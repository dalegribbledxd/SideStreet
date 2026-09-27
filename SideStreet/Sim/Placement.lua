-- Object placement for buy mode: validation with reasons, buy/move/rotate/sell/store/place-from-
-- inventory/eyedropper, parents and children (items on surfaces), all through SS.Undo transactions.
-- Owner: catalogue module. Notes: docs/modules/catalogue.md ("Placement").
--
-- Object record (ARCHITECTURE.md §5): { id, def, x, y, f, level, variant, state, parent, pslot,
--   bought, paid, used, wear, dirt }. Wall/window mounts sit in the cell in front of the wall edge
--   they hang on: the wall is behind the object (local -y edge of each footprint cell). Items on a
--   surface keep parent = oid and pslot = "n:k" (surface n, slot k of the parent's definition) and
--   share the parent's cell and level; P.SurfacePos gives their exact position and height.
-- Money: every action moves money at most once through SS.Money and records tx.cost for undo;
--   nothing is charged when SS.Build.IsFree(world) (community editing, sandbox money).
-- Events: after every change lot.version is bumped, SS.World.Rebuild runs and
--   SS.Emit("lotChanged", "object", oid) fires. "objectPlaced"/"objectRemoved" carry details.
local _, SS = ...
local G, W, C, U = SS.Grid, SS.World, SS.Catalog, SS.U
local P = {}
SS.Placement = P

P.DAY = 1440   -- minutes: a sale on the same calendar day as the purchase, before first use, refunds in full

local function fmt(v) return U.fmtMoney(v) end
local function idx(lot, i, j) return j * lot.w + i + 1 end
local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

function P.IsFree(world)
    if not world.household then return true end
    return (SS.Build and SS.Build.IsFree and SS.Build.IsFree(world)) and true or false
end
local function sandbox(world)
    local s = world.settings or {}
    return (s.sandbox or s.sandboxMoney) and true or false
end
P.Sandbox = sandbox

-- Whole-cell coordinates from what a caller passed (numbers, not NaN or huge). Returns x, y, f,
-- level (f wrapped to 0..3, level defaulting to 0), or nil when they are not a place on a lot.
local function num(v) return type(v) == "number" and v == v and v > -1e6 and v < 1e6 end
function P.Coords(x, y, f, level)
    if not (num(x) and num(y)) or (f ~= nil and not num(f)) or (level ~= nil and not num(level)) then return nil end
    return math.floor(x), math.floor(y), math.floor(f or 0) % 4, math.floor(level or 0)
end
P.BAD_SPOT = "That is not a place on the lot."

-- The lot entrance cell (ARCHITECTURE.md §5: lot.entry = { i, j }; the named { i =, j = } form is
-- read too). Returns i, j, or nil when the lot has none inside it.
function P.EntryCell(lot)
    local e = lot and lot.entry
    if type(e) ~= "table" then return nil end
    local i, j = e[1] or e.i, e[2] or e.j
    if not (num(i) and num(j)) then return nil end
    i, j = math.floor(i), math.floor(j)
    if not W.InLot(lot, i, j) then return nil end
    return i, j
end

-- May furniture on this lot go to (or come from) the household inventory? Only in the played
-- household's own home: never while a venue or an unowned lot is edited from the neighbourhood
-- (world.editVenue / world.editSession: the played household is only the viewer there), never on a
-- community lot, never on someone else's lot. Returns ok, why.
function P.InventoryHere(world)
    local hh = world and world.household
    if not (hh and world.lot) then return false, "There is no household here to keep it." end
    if world.editVenue or world.editSession then
        return false, "Nothing here goes to the household inventory: this lot is edited for free and its furniture stays on it."
    end
    if world.lot.kind == "community" then return false, "Furniture on a community lot stays there." end
    if hh.lotId and hh.lotId ~= world.lot.id then return false, "Only furniture in the household's own home can be stored." end
    return true
end

-- New object id, unique on this lot ("o<n>", shared counter lot.nextObj).
function P.NewId(lot)
    local n = tonumber(lot.nextObj) or tonumber(lot.nextId) or 1
    local id = "o" .. n
    while lot.objects[id] do n = n + 1; id = "o" .. n end
    lot.nextObj = n + 1
    return id
end

-- After any change: version, derived caches, event.
local function touch(world, oid)
    local lot = world.lot
    lot.version = (lot.version or 0) + 1
    W.Rebuild(world)
    if SS.UI then SS.UI.dirty = true end
    SS.Emit("lotChanged", "object", oid)
end
P.Touch = touch

---------------------------------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------------------------------
-- World cells of a design at (x, y) facing f: { { i, j, dx, dy }, ... } and a set idx -> true.
function P.Cells(def, x, y, f, lot)
    local out, set = {}, {}
    for n, c in ipairs(def.fp or { { 0, 0 } }) do
        local dx, dy = G.rot(c[1], c[2], f or 0)
        out[n] = { i = x + dx, j = y + dy, dx = c[1], dy = c[2] }
        if lot then set[idx(lot, x + dx, y + dy)] = true end
    end
    return out, set
end

-- The wall edge behind a cell for an object facing f (the object's local -y side).
function P.BackEdge(i, j, f)
    local bx, by = G.rot(0, -1, f or 0)
    return G.edgeBetween(i, j, i + bx, j + by), i + bx, j + by
end

-- Exact position of an object (items on surfaces: at the slot, at the surface height).
-- Returns x, y (continuous tiles) and z (tiles above level 0 ground).
function P.SurfacePos(world, o)
    local lvz = (o.level or 0) * W.STORY
    local p = o.parent and world.lot.objects[o.parent]
    local pdef = p and SS.Objects[p.def]
    local s = pdef and C.SurfaceSlot(pdef, o.pslot)
    if not s then return o.x + 0.5, o.y + 0.5, lvz end
    local ox, oy = G.rot(s.cell[1] + s.off[1], s.cell[2] + s.off[2], p.f or 0)
    return p.x + 0.5 + ox, p.y + 0.5 + oy, (p.level or 0) * W.STORY + s.z
end

-- Children resting on an object's surfaces, sorted by slot key then id.
function P.Children(world, oid)
    local out = {}
    for id, o in pairs(world.lot.objects) do if o.parent == oid then out[#out + 1] = id end end
    table.sort(out, function(a, b)
        local pa, pb = world.lot.objects[a].pslot or "", world.lot.objects[b].pslot or ""
        if pa ~= pb then return pa < pb end
        return a < b
    end)
    return out
end

---------------------------------------------------------------------------------------------------
-- Chair-to-table pairing (brief §8.3). A chair (a one-cell floor seat: dining, desk, stool, outdoor)
-- pairs with the table, desk or counter its front faces: the cell in front of it is covered by a
-- surface of kind table/desk/counter on the same level. household-core seats diners and workers at
-- paired chairs (P.PairedTable); buy mode turns a new chair to face the table it is placed beside.
---------------------------------------------------------------------------------------------------
P.PAIR_SUBS = { dining = true, desk = true, stool = true, outdoor = true }
P.PAIR_SURFACES = { table = true, desk = true, counter = true }

function P.IsChair(def)
    if not def or def.mount ~= "floor" or #(def.fp or {}) > 1 then return false end
    local sl = def.slots and def.slots.seat
    return (sl and sl.on and C.Has(def, "seat") and (P.PAIR_SUBS[def.sub or ""] or def.pairs)) and true or false
end

-- The object (and surface slot key) with a pairing surface over cell (i, j) on `level`.
local function pairSurfaceAt(world, level, i, j, ignore)
    for _, oid in ipairs(sortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and def.surfaces and not o.parent and (o.level or 0) == level and not (ignore and ignore[oid]) then
            for _, s in ipairs(C.SurfaceSlots(def)) do
                if P.PAIR_SURFACES[s.kind] then
                    local dx, dy = G.rot(s.cell[1], s.cell[2], o.f or 0)
                    if o.x + dx == i and o.y + dy == j then return oid, s.key end
                end
            end
        end
    end
end

-- The table a placed chair faces, if any: oid, surface slot key.
function P.PairedTable(world, oid)
    local o = world.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not P.IsChair(def) or o.parent then return nil end
    local fx, fy = G.rot(0, 1, o.f or 0)
    return pairSurfaceAt(world, o.level or 0, o.x + fx, o.y + fy)
end

-- Chairs paired with a table (sorted ids).
function P.Pairs(world, tableOid)
    local out = {}
    for _, oid in ipairs(sortedKeys(world.lot.objects)) do
        if oid ~= tableOid and P.PairedTable(world, oid) == tableOid then out[#out + 1] = oid end
    end
    return out
end

-- Facing that turns a chair at (x, y) toward an adjacent table/desk/counter, or nil. `pref` wins
-- when it already faces one; otherwise the first of front, left, back, right in facing order.
function P.AutoFacing(world, def, x, y, level, pref, ignore)
    if not P.IsChair(def) then return nil end
    level = level or 0
    local function faces(f)
        local fx, fy = G.rot(0, 1, f)
        return pairSurfaceAt(world, level, x + fx, y + fy, ignore) ~= nil
    end
    if pref and faces(pref % 4) then return pref % 4 end
    for f = 0, 3 do if faces(f) then return f end end
end

---------------------------------------------------------------------------------------------------
-- Occupancy index (built on demand; lots are small). Per level:
--   block[idx]  blocking floor objects      pad[idx]   walk-on floor pieces that are not rugs
--   rug[idx]    rugs (layer freely)          ceil[idx]  ceiling fixtures
--   wallFace["edge@i,j"] / winFace[...]      wall/window mounts on that side of that edge
--   surf[idx] = { parent oids with a surface over that cell }     kids[parent][pslot] = child oid
---------------------------------------------------------------------------------------------------
function P.Index(world, ignore)
    local lot = world.lot
    ignore = ignore or {}
    local ix = { block = {}, pad = {}, rug = {}, ceil = {}, wallFace = {}, winFace = {}, surf = {}, kids = {} }
    for l = 0, W.LEVELS - 1 do
        ix.block[l], ix.pad[l], ix.rug[l], ix.ceil[l], ix.wallFace[l], ix.winFace[l], ix.surf[l] = {}, {}, {}, {}, {}, {}, {}
    end
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and not ignore[oid] then
            local lv = o.level or 0
            if lv < 0 or lv >= W.LEVELS then lv = 0 end
            if o.parent then
                ix.kids[o.parent] = ix.kids[o.parent] or {}
                ix.kids[o.parent][o.pslot or "?"] = oid
            elseif def.mount == "wall" or def.mount == "window" then
                local faces = def.mount == "wall" and ix.wallFace[lv] or ix.winFace[lv]
                for _, c in ipairs(P.Cells(def, o.x, o.y, o.f)) do
                    faces[P.BackEdge(c.i, c.j, o.f) .. "@" .. c.i .. "," .. c.j] = oid
                end
            elseif def.mount == "ceiling" then
                for _, c in ipairs(P.Cells(def, o.x, o.y, o.f)) do
                    if W.InLot(lot, c.i, c.j) then ix.ceil[lv][idx(lot, c.i, c.j)] = oid end
                end
            elseif def.mount ~= "surface" then
                local layer = def.rug and ix.rug[lv] or (def.noBlock and ix.pad[lv]) or ix.block[lv]
                for _, c in ipairs(P.Cells(def, o.x, o.y, o.f)) do
                    if W.InLot(lot, c.i, c.j) then layer[idx(lot, c.i, c.j)] = oid end
                end
            end
            if def.surfaces and not o.parent then
                for _, s in ipairs(C.SurfaceSlots(def)) do
                    local dx, dy = G.rot(s.cell[1], s.cell[2], o.f or 0)
                    local i, j = o.x + dx, o.y + dy
                    if W.InLot(lot, i, j) then
                        local k = idx(lot, i, j)
                        local list = ix.surf[lv][k] or {}
                        ix.surf[lv][k] = list
                        local have = false
                        for _, p in ipairs(list) do if p == oid then have = true end end
                        if not have then list[#list + 1] = oid end
                    end
                end
            end
        end
    end
    return ix
end

---------------------------------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------------------------------
local function nameOf(world, oid)
    local o = oid and world.lot.objects[oid]
    local d = o and SS.Objects[o.def]
    return d and d.name or "something"
end

-- Can people stand on (and walk through) cell (i, j) of `level`? `ix` is the occupancy index; exSet
-- (idx -> true) are extra blocking cells on exLevel (the object being placed). Walls are edges and
-- are checked by stepOK, not here.
local function openCell(world, ix, level, i, j, exLevel, exSet)
    local lot = world.lot
    if not W.InLot(lot, i, j) then return false end
    local k = idx(lot, i, j)
    if level > 0 then
        if not W.FloorAt(lot, level, i, j) then return false end
        if SS.RT.well and SS.RT.well[level] and SS.RT.well[level][k] then return false end
    elseif lot.pool and lot.pool[k] then
        return false
    end
    if ix.block[level][k] then return false end
    if exSet and exLevel == level and exSet[k] then return false end
    -- diagonal wall cells and ponds (build module, docs/requests/build.md R-CAT-1), solid build cells
    if SS.Build and SS.Build.CellBlocked and SS.Build.CellBlocked(world, level, i, j) then return false end
    local hooks = W.blockedHooks
    if hooks then for n = 1, #hooks do if hooks[n](world, level, i, j) then return false end end end
    return true
end

-- A cell an actor could stand on at this level (ignoring the new object unless selfWalk).
local function standable(world, ix, level, i, j, newSet, selfWalk)
    return openCell(world, ix, level, i, j, level, (not selfWalk) and newSet or nil)
end

-- May people step between two 4-adjacent cells of a level? (walls and windows no, doorways yes)
local function stepOK(world, level, i, j, ni, nj)
    if W.CanStepStatic then return W.CanStepStatic(world, level, i, j, ni, nj) and true or false end
    local wl = W.WallAt(world.lot, level, G.edgeBetween(i, j, ni, nj))
    return (not wl or W.OPENINGS[wl.kind]) and true or false
end

-- While a community venue is edited from the neighbourhood (world.editVenue), only designs that make
-- sense in a public place are sold: SS.Venues.CatalogFilter (outings) decides; without it, venue
-- equipment plus the ordinary furnishing categories, never beds, cribs, children's or pet items.
P.VENUE_CATS = { community = true, seating = true, surfaces = true, lighting = true, decor = true, outdoor = true,
    plumbing = true, kitchen = true, skill = true, electronics = true, storage = true }
function P.VenueOK(world, def)
    if type(def) == "string" then def = SS.Objects[def] end
    if not (world and world.editVenue and world.lot and world.lot.kind == "community") or not def or sandbox(world) then return true end
    local ok
    if SS.Venues and SS.Venues.CatalogFilter then ok = SS.Venues.CatalogFilter(def)
    else ok = def.community or (not def.kidOnly and not def.pet and P.VENUE_CATS[def.cat] == true) end
    if ok then return true end
    return false, (def.name or "That") .. " is not sold for public venues."
end

-- Can someone on approach cell (ai, aj) reach the object? `targets` = cells they use (the slot's cell
-- for on-slots, every footprint cell otherwise). Adjacent across a solid wall = no.
local function reaches(world, level, ai, aj, targets)
    local adjacent = false
    for _, c in ipairs(targets) do
        local d = math.abs(ai - c.i) + math.abs(aj - c.j)
        if d == 0 then return true end
        if d == 1 then
            adjacent = true
            local wl = W.WallAt(world.lot, level, G.edgeBetween(ai, aj, c.i, c.j))
            if not wl or W.OPENINGS[wl.kind] then return true end
        end
    end
    return not adjacent
end

-- Approach cells of one slot of an object at (x, y, f), each { i, j, ok }.
local function slotApproaches(world, ix, level, def, x, y, f, sl, cells, newSet)
    local targets = cells
    if sl.on then
        local sc = sl.cell or { 0, 0 }
        local dx, dy = G.rot(sc[1], sc[2], f)
        targets = { { i = x + dx, j = y + dy } }
    end
    local out = {}
    for _, a in ipairs(sl.approaches or {}) do
        local dx, dy = G.rot(a[1], a[2], f)
        local i, j = x + dx, y + dy
        local ok = standable(world, ix, level, i, j, newSet, def.noBlock) and reaches(world, level, i, j, targets)
        out[#out + 1] = { i = i, j = j, ok = ok }
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Reachability (brief §4: approach cells are never permanently blocked, doors keep a clear entry,
-- the entrance stays accessible). A 4-neighbour flood fill over the cells people can stand on,
-- through doorways and up and down stairs, from the lot entrance (the street row when the lot has
-- none), the way SS.Nav's static regions see the lot: walls, blocking furniture, missing floor,
-- stairwells, water and solid build cells; no locks and no people. A blocking floor object is
-- refused when it cuts off something that could be reached before it went down: a side of a
-- doorway, where a resident stands, the last usable approach of any object, or its own approaches.
-- Things that were already out of reach (a room still without a door) are not held against it.
-- Scratch arrays are stamped and reused; the "before" fill is cached per lot version.
---------------------------------------------------------------------------------------------------
local RS = { before = {}, after = {}, queue = {}, sb = 0, sa = 0 }

local function flood(world, ix, exLevel, exSet, seen, stamp)
    local lot = world.lot
    local w, plane = lot.w, lot.w * lot.h
    local q, qn, qh = RS.queue, 0, 1
    local function push(l, i, j)
        if not W.InLot(lot, i, j) then return end
        local key = l * plane + j * w + i
        if seen[key] ~= stamp and openCell(world, ix, l, i, j, exLevel, exSet) then
            seen[key] = stamp
            qn = qn + 1
            q[qn] = key
        end
    end
    local ei, ej = P.EntryCell(lot)
    if ei then push(0, ei, ej) end
    if qn == 0 then for i = 0, lot.w - 1 do push(0, i, lot.h - 1) end end
    local stairs = SS.RT.stairs or {}
    while qh <= qn do
        local key = q[qh]
        qh = qh + 1
        local l = math.floor(key / plane)
        local r = key - l * plane
        local j = math.floor(r / w)
        local i = r - j * w
        for d = 0, 3 do
            local dv = G.DIRS[d]
            local ni, nj = i + dv[1], j + dv[2]
            if W.InLot(lot, ni, nj) and seen[l * plane + nj * w + ni] ~= stamp and stepOK(world, l, i, j, ni, nj) then push(l, ni, nj) end
        end
        for n = 1, #stairs do
            local st = stairs[n]
            local sl = st.level or 0
            if sl == l and st.bottom[1] == i and st.bottom[2] == j and sl + 1 < W.LEVELS then push(sl + 1, st.top[1], st.top[2])
            elseif sl + 1 == l and st.top[1] == i and st.top[2] == j then push(sl, st.bottom[1], st.bottom[2]) end
        end
    end
end

local function reached(seen, stamp, lot, l, i, j)
    return W.InLot(lot, i, j) and seen[l * lot.w * lot.h + j * lot.w + i] == stamp
end

-- The lot as it is now (cached per lot version): the fill, its doorway cells, and which slots of
-- which objects are usable (some approach cell standable, reachable and not across a wall).
local function beforeState(world)
    local lot = world.lot
    local c = RS.cache
    if c and c.lot == lot and c.version == lot.version and c.rt == SS.RT then return c end
    RS.sb = RS.sb + 1
    local ix = P.Index(world)
    flood(world, ix, nil, nil, RS.before, RS.sb)
    c = { lot = lot, version = lot.version, rt = SS.RT, stamp = RS.sb, ix = ix, doors = {}, usable = {} }
    for l = 0, W.LEVELS - 1 do
        local keys = {}
        for key, wl in pairs(lot.walls[l] or {}) do if W.OPENINGS[wl.kind] then keys[#keys + 1] = key end end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local okE, _, _, _, ai, aj, bi, bj = pcall(G.parseEdge, key)
            if okE and ai then
                c.doors[#c.doors + 1] = { l, ai, aj }
                c.doors[#c.doors + 1] = { l, bi, bj }
            end
        end
    end
    RS.cache = c
    return c
end

-- Is slot `sl` of object o usable in a state (index ix + extra blocking cells, fill seen/stamp)?
local function slotUsable(world, ix, o, odef, sl, exLevel, exSet, seen, stamp)
    local lot = world.lot
    local lv = o.level or 0
    local f = o.f or 0
    local targets
    if sl.on then
        local sc = sl.cell or { 0, 0 }
        local dx, dy = G.rot(sc[1], sc[2], f)
        targets = { { i = o.x + dx, j = o.y + dy } }
    else
        targets = P.Cells(odef, o.x, o.y, f)
    end
    for _, a in ipairs(sl.approaches or {}) do
        local dx, dy = G.rot(a[1], a[2], f)
        local i, j = o.x + dx, o.y + dy
        if reached(seen, stamp, lot, lv, i, j) and openCell(world, ix, lv, i, j, exLevel, exSet) and reaches(world, lv, i, j, targets) then
            return true
        end
    end
    return false
end

-- Would blocking cells newSet on `level` cut anything off? Returns nil, or why and the cells at fault.
-- opts.ignore: objects being moved (their old cells are free afterwards, their slots move with them).
local function cutsOff(world, ix, def, x, y, f, level, cells, newSet, opts)
    local lot = world.lot
    local B = beforeState(world)
    local bSeen, bStamp = RS.before, B.stamp
    RS.sa = RS.sa + 1
    local aSeen, aStamp = RS.after, RS.sa
    flood(world, ix, level, newSet, aSeen, aStamp)
    local function lost(l, i, j) return reached(bSeen, bStamp, lot, l, i, j) and not reached(aSeen, aStamp, lot, l, i, j) end
    local function at(list, i, j)
        local out = {}
        for n, c in ipairs(list) do out[n] = c end
        out[#out + 1] = { i = i, j = j }
        return out
    end
    for _, d in ipairs(B.doors) do
        if lost(d[1], d[2], d[3]) then
            return "That would cut a doorway off from the lot entrance: leave a way through.", at(cells, d[2], d[3])
        end
    end
    for _, rid in ipairs(sortedKeys(world.actors or {})) do
        local a = world.actors[rid]
        if a.x and a.y and not a.away and not a.dead then
            local ai, aj = math.floor(a.x), math.floor(a.y)
            if lost(a.level or 0, ai, aj) then
                return (a.name or "Someone") .. " would be shut in there: leave a way out.", at(cells, ai, aj)
            end
        end
    end
    local ignore = opts.ignore or {}
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local odef = SS.Objects[o.def]
        if odef and not ignore[oid] and odef.slots and next(odef.slots) and type(o.x) == "number" and type(o.y) == "number" then
            for _, sname in ipairs(sortedKeys(odef.slots)) do
                local sl = odef.slots[sname]
                local key = oid .. "|" .. sname
                local was = B.usable[key]
                if was == nil then
                    was = slotUsable(world, B.ix, o, odef, sl, nil, nil, bSeen, bStamp)
                    B.usable[key] = was
                end
                if was and not slotUsable(world, ix, o, odef, sl, level, newSet, aSeen, aStamp) then
                    return "That would block the only way to use the " .. (odef.name or "object") .. ".", cells
                end
            end
        end
    end
    -- its own slots: approach cells people could get to before must still be reachable
    local me = { x = x, y = y, f = f, level = level }
    for _, sname in ipairs(sortedKeys(def.slots or {})) do
        local sl = def.slots[sname]
        local couldReach = false
        for _, a in ipairs(sl.approaches or {}) do
            local dx, dy = G.rot(a[1], a[2], f)
            local i, j = x + dx, y + dy
            if reached(bSeen, bStamp, lot, level, i, j) and openCell(world, ix, level, i, j, level, newSet) then couldReach = true end
        end
        if couldReach and not slotUsable(world, ix, me, def, sl, level, newSet, aSeen, aStamp) then
            return "Nobody could get to it there: it would block its own way in.", cells
        end
    end
    return nil
end
P.CutsOff = cutsOff

local function kindsText(list)
    local t = {}
    for _, k in ipairs(list or C.ALL_SURFACES) do t[#t + 1] = k end
    return table.concat(t, "/")
end

-- Surface items: find a free typed slot on a parent at cell (x, y).
local function checkSurface(world, def, x, y, f, level, opts, ix)
    local lot = world.lot
    if not W.InLot(lot, x, y) then return false, "That is outside the lot.", { { x, y } } end
    local cands = ix.surf[level] and ix.surf[level][idx(lot, x, y)] or {}
    local fits = {}
    for _, k in ipairs(def.fits or C.ALL_SURFACES) do fits[k] = true end
    local best, bestD, sawKind, sawFull
    for _, poid in ipairs(cands) do
        if not opts.parent or opts.parent == poid then
            local po = lot.objects[poid]
            local pdef = SS.Objects[po.def]
            for _, s in ipairs(C.SurfaceSlots(pdef)) do
                local dx, dy = G.rot(s.cell[1], s.cell[2], po.f or 0)
                if po.x + dx == x and po.y + dy == y then
                    if fits[s.kind] then
                        sawKind = true
                        local taken = ix.kids[poid] and ix.kids[poid][s.key]
                        if (not opts.pslot or opts.pslot == s.key) and not taken then
                            local d = 0
                            if opts.px and opts.py then
                                local ox, oy = G.rot(s.cell[1] + s.off[1], s.cell[2] + s.off[2], po.f or 0)
                                d = math.abs(po.x + 0.5 + ox - opts.px) + math.abs(po.y + 0.5 + oy - opts.py)
                            end
                            if not bestD or d < bestD then
                                best, bestD = { parent = poid, pslot = s.key, z = s.z, level = po.level or 0, parentName = pdef.name }, d
                            end
                        else
                            sawFull = true
                        end
                    end
                end
            end
        end
    end
    if best then return true, nil, {}, best end
    if sawFull then return false, "That surface is full: move something off it first.", { { x, y } } end
    if #cands > 0 then return false, def.name .. " only fits on a " .. kindsText(def.fits) .. " surface.", { { x, y } } end
    return false, def.name .. " goes on a " .. kindsText(def.fits) .. " surface: point at a counter, table, desk or shelf.", { { x, y } }
end

-- Validate placing `def` at (x, y) facing f on `level`.
-- opts: { ignore = {oid=true}, price = n (check affordability), parent, pslot, px, py (cursor, for
--         choosing a surface slot), index }
-- Returns ok, why, blocked (list of {i, j}), info { level, parent, pslot, z, cells, approaches }.
function P.Check(world, def, x, y, f, level, opts)
    opts = opts or {}
    local lot = world.lot
    local blocked = {}
    local function fail(why, list)
        for _, c in ipairs(list or {}) do blocked[#blocked + 1] = { c.i or c[1], c.j or c[2] } end
        return false, why, blocked
    end
    x, y, f, level = P.Coords(x, y, f, level)
    if not x then return fail(P.BAD_SPOT) end
    if type(def) == "string" then def = SS.Objects[def] end
    if not def then return fail("That design does not exist.") end
    if def.stairs then return fail("Stairs are placed with the stairs tool in build mode.") end
    if def.community and lot.kind ~= "community" and not sandbox(world) then
        return fail(def.name .. " is venue equipment: edit a community lot from the neighbourhood to install it.")
    end
    local okVenue, venueWhy = P.VenueOK(world, def)
    if not okVenue then return fail(venueWhy) end
    if level < 0 or level >= W.LEVELS then return fail("There is no such floor level.") end
    if def.groundOnly and level > 0 then return fail(def.name .. " has to stand on the ground floor.") end
    if opts.price and opts.price > (world.money or 0) then
        return fail("It costs " .. fmt(opts.price) .. "; the household only has " .. fmt(world.money or 0) .. ".")
    end
    local ix = opts.index or P.Index(world, opts.ignore)
    if def.mount == "surface" then
        local ok, why, bl, info = checkSurface(world, def, x, y, f, level, opts, ix)
        if not ok then return fail(why, bl) end
        info.cells = { { i = x, j = y } }
        info.approaches = {}
        for _, sname in ipairs(sortedKeys(def.slots or {})) do
            for _, a in ipairs(slotApproaches(world, ix, info.level, def, x, y, f, def.slots[sname], info.cells, nil)) do
                info.approaches[#info.approaches + 1] = a
            end
        end
        return true, nil, blocked, info
    end
    local cells, newSet = P.Cells(def, x, y, f, lot)
    -- in the lot, on a floor, not in a stairwell, on flat ground, not in the pool
    local bad = {}
    for _, c in ipairs(cells) do if not W.InLot(lot, c.i, c.j) then bad[#bad + 1] = c end end
    if #bad > 0 then return fail("Part of it would stick out past the lot boundary.", bad) end
    for _, c in ipairs(cells) do
        local k = idx(lot, c.i, c.j)
        if level > 0 and not W.FloorAt(lot, level, c.i, c.j) then bad[#bad + 1] = c end
        if SS.RT.well and SS.RT.well[level] and SS.RT.well[level][k] then return fail("That is the stairwell: nothing can stand over the stairs.", { c }) end
    end
    if #bad > 0 then return fail("There is no floor there on this level; add floor tiles in build mode first.", bad) end
    if level == 0 then
        for _, c in ipairs(cells) do
            if SS.Terrain and SS.Terrain.Flat and not SS.Terrain.Flat(world, c.i, c.j) then bad[#bad + 1] = c end
        end
        if #bad > 0 then return fail("The ground slopes there; level it with the terrain tool first.", bad) end
        for _, c in ipairs(cells) do if lot.pool and lot.pool[idx(lot, c.i, c.j)] then bad[#bad + 1] = c end end
        if #bad > 0 then return fail("It cannot go in the pool.", bad) end
    end
    -- the build module's own refusals for anything standing on the floor: ponds, diagonal wall cells,
    -- pool ladder landings (and its terrain and pool rules again, with its wording)
    if def.mount == "floor" and SS.Build and SS.Build.CanOccupy then
        for _, c in ipairs(cells) do
            local ok, why = SS.Build.CanOccupy(world, level, c.i, c.j)
            if not ok then return fail(why or "Nothing can stand there.", { c }) end
        end
    end
    if def.outdoor then
        for _, c in ipairs(cells) do if W.RoomAt(world, level, c.i, c.j) ~= 0 then bad[#bad + 1] = c end end
        if #bad > 0 then return fail(def.name .. " belongs outdoors.", bad) end
    end
    -- a multi-tile object must not straddle a wall (or fence, door, window)
    for a = 1, #cells do
        for b = a + 1, #cells do
            local ca, cb = cells[a], cells[b]
            if math.abs(ca.i - cb.i) + math.abs(ca.j - cb.j) == 1 and W.WallAt(lot, level, G.edgeBetween(ca.i, ca.j, cb.i, cb.j)) then
                return fail("It would straddle a wall; find a clear stretch of floor.", { ca, cb })
            end
        end
    end
    local mount = def.mount
    if mount == "wall" or mount == "window" then
        for _, c in ipairs(cells) do
            local key = P.BackEdge(c.i, c.j, f)
            local wl = W.WallAt(lot, level, key)
            local face = key .. "@" .. c.i .. "," .. c.j
            if mount == "wall" then
                if not (wl and wl.kind == "wall") then return fail(def.name .. " needs a solid wall behind it (not a door, window or fence).", { c }) end
                if ix.wallFace[level][face] then return fail(nameOf(world, ix.wallFace[level][face]) .. " already hangs there.", { c }) end
            else
                if not (wl and wl.kind == "window") then return fail(def.name .. " has to hang at a window.", { c }) end
                if ix.winFace[level][face] then return fail("That window already has " .. nameOf(world, ix.winFace[level][face]) .. " on this side.", { c }) end
                local room = W.RoomAt(world, level, c.i, c.j)
                if def.outdoor and room ~= 0 then return fail(def.name .. " goes on the outside of a window.", { c }) end
                if not def.outdoor and room == 0 then return fail(def.name .. " hangs on the inside of a window, in a room.", { c }) end
            end
        end
    elseif mount == "ceiling" then
        for _, c in ipairs(cells) do
            local k = idx(lot, c.i, c.j)
            local covered = W.RoomAt(world, level, c.i, c.j) > 0 or (level + 1 < W.LEVELS and W.FloorAt(lot, level + 1, c.i, c.j) ~= nil)
            if not covered then return fail("Ceiling lights need a ceiling: an indoor room, or an upper floor above.", { c }) end
            if ix.ceil[level][k] then return fail(nameOf(world, ix.ceil[level][k]) .. " is already on the ceiling there.", { c }) end
        end
    else
        -- floor: blocking pieces and walk-on pads need free cells; rugs layer over anything
        if not def.rug then
            for _, c in ipairs(cells) do
                local k = idx(lot, c.i, c.j)
                local other = ix.block[level][k] or ix.pad[level][k]
                if other then bad[#bad + 1] = c; bad.name = bad.name or nameOf(world, other) end
            end
            if #bad > 0 then return fail(bad.name .. " is in the way.", bad) end
        end
        if def.wallBack then
            for _, c in ipairs(cells) do
                if not C.FootSet(def)[c.dx .. "," .. (c.dy - 1)] then
                    local wl = W.WallAt(lot, level, P.BackEdge(c.i, c.j, f))
                    if not (wl and wl.kind == "wall") then return fail(def.name .. " must stand with its back against a solid wall.", { c }) end
                end
            end
        end
        if not def.noBlock then
            -- doorways, the lot entrance and stair landings stay clear
            local ei, ej = P.EntryCell(lot)
            for _, c in ipairs(cells) do
                for d = 0, 3 do
                    local dir = G.DIRS[d]
                    local wl = W.WallAt(lot, level, G.edgeBetween(c.i, c.j, c.i + dir[1], c.j + dir[2]))
                    if wl and W.OPENINGS[wl.kind] then return fail("Keep the " .. (wl.kind == "gate" and "gateway" or "doorway") .. " clear.", { c }) end
                end
                if level == 0 and c.i == ei and c.j == ej then return fail("Keep the lot entrance clear so visitors can arrive.", { c }) end
                for _, st in ipairs(SS.RT.stairs or {}) do
                    if (st.level == level and st.bottom[1] == c.i and st.bottom[2] == c.j) or (st.level + 1 == level and st.top[1] == c.i and st.top[2] == c.j) then
                        return fail("Keep the stair landing clear.", { c })
                    end
                end
            end
            for _, rid in ipairs(sortedKeys(world.actors or {})) do
                local a = world.actors[rid]
                if (a.level or 0) == level and a.x and newSet[idx(lot, math.floor(a.x), math.floor(a.y))] and not a.away then
                    return fail((a.name or "Someone") .. " is standing there.", { { i = math.floor(a.x), j = math.floor(a.y) } })
                end
            end
        end
    end
    -- the new object's own slots: every slot keeps at least one usable approach cell
    local approaches = {}
    for _, sname in ipairs(sortedKeys(def.slots or {})) do
        local list = slotApproaches(world, ix, level, def, x, y, f, def.slots[sname], cells, newSet)
        local any = false
        for _, a in ipairs(list) do approaches[#approaches + 1] = a; if a.ok then any = true end end
        if not any then return fail("Nobody could get to it: clear a space where people stand to use it.", list) end
    end
    -- and nothing that people could get to before may be cut off: doorways, residents, other
    -- objects' last way in, its own way in (blocking floor pieces only: nothing else changes where
    -- people can walk)
    if mount ~= "wall" and mount ~= "window" and mount ~= "ceiling" and not def.rug and not def.noBlock then
        local why, cut = cutsOff(world, ix, def, x, y, f, level, cells, newSet, opts)
        if why then return fail(why, cut) end
    end
    return true, nil, blocked, { level = level, cells = cells, approaches = approaches }
end

---------------------------------------------------------------------------------------------------
-- Use, value, transactions
---------------------------------------------------------------------------------------------------
-- The resident using an object (or one of `oids`) right now, if any.
local function userOf(world, oids)
    for _, rid in ipairs(sortedKeys(world.actors or {})) do
        local a = world.actors[rid]
        if a.onObj and oids[a.onObj] then return a end
        local act = a.act
        local t = act and ((act.target and act.target.oid) or act.oid)
        local v = act and act.target and act.target.viewer
        if act and ((t and oids[t]) or (v and oids[v])) and (act.phase == "perform" or act.phase == "enter" or act.phase == "exit") then return a end
    end
end
-- Residents still walking to an object give up (the object is about to move or go).
local function cancelWalkers(world, oids)
    for _, rid in ipairs(sortedKeys(world.actors or {})) do
        local a = world.actors[rid]
        local act = a.act
        local t = act and ((act.target and act.target.oid) or act.oid)
        if t and oids[t] and SS.Actions and SS.Actions.Cancel then pcall(SS.Actions.Cancel, world, a) end
    end
end

-- Build pieces (stairs, columns, outdoor steps, pool ladders) belong to build mode: buy mode never
-- picks them up, sells or stores them.
function P.BuildPiece(def)
    return def and (def.stairs or def.column or def.steps or def.poolLadder or def.buildPiece or def.cat == "build_stairs") and true or false
end

-- Can this placed object be sold or stored from buy mode? System objects that come with the lot
-- (mailbox, memorials and other non-buyable fixtures) cannot. Returns ok, why.
function P.CanSell(world, oid)
    local o = world.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return false, "That object is no longer here." end
    if P.BuildPiece(def) then return false, "Use build mode for the " .. def.name .. "." end
    if def.buyable == false and not o.paid then return false, "The " .. def.name .. " belongs to the lot; it can be moved but not sold or stored." end
    -- a venue must keep its required staff posts and service points (outings, docs/requests/outings.md CA-2)
    if world.lot.kind == "community" and SS.Venues and SS.Venues.CanRemove and not sandbox(world) then
        local ok, why = SS.Venues.CanRemove(world, o)
        if not ok then return false, why or "The venue needs this to stay open." end
    end
    return true
end

-- Same calendar day as the purchase and never used: the full price comes back.
function P.FullRefund(world, o)
    local t = world.time or 0
    return o.bought ~= nil and not o.used and t >= o.bought and math.floor(o.bought / P.DAY) == math.floor(t / P.DAY)
end

-- What one object sells for now (disclosed before selling). Something that cost nothing (paid = 0:
-- bought while editing for free, a gift from the game) sells for nothing.
function P.SellValue(world, o)
    local def = type(o) == "table" and SS.Objects[o.def]
    if not def or def.buyable == false and not o.paid then return 0 end
    local base = tonumber(o.paid) or def.price or 0
    if base <= 0 then return 0 end
    if P.FullRefund(world, o) then return math.floor(base) end
    -- careers' SS.Economy.ResaleValue decides (age, damage, def.appreciates); without it: 80% of what
    -- was paid, and original art (def.appreciates) keeps its value
    local v = SS.Economy and SS.Economy.ResaleValue and SS.Economy.ResaleValue(world, o)
        or (def.appreciates and math.floor(base)) or math.floor(base * 0.8)
    return math.max(0, math.floor(tonumber(v) or 0))
end

-- What the household actually receives for a sale worth `value`: nothing while editing for free.
function P.Payout(world, value)
    if P.IsFree(world) then return 0 end
    return math.max(0, math.floor(tonumber(value) or 0))
end

-- Quote for selling an object with everything on it. Returns total, lines { {oid, name, value, full} }.
function P.Quote(world, oid)
    local lines, total = {}, 0
    local list = { oid }
    for _, c in ipairs(P.Children(world, oid)) do list[#list + 1] = c end
    for _, id in ipairs(list) do
        local o = world.lot.objects[id]
        if o then
            local v = P.SellValue(world, o)
            total = total + v
            lines[#lines + 1] = { oid = id, name = nameOf(world, id), value = v, full = P.FullRefund(world, o), paid = o.paid }
        end
    end
    return total, lines
end

local function record(world, label, cost, op)
    local tx = SS.Undo.Begin(world, label)
    tx.ops[#tx.ops + 1] = op
    tx.cost = cost
    SS.Undo.Commit(world, tx)
    return tx
end

local function remember(o)
    return { x = o.x, y = o.y, f = o.f, level = o.level, parent = o.parent, pslot = o.pslot }
end
local function restore(o, s)
    o.x, o.y, o.f, o.level, o.parent, o.pslot = s.x, s.y, s.f, s.level, s.parent, s.pslot
end

-- Put a child at its slot on a parent (position, level, facing follow the parent).
local function seat(child, parent, pslot, dfacing)
    local pdef = SS.Objects[parent.def]
    local s = C.SurfaceSlot(pdef, pslot)
    if not s then return false end
    local dx, dy = G.rot(s.cell[1], s.cell[2], parent.f or 0)
    child.parent, child.pslot = parent.id, pslot
    child.x, child.y, child.level = parent.x + dx, parent.y + dy, parent.level or 0
    if dfacing then child.f = ((child.f or 0) + dfacing) % 4 end
    return true
end

---------------------------------------------------------------------------------------------------
-- Actions. Each returns ok, why (and an id or item). All are undoable.
---------------------------------------------------------------------------------------------------
-- Buy a new object. opts: { variant, px, py (cursor), pslot, parent }.
function P.Buy(world, defId, x, y, f, level, opts)
    opts = opts or {}
    local def = defId and SS.Objects[defId]
    if not def then return false, "That design does not exist." end
    x, y, f, level = P.Coords(x, y, f, level)
    if not x then return false, P.BAD_SPOT end
    if def.buyable == false then return false, def.name .. " is not sold in buy mode." end
    local free = P.IsFree(world)
    local price = free and 0 or def.price
    local ok, why, blocked, info = P.Check(world, def, x, y, f, level, { price = (not free) and price or nil, px = opts.px, py = opts.py, pslot = opts.pslot, parent = opts.parent })
    if not ok then return false, why, blocked end
    local lot = world.lot
    local variant = C.Variant(def, opts.variant)
    local o = { id = P.NewId(lot), def = defId, x = x, y = y, f = (f or 0) % 4, level = info.level or level or 0,
        variant = variant and variant.id, bought = world.time, paid = price }
    if info.parent then o.parent, o.pslot = info.parent, info.pslot end
    if def.startState then o.state = U.deepcopy(def.startState) end
    lot.objects[o.id] = o
    if price > 0 then SS.Money(world, -price, "purchase", "Bought " .. def.name) end
    touch(world, o.id)
    record(world, "Buy " .. def.name, price, {
        undo = function() if lot.objects[o.id] == o then lot.objects[o.id] = nil end; touch(world, o.id) end,
        redo = function() lot.objects[o.id] = o; touch(world, o.id) end,
        checkUndo = function()
            if lot.objects[o.id] ~= o then return false, def.name .. " is no longer here." end
            if o.used then return false, "Someone has used the " .. def.name .. " since; sell it instead." end
            if #P.Children(world, o.id) > 0 then return false, "Take the things off the " .. def.name .. " first." end
            return true
        end,
        checkRedo = function() return P.Check(world, def, o.x, o.y, o.f, o.level, { parent = o.parent, pslot = o.pslot }) end,
    })
    SS.Emit("objectPlaced", world, o, "buy")
    return true, nil, o.id
end

-- Buy-and-place in one call for other tools (build mode's landscaping, Sim/Build.lua
-- B.PlaceLandscape): same rules, money and undo as P.Buy. Returns the new object id, or false, why.
function P.Place(world, defId, x, y, f, level, opts)
    local ok, why, oid = P.Buy(world, defId, x, y, f, level, opts)
    if ok then return oid end
    return false, why
end

-- Move (and/or rotate) a placed object; its children come along. Never charges.
-- opts: { px, py (cursor), pslot, parent } for surface items.
function P.Move(world, oid, x, y, f, level, opts)
    opts = opts or {}
    local lot = world.lot
    local o = oid and lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return false, "That object is no longer here." end
    x, y, f, level = P.Coords(x, y, f, level)
    if not x then return false, P.BAD_SPOT end
    if def.stairs then return false, "Move stairs with the stairs tool in build mode." end
    if P.BuildPiece(def) then return false, "Use build mode for the " .. def.name .. "." end
    local family = { [oid] = true }
    local kids = P.Children(world, oid)
    for _, c in ipairs(kids) do family[c] = true end
    local user = userOf(world, family)
    if user then return false, (user.name or "Someone") .. " is using the " .. def.name .. " right now." end
    local ok, why, blocked, info = P.Check(world, def, x, y, f, level, { ignore = family, px = opts.px, py = opts.py, pslot = opts.pslot, parent = opts.parent })
    if not ok then return false, why, blocked end
    local before, after = {}, {}
    before[oid] = remember(o)
    for _, c in ipairs(kids) do before[c] = remember(lot.objects[c]) end
    local df = ((f or 0) - (o.f or 0)) % 4
    o.x, o.y, o.f, o.level = x, y, (f or 0) % 4, info.level or level or 0
    if info.parent then o.parent, o.pslot = info.parent, info.pslot end
    for _, c in ipairs(kids) do seat(lot.objects[c], o, lot.objects[c].pslot, df) end
    after[oid] = remember(o)
    for _, c in ipairs(kids) do after[c] = remember(lot.objects[c]) end
    cancelWalkers(world, family)
    touch(world, oid)
    local function apply(state)
        for id, s in pairs(state) do if lot.objects[id] then restore(lot.objects[id], s) end end
        touch(world, oid)
    end
    local moved = (before[oid].x ~= x or before[oid].y ~= y or before[oid].level ~= o.level)
    -- undo and redo put it back only where it can still go (something may have taken the spot since)
    local function fits(state)
        if lot.objects[oid] ~= o then return false, def.name .. " is no longer here." end
        for id in pairs(family) do if not lot.objects[id] then return false, "Something that was on the " .. def.name .. " is gone." end end
        local s0 = state[oid]
        if s0.parent and not lot.objects[s0.parent] then return false, "What it stood on is gone." end
        local ok2, why2 = P.Check(world, def, s0.x, s0.y, s0.f, s0.level, { ignore = family, parent = s0.parent, pslot = s0.pslot })
        if not ok2 then return false, why2 end
        return true
    end
    record(world, (moved and "Move " or "Rotate ") .. def.name, 0, {
        undo = function() apply(before) end,
        redo = function() apply(after) end,
        checkUndo = function() return fits(before) end,
        checkRedo = function() return fits(after) end,
    })
    SS.Emit("objectPlaced", world, o, "move")
    return true, nil, oid
end

function P.Rotate(world, oid, dir)
    local o = oid and world.lot.objects[oid]
    if not o then return false, "That object is no longer here." end
    return P.Move(world, oid, o.x, o.y, ((o.f or 0) + (tonumber(dir) or 1)) % 4, o.level or 0, { parent = o.parent, pslot = o.pslot })
end

-- Remove objects (parent first in list) and give back a restore function.
local function detach(world, ids)
    local lot = world.lot
    local saved = {}
    for n, id in ipairs(ids) do saved[n] = lot.objects[id]; lot.objects[id] = nil end
    return saved
end
local function reattach(world, saved)
    for _, o in ipairs(saved) do world.lot.objects[o.id] = o end
end

-- Sell an object. If things rest on it, opts.withChildren must be true (the UI asks first);
-- otherwise returns false, why, nil, { needConfirm = true, count, total }.
function P.Sell(world, oid, opts)
    opts = opts or {}
    local lot = world.lot
    local o = oid and lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return false, "That object is no longer here." end
    if def.stairs then return false, "Remove stairs with the stairs tool in build mode." end
    local canSell, sellWhy = P.CanSell(world, oid)
    if not canSell then return false, sellWhy end
    local kids = P.Children(world, oid)
    local total, lines = P.Quote(world, oid)
    if #kids > 0 and not opts.withChildren then
        return false, "The " .. def.name .. " has " .. #kids .. (#kids == 1 and " thing" or " things") .. " on it.", nil,
            { needConfirm = true, count = #kids, total = total, lines = lines }
    end
    local ids = { oid }
    local family = { [oid] = true }
    for _, c in ipairs(kids) do ids[#ids + 1] = c; family[c] = true end
    local user = userOf(world, family)
    if user then return false, (user.name or "Someone") .. " is using the " .. def.name .. " right now." end
    local value = P.Payout(world, total)
    cancelWalkers(world, family)
    local saved = detach(world, ids)
    if value > 0 then SS.Money(world, value, "sale", "Sold " .. def.name .. (#kids > 0 and (" and " .. #kids .. " more") or "")) end
    touch(world, oid)
    record(world, "Sell " .. def.name, -value, {
        undo = function() reattach(world, saved); touch(world, oid) end,
        redo = function() detach(world, ids); touch(world, oid) end,
        checkUndo = function()
            for _, so in ipairs(saved) do if lot.objects[so.id] then return false, "Something else took its place." end end
            local sdef = SS.Objects[saved[1].def]
            if saved[1].parent and not lot.objects[saved[1].parent] then return false, "What it stood on is gone." end
            return P.Check(world, sdef, saved[1].x, saved[1].y, saved[1].f, saved[1].level, { parent = saved[1].parent, pslot = saved[1].pslot, ignore = {} })
        end,
    })
    SS.Emit("objectRemoved", world, oid, "sell", value)
    return true, nil, value
end

-- Inventory item for a placed object (children bundled). nil for an unknown object or design.
function P.ItemFor(world, oid)
    local lot = world.lot
    local o = oid and lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return nil end
    local total = P.Quote(world, oid)
    local data = { variant = o.variant, state = o.state and U.deepcopy(o.state), bought = o.bought, paid = o.paid, used = o.used,
        wear = o.wear, dirt = o.dirt, children = {} }
    for _, c in ipairs(P.Children(world, oid)) do
        local co = lot.objects[c]
        if SS.Objects[co.def] then
            data.children[#data.children + 1] = { def = co.def, variant = co.variant, pslot = co.pslot, df = ((co.f or 0) - (o.f or 0)) % 4,
                state = co.state and U.deepcopy(co.state), bought = co.bought, paid = co.paid, used = co.used }
        end
    end
    if #data.children == 0 then data.children = nil end
    return { kind = "object", def = o.def, name = def.name, value = total, data = data }
end

-- Move a placed object (with everything on it) into the household inventory. Never charges.
-- Only in the household's own home (P.InventoryHere) and within the player's storage limit.
function P.Store(world, oid)
    local lot = world.lot
    local o = oid and lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return false, "That object is no longer here." end
    if def.stairs then return false, "Stairs cannot be stored." end
    local canStore, storeWhy = P.CanSell(world, oid)
    if not canStore then return false, storeWhy end
    local here, hereWhy = P.InventoryHere(world)
    if not here then return false, hereWhy end
    if SS.Inventory.Full(world) then return false, "The household inventory is full (" .. SS.Inventory.CAP .. " items). Sell or place something first." end
    local kids = P.Children(world, oid)
    local ids = { oid }
    local family = { [oid] = true }
    for _, c in ipairs(kids) do ids[#ids + 1] = c; family[c] = true end
    local user = userOf(world, family)
    if user then return false, (user.name or "Someone") .. " is using the " .. def.name .. " right now." end
    local item = P.ItemFor(world, oid)
    local added, addWhy = SS.Inventory.Add(world, item, { player = true })
    if not added then return false, addWhy or "The household inventory would not take it." end
    cancelWalkers(world, family)
    local saved = detach(world, ids)
    touch(world, oid)
    record(world, "Store " .. def.name, 0, {
        undo = function() SS.Inventory.Remove(world, item); reattach(world, saved); touch(world, oid) end,
        redo = function() detach(world, ids); SS.Inventory.Insert(world, item); touch(world, oid) end,
        checkUndo = function()
            if not SS.Inventory.IndexOf(world, item) then return false, "The stored " .. def.name .. " has been used elsewhere." end
            for _, so in ipairs(saved) do if lot.objects[so.id] then return false, "Something else took its place." end end
            return P.Check(world, def, o.x, o.y, o.f, o.level, { parent = o.parent, pslot = o.pslot })
        end,
        checkRedo = function()
            if not P.InventoryHere(world) then return false, "Nothing here can go to the household inventory." end
            return true
        end,
    })
    SS.Emit("objectRemoved", world, oid, "store", 0)
    return true, nil, item
end

-- Place an object item from the inventory (its stored children come back onto their slots).
function P.PlaceItem(world, item, x, y, f, level, opts)
    opts = opts or {}
    local def = type(item) == "table" and item.kind == "object" and item.def and SS.Objects[item.def]
    if not def then return false, "Only furniture and other objects can be placed." end
    local here, hereWhy = P.InventoryHere(world)
    if not here then return false, hereWhy end
    if not SS.Inventory.IndexOf(world, item) then return false, "That item is no longer in the inventory." end
    x, y, f, level = P.Coords(x, y, f, level)
    if not x then return false, P.BAD_SPOT end
    local ok, why, blocked, info = P.Check(world, def, x, y, f, level, { px = opts.px, py = opts.py, pslot = opts.pslot, parent = opts.parent })
    if not ok then return false, why, blocked end
    local lot = world.lot
    local d = type(item.data) == "table" and item.data or {}
    local variant = C.Variant(def, d.variant)
    local o = { id = P.NewId(lot), def = item.def, x = x, y = y, f = f, level = info.level or level or 0,
        variant = variant and variant.id, bought = d.bought or world.time, paid = d.paid or item.value or def.price,
        used = d.used, wear = d.wear, dirt = d.dirt, state = d.state and U.deepcopy(d.state) or (def.startState and U.deepcopy(def.startState)) }
    if info.parent then o.parent, o.pslot = info.parent, info.pslot end
    lot.objects[o.id] = o
    local placed = { o }
    local leftovers = {}
    for _, cd in ipairs(type(d.children) == "table" and d.children or {}) do
        local cdef = type(cd) == "table" and cd.def and SS.Objects[cd.def]
        local child = cdef and { id = P.NewId(lot), def = cd.def, f = o.f, variant = cd.variant, state = cd.state and U.deepcopy(cd.state),
            bought = cd.bought, paid = cd.paid, used = cd.used }
        if child and seat(child, o, cd.pslot, cd.df or 0) then
            lot.objects[child.id] = child
            placed[#placed + 1] = child
        elseif cdef then
            leftovers[#leftovers + 1] = { kind = "object", def = cd.def, name = cdef.name, value = cd.paid or cdef.price,
                data = { variant = cd.variant, state = cd.state, bought = cd.bought, paid = cd.paid, used = cd.used } }
        end
    end
    local pos = SS.Inventory.IndexOf(world, item)
    SS.Inventory.Remove(world, item)
    -- things whose slot this design no longer has go back to the inventory as their own items
    -- (objects are never refused there); anything that still is not taken stands beside it
    local kept = {}
    for _, it in ipairs(leftovers) do
        if SS.Inventory.Add(world, it) then kept[#kept + 1] = it
        else SS.Emit("notice", nil, "The " .. it.name .. " could not go back to the household inventory.") end
    end
    leftovers = kept
    touch(world, o.id)
    local ids = {}
    for n, po in ipairs(placed) do ids[n] = po.id end
    record(world, "Place " .. def.name, 0, {
        undo = function()
            for _, it in ipairs(leftovers) do SS.Inventory.Remove(world, it) end
            detach(world, ids); SS.Inventory.Insert(world, item, pos); touch(world, o.id)
        end,
        redo = function()
            SS.Inventory.Remove(world, item); reattach(world, placed)
            for _, it in ipairs(leftovers) do SS.Inventory.Add(world, it) end
            touch(world, o.id)
        end,
        checkUndo = function()
            if lot.objects[o.id] ~= o then return false, def.name .. " is no longer here." end
            for _, po in ipairs(placed) do if lot.objects[po.id] ~= po then return false, "Something on the " .. def.name .. " has moved." end end
            for _, it in ipairs(leftovers) do if not SS.Inventory.IndexOf(world, it) then return false, "The " .. it.name .. " has left the inventory." end end
            return true
        end,
        checkRedo = function()
            if not P.InventoryHere(world) then return false, "Nothing here comes from the household inventory." end
            if not SS.Inventory.IndexOf(world, item) then return false, "That item is no longer in the inventory." end
            for _, po in ipairs(placed) do if lot.objects[po.id] then return false, "Something else took its place." end end
            return P.Check(world, def, o.x, o.y, o.f, o.level, { parent = o.parent, pslot = o.pslot })
        end,
    })
    SS.Emit("objectPlaced", world, o, "inventory")
    return true, nil, o.id
end

-- Sell an inventory item (objects: at their current resale value; other items: their value).
-- Only in the household's own home; nothing is paid while editing for free.
function P.SellItem(world, item)
    local pos = type(item) == "table" and SS.Inventory.IndexOf(world, item)
    if not pos then return false, "That item is no longer in the inventory." end
    local here, hereWhy = P.InventoryHere(world)
    if not here then return false, hereWhy end
    local value = P.Payout(world, P.ItemValue(world, item))
    SS.Inventory.Remove(world, item)
    if value > 0 then SS.Money(world, value, "sale", "Sold " .. (item.name or "an item")) end
    record(world, "Sell " .. (item.name or "item"), -value, {
        -- the sale is taken back whole: the item returns to its old place in the list (undo of a
        -- player's own sale may go past the storage limit; nothing is ever dropped)
        undo = function() SS.Inventory.Insert(world, item, pos) end,
        redo = function() SS.Inventory.Remove(world, item) end,
        checkUndo = function()
            if SS.Inventory.IndexOf(world, item) then return false, "It is already back in the inventory." end
            return true
        end,
    })
    return true, nil, value
end

-- What an inventory item sells for (its market value: resale rules for objects; paid = 0 means 0).
-- Use P.Payout for what the household would actually receive right now.
function P.ItemValue(world, item)
    if type(item) ~= "table" then return 0 end
    if item.kind == "object" and item.def and SS.Objects[item.def] then
        local d = type(item.data) == "table" and item.data or {}
        local v = P.SellValue(world, { def = item.def, bought = d.bought, paid = d.paid or item.value, used = d.used, state = d.state })
        for _, cd in ipairs(type(d.children) == "table" and d.children or {}) do
            if type(cd) == "table" and cd.def and SS.Objects[cd.def] then
                v = v + P.SellValue(world, { def = cd.def, bought = cd.bought, paid = cd.paid, used = cd.used, state = cd.state })
            end
        end
        return v
    end
    return math.max(0, math.floor(tonumber(item.value) or 0))
end

-- Eyedropper: the design, variant and facing of a placed object, to buy another the same.
function P.Eyedropper(world, oid)
    local o = world.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return nil, "Nothing to copy there." end
    if def.buyable == false or not C.CAT[def.cat] then return nil, def.name .. " is not sold in buy mode." end
    if def.community and world.lot.kind ~= "community" and not sandbox(world) then return nil, def.name .. " is venue equipment." end
    return { def = o.def, variant = o.variant, f = o.f or 0 }
end

-- Placement ghost for the renderer (SS.Render.SetGhost):
--   { def, variant, x, y, f, level, valid, reason, cells = { {i, j}... } (footprint),
--     blocked = { {i, j}... } (cells at fault), approaches = { {i, j, ok}... } (where people stand to use it),
--     z (surface height in tiles, items on surfaces), sx, sy (exact position on a surface), parent, pslot,
--     moving = oid (a picked-up object: draw the ghost instead of the original) }
function P.Ghost(world, defId, x, y, f, level, opts)
    opts = opts or {}
    local def = defId and SS.Objects[defId]
    x, y, f, level = P.Coords(x, y, f, level)
    if not x then
        return { def = defId, variant = opts.variant, x = 0, y = 0, f = 0, level = 0, valid = false, blocked = {}, reason = P.BAD_SPOT,
            cells = {}, approaches = {}, moving = opts.moving }
    end
    local ok, why, blocked, info = P.Check(world, def, x, y, f, level, opts)
    info = info or {}
    local z, sx, sy
    if info.parent then
        z = ((info.level or 0) * W.STORY) + (info.z or 0)
        local p = world.lot.objects[info.parent]
        if p then sx, sy = P.SurfacePos(world, { x = x, y = y, level = info.level, parent = info.parent, pslot = info.pslot }) end
    end
    local cells = {}
    if def then for n, c in ipairs(P.Cells(def, x, y, f)) do cells[n] = { c.i, c.j } end end
    local approaches = {}
    for n, a in ipairs(info.approaches or {}) do approaches[n] = { a.i or a[1], a.j or a[2], ok = a.ok ~= false } end
    return { def = defId, variant = opts.variant, x = x, y = y, f = (f or 0) % 4, level = info.level or level or 0, valid = ok and true or false,
        blocked = blocked or {}, reason = why, cells = cells, z = z, sx = sx, sy = sy, parent = info.parent, pslot = info.pslot,
        approaches = approaches, moving = opts.moving }
end

---------------------------------------------------------------------------------------------------
-- Buy mode entry, keeping things valid after build edits, save validation, use tracking
---------------------------------------------------------------------------------------------------
-- canEnter for buy mode: refuses during an emergency (unless sandbox) and on lots the household
-- does not own (community venues only while editing them from the neighbourhood).
function P.CanEnter(world)
    if not world or not world.lot then return false, "Load a household first." end
    if SS.Fire and SS.Fire.Active and SS.Fire.Active(world) and not sandbox(world) then
        return false, "Not during an emergency: deal with the fire first."
    end
    local lot = world.lot
    if lot.kind == "community" and not world.editVenue and not sandbox(world) then
        return false, "You can only furnish a community lot while editing it from the neighbourhood."
    end
    if lot.kind ~= "community" and world.household and world.household.lotId and world.household.lotId ~= lot.id and not sandbox(world) then
        return false, "You can only furnish your own home."
    end
    return true
end

-- Is a mounted object still properly supported? Returns ok, why.
function P.Supported(world, o)
    local lot = world.lot
    local def = SS.Objects[o.def]
    if not def then return false, "unknown design" end
    local lv = o.level or 0
    if o.parent then
        local p = lot.objects[o.parent]
        if not p then return false, "what it rested on is gone" end
        if not C.SurfaceSlot(SS.Objects[p.def] or {}, o.pslot) then return false, "its surface is gone" end
        return true
    end
    if def.mount == "surface" then return true end   -- loose legacy item: leave it
    for _, c in ipairs(P.Cells(def, o.x, o.y, o.f)) do
        if not W.InLot(lot, c.i, c.j) then return false, "it is outside the lot" end
        if lv > 0 and not W.FloorAt(lot, lv, c.i, c.j) then return false, "its floor was removed" end
        if def.mount == "wall" or def.mount == "window" then
            local wl = W.WallAt(lot, lv, P.BackEdge(c.i, c.j, o.f))
            local want = def.mount == "wall" and "wall" or "window"
            if not (wl and wl.kind == want) then return false, "its " .. want .. " was removed" end
        elseif def.mount == "ceiling" then
            if not (W.RoomAt(world, lv, c.i, c.j) > 0 or (lv + 1 < W.LEVELS and W.FloorAt(lot, lv + 1, c.i, c.j))) then return false, "its ceiling was removed" end
        end
    end
    return true
end

-- Objects that lost their support (wall, window, ceiling, floor or parent) go to the household
-- inventory with a notice, children and all: never orphaned, never lost, never charged. Where
-- nothing can go to an inventory (a venue or unowned lot edited for free, a community lot, someone
-- else's home, no household: P.InventoryHere) they stay on the lot, and the player is told once
-- per object what to fix; a child whose parent went away is set down loose where it stood.
-- Unknown designs are left alone. Returns the number of objects moved to the inventory.
P.unsupported = {}   -- runtime: "lotId|oid" -> true once the player has been told (never saved)
local function tellOnce(world, oid, text)
    local key = tostring(world.lot.id) .. "|" .. tostring(oid)
    if P.unsupported[key] then return end
    P.unsupported[key] = true
    SS.Emit("notice", nil, text)
end
local function toInventory(world, oid, why)
    local lot = world.lot
    local o = lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return false end
    local here = P.InventoryHere(world)
    local item = here and P.ItemFor(world, oid)
    if not item then
        tellOnce(world, oid, "The " .. def.name .. " stays where it is although " .. why .. ": move it or sell it in buy mode.")
        return false
    end
    local ids = { oid }
    for _, c in ipairs(P.Children(world, oid)) do ids[#ids + 1] = c end
    local added = SS.Inventory.Add(world, item)
    if not added then
        tellOnce(world, oid, "The " .. def.name .. " stays where it is although " .. why .. " (the household inventory would not take it).")
        return false
    end
    detach(world, ids)
    SS.Emit("notice", nil, def.name .. " went to the household inventory because " .. why .. ".")
    return true
end
function P.Revalidate(world)
    if not world or not world.lot or not world.lot.objects then return 0 end
    local lot = world.lot
    local moved, changed = 0, false
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        if o and not o.parent and SS.Objects[o.def] then
            local ok, why = P.Supported(world, o)
            if not ok then
                if toInventory(world, oid, why) then moved = moved + 1; changed = true end
            end
        end
    end
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        if o and o.parent and SS.Objects[o.def] then
            local ok, why = P.Supported(world, o)
            if not ok then
                if toInventory(world, oid, why) then
                    moved = moved + 1
                else
                    -- nowhere to keep it: it stays, loose, where it stood
                    o.parent, o.pslot = nil, nil
                end
                changed = true
            end
        end
    end
    if changed then touch(world, nil) end
    return moved
end

local REVALIDATE_ON = { wall = true, walls = true, floor = true, floors = true, build = true, undo = true, redo = true,
    terrain = true, roof = true, door = true, window = true, stairs = true, fire = true, bulldoze = true }
SS.On("lotChanged", function(kind)
    if not REVALIDATE_ON[kind] then return end
    local world = SS.Sim and SS.Sim.world
    if world and not P.busy then
        P.busy = true
        local ok, err = pcall(P.Revalidate, world)
        P.busy = false
        if not ok then SS.Log("placement revalidate failed: %s", tostring(err)) end
    end
end)

-- The first use ends the same-day full refund (Economy also tracks this; both are idempotent).
SS.On("actionStarted", function(actor, act)
    local world = SS.Sim and SS.Sim.world
    if not world or not act then return end
    for _, oid in ipairs({ act.oid, act.target and act.target.oid, act.target and act.target.viewer }) do
        local o = oid and world.lot.objects[oid]
        if o and not o.used then o.used = world.time end
    end
end)

-- Save repair: children whose parent or slot is gone, or two children on one slot, go to the lot
-- owner's inventory (a lot without a household keeps them, set down loose where they stood).
if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        local owners = {}
        for _, hh in pairs(root.households or {}) do if type(hh) == "table" and hh.lotId then owners[hh.lotId] = hh end end
        for lid, lot in pairs(root.hood and root.hood.lots or {}) do
            local taken = {}
            for _, oid in ipairs(sortedKeys(lot.objects or {})) do
                local o = lot.objects[oid]
                if o.parent ~= nil then
                    local p = lot.objects[o.parent]
                    local pdef = p and SS.Objects[p.def]
                    local key = tostring(o.parent) .. "|" .. tostring(o.pslot)
                    if not (pdef and C.SurfaceSlot(pdef, o.pslot)) or taken[key] then
                        lot.objects[oid] = nil
                        local hh = owners[lid]
                        local def = SS.Objects[o.def]
                        if hh and def then
                            -- same item shape and id rules as SS.Inventory.Add; never refused (it came off the lot)
                            hh.inventory = type(hh.inventory) == "table" and hh.inventory or {}
                            local item = { kind = "object", def = o.def, name = def.name, value = o.paid or def.price,
                                data = { variant = o.variant, state = o.state, bought = o.bought, paid = o.paid, used = o.used } }
                            if SS.Inventory and SS.Inventory.Normalize then SS.Inventory.Normalize(hh, item) end
                            hh.inventory[#hh.inventory + 1] = item
                            problems[#problems + 1] = "moved a loose " .. tostring(o.def) .. " on " .. tostring(lid) .. " to storage"
                        elseif def then
                            -- nobody's lot: it stays, set down loose where it stood
                            o.parent, o.pslot = nil, nil
                            lot.objects[oid] = o
                            problems[#problems + 1] = "set down a loose " .. tostring(o.def) .. " on " .. tostring(lid)
                        else
                            problems[#problems + 1] = "removed an unknown loose object " .. tostring(o.def) .. " on " .. tostring(lid)
                        end
                    else
                        taken[key] = true
                    end
                end
            end
        end
    end)
end
