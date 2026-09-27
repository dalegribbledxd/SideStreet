-- SideStreet street edge: entry cells, sidewalk and curb geometry, vehicles, and walking departures
-- and arrivals. Owner: visitors module (docs/modules/visitors.md).
--
-- The street runs along every lot's j = h edge (ARCHITECTURE.md §6). People step on and off the lot at
-- an entry cell on row h - 1; beyond it lies a two-tile road band: a sidewalk line at y = h + 0.3, the
-- curb at y = h + 0.7 and the near traffic lane at y = h + 1.25 (Data/Roles.lua tuning.geometry).
-- Off-lot movement (sidewalk and curb) is a straight walk handled here; on-lot movement always goes
-- through the shared executor ("goto") so doors, stairs, permissions and waiting rules apply.
--
-- SS.Street.vehicles is the runtime list the renderer draws. Each entry:
--   { id, kind, i (parking column), x (current centre along the street, tiles), y (lane), dir = 1|-1,
--     state = "arriving" | "parked" | "leaving", t (sim minutes in this state), len (tiles),
--     livery?, owner?, label?, expect (riders to board), boarded = {rid...}, passengers = {rid...} }
-- Vehicles arrive, wait a bounded time and leave. The list is runtime only: it is rebuilt on attach
-- from saved visitor state, and other modules re-request their own vehicles after a load.
local _, SS = ...
local RD = SS.RoleData
local TUN = RD.tuning
local GEO, VT = TUN.geometry, TUN.vehicle
local W, G = SS.World, SS.Grid
local St = SS.Street or {}
SS.Street = St
St.vehicles = St.vehicles or {}
St.stats = { vehicles = 0, departures = 0, arrivals = 0, missed = 0, boarded = 0 }
local nextVid = 0

---------------------------------------------------------------------------------------------------
-- Geometry
function St.SidewalkY(world) return world.lot.h + GEO.sidewalk end
function St.CurbPos(world, i) return i + 0.5, world.lot.h + GEO.curb end
function St.LaneY(world) return world.lot.h + GEO.lane end
function St.SidewalkEnds(world) return -GEO.sidewalkEnd, world.lot.w + GEO.sidewalkEnd end
function St.IsOffLot(world, x, y)
    local lot = world.lot
    return x < 0 or y < 0 or x >= lot.w or y >= lot.h
end

-- Walkable boundary cells on row h - 1 whose edge to the street is open (no wall/fence; gates are
-- openings), preferred order: lot.entry's column first, then nearest to it. Cached per rebuild.
local entryCache = {}
local function edgeOpen(lot, i)
    local wl = W.WallAt(lot, 0, G.edgeBetween(i, lot.h - 1, i, lot.h))
    return (not wl) or (W.OPENINGS[wl.kind] and not wl.locked) and true or false
end
function St.EntryCells(world)
    local lot = world.lot
    if entryCache.rt == SS.RT and entryCache.lot == lot and entryCache.ver == lot.version and entryCache.n == lot.nextId then
        return entryCache.list
    end
    local list = {}
    local j = lot.h - 1
    local pref = (lot.entry and lot.entry[1]) or math.floor(lot.w / 2)
    for i = 0, lot.w - 1 do
        if not W.Blocked(world, 0, i, j) and edgeOpen(lot, i) then list[#list + 1] = { i, j, 0 } end
    end
    table.sort(list, function(a, b)
        local da, db = math.abs(a[1] - pref), math.abs(b[1] - pref)
        if da ~= db then return da < db end
        return a[1] < b[1]
    end)
    entryCache.rt, entryCache.lot, entryCache.ver, entryCache.n, entryCache.list = SS.RT, lot, lot.version, lot.nextId, list
    return list
end
function St.InvalidateEntry() entryCache.rt = nil end

-- The lot's street entry. Returns i, j and `blocked` (true when no boundary cell is usable; the
-- returned cell is then lot.entry or the middle of row h - 1, kept for stub compatibility).
function St.EntryCell(world)
    local list = St.EntryCells(world)
    if list[1] then return list[1][1], list[1][2], false end
    local lot = world.lot
    if lot.entry then return lot.entry[1], lot.entry[2], true end
    return math.floor(lot.w / 2), lot.h - 1, true
end

---------------------------------------------------------------------------------------------------
-- Straight off-lot walking along waypoints in actor.tmp.wp (runtime). Returns true on arrival.
function St.SetPath(actor, wp)
    actor.tmp = actor.tmp or {}
    actor.tmp.wp, actor.tmp.wpi = wp, 1
end
function St.FollowPath(world, actor, dt)
    local tmp = actor.tmp
    local wp = tmp and tmp.wp
    if not wp then return true end
    local dist = SS.Tuning.walkSpeed * dt
    local k = tmp.wpi or 1
    while dist > 1e-9 and wp[k] do
        local p = wp[k]
        local dx, dy = p[1] - actor.x, p[2] - actor.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d > 1e-4 then actor.facing = G.dirToFacing(dx, dy) end
        if d <= dist then
            actor.x, actor.y = p[1], p[2]
            dist = dist - d
            actor.stride = (actor.stride or 0) + d
            k = k + 1
        else
            actor.x, actor.y = actor.x + dx / d * dist, actor.y + dy / d * dist
            actor.stride = (actor.stride or 0) + dist
            dist = 0
        end
    end
    tmp.wpi = k
    if wp[k] then actor.pose, actor.walking = "walk", true; return false end
    tmp.wp, tmp.wpi = nil, nil
    actor.pose, actor.walking = "idle", nil
    return true
end

-- From an off-lot position (curb, vehicle, sidewalk) onto the entry cell. nil when no entry is usable.
function St.ArrivalPath(world, actor)
    local ei, ej, blocked = St.EntryCell(world)
    if blocked then return nil end
    local sy = St.SidewalkY(world)
    local ex = ei + 0.5
    local wp = {}
    if actor.y > sy + 0.05 then wp[#wp + 1] = { actor.x, sy } end
    if math.abs(actor.x - ex) > 0.05 then wp[#wp + 1] = { ex, sy } end
    wp[#wp + 1] = { ex, ej + 0.5 }
    return wp
end

-- From the entry cell off the lot. target: { kind = "vehicle", i = column } | { kind = "curb" } |
-- { kind = "end", side = -1 | 1 } (walk along the sidewalk and off the view).
function St.ExitPath(world, actor, target)
    local sy = St.SidewalkY(world)
    local wp = { { actor.x, sy } }
    if target.kind == "vehicle" then
        local cx, cy = St.CurbPos(world, target.i)
        wp[#wp + 1] = { cx, sy }
        wp[#wp + 1] = { cx, cy }
    elseif target.kind == "curb" then
        local cx, cy = St.CurbPos(world, math.floor(actor.x))
        wp[#wp + 1] = { cx, cy }
    else
        local l, r = St.SidewalkEnds(world)
        wp[#wp + 1] = { (target.side or 1) < 0 and l or r, sy }
    end
    return wp
end

-- Walk-by path along the sidewalk from one end to the other (side = where they start).
function St.PassPath(world, side)
    local sy = St.SidewalkY(world)
    local l, r = St.SidewalkEnds(world)
    if side < 0 then return { l, sy }, { { r, sy } } end
    return { r, sy }, { { l, sy } }
end

---------------------------------------------------------------------------------------------------
-- Vehicles
function St.VehicleById(id)
    if not id then return nil end
    for n = 1, #St.vehicles do if St.vehicles[n].id == id then return St.vehicles[n] end end
end

local function spotFree(i, len, except)
    for n = 1, #St.vehicles do
        local v = St.vehicles[n]
        if v ~= except and v.state ~= "leaving" and math.abs((v.i or 0) - i) < ((v.len or 2) + len) / 2 then return false end
    end
    return true
end

-- A free curb spot for a vehicle of length len, as close as possible to `prefer` (default: entry).
function St.ParkSpot(world, len, prefer)
    local w = world.lot.w
    local base = prefer or (St.EntryCell(world))
    for k = 0, 2 * w do
        local off = (k % 2 == 1) and math.ceil(k / 2) or -(k / 2)
        local i = base + off
        if i >= 0 and i <= w - 1 and spotFree(i, len) then return i end
    end
    return base
end

local function normalize(world, v)
    if v.id then return end
    nextVid = nextVid + 1
    local info = RD.vehicles[v.kind] or {}
    v.id = nextVid
    v.i = v.i or (St.EntryCell(world))
    v.x = v.x or v.i
    v.y = v.y or St.LaneY(world)
    v.dir = v.dir or 1
    v.len = v.len or info.len or 2
    v.state = v.state or "parked"
    v.t = v.t or 0
    v.wait = math.min(v.wait or VT.wait, VT.maxWait)
    v.expect = v.expect or 0
    v.boarded = v.boarded or {}
    v.passengers = v.passengers or {}
end

-- Call a vehicle to this lot's curb. opts: { owner, wait (max minutes parked), expect (riders to
-- board), passengers = {rid...} (riders who get out), hold (stay until released), livery, i, dir,
-- parked (appear already parked: used when rebuilding after a load) }. Returns the vehicle, or nil
-- when the street is full (a hard cap; callers then walk people in from the sidewalk).
function St.CallVehicle(world, kind, opts)
    opts = opts or {}
    if #St.vehicles >= VT.cap * 2 then return nil, "The street is full of vehicles." end
    local info = RD.vehicles[kind] or {}
    local len = opts.len or info.len or 2
    nextVid = nextVid + 1
    local i = St.ParkSpot(world, len, opts.i)
    local dir = opts.dir or ((nextVid % 2 == 0) and -1 or 1)
    local v = {
        id = nextVid, kind = kind, i = i, dir = dir, len = len, livery = opts.livery, label = info.label,
        state = opts.parked and "parked" or "arriving", t = 0,
        x = opts.parked and i or (i - dir * VT.travel), y = St.LaneY(world),
        owner = opts.owner, wait = math.min(opts.wait or VT.wait, VT.maxWait), hold = opts.hold,
        expect = opts.expect or 0, boarded = {}, passengers = opts.passengers or {},
    }
    St.vehicles[#St.vehicles + 1] = v
    St.stats.vehicles = St.stats.vehicles + 1
    if not opts.parked and SS.Audio and SS.Audio.Sfx then SS.Audio.Sfx(RD.sfx.arrive) end
    SS.Emit("vehicleArriving", world, v)
    return v
end

-- Let a held vehicle go (it leaves once parked).
function St.ReleaseVehicle(world, v)
    if not v then return end
    v.hold, v.release = nil, true
end

-- One rider gets in (called when a departing person reaches the curb beside the vehicle).
function St.BoardOne(world, v, actor)
    if not v or v.state == "leaving" then return false end
    v.boarded[#v.boarded + 1] = actor.id
    St.stats.boarded = St.stats.boarded + 1
    return true
end

local function missing(v)
    if not v.expectRids then return {} end
    local got = {}
    for _, rid in ipairs(v.boarded) do got[rid] = true end
    local out = {}
    for _, rid in ipairs(v.expectRids) do if not got[rid] then out[#out + 1] = rid end end
    return out
end

local function startLeaving(world, v)
    v.state, v.t = "leaving", 0
    if SS.Audio and SS.Audio.Sfx then SS.Audio.Sfx(RD.sfx.leave) end
    if v.boardReason then SS.Emit("streetBoarded", world, v, v.boarded, v.boardReason, v.boardData) end
    local miss = missing(v)
    if #miss > 0 then St.stats.missed = St.stats.missed + #miss end
    SS.Emit("vehicleLeft", world, v, miss)
end

-- Riders a vehicle waits for who can no longer come (taken off the lot, away, dead) are dropped, so
-- it leaves as soon as everyone still coming is aboard instead of idling to its time limit.
local function dropAbsent(world, v)
    local list = v.expectRids
    if not list or #list == 0 then return end
    local n = #list
    while n >= 1 do
        local rid = list[n]
        local a = world.actors[rid]
        if not a or a.away or a.dead then
            local aboard = false
            for _, b in ipairs(v.boarded) do if b == rid then aboard = true; break end end
            if not aboard then
                table.remove(list, n)
                v.expect = math.max(0, (v.expect or 0) - 1)
                v.dropped = (v.dropped or 0) + 1
            end
        end
        n = n - 1
    end
end
St.DropAbsent = dropAbsent

-- Advance every vehicle (arriving -> parked -> leaving -> removed). Bounded: a parked vehicle never
-- waits longer than its wait time (tuning.vehicle.maxWait at most).
function St.Tick(world, dt)
    local list = St.vehicles
    local n = 1
    while n <= #list do
        local v = list[n]
        normalize(world, v)
        v.t = v.t + dt
        local remove = false
        if v.state == "arriving" then
            local step = VT.travel / VT.arrive * dt
            local d = v.i - v.x
            if math.abs(d) <= step then
                v.x, v.state, v.t = v.i, "parked", 0
                SS.Emit("vehicleParked", world, v)
            else
                v.x = v.x + (d > 0 and step or -step)
            end
        elseif v.state == "parked" then
            if v.expectRids and #v.boarded < (v.expect or 0) then dropAbsent(world, v) end
            local go
            if v.release then go = true
            elseif v.t >= v.wait then go = true
            elseif v.hold then go = false
            elseif v.expect > 0 then go = #v.boarded >= v.expect and v.t >= VT.boardGrace
            else go = v.t >= VT.boardGrace end
            if go then startLeaving(world, v) end
        elseif v.state == "leaving" then
            v.x = v.x + v.dir * VT.travel / VT.leave * dt
            if math.abs(v.x - v.i) >= VT.travel then remove = true end
        end
        if remove then
            table.remove(list, n)
            SS.Emit("vehicleGone", world, v)
        else
            n = n + 1
        end
    end
end

function St.Clear()
    for n = #St.vehicles, 1, -1 do St.vehicles[n] = nil end
end

---------------------------------------------------------------------------------------------------
-- Departures and arrivals of residents (work, school, outings, going home).

-- Send an actor off the lot. They walk to the entry and the curb (boarding `data.vehicle` when
-- given: a vehicle id or a kind to call) and are then removed with away = { reason, untilT, data,
-- lotId }. `returnAt` schedules their walk-in on this lot's clock ("street.return"). data.immediate
-- removes them at once (the pre-integration behaviour). Emits "streetDeparted"(world, actor, reason,
-- data) on removal and "streetMissed"(world, actor, reason, data) if their vehicle left without them.
function St.Depart(world, actor, reason, returnAt, data)
    data = data or {}
    if returnAt then
        -- the walk back in is a required timer: if the visitor timer queue refuses it (full), the
        -- core scheduler carries it instead, so nobody is ever left away for good
        local ev = { rid = actor.id, reason = reason, vehicle = data.returnVehicle }
        local ok = SS.Visitors.After and SS.Visitors.After(world, returnAt, "street.return", ev, world.lot.id)
        if not ok then SS.Sim.Schedule(world, returnAt, "street.return", ev, world.lot.id) end
    end
    local away = { reason = reason, untilT = returnAt, data = data, lotId = world.lot.id }
    if data.immediate or not world.actors[actor.id] or not SS.Visitors.BeginDeparture then
        St.FinishDeparture(world, actor, away)
        return true
    end
    local v
    if type(data.vehicle) == "number" then v = St.VehicleById(data.vehicle)
    elseif type(data.vehicle) == "string" then
        v = St.CallVehicle(world, data.vehicle, { owner = "depart:" .. actor.id, expect = 1, wait = data.wait })
        if v then v.expectRids = { actor.id } end
    end
    SS.Visitors.BeginDeparture(world, actor, away, v)
    return true
end

-- The walk out is over: the internal "departing" role ends (a role another module gave them, such
-- as a pet's, comes back) and they leave the lot with `away`. Any other role is left alone.
function St.FinishDeparture(world, actor, away)
    if actor.role == "departing" then
        local vs = actor.roleData and actor.roleData.vs
        if SS.Visitors.RestorePrevRole then SS.Visitors.RestorePrevRole(actor, vs) else actor.role, actor.roleData = nil, nil end
    end
    if actor.tmp then actor.tmp.offLot, actor.tmp.wp = nil, nil end
    SS.Sim.RemoveActor(world, actor.id, away)
    St.stats.departures = St.stats.departures + 1
    SS.Emit("streetDeparted", world, actor, away and away.reason, away and away.data)
end

-- Bring a resident onto the lot: they appear at the curb (or step out of `opts.vehicle`, a kind) and
-- walk onto the entry cell. opts.immediate places them on the entry cell at once. Returns the actor.
function St.Arrive(world, rid, opts)
    opts = opts or {}
    local r = world.root.residents[rid]
    if not r or (r.dead and not r.ghost) then return nil end
    if world.actors[rid] then return world.actors[rid] end
    if opts.immediate or not (SS.Visitors and SS.Visitors.BeginArrival) then
        local i, j = St.EntryCell(world)
        r.away = nil
        local a = SS.Sim.AddActor(world, rid, i, j, 0)
        if a then St.stats.arrivals = St.stats.arrivals + 1; SS.Emit("streetArrived", world, a, opts.reason) end
        return a
    end
    return SS.Visitors.BeginArrival(world, rid, opts)
end

-- Several residents come home in one vehicle (a taxi back from an outing): it parks, they step out
-- at the curb and walk in. Returns the arriving actors, the vehicle (nil when the street is full or
-- opts.immediate) and why there is no vehicle.
function St.ArriveGroup(world, rids, kind, opts)
    opts = opts or {}
    local v, why
    if not opts.immediate then
        v, why = St.CallVehicle(world, kind or "taxi", { owner = "arrive:" .. tostring(opts.reason), passengers = rids, wait = 10 })
    end
    local out = {}
    for n = 1, #rids do
        -- without a vehicle (street full) they still walk in from the curb
        local a = St.Arrive(world, rids[n], { vehicleId = v and v.id, reason = opts.reason, immediate = opts.immediate })
        if a then out[#out + 1] = a end
    end
    return out, v, why
end

-- Several residents walk out to one vehicle (a taxi for an outing). vehicle: a vehicle or a kind.
-- When the vehicle leaves, "streetBoarded"(world, v, boardedRids, reason, data) fires; riders who did
-- not make it are listed by "vehicleLeft"(world, v, missing). Returns the vehicle or nil, why.
-- Only riders who are on the lot now are waited for (anyone away, dead or elsewhere is left out);
-- with nobody to board, no vehicle is called. Returns the vehicle or nil, why, and the riders left out.
function St.Board(world, rids, vehicle, reason, data)
    local present, absent = {}, {}
    for n = 1, #rids do
        local a = world.actors[rids[n]]
        if a and not a.away and not a.dead then present[#present + 1] = rids[n] else absent[#absent + 1] = rids[n] end
    end
    if #present == 0 then
        if type(vehicle) == "table" then St.ReleaseVehicle(world, vehicle) end
        return nil, "Nobody who should ride is here.", absent
    end
    local v = vehicle
    if type(v) ~= "table" then
        v = St.CallVehicle(world, vehicle or "taxi", { owner = "board:" .. tostring(reason), wait = 60 })
    end
    if not v then return nil, "No vehicle could reach the curb.", absent end
    v.expect = #present
    v.expectRids = {}
    for n = 1, #present do v.expectRids[n] = present[n] end
    v.boardReason, v.boardData = reason, data
    for n = 1, #present do
        St.Depart(world, world.actors[present[n]], reason, nil, { vehicle = v.id, group = true, data = data })
    end
    return v, nil, absent
end

-- Is anyone still walking out or in? (reason optional)
function St.Pending(world, reason)
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if (a.role == "departing" or a.role == "arriving") then
            local vs = a.roleData and a.roleData.vs
            if not reason or (vs and vs.away and vs.away.reason == reason) then return true end
        end
    end
    return false
end

-- A scheduled return: the resident walks back in unless they are already somewhere (or dead).
function St.HandleReturn(world, d)
    local r = d and world.root.residents[d.rid]
    if r and not r.dead and not r.lotId then
        r.away = nil
        return St.Arrive(world, d.rid, { vehicle = d.vehicle, reason = d.reason })
    end
end
SS.On("scheduled", function(ev, world)
    if ev.kind == "street.return" and world then St.HandleReturn(world, ev.data) end
end)

-- Vehicles are runtime only: cleared on attach (visitors re-request theirs in their reconcile) and detach.
SS.Sim.Register({ name = "street", order = 38, tick = St.Tick,
    attach = function() St.Clear(); St.InvalidateEntry() end,
    detach = function() St.Clear() end })
