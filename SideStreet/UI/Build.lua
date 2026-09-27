-- Build mode UI: tabs and tools for every construction job, a catalogue with prices and
-- tooltips, cursor previews with validity colours and a cost label (Render/BuildFx.lua), drag and
-- click input, a full cost preview before anything is committed, undo/redo with descriptions and
-- costs, eyedropper, delete/sell, rotate, grid, cancel and floor up/down.
-- Owner: build module (see docs/modules/build.md "Build mode UI").
--
-- Input model: a tool reads the cursor through mode.mouseMove (world position on the edited floor)
-- and commits on mode.click (mouse up). Drags are seen by polling the left button in mode.update;
-- when a press is missed (or the player prefers it) a click sets the start point and a second
-- click the end point. Right-click or Esc cancels a drag without cost: nothing touches the lot
-- until SS.Build.Commit.
local _, SS = ...
local UI = SS.UI
local K = UI.Kit
local COL = K.COL
local B, BF = SS.Build, SS.BuildFx

local BM = { tab = "walls", tool = "wall", lastTool = "wall", lastByTab = {}, sel = {}, f = 0, brush = 0, roofScope = "lot",
    roofSide = "south", roomFloor = false, grid = false, info = {}, t = 0, errors = 0 }
UI.BuildMode = BM

local function world() return SS.Sim.world end
local function fmt(v) return SS.U.fmtMoney(v) end
local function camLevel() return (SS.Render.cam and SS.Render.cam.level) or 0 end
local function cue(name) if SS.Audio and SS.Audio.Cue then SS.Audio.Cue(name) end end
local function notice(text) if UI.Notice and text then UI.Notice(text) end end
local function round(v) return math.floor(v + 0.5) end

---------------------------------------------------------------------------------------------------
-- Tabs and tools
---------------------------------------------------------------------------------------------------
BM.TABS = {
    { id = "walls", label = "Walls", tools = { "wall", "room", "halfwall", "erase" }, tip = "Walls and rooms. Drag along the grid; drag at 45 degrees for a diagonal wall." },
    { id = "paint", label = "Paint", tools = { "paintside", "paintroom" }, tip = "Wall finishes: one side of a wall, or every wall of a room." },
    { id = "floors", label = "Floors", tools = { "tile", "floorrect", "floorroom", "floorremove" }, tip = "Floors, downstairs and upstairs (Page Up / Page Down picks the floor)." },
    { id = "doors", label = "Doors", tools = { "door" }, tip = "Doors and archways: point at a wall. Double doors take two segments." },
    { id = "windows", label = "Windows", tools = { "window" }, tip = "Windows: point at a wall. They light rooms; nobody climbs through them." },
    { id = "stairs", label = "Stairs", tools = { "stairs" }, tip = "Stairs to the floor above. R turns them." },
    { id = "roof", label = "Roof", tools = { "roofstyle", "roofmaterial", "roofcolor" }, tip = "Roof style, material and colour, for the whole lot or one building." },
    { id = "fences", label = "Fences", tools = { "fence", "gate", "railing", "column", "steps" }, tip = "Fences and gates, railings, columns and outdoor steps." },
    { id = "terrain", label = "Terrain", tools = { "raise", "lower", "flatten", "ground", "path", "pond", "fillpond" }, tip = "Raise, lower and level the ground; paint it; lay paths; dig ponds." },
    { id = "garden", label = "Garden", tools = { "landscape" }, tip = "Trees, shrubs, flowers and garden pieces from the catalogue." },
    { id = "pool", label = "Pool", tools = { "pool", "poolremove", "ladder" }, tip = "Swimming pools and the ladders people use to get in and out." },
}
BM.TAB = {}
for _, t in ipairs(BM.TABS) do BM.TAB[t.id] = t end

-- Inputs: line (corner to corner), rectc (corner rectangle), rect (cell rectangle), brush (cells
-- under a drag), room (click inside), edge (nearest wall edge), corner (nearest grid corner),
-- place (cell + facing), target (thing under the cursor), roof (lot or building).
local DRAG = { line = true, rectc = true, rect = true, brush = true }
local GROUND_ONLY = { raise = true, lower = true, flatten = true, ground = true, path = true, pond = true, fillpond = true,
    pool = true, poolremove = true, ladder = true, steps = true }

local function sel(key) return BM.sel[key] end
local function Te() return SS.Terrain end
local function Pl() return SS.Pool end
local function Rf() return SS.Roof end

local function roofArgs(st)
    local a = { section = st.section }
    if BM.tool == "roofstyle" then
        a.style = sel("roofStyle")
        if a.style == "shed" then a.side = BM.roofSide end
    elseif BM.tool == "roofmaterial" then a.material = sel("roofMaterial")
    else a.color = sel("roofColor") end
    return a
end

BM.TOOLS = {
    wall = { label = "Wall", input = "line", diag = true, list = "wallFinish",
        tip = "Build walls: drag from corner to corner. A 45-degree drag builds a diagonal wall.",
        help = "Drag along the grid lines to build walls (a 45-degree drag makes a diagonal).",
        plan = function(w, st) return B.PlanLine(w, { level = st.level, x0 = st.x0, y0 = st.y0, x1 = st.x1, y1 = st.y1, kind = "wall", finish = sel("wallFinish"), diag = st.diag }) end },
    room = { label = "Room", input = "rectc", list = "wallFinish",
        tip = "Build a rectangular room: drag from one corner to the opposite corner.",
        help = "Drag a rectangle to wall in a room (existing walls are kept).",
        plan = function(w, st) return B.PlanRoom(w, { level = st.level, x0 = st.x0, y0 = st.y0, x1 = st.x1, y1 = st.y1, finish = sel("wallFinish"), withFloor = BM.roomFloor, floor = sel("floor") }) end },
    halfwall = { label = "Half Wall", input = "line", list = "wallFinish",
        tip = "Build waist-high half walls: they divide space without closing a room.",
        help = "Drag along the grid for a half wall (people can't walk through it, but rooms stay open).",
        plan = function(w, st) return B.PlanLine(w, { level = st.level, x0 = st.x0, y0 = st.y0, x1 = st.x1, y1 = st.y1, kind = "halfwall", finish = sel("wallFinish"), diag = false }) end },
    erase = { label = "Erase", input = "line", diag = true,
        tip = "Erase walls, fences and railings along a line (75% refund). Doors and windows go with their wall.",
        help = "Drag over walls to remove them. Double doors and windows never hang: the other half becomes wall.",
        plan = function(w, st) return B.PlanErase(w, { level = st.level, x0 = st.x0, y0 = st.y0, x1 = st.x1, y1 = st.y1 }) end },
    paintside = { label = "Side", input = "edge", list = "wallFinish",
        tip = "Paint one side of a wall (the side the cursor is on).",
        help = "Point at a wall; the side nearest the cursor takes the finish.",
        plan = function(w, st)
            if st.idx then return B.PlanPaint(w, { level = st.level, idx = st.idx, side = st.side, finish = sel("wallFinish") }) end
            return B.PlanPaint(w, { level = st.level, key = st.key, side = st.side, finish = sel("wallFinish") })
        end },
    paintroom = { label = "Room", input = "room", list = "wallFinish",
        tip = "Paint every wall facing into a room.",
        help = "Click inside a room to paint all of its inside walls.",
        plan = function(w, st) return B.PlanPaint(w, { level = st.level, room = { st.i, st.j }, finish = sel("wallFinish") }) end },
    tile = { label = "Tile", input = "brush", list = "floor",
        tip = "Lay floor tile by tile: click, or drag to paint several.",
        help = "Click or drag over tiles to lay the selected floor.",
        plan = function(w, st) return B.PlanFloor(w, { level = st.level, finish = sel("floor"), cells = st.cells }) end },
    floorrect = { label = "Area", input = "rect", list = "floor",
        tip = "Lay floor over a rectangle: drag from one tile to another.",
        help = "Drag a rectangle of tiles to floor it.",
        plan = function(w, st) return B.PlanFloor(w, { level = st.level, finish = sel("floor"), rect = { st.x0, st.y0, st.x1, st.y1 } }) end },
    floorroom = { label = "Fill Room", input = "room", list = "floor",
        tip = "Floor a whole enclosed room in one click.",
        help = "Click inside a walled room to floor all of it.",
        plan = function(w, st) return B.PlanFloor(w, { level = st.level, finish = sel("floor"), room = { st.i, st.j } }) end },
    floorremove = { label = "Remove", input = "rect",
        tip = "Take up floor tiles (75% refund). Upstairs, this opens holes to the floor below.",
        help = "Drag over floor tiles to remove them.",
        plan = function(w, st) return B.PlanFloor(w, { level = st.level, remove = true, rect = { st.x0, st.y0, st.x1, st.y1 } }) end },
    door = { label = "Door", input = "edge", list = "door",
        tip = "Put a door or archway into a wall. It needs a clear tile on both sides.",
        help = "Point at a wall to place the door; double doors take two segments in a row.",
        plan = function(w, st) return B.PlanOpening(w, { level = st.level, key = st.key, style = sel("door"), kind = "door", side = st.side }) end },
    window = { label = "Window", input = "edge", list = "window",
        tip = "Put a window into a wall. Windows light the rooms on both sides.",
        help = "Point at a wall to place the window.",
        plan = function(w, st) return B.PlanOpening(w, { level = st.level, key = st.key, style = sel("window"), kind = "window", side = st.side }) end },
    stairs = { label = "Stairs", input = "place", list = "stairs", facing = true,
        tip = "Place stairs. They need a clear tile at the bottom and a floor tile upstairs at the top (R turns them).",
        help = "Point where the stairs go; blue is the top landing upstairs, yellow the tile to step on at the bottom. R turns.",
        plan = function(w, st) return B.PlanStairs(w, { def = sel("stairs"), x = st.i, y = st.j, f = BM.f, level = st.level }) end },
    roofstyle = { label = "Style", input = "roof", list = "roofStyle",
        tip = "Roof style: gable, hipped, flat, shed or mansard.",
        help = "Pick a style, then click the lot (whole lot) or a building (one building).",
        plan = function(w, st) return Rf().PlanRoof(w, roofArgs(st)) end },
    roofmaterial = { label = "Material", input = "roof", list = "roofMaterial",
        tip = "Roof material (priced per roof tile).",
        help = "Pick a material, then click the lot (whole lot) or a building (one building).",
        plan = function(w, st) return Rf().PlanRoof(w, roofArgs(st)) end },
    roofcolor = { label = "Colour", input = "roof", list = "roofColor",
        tip = "Roof colour.",
        help = "Pick a colour, then click the lot (whole lot) or a building (one building).",
        plan = function(w, st) return Rf().PlanRoof(w, roofArgs(st)) end },
    fence = { label = "Fence", input = "line", diag = true, list = "fence",
        tip = "Build fences: drag along the grid (45 degrees for a diagonal run). Fences don't make rooms.",
        help = "Drag along the grid to build a fence. Add gates with the Gate tool.",
        plan = function(w, st) return B.PlanLine(w, { level = st.level, x0 = st.x0, y0 = st.y0, x1 = st.x1, y1 = st.y1, kind = "fence", style = sel("fence"), diag = st.diag }) end },
    gate = { label = "Gate", input = "edge", list = "gate",
        tip = "Turn a fence segment into a gate of the same family. People walk through gates like doors.",
        help = "Point at a fence segment to put a gate in it.",
        plan = function(w, st) return B.PlanGate(w, { level = st.level, key = st.key }) end },
    railing = { label = "Railing", input = "line", list = "railing",
        tip = "Railings for balconies, terraces and porches. Open upstairs edges get railings automatically.",
        help = "Drag along the grid to build a railing.",
        plan = function(w, st) return B.PlanLine(w, { level = st.level, x0 = st.x0, y0 = st.y0, x1 = st.x1, y1 = st.y1, kind = "railing", style = sel("railing"), diag = false }) end },
    column = { label = "Column", input = "place", list = "column", facing = true,
        tip = "Columns hold up porches and balconies: an upstairs floor may reach 2 tiles past a wall or column below.",
        help = "Click a tile to put a column there.",
        plan = function(w, st) return B.PlanObject(w, { def = sel("column"), x = st.i, y = st.j, f = BM.f, level = st.level }) end },
    steps = { label = "Steps", input = "place", list = "steps", facing = true,
        tip = "Outdoor steps on a slope: easier walking up a bank (R turns them to face uphill).",
        help = "Click a sloped tile; the steps climb toward the facing (R turns).",
        plan = function(w, st) return B.PlanObject(w, { def = sel("steps"), x = st.i, y = st.j, f = BM.f, level = 0 }) end },
    raise = { label = "Raise", input = "corner",
        tip = "Raise the ground at a grid corner (brush size on the right). Neighbouring corners follow so slopes stay walkable.",
        help = "Click a grid corner to raise the ground one step.",
        plan = function(w, st) return Te().PlanRaise(w, { x = st.cx, y = st.cy, dir = 1, brush = BM.brush }) end },
    lower = { label = "Lower", input = "corner",
        tip = "Lower the ground at a grid corner.",
        help = "Click a grid corner to lower the ground one step.",
        plan = function(w, st) return Te().PlanRaise(w, { x = st.cx, y = st.cy, dir = -1, brush = BM.brush }) end },
    flatten = { label = "Level", input = "rect",
        tip = "Level an area to the height where the drag starts. Ground under buildings stays put.",
        help = "Drag over the ground to level it to the starting height.",
        plan = function(w, st) return Te().PlanFlatten(w, { rect = { st.x0, st.y0, st.x1, st.y1 }, height = st.h0, skipLocked = true }) end },
    ground = { label = "Paint", input = "rect", list = "ground",
        tip = "Paint the open ground: grass, earth, stone, sand and more.",
        help = "Drag over open ground to paint it.",
        plan = function(w, st) return Te().PlanPaint(w, { paint = sel("ground"), rect = { st.x0, st.y0, st.x1, st.y1 } }) end },
    path = { label = "Path", input = "brush", list = "path",
        tip = "Lay garden paths and patios with outdoor paving. Paths stay outdoors.",
        help = "Click or drag to lay paving.",
        plan = function(w, st) return B.PlanFloor(w, { level = 0, finish = sel("path"), cells = st.cells }) end },
    pond = { label = "Pond", input = "rect", list = "pond",
        tip = "Dig a decorative pond. Nobody wades or swims in ponds; they walk around.",
        help = "Drag over level open ground to dig a pond.",
        plan = function(w, st) return Te().PlanPond(w, { style = sel("pond"), rect = { st.x0, st.y0, st.x1, st.y1 } }) end },
    fillpond = { label = "Fill In", input = "rect",
        tip = "Fill a pond back in (75% refund).",
        help = "Drag over pond tiles to fill them in.",
        plan = function(w, st) return Te().PlanPond(w, { remove = true, rect = { st.x0, st.y0, st.x1, st.y1 } }) end },
    landscape = { label = "Plant", input = "place", list = "landscape", facing = true,
        tip = "Plant trees, shrubs and flowers and place garden pieces (R turns them).",
        help = "Click open ground to plant the selected item.",
        plan = function(w, st) return B.PlanLandscape(w, { def = sel("landscape"), x = st.i, y = st.j, f = BM.f, level = st.level }) end },
    pool = { label = "Pool", input = "rect", list = "pool",
        tip = "Dig a swimming pool on level open ground. Add a ladder so people can get in and out.",
        help = "Drag a rectangle to dig the pool (drag next to it to extend it).",
        plan = function(w, st) return Pl().PlanPool(w, { rect = { st.x0, st.y0, st.x1, st.y1 }, style = sel("pool") }) end },
    poolremove = { label = "Remove", input = "rect",
        tip = "Fill in pool tiles (75% refund). Ladders facing them come out too.",
        help = "Drag over the pool to fill it in.",
        plan = function(w, st) return Pl().PlanPool(w, { remove = true, rect = { st.x0, st.y0, st.x1, st.y1 } }) end },
    ladder = { label = "Ladder", input = "place", list = "ladder", facing = true,
        tip = "Pool ladders are the only way into and out of the water. Place one on the pool's edge; it turns to face the water.",
        help = "Click a tile beside the pool: the ladder faces the water automatically.",
        plan = function(w, st)
            local f = Pl().LadderFacingAt(w.lot, st.i, st.j, BM.f) or BM.f
            return Pl().PlanLadder(w, { def = sel("ladder"), x = st.i, y = st.j, f = f })
        end },
    -- utilities (always available)
    pick = { label = "Pick", input = "target", utility = true,
        tip = "Eyedropper (I): click a wall, floor, door, fence, roof, pool or object to pick up its style.",
        help = "Click something to copy its finish or style into the matching tool." },
    delete = { label = "Delete", input = "target", utility = true,
        tip = "Delete or sell (Del): doors, windows, gates, walls, stairs, columns, steps, ladders and garden objects.",
        help = "Click something to remove it. Build items refund 75%; bought objects sell by the shop's rules.",
        plan = function(w, st) return B.PlanDelete(w, st.target) end },
    rotate = { label = "Rotate", input = "target", utility = true,
        tip = "Rotate a placed object a quarter turn (stairs, steps, columns, garden objects).",
        help = "Click an object to turn it a quarter turn.",
        plan = function(w, st)
            if not (st.target and st.target.kind == "obj") then
                local p = B.NewPlan(w, "rotate", "Rotate")
                return B.Fail(p, "Point at an object to turn it.")
            end
            return B.PlanRotate(w, st.target.oid, 1)
        end },
}
for id, t in pairs(BM.TOOLS) do t.id = id end
for _, tab in ipairs(BM.TABS) do for _, id in ipairs(tab.tools) do BM.TOOLS[id].tab = tab.id end end

---------------------------------------------------------------------------------------------------
-- Catalogue lists: { id, name, price, priceText, desc, rgb, extra }
---------------------------------------------------------------------------------------------------
local function colorOf(it)
    if type(it.color) == "table" then return it.color end
    if type(it.rgb) == "table" then return it.rgb end
    if type(it.look) == "table" and type(it.look.base) == "table" then return it.look.base end
    if type(it.colors) == "table" and it.colors[1] and it.colors[1].rgb then return it.colors[1].rgb end
    if type(it.water) == "table" then return it.water end
    return nil
end

local function entries(items, per, extraFn)
    local out = {}
    for _, it in ipairs(items or {}) do
        out[#out + 1] = { id = it.id, name = it.name or it.id, price = it.price or 0, priceText = fmt(it.price or 0) .. (per or ""),
            desc = it.desc or "", rgb = colorOf(it), extra = extraFn and extraFn(it) or nil, item = it }
    end
    return out
end

local function currentRoofMaterial(w)
    local lot = w and w.lot
    return Rf().Material(lot and lot.roof and lot.roof.material)
end

BM.LISTS = {
    wallFinish = function() return entries(B.Items("walls"), " / side") end,
    floor = function()
        -- indoor floors first (the default pick), then outdoor paving for porches and terraces
        local list = {}
        for _, it in ipairs(B.Items("floors")) do if not B.IsOutdoorFloor(it.id) then list[#list + 1] = it end end
        for _, it in ipairs(B.Items("floors")) do if B.IsOutdoorFloor(it.id) and not B.IsGround(it.id) then list[#list + 1] = it end end
        return entries(list, " / tile", function(it) return B.IsOutdoorFloor(it.id) and "Outdoor paving: porches, patios and terraces stay outdoors." or nil end)
    end,
    path = function()
        local list = {}
        for _, it in ipairs(B.Items("floors")) do if B.IsOutdoorFloor(it.id) and not B.IsGround(it.id) then list[#list + 1] = it end end
        return entries(list, " / tile")
    end,
    door = function()
        return entries(B.Items("doors"), "", function(it)
            local t = {}
            if it.kind == "arch" then t[#t + 1] = "Archway (no door)" end
            if it.width == 2 then t[#t + 1] = "Double width: needs two wall segments in a row" end
            if it.glass then t[#t + 1] = "Glazed: lets a little light through" end
            return #t > 0 and table.concat(t, ". ") .. "." or nil
        end)
    end,
    window = function()
        return entries(B.Items("windows"), "", function(it)
            local t = { string.format("Light %d%%", round((it.light or 1) * 100)) }
            if it.width == 2 then t[#t + 1] = "Double width: needs two wall segments in a row" end
            return table.concat(t, ". ") .. "."
        end)
    end,
    stairs = function()
        return entries(B.Items("stairs"), "", function(it)
            local st = it.def and it.def.stairs
            return st and string.format("%d tiles of stairs.", #st.run) or nil
        end)
    end,
    roofStyle = function()
        local out = {}
        for _, s in ipairs(Rf().STYLES) do
            out[#out + 1] = { id = s.id, name = s.name, price = Rf().T.stylePrice, priceText = fmt(Rf().T.stylePrice) .. " / roof tile", desc = s.desc }
        end
        return out
    end,
    roofMaterial = function()
        return entries(B.Items("roofs"), " / roof tile", function(it)
            return it.colors and (#it.colors .. " colours") or nil
        end)
    end,
    roofColor = function()
        local w = world()
        local mat = w and currentRoofMaterial(w)
        local out, seen = {}, {}
        for _, c in ipairs((mat and mat.colors) or {}) do
            seen[c.id] = true
            out[#out + 1] = { id = c.id, name = c.name, price = Rf().T.colorPrice, priceText = fmt(Rf().T.colorPrice) .. " / roof tile",
                desc = "A colour made for " .. (mat.name or "this roof") .. ".", rgb = c.rgb }
        end
        for _, c in ipairs(B.ROOF_COLORS) do
            if not seen[c.id] then
                out[#out + 1] = { id = c.id, name = c.name, price = Rf().T.colorPrice, priceText = fmt(Rf().T.colorPrice) .. " / roof tile",
                    desc = "A painted roof finish.", rgb = c.rgb }
            end
        end
        return out
    end,
    fence = function()
        return entries(B.Items("fences"), " / segment", function(it) return "Gate: " .. (it.gateName or "gate") .. ", " .. fmt(it.gatePrice or 0) .. "." end)
    end,
    gate = function()
        local out = {}
        for _, it in ipairs(B.Items("fences")) do
            out[#out + 1] = { id = it.id, name = it.gateName or (it.name .. " Gate"), price = it.gatePrice or 0, priceText = fmt(it.gatePrice or 0),
                desc = "Fits the " .. it.name .. ". Point at a fence segment of that family: the gate always matches the fence.", rgb = colorOf(it), infoOnly = true }
        end
        return out
    end,
    railing = function() return entries(B.Items("railings"), " / segment") end,
    column = function() return entries(B.Items("columns"), "") end,
    steps = function() return entries(B.Items("steps"), "") end,
    ground = function() return entries(B.Items("terrain"), " / tile") end,
    pond = function() return entries(Te().PONDS, " / tile") end,
    landscape = function() return entries(B.Items("landscape"), "") end,
    pool = function() return entries(Pl().STYLES, " / tile", function(it) return "Coping: " .. tostring(it.coping or "stone") .. "." end) end,
    ladder = function()
        local list = {}
        for id, d in pairs(SS.Objects) do if d.poolLadder then list[#list + 1] = { id = id, name = d.name, price = d.price or 0, desc = d.desc } end end
        table.sort(list, function(a, b) if a.price ~= b.price then return a.price < b.price end return a.id < b.id end)
        return entries(list, "")
    end,
}

BM.EMPTY = {
    landscape = "The catalogue's garden objects (trees, shrubs, flowers) appear here.",
    path = "Outdoor paving from the floor catalogue appears here.",
}

-- Items of a list, with the current selection kept valid (defaults to the first item).
function BM.Items(key)
    local fn = key and BM.LISTS[key]
    if not fn then return {} end
    local ok, list = pcall(fn)
    if not ok then list = {} end
    local cur = BM.sel[key]
    local found = false
    for _, e in ipairs(list) do if e.id == cur then found = true end end
    if not found and key ~= "gate" then BM.sel[key] = list[1] and list[1].id or nil end
    return list
end

---------------------------------------------------------------------------------------------------
-- Cursor state -> plan
---------------------------------------------------------------------------------------------------
local function lotOf() local w = world(); return w and w.lot end

local function corner(wx, wy)
    local lot = lotOf()
    local x, y = round(wx), round(wy)
    if lot then x = math.max(0, math.min(lot.w, x)); y = math.max(0, math.min(lot.h, y)) end
    return x, y
end
local function cell(wx, wy)
    local lot = lotOf()
    local i, j = math.floor(wx), math.floor(wy)
    if lot then i = math.max(0, math.min(lot.w - 1, i)); j = math.max(0, math.min(lot.h - 1, j)) end
    return i, j
end
local function snapFor(input, wx, wy)
    if input == "line" or input == "rectc" then return corner(wx, wy) end
    return cell(wx, wy)
end

local function failPlan(label, why)
    local w = world()
    return B.Fail(B.NewPlan(w, "none", label or "Build"), why)
end

-- The input state for the current tool and cursor: st (plan arguments), hover marks, key.
function BM.InputState()
    local w = world()
    local t = BM.TOOLS[BM.tool]
    if not (w and t) then return nil end
    local level = camLevel()
    local c = BM.cursor
    local d = BM.drag
    if t.input == "roof" then
        if BM.roofScope == "lot" then return { level = level, scope = "lot" }, nil, "roof:lot" end
        if not c then return nil end
        local i, j = cell(c[1], c[2])
        local sec = Rf().SectionAt(w, nil, i, j)
        if not sec then return { level = level, none = true }, { { i, j, level } }, "roof:none:" .. i .. ":" .. j end
        return { level = level, section = sec.key }, nil, "roof:" .. sec.key
    end
    if not c then return nil end
    local wx, wy = c[1], c[2]
    if t.input == "line" or t.input == "rectc" then
        if not d then
            local x, y = corner(wx, wy)
            local hover = {}
            for _, o in ipairs({ { 0, 0 }, { -1, 0 }, { 0, -1 }, { -1, -1 } }) do hover[#hover + 1] = { x + o[1], y + o[2], level } end
            return nil, hover, "hc:" .. x .. ":" .. y
        end
        if d.cx == d.sx and d.cy == d.sy then
            -- pressed but not moved yet (or waiting for the second click): mark the start corner
            local hover = {}
            for _, o in ipairs({ { 0, 0 }, { -1, 0 }, { 0, -1 }, { -1, -1 } }) do hover[#hover + 1] = { d.sx + o[1], d.sy + o[2], level } end
            return nil, hover, "start:" .. d.sx .. ":" .. d.sy .. ":" .. tostring(d.sticky)
        end
        local x0, y0, x1, y1, isDiag = d.sx, d.sy, d.cx, d.cy, false
        if t.input == "line" then x0, y0, x1, y1, isDiag = B.SnapLine(d.sx, d.sy, d.cx, d.cy, t.diag) end
        return { level = level, x0 = x0, y0 = y0, x1 = x1, y1 = y1, diag = isDiag }, nil,
            string.format("%s:%d:%d:%d:%d", t.input, x0, y0, x1, y1)
    elseif t.input == "rect" then
        local i, j = cell(wx, wy)
        local si, sj = i, j
        if d then si, sj = d.sx, d.sy end
        local st = { level = level, x0 = math.min(si, i), y0 = math.min(sj, j), x1 = math.max(si, i), y1 = math.max(sj, j) }
        if BM.tool == "flatten" and Te() then st.h0 = d and d.h0 or Te().CornerH(w.lot, si, sj) end
        return st, nil, string.format("rect:%d:%d:%d:%d", st.x0, st.y0, st.x1, st.y1)
    elseif t.input == "brush" then
        if d and d.cells then
            return { level = level, cells = d.cells }, nil, "brush:" .. #d.cells .. ":" .. d.cx .. ":" .. d.cy
        end
        local i, j = cell(wx, wy)
        return { level = level, cells = { { i, j } } }, nil, "brush1:" .. i .. ":" .. j
    elseif t.input == "room" then
        local i, j = cell(wx, wy)
        return { level = level, i = i, j = j }, nil, "room:" .. i .. ":" .. j
    elseif t.input == "edge" then
        local key, side, i, j = B.NearestEdge(wx, wy)
        local st = { level = level, key = key, side = side }
        if BM.tool == "paintside" then
            local lot = w.lot
            if i >= 0 and j >= 0 and i < lot.w and j < lot.h then
                local k = j * lot.w + i + 1
                local dg = lot.diag[level] and lot.diag[level][k]
                if dg then st.idx, st.side, st.key = k, B.DiagSideAt(dg.dir, wx - i, wy - j), nil end
            end
        end
        return st, nil, "edge:" .. tostring(st.key) .. ":" .. tostring(st.idx) .. ":" .. st.side
    elseif t.input == "corner" then
        local x, y = corner(wx, wy)
        return { level = level, cx = x, cy = y }, nil, "corner:" .. x .. ":" .. y
    elseif t.input == "place" then
        local i, j = cell(wx, wy)
        return { level = level, i = i, j = j }, nil, "place:" .. i .. ":" .. j
    elseif t.input == "target" then
        local pk = BM.pickHit
        local target = B.TargetAt(w, level, wx, wy, pk and pk[1], pk and pk[2])
        local i, j = cell(wx, wy)
        local tkey = target and (target.kind .. ":" .. tostring(target.oid or target.key or target.idx)) or "none"
        return { level = level, target = target, i = i, j = j }, { { i, j, level } }, "target:" .. tkey .. ":" .. i .. ":" .. j
    end
    return nil
end

local function planKey(st, key)
    local w = world()
    local t = BM.TOOLS[BM.tool]
    return table.concat({ BM.tool, tostring(key), tostring(camLevel()), tostring(w and w.lot.version or 0), tostring(t and t.list and BM.sel[t.list] or ""),
        tostring(BM.f), tostring(BM.brush), BM.roofScope, BM.roofSide, tostring(BM.roomFloor), tostring(w and w.money or 0) }, "|")
end

local function computePlan(st)
    local w = world()
    local t = BM.TOOLS[BM.tool]
    if not (st and t and t.plan) then return nil end
    if st.none then return failPlan("Roof", "Point at a roofed building: roofs cover indoor rooms with nothing built above them.") end
    if GROUND_ONLY[BM.tool] and (st.level or 0) > 0 then
        return failPlan(t.label, "That is done on the ground floor: Page Down to go back down.")
    end
    if BM.tool == "delete" and not st.target then return failPlan("Delete", "Point at something built to remove it.") end
    if t.list and t.list ~= "gate" and BM.sel[t.list] == nil then BM.Items(t.list) end
    if t.list and BM.sel[t.list] == nil and t.list ~= "gate" then
        return failPlan(t.label, BM.EMPTY[t.list] or "Pick something from the catalogue first.")
    end
    local ok, plan = pcall(t.plan, w, st)
    if not ok then
        BM.errors = BM.errors + 1
        BM.lastError = tostring(plan)
        SS.Log("build preview error: %s", tostring(plan))
        return failPlan(t.label, "That can't be checked right now.")
    end
    return plan
end

-- Ghost for placement tools (drawn by the renderer from SS.Render.SetGhost).
local function ghostFor(plan, st)
    local t = BM.TOOLS[BM.tool]
    if not (plan and st and t and t.input == "place") then return nil end
    local defId = t.list and BM.sel[t.list]
    if not defId or not SS.Objects[defId] then return nil end
    local f = BM.f
    if BM.tool == "ladder" and Pl() then f = Pl().LadderFacingAt(world().lot, st.i, st.j, BM.f) or BM.f end
    local blocked = {}
    for _, c in ipairs(plan.preview and plan.preview.cells or {}) do if c.bad then blocked[#blocked + 1] = { c.i, c.j } end end
    return { def = defId, x = st.i, y = st.j, f = f, level = st.level, valid = plan.ok and true or false, blocked = blocked }
end

-- Recompute the preview when the snapped cursor, tool, selection or lot changed.
function BM.Preview(force)
    local w = world()
    if not w or UI.mode ~= "build" then return end
    local st, hover, key = BM.InputState()
    local pk = planKey(st, key)
    if not force and pk == BM.planKey then return end
    BM.planKey = pk
    BM.st = st
    BM.plan = computePlan(st)
    BM.hover = hover
    BF.Show(w, BM.plan, hover, camLevel())
    if SS.Render.SetGhost then
        local g = ghostFor(BM.plan, st)
        if g or BM.ghostShown then SS.Render.SetGhost(g) end
        BM.ghostShown = g ~= nil
    end
    BM.RefreshInfo()
end

function BM.ClearPreview()
    BM.drag, BM.plan, BM.planKey, BM.st, BM.hover = nil, nil, nil, nil, nil
    BM.sigTool = nil
    BF.Clear()
    if BM.ghostShown and SS.Render.SetGhost then SS.Render.SetGhost(nil) end
    BM.ghostShown = false
    if BM.label then BM.label:Hide() end
end

---------------------------------------------------------------------------------------------------
-- Commit, undo, redo, eyedropper
---------------------------------------------------------------------------------------------------
local function resultText(plan, tx)
    local label = (tx and tx.label) or plan.label or "Done"
    local cost = tx and tx.cost
    if cost == nil then cost = plan.cost end
    local w = world()
    if w and B.IsFree(w) then return label .. " (free here)" end
    if cost and cost > 0 then return label .. ": " .. fmt(cost) end
    if cost and cost < 0 then return label .. ": refund " .. fmt(-cost) end
    return label
end

local function doCommit(plan)
    local w = world()
    if not w then return false, "No lot." end
    local ok, res = B.Commit(w, plan)
    if ok then
        cue("place")
        notice(resultText(plan, type(res) == "table" and res or nil))
        BM.lastCommit = { label = plan.label, cost = plan.cost, kind = plan.kind }
    else
        cue("alert")
        notice(res)
    end
    if BM.drag and not BM.drag.keep then BM.drag = nil end
    BM.Preview(true)
    return ok, res
end

-- Commit a previewed plan: invalid plans only explain; dangerous ones ask first.
function BM.CommitPlan(plan)
    if not plan then return false, "Nothing to build there." end
    if not plan.ok then
        cue("alert")
        notice(plan.why or "That can't be built there.")
        return false, plan.why
    end
    if plan.danger then
        local result
        UI.Confirm(plan.danger .. "\n\nDo it anyway?", function() result = { doCommit(plan) } end, function() notice("Left as it was.") end)
        if result then return result[1], result[2] end
        return false, "confirm"
    end
    return doCommit(plan)
end

function BM.Undo()
    local w = world()
    if not w then return false end
    local tx = SS.Undo.Peek()
    local desc = tx and SS.Undo.Describe(tx)
    local ok, why = SS.Undo.Undo(w)
    if ok then cue("place"); notice("Undone: " .. desc) else cue("alert"); notice(why) end
    BM.drag = nil
    BM.Preview(true)
    return ok, why
end

function BM.Redo()
    local w = world()
    if not w then return false end
    local tx = SS.Undo.PeekRedo()
    local desc = tx and SS.Undo.Describe(tx)
    local ok, why = SS.Undo.Redo(w)
    if ok then cue("place"); notice("Redone: " .. desc) else cue("alert"); notice(why) end
    BM.drag = nil
    BM.Preview(true)
    return ok, why
end

-- Eyedropper result -> tab, tool and the catalogue list its item belongs to.
local PICK = {
    stairs = { "stairs", "stairs", "stairs" }, column = { "fences", "column", "column" }, steps = { "fences", "steps", "steps" },
    ladder = { "pool", "ladder", "ladder" }, landscape = { "garden", "landscape", "landscape" }, door = { "doors", "door", "door" },
    window = { "windows", "window", "window" }, fence = { "fences", "fence", "fence" }, gate = { "fences", "gate", "fence" },
    railing = { "fences", "railing", "railing" }, paint = { "paint", "paintside", "wallFinish" }, pool = { "pool", "pool", "pool" },
    floor = { "floors", "tile", "floor" }, pond = { "terrain", "pond", "pond" }, terrain = { "terrain", "ground", "ground" },
}

function BM.Eyedrop(kind, ref, wx, wy, level)
    local w = world()
    local r = w and B.Eyedropper(w, level or camLevel(), wx, wy, kind, ref)
    if not r then notice("Nothing to pick up there."); return false end
    local m = PICK[r.tool]
    if r.tool == "floor" and B.IsOutdoorFloor(r.item) then m = { "terrain", "path", "path" } end
    if not m then notice("Nothing to pick up there."); return false end
    local list = BM.Items(m[3])
    local name
    for _, e in ipairs(list) do if e.id == r.item then name = e.name end end
    if not name then
        if r.tool == "landscape" then notice("That is furniture: pick it up in buy mode.") else notice("That style isn't in the catalogue any more.") end
        return false
    end
    BM.sel[m[3]] = r.item
    if r.f then BM.f = r.f end
    BM.SelectTab(m[1], m[2])
    notice("Picked " .. name .. ".")
    return true, r
end

---------------------------------------------------------------------------------------------------
-- Tool selection and options
---------------------------------------------------------------------------------------------------
function BM.SelectTab(id, tool)
    local tab = BM.TAB[id]
    if not tab then return end
    BM.tab = id
    BM.SelectTool(tool or BM.lastByTab[id] or tab.tools[1])
end

function BM.SelectTool(id)
    local t = BM.TOOLS[id]
    if not t then return end
    if t.utility then
        if not BM.TOOLS[BM.tool].utility then BM.lastTool = BM.tool end
    else
        BM.lastTool = id
        BM.tab = t.tab
        BM.lastByTab[t.tab] = id
    end
    BM.tool = id
    BM.drag = nil
    BM.RefreshControls()
    BM.Preview(true)
end

BM.SIDES = { "south", "west", "north", "east" }
BM.SIDE_NAMES = { south = "South", west = "West", north = "North", east = "East" }
BM.BRUSH_NAMES = { [0] = "1 corner", [1] = "3 x 3", [2] = "5 x 5" }

-- Up to two option buttons per tool: label, tooltip and what a click does.
function BM.Options()
    local id = BM.tool
    local out = {}
    if id == "raise" or id == "lower" then
        out[1] = { label = "Brush: " .. BM.BRUSH_NAMES[BM.brush], tip = "Brush size: how many corners move together.",
            run = function() BM.brush = (BM.brush + 1) % 3 end }
    elseif id == "room" then
        out[1] = { label = BM.roomFloor and "Floor: on" or "Floor: off", tip = "Also lay the selected floor (Floors tab) inside the new room.",
            run = function() BM.roomFloor = not BM.roomFloor end }
    elseif id == "roofstyle" or id == "roofmaterial" or id == "roofcolor" then
        out[1] = { label = BM.roofScope == "lot" and "Whole lot" or "One building",
            tip = "Whole lot: click anywhere to change every roof. One building: click a building to give it its own roof.",
            run = function() BM.roofScope = BM.roofScope == "lot" and "building" or "lot" end }
        if id == "roofstyle" then
            out[2] = { label = "Low side: " .. BM.SIDE_NAMES[BM.roofSide], tip = "Shed roofs slope down toward this side.",
                run = function()
                    local n = 1
                    for k, s in ipairs(BM.SIDES) do if s == BM.roofSide then n = k end end
                    BM.roofSide = BM.SIDES[n % #BM.SIDES + 1]
                end }
        end
    elseif BM.TOOLS[id] and BM.TOOLS[id].facing then
        out[1] = { label = "Turn (R)", tip = "Turn what you are placing a quarter turn.", run = function() BM.Rotate(1) end }
    end
    return out
end

function BM.Option(n)
    local o = BM.Options()[n]
    if not o then return end
    o.run()
    BM.RefreshControls()
    BM.Preview(true)
end

function BM.Rotate(d)
    local t = BM.TOOLS[BM.tool]
    if BM.tool == "rotate" and BM.plan then return BM.CommitPlan(BM.plan) end
    BM.f = (BM.f + (d or 1)) % 4
    if t and not t.facing then notice("Turned the placement direction.") end
    BM.RefreshControls()
    BM.Preview(true)
end

function BM.SetGrid(on)
    BM.grid = on and true or false
    BF.SetGrid(BM.grid, world(), camLevel())
    BM.RefreshControls()
end

-- Esc / right-click / Cancel button. Returns true when something was cancelled.
function BM.Cancel()
    if BM.drag then
        BM.drag = nil
        BM.Preview(true)
        notice("Cancelled: nothing was built or charged.")
        return true
    end
    if BM.TOOLS[BM.tool] and BM.TOOLS[BM.tool].utility then
        BM.SelectTool(BM.lastTool or "wall")
        return true
    end
    return false
end

---------------------------------------------------------------------------------------------------
-- Mode callbacks
---------------------------------------------------------------------------------------------------
function BM.CanEnter(w)
    if not w or not w.lot then return false, "Load a household first." end
    local s = w.settings or {}
    local sandbox = s.sandboxMoney or s.sandbox
    if SS.Fire and SS.Fire.Active and SS.Fire.Active(w) and not sandbox then
        return false, "Not during an emergency: deal with it first (building is allowed in sandbox money mode)."
    end
    local lot = w.lot
    if lot.kind == "community" and not w.editVenue and not sandbox then
        return false, "Community lots can only be rebuilt while editing them from the neighbourhood."
    end
    if lot.kind ~= "community" and w.household and w.household.lotId and w.household.lotId ~= lot.id and not sandbox and not w.editVenue then
        return false, "You can only build on your own home."
    end
    for _, a in pairs(w.actors or {}) do
        if a.act and a.act.flight and (a.act.flight.kind == "trip" or a.act.flight.travel) then
            return false, "Wait until " .. (a.name or "everyone") .. " has left or arrived."
        end
    end
    return true
end

function BM.Enter(w)
    BM.cursor, BM.drag, BM.pickHit, BM.wasDown = nil, nil, nil, false
    BM.levelSeen = camLevel()
    BM.versionSeen = w and w.lot.version
    BF.SetGrid(BM.grid, w, camLevel())
    BM.RefreshControls()
    BM.Preview(true)
end

function BM.Exit(w)
    BM.ClearPreview()
    BM.cursor = nil
    BF.grid = false
end

-- What the current tool reads from the cursor, as three numbers: the snapped corner or cell,
-- plus (for edge and pick tools) which edge of the cell is nearest, whether it is within the pick
-- distance, and which half of a diagonal the point is in. While these stay the same the plan
-- can't change, so mouse moves inside them build nothing (no strings, tables or plans).
local function cursorSig(input, wx, wy)
    if input == "line" or input == "rectc" or input == "corner" then
        local x, y = corner(wx, wy)
        return x, y, 0
    end
    local i, j = cell(wx, wy)
    if input == "edge" or input == "target" then
        local fx, fy = wx - math.floor(wx), wy - math.floor(wy)
        local best, code = fy, 0
        if 1 - fy < best then best, code = 1 - fy, 1 end
        if fx < best then best, code = fx, 2 end
        if 1 - fx < best then best, code = 1 - fx, 3 end
        return i, j, code * 8 + (best <= 0.3 and 4 or 0) + (fy < fx and 2 or 0) + (fx + fy < 1 and 1 or 0)
    end
    return i, j, 0
end

local CURSOR = {}
function BM.MouseMove(wx, wy, level)
    if not wx then return end
    local lv = level or camLevel()
    CURSOR[1], CURSOR[2], CURSOR[3] = wx, wy, lv
    BM.cursor = CURSOR
    BM.pickHit = nil
    local d = BM.drag
    local t = BM.TOOLS[BM.tool]
    local dragMoved = false
    if d and t then
        local cx, cy = snapFor(t.input, wx, wy)
        if cx ~= d.cx or cy ~= d.cy then
            dragMoved = true
            d.cx, d.cy = cx, cy
            if cx ~= d.sx or cy ~= d.sy then d.moved = true end
            if d.cells and #d.cells < B.T.maxCells then
                local k = cx .. ":" .. cy
                if not d.set[k] then d.set[k] = true; d.cells[#d.cells + 1] = { cx, cy } end
            end
        end
    end
    if t and not dragMoved and BM.planKey then
        local a1, a2, a3 = cursorSig(t.input, wx, wy)
        if a1 == BM.sig1 and a2 == BM.sig2 and a3 == BM.sig3 and BM.sigTool == BM.tool and BM.sigLevel == lv then return end
        BM.sig1, BM.sig2, BM.sig3, BM.sigTool, BM.sigLevel = a1, a2, a3, BM.tool, lv
    elseif t then
        BM.sig1, BM.sig2, BM.sig3 = cursorSig(t.input, wx, wy)
        BM.sigTool, BM.sigLevel = BM.tool, lv
    end
    BM.Preview()
end

-- Mouse pressed over the lot (seen by the frame loop): start a drag for drag tools.
function BM.PointerDown()
    local t = BM.TOOLS[BM.tool]
    local c = BM.cursor
    if not (t and c and DRAG[t.input]) then return end
    if BM.drag and BM.drag.sticky then return end
    local sx, sy = snapFor(t.input, c[1], c[2])
    BM.drag = { sx = sx, sy = sy, cx = sx, cy = sy, moved = false }
    if t.input == "brush" then BM.drag.cells, BM.drag.set = { { sx, sy } }, { [sx .. ":" .. sy] = true } end
    if BM.tool == "flatten" and Te() then BM.drag.h0 = Te().CornerH(world().lot, sx, sy) end
    BM.Preview(true)
end

-- Press on the lot (called by the shell when it offers mode.mouseDown; otherwise BM.Update polls
-- the button). A press from either path starts the drag once.
function BM.MouseDown(btn, wx, wy, level)
    if btn ~= "LeftButton" then return false end
    if wx then CURSOR[1], CURSOR[2], CURSOR[3] = wx, wy, level or camLevel(); BM.cursor = CURSOR end
    BM.PointerDown()
    BM.wasDown = true
    return true
end

function BM.Click(btn, kind, ref, wx, wy, level)
    local w = world()
    if not w then return true end
    if btn == "RightButton" then BM.Cancel(); return true end
    local t = BM.TOOLS[BM.tool]
    if not t then return true end
    if t.input ~= "roof" or BM.roofScope ~= "lot" then
        if not wx then notice("Click inside the lot."); return true end
    end
    if wx then
        CURSOR[1], CURSOR[2], CURSOR[3] = wx, wy, level or camLevel()
        BM.cursor = CURSOR
        local d = BM.drag
        if d then
            local cx, cy = snapFor(t.input, wx, wy)
            if cx ~= d.cx or cy ~= d.cy then BM.MouseMove(wx, wy, level) end
        end
    end
    BM.pickHit = (kind == "obj" or kind == "actor") and { kind, ref } or nil
    if BM.tool == "pick" then
        BM.Eyedrop(kind, ref, wx, wy, level or camLevel())
        return true
    end
    if DRAG[t.input] then
        local d = BM.drag
        if not d then
            BM.PointerDown()
            d = BM.drag
            if not d then return true end
            if t.input == "line" or t.input == "rectc" then
                -- the press was not seen as a drag: this click is the start point
                d.sticky = true
                BM.Preview(true)
                notice("Now click where it should end (right-click cancels).")
                return true
            end
        elseif (t.input == "line" or t.input == "rectc") and not d.moved and not d.sticky then
            d.sticky = true
            BM.Preview(true)
            notice("Now click where it should end (right-click cancels).")
            return true
        end
        BM.Preview(true)
        local plan = BM.plan
        BM.drag = nil
        return BM.CommitPlan(plan) or true
    end
    BM.Preview(true)
    BM.CommitPlan(BM.plan)
    return true
end

local SPEED_KEYS = { SPACE = true, ["0"] = true, ["1"] = true, ["2"] = true, ["3"] = true }
function BM.OnKey(key)
    if key == "ESCAPE" then return BM.Cancel() end
    local ctrl = IsControlKeyDown and IsControlKeyDown()
    local shift = IsShiftKeyDown and IsShiftKeyDown()
    if key == "Z" then
        if not ctrl then return false end
        if shift then BM.Redo() else BM.Undo() end
        return true
    elseif key == "Y" then
        if not ctrl then return false end
        BM.Redo()
        return true
    elseif key == "R" then BM.Rotate(shift and -1 or 1); return true
    elseif key == "G" then BM.SetGrid(not BM.grid); return true
    elseif key == "I" then BM.SelectTool(BM.tool == "pick" and (BM.lastTool or "wall") or "pick"); return true
    elseif key == "DELETE" or key == "BACKSPACE" then BM.SelectTool(BM.tool == "delete" and (BM.lastTool or "wall") or "delete"); return true
    elseif SPEED_KEYS[key] then
        notice("Time stands still while you build. Leave build mode (Esc or F1) to carry on.")
        return true
    elseif key == "PAGEUP" or key == "PAGEDOWN" then
        BM.drag = nil
        return false   -- the window changes the floor; the preview follows on the next frame
    end
    return false
end

function BM.Update(el)
    local w = world()
    if not w or UI.mode ~= "build" then return end
    -- time never passes in build mode (undo relies on it): a speed change waits for leaving
    if (w.speed or 0) ~= 0 then
        UI.resumeSpeed = w.speed
        SS.Sim.SetSpeed(0)
        notice("Time stands still while you build; that speed applies when you leave build mode.")
    end
    local down = IsMouseButtonDown and IsMouseButtonDown("LeftButton") and true or false
    if down and not BM.wasDown and UI.viewport and UI.viewport:IsMouseOver() then BM.PointerDown() end
    BM.wasDown = down
    if camLevel() ~= BM.levelSeen then
        BM.levelSeen = camLevel()
        BM.drag = nil
        if BM.grid then BF.SetGrid(true, w, camLevel()) end
        BM.RefreshControls()
        BM.Preview(true)
    elseif w.lot.version ~= BM.versionSeen then
        BM.versionSeen = w.lot.version
        BM.Preview(true)
    end
    BM.t = BM.t + (el or 0)
    if BM.t >= 0.25 then BM.t = 0; BM.RefreshInfo() end
    BM.PlaceLabel()
end

---------------------------------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------------------------------
local function setColor(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

function BM.ItemTip(e)
    if not e then return "" end
    local lines = { e.name, e.priceText or fmt(e.price or 0) }
    if e.desc and e.desc ~= "" then lines[#lines + 1] = e.desc end
    if e.extra then lines[#lines + 1] = e.extra end
    if e.infoOnly then lines[#lines + 1] = "Gates always match the fence they go in." end
    return table.concat(lines, "\n")
end

function BM.SelectItem(e)
    if not e then return end
    local t = BM.TOOLS[BM.tool]
    if not (t and t.list) then return end
    if e.infoOnly then
        -- gate list: pick the matching fence family for the Fence tool
        BM.sel.fence = e.id
        notice(e.name .. ": point at a " .. (B.Item("fences", e.id) or { name = "fence" }).name .. " segment.")
    else
        BM.sel[t.list] = e.id
    end
    if BM.list then BM.list:Page(BM.list.page) end
    BM.Preview(true)
end

-- Optional toolbar icons (docs/art_requests/build.md): a button shows SS.Art.icons[name] beside its
-- label when the art manifest has that icon; otherwise it keeps its text label alone.
function BM.SetIcon(b, name)
    local icons = SS.Art and SS.Art.icons
    local sprite = name and icons and icons[name]
    local shown = false
    if sprite and SS.Art.sprites and SS.Art.sprites[sprite] then
        b.icon = b.icon or K.Tex(b, "ARTWORK")
        b.icon:ClearAllPoints()
        b.icon:SetPoint("LEFT", 2, 0)
        local ok, res = pcall(K.SetSprite, b.icon, sprite, 14, 14)
        shown = ok and res and true or false
    end
    if not shown and b.icon then b.icon:Hide() end
    b.label:ClearAllPoints()
    b.label:SetPoint("CENTER", shown and 7 or 0, 0)
    b.iconName = shown and name or nil
    return shown
end

function BM.Create(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    BM.frame = f
    -- tabs
    BM.tabBtns = {}
    for n, tab in ipairs(BM.TABS) do
        local b = K.Button(f, tab.label, 56, 18, function() BM.SelectTab(tab.id) end, tab.tip)
        b:SetPoint("TOPLEFT", 6 + (n - 1) * 58, -4)
        BM.SetIcon(b, "build_tab_" .. tab.id)
        BM.tabBtns[tab.id] = b
    end
    -- tools of the current tab (pooled)
    BM.toolBtns = {}
    for n = 1, 7 do
        local b = K.Button(f, "", 62, 18, function(self) if self.toolId then BM.SelectTool(self.toolId) end end, function(self) return self.toolTip end)
        b:SetPoint("TOPLEFT", 6 + (n - 1) * 64, -26)
        BM.toolBtns[n] = b
    end
    BM.optBtns = {}
    for n = 1, 2 do
        local b = K.Button(f, "", 104, 18, function() BM.Option(n) end, function() local o = BM.Options()[n]; return o and o.tip or "" end)
        b:SetPoint("TOPLEFT", 6 + 7 * 64 + (n - 1) * 106, -26)
        BM.optBtns[n] = b
    end
    -- catalogue
    BM.list = K.PagedList(f, 4, 19, function(r)
        r.hl = K.Tex(r, "BACKGROUND", COL.panelDark); r.hl:SetAllPoints(); r.hl:Hide()
        r.sw = K.Tex(r, "ARTWORK", { 1, 1, 1, 1 }); r.sw:SetSize(12, 12); r.sw:SetPoint("LEFT", 3, 0)
        r.name = K.Text(r, 11); r.name:SetPoint("LEFT", 20, 0); r.name:SetWidth(150)
        r.price = K.Text(r, 10, COL.inkSoft, "RIGHT"); r.price:SetPoint("RIGHT", -4, 0); r.price:SetWidth(80)
        r:SetScript("OnClick", function(self) if SS.Audio and SS.Audio.Cue then SS.Audio.Cue("click") end; BM.SelectItem(self.item) end)
        K.Tooltip(r, function(self) return BM.ItemTip(self.item) end)
    end, function(r, e)
        r.item = e
        r.name:SetText(e.name)
        r.price:SetText(e.priceText or fmt(e.price or 0))
        if e.rgb then r.sw:SetColorTexture(e.rgb[1], e.rgb[2], e.rgb[3], 1); r.sw:Show() else r.sw:Hide() end
        local t = BM.TOOLS[BM.tool]
        local on = t and t.list and (BM.sel[t.list] == e.id or (e.infoOnly and BM.sel.fence == e.id))
        r.hl:SetShown(on and true or false)
    end)
    BM.list.frame:SetPoint("TOPLEFT", 6, -48)
    BM.list.frame:SetSize(250, 96)
    BM.listNote = K.Text(f, 11, COL.inkSoft)
    BM.listNote:SetPoint("TOPLEFT", 8, -52); BM.listNote:SetWidth(244)
    -- info (plan, cost, warnings, undo, session)
    for n = 1, 5 do
        local fs = K.Text(f, n == 1 and 12 or 11, n == 1 and COL.ink or COL.inkSoft)
        fs:SetPoint("TOPLEFT", 266, -48 - (n - 1) * 17)
        fs:SetPoint("RIGHT", f, "RIGHT", -150, 0)
        BM.info[n] = fs
    end
    -- utilities (right column)
    local function util(label, row, col, fn, tip)
        local b = K.Button(f, label, 64, 18, fn, tip)
        b:SetPoint("TOPRIGHT", -6 - (col - 1) * 68, -26 - (row - 1) * 20)
        return b
    end
    BM.undoBtn = util("Undo", 1, 2, function() BM.Undo() end, function()
        local tx = SS.Undo.Peek()
        return tx and ("Undo (Ctrl+Z): " .. SS.Undo.Describe(tx) .. (tx.cost and tx.cost ~= 0 and (tx.cost > 0 and "\nRefunds exactly what it cost." or "\nTakes back exactly what it paid out.") or "")) or "Nothing to undo."
    end)
    BM.redoBtn = util("Redo", 1, 1, function() BM.Redo() end, function()
        local tx = SS.Undo.PeekRedo()
        return tx and ("Redo (Ctrl+Y): " .. SS.Undo.Describe(tx)) or "Nothing to redo."
    end)
    BM.pickBtn = util("Pick", 2, 2, function() BM.SelectTool(BM.tool == "pick" and BM.lastTool or "pick") end, BM.TOOLS.pick.tip)
    BM.deleteBtn = util("Delete", 2, 1, function() BM.SelectTool(BM.tool == "delete" and BM.lastTool or "delete") end, BM.TOOLS.delete.tip)
    BM.rotateBtn = util("Rotate", 3, 2, function() BM.SelectTool(BM.tool == "rotate" and BM.lastTool or "rotate") end, BM.TOOLS.rotate.tip)
    BM.gridBtn = util("Grid", 3, 1, function() BM.SetGrid(not BM.grid) end, "Show the tile grid on the edited floor (G).")
    BM.cancelBtn = util("Cancel", 4, 2, function() if not BM.Cancel() then notice("Nothing to cancel.") end end,
        "Cancel the line or area being drawn (Esc or right-click). Nothing is charged until a plan is built.")
    BM.upBtn = K.Button(f, "Up", 30, 18, function() BM.ChangeLevel(1) end, "Edit the floor above (Page Up).")
    BM.upBtn:SetPoint("TOPRIGHT", -40, -86)
    BM.downBtn = K.Button(f, "Dn", 30, 18, function() BM.ChangeLevel(-1) end, "Edit the floor below (Page Down).")
    BM.downBtn:SetPoint("TOPRIGHT", -6, -86)
    BM.floorText = K.Text(f, 11, COL.ink, "RIGHT")
    BM.floorText:SetPoint("TOPRIGHT", -6, -110); BM.floorText:SetWidth(136)
    BM.moneyText = K.Text(f, 10, COL.inkSoft, "RIGHT")
    BM.moneyText:SetPoint("TOPRIGHT", -6, -126); BM.moneyText:SetWidth(136)
    -- cost label beside the cursor
    local lf = CreateFrame("Frame", nil, UI.frame or f)
    lf:SetFrameStrata("DIALOG")
    lf:SetSize(160, 18)
    K.Tex(lf, "BACKGROUND", { 0.10, 0.11, 0.12, 0.82 }):SetAllPoints()
    lf.text = K.Text(lf, 11, COL.white, "LEFT")
    lf.text:SetPoint("LEFT", 4, 0)
    lf:Hide()
    BM.label = lf
    SS.On("undoChanged", function() if UI.mode == "build" then BM.RefreshInfo() end end)
    BM.RefreshControls()
    return f
end

function BM.ChangeLevel(d)
    if UI.ChangeLevel then UI.ChangeLevel(d)
    else
        local cam = SS.Render.cam
        cam.level = math.max(0, math.min(SS.World.LEVELS - 1, (cam.level or 0) + d))
        UI.dirty = true
    end
    BM.drag = nil
    BM.RefreshControls()
    BM.Preview(true)
end

function BM.RefreshControls()
    if not BM.frame then return end
    for id, b in pairs(BM.tabBtns) do b:SetActive(id == BM.tab and not BM.TOOLS[BM.tool].utility) end
    local tab = BM.TAB[BM.tab]
    for n, b in ipairs(BM.toolBtns) do
        local id = tab and tab.tools[n]
        if id then
            local t = BM.TOOLS[id]
            b.toolId, b.toolTip = id, t.tip
            b.label:SetText(t.label)
            if b.iconFor ~= id then b.iconFor = id; BM.SetIcon(b, "build_tool_" .. id) end
            b:SetActive(BM.tool == id)
            b:Show()
        else
            b.toolId = nil
            b:Hide()
        end
    end
    local opts = BM.Options()
    for n, b in ipairs(BM.optBtns) do
        local o = opts[n]
        if o then b.label:SetText(o.label); b:Show() else b:Hide() end
    end
    BM.pickBtn:SetActive(BM.tool == "pick")
    BM.deleteBtn:SetActive(BM.tool == "delete")
    BM.rotateBtn:SetActive(BM.tool == "rotate")
    BM.gridBtn:SetActive(BM.grid)
    -- catalogue
    local t = BM.TOOLS[BM.tool]
    local items = t and t.list and BM.Items(t.list) or {}
    BM.listItems = items
    if t and t.list and #items > 0 then
        BM.list.frame:Show()
        BM.listNote:Hide()
        local page = 1
        local key = t.list == "gate" and "fence" or t.list
        for n, e in ipairs(items) do if e.id == BM.sel[key] then page = math.floor((n - 1) / BM.list.perPage) + 1 end end
        BM.list:SetItems(items)
        BM.list:Page(page)
    else
        BM.list.frame:Hide()
        BM.listNote:SetText((t and t.list and BM.EMPTY[t.list]) or (t and t.help) or "")
        BM.listNote:Show()
    end
    local lv = camLevel()
    BM.floorText:SetText(lv == 0 and "Floor: Ground" or ("Floor: Upstairs " .. lv))
    BM.upBtn:SetUsable(lv < SS.World.LEVELS - 1)
    BM.downBtn:SetUsable(lv > 0)
    BM.RefreshInfo()
end

-- Text for the info area (also used by tests).
function BM.InfoLines()
    local w = world()
    local t = BM.TOOLS[BM.tool]
    local plan = BM.plan
    local lines = { "", "", "", "", "" }
    if not w then return lines end
    if plan then
        lines[1] = plan.label or (t and t.label) or ""
        if plan.ok then
            local c = B.CostText(w, plan)
            if not B.IsFree(w) and plan.cost > 0 and plan.cost > (w.money or 0) then c = c .. "  (the household has " .. fmt(w.money or 0) .. ")" end
            lines[2] = c
        else
            lines[2] = "Can't: " .. tostring(plan.why or "that can't be built here.")
        end
        local extra = {}
        for _, x in ipairs(plan.warnings or {}) do extra[#extra + 1] = x end
        for _, x in ipairs(plan.notes or {}) do extra[#extra + 1] = x end
        lines[3] = table.concat(extra, "  ")
    else
        lines[1] = t and t.help or ""
        lines[2] = (BM.drag and BM.drag.sticky) and "Click the end point, or right-click to cancel." or ""
    end
    local u = SS.Undo.Peek()
    local r = SS.Undo.PeekRedo()
    lines[4] = (u and ("Undo: " .. SS.Undo.Describe(u)) or "Nothing to undo") .. (r and ("   Redo: " .. SS.Undo.Describe(r)) or "")
    local s = SS.Undo.session
    if B.IsFree(w) then lines[5] = "Free editing here: nothing is charged."
    else lines[5] = string.format("This visit: spent %s, refunded %s (%d edit%s)", fmt(s.spent), fmt(s.refunded), s.count, s.count == 1 and "" or "s") end
    return lines
end

function BM.RefreshInfo()
    if not BM.frame then return end
    local w = world()
    local lines = BM.InfoLines()
    for n, fs in ipairs(BM.info) do fs:SetText(lines[n] or "") end
    if BM.plan and not BM.plan.ok then setColor(BM.info[2], COL.warn) else setColor(BM.info[2], COL.good) end
    setColor(BM.info[3], COL.warn)
    BM.undoBtn:SetUsable(SS.Undo.CanUndo())
    BM.redoBtn:SetUsable(SS.Undo.CanRedo())
    if w then BM.moneyText:SetText(B.IsFree(w) and "Free editing" or ("Funds " .. fmt(w.money or 0))) end
end

-- The small cost/reason label that follows the cursor over the lot.
function BM.LabelText()
    local w = world()
    local plan = BM.plan
    if not (w and plan) then return nil end
    if not plan.ok then return plan.why, false end
    local c = plan.cost or 0
    if B.IsFree(w) then return "Free", true end
    if c > 0 then return fmt(c), true end
    if c < 0 then return "+" .. fmt(-c), true end
    return "No cost", true
end

-- The floating cost label runs every frame: its text is worked out once per plan (and free
-- state), the colours are constants, and it only moves when the cursor did.
local LABEL_OK, LABEL_BAD = { 0.75, 1, 0.75 }, { 1, 0.7, 0.6 }
function BM.PlaceLabel()
    local lf = BM.label
    if not lf then return end
    local w = world()
    local free = w and B.IsFree(w) or false
    if lf.ssPlan ~= BM.plan or lf.ssFree ~= free then
        lf.ssPlan, lf.ssFree = BM.plan, free
        lf.ssText, lf.ssOk = BM.LabelText()
        if lf.ssText then
            lf.text:SetText(lf.ssText)
            setColor(lf.text, lf.ssOk and LABEL_OK or LABEL_BAD)
            lf:SetWidth(math.min(320, math.max(40, (lf.text:GetStringWidth() or 60) + 10)))
        end
    end
    if not lf.ssText or not (UI.viewport and UI.viewport:IsMouseOver()) then
        if lf:IsShown() then lf:Hide() end
        return
    end
    local x, y = GetCursorPosition()
    if x ~= lf.ssX or y ~= lf.ssY or not lf:IsShown() then
        lf.ssX, lf.ssY = x, y
        local sc = (UI.frame and UI.frame:GetEffectiveScale()) or 1
        lf:ClearAllPoints()
        lf:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / sc + 16, y / sc + 6)
        lf:Show()
    end
end

---------------------------------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------------------------------
UI.RegisterMode("build", {
    label = "Build", order = 20, key = "F3", audio = "build", pausesSim = true,
    tip = "Build mode: walls, floors, doors, windows, stairs, roofs, fences, terrain, gardens and pools. The household waits while you build.",
    create = BM.Create, canEnter = BM.CanEnter, enter = BM.Enter, exit = BM.Exit,
    click = BM.Click, mouseMove = BM.MouseMove, mouseDown = BM.MouseDown, onKey = BM.OnKey, update = BM.Update,
    keys = { R = true, G = true, I = true, DELETE = true, BACKSPACE = true, Z = true, Y = true },
    keyHelp = {
        { "Drag", "Draw walls, fences, rooms and areas (or click start, then end)" },
        { "Right-click / Esc", "Cancel the current drag (nothing is charged)" },
        { "R", "Turn stairs, steps, columns, ladders and garden objects" },
        { "Ctrl+Z / Ctrl+Y", "Undo / redo (money exactly returned or retaken)" },
        { "I", "Eyedropper: pick up a finish or style" },
        { "Del", "Delete / sell tool" },
        { "G", "Grid on / off" },
        { "Page Up / Down", "Edit the floor above / below" },
    },
    help = {
        "Build mode pauses the household. Every tool shows its full cost (or refund) and any problem before you commit; nothing is charged until you release the mouse on a valid plan.",
        "Walls: drag between grid corners; a 45-degree drag builds a diagonal. Room drags a rectangle. Erase refunds 75%, Undo refunds 100%.",
        "Upstairs floors need a wall or column below within 2 tiles. Open edges upstairs get railings automatically. Stairs need a floor tile at the top.",
        "Roofs build themselves over indoor rooms; the Roof tab changes style, material and colour for the whole lot or one building.",
        "Pools need a ladder: swimmers only get in and out by ladders and tire in the water. Removing the last ladder while someone swims asks first.",
    },
})
