-- Swimming pools: footprint tool, coping/edge data and styles, ladders (system build objects),
-- swimming (interaction, water-only routing, entry/exit through ladders), fun/body/energy effects,
-- and the exhaustion/drowning pathway with warnings and a forecast.
-- Owner: build module (see ARCHITECTURE.md §5, docs/modules/build.md "Pools").
--
-- Data: lot.pool[idx] = { depth = tiles, style = styleId } on level 0.
-- Navigation (pass hook on level 0):
--   * water -> water steps are for swimmers only (someone in the water, or someone whose current
--     action is a swim); everybody else walks round the pool;
--   * land <-> water steps happen only across a ladder edge (the edge between a ladder's cell and
--     the water tile in front of it), again only for swimmers. No ladder, no way in or out.
-- Exhaustion pathway (documented in docs/modules/build.md):
--   energy drains faster in the water (P.T.drainPerHour on top of normal decay);
--   below P.T.warnAt the swimmer is "getting tired" (message);
--   below P.T.dangerAt they head for a reachable ladder on their own (even without free will), or,
--     if no ladder is reachable, an emergency warning drops the game to normal speed;
--   a swimmer with no reachable ladder gets an emergency warning as soon as they are trapped;
--   at P.T.drownAt with no reachable ladder, SS.Death.Kill(world, actor, "drowning");
--   with a reachable ladder they cling on (energy held just above the limit) until they climb out.
-- Removing a ladder while someone swims is forecast in the delete preview (P.LadderRemovalWarning)
-- and asks for confirmation in the build UI.
local _, SS = ...
local G, W, B = SS.Grid, SS.World, SS.Build
local P = {}
SS.Pool = P

P.T = {
    depth = 1.5,          -- tiles (visual; everyone swims, nobody touches the bottom)
    drainPerHour = 45,    -- extra energy lost per sim hour in the water
    startMin = -10,       -- energy needed to start a swim
    stopAt = -15,         -- a swim ends by itself below this energy
    warnAt = 0,           -- "getting tired in the pool"
    dangerAt = -40,       -- head for the ladder now / emergency if there is none
    drownAt = -95,        -- energy exhausted in the water
    swimSpeed = 1.2,      -- tiles per sim minute while swimming laps
    idleExit = 20,        -- sim minutes idle in the water before a free-willed swimmer climbs out
    waterCost = 1.0,      -- extra route cost per water tile (swimmers prefer short swims)
    floatSpeed = 0.35,    -- tiles per sim minute while floating (a slow drift)
    floatDrain = 0.4,     -- share of drainPerHour while floating instead of swimming laps
    maxCells = 200,
}

P.STYLES = {
    { id = "pool_classic", name = "Classic Blue Tile", price = 60, coping = "white_stone", water = { 0.36, 0.68, 0.88 },
      desc = "Bright blue tiles and a white stone edge. Smells faintly of summer and chlorine." },
    { id = "pool_lagoon", name = "Lagoon Pebble", price = 80, coping = "sandstone", water = { 0.30, 0.76, 0.72 },
      desc = "A pebbled green-blue basin with sandstone coping, for a holiday that never leaves the garden." },
    { id = "pool_midnight", name = "Midnight Slate", price = 110, coping = "slate", water = { 0.17, 0.33, 0.52 },
      desc = "Dark slate tiles that make the water look deep, serious and very expensive." },
}
P.STYLE = {}
for _, s in ipairs(P.STYLES) do P.STYLE[s.id] = s end

-- Ladder: a system build object (not in buy mode). It stands on the land tile at the pool's edge
-- and faces the water tile in front of it (+y in its local frame).
P.LADDER = "pool_ladder"
if not SS.Objects[P.LADDER] then
    local slots = {}
    for n = 1, 4 do slots["swim" .. n] = { approaches = { { 0, 1 } }, face = 0, group = "swim" } end
    SS.Objects[P.LADDER] = { name = "Chrome Pool Ladder", cat = "build_pool", buyable = false, price = 150, poolLadder = true,
        noBlock = true, fp = { { 0, 0 } }, env = 0, tags = {}, ratings = {}, slots = slots, actions = { "swim", "pool_float" },
        desc = "The only dignified way into the pool, and the only way out. Place it on the edge facing the water.",
        art = { model = "design/build/pool.json#ladder" } }
end
do  -- a ladder defined elsewhere still offers both pool interactions
    local d = SS.Objects[P.LADDER]
    d.actions = d.actions or {}
    for _, iid in ipairs({ "swim", "pool_float" }) do
        local has = false
        for _, x in ipairs(d.actions) do if x == iid then has = true end end
        if not has then d.actions[#d.actions + 1] = iid end
    end
end
function P.IsLadderDef(defId)
    local d = SS.Objects[defId]
    return d ~= nil and d.poolLadder == true
end

local function inLot(lot, i, j) return i >= 0 and j >= 0 and i < lot.w and j < lot.h end
local function cellOf(lot, k) k = k - 1; return k % lot.w, math.floor(k / lot.w) end

-- Land cell and water cell of a ladder object.
function P.LadderCells(o)
    local dx, dy = G.rot(0, 1, o.f or 0)
    return o.x, o.y, o.x + dx, o.y + dy
end

---------------------------------------------------------------------------------------------------
-- Derived data (after every rebuild): water cells, components, ladders and their edges
---------------------------------------------------------------------------------------------------
P.rt = nil
local function derive(lot, blockedFn)
    local pt = { lot = lot, water = {}, any = false, comp = {}, compLadders = {}, ladderEdge = {}, ladders = {}, ladderAt = {} }
    for k in pairs(lot.pool or {}) do pt.water[k] = true; pt.any = true end
    -- components (4-neighbour water, no wall between)
    local keys = {}
    for k in pairs(pt.water) do keys[#keys + 1] = k end
    table.sort(keys)
    local nComp = 0
    local walls = lot.walls and lot.walls[0] or {}
    for _, k0 in ipairs(keys) do
        if not pt.comp[k0] then
            nComp = nComp + 1
            pt.comp[k0] = nComp
            pt.compLadders[nComp] = 0
            local stack = { k0 }
            while #stack > 0 do
                local k = table.remove(stack)
                local i, j = cellOf(lot, k)
                for d = 0, 3 do
                    local v = G.DIRS[d]
                    local ni, nj = i + v[1], j + v[2]
                    if inLot(lot, ni, nj) then
                        local nk = nj * lot.w + ni + 1
                        if pt.water[nk] and not pt.comp[nk] and not walls[G.edgeBetween(i, j, ni, nj)] then
                            pt.comp[nk] = nComp
                            stack[#stack + 1] = nk
                        end
                    end
                end
            end
        end
    end
    -- ladders
    local ids = {}
    for id, o in pairs(lot.objects or {}) do if P.IsLadderDef(o.def) and (o.level or 0) == 0 then ids[#ids + 1] = id end end
    table.sort(ids)
    pt.ladderIds = ids   -- sorted once per rebuild; swimmers' per-tick checks walk this list
    for _, id in ipairs(ids) do
        local o = lot.objects[id]
        local li, lj, wi, wj = P.LadderCells(o)
        if inLot(lot, li, lj) and inLot(lot, wi, wj) then
            local wk = wj * lot.w + wi + 1
            local key = G.edgeBetween(li, lj, wi, wj)
            local lad = { id = id, land = { li, lj }, water = { wi, wj }, key = key, ok = false }
            if pt.water[wk] and not pt.water[lj * lot.w + li + 1] and not walls[key] then
                lad.ok = true
                pt.ladderEdge[key] = id
                local usable = not (blockedFn and blockedFn(li, lj))
                lad.usable = usable
                if usable then pt.compLadders[pt.comp[wk]] = pt.compLadders[pt.comp[wk]] + 1 end
            end
            pt.ladders[id] = lad
            pt.ladderAt[wk] = pt.ladderAt[wk] or {}
            table.insert(pt.ladderAt[wk], id)
        end
    end
    return pt
end
P.Derive = derive

B.RegisterDerived(function(world, rt, bt, scan)
    local lot = bt.lot
    local blocked = function(i, j)
        local k = j * lot.w + i + 1
        return (scan.occ[0][k] ~= nil) or bt.solid[0][k] == true
    end
    local pt = derive(lot, blocked)
    rt.pool = pt
    bt.pool = pt
    P.rt = pt
end)

local function current(world)
    local pt = P.rt
    if pt and pt.lot == world.lot then return pt end
    return nil
end

-- Is the actor in the water on the attached lot?
function P.InWater(world, a)
    if not a or not a.x or (a.level or 0) ~= 0 then return false end
    local pt = current(world)
    if not pt or not pt.any then return false end
    local i, j = math.floor(a.x), math.floor(a.y)
    if not inLot(world.lot, i, j) then return false end
    return pt.water[j * world.lot.w + i + 1] == true
end
function P.IsSwimming(a, world)
    world = world or (SS.Sim and SS.Sim.world)
    if not world then return false end
    return P.InWater(world, a)
end

local function canSwim(a)
    if not a then return false end
    if (a.kind or "human") ~= "human" then return false end
    if a.age == "infant" then return false end
    return true
end

-- Pool interactions (all run from a ladder's swim slots and keep the person in the water).
P.SWIM_IIDS = { swim = true, pool_float = true }

local function swimmer(world, who)
    if not canSwim(who) then return false end
    if P.InWater(world, who) then return true end
    local act = who.act
    return act ~= nil and P.SWIM_IIDS[act.iid] == true
end
P.Swimmer = swimmer

-- Navigation rules (see header).
B.RegisterStructuralPass(function(world, level, i, j, ni, nj, wall, who)
    if level ~= 0 then return end
    local pt = P.rt
    if not pt or not pt.any or pt.lot ~= world.lot then return end
    local w = world.lot.w
    local a = pt.water[j * w + i + 1]
    local b = pt.water[nj * w + ni + 1]
    if not a and not b then return end
    if a and b then
        if who and swimmer(world, who) then return end
        return false
    end
    if not pt.ladderEdge[G.edgeBetween(i, j, ni, nj)] then return false end
    if who and swimmer(world, who) then return end
    return false
end)   -- water is physical, not a rule: a structural pass (docs/requests/build.md R-WORLD-2)

W.RegisterCostHook(function(world, level, i, j)
    if level ~= 0 then return 0 end
    local pt = P.rt
    if not pt or not pt.any or pt.lot ~= world.lot then return 0 end
    if pt.water[j * world.lot.w + i + 1] then return P.T.waterCost end
    return 0
end)

-- Energy drains faster in the water.
SS.Needs.RegisterRateHook(function(world, actor, need, rate)
    if need == "energy" and P.InWater(world, actor) then
        local drain = P.T.drainPerHour
        if actor.act and actor.act.iid == "pool_float" then drain = drain * P.T.floatDrain end
        return rate - drain
    end
    return rate
end)

---------------------------------------------------------------------------------------------------
-- Queries: reachability, forecast, edge pieces
---------------------------------------------------------------------------------------------------
-- Can this swimmer reach a usable ladder? Returns ok, ladderOid (nearest by straight distance).
function P.LadderReachable(world, a, pt)
    pt = pt or current(world)
    if not pt then return false end
    local lot = world.lot
    local i, j = math.floor(a.x), math.floor(a.y)
    local comp = inLot(lot, i, j) and pt.comp[j * lot.w + i + 1]
    if not comp or (pt.compLadders[comp] or 0) <= 0 then return false end
    local best, bd
    local ids = pt.ladderIds or {}
    for n = 1, #ids do
        local id = ids[n]
        local L = pt.ladders[id]
        if L and L.ok and L.usable and pt.comp[L.water[2] * lot.w + L.water[1] + 1] == comp then
            local d = math.abs(L.water[1] + 0.5 - a.x) + math.abs(L.water[2] + 0.5 - a.y)
            if not bd or d < bd then best, bd = id, d end
        end
    end
    return best ~= nil, best
end

-- Energy change per sim hour for this actor right now (normal decay, hooks, pool drain).
function P.EnergyRate(world, a)
    local T = SS.Tuning
    local decay = (a.decay and a.decay.awake) or T.decayAwake
    local rate = decay.energy or 0
    for _, fn in ipairs(SS.Needs.rateHooks) do rate = fn(world, a, "energy", rate) end
    return rate
end

-- Forecast for a person in (or about to enter) the water.
-- Returns { inWater, energy, rate (per hour), toWarn, toDanger, toExhausted (minutes, nil if not
-- falling), ladder = bool, ladderId, trapped = bool, text }.
function P.Forecast(world, a)
    local inW = P.InWater(world, a)
    local e = a.needs and a.needs.energy or 0
    local rate = P.EnergyRate(world, a)
    if not inW then rate = rate - P.T.drainPerHour end
    local function mins(limit)
        if e <= limit then return 0 end
        if rate >= 0 then return nil end
        return (e - limit) / -rate * 60
    end
    local ok, lad = false, nil
    if inW then ok, lad = P.LadderReachable(world, a) end
    local f = { inWater = inW, energy = e, rate = rate, toWarn = mins(P.T.warnAt), toDanger = mins(P.T.dangerAt),
        toExhausted = mins(P.T.drownAt), ladder = ok, ladderId = lad, trapped = inW and not ok }
    local m = f.toExhausted and math.floor(f.toExhausted + 0.5)
    if not inW then
        f.text = m and string.format("Could swim for about %d minutes before running out of energy.", m) or "Plenty of energy for a swim."
    elseif f.trapped then
        f.text = string.format("No ladder within reach! Energy runs out in about %d minutes.", m or 0)
    else
        f.text = m and string.format("Tires out in about %d minutes; a ladder is within reach.", m) or "Swimming comfortably."
    end
    return f
end

-- Pool pieces for the renderer and previews (any lot). mask bits: 1 = water to the north (j-1),
-- 2 = east (i+1), 4 = south (j+1), 8 = west (i-1); coping runs along every side without water.
function P.PiecesForLot(lot)
    local out = { cells = {}, ladders = {} }
    local pool = lot.pool or {}
    local keys = {}
    for k in pairs(pool) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local i, j = cellOf(lot, k)
        local function has(ni, nj) return inLot(lot, ni, nj) and pool[nj * lot.w + ni + 1] ~= nil end
        local mask = (has(i, j - 1) and 1 or 0) + (has(i + 1, j) and 2 or 0) + (has(i, j + 1) and 4 or 0) + (has(i - 1, j) and 8 or 0)
        local e = pool[k]
        local st = P.STYLE[type(e) == "table" and e.style or ""] or P.STYLES[1]
        local coping = {}
        if mask % 2 == 0 then coping[#coping + 1] = "north" end
        if math.floor(mask / 2) % 2 == 0 then coping[#coping + 1] = "east" end
        if math.floor(mask / 4) % 2 == 0 then coping[#coping + 1] = "south" end
        if math.floor(mask / 8) % 2 == 0 then coping[#coping + 1] = "west" end
        local z = SS.Terrain and SS.Terrain.CellZ(lot, i, j) or 0
        out.cells[#out.cells + 1] = { i = i, j = j, mask = mask, style = st.id, water = st.water, coping = coping,
            copingStyle = st.coping, depth = type(e) == "table" and e.depth or P.T.depth, z = z }
    end
    local ids = {}
    for id, o in pairs(lot.objects or {}) do if P.IsLadderDef(o.def) then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local o = lot.objects[id]
        local li, lj, wi, wj = P.LadderCells(o)
        out.ladders[#out.ladders + 1] = { id = id, i = li, j = lj, f = o.f or 0, water = { wi, wj }, edgeKey = G.edgeBetween(li, lj, wi, wj) }
    end
    return out
end
function P.Pieces(world) return P.PiecesForLot(world.lot) end

-- Which facing puts a ladder on land cell (x, y) toward an adjacent pool tile? nil if none.
function P.LadderFacingAt(lot, x, y, prefer)
    local order = { prefer or 0, 0, 3, 2, 1 }
    for _, f in ipairs(order) do
        local dx, dy = G.rot(0, 1, f)
        local ni, nj = x + dx, y + dy
        if inLot(lot, ni, nj) and lot.pool and lot.pool[nj * lot.w + ni + 1] then return f end
    end
    return nil
end

---------------------------------------------------------------------------------------------------
-- Ladder placement rules (called from SS.Build.CheckObject)
---------------------------------------------------------------------------------------------------
function P.CheckLadder(world, defId, x, y, f, level, ignoreOid)
    local lot = B.EnsureLot(world.lot)
    local marks = { { x, y, level or 0 } }
    if (level or 0) ~= 0 then return false, "Pools are on the ground floor.", marks end
    if not inLot(lot, x, y) then return false, "That is outside the lot.", marks end
    local li, lj, wi, wj = P.LadderCells({ x = x, y = y, f = f })
    marks[2] = { wi, wj, 0 }
    local lk = lj * lot.w + li + 1
    if not inLot(lot, wi, wj) or not lot.pool[wj * lot.w + wi + 1] then
        return false, "A ladder goes on the edge of the pool, facing the water (R turns it).", marks
    end
    if lot.pool[lk] then return false, "The ladder's top has to rest on the pool's edge, not in the water.", marks end
    if lot.terrain.water[lk] then return false, "That is a pond.", marks end
    if lot.diag[0][lk] then return false, "A diagonal wall runs through that tile.", marks end
    if lot.walls[0][G.edgeBetween(li, lj, wi, wj)] then return false, "A wall or fence is in the way of the ladder.", marks end
    if SS.Terrain and not SS.Terrain.FlatLot(lot, li, lj) then return false, "The pool's edge needs level ground there.", marks end
    if SS.Terrain and SS.Terrain.CellBase(lot, li, lj) ~= SS.Terrain.CellBase(lot, wi, wj) then return false, "The edge has to be level with the water.", marks end
    local scan = B.Scan(lot)
    local occ = scan.occ[0][lk]
    if occ and occ ~= ignoreOid then
        local o = lot.objects[occ]
        return false, "The " .. ((o and SS.Objects[o.def] and SS.Objects[o.def].name) or "object") .. " is in the way.", marks
    end
    if not B.IsGround(lot.floor[0][lk]) and not B.IsOutdoorFloor(lot.floor[0][lk]) then return false, "Pool ladders go outdoors on the pool's edge.", marks end
    for oid, o in pairs(lot.objects) do
        if oid ~= ignoreOid and P.IsLadderDef(o.def) then
            local a, b2, c, d = P.LadderCells(o)
            if a == li and b2 == lj and c == wi and d == wj then return false, "There is already a ladder there.", marks end
        end
    end
    return true, nil, marks
end

-- Place a ladder (build plan; commit with SS.Build.Commit).
function P.PlanLadder(world, args) return B.PlanObject(world, { def = args.def or P.LADDER, x = args.x, y = args.y, f = args.f, level = 0 }) end

---------------------------------------------------------------------------------------------------
-- Pool footprint tool. args: { rect | cells, style, remove = bool }
---------------------------------------------------------------------------------------------------
local function swimmersIn(world, set)
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and (a.level or 0) == 0 then
            local k = math.floor(a.y) * world.lot.w + math.floor(a.x) + 1
            if set[k] then return a end
        end
    end
end

function P.PlanPool(world, args)
    local lot = B.EnsureLot(world.lot)
    local plan = B.NewPlan(world, "pool", args.remove and "Remove pool" or "Build pool")
    local style = P.STYLE[args.style or ""] or P.STYLES[1]
    local cells = args.cells
    if args.rect then local r = args.rect; cells = B.RectCells(lot, r[1], r[2], r[3], r[4]) end
    if not cells or #cells == 0 then return B.Fail(plan, "Drag out the pool on open ground.") end
    if #cells > P.T.maxCells then return B.Fail(plan, "That pool is too large (limit " .. P.T.maxCells .. " tiles).") end
    local scan = B.Scan(lot)
    local set = {}
    for _, c in ipairs(cells) do if inLot(lot, c[1], c[2]) then set[c[2] * lot.w + c[1] + 1] = true end end
    if args.remove then
        local hit = {}
        for k in pairs(set) do if lot.pool[k] then hit[k] = true end end
        local who = swimmersIn(world, hit)
        if who then return B.Fail(plan, who.name .. " is swimming there.") end
        local keys = {}
        for k in pairs(hit) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local e = lot.pool[k]
            local st = P.STYLE[type(e) == "table" and e.style or ""] or P.STYLES[1]
            B.Add(plan, { t = "pool", idx = k, old = SS.U.deepcopy(e), new = nil }, -B.Refund(st.price))
            plan.count = plan.count + 1
            local i, j = cellOf(lot, k)
            plan.preview.cells[#plan.preview.cells + 1] = { i = i, j = j, level = 0, erase = true }
        end
        -- ladders facing removed water come out too (refunded)
        local ids = {}
        for id, o in pairs(lot.objects) do if P.IsLadderDef(o.def) then ids[#ids + 1] = id end end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local o = lot.objects[id]
            local _, _, wi, wj = P.LadderCells(o)
            if inLot(lot, wi, wj) and hit[wj * lot.w + wi + 1] then
                B.Add(plan, { t = "obj", oid = id, old = SS.U.deepcopy(o), new = nil }, -B.Refund(o.paid or SS.Objects[o.def].price or 0))
                plan.notes[#plan.notes + 1] = "a ladder comes out with the water"
            end
        end
        if plan.count == 0 then return B.Fail(plan, "There is no pool there.") end
        plan.label = string.format("Remove %d pool tile%s", plan.count, plan.count == 1 and "" or "s")
        return B.Finalize(world, plan)
    end
    -- build: every tile must be free, open, level ground at the pool's height
    local baseH
    for k in pairs(lot.pool) do
        local i, j = cellOf(lot, k)
        local nb = false
        for _, c in ipairs(cells) do if math.abs(c[1] - i) + math.abs(c[2] - j) == 1 then nb = true; break end end
        if nb and SS.Terrain then baseH = SS.Terrain.CellBase(lot, i, j); break end
    end
    for _, c in ipairs(cells) do
        local i, j = c[1], c[2]
        local bad
        local k = inLot(lot, i, j) and (j * lot.w + i + 1)
        if not k then bad = "That is outside the lot."
        elseif not B.IsGround(lot.floor[0][k]) then bad = "Pools go in open ground; remove the floor first."
        elseif lot.floor[1][k] then bad = "Not under the upstairs floor."
        elseif scan.any[0][k] then
            local o = lot.objects[scan.any[0][k]]
            bad = "The " .. ((o and SS.Objects[o.def] and SS.Objects[o.def].name) or "object") .. " is in the way."
        elseif lot.terrain.water[k] then bad = "That is a pond; fill it in first."
        elseif lot.diag[0][k] then bad = "A diagonal wall runs through that tile."
        elseif lot.entry and lot.entry[1] == i and lot.entry[2] == j then bad = "Keep the lot entrance clear."
        elseif SS.Terrain and not SS.Terrain.FlatLot(lot, i, j) then bad = "Pools need level ground: flatten it first."
        elseif SS.Terrain and baseH and SS.Terrain.CellBase(lot, i, j) ~= baseH then bad = "The whole pool has to sit at one height."
        else
            for _, id in ipairs(SS.Sim.ActorIds(world)) do
                local a = world.actors[id]
                if a and (a.level or 0) == 0 and math.floor(a.x) == i and math.floor(a.y) == j then bad = a.name .. " is standing there." end
            end
        end
        if not bad and SS.Terrain then baseH = baseH or SS.Terrain.CellBase(lot, i, j) end
        -- no walls or fences across the water
        if not bad then
            for _, e in ipairs(B.CellEdges(i, j)) do
                local nk = inLot(lot, e[2], e[3]) and (e[3] * lot.w + e[2] + 1)
                if nk and (set[nk] or lot.pool[nk]) and lot.walls[0][e[1]] then bad = "A wall or fence would cross the water." end
            end
        end
        plan.preview.cells[#plan.preview.cells + 1] = { i = i, j = j, level = 0, bad = bad and true or nil }
        if bad then B.Fail(plan, bad)
        else
            local old = lot.pool[k]
            local oldSt = old and (P.STYLE[type(old) == "table" and old.style or ""] or P.STYLES[1])
            if not old or oldSt.id ~= style.id then
                B.Add(plan, { t = "pool", idx = k, old = SS.U.deepcopy(old), new = { depth = P.T.depth, style = style.id } },
                    style.price - (oldSt and B.Refund(oldSt.price) or 0))
                plan.count = plan.count + 1
            end
        end
    end
    if plan.ok and plan.count == 0 then B.Fail(plan, "That pool is already there.") end
    plan.label = string.format("Build %d pool tile%s (%s)", plan.count, plan.count == 1 and "" or "s", style.name)
    if plan.ok then
        local anyLadder = false
        for _, o in pairs(lot.objects) do if P.IsLadderDef(o.def) then anyLadder = true end end
        if not anyLadder then plan.notes[#plan.notes + 1] = "Add a ladder (Pool tab) so people can get in and out." end
    end
    return B.Finalize(world, plan)
end

---------------------------------------------------------------------------------------------------
-- Forecast of removing a ladder (used by the delete tool). Returns warning, danger or nil:
-- danger = true when someone in the water would be left with no way out (the UI asks first).
---------------------------------------------------------------------------------------------------
function P.LadderRemovalWarning(world, oid)
    local lot = world.lot
    local o = lot.objects[oid]
    if not (o and P.IsLadderDef(o.def)) then return nil end
    local saved = lot.objects[oid]
    lot.objects[oid] = nil
    local ok, pt = pcall(derive, lot, nil)
    lot.objects[oid] = saved
    if not ok then return nil end
    local trapped = {}
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and P.InWater(world, a) then
            local i, j = math.floor(a.x), math.floor(a.y)
            local comp = pt.comp[j * lot.w + i + 1]
            if comp and (pt.compLadders[comp] or 0) == 0 then trapped[#trapped + 1] = a.name end
        end
    end
    if #trapped > 0 then
        return "Danger: " .. table.concat(trapped, ", ") .. (#trapped == 1 and " is" or " are") ..
            " in the pool and would have no way out. Swimmers tire, and an exhausted swimmer with no ladder drowns.", true
    end
    local _, _, wi, wj = P.LadderCells(o)
    local comp = inLot(lot, wi, wj) and pt.comp[wj * lot.w + wi + 1]
    if comp and (pt.compLadders[comp] or 0) == 0 then
        return "Without this ladder nobody can get into or out of that pool."
    end
    return nil
end

-- Any build edit that would leave a swimmer with no way out (deleting a ladder, removing the water
-- tile in front of it, splitting the pool, a fence or wall on the ladder edge, something solid on
-- its landing, a diagonal wall through it) is a DANGER the build UI confirms first. Runs as a
-- build deriver: the plan's changes are applied to the lot while this looks.
local function trappedText(world, names, forecasts)
    local text = "Danger: " .. table.concat(names, ", ") .. (#names == 1 and " is" or " are") ..
        " in the pool and would have no way out. Swimmers tire, and an exhausted swimmer with no ladder drowns."
    local soonest
    for _, m in ipairs(forecasts) do if m and (not soonest or m < soonest) then soonest = m end end
    if soonest then text = text .. string.format(" Strength would run out in about %d minutes.", math.floor(soonest + 0.5)) end
    return text
end

function P.TrappedByPlan(world, plan, scan, lot)
    local pt0 = current(world)
    if not (pt0 and pt0.any) then return nil end
    local who
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and not a.dead and P.InWater(world, a) and P.LadderReachable(world, a, pt0) then
            who = who or {}
            who[#who + 1] = a
        end
    end
    if not who then return nil end
    local occ, diag, pond = scan.occ[0], lot.diag[0] or {}, lot.terrain and lot.terrain.water or {}
    local pt1 = derive(lot, function(i, j)
        local k = j * lot.w + i + 1
        return occ[k] ~= nil or diag[k] ~= nil or pond[k] ~= nil
    end)
    local names, mins = {}, {}
    for _, a in ipairs(who) do
        local i, j = math.floor(a.x), math.floor(a.y)
        local k = j * lot.w + i + 1
        local comp = pt1.water[k] and pt1.comp[k]
        if comp and (pt1.compLadders[comp] or 0) == 0 then
            names[#names + 1] = a.name or a.id
            local f = P.Forecast(world, a)
            mins[#mins + 1] = f.toExhausted
        end
    end
    if #names == 0 then return nil end
    return trappedText(world, names, mins), names
end

B.RegisterDeriver(function(world, plan, scan, lot)
    local text, names = P.TrappedByPlan(world, plan, scan, lot)
    if not text then return end
    B.Warn(plan, text)
    plan.poolTrapped = names
    plan.danger = plan.danger and (plan.danger .. "\n" .. text) or text
end)

---------------------------------------------------------------------------------------------------
-- Swimming
---------------------------------------------------------------------------------------------------
local function waterAt(world, i, j)
    local pt = current(world)
    return pt and inLot(world.lot, i, j) and pt.water[j * world.lot.w + i + 1] == true
end

-- Swim laps: head for a neighbouring water tile, keep going straight when possible. The target
-- is two numbers in a.tmp (swimTo, swimToY) and the direction list is a module scratch table, so
-- a swimmer allocates nothing per tick or per tile.
local DIRS_SCRATCH = {}
local function swimMove(world, a, dt, speed)
    local t = a.tmp
    local i, j = math.floor(a.x), math.floor(a.y)
    local tx, ty = t.swimTo, t.swimToY
    if not tx or not ty or (math.abs(a.x - tx) < 0.05 and math.abs(a.y - ty) < 0.05) then
        local dirs, nd = DIRS_SCRATCH, 0
        local keep = t.swimDir
        local walls = world.lot.walls[0]
        for d = 0, 3 do
            local v = G.DIRS[d]
            local ni, nj = i + v[1], j + v[2]
            if waterAt(world, ni, nj) and not walls[G.edgeBetween(i, j, ni, nj)] then nd = nd + 1; dirs[nd] = d end
        end
        local pick
        for n = 1, nd do if dirs[n] == keep then pick = keep end end
        if not pick or SS.Random(world, "pool") < 0.2 then
            if nd > 0 then pick = dirs[SS.RandomInt(world, "pool", 1, nd)] end
        end
        if pick then
            local v = G.DIRS[pick]
            t.swimDir = pick
            tx, ty = i + v[1] + 0.5, j + v[2] + 0.5
        else
            tx, ty = i + 0.5, j + 0.5
        end
        t.swimTo, t.swimToY = tx, ty
    end
    local dx, dy = tx - a.x, ty - a.y
    local d = math.sqrt(dx * dx + dy * dy)
    local step = (speed or P.T.swimSpeed) * dt
    if d > 1e-6 then a.facing = G.dirToFacing(dx, dy) end
    if d <= step then a.x, a.y = tx, ty else a.x, a.y = a.x + dx / d * step, a.y + dy / d * step end
end
P.SwimMove = swimMove

local function poolTest(world, actor, obj)
    if not canSwim(actor) then return false, (actor.age == "infant") and "Babies stay out of the pool." or "Only people swim here." end
    if (actor.needs and actor.needs.energy or 0) < P.T.startMin then return false, "Too tired to swim safely." end
    if (actor.level or 0) ~= 0 then return false, "The pool is downstairs." end
    if obj and P.IsLadderDef(obj.def) then
        local pt = current(world)
        local L = pt and pt.ladders[obj.id]
        if not (L and L.ok) then return false, "This ladder isn't at the pool's edge." end
    end
    return true
end
-- Where a swimmer is in the water survives a save: the spot goes into act.data (which the
-- executor saves with the action). When household-core resumes a performing action after a load
-- it puts the person on the slot's approach tile (the ladder's water tile); the first tick puts
-- them back where they were, once per resumed action, and only onto water.
local function resumeSpot(world, actor, act)
    local d = act.data
    if not d then return end
    local t = actor.tmp
    if act.resumed and t.swimResumed ~= act then
        t.swimResumed = act
        local sx, sy = tonumber(d.swimX), tonumber(d.swimY)
        if sx and sy and waterAt(world, math.floor(sx), math.floor(sy)) then
            actor.x, actor.y = sx, sy
            t.swimTo, t.swimDir = nil, nil
        end
    end
end
local function noteSpot(actor, act)
    local d = act.data
    if d then d.swimX, d.swimY = actor.x, actor.y end
end
P.ResumeSpot = resumeSpot

local function poolStart(world, actor, act)
    if not P.InWater(world, actor) then return false, "Couldn't get into the pool." end
    actor.tmp = actor.tmp or {}
    actor.tmp.swimTo, actor.tmp.swimDir = nil, nil
    return true
end
local function poolEnd(world, actor, act, obj, status)
    act.keepOutfit = true   -- the pool system changes clothes when the swimmer leaves the water
    if P.InWater(world, actor) then actor.pose = "swim" end
end

-- Swim laps: fun, hygiene and body skill, the full energy drain.
SS.Interactions.swim = {
    label = "Go Swimming", category = "Fun", pose = "swim", slot = "swim",
    rate = { fun = 28, hygiene = 6 }, maxDur = 90, advert = { fun = 30 },
    wakeOn = { energy = P.T.stopAt },
    ages = { adult = true, child = true }, kinds = { human = true }, exertion = 1, leisure = true,
    test = poolTest, onStart = poolStart, onEnd = poolEnd,
    onTick = function(world, actor, act, obj, dt)
        if not P.InWater(world, actor) then act.complete = true; return end
        actor.tmp = actor.tmp or {}
        resumeSpot(world, actor, act)
        swimMove(world, actor, dt)
        noteSpot(actor, act)
        act.pose = "swim"
        if SS.Skills and SS.Skills.Gain then SS.Skills.Gain(world, actor, "body", 1.2 * dt / 60) end
    end,
}

-- Float and relax: gentler fun plus comfort, a slow drift, no skill, a smaller energy drain
-- (P.T.floatDrain). Still subject to the whole exhaustion pathway.
SS.Interactions.pool_float = {
    label = "Float and Relax", category = "Fun", pose = "swim", slot = "swim",
    rate = { fun = 16, comfort = 14, hygiene = 3 }, maxDur = 60, advert = { fun = 18, comfort = 12 },
    wakeOn = { energy = P.T.stopAt },
    ages = { adult = true, child = true }, kinds = { human = true }, exertion = 0.3, leisure = true,
    test = poolTest, onStart = poolStart, onEnd = poolEnd,
    onTick = function(world, actor, act, obj, dt)
        if not P.InWater(world, actor) then act.complete = true; return end
        actor.tmp = actor.tmp or {}
        resumeSpot(world, actor, act)
        swimMove(world, actor, dt, P.T.floatSpeed)
        noteSpot(actor, act)
        act.pose = "swim"
    end,
}

---------------------------------------------------------------------------------------------------
-- Pool system: clothes, pose, idle swimmers, and the exhaustion/drowning pathway
---------------------------------------------------------------------------------------------------
local function exitOrder(world, a, ladderId)
    local pt = current(world)
    local L = pt and pt.ladders[ladderId]
    if not L then return false end
    a.tmp.poolExit = world.time
    return SS.Actions.Order(world, a, nil, "goto", L.land[1], L.land[2], { level = 0 })
end

local function heading(a)
    local act = a.act
    return act and act.iid == "goto"
end

-- The tick's actor order (sorted ids), rebuilt only when the actor set changes, so the pool
-- system allocates nothing per sim step.
local order, orderN, orderWorld = {}, 0, nil
local function tickOrder(world)
    local n = 0
    for _ in pairs(world.actors) do n = n + 1 end
    if orderWorld == world and orderN == n then
        local same = true
        for k = 1, n do if not world.actors[order[k]] then same = false; break end end
        if same then return order end
    end
    local ids = SS.Sim.ActorIds(world)
    for k = #order, 1, -1 do order[k] = nil end
    for k = 1, #ids do order[k] = ids[k] end
    orderN, orderWorld = #ids, world
    return order
end

function P.Tick(world, dt)
    local pt = current(world)
    local ids = tickOrder(world)
    for _, id in ipairs(ids) do
        local a = world.actors[id]
        if a and not a.dead then
            local inW = pt and pt.any and P.InWater(world, a)
            a.tmp = a.tmp or {}
            local st = a.tmp
            if inW then
                -- swimwear on, swim pose when not walking
                if a.outfit ~= "swim" then st.dryOutfit = a.outfit or "everyday"; a.outfit = "swim" end
                st.swimOutfit = true
                a.swimming = true   -- renderer: draw the swim pose even while moving through water
                if not a.act or a.act.phase ~= "route" then a.pose = "swim" end
                if not a.act and not (a.queue and #a.queue > 0) then
                    st.idleSince = st.idleSince or world.time
                else
                    st.idleSince = nil
                end
                local energy = a.needs and a.needs.energy or 0
                local reach, lad = P.LadderReachable(world, a, pt)
                -- trapped: no way out at all (forecast warning, once per trap)
                if not reach then
                    if not st.poolTrapped then
                        st.poolTrapped = true
                        local f = P.Forecast(world, a)
                        local text = a.name .. " is in the pool with no ladder to climb out. " .. f.text
                        SS.Actions.Message(world, a, text, "energy")
                        SS.Sim.Emergency(world, text, "warning")
                        SS.Emit("poolWarning", world, a, "trapped", f)
                    end
                else
                    st.poolTrapped = nil
                end
                -- idle free-willed swimmers climb out after a while
                if reach and st.idleSince and world.time - st.idleSince >= P.T.idleExit and world.settings and world.settings.freeWill then
                    st.idleSince = nil
                    exitOrder(world, a, lad)
                end
                -- exhaustion pathway
                local level = st.poolWarn or 0
                if energy < P.T.warnAt and level < 1 then
                    st.poolWarn = 1
                    local f = P.Forecast(world, a)
                    SS.Actions.Message(world, a, a.name .. " is getting tired in the pool. " .. f.text, "energy")
                    SS.Emit("poolWarning", world, a, "tired", f)
                end
                if energy < P.T.dangerAt then
                    if reach then
                        if not heading(a) and (not st.poolExit or world.time - st.poolExit > 10) then
                            if (st.poolWarn or 0) < 2 then
                                st.poolWarn = 2
                                SS.Actions.Message(world, a, a.name .. " is exhausted and heading for the ladder.", "energy")
                                SS.Emit("poolWarning", world, a, "exhausted", P.Forecast(world, a))
                            end
                            exitOrder(world, a, lad)
                        end
                    elseif (st.poolWarn or 0) < 3 then
                        st.poolWarn = 3
                        local f = P.Forecast(world, a)
                        local left = math.floor((f.toExhausted or 0) + 0.5)
                        local text = string.format("%s is exhausted in the pool and can't reach a ladder! Strength runs out in about %d minutes.", a.name, left)
                        SS.Actions.Message(world, a, text, "energy")
                        SS.Sim.Emergency(world, text, "emergency")
                        SS.Emit("poolWarning", world, a, "danger", f)
                    end
                end
                if energy <= P.T.drownAt then
                    if reach then
                        -- clinging on at the edge of their strength until they reach the ladder
                        a.needs.energy = P.T.drownAt + 1
                        if not heading(a) then exitOrder(world, a, lad) end
                    else
                        SS.Emit("poolWarning", world, a, "drowned", P.Forecast(world, a))
                        if SS.Actions.Journal and world.journal then SS.Actions.Journal(world, a.name .. " ran out of strength in the pool and drowned.") end
                        SS.Death.Kill(world, a, "drowning")
                    end
                end
            else
                if st.swimOutfit then
                    if a.outfit == "swim" then a.outfit = st.dryOutfit or "everyday" end
                    st.swimOutfit, st.dryOutfit = nil, nil
                end
                local ia = a.act and SS.Interactions[a.act.iid]
                if a.outfit == "swim" and not st.swimOutfit and not (ia and (ia.outfit == "swim" or P.SWIM_IIDS[a.act.iid])) then
                    -- after a load the runtime note is gone: out of the water means dressed again
                    a.outfit = "everyday"
                end
                st.poolWarn, st.poolTrapped, st.idleSince, st.swimTo, st.swimDir = nil, nil, nil, nil, nil
                if a.swimming then
                    a.swimming = nil
                    if a.pose == "swim" then a.pose = "idle" end
                end
            end
        end
    end
end

-- After a load: a swim or float that the executor resumed goes on from the saved spot in the
-- water (see resumeSpot), before anything is drawn or ticked.
local function attachPool(world)
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        local act = a and a.act
        if act and act.resumed and (act.iid == "swim" or act.iid == "pool_float") then
            a.tmp = a.tmp or {}
            resumeSpot(world, a, act)
        end
    end
end
SS.Sim.Register({ name = "pool", order = 30, tick = P.Tick, attach = attachPool })
SS.Save.RegisterRuntime("actor", "swimming")

---------------------------------------------------------------------------------------------------
-- Save validation
---------------------------------------------------------------------------------------------------
SS.Save.RegisterValidator(function(root, problems)
    for lotId, lot in pairs(root.hood and root.hood.lots or {}) do
        if type(lot.pool) ~= "table" then lot.pool = {} end
        for k, e in pairs(lot.pool) do
            if type(k) ~= "number" or k < 1 or k > lot.w * lot.h then
                lot.pool[k] = nil
                problems[#problems + 1] = "removed a damaged pool tile on " .. tostring(lotId)
            elseif type(e) ~= "table" then
                lot.pool[k] = { depth = P.T.depth, style = P.STYLES[1].id }
            else
                if not P.STYLE[e.style or ""] then e.style = P.STYLES[1].id end
                if type(e.depth) ~= "number" then e.depth = P.T.depth end
            end
        end
    end
    return true
end)
