-- SideStreet hazards: burglary and the police, breakdowns, leaks and puddles, pests from
-- sustained mess, the starvation pathway, and electrocution risk. Owner: events module.
--
-- Saved state
--   root.events.mess["lotId|level:room"] = hours the room has been messy
--   root.events.people[rid].starve = { level, since, stage, ev }  /  .lastShock, .shockObj
--   event records: burglary (stolen item, alarm, police), leak (puddles), pests (colonies),
--   breakdown, starvation
--   system objects: puddle (fallback def), ev_pests
local _, SS = ...
local H = SS.Hazards or {}
SS.Hazards = H
local Ev = SS.Events
local ED = SS.EventsData
local BD, PD, LD, SD, XD = ED.burglary, ED.pests, ED.leak, ED.starvation, ED.electric
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

---------------------------------------------------------------------------------------------------
-- Breakdowns (director family; household-core owns breaking and repairing).

local PLUMBING_TAGS = { "toilet", "shower", "bath", "sink", "basin", "dishwasher" }
function H.IsPlumbing(def)
    if not def or def.system then return false end
    if def.cat == "plumbing" then return true end
    for _, t in ipairs(PLUMBING_TAGS) do if Ev.HasTag(def, t) then return true end end
    return false
end

local function breakable(world, pred)
    local out = {}
    for _, oid in ipairs(Ev.SortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and not def.system and not (o.state and (o.state.broken or o.state.burnt or o.state.burning)) and pred(def, o) then
            out[#out + 1] = o
        end
    end
    return out
end

local function homeAwake(world)
    return #Ev.Members(world, function(a) return not a.sleeping and Ev.IsHuman(a) end) > 0
end

Ev.families.breakdown = {
    eligible = function(world)
        if not (SS.Maintenance and SS.Maintenance.Break) then return false, "breakdowns not available" end
        if not homeAwake(world) then return false, "nobody around to notice" end
        if #breakable(world, function(def) return ED.breakdown.eligibleCats[def.cat] and not H.IsPlumbing(def) end) == 0 then
            return false, "nothing that can break"
        end
        return true
    end,
    run = function(world)
        local o = SS.Pick(world, "events", breakable(world, function(def) return ED.breakdown.eligibleCats[def.cat] and not H.IsPlumbing(def) end))
        if not o then return nil, "nothing to break" end
        if not SS.Maintenance.Break(world, o, "event") then return nil, "it held together" end
        local e = Ev.ForTarget(world, "breakdown", o.id)
        if not e then   -- the maintenance module did not announce it: record it ourselves
            local def = SS.Objects[o.def]
            e = Ev.Record(world, "breakdown", { why = "event" }, { targets = { o.id }, cause = "event", family = "breakdown",
                text = (def and def.name or "Something") .. " broke down." })
        end
        local def = SS.Objects[o.def]
        Ev.Emergency(world, (def and def.name or "Something") .. " broke down. Repair it or call a repair service.", "info")
        return e
    end,
}

---------------------------------------------------------------------------------------------------
-- Leaks and puddles: any broken plumbing fixture leaks, adding a puddle beside it every
-- LD.every minutes (up to LD.cap) until it is repaired; the record resolves once it is
-- repaired and the puddles are mopped.
-- With household-core loaded (SS.Maintenance.SpawnPuddle), its own hourly leak model makes the
-- puddles of broken plumbing (cause "leak"): events then only places the first puddle through
-- that API when the leak starts, adds none of its own, and counts household-core's leak puddles
-- around the fixture (within LD.near cells) for the record's resolution. No doubled puddles.
local function corePuddles() return SS.Maintenance ~= nil and type(SS.Maintenance.SpawnPuddle) == "function" end
H.CorePuddles = corePuddles

local function isLeakPuddle(world, e, o, fixture)
    if o.def ~= "puddle" then return false end
    if o.state and o.state.ev == e.id then return true end
    if not e.data.core or not fixture then return false end
    local cause = o.cause or (o.state and o.state.cause)
    return cause == "leak" and (o.level or 0) == (fixture.level or 0) and Ev.Dist(o.x, o.y, fixture.x, fixture.y) <= LD.near
end

local function puddlesOf(world, e)
    local n = 0
    local fixture = e.targets and world.lot.objects[e.targets[1]]
    if e.data.core and not fixture then fixture = e.data.at and { x = e.data.at[2], y = e.data.at[3], level = e.data.at[1] } end
    for _, o in pairs(world.lot.objects) do if isLeakPuddle(world, e, o, fixture) then n = n + 1 end end
    return n
end
H.PuddlesOf = puddlesOf

local function addPuddle(world, e, fixture)
    local lot = world.lot
    local level = fixture.level or 0
    local have = {}
    for _, o in pairs(lot.objects) do
        if o.def == "puddle" and (o.level or 0) == level then have[o.y * 1000 + o.x] = true end
    end
    local room = SS.World.RoomAt(world, level, fixture.x, fixture.y)
    local i, j = Ev.FreeCell(world, level, fixture.x, fixture.y, function(ci, cj)
        return not have[cj * 1000 + ci] and SS.World.RoomAt(world, level, ci, cj) == room and not Ev.NearOpening(world, level, ci, cj)
    end, 3)
    if not i then return nil end
    local o
    if e.data.core then
        o = Ev.Call(SS.Maintenance.SpawnPuddle, world, level, i, j, "leak")
        if type(o) ~= "table" then return nil end
    else
        o = Ev.AddObject(world, lot, "puddle", i, j, 0, level, { ev = e.id, wet = true }, true)
    end
    e.data.puddles = (e.data.puddles or 0) + 1
    return o
end
H.AddPuddle = addPuddle

local function startLeak(world, o, why)
    if Ev.ForTarget(world, "leak", o.id) then return nil end
    local def = SS.Objects[o.def]
    local e = Ev.Record(world, "leak", { why = why, next = world.time + LD.every, core = corePuddles() or nil, at = { o.level or 0, o.x, o.y } },
        { targets = { o.id }, cause = why, family = "pipe_leak", budget = why == "leak",
        text = "The " .. (def and def.name or "plumbing") .. " sprang a leak." })
    addPuddle(world, e, o)
    for _, a in ipairs(Ev.Members(world, function(m) return not m.sleeping end)) do
        Ev.Say(world, a, "puddle", { objDef = o.def }, "Is that... water? Where is that coming from?", "hygiene", true)
        break
    end
    return e
end
H.StartLeak = startLeak

SS.On("objectBroken", function(world, o, why)
    if not world or not world.lot or not o or world.lot.objects[o.id] ~= o then return end
    if why == "fire" or why == "burglary" then return end
    if H.IsPlumbing(SS.Objects[o.def]) then startLeak(world, o, why or "wear") end
end)

Ev.families.pipe_leak = {
    eligible = function(world)
        if not (SS.Maintenance and SS.Maintenance.Break) then return false, "breakdowns not available" end
        if not homeAwake(world) then return false, "nobody around" end
        if #breakable(world, function(def) return H.IsPlumbing(def) end) == 0 then return false, "no plumbing" end
        return true
    end,
    run = function(world)
        local o = SS.Pick(world, "events", breakable(world, function(def) return H.IsPlumbing(def) end))
        if not o then return nil, "no plumbing" end
        if not SS.Maintenance.Break(world, o, "leak") then return nil, "the pipes held" end
        return Ev.ForTarget(world, "leak", o.id) or startLeak(world, o, "leak")
    end,
}

Ev.OnMinute("leaks", function(world)
    local list, lotId = Ev.State(world).list, world.lot.id
    for n = 1, #list do
        local e = list[n]
        if e and e.kind == "leak" and e.state ~= "resolved" and e.lotId == lotId then H.LeakMinute(world, e) end
    end
end, 40)

function H.LeakMinute(world, e)
    local o = world.lot.objects[e.targets[1]]
    local leaking = o and o.state and o.state.broken
    if leaking and not e.data.core and world.time >= (e.data.next or 0) then
        e.data.next = world.time + LD.every
        if puddlesOf(world, e) < LD.cap then addPuddle(world, e, o) end
    end
    if not leaking and puddlesOf(world, e) == 0 then
        Ev.Resolve(world, e, o and "fixed" or "removed", "The leak is fixed and the floor is dry again.")
    elseif not leaking and not e.data.fixedAt then
        e.data.fixedAt = world.time
    end
end

-- Mopping (fallback: household-core's own puddle interactions win when it defines puddles).
SS.Interactions.ev_mop = SS.Interactions.ev_mop or {
    label = "Mop Up", category = "Chores", slot = "near", pose = "clean", carry = "mop", dur = 6, advert = { room = 20 },
    onStart = function(world, actor) actor.carry = "mop" end,
    onEnd = function(world, actor, act, o, status)
        actor.carry = nil
        if status == "done" and o then Ev.RemoveObject(world, world.lot, o.id, true); SS.Emit("lotChanged", "object", o.id) end
    end,
}
-- Whoever owns the puddle definition, leak puddles can always be mopped with this.
if SS.Objects.puddle then
    local def = SS.Objects.puddle
    def.actions = def.actions or {}
    local have = false
    for _, a in ipairs(def.actions) do if a == "ev_mop" or a == "mop" then have = true end end
    if not have then def.actions[#def.actions + 1] = "ev_mop" end
end

---------------------------------------------------------------------------------------------------
-- Pests from sustained mess.

-- Pest mess points of one object. `def.mess` is a number (this module's system objects) or a
-- mess kind string (household-core: "plate", "food", "trash", "bag", "puddle", "clutter"...).
-- Every kind, and the object states household-core also scores (spoiled food, dirt, filth, a
-- full bin), is worth household-core's own weight (SS.Tuning.room.mess[kind]) divided by
-- PD.tuningScale when that table exists, else PD.kinds[kind] (1 for an unknown kind). Broken,
-- wilted and unmade things spoil a room but do not feed beetles, so they are not counted here.
local function kindPoints(kind)
    local R = SS.Tuning and SS.Tuning.room
    local w = type(R) == "table" and type(R.mess) == "table" and R.mess[kind]
    if type(w) == "number" then return w / PD.tuningScale end
    local v = PD.kinds[kind]
    if type(v) == "number" then return v end
    return 1
end
H.MessKindPoints = kindPoints

local function tuningAt(name, default)
    local v = SS.Tuning and SS.Tuning[name]
    return type(v) == "number" and v or default
end

local function messOf(o, def)
    if o.def == "ev_pests" then return 0 end
    local st = type(o.state) == "table" and o.state or nil
    local dm, m = def.mess, 0
    local spoiledKind = false
    if type(dm) == "number" then m = dm
    elseif type(dm) == "string" then
        local kind = dm
        if kind == "food" and st and st.spoiled then kind, spoiledKind = "spoiled", true end
        m = kindPoints(kind)
    end
    local dirt = tonumber(o.dirt) or (st and tonumber(st.dirt)) or 0
    if dirt >= tuningAt("filthyAt", 85) then m = m + kindPoints("filthy")
    elseif dirt >= tuningAt("dirtyAt", 50) or (st and st.dirty) then m = m + kindPoints("dirty") end
    if st then
        if st.spoiled and not spoiledKind then m = m + kindPoints("spoiled") end
        if st.full then m = m + kindPoints("binFull") end
    end
    return m
end
H.MessOf = messOf

-- Mess per indoor room on the running lot: key "level:room" -> { mess, cells = {{i,j}...} }.
function H.RoomMess(world)
    local lot = world.lot
    local out = {}
    for _, oid in ipairs(Ev.SortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if type(def) == "table" then
            local m = messOf(o, def)
            if m > 0 then
                local lv = o.level or 0
                local room = SS.World.RoomAt(world, lv, o.x, o.y)
                if room > 0 then
                    local k = lv .. ":" .. room
                    local r = out[k]
                    if not r then r = { mess = 0, level = lv, room = room, cells = {} }; out[k] = r end
                    r.mess = r.mess + m
                    r.cells[#r.cells + 1] = { o.x, o.y }
                end
            end
        end
    end
    return out
end

local function colonies(world)
    local out = {}
    for _, oid in ipairs(Ev.SortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        if o.def == "ev_pests" then out[#out + 1] = o end
    end
    return out
end
H.Colonies = colonies

local function spawnPests(world, r)
    local lot = world.lot
    local c = r.cells[1]
    local i, j = Ev.FreeCell(world, r.level, c[1], c[2], function(ci, cj)
        if SS.World.RoomAt(world, r.level, ci, cj) ~= r.room then return false end
        for _, o in ipairs(colonies(world)) do if o.x == ci and o.y == cj then return false end end
        return true
    end, 4)
    if not i then return nil end
    local e = Ev.Open(world, "pests", lot.id)[1]
    if not e then
        e = Ev.Record(world, "pests", {}, { family = "pests", budget = false,
            text = "Crumb beetles have moved in. The mess invited them; cleaning up and spraying will see them off." })
        for _, a in ipairs(Ev.Members(world, function(m) return not m.sleeping end)) do
            Ev.Tell(world, a, "Ugh! Beetles! Something needs cleaning around here.", "hygiene")
            break
        end
    end
    local o = Ev.AddObject(world, lot, "ev_pests", i, j, 0, r.level, { ev = e.id, since = world.time, room = r.room, clean = 0 }, true)
    e.targets[#e.targets + 1] = o.id
    e.data.colonies = (e.data.colonies or 0) + 1
    return o
end
H.SpawnPests = spawnPests

Ev.OnHour("pests", function(world)
    local lot = world.lot
    local s = Ev.State(world)
    local rooms = H.RoomMess(world)
    local list = colonies(world)
    -- sustained mess counters (only rooms above the threshold count)
    local seen = {}
    for _, k in ipairs(Ev.SortedKeys(rooms)) do
        local r = rooms[k]
        local key = lot.id .. "|" .. k
        seen[key] = true
        if r.mess >= PD.threshold then
            s.mess[key] = (s.mess[key] or 0) + 1
            local hours = s.mess[key]
            -- the first colony after PD.hours of mess; another every PD.spreadHours after the newest
            -- one in the room (never several at once when the mess outlasted a cooldown)
            local inRoom, newest = 0, nil
            for _, o in ipairs(list) do
                if (o.level or 0) == r.level and o.state.room == r.room then
                    inRoom = inRoom + 1
                    local since = o.state.since or world.time
                    if not newest or since > newest then newest = since end
                end
            end
            local due = (inRoom == 0 and hours >= PD.hours) or (inRoom > 0 and world.time - newest >= PD.spreadHours * 60)
            if due and #list < PD.cap and not Ev.Cooled(world, "pests:" .. lot.id) then
                if spawnPests(world, r) then list = colonies(world) end
            end
        else
            s.mess[key] = nil
        end
    end
    for key in pairs(s.mess) do
        if key:sub(1, #lot.id + 1) == lot.id .. "|" and not seen[key] then s.mess[key] = nil end
    end
    -- colonies leave after a day without mess in their room
    for _, o in ipairs(list) do
        local r = rooms[(o.level or 0) .. ":" .. (o.state.room or -1)]
        if r and r.mess >= PD.threshold then o.state.clean = 0
        else
            o.state.clean = (o.state.clean or 0) + 1
            if o.state.clean >= PD.leaveHours then
                local e = o.state.ev and Ev.Find(world, o.state.ev)
                Ev.RemoveObject(world, lot, o.id, true)
                if e then Ev.Journal(world, "With the mess gone, the crumb beetles moved on.", e) end
            end
        end
    end
    -- the record resolves when no colony is left
    for _, e in ipairs(Ev.Open(world, "pests", lot.id)) do
        if #colonies(world) == 0 then Ev.Resolve(world, e, "gone") end
    end
end, 30)

SS.Interactions.ev_spray_pests = {
    label = "Spray for Beetles", category = "Chores", slot = "near", pose = "clean", dur = 10, cost = PD.sprayCost, ledger = "Pest spray",
    advert = { room = 25, hygiene = 5 },
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        local e = o.state and o.state.ev and Ev.Find(world, o.state.ev)
        Ev.RemoveObject(world, world.lot, o.id, true)
        SS.Emit("lotChanged", "object", o.id)
        Ev.Cool(world, "pests:" .. world.lot.id, PD.cooldown)
        if e then Ev.Journal(world, actor.name .. " sprayed out a crumb beetle colony.", e, { actor.id }) end
        if #colonies(world) == 0 and e then
            Ev.Resolve(world, e, "exterminated", "The beetles are gone. Keep the place tidy or they will be back.")
        end
    end,
}

-- Hygiene suffers faster in a room with pests.
local pestRooms = { t = -1, set = {} }
Ev.OnModifiers(function(world, a, add)
    if pestRooms.t ~= world.time then
        pestRooms.t = world.time
        local set = pestRooms.set
        for k in pairs(set) do set[k] = nil end
        local any, list, lotId = false, Ev.State(world).list, world.lot.id
        for n = 1, #list do
            local e = list[n]
            if e.kind == "pests" and e.state ~= "resolved" and e.lotId == lotId then any = true; break end
        end
        if any then
            for _, o in pairs(world.lot.objects) do
                if o.def == "ev_pests" then set[(o.level or 0) * 10000 + (o.state and o.state.room or -1)] = true end
            end
        end
    end
    if not next(pestRooms.set) then return end
    local lv = a.level or 0
    if pestRooms.set[lv * 10000 + SS.World.RoomAt(world, lv, floor(a.x), floor(a.y))] then add("hygiene", PD.hygieneRate) end
end)

---------------------------------------------------------------------------------------------------
-- Starvation: escalating warnings, then an explicit clock at -100 Hunger (brief section 10).
--   -50: very hungry; -80: starving (warning); -95: about to collapse (warning);
--   at -100: critical now, fading after 8 h, last hours after 16 h, collapse and death at 24 h.
-- Eating anything that lifts Hunger above -100 stops the clock; above -50 clears the warnings.

function H.StarvationStatus(world, a)
    local p = Ev.PersonIf(world, a.id)
    local s = p and p.starve
    if not s then return nil end
    local left = s.since and (SD.fatalAfter - (world.time - s.since)) or nil
    return { level = s.level or 0, since = s.since, minutesLeft = left }
end

local function starveRecord(world, a, p)
    local e = p.starve.ev and Ev.Find(world, p.starve.ev)
    if e and e.state ~= "resolved" then return e end
    e = Ev.Record(world, "starvation", {}, { who = { a.id }, family = "neglect", budget = false, cause = "hunger" })
    p.starve.ev = e.id
    return e
end

-- Only grown-ups can starve to death here. A hungry child or infant is the family module's
-- welfare case (warnings, neglect reports, an inspection, protective removal; brief section 10):
-- this pathway never collapses or kills a dependent. Without the family module, dependents
-- still get the hunger warnings and an open "starvation" record, but no fatal clock.
function H.StarvationHour(world)
    local familyOwns = SS.Family and SS.Family.IsDependent and true or false
    for _, a in ipairs(Ev.Members(world, Ev.IsHuman)) do
        local dependent = Ev.IsDependent(a)
        if dependent and familyOwns then
            local p = Ev.PersonIf(world, a.id)
            if p and p.starve then   -- became a family case (the module loaded after a save): hand over
                local e = p.starve.ev and Ev.Find(world, p.starve.ev)
                p.starve = nil
                if e then Ev.Resolve(world, e, "family_care") end
            end
        else
            H.StarvePerson(world, a, dependent)
        end
    end
end

function H.StarvePerson(world, a, dependent)
    local hunger = a.needs.hunger or 0
    local p = Ev.PersonIf(world, a.id)
    if hunger > -50 then
        if p and p.starve then
            local e = p.starve.ev and Ev.Find(world, p.starve.ev)
            p.starve = nil
            if e then Ev.Resolve(world, e, "fed", a.name .. " finally got a proper meal.") end
        end
    else
        p = Ev.Person(world, a.id)
        p.starve = p.starve or { level = 0 }
        local s = p.starve
        for n, wdef in ipairs(SD.warnings) do
            if hunger <= wdef.at and (s.level or 0) < n then
                s.level = n
                local text = string.format(wdef.text, a.name)
                local e = starveRecord(world, a, p)
                Ev.Journal(world, text, e, { a.id })
                if wdef.emergency then Ev.Emergency(world, text, wdef.emergency) else Ev.Tell(world, a, text, "hunger") end
            end
        end
        if hunger <= -99.5 and dependent then
            -- a dependent: no clock, no collapse; the record stays open until they are fed
            if not s.dependentWarned then
                s.dependentWarned = world.time
                local text = a.name .. " is starving. A child cannot look after this alone: feed them now."
                Ev.Journal(world, text, starveRecord(world, a, p), { a.id })
                Ev.Emergency(world, text, "emergency")
            end
        elseif hunger <= -99.5 then
            s.since = s.since or world.time
            local at = world.time - s.since
            local e = starveRecord(world, a, p)
            for _, k in ipairs({ "critical", "fading", "last" }) do
                local st = SD[k]
                if at >= st.after and not (s.stage and s.stage[k]) then
                    s.stage = s.stage or {}
                    s.stage[k] = world.time
                    local text = string.format(st.text, a.name)
                    Ev.Journal(world, text, e, { a.id })
                    Ev.Emergency(world, text, st.emergency)
                end
            end
            if at >= SD.fatalAfter and SS.Death and SS.Death.Collapse then
                SS.Death.Collapse(world, a, "starvation", a.name .. " collapsed from hunger.")
            end
        elseif s.since then
            s.since, s.stage = nil, nil   -- they ate something: the clock stops
        end
    end
end
Ev.OnHour("starvation", function(world) H.StarvationHour(world) end, 5)

---------------------------------------------------------------------------------------------------
-- Electrocution. SS.Hazards.Electrocute(world, actor, obj, opts) decides the outcome of an
-- electrical repair attempt. Risk falls with mechanical skill and rises with standing water. A
-- first shock is the warning; a shock while wet or soon after another can be fatal (collapse,
-- then death). Returns "ok" | "shock" | "fatal".
-- Who rolls whether a shock happens at all: this module, by default (household-core's
-- M.ShockCheck hands the whole decision over and reads back the result). A caller that already
-- rolled its own chance passes { rolled = true }, and { force = true } always shocks; neither
-- rolls again, so the shock is never gated twice.

local function wetNear(world, a, obj)
    local ai, aj, al = Ev.CellOf(a)
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        if def and (def.wet or (o.state and o.state.wet)) and (o.level or 0) == al then
            if Ev.Dist(o.x, o.y, ai, aj) <= 1 or (obj and Ev.Dist(o.x, o.y, obj.x, obj.y) <= 1) then return true end
        end
    end
    return false
end
H.WetNear = wetNear

function H.ElectricRisk(world, actor, obj)
    local mech = (SS.Skills and SS.Skills.Level and SS.Skills.Level(actor, "mechanical")) or 0
    local chance = max(XD.minShock, XD.shock * (1 - mech / 10))
    local wet = wetNear(world, actor, obj)
    if wet then chance = chance + XD.wet end
    return min(0.95, chance), wet
end

local sparks = {}   -- runtime: { level, x, y, untilT }
H.sparks = sparks

-- Has the caller already decided that a shock happens? household-core's ShockCheck hands the
-- whole roll to this module (it calls Electrocute(world, actor, obj) and reads back "ok",
-- "shock" or "fatal"), so by default this module rolls. A caller that rolled its own chance
-- passes { rolled = true }; { force = true } (debug, scripted events) always shocks.
function H.ShockRolled(opts)
    return type(opts) == "table" and (opts.rolled or opts.force) and true or false
end

function H.Electrocute(world, actor, obj, opts)
    if not actor or actor.dead then return "ok" end
    local chance, wet = H.ElectricRisk(world, actor, obj)
    if not H.ShockRolled(opts) and SS.Random(world, "hazards") >= chance then return "ok" end
    local p = Ev.Person(world, actor.id)
    local recent = p.lastShock and world.time - p.lastShock < XD.recent
    p.lastShock, p.shockObj = world.time, obj and obj.id
    if obj then
        if #sparks >= 8 then table.remove(sparks, 1) end
        sparks[#sparks + 1] = { level = obj.level or 0, x = obj.x + 0.5, y = obj.y + 0.5, untilT = world.time + XD.sparksMinutes }
    end
    local def = obj and SS.Objects[obj.def]
    local e = Ev.Record(world, "shock", { wet = wet, recent = recent and true or false }, { who = { actor.id }, targets = obj and { obj.id } or {},
        family = "neglect", budget = false, cause = "electrical" })
    if (wet or recent) and SS.Random(world, "hazards") < XD.fatal and SS.Death and SS.Death.Collapse then
        Ev.Resolve(world, e, "fatal")
        SS.Death.Collapse(world, actor, "electrocution", actor.name .. " took a severe shock from the " .. (def and def.name or "wiring") .. " and collapsed.")
        return "fatal"
    end
    SS.Needs.Add(actor, "energy", -30)
    SS.Needs.Add(actor, "comfort", -25)
    SS.Needs.Add(actor, "hygiene", -20)
    if actor.act then SS.Actions.Finish(world, actor, "cancelled") end
    Ev.Pseudo(world, actor, "ev_shocked", { len = 3 })
    local warn = actor.name .. " got a nasty shock from the " .. (def and def.name or "wiring") .. "."
    if wet then warn = warn .. " Standing water makes this far more dangerous." end
    warn = warn .. " Another shock soon could be fatal; a repair service is safer."
    Ev.Emergency(world, warn, "warning")
    Ev.Resolve(world, e, "shocked", actor.name .. " survived an electric shock (singed eyebrows).")
    -- a bad shock can start an electrical fire at the object
    if obj and SS.Fire and SS.Fire.Ignite and SS.Random(world, "hazards") < 0.1 then
        SS.Fire.Ignite(world, obj.level or 0, obj.x, obj.y, "shock", obj.id)
    end
    return "shock"
end

-- Is this an electrical object (the kind a repair can shock)? household-core's own rule when it
-- has one (SS.Maintenance.IsPowered), else electronics, lighting and def.powered.
function H.IsElectrical(def)
    if not def or def.system then return false end
    local M = SS.Maintenance
    if M and type(M.IsPowered) == "function" then
        local ok, r = pcall(M.IsPowered, def)
        if ok then return r and true or false end
    end
    return (def.powered or def.cat == "electronics" or def.cat == "lighting") and true or false
end

-- After a shock, a resident does not go back to electrical repairs on their own while another
-- shock could be fatal (XD.recent). Household-core's autonomy already rests a failed
-- object/interaction pair for its own actor (actor.cool["<oid>:<iid>"], with the reason in
-- actor.tmp.coolWhy, shown in the inspector); when the shocked repair ends, events lengthens that
-- rest to the end of the danger window for every broken electrical object on the lot. Menus and
-- the player's orders do not read it: the player can still send them (the hint shows the risk).
SS.On("actionEnded", function(actor, act, status)
    local world = SS.Sim.world
    if not (world and world.lot and actor and act and act.iid and status ~= "done" and not actor.dead) then return end
    local p = Ev.PersonIf(world, actor.id)
    if not (p and p.lastShock and world.time - p.lastShock <= 1 and act.oid == p.shockObj) then return end
    local untilT = p.lastShock + XD.recent
    actor.cool = type(actor.cool) == "table" and actor.cool or {}
    actor.tmp = type(actor.tmp) == "table" and actor.tmp or {}
    actor.tmp.coolWhy = type(actor.tmp.coolWhy) == "table" and actor.tmp.coolWhy or {}
    for oid, o in pairs(world.lot.objects) do
        if o.state and o.state.broken and (oid == act.oid or H.IsElectrical(SS.Objects[o.def])) then
            local key = oid .. ":" .. act.iid
            if (actor.cool[key] or 0) < untilT then
                actor.cool[key] = untilT
                actor.tmp.coolWhy[key] = XD.shakenWhy
            end
        end
    end
end)

SS.Interactions.ev_shocked = {
    label = "Shocked", category = "Other", pose = "collapse", advert = {}, manualOnly = true, maxDur = 10,
    onTick = function(world, actor, act, o, dt) if act.t + dt >= (act.data.len or 3) then act.complete = true end end,
}

Ev.OnEffects(function(world, add)
    for n = #sparks, 1, -1 do
        local s = sparks[n]
        if s.untilT < world.time then table.remove(sparks, n) else add(s.level, s.x, s.y, 0.6, "sparks", 0.8) end
    end
end)

---------------------------------------------------------------------------------------------------
-- Burglary: a burglar comes at night, goes for a valuable object and carries it off, unless a
-- burglar alarm catches them and the police arrive in time. Awake residents who see them can
-- call the police too.

local function lotValue(world)
    if SS.Economy and SS.Economy.LotValue then
        local v = Ev.Call(SS.Economy.LotValue, world, world.lot)
        if type(v) == "number" then return v end
    end
    local v = 0
    for _, o in pairs(world.lot.objects) do local d = SS.Objects[o.def]; v = v + (d and d.price or 0) end
    return v
end
H.LotValue = lotValue

local function objectValue(world, o)
    local def = SS.Objects[o.def]
    if SS.Economy and SS.Economy.ResaleValue then
        local v = Ev.Call(SS.Economy.ResaleValue, world, o)
        if type(v) == "number" then return v end
    end
    return def and def.price or 0
end

-- Stealable things on the ground floor: valuable, small, not built in, not in use.
function H.Valuables(world)
    local out = {}
    for _, oid in ipairs(Ev.SortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and not def.system and not def.stairs and BD.cats[def.cat] and not H.IsPlumbing(def) and (o.level or 0) == 0 and (def.price or 0) >= BD.minItemValue
            and #(def.fp or { { 0, 0 } }) <= 2 and not (def.cat or ""):find("^build") and not (o.state and (o.state.burnt or o.state.burning))
            and not (o.res and next(o.res)) and not Ev.HasTag(def, "memorial") then
            out[#out + 1] = { o = o, v = objectValue(world, o) }
        end
    end
    table.sort(out, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.o.id < b.o.id end)
    return out
end

local function burglarAlarms(world)
    local out = {}
    for _, oid in ipairs(Ev.SortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and Ev.HasTag(def, "burglar_alarm") and not (o.state and (o.state.broken or o.state.burnt)) then out[#out + 1] = o end
    end
    return out
end
H.BurglarAlarms = burglarAlarms

-- Coverage: an alarm covers indoor cells on its level within its range: the catalogue's
-- def.quality.range when set (the burglar alarm panel has 10), else BD.alarmRange.
function H.AlarmRange(al)
    local def = SS.Objects[al.def]
    local r = def and def.quality and def.quality.range
    return type(r) == "number" and r or BD.alarmRange
end
function H.AlarmCovers(world, al, level, i, j)
    if (al.level or 0) ~= level then return false end
    if SS.World.RoomAt(world, level, i, j) == 0 then return false end
    return Ev.Dist(al.x, al.y, i, j) <= H.AlarmRange(al)
end

Ev.families.burglary = {
    eligible = function(world)
        if Ev.EmergencyActive(world) then return false, "something else is going on" end
        if homeAwake(world) then return false, "someone is awake" end
        local v = lotValue(world)
        if v < BD.minValue then return false, "nothing worth taking" end
        if #H.Valuables(world) == 0 then return false, "nothing portable worth taking" end
        local fam = nil
        for _, f in ipairs(ED.families) do if f.id == "burglary" then fam = f end end
        return true, min(BD.maxChance, (fam and fam.chance or 0.02) + v / BD.valueScale)
    end,
    run = function(world)
        local e = Ev.Record(world, "burglary", { lotValue = lotValue(world) }, { family = "burglary", lane = "emergency" })
        Ev.RequestResponder(world, e, "burglar", H.BurglarId(), SS.RandomInt(world, "hazards", 2, 10))
        return e
    end,
}

-- Debug / tests: send a burglar now through the same path.
function H.DebugBurglary(world)
    local e = Ev.Record(world, "burglary", { lotValue = lotValue(world), debug = true }, { family = "burglary", lane = "emergency" })
    Ev.RequestResponder(world, e, "burglar", H.BurglarId(), 1)
    return e
end

-- The officer: the visitors module's first police identity when its pools are loaded, else ours.
function H.PoliceId() return Ev.ResponderId("police", 1, "npc_police_1") end
function H.BurglarId() return "npc_burglar_1" end

local function callPolice(world, e, how, caller)
    if e.data.police then return false, "The police are already on the way." end
    local delay = BD.policeResponse + SS.RandomInt(world, "hazards", 0, BD.policeJitter)
    local rid = H.PoliceId()
    e.data.police = { how = how, t = world.time, by = caller and caller.id, eta = world.time + delay, rid = rid }
    e.data.calling = nil
    Ev.RequestResponder(world, e, "police", rid, delay, "police_car")
    if how == "alarm" then Ev.Journal(world, "The burglar alarm went off and called the police.", e)
    else Ev.Journal(world, (caller and caller.name or "Someone") .. " called the police.", e) end
    return true, "The police are on their way."
end
H.CallPolice = callPolice

local function burglarOnLot(world)
    local ids = Ev.ActorIds(world)
    for n = 1, #ids do
        local a = world.actors[ids[n]]
        if a and a.role == "burglar" and a.roleData and a.roleData.phase ~= "leaving" then return a end
    end
end
H.BurglarOnLot = burglarOnLot

if SS.Phone and SS.Phone.RegisterCall then
    SS.Phone.RegisterCall({
        id = "ev_police", label = "Police", category = "Emergency", order = 2,
        test = function(world, caller)
            local b = burglarOnLot(world)
            if not b then return false, "Nothing to report right now." end
            local e = Ev.Find(world, b.roleData.eventId)
            if e and e.data.police then return false, "The police are already on the way." end
            return true
        end,
        run = function(world, caller)
            local b = burglarOnLot(world)
            local e = b and Ev.Find(world, b.roleData.eventId)
            if not e then return false, "Nothing to report right now." end
            return callPolice(world, e, "phone", caller)
        end,
    })
end

local function freeNeighbour(world, o, from)
    local ai, aj = floor(from.x), floor(from.y)
    local dist = Ev.Flood(world, 0, ai, aj, from)
    local best, bd
    for _, c in ipairs(Ev.ObjectCells(o)) do
        for k = 0, 3 do
            local dv = SS.Grid.DIRS[k]
            local ni, nj = c[1] + dv[1], c[2] + dv[2]
            local d = dist[nj * world.lot.w + ni]
            -- reach it from the same side of any wall (no grabbing through walls or windows)
            local wl = SS.World.WallAt(world.lot, 0, SS.Grid.edgeBetween(ni, nj, c[1], c[2]))
            if d and SS.World.InLot(world.lot, ni, nj) and not (wl and not SS.World.OPENINGS[wl.kind]) and (not bd or d < bd) then
                best, bd = { ni, nj }, d
            end
        end
    end
    return best
end

local function burglarLeave(world, a, e, why)
    local rd = a.roleData
    if rd.phase == "leaving" or rd.phase == "exit" then return end
    rd.phase = "exit"
    if a.act then SS.Actions.Finish(world, a, "cancelled") end
    a.queue = {}
    local ei, ej = SS.Street.EntryCell(world)
    SS.Actions.Order(world, a, nil, "goto", ei, ej, { level = 0, manual = true, data = { source = "events" } })
    rd.exitWhy = why
end

local function steal(world, a, e, o)
    local def = SS.Objects[o.def]
    local v = objectValue(world, o)
    e.data.stolen = { name = def and def.name or o.def, value = v, def = o.def, oid = o.id }
    if Ev.Once(e, "stolen", world) then
        Ev.RemoveObject(world, world.lot, o.id)
        a.carry = "loot"
        Ev.Journal(world, "A burglar made off with the " .. (def and def.name or "valuables") .. " (" .. SS.U.fmtMoney(v) .. ").", e)
        SS.Emit("burglary", world, e)
    end
end

local function caught(world, e, police, burglar)
    if not Ev.Once(e, "caught", world) then return end
    local stolen = e.data.stolen
    local text = (police and police.name or "The police") .. " caught the burglar in the act."
    if stolen and e.data.stolenReturned == nil then
        -- recovered goods go back into the household inventory (or are paid back when it cannot
        -- take them, so the text never claims something that did not happen)
        local back = SS.Inventory and SS.Inventory.Add and Ev.Call(SS.Inventory.Add, world,
            { kind = "object", def = stolen.def, name = stolen.name, value = stolen.value, data = { source = "recovered" } })
        e.data.stolenReturned = back and "inventory" or "paid"
        if back then
            text = text .. " The " .. stolen.name .. " was recovered and put in the household inventory."
        else
            SS.Money(world, stolen.value or 0, "insurance", "Recovered stolen " .. stolen.name .. " (paid back)")
            text = text .. " The " .. stolen.name .. " was recovered; its value (" .. SS.U.fmtMoney(stolen.value or 0) .. ") was paid back."
        end
    else
        text = text .. " Nothing was taken."
    end
    for _, m in ipairs(Ev.Members(world)) do SS.Needs.Add(m, "fun", 10) end
    Ev.Resolve(world, e, "caught", text)
    Ev.Emergency(world, text, "info")
    if burglar then
        burglar.carry = nil
        Ev.SendAway(world, burglar, "arrested")
    end
end

local function burglarTick(world, a, dt)
    local rd = a.roleData
    if rd.phase == "leaving" then return end
    local e = Ev.Find(world, rd.eventId)
    if not e then return Ev.SendAway(world, a, "done") end
    rd.arrivedAt = rd.arrivedAt or world.time
    rd.phase = rd.phase or "enter"
    a.outfit = "burglar"
    -- the alarm keeps ringing while the burglar is in the house
    if e.data.alarm and e.state == "active" then Ev.KeepRinging(world, world.lot.objects[e.data.alarm]) end
    if world.time < (rd.next or -1e9) then return end
    rd.next = world.time + 0.5
    local ai, aj, al = Ev.CellOf(a)
    -- alarm
    if not e.data.alarm and rd.phase ~= "exit" then
        for _, al_ in ipairs(burglarAlarms(world)) do
            if H.AlarmCovers(world, al_, al, ai, aj) then
                e.data.alarm, e.data.alarmAt = al_.id, world.time
                Ev.StartRinging(world, al_)
                Ev.Audio("Cue", "burglar_alarm")
                Ev.Emergency(world, "The burglar alarm is going off!", "emergency")
                callPolice(world, e, "alarm")
                rd.phase = "frozen"
                rd.frozenUntil = world.time + BD.freezeMinutes
                Ev.Pseudo(world, a, "ev_freeze", { len = BD.freezeMinutes })
                -- the whole house wakes up
                for _, m in ipairs(Ev.Members(world)) do
                    if m.sleeping then SS.Actions.Cancel(world, m, 0) end
                end
                break
            end
        end
    end
    if rd.phase == "frozen" then
        if world.time >= (rd.frozenUntil or 0) and not rd.held then
            -- an officer already here or pulling up (the visitors module drives them in and walks
            -- them up from the curb) keeps the burglar pinned a little longer: caught in the act
            local pid = e.data.police and e.data.police.rid
            local cop = pid and world.actors[pid]
            if cop and cop.role == "police" then
                rd.held = world.time
                rd.frozenUntil = world.time + BD.holdMinutes
                if not a.act then Ev.Pseudo(world, a, "ev_freeze", { len = BD.holdMinutes }) end
                return
            end
        end
        if world.time >= (rd.frozenUntil or 0) then
            if Ev.Once(e, "fled", world) then
                Ev.Resolve(world, e, "scared_off", "The burglar alarm scared the intruder off before the police arrived. Nothing was taken.")
            end
            burglarLeave(world, a, e, "fled")
        end
        return
    end
    if rd.phase == "exit" then
        local ei, ej = SS.Street.EntryCell(world)
        if not a.act and (Ev.Dist(ai, aj, ei, ej) <= 1 or (rd.exitTries or 0) > 3) then
            Ev.SendAway(world, a, rd.exitWhy or "done")
        elseif not a.act then
            rd.exitTries = (rd.exitTries or 0) + 1
            SS.Actions.Order(world, a, nil, "goto", ei, ej, { level = 0, manual = true, data = { source = "events" } })
        end
        return
    end
    if world.time - rd.arrivedAt >= BD.maxStay then return burglarLeave(world, a, e, "gave_up") end
    if rd.phase == "enter" then
        if a.act then return end
        local vals = H.Valuables(world)
        for n = 1 + (rd.skip or 0), #vals do
            local cell = freeNeighbour(world, vals[n].o, a)
            if cell then
                rd.target = vals[n].o.id
                rd.phase = "go"
                SS.Actions.Order(world, a, nil, "goto", cell[1], cell[2], { level = 0, manual = true, data = { source = "events" } })
                return
            end
        end
        if Ev.Once(e, "nothing", world) then Ev.Resolve(world, e, "nothing_taken", "An intruder tried the house in the night but found nothing to take.") end
        return burglarLeave(world, a, e, "nothing")
    elseif rd.phase == "go" then
        if a.act then return end
        local o = rd.target and world.lot.objects[rd.target]
        if not o then rd.phase = "enter"; rd.skip = (rd.skip or 0) + 1; return end
        local near = false
        for _, c in ipairs(Ev.ObjectCells(o)) do if Ev.Dist(ai, aj, c[1], c[2]) <= 1 then near = true end end
        if not near then rd.phase = "enter"; rd.skip = (rd.skip or 0) + 1; return end
        rd.phase = "grab"
        a.facing = SS.Grid.dirToFacing(o.x - ai, o.y - aj)
        Ev.Pseudo(world, a, "ev_grab", { len = BD.grabMinutes, oid = o.id })
    elseif rd.phase == "grab" then
        if a.act and a.act.iid == "ev_grab" then return end
        local o = rd.target and world.lot.objects[rd.target]
        if o and rd.grabbed then steal(world, a, e, o) end
        burglarLeave(world, a, e, o and "stole" or "nothing")
    end
end

SS.Interactions.ev_grab = {
    label = "Rummaging", category = "Other", pose = "use", advert = {}, manualOnly = true, maxDur = 30,
    onTick = function(world, actor, act, o, dt)
        if act.t + dt >= (act.data.len or 5) then
            act.complete = true
            if actor.roleData then actor.roleData.grabbed = true end
        end
    end,
}
SS.Interactions.ev_freeze = {
    label = "Caught Out", category = "Other", pose = "panic", advert = {}, manualOnly = true, maxDur = 30,
    onTick = function(world, actor, act, o, dt) if act.t + dt >= (act.data.len or 10) then act.complete = true end end,
}
SS.Interactions.ev_call_police = {
    label = "Call the Police", category = "Emergency", pose = "phone", advert = {}, manualOnly = true, dur = 1.5,
    onStart = function(world, actor) actor.carry = "phone" end,
    onEnd = function(world, actor, act, o, status)
        actor.carry = nil
        local e = Ev.Find(world, act.data.ev)
        if e and e.data.calling == actor.id then e.data.calling = nil end
        if status == "done" and e and e.state == "active" then callPolice(world, e, "phone", actor) end
    end,
}
SS.Interactions.ev_arrest = {
    label = "Arrest", category = "Other", targetActor = true, pose = "argue", dur = 2, advert = {}, manualOnly = true,
    test = function(world, actor, target)
        if actor.role ~= "police" then return false, "Leave that to the police." end
        if not target or target.role ~= "burglar" then return false, "Nobody to arrest." end
        return true
    end,
    onEnd = function(world, actor, act, o, status)
        local b = world.actors[act.tid]
        if status ~= "done" or not b or b.role ~= "burglar" then return end
        local e = Ev.Find(world, b.roleData.eventId)
        if e then caught(world, e, actor, b) end
    end,
}

-- Awake residents who see the burglar raise the alarm (adults phone the police).
Ev.OnMinute("burglar_seen", function(world)
    local b = burglarOnLot(world)
    if not b then return end
    local e = Ev.Find(world, b.roleData.eventId)
    if not e or e.state ~= "active" then return end
    local bi, bj, bl = Ev.CellOf(b)
    local room = SS.World.RoomAt(world, bl, bi, bj)
    for _, a in ipairs(Ev.Members(world, function(m) return not m.sleeping and Ev.IsHuman(m) end)) do
        local ai, aj, al = Ev.CellOf(a)
        if al == bl and Ev.Dist(ai, aj, bi, bj) <= BD.seeRange and (SS.World.RoomAt(world, al, ai, aj) == room or Ev.Dist(ai, aj, bi, bj) <= 2) then
            if Ev.Once(e, "seen", world) then
                Ev.Emergency(world, a.name .. " spotted a burglar!", "emergency")
                Ev.Journal(world, a.name .. " caught sight of a burglar in the house.", e, { a.id })
            end
            -- a caller who is no longer on the phone (interrupted, or the game was reloaded
            -- mid-call: actions do not survive a load) frees the line for someone else
            local c = e.data.calling and world.actors[e.data.calling]
            if e.data.calling and not (c and c.act and c.act.iid == "ev_call_police") then e.data.calling = nil end
            if not (a.act and (a.act.iid == "ev_call_police" or a.act.iid == "ev_panic")) then
                if Ev.IsAdult(a) and not e.data.police and not e.data.calling then
                    e.data.calling = a.id
                    Ev.Pseudo(world, a, "ev_call_police", { ev = e.id })
                elseif not Ev.IsAdult(a) and Ev.Once(e, "kidpanic:" .. a.id, world) then
                    Ev.Pseudo(world, a, "ev_panic", { len = 3 })
                end
            end
        end
    end
end, 45)

-- Police (visitors-framework role): catch a burglar who is still here, otherwise take a
-- statement and leave.
local function policeTick(world, a, dt)
    local rd = a.roleData
    if rd.phase == "leaving" then return end
    rd.phase = rd.phase or "respond"
    rd.arrivedAt = rd.arrivedAt or world.time
    local e = Ev.Find(world, rd.eventId)
    a.outfit = "police"
    -- ...and until the police have dealt with it
    if e and e.data.alarm and e.state == "active" then Ev.KeepRinging(world, world.lot.objects[e.data.alarm]) end
    if a.act then return end
    if world.time < (rd.next or -1e9) then return end
    rd.next = world.time + 1
    local b = burglarOnLot(world)
    if b and e and e.state == "active" and (rd.tries or 0) < 6 then
        rd.tries = (rd.tries or 0) + 1
        SS.Actions.Order(world, a, nil, "ev_arrest", nil, nil, { tid = b.id, manual = true, data = { source = "events" } })
        return
    end
    if rd.phase ~= "statement" then
        rd.phase = "statement"
        rd.untilT = world.time + BD.searchMinutes
        a.pose = "talk"
        return
    end
    if world.time >= (rd.untilT or 0) then
        if e and e.state == "active" then
            if e.data.stolen then
                Ev.Resolve(world, e, "stolen", (a.name or "The officer") .. " took a statement about the stolen " .. e.data.stolen.name .. ". It is gone.")
            else
                Ev.Resolve(world, e, "nothing_taken", (a.name or "The officer") .. " checked the house. Whoever it was is long gone.")
            end
        end
        Ev.SendAway(world, a, "done")
    end
end

if SS.Visitors and SS.Visitors.RegisterRole then
    SS.Visitors.RegisterRole("burglar", {
        label = "Burglar", noNeeds = true, access = "intruder", useAutonomy = false, uniform = "burglar", outfit = "burglar",
        onArrive = function(world, a) a.outfit = "burglar"; a.roleData.phase = "enter" end,
        onLeave = function(world, a) a.carry = nil end,
        tick = burglarTick,
    })
    SS.Visitors.RegisterRole("police", {
        label = "Police Officer", noNeeds = true, access = "emergency", useAutonomy = false, uniform = "police",
        outfit = "police", pool = "police", vehicle = "police_car",
        onArrive = function(world, a)
            a.outfit = "police"
            local e = Ev.Find(world, a.roleData.eventId)
            if e and Ev.Once(e, "policeArrived", world) then Ev.Journal(world, (a.name or "The police") .. " arrived.", e) end
        end,
        onLeave = function(world, a) Ev.ClearVehicle(a.id) end,
        tick = policeTick,
    })
end

Ev.arrivals.burglar = function(world, e)
    return e.state == "active" and not homeAwake(world) or (e.state == "active" and e.data.debug)
end
Ev.arrivals.police = function(world, e) return true end

-- In the morning (or when someone wakes), an unnoticed theft is discovered.
Ev.OnHour("burglary_discovery", function(world)
    for _, e in ipairs(Ev.Open(world, "burglary", world.lot.id)) do
        local rs = e.data.responders or {}
        local function pending(rid) return rs[rid] ~= nil and Ev.Pending(world, e, rid) end
        local prid = e.data.police and e.data.police.rid or H.PoliceId()
        if e.state == "active" and not burglarOnLot(world) and not world.actors[prid] and not pending(H.BurglarId()) and not pending(prid) then
            if e.data.stolen then
                -- the theft is discovered once someone is up and about
                if homeAwake(world) and Ev.Once(e, "discovered", world) then
                    for _, m in ipairs(Ev.Members(world)) do SS.Needs.Add(m, "comfort", -10); SS.Needs.Add(m, "fun", -10) end
                    local who = Ev.Members(world, function(m) return not m.sleeping end)[1]
                    if who then Ev.Say(world, who, "burglary", { item = e.data.stolen.def }, "Where is the " .. e.data.stolen.name .. "? We've been robbed!", "alert", true) end
                    Ev.Resolve(world, e, "stolen", "The household woke to find the " .. e.data.stolen.name .. " gone (" .. SS.U.fmtMoney(e.data.stolen.value) .. "). The burglar got away.")
                end
            else
                -- nobody came (skipped), or they left with nothing
                Ev.Resolve(world, e, "nothing_taken")
            end
        end
        if e.data.alarm then
            local al = world.lot.objects[e.data.alarm]
            if e.state ~= "active" then Ev.StopRinging(world, al) else Ev.KeepRinging(world, al) end
        end
    end
end, 35)

-- A burglary that ends (caught, scared off, reported) silences its alarm straight away.
local function silence(world, e)
    if not (world and e and e.kind == "burglary" and e.data and e.data.alarm) then return end
    local lot = world.lot
    if not lot or lot.id ~= e.lotId or not lot.objects then return end
    Ev.StopRinging(world, lot.objects[e.data.alarm])
end
H.Silence = silence
SS.On("eventResolved", function(world, e) silence(world, e) end)
SS.On("eventAftermath", function(world, e) silence(world, e) end)

-- Alarm ringing effect (shared list with the fire alarm effect in Sim/Fire.lua).
Ev.OnEffects(function(world, add)
    local b = burglarOnLot(world)
    if not b then return end
    local e = Ev.Find(world, b.roleData.eventId)
    local al = e and e.data.alarm and world.lot.objects[e.data.alarm]
    if al then add(al.level or 0, al.x + 0.5, al.y + 0.5, 1.8, "alarm_flash", 1) end
end)
