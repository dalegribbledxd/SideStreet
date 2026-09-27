-- SideStreet needs: passive change, exertion, room evaluation, warnings, reactions, mood.
-- Owner: household-core. Scale -100..+100 (0 neutral); thresholds and rates in Data/Tuning.lua.
local _, SS = ...
local T = SS.Tuning
local W = SS.World
local U = SS.U
local N = {}
SS.Needs = N

function N.Clamp(actor)
    actor.needs = actor.needs or {}
    for _, k in ipairs(T.needs) do actor.needs[k] = U.clamp(tonumber(actor.needs[k]) or 0, -100, 100) end
end

function N.Add(actor, need, amount)
    actor.needs[need] = U.clamp((actor.needs[need] or 0) + amount, -100, 100)
end

-- Level of a need: "ok" | "warn" | "urgent" | "critical".
function N.Status(actor, need)
    local v = actor.needs[need] or 0
    if v <= (T.critical[need] or -80) then return "critical" end
    if v < T.urgent then return "urgent" end
    if v <= (T.warn[need] or -30) then return "warn" end
    return "ok"
end

-- Room scores are cached per room; the cache refreshes every Tuning.room.cacheMinutes or when
-- the room's contents change (World.Touch / Rebuild bump SS.RT.env).
-- dark = true: the score without its light term (someone asleep does not mind a dark room).
local cache = {}
local BREAKDOWN = {} -- refilled by every room-score refresh (read at once)
local function roomScore(world, level, roomId, dark)
    local key = level * 1000 + roomId
    local c = cache[key]
    local rt = SS.RT
    if not (c and c.env == rt.env and c.ver == rt.version and world.time - c.t < T.room.cacheMinutes and world.time >= c.t) then
        -- one breakdown gives both (W.RoomScore is its total; other modules adjust the breakdown)
        local v, light = 0, 0
        if W.RoomInfo(level, roomId) then
            local b = W.RoomBreakdown(world, level, roomId, BREAKDOWN)
            v, light = b.total or 0, b.light or 0
        end
        if not c then c = {}; cache[key] = c end
        c.t, c.v, c.env, c.ver = world.time, v, rt.env, rt.version
        c.dark = SS.U.clamp(v - light, -100, 100)
    end
    if dark then return c.dark end
    return c.v
end
N.RoomScoreCached = roomScore

-- Rate hooks: systems adjust passive change (life stage, traits, pets, illness, weather).
--   N.RegisterRateHook(fn(world, actor, need, rate) -> rate)   rate is per sim-hour
N.rateHooks = {}
function N.RegisterRateHook(fn) N.rateHooks[#N.rateHooks + 1] = fn end

-- Reactions ("feel") ---------------------------------------------------------------------
-- Short-lived emotional reactions with a mood effect (embarrassment, frustration, bathroom
-- annoyance, grogginess, pride; grief and jealousy for other modules). Saved on the person
-- (`feel`), capped at Tuning.feelCap: when full, the weakest reaction gives way.
function N.Feel(world, actor, kind, mult)
    local def = T.feel[kind]
    if not def or not actor.needs then return end
    actor.feel = actor.feel or {}
    local list = actor.feel
    local untilT = world.time + def.dur
    for n = 1, #list do
        if list[n].kind == kind then list[n].untilT = math.max(list[n].untilT, untilT); list[n].m = math.max(list[n].m or 1, mult or 1); return list[n] end
    end
    if #list >= T.feelCap then
        -- the weakest reaction (mood effect x time left) gives way; that may be the new one
        local function weight(k, u, m) return math.abs(T.feel[k] and T.feel[k].mood or 0) * (m or 1) * math.max(0, u - world.time) end
        local weakest, wv = nil, weight(kind, untilT, mult)
        for n = 1, #list do
            local v = weight(list[n].kind, list[n].untilT, list[n].m)
            if v < wv then weakest, wv = n, v end
        end
        if not weakest then return nil end
        table.remove(list, weakest)
    end
    local f = { kind = kind, untilT = untilT, m = mult or 1 }
    list[#list + 1] = f
    SS.Emit("feel", world, actor, kind)
    return f
end

function N.Feeling(actor, kind)
    for _, f in ipairs(actor.feel or {}) do if f.kind == kind then return f end end
end

local function expireFeel(world, actor)
    local list = actor.feel
    if not list then return end
    for n = #list, 1, -1 do
        if list[n].untilT <= world.time then table.remove(list, n) end
    end
end

-- Warnings: a thought balloon at "warn", a player notice at "critical" (household members),
-- each at most once per Tuning.warnCooldown per need. Emits needWarning(world, actor, need, status).
local RANK = { ok = 0, warn = 1, urgent = 2, critical = 3 }
local TOLERANT = { room = true, social = true, hygiene = true, fun = true }
local function warnings(world, actor)
    if actor.role or actor.noNeeds then return end
    local tmp = actor.tmp
    if not tmp then tmp = {}; actor.tmp = tmp end
    local warned = tmp.warned
    if not warned then warned = {}; tmp.warned = warned end
    local cool = actor.cool
    if not cool then cool = {}; actor.cool = cool end
    local P = SS.Personality
    local tol = P and P.Tolerance
    for n = 1, #T.needs do
        local need = T.needs[n]
        local st = N.Status(actor, need)
        local rank = RANK[st]
        -- personality tolerances (social module): a messy person puts up with a grim room until
        -- about -60, a neat one minds at +20; loneliness likewise by outgoingness. Critical always warns.
        if tol and TOLERANT[need] and rank < 3 then
            local limit = tol(actor, need)
            if limit then
                if (actor.needs[need] or 0) <= limit then
                    if rank == 0 then rank, st = 1, "warn" end
                else
                    rank, st = 0, "ok"
                end
            end
        end
        local prev = warned[need] or 0
        if rank == 0 then
            warned[need] = nil
        elseif rank < prev then
            warned[need] = rank
        elseif rank > prev or (cool["warn:" .. need] or -1e9) <= world.time then
            warned[need] = rank
            cool["warn:" .. need] = world.time + T.warnCooldown
            local texts = T.warnText[need]
            local txt = texts and string.format(texts[rank == 3 and 2 or 1], actor.name or "Someone")
            if not actor.balloon or actor.balloon.kind ~= "speech" then
                actor.balloon = { icon = need, text = rank == 3 and txt or nil, untilT = world.time + 15, kind = rank == 3 and "alert" or "thought" }
            end
            if rank == 3 and txt and world.household and actor.householdId == world.household.id then
                SS.Emit("notice", actor, txt)
            end
            if need == "room" and SS.Actions and SS.Actions.Say and actor.needs.room then
                SS.Actions.Say(world, actor, "room_filthy", { roomScore = math.floor(actor.needs.room) }, "room")
            end
            SS.Emit("needWarning", world, actor, need, st)
        end
    end
end

function N.Tick(world, actor, dt)
    local hours = dt / 60
    local decay = (actor.decay and (actor.sleeping and actor.decay.sleep or actor.decay.awake))
        or (actor.sleeping and T.decaySleep or T.decayAwake)
    local hooks = N.rateHooks
    local age = T.ageDecay[actor.age or "adult"]
    local ex = 0
    local act = actor.act
    if act and act.phase == "perform" then
        local ia = SS.Interactions[act.iid]
        ex = ia and ia.exertion or 0
    end
    local needs = actor.needs
    for need, rate in pairs(decay) do
        if actor.walking and T.walkingExtra[need] then rate = rate + T.walkingExtra[need] end
        if ex > 0 and T.exertion[need] then rate = rate + T.exertion[need] * ex end
        if age and age[need] and rate < 0 then rate = rate * age[need] end
        for n = 1, #hooks do rate = hooks[n](world, actor, need, rate) end
        local v = needs[need] + rate * hours
        if v < -100 then v = -100 elseif v > 100 then v = 100 end
        needs[need] = v
    end
    -- Room moves toward the score of the room the actor is actually in; asleep, how dark the room
    -- is does not count (a dark bedroom at night is right).
    local lv = actor.level or 0
    local room = W.RoomAt(world, lv, math.floor(actor.x), math.floor(actor.y))
    local target = roomScore(world, lv, room, actor.sleeping)
    local cur = needs.room or 0
    local step = T.roomApproach * hours
    if math.abs(target - cur) <= step then needs.room = target
    elseif target > cur then needs.room = cur + step
    else needs.room = cur - step end
    if actor.feel then expireFeel(world, actor) end
    N.TrackTrend(actor, hours)
    warnings(world, actor)
end

-- Change direction for the needs panel: the smoothed actual change in points per sim hour since
-- the previous tick (passive change, activities, events alike). Runtime only (actor.tmp.trend).
function N.TrackTrend(actor, hours)
    if hours <= 0 then return end
    local tmp = actor.tmp
    if not tmp then tmp = {}; actor.tmp = tmp end
    local last, tr = tmp.lastNeeds, tmp.trend
    if not last then last = {}; tmp.lastNeeds = last end
    if not tr then tr = {}; tmp.trend = tr end
    local k = math.min(1, hours / T.trendSmooth)
    local needs = actor.needs
    for n = 1, #T.needs do
        local need = T.needs[n]
        local v = needs[need] or 0
        local p = last[need]
        if p then
            local r = (v - p) / hours
            local old = tr[need]
            tr[need] = old and (old + (r - old) * k) or r
        end
        last[need] = v
    end
end

-- N.Trend(actor, need) -> points per sim hour, "up" | "down" | "steady" (deadband Tuning.trendDeadband)
function N.Trend(actor, need)
    local r = actor.tmp and actor.tmp.trend and actor.tmp.trend[need] or 0
    if r > T.trendDeadband then return r, "up" end
    if r < -T.trendDeadband then return r, "down" end
    return r, "steady"
end

-- Personality-weighted mood weight for a need. The social module owns personality: when it
-- provides SS.Personality.NeedWeight(actor, need) that is the one source (Tuning.moodTrait is the
-- fallback before integration), so traits never count twice.
local function weight(actor, need)
    local w = T.moodWeight[need] or 1
    local P = SS.Personality
    if P and P.NeedWeight then return w * (P.NeedWeight(actor, need) or 1) end
    local p = actor.personality
    if p then
        for trait, coefs in pairs(T.moodTrait) do
            local c = coefs[need]
            if c and p[trait] then w = w * math.max(0.2, 1 + c * (p[trait] - 5)) end
        end
    end
    return w
end
N.Weight = weight

-- Mood: weighted average where negative values are amplified, so one desperate need cannot be
-- cancelled by a nice room; personality shifts weights; short reactions add on top.
function N.Mood(actor, world)
    local sum, wsum = 0, 0
    for _, k in ipairs(T.needs) do
        local v = actor.needs[k] or 0
        local w = weight(actor, k)
        local term = v
        if v < 0 then
            local sev = -v / 100
            term = v * (1 + 2 * sev * sev)
            w = w * (1 + 3 * sev)
        end
        sum = sum + term * w
        wsum = wsum + w
    end
    local mood = sum / wsum
    if actor.feel then
        local now = world and world.time or (SS.Sim and SS.Sim.world and SS.Sim.world.time) or 0
        for _, f in ipairs(actor.feel) do
            local def = T.feel[f.kind]
            if def and f.untilT > now then mood = mood + def.mood * (f.m or 1) end
        end
    end
    return U.clamp(mood, -100, 100)
end

-- Overall mood summary for the panel: N.MoodSummary(actor, world) -> mood, label, worst need
-- (the need dragging mood down most, or nil when nothing is below its warning threshold).
function N.MoodSummary(actor, world)
    local mood = N.Mood(actor, world)
    local label = T.moodLabels[#T.moodLabels][2]
    for _, row in ipairs(T.moodLabels) do
        if mood > row[1] then label = row[2]; break end
    end
    local worst, wv = nil, nil
    for _, k in ipairs(T.needs) do
        local v = actor.needs[k] or 0
        if v <= (T.warn[k] or -30) then
            local pull = v * weight(actor, k)
            if not wv or pull < wv then worst, wv = k, pull end
        end
    end
    return mood, label, worst
end

-- Worst need (for warnings / thought bubbles).
function N.Worst(actor)
    local worst, wv = nil, 1e9
    for _, k in ipairs(T.needs) do
        if actor.needs[k] < wv then worst, wv = k, actor.needs[k] end
    end
    return worst, wv
end

-- Fun repetition: the same activity loses appeal when repeated, recovering over time
-- (Tuning.repetition). Runtime memory (actor.tmp.rep). R (optional) is another parameter set
-- { step, floor, halfLife } for other diminishing returns (snacks: Tuning.food.snackRepeat); use
-- the same R for a key in both calls.
function N.RepFactor(world, actor, key, R)
    local r = actor.tmp and actor.tmp.rep and actor.tmp.rep[key]
    if not r then return 1 end
    R = R or T.repetition
    local n = r.n * 0.5 ^ ((world.time - r.t) / R.halfLife)
    return math.max(R.floor, 1 - R.step * n)
end

function N.RepAdd(world, actor, key, amount, R)
    actor.tmp = actor.tmp or {}
    actor.tmp.rep = actor.tmp.rep or {}
    local r = actor.tmp.rep[key]
    R = R or T.repetition
    if r then
        r.n = r.n * 0.5 ^ ((world.time - r.t) / R.halfLife) + (amount or 1)
        r.t = world.time
    else
        actor.tmp.rep[key] = { n = amount or 1, t = world.time }
    end
end
