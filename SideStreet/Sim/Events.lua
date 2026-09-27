-- SideStreet event director and event records.
-- Owner: events module (see ARCHITECTURE.md, docs/modules/events.md).
--
-- * Event records live in root.events.list (bounded). Each record carries an id, kind, cause,
--   participants (who), target objects, start/resolve state, the lane (ordinary/emergency),
--   `fx` flags so every effect is applied exactly once (also across save/load), and concise
--   history text that goes to the household journal.
-- * The director runs on simulated hour ticks (never per frame) with SS.Random(world, "events").
--   Ordinary events and emergencies roll in separate lanes with their own budgets, cooldowns and
--   quiet periods.
-- * Families owned by other modules are started through their APIs (guarded) or observed from
--   the events bus and recorded; see D.families / D.observed in Data/Events.lua.
local _, SS = ...
local Ev = SS.Events or {}
SS.Events = Ev
local D = SS.EventsData
local floor = math.floor

Ev.families = Ev.families or {}      -- id -> { eligible = fn(world, fam), run = fn(world, fam) }
Ev.errors = {}                       -- bounded list of errors caught in guarded cross-module calls

-- Attach hooks: fn(world) after SS.Sim.Attach (lazy registrations with modules that load later).
Ev.attachers = {}
function Ev.OnAttach(name, fn) Ev.attachers[#Ev.attachers + 1] = { name = name, fn = fn } end

---------------------------------------------------------------------------------------------------
-- Small helpers shared by Fire / Death / Hazards.

-- Guarded call into another module: never lets a failure there break an emergency here.
function Ev.Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local res = { pcall(fn, ...) }
    if not res[1] then
        local msg = tostring(res[2])
        SS.Log("events: guarded call failed: %s", msg)
        Ev.errors[#Ev.errors + 1] = msg
        if #Ev.errors > 20 then table.remove(Ev.errors, 1) end
        return nil
    end
    return unpack(res, 2, table.maxn(res))
end

-- Hook failures: a hook that throws is logged (first few times per hook, then only counted) and
-- the other hooks still run, so one module's bad data never stops the whole events system.
Ev.hookErrors = {}   -- hook name -> count
local function hookFailed(name, err)
    local n = (Ev.hookErrors[name] or 0) + 1
    Ev.hookErrors[name] = n
    if n <= 3 then
        local msg = name .. ": " .. tostring(err)
        SS.Log("events: hook %s failed: %s", name, tostring(err))
        Ev.errors[#Ev.errors + 1] = msg
        if #Ev.errors > 20 then table.remove(Ev.errors, 1) end
    end
end
-- pcall without a result table (hot path: every sim minute).
local function guard(name, ok, err) if not ok then hookFailed(name, err) end end
Ev.Guard = guard

local function byString(a, b) return tostring(a) < tostring(b) end
function Ev.SortedKeys(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = k end
    table.sort(out, byString)
    return out
end

-- Sorted keys cached per source table: rebuilt only when the key set changes (count or
-- membership), so per-minute loops do not allocate. The returned list must not be modified.
function Ev.CachedKeys(cache, t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if cache.src == t and cache.n == n then
        local list, same = cache.list, true
        for k = 1, n do if t[list[k]] == nil then same = false; break end end
        if same then return list end
    end
    local list = {}
    for k in pairs(t) do list[#list + 1] = k end
    table.sort(list, byString)
    cache.src, cache.n, cache.list = t, n, list
    return list
end

-- Sorted actor ids on the running lot, cached (SS.Sim.ActorIds builds a new table per call).
local idCache = {}
function Ev.ActorIds(world) return Ev.CachedKeys(idCache, world.actors) end

function Ev.IsHuman(a) return a and (a.kind or "human") == "human" end
function Ev.IsAdult(a) return Ev.IsHuman(a) and (a.age or "adult") == "adult" end
-- Children and infants (the family module owns their welfare path; pets are not dependents).
function Ev.IsDependent(a)
    if SS.Family and SS.Family.IsDependent then return SS.Family.IsDependent(a) and true or false end
    return Ev.IsHuman(a) and (a.age or "adult") ~= "adult"
end

-- Living household members on this lot (no NPC roles), in actor-id order.
function Ev.Members(world, pred, into)
    local out, hh = into or {}, world.household
    if not hh then return out end
    for _, id in ipairs(Ev.ActorIds(world)) do
        local a = world.actors[id]
        if a and not a.dead and not a.role and a.householdId == hh.id and (not pred or pred(a)) then out[#out + 1] = a end
    end
    return out
end

-- Anyone on the lot who reacts like an ordinary person (household members and role-less guests).
-- `into` (optional) is a caller-owned list to fill instead of a new one (per-minute callers).
function Ev.People(world, pred, into)
    local out = into or {}
    for _, id in ipairs(Ev.ActorIds(world)) do
        local a = world.actors[id]
        if a and not a.dead and not a.ghost and not a.role and (not pred or pred(a)) then out[#out + 1] = a end
    end
    return out
end

function Ev.CellOf(a) return floor(a.x), floor(a.y), a.level or 0 end

function Ev.Dist(ax, ay, bx, by) return math.max(math.abs(ax - bx), math.abs(ay - by)) end

---------------------------------------------------------------------------------------------------
-- Saved state: root.events = { list, nextId, cooldowns, people, director, mess, deaths, stats }
function Ev.State(world)
    local root = world.root or world
    local s = root.events
    if type(s) ~= "table" then s = {}; root.events = s end
    s.list = s.list or {}
    s.nextId = s.nextId or 1
    s.cooldowns = s.cooldowns or {}
    s.people = s.people or {}
    s.director = s.director or {}
    s.mess = s.mess or {}
    s.deaths = s.deaths or {}
    s.stats = s.stats or {}
    return s
end

-- Per-person event state (warnings, fire response, mourning, ...), saved under root.events.people.
function Ev.Person(world, rid)
    local s = Ev.State(world)
    local p = s.people[rid]
    if not p then p = {}; s.people[rid] = p end
    return p
end
function Ev.PersonIf(world, rid)
    local root = world.root or world
    return root.events and root.events.people and root.events.people[rid]
end

-- Cooldowns: key -> until (sim minutes).
function Ev.Cooled(world, key) local s = Ev.State(world); return (s.cooldowns[key] or -1e18) > world.time end
function Ev.Cool(world, key, minutes) Ev.State(world).cooldowns[key] = world.time + minutes end

---------------------------------------------------------------------------------------------------
-- Messages, lines, journal, emergencies.

-- Important message: speech balloon plus a notice the UI shows.
function Ev.Tell(world, actor, text, icon)
    if not text then return end
    if actor and SS.Actions and SS.Actions.Message then SS.Actions.Message(world, actor, text, icon)
    else SS.Emit("notice", actor, text) end
end

-- Ambient reaction: balloon only (no notice spam when five people panic at once).
function Ev.Balloon(world, actor, text, icon, kind)
    if not actor then return end
    actor.balloon = { icon = icon, text = text, untilT = world.time + 15, kind = kind or "speech" }
end

-- Alarms (smoke and burglar) ring the shared way: object.state.ringing with object.ringUntil, which
-- household-core's object tick honours (a ringing object whose time has passed goes quiet). Events
-- keeps its alarm's time ahead while the incident lasts, never restarts one a resident silenced,
-- and clears both when the incident is over.
function Ev.StartRinging(world, o)
    o.state = o.state or {}
    o.state.ringing = true
    o.ringUntil = world.time + (SS.EventsData.alarmRingHold or 10)
    SS.Emit("lotChanged", "state", o.id)
end
function Ev.KeepRinging(world, o)
    if o and o.state and o.state.ringing then o.ringUntil = world.time + (SS.EventsData.alarmRingHold or 10) end
end
function Ev.StopRinging(world, o)
    if not o then return end
    local was = o.state and o.state.ringing
    if o.state then o.state.ringing = nil end
    o.ringUntil = nil
    if was then SS.Emit("lotChanged", "state", o.id) end
end

-- Humour and reaction lines go through the social module's pool; the fallback is plain,
-- factual text so a line never describes something that did not happen.
function Ev.Say(world, actor, situation, ctx, fallback, icon, notice)
    local line
    if SS.Lines and SS.Lines.Say then line = Ev.Call(SS.Lines.Say, world, actor, situation, ctx or {}) end
    local text = line or fallback
    if not text then return nil end
    if notice then Ev.Tell(world, actor, text, icon) else Ev.Balloon(world, actor, text, icon) end
    return text
end

local JOURNAL_CAP = 40
function Ev.Journal(world, text, e, who)
    if not text then return end
    local root = world.root or world
    local hh = (e and e.hh and root.households and root.households[e.hh]) or world.household
    if not hh then return end
    local entry
    if world.household == hh and SS.Actions and SS.Actions.Journal then
        SS.Actions.Journal(world, text)
        local j = hh.journal
        entry = j and j[#j]
        if entry and entry.text ~= text then entry = nil end
    else
        hh.journal = hh.journal or {}
        entry = { t = world.time, text = text }
        hh.journal[#hh.journal + 1] = entry
        while #hh.journal > JOURNAL_CAP do table.remove(hh.journal, 1) end
    end
    if entry then
        entry.kind = e and e.kind or entry.kind
        entry.ev = e and e.id or entry.ev
        local list = who or (e and e.who)
        if list and #list > 0 then
            entry.who = {}
            for n = 1, math.min(#list, 8) do entry.who[n] = list[n] end
        end
    end
end

function Ev.Emergency(world, text, severity)
    if SS.Sim and SS.Sim.Emergency then SS.Sim.Emergency(world, text, severity or "emergency")
    else SS.Emit("emergency", text, severity or "emergency", world) end
end

function Ev.Audio(fnName, ...)
    local A = SS.Audio
    if A and A[fnName] then Ev.Call(A[fnName], ...) end
end

---------------------------------------------------------------------------------------------------
-- Objects: ids, creation, removal, cell queries.

function Ev.NewObjectId(lot)
    local field = lot.nextId and "nextId" or "nextObj"
    local n = tonumber(lot[field]) or 1
    local id = "o" .. n
    while lot.objects[id] do n = n + 1; id = "o" .. n end
    lot[field] = n + 1
    return id
end

-- Add a system object. quiet = true skips the lot version bump (invisible runtime-ish objects).
function Ev.AddObject(world, lot, defId, x, y, f, level, state, quiet)
    lot = lot or world.lot
    local id = Ev.NewObjectId(lot)
    local o = { id = id, def = defId, x = x, y = y, f = f or 0, level = level or 0, state = state or {},
        bought = world.time, paid = 0 }
    lot.objects[id] = o
    if not quiet then lot.version = (lot.version or 1) + 1 end
    local def = SS.Objects[defId]
    if lot == world.lot then
        if def and not (def.fp and #def.fp == 0) then SS.World.Rebuild(world) end
        SS.Emit("lotChanged", "object", id)
    end
    return o
end

-- Cancel every action that targets an object (reservations are released by the executor).
function Ev.CancelUsers(world, oid)
    for _, id in ipairs(Ev.ActorIds(world)) do
        local a = world.actors[id]
        local act = a and a.act
        if act and (act.oid == oid or (act.target and act.target.oid == oid)) then
            SS.Actions.Finish(world, a, "cancelled")
        end
    end
end

function Ev.RemoveObject(world, lot, oid, quiet)
    lot = lot or world.lot
    local o = lot.objects[oid]
    if not o then return false end
    if lot == world.lot then Ev.CancelUsers(world, oid) end
    lot.objects[oid] = nil
    if not quiet then lot.version = (lot.version or 1) + 1 end
    if lot == world.lot then
        local def = SS.Objects[o.def]
        if def and not (def.fp and #def.fp == 0) then SS.World.Rebuild(world) end
        SS.Emit("lotChanged", "object", oid)
    end
    return true
end

-- Cells an object covers. Objects with an empty footprint count as standing on (x, y).
function Ev.ObjectCells(o)
    local def = SS.Objects[o.def]
    if def and def.fp and #def.fp == 0 then return { { o.x, o.y } } end
    if not def then return { { o.x, o.y } } end
    return SS.Grid.footprint(def, o)
end

-- Objects covering a cell on a level, sorted by id. skipSystem drops this module's system objects.
function Ev.ObjectsAt(lot, level, i, j, skipSystem)
    local out = {}
    for _, oid in ipairs(Ev.SortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if (o.level or 0) == level and def and not (skipSystem and def.system == "events") then
            for _, c in ipairs(Ev.ObjectCells(o)) do
                if c[1] == i and c[2] == j then out[#out + 1] = o; break end
            end
        end
    end
    return out
end

function Ev.CountDef(lot, defId, pred)
    local n = 0
    for _, o in pairs(lot.objects) do if o.def == defId and (not pred or pred(o)) then n = n + 1 end end
    return n
end

-- (defs without tags answer false here: SS.Tags.Has would build an empty list for each of them)
function Ev.HasTag(def, tag) return def ~= nil and def.tags ~= nil and SS.Tags.Has(def, tag) end

-- Nearest free, standable cell to (i, j) on a level (spiral search, deterministic order).
-- pred(i, j) may reject cells (burning, wrong room, ...).
function Ev.FreeCell(world, level, i, j, pred, maxR)
    local lot = world.lot
    maxR = maxR or math.max(lot.w, lot.h)
    for r = 0, maxR do
        for dj = -r, r do
            for di = -r, r do
                if math.max(math.abs(di), math.abs(dj)) == r then
                    local ci, cj = i + di, j + dj
                    if SS.World.InLot(lot, ci, cj) and not SS.World.Blocked(world, level, ci, cj) and (not pred or pred(ci, cj)) then
                        return ci, cj
                    end
                end
            end
        end
    end
end

-- Cells that other objects need for access (their slot approach cells), for placing piles
-- and puddles without blocking a toilet or a doorway.
function Ev.ApproachCells(world, level)
    local set = {}
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        if def and (o.level or 0) == level and def.slots then
            for _, sl in pairs(def.slots) do
                for _, ap in ipairs(sl.approaches or {}) do
                    local dx, dy = SS.Grid.rot(ap[1], ap[2], o.f or 0)
                    set[(o.y + dy) * 1000 + (o.x + dx)] = true
                end
            end
        end
    end
    return set
end

-- Is the cell next to a door, gate or arch (keeps doorways clear)?
function Ev.NearOpening(world, level, i, j)
    local walls = world.lot.walls[level] or {}
    for k = 0, 3 do
        local d = SS.Grid.DIRS[k]
        local wl = walls[SS.Grid.edgeBetween(i, j, i + d[1], j + d[2])]
        if wl and SS.World.OPENINGS[wl.kind] then return true end
    end
    return false
end

-- The outdoor cell in front of the exterior door nearest to the street entry (or the entry).
function Ev.Doorstep(world)
    local lot = world.lot
    local ei, ej = SS.Street.EntryCell(world)
    local best, bi, bj
    for _, key in ipairs(Ev.SortedKeys(lot.walls[0] or {})) do
        local wl = lot.walls[0][key]
        if SS.World.OPENINGS[wl.kind] then
            local _, _, _, ai, aj, ci, cj = SS.Grid.parseEdge(key)
            for _, c in ipairs({ { ai, aj }, { ci, cj } }) do
                if SS.World.InLot(lot, c[1], c[2]) and SS.World.RoomAt(world, 0, c[1], c[2]) == 0 then
                    local d = math.abs(c[1] - ei) + math.abs(c[2] - ej)
                    if not best or d < best then best, bi, bj = d, c[1], c[2] end
                end
            end
        end
    end
    if not bi then bi, bj = ei, ej end
    return bi, bj
end

-- Reachability flood from a cell on one level (4-connected, walls and pass hooks respected,
-- occupied cells skipped). Returns dist[idx] (idx = j * w + i) and a sorted list of reached
-- cells { i, j, d }. Bounded by the lot size.
function Ev.Flood(world, level, si, sj, who, maxD)
    local lot = world.lot
    local w = lot.w
    local dist, list = { [sj * w + si] = 0 }, { { si, sj, 0 } }
    local head = 1
    maxD = maxD or (lot.w * lot.h)
    while list[head] do
        local c = list[head]
        head = head + 1
        if c[3] < maxD then
            for k = 0, 3 do
                local dv = SS.Grid.DIRS[k]
                local ni, nj = c[1] + dv[1], c[2] + dv[2]
                local key = nj * w + ni
                if not dist[key] and SS.World.InLot(lot, ni, nj) and not SS.World.Blocked(world, level, ni, nj)
                    and SS.World.CanStep(world, level, c[1], c[2], ni, nj, who) then
                    dist[key] = c[3] + 1
                    list[#list + 1] = { ni, nj, c[3] + 1 }
                end
            end
        end
    end
    return dist, list
end

-- Start an in-place scripted activity (panic, phoning for help, burning, grieving on the
-- spot, being scared by a ghost) through the shared executor: the current action is cancelled
-- (reservations released) and the actor performs `iid` where they stand.
function Ev.Pseudo(world, a, iid, data)
    if a.act then SS.Actions.Finish(world, a, "cancelled") end
    a.queue = {}
    local ia = SS.Interactions[iid]
    a.act = { iid = iid, manual = true, actorId = a.id, phase = "perform", t = 0, done = 0, data = data or {},
        label = ia and ia.label or iid }
    return a.act
end

-- Is the actor busy with one of this module's scripted activities (or an order from it)?
function Ev.Busy(a, iid)
    local act = a.act
    if not act then return false end
    if iid then return act.iid == iid end
    return act.iid:sub(1, 3) == "ev_" or (act.data and act.data.source == "events")
end

---------------------------------------------------------------------------------------------------
-- Visual effects: one renderer registration; Fire, Hazards and Death add providers.
-- Provider: fn(world, add) where add(level, x, y, z, effect, scale) appends one draw item.
-- Items come from a reused pool (no per-frame table churn).
Ev.effectProviders = {}
function Ev.OnEffects(fn) Ev.effectProviders[#Ev.effectProviders + 1] = fn end

local fxPool, fxOut, fxN, fxFrame = {}, nil, 0, 0
local function fxAdd(level, x, y, z, effect, scale)
    if fxN >= 64 then return end
    fxN = fxN + 1
    local it = fxPool[fxN]
    if not it then it = {}; fxPool[fxN] = it end
    it.level, it.x, it.y, it.z, it.effect, it.scale = level or 0, x, y, z or 0, effect, scale or 1
    it.frame = (fxFrame + fxN) % 8
    fxOut[#fxOut + 1] = it
end

-- Collect effect items (also used by tests; the renderer calls it through RegisterEffects).
function Ev.CollectEffects(world, out)
    fxOut, fxN = out, 0
    local gt = rawget(_G, "GetTime")
    fxFrame = floor(((gt and gt()) or world.time) * 8) % 8
    for _, fn in ipairs(Ev.effectProviders) do fn(world, fxAdd) end
    fxOut = nil
    return out
end

local fxRegistered = false
Ev.OnAttach("effects", function()
    if fxRegistered or not (SS.Render and SS.Render.RegisterEffects) then return end
    fxRegistered = true
    SS.Render.RegisterEffects(function(world, cam, out) Ev.CollectEffects(world, out) end)
end)

---------------------------------------------------------------------------------------------------
-- NPC identities (firefighters, police, burglar, Registrar): stable ids, created once.
-- When the visitors module's identity pools are loaded (SS.RoleData.pools), responders come from
-- them (the firefighter and police pools), so every module sees the same officer under the same
-- name; events' own D.npcs are the fallback for the ids the pools do not list.
local function poolEntry(rid)
    local pools = SS.RoleData and SS.RoleData.pools
    if type(pools) ~= "table" then return nil end
    for _, pname in ipairs(Ev.SortedKeys(pools)) do
        for _, entry in ipairs(pools[pname]) do
            if entry.id == rid then return entry, pname end
        end
    end
end

-- The stable id of the n-th responder of a pool ("firefighter", "police"), or the fallback.
function Ev.ResponderId(pool, n, fallback)
    local pools = SS.RoleData and SS.RoleData.pools
    local list = type(pools) == "table" and pools[pool]
    local entry = type(list) == "table" and list[n]
    return (entry and entry.id) or fallback
end

function Ev.EnsureNPC(root, rid)
    root = root.root or root
    local r = root.residents[rid]
    if r then return r end
    local entry, pname = poolEntry(rid)
    if entry and SS.Visitors and SS.Visitors.EnsureNPC then
        r = Ev.Call(SS.Visitors.EnsureNPC, { root = root }, entry, pname)
        if r then return r end
    end
    -- the pool's identity (name, pronoun) wins over this module's fallback data
    local spec = D.npcs[rid] or { name = rid, look = {} }
    local look = SS.U.deepcopy((entry and entry.look) or spec.look or {})
    r = { id = rid, name = (entry and entry.name) or spec.name, age = "adult", kind = "human",
        pronoun = (entry and entry.pronoun) or spec.pronoun or "they", npc = "events",
        look = look, outfit = spec.outfit or "work",
        needs = { hunger = 50, energy = 50, bladder = 50, hygiene = 50, fun = 50, social = 50, comfort = 50, room = 0 },
        personality = { neat = 5, outgoing = 5, active = 5, playful = 5, nice = 5 }, skills = {},
        x = 0, y = 0, level = 0, facing = 0 }
    root.residents[rid] = r
    return r
end

---------------------------------------------------------------------------------------------------
-- Event records.

local function dirState(world, hhId)
    local s = Ev.State(world)
    hhId = hhId or (world.household and world.household.id) or "_"
    local d = s.director[hhId]
    if not d then d = { count = 0, day = floor(world.time / 1440) }; s.director[hhId] = d end
    return d
end
Ev.DirState = dirState

local function prune(s)
    local cap = D.director.historyCap
    local n = 1
    while #s.list > cap and n <= #s.list do
        if s.list[n].state == "resolved" then table.remove(s.list, n) else n = n + 1 end
    end
end

-- Create an event record. Keeps the stub signature Record(world, kind, data); optional opts:
-- { cause, who = {rid...}, targets = {oid...}, lotId, hh, lane = "ordinary"|"emergency",
--   family, text (journal), budget = false (do not count toward the daily ordinary budget) }.
-- A record with no `family` (another module calling the stub signature) counts toward the budget
-- only with budget = true.
-- The director's argument waiting for the social module to play it out (a and b either way;
-- a quarrel that never came to anything within six hours is not claimed by a later one).
local function pendingArgument(world, aId, bId)
    if not aId or not bId then return nil end
    for _, e in ipairs(Ev.Open(world, "argument")) do
        local w = e.who or {}
        if e.data.social == "pending" and world.time - e.t <= 360
            and ((w[1] == aId and w[2] == bId) or (w[1] == bId and w[2] == aId)) then return e end
    end
end

function Ev.Record(world, kind, data, opts)
    local s = Ev.State(world)
    opts = opts or {}
    data = data or {}
    -- social records the quarrel the director started: that is the director's record (one
    -- record; social keeps its id and resolves it "reconciled" on the apology)
    if kind == "social.argument" and opts.family == nil then
        local mine = pendingArgument(world, data.a, data.b)
        if mine then
            mine.data.social, mine.data.cause = "linked", data.cause
            mine.cause = mine.cause or data.cause
            return mine
        end
    end
    local e = {
        id = "ev" .. s.nextId, kind = kind, t = world.time, data = data, state = "active",
        cause = opts.cause or data.cause, who = opts.who or data.participants or {},
        targets = opts.targets or data.targets or {},
        lotId = opts.lotId or (world.lot and world.lot.id), hh = opts.hh or (world.household and world.household.id),
        lane = opts.lane or data.lane or "ordinary", family = opts.family or kind, fx = {}, text = opts.text,
    }
    s.nextId = s.nextId + 1
    s.list[#s.list + 1] = e
    prune(s)
    s.stats[kind] = (s.stats[kind] or 0) + 1
    if e.hh then
        local d = dirState(world, e.hh)
        local day = floor(world.time / 1440)
        if d.day ~= day then d.day, d.count = day, 0 end
        -- only events' own records (they name their family) count toward the daily ordinary
        -- budget; other modules' records through the stub signature (family's grew_up, party,
        -- neglect; careers' report cards, chance events, collections) never crowd the director out
        if e.lane == "emergency" then d.lastEmergency = world.time
        elseif opts.budget == true or (opts.budget ~= false and opts.family ~= nil) then d.count = (d.count or 0) + 1 end
    end
    if opts.text then Ev.Journal(world, opts.text, e) end
    SS.Emit("eventStarted", world, e)
    return e
end

-- Mark an effect as applied. Returns true the first time only (the flag is saved with the record).
function Ev.Once(e, key, world)
    if not e then return false end
    e.fx = e.fx or {}
    if e.fx[key] then return false end
    e.fx[key] = world and world.time or true
    return true
end

function Ev.Find(world, id)
    if type(id) == "table" then return id end
    local s = Ev.State(world)
    for n = #s.list, 1, -1 do if s.list[n].id == id then return s.list[n] end end
end

function Ev.Resolve(world, id, outcome, text)
    local e = Ev.Find(world, id)
    if not e or e.state == "resolved" then return e end
    e.state, e.outcome, e.resolvedAt = "resolved", outcome, world.time
    if text then Ev.Journal(world, text, e) end
    SS.Emit("eventResolved", world, e)
    return e
end

-- The emergency is over but consequences remain (charred remains, a burglary to report...).
function Ev.Aftermath(world, id, text)
    local e = Ev.Find(world, id)
    if not e or e.state ~= "active" then return e end
    e.state, e.aftermathAt = "aftermath", world.time
    if text then Ev.Journal(world, text, e) end
    SS.Emit("eventAftermath", world, e)
    return e
end

-- First active record of a kind (optionally on one lot). Stub-compatible.
function Ev.Active(world, kind, lotId)
    local s = Ev.State(world)
    for _, e in ipairs(s.list) do
        if e.kind == kind and e.state == "active" and (not lotId or e.lotId == lotId) then return e end
    end
end

-- Records not yet resolved (active or aftermath), filtered.
function Ev.Open(world, kind, lotId, pred)
    local out = {}
    for _, e in ipairs(Ev.State(world).list) do
        if e.state ~= "resolved" and (not kind or e.kind == kind) and (not lotId or e.lotId == lotId) and (not pred or pred(e)) then
            out[#out + 1] = e
        end
    end
    return out
end

-- Is an emergency that blocks other events (a fire, a burglary: D.director.blocking) running on
-- this lot right now? Records that stay open for a long time (a death until the Registrar has
-- been, a household without a guardian) never hold the director back.
function Ev.EmergencyActive(world)
    local lotId = world.lot and world.lot.id
    local blocking = D.director.blocking
    for _, e in ipairs(Ev.State(world).list) do
        if e.state == "active" and blocking[e.kind] and e.lotId == lotId then return true end
    end
    return false
end

-- Records whose participants are the dead themselves (they settle through their own flow).
Ev.ABOUT_THE_DEAD = { death = true, household_end = true, guardian_lost = true }

-- A death settles the open records that were only about that person (a hunger clock, a shock,
-- being on fire, hiccups...): nothing can resolve them any more. Returns how many settled.
function Ev.SettleFor(world, rid)
    local root = world.root or world
    local n = 0
    for _, e in ipairs(Ev.State(world).list) do
        if e.state ~= "resolved" and not Ev.ABOUT_THE_DEAD[e.kind] and e.who and #e.who > 0 then
            local mine, others = false, false
            for _, w in ipairs(e.who) do
                if w == rid then mine = true
                else
                    local r = root.residents[w]
                    if not (r and r.dead) then others = true end
                end
            end
            if mine and not others then
                Ev.Resolve(world, e, e.kind == "ghost" and "faded" or "died")
                n = n + 1
            end
        end
    end
    return n
end

-- An open record of `kind` that targets object `oid`.
function Ev.ForTarget(world, kind, oid)
    for _, e in ipairs(Ev.State(world).list) do
        if e.state ~= "resolved" and e.kind == kind and e.lotId == world.lot.id then
            for _, t in ipairs(e.targets or {}) do if t == oid then return e end end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Responders (firefighters, police, the burglar, the Registrar) on the visitors framework.
-- Uses SS.Visitors.Request when it accepts the request (one request per responder per event: the
-- dedupe key names the event); otherwise schedules the arrival on that lot's clock and spawns
-- through SS.Visitors.Spawn. A request the visitors module cancels (the person was busy, a cap)
-- falls back to events' own schedule, a bounded number of times.
local function requestData(role, rid, e, delay, vehicle, lotId)
    local cfg = D.responders[role] or {}
    return { rid = rid, eventId = e.id, delay = delay, vehicle = vehicle, urgent = true, source = "events", lotId = lotId,
        priority = cfg.priority, arrive = cfg.arrive, key = role .. ":" .. rid .. ":" .. e.id }
end

local function scheduleArrival(world, e, rid, rec, at)
    SS.Sim.Schedule(world, at, "events.arrive", { role = rec.role, rid = rid, eventId = e.id, vehicle = rec.vehicle }, rec.lotId)
    rec.scheduled, rec.eta = true, at
end

function Ev.RequestResponder(world, e, role, rid, delay, vehicle, lotId)
    e.data.responders = e.data.responders or {}
    if e.data.responders[rid] then return false end
    Ev.EnsureNPC(world.root, rid)
    lotId = lotId or world.lot.id
    local rec = { role = role, t = world.time, eta = world.time + delay, vehicle = vehicle, lotId = lotId }
    e.data.responders[rid] = rec
    local reqId
    if SS.Visitors and SS.Visitors.Request then
        reqId = Ev.Call(SS.Visitors.Request, world, role, requestData(role, rid, e, delay, vehicle, lotId))
    end
    if reqId then rec.request = reqId
    else
        -- another lot's clock may differ (outings); the arrival waits until that lot runs
        local at = (lotId == world.lot.id) and (world.time + delay) or ((world.root.time or world.time) + delay)
        scheduleArrival(world, e, rid, rec, at)
    end
    return true
end

Ev.arrivals = {}   -- role -> fn(world, e, rid) -> false to skip the arrival (checked before spawning)

-- Is a requested responder still expected? Not once they arrived or were stood down, and not
-- when they are more than three hours overdue (a request the visitors module never fulfilled):
-- then the request counts as skipped, so no event waits forever.
Ev.OVERDUE = 180
function Ev.Pending(world, e, rid)
    local rec = e and e.data.responders and e.data.responders[rid]
    if not rec or rec.arrived or rec.skipped then return false end
    if world.time > (rec.eta or rec.t or world.time) + Ev.OVERDUE and not world.actors[rid] then
        rec.skipped = world.time
        return false
    end
    return true
end

-- A responder due for one event while the same person is still on the lot for another (the
-- Registrar filing the first of two deaths, say) comes back when they are free: the arrival is
-- tried again every D.responderRetry minutes, at most D.responderRetries times.
function Ev.Arrive(world, data)
    local e = Ev.Find(world, data.eventId)
    local rec = e and e.data.responders and e.data.responders[data.rid]
    if not rec or rec.arrived or rec.skipped then return nil end
    local check = Ev.arrivals[data.role]
    if e.state == "resolved" or (check and check(world, e, data.rid) == false) then
        rec.skipped = world.time
        return nil
    end
    local here = world.actors[data.rid]
    if here then
        if here.role == data.role and here.roleData and here.roleData.eventId == e.id then rec.arrived = world.time; return here end
        rec.defers = (rec.defers or 0) + 1
        if rec.defers > D.responderRetries then rec.skipped = world.time; return nil end
        scheduleArrival(world, e, data.rid, rec, world.time + D.responderRetry)
        return nil
    end
    Ev.EnsureNPC(world.root, data.rid)
    local sd = requestData(data.role, data.rid, e, 0, data.vehicle, world.lot.id)
    sd.key, sd.delay, sd.urgent, sd.lotId = nil, nil, nil, nil
    local a = SS.Visitors and SS.Visitors.Spawn and SS.Visitors.Spawn(world, data.rid, data.role, sd)
    if not a then rec.skipped = world.time; return nil end
    rec.arrived = world.time
    a.roleData = a.roleData or {}
    a.roleData.eventId = a.roleData.eventId or e.id
    -- the stub street has no vehicles of its own: park one so the renderer has something to draw
    -- (the visitors module's street brings its own vehicle for `data.vehicle`)
    if data.vehicle and SS.Street and type(SS.Street.vehicles) == "table" and not SS.Street.CallVehicle then
        local i = SS.Street.EntryCell(world)
        local vs = SS.Street.vehicles
        if #vs < 8 then vs[#vs + 1] = { kind = data.vehicle, i = i, state = "parked", t = world.time, owner = data.rid } end
    end
    return a
end

-- A visitors-module request that ended before the responder arrived (cancelled because the
-- person was busy or a cap refused them, pruned, or closed as "done" by a reload before they
-- got here) falls back to events' own arrival, at most twice per responder.
local function checkRequests(world)
    local V = SS.Visitors
    if not (V and V.GetRequest) then return end
    for _, e in ipairs(Ev.State(world).list) do
        local rs = e.state ~= "resolved" and e.data.responders
        if rs and next(rs) then
            for _, rid in ipairs(Ev.SortedKeys(rs)) do
                local rec = rs[rid]
                if rec.request and not rec.arrived and not rec.skipped then
                    local r = V.GetRequest(world, rec.request)
                    if not r or r.state == "cancelled" or r.state == "done" then
                        rec.request = nil
                        rec.fallbacks = (rec.fallbacks or 0) + 1
                        local now = (rec.lotId == world.lot.id) and world.time or (world.root.time or world.time)
                        if rec.fallbacks > 2 then rec.skipped = world.time
                        else scheduleArrival(world, e, rid, rec, now + D.responderRetry) end
                    end
                end
            end
        end
    end
end
Ev.CheckRequests = checkRequests

function Ev.ClearVehicle(rid)
    local vs = SS.Street and SS.Street.vehicles
    if type(vs) ~= "table" then return end
    for n = #vs, 1, -1 do if vs[n].owner == rid then table.remove(vs, n) end end
end

-- Send a responder home through the visitors framework (walks out in the full implementation).
function Ev.SendAway(world, a, why)
    if not a or not world.actors[a.id] then return end
    a.roleData = a.roleData or {}
    if a.roleData.phase == "leaving" then return end
    a.roleData.phase = "leaving"
    if a.act then SS.Actions.Finish(world, a, "cancelled") end
    a.queue = {}
    a.carry = nil
    Ev.ClearVehicle(a.id)
    if SS.Visitors and SS.Visitors.Leave then SS.Visitors.Leave(world, a, why or "done")
    else SS.Sim.RemoveActor(world, a.id, { reason = why or "done" }) end
end

SS.On("scheduled", function(ev, world)
    if ev.kind == "events.arrive" and world then Ev.Arrive(world, ev.data) end
end)

---------------------------------------------------------------------------------------------------
-- Hour / minute plumbing (registered as one simulation system below).

Ev.hourly, Ev.minutely = {}, {}
function Ev.OnHour(name, fn, order) Ev.hourly[#Ev.hourly + 1] = { name = name, fn = fn, order = order or 50 }
    table.sort(Ev.hourly, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.name < b.name end) end
function Ev.OnMinute(name, fn, order) Ev.minutely[#Ev.minutely + 1] = { name = name, fn = fn, order = order or 50 }
    table.sort(Ev.minutely, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.name < b.name end) end

local RT = { lotId = nil, minute = nil }
Ev.RT = RT

-- Every hook runs guarded: one hook failing (another module's unexpected data, say) is logged
-- and the rest of the minute still runs.
function Ev.Minute(world)
    local list = Ev.minutely
    for n = 1, #list do
        local h = list[n]
        guard(h.name, pcall(h.fn, world))
    end
end

local function tick(world, dt)
    if RT.lotId ~= world.lot.id or not RT.minute then RT.lotId, RT.minute = world.lot.id, floor(world.time) end
    local target = floor(world.time + dt + 1e-9)
    local n = 0
    while RT.minute < target and n < 15 do
        RT.minute = RT.minute + 1
        n = n + 1
        Ev.Minute(world)
    end
    if RT.minute < target then RT.minute = target end
end

function Ev.Hour(world, hourIndex)
    local list = Ev.hourly
    for n = 1, #list do
        local h = list[n]
        guard(h.name, pcall(h.fn, world, hourIndex))
    end
    guard("director", pcall(Ev.Director, world, hourIndex))
end

local function day(world)
    local s = Ev.State(world)
    for k, v in pairs(s.cooldowns) do if v < world.time - 1440 then s.cooldowns[k] = nil end end
end

local function attach(world)
    Ev.State(world)
    RT.lotId, RT.minute = world.lot.id, floor(world.time)
    for _, a in ipairs(Ev.attachers) do guard("attach:" .. a.name, pcall(a.fn, world)) end
end

SS.Sim.Register({ name = "events", order = 40, tick = tick, hour = function(world, h) Ev.Hour(world, h) end,
    day = day, attach = attach })

---------------------------------------------------------------------------------------------------
-- The director.

local function inHours(fam, hour)
    local h = fam.hours
    if not h then return true end
    if h[1] <= h[2] then return hour >= h[1] and hour < h[2] end
    return hour >= h[1] or hour < h[2]
end

local function famKey(fam, world) return "fam:" .. fam.id .. ":" .. ((world.household and world.household.id) or "_") end

-- Can a family run now? Returns ok, why (for the debug panel and tests).
function Ev.Eligible(world, fam, ignoreCooldown)
    local impl = Ev.families[fam.id]
    if not impl then return false, "not implemented" end
    if not ignoreCooldown and Ev.Cooled(world, famKey(fam, world)) then return false, "cooling down" end
    return impl.eligible(world, fam)
end

local function roll(world, lane, hour, d)
    local cands, total = {}, 0
    for _, fam in ipairs(D.families) do
        if fam.lane == lane and inHours(fam, hour) and (not fam.comic or (world.time >= (d.lastComic or -1e18) + D.director.comicGap
            and world.time >= (d.lastEmergency or -1e18) + D.director.somberGap)) then
            local ok, chance = Ev.Eligible(world, fam)
            if ok then
                local c = type(chance) == "number" and chance or fam.chance
                cands[#cands + 1] = { fam = fam, chance = c }
                total = total + c
            end
        end
    end
    if #cands == 0 then return nil end
    local scale = total > D.director.maxChance and D.director.maxChance / total or 1
    local r = SS.Random(world, "events")
    local acc = 0
    for _, c in ipairs(cands) do
        acc = acc + c.chance * scale
        if r < acc then return c.fam end
    end
end

local function runFamily(world, fam, d)
    local impl = Ev.families[fam.id]
    local e, why = Ev.Call(impl.run, world, fam)
    if e then
        Ev.Cool(world, famKey(fam, world), fam.cooldown)
        if fam.comic then d.lastComic = world.time end
        if fam.lane == "ordinary" then d.nextOrdinary = world.time + D.director.ordinaryGap end
    else
        Ev.Cool(world, famKey(fam, world), D.director.retry)
        SS.Log("events: %s could not run: %s", fam.id, tostring(why))
    end
    return e, why
end

function Ev.Director(world, hourIndex)
    local lot, hh = world.lot, world.household
    if not hh or lot.kind == "community" or hh.lotId ~= lot.id or (hh.flags and hh.flags.ended) then return end
    if #Ev.Members(world) == 0 then return end
    local d = dirState(world)
    local t = world.time
    if not d.started then d.started = t; d.quietUntil = t + D.director.firstQuiet end
    if t < (d.quietUntil or 0) then return end
    local calmFrom = (d.started or t) + (D.director.firstEmergencyQuiet or 0)
    local dayIdx = floor(t / 1440)
    if d.day ~= dayIdx then d.day, d.count = dayIdx, 0 end
    local hour = hourIndex % 24
    if (d.count or 0) < D.director.ordinaryPerDay and t >= (d.nextOrdinary or -1e18) and not Ev.EmergencyActive(world) then
        local fam = roll(world, "ordinary", hour, d)
        if fam then runFamily(world, fam, d) end
    end
    if t >= calmFrom and t >= (d.lastEmergency or -1e18) + D.director.emergencyQuiet and not Ev.EmergencyActive(world) then
        local fam = roll(world, "emergency", hour, d)
        if fam then runFamily(world, fam, d) end
    end
end

-- Debug: run one family now through the real system (eligibility still applies).
function Ev.Debug(world, famId)
    for _, fam in ipairs(D.families) do
        if fam.id == famId then
            local ok, why = Ev.Eligible(world, fam, true)
            if not ok then return nil, why end
            return runFamily(world, fam, dirState(world))
        end
    end
    return nil, "no such event family"
end

---------------------------------------------------------------------------------------------------
-- Families started through other modules' APIs (guarded; they run once those modules land).

local function awakeMembers(world)
    return Ev.Members(world, function(a) return not a.sleeping and Ev.IsHuman(a) end)
end

-- Someone the household knows drops by: the visitors module's "guest" role, for the free person
-- (townie or neighbour) with the best relationship to the household, ties by id. Visitors owns
-- the visit itself (door, greeting, hosting, leaving).
local function dropInGuest(world)
    local V = SS.Visitors
    if not (V and V.Candidates) then return nil end
    local list = Ev.Call(V.Candidates, world)
    if type(list) ~= "table" then return nil end
    local best, bestS
    for _, r in ipairs(list) do
        if type(r) == "table" and not r.dead then
            local s = (V.BestRel and Ev.Call(V.BestRel, world, r.id)) or 0
            if type(s) ~= "number" then s = 0 end
            if not best or s > bestS or (s == bestS and r.id < best.id) then best, bestS = r, s end
        end
    end
    return best
end

Ev.families.visit_dropin = {
    eligible = function(world)
        local V = SS.Visitors
        if not (V and V.Request) then return false, "visitors module missing" end
        if V.roles and not V.roles.guest then return false, "no guest visits in this build" end
        if #awakeMembers(world) == 0 then return false, "nobody awake" end
        if not dropInGuest(world) then return false, "nobody free to drop by" end
        return true
    end,
    run = function(world)
        local r = dropInGuest(world)
        if not r then return nil, "nobody free to drop by" end
        local id, why = SS.Visitors.Request(world, "guest", { rid = r.id, delay = 5, window = 30, key = "guest:" .. r.id,
            spontaneous = true, source = "events" })
        if not id then return nil, why or "no visitor available" end
        return Ev.Resolve(world, Ev.Record(world, "visit", { request = id, rid = r.id }, { who = { r.id }, family = "visit_dropin" }), "arranged")
    end,
}

-- A friend rings (visitors' phone). The caller is someone the household knows when the visitors
-- module can say who; the phone module answers "chat" calls with a relationship boost.
local function phoneCaller(world)
    local V = SS.Visitors
    if not (V and V.KnownPeople) then return nil end
    local known = Ev.Call(V.KnownPeople, world, 8)
    for _, entry in ipairs(type(known) == "table" and known or {}) do
        local r = entry.r or entry
        if type(r) == "table" and not r.dead and not world.actors[r.id] then return r end
    end
end

Ev.families.phone_call = {
    eligible = function(world)
        if not (SS.Phone and SS.Phone.Ring) then return false, "incoming calls not available" end
        if #awakeMembers(world) == 0 then return false, "nobody awake" end
        return true
    end,
    run = function(world)
        local from = phoneCaller(world)
        local call, why = SS.Phone.Ring(world, { kind = "chat", from = from and from.id, source = "events" })
        if not call then return nil, why end
        local callId = type(call) == "table" and call.id or call
        return Ev.Resolve(world, Ev.Record(world, "phone", { call = callId, from = from and from.id },
            { who = from and { from.id } or {}, family = "phone_call" }), "rang")
    end,
}

-- Arguments come from real tension: the pair with the lowest mutual feeling on the lot. With the
-- social module, only people who know each other can quarrel (its own rule for Argue: met, or
-- housemates when it offers SS.Social.Knows), and the scan reads relationships without creating
-- them (SS.Social.Peek).
local function hasMet(r) return r ~= nil and (type(r.flags) ~= "table" or r.flags.met) and true or false end
local function tensePair(world)
    local list = awakeMembers(world)
    local best, ba, bb
    local peek = SS.Social and (SS.Social.Peek or SS.Social.Get)
    local knows = SS.Social and SS.Social.Knows
    for x = 1, #list do
        for y = x + 1, #list do
            local a, b = list[x], list[y]
            local v
            if peek then
                local ra, rb = peek(world, a.id, b.id), peek(world, b.id, a.id)
                local known
                if knows then known = knows(world, a.id, b.id) else known = hasMet(ra) or hasMet(rb) end
                if known then v = math.min(ra and ra.daily or 0, rb and rb.daily or 0) end
            elseif SS.Social and SS.Social.Rel then
                v = math.min(SS.Social.Rel(world, a.id, b.id).daily or 0, SS.Social.Rel(world, b.id, a.id).daily or 0)
            else
                v = 0
            end
            if v and (not best or v < best) then best, ba, bb = v, a, b end
        end
    end
    return ba, bb, best
end

Ev.families.argument = {
    eligible = function(world)
        if not (SS.Social and (SS.Social.StartConflict or SS.Interactions.argue)) then return false, "social arguments not available" end
        local a, b, v = tensePair(world)
        if not a then return false, "needs two people awake who know each other" end
        if v >= 20 then return false, "everyone is getting on" end
        return true
    end,
    run = function(world)
        local a, b = tensePair(world)
        if not a then return nil, "nobody to argue" end
        local social = SS.Social.StartConflict ~= nil
        if social then
            if not Ev.Call(SS.Social.StartConflict, world, a, b, "events") then return nil, "they kept the peace" end
        else
            if a.act and a.act.manual then return nil, "busy" end
            if a.act then SS.Actions.Finish(world, a, "cancelled") end
            SS.Actions.Order(world, a, nil, "argue", nil, nil, { tid = b.id, manual = false, data = { source = "events" } })
        end
        -- with the social module the quarrel is social's to play out: when it records it
        -- ("social.argument"), it gets this record back (see Ev.Record), so there is one record,
        -- and its apology resolves it
        return Ev.Record(world, "argument", { social = social and "pending" or nil }, { who = { a.id, b.id }, family = "argument",
            text = a.name .. " and " .. b.name .. " had words." })
    end,
}

Ev.families.work_chance = {
    eligible = function(world)
        if not (SS.Career and SS.Career.ChanceEvent) then return false, "career chance events not available" end
        for _, a in ipairs(Ev.Members(world, Ev.IsAdult)) do if a.career then return true end end
        return false, "nobody has a job"
    end,
    run = function(world)
        for _, a in ipairs(Ev.Members(world, Ev.IsAdult)) do
            if a.career then
                local ok, text = SS.Career.ChanceEvent(world, a)
                if ok then return Ev.Resolve(world, Ev.Record(world, "work", { text = text }, { who = { a.id }, family = "work_chance" }), "offered") end
            end
        end
        return nil, "no chance event today"
    end,
}

local GARDEN_TAGS = { "garden_plot", "planter", "flowers", "shrub", "tree" }
local function gardenObjects(world)
    local out = {}
    for _, oid in ipairs(Ev.SortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        for _, tag in ipairs(GARDEN_TAGS) do
            if Ev.HasTag(def, tag) and not (o.state and o.state.wilted) then out[#out + 1] = o; break end
        end
    end
    return out
end

Ev.families.garden_stress = {
    eligible = function(world)
        if not (SS.Garden and SS.Garden.Stress) then return false, "gardening not available" end
        if #gardenObjects(world) == 0 then return false, "no plants" end
        return true
    end,
    run = function(world)
        local list = gardenObjects(world)
        local o = SS.Pick(world, "events", list)
        if not o or not SS.Garden.Stress(world, o, "dry_spell") then return nil, "the plants coped" end
        return Ev.Record(world, "garden", { cause = "dry_spell" }, { targets = { o.id }, family = "garden_stress",
            text = "A hot, dry spell is hard on the garden." })
    end,
}

---------------------------------------------------------------------------------------------------
-- Observed families: recorded when another module's system produces them.

-- Breakdowns (any cause) are recorded; leaks are handled in Sim/Hazards.lua.
SS.On("objectBroken", function(world, o, why)
    if not world or not world.lot or not o or world.lot.objects[o.id] ~= o then return end
    if why == "fire" or why == "burglary" then return end   -- part of that event's own record
    if Ev.ForTarget(world, "breakdown", o.id) then return end
    local def = SS.Objects[o.def]
    if SS.Hazards and SS.Hazards.IsPlumbing and SS.Hazards.IsPlumbing(def) then return end   -- a leak (Sim/Hazards.lua)
    local text = (def and def.name or "Something") .. " broke down."
    if def and (def.cat == "electronics" or def.cat == "lighting" or def.powered) then
        text = text .. " Faulty electrics left unrepaired can start a fire."   -- the risk is forecast, not a surprise
    end
    Ev.Record(world, "breakdown", { why = why }, { targets = { o.id }, cause = why, family = "breakdown",
        budget = why == "event", text = text })
end)

-- Bills (careers). Careers emits billRaised(world, bill), billPaid(world, bill),
-- billOverdue(world, bill, stage 1|2|3) and repossessed(world, collection, item), records its own
-- "bill_collection" and journals its final notices. Events keeps one "bills" record open per
-- household while any bill is overdue (stage 1 opens it and journals once; stages 2 and 3 update
-- it) and resolves it when the last overdue bill is paid or the collector has settled the debt.
-- Payments made through SS.Money(..., "bills", ...) are recorded as resolved "bills" records.
-- The older billEvent(world, kind, bill) form is still understood.
local function openOverdue(world)
    local hh = world.household and world.household.id
    for _, e in ipairs(Ev.State(world).list) do
        if e.state ~= "resolved" and e.kind == "bills" and e.hh == hh and e.data.kind == "overdue" then return e end
    end
end
local function overdueLeft(world)
    local hh = world.household
    if type(hh) ~= "table" or type(hh.bills) ~= "table" then return nil end   -- unknown: careers not loaded
    for _, b in ipairs(hh.bills) do
        if type(b) == "table" and b.state == "delivered" and type(b.due) == "number" and world.time >= b.due then return true end
    end
    return false
end
local function settleOverdue(world, outcome, text)
    local e = openOverdue(world)
    if not e then return end
    if overdueLeft(world) then return end   -- another overdue bill is still waiting
    Ev.Resolve(world, e, outcome or "paid", text or "The overdue bills are settled.")
end
Ev.SettleOverdue = settleOverdue

local function overdue(world, bill, stage)
    if not world or not world.household then return end
    local e = openOverdue(world)
    if not e then
        e = Ev.Record(world, "bills", { kind = "overdue", stage = stage or 1, amount = bill and bill.amount, bill = bill and bill.id },
            { family = "bills", text = "A bill is overdue. Pay it before the collector calls." })
    end
    if (stage or 1) > (e.data.stage or 1) then e.data.stage = stage end
    return e
end

SS.On("money", function(delta, text, cat)
    local world = SS.Sim.world
    if not world or cat ~= "bills" or not world.household or delta == 0 then return end
    Ev.Resolve(world, Ev.Record(world, "bills", { amount = delta, text = text }, { family = "bills", budget = false }), "paid")
    if delta < 0 and not overdueLeft(world) then settleOverdue(world) end   -- no overdue bill left (or no bill list): a payment settles it
end)
SS.On("billOverdue", function(world, bill, stage) overdue(world, bill, stage) end)
SS.On("billPaid", function(world, bill) if world then settleOverdue(world, "paid", "The overdue bills are paid.") end end)
SS.On("collectionDone", function(world, col) if world then settleOverdue(world, "collected", "The bill collector has settled the debt.") end end)
SS.On("repossessed", function(world, col, item)
    local e = world and openOverdue(world)
    if e then
        e.data.repossessed = (e.data.repossessed or 0) + 1
        if #(e.targets) < 8 and type(item) == "table" and item.oid then e.targets[#e.targets + 1] = item.oid end
    end
end)
SS.On("billEvent", function(world, kind, bill)
    if not world or not world.household then return end
    if kind == "paid" then settleOverdue(world); return end
    if kind == "overdue" then overdue(world, bill, 1); return end
    local e = Ev.Record(world, "bills", { kind = kind, amount = bill and bill.amount }, { family = "bills" })
    Ev.Resolve(world, e, kind)
end)

-- Careers: careerPromoted(world, actor, level), careerDemoted(world, actor, level, why),
-- careerEnded(world, actor, reason). Careers journals these itself, so the records carry no text
-- (the Incidents list shows them; the journal has careers' own line once).
local function workRecord(world, actor, kind, data)
    if not world or type(actor) ~= "table" or not actor.id then return end
    data = data or {}
    data.kind = kind
    Ev.Resolve(world, Ev.Record(world, "work", data, { who = { actor.id }, family = "work" }), kind)
end
SS.On("careerPromoted", function(world, actor, level) workRecord(world, actor, "promoted", { level = level }) end)
SS.On("careerDemoted", function(world, actor, level, why) workRecord(world, actor, "demoted", { level = level, why = why }) end)
SS.On("careerEnded", function(world, actor, reason) workRecord(world, actor, reason == "fired" and "fired" or "left", { reason = reason }) end)
-- The older careerEvent(world, actor, kind, text) form.
SS.On("careerEvent", function(world, actor, kind, text)
    if not world or not actor then return end
    Ev.Resolve(world, Ev.Record(world, "work", { kind = kind }, { who = { actor.id }, family = "work", text = text }), kind)
end)

-- Parties (family): partyEnded(world, rec[, summary]) with rec.outcome = "good" | "ok" | "bad" |
-- "empty" | "cancelled" and rec.id. Family records its own "party" record (data.id = rec.id)
-- before emitting; events records one only when family has not (older payloads with `success`).
local PARTY_TEXT = { good = "The party was a success.", ok = "The party went fine.", bad = "The party fizzled out.",
    empty = "Nobody came to the party." }
SS.On("partyEnded", function(world, rec, summary)
    if not world or type(rec) ~= "table" then return end
    local outcome = rec.outcome
    if outcome == nil and rec.success ~= nil then outcome = rec.success and "good" or "bad" end
    if outcome == nil or outcome == "cancelled" then return end
    if rec.id then
        for _, e in ipairs(Ev.State(world).list) do
            if e.kind == "party" and e.data.id == rec.id then return end   -- family recorded it already
        end
    end
    -- guests who came: family keeps rec.guests as a map by resident id in rec.order's order; an
    -- older payload had a plain list of ids
    local guests = {}
    local map = type(rec.guests) == "table" and rec.guests or {}
    if type(rec.order) == "table" then
        for _, rid in ipairs(rec.order) do
            local g = map[rid]
            if #guests < 8 and type(rid) == "string" and type(g) == "table" and g.arrived then guests[#guests + 1] = rid end
        end
    else
        for n = 1, math.min(#map, 8) do if type(map[n]) == "string" then guests[#guests + 1] = map[n] end end
    end
    Ev.Resolve(world, Ev.Record(world, "party", { id = rec.id, score = rec.score, outcome = outcome },
        { family = "party", who = guests, budget = false, text = PARTY_TEXT[outcome] or "The party is over." }), outcome)
end)

-- The social module's own reconciliation (SS.Social.Reconcile emits "reconciled"): the pair's
-- open argument records are settled too (social resolves the one it holds the id of itself).
SS.On("reconciled", function(world, aId, bId)
    if type(world) ~= "table" or not world.root then return end
    for _, e in ipairs(Ev.Open(world, "argument")) do
        local w = e.who or {}
        if (w[1] == aId and w[2] == bId) or (w[1] == bId and w[2] == aId) then Ev.Resolve(world, e, "reconciled") end
    end
end)

-- Social: arguments and reconciliation seen through the shared executor.
local RECONCILE = { apologize = true, apologise = true, make_up = true, makeup = true, reconcile = true }
SS.On("actionEnded", function(actor, act, status)
    local world = SS.Sim.world
    if not world or not act or status ~= "done" or not act.tid then return end
    if RECONCILE[act.iid] then
        for _, e in ipairs(Ev.Open(world, "argument")) do
            local w = e.who or {}
            if (w[1] == actor.id and w[2] == act.tid) or (w[2] == actor.id and w[1] == act.tid) then
                local other = world.actors[act.tid]
                Ev.Resolve(world, e, "reconciled", actor.name .. " and " .. (other and other.name or "their housemate") .. " made up.")
            end
        end
    elseif act.iid == "argue" and not (act.data and act.data.source == "events") then
        local recent = false
        for _, e in ipairs(Ev.Open(world, "argument")) do
            if e.who and ((e.who[1] == actor.id and e.who[2] == act.tid) or (e.who[2] == actor.id and e.who[1] == act.tid)) then recent = true end
        end
        if not recent then
            local other = world.actors[act.tid]
            Ev.Record(world, "argument", {}, { who = { actor.id, act.tid }, family = "argument", budget = false,
                text = actor.name .. " and " .. (other and other.name or "someone") .. " argued." })
        end
    end
end)

-- Hourly checks: spoiled food, wilted plants, repairs, argument fade.
-- An object that already belongs to an open event (a comic casserole, say) is that event's business.
local function claimed(world, oid, kind)
    for _, e in ipairs(Ev.Open(world, nil, world.lot.id)) do
        if e.kind ~= kind and e.targets and e.targets[1] == oid then return true end
    end
    return false
end
Ev.OnHour("observe", function(world)
    local lot = world.lot
    for _, oid in ipairs(Ev.SortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local st = o.state
        if st and st.spoiled and not Ev.ForTarget(world, "spoiled_food", oid) and not claimed(world, oid, "spoiled_food") then
            local def = SS.Objects[o.def]
            Ev.Record(world, "spoiled_food", {}, { targets = { oid }, family = "spoiled_food", budget = false,
                text = (def and def.name or "Some food") .. " has gone off." })
        end
        if st and st.wilted and not Ev.ForTarget(world, "garden", oid) and not claimed(world, oid, "garden") then
            local def = SS.Objects[o.def]
            Ev.Record(world, "garden", { cause = "wilted" }, { targets = { oid }, family = "garden", budget = false,
                text = (def and def.name or "A plant") .. " is wilting." })
        end
    end
    for _, e in ipairs(Ev.Open(world, nil, lot.id)) do
        local o = e.targets and e.targets[1] and lot.objects[e.targets[1]]
        if e.kind == "breakdown" then
            if not o then Ev.Resolve(world, e, "removed")
            elseif not (o.state and o.state.broken) then Ev.Resolve(world, e, "repaired") end
        elseif e.kind == "spoiled_food" then
            if not o or not (o.state and o.state.spoiled) then Ev.Resolve(world, e, "cleared") end
        elseif e.kind == "garden" and e.data.cause == "wilted" then
            if not o or not (o.state and o.state.wilted) then Ev.Resolve(world, e, "recovered") end
        elseif e.kind == "garden" then
            if world.time - e.t > 2 * 1440 then Ev.Resolve(world, e, "passed") end
        elseif e.kind == "argument" or e.kind == "social.argument" then
            -- (social forgets an unapologised conflict after the same three days, silently)
            if world.time - e.t > 3 * 1440 then Ev.Resolve(world, e, "faded") end
        end
    end
end, 10)

---------------------------------------------------------------------------------------------------
-- Comic surprises: original harmless oddities, each with a consequence. At least five are
-- required; seven are implemented (casserole, parcel, sofa coins, pigeon, midnight broadcast,
-- garden gnome, hiccups).
local C = D.comic

local function interaction(id, def) SS.Interactions[id] = def end

local function ifIndoor(world, level) return function(i, j) return SS.World.RoomAt(world, level, i, j) > 0 end end

local function randomCell(world, level, pred, stream)
    local lot, cells = world.lot, {}
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do
            if not SS.World.Blocked(world, level, i, j) and (not pred or pred(i, j)) then cells[#cells + 1] = { i, j } end
        end
    end
    local c = SS.Pick(world, stream or "events", cells)
    if c then return c[1], c[2] end
end
Ev.RandomCell = randomCell

local function openComic(world, defId) return Ev.CountDef(world.lot, defId) > 0 end

local function finishComic(world, o, outcome, text)
    local e = Ev.ForTarget(world, o.state and o.state.kind or "comic", o.id)
    if not e then
        for _, r in ipairs(Ev.Open(world, nil, world.lot.id)) do
            if r.targets and r.targets[1] == o.id then e = r end
        end
    end
    Ev.RemoveObject(world, world.lot, o.id)
    if e then Ev.Resolve(world, e, outcome, text) end
end

-- 1. Mystery casserole on the doorstep ----------------------------------------------------
Ev.families.comic_casserole = {
    eligible = function(world)
        if openComic(world, "ev_casserole") then return false, "one is already there" end
        if #awakeMembers(world) == 0 then return false, "nobody awake" end
        return true
    end,
    run = function(world)
        local i, j = Ev.Doorstep(world)
        local o = Ev.AddObject(world, nil, "ev_casserole", i, j, 0, 0, { made = world.time, kind = "comic_casserole" })
        return Ev.Record(world, "comic_casserole", {}, { targets = { o.id }, family = "comic_casserole",
            text = "Someone left a mystery casserole on the doorstep. There is a note, but no name." })
    end,
}
interaction("ev_eat_casserole", {
    label = "Eat the Mystery Casserole", category = "Food", slot = "near", pose = "eat_stand", dur = 20,
    gain = { hunger = C.casserole.hunger }, advert = { hunger = 45 },
    test = function(world, actor, o)
        if o.state and o.state.spoiled then return false, "It has gone off. Throw it away." end
        if not Ev.IsHuman(actor) then return false, "Not for pets." end
        return true
    end,
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        local e = Ev.ForTarget(world, "comic_casserole", o.id)
        local good = true
        if e and Ev.Once(e, "outcome", world) then
            good = SS.Random(world, "events") < C.casserole.goodChance
            e.data.good = good
        elseif e then good = e.data.good ~= false end
        if good then
            SS.Needs.Add(actor, "fun", 10)
            Ev.Say(world, actor, "proud_meal", { objDef = "ev_casserole" }, "Whoever made this can cook.", "hunger")
        else
            SS.Needs.Add(actor, "hygiene", -15); SS.Needs.Add(actor, "bladder", -25)
            Ev.Tell(world, actor, actor.name .. " regrets the casserole.", "bladder")
        end
        finishComic(world, o, good and "eaten" or "regretted",
            good and (actor.name .. " ate the mystery casserole. It was excellent.") or (actor.name .. " ate the mystery casserole and spent the evening regretting it."))
    end,
})
interaction("ev_bin_casserole", {
    label = "Throw It Away", category = "Chores", slot = "near", pose = "use", dur = 3, advert = {}, manualOnly = true,
    onEnd = function(world, actor, act, o, status)
        if status == "done" and o then finishComic(world, o, "binned", actor.name .. " threw the mystery casserole away.") end
    end,
})
Ev.OnHour("casserole", function(world)
    for _, oid in ipairs(Ev.SortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        if o.def == "ev_casserole" and not o.state.spoiled and world.time - (o.state.made or world.time) >= C.casserole.spoilAfter then
            o.state.spoiled = true
            SS.Emit("lotChanged", "state", oid)
            Ev.Journal(world, "The mystery casserole on the doorstep has gone off.", Ev.ForTarget(world, "comic_casserole", oid))
        end
    end
end, 20)

-- 2. Misdelivered parcel --------------------------------------------------------------------
-- The contents: a seeded pick among buyable catalogue objects of C.parcel.cats within the price
-- band (ids sorted, so the same seed gives the same item), else C.parcel.fallback.
function Ev.ParcelItems()
    local out = {}
    local cats, band = C.parcel.cats, C.parcel.price
    for _, id in ipairs(Ev.SortedKeys(SS.Objects)) do
        local def = SS.Objects[id]
        if type(def) == "table" and not def.system and def.buyable ~= false and cats[def.cat or ""]
            and type(def.price) == "number" and def.price >= band[1] and def.price <= band[2] then
            out[#out + 1] = id
        end
    end
    return out
end
local function parcelItem(world)
    local id = SS.Pick(world, "events", Ev.ParcelItems())
    if id then return id end
    return SS.Objects[C.parcel.fallback] and C.parcel.fallback or nil
end
Ev.ParcelItem = parcelItem

Ev.families.comic_parcel = {
    eligible = function(world)
        if openComic(world, "ev_parcel") then return false, "one is already there" end
        if #awakeMembers(world) == 0 then return false, "nobody awake" end
        return true
    end,
    run = function(world)
        local i, j = Ev.Doorstep(world)
        local o = Ev.AddObject(world, nil, "ev_parcel", i, j, 0, 0, { kind = "comic_parcel" })
        return Ev.Record(world, "comic_parcel", {}, { targets = { o.id }, family = "comic_parcel",
            text = "A parcel addressed to 'The Occupant, Probably' turned up on the step." })
    end,
}
interaction("ev_open_parcel", {
    label = "Open It Anyway", category = "Home", slot = "near", pose = "use", dur = 4, advert = {}, manualOnly = true,
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        local e = Ev.ForTarget(world, "comic_parcel", o.id)
        local text
        if e and Ev.Once(e, "contents", world) then
            local defId = SS.Random(world, "events") < C.parcel.keepChance and parcelItem(world)
            local def = defId and SS.Objects[defId]
            -- the item goes into the household inventory; when it cannot (no inventory, or full),
            -- the parcel held vouchers instead, so the text never claims something that did not happen
            local kept = def and SS.Inventory and SS.Inventory.Add
                and Ev.Call(SS.Inventory.Add, world, { kind = "object", def = defId, name = def.name, value = def.price, data = { source = "parcel" } })
            if kept then
                e.data.item = defId
                text = actor.name .. " opened the stray parcel: a " .. def.name .. ", now in the household inventory."
            else
                local cash = SS.RandomInt(world, "events", C.parcel.cash[1], C.parcel.cash[2])
                SS.Money(world, cash, "gift", "Stray parcel: a sheet of cash-back vouchers")
                e.data.cash = cash
                text = actor.name .. " opened the stray parcel and found vouchers worth " .. SS.U.fmtMoney(cash) .. "."
            end
            if (actor.personality and actor.personality.nice or 5) >= 7 then
                SS.Needs.Add(actor, "fun", -5)
                Ev.Balloon(world, actor, "That wasn't really ours.", "social")
            end
        end
        finishComic(world, o, "opened", text)
    end,
})
interaction("ev_return_parcel", {
    label = "Return to Sender", category = "Home", slot = "near", pose = "use", dur = 3, advert = {}, manualOnly = true,
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        SS.Needs.Add(actor, "fun", C.parcel.returnFun)
        SS.Needs.Add(actor, "social", 5)
        finishComic(world, o, "returned", actor.name .. " sent the stray parcel back with a polite note.")
    end,
})

-- 3. Money down the back of the seat --------------------------------------------------------
local function sittingMember(world)
    for _, a in ipairs(Ev.Members(world)) do
        local act = a.act
        local o = act and act.phase == "perform" and act.target and world.lot.objects[act.target.oid]
        local def = o and SS.Objects[o.def]
        if def and (def.seat or (act.target.slotName or ""):find("seat")) then return a, o end
    end
end
Ev.families.comic_coins = {
    eligible = function(world)
        if not sittingMember(world) then return false, "nobody is sitting down" end
        return true
    end,
    run = function(world)
        local a, o = sittingMember(world)
        if not a then return nil, "nobody sitting" end
        local amount = SS.RandomInt(world, "events", C.coins.min, C.coins.max)
        local def = SS.Objects[o.def]
        local e = Ev.Record(world, "comic_coins", { amount = amount }, { who = { a.id }, targets = { o.id }, family = "comic_coins",
            text = a.name .. " found " .. SS.U.fmtMoney(amount) .. " down the back of the " .. (def and def.name or "seat") .. "." })
        if Ev.Once(e, "money", world) then SS.Money(world, amount, "gift", "Found down the back of the seat") end
        Ev.Tell(world, a, "Found " .. SS.U.fmtMoney(amount) .. " in the cushions!", "fun")
        return Ev.Resolve(world, e, "found")
    end,
}

-- 4. The indignant pigeon -------------------------------------------------------------------
Ev.families.comic_pigeon = {
    eligible = function(world)
        if openComic(world, "ev_pigeon") then return false, "already has a pigeon" end
        if not randomCell(world, 0, ifIndoor(world, 0), "events_probe") then return false, "no room indoors" end
        return true
    end,
    run = function(world)
        local i, j = randomCell(world, 0, ifIndoor(world, 0), "events")
        if not i then return nil, "no room indoors" end
        local o = Ev.AddObject(world, nil, "ev_pigeon", i, j, 0, 0, { since = world.time, kind = "comic_pigeon" })
        return Ev.Record(world, "comic_pigeon", {}, { targets = { o.id }, family = "comic_pigeon",
            text = "A pigeon got into the house and has no plans to leave." })
    end,
}
interaction("ev_shoo_pigeon", {
    label = "Shoo the Pigeon", category = "Chores", slot = "near", pose = "argue", dur = 5, advert = { room = 20, fun = 6 },
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        if SS.Random(world, "events") < C.pigeon.shooChance then
            SS.Needs.Add(actor, "fun", C.pigeon.fun)
            finishComic(world, o, "shooed", actor.name .. " shooed the pigeon out. It left a feather as a formal complaint.")
        else
            local i, j = randomCell(world, o.level or 0, ifIndoor(world, o.level or 0), "events")
            if i then o.x, o.y = i, j; SS.Emit("lotChanged", "object", o.id) end
            Ev.Tell(world, actor, "The pigeon relocated. It is not leaving on your terms.", "room")
        end
    end,
})
Ev.OnHour("pigeon", function(world)
    for _, oid in ipairs(Ev.SortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        if o.def == "ev_pigeon" and world.time - (o.state.since or world.time) >= 2 * 1440 then
            finishComic(world, o, "left", "The pigeon left on its own, unimpressed.")
        end
    end
end, 21)

-- 5. The midnight broadcast: a TV or stereo switches itself on at night -----------------------
local function isSetTop(def) return def and (def.viewer or Ev.HasTag(def, "tv") or Ev.HasTag(def, "stereo") or Ev.HasTag(def, "radio")) end
local function broadcastTarget(world)
    for _, oid in ipairs(Ev.SortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if isSetTop(def) and not (o.state and (o.state.on or o.state.broken)) then return o end
    end
end
Ev.families.comic_broadcast = {
    eligible = function(world)
        if not broadcastTarget(world) then return false, "no idle TV or stereo" end
        if #Ev.Members(world, function(a) return a.sleeping end) == 0 then return false, "nobody asleep" end
        return true
    end,
    run = function(world)
        local o = broadcastTarget(world)
        if not o then return nil, "nothing to switch on" end
        o.state = o.state or {}
        o.state.on, o.state.selfOn = true, world.time
        SS.Emit("lotChanged", "state", o.id)
        local def = SS.Objects[o.def]
        return Ev.Record(world, "comic_broadcast", {}, { targets = { o.id }, family = "comic_broadcast",
            text = "In the small hours the " .. (def and def.name or "television") .. " switched itself on, loudly." })
    end,
}
interaction("ev_hush", {
    label = "Switch It Off", category = "Home", slot = "viewer", pose = "use", dur = 1, advert = {}, manualOnly = true,   -- from a facing seat (the remote), else in front
    test = function(world, actor, o)
        if not (o.state and o.state.selfOn) then return false, "It is behaving itself." end
        return true
    end,
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        o.state.on, o.state.selfOn = false, nil
        SS.Emit("lotChanged", "state", o.id)
        local e = Ev.ForTarget(world, "comic_broadcast", o.id)
        if e then Ev.Resolve(world, e, "switched_off", actor.name .. " switched it off and unplugged it, just in case.") end
    end,
})
Ev.OnHour("broadcast", function(world)
    for _, e in ipairs(Ev.Open(world, "comic_broadcast", world.lot.id)) do
        local o = world.lot.objects[e.targets[1]]
        if not o or not (o.state and o.state.on) then
            if o then o.state.selfOn = nil end
            Ev.Resolve(world, e, "stopped")
        elseif world.time - e.t >= 180 then
            o.state.on, o.state.selfOn = false, nil
            SS.Emit("lotChanged", "state", o.id)
            Ev.Resolve(world, e, "switched_off", "The set switched itself off again, as if nothing had happened.")
        else
            -- sleepers in the same room may wake up (one chance per hour each)
            local room = SS.World.RoomAt(world, o.level or 0, o.x, o.y)
            for _, a in ipairs(Ev.Members(world, function(m) return m.sleeping end)) do
                if (a.level or 0) == (o.level or 0) and SS.World.RoomAt(world, a.level or 0, floor(a.x), floor(a.y)) == room
                    and SS.Random(world, "events") < 0.3 then
                    SS.Actions.Cancel(world, a, 0)
                    Ev.Tell(world, a, a.name .. " was woken by the midnight broadcast.", "energy")
                end
            end
        end
    end
end, 22)

-- 6. The wandering garden gnome -------------------------------------------------------------
local function ifOutdoor(world) return function(i, j) return SS.World.RoomAt(world, 0, i, j) == 0 and not Ev.NearOpening(world, 0, i, j) end end
Ev.families.comic_gnome = {
    eligible = function(world)
        if openComic(world, "ev_gnome") then return false, "one gnome at a time" end
        if not randomCell(world, 0, ifOutdoor(world), "events_probe") then return false, "no lawn" end
        return true
    end,
    run = function(world)
        local i, j = randomCell(world, 0, ifOutdoor(world), "events")
        if not i then return nil, "no lawn" end
        local o = Ev.AddObject(world, nil, "ev_gnome", i, j, SS.RandomInt(world, "events", 0, 3), 0, { since = world.time, adopted = false, kind = "comic_gnome" })
        return Ev.Record(world, "comic_gnome", {}, { targets = { o.id }, family = "comic_gnome",
            text = "A garden gnome with a tiny suitcase has appeared on the lawn." })
    end,
}
interaction("ev_adopt_gnome", {
    label = "Let Him Stay", category = "Home", slot = "near", pose = "use", dur = 2, advert = {}, manualOnly = true, requireState = { adopted = false },
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        o.state.adopted = true
        local e = Ev.ForTarget(world, "comic_gnome", o.id)
        if e then Ev.Resolve(world, e, "adopted", actor.name .. " decided the gnome can stay. He brightens the lawn a little.") end
    end,
})
interaction("ev_sell_gnome", {
    label = "Sell to a Collector", category = "Home", slot = "near", pose = "use", dur = 3, advert = {}, manualOnly = true,
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        local e = Ev.ForTarget(world, "comic_gnome", o.id)
        if not e then
            -- adopted gnomes can still be sold (their record is resolved already)
            e = Ev.Record(world, "comic_gnome", {}, { targets = { o.id }, family = "comic_gnome", budget = false })
        end
        if Ev.Once(e, "sale", world) then SS.Money(world, C.gnome.sale, "sale", "Sold a wandering garden gnome") end
        finishComic(world, o, "sold", actor.name .. " sold the gnome to a collector for " .. SS.U.fmtMoney(C.gnome.sale) .. ".")
    end,
})
Ev.OnHour("gnome", function(world)
    for _, oid in ipairs(Ev.SortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        if o.def == "ev_gnome" and not o.state.adopted and world.time - (o.state.since or world.time) >= 3 * 1440 then
            finishComic(world, o, "wandered_off", "The gnome picked up his suitcase and moved on.")
        end
    end
end, 23)

-- 7. Hiccups --------------------------------------------------------------------------------
Ev.families.comic_hiccups = {
    eligible = function(world)
        for _, a in ipairs(awakeMembers(world)) do
            local p = Ev.PersonIf(world, a.id)
            if not (p and p.hiccups) then return true end
        end
        return false, "nobody available"
    end,
    run = function(world)
        local list = {}
        for _, a in ipairs(awakeMembers(world)) do
            local p = Ev.PersonIf(world, a.id)
            if not (p and p.hiccups) then list[#list + 1] = a end
        end
        local a = SS.Pick(world, "events", list)
        if not a then return nil, "nobody" end
        local hours = SS.RandomInt(world, "events", C.hiccups.hours[1], C.hiccups.hours[2])
        Ev.Person(world, a.id).hiccups = world.time + hours * 60
        Ev.Tell(world, a, a.name .. " has the hiccups. Again. Hic.", "comfort")
        return Ev.Record(world, "comic_hiccups", { untilT = world.time + hours * 60 }, { who = { a.id }, family = "comic_hiccups",
            text = a.name .. " came down with a stubborn case of the hiccups." })
    end,
}
Ev.OnHour("hiccups", function(world)
    for _, e in ipairs(Ev.Open(world, "comic_hiccups")) do
        local rid = e.who[1]
        local p = rid and Ev.PersonIf(world, rid)
        if not p or not p.hiccups or world.time >= p.hiccups then
            if p then p.hiccups = nil end
            local r = world.root.residents[rid]
            Ev.Resolve(world, e, "cured", (r and r.name or "They") .. "'s hiccups finally stopped.")
        end
    end
end, 24)

---------------------------------------------------------------------------------------------------
-- Responders brought on by the visitors module itself (once Visitors.Request is real) are marked
-- as arrived when they show up on the lot, so events waiting on them move on.
Ev.OnMinute("responders", function(world)
    local ids = Ev.ActorIds(world)
    for n = 1, #ids do
        local id = ids[n]
        local a = world.actors[id]
        local rd = a and a.role and a.roleData
        if rd and rd.eventId then
            local e = Ev.Find(world, rd.eventId)
            local rec = e and e.data.responders and e.data.responders[id]
            if rec and not rec.arrived and not rec.skipped then rec.arrived = world.time end
        end
    end
    if RT.minute and RT.minute % 5 == 0 then checkRequests(world) end
end, 5)

---------------------------------------------------------------------------------------------------
-- Need modifiers (mourning, hiccups, pests, sleepless nights), recomputed once per sim minute
-- into a small runtime table so the needs hook stays a cheap table lookup. One shared `add`
-- function (no closure per actor per minute).
local MODS = {}
Ev.MODS = MODS
Ev.modifiers = {}   -- list of fn(world, actor, add(need, perHour))

function Ev.OnModifiers(fn) Ev.modifiers[#Ev.modifiers + 1] = fn end

local modCur, modId
local function modAdd(need, v)
    local m = modCur
    if not m then m = {}; MODS[modId] = m; modCur = m end
    m[need] = (m[need] or 0) + v
end

Ev.OnMinute("modifiers", function(world)
    for id, m in pairs(MODS) do
        if not world.actors[id] then MODS[id] = nil else for k in pairs(m) do m[k] = nil end end
    end
    local ids, fns = Ev.ActorIds(world), Ev.modifiers
    for n = 1, #ids do
        local id = ids[n]
        local a = world.actors[id]
        if a and not a.noNeeds then
            modCur, modId = MODS[id], id
            for k = 1, #fns do fns[k](world, a, modAdd) end
        end
    end
    modCur, modId = nil, nil
end, 90)

Ev.OnModifiers(function(world, a, add)
    local p = Ev.PersonIf(world, a.id)
    if p and p.hiccups and world.time < p.hiccups then add("comfort", C.hiccups.comfortRate) end
end)

-- The midnight broadcast makes for poor sleep in the same room while it plays.
Ev.OnModifiers(function(world, a, add)
    if not a.sleeping then return end
    local list, lotId = Ev.State(world).list, world.lot.id
    for n = 1, #list do
        local e = list[n]
        if e.kind == "comic_broadcast" and e.state ~= "resolved" and e.lotId == lotId then
            local o = world.lot.objects[e.targets[1]]
            if o and o.state and o.state.selfOn and (o.level or 0) == (a.level or 0)
                and SS.World.RoomAt(world, o.level or 0, o.x, o.y) == SS.World.RoomAt(world, a.level or 0, floor(a.x), floor(a.y)) then
                add("energy", C.broadcast.energyRate)
                return
            end
        end
    end
end)

if SS.Needs and SS.Needs.RegisterRateHook then
    SS.Needs.RegisterRateHook(function(world, actor, need, rate)
        local m = MODS[actor.id]
        if m then
            local d = m[need]
            if d then return rate + d end
        end
        return rate
    end)
end

---------------------------------------------------------------------------------------------------
-- Save validation: defaults and repairs for root.events.
SS.Save.RegisterValidator(function(root, p)
    if root.events ~= nil and type(root.events) ~= "table" then root.events = nil; p[#p + 1] = "event records were damaged and reset" end
    local s = Ev.State(root)
    local maxId = 0
    for n = #s.list, 1, -1 do
        local e = s.list[n]
        if type(e) ~= "table" or type(e.id) ~= "string" or type(e.kind) ~= "string" then
            table.remove(s.list, n)
            p[#p + 1] = "dropped a damaged event record"
        else
            e.fx = type(e.fx) == "table" and e.fx or {}
            e.data = type(e.data) == "table" and e.data or {}
            e.who = type(e.who) == "table" and e.who or {}
            e.targets = type(e.targets) == "table" and e.targets or {}
            if e.state ~= "active" and e.state ~= "aftermath" and e.state ~= "resolved" then e.state = "resolved" end
            local num = tonumber((e.id or ""):match("^ev(%d+)$"))
            if num and num > maxId then maxId = num end
        end
    end
    if type(s.nextId) ~= "number" or s.nextId <= maxId then s.nextId = maxId + 1 end
    for rid in pairs(s.people) do
        if not root.residents[rid] then s.people[rid] = nil end
    end
    -- Records about people who have all died since (a hunger clock, a shock, hiccups...) settle:
    -- nothing can resolve them any more. Death records and the household's own records stay.
    for _, e in ipairs(s.list) do
        if e.state ~= "resolved" and not Ev.ABOUT_THE_DEAD[e.kind] and #e.who > 0 then
            local allDead = true
            for _, rid in ipairs(e.who) do
                local r = root.residents[rid]
                if not (r and r.dead) then allDead = false; break end
            end
            if allDead then
                e.state, e.outcome, e.resolvedAt = "resolved", e.kind == "ghost" and "faded" or "died", root.time
                p[#p + 1] = "settled a " .. e.kind .. " record about someone who has died"
            end
        end
    end
    return true
end)
