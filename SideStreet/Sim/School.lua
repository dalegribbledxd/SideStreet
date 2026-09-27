-- School: the weekday school bus, grades (A-F) from homework and mood, homework at a desk or table,
-- the weekly report card and its effects, the neglect path (warnings, a note home, a meeting with
-- the school counselor, then a referral to the family module) and home-alone supervision for
-- school-age children. Infants and toddlers belong to the family module.
-- Owner: careers module (docs/modules/careers.md). Data: SS.CareerData.school (Data/Careers.lua).
--
-- Saved data:
--   child.school = { score (0..100), letter, homework = { forDay, minutes, done, assignedAt } | nil,
--       missingStreak, concern, goodDays, absences = { t... }, trip = tripRecord | nil, trips = { last 5 },
--       reports = { { t, letter, score }... } (last 6), plan = { untilT } | nil, noteLevel, referred,
--       aloneSince, aloneFlagged, lastReportDay }
--   tripRecord = { day, state = "waiting"|"away"|"done"|"missed"|"skipped", boardedAt, mood, returnAt, homework, paid,
--       meal (hunger from the school lunch, D.school.lunch) }
--   household.schoolBus = { day, state = "planned"|"waiting"|"gone"|"done"|"skipped", busAt, leaveAt, returnAt }
--   household.schoolCare = { nextId, meeting = { id, at, state = "scheduled"|"arrived"|"meeting"|"done"|"missed", rids, tries } | nil,
--       lastMeeting (a meeting the school called off, state "cancelled", after counselor.maxTries visits nobody could make) }
-- Scheduled events (home lot): "school.wake", "school.bus", "school.leave", "school.dropoff", "school.return"
--   (data { day }), "school.counselor" (data { id }).
-- Events emitted: "schoolDeparted", "schoolHome", "schoolAbsent", "reportCard", "schoolConcern", "homeworkDone".
local _, SS = ...
local S = SS.School or {}
SS.School = S
local U = SS.U

local function D() return SS.CareerData.school end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function fmt(v) return U.fmtMoney(v) end
local function C() return SS.Career end

S.rt = S.rt or { board = {}, busUntil = nil }

local function isHome(world) return not S.suspended and SS.Economy and SS.Economy.IsHome(world) end
local function journal(world, text)
    if SS.Actions and SS.Actions.Journal and world.journal then SS.Actions.Journal(world, text) end
end
local function tell(world, actor, text, icon) return SS.Career.Tell(world, actor, text, icon or "school") end
-- a spoken line through social's Lines situations (school_good / school_bad); silent without them
local function say(world, actor, situation, ctx)
    if SS.Career.Say then return SS.Career.Say(world, actor, situation, ctx) end
end

local function sortedKeys(t)
    local ids = {}
    for k in pairs(t) do ids[#ids + 1] = k end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    return ids
end

---------------------------------------------------------------------------------------------------
-- Records and grades
---------------------------------------------------------------------------------------------------
-- Test hook for other modules whose tests simulate school themselves (e.g. household-core's A17
-- day): SS.School.Suspend(true) makes the school routine inert (no bus, homework, report cards or
-- home-alone checks) until Suspend(false). Runtime only, never saved; the game never calls it.
function S.Suspend(on) S.suspended = on and true or nil end

function S.Record(child)
    local s = child.school
    if type(s) ~= "table" then
        s = { score = D().gradeStart, missingStreak = 0, concern = 0, goodDays = 0, absences = {}, trips = {}, reports = {} }
        child.school = s
    end
    s.score = s.score or D().gradeStart
    s.absences = s.absences or {}
    s.trips = s.trips or {}
    s.reports = s.reports or {}
    s.concern = s.concern or 0
    s.missingStreak = s.missingStreak or 0
    s.goodDays = s.goodDays or 0
    s.letter = S.Letter(s.score)
    return s
end

function S.Letter(score)
    for _, row in ipairs(D().letters) do
        if score >= row[1] then return row[2] end
    end
    return "F"
end

function S.Children(world)
    local out = {}
    for _, m in ipairs(C().Members(world)) do if C().SchoolAge(m) then out[#out + 1] = m end end
    return out
end

function S.IsSchoolDay(day)
    local wd = day % 7
    for _, d in ipairs(D().days) do if d == wd then return true end end
    return false
end

local function changeScore(child, delta)
    local s = S.Record(child)
    s.score = clamp(s.score + delta, 0, 100)
    s.letter = S.Letter(s.score)
    return s.score
end
S.ChangeScore = changeScore

function S.MoodPoints(mood)
    for _, tier in ipairs(D().mood) do if mood >= tier[1] then return tier[2] end end
    return D().mood[#D().mood][2]
end

-- Adults who look after the household's children: working-age members plus a nanny or babysitter.
local function adultPresent(world, except)
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and a ~= except then
            if (C().IsMember(world, a) and C().WorkingAge(a) and not C().Leaving(a)) or a.role == "nanny" or a.role == "babysitter" then return a end
        end
    end
end
S.AdultPresent = adultPresent

function S.Parents(world, child)
    local out = {}
    for _, m in ipairs(C().Members(world)) do
        if m.id ~= child.id and C().WorkingAge(m) then out[#out + 1] = m end
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Concern: the neglect path. Warnings, a note home, a counselor meeting, then a referral.
---------------------------------------------------------------------------------------------------
local meetingDue -- forward

local function raiseConcern(world, child, amount, why)
    local s = S.Record(child)
    s.concern = clamp(s.concern + amount, 0, 20)
    s.goodDays = 0
    local cn = D().concern
    SS.Emit("schoolConcern", world, child, "raised", why)
    if s.concern >= cn.referralAt and not s.referred then
        s.referred = true
        local text = string.format("The school has passed its concerns about %s to the family welfare office (%s).", child.name, why)
        tell(world, child, text, "warning")
        journal(world, text)
        -- the family module's child-welfare flow takes it from here: a school referral hook if it has
        -- one, else a documented neglect incident (its strike and inspection path)
        -- (family words its own notice as "Neglect reported: <name> <reason>. ...", so the reason
        -- is a clause that follows the child's name)
        local F = SS.Family
        local handed = false
        if F and F.WelfareConcern then
            -- (family returns false when it does not take the concern up, e.g. for a household that has ended)
            local ok, taken = pcall(F.WelfareConcern, world, child, "school", { why = why, concern = s.concern })
            handed = ok and taken ~= false
        elseif F and F.AddStrike then
            handed = pcall(F.AddStrike, world, nil, child, "was referred by the school (" .. why .. ")")
        end
        SS.Emit("schoolConcern", world, child, "referral", why)
        -- family's flow raises its own alert; without it the school's text is the alert
        if not handed and SS.Sim.Emergency then SS.Sim.Emergency(world, text, "warning") end
    elseif s.concern >= cn.meetingAt then
        meetingDue(world, child, why)
    elseif s.concern >= cn.noteAt and (s.noteLevel or 0) < 1 then
        s.noteLevel = 1
        local text = string.format("A note from %s's teacher: \"We are a little worried (%s). Please make sure homework gets done and the bus is not missed.\"", child.name, why)
        if SS.Economy and SS.Economy.Post then SS.Economy.Post(world, "note", text) end
        tell(world, child, child.name .. " brought home a note from the teacher.", "school")
        journal(world, child.name .. " brought home a worried note from school.")
        SS.Emit("schoolConcern", world, child, "note", why)
    end
end
S.RaiseConcern = raiseConcern

local function care(world)
    local hh = world.household
    if type(hh.schoolCare) ~= "table" then hh.schoolCare = { nextId = 0 } end
    return hh.schoolCare
end

-- The next weekday at the counselor's hour, at least `after` minutes from now.
local function nextVisitTime(world, after)
    local cs = D().counselor
    local d0 = math.floor((world.time + after) / 1440)
    for d = d0, d0 + 10 do
        if S.IsSchoolDay(d) then
            local t = d * 1440 + cs.hour * 60 + cs.minute
            if t >= world.time + after then return t end
        end
    end
    return world.time + after + 1440
end

meetingDue = function(world, child, why)
    local st = care(world)
    local m = st.meeting
    if m and (m.state == "scheduled" or m.state == "arrived" or m.state == "meeting") then
        for _, rid in ipairs(m.rids) do if rid == child.id then return end end
        m.rids[#m.rids + 1] = child.id
        return
    end
    st.nextId = (st.nextId or 0) + 1
    m = { id = "meet" .. st.nextId, rids = { child.id }, state = "scheduled", tries = 0, why = why }
    m.at = nextVisitTime(world, 12 * 60)
    st.meeting = m
    SS.Sim.Schedule(world, m.at, "school.counselor", { id = m.id }, world.lot.id)
    local s = S.Record(child)
    s.noteLevel = 2
    local text = string.format("The school has asked to meet a parent about %s (%s). A counselor will visit %s. An adult needs to be home.",
        child.name, why, SS.Sim.ClockText(m.at))
    if SS.Economy and SS.Economy.Post then SS.Economy.Post(world, "note", text) end
    tell(world, child, text, "warning")
    journal(world, text)
    SS.Emit("schoolConcern", world, child, "meeting", why)
end

-- The meeting happened: each child's concern drops and a study plan starts.
function S.MeetingDone(world, adult, counselor)
    local st = care(world)
    local m = st.meeting
    if not m or m.state == "done" then return false end
    m.state, m.doneAt = "done", world.time
    local cs = D().counselor
    local names = {}
    for _, rid in ipairs(m.rids) do
        local child = world.root.residents[rid]
        if child and not child.dead then
            local s = S.Record(child)
            s.concern = math.max(0, s.concern - cs.relief)
            s.plan = { untilT = world.time + cs.planDays * 1440 }
            s.noteLevel = 0
            if s.concern < D().concern.meetingAt then s.referred = nil end
            names[#names + 1] = child.name
        end
    end
    local text = string.format("%s met the school counselor about %s. They agreed a study plan for the next %d days (homework counts for more).",
        adult and adult.name or "A parent", table.concat(names, " and "), cs.planDays)
    tell(world, adult, text, "school")
    journal(world, text)
    SS.Emit("schoolConcern", world, adult, "met", m.id)
    if counselor and SS.Visitors and SS.Visitors.Leave then SS.Visitors.Leave(world, counselor, "done")
    elseif counselor then SS.Sim.RemoveActor(world, counselor.id, { reason = "done" }) end
    return true
end

local function meetingMissed(world, counselor)
    local st = care(world)
    local m = st.meeting
    if not m or m.state == "done" or m.state == "missed" then return end
    m.state = "missed"
    m.tries = (m.tries or 0) + 1
    local cs = D().counselor
    local kids = {}
    for _, rid in ipairs(m.rids) do
        local child = world.root.residents[rid]
        if child and not child.dead then kids[#kids + 1] = child end
    end
    local text = "The school counselor waited, but no adult was available to meet. The school is more worried now."
    tell(world, nil, text, "warning")
    journal(world, text)
    if counselor then
        if SS.Visitors and SS.Visitors.Leave then SS.Visitors.Leave(world, counselor, "missed")
        else SS.Sim.RemoveActor(world, counselor.id, { reason = "missed" }) end
    end
    st.meeting = nil
    for _, child in ipairs(kids) do raiseConcern(world, child, cs.missed, "a missed meeting with the school") end
end
S.MeetingMissed = meetingMissed

---------------------------------------------------------------------------------------------------
-- The counselor (a visitor role) and the meeting interaction
---------------------------------------------------------------------------------------------------
local function counselorOnLot(world, id)
    for _, rid in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[rid]
        if a and a.role == "counselor" and a.roleData and a.roleData.meeting == id then return a end
    end
end

local function freeAdult(world)
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and C().IsMember(world, a) and not a.role and C().WorkingAge(a) and not C().IsSleeping(a) and not (a.act and a.act.manual) then return a end
    end
end

function S.CounselorTick(world, a, dt)
    local rd = a.roleData or {}
    a.roleData = rd
    local st = care(world)
    local m = st.meeting
    if not m or m.id ~= rd.meeting or m.state == "done" or m.state == "missed" then
        if SS.Visitors and SS.Visitors.Leave then SS.Visitors.Leave(world, a, "done") else SS.Sim.RemoveActor(world, a.id, { reason = "done" }) end
        return
    end
    if m.state == "scheduled" then m.state = "arrived"; m.arrivedAt = world.time end
    rd.since = rd.since or world.time
    local cs = D().counselor
    local waited = world.time - rd.since
    -- after a short wait, a free adult goes over to meet (the player can also order it at once)
    if m.state == "arrived" and waited >= 20 and not rd.sent then
        local adult = freeAdult(world)
        if adult then
            rd.sent = true
            SS.Actions.Order(world, adult, nil, "school_meet", nil, nil, { tid = a.id })
        end
    end
    if m.state == "arrived" and waited >= cs.waitMinutes then meetingMissed(world, a) end
end

-- Role definition for SS.Visitors.RegisterRole (visitors framework fields: arrive, class, timeout,
-- important, reconcile). After a load the counselor resumes; a meeting whose counselor is gone is re-planned.
S.COUNSELOR_ROLE = {
    label = "School Counselor", desc = "Visits to talk with a parent about a child's schooling.",
    noNeeds = true, useAutonomy = false, access = "guest", class = "service", arrive = "direct", outfit = "counselor_cardigan",
    timeout = D().counselor.waitMinutes + D().counselor.meetingMinutes + 30, important = true,
    reconcile = function(world, a) return "resume" end,
    onArrive = function(world, a)
        local text = "The school counselor has arrived for the meeting. Click the counselor with an adult selected to meet."
        tell(world, nil, text, "school")
        if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "info") end
    end,
    tick = function(world, a, dt) S.CounselorTick(world, a, dt) end,
}

SS.Interactions = SS.Interactions or {}
SS.Interactions.school_meet = {
    label = "Meet the Counselor", category = "Family", targetActor = true, pose = "talk", dur = D().counselor.meetingMinutes,
    manualOnly = true, ages = { adult = true, elder = true }, kinds = { human = true },
    test = function(world, actor, target)
        if not target or target.role ~= "counselor" then return false, "That is not the school counselor." end
        if not C().IsMember(world, actor) or not C().WorkingAge(actor) then return false, "The counselor wants to talk to a parent." end
        local m = care(world).meeting
        if not m or m.state ~= "arrived" and m.state ~= "meeting" then return false, "There is no meeting right now." end
        return true
    end,
    onStart = function(world, actor, act)
        local m = care(world).meeting
        if m then m.state = "meeting" end
    end,
    onEnd = function(world, actor, act, obj, status)
        local target = act.tid and world.actors[act.tid]
        local m = care(world).meeting
        if status == "done" then S.MeetingDone(world, actor, target)
        elseif m and m.state == "meeting" then m.state = "arrived" end
    end,
}

---------------------------------------------------------------------------------------------------
-- Homework
---------------------------------------------------------------------------------------------------
-- Is this definition a desk or table someone can write at?
function S.IsDesk(def)
    if not def then return false end
    if def.sub == "desk" then return true end
    if def.surfaces then
        for _, sf in ipairs(def.surfaces) do
            if sf.kind == "desk" or (sf.kind == "table" and (sf.z or 0.75) >= 0.6) then return true end
        end
    end
    if SS.Tags.Has(def, "table_dining") or SS.Tags.Has(def, "desk") then return true end
    return def.surface and def.cat == "surfaces" or false
end

-- Where the desks are, and which chairs face one: an index per lot, rebuilt only when the lot changes
-- (a new world runtime from SS.World.Rebuild, a new lot.version, another lot, or a "lotChanged" event),
-- so homework autonomy and the chair test never scan every object. Runtime only, never saved.
--   S.rt.desks = { lot, version, rt, dirty, at = { [level] = { [cellKey] = obj } }, ids = { [obj] = oid },
--                  seats = { { oid, obj }... } }
local CELL = 4096
local function deskIndex(world)
    local lot = world.lot
    local ix = S.rt.desks
    if ix and not ix.dirty and ix.lot == lot and ix.version == lot.version and ix.rt == SS.RT then return ix end
    ix = { lot = lot, version = lot.version, rt = SS.RT, at = {}, ids = {}, seats = {} }
    local ids = sortedKeys(lot.objects) -- (once per lot change)
    -- desks first: the lowest id wins a cell that two desk footprints share
    for n = #ids, 1, -1 do
        local o = lot.objects[ids[n]]
        local def = SS.Objects[o.def]
        if def and S.IsDesk(def) then
            local lv = o.level or 0
            local row = ix.at[lv]
            if not row then row = {}; ix.at[lv] = row end
            for _, c in ipairs(SS.Grid.footprint(def, o)) do row[c[1] * CELL + c[2]] = o end
            ix.ids[o] = ids[n]
        end
    end
    -- chairs that offer homework and face a desk (the candidates for homework autonomy)
    for _, oid in ipairs(ids) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and def.slots and def.slots.seat then
            local listed = false
            for _, iid in ipairs(def.actions or {}) do if iid == "school_homework" then listed = true; break end end
            if listed then
                local d = SS.Grid.DIRS[(o.f or 0) % 4]
                local row = ix.at[o.level or 0]
                local desk = row and row[(o.x + d[1]) * CELL + (o.y + d[2])]
                if desk and desk ~= o then ix.seats[#ix.seats + 1] = { oid = oid, obj = o } end
            end
        end
    end
    S.rt.desks = ix
    return ix
end
S.DeskIndex = deskIndex
-- (object state changes - lights, dirt, the mailbox flag - are most lotChanged events and move nothing)
SS.On("lotChanged", function(kind) if kind ~= "state" and S.rt.desks then S.rt.desks.dirty = true end end)

-- The desk or table in front of a chair, or nil (one lookup in the lot's desk index).
function S.DeskInFront(world, chair)
    local d = SS.Grid.DIRS[(chair.f or 0) % 4]
    local row = deskIndex(world).at[chair.level or 0]
    local ix = S.rt.desks
    local o = row and row[(chair.x + d[1]) * CELL + (chair.y + d[2])]
    if o and o ~= chair and world.lot.objects[ix.ids[o]] == o then return o end
    return nil
end

-- Homework due for the next school day (nil when none).
function S.Homework(child)
    local s = child.school
    local hw = s and s.homework
    if type(hw) ~= "table" then return nil end
    return hw
end

function S.HomeworkMinutes() return D().homework.minutes end

local function homeworkTest(world, actor, obj)
    if not C().IsMember(world, actor) then return false, "Only the household's children do homework here." end
    if not C().SchoolAge(actor) then return false, "Only school children have homework." end
    local hw = S.Homework(actor)
    if not hw then return false, "No homework today." end
    if hw.done then return false, "Homework is already done." end
    if obj and not S.DeskInFront(world, obj) then return false, "This chair needs to face a desk or table." end
    return true
end

SS.Interactions.school_homework = {
    label = "Do Homework", category = "School", slot = "seat", pose = "sit", carry = "book", maxDur = D().homework.minutes + 30,
    ages = { child = true, teen = true }, kinds = { human = true }, test = homeworkTest,
    rate = { fun = D().homework.fun },
    onTick = function(world, actor, act, obj, dt)
        local hw = S.Homework(actor)
        if not hw or hw.done then act.complete = true; return end
        hw.minutes = (hw.minutes or 0) + dt * (act.data and act.data.helped and 1.5 or 1)
        for sk, per in pairs(D().homework.skill) do SS.Skills.Gain(world, actor, sk, per * dt / 60) end
        if hw.minutes >= D().homework.minutes then
            act.complete = true
            S.FinishHomework(world, actor)
        end
    end,
}

function S.FinishHomework(world, child)
    local hw = S.Homework(child)
    if not hw or hw.done then return end
    hw.done, hw.doneAt = true, world.time
    tell(world, child, child.name .. " finished tonight's homework.", "school")
    say(world, child, "school_good", {})
    SS.Emit("homeworkDone", world, child)
end

-- An adult helps: the child's homework goes faster and they grow closer.
SS.Interactions.school_help = {
    label = "Help with Homework", category = "Family", targetActor = true, pose = "talk", dur = 20, manualOnly = true,
    ages = { adult = true, elder = true }, kinds = { human = true },
    test = function(world, actor, target)
        if not target or not C().SchoolAge(target) or not C().IsMember(world, target) then return false, "Only a school child in the household." end
        if not C().IsMember(world, actor) or not C().WorkingAge(actor) then return false, "A grown-up in the household can help." end
        local act = target.act
        if not (act and act.iid == "school_homework" and act.phase == "perform") then return false, target.name .. " is not doing homework right now." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        local child = act.tid and world.actors[act.tid]
        if status ~= "done" or not child then return end
        if S.HelpHomework(world, actor, child) and SS.Social and SS.Social.Change then
            SS.Social.Change(world, actor.id, child.id, 4, 1)
            SS.Social.Change(world, child.id, actor.id, 4, 1)
        end
    end,
}

-- A grown-up helps with homework (this interaction, or the social module's "help_homework" chat,
-- which calls this after a successful exchange): 20 minutes of the child's homework are done.
-- Relationship changes belong to the caller. Returns true when it helped, or false, why.
function S.HelpHomework(world, helper, child)
    if not helper or not child or not C().SchoolAge(child) then return false, "Only a school child can be helped with homework." end
    local hw = S.Homework(child)
    if not hw or hw.done then return false, child.name .. " has no homework to do." end
    hw.minutes = math.min(S.HomeworkMinutes(), (hw.minutes or 0) + 20)
    if child.act and child.act.iid == "school_homework" then child.act.data = child.act.data or {}; child.act.data.helped = true end
    tell(world, helper, helper.name .. " helped " .. child.name .. " with homework.", "school")
    if hw.minutes >= S.HomeworkMinutes() then S.FinishHomework(world, child) end
    return true
end

-- Homework is offered on every seat through the "seat" tag (SS.Tags, the sanctioned hook; the
-- catalogue module tags its chairs, sofas and benches "seat"). Other modules' definitions are never
-- edited directly.
function S.AttachHomework()
    SS.Tags.Attach("seat", "school_homework")
end
S.AttachHomework()

-- Autonomy: children with homework sit down to it in the late afternoon and evening.
local function homeworkCandidates(world, actor, cands)
    if not isHome(world) or not C().SchoolAge(actor) or not C().IsMember(world, actor) then return end
    local hw = S.Homework(actor)
    if not hw or hw.done then return end
    local hod = (world.time % 1440) / 60
    if hod < 15.5 or hod >= 21.5 then return end
    for _, need in ipairs({ "hunger", "energy", "bladder" }) do if (actor.needs[need] or 0) < -35 then return end end
    local neat = actor.personality and actor.personality.neat or 5
    local best, bestD
    -- (the lot's cached list of chairs that face a desk: no scan of every object, no allocation)
    local seats = deskIndex(world).seats
    for n = 1, #seats do
        local e = seats[n]
        local oid, o = e.oid, e.obj
        if world.lot.objects[oid] == o then
            local cool = actor.cool and actor.cool[oid .. ":school_homework"]
            if not (cool and cool > world.time) and SS.Actions.Available(world, actor, o, "school_homework") then
                local d = math.abs(o.x + 0.5 - actor.x) + math.abs(o.y + 0.5 - actor.y)
                if not bestD or d < bestD then best, bestD = oid, d end
            end
        end
    end
    if best then cands[#cands + 1] = { oid = best, iid = "school_homework", s = 14 + neat * 1.2 + (hod >= 19 and 8 or 0) } end
end
SS.Actions.RegisterCandidates(homeworkCandidates)

---------------------------------------------------------------------------------------------------
-- The school bus
---------------------------------------------------------------------------------------------------
local function bus(world)
    local hh = world.household
    if type(hh.schoolBus) ~= "table" then hh.schoolBus = {} end
    return hh.schoolBus
end

local function busTimes(day)
    local d = D()
    return day * 1440 + d.busAt, day * 1440 + d.busAt + d.busWait, day * 1440 + d.returnAt
end

local function unscheduleBus(world)
    SS.Sim.Unschedule(world, function(ev)
        return type(ev.kind) == "string" and ev.kind:sub(1, 7) == "school." and ev.kind ~= "school.counselor" and ev.lotId == world.lot.id
    end)
end

-- Plan the next school-day bus if the household has school-age children and none is planned.
function S.PlanBus(world, force)
    if not isHome(world) then return nil end
    local b = bus(world)
    if not force and b.state and b.state ~= "done" and b.state ~= "skipped" then return b end
    if #S.Children(world) == 0 then return nil end
    local d0 = math.floor(world.time / 1440)
    for d = d0, d0 + 7 do
        if S.IsSchoolDay(d) then
            local busAt, leaveAt, returnAt = busTimes(d)
            if busAt >= world.time then
                unscheduleBus(world)
                b.day, b.state, b.busAt, b.leaveAt, b.returnAt = d, "planned", busAt, leaveAt, returnAt
                local wake = busAt - D().wakeLead
                if wake > world.time then SS.Sim.Schedule(world, wake, "school.wake", { day = d }, world.lot.id) end
                SS.Sim.Schedule(world, busAt, "school.bus", { day = d }, world.lot.id)
                SS.Sim.Schedule(world, leaveAt, "school.leave", { day = d }, world.lot.id)
                return b
            end
        end
    end
end

-- Is this child on the way to the bus right now? (Used by careers' childcare check.)
function S.Leaving(rid) return S.rt.board[rid] ~= nil end

local function onWake(world, ev)
    local b = bus(world)
    if b.day ~= ev.data.day or b.state ~= "planned" then return end
    for _, child in ipairs(S.Children(world)) do
        local a = world.actors[child.id]
        if a then
            C().HoldAwake(world, a, b.leaveAt)
            if C().Wake(world, a, "school", "School today.") then tell(world, a, a.name .. " is up for school. The bus comes at " .. C().ClockText(D().busAt) .. ".", "school") end
            C().GetReady(world, a, b.leaveAt - SS.CareerData.rules.mealSlack)
        end
    end
end

local function onBus(world, ev)
    local b = bus(world)
    if b.day ~= ev.data.day or b.state ~= "planned" then return end
    if world.time > b.leaveAt then b.state = "skipped"; return S.PlanBus(world, true) end
    local kids = S.Children(world)
    if #kids == 0 then b.state = "skipped"; return end
    b.state = "waiting"
    SS.Economy.AddVehicle(world, "schoolbus", "school_bus")
    local names = {}
    for _, child in ipairs(kids) do
        local s = S.Record(child)
        s.trip = { day = b.day, state = "waiting" }
        if world.actors[child.id] then
            S.rt.board[child.id] = { attempts = 0, nextTry = world.time }
            C().HoldAwake(world, child, b.leaveAt)
        end
        names[#names + 1] = child.name
    end
    tell(world, nil, string.format("The school bus is here for %s. It leaves at %s.", table.concat(names, " and "), C().ClockText(D().busAt + D().busWait)), "school")
end

-- Board one child: homework and mood count toward the grade, then off to school.
function S.Board(world, child)
    local s = S.Record(child)
    local t = s.trip
    local b = bus(world)
    if not t or t.state ~= "waiting" then return false end
    local hwd = D().homework
    t.state, t.boardedAt = "away", world.time
    t.mood = math.floor(SS.Needs.Mood(child) + 0.5)
    t.returnAt = b.returnAt or (world.time + 8 * 60)
    local hw = s.homework
    if hw and hw.forDay == t.day then
        if hw.done then
            local pts = hwd.done
            if SS.Skills.Level(child, "logic") >= hwd.logicBonusAt then pts = pts + hwd.logicBonus end
            if s.plan and world.time < s.plan.untilT then pts = pts + hwd.planBonus end
            changeScore(child, pts)
            s.missingStreak = 0
            t.homework = "done"
        else
            changeScore(child, hwd.missing)
            s.missingStreak = (s.missingStreak or 0) + 1
            t.homework = "missing"
            if s.missingStreak >= D().concern.homeworkStreak then
                s.missingStreak = 0
                raiseConcern(world, child, D().concern.streakConcern, "homework missing three days running")
            end
        end
        s.homework = nil
    end
    changeScore(child, S.MoodPoints(t.mood))
    S.rt.board[child.id] = nil
    if t.homework == "missing" then tell(world, child, child.name .. " went to school without the homework.", "school") end
    SS.Emit("schoolDeparted", world, child, t)
    -- the bus stays until it leaves at its time; with visitors' street the child walks aboard it
    C().Depart(world, child, "school", t.returnAt, { day = t.day, vehicle = SS.Economy.VehicleFor(world, "schoolbus") })
    return true
end

local function absent(world, child, why)
    local s = S.Record(child)
    local t = s.trip
    if t then t.state, t.reason = "missed", why end
    S.rt.board[child.id] = nil
    changeScore(child, D().absence)
    s.absences[#s.absences + 1] = world.time
    while #s.absences > 10 do table.remove(s.absences, 1) end
    s.trips[#s.trips + 1] = t
    while #s.trips > 5 do table.remove(s.trips, 1) end
    s.trip = nil
    local a = world.actors[child.id]
    if a and a.act and a.act.iid == "goto" and a.act.data and a.act.data.ride == "schoolbus" then SS.Actions.Cancel(world, a, 0) end
    local text = string.format("%s missed the school bus (%s). The school has marked an absence.", child.name, why)
    tell(world, child, text, "warning")
    journal(world, text)
    SS.Emit("schoolAbsent", world, child, why)
    raiseConcern(world, child, D().concern.absence, "missed school")
end

local function onLeave(world, ev)
    local b = bus(world)
    if b.day ~= ev.data.day or b.state ~= "waiting" then return end
    for _, child in ipairs(S.Children(world)) do
        local s = S.Record(child)
        local t = s.trip
        if t and t.state == "waiting" and t.day == b.day then
            local a = world.actors[child.id]
            if a and C().AtCurb(world, a) then S.Board(world, a)
            elseif not a then absent(world, child, "was not home")
            else absent(world, child, S.rt.board[child.id] and S.rt.board[child.id].failed or "did not get to the curb in time") end
        end
    end
    b.state = "gone"
    SS.Economy.RemoveVehicle(world, "schoolbus")
    SS.Sim.Schedule(world, b.returnAt - 1, "school.dropoff", { day = b.day }, world.lot.id)
    SS.Sim.Schedule(world, b.returnAt + 2, "school.return", { day = b.day }, world.lot.id)
end

local function onDropoff(world, ev)
    local b = bus(world)
    if b.day ~= ev.data.day then return end
    SS.Economy.AddVehicle(world, "schoolbus", "school_bus")
    S.rt.busUntil = world.time + 5
end

-- A child is home from school: needs, mood effect already counted, homework for tomorrow.
function S.Settle(world, child)
    local s = S.Record(child)
    local t = s.trip
    if not t or t.state ~= "away" or t.paid then return false end
    t.paid = true
    t.state = "done"
    t.homeAt = world.time
    local hours = math.max(0, (math.min(world.time, t.returnAt or world.time) - (t.boardedAt or world.time)) / 60)
    local meal = C().ApplyAwayNeeds(child, D().needs, hours, D().needs.bladder, D().lunch)
    t.meal = meal > 0 and meal or nil
    s.trips[#s.trips + 1] = t
    while #s.trips > 5 do table.remove(s.trips, 1) end
    s.trip = nil
    -- a good day (attended, homework in) slowly eases the school's worry
    if t.homework ~= "missing" then
        s.goodDays = (s.goodDays or 0) + 1
        if s.goodDays >= D().concern.goodDaysDecay and s.concern > 0 then
            s.goodDays = 0
            s.concern = s.concern - 1
            if s.concern < D().concern.noteAt then s.noteLevel = 0 end
            if s.concern < D().concern.meetingAt then s.referred = nil end
        end
    end
    -- homework for the next school day
    local nd = math.floor(world.time / 1440) + 1
    while not S.IsSchoolDay(nd) do nd = nd + 1 end
    s.homework = { forDay = nd, minutes = 0, done = false, assignedAt = world.time }
    tell(world, child, string.format("%s is home from school (grade %s) with an hour of homework for %s.", child.name, s.letter, C().DAY_NAMES[nd % 7]), "school")
    SS.Emit("schoolHome", world, child, t)
    return true
end

SS.On("actorAdded", function(world, r)
    if not world or not r or type(r.school) ~= "table" then return end
    local t = r.school.trip
    if t and t.state == "away" and isHome(world) then S.Settle(world, r) end
end)

local function onReturn(world, ev)
    for _, child in ipairs(S.Children(world)) do
        local t = child.school and child.school.trip
        if t and t.state == "away" and t.day == ev.data.day then
            if not world.actors[child.id] then C().Arrive(world, child.id) end
            if t.state == "away" then S.Settle(world, child) end
        end
    end
    local b = bus(world)
    if b.day == ev.data.day then b.state = "done"; S.PlanBus(world) end
end

local boardIds = {}
local function tickBoarding(world)
    local r = SS.CareerData.rules
    -- (a reused, sorted id list: no table per tick)
    local n = 0
    for rid in pairs(S.rt.board) do n = n + 1; boardIds[n] = rid end
    for k = #boardIds, n + 1, -1 do boardIds[k] = nil end
    if n > 1 then table.sort(boardIds) end
    for k = 1, n do
        local rid = boardIds[k]
        local bd = S.rt.board[rid]
        local child = world.actors[rid]
        local t = child and child.school and child.school.trip
        if not bd then
            -- (removed earlier in this tick)
        elseif not t or t.state ~= "waiting" then
            S.rt.board[rid] = nil
        else
            local walking = child.act and child.act.iid == "goto" and child.act.data and child.act.data.ride == "schoolbus"
            if C().AtCurb(world, child) and not (child.act and not walking) then
                S.Board(world, child)
            elseif bd.attempts == 0 and C().WaitForMeal(world, child, bd, (bus(world).leaveAt or world.time) - r.mealSlack) then
                -- finishing breakfast first; the bus waits until it leaves
            elseif not C().OnTheWay(child, "schoolbus") and world.time >= (bd.nextTry or 0) and bd.attempts < r.maxSendAttempts then
                bd.attempts = bd.attempts + 1
                bd.nextTry = world.time + r.retryMinutes
                local ok, why = C().SendToCurb(world, child, "schoolbus")
                if not ok then bd.failed = why end
            end
        end
    end
end

SS.On("actionEnded", function(actor, act, status, reason)
    if not act or act.iid ~= "goto" or not act.data or act.data.ride ~= "schoolbus" then return end
    local bd = S.rt.board[actor.id]
    local world = SS.Sim.world
    if bd and status ~= "done" and world then
        bd.failed = "could not get to the curb (" .. tostring(reason or status) .. ")"
        bd.nextTry = world.time + SS.CareerData.rules.retryMinutes
    end
end)

---------------------------------------------------------------------------------------------------
-- Report cards (weekly)
---------------------------------------------------------------------------------------------------
function S.ReportCard(world, child)
    local s = S.Record(child)
    local day = math.floor(world.time / 1440)
    if s.lastReportDay == day then return nil end
    s.lastReportDay = day
    local letter = S.Letter(s.score)
    local eff = D().report.effects[letter]
    s.reports[#s.reports + 1] = { t = world.time, letter = letter, score = math.floor(s.score + 0.5) }
    while #s.reports > 6 do table.remove(s.reports, 1) end
    if eff.money and eff.money > 0 then SS.Money(world, eff.money, "gifts", string.format("School book token (%s, grade %s)", child.name, letter)) end
    if eff.fun then SS.Needs.Add(child, "fun", eff.fun) end
    if eff.social then SS.Needs.Add(child, "social", eff.social) end
    if eff.rel and eff.rel ~= 0 and SS.Social and SS.Social.Change then
        for _, p in ipairs(S.Parents(world, child)) do
            SS.Social.Change(world, p.id, child.id, eff.rel, math.ceil(eff.rel / 2))
            SS.Social.Change(world, child.id, p.id, eff.rel, math.ceil(eff.rel / 2))
        end
    end
    local text = string.format("Report card for %s: %s. %s", child.name, letter, eff.text)
    tell(world, child, text, "school")
    if letter == "A" or letter == "B" then say(world, child, "school_good", { grade = letter })
    elseif letter == "D" or letter == "F" then say(world, child, "school_bad", { grade = letter }) end
    journal(world, string.format("%s's report card: %s.", child.name, letter))
    local rec = SS.Events and SS.Events.Record and SS.Events.Record(world, "report_card", { rid = child.id, letter = letter })
    if rec and SS.Events.Resolve then SS.Events.Resolve(world, rec.id, letter) end
    SS.Emit("reportCard", world, child, letter, s.score, eff)
    if eff.concern and eff.concern > 0 then raiseConcern(world, child, eff.concern, "a " .. letter .. " on the report card") end
    return letter
end

---------------------------------------------------------------------------------------------------
-- Home alone (school-age children; infants and toddlers are the family module's)
---------------------------------------------------------------------------------------------------
local function isNight(world)
    local hod = (world.time % 1440) / 60
    local al = D().alone
    return hod >= al.nightFrom or hod < al.nightTo
end

local ALONE_EVERY = 5 -- sim minutes between home-alone checks (no per-frame member lists)
local function tickAlone(world)
    local nextAt = S.rt.aloneNext
    if nextAt and world.time < nextAt and world.time >= nextAt - ALONE_EVERY then return end
    S.rt.aloneNext = world.time + ALONE_EVERY
    local adult = adultPresent(world)
    for _, child in ipairs(S.Children(world)) do
        local s = child.school
        if world.actors[child.id] and not adult then
            s = S.Record(child)
            s.aloneSince = s.aloneSince or world.time
            local limit = isNight(world) and D().alone.nightMinutes or D().alone.dayMinutes
            if not s.aloneFlagged and world.time - s.aloneSince >= limit then
                s.aloneFlagged = true
                local text = string.format("%s has been home alone for %d hours%s. Children need an adult around.", child.name,
                    math.floor((world.time - s.aloneSince) / 60), isNight(world) and " at night" or "")
                tell(world, child, text, "warning")
                journal(world, text)
                if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "warning") end
                raiseConcern(world, child, D().concern.alone, "left home alone")
            end
        elseif s and (s.aloneSince or s.aloneFlagged) then
            s.aloneSince, s.aloneFlagged = nil, nil
        end
    end
end
S.TickAlone = tickAlone

---------------------------------------------------------------------------------------------------
-- System
---------------------------------------------------------------------------------------------------
local roleDone = false
function S.RegisterLate()
    S.AttachHomework()
    if roleDone then return end
    if SS.Visitors and SS.Visitors.RegisterRole then
        SS.Visitors.RegisterRole("counselor", S.COUNSELOR_ROLE)
        roleDone = true
    else
        SS.Roles.counselor = S.COUNSELOR_ROLE
    end
end

local function onCounselor(world, ev)
    local st = care(world)
    local m = st.meeting
    if not m or m.id ~= ev.data.id or m.state ~= "scheduled" then return end
    if world.time > m.at + D().counselor.waitMinutes then return meetingMissed(world, nil) end
    if counselorOnLot(world, m.id) then return end
    local a
    if SS.Visitors and SS.Visitors.Spawn then a = SS.Visitors.Spawn(world, nil, "counselor", { meeting = m.id }) end
    if not a then
        -- nobody could come (the school's side, not the household's): the visit moves to the next school
        -- day, a bounded number of times, and the household is told each time
        m.tries = (m.tries or 0) + 1
        local names = {}
        for _, rid in ipairs(m.rids) do
            local child = world.root.residents[rid]
            if child and not child.dead then names[#names + 1] = child.name end
        end
        local who = #names > 0 and table.concat(names, " and ") or "the children"
        if m.tries > D().counselor.maxTries then
            -- the school writes instead; the concern stays as it is (it was not the household's doing),
            -- and the next worry asks for a meeting again (or refers, at the referral line)
            m.state, m.doneAt = "cancelled", world.time
            st.meeting, st.lastMeeting = nil, m
            local text = string.format("The school could not send a counselor about %s. They wrote instead: \"Please keep homework and the bus on track. We will ask to meet again if we are still worried.\"", who)
            if SS.Economy and SS.Economy.Post then SS.Economy.Post(world, "note", text) end
            tell(world, nil, text, "school")
            journal(world, text)
            SS.Emit("schoolConcern", world, nil, "meetingCancelled", m.id)
            return
        end
        m.at = nextVisitTime(world, 12 * 60)
        SS.Sim.Schedule(world, m.at, "school.counselor", { id = m.id }, world.lot.id)
        local text = string.format("The school counselor could not come today about %s. The visit moves to %s; an adult needs to be home.", who, SS.Sim.ClockText(m.at))
        tell(world, nil, text, "school")
        journal(world, text)
    else
        m.state = "arrived"
        m.arrivedAt = world.time
    end
end

local function attach(world)
    S.RegisterLate()
    S.rt.board, S.rt.busUntil = {}, nil
    if not isHome(world) then return end
    local gap = SS.Economy.Gap(world)
    local b = bus(world)
    if gap > 0 and b.state and (b.state == "planned" or b.state == "waiting") and (b.busAt or 0) < world.time then
        b.state = "skipped"
        for _, child in ipairs(S.Children(world)) do
            local t = child.school and child.school.trip
            if t and t.state == "waiting" then t.state = "skipped"; child.school.trip = nil end
        end
    end
    if gap > 0 then
        for _, child in ipairs(S.Children(world)) do
            local s = child.school
            if s and s.aloneSince then s.aloneSince = s.aloneSince + gap end
        end
        local m = care(world).meeting
        if m and m.state == "scheduled" and m.at < world.time then
            SS.Sim.Unschedule(world, function(ev) return ev.kind == "school.counselor" and ev.data and ev.data.id == m.id end)
            m.at = nextVisitTime(world, 12 * 60)
            SS.Sim.Schedule(world, m.at, "school.counselor", { id = m.id }, world.lot.id)
        end
    end
    if b.state == "waiting" then
        -- saved while the bus was at the curb
        SS.Economy.AddVehicle(world, "schoolbus", "school_bus", { parked = true })
        for _, child in ipairs(S.Children(world)) do
            local t = child.school and child.school.trip
            if t and t.state == "waiting" and world.actors[child.id] then S.rt.board[child.id] = { attempts = 0, nextTry = world.time } end
        end
        local has = false
        for _, ev in ipairs(world.scheduled) do if ev.kind == "school.leave" and ev.data and ev.data.day == b.day then has = true end end
        if not has then SS.Sim.Schedule(world, math.max(world.time, b.leaveAt or world.time), "school.leave", { day = b.day }, world.lot.id) end
    elseif b.state == "gone" then
        local has = false
        for _, ev in ipairs(world.scheduled) do if ev.kind == "school.return" and ev.data and ev.data.day == b.day then has = true end end
        if not has then SS.Sim.Schedule(world, math.max(world.time, (b.returnAt or world.time) + 2), "school.return", { day = b.day }, world.lot.id) end
    elseif b.state == "planned" then
        local has = false
        for _, ev in ipairs(world.scheduled) do if ev.kind == "school.bus" and ev.data and ev.data.day == b.day then has = true end end
        if not has then S.PlanBus(world, true) end
    else
        S.PlanBus(world)
    end
    -- a counselor on the lot after a load keeps going; a meeting marked arrived without one gets a new visit
    local m = care(world).meeting
    if m and (m.state == "arrived" or m.state == "meeting") and not counselorOnLot(world, m.id) then
        m.state = "scheduled"
        m.at = nextVisitTime(world, 60)
        SS.Sim.Schedule(world, m.at, "school.counselor", { id = m.id }, world.lot.id)
    end
end

local function tick(world, dt)
    if not isHome(world) then return end
    if next(S.rt.board) then tickBoarding(world) end
    if S.rt.busUntil and (world.time >= S.rt.busUntil or world.time < S.rt.busUntil - 10) then
        S.rt.busUntil = nil
        SS.Economy.RemoveVehicle(world, "schoolbus")
    end
    tickAlone(world)
end

local function hour(world, h)
    if not isHome(world) then return end
    local rep = D().report
    local day = math.floor(h / 24)
    if h % 24 == rep.hour and day % 7 == rep.weekday then
        for _, child in ipairs(S.Children(world)) do S.ReportCard(world, child) end
    end
    local b = bus(world)
    if not b.state or b.state == "done" or b.state == "skipped" then S.PlanBus(world) end
    -- a counselor who left before the meeting ended (a framework timeout, a forced leave) comes again
    local m = care(world).meeting
    if m and (m.state == "arrived" or m.state == "meeting") and not counselorOnLot(world, m.id) then
        m.state = "scheduled"
        m.at = nextVisitTime(world, 60)
        SS.Sim.Schedule(world, m.at, "school.counselor", { id = m.id }, world.lot.id)
    end
end

-- A child who dies no longer goes to school (the events module's death transition owns the rest).
SS.On("death", function(world, child, cause)
    if not world or not child then return end
    local r = world.root and world.root.residents[child.id] or child
    S.rt.board[child.id] = nil
    if r.school then r.school.trip, r.school.homework, r.school.aloneSince = nil, nil, nil end
end)

SS.Sim.Register({ name = "school", order = 43, attach = attach, tick = tick, hour = hour })

SS.On("scheduled", function(ev, world)
    if not world or type(ev.kind) ~= "string" or ev.kind:sub(1, 7) ~= "school." or not ev.data then return end
    if not isHome(world) then return end
    local k = ev.kind
    if k == "school.wake" then onWake(world, ev)
    elseif k == "school.bus" then onBus(world, ev)
    elseif k == "school.leave" then onLeave(world, ev)
    elseif k == "school.dropoff" then onDropoff(world, ev)
    elseif k == "school.return" then onReturn(world, ev)
    elseif k == "school.counselor" then onCounselor(world, ev) end
end)

---------------------------------------------------------------------------------------------------
-- Save validation
---------------------------------------------------------------------------------------------------
if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        for id, r in pairs(root.residents or {}) do
            if type(r) == "table" and r.school ~= nil then
                if type(r.school) ~= "table" then
                    r.school = nil
                    problems[#problems + 1] = "reset school record for " .. tostring(id)
                else
                    local s = r.school
                    s.score = clamp(tonumber(s.score) or D().gradeStart, 0, 100)
                    s.concern = clamp(tonumber(s.concern) or 0, 0, 20)
                    s.absences = type(s.absences) == "table" and s.absences or {}
                    s.trips = type(s.trips) == "table" and s.trips or {}
                    s.reports = type(s.reports) == "table" and s.reports or {}
                    if s.homework ~= nil and type(s.homework) ~= "table" then s.homework = nil end
                    if s.trip ~= nil and type(s.trip) ~= "table" then s.trip = nil end
                end
            end
        end
    end)
end
