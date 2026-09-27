-- Leisure and learning: television channels, radio/stereo stations and dancing, computers,
-- books and study, games for one or two (chess, board games, pool, darts, arcade, pinball),
-- instruments, exercise, DJ booth, telescope, mirror practice, outfits, admiring art, and the
-- money-making crafts (painting at an easel, woodwork at a workbench). Owner: household-core.
--
-- Each activity has its own pose, fun, skill practice (SS.Skills.Gain through the executor's
-- `skill` field), personality fit (`traits`), interest topic, capacity (slots, viewer seats and
-- standing spots, or a spot radius with a cap) and, when shared, relationship effects
-- (SS.Social.Change) plus a little social need.
local _, SS = ...
local T, W, G, U = SS.Tuning, SS.World, SS.Grid, SS.U
local A, M, C = SS.Actions, SS.Maintenance, SS.Chains
local I = SS.Interactions
local L = {}
SS.Leisure = L

local function level(o) return o and o.level or 0 end
local function isMember(world, actor) return A.IsMember(world, actor) end
local function skillOf(actor, name) return (SS.Skills and SS.Skills.Level and SS.Skills.Level(actor, name)) or 0 end
local function trait(actor, name) return actor.personality and actor.personality[name] or 5 end
local ADULT_CHILD = { adult = true, child = true }

-- Shared activities ------------------------------------------------------------------------
-- Other people doing one of `iids` on the same object (or within `radius` tiles of it), in actor
-- id order. `into` (optional) is a list to fill and return instead of a new one; the per-tick
-- callers below pass their own scratch list, so a shared activity allocates nothing per tick.
local function isPartner(b, actor, obj, iids, radius)
    local act = b and b ~= actor and b.act
    if not (act and act.phase == "perform" and iids[act.iid]) then return false end
    if act.oid == (obj and obj.id) then return true end
    return radius and obj and (b.level or 0) == level(obj)
        and math.abs(b.x - (obj.x + 0.5)) + math.abs(b.y - (obj.y + 0.5)) <= radius or false
end

function L.Partners(world, actor, obj, iids, radius, into)
    local out = into or {}
    for n = #out, 1, -1 do out[n] = nil end
    local ids = SS.Sim.StepOrder(world)
    for n = 1, #ids do
        local b = world.actors[ids[n]]
        if isPartner(b, actor, obj, iids, radius) then out[#out + 1] = b end
    end
    return out
end

-- How many partners (no list).
function L.CountPartners(world, actor, obj, iids, radius)
    local c = 0
    for _, b in pairs(world.actors) do
        if isPartner(b, actor, obj, iids, radius) then c = c + 1 end
    end
    return c
end

-- Company while doing something together: a little social need, more fun, and every
-- Tuning.shareRel.every minutes a small relationship gain both ways (social module's store).
function L.ShareTick(world, actor, act, obj, dt, iids, radius)
    act.mult = act.mult or {}
    local count = L.CountPartners(world, actor, obj, iids, radius)
    if count == 0 then
        act.mult.fun = act.data.soloFun or 1
        act.data.shared = nil
        return 0
    end
    act.mult.fun = (act.data.soloFun or 1) * 1.25
    act.data.shared = count
    SS.Needs.Add(actor, "social", 6 * dt / 60)
    act.data.shareT = (act.data.shareT or 0) + dt
    if act.data.shareT >= T.shareRel.every then
        act.data.shareT = 0
        if SS.Social and SS.Social.Change then
            -- a fresh list here (rare: every 30 minutes), so a Change handler may call back safely
            for _, b in ipairs(L.Partners(world, actor, obj, iids, radius)) do
                SS.Social.Change(world, actor.id, b.id, T.shareRel.daily, T.shareRel.life)
            end
        end
        SS.Emit("sharedActivity", world, actor, act.iid, count)
    end
    return count
end

local function set(list) local s = {} for _, v in ipairs(list) do s[v] = true end return s end

-- Television --------------------------------------------------------------------------------
function L.Channel(id)
    for _, ch in ipairs(T.tvChannels) do if ch.id == id then return ch end end
end

-- How much this person enjoys a channel (fun per hour).
function L.ChannelFun(actor, ch)
    local fun = ((actor.age == "child") and ch.funChild) or ch.fun
    -- a show about something you love (or loathe) matters more than a generic activity's topic
    local iv = ch.topic and actor.interests and actor.interests[ch.topic]
    local f = fun * (iv and U.clamp(1 + (iv - 5) * T.channelInterest, 0.4, 1.8) or 1)
    if ch.playful then f = f * U.clamp(1 + (trait(actor, "playful") - 5) * 0.06 * ch.playful, 0.6, 1.5) end
    if ch.workout then f = f * U.clamp(1 + (trait(actor, "active") - 5) * 0.08, 0.5, 1.6) end
    if ch.skill and ch.skill.logic then f = f * U.clamp(1 + (5 - trait(actor, "playful")) * 0.05, 0.7, 1.3) end
    return f
end

function L.BestChannel(actor)
    local best, bestF
    for _, ch in ipairs(T.tvChannels) do
        local f = L.ChannelFun(actor, ch)
        if not bestF or f > bestF then best, bestF = ch, f end
    end
    return best
end

local TV_IIDS = set({ "watchtv", "tv_workout" })

-- The channel someone will watch: the order's choice, what's already on, or their favourite.
local function channelFor(world, actor, obj, data)
    if data and data.channel and L.Channel(data.channel) then return L.Channel(data.channel) end
    if obj and obj.state and obj.state.on and obj.channel and L.Channel(obj.channel) then return L.Channel(obj.channel) end
    return L.BestChannel(actor)
end
L.ChannelFor = channelFor

-- Programme or station fun on this particular set/speakers: the catalogue's `rates.fun` over the
-- starter model's (Tuning.mediaRefFun[kind]) is added; objects without a fun rate change nothing.
function L.EquipmentFun(def, base, kind)
    local r = def and def.rates and def.rates.fun
    local ref = T.mediaRefFun and T.mediaRefFun[kind]
    if type(r) ~= "number" or not ref then return base end
    return math.max(base * (T.mediaMinShare or 0.4), base + (r - ref))
end

local function setWatchRates(actor, act, ch, obj)
    act.data.channel = ch.id
    act.rates = { fun = L.EquipmentFun(obj and SS.Objects[obj.def], L.ChannelFun(actor, ch), "tv") }
    act.skill = ch.skill
    act.data.soloFun = 1
end

I.watchtv.advertise = function(world, actor, obj)
    local ch = channelFor(world, actor, obj, nil)
    return A.Advert("l138", "fun", 12 + L.EquipmentFun(SS.Objects[obj.def], L.ChannelFun(actor, ch), "tv") * 1.1, "comfort", 8)
end
I.watchtv.onStart = function(world, actor, act, obj)
    if not obj then return end
    local ch = channelFor(world, actor, obj, act.data)
    obj.channel = ch.id
    setWatchRates(actor, act, ch, obj)
    SS.Emit("lotChanged", "state", obj.id)
end
I.watchtv.onResume = function(world, actor, act, obj)
    local ch = L.Channel(obj and obj.channel or act.data.channel) or L.BestChannel(actor)
    setWatchRates(actor, act, ch, obj)
end
I.watchtv.onTick = function(world, actor, act, obj, dt)
    if not obj then return end
    if obj.channel ~= act.data.channel then
        local ch = L.Channel(obj.channel)
        if ch then setWatchRates(actor, act, ch, obj) end
    end
    L.ShareTick(world, actor, act, obj, dt, TV_IIDS)
end
I.watchtv.topic = "films"

I.tv_workout = {
    label = "Work Out to the TV", category = "Fun", slot = "spot", radius = 3, capacity = 3, pose = "exercise", maxDur = 60,
    exertion = 2, leisure = true, usesState = "on", group = true, ages = ADULT_CHILD, topic = "fitness",
    rate = { fun = 12 }, skill = { body = 0.5 }, traits = { active = 1 },
    advert = { fun = 18 },
    test = function(world, actor, obj)
        local def = SS.Objects[obj.def]
        if obj.state and obj.state.on and obj.channel and obj.channel ~= "fitness" and obj.watchers and next(obj.watchers) then
            return false, "Someone is watching something else."
        end
        return true
    end,
    onStart = function(world, actor, act, obj)
        if obj then obj.channel = "fitness"; SS.Emit("lotChanged", "state", obj.id) end
        act.data.soloFun = 1
    end,
    onTick = function(world, actor, act, obj, dt) L.ShareTick(world, actor, act, obj, dt, TV_IIDS) end,
}

I.change_channel = {
    label = "Change Channel", category = "Fun", slot = "viewer", pose = "use", dur = 0.2, manualOnly = true, noWear = true,
    ages = ADULT_CHILD,
    test = function(world, actor, obj, data)
        if not (data and L.Channel(data.channel)) then return false, "Pick a channel." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj then return end
        obj.channel = act.data.channel
        obj.state = obj.state or {}
        SS.Emit("lotChanged", "state", obj.id)
        local ch = L.Channel(obj.channel)
        A.Message(world, actor, "Now showing: " .. ch.name .. ".", "fun")
    end,
}
-- change_channel resolves like a viewer but only needs a moment in front of the set
I.change_channel.slot = { "front2", "front", "use" }

I.tv_off = {
    label = "Turn Off", category = "Fun", slot = { "front2", "front", "use" }, pose = "use", dur = 0.2, manualOnly = true, noWear = true,
    requireState = { on = true }, requireText = "It's already off.", ages = ADULT_CHILD,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj then return end
        obj.state.on = false
        obj.keepOn = nil
        for _, id in ipairs(SS.Sim.ActorIds(world)) do
            local b = world.actors[id]
            if b and b.act and b.act.oid == obj.id and b ~= actor then A.Interrupt(world, b, "The set was switched off.") end
        end
        SS.Emit("lotChanged", "state", obj.id)
    end,
}

-- Music: stereo and radio stations, listening and dancing ----------------------------------
function L.Station(id)
    for _, st in ipairs(T.stations) do if st.id == id then return st end end
end

function L.StationFun(actor, st, dancing)
    local f = st.fun * A.InterestFit(actor, "music")
    if dancing then f = f * (st.dance or 1) * U.clamp(1 + (trait(actor, "active") - 5) * 0.06, 0.6, 1.5) end
    return f
end

function L.BestStation(actor, dancing)
    local best, bestF
    for _, st in ipairs(T.stations) do
        local f = L.StationFun(actor, st, dancing)
        if not bestF or f > bestF then best, bestF = st, f end
    end
    return best
end

local MUSIC_IIDS = set({ "listen_music", "dance", "dj_spin" })
local DJ_IIDS = set({ "dj_spin" })
local MUSIC_TAGS = { "stereo", "radio", "dj" }
local CROWD_IIDS = set({ "dance", "listen_music" })

-- Music source for a dance floor: a stereo/radio/DJ booth switched on in the same room.
function L.MusicInRoom(world, obj)
    local room = W.ObjRoom(world, obj)
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if def and o.state and o.state.on and not o.state.broken and level(o) == level(obj) and W.ObjRoom(world, o) == room
            and C.HasAnyTag(def, MUSIC_TAGS) then
            return o
        end
    end
end

local function stationFor(world, actor, obj, data, dancing)
    if data and data.station and L.Station(data.station) then return L.Station(data.station) end
    local src = obj
    local def = obj and SS.Objects[obj.def]
    if def and not C.HasAnyTag(def, MUSIC_TAGS) then src = L.MusicInRoom(world, obj) end
    if src and src.state and src.state.on and src.station and L.Station(src.station) then return L.Station(src.station) end
    return L.BestStation(actor, dancing)
end

local function isMusicSource(def) return C.HasAnyTag(def, MUSIC_TAGS) end

local function musicStart(world, actor, act, obj, dancing)
    local def = obj and SS.Objects[obj.def]
    local st = stationFor(world, actor, obj, act.data, dancing)
    if obj and isMusicSource(def) then obj.station = st.id; SS.Emit("lotChanged", "state", obj.id) end
    act.data.station = st.id
    local src = (obj and isMusicSource(def)) and obj or (obj and L.MusicInRoom(world, obj))
    act.rates = { fun = L.EquipmentFun(src and SS.Objects[src.def], L.StationFun(actor, st, dancing), "music") }
    if dancing then act.rates.fun = act.rates.fun * 1.1 end
    act.skill = dancing and { body = 0.15 } or st.skill
    act.data.soloFun = 1
end

local function musicTick(world, actor, act, obj, dt, dancing)
    local def = obj and SS.Objects[obj.def]
    local src = (obj and isMusicSource(def)) and obj or (obj and L.MusicInRoom(world, obj))
    if not src or not (src.state and src.state.on) then
        if not (obj and isMusicSource(def)) then act.failWhy = "The music stopped." end
        return
    end
    if src.station and src.station ~= act.data.station then musicStart(world, actor, act, src, dancing) end
    -- a DJ spinning in the room lifts the dance floor
    act.data.soloFun = (L.CountPartners(world, actor, src, DJ_IIDS, 6) > 0) and 1.3 or 1
    L.ShareTick(world, actor, act, obj, dt, MUSIC_IIDS, 4)
end

I.listen_music = {
    label = "Listen to Music", category = "Fun", slot = "spot", radius = 3, pose = "idle", maxDur = 90, leisure = true,
    usesState = "on", group = true, ages = ADULT_CHILD, topic = "music", untilFull = "fun",
    rate = { fun = 22 }, traits = { playful = 0.2, active = -0.2 },
    advertise = function(world, actor, obj)
        local st = stationFor(world, actor, obj, nil, false)
        return A.Advert("l294", "fun", 8 + L.StationFun(actor, st, false))
    end,
    onStart = function(world, actor, act, obj) musicStart(world, actor, act, obj, false) end,
    onResume = function(world, actor, act, obj) musicStart(world, actor, act, obj, false) end,
    onTick = function(world, actor, act, obj, dt) musicTick(world, actor, act, obj, dt, false) end,
}

I.dance = {
    label = "Dance", category = "Fun", slot = "spot", radius = 3, pose = "dance", maxDur = 60, leisure = true, exertion = 1,
    group = true, ages = ADULT_CHILD, topic = "music", untilFull = "fun", noise = 1,
    rate = { fun = 28 }, traits = { outgoing = 0.6, active = 0.4, playful = 0.3 },
    test = function(world, actor, obj)
        local def = SS.Objects[obj.def]
        if not isMusicSource(def) and not L.MusicInRoom(world, obj) then return false, "There's no music playing." end
        return true
    end,
    advertise = function(world, actor, obj)
        local st = stationFor(world, actor, obj, nil, true)
        return A.Advert("l312", "fun", 10 + L.StationFun(actor, st, true))
    end,
    onStart = function(world, actor, act, obj)
        local def = obj and SS.Objects[obj.def]
        if obj and isMusicSource(def) then
            obj.state = obj.state or {}
            obj.state.on = true
            obj.watchers = obj.watchers or {}
            obj.watchers[actor.id] = true
            act.target.viewer = obj.id
        end
        musicStart(world, actor, act, obj, true)
    end,
    onResume = function(world, actor, act, obj)
        local def = obj and SS.Objects[obj.def]
        if obj and isMusicSource(def) then
            obj.state = obj.state or {}
            obj.state.on = true
            obj.watchers = obj.watchers or {}
            obj.watchers[actor.id] = true
            act.target.viewer = obj.id
        end
        musicStart(world, actor, act, obj, true)
    end,
    onTick = function(world, actor, act, obj, dt) musicTick(world, actor, act, obj, dt, true) end,
}

I.music_on = {
    label = "Turn On Music", category = "Fun", slot = "around", pose = "use", dur = 0.2, manualOnly = true, noWear = true,
    requireState = { on = false }, requireText = "It's already playing.", ages = ADULT_CHILD,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj then return end
        local st = stationFor(world, actor, obj, act.data, false)
        obj.state = obj.state or {}
        obj.state.on, obj.station, obj.keepOn = true, st.id, true
        SS.Emit("lotChanged", "state", obj.id)
        A.Message(world, actor, "Playing " .. st.name .. ".", "fun")
    end,
}

I.change_station = {
    label = "Change Station", category = "Fun", slot = "around", pose = "use", dur = 0.2, manualOnly = true, noWear = true,
    ages = ADULT_CHILD,
    test = function(world, actor, obj, data)
        if not (data and L.Station(data.station)) then return false, "Pick a station." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj then return end
        obj.station = act.data.station
        SS.Emit("lotChanged", "state", obj.id)
        A.Message(world, actor, "Now playing: " .. L.Station(obj.station).name .. ".", "fun")
    end,
}

I.music_off = {
    label = "Turn Off Music", category = "Fun", slot = "around", pose = "use", dur = 0.2, manualOnly = true, noWear = true,
    requireState = { on = true }, requireText = "It's not playing.", ages = ADULT_CHILD,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj then return end
        obj.state.on, obj.keepOn = false, nil
        for _, id in ipairs(SS.Sim.ActorIds(world)) do
            local b = world.actors[id]
            local ia = b and b.act and I[b.act.iid]
            if b and b ~= actor and b.act and MUSIC_IIDS[b.act.iid] then A.Interrupt(world, b, "The music stopped.") end
        end
        SS.Emit("lotChanged", "state", obj.id)
    end,
}

I.dj_spin = {
    label = "Spin Records", category = "Fun", slot = { "use", "front", "stand" }, pose = "play", maxDur = 90, leisure = true,
    usesState = "on", ages = { adult = true }, topic = "music", noise = 2,
    rate = { fun = 26 }, skill = { creativity = 0.3 }, traits = { outgoing = 0.7, playful = 0.4 },
    advert = { fun = 30 },
    onStart = function(world, actor, act, obj)
        local st = stationFor(world, actor, obj, act.data, true)
        obj.station = st.id
        act.data.soloFun = 1
    end,
    onTick = function(world, actor, act, obj, dt)
        -- spinning for a crowd is better
        local crowd = L.CountPartners(world, actor, obj, CROWD_IIDS, 6)
        act.mult = act.mult or {}
        act.mult.fun = 1 + math.min(0.5, crowd * 0.15)
    end,
}

-- Computer ---------------------------------------------------------------------------------
I.play_computer = {
    label = "Play Computer Games", category = "Fun", slot = { "seat", "use", "front" }, pose = "type", maxDur = 120, leisure = true,
    untilFull = "fun", ages = ADULT_CHILD, topic = "games",
    rate = { fun = 30 }, skill = { logic = 0.05 }, traits = { playful = 0.5, active = -0.4 }, advert = { fun = 40 },
}
I.chat_online = {
    label = "Chat Online", category = "Social", slot = { "seat", "use", "front" }, pose = "type", maxDur = 60, leisure = true,
    ages = ADULT_CHILD, topic = "games",
    rate = { social = 10, fun = 8 }, traits = { outgoing = 0.6 }, advert = { social = 18, fun = 6 },
}
I.study_computer = {
    label = "Research Online", category = "Skills", slot = { "seat", "use", "front" }, pose = "type", maxDur = 90, leisure = true,
    ages = ADULT_CHILD, topic = "science",
    rate = { fun = 4 }, skill = { logic = 0.6 }, traits = { playful = -0.6, active = -0.2 },
    advertise = function(world, actor) return A.Advert("l415", "fun", 6 + math.max(0, 5 - trait(actor, "playful")) * 3) end,
}

-- Books and study ----------------------------------------------------------------------------
L.STUDY = { cooking = "Cooking", mechanical = "Mechanics", charisma = "Public Speaking", logic = "Logic Puzzles",
    creativity = "Art History", body = "Fitness" }
L.STUDY_ORDER = { "cooking", "mechanical", "charisma", "logic", "creativity", "body" }

-- A book borrowed to study carries its shelf's quality.skill (the catalogue's HC-3: a better
-- bookcase holds better books), since the reading happens on a seat, not at the shelf.
local function shelfFactor(obj)
    local f = SS.Actions.SkillFactor(obj and SS.Objects[obj.def])
    return f ~= 1 and f or nil
end

I.read_book = {
    label = "Read a Book", category = "Fun", slot = { "front", "use" }, pose = "use", dur = 0.5, ages = ADULT_CHILD,
    topic = "books", traits = { playful = -0.3, active = -0.3 }, leisure = true, givesSkill = true,
    estimate = function() return 45 end,
    test = function(world, actor) if actor.held then return false, "Hands are full." end return true end,
    advert = { fun = 26, comfort = 6 },
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or actor.held then return end
        C.Hold(world, actor, "book", { topic = act.data.skill and nil or "books", skill = act.data.skill, from = obj and obj.id,
            skillMult = act.data.skill and shelfFactor(obj) or nil })
    end,
    next = function(world, actor) return L.ReadOrder(world, actor) end,
}

I.study_skill = {
    label = "Study", category = "Skills", slot = { "front", "use" }, pose = "use", dur = 0.5, ages = ADULT_CHILD,
    leisure = true, traits = { playful = -0.4 }, givesSkill = true,
    test = function(world, actor, obj, data)
        if actor.held then return false, "Hands are full." end
        return true
    end,
    advertise = function(world, actor)
        return A.Advert("l444", "fun", 5 + math.max(0, 5 - trait(actor, "playful")) * 2.5)
    end,
    onStart = function(world, actor, act)
        if not act.data.skill then
            -- the skill this person is furthest behind on among cooking/mechanical/charisma
            local best, bestV
            for _, k in ipairs(L.STUDY_ORDER) do
                local v = skillOf(actor, k)
                if not bestV or v < bestV then best, bestV = k, v end
            end
            act.data.skill = best
        end
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or actor.held then return end
        C.Hold(world, actor, "book", { skill = act.data.skill or "logic", from = obj and obj.id, skillMult = shelfFactor(obj) })
    end,
    next = function(world, actor) return L.ReadOrder(world, actor) end,
}

-- Read the held book on a seat (or standing if there is none).
function L.ReadOrder(world, actor)
    if not C.Held(actor, "book") then return nil end
    local best, bestD
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if def and (def.seat or C.HasAnyTag(def, { "seat", "sofa" })) and A.Available(world, actor, o, "read_seat") then
            local d = math.abs(o.x + 0.5 - actor.x) + math.abs(o.y + 0.5 - actor.y) + math.abs(level(o) - (actor.level or 0)) * T.levelCost
            if SS.Tags.Has(def, "sofa") or (def.rates and (def.rates.comfort or 0) >= 30) then d = d - 3 end
            if not bestD or d < bestD then best, bestD = o, d end
        end
    end
    if best then return { oid = best.id, iid = "read_seat" } end
    return { iid = "read_here" }
end

local function readSetup(world, actor, act)
    local h = C.Held(actor, "book")
    if not h then return false, "No book in hand." end
    act.data.skill = h.skill
    if h.skill then
        act.rates = { fun = 6 }
        act.skill = { [h.skill] = 0.7 * (tonumber(h.skillMult) or 1) }
    else
        act.rates = { fun = 20 * A.InterestFit(actor, "books") }
        act.skill = nil
    end
    actor.carry = "book"
end

local function afterReading(world, actor, act, status)
    local h = C.Held(actor, "book")
    if not h or status ~= "done" then return end
    local neat = trait(actor, "neat")
    if SS.Random(world, "tidy") < 0.2 + 0.08 * neat then act.data.putBack = true
    else C.SettleHeld(world, actor, "left") end
end

I.read_seat = {
    usesHeld = { book = true },
    label = "Read", category = "Fun", hidden = true, slot = "seat", pose = "read", maxDur = 90, leisure = true,
    ages = ADULT_CHILD, useTags = { "seat", "sofa" }, untilFull = nil,
    test = function(world, actor) if not C.Held(actor, "book") then return false, "No book in hand." end return true end,
    onStart = function(world, actor, act) return readSetup(world, actor, act) end,
    onResume = function(world, actor, act) readSetup(world, actor, act) end,
    onTick = function(world, actor, act)
        if not act.data.skill and (actor.needs.fun or 0) >= 98 then act.complete = true end
    end,
    onEnd = function(world, actor, act, obj, status) afterReading(world, actor, act, status) end,
    next = function(world, actor, act) if act.data.putBack then local o = L.ReturnBookOrder(world, actor); if o then o.optional = true end; return o end end,
}
I.read_here = {
    usesHeld = { book = true },
    label = "Read Standing", category = "Fun", hidden = true, slot = "here", pose = "read", maxDur = 45, leisure = true,
    ages = ADULT_CHILD,
    test = I.read_seat.test,
    onStart = function(world, actor, act)
        local ok, why = readSetup(world, actor, act)
        if ok == false then return false, why end
        act.rates.comfort = -6
    end,
    onResume = function(world, actor, act) readSetup(world, actor, act); act.rates.comfort = -6 end,
    onTick = I.read_seat.onTick,
    onEnd = I.read_seat.onEnd,
    next = I.read_seat.next,
}

function L.ReturnBookOrder(world, actor)
    if not C.Held(actor, "book") then return nil end
    local shelf = C.FindUsable(world, actor, { "bookshelf", "book" }, "return_book")
    if shelf then return { oid = shelf.id, iid = "return_book" } end
end

I.return_book = {
    usesHeld = { book = true },
    label = "Put Book Back", category = "Chores", hidden = true, slot = { "front", "use" }, pose = "use", dur = 0.3, noWear = true,
    useTags = { "bookshelf", "book" }, ages = ADULT_CHILD,
    test = function(world, actor) if not C.Held(actor, "book") then return false, "No book in hand." end return true end,
    onEnd = function(world, actor, act, obj, status) if status == "done" then C.Drop(world, actor) end end,
}

-- Games -----------------------------------------------------------------------------------
-- Two-player objects use slot groups ("player") when the definition has them; otherwise the
-- spot resolver (radius, capacity) gives each player a place beside the object.
local function gameDef(t)
    t.category = t.category or "Fun"
    t.leisure = true
    t.group = true
    t.ages = t.ages or ADULT_CHILD
    local iids = set(t.shareWith or { t.id })
    local solo = t.soloFun or 1
    t.onStart = function(world, actor, act, obj)
        act.data.soloFun = solo
    end
    t.onResume = t.onStart
    t.onTick = function(world, actor, act, obj, dt)
        local n = L.ShareTick(world, actor, act, obj, dt, iids, t.shareRadius)
        if n == 0 and t.twoPlayer then act.mult.fun = solo * 0.7 end -- practising alone is less fun
    end
    t.shareWith, t.id = nil, nil
    return t
end

I.play_chess = gameDef({ id = "play_chess", label = "Play Chess", slot = { "player", "seat", "use" }, pose = "play", maxDur = 90,
    untilFull = "fun", topic = "games", twoPlayer = true, rate = { fun = 22 }, skill = { logic = 0.5 },
    traits = { playful = -0.4, active = -0.2 }, advert = { fun = 26 } })
I.play_game = gameDef({ id = "play_game", label = "Play a Game", slot = { "player", "seat", "use" }, pose = "play", maxDur = 60,
    untilFull = "fun", topic = "games", twoPlayer = true, rate = { fun = 30 }, traits = { playful = 0.5 }, advert = { fun = 32 } })
I.play_pool = gameDef({ id = "play_pool", label = "Shoot Pool", slot = "spot", radius = 1, capacity = 2, pose = "play", maxDur = 60,
    untilFull = "fun", topic = "sports", twoPlayer = true, rate = { fun = 28 }, skill = { body = 0.2, logic = 0.1 },
    traits = { outgoing = 0.4, playful = 0.3 }, advert = { fun = 30 } })
I.play_darts = gameDef({ id = "play_darts", label = "Throw Darts", slot = "spot", radius = 3, capacity = 2, pose = "play", maxDur = 45,
    untilFull = "fun", topic = "sports", twoPlayer = true, rate = { fun = 24 }, skill = { body = 0.1 }, shareRadius = 4,
    traits = { outgoing = 0.3, playful = 0.3 }, advert = { fun = 26 } })
I.play_arcade = gameDef({ id = "play_arcade", label = "Play Arcade Game", slot = { "use", "front", "stand" }, pose = "play", maxDur = 60,
    untilFull = "fun", topic = "games", rate = { fun = 34 }, noise = 2, traits = { playful = 0.7 }, advert = { fun = 36 },
    shareRadius = 2 })
I.play_pinball = gameDef({ id = "play_pinball", label = "Play Pinball", slot = { "use", "front", "stand" }, pose = "play", maxDur = 45,
    untilFull = "fun", topic = "games", rate = { fun = 32 }, skill = { body = 0.1 }, noise = 2, traits = { playful = 0.6 },
    advert = { fun = 34 }, shareRadius = 2 })

-- Music practice, exercise, telescope, mirror -------------------------------------------------
-- Who is playing this instrument (performing play_instrument on it), if anyone.
local function playerOf(world, obj)
    if not obj then return nil end
    for _, b in pairs(world.actors) do
        local act = b.act
        if act and act.iid == "play_instrument" and act.phase == "perform" and act.oid == obj.id then return b end
    end
end
L.PlayerOf = playerOf

local function listenFun(player)
    local TI = T.instrument
    return TI.listen + TI.listenPerSkill * skillOf(player, "creativity")
end

I.play_instrument = {
    label = "Practise", category = "Skills", slot = { "seat", "use", "front", "stand" }, pose = "play", maxDur = 90, leisure = true,
    ages = ADULT_CHILD, topic = "music", noise = T.instrumentNoise,
    rate = { fun = 18 }, skill = { creativity = 0.5 }, traits = { playful = 0.4, outgoing = 0.2 },
    advertise = function(world, actor) return A.Advert("l606", "fun", 14 + skillOf(actor, "creativity") * 2) end,
    onTick = function(world, actor, act, obj, dt)
        -- skilled playing entertains the room (people behind a wall hear it but get nothing from
        -- it); beginners get a polite silence. Listeners get their own rate (listen_instrument).
        local TI = T.instrument
        local sk = skillOf(actor, "creativity")
        local lv = actor.level or 0
        local audience = 0
        if sk >= TI.skilled then
            local room = W.RoomAt(world, lv, math.floor(actor.x), math.floor(actor.y))
            local perHour = TI.bystander + TI.perSkill * sk
            for _, b in pairs(world.actors) do
                if b ~= actor and b.needs and not b.sleeping and (b.level or 0) == lv
                    and math.abs(b.x - actor.x) + math.abs(b.y - actor.y) <= TI.roomRadius
                    and W.RoomAt(world, lv, math.floor(b.x), math.floor(b.y)) == room then
                    local ba = b.act
                    if ba and ba.iid == "listen_instrument" and ba.oid == act.oid then
                        if ba.phase == "perform" then audience = audience + 1 end
                    else
                        SS.Needs.Add(b, "fun", perHour * dt / 60)
                    end
                end
            end
        end
        act.mult = act.mult or {}
        act.mult.fun = audience > 0 and TI.audienceFun or nil
        act.data.audience = audience > 0 and audience or nil
        if audience > 0 then SS.Needs.Add(actor, "social", TI.audienceSocial * dt / 60) end
    end,
}

local LISTEN_IIDS = set({ "play_instrument", "listen_instrument" })

-- Stopping to listen to someone who plays well: on offer only while a skilled player is at it.
I.listen_instrument = {
    label = "Listen", category = "Fun", slot = "spot", radius = 3, pose = "idle", maxDur = 60, leisure = true,
    group = true, ages = ADULT_CHILD, topic = "music", untilFull = "fun",
    rate = { fun = 12 }, traits = { playful = 0.1, outgoing = 0.2 },
    test = function(world, actor, obj)
        local p = playerOf(world, obj)
        if not p or p == actor then return false, "Nobody is playing it." end
        if skillOf(p, "creativity") < T.instrument.skilled then return false, (p.name or "They") .. " is still learning." end
        return true
    end,
    advertise = function(world, actor, obj)
        local p = playerOf(world, obj)
        if not p or p == actor or skillOf(p, "creativity") < T.instrument.skilled then return nil end
        return A.Advert("l653", "fun", 4 + listenFun(p) * 1.25, "social", 4)
    end,
    onStart = function(world, actor, act, obj)
        local p = playerOf(world, obj)
        act.data.player = p and p.id or nil
        act.rates = { fun = p and listenFun(p) or 0 }
        act.data.soloFun = 1
    end,
    onResume = function(world, actor, act, obj)
        local p = playerOf(world, obj)
        act.rates = { fun = p and listenFun(p) or 0 }
    end,
    onTick = function(world, actor, act, obj, dt)
        local p = playerOf(world, obj)
        if not p then act.complete = true; return end
        if p.id ~= act.data.player then
            act.data.player = p.id
            act.rates = { fun = listenFun(p) }
        end
        -- company: the player and the other listeners (social, relationship, fun x1.25)
        L.ShareTick(world, actor, act, obj, dt, LISTEN_IIDS, 3)
    end,
}

I.workout = {
    label = "Work Out", category = "Skills", slot = { "use", "front", "stand", "seat" }, pose = "exercise", maxDur = 60, leisure = true,
    exertion = 2, ages = ADULT_CHILD, topic = "fitness",
    rate = { fun = 10 }, skill = { body = 0.6 }, traits = { active = 1.2 },
    advertise = function(world, actor) return A.Advert("l681", "fun", 6 + math.max(0, trait(actor, "active") - 3) * 4) end,
    onStart = function(world, actor, act)
        act.rates = { fun = 4 + trait(actor, "active") * 2 }
    end,
    onResume = function(world, actor, act) act.rates = { fun = 4 + trait(actor, "active") * 2 } end,
}

I.stargaze = {
    label = "Stargaze", category = "Skills", slot = { "use", "front", "stand" }, pose = "use", maxDur = 60, leisure = true,
    ages = ADULT_CHILD, topic = "science",
    rate = { fun = 20 }, skill = { logic = 0.4 }, traits = { playful = -0.2 },
    test = function(world) if not C.IsNight(world) then return false, "The stars only come out at night." end return true end,
    advert = { fun = 24 },
    onTick = function(world, actor, act) if not C.IsNight(world) then act.complete = true end end,
}

I.practice_speech = {
    label = "Practise Speech", category = "Skills", slot = { "front", "use" }, pose = "talk", maxDur = 45, leisure = true,
    ages = ADULT_CHILD, topic = "people",
    rate = { fun = 5 }, skill = { charisma = 0.5 }, traits = { outgoing = 0.8 },
    advertise = function(world, actor) return A.Advert("l701", "fun", 4 + math.max(0, trait(actor, "outgoing") - 4) * 3) end,
}

-- Outfits -----------------------------------------------------------------------------------
L.OUTFITS = { "everyday", "formal", "work", "swim", "sleep" }
L.OUTFIT_LABEL = { everyday = "Everyday", formal = "Formal", work = "Work Clothes", swim = "Swimwear", sleep = "Pyjamas" }
I.change_outfit = {
    label = "Change Clothes", category = "Home", slot = { "front", "use" }, pose = "use", dur = 1.5, manualOnly = true, noWear = true,
    ages = ADULT_CHILD,
    test = function(world, actor, obj, data)
        local o = data and data.outfit or "everyday"
        if not L.OUTFIT_LABEL[o] then return false, "Unknown outfit." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" then return end
        actor.outfit = act.data.outfit or "everyday"
        SS.Emit("outfitChanged", world, actor, actor.outfit)
    end,
}

-- Art and crafts --------------------------------------------------------------------------
local sysdef = M.SystemDef
SS.Objects.craft_painting = sysdef({ name = "Home-Made Painting", mount = "floor", noBlock = true,
    desc = "Signed in the corner. The artist would like you to notice.", actions = { "admire_art", "sell_craft" } })
SS.Objects.craft_woodwork = sysdef({ name = "Home-Made Woodwork", mount = "floor", noBlock = true,
    desc = "Sanded, varnished and only slightly wonky.", actions = { "admire_art", "sell_craft" } })

L.CRAFT = {
    painting = { tag = "easel", item = "craft_painting", noun = "painting", pose = "paint",
                 titles = { "Harbour at Dusk", "Bowl of Lemons", "Portrait of a Neighbour", "Rain on Juniper Lane", "The Blue Chair",
                            "Garden in August", "Study in Orange", "Cat, Asleep", "Morning Kettle", "Streetlight No. 3" } },
    woodwork = { tag = "workbench", item = "craft_woodwork", noun = "piece", pose = "use",
                 titles = { "Birdhouse", "Step Stool", "Toy Truck", "Spice Rack", "Picture Frame", "Plant Stand", "Letter Box", "Jewellery Box" } },
}

-- A new canvas: time, quality and value are fixed when it starts (stored on the easel), so
-- stopping, reloading or restarting cannot re-roll them.
function L.NewCanvas(world, actor, kind, mode)
    local K = T.craft[kind]
    local m = K[mode] or K.quick
    local skill = skillOf(actor, K.skill)
    local q = U.clamp(0.2 + skill * 0.07 + (mode == "careful" and 0.2 or 0) + (SS.Random(world, "craft") * 2 - 1) * 0.12, 0.05, 1)
    local need = m.minutes / (1 + skill * 0.05)
    local C2 = T.craft
    -- skill counts once, through quality (and time); the market pays for quality convexly
    local value = math.max(1, math.floor(m.value * (C2.valueBase + C2.valueQ * q * q) + 0.5))
    local titles = L.CRAFT[kind].titles
    local title = titles[SS.RandomInt(world, "craft", 1, #titles)]
    return { kind = kind, by = actor.id, mode = mode, need = need, done = 0, q = q, value = value, title = title, started = world.time }
end

local function craftDef(kind, label)
    local K = L.CRAFT[kind]
    return {
        label = label, category = "Skills", slot = { "use", "front", "stand", "seat" }, pose = K.pose, leisure = true,
        ages = ADULT_CHILD, topic = "arts", traits = { playful = 0.5, neat = 0.1 }, givesSkill = true,
        test = function(world, actor, obj, data)
            local cv = obj.canvas
            if cv and cv.by ~= actor.id and world.root.residents[cv.by] and not (world.root.residents[cv.by].dead) then
                return false, "Someone else's unfinished " .. K.noun .. " is on it."
            end
            if data and data.mode and not T.craft[kind][data.mode] then return false, "Unknown style." end
            return true
        end,
        advertise = function(world, actor, obj)
            local s = skillOf(actor, T.craft[kind].skill)
            local unfinished = obj.canvas and obj.canvas.by == actor.id
            return A.Advert("l769", "fun", 12 + s * 2 + (unfinished and 10 or 0))
        end,
        estimate = function(world, actor, obj)
            local cv = obj and obj.canvas
            if cv then return math.max(1, cv.need - cv.done) end
            return T.craft[kind].quick.minutes
        end,
        onStart = function(world, actor, act, obj)
            if not obj.canvas then
                local mode = act.data.mode or ((skillOf(actor, T.craft[kind].skill) >= 3) and "careful" or "quick")
                obj.canvas = L.NewCanvas(world, actor, kind, mode)
            end
            obj.canvas.by = actor.id
            obj.state = obj.state or {}
            obj.state.stage = math.floor(obj.canvas.done / obj.canvas.need * 4)
            act.dur = math.max(0.25, obj.canvas.need - obj.canvas.done)
            act.rates = { fun = 8 + trait(actor, "playful") * 1.5 + skillOf(actor, T.craft[kind].skill) }
            act.skill = { [T.craft[kind].skill] = T.craft[kind].gain }
            SS.Emit("lotChanged", "state", obj.id)
        end,
        onResume = function(world, actor, act, obj)
            act.rates = { fun = 8 + trait(actor, "playful") * 1.5 + skillOf(actor, T.craft[kind].skill) }
            act.skill = { [T.craft[kind].skill] = T.craft[kind].gain }
        end,
        onTick = function(world, actor, act, obj, dt)
            local cv = obj and obj.canvas
            if not cv then act.failWhy = "The work is gone."; return end
            cv.done = cv.done + dt
            local st = math.floor(cv.done / cv.need * 4)
            if obj.state.stage ~= st then obj.state.stage = st; SS.Emit("lotChanged", "state", obj.id) end
            if cv.done >= cv.need then act.complete = true end
        end,
        onEnd = function(world, actor, act, obj, status)
            local cv = obj and obj.canvas
            if not cv then return end
            if cv.done >= cv.need then L.FinishCraft(world, actor, obj)
            elseif act.performed and isMember(world, actor) then
                A.Message(world, actor, string.format("The %s is %d%% done; it will wait on the %s.", K.noun,
                    math.floor(cv.done / cv.need * 100), K.tag), "fun")
            end
        end,
    }
end

-- Completion: exactly one item, then the canvas is cleared in the same call.
function L.FinishCraft(world, actor, obj)
    local cv = obj.canvas
    if not cv or cv.done < cv.need then return nil end
    obj.canvas = nil
    if obj.state then obj.state.stage = nil end
    SS.Emit("lotChanged", "state", obj.id)
    local K = L.CRAFT[cv.kind]
    -- a visitor who paints on the household's easel takes the work home: it never becomes the
    -- household's to sell
    if not isMember(world, actor) then
        SS.Needs.Feel(world, actor, "proud", 0.5 + cv.q * 0.5)
        A.Message(world, actor, string.format("%s takes \"%s\" home.", A.FirstName(actor) or "The visitor", cv.title), "fun")
        A.Journal(world, string.format("%s finished \"%s\" here and took it home.", actor.name or "A visitor", cv.title), actor)
        SS.Emit("craftMade", world, actor, nil, cv)
        return nil
    end
    local fields = { value = cv.value, q = cv.q, maker = cv.by, made = world.time, title = cv.title,
        owner = world.household and world.household.id, env = math.min(8, math.floor(cv.q * 8 + 0.5)) }
    local item
    local onLot = 0
    for _, o in pairs(world.lot.objects) do if o.def == "craft_painting" or o.def == "craft_woodwork" then onLot = onLot + 1 end end
    if onLot < T.craft.maxOnLot then
        local lv = level(obj)
        local i, j = SS.Nav.NearestFree(world, lv, obj.x, obj.y, 3, function(i, j)
            for _, o in pairs(world.lot.objects) do if o.x == i and o.y == j and level(o) == lv then return false end end
            return true
        end)
        if i then
            item = M.Spawn(world, K.item, lv, i, j, fields)
            item.label = cv.title
        end
    end
    if not item and SS.Inventory and SS.Inventory.Add then
        SS.Inventory.Add(world, { kind = "craft", def = K.item, name = cv.title, value = cv.value, data = fields })
        A.Message(world, actor, "No room on the lot; \"" .. cv.title .. "\" went into storage.", "fun")
    end
    SS.Needs.Feel(world, actor, "proud", 0.5 + cv.q * 0.5)
    A.Journal(world, string.format("%s finished \"%s\" (worth about %s).", actor.name or "Someone", cv.title, U.fmtMoney(cv.value)), actor)
    SS.Emit("craftMade", world, actor, item, cv)
    return item
end

I.paint = craftDef("painting", "Paint")
I.woodwork = craftDef("woodwork", "Do Woodwork")

-- Selling: each sale on the same day fetches less (Tuning.craft.saleStep, floor saleFloor); the
-- count is kept on the household (household.flags.craftSales = { day, n }, saved and validated).
local function salesToday(world)
    local hh = world.household
    local rec = hh and type(hh.flags) == "table" and hh.flags.craftSales
    local day = math.floor(world.time / 1440)
    if type(rec) == "table" and rec.day == day then return rec.n or 0 end
    return 0
end
function L.SalePrice(world, obj)
    local n = salesToday(world)
    local f = math.max(T.craft.saleFloor, 1 - T.craft.saleStep * n)
    return math.floor((obj.value or 0) * f + 0.5), f
end
local function countSale(world)
    local hh = world.household
    if not hh then return end
    if type(hh.flags) ~= "table" then hh.flags = {} end
    local day = math.floor(world.time / 1440)
    local rec = hh.flags.craftSales
    if type(rec) ~= "table" or rec.day ~= day then rec = { day = day, n = 0 }; hh.flags.craftSales = rec end
    rec.n = (rec.n or 0) + 1
end

I.sell_craft = {
    label = "Sell", category = "Money", slot = "around", pose = "use", dur = 0.5, noWear = true, manualOnly = true,
    householdOnly = true, ages = { adult = true },
    test = function(world, actor, obj)
        if obj.sold then return false, "Already sold." end
        if not world.household or obj.owner ~= world.household.id then return false, "That isn't yours to sell." end
        return true
    end,
    hint = function(world, actor, obj)
        local price, f = L.SalePrice(world, obj)
        if f < 1 then return string.format("Fetches %s today; buyers have seen a lot of your work lately.", U.fmtMoney(price)) end
        return string.format("Fetches %s.", U.fmtMoney(price))
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj or obj.sold or not world.lot.objects[obj.id] then return end
        -- remove first, then pay: the item can never be sold twice
        obj.sold = true
        local value, title = L.SalePrice(world, obj), obj.title or "a craft"
        act.removing = true
        M.Remove(world, obj)
        countSale(world)
        SS.Money(world, value, "sale", "Sold \"" .. title .. "\"")
        A.Message(world, actor, "Sold \"" .. title .. "\" for " .. U.fmtMoney(value) .. ".", "money")
        SS.Emit("craftSold", world, actor, value, title)
    end,
}

I.admire_art = {
    label = "Admire", category = "Fun", slot = "around", pose = "idle", dur = 4, leisure = true, noWear = true,
    ages = ADULT_CHILD, topic = "arts",
    gain = { fun = 5 }, skill = { creativity = 0.2 }, traits = { playful = 0.2 },
    advertise = function(world, actor, obj)
        local def = SS.Objects[obj.def]
        local env = obj.env or (def and def.env) or 2
        return A.Advert("l917", "fun", 4 + math.min(10, env))
    end,
    onStart = function(world, actor, act, obj)
        local def = obj and SS.Objects[obj.def]
        local env = obj and (obj.env or (def and def.env)) or 2
        act.gain = { fun = 3 + math.min(10, env) * 0.6 }
        act.data.soloFun = 1
    end,
}

-- Tags ---------------------------------------------------------------------------------------
for _, t in ipairs({
    { "tv", { "watchtv", "tv_workout", "tv_off" } },
    { "stereo", { "listen_music", "dance", "music_on", "music_off" } }, { "radio", { "listen_music", "dance", "music_on", "music_off" } },
    { "dj", { "dj_spin", "dance" } }, { "dance", { "dance" } },
    { "computer", { "play_computer", "chat_online", "study_computer" } },
    { "book", { "read_book" } }, { "bookshelf", { "read_book", "study_skill" } },
    { "chess", { "play_chess" } }, { "game", { "play_game" } }, { "pool_table", { "play_pool" } }, { "darts", { "play_darts" } },
    { "arcade", { "play_arcade" } }, { "pinball", { "play_pinball" } },
    { "piano", { "play_instrument", "listen_instrument" } }, { "instrument", { "play_instrument", "listen_instrument" } }, { "exercise", { "workout" } },
    { "telescope", { "stargaze" } }, { "mirror", { "practice_speech" } }, { "dresser", { "change_outfit" } },
    { "easel", { "paint" } }, { "workbench", { "woodwork" } }, { "painting", { "admire_art" } },
}) do
    for _, iid in ipairs(t[2]) do SS.Tags.Attach(t[1], iid) end
end
-- "rug" is decoration only: it adds to the room score through its definition's env.
-- The skill factor is read on every tag these practise on (Chains.DeclareReads, catalogue HC-3).
SS.Chains.DeclareReads()

-- Menus --------------------------------------------------------------------------------------
local menusDone = false
function L.RegisterMenus()
    local UI = SS.UI
    if menusDone or not (UI and UI.RegisterMenu) then return end
    menusDone = true
    UI.RegisterMenu("obj", function(world, actor, oid, entries)
        local o = world and world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if not def or not actor then return end
        local function sub(label, order, list) if #list > 0 then entries[#entries + 1] = { label = label, order = order, submenu = list } end end
        if SS.Tags.Has(def, "tv") then
            local list = {}
            for _, ch in ipairs(T.tvChannels) do
                local ok, why = A.Available(world, actor, o, "watchtv", { channel = ch.id })
                list[#list + 1] = { label = ch.name, disabled = not ok, reason = why,
                    onClick = function() A.Order(world, actor, oid, "watchtv", nil, nil, { data = { channel = ch.id } }) end }
            end
            sub("Watch...", 5, list)
            if o.state and o.state.on then
                local list2 = {}
                for _, ch in ipairs(T.tvChannels) do
                    list2[#list2 + 1] = { label = ch.name, onClick = function() A.Order(world, actor, oid, "change_channel", nil, nil, { data = { channel = ch.id } }) end }
                end
                sub("Change Channel...", 6, list2)
            end
        end
        if C.HasAnyTag(def, { "stereo", "radio" }) then
            local list, list2 = {}, {}
            for _, st in ipairs(T.stations) do
                list[#list + 1] = { label = st.name, onClick = function() A.Order(world, actor, oid, "listen_music", nil, nil, { data = { station = st.id } }) end }
                list2[#list2 + 1] = { label = st.name, onClick = function() A.Order(world, actor, oid, "dance", nil, nil, { data = { station = st.id } }) end }
            end
            sub("Listen to...", 5, list)
            sub("Dance to...", 6, list2)
        end
        if SS.Tags.Has(def, "bookshelf") then
            local list = {}
            for _, k in ipairs(L.STUDY_ORDER) do
                local ok, why = A.Available(world, actor, o, "study_skill", { skill = k })
                list[#list + 1] = { label = L.STUDY[k], disabled = not ok, reason = why,
                    onClick = function() A.Order(world, actor, oid, "study_skill", nil, nil, { data = { skill = k } }) end }
            end
            sub("Study...", 6, list)
        end
        for kind, K in pairs(L.CRAFT) do
            if SS.Tags.Has(def, K.tag) and not o.canvas then
                local list = {}
                for _, mode in ipairs({ "quick", "careful" }) do
                    local m = T.craft[kind][mode]
                    list[#list + 1] = { label = (mode == "quick" and "Quick sketch" or "Careful work") .. string.format(" (about %d min)", m.minutes),
                        desc = mode == "quick" and "Fast, worth less." or "Slow, better and worth more.",
                        onClick = function() A.Order(world, actor, oid, kind == "painting" and "paint" or "woodwork", nil, nil, { data = { mode = mode } }) end }
                end
                sub("Start...", 6, list)
            end
        end
        if SS.Tags.Has(def, "dresser") then
            local list = {}
            for _, k in ipairs(L.OUTFITS) do
                list[#list + 1] = { label = L.OUTFIT_LABEL[k], disabled = actor.outfit == k, reason = "Already wearing that.",
                    onClick = function() A.Order(world, actor, oid, "change_outfit", nil, nil, { data = { outfit = k } }) end }
            end
            sub("Change Into...", 6, list)
        end
    end)
end
SS.On("worldAttached", function() L.RegisterMenus() end)

-- Save integrity: unfinished work, the programme on and the station tuned in are saved on the
-- object; anything unreadable is dropped (an unreadable canvas is lost rather than re-rolled).
SS.Save.RegisterValidator(function(root, problems)
    for _, lot in pairs(root.hood and root.hood.lots or {}) do
        for oid, o in pairs(lot.objects or {}) do
            if type(o) == "table" then
                local cv = o.canvas
                if cv ~= nil then
                    local ok = type(cv) == "table" and L.CRAFT[cv.kind] and type(cv.need) == "number" and cv.need > 0
                        and type(cv.done) == "number" and cv.done >= 0 and type(cv.q) == "number" and type(cv.value) == "number"
                    if not ok then
                        o.canvas = nil
                        problems[#problems + 1] = "dropped an unreadable unfinished craft on " .. tostring(oid)
                    else
                        cv.q = U.clamp(cv.q, 0, 1)
                        cv.value = math.max(0, math.floor(cv.value))
                        cv.done = math.min(cv.done, cv.need)
                        if type(cv.title) ~= "string" then cv.title = L.CRAFT[cv.kind].titles[1] end
                    end
                end
                if o.channel ~= nil and not L.Channel(o.channel) then o.channel = nil end
                if o.station ~= nil and not L.Station(o.station) then o.station = nil end
                if (o.def == "craft_painting" or o.def == "craft_woodwork") and type(o.value) ~= "number" then o.value = 0 end
            end
        end
    end
    -- the day's craft sales count (sale prices fall with each sale on one day)
    for _, hh in pairs(type(root.households) == "table" and root.households or {}) do
        if type(hh) == "table" and type(hh.flags) == "table" and hh.flags.craftSales ~= nil then
            local rec = hh.flags.craftSales
            if type(rec) ~= "table" or type(rec.day) ~= "number" or type(rec.n) ~= "number" or rec.n < 0 then
                hh.flags.craftSales = nil
                problems[#problems + 1] = "dropped an unreadable craft sales count"
            end
        end
    end
    return true
end)
