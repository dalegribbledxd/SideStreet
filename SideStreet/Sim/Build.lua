-- Build mode engine: walls (straight and diagonal), rooms, paint, floors, doors, windows, stairs,
-- fences/gates/railings/half walls, columns, outdoor steps, landscaping placement, delete, rotate,
-- eyedropper, structural rules and room maintenance.
-- Owner: build module (see ARCHITECTURE.md §3, docs/modules/build.md).
--
-- Every edit is a PLAN first: a list of data changes (diffs of lot fields) with a full cost,
-- validity + reason, warnings and preview marks. Nothing touches the lot until B.Commit, which
-- applies the diffs once, charges money once through SS.Money (skipped when B.IsFree), records an
-- SS.Undo transaction whose ops re-apply the same diffs, bumps lot.version, rebuilds derived data
-- and emits lotChanged. Cancelling a plan costs nothing because it never touched the lot.
local _, SS = ...
local G, W = SS.Grid, SS.World
local B = { rt = nil }
SS.Build = B

---------------------------------------------------------------------------------------------------
-- Tuning (prices in section-sign money; see ARCHITECTURE.md §9.7)
---------------------------------------------------------------------------------------------------
B.T = {
    wallPrice = 70,        -- one wall segment (plus the finish on each side)
    halfwallPrice = 45,    -- one half-wall segment (plus finishes)
    refundRate = 0.75,     -- demolition/replacement refund of a build item's price (Undo returns 100%)
    supportSpan = 2,       -- an upstairs floor tile may cantilever this many tiles from a wall/column below
    maxLine = 64,          -- longest wall/fence drag in segments
    maxCells = 400,        -- largest floor/terrain/pool rectangle in cells
    groundFloors = { grass = true, lawn = true },   -- level-0 "floor" ids that mean bare ground
}

-- Wall kinds. ENCLOSES: separates rooms and makes indoors (a closed door or an arch still counts
-- as the building's wall). SUPPORTS: carries an upstairs floor. FINISHED: takes interior/exterior finishes.
B.ENCLOSES = { wall = true, door = true, window = true, arch = true }
B.SUPPORTS = { wall = true, door = true, window = true, arch = true }
B.FINISHED = { wall = true, door = true, window = true, arch = true, halfwall = true }
B.KINDS = { wall = true, door = true, window = true, arch = true, fence = true, gate = true, railing = true, halfwall = true }

local function round(v) return math.floor(v + 0.5) end
local function fmt(v) return SS.U.fmtMoney(v) end
local function deepcopy(t) return SS.U.deepcopy(t) end
function B.Refund(price) return round((price or 0) * B.T.refundRate) end

-- Household charges are skipped while editing a community venue from neighbourhood management,
-- in sandbox money mode, or when no household is attached (fixtures, previews).
function B.IsFree(world)
    if world.editVenue or (world.settings and world.settings.sandboxMoney) then return true end
    if world.household == nil and rawget(world, "money") == nil then return true end
    return false
end

---------------------------------------------------------------------------------------------------
-- Build catalogue. Styles and materials come from Data/Finishes.lua (catalogue module). The
-- fallback sets below are used only for a category that Data/Finishes.lua does not provide, so
-- build mode is complete on its own; after integration the catalogue's own entries win.
---------------------------------------------------------------------------------------------------
B.ROOF_COLORS = {
    { id = "terracotta", name = "Terracotta", rgb = { 0.72, 0.38, 0.26 } },
    { id = "charcoal", name = "Charcoal", rgb = { 0.27, 0.28, 0.30 } },
    { id = "slate", name = "Slate Blue", rgb = { 0.36, 0.44, 0.52 } },
    { id = "moss", name = "Moss Green", rgb = { 0.38, 0.48, 0.32 } },
    { id = "sand", name = "Sandstone", rgb = { 0.80, 0.70, 0.52 } },
    { id = "brick", name = "Brick Red", rgb = { 0.58, 0.22, 0.18 } },
    { id = "cedar", name = "Weathered Cedar", rgb = { 0.55, 0.42, 0.30 } },
    { id = "pewter", name = "Pewter", rgb = { 0.62, 0.64, 0.66 } },
}

B.FALLBACK = {
    doors = {
        door_hollow = { name = "Hollow-Core Hallway Door", price = 110, style = "starter", desc = "Light enough to slam dramatically, too light to slam convincingly." },
        door_louvre = { name = "Louvred Closet Door", price = 150, style = "starter", desc = "Lets air through and secrets out." },
        door_panel = { name = "Six-Panel Parlour Door", price = 260, style = "traditional", desc = "Six panels, one for each relative who has knocked on it uninvited." },
        door_glass = { name = "Frosted Garden Door", price = 380, style = "contemporary", glass = true, desc = "Frosted glass: daylight in, identities blurred." },
        door_screen = { name = "Porch Screen Door", price = 90, style = "garden", glass = true, desc = "Stops flies. Does not stop the neighbour's opinions." },
        door_dutch = { name = "Split Stable Door", price = 340, style = "eclectic", desc = "Open the top half for conversation, keep the bottom half for dignity." },
        door_front = { name = "Oak Front Door with Fanlight", price = 620, style = "traditional", glass = true, desc = "A proper front door. Visitors straighten their collars on the step." },
        door_french = { name = "French Double Doors", price = 780, width = 2, style = "traditional", glass = true, desc = "Two glass doors that turn any patio into an occasion." },
        door_barn = { name = "Sliding Barn Doors", price = 540, width = 2, style = "eclectic", desc = "Rolls aside on a steel track, like a very polite train." },
        door_grand = { name = "Grand Entry Double Doors", price = 1200, width = 2, style = "contemporary", desc = "For households that want guests to feel slightly underdressed." },
        arch_round = { name = "Round Archway", price = 150, kind = "arch", style = "traditional", desc = "An opening with ambitions. No door, no draughts of doubt." },
        arch_wide = { name = "Wide Open Archway", price = 220, kind = "arch", width = 2, style = "contemporary", desc = "Two tiles of open plan for households that share everything, including noise." },
    },
    windows = {
        window_sash = { name = "Sliding Sash Window", price = 95, style = "starter", desc = "Goes up, comes down, occasionally stays where it is put." },
        window_casement = { name = "Cottage Casement", price = 140, style = "traditional", desc = "Swings out on a hinge like a small, glazed garden gate." },
        window_frosted = { name = "Frosted Bathroom Window", price = 120, style = "starter", light = 0.7, desc = "All of the daylight, none of the audience." },
        window_shutter = { name = "Shuttered Window", price = 160, style = "garden", desc = "Painted shutters that have never once been closed." },
        window_porthole = { name = "Porthole Window", price = 180, style = "eclectic", desc = "For households that would like the house to feel slightly nautical." },
        window_clerestory = { name = "High Clerestory Strip", price = 150, style = "contemporary", desc = "Light from up high, privacy down low." },
        window_tall = { name = "Tall Narrow Window", price = 240, style = "contemporary", desc = "Floor-to-ceiling slice of outdoors. Curtain sold separately and urgently." },
        window_picture = { name = "Picture Window", price = 260, style = "traditional", light = 1.3, desc = "Frames the garden like a painting that needs mowing." },
        window_arched = { name = "Arched Palladian Window", price = 350, style = "traditional", light = 1.2, desc = "A rounded top so the sky feels welcome." },
        window_stained = { name = "Stained Glass Panel", price = 480, style = "eclectic", light = 0.8, desc = "Colours the afternoon light the shade of an argument about taste." },
        window_wide = { name = "Wide Double Window", price = 320, width = 2, style = "contemporary", light = 1.2, desc = "Two tiles of glass for households with nothing to hide, or no curtains yet." },
        window_ribbon = { name = "Ribbon Window Pair", price = 280, width = 2, style = "contemporary", desc = "A long low band of glass that makes the room look designed on purpose." },
    },
    roofs = {
        roof_shingle = { name = "Asphalt Shingle", price = 3, style = "starter", desc = "Keeps the rain out and the budget in." },
        roof_shake = { name = "Cedar Shake", price = 5, style = "garden", desc = "Split cedar that smells faintly of weekends." },
        roof_clay = { name = "Clay Barrel Tile", price = 7, style = "traditional", desc = "Rounded tiles for a sunnier disposition." },
        roof_slate = { name = "Natural Slate", price = 10, style = "traditional", desc = "Heavy, handsome, and older than your grandparents' grudges." },
        roof_metal = { name = "Standing-Seam Metal", price = 8, style = "contemporary", desc = "Rain on it sounds like applause." },
        roof_thatch = { name = "Reed Thatch", price = 6, style = "eclectic", desc = "A roof with the texture of a very tidy haystack." },
    },
    fences = {
        fence_picket = { name = "White Picket Fence", price = 25, gatePrice = 120, style = "traditional", desc = "The classic. Keeps nothing in, but looks very sure about it." },
        fence_rail = { name = "Split-Rail Fence", price = 18, gatePrice = 90, style = "garden", desc = "Two rails and a rustic sense of boundaries." },
        fence_board = { name = "Privacy Board Fence", price = 35, gatePrice = 150, style = "starter", desc = "Tall boards so the neighbours can only hear what you are doing." },
        fence_iron = { name = "Wrought Iron Railings", price = 60, gatePrice = 300, style = "contemporary", desc = "Elegant spikes for a household with standards." },
    },
    railings = {
        railing_timber = { name = "Timber Balustrade", price = 30, style = "traditional", desc = "Turned spindles to lean on while pretending to admire the view." },
        railing_iron = { name = "Iron Balcony Rail", price = 55, style = "contemporary", desc = "Thin, black and reassuringly firm." },
        railing_glass = { name = "Glass Balustrade", price = 90, style = "contemporary", desc = "Safety you can see through, fingerprints included." },
    },
    terrain = {
        grass = { name = "Lawn", price = 0, desc = "Green, soft and quietly growing while nobody looks." },
        dirt = { name = "Bare Earth", price = 1, desc = "Honest dirt, ready for a garden or a mess." },
        stone = { name = "Crushed Stone", price = 3, desc = "Crunches underfoot so nobody sneaks up on the barbecue." },
        sand = { name = "Soft Sand", price = 2, desc = "A beach without the sea, the sea being a separate purchase." },
    },
}

-- Build-only object definitions (placed by build tools, never listed in buy mode).
local function buildDef(id, def)
    if SS.Objects[id] then return end
    def.buyable = false
    def.slots = def.slots or {}
    def.actions = def.actions or {}
    def.tags = def.tags or {}
    def.env = def.env or 0
    def.ratings = def.ratings or {}
    SS.Objects[id] = def
end
B.COLUMN_DEFS = { "build_column_timber", "build_column_brick", "build_column_stone" }
buildDef("build_column_timber", { name = "Square Timber Post", cat = "build_column", column = true, price = 80, style = "garden",
    desc = "Holds up a porch roof or a balcony, and occasionally a hammock.", height = 2.25, art = { model = "design/build/columns.json#timber" } })
buildDef("build_column_brick", { name = "Brick Pier", cat = "build_column", column = true, price = 160, style = "traditional",
    desc = "Solid enough to carry the upstairs and the weight of family expectations.", height = 2.25, env = 1, art = { model = "design/build/columns.json#brick" } })
buildDef("build_column_stone", { name = "Fluted Stone Column", cat = "build_column", column = true, price = 320, style = "traditional",
    desc = "Adds a little classical grandeur to the front porch and a lot to the bill.", height = 2.25, env = 3, art = { model = "design/build/columns.json#stone" } })
B.STEPS_DEFS = { "build_steps_stone", "build_steps_timber" }
buildDef("build_steps_stone", { name = "Stone Garden Steps", cat = "build_steps", steps = true, noBlock = true, price = 60, style = "garden",
    desc = "Turns a lawn slope into a proper approach. Place on a slope rising straight ahead.", art = { model = "design/build/steps.json#stone" } })
buildDef("build_steps_timber", { name = "Timber Sleeper Steps", cat = "build_steps", steps = true, noBlock = true, price = 40, style = "starter",
    desc = "Railway sleepers set into the hillside, minus the railway.", art = { model = "design/build/steps.json#timber" } })

-- Stair variants: the catalogue owns them (defs with `stairs = {...}`); two fallback variants are
-- added only if fewer than three exist when the build module loads.
local function stairCount()
    local n = 0
    for _, d in pairs(SS.Objects) do if d.stairs then n = n + 1 end end
    return n
end
if stairCount() < 3 then
    buildDef("stairs_long", { name = "Gentle Long-Run Stairs", cat = "build_stairs", price = 650, fp = { { 0, 0 }, { 0, 1 }, { 0, 2 } },
        desc = "Three tiles of shallow treads for knees that have opinions.",
        stairs = { bottom = { 0, 3 }, top = { 0, -1 }, run = { { 0, 2 }, { 0, 1 }, { 0, 0 } } }, art = { model = "design/build/stairs.json#long" } })
end
if stairCount() < 3 then
    buildDef("stairs_turn", { name = "Quarter-Turn Stairs", cat = "build_stairs", price = 820, fp = { { 0, 0 }, { 0, 1 }, { 1, 0 } },
        desc = "Climbs, turns the corner and arrives with a little flourish.",
        stairs = { bottom = { 0, 2 }, top = { 2, 0 }, run = { { 0, 1 }, { 0, 0 }, { 1, 0 } } }, art = { model = "design/build/stairs.json#turn" } })
end

-- Normalised catalogue lists: B.Items(kind) -> array of entries sorted by price then id.
-- Every entry keeps the original fields plus: id, name, price, desc, width (doors/windows),
-- kind ("door"|"arch" for doors), glass, light, gatePrice (fences), colors (roofs).
local itemCache = {}
local function source(kind)
    local F = SS.Finishes or {}
    local map = F[kind]
    if kind == "terrain" then map = map or F.terrainPaints or F.paints end
    if type(map) == "table" and next(map) ~= nil then return map, false end
    return B.FALLBACK[kind], true
end

local function normalise(kind, id, e)
    local it = {}
    for k, v in pairs(e) do it[k] = v end
    it.id = e.id or id
    it.name = e.name or id
    it.price = tonumber(e.price) or 0
    it.desc = e.desc or ""
    if kind == "doors" or kind == "windows" then
        local w = e.width or e.w or e.span or e.cells or (e.double and 2) or 1
        it.width = (tonumber(w) and tonumber(w) >= 2) and 2 or 1
        if kind == "doors" then
            it.kind = (e.kind == "arch" or e.arch or e.opening) and "arch" or "door"
            it.glass = e.glass or (e.light and e.light > 0) or false
        else
            it.kind = "window"
            it.light = tonumber(e.light) or 1
        end
    elseif kind == "fences" then
        it.gatePrice = tonumber(e.gatePrice or (type(e.gate) == "table" and e.gate.price)) or round(it.price * 5)
        it.gateName = (type(e.gate) == "table" and e.gate.name) or e.gateName or (it.name .. " Gate")
    elseif kind == "roofs" then
        local cols = {}
        if type(e.colors) == "table" and #e.colors > 0 then
            for n, c in ipairs(e.colors) do
                if type(c) == "table" then
                    cols[n] = { id = c.id or ("c" .. n), name = c.name or c.id or ("Colour " .. n), rgb = c.rgb or c.color or { c[1] or 1, c[2] or 1, c[3] or 1 } }
                else
                    local known
                    for _, p in ipairs(B.ROOF_COLORS) do if p.id == c then known = p end end
                    cols[n] = known or { id = tostring(c), name = tostring(c), rgb = { 0.6, 0.6, 0.6 } }
                end
            end
        else
            for n, p in ipairs(B.ROOF_COLORS) do cols[n] = p end
        end
        it.colors = cols
    end
    return it
end

function B.Items(kind)
    if kind == "stairs" then
        local out = {}
        for id, d in pairs(SS.Objects) do if d.stairs then out[#out + 1] = { id = id, name = d.name, price = d.price or 0, desc = d.desc or "", def = d } end end
        table.sort(out, function(a, b) if a.price ~= b.price then return a.price < b.price end return a.id < b.id end)
        return out
    elseif kind == "columns" or kind == "steps" then
        local out = {}
        for _, id in ipairs(kind == "columns" and B.COLUMN_DEFS or B.STEPS_DEFS) do
            local d = SS.Objects[id]
            if d then out[#out + 1] = { id = id, name = d.name, price = d.price or 0, desc = d.desc or "", def = d } end
        end
        return out
    elseif kind == "landscape" then
        local out = {}
        local TAGS = { "tree", "shrub", "flowers", "planter", "fountain", "birdbath", "garden_plot" }
        for id, d in pairs(SS.Objects) do
            local ok = d.buyable ~= false and (d.cat == "outdoor" or d.outdoor == true) and not d.community
            if not ok and d.buyable ~= false then
                for _, t in ipairs(TAGS) do if SS.Tags.Has(d, t) then ok = true end end
            end
            if ok then out[#out + 1] = { id = id, name = d.name, price = d.price or 0, desc = d.desc or "", def = d } end
        end
        table.sort(out, function(a, b) if a.price ~= b.price then return a.price < b.price end return a.id < b.id end)
        return out
    end
    local map = source(kind)
    local c = itemCache[kind]
    if c and c.src == map then return c.list end
    local list = {}
    for id, e in pairs(map or {}) do
        if type(e) == "table" and not (kind == "fences" and (e.gate == true or e.isGate)) then list[#list + 1] = normalise(kind, id, e) end
    end
    table.sort(list, function(a, b) if a.price ~= b.price then return a.price < b.price end return a.id < b.id end)
    itemCache[kind] = { src = map, list = list }
    return list
end

function B.Item(kind, id)
    if not id then return nil end
    for _, it in ipairs(B.Items(kind)) do if it.id == id then return it end end
end

-- Price of a wall/floor finish (0 when unknown).
function B.FinishPrice(kind, id)
    if not id then return 0 end
    local F = SS.Finishes and SS.Finishes[kind]
    local e = F and F[id]
    if e then return tonumber(e.price) or 0 end
    return 0
end

-- Bare ground or an outdoor surface (courtyards stay outdoors: they have no indoor floor).
function B.IsGround(fid) return fid == nil or B.T.groundFloors[fid] == true end
function B.IsOutdoorFloor(fid)
    if B.IsGround(fid) then return true end
    local e = SS.Finishes and SS.Finishes.floors and SS.Finishes.floors[fid]
    if e and (e.outdoor or e.exterior or e.ground or e.use == "outdoor" or e.cat == "outdoor" or e.cat == "paving") then return true end
    local s = tostring(fid)
    return (s:find("path") or s:find("patio") or s:find("deck") or s:find("paving") or s:find("gravel") or s:find("lawn")) and true or false
end

---------------------------------------------------------------------------------------------------
-- Lot data helpers (every lot field the build module owns may be missing on old or foreign lots)
---------------------------------------------------------------------------------------------------
function B.EnsureLot(lot)
    lot.floor = lot.floor or {}
    lot.walls = lot.walls or {}
    lot.diag = lot.diag or {}
    for level = 0, W.LEVELS - 1 do
        lot.floor[level] = lot.floor[level] or {}
        lot.walls[level] = lot.walls[level] or {}
        lot.diag[level] = lot.diag[level] or {}
    end
    lot.terrain = lot.terrain or {}
    lot.terrain.h = lot.terrain.h or {}
    lot.terrain.paint = lot.terrain.paint or {}
    lot.terrain.water = lot.terrain.water or {}
    lot.pool = lot.pool or {}
    lot.roof = lot.roof or { style = "gable" }
    lot.objects = lot.objects or {}
    return lot
end

local function idx(lot, i, j) return j * lot.w + i + 1 end
B.idx = idx
local function cellOf(lot, n) n = n - 1; return n % lot.w, math.floor(n / lot.w) end
B.CellOf = cellOf
local function inLot(lot, i, j) return i >= 0 and j >= 0 and i < lot.w and j < lot.h end

-- Edge helpers. "x:i:j" runs along x at y=j from corner (i,j) to (i+1,j); "y:i:j" runs along y at
-- x=i from (i,j) to (i,j+1). a = the lower-coordinate cell, b = the other.
function B.EdgeCorners(key)
    local axis, i, j = G.parseEdge(key)
    if axis == "x" then return i, j, i + 1, j end
    return i, j, i, j + 1
end
function B.EdgeCells(key)
    local _, _, _, ai, aj, bi, bj = G.parseEdge(key)
    return ai, aj, bi, bj
end
function B.NextEdge(key, d)
    local axis, i, j = G.parseEdge(key)
    if axis == "x" then return "x:" .. (i + d) .. ":" .. j end
    return "y:" .. i .. ":" .. (j + d)
end
function B.EdgeInLot(lot, key)
    local axis, i, j = G.parseEdge(key)
    if axis == "x" then return i >= 0 and i < lot.w and j >= 0 and j <= lot.h end
    return j >= 0 and j < lot.h and i >= 0 and i <= lot.w
end
-- Edges of cell (i, j) with the neighbour across each.
function B.CellEdges(i, j)
    return {
        { "x:" .. i .. ":" .. j, i, j - 1 }, { "x:" .. i .. ":" .. (j + 1), i, j + 1 },
        { "y:" .. i .. ":" .. j, i - 1, j }, { "y:" .. (i + 1) .. ":" .. j, i + 1, j },
    }
end

-- Nearest edge to a world point, and which side of it the point's cell is on.
function B.NearestEdge(wx, wy)
    local i, j = math.floor(wx), math.floor(wy)
    local fx, fy = wx - i, wy - j
    local best, key, side = fy, "x:" .. i .. ":" .. j, "b"
    if 1 - fy < best then best, key, side = 1 - fy, "x:" .. i .. ":" .. (j + 1), "a" end
    if fx < best then best, key, side = fx, "y:" .. i .. ":" .. j, "b" end
    if 1 - fx < best then best, key, side = 1 - fx, "y:" .. (i + 1) .. ":" .. j, "a" end
    return key, side, i, j, best
end

-- Diagonal wall geometry. dir 0 runs from corner (i,j) to (i+1,j+1); dir 1 from (i+1,j) to (i,j+1).
-- Side "a" is the half touching the cell's y=j edge (north); for dir 0 it also touches x=i+1 (east),
-- for dir 1 x=i (west). Side "b" is the other half.
function B.DiagSideCells(i, j, dir, side)
    if dir == 0 then
        if side == "a" then return { { i, j - 1 }, { i + 1, j } } end
        return { { i - 1, j }, { i, j + 1 } }
    end
    if side == "a" then return { { i, j - 1 }, { i - 1, j } } end
    return { { i + 1, j }, { i, j + 1 } }
end
function B.DiagSideAt(dir, fx, fy)
    if dir == 0 then return fy < fx and "a" or "b" end
    return (fx + fy < 1) and "a" or "b"
end

-- Snap a drag between grid corners to a straight or 45-degree line.
function B.SnapLine(x0, y0, x1, y1, allowDiag)
    local dx, dy = x1 - x0, y1 - y0
    local ax, ay = math.abs(dx), math.abs(dy)
    if allowDiag and ax > 0 and ay > 0 and math.abs(ax - ay) <= math.max(ax, ay) * 0.35 then
        local n = round((ax + ay) / 2)
        return x0, y0, x0 + (dx > 0 and n or -n), y0 + (dy > 0 and n or -n), true
    elseif ax >= ay then
        return x0, y0, x1, y0, false
    end
    return x0, y0, x0, y1, false
end

-- Straight line of edges between two corners on one grid line.
function B.LineEdges(x0, y0, x1, y1)
    local out = {}
    if y0 == y1 then
        for i = math.min(x0, x1), math.max(x0, x1) - 1 do out[#out + 1] = "x:" .. i .. ":" .. y0 end
    elseif x0 == x1 then
        for j = math.min(y0, y1), math.max(y0, y1) - 1 do out[#out + 1] = "y:" .. x0 .. ":" .. j end
    end
    return out
end

-- Cells crossed by a 45-degree line between two corners, with the wall direction.
function B.DiagCells(x0, y0, x1, y1)
    local out = {}
    local dx, dy = x1 - x0, y1 - y0
    if dx == 0 or math.abs(dx) ~= math.abs(dy) then return out, nil end
    local sx, sy = dx > 0 and 1 or -1, dy > 0 and 1 or -1
    local dir = (sx == sy) and 0 or 1
    for k = 0, math.abs(dx) - 1 do
        out[#out + 1] = { x0 + k * sx + (sx < 0 and -1 or 0), y0 + k * sy + (sy < 0 and -1 or 0) }
    end
    return out, dir
end

function B.RectEdges(x0, y0, x1, y1)
    local ax, bx, ay, by = math.min(x0, x1), math.max(x0, x1), math.min(y0, y1), math.max(y0, y1)
    local out = {}
    if bx == ax or by == ay then return out end
    for i = ax, bx - 1 do out[#out + 1] = "x:" .. i .. ":" .. ay; out[#out + 1] = "x:" .. i .. ":" .. by end
    for j = ay, by - 1 do out[#out + 1] = "y:" .. ax .. ":" .. j; out[#out + 1] = "y:" .. bx .. ":" .. j end
    return out
end

function B.RectCells(lot, i0, j0, i1, j1)
    local out = {}
    for j = math.max(0, math.min(j0, j1)), math.min(lot.h - 1, math.max(j0, j1)) do
        for i = math.max(0, math.min(i0, i1)), math.min(lot.w - 1, math.max(i0, i1)) do out[#out + 1] = { i, j } end
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Occupancy and structure computed from lot data only (works for any lot, attached or not,
-- and for a lot with a plan's changes temporarily applied).
---------------------------------------------------------------------------------------------------
local NOBLOCK_MOUNT = { wall = true, ceiling = true, surface = true, window = true }
function B.NonBlocking(def, o)
    if W.NonBlocking then return W.NonBlocking(def, o) end
    if not def then return true end
    return (def.noBlock or (def.mount and NOBLOCK_MOUNT[def.mount]) or (o and o.parent)) and true or false
end

-- occ[level][idx] = oid for blocking objects; stair parts; stairwells.
function B.Scan(lot)
    local s = { occ = {}, any = {}, well = {}, stairBottom = {}, stairTop = {}, stairRun = {}, stairs = {}, columns = {},
        ladderEdge = {}, ladderLand = {} }
    for level = 0, W.LEVELS - 1 do s.occ[level], s.any[level], s.well[level], s.stairBottom[level], s.stairTop[level], s.stairRun[level] = {}, {}, {}, {}, {}, {} end
    local ids = {}
    for id in pairs(lot.objects) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local o = lot.objects[id]
        local def = SS.Objects[o.def]
        if def then
            local lv = math.min(o.level or 0, W.LEVELS - 1)
            local cells = G.footprint(def, o)
            local nb = B.NonBlocking(def, o)
            for n = 1, #cells do
                local c = cells[n]
                if inLot(lot, c[1], c[2]) then
                    local k = idx(lot, c[1], c[2])
                    s.any[lv][k] = s.any[lv][k] or id
                    if not nb then s.occ[lv][k] = id end
                end
            end
            if def.column and inLot(lot, o.x, o.y) then s.columns[idx(lot, o.x, o.y) + lv * lot.w * lot.h] = id end
            -- pool ladder (level 0): its land cell and the edge people climb across
            if def.poolLadder and lv == 0 and inLot(lot, o.x, o.y) then
                local dx, dy = G.rot(0, 1, o.f or 0)
                s.ladderLand[idx(lot, o.x, o.y)] = id
                s.ladderEdge[G.edgeBetween(o.x, o.y, o.x + dx, o.y + dy)] = id
            end
            local st = W.StairInfo(o)
            if st then
                st.id = id
                s.stairs[#s.stairs + 1] = st
                if inLot(lot, st.bottom[1], st.bottom[2]) then s.stairBottom[lv][idx(lot, st.bottom[1], st.bottom[2])] = id end
                if lv + 1 < W.LEVELS and inLot(lot, st.top[1], st.top[2]) then s.stairTop[lv + 1][idx(lot, st.top[1], st.top[2])] = id end
                for n = 1, #st.run do
                    local c = st.run[n]
                    if inLot(lot, c[1], c[2]) then
                        s.stairRun[lv][idx(lot, c[1], c[2])] = id
                        if lv + 1 < W.LEVELS then s.well[lv + 1][idx(lot, c[1], c[2])] = id end
                    end
                end
            end
        end
    end
    return s
end

-- Is a cell usable for standing/building on (lot data only)? Returns false, reason when not.
function B.CellFree(lot, scan, level, i, j, ignoreOid)
    if not inLot(lot, i, j) then return false, "That is outside the lot." end
    local k = idx(lot, i, j)
    local o = scan.occ[level][k]
    if o and o ~= ignoreOid then
        local def = SS.Objects[lot.objects[o].def]
        return false, "The " .. (def and def.name or "object") .. " is in the way."
    end
    if lot.diag[level] and lot.diag[level][k] then return false, "A diagonal wall runs through that tile." end
    if level == 0 then
        if lot.pool[k] then return false, "That is part of the pool." end
        if lot.terrain.water[k] then return false, "That is a pond." end
    else
        if not lot.floor[level][k] then return false, "There is no floor there upstairs." end
        if scan.well[level][k] and scan.well[level][k] ~= ignoreOid then return false, "That is the stairwell." end
    end
    return true
end

-- Who is standing on a cell (the first by actor id), for refusing solid placements on people.
function B.ActorAt(world, level, i, j)
    local ids = SS.Sim.ActorIds(world)
    for n = 1, #ids do
        local a = world.actors[ids[n]]
        if a and not a.dead and a.x and (a.level or 0) == level and math.floor(a.x) == i and math.floor(a.y) == j then return a end
    end
    return nil
end

-- Public: can people/furniture occupy this cell of the attached lot (diagonal walls, pool, pond)?
function B.CellBlocked(world, level, i, j)
    local lot = world.lot
    if not inLot(lot, i, j) then return true, "That is outside the lot." end
    local k = idx(lot, i, j)
    if lot.diag and lot.diag[level] and lot.diag[level][k] then return true, "A diagonal wall runs through that tile." end
    if level == 0 and lot.pool and lot.pool[k] then return true, "That is part of the pool." end
    if level == 0 and lot.terrain and lot.terrain.water and lot.terrain.water[k] then return true, "That is a pond." end
    return false
end
-- For the catalogue's placement: may an object stand on this cell? (terrain, water, diagonals)
function B.CanOccupy(world, level, i, j)
    local bad, why = B.CellBlocked(world, level, i, j)
    if bad then return false, why end
    if level == 0 and SS.Terrain and SS.Terrain.Flat and not SS.Terrain.Flat(world, i, j) then return false, "The ground is sloped there; flatten it first." end
    if level == 0 then
        local bt = B.rt
        local lad = bt and bt.lot == world.lot and bt.scan and bt.scan.ladderLand[idx(world.lot, i, j)]
        if lad then return false, "That is where people climb out of the pool: keep the ladder clear." end
    end
    return true
end

local function cellFlat(lot, i, j)
    if SS.Terrain and SS.Terrain.FlatLot then return SS.Terrain.FlatLot(lot, i, j) end
    return true
end
local function cellHeight(lot, i, j)
    if SS.Terrain and SS.Terrain.CellBase then return SS.Terrain.CellBase(lot, i, j) end
    return 0
end
local function edgeLevelGround(lot, key)
    if not (SS.Terrain and SS.Terrain.CornerH) then return true end
    local x0, y0, x1, y1 = B.EdgeCorners(key)
    return SS.Terrain.CornerH(lot, x0, y0) == SS.Terrain.CornerH(lot, x1, y1)
end

-- Upstairs floor support: a level-1 floor tile is directly supported by a supporting wall on any of
-- its edges below, a diagonal wall in the cell below, or a column below; other tiles may
-- cantilever up to B.T.supportSpan tiles (through floor) from a directly supported tile.
function B.Support(lot, scan)
    scan = scan or B.Scan(lot)
    local plane = lot.w * lot.h
    local dist, queue = {}, {}
    local F = lot.floor[1]
    local W0 = lot.walls[0]
    for k in pairs(F) do
        local i, j = cellOf(lot, k)
        local direct = (lot.diag[0] and lot.diag[0][k]) or scan.columns[k] ~= nil
        if not direct then
            for _, e in ipairs(B.CellEdges(i, j)) do
                local wl = W0[e[1]]
                if wl and B.SUPPORTS[wl.kind] then direct = true; break end
            end
        end
        if direct then dist[k] = 0; queue[#queue + 1] = k end
    end
    local head = 1
    while head <= #queue do
        local k = queue[head]; head = head + 1
        local d = dist[k]
        if d < B.T.supportSpan then
            local i, j = cellOf(lot, k)
            for dd = 0, 3 do
                local v = G.DIRS[dd]
                local ni, nj = i + v[1], j + v[2]
                if inLot(lot, ni, nj) then
                    local nk = idx(lot, ni, nj)
                    if F[nk] and dist[nk] == nil then dist[nk] = d + 1; queue[#queue + 1] = nk end
                end
            end
        end
    end
    local unsupported = {}
    for k in pairs(F) do if dist[k] == nil then unsupported[#unsupported + 1] = k end end
    table.sort(unsupported)
    return dist, unsupported, plane
end

-- Upstairs regions (walkable level-1 cells joined by passable edges) and which ones stairs reach.
-- Returns accessible[idx] = true for level-1 cells reachable from a stair landing.
function B.UpperAccess(lot, scan)
    scan = scan or B.Scan(lot)
    local acc, queue = {}, {}
    local F, Wl = lot.floor[1], lot.walls[1]
    local function walkable(k) return F[k] and not scan.well[1][k] and not (lot.diag[1] and lot.diag[1][k]) end
    for k in pairs(scan.stairTop[1]) do
        if walkable(k) then acc[k] = true; queue[#queue + 1] = k end
    end
    local head = 1
    while head <= #queue do
        local k = queue[head]; head = head + 1
        local i, j = cellOf(lot, k)
        for dd = 0, 3 do
            local v = G.DIRS[dd]
            local ni, nj = i + v[1], j + v[2]
            if inLot(lot, ni, nj) then
                local nk = idx(lot, ni, nj)
                if not acc[nk] and walkable(nk) then
                    local wl = Wl[G.edgeBetween(i, j, ni, nj)]
                    if not wl or W.OPENINGS[wl.kind] then acc[nk] = true; queue[#queue + 1] = nk end
                end
            end
        end
    end
    local floors = 0
    for k in pairs(F) do if walkable(k) then floors = floors + 1 end end
    return acc, floors
end

---------------------------------------------------------------------------------------------------
-- Rooms (lot data only). Replaces the flood fill's result after every SS.World.Rebuild so that
-- diagonal walls separate rooms, fences/railings/half walls do not enclose, stairwells do not
-- make an upstairs room "outdoors", and a walled area with no indoor floor is an open courtyard.
---------------------------------------------------------------------------------------------------
function B.Rooms(lot, level, scan)
    scan = scan or B.Scan(lot)
    local walls = lot.walls[level] or {}
    local diag = lot.diag[level] or {}
    local well = scan.well[level]
    local function walkable(i, j)
        if not inLot(lot, i, j) then return false end
        local k = idx(lot, i, j)
        if diag[k] then return false end
        if level == 0 then return true end
        return lot.floor[level][k] ~= nil and not well[k]
    end
    local function barrier(i, j, ni, nj)
        local wl = walls[G.edgeBetween(i, j, ni, nj)]
        return wl and B.ENCLOSES[wl.kind]
    end
    local region, regions = {}, {}
    local function fill(si, sj, id)
        local stack = { si, sj }
        region[idx(lot, si, sj)] = id
        local cells = { idx(lot, si, sj) }
        while #stack > 0 do
            local j = table.remove(stack); local i = table.remove(stack)
            for d = 0, 3 do
                local v = G.DIRS[d]
                local ni, nj = i + v[1], j + v[2]
                if walkable(ni, nj) then
                    local nk = idx(lot, ni, nj)
                    if not region[nk] and not barrier(i, j, ni, nj) then
                        region[nk] = id
                        cells[#cells + 1] = nk
                        stack[#stack + 1] = ni; stack[#stack + 1] = nj
                    end
                end
            end
        end
        return cells
    end
    -- outdoor seeds: a cell open to the outside of the lot (its boundary edge has no enclosing
    -- wall, so a room built flush with the lot line is still a room); upstairs, also a cell open
    -- to a floorless (non-stairwell) tile
    local outdoor = {}
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do
            if walkable(i, j) and not region[idx(lot, i, j)] then
                local out = false
                for d = 0, 3 do
                    local v = G.DIRS[d]
                    local ni, nj = i + v[1], j + v[2]
                    if not inLot(lot, ni, nj) then
                        if not barrier(i, j, ni, nj) then out = true; break end
                    elseif level > 0 and not walkable(ni, nj) then
                        local nk = idx(lot, ni, nj)
                        if not well[nk] and not diag[nk] and not barrier(i, j, ni, nj) then out = true; break end
                    end
                end
                if out then
                    for _, k in ipairs(fill(i, j, 0)) do outdoor[#outdoor + 1] = k end
                end
            end
        end
    end
    local tmp = 0
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do
            if walkable(i, j) and not region[idx(lot, i, j)] then
                tmp = tmp + 1
                regions[tmp] = fill(i, j, -tmp)
            end
        end
    end
    local room, rooms = {}, {}
    rooms[0] = { id = 0, outdoor = true, area = 0, level = level, windows = 0, blocked = 0 }
    for _, k in ipairs(outdoor) do room[k] = 0 end
    rooms[0].area = #outdoor
    local rid = 0
    for t = 1, tmp do
        local cells = regions[t]
        local indoor = level > 0
        if not indoor then
            for _, k in ipairs(cells) do
                if not B.IsOutdoorFloor(lot.floor[0][k]) then indoor = true; break end
            end
        end
        if indoor then
            rid = rid + 1
            rooms[rid] = { id = rid, area = #cells, windows = 0, level = level, blocked = 0 }
            for _, k in ipairs(cells) do room[k] = rid end
        else
            for _, k in ipairs(cells) do room[k] = 0 end
            rooms[0].area = rooms[0].area + #cells
            rooms[0].courtyards = (rooms[0].courtyards or 0) + 1
        end
    end
    -- windows (and glass doors) light the indoor rooms on either side
    for key, wl in pairs(walls) do
        local lightAmt
        if wl.kind == "window" then
            local it = B.Item("windows", wl.style)
            lightAmt = it and it.light or 1
        elseif (wl.kind == "door") and wl.style then
            local it = B.Item("doors", wl.style)
            if it and it.glass then lightAmt = 0.5 end
        end
        if lightAmt then
            local ai, aj, bi, bj = B.EdgeCells(key)
            for _, c in ipairs({ { ai, aj }, { bi, bj } }) do
                if inLot(lot, c[1], c[2]) then
                    local r = rooms[room[idx(lot, c[1], c[2])] or 0]
                    if r and not r.outdoor then r.windows = r.windows + lightAmt end
                end
            end
        end
    end
    -- a diagonal cell belongs (for light and display) to the indoor room on its "a" side, else "b"
    for k, dg in pairs(diag) do
        local i, j = cellOf(lot, k)
        local pick = 0
        for _, side in ipairs({ "a", "b" }) do
            for _, c in ipairs(B.DiagSideCells(i, j, dg.dir or 0, side)) do
                if pick == 0 and inLot(lot, c[1], c[2]) then
                    local r = room[idx(lot, c[1], c[2])]
                    if r and r > 0 then pick = r end
                end
            end
        end
        room[k] = pick
    end
    for k, _ in pairs(scan.occ[level]) do
        local r = rooms[room[k] or 0]
        if r and not r.outdoor then r.blocked = r.blocked + 1 end
    end
    return room, rooms
end

---------------------------------------------------------------------------------------------------
-- Derived data after every SS.World.Rebuild: rooms (above), plus build-owned lookup tables for
-- the navigation hooks (diagonal cells, pools, ladders, ponds, slopes). Other build files add their
-- parts through B.RegisterDerived(fn(world, rt, bt, scan)).
---------------------------------------------------------------------------------------------------
B.derived = {}
function B.RegisterDerived(fn) B.derived[#B.derived + 1] = fn end

-- Solid cells: nobody may stand in them (diagonal wall cells, ponds). Other build files mark
-- theirs from B.RegisterDerived with B.MarkSolid(bt, level, idx).
function B.MarkSolid(bt, level, k)
    bt.solid[level][k] = true
    bt.solidAny = true
end

function B.PostRebuild(world, rt)
    rt = rt or SS.RT
    if not rt or not world or not world.lot then return end
    local lot = B.EnsureLot(world.lot)
    local scan = B.Scan(lot)
    local bt = { lot = lot, diag = {}, anyDiag = false, scan = scan, solid = {}, solidAny = false }
    for level = 0, W.LEVELS - 1 do
        bt.diag[level] = {}
        bt.solid[level] = {}
        for k in pairs(lot.diag[level]) do bt.diag[level][k] = true; bt.anyDiag = true; B.MarkSolid(bt, level, k) end
        if rt.room and rt.rooms then
            local room, rooms = B.Rooms(lot, level, scan)
            rt.room[level], rt.rooms[level] = room, rooms
        end
    end
    -- Pre-integration world module: its occupancy counted every object as solid. Non-blocking
    -- objects (pool ladders, outdoor steps, rugs) must not block their cell, as in the updated
    -- world module (W.NonBlocking), so keep only blocking objects in the occupancy map.
    if not W.NonBlocking and rt.occ then
        for level = 0, W.LEVELS - 1 do
            local occ = rt.occ[level]
            if occ then
                for k in pairs(occ) do occ[k] = scan.occ[level][k] end
            end
        end
    end
    for _, fn in ipairs(B.derived) do fn(world, rt, bt, scan) end
    rt.build = bt
    B.rt = bt
    return rt
end

-- Wrap the world rebuild so every caller (attach, catalogue placement, events) gets build data.
if W.RegisterRebuildHook then
    W.RegisterRebuildHook(function(world, rt) B.PostRebuild(world, rt) end)
else
    local baseRebuild = W.Rebuild
    W.Rebuild = function(world, ...)
        local rt = baseRebuild(world, ...)
        B.PostRebuild(world, rt or SS.RT)
        return rt
    end
end

-- Solid build cells are blocked for everyone, exactly like furniture, so static reachability,
-- recovery of stranded people and route planning all agree. Uses a blocked-cell hook when the
-- world module offers one (requested in docs/requests/build.md), else wraps SS.World.Blocked.
local function solidAt(world, level, i, j)
    local bt = B.rt
    if not bt or not bt.solidAny or bt.lot ~= world.lot then return false end
    local s = bt.solid[level or 0]
    return s ~= nil and s[j * world.lot.w + i + 1] == true
end
B.SolidAt = solidAt
if W.RegisterBlockedHook then
    W.RegisterBlockedHook(function(world, level, i, j) return solidAt(world, level, i, j) end)
else
    local baseBlocked = W.Blocked
    W.Blocked = function(world, level, i, j)
        if baseBlocked(world, level, i, j) then return true end
        return solidAt(world, level, i, j)
    end
end

-- Structural pass rules: physical geometry (diagonal wall cells, pool water), not rules like
-- locks or privacy. Each is a normal pass hook registered with { structural = true } AND is
-- listed in B.structural, so B.StructuralPass(world, level, i, j, ni, nj, who) answers "can this
-- mover physically step here". household-core's W.CanStepStructural (the "is there a way at all"
-- step of routes that ignore rules) runs the same hooks with the mover; build.structural_hooks
-- checks that both agree in a merged tree (docs/requests/build.md R-WORLD-2). Build never wraps
-- W.CanStepStatic: that walls-only step builds Nav's static regions without a mover, so treating
-- water as a wall there would cut swimmers off from the land. Regions that are too generous only
-- cost a failed search; diagonal wall cells are already Blocked cells, so regions skip them.
B.structural = {}
function B.RegisterStructuralPass(fn)
    B.structural[#B.structural + 1] = fn
    W.RegisterPassHook(fn, { structural = true })   -- trailing option for a hook API that honours it
end
function B.StructuralPass(world, level, i, j, ni, nj, who)
    local wl = world.lot.walls[level] and world.lot.walls[level][G.edgeBetween(i, j, ni, nj)]
    local hooks = B.structural
    for n = 1, #hooks do
        if hooks[n](world, level, i, j, ni, nj, wl, who) == false then return false end
    end
    return true
end

-- Diagonal wall cells are not walkable (entering or leaving one is refused).
B.RegisterStructuralPass(function(world, level, i, j, ni, nj)
    local bt = B.rt
    if not bt or not bt.anyDiag or bt.lot ~= world.lot then return end
    local d = bt.diag[level]
    local w = world.lot.w
    if d[nj * w + ni + 1] or d[j * w + i + 1] then return false end
end)

---------------------------------------------------------------------------------------------------
-- The change engine
---------------------------------------------------------------------------------------------------
local function same(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
B.Same = same

local function getField(lot, ch)
    local t = ch.t
    if t == "wall" then return lot.walls[ch.level][ch.key]
    elseif t == "diag" then return lot.diag[ch.level][ch.idx]
    elseif t == "floor" then return lot.floor[ch.level][ch.idx]
    elseif t == "h" then return lot.terrain.h[ch.idx]
    elseif t == "paint" then return lot.terrain.paint[ch.idx]
    elseif t == "water" then return lot.terrain.water[ch.idx]
    elseif t == "pool" then return lot.pool[ch.idx]
    elseif t == "obj" then return lot.objects[ch.oid]
    elseif t == "roof" then return lot.roof
    end
end

local function setField(lot, ch, v)
    if type(v) == "table" then v = deepcopy(v) end
    local t = ch.t
    if t == "wall" then lot.walls[ch.level][ch.key] = v
    elseif t == "diag" then lot.diag[ch.level][ch.idx] = v
    elseif t == "floor" then lot.floor[ch.level][ch.idx] = v
    elseif t == "h" then lot.terrain.h[ch.idx] = (v ~= 0) and v or nil
    elseif t == "paint" then lot.terrain.paint[ch.idx] = v
    elseif t == "water" then lot.terrain.water[ch.idx] = v
    elseif t == "pool" then lot.pool[ch.idx] = v
    elseif t == "obj" then lot.objects[ch.oid] = v
    elseif t == "roof" then lot.roof = v or { style = "gable" }
    end
end

-- Apply a list of changes in one direction. simulate = true skips world side effects (inventory).
function B.ApplyChanges(world, changes, dir, simulate)
    local lot = world.lot
    if dir == "new" then
        for n = 1, #changes do
            local ch = changes[n]
            if ch.t == "inv" then
                if not simulate and SS.Inventory then
                    if ch.add then SS.Inventory.Add(world, ch.item) else SS.Inventory.Remove(world, ch.item) end
                end
            else setField(lot, ch, ch.new) end
        end
    else
        for n = #changes, 1, -1 do
            local ch = changes[n]
            if ch.t == "inv" then
                if not simulate and SS.Inventory then
                    if ch.add then SS.Inventory.Remove(world, ch.item) else SS.Inventory.Add(world, ch.item) end
                end
            else setField(lot, ch, ch.old) end
        end
    end
end

-- The lot field a change writes ("wall:1:x:3:2", "floor:0:57", "obj:b4", "roof"...); nil for
-- inventory moves. A plan holds at most one change per field (B.Finalize enforces it).
local function fieldKey(ch)
    local t = ch.t
    if t == "wall" then return "wall:" .. tostring(ch.level) .. ":" .. tostring(ch.key)
    elseif t == "diag" or t == "floor" then return t .. ":" .. tostring(ch.level) .. ":" .. tostring(ch.idx)
    elseif t == "h" or t == "paint" or t == "water" or t == "pool" then return t .. ":" .. tostring(ch.idx)
    elseif t == "obj" then return "obj:" .. tostring(ch.oid)
    elseif t == "roof" then return "roof"
    end
    return nil
end
B.FieldKey = fieldKey

local function noOp(ch)
    if ch.t == "inv" then return false end
    if ch.t == "h" then return (ch.old or 0) == (ch.new or 0) end
    return same(ch.old, ch.new)
end

-- Do the lot fields still hold what `dir` expects (for safe undo/redo)? When one transaction
-- touches a field more than once (old saves, external records), undo expects the LAST change's
-- `new` and redo the FIRST change's `old`, which is what applying them in order leaves behind.
function B.ChangesHold(world, changes, field)
    local lot = world.lot
    local pick, order = {}, {}
    for n = 1, #changes do
        local ch = changes[n]
        local fk = fieldKey(ch)
        if fk then
            if pick[fk] == nil then order[#order + 1] = fk; pick[fk] = ch
            elseif field == "new" then pick[fk] = ch end
        end
    end
    for n = 1, #order do
        local ch = pick[order[n]]
        local cur = getField(lot, ch)
        local want = ch[field]
        if ch.t == "h" then cur, want = cur or 0, want or 0 end
        if not same(cur, want) then return false end
    end
    return true
end

function B.NewPlan(world, kind, label)
    local lot = B.EnsureLot(world.lot)
    return { ok = true, kind = kind, label = label, cost = 0, changes = {}, warnings = {}, notes = {},
        preview = { cells = {}, edges = {}, diag = {}, corners = {} }, version = lot.version or 0, lotId = lot.id, count = 0 }
end

function B.Fail(plan, why)
    if plan.ok then plan.ok = false; plan.why = why end
    return plan
end

function B.Add(plan, ch, cost)
    plan.changes[#plan.changes + 1] = ch
    plan.cost = plan.cost + (cost or 0)
    return ch
end

-- A change derived while the plan is applied (automatic railings, furniture that lost its
-- support). It takes effect at once. When the plan already changes that field (an erased
-- upstairs wall whose edge now needs a railing), the existing change keeps its original `old`
-- and takes the derived value, so every field still has exactly one change and undo/redo hold.
function B.AddDerived(world, plan, ch)
    setField(world.lot, ch, ch.new)
    local fk = fieldKey(ch)
    local index = plan.fieldIdx
    if fk and index and index[fk] then
        local prev = index[fk]
        prev.new = deepcopy(ch.new)
        return prev
    end
    plan.changes[#plan.changes + 1] = ch
    if fk and index then index[fk] = ch end
    return ch
end

function B.Warn(plan, text)
    for _, w in ipairs(plan.warnings) do if w == text then return end end
    plan.warnings[#plan.warnings + 1] = text
end

-- Money summary for previews: "Cost §468" / "Refund §30" / "Free (venue editing)".
function B.CostText(world, plan)
    if not plan then return "" end
    if B.IsFree(world) then return plan.cost ~= 0 and ("Free here (would be " .. fmt(math.abs(plan.cost)) .. ")") or "Free" end
    if plan.cost > 0 then return "Cost " .. fmt(plan.cost) end
    if plan.cost < 0 then return "Refund " .. fmt(-plan.cost) end
    return "No cost"
end

-- Structural invariants and derived changes, evaluated with the plan's changes temporarily
-- applied to the lot (and always reverted, even on error).
B.derivers = {}
function B.RegisterDeriver(fn) B.derivers[#B.derivers + 1] = fn end

local function wallMountEdge(o, def)
    local bx, by = G.rot(0, -1, o.f or 0)
    return G.edgeBetween(o.x, o.y, o.x + bx, o.y + by)
end
B.MountEdge = wallMountEdge

-- Who is using an object (the first by actor id, so the refusal names the same person every
-- time): sitting or lying on it, performing with it, or holding a reservation on it. skip(a)
-- true ignores that person (a swimmer is not "using" the ladder in the way that blocks removal).
local function objInUse(world, oid, skip)
    local o = world.lot.objects[oid]
    local ids = SS.Sim.ActorIds(world)
    for n = 1, #ids do
        local a = world.actors[ids[n]]
        if a and not (skip and skip(a)) then
            if a.onObj == oid then return a end
            if a.act and (a.act.oid == oid or (a.act.target and a.act.target.oid == oid)) and a.act.phase == "perform" then return a end
        end
    end
    if o and o.res then
        local best, unknown = nil, false
        for _, v in pairs(o.res) do
            local a = v and world.actors[v]
            if a then
                if not (skip and skip(a)) and (not best or tostring(v) < tostring(best)) then best = v end
            elseif v then
                unknown = true   -- a reservation by someone not on the lot any more
            end
        end
        if best then return world.actors[best] end
        if unknown then return true end
    end
    return nil
end
B.ObjInUse = objInUse

-- Objects whose support vanished in the (applied) plan: level-1 objects without floor or over a
-- stairwell, wall mounts without a wall, window mounts without a window, ceiling mounts without a
-- ceiling. Returns list of oids (children included) in sorted order.
local function displaced(world, scan, lot, before)
    local out, seen = {}, {}
    local roomsCache = {}
    local function indoor(level, i, j)
        if level > 0 then return true end
        if lot.floor[1][idx(lot, i, j)] then return true end
        roomsCache[level] = roomsCache[level] or (B.Rooms(lot, level, scan))
        local r = roomsCache[level][idx(lot, i, j)]
        return r and r > 0
    end
    local ids = {}
    for id in pairs(lot.objects) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local o = lot.objects[id]
        local def = SS.Objects[o.def]
        if def and not o.parent then
            local lv = o.level or 0
            local bad = false
            if lv > 0 then
                for _, c in ipairs(G.footprint(def, o)) do
                    if inLot(lot, c[1], c[2]) then
                        local k = idx(lot, c[1], c[2])
                        if not lot.floor[lv][k] or (scan.well[lv][k] and not def.stairs) then bad = true end
                    end
                end
            end
            if def.mount == "wall" or def.mount == "window" then
                local wl = lot.walls[lv][wallMountEdge(o, def)]
                local okKinds = def.mount == "window" and { window = true } or { wall = true, halfwall = true }
                local was = before and before[id]
                if not wl or not okKinds[wl.kind] then
                    -- only objects that were properly mounted before this edit are displaced by it
                    if was ~= false then bad = true end
                end
            elseif def.mount == "ceiling" then
                if not indoor(lv, o.x, o.y) and (not before or before[id] ~= false) then bad = true end
            end
            if bad and not seen[id] then
                seen[id] = true
                out[#out + 1] = id
            end
        end
    end
    -- children resting on displaced parents go with them
    local n = 1
    while n <= #out do
        local pid = out[n]
        for _, id in ipairs(ids) do
            local o = lot.objects[id]
            if o and o.parent == pid and not seen[id] then seen[id] = true; out[#out + 1] = id end
        end
        n = n + 1
    end
    return out
end

-- Mount status before an edit (so pre-existing oddities in old saves are not blamed on it).
local function mountStatus(world, scan, lot)
    local st = {}
    for id, o in pairs(lot.objects) do
        local def = SS.Objects[o.def]
        if def and (def.mount == "wall" or def.mount == "window") then
            local wl = lot.walls[o.level or 0][wallMountEdge(o, def)]
            local okKinds = def.mount == "window" and { window = true } or { wall = true, halfwall = true }
            st[id] = (wl and okKinds[wl.kind]) and true or false
        elseif def and def.mount == "ceiling" then
            st[id] = true
        end
    end
    return st
end

-- Auto railings: upstairs floor edges open to a drop get a railing (and lose it when the drop is
-- filled in), except the exit edge between a stair's top landing and its stairwell.
local function autoRailings(world, scan, lot, plan)
    local F = lot.floor[1]
    local Wl = lot.walls[1]
    local style = (B.Items("railings")[1] or {}).id
    local exits = {}
    for _, st in ipairs(scan.stairs) do
        local last = st.run[#st.run]
        if last then exits[G.edgeBetween(st.top[1], st.top[2], last[1], last[2])] = true end
    end
    local function solid(i, j)
        if not inLot(lot, i, j) then return false end
        local k = idx(lot, i, j)
        return F[k] ~= nil and not scan.well[1][k]
    end
    local want = {}
    for k in pairs(F) do
        local i, j = cellOf(lot, k)
        if not scan.well[1][k] then
            for _, e in ipairs(B.CellEdges(i, j)) do
                if not solid(e[2], e[3]) and not exits[e[1]] then want[e[1]] = true end
            end
        end
    end
    local keys = {}
    for key in pairs(want) do keys[#keys + 1] = key end
    for key, wl in pairs(Wl) do if wl.auto and not want[key] then keys[#keys + 1] = key end end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local wl = Wl[key]
        if want[key] and not wl then
            B.AddDerived(world, plan, { t = "wall", level = 1, key = key, old = nil, new = { kind = "railing", style = style, auto = true } })
        elseif (not want[key]) and wl and wl.auto then
            B.AddDerived(world, plan, { t = "wall", level = 1, key = key, old = deepcopy(wl), new = nil })
        end
    end
end

function B.Finalize(world, plan)
    if not plan.ok then return plan end
    local lot = world.lot
    -- one change per lot field: a tool that touched a field twice would apply only its last
    -- change but charge for both and leave an undo that can never match the lot
    local index = {}
    for n = 1, #plan.changes do
        local ch = plan.changes[n]
        local fk = fieldKey(ch)
        if fk then
            if index[fk] then
                plan.dupField = fk
                if SS.Log then SS.Log("build: plan %s changes %s twice", tostring(plan.kind), fk) end
                return B.Fail(plan, "That edit would change the same spot twice, so it was stopped. Try a smaller edit.")
            end
            index[fk] = ch
        end
    end
    plan.fieldIdx = index
    local scan0 = B.Scan(lot)
    local mounts = mountStatus(world, scan0, lot)
    local acc0 = B.UpperAccess(lot, scan0)
    local _, unsup0 = B.Support(lot, scan0)
    local unsupBefore = {}
    for _, k in ipairs(unsup0) do unsupBefore[k] = true end
    local mainCount = #plan.changes
    B.ApplyChanges(world, plan.changes, "new", true)
    local ok, err = pcall(function()
        local scan = B.Scan(lot)
        autoRailings(world, scan, lot, plan)
        for _, fn in ipairs(B.derivers) do fn(world, plan, scan, lot) end
        scan = B.Scan(lot)
        -- upstairs floor support
        local _, unsup = B.Support(lot, scan)
        for _, k in ipairs(unsup) do
            if not unsupBefore[k] then
                local i, j = cellOf(lot, k)
                B.Fail(plan, string.format("The upstairs floor at %d,%d would have nothing holding it up: keep a wall or column below within %d tiles.", i, j, B.T.supportSpan))
                break
            end
        end
        -- upstairs walls stand on floor
        for key, wl in pairs(lot.walls[1]) do
            if not wl.auto then
                local ai, aj, bi, bj = B.EdgeCells(key)
                local fa = inLot(lot, ai, aj) and lot.floor[1][idx(lot, ai, aj)]
                local fb = inLot(lot, bi, bj) and lot.floor[1][idx(lot, bi, bj)]
                if not fa and not fb then B.Fail(plan, "An upstairs wall would be left standing on nothing; remove it first.") end
            end
        end
        -- stairs keep their landing and a clear stairwell
        for _, st in ipairs(scan.stairs) do
            local lv = st.level
            if lv + 1 < W.LEVELS then
                if not (inLot(lot, st.top[1], st.top[2]) and lot.floor[lv + 1][idx(lot, st.top[1], st.top[2])]) then
                    B.Fail(plan, "The stairs need their upstairs landing floor.")
                end
            end
        end
        -- doors and gates keep a clear tile on both sides
        for level = 0, W.LEVELS - 1 do
            for key, wl in pairs(lot.walls[level]) do
                if W.OPENINGS[wl.kind] then
                    local ai, aj, bi, bj = B.EdgeCells(key)
                    for _, c in ipairs({ { ai, aj }, { bi, bj } }) do
                        if inLot(lot, c[1], c[2]) then
                            local k = idx(lot, c[1], c[2])
                            if level > 0 and (not lot.floor[level][k] or scan.well[level][k]) then
                                B.Fail(plan, "An upstairs doorway would open onto thin air.")
                            elseif level == 0 and (lot.pool[k] or lot.terrain.water[k]) then
                                B.Fail(plan, "A doorway would open straight into water.")
                            elseif lot.diag[level][k] then
                                B.Fail(plan, "A diagonal wall would block a doorway.")
                            end
                        end
                    end
                end
            end
        end
        -- the lot entrance stays usable
        if lot.entry then
            local ei, ej = lot.entry[1], lot.entry[2]
            if inLot(lot, ei, ej) then
                local fine = B.CellFree(lot, scan, 0, ei, ej)
                if not fine then B.Fail(plan, "Keep the lot entrance clear (the tile where people arrive from the street).") end
            end
        end
        -- furniture that lost its support goes to household inventory (or the edit is refused)
        if plan.ok then
            for _, oid in ipairs(displaced(world, scan, lot, mounts)) do
                local o = lot.objects[oid]
                local def = SS.Objects[o.def]
                local user = objInUse(world, oid)
                if user then
                    B.Fail(plan, (type(user) == "table" and user.name or "Someone") .. " is using the " .. (def and def.name or "object") .. ".")
                    break
                end
                if not (SS.Inventory and SS.Inventory.Add) then
                    B.Fail(plan, "Move the " .. (def and def.name or "object") .. " first.")
                    break
                end
                local item = { kind = "object", def = o.def, name = def and def.name or o.def, value = o.paid or (def and def.price) or 0,
                    data = { variant = o.variant, state = deepcopy(o.state), paid = o.paid, bought = o.bought, wear = o.wear, dirt = o.dirt, from = "build" } }
                B.AddDerived(world, plan, { t = "obj", oid = oid, old = deepcopy(o), new = nil })
                plan.changes[#plan.changes + 1] = { t = "inv", item = item, add = true }
                B.Warn(plan, "The " .. (def and def.name or "object") .. " was moved to household inventory.")
            end
        end
        -- upstairs access warnings
        local acc1, floors1 = B.UpperAccess(lot, scan)
        local lost = false
        for k in pairs(acc0) do
            if lot.floor[1][k] and not acc1[k] and not scan.well[1][k] then lost = true; break end
        end
        if lost then
            B.Warn(plan, "Warning: part of the upstairs floor no longer has any stairs leading to it.")
            plan.accessLost = true
            -- people standing up there would be stuck: the UI asks before committing
            local stuck = {}
            for _, id in ipairs(SS.Sim.ActorIds(world)) do
                local a = world.actors[id]
                if a and not a.dead and (a.level or 0) == 1 and a.x and a.y then
                    local k = idx(lot, math.floor(a.x), math.floor(a.y))
                    if acc0[k] and not acc1[k] then stuck[#stuck + 1] = a.name or id end
                end
            end
            if #stuck > 0 then
                local text = table.concat(stuck, ", ") .. (#stuck == 1 and " is" or " are") .. " upstairs and would have no stairs down."
                plan.stuck = stuck
                plan.danger = plan.danger and (plan.danger .. "\n" .. text) or text
            end
        elseif plan.kind == "floor" and floors1 > 0 then
            local unreach = 0
            for k in pairs(lot.floor[1]) do if not acc1[k] and not scan.well[1][k] then unreach = unreach + 1 end end
            if unreach > 0 and #scan.stairs == 0 then B.Warn(plan, "No stairs reach the upstairs floor yet (Stairs tab).") end
        end
    end)
    -- revert everything, main changes and derived ones
    B.ApplyChanges(world, plan.changes, "old", true)
    plan.fieldIdx = nil
    if not ok then B.Fail(plan, "Could not check that edit: " .. tostring(err)) end
    plan.derivedCount = #plan.changes - mainCount
    -- a derived value that undid a main change (a railing erased and put straight back) is no change
    local kept, dropped = {}, false
    for n = 1, #plan.changes do
        local ch = plan.changes[n]
        if noOp(ch) then dropped = true else kept[#kept + 1] = ch end
    end
    if dropped then plan.changes = kept end
    return plan
end

-- Relocate people left inside something solid (new wall-cell, stairs, pool, pond, removed floor)
-- to the nearest usable tile, with a message. Swimmers inside a pool are left alone, and so is
-- anyone using the object on their tile (seated, in bed, at a counter): that is where they belong.
local function usingObjectAt(world, a, level, i, j)
    if not a or not a.id then return false end
    local occ = SS.RT and SS.RT.occ and SS.RT.occ[level]
    local oid = occ and occ[idx(world.lot, i, j)]
    if not oid then return false end
    if oid == true then return a.onObj ~= nil end
    if a.onObj == oid then return true end
    local act = a.act
    return act ~= nil and (act.oid == oid or (act.target ~= nil and act.target.oid == oid))
end

-- Can this person swim (the pool module's rule: people, not infants)?
local function canSwim(a)
    return a ~= nil and (a.kind or "human") == "human" and a.age ~= "infant"
end

-- opts.onLoad: the save was just attached, so the pool module's runtime notes (a.swimming, the
-- swim outfit memo) are gone; anyone who can swim and was saved standing in pool water is
-- swimming, and stays there.
local function badCell(world, a, level, i, j, opts)
    local lot = world.lot
    if not inLot(lot, i, j) then return true end
    if W.Blocked(world, level, i, j) and not (usingObjectAt(world, a, level, i, j) and not solidAt(world, level, i, j)) then return true end
    local blocked = B.CellBlocked(world, level, i, j)
    if blocked then
        -- someone already swimming stays in the water; a dry person the water came back under
        -- (an undo of a pool removal) is moved out like anyone else in the way
        if level == 0 and lot.pool[idx(lot, i, j)] then
            if a.swimming or (a.act and SS.Pool and SS.Pool.SWIM_IIDS and SS.Pool.SWIM_IIDS[a.act.iid]) or (a.tmp and a.tmp.swimOutfit) then return false end
            if opts and opts.onLoad and a.id and canSwim(a) then return false end
        end
        return true
    end
    return false
end
B.BadCell = badCell

local NOBODY = {}

-- A cell a displaced person can move THROUGH on the way out (pool water yes; walls, diagonal
-- walls, furniture and missing upstairs floor no).
local function traversable(world, level, i, j)
    local lot = world.lot
    if not inLot(lot, i, j) then return false end
    if lot.diag[level] and lot.diag[level][idx(lot, i, j)] then return false end
    return not W.Blocked(world, level, i, j)
end

-- Nearest usable tile reachable from (i, j) without passing through walls. openings = false
-- keeps to the person's own room; true also goes through doors, arches and gates. The start cell
-- may itself be solid (that is why they are moving): from a diagonal-wall cell only the half
-- they stand in leads anywhere.
local function reachableSpot(world, a, level, i, j, openings)
    local lot = world.lot
    if not inLot(lot, i, j) then return nil end
    local walls = lot.walls[level] or {}
    local seen, q = {}, {}
    local function push(ci, cj, fi, fj)
        if not inLot(lot, ci, cj) then return end
        local k = idx(lot, ci, cj)
        if seen[k] then return end
        local wl = walls[G.edgeBetween(fi, fj, ci, cj)]
        if wl and not (openings and W.OPENINGS[wl.kind]) then return end
        seen[k] = true
        q[#q + 1] = ci; q[#q + 1] = cj
    end
    seen[idx(lot, i, j)] = true
    local dg = lot.diag[level] and lot.diag[level][idx(lot, i, j)]
    if dg then
        local side = B.DiagSideAt(dg.dir or 0, (a.x or i + 0.5) - i, (a.y or j + 0.5) - j)
        for _, c in ipairs(B.DiagSideCells(i, j, dg.dir or 0, side)) do push(c[1], c[2], i, j) end
    else
        for d = 0, 3 do local v = G.DIRS[d]; push(i + v[1], j + v[2], i, j) end
    end
    local head = 1
    while head <= #q do
        local ci, cj = q[head], q[head + 1]
        head = head + 2
        if not badCell(world, NOBODY, level, ci, cj) then return ci, cj end
        if traversable(world, level, ci, cj) or (level == 0 and lot.pool[idx(lot, ci, cj)]) then
            for d = 0, 3 do local v = G.DIRS[d]; push(ci + v[1], cj + v[2], ci, cj) end
        end
    end
    return nil
end

-- Last resort: the nearest usable tile at all (square rings), used only when walls enclose the
-- person completely.
local function ringSpot(world, level, i, j)
    for r = 1, math.max(world.lot.w, world.lot.h) do
        for dj = -r, r do
            for di = -r, r do
                if math.max(math.abs(di), math.abs(dj)) == r and not badCell(world, NOBODY, level, i + di, j + dj) then return i + di, j + dj end
            end
        end
    end
    return nil
end

-- Where does a displaced person go? Same room first, then through doors, then (upstairs) the
-- ground below, and only then the nearest free tile regardless of walls.
function B.RelocationSpot(world, a, lv, i, j)
    local levels = lv > 0 and { lv, 0 } or { 0 }
    for _, L in ipairs(levels) do
        -- stepping down from upstairs: the tile straight below first
        if L ~= lv and not badCell(world, NOBODY, L, i, j) then return i, j, L end
        for _, openings in ipairs({ false, true }) do
            local fi, fj = reachableSpot(world, a, L, i, j, openings)
            if fi then return fi, fj, L end
        end
    end
    for _, L in ipairs(levels) do
        local fi, fj = ringSpot(world, L, i, j)
        if fi then return fi, fj, L end
    end
    return nil
end

-- opts.onLoad = true when called for a freshly attached save (see badCell).
function B.RelocateActors(world, opts)
    local moved = {}
    local ids = SS.Sim.ActorIds(world)
    for _, id in ipairs(ids) do
        local a = world.actors[id]
        if a and a.x and not (a.act and a.act.flight) then
            local lv = a.level or 0
            local i, j = math.floor(a.x), math.floor(a.y)
            if badCell(world, a, lv, i, j, opts) then
                local fi, fj, fl = B.RelocationSpot(world, a, lv, i, j)
                if fi then
                    if a.act and SS.Actions and SS.Actions.Finish then SS.Actions.Finish(world, a, "cancelled") end
                    a.x, a.y, a.level, a.z = fi + 0.5, fj + 0.5, fl, nil
                    moved[#moved + 1] = a
                    if SS.Actions and SS.Actions.Message then SS.Actions.Message(world, a, a.name .. " stepped out of the way of the building work.", "noroute") end
                end
            end
        end
    end
    return moved
end

-- Routes planned before an edit may cross new walls: make walkers plan again.
function B.InvalidateRoutes(world)
    if SS.Actions and SS.Actions.InvalidateRoutes then return SS.Actions.InvalidateRoutes(world) end
    for _, a in pairs(world.actors or {}) do
        if a.act and a.act.phase == "route" and not a.act.flight then a.act.phase = "plan" end
    end
end

-- After any committed edit, undo or redo.
local function notify(world, text)
    if SS.UI and SS.UI.Notice and SS.UI.frame then SS.UI.Notice(text) end
    SS.Emit("buildNotice", text)
end

-- People upstairs whose tile no stairs reach any more (after an edit, an undo or a redo).
function B.StrandedUpstairs(world)
    local out = {}
    local lot = world.lot
    local ids = SS.Sim.ActorIds(world)
    local acc
    for _, id in ipairs(ids) do
        local a = world.actors[id]
        if a and not a.dead and (a.level or 0) > 0 and not (a.act and a.act.flight) then
            acc = acc or B.UpperAccess(lot, B.Scan(lot))
            local i, j = math.floor(a.x), math.floor(a.y)
            if inLot(lot, i, j) and not acc[idx(lot, i, j)] then out[#out + 1] = a end
        end
    end
    return out
end

function B.AfterEdit(world, kind, ref)
    local lot = world.lot
    lot.version = (lot.version or 0) + 1
    W.Rebuild(world)
    B.RelocateActors(world)
    B.InvalidateRoutes(world)
    if SS.Roof and SS.Roof.Invalidate then SS.Roof.Invalidate(lot) end
    SS.Emit("lotChanged", kind or "build", ref)
    local stranded = B.StrandedUpstairs(world)
    if #stranded > 0 then
        local names = {}
        for n, a in ipairs(stranded) do names[n] = a.name end
        notify(world, "Warning: " .. table.concat(names, ", ") .. (#names == 1 and " is" or " are") .. " upstairs with no stairs down.")
        SS.Emit("buildWarning", "stranded", names)
    end
end

-- Commit a plan: apply once, charge once, record undo. Returns ok, why | tx.
function B.Commit(world, plan)
    if not plan then return false, "Nothing to build." end
    if not plan.ok then return false, plan.why or "That can't be built." end
    local lot = world.lot
    if plan.lotId ~= lot.id or plan.version ~= (lot.version or 0) then return false, "The lot changed; try that again." end
    if plan.external then return B.CommitExternal(world, plan) end
    if #plan.changes == 0 then return false, plan.why or "Nothing would change." end
    local free = B.IsFree(world)
    local cost = free and 0 or plan.cost
    if cost > 0 and (world.money or 0) < cost then
        return false, "That costs " .. fmt(cost) .. "; the household has " .. fmt(world.money or 0) .. "."
    end
    local changes = plan.changes
    B.ApplyChanges(world, changes, "new", false)
    if cost ~= 0 then SS.Money(world, -cost, cost > 0 and "build" or "refund", plan.label) end
    local tx = SS.Undo.Begin(world, plan.label)
    tx.cost = cost
    tx.free = free
    tx.kind = plan.kind
    tx.ops[1] = {
        undo = function() B.ApplyChanges(world, changes, "old", false) end,
        redo = function() B.ApplyChanges(world, changes, "new", false) end,
        checkUndo = function() return B.ChangesHold(world, changes, "new"), "The lot has changed since; that step can no longer be undone." end,
        checkRedo = function() return B.ChangesHold(world, changes, "old"), "The lot has changed since; that step can no longer be redone." end,
    }
    SS.Undo.Commit(world, tx)
    B.AfterEdit(world, plan.kind, plan.label)
    for _, w in ipairs(plan.warnings) do notify(world, w) end
    if plan.accessLost and SS.Sim and SS.Sim.Emergency then
        SS.Emit("buildWarning", "access", plan)
    end
    return true, tx
end

---------------------------------------------------------------------------------------------------
-- Tools: walls, half walls, fences, railings (straight or diagonal), rooms, erase
---------------------------------------------------------------------------------------------------
local LINE_KINDS = { wall = true, halfwall = true, fence = true, railing = true }

local function wallFinishDefault()
    local F = SS.Finishes and SS.Finishes.walls
    if F and F.paint_cream then return "paint_cream" end
    local list = {}
    for id in pairs(F or {}) do list[#list + 1] = id end
    table.sort(list)
    return list[1]
end
B.DefaultWallFinish = wallFinishDefault

-- Price of a new segment of `kind` with `style` (fence/railing family) or finish `fin` (both sides).
function B.SegmentPrice(kind, style, fin, finB)
    if kind == "wall" or kind == "halfwall" then
        return (kind == "wall" and B.T.wallPrice or B.T.halfwallPrice) + B.FinishPrice("walls", fin) + B.FinishPrice("walls", finB or fin)
    elseif kind == "fence" then
        local it = B.Item("fences", style) or B.Items("fences")[1]
        return it and it.price or 20
    elseif kind == "railing" then
        local it = B.Item("railings", style) or B.Items("railings")[1]
        return it and it.price or 30
    end
    return 0
end

-- Full value of an existing wall record (structure, finishes, door/window/gate item).
function B.WallValue(wl)
    if not wl then return 0 end
    local k = wl.kind
    local v = 0
    if k == "fence" or k == "gate" then
        local it = B.Item("fences", wl.style)
        v = it and it.price or 20
        if k == "gate" then v = v + (it and it.gatePrice or 100) end
    elseif k == "railing" then
        if wl.auto then return 0 end
        local it = B.Item("railings", wl.style)
        v = it and it.price or 30
    else
        v = (k == "halfwall" and B.T.halfwallPrice or B.T.wallPrice) + B.FinishPrice("walls", wl.a) + B.FinishPrice("walls", wl.b)
        if (k == "door" or k == "arch") and (wl.part or 1) == 1 then local it = B.Item("doors", wl.style); v = v + (it and it.price or 0) end
        if k == "window" and (wl.part or 1) == 1 then local it = B.Item("windows", wl.style); v = v + (it and it.price or 0) end
    end
    return v
end

local function stairEdges(scan, lot)
    -- edges a wall may not cross: between consecutive stair cells, and landing-to-stairwell upstairs
    local e = { [0] = {}, [1] = {} }
    for _, st in ipairs(scan.stairs) do
        local prev = st.bottom
        for n = 1, #st.run do
            local c = st.run[n]
            e[st.level][G.edgeBetween(prev[1], prev[2], c[1], c[2])] = true
            if n > 1 and st.level + 1 < W.LEVELS then e[st.level + 1][G.edgeBetween(prev[1], prev[2], c[1], c[2])] = true end
            prev = c
        end
        if st.level + 1 < W.LEVELS then e[st.level + 1][G.edgeBetween(prev[1], prev[2], st.top[1], st.top[2])] = true end
    end
    return e
end

-- Why can't a new segment go on this edge? nil when fine.
local function edgeProblem(world, lot, scan, level, key, kind, stairE)
    if not B.EdgeInLot(lot, key) then return "That is outside the lot." end
    local ai, aj, bi, bj = B.EdgeCells(key)
    local ina, inb = inLot(lot, ai, aj), inLot(lot, bi, bj)
    if level == 0 then
        if kind == "wall" or kind == "halfwall" then
            if (ina and not cellFlat(lot, ai, aj)) or (inb and not cellFlat(lot, bi, bj)) then return "Walls need flat ground: flatten the terrain first." end
        elseif not edgeLevelGround(lot, key) then
            return "Fences and railings follow level ground only: flatten along this line first."
        end
        if ina and inb and lot.pool[idx(lot, ai, aj)] and lot.pool[idx(lot, bi, bj)] then return "That would put a wall in the middle of the pool." end
        if scan.ladderEdge[key] then return "That would block the pool ladder: people climb in and out there." end
        if ina and inb and lot.terrain.water[idx(lot, ai, aj)] and lot.terrain.water[idx(lot, bi, bj)] then return "That would put a wall in the middle of the pond." end
    else
        local fa = ina and lot.floor[level][idx(lot, ai, aj)]
        local fb = inb and lot.floor[level][idx(lot, bi, bj)]
        if not fa and not fb then return "Upstairs walls need a floor to stand on." end
    end
    if ina and inb then
        local oa, ob = scan.any[level][idx(lot, ai, aj)], scan.any[level][idx(lot, bi, bj)]
        if oa and oa == ob then
            local o = lot.objects[oa]
            local def = o and SS.Objects[o.def]
            if def and not B.NonBlocking(def, o) then return "The " .. def.name .. " is in the way." end
        end
    end
    if stairE[level] and stairE[level][key] then return "That would block the stairs." end
    return nil
end

-- Plan a straight line of segments (wall, halfwall, fence, railing) between two corners.
-- args: { level, x0, y0, x1, y1, kind, finish, style }
function B.PlanLine(world, args)
    local kind = args.kind or "wall"
    local level = args.level or 0
    local lot = B.EnsureLot(world.lot)
    local names = { wall = "wall", halfwall = "half wall", fence = "fence", railing = "railing" }
    local plan = B.NewPlan(world, kind, "Build " .. names[kind])
    if not LINE_KINDS[kind] then return B.Fail(plan, "Unknown wall kind.") end
    if kind == "fence" or kind == "railing" then
        args.style = args.style or ((B.Items(kind == "fence" and "fences" or "railings")[1]) or {}).id
    else
        args.finish = args.finish or wallFinishDefault()
    end
    local x0, y0, x1, y1, isDiag = args.x0, args.y0, args.x1, args.y1, args.diag
    if isDiag == nil then isDiag = (x0 ~= x1 and y0 ~= y1) end
    if isDiag then return B.PlanDiagLine(world, args, plan) end
    local edges = B.LineEdges(x0, y0, x1, y1)
    if #edges == 0 then return B.Fail(plan, "Drag along the grid to draw a " .. names[kind] .. ".") end
    if #edges > B.T.maxLine then return B.Fail(plan, "That line is too long (" .. #edges .. " segments; the limit is " .. B.T.maxLine .. ").") end
    local scan = B.Scan(lot)
    local stairE = stairEdges(scan, lot)
    local skipped = 0
    for _, key in ipairs(edges) do
        local existing = lot.walls[level][key]
        local bad = edgeProblem(world, lot, scan, level, key, kind, stairE)
        plan.preview.edges[#plan.preview.edges + 1] = { key = key, level = level, kind = kind, bad = bad and true or nil }
        if bad then B.Fail(plan, bad)
        elseif existing and not existing.auto then skipped = skipped + 1
        else
            local rec
            if kind == "fence" or kind == "railing" then rec = { kind = kind, style = args.style }
            else rec = { kind = kind, a = args.finish, b = args.finishB or args.finish } end
            local price = B.SegmentPrice(kind, args.style, args.finish, args.finishB)
            B.Add(plan, { t = "wall", level = level, key = key, old = deepcopy(existing), new = rec }, price)
            plan.count = plan.count + 1
        end
    end
    if plan.ok and plan.count == 0 then B.Fail(plan, "There is already a wall along all of that line.") end
    plan.label = string.format("Build %d %s%s", plan.count, names[kind], plan.count == 1 and "" or "s")
    if skipped > 0 then plan.notes[#plan.notes + 1] = skipped .. " existing segment(s) kept" end
    return B.Finalize(world, plan)
end

-- Diagonal segments (walls or fences) through cells.
function B.PlanDiagLine(world, args, plan)
    local kind = args.kind or "wall"
    local level = args.level or 0
    local lot = B.EnsureLot(world.lot)
    plan = plan or B.NewPlan(world, "diag", "Build diagonal wall")
    plan.kind = "diag"
    if kind ~= "wall" and kind ~= "fence" then return B.Fail(plan, "Only walls and fences can run diagonally.") end
    local cells, dir = B.DiagCells(args.x0, args.y0, args.x1, args.y1)
    if #cells == 0 then return B.Fail(plan, "Diagonal walls run at exactly 45 degrees.") end
    if #cells > B.T.maxLine then return B.Fail(plan, "That line is too long.") end
    local scan = B.Scan(lot)
    local fin = args.finish or wallFinishDefault()
    for _, c in ipairs(cells) do
        local i, j = c[1], c[2]
        local k = inLot(lot, i, j) and idx(lot, i, j)
        local bad
        if not k then bad = "That is outside the lot."
        else
            local existing = lot.diag[level][k]
            if existing then bad = existing.dir == dir and "There is already a diagonal wall there." or "Diagonal walls can't cross." end
            if not bad then
                local fine, why = B.CellFree(lot, scan, level, i, j)
                if not fine then bad = why end
            end
            if not bad and level == 0 and not cellFlat(lot, i, j) then bad = "Diagonal walls need flat ground." end
            if not bad and (scan.stairBottom[level][k] or scan.stairTop[level][k] or scan.stairRun[level][k]) then bad = "That would block the stairs." end
            if not bad and lot.entry and lot.entry[1] == i and lot.entry[2] == j and level == 0 then bad = "Keep the lot entrance clear." end
            if not bad and level == 0 and scan.ladderLand[k] then bad = "That is where people climb out of the pool: keep the ladder clear." end
            if not bad then
                local who = B.ActorAt(world, level, i, j)
                if who then bad = who.name .. " is standing there." end
            end
        end
        plan.preview.diag[#plan.preview.diag + 1] = { i = i, j = j, level = level, dir = dir, kind = kind, bad = bad and true or nil }
        if bad then B.Fail(plan, bad)
        else
            local rec = { dir = dir, kind = kind }
            if kind == "fence" then rec.style = args.style or ((B.Items("fences")[1]) or {}).id else rec.a, rec.b = fin, args.finishB or fin end
            B.Add(plan, { t = "diag", level = level, idx = k, old = nil, new = rec }, B.SegmentPrice(kind, rec.style, fin, args.finishB))
            plan.count = plan.count + 1
        end
    end
    plan.label = string.format("Build %d diagonal %s%s", plan.count, kind, plan.count == 1 and "" or "s")
    return B.Finalize(world, plan)
end

-- Rectangular room: walls around the rectangle between two corners (existing segments kept).
function B.PlanRoom(world, args)
    local lot = B.EnsureLot(world.lot)
    local level = args.level or 0
    local plan = B.NewPlan(world, "wall", "Build room")
    local edges = B.RectEdges(args.x0, args.y0, args.x1, args.y1)
    if #edges == 0 then return B.Fail(plan, "Drag out a rectangle at least one tile wide and deep.") end
    if #edges > B.T.maxLine * 4 then return B.Fail(plan, "That room is too large.") end
    local fin = args.finish or wallFinishDefault()
    local scan = B.Scan(lot)
    local stairE = stairEdges(scan, lot)
    for _, key in ipairs(edges) do
        local existing = lot.walls[level][key]
        local bad = edgeProblem(world, lot, scan, level, key, "wall", stairE)
        plan.preview.edges[#plan.preview.edges + 1] = { key = key, level = level, kind = "wall", bad = bad and true or nil }
        if bad then B.Fail(plan, bad)
        elseif not existing or existing.auto then
            B.Add(plan, { t = "wall", level = level, key = key, old = deepcopy(existing), new = { kind = "wall", a = fin, b = args.finishB or fin } }, B.SegmentPrice("wall", nil, fin, args.finishB))
            plan.count = plan.count + 1
        end
    end
    if plan.ok and plan.count == 0 then B.Fail(plan, "Those walls are already built.") end
    local w, h = math.abs(args.x1 - args.x0), math.abs(args.y1 - args.y0)
    plan.label = string.format("Build %dx%d room (%d walls)", w, h, plan.count)
    if plan.ok and args.withFloor and args.floor then
        local cells = B.RectCells(lot, math.min(args.x0, args.x1), math.min(args.y0, args.y1), math.max(args.x0, args.x1) - 1, math.max(args.y0, args.y1) - 1)
        B.AddFloorChanges(world, plan, level, cells, args.floor, scan)
    end
    return B.Finalize(world, plan)
end

-- Erase every wall kind along a line (straight edges or diagonal cells). Double doors and windows
-- that lose one half become plain wall on the other half, so nothing is left hanging.
function B.PlanErase(world, args)
    local lot = B.EnsureLot(world.lot)
    local level = args.level or 0
    local plan = B.NewPlan(world, "erase", "Erase walls")
    local x0, y0, x1, y1 = args.x0, args.y0, args.x1, args.y1
    if x0 ~= x1 and y0 ~= y1 then
        local cells = B.DiagCells(x0, y0, x1, y1)
        for _, c in ipairs(cells) do
            if inLot(lot, c[1], c[2]) then
                local k = idx(lot, c[1], c[2])
                local dg = lot.diag[level][k]
                plan.preview.diag[#plan.preview.diag + 1] = { i = c[1], j = c[2], level = level, dir = dg and dg.dir or 0, erase = true }
                if dg then
                    local v = B.SegmentPrice(dg.kind, dg.style, dg.a, dg.b)
                    B.Add(plan, { t = "diag", level = level, idx = k, old = deepcopy(dg), new = nil }, -B.Refund(v))
                    plan.count = plan.count + 1
                end
            end
        end
    else
        local edges = B.LineEdges(x0, y0, x1, y1)
        local set = {}
        for _, key in ipairs(edges) do set[key] = true end
        for _, key in ipairs(edges) do
            local wl = lot.walls[level][key]
            plan.preview.edges[#plan.preview.edges + 1] = { key = key, level = level, kind = "erase", erase = true }
            if wl and not (wl.auto and args.keepAuto) then
                B.Add(plan, { t = "wall", level = level, key = key, old = deepcopy(wl), new = nil }, -B.Refund(B.WallValue(wl)))
                plan.count = plan.count + 1
                if wl.pair and not set[wl.pair] then
                    local pw = lot.walls[level][wl.pair]
                    if pw then
                        local plain = { kind = (pw.kind == "gate") and "fence" or "wall", a = pw.a, b = pw.b, style = (pw.kind == "gate") and pw.style or nil }
                        B.Add(plan, { t = "wall", level = level, key = wl.pair, old = deepcopy(pw), new = plain }, -B.Refund(B.WallValue(pw) - B.WallValue(plain)))
                    end
                end
            end
        end
    end
    if plan.ok and plan.count == 0 then B.Fail(plan, "There are no walls along that line.") end
    plan.label = string.format("Erase %d wall segment%s", plan.count, plan.count == 1 and "" or "s")
    return B.Finalize(world, plan)
end

---------------------------------------------------------------------------------------------------
-- Paint (wall finishes per side; one side or a whole room)
---------------------------------------------------------------------------------------------------
-- args: { level, key = edgeKey | idx = diagCellIdx, side = "a"|"b", finish } or { level, room = {i, j}, finish }
function B.PlanPaint(world, args)
    local lot = B.EnsureLot(world.lot)
    local level = args.level or 0
    local fin = args.finish
    local plan = B.NewPlan(world, "paint", "Paint walls")
    if not (fin and SS.Finishes and SS.Finishes.walls and SS.Finishes.walls[fin]) then return B.Fail(plan, "Pick a wall finish first.") end
    local newPrice = B.FinishPrice("walls", fin)
    local sides = 0
    -- One change per wall segment or diagonal cell. A segment with the room on both of its sides
    -- (a half wall or peninsula inside the room, a freestanding wall in the garden) or a double
    -- door whose halves are both reached gets both sides merged into that one change, and each
    -- side is charged once, only when its finish actually changes.
    local byKey, shown = {}, {}
    local function paintEdge(key, side)
        local wl = lot.walls[level][key]
        if not wl or not B.FINISHED[wl.kind] then return end
        if not shown[key .. side] then
            shown[key .. side] = true
            plan.preview.edges[#plan.preview.edges + 1] = { key = key, level = level, kind = "paint", side = side }
        end
        local ch = byKey[key]
        if (ch and ch.new or wl)[side] == fin then return end
        if not ch then
            ch = B.Add(plan, { t = "wall", level = level, key = key, old = deepcopy(wl), new = deepcopy(wl) }, 0)
            byKey[key] = ch
        end
        ch.new[side] = fin
        plan.cost = plan.cost + newPrice - B.Refund(B.FinishPrice("walls", wl[side]))
        sides = sides + 1
        -- a double door/window keeps both halves' finishes matched
        if wl.pair and wl.pair ~= key then paintEdge(wl.pair, side) end
    end
    local function paintDiag(k, side)
        local dg = lot.diag[level][k]
        if not dg or dg.kind ~= "wall" then return end
        local dk = "d" .. k
        local ch = byKey[dk]
        if (ch and ch.new or dg)[side] == fin then return end
        if not ch then
            ch = B.Add(plan, { t = "diag", level = level, idx = k, old = deepcopy(dg), new = deepcopy(dg) }, 0)
            byKey[dk] = ch
        end
        ch.new[side] = fin
        plan.cost = plan.cost + newPrice - B.Refund(B.FinishPrice("walls", dg[side]))
        sides = sides + 1
    end
    if args.room then
        local ri, rj = args.room[1], args.room[2]
        if not inLot(lot, ri, rj) then return B.Fail(plan, "Click inside a room to paint all of its walls.") end
        local scan = B.Scan(lot)
        local room = B.Rooms(lot, level, scan)
        local rid = room[idx(lot, ri, rj)]
        local cells = {}
        for k, r in pairs(room) do if r == rid then cells[#cells + 1] = k end end
        table.sort(cells)
        local done = {}
        for _, k in ipairs(cells) do
            local i, j = cellOf(lot, k)
            if lot.diag[level][k] then
                local dg = lot.diag[level][k]
                for _, side in ipairs({ "a", "b" }) do
                    for _, c in ipairs(B.DiagSideCells(i, j, dg.dir, side)) do
                        if inLot(lot, c[1], c[2]) and room[idx(lot, c[1], c[2])] == rid and not done["d" .. k .. side] then
                            done["d" .. k .. side] = true
                            paintDiag(k, side)
                        end
                    end
                end
            else
                for _, e in ipairs(B.CellEdges(i, j)) do
                    local key = e[1]
                    local ai, aj = B.EdgeCells(key)
                    local side = (ai == i and aj == j) and "a" or "b"
                    if not done[key .. side] then done[key .. side] = true; paintEdge(key, side) end
                end
            end
        end
        plan.label = "Paint room"
    elseif args.idx then
        paintDiag(args.idx, args.side or "a")
    else
        paintEdge(args.key, args.side or "a")
    end
    if plan.ok and sides == 0 then B.Fail(plan, "Nothing to paint there (or it already has that finish).") end
    plan.count = sides
    local nm = SS.Finishes.walls[fin].name or fin
    plan.label = string.format("%s: %s (%d side%s)", plan.label, nm, sides, sides == 1 and "" or "s")
    return B.Finalize(world, plan)
end

---------------------------------------------------------------------------------------------------
-- Floors: single tile, rectangle, enclosed room, remove; ground and upstairs
---------------------------------------------------------------------------------------------------
function B.FloorProblem(world, lot, scan, level, i, j, remove)
    if not inLot(lot, i, j) then return "That is outside the lot." end
    local k = idx(lot, i, j)
    if level == 0 then
        if lot.pool[k] then return "That is the pool; remove the pool tile first." end
        if lot.terrain.water[k] then return "That is a pond." end
        if not remove and not cellFlat(lot, i, j) then return "Floors need flat ground: flatten the terrain first." end
    else
        if scan.well[level][k] then return "That is the stairwell: it stays open above the stairs." end
        if remove then
            local who = B.ActorAt(world, level, i, j)
            if who then return who.name .. " is standing there." end
        else
            if SS.Terrain and SS.Terrain.CellBase and cellHeight(lot, i, j) ~= 0 then return "Upper floors stand on level ground at the lot's base height." end
        end
    end
    return nil
end

function B.AddFloorChanges(world, plan, level, cells, finish, scan, remove)
    local lot = world.lot
    local newPrice = remove and 0 or B.FinishPrice("floors", finish)
    for _, c in ipairs(cells) do
        local i, j = c[1], c[2]
        local bad = B.FloorProblem(world, lot, scan, level, i, j, remove)
        plan.preview.cells[#plan.preview.cells + 1] = { i = i, j = j, level = level, bad = bad and true or nil }
        if bad then
            if not plan.skipBad then B.Fail(plan, bad) end
        else
            local k = idx(lot, i, j)
            local old = lot.floor[level][k]
            local oldPrice = (level == 0 and B.IsGround(old)) and 0 or B.FinishPrice("floors", old)
            if remove then
                if old ~= nil and not (level == 0 and B.IsGround(old)) then
                    B.Add(plan, { t = "floor", level = level, idx = k, old = old, new = nil }, -B.Refund(oldPrice))
                    plan.count = plan.count + 1
                end
            elseif old ~= finish then
                B.Add(plan, { t = "floor", level = level, idx = k, old = old, new = finish }, newPrice - B.Refund(oldPrice))
                plan.count = plan.count + 1
            end
        end
    end
end

-- args: { level, finish, remove = bool, cells = {{i,j}...} | rect = {i0,j0,i1,j1} | room = {i,j} }
function B.PlanFloor(world, args)
    local lot = B.EnsureLot(world.lot)
    local level = args.level or 0
    local plan = B.NewPlan(world, "floor", args.remove and "Remove floor" or "Lay floor")
    if not args.remove then
        if not (args.finish and SS.Finishes and SS.Finishes.floors and SS.Finishes.floors[args.finish]) then return B.Fail(plan, "Pick a floor finish first.") end
    end
    local scan = B.Scan(lot)
    local cells = args.cells
    if args.rect then
        local r = args.rect
        if (math.abs(r[3] - r[1]) + 1) * (math.abs(r[4] - r[2]) + 1) > B.T.maxCells then return B.Fail(plan, "That area is too large (limit " .. B.T.maxCells .. " tiles).") end
        cells = B.RectCells(lot, r[1], r[2], r[3], r[4])
        plan.skipBad = args.skipBad
    elseif args.room then
        local ri, rj = args.room[1], args.room[2]
        if not inLot(lot, ri, rj) then return B.Fail(plan, "Click inside an enclosed room.") end
        local room = B.Rooms(lot, level, scan)
        local rid = room[idx(lot, ri, rj)]
        -- a courtyard or unfloored enclosure counts as outdoors; fill it by its walls instead
        if not rid or rid == 0 then
            local encl = B.EnclosedArea(lot, level, ri, rj, scan)
            if not encl then return B.Fail(plan, "Room fill needs an area enclosed by walls; this one is open to the outdoors.") end
            cells = encl
        else
            cells = {}
            for k, r in pairs(room) do if r == rid and not lot.diag[level][k] then local i, j = cellOf(lot, k); cells[#cells + 1] = { i, j } end end
            table.sort(cells, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
        end
        if #cells > B.T.maxCells then return B.Fail(plan, "That room is too large to fill in one go.") end
    end
    if not cells or #cells == 0 then return B.Fail(plan, "Pick where the floor goes.") end
    B.AddFloorChanges(world, plan, level, cells, args.finish, scan, args.remove)
    if plan.ok and plan.count == 0 then B.Fail(plan, args.remove and "There is no floor to remove there." or "That floor is already there.") end
    local nm = (not args.remove) and ((SS.Finishes.floors[args.finish] or {}).name or args.finish) or nil
    plan.label = args.remove and string.format("Remove %d floor tile%s", plan.count, plan.count == 1 and "" or "s")
        or string.format("Lay %d tile%s of %s", plan.count, plan.count == 1 and "" or "s", nm)
    return B.Finalize(world, plan)
end

-- Cells enclosed by walls around (i, j) regardless of flooring (for room fill in a new room).
function B.EnclosedArea(lot, level, si, sj, scan)
    scan = scan or B.Scan(lot)
    local walls = lot.walls[level]
    local seen = { [idx(lot, si, sj)] = true }
    local out = { { si, sj } }
    local n = 1
    while n <= #out do
        local i, j = out[n][1], out[n][2]
        n = n + 1
        for d = 0, 3 do
            local v = G.DIRS[d]
            local ni, nj = i + v[1], j + v[2]
            local wl = walls[G.edgeBetween(i, j, ni, nj)]
            if not (wl and B.ENCLOSES[wl.kind]) then
                if not inLot(lot, ni, nj) then return nil end
                local nk = idx(lot, ni, nj)
                if level > 0 and not lot.floor[level][nk] and not scan.well[level][nk] then return nil end
                if not seen[nk] and not lot.diag[level][nk] then
                    seen[nk] = true
                    out[#out + 1] = { ni, nj }
                    if #out > B.T.maxCells then return nil end
                end
            end
        end
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Doors, arches and windows (single or double width, snapped to walls)
---------------------------------------------------------------------------------------------------
-- args: { level, key, style, kind = "door"|"window", side = "a"|"b" }
function B.PlanOpening(world, args)
    local lot = B.EnsureLot(world.lot)
    local level = args.level or 0
    local cat = args.kind == "window" and "windows" or "doors"
    local item = B.Item(cat, args.style) or B.Items(cat)[1]
    local plan = B.NewPlan(world, args.kind == "window" and "window" or "door", "Place " .. (args.kind == "window" and "window" or "door"))
    if not item then return B.Fail(plan, "No " .. cat .. " in the catalogue.") end
    local key = args.key
    if not key or not B.EdgeInLot(lot, key) then return B.Fail(plan, "Point at a wall.") end
    local function usable(k)
        local wl = lot.walls[level][k]
        if not wl then return false, "Doors and windows go into walls: build a wall here first." end
        if not (wl.kind == "wall" or wl.kind == "door" or wl.kind == "window" or wl.kind == "arch") then
            if wl.kind == "fence" or wl.kind == "gate" then return false, "That is a fence: use the Gate tool." end
            return false, "That kind of wall can't take a door or window."
        end
        if not B.EdgeInLot(lot, k) then return false, "That is outside the lot." end
        return true
    end
    local keys = { key }
    local ok, why = usable(key)
    if not ok then return B.Fail(plan, why) end
    if item.width == 2 then
        local k2 = B.NextEdge(key, 1)
        local ok2 = usable(k2)
        if not ok2 then k2 = B.NextEdge(key, -1); ok2 = usable(k2) end
        if not ok2 then return B.Fail(plan, "The " .. item.name .. " is two tiles wide: it needs two wall segments in a row.") end
        keys[2] = k2
        table.sort(keys)
    end
    local scan = B.Scan(lot)
    local needClear = item.kind ~= "window"
    for _, k in ipairs(keys) do
        plan.preview.edges[#plan.preview.edges + 1] = { key = k, level = level, kind = item.kind }
        local ai, aj, bi, bj = B.EdgeCells(k)
        if needClear then
            for _, c in ipairs({ { ai, aj }, { bi, bj } }) do
                if not inLot(lot, c[1], c[2]) then return B.Fail(plan, "A doorway on the lot boundary would lead nowhere.") end
                local fine, why2 = B.CellFree(lot, scan, level, c[1], c[2])
                if not fine then return B.Fail(plan, "A doorway needs a clear tile on both sides: " .. why2) end
            end
        end
        local wl = lot.walls[level][k]
        if wl.pair then
            local partnerInside = false
            for _, kk in ipairs(keys) do if kk == wl.pair then partnerInside = true end end
            if not partnerInside then return B.Fail(plan, "Remove the double door or window there first (Delete tool).") end
        end
    end
    for n, k in ipairs(keys) do
        local wl = lot.walls[level][k]
        local nw = { kind = item.kind, style = item.id, a = wl.a, b = wl.b, side = args.side or "b" }
        if #keys == 2 then nw.span, nw.part, nw.pair = 2, n, keys[3 - n] end
        local oldItem = 0
        if wl.kind ~= "wall" and (wl.part or 1) == 1 then
            local oi = B.Item(wl.kind == "window" and "windows" or "doors", wl.style)
            oldItem = oi and oi.price or 0
        end
        B.Add(plan, { t = "wall", level = level, key = k, old = deepcopy(wl), new = nw }, (n == 1 and item.price or 0) - B.Refund(oldItem))
    end
    plan.count = 1
    plan.item = item
    plan.label = "Place " .. item.name
    return B.Finalize(world, plan)
end

-- Gate: turns a fence segment into a gate of the same family (a route, like a door).
function B.PlanGate(world, args)
    local lot = B.EnsureLot(world.lot)
    local level = args.level or 0
    local plan = B.NewPlan(world, "gate", "Place gate")
    local wl = args.key and lot.walls[level][args.key]
    if not wl or wl.kind ~= "fence" then return B.Fail(plan, "Gates go into fences: point at a fence segment.") end
    local fam = B.Item("fences", wl.style) or B.Items("fences")[1]
    local scan = B.Scan(lot)
    local ai, aj, bi, bj = B.EdgeCells(args.key)
    for _, c in ipairs({ { ai, aj }, { bi, bj } }) do
        if not inLot(lot, c[1], c[2]) then return B.Fail(plan, "A gate on the lot boundary would lead nowhere.") end
        local fine, why = B.CellFree(lot, scan, level, c[1], c[2])
        if not fine then return B.Fail(plan, "A gate needs a clear tile on both sides: " .. why) end
    end
    plan.preview.edges[1] = { key = args.key, level = level, kind = "gate" }
    B.Add(plan, { t = "wall", level = level, key = args.key, old = deepcopy(wl), new = { kind = "gate", style = wl.style } }, fam and fam.gatePrice or 100)
    plan.count = 1
    plan.label = "Place " .. (fam and fam.gateName or "gate")
    return B.Finalize(world, plan)
end

---------------------------------------------------------------------------------------------------
-- Objects placed by build tools: stairs, columns, outdoor steps, landscaping (fallback placement)
---------------------------------------------------------------------------------------------------
function B.NewObjectId(lot)
    local n = lot.nextBuild or 1
    while lot.objects["b" .. n] do n = n + 1 end
    lot.nextBuild = n + 1
    return "b" .. n
end

local function household(world) return world.household and world.household.id end

local function newObj(world, id, defId, x, y, f, level)
    local def = SS.Objects[defId]
    return { id = id, def = defId, x = x, y = y, f = f or 0, level = level or 0, bought = world.time, paid = def and def.price or 0,
        owner = household(world), state = def and def.startState and deepcopy(def.startState) or nil }
end

-- Validate stairs of `defId` at (x, y, f) on `level`. Returns ok, why, info.
function B.CheckStairs(world, defId, x, y, f, level, ignoreOid)
    local lot = B.EnsureLot(world.lot)
    local def = SS.Objects[defId]
    if not (def and def.stairs) then return false, "Those aren't stairs." end
    level = level or 0
    if level + 1 >= W.LEVELS then return false, "Stairs lead up one floor; there is no floor above this one." end
    local st = W.StairInfo({ def = defId, x = x, y = y, f = f, level = level })
    local scan = B.Scan(lot)
    if ignoreOid then
        -- evaluate as if the object being moved/rotated were not there
        local saved = lot.objects[ignoreOid]
        lot.objects[ignoreOid] = nil
        scan = B.Scan(lot)
        lot.objects[ignoreOid] = saved
    end
    local function flatDatum(i, j)
        if not cellFlat(lot, i, j) then return false end
        return cellHeight(lot, i, j) == 0
    end
    local marks = {}
    for n, c in ipairs(st.run) do
        local i, j = c[1], c[2]
        marks[#marks + 1] = { i, j, level }
        if not inLot(lot, i, j) then return false, "The stairs would stick out of the lot.", marks end
        local fine, why = B.CellFree(lot, scan, level, i, j)
        if not fine then return false, "Stair tile blocked: " .. why, marks end
        if level == 0 and not flatDatum(i, j) then return false, "Stairs need flat ground at the lot's base height.", marks end
        if lot.entry and level == 0 and lot.entry[1] == i and lot.entry[2] == j then return false, "Keep the lot entrance clear.", marks end
        local k = idx(lot, i, j)
        if scan.stairBottom[level][k] then return false, "That is the foot of other stairs.", marks end
        if level == 0 and scan.ladderLand[k] then return false, "That is where people climb out of the pool: keep the ladder clear.", marks end
        local who = B.ActorAt(world, level, i, j)
        if who then return false, who.name .. " is standing there.", marks end
        if scan.any[level + 1][k] then
            local o = lot.objects[scan.any[level + 1][k]]
            return false, "Upstairs, the " .. ((o and SS.Objects[o.def] and SS.Objects[o.def].name) or "furniture") .. " is over the stairwell.", marks
        end
        if lot.diag[level + 1][k] then return false, "A diagonal wall upstairs is over the stairwell.", marks end
        if scan.stairTop[level + 1][k] then return false, "The stairwell would swallow another staircase's landing.", marks end
    end
    local b, t = st.bottom, st.top
    marks[#marks + 1] = { b[1], b[2], level, clear = true }
    marks[#marks + 1] = { t[1], t[2], level + 1, landing = true }
    if not inLot(lot, b[1], b[2]) then return false, "There is no room to step onto the stairs at the bottom.", marks end
    local fb, whyb = B.CellFree(lot, scan, level, b[1], b[2])
    if not fb then return false, "The bottom step needs a clear tile in front: " .. whyb, marks end
    if level == 0 and not flatDatum(b[1], b[2]) then return false, "The bottom step needs flat ground in front.", marks end
    if not inLot(lot, t[1], t[2]) then return false, "The top landing would be outside the lot.", marks end
    local tk = idx(lot, t[1], t[2])
    if not lot.floor[level + 1][tk] then return false, "The top of the stairs needs a floor upstairs to arrive on. Rotate (R) or lay a floor tile there first.", marks end
    local ft, whyt = B.CellFree(lot, scan, level + 1, t[1], t[2])
    if not ft then return false, "The top landing is blocked: " .. whyt, marks end
    -- no wall across the flight or between the flight and the landing
    local prev = b
    for n, c in ipairs(st.run) do
        local e = G.edgeBetween(prev[1], prev[2], c[1], c[2])
        local wl = lot.walls[level][e]
        if wl and not W.OPENINGS[wl.kind] then return false, "A wall crosses the stairs.", marks end
        if n > 1 then
            local wu = lot.walls[level + 1][e]
            if wu and not wu.auto then return false, "An upstairs wall crosses the stairwell.", marks end
        end
        prev = c
    end
    local eTop = G.edgeBetween(prev[1], prev[2], t[1], t[2])
    local wt = lot.walls[level + 1][eTop]
    if wt and not wt.auto and not W.OPENINGS[wt.kind] then return false, "A wall upstairs blocks the top of the stairs.", marks end
    return true, nil, marks
end

-- args: { def, x, y, f, level }
function B.PlanStairs(world, args)
    local lot = B.EnsureLot(world.lot)
    local def = SS.Objects[args.def]
    local plan = B.NewPlan(world, "stairs", "Place stairs")
    local ok, why, marks = B.CheckStairs(world, args.def, args.x, args.y, args.f or 0, args.level or 0)
    for _, m in ipairs(marks or {}) do plan.preview.cells[#plan.preview.cells + 1] = { i = m[1], j = m[2], level = m[3], bad = (not ok) or nil, landing = m.landing, clear = m.clear } end
    if not ok then return B.Fail(plan, why) end
    local id = B.NewObjectId(lot)
    B.Add(plan, { t = "obj", oid = id, old = nil, new = newObj(world, id, args.def, args.x, args.y, args.f or 0, args.level or 0) }, def.price or 0)
    plan.count = 1
    plan.oid = id
    plan.label = "Place " .. def.name
    return B.Finalize(world, plan)
end

-- Generic single object (columns, outdoor steps, landscaping without SS.Placement).
function B.CheckObject(world, defId, x, y, f, level, ignoreOid)
    local lot = B.EnsureLot(world.lot)
    local def = SS.Objects[defId]
    if not def then return false, "Unknown object." end
    if def.poolLadder and SS.Pool and SS.Pool.CheckLadder then return SS.Pool.CheckLadder(world, defId, x, y, f, level, ignoreOid) end
    level = level or 0
    local scan = B.Scan(lot)
    local cells = G.footprint(def, { x = x, y = y, f = f or 0 })
    local marks = {}
    for _, c in ipairs(cells) do
        marks[#marks + 1] = { c[1], c[2], level }
        if not inLot(lot, c[1], c[2]) then return false, "That would stick out of the lot.", marks end
        local fine, why = B.CellFree(lot, scan, level, c[1], c[2], ignoreOid)
        if not fine then return false, why, marks end
        if not def.noBlock and scan.any[level][idx(lot, c[1], c[2])] and scan.any[level][idx(lot, c[1], c[2])] ~= ignoreOid and not def.steps then
            local o = lot.objects[scan.any[level][idx(lot, c[1], c[2])]]
            if o and SS.Objects[o.def] and not B.NonBlocking(SS.Objects[o.def], o) then return false, "Something is already there.", marks end
        end
        local k = idx(lot, c[1], c[2])
        if not def.noBlock then
            -- a solid object never lands on someone (they would have to be moved out of it)
            local who = B.ActorAt(world, level, c[1], c[2])
            if who then return false, who.name .. " is standing there.", marks end
            if level == 0 and scan.ladderLand[k] and scan.ladderLand[k] ~= ignoreOid then
                return false, "That is where people climb out of the pool: keep the ladder clear.", marks
            end
        end
        if level == 0 then
            if def.steps then
                if not (SS.Terrain and SS.Terrain.StepsFit and SS.Terrain.StepsFit(lot, c[1], c[2], f or 0)) then
                    return false, "Outdoor steps go on a slope that rises straight ahead of them (use R to turn them).", marks
                end
                for oid, o in pairs(lot.objects) do
                    if oid ~= ignoreOid and o.x == c[1] and o.y == c[2] and (o.level or 0) == 0 and SS.Objects[o.def] and SS.Objects[o.def].steps then return false, "There are already steps there.", marks end
                end
            elseif not cellFlat(lot, c[1], c[2]) then
                return false, "The ground is sloped there; flatten it first.", marks
            end
            if lot.entry and lot.entry[1] == c[1] and lot.entry[2] == c[2] and not def.noBlock then return false, "Keep the lot entrance clear.", marks end
            if scan.stairBottom[0][k] and not def.noBlock then return false, "That is the foot of the stairs.", marks end
        else
            if scan.stairTop[level][k] and not def.noBlock then return false, "That is the stairs' landing.", marks end
        end
        if def.column and level == 0 and cellHeight(lot, c[1], c[2]) ~= 0 then return false, "Columns carry the upstairs, so they stand at the lot's base height.", marks end
    end
    -- a multi-tile object may not cross walls
    for a = 1, #cells do
        for b2 = a + 1, #cells do
            local ca, cb = cells[a], cells[b2]
            if math.abs(ca[1] - cb[1]) + math.abs(ca[2] - cb[2]) == 1 then
                if lot.walls[level][G.edgeBetween(ca[1], ca[2], cb[1], cb[2])] then return false, "It would straddle a wall.", marks end
            end
        end
    end
    return true, nil, marks
end

-- args: { def, x, y, f, level }
function B.PlanObject(world, args)
    local lot = B.EnsureLot(world.lot)
    local def = SS.Objects[args.def]
    local plan = B.NewPlan(world, "object", "Place object")
    if not def then return B.Fail(plan, "Pick something to place.") end
    if def.stairs then return B.PlanStairs(world, args) end
    local ok, why, marks = B.CheckObject(world, args.def, args.x, args.y, args.f or 0, args.level or 0)
    for _, m in ipairs(marks or {}) do plan.preview.cells[#plan.preview.cells + 1] = { i = m[1], j = m[2], level = m[3], bad = (not ok) or nil } end
    if not ok then return B.Fail(plan, why) end
    local id = B.NewObjectId(lot)
    B.Add(plan, { t = "obj", oid = id, old = nil, new = newObj(world, id, args.def, args.x, args.y, args.f or 0, args.level or 0) }, def.price or 0)
    plan.count = 1
    plan.oid = id
    plan.label = "Place " .. def.name
    return B.Finalize(world, plan)
end

-- The catalogue's placement engine (SS.Placement.Check/Buy/Sell/Rotate) owns buy-mode objects:
-- landscaping bought from the Garden tab, and furniture sold or turned from build mode, go through
-- it when it is present so its rules, refunds and undo records apply. Without it (pre-integration)
-- the build engine's own object plans are used.
local function placement(op)
    local P = SS.Placement
    if not P then return nil end
    if op == "place" then
        if type(P.Buy) == "function" then return P.Buy end
        if type(P.Place) == "function" then return P.Place end
    elseif op == "sell" then
        if type(P.Sell) == "function" then return P.Sell end
    elseif op == "rotate" then
        if type(P.Rotate) == "function" then return P.Rotate end
    elseif op == "check" then
        if type(P.Check) == "function" and (type(P.Buy) == "function" or type(P.Place) == "function") then return P.Check end
    end
    return nil
end
B.Placement = placement

-- Objects the build tools own (stairs, columns, steps, pool ladders, anything in a build_* category).
function B.IsBuildObject(def)
    if not def then return false end
    if def.stairs or def.column or def.steps or def.poolLadder then return true end
    return type(def.cat) == "string" and def.cat:sub(1, 6) == "build_"
end

-- Landscaping plan (trees, shrubs, flowers, garden decor). args: { def, x, y, f, level }
function B.PlanLandscape(world, args)
    local def = SS.Objects[args.def or ""]
    local check = placement("check")
    if not (def and check) then return B.PlanObject(world, args) end
    local plan = B.NewPlan(world, "landscape", "Plant " .. def.name)
    local lv, f = args.level or 0, args.f or 0
    local ok, why, blocked = check(world, args.def, args.x, args.y, f, lv, {})
    local bad = {}
    for _, c in ipairs(blocked or {}) do bad[(c.i or c[1]) .. ":" .. (c.j or c[2])] = true end
    for _, c in ipairs(G.footprint(def, { x = args.x, y = args.y, f = f })) do
        plan.preview.cells[#plan.preview.cells + 1] = { i = c[1], j = c[2], level = lv, bad = (bad[c[1] .. ":" .. c[2]] or not ok) or nil }
    end
    plan.cost = def.price or 0
    plan.count = 1
    plan.external = { op = "place", def = args.def, x = args.x, y = args.y, f = f, level = lv }
    if not ok then B.Fail(plan, why or "Can't place that there.") end
    return plan
end

-- Place a landscaping object now. Returns ok, why | oid.
function B.PlaceLandscape(world, defId, x, y, f, level)
    return B.Commit(world, B.PlanLandscape(world, { def = defId, x = x, y = y, f = f, level = level }))
end

-- Carry out a plan through the catalogue's placement engine (it charges, records undo and emits
-- lotChanged itself). Returns ok, why | tx.
function B.CommitExternal(world, plan)
    local ex = plan.external
    local fn = placement(ex.op)
    if not fn then return false, "That needs the catalogue's placement, which isn't available." end
    local okc, a, b, c
    if ex.op == "place" then okc, a, b, c = pcall(fn, world, ex.def, ex.x, ex.y, ex.f or 0, ex.level or 0)
    elseif ex.op == "sell" then okc, a, b, c = pcall(fn, world, ex.oid, { withChildren = true })
    else okc, a, b = pcall(fn, world, ex.oid, ex.dir or 1) end
    if not okc then return false, "That didn't work: " .. tostring(a) end
    if not a then return false, b or "That can't be done here." end
    for _, w in ipairs(plan.warnings) do notify(world, w) end
    return true, SS.Undo.Peek()
end

-- Rotate a placed build object (stairs, columns, steps, landscaping) a quarter turn.
function B.PlanRotate(world, oid, dir)
    local lot = B.EnsureLot(world.lot)
    local o = lot.objects[oid]
    local plan = B.NewPlan(world, "rotate", "Rotate")
    if not o then return B.Fail(plan, "Nothing to rotate there.") end
    local def = SS.Objects[o.def]
    if not def then return B.Fail(plan, "That object's design is missing; delete it instead.") end
    if objInUse(world, oid) then return B.Fail(plan, "Someone is using it.") end
    local nf = ((o.f or 0) + (dir or 1)) % 4
    if def and def.buyable ~= false and not B.IsBuildObject(def) and placement("rotate") then
        -- furniture and landscaping turn by the catalogue's rules (it validates and records undo)
        plan.external = { op = "rotate", oid = oid, dir = dir or 1 }
        plan.count = 1
        plan.label = "Rotate " .. def.name
        plan.preview.cells[1] = { i = o.x, j = o.y, level = o.level or 0 }
        return plan
    end
    local ok, why
    if def.stairs then ok, why = B.CheckStairs(world, o.def, o.x, o.y, nf, o.level or 0, oid)
    else ok, why = B.CheckObject(world, o.def, o.x, o.y, nf, o.level or 0, oid) end
    if not ok then return B.Fail(plan, why) end
    local no = deepcopy(o); no.f = nf
    B.Add(plan, { t = "obj", oid = oid, old = deepcopy(o), new = no }, 0)
    plan.count = 1
    plan.label = "Rotate " .. (def and def.name or "object")
    return B.Finalize(world, plan)
end

---------------------------------------------------------------------------------------------------
-- Delete/sell a build item at a spot: door/window/arch (wall stays), gate (fence stays), wall or
-- fence segment, diagonal wall, stairs, column, steps, landscaping object, pool ladder.
-- target: { kind = "edge", level, key } | { kind = "diag", level, idx } | { kind = "obj", oid }
---------------------------------------------------------------------------------------------------
function B.PlanDelete(world, target)
    local lot = B.EnsureLot(world.lot)
    local plan = B.NewPlan(world, "delete", "Delete")
    if not target then return B.Fail(plan, "Nothing to delete there.") end
    if target.kind == "obj" then
        local o = lot.objects[target.oid]
        if not o then return B.Fail(plan, "Nothing to delete there.") end
        -- an object whose definition is gone (damaged save, removed content) can still be cleared
        local def = SS.Objects[o.def] or { name = "unknown object", price = 0, buyable = false }
        -- a pool ladder is not "in use" by people already in the water: removing it is allowed,
        -- with the drowning forecast shown as a danger warning below
        local skip = def.poolLadder and SS.Pool and SS.Pool.InWater and function(a) return SS.Pool.InWater(world, a) end or nil
        local user = objInUse(world, target.oid, skip)
        if user then return B.Fail(plan, (type(user) == "table" and user.name or "Someone") .. " is using it.") end
        if def.stairs then
            -- only people on THIS staircase stop it being removed: climbing it right now (their
            -- route's current step is this flight) or standing on its run
            local st = W.StairInfo(o)
            for _, id in ipairs(SS.Sim.ActorIds(world)) do
                local a = world.actors[id]
                if a then
                    local act = a.act
                    local node = act and act.flight and act.path and act.path[act.pi or 1]
                    if node and node.stairs == target.oid then return B.Fail(plan, (a.name or id) .. " is on the stairs.") end
                    if st and a.x then
                        for _, c in ipairs(st.run) do
                            if (a.level or 0) == st.level and math.floor(a.x) == c[1] and math.floor(a.y) == c[2] then return B.Fail(plan, (a.name or id) .. " is on the stairs.") end
                        end
                    end
                end
            end
        end
        if def.buyable ~= false and not B.IsBuildObject(def) and placement("sell") then
            -- bought objects (landscaping, furniture) sell by the catalogue's refund rules
            local total = SS.Placement.Quote and SS.Placement.Quote(world, target.oid) or 0
            plan.cost = -(B.IsFree(world) and 0 or (total or 0))
            plan.external = { op = "sell", oid = target.oid }
            plan.count = 1
            plan.label = "Sell " .. def.name
            plan.preview.cells[1] = { i = o.x, j = o.y, level = o.level or 0, erase = true }
            return plan
        end
        local value
        if def.buyable ~= false and SS.Economy and SS.Economy.ResaleValue then value = SS.Economy.ResaleValue(world, o)
        else value = B.Refund(o.paid or def.price or 0) end
        B.Add(plan, { t = "obj", oid = target.oid, old = deepcopy(o), new = nil }, -value)
        -- anything resting on it goes to inventory rather than floating
        for cid, c in pairs(lot.objects) do
            if c.parent == target.oid then plan.changes[#plan.changes + 1] = { t = "obj", oid = cid, old = deepcopy(c), new = nil } end
        end
        for n = 1, #plan.changes do
            local ch = plan.changes[n]
            if ch.oid ~= target.oid and ch.t == "obj" then
                local cd = SS.Objects[ch.old.def]
                plan.changes[#plan.changes + 1] = { t = "inv", add = true, item = { kind = "object", def = ch.old.def, name = cd and cd.name or ch.old.def, value = ch.old.paid or 0, data = { variant = ch.old.variant, from = "build" } } }
            end
        end
        -- the pool's build deriver flags a swimmer left with no way out as a danger (every edit,
        -- not just this one); here only the calm "nobody can get in or out" note is added
        if SS.Pool and SS.Pool.LadderRemovalWarning then
            local w, danger = SS.Pool.LadderRemovalWarning(world, target.oid)
            if w and not danger then B.Warn(plan, w) end
        end
        plan.count = 1
        plan.label = ((value > 0 and not B.IsBuildObject(def)) and "Sell " or "Remove ") .. (def and def.name or "object")
        plan.preview.cells[1] = { i = o.x, j = o.y, level = o.level or 0, erase = true }
        return B.Finalize(world, plan)
    elseif target.kind == "diag" then
        local dg = lot.diag[target.level][target.idx]
        if not dg then return B.Fail(plan, "No diagonal wall there.") end
        B.Add(plan, { t = "diag", level = target.level, idx = target.idx, old = deepcopy(dg), new = nil }, -B.Refund(B.SegmentPrice(dg.kind, dg.style, dg.a, dg.b)))
        plan.count = 1
        plan.label = "Remove diagonal " .. dg.kind
        return B.Finalize(world, plan)
    elseif target.kind == "edge" then
        local level = target.level or 0
        local wl = lot.walls[level][target.key]
        if not wl then return B.Fail(plan, "No wall there.") end
        plan.preview.edges[1] = { key = target.key, level = level, kind = "erase", erase = true }
        local function toPlain(key, rec)
            if rec.kind == "gate" then return { kind = "fence", style = rec.style } end
            return { kind = "wall", a = rec.a, b = rec.b }
        end
        if wl.kind == "door" or wl.kind == "window" or wl.kind == "arch" or wl.kind == "gate" then
            local it
            if wl.kind == "gate" then local fam = B.Item("fences", wl.style); it = { price = fam and fam.gatePrice or 100, name = fam and fam.gateName or "gate" }
            else it = B.Item(wl.kind == "window" and "windows" or "doors", wl.style) or { price = 0, name = wl.kind } end
            B.Add(plan, { t = "wall", level = level, key = target.key, old = deepcopy(wl), new = toPlain(target.key, wl) }, -B.Refund(it.price))
            if wl.pair and lot.walls[level][wl.pair] then
                local pw = lot.walls[level][wl.pair]
                B.Add(plan, { t = "wall", level = level, key = wl.pair, old = deepcopy(pw), new = toPlain(wl.pair, pw) }, 0)
                plan.preview.edges[2] = { key = wl.pair, level = level, kind = "erase", erase = true }
            end
            plan.label = "Remove " .. it.name
        else
            if wl.auto then return B.Fail(plan, "This railing guards an upstairs edge; it goes away by itself when the drop is filled in.") end
            B.Add(plan, { t = "wall", level = level, key = target.key, old = deepcopy(wl), new = nil }, -B.Refund(B.WallValue(wl)))
            plan.label = "Remove " .. wl.kind
        end
        plan.count = 1
        return B.Finalize(world, plan)
    end
    return B.Fail(plan, "Nothing to delete there.")
end

-- What build item is at a world point on `level`? Returns a delete target (objects first, then
-- diagonal walls, then the nearest edge within 0.3 tiles).
function B.TargetAt(world, level, wx, wy, pickKind, pickRef)
    local lot = B.EnsureLot(world.lot)
    if pickKind == "obj" and pickRef and lot.objects[pickRef] then return { kind = "obj", oid = pickRef } end
    local i, j = math.floor(wx), math.floor(wy)
    if inLot(lot, i, j) then
        local k = idx(lot, i, j)
        -- build objects on the cell (stairs, columns, steps, ladders, landscaping)
        local best
        for oid, o in pairs(lot.objects) do
            local def = SS.Objects[o.def]
            if def and (o.level or 0) == level then
                for _, c in ipairs(G.footprint(def, o)) do
                    if c[1] == i and c[2] == j and (not best or oid < best) then best = oid end
                end
            end
        end
        if best then return { kind = "obj", oid = best } end
        if lot.diag[level][k] then return { kind = "diag", level = level, idx = k } end
    end
    local key, _, _, _, dist = B.NearestEdge(wx, wy)
    if dist <= 0.3 and lot.walls[level][key] then return { kind = "edge", level = level, key = key } end
    return nil
end

---------------------------------------------------------------------------------------------------
-- Eyedropper: what is under the cursor, as a tool + item the UI can switch to.
---------------------------------------------------------------------------------------------------
function B.Eyedropper(world, level, wx, wy, pickKind, pickRef)
    local lot = B.EnsureLot(world.lot)
    if pickKind == "obj" and pickRef and lot.objects[pickRef] then
        local o = lot.objects[pickRef]
        local def = SS.Objects[o.def]
        if def and def.stairs then return { tool = "stairs", item = o.def, f = o.f } end
        if def and def.column then return { tool = "column", item = o.def } end
        if def and def.steps then return { tool = "steps", item = o.def, f = o.f } end
        if def and SS.Pool and SS.Pool.IsLadderDef and SS.Pool.IsLadderDef(o.def) then return { tool = "ladder", item = o.def } end
        return { tool = "landscape", item = o.def, f = o.f }
    end
    local i, j = math.floor(wx), math.floor(wy)
    local key, side, _, _, dist = B.NearestEdge(wx, wy)
    local wl = lot.walls[level][key]
    if wl and dist <= 0.3 then
        if wl.kind == "door" or wl.kind == "arch" then return { tool = "door", item = wl.style } end
        if wl.kind == "window" then return { tool = "window", item = wl.style } end
        if wl.kind == "fence" then return { tool = "fence", item = wl.style } end
        if wl.kind == "gate" then return { tool = "gate", item = wl.style } end
        if wl.kind == "railing" then return { tool = "railing", item = wl.style } end
        if wl[side] then return { tool = "paint", item = wl[side] } end
    end
    if inLot(lot, i, j) then
        local k = idx(lot, i, j)
        local dg = lot.diag[level][k]
        if dg then
            local s = B.DiagSideAt(dg.dir, wx - i, wy - j)
            if dg.kind == "fence" then return { tool = "fence", item = dg.style } end
            return { tool = "paint", item = dg[s] }
        end
        if level == 0 and lot.pool[k] then return { tool = "pool", item = lot.pool[k].style } end
        local f = lot.floor[level][k]
        if f and not (level == 0 and B.IsGround(f)) then return { tool = "floor", item = f } end
        if level == 0 then
            if lot.terrain.water[k] then return { tool = "pond", item = lot.terrain.water[k] } end
            return { tool = "terrain", item = lot.terrain.paint[k] or "grass" }
        end
    end
    return nil
end

---------------------------------------------------------------------------------------------------
-- Session wiring: attach, save validation
---------------------------------------------------------------------------------------------------
local function attach(world)
    B.EnsureLot(world.lot)
    if not (SS.RT and SS.RT.build and SS.RT.build.lot == world.lot) then B.PostRebuild(world, SS.RT) end
    B.RelocateActors(world, { onLoad = true })
end
SS.Sim.Register({ name = "build", order = 5, attach = attach })

local VALID_KIND = B.KINDS
SS.Save.RegisterValidator(function(root, problems)
    for lotId, lot in pairs(root.hood and root.hood.lots or {}) do
        B.EnsureLot(lot)
        for level = 0, W.LEVELS - 1 do
            for key, wl in pairs(lot.walls[level]) do
                if type(key) ~= "string" or not key:match("^[xy]:%-?%d+:%-?%d+$") or type(wl) ~= "table" then
                    lot.walls[level][key] = nil
                    problems[#problems + 1] = "removed a damaged wall on " .. tostring(lotId)
                elseif not VALID_KIND[wl.kind] then
                    wl.kind = "wall"
                end
            end
            -- double doors/windows keep both halves; a lone half becomes a single-width piece
            for key, wl in pairs(lot.walls[level]) do
                if wl.pair then
                    local pw = lot.walls[level][wl.pair]
                    if not pw or pw.pair ~= key or pw.kind ~= wl.kind then wl.pair, wl.span, wl.part = nil, nil, nil end
                end
            end
            for k, dg in pairs(lot.diag[level]) do
                if type(k) ~= "number" or type(dg) ~= "table" or (dg.dir ~= 0 and dg.dir ~= 1) or k < 1 or k > lot.w * lot.h then
                    lot.diag[level][k] = nil
                    problems[#problems + 1] = "removed a damaged diagonal wall on " .. tostring(lotId)
                elseif dg.kind ~= "wall" and dg.kind ~= "fence" then
                    dg.kind = "wall"
                end
            end
        end
        if type(lot.roof) ~= "table" then lot.roof = { style = "gable" } end
    end
    return true
end)
