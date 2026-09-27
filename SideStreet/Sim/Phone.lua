-- SideStreet phone: outgoing calls made at a real phone object, incoming calls that ring and are
-- answered (or missed), and the built-in calls (services, friends, the newspaper). Owner: visitors
-- module (docs/modules/visitors.md). Other modules add calls with SS.Phone.RegisterCall (the fire
-- brigade, a taxi, adoption, parties, job offers) and incoming call kinds with RegisterIncoming.
--
-- Nothing happens "from a menu": the chosen resident walks to a phone (an object tagged `phone`),
-- picks it up (pose "phone", prop "phone"), talks, and the call's outcome happens when the
-- call ends. Without a phone on the lot, calls are refused with that explanation.
local _, SS = ...
local RD = SS.RoleData
local PT = RD.phone
local U = SS.U
local V = SS.Visitors
local Sv = SS.Services
local Ph = SS.Phone or {}
SS.Phone = Ph
Ph.calls = Ph.calls or {}
Ph.incomingKinds = Ph.incomingKinds or {}
Ph.stats = { placed = 0, rang = 0, answered = 0, missed = 0, badtime = 0 }

local CATS = {}
for n, c in ipairs(PT.categories) do CATS[c.id] = n end
Ph.categories = PT.categories

local function sortedIds(t) return V.SortedIds(t) end
local function sfx(name) if SS.Audio and SS.Audio.Sfx then SS.Audio.Sfx(name) end end

---------------------------------------------------------------------------------------------------
-- Outgoing call registry
-- def = { id, label, category = "Services"|"Friends"|"Emergency"|"Travel"|"Family"|"Other", order,
--   desc, test = fn(world, caller) -> ok, why,
--   run = fn(world, caller, arg) -> ok, message        (runs when the call ends)
--   options = fn(world, caller) -> { { label, arg, desc?, disabled?, reason? }, ... }   (a sub-list:
--             friends to invite, menu items; the chosen option's arg reaches run)
--   labelFn = fn(world, caller) -> label (a label that follows state, e.g. Book / Cancel daily)
--   dur = minutes on the phone (default tuning.phone.callLen), gain = { need = amount } over the call,
--   hidden = fn(world, caller) -> true to leave it out of the list }
-- Unknown categories are listed under "Other".
function Ph.RegisterCall(def)
    assert(def and def.id, "SS.Phone.RegisterCall needs an id")
    if not CATS[def.category or ""] then def.category = "Other" end
    Ph.calls[def.id] = def
    return def
end
for _, def in pairs(Ph.calls) do if not CATS[def.category or ""] then def.category = "Other" end end

local function callSort(a, b)
    local ca, cb = CATS[a.category] or 99, CATS[b.category] or 99
    if ca ~= cb then return ca < cb end
    if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) < (b.order or 50) end
    return a.id < b.id
end

-- Registered calls, sorted (category order, then order, then id). category (optional) filters.
-- Hidden calls are left out when a world is given.
function Ph.Calls(world, caller, category)
    local out = {}
    for _, d in pairs(Ph.calls) do
        if (not category or d.category == category) and not (world and d.hidden and d.hidden(world, caller)) then out[#out + 1] = d end
    end
    table.sort(out, callSort)
    return out
end

-- { { id, label, calls = {...} }, ... } for the non-empty categories in the fixed order.
function Ph.CallsByCategory(world, caller)
    local out = {}
    for _, c in ipairs(PT.categories) do
        local list = Ph.Calls(world, caller, c.id)
        if #list > 0 then out[#out + 1] = { id = c.id, label = c.label, calls = list } end
    end
    return out
end

function Ph.Label(world, caller, def)
    return def.labelFn and def.labelFn(world, caller) or def.label or def.id
end

-- Any phone object, broken or not (a phone that broke while ringing still stops ringing).
local function isPhone(o)
    local def = o and SS.Objects[o.def]
    return def and SS.Tags.Has(def, "phone") or false
end

-- The phones on the lot (tag `phone`), nearest to `near` first.
function Ph.Phones(world, near)
    local out = {}
    for _, oid in ipairs(sortedIds(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and SS.Tags.Has(def, "phone") and not (o.state and o.state.broken) then out[#out + 1] = o end
    end
    if near then
        table.sort(out, function(a, b)
            local da = math.abs(a.x + 0.5 - near.x) + math.abs(a.y + 0.5 - near.y) + math.abs((a.level or 0) - (near.level or 0)) * 6
            local db = math.abs(b.x + 0.5 - near.x) + math.abs(b.y + 0.5 - near.y) + math.abs((b.level or 0) - (near.level or 0)) * 6
            if da ~= db then return da < db end
            return a.id < b.id
        end)
    end
    return out
end
function Ph.AnyPhone(world, broken)
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        if def and SS.Tags.Has(def, "phone") and (broken or not (o.state and o.state.broken)) then return o end
    end
end

-- Can `caller` make this call now? ok, why
function Ph.Check(world, caller, def, arg)
    if not def then return false, "No such number." end
    if not caller or not V.IsMember(world, caller) then return false, "Select someone from the household first." end
    if (caller.kind or "human") ~= "human" then return false, "Only people use the phone." end
    if caller.age == "infant" then return false, "Too young to use the phone." end
    if caller.sleeping then return false, caller.name .. " is asleep." end
    if not Ph.AnyPhone(world, true) then return false, "There's no phone on this lot. Buy one from the Electronics catalogue." end
    if not Ph.AnyPhone(world) then return false, "The phone is broken. Repair it first (choose Repair on the phone)." end
    if def.test then
        local ok, why = def.test(world, caller, arg)
        if not ok then return false, why or "Not possible right now." end
    end
    return true
end

-- Evaluated sub-options of a call (each with ok / why).
function Ph.Options(world, caller, def)
    if not def.options then return nil end
    local out = {}
    for _, o in ipairs(def.options(world, caller) or {}) do out[#out + 1] = o end
    return out
end

-- Place a call: the caller walks to the nearest reachable phone and makes it. Returns ok, message.
-- phoneOid picks a phone (the object menu); arg is the chosen option.
function Ph.Place(world, caller, callId, arg, phoneOid)
    local def = Ph.calls[callId]
    local ok, why = Ph.Check(world, caller, def, arg)
    if not ok then return false, why end
    local phones = phoneOid and { world.lot.objects[phoneOid] } or Ph.Phones(world, caller)
    for _, o in ipairs(phones) do
        if o then
            local pdef = SS.Objects[o.def]
            V.EnsureSlot(pdef, "svc")
            local okA, whyA = SS.Actions.Available(world, caller, o, "phone_call")
            if okA then
                SS.Actions.Order(world, caller, o.id, "phone_call", nil, nil, { data = { call = callId, arg = arg } })
                Ph.stats.placed = Ph.stats.placed + 1
                return true, caller.name .. " is going to the phone."
            end
            why = whyA
        end
    end
    return false, why or "Nobody can reach a phone right now."
end

---------------------------------------------------------------------------------------------------
-- Phone interactions
local function callDur(world, act)
    local def = act.data and act.data.call and Ph.calls[act.data.call]
    return (def and def.dur) or PT.callLen
end

SS.Interactions.phone_call = {
    label = "Make a Call", category = "Phone", slot = "svc", pose = "phone", carry = "phone", maxDur = 90, manualOnly = true,
    test = function(world, actor, obj)
        if V.Owns(actor.role) then return false, "Only the household uses the phone." end
        if (actor.kind or "human") ~= "human" then return false, "Only people use the phone." end
        if actor.age == "infant" then return false, "Too young to use the phone." end
        if obj and obj.state and obj.state.broken then return false, "The phone is broken." end
        if obj and obj.state and obj.state.ringing then return false, "It's ringing: answer it first." end
        return true
    end,
    onStart = function(world, actor, act, obj)
        local def = act.data and Ph.calls[act.data.call]
        if not def then return false, "No such number." end
        local ok, why = Ph.Check(world, actor, def, act.data.arg)
        if not ok then return false, why end
        act.need = callDur(world, act)
        act.pose = "phone"
        actor.carry = "phone"
        if obj then obj.state = obj.state or {}; obj.state.inUse = true end
        sfx(RD.sfx.pickup)
        actor.balloon = { kind = "speech", icon = "bubble", untilT = world.time + act.need }
    end,
    onTick = function(world, actor, act, obj, dt)
        local def = act.data and Ph.calls[act.data.call]
        if def and def.gain then
            local frac = math.min(dt, math.max(0, act.need - act.t)) / act.need
            for need, amt in pairs(def.gain) do SS.Needs.Add(actor, need, amt * frac) end
        end
        if act.t + dt >= (act.need or PT.callLen) then act.complete = true end
    end,
    onEnd = function(world, actor, act, obj, status)
        if actor.carry == "phone" then actor.carry = nil end
        if obj and obj.state then obj.state.inUse = nil end
        sfx(RD.sfx.hangup)
        local def = act.data and Ph.calls[act.data.call]
        if status ~= "done" or not def or not act.performed then
            if status == "cancelled" and act.performed then V.Notice(world, actor, actor.name .. " hung up before finishing the call.", "bubble") end
            return
        end
        local ok, msg = true, nil
        if def.run then ok, msg = def.run(world, actor, act.data.arg) end
        if msg then V.Notice(world, actor, msg, ok and "bubble" or "noroute") end
        SS.Emit("phoneCall", world, actor, def.id, ok, msg)
    end,
}

---------------------------------------------------------------------------------------------------
-- Incoming calls: root.phone = { incoming = {...} | nil, missed = { bounded }, cool, nextId }
function Ph.State(world)
    local root = world.root or world
    local s = root.phone
    if type(s) ~= "table" then s = {}; root.phone = s end
    s.missed = s.missed or {}
    s.nextId = s.nextId or 1
    return s
end

-- Other modules' incoming kinds: Ph.RegisterIncoming(kind, { label, answer = fn(world, answerer, call)
-- -> message, dur }) and Ph.Ring(world, { kind, from, text }).
function Ph.RegisterIncoming(kind, def) Ph.incomingKinds[kind] = def; return def end

local function ringingPhone(world)
    local list = Ph.Phones(world)
    return list[1]
end

-- Start the phone ringing with a call (returns the call, or nil, why). call = { kind, from = rid,
-- desk, ... }. An ordinary kind (chat, invite, news) rung without a caller (events' "a friend
-- calls") gets one the way the hourly roll picks them: a friend for a chat or an invitation, someone
-- met for news, else the newsdesk. Registered kinds (Ph.RegisterIncoming) are left as they are.
local ORDINARY = { chat = true, invite = true, news = true }
function Ph.Ring(world, call)
    call = type(call) == "table" and call or {}
    local s = Ph.State(world)
    if s.incoming then return nil, "The line is busy." end
    local phone = ringingPhone(world)
    if not phone then return nil, "There's no working phone here." end
    call.kind = call.kind or "chat"
    if call.from == nil and not call.desk and ORDINARY[call.kind] and not Ph.incomingKinds[call.kind] and Ph.PickCaller then
        local kind = call.kind
        local from = Ph.PickCaller(world, kind)
        if not from and kind ~= "news" then kind, from = "news", Ph.PickCaller(world, "news") end
        call.kind, call.from, call.desk = kind, from and from.id or nil, (not from) or nil
    end
    call.id = "pc" .. s.nextId
    s.nextId = s.nextId + 1
    call.at, call.untilT, call.lotId = world.time, world.time + PT.ringFor, world.lot.id
    call.hh = world.household and world.household.id
    s.incoming = call
    s.cool = world.time + PT.cool
    phone.state = phone.state or {}
    phone.state.ringing = true
    -- ringUntil: other modules' object ticks treat a ringing object without it as stale and silence it;
    -- the grace matches Ph.Tick (someone mid-walk to the phone keeps it ringing a little longer)
    phone.ringUntil = call.untilT + 2
    Ph.stats.rang = Ph.stats.rang + 1
    if SS.Audio and SS.Audio.Loop then SS.Audio.Loop("phone", RD.sfx.ring) end
    local who = call.from and world.root.residents[call.from]
    V.Notice(world, nil, "The phone is ringing" .. (who and (": " .. who.name .. " is calling.") or "."))
    SS.Emit("phoneRinging", world, call, phone)
    return call
end

local function stopRinging(world)
    -- phones only: an alarm clock or a smoke alarm ringing elsewhere on the lot is not ours to silence
    for _, o in pairs(world.lot.objects) do if isPhone(o) then
        if o.state and o.state.ringing then o.state.ringing = nil end
        o.ringUntil = nil
    end end
    if SS.Audio and SS.Audio.StopLoop then SS.Audio.StopLoop("phone") end
end

function Ph.Missed(world)
    local s = Ph.State(world)
    local call = s.incoming
    if not call then return end
    s.incoming = nil
    stopRinging(world)
    Ph.stats.missed = Ph.stats.missed + 1
    local who = call.from and world.root.residents[call.from]
    call.missedAt = world.time
    s.missed[#s.missed + 1] = { t = world.time, from = call.from, kind = call.kind, text = call.text, hh = call.hh }
    while #s.missed > PT.missedCap do table.remove(s.missed, 1) end
    V.Notice(world, nil, "Missed call" .. (who and (" from " .. who.name) or "") .. ".")
    SS.Emit("phoneMissed", world, call)
end

-- The missed calls of the household playing this lot (the list is shared by the save; each entry
-- remembers whose phone it rang). Entries from before this field existed count for everyone.
function Ph.MissedFor(world)
    local s = Ph.State(world)
    local hh = world.household and world.household.id
    local out = {}
    for _, m in ipairs(s.missed) do if m.hh == nil or m.hh == hh then out[#out + 1] = m end end
    return out
end

-- Pick who calls, by kind: a chat or an invitation only comes from someone the household is friendly
-- with (best mutual relationship >= phone.friendRel), news from someone they have at least met. With
-- nobody like that, the call is the newspaper's newsdesk reading a headline (from = nil), never a
-- stranger. Deterministic stream "phone".
local function pickCaller(world, kind)
    local cands = {}
    for _, e in ipairs(V.KnownPeople(world, 8)) do
        local r = e.r
        if not r.dead and not world.actors[r.id] then
            if kind == "news" then
                if V.Knows(world, r.id) then cands[#cands + 1] = r end
            elseif e.score >= PT.friendRel then
                cands[#cands + 1] = r
            end
        end
    end
    return SS.Pick(world, "phone", cands)
end
Ph.PickCaller = pickCaller

local function pickKind(world)
    local total = 0
    for _, k in ipairs(PT.kinds) do total = total + k.w end
    local x = SS.Random(world, "phone") * total
    for _, k in ipairs(PT.kinds) do
        x = x - k.w
        if x < 0 then return k.id end
    end
    return PT.kinds[#PT.kinds].id
end

-- Hourly roll for an ordinary incoming call.
function Ph.Hour(world, h)
    if not V.HomeLot(world) then return end
    local s = Ph.State(world)
    local hr = h % 24
    if s.incoming or hr < PT.first or hr >= PT.last then return end
    if (s.cool or -1e9) > world.time then return end
    if #V.MembersPresent(world) == 0 or not ringingPhone(world) then return end
    if SS.Fire and SS.Fire.Active and SS.Fire.Active(world) then return end
    if SS.Random(world, "phone") >= PT.chance then return end
    local kind = pickKind(world)
    local from = pickCaller(world, kind)
    if not from and kind ~= "news" then kind, from = "news", pickCaller(world, "news") end
    return Ph.Ring(world, { kind = kind, from = from and from.id or nil, desk = not from or nil })
end

-- Is this a bad moment for the person answering? (the badly timed call)
local function badTime(world, m)
    local n = m.needs or {}
    if (n.bladder or 0) < -20 or (n.hunger or 0) < -30 or (n.energy or 0) < -30 then return true end
    local le = m.tmp and m.tmp.interrupted
    if le and world.time - le.t < 1 and (le.iid == "toilet" or le.iid == "shower" or le.iid == "bath" or le.iid == "eat") then return true end
    return false
end


-- Resolve an answered call; returns minutes on the phone.
function Ph.Answer(world, m, call)
    local who = call.from and world.root.residents[call.from]
    local name = who and who.name or (call.desk and V.Text("newsdesk")) or "Someone"
    local T = RD.tuning
    Ph.stats.answered = Ph.stats.answered + 1
    local reg = Ph.incomingKinds[call.kind]
    if reg and reg.answer then
        local msg, dur = reg.answer(world, m, call)
        if msg then V.Notice(world, m, msg, "bubble") end
        SS.Emit("phoneAnswered", world, m, call, "custom")
        return dur or PT.len.news, "custom"
    end
    if badTime(world, m) then
        Ph.stats.badtime = Ph.stats.badtime + 1
        V.Say(world, m, "phone_badtime", { from = call.from, subject = who and who.id or name, kind = call.kind }, nil, "bubble")
        if who then V.RelChange(world, m.id, who.id, T.rel.badtime); V.RelChange(world, who.id, m.id, T.rel.badtime) end
        V.Notice(world, m, name .. " called at a terrible moment. " .. m.name .. " cut it short.", "bubble")
        SS.Emit("phoneAnswered", world, m, call, "badtime")
        return PT.len.badtime, "badtime"
    end
    if call.kind == "invite" and who then
        local ok, msg = V.Invite(world, m, who.id, { force = true })
        if ok then V.Notice(world, m, name .. " called to invite themselves over. " .. msg, "bubble")
        else V.Notice(world, m, name .. " wanted to come over, but " .. (msg or "it didn't work out") .. "", "bubble") end
        if who then V.RelChange(world, m.id, who.id, T.rel.chat) end
        SS.Emit("phoneAnswered", world, m, call, "invite")
        return PT.len.invite, "invite"
    end
    if call.kind == "chat" and who then
        V.Say(world, m, "smalltalk", { target = who.id, phone = true }, nil, "bubble")
        V.RelChange(world, m.id, who.id, T.rel.chat)
        V.RelChange(world, who.id, m.id, T.rel.chat)
        V.Notice(world, m, name .. " rang for a long chat.", "bubble")
        SS.Emit("phoneAnswered", world, m, call, "chat")
        return PT.len.chat, "chat"
    end
    local list = V.Text("news") or {}
    local news = list[SS.RandomInt(world, "phone", 1, math.max(1, #list))] or "nothing much, at length"
    V.Say(world, m, "gossip", { target = call.from, phone = true }, nil, "bubble")
    if who then V.Notice(world, m, name .. " called with the news: " .. news .. ".", "bubble")
    else V.Notice(world, m, string.format(V.Text("newsdeskCall") or "%s rang: %s.", name, news), "bubble") end
    if who then V.RelChange(world, m.id, who.id, { 2, 0 }) end
    SS.Emit("phoneAnswered", world, m, call, "news")
    return PT.len.news, "news"
end

SS.Interactions.phone_answer = {
    label = "Answer the Phone", category = "Phone", slot = "svc", pose = "phone", carry = "phone", maxDur = 60,
    advertise = function(world, actor, obj)
        if V.Owns(actor.role) or (actor.kind or "human") ~= "human" or actor.age == "infant" then return nil end
        if not (obj and obj.state and obj.state.ringing) then return nil end
        return { social = 25, fun = 10 }
    end,
    test = function(world, actor, obj)
        if V.Owns(actor.role) then return false, "Only the household answers the phone." end
        if (actor.kind or "human") ~= "human" then return false, "Only people answer the phone." end
        if actor.age == "infant" then return false, "Too young to answer." end
        if not (obj and obj.state and obj.state.ringing) or not Ph.State(world).incoming then return false, "It isn't ringing." end
        return true
    end,
    onStart = function(world, actor, act, obj)
        local s = Ph.State(world)
        local call = s.incoming
        if not call then return false, "They hung up." end
        s.incoming = nil
        stopRinging(world)
        sfx(RD.sfx.pickup)
        actor.carry = "phone"
        local dur, outcome = Ph.Answer(world, actor, call)
        act.need, act.data.outcome = math.max(1, dur or 3), outcome
        act.pose = "phone"
        actor.balloon = { kind = "speech", icon = "bubble", untilT = world.time + act.need }
    end,
    onTick = function(world, actor, act, obj, dt)
        if act.data.outcome == "chat" then
            local frac = math.min(dt, math.max(0, act.need - act.t)) / act.need
            SS.Needs.Add(actor, "social", 30 * frac)
            SS.Needs.Add(actor, "fun", 8 * frac)
        elseif act.data.outcome == "news" or act.data.outcome == "invite" then
            SS.Needs.Add(actor, "social", 10 * math.min(dt, math.max(0, act.need - act.t)) / act.need)
        end
        if act.t + dt >= (act.need or 3) then act.complete = true end
    end,
    onEnd = function(world, actor, act)
        if actor.carry == "phone" then actor.carry = nil end
        sfx(RD.sfx.hangup)
    end,
}
SS.Tags.Attach("phone", "phone_answer")
-- every phone design gets the visitors work slot "svc" (its own front slot, grouped, when it has one:
-- see SS.Visitors.EnsureSlot), the same name a repair worker uses, so the two never share a spot
function Ph.EnsureSlots()
    for _, def in pairs(SS.Objects) do if SS.Tags.Has(def, "phone") then V.EnsureSlot(def, "svc") end end
end
Ph.EnsureSlots()

-- Household members hurry to a ringing phone (a strong autonomy candidate while it rings).
SS.Actions.RegisterCandidates(function(world, actor, cands)
    local s = Ph.State(world)
    if not s.incoming or not V.IsMember(world, actor) or (actor.kind or "human") ~= "human" or actor.age == "infant" then return end
    for _, o in ipairs(Ph.Phones(world, actor)) do
        if o.state and o.state.ringing then
            local key = o.id .. ":phone_answer"
            local cool = actor.cool and actor.cool[key]
            local d = math.abs(o.x + 0.5 - actor.x) + math.abs(o.y + 0.5 - actor.y)
            local sc = 60 / (1 + d * 0.03)
            if (not cool or cool <= world.time) and sc > 12 then
                -- only one member walks to it: skip if someone else is already going
                for _, b in pairs(world.actors) do
                    if b ~= actor and ((b.act and b.act.iid == "phone_answer") or (b.queue and b.queue[1] and b.queue[1].iid == "phone_answer")) then return end
                end
                V.EnsureSlot(SS.Objects[o.def], "svc")
                if SS.Actions.Available(world, actor, o, "phone_answer") then
                    cands[#cands + 1] = { oid = o.id, iid = "phone_answer", s = sc }
                end
            end
            return
        end
    end
end)

-- remember which need-critical action was interrupted (for the badly timed call)
SS.On("actionEnded", function(actor, act, status)
    if actor and act and status == "cancelled" and not actor.role then
        actor.tmp = actor.tmp or {}
        actor.tmp.interrupted = { iid = act.iid, t = SS.Sim.world and SS.Sim.world.time or 0 }
    end
end)

function Ph.Tick(world, dt)
    local s = world.root.phone
    local call = s and s.incoming
    if call and call.lotId == world.lot.id and world.time >= (call.untilT or 0) then
        -- nobody picked up in time (someone mid-walk to the phone keeps it ringing a little longer)
        for _, a in pairs(world.actors) do
            if a.act and a.act.iid == "phone_answer" and a.act.phase ~= "perform" and world.time < call.untilT + 2 then return end
        end
        Ph.Missed(world)
    end
end

function Ph.Attach(world)
    Ph.EnsureSlots()
    local s = Ph.State(world)
    -- a call ringing when the game was saved has hung up by the time it loads: recorded as missed
    if s.incoming then
        local call = s.incoming
        s.incoming = nil
        s.missed[#s.missed + 1] = { t = call.at or world.time, from = call.from, kind = call.kind, hh = call.hh }
        while #s.missed > PT.missedCap do table.remove(s.missed, 1) end
    end
    for _, o in pairs(world.lot.objects) do if isPhone(o) then
        if o.state and (o.state.ringing or o.state.inUse) then o.state.ringing, o.state.inUse = nil, nil end
        o.ringUntil = nil
    end end
end
function Ph.Detach(world)
    if SS.Audio and SS.Audio.StopLoop then SS.Audio.StopLoop("phone") end
end

SS.Sim.Register({ name = "phone", order = 42, tick = Ph.Tick, hour = Ph.Hour, attach = Ph.Attach, detach = Ph.Detach })

---------------------------------------------------------------------------------------------------
-- Built-in calls
local function money(v) return U.fmtMoney(v) end

local function serviceCall(kind, order)
    local S = RD.services[kind]
    Ph.RegisterCall({
        id = "svc_" .. kind, label = S.label, category = "Services", order = order,
        desc = S.desc .. " Call-out " .. money(S.callout) .. ", then " .. money(S.rate) .. " an hour.",
        test = function(world, caller) return Sv.CanCall(world, kind, caller) end,
        run = function(world, caller) local ok, msg = Sv.Call(world, kind, caller); return ok, msg end,
    })
    if S.regular then
        Ph.RegisterCall({
            id = "svc_" .. kind .. "_daily", category = "Services", order = order + 1,
            label = "Daily " .. S.label,
            labelFn = function(world) return Sv.Booking(world, kind) and ("Stop the Daily " .. S.label) or ("Book a Daily " .. S.label) end,
            desc = "A regular visit every morning, paid per visit. Days with nothing to do cost nothing.",
            test = function(world, caller)
                if not V.HomeLot(world) then return false, "Regular services only come to your own home." end
                if not Sv.CanPay(caller) then return false, "Only a teen or an adult can book regular help." end
                return true
            end,
            run = function(world, caller)
                if Sv.Booking(world, kind) then return Sv.Unbook(world, kind, caller) end
                return Sv.Book(world, kind, nil, caller)
            end,
        })
    end
end
serviceCall("cleaner", 10)
serviceCall("repair", 20)
serviceCall("gardener", 30)

Ph.RegisterCall({
    id = "svc_food", label = "Order Food Delivery", category = "Services", order = 40,
    desc = RD.services.food.desc .. " Delivery fee " .. money(RD.services.food.fee) .. ".",
    test = function(world, caller, arg)
        local ok, why = Sv.CanCall(world, "food", caller, { menu = arg or RD.menu[1].id })
        if not ok and not arg and why and why:find("menu") then return true end
        return ok, why
    end,
    options = function(world, caller)
        local out = {}
        for _, m in ipairs(RD.menu) do
            local ok, why = Sv.CanCall(world, "food", caller, { menu = m.id })
            out[#out + 1] = { label = m.name .. "  " .. money(m.price + RD.services.food.fee), arg = m.id, desc = m.desc .. " Serves " .. m.servings .. ".",
                disabled = not ok, reason = why }
        end
        return out
    end,
    run = function(world, caller, arg) local ok, msg = Sv.Call(world, "food", caller, { menu = arg }); return ok, msg end,
})

Ph.RegisterCall({
    id = "svc_cancel", label = "Cancel a Booking", category = "Services", order = 90,
    desc = "Cancel a service before the worker reaches your door. No charge.",
    test = function(world, caller)
        if not Sv.CanPay(caller) then return false, "Only a teen or an adult can change the bookings." end
        for _, v in ipairs(Sv.Expected(world)) do if not v.committed then return true end end
        return false, "Nothing is booked that can still be cancelled."
    end,
    options = function(world)
        local out = {}
        for _, v in ipairs(Sv.Expected(world)) do
            local S = RD.services[v.kind]
            out[#out + 1] = { label = S.label .. " (" .. V.ClockText(v.at) .. ")", arg = v.id,
                disabled = v.committed and true or nil, reason = v.committed and "Already here: use Send Home." or nil }
        end
        return out
    end,
    run = function(world, caller, arg) return Sv.Cancel(world, arg) end,
})

-- Friends: invite over, or just chat.
-- The phone book: people the household has met (V.Knows) can be invited or rung for a chat; the
-- rest of the street is listed greyed out with the reason (say hello when they walk past first).
local NOT_MET = "You haven't met them yet. Say hello when they walk past, or invite them over from the street."
local function friendOptions(world, caller, why0)
    local out = {}
    for _, e in ipairs(V.KnownPeople(world, 12)) do
        local r = e.r
        local ok, why = V.Available(world, r)
        if ok and not V.Knows(world, r.id) then ok, why = false, NOT_MET end
        out[#out + 1] = { label = r.name, arg = r.id, desc = r.bio, disabled = not ok, reason = why }
    end
    return out
end
local function knownTest(world, caller, arg)
    if arg and not V.Knows(world, arg) then return false, NOT_MET end
    return true
end
Ph.RegisterCall({
    id = "friend_invite", label = "Invite Someone Over", category = "Friends", order = 10,
    desc = "Ask a friend or neighbour to visit. They arrive within the hour if they can make it.",
    dur = 5,
    test = function(world, caller, arg)
        if not V.HomeLot(world) then return false, "You can only invite people to your own home." end
        return knownTest(world, caller, arg)
    end,
    options = friendOptions,
    run = function(world, caller, arg)
        local ok, msg = V.Invite(world, caller, arg)
        return ok, msg
    end,
})
Ph.RegisterCall({
    id = "friend_chat", label = "Chat on the Phone", category = "Friends", order = 20,
    desc = "A long natter. Good for Social; the other person enjoys it too.",
    dur = PT.chatLen, gain = { social = 35, fun = 8 },
    test = knownTest,
    options = friendOptions,
    run = function(world, caller, arg)
        local r = arg and world.root.residents[arg]
        if not r then return false, "Nobody answered." end
        if r.dead then return false, "Nobody answered." end
        V.RelChange(world, caller.id, r.id, RD.tuning.rel.chat)
        V.RelChange(world, r.id, caller.id, RD.tuning.rel.chat)
        return true, caller.name .. " had a good long chat with " .. r.name .. "."
    end,
})

Ph.RegisterCall({
    id = "other_paper", category = "Other", order = 10, label = "Newspaper",
    labelFn = function(world)
        local hh = world.household
        return (hh and hh.flags and hh.flags.noPaper) and "Restart the Newspaper" or "Stop the Newspaper"
    end,
    desc = "The morning paper is free. It brings the job listings; old papers pile up by the path until someone recycles them.",
    test = function(world) return world.household ~= nil, "No household here." end,
    run = function(world)
        local hh = world.household
        hh.flags = hh.flags or {}
        hh.flags.noPaper = not hh.flags.noPaper or nil
        return true, hh.flags.noPaper and "The newspaper has been stopped." or "The newspaper will come again every morning."
    end,
})

SS.Save.RegisterValidator(function(root, p)
    if root.phone ~= nil and type(root.phone) ~= "table" then root.phone = nil; p[#p + 1] = "phone records reset" end
    local s = root.phone
    if s then
        if type(s.missed) ~= "table" then s.missed = {} end
        while #s.missed > PT.missedCap do table.remove(s.missed, 1) end
        if s.incoming ~= nil and type(s.incoming) ~= "table" then s.incoming = nil end
        s.nextId = tonumber(s.nextId) or 1
    end
    return true
end)
