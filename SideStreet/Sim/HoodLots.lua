-- SideStreet neighbourhood lot builder: turns the blueprints in Data/HoodLots.lua into real,
-- editable lot data (floors, walls with finishes, doors, windows, arches, stairs with stairwells
-- and railings, fences, pools, paths, roofs, furniture and a curbside mailbox), furnished through
-- SS.Catalog.Find with a fallback to the base object ids. Also validates any lot (built or edited):
-- World.Rebuild runs, the front door is reachable from the entry, every fixture is usable and the
-- mailbox sits by the entry. Owner: hood module (docs/modules/hood.md).
--
-- Pure Lua: no WoW API. Building never touches SS.RT (the runtime cache of the running lot);
-- validation saves and restores it around its own World.Rebuild.
local _, SS = ...
local HL = SS.HoodLots or {}
SS.HoodLots = HL
local G = SS.Grid

local OPEN = { door = true, gate = true, arch = true }
local NOBLOCK_MOUNT = { wall = true, ceiling = true, surface = true, window = true }

local function idx(lot, i, j) return j * lot.w + i + 1 end
local function inLot(lot, i, j) return i >= 0 and j >= 0 and i < lot.w and j < lot.h end
HL.idx, HL.inLot = idx, inLot

local function sortedKeys(t)
    local ks = {}
    for k in pairs(t or {}) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
    return ks
end
HL.sortedKeys = sortedKeys

-- Objects that never block a cell (same rule as SS.World.NonBlocking when it exists).
function HL.NonBlocking(def, o)
    if SS.World and SS.World.NonBlocking then return SS.World.NonBlocking(def, o) end
    if not def then return true end
    if def.noBlock or def.rug or (def.mount and NOBLOCK_MOUNT[def.mount]) then return true end
    if o and o.parent then return true end
    return false
end

---------------------------------------------------------------------------
-- Finishes, styles and object kinds
---------------------------------------------------------------------------

-- First candidate id that exists in SS.Finishes[kind] ("floors" | "walls" | ...), else fallback.
function HL.Finish(kind, cands, fallback)
    local t = SS.Finishes and SS.Finishes[kind]
    if type(t) ~= "table" then return fallback end
    for _, id in ipairs(cands or {}) do if t[id] then return id end end
    if fallback and t[fallback] then return fallback end
    return fallback or sortedKeys(t)[1]
end

-- Door/window/fence style by tier from the build catalogue when it exists (nil = renderer default).
local TIER_POS = { budget = 0, mid = 0.5, lux = 1 }
function HL.Style(kind, tier)
    local t = SS.Finishes and SS.Finishes[kind]
    if type(t) ~= "table" then return nil end
    local ids = sortedKeys(t)
    if #ids == 0 then return nil end
    table.sort(ids, function(a, b)
        local pa, pb = type(t[a]) == "table" and t[a].price or 0, type(t[b]) == "table" and t[b].price or 0
        if pa ~= pb then return pa < pb end
        return a < b
    end)
    local pos = TIER_POS[tier or "mid"] or 0.5
    return ids[math.floor(pos * (#ids - 1) + 0.5) + 1]
end

-- Does definition `id` serve as `kind` (a tag, or the base-object stand-in table)?
function HL.IsKind(id, kind)
    local def = SS.Objects[id]
    if not def then return false end
    if SS.Tags.Has(def, kind) then return true end
    return HL.BASE_KIND[id] == kind
end

-- How many people a bed sleeps (catalogue bed slots in group "bed"; base beds sleep one).
function HL.Sleeps(def)
    if not def then return 0 end
    local n = 0
    for name, sl in pairs(def.slots or {}) do
        if sl.group == "bed" or (not sl.group and name:find("^bed")) then n = n + 1 end
    end
    if def.quality and type(def.quality.capacity) == "number" and (def.sleeps == nil) then n = math.max(n, def.quality.capacity) end
    if def.sleeps then n = def.sleeps end
    return math.max(n, 1)
end

-- Catalogue candidates for a furnishing role, cheapest first inside the tier's price band, then
-- outside it, then the base fallback. Uses only SS.Catalog.Find (stepping minPrice upward).
local function findSeries(q, lo, hi, out, seen, cap)
    local query = {}
    for k, v in pairs(q) do query[k] = v end
    query.maxPrice = hi
    local minP = lo
    for _ = 1, cap do
        query.minPrice = minP
        local id = SS.Catalog and SS.Catalog.Find and SS.Catalog.Find(query)
        if not id then break end
        if not seen[id] then seen[id] = true; out[#out + 1] = id end
        local p = SS.Objects[id] and SS.Objects[id].price or 0
        minP = p + 1
    end
end
-- fit: 0 (or nil) catalogue order; 1 = pieces no bigger than the blueprint planned for first (the
-- base object's footprint, or r.fit cells); 2 = the base object first, then fit order.
local function fpSize(id)
    local def = SS.Objects[id]
    return def and #(def.fp or { { 0, 0 } }) or 99
end
function HL.Candidates(role, tier, fit)
    local r = HL.roles[role]
    if not r then return {} end
    local out, seen = {}, {}
    local band = r.band and r.band[tier or "mid"]
    for _, q in ipairs(r.q or {}) do
        if band then findSeries(q, band[1], band[2], out, seen, 5) end
        findSeries(q, nil, nil, out, seen, 5)
    end
    if r.base and SS.Objects[r.base] and not seen[r.base] then out[#out + 1] = r.base end
    if fit and fit > 0 and #out > 1 then
        local ref = r.fit or (r.base and SS.Objects[r.base] and fpSize(r.base)) or 1
        local small, big = {}, {}
        for _, id in ipairs(out) do
            if fit == 2 and id == r.base then table.insert(small, 1, id)
            elseif fpSize(id) <= ref then small[#small + 1] = id
            else big[#big + 1] = id end
        end
        for _, id in ipairs(big) do small[#small + 1] = id end
        out = small
    end
    return out
end

---------------------------------------------------------------------------
-- Placement context: occupancy, stairwells, pools, kept-clear cells and reachability.
---------------------------------------------------------------------------
local function newCtx(lot)
    local ctx = { lot = lot, occ = { [0] = {}, [1] = {} }, well = { [0] = {}, [1] = {} }, keep = { [0] = {}, [1] = {} },
        ceil = { [0] = {}, [1] = {} }, mounted = { [0] = {}, [1] = {} }, placed = {}, problems = {}, need = {}, reach = nil,
        pslots = {} }
    return ctx
end

local function floorAt(lot, lv, i, j)
    local f = lot.floor[lv]
    return f and f[idx(lot, i, j)]
end

local function walkable(ctx, lv, i, j)
    local lot = ctx.lot
    if not inLot(lot, i, j) then return false end
    local k = idx(lot, i, j)
    if ctx.occ[lv][k] or ctx.well[lv][k] then return false end
    if lv == 0 and lot.pool and lot.pool[k] then return false end
    if lv > 0 and not floorAt(lot, lv, i, j) then return false end
    return true
end
HL.walkableCtx = walkable

local function wallOn(lot, lv, key)
    local w = lot.walls[lv]
    return w and w[key]
end

local function canStep(ctx, lv, i, j, ni, nj)
    local wl = wallOn(ctx.lot, lv, G.edgeBetween(i, j, ni, nj))
    return not wl or OPEN[wl.kind]
end

-- Flood from the entry over both levels (stairs link bottom <-> top). Returns reach[lv][idx].
local function flood(ctx)
    local lot = ctx.lot
    local reach = { [0] = {}, [1] = {} }
    local e = lot.entry
    if not e or not walkable(ctx, 0, e[1], e[2]) then ctx.reach = reach; return reach end
    local stack = { { e[1], e[2], 0 } }
    reach[0][idx(lot, e[1], e[2])] = true
    local links = {}
    for _, st in ipairs(ctx.stairs or {}) do
        local b = st.bottom; local t = st.top
        links[0 .. ":" .. idx(lot, b[1], b[2])] = { t[1], t[2], 1 }
        links[1 .. ":" .. idx(lot, t[1], t[2])] = { b[1], b[2], 0 }
    end
    while #stack > 0 do
        local c = table.remove(stack)
        local i, j, lv = c[1], c[2], c[3]
        for d = 0, 3 do
            local dv = G.DIRS[d]
            local ni, nj = i + dv[1], j + dv[2]
            if walkable(ctx, lv, ni, nj) and not reach[lv][idx(lot, ni, nj)] and canStep(ctx, lv, i, j, ni, nj) then
                reach[lv][idx(lot, ni, nj)] = true
                stack[#stack + 1] = { ni, nj, lv }
            end
        end
        local l = links[lv .. ":" .. idx(lot, i, j)]
        if l and walkable(ctx, l[3], l[1], l[2]) and not reach[l[3]][idx(lot, l[1], l[2])] then
            reach[l[3]][idx(lot, l[1], l[2])] = true
            stack[#stack + 1] = { l[1], l[2], l[3] }
        end
    end
    ctx.reach = reach
    return reach
end
HL.floodCtx = flood

-- Usable approach cells of an object's slots (walkable, and no wall between an adjacent approach
-- and the slot's own cell). Returns list of { i, j, lv, slot } (may be empty).
local function approaches(ctx, def, o)
    local out = {}
    local lv = o.level or 0
    for name, sl in pairs(def.slots or {}) do
        local cell = sl.cell or { 0, 0 }
        local cx, cy = G.rot(cell[1], cell[2], o.f)
        cx, cy = o.x + cx, o.y + cy
        for _, ap in ipairs(sl.approaches or {}) do
            local dx, dy = G.rot(ap[1], ap[2], o.f)
            local ai, aj = o.x + dx, o.y + dy
            local ok = walkable(ctx, lv, ai, aj) or (ai == o.x and aj == o.y and HL.NonBlocking(def, o))
            if ok and math.abs(ai - cx) + math.abs(aj - cy) == 1 then
                local wl = wallOn(ctx.lot, lv, G.edgeBetween(cx, cy, ai, aj))
                if wl and not OPEN[wl.kind] then ok = false end
            end
            if ok then out[#out + 1] = { ai, aj, lv, name } end
        end
    end
    return out
end
HL.approachesCtx = approaches

local function slotCount(def)
    local n = 0
    for _ in pairs(def.slots or {}) do n = n + 1 end
    return n
end

local function isSeat(def) return def and (def.seat or SS.Tags.Has(def, "seat") or SS.Tags.Has(def, "sofa")) and true or false end

-- Seats a viewer object (TV) can be watched from: facing it, 1-4 cells in front, at most one
-- cell to the side (the rule SS.Actions.ResolveSlot uses for "viewer" interactions).
function HL.ViewerSeats(lot, o)
    local out = {}
    local fx, fy = G.rot(0, 1, o.f)
    for _, sid in ipairs(sortedKeys(lot.objects)) do
        local s = lot.objects[sid]
        local sd = SS.Objects[s.def]
        if s ~= o and isSeat(sd) and s.f == (o.f + 2) % 4 and (s.level or 0) == (o.level or 0) then
            local dx, dy = s.x - o.x, s.y - o.y
            local along = dx * fx + dy * fy
            local side = math.abs(dx * fy - dy * fx)
            if along >= 1 and along <= 4 and side <= 1 then out[#out + 1] = s end
        end
    end
    return out
end

-- Every recorded requirement (door sides, stair ends, entry, every placed object's usable
-- approach) still reachable?
local function requirementsMet(ctx, reach)
    local lot = ctx.lot
    for _, p in ipairs(ctx.need) do
        if not reach[p[3]][idx(lot, p[1], p[2])] then return false, p.what end
    end
    local function usable(def, o)
        for _, a in ipairs(approaches(ctx, def, o)) do
            if reach[a[3]][idx(lot, a[1], a[2])] then return true end
        end
        return false
    end
    for _, rec in ipairs(ctx.placed) do
        if rec.needsReach and not usable(rec.def, rec.o) then
            local ok = false
            if rec.def.viewer then
                for _, s in ipairs(HL.ViewerSeats(lot, rec.o)) do
                    if usable(SS.Objects[s.def], s) then ok = true; break end
                end
            end
            if not ok then return false, rec.o.def end
        end
    end
    return true
end

local function footprint(def, x, y, f)
    local out = {}
    for n, c in ipairs(def.fp or { { 0, 0 } }) do
        local dx, dy = G.rot(c[1], c[2], f)
        out[n] = { x + dx, y + dy, c[1], c[2] }
    end
    return out
end

local function indoorCell(ctx, lv, i, j)
    local r = ctx.roomOf and ctx.roomOf[lv] and ctx.roomOf[lv][idx(ctx.lot, i, j)]
    if r then return true end
    return lv == 0 and floorAt(ctx.lot, 1, i, j) ~= nil -- under an upper floor
end

-- Surface parent for a surface-mounted item at (x, y): an object whose surface cell is there,
-- with a free surface slot of a kind the item fits.
local function surfaceParent(ctx, def, x, y, lv)
    local fits
    if def.fits then fits = {}; for _, k in ipairs(def.fits) do fits[k] = true end end
    for _, rec in ipairs(ctx.placed) do
        local p = rec.o
        local pdef = rec.def
        if (p.level or 0) == lv and pdef.surfaces then
            local flat = SS.Catalog and SS.Catalog.SurfaceSlots and SS.Catalog.SurfaceSlots(pdef)
            if not flat then
                flat = {}
                for n, s in ipairs(pdef.surfaces) do for _ = 1, (s.slots or 1) do flat[#flat + 1] = { surface = n, cell = s.cell or { 0, 0 }, kind = s.kind } end end
            end
            for k, s in ipairs(flat) do
                local dx, dy = G.rot(s.cell[1], s.cell[2], p.f)
                if p.x + dx == x and p.y + dy == y and (not fits or fits[s.kind]) and not ctx.pslots[p.id .. ":" .. k] then
                    return p, k
                end
            end
        end
    end
end

-- Can definition `id` go at (x, y, f, lv)? Returns ok, why, parent, pslot.
function HL.CanPlace(ctx, id, x, y, f, lv)
    local def = SS.Objects[id]
    local lot = ctx.lot
    if not def then return false, "unknown object" end
    if not inLot(lot, x, y) then return false, "outside the lot" end
    if lv > 0 and not floorAt(lot, lv, x, y) then return false, "no floor" end
    if def.groundOnly and lv > 0 then return false, "ground only" end
    if def.outdoor and indoorCell(ctx, lv, x, y) then return false, "outdoor only" end
    local mount = def.mount or "floor"
    local k0 = idx(lot, x, y)
    if ctx.well[lv][k0] or (lv == 0 and lot.pool and lot.pool[k0]) then return false, "stairwell or pool" end
    if mount == "surface" then
        local p, k = surfaceParent(ctx, def, x, y, lv)
        if not p then return false, "no free surface" end
        return true, nil, p, k
    elseif mount == "wall" or mount == "window" then
        local want = mount == "wall" and "wall" or "window"
        for _, c in ipairs(footprint(def, x, y, f)) do
            if not inLot(lot, c[1], c[2]) then return false, "outside" end
            local bx, by = G.rot(0, -1, f)
            local key = G.edgeBetween(c[1], c[2], c[1] + bx, c[2] + by)
            local wl = wallOn(lot, lv, key)
            if not wl or wl.kind ~= want then return false, "needs a " .. want .. " behind" end
            if ctx.mounted[lv][key .. "@" .. c[1] .. "," .. c[2]] then return false, "wall spot taken" end
        end
        return true
    elseif mount == "ceiling" then
        if not indoorCell(ctx, lv, x, y) then return false, "needs a ceiling" end
        if ctx.ceil[lv][k0] then return false, "ceiling spot taken" end
        return true
    end
    if HL.NonBlocking(def) then return true end
    local cells = footprint(def, x, y, f)
    local set = {}
    for _, c in ipairs(cells) do
        if not inLot(lot, c[1], c[2]) then return false, "outside the lot" end
        local k = idx(lot, c[1], c[2])
        if ctx.occ[lv][k] then return false, "occupied" end
        if ctx.keep[lv][k] then return false, "keep clear" end
        if ctx.well[lv][k] or (lv == 0 and lot.pool and lot.pool[k]) then return false, "stairwell or pool" end
        if lv > 0 and not floorAt(lot, lv, c[1], c[2]) then return false, "no floor" end
        set[c[1] .. "," .. c[2]] = true
    end
    -- no wall may cut through a multi-cell footprint
    for _, c in ipairs(cells) do
        for d = 0, 3 do
            local dv = G.DIRS[d]
            local ni, nj = c[1] + dv[1], c[2] + dv[2]
            if set[ni .. "," .. nj] then
                local wl = wallOn(lot, lv, G.edgeBetween(c[1], c[2], ni, nj))
                if wl then return false, "a wall crosses it" end
            end
        end
    end
    if def.wallBack then
        local bx, by = G.rot(0, -1, f)
        for _, c in ipairs(cells) do
            if not set[(c[1] + bx) .. "," .. (c[2] + by)] then
                local wl = wallOn(lot, lv, G.edgeBetween(c[1], c[2], c[1] + bx, c[2] + by))
                if not wl or wl.kind ~= "wall" then return false, "needs a wall behind" end
            end
        end
    end
    return true
end

local function markPlaced(ctx, def, o, add)
    local lot = ctx.lot
    local lv = o.level or 0
    local mount = def.mount or "floor"
    local v = add and o.id or nil
    if o.parent then
        ctx.pslots[o.parent .. ":" .. o.pslot] = add or nil
    elseif mount == "wall" or mount == "window" then
        for _, c in ipairs(footprint(def, o.x, o.y, o.f)) do
            local bx, by = G.rot(0, -1, o.f)
            ctx.mounted[lv][G.edgeBetween(c[1], c[2], c[1] + bx, c[2] + by) .. "@" .. c[1] .. "," .. c[2]] = v
        end
    elseif mount == "ceiling" then
        ctx.ceil[lv][idx(lot, o.x, o.y)] = v
    elseif not HL.NonBlocking(def, o) then
        for _, c in ipairs(footprint(def, o.x, o.y, o.f)) do
            if inLot(lot, c[1], c[2]) then ctx.occ[lv][idx(lot, c[1], c[2])] = v end
        end
    end
end

local function newObject(lot, defId, x, y, f, lv)
    local n = lot.nextObj or 1
    local id = "o" .. n
    while lot.objects[id] do n = n + 1; id = "o" .. n end
    lot.nextObj = n + 1
    lot.nextId = lot.nextObj
    local o = { id = id, def = defId, x = x, y = y, f = f or 0, level = lv or 0 }
    return o
end

-- Try to place `defId`; keeps every earlier requirement reachable. Returns object or nil, why.
function HL.TryPlace(ctx, defId, x, y, f, lv, opts)
    local ok, why, parent, pslot = HL.CanPlace(ctx, defId, x, y, f, lv)
    if not ok then return nil, why end
    local def = SS.Objects[defId]
    local lot = ctx.lot
    local o = newObject(lot, defId, x, y, f, lv)
    if parent then o.parent, o.pslot = parent.id, pslot end
    lot.objects[o.id] = o
    markPlaced(ctx, def, o, true)
    local rec = { o = o, def = def, needsReach = slotCount(def) > 0 and not (opts and opts.noReach) }
    local blocking = not HL.NonBlocking(def, o) and (def.mount or "floor") == "floor"
    local reach = ctx.reach
    if blocking or not reach then reach = flood(ctx) end
    ctx.placed[#ctx.placed + 1] = rec
    local good, what = requirementsMet(ctx, reach)
    if not good then
        ctx.placed[#ctx.placed] = nil
        markPlaced(ctx, def, o, false)
        lot.objects[o.id] = nil
        lot.nextObj = lot.nextObj - 1
        lot.nextId = lot.nextObj
        if blocking then flood(ctx) end
        return nil, "would block " .. tostring(what)
    end
    if def.startState and not o.state then o.state = SS.U.deepcopy(def.startState) end
    return o
end

-- Register an existing lot object (the starter's furniture) with the context.
local function adopt(ctx, o)
    local def = SS.Objects[o.def]
    if not def then return end
    markPlaced(ctx, def, o, true)
    local st = def.stairs
    if st then
        local function at(p) local dx, dy = G.rot(p[1], p[2], o.f); return { o.x + dx, o.y + dy } end
        local rec = { bottom = at(st.bottom), top = at(st.top), run = {} }
        for n, c in ipairs(st.run) do rec.run[n] = at(c) end
        ctx.stairs = ctx.stairs or {}
        ctx.stairs[#ctx.stairs + 1] = rec
        for _, c in ipairs(rec.run) do if inLot(ctx.lot, c[1], c[2]) then ctx.well[(o.level or 0) + 1][idx(ctx.lot, c[1], c[2])] = o.id end end
    end
    ctx.placed[#ctx.placed + 1] = { o = o, def = def, needsReach = slotCount(def) > 0 }
end
HL.Adopt = adopt

---------------------------------------------------------------------------
-- Structure
---------------------------------------------------------------------------
local function setWall(lot, lv, key, kind, a, b, style)
    lot.walls[lv] = lot.walls[lv] or {}
    local old = lot.walls[lv][key]
    if old and kind ~= "wall" and kind ~= "railing" and kind ~= "fence" then
        old.kind, old.style = kind, style or old.style
        return old
    end
    local wl = { kind = kind, a = a, b = b, style = style }
    lot.walls[lv][key] = wl
    return wl
end

local function roomGroup(r, n) return r.group or ("room" .. n) end

-- Build rooms (floors + automatic walls with finishes), openings, outdoor floors, stairs,
-- railings, fences and pool. Returns ctx.
local function buildStructure(lot, bp, ctx)
    local ext = HL.Finish("walls", bp.ext, "siding_sage")
    local tier = bp.tier or "mid"
    ctx.roomOf = { [0] = {}, [1] = {} }
    ctx.roomRec = {}
    for n, r in ipairs(bp.rooms or {}) do
        local lv, i0, j0, i1, j1 = r[1], r[2], r[3], r[4], r[5]
        local fin = HL.Finish("floors", r.floor, "wood")
        local paint = HL.Finish("walls", r.paint, "paint_cream")
        ctx.roomRec[n] = { name = r[6], paint = paint, group = roomGroup(r, n), lv = lv }
        for j = j0, j1 do
            for i = i0, i1 do
                if inLot(lot, i, j) then
                    local k = idx(lot, i, j)
                    if ctx.roomOf[lv][k] then ctx.problems[#ctx.problems + 1] = "rooms overlap at " .. i .. "," .. j end
                    ctx.roomOf[lv][k] = n
                    lot.floor[lv][k] = fin
                end
            end
        end
    end
    -- outdoor floors (paths, porches, decks, balconies)
    for _, od in ipairs(bp.outdoor or {}) do
        local lv = od[1]
        local fin = HL.Finish("floors", od[6], "path")
        for j = od[3], od[5] do
            for i = od[2], od[4] do
                if inLot(lot, i, j) and not ctx.roomOf[lv][idx(lot, i, j)] then lot.floor[lv][idx(lot, i, j)] = fin end
            end
        end
    end
    -- automatic walls: room vs non-room, and between rooms of different groups
    for lv = 0, 1 do
        for j = 0, lot.h - 1 do
            for i = 0, lot.w - 1 do
                local n = ctx.roomOf[lv][idx(lot, i, j)]
                if n then
                    local rr = ctx.roomRec[n]
                    for d = 0, 3 do
                        local dv = G.DIRS[d]
                        local ni, nj = i + dv[1], j + dv[2]
                        local m = inLot(lot, ni, nj) and ctx.roomOf[lv][idx(lot, ni, nj)] or nil
                        local other = m and ctx.roomRec[m]
                        if not other or other.group ~= rr.group then
                            local key = G.edgeBetween(i, j, ni, nj)
                            if not lot.walls[lv][key] then
                                -- a = side with the lower cell coordinate
                                local _, _, _, ai, aj = G.parseEdge(key)
                                local mine, theirs = rr.paint, other and other.paint or ext
                                local a, b
                                if ai == i and aj == j then a, b = mine, theirs else a, b = theirs, mine end
                                setWall(lot, lv, key, "wall", a, b)
                            end
                        end
                    end
                end
            end
        end
    end
    local doorStyle, winStyle = HL.Style("doors", tier), HL.Style("windows", tier)
    local function opening(list, kind, style)
        for _, d in ipairs(list or {}) do
            local lv, key = d[1], d[2]
            if not lot.walls[lv][key] then
                ctx.problems[#ctx.problems + 1] = kind .. " " .. key .. " (level " .. lv .. ") is not on a wall"
            else
                setWall(lot, lv, key, kind, nil, nil, style)
                if d.front then lot.frontDoor = key end
            end
        end
    end
    opening(bp.doors, "door", doorStyle)
    opening(bp.arches, "arch", nil)
    opening(bp.windows, "window", winStyle)
    -- stairs
    ctx.stairs = {}
    for _, s in ipairs(bp.stairs or {}) do
        local sid = SS.Objects.stairs_straight and "stairs_straight"
        if not sid then
            for _, id in ipairs(sortedKeys(SS.Objects)) do if SS.Objects[id].stairs then sid = id; break end end
        end
        if not sid then
            ctx.problems[#ctx.problems + 1] = "no stairs object defined"
        else
            local o = newObject(lot, sid, s[1], s[2], s[3], 0)
            lot.objects[o.id] = o
            adopt(ctx, o)
            -- the stairwell has no upper floor
            for _, c in ipairs(ctx.stairs[#ctx.stairs].run) do lot.floor[1][idx(lot, c[1], c[2])] = nil end
        end
    end
    -- railings: upper floor edges open to a drop, except each stair's exit edge
    local exits = {}
    for _, st in ipairs(ctx.stairs) do
        local t = st.top
        for _, c in ipairs(st.run) do
            if math.abs(c[1] - t[1]) + math.abs(c[2] - t[2]) == 1 then exits[G.edgeBetween(t[1], t[2], c[1], c[2])] = true end
        end
    end
    local railStyle = HL.Style("railings", tier)
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do
            if lot.floor[1][idx(lot, i, j)] then
                for d = 0, 3 do
                    local dv = G.DIRS[d]
                    local ni, nj = i + dv[1], j + dv[2]
                    local drop = not inLot(lot, ni, nj) or not lot.floor[1][idx(lot, ni, nj)]
                    local key = G.edgeBetween(i, j, ni, nj)
                    if drop and not lot.walls[1][key] and not exits[key] then
                        local wl = setWall(lot, 1, key, "railing", nil, nil, railStyle)
                        wl.auto = true
                    end
                end
            end
        end
    end
    -- fences along the lot boundary (back, sides) with an optional front gate
    local fs = bp.fence
    if fs then
        local fstyle = HL.Style("fences", tier)
        if fs.back then for i = 0, lot.w - 1 do setWall(lot, 0, "x:" .. i .. ":0", "fence", nil, nil, fstyle) end end
        if fs.west then for j = fs.west[1], fs.west[2] do setWall(lot, 0, "y:0:" .. j, "fence", nil, nil, fstyle) end end
        if fs.east then for j = fs.east[1], fs.east[2] do setWall(lot, 0, "y:" .. lot.w .. ":" .. j, "fence", nil, nil, fstyle) end end
    end
    -- pool
    if bp.pool then
        local p = bp.pool
        lot.pool = lot.pool or {}
        for j = p[2], p[4] do
            for i = p[1], p[3] do
                if inLot(lot, i, j) then
                    lot.pool[idx(lot, i, j)] = { depth = p[5] or 2 }
                    lot.floor[0][idx(lot, i, j)] = nil
                end
            end
        end
    end
    return ctx
end

---------------------------------------------------------------------------
-- Keep-clear cells: entry, door sides, stair ends, the path from the entry, spawn points.
---------------------------------------------------------------------------
local function keepCell(ctx, lv, i, j, what)
    if inLot(ctx.lot, i, j) then
        ctx.keep[lv][idx(ctx.lot, i, j)] = true
        if what then ctx.need[#ctx.need + 1] = { i, j, lv, what = what } end
    end
end

local function keepClear(ctx, bp)
    local lot = ctx.lot
    keepCell(ctx, 0, lot.entry[1], lot.entry[2], "entry")
    for lv = 0, 1 do
        for _, key in ipairs(sortedKeys(lot.walls[lv])) do
            local wl = lot.walls[lv][key]
            if OPEN[wl.kind] then
                local _, _, _, ai, aj, bi, bj = G.parseEdge(key)
                keepCell(ctx, lv, ai, aj, wl.kind .. " " .. key)
                keepCell(ctx, lv, bi, bj, wl.kind .. " " .. key)
            end
        end
    end
    for _, st in ipairs(ctx.stairs or {}) do
        keepCell(ctx, 0, st.bottom[1], st.bottom[2], "stairs bottom")
        keepCell(ctx, 1, st.top[1], st.top[2], "stairs top")
    end
    for _, od in ipairs(bp.outdoor or {}) do
        -- path cells (ground level, front yard) stay walkable; decks may hold furniture
        local fin = od[6] and od[6][#od[6]]
        if od[1] == 0 and fin == "path" and (od[2] == od[4] or od[3] == od[5]) then
            for j = od[3], od[5] do for i = od[2], od[4] do keepCell(ctx, 0, i, j) end end
        end
    end
    for _, s in ipairs(bp.spawn or {}) do keepCell(ctx, s[3] or 0, s[1], s[2]) end
end

---------------------------------------------------------------------------
-- Furnishing
---------------------------------------------------------------------------
local CHAIR_SPOTS = { { 0, 1, 2 }, { 0, -1, 0 }, { -1, 0, 3 }, { 1, 0, 1 } } -- dx, dy, chair facing (toward the table)

-- Place one furnishing role; tries each catalogue candidate (n-th first), then small shifts.
local function placeRole(ctx, role, lv, x, y, f, tier, opts)
    local cands = HL.Candidates(role, tier, ctx.fit)
    if #cands == 0 then return nil, "no candidates for " .. role end
    local n = opts and opts.n or 1
    if n > 1 and #cands > 1 then
        local k = ((n - 1) % #cands) + 1
        local rot = {}
        for m = 0, #cands - 1 do rot[#rot + 1] = cands[((k - 1 + m) % #cands) + 1] end
        cands = rot
    end
    local lastWhy
    local turns = (opts and opts.fixed) and 0 or 3
    for _, id in ipairs(cands) do
        for t = 0, turns do
            local o, why = HL.TryPlace(ctx, id, x, y, (f + t) % 4, lv, opts)
            if o then return o end
            if t == 0 then lastWhy = id .. ": " .. tostring(why) end
        end
    end
    return nil, lastWhy
end
HL.PlaceRole = placeRole

local function dining(ctx, item, tier)
    local lv, x, y, f = item[2], item[3], item[4], item[5] or 0
    local t, why = placeRole(ctx, "table", lv, x, y, f, tier)
    if not t then return nil, why end
    local def = SS.Objects[t.def]
    local cells = footprint(def, t.x, t.y, t.f)
    local set = {}
    for _, c in ipairs(cells) do set[c[1] .. "," .. c[2]] = true end
    local want, got, spots = item.chairs or 2, 0, 0
    for _, c in ipairs(cells) do
        for _, s in ipairs(CHAIR_SPOTS) do
            if got >= want then break end
            local ci, cj = c[1] + s[1], c[2] + s[2]
            if not set[ci .. "," .. cj] then
                spots = spots + 1
                local ch = placeRole(ctx, item.chairRole or "chair", lv, ci, cj, s[3], tier, { fixed = true })
                if ch then got = got + 1 end
            end
        end
    end
    if got < math.min(want, spots) then ctx.problems[#ctx.problems + 1] = string.format("dining at %d,%d seats %d of %d", x, y, got, want) end
    return t
end

local function furnish(ctx, bp)
    local lot = ctx.lot
    local tier = bp.tier or "mid"
    local lastPrimary
    local items = bp.items or {}
    if (ctx.fit or 0) >= 1 then
        -- the careful passes place every needed piece before the optional extras (decor and
        -- gadgets that have no base stand-in), so an extra never crowds out a needed piece
        local need, extra = {}, {}
        for _, item in ipairs(items) do
            local r = HL.roles[item[1]]
            if r and r.base == false then extra[#extra + 1] = item else need[#need + 1] = item end
        end
        items = need
        for _, item in ipairs(extra) do items[#items + 1] = item end
    end
    for _, item in ipairs(items) do
        local role = item[1]
        local o, why
        if role == "dining" then
            o, why = dining(ctx, item, tier)
        elseif item.pairWith then
            -- companion bed: only when the primary bed placed just before sleeps one
            local prim = lastPrimary
            if prim and HL.Sleeps(SS.Objects[prim.def]) < 2 then
                o, why = placeRole(ctx, role, item[2], item[3], item[4], item[5] or 0, tier, { n = item.n })
            else
                o, why = nil, "skip"
            end
        else
            o, why = placeRole(ctx, role, item[2], item[3], item[4], item[5] or 0, tier, { n = item.n })
        end
        if o then
            local rdef = HL.roles[role]
            if rdef and rdef.landscape then o.landscape = role end -- "tree" | "shrub" | "flowers" | "fountain" (previews draw it)
            if item.state then
                o.state = o.state or {}
                for k, v in pairs(item.state) do o.state[k] = v end
            end
            if role == "bed" or role == "bed2" then lastPrimary = o end
        elseif why ~= "skip" then
            local r = HL.roles[role]
            local optional = r and r.base == false
            if not optional and role ~= "dining" then
                ctx.problems[#ctx.problems + 1] = string.format("%s at %d,%d (level %d) not placed: %s", role, item[3], item[4], item[2], tostring(why))
            end
            ctx.skipped = (ctx.skipped or 0) + 1
        end
    end
end

local function placeMailbox(ctx, bp)
    local lot = ctx.lot
    local m = bp.mailbox
    if not m then return end
    local o, why = placeRole(ctx, "mailbox", 0, m[1], m[2], m[3] or 2, "mid")
    if not o then
        -- any cell next to the entry
        local e = lot.entry
        for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { -2, 0 }, { 2, 0 } }) do
            o = placeRole(ctx, "mailbox", 0, e[1] + d[1], e[2] + d[2], 2, "mid")
            if o then break end
        end
    end
    if o then lot.mailbox = o.id else ctx.problems[#ctx.problems + 1] = "mailbox not placed: " .. tostring(why) end
end

-- Is the level-0 edge `key` a door, gate or arch?
function HL.IsOpening(lot, key)
    local wl = key and lot.walls and lot.walls[0] and lot.walls[0][key]
    return wl ~= nil and OPEN[wl.kind] == true
end

-- The most likely front door of an existing lot (an upgraded save without the record): a door,
-- gate or arch on an edge along x, nearest the street row, then nearest the entry's column.
-- Returns the edge key or nil.
function HL.FindFrontDoor(lot)
    local best, bestJ, bestD
    local ei = lot.entry and lot.entry[1] or math.floor(lot.w / 2)
    for _, key in ipairs(sortedKeys(lot.walls and lot.walls[0] or {})) do
        if HL.IsOpening(lot, key) then
            local axis, i, j = G.parseEdge(key)
            if axis == "x" then
                local d = math.abs(i - ei)
                if not best or j > bestJ or (j == bestJ and d < bestD) then best, bestJ, bestD = key, j, d end
            end
        end
    end
    return best
end

-- Put a mailbox back beside the entry of an existing lot (after a bulldoze, or an upgraded save).
-- Returns the object id, or nil and a reason.
function HL.AddMailbox(lot)
    if not lot or not lot.entry then return nil, "lot has no entry" end
    for _, o in pairs(lot.objects or {}) do
        local def = SS.Objects[o.def]
        if def and SS.Tags.Has(def, "mailbox") then lot.mailbox = o.id; return o.id end
    end
    local ctx = newCtx(lot)
    for _, oid in ipairs(sortedKeys(lot.objects)) do adopt(ctx, lot.objects[oid]) end
    local e = lot.entry
    for _, d in ipairs({ { 0, -1 }, { 1, -1 }, { -1, -1 } }) do
        local k = idx(lot, e[1] + d[1], e[2] + d[2])
        if inLot(lot, e[1] + d[1], e[2] + d[2]) then ctx.keep[0][k] = "path" end
    end
    ctx.keep[0][idx(lot, e[1], e[2])] = "entry"
    flood(ctx)
    local bp = HL.blueprints[lot.blueprint or ""]
    local m = bp and bp.mailbox or { e[1] - 1, e[2], 2 }
    placeMailbox(ctx, { mailbox = m })
    if lot.mailbox and lot.objects[lot.mailbox] then return lot.mailbox end
    return nil, ctx.problems[#ctx.problems] or "no room for a mailbox"
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------
local function newLot(bp, id, address)
    local lot = {
        id = id, address = address, name = bp.name, desc = bp.desc, kind = bp.venue and "community" or "residential",
        venue = bp.venue, w = bp.w, h = bp.h, price = bp.land or 0, street = "south",
        entry = { bp.entry[1], bp.entry[2] }, floor = { [0] = {}, [1] = {} }, walls = { [0] = {}, [1] = {} },
        objects = {}, nextObj = 1, nextId = 1, version = 1, blueprint = nil, tier = bp.tier, style = bp.style,
    }
    if bp.roof then
        local mat = bp.roof.material
        local roofs = SS.Finishes and (SS.Finishes.roofs or SS.Finishes.roof)
        if type(roofs) == "table" and not roofs[mat] then mat = sortedKeys(roofs)[1] or mat end
        lot.roof = { style = bp.roof.style, material = mat, color = bp.roof.color }
    end
    local grass = HL.Finish("floors", { "grass", "lawn" }, "grass")
    for j = 0, lot.h - 1 do for i = 0, lot.w - 1 do lot.floor[0][idx(lot, i, j)] = grass end end
    return lot
end

-- Build blueprint `bpId` as lot `id` at `address`. Returns lot, problems (empty when clean).
-- The furnishing uses the catalogue's own order first (variety); when a piece does not fit or the
-- lot does not validate (a bigger catalogue piece crowding the plan), it is rebuilt preferring
-- pieces of the planned size, then the base objects. The cleanest attempt wins.
function HL.Build(bpId, id, address)
    local bp = HL.blueprints[bpId]
    assert(bp, "SideStreet: unknown lot blueprint " .. tostring(bpId))
    if bp.starter then return HL.BuildPass(bpId, id, address, 0) end
    local best
    for fit = 0, 2 do
        local lot, problems, ctx = HL.BuildPass(bpId, id, address, fit)
        local bad = #problems
        if bad == 0 then
            local ok, vp = HL.ValidateLot(lot, nil, { furnished = not bp.empty and not bp.venue })
            if not ok then bad = #vp end
        end
        if not best or bad < best.bad then best = { lot = lot, problems = problems, ctx = ctx, bad = bad, fit = fit } end
        if bad == 0 then break end
    end
    best.ctx.fitPass = best.fit
    return best.lot, best.problems, best.ctx
end

function HL.BuildPass(bpId, id, address, fit)
    local bp = HL.blueprints[bpId]
    local lot, ctx
    if bp.starter then
        lot = SS.Fixtures.StarterLot()
        lot.id, lot.address = id or lot.id, address or lot.address
        lot.name, lot.desc, lot.price, lot.street = bp.name, bp.desc, bp.land or lot.price, "south"
        lot.entry = { bp.entry[1], bp.entry[2] }
        lot.frontDoor, lot.tier, lot.style = bp.frontDoor, bp.tier, bp.style
        lot.nextId = lot.nextObj
        ctx = newCtx(lot)
        for _, oid in ipairs(sortedKeys(lot.objects)) do adopt(ctx, lot.objects[oid]) end
        keepClear(ctx, bp)
        flood(ctx)
    else
        lot = newLot(bp, id, address)
        ctx = newCtx(lot)
        ctx.fit = fit
        buildStructure(lot, bp, ctx)
        keepClear(ctx, bp)
        flood(ctx)
        furnish(ctx, bp)
    end
    placeMailbox(ctx, bp)
    lot.blueprint = bpId
    if bp.placeholder then lot.placeholder = true end
    if bp.empty then lot.empty = true end
    if bp.spawn then
        lot.spawn = {}
        for n, s in ipairs(bp.spawn) do lot.spawn[n] = { s[1], s[2], s[3] or 0 } end
    end
    return lot, ctx.problems, ctx
end

-- Deterministic signature of the object catalogue (rebuild cached templates when it changes).
local function catalogueSig()
    local n, p = 0, 0
    for id, def in pairs(SS.Objects) do n = n + 1; p = p + (def.price or 0) end
    local f = 0
    for _, t in pairs(SS.Finishes or {}) do if type(t) == "table" then for _ in pairs(t) do f = f + 1 end end end
    return n .. ":" .. p .. ":" .. f
end
HL.cache = HL.cache or {}

-- Cached build: the same blueprint, id and catalogue give the same lot, so each new game deep
-- copies a template instead of re-running placement.
function HL.BuildCached(bpId, id, address)
    local key = bpId .. "|" .. tostring(id) .. "|" .. tostring(address)
    local sig = catalogueSig()
    local c = HL.cache[key]
    if not c or c.sig ~= sig then
        local lot, problems = HL.Build(bpId, id, address)
        c = { sig = sig, lot = lot, problems = problems }
        HL.cache[key] = c
    end
    return SS.U.deepcopy(c.lot), c.problems
end

---------------------------------------------------------------------------
-- Validation (any lot, built or edited). Uses the real engine: World.Rebuild and Nav.FindPath.
---------------------------------------------------------------------------
HL.REQUIRED = { "fridge", "stove", "toilet", "bed" }
HL.MAILBOX_RANGE = 3

-- Run fn(world) against a temporary session of `lot` with SS.RT saved and restored.
function HL.WithLot(root, lot, fn)
    local saved = SS.RT
    local world = setmetatable({ lot = lot, root = root, actors = {}, household = nil },
        { __index = function(_, k) if root then return root[k] end end })
    if world.time == nil then rawset(world, "time", SS.Tuning and SS.Tuning.startTime or 480) end
    local ok, a, b, c = pcall(function()
        SS.World.Rebuild(world)
        return fn(world)
    end)
    SS.RT = saved
    if not ok then return nil, "error: " .. tostring(a) end
    return a, b, c
end

local function kindsPresent(lot)
    local have = {}
    for _, o in pairs(lot.objects) do
        local def = SS.Objects[o.def]
        if def then
            for _, t in ipairs(def.tags or {}) do have[t] = true end
            local b = HL.BASE_KIND[o.def]
            if b then have[b] = true end
        end
    end
    return have
end
HL.KindsPresent = kindsPresent

-- Approach cells (as Nav goals) of every slot of an object, minus approaches cut off from the
-- slot's own cell by a wall.
function HL.SlotGoals(lot, o, def)
    local goals = {}
    local lv = o.level or 0
    for _, sl in pairs(def.slots or {}) do
        local cell = sl.cell or { 0, 0 }
        local cx, cy = G.rot(cell[1], cell[2], o.f)
        cx, cy = o.x + cx, o.y + cy
        for _, ap in ipairs(sl.approaches or {}) do
            local dx, dy = G.rot(ap[1], ap[2], o.f)
            local ai, aj = o.x + dx, o.y + dy
            local okw = true
            if math.abs(ai - cx) + math.abs(aj - cy) == 1 then
                local w2 = lot.walls[lv] and lot.walls[lv][G.edgeBetween(cx, cy, ai, aj)]
                if w2 and not OPEN[w2.kind] then okw = false end
            end
            if okw then goals[#goals + 1] = { ai, aj, lv } end
        end
    end
    return goals
end

-- Returns ok, problems, report { reachable = n, fixtures = n, mailbox = oid }.
function HL.ValidateLot(lot, root, opts)
    opts = opts or {}
    local problems, report = {}, { fixtures = 0, unusable = {} }
    if type(lot) ~= "table" or not lot.entry then return false, { "lot has no entry" }, report end
    local res, err = HL.WithLot(root, lot, function(world)
        local W, Nav = SS.World, SS.Nav
        local e = lot.entry
        if e[2] ~= lot.h - 1 then problems[#problems + 1] = "entry is not on the street row" end
        if W.Blocked(world, 0, e[1], e[2]) then problems[#problems + 1] = "entry cell is blocked"; return end
        local function reach(goals)
            local path = Nav.FindPath(world, e[1], e[2], 0, goals)
            return path ~= nil
        end
        -- front door: both sides reachable from the entry
        if lot.kind == "residential" and not lot.empty then
            local fd = lot.frontDoor
            local wl = fd and lot.walls[0][fd]
            if not wl or not OPEN[wl.kind] then
                problems[#problems + 1] = "no front door"
            else
                local axis, _, _, ai, aj, bi, bj = G.parseEdge(fd)
                if not reach({ { ai, aj, 0 } }) or not reach({ { bi, bj, 0 } }) then problems[#problems + 1] = "front door " .. fd .. " is not reachable from the entry" end
                -- the front door faces the street (row h - 1 side): an "x" edge whose street-side
                -- cell (the larger j) is outdoors
                local outside = W.RoomInfo(0, W.RoomAt(world, 0, bi, bj))
                if axis ~= "x" or (outside and not outside.outdoor) then problems[#problems + 1] = "front door " .. fd .. " does not face the street" end
            end
        end
        -- every object with slots is usable from at least one reachable approach
        local function usable(o, def)
            local goals = HL.SlotGoals(lot, o, def)
            if #goals > 0 and reach(goals) then return true end
            if def.viewer then
                for _, s in ipairs(HL.ViewerSeats(lot, o)) do
                    local sg = HL.SlotGoals(lot, s, SS.Objects[s.def])
                    if #sg > 0 and reach(sg) then return true end
                end
            end
            return false
        end
        for _, oid in ipairs(sortedKeys(lot.objects)) do
            local o = lot.objects[oid]
            local def = SS.Objects[o.def]
            if def and def.slots and next(def.slots) then
                report.fixtures = report.fixtures + 1
                if not usable(o, def) then
                    report.unusable[#report.unusable + 1] = oid .. " (" .. o.def .. ")"
                end
            end
        end
        if #report.unusable > 0 then problems[#problems + 1] = "unreachable fixtures: " .. table.concat(report.unusable, ", ") end
        -- stairs: both ends reachable
        for _, st in ipairs(SS.RT.stairs or {}) do
            if not reach({ { st.bottom[1], st.bottom[2], st.level } }) then problems[#problems + 1] = "stairs " .. st.id .. " bottom unreachable" end
            if not reach({ { st.top[1], st.top[2], st.level + 1 } }) then problems[#problems + 1] = "stairs " .. st.id .. " top unreachable" end
        end
        -- mailbox by the entry
        local mb
        for _, oid in ipairs(sortedKeys(lot.objects)) do
            local o = lot.objects[oid]
            if HL.IsKind(o.def, "mailbox") and (o.level or 0) == 0 then
                local d = math.abs(o.x - e[1]) + math.abs(o.y - e[2])
                if d <= HL.MAILBOX_RANGE and (not mb or d < mb.d) then mb = { id = oid, d = d } end
            end
        end
        if lot.kind == "residential" then
            if not mb then problems[#problems + 1] = "no mailbox within " .. HL.MAILBOX_RANGE .. " cells of the entry" else report.mailbox = mb.id end
        end
        -- needed fixtures for a furnished home
        if lot.kind == "residential" and not lot.empty and opts.furnished ~= false then
            local have = kindsPresent(lot)
            for _, k in ipairs(HL.REQUIRED) do
                if not have[k] then problems[#problems + 1] = "missing " .. k end
            end
            if not (have.shower or have.bath) then problems[#problems + 1] = "missing shower or bath" end
        end
        -- rooms computed (upstairs floor exists => at least one upper room or outdoor area)
        report.rooms0 = 0
        for id, r in pairs(SS.RT.rooms[0] or {}) do if not r.outdoor then report.rooms0 = report.rooms0 + 1 end end
        report.rooms1 = 0
        for id, r in pairs(SS.RT.rooms[1] or {}) do if not r.outdoor then report.rooms1 = report.rooms1 + 1 end end
        return true
    end)
    if res == nil then problems[#problems + 1] = "World.Rebuild or navigation failed: " .. tostring(err) end
    return #problems == 0, problems, report
end

-- Beds and how many they sleep on a lot.
function HL.BedCapacity(lot)
    local n = 0
    for _, o in pairs(lot.objects or {}) do
        local def = SS.Objects[o.def]
        if def and (HL.IsKind(o.def, "bed") or HL.IsKind(o.def, "bed_child")) then n = n + HL.Sleeps(def) end
    end
    return n
end

-- Human-readable ASCII plan of a lot level (debugging and the test log).
function HL.Ascii(lot, lv)
    lv = lv or 0
    local rows = {}
    local occ = {}
    for oid, o in pairs(lot.objects) do
        local def = SS.Objects[o.def]
        if def and (o.level or 0) == lv then
            for _, c in ipairs(footprint(def, o.x, o.y, o.f)) do
                if inLot(lot, c[1], c[2]) then occ[idx(lot, c[1], c[2])] = def.stairs and "S" or (HL.NonBlocking(def, o) and "+" or "#") end
            end
        end
    end
    for j = 0, lot.h - 1 do
        local s = {}
        for i = 0, lot.w - 1 do
            local k = idx(lot, i, j)
            local ch = occ[k] or (lot.pool and lv == 0 and lot.pool[k] and "~") or (lot.floor[lv][k] and ".") or " "
            local wr = lot.walls[lv]["y:" .. (i + 1) .. ":" .. j]
            s[#s + 1] = ch .. (wr and (wr.kind == "door" and "D" or wr.kind == "window" and "W" or wr.kind == "arch" and "A" or wr.kind == "railing" and "r" or wr.kind == "fence" and "f" or "|") or " ")
        end
        local b = {}
        for i = 0, lot.w - 1 do
            local wb = lot.walls[lv]["x:" .. i .. ":" .. (j + 1)]
            b[#b + 1] = (wb and (wb.kind == "door" and "D" or wb.kind == "window" and "W" or wb.kind == "arch" and "A" or wb.kind == "railing" and "r" or wb.kind == "fence" and "f" or "-") or " ") .. " "
        end
        rows[#rows + 1] = table.concat(s)
        rows[#rows + 1] = table.concat(b)
    end
    return table.concat(rows, "\n")
end
