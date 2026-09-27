-- Careers: job search, the carpool commute, shifts and pay, performance, promotions, demotions,
-- dismissal, vacation days and career chance events.
-- Owner: careers module (docs/modules/careers.md). Data: SS.CareerData (Data/Careers.lua).
--
-- Saved data (plain tables on the resident, root.residents[rid]):
--   career = { track, level, perf (-100..100), hired, shiftsAtLevel, daysWorked, earned, warnings,
--              misses = { t... }, lates = { t... }, streak, vacation, dayOff, nextId, coworker = { name, rel },
--              shift = shiftRecord | nil, history = { shiftRecord... } (last 8), pending = chance | nil,
--              lastChance, recent = { chanceId... }, readyMsgAt, perfWarned }
--   shiftRecord = { id, level, title, start, finish, pickupAt, state = "planned"|"waiting"|"away"|"done"|
--              "missed"|"off"|"skipped", boardedAt, late, mood, pay, paid, paidAt, returnAt, perfDelta, reason, chance,
--              meal (hunger from the meal break, when the day was long enough),
--              minding (while the worker is held home to mind an infant or toddler: the reason), mindCheck (the
--              next time that is checked again), mindFreed and mindWhy (when someone came to take over, and
--              the reason the worker had been held) }
--   careerPast = { { track, level, title, reason, t }... } (last 5)
-- Scheduled events (bound to the home lot): "career.wake", "career.pickup", "career.leave", "career.chance",
--   "career.return", all with data { rid, shift = shiftId }.
-- Pay is credited exactly once, when the worker comes home (actorAdded) or, as a fallback, at the
-- "career.return" event. shift.paid is set in the same call that credits the money, so no save, reload
-- or speed can split or repeat it.
-- Events emitted: "careerHired", "careerDeparted", "careerShiftDone", "careerMissed", "careerPromoted",
--   "careerDemoted", "careerEnded", "careerChance", "careerChanceResolved", "careerOffers" (see the module doc).
local _, SS = ...
local C = SS.Career or {}
SS.Career = C
local U = SS.U

local function D() return SS.CareerData end
local function R() return SS.CareerData.rules end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function fmt(v) return U.fmtMoney(v) end

-- Runtime only (rebuilt on attach): board[rid] = { shift, attempts, nextTry, walking, blocked, told }.
-- blocked mirrors the saved shift.minding (a childcare hold), so a reload rebuilds it exactly.
C.rt = C.rt or { board = {} }

---------------------------------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------------------------------
local DAY_NAMES = { [0] = "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
C.DAY_NAMES = DAY_NAMES

function C.ClockText(minuteOfDay)
    local m = math.floor(minuteOfDay % 1440 + 0.5) % 1440
    local h, mm = math.floor(m / 60), m % 60
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    if mm == 0 then return string.format("%d %s", h12, h < 12 and "AM" or "PM") end
    return string.format("%d:%02d %s", h12, mm, h < 12 and "AM" or "PM")
end

-- "Mon-Fri", "Wed-Sun", "Mon, Wed, Sat". Consecutive runs (wrapping past Sunday) are joined.
function C.DaysText(days)
    local on = {}
    for _, d in ipairs(days or {}) do on[d % 7] = true end
    local n = 0
    for d = 0, 6 do if on[d] then n = n + 1 end end
    if n == 7 then return "Every day" end
    if n == 0 then return "No days" end
    -- start of a run: a working day whose previous day is off
    local runs = {}
    for d = 0, 6 do
        if on[d] and not on[(d + 6) % 7] then
            local e = d
            while on[(e + 1) % 7] and (e + 1) % 7 ~= d do e = (e + 1) % 7 end
            runs[#runs + 1] = { d, e }
        end
    end
    table.sort(runs, function(a, b) return a[1] < b[1] end)
    local parts = {}
    for _, r in ipairs(runs) do
        local len = (r[2] - r[1]) % 7 + 1
        if len >= 3 then parts[#parts + 1] = DAY_NAMES[r[1]] .. "-" .. DAY_NAMES[r[2]]
        elseif len == 2 then parts[#parts + 1] = DAY_NAMES[r[1]] .. ", " .. DAY_NAMES[r[2]]
        else parts[#parts + 1] = DAY_NAMES[r[1]] end
    end
    return table.concat(parts, ", ")
end

function C.HoursText(lv)
    local night = lv.finish <= lv.start
    return C.ClockText(lv.start * 60) .. " - " .. C.ClockText(lv.finish * 60) .. (night and " (overnight)" or "")
end

function C.ShiftText(lv) return C.DaysText(lv.days) .. ", " .. C.HoursText(lv) end

function C.Track(id) return D().tracks[id] end
-- The wage per shift for a level in this save (the listed pay with the money pressure applied).
function C.Pay(world, lv)
    if not lv then return 0 end
    if world and SS.Economy and SS.Economy.WageFor then return SS.Economy.WageFor(world, lv.pay) end
    return lv.pay
end
function C.LevelDef(track, level)
    local t = D().tracks[track]
    return t and t.levels[level]
end
function C.Current(actor)
    local c = actor and actor.career
    if not c then return nil end
    return C.LevelDef(c.track, c.level), c
end
function C.Title(actor)
    local lv = C.Current(actor)
    return lv and lv.title or nil
end

local function isHuman(actor) return actor.kind == nil or actor.kind == "human" end
-- Work clothes, per the person contract: actor.outfit = "work" and the style in look.outfits.work
-- (colours the player chose are kept; only the style follows the job level).
function C.DressForWork(actor, lv)
    if not lv then return end
    actor.look = type(actor.look) == "table" and actor.look or {}
    local o = actor.look.outfits
    if type(o) ~= "table" then o = {}; actor.look.outfits = o end
    local wk = o.work
    if type(wk) ~= "table" then
        local l = actor.look
        wk = { top = l.top, bottom = l.bottom, shoes = l.shoes }
        o.work = wk
    end
    wk.style = lv.outfit
    actor.outfit = "work"
end

function C.Undress(actor)
    if actor.outfit == "work" then actor.outfit = "everyday" end
end

-- A household member on this lot. Some roles are worn by residents themselves: with the visitors module
-- a resident walking in from the curb or out to a vehicle is "arriving" or "departing", and the family
-- module gives babies and pets the roles "infant" and "pet". Such household roles keep them members:
-- visitors' V.Resident(role) when it exists, else a role declared with resident = true or access
-- "household" (visitors' registry or SS.Roles). A visitor role (a guest, the collector) does not.
local TRANSIT = { arriving = true, departing = true, infant = true, pet = true }
local function declaredResident(reg, role)
    local def = type(reg) == "table" and reg[role]
    return type(def) == "table" and (def.resident == true or def.access == "household")
end
local function householdRole(role)
    if TRANSIT[role] then return true end
    local V = SS.Visitors
    if V and type(V.Resident) == "function" and V.Resident(role) then return true end
    return declaredResident(V and V.roles, role) or declaredResident(SS.Roles, role)
end
C.HouseholdRole = householdRole
function C.IsMember(world, actor)
    return world.household ~= nil and actor.householdId == world.household.id and (not actor.role or householdRole(actor.role))
end
-- On the way out to a vehicle (visitors' departure walk): no longer minding anyone at home.
function C.Leaving(actor) return actor.role == "departing" end
-- Working age: adults and elders (the family module owns ages).
function C.WorkingAge(actor) return isHuman(actor) and (actor.age == "adult" or actor.age == "elder") and not actor.dead end
function C.SchoolAge(actor) return isHuman(actor) and (actor.age == "child" or actor.age == "teen") and not actor.dead end
function C.NeedsMinding(actor) return isHuman(actor) and (actor.age == "infant" or actor.age == "toddler") and not actor.dead end

local function isHome(world) return not C.suspended and SS.Economy and SS.Economy.IsHome(world) end
-- Test hook for other modules whose tests simulate work themselves: SS.Career.Suspend(true) makes
-- shifts inert (no pickups, departures or pay) until Suspend(false). Runtime only, never saved.
function C.Suspend(on) C.suspended = on and true or nil end

local function journal(world, text)
    if SS.Actions and SS.Actions.Journal and world.journal then SS.Actions.Journal(world, text) end
end

-- A message about a person: on their balloon when they are here, else a household notice.
local function tell(world, actor, text, icon)
    if actor and world.actors[actor.id] and SS.Actions and SS.Actions.Message then
        SS.Actions.Message(world, actor, text, icon or "career")
    elseif SS.Economy and SS.Economy.HouseholdMessage then
        SS.Economy.HouseholdMessage(world, text, icon or "career")
    end
    SS.Emit("careerNotice", world, actor, text)
end
C.Tell = tell

local function say(world, actor, situation, ctx)
    if actor and world.actors[actor.id] and SS.Actions then
        if SS.Actions.Say then
            local ok, text = pcall(SS.Actions.Say, world, actor, situation, ctx or {})
            return ok and text or nil
        end
        if SS.Lines and SS.Lines.Say then
            local ok, text = pcall(SS.Lines.Say, world, actor, situation, ctx or {})
            if ok and text then SS.Actions.Message(world, actor, text, "bubble") end
            return ok and text or nil
        end
    end
end
C.Say = say

local function sortedKeys(t)
    local ids = {}
    for k in pairs(t) do ids[#ids + 1] = k end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    return ids
end

-- Household members (records), sorted by id.
function C.Members(world)
    local out = {}
    local hh = world.household
    if not hh then return out end
    local ids = {}
    for _, rid in ipairs(hh.members or {}) do ids[#ids + 1] = rid end
    table.sort(ids)
    for _, rid in ipairs(ids) do
        local r = world.root.residents[rid]
        if r and not r.dead then out[#out + 1] = r end
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Schedules
---------------------------------------------------------------------------------------------------
function C.WorksOn(lv, weekday)
    for _, d in ipairs(lv.days) do if d % 7 == weekday % 7 then return true end end
    return false
end

-- Absolute start and finish of the shift that starts on absolute day `day`.
function C.ShiftTimes(lv, day)
    local start = day * 1440 + lv.start * 60
    local hours = (lv.finish - lv.start) % 24
    if hours == 0 then hours = 24 end
    return start, start + hours * 60
end

-- The next shift whose carpool pickup is not before `from`. Returns start, finish.
function C.NextShiftTimes(lv, from)
    local lead = R().pickupLead
    local d0 = math.floor(from / 1440)
    for d = d0, d0 + 14 do
        if C.WorksOn(lv, d % 7) then
            local s, f = C.ShiftTimes(lv, d)
            if s - lead >= from - 1e-6 then return s, f end
        end
    end
end

local function eventsFor(world, rid, prefix)
    return function(ev)
        return type(ev.kind) == "string" and ev.kind:sub(1, #prefix) == prefix and ev.data and ev.data.rid == rid
    end
end

local function unschedule(world, rid)
    SS.Sim.Unschedule(world, eventsFor(world, rid, "career."))
end

local function schedule(world, at, kind, rid, shiftId, extra)
    local data = { rid = rid, shift = shiftId }
    if extra then for k, v in pairs(extra) do data[k] = v end end
    return SS.Sim.Schedule(world, at, kind, data, world.lot.id)
end

local function archive(c, sh)
    if sh.start and (not c.lastStart or sh.start > c.lastStart) then c.lastStart = sh.start end
    c.history = c.history or {}
    c.history[#c.history + 1] = sh
    while #c.history > 8 do table.remove(c.history, 1) end
    if c.shift == sh then c.shift = nil end
end

-- Plan the next shift (and its wake/pickup/leave events). Keeps a shift that is under way.
function C.Plan(world, actor, from)
    local c = actor.career
    if not c or not isHome(world) then return nil end
    if c.shift and (c.shift.state == "waiting" or c.shift.state == "away") then return c.shift end
    unschedule(world, actor.id)
    c.shift = nil
    local lv = C.LevelDef(c.track, c.level)
    if not lv then return nil end
    from = from or world.time
    -- never plan a shift that has already been settled (a day off taken at pickup time)
    if c.lastStart and from <= c.lastStart then from = c.lastStart + 1 end
    local start, finish = C.NextShiftTimes(lv, from)
    if not start then return nil end
    c.nextId = (c.nextId or 0) + 1
    local r = R()
    local sh = { id = c.nextId, level = c.level, title = lv.title, start = start, finish = finish,
        pickupAt = start - r.pickupLead, state = "planned" }
    c.shift = sh
    if sh.pickupAt - r.wakeLead > world.time then schedule(world, sh.pickupAt - r.wakeLead, "career.wake", actor.id, sh.id) end
    schedule(world, sh.pickupAt, "career.pickup", actor.id, sh.id)
    schedule(world, sh.start, "career.leave", actor.id, sh.id)
    return sh
end

function C.HasEvents(world, rid, shiftId)
    for _, ev in ipairs(world.scheduled) do
        if ev.data and ev.data.rid == rid and ev.data.shift == shiftId and type(ev.kind) == "string" and ev.kind:sub(1, 7) == "career." then
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------------------------------
-- Friends and requirements
---------------------------------------------------------------------------------------------------
-- Friends: the social module's count when it provides one (SS.Social.CountFriends: people this
-- person counts as a friend), else long-term relationships at or above rules.friendLife. A close coworker (from chance events) counts as one more.
function C.FriendCount(world, actor)
    local n = 0
    local So = SS.Social
    if So and So.CountFriends then
        n = So.CountFriends(world, actor.id) or 0
    elseif So and So.FriendCount then
        n = So.FriendCount(world, actor.id) or 0
    else
        local rel = world.root.social and world.root.social.rel
        local prefix = actor.id .. ">"
        local lim = R().friendLife
        for key, r in pairs(rel or {}) do
            if type(key) == "string" and key:sub(1, #prefix) == prefix and type(r) == "table" and (r.life or 0) >= lim then
                local other = world.root.residents[key:sub(#prefix + 1)]
                if other and not other.dead then n = n + 1 end
            end
        end
    end
    local c = actor.career
    if c and c.coworker and (c.coworker.rel or 0) >= R().friendLife then n = n + 1 end
    return n
end

-- Requirements of a level for this person: ok, list of { kind = "skill"|"friends", key, have, need }.
function C.Requirements(world, actor, track, level)
    local lv = C.LevelDef(track, level)
    local rows, ok = {}, true
    if not lv then return false, rows end
    for _, sk in ipairs(SS.Skills.LIST) do
        local need = lv.skills[sk]
        if need and need > 0 then
            local have = SS.Skills.Level(actor, sk)
            rows[#rows + 1] = { kind = "skill", key = sk, label = SS.Skills.Label(sk), have = have, need = need, met = have >= need }
            if have < need then ok = false end
        end
    end
    if (lv.friends or 0) > 0 then
        local have = C.FriendCount(world, actor)
        rows[#rows + 1] = { kind = "friends", key = "friends", label = "Friends", have = have, need = lv.friends, met = have >= lv.friends }
        if have < lv.friends then ok = false end
    end
    return ok, rows
end

-- What stands between this worker and the next level: ok, rows (requirements plus performance and
-- shifts at this level).
function C.PromotionStatus(world, actor)
    local c = actor.career
    if not c then return false, {} end
    if c.level >= #D().tracks[c.track].levels then return false, {}, "top" end
    local ok, rows = C.Requirements(world, actor, c.track, c.level + 1)
    local r = R()
    rows[#rows + 1] = { kind = "perf", key = "perf", label = "Performance", have = math.floor(c.perf + 0.5), need = r.promoteAt, met = c.perf >= r.promoteAt }
    rows[#rows + 1] = { kind = "shifts", key = "shifts", label = "Shifts at this level", have = c.shiftsAtLevel or 0, need = r.minShiftsAtLevel,
        met = (c.shiftsAtLevel or 0) >= r.minShiftsAtLevel }
    for _, row in ipairs(rows) do if not row.met then ok = false end end
    return ok, rows
end

local function missingText(rows)
    local parts = {}
    for _, row in ipairs(rows) do
        if not row.met and (row.kind == "skill" or row.kind == "friends") then
            parts[#parts + 1] = string.format("%s %d (has %d)", row.label, row.need, row.have)
        end
    end
    return table.concat(parts, ", ")
end
C.MissingText = missingText

-- Can this person take this job now? ok, why.
function C.CanTake(world, actor, track, level)
    if not actor or not C.LevelDef(track, level) then return false, "That job does not exist." end
    if not C.IsMember(world, actor) then return false, "Only household members can take a job." end
    if C.SchoolAge(actor) then return false, actor.name .. " goes to school; jobs are for grown-ups." end
    if not C.WorkingAge(actor) then return false, actor.name .. " is too young to work." end
    local c = actor.career
    if c and c.shift and (c.shift.state == "away" or c.shift.state == "waiting") then
        return false, actor.name .. " is on the way to work or at work. Change jobs once they are home."
    end
    if c and c.track == track and c.level == level then return false, actor.name .. " already has this job." end
    local ok, rows = C.Requirements(world, actor, track, level)
    if not ok then return false, "Needs " .. missingText(rows) .. "." end
    return true
end

---------------------------------------------------------------------------------------------------
-- Hiring, quitting, dismissal
---------------------------------------------------------------------------------------------------
local function leaveJob(world, actor, reason, text)
    local c = actor.career
    if not c then return end
    local lv = C.LevelDef(c.track, c.level)
    unschedule(world, actor.id)
    SS.Economy.RemoveVehicle(world, "carpool:" .. actor.id, true)
    C.rt.board[actor.id] = nil
    actor.careerPast = actor.careerPast or {}
    table.insert(actor.careerPast, { track = c.track, level = c.level, title = lv and lv.title, reason = reason, t = world.time,
        daysWorked = c.daysWorked, earned = c.earned })
    while #actor.careerPast > 5 do table.remove(actor.careerPast, 1) end
    if c.pending and c.pending.eventId and SS.Events and SS.Events.Resolve then SS.Events.Resolve(world, c.pending.eventId, "left job") end
    actor.career = nil
    C.Undress(actor)
    if text then tell(world, actor, text, "career"); journal(world, text) end
    SS.Emit("careerEnded", world, actor, reason)
end

function C.Hire(world, actor, track, level, source)
    local lv = C.LevelDef(track, level)
    if not lv then return false, string.format("There is no level %s job in the %s career.", tostring(level), tostring(track)) end
    if not C.WorkingAge(actor) then return false, (actor.name or "They") .. " is too young for a job." end
    if actor.career then leaveJob(world, actor, "changed", nil) end
    actor.career = {
        track = track, level = level, perf = 0, hired = world.time, shiftsAtLevel = 0, daysWorked = 0, earned = 0,
        warnings = 0, misses = {}, lates = {}, streak = 0, vacation = 0, nextId = 0, history = {}, recent = {},
        coworker = { name = SS.Pick(world, "career.coworker", D().coworkerNames) or "A colleague", rel = 0 },
        source = source,
    }
    local sh = C.Plan(world, actor, world.time + R().firstShiftDelay)
    local text = string.format("%s is now a %s (%s): %s per shift, %s.", actor.name, lv.title, D().tracks[track].name, fmt(C.Pay(world, lv)), C.ShiftText(lv))
    if sh then text = text .. " First shift: " .. SS.Sim.ClockText(sh.start) .. "." end
    tell(world, actor, text, "career_" .. track)
    journal(world, string.format("%s started work as a %s.", actor.name, lv.title))
    if SS.Audio and SS.Audio.Cue then SS.Audio.Cue("career") end
    say(world, actor, "career_hired", { job = lv.title, amount = C.Pay(world, lv) })
    SS.Emit("careerHired", world, actor, track, level)
    return true, text
end

-- Accept a job offer (newspaper, computer or phone). Returns ok, message.
function C.Accept(world, actor, track, level, source)
    local ok, why = C.CanTake(world, actor, track, level)
    if not ok then return false, why end
    return C.Hire(world, actor, track, level, source)
end

function C.Quit(world, actor)
    local c = actor and actor.career
    if not c then return false, "They do not have a job." end
    if c.shift and (c.shift.state == "away" or c.shift.state == "waiting") then
        return false, actor.name .. " can quit once they are home from this shift."
    end
    local lv = C.LevelDef(c.track, c.level)
    leaveJob(world, actor, "quit", string.format("%s quit their job as a %s.", actor.name, lv and lv.title or "worker"))
    return true
end

-- A worker who dies leaves the job quietly: no more shifts, no carpool, the record kept in careerPast.
-- (The events module's death transition also unschedules; doing it here too is harmless.)
SS.On("death", function(world, actor, cause)
    if not world or not actor then return end
    local r = world.root and world.root.residents[actor.id] or actor
    if r.career then leaveJob(world, r, "died", nil) end
end)

local function dismiss(world, actor, why)
    local lv = C.Current(actor)
    local text = string.format("%s was let go from the job as a %s: %s", actor.name, lv and lv.title or "worker", why)
    say(world, actor, "work_fired", { job = lv and lv.title })
    leaveJob(world, actor, "fired", text)
    if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "info") end
end
C.Dismiss = dismiss

local function promote(world, actor)
    local c = actor.career
    local r = R()
    c.level = c.level + 1
    c.perf = r.perf.promotedTo
    c.shiftsAtLevel = 0
    c.perfWarned = nil
    local lv = C.LevelDef(c.track, c.level)
    local text = string.format("Promotion! %s is now a %s: %s per shift, %s.", actor.name, lv.title, fmt(C.Pay(world, lv)), C.ShiftText(lv))
    tell(world, actor, text, "career_" .. c.track)
    journal(world, string.format("%s was promoted to %s.", actor.name, lv.title))
    if SS.Audio and SS.Audio.Cue then SS.Audio.Cue("promotion") end
    say(world, actor, "work_promoted", { job = lv.title, amount = C.Pay(world, lv), level = c.level })
    SS.Emit("careerPromoted", world, actor, c.level)
end
C.Promote = promote

local function demote(world, actor, why)
    local c = actor.career
    local r = R()
    c.level = c.level - 1
    c.perf = r.perf.demotedTo
    c.shiftsAtLevel = 0
    local lv = C.LevelDef(c.track, c.level)
    local text = string.format("%s was demoted to %s (%s per shift): %s", actor.name, lv.title, fmt(C.Pay(world, lv)), why)
    tell(world, actor, text, "career_" .. c.track)
    journal(world, text)
    say(world, actor, "work_demoted", { job = lv.title, level = c.level })
    SS.Emit("careerDemoted", world, actor, c.level, why)
end
C.Demote = demote

---------------------------------------------------------------------------------------------------
-- Performance, reviews, warnings
---------------------------------------------------------------------------------------------------
function C.MoodPoints(mood)
    for _, tier in ipairs(R().perf.mood) do
        if mood >= tier[1] then return tier[2] end
    end
    return R().perf.mood[#R().perf.mood][2]
end

-- 0..1: how much of the next level's skill requirement this worker already has (1 at the top level).
function C.Readiness(actor)
    local c = actor.career
    local nxt = c and C.LevelDef(c.track, c.level + 1)
    local cur = c and C.LevelDef(c.track, c.level)
    local req = (nxt and nxt.skills) or (cur and cur.skills) or {}
    local have, need = 0, 0
    for _, sk in ipairs(SS.Skills.LIST) do
        local n = req[sk]
        if n and n > 0 then
            need = need + n
            have = have + math.min(n, SS.Skills.Level(actor, sk))
        end
    end
    if need == 0 then return 1 end
    return have / need
end

-- Performance change for one worked shift. Returns delta, parts table (for the UI and tests).
function C.ShiftPerformance(world, actor, sh)
    local p = R().perf
    local c = actor.career
    local parts = {}
    parts.base = p.base
    parts.mood = C.MoodPoints(sh.mood or 0)
    parts.skills = p.skill * C.Readiness(actor) - p.skillOffset
    local nxt = C.LevelDef(c.track, c.level + 1)
    local needF = nxt and nxt.friends or 0
    parts.friends = (C.FriendCount(world, actor) >= needF) and p.friends or 0
    parts.late = -math.min(p.lateMax, (sh.late or 0) * p.latePerMin)
    local d = parts.base + parts.mood + parts.skills + parts.friends + parts.late
    return d, parts
end

local function pruneTimes(list, now, window)
    for n = #list, 1, -1 do if now - list[n] > window then table.remove(list, n) end end
    while #list > 10 do table.remove(list, 1) end
end

local function addWarning(world, actor, text)
    local c = actor.career
    c.warnings = math.min(3, (c.warnings or 0) + 1)
    c.streak = 0
    local t = string.format("Warning %d for %s: %s", c.warnings, actor.name, text)
    tell(world, actor, t, "warning")
    journal(world, t)
end

-- After each worked shift: promotion, readiness notice, demotion or a performance warning.
function C.Review(world, actor)
    local c = actor.career
    if not c then return end
    local r = R()
    if c.perf >= r.promoteAt and c.level < #D().tracks[c.track].levels then
        local ok, rows = C.PromotionStatus(world, actor)
        if ok then promote(world, actor); return "promoted" end
        if (c.shiftsAtLevel or 0) >= r.minShiftsAtLevel and world.time - (c.readyMsgAt or -1e9) >= r.readyMessageDays * 1440 then
            c.readyMsgAt = world.time
            local miss = missingText(rows)
            if miss ~= "" then
                tell(world, actor, string.format("%s's boss would promote them, but the next job needs %s.", actor.name, miss), "career")
            end
        end
        return "ready"
    end
    if c.perf <= r.demoteAt then
        if c.level > 1 then
            demote(world, actor, "performance has been poor for too long.")
            return "demoted"
        end
        if (c.warnings or 0) >= 2 then
            dismiss(world, actor, "performance stayed poor after two warnings.")
            return "fired"
        end
        addWarning(world, actor, "performance is very poor. Arrive in a good mood and work on the job's skills.")
        c.perf = r.warnAt
        return "warned"
    end
    if c.perf <= r.warnAt then
        if not c.perfWarned then
            c.perfWarned = true
            tell(world, actor, string.format("%s's performance is slipping (%d). A bad mood at work drags it down.", actor.name, math.floor(c.perf)), "warning")
        end
    else
        c.perfWarned = nil
    end
end

---------------------------------------------------------------------------------------------------
-- Commute helpers (shared with School.lua)
---------------------------------------------------------------------------------------------------
function C.EntryCell(world)
    if SS.Street and SS.Street.EntryCell then return SS.Street.EntryCell(world) end
    local lot = world.lot
    if lot.entry then return lot.entry[1], lot.entry[2] end
    return math.floor(lot.w / 2), lot.h - 1
end

function C.AtCurb(world, actor)
    if (actor.level or 0) ~= 0 then return false end
    local i, j = C.EntryCell(world)
    local dx, dy = actor.x - (i + 0.5), actor.y - (j + 0.5)
    return dx * dx + dy * dy <= 1.0 + 1e-6
end

local function isSleeping(actor)
    if actor.sleeping then return true end
    local ia = actor.act and SS.Interactions[actor.act.iid]
    return ia and ia.sleeping and actor.act.phase == "perform" or false
end
C.IsSleeping = isSleeping

-- Wake a sleeper gracefully (household-core's wake-up API when present). Returns true if woken.
-- why: "work" | "school" (household-core's wake reasons; a proper wake-up lets the morning routine
-- follow). text: what the person thinks when the fallback interrupts the sleep instead.
function C.Wake(world, actor, why, text)
    if not isSleeping(actor) then return false end
    local Ch = SS.Chains
    if Ch and Ch.RequestWake then
        if Ch.RequestWake(world, actor, why) then return true end
    elseif Ch and Ch.Wake then
        Ch.Wake(world, actor, why)
        return true
    end
    if SS.Actions.Interrupt then
        SS.Actions.Interrupt(world, actor, text or "Time to get up.", "interrupted")
    else
        SS.Actions.Cancel(world, actor, 0)
    end
    return true
end

-- Keep someone out of bed until `untilT` (autonomy only; the player can still order sleep).
function C.HoldAwake(world, actor, untilT)
    actor.cool = actor.cool or {}
    local spots = C.SleepSpots(world)
    for n = 1, #spots do
        local e = spots[n]
        if world.lot.objects[e.oid] == e.obj then
            local k = e.oid .. ":" .. e.iid
            if (actor.cool[k] or -1e9) < untilT then actor.cool[k] = untilT end
        end
    end
    actor.tmpAwakeUntil = untilT
end

-- Is this person already walking (or queued to walk) to the curb for this ride?
function C.OnTheWay(actor, tag)
    local act = actor.act
    if act and act.iid == "goto" and act.data and act.data.ride == tag then return true end
    for _, o in ipairs(actor.queue or {}) do
        if o.iid == "goto" and o.data and o.data.ride == tag then return true end
    end
    return false
end

-- Eating, or cooking one's own meal (not a food chore such as the dishes): household-core's "Food"
-- category, or any action that feeds hunger (the baseline snack). The next queued step counts too
-- (a meal is a chain: cook, prepare, serve, sit down and eat).
local function mealStep(iid)
    local ia = iid and SS.Interactions[iid]
    if type(ia) ~= "table" or ia.chore or ia.sleeping then return false end
    if ia.category == "Food" then return true end
    return (type(ia.gain) == "table" and (tonumber(ia.gain.hunger) or 0) > 0)
        or (type(ia.advert) == "table" and (tonumber(ia.advert.hunger) or 0) > 0)
end
function C.AtMeal(actor)
    if not actor then return false end
    if actor.act then return mealStep(actor.act.iid) end
    local q = actor.queue and actor.queue[1]
    return type(q) == "table" and mealStep(q.iid) or false
end

-- Someone eating when their ride comes finishes the meal first while there is still time: until
-- `deadline` (the last minute to set off and still be on time, less R().mealSlack for the walk out).
-- hold is the ride's runtime record; a meal chain has a moment between its steps (cook, serve, sit,
-- eat), so an action that just ended keeps the hold for two more minutes. Bounded by the deadline.
function C.WaitForMeal(world, actor, hold, deadline)
    if world.time >= deadline then return false end
    if C.AtMeal(actor) then hold.mealUntil = world.time + 2; return true end
    return hold.mealUntil ~= nil and world.time < hold.mealUntil and not actor.act
end

-- Walk to the curb for a ride. tag identifies the ride (for actionEnded). Returns ok, why.
function C.SendToCurb(world, actor, tag)
    local i, j = C.EntryCell(world)
    if isSleeping(actor) then C.Wake(world, actor, tag == "schoolbus" and "school" or "work", "Time to go.") end
    if actor.act and not (actor.act.iid == "goto" and actor.act.data and actor.act.data.ride == tag) then
        if SS.Actions.Interrupt then SS.Actions.Interrupt(world, actor, "Time to go.", "interrupted")
        else SS.Actions.Cancel(world, actor, 0) end
    end
    actor.queue = {}
    if actor.orders then actor.orders = actor.queue end
    local ok = SS.Actions.Order(world, actor, nil, "goto", i, j, { level = 0, data = { ride = tag } })
    if not ok then return false, "could not be sent to the curb" end
    return true
end

function C.Depart(world, actor, reason, returnAt, data)
    if SS.Street and SS.Street.Depart then
        SS.Street.Depart(world, actor, reason, returnAt, data)
    else
        SS.Sim.RemoveActor(world, actor.id, { reason = reason, untilT = returnAt, data = data, lotId = world.lot.id })
    end
end

function C.Arrive(world, rid)
    local r = world.root.residents[rid]
    if not r or r.dead or r.lotId then return world.actors[rid] end
    r.away = nil
    if SS.Street and SS.Street.Arrive then return SS.Street.Arrive(world, rid) end
    local i, j = C.EntryCell(world)
    return SS.Sim.AddActor(world, rid, i, j, 0)
end

-- Would this worker leaving now leave an infant or toddler with nobody to mind them?
-- Returns nil when it is fine, else the reason (a lower-case clause, no full stop). The family
-- module answers when present: SS.Family.CanLeave(world, rids) -> ok, why, asked about this worker
-- together with every other adult who is on the way out right now (so two parents cannot both go).
function C.LeavesSomeoneAlone(world, actor)
    if SS.Family and SS.Family.CanLeave then
        local rids = { actor.id }
        for rid, b in pairs(C.rt.board) do if rid ~= actor.id and not b.blocked then rids[#rids + 1] = rid end end
        table.sort(rids)
        local ok, why = SS.Family.CanLeave(world, rids)
        if ok == false then
            why = tostring(why or "a young child cannot be left alone"):gsub("%.$", ""):gsub("^%u", string.lower)
            return why
        end
        if ok == true then return nil end
    end
    local young, carer
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and a ~= actor then
            if C.IsMember(world, a) and C.NeedsMinding(a) then young = young or a end
            local minder = (C.IsMember(world, a) and C.WorkingAge(a) and not C.Leaving(a)) or a.role == "nanny" or a.role == "babysitter"
            local b2 = C.rt.board[a.id]
            -- another adult who is also about to leave does not count, unless they are staying (blocked)
            if minder and not (b2 and not b2.blocked) then carer = a end
        end
    end
    if young and not carer then return "nobody else is home to mind " .. young.name end
    return nil
end

---------------------------------------------------------------------------------------------------
-- The carpool: wake, pickup, boarding, departure, missing it
---------------------------------------------------------------------------------------------------
local function shiftFor(world, rid, shiftId)
    local r = world.root.residents[rid]
    local c = r and r.career
    local sh = c and c.shift
    if not sh or sh.id ~= shiftId then return nil end
    return r, c, sh
end

local function carpoolKey(rid) return "carpool:" .. rid end

-- Settle a shift that was skipped without the worker's fault (the household was paused past it).
local function skip(world, actor, sh, why)
    sh.state, sh.reason = "skipped", why
    archive(actor.career, sh)
    C.rt.board[actor.id] = nil
    SS.Economy.RemoveVehicle(world, carpoolKey(actor.id), true)
    C.Plan(world, actor, world.time)
end

-- The last moment to set off for this shift and still board on time, keeping mealSlack for the walk.
function C.SetOffBy(sh) return sh.start - R().commute - R().mealSlack end

-- Tell household-core when this person has to be out of the door, whether they were just woken or
-- were already up: a hungry person then prefers food that is done in time (SS.Chains.GetReady).
function C.GetReady(world, actor, leaveAt)
    local Ch = SS.Chains
    if Ch and type(Ch.GetReady) == "function" then return Ch.GetReady(world, actor, leaveAt) end
    return false
end

local function onWake(world, ev)
    local actor, c, sh = shiftFor(world, ev.data.rid, ev.data.shift)
    if not sh or sh.state ~= "planned" then return end
    local a = world.actors[actor.id]
    if not a then return end
    C.HoldAwake(world, a, sh.start)
    if C.Wake(world, a, "work", "The alarm rings: work today.") then
        tell(world, a, string.format("%s's alarm goes off: the carpool comes at %s.", a.name, C.ClockText(sh.pickupAt)), "energy")
    end
    C.GetReady(world, a, C.SetOffBy(sh))
end

local function onPickup(world, ev)
    local actor, c, sh = shiftFor(world, ev.data.rid, ev.data.shift)
    if not sh or sh.state ~= "planned" then return end
    if world.time > sh.start + 1 then return skip(world, actor, sh, "the household was not being played") end
    local lv = C.LevelDef(c.track, sh.level)
    if c.dayOff and c.dayOff == sh.start then
        c.dayOff = nil
        sh.state, sh.reason = "off", "vacation day"
        archive(c, sh)
        tell(world, actor, string.format("%s has the day off (a vacation day). No pay, no penalty.", actor.name), "career")
        C.Plan(world, actor, world.time)
        return
    end
    sh.state, sh.arrivedAt = "waiting", world.time
    SS.Economy.AddVehicle(world, carpoolKey(actor.id), lv.carpool)
    C.rt.board[actor.id] = { shift = sh.id, attempts = 0, nextTry = world.time }
    local a = world.actors[actor.id]
    if a then
        C.HoldAwake(world, a, sh.start)
        tell(world, a, string.format("The carpool (%s) is at the curb for %s. It leaves at %s.", lv.carpool, a.name, C.ClockText(sh.start)), "career_" .. c.track)
    else
        tell(world, actor, string.format("The carpool is here for %s, but %s is not home.", actor.name, actor.name), "career")
    end
end

-- The worker is at the curb: change is done, board, depart. Records mood and lateness.
function C.Board(world, actor)
    local c = actor.career
    local sh = c and c.shift
    if not sh or sh.state ~= "waiting" then return false end
    local r = R()
    local lv = C.LevelDef(c.track, sh.level)
    sh.state = "away"
    sh.boardedAt = world.time
    sh.late = math.max(0, math.floor(world.time + r.commute - sh.start + 0.5))
    sh.mood = math.floor(SS.Needs.Mood(actor) + 0.5)
    sh.pay = C.Pay(world, lv)
    sh.returnAt = sh.finish + r.commute
    C.DressForWork(actor, lv)
    C.rt.board[actor.id] = nil
    unschedule(world, actor.id)
    schedule(world, sh.returnAt + 2, "career.return", actor.id, sh.id)
    -- a career chance event, sometimes (or when the events director asked for one), halfway through the shift
    local ch = R().chance
    local forced = c.forceChance
    c.forceChance = nil
    if forced or (world.time - (c.lastChance or -1e9) >= ch.cooldownDays * 1440 and SS.Random(world, "career.chance") < ch.p) then
        local e = C.PickChance(world, actor, sh.level)
        if e then
            local mid = math.max(world.time + 5, sh.start + (sh.finish - sh.start) / 2)
            schedule(world, mid, "career.chance", actor.id, sh.id, { event = e.id, director = forced and true or nil })
            sh.chanceAt = mid
        end
    end
    local text = string.format("%s left for work as a %s.", actor.name, lv.title)
    if sh.late > 0 then text = text .. string.format(" They will be %d minutes late.", sh.late) end
    tell(world, actor, text, "career_" .. c.track)
    -- social's Lines situations: "work_late" with the minutes, else "career_leave" (both in social's list)
    if sh.late > 0 then say(world, actor, "work_late", { job = lv.title, count = sh.late })
    else say(world, actor, "career_leave", { job = lv.title }) end
    -- the worker boards the carpool when the street walks riders to their vehicle (visitors);
    -- otherwise the carpool simply drives off as they leave
    local vid = SS.Economy.HandOverVehicle(world, carpoolKey(actor.id), { actor.id })
    SS.Emit("careerDeparted", world, actor, sh)
    C.Depart(world, actor, "work", sh.returnAt, { shift = sh.id, vehicle = vid, returnVehicle = vid and lv.carpool or nil })
    return true
end

-- Missed shift. excused = childcare (smaller penalty, no warning). Returns the outcome word.
function C.Miss(world, actor, reason, excused)
    local c = actor.career
    local sh = c and c.shift
    if not sh then return end
    local r = R()
    sh.state, sh.reason = "missed", reason
    C.rt.board[actor.id] = nil
    SS.Economy.RemoveVehicle(world, carpoolKey(actor.id))
    local lv = C.LevelDef(c.track, c.level)
    C.Undress(actor)
    -- stop a walk to the curb that is still going on
    local a = world.actors[actor.id]
    if a and a.act and a.act.iid == "goto" and a.act.data and a.act.data.ride == "carpool" then SS.Actions.Cancel(world, a, 0) end
    c.streak = 0
    local outcome
    if excused then
        c.perf = clamp(c.perf + r.perf.childcare, -100, 100)
        tell(world, actor, string.format("%s stayed home: %s. The boss understands, once. No pay today.", actor.name, reason), "career")
        outcome = "excused"
    else
        c.perf = clamp(c.perf + r.perf.miss, -100, 100)
        if a then say(world, actor, "work_late", { job = lv and lv.title }) end
        c.misses = c.misses or {}
        c.misses[#c.misses + 1] = world.time
        pruneTimes(c.misses, world.time, r.missWindowDays * 1440)
        local n = #c.misses
        if n >= 3 then
            archive(c, sh)
            dismiss(world, actor, string.format("missed work three times in %d days (%s).", r.missWindowDays, reason))
            SS.Emit("careerMissed", world, actor, sh, "fired")
            return "fired"
        elseif n == 2 then
            if c.level > 1 then
                demote(world, actor, "missed work twice in two weeks (" .. reason .. ").")
                outcome = "demoted"
            else
                c.warnings = 2
                local t = string.format("Final warning for %s: missed work twice (%s). One more miss and the job is gone.", actor.name, reason)
                tell(world, actor, t, "warning")
                journal(world, t)
                outcome = "final"
            end
        else
            addWarning(world, actor, "missed work (" .. reason .. "). Missing again soon means a demotion.")
            outcome = "warned"
        end
    end
    archive(c, sh)
    SS.Emit("careerMissed", world, actor, sh, outcome)
    if actor.career then C.Plan(world, actor, world.time) end
    return outcome
end

local function onLeave(world, ev)
    local actor, c, sh = shiftFor(world, ev.data.rid, ev.data.shift)
    if not sh then return end
    if sh.state == "planned" then return skip(world, actor, sh, "the carpool never came") end
    if sh.state ~= "waiting" then return end
    local b = C.rt.board[actor.id]
    local a = world.actors[actor.id]
    if a then
        -- childcare is decided by who is home now, whatever an earlier check said
        local alone = C.LeavesSomeoneAlone(world, a)
        if alone then
            sh.minding, sh.mindCheck = nil, nil
            return C.Miss(world, actor, alone, true)
        end
        -- boarding happens in the system tick; someone standing at the curb right now still makes it
        if C.AtCurb(world, a) then sh.minding, sh.mindCheck = nil, nil; C.Board(world, a); return end
        -- held home until (almost) now: there was no time left to get to the car, still a childcare miss
        local held = sh.minding or (sh.mindFreed and world.time - sh.mindFreed <= R().mindGrace and sh.mindWhy)
        if held then
            local why = sh.minding or sh.mindWhy
            sh.minding, sh.mindCheck = nil, nil
            return C.Miss(world, actor, why, true)
        end
    end
    local why
    if not a then why = "was not home when the carpool came"
    elseif b and b.failed then why = b.failed
    else why = "did not make it to the carpool in time" end
    C.Miss(world, actor, why, false)
end

-- Childcare hold. A worker who would leave an infant or toddler with nobody to mind them waits at
-- home instead of walking to the carpool. The hold is a condition, not a verdict: it is checked again
-- every rules.mindRecheck minutes and at the curb, so another adult who comes home in time (or anyone
-- else the family module's CanLeave accepts as a carer) lets the worker go. It is saved on the shift (minding, mindCheck), so a reload rebuilds the same
-- hold and checks it at the same time. Only a worker still needed when the carpool leaves misses the
-- shift (excused). Returns the reason while held, else nil.
local function checkMinding(world, actor, b, sh)
    local alone = C.LeavesSomeoneAlone(world, actor)
    if alone then
        if not sh.minding then
            tell(world, actor, string.format("%s can't leave for work: %s. If another adult comes home before the carpool leaves at %s, %s can still go.",
                actor.name, alone, C.ClockText(sh.start), actor.name), "warning")
        end
        sh.minding, b.blocked = alone, alone
        b.nextTry = world.time + R().mindRecheck
        sh.mindCheck = b.nextTry
        return alone
    end
    if sh.minding then
        sh.mindWhy, sh.mindFreed = sh.minding, world.time
        sh.minding, sh.mindCheck, b.blocked = nil, nil, nil
        tell(world, actor, string.format("Someone is home to mind the little one now: %s heads out to the carpool.", actor.name), "career")
    end
    return nil
end

-- System tick: send waiting workers to the curb (bounded retries) and board the ones who got there.
local boardIds = {}
local function tickBoarding(world)
    local r = R()
    -- (a reused, sorted id list: no table per tick)
    local n = 0
    for rid in pairs(C.rt.board) do n = n + 1; boardIds[n] = rid end
    for k = #boardIds, n + 1, -1 do boardIds[k] = nil end
    if n > 1 then table.sort(boardIds) end
    for k = 1, n do
        local rid = boardIds[k]
        local b = C.rt.board[rid]
        local actor = world.actors[rid]
        local c = world.root.residents[rid] and world.root.residents[rid].career
        local sh = c and c.shift
        if not b then
            -- (removed earlier in this tick)
        elseif not sh or sh.state ~= "waiting" or sh.id ~= b.shift then
            C.rt.board[rid] = nil
        elseif actor then
            -- a childcare hold is looked at again on its own schedule; when it clears the worker goes now
            if b.blocked and world.time >= (b.nextTry or 0) then checkMinding(world, actor, b, sh) end
            local walkingThere = actor.act and actor.act.iid == "goto" and actor.act.data and actor.act.data.ride == "carpool"
            if b.blocked then
                -- held home: waits for the next check (or the carpool leaves without them)
            elseif C.AtCurb(world, actor) and not (actor.act and not walkingThere) then
                -- the last look before stepping into the car: someone may have gone out meanwhile
                if not checkMinding(world, actor, b, sh) then C.Board(world, actor) end
            elseif not C.OnTheWay(actor, "carpool") and world.time >= (b.nextTry or 0) then
                if checkMinding(world, actor, b, sh) then
                    -- held home (told once)
                elseif b.attempts == 0 and C.WaitForMeal(world, actor, b, C.SetOffBy(sh)) then
                    if not b.mealTold then
                        b.mealTold = true
                        tell(world, actor, string.format("%s finishes eating first, then heads out to the carpool.", actor.name), "career")
                    end
                elseif b.attempts < r.maxSendAttempts then
                    b.attempts = b.attempts + 1
                    local lv = C.LevelDef(c.track, sh.level)
                    local ok, why = C.SendToCurb(world, actor, "carpool")
                    b.nextTry = world.time + r.retryMinutes
                    if ok then
                        b.walking = true
                        if b.attempts == 1 then
                            C.DressForWork(actor, lv)
                            tell(world, actor, string.format("%s changes into work clothes and heads for the carpool.", actor.name), "career_" .. c.track)
                        end
                    else
                        b.failed = why
                        b.nextTry = world.time + r.retryMinutes
                    end
                elseif not b.told then
                    b.told = true
                    tell(world, actor, string.format("%s keeps not getting to the carpool. It leaves at %s.", actor.name, C.ClockText(sh.start)), "warning")
                end
            end
        end
    end
end
C.TickBoarding = tickBoarding

SS.On("actionEnded", function(actor, act, status, reason)
    if not act or act.iid ~= "goto" or not act.data or act.data.ride ~= "carpool" then return end
    local b = C.rt.board[actor.id]
    if not b then return end
    b.walking = false
    local world = SS.Sim.world
    if status ~= "done" and world then
        b.failed = "could not get to the curb (" .. tostring(reason or status) .. ")"
        b.nextTry = world.time + R().retryMinutes
    end
end)

---------------------------------------------------------------------------------------------------
-- Coming home: needs, performance, pay (exactly once), review, next shift
---------------------------------------------------------------------------------------------------
function C.WorkRates(track)
    local out = {}
    for k, v in pairs(D().workNeeds) do out[k] = v end
    local t = D().tracks[track]
    for k, v in pairs(t and t.work or {}) do out[k] = v end
    return out
end

-- Needs over a day away (work or school). A day of at least meal.minHours has a meal break halfway:
-- the first half of the hours, then hunger + meal.hunger, then the second half. meal defaults to the
-- work rule (D.rules.mealBreak); the school passes its lunch. Bladder returns at floorBladder if it
-- was lower. Returns the meal break's hunger (0 if none).
local function applyAwayNeeds(actor, rates, hours, floorBladder, mealRule)
    local mb = mealRule or R().mealBreak
    local meal = (type(mb) == "table" and hours >= (mb.minHours or math.huge)) and (mb.hunger or 0) or 0
    local parts = meal > 0 and 2 or 1
    for part = 1, parts do
        for _, need in ipairs(SS.Tuning.needs) do
            local rate = rates[need]
            if rate and need ~= "bladder" and need ~= "room" then SS.Needs.Add(actor, need, rate * hours / parts) end
        end
        if part == 1 and meal > 0 then SS.Needs.Add(actor, "hunger", meal) end
    end
    if floorBladder and (actor.needs.bladder or 0) < floorBladder then actor.needs.bladder = floorBladder end
    return meal
end
C.ApplyAwayNeeds = applyAwayNeeds

-- Settle a worked shift. Idempotent: sh.paid guards the money.
function C.Settle(world, actor)
    local c = actor.career
    local sh = c and c.shift
    if not sh or sh.state ~= "away" or sh.paid then return false end
    sh.paid = true
    sh.paidAt = world.time
    sh.state = "done"
    if c.pending and c.pending.shift == sh.id then C.ResolveChance(world, actor, nil, "auto") end
    local r = R()
    local hours = math.max(0, (math.min(world.time, sh.returnAt or world.time) - (sh.boardedAt or world.time)) / 60)
    local rates = C.WorkRates(c.track)
    local meal = applyAwayNeeds(actor, rates, hours, rates.bladder)
    sh.meal = meal > 0 and meal or nil
    local delta, parts = C.ShiftPerformance(world, actor, sh)
    sh.perfDelta, sh.parts = delta, parts
    c.perf = clamp(c.perf + delta, -100, 100)
    SS.Money(world, sh.pay, "wages", string.format("Wages: %s (%s)", sh.title, actor.name))
    local garnished = SS.Economy.Garnish(world, sh.pay)
    sh.garnished = garnished > 0 and garnished or nil
    c.daysWorked = (c.daysWorked or 0) + 1
    c.shiftsAtLevel = (c.shiftsAtLevel or 0) + 1
    c.earned = (c.earned or 0) + sh.pay
    c.streak = (c.streak or 0) + 1
    if c.daysWorked % r.vacationEvery == 0 and (c.vacation or 0) < r.vacationCap then c.vacation = (c.vacation or 0) + 1 end
    if (c.warnings or 0) > 0 and c.streak >= r.warningClearShifts then
        c.warnings = c.warnings - 1
        c.streak = 0
        tell(world, actor, string.format("%s's boss has noticed the reliable attendance: one warning cleared.", actor.name), "career")
    end
    if sh.late > 0 then
        c.lates = c.lates or {}
        c.lates[#c.lates + 1] = world.time
        pruneTimes(c.lates, world.time, r.missWindowDays * 1440)
        if #c.lates >= 3 then
            c.lates = {}
            addWarning(world, actor, "late three times in two weeks.")
        end
    end
    local lv = C.LevelDef(c.track, c.level)
    C.Undress(actor)
    local text = string.format("%s is home from work: earned %s. Performance %s%d (now %d).", actor.name, fmt(sh.pay),
        delta >= 0 and "+" or "", math.floor(delta + 0.5), math.floor(c.perf + 0.5))
    if sh.late > 0 then text = text .. string.format(" Arrived %d minutes late.", sh.late) end
    if garnished > 0 then text = text .. string.format(" %s was withheld for unpaid bills.", fmt(garnished)) end
    tell(world, actor, text, "money")
    -- night workers head for bed; this also feeds the sleep chain (see candidates below)
    if lv and lv.finish <= lv.start then actor.tmpNightShift = world.time end
    archive(c, sh)
    SS.Emit("careerShiftDone", world, actor, sh)
    local outcome = C.Review(world, actor)
    -- one spoken line on the way in: the review's own (promotion, demotion, dismissal), else the
    -- home line (household-core's Actions.Say allows one line per person every few minutes)
    if outcome ~= "promoted" and outcome ~= "demoted" and outcome ~= "fired" then
        say(world, actor, "career_home", { job = lv and lv.title, amount = sh.pay })
    end
    if actor.career then C.Plan(world, actor, world.time) end
    return true
end

SS.On("actorAdded", function(world, r)
    if not world or not r or not r.career then return end
    local sh = r.career.shift
    if sh and sh.state == "away" and not sh.paid and isHome(world) then C.Settle(world, r) end
end)

local function onReturn(world, ev)
    local actor, c, sh = shiftFor(world, ev.data.rid, ev.data.shift)
    if not sh or sh.state ~= "away" or sh.paid then return end
    -- the street did not bring them back: do it here (arrival settles), else settle anyway
    if not world.actors[actor.id] and not actor.dead then C.Arrive(world, actor.id) end
    if sh.state == "away" and not sh.paid then C.Settle(world, actor) end
end

---------------------------------------------------------------------------------------------------
-- Chance events
---------------------------------------------------------------------------------------------------
function C.ChanceDef(id)
    for _, e in ipairs(D().chance) do if e.id == id then return e end end
end

local function defaultChoice(e)
    for n, ch in ipairs(e.choices) do if ch.default then return n end end
    return #e.choices
end

-- Probability (0..1) that a skill check succeeds for this worker.
function C.CheckChance(actor, check)
    return clamp(check.base + check.per * SS.Skills.Level(actor, check.skill), 0.05, 0.95)
end

-- A chance event this worker has not had recently, for their track and level (nil when none fits).
function C.PickChance(world, actor, level)
    local c = actor.career
    if not c then return nil end
    local list, all = {}, {}
    for _, e in ipairs(D().chance) do
        if e.track == c.track and (level or c.level) >= (e.minLevel or 1) then
            all[#all + 1] = e
            local recent = false
            for _, id in ipairs(c.recent or {}) do if id == e.id then recent = true end end
            if not recent then list[#list + 1] = e end
        end
    end
    -- every eligible event was recent (few at low levels): anything but the very last one, or that one again
    if #list == 0 then
        local last = c.recent and c.recent[#c.recent]
        for _, e in ipairs(all) do if e.id ~= last then list[#list + 1] = e end end
        if #list == 0 then list = all end
    end
    return SS.Pick(world, "career.chance", list)
end

local function startChance(world, actor, c, sh, e, director)
    -- the events module records director-started events itself; ours go in its log here
    local rec
    if not director and SS.Events and SS.Events.Record then rec = SS.Events.Record(world, "career_chance", { rid = actor.id, id = e.id }) end
    c.pending = { id = e.id, shift = sh.id, at = world.time, untilT = world.time + R().chance.autoResolveHours * 60, eventId = rec and rec.id }
    c.lastChance = world.time
    c.recent = c.recent or {}
    c.recent[#c.recent + 1] = e.id
    while #c.recent > R().chance.recent do table.remove(c.recent, 1) end
    tell(world, actor, string.format("At work: %s. %s needs you to decide.", e.title, actor.name), "career_" .. c.track)
    SS.Emit("careerChance", world, actor, e)
end

local function onChance(world, ev)
    local actor, c, sh = shiftFor(world, ev.data.rid, ev.data.shift)
    if not sh or sh.state ~= "away" or c.pending then return end
    local e = C.ChanceDef(ev.data.event)
    if not e then return end
    startChance(world, actor, c, sh, e, ev.data.director)
end

-- For the events module's director (family "work_chance"): a worker at work gets a chance event now;
-- one with a shift coming up is sure to get one on that shift. Returns ok, text.
function C.ChanceEvent(world, actor)
    local c = actor and actor.career
    if not c then return false, "They do not have a job." end
    if c.pending then return false, "A decision is already waiting at work." end
    local sh = c.shift
    if not sh then return false, "There is no shift coming up." end
    if sh.state == "away" then
        local e = C.PickChance(world, actor, sh.level)
        if not e then return false, "Nothing unusual is happening at work." end
        startChance(world, actor, c, sh, e, true)
        return true, string.format("%s at work: %s.", actor.name, e.title)
    elseif sh.state == "planned" or sh.state == "waiting" then
        if c.forceChance then return false, "Something is already brewing at work." end
        if not C.PickChance(world, actor, sh.level) then return false, "Nothing unusual is happening at work." end
        c.forceChance = true
        return true, string.format("Rumours at %s's work: the next shift will be eventful.", actor.name)
    end
    return false, "There is no shift coming up."
end

-- Apply an outcome record to the worker. Returns the text.
local function applyOutcome(world, actor, o, title)
    local c = actor.career
    if o.perf and c then c.perf = clamp(c.perf + o.perf, -100, 100) end
    if o.money and o.money ~= 0 then
        if o.money > 0 then SS.Money(world, o.money, "wages", "Bonus at work: " .. title)
        else
            -- never below zero: what the household cannot pay now comes out of the next wages
            local now, later = SS.Economy.Debit(world, -o.money, "fines", "Docked at work: " .. title)
            if later > 0 then
                tell(world, actor, string.format("%s is short: %s of the %s docked will be withheld from the next wages.", actor.name, fmt(later), fmt(-o.money)), "money")
            end
        end
    end
    if o.skill then SS.Skills.Adjust(world, actor, o.skill.name, o.skill.levels) end
    if o.needs then for need, v in pairs(o.needs) do SS.Needs.Add(actor, need, v) end end
    if o.vacation and c then c.vacation = math.min(R().vacationCap, (c.vacation or 0) + o.vacation) end
    if o.rel then
        if o.rel.who == "coworker" and c and c.coworker then
            c.coworker.rel = clamp((c.coworker.rel or 0) + (o.rel.life or 0) + (o.rel.daily or 0) * 0.5, -100, 100)
        elseif o.rel.who == "household" and SS.Social and SS.Social.Change then
            for _, m in ipairs(C.Members(world)) do
                if m.id ~= actor.id then
                    SS.Social.Change(world, actor.id, m.id, o.rel.daily, o.rel.life)
                    SS.Social.Change(world, m.id, actor.id, o.rel.daily, o.rel.life)
                end
            end
        end
    end
    return o.text
end

-- Resolve the pending chance event with choice index n (nil = the default choice). how = "player"|"auto".
-- Returns ok, text, success.
function C.ResolveChance(world, actor, n, how)
    local c = actor and actor.career
    local p = c and c.pending
    if not p then return false, "There is nothing to decide." end
    local e = C.ChanceDef(p.id)
    c.pending = nil
    if not e then return false, "That event no longer exists." end
    n = n or defaultChoice(e)
    local ch = e.choices[n] or e.choices[defaultChoice(e)]
    local outcome, success = ch.outcome, nil
    if ch.check then
        success = SS.Random(world, "career.chance") < C.CheckChance(actor, ch.check)
        outcome = success and ch.success or ch.failure
    end
    local text = applyOutcome(world, actor, outcome, e.title)
    local sh = c.shift and c.shift.id == p.shift and c.shift or nil
    if not sh then
        for _, h in ipairs(c.history or {}) do if h.id == p.shift then sh = h end end
    end
    if sh then sh.chance = { id = e.id, choice = n, success = success, how = how or "player" } end
    local full = string.format("%s - %s: %s", e.title, ch.label, text)
    if how == "auto" then full = full .. " (Nobody answered, so " .. actor.name .. " chose the safe option.)" end
    tell(world, actor, full, "career_" .. c.track)
    journal(world, actor.name .. " at work: " .. text)
    if p.eventId and SS.Events and SS.Events.Resolve then SS.Events.Resolve(world, p.eventId, ch.label) end
    SS.Emit("careerChanceResolved", world, actor, e, n, success, outcome)
    return true, text, success
end

---------------------------------------------------------------------------------------------------
-- Days off
---------------------------------------------------------------------------------------------------
-- Use a vacation day for the next shift. force = stay home without one (counts as a missed shift).
function C.TakeDayOff(world, actor, force)
    local c = actor and actor.career
    if not c then return false, "They do not have a job." end
    local sh = c.shift
    if not sh then return false, "There is no shift planned." end
    if sh.state == "away" then return false, actor.name .. " is already at work." end
    if (c.vacation or 0) > 0 then
        c.vacation = c.vacation - 1
        if sh.state == "waiting" then
            sh.state, sh.reason = "off", "vacation day"
            C.rt.board[actor.id] = nil
            SS.Economy.RemoveVehicle(world, carpoolKey(actor.id))
            archive(c, sh)
            C.Plan(world, actor, world.time)
        else
            c.dayOff = sh.start
        end
        local text = string.format("%s is taking a vacation day on %s. %d left.", actor.name, SS.Sim.ClockText(sh.start), c.vacation)
        tell(world, actor, text, "career")
        return true, text
    end
    if not force then
        return false, "No vacation days left. Staying home anyway counts as a missed shift."
    end
    if sh.state ~= "waiting" and sh.state ~= "planned" then return false, "There is no shift to skip." end
    local outcome = C.Miss(world, actor, "called in and stayed home", false)
    return true, "Stayed home: " .. tostring(outcome)
end

---------------------------------------------------------------------------------------------------
-- Job offers (newspaper, computer, phone)
---------------------------------------------------------------------------------------------------
local function shuffled(world, stream, list)
    local out = {}
    for n, v in ipairs(list) do out[n] = v end
    for n = #out, 2, -1 do
        local k = SS.RandomInt(world, stream, 1, n)
        out[n], out[k] = out[k], out[n]
    end
    return out
end

-- Today's offers from a source ("newspaper" | "computer" | "phone"). The same source gives the same
-- list all day; a new day brings new offers. Returns { { track, level }... }.
function C.Offers(world, source)
    local hh = world.household
    if not hh then return {} end
    local day = math.floor(world.time / 1440)
    local o = hh.jobOffers
    if type(o) ~= "table" or o.day ~= day then o = { day = day }; hh.jobOffers = o end
    if not o[source] then
        local js = D().jobSearch
        local n = js[source] or 3
        local tracks = shuffled(world, "career.offers", D().trackOrder)
        local list = {}
        for k = 1, math.min(n, #tracks) do
            local level = 1
            if SS.Random(world, "career.offers") < js.higherChance then level = SS.RandomInt(world, "career.offers", 2, js.maxOfferLevel) end
            list[#list + 1] = { track = tracks[k], level = level }
        end
        o[source] = list
    end
    return o[source]
end

-- Offers seen today (newspaper and computer) plus, unless `seenOnly`, the job line's own, without duplicates.
function C.PhoneOffers(world, seenOnly)
    local out, seen = {}, {}
    local hh = world.household
    local o = hh and hh.jobOffers
    local day = math.floor(world.time / 1440)
    local lists = {}
    if type(o) == "table" and o.day == day then lists[#lists + 1] = o.newspaper; lists[#lists + 1] = o.computer end
    if not seenOnly then lists[#lists + 1] = C.Offers(world, "phone") end
    for _, l in ipairs(lists) do
        for _, off in ipairs(l or {}) do
            local k = off.track .. ":" .. off.level
            if not seen[k] then seen[k] = true; out[#out + 1] = off end
        end
    end
    return out
end

-- Describe an offer for this person: { track, level, name, title, pay, shift, ok, why, rows }.
function C.DescribeOffer(world, actor, off)
    local lv = C.LevelDef(off.track, off.level)
    local ok, why = C.CanTake(world, actor, off.track, off.level)
    local _, rows = C.Requirements(world, actor, off.track, off.level)
    return { track = off.track, level = off.level, name = D().tracks[off.track].name, title = lv.title, pay = C.Pay(world, lv),
        shift = C.ShiftText(lv), carpool = lv.carpool, outfit = lv.outfit, desc = lv.desc, ok = ok, why = why, rows = rows }
end

-- Show offers to the player (UI popup via the "careerOffers" event). Returns the list.
-- source: "newspaper" | "computer" | "phone" (seen today + the job line's) | "seen" (today's newspaper
-- and computer listings again, nothing new).
function C.ShowOffers(world, actor, source)
    local list
    if source == "phone" then list = C.PhoneOffers(world)
    elseif source == "seen" then list = C.PhoneOffers(world, true)
    else list = C.Offers(world, source) end
    local out = {}
    for _, off in ipairs(list) do out[#out + 1] = C.DescribeOffer(world, actor, off) end
    SS.Emit("careerOffers", world, actor, source, out)
    return out
end

local function searchTest(world, actor, obj)
    if not C.IsMember(world, actor) then return false, "Only household members look for work here." end
    if not C.WorkingAge(actor) then return false, "Job hunting is for grown-ups." end
    if obj and obj.state and obj.state.broken then return false, "It's broken." end
    return true
end

SS.Interactions = SS.Interactions or {}
-- The morning paper (visitors' system object, tag "newspaper") carries state.day; a paper from an
-- earlier day has no current listings. Reading it marks it read, so the visitors module's
-- recycling picks it up.
local function paperTest(world, actor, obj)
    local ok, why = searchTest(world, actor, obj)
    if not ok then return ok, why end
    local day = obj and obj.state and obj.state.day
    if day and day < math.floor(world.time / 1440) then
        return false, "That paper is from an earlier day; its job listings have gone. Today's paper comes in the morning."
    end
    return true
end
C.PaperTest = paperTest

SS.Interactions.career_paper = {
    label = "Look for a Job", category = "Career", slot = "front", pose = "read", carry = "newspaper", dur = 15, manualOnly = true,
    ages = { adult = true, elder = true }, kinds = { human = true }, test = paperTest,
    onStart = function(world, actor, act, obj)
        if obj then obj.state = obj.state or {}; obj.state.read = true end
    end,
    onEnd = function(world, actor, act, obj, status)
        if status == "done" then C.ShowOffers(world, actor, "newspaper") end
    end,
}
SS.Interactions.career_pc = {
    label = "Find a Job Online", category = "Career", slot = "front", pose = "type", dur = 20, manualOnly = true,
    ages = { adult = true, elder = true }, kinds = { human = true }, test = searchTest,
    onEnd = function(world, actor, act, obj, status)
        if status == "done" then C.ShowOffers(world, actor, "computer") end
    end,
}
SS.Tags.Attach("newspaper", "career_paper")
SS.Tags.Attach("computer", "career_pc")

---------------------------------------------------------------------------------------------------
-- Sleep chain: night workers sleep after their shift; nobody goes back to bed just before a pickup.
---------------------------------------------------------------------------------------------------
-- The lot's beds (objects with an open-ended sleeping interaction), found once per lot change
-- (lot.version, a world rebuild, or a lotChanged that is not a state change): sleep autonomy after a
-- night shift and HoldAwake do not scan every object. Runtime only.
local function sleepSpots(world)
    local lot = world.lot
    local c = C.rt.beds
    if c and not c.dirty and c.lot == lot and c.version == lot.version and c.rt == SS.RT then return c.list end
    local list = {}
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        for _, iid in ipairs(def and def.actions or {}) do
            local ia = SS.Interactions[iid]
            if ia and ia.sleeping then list[#list + 1] = { oid = oid, obj = o, iid = iid, open = not ia.dur } end
        end
    end
    C.rt.beds = { lot = lot, version = lot.version, rt = SS.RT, list = list }
    return list
end
C.SleepSpots = sleepSpots
SS.On("lotChanged", function(kind) if kind ~= "state" and C.rt.beds then C.rt.beds.dirty = true end end)

local function sleepCandidates(world, actor, cands)
    if not actor.tmpNightShift or not C.IsMember(world, actor) or actor.role then return end -- (not while walking in)
    if world.time - actor.tmpNightShift > 8 * 60 or (actor.needs.energy or 0) > 70 then actor.tmpNightShift = nil; return end
    if actor.act or (actor.queue and #actor.queue > 0) then return end
    local best, bestD
    local spots = sleepSpots(world)
    for n = 1, #spots do
        local e = spots[n]
        local o = e.obj
        if e.open and world.lot.objects[e.oid] == o and SS.Actions.Available(world, actor, o, e.iid) then
            local d = math.abs(o.x + 0.5 - actor.x) + math.abs(o.y + 0.5 - actor.y)
            if not bestD or d < bestD then best, bestD = e, d end
        end
    end
    if best then cands[#cands + 1] = { oid = best.oid, iid = best.iid, s = 40 + math.max(0, 50 - (actor.needs.energy or 0)) * 0.5 } end
end
SS.Actions.RegisterCandidates(sleepCandidates)

if SS.Actions.RegisterAvailability then
    SS.Actions.RegisterAvailability(function(world, actor, obj, iid, ia)
        if ia and ia.sleeping and not ia.dur and actor.tmpAwakeUntil and world.time < actor.tmpAwakeUntil and not (actor.act and actor.act.manual) then
            local c = actor.career
            if c and c.shift and (c.shift.state == "planned" or c.shift.state == "waiting") and world.time >= c.shift.pickupAt - R().wakeLead then
                return false, "Work soon: the carpool comes at " .. C.ClockText(c.shift.pickupAt) .. ".", "career"
            end
        end
        return true
    end)
end
if SS.Save and SS.Save.RegisterRuntime then
    SS.Save.RegisterRuntime("actor", "tmpAwakeUntil")
    SS.Save.RegisterRuntime("actor", "tmpNightShift")
end

---------------------------------------------------------------------------------------------------
-- Phone calls (registered once the phone module has loaded)
---------------------------------------------------------------------------------------------------
local phoneDone = false
function C.RegisterLate()
    SS.Tags.Attach("newspaper", "career_paper")
    SS.Tags.Attach("computer", "career_pc")
    if phoneDone or not (SS.Phone and SS.Phone.RegisterCall) then return end
    phoneDone = true
    SS.Phone.RegisterCall({
        id = "career_jobline", label = "Job Line: Today's Openings", category = "Services", order = 40,
        desc = "Hear today's job openings read out and take one on the spot.",
        test = function(world, caller) return searchTest(world, caller, nil) end,
        run = function(world, caller)
            local list = C.ShowOffers(world, caller, "phone")
            return true, string.format("The job line reads out %d openings.", #list)
        end,
    })
    SS.Phone.RegisterCall({
        id = "career_dayoff", label = "Call Work: Take a Day Off", category = "Services", order = 41,
        desc = "Use a vacation day to skip the next shift without a warning.",
        test = function(world, caller)
            local c = caller.career
            if not c then return false, "They do not have a job." end
            if not c.shift or c.shift.state == "away" then return false, "There is no shift coming up." end
            if (c.vacation or 0) <= 0 then return false, "No vacation days left." end
            return true
        end,
        run = function(world, caller) return C.TakeDayOff(world, caller) end,
    })
end

---------------------------------------------------------------------------------------------------
-- System
---------------------------------------------------------------------------------------------------
local function attach(world)
    C.RegisterLate()
    C.rt.board = {}
    if not isHome(world) then return end
    local gap = SS.Economy.Gap(world)
    for _, actor in ipairs(C.Members(world)) do
        -- a premade household's starting job (hood's person.starterJob), taken the first time it is played
        if type(actor.starterJob) == "table" then
            local sj = actor.starterJob
            actor.starterJob = nil
            if not actor.career then C.Hire(world, actor, sj.track, sj.level, "starter") end
        end
        local c = actor.career
        if c then
            local sh = c.shift
            if sh and sh.state == "waiting" then
                if gap > 0 or world.time > sh.start then
                    skip(world, actor, sh, "the household was not being played")
                else
                    -- saved during a pickup: the carpool is still at the curb
                    local lv = C.LevelDef(c.track, sh.level)
                    SS.Economy.AddVehicle(world, carpoolKey(actor.id), lv and lv.carpool or "hatchback", { parked = true })
                    -- (a childcare hold is saved on the shift: the same hold, checked again at the same time)
                    C.rt.board[actor.id] = { shift = sh.id, attempts = 0, blocked = sh.minding,
                        nextTry = sh.minding and (sh.mindCheck or world.time) or world.time }
                    if not C.HasEvents(world, actor.id, sh.id) then schedule(world, sh.start, "career.leave", actor.id, sh.id) end
                end
            elseif sh and sh.state == "planned" then
                if gap > 0 and sh.pickupAt < world.time then
                    skip(world, actor, sh, "the household was not being played")
                elseif not C.HasEvents(world, actor.id, sh.id) then
                    C.Plan(world, actor, world.time)
                end
            elseif sh and sh.state == "away" then
                if not C.HasEvents(world, actor.id, sh.id) then schedule(world, math.max(world.time, (sh.returnAt or world.time) + 2), "career.return", actor.id, sh.id) end
            elseif not sh then
                C.Plan(world, actor, world.time)
            end
        end
    end
end

local function tick(world, dt)
    if not isHome(world) then return end
    if next(C.rt.board) then tickBoarding(world) end
end

local function hour(world, h)
    if not isHome(world) then return end
    for _, actor in ipairs(C.Members(world)) do
        local c = actor.career
        if c and c.pending and world.time >= (c.pending.untilT or 0) then C.ResolveChance(world, actor, nil, "auto") end
    end
end

SS.Sim.Register({ name = "career", order = 42, attach = attach, tick = tick, hour = hour })

SS.On("scheduled", function(ev, world)
    if not world or type(ev.kind) ~= "string" or ev.kind:sub(1, 7) ~= "career." or not ev.data then return end
    if not isHome(world) then return end
    local k = ev.kind
    if k == "career.wake" then onWake(world, ev)
    elseif k == "career.pickup" then onPickup(world, ev)
    elseif k == "career.leave" then onLeave(world, ev)
    elseif k == "career.chance" then onChance(world, ev)
    elseif k == "career.return" then onReturn(world, ev) end
end)

---------------------------------------------------------------------------------------------------
-- Save validation: damaged career records are repaired or dropped with a reason.
---------------------------------------------------------------------------------------------------
if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        for id, r in pairs(root.residents or {}) do
            if type(r) == "table" and r.career ~= nil then
                local c = r.career
                if type(c) ~= "table" or not C.LevelDef(c.track, c.level) then
                    r.career = nil
                    problems[#problems + 1] = "dropped an unknown job from " .. tostring(id)
                else
                    c.perf = clamp(tonumber(c.perf) or 0, -100, 100)
                    c.misses = type(c.misses) == "table" and c.misses or {}
                    c.lates = type(c.lates) == "table" and c.lates or {}
                    c.history = type(c.history) == "table" and c.history or {}
                    c.recent = type(c.recent) == "table" and c.recent or {}
                    c.warnings = tonumber(c.warnings) or 0
                    c.vacation = tonumber(c.vacation) or 0
                    c.daysWorked = tonumber(c.daysWorked) or 0
                    c.shiftsAtLevel = tonumber(c.shiftsAtLevel) or 0
                    c.nextId = tonumber(c.nextId) or 0
                    if c.shift ~= nil and (type(c.shift) ~= "table" or type(c.shift.id) ~= "number") then
                        c.shift = nil
                        problems[#problems + 1] = "reset a damaged shift for " .. tostring(id)
                    end
                    if c.pending ~= nil and (type(c.pending) ~= "table" or not C.ChanceDef(c.pending.id)) then c.pending = nil end
                end
            end
        end
    end)
end
