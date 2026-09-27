-- Personality: five dimensions (0..10) that change what people actually do.
-- Owner: social module. Dimensions: neat, outgoing, active, playful, nice (creator budget 25,
-- the creator itself belongs to the hood module). Personality acts through:
--   * P.Modify(world, actor, target, iid, score)  autonomy scores (tidying, hand washing, games,
--     exercise, lounging, reading, phone calls, caring, and every social interaction);
--   * a needs rate hook: outgoing people's Social and playful people's Fun drain faster, messy
--     people's Hygiene and lazy people's Comfort drain faster, and a shy person's Fun drains while
--     they are stuck in a conversation (social fun decays faster);
--   * P.NeedWeight / P.Tolerance / P.Mood: need weights and tolerances for mood and urgency;
--   * conversation responses (Sim/Conversation.lua): acceptance, rude or polite replies,
--     retaliation, social fatigue (shy people tire of socialising sooner);
--   * P.WillTidy: whether someone clears their plate or leaves it (messy people leave plates).
local _, SS = ...
local U = SS.U
local P = { DIMS = { "neat", "outgoing", "active", "playful", "nice" }, BUDGET = 25, MAX = 10 }
SS.Personality = P

P.LABELS = {
    neat     = { name = "Neat",     low = "Messy",    high = "Neat",     icon = "pers_neat" },
    outgoing = { name = "Outgoing", low = "Shy",      high = "Outgoing", icon = "pers_outgoing" },
    active   = { name = "Active",   low = "Lazy",     high = "Active",   icon = "pers_active" },
    playful  = { name = "Playful",  low = "Serious",  high = "Playful",  icon = "pers_playful" },
    nice     = { name = "Nice",     low = "Grouchy",  high = "Nice",     icon = "pers_nice" },
}

-- What each dimension does in play, for the creator's tradeoff text and the personality tab.
P.TRADEOFFS = {
    neat = "Neat people tidy up and wash their hands without being asked, and feel dirt and clutter "
        .. "sooner. Messy people leave plates where they fall and only clean when the room is a disgrace.",
    outgoing = "Outgoing people need company more often but enjoy long conversations and parties. "
        .. "Shy people need less company and tire of socialising sooner.",
    active = "Active people value exercise and sport. Lazy people prefer the sofa and feel "
        .. "uncomfortable sooner.",
    playful = "Playful people prefer games, jokes and silly stories, and get bored faster. "
        .. "Serious people prefer books and debates and are hard to make laugh.",
    nice = "Nice people are forgiving, comfort others and accept more social offers. Grouchy people "
        .. "reject more, answer rudely and sometimes pick a fight.",
}

local BANDS = {
    neat = { "Lives in a nest of receipts and cereal bowls.", "Tidies when guests are coming. Probably.",
        "Clean enough, most days.", "Wipes the counter before and after.", "Straightens picture frames in other people's houses." },
    outgoing = { "Would rather text from the next room.", "Warm once you get past the first hour.",
        "Happy to chat, happy to leave.", "Knows every neighbour's middle name.", "Has never met a stranger, only an audience." },
    active = { "Considers the stairs a personal insult.", "Walks when the car is in the shop.",
        "Gets out now and then.", "Jogs, stretches, mentions it.", "Cannot sit through a film without doing lunges." },
    playful = { "Reads the instructions to board games aloud, twice.", "Laughs on the second telling.",
        "Enjoys a joke at the right moment.", "Always has a pun ready, unfortunately.", "Treats every afternoon as a game show." },
    nice = { "Complains to the complaints department about the complaints department.", "Polite, with an edge.",
        "Decent company.", "Brings a casserole when you're poorly.", "Apologises to furniture after bumping into it." },
}

function P.Get(actor, dim)
    local p = actor and actor.personality
    local v = p and p[dim]
    if type(v) ~= "number" then return 5 end
    return v
end

function P.Describe(dim, v)
    local b = BANDS[dim]
    if not b then return "" end
    v = v or 5
    local i = v <= 1 and 1 or v <= 3 and 2 or v <= 6 and 3 or v <= 8 and 4 or 5
    return b[i]
end

-- Short label like "Neat 8" / "Messy 2".
function P.Label(dim, v)
    local L = P.LABELS[dim]
    if not L then return dim end
    if v >= 6 then return L.high .. " " .. v elseif v <= 4 then return L.low .. " " .. (10 - v) end
    return L.name .. " " .. v
end

-- Creator validation (budget 25 by default). Returns ok, why.
function P.Validate(pers, budget)
    budget = budget or P.BUDGET
    if type(pers) ~= "table" then return false, "No personality." end
    local sum = 0
    for _, d in ipairs(P.DIMS) do
        local v = pers[d]
        if type(v) ~= "number" or v < 0 or v > P.MAX or v ~= math.floor(v) then
            return false, P.LABELS[d].name .. " must be a whole number from 0 to 10."
        end
        sum = sum + v
    end
    if sum > budget then return false, "That uses " .. sum .. " points; the budget is " .. budget .. "." end
    return true, sum
end

---------------------------------------------------------------------------
-- Interests
---------------------------------------------------------------------------
local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    return h
end
P.Hash = hash

-- Deterministic default interests from personality and identity (used when a saved person has
-- none, e.g. an old save or a stub NPC). The creator can overwrite them freely.
function P.DefaultInterests(person)
    local out, order = {}, {}
    local id = tostring(person and person.id or "someone")
    local kid = person and person.age == "child"
    for _, t in ipairs(SS.Topics.list) do
        local v = 3 + hash(id .. ":" .. t.id) % 5
        for dim, w in pairs(t.lean) do v = v + w * (P.Get(person, dim) - 5) / 5 * 3 end
        if kid and not t.kid then v = math.min(v, 4) end
        v = U.clamp(math.floor(v + 0.5), 0, 10)
        out[t.id] = v
        order[#order + 1] = t
    end
    table.sort(order, function(a, b)
        if out[a.id] ~= out[b.id] then return out[a.id] > out[b.id] end
        return a.order < b.order
    end)
    -- everyone has at least two loves and one pet hate
    local loves = 0
    for _, t in ipairs(order) do
        if loves < 2 and (not kid or t.kid) then out[t.id] = math.max(out[t.id], 8 - loves); loves = loves + 1 end
    end
    local worst = order[#order]
    out[worst.id] = math.min(out[worst.id], 1)
    return out
end

-- Randomised interests for the creator ("randomise" button): 2-3 loves, 1-2 hates.
function P.RandomInterests(world, person, stream)
    stream = stream or "creator"
    local out = {}
    local ids = {}
    for _, t in ipairs(SS.Topics.list) do
        out[t.id] = SS.RandomInt(world, stream, 3, 6)
        if not (person and person.age == "child") or t.kid then ids[#ids + 1] = t.id end
    end
    for n = 1, SS.RandomInt(world, stream, 2, 3) do
        local k = table.remove(ids, SS.RandomInt(world, stream, 1, #ids))
        out[k] = SS.RandomInt(world, stream, 7, 10)
    end
    for n = 1, SS.RandomInt(world, stream, 1, 2) do
        local k = table.remove(ids, SS.RandomInt(world, stream, 1, #ids))
        out[k] = SS.RandomInt(world, stream, 0, 2)
    end
    return out
end

function P.Interest(person, topicId)
    local i = person and person.interests
    local v = i and i[topicId]
    if type(v) == "number" then return v end
    return 5
end

-- Topics a person loves (>= LOVE), best first (ties by topic order).
function P.Loves(person, min)
    min = min or SS.Topics.LOVE
    local out = {}
    for _, t in ipairs(SS.Topics.list) do
        if P.Interest(person, t.id) >= min then out[#out + 1] = t.id end
    end
    table.sort(out, function(a, b)
        local va, vb = P.Interest(person, a), P.Interest(person, b)
        if va ~= vb then return va > vb end
        return SS.Topics.byId[a].order < SS.Topics.byId[b].order
    end)
    return out
end

function P.Hates(person)
    local out = {}
    for _, t in ipairs(SS.Topics.list) do
        if P.Interest(person, t.id) <= SS.Topics.HATE then out[#out + 1] = t.id end
    end
    return out
end

-- The person's favourite topic, optionally avoiding one; kids only pick kid topics.
function P.Favourite(person, avoid)
    local best, bv
    for _, t in ipairs(SS.Topics.list) do
        if t.id ~= avoid and (person.age ~= "child" or t.kid) then
            local v = P.Interest(person, t.id)
            if not bv or v > bv then best, bv = t.id, v end
        end
    end
    return best, bv
end

-- Personality similarity, -1 (opposites) .. 1 (twins). Nice counts as "both nice is good".
function P.Compatibility(a, b)
    local diff = 0
    for _, d in ipairs(P.DIMS) do
        if d == "nice" then diff = diff + (20 - P.Get(a, d) - P.Get(b, d)) * 0.5
        else diff = diff + math.abs(P.Get(a, d) - P.Get(b, d)) end
    end
    return U.clamp(1 - diff / 20, -1, 1)
end

---------------------------------------------------------------------------
-- Needs: decay multipliers, weights, tolerances, mood
---------------------------------------------------------------------------
local function human(actor) return actor and (actor.kind == nil or actor.kind == "human") and actor.age ~= "infant" end

-- Multiplier on passive decay (negative rates) per need.
function P.DecayMultiplier(actor, need)
    if not human(actor) then return 1 end
    if need == "social" then return 0.6 + P.Get(actor, "outgoing") * 0.08 end
    if need == "fun" then return 0.8 + P.Get(actor, "playful") * 0.04 end
    if need == "hygiene" then return 1.2 - P.Get(actor, "neat") * 0.04 end
    if need == "comfort" then return 1.2 - P.Get(actor, "active") * 0.04 end
    return 1
end

-- Extra Fun drain (per sim hour) for someone stuck in a conversation: shy people tire sooner.
function P.ConversationFunDrain(actor)
    return -(10 - P.Get(actor, "outgoing")) * 0.9
end

-- Needs rate hook: runs for every need of every actor each step, so it stays arithmetic only.
local function rateHook(world, actor, need, rate)
    if rate >= 0 or not actor.personality then return rate end
    if actor.kind and actor.kind ~= "human" then return rate end
    local p = actor.personality
    if need == "social" then rate = rate * (0.6 + (p.outgoing or 5) * 0.08)
    elseif need == "fun" then
        rate = rate * (0.8 + (p.playful or 5) * 0.04)
        local tmp = actor.tmp
        if tmp and tmp.conv then rate = rate - (10 - (p.outgoing or 5)) * 0.9 end
    elseif need == "hygiene" then rate = rate * (1.2 - (p.neat or 5) * 0.04)
    elseif need == "comfort" then rate = rate * (1.2 - (p.active or 5) * 0.04) end
    return rate
end
P.RateHook = rateHook
if SS.Needs and SS.Needs.RegisterRateHook then SS.Needs.RegisterRateHook(rateHook) end

-- Mood weight multiplier: what this person minds more (neat: room and hygiene; outgoing: social;
-- playful: fun; lazy: comfort). household-core's Needs.Mood can multiply T.moodWeight by it.
function P.NeedWeight(actor, need)
    if not human(actor) then return 1 end
    if need == "room" or need == "hygiene" then return 0.7 + P.Get(actor, "neat") * 0.06 end
    if need == "social" then return 0.6 + P.Get(actor, "outgoing") * 0.08 end
    if need == "fun" then return 0.7 + P.Get(actor, "playful") * 0.06 end
    if need == "comfort" then return 1.3 - P.Get(actor, "active") * 0.06 end
    return 1
end

-- Tolerance: how low a need may go before this person treats it as a problem (need value).
-- Messy people tolerate a grim room; shy people tolerate loneliness longer.
function P.Tolerance(actor, need)
    if need == "room" then return -60 + P.Get(actor, "neat") * 8 end
    if need == "hygiene" then return -50 + P.Get(actor, "neat") * 5 end
    if need == "social" then return -55 + P.Get(actor, "outgoing") * 6 end
    if need == "fun" then return -50 + P.Get(actor, "playful") * 5 end
    return (SS.Tuning and SS.Tuning.urgent) or -55
end

-- Personality-weighted mood (-100..100). One function for everyone: when the needs module weighs
-- mood by personality itself (household-core's SS.Needs.Mood multiplies its weights by
-- P.NeedWeight and adds short reactions; it exports SS.Needs.Weight), this is that mood. Before
-- integration it is computed here with the same shape (negative values amplified so one desperate
-- need dominates) and the same P.NeedWeight.
function P.Mood(actor, world)
    if not actor or not actor.needs then return 0 end
    local N = SS.Needs
    if N and N.Weight and N.Mood then return N.Mood(actor, world) end
    local T = SS.Tuning
    local sum, wsum = 0, 0
    for _, k in ipairs(T.needs) do
        local v = actor.needs[k] or 0
        local w = (T.moodWeight[k] or 1) * P.NeedWeight(actor, k)
        local term = v
        if v < 0 then
            local sev = -v / 100
            term = v * (1 + 2 * sev * sev)
            w = w * (1 + 3 * sev)
        end
        sum = sum + term * w
        wsum = wsum + w
    end
    return U.clamp(sum / wsum, -100, 100)
end

---------------------------------------------------------------------------
-- Autonomy: P.Modify
---------------------------------------------------------------------------
-- Personality is applied once, here. Where an interaction declares its personality appeal
-- (`personality = { dim = weight }`, or household-core's `traits = { dim = weight }`), that is the
-- whole profile; household-core's own trait factor (SS.Actions.TraitFit) stands down because
-- P.handlesTraits is set, so a trait never counts twice. Chores (`tidy = true`, or household-core's
-- `chore = kind` other than repairs) are tidying: messy people put them off.
P.handlesTraits = true
-- Interactions that declare nothing are recognised by keyword, on whole "_"-separated tokens of
-- the id ("care" matches care_for_plant, never career_paper; a pattern with "_" matches that
-- run of tokens, e.g. "wash_hands").
P.KEYWORDS = {
    { tidy = true, dims = { neat = 1.0 }, pats = { "clean", "tidy", "scrub", "mop", "wipe", "sweep", "dust", "dishes", "dishwasher",
        "declutter", "laundry", "trash", "rubbish", "garbage", "make_bed", "makebed", "empty_bin", "clear_plate" } },
    { dims = { neat = 0.9 }, pats = { "washhands", "wash_hands", "handwash", "brushteeth", "brush_teeth" } },
    { dims = { active = 1.0 }, pats = { "exercise", "workout", "work_out", "jog", "jogging", "treadmill", "weights", "yoga",
        "swim", "laps", "stretch", "sport", "sports", "bike", "cycling", "aerobics", "pushups", "situps", "hoops" } },
    { dims = { playful = 1.0 }, pats = { "game", "games", "arcade", "pinball", "chess", "darts", "play", "toy", "toys", "puzzle",
        "cards", "karaoke", "dance", "trampoline", "slide", "swing", "videogame", "boardgame", "float" } },
    { dims = { playful = -0.45 }, pats = { "read", "study", "book", "newspaper", "homework", "research", "crossword" } },
    { dims = { active = -0.5 }, pats = { "nap", "lounge", "sofa", "relax", "recline", "watchtv", "watch_tv" } },
    { dims = { outgoing = 0.8 }, pats = { "phone", "chat", "invite", "party", "mingle" } },
    { dims = { nice = 0.5 }, pats = { "feed", "cuddle", "soothe", "care", "tend", "water", "weed" } },
}
P.TAGS = {
    exercise = { active = 1.0 }, arcade = { playful = 1.0 }, pinball = { playful = 1.0 }, pool_table = { playful = 0.9 },
    darts = { playful = 0.9 }, chess = { playful = 0.5 }, game = { playful = 1.0 }, dance = { playful = 0.6, active = 0.4 },
    dj = { playful = 0.6, outgoing = 0.4 }, toybox = { playful = 0.8 }, kid_play = { playful = 0.8, active = 0.3 },
    bookshelf = { playful = -0.45 }, book = { playful = -0.45 }, sofa = { active = -0.4 }, tv = { active = -0.3 },
    phone = { outgoing = 0.8 }, pet_bowl = { nice = 0.5 }, pet_toy = { nice = 0.4, playful = 0.4 },
    garden_plot = { nice = 0.3, neat = 0.3 }, planter = { nice = 0.3 }, crib = { nice = 0.5 },
}
P.STRENGTH = 0.7

-- Does the token list contain the pattern's tokens as a consecutive run?
local patTokens = {}
local function tokensOf(s)
    local t = {}
    for tk in s:gmatch("[^_]+") do t[#t + 1] = tk end
    return t
end
local function matches(tokens, pat)
    local pt = patTokens[pat]
    if not pt then pt = tokensOf(pat); patTokens[pat] = pt end
    local n = #pt
    for i = 1, #tokens - n + 1 do
        local ok = true
        for k = 1, n do if tokens[i + k - 1] ~= pt[k] then ok = false; break end end
        if ok then return true end
    end
    return false
end
P.MatchesKeyword = function(iid, pat) return matches(tokensOf(iid:lower()), pat) end

local DIM = { neat = true, outgoing = true, active = true, playful = true, nice = true }
local function isChore(ia) return ia.tidy or (ia.chore ~= nil and ia.chore ~= false and ia.chore ~= "repair") end

-- Profile of an interaction on an object definition id: { dims = {dim = w}, tidy = bool,
-- source = "declared" | "keywords" }. Cached per interaction and object definition.
local profileCache = {}
function P.Profile(iid, defId)
    local byIid = profileCache[iid]
    if not byIid then byIid = {}; profileCache[iid] = byIid end
    local key = defId or "-"
    local prof = byIid[key]
    if prof then return prof end
    local def = defId and SS.Objects and SS.Objects[defId]
    prof = { dims = {}, tidy = false, source = "keywords" }
    local ia = SS.Interactions and SS.Interactions[iid]
    local declared = ia and ((type(ia.personality) == "table" and ia.personality) or (type(ia.traits) == "table" and ia.traits))
    if declared then
        for d, w in pairs(declared) do if DIM[d] and type(w) == "number" then prof.dims[d] = w end end
        prof.tidy = isChore(ia) and true or false
        prof.source = "declared"
    else
        prof = P.KeywordProfile(iid, def)
        if ia and isChore(ia) then prof.tidy = true end
    end
    byIid[key] = prof
    return prof
end

-- The keyword reading of an interaction id (plus the object definition's tags), ignoring any
-- declaration: what P.Profile falls back to for interactions that declare nothing. A new table.
function P.KeywordProfile(iid, def)
    local prof = { dims = {}, tidy = false, source = "keywords" }
    local tokens = tokensOf(iid:lower())
    for _, k in ipairs(P.KEYWORDS) do
        for _, pat in ipairs(k.pats) do
            if matches(tokens, pat) then
                for d, w in pairs(k.dims) do if math.abs(w) > math.abs(prof.dims[d] or 0) then prof.dims[d] = w end end
                if k.tidy then prof.tidy = true end
                break
            end
        end
    end
    if def and def.tags and not prof.tidy then
        for _, tag in ipairs(def.tags) do
            local t = P.TAGS[tag]
            if t then for d, w in pairs(t) do if prof.dims[d] == nil then prof.dims[d] = w end end end
        end
    end
    return prof
end
-- Interactions are registered as modules load; a profile computed early must not stick.
function P.ClearProfiles() profileCache = {} end
SS.On("worldAttached", function() P.ClearProfiles() end)

-- How much a messy person puts a chore off (a factor on its score): while the room is still above
-- their own tolerance, neat 0 scores it at P.PUT_OFF (35%), rising in a line to 100% at neat 5.
-- Average and neat people are never held back (a very neat person must not tidy less than an
-- average one, and an average person scores chores as the needs module tuned them); once the room
-- is past the person's tolerance nobody puts it off.
P.PUT_OFF = 0.35
function P.PutOff(actor)
    local neat = P.Get(actor, "neat")
    if neat >= 5 or not actor.needs or (actor.needs.room or 0) <= P.Tolerance(actor, "room") then return 1 end
    return P.PUT_OFF + (1 - P.PUT_OFF) * neat / 5
end

function P.Multiplier(actor, prof)
    local m = 1
    for d, w in pairs(prof.dims) do m = m * (1 + w * (P.Get(actor, d) - 5) / 5 * P.STRENGTH) end
    return U.clamp(m, 0.08, 2.6)
end

-- Adjust an autonomy score for this actor's personality. target is an object (object
-- interactions) or an actor (social interactions, iid "soc_*"). Returns the new score.
function P.Modify(world, actor, target, iid, score)
    if not score or score <= 0 or not actor or not iid then return score end
    if not human(actor) then return score end
    if iid:sub(1, 4) == "soc_" then
        local sdef = SS.Socials and SS.Socials.byIid and SS.Socials.byIid[iid]
        return score * P.SocialAffinity(actor, sdef, target)
    end
    local prof = P.Profile(iid, target and target.def)
    local m = P.Multiplier(actor, prof)
    -- messy people do not bother tidying until the room is bad by their own standards
    if prof.tidy then m = m * P.PutOff(actor) end
    return score * m
end

-- Social interaction appeal for this person (autonomy): outgoing people socialise more,
-- nice people pick kind interactions, grouchy people pick fights, playful people joke.
P.SOCIAL_CAT = {
    Hello = { outgoing = 0.6 }, Talk = { outgoing = 0.5 }, Fun = { playful = 1.0, outgoing = 0.3 },
    Kind = { nice = 1.0 }, Affection = { nice = 0.5, outgoing = 0.4 }, Mean = { nice = -1.3 },
    Romance = { outgoing = 0.5 }, Games = { playful = 1.0, active = 0.3 }, Kids = { nice = 0.5, playful = 0.5 },
    Family = { nice = 0.6 }, Group = { outgoing = 1.0 }, Visitors = {}, Gifts = { nice = 0.6 }, Invite = { outgoing = 0.8 },
}
function P.SocialAffinity(actor, sdef, target)
    local m = 0.55 + P.Get(actor, "outgoing") * 0.09
    if sdef then
        local cat = P.SOCIAL_CAT[sdef.cat]
        if cat then for d, w in pairs(cat) do m = m * (1 + w * (P.Get(actor, d) - 5) / 5 * P.STRENGTH) end end
        if sdef.aff then for d, w in pairs(sdef.aff) do m = m * (1 + w * (P.Get(actor, d) - 5) / 5 * P.STRENGTH) end end
    end
    return U.clamp(m, 0.03, 3)
end

-- Whether this person tidies up after themselves right now ("plate", "dishes", "bed", "rubbish").
-- Deterministic roll on the "personality" stream: neat 10 almost always, neat 0 rarely. A very
-- dirty room nudges even messy people. household-core's eating chain calls this (guarded).
function P.WillTidy(world, actor, what)
    local neat = P.Get(actor, "neat")
    local p = 0.05 + neat * 0.09
    if actor.needs and (actor.needs.room or 0) < -40 then p = p + 0.2 end
    if what == "bed" then p = p - 0.1 end
    return SS.Random(world, "personality") < p
end

-- Social fatigue per sim minute in conversation (0..1 scale); recovery per minute apart.
function P.SocialFatigueRate(actor) return 0.012 + (10 - P.Get(actor, "outgoing")) * 0.0045 end
P.FATIGUE_RECOVERY = 0.02

-- How someone answers a social offer they don't like: "rude" (grouchy), "blunt" or "polite".
function P.ResponseStyle(actor)
    local n = P.Get(actor, "nice")
    if n <= 3 then return "rude" elseif n <= 5 then return "blunt" end
    return "polite"
end

-- Everyone attached to the simulation has interests: people made before interests existed, or by
-- a module that doesn't set them, get the deterministic defaults (the creator can overwrite them).
SS.On("worldAttached", function(world)
    local root = world and (world.root or world)
    -- order doesn't matter: the defaults depend only on the person, never on a random stream
    for _, set in ipairs({ root and root.residents or {}, world and world.actors or {} }) do
        for _, r in pairs(set) do
            if type(r) == "table" and (r.kind == nil or r.kind == "human") and type(r.interests) ~= "table" then
                r.interests = P.DefaultInterests(r)
            end
        end
    end
end)

-- Save validator: personality numbers and interests exist and are in range for every human.
if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        for id, r in pairs(root.residents or {}) do
            if type(r) == "table" and (r.kind == nil or r.kind == "human") then
                if type(r.personality) ~= "table" then
                    r.personality = { neat = 5, outgoing = 5, active = 5, playful = 5, nice = 5 }
                    problems[#problems + 1] = "personality defaulted for " .. tostring(id)
                end
                for _, d in ipairs(P.DIMS) do
                    local v = r.personality[d]
                    if type(v) ~= "number" then r.personality[d] = 5 else r.personality[d] = U.clamp(v, 0, 10) end
                end
                if type(r.interests) ~= "table" then
                    r.interests = P.DefaultInterests(r)
                else
                    for k, v in pairs(r.interests) do
                        if not SS.Topics.byId[k] or type(v) ~= "number" then r.interests[k] = nil
                        else r.interests[k] = U.clamp(v, 0, 10) end
                    end
                end
            end
        end
    end)
end
