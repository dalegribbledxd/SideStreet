-- Terrain: bounded corner heightfield, ground paint, ponds, raise/lower/flatten tools, GroundZ.
-- Owner: build module (see ARCHITECTURE.md §5, §6, docs/modules/build.md).
--
-- Heights live on lot corners: lot.terrain.h[cornerIdx] = steps (nil = 0), cornerIdx = j*(w+1)+i+1
-- for corner (i, j), 0 <= i <= w, 0 <= j <= h. One step is Te.STEP tiles. The model is bounded:
--   * every height stays within Te.MIN..Te.MAX steps;
--   * any two corners of one cell (including diagonals) differ by at most one step, so every cell
--     is either flat or a single-step slope that the pre-rendered corner-pattern tiles can draw
--     (4 corner offsets of 0/1 plus a split flag) and that people can walk.
-- Raising or lowering a corner pushes its neighbours along to keep that bound (a smooth hill).
-- Corners under structures (walls, fences, floors, objects, pools, ponds, stairs, diagonal walls,
-- upstairs floors) are locked: an edit that would move one is refused with the reason.
local _, SS = ...
local G, W, B = SS.Grid, SS.World, SS.Build
local Te = { STEP = 0.25, MIN = -4, MAX = 8 }
SS.Terrain = Te

Te.T = {
    stepPrice = 5,      -- per corner per step moved (raise, lower, flatten)
    slopeCost = 0.3,    -- extra route cost on a sloped cell (people prefer level ground and steps)
    maxBrush = 2,       -- raise/lower brush radius in corners (0 = one corner, 2 = a 5x5 patch)
    maxFlatten = 900,   -- corners one flatten may touch
}

-- Decorative water (not swimmable). Ids stored in lot.terrain.water[idx].
Te.PONDS = {
    { id = "pond_clear", name = "Clear Garden Pond", price = 30, desc = "Still water with a pebble bed. Frogs sold separately; frogs arrive anyway." },
    { id = "pond_lily", name = "Lily Pond", price = 45, desc = "Floating lilies and a sense that something is watching from under the leaves." },
    { id = "pond_koi", name = "Koi Pool", price = 70, desc = "Deeper, darker water with flashes of orange. The fish have opinions about your garden." },
}
Te.POND = {}
for _, p in ipairs(Te.PONDS) do Te.POND[p.id] = p end

local function round(v) return math.floor(v + 0.5) end

---------------------------------------------------------------------------------------------------
-- Height queries (lot data only; safe on lots that have never been edited)
---------------------------------------------------------------------------------------------------
function Te.CornerIdx(lot, i, j) return j * (lot.w + 1) + i + 1 end

-- Height in steps of corner (i, j); positions outside the lot clamp to the nearest corner.
function Te.CornerH(lot, i, j)
    local t = lot.terrain
    local h = t and t.h
    if not h then return 0 end
    if i < 0 then i = 0 elseif i > lot.w then i = lot.w end
    if j < 0 then j = 0 elseif j > lot.h then j = lot.h end
    return h[j * (lot.w + 1) + i + 1] or 0
end
local CH = Te.CornerH

-- The four corners of cell (i, j): nw = (i, j), ne = (i+1, j), se = (i+1, j+1), sw = (i, j+1).
function Te.CellCorners(lot, i, j)
    return CH(lot, i, j), CH(lot, i + 1, j), CH(lot, i + 1, j + 1), CH(lot, i, j + 1)
end

function Te.FlatLot(lot, i, j)
    local a, b, c, d = Te.CellCorners(lot, i, j)
    return a == b and b == c and c == d
end
-- True when the cell's four corners are level (walls, floors, objects and stairs need this).
function Te.Flat(world, i, j) return Te.FlatLot(world.lot, i, j) end

-- Lowest corner of a cell (steps) and its height in tiles.
function Te.CellBase(lot, i, j)
    local a, b, c, d = Te.CellCorners(lot, i, j)
    return math.min(a, b, c, d)
end
function Te.CellZ(lot, i, j) return Te.CellBase(lot, i, j) * Te.STEP end

-- Difference between the highest and lowest corner of a cell (0 = flat, 1 = a walkable slope).
function Te.Spread(lot, i, j)
    local a, b, c, d = Te.CellCorners(lot, i, j)
    return math.max(a, b, c, d) - math.min(a, b, c, d)
end

-- Ground height in tiles at a world position (bilinear over the cell's corners).
function Te.GroundZLot(lot, x, y)
    local t = lot.terrain
    if not (t and t.h and next(t.h)) then return 0 end
    local i, j = math.floor(x), math.floor(y)
    if i < 0 then i = 0 elseif i >= lot.w then i = lot.w - 1 end
    if j < 0 then j = 0 elseif j >= lot.h then j = lot.h - 1 end
    local fx, fy = x - i, y - j
    if fx < 0 then fx = 0 elseif fx > 1 then fx = 1 end
    if fy < 0 then fy = 0 elseif fy > 1 then fy = 1 end
    local a, b, c, d = Te.CellCorners(lot, i, j)
    local top = a + (b - a) * fx
    local bottom = d + (c - d) * fx
    return (top + (bottom - top) * fy) * Te.STEP
end
function W.GroundZ(world, x, y) return Te.GroundZLot(world.lot, x, y) end

-- Corner pattern for a terrain tile: offsets (0/1) above the cell's lowest corner in world order
-- {nw, ne, se, sw}, the base height in steps, and the fold diagonal for 1- or 3-raised cells.
function Te.TilePattern(lot, i, j)
    local a, b, c, d = Te.CellCorners(lot, i, j)
    local base = math.min(a, b, c, d)
    local o = { a - base, b - base, c - base, d - base }
    local n = o[1] + o[2] + o[3] + o[4]
    local fold
    if n == 1 or n == 3 then
        local odd = (n == 1) and 1 or 0
        fold = (o[1] == odd or o[3] == odd) and "nwse" or "nesw"
    elseif n == 2 and o[1] == o[3] then
        fold = (o[1] == 1) and "nwse" or "nesw"
    end
    return o, base, fold
end

-- Outdoor steps fit a cell sloping by one step straight along the steps' facing axis.
function Te.StepsFit(lot, i, j, f)
    local nw, ne, se, sw = Te.CellCorners(lot, i, j)
    f = (f or 0) % 4
    if f == 0 or f == 2 then          -- facing +y / -y: north edge level, south edge level, differ
        return nw == ne and sw == se and nw ~= sw
    end
    return nw == sw and ne == se and nw ~= ne   -- facing -x / +x
end

-- Ground paint id at a cell ("grass" when never painted).
function Te.Paint(lot, i, j)
    local t = lot.terrain
    local p = t and t.paint and t.paint[j * lot.w + i + 1]
    return p or "grass"
end

---------------------------------------------------------------------------------------------------
-- Locks: corners that structures hold in place. Returns locked[cornerIdx] = reason.
---------------------------------------------------------------------------------------------------
local function objName(lot, oid)
    local o = lot.objects[oid]
    local def = o and SS.Objects[o.def]
    return def and def.name or "furniture"
end

function Te.Locks(lot, scan)
    scan = scan or B.Scan(lot)
    local locked = {}
    local W1 = lot.w + 1
    local function lockCell(i, j, why)
        for _, c in ipairs({ { i, j }, { i + 1, j }, { i + 1, j + 1 }, { i, j + 1 } }) do
            local k = c[2] * W1 + c[1] + 1
            locked[k] = locked[k] or why
        end
    end
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do
            local k = j * lot.w + i + 1
            local why
            local f0 = lot.floor[0][k]
            if f0 ~= nil and not B.IsGround(f0) then why = "the floor there"
            elseif lot.floor[1] and lot.floor[1][k] then why = "the upstairs floor above it"
            elseif scan.any[0][k] then why = "the " .. objName(lot, scan.any[0][k])
            elseif lot.pool[k] then why = "the pool"
            elseif lot.terrain.water[k] then why = "the pond"
            elseif lot.diag[0][k] then why = "a diagonal wall" end
            if why then lockCell(i, j, why) end
        end
    end
    for key, wl in pairs(lot.walls[0]) do
        local x0, y0, x1, y1 = B.EdgeCorners(key)
        local why = (wl.kind == "fence" or wl.kind == "gate") and "a fence" or (wl.kind == "railing" and "a railing") or "a wall"
        local k0, k1 = y0 * W1 + x0 + 1, y1 * W1 + x1 + 1
        locked[k0] = locked[k0] or why
        locked[k1] = locked[k1] or why
    end
    return locked
end

---------------------------------------------------------------------------------------------------
-- Height edits. `want` maps cornerIdx -> target height; neighbours are pushed along (8-neighbour,
-- at most one step apart) until the bound holds. Returns changed map or nil, reason.
---------------------------------------------------------------------------------------------------
local function settle(lot, want, locks, base)
    local W1, H1 = lot.w + 1, lot.h + 1
    local new = {}
    local queue = {}
    local keys = {}
    for k in pairs(want) do keys[#keys + 1] = k end
    table.sort(keys)
    local function cur(k)
        if new[k] ~= nil then return new[k] end
        if base and base[k] ~= nil then return base[k] end
        return lot.terrain.h[k] or 0
    end
    for _, k in ipairs(keys) do
        local v = want[k]
        if v > Te.MAX or v < Te.MIN then return nil, "The ground can't go any " .. (v > Te.MAX and "higher" or "lower") .. " here." end
        if v ~= cur(k) then
            if locks[k] then return nil, "Can't reshape the ground under " .. locks[k] .. "." end
            new[k] = v
        end
        queue[#queue + 1] = k
    end
    local head, guard = 1, 0
    while head <= #queue do
        local k = queue[head]; head = head + 1
        guard = guard + 1
        if guard > W1 * H1 * 16 then return nil, "That edit is too large." end
        local n = k - 1
        local ci, cj = n % W1, math.floor(n / W1)
        local hk = cur(k)
        for dj = -1, 1 do
            for di = -1, 1 do
                if di ~= 0 or dj ~= 0 then
                    local ni, nj = ci + di, cj + dj
                    if ni >= 0 and nj >= 0 and ni < W1 and nj < H1 then
                        local nk = nj * W1 + ni + 1
                        local hn = cur(nk)
                        local target
                        if hn > hk + 1 then target = hk + 1 elseif hn < hk - 1 then target = hk - 1 end
                        if target then
                            if locks[nk] then return nil, "Can't reshape the ground next to " .. locks[nk] .. ": it would have to move too." end
                            new[nk] = target
                            queue[#queue + 1] = nk
                        end
                    end
                end
            end
        end
    end
    return new
end
Te.Settle = settle

local function addHeightChanges(plan, lot, new)
    local keys = {}
    for k in pairs(new) do keys[#keys + 1] = k end
    table.sort(keys)
    local W1 = lot.w + 1
    for _, k in ipairs(keys) do
        local old = lot.terrain.h[k] or 0
        local v = new[k]
        if v ~= old then
            B.Add(plan, { t = "h", idx = k, old = old, new = v }, Te.T.stepPrice * math.abs(v - old))
            plan.count = plan.count + 1
            local n = k - 1
            plan.preview.corners[#plan.preview.corners + 1] = { i = n % W1, j = math.floor(n / W1), h = v, old = old }
        end
    end
end

-- Raise (dir = 1) or lower (dir = -1) the corners around corner (x, y) by one step.
-- args: { x, y, dir, brush = 0..Te.T.maxBrush }
function Te.PlanRaise(world, args)
    local lot = B.EnsureLot(world.lot)
    local dir = (args.dir or 1) >= 0 and 1 or -1
    local plan = B.NewPlan(world, "terrain", dir > 0 and "Raise ground" or "Lower ground")
    local x, y = args.x, args.y
    if not x or x < 0 or y < 0 or x > lot.w or y > lot.h then return B.Fail(plan, "Point at the ground inside the lot.") end
    local r = math.max(0, math.min(Te.T.maxBrush, args.brush or 0))
    local scan = B.Scan(lot)
    local locks = Te.Locks(lot, scan)
    local want = {}
    local W1 = lot.w + 1
    -- the brush lifts its whole square to one level above its current highest point (or one below
    -- its lowest), so repeated clicks build a plateau instead of spikes
    local top, bottom = -1e9, 1e9
    for j = y - r, y + r do
        for i = x - r, x + r do
            if i >= 0 and j >= 0 and i <= lot.w and j <= lot.h then
                local h = CH(lot, i, j)
                if h > top then top = h end
                if h < bottom then bottom = h end
            end
        end
    end
    local target = dir > 0 and (r == 0 and CH(lot, x, y) + 1 or top + (top == bottom and 1 or 0)) or (r == 0 and CH(lot, x, y) - 1 or bottom - (top == bottom and 1 or 0))
    if target > Te.MAX then return B.Fail(plan, "The ground is already as high as it goes (" .. (Te.MAX * Te.STEP) .. " tiles).") end
    if target < Te.MIN then return B.Fail(plan, "The ground is already as low as it goes (" .. (Te.MIN * Te.STEP) .. " tiles).") end
    for j = y - r, y + r do
        for i = x - r, x + r do
            if i >= 0 and j >= 0 and i <= lot.w and j <= lot.h then
                local k = j * W1 + i + 1
                local h = CH(lot, i, j)
                if (dir > 0 and h < target) or (dir < 0 and h > target) then want[k] = target end
            end
        end
    end
    if not next(want) then want[y * W1 + x + 1] = CH(lot, x, y) + dir end
    local new, why = settle(lot, want, locks)
    if not new then return B.Fail(plan, why) end
    addHeightChanges(plan, lot, new)
    if plan.ok and plan.count == 0 then B.Fail(plan, "Nothing would change.") end
    plan.label = string.format("%s ground (%d corner%s)", dir > 0 and "Raise" or "Lower", plan.count, plan.count == 1 and "" or "s")
    return B.Finalize(world, plan)
end

-- Flatten the cells of a rectangle to one height (default: the height of its first corner).
-- args: { rect = {i0, j0, i1, j1}, height = steps?, skipLocked = bool (level the rest) }
function Te.PlanFlatten(world, args)
    local lot = B.EnsureLot(world.lot)
    local plan = B.NewPlan(world, "terrain", "Flatten ground")
    local r = args.rect
    if not r then return B.Fail(plan, "Drag over the ground to flatten.") end
    local i0, i1 = math.max(0, math.min(r[1], r[3])), math.min(lot.w - 1, math.max(r[1], r[3]))
    local j0, j1 = math.max(0, math.min(r[2], r[4])), math.min(lot.h - 1, math.max(r[2], r[4]))
    if i1 < i0 or j1 < j0 then return B.Fail(plan, "Drag over the ground inside the lot.") end
    if (i1 - i0 + 2) * (j1 - j0 + 2) > Te.T.maxFlatten then return B.Fail(plan, "That area is too large to flatten in one go.") end
    local target = args.height
    if target == nil then target = CH(lot, r[1] >= 0 and r[1] or 0, r[2] >= 0 and r[2] or 0) end
    target = math.max(Te.MIN, math.min(Te.MAX, target))
    local scan = B.Scan(lot)
    local locks = Te.Locks(lot, scan)
    local want = {}
    local W1 = lot.w + 1
    for j = j0, j1 + 1 do
        for i = i0, i1 + 1 do
            local k = j * W1 + i + 1
            if CH(lot, i, j) ~= target then
                if locks[k] then
                    if not args.skipLocked then return B.Fail(plan, "Can't flatten under " .. locks[k] .. ".") end
                else
                    want[k] = target
                end
            end
            plan.preview.corners[#plan.preview.corners + 1] = { i = i, j = j, h = target, area = true }
        end
    end
    for j = j0, j1 do
        for i = i0, i1 do plan.preview.cells[#plan.preview.cells + 1] = { i = i, j = j, level = 0 } end
    end
    local new, why
    if args.skipLocked then
        -- level what can be levelled, one corner at a time; a corner whose change would have to move
        -- a locked one keeps its height (it becomes part of the slope around the structure)
        new = {}
        local keys = {}
        for k in pairs(want) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local res = settle(lot, { [k] = want[k] }, locks, new)
            if res then for kk, vv in pairs(res) do new[kk] = vv end end
        end
    else
        new, why = settle(lot, want, locks)
        if not new then return B.Fail(plan, why) end
    end
    local preview = plan.preview.corners
    plan.preview.corners = {}
    addHeightChanges(plan, lot, new)
    for _, c in ipairs(preview) do plan.preview.corners[#plan.preview.corners + 1] = c end
    if plan.ok and plan.count == 0 then B.Fail(plan, "That ground is already level.") end
    plan.label = string.format("Flatten ground (%d corner%s)", plan.count, plan.count == 1 and "" or "s")
    return B.Finalize(world, plan)
end

---------------------------------------------------------------------------------------------------
-- Ground paint (grass, dirt, stone, sand)
---------------------------------------------------------------------------------------------------
local function cellsOf(lot, args)
    if args.rect then
        local r = args.rect
        return B.RectCells(lot, r[1], r[2], r[3], r[4])
    end
    return args.cells or {}
end

-- args: { paint, cells = {{i,j}...} | rect = {i0,j0,i1,j1} }
function Te.PlanPaint(world, args)
    local lot = B.EnsureLot(world.lot)
    local item = B.Item("terrain", args.paint)
    local plan = B.NewPlan(world, "paint_ground", "Paint ground")
    if not item then return B.Fail(plan, "Pick a ground paint first.") end
    local cells = cellsOf(lot, args)
    if #cells == 0 then return B.Fail(plan, "Drag over the ground to paint it.") end
    if #cells > B.T.maxCells then return B.Fail(plan, "That area is too large (limit " .. B.T.maxCells .. " tiles).") end
    local skipped = 0
    for _, c in ipairs(cells) do
        local i, j = c[1], c[2]
        local k = j * lot.w + i + 1
        local bad
        if not (i >= 0 and j >= 0 and i < lot.w and j < lot.h) then bad = true
        elseif lot.pool[k] or lot.terrain.water[k] then bad = true
        elseif not B.IsGround(lot.floor[0][k]) then bad = true end
        plan.preview.cells[#plan.preview.cells + 1] = { i = i, j = j, level = 0, bad = bad or nil }
        if bad then skipped = skipped + 1
        else
            local old = lot.terrain.paint[k]
            local new = (item.id ~= "grass") and item.id or nil
            if old ~= new then
                local oldItem = B.Item("terrain", old or "grass")
                B.Add(plan, { t = "paint", idx = k, old = old, new = new }, item.price - B.Refund(oldItem and oldItem.price or 0))
                plan.count = plan.count + 1
            end
        end
    end
    if plan.count == 0 then
        return B.Fail(plan, skipped > 0 and "Ground paint goes on open ground (not floors, pools or ponds)." or "That ground already has that paint.")
    end
    if skipped > 0 then plan.notes[#plan.notes + 1] = skipped .. " tile(s) with floors or water skipped" end
    plan.label = string.format("Paint %d tile%s %s", plan.count, plan.count == 1 and "" or "s", item.name)
    return B.Finalize(world, plan)
end

---------------------------------------------------------------------------------------------------
-- Ponds (decorative water; nobody walks or swims in them)
---------------------------------------------------------------------------------------------------
-- args: { style, cells | rect, remove = bool }
function Te.PlanPond(world, args)
    local lot = B.EnsureLot(world.lot)
    local plan = B.NewPlan(world, "pond", args.remove and "Fill in pond" or "Dig pond")
    local style = Te.POND[args.style or ""] or (not args.remove and Te.PONDS[1]) or nil
    local cells = cellsOf(lot, args)
    if #cells == 0 then return B.Fail(plan, "Drag over the ground.") end
    if #cells > B.T.maxCells then return B.Fail(plan, "That area is too large.") end
    local scan = B.Scan(lot)
    for _, c in ipairs(cells) do
        local i, j = c[1], c[2]
        local bad
        local k = (i >= 0 and j >= 0 and i < lot.w and j < lot.h) and (j * lot.w + i + 1)
        if not k then bad = "That is outside the lot."
        elseif args.remove then
            if lot.terrain.water[k] then
                local old = Te.POND[lot.terrain.water[k]] or Te.PONDS[1]
                B.Add(plan, { t = "water", idx = k, old = lot.terrain.water[k], new = nil }, -B.Refund(old.price))
                plan.count = plan.count + 1
            end
        else
            if lot.terrain.water[k] == style.id then bad = nil
            elseif lot.pool[k] then bad = "That is the swimming pool."
            elseif not B.IsGround(lot.floor[0][k]) then bad = "Ponds go in open ground, not on floors."
            elseif lot.floor[1][k] then bad = "Not under the upstairs floor."
            elseif scan.any[0][k] then bad = "The " .. objName(lot, scan.any[0][k]) .. " is in the way."
            elseif lot.diag[0][k] then bad = "A diagonal wall runs through that tile."
            elseif not Te.FlatLot(lot, i, j) then bad = "Water needs level ground: flatten it first."
            elseif lot.entry and lot.entry[1] == i and lot.entry[2] == j then bad = "Keep the lot entrance clear."
            else
                local who = B.ActorAt(world, 0, i, j)
                if who then bad = who.name .. " is standing there." end
            end
            if not bad and lot.terrain.water[k] ~= style.id then
                local old = lot.terrain.water[k] and (Te.POND[lot.terrain.water[k]] or Te.PONDS[1])
                B.Add(plan, { t = "water", idx = k, old = lot.terrain.water[k], new = style.id }, style.price - (old and B.Refund(old.price) or 0))
                plan.count = plan.count + 1
            end
        end
        plan.preview.cells[#plan.preview.cells + 1] = { i = i, j = j, level = 0, bad = bad and true or nil, erase = args.remove or nil }
        if bad then B.Fail(plan, bad) end
    end
    if plan.ok and plan.count == 0 then B.Fail(plan, args.remove and "There is no pond there." or "That is already a pond.") end
    plan.label = args.remove and string.format("Fill in %d pond tile%s", plan.count, plan.count == 1 and "" or "s")
        or string.format("Dig %d tile%s of %s", plan.count, plan.count == 1 and "" or "s", style.name)
    return B.Finalize(world, plan)
end

---------------------------------------------------------------------------------------------------
-- Derived data and navigation: ponds are solid; slopes cost a little extra (steps cancel it).
---------------------------------------------------------------------------------------------------
B.RegisterDerived(function(world, rt, bt, scan)
    local lot = bt.lot
    local sloped, steps, any = {}, {}, false
    for id, o in pairs(lot.objects) do
        local def = SS.Objects[o.def]
        if def and def.steps and (o.level or 0) == 0 and o.x >= 0 and o.y >= 0 and o.x < lot.w and o.y < lot.h then steps[o.y * lot.w + o.x + 1] = id end
    end
    if next(lot.terrain.h) then
        for j = 0, lot.h - 1 do
            for i = 0, lot.w - 1 do
                if not Te.FlatLot(lot, i, j) then
                    local k = j * lot.w + i + 1
                    if not steps[k] then sloped[k] = true; any = true end
                end
            end
        end
    end
    bt.sloped, bt.anySloped, bt.steps = sloped, any, steps
    for k in pairs(lot.terrain.water) do B.MarkSolid(bt, 0, k) end
end)

W.RegisterCostHook(function(world, level, i, j)
    if level ~= 0 then return 0 end
    local bt = B.rt
    if not bt or not bt.anySloped or bt.lot ~= world.lot then return 0 end
    if bt.sloped[j * world.lot.w + i + 1] then return Te.T.slopeCost end
    return 0
end)

---------------------------------------------------------------------------------------------------
-- Save validation: heights are integers within bounds and every cell's corners within one step
-- (a too-high corner is lowered until the bound holds); unknown paints and ponds are dropped.
---------------------------------------------------------------------------------------------------
function Te.Repair(lot)
    B.EnsureLot(lot)
    local h = lot.terrain.h
    local W1, H1 = lot.w + 1, lot.h + 1
    local fixed = 0
    for k, v in pairs(h) do
        if type(k) ~= "number" or k < 1 or k > W1 * H1 or type(v) ~= "number" then h[k] = nil; fixed = fixed + 1
        else
            local nv = math.max(Te.MIN, math.min(Te.MAX, round(v)))
            if nv ~= v then fixed = fixed + 1 end
            h[k] = (nv ~= 0) and nv or nil
        end
    end
    -- lowering-only relaxation over every corner: a corner more than one step above any neighbour
    -- drops to one above it; heights only fall and are bounded below, so this terminates
    for _ = 1, 64 do
        local changed = false
        for k = 1, W1 * H1 do
            local v = h[k] or 0
            local n = k - 1
            local ci, cj = n % W1, math.floor(n / W1)
            local lo = 1e9
            for dj = -1, 1 do
                for di = -1, 1 do
                    local ni, nj = ci + di, cj + dj
                    if (di ~= 0 or dj ~= 0) and ni >= 0 and nj >= 0 and ni < W1 and nj < H1 then
                        local hv = h[nj * W1 + ni + 1] or 0
                        if hv < lo then lo = hv end
                    end
                end
            end
            if v > lo + 1 then
                h[k] = (lo + 1 ~= 0) and (lo + 1) or nil
                changed = true
                fixed = fixed + 1
            end
        end
        if not changed then break end
    end
    for k, p in pairs(lot.terrain.paint) do
        if type(k) ~= "number" or type(p) ~= "string" then lot.terrain.paint[k] = nil; fixed = fixed + 1 end
    end
    for k, p in pairs(lot.terrain.water) do
        if type(k) ~= "number" or k < 1 or k > lot.w * lot.h or type(p) ~= "string" then lot.terrain.water[k] = nil; fixed = fixed + 1
        elseif not Te.POND[p] then lot.terrain.water[k] = Te.PONDS[1].id end
    end
    return fixed
end

SS.Save.RegisterValidator(function(root, problems)
    for lotId, lot in pairs(root.hood and root.hood.lots or {}) do
        local n = Te.Repair(lot)
        if n > 0 then problems[#problems + 1] = "repaired " .. n .. " terrain value(s) on " .. tostring(lotId) end
    end
    return true
end)
