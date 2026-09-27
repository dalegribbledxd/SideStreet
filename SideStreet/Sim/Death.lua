-- SideStreet death and aftermath (brief 16.2-16.3): the exactly-once transition, memorials,
-- the Registrar of Departures and his plea, mourning, ghosts, the last-adult rules and the
-- household continuation path. Owner: events module. Everything is non-graphic.
--
-- Saved state
--   person: dead, deathCause, diedAt, deathLot, ghost (only while haunting)
--   household: members (the dead are removed), deceased = { { id, name, diedAt, cause } } (bounded),
--              flags.ended = { t, reason } / flags.guardianLost
--   root.events.deaths[rid] = { t, cause, ev, lotId, memorial = { lotId, oid } }
--   root.events.people[rid].grief = { [deadId] = hours of grief left }, .dying = { cause, at }
--   memorial objects (ev_grave / ev_urn) with state { rid, name, died, cause }
local _, SS = ...
local D = SS.Death or {}
SS.Death = D
local Ev = SS.Events
local DD = SS.EventsData.death
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local function deaths(world) return Ev.State(world).deaths end

---------------------------------------------------------------------------------------------------
-- Memorials. Placement works on any lot (the death may happen away from home): an outdoor
-- cell away from doors, paths and other objects' access cells gets a headstone; otherwise an
-- indoor cell gets an urn.

local function lotOccupancy(lot, level)
    local occ = {}
    for _, o in pairs(lot.objects) do
        local def = SS.Objects[o.def]
        if def and (o.level or 0) == level then
            for _, c in ipairs(Ev.ObjectCells(o)) do occ[c[2] * 1000 + c[1]] = true end
            for _, sl in pairs(def.slots or {}) do
                for _, ap in ipairs(sl.approaches or {}) do
                    local dx, dy = SS.Grid.rot(ap[1], ap[2], o.f or 0)
                    occ[(o.y + dy) * 1000 + (o.x + dx)] = occ[(o.y + dy) * 1000 + (o.x + dx)] or "access"
                end
            end
        end
    end
    return occ
end

local function nearOpeningOn(lot, i, j)
    local walls = lot.walls[0] or {}
    for k = 0, 3 do
        local d = SS.Grid.DIRS[k]
        local wl = walls[SS.Grid.edgeBetween(i, j, i + d[1], j + d[2])]
        if wl and SS.World.OPENINGS[wl.kind] then return true end
    end
    return false
end

-- Is the cell outdoors? On the running lot the room map knows; elsewhere, outdoor finishes
-- (grass, dirt, path) or no floor at all count as outdoors.
local function outdoorCell(world, lot, i, j)
    if world.lot == lot then return SS.World.RoomAt(world, 0, i, j) == 0 end
    local f = SS.World.FloorAt(lot, 0, i, j)
    return not f or tostring(f):find("grass", 1, true) ~= nil or tostring(f):find("dirt", 1, true) ~= nil
end

function D.MemorialCell(world, lot)
    local occ = lotOccupancy(lot, 0)
    local ei, ej = (lot.entry and lot.entry[1]) or floor(lot.w / 2), (lot.entry and lot.entry[2]) or (lot.h - 1)
    local best
    for pass = 1, 2 do
        for j = 0, lot.h - 1 do
            for i = 0, lot.w - 1 do
                if not occ[j * 1000 + i] and outdoorCell(world, lot, i, j) == (pass == 1) and not nearOpeningOn(lot, i, j)
                    and abs(i - ei) + abs(j - ej) > 2 then
                    -- keep corridors open: at least three free neighbours
                    local free = 0
                    for k = 0, 3 do
                        local d = SS.Grid.DIRS[k]
                        local ni, nj = i + d[1], j + d[2]
                        if SS.World.InLot(lot, ni, nj) and occ[nj * 1000 + ni] ~= true then free = free + 1 end
                    end
                    local path = SS.World.FloorAt(lot, 0, i, j)
                    if free >= 3 and not (path and tostring(path):find("path", 1, true)) then
                        -- back of the lot first, then along it
                        local score = j * 100 + i
                        if not best or score < best[3] then best = { i, j, score, pass == 1 and "ev_grave" or "ev_urn" } end
                    end
                end
            end
        end
        if best then return best[1], best[2], best[4] end
    end
    return nil
end

local function addMemorial(world, lot, r, cause)
    local i, j, defId = D.MemorialCell(world, lot)
    if not i then return nil end
    local state = { rid = r.id, name = r.name, died = world.time, cause = cause, day = floor(world.time / 1440) + 1 }
    if lot == world.lot then
        return Ev.AddObject(world, lot, defId, i, j, 0, 0, state)
    end
    local id = Ev.NewObjectId(lot)
    local o = { id = id, def = defId, x = i, y = j, f = 0, level = 0, state = state, bought = world.time, paid = 0 }
    lot.objects[id] = o
    lot.version = (lot.version or 1) + 1
    return o
end

function D.Memorials(world, lot)
    lot = lot or world.lot
    local out = {}
    for _, oid in ipairs(Ev.SortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and Ev.HasTag(def, "memorial") and o.state and o.state.rid then out[#out + 1] = o end
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Grief and mourning.

local function closeness(world, survivor, dead)
    local root = world.root
    local rel = root.social and root.social.rel
    local r1 = rel and rel[survivor.id .. ">" .. dead.id]
    local c = 0
    if survivor.householdId and survivor.householdId == dead.householdId then c = 0.7 end
    if r1 then
        if r1.flags and r1.flags.family then c = max(c, 1) end
        if r1.flags and r1.flags.partner then c = max(c, 1) end
        local v = max(r1.daily or 0, r1.life or 0)
        if v >= 50 then c = max(c, 0.8) elseif v >= 20 then c = max(c, 0.4) end
    end
    return c
end

function D.Grief(world, rid)
    local p = Ev.PersonIf(world, rid)
    local total = 0
    if p and p.grief then for _, v in pairs(p.grief) do total = total + max(0, v) end end
    return total
end

local function griefFactor(world, a) return min(1, D.Grief(world, a.id) / DD.mournHours) end
D.GriefFactor = griefFactor

Ev.OnModifiers(function(world, a, add)
    if a.dead then return end
    local f = griefFactor(world, a)
    if f > 0 then
        for need, rate in pairs(DD.mournRates) do add(need, rate * f) end
    end
end)

-- Hourly: grief fades; the mourning record resolves when nobody grieves any more.
Ev.OnHour("grief", function(world)
    local people = Ev.State(world).people
    for _, rid in ipairs(Ev.SortedKeys(people)) do
        local p = people[rid]
        if p.grief then
            for _, dead in ipairs(Ev.SortedKeys(p.grief)) do
                p.grief[dead] = p.grief[dead] - 1
                if p.grief[dead] <= 0 then p.grief[dead] = nil end
            end
            if not next(p.grief) then p.grief = nil end
        end
    end
    for _, e in ipairs(Ev.Open(world, "mourning")) do
        local dead = e.data.dead
        local anyone = false
        for _, p in pairs(people) do if p.grief and p.grief[dead] then anyone = true end end
        if not anyone then
            local r = world.root.residents[dead]
            Ev.Resolve(world, e, "healed", "The household has made its peace with losing " .. (r and r.name or "them") .. ".")
        end
    end
end, 15)

SS.Interactions.ev_mourn = {
    label = "Mourn", slot = "front", pose = "mourn", maxDur = 60, category = "Basics",
    advertise = function(world, actor, o)
        local p = Ev.PersonIf(world, actor.id)
        local g = p and p.grief and o.state and p.grief[o.state.rid]
        if not g or g <= 0 then return nil end
        local f = min(1, g / DD.mournHours)
        return { comfort = 40 * f, fun = 25 * f }
    end,
    test = function(world, actor, o)
        if not Ev.IsHuman(actor) then return false, "Only people mourn here." end
        if actor.role then return false, "Only people who knew them mourn here." end
        return true
    end,
    onTick = function(world, actor, act, o, dt)
        local p = Ev.PersonIf(world, actor.id)
        local rid = o and o.state and o.state.rid
        if p and p.grief and rid and p.grief[rid] then
            p.grief[rid] = p.grief[rid] - DD.mournRelief * dt / 60
            SS.Needs.Add(actor, "comfort", 6 * dt / 60)
            if p.grief[rid] <= 0 then p.grief[rid] = nil; act.complete = true end
        else
            act.complete = true
        end
    end,
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not (o and o.state and o.state.rid) then return end
        local p = Ev.Person(world, actor.id)
        p.visited = p.visited or {}
        if not p.visited[o.state.rid] then
            p.visited[o.state.rid] = world.time
            Ev.Journal(world, actor.name .. " spent a while at " .. (o.state.name or "the") .. "'s memorial.")
        end
    end,
}

SS.Interactions.ev_respects = {
    label = "Pay Respects", category = "Family", slot = "front", pose = "mourn", dur = 5, advert = {}, manualOnly = true,
    gain = { social = 4, fun = 2 },
    test = function(world, actor, o) return Ev.IsHuman(actor), "Only people pay respects." end,
    onEnd = function(world, actor, act, o, status)
        if status == "done" and o and o.state then Ev.Balloon(world, actor, "Rest easy, " .. (o.state.name or "friend") .. ".", "social") end
    end,
}

-- Witnesses grieve where they stand.
SS.Interactions.ev_grieve = {
    label = "Grieving", category = "Other", pose = "cry", advert = {}, manualOnly = true, maxDur = 30,
    onTick = function(world, actor, act, o, dt) if act.t + dt >= (act.data.len or DD.reactMinutes) then act.complete = true end end,
}

-- The final collapse before our own pathways (starvation, shock) call Kill.
SS.Interactions.ev_collapse = {
    label = "Collapsed", category = "Other", pose = "collapse", advert = {}, manualOnly = true, maxDur = 30,
}

---------------------------------------------------------------------------------------------------
-- The transition (exactly once).

local function unschedule(world, rid)
    SS.Sim.Unschedule(world, function(ev)
        local d = ev.data
        return type(d) == "table" and (d.rid == rid or d.actorId == rid or d.who == rid or d.residentId == rid or d.personId == rid)
            and ev.kind ~= "events.arrive"
    end)
end

local function markRelations(world, rid, flag)
    local root = world.root
    local rel = root.social and root.social.rel
    if type(rel) ~= "table" then return end
    for _, other in ipairs(Ev.SortedKeys(root.residents)) do
        if other ~= rid then
            local r = rel[other .. ">" .. rid]
            if type(r) == "table" then
                r.flags = r.flags or {}
                r.flags.deceased = flag or nil
            end
        end
    end
end

local function removeMember(hh, rid)
    for n = #(hh.members or {}), 1, -1 do if hh.members[n] == rid then table.remove(hh.members, n) end end
end

local function witnesses(world, dead)
    local out = {}
    local di, dj, dl = Ev.CellOf(dead)
    local room = SS.World.RoomAt(world, dl, di, dj)
    for _, a in ipairs(Ev.People(world)) do
        if a ~= dead and Ev.IsHuman(a) then
            local ai, aj, al = Ev.CellOf(a)
            if al == dl and (SS.World.RoomAt(world, al, ai, aj) == room or Ev.Dist(ai, aj, di, dj) <= 6) and not a.sleeping then
                out[#out + 1] = a
            end
        end
    end
    return out
end

local function living(world, hh, pred)
    local out = {}
    for _, rid in ipairs(hh.members or {}) do
        local r = world.root.residents[rid]
        if r and not r.dead and (not pred or pred(r)) then out[#out + 1] = r end
    end
    return out
end
D.Living = living

-- Transition a resident to dead exactly once. cause: "starvation", "fire", "electrocution",
-- "drowning", "neglect", ... Returns true, or false and why.
function D.Kill(world, actor, cause, opts)
    if type(actor) == "string" then actor = world.root.residents[actor] end
    if not actor then return false, "Nobody to kill." end
    if actor.dead then return false, "Already dead." end
    opts = opts or {}
    cause = cause or "unknown"
    local root = world.root
    local rid = actor.id
    local onLot = world.actors[rid] == actor
    local hh = actor.householdId and root.households[actor.householdId]
    local causeDef = DD.causes[cause] or DD.causes.unknown
    local text = string.format(causeDef.text, actor.name)
    local di, dj, dl = Ev.CellOf(actor)
    local wit = onLot and witnesses(world, actor) or {}

    -- 1. the record, the flags, the moment (so re-entry from any hook sees `dead` at once)
    actor.dead, actor.deathCause, actor.diedAt = true, cause, world.time
    actor.deathLot = onLot and world.lot.id or (actor.away and actor.away.lotId) or (hh and hh.lotId)
    local pleaRoll = SS.Random(world, "death")    -- rolled now and saved: reloading cannot re-roll a plea
    local e = Ev.Record(world, "death", { cause = cause, name = actor.name, pleaRoll = pleaRoll, cell = { dl, di, dj } },
        { who = { rid }, cause = cause, lane = "emergency", family = "death", budget = false, hh = hh and hh.id, text = text })
    deaths(world)[rid] = { t = world.time, cause = cause, ev = e.id, lotId = actor.deathLot }
    local p = Ev.Person(world, rid)
    p.fire, p.onFire, p.dying, p.starve, p.grief, p.hiccups = nil, nil, nil, nil, nil, nil
    -- open records that were only about them (the hunger clock, a shock, being on fire...) end here
    Ev.SettleFor(world, rid)

    -- 2. actions, reservations, held things, schedules
    if onLot then
        if actor.act then SS.Actions.Finish(world, actor, "cancelled") end
        actor.queue = {}
        actor.carry = nil
        SS.Sim.RemoveActor(world, rid, { reason = "dead" })
    end
    actor.carry, actor.act, actor.queue, actor.sleeping, actor.walking, actor.onObj = nil, nil, {}, nil, nil, nil
    actor.role, actor.roleData, actor.ghost = nil, nil, nil
    actor.lotId, actor.away = nil, nil
    unschedule(world, rid)
    if root.outing and type(root.outing.participants) == "table" then
        for n = #root.outing.participants, 1, -1 do
            if root.outing.participants[n] == rid then table.remove(root.outing.participants, n) end
        end
    end

    -- 3. household membership and relationships (relationships stay; flags mark the death)
    if hh then
        removeMember(hh, rid)
        hh.deceased = hh.deceased or {}
        hh.deceased[#hh.deceased + 1] = { id = rid, name = actor.name, diedAt = world.time, cause = cause }
        while #hh.deceased > 20 do table.remove(hh.deceased, 1) end
    end
    markRelations(world, rid, true)

    -- 4. memorial on the lot where they died (their home lot if that one cannot take it, or if
    -- they died at a community venue: a headstone does not belong in the cafe)
    local lot = onLot and world.lot or (actor.deathLot and root.hood.lots[actor.deathLot])
    local home = hh and hh.lotId and root.hood.lots[hh.lotId]
    if lot and lot.kind == "community" and home then lot = home end
    local memo = lot and addMemorial(world, lot, actor, cause)
    if not memo and hh and hh.lotId and root.hood.lots[hh.lotId] and root.hood.lots[hh.lotId] ~= lot then
        lot = root.hood.lots[hh.lotId]
        memo = addMemorial(world, lot, actor, cause)
    end
    if memo then
        deaths(world)[rid].memorial = { lotId = lot.id, oid = memo.id }
        e.targets = { memo.id }
        e.data.memorial = { lotId = lot.id, oid = memo.id }
    end

    -- 5. everyone is told; witnesses grieve on the spot; survivors mourn
    Ev.Emergency(world, text, "emergency")
    Ev.Audio("Cue", "death")
    for _, a in ipairs(wit) do
        local wp = Ev.PersonIf(world, a.id)
        if not (wp and (wp.fire or wp.onFire or wp.dying)) then Ev.Pseudo(world, a, "ev_grieve", { len = DD.reactMinutes }) end
        Ev.Say(world, a, "death_grief", { dead = rid, cause = cause }, "No... no, no, no.", "social")
    end
    local mourners = {}
    for _, sid in ipairs(Ev.SortedKeys(root.residents)) do
        local s = root.residents[sid]
        if s ~= actor and not s.dead and Ev.IsHuman(s) and not s.npc then
            local c = closeness(world, s, actor)
            if c > 0 then
                local sp = Ev.Person(world, sid)
                sp.grief = sp.grief or {}
                sp.grief[rid] = DD.mournHours * c
                mourners[#mourners + 1] = sid
            end
        end
    end
    if #mourners > 0 then
        Ev.Record(world, "mourning", { dead = rid }, { who = mourners, family = "mourning", budget = false, hh = hh and hh.id,
            text = "The household is mourning " .. actor.name .. "." })
    end

    -- 6. the Registrar of Departures visits the memorial (on this lot now, or when that lot next runs)
    if memo and not opts.noVisitor then
        local delay = DD.registrarDelay + SS.RandomInt(world, "death", 0, DD.registrarJitter)
        Ev.RequestResponder(world, e, "registrar", "npc_registrar", delay, nil, lot.id)
    end

    SS.Emit("death", world, actor, cause)

    -- 7. the household after this death (A39)
    if hh then D.CheckHousehold(world, hh, actor) end
    return true
end

---------------------------------------------------------------------------------------------------
-- Last adult lost / everyone gone.

-- Dependents are living children and infants. Pets alone do not keep a household going.
local function isDependent(r) return Ev.IsDependent(r) end

-- The last adult is gone. With living children or infants, the family module's child-welfare
-- path takes over (SS.Family.OnGuardianLost; it records its own "guardian_lost"). Without that
-- module, events records "guardian_lost" itself: an ordinary, long-lived record that never holds
-- the director back and resolves when a grown-up is back or the household has ended.
function D.CheckHousehold(world, hh, lost)
    if hh.flags and hh.flags.ended then return "ended" end
    local adults = living(world, hh, function(r) return Ev.IsAdult(r) end)
    if #adults > 0 then return "ok" end
    local deps = living(world, hh, isDependent)
    if #deps > 0 then
        hh.flags = hh.flags or {}
        hh.flags.guardianLost = hh.flags.guardianLost or world.time
        local handled
        if SS.Family and SS.Family.OnGuardianLost then handled = Ev.Call(SS.Family.OnGuardianLost, world, hh) end
        if hh.flags.ended then return "ended" end    -- the welfare path already closed the household
        if not handled and not D.GuardianRecord(world, hh) then
            Ev.Journal(world, "No grown-up is left to look after the household.", nil)
            SS.Emit("notice", nil, "No adult is left in the " .. (hh.name or "") .. " household. Family services have been notified.")
            Ev.Record(world, "guardian_lost", { handled = false, byEvents = true }, { who = lost and { lost.id } or {}, hh = hh.id,
                family = "death", budget = false, lane = "ordinary" })
        end
        return "guardian"
    end
    D.EndHousehold(world, hh, "all_gone")
    return "ended"
end

-- events' own open guardian_lost record for a household (nil when there is none).
function D.GuardianRecord(world, hh)
    for _, e in ipairs(Ev.State(world).list) do
        if e.kind == "guardian_lost" and e.state ~= "resolved" and e.hh == hh.id and e.data.byEvents then return e end
    end
end

-- Everyone is gone: the household ends cleanly and the player gets a continuation choice.
-- The lot stays attached (root.active stays valid) until the player chooses. The record is an
-- ordinary one (it waits for the player, so it must not hold the director or other records back).
-- A household that is not the one being played (a visitor's household lost its last member here)
-- ends at once with its house kept; nobody is asked.
function D.EndHousehold(world, hh, reason)
    hh.flags = hh.flags or {}
    if hh.flags.ended then return false end
    reason = reason or "all_gone"
    hh.flags.ended = { t = world.time, reason = reason, lotId = hh.lotId }
    local played = world.household == hh
    local e = Ev.Record(world, "household_end", { reason = reason }, { hh = hh.id, family = "death", budget = false, lane = "ordinary",
        text = "The story of the " .. (hh.name or "") .. " household has come to an end." })
    if played then
        world.root.pendingEnd = { hh = hh.id, t = world.time, ev = e.id }
        if SS.Sim.world == world and world.speed and world.speed > 0 then SS.Sim.SetSpeed(0) end
    else
        local handled
        if SS.Hood and SS.Hood.OnHouseholdEnded then handled = Ev.Call(SS.Hood.OnHouseholdEnded, world, hh, "keep") end
        if not handled then hh.flags.ended.choice = "keep" end
        Ev.Resolve(world, e, "keep")
    end
    SS.Emit("householdEnded", world, hh, reason)
    return true
end

-- Another module ended the played household (family: the pets or children went into care).
-- The player still gets events' continuation (hood refuses to switch households until the
-- choice is made): a pendingEnd and an open household_end record, once. Returns the record.
function D.AdoptEnd(world, hh, reason)
    if type(hh) ~= "table" then hh = hh and world.root.households[hh] end
    if not hh or world.household ~= hh or not (hh.flags and hh.flags.ended) then return nil end
    local pe = world.root.pendingEnd
    if pe and pe.hh == hh.id then return Ev.Find(world, pe.ev) end
    local e = Ev.Record(world, "household_end", { reason = reason, by = "family", lotReleased = hh.lotId == nil or nil },
        { hh = hh.id, family = "death", budget = false, lane = "ordinary",
        text = "The story of the " .. (hh.name or "") .. " household has come to an end." })
    world.root.pendingEnd = { hh = hh.id, t = world.time, ev = e.id }
    if SS.Sim.world == world and world.speed and world.speed > 0 then SS.Sim.SetSpeed(0) end
    return e
end
SS.On("householdEnded", function(world, hh, reason)
    if type(world) == "table" and world.root and world.lot then D.AdoptEnd(world, hh, reason) end
end)

-- Hourly and on attach: settle household records whose situation has passed.
function D.SettleHouseholdRecords(world)
    local root = world.root
    for _, e in ipairs(Ev.State(world).list) do
        if e.state ~= "resolved" and e.kind == "guardian_lost" and e.data.byEvents then
            local hh = e.hh and root.households[e.hh]
            if not hh then Ev.Resolve(world, e, "gone")
            elseif hh.flags and hh.flags.ended then Ev.Resolve(world, e, "ended")
            elseif #living(world, hh, function(r) return Ev.IsAdult(r) end) > 0 then
                hh.flags.guardianLost = nil
                Ev.Resolve(world, e, "guardian", "A grown-up is looking after the household again.")
            elseif #living(world, hh, isDependent) == 0 then Ev.Resolve(world, e, "gone") end
        elseif e.state ~= "resolved" and e.kind == "household_end" then
            local pe = root.pendingEnd
            local hh = e.hh and root.households[e.hh]
            if not (pe and pe.ev == e.id) then
                Ev.Resolve(world, e, (hh and hh.flags and hh.flags.ended) and ((type(hh.flags.ended) == "table" and hh.flags.ended.choice) or "continued") or "returned")
            end
        end
    end
end
Ev.OnHour("household_records", function(world) D.SettleHouseholdRecords(world) end, 17)
Ev.OnAttach("household_records", function(world) D.SettleHouseholdRecords(world) end)

-- The continuation path. choice: "keep" (the house stays as it is, empty and unowned by a
-- living household) or "sell" (the lot goes back on the market through the neighbourhood).
-- Always returns to the neighbourhood when that mode exists; never leaves the player stuck.
D.CHOICES = {
    { id = "keep", label = "Return to the neighbourhood", desc = "Keep the house exactly as it is. The memorials stay." },
    { id = "sell", label = "Sell the house and return", desc = "The lot goes back on the market; the memorials move with the family records." },
}

function D.Continue(world, choice)
    local root = world.root
    local pe = root.pendingEnd
    if not pe then return false, "Nothing to continue from." end
    local hh = root.households[pe.hh]
    choice = choice == "sell" and "sell" or "keep"
    -- a household another module ended may have released its lot already (family's end hands the
    -- house back): there is nothing left to sell, with or without hood, and the dialog does not
    -- offer it
    if choice == "sell" and hh and not hh.lotId then choice = "keep" end
    local handled
    if SS.Hood and SS.Hood.OnHouseholdEnded then handled = Ev.Call(SS.Hood.OnHouseholdEnded, world, hh, choice) end
    if not handled and hh then
        hh.flags = hh.flags or {}
        if choice == "sell" then
            local lot = hh.lotId and root.hood.lots[hh.lotId]
            if lot then lot.forSale = true end
        end
    end
    if not handled and hh and type(hh.flags.ended) ~= "table" then hh.flags.ended = { t = world.time, reason = "ended" } end
    if not handled and hh then hh.flags.ended.choice = choice end
    local e = Ev.Find(world, pe.ev)
    if e then Ev.Resolve(world, e, choice) end
    root.pendingEnd = nil
    SS.Emit("householdContinue", world, hh, choice)
    -- the neighbourhood view is another module's screen: if it fails to open, the choice still
    -- stands and the dialog still closes (never a stuck end screen)
    local UI = SS.UI
    if UI and UI.SetMode and UI.modes and UI.modes.hood then Ev.Call(UI.SetMode, "hood") end
    return true, choice == "sell" and "The house is on the market. Pick another household in the neighbourhood."
        or "Back to the neighbourhood. The house stays as it was."
end

---------------------------------------------------------------------------------------------------
-- Collapse, then death (starvation and shocks go through here, with warnings before).
function D.Collapse(world, a, cause, text)
    if a.dead then return false end
    local p = Ev.Person(world, a.id)
    if p.dying then return false end
    p.dying = { cause = cause, at = world.time + DD.collapseMinutes }
    Ev.Pseudo(world, a, "ev_collapse", {})
    Ev.Emergency(world, text or (a.name .. " has collapsed."), "emergency")
    return true
end

Ev.OnMinute("dying", function(world)
    local people = Ev.State(world).people
    local any = false
    for _, p in pairs(people) do if p.dying then any = true; break end end
    if not any then return end
    for _, rid in ipairs(Ev.SortedKeys(people)) do
        local p = people[rid]
        if p.dying then
            local a = world.actors[rid]
            if not a or a.dead then p.dying = nil
            elseif world.time >= p.dying.at then
                local cause = p.dying.cause
                p.dying = nil
                D.Kill(world, a, cause)
            elseif not (a.act and a.act.iid == "ev_collapse") then
                Ev.Pseudo(world, a, "ev_collapse", {})
            end
        end
    end
end, 60)

---------------------------------------------------------------------------------------------------
-- The Registrar of Departures (visitors-framework role): arrives, files the paperwork at the
-- memorial, hears one plea, leaves.

local function registrarEvent(world, a) return a.roleData and Ev.Find(world, a.roleData.eventId) end

SS.Interactions.ev_registrar_file = {
    label = "File the Paperwork", category = "Other", slot = "front", pose = "use", dur = DD.registrarWork, advert = {}, manualOnly = true,
    test = function(world, actor) if actor.role ~= "registrar" then return false, "Only the Registrar files these." end return true end,
    onEnd = function(world, actor, act, o, status)
        if status == "done" and actor.roleData then actor.roleData.filed = world.time end
    end,
}

-- The plea. The chance is fixed when the person dies (saved), and each death hears one plea:
-- the attempt is recorded on the death record before the outcome, so a reload cannot farm it.
function D.PleaChance(world, pleader)
    local ch = (SS.Skills and SS.Skills.Level and SS.Skills.Level(pleader, "charisma")) or 0
    return min(0.9, DD.pleaChance + DD.pleaCharisma * ch)
end

SS.Interactions.ev_plea = {
    label = "Plead for Their Return", category = "Family", targetActor = true, pose = "talk", dur = DD.pleaMinutes, advert = {}, manualOnly = true,
    test = function(world, actor, target)
        if not target or target.role ~= "registrar" then return false, "Only the Registrar can hear this." end
        if not Ev.IsAdult(actor) or actor.role then return false, "A grown-up of the household has to ask." end
        local e = registrarEvent(world, target)
        if not e or e.kind ~= "death" then return false, "He is not here about anyone." end
        if e.fx.plea then return false, "He has already heard a plea for " .. (e.data.name or "them") .. "." end
        if target.roleData and target.roleData.filed then return false, "The paperwork is already filed." end
        return true
    end,
    onStart = function(world, actor, act)
        local target = world.actors[act.tid]
        local e = target and registrarEvent(world, target)
        if not e or not Ev.Once(e, "plea", world) then return false, "He has already heard a plea." end
        e.data.pleaBy = actor.id
        e.data.pleaChance = D.PleaChance(world, actor)
        if target.act then SS.Actions.Finish(world, target, "cancelled") end
        target.roleData.hearing = actor.id
        target.pose = "talk"
    end,
    onEnd = function(world, actor, act, o, status)
        local target = world.actors[act.tid]
        local e = target and registrarEvent(world, target)
        if target and target.roleData then target.roleData.hearing = nil end
        if not e or not e.fx.plea or e.data.pleaOutcome then return end
        -- an interrupted plea still counts as the one plea (it was recorded at the start)
        if status ~= "done" then
            e.data.pleaOutcome = "interrupted"
            Ev.Journal(world, actor.name .. " began to plead with the Registrar but was interrupted.", e)
            return
        end
        if e.data.pleaRoll < e.data.pleaChance then
            e.data.pleaOutcome = "granted"
            D.Revive(world, e, actor, target)
        else
            e.data.pleaOutcome = "refused"
            SS.Needs.Add(actor, "fun", -10)
            Ev.Tell(world, target, "\"I'm terribly sorry. The forms are final.\"", "social")
            Ev.Journal(world, actor.name .. " pleaded with the Registrar for " .. (e.data.name or "them") .. ". He was kind, but the forms are final.", e)
        end
    end,
}

-- A granted plea: the paperwork is torn up and the person walks back in. The memorial and
-- the death flags go; the death record stays in the history as "returned".
function D.Revive(world, e, pleader, registrar)
    local root = world.root
    local rid = e.who[1]
    local r = rid and root.residents[rid]
    if not r or not r.dead then return false end
    r.dead, r.deathCause, r.diedAt, r.ghost = nil, nil, nil, nil
    r.revivedAt = world.time
    local hh = r.householdId and root.households[r.householdId]
    if hh then
        local have = false
        for _, m in ipairs(hh.members) do if m == rid then have = true end end
        if not have then hh.members[#hh.members + 1] = rid end
        for n = #(hh.deceased or {}), 1, -1 do if hh.deceased[n].id == rid then table.remove(hh.deceased, n) end end
        if hh.flags and hh.flags.ended then
            hh.flags.ended = nil
            local pe = root.pendingEnd
            if pe and pe.hh == hh.id then
                root.pendingEnd = nil
                local he = Ev.Find(world, pe.ev)
                if he then Ev.Resolve(world, he, "returned") end
            end
        end
        if hh.flags then hh.flags.guardianLost = nil end
        local ge = D.GuardianRecord(world, hh)
        if ge and Ev.IsAdult(r) then Ev.Resolve(world, ge, "guardian") end
    end
    markRelations(world, rid, false)
    local mem = e.data.memorial
    if mem then
        local lot = root.hood.lots[mem.lotId]
        if lot and lot.objects[mem.oid] then
            if lot == world.lot then Ev.RemoveObject(world, lot, mem.oid) else lot.objects[mem.oid] = nil; lot.version = (lot.version or 1) + 1 end
        end
    end
    for _, p in pairs(Ev.State(world).people) do if p.grief then p.grief[rid] = nil end end
    for _, m in ipairs(Ev.Open(world, "mourning")) do if m.data.dead == rid then Ev.Resolve(world, m, "returned") end end
    deaths(world)[rid] = nil
    for need, v in pairs({ hunger = 10, energy = 10, bladder = 20, hygiene = 0, fun = -20, social = 0, comfort = -10 }) do r.needs[need] = v end
    local i, j = Ev.FreeCell(world, registrar.level or 0, floor(registrar.x), floor(registrar.y))
    if i then SS.Sim.AddActor(world, rid, i, j, registrar.level or 0) end
    Ev.Resolve(world, e, "returned", pleader.name .. " pleaded with the Registrar, and he tore up the paperwork. " .. r.name .. " is back!")
    Ev.Tell(world, registrar, "\"Just this once. Don't make me regret it.\"", "social")
    SS.Emit("revived", world, r)
    return true
end

-- Is the Registrar really hearing a plea right now? The pleader must still be performing
-- ev_plea toward him. Actions do not survive a reload, and an interrupted plea may never reach
-- its onEnd: then the hearing is over, and a plea that was started (recorded on the death
-- record) but never decided counts as interrupted. That was the one plea.
function D.CheckHearing(world, a)
    local rd = a.roleData
    if not (rd and rd.hearing) then return false end
    local p = world.actors[rd.hearing]
    local act = p and p.act
    if act and act.iid == "ev_plea" and act.tid == a.id then return true end
    rd.hearing = nil
    local e = registrarEvent(world, a)
    if e and e.fx.plea and not e.data.pleaOutcome then
        e.data.pleaOutcome = "interrupted"
        local r = e.data.pleaBy and world.root.residents[e.data.pleaBy]
        Ev.Journal(world, (r and r.name or "Someone") .. " began to plead with the Registrar but was interrupted.", e)
    end
    return false
end

local function registrarTick(world, a, dt)
    local rd = a.roleData
    if rd.phase == "leaving" then return end
    rd.phase = rd.phase or "arrive"
    rd.arrivedAt = rd.arrivedAt or world.time
    local e = registrarEvent(world, a)
    local stayed = world.time - rd.arrivedAt
    -- a plea in progress may run past the usual visit, but never past the hard limit
    if D.CheckHearing(world, a) and stayed < DD.registrarStay + DD.pleaMinutes + 5 then return end
    local over = stayed >= DD.registrarStay
    if not e or e.state == "resolved" or over or rd.filed then
        if e and Ev.Once(e, "registrarLeft", world) then
            if e.data.pleaOutcome == "granted" then
                Ev.Journal(world, (a.name or "The Registrar") .. " left in a hurry, muttering about paperwork.", e)
            else
                Ev.Journal(world, (a.name or "The Registrar") .. " filed the paperwork, tipped his hat to the household, and left.", e)
                if e.state ~= "resolved" then Ev.Resolve(world, e, "filed") end
            end
        end
        return Ev.SendAway(world, a, "done")
    end
    if a.act or (a.queue and #a.queue > 0) then return end
    if world.time < (rd.nextOrder or -1e9) then return end
    rd.nextOrder = world.time + 2
    local mem = e.data.memorial and world.lot.objects[e.data.memorial.oid]
    if not mem then rd.filed = world.time; return end
    rd.tries = (rd.tries or 0) + 1
    if rd.tries > 6 then rd.filed = world.time; return end
    SS.Actions.Order(world, a, mem.id, "ev_registrar_file", nil, nil, { manual = true, data = { source = "events" } })
end

-- After a load: whatever he was doing was dropped, so a hearing cannot still be going on.
Ev.OnAttach("registrar", function(world)
    for _, id in ipairs(Ev.ActorIds(world)) do
        local a = world.actors[id]
        if a and a.role == "registrar" and a.roleData then D.CheckHearing(world, a) end
    end
end)

-- He passes household locks like the other responders (access "emergency": a memorial behind a
-- household-only door still gets its paperwork), but he is not an emergency crew, so his visit
-- keeps the service class (the visitors framework's caps and timeouts for workers).
if SS.Visitors and SS.Visitors.RegisterRole then
    SS.Visitors.RegisterRole("registrar", {
        label = "Registrar of Departures", noNeeds = true, access = "emergency", class = "service", useAutonomy = false, uniform = "registrar",
        outfit = "registrar", arrive = "direct",
        reconcile = function(world, a) D.CheckHearing(world, a); return "resume" end,
        onArrive = function(world, a)
            a.outfit = "registrar"
            a.carry = "ledger"
            local e = registrarEvent(world, a)
            if e and Ev.Once(e, "registrarCame", world) then
                Ev.Journal(world, (a.name or "The Registrar") .. ", the Registrar of Departures, arrived about " .. (e.data.name or "the departed") .. "'s paperwork.", e)
                Ev.Tell(world, a, "\"Good day. I'm here about " .. (e.data.name or "the departed") .. ". I won't be long.\"", "social")
            end
        end,
        onLeave = function(world, a) a.carry = nil end,
        tick = registrarTick,
    })
end

-- He only comes while the death is still open (not after a return) and the memorial exists.
Ev.arrivals.registrar = function(world, e)
    if e.state == "resolved" then return false end
    local mem = e.data.memorial
    return mem ~= nil and mem.lotId == world.lot.id and world.lot.objects[mem.oid] ~= nil
end

-- Death records settle once the Registrar has been and gone, or when no visit is coming.
Ev.OnHour("death_records", function(world)
    for _, e in ipairs(Ev.Open(world, "death")) do
        local rec = e.data.responders and e.data.responders.npc_registrar
        if rec then Ev.Pending(world, e, "npc_registrar") end   -- marks a long-overdue visit as skipped
        if not rec then Ev.Resolve(world, e, "recorded")
        elseif rec.skipped and not world.actors.npc_registrar then Ev.Resolve(world, e, "recorded") end
    end
end, 16)

---------------------------------------------------------------------------------------------------
-- Ghosts: occasionally, at night, on lots with memorials. The ghost is the dead resident's own
-- id in the "ghost" role; they drift near their memorial, startle people, and fade before dawn.
local GH = DD.ghost

local function isNight(world)
    local h = floor(world.time / 60) % 24
    if GH.from <= GH.to then return h >= GH.from and h < GH.to end
    return h >= GH.from or h < GH.to
end

function D.SpawnGhost(world, mem)
    local r = world.root.residents[mem.state.rid]
    if not r or not r.dead or world.actors[r.id] then return nil, "not available" end
    r.ghost = true
    local stay = SS.RandomInt(world, "death", GH.stay[1], GH.stay[2])
    local i, j = Ev.FreeCell(world, mem.level or 0, mem.x, mem.y + 1)
    -- appears by the memorial (visitors' arrive mode "none"); `ghost` lets the framework spawn
    -- the dead resident's own id, and nothing else ever does
    local a = SS.Visitors and SS.Visitors.Spawn and SS.Visitors.Spawn(world, r.id, "ghost", { memorial = mem.id, untilT = world.time + stay,
        ghost = true, arrive = "none", i = i, j = j, level = mem.level or 0, force = true })
    if not a then r.ghost = nil; return nil, "could not appear" end
    if i then a.x, a.y, a.level = i + 0.5, j + 0.5, mem.level or 0 end
    a.noNeeds = true
    Ev.Cool(world, "ghost:" .. r.id, GH.cooldown)
    local e = Ev.Record(world, "ghost", { rid = r.id }, { who = { r.id }, targets = { mem.id }, family = "ghost", budget = false })
    a.roleData.eventId = e.id
    SS.Emit("ghost", world, a)
    return a
end

local function fade(world, a, why)
    local e = a.roleData and Ev.Find(world, a.roleData.eventId)
    local rid = a.id
    -- a ghost fades where it stands (never a walk out to the street): `immediate` removes it now
    if SS.Visitors and SS.Visitors.Leave then SS.Visitors.Leave(world, a, "faded", { immediate = true }) end
    if world.actors[rid] then SS.Sim.RemoveActor(world, rid, { reason = "faded" }) end
    local r = world.root.residents[rid]
    if r then r.ghost, r.lotId, r.away, r.role, r.roleData = nil, nil, nil, nil, nil end
    if e then Ev.Resolve(world, e, why or "faded") end
end
D.FadeGhost = fade

local function ghostTick(world, a, dt)
    local rd = a.roleData
    if not a.dead then return fade(world, a, "revived") end
    if world.time >= (rd.untilT or 0) or not isNight(world) then return fade(world, a, "faded") end
    a.pose = "idle"
    if world.time < (rd.next or -1e9) then return end
    rd.next = world.time + 1
    -- startle the living nearby (awake, same level)
    local gi, gj, gl = Ev.CellOf(a)
    for _, p in ipairs(Ev.People(world)) do
        if not p.sleeping and Ev.IsHuman(p) then
            local pi, pj, pl = Ev.CellOf(p)
            if pl == gl and Ev.Dist(pi, pj, gi, gj) <= GH.scareRange and not Ev.Cooled(world, "scare:" .. p.id) then
                Ev.Cool(world, "scare:" .. p.id, GH.scareCooldown)
                Ev.Pseudo(world, p, "ev_scared", { len = 2 })
                SS.Needs.Add(p, "comfort", -15)
                SS.Needs.Add(p, "fun", -5)
                SS.Needs.Add(p, "energy", 5)
                Ev.Say(world, p, "ghost_seen", { ghost = a.id }, "Is that... " .. a.name .. "?!", "alert")
                local e = Ev.Find(world, rd.eventId)
                if e and Ev.Once(e, "seen:" .. p.id, world) then
                    Ev.Journal(world, p.name .. " saw the ghost of " .. a.name .. ".", e, { p.id, a.id })
                end
            end
        end
    end
    -- drift near the memorial
    if not a.act and (rd.nextMove or -1e9) <= world.time then
        rd.nextMove = world.time + 6
        local mem = world.lot.objects[rd.memorial]
        local ci, cj = mem and mem.x or gi, mem and mem.y or gj
        local ti, tj = Ev.RandomCell(world, gl, function(i, j) return Ev.Dist(i, j, ci, cj) <= 4 end, "death")
        if ti then SS.Actions.Order(world, a, nil, "goto", ti, tj, { level = gl, manual = true, data = { source = "events" } }) end
    end
end

SS.Interactions.ev_scared = {
    label = "Spooked", category = "Other", pose = "panic", advert = {}, manualOnly = true, maxDur = 5,
    onTick = function(world, actor, act, o, dt) if act.t + dt >= (act.data.len or 2) then act.complete = true end end,
}

if SS.Visitors and SS.Visitors.RegisterRole then
    SS.Visitors.RegisterRole("ghost", {
        label = "Ghost", noNeeds = true, access = "intruder", class = "other", useAutonomy = false, translucent = true,
        ghost = true, arrive = "none", timeout = 120,
        tick = ghostTick,
        onLeave = function(world, a) a.ghost = nil end,
        -- a reload ends a haunting (the validator has already cleared the dead's location)
        reconcile = function(world, a) return "remove" end,
    })
end

-- Ghost records settle once the ghost is no longer on the lot (it faded, or the game was
-- reloaded mid-haunt: a reload never brings a ghost back).
function D.SettleGhosts(world)
    for _, e in ipairs(Ev.State(world).list) do
        if e.kind == "ghost" and e.state ~= "resolved" and e.lotId == world.lot.id then
            local g = world.actors[e.data.rid]
            if not (g and g.role == "ghost") then
                local r = world.root.residents[e.data.rid]
                if r and r.dead then r.ghost = nil end
                Ev.Resolve(world, e, "faded")
            end
        end
    end
end
Ev.OnAttach("ghosts", function(world) D.SettleGhosts(world) end)

Ev.OnHour("ghosts", function(world)
    D.SettleGhosts(world)
    if not isNight(world) or Ev.EmergencyActive(world) then return end
    for _, mem in ipairs(D.Memorials(world)) do
        local rid = mem.state.rid
        local r = world.root.residents[rid]
        if r and r.dead and not world.actors[rid] and not Ev.Cooled(world, "ghost:" .. rid)
            and world.time - (r.diedAt or 0) >= 1440 then
            if SS.Random(world, "death") < GH.chance then D.SpawnGhost(world, mem) end
        end
    end
end, 50)

---------------------------------------------------------------------------------------------------
-- Effects: a soft glow on ghosts.
Ev.OnEffects(function(world, add)
    for _, a in pairs(world.actors) do
        if a.role == "ghost" then add(a.level or 0, a.x, a.y, 0.8, "ghost_glow", 1) end
    end
end)

---------------------------------------------------------------------------------------------------
-- Validator: the dead are never alive anywhere. Repairs stale lotId / away / ghost on the dead
-- (and the "ghost" role, which is events' own; a role another module owns, such as family's
-- "pet", is that module's data and stays: with no lotId the dead are on no lot anyway),
-- household membership, outing participants, and death bookkeeping.
SS.Save.RegisterValidator(function(root, p)
    local st = root.events and root.events.deaths
    for _, rid in ipairs(Ev.SortedKeys(root.residents)) do
        local r = root.residents[rid]
        if r.dead then
            if r.lotId or r.away or r.ghost or r.role == "ghost" then
                r.lotId, r.away, r.ghost = nil, nil, nil
                if r.role == "ghost" then r.role, r.roleData = nil, nil end
                p[#p + 1] = "cleared a stale location for " .. tostring(r.name or rid) .. " (deceased)"
            end
            r.act, r.queue = nil, nil
            local hh = r.householdId and root.households[r.householdId]
            if hh then
                for n = #hh.members, 1, -1 do
                    if hh.members[n] == rid then table.remove(hh.members, n); p[#p + 1] = "removed a deceased member from " .. tostring(hh.id) end
                end
            end
            if root.outing and type(root.outing.participants) == "table" then
                for n = #root.outing.participants, 1, -1 do
                    if root.outing.participants[n] == rid then table.remove(root.outing.participants, n) end
                end
            end
            if st and not st[rid] then st[rid] = { t = r.diedAt or root.time, cause = r.deathCause or "unknown" } end
        elseif st and st[rid] then
            st[rid] = nil   -- alive again (a granted plea) or a damaged entry
        end
        if not r.dead and r.ghost then r.ghost = nil end
    end
    if root.pendingEnd and not (root.households[root.pendingEnd.hh]) then root.pendingEnd = nil end
    return true
end)
