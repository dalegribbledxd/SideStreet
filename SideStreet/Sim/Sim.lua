-- SideStreet simulation driver: clock, speeds, bounded sub-stepping, scheduler.
-- Runs only while the game window is open (the UI drives Sim.Update from OnUpdate).
local _, SS = ...
local T = SS.Tuning
local Sim = {}
SS.Sim = Sim

Sim.world = nil
Sim.perf = { steps = 0, lastMs = 0 }

-- A session is the view of the save root that the simulation runs against: the active
-- lot, its household and the residents present on it. Reads of root-level keys (time,
-- settings, ...) and household keys (money, ledger, journal) are forwarded, and so are
-- writes, so the saved data stays in one place and nothing is duplicated.
local ROOT_KEYS = { time = true, speed = true, lastSpeed = true, settings = true, seed = true, scheduled = true,
    schema = true, hood = true, households = true, residents = true, active = true }
local HH_KEYS = { money = true, ledger = true, journal = true }

-- householdId: the household being played here. Defaults to the lot's owner, else the
-- active household (a visiting household on a community lot).
function Sim.NewSession(root, lotId, householdId)
    local lot = root.hood.lots[lotId]
    assert(lot, "SideStreet: unknown lot " .. tostring(lotId))
    local hh = householdId and root.households[householdId]
    if not hh then
        for _, h in pairs(root.households) do if h.lotId == lotId then hh = h end end
    end
    if not hh and root.active then hh = root.households[root.active.householdId] end
    -- The clock: normally root.time. During an outing (root.outing, owned by the travel module)
    -- the community lot runs on root.outing.time and the home clock stays frozen.
    local clock = (root.outing and root.outing.lotId == lotId) and root.outing or root
    local S = { root = root, lot = lot, household = hh, actors = {}, clock = clock }
    for rid, r in pairs(root.residents) do
        if r.lotId == lotId and not r.dead then S.actors[rid] = r end
    end
    return setmetatable(S, {
        __index = function(_, k)
            if k == "time" then return clock.time end
            if HH_KEYS[k] then return hh and hh[k] end
            return root[k]
        end,
        __newindex = function(t, k, v)
            if k == "time" then
                clock.time = v
            elseif HH_KEYS[k] then
                if hh then hh[k] = v end
            elseif ROOT_KEYS[k] then
                root[k] = v
            else
                rawset(t, k, v)
            end
        end,
    })
end

local function runDetach(w)
    for _, sys in ipairs(Sim.systems) do
        if sys.detach then sys.detach(w) end
    end
end

-- Run the attached session's detach hooks and forget it. A household switch detaches first (the
-- hooks still see the old household's clock and root.active), changes clocks, then attaches.
-- Sim.Update steps nothing until the next Attach. (Hood calls this when it exists: hood's HC-1.)
function Sim.Detach()
    local w = Sim.world
    if not w then return end
    runDetach(w)
    Sim.world, Sim.order, Sim.orderN, Sim.orderWorld = nil, nil, nil, nil
end

-- Attach a save root (or reattach an existing session): object states, derived caches,
-- runtime fields, and in-progress actions resumed from their saved mirrors (`doing`, `orders`).
-- Returns the session.
function Sim.Attach(root, lotId, householdId)
    if root.root then root = root.root end
    root.scheduled = root.scheduled or {}
    Sim.OrderQueue(root.scheduled)
    lotId = lotId or (root.active and root.active.lotId)
    if Sim.world then runDetach(Sim.world) end
    local world = Sim.NewSession(root, lotId, householdId)
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        o.level = o.level or 0
        if not o.state and def and def.startState then o.state = SS.U.deepcopy(def.startState) end
        o.res, o.watchers, o.tmp = nil, nil, nil
        if o.state and def and def.viewer then o.state.on = false end
        if o.state then
            o.state.occupied = nil
            -- looks that last only while someone uses the thing (a resumed use sets them again):
            -- a running tap or shower, a combo shower's spray, an open fridge or dishwasher door.
            -- A number in state.water is a garden object's moisture (family), not a tap.
            if o.state.water == true then o.state.water = nil end
            if o.state.open == true then o.state.open = nil end
            if o.state.on and def and SS.Tags.Has(def, "bath") and SS.Tags.Has(def, "shower") then o.state.on = nil end
        end
    end
    SS.World.Rebuild(world)
    SS.Actions.privacy = {}
    local ids = {}
    for id in pairs(world.actors) do ids[#ids + 1] = id end
    table.sort(ids)
    for n, id in ipairs(ids) do
        local a = world.actors[id]
        a.act, a.sleeping, a.walking, a.onObj, a.pose, a.cool, a.lastThink, a.stride = nil, nil, nil, nil, "idle", nil, nil, nil
        a.level, a.z = a.level or 0, nil
        a.nextThink = world.time + (n - 1) * T.thinkSpread
        SS.Needs.Clamp(a)
    end
    -- resume actions in a deterministic order (reservations are rebuilt here, never loaded)
    for _, id in ipairs(ids) do
        local a = world.actors[id]
        local ok, resumed = pcall(SS.Actions.Resume, world, a)
        if not ok then
            SS.Log("Could not resume %s's action: %s", tostring(id), tostring(resumed))
            a.act, a.doing, a.queue, a.orders = nil, nil, {}, nil
            a.orders = a.queue
        end
    end
    for _, id in ipairs(ids) do
        local a = world.actors[id]
        -- recover an actor standing inside a solid cell (e.g. the layout changed): nearest free cell
        -- (someone out on the street, off the lot, belongs to the street/visitor code: left alone)
        local i, j = math.floor(a.x), math.floor(a.y)
        local street = not SS.World.InLot(world.lot, i, j) or (a.tmp and (a.tmp.offLot or a.tmp.wp or a.tmp.inVehicle))
        if not a.onObj and not street and SS.World.Blocked(world, a.level, i, j) then
            local ni, nj = SS.Nav.NearestFree(world, a.level, i, j, nil, nil, true)
            if not ni and a.level > 0 then a.level = 0; ni, nj = SS.Nav.NearestFree(world, 0, i, j, nil, nil, true) end
            if ni then
                a.x, a.y = ni + 0.5, nj + 0.5
                SS.Log("Recovered %s from a blocked cell to %d,%d", a.id, ni, nj)
            end
        end
    end
    Sim.root, Sim.world = root, world
    Sim.order, Sim.orderN = nil, nil
    Sim.lotDirty = false
    for _, sys in ipairs(Sim.systems) do
        if sys.attach then sys.attach(world) end
    end
    -- What someone holds (actor.held) is household-core state, and its prop follows from it. A
    -- system that puts stray props away on attach cannot leave a held plate unseen in a resumed meal.
    local propFor = SS.Chains and SS.Chains.PropFor
    if propFor then
        for _, id in ipairs(ids) do
            local a = world.actors[id]
            if a and a.held then a.carry = propFor(a.held) or a.carry end
        end
    end
    -- route search scratch, edge keys, reachability and lock maps are built now, at load, not by
    -- the first searches during play
    SS.Nav.Prepare(world)
    SS.Emit("worldAttached", world)
    return world
end

-- Bring a resident (household member, townie, visitor, service worker, pet) onto this lot
-- at cell (i, j, level). The record lives in root.residents; world.actors indexes it.
function Sim.AddActor(world, rid, i, j, level)
    local r = world.root.residents[rid]
    if not r or r.dead and not r.ghost then return nil end
    r.lotId = world.lot.id
    r.x, r.y, r.level, r.z = i + 0.5, j + 0.5, level or 0, nil
    r.act, r.queue, r.sleeping, r.walking, r.onObj, r.pose, r.nextThink = nil, {}, nil, nil, nil, "idle", nil
    r.doing, r.orders = nil, r.queue
    if r.needs then SS.Needs.Clamp(r) end
    world.actors[rid] = r
    Sim.order = nil
    SS.Emit("actorAdded", world, r)
    return r
end

-- Take an actor off this lot (leaving for work, going home, travelling, dying).
-- Cancels the action and releases reservations; `away` records why and until when.
function Sim.RemoveActor(world, rid, away)
    local r = world.actors[rid]
    if not r then return end
    if r.act then SS.Actions.Finish(world, r, "cancelled", (away and away.reason) or "left") end
    if r.held and SS.Chains and SS.Chains.SettleHeld then SS.Chains.SettleHeld(world, r, "left") end
    for _, o in pairs(world.lot.objects) do
        if o.res then for k, v in pairs(o.res) do if v == rid then o.res[k] = nil end end end
        if o.watchers then o.watchers[rid] = nil end
    end
    r.queue, r.act, r.doing = {}, nil, nil
    r.orders = r.queue
    r.sleeping, r.walking, r.onObj, r.carry = nil, nil, nil, nil
    Sim.order = nil
    r.lotId = nil
    r.away = away
    world.actors[rid] = nil
    SS.Emit("actorRemoved", world, r, away)
end

function Sim.SetSpeed(level)
    local w = Sim.world
    if not w or not T.speeds[level] then return end
    if level > 0 then w.lastSpeed = level end
    w.speed = level
    SS.Emit("speed", level)
end

function Sim.TogglePause()
    local w = Sim.world
    if not w then return end
    if w.speed == 0 then Sim.SetSpeed(w.lastSpeed or 1) else Sim.SetSpeed(0) end
end

-- Discrete scheduled events are fired in time order and never skipped when a
-- large step crosses their minute. `kind` is namespaced by module ("career.pickup").
-- lotId binds the event to one lot: it only fires while that lot's session runs, on that
-- session's clock (home events wait while the household is on an outing). Handlers:
-- SS.On("scheduled", function(ev, world) if ev.kind == "..." then ... end end)
-- The queue is kept ordered by time, and events due at the same minute keep the order they were
-- scheduled in: a new event goes after every event due at or before its time (binary search for
-- the upper bound). The saved queue is that array, so the order is the same after a reload.
function Sim.Schedule(world, at, kind, data, lotId)
    local s = world.scheduled
    local ev = { at = at, kind = kind, data = data, lotId = lotId }
    local lo, hi = 1, #s + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if s[mid].at <= at then lo = mid + 1 else hi = mid end
    end
    table.insert(s, lo, ev)
    return ev
end

function Sim.Unschedule(world, pred)
    local s = world.scheduled
    for n = #s, 1, -1 do if pred(s[n]) then table.remove(s, n) end end
end

-- A queue written by older code (or by hand) is put in time order without changing the order of
-- events due at the same minute (stable insertion sort; nothing moves in an ordered queue).
local function orderQueue(s)
    for n = #s, 1, -1 do
        if type(s[n]) ~= "table" or type(s[n].at) ~= "number" then table.remove(s, n) end
    end
    for n = 2, #s do
        local ev = s[n]
        local k = n - 1
        while k >= 1 and s[k].at > ev.at do s[k + 1] = s[k]; k = k - 1 end
        s[k + 1] = ev
    end
end
Sim.OrderQueue = orderQueue

-- Fire every event due by `upTo`. After each one the queue is read again from the front, so an
-- event a handler schedules for a time already due (or one it removes) is honoured in the same
-- step. At most Tuning.scheduleMaxPerStep events fire in one step, so a handler that keeps
-- rescheduling itself for "now" cannot hang the game: the rest fire on the next step.
local function runDue(world, upTo)
    local s = world.scheduled
    local cap = T.scheduleMaxPerStep or 256
    local lotId = world.lot.id
    local fired, n = 0, 1
    while true do
        local ev = s[n]
        if not ev or ev.at > upTo then break end
        if ev.lotId == nil or ev.lotId == lotId then
            if fired >= cap then
                Sim.perf.dueCapped = (Sim.perf.dueCapped or 0) + 1
                break
            end
            table.remove(s, n)
            fired = fired + 1
            -- the clock is not moved here (Sim.Step advances it once per step); ev.at says
            -- when the event was due, within this step
            SS.Emit("scheduled", ev, world)
            n = 1
        else
            n = n + 1
        end
    end
    return fired
end

-- Emergencies (fire, collapse, burglary, arrival of important visitors): drop to normal speed
-- and tell the UI to show a prominent warning. severity: "info" | "warning" | "emergency".
function Sim.Emergency(world, text, severity)
    if world.speed and world.speed > 1 then Sim.SetSpeed(1) end
    SS.Emit("emergency", text, severity or "emergency", world)
end

-- Systems: gameplay modules register here instead of editing the step loop.
--   SS.Sim.Register{ name = "fire", order = 50, tick = fn(world, dt), hour = fn(world, hourIndex),
--                    day = fn(world, dayIndex), attach = fn(world), detach = fn(world) }
-- Lower order runs first. Roles: SS.Roles[role].tick(world, actor, dt) runs for actors
-- whose actor.role is set (visitors, service NPCs, pets) before the shared executor.
Sim.systems = {}
SS.Roles = SS.Roles or {}
function Sim.Register(sys)
    for n, s in ipairs(Sim.systems) do
        if s.name == sys.name then Sim.systems[n] = sys; return end
    end
    Sim.systems[#Sim.systems + 1] = sys
    table.sort(Sim.systems, function(a, b) return (a.order or 50) < (b.order or 50) end)
end

-- Deterministic actor order (sorted ids), so runs match between WoW and the test harness.
-- Returns a fresh list (callers may keep or change it).
function Sim.ActorIds(world)
    local ids = {}
    for id in pairs(world.actors) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

-- Cached order for the step loop; rebuilt when actors are added/removed (count or membership).
local function stepOrder(world)
    local ord = Sim.order
    local n = 0
    for _ in pairs(world.actors) do n = n + 1 end
    if ord and Sim.orderN == n and Sim.orderWorld == world then
        local same = true
        for k = 1, #ord do if not world.actors[ord[k]] then same = false; break end end
        if same then return ord end
    end
    ord = Sim.ActorIds(world)
    Sim.order, Sim.orderN, Sim.orderWorld = ord, n, world
    return ord
end
-- The actor ids in step order (sorted), shared and read-only: callers must not change the list.
-- Sim.ActorIds returns a fresh list for callers that need their own.
Sim.StepOrder = stepOrder

-- The lot changed structurally (objects bought/sold/moved, walls, undo): actions whose target
-- vanished fail with a reason; routes toward moved targets are re-selected.
function Sim.ValidateActions(world)
    SS.World.ObjectsChanged()
    local ids = stepOrder(world)
    for n = 1, #ids do
        local a = world.actors[ids[n]]
        local act = a and a.act
        local ia = act and SS.Interactions[act.iid]
        if act and act.oid and ia and not ia.targetActor then
            local o = world.lot.objects[act.oid]
            local tgt = act.target and world.lot.objects[act.target.oid]
            if not o or (act.target and not tgt) then
                SS.Actions.Interrupt(world, a, "That object is gone.", "failed")
                if a.act == act and act.phase ~= "exit" then SS.Actions.Finish(world, a, "failed", "That object is gone.") end
            elseif act.phase == "route" or act.phase == "wait" then
                if act.target and tgt and tgt.res and tgt.res[act.target.key] == a.id then tgt.res[act.target.key] = nil end
                act.target, act.path, act.pi, act.goalCells = nil, nil, nil, nil
                act.phase = "select"
            end
        end
        -- queued orders on vanished objects are dropped
        if a and a.queue then
            for k = #a.queue, 1, -1 do
                local q = a.queue[k]
                if q.oid and not world.lot.objects[q.oid] then table.remove(a.queue, k) end
            end
        end
    end
end

SS.On("lotChanged", function(kind)
    if kind == "state" or kind == "system" then SS.World.Touch(); return end
    Sim.lotDirty = true
end)

function Sim.Step(world, dt)
    runDue(world, world.time + dt)
    if Sim.lotDirty then
        Sim.lotDirty = false
        Sim.ValidateActions(world)
    end
    SS.Nav.NewStep()
    SS.Actions.NewStep(world)
    for _, sys in ipairs(Sim.systems) do
        if sys.tick then sys.tick(world, dt) end
    end
    local ids = stepOrder(world)
    local A = SS.Actions
    A.inStep = true
    for n = 1, #ids do
        local a = world.actors[ids[n]]
        if a then
            local role = a.role and SS.Roles[a.role]
            if role and role.tick then role.tick(world, a, dt) end
            if world.actors[ids[n]] then
                if not a.noNeeds then SS.Needs.Tick(world, a, dt) end
                if not role or role.useAutonomy then A.Think(world, a) end
                if a.act then A.Reconsider(world, a) end
                A.Update(world, a, dt)
                if not a.noNeeds then A.Consequences(world, a) end
            end
        end
    end
    A.inStep = false
    local before = math.floor(world.time / 60)
    world.time = world.time + dt
    local after = math.floor(world.time / 60)
    if after ~= before then
        for _, sys in ipairs(Sim.systems) do
            if sys.hour then sys.hour(world, after) end
        end
        SS.Emit("hour", world, after)
        if math.floor(after / 24) ~= math.floor(before / 24) then
            for _, sys in ipairs(Sim.systems) do
                if sys.day then sys.day(world, math.floor(after / 24)) end
            end
            SS.Emit("day", world, math.floor(after / 24))
        end
    end
    Sim.perf.steps = Sim.perf.steps + 1
end

-- Advance by real seconds at the current speed, in bounded sub-steps.
function Sim.Update(realDt)
    local world = Sim.world
    if not world or world.speed == 0 then return end
    realDt = math.min(realDt, T.maxRealStep)
    local simDt = realDt * T.speeds[world.speed]
    local steps = 0
    -- stop when a step detached this world (a lot switch or emergency attached another) or paused it
    while simDt > 1e-6 and steps < 64 and Sim.world == world and world.speed ~= 0 do
        local dt = math.min(simDt, T.subStep)
        Sim.Step(world, dt)
        simDt = simDt - dt
        steps = steps + 1
    end
end

-- Simulate a fixed span (tests and the debug 'advance' command).
function Sim.Advance(world, minutes)
    local left = minutes
    while left > 1e-6 do
        local dt = math.min(left, T.subStep)
        Sim.Step(world, dt)
        left = left - dt
    end
end

function Sim.ClockText(time)
    local day = math.floor(time / 1440) + 1
    local m = math.floor(time % 1440)
    local h, mm = math.floor(m / 60), m % 60
    local ampm = h < 12 and "AM" or "PM"
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("Day %d  %d:%02d %s", day, h12, mm, ampm)
end
