-- SideStreet travel between lots: the destination choice, the taxi, the outing clock and the trip
-- home. Owner: outings module (docs/modules/outings.md).
--
-- Time policy (shown in help): while the household is out, the home lot's clock and schedule are
-- frozen and nothing there is simulated. The outing runs on its own clock (root.outing.time). On the
-- way home the home clock resumes exactly where it stopped; the people who went out keep what
-- happened to them (needs, relationships, purchases, money spent).
--
-- A trip: call a taxi (the phone or the Go Out screen) -> the taxi pulls up at the curb -> the chosen
-- residents walk out and board (bounded retries and a deadline) -> the lot transition runs outside
-- the simulation step (Tr.Flush) -> they step out at the venue. Coming home is the same in reverse.
local _, SS = ...
local VD = SS.VenueData
local T = VD.tuning
local U = SS.U
local V = SS.Venues
local Tr = SS.Travel or {}
SS.Travel = Tr

Tr.POLICY = {
    "Going out: pick a venue and who goes. A taxi collects them from the curb.",
    "While the household is out, home is frozen: its clock, schedule, bills, work and visitors wait, and nobody left at home is simulated.",
    "The outing has its own clock. Coming home, the home clock carries on from the moment you left.",
    "Residents keep what happened while out: needs, friendships, purchases and money spent.",
}
Tr.POLICY_SHORT = "Home is frozen while you're out; its clock resumes when you get back."

local function rootOf(x) return x and (x.root or x) end
local function copyList(t) local o = {}; for n, v in ipairs(t or {}) do o[n] = v end; return o end
-- Put a person record at a lot's entry cell (used when nobody may be left in limbo).
local function placeAtEntry(root, r, lotId)
    local lot = root.hood.lots[lotId]
    if not lot then return end
    local e = lot.entry or { math.floor(lot.w / 2), lot.h - 1 }
    r.lotId, r.x, r.y, r.level = lotId, e[1] + 0.5, e[2] + 0.5, 0
    r.away, r.role, r.roleData = nil, nil, nil
end

function Tr.OnOuting(world) return rootOf(world).outing ~= nil end
function Tr.IsVenue(world) return world and world.lot and world.lot.kind == "community" or false end
function Tr.Outing(world) return rootOf(world).outing end
function Tr.AudioMode(world) return V.Active(world) and V.AudioMode(world) or nil end

function Tr.Record(root)
    root = rootOf(root)
    root.travel = root.travel or { nextId = 1, history = {} }
    root.travel.history = root.travel.history or {}
    root.travel.nextId = root.travel.nextId or 1
    return root.travel
end

function Tr.Pending(world)
    local tr = rootOf(world).travel
    return tr and tr.pending
end

local function history(root, entry)
    local tr = Tr.Record(root)
    tr.history[#tr.history + 1] = entry
    while #tr.history > 12 do table.remove(tr.history, 1) end
end

---------------------------------------------------------------------------------------------------
-- Who can go
function Tr.CanTravel(world, r)
    if not r then return false, "Nobody by that name." end
    if r.dead or r.ghost then return false, r.name .. " has passed away." end
    if (r.kind or "human") ~= "human" then return false, "Pets stay home and mind the house." end
    if r.age == "infant" then return false, "Babies stay home with a grown-up." end
    if r.lotId ~= world.lot.id or not world.actors[r.id] then return false, r.name .. " isn't here right now." end
    if r.away then return false, r.name .. " is away." end
    if r.role then return false, r.name .. " is busy." end
    return true
end

-- Household members on this lot with a yes/no and a reason each.
function Tr.Candidates(world)
    local out = {}
    local root = rootOf(world)
    for _, rid in ipairs(world.household and world.household.members or {}) do
        local r = root.residents[rid]
        local ok, why = Tr.CanTravel(world, r)
        out[#out + 1] = { rid = rid, name = r and r.name or rid, ok = ok, why = why, age = r and r.age or "adult" }
    end
    return out
end

-- People who could be invited along (not in the household), warmest relationship first.
function Tr.GuestCandidates(world, hostRid, max)
    local root = rootOf(world)
    local out = {}
    for _, rid in ipairs(V.SortedKeys(root.residents)) do
        local r = root.residents[rid]
        if r.householdId ~= (world.household and world.household.id) and not r.npc then
            local ok, why = V.CanVisit(world, r)
            if ok or (not r.dead and not r.npc and (r.kind or "human") == "human") then
                local rel = 0
                if hostRid and SS.Social and SS.Social.Rel then
                    local x = SS.Social.Rel(world, hostRid, rid)
                    rel = math.floor((x.daily or 0) * 0.6 + (x.life or 0) * 0.4)
                end
                if not r.dead and (r.kind or "human") == "human" and r.age ~= "infant" then
                    out[#out + 1] = { rid = rid, name = r.name, rel = rel, ok = ok, why = why }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.ok ~= b.ok then return a.ok end
        if a.rel ~= b.rel then return a.rel > b.rel end
        return a.rid < b.rid
    end)
    if max then while #out > max do table.remove(out) end end
    return out
end

-- Venue lots with their public information (adds the four standard venues to a neighbourhood
-- that has none: pre-integration saves).
function Tr.Destinations(world)
    local root = rootOf(world)
    V.EnsureLots(root)
    local out = {}
    for _, id in ipairs(V.List(root)) do
        local info = V.LotInfo(root, id)
        info.openAtArrival = V.IsOpen(info.kind, (world.time or 0) + T.taxiWait + T.ride)
        out[#out + 1] = info
    end
    return out
end

-- Can this group go to that venue now? Returns ok, why.
function Tr.CanGo(world, rids, lotId, opts)
    opts = opts or {}
    local root = rootOf(world)
    if root.outing then return false, "The household is already out. Go home first; every trip starts from home." end
    if Tr.Pending(world) then return false, "A taxi is already on its way." end
    if world.lot.kind == "community" then return false, "Trips start from home." end
    if world.editVenue then return false, "Not while editing a venue." end
    if SS.Fire and SS.Fire.Active and SS.Fire.Active(world) then return false, "Not while the house is on fire!" end
    local lot = root.hood.lots[lotId]
    local kind = V.Kind(lot)
    if not kind then return false, "Pick a venue to visit." end
    local ok, problems = V.Verdict(root, lotId)
    if not ok then return false, (lot.name or "That venue") .. " is closed for repairs: " .. (problems[1] or "it is missing staff or service points.") end
    local arrive = (world.time or 0) + T.taxiWait + T.ride
    if not V.IsOpen(kind, arrive) then return false, (lot.name or "That venue") .. " is closed then (" .. V.HoursText(kind) .. ")." end
    if type(rids) ~= "table" or #rids == 0 then return false, "Choose who is going." end
    if #rids > T.maxParty then return false, "A taxi takes at most " .. T.maxParty .. " people." end
    local going, adults, kids = {}, 0, 0
    for _, rid in ipairs(rids) do
        local r = root.residents[rid]
        if not r or r.householdId ~= (world.household and world.household.id) then return false, "Only your household can be sent out." end
        local can, why = Tr.CanTravel(world, r)
        if not can then return false, why end
        if kind == "club" and r.age == "child" then return false, "The Gramophone Room is for grown-ups; " .. r.name .. " stays home." end
        going[rid] = true
        if r.age == "child" then kids = kids + 1 else adults = adults + 1 end
    end
    if kids > 0 and adults == 0 then return false, "Children need a grown-up with them." end
    -- a baby at home needs a grown-up at home
    local babyHome, adultHome = false, false
    for _, rid in ipairs(world.household.members or {}) do
        local r = root.residents[rid]
        if r and not r.dead and r.lotId == world.lot.id and not going[rid] then
            if r.age == "infant" then babyHome = true
            elseif r.age == "adult" and (r.kind or "human") == "human" and not r.away then adultHome = true end
        end
    end
    if babyHome and not adultHome then return false, "Someone grown-up has to stay home with the baby." end
    -- the family module's welfare rule (an infant never alone, a child not alone at night)
    local Fam = SS.Family
    if Fam and type(Fam.CanLeave) == "function" then
        local okL, can, why = pcall(Fam.CanLeave, world, rids)
        if okL and can == false then return false, why or "Someone has to stay home." end
    end
    local guests = opts.guests or {}
    if #guests > T.maxGuests then return false, "You can invite " .. T.maxGuests .. " person to meet you there." end
    for _, gid in ipairs(guests) do
        local g = root.residents[gid]
        if going[gid] then return false, "Guests come from outside the household." end
        local here = g and world.actors[gid] ~= nil and g.lotId == world.lot.id
        local can, why = V.CanVisit(world, g, kind, here and { rideAlong = true } or nil)
        if not can then return false, why end
    end
    return true
end

-- Split a people list into household members and outsiders (who come as guests).
function Tr.SplitParty(world, rids)
    local root = rootOf(world)
    local members, others = {}, {}
    local hid = world.household and world.household.id
    for _, rid in ipairs(rids or {}) do
        local r = root.residents[rid]
        if r and hid and r.householdId ~= hid then others[#others + 1] = rid else members[#members + 1] = rid end
    end
    return members, others
end

---------------------------------------------------------------------------------------------------
-- Taxi (the street's vehicle list is drawn by the renderer; visitors owns it)
local function taxiArrive(world, trip)
    local St = SS.Street
    if St.CallVehicle then
        local ok, v = pcall(St.CallVehicle, world, "taxi", { owner = "outings", hold = true, wait = T.taxiBoardLimit + 10, expect = #trip.rids })
        if ok and v then Tr.vehicle = v; return end
    end
    St.vehicles = St.vehicles or {}
    local ei = St.EntryCell(world)
    local v = { kind = "taxi", i = ei, state = "parked", t = 0, owner = "outings", len = 2 }
    St.vehicles[#St.vehicles + 1] = v
    Tr.vehicle = v
end

local function taxiLeave(world)
    local v = Tr.vehicle
    Tr.vehicle = nil
    if not v then return end
    local St = SS.Street
    if St.ReleaseVehicle and v.id then pcall(St.ReleaseVehicle, world, v); return end
    local list = St.vehicles or {}
    for n = #list, 1, -1 do if list[n] == v then table.remove(list, n) end end
end

---------------------------------------------------------------------------------------------------
-- Calling a taxi
local function newTrip(world, kind, rids, dest, reason)
    local root = rootOf(world)
    local tr = Tr.Record(root)
    local id = "trip" .. tr.nextId
    tr.nextId = tr.nextId + 1
    local trip = {
        id = id, kind = kind, from = world.lot.id, dest = dest, householdId = world.household and world.household.id,
        rids = copyList(rids), boarded = {}, left = {}, tries = {}, calledAt = world.time,
        taxiAt = world.time + T.taxiWait, state = "waiting", reason = reason,
    }
    tr.pending = trip
    return trip
end

-- Send residents out. opts = { guests = {rid}, date = bool (the first guest is a date for rids[1]),
-- host = rid, instant = bool (taxi already at the curb; used by tests and the debug path) }.
-- Returns ok, message.
function Tr.Go(world, rids, lotId, opts)
    opts = opts or {}
    -- someone from outside the household in the list (the social module's "Invite on an Outing"
    -- passes { host, friend }) comes as a guest who has already said yes
    local members, others = Tr.SplitParty(world, rids)
    local accepted = {}
    if #others > 0 then
        local o2 = {}
        for k, v in pairs(opts) do o2[k] = v end
        o2.guests = copyList(opts.guests)
        for _, gid in ipairs(others) do o2.guests[#o2.guests + 1] = gid; accepted[gid] = true end
        opts, rids = o2, members
    end
    local ok, why = Tr.CanGo(world, rids, lotId, opts)
    if not ok then return false, why end
    local root = rootOf(world)
    local lot = root.hood.lots[lotId]
    local trip = newTrip(world, "out", rids, lotId)
    trip.guests = {}
    local host = opts.host or rids[1]
    local msgs = {}
    for _, gid in ipairs(opts.guests or {}) do
        local g = root.residents[gid]
        local yes, stoodUp = V.InviteRoll(world, host, gid)
        local ride = world.actors[gid] ~= nil and g.lotId == world.lot.id
        if opts.forceAccept or accepted[gid] or ride then yes, stoodUp = true, false end
        if opts.forceStoodUp then yes, stoodUp = true, true end
        local delay = SS.RandomInt(world, "outings.guest", T.guestDelay[1], T.guestDelay[2])
        if ride then delay = 0 end
        local entry = { rid = gid, with = host, date = opts.date and true or false, delay = delay, ride = ride or nil }
        local accepted = yes
        if accepted and not stoodUp then entry.state = "coming"
        elseif accepted then entry.state = "stood_up"
        else entry.state = "declined" end
        trip.guests[#trip.guests + 1] = entry
        if entry.state == "declined" then msgs[#msgs + 1] = g.name .. " can't make it this time."
        elseif ride then msgs[#msgs + 1] = g.name .. " is coming along."
        else msgs[#msgs + 1] = g.name .. " will meet you there." end
        if opts.date and entry.state ~= "declined" and not trip.date then trip.date = { by = host, with = gid } end
    end
    if opts.instant then trip.taxiAt = world.time end
    local names = {}
    for _, rid in ipairs(rids) do names[#names + 1] = root.residents[rid].name end
    local msg = string.format("Taxi called to %s for %s. It arrives in %d minutes.", lot.name or lotId, table.concat(names, ", "),
        math.max(0, math.floor(trip.taxiAt - world.time)))
    if #msgs > 0 then msg = msg .. " " .. table.concat(msgs, " ") end
    V.Notice(world, msg)
    SS.Emit("taxiCalled", world, trip)
    return true, msg
end

-- Take everybody home from the venue. opts = { instant = bool, reason = text }.
function Tr.GoHome(world, opts)
    opts = opts or {}
    local root = rootOf(world)
    local o = root.outing
    if not o or o.lotId ~= world.lot.id then return false, "Nobody is out on a trip." end
    local pending = Tr.Pending(world)
    if pending then
        if pending.kind == "home" then
            if opts.instant and pending.state ~= "ready" then Tr.BoardAll(world, pending) end
            return true, "The taxi home is already on its way."
        end
        return false, "A taxi is already on its way."
    end
    local rids = {}
    for _, rid in ipairs(o.participants or {}) do if world.actors[rid] then rids[#rids + 1] = rid end end
    local trip = newTrip(world, "home", rids, o.homeLotId, opts.reason)
    if opts.instant then
        trip.taxiAt = world.time
        Tr.BoardAll(world, trip)
    end
    V.Notice(world, opts.instant and "Heading home now." or ("Taxi home called. It arrives in " .. T.taxiWait .. " minutes."))
    SS.Emit("taxiCalled", world, trip)
    return true
end

-- Cancel a taxi that hasn't left: anyone already in it steps back out at the curb.
function Tr.Cancel(world)
    local root = rootOf(world)
    local trip = Tr.Pending(world)
    if not trip then return false, "No taxi to cancel." end
    if trip.from ~= world.lot.id then return false, "That taxi is somewhere else." end
    if trip.state == "ready" then return false, "Too late: the taxi is pulling away." end
    local ei, ej = SS.Street.EntryCell(world)
    for _, rid in ipairs(trip.boarded) do
        local r = root.residents[rid]
        if r and not r.dead and not r.lotId then
            r.away = nil
            SS.Sim.AddActor(world, rid, ei, ej, 0)
        end
    end
    root.travel.pending = nil
    taxiLeave(world)
    history(root, { id = trip.id, kind = trip.kind, from = trip.from, dest = trip.dest, at = world.time, result = "cancelled" })
    V.Notice(world, "Taxi cancelled.")
    SS.Emit("taxiCancelled", world, trip)
    return true
end

---------------------------------------------------------------------------------------------------
-- Boarding (runs on the lot the taxi is waiting at)
local function board(world, trip, rid)
    local a = world.actors[rid]
    if not a then return end
    if a.act then SS.Actions.Finish(world, a, "cancelled", "Left in a taxi.") end
    SS.Sim.RemoveActor(world, rid, { reason = "travel", lotId = trip.from, data = { trip = trip.id } })
    a.doing, a.orders = nil, nil
    trip.boarded[#trip.boarded + 1] = rid
    if Tr.vehicle and SS.Street.BoardOne and Tr.vehicle.id then pcall(SS.Street.BoardOne, world, Tr.vehicle, a) end
end

-- Is the curb reachable for this actor by the lot's rules (walls, locks, staff and visiting
-- permissions, fire), people aside? Walks that keep failing only because family members stand in
-- a narrow way still end in the taxi: the traveller squeezes past. A curb shut off by walls or rules
-- does not.
function Tr.CurbOpen(world, a)
    local Nav = SS.Nav
    if not (a and Nav and Nav.FindPath) then return false end
    local ei, ej = SS.Street.EntryCell(world)
    local ok, path = pcall(Nav.FindPath, world, math.floor(a.x), math.floor(a.y), a.level or 0, { { ei, ej, 0 } }, a, { force = true })
    return ok and path ~= nil
end

local function resolved(trip, rid)
    for _, id in ipairs(trip.boarded) do if id == rid then return true end end
    for _, id in ipairs(trip.left) do if id == rid then return true end end
    return false
end

-- Everyone gets in now (the "leave right now" path and the trip home at its deadline).
function Tr.BoardAll(world, trip)
    for _, rid in ipairs(trip.rids) do
        if not resolved(trip, rid) then
            if world.actors[rid] then board(world, trip, rid) else trip.left[#trip.left + 1] = rid end
        end
    end
    trip.state = "ready"
    Tr.RequestFlush()
end

local function finishBoarding(world, trip)
    local root = rootOf(world)
    if #trip.boarded == 0 then
        root.travel.pending = nil
        taxiLeave(world)
        history(root, { id = trip.id, kind = trip.kind, from = trip.from, dest = trip.dest, at = world.time, result = "nobody boarded" })
        V.Notice(world, "The taxi left empty: nobody made it to the curb.")
        SS.Emit("taxiCancelled", world, trip)
        return
    end
    trip.state = "ready"
    Tr.RequestFlush()
end

function Tr.Tick(world, dt)
    local root = rootOf(world)
    local trip = root.travel and root.travel.pending
    if not trip or trip.from ~= world.lot.id or trip.state == "ready" then return end
    if trip.state == "waiting" then
        if world.time < trip.taxiAt then return end
        trip.state = "boarding"
        trip.deadline = world.time + T.taxiBoardLimit
        taxiArrive(world, trip)
        for _, rid in ipairs(trip.rids) do
            local a = world.actors[rid]
            if a then
                a.queue = {}
                if a.act then SS.Actions.Cancel(world, a, 0) end
            end
        end
        V.Notice(world, "The taxi is at the curb.")
    end
    local ei, ej = SS.Street.EntryCell(world)
    local pending = 0
    for _, rid in ipairs(trip.rids) do
        if not resolved(trip, rid) then
            local a = world.actors[rid]
            if not a then
                trip.left[#trip.left + 1] = rid
            else
                local ci, cj = math.floor(a.x), math.floor(a.y)
                local near = math.abs(ci - ei) + math.abs(cj - ej) <= 1 and (a.level or 0) == 0
                if near and not (a.act and a.act.phase == "exit") then
                    board(world, trip, rid)
                else
                    pending = pending + 1
                    if not a.act or (a.act.iid ~= "goto" and a.act.phase ~= "exit") then
                        if a.act and a.act.iid ~= "goto" then SS.Actions.Cancel(world, a, 0) end
                        local tries = trip.tries[rid] or 0
                        if not a.act then
                            if tries >= T.boardRetries then
                                if trip.kind == "home" or Tr.CurbOpen(world, a) then board(world, trip, rid); pending = pending - 1
                                else
                                    trip.left[#trip.left + 1] = rid
                                    pending = pending - 1
                                    V.Notice(world, a.name .. " couldn't get to the taxi and stays behind.")
                                end
                            else
                                trip.tries[rid] = tries + 1
                                a.queue = {}
                                SS.Actions.Order(world, a, nil, "goto", ei, ej, { level = 0 })
                            end
                        end
                    end
                end
            end
        end
    end
    if pending > 0 and world.time >= (trip.deadline or 0) then
        for _, rid in ipairs(trip.rids) do
            if not resolved(trip, rid) then
                local a = world.actors[rid]
                if trip.kind == "home" and a then board(world, trip, rid)
                else
                    trip.left[#trip.left + 1] = rid
                    if a then V.Notice(world, a.name .. " missed the taxi.") end
                end
            end
        end
        pending = 0
    end
    if pending <= 0 then finishBoarding(world, trip) end
end

---------------------------------------------------------------------------------------------------
-- The lot transition (never inside Sim.Step: Tr.RequestFlush defers it to the next frame).
function Tr.RequestFlush()
    Tr.flushWanted = true
    if Tr.driver then Tr.driver:Show(); return end
    local CF = rawget(_G, "CreateFrame")
    if not CF then return end
    local f = CF("Frame")
    f:SetScript("OnUpdate", function(self)
        if Tr.flushWanted then Tr.Flush() end
        if not Tr.flushWanted then self:Hide() end
    end)
    Tr.driver = f
end

local function refreshUI(world)
    local UI = SS.UI
    if not UI or not UI.frame then return end
    local o = rootOf(world).outing
    local first
    for _, rid in ipairs(o and o.participants or (world.household and world.household.members) or {}) do
        if world.actors[rid] and not first then first = rid end
    end
    if first then UI.selected = first end
    UI.dirty = true
    for _, fn in ipairs({ "RefreshPortrait", "RefreshPortraits", "RefreshToolbar", "RefreshPanel", "CenterOnSelected" }) do
        if type(UI[fn]) == "function" then pcall(UI[fn]) end
    end
    if UI.mode and UI.mode ~= "live" and UI.SetMode then pcall(UI.SetMode, "live") end
end

-- Park unbound scheduled events on the home lot while out; they come back untouched.
local function holdEvents(root, homeLotId)
    for _, ev in ipairs(root.scheduled or {}) do
        if ev.lotId == nil then ev.lotId, ev.outingHold = homeLotId, true end
    end
end

-- Coming home: held events are released, events bound to the venue end with the visit, and
-- unbound events created during the outing keep their delay on the home clock.
function Tr.ReleaseEvents(root, o)
    local s = root.scheduled or {}
    for n = #s, 1, -1 do
        local ev = s[n]
        if ev.outingHold then
            ev.lotId, ev.outingHold = nil, nil
        elseif ev.lotId == o.lotId then
            table.remove(s, n)
        elseif ev.lotId == nil then
            ev.at = (o.startedAt or root.time) + math.max(0, ev.at - (o.time or ev.at))
        end
    end
    table.sort(s, function(a, b) return a.at < b.at end)
end

-- The home as it is left: a compact fingerprint of the home lot (V.LotPrint) and of everyone who
-- stays there (place and needs), kept in the outing record. The return compares it, so the rule
-- "nothing at home is simulated while the household is out" is checked on every trip.
function Tr.HomeDigest(root, lotId)
    local lot = root.hood.lots[lotId]
    local ln, lsum = 0, 0
    if lot then ln, lsum = V.LotPrint(lot) end
    local pn, psum = 0, 0
    for _, rid in ipairs(V.SortedKeys(root.residents)) do
        local r = root.residents[rid]
        if r.lotId == lotId and not r.dead then
            pn = pn + 1
            local v = (r.x or 0) * 97 + (r.y or 0) * 89 + (r.level or 0) * 7
            for _, need in ipairs(SS.Tuning.needs) do v = v + (r.needs and r.needs[need] or 0) * 3 end
            psum = psum + v * pn
        end
    end
    return { lotN = ln, lotSum = lsum, people = pn, peopleSum = psum }
end

local function sameDigest(a, b)
    if not (a and b) then return true end
    local what = {}
    if a.lotN ~= b.lotN or math.abs(a.lotSum - b.lotSum) > 1e-6 then what[#what + 1] = "the home lot" end
    if a.people ~= b.people or math.abs(a.peopleSum - b.peopleSum) > 1e-6 then what[#what + 1] = "the people at home" end
    return #what == 0, table.concat(what, " and ")
end

function Tr.DoDepart(world, trip)
    local root = rootOf(world)
    local hh = root.households[trip.householdId]
    Tr.transitioning = true
    -- the saved game is written as it stands at the moment of leaving (the authoritative state),
    -- and the home's fingerprint goes into the outing record (compared on the way back)
    if SS.Boot and SS.Boot.Checkpoint then pcall(SS.Boot.Checkpoint) end
    taxiLeave(world)
    -- a guest who was visiting rides along: they leave the home lot now (back to their own home
    -- record) and step out of the taxi with the party
    for _, g in ipairs(trip.guests or {}) do
        local a = g.ride and world.actors[g.rid]
        if a then
            if a.role and SS.Visitors and SS.Visitors.Leave then pcall(SS.Visitors.Leave, world, a, "outing", { immediate = true }) end
            if world.actors[g.rid] then SS.Sim.RemoveActor(world, g.rid, nil) end
            a.role, a.roleData, a.away = nil, nil, nil
            local ghh = a.householdId and root.households[a.householdId]
            if ghh and ghh.lotId and root.hood.lots[ghh.lotId] and ghh.lotId ~= trip.from then placeAtEntry(root, a, ghh.lotId)
            else a.lotId = nil end
        end
    end
    holdEvents(root, trip.from)
    local o = {
        id = "out_" .. trip.id, lotId = trip.dest, homeLotId = trip.from, householdId = trip.householdId,
        time = root.time + T.ride, startedAt = root.time, participants = copyList(trip.boarded),
        guests = {}, score = 50, venue = root.hood.lots[trip.dest].venue,
        home = { money = hh and hh.money or 0, time = root.time }, arrivedAt = root.time + T.ride, log = {},
    }
    for _, g in ipairs(trip.guests or {}) do
        if g.state ~= "declined" then
            o.guests[#o.guests + 1] = { rid = g.rid, with = g.with, date = g.date, state = g.state, arriveAt = o.time + (g.delay or 15) }
        end
    end
    if trip.date then o.date = { by = trip.date.by, with = trip.date.with, score = 50, state = "waiting" } end
    -- (the party has left the home lot by now: their records are in the taxi)
    o.home.digest = Tr.HomeDigest(root, trip.from)
    root.outing = o
    root.active = { householdId = trip.householdId, lotId = trip.dest }
    root.travel.pending = nil
    history(root, { id = trip.id, kind = "out", from = trip.from, dest = trip.dest, at = root.time, rids = copyList(trip.boarded), result = "departed" })
    local rec = V.Record(root, trip.dest)
    rec.visits, rec.lastVisit = rec.visits + 1, root.time
    local vw = SS.Sim.Attach(root, trip.dest, trip.householdId)
    local ei, ej = SS.Street.EntryCell(vw)
    local gi, gj = vw.lot.gather and vw.lot.gather[1] or ei, vw.lot.gather and vw.lot.gather[2] or (ej - 2)
    for n, rid in ipairs(o.participants) do
        local r = root.residents[rid]
        r.away = nil
        local a = SS.Sim.AddActor(vw, rid, ei, ej, 0)
        if a then
            local fi, fj = V.FreeNear(vw, gi + ((n - 1) % 3) - 1, gj - math.floor((n - 1) / 3), 0, 3)
            if fi then SS.Actions.Order(vw, a, nil, "goto", fi, fj, { level = 0 }) end
        end
    end
    Tr.transitioning = false
    V.Log(vw, "Arrived at " .. (vw.lot.name or "the venue") .. ".")
    refreshUI(vw)
    V.PlayAudio(vw)
    SS.Emit("outingStarted", vw, o)
    return true
end

-- Remove everyone who is not part of the household from the venue (staff off shift, patrons and
-- guests back to their own homes) and put any participant still on the lot into the taxi list.
local function clearVenue(world, o, boarded)
    local party, done = {}, {}
    for _, rid in ipairs(o.participants or {}) do party[rid] = true end
    for _, rid in ipairs(boarded) do done[rid] = true end
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a then
            if a.npc == "staff" then V.StaffOff(world, id)
            elseif party[id] and not done[id] then
                if a.act then SS.Actions.Finish(world, a, "cancelled", "Went home.") end
                SS.Sim.RemoveActor(world, id, { reason = "travel", lotId = world.lot.id })
                boarded[#boarded + 1] = id
            elseif a.roleData and a.roleData.home then V.SendHome(world, a)
            else
                SS.Sim.RemoveActor(world, id, { reason = "left" })
                a.role, a.roleData = nil, nil
            end
        end
    end
end

function Tr.DoReturn(world, trip)
    local root = rootOf(world)
    local o = root.outing
    Tr.transitioning = true
    if SS.Dining and SS.Dining.Settle then SS.Dining.Settle(world, "home") end
    if SS.Shopping and SS.Shopping.Settle then SS.Shopping.Settle(world, "home") end
    V.SettleTabs(world, "leave")
    V.Conclude(world)
    local boarded = copyList(trip.boarded)
    clearVenue(world, o, boarded)
    taxiLeave(world)
    Tr.ReleaseEvents(root, o)
    root.time = o.startedAt
    root.outing = nil
    root.active = { householdId = o.householdId, lotId = o.homeLotId }
    root.travel.pending = nil
    local hh = root.households[o.householdId]
    local spent = (o.home and o.home.money or 0) - (hh and hh.money or 0)
    history(root, { id = trip.id, kind = "home", from = o.lotId, dest = o.homeLotId, at = o.time, rids = copyList(boarded),
        result = "home", score = o.score, spent = spent, outing = o.id, venue = o.venue, verdict = o.verdict })
    Tr.lastOuting = o
    -- the home must be exactly as it was left (nothing simulated it while the household was out)
    local same, what = sameDigest(o.home and o.home.digest, Tr.HomeDigest(root, o.homeLotId))
    if not same then
        o.home.changed = what
        root.travel.history[#root.travel.history].homeChanged = what
        SS.Emit("homeChangedWhileOut", root, o, what)
    end
    local hw = SS.Sim.Attach(root, o.homeLotId, o.householdId)
    local ei, ej = SS.Street.EntryCell(hw)
    for n, rid in ipairs(boarded) do
        local r = root.residents[rid]
        if r and not r.dead then
            r.away = nil
            local a = SS.Sim.AddActor(hw, rid, ei, ej, 0)
            if a then
                local fi, fj = V.FreeNear(hw, ei + ((n - 1) % 3) - 1, ej - 1 - math.floor((n - 1) / 3), 0, 3)
                if fi then SS.Actions.Order(hw, a, nil, "goto", fi, fj, { level = 0 }) end
            end
        end
    end
    Tr.transitioning = false
    if o.home.changed and SS.Actions and SS.Actions.Journal and hw.journal then
        SS.Actions.Journal(hw, "While the household was out, " .. o.home.changed .. " changed; that should not happen (please report it).")
    end
    V.Notice(hw, string.format("Home again. Spent %s while out.", U.fmtMoney(math.max(0, spent))))
    refreshUI(hw)
    if SS.Audio and SS.Audio.SetMode and V.MusicOn(hw) then pcall(SS.Audio.SetMode, "live") end
    SS.Emit("outingEnded", hw, o)
    return true
end

function Tr.Flush()
    Tr.flushWanted = false
    local world = SS.Sim.world
    if not world then return false end
    local root = rootOf(world)
    local trip = root.travel and root.travel.pending
    if not trip or trip.state ~= "ready" or trip.from ~= world.lot.id then return false end
    if trip.kind == "out" then return Tr.DoDepart(world, trip) end
    return Tr.DoReturn(world, trip)
end

---------------------------------------------------------------------------------------------------
-- Consistency when another module attaches a different lot mid-trip or mid-outing (a household
-- switch from the neighbourhood, venue editing elsewhere): the outing ends safely, nobody is lost.

-- End an outing without its venue attached (data only). Participants go home; staff go off shift;
-- patrons and guests go back to their own homes; dining bills for food eaten are settled once.
function Tr.EndOutingOffline(root, reason)
    root = rootOf(root)
    local o = root.outing
    if not o then return end
    local lot = root.hood.lots[o.lotId]
    if lot and root.households[o.householdId] and SS.Sim.NewSession then
        local ok, sess = pcall(SS.Sim.NewSession, root, o.lotId, o.householdId)
        if ok and sess then
            if SS.Dining and SS.Dining.Settle then pcall(SS.Dining.Settle, sess, reason or "abandoned") end
            if SS.Shopping and SS.Shopping.Settle then pcall(SS.Shopping.Settle, sess, reason or "abandoned") end
            pcall(V.SettleTabs, sess, "leave")
            pcall(V.Conclude, sess)
        end
    end
    local party = {}
    for _, rid in ipairs(o.participants or {}) do party[rid] = true end
    for _, rid in ipairs(V.SortedKeys(root.residents)) do
        local r = root.residents[rid]
        if party[rid] then
            if not r.dead then placeAtEntry(root, r, o.homeLotId) end
        elseif r.lotId == o.lotId or (r.npc == "staff" and r.lotId) then
            if r.npc == "staff" then r.lotId, r.role, r.roleData, r.away = nil, nil, nil, nil
            elseif r.roleData and r.roleData.home then
                local h = r.roleData.home
                r.lotId, r.x, r.y, r.level, r.facing = h.lotId, h.x, h.y, h.level or 0, h.facing or 0
                r.noNeeds = r.roleData.prevNoNeeds or nil
                r.role, r.roleData, r.away = nil, nil, nil
            else
                r.lotId, r.role, r.roleData = nil, nil, nil
            end
        end
    end
    Tr.ReleaseEvents(root, o)
    root.time = o.startedAt or root.time
    root.outing = nil
    if root.active then root.active.lotId = o.homeLotId end
    history(root, { id = o.id, kind = "home", from = o.lotId, dest = o.homeLotId, at = o.time, result = reason or "abandoned" })
end

function Tr.OnAttach(world)
    if Tr.transitioning then return end
    local root = rootOf(world)
    local o = root.outing
    -- (any other lot attached mid-outing ends it safely; the hood refuses venue editing while the
    -- household is out, and it marks an edit session only after attaching, so no guard is needed)
    if o and o.lotId ~= world.lot.id then
        Tr.EndOutingOffline(root, "lot switched")
        if world.lot.id == o.homeLotId then
            for _, rid in ipairs(o.participants or {}) do
                local r = root.residents[rid]
                if r and r.lotId == world.lot.id and not world.actors[rid] then
                    SS.Sim.AddActor(world, rid, math.floor(r.x), math.floor(r.y), 0)
                end
            end
        end
    end
    local trip = root.travel and root.travel.pending
    if trip and trip.from ~= world.lot.id then
        for _, rid in ipairs(trip.boarded or {}) do
            local r = root.residents[rid]
            if r and not r.dead and not r.lotId then placeAtEntry(root, r, trip.from) end
        end
        root.travel.pending = nil
        history(root, { id = trip.id, kind = trip.kind, from = trip.from, dest = trip.dest, at = root.time, result = "cancelled (lot switched)" })
    elseif trip and trip.from == world.lot.id and trip.state ~= "waiting" then
        -- reattached mid-boarding (a load): riders step back out and the taxi pulls up again
        local ei, ej = SS.Street.EntryCell(world)
        for _, rid in ipairs(trip.boarded or {}) do
            local r = root.residents[rid]
            if r and not r.dead and (not r.lotId or r.lotId == world.lot.id) and not world.actors[rid] then
                r.away = nil
                SS.Sim.AddActor(world, rid, ei, ej, 0)
            end
        end
        trip.boarded, trip.left, trip.tries, trip.state, trip.taxiAt = {}, {}, {}, "waiting", world.time
    end
end

SS.Sim.Register({ name = "outings_travel", order = 55, tick = Tr.Tick, attach = Tr.OnAttach })

---------------------------------------------------------------------------------------------------
-- Save validation: repair outing and trip records so a load never strands anyone.
SS.Save.RegisterValidator(function(root, p)
    if root.travel ~= nil and type(root.travel) ~= "table" then root.travel = nil end
    if root.travel then
        local tr = root.travel
        tr.history = type(tr.history) == "table" and tr.history or {}
        while #tr.history > 12 do table.remove(tr.history, 1) end
        tr.nextId = type(tr.nextId) == "number" and tr.nextId or 1
        local trip = tr.pending
        if trip ~= nil and (type(trip) ~= "table" or not root.hood.lots[trip.from or ""] or not root.hood.lots[trip.dest or ""]) then
            tr.pending = nil
            p[#p + 1] = "dropped a damaged taxi trip"
        elseif trip then
            trip.rids = type(trip.rids) == "table" and trip.rids or {}
            -- a save taken mid-boarding: riders step back out at the curb; the taxi returns on load
            for _, rid in ipairs(type(trip.boarded) == "table" and trip.boarded or {}) do
                local r = root.residents[rid]
                if r and not r.dead and not r.lotId then placeAtEntry(root, r, trip.from) end
            end
            if trip.state ~= "waiting" then
                trip.state, trip.boarded, trip.left, trip.tries = "waiting", {}, {}, {}
                trip.taxiAt = root.time
                p[#p + 1] = "taxi boarding restarted"
            end
            trip.boarded = trip.boarded or {}
            trip.left = trip.left or {}
            trip.tries = trip.tries or {}
        end
    end
    if root.venues ~= nil and type(root.venues) ~= "table" then root.venues = nil end
    local o = root.outing
    if o ~= nil then
        local bad = type(o) ~= "table" or not root.hood.lots[o.lotId or ""] or not root.hood.lots[o.homeLotId or ""]
            or type(o.time) ~= "number" or not root.households[o.householdId or ""]
        if bad then
            if type(o) == "table" and root.hood.lots[o.homeLotId or ""] then
                o.startedAt = type(o.startedAt) == "number" and o.startedAt or root.time
                o.participants = type(o.participants) == "table" and o.participants or {}
                Tr.EndOutingOffline(root, "damaged save")
            else
                root.outing = nil
            end
            p[#p + 1] = "ended a damaged outing; everyone is home"
        else
            o.participants = type(o.participants) == "table" and o.participants or {}
            o.guests = type(o.guests) == "table" and o.guests or {}
            o.score = type(o.score) == "number" and o.score or 50
            o.startedAt = type(o.startedAt) == "number" and o.startedAt or root.time
            local keep = {}
            local lot = root.hood.lots[o.lotId]
            for _, rid in ipairs(o.participants) do
                local r = root.residents[rid]
                if r and not r.dead then
                    if r.lotId ~= o.lotId then placeAtEntry(root, r, o.lotId); p[#p + 1] = "returned " .. rid .. " to the outing" end
                    keep[#keep + 1] = rid
                end
            end
            o.participants = keep
            if #keep == 0 then
                Tr.EndOutingOffline(root, "nobody left on the outing")
                p[#p + 1] = "ended an empty outing"
            else
                root.active = root.active or {}
                root.active.householdId, root.active.lotId = o.householdId, o.lotId
                if lot and V.Kind(lot) == nil then Tr.EndOutingOffline(root, "venue gone") end
            end
        end
    end
    if not root.outing then
        -- nobody may be stuck at a venue, in a taxi, or in a staff uniform between visits
        for _, ev in ipairs(root.scheduled or {}) do
            if ev.outingHold then ev.lotId, ev.outingHold = nil, nil; p[#p + 1] = "released a held event" end
        end
        local pendingRiders = {}
        local trip = root.travel and root.travel.pending
        for _, rid in ipairs(trip and trip.rids or {}) do pendingRiders[rid] = true end
        for _, rid in ipairs(V.SortedKeys(root.residents)) do
            local r = root.residents[rid]
            local lot = r.lotId and root.hood.lots[r.lotId]
            if r.npc == "staff" then
                if r.lotId then r.lotId, r.role, r.roleData = nil, nil, nil end
            elseif lot and V.Kind(lot) and not r.dead then
                if r.roleData and r.roleData.home and root.hood.lots[r.roleData.home.lotId or ""] then
                    local h = r.roleData.home
                    r.lotId, r.x, r.y, r.level = h.lotId, h.x, h.y, h.level or 0
                    r.noNeeds = r.roleData.prevNoNeeds or nil
                    r.role, r.roleData = nil, nil
                else
                    local hh = r.householdId and root.households[r.householdId]
                    if hh and hh.lotId then placeAtEntry(root, r, hh.lotId) else r.lotId, r.role, r.roleData = nil, nil, nil end
                end
                p[#p + 1] = "brought " .. rid .. " home from a venue"
            elseif not r.lotId and r.away and r.away.reason == "travel" and not pendingRiders[rid] and not r.dead then
                local hh = r.householdId and root.households[r.householdId]
                if hh and hh.lotId then placeAtEntry(root, r, hh.lotId); p[#p + 1] = "brought " .. rid .. " home from a taxi" end
            end
        end
        if root.active and root.hood.lots[root.active.lotId or ""] and V.Kind(root.hood.lots[root.active.lotId]) then
            local hh = root.households[root.active.householdId or ""]
            if hh and hh.lotId then root.active.lotId = hh.lotId; p[#p + 1] = "active lot reset to home" end
        end
    end
end)

---------------------------------------------------------------------------------------------------
-- Phone: "Call a Taxi" opens the destination chooser at home, or calls the taxi home when out.
if SS.Phone and SS.Phone.RegisterCall then
    SS.Phone.RegisterCall({
        id = "outings_taxi", label = "Call a Taxi", category = "Travel", order = 60,
        test = function(world, caller)
            if Tr.Pending(world) then return false, "A taxi is already on its way." end
            if V.Active(world) then return true end
            if rootOf(world).outing then return false, "The household is out." end
            if world.lot.kind == "community" then return false, "Call from home or from an outing." end
            return true
        end,
        run = function(world, caller)
            if V.Active(world) then return Tr.GoHome(world, {}) end
            if SS.UI and SS.UI.OpenTravel then
                local ok, why = SS.UI.OpenTravel(caller and caller.id)
                if ok then return true, "Where to? Choose a venue and who's going." end
                return false, why
            end
            return false, "The destination chooser needs the game window."
        end,
    })
end
