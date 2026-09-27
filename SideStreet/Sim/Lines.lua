-- Authored lines: situation-aware, state-checked, rate-limited, no-repeat captions.
-- Owner: social module. The text lives in Data/Lines.lua (SS.LineData). Other modules call
--   SS.Lines.Say(world, actor, situation, ctx) -> text, lineId   (or nil)
--   SS.Lines.Speak(world, actor, situation, ctx) -> text          (Say + speech balloon)
-- Conditions on every line are checked against real state: objects must exist on the lot,
-- "filthy room" lines need the evaluated room score or a counted mess, topic lines use the
-- listener's saved interests. Say computes the speaker-side keys itself (room score, mess,
-- witnesses, personality, mood, hour, money, venue) so a caller cannot make a line lie.
--
-- Frequency: a per-household no-repeat memory (saved, bounded), a minimum gap per speaker and
-- per situation, and an hourly cap per household; important situations (emergencies, work,
-- money trouble, death) bypass the cap but never repeat a line while another fits.
-- Every line said goes to a bounded log (root.social.lines.log) with an expandable detail; notable
-- situations also add a household journal entry.
local _, SS = ...
local U = SS.U
local L = {}
SS.Lines = L

-- Context keys a line condition or slot may use (A29 audits against this list).
-- speaker-side keys are computed by Say; the rest come from the caller's ctx. The full caller
-- contract (keys, aliases, which values may be ids) is published in docs/requests/social.md.
L.CTX_KEYS = {
    -- computed from the speaker and the lot (a caller's value for these is ignored)
    speaker = "speaker's first name", age = "speaker's life stage", mood = "speaker's mood -100..100",
    neat = "speaker personality", outgoing = "speaker personality", active = "speaker personality",
    playful = "speaker personality", nice = "speaker personality", hour = "hour of day 0-23",
    roomScore = "evaluated score of the room the speaker is in", mess = "mess objects counted in that room",
    messDef = "definition id of one counted mess object", witnesses = "other people within 6 tiles",
    money = "household cash", venue = "true on a community lot", guest = "speaker is not a resident of this lot",
    -- derived from ctx.listener (an actor or resident id)
    other = "listener's first name", rel = "speaker->listener life score", daily = "speaker->listener daily score",
    family = "family tie kind", partner = "listener is the speaker's partner or spouse", otherAge = "listener's life stage",
    otherMood = "listener's mood", interest = "listener's interest in ctx.topic (0..10)",
    myInterest = "speaker's interest in ctx.topic (0..10)",
    -- given by the caller
    topic = "topic id", objDef = "object definition id (must exist on the lot)", objPrice = "price of objDef",
    item = "item name", amount = "money amount", meal = "meal name", quality = "0..10 quality",
    job = "job title", level = "career level", skill = "skill name", grade = "school grade letter",
    pet = "pet name", plant = "plant or produce name", deceased = "name of someone who died", cause = "cause id",
    count = "a count", days = "days (e.g. overdue)", place = "venue or place name", waitMin = "minutes waited",
    score = "outcome score", holder = "name of whoever is occupying something", subject = "name of a third person",
    role = "'speaker' or 'listener' in a conversation exchange",
    name = "first name of the person the caller's situation is about (a date, a guest, a giver, a baby)",
    isHost = "the speaker is hosting (party, visit)", hostName = "first name of the host",
    reason = "the caller's reason id (why someone leaves, is refused, retries)", invited = "the visit was by invitation",
    phone = "said on the phone", passing = "a greeting in passing", party = "at a party",
    outcome = "'accepted' or 'rejected': how the exchange being reacted to went",
    itemKind = "kind of the item given (gift, flowers, book, ...)",
}

-- Slot -> the ctx key that fills it.
L.SLOTS = {
    speaker = "speaker", name = "name", host = "hostName", other = "other", topic = "topic", obj = "objDef", item = "item", amount = "amount", meal = "meal",
    job = "job", skill = "skill", pet = "pet", plant = "plant", deceased = "deceased", place = "place",
    holder = "holder", subject = "subject", grade = "grade", count = "count", days = "days", mess = "messDef",
    witnesses = "witnesses",
}

L.REQUIRED = {
    "greet", "farewell", "smalltalk", "topic_love", "topic_hate", "joke_good", "joke_bad", "story", "gossip", "compliment",
    "boast", "boast_undercut_mess", "complain", "tease", "argue", "insult", "apologize", "comfort", "flirt", "romance_reject",
    "jealous", "gift_good", "gift_bad", "group_join", "ask_leave", "messy_plate", "room_filthy", "bathroom_queue",
    "chores_argument", "burnt_meal", "proud_meal", "broken_object", "puddle", "bill_arrived", "bill_overdue",
    "repo_visit", "visitor_greet", "visitor_wait", "visitor_refused", "visitor_ornament", "party_good", "party_bad",
    "party_leave_bad", "phone_badtime", "work_promoted", "work_demoted", "work_fired", "work_late", "school_good",
    "school_bad", "shop_browse", "shop_checkout", "shop_broke", "dine_good", "dine_bad", "fire_alarm", "fire_panic",
    "fire_after", "death_grief", "ghost_seen", "burglary", "pet_mess", "garden_harvest", "infant_cry", "expensive_chair",
}

-- Tuning knobs (sim minutes).
L.ACTOR_GAP = 3          -- a person captions at most this often
L.SITUATION_GAP = 12     -- default gap between captions of one situation per household
L.HOURLY_CAP = 14        -- captions per sim hour per household (important situations exempt)
L.MEMORY = 120           -- no-repeat memory per household (line ids)
L.LOG_CAP = 60           -- bounded line log
L.REUSE_AFTER = 1440 * 2 -- when every fitting line is remembered, the oldest may return after this
-- L.Say enforces its own limits (the speaker gap, per-situation gaps, the hourly cap; important
-- situations exempt), so a caller needs no cooldown of its own in front of it. A caller-side
-- cooldown longer than ACTOR_GAP silently drops lines L.Say would have allowed (a chores
-- argument swallowed by a room complaint a minute earlier). See docs/requests/social.md.
L.RATE_LIMITED = true

---------------------------------------------------------------------------
-- Parse Data/Lines.lua once
---------------------------------------------------------------------------
local OPS = { ">=", "<=", "~=", ">", "<", "=" }
local function parseCond(tok)
    if tok:sub(1, 1) == "!" then return { key = tok:sub(2), op = "not" } end
    for _, op in ipairs(OPS) do
        local a, b = tok:find(op, 1, true)
        if a then
            local k, v = tok:sub(1, a - 1), tok:sub(b + 1)
            local num = tonumber(v)
            if v == "true" then num = true elseif v == "false" then num = false end
            return { key = k, op = op, val = num ~= nil and num or v }
        end
    end
    return { key = tok, op = "has" }
end

L.lines, L.bySit, L.byId, L.sitNeeds = {}, {}, {}, {}
function L.Load(data)
    data = data or SS.LineData
    L.lines, L.bySit, L.byId, L.sitNeeds = {}, {}, {}, {}
    if not data then return end
    L.meta = data.situations or {}
    for _, ln in ipairs(data.lines or {}) do
        local e = { id = ln.id, s = ln.s, text = ln.t, detail = ln.d, w = ln.w or 1, conds = {}, slots = {} }
        for tok in (ln.c or ""):gmatch("%S+") do e.conds[#e.conds + 1] = parseCond(tok) end
        for slot in e.text:gmatch("{(%w+)}") do e.slots[#e.slots + 1] = slot end
        L.lines[#L.lines + 1] = e
        L.byId[e.id] = e
        L.bySit[e.s] = L.bySit[e.s] or {}
        table.insert(L.bySit[e.s], e)
        local need = L.sitNeeds[e.s] or {}
        L.sitNeeds[e.s] = need
        for _, c in ipairs(e.conds) do need[c.key] = true end
        for _, s in ipairs(e.slots) do need[L.SLOTS[s] or s] = true end
    end
end
L.Load()

local function meta(s) return (L.meta and L.meta[s]) or {} end
L.Meta = meta

---------------------------------------------------------------------------
-- State helpers (also used by the conversation engine and remarks)
---------------------------------------------------------------------------
local MESS_TAGS = { mess = "mess", puddle = "puddle", trash = "trash", rubbish = "trash", plate_dirty = "plate",
    dirty_dish = "plate", dishes = "plate", pest = "pest", pests = "pest", charred = "charred", pet_mess = "pet",
    litter_mess = "pet", clutter = "mess", leftovers = "plate", spoiled = "plate" }
local MESS_WORDS = { { "puddle", "puddle" }, { "plate", "plate" }, { "dish", "plate" }, { "trash", "trash" },
    { "rubbish", "trash" }, { "garbage", "trash" }, { "pest", "pest" }, { "roach", "pest" }, { "charred", "charred" },
    { "ash", "charred" }, { "mess", "mess" }, { "clutter", "mess" }, { "poop", "pet" }, { "dropping", "pet" },
    { "leftover", "plate" } }

-- What kind of mess an object is ("plate", "puddle", "trash", "pest", "pet", "charred", "dirty",
-- "spoiled", "mess") or nil. System objects are recognised by tag or id; any object can be
-- dirty, spoiled or burnt through its state.
function L.MessKind(obj, def)
    def = def or (obj and SS.Objects[obj.def])
    if not def then return nil end
    if def.tags then
        for _, t in ipairs(def.tags) do if MESS_TAGS[t] then return MESS_TAGS[t] end end
    end
    if def.mess then return type(def.mess) == "string" and def.mess or "mess" end
    if def.cat == "system" or def.buyable == false then
        local id = obj and obj.def or ""
        for _, w in ipairs(MESS_WORDS) do if id:find(w[1], 1, true) then return w[2] end end
    end
    local st = obj and obj.state
    if st then
        if st.spoiled then return "spoiled" end
        if st.burnt then return "charred" end
        if st.dirty or (type(st.dirt) == "number" and st.dirt >= 50) then return "dirty" end
    end
    return nil
end

-- Mess near an actor: objects in the same room (same level). Returns count, one def id, kinds map.
function L.MessNear(world, actor, onlyKind)
    if not actor or not world.lot then return 0 end
    local W = SS.World
    local lv = actor.level or 0
    local room = W.RoomAt(world, lv, math.floor(actor.x), math.floor(actor.y))
    local n, sample, sampleId = 0, nil, nil
    for oid, o in pairs(world.lot.objects) do
        if (o.level or 0) == lv then
            local k = L.MessKind(o)
            if k and (not onlyKind or k == onlyKind) and W.RoomAt(world, lv, o.x, o.y) == room then
                n = n + 1
                if not sampleId or oid < sampleId then sample, sampleId = o.def, oid end
            end
        end
    end
    return n, sample, sampleId
end

-- Mess anywhere on the lot (count, sample def, sample object id).
function L.MessOnLot(world, onlyKind)
    local n, sample, sid = 0, nil, nil
    for oid, o in pairs(world.lot and world.lot.objects or {}) do
        local k = L.MessKind(o)
        if k and (not onlyKind or k == onlyKind) then
            n = n + 1
            if not sid or oid < sid then sample, sid = o.def, oid end
        end
    end
    return n, sample, sid
end

function L.RoomScoreAt(world, actor)
    local W = SS.World
    local lv = actor.level or 0
    local room = W.RoomAt(world, lv, math.floor(actor.x), math.floor(actor.y))
    if SS.Needs and SS.Needs.RoomScoreCached then return SS.Needs.RoomScoreCached(world, lv, room) end
    return W.RoomScore(world, lv, room)
end

-- Sight and hearing across the lot. A straight line from one point to another is walked cell by
-- cell (4-connected steps, DDA) and every wall edge it crosses is checked: solid walls and closed
-- doors block sight; windows, arches, gates, fences and railings don't. Sound also carries through
-- a door. Nothing is allocated except the edge keys of cells actually crossed (at most a dozen).
L.SEE_THROUGH = { window = true, arch = true, gate = true, fence = true, railing = true, halfwall = true }
L.HEAR_THROUGH = { window = true, arch = true, gate = true, fence = true, railing = true, halfwall = true, door = true }
function L.LineClear(world, level, x0, y0, x1, y1, through)
    local walls = world.lot and world.lot.walls and world.lot.walls[level or 0]
    if not walls or next(walls) == nil then return true end
    local G = SS.Grid
    local i, j = math.floor(x0), math.floor(y0)
    local ti, tj = math.floor(x1), math.floor(y1)
    local dx, dy = x1 - x0, y1 - y0
    local si, sj = dx > 0 and 1 or -1, dy > 0 and 1 or -1
    local adx, ady = math.abs(dx), math.abs(dy)
    local tMaxX = adx > 1e-9 and ((dx > 0 and (i + 1 - x0) or (x0 - i)) / adx) or math.huge
    local tMaxY = ady > 1e-9 and ((dy > 0 and (j + 1 - y0) or (y0 - j)) / ady) or math.huge
    local tdx = adx > 1e-9 and 1 / adx or math.huge
    local tdy = ady > 1e-9 and 1 / ady or math.huge
    local guard = 64
    while (i ~= ti or j ~= tj) and guard > 0 do
        guard = guard - 1
        local ni, nj = i, j
        if tMaxX < tMaxY then ni = i + si; tMaxX = tMaxX + tdx else nj = j + sj; tMaxY = tMaxY + tdy end
        local wl = walls[G.edgeBetween(i, j, ni, nj)]
        if wl and not through[wl.kind] then return false end
        i, j = ni, nj
    end
    return true
end

-- Can `viewer` see `target`? Awake, same floor, within radius, and either in the same room or
-- with a clear line of sight (through windows and open archways, not walls or doors).
function L.CanSee(world, viewer, target, radius)
    if not viewer or not target or viewer.sleeping or (viewer.level or 0) ~= (target.level or 0) then return false end
    local dx, dy = viewer.x - target.x, viewer.y - target.y
    local r = radius or 6
    if dx * dx + dy * dy > r * r then return false end
    local W = SS.World
    local lv = viewer.level or 0
    if W and W.RoomAt and SS.RT and SS.RT.room then
        local ra = W.RoomAt(world, lv, math.floor(viewer.x), math.floor(viewer.y))
        local rb = W.RoomAt(world, lv, math.floor(target.x), math.floor(target.y))
        if ra == rb and ra ~= 0 then return true end
    end
    return L.LineClear(world, lv, viewer.x, viewer.y, target.x, target.y, L.SEE_THROUGH)
end

-- Can `listener` overhear `speaker`? Awake, same floor, and either in the same room within 8
-- tiles, or within 3 tiles with nothing but openings (a door included) in between.
function L.CanHear(world, listener, speaker)
    if not listener or not speaker or listener.sleeping or (listener.level or 0) ~= (speaker.level or 0) then return false end
    local dx, dy = listener.x - speaker.x, listener.y - speaker.y
    local d2 = dx * dx + dy * dy
    if d2 > 64 then return false end
    local W = SS.World
    local lv = speaker.level or 0
    if W and W.RoomAt and SS.RT and SS.RT.room then
        local ra = W.RoomAt(world, lv, math.floor(listener.x), math.floor(listener.y))
        local rb = W.RoomAt(world, lv, math.floor(speaker.x), math.floor(speaker.y))
        if ra == rb and ra ~= 0 then return true end
        if ra == 0 and rb == 0 and d2 <= 36 then return L.LineClear(world, lv, listener.x, listener.y, speaker.x, speaker.y, L.HEAR_THROUGH) end
    end
    return d2 <= 9 and L.LineClear(world, lv, listener.x, listener.y, speaker.x, speaker.y, L.HEAR_THROUGH)
end

-- People who can see the actor (the `witnesses` line key): awake humans within radius and sight.
function L.Witnesses(world, actor, radius, exclude)
    radius = radius or 6
    local n = 0
    for id, a in pairs(world.actors or {}) do
        if id ~= actor.id and (not exclude or not exclude[id]) and (a.kind == nil or a.kind == "human") and not a.ghost
            and L.CanSee(world, a, actor, radius) then
            n = n + 1
        end
    end
    return n
end

local function objOnLot(world, defId)
    for _, o in pairs(world.lot and world.lot.objects or {}) do if o.def == defId then return true end end
    return false
end
L.ObjOnLot = objOnLot

local function firstName(p)
    local n = p and p.name
    if not n then return nil end
    return (n:match("^(%S+)")) or n
end
L.FirstName = firstName

---------------------------------------------------------------------------
-- Context
---------------------------------------------------------------------------
local P = SS.Personality

-- Build the checked context for a speaker. Only keys some line of the situation needs are
-- computed (room score, mess and witnesses cost a scan).
-- Keys computed from real state: a caller's value never overrides them.
L.COMPUTED = { speaker = true, age = true, mood = true, neat = true, outgoing = true, active = true, playful = true,
    nice = true, hour = true, roomScore = true, mess = true, messDef = true, witnesses = true, money = true, venue = true,
    guest = true, other = true, family = true, partner = true, otherAge = true, otherMood = true, interest = true,
    myInterest = true, objPrice = true }
-- Other modules' names for contract keys (their call sites): alias -> key. The alias is used
-- only when the contract key itself is absent.
L.ALIASES = { recipe = "meal", crop = "plant", qty = "count", petName = "pet", dead = "deceased", ghost = "deceased",
    infant = "subject", from = "subject", victim = "subject", target = "listener", with = "listener" }

local function person(world, id)
    if type(id) ~= "string" then return nil end
    return (world.actors and world.actors[id]) or (world.root and world.root.residents and world.root.residents[id])
end
-- A person named by id or by full name becomes a first name; any other string stays as it is.
local function personName(world, v, whole)
    if type(v) == "table" then return v.name and (whole and v.name or firstName(v)) or nil end
    if type(v) ~= "string" then return v end
    local p = person(world, v)
    if p then return whole and p.name or firstName(p) end
    for _, r in pairs(world.root and world.root.residents or {}) do
        if r.name == v then return whole and v or firstName(r) end
    end
    return v
end
local function humanize(id) return (tostring(id):gsub("_", " ")) end
-- Value conversions for keys that callers pass as ids.
local CONVERT = {
    meal = function(world, v)
        local r = SS.Food and SS.Food.recipes and SS.Food.recipes[v]
        return r and r.name or (type(v) == "string" and v:find("_") and humanize(v)) or v
    end,
    plant = function(world, v)
        local cr = SS.PlantData and SS.PlantData.crops and SS.PlantData.crops[v]
        return cr and cr.name or (type(v) == "string" and v:find("_") and humanize(v)) or v
    end,
    item = function(world, v)
        if type(v) == "table" then return v.name end
        local d = type(v) == "string" and SS.Objects and SS.Objects[v]
        if d and d.name then return d.name end
        return v
    end,
    pet = function(world, v) return personName(world, v, true) end,
    deceased = function(world, v) return personName(world, v) end,
    subject = function(world, v) return personName(world, v) end,
    holder = function(world, v) return personName(world, v) end,
    name = function(world, v) return personName(world, v) end,
    place = function(world, v) return type(v) == "string" and v or nil end,
}

-- The caller's ctx as contract keys: aliases applied, ids turned into names, computed keys dropped.
function L.Normalize(world, actor, ctx)
    local c = {}
    for k, v in pairs(ctx) do
        if L.CTX_KEYS[k] and not L.COMPUTED[k] and k ~= "listener" then c[k] = v end
    end
    for alias, key in pairs(L.ALIASES) do
        local v = ctx[alias]
        if v ~= nil and key ~= "listener" and c[key] == nil then c[key] = v end
    end
    -- outings pass the venue's name as `venue` (a computed flag here): it is the place
    if type(ctx.venue) == "string" and c.place == nil then c.place = ctx.venue end
    -- host: true (the speaker hosts) or the host's id
    local host = ctx.host
    if host == true then c.isHost = true
    elseif type(host) == "string" then
        c.hostName = personName(world, host)
        if actor and host == actor.id then c.isHost = true end
    end
    for k, conv in pairs(CONVERT) do
        if c[k] ~= nil then c[k] = conv(world, c[k]) end
    end
    return c
end

-- Who the line is said to: ctx.listener, else the person the caller targets (target, with, the
-- host of a visit), never the speaker.
function L.ListenerOf(world, actor, ctx)
    local lis = ctx.listener
    if lis == nil then
        for _, k in ipairs({ "target", "with" }) do if ctx[k] ~= nil then lis = ctx[k]; break end end
        if lis == nil and type(ctx.host) == "string" and not (actor and ctx.host == actor.id) then lis = ctx.host end
    end
    if type(lis) == "string" then lis = person(world, lis) end
    if type(lis) ~= "table" or (actor and lis.id == actor.id) then return nil end
    return lis
end

function L.Context(world, actor, situation, ctx)
    ctx = ctx or {}
    local need = L.sitNeeds[situation] or {}
    local c = L.Normalize(world, actor, ctx)
    local M = L.meta and L.meta[situation]
    if c.role == nil and M and M.defaultRole then c.role = M.defaultRole end
    if actor then
        c.speaker = firstName(actor)
        c.age = actor.age
        for _, d in ipairs(P.DIMS) do c[d] = P.Get(actor, d) end
        if need.mood then c.mood = P.Mood(actor, world) end
        if world.lot and actor.x then
            if need.roomScore then c.roomScore = L.RoomScoreAt(world, actor) end
            if need.mess or need.messDef then
                local n, def = L.MessNear(world, actor)
                c.mess, c.messDef = n, def
            end
            if need.witnesses then c.witnesses = L.Witnesses(world, actor, 6, ctx.listener and { [type(ctx.listener) == "table" and ctx.listener.id or ctx.listener] = true }) end
        end
        c.guest = (world.household and actor.householdId ~= world.household.id) or nil
    end
    c.hour = math.floor((world.time or 0) / 60) % 24
    c.money = world.money
    c.venue = (world.lot and world.lot.kind == "community") or nil
    -- listener-derived keys
    local lis = L.ListenerOf(world, actor, ctx)
    if lis then
        c.other = firstName(lis)
        c.otherAge = lis.age
        if need.otherMood then c.otherMood = P.Mood(lis, world) end
        if actor and SS.Social then
            local r = SS.Social.Get(world, actor.id, lis.id)
            c.rel = r and r.life or 0
            c.daily = r and r.daily or 0
            c.family = SS.Social.FamilyKind(world, actor.id, lis.id)
            c.partner = SS.Social.IsPartner(world, actor.id, lis.id) or nil
        end
        if c.topic then
            c.interest = P.Interest(lis, c.topic)
        end
    elseif c.name then
        c.other = c.name   -- the person the caller names is who the line is about
    end
    if actor and c.topic then c.myInterest = P.Interest(actor, c.topic) end
    -- objects must really be on this lot (unless the caller says the object is elsewhere)
    if ctx.oid and world.lot and world.lot.objects[ctx.oid] then c.objDef = world.lot.objects[ctx.oid].def end
    if c.objDef then
        if not SS.Objects[c.objDef] or (not ctx.offLot and not objOnLot(world, c.objDef)) then c.objDef = nil
        else c.objPrice = SS.Objects[c.objDef].price end
    end
    if c.messDef and not SS.Objects[c.messDef] then c.messDef = nil end
    return c
end

local function check(cond, c)
    local v = c[cond.key]
    local op = cond.op
    if op == "has" then return v ~= nil and v ~= false end
    if op == "not" then return v == nil or v == false end
    if v == nil then return false end
    if op == "=" then return v == cond.val end
    if op == "~=" then return v ~= cond.val end
    if type(v) ~= "number" or type(cond.val) ~= "number" then return false end
    if op == ">=" then return v >= cond.val elseif op == "<=" then return v <= cond.val
    elseif op == ">" then return v > cond.val elseif op == "<" then return v < cond.val end
    return false
end

local function slotValue(slot, c)
    local k = L.SLOTS[slot]
    local v = k and c[k]
    if v == nil then return nil end
    if slot == "topic" then local t = SS.Topics.byId[v]; return t and t.noun or tostring(v) end
    if slot == "obj" or slot == "mess" then
        local d = SS.Objects[v]
        if not d or not d.name then return nil end
        -- generic system objects (a dirty plate, a puddle) read as common nouns mid-sentence
        if d.cat == "system" or d.buyable == false then return d.name:lower() end
        return d.name
    end
    if slot == "amount" then return U.fmtMoney(v) end
    if type(v) == "number" then return tostring(math.floor(v + 0.5)) end
    return tostring(v)
end

function L.Eligible(line, c)
    for _, cond in ipairs(line.conds) do if not check(cond, c) then return false end end
    for _, s in ipairs(line.slots) do if slotValue(s, c) == nil then return false end end
    return true
end

-- Fill slots; a slot that starts a sentence is capitalised ("Music. Fascinating.").
function L.Fill(text, c)
    local out, pos = {}, 1
    while true do
        local a, b, s = text:find("{(%w+)}", pos)
        if not a then break end
        local before = text:sub(pos, a - 1)
        out[#out + 1] = before
        local v = slotValue(s, c)
        if v == nil then v = "{" .. s .. "}"
        else
            local sofar = table.concat(out):gsub("%s+$", "")
            if sofar == "" or (sofar:find("[%.!?]$") and not sofar:find("%.%.%.$")) then v = v:sub(1, 1):upper() .. v:sub(2) end
        end
        out[#out + 1] = v
        pos = b + 1
    end
    out[#out + 1] = text:sub(pos)
    return table.concat(out)
end

-- Every line of a situation that fits this context (no side effects).
function L.Candidates(world, actor, situation, ctx, c)
    c = c or L.Context(world, actor, situation, ctx)
    local out = {}
    for _, line in ipairs(L.bySit[situation] or {}) do
        if L.Eligible(line, c) then out[#out + 1] = line end
    end
    return out, c
end

---------------------------------------------------------------------------
-- Memory and frequency
---------------------------------------------------------------------------
local rt = { actorT = {}, sitT = {}, hourly = {} }  -- runtime only; reset on attach
L.rt = rt

local function store(world)
    local root = world.root or world
    root.social = root.social or {}
    local s = root.social.lines
    if type(s) ~= "table" then s = {}; root.social.lines = s end
    s.mem = s.mem or {}
    s.log = s.log or {}
    return s
end
L.Store = store

local function hhKey(world, actor)
    return (actor and actor.householdId) or (world.household and world.household.id) or "none"
end

local function memFor(world, hh)
    local s = store(world)
    local m = s.mem[hh]
    if not m then m = { order = {}, at = {} }; s.mem[hh] = m end
    return m
end

local function remember(world, hh, id)
    local m = memFor(world, hh)
    if m.at[id] then
        for i = #m.order, 1, -1 do if m.order[i] == id then table.remove(m.order, i); break end end
    end
    m.order[#m.order + 1] = id
    m.at[id] = world.time or 0
    while #m.order > L.MEMORY do
        local old = table.remove(m.order, 1)
        m.at[old] = nil
    end
end

-- Is this situation allowed to speak now? (per actor, per situation, hourly cap)
-- The situation gap is kept per role, so a reply ("role=listener") may follow an opener of the
-- same situation within one exchange.
local function sitKey(world, actor, situation, ctx)
    return hhKey(world, actor) .. ":" .. situation .. ":" .. tostring(ctx and ctx.role or "")
end

function L.Allowed(world, actor, situation, ctx)
    local now = world.time or 0
    local M = meta(situation)
    local important = M.important
    if actor and not important then
        local t = rt.actorT[actor.id]
        if t and now - t < L.ACTOR_GAP and now >= t then return false, "speaker gap" end
    end
    local hh = hhKey(world, actor)
    local sk = sitKey(world, actor, situation, ctx)
    local gap = M.gap or (important and 1 or L.SITUATION_GAP)
    local st = rt.sitT[sk]
    if st and now - st < gap and now >= st then return false, "situation gap" end
    if not important then
        local h = rt.hourly[hh]
        if h and now - h.start < 60 and now >= h.start and h.n >= L.HOURLY_CAP then return false, "hourly cap" end
    end
    return true
end

local function mark(world, actor, situation, ctx)
    local now = world.time or 0
    local hh = hhKey(world, actor)
    if actor then rt.actorT[actor.id] = now end
    rt.sitT[sitKey(world, actor, situation, ctx)] = now
    local h = rt.hourly[hh]
    if not h or now - h.start >= 60 or now < h.start then h = { start = now, n = 0 }; rt.hourly[hh] = h end
    h.n = h.n + 1
end

-- Choose among fitting lines, avoiding remembered ones; weighted by line weight.
local function choose(world, hh, list, important)
    local m = memFor(world, hh)
    local fresh, total = {}, 0
    for _, line in ipairs(list) do
        if not m.at[line.id] then fresh[#fresh + 1] = line; total = total + line.w end
    end
    if #fresh == 0 then
        -- everything fitting was said recently: the least recently used may return after a while
        local best, bt
        for _, line in ipairs(list) do
            local t = m.at[line.id] or -1e9
            if not bt or t < bt or (t == bt and line.id < best.id) then best, bt = line, t end
        end
        if best and (important or (world.time or 0) - bt >= L.REUSE_AFTER) then return best end
        return nil
    end
    local r = SS.Random(world, "lines") * total
    for _, line in ipairs(fresh) do
        r = r - line.w
        if r <= 0 then return line end
    end
    return fresh[#fresh]
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- Pick an authored line for a situation, checking its conditions against ctx and real state;
-- remembers it so it doesn't repeat. Returns text, lineId (or nil, reason).
function L.Say(world, actor, situation, ctx)
    if not world or not L.bySit[situation] then return nil, "no lines for " .. tostring(situation) end
    local ok, why = L.Allowed(world, actor, situation, ctx)
    if not ok then return nil, why end
    local list, c = L.Candidates(world, actor, situation, ctx)
    if #list == 0 then return nil, "no line fits the situation" end
    local hh = hhKey(world, actor)
    local line = choose(world, hh, list, meta(situation).important)
    if not line then return nil, "all fitting lines said recently" end
    local text = L.Fill(line.text, c)
    remember(world, hh, line.id)
    mark(world, actor, situation, ctx)
    L.Log(world, actor, situation, line, text, c)
    SS.Emit("lineSaid", world, actor, situation, line.id, text)
    return text, line.id
end

-- Say and show it in the speaker's balloon (icon from the situation, or opts.icon).
function L.Speak(world, actor, situation, ctx, opts)
    local text, id = L.Say(world, actor, situation, ctx)
    if text and actor then
        local M = meta(situation)
        actor.balloon = { icon = (opts and opts.icon) or M.icon or "bubble", text = text,
            untilT = (world.time or 0) + ((opts and opts.dur) or 3), kind = (opts and opts.kind) or "speech" }
    end
    return text, id
end

local function clockText(t)
    if SS.Sim and SS.Sim.ClockText then return SS.Sim.ClockText(t) end
    return tostring(math.floor(t))
end

-- Bounded log with expandable detail; notable situations also go to the household journal.
function L.Log(world, actor, situation, line, text, c)
    local s = store(world)
    local M = meta(situation)
    local who = c.speaker or (world.household and world.household.name) or "Someone"
    local detail = string.format("%s, %s%s (%s): \"%s\"", clockText(world.time or 0), who,
        c.other and (" to " .. c.other) or "", M.label or situation, text)
    if c.objDef and SS.Objects[c.objDef] then detail = detail .. " About: " .. SS.Objects[c.objDef].name .. "." end
    if c.topic and SS.Topics.byId[c.topic] then detail = detail .. " Topic: " .. SS.Topics.byId[c.topic].name .. "." end
    if line.detail then
        local okDetail = true
        for slot in line.detail:gmatch("{(%w+)}") do if slotValue(slot, c) == nil then okDetail = false end end
        if okDetail then detail = detail .. " " .. L.Fill(line.detail, c) end
    end
    s.log[#s.log + 1] = { t = world.time or 0, rid = actor and actor.id, s = situation, id = line.id, text = text,
        who = who, other = c.other, detail = detail, hh = hhKey(world, actor) }
    while #s.log > L.LOG_CAP do table.remove(s.log, 1) end
    if M.journal and SS.Actions and SS.Actions.Journal and world.household then
        pcall(SS.Actions.Journal, world, who .. ": \"" .. text .. "\"")
    end
end

-- Most recent log entries, newest first (optionally for one household).
function L.Recent(world, n, hh)
    local s = store(world)
    local out = {}
    for i = #s.log, 1, -1 do
        local e = s.log[i]
        if not hh or e.hh == hh then out[#out + 1] = e end
        if #out >= (n or 20) then break end
    end
    return out
end

-- Audit for A29 and the content manifest: counts, duplicates, coverage, unknown keys and slots.
local FRANCHISE = { "sims", "simlish", "maxis", "sul sul", "dag dag", "llama", "plumbob", "electronic arts", "sim city" }
L.OBJECT_NOUNS = { "piano", "sofa", "couch", "fridge", "refrigerator", "armchair", "painting", "television", " tv",
    "stereo", "toilet", "shower", "bathtub", "oven", "stove", "sink", "lamp", "rug", "computer", "aquarium",
    "fireplace", "treadmill", "easel", "chess", "bookshelf", "mirror", "dishwasher", "microwave", "chandelier", "statue",
    "sculpture", "vase", "grill", "hot tub", "jukebox", "pinball", "telescope" }
function L.Audit()
    local rep = { total = #L.lines, ids = {}, dupIds = {}, dupText = {}, unknownKeys = {}, unknownSlots = {},
        missing = {}, perSit = {}, tooLong = {}, franchise = {}, objNoCond = {} }
    local seenText = {}
    for _, e in ipairs(L.lines) do
        if rep.ids[e.id] then rep.dupIds[#rep.dupIds + 1] = e.id end
        rep.ids[e.id] = true
        local norm = e.text:lower():gsub("{%w+}", "{}"):gsub("[^%w{}]", "")
        if seenText[norm] then rep.dupText[#rep.dupText + 1] = e.id .. "=" .. seenText[norm] end
        seenText[norm] = e.id
        rep.perSit[e.s] = (rep.perSit[e.s] or 0) + 1
        local hasObj = false
        for _, c in ipairs(e.conds) do
            if not L.CTX_KEYS[c.key] then rep.unknownKeys[#rep.unknownKeys + 1] = e.id .. ":" .. c.key end
            if c.key == "objDef" then hasObj = true end
        end
        for _, s in ipairs(e.slots) do
            if not L.SLOTS[s] then rep.unknownSlots[#rep.unknownSlots + 1] = e.id .. ":" .. s end
            if s == "obj" then hasObj = true end
        end
        for s in (e.detail or ""):gmatch("{(%w+)}") do
            if not L.SLOTS[s] then rep.unknownSlots[#rep.unknownSlots + 1] = e.id .. ":detail:" .. s end
        end
        if e.detail then rep.details = (rep.details or 0) + 1 end
        if #e.text > 100 then rep.tooLong[#rep.tooLong + 1] = e.id end
        local low = " " .. e.text:lower()
        for _, f in ipairs(FRANCHISE) do if low:find(f, 1, true) then rep.franchise[#rep.franchise + 1] = e.id end end
        if not hasObj then
            for _, noun in ipairs(L.OBJECT_NOUNS) do
                if low:find(noun, 1, true) then rep.objNoCond[#rep.objNoCond + 1] = e.id .. ":" .. noun end
            end
        end
    end
    for _, s in ipairs(L.REQUIRED) do if not rep.perSit[s] then rep.missing[#rep.missing + 1] = s end end
    local distinct = 0
    for _ in pairs(seenText) do distinct = distinct + 1 end
    rep.distinct = distinct
    return rep
end

-- Runtime frequency state never outlives a lot session.
SS.On("worldAttached", function() rt.actorT, rt.sitT, rt.hourly = {}, {}, {} end)

-- Save validator: bounded memory and log.
if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        local s = root.social and root.social.lines
        if s == nil then return end
        if type(s) ~= "table" then root.social.lines = nil; return end
        s.mem = type(s.mem) == "table" and s.mem or {}
        s.log = type(s.log) == "table" and s.log or {}
        for hh, m in pairs(s.mem) do
            if type(m) ~= "table" or type(m.order) ~= "table" or type(m.at) ~= "table" then s.mem[hh] = nil
            else
                while #m.order > L.MEMORY do m.at[table.remove(m.order, 1)] = nil end
            end
        end
        for i = #s.log, 1, -1 do if type(s.log[i]) ~= "table" or type(s.log[i].text) ~= "string" then table.remove(s.log, i) end end
        while #s.log > L.LOG_CAP do table.remove(s.log, 1) end
    end)
end
