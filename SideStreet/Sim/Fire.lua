-- SideStreet fire (brief 16.1): ignition, burning cells, spread, damage, smoke alarms, resident
-- response, catching fire, firefighters and aftermath. Owner: events module.
--
-- Saved state
--   lot.fires["L:i:j"] = { level, i, j, int (0..1), fuel, t, ev, objs = {oid...}, src, burned, flames }
--   object state: burning (while its cell burns), heat, burnt (+ broken), ev (system objects)
--   root.events.people[rid].fire = { st, t, ev, tries }  and  .onFire = { since, ev }
--   the fire's event record (kind "fire", lane "emergency") holds cause, damage lists, calls,
--   responders and the exactly-once flags.
-- Runtime only: IDX (burning / near-fire cell sets for the route hooks), effect lists.
local _, SS = ...
local F = SS.Fire or {}
SS.Fire = F
local Ev = SS.Events
local FD = SS.EventsData.fire
local FP = SS.EventsData.fireplace
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local NONE = {}   -- shared empty table for read-only fallbacks (never written)

local function cellIdx(level, i, j) return level * 100000 + j * 1000 + i end
-- Cell keys ("L:i:j") are built once per cell and kept, so the per-minute spread and lookup code
-- does not make new strings (cells off the 0..999 x 0..99 grid are built each time).
local KEYS = {}
local function key(level, i, j)
    if i < 0 or j < 0 or i >= 1000 or j >= 100 or level < 0 then return level .. ":" .. i .. ":" .. j end
    local n = cellIdx(level, i, j)
    local s = KEYS[n]
    if not s then s = level .. ":" .. i .. ":" .. j; KEYS[n] = s end
    return s
end
F.Key = key

-- Roles that are part of an emergency response and do not flee or leave because of a fire.
F.RESPONDERS = { firefighter = true, police = true, registrar = true, burglar = true, ghost = true }

---------------------------------------------------------------------------------------------------
-- Runtime index of burning cells, used by the route hooks (cheap lookups inside A*).
local IDX = { lotId = nil, burning = {}, near = {}, n = 0, stamp = 0, cells = 0 }
F.IDX = IDX

-- Rebuilt whenever the set of burning cells changes (a cell starts, goes out, or is put out to
-- intensity 0); `stamp` tells the sorted-cell cache below to rebuild too. The two sets are wiped
-- and refilled in place (the route hooks read them through IDX on every call).
local function reindex(world)
    local lot = world.lot
    IDX.stamp = IDX.stamp + 1
    local b, nr, n = IDX.burning, IDX.near, 0
    for k in pairs(b) do b[k] = nil end
    for k in pairs(nr) do nr[k] = nil end
    for _, c in pairs(lot.fires or NONE) do
        if c.int > 0 then
            n = n + 1
            b[cellIdx(c.level, c.i, c.j)] = c
            for dj = -1, 1 do
                for di = -1, 1 do nr[cellIdx(c.level, c.i + di, c.j + dj)] = true end
            end
        end
    end
    IDX.lotId, IDX.n = lot.id, n
end
F.Reindex = reindex

-- Does the index still match the live cells? (allocation-free; the per-minute model reindexes
-- only when a cell started, went out or reached intensity 0)
local function indexStale(lot)
    if IDX.lotId ~= lot.id then return true end
    local n = 0
    for _, c in pairs(lot.fires or NONE) do
        if c.int > 0 then
            n = n + 1
            if IDX.burning[cellIdx(c.level, c.i, c.j)] ~= c then return true end
        end
    end
    return n ~= IDX.n
end
F.IndexStale = indexStale

-- Nobody walks into flames (leaving a burning cell is always allowed).
SS.World.RegisterPassHook(function(world, level, i, j, ni, nj, wall, who)
    if IDX.n == 0 or IDX.lotId ~= world.lot.id then return nil end
    if IDX.burning[cellIdx(level, ni, nj)] then return false end
    return nil
end)
-- Routes avoid passing right beside a fire when there is another way.
SS.World.RegisterCostHook(function(world, level, i, j, who)
    if IDX.n == 0 or IDX.lotId ~= world.lot.id then return 0 end
    if IDX.near[cellIdx(level, i, j)] and not (who and who.role == "firefighter") then return FD.dangerCost end
    return 0
end)

function F.BurningAt(world, level, i, j)
    if IDX.lotId ~= world.lot.id then reindex(world) end
    return IDX.burning[cellIdx(level or 0, i, j)]
end

---------------------------------------------------------------------------------------------------
-- Queries.

function F.Count(lot)
    local n = 0
    for _ in pairs(lot.fires or NONE) do n = n + 1 end
    return n
end

-- Is there a fire on this lot right now? (build and buy refuse entry while this is true)
function F.Active(world)
    local lot = world and world.lot
    if not lot then return false end
    if lot.fires and next(lot.fires) then return true end
    return Ev.Active(world, "fire", lot.id) ~= nil
end

function F.Event(world) return Ev.Active(world, "fire", world.lot.id) end

-- Flammability of an object definition (0 = does not burn).
function F.Risk(def)
    if not def or def.system then return 0 end
    local q = def.quality and def.quality.fireRisk
    if type(q) == "number" then return q end
    local m = def.material and FD.material[def.material]
    if m then return m end
    if Ev.HasTag(def, "fireplace") or Ev.HasTag(def, "smoke_alarm") then return 0 end
    if def.stairs then return 0.5 end
    return FD.fireRiskByCat[def.cat] or FD.fireRiskByCat.default
end

local FLOOR_KEYS = {}
for k in pairs(FD.floorFuel) do if k ~= "default" then FLOOR_KEYS[#FLOOR_KEYS + 1] = k end end
table.sort(FLOOR_KEYS)

local function floorFuel(lot, level, i, j)
    local f = SS.World.FloorAt(lot, level, i, j)
    if not f then return FD.floorFuel.default end
    local fin = SS.Finishes and SS.Finishes[f]
    local mat = type(fin) == "table" and fin.material
    if mat and FD.floorFuel[mat] then return FD.floorFuel[mat] end
    for _, k in ipairs(FLOOR_KEYS) do
        if tostring(f):find(k, 1, true) then return FD.floorFuel[k] end
    end
    return FD.floorFuel.default
end
F.FloorFuel = floorFuel

-- Objects (not this module's system objects) covering each cell, and the smoke alarms, cached
-- while the lot's objects are unchanged: same lot and object table, same non-system object count, same
-- occupancy version (SS.RT.version moves on every placement), rebuilt at least every
-- FD.cellMapRefresh minutes and whenever this module destroys something (F.InvalidateCells).
local cellMapCache = { t = nil, lotId = nil, map = nil, alarms = nil }
local function cellMap(world)
    local lot = world.lot
    local cc = cellMapCache
    local n = 0
    for _, o in pairs(lot.objects) do
        local d = SS.Objects[o.def]
        if d and not d.system then n = n + 1 end   -- flames and scorch marks come and go without a rebuild
    end
    if cc.t and cc.lotId == lot.id and cc.objs == lot.objects and cc.ver == SS.RT.version and cc.n == n
        and world.time >= cc.t and world.time - cc.t < FD.cellMapRefresh then return cc.map end
    local map, al = {}, {}
    for _, oid in ipairs(Ev.SortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and not def.system then
            for _, c in ipairs(Ev.ObjectCells(o)) do
                local k = cellIdx(o.level or 0, c[1], c[2])
                local l = map[k]
                if not l then l = {}; map[k] = l end
                l[#l + 1] = o
            end
            if Ev.HasTag(def, "smoke_alarm") then al[#al + 1] = o end
        end
    end
    cc.t, cc.lotId, cc.objs, cc.n, cc.map, cc.alarms, cc.ver = world.time, lot.id, lot.objects, n, map, al, SS.RT.version
    return map
end
function F.InvalidateCells() cellMapCache.t = nil end
-- Smoke alarms on the lot (id order) from the same cache; broken or burnt ones are filtered by
-- the caller, since their state changes without the object set changing.
local function cachedAlarms(world)
    cellMap(world)
    return cellMapCache.alarms
end

local function fuelAt(world, level, i, j)
    local fuel = floorFuel(world.lot, level, i, j)
    for _, o in ipairs(cellMap(world)[cellIdx(level, i, j)] or NONE) do
        fuel = fuel + FD.objectFuel * F.Risk(SS.Objects[o.def])
    end
    return fuel
end
F.FuelAt = fuelAt

local function hasExtinguisher(world)
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        if def and Ev.HasTag(def, "extinguisher") and not (o.state and (o.state.broken or o.state.burnt)) then return true end
    end
    return false
end
F.HasExtinguisher = hasExtinguisher

-- Burning cells sorted by key (deterministic), optionally only live ones. Cached until the index
-- changes (reindex), so the per-sub-step firefighter and resident code does not allocate. The
-- returned list must not be modified.
local cellsCache = { lot = nil, fires = nil, stamp = -1, cells = -1, all = {}, live = {} }
local function byCellKey(a, b) return key(a.level, a.i, a.j) < key(b.level, b.i, b.j) end
local function sortedCells(lot, liveOnly)
    local cc = cellsCache
    if cc.lot ~= lot or cc.fires ~= lot.fires or cc.stamp ~= IDX.stamp or cc.cells ~= IDX.cells then
        -- new lists (a caller may still be walking the old one); rebuilt only when cells change
        local all, live = {}, {}
        for _, c in pairs(lot.fires or NONE) do all[#all + 1] = c end
        table.sort(all, byCellKey)   -- the same order as sorting the "L:i:j" keys
        for n = 1, #all do local c = all[n]; if c.int > 0 then live[#live + 1] = c end end
        cc.lot, cc.fires, cc.stamp, cc.cells, cc.all, cc.live = lot, lot.fires, IDX.stamp, IDX.cells, all, live
    end
    return liveOnly and cc.live or cc.all
end
F.SortedCells = sortedCells
function F.InvalidateSorted() cellsCache.stamp = -1 end

-- Nearest live burning cell to an actor (same level first).
local function nearestCell(world, a, maxInt)
    local ai, aj, al = Ev.CellOf(a)
    local best, bd
    local list = sortedCells(world.lot, true)
    for n = 1, #list do
        local c = list[n]
        if c.int > 0 then
            local d = Ev.Dist(ai, aj, c.i, c.j) + (c.level == al and 0 or 50)
            if not bd or d < bd then best, bd = c, d end
        end
    end
    return best, bd
end
F.NearestCell = nearestCell

local function fireSize(world)
    local n, mx = 0, 0
    for _, c in pairs(world.lot.fires or NONE) do
        if c.int > 0 then n = n + 1; if c.int > mx then mx = c.int end end
    end
    return n, mx
end
F.Size = fireSize

local function firefighterWorking(world)
    local ids = Ev.ActorIds(world)
    for n = 1, #ids do
        local a = world.actors[ids[n]]
        if a and a.role == "firefighter" and a.roleData and a.roleData.phase ~= "leaving" then return a end
    end
end

---------------------------------------------------------------------------------------------------
-- Ignition.

local CAUSE_TEXT = {
    cooking = "The %s caught fire during cooking.",
    fireplace = "Sparks from the fireplace set the %s alight.",
    electrical = "Faulty wiring in the %s started a fire.",
    shock = "The %s threw sparks and caught fire.",
    debug = "A fire was started at the %s (debug).",
    candle = "A candle set the %s alight.",
}

local function whereText(world, level, i, j, src)
    local def = src and SS.Objects[src.def]
    if def then return def.name end
    return (SS.World.RoomAt(world, level, i, j) > 0) and "floor" or "yard"
end

-- `batch` (the per-minute model) leaves the index to the caller, which rebuilds it once.
local function addCell(world, e, level, i, j, int, extraFuel, srcId, batch)
    local lot = world.lot
    lot.fires = lot.fires or {}
    local objs = {}
    local fuel = floorFuel(lot, level, i, j) + (extraFuel or 0)
    for _, o in ipairs(cellMap(world)[cellIdx(level, i, j)] or NONE) do
        objs[#objs + 1] = o.id
        fuel = fuel + FD.objectFuel * F.Risk(SS.Objects[o.def])
        o.state = o.state or {}
        if not o.state.burning then o.state.burning = true; SS.Emit("lotChanged", "state", o.id) end
    end
    local k = key(level, i, j)
    local c = { level = level, i = i, j = j, int = int, fuel = fuel, t = world.time, ev = e.id, objs = objs,
        src = srcId, burned = 0 }
    lot.fires[k] = c
    IDX.cells = IDX.cells + 1
    local fl = Ev.AddObject(world, lot, "ev_flames", i, j, 0, level, { cell = k, ev = e.id }, true)
    c.flames = fl.id
    e.data.cells = (e.data.cells or 0) + 1
    local live = fireSize(world)
    if live > (e.data.peak or 0) then e.data.peak = live end
    if not batch then reindex(world) end
    SS.Emit("fireCell", world, c, "start")
    return c
end

-- Start a fire at a cell (or on object `oid`). cause: "cooking", "fireplace", "electrical",
-- "debug", ... Returns the fire's event record, or nil and a reason.
function F.Ignite(world, level, i, j, cause, oid)
    if not world or not world.lot then return nil, "No lot is running." end
    local lot = world.lot
    local src = oid and lot.objects[oid]
    if src then level, i, j = src.level or 0, src.x, src.y end
    level = level or 0
    if type(i) ~= "number" or type(j) ~= "number" or not SS.World.InLot(lot, i, j) then return nil, "That is not on the lot." end
    if level > 0 and not SS.World.FloorAt(lot, level, i, j) then return nil, "There is no floor there." end
    lot.fires = lot.fires or {}
    local e = F.Event(world)
    if lot.fires[key(level, i, j)] then return e, "It is already burning." end
    if F.Count(lot) >= FD.maxCells then return e, "The fire cannot get any bigger." end
    cause = cause or "unknown"
    if not e then
        local what = whereText(world, level, i, j, src)
        local text = string.format(CAUSE_TEXT[cause] or "A fire broke out at the %s.", what)
        e = Ev.Record(world, "fire", { burnt = {}, destroyed = {}, singed = {}, loss = 0, doors = {}, origin = { level, i, j },
            responders = {} }, { cause = cause, lane = "emergency", family = "fire", targets = src and { src.id } or {},
            text = "Fire! " .. text })
        if SS.Economy and SS.Economy.LotValue then e.data.valueBefore = Ev.Call(SS.Economy.LotValue, world, lot) end
        Ev.Emergency(world, "Fire! " .. text, "emergency")
        Ev.Audio("SetMode", "emergency")
    end
    addCell(world, e, level, i, j, FD.startIntensity, src and FD.sourceFuel or 0, src and src.id)
    return e
end

-- Debug "start a fire here" goes through exactly the same path.
function F.DebugIgnite(world, level, i, j, oid) return F.Ignite(world, level, i, j, "debug", oid) end

-- Chance that one cooking attempt starts a fire (household-core rolls it; see docs/requests).
function F.CookingChance(actor, stoveDef)
    local cook = (SS.Skills and SS.Skills.Level and SS.Skills.Level(actor, "cooking")) or 0
    local q = stoveDef and stoveDef.quality and stoveDef.quality.fireRisk or 1
    return SS.U.clamp(0.04 * (1 - cook / 10) * q, 0.002, 0.08)
end

---------------------------------------------------------------------------------------------------
-- Calling the fire service (alarm, phone, neighbour).

-- The n-th firefighter: the visitors module's firefighter pool when loaded, else events' own.
function F.FirefighterId(n) return Ev.ResponderId("firefighter", n, "npc_fire_" .. n) end

function F.CallService(world, e, how, caller)
    e = Ev.Find(world, e) or F.Event(world)
    if not e then return false, "Nothing is on fire." end
    if e.state ~= "active" then return false, "The fire is already out." end
    if e.data.called then return false, "The fire service is already on the way." end
    e.data.called = { how = how, t = world.time, by = caller and caller.id }
    local delay = FD.responseMin + SS.RandomInt(world, "fire", 0, FD.responseJitter)
    for n = 1, FD.firefighters do
        Ev.RequestResponder(world, e, "firefighter", F.FirefighterId(n), delay, n == 1 and "fire_truck" or nil)
    end
    local text
    if how == "alarm" then text = "The smoke alarm called the fire service automatically."
    elseif how == "neighbour" then text = "A neighbour saw the smoke and called the fire service."
    else text = (caller and caller.name or "Someone") .. " called the fire service." end
    Ev.Journal(world, text, e)
    return true, "The fire service is on the way (about " .. delay .. " minutes)."
end

if SS.Phone and SS.Phone.RegisterCall then
    SS.Phone.RegisterCall({
        id = "ev_fire_service", label = "Fire Service", category = "Emergency", order = 1,
        test = function(world, caller)
            local e = F.Event(world)
            if not e or not (world.lot.fires and next(world.lot.fires)) then return false, "Nothing is on fire. Keep the line free for emergencies." end
            if e.data.called then return false, "The fire service is already on the way." end
            return true
        end,
        run = function(world, caller) return F.CallService(world, F.Event(world), "phone", caller) end,
    })
end

---------------------------------------------------------------------------------------------------
-- Smoke alarms. Coverage rule: an alarm hears a burning cell on its own level when the cell is
-- in the same indoor room, or when it is within its range in steps through edges with no wall,
-- window or closed door between (open arches, fences and gates let smoke through). The range is
-- the catalogue's def.quality.range when set (the smoke alarm has 6), else FD.alarmRange.
local SMOKE_OPEN = { arch = true, fence = true, gate = true, railing = true, halfwall = true }

function F.AlarmRange(alarm)
    local def = SS.Objects[alarm.def]
    local r = def and def.quality and def.quality.range
    return type(r) == "number" and r or FD.alarmRange
end

-- Coverage depends only on the walls, the alarm's position and range and the cell, so answers are
-- cached per alarm until the lot's layout changes (SS.RT.version) or the alarm moves.
local coverCache = { ver = nil, lotId = nil, byAlarm = {} }
local covers
function F.Covers(world, alarm, level, i, j)
    local cc = coverCache
    if cc.ver ~= SS.RT.version or cc.lotId ~= world.lot.id then cc.ver, cc.lotId, cc.byAlarm = SS.RT.version, world.lot.id, {} end
    local ca = cc.byAlarm[alarm]
    local where = ((alarm.level or 0) * 1000 + alarm.y) * 1000 + alarm.x
    local range = F.AlarmRange(alarm)
    if not ca or ca.where ~= where or ca.range ~= range then ca = { where = where, range = range, cells = {} }; cc.byAlarm[alarm] = ca end
    local k = cellIdx(level, i, j)
    local v = ca.cells[k]
    if v == nil then v = covers(world, alarm, level, i, j); ca.cells[k] = v end
    return v
end
covers = function(world, alarm, level, i, j)
    if (alarm.level or 0) ~= level then return false end
    local ra = SS.World.RoomAt(world, level, alarm.x, alarm.y)
    if ra > 0 and ra == SS.World.RoomAt(world, level, i, j) then return true end
    local range = F.AlarmRange(alarm)
    if Ev.Dist(alarm.x, alarm.y, i, j) > range then return false end
    local lot = world.lot
    local walls = lot.walls[level] or NONE
    local seen, frontier = { [alarm.y * 1000 + alarm.x] = true }, { { alarm.x, alarm.y } }
    for _ = 1, range do
        local nextF = {}
        for _, c in ipairs(frontier) do
            for k = 0, 3 do
                local dv = SS.Grid.DIRS[k]
                local ni, nj = c[1] + dv[1], c[2] + dv[2]
                local wl = walls[SS.Grid.edgeBetween(c[1], c[2], ni, nj)]
                if SS.World.InLot(lot, ni, nj) and not seen[nj * 1000 + ni] and (not wl or SMOKE_OPEN[wl.kind]) then
                    if ni == i and nj == j then return true end
                    seen[nj * 1000 + ni] = true
                    nextF[#nextF + 1] = { ni, nj }
                end
            end
        end
        frontier = nextF
    end
    return false
end

local function alarms(world)
    local out = {}
    for _, oid in ipairs(Ev.SortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and Ev.HasTag(def, "smoke_alarm") and not (o.state and (o.state.broken or o.state.burnt)) then out[#out + 1] = o end
    end
    return out
end
F.Alarms = alarms

local function detect(world, e)
    if e.data.alarm then return end
    local list = cachedAlarms(world)
    if #list == 0 then return end
    for _, c in ipairs(sortedCells(world.lot, true)) do
        if c.burned >= FD.smokeDelay then
            for _, al in ipairs(list) do
                if world.lot.objects[al.id] == al and not (al.state and (al.state.broken or al.state.burnt))
                    and F.Covers(world, al, c.level, c.i, c.j) then
                    e.data.alarm, e.data.alarmAt = al.id, world.time
                    Ev.StartRinging(world, al)
                    Ev.Audio("Cue", "fire_alarm")
                    Ev.Emergency(world, "The smoke alarm is going off!", "emergency")
                    Ev.Journal(world, "The smoke alarm went off.", e)
                    F.CallService(world, e, "alarm")
                    return
                end
            end
        end
    end
end

local function stopAlarm(world, e)
    Ev.StopRinging(world, e.data.alarm and world.lot.objects[e.data.alarm])
end

---------------------------------------------------------------------------------------------------
-- Damage.

local function objectValue(world, o)
    local def = SS.Objects[o.def]
    if SS.Economy and SS.Economy.ResaleValue then
        local v = Ev.Call(SS.Economy.ResaleValue, world, o)
        if type(v) == "number" then return v end
    end
    return o.paid or (def and def.price) or 0
end

local function destroy(world, e, o)
    local lot = world.lot
    local def = SS.Objects[o.def]
    local value = objectValue(world, o)
    e.data.loss = (e.data.loss or 0) + value
    local d = e.data.destroyed
    if #d < 24 then d[#d + 1] = { name = def and def.name or o.def, value = value, def = o.def } end
    -- things resting on it go with it
    for _, cid in ipairs(Ev.SortedKeys(lot.objects)) do
        local ch = lot.objects[cid]
        if ch.parent == o.id then Ev.RemoveObject(world, lot, cid, true) end
    end
    local x, y, level = o.x, o.y, o.level or 0
    local floorItem = not def or not def.mount or def.mount == "floor"
    Ev.RemoveObject(world, lot, o.id, true)
    F.InvalidateCells()
    if floorItem and not SS.World.Blocked(world, level, x, y) then
        Ev.AddObject(world, lot, "ev_charred", x, y, o.f or 0, level, { ev = e.id, from = def and def.name, value = value }, true)
    end
    Ev.Journal(world, (def and def.name or "Something") .. " was destroyed in the fire.", e)
end

local function heatObjects(world, e, c)
    local lot = world.lot
    for _, oid in ipairs(c.objs) do
        local o = lot.objects[oid]
        if o then
            local def = SS.Objects[o.def]
            local factor = max(FD.minHeatFactor, F.Risk(def))
            if oid == c.src then factor = max(factor, FD.sourceFactor) end
            o.state = o.state or {}
            o.state.heat = (o.state.heat or 0) + FD.heatRate * c.int * factor
            if o.state.heat >= FD.burntHeat and not o.state.burnt then
                o.state.burnt = true
                o.state.ev = e.id
                if SS.Maintenance and SS.Maintenance.Break then Ev.Call(SS.Maintenance.Break, world, o, "fire") end
                o.state.broken = true
                local b = e.data.burnt
                if #b < 24 then b[#b + 1] = { oid = o.id, name = def and def.name or o.def } end
                SS.Emit("lotChanged", "state", o.id)
            end
            if o.state.heat >= FD.destroyHeat and not (def and def.stairs) then destroy(world, e, o) end
        end
    end
end

local SPREAD_BLOCK = { wall = true, window = true, door = true }

local function burnDoors(world, e, c)
    local walls = world.lot.walls[c.level]
    if not walls then return end
    for k = 0, 3 do
        local dv = SS.Grid.DIRS[k]
        local ek = SS.Grid.edgeBetween(c.i, c.j, c.i + dv[1], c.j + dv[2])
        local wl = walls[ek]
        if wl and wl.kind == "door" then
            e.data.doors[ek] = (e.data.doors[ek] or 0) + c.int
            if e.data.doors[ek] >= FD.doorBurn then
                wl.kind, wl.burnt = "arch", true
                world.lot.version = (world.lot.version or 1) + 1
                e.data.doorsLost = (e.data.doorsLost or 0) + 1
                SS.World.Rebuild(world)
                SS.Emit("lotChanged", "wall", ek)
                Ev.Journal(world, "The fire burned through a door; only the frame is left.", e)
            end
        end
    end
end

-- Spread candidates are {level, i, j} triples from a pool reused every minute.
local SPREAD_POOL, spreadN = {}, 0
local function spread(world, e, c, out)
    if c.int < FD.spreadMin then return end
    local lot = world.lot
    local walls = lot.walls[c.level] or NONE
    for k = 0, 3 do
        local dv = SS.Grid.DIRS[k]
        local ni, nj = c.i + dv[1], c.j + dv[2]
        if SS.World.InLot(lot, ni, nj) and not lot.fires[key(c.level, ni, nj)] and (c.level == 0 or SS.World.FloorAt(lot, c.level, ni, nj)) then
            local wl = walls[SS.Grid.edgeBetween(c.i, c.j, ni, nj)]
            if not (wl and SPREAD_BLOCK[wl.kind]) then
                local nf = fuelAt(world, c.level, ni, nj)
                if nf > 0 then
                    local chance = FD.spreadChance * c.int * (nf / FD.objectFuel)
                    if SS.Random(world, "fire") < chance then
                        spreadN = spreadN + 1
                        local t = SPREAD_POOL[spreadN]
                        if not t then t = {}; SPREAD_POOL[spreadN] = t end
                        t[1], t[2], t[3] = c.level, ni, nj
                        out[#out + 1] = t
                    end
                end
            end
        end
    end
end

-- A cell stops burning: flames go, scorch marks stay where it burned for a while.
local function cellOut(world, e, c, batch)
    local lot = world.lot
    local k = key(c.level, c.i, c.j)
    lot.fires[k] = nil
    IDX.cells = IDX.cells + 1
    if c.flames and lot.objects[c.flames] then Ev.RemoveObject(world, lot, c.flames, true) end
    for _, oid in ipairs(c.objs) do
        local o = lot.objects[oid]
        if o and o.state and o.state.burning then
            local still = false
            for _, oc in pairs(lot.fires) do
                for _, x in ipairs(oc.objs) do if x == oid then still = true end end
            end
            if not still then o.state.burning = nil; SS.Emit("lotChanged", "state", oid) end
        end
    end
    if c.burned >= FD.scorchAfter and e then
        local has = false
        for _, o in pairs(lot.objects) do
            if o.def == "ev_scorch" and o.x == c.i and o.y == c.j and (o.level or 0) == c.level then has = true end
        end
        if not has then
            Ev.AddObject(world, lot, "ev_scorch", c.i, c.j, 0, c.level, { ev = e.id }, true)
            e.data.scorch = (e.data.scorch or 0) + 1
        end
    end
    if not batch then reindex(world) end
    SS.Emit("fireCell", world, c, "out")
end
F.CellOut = cellOut

---------------------------------------------------------------------------------------------------
-- People: awareness, panic, fight or flee, calling for help, catching fire.

local function fireState(world, a) local p = Ev.PersonIf(world, a.id); return p and p.fire end

function F.CanFight(world, a)
    if not Ev.IsAdult(a) then return false, "too young" end
    local p = Ev.PersonIf(world, a.id)
    if p and p.onFire then return false, "on fire" end
    if firefighterWorking(world) then return false, "the firefighters are here" end
    local n, mx = fireSize(world)
    if n == 0 then return false, "nothing burning" end
    if n > FD.fightMaxCells then return false, "too big" end
    local mech = (SS.Skills and SS.Skills.Level and SS.Skills.Level(a, "mechanical")) or 0
    local score = FD.fightBase + mech * FD.fightSkill + (hasExtinguisher(world) and FD.fightExtinguisher or 0)
        - n * FD.fightPerCell - mx * FD.fightIntensity
    if score <= 0 then return false, "too dangerous for their skill" end
    return true, score
end

-- Outdoor ground cells far enough from every flame, nearest to the street entry first.
local function safeCells(world)
    local lot = world.lot
    local live = sortedCells(lot, true)
    local ei, ej = SS.Street.EntryCell(world)
    local out = {}
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do
            if SS.World.RoomAt(world, 0, i, j) == 0 and not SS.World.Blocked(world, 0, i, j) then
                local ok = true
                for _, c in ipairs(live) do
                    if Ev.Dist(i, j, c.i, c.j) < FD.safeDistance then ok = false; break end
                end
                if ok then out[#out + 1] = { i, j, abs(i - ei) + abs(j - ej) } end
            end
        end
    end
    table.sort(out, function(a, b)
        if a[3] ~= b[3] then return a[3] < b[3] end
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[1] < b[1]
    end)
    return out
end
F.SafeCells = safeCells

local function isSafe(world, a)
    local ai, aj, al = Ev.CellOf(a)
    if al ~= 0 or SS.World.RoomAt(world, 0, ai, aj) ~= 0 then return false end
    for _, c in pairs(world.lot.fires or NONE) do
        if c.int > 0 and Ev.Dist(ai, aj, c.i, c.j) < FD.safeDistance - 1 then return false end
    end
    return true
end

local function flee(world, e, a, f)
    f.st, f.t = "flee", world.time
    local cells = safeCells(world)
    -- spread people out a little: skip cells someone else is heading to
    local taken = {}
    for _, id in ipairs(Ev.ActorIds(world)) do
        local o = world.actors[id]
        local of = o and o ~= a and fireState(world, o)
        if of and of.goal then taken[of.goal[2] * 1000 + of.goal[1]] = true end
    end
    local pick
    local skip = f.tries or 0
    for _, c in ipairs(cells) do
        if not taken[c[2] * 1000 + c[1]] then
            if skip == 0 then pick = c; break end
            skip = skip - 1
        end
    end
    pick = pick or cells[1]
    if not pick then
        f.st = "trapped"
        Ev.Pseudo(world, a, "ev_panic", { len = 5 })
        Ev.Tell(world, a, a.name .. " cannot find a way out!", "alert")
        return
    end
    f.goal = { pick[1], pick[2] }
    if a.act then SS.Actions.Finish(world, a, "cancelled") end
    a.queue = {}
    SS.Actions.Order(world, a, nil, "goto", pick[1], pick[2], { level = 0, manual = true, data = { source = "events" } })
    a.pose = "run"
end

local function fight(world, e, a, f)
    local c = nearestCell(world, a)
    if not c or not c.flames or not world.lot.objects[c.flames] then return flee(world, e, a, f) end
    f.st, f.t = "fight", world.time
    if a.act then SS.Actions.Finish(world, a, "cancelled") end
    a.queue = {}
    SS.Actions.Order(world, a, c.flames, "ev_extinguish", nil, nil, { manual = true, data = { source = "events", ev = e.id } })
    Ev.Say(world, a, "fire_panic", { fighting = true }, "Stand back, I've got this!", "alert")
end

local function decide(world, e, a, f)
    if F.CanFight(world, a) then fight(world, e, a, f) else flee(world, e, a, f) end
end

local function startCall(world, e, a, f)
    e.data.calling = a.id
    f.st, f.t = "call", world.time
    Ev.Pseudo(world, a, "ev_call_fire", { ev = e.id })
end

local function aware(world, a, alarmOn, liveCells, shoutRooms)
    if alarmOn then return true, "alarm" end
    local ai, aj, al = Ev.CellOf(a)
    local room = SS.World.RoomAt(world, al, ai, aj)
    for _, c in ipairs(liveCells) do
        if c.level == al then
            local d = Ev.Dist(ai, aj, c.i, c.j)
            if a.sleeping then
                if d <= FD.wakeRange then return true, "smoke" end
            else
                if d <= 2 then return true, "heat" end
                if d <= FD.seeRange and SS.World.RoomAt(world, al, c.i, c.j) == room then return true, "saw" end
            end
        end
    end
    if not a.sleeping and shoutRooms[al * 10000 + room] then return true, "shout" end
    return false
end

function F.CatchFire(world, a, e)
    local p = Ev.Person(world, a.id)
    if p.onFire or a.dead then return end
    e = e or F.Event(world)
    p.onFire = { since = world.time, ev = e and e.id }
    Ev.Pseudo(world, a, "ev_on_fire", {})
    Ev.Tell(world, a, a.name .. " has caught fire! Stop, drop and roll!", "alert")
    Ev.Emergency(world, a.name .. " is on fire!", "emergency")
    if e then Ev.Journal(world, a.name .. " caught fire.", e, { a.id }) end
end

local function putOut(world, e, a, p, how)
    p.onFire = nil
    SS.Needs.Add(a, "hygiene", -40)
    SS.Needs.Add(a, "comfort", -30)
    SS.Needs.Add(a, "energy", -15)
    if e then local s = e.data.singed; if #s < 12 then s[#s + 1] = a.id end end
    Ev.Tell(world, a, how or (a.name .. " put the flames out. Singed and shaken, but alive."), "comfort")
    if a.act and a.act.iid == "ev_on_fire" then SS.Actions.Finish(world, a, "done") end
    p.fire = { st = "panic", t = world.time, ev = e and e.id, tries = 0 }
    if e and next(world.lot.fires or NONE) then flee(world, e, a, p.fire) end
end

local function burningPerson(world, e, a, p)
    local ai, aj, al = Ev.CellOf(a)
    for _, id in ipairs(Ev.ActorIds(world)) do
        local o = world.actors[id]
        if o and o.role == "firefighter" and (o.level or 0) == al and Ev.Dist(ai, aj, floor(o.x), floor(o.y)) <= FD.helpRange then
            return putOut(world, e, a, p, o.name .. " smothered the flames on " .. a.name .. ".")
        end
    end
    local body = (SS.Skills and SS.Skills.Level and SS.Skills.Level(a, "body")) or 0
    if SS.Random(world, "fire") < FD.rollChance + body * FD.rollBody then return putOut(world, e, a, p) end
    local elapsed = world.time - p.onFire.since
    if elapsed >= FD.onFireMinutes then
        p.onFire = nil
        p.fire = nil
        if SS.Death and SS.Death.Kill then SS.Death.Kill(world, a, "fire") end
        return
    end
    if elapsed >= FD.onFireMinutes - 1 and not p.onFire.warned then
        p.onFire.warned = true
        Ev.Emergency(world, a.name .. " is badly hurt and still burning. Get help to them now!", "emergency")
    end
    if not (a.act and a.act.iid == "ev_on_fire") then Ev.Pseudo(world, a, "ev_on_fire", {}) end
end

local function calm(world, e)
    local people = Ev.State(world).people
    for _, rid in ipairs(Ev.SortedKeys(people)) do
        local p = people[rid]
        if p.fire then
            local a = world.actors[rid]
            p.fire = nil
            if a then
                a.nextThink = nil
                if a.act and (a.act.iid == "ev_panic" or a.act.iid == "ev_call_fire" or (a.act.iid == "goto" and a.act.data and a.act.data.source == "events")) then
                    SS.Actions.Finish(world, a, "done")
                end
                if e and Ev.Once(e, "after:" .. rid, world) and not a.role then
                    Ev.Say(world, a, "fire_after", { eventId = e.id }, "Is it out? It's out. Everyone okay?", "comfort")
                end
            end
        end
    end
end

local function respond(world, e, a, alarmOn, live, shoutRooms, n)
    local p = Ev.Person(world, a.id)
    if p.onFire then return burningPerson(world, e, a, p) end
    local ai, aj, al = Ev.CellOf(a)
    local here = IDX.burning[cellIdx(al, ai, aj)]
    if here and SS.Random(world, "fire") < FD.standChance * here.int then return F.CatchFire(world, a, e) end
    local f = p.fire
    if f and (f.st == "panic" or f.st == "fight") then shoutRooms[al * 10000 + SS.World.RoomAt(world, al, ai, aj)] = true end
    if not f then
        local ok, how = aware(world, a, alarmOn, live, shoutRooms)
        -- a player's own fire order (calling for help, fighting it) is not overridden by panic
        local mine = a.act and (a.act.iid == "ev_call_fire" or a.act.iid == "ev_extinguish") and a.act.iid
        if mine then
            f = { st = mine == "ev_call_fire" and "call" or "fight", t = world.time, ev = e.id, tries = 0, how = how or "player" }
            p.fire = f
            if mine == "ev_call_fire" and not e.data.calling then e.data.calling = a.id end
            shoutRooms[al * 10000 + SS.World.RoomAt(world, al, ai, aj)] = true
            return
        end
        if not ok then return end
        f = { st = "panic", t = world.time, ev = e.id, tries = 0, how = how }
        p.fire = f
        local len = SS.RandomInt(world, "fire", FD.panicMin[1], FD.panicMin[2])
        Ev.Pseudo(world, a, "ev_panic", { len = len })
        if how == "alarm" then
            -- social's alarm lines name what is burning (objDef: the object the fire started at,
            -- while it is still on the lot)
            local src = e.targets and e.targets[1] and world.lot.objects[e.targets[1]]
            Ev.Say(world, a, "fire_alarm", { how = how, objDef = src and src.def }, "The alarm! Is something burning?", "alert")
        else
            Ev.Say(world, a, "fire_panic", { how = how }, "Fire! FIRE!", "alert")
        end
        if Ev.Once(e, "noticed", world) and how ~= "alarm" then Ev.Journal(world, a.name .. " spotted the fire.", e, { a.id }) end
        shoutRooms[al * 10000 + SS.World.RoomAt(world, al, ai, aj)] = true
        return
    end
    a.nextThink = world.time + 3        -- nobody wanders back in for a snack mid-fire
    local st = f.st
    if st == "panic" or st == "trapped" then
        if a.act and a.act.iid == "ev_panic" then return end
        if st == "trapped" then f.tries = 0 end
        return decide(world, e, a, f)
    elseif st == "fight" then
        if firefighterWorking(world) then
            Ev.Balloon(world, a, "All yours!", "alert")
            f.tries = 0
            return flee(world, e, a, f)
        end
        local busy = a.act and a.act.iid == "ev_extinguish"
        local queued = a.queue and a.queue[1] and a.queue[1].iid == "ev_extinguish"
        if not busy and not queued then return decide(world, e, a, f) end
    elseif st == "flee" then
        if isSafe(world, a) then
            f.st, f.t = "safe", world.time
            if a.act and a.act.iid == "goto" then SS.Actions.Finish(world, a, "done") end
            if not e.data.called and not e.data.calling and Ev.IsHuman(a) and (a.age or "adult") ~= "infant" then
                return startCall(world, e, a, f)
            end
            return
        end
        local moving = a.act and a.act.iid == "goto" or (a.queue and a.queue[1] and a.queue[1].iid == "goto")
        if not moving then
            f.tries = (f.tries or 0) + 1
            if f.tries > 4 then
                f.st = "trapped"
                Ev.Pseudo(world, a, "ev_panic", { len = 5 })
                if Ev.Once(e, "trapped:" .. a.id, world) then
                    Ev.Emergency(world, a.name .. " is trapped by the fire!", "emergency")
                end
                return
            end
            return flee(world, e, a, f)
        end
    elseif st == "call" then
        if a.act and a.act.iid == "ev_call_fire" then return end
        f.st = isSafe(world, a) and "safe" or "flee"
        if e.data.calling == a.id and not e.data.called then e.data.calling = nil end
        if f.st == "flee" then return flee(world, e, a, f) end
    elseif st == "safe" then
        if not isSafe(world, a) then f.tries = 0; return flee(world, e, a, f) end
        if not e.data.called and not e.data.calling and Ev.IsHuman(a) and (a.age or "adult") ~= "infant" then
            return startCall(world, e, a, f)
        end
        if not a.act then a.facing = SS.Grid.dirToFacing((e.data.origin[2] or 0) - a.x, (e.data.origin[3] or 0) - a.y) end
    end
end

-- Guests, service staff and other role visitors leave when a fire breaks out.
local function sendGuestsAway(world, e)
    for _, id in ipairs(Ev.ActorIds(world)) do
        local a = world.actors[id]
        if a and a.role and not F.RESPONDERS[a.role] and Ev.IsHuman(a) then
            if Ev.Once(e, "guest:" .. id, world) then Ev.Balloon(world, a, "I'll get out of your way!", "alert") end
            Ev.SendAway(world, a, "fire")
        end
    end
end

---------------------------------------------------------------------------------------------------
-- The fire's end and the aftermath.

local function summary(e)
    local nb, nd = #(e.data.burnt or {}), #(e.data.destroyed or {})
    local parts = {}
    if nb > 0 then parts[#parts + 1] = nb .. (nb == 1 and " thing was" or " things were") .. " burnt" end
    if nd > 0 then parts[#parts + 1] = nd .. " destroyed (" .. SS.U.fmtMoney(e.data.loss or 0) .. " of belongings lost)" end
    if (e.data.doorsLost or 0) > 0 then parts[#parts + 1] = e.data.doorsLost .. " door(s) burned away" end
    if #parts == 0 then return "The fire is out. Nothing was badly damaged." end
    return "The fire is out. " .. table.concat(parts, "; ") .. "."
end
F.Summary = summary

-- Remaining fire damage from this event: charred remains, scorch marks, burnt objects.
function F.Damage(world, e)
    local lot = world.lot
    local out = { charred = 0, scorch = 0, burnt = 0 }
    for _, o in pairs(lot.objects) do
        local st = o.state
        if st and st.ev == e.id then
            if o.def == "ev_charred" then out.charred = out.charred + 1
            elseif o.def == "ev_scorch" then out.scorch = out.scorch + 1
            elseif st.burnt then out.burnt = out.burnt + 1 end
        end
    end
    out.total = out.charred + out.scorch + out.burnt
    return out
end

local function fireOut(world, e)
    e.data.outAt = world.time
    stopAlarm(world, e)
    calm(world, e)
    if SS.Economy and SS.Economy.LotValue then e.data.valueAfter = Ev.Call(SS.Economy.LotValue, world, world.lot) end
    world.lot.version = (world.lot.version or 1) + 1
    SS.World.Rebuild(world)
    SS.Emit("lotChanged", "fire", e.id)
    Ev.Audio("SetMode", "live")
    -- responders still on the way are stood down
    for _, rid in ipairs(Ev.SortedKeys(e.data.responders or {})) do
        local rec = e.data.responders[rid]
        if not rec.arrived and not rec.skipped then
            rec.skipped = world.time
            if Ev.Once(e, "stooddown", world) then Ev.Journal(world, "The fire service was told the fire is out and turned back.", e) end
        end
    end
    local text = summary(e)
    local dmg = F.Damage(world, e)
    if dmg.total == 0 then
        Ev.Resolve(world, e, "out", text)
    else
        Ev.Aftermath(world, e, text .. " Clear the remains and restore or replace what burned.")
    end
    SS.Emit("fireOut", world, e)
end

-- Aftermath resolves once charred remains, scorch marks and burnt objects are dealt with.
Ev.OnHour("fire_aftermath", function(world)
    for _, e in ipairs(Ev.Open(world, "fire", world.lot.id)) do
        if e.state == "aftermath" and F.Damage(world, e).total == 0 then
            Ev.Resolve(world, e, "cleaned_up", "The last of the fire damage has been dealt with.")
        end
    end
end, 30)

-- Restore a burnt object (a restorer is paid; the house never fixes itself). Returns ok, message.
function F.RestoreCost(world, o)
    local def = SS.Objects[o.def]
    return math.max(5, math.ceil((def and def.price or 0) * FD.restoreFactor))
end
function F.Restore(world, oid)
    local o = world.lot.objects[oid]
    if not o or not (o.state and o.state.burnt) then return false, "That is not fire-damaged." end
    if F.Active(world) and world.lot.fires and next(world.lot.fires) then return false, "Not while the fire is burning." end
    local cost = F.RestoreCost(world, o)
    if (world.money or 0) < cost then return false, "Restoring it costs " .. SS.U.fmtMoney(cost) .. "; the household cannot afford it." end
    local def = SS.Objects[o.def]
    SS.Money(world, -cost, "repair", "Restored fire-damaged " .. (def and def.name or "item"))
    o.state.burnt, o.state.broken, o.state.heat, o.state.ev = nil, nil, nil, nil
    SS.Emit("lotChanged", "state", oid)
    Ev.Journal(world, (def and def.name or "Something") .. " was restored after the fire.")
    return true, "Restored for " .. SS.U.fmtMoney(cost) .. "."
end

-- Get rid of a burnt object for scrap (then buy a replacement in buy mode).
function F.Discard(world, oid)
    local o = world.lot.objects[oid]
    if not o or not (o.state and o.state.burnt) then return false, "That is not fire-damaged." end
    local def = SS.Objects[o.def]
    Ev.RemoveObject(world, world.lot, oid)
    SS.Money(world, FD.scrapValue, "sale", "Scrap value of fire-damaged " .. (def and def.name or "item"))
    Ev.Journal(world, (def and def.name or "Something") .. " was hauled away after the fire.")
    return true, "Hauled away for " .. SS.U.fmtMoney(FD.scrapValue) .. " scrap. Replace it in buy mode."
end

---------------------------------------------------------------------------------------------------
-- The per-minute fire model.

-- People still burning after the last flame went out (or set alight some other way).
local function burningPeople(world, e)
    local people = Ev.State(world).people
    local any = false
    for _, p in pairs(people) do if p.onFire then any = true; break end end
    if not any then return end
    for _, rid in ipairs(Ev.SortedKeys(people)) do
        local p = people[rid]
        local a = p.onFire and world.actors[rid]
        if a and not a.dead then burningPerson(world, e or Ev.Find(world, p.onFire.ev), a, p)
        elseif p.onFire and not world.actors[rid] then p.onFire = nil end
    end
end

local SCRATCH_NEW, SCRATCH_SHOUT, SCRATCH_PEOPLE, SCRATCH_OUT = {}, {}, {}, {}
local function wipe(t) for k in pairs(t) do t[k] = nil end return t end
local function minute(world)
    local lot = world.lot
    if IDX.lotId ~= lot.id then reindex(world) end
    local e = F.Event(world)
    if not lot.fires or not next(lot.fires) then
        if e and not e.data.outAt then fireOut(world, e) end
        burningPeople(world, e)
        return
    end
    if not e then
        -- cells without a record (damaged save): adopt them into a new record
        e = Ev.Record(world, "fire", { burnt = {}, destroyed = {}, singed = {}, loss = 0, doors = {}, origin = { 0, 0, 0 }, responders = {} },
            { cause = "unknown", lane = "emergency", family = "fire" })
    end
    local cells = sortedCells(lot)
    local newCells = wipe(SCRATCH_NEW)
    spreadN = 0
    for _, c in ipairs(cells) do
        if c.int > 0 then
            local fought = (world.time - (c.foughtAt or -1e9)) <= 1.01
            if c.fuel > 0 then
                if not fought then c.int = min(1, c.int + FD.growth) end
                c.fuel = max(0, c.fuel - c.int)
            else
                c.int = c.int - FD.decay
            end
            c.burned = c.burned + 1
            if c.int > 0 then
                heatObjects(world, e, c)
                burnDoors(world, e, c)
                spread(world, e, c, newCells)
            end
        end
    end
    local changed = false
    for _, nc in ipairs(newCells) do
        if not lot.fires[key(nc[1], nc[2], nc[3])] and F.Count(lot) < FD.maxCells then
            addCell(world, e, nc[1], nc[2], nc[3], FD.startIntensity * 0.8, 0, nil, true)
            changed = true
        end
    end
    -- cells that went out, collected first so the list is not rebuilt while it is walked
    local outs = wipe(SCRATCH_OUT)
    for _, c in ipairs(sortedCells(lot)) do
        if c.int <= 0 and lot.fires[key(c.level, c.i, c.j)] == c then outs[#outs + 1] = c end
    end
    for n = 1, #outs do cellOut(world, e, outs[n], true); changed = true end
    wipe(outs)
    if changed or indexStale(lot) then reindex(world) end
    local live = sortedCells(lot, true)
    local n = #live
    if n > (e.data.peak or 0) then e.data.peak = n end
    -- detection and calls; a ringing alarm keeps ringing while the fire burns
    detect(world, e)
    if e.data.alarm and n > 0 then Ev.KeepRinging(world, lot.objects[e.data.alarm]) end
    if not e.data.called and (world.time - e.t >= FD.neighbourDelay or n >= FD.neighbourCells) then
        F.CallService(world, e, "neighbour")
    end
    -- people
    local alarmOn = e.data.alarm ~= nil and n > 0
    local shoutRooms = wipe(SCRATCH_SHOUT)
    if n > 0 then
        for _, a in ipairs(Ev.People(world, nil, wipe(SCRATCH_PEOPLE))) do respond(world, e, a, alarmOn, live, shoutRooms, n) end
        sendGuestsAway(world, e)
    else
        burningPeople(world, e)
    end
    if not next(lot.fires) then fireOut(world, e) end
end

Ev.OnMinute("fire", function(world) minute(world) end, 30)

-- Keep the index honest across lot switches and loads. Actions do not survive a load, so
-- nobody is still on the phone to the fire service: the line is free again.
Ev.OnAttach("fire", function(world)
    reindex(world)
    F.InvalidateCells()
    for _, e in ipairs(Ev.State(world).list) do
        if e.kind == "fire" and e.state ~= "resolved" and e.lotId == world.lot.id then e.data.calling = nil end
    end
end)

---------------------------------------------------------------------------------------------------
-- Interactions.

local function cellFor(world, o)
    local k = o and o.state and o.state.cell
    local c = k and world.lot.fires and world.lot.fires[k]
    if c and c.int > 0 then return c end
end

SS.Interactions.ev_extinguish = {
    label = "Put Out the Fire", category = "Emergency", slot = "fight", pose = "use", advert = {}, manualOnly = true, maxDur = 90,
    risk = { fire = true },
    test = function(world, actor, o)
        if not Ev.IsHuman(actor) then return false, "Only people can fight a fire." end
        if actor.role ~= "firefighter" and (actor.age or "adult") ~= "adult" then return false, "Too young to fight a fire. Get out and get help." end
        if not cellFor(world, o) then return false, "That part of the fire is already out." end
        return true
    end,
    onStart = function(world, actor, act, o)
        if actor.role == "firefighter" or hasExtinguisher(world) then actor.carry = "extinguisher" end
        act.data.ext = hasExtinguisher(world)
    end,
    onTick = function(world, actor, act, o, dt)
        local c = cellFor(world, o)
        if not c then act.complete = true; return end
        local rate
        if actor.role == "firefighter" then rate = FD.ffRate
        else
            local mech = (SS.Skills and SS.Skills.Level and SS.Skills.Level(actor, "mechanical")) or 0
            rate = (FD.residentRate + FD.residentSkill * mech) * (act.data.ext and FD.extinguisherBonus or 1)
        end
        c.int = c.int - rate * dt
        c.foughtAt = world.time
        if actor.role ~= "firefighter" then
            act.data.acc = (act.data.acc or 0) + dt
            while act.data.acc >= 1 and actor.act == act do
                act.data.acc = act.data.acc - 1
                local mech = (SS.Skills and SS.Skills.Level and SS.Skills.Level(actor, "mechanical")) or 0
                local chance = FD.catchChance * max(0, c.int) * (1 - mech / 12) * (act.data.ext and 0.5 or 1)
                if SS.Random(world, "fire") < chance then F.CatchFire(world, actor); return end
            end
        end
        if c.int <= 0 then c.int = 0; act.complete = true; reindex(world) end
    end,
    onEnd = function(world, actor, act, o, status)
        if actor.role ~= "firefighter" then actor.carry = nil end
        if status == "done" and actor.role ~= "firefighter" and SS.Skills and SS.Skills.Gain then
            Ev.Call(SS.Skills.Gain, world, actor, "mechanical", 0.05)
        end
    end,
    next = function(world, actor, act, o)
        if IDX.n == 0 then return nil end
        if actor.role ~= "firefighter" and not F.CanFight(world, actor) then return nil end
        local c = nearestCell(world, actor)
        if c and c.flames and world.lot.objects[c.flames] then
            return { oid = c.flames, iid = "ev_extinguish", manual = true, data = { source = "events", ev = act.data.ev } }
        end
    end,
}

SS.Interactions.ev_panic = {
    label = "Panicking", category = "Other", pose = "panic", advert = {}, manualOnly = true, maxDur = 10,
    onTick = function(world, actor, act, o, dt)
        if act.t + dt >= (act.data.len or 2) then act.complete = true end
    end,
}

SS.Interactions.ev_on_fire = {
    label = "On Fire!", category = "Other", pose = "panic", advert = {}, manualOnly = true, maxDur = 30,
}

SS.Interactions.ev_call_fire = {
    label = "Call the Fire Service", category = "Emergency", pose = "phone", carry = "phone", advert = {}, manualOnly = true, dur = 1.5,
    onStart = function(world, actor) actor.carry = "phone" end,
    onEnd = function(world, actor, act, o, status)
        actor.carry = nil
        if status == "done" then
            local e = Ev.Find(world, act.data.ev) or F.Event(world)
            if e then
                F.CallService(world, e, "phone", actor)
                if e.data.calling == actor.id then e.data.calling = nil end
            end
        end
    end,
}

local function clearedBy(world, actor, o, text)
    local e = o.state and o.state.ev and Ev.Find(world, o.state.ev)
    Ev.RemoveObject(world, world.lot, o.id)
    if e and text then Ev.Journal(world, text, e, { actor.id }) end
end

SS.Interactions.ev_clear_charred = {
    label = "Clear Away", category = "Chores", slot = "near", pose = "clean", carry = "trash_bag", dur = FD.clearMinutes,
    gain = { hygiene = -10 }, advert = { room = 30 },
    onStart = function(world, actor) actor.carry = "trash_bag" end,
    onEnd = function(world, actor, act, o, status)
        actor.carry = nil
        if status == "done" and o then clearedBy(world, actor, o, actor.name .. " cleared away the charred remains.") end
    end,
}

SS.Interactions.ev_sell_charred = {
    label = "Sell for Scrap", category = "Chores", slot = "near", pose = "use", dur = 2, advert = {}, manualOnly = true,
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        SS.Money(world, FD.scrapValue, "sale", "Charred remains sold for scrap")
        clearedBy(world, actor, o, actor.name .. " had the charred remains hauled off for scrap (" .. SS.U.fmtMoney(FD.scrapValue) .. ").")
    end,
}

SS.Interactions.ev_scrub_scorch = {
    label = "Scrub the Scorch Marks", category = "Chores", slot = "near", pose = "clean", dur = FD.scrubMinutes,
    gain = { hygiene = -6 }, advert = { room = 15 },
    onEnd = function(world, actor, act, o, status)
        if status == "done" and o then clearedBy(world, actor, o, actor.name .. " scrubbed the scorch marks off the floor.") end
    end,
}

---------------------------------------------------------------------------------------------------
-- Firefighters (visitors framework role).

local function hoseTarget(world, a)
    local ai, aj, al = Ev.CellOf(a)
    local dist, list = Ev.Flood(world, al, ai, aj, a)
    local best, bd
    local live = sortedCells(world.lot, true)
    for _, cell in ipairs(list) do
        for n = 1, #live do
            local c = live[n]
            if c.level == al and c.int > 0 then
                local d = Ev.Dist(cell[1], cell[2], c.i, c.j)
                if d <= FD.hoseRange and (not bd or cell[3] < bd) then best, bd = cell, cell[3] end
            end
        end
    end
    return best
end

local function hose(world, a, dt)
    local ai, aj, al = Ev.CellOf(a)
    local hit, out = false, false
    local live = sortedCells(world.lot, true)
    for n = 1, #live do
        local c = live[n]
        if c.int > 0 and c.level == al and Ev.Dist(ai, aj, c.i, c.j) <= FD.hoseRange then
            c.int = c.int - FD.ffRate * dt
            c.foughtAt = world.time
            if c.int <= 0 then c.int, out = 0, true end
            hit = true
            a.facing = SS.Grid.dirToFacing(c.i - ai, c.j - aj)
            break
        end
    end
    if hit then a.pose = "use"; a.roleData.spraying = world.time end
    if out then reindex(world) end    -- only when a cell stopped burning (the index does not hold intensities)
    return hit
end

function F.FirefighterTick(world, a, dt)
    local rd = a.roleData or {}
    a.roleData = rd
    if rd.phase == "leaving" then return end
    rd.phase = rd.phase or "work"
    a.carry = "extinguisher"
    if IDX.n > 0 then
        rd.phase = "work"
        if a.act and a.act.iid == "ev_extinguish" then return end
        if a.queue and #a.queue > 0 then return end
        if rd.hose and not (a.act and a.act.iid == "goto") and hose(world, a, dt) then return end
        if a.act or world.time < (rd.nextOrder or -1e9) then return end
        rd.nextOrder = world.time + 1
        if rd.hose then
            local t = hoseTarget(world, a)
            if t then
                SS.Actions.Order(world, a, nil, "goto", t[1], t[2], { level = a.level or 0, manual = true, data = { source = "events" } })
            else
                rd.tries = (rd.tries or 0) + 1
            end
        else
            local c = nearestCell(world, a)
            if c and c.flames and world.lot.objects[c.flames] then
                SS.Actions.Order(world, a, c.flames, "ev_extinguish", nil, nil, { manual = true, data = { source = "events", ev = rd.eventId } })
            else
                rd.hose = true
            end
        end
        if (rd.tries or 0) >= FD.maxTries then
            local e = Ev.Find(world, rd.eventId)
            if e and Ev.Once(e, "unreachable", world) then Ev.Journal(world, "The firefighters could not reach the fire and had to let it burn out.", e) end
            Ev.SendAway(world, a, "unreachable")
        end
        return
    end
    -- nothing burning: check the scene, then leave
    if rd.phase ~= "inspect" then
        rd.phase = "inspect"
        rd.inspectUntil = world.time + FD.inspectMinutes
        if a.act then SS.Actions.Finish(world, a, "done") end
    end
    a.pose = "use"
    if world.time >= (rd.inspectUntil or 0) then
        local e = Ev.Find(world, rd.eventId)
        if e and Ev.Once(e, "ffleft", world) then
            Ev.Journal(world, "The firefighters checked for hot spots and left.", e)
        end
        Ev.SendAway(world, a, "done")
    end
end

SS.On("actionEnded", function(actor, act, status)
    if not act or actor.role ~= "firefighter" or status ~= "failed" then return end
    local rd = actor.roleData
    if not rd then return end
    rd.tries = (rd.tries or 0) + 1
    if rd.tries >= 2 then rd.hose = true end
end)

if SS.Visitors and SS.Visitors.RegisterRole then
    SS.Visitors.RegisterRole("firefighter", {
        label = "Firefighter", noNeeds = true, access = "emergency", useAutonomy = false, uniform = "firefighter",
        outfit = "firefighter", pool = "firefighter", vehicle = "fire_truck",
        onArrive = function(world, a)
            a.outfit = "firefighter"
            a.carry = "extinguisher"
            a.roleData = a.roleData or {}
            a.roleData.phase = "work"
            local e = Ev.Find(world, a.roleData.eventId)
            if e and Ev.Once(e, "ffarrived", world) then
                Ev.Journal(world, "The fire service arrived.", e)
                Ev.Tell(world, a, "Fire service! Everybody out, we've got this.", "alert")
            end
        end,
        onLeave = function(world, a) a.carry = nil; Ev.ClearVehicle(a.id) end,
        tick = function(world, a, dt) F.FirefighterTick(world, a, dt) end,
    })
end

-- Firefighters only come while the fire is still burning.
Ev.arrivals.firefighter = function(world, e) return e.state == "active" and world.lot.fires ~= nil and next(world.lot.fires) ~= nil end

---------------------------------------------------------------------------------------------------
-- Fireplaces (tag "fireplace"): light and put out; sparks can reach flammable things in front.

SS.Interactions.ev_light_fire = {
    label = "Light the Fire", category = "Home", pose = "use", dur = 2, advert = {}, manualOnly = true, requireState = { lit = false },
    test = function(world, actor, o)
        if (actor.age or "adult") ~= "adult" then return false, "Grown-ups light the fire." end
        if o.state and (o.state.broken or o.state.burnt) then return false, "The fireplace needs repairing first." end
        return true
    end,
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        o.state = o.state or {}
        o.state.lit, o.state.litAt = true, world.time
        SS.Emit("lotChanged", "state", o.id)
    end,
}
SS.Interactions.ev_douse_fire = {
    label = "Put Out the Hearth", category = "Home", pose = "use", dur = 1, advert = {}, manualOnly = true, requireState = { lit = true },
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        o.state.lit, o.state.litAt = nil, nil
        SS.Emit("lotChanged", "state", o.id)
    end,
}
SS.Tags.Attach("fireplace", "ev_light_fire")
SS.Tags.Attach("fireplace", "ev_douse_fire")

-- Cells in front of a fireplace within reach, with the flammable objects on them.
function F.HearthRisks(world, o)
    local out = {}
    local map = cellMap(world)
    for r = 1, FP.reach do
        local dx, dy = SS.Grid.rot(0, r, o.f or 0)
        local i, j = o.x + dx, o.y + dy
        for _, t in ipairs(map[cellIdx(o.level or 0, i, j)] or NONE) do
            if F.Risk(SS.Objects[t.def]) >= FP.minRisk then out[#out + 1] = t end
        end
        local fl = SS.World.FloorAt(world.lot, o.level or 0, i, j)
        if fl and floorFuel(world.lot, o.level or 0, i, j) >= FD.floorFuel.carpet then out[#out + 1] = { floorCell = { i, j } } end
    end
    return out
end

Ev.OnHour("fireplace", function(world)
    local lot = world.lot
    local awake = #Ev.Members(world, function(m) return not m.sleeping end) > 0
    for _, oid in ipairs(Ev.SortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and o.state and o.state.lit and Ev.HasTag(def, "fireplace") then
            if world.time - (o.state.litAt or world.time) >= FP.burnHours * 60 then
                o.state.lit, o.state.litAt = nil, nil
                SS.Emit("lotChanged", "state", oid)
            elseif not F.Active(world) then
                local mult = awake and 1 or FP.unattended
                for _, t in ipairs(F.HearthRisks(world, o)) do
                    if SS.Random(world, "fire") < FP.sparkChance * mult then
                        if t.floorCell then F.Ignite(world, o.level or 0, t.floorCell[1], t.floorCell[2], "fireplace")
                        else F.Ignite(world, o.level or 0, t.x, t.y, "fireplace", t.id) end
                        break
                    end
                end
            end
        end
    end
end, 40)

---------------------------------------------------------------------------------------------------
-- Electrical fires (emergency lane): only where electrics are broken or worn out.
local ELECTRIC = { electronics = true, lighting = true }
local function faultyElectrics(world)
    local out = {}
    for _, oid in ipairs(Ev.SortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and (ELECTRIC[def.cat] or def.powered) and not (o.state and o.state.burnt)
            and ((o.state and o.state.broken) or (o.wear or 0) >= 80) then
            -- a fresh breakdown is not yet a hazard: only electrics left unrepaired for a while
            local rec = o.state and o.state.broken and Ev.ForTarget(world, "breakdown", oid)
            if not rec or world.time - rec.t >= (FD.faultAge or 0) then out[#out + 1] = o end
        end
    end
    return out
end
F.FaultyElectrics = faultyElectrics

Ev.families.electrical_fire = {
    eligible = function(world)
        if F.Active(world) then return false, "already a fire" end
        if #Ev.Members(world) == 0 then return false, "nobody home" end
        if #faultyElectrics(world) == 0 then return false, "no faulty electrics" end
        return true
    end,
    run = function(world)
        local o = SS.Pick(world, "events", faultyElectrics(world))
        if not o then return nil, "no faulty electrics" end
        local e, why = F.Ignite(world, o.level or 0, o.x, o.y, "electrical", o.id)
        if not e then return nil, why end
        return e
    end,
}

---------------------------------------------------------------------------------------------------
-- Effects: flames and smoke per burning cell, burning people, lit hearths, ringing alarms.
local hearths = { lotId = nil, t = -1, list = {} }
Ev.OnEffects(function(world, add)
    local lot = world.lot
    for _, c in pairs(lot.fires or NONE) do
        if c.int > 0 then
            add(c.level, c.i + 0.5, c.j + 0.5, 0, "fire", 0.5 + c.int * 0.7)
            add(c.level, c.i + 0.5, c.j + 0.5, 1.2 + c.int, "smoke", 0.6 + c.int * 0.6)
        end
    end
    -- water from extinguishers and hoses while someone is actually working a burning cell
    if next(lot.fires or NONE) then
        for _, a in pairs(world.actors) do
            local act = a.act
            if (act and act.iid == "ev_extinguish" and act.phase == "perform")
                or (a.roleData and a.roleData.spraying and world.time - a.roleData.spraying <= 1) then
                add(a.level or 0, a.x, a.y, 0.8, "water_spray", 1)
            end
        end
    end
    local people = world.root.events and world.root.events.people
    if people then
        for rid, p in pairs(people) do
            local a = p.onFire and world.actors[rid]
            if a then add(a.level or 0, a.x, a.y, 0.6, "fire", 0.45) end
        end
    end
    if hearths.lotId ~= lot.id or hearths.t ~= floor(world.time / 10) then
        hearths.lotId, hearths.t = lot.id, floor(world.time / 10)
        local l = {}
        for _, o in pairs(lot.objects) do
            local def = SS.Objects[o.def]
            if o.state and ((o.state.lit and def and Ev.HasTag(def, "fireplace")) or o.state.ringing) then l[#l + 1] = o end
        end
        hearths.list = l
    end
    for _, o in ipairs(hearths.list) do
        if o.state and o.state.lit then add(o.level or 0, o.x + 0.5, o.y + 0.5, 0.2, "hearth_fire", 0.6) end
        if o.state and o.state.ringing then add(o.level or 0, o.x + 0.5, o.y + 0.5, 1.8, "alarm_flash", 1) end
    end
end)
SS.On("lotChanged", function() hearths.t = -1 end)

---------------------------------------------------------------------------------------------------
-- Save validation: lot.fires cells, flames objects and object burning flags agree.
SS.Save.RegisterValidator(function(root, p)
    for lotId, lot in pairs(root.hood.lots) do
        if lot.fires ~= nil and type(lot.fires) ~= "table" then lot.fires = nil; p[#p + 1] = "fire state reset on " .. tostring(lotId) end
        local fires = lot.fires or {}
        for k, c in pairs(fires) do
            if type(c) ~= "table" or type(c.i) ~= "number" or type(c.j) ~= "number" or type(c.int) ~= "number" then
                fires[k] = nil
                p[#p + 1] = "dropped a damaged fire cell on " .. tostring(lotId)
            else
                c.level = c.level or 0
                c.fuel = type(c.fuel) == "number" and c.fuel or 0
                c.burned = c.burned or 0
                c.objs = type(c.objs) == "table" and c.objs or {}
                c.t = c.t or root.time
            end
        end
        -- flames objects without a cell go; cells without flames get them back
        local byCell = {}
        for oid, o in pairs(lot.objects) do
            if o.def == "ev_flames" then
                local c = o.state and o.state.cell and fires[o.state.cell]
                if not c or byCell[o.state.cell] then lot.objects[oid] = nil else byCell[o.state.cell] = oid; c.flames = oid end
            end
        end
        for k, c in pairs(fires) do
            if not byCell[k] then
                local field = lot.nextId and "nextId" or "nextObj"
                local n = tonumber(lot[field]) or 1
                local id = "o" .. n
                while lot.objects[id] do n = n + 1; id = "o" .. n end
                lot[field] = n + 1
                lot.objects[id] = { id = id, def = "ev_flames", x = c.i, y = c.j, f = 0, level = c.level, state = { cell = k, ev = c.ev } }
                c.flames = id
            end
        end
        -- stale burning flags
        for _, o in pairs(lot.objects) do
            if o.state and o.state.burning then
                local still = false
                for _, c in pairs(fires) do for _, x in ipairs(c.objs) do if x == o.id then still = true end end end
                if not still then o.state.burning = nil end
            end
        end
    end
    return true
end)
