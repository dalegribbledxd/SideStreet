-- Visible conversations: approach, engage, take turns, react, resolve, group sessions.
-- Owner: social module. Every social definition (Data/Socials.lua) is an executor interaction
-- "soc_<id>" (targetActor = true). The initiator routes next to the target through the normal
-- executor; on arrival the target stops what it is doing (or declines when busy or unwilling) and
-- joins a conversation session by taking the "social_chat" action, which routes it into a
-- conversational position facing the speaker. A session (runtime only) runs exchanges one at a
-- time: the speaker talks (pose, topic icon, optional caption), the listener reacts (laugh,
-- argue, cry...), the outcome is resolved from relationship, mood, personality, interests,
-- audience, repetition and setting, and daily/life/romance/rivalry change asymmetrically.
-- Sessions are bounded (members, length, idle time, per-member stay, fatigue) and are rebuilt
-- from nothing on load, so a save made mid-conversation never leaves anyone stuck.
local _, SS = ...
local U, P, So, L = SS.U, SS.Personality, SS.Social, SS.Lines
local G = SS.Grid
local S = SS.Socials
local C = {
    MAX_MEMBERS = 6,      -- people in one conversation
    JOIN_TIMEOUT = 5,     -- minutes a pulled-in person has to set off before they are dropped
    JOIN_WALK = 12,       -- minutes someone already on their way has to arrive (across a house)
    IDLE_END = 3,         -- minutes of silence before a conversation breaks up
    MAX_SESSION = 150,    -- minutes a conversation can last at most
    MAX_STAY = 100,       -- minutes one person stays at most
    LEAVE_FATIGUE = 0.85, -- social fatigue at which people excuse themselves
    RADIUS = 3.3,         -- tiles from the conversation's anchor before someone has wandered off
    CHASE = 3,            -- times an initiator re-routes after a target that moved
    GAP = 0.5,            -- minutes between exchanges
    CALLED_AWAY = 20,     -- minutes someone the player called out of a conversation won't start or
                          -- be pulled into another one on their own
}
SS.Conversation = C

C.sessions, C.byActor, C.nextId, C.epoch = {}, {}, 1, 1
local deferred = {}

local function now(world) return world.time or 0 end
local function first(p) return (p and p.name and (p.name:match("^(%S+)") or p.name)) or "Someone" end
C.First = first

local function human(a)
    return a and (a.kind == nil or a.kind == "human") and a.age ~= "infant" and not a.dead and not a.ghost and a.needs ~= nil
end
C.Human = human

-- Mood during one autonomy scan: P.Mood is pure in the needs, which don't change while one person
-- thinks, so the scan remembers it per person (C.ScanBegin starts a new scan).
local moodMemo, moodSerial, scanSerial = setmetatable({}, { __mode = "k" }), setmetatable({}, { __mode = "k" }), 0
local function mood(p)
    if scanSerial > 0 and moodSerial[p] == scanSerial then return moodMemo[p] end
    local m = P.Mood(p)
    if scanSerial > 0 then moodMemo[p], moodSerial[p] = m, scanSerial end
    return m
end
C.MoodOf = mood
-- Serials only ever grow (1, 2, 3, ...; negative between scans), so a memo belongs to exactly one
-- scan: a later scan never reuses an earlier scan's mood, whatever ran before (determinism).
function C.ScanBegin() scanSerial = (scanSerial < 0 and -scanSerial or scanSerial) + 1 end
function C.ScanEnd() if scanSerial > 0 then scanSerial = -scanSerial end end

local function dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- Someone talking from a seat (another module's meal or bench the talk joined) keeps the seat's
-- facing and a sitting pose.
local function face(a, b)
    if a and b and not a.onObj and (a.x ~= b.x or a.y ~= b.y) then a.facing = G.dirToFacing(b.x - a.x, b.y - a.y) end
end

local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end
-- Same, into a caller-owned scratch list (per-step paths build no table). Returns out, n.
local function sortedInto(t, out)
    local n = 0
    for k in pairs(t) do n = n + 1; out[n] = k end
    for k = #out, n + 1, -1 do out[k] = nil end
    if n > 1 then table.sort(out) end
    return out, n
end

-- Sorted ids of the people on the lot, cached until someone arrives or leaves, so the per-step
-- paths build no list. The returned list is shared: read it, never modify it.
local idsCache = { list = {}, n = -1 }
local function actorIds(world)
    local c = idsCache
    local actors = world.actors
    local n = 0
    for _ in pairs(actors) do n = n + 1 end
    if c.world == world and c.n == n then
        local list, same = c.list, true
        for k = 1, #list do if not actors[list[k]] then same = false; break end end
        if same then return list end
    end
    local list = {}
    for id in pairs(actors) do list[#list + 1] = id end
    table.sort(list)
    c.list, c.n, c.world = list, n, world
    return list
end
C.ActorIds = actorIds

-- Free will: without it nobody starts anything on their own (a reaction is shown, never queued).
local function autonomyOn(world) return world.settings and world.settings.freeWill and true or false end
C.AutonomyOn = autonomyOn

-- Need lists walked on hot paths (never rebuilt per call).
local URGENT3 = { "hunger", "bladder", "energy" }
local URGENT4 = { "hunger", "bladder", "energy", "hygiene" }

---------------------------------------------------------------------------
-- Who is who on this lot
---------------------------------------------------------------------------
local SOCIAL_ACCESS = { guest = true, public = true, household = true }
function C.RoleSocial(a)
    if not a.role then return true end
    local def = (SS.Visitors and SS.Visitors.roles and SS.Visitors.roles[a.role]) or (SS.Roles and SS.Roles[a.role])
    if not def or def.access == nil then return true end
    if def.social ~= nil then return def.social and true or false end
    return SOCIAL_ACCESS[def.access] or false
end

-- A visitor the visitors framework is still bringing in or seeing off (its documented states in
-- actor.roleData.vs: arriving, approach, door, leaving, passing) isn't available for a chat: the
-- door is answered, and passers-by are called over, through the visitors module. Returns why.
local VISITOR_AWAY = {
    arriving = " is still on the way.", approach = " is still on the way.", door = " is at the door. Answer it first.",
    leaving = " is on the way out.", passing = " is just passing by. Call them over first.",
}
function C.VisitorUnavailable(b)
    local rd = b.role and b.roleData
    local vs = type(rd) == "table" and rd.vs
    local st = type(vs) == "table" and vs.state
    local why = st and VISITOR_AWAY[st]
    return why and (first(b) .. why) or nil
end

-- Member of the household that lives on this lot. With the visitors framework loaded, a member
-- wearing a role is whatever SS.Visitors.IsMember says (a resident role such as a pet's or a
-- baby's counts; so do the street's walks home and out, when visitors counts them); before it,
-- any role means someone who doesn't live here.
function C.IsResident(world, a)
    local hh = world.household
    if not (hh and hh.lotId == world.lot.id and a.householdId == hh.id) or a.dead then return false end
    local V = SS.Visitors
    if a.role and V and V.IsMember then return V.IsMember(world, a) and true or false end
    return not a.role
end
function C.IsHost(world, a) return C.IsResident(world, a) end
-- Someone on the lot who doesn't live here: a visitor the framework runs (SS.Visitors.IsVisitor),
-- or anyone from another household. Before the visitors module, any role counts as a visitor.
function C.IsVisitor(world, b)
    local V = SS.Visitors
    if b.role then
        if not (V and V.IsVisitor and V.Owns) then return true end
        if V.IsVisitor(world, b) then return true end
        -- a resident's walk in or out, or a resident role: decided by household below
    end
    local hh = world.household
    if not hh or hh.lotId ~= world.lot.id then return false end
    return b.householdId ~= hh.id
end

local function ageOk(age, want)
    if want == "any" then return age == "adult" or age == "child" end
    return age == want
end

local EMPTY = { daily = 0, life = 0, romance = 0, rivalry = 0, flags = {}, last = {} }
-- Both directions of a pair, filled into t (the autonomy scan reuses one table; nothing here
-- builds a string).
function C.PairInto(world, a, b, t)
    local ab = So.Out(world, a.id)[b.id]
    local ba = So.Out(world, b.id)[a.id]
    local fam = ab and ab.flags.family
    if not fam and ba and ba.flags.family then fam = So.INVERSE[ba.flags.family] or ba.flags.family end
    t.ab, t.ba = ab or EMPTY, ba or EMPTY
    t.sameHH = So.SameHousehold(world, a.id, b.id)
    -- people who live together know each other, with or without a relationship record yet
    t.met = ((ab and ab.flags.met) or (ba and ba.flags.met) or t.sameHH) and true or false
    t.fam = fam
    t.partner = (ab and (ab.flags.partner or ab.flags.married or ab.flags.family == "spouse")) and true or false
    return t
end
function C.Pair(world, a, b) return C.PairInto(world, a, b, {}) end

---------------------------------------------------------------------------
-- Items, subjects, topics
---------------------------------------------------------------------------
-- A gift-able item of a kind ("gift", "flowers", "book") in the actor's household inventory.
function C.Items(world, a, kind)
    local root = world.root or world
    local hh = root.households and root.households[a.householdId]
    local out = {}
    for _, it in ipairs(hh and hh.inventory or {}) do
        local k = it.kind
        local ok = k == kind or (kind == "flowers" and it.data and it.data.flowers)
            or (kind == "gift" and it.data and it.data.giftable and k ~= "flowers")
        -- a present another member of the household received is theirs, not a's to give away
        local owner = ok and type(it.data) == "table" and it.data.owner
        if owner and owner ~= a.id then
            local o = root.residents and root.residents[owner]
            if o and not o.dead and o.householdId == a.householdId then ok = false end
        end
        if ok then out[#out + 1] = it end
    end
    return out, hh
end

function C.HasBook(world, a)
    if #C.Items(world, a, "book") > 0 then return true end
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        if def and (SS.Tags.Has(def, "bookshelf") or SS.Tags.Has(def, "book")) then return true end
    end
    return false
end

-- Someone a knows well enough to gossip about or imitate (not b, alive). Strongest feelings first.
function C.Subject(world, a, b)
    local best, bw
    local residents = (world.root or world).residents
    for id, r in pairs(So.Out(world, a.id)) do
        if id ~= b.id and id ~= a.id then
            local p = residents[id]
            if p and not p.dead and r.flags.met then
                local w = math.abs(r.life) + math.abs(r.daily) * 0.5
                if not bw or w > bw or (w == bw and id < best) then best, bw = id, w end
            end
        end
    end
    return best
end

-- Topic for an exchange by the definition's rule.
function C.PickTopic(world, a, b, rule)
    if rule == "speaker" then return (P.Favourite(a)) end
    if rule == "speaker_love" then return P.Loves(a)[1] or (P.Favourite(a)) end
    if rule == "listener" then return (P.Favourite(b)) end
    if rule == "safe" then return SS.Random(world, "social") < 0.6 and "weather" or "townnews" end
    if rule == "shared" then
        local best, bv
        for _, t in ipairs(SS.Topics.list) do
            if (a.age ~= "child" and b.age ~= "child") or t.kid then
                local v = math.min(P.Interest(a, t.id), P.Interest(b, t.id))
                if v >= 4 and (not bv or v > bv) then best, bv = t.id, v end
            end
        end
        return best
    end
    return nil
end

function C.Venues(world)
    local out = {}
    local root = world.root or world
    for id, lot in pairs(root.hood and root.hood.lots or {}) do
        if lot.kind == "community" and id ~= world.lot.id then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

local GUARDIAN = { parent = true, guardian = true, grandparent = true, aunt_uncle = true, step_parent = true }

-- Recently misbehaved child (mean socials within 6 h, or a failed tease/argue).
function C.Misbehaved(world, child)
    local t0 = now(world) - 360
    for _, r in pairs(So.Out(world, child.id)) do
        local last = r.last
        for i = #last, 1, -1 do
            local e = last[i]
            if e.t < t0 then break end
            local sd = S.byId[e.id]
            if e.me and sd and sd.kind == "hostile" and e.id ~= "scold" then return true end
            if e.me and not e.ok and (e.id == "tease" or e.id == "tickle") then return true end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Prerequisites (menus and autonomy use exactly the same checks)
---------------------------------------------------------------------------
-- C.CHECKS[k](world, a, b, pc, v) -> true/false only. The player-facing reason is built by
-- C.WHY[k] only when a menu or an order needs it, so the autonomy scan never makes strings.
C.CHECKS = {
    met = function(w, a, b, pc) return pc.met end,
    unmet = function(w, a, b, pc) return not pc.met end,
    minLife = function(w, a, b, pc, v) return pc.ab.life >= v end,
    theirLife = function(w, a, b, pc, v) return pc.ba.life >= v end,
    maxLife = function(w, a, b, pc, v) return pc.ab.life <= v end,
    closeOrFamily = function(w, a, b, pc, v)
        return pc.ab.life >= v or pc.fam ~= nil or pc.partner or (pc.sameHH and pc.ab.life >= v - 20)
    end,
    family = function(w, a, b, pc) return pc.fam ~= nil end,
    household = function(w, a, b, pc) return pc.sameHH end,
    notHousehold = function(w, a, b, pc) return not pc.sameHH end,
    romance = function(w, a, b, pc) return So.RomanceAllowed(w, a.id, b.id) end,
    crush = function(w, a, b, pc, v) return (pc.ab.romance or 0) >= v end,
    romanceBoth = function(w, a, b, pc, v) return pc.partner or ((pc.ab.romance or 0) >= v and (pc.ba.romance or 0) >= v * 0.5) end,
    partner = function(w, a, b, pc) return pc.partner end,
    notPartner = function(w, a, b, pc) return not pc.partner end,
    notTaken = function(w, a, b, pc) return not So.HasOtherPartner(w, a.id, b.id) and not So.HasOtherPartner(w, b.id, a.id) end,
    upset = function(w, a, b, pc) return So.Upset(w, b.id) ~= nil or mood(b) < -20 end,
    selfLow = function(w, a, b, pc) return So.Upset(w, a.id) ~= nil or mood(a) < 5 end,
    conflict = function(w, a, b, pc) return So.Conflict(w, a.id, b.id) ~= nil end,
    owed = function(w, a, b, pc)
        local e = So.Last(w, a.id, b.id, nil, false, true)
        local sd = e and S.byId[e.id]
        return e and sd and (sd.kind == "kind" or sd.cat == "Affection") and now(w) - e.t <= 1440 or false
    end,
    visitor = function(w, a, b, pc) return C.IsVisitor(w, b) end,
    host = function(w, a, b, pc) return C.IsHost(w, a) end,
    item = function(w, a, b, pc, v) return C.HasItem(w, a, v) end,
    book = function(w, a, b, pc) return C.HasBook(w, a) end,
    mess = function(w, a, b, pc) return C.LotMess(w) > 0 end,
    loves = function(w, a, b, pc) return C.LovesAny(a) end,
    subject = function(w, a, b, pc) return C.Subject(w, a, b) ~= nil end,
    session = function(w, a, b, pc)
        local s = C.SessionOf(b.id)
        return s ~= nil and not s.members[a.id] and C.Count(s) < C.MAX_MEMBERS
    end,
    venue = function(w, a, b, pc) return (SS.Travel and SS.Travel.Go) and #C.Venues(w) > 0 or false end,
    guardianOf = function(w, a, b, pc)
        local k = So.FamilyKind(w, a.id, b.id)
        return (k and GUARDIAN[k]) or (pc.sameHH and a.age == "adult") or false
    end,
    energy = function(w, a, b, pc, v) return (a.needs.energy or 0) >= v and (b.needs.energy or 0) >= v end,
}

C.WHY = {
    met = function() return "You haven't been introduced yet." end,
    unmet = function() return "You already know each other." end,
    minLife = function() return "You'd need to be closer first." end,
    theirLife = function(w, a, b) return first(b) .. " isn't close enough to you." end,
    maxLife = function() return "You get on too well for that." end,
    closeOrFamily = function() return "Only for close friends and family." end,
    family = function() return "Only between relatives." end,
    household = function() return "Only for people who live together." end,
    notHousehold = function(w, a, b) return first(b) .. " already lives with you." end,
    romance = function(w, a, b) return select(2, So.CanRomance(w, a.id, b.id)) end,
    crush = function(w, a, b) return "You'd need stronger feelings for " .. first(b) .. " first." end,
    romanceBoth = function() return "The spark isn't mutual yet." end,
    partner = function() return "You're not together." end,
    notPartner = function() return "You're already together." end,
    notTaken = function(w, a, b)
        if So.HasOtherPartner(w, a.id, b.id) then return "You're already spoken for." end
        return first(b) .. " is already spoken for."
    end,
    upset = function(w, a, b) return first(b) .. " seems fine." end,
    selfLow = function() return "You've nothing much to complain about." end,
    conflict = function() return "There's nothing to apologise for." end,
    owed = function(w, a, b) return first(b) .. " hasn't done anything for you lately." end,
    visitor = function(w, a, b) return first(b) .. " lives here." end,
    host = function() return "Only the people who live here can do that." end,
    item = function(w, a, b, pc, v) return "There's no " .. tostring(v) .. " in the household inventory." end,
    book = function() return "You need a book in the inventory or a bookshelf on the lot." end,
    mess = function() return "Nothing is out of place right now." end,
    loves = function() return "Nothing excites you enough to gush about." end,
    subject = function() return "You don't know anyone else to talk about." end,
    session = function(w, a, b)
        local s = C.SessionOf(b.id)
        if s and s.members[a.id] then return "You're already in that conversation." end
        if s then return "That conversation is full." end
        return first(b) .. " isn't in a conversation."
    end,
    venue = function()
        if not (SS.Travel and SS.Travel.Go) then return "Outings aren't available." end
        return "There are no community venues to visit."
    end,
    guardianOf = function() return "Only for children in your care." end,
    energy = function() return "Someone is too tired for that." end,
}

-- Does a love any topic? (P.Loves without building the list.)
function C.LovesAny(a)
    local love = SS.Topics.LOVE
    for _, t in ipairs(SS.Topics.list) do if P.Interest(a, t.id) >= love then return true end end
    return false
end

-- A gift-able item of this kind exists (no list is built).
function C.HasItem(world, a, kind)
    return #C.Items(world, a, kind) > 0
end

-- Mess on the lot, counted at most once per sim minute (the autonomy scan asks per person).
function C.LotMess(world)
    local c = C.messCache
    local t = now(world)
    if c and c.t == t and c.lot == world.lot then return c.n, c.def end
    local n, def = L.MessOnLot(world)
    c = c or {}
    c.t, c.lot, c.n, c.def = t, world.lot, n, def
    C.messCache = c
    return n, def
end

local function hoursText(minutes)
    if minutes < 60 then return math.max(1, math.ceil(minutes)) .. " min" end
    return string.format("%.1f h", minutes / 60)
end

-- Can a start definition d with b? Same rules for the menu, manual orders and autonomy.
-- quiet = true (the autonomy scan): the answer only, no reason text is built.
function C.CanStart(world, a, b, d, pc, quiet)
    if not d then return false, "Unknown interaction." end
    if not b or not a or b == a or b.id == a.id then return false, "Nobody there." end
    if not human(a) then return false, "Can't do that." end
    if not human(b) then return false, quiet or (first(b) .. " can't chat.") end
    if not ageOk(a.age, d.who) then return false, d.who == "adult" and "Only adults can do that." or "Only children can do that." end
    if not ageOk(b.age, d.whom) then return false, d.whom == "adult" and "Only with adults." or "Only with children." end
    if a.age == "child" and d.whom == "child" and b.age ~= "child" then return false, "Only with children." end
    if not C.RoleSocial(a) then return false, "Busy working." end
    if not C.RoleSocial(b) and d.id ~= "ask_leave" then return false, quiet or (first(b) .. " is working.") end
    if b.role then
        local away = C.VisitorUnavailable(b)
        if away then return false, quiet or away end
    end
    if a.role and C.VisitorUnavailable(a) then return false, quiet or "Not now." end
    if b.sleeping then return false, quiet or (first(b) .. " is asleep.") end
    if So.AnyCooldown(world, a.id, b.id) then
        local cd = So.Cooldown(world, a.id, b.id, d.id)
        if cd then return false, quiet or (first(b) .. " turned this down recently (try again in " .. hoursText(cd - now(world)) .. ").") end
        if d.kind == "romantic" and So.Cooldown(world, a.id, b.id, "romance") then
            return false, quiet or (first(b) .. " isn't in the mood for romance with you right now.")
        end
        if d.kind ~= "hostile" and So.Cooldown(world, a.id, b.id, "talk") then
            return false, quiet or (first(b) .. " brushed you off a moment ago.")
        end
        if So.Cooldown(world, a.id, b.id, "busy") then
            local busy = C.Busy(world, b, a, d)
            if busy then return false, quiet or (busy .. " Leave them be for now.") end
        end
    end
    pc = pc or C.Pair(world, a, b)
    local order = d.needOrder
    if not order then
        order = {}
        for k in pairs(d.need) do order[#order + 1] = k end
        table.sort(order)   -- deterministic: the same reason is shown every time
        d.needOrder = order
    end
    local need = d.need
    for n = 1, #order do
        local k = order[n]
        local chk = C.CHECKS[k]
        if chk and not chk(world, a, b, pc, need[k]) then
            if quiet then return false, k end
            local why = C.WHY[k]
            return false, why and why(world, a, b, pc, need[k]) or "Not possible right now."
        end
    end
    local sp = C.SPECIAL[d.id]
    if sp and sp.check then
        local ok, why = sp.check(world, a, b, pc, quiet)
        if not ok then return false, why end
    end
    return true
end

-- Is b busy right now? Returns a reason or nil. quiet = true (the autonomy scan): true instead of
-- the reason, so asking builds no text. The checks read flags, the action and queue, and needs.
function C.Busy(world, b, a, d, quiet)
    if b.sleeping then return quiet or (first(b) .. " is asleep.") end
    local act = b.act
    if act then
        local conv = act.data and act.data.conv
        if conv and C.sessions[conv] then return nil end
        local ia = SS.Interactions[act.iid]
        if ia and ia.sleeping then return quiet or (first(b) .. " is resting.") end
        if act.manual then
            if quiet then return true end
            local label = act.label or (ia and ia.label) or act.iid
            return first(b) .. " is busy (" .. tostring(label) .. ")."
        end
        if act.target and act.target.on then
            local o = world.lot.objects[act.target.oid]
            local def = o and SS.Objects[o.def]
            if (ia and ia.privacy) or (def and (SS.Tags.Has(def, "toilet") or SS.Tags.Has(def, "shower") or SS.Tags.Has(def, "bath")))
                or act.iid == "toilet" or act.iid == "shower" then
                return quiet or (first(b) .. " is busy in the bathroom.")
            end
        end
    end
    local queue = b.queue
    if queue then
        for n = 1, #queue do
            if queue[n].manual then return quiet or (first(b) .. " has something to do.") end
        end
    end
    if not C.RoleSocial(b) and not (d and d.id == "ask_leave") then return quiet or (first(b) .. " is working.") end
    if not (d and d.kind == "hostile") then
        local T = SS.Tuning
        for n = 1, #URGENT4 do
            if (b.needs[URGENT4[n]] or 0) < T.urgent then return quiet or (first(b) .. " has more pressing needs.") end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Social fatigue (shy people tire of socialising sooner)
---------------------------------------------------------------------------
function C.Fatigue(world, a)
    a.tmp = a.tmp or {}
    local t = a.tmp
    local n = now(world)
    local last = t.fatigueT or n
    local dt = math.max(0, n - last)
    local f = t.fatigue or 0
    if t.conv then f = f + P.SocialFatigueRate(a) * dt else f = f - P.FATIGUE_RECOVERY * dt end
    f = U.clamp(f, 0, 1)
    t.fatigue, t.fatigueT = f, n
    return f
end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------
function C.SessionOf(rid)
    local id = C.byActor[rid]
    return id and C.sessions[id]
end

function C.Count(sess, state)
    local n = 0
    for _, m in pairs(sess.members) do if not state or m.state == state then n = n + 1 end end
    return n
end

function C.NewSession(world, a, b)
    local id = C.nextId
    C.nextId = C.nextId + 1
    local lv = b.level or 0
    -- the ring forms round a walkable cell: where b stands, or, when b is sitting, the cell b stands
    -- up onto (C.AnchorCell)
    local ai, aj = C.AnchorCell(world, lv, b, a)
    local ax, ay = b.x, b.y
    if ai ~= math.floor(b.x) or aj ~= math.floor(b.y) then ax, ay = ai + 0.5, aj + 0.5 end
    local sess = { id = id, lotId = world.lot.id, level = lv, ax = ax, ay = ay, members = {},
        ai = ai, aj = aj, anchorId = b.id, taken = {},
        queue = {}, created = now(world), idle = 0, gapUntil = now(world), checkT = now(world), host = a.id }
    C.sessions[id] = sess
    SS.Emit("conversation", world, "start", id, a.id, b.id)
    return sess
end

local function setPose(actor, pose)
    if not actor then return end
    if actor.onObj and not (type(pose) == "string" and pose:sub(1, 3) == "sit") then return end
    local act = actor.act
    if act and act.data and act.data.conv then act.pose = pose end
    actor.pose = pose
end
C.SetPose = setPose

---------------------------------------------------------------------------
-- Conversational positions: everyone stands on their own cell in a ring around the anchor, a
-- walkable cell where the person first approached stands (or, if they were sitting, the cell they
-- stand up onto). The executor only walks people to one of the four cells next to their target,
-- without knowing who else stands there; on arrival the conversation gives each member a free,
-- reachable cell (theirs if it is already fine), reserves it in the session and walks them the
-- last step or two itself. Two members never hold the same cell: a member who can reach no free
-- cell leaves the conversation ("no room") rather than share one. Searches are tiny (a 9x9
-- window) and run once per member, never per step.
---------------------------------------------------------------------------
C.SLOT_RING, C.SLOT_WINDOW = 2, 4
C.SLOT_NAV_TRIES = 3   -- route searches one member may try when the window holds no way to a ring cell
local function ckey(i, j) return j * 4096 + i end
C.CellKey = ckey

-- Breadth-first search over walkable cells within `radius` (Chebyshev) of (ci, cj), from (si, sj).
-- Returns the distance and predecessor maps (keys ckey). Only walkable cells are ever entered;
-- the start cell is where the search begins, so it is in the map even when it is blocked (a
-- person can always step out of the cell they are in), and callers never offer it as a spot
-- unless it is walkable.
-- Scratch maps for the searches (two sets: the ring around the anchor and the walk to it).
local reachPool = { { {}, {}, {} }, { {}, {}, {} } }
local function wipe(t) for k in pairs(t) do t[k] = nil end end
function C.LocalReach(world, lv, si, sj, ci, cj, radius, who, slot)
    local W = SS.World
    local set = reachPool[slot or 1]
    local distm, came, q = set[1], set[2], set[3]
    wipe(distm); wipe(came)
    for k = #q, 1, -1 do q[k] = nil end
    distm[ckey(si, sj)] = 0
    q[1], q[2] = si, sj
    local head = 1
    while head < #q do
        local i, j = q[head], q[head + 1]
        head = head + 2
        local k = ckey(i, j)
        for d = 0, 3 do
            local dv = G.DIRS[d]
            local ni, nj = i + dv[1], j + dv[2]
            local nk = ckey(ni, nj)
            if not distm[nk] and math.abs(ni - ci) <= radius and math.abs(nj - cj) <= radius
                and not W.Blocked(world, lv, ni, nj) and W.CanStep(world, lv, i, j, ni, nj, who) then
                distm[nk] = distm[k] + 1
                came[nk] = k
                q[#q + 1] = ni; q[#q + 1] = nj
            end
        end
    end
    return distm, came
end

-- Cells where someone other than `rid` stands still right now (same level). Shared scratch.
local occScratch = {}
local function standingCells(world, lv, rid)
    local occ = occScratch
    wipe(occ)
    for id, p in pairs(world.actors) do
        if id ~= rid and (p.level or 0) == lv and not p.walking and not p.onObj then occ[ckey(math.floor(p.x), math.floor(p.y))] = id end
    end
    return occ
end

-- The walkable cell nearest (px, py) that `from` can walk to within the window around (bi, bj),
-- preferring one nobody stands on; else the first open cell beside (bi, bj); else (bi, bj).
local function nearestOpen(world, lv, bi, bj, px, py, from, who)
    local W = SS.World
    if from and (from.level or 0) == lv then
        local si, sj = math.floor(from.x), math.floor(from.y)
        if not W.Blocked(world, lv, si, sj) then
            local distm = C.LocalReach(world, lv, si, sj, bi, bj, C.SLOT_WINDOW, from, 2)
            local occ = standingCells(world, lv, nil)
            local best, bw
            local R = C.SLOT_WINDOW
            for dj = -R, R do
                for di = -R, R do
                    local i, j = bi + di, bj + dj
                    local k = ckey(i, j)
                    if distm[k] and not W.Blocked(world, lv, i, j) then
                        local ex, ey = i + 0.5 - px, j + 0.5 - py
                        local w = ex * ex + ey * ey + (occ[k] and 100 or 0)
                        if not bw or w < bw then best, bw = k, w end
                    end
                end
            end
            if best then return best % 4096, math.floor(best / 4096) end
        end
    end
    for d = 0, 3 do
        local dv = G.DIRS[d]
        local ni, nj = bi + dv[1], bj + dv[2]
        if not W.Blocked(world, lv, ni, nj) and W.CanStep(world, lv, bi, bj, ni, nj, who) then return ni, nj end
    end
    return bi, bj
end

-- The cell a conversation with b forms around. Someone standing: their own cell. Someone sitting
-- (an armchair, a dining chair) or standing in a blocked cell: the cell they stand up onto (their
-- action's approach cell) when it is walkable and close, else the walkable cell nearest them that
-- the initiator `a` can walk to (nobody else's spot if avoidable), else an open cell beside them.
function C.AnchorCell(world, lv, b, a)
    local W = SS.World
    local bi, bj = math.floor(b.x), math.floor(b.y)
    if not b.onObj and not W.Blocked(world, lv, bi, bj) then return bi, bj end
    local ap = b.act and b.act.approach
    if type(ap) == "table" and type(ap[1]) == "number" and type(ap[2]) == "number" and (ap[3] or 0) == lv
        and math.max(math.abs(ap[1] - bi), math.abs(ap[2] - bj)) <= C.SLOT_RING and not W.Blocked(world, lv, ap[1], ap[2]) then
        return ap[1], ap[2]
    end
    return nearestOpen(world, lv, bi, bj, b.x, b.y, a, b)
end

-- The anchor cell was built over (or never was walkable, in an old session): move the ring to the
-- nearest walkable cell the member now looking for a spot can reach.
function C.Reanchor(world, sess, by)
    local lv = sess.level or 0
    local an = world.actors[sess.anchorId]
    local ai, aj
    if an and (an.level or 0) == lv then ai, aj = C.AnchorCell(world, lv, an, by)
    else ai, aj = nearestOpen(world, lv, sess.ai, sess.aj, sess.ai + 0.5, sess.aj + 0.5, by, by) end
    sess.ai, sess.aj = ai, aj
end

-- Scratch for the ranked candidate cells of one claim.
local candK, candW = {}, {}

-- Give actor a conversational cell in sess (keeps a good current cell). Returns true if it has to
-- walk. Cells are walkable, reachable, and never held by another member; a member who can reach
-- no free cell is marked m.noRoom and leaves on the session's next tick.
function C.ClaimSlot(world, sess, actor)
    local m = sess.members[actor.id]
    if not m or m.slot or not sess.ai then return false end
    local lv = sess.level or 0
    if (actor.level or 0) ~= lv then return false end
    local W = SS.World
    local taken = sess.taken
    local ci, cj = math.floor(actor.x), math.floor(actor.y)
    if actor.onObj then
        -- talking from a seat (a table, a bench): they stay where they sit. A seat is not a spot
        -- anyone standing can take, so it is theirs.
        local k = ckey(ci, cj)
        m.slot, m.si, m.sj = k, ci, cj
        if not taken[k] then taken[k] = actor.id end
        return false
    end
    if W.Blocked(world, lv, sess.ai, sess.aj) then C.Reanchor(world, sess, actor) end
    local ai, aj = sess.ai, sess.aj
    local occ = standingCells(world, lv, actor.id)
    local isAnchor = actor.id == sess.anchorId
    local function open(i, j)
        -- walkable, not another member's, and nobody else standing there
        local k = ckey(i, j)
        local holder = taken[k]
        if holder and holder ~= actor.id then return false end
        local o = occ[k]
        if o and o ~= actor.id then return false end
        return not W.Blocked(world, lv, i, j)
    end
    local function free(i, j)
        -- a ring spot: open, and the anchor's own cell is kept for the anchor
        if i == ai and j == aj and not isAnchor then return false end
        return open(i, j)
    end
    local function take(k, path)
        m.slot, m.si, m.sj = k, k % 4096, math.floor(k / 4096)
        taken[k] = actor.id
        if path and #path > 0 then m.path, m.pi = path, 1; return true end
        return false
    end
    local reach = C.LocalReach(world, lv, ai, aj, ai, aj, C.SLOT_RING, actor, 1)
    if reach[ckey(ci, cj)] and free(ci, cj) then return take(ckey(ci, cj)) end
    -- the ring's free cells, best first: ring 1 before ring 2 (the anchor's own cell first for the
    -- anchor), then nearest to where they stand, then by cell
    local R, n = C.SLOT_RING, 0
    for dj = -R, R do
        for di = -R, R do
            local i, j = ai + di, aj + dj
            local k = ckey(i, j)
            if reach[k] and free(i, j) then
                local ring = math.max(math.abs(di), math.abs(dj))
                if ring == 0 then ring = isAnchor and -1 or 9 end
                local ex, ey = i + 0.5 - actor.x, j + 0.5 - actor.y
                local w = ring * 100 + ex * ex + ey * ey
                n = n + 1
                local at = n
                while at > 1 and (candW[at - 1] > w or (candW[at - 1] == w and candK[at - 1] > k)) do
                    candK[at], candW[at] = candK[at - 1], candW[at - 1]
                    at = at - 1
                end
                candK[at], candW[at] = k, w
            end
        end
    end
    -- the first of them they can walk to: a path inside the window around the anchor, else a route
    -- search (a few at most)
    local distm, came = C.LocalReach(world, lv, ci, cj, ai, aj, C.SLOT_WINDOW, actor, 2)
    local start, tries = ckey(ci, cj), 0
    local function walkTo(k)
        if distm[k] then
            local path = {}
            while k and k ~= start do
                table.insert(path, 1, { k % 4096, math.floor(k / 4096) })
                k = came[k]
            end
            return path
        end
        if tries >= C.SLOT_NAV_TRIES or not (SS.Nav and SS.Nav.FindPath) then return nil end
        tries = tries + 1
        local p = SS.Nav.FindPath(world, ci, cj, lv, { { k % 4096, math.floor(k / 4096), lv } }, actor)
        if not p or #p == 0 then return nil end
        local path = {}
        for q = 1, #p do
            if p[q].stairs or (p[q][3] or lv) ~= lv then return nil end
            path[#path + 1] = { p[q][1], p[q][2] }
        end
        return path
    end
    for c = 1, n do
        local path = walkTo(candK[c])
        if path and #path > 0 then return take(candK[c], path) end
    end
    -- no ring cell they can walk to: stay where they stand if nobody else holds it or stands there
    if open(ci, cj) then return take(start) end
    -- otherwise the nearest free cell they can walk to inside the window
    local best, bd
    local WR = C.SLOT_WINDOW
    for dj = -WR, WR do
        for di = -WR, WR do
            local i, j = ai + di, aj + dj
            local k = ckey(i, j)
            local d = distm[k]
            if d and d > 0 and open(i, j) and (not bd or d < bd) then best, bd = k, d end
        end
    end
    if best then return take(best, walkTo(best)) end
    -- nowhere at all: they leave the conversation rather than stand on someone
    m.noRoom = true
    return false
end

function C.ReleaseSlot(sess, rid)
    local m = sess.members[rid]
    if m and m.slot and sess.taken and sess.taken[m.slot] == rid then sess.taken[m.slot] = nil end
    if m then m.slot, m.path, m.pi = nil, nil, nil end
end

-- Who a member faces when not speaking: the current speaker, else the anchor, else the host.
function C.FocusOf(world, sess, rid)
    local ex = sess.ex
    if ex then
        local id = (rid == ex.a) and ex.b or ex.a
        return world.actors[id]
    end
    local id = (rid ~= sess.anchorId and sess.members[sess.anchorId]) and sess.anchorId or sess.host
    if id == rid then
        for other in pairs(sess.members) do if other ~= rid then id = other; break end end
    end
    return world.actors[id]
end

-- Everyone settled in a conversation keeps facing it, every tick: the speaker faces the listener,
-- the listener the speaker, everyone else the speaker (between exchanges, the anchor). Executors
-- turn people toward whatever they walked up to, so someone who needed no step to reach their spot
-- would otherwise keep facing that. Seated talkers keep their seat's facing; a guest caught
-- admiring an ornament keeps looking at it for that reaction. Allocates nothing.
function C.HoldFacing(world, sess)
    local ex = sess.ex
    local lookAway = ex and ex.ornament and ex.stage == "react" and ex.b or nil
    for rid, m in pairs(sess.members) do
        if m.state == "in" and not m.path and rid ~= lookAway then
            local p = world.actors[rid]
            if p and not p.walking then face(p, C.FocusOf(world, sess, rid)) end
        end
    end
end

-- Walk a member along its settling path (called from their conversation action's tick).
-- Returns true while they are still moving.
function C.Settle(world, sess, actor, dt)
    local m = sess.members[actor.id]
    local path = m and m.path
    if not path then return false end
    local left = ((SS.Tuning and SS.Tuning.walkSpeed) or 2.4) * dt
    while left > 0 and path[m.pi] do
        local c = path[m.pi]
        local tx, ty = c[1] + 0.5, c[2] + 0.5
        local dx, dy = tx - actor.x, ty - actor.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d > 1e-4 then actor.facing = G.dirToFacing(dx, dy) end
        if d <= left then
            actor.x, actor.y = tx, ty
            left = left - d
            m.pi = m.pi + 1
        else
            actor.x, actor.y = actor.x + dx / d * left, actor.y + dy / d * left
            d = left
            left = 0
        end
        actor.stride = (actor.stride or 0) + d
    end
    if path[m.pi] then
        actor.walking = true
        setPose(actor, "walk")
        return true
    end
    m.path, m.pi = nil, nil
    actor.walking = nil
    setPose(actor, "idle")
    face(actor, C.FocusOf(world, sess, actor.id))
    return false
end

function C.Moving(sess, rid)
    local m = sess.members[rid]
    return m and m.path ~= nil or false
end

-- Claim a spot for someone now "in"; someone who needs no step to reach it turns to the talk at once.
local function settleIn(world, sess, actor)
    local m = sess.members[actor.id]
    if not C.ClaimSlot(world, sess, actor) and m and not m.noRoom and not m.path then face(actor, C.FocusOf(world, sess, actor.id)) end
end

function C.AddMember(world, sess, actor, state, act)
    if sess.members[actor.id] then
        local m = sess.members[actor.id]
        if state == "in" then m.state = "in"; settleIn(world, sess, actor) end
        m.switching = nil
        if act then act.data.conv = sess.id; act.data.epoch = C.epoch end
        return
    end
    C.Fatigue(world, actor)
    sess.members[actor.id] = { state = state, since = now(world), spoke = 0 }
    C.byActor[actor.id] = sess.id
    actor.tmp.conv = sess.id
    if act then act.data.conv = sess.id; act.data.epoch = C.epoch end
    if state == "in" then settleIn(world, sess, actor) end
    SS.Emit("conversation", world, "join", sess.id, actor.id)
end

-- A pulled-in member has arrived (their conversation action is performing).
function C.MarkIn(world, sess, rid, m)
    if m.state ~= "in" then m.state, m.since = "in", now(world) end
    local p = world.actors[rid]
    if p and not m.slot and not m.noRoom then settleIn(world, sess, p) end
end

local function balloon(world, actor, icon, text, dur, kind)
    if not actor then return end
    actor.balloon = { icon = icon, text = text, untilT = now(world) + (dur or 2), kind = kind or "speech" }
end
C.Balloon = balloon

-- Babble voice through ui-shell's audio director (muted there by the voices setting). The
-- director's voice bank has eight moods (neutral, happy, laugh, angry, sad, question, surprise,
-- effort); the gesture shown picks one. Only the attached (visible) world makes sound.
C.VOICE_MOOD = {
    talk = "neutral", idle = "neutral", read = "neutral", use = "neutral",
    greet = "happy", celebrate = "happy", hug = "happy", kiss = "happy", play = "happy", flirt = "happy",
    laugh = "laugh", argue = "angry", cry = "sad", sheepish = "question", run = "effort",
}
local function voice(world, actor, gesture)
    if not actor or not (SS.Audio and SS.Audio.Voice) then return end
    if SS.Sim and SS.Sim.world ~= world then return end
    pcall(SS.Audio.Voice, actor, C.VOICE_MOOD[gesture] or "neutral")
end
C.Voice = voice

-- Props social puts in someone's hand for an exchange (a gift, flowers, a book) are marked on the
-- person (socialCarry, and socialPrevCarry for what they held before), so only social's own prop is
-- ever taken away again: other modules' props (a visitor's welcome gift, a phone) are left alone.
function C.DropProp(r)
    if type(r) ~= "table" or r.socialCarry == nil then return false end
    if r.carry == r.socialCarry then r.carry = r.socialPrevCarry end
    r.socialCarry, r.socialPrevCarry = nil, nil
    return true
end
local function restoreCarry(world, ex)
    if ex and ex.carrier then
        local a = world.actors[ex.carrier]
        if a and a.socialCarry == ex.carry then C.DropProp(a)
        elseif a and a.carry == ex.carry then a.carry = ex.prevCarry end
        ex.carrier = nil
    end
end

function C.AbortExchange(world, sess, why)
    local ex = sess.ex
    if not ex then return end
    restoreCarry(world, ex)
    sess.ex = nil
    local req = ex.req
    if req then
        if req.data.resolved then req.data.exDone = true else req.data.aborted = why or "interrupted" end
    end
end

-- Remove someone from a conversation. finishAct: end their conversation action too.
function C.RemoveMember(world, sess, rid, why, finishAct)
    local m = sess.members[rid]
    if not m then return end
    C.ReleaseSlot(sess, rid)
    sess.members[rid] = nil
    if C.byActor[rid] == sess.id then C.byActor[rid] = nil end
    if sess.ex and (sess.ex.a == rid or sess.ex.b == rid) then C.AbortExchange(world, sess, why) end
    for i = #sess.queue, 1, -1 do
        local q = sess.queue[i]
        if q.a == rid or q.b == rid then
            table.remove(sess.queue, i)
            if q.req and q.a ~= rid then q.req.data.aborted = why or "left" end
        end
    end
    local root = world.root or world
    local a = world.actors[rid] or (root.residents and root.residents[rid])
    if a then
        if a.tmp then C.Fatigue(world, a); if a.tmp.conv == sess.id then a.tmp.conv = nil end end
        if a.queue then
            for i = #a.queue, 1, -1 do
                local o = a.queue[i]
                if o.iid == "social_chat" and o.data and o.data.conv == sess.id then table.remove(a.queue, i) end
            end
        end
        local act = a.act
        if finishAct and act and act.data and act.data.conv == sess.id then
            local ia = SS.Interactions[act.iid]
            if ia and ia.keepOnTalkEnd then
                -- another module's action the talk only joined (a meal at a table, a bench):
                -- it carries on without the conversation
                act.data.conv, act.data.epoch = nil, nil
            else
                act.data.leaving = why or "done"
                if act.data.stage == "session" and not act.data.resolved and act.manual then
                    SS.Actions.Finish(world, a, "failed", C.AbortText(world, act, why))
                else
                    SS.Actions.Finish(world, a, "done")
                end
            end
        end
        -- back to a neutral pose unless they are already walking or doing something unrelated
        local busyElsewhere = a.act and not (a.act.data and a.act.data.conv)
        if world.actors[rid] and a.pose ~= "walk" and not busyElsewhere then a.pose = "idle" end
    end
    SS.Emit("conversation", world, "leave", sess.id, rid, why)
end

function C.AbortText(world, act, why)
    local b = act.tid and world.actors[act.tid]
    if why == "wandered off" or why == "never arrived" then return first(b) .. " wandered off." end
    if why == "no room" then return "There was no room to stand and talk with " .. first(b) .. "." end
    return "The conversation with " .. first(b) .. " ended."
end

function C.Dissolve(world, sess, why)
    if sess.dead then return end
    sess.dead = true
    for _, rid in ipairs(sortedKeys(sess.members)) do C.RemoveMember(world, sess, rid, why or "ended", true) end
    C.sessions[sess.id] = nil
    SS.Emit("conversation", world, "end", sess.id, why)
end

-- Can someone walk up beside p: is one of p's four side cells walkable with nobody on it? The
-- executor walks a newcomer to a side cell of the person they go to, and household-core's tries
-- only the side cells nobody stands on, so a member boxed in by furniture and people can't be
-- reached at all (the route fails and the newcomer would drop out).
local SIDES = { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }
local function openSide(world, p, b)
    local lv = p.level or 0
    local pi, pj = math.floor(p.x), math.floor(p.y)
    for n = 1, 4 do
        local i, j = pi + SIDES[n][1], pj + SIDES[n][2]
        if not SS.World.Blocked(world, lv, i, j) then
            local busy = false
            for _, q in pairs(world.actors) do
                if q ~= p and q ~= b and (q.level or 0) == lv and math.floor(q.x) == i and math.floor(q.y) == j then busy = true; break end
            end
            if not busy then return true end
        end
    end
    return false
end
C.OpenSide = openSide

-- Whom b walks up to when pulled in: a member already standing in the conversation with a free
-- side cell, the nearest first (ties broken by id); failing that the nearest member; else `by`.
-- The executor walks people to a cell beside their target, so a newcomer joins the near side of
-- the group instead of routing round everyone to the host; on arrival the conversation gives
-- them their own spot in the ring (C.ClaimSlot). `skip` (ids) leaves out members b already
-- failed to reach.
function C.NearestMember(world, sess, b, by, skip)
    local best, bd, bid, bopen
    local function consider(p)
        local open = openSide(world, p, b)
        local d = dist(b, p)
        if not best or (open and not bopen)
            or (open == bopen and (d < bd - 1e-9 or (d <= bd + 1e-9 and p.id < bid))) then
            best, bd, bid, bopen = p, d, p.id, open
        end
    end
    if by and by ~= b and not (skip and skip[by.id]) then consider(by) end
    for rid, m in pairs(sess.members) do
        local p = world.actors[rid]
        if p and p ~= by and rid ~= b.id and m.state == "in" and not (skip and skip[rid]) and (p.level or 0) == (b.level or 0) then
            consider(p)
        end
    end
    return best
end

-- Make b stop what it is doing and come over to the conversation (`by` invited them).
function C.Pull(world, sess, b, by)
    C.AddMember(world, sess, b, "joining")
    b.queue = b.queue or {}
    for i = #b.queue, 1, -1 do if not b.queue[i].manual then table.remove(b.queue, i) end end
    if b.act and not (b.act.data and b.act.data.conv == sess.id) then SS.Actions.Cancel(world, b, 0) end
    local to = C.NearestMember(world, sess, b, by)
    table.insert(b.queue, 1, { tid = to.id, iid = "social_chat", manual = false, data = { conv = sess.id, epoch = C.epoch } })
    face(b, by)
end

-- Queue an exchange; manual requests go first.
-- Is an exchange involving rid waiting in (or running in) this conversation?
function C.Pending(sess, rid)
    if sess.ex and (sess.ex.a == rid or sess.ex.b == rid) then return true end
    for _, q in ipairs(sess.queue) do if q.a == rid or q.b == rid then return true end end
    return false
end

function C.Queue(world, sess, req)
    if req.manual then
        local pos = 1
        for i, q in ipairs(sess.queue) do if q.manual then pos = i + 1 end end
        table.insert(sess.queue, pos, req)
    else
        sess.queue[#sess.queue + 1] = req
    end
    while #sess.queue > 6 do table.remove(sess.queue) end
end

-- A declined approach: visible reaction, small hurt, and a cooldown so it isn't retried at once.
function C.Decline(world, a, b, d, why, kind)
    if not b.sleeping then
        -- someone already talking with others answers without turning away from them, and keeps
        -- the balloon of the exchange they are in (the approacher's awkward look tells the story)
        local bs = C.SessionOf(b.id)
        local inEx = bs and bs.ex and (bs.ex.a == b.id or bs.ex.b == b.id)
        if not bs then face(b, a) end
        if not inEx then balloon(world, b, "react_no", nil, 2, "thought") end
    end
    balloon(world, a, "react_awkward", nil, 2, "thought")
    if kind == "unwilling" then
        So.SetCooldown(world, a.id, b.id, "talk", 30)
        So.Adjust(world, a.id, b.id, { daily = -1 })
        So.Record(world, a.id, b.id, d.id, false, -1, 0, 0, 0)
    elseif kind == "busy" then
        -- no hard feelings, but no pestering either: a leaves b alone while b stays busy, for at
        -- least BUSY_COOL minutes (longer when b's action has a known length left, up to BUSY_MAX)
        So.SetCooldown(world, a.id, b.id, "busy", C.BusyFor(world, b))
    end
    SS.Emit("socialDeclined", world, a.id, b.id, d.id, why)
end

C.BUSY_COOL, C.BUSY_MAX = 30, 90
-- Minutes to leave a busy person alone: the rest of their current action when it has a known
-- length (within BUSY_COOL..BUSY_MAX), otherwise BUSY_COOL. The block also lifts early the moment
-- they stop being busy (C.CanStart re-checks C.Busy while the "busy" cooldown runs).
function C.BusyFor(world, b)
    local act = b.act
    local ia = act and SS.Interactions[act.iid]
    local left
    if act and ia then
        local dur = act.dur or ia.dur or act.maxDur or ia.maxDur
        if type(dur) == "number" then left = dur - (act.t or 0) end
    end
    return U.clamp(left or C.BUSY_COOL, C.BUSY_COOL, C.BUSY_MAX)
end

-- Would b talk to a right now? (Busy is checked first.) Deterministic roll on "social".
function C.Willing(world, a, b, d, pc)
    pc = pc or C.Pair(world, a, b)
    local w = 55 + pc.ba.daily * 0.4 + pc.ba.life * 0.25 + mood(b) * 0.2 + (P.Get(b, "outgoing") - 5) * 4
    local soc = b.needs.social or 0
    if soc < 0 then w = w + 15 elseif soc > 85 then w = w - 10 end
    w = w - C.Fatigue(world, b) * 45
    if pc.fam or pc.partner then w = w + 15 end
    w = U.clamp(w, 5, 98)
    return SS.Random(world, "social") * 100 < w, w
end

-- The initiator has arrived: engage the target. Returns the session or nil, why.
function C.Engage(world, a, b, d, act)
    local bs = C.SessionOf(b.id)
    if d.id == "join_group" then
        if not bs then return nil, "The conversation broke up." end
        if C.Count(bs) >= C.MAX_MEMBERS then return nil, "That conversation is full." end
        C.AddMember(world, bs, a, "in", act)
        if not C.Moving(bs, a.id) then face(a, C.FocusOf(world, bs, a.id) or b) end
        C.Queue(world, bs, { a = a.id, b = b.id, def = d, manual = act.manual, req = act })
        return bs
    end
    local busy = C.Busy(world, b, a, d)
    if busy then C.Decline(world, a, b, d, busy, "busy"); return nil, busy end
    local pc = C.Pair(world, a, b)
    if d.kind ~= "hostile" and not (bs and bs.members[a.id]) then
        if not C.Willing(world, a, b, d, pc) then
            local why = first(b) .. " doesn't feel like talking right now."
            C.Decline(world, a, b, d, why, "unwilling")
            return nil, why
        end
    end
    local sess = bs
    if sess then
        if not sess.members[a.id] and C.Count(sess) >= C.MAX_MEMBERS then return nil, "That conversation is full." end
    else
        sess = C.NewSession(world, a, b)
        C.Pull(world, sess, b, a)
    end
    C.AddMember(world, sess, a, "in", act)
    if not C.Moving(sess, a.id) then face(a, C.FocusOf(world, sess, a.id) or b) end
    C.Queue(world, sess, { a = a.id, b = b.id, def = d, manual = act.manual, req = act, data = act.data })
    return sess
end


-- Bring nearby available people into a session (group chat).
function C.InviteNearby(world, sess, host, maxN)
    local added = 0
    for _, id in ipairs(actorIds(world)) do
        if added >= maxN or C.Count(sess) >= C.MAX_MEMBERS then break end
        local p = world.actors[id]
        if p and not sess.members[id] and human(p) and (p.level or 0) == sess.level and dist(p, host) <= 7
            and not C.SessionOf(id) and not C.CalledAway(world, p) and not C.Busy(world, p, host, nil) and C.RoleSocial(p) then
            local pc = C.Pair(world, host, p)
            if C.Willing(world, host, p, nil, pc) then
                C.Pull(world, sess, p, host)
                added = added + 1
            end
        end
    end
    return added
end


---------------------------------------------------------------------------
-- Acceptance
---------------------------------------------------------------------------
-- Can listener overhear speaker? Awake, same floor, same room within 8 tiles, or within 3 tiles
-- with nothing but openings (doors included) in between. See SS.Lines.CanHear.
function C.Earshot(world, listener, speaker) return L.CanHear(world, listener, speaker) end

-- Can p see what a is doing? Awake, same floor, within radius, same room or a clear line of
-- sight (windows and archways yes, walls and doors no). See SS.Lines.CanSee.
function C.Sees(world, p, a, radius) return L.CanSee(world, p, a, radius or 6) end

-- Witnesses of an exchange: other people who can see the speaker (and are not in exclude).
function C.WitnessList(world, a, b, radius, exclude)
    local out = {}
    local ids = actorIds(world)
    for k = 1, #ids do
        local id = ids[k]
        local p = world.actors[id]
        if id ~= a.id and id ~= b.id and (not exclude or not exclude[id]) and human(p) and C.Sees(world, p, a, radius or 6) then
            out[#out + 1] = p
        end
    end
    return out
end
-- How many would be in C.WitnessList (no list built).
function C.WitnessCount(world, a, b, radius)
    local n, ids = 0, actorIds(world)
    for k = 1, #ids do
        local id = ids[k]
        local p = world.actors[id]
        if id ~= a.id and id ~= b.id and human(p) and C.Sees(world, p, a, radius or 6) then n = n + 1 end
    end
    return n
end

local function roomScore(world, actor)
    return L.RoomScoreAt(world, actor)
end

-- Chance (3..97) that b accepts / enjoys a's interaction d. ex carries topic/subject/item.
function C.Chance(world, a, b, d, pc, ex)
    local acc, accA = d.acc, d.accA
    local c = 50 + (d.base or 0)
    local relW = acc.rel or 1
    c = c + (pc.ba.daily * 0.3 + pc.ba.life * 0.2) * relW
    local moodB = mood(b)
    c = c + moodB * 0.15 * (acc.mood or 1)
    c = c + mood(a) * 0.04
    for _, dim in ipairs(P.DIMS) do
        if acc[dim] then c = c + (P.Get(b, dim) - 5) * acc[dim] end
        if accA[dim] then c = c + (P.Get(a, dim) - 5) * accA[dim] end
    end
    -- disagreeable people accept less (hostile interactions weigh niceness through acc.nice)
    if d.kind ~= "hostile" then c = c + (P.Get(b, "nice") - 5) * 2 end
    if acc.compat then c = c + P.Compatibility(a, b) * acc.compat end
    if acc.charisma and SS.Skills and SS.Skills.Level then c = c + SS.Skills.Level(a, "charisma") * 2 * acc.charisma
    elseif SS.Skills and SS.Skills.Level then c = c + SS.Skills.Level(a, "charisma") * 0.8 end
    -- interests
    if ex.topic and (acc.interest or d.topic) then
        local ib = P.Interest(b, ex.topic)
        local w = acc.interest or 0.5
        c = c + (ib - 5) * 5 * w
        if ib <= SS.Topics.HATE then c = c - 15 * w end
        if ib >= SS.Topics.LOVE and P.Interest(a, ex.topic) >= SS.Topics.LOVE then c = c + 10 end
    end
    -- audience
    local wit = ex.witnesses or 0
    if acc.audience then c = c + wit * acc.audience end
    -- romance
    if d.kind == "romantic" or acc.romance then
        local rw = acc.romance or 1
        c = c + ((pc.ba.romance or 0) * 0.5 - 12) * rw
        if pc.partner then c = c + 20 end
        if So.HasOtherPartner(world, b.id, a.id) then c = c - 25 end
    end
    -- repetition: the same thing again soon is worse; repeated flops are worse still
    local reps = So.Count(world, b.id, a.id, d.id, 360, false)
    c = c - reps * d.rep
    if d.repFail > 0 then
        c = c - So.Count(world, b.id, a.id, d.id, 720, false, false) * d.repFail
    end
    c = c - So.Count(world, b.id, a.id, nil, 60, false) * 1.5
    -- setting: room, venue, late night, distraction, fatigue
    c = c + (ex.roomScore or roomScore(world, b)) * 0.06
    if world.lot.kind == "community" and (d.kind == "romantic" or d.kind == "fun") then c = c + 6 end
    local hour = math.floor(now(world) / 60) % 24
    if (hour >= 23 or hour < 6) and (d.kind == "fun" or d.cat == "Games") then c = c - 6 end
    local T = SS.Tuning
    for n = 1, #URGENT3 do
        if (b.needs[URGENT3[n]] or 0) < T.urgent then c = c - 12 end
    end
    c = c - C.Fatigue(world, b) * 20
    if So.Upset(world, b.id) and d.kind ~= "kind" then c = c - 10 end
    local sp = C.SPECIAL[d.id]
    if sp and sp.chance then c = c + (sp.chance(world, a, b, pc, ex) or 0) end
    return U.clamp(c, 3, 97)
end

---------------------------------------------------------------------------
-- Exchange lifecycle
---------------------------------------------------------------------------
local function iconFor(ex, name)
    if name == "topic" then
        local t = ex.topic and SS.Topics.byId[ex.topic]
        return t and t.icon or ex.def.icon
    end
    return name
end

local function itemKind(item)
    if not item then return nil end
    if item.kind == "flowers" or (item.data and item.data.flowers) then return "flowers" end
    return item.kind
end

local function lineCtx(ex, listener, role)
    return { listener = listener, topic = ex.topic, role = role, subject = ex.subjectName, item = ex.itemName,
        itemKind = itemKind(ex.item), objDef = ex.objDef, skill = ex.skill, job = ex.job, amount = ex.amount,
        count = ex.reps, outcome = ex.outcome }
end

function C.StartExchange(world, sess, req)
    local a, b = world.actors[req.a], world.actors[req.b]
    local d = req.def
    local ex = { a = req.a, b = req.b, def = d, stage = "open", t = 0, manual = req.manual, req = req.req,
        data = req.data or {}, auto = req.auto }
    sess.ex = ex
    -- topic, subject, item and other specifics are chosen now, from real state
    if d.topic then ex.topic = C.PickTopic(world, a, b, d.topic) end
    -- how often a already did this to b lately (the listener remembers repeated jokes)
    ex.reps = So.Count(world, b.id, a.id, d.id, 360, false)
    local sp = C.SPECIAL[d.id]
    if sp and sp.open then sp.open(world, ex, a, b) end
    ex.witnesses = C.WitnessCount(world, a, b, 6)
    -- positions: everyone faces the speaker, the speaker faces the listener
    face(a, b); face(b, a)
    for rid, m in pairs(sess.members) do
        if rid ~= ex.a and rid ~= ex.b and m.state == "in" and not m.path then
            local p = world.actors[rid]
            face(p, a)
            setPose(p, "idle")
        end
    end
    setPose(a, d.pose or "talk")
    setPose(b, d.listen or "idle")
    if d.carry then
        ex.carrier, ex.prevCarry, ex.carry = a.id, a.carry, d.carry
        a.socialCarry, a.socialPrevCarry = d.carry, a.carry
        a.carry = d.carry
    end
    local text
    if d.open then text = L.Say(world, a, d.open, lineCtx(ex, b, "speaker")) end
    local icon = (ex.topic and d.topic) and "topic" or d.icon
    balloon(world, a, iconFor(ex, icon), text, d.dur + 0.5)
    voice(world, a, d.pose or "talk")
    local m = sess.members[ex.a]
    if m then m.spoke = m.spoke + 1; m.lastSpoke = now(world) end
    sess.lastSpeaker = ex.a
    SS.Emit("socialStart", world, ex.a, ex.b, d.id)
end

-- Apply outcome deltas scaled by magnitude.
local function scaled(t, mag)
    if not t then return nil end
    local o = {}
    if t.d then o.daily = t.d * mag end
    if t.l then o.life = t.l * mag end
    if t.r then o.romance = t.r * mag end
    if t.v then o.rivalry = t.v * mag end
    return o
end

function C.NeedGain(world, actor, need, amt, mag)
    if not amt or amt == 0 or not actor or not actor.needs then return 0 end
    local v = amt
    if amt > 0 then
        v = amt * (mag or 1)
        if need == "social" then v = v * (1 - 0.8 * C.Fatigue(world, actor)) * (0.7 + 0.06 * P.Get(actor, "outgoing"))
        elseif need == "fun" then v = v * (1 - 0.6 * C.Fatigue(world, actor)) * (0.7 + 0.06 * P.Get(actor, "playful")) end
    end
    SS.Needs.Add(actor, need, v)
    return v
end

local function recordEvent(world, kind, data, resolve)
    if SS.Events and SS.Events.Record then
        local ok, e = pcall(SS.Events.Record, world, kind, data)
        if ok and e then
            if resolve and SS.Events.Resolve then pcall(SS.Events.Resolve, world, e.id, resolve) end
            return e.id
        end
    end
end
C.RecordEvent = recordEvent

function C.Resolve(world, sess, ex)
    local a, b = world.actors[ex.a], world.actors[ex.b]
    local d = ex.def
    local pc = C.Pair(world, a, b)
    local chance = C.Chance(world, a, b, d, pc, ex)
    local roll = SS.Random(world, "social") * 100
    local ok = roll < chance
    local sp = C.SPECIAL[d.id]
    if sp and sp.decide then ok = sp.decide(world, ex, a, b, ok, chance, roll) end
    -- a guest distracted by an expensive ornament ignores the host (comic situation)
    if not ex.forced and not ex.handedBack and not ex.given and C.OrnamentDistraction(world, ex, a, b) then ok = false end
    local mag
    if ok then mag = 0.7 + 0.6 * (chance - roll) / math.max(chance, 1)
    else mag = 0.7 + 0.6 * (roll - chance) / math.max(100 - chance, 1) end
    mag = U.clamp(mag, 0.5, 1.4)
    ex.ok, ex.chance, ex.roll, ex.mag = ok, chance, roll, mag
    ex.outcome = ok and "accepted" or "rejected"
    local out = ok and d.ok or d.no
    if ex.ornament then out = C.ORNAMENT_OUTCOME end
    if ex.handedBack then out = C.HANDBACK_OUTCOME end
    -- relationships (asymmetric) and history
    local m, th = scaled(out.mine, mag), scaled(out.theirs, mag)
    if m and m.romance and not So.CanRomance(world, a.id, b.id) then m.romance = nil end
    if th and th.romance and not So.CanRomance(world, b.id, a.id) then th.romance = nil end
    if m then So.Adjust(world, a.id, b.id, m) end
    if th then So.Adjust(world, b.id, a.id, th) end
    So.Record(world, a.id, b.id, d.id, ok, m and m.daily, m and m.life, th and th.daily, th and th.life)
    -- needs respond to quality and personality
    for _, need in ipairs({ "social", "fun", "comfort", "energy" }) do
        local t = out[need]
        if t then C.NeedGain(world, a, need, t[1], mag); C.NeedGain(world, b, need, t[2], mag) end
    end
    if ok and SS.Skills and SS.Skills.Gain then
        pcall(SS.Skills.Gain, world, a, "charisma", 0.004 * mag)
        for sk, amt in pairs(d.skill or {}) do
            pcall(SS.Skills.Gain, world, a, sk, amt * mag)
            pcall(SS.Skills.Gain, world, b, sk, amt * mag)
        end
    end
    -- conflict, hurt feelings, cooldowns
    if out.conflict then
        local had = So.Conflict(world, a.id, b.id)
        So.MarkConflict(world, a.id, b.id, d.id)
        -- one incident record per quarrel: for an argument the events director started, events
        -- hands back its own record from Record("social.argument") (Ev.Record links them), so
        -- social keeps that id and its apology settles the director's record
        if not had then
            local r = So.Rel(world, a.id, b.id)
            r.conflict.ev = recordEvent(world, "social.argument", { a = a.id, b = b.id, cause = d.id })
            So.Rel(world, b.id, a.id).conflict.ev = r.conflict.ev
        end
    end
    if out.upset then So.SetUpset(world, b.id, out.upset, d.id, a.id) end
    if out.upsetA then So.SetUpset(world, a.id, out.upsetA, d.id, b.id) end
    if not ok then
        local fails = So.Recent(world, a.id, b.id, { id = d.id, window = 720, me = true, ok = false })
        So.SetCooldown(world, a.id, b.id, d.id, d.cooldown * math.min(3, math.max(1, fails)))
        if d.kind == "romantic" then So.SetCooldown(world, a.id, b.id, "romance", 90) end
    end
    -- reactions
    local po, ic = out.pose or {}, out.icon or {}
    setPose(a, po[1] or "idle")
    setPose(b, po[2] or "idle")
    balloon(world, a, iconFor(ex, ic[1] or d.icon), nil, d.react + 0.5)
    local line = out.line
    local lineSit, lineBy = line, out.by
    if ex.ornament then lineSit, lineBy = "visitor_ornament", "b" end
    if ex.undercut and not ok then lineSit, lineBy = "boast_undercut_mess", "b" end
    if ex.vent then lineSit, lineBy = "complain", "b" end
    local btext
    if lineSit and lineBy == "b" then
        btext = L.Say(world, b, lineSit, lineCtx(ex, a, "listener"))
    elseif lineSit and lineBy == "a" then
        ex.beatLine = lineSit   -- said after a pause (the awkward silence after a bad joke)
    end
    balloon(world, b, iconFor(ex, ic[2] or "react_yes"), btext, d.react + 0.5)
    if btext or (po[2] and po[2] ~= "idle") then voice(world, b, po[2] or "talk") end
    if ex.ornament and ex.ornamentOid then
        local o = world.lot.objects[ex.ornamentOid]
        if o and not b.onObj then b.facing = G.dirToFacing(o.x + 0.5 - b.x, o.y + 0.5 - b.y) end
    end
    if sp and sp.after then sp.after(world, ex, a, b, ok, sess) end
    C.Audience(world, sess, ex, a, b, ok)
    C.Witnesses(world, sess, ex, a, b, ok)
    C.Retaliate(world, sess, ex, a, b, ok)
    local req = ex.req
    if req then req.data.resolved, req.data.ok = true, ok end
    SS.Emit("socialExchange", world, { a = a.id, b = b.id, id = d.id, ok = ok, chance = chance, mag = mag, topic = ex.topic,
        session = sess.id, members = C.Count(sess, "in") })
end

-- Second half of the reaction: a line from the speaker after a pause (bad joke recovery).
function C.Beat2(world, sess, ex)
    ex.beat2 = true
    if ex.beatLine then
        local a, b = world.actors[ex.a], world.actors[ex.b]
        local text = L.Say(world, a, ex.beatLine, lineCtx(ex, b, "speaker"))
        if text then
            balloon(world, a, (ex.def.no.icon and iconFor(ex, ex.def.no.icon[1])) or ex.def.icon, text, ex.def.react * 0.5 + 0.5)
            voice(world, a, "sheepish")
        end
    end
end

function C.EndExchange(world, sess, ex)
    restoreCarry(world, ex)
    if ex.req then ex.req.data.exDone = true end
    for rid, m in pairs(sess.members) do
        local p = world.actors[rid]
        if p and m.state == "in" and not m.path then setPose(p, "idle") end
    end
    sess.ex = nil
    sess.idle = 0
    sess.gapUntil = now(world) + C.GAP
end

-- Group members who aren't speaker or listener react to what they heard.
function C.Audience(world, sess, ex, a, b, ok)
    local d = ex.def
    for _, rid in ipairs(sortedKeys(sess.members)) do
        local m = sess.members[rid]
        local p = world.actors[rid]
        if p and rid ~= ex.a and rid ~= ex.b and m.state == "in" then
            local pa = So.Get(world, rid, a.id) or EMPTY
            if d.kind == "hostile" then
                So.Adjust(world, rid, a.id, { daily = -(1 + P.Get(p, "nice") * 0.3) })
                So.Adjust(world, rid, b.id, { daily = 1 })
                setPose(p, "idle")
                balloon(world, p, "react_awkward", nil, d.react)
            elseif d.kind == "romantic" then
                So.Adjust(world, rid, a.id, { daily = -1 })
                balloon(world, p, "react_awkward", nil, d.react)
            else
                local cm = 50 + pa.daily * 0.3 + (P.Get(p, "playful") - 5) * (d.kind == "fun" and 4 or 1.5) + mood(p) * 0.1
                if ex.topic then cm = cm + (P.Interest(p, ex.topic) - 5) * 4 end
                local liked = ok and SS.Random(world, "social") * 100 < cm
                if liked then
                    So.Adjust(world, rid, a.id, { daily = 2 * ex.mag, life = 0.4 * ex.mag })
                    C.NeedGain(world, p, "social", 4, ex.mag)
                    if d.kind == "fun" then C.NeedGain(world, p, "fun", 5, ex.mag) end
                    setPose(p, d.kind == "fun" and "laugh" or "idle")
                    balloon(world, p, d.kind == "fun" and "react_laugh" or "react_yes", nil, d.react)
                else
                    So.Adjust(world, rid, a.id, { daily = ok and -0.5 or -1.5 })
                    C.NeedGain(world, p, "social", 1, 1)
                    balloon(world, p, ok and "react_bored" or "react_awkward", nil, d.react)
                end
            end
        end
    end
end

-- People nearby but outside the conversation: public embarrassment and jealousy.
function C.Witnesses(world, sess, ex, a, b, ok)
    local d = ex.def
    local list = C.WitnessList(world, a, b, 6, sess.members)
    local all = C.WitnessList(world, a, b, 6)
    -- embarrassment in front of an audience (members included: they saw it too)
    if not ok and (d.kind == "fun" or d.kind == "romantic") and #all > 0 then
        SS.Needs.Add(a, "social", -math.min(2, #all))
        So.SetUpset(world, a.id, 30, "embarrassed", b.id)
        for _, w in ipairs(list) do So.Adjust(world, w.id, a.id, { daily = -1.5 }) end
        balloon(world, a, "react_embarrassed", a.balloon and a.balloon.text, d.react + 0.5)
    end
    if d.kind == "hostile" and d.id ~= "scold" and #all > 0 then
        SS.Needs.Add(b, "social", -math.min(3, #all))
        for _, w in ipairs(list) do
            So.Adjust(world, w.id, a.id, { daily = -(1 + P.Get(w, "nice") * 0.3) })
            So.Adjust(world, w.id, b.id, { daily = 1 })
        end
    end
    if d.kind == "romantic" or ex.romanticGift then C.Jealousy(world, a, b, all) end
end

-- A partner (or someone in love) who sees romance with someone else gets jealous and confronts.
function C.Jealousy(world, a, b, witnesses)
    for _, w in ipairs(witnesses) do
        for _, pair in ipairs({ { a, b }, { b, a } }) do
            local lover, other = pair[1], pair[2]
            local r = So.Get(world, w.id, lover.id)
            local committed = r and (r.flags.partner or r.flags.married or r.flags.love)
            if committed and w.id ~= other.id and not So.IsPartner(world, lover.id, other.id) then
                So.Adjust(world, w.id, lover.id, { daily = -20, life = -6 })
                So.Adjust(world, w.id, other.id, { daily = -15, life = -3, rivalry = 25 })
                So.SetUpset(world, w.id, 180, "jealous", lover.id)
                So.MarkConflict(world, w.id, lover.id, "jealous")
                setPose(w, "argue")
                face(w, lover)
                local text = L.Say(world, w, "jealous", { listener = lover, subject = first(other), role = "speaker" })
                balloon(world, w, "react_jealous", text, 3)
                recordEvent(world, "social.jealousy", { jealous = w.id, a = lover.id, b = other.id }, "witnessed")
                if SS.Actions and SS.Actions.Journal and world.household then
                    pcall(SS.Actions.Journal, world, first(w) .. " saw " .. first(lover) .. " getting close to " .. first(other) .. " and is furious.")
                end
                SS.Emit("jealousy", world, w.id, lover.id, other.id)
                C.Confront(world, w, lover)
                break
            end
        end
    end
end

-- Queue an autonomous "argue" from w at target (w stops optional activity first). With free will
-- off nothing is queued: the hurt shows (pose, balloon, line) and the player decides.
-- Already in the same conversation as the target: it comes out right there, as the next thing
-- said after anything the player queued. In another conversation: w walks out of it (unless the
-- player put them there) and goes to have it out.
local function confrontOrder(world, w, target, data)
    if w.act then SS.Actions.Cancel(world, w, 0) end
    w.queue = w.queue or {}
    for i = #w.queue, 1, -1 do if not w.queue[i].manual then table.remove(w.queue, i) end end
    table.insert(w.queue, 1, { tid = target.id, iid = "soc_argue", manual = false, data = data or { jealous = true } })
end

-- An argument the events module's director starts between two people who are getting on badly
-- (SS.Social.StartConflict(world, a, b, source) -> bool; a and b are actors or ids on the lot).
-- a argues with b through the ordinary Argue (soc_argue, data.source = source), with the menu's
-- checks: both awake, they have met, nobody working, the turned-down cooldown. The player's own
-- orders are never interrupted. Returns true when the argument is on its way (queued in their
-- conversation when they are already talking, else a walks over).
function C.StartConflict(world, a, b, source)
    if not world or not world.actors then return false end
    if type(a) == "string" then a = world.actors[a] end
    if type(b) == "string" then b = world.actors[b] end
    if type(a) ~= "table" or type(b) ~= "table" or a == b or not world.actors[a.id] or not world.actors[b.id] then return false end
    if not human(a) or not human(b) or a.sleeping or b.sleeping then return false end
    local rd = S.byId.argue
    local data = { source = source or "events" }
    local as = C.SessionOf(a.id)
    if as and as.members[b.id] then
        if not C.CanStart(world, a, b, rd, nil, true) then return false end
        for _, q in ipairs(as.queue) do if q.a == a.id and q.b == b.id and q.def == rd then return true end end
        local pos = 1
        for i, q in ipairs(as.queue) do if q.manual then pos = i + 1 end end
        table.insert(as.queue, pos, { a = a.id, b = b.id, def = rd, auto = true, data = data })
        while #as.queue > 6 do table.remove(as.queue) end
        return true
    end
    if (a.act and a.act.manual) then return false end
    for _, o in ipairs(a.queue or {}) do if o.manual then return false end end
    if not C.CanStart(world, a, b, rd, nil, true) then return false end
    if as then
        -- after this tick's session updates (the same queue Confront uses)
        deferred[#deferred + 1] = function()
            local s2 = C.SessionOf(a.id)
            if s2 and not s2.dead then
                C.RemoveMember(world, s2, a.id, "stormed off", true)
                if C.Count(s2) < 2 then C.Dissolve(world, s2, "too few") end
            end
            if world.actors[a.id] and world.actors[b.id] and not C.SessionOf(a.id) then confrontOrder(world, a, b, data) end
        end
        return true
    end
    confrontOrder(world, a, b, data)
    return true
end
function C.Confront(world, w, target)
    if not autonomyOn(world) or w.sleeping then return false end
    local ws = C.SessionOf(w.id)
    local rd = S.byId.argue
    if ws and ws.members[target.id] then
        if not rd or not C.CanStart(world, w, target, rd, nil, true) then return false end
        for _, q in ipairs(ws.queue) do
            if q.a == w.id and q.b == target.id and q.def == rd then return true end
        end
        local pos = 1
        for i, q in ipairs(ws.queue) do if q.manual then pos = i + 1 end end
        table.insert(ws.queue, pos, { a = w.id, b = target.id, def = rd, auto = true, data = { jealous = true } })
        while #ws.queue > 6 do table.remove(ws.queue) end
        return true
    end
    if w.act and w.act.manual then return false end
    if ws then
        -- leave the other conversation once this tick's exchanges are done, then go
        C.Defer(function()
            local s = C.SessionOf(w.id)
            if s and not s.dead then
                C.RemoveMember(world, s, w.id, "stormed off", true)
                if C.Count(s) < 2 then C.Dissolve(world, s, "too few") end
            end
            if world.actors[w.id] and world.actors[target.id] and not C.SessionOf(w.id) then confrontOrder(world, w, target) end
        end)
        return true
    end
    confrontOrder(world, w, target)
    return true
end

-- Grouchy people answer back; hurt nice people walk away. Answering back is a new exchange b
-- starts on their own, so it needs free will; walking away is part of the reaction.
function C.Retaliate(world, sess, ex, a, b, ok)
    local d = ex.def
    local nice = P.Get(b, "nice")
    local fw = autonomyOn(world)
    if d.kind ~= "hostile" and not ok and P.ResponseStyle(b) == "rude" then
        if fw and SS.Random(world, "social") < 0.5 - nice * 0.1 then
            local rd = S.byId[P.Get(b, "playful") >= 5 and "tease" or "argue"]
            if C.CanStart(world, b, a, rd) then C.Queue(world, sess, { a = b.id, b = a.id, def = rd, auto = true }) end
        end
    elseif d.kind == "hostile" and d.id ~= "scold" and d.id ~= "break_up" then
        if fw and not ok and nice <= 3 and SS.Random(world, "social") < (4 - nice) / 8 then
            local rd = S.byId.argue
            if C.CanStart(world, b, a, rd) then C.Queue(world, sess, { a = b.id, b = a.id, def = rd, auto = true }) end
        elseif ok and nice >= 6 and sess.members[b.id] then
            ex.storm = b.id
        end
    end
end

-- Comic situation: a guest admires an expensive ornament and ignores the host.
C.ORNAMENT_OUTCOME = {
    mine = { d = -3 }, theirs = { d = 0.5 }, social = { 1, 2 }, fun = { 0, 4 }, pose = { "idle", "idle" },
    icon = { "react_awkward", "react_star" },
}
function C.OrnamentDistraction(world, ex, a, b)
    local d = ex.def
    if d.kind == "hostile" or d.kind == "romantic" or not C.IsHost(world, a) or not C.IsVisitor(world, b) then return false end
    local sess = C.SessionOf(a.id)
    if sess and sess.ornamentDone then return false end
    local W = SS.World
    local lv = b.level or 0
    local room = W.RoomAt(world, lv, math.floor(b.x), math.floor(b.y))
    local best, bp
    for _, oid in ipairs(sortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and (o.level or 0) == lv and (def.cat == "decor" or SS.Tags.Has(def, "painting")) and (def.price or 0) >= 750
            and W.RoomAt(world, lv, o.x, o.y) == room then
            if not bp or def.price > bp then best, bp = o, def.price end
        end
    end
    if not best then return false end
    local p = 0.25 + (10 - P.Get(b, "nice")) * 0.02 + math.min(0.2, (bp - 750) / 10000)
    if SS.Random(world, "social") >= p then return false end
    ex.ornament, ex.ornamentOid, ex.objDef = true, best.id, best.def
    if sess then sess.ornamentDone = true end
    return true
end

---------------------------------------------------------------------------
-- Behaviour special to single interactions
---------------------------------------------------------------------------
local function defer(fn) deferred[#deferred + 1] = fn end
C.Defer = defer

local function bestSkill(a)
    local best, bv
    for _, sk in ipairs((SS.Skills and SS.Skills.LIST) or {}) do
        local v = SS.Skills.Level and SS.Skills.Level(a, sk) or 0
        if v > 0 and (not bv or v > bv) then best, bv = sk, v end
    end
    return best, bv
end

-- Order someone to tidy a mess object after an argument about chores.
function C.OrderCleanup(world, who)
    for _, oid in ipairs(sortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and L.MessKind(o, def) then
            for _, iid in ipairs(def.actions or {}) do
                if P.Profile(iid, o.def).tidy and SS.Actions.Available(world, who, o, iid) then
                    who.queue = who.queue or {}
                    table.insert(who.queue, { oid = oid, iid = iid, manual = false, data = { chores = true } })
                    return oid, iid
                end
            end
        end
    end
    return nil
end

-- Where a gift to b would go: "same" (b lives with the giver: the item stays in the shared
-- inventory and becomes b's), "household" (b's household inventory, if it has room) or
-- "keepsake" (someone with no household, such as a townie, keeps it personally in
-- root.social.keepsakes[b.id], bounded; it moves into their household's inventory if they ever
-- join one). Returns kind, household or nil, reason. Nothing is ever given into thin air.
C.INV_CAP = 200     -- fallback when catalogue's SS.Inventory.CAP is absent (same number)
C.KEEPSAKES = 12    -- gifts one person without a household can hold
function C.GiftDestination(world, a, b)
    local root = world.root or world
    if a and a.householdId and a.householdId == b.householdId then return "same", root.households[a.householdId] end
    local hh = b.householdId and root.households and root.households[b.householdId]
    if b.householdId and not hh then return nil, first(b) .. "'s household can't be found, so there's nowhere to keep it." end
    if hh then
        local cap = (SS.Inventory and SS.Inventory.CAP) or C.INV_CAP
        if type(hh.inventory) == "table" and #hh.inventory >= cap then
            return nil, first(b) .. "'s home has no room for it (" .. cap .. " things stored already)."
        end
        return "household", hh
    end
    local s = So.Data(world)
    local k = s.keepsakes and s.keepsakes[b.id]
    if k and #k >= C.KEEPSAKES then return nil, first(b) .. " can't carry another keepsake." end
    return "keepsake"
end

-- Keepsakes of people without a household (bounded; see C.GiftDestination).
function C.Keepsakes(world, rid)
    local s = So.Data(world)
    return s.keepsakes and s.keepsakes[rid] or {}
end

-- Someone who received keepsakes and has since joined a household brings them along (room
-- permitting; the rest stay as keepsakes).
function C.SettleKeepsakes(world)
    local s = So.Data(world)
    if not s.keepsakes then return 0 end
    local root = world.root or world
    local moved = 0
    for _, rid in ipairs(sortedKeys(s.keepsakes)) do
        local p = root.residents and root.residents[rid]
        local hh = p and p.householdId and root.households and root.households[p.householdId]
        local list = s.keepsakes[rid]
        if hh then
            local cap = (SS.Inventory and SS.Inventory.CAP) or C.INV_CAP
            hh.inventory = type(hh.inventory) == "table" and hh.inventory or {}
            while #list > 0 and #hh.inventory < cap do
                local it = table.remove(list, 1)
                if SS.Inventory and SS.Inventory.AddToHousehold then
                    if not SS.Inventory.AddToHousehold(world, hh.id, it) then table.insert(list, 1, it); break end
                else
                    hh.inventory[#hh.inventory + 1] = it
                    SS.Emit("inventory", world, "add", it, hh.id)
                end
                moved = moved + 1
            end
        end
        if #list == 0 then s.keepsakes[rid] = nil end
    end
    return moved
end

local function indexIn(list, item)
    for i = 1, #(list or {}) do if list[i] == item then return i end end
end

-- Hand an inventory item from a's household to b. The destination is checked first; the item
-- leaves the giver only when it has somewhere to go, and goes back where it was if adding it
-- fails after all. Returns true, or false and the reason (the gift is then handed back).
function C.TransferItem(world, a, b, item)
    local root = world.root or world
    local from = a and root.households and root.households[a.householdId]
    if not from or not item then return false, "There's nothing to give." end
    local idx = indexIn(from.inventory, item)
    if not idx then return false, "The gift isn't in the inventory any more." end
    local dest, to = C.GiftDestination(world, a, b)
    if not dest then return false, to end
    item.data = type(item.data) == "table" and item.data or {}
    if dest == "same" then
        -- living together: it stays in the shared inventory and now belongs to b
        item.data.owner, item.data.from, item.data.givenAt = b.id, a.id, now(world)
        SS.Emit("inventory", world, "update", item, from.id)
        return true
    end
    local active = world.household and world.household.id == from.id
    local removed
    if active and SS.Inventory and SS.Inventory.Remove then removed = SS.Inventory.Remove(world, item)
    else
        table.remove(from.inventory, idx)
        removed = true
        SS.Emit("inventory", world, "remove", item, from.id)
    end
    if not removed then return false, "The gift isn't in the inventory any more." end
    local prevOwner, prevFrom, prevAt = item.data.owner, item.data.from, item.data.givenAt
    item.data.owner, item.data.from, item.data.givenAt = b.id, a.id, now(world)
    local added, why
    if dest == "household" then
        if SS.Inventory and SS.Inventory.AddToHousehold then
            added, why = SS.Inventory.AddToHousehold(world, to.id, item)
        elseif SS.Inventory and SS.Inventory.Add and world.household and world.household.id == to.id then
            added, why = SS.Inventory.Add(world, item)
        else
            to.inventory = type(to.inventory) == "table" and to.inventory or {}
            to.inventory[#to.inventory + 1] = item
            SS.Emit("inventory", world, "add", item, to.id)
            added = item
        end
    else
        local s = So.Data(world)
        s.keepsakes = s.keepsakes or {}
        s.keepsakes[b.id] = s.keepsakes[b.id] or {}
        local list = s.keepsakes[b.id]
        list[#list + 1] = item
        added = item
    end
    if added then return true end
    -- could not be added after all: put it back exactly where it was
    item.data.owner, item.data.from, item.data.givenAt = prevOwner, prevFrom, prevAt
    if active and SS.Inventory and SS.Inventory.Insert then SS.Inventory.Insert(world, item, idx)
    else
        table.insert(from.inventory, math.min(idx, #from.inventory + 1), item)
        SS.Emit("inventory", world, "add", item, from.id)
    end
    return false, why or (first(b) .. " has nowhere to keep it.")
end

-- Gifts: offered only when the present has somewhere to go; the item changes hands at the
-- moment the outcome is decided, before any reward, and a gift that can't be kept is handed back.
function C.GiftCheck(world, a, b)
    local dest, why = C.GiftDestination(world, a, b)
    if not dest then return false, why end
    return true
end

C.HANDBACK_OUTCOME = {
    mine = { d = -0.5 }, theirs = { d = 1 }, social = { 2, 2 }, pose = { "idle", "idle" },
    icon = { "react_awkward", "react_shrug" }, line = "gift_handback", by = "b",
}

function C.GiftDecide(world, ex, a, b, ok)
    if not ex.item then return false end
    local r = So.Get(world, b.id, a.id)
    if r and r.life < -30 then ex.refused = true; return false end
    local given, why = C.TransferItem(world, a, b, ex.item)
    if not given then ex.handedBack = why or "there's nowhere to keep it"; return false end
    ex.given = true
    return ok
end

function C.GiftAfter(world, ex, a, b, ok)
    if ex.handedBack then
        SS.Actions.Message(world, a, first(b) .. " handed the " .. tostring(ex.itemName or "gift") .. " back. " .. ex.handedBack, "soc_gift")
        SS.Emit("giftHandedBack", world, a.id, b.id, ex.item, ex.handedBack)
    elseif ex.given then
        SS.Emit("giftGiven", world, a.id, b.id, ex.item)
    end
end

---------------------------------------------------------------------------
-- Invitations kept later ("come over sometime")
---------------------------------------------------------------------------
-- An accepted invitation is a promise. root.social.invites keeps it (bounded) and the guest visit
-- is booked with the visitors module once the guest has left and the host's household is back on
-- its home lot, for the next evening at least C.INVITE_LEAD minutes ahead. (The visitors module
-- refuses to book someone who is on the lot right now, so asking at the moment of the yes would
-- always fail.) A booking that is refused is retried a few times, then the host is told why.
--   invites[n] = { t, host, guest, hh, lotId, at, state = "pending"|"booked"|"done"|"failed"|
--                  "cancelled"|"lapsed", tries, next, request, why }
C.INVITE_HOUR, C.INVITE_LEAD = 18, 240
C.INVITE_TRIES, C.INVITE_RETRY, C.INVITE_KEEP, C.INVITE_EXPIRE = 4, 60, 20, 3 * 1440

-- The first evening (C.INVITE_HOUR) at least C.INVITE_LEAD minutes after t.
function C.InviteTime(world, t)
    t = t or now(world)
    local at = math.floor(t / 1440) * 1440 + C.INVITE_HOUR * 60
    while at < t + C.INVITE_LEAD do at = at + 1440 end
    return at
end

function C.Invites(world)
    local s = So.Data(world)
    if type(s.invites) ~= "table" then s.invites = {} end
    return s.invites
end

local OPEN_INVITE = { pending = true, booked = true }
local function whenText(world, at)
    local days = math.floor(at / 1440) - math.floor(now(world) / 1440)
    if days <= 0 then return "this evening" elseif days == 1 then return "tomorrow evening" end
    return "in " .. days .. " days"
end
local function tellHost(world, rec, text)
    local host = world.actors[rec.host]
    if host then SS.Actions.Message(world, host, text, "soc_invite") end
    if world.household and world.household.id == rec.hh and SS.Actions.Journal then pcall(SS.Actions.Journal, world, text) end
end

function C.AddInvite(world, a, b)
    local root = world.root or world
    local list = C.Invites(world)
    for _, rec in ipairs(list) do
        if rec.guest == b.id and rec.hh == a.householdId and OPEN_INVITE[rec.state] then rec.host = a.id; return rec end
    end
    local hh = a.householdId and root.households and root.households[a.householdId]
    local rec = { t = now(world), host = a.id, guest = b.id, hh = a.householdId, lotId = hh and hh.lotId,
        at = C.InviteTime(world), state = "pending", tries = 0 }
    if not rec.lotId then
        rec.state, rec.why = "failed", "there's no home to invite them to"
        tellHost(world, rec, first(b) .. " said yes, but " .. rec.why .. ".")
    elseif not (SS.Visitors and SS.Visitors.Request) then
        rec.state, rec.why = "failed", "visits can't be arranged in this version"
        tellHost(world, rec, first(b) .. " said yes, but " .. rec.why .. ".")
    end
    list[#list + 1] = rec
    -- bounded: settled invitations go first, then the oldest
    while #list > C.INVITE_KEEP do
        local drop = 1
        for k = 1, #list do if not OPEN_INVITE[list[k].state] then drop = k; break end end
        table.remove(list, drop)
    end
    C.inviteCheck = nil
    SS.Emit("socialInvite", world, a.id, b.id, rec)
    return rec
end

-- Book what can be booked (about once a minute, and right after someone leaves the lot).
function C.InvitesTick(world)
    local n = now(world)
    local nextT = C.inviteCheck
    if nextT and n < nextT and nextT - n <= 1 then return end
    C.inviteCheck = n + 1
    local s = So.Data(world)
    local list = s.invites
    if type(list) ~= "table" or #list == 0 then return end
    local root = world.root or world
    for k = 1, #list do
        local rec = list[k]
        if rec.state == "pending" then
            local host, guest = root.residents and root.residents[rec.host], root.residents and root.residents[rec.guest]
            if not host or host.dead or not guest or guest.dead then
                rec.state, rec.why = "cancelled", "someone is no longer around"
            elseif n - rec.t > C.INVITE_EXPIRE then
                rec.state, rec.why = "lapsed", "nobody followed it up"
            elseif world.lot and world.lot.id == rec.lotId and not world.actors[rec.guest] and (rec.next or 0) <= n then
                if rec.at < n + 30 then rec.at = C.InviteTime(world) end
                local okCall, id, why = pcall(SS.Visitors.Request, world, "guest", { rid = rec.guest, host = rec.host,
                    reason = "invited", invited = true, invitedBy = rec.host, lotId = rec.lotId, at = rec.at })
                if okCall and id then
                    rec.state, rec.request = "booked", id
                    tellHost(world, rec, So.FirstName(world, rec.guest) .. " is coming over " .. whenText(world, rec.at) .. ".")
                    SS.Emit("socialInviteBooked", world, rec)
                else
                    rec.tries = (rec.tries or 0) + 1
                    rec.why = okCall and tostring(why or "no reason given") or "the visit couldn't be arranged"
                    if rec.tries >= C.INVITE_TRIES then
                        rec.state = "failed"
                        tellHost(world, rec, So.FirstName(world, rec.guest) .. " can't come over after all: " .. rec.why)
                    else
                        rec.next = n + C.INVITE_RETRY
                    end
                end
            end
        end
    end
end

-- The booked visit happened, or fell through (visitors module events).
SS.On("visitorArrived", function(world, a, role)
    if not world or not a or role ~= "guest" then return end
    for _, rec in ipairs(C.Invites(world)) do
        if rec.state == "booked" and rec.guest == a.id then rec.state = "done" end
    end
end)
SS.On("visitorCancelled", function(world, r)
    if not world or type(r) ~= "table" then return end
    for _, rec in ipairs(C.Invites(world)) do
        if rec.state == "booked" and rec.request == r.id then rec.state, rec.why = "cancelled", r.why end
    end
end)
SS.On("actorRemoved", function(world, r)
    if world and r and r.id then C.inviteCheck = nil end
end)
SS.On("visitorLeft", function() C.inviteCheck = nil end)

-- Gift appeal: its topic (item.data.topic / item.data.interest) against the recipient's interests.
local function giftTopic(item)
    local d = item and item.data
    return d and (d.topic or d.interest)
end

-- Pick the gift that suits b best (or the ordered one).
local function pickItem(world, ex, a, b, kind)
    local chosen = ex.data and ex.data.item
    local items = C.Items(world, a, kind)
    if type(chosen) == "table" then
        for _, it in ipairs(items) do if it == chosen then return it end end
        -- an order resumed from a save holds a copy of the item: find the same one again
        for _, it in ipairs(items) do
            if chosen.id and it.id == chosen.id then return it end
            if not chosen.id and it.def == chosen.def and it.name == chosen.name then return it end
        end
    end
    local best, bv
    for _, it in ipairs(items) do
        local t = giftTopic(it)
        local v = (t and P.Interest(b, t) or 5) * 100 + (it.value or 0) / 100
        if not bv or v > bv then best, bv = it, v end
    end
    return best
end

C.SPECIAL = {
    introduce = {
        pref = function(world, a, b, pc) return 1.4 end, prefMax = 1.4,
    },
    farewell = {
        after = function(world, ex, a, b, ok)
            if C.IsVisitor(world, b) and SS.Visitors and SS.Visitors.Leave then
                defer(function() if world.actors[b.id] then SS.Visitors.Leave(world, b, "goodbye") end end)
            end
        end,
    },
    ask_day = {
        decide = function(world, ex, a, b, ok)
            if mood(b) < -15 or So.Upset(world, b.id) then ex.vent = true; return true end
            return ok
        end,
        after = function(world, ex, a, b, ok)
            if ex.vent then So.SetUpset(world, b.id, 90, "bad day", nil) end
        end,
    },
    share_enthusiasm = {
        pref = function(world, a, b, pc) return 1 end,
    },
    debate = {
        check = function(world, a, b, pc)
            return C.PickTopic(world, a, b, "shared") ~= nil, "You don't share any subject worth debating."
        end,
    },
    gossip = {
        -- sensible people don't gossip within earshot of the person they're gossiping about
        pref = function(world, a, b, pc)
            local sid = C.Subject(world, a, b)
            local subj = sid and world.actors[sid]
            if subj and C.Earshot(world, subj, a) then return P.Get(a, "nice") <= 2 and 0.5 or 0.1 end
            return 1
        end,
        open = function(world, ex, a, b)
            ex.subject = C.Subject(world, a, b)
            local p = ex.subject and (world.root or world).residents[ex.subject]
            ex.subjectName = p and first(p)
        end,
        chance = function(world, a, b, pc, ex)
            return (ex.subject and So.Get(world, b.id, ex.subject)) and 5 or 0
        end,
        after = function(world, ex, a, b, ok)
            local sid = ex.subject
            if not sid then return end
            local ra = So.Get(world, a.id, sid)
            if ok then
                if ra and ra.life < 20 then So.Adjust(world, b.id, sid, { daily = -4 * ex.mag, life = -1 * ex.mag })
                else So.Adjust(world, b.id, sid, { daily = 1 }) end
            end
            local subj = world.actors[sid]
            if subj and C.Earshot(world, subj, a) then
                So.Adjust(world, sid, a.id, { daily = -15, life = -4 })
                So.SetUpset(world, sid, 60, "gossiped about", a.id)
                balloon(world, subj, "react_angry", L.Say(world, subj, "overheard", { listener = a, role = "listener" }), 3)
                SS.Needs.Add(a, "social", -4)
                balloon(world, a, "react_embarrassed", nil, 2)
            end
        end,
    },
    impression = {
        open = function(world, ex, a, b)
            ex.subject = C.Subject(world, a, b)
            local p = ex.subject and (world.root or world).residents[ex.subject]
            ex.subjectName = p and first(p)
        end,
        after = function(world, ex, a, b, ok)
            local subj = ex.subject and world.actors[ex.subject]
            if subj and human(subj) and C.Sees(world, subj, a, 6) then
                So.Adjust(world, subj.id, a.id, { daily = -12, life = -3 })
                balloon(world, subj, "react_angry", L.Say(world, subj, "overheard", { listener = a, role = "listener" }), 3)
                balloon(world, a, "react_embarrassed", nil, 2)
            end
        end,
    },
    ask_advice = {
        after = function(world, ex, a, b, ok)
            if not ok or not (SS.Skills and SS.Skills.Gain) then return end
            local sk, lv = bestSkill(b)
            if sk and SS.Skills.Level(a, sk) < lv then pcall(SS.Skills.Gain, world, a, sk, 0.05) end
        end,
    },
    boast = {
        open = function(world, ex, a, b)
            local sk, lv = bestSkill(a)
            if sk and lv >= 3 then ex.skill = sk end
            if a.career and type(a.career) == "table" and type(a.career.title) == "string" then ex.job = a.career.title end
            local root = world.root or world
            local hh = root.households and root.households[a.householdId]
            if hh and hh.money and hh.money >= 5000 then ex.amount = hh.money end
            local n, def = L.MessNear(world, a)
            if n >= 2 then ex.undercut, ex.objDef = true, def end
        end,
        chance = function(world, a, b, pc, ex) return ex.undercut and -25 or 0 end,
    },
    thumb_war = {
        after = function(world, ex, a, b, ok)
            if not ok then return end
            local bodyA = SS.Skills and SS.Skills.Level and SS.Skills.Level(a, "body") or 0
            local bodyB = SS.Skills and SS.Skills.Level and SS.Skills.Level(b, "body") or 0
            local aWins = SS.Random(world, "social") < 0.5 + (bodyA - bodyB) * 0.05
            local win, lose = aWins and a or b, aWins and b or a
            ex.winner = win.id
            setPose(win, "celebrate"); balloon(world, win, "react_trophy", nil, 2)
            if P.Get(lose, "nice") <= 3 then
                So.Adjust(world, lose.id, win.id, { rivalry = 6, daily = -3 })
                setPose(lose, "argue"); balloon(world, lose, "react_angry", nil, 2)
            else
                setPose(lose, "laugh"); balloon(world, lose, "react_laugh", nil, 2)
            end
        end,
    },
    play_tag = {
        chance = function(world, a, b, pc, ex)
            if b.age == "child" then return 15 end
            if P.Get(b, "playful") < 5 and P.Get(b, "active") < 5 then return -20 end
            return 0
        end,
    },
    compliment = {
        chance = function(world, a, b, pc, ex) return mood(b) < -10 and 10 or 0 end,
    },
    comfort = {
        chance = function(world, a, b, pc, ex)
            local u = So.Upset(world, b.id)
            if u and u.by == a.id then return -30 end
            return 0
        end,
        after = function(world, ex, a, b, ok)
            if not ok then return end
            local u = So.Upset(world, b.id)
            if u and u.reason == "grief" then u.untilT = now(world) + math.max(0, (u.untilT - now(world)) * 0.5)
            else So.ClearUpset(world, b.id) end
            SS.Needs.Add(b, "fun", 5 * ex.mag)
        end,
        prefMax = 2.5 * (1 + 100 / 60),
        pref = function(world, a, b, pc)
            if pc.ab.life < -10 then return 0.1 end
            return (So.Upset(world, b.id) and 2.5 or 1) * (1 + math.max(0, pc.ab.life) / 60)
        end,
    },
    apologize = {
        chance = function(world, a, b, pc, ex)
            local c = So.Conflict(world, a.id, b.id)
            if c and now(world) - c.t < 20 then return -15 end
            return 0
        end,
        after = function(world, ex, a, b, ok)
            if not ok then return end
            local c = So.Conflict(world, a.id, b.id) or So.Conflict(world, b.id, a.id)
            local ev = c and c.ev
            So.Reconcile(world, a.id, b.id)
            So.ClearUpset(world, b.id)
            if ev and SS.Events and SS.Events.Resolve then pcall(SS.Events.Resolve, world, ev, "reconciled") end
        end,
        pref = function(world, a, b, pc) return pc.ab.life >= -20 and 2 * (0.4 + P.Get(a, "nice") / 8) or 0.2 end,
        prefMax = 2 * (0.4 + 10 / 8),
    },
    argue = {
        after = function(world, ex, a, b, ok)
            if P.Get(a, "nice") <= 3 then SS.Needs.Add(a, "fun", 4) end
            if ex.data and ex.data.jealous then So.Adjust(world, b.id, a.id, { daily = -4 }) end
            if ex.storm then defer(function() local s = C.SessionOf(ex.storm); if s then C.RemoveMember(world, s, ex.storm, "stormed off", true) end end) end
        end,
    },
    insult = {
        after = function(world, ex, a, b, ok)
            if P.Get(a, "nice") <= 3 then SS.Needs.Add(a, "fun", 5) end
            if ex.storm then defer(function() local s = C.SessionOf(ex.storm); if s then C.RemoveMember(world, s, ex.storm, "stormed off", true) end end) end
        end,
    },
    bicker_chores = {
        open = function(world, ex, a, b)
            local n, def = L.MessOnLot(world)
            ex.objDef = def
        end,
        -- agreeing to tidy up sends b off to do it (free will only; otherwise the player decides)
        after = function(world, ex, a, b, ok, sess)
            if ok and autonomyOn(world) then
                defer(function()
                    local s = C.SessionOf(b.id)
                    if s then C.RemoveMember(world, s, b.id, "went to tidy up", true) end
                    if world.actors[b.id] then C.OrderCleanup(world, b) end
                end)
            end
        end,
        pref = function(world, a, b, pc)
            local n = C.LotMess(world)
            if n >= 2 and P.Get(a, "neat") >= 6 and P.Get(b, "neat") < P.Get(a, "neat") then return 1.6 end
            return 0.2
        end,
        prefMax = 1.6,
    },
    mock_hobby = {},
    flirt = {
        pref = function(world, a, b, pc) return C.RomancePref(world, a, b, pc, 0) end, prefMax = 1 * (0.4 + 100 / 40) * 1.5,
    },
    sweet_talk = { pref = function(world, a, b, pc) return C.RomancePref(world, a, b, pc, 20) end, prefMax = 1 * (0.4 + 100 / 40) * 1.5 },
    hold_hands = { pref = function(world, a, b, pc) return C.RomancePref(world, a, b, pc, 25) end, prefMax = 1 * (0.4 + 100 / 40) * 1.5 },
    embrace = { pref = function(world, a, b, pc) return C.RomancePref(world, a, b, pc, 35) end, prefMax = 1 * (0.4 + 100 / 40) * 1.5 },
    kiss = { pref = function(world, a, b, pc) return C.RomancePref(world, a, b, pc, 45) end, prefMax = 1 * (0.4 + 100 / 40) * 1.5 },
    ask_partner = {
        after = function(world, ex, a, b, ok)
            if ok then
                So.SetPartner(world, a.id, b.id, true)
                recordEvent(world, "social.partners", { a = a.id, b = b.id }, "together")
                setPose(a, "celebrate")
            end
        end,
        pref = function(world, a, b, pc)
            if (pc.ab.romance or 0) >= 70 and (pc.ba.romance or 0) >= 50 then return C.RomancePref(world, a, b, pc, 50) end
            return 0
        end,
        prefMax = 1 * (0.4 + 100 / 40) * 1.5,
    },
    break_up = {
        decide = function(world, ex, a, b, ok) return ok end,
        after = function(world, ex, a, b, ok)
            So.SetPartner(world, a.id, b.id, false)
            recordEvent(world, "social.breakup", { a = a.id, b = b.id, messy = not ok }, ok and "amicable" or "messy")
        end,
    },
    give_gift = {
        check = function(world, a, b, pc) return C.GiftCheck(world, a, b) end,
        open = function(world, ex, a, b)
            ex.item = pickItem(world, ex, a, b, "gift")
            ex.itemName = ex.item and ex.item.name
            ex.topic = giftTopic(ex.item)
        end,
        chance = function(world, a, b, pc, ex) return ex.item and 0 or -100 end,
        decide = function(world, ex, a, b, ok) return C.GiftDecide(world, ex, a, b, ok) end,
        after = function(world, ex, a, b, ok) C.GiftAfter(world, ex, a, b, ok) end,
    },
    give_flowers = {
        check = function(world, a, b, pc) return C.GiftCheck(world, a, b) end,
        open = function(world, ex, a, b)
            ex.item = pickItem(world, ex, a, b, "flowers")
            ex.itemName = ex.item and ex.item.name
            ex.topic = "gardening"
            if So.CanRomance(world, a.id, b.id) and ((So.Get(world, a.id, b.id) or EMPTY).romance or 0) >= 15 then ex.romanticGift = true end
        end,
        decide = function(world, ex, a, b, ok) return C.GiftDecide(world, ex, a, b, ok) end,
        after = function(world, ex, a, b, ok)
            C.GiftAfter(world, ex, a, b, ok)
            if ok and ex.given and ex.romanticGift then So.Adjust(world, b.id, a.id, { romance = 5 * ex.mag }) end
        end,
    },
    invite_over = {
        -- a yes is a promise: the visit is booked later, once the guest has gone home (C.AddInvite)
        after = function(world, ex, a, b, ok) if ok then C.AddInvite(world, a, b) end end,
    },
    invite_outing = {
        after = function(world, ex, a, b, ok)
            if not ok then return end
            local lotId = (ex.data and ex.data.lotId) or C.Venues(world)[1]
            defer(function()
                if not (SS.Travel and SS.Travel.Go) or not lotId then return end
                local ok2, why = SS.Travel.Go(world, { a.id, b.id }, lotId)
                if not ok2 and world.actors[a.id] then
                    SS.Actions.Message(world, a, "The outing fell through: " .. tostring(why or "no reason given"), "soc_outing")
                end
            end)
        end,
    },
    ask_leave = {
        after = function(world, ex, a, b, ok)
            defer(function()
                local s = C.SessionOf(b.id)
                if s then C.RemoveMember(world, s, b.id, "asked to leave", true) end
                if world.actors[b.id] and SS.Visitors and SS.Visitors.Leave then SS.Visitors.Leave(world, b, "asked") end
            end)
        end,
    },
    group_chat = {
        check = function(world, a, b, pc)
            for _, id in ipairs(actorIds(world)) do
                local p = world.actors[id]
                if id ~= a.id and id ~= b.id and human(p) and (p.level or 0) == (a.level or 0) and dist(p, a) <= 8 then return true end
            end
            return false, "Nobody else is around to join in."
        end,
        after = function(world, ex, a, b, ok, sess)
            -- a group the player gathers keeps talking by itself (bounded like any session)
            if ok then sess.group = true; C.InviteNearby(world, sess, a, 3) end
        end,
    },
    join_group = {
        after = function(world, ex, a, b, ok, sess)
            if ok then
                for rid, m in pairs(sess.members) do
                    if rid ~= a.id and rid ~= b.id and m.state == "in" then So.Adjust(world, rid, a.id, { daily = 2 }) end
                end
            else
                defer(function() local s = C.SessionOf(a.id); if s then C.RemoveMember(world, s, a.id, "left awkwardly", true) end end)
            end
        end,
    },
    read_to = {
        after = function(world, ex, a, b, ok)
            if ok and SS.Skills and SS.Skills.Gain then
                pcall(SS.Skills.Gain, world, b, "creativity", 0.08 * ex.mag)
                pcall(SS.Skills.Gain, world, b, "logic", 0.04 * ex.mag)
            end
        end,
    },
    scold = {
        chance = function(world, a, b, pc, ex) return C.Misbehaved(world, b) and 25 or -15 end,
        pref = function(world, a, b, pc) return C.Misbehaved(world, b) and 2 or 0 end, prefMax = 2,
    },
    help_homework = {
        after = function(world, ex, a, b, ok)
            if ok and SS.School and SS.School.HelpHomework then pcall(SS.School.HelpHomework, world, a, b) end
        end,
    },
}

-- Romantic autonomy preference: attraction, existing feelings and loyalty to a partner.
function C.Attraction(a, b)
    local x, y = a.id < b.id and a.id or b.id, a.id < b.id and b.id or a.id
    local h = (P.Hash(x .. "~" .. y) % 1000) / 1000
    return U.clamp(h * 0.6 + (P.Compatibility(a, b) + 1) * 0.2, 0, 1)
end
function C.RomancePref(world, a, b, pc, minRomance)
    if (pc.ab.romance or 0) < minRomance then return 0 end
    if pc.ab.flags.enemy then return 0 end
    local pref = C.Attraction(a, b) * (0.4 + (pc.ab.romance or 0) / 40)
    if pc.ab.life < 10 and not pc.partner then pref = pref * 0.3 end
    if So.HasOtherPartner(world, a.id, b.id) then pref = pref * 0.08 end
    if pc.partner then pref = pref * 1.5 end
    return pref
end
C.ROMANCE_PREF_MAX = 1 * (0.4 + 100 / 40) * 1.5   -- attraction <= 1, romance <= 100, partner x1.5

---------------------------------------------------------------------------
-- Executor interactions
---------------------------------------------------------------------------
-- The initiator's action (soc_<id>): route (executor) -> engage -> session -> member.
function C.InitTick(world, actor, act, target, dt)
    local d = S.byIid[act.iid]
    local data = act.data
    if data.epoch ~= C.epoch then
        -- a fresh order, or one resumed from a save (conversations are runtime only): an exchange
        -- that already happened is never replayed; anything else starts again from the approach
        if data.resolved then SS.Actions.Finish(world, actor, "done"); return end
        data.stage, data.conv, data.aborted, data.exDone, data.ok = nil, nil, nil, nil, nil
        data.epoch = C.epoch
    end
    data.stage = data.stage or "approach"
    if data.stage ~= "approach" then
        local sess = data.conv and C.sessions[data.conv]
        if not (sess and sess.members[actor.id]) and not data.aborted then
            SS.Actions.Finish(world, actor, (act.manual and not data.resolved) and "failed" or "done", C.AbortText(world, act, "ended"))
            return
        end
        if sess then C.Settle(world, sess, actor, dt) end
    end
    if data.stage == "approach" then
        local b = world.actors[act.tid]
        if not b then SS.Actions.Finish(world, actor, "failed", "They're not here any more."); return end
        if (b.level or 0) ~= (actor.level or 0) or dist(actor, b) > 2.9 then
            if (data.chase or 0) >= C.CHASE then
                SS.Actions.Finish(world, actor, "failed", "Couldn't catch up with " .. first(b) .. ".")
                return
            end
            data.rechase = true
            SS.Actions.Finish(world, actor, "done")
            return
        end
        -- re-check suitability on arrival (things change while walking)
        local ok, why = C.CanStart(world, actor, b, d)
        if not ok then SS.Actions.Finish(world, actor, "failed", why); return end
        local sess
        sess, why = C.Engage(world, actor, b, d, act)
        if not sess then SS.Actions.Finish(world, actor, "failed", why); return end
        data.stage = "session"
        act.label = d.label .. " (" .. first(b) .. ")"
        return
    end
    if data.stage == "session" then
        if data.aborted then
            SS.Actions.Finish(world, actor, act.manual and "failed" or "done", C.AbortText(world, act, data.aborted))
            return
        end
        -- the ordered exchange is over once its reaction has played out
        if data.resolved and data.exDone then
            -- stay and keep chatting when autonomy is on, or in a group the player gathered
            local sess = C.sessions[data.conv]
            local fw = (world.settings and world.settings.freeWill) or (sess and sess.group)
            -- someone walked up and queued an exchange with me (joining, a follow-up): answer it first
            if not fw and sess and C.Pending(sess, actor.id) then return end
            if (act.manual and #(actor.queue or {}) > 0) or not fw then SS.Actions.Finish(world, actor, "done"); return end
            act.manual = false
            data.stage = "member"
            act.label = "Chatting"
        end
    end
end

function C.InitEnd(world, actor, act, target, status)
    C.OnActEnd(world, actor, act, status)
end

function C.InitNext(world, actor, act, target)
    if act.data and act.data.rechase then
        return { tid = act.tid, iid = act.iid, manual = act.manual,
            data = { chase = (act.data.chase or 0) + 1, item = act.data.item, lotId = act.data.lotId } }
    end
end

function C.OnActEnd(world, actor, act, status)
    local conv = act and act.data and act.data.conv
    local sess = conv and C.sessions[conv]
    if sess and sess.members[actor.id] then
        -- on the way over and couldn't get there (no route to the member walked to, or they left):
        -- walk to another member instead; each is tried once, then b drops out as before
        if status == "failed" and act.iid == "social_chat" and sess.members[actor.id].state == "joining" and not sess.dead then
            local tried = act.data.tried or {}
            if act.tid then tried[act.tid] = true end
            local to = C.NearestMember(world, sess, actor, nil, tried)
            if to then
                act.quiet = true   -- no "Can't find a way there." for someone who is still on their way
                actor.queue = actor.queue or {}
                table.insert(actor.queue, 1, { tid = to.id, iid = "social_chat", manual = false,
                    data = { conv = sess.id, epoch = C.epoch, tried = tried } })
                return
            end
        end
        -- the player queued another interaction with someone in this conversation: stay in it
        local nxt = actor.queue and actor.queue[1]
        if status == "done" and nxt and nxt.tid and sess.members[nxt.tid] and type(nxt.iid) == "string"
            and nxt.iid:sub(1, 4) == "soc_" and not sess.dead then
            sess.members[actor.id].switching = now(world) + 2
            return
        end
        C.RemoveMember(world, sess, actor.id, status == "cancelled" and "called away" or "left", false)
        if status == "cancelled" then
            -- the player took them out of it: don't wander straight back in
            actor.tmp = actor.tmp or {}
            actor.tmp.calledAway = now(world) + C.CALLED_AWAY
        end
        if C.Count(sess) < 2 then C.Dissolve(world, sess, "too few") end
    end
    if actor.tmp and actor.tmp.conv == conv then actor.tmp.conv = nil end
end

-- Other members' action ("social_chat").
function C.ChatTest(world, actor, target)
    local sess = C.SessionOf(actor.id)
    if not sess then return false, "The conversation is over." end
    return true
end
function C.ChatTick(world, actor, act, target, dt)
    local sess = act.data.conv and C.sessions[act.data.conv]
    if not sess or not sess.members[actor.id] or act.data.epoch ~= C.epoch then SS.Actions.Finish(world, actor, "done"); return end
    local m = sess.members[actor.id]
    C.MarkIn(world, sess, actor.id, m)
    actor.tmp = actor.tmp or {}
    actor.tmp.conv = sess.id
    C.Settle(world, sess, actor, dt)
    if not act.label or act.label == "Chatting" then
        local other = act.tid and world.actors[act.tid]
        act.label = "Chatting with " .. first(other)
    end
end
function C.ChatEnd(world, actor, act, target, status) C.OnActEnd(world, actor, act, status) end

SS.Interactions = SS.Interactions or {}
SS.Interactions.social_chat = {
    label = "Chatting", category = "Social", targetActor = true, pose = "idle", maxDur = 240, manualOnly = true,
    advert = { social = 1, fun = 1 }, test = C.ChatTest, onTick = C.ChatTick, onEnd = C.ChatEnd, social = true,
}
for _, d in ipairs(S.list) do
    SS.Interactions[d.iid] = {
        label = d.label, category = d.kind == "romantic" and "Romance" or "Social", targetActor = true, pose = d.pose or "talk",
        maxDur = 240, manualOnly = true, advert = d.adv or { social = 1 }, social = true, socialDef = d.id,
        test = function(world, actor, target) return C.CanStart(world, actor, target, d) end,
        onTick = C.InitTick, onEnd = C.InitEnd, next = C.InitNext,
    }
end

---------------------------------------------------------------------------
-- Session tick (runs as a Sim system before actors update)
---------------------------------------------------------------------------

-- Choose the next speaker and interaction in a session that has gone quiet.
local pickIds, spP, spW = {}, {}, {}
function C.PickNext(world, sess)
    local ids, nIds = sortedInto(sess.members, pickIds)
    local ns, many = 0, C.Count(sess, "in") > 1
    for k = 1, nIds do
        local rid = ids[k]
        local m = sess.members[rid]
        local p = world.actors[rid]
        if p and m.state == "in" and not m.path then
            local w = 1 + P.Get(p, "outgoing") * 0.25 + math.max(0, 50 - (p.needs.social or 0)) / 40 - C.Fatigue(world, p) * 1.5
            if rid == sess.lastSpeaker and many then w = w * 0.35 end
            w = w * (0.75 + SS.Random(world, "social") * 0.5)
            -- insertion by weight (heaviest first, ties by id: ids arrive sorted, so stable)
            local at = ns + 1
            while at > 1 and spW[at - 1] < w do spP[at], spW[at] = spP[at - 1], spW[at - 1]; at = at - 1 end
            spP[at], spW[at] = p, w
            ns = ns + 1
        end
    end
    for s = 1, ns do
        local a = spP[s]
        -- listener: the last speaker if it isn't a, else whoever a likes talking to most
        local best, bw
        for k = 1, nIds do
            local rid = ids[k]
            local p = world.actors[rid]
            local m = sess.members[rid]
            if p and m and rid ~= a.id and m.state == "in" and not m.path then
                local r = So.Get(world, a.id, rid) or EMPTY
                local w = r.daily + r.life * 0.5 + (rid == sess.lastSpeaker and 25 or 0) + SS.Random(world, "social") * 30
                if not bw or w > bw then best, bw = p, w end
            end
        end
        if best then
            local d = C.PickDef(world, a, best, sess)
            if d then
                for k = 1, ns do spP[k] = nil end
                return { a = a.id, b = best.id, def = d, auto = true }
            end
        end
    end
    for k = 1, ns do spP[k] = nil end
    return nil
end

C.NO_IN_SESSION = { introduce = false, group_chat = true, join_group = true, farewell = true, ask_leave = true,
    invite_over = true, invite_outing = true, give_gift = true, give_flowers = true, play_tag = true, break_up = true,
    ask_partner = true }

-- In a conversation: the next thing a says to b, weighted among the three best-scoring
-- definitions (same checks and scores as autonomy outside, with the session bonus).
local pickPc, pickEx = {}, { witnesses = 0 }
function C.PickDef(world, a, b, sess)
    local pc = C.PairInto(world, a, b, pickPc)
    local members = C.Count(sess, "in")
    pickEx.roomScore = roomScore(world, b)
    C.ScanBegin()
    local top = C.TopDefs(world, a, b, pc, 1, true, 3, 1, members, pickEx)
    C.ScanEnd()
    local n = top.n
    if n == 0 then return nil end
    local total = 0
    for k = 1, n do total = total + top.s[k] end
    local r = SS.Random(world, "social") * total
    for k = 1, n do
        r = r - top.s[k]
        if r <= 0 then return top.d[k] end
    end
    return top.d[1]
end

-- Leave conditions checked about once a minute: fatigue (shy people sooner), satisfaction,
-- urgent needs, maximum stay.
function C.LeaveReason(world, sess, rid, m)
    local p = world.actors[rid]
    if not p then return "gone" end
    local f = C.Fatigue(world, p)
    local soc = p.needs.social or 0
    -- shy people tire sooner (fatigue rate) and put up with loneliness longer (tolerance)
    if f >= C.LEAVE_FATIGUE and (soc >= P.Tolerance(p, "social") or f >= 0.99) then return "tired of talking" end
    if soc >= 97 and now(world) - m.since >= 8 and (p.needs.fun or 0) >= 60 then return "had enough chat" end
    if now(world) - m.since >= C.MAX_STAY then return "had to go" end
    local T = SS.Tuning
    for n = 1, #URGENT4 do
        if (p.needs[URGENT4[n]] or 0) < T.urgent then return "needs to go" end
    end
    return nil
end

local memberIds = {}
function C.TickSession(world, sess, dt)
    local n = now(world)
    -- validate members
    local ids, nIds = sortedInto(sess.members, memberIds)
    for k = 1, nIds do
        local rid = ids[k]
        local m = sess.members[rid]
        local p = world.actors[rid]
        if m then
            if not p or p.dead then
                C.RemoveMember(world, sess, rid, "gone", false)
            elseif m.noRoom then
                -- nowhere free to stand in this conversation (C.ClaimSlot): they excuse themselves
                balloon(world, p, "react_awkward", nil, 2, "thought")
                C.RemoveMember(world, sess, rid, "no room", true)
            elseif m.state == "joining" then
                local act = p.act
                local ours = act and act.data and act.data.conv == sess.id
                if ours and act.phase == "perform" then
                    C.MarkIn(world, sess, rid, m)
                elseif n - m.since > (ours and C.JOIN_WALK or C.JOIN_TIMEOUT) then
                    -- never set off, or set off and still not here after a walk across the house
                    C.RemoveMember(world, sess, rid, "never arrived", true)
                end
            else
                local act = p.act
                if not act or not act.data or act.data.conv ~= sess.id then
                    if not (m.switching and m.switching > n) then C.RemoveMember(world, sess, rid, "left", false) end
                elseif not m.path and ((p.level or 0) ~= sess.level or math.sqrt((p.x - sess.ax) ^ 2 + (p.y - sess.ay) ^ 2) > C.RADIUS) then
                    -- (someone still stepping into their spot is on the way in, not wandering off)
                    C.RemoveMember(world, sess, rid, "wandered off", true)
                end
            end
        end
    end
    if sess.dead then return end
    if C.Count(sess) < 2 then C.Dissolve(world, sess, "too few"); return end
    if n - sess.created > C.MAX_SESSION then C.Dissolve(world, sess, "talked out"); return end
    -- leave checks (about once a minute), never in the middle of one's own exchange
    if n - sess.checkT >= 1 then
        sess.checkT = n
        ids, nIds = sortedInto(sess.members, memberIds)
        for k = 1, nIds do
            local rid = ids[k]
            local m = sess.members[rid]
            if m and m.state == "in" and not (sess.ex and (sess.ex.a == rid or sess.ex.b == rid)) then
                local p = world.actors[rid]
                local act = p and p.act
                local pending = act and act.data and act.data.stage == "session" and not act.data.resolved
                local why = not pending and C.LeaveReason(world, sess, rid, m)
                if why then
                    balloon(world, p, why == "tired of talking" and "react_tired" or "react_bye", nil, 2)
                    C.RemoveMember(world, sess, rid, why, true)
                end
            end
        end
        if sess.dead then return end
        if C.Count(sess) < 2 then C.Dissolve(world, sess, "too few"); return end
    end
    -- exchanges
    local ex = sess.ex
    if ex then
        ex.t = ex.t + dt
        if ex.stage == "open" and ex.t >= ex.def.dur then
            C.Resolve(world, sess, ex)
            if sess.ex == ex then ex.stage, ex.t = "react", 0 end
        elseif ex.stage == "react" then
            if not ex.beat2 and ex.t >= ex.def.react * 0.5 then C.Beat2(world, sess, ex) end
            if ex.t >= ex.def.react then C.EndExchange(world, sess, ex) end
        end
        return
    end
    if n < sess.gapUntil then return end
    -- next exchange: queued requests first (manual before autonomous), then autonomous choice
    local queue = sess.queue
    for i = 1, #queue do
        local q = queue[i]
        local ma, mb = sess.members[q.a], sess.members[q.b]
        if ma and mb and ma.state == "in" and mb.state == "in" and not ma.path and not mb.path then
            table.remove(sess.queue, i)
            C.StartExchange(world, sess, q)
            return
        end
    end
    local waitingManual = false
    for i = 1, #queue do if queue[i].manual then waitingManual = true end end
    if not waitingManual and (autonomyOn(world) or sess.group) and C.Count(sess, "in") >= 2 then
        local q = C.PickNext(world, sess)
        if q then C.StartExchange(world, sess, q); return end
    end
    sess.idle = sess.idle + dt
    if sess.idle > C.IDLE_END and not waitingManual then C.Dissolve(world, sess, "petered out") end
    if waitingManual and sess.idle > C.JOIN_WALK + 1 then C.Dissolve(world, sess, "never arrived") end
end

local tickIds = {}
function C.Tick(world, dt)
    So.ClockCheck(world, dt)
    if next(C.sessions) then
        local ids, n = sortedInto(C.sessions, tickIds)
        for k = 1, n do
            local sess = C.sessions[ids[k]]
            if sess and sess.lotId == world.lot.id then
                C.TickSession(world, sess, dt)
                if not sess.dead then C.HoldFacing(world, sess) end
            end
        end
    end
    if #deferred > 0 then
        local list = deferred
        deferred = {}
        for _, fn in ipairs(list) do fn() end
    end
    C.RemarksTick(world)
    C.InvitesTick(world)
    if C.alarmPending then C.AlarmTick(world) end
end

---------------------------------------------------------------------------
-- Autonomy: candidate provider (SS.Actions.RegisterCandidates)
---------------------------------------------------------------------------
local function urgency(v) local x = (100 - v) / 100; return x * x end

function C.RelPref(world, a, b, d, pc)
    local x = pc.ab.daily * 0.5 + pc.ab.life
    local pref
    if d.kind == "hostile" then
        pref = U.clamp(0.15 + (-x) / 90, 0, 1.4)
        if mood(a) < -20 then pref = pref * 1.3 end
    elseif d.kind == "romantic" then
        pref = 1
    elseif x < 0 and d.kind ~= "kind" then
        -- few joke or gush with someone they dislike (nice people keep trying); amends stay open
        pref = U.clamp(0.7 + x / 80, 0.05 + P.Get(a, "nice") * 0.04, 0.7)
        if pc.ab.flags.enemy then pref = pref * 0.1 end
    else
        pref = U.clamp(0.7 + x / 150, 0.05, 1.8)
        if pc.ab.flags.enemy then pref = pref * 0.1 end
    end
    if pc.sameHH or pc.fam then pref = pref * 1.1 end
    return pref
end

-- Who starts trouble on their own (0..1, 0 = never): grouchy people; the very neat about a real
-- mess; anyone in a foul mood, less so the nicer they are. Scolding is discipline, gated by the
-- child's actual misbehaviour instead (SPECIAL.scold.pref). Players can still order any of it.
function C.Temper(world, a, d)
    if d.id == "scold" then return 1 end
    local nice = P.Get(a, "nice")
    local t = U.clamp((4 - nice) / 4, 0, 1)
    if d.id == "bicker_chores" then
        t = math.max(t, U.clamp((P.Get(a, "neat") - 6) / 4, 0, 1) * (nice <= 6 and 1 or 0.3))
    end
    if mood(a) < -35 then t = math.max(t, nice <= 4 and 0.3 or nice <= 6 and 0.08 or 0) end
    return t
end

-- Autonomy score for a doing d to b (same scale as object adverts in SS.Actions.Score).
-- pre: the actor-only part (advertised needs x autonomy weight x personality, C.PreScore), when
-- the caller already has it. ex: what autonomy knows before an exchange (room score); optional.
local AUTO_EX = { witnesses = 0 }   -- no topic or audience chosen yet when autonomy weighs an overture

-- Advertised-need value of d for a (no allocation).
local function needScore(a, d, inSession)
    local s = 0
    local adv = d.adv
    if adv then
        for need, amt in pairs(adv) do
            local v = a.needs[need] or 0
            local useful = math.min(amt, 100 - v)
            s = s + useful * urgency(v)
        end
    end
    if inSession then s = s + 8 end
    return s
end

-- The actor-only factor of an autonomy score: advertised needs x autonomy weight x personality
-- affinity (SS.Personality.Modify; social affinity depends on the actor and definition only).
function C.PreScore(world, a, d, inSession)
    local s = needScore(a, d, inSession)
    if s <= 0 then return 0 end
    return P.Modify(world, a, nil, d.iid, s * (d.auto or 0))
end

function C.AutoScore(world, a, b, d, pc, dst, inSession, pre, ex)
    local s = pre or C.PreScore(world, a, d, inSession)
    if s <= 0 then return 0 end
    s = s * C.RelPref(world, a, b, d, pc)
    if d.kind == "hostile" then s = s * C.Temper(world, a, d) end
    if s <= 0 then return 0 end
    local sp = C.SPECIAL[d.id]
    if sp and sp.pref then s = s * sp.pref(world, a, b, pc) end
    local reps = So.Count(world, a.id, b.id, d.id, 180, true)
    if reps > 0 then s = s * (0.5 ^ reps) end
    -- people sense how an overture will land: long shots are tried less often (never ruled out)
    if s > 1 then s = s * (0.3 + 0.7 * C.Chance(world, a, b, d, pc, ex or AUTO_EX) / 100) end
    -- shy people tolerate loneliness longer
    if not inSession and (a.needs.social or 0) > P.Tolerance(a, "social") + 60 then s = s * 0.6 end
    return s / (1 + (dst or 1) * 0.06)
end

-- Upper bound of everything AutoScore multiplies onto the pre-score, per definition: the
-- relationship preference (C.RelPref), the definition's own preference (SPECIAL.pref, bounded by
-- SPECIAL.prefMax; tests sample it) and the success estimate (<= 0.3 + 0.7 * 0.97). Temper,
-- repetition, loneliness and distance only ever shrink a score. This lets the scan stop early
-- without changing which candidates come out on top.
local REL_MAX = { hostile = 1.4 * 1.3 * 1.1, romantic = 1.1 }
function C.BoundMult(d)
    local b = d.boundMult
    if b then return b end
    local sp = C.SPECIAL[d.id]
    local pm = (sp and sp.pref) and (sp.prefMax or 1) or 1
    b = (REL_MAX[d.kind] or 1.8 * 1.1) * pm * 0.98
    d.boundMult = b
    return b
end

C.AUTO_LIST = {}
for _, d in ipairs(S.list) do if d.auto then C.AUTO_LIST[#C.AUTO_LIST + 1] = d end end
C.AUTO_MIN = 12   -- the executor's candidate bar

-- Scratch space for the autonomy scan (reused every call; nothing escapes except the
-- candidates handed to the executor).
local scan = { pre = {}, bound = {}, order = {}, nOrd = 0, near = {}, nearD = {}, pc = {}, ex = { witnesses = 0 },
    top = { n = 0, d = {}, s = {} }, preIn = {}, boundIn = {}, orderIn = {} }
local curBound
local function byBound(x, y)
    local bx, by = curBound[x], curBound[y]
    if bx ~= by then return bx > by end
    return x < y
end

-- Rank the actor-only bound of every autonomous definition (descending). Returns the order
-- array and its length; bound[] and pre[] are indexed like C.AUTO_LIST.
local function rankDefs(world, a, inSession, minScore)
    local list = C.AUTO_LIST
    local pre = inSession and scan.preIn or scan.pre
    local bound = inSession and scan.boundIn or scan.bound
    local order = inSession and scan.orderIn or scan.order
    local n = 0
    for k = 1, #list do
        local d = list[k]
        local ps = C.PreScore(world, a, d, inSession)
        local ub = ps > 0 and ps * C.BoundMult(d) or 0
        pre[k], bound[k] = ps, ub
        if ub > minScore then n = n + 1; order[n] = k end
    end
    for k = #order, n + 1, -1 do order[k] = nil end
    if n > 1 then curBound = bound; table.sort(order, byBound) end
    return order, n, pre, bound
end

-- The K best definitions a could start with b (scores above minScore), best first, ties by
-- definition order. Branch and bound: each candidate definition gets an upper bound for this
-- pair (the actor-only pre-score x the pair's exact relationship preference and temper x the
-- definition's preference ceiling x the best possible success estimate); they are tried best
-- bound first and the search stops once no remaining one could enter the top K. Returns
-- scan.top (reused, read it before the next call).
local KIND_PROBE = { hostile = { kind = "hostile" }, romantic = { kind = "romantic" }, kind = { kind = "kind" }, other = { kind = "neutral" } }
local pairBound, pairOrder = {}, {}
local function byPairBound(x, y)
    local bx, by = pairBound[x], pairBound[y]
    if bx ~= by then return bx > by end
    return x < y
end
function C.TopDefs(world, a, b, pc, dst, inSession, K, minScore, members, ex, order, nOrd, pre, bound)
    if not order then order, nOrd, pre, bound = rankDefs(world, a, inSession, minScore) end
    local top = scan.top
    top.n = 0
    local list = C.AUTO_LIST
    local distF = 1 + (dst or 1) * 0.06
    -- exact relationship preference for each kind of definition with this person
    local relH = C.RelPref(world, a, b, KIND_PROBE.hostile, pc)
    local relR = C.RelPref(world, a, b, KIND_PROBE.romantic, pc)
    local relK = C.RelPref(world, a, b, KIND_PROBE.kind, pc)
    local relO = C.RelPref(world, a, b, KIND_PROBE.other, pc)
    local n = 0
    for k = 1, nOrd do
        local idx = order[k]
        local d = list[idx]
        local kd = d.kind
        local rel = kd == "hostile" and relH or kd == "romantic" and relR or kd == "kind" and relK or relO
        if kd == "hostile" then rel = rel * C.Temper(world, a, d) end
        local sp = C.SPECIAL[d.id]
        local ub = pre[idx] * rel * ((sp and sp.pref) and (sp.prefMax or 1) or 1) * 0.98 / distF
        if ub > minScore then n = n + 1; pairOrder[n] = idx; pairBound[idx] = ub end
    end
    for k = #pairOrder, n + 1, -1 do pairOrder[k] = nil end
    if n > 1 then table.sort(pairOrder, byPairBound) end
    local bs = not inSession and C.SessionOf(b.id) or nil
    local cool = a.cool
    local hasCool = cool and next(cool) ~= nil
    local t = now(world)
    for k = 1, n do
        local idx = pairOrder[k]
        local floor = (top.n >= K) and top.s[K] or minScore
        if pairBound[idx] < floor then break end
        local d = list[idx]
        local fits
        if inSession then fits = not C.NO_IN_SESSION[d.id] and (members <= 2 or d.group)
        else fits = (bs == nil) ~= (d.id == "join_group") end
        if fits and hasCool then
            local ck = cool[b.id .. ":" .. d.iid]
            if ck and ck > t then fits = false end
        end
        if fits and C.CanStart(world, a, b, d, pc, true) then
            local sc = C.AutoScore(world, a, b, d, pc, dst, inSession, pre[idx], ex)
            if sc > minScore and (top.n < K or sc > top.s[K] or (sc == top.s[K] and d.order < top.d[K].order)) then
                -- insert keeping (score desc, definition order asc)
                local pos = math.min(top.n + 1, K)
                top.d[pos], top.s[pos] = d, sc
                if top.n < K then top.n = top.n + 1 end
                while pos > 1 and (top.s[pos] > top.s[pos - 1] or (top.s[pos] == top.s[pos - 1] and top.d[pos].order < top.d[pos - 1].order)) do
                    top.d[pos], top.d[pos - 1] = top.d[pos - 1], top.d[pos]
                    top.s[pos], top.s[pos - 1] = top.s[pos - 1], top.s[pos]
                    pos = pos - 1
                end
            end
        end
    end
    return top
end

function C.CalledAway(world, a)
    local t = a.tmp and a.tmp.calledAway
    if t and t <= now(world) then a.tmp.calledAway = nil; return false end
    return t ~= nil
end
-- Whom free will leaves alone (checked before anything is scored, and cheap: flags, the action,
-- the queue, needs and cooldowns; no text is built): someone visibly busy (asleep or resting, at
-- work, in the bathroom, doing something the player asked for or has queued, an urgent need;
-- C.Busy), someone who brushed `a` off a moment ago (the "talk" cooldown), and someone the player
-- called out of a conversation a moment ago (C.CALLED_AWAY). Someone already in a conversation is
-- not busy: they can be joined. The player can still order any of it; the target then answers in
-- person (C.Engage declines out loud and sets the "busy" cooldown).
function C.Unapproachable(world, a, b)
    if C.Busy(world, b, a, nil, true) then return true end
    if C.CalledAway(world, b) then return true end
    if So.AnyCooldown(world, a.id, b.id) and So.Cooldown(world, a.id, b.id, "talk") then return true end
    return false
end
function C.CanAuto(world, a)
    return human(a) and C.RoleSocial(a) and not C.SessionOf(a.id) and not C.CalledAway(world, a)
end

C.SCAN_PEOPLE, C.SCAN_RANGE = 6, 14
C.SCAN_KEEP, C.SCAN_PER_PERSON = 4, 2   -- candidates handed to the executor: best 4, at most 2 per person
local function byNear(x, y)
    local nd = scan.nearD
    if nd[x] ~= nd[y] then return nd[x] < nd[y] end
    return x.id < y.id
end

-- Autonomy candidates: the best few socials with the six nearest people. Content people cost one
-- pass over the definitions' actor-only bounds and nothing else; otherwise prerequisites and
-- scores run only for the definitions that could still make the cut (C.TopDefs), and people
-- too far away to beat what has been found already are not looked at.
local keepS, keepD, keepB = {}, {}, {}
function C.Candidates(world, actor, cands)
    if not C.CanAuto(world, actor) then return end
    local order, nOrd, pre, bound = rankDefs(world, actor, false, C.AUTO_MIN)
    if nOrd == 0 then return end   -- nothing social could reach the bar with anyone right now
    local near, nearD = scan.near, scan.nearD
    local nn = 0
    local lv = actor.level or 0
    local ids = actorIds(world)
    for k = 1, #ids do
        local b = world.actors[ids[k]]
        if b and b ~= actor and human(b) and (b.level or 0) == lv then
            local dd = math.abs(b.x - actor.x) + math.abs(b.y - actor.y)
            if dd <= C.SCAN_RANGE then nn = nn + 1; near[nn] = b; nearD[b] = dd end
        end
    end
    for k = #near, nn + 1, -1 do near[k] = nil end
    if nn == 0 then return end
    if nn > 1 then table.sort(near, byNear) end
    C.ScanBegin()
    local best = bound[order[1]]
    local ex = scan.ex
    local kn, KEEP = 0, C.SCAN_KEEP
    for n = 1, math.min(C.SCAN_PEOPLE, nn) do
        local b = near[n]
        local dd = nearD[b]
        local floor = (kn >= KEEP) and keepS[KEEP] or C.AUTO_MIN
        if best / (1 + dd * 0.06) < floor then break end   -- nobody farther away can do better
        -- pair-level quick outs (C.Unapproachable): nobody walks over on their own to someone
        -- visibly busy, someone who just brushed them off, or someone the player just called away
        if not C.Unapproachable(world, actor, b) then
            local pc = C.PairInto(world, actor, b, scan.pc)
            ex.roomScore = roomScore(world, b)
            local top = C.TopDefs(world, actor, b, pc, dd, false, C.SCAN_PER_PERSON, floor, nil, ex, order, nOrd, pre, bound)
            for k = 1, top.n do
                local sc, d = top.s[k], top.d[k]
                if kn < KEEP or sc > keepS[KEEP] then
                    local pos = math.min(kn + 1, KEEP)
                    keepS[pos], keepD[pos], keepB[pos] = sc, d, b
                    if kn < KEEP then kn = kn + 1 end
                    while pos > 1 and keepS[pos] > keepS[pos - 1] do
                        keepS[pos], keepS[pos - 1] = keepS[pos - 1], keepS[pos]
                        keepD[pos], keepD[pos - 1] = keepD[pos - 1], keepD[pos]
                        keepB[pos], keepB[pos - 1] = keepB[pos - 1], keepB[pos]
                        pos = pos - 1
                    end
                end
            end
        end
    end
    for k = 1, kn do
        cands[#cands + 1] = { tid = keepB[k].id, iid = keepD[k].iid, s = keepS[k] }
        keepB[k], keepD[k] = nil, nil
    end
    for k = 1, nn do nearD[near[k]] = nil end
    C.ScanEnd()
end
if SS.Actions and SS.Actions.RegisterCandidates then SS.Actions.RegisterCandidates(C.Candidates) end
-- Guests let in by the visitors module socialise through these candidates too (C.CanAuto and
-- C.RoleSocial), so the visitors module's stand-in chat is no longer needed once social is loaded.
C.HANDLES_GUESTS = true

---------------------------------------------------------------------------
-- Remarks: residents comment on what they actually see (rate-limited through SS.Lines)
---------------------------------------------------------------------------
C.REMARK_EVERY = 20
function C.RemarksTick(world)
    local n = now(world)
    if (C.remarkT or -1) > n and C.remarkT - n < C.REMARK_EVERY then return end
    C.remarkT = n + 1
    local ids = actorIds(world)
    if #ids == 0 then return end
    C.remarkIdx = (C.remarkIdx or 0) % #ids + 1
    local a = world.actors[ids[C.remarkIdx]]
    if not a or not human(a) or a.sleeping or C.SessionOf(a.id) or not C.RoleSocial(a) then return end
    a.tmp = a.tmp or {}
    if (a.tmp.nextRemark or 0) > n then return end
    a.tmp.nextRemark = n + C.REMARK_EVERY
    C.Remark(world, a)
end

-- One observation from what is really around the actor. Returns the situation said, if any.
function C.Remark(world, a)
    local W = SS.World
    local lv = a.level or 0
    local room = W.RoomAt(world, lv, math.floor(a.x), math.floor(a.y))
    local neat = P.Get(a, "neat")
    local plate, puddle, pet, broken, chair
    for _, oid in ipairs(sortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        if (o.level or 0) == lv and W.RoomAt(world, lv, o.x, o.y) == room then
            local def = SS.Objects[o.def]
            local k = L.MessKind(o, def)
            if k == "plate" and not plate then plate = o end
            if k == "puddle" and not puddle then puddle = o end
            if k == "pet" and not pet then pet = o end
            if o.state and o.state.broken and not broken then broken = o end
            if def and def.seat and (def.price or 0) >= 900 and not chair then chair = o end
        end
    end
    local tries = {}
    if chair and C.IsVisitor(world, a) then tries[#tries + 1] = { "expensive_chair", { objDef = chair.def } } end
    if broken then tries[#tries + 1] = { "broken_object", { objDef = broken.def } } end
    if puddle then tries[#tries + 1] = { "puddle", { objDef = puddle.def } } end
    if pet then tries[#tries + 1] = { "pet_mess", { objDef = pet.def } } end
    if plate and neat >= 6 then tries[#tries + 1] = { "messy_plate", { objDef = plate.def } } end
    -- the same context household-core's needs warning passes (the lines re-read the real score)
    if neat >= 5 or C.IsVisitor(world, a) then tries[#tries + 1] = { "room_filthy", { roomScore = math.floor(L.RoomScoreAt(world, a)) } } end
    for _, t in ipairs(tries) do
        local text = L.Say(world, a, t[1], t[2])
        if text then
            balloon(world, a, (L.Meta(t[1]).icon) or "react_mess", text, 3, "thought")
            return t[1]
        end
    end
    return nil
end

-- Event reactions from other modules' documented bus events.
SS.On("objectBroken", function(world, o, why)
    if not world or not world.actors or not o then return end
    local W = SS.World
    local room = W.RoomAt(world, o.level or 0, o.x, o.y)
    for _, id in ipairs(actorIds(world)) do
        local a = world.actors[id]
        if human(a) and not a.sleeping and (a.level or 0) == (o.level or 0) and W.RoomAt(world, o.level or 0, math.floor(a.x), math.floor(a.y)) == room then
            local text = L.Say(world, a, "broken_object", { objDef = o.def, oid = o.id })
            if text then balloon(world, a, "react_mess", text, 3) end
            return
        end
    end
end)

SS.On("death", function(world, dead, cause)
    if not world or not world.actors or not dead then return end
    for _, id in ipairs(actorIds(world)) do
        local a = world.actors[id]
        local r = a and So.Get(world, id, dead.id)
        if human(a) and not a.sleeping and r and (r.life >= 20 or r.flags.family or r.flags.partner) then
            local text = L.Say(world, a, "death_grief", { deceased = first(dead), cause = cause })
            if text then balloon(world, a, "react_sad", text, 4); setPose(a, "cry") end
            return
        end
    end
end)

-- A failed bathroom trip because someone else is in there: annoyance line.
SS.On("actionEnded", function(actor, act, status, why)
    local world = SS.Sim and SS.Sim.world
    if not world or not actor or not act or status ~= "failed" or type(why) ~= "string" then return end
    local iid = act.iid or ""
    if (iid == "toilet" or iid == "shower" or iid == "bath" or iid == "washhands" or iid:find("toilet", 1, true)
        or iid:find("shower", 1, true) or iid:find("bath", 1, true)) and why:find("using it", 1, true) then
        local holder = why:match("^(%S+)")
        if holder == "Someone" then holder = nil end
        local o = act.oid and world.lot.objects[act.oid]
        L.Speak(world, actor, "bathroom_queue", { holder = holder, objDef = o and o.def })
    end
end)

-- A smoke alarm going off. The events module rings it (`state.ringing`, then "lotChanged" "state");
-- on social's next tick the awake person nearest the alarm says so (fire_alarm), naming what is
-- burning when events' fire record says what caught. A module that says fire_alarm itself wins:
-- social stays quiet when a fire_alarm line was said since the alarm started. At most one alarm
-- line per ALARM_GAP minutes; nothing is saved (a reload mid-alarm simply says nothing).
C.ALARM_GAP = 30
local function isSmokeAlarm(def)
    if type(def) ~= "table" or type(def.tags) ~= "table" then return false end
    for _, t in ipairs(def.tags) do if t == "smoke_alarm" then return true end end
    return false
end
C.IsSmokeAlarm = isSmokeAlarm
SS.On("lotChanged", function(kind, oid)
    if kind ~= "state" or oid == nil or C.alarmPending then return end
    local world = SS.Sim and SS.Sim.world
    local o = world and world.lot and world.lot.objects and world.lot.objects[oid]
    if not (o and type(o.state) == "table" and o.state.ringing and isSmokeAlarm(SS.Objects[o.def])) then return end
    C.alarmPending, C.alarmSince = oid, now(world)
end)
SS.On("lineSaid", function(world, actor, situation)
    if situation == "fire_alarm" and type(world) == "table" then C.alarmSaidT = now(world) end
end)
-- What is burning: the first target of events' fire record that is still on the lot (guarded).
function C.AlarmObject(world)
    local F = SS.Fire
    if not (F and F.Event) then return nil end
    local ok, e = pcall(F.Event, world)
    local t = ok and type(e) == "table" and e.targets
    local o = type(t) == "table" and t[1] ~= nil and world.lot.objects[t[1]]
    return o and o.def or nil
end
function C.AlarmTick(world)
    local oid, since = C.alarmPending, C.alarmSince
    C.alarmPending, C.alarmSince = nil, nil
    local o = oid and world.lot and world.lot.objects[oid]
    if not o then return nil end
    local n = now(world)
    if (C.alarmSaidT or -1e9) >= since or n - (C.alarmT or -1e9) < C.ALARM_GAP then return nil end
    local best, bd
    local ox, oy, ol = (o.x or 0) + 0.5, (o.y or 0) + 0.5, o.level or 0
    for _, id in ipairs(actorIds(world)) do
        local a = world.actors[id]
        if human(a) and not a.sleeping and C.RoleSocial(a) then
            local d = math.abs((a.level or 0) - ol) * 1000 + (a.x - ox) ^ 2 + (a.y - oy) ^ 2
            if not bd or d < bd then best, bd = a, d end
        end
    end
    if not best then return nil end
    C.alarmT = n
    local text = L.Say(world, best, "fire_alarm", { objDef = C.AlarmObject(world) })
    if text then balloon(world, best, L.Meta("fire_alarm").icon or "react_fire", text, 3) end
    return text, best
end

---------------------------------------------------------------------------
-- Render effects: hearts over romance, steam over arguments (pooled items)
---------------------------------------------------------------------------
local fxPool, fxIds = {}, {}
function C.Effects(world, cam, out)
    local k = 0
    if not next(C.sessions) then return end
    local ids, n = sortedInto(C.sessions, fxIds)
    for i = 1, n do
        local sess = C.sessions[ids[i]]
        local ex = sess.ex
        if ex and sess.lotId == world.lot.id then
            local kind = ex.def.kind
            local effect = (kind == "romantic" and (ex.stage == "open" or ex.ok)) and "hearts"
                or (kind == "hostile" and ex.def.id ~= "scold") and "steam" or nil
            if effect then
                for side = 1, 2 do
                    local p = world.actors[side == 1 and ex.a or ex.b]
                    if p and k < 12 then
                        k = k + 1
                        local it = fxPool[k] or {}
                        fxPool[k] = it
                        it.level, it.x, it.y, it.z, it.effect = p.level or 0, p.x, p.y, 2.1, effect
                        it.frame, it.scale = math.floor(ex.t * 4) % 4, 1
                        out[#out + 1] = it
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- System registration, attach/detach
---------------------------------------------------------------------------
-- Props only a conversation hands out (restored when the exchange ends; sessions are runtime
-- only, so after a load or a reattach nobody can still be holding one).

function C.Reset(world)
    for _, sess in pairs(C.sessions) do
        sess.dead = true
        if sess.ex and world and world.actors then restoreCarry(world, sess.ex) end
    end
    C.sessions, C.byActor, deferred = {}, {}, {}
    C.nextId = 1              -- session ids restart with every attach (deterministic)
    C.epoch = C.epoch + 1     -- orders stamped before this point are stale (C.InitTick, C.ChatTick)
    C.remarkT, C.remarkIdx, C.inviteCheck = nil, nil, nil
    C.alarmPending, C.alarmSince, C.alarmSaidT, C.alarmT = nil, nil, nil, nil
    local root = world and (world.root or world)
    for _, set in ipairs({ root and root.residents or {}, world and world.actors or {} }) do
        for _, r in pairs(set) do
            if type(r) == "table" then
                if r.tmp then r.tmp.conv = nil; r.tmp.fatigue = nil; r.tmp.fatigueT = nil end
                -- a gift, bunch of flowers or book social handed them for an exchange that no longer exists
                C.DropProp(r)
            end
        end
    end
end

-- Public helper for other modules (visitors' greeting, parties, dates): order a social.
-- Returns ok, why. manual=false makes it an autonomous choice (the player's orders pre-empt it).
function C.Start(world, actor, target, defId, manual, data)
    local d = S.byId[defId]
    if not d then return false, "Unknown interaction." end
    local ok, why = C.CanStart(world, actor, target, d)
    if not ok then return false, why end
    actor.queue = actor.queue or {}
    if manual then
        return SS.Actions.Order(world, actor, nil, d.iid, nil, nil, { tid = target.id, data = data or {} })
    end
    table.insert(actor.queue, { tid = target.id, iid = d.iid, manual = false, data = data or {} })
    return true
end

-- Saves: conversations are runtime only. household-core mirrors each person's current action
-- (`doing`) and queue (`orders`) into the save and resumes them on load. The listener's half of a
-- conversation ("social_chat") cannot continue without its session, so it is dropped; a social
-- order keeps only what the player asked for (whom, what, which item), so it starts again from
-- the approach, and an exchange that already played out (`resolved`) is not replayed.
C.RUNTIME_DATA = { "conv", "stage", "epoch", "aborted", "exDone", "ok", "rechase" }
local function socialIid(iid) return type(iid) == "string" and (iid == "social_chat" or iid:sub(1, 4) == "soc_") end
local function scrubData(data)
    if type(data) ~= "table" then return end
    for k = 1, #C.RUNTIME_DATA do data[C.RUNTIME_DATA[k]] = nil end
end
function C.ScrubSaved(r)
    local n = 0
    if type(r.doing) == "table" and socialIid(r.doing.iid) then
        if r.doing.iid == "social_chat" then r.doing = nil else scrubData(r.doing.data); r.doing.performed = nil end
        n = n + 1
    end
    for _, key in ipairs({ "orders", "queue" }) do
        local q = r[key]
        if type(q) == "table" then
            for i = #q, 1, -1 do
                local o = q[i]
                if type(o) == "table" and socialIid(o.iid) then
                    if o.iid == "social_chat" then table.remove(q, i) else scrubData(o.data) end
                    n = n + 1
                end
            end
        end
    end
    if type(r.tmp) == "table" then r.tmp.conv = nil end
    -- a gift, flowers or a book social held up for an exchange: the resumed order takes it out again
    if C.DropProp(r) then n = n + 1 end
    return n
end
if SS.Save and SS.Save.RegisterValidator then
    -- runs on the snapshot when saving and again on load (older saves); an expected clean-up,
    -- so nothing is reported to the player
    SS.Save.RegisterValidator(function(root, problems)
        local n = 0
        for _, r in pairs(root.residents or {}) do if type(r) == "table" then n = n + C.ScrubSaved(r) end end
        C.lastScrub = n
    end)
end

if SS.Sim and SS.Sim.Register then
    SS.Sim.Register {
        name = "social", order = 40,
        tick = function(world, dt) C.Tick(world, dt) end,
        day = function(world) So.MeetHousehold(world); So.DayTick(world) end,
        attach = function(world)
            So.ClockCheck(world)
            C.Reset(world)
            So.RefreshHousehold(world)
            So.MeetHousehold(world)
            C.SettleKeepsakes(world)
            if SS.Render and SS.Render.RegisterEffects and not C.fxRegistered then
                SS.Render.RegisterEffects(C.Effects)
                C.fxRegistered = true
            end
        end,
        detach = function(world) C.Reset(world) end,
    }
end
