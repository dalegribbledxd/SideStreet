-- Roofs: automatic generation from each building's top-floor footprint, per-building styles,
-- materials and colours, and the geometry contract the renderer and neighbourhood previews draw.
-- Owner: build module (see ARCHITECTURE.md §5, §10, docs/modules/build.md).
--
-- A roof SECTION is a connected set of cells on one level that are indoors (room id > 0, see
-- SS.Build.Rooms) with nothing built above them, plus stairwell openings enclosed by them.
-- Open courtyards, terraces and balconies are outdoors, so they get no roof, and a two-story
-- building gets its roof on the upper story while a one-story wing gets its own lower roof.
--
-- Heights are integer RISE steps on the section's corner grid, computed as a geodesic L-infinity
-- (8-neighbour) distance from the section's eave corners. For a rectilinear footprint this is the
-- straight-skeleton roof: hips at convex corners, valleys at reflex corners (L and T wings,
-- courtyards). Because two corners of one cell are always 8-neighbours, every cell's corners
-- differ by at most one step, so each piece is exactly a 0/1 corner pattern (the art is
-- pre-rendered at Rf.RISE = 0.5 tiles of rise per tile of run). Styles choose the eaves:
--   hip      every outer edge is an eave;
--   gable    the end caps of each wing (short faces) stand as vertical gable walls;
--   shed     only the faces toward one side are eaves (a single slope, capped into a deck);
--   mansard  a hip clipped to a flat deck after Rf.T.mansardCap steps;
--   flat     no slope (parapet deck).
-- Edges against a taller story of the same building never count as eaves: the lower roof rises
-- into that wall (a lean-to), which then hides the join.
local _, SS = ...
local G, W, B = SS.Grid, SS.World, SS.Build
local Rf = { RISE = 0.5 }   -- roof height gained per tile of run (tiles); art pre-renders at this pitch
SS.Roof = Rf

Rf.T = {
    maxRise = 6,        -- steps; taller roofs turn into a flat deck at this height
    mansardCap = 2,     -- steps of steep edge before a mansard's deck
    shedCap = 4,        -- steps; a shed roof on a deep house levels off here
    stylePrice = 2,     -- per roofed tile to change a building's roof style
    colorPrice = 1,     -- per roofed tile to repaint
}

Rf.STYLES = {
    { id = "gable", name = "Gable", desc = "Two slopes meeting at a ridge, with triangular gable walls at the ends of each wing." },
    { id = "hip", name = "Hipped", desc = "Slopes on every side, meeting in hips and valleys. Tidy on any footprint." },
    { id = "flat", name = "Flat", desc = "A level deck behind a low parapet. Modern, and excellent for pigeons." },
    { id = "shed", name = "Shed (lean-to)", desc = "One long slope, high at the back and low toward the chosen side." },
    { id = "mansard", name = "Mansard", desc = "A steep bevel all round topped by a flat deck, for a house with attic ambitions." },
}
Rf.STYLE = {}
for _, s in ipairs(Rf.STYLES) do Rf.STYLE[s.id] = s end
Rf.ALIAS = { hipped = "hip", hips = "hip", pyramid = "hip", pitched = "gable", gabled = "gable", ridge = "gable",
    lean = "shed", ["lean-to"] = "shed", leanto = "shed", skillion = "shed", clipped = "mansard", deck = "flat" }
Rf.SIDES = { "south", "west", "north", "east" }
local SIDE_NORMAL = { south = { 0, 1 }, north = { 0, -1 }, east = { 1, 0 }, west = { -1, 0 } }

function Rf.NormStyle(s)
    if s and Rf.STYLE[s] then return s end
    return (s and Rf.ALIAS[s]) or "gable"
end

-- Roof material item (normalised catalogue entry; accepts bare ids like "shingle").
function Rf.Material(id)
    if id then
        local it = B.Item("roofs", id) or B.Item("roofs", "roof_" .. tostring(id))
        if it then return it end
    end
    return B.Items("roofs")[1]
end

function Rf.Color(item, id)
    local list = item and item.colors or B.ROOF_COLORS
    for _, c in ipairs(list) do if c.id == id then return c end end
    for _, c in ipairs(B.ROOF_COLORS) do if c.id == id then return c end end
    return list[1] or B.ROOF_COLORS[1]
end

---------------------------------------------------------------------------------------------------
-- Sections
---------------------------------------------------------------------------------------------------
local function cellOf(lot, k) k = k - 1; return k % lot.w, math.floor(k / lot.w) end

-- Returns list of sections { key, level, cells (sorted idx), set, anchor, z, base }.
-- rooms (optional) = { [level] = roomMap } to reuse.
function Rf.Sections(lot, scan, rooms)
    B.EnsureLot(lot)
    scan = scan or B.Scan(lot)
    rooms = rooms or {}
    for L = 0, W.LEVELS - 1 do rooms[L] = rooms[L] or B.Rooms(lot, L, scan) end
    local out = {}
    for L = 0, W.LEVELS - 1 do
        local room = rooms[L]
        local up = rooms[L + 1]
        local roofed = {}
        for k, r in pairs(room) do
            if r and r > 0 then
                local covered = false
                if L + 1 < W.LEVELS then
                    if scan.well[L + 1][k] then covered = true
                    elseif lot.floor[L + 1][k] ~= nil then covered = true end
                end
                if not covered then roofed[k] = true end
            end
        end
        -- stairwell openings inside an upper story are under its roof
        if L > 0 then
            local wl = lot.walls[L]
            for k in pairs(scan.well[L]) do
                local i, j = cellOf(lot, k)
                local enclosed = true
                for d = 0, 3 do
                    local v = G.DIRS[d]
                    local ni, nj = i + v[1], j + v[2]
                    local e = wl[G.edgeBetween(i, j, ni, nj)]
                    if not (e and B.ENCLOSES[e.kind]) then
                        if not (ni >= 0 and nj >= 0 and ni < lot.w and nj < lot.h) then enclosed = false
                        else
                            local nk = nj * lot.w + ni + 1
                            if not (roofed[nk] or scan.well[L][nk]) then enclosed = false end
                        end
                    end
                end
                if enclosed then roofed[k] = true end
            end
        end
        -- connected components (interior walls do not split a roof)
        local keys = {}
        for k in pairs(roofed) do keys[#keys + 1] = k end
        table.sort(keys)
        local seen = {}
        for _, k0 in ipairs(keys) do
            if not seen[k0] then
                local cells, set = { k0 }, { [k0] = true }
                seen[k0] = true
                local n = 1
                while n <= #cells do
                    local i, j = cellOf(lot, cells[n])
                    n = n + 1
                    for d = 0, 3 do
                        local v = G.DIRS[d]
                        local ni, nj = i + v[1], j + v[2]
                        if ni >= 0 and nj >= 0 and ni < lot.w and nj < lot.h then
                            local nk = nj * lot.w + ni + 1
                            if roofed[nk] and not seen[nk] then seen[nk] = true; set[nk] = true; cells[#cells + 1] = nk end
                        end
                    end
                end
                table.sort(cells)
                local base = 0
                if L == 0 and SS.Terrain then
                    base = -1e9
                    for _, k in ipairs(cells) do
                        local i, j = cellOf(lot, k)
                        local b = SS.Terrain.CellBase(lot, i, j)
                        if b > base then base = b end
                    end
                end
                local groundZ = (SS.Terrain and base * SS.Terrain.STEP) or 0
                out[#out + 1] = { key = L .. ":" .. cells[1], level = L, cells = cells, set = set, anchor = cells[1],
                    z = (L + 1) * W.STORY + groundZ, groundZ = groundZ, up = up }
            end
        end
    end
    return out, rooms
end

-- Resolved settings for a section: style, material item, colour entry, shed side.
function Rf.Settings(lot, sec)
    local roof = lot.roof or {}
    local ov
    local ovs = roof.overrides
    if type(ovs) == "table" then
        for _, k in ipairs(sec.cells) do
            local o = ovs[sec.level .. ":" .. k]
            if type(o) == "table" then ov = o; break end
        end
    end
    local style = Rf.NormStyle((ov and ov.style) or roof.style)
    local mat = Rf.Material((ov and ov.material) or roof.material)
    local col = Rf.Color(mat, (ov and ov.color) or roof.color)
    local side = (ov and ov.side) or roof.side or "south"
    if not SIDE_NORMAL[side] then side = "south" end
    return style, mat, col, side, ov
end

---------------------------------------------------------------------------------------------------
-- Height field
---------------------------------------------------------------------------------------------------
-- Boundary faces of a section: maximal runs of boundary edges on one line with the same outward
-- normal. Returns list { normal = "north"|..., edges = {key...}, len, cap = bool, depth }.
local function faces(lot, sec)
    local S = sec.set
    local function inS(i, j) return i >= 0 and j >= 0 and i < lot.w and j < lot.h and S[j * lot.w + i + 1] == true end
    local list = {}
    local used = {}
    for _, k in ipairs(sec.cells) do
        local i, j = cellOf(lot, k)
        -- north face (outside at j-1), south (j+1), west (i-1), east (i+1)
        local dirs = { { "north", 0, -1 }, { "south", 0, 1 }, { "west", -1, 0 }, { "east", 1, 0 } }
        for _, d in ipairs(dirs) do
            local nm, dx, dy = d[1], d[2], d[3]
            if not inS(i + dx, j + dy) and not used[nm .. k] then
                -- walk to the start of the run, then along it
                local ax, ay = (dx == 0) and 1 or 0, (dy == 0) and 1 or 0   -- run direction
                local si, sj = i, j
                while inS(si - ax, sj - ay) and not inS(si - ax + dx, sj - ay + dy) do si, sj = si - ax, sj - ay end
                local edges, cells = {}, {}
                local ci, cj = si, sj
                while inS(ci, cj) and not inS(ci + dx, cj + dy) do
                    local ck = cj * lot.w + ci + 1
                    used[nm .. ck] = true
                    edges[#edges + 1] = G.edgeBetween(ci, cj, ci + dx, cj + dy)
                    cells[#cells + 1] = { ci, cj }
                    ci, cj = ci + ax, cj + ay
                end
                local len = #edges
                -- convex ends: the cell beyond the run (along it) is outside the section
                local startConvex = not inS(si - ax, sj - ay)
                local endConvex = not inS(ci, cj)
                local cap = startConvex and endConvex
                -- depth: how far the face's full width reaches inward
                local depth = 0
                if cap then
                    local ok = true
                    local ox, oy = -dx, -dy
                    while ok and depth <= lot.w + lot.h do
                        for _, c in ipairs(cells) do
                            if not inS(c[1] + ox * depth, c[2] + oy * depth) then ok = false; break end
                        end
                        if ok then depth = depth + 1 end
                    end
                end
                list[#list + 1] = { normal = nm, edges = edges, len = len, cap = cap, depth = depth, cells = cells, dx = dx, dy = dy }
            end
        end
    end
    return list
end
Rf.Faces = faces

-- Heights (steps) on the section's corners: h[cornerIdx]. Also returns abut[edgeKey] = true for
-- boundary edges against a taller story, and eave[edgeKey] = true for eave edges.
function Rf.Heights(lot, sec, style, side)
    style = Rf.NormStyle(style)
    -- accept a built section (Rf.Build / Rf.Pieces output has no set/up): resolve it by key
    if not sec.set then
        local found
        for _, s in ipairs(Rf.Sections(lot)) do if s.key == sec.key then found = s; break end end
        if not found then return {}, {}, {}, {} end
        sec = found
    end
    local W1 = lot.w + 1
    local S = sec.set
    local function inS(i, j) return i >= 0 and j >= 0 and i < lot.w and j < lot.h and S[j * lot.w + i + 1] == true end
    local h = {}
    local corners = {}
    for _, k in ipairs(sec.cells) do
        local i, j = cellOf(lot, k)
        for _, c in ipairs({ { i, j }, { i + 1, j }, { i + 1, j + 1 }, { i, j + 1 } }) do corners[c[2] * W1 + c[1] + 1] = true end
    end
    local fl = faces(lot, sec)
    -- edges against a taller story (the neighbour cell has an indoor story above this level)
    local abut, eave = {}, {}
    local up = sec.up
    for _, f in ipairs(fl) do
        for n, key in ipairs(f.edges) do
            local c = f.cells[n]
            local ni, nj = c[1] + f.dx, c[2] + f.dy
            if up and ni >= 0 and nj >= 0 and ni < lot.w and nj < lot.h and (up[nj * lot.w + ni + 1] or 0) > 0 then abut[key] = true end
        end
    end
    if style == "flat" then
        for k in pairs(corners) do h[k] = 0 end
        return h, abut, eave, fl
    end
    local isEave = {}
    for _, f in ipairs(fl) do
        local e
        if style == "shed" then
            e = (f.normal == side)
        elseif style == "gable" then
            local gableEnd = f.cap and (f.depth > f.len or (f.depth == f.len and (f.normal == "east" or f.normal == "west")))
            e = not gableEnd
        else
            e = true
        end
        for _, key in ipairs(f.edges) do
            if e and not abut[key] then eave[key] = true end
        end
    end
    local sources = {}
    local function addSources(filter)
        for _, f in ipairs(fl) do
            for _, key in ipairs(f.edges) do
                if filter(key) then
                    local x0, y0, x1, y1 = B.EdgeCorners(key)
                    sources[#sources + 1] = y0 * W1 + x0 + 1
                    sources[#sources + 1] = y1 * W1 + x1 + 1
                end
            end
        end
    end
    addSources(function(key) return eave[key] end)
    if #sources == 0 then
        -- nothing counts as an eave (every face abuts or is a gable): fall back to a hip
        addSources(function(key) return not abut[key] end)
        if #sources == 0 then addSources(function() return true end) end
    end
    -- multi-source BFS, 8-neighbour moves that stay over the section
    local queue, head = {}, 1
    for _, k in ipairs(sources) do
        if h[k] == nil then h[k] = 0; queue[#queue + 1] = k end
    end
    while head <= #queue do
        local k = queue[head]; head = head + 1
        local n = k - 1
        local ci, cj = n % W1, math.floor(n / W1)
        local hk = h[k]
        for dj = -1, 1 do
            for di = -1, 1 do
                if di ~= 0 or dj ~= 0 then
                    local ni, nj = ci + di, cj + dj
                    local nk = nj * W1 + ni + 1
                    if corners[nk] and h[nk] == nil then
                        local ok
                        if di ~= 0 and dj ~= 0 then
                            ok = inS(math.min(ci, ni), math.min(cj, nj))
                        elseif di ~= 0 then
                            local x = math.min(ci, ni)
                            ok = inS(x, cj - 1) or inS(x, cj)
                        else
                            local y = math.min(cj, nj)
                            ok = inS(ci - 1, y) or inS(ci, y)
                        end
                        if ok then h[nk] = hk + 1; queue[#queue + 1] = nk end
                    end
                end
            end
        end
    end
    local cap = Rf.T.maxRise
    if style == "mansard" then cap = math.min(cap, Rf.T.mansardCap)
    elseif style == "shed" then cap = math.min(cap, Rf.T.shedCap) end
    for k in pairs(corners) do
        local v = h[k] or 0
        if v > cap then v = cap end
        h[k] = v
    end
    return h, abut, eave, fl
end

---------------------------------------------------------------------------------------------------
-- Pieces (the renderer / preview contract)
---------------------------------------------------------------------------------------------------
-- Fold diagonal for a 0/1 corner pattern {nw, ne, se, sw}: through the odd corner of a 1- or
-- 3-raised cell; along the raised diagonal of a saddle; nil for planar cells.
function Rf.Fold(c)
    local n = c[1] + c[2] + c[3] + c[4]
    if n == 1 or n == 3 then
        local odd = (n == 1) and 1 or 0
        return (c[1] == odd or c[3] == odd) and "nwse" or "nesw"
    elseif n == 2 and c[1] == c[3] then
        return (c[1] == 1) and "nwse" or "nesw"
    end
    return nil
end

-- Geometry for any lot (attached or not): { pieces, gables, sections }.
--   piece = { level, i, j, z, c = {nw, ne, se, sw} (0/1 RISE steps above z), split, fold,
--             material, color, rgb, style, section, flat }
--   gable = { level, edgeKey, z, h1, h2, finish, side, material, color, rgb, section }
--             h1/h2: roof height (RISE steps above z) at the edge's first and second corner
--             (B.EdgeCorners order); a vertical wall piece fills from z up to that line;
--             side = the edge side facing out of the building ("a" or "b").
--   section = { key, level, z, style, material, color, area, cells, peak }
function Rf.Build(lot, scan)
    B.EnsureLot(lot)
    local out = { pieces = {}, gables = {}, sections = {} }
    local secs = Rf.Sections(lot, scan)
    local W1 = lot.w + 1
    for _, sec in ipairs(secs) do
        local style, mat, col, side = Rf.Settings(lot, sec)
        local h, abut = Rf.Heights(lot, sec, style, side)
        local peak = 0
        for _, k in ipairs(sec.cells) do
            local i, j = cellOf(lot, k)
            local a = h[j * W1 + i + 1] or 0
            local b = h[j * W1 + i + 2] or 0
            local c = h[(j + 1) * W1 + i + 2] or 0
            local d = h[(j + 1) * W1 + i + 1] or 0
            local base = math.min(a, b, c, d)
            local top = math.max(a, b, c, d)
            if top > peak then peak = top end
            local cc = { a - base, b - base, c - base, d - base }
            local fold = Rf.Fold(cc)
            out.pieces[#out.pieces + 1] = { level = sec.level, i = i, j = j, z = sec.z + base * Rf.RISE, c = cc,
                split = fold ~= nil, fold = fold, material = mat and mat.id, color = col.id, rgb = col.rgb, style = style,
                section = sec.key, flat = (top == base) or nil }
        end
        -- gable / end walls along boundary edges whose roof line is above the wall top
        local walls = lot.walls[sec.level]
        for _, f in ipairs(faces(lot, sec)) do
            for _, key in ipairs(f.edges) do
                if not abut[key] then
                    local x0, y0, x1, y1 = B.EdgeCorners(key)
                    local h1, h2 = h[y0 * W1 + x0 + 1] or 0, h[y1 * W1 + x1 + 1] or 0
                    if h1 > 0 or h2 > 0 then
                        local ai, aj = B.EdgeCells(key)
                        local inside = sec.set[aj * lot.w + ai + 1] and (ai >= 0 and aj >= 0 and ai < lot.w and aj < lot.h)
                        local outSide = inside and "b" or "a"
                        local wl = walls[key]
                        out.gables[#out.gables + 1] = { level = sec.level, edgeKey = key, z = sec.z, h1 = h1, h2 = h2,
                            finish = wl and wl[outSide] or (wl and (wl.a or wl.b)) or B.DefaultWallFinish(), side = outSide,
                            material = mat and mat.id, color = col.id, rgb = col.rgb, section = sec.key }
                    end
                end
            end
        end
        out.sections[#out.sections + 1] = { key = sec.key, level = sec.level, z = sec.z, style = style, material = mat and mat.id,
            color = col.id, rgb = col.rgb, side = side, area = #sec.cells, cells = sec.cells, peak = peak }
    end
    return out
end

local cache = setmetatable({}, { __mode = "k" })
function Rf.PiecesForLot(lot)
    local c = cache[lot]
    if c and c.version == (lot.version or 0) then return c.data end
    local data = Rf.Build(lot)
    cache[lot] = { version = lot.version or 0, data = data }
    return data
end
function Rf.Invalidate(lot) if lot then cache[lot] = nil end end

-- Roof geometry for the renderer: { pieces = { { level, i, j, z, c = {nw, ne, se, sw}, split, material, color } },
--   gables = { { level, edgeKey, z, h1, h2, finish } } }. Corner offsets are in RISE steps (0/1) above z.
function Rf.Pieces(world) return Rf.PiecesForLot(world.lot) end

-- View order for camera rotation r: returns the four corner offsets ordered as the view cell's
-- {nw, ne, se, sw} (u/v space), and the fold diagonal named in view space.
local VIEW = {}
do
    local corners = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
    for r = 0, 3 do
        local map = {}
        for n, vc in ipairs(corners) do
            -- world corner (0/1 offsets) that sits at view corner vc of a unit lot
            local x, y = G.wpos(vc[1], vc[2], r, 1, 1)
            for m, wc in ipairs(corners) do
                if math.abs(wc[1] - x) < 1e-9 and math.abs(wc[2] - y) < 1e-9 then map[n] = m end
            end
        end
        VIEW[r] = map
    end
end
function Rf.ViewCorners(c, r)
    local m = VIEW[(r or 0) % 4]
    local v = { c[m[1]], c[m[2]], c[m[3]], c[m[4]] }
    return v, Rf.Fold(v)
end

-- Which section is over cell (i, j)? Searches from the top level down (or only `level`).
function Rf.SectionAt(world, level, i, j)
    local data = Rf.Pieces(world)
    local lot = world.lot
    local k = j * lot.w + i + 1
    local best
    for _, s in ipairs(data.sections) do
        if (level == nil or s.level == level) then
            for _, c in ipairs(s.cells) do
                if c == k and (not best or s.level > best.level) then best = s end
            end
        end
    end
    return best
end

---------------------------------------------------------------------------------------------------
-- Edits: style, material, colour and shed side, for one building (section) or the whole lot.
-- args: { section = key | nil, style?, material?, color?, side? }
---------------------------------------------------------------------------------------------------
function Rf.PlanRoof(world, args)
    local lot = B.EnsureLot(world.lot)
    local plan = B.NewPlan(world, "roof", "Change roof")
    local data = Rf.Build(lot)
    local targets = {}
    for _, s in ipairs(data.sections) do
        if not args.section or s.key == args.section then targets[#targets + 1] = s end
    end
    if args.section and #targets == 0 then return B.Fail(plan, "There is no roof there: roofs cover indoor rooms with nothing built above them.") end
    if args.style and not Rf.STYLE[Rf.NormStyle(args.style)] then return B.Fail(plan, "Unknown roof style.") end
    local mat = args.material and Rf.Material(args.material)
    if args.material and not (mat and (mat.id == args.material or mat.id == "roof_" .. args.material)) then return B.Fail(plan, "Unknown roof material.") end
    if args.color then
        local okc = false
        local list = (mat or Rf.Material((targets[1] and targets[1].material) or lot.roof.material)).colors
        for _, c in ipairs(list) do if c.id == args.color then okc = true end end
        for _, c in ipairs(B.ROOF_COLORS) do if c.id == args.color then okc = true end end
        if not okc then return B.Fail(plan, "That colour isn't offered for this roof.") end
    end
    if args.side and not SIDE_NORMAL[args.side] then return B.Fail(plan, "Unknown side.") end
    local old = SS.U.deepcopy(lot.roof)
    local new = SS.U.deepcopy(lot.roof)
    new.overrides = type(new.overrides) == "table" and new.overrides or {}
    local cost = 0
    local changed = 0
    local function price(s, st, m, c, sd)
        local p = 0
        if st and Rf.NormStyle(st) ~= s.style then p = p + Rf.T.stylePrice * s.area end
        if m and m ~= s.material then p = p + (Rf.Material(m).price or 0) * s.area end
        if c and c ~= s.color then p = p + Rf.T.colorPrice * s.area end
        if sd and sd ~= s.side and s.style == "shed" then p = p + Rf.T.stylePrice * s.area end
        return p
    end
    local mid = mat and mat.id
    if args.section then
        local s = targets[1]
        local sec = { level = s.level, cells = s.cells }
        -- one override per building, stored on its first cell; stray ones inside it are merged
        local merged = {}
        for _, k in ipairs(s.cells) do
            local key = s.level .. ":" .. k
            local o = new.overrides[key]
            if type(o) == "table" then
                for f, v in pairs(o) do if merged[f] == nil then merged[f] = v end end
                new.overrides[key] = nil
            end
        end
        if args.style then merged.style = Rf.NormStyle(args.style) end
        if mid then merged.material = mid end
        if args.color then merged.color = args.color end
        if args.side then merged.side = args.side end
        new.overrides[s.key] = merged
        cost = price(s, args.style, mid, args.color, args.side)
        changed = 1
        plan.label = "Change roof of one building"
        for _, k in ipairs(sec.cells) do local i, j = cellOf(lot, k); plan.preview.cells[#plan.preview.cells + 1] = { i = i, j = j, level = s.level, roof = true } end
    else
        if args.style then new.style = Rf.NormStyle(args.style) end
        -- a bare legacy id ("shingle") that already means this material stays as it is
        if mid then new.material = (old.material and Rf.Material(old.material).id == mid) and old.material or mid end
        if args.color then new.color = args.color end
        if args.side then new.side = args.side end
        for key, o in pairs(new.overrides) do
            if type(o) == "table" then
                if args.style then o.style = nil end
                if mid then o.material = nil end
                if args.color then o.color = nil end
                if args.side then o.side = nil end
                if next(o) == nil then new.overrides[key] = nil end
            end
        end
        for _, s in ipairs(targets) do
            cost = cost + price(s, args.style, mid, args.color, args.side)
            for _, k in ipairs(s.cells) do local i, j = cellOf(lot, k); plan.preview.cells[#plan.preview.cells + 1] = { i = i, j = j, level = s.level, roof = true } end
        end
        changed = #targets
        plan.label = "Change roof (whole lot)"
    end
    if next(new.overrides) == nil then new.overrides = nil end
    if B.Same(old, new) then return B.Fail(plan, "The roof already looks like that.") end
    local parts = {}
    if args.style then parts[#parts + 1] = Rf.STYLE[Rf.NormStyle(args.style)].name end
    if mat then parts[#parts + 1] = mat.name end
    if args.color then
        local c = Rf.Color(mat or Rf.Material(lot.roof.material), args.color)
        parts[#parts + 1] = c.name
    end
    if args.side then parts[#parts + 1] = "low side " .. args.side end
    if #parts > 0 then plan.label = plan.label .. ": " .. table.concat(parts, ", ") end
    B.Add(plan, { t = "roof", old = old, new = new }, cost)
    plan.count = changed
    if changed == 0 then plan.notes[#plan.notes + 1] = "No roofs yet: the choice applies to roofs built later." end
    return B.Finalize(world, plan)
end

---------------------------------------------------------------------------------------------------
-- Save validation
---------------------------------------------------------------------------------------------------
SS.Save.RegisterValidator(function(root, problems)
    for lotId, lot in pairs(root.hood and root.hood.lots or {}) do
        if type(lot.roof) ~= "table" then lot.roof = { style = "gable" }; problems[#problems + 1] = "roof reset on " .. tostring(lotId) end
        lot.roof.style = Rf.NormStyle(lot.roof.style)
        if lot.roof.side and not SIDE_NORMAL[lot.roof.side] then lot.roof.side = nil end
        if lot.roof.overrides ~= nil then
            if type(lot.roof.overrides) ~= "table" then lot.roof.overrides = nil
            else
                for k, o in pairs(lot.roof.overrides) do
                    if type(k) ~= "string" or not k:match("^%d+:%d+$") or type(o) ~= "table" then lot.roof.overrides[k] = nil
                    else
                        if o.style then o.style = Rf.NormStyle(o.style) end
                        if o.side and not SIDE_NORMAL[o.side] then o.side = nil end
                    end
                end
                if next(lot.roof.overrides) == nil then lot.roof.overrides = nil end
            end
        end
    end
    return true
end)
