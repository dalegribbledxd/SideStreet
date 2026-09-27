-- SideStreet parties: phone invitations with a capped guest list drawn from known residents by
-- relationship, acceptance rolls, arrival windows through the visitors framework (role "guest",
-- autonomy on), music (stereo/radio on, party audio mode), food (a party platter system object),
-- activities (mingling, dancing together, a toast), guest needs, an emergent score from sampled
-- conditions, early leavers (miserable, starving, exhausted, and the guest who just wants to go
-- home), memorable outcomes with lines, relationship consequences, a journal entry, departure and
-- the mess left behind. Owner: family module. Tuning: SS.FamilyData.party.
--
-- Saved: root.parties = { nextId, active = rec | nil, history = { summary... }, lastEnd }.
-- rec = { id, hh, lotId, host, state = "planned"|"running"|"ended", createdAt, startAt, endAt, food,
--   charged, platter (oid), guests = { [rid] = g }, order = { rid... }, stats = {...}, spots = {...},
--   score, parts, outcome }.   g = { rid, accepted, reason, arriveAt, coming (walking in from the street,
--   not yet let in), arrived, left, leftWhy, samples, moodSum, musicSamples, socials, ate, miserable,
--   pendingLeave / leaveWaits (decided to go, finishing an ordered action first), joinTries /
--   joinRetryAt (the walk in from the door was blocked), sat, movedIn }. leftWhy: "over" (stayed to
--   the end), an early reason (miserable, hungry, exhausted, homebody, left), "noshow", or "moved_in"
--   (moved in with the hosts: family now, not a guest).
local _, SS = ...
local U = SS.U
local W = SS.World
local F = SS.Family
local FD = SS.FamilyData
local PD = FD.party
local Pa = {}
SS.Parties = Pa

function Pa.Root(world)
    local root = F.Root(world)
    local s = root.parties
    if type(s) ~= "table" then s = {}; root.parties = s end
    s.nextId = s.nextId or 1
    s.history = s.history or {}
    return s
end

function Pa.Active(world)
    local rec = Pa.Root(world).active
    if rec and rec.state ~= "ended" then return rec end
end

function Pa.Running(world)
    local rec = Pa.Active(world)
    if rec and rec.state == "running" and world.lot and rec.lotId == world.lot.id then return rec end
end

-- The guest entry of someone at the running party (a member of the hosting household is never a
-- guest, even one who came as a guest and moved in).
local function guestOf(world, a)
    local rec = Pa.Running(world)
    if not rec or not a or a.householdId == rec.hh then return nil end
    local g = rec.guests[a.id]
    if g and g.arrived and not g.left and world.actors[a.id] then return g, rec end
end
Pa.GuestOf = guestOf

-- A guest who moves in with the hosts (mid-party, or before a planned one starts) is family now:
-- the guest entry closes as "moved_in". That is not an early departure: no penalty, no satisfaction
-- score, no relationship consequence from the party, and they are not sent home at the end.
function Pa.GuestMovedIn(world, rec, rid)
    local g = rec and rec.guests[rid]
    if not g or g.left then return false end
    g.left, g.leftWhy, g.movedIn = F.Root(world).time, "moved_in", true
    g.coming, g.pendingLeave, g.leaveWaits, g.sat = nil, nil, nil, nil
    return true
end
SS.On("householdChanged", function(world, rid, fromId, toId)
    if type(world) ~= "table" or not rid then return end
    local rec = Pa.Active(world)
    if rec and toId == rec.hh then Pa.GuestMovedIn(world, rec, rid) end
end)

---------------------------------------------------------------------------
-- The guest list
---------------------------------------------------------------------------
-- Everyone who could be invited, best relationship first: { rid, name, life, daily, known }.
function Pa.Candidates(world, hh)
    local root = F.Root(world)
    hh = F.Household(world, hh)
    local members = F.Members(world, hh, F.IsHuman)
    local ids = {}
    for rid in pairs(root.residents) do ids[#ids + 1] = rid end
    table.sort(ids)
    local out = {}
    for _, rid in ipairs(ids) do
        local r = root.residents[rid]
        local other = r and r.householdId and root.households[r.householdId]
        local ok = r and F.Alive(r) and F.IsAdult(r) and not F.IsNpc(r) and r.householdId ~= hh.id
            and not F.IsServiceHousehold(r.householdId) and not (other and other.flags and other.flags.ended)
            and not (r.away and r.away.reason and r.away.reason ~= "home")
            and not (r.role and r.role ~= "guest" and world.actors[rid])
        if ok then
            local life, daily = -100, -100
            for _, m in ipairs(members) do
                local a, b = F.PeekRel(world, m.id, rid), F.PeekRel(world, rid, m.id)
                life = math.max(life, a.life, b.life)
                daily = math.max(daily, a.daily, b.daily)
            end
            if #members == 0 then life, daily = 0, 0 end
            out[#out + 1] = { rid = rid, name = r.name, life = life, daily = daily, known = life >= PD.acceptLife }
        end
    end
    table.sort(out, function(a, b)
        if a.life ~= b.life then return a.life > b.life end
        if a.daily ~= b.daily then return a.daily > b.daily end
        return a.rid < b.rid
    end)
    return out
end

-- Default list: known people first, strangers (neighbours) only when too few are known.
function Pa.DefaultGuests(world, hh, max)
    max = math.min(max or PD.maxGuests, PD.maxGuests)
    local out, known = {}, 0
    local cands = Pa.Candidates(world, hh)
    for _, c in ipairs(cands) do
        if c.known and #out < max then out[#out + 1] = c.rid; known = known + 1 end
    end
    if known < PD.strangersFill then
        for _, c in ipairs(cands) do
            if not c.known and #out < math.min(max, PD.strangersFill + known) then out[#out + 1] = c.rid end
        end
    end
    return out
end

function Pa.AcceptChance(world, rid, hh, startAt)
    local root = F.Root(world)
    local r = root.residents[rid]
    local life = -100
    for _, m in ipairs(F.Members(world, hh, F.IsHuman)) do life = math.max(life, F.PeekRel(world, rid, m.id).life, F.PeekRel(world, m.id, rid).life) end
    if life == -100 then life = 0 end
    local out = (r.personality and r.personality.outgoing) or 5
    local p = PD.acceptBase + PD.acceptPerLife * life + PD.acceptOutgoing * (out - 5)
    local h = ((startAt or root.time) % 1440) / 60
    if h >= 23 or h < 5 then p = p - 0.2 end
    return U.clamp(p, 0.05, 0.95), life
end

---------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------
function Pa.PlanCheck(world, host)
    if not host or not F.IsAdult(host) then return false, "Only an adult can throw a party." end
    local hh = world.household
    if not hh or host.householdId ~= hh.id then return false, "Only a member of this household can throw a party here." end
    if not hh.lotId or world.lot.id ~= hh.lotId then return false, "Parties are thrown at home." end
    if Pa.Active(world) then return false, "A party is already planned or under way." end
    local s = Pa.Root(world)
    if s.lastEnd and F.Root(world).time - s.lastEnd < PD.cooldown then
        return false, "The neighbours are still recovering from the last party. Try again later."
    end
    if #Pa.Candidates(world, hh) == 0 then return false, "There's nobody to invite yet." end
    return true
end

local function endTimeFor(startAt)
    local dayStart = math.floor(startAt / 1440) * 1440
    local late = dayStart + PD.lateHour * 60
    if late <= startAt then late = late + 1440 end
    return math.min(startAt + PD.duration, late)
end

-- opts = { start = minutes from now (one of PD.startOptions), food = "platter"|"none", guests = { rid... } }
function Pa.Plan(world, host, opts)
    opts = opts or {}
    local ok, why = Pa.PlanCheck(world, host)
    if not ok then return false, why end
    local hh = world.household
    local food = opts.food or "platter"
    if food ~= "platter" and food ~= "meal" and food ~= "none" then return false, "Choose a platter, a group meal or no food." end
    if food == "meal" and not (SS.Chains and SS.Chains.GroupMeal) then
        return false, "A cooked group meal isn't available yet; order a platter or go without."
    end
    if food == "platter" and (world.money or 0) < PD.platter.cost then
        return false, "A party platter costs " .. U.fmtMoney(PD.platter.cost) .. "; the household can't afford it. Choose no food or save up."
    end
    local root = F.Root(world)
    local startIn = opts.start or PD.startOptions[1]
    local list = opts.guests or Pa.DefaultGuests(world, hh)
    if #list == 0 then return false, "Pick at least one guest." end
    if #list > PD.maxGuests then return false, "The guest list is capped at " .. PD.maxGuests .. " people." end
    local valid = {}
    for _, c in ipairs(Pa.Candidates(world, hh)) do valid[c.rid] = true end
    local s = Pa.Root(world)
    local rec = { id = "party" .. s.nextId, hh = hh.id, lotId = world.lot.id, host = host.id, state = "planned",
        createdAt = root.time, startAt = root.time + startIn, food = food, guests = {}, order = {},
        stats = { samples = 0, moodSum = 0, needsSum = 0, roomSum = 0, musicSamples = 0, socials = 0, food = 0,
            activities = 0, guestMinutes = 0, arrived = 0, earlyLeaves = 0, leavePenalty = 0 }, spots = {} }
    s.nextId = s.nextId + 1
    rec.endAt = endTimeFor(rec.startAt)
    local coming, declined = {}, {}
    local seen = {}
    for _, rid in ipairs(list) do
        if valid[rid] and not seen[rid] then
            seen[rid] = true
            local p, life = Pa.AcceptChance(world, rid, hh, rec.startAt)
            local roll = SS.Random(world, "party")
            local g = { rid = rid, accepted = roll < p, life = life, samples = 0, moodSum = 0, musicSamples = 0, socials = 0, ate = 0, miserable = 0 }
            if g.accepted then
                g.arriveAt = rec.startAt + SS.RandomInt(world, "party", PD.arrivalWindow[1], PD.arrivalWindow[2])
                coming[#coming + 1] = rid
            else
                g.reason = life < PD.acceptLife and "doesn't know the household well enough" or "has other plans"
                declined[#declined + 1] = rid
            end
            rec.guests[rid] = g
            rec.order[#rec.order + 1] = rid
        end
    end
    if #coming < PD.minGuests then
        local names = {}
        for _, rid in ipairs(declined) do names[#names + 1] = root.residents[rid].name end
        local text = "Nobody can come to the party" .. (#names > 0 and (" (" .. table.concat(names, ", ") .. " declined)") or "") .. ". Get to know people first."
        F.Journal(world, text)
        return false, text
    end
    s.active = rec
    SS.Sim.Schedule(world, rec.startAt, "party.start", { id = rec.id }, rec.lotId)
    for _, rid in ipairs(coming) do
        SS.Sim.Schedule(world, rec.guests[rid].arriveAt, "party.arrive", { id = rec.id, rid = rid }, rec.lotId)
    end
    local when = SS.Sim.ClockText(rec.startAt):match("%d+:%d+ %a+") or ""
    local text = host.name .. " is throwing a party" .. (startIn > 0 and (" at " .. when) or " now") .. ": "
        .. #coming .. " of " .. (#coming + #declined) .. " invited guests are coming."
    F.Journal(world, text)
    SS.Emit("partyPlanned", world, rec)
    if startIn <= 0 then Pa.Start(world, rec) end
    return true, text, rec
end

function Pa.Cancel(world, why)
    local rec = Pa.Active(world)
    if not rec then return false, "No party is planned." end
    if rec.state == "running" then return Pa.End(world, rec, why or "host") end
    rec.state = "ended"
    rec.outcome = "cancelled"
    SS.Sim.Unschedule(world, function(ev) return (ev.kind == "party.start" or ev.kind == "party.arrive") and ev.data and ev.data.id == rec.id end)
    Pa.Root(world).active = nil
    F.Journal(world, "The party was called off.")
    SS.Emit("partyEnded", world, rec)
    return true
end

---------------------------------------------------------------------------
-- Music and food
---------------------------------------------------------------------------
-- Music sources on the lot (stereo, radio, DJ booth), sorted by id. The list is shared and read
-- only: it is built from family's tag index and kept until that index is rebuilt (the object set
-- changed), so asking for it every step allocates nothing (ARCH §4).
local MUSIC_TAGS = { "stereo", "radio", "dj", "dj_booth" }
local musicCache = { gen = -1 }
function Pa.MusicSources(world)
    local gen = F.TagIndexGen(world)
    local c = musicCache
    if c.list and c.gen == gen and c.lot == world.lot then return c.list end
    local out, seen = {}, {}
    for _, tag in ipairs(MUSIC_TAGS) do
        for _, o in ipairs(F.ObjectsWithTag(world, tag)) do
            if not seen[o] then seen[o] = true; out[#out + 1] = o end
        end
    end
    table.sort(out, F.ById)
    c.list, c.gen, c.lot = out, gen, world.lot
    return out
end

-- Is music playing within earshot of `a` (a source switched on, same floor, within the radius)?
-- The on/off state is read live from the objects, so a stereo switched off is heard at once.
function Pa.MusicAt(world, a, sources)
    local list = sources or Pa.MusicSources(world)
    local lv, r = a.level or 0, PD.musicRadius
    for n = 1, #list do
        local o = list[n]
        if o.state and o.state.on and (o.level or 0) == lv and world.lot.objects[o.id] == o then
            if math.abs(o.x + 0.5 - a.x) + math.abs(o.y + 0.5 - a.y) <= r then return true end
        end
    end
    return false
end

-- Does this guest hear the music this step? Worked out once per guest per sim step (Pa.Tick does it
-- for everyone at the party; the rate hook and the samplers read the flag) and kept in actor.tmp,
-- which is runtime-only.
function Pa.HearsMusic(world, a)
    local t = a.tmp
    if t and t.partyMusicAt == world.time then return t.partyMusic end
    if not t then t = {}; a.tmp = t end
    local on = Pa.MusicAt(world, a)
    t.partyMusic, t.partyMusicAt = on, world.time
    return on
end

-- The party's music: the first playing source, else the first one switched on. It is marked
-- `keepOn = "party"` so household-core doesn't switch it off when the last listener walks away;
-- the mark is removed when the party ends (or when someone switches the music off by hand).
local function musicOn(world, rec)
    local srcs = Pa.MusicSources(world)
    if not srcs[1] then return false end
    local pick
    for _, o in ipairs(srcs) do
        if o.state and o.state.on and not o.state.broken then pick = o; break end
    end
    if not pick then
        for _, o in ipairs(srcs) do
            if not (o.state and o.state.broken) then pick = o; break end
        end
        if not pick then return false end
        pick.state = pick.state or {}
        pick.state.on = true
        if rec then rec.musicSwitched = true end
        SS.Emit("lotChanged", "state", pick.id)
    end
    if rec then
        rec.musicObj = pick.id
        if not pick.keepOn then pick.keepOn = "party" end
    end
    return true
end

-- Keep the music going while the party runs (a source switched off by the executor when its last
-- listener left comes back on; a broken or removed one is replaced) unless a member turned it off.
local function keepMusic(world, rec)
    if not rec.music or rec.musicStopped then return end
    local o = rec.musicObj and world.lot.objects[rec.musicObj]
    if o and not (o.state and o.state.broken) then
        if not (o.state and o.state.on) then
            o.state = o.state or {}
            o.state.on = true
            SS.Emit("lotChanged", "state", o.id)
        end
        if not o.keepOn then o.keepOn = "party" end
        return
    end
    rec.music = musicOn(world, rec)
end

local function releaseMusic(world, rec)
    local o = rec.musicObj and world.lot.objects[rec.musicObj]
    if not o then return end
    if o.keepOn == "party" then o.keepOn = nil end
    if rec.musicSwitched and o.state and o.state.on and not (o.watchers and next(o.watchers)) then
        o.state.on = false
        SS.Emit("lotChanged", "state", o.id)
    end
end
Pa.KeepMusic, Pa.ReleaseMusic = keepMusic, releaseMusic

local function platterCell(world, host)
    local ref = host or world.actors[next(world.actors) or ""]
    local lv = ref and ref.level or 0
    local i, j = ref and math.floor(ref.x) or 0, ref and math.floor(ref.y) or 0
    local ci, cj = F.FreeCellNear(world, lv, i, j, 8, { indoor = true, open = true, notDoor = true, minR = 1 })
    if not ci then
        local _, _, ii, ij = F.FrontDoor(world)
        if ii then ci, cj = F.FreeCellNear(world, 0, ii, ij, 8, { indoor = true, notDoor = true, minR = 1 }); lv = 0 end
    end
    if not ci then ci, cj = F.FreeCellNear(world, lv, i, j, 10, { minR = 1 }) end
    return ci, cj, lv
end

---------------------------------------------------------------------------
-- Start, arrivals, sampling, leaving, end
---------------------------------------------------------------------------
local function setAudio(world, mode)
    if SS.Sim.world == world and world.settings and world.settings.music and SS.Audio and SS.Audio.SetMode then
        SS.Audio.SetMode(mode)
    end
end

function Pa.Start(world, rec)
    rec = rec or Pa.Active(world)
    if not rec or rec.state ~= "planned" then return false end
    local root = F.Root(world)
    local host = world.actors[rec.host]
    rec.state = "running"
    rec.startedAt = root.time
    -- the commit point for the food money: once, recorded on the party
    if rec.food == "platter" and not rec.charged then
        if (world.money or 0) >= PD.platter.cost then
            SS.Money(world, -PD.platter.cost, "family", "Party platter")
            rec.charged = PD.platter.cost
            local i, j, lv = platterCell(world, host)
            if i then
                local o = F.AddObject(world, "party_platter", i, j, lv, 0, { servings = PD.platter.servings, heaped = true, party = rec.id })
                rec.platter = o.id
            end
        else
            rec.food = "none"
            F.Journal(world, "The party platter was cancelled: not enough money.")
        end
    elseif rec.food == "meal" then
        -- household-core's cooking chain: the host cooks one big pot, groceries paid at the fridge
        local ok, why
        if SS.Chains and SS.Chains.GroupMeal and host then ok, why = SS.Chains.GroupMeal(world, host, { party = rec.id })
        else ok, why = false, host and "Nobody can cook a group meal here." or "The host isn't home to cook." end
        if not ok then
            rec.food = "none"
            F.Journal(world, "The party meal was called off: " .. tostring(why or "it couldn't be cooked."))
        end
    end
    rec.music = musicOn(world, rec)
    setAudio(world, "party")
    local text = "The party has started!" .. (rec.music and "" or " (There's no stereo or radio for music.)")
    if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "info") end
    F.Journal(world, text)
    SS.Emit("partyStarted", world, rec)
    return true
end

-- Offscreen townies aren't simulated, so a guest arrives with plausible needs for the hour:
-- seeded ranges, hungrier around dinner, tired late at night.
local NEED_ORDER = { "hunger", "energy", "bladder", "hygiene", "fun", "social", "comfort" }
local function arrivalNeeds(world, a)
    local m = F.Root(world).time % 1440
    local S = PD.arrivalShift
    for _, k in ipairs(NEED_ORDER) do
        local range = PD.arrivalNeeds[k]
        local v = SS.RandomInt(world, "party", range[1], range[2])
        if k == "hunger" and m >= S.dinnerFrom and m < S.dinnerTo then v = v + S.dinnerHunger end
        if k == "energy" and (m >= S.lateFrom or m < S.lateTo) then v = v + S.lateEnergy end
        a.needs[k] = U.clamp(v, -100, 100)
    end
end

-- Where the party is: the platter, else a playing stereo/radio, else the host. Returns i, j, level.
function Pa.Hub(world, rec)
    local p = rec.platter and world.lot.objects[rec.platter]
    if p then return p.x, p.y, p.level or 0 end
    for _, o in ipairs(Pa.MusicSources(world)) do
        if o.state and o.state.on then return o.x, o.y, o.level or 0 end
    end
    local host = world.actors[rec.host]
    if host then return math.floor(host.x), math.floor(host.y), host.level or 0 end
end

-- Is a guest who was spawned by the visitors framework through the door yet? The framework walks a
-- guest in from the street, rings and (invited, walkIn) lets them in; until then they are "coming".
-- Without the framework's visit state (the stub) a spawned guest is inside at once.
function Pa.Inside(a)
    local vs = a and type(a.roleData) == "table" and a.roleData.vs
    if type(vs) ~= "table" then return a ~= nil end
    return vs.invitedIn == true
end

-- Come in and join the party (the platter, the music or the host) instead of lingering at the
-- door. Returns true when a walk was queued.
local function joinHub(world, rec, a)
    local hi, hj, hl = Pa.Hub(world, rec)
    if not hi then return false end
    local ci, cj = F.FreeCellNear(world, hl, hi, hj, 4, { minR = 1, notDoor = true })
    if not ci then return false end
    a.queue = a.queue or {}
    table.insert(a.queue, 1, { iid = "goto", x = ci, y = cj, level = hl, manual = false, data = { noEngage = true, arriving = true } })
    return true
end

-- A guest whose walk in was blocked (people standing in the doorway) tries again a few times.
local function retryJoin(world, rec, now)
    for _, rid in ipairs(rec.order) do
        local g = rec.guests[rid]
        local a = g.joinRetryAt and g.arrived and not g.left and world.actors[rid]
        if a and now >= g.joinRetryAt then
            g.joinRetryAt = nil
            local hi, hj, hl = Pa.Hub(world, rec)
            local far = hi and ((a.level or 0) ~= hl or math.abs(a.x - hi - 0.5) + math.abs(a.y - hj - 0.5) > PD.joinNear)
            if far and not (a.act and a.act.manual) then
                g.joinTries = (g.joinTries or 0) + 1
                joinHub(world, rec, a)
            end
        end
    end
end

-- The guest is at the party: counted, greeted, heading for the platter / music / host.
local function completeArrival(world, rec, g, a)
    local root = F.Root(world)
    a.role = a.role or "guest"
    a.roleData = a.roleData or {}
    a.roleData.party, a.roleData.invited = rec.id, true
    a.noNeeds = nil
    g.coming = nil
    g.arrived = root.time
    rec.stats.arrived = rec.stats.arrived + 1
    local host = world.actors[rec.host]
    joinHub(world, rec, a)
    F.Say(world, a, "greet", { party = true, host = rec.host })
    if host then F.Change(world, a.id, host.id, 2, 0) end
    SS.Emit("partyGuestArrived", world, rec, a)
end

function Pa.Arrive(world, rec, rid)
    local g = rec.guests[rid]
    if not g or g.arrived or g.left or g.coming or not g.accepted then return end
    if rec.state == "planned" and rec.startAt <= F.Root(world).time then Pa.Start(world, rec) end
    if rec.state ~= "running" then return end
    local root = F.Root(world)
    local r = root.residents[rid]
    if not r or r.dead or (r.away and r.away.reason and r.away.reason ~= "home") or F.IsServiceHousehold(r.householdId) then
        g.left, g.leftWhy, g.noShow = root.time, "noshow", true
        return
    end
    local a = world.actors[rid]
    if a and a.role and a.role ~= "guest" then g.left, g.leftWhy, g.noShow = root.time, "noshow", true; return end
    if not a then
        -- walkIn: an invited party guest lets themselves in a few minutes after ringing
        local why
        if SS.Visitors and SS.Visitors.Spawn then
            a, why = SS.Visitors.Spawn(world, rid, "guest", { party = rec.id, invited = true, host = rec.host, walkIn = true, autoEnter = true,
                stayUntil = rec.endAt + PD.stayMargin })
        end
        if not a then g.left, g.leftWhy, g.noShow, g.noShowWhy = root.time, "noshow", true, why; return end
        arrivalNeeds(world, a)
    end
    if Pa.Inside(a) then return completeArrival(world, rec, g, a) end
    a.roleData = a.roleData or {}
    a.roleData.party, a.roleData.invited = rec.id, true
    a.noNeeds = nil
    g.coming = root.time
end

-- A coming guest let in by the visitors framework (or who let themselves in) joins the party.
SS.On("visitorLetIn", function(world, v)
    if not world or type(v) ~= "table" then return end
    local rec = Pa.Running(world)
    local g = rec and rec.guests[v.id]
    if g and g.coming and not g.arrived and not g.left and world.actors[v.id] == v then completeArrival(world, rec, g, v) end
end)

-- The visitors framework sends a guest home on its own rules (worn out, starving, unhappy, a fire,
-- nobody home): at a party that is the party's early departure, with its reason and line.
local VISIT_WHY = { emergency = "over", nobody = "over", time = "over" }
local function visitorWhy(rec, a, why, now)
    if VISIT_WHY[why] then return (why ~= "time" or now >= rec.endAt - 1) and VISIT_WHY[why] or "left" end
    if why == "needs" or why == "night" then
        local n = a.needs or {}
        local e, h = n.energy or 0, n.hunger or 0
        if why == "night" or (e < 0 and e <= h) then return "exhausted" end
        if h < 0 then return "hungry" end
        return "miserable"
    end
    return "left"
end
SS.On("visitorLeaving", function(world, a, why)
    if not world or type(a) ~= "table" then return end
    local rec = Pa.Running(world)
    local g = rec and rec.guests[a.id]
    if not g or not g.arrived or g.left then return end
    if why == "party_left" or why == "party_over" then return end
    Pa.GuestLeaves(world, rec, a, visitorWhy(rec, a, why, F.Root(world).time))
end)

-- Coming guests: in (joined), or gone before they got in (sent away at the door, the street blocked:
-- a no-show, never an early leaver). Called every party tick; bounded by the guest cap.
local function checkComing(world, rec, now)
    for _, rid in ipairs(rec.order) do
        local g = rec.guests[rid]
        if g.coming and not g.arrived and not g.left then
            local a = world.actors[rid]
            local vs = a and type(a.roleData) == "table" and a.roleData.vs
            if not a or a.role ~= "guest" then
                g.coming, g.left, g.leftWhy, g.noShow = nil, now, "noshow", true
            elseif Pa.Inside(a) and not (type(vs) == "table" and vs.state == "leaving") then
                completeArrival(world, rec, g, a)
            end
        end
    end
end

function Pa.Satisfaction(world, rec, g)
    local mood = g.samples > 0 and g.moodSum / g.samples or 30
    local hours = math.max(0.25, ((g.left or F.Root(world).time) - (g.arrived or F.Root(world).time)) / 60)
    local social = math.min(1, g.socials / math.max(1, hours * PD.socialsPerGuestHour)) * 100
    local food = math.min(1, g.ate) * 100
    local music = g.samples > 0 and g.musicSamples / g.samples * 100 or 0
    return U.clamp(0.5 * mood + 0.2 * social + 0.15 * food + 0.15 * music, 0, 100)
end

local function relConsequence(world, rec, g, sat)
    local d = sat - 50
    local hh = F.Root(world).households[rec.hh]
    for _, m in ipairs(F.Members(world, hh, F.IsAdult)) do
        local w = (m.id == rec.host) and 1 or 0.5
        F.Change(world, g.rid, m.id, d * PD.rel.dailyPerPoint * w, d * PD.rel.lifePerPoint * w)
        F.Change(world, m.id, g.rid, d * PD.rel.dailyPerPoint * w * 0.5, d * PD.rel.lifePerPoint * w * 0.5)
    end
end

local LEAVE_TEXT = {
    miserable = "wasn't enjoying it", hungry = "went to find something to eat", exhausted = "was too tired to stay",
    homebody = "just wanted to go home", left = "went home early",
}

function Pa.GuestLeaves(world, rec, a, why)
    local g = rec.guests[a.id]
    if not g or g.left then return end
    local root = F.Root(world)
    g.left, g.leftWhy = root.time, why
    local early = why ~= "over"
    if early then
        rec.stats.earlyLeaves = rec.stats.earlyLeaves + 1
        rec.stats.leavePenalty = rec.stats.leavePenalty + (PD.leaveWeight[why] or 1)
    end
    g.sat = Pa.Satisfaction(world, rec, g)
    if early then g.sat = g.sat - 10 end
    relConsequence(world, rec, g, g.sat)
    if early then
        local host = world.actors[rec.host]
        local fallback = why == "homebody" and "Time for me to head home." or "I'm going to head out."
        F.Say(world, a, "party_leave_bad", { reason = why, homebody = why == "homebody", host = rec.host, sat = g.sat }, fallback)
        local text = a.name .. " left the party early: " .. (LEAVE_TEXT[why] or "went home") .. "."
        if host then SS.Actions.Message(world, host, text, "social") else SS.Emit("notice", nil, text) end
        SS.Emit("partyGuestLeft", world, rec, a, why)
    end
    if world.actors[a.id] and a.role == "guest" then
        if SS.Visitors and SS.Visitors.Leave then SS.Visitors.Leave(world, a, early and "party_left" or "party_over")
        else SS.Sim.RemoveActor(world, a.id, { reason = "home" }) end
    end
end

local SAMPLE_NEEDS = { "hunger", "energy", "bladder", "hygiene", "comfort" }

function Pa.Sample(world, rec)
    local st = rec.stats
    if rec.state == "running" then keepMusic(world, rec) end
    local foodLeft = rec.platter and world.lot.objects[rec.platter] and (world.lot.objects[rec.platter].state.servings or 0) > 0
    local now = F.Root(world).time
    for _, rid in ipairs(rec.order) do
        local g = rec.guests[rid]
        local a = g.arrived and not g.left and world.actors[rid]
        if a then
            -- enjoyment: how much fun and company the guest is having right now (0..100)
            local mood = U.clamp(((a.needs.fun or 0) + (a.needs.social or 0)) / 2, 0, 100)
            local ok = 0
            for _, k in ipairs(SAMPLE_NEEDS) do if (a.needs[k] or 0) > 0 then ok = ok + 1 end end
            local lv = a.level or 0
            local room = (SS.Needs.RoomScoreCached(world, lv, W.RoomAt(world, lv, math.floor(a.x), math.floor(a.y))) + 100) / 2
            local music = Pa.HearsMusic(world, a)
            g.samples, g.moodSum = g.samples + 1, g.moodSum + mood
            if music then g.musicSamples = g.musicSamples + 1; st.musicSamples = st.musicSamples + 1 end
            st.samples = st.samples + 1
            st.moodSum = st.moodSum + mood
            st.needsSum = st.needsSum + ok / #SAMPLE_NEEDS
            st.roomSum = st.roomSum + room
            -- where the fun happened: the rubbish ends up around here
            local si = #rec.spots < PD.spotsCap and #rec.spots + 1 or (st.samples % PD.spotsCap) + 1
            local spot = rec.spots[si]
            if not spot then spot = {}; rec.spots[si] = spot end
            spot[1], spot[2], spot[3] = math.floor(a.x), math.floor(a.y), lv
            -- should this guest go home early?
            local rawMood = SS.Needs.Mood(a)
            if rawMood < PD.miserableMood then g.miserable = g.miserable + 1 else g.miserable = 0 end
            local present = now - g.arrived
            local out = (a.personality and a.personality.outgoing) or 5
            local why
            if g.miserable >= PD.miserableSamples then why = "miserable"
            elseif (a.needs.energy or 0) < PD.exhaustedEnergy then why = "exhausted"
            elseif (a.needs.hunger or 0) < PD.hungryLeave and not foodLeft then why = "hungry"
            elseif out <= PD.homebodyOutgoing and present >= PD.homebodyAfter and (a.needs.fun or 0) < PD.homebodyFun then
                -- a shy guest who is still bored gets likelier to slip away the longer it goes on
                if SS.Random(world, "party") < PD.homebodyChance then why = "homebody" end
            end
            -- a guest in the middle of something they were asked to do finishes it first (a sample or
            -- two), then goes: the decision is kept, never lost
            why = why or g.pendingLeave
            if why then
                if a.act and a.act.manual and (g.leaveWaits or 0) < PD.leaveWaitSamples then
                    g.pendingLeave, g.leaveWaits = why, (g.leaveWaits or 0) + 1
                else
                    g.pendingLeave, g.leaveWaits = nil, nil
                    Pa.GuestLeaves(world, rec, a, why)
                end
            end
        end
    end
    Pa.Score(world, rec)
end

-- The score (0..100) emerges from what actually happened: enjoyment, conversations per guest-hour,
-- food eaten per guest, music heard, the rooms, guests' basic needs, minus early departures.
function Pa.Score(world, rec)
    local st = rec.stats
    if st.samples == 0 then rec.score, rec.parts = 0, { fun = 0, social = 0, food = 0, music = 0, room = 0, needs = 0 }; return 0 end
    local guestHours = math.max(0.25, st.guestMinutes / 60)
    local parts = {
        fun = st.moodSum / st.samples,
        needs = st.needsSum / st.samples * 100,
        room = st.roomSum / st.samples,
        music = st.musicSamples / st.samples * 100,
        social = math.min(1, st.socials / math.max(1, guestHours * PD.socialsPerGuestHour)) * 100,
        food = math.min(1, st.food / math.max(1, 0.75 * st.arrived)) * 100,
    }
    local raw = 0
    for k, w in pairs(PD.weights) do raw = raw + w * parts[k] end
    local penalty = math.min(PD.earlyLeaveCap, st.leavePenalty * PD.earlyLeavePenalty)
    parts.penalty = penalty
    rec.parts = parts
    rec.score = U.clamp(math.floor(raw - penalty + 0.5), 0, 100)
    return rec.score
end

-- Why it went the way it went (for the journal and the planner's result card).
function Pa.Factors(rec)
    local p = rec.parts or {}
    local good, bad = {}, {}
    if (p.food or 0) >= 70 then good[#good + 1] = "plenty to eat" elseif (p.food or 0) < 30 then bad[#bad + 1] = "not enough food" end
    if (p.music or 0) >= 60 then good[#good + 1] = "music all night" elseif (p.music or 0) < 20 then bad[#bad + 1] = "no music" end
    if (p.social or 0) >= 60 then good[#good + 1] = "lively conversation" elseif (p.social or 0) < 25 then bad[#bad + 1] = "guests barely talked" end
    if (p.fun or 0) >= 55 then good[#good + 1] = "guests having a great time" elseif (p.fun or 0) < 30 then bad[#bad + 1] = "bored guests" end
    if (p.needs or 0) < 50 then bad[#bad + 1] = "tired, hungry guests" end
    if (p.room or 0) < 40 then bad[#bad + 1] = "a gloomy, messy house" end
    if (rec.stats.earlyLeaves or 0) > 0 then bad[#bad + 1] = rec.stats.earlyLeaves .. " guest" .. (rec.stats.earlyLeaves == 1 and "" or "s") .. " left early" end
    return good, bad
end

local function leaveMess(world, rec)
    local made = {}
    local p = rec.platter and world.lot.objects[rec.platter]
    if p then
        local x, y, lv = p.x, p.y, p.level or 0
        local eaten = PD.platter.servings - (p.state.servings or 0)
        F.RemoveObject(world, p.id)
        if eaten > 0 then
            local o
            if SS.Maintenance and SS.Maintenance.Mess then o = SS.Maintenance.Mess(world, "plates", x, y, lv, { count = eaten }) end
            o = o or F.AddObject(world, "party_plates", x, y, lv, 0, { dirty = true, party = rec.id, plates = eaten })
            made[#made + 1] = o.id
        end
    end
    local n = math.floor((rec.stats.arrived or 0) / PD.rubbishPerGuests)
    if (rec.stats.arrived or 0) >= 2 then n = math.max(n, 1) end
    local avoid = {}
    for k = 1, n do
        local spot = rec.spots[((k - 1) * 5) % math.max(1, #rec.spots) + 1]
        if spot then
            local i, j = F.FreeCellNear(world, spot[3], spot[1], spot[2], 4, { open = true, notDoor = true, minR = 1, avoid = avoid })
            if i then
                avoid[i .. ":" .. j] = true
                local o
                if SS.Maintenance and SS.Maintenance.Mess then o = SS.Maintenance.Mess(world, "rubbish", i, j, spot[3], { units = 1 }) end
                o = o or F.AddObject(world, "party_rubbish", i, j, spot[3], 0, { party = rec.id })
                made[#made + 1] = o.id
            end
        end
    end
    rec.mess = made
    return made
end

function Pa.End(world, rec, why)
    rec = rec or Pa.Active(world)
    if not rec or rec.state == "ended" then return false, "No party is running." end
    if rec.state == "planned" then return Pa.Cancel(world, why) end
    local root = F.Root(world)
    Pa.Sample(world, rec)
    rec.state = "ended"
    rec.endedAt = root.time
    rec.endWhy = why
    SS.Sim.Unschedule(world, function(ev) return ev.kind == "party.arrive" and ev.data and ev.data.id == rec.id end)
    local score = Pa.Score(world, rec)
    rec.outcome = (rec.stats.arrived == 0 and "empty") or (score >= PD.goodAt and "good") or (score <= PD.badAt and "bad") or "ok"
    local host = world.actors[rec.host]
    local good = rec.outcome == "good"
    if host then
        if rec.outcome ~= "ok" then F.Say(world, host, good and "party_good" or "party_bad", { score = score, host = true }, nil) end
        host.pose = good and "celebrate" or (rec.outcome == "bad" and "cry" or "idle")
        SS.Needs.Add(host, "fun", (score - 50) / 3)
        SS.Needs.Add(host, "social", 10 + score / 5)
    end
    -- everyone still here says goodbye and goes home
    for _, rid in ipairs(rec.order) do
        local g = rec.guests[rid]
        local a = g.arrived and not g.left and world.actors[rid]
        if a then
            if rec.outcome == "good" or rec.outcome == "bad" then
                F.Say(world, a, good and "party_good" or "party_bad", { score = score, guest = true, host = rec.host })
            end
            Pa.GuestLeaves(world, rec, a, "over")
        elseif g.arrived and not g.sat and not g.movedIn then
            g.sat = Pa.Satisfaction(world, rec, g)
        elseif g.coming and not g.arrived and not g.left then
            -- still on the way in when it ended: turned round at the door (a no-show, no penalty)
            g.coming, g.left, g.leftWhy, g.noShow = nil, root.time, "noshow", true
            local c = world.actors[rid]
            if c and c.role == "guest" then
                if SS.Visitors and SS.Visitors.Leave then SS.Visitors.Leave(world, c, "party_over")
                else SS.Sim.RemoveActor(world, c.id, { reason = "home" }) end
            end
        end
    end
    local mess = leaveMess(world, rec)
    releaseMusic(world, rec)
    setAudio(world, "live")
    local goodF, badF = Pa.Factors(rec)
    local head = ({ good = "The party was a hit", ok = "The party was pleasant enough", bad = "The party was a flop",
        empty = "Nobody turned up to the party" })[rec.outcome]
    local text = head .. " (score " .. score .. ")"
    local bits = {}
    if goodF[1] then bits[#bits + 1] = table.concat(goodF, ", ") end
    if badF[1] then bits[#bits + 1] = (goodF[1] and "but " or "") .. table.concat(badF, ", ") end
    if bits[1] then text = text .. ": " .. table.concat(bits, "; ") end
    text = text .. "." .. (#mess > 0 and " The clean-up can wait until morning." or "")
    F.Journal(world, text)
    if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "info") end
    local ev = F.Record(world, "party", { id = rec.id, score = score, outcome = rec.outcome, guests = rec.stats.arrived })
    if ev then F.Resolve(world, ev, rec.outcome) end
    local s = Pa.Root(world)
    local summary = { id = rec.id, t = root.time, score = score, outcome = rec.outcome, arrived = rec.stats.arrived,
        earlyLeaves = rec.stats.earlyLeaves, host = rec.host, parts = U.deepcopy(rec.parts), mess = #mess, text = text,
        guests = {} }
    for _, rid in ipairs(rec.order) do
        local g = rec.guests[rid]
        summary.guests[#summary.guests + 1] = { rid = rid, accepted = g.accepted, arrived = g.arrived and true or false,
            leftWhy = g.leftWhy, sat = g.sat and math.floor(g.sat + 0.5) or nil }
    end
    s.history[#s.history + 1] = summary
    while #s.history > PD.historyCap do table.remove(s.history, 1) end
    s.lastEnd = root.time
    s.active = nil
    SS.Emit("partyEnded", world, rec, summary)
    return true, text, summary
end

function Pa.Tick(world, dt)
    local rec = Pa.Active(world)
    if not rec or rec.lotId ~= world.lot.id then return end
    local now = F.Root(world).time
    if rec.state == "planned" then
        if now >= rec.startAt then Pa.Start(world, rec) end
        return
    end
    checkComing(world, rec, now)
    retryJoin(world, rec, now)
    local present = 0
    for _, rid in ipairs(rec.order) do
        local g = rec.guests[rid]
        if g.arrived and not g.left then
            local a = world.actors[rid]
            if a then
                present = present + 1
                Pa.HearsMusic(world, a)
            else
                -- sent home by someone else (the visitors framework, "Ask to Leave"): an early departure
                g.left, g.leftWhy = now, "left"
                rec.stats.earlyLeaves = rec.stats.earlyLeaves + 1
                rec.stats.leavePenalty = rec.stats.leavePenalty + PD.leaveWeight.left
                g.sat = Pa.Satisfaction(world, rec, g) - 10
                relConsequence(world, rec, g, g.sat)
            end
        end
    end
    rec.stats.guestMinutes = rec.stats.guestMinutes + present * dt
    rec.acc = (rec.acc or 0) + dt
    if rec.acc >= PD.sampleEvery then
        rec.acc = 0
        Pa.Sample(world, rec)
    end
    local waiting = false
    for _, rid in ipairs(rec.order) do
        local g = rec.guests[rid]
        if g.accepted and not g.arrived and not g.left then waiting = true end
    end
    local anyAdult = F.AdultPresent(world, world.household)
    if now >= rec.endAt then Pa.End(world, rec, "time")
    elseif not waiting and present == 0 and now >= rec.startAt + PD.arrivalWindow[2] then Pa.End(world, rec, "empty")
    elseif not anyAdult then Pa.End(world, rec, "host_left") end
end

---------------------------------------------------------------------------
-- Party interactions: eating from the platter, mingling, dancing, a toast; cleaning up after
---------------------------------------------------------------------------
local I = SS.Interactions
local PP = PD.platter

local function platterServings(world, o, delta)
    o.state.servings = math.max(0, math.min(PP.servings, (o.state.servings or 0) + delta))
    o.state.heaped = o.state.servings > PP.servings / 2 or nil
    o.state.empty = o.state.servings <= 0 or nil
    SS.Emit("lotChanged", "state", o.id)
end

-- A guest ate a serving (or a meal) at the running party.
function Pa.CountFood(world, actor)
    local rec = Pa.Running(world)
    local g = rec and guestOf(world, actor)
    if not g then return false end
    g.ate = g.ate + 1
    rec.stats.food = rec.stats.food + 1
    return true
end

I.party_eat = {
    label = "Grab a Bite", category = "Food", slot = "front", pose = "eat_stand", dur = PP.eatDur,
    gain = { hunger = PP.hunger, fun = PP.fun, social = 5 }, advert = { hunger = PP.hunger, fun = PP.fun + 10, social = 10 }, kinds = { human = true },
    test = function(world, actor, o)
        if not F.IsHuman(actor) or F.IsInfant(actor) then return false, "That's people food." end
        if not o then return false, "The platter is gone." end
        if not o.state or (o.state.servings or 0) <= 0 then return false, "The platter is empty." end
        return true
    end,
    onStart = function(world, actor, act, o)
        if not o or (o.state.servings or 0) <= 0 then return false, "The platter is empty." end
        platterServings(world, o, -1)
        act.data.served = o.id
        -- someone starting a chat doesn't pull a guest away from their plate (F.Engage honours
        -- noEngage); the talker still says their piece
        act.data.noEngage = true
        if not actor.carry or actor.carry == "plate_food" then actor.carry = "plate_food"; act.data.plate = true end
    end,
    onEnd = function(world, actor, act, o, status)
        if act.data.plate and actor.carry == "plate_food" then actor.carry = nil end
        if status == "done" or not act.data.served then return end
        -- interrupted (a player order, a fire, a visitor sent home): most of the plate eaten
        -- counts as eaten; a plate barely touched goes back on the platter if it is still there
        if (act.t or 0) >= (act.dur or PP.eatDur) / 2 then
            Pa.CountFood(world, actor)
        else
            local p = world.lot.objects[act.data.served]
            if p and p.state then platterServings(world, p, 1) end
        end
    end,
}

local function partyPeople(world, actor, target)
    local rec = Pa.Running(world)
    if not rec then return false, "That's for parties." end
    local function inParty(a)
        if not a or not F.IsHuman(a) or F.IsInfant(a) or a.dead then return false end
        if a.householdId == rec.hh and not a.role then return true end
        return guestOf(world, a) ~= nil
    end
    if not inParty(actor) then return false, "Only people at the party can do that." end
    if not inParty(target) then return false, (target and target.name or "They") .. " isn't at the party." end
    if actor == target then return false, "That takes two." end
    if target.sleeping then return false, target.name .. " is asleep." end
    return true, rec
end

-- Chance that a party conversation lands (relationship, both personalities, music in the air).
function Pa.MingleChance(world, a, b)
    local M = PD.mingle
    local life = math.max(F.PeekRel(world, a.id, b.id).life, F.PeekRel(world, b.id, a.id).life)
    local oa = (a.personality and a.personality.outgoing) or 5
    local ob = (b.personality and b.personality.outgoing) or 5
    local p = M.base + M.perLife * life + M.perOutgoing * ((oa + ob) / 2 - 5) + (Pa.MusicAt(world, a) and M.music or 0)
    return U.clamp(p, M.min, M.max)
end

local function social(label, D, pose, extra)
    local def = {
        label = label, category = "Party", targetActor = true, pose = pose, dur = D.dur, kinds = { human = true },
        advert = { social = D.social, fun = D.fun },
        test = function(world, actor, target)
            local ok, why = partyPeople(world, actor, target)
            if not ok then return false, why end
            if extra and extra.test then return extra.test(world, actor, target) end
            return true
        end,
        onStart = function(world, actor, act)
            local t, why = F.TargetInReach(world, actor, act, 2.8)
            if not t then return false, why end
            if extra and extra.roll then
                act.data.awkward = SS.Random(world, "party") >= extra.roll(world, actor, t) or nil
            end
            F.Engage(world, t, actor, act.data.awkward and "idle" or pose, D.dur + 2)
        end,
        onTick = function(world, actor, act, _, dt)
            local t = world.actors[act.tid]
            local gains = act.data.awkward and { social = PD.mingle.awkwardSocial, fun = PD.mingle.awkwardFun }
                or { social = D.social, fun = D.fun, energy = D.energy }
            F.TickGain(world, act, actor, gains, D.dur, dt)
            if t then F.TickGain(world, act, t, gains, D.dur, dt) end
        end,
        onEnd = function(world, actor, act, _, status)
            if status ~= "done" or not F.Exists(world, act.tid) then return end
            if act.data.awkward then
                F.Change(world, actor.id, act.tid, -2, 0)
                F.Change(world, act.tid, actor.id, -2, 0)
                actor.balloon = { icon = "social", text = "An awkward pause.", untilT = world.time + 6, kind = "thought" }
                return
            end
            F.Change(world, actor.id, act.tid, 3, 0.5)
            F.Change(world, act.tid, actor.id, 3, 0.5)
            if extra and extra.done then extra.done(world, actor, act) end
        end,
    }
    return def
end

I.party_mingle = social("Mingle", PD.mingle, "talk", { roll = function(world, a, b) return Pa.MingleChance(world, a, b) end })
I.party_dance = social("Dance Together", PD.dance, "dance", {
    test = function(world, actor, target)
        if not Pa.MusicAt(world, actor) then return false, "There's no music to dance to." end
        if (actor.needs.energy or 0) < -40 then return false, actor.name .. " is too tired to dance." end
        return true
    end,
    done = function(world, actor)
        local rec = Pa.Running(world)
        if rec then rec.stats.activities = rec.stats.activities + 1 end
    end,
})

I.party_toast = {
    label = "Raise a Toast", category = "Party", targetActor = true, pose = "celebrate", dur = PD.toast.dur, kinds = { human = true },
    advert = {}, manualOnly = true,
    test = function(world, actor, target)
        local ok, rec = partyPeople(world, actor, target)
        if not ok then return false, rec end
        if actor.id ~= rec.host and actor.householdId ~= rec.hh then return false, "Only the hosts raise a toast." end
        if rec.toastAt and F.Root(world).time - rec.toastAt < PD.toastCooldown then return false, "There was a toast a moment ago." end
        return true
    end,
    onEnd = function(world, actor, act, _, status)
        if status ~= "done" then return end
        local rec = Pa.Running(world)
        if not rec then return end
        rec.toastAt = F.Root(world).time
        rec.stats.activities = rec.stats.activities + 1
        local n = 0
        for _, rid in ipairs(rec.order) do
            local a = world.actors[rid]
            if a and guestOf(world, a) and F.Dist(a, actor) <= PD.toast.radius then
                SS.Needs.Add(a, "fun", 8)
                SS.Needs.Add(a, "social", 8)
                a.pose = "celebrate"
                F.Change(world, rid, actor.id, 2, 0.5)
                n = n + 1
            end
        end
        rec.stats.socials = rec.stats.socials + n
        SS.Actions.Message(world, actor, actor.name .. " raised a toast" .. (n > 0 and (" and " .. n .. " guest" .. (n == 1 and "" or "s") .. " cheered.") or ", but nobody was close enough to hear."), "social")
    end,
}

local function cleanup(label, dur)
    return {
        label = label, category = "Cleaning", slot = "front", pose = "clean", dur = dur, chore = true, traits = { neat = 1 },
        gain = { hygiene = -3 }, advert = { room = 30 }, ages = { adult = true, child = true }, kinds = { human = true },
        test = function(world, actor)
            if not F.IsHuman(actor) or F.IsInfant(actor) then return false, "Only people can tidy up." end
            if actor.role == "guest" then return false, "Guests don't clean up." end
            return true
        end,
        onStart = function(world, actor, act, o)
            if not o then return false, "Someone already cleared it away." end
            if o.def == "party_plates" and (not actor.carry or actor.carry == "plate_stack") then actor.carry = "plate_stack"; act.data.carry = true end
        end,
        onEnd = function(world, actor, act, o, status)
            if act.data.carry and actor.carry == "plate_stack" then actor.carry = nil end
            if status ~= "done" or not o then return end
            F.RemoveObject(world, o.id)
            SS.Emit("messCleaned", world, actor, o.def)
        end,
    }
end
I.party_clean_plates = cleanup("Clear Away Plates", 6)
I.party_clean_rubbish = cleanup("Pick Up Rubbish", 5)

-- Party guests never go to bed in the hosts' home: refused outright where household-core takes
-- access hooks (menus, orders and autonomy), and stripped from autonomy's candidates below.
if SS.Actions.RegisterAccessHook then
    SS.Actions.RegisterAccessHook(function(world, actor, obj, iid, ia)
        ia = ia or SS.Interactions[iid]
        if ia and ia.sleeping and actor and guestOf(world, actor) then
            return false, "Party guests don't go to bed here.", "guest"
        end
    end)
end

-- Social opportunities: during a party, guests and the family mingle and dance autonomously.
local NEAR_T, NEAR_D = {}, {}
SS.Actions.RegisterCandidates(function(world, actor, cands)
    local rec = Pa.Running(world)
    if not rec or not F.IsHuman(actor) or F.IsInfant(actor) then return end
    local isGuest = guestOf(world, actor) ~= nil
    -- guests don't go to bed in the hosts' home: a guest that tired goes home instead (Pa.Sample)
    if isGuest then
        for n = #cands, 1, -1 do
            local ia = SS.Interactions[cands[n].iid]
            if ia and ia.sleeping then table.remove(cands, n) end
        end
    end
    if not isGuest and not (actor.householdId == rec.hh and not actor.role) then return end
    local out = (actor.personality and actor.personality.outgoing) or 5
    local act_ = (actor.personality and actor.personality.active) or 5
    -- the nearest three people at the party (a fixed scratch buffer: no tables per think)
    local nearT, nearD = NEAR_T, NEAR_D
    local count = 0
    local ids = F.ActorIds(world)
    for n = 1, #ids do
        local t = world.actors[ids[n]]
        local arriving = t and ((t.act and t.act.data and t.act.data.arriving) or (t.queue and t.queue[1] and t.queue[1].data and t.queue[1].data.arriving))
        -- (people standing in a doorway are passing through: no party chat there)
        if t and t ~= actor and not t.sleeping and not arriving and not F.NearDoor(world, math.floor(t.x), math.floor(t.y))
            and (guestOf(world, t) or (t.householdId == rec.hh and F.IsHuman(t) and not F.IsInfant(t) and not t.role)) then
            local d = F.Dist(t, actor)
            -- insert in order (distance, then id: ids arrive sorted, so ties keep the lower id first)
            local k = count < 3 and count + 1 or 4
            while k > 1 and nearD[k - 1] > d do
                if k <= 3 then nearT[k], nearD[k] = nearT[k - 1], nearD[k - 1] end
                k = k - 1
            end
            if k <= 3 then nearT[k], nearD[k] = t, d; if count < 3 then count = count + 1 end end
        end
    end
    if count == 0 then return end
    local pick = nearT[SS.RandomInt(world, "party", 1, count)]
    for k = 1, 3 do nearT[k] = nil end
    -- outgoing people mingle readily; shy ones mostly with people they already know
    local life = math.max(F.PeekRel(world, actor.id, pick.id).life, F.PeekRel(world, pick.id, actor.id).life)
    local s = 6 + (100 - (actor.needs.social or 0)) / 6 + 2 * out + U.clamp(life, 0, 50) / 5
    if not F.AutoCooling(world, actor, pick.id, "party_mingle") and SS.Actions.Available(world, actor, pick, "party_mingle") then
        cands[#cands + 1] = { tid = pick.id, iid = "party_mingle", s = s }
    end
    if Pa.HearsMusic(world, actor) and not F.AutoCooling(world, actor, pick.id, "party_dance") and SS.Actions.Available(world, actor, pick, "party_dance") then
        cands[#cands + 1] = { tid = pick.id, iid = "party_dance", s = 12 + (100 - (actor.needs.fun or 0)) / 5 + act_ }
    end
end)

-- Atmosphere: music makes a party; silence makes it drag (guests of the running party only).
SS.Needs.RegisterRateHook(function(world, a, need, rate)
    if need ~= "fun" or not world or a.role ~= "guest" then return rate end
    local g = guestOf(world, a)
    if not g then return rate end
    if Pa.HearsMusic(world, a) then return rate + PD.atmosphere.musicFun end
    return rate + PD.atmosphere.silenceFun
end)

-- Conversations and food count toward the score as they happen.
local SKIP = { fam_respond = true, fam_cheer = true }
SS.On("actionEnded", function(actor, act, status)
    if not act then return end
    local world = SS.Sim.world
    if not world then return end
    local rec = Pa.Running(world)
    if not rec then return end
    if status ~= "done" then
        -- the walk in was blocked: try again shortly (bounded)
        local g = act.iid == "goto" and act.data and act.data.arriving and guestOf(world, actor)
        if g and status == "failed" and (g.joinTries or 0) < PD.joinRetries then
            g.joinRetryAt = F.Root(world).time + PD.joinRetryEvery
        end
        return
    end
    local ia = SS.Interactions[act.iid]
    if not ia then return end
    local g = guestOf(world, actor)
    local target = act.tid and world.actors[act.tid]
    if ia.targetActor and target and F.IsHuman(target) and not F.IsInfant(target) and not SKIP[act.iid]
        and not (act.data and act.data.awkward)
        and act.iid:sub(1, 4) ~= "pet_" and act.iid:sub(1, 7) ~= "infant_" and act.iid ~= "party_toast" then
        local tg = guestOf(world, target)
        if g or tg then
            rec.stats.socials = rec.stats.socials + 1
            if g then g.socials = g.socials + 1 end
            if tg then tg.socials = tg.socials + 1 end
        end
    end
    if g and ((ia.gain and (ia.gain.hunger or 0) > 0) or act.iid == "party_eat") then Pa.CountFood(world, actor) end
    -- dancing to the stereo through household-core's own Dance counts like party_dance
    -- (which counts itself in its onEnd)
    if act.iid ~= "party_dance" and (ia.pose == "dance" or act.iid == "dance")
        and (g or (actor.householdId == rec.hh and not actor.role and F.IsHuman(actor))) then
        rec.stats.activities = rec.stats.activities + 1
    end
    -- a member switching the music off by hand: the party stops putting it back on
    if act.iid == "music_off" and act.oid and act.oid == rec.musicObj and not g then
        rec.musicStopped = true
        local o = world.lot.objects[act.oid]
        if o and o.keepOn == "party" then o.keepOn = nil end
    end
end)

-- A guest removed from the lot mid-party is marked on the next tick (Pa.Tick).

---------------------------------------------------------------------------
-- Phone call, fallback guest role, scheduled events, system, validator
---------------------------------------------------------------------------
if SS.Phone and SS.Phone.RegisterCall then
    SS.Phone.RegisterCall({ id = "family_party", label = "Throw a Party", category = "Friends", order = 5,
        test = function(world, caller) return Pa.PlanCheck(world, caller) end,
        run = function(world, caller)
            if Pa.openPlanner then Pa.openPlanner(world, caller); return true, "Plan the party: pick a time, the food and the guests." end
            return Pa.Plan(world, caller, {})
        end })
end

-- The visitors module owns the "guest" role; until it registers one this minimal role keeps
-- party guests on autonomy with their needs running.
if not (SS.Roles and SS.Roles.guest) and SS.Visitors and SS.Visitors.RegisterRole then
    SS.Visitors.RegisterRole("guest", { label = "Guest", useAutonomy = true, noNeeds = false, access = "guest", fallbackFromFamily = true })
end

SS.On("scheduled", function(ev, world)
    if not world then return end
    if ev.kind == "party.start" then
        local rec = Pa.Active(world)
        if rec and rec.id == ev.data.id and rec.state == "planned" then Pa.Start(world, rec) end
    elseif ev.kind == "party.arrive" then
        local rec = Pa.Active(world)
        if rec and rec.id == ev.data.id then Pa.Arrive(world, rec, ev.data.rid) end
    end
end)

-- Plates in hand from before a load are put away unless a resumed action uses them (F.PutAwayProps).
Pa.PROPS = { plate_food = "party_eat", plate_stack = "party_clean_plates" }

SS.Sim.Register({
    name = "parties", order = 48,
    attach = function(world)
        F.PutAwayProps(world, Pa.PROPS)
        local rec = Pa.Active(world)
        -- a stale "keep the music on" mark with no party running here (a save from mid-party whose
        -- party record was repaired away) is removed
        if not (rec and rec.state == "running" and rec.lotId == world.lot.id) then
            for _, o in pairs(world.lot.objects) do if o.keepOn == "party" then o.keepOn = nil end end
        end
        if not rec or rec.lotId ~= world.lot.id then return end
        local now = F.Root(world).time
        -- scheduled events survive in the save; add any that went missing (never twice)
        local have = {}
        for _, ev in ipairs(world.scheduled) do
            if (ev.kind == "party.arrive" or ev.kind == "party.start") and ev.data and ev.data.id == rec.id then
                have[ev.kind .. ":" .. tostring(ev.data.rid)] = true
            end
        end
        if rec.state == "planned" and not have["party.start:nil"] then
            SS.Sim.Schedule(world, math.max(rec.startAt, now), "party.start", { id = rec.id }, rec.lotId)
        end
        for _, rid in ipairs(rec.order) do
            local g = rec.guests[rid]
            -- a guest saved on the way in who is no longer on the street is sent for again
            if g.coming and not g.arrived and not g.left and not world.actors[rid] then g.coming = nil end
            if g.accepted and not g.arrived and not g.left and not g.coming and not have["party.arrive:" .. rid] then
                SS.Sim.Schedule(world, math.max(g.arriveAt or now, now), "party.arrive", { id = rec.id, rid = rid }, rec.lotId)
            end
            local a = world.actors[rid]
            if g.arrived and not g.left and a then
                a.role = a.role or "guest"
                a.roleData = a.roleData or {}
                a.roleData.party = rec.id
                a.noNeeds = nil
            end
        end
        if rec.state == "running" then setAudio(world, "party") end
    end,
    tick = function(world, dt) Pa.Tick(world, dt) end,
})

SS.Save.RegisterValidator(function(root, problems)
    local s = root.parties
    if s == nil then return true end
    if type(s) ~= "table" then root.parties = nil; problems[#problems + 1] = "party data reset"; return true end
    s.history = type(s.history) == "table" and s.history or {}
    while #s.history > PD.historyCap do table.remove(s.history, 1) end
    local rec = s.active
    if rec ~= nil then
        if type(rec) ~= "table" or type(rec.guests) ~= "table" or type(rec.order) ~= "table" or type(rec.stats) ~= "table"
            or not root.households[rec.hh or ""] or not (root.hood and root.hood.lots[rec.lotId or ""]) then
            s.active = nil
            problems[#problems + 1] = "dropped a damaged party record"
        else
            for _, rid in ipairs(rec.order) do
                if not rec.guests[rid] or not root.residents[rid] then rec.guests[rid] = { rid = rid, accepted = false, left = root.time or 0, leftWhy = "noshow",
                    samples = 0, moodSum = 0, musicSamples = 0, socials = 0, ate = 0, miserable = 0 } end
            end
            rec.spots = type(rec.spots) == "table" and rec.spots or {}
        end
    end
    return true
end)

-- Summary for the UI planner.
function Pa.Status(world)
    local rec = Pa.Active(world)
    if not rec then return nil end
    local root = F.Root(world)
    local coming, arrived, here, left = 0, 0, 0, 0
    for _, rid in ipairs(rec.order) do
        local g = rec.guests[rid]
        if g.accepted then coming = coming + 1 end
        if g.arrived then arrived = arrived + 1 end
        if g.arrived and not g.left then here = here + 1 end
        if g.left and g.arrived then left = left + 1 end
    end
    local p = rec.platter and world.lot and world.lot.objects[rec.platter]
    return { id = rec.id, state = rec.state, startAt = rec.startAt, endAt = rec.endAt, invited = #rec.order, coming = coming,
        arrived = arrived, here = here, left = left, score = rec.score or 0, parts = rec.parts, food = rec.food,
        servings = p and p.state.servings or 0, music = rec.music, host = root.residents[rec.host] and root.residents[rec.host].name }
end
