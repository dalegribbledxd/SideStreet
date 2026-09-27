-- SideStreet services: the cleaner, repair technician, gardener and food delivery (§15.2), on the
-- visitors roles framework. Owner: visitors module (docs/modules/visitors.md).
--
-- A service visit is a saved record in root.services.visits:
--   { id, kind, lotId, hhId, state, at, created, regular, req, rid, committed, arrivedAt, leftAt,
--     tasks, fixed = {oid...}, failed = n, menu, settled, charged, amount, why }
-- states: booked (a worker will come) -> arriving (on the street / walking to the door) ->
--   working (reached the door: the commitment point) -> done | nowork | dismissed | failed |
--   cancelled | ended (worker vanished, e.g. a reload mid-visit: never invoiced)
-- Policy: one open visit per service per lot; a repeated call returns the same visit. Cancelling
-- before the worker reaches the door is free. After that, "Send Home" pays the call-out and the
-- time so far. Payment happens once, when the worker leaves (one ledger entry); food is paid at the
-- door when a household member takes the meal. Nothing is ever charged on load.
local _, SS = ...
local RD = SS.RoleData
local TUN = RD.tuning
local W, G, U = SS.World, SS.Grid, SS.U
local V = SS.Visitors
local St = SS.Street
local Sv = SS.Services or {}
SS.Services = Sv
Sv.stats = { calls = 0, visits = 0, tasks = 0, repairs = 0, repairFails = 0, charges = 0, searches = 0 }

local OPEN = { booked = true, arriving = true, working = true }
local WORKER_ROLES = { cleaner = "cleaner", repair = "repair", gardener = "gardener" }
local HISTORY_CAP = 30

local function sortedIds(t) return V.SortedIds(t) end
local function hourOf(t) return math.floor(t / 60) % 24 end
local function money(v) return U.fmtMoney(v) end

function Sv.State(world)
    local root = world.root or world
    local s = root.services
    if type(s) ~= "table" then s = {}; root.services = s end
    s.visits = s.visits or {}
    s.nextId = s.nextId or 1
    s.bookings = s.bookings or {}
    s.lastWorker = s.lastWorker or {}
    return s
end

function Sv.Get(world, vid) return vid and Sv.State(world).visits[vid] end

-- The open visit of a service on a lot (booked, arriving or working), if any.
function Sv.OpenVisit(world, kind, lotId)
    local s = Sv.State(world)
    lotId = lotId or world.lot.id
    for _, id in ipairs(sortedIds(s.visits)) do
        local v = s.visits[id]
        if v.kind == kind and v.lotId == lotId and OPEN[v.state] then return v end
    end
end

-- Every open visit on this lot, earliest first (the phone's "expected" list).
function Sv.Expected(world)
    local out = {}
    local s = Sv.State(world)
    for _, id in ipairs(sortedIds(s.visits)) do
        local v = s.visits[id]
        if v.lotId == world.lot.id and OPEN[v.state] then out[#out + 1] = v end
    end
    table.sort(out, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.id < b.id end)
    return out
end

function Sv.Worker(world, v)
    local a = v and v.rid and world.actors[v.rid]
    if a and a.roleData and a.roleData.visit == v.id then return a end
end
function Sv.VisitOf(world, a)
    local vid = a and a.roleData and a.roleData.visit
    return vid and Sv.State(world).visits[vid]
end

local function prune(world)
    local s = Sv.State(world)
    local settled = {}
    for id, v in pairs(s.visits) do if not OPEN[v.state] then settled[#settled + 1] = v end end
    if #settled <= HISTORY_CAP then return end
    table.sort(settled, function(a, b) if a.created ~= b.created then return a.created < b.created end return a.id < b.id end)
    for k = 1, #settled - HISTORY_CAP do s.visits[settled[k].id] = nil end
end

---------------------------------------------------------------------------------------------------
-- Work finding (task selection policy)
local function has(def, tag) return SS.Tags.Has(def, tag) end
local function today(world) return math.floor(world.time / 1440) end

-- Cleaner: what kind of mess is this object? puddle | dishes | rubbish | bin | fixture | nil
function Sv.CleanKind(world, o, def)
    local st = o.state or {}
    local id = o.def
    if has(def, "puddle") or id:find("puddle", 1, true) then return "puddle" end
    if has(def, "dishes") or has(def, "dirty_dishes") then return "dishes" end
    if def.cat == "system" and (has(def, "plate") or id:find("plate", 1, true) or id:find("dish", 1, true))
        and (st.dirty or st.eaten or st.empty) then return "dishes" end
    if has(def, "rubbish") or has(def, "trash_pile") or id:find("rubbish", 1, true) then return "rubbish" end
    if id == "delivery_box" or (id == "delivery_meal" and st.spoiled) then return "rubbish" end
    if has(def, "newspaper") and (st.read or (st.day and st.day < today(world))) then return "rubbish" end
    if (has(def, "bin") or has(def, "trash") or has(def, "trash_can")) and st.full then return "bin" end
    if st.dirty or (st.dirt or 0) >= 50 or (o.dirt or 0) >= 50 then
        if def.cat ~= "system" then return "fixture" end
    end
end

-- Repair: actually broken, eligible objects (not system objects, not burnt remains).
function Sv.RepairEligible(world, o, def)
    local st = o.state
    if not (st and st.broken) then return false end
    if def.cat == "system" or st.burnt or def.noRepair then return false end
    return true
end

local function isPlant(def)
    for _, t in ipairs(RD.plantTags) do if has(def, t) then return true end end
    return false
end
-- Gardener: "water" | "weed" | nil. SS.Garden.NeedsCare (family module) decides when present.
function Sv.PlantNeed(world, o, def)
    if not isPlant(def) then return nil end
    if SS.Garden and SS.Garden.NeedsCare then return SS.Garden.NeedsCare(world, o) end
    local st = o.state or {}
    if st.wilted or st.dry or (st.water ~= nil and st.water < 40) then return "water" end
    if (st.weeds or 0) > 0 then return "weed" end
end

-- Which interaction does the task: household-core's chore interaction for this object when it has
-- one tagged `chore = <name>` that the worker may use, else this module's own svc_* interaction.
local OWN = { puddle = "svc_mop", dishes = "svc_dishes", rubbish = "svc_rubbish", bin = "svc_empty_bin", fixture = "svc_scrub",
    repair = "svc_repair", water = "svc_tend", weed = "svc_tend" }
local CHORE = { repair = "repair", water = "water", weed = "weed" }
for k, v in pairs(RD.cleanChore) do CHORE[k] = v end
function Sv.TaskInteraction(world, a, o, def, what)
    local chore = CHORE[what]
    for _, iid in ipairs(def.actions or {}) do
        local ia = SS.Interactions[iid]
        if ia and chore and ia.chore == chore and not ia.householdOnly then
            if SS.Actions.Available(world, a, o, iid) then return iid, true end
        end
    end
    V.EnsureSlot(def, "svc")
    return OWN[what], false
end

local function reservedByOther(o, a)
    if not o.res then return false end
    for _, holder in pairs(o.res) do if holder ~= a.id then return true end end
    return false
end
local function targetedByOther(world, o, a)
    for id, b in pairs(world.actors) do
        if id ~= a.id and b.act and (b.act.oid == o.id) then return true end
    end
    return false
end

-- The garden module's route (family VI-3): SS.Garden.Tasks(world) lists what needs care, most urgent
-- first. -> { [objId] = rank } or nil without it. Guarded: a failing call falls back to the scan.
local function gardenRoute(world)
    if not (SS.Garden and SS.Garden.Tasks) then return nil end
    local ok, list = pcall(SS.Garden.Tasks, world)
    if not ok or type(list) ~= "table" then return nil end
    local rank = {}
    for n, e in ipairs(list) do
        local id = type(e) == "table" and (e.id or (type(e.obj) == "table" and e.obj.id))
        if id and not rank[id] then rank[id] = n end
    end
    return rank
end
Sv.GardenRoute = gardenRoute

-- Candidate tasks for a worker, best first: { oid, what, pri, d }.
function Sv.Tasks(world, kind, a)
    local out = {}
    local lot = world.lot
    local skip = a and a.roleData and a.roleData.vs and a.roleData.vs.skip or {}
    local route = kind == "gardener" and gardenRoute(world) or nil
    for _, oid in ipairs(sortedIds(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and (skip[oid] or 0) < 2 and not (a and (reservedByOther(o, a) or targetedByOther(world, o, a))) then
            local what, pri
            if kind == "cleaner" then
                what = Sv.CleanKind(world, o, def)
                pri = what and RD.cleanPriority[what]
            elseif kind == "repair" then
                if Sv.RepairEligible(world, o, def) then
                    what = "repair"
                    local q = 9
                    for _, t in ipairs({ "plumbing", "kitchen", "electronics", "lighting" }) do
                        if def.cat == t then q = RD.repairPriority[t] end
                    end
                    pri = q
                end
            elseif kind == "gardener" then
                if route then
                    -- the garden module's list is the route: its urgency order, its own job names
                    local n = route[oid]
                    if n then
                        local job = SS.Garden.NeedsCare and SS.Garden.NeedsCare(world, o)
                        what, pri = (job == "weed") and "weed" or "water", n
                    end
                else
                    what = Sv.PlantNeed(world, o, def)
                    pri = what == "water" and 1 or (what and 2)
                end
            end
            if what then
                local d = a and (math.abs(o.x + 0.5 - a.x) + math.abs(o.y + 0.5 - a.y) + math.abs((o.level or 0) - (a.level or 0)) * 6) or 0
                out[#out + 1] = { oid = oid, what = what, pri = pri or 9, d = d }
            end
        end
    end
    table.sort(out, function(x, y)
        if x.pri ~= y.pri then return x.pri < y.pri end
        if x.d ~= y.d then return x.d < y.d end
        return x.oid < y.oid
    end)
    return out
end

function Sv.HasWork(world, kind)
    if kind == "food" then return true end
    return #Sv.Tasks(world, kind, nil) > 0
end

---------------------------------------------------------------------------------------------------
-- Money (one ledger entry per visit)
local function pay(world, amount, text)
    if amount <= 0 then return "free" end
    Sv.stats.charges = Sv.stats.charges + 1
    if (world.money or 0) < amount and SS.Economy and SS.Economy.Bill then
        local bill = SS.Economy.Bill(world, amount, "service", text)
        if bill then return "billed" end
    end
    SS.Money(world, -amount, "service", text)
    return "paid"
end

-- Price of a visit so far: call-out plus the hourly rate per started quarter hour on site.
function Sv.Price(kind, minutes)
    local S = RD.services[kind]
    if not S or kind == "food" then return 0 end
    local q = math.max(1, math.ceil((minutes or 0) / RD.quarter - 1e-6))
    return S.callout + math.floor(S.rate * q * RD.quarter / 60 + 0.5)
end

local function history(world, v, text)
    v.note = text
    local hh = world.household
    if hh and hh.id == v.hhId then V.Journal(world, text) end
end

-- Close a visit exactly once. Charges only when the worker was committed (reached the door) and did
-- work (or was sent home after arriving). outcome: done | nowork | dismissed | failed | cancelled | ended
function Sv.Settle(world, v, outcome, why)
    if not v or v.settled then return 0 end
    v.settled = true
    v.leftAt = v.leftAt or world.time
    local S = RD.services[v.kind] or {}
    local amount = 0
    if v.kind ~= "food" and v.committed and outcome ~= "ended" and outcome ~= "failed" then
        local worked = (v.tasks or 0) > 0
        if worked or outcome == "dismissed" or RD.chargeWhenNoWork then
            amount = Sv.Price(v.kind, v.leftAt - (v.arrivedAt or v.leftAt))
        end
    end
    v.state, v.why = outcome, why or v.why
    local who = v.rid and world.root.residents[v.rid]
    local name = who and who.name or S.label
    if amount > 0 then
        local minutes = math.floor(v.leftAt - (v.arrivedAt or v.leftAt) + 0.5)
        local text = string.format("%s (%s): call-out %s + %d min", S.label or v.kind, name, money(S.callout or 0), minutes)
        v.payment = pay(world, amount, text)
        v.charged, v.amount = true, amount
        SS.Emit("serviceCharged", world, v, amount)
    end
    local line
    if v.leaveWhy == "lot_switch" or v.leaveWhy == "away" then
        if outcome == "done" or outcome == "nowork" or outcome == "dismissed" then
            line = string.format("%s went home when the household was left (%d task%s done, paid %s).", name, v.tasks or 0,
                (v.tasks == 1) and "" or "s", money(amount))
        end
    elseif outcome == "done" then
        line = string.format("%s finished (%d task%s) and was paid %s.", name, v.tasks or 0, (v.tasks == 1) and "" or "s", money(amount))
    elseif outcome == "nowork" then
        line = name .. " found nothing to do and left. No charge."
    elseif outcome == "dismissed" then
        line = string.format("%s was sent home and was paid %s.", name, money(amount))
    elseif outcome == "failed" then
        line = name .. " couldn't do the job: " .. tostring(why or "unknown") .. " No charge."
    elseif outcome == "cancelled" then
        line = (S.label or v.kind) .. " visit cancelled. No charge."
    end
    if line then
        V.Notice(world, nil, line)
        history(world, v, line)
    end
    SS.Emit("serviceSettled", world, v, outcome, amount)
    prune(world)
    return amount
end

---------------------------------------------------------------------------------------------------
-- Calling, booking, cancelling

-- Next arrival time for a service: now + lead when open, else the next opening.
function Sv.ArrivalTime(world, kind)
    local S = RD.services[kind]
    local t = world.time
    local lead = SS.RandomInt(world, "services", S.leadMin, S.leadMax)
    local at = t + lead
    local h = hourOf(at)
    local m = math.floor(at % 1440)
    if h >= S.open and m <= S.close * 60 - 15 then return at end
    local day = math.floor(at / 1440)
    if h >= S.open then day = day + 1 end
    return day * 1440 + S.open * 60 + SS.RandomInt(world, "services", 0, 45)
end

-- Paid calls and paying at the door need a teen or older (tuning.payAges), like every other purchase.
function Sv.CanPay(who)
    if not who then return true end
    if (who.kind or "human") ~= "human" then return false end
    return TUN.payAges[who.age or "adult"] and true or false
end

-- Can this household call the service now? ok, why. caller (optional): who is on the phone.
function Sv.CanCall(world, kind, caller, opts)
    opts = opts or {}
    local S = RD.services[kind]
    if not S then return false, "No such service." end
    if not V.HomeLot(world) then return false, "Services only come to your own home." end
    if not Sv.CanPay(caller) then
        return false, (kind == "food" and "Only a teen or an adult can order food." or "Only a teen or an adult can hire help.")
    end
    local open = Sv.OpenVisit(world, kind)
    if open then
        return false, (S.label .. " is already booked (expected around " .. V.ClockText(open.at) .. ")."), open
    end
    if kind == "food" then
        local item = Sv.MenuItem(opts.menu)
        if not item then return false, "Pick something from the menu." end
        if (world.money or 0) < item.price + S.fee then return false, "Not enough money for " .. item.name .. " (" .. money(item.price + S.fee) .. ")." end
        return true
    end
    if (world.money or 0) < S.callout then return false, "Not enough money for the call-out fee (" .. money(S.callout) .. ")." end
    if S.needsWork and not opts.regular and not Sv.HasWork(world, kind) then return false, S.noWork end
    return true
end

function Sv.MenuItem(id)
    for _, m in ipairs(RD.menu) do if m.id == id then return m end end
end

local function openVisit(world, kind, caller, opts)
    local S = RD.services[kind]
    local s = Sv.State(world)
    local id = "sv" .. s.nextId
    s.nextId = s.nextId + 1
    local at = opts.at or Sv.ArrivalTime(world, kind)
    local v = { id = id, kind = kind, lotId = world.lot.id, hhId = world.household and world.household.id, state = "booked",
        at = at, created = world.time, regular = opts.regular or nil, caller = caller and caller.id, tasks = 0, fixed = {},
        menu = opts.menu }
    s.visits[id] = v
    -- one request per visit (the key names the visit): a worker still walking back to the van from an
    -- earlier visit never absorbs the new booking. Sv.CanCall already refuses a second open visit.
    local reqId, why = V.Request(world, S.role, { at = at, key = "svc:" .. kind .. ":" .. world.lot.id .. ":" .. id, visit = id,
        prefer = s.lastWorker[kind], priority = "service" })
    if not reqId or why == "already" then
        s.visits[id] = nil
        return nil, (why ~= "already" and why) or "Nobody can come right now."
    end
    v.req = reqId
    Sv.stats.visits = Sv.stats.visits + 1
    SS.Emit("serviceBooked", world, v)
    return v
end

-- Call a service. kind: cleaner | repair | gardener | food. opts: { menu (food), regular }.
-- Returns ok, message, visit. A repeated call never books a second worker: it reports the visit
-- already on its way (ok = false, visit = that visit).
function Sv.Call(world, kind, caller, opts)
    opts = opts or {}
    Sv.stats.calls = Sv.stats.calls + 1
    local ok, why, existing = Sv.CanCall(world, kind, caller, opts)
    if not ok then return false, why, existing end
    local v, err = openVisit(world, kind, caller, opts)
    if not v then return false, err or "Nobody can come." end
    local S = RD.services[kind]
    local msg
    if kind == "food" then
        local item = Sv.MenuItem(opts.menu)
        msg = string.format("%s ordered (%s on delivery). Expected around %s.", item.name, money(item.price + S.fee), V.ClockText(v.at))
    else
        msg = string.format("%s booked: expected around %s. Call-out %s, then %s an hour.", S.label, V.ClockText(v.at), money(S.callout), money(S.rate))
    end
    V.Notice(world, nil, msg)
    return true, msg, v
end

-- Cancel before the commitment point (free). After the worker reached the door this refuses and
-- points to Send Home. Returns ok, message.
function Sv.Cancel(world, vid)
    local v = Sv.Get(world, vid)
    if not v or not OPEN[v.state] then return false, "There is no such booking." end
    local S = RD.services[v.kind]
    if v.state == "working" or v.committed then
        if v.kind == "food" then return false, "The courier is at the door: answer it, or ask them to leave." end
        return false, (S.label .. " is already here. Use Send Home to stop the visit (you pay the call-out and the time so far).")
    end
    Sv.Settle(world, v, "cancelled", "cancelled")
    if v.req then V.CancelRequest(world, v.req, "cancelled") end
    local a = Sv.Worker(world, v)
    if a then V.Leave(world, a, "cancelled") end
    SS.Emit("serviceCancelled", world, v)
    return true, S.label .. " cancelled. No charge."
end

-- Send a committed worker home now: they stop, pay is the call-out plus time on site.
function Sv.Dismiss(world, vid)
    local v = Sv.Get(world, vid)
    if not v or not OPEN[v.state] then return false, "They're not working here." end
    if not v.committed then return Sv.Cancel(world, vid) end
    local a = Sv.Worker(world, v)
    v.dismissed = true
    if a then
        V.Say(world, a, "farewell", { reason = "dismissed" })
        V.Leave(world, a, "dismissed")
    else
        Sv.Settle(world, v, "dismissed")
    end
    return true, (RD.services[v.kind].label .. " sent home.")
end

-- Regular daily visits (cleaner, gardener).
function Sv.Booking(world, kind)
    local hh = world.household
    local b = hh and Sv.State(world).bookings[hh.id]
    return b and b[kind]
end
function Sv.Book(world, kind, hour, caller)
    local S = RD.services[kind]
    if not S or not S.regular then return false, "That service can't be booked daily." end
    local hh = world.household
    if not hh or not V.HomeLot(world) then return false, "Regular services only come to your own home." end
    if not Sv.CanPay(caller) then return false, "Only a teen or an adult can book regular help." end
    local s = Sv.State(world)
    s.bookings[hh.id] = s.bookings[hh.id] or {}
    if s.bookings[hh.id][kind] then return false, S.label .. " already comes every day." end
    hour = hour or (S.open + 1)
    s.bookings[hh.id][kind] = { lotId = world.lot.id, hour = hour, since = world.time }
    Sv.ScheduleRegular(world, kind)
    local msg = string.format("%s booked daily at about %d %s. Call-out %s, then %s an hour, paid each visit.", S.label,
        (hour % 12 == 0) and 12 or hour % 12, hour < 12 and "AM" or "PM", money(S.callout), money(S.rate))
    V.Notice(world, nil, msg)
    SS.Emit("serviceRegular", world, kind, true)
    return true, msg
end
function Sv.Unbook(world, kind, caller)
    local hh = world.household
    if not Sv.CanPay(caller) then return false, "Only a teen or an adult can change the bookings." end
    local s = Sv.State(world)
    local b = hh and s.bookings[hh.id]
    if not (b and b[kind]) then return false, "No daily booking to cancel." end
    b[kind] = nil
    local v = Sv.OpenVisit(world, kind)
    if v and v.regular and not v.committed then Sv.Cancel(world, v.id) end
    local msg = RD.services[kind].label .. " will no longer come daily."
    V.Notice(world, nil, msg)
    SS.Emit("serviceRegular", world, kind, false)
    return true, msg
end
function Sv.ScheduleRegular(world, kind)
    local b = Sv.Booking(world, kind)
    if not b or b.lotId ~= world.lot.id then return end
    if Sv.OpenVisit(world, kind) then return end
    local S = RD.services[kind]
    local day = today(world)
    if b.lastDay == day then day = day + 1 end
    local at = day * 1440 + b.hour * 60
    if at < world.time + S.leadMin then day = day + 1; at = day * 1440 + b.hour * 60 end
    at = at + SS.RandomInt(world, "services", 0, 30)
    b.lastDay = day
    return openVisit(world, kind, nil, { regular = true, at = at })
end

---------------------------------------------------------------------------------------------------
-- The worker on site
local function commit(world, a)
    local v = Sv.VisitOf(world, a)
    if not v or v.committed then return end
    v.committed, v.arrivedAt, v.state = true, world.time, "working"
    Sv.State(world).lastWorker[v.kind] = a.id
    local S = RD.services[v.kind]
    V.Notice(world, nil, string.format("%s the %s has arrived.", a.name, S.label:lower()))
    SS.Emit("serviceArrived", world, v, a)
end

local function finishWork(world, a, v, vs)
    if (v.tasks or 0) == 0 then
        local S = RD.services[v.kind]
        if vs.unreachable and vs.unreachable > 0 then
            v.why = "couldn't get to the work (the way is blocked)"
            V.Say(world, a, "visitor_refused", { reason = "blocked" })
            V.Help(world, a, a.name .. " couldn't get to anything that needed doing (the way is blocked). No charge.")
            vs.outcome = "failed"
        else
            V.Say(world, a, "farewell", { reason = "nowork" })
            V.Notice(world, a, a.name .. ": " .. S.noWork, "social")
            vs.outcome = "nowork"
        end
    else
        V.Say(world, a, "farewell", { reason = "done" })
        vs.outcome = "done"
    end
    V.Leave(world, a, vs.outcome)
end

-- Runs in the framework's "task" state for cleaner, repair and gardener.
function Sv.WorkTick(world, a, dt)
    local vs = a.roleData.vs
    local v = Sv.VisitOf(world, a)
    if not v or v.settled then return V.Leave(world, a, "done") end
    if not v.committed then commit(world, a) end
    vs.skip = vs.skip or {}
    if V.Busy(a) then return end
    local cur = vs.cur
    if cur then
        vs.cur = nil
        local le = a.tmp.lastEnd
        if not (le and le.oid == cur.oid and le.iid == cur.iid and le.status == "done") then
            vs.skip[cur.oid] = (vs.skip[cur.oid] or 0) + 1
        end
    end
    local S = RD.services[v.kind]
    if world.time - (v.arrivedAt or world.time) >= S.maxWork then return finishWork(world, a, v, vs) end
    if (vs.nextLook or 0) > world.time then return end
    local tasks = Sv.Tasks(world, v.kind, a)
    local task = tasks[1]
    if not task then return finishWork(world, a, v, vs) end
    local o = world.lot.objects[task.oid]
    local def = SS.Objects[o.def]
    local iid, core = Sv.TaskInteraction(world, a, o, def, task.what)
    Sv.stats.searches = Sv.stats.searches + 1
    if not iid or not SS.Actions.Available(world, a, o, iid) or not V.Reachable(world, a, o, iid) then
        vs.skip[task.oid] = 2
        vs.unreachable = (vs.unreachable or 0) + 1
        vs.nextLook = world.time + 0.5
        return
    end
    local data = { svcTask = task.what, visit = v.id, core = core }
    if core and task.what == "repair" then
        -- household-core's repair chore lets whoever orders a professional set the odds
        -- (data.success); the last allowed attempt always holds, as with this module's own repair
        local tries = vs.attempts and vs.attempts[task.oid] or 0
        data.success = (tries + 1 >= (S.attempts or 1)) and 1 or S.success
    end
    SS.Actions.Order(world, a, task.oid, iid, nil, nil, { data = data })
    vs.cur = { oid = task.oid, iid = iid, what = task.what }
end

-- A task finished through any interaction (ours or household-core's): count it for the visit.
function Sv.TaskDone(world, a, what, o)
    local v = Sv.VisitOf(world, a)
    if not v then return end
    v.tasks = (v.tasks or 0) + 1
    Sv.stats.tasks = Sv.stats.tasks + 1
    if what == "repair" and o then v.fixed[#v.fixed + 1] = o.id end
    SS.Emit("serviceTask", world, v, a, what, o)
end
SS.On("actionEnded", function(actor, act, status)
    if not actor or not act or not act.data or not act.data.core then return end
    local world = SS.Sim.world
    if not world then return end
    local obj = act.oid and world.lot.objects[act.oid]
    if act.data.svcTask == "repair" then
        local vs = actor.roleData and actor.roleData.vs
        if vs and act.oid then
            vs.attempts = vs.attempts or {}
            vs.attempts[act.oid] = (vs.attempts[act.oid] or 0) + 1
        end
        -- household-core's chore ends a repair that didn't take as "failed" (data.failed) and one
        -- stopped by a shock with data.shocked: a failed attempt, tried again while attempts remain
        if status ~= "done" and (act.data.failed or act.data.shocked) and obj and obj.state and obj.state.broken then
            Sv.stats.repairFails = Sv.stats.repairFails + 1
            V.Say(world, actor, "complain", { reason = "repair_retry", objDef = obj.def })
            local S = RD.services.repair
            if vs and vs.cur and vs.cur.oid == act.oid and (vs.attempts[act.oid] or 0) < (S.attempts or 1) + 1 then
                vs.cur = nil -- not an unreachable or refused task: picked again on the next look
                if vs.skip then vs.skip[act.oid] = nil end
            end
            return
        end
    end
    if status ~= "done" then return end
    if act.data.svcTask == "repair" then
        if obj and obj.state and obj.state.broken then return end -- ended without the fix holding
        Sv.stats.repairs = Sv.stats.repairs + 1
    end
    Sv.TaskDone(world, actor, act.data.svcTask, obj)
end)

-- The worker was still on the way when the lot was left (V.Requeue put the request back): the visit
-- is booked again and a worker comes when the lot is next played. Nothing is charged.
function Sv.Rebook(world, v)
    local req = v.req and V.GetRequest(world, v.req)
    v.state, v.rid = "booked", nil
    if req and req.state == "pending" then v.at = req.at end
    v.requeued = (v.requeued or 0) + 1
    SS.Emit("serviceRebooked", world, v)
end

local function workerDef(kind)
    return {
        tick = Sv.WorkTick,
        afterDoor = "task",
        onDoor = function(world, a) commit(world, a) end,
        onBlocked = function(world, a)
            local v = Sv.VisitOf(world, a)
            if v then v.why = "couldn't get in (the way to the front door is blocked)" end
            a.roleData.vs.outcome = "failed"
        end,
        onLeave = function(world, a, why)
            local v = Sv.VisitOf(world, a)
            if not v or v.settled then return end
            local vs = a.roleData.vs
            if vs.requeued and not v.committed then return Sv.Rebook(world, v) end
            v.leftAt, v.leaveWhy = world.time, why
            local outcome = vs.outcome
            if why == "dismissed" then outcome = "dismissed"
            elseif why == "cancelled" then outcome = "cancelled"
            elseif not v.committed then outcome = outcome or "failed"
            elseif not outcome then outcome = ((v.tasks or 0) > 0) and "done" or "nowork" end
            if outcome == "failed" and not v.why then v.why = "they had to leave (" .. tostring(why) .. ")" end
            Sv.Settle(world, v, outcome, v.why)
        end,
        onTimeout = function(world, a)
            local v = Sv.VisitOf(world, a)
            if v and v.committed then
                a.roleData.vs.outcome = ((v.tasks or 0) > 0) and "done" or "nowork"
            end
            V.Leave(world, a, "timeout")
        end,
        reconcile = function(world, a)
            local v = Sv.VisitOf(world, a)
            if not v or v.settled then return "remove" end
            a.roleData.vs.cur, a.roleData.vs.nextLook = nil, nil
            return "resume"
        end,
        describe = function(world, a, vs)
            local v = Sv.VisitOf(world, a)
            if vs.state == "task" and v then
                local cur = vs.cur and vs.cur.what
                return "working" .. (cur and (" (" .. cur .. ")") or "") .. ", " .. (v.tasks or 0) .. " done"
            end
        end,
    }
end
for kind, role in pairs(WORKER_ROLES) do
    local def = V.roles[role]
    for k, fn in pairs(workerDef(kind)) do def[k] = fn end
    V.RegisterRole(role, def)
end

---------------------------------------------------------------------------------------------------
-- Work progress survives a save/load: the minutes worked on each task (object + interaction) are kept
-- in the worker's saved role state and resumed when the task is picked up again, so a reload never
-- restarts a half-done job (or bills the redone minutes). Bounded by tuning.workProgressCap entries.
local function progTable(actor)
    local vs = actor.roleData and actor.roleData.vs
    if not vs then return nil end
    vs.prog = vs.prog or {}
    return vs.prog
end
local function progKey(act) return tostring(act.oid) .. ":" .. tostring(act.iid) end
function Sv.SaveProgress(actor, act, t)
    local p = progTable(actor)
    if not p or not act.oid then return end
    local k = progKey(act)
    if p[k] == nil then
        local n = 0
        for _ in pairs(p) do n = n + 1 end
        if n >= (TUN.workProgressCap or 16) then for kk in pairs(p) do p[kk] = nil end end
    end
    p[k] = t
end
function Sv.ResumeProgress(actor, act)
    local p = progTable(actor)
    local t = p and act.oid and p[progKey(act)]
    if t and t > 0 then
        act.t, act.resumedAt = t, t
        return t
    end
end
function Sv.ClearProgress(actor, act)
    local p = progTable(actor)
    if p and act and act.oid then p[progKey(act)] = nil end
end
local function trackProgress(world, actor, act, obj, dt) Sv.SaveProgress(actor, act, act.t + dt) end
Sv.TrackProgress = trackProgress

---------------------------------------------------------------------------------------------------
-- Service interactions (own fallbacks; household-core's chore interactions are preferred)
local function workerTest(kinds)
    return function(world, actor)
        if actor.role and kinds[actor.role] then return true end
        return false, "That's the service worker's job."
    end
end
local CLEANER = { cleaner = true }
local function removeTask(what, minutes, pose, label, carry)
    return {
        label = label, category = "Service", slot = "svc", pose = pose, dur = minutes, manualOnly = true, carry = carry,
        test = workerTest(CLEANER),
        onStart = function(world, actor, act, obj)
            if not obj then return false, "It's gone." end
            if carry then actor.carry = carry end
            Sv.ResumeProgress(actor, act)
        end,
        onTick = trackProgress,
        onEnd = function(world, actor, act, obj, status)
            if carry and actor.carry == carry then actor.carry = nil end
            if status == "done" then Sv.ClearProgress(actor, act) end
            if status ~= "done" or not obj or not world.lot.objects[obj.id] then return end
            if SS.Maintenance and SS.Maintenance.Clean and SS.Maintenance.Clean(world, obj, actor, what) then
                -- household-core removed / cleaned it
            else
                V.RemoveObject(world, obj.id)
            end
            Sv.TaskDone(world, actor, what, obj)
        end,
    }
end
SS.Interactions.svc_mop = removeTask("puddle", RD.cleanMinutes.puddle, "clean", "Mop Up", "mop")
SS.Interactions.svc_dishes = removeTask("dishes", RD.cleanMinutes.dishes, "clean", "Clear Dishes", "plate_stack")
SS.Interactions.svc_rubbish = removeTask("rubbish", RD.cleanMinutes.rubbish, "clean", "Pick Up Rubbish", "trash_bag")
SS.Interactions.svc_empty_bin = {
    label = "Empty the Bin", category = "Service", slot = "svc", pose = "clean", dur = RD.cleanMinutes.bin, manualOnly = true,
    carry = "trash_bag", test = workerTest(CLEANER),
    onStart = function(world, actor, act) actor.carry = "trash_bag"; Sv.ResumeProgress(actor, act) end,
    onTick = trackProgress,
    onEnd = function(world, actor, act, obj, status)
        if actor.carry == "trash_bag" then actor.carry = nil end
        if status == "done" then Sv.ClearProgress(actor, act) end
        if status ~= "done" or not obj then return end
        if not (SS.Maintenance and SS.Maintenance.Clean and SS.Maintenance.Clean(world, obj, actor, "bin")) then
            obj.state = obj.state or {}
            obj.state.full, obj.state.fill = nil, 0
            SS.Emit("lotChanged", "state", obj.id)
        end
        Sv.TaskDone(world, actor, "bin", obj)
    end,
}
SS.Interactions.svc_scrub = {
    label = "Scrub", category = "Service", slot = "svc", pose = "clean", dur = RD.cleanMinutes.fixture, manualOnly = true,
    test = workerTest(CLEANER),
    onStart = function(world, actor, act) actor.carry = nil; Sv.ResumeProgress(actor, act) end,
    onTick = trackProgress,
    onEnd = function(world, actor, act, obj, status)
        if status == "done" then Sv.ClearProgress(actor, act) end
        if status ~= "done" or not obj then return end
        if not (SS.Maintenance and SS.Maintenance.Clean and SS.Maintenance.Clean(world, obj, actor, "fixture")) then
            obj.state = obj.state or {}
            obj.state.dirty, obj.state.dirt, obj.dirt = nil, 0, 0
            SS.Emit("lotChanged", "state", obj.id)
        end
        Sv.TaskDone(world, actor, "fixture", obj)
    end,
}

-- Repair: takes real time (base + difficulty), can fail and be retried (bounded attempts).
local function repairMinutes(obj)
    local def = obj and SS.Objects[obj.def]
    local diff = def and def.quality and def.quality.repairDifficulty or 1
    return RD.repairBase + RD.repairPerDifficulty * diff
end
SS.Interactions.svc_repair = {
    label = "Repair", category = "Service", slot = "svc", pose = "repair", maxDur = 400, manualOnly = true, carry = "wrench",
    whenBroken = true, -- the executor refuses a broken object's interactions unless they declare this
    test = function(world, actor, obj)
        if actor.role ~= "repair" then return false, "That's the repair technician's job." end
        if not (obj and obj.state and obj.state.broken) then return false, "It isn't broken." end
        return true
    end,
    onStart = function(world, actor, act, obj)
        act.pose = "repair"
        act.need = repairMinutes(obj)
        actor.carry = "wrench"
        if not Sv.ResumeProgress(actor, act) then V.Say(world, actor, "broken_object", { objDef = obj and obj.def, repairing = true }) end
    end,
    onTick = function(world, actor, act, obj, dt)
        Sv.SaveProgress(actor, act, act.t + dt)
        if act.t + dt >= (act.need or RD.repairBase) then act.complete = true end
    end,
    onEnd = function(world, actor, act, obj, status)
        if actor.carry == "wrench" then actor.carry = nil end
        if status == "done" then Sv.ClearProgress(actor, act) end
        if status ~= "done" or not obj or not world.lot.objects[obj.id] then return end
        local vs = actor.roleData and actor.roleData.vs
        local S = RD.services.repair
        local ok = SS.Random(world, "services") < S.success
        if vs then
            vs.attempts = vs.attempts or {}
            vs.attempts[obj.id] = (vs.attempts[obj.id] or 0) + 1
            if not ok and vs.attempts[obj.id] >= S.attempts then ok = true end -- the last allowed attempt always holds
        end
        if ok then
            if not (SS.Maintenance and SS.Maintenance.Repair and SS.Maintenance.Repair(world, obj, actor, "service")) then
                obj.state.broken = nil
                obj.wear = 0
                SS.Emit("lotChanged", "state", obj.id)
                SS.Emit("objectRepaired", world, obj, actor)
            end
            Sv.stats.repairs = Sv.stats.repairs + 1
            Sv.TaskDone(world, actor, "repair", obj)
        else
            Sv.stats.repairFails = Sv.stats.repairFails + 1
            V.Say(world, actor, "complain", { reason = "repair_retry", objDef = obj.def })
            -- not counted as a task yet; the object stays broken and is picked again (bounded)
            if vs then vs.skip = vs.skip or {}; vs.skip[obj.id] = nil end
        end
    end,
}

SS.Interactions.svc_tend = {
    label = "Tend", category = "Service", slot = "svc", pose = "use", dur = RD.tendMinutes, manualOnly = true, carry = "watering_can",
    test = workerTest({ gardener = true }),
    onStart = function(world, actor, act, obj)
        local need = obj and Sv.PlantNeed(world, obj, SS.Objects[obj.def])
        act.pose = (need == "weed") and "clean" or "use"
        actor.carry = (need ~= "weed") and "watering_can" or nil
        act.data = act.data or {}
        act.data.need = need
        Sv.ResumeProgress(actor, act)
    end,
    onTick = trackProgress,
    onEnd = function(world, actor, act, obj, status)
        if actor.carry == "watering_can" then actor.carry = nil end
        if status == "done" then Sv.ClearProgress(actor, act) end
        if status ~= "done" or not obj then return end
        if SS.Garden and SS.Garden.Tend then
            -- family's garden decides what a round of care does (water, weed, clear, refill)
            local ok, text = SS.Garden.Tend(world, obj, actor)
            if not ok then
                -- already seen to (a resident got there first): nothing to count or bill, and not picked again
                local vs = actor.roleData and actor.roleData.vs
                if vs then vs.skip = vs.skip or {}; vs.skip[obj.id] = 2 end
                return
            end
        else
            obj.state = obj.state or {}
            obj.state.dry, obj.state.wilted = nil, nil
            if obj.state.water ~= nil then obj.state.water = 100 end
            obj.state.weeds = 0
            SS.Emit("lotChanged", "state", obj.id)
        end
        Sv.TaskDone(world, actor, act.data.need or "water", obj)
    end,
}

---------------------------------------------------------------------------------------------------
-- Food delivery: the courier waits at the door; a member pays and takes the meal.
local courier = V.roles.courier
courier.onArrive = function(world, a) a.carry = "shopping_bag" end
courier.onDoor = function(world, a)
    local v = Sv.VisitOf(world, a)
    if v then v.state, v.atDoorAt = "working", world.time end
end
courier.onIgnored = function(world, a)
    local v = Sv.VisitOf(world, a)
    if v and not v.settled then
        v.why = "nobody answered the door"
        V.Say(world, a, "visitor_refused", { reason = "ignored" })
        Sv.Settle(world, v, "failed", "nobody answered the door.")
    end
    return true
end
courier.onBlocked = function(world, a)
    local v = Sv.VisitOf(world, a)
    if v then v.why = "couldn't get to the front door (the way is blocked)." end
end
courier.onLeave = function(world, a, why)
    local v = Sv.VisitOf(world, a)
    if not v or v.settled then return end
    local vs = a.roleData and a.roleData.vs
    if vs and vs.requeued and v.state ~= "working" then return Sv.Rebook(world, v) end
    v.leftAt = world.time
    if why == "lot_switch" or why == "away" then
        return Sv.Settle(world, v, "failed", "the delivery couldn't wait while nobody was home.")
    end
    if why == "asked" or why == "cancelled" then Sv.Settle(world, v, "cancelled", "sent away at the door")
    else Sv.Settle(world, v, "failed", v.why or ("they had to leave (" .. tostring(why) .. ").")) end
end
courier.reconcile = function(world, a)
    local v = Sv.VisitOf(world, a)
    if not v or v.settled then return "remove" end
    a.carry = "shopping_bag"
    return "resume"
end
V.RegisterRole("courier", courier)

local OT = RD.text.objects
SS.Objects.delivery_meal = {
    name = OT.delivery_meal.name, cat = "system", buyable = false, price = 0, env = 0, noBlock = true, fp = { { 0, 0 } }, mount = "surface",
    desc = OT.delivery_meal.desc,
    tags = { "takeaway" }, slots = { grab = { approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }, face = 2 } },
    actions = { "eat_delivery", "toss_delivery" }, startState = { servings = 4 },
}
SS.Objects.delivery_box = {
    name = OT.delivery_box.name, cat = "system", buyable = false, price = 0, env = -2, noBlock = true, fp = { { 0, 0 } }, mount = "surface",
    desc = OT.delivery_box.desc,
    tags = { "rubbish" }, slots = { grab = { approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }, face = 2 } },
    actions = { "toss_delivery" }, startState = {},
}

-- Place the delivered meal: the nearest surface with room, else the floor inside the front door.
-- A free surface slot is chosen (never one that already holds something); with every surface full
-- the meal goes on the floor just inside the front door.
function Sv.PlaceMeal(world, member, item)
    local near = member and { math.floor(member.x), math.floor(member.y), member.level or 0 }
    local state = { servings = item.servings, menu = item.id, t = world.time, hunger = item.hunger }
    local meal = V.PlaceOnSurface(world, "delivery_meal", near, { state = state })
    if meal then return meal end
    local door = V.DoorFor(world, {})
    local spot = door.inside or door.stand
    return V.PlaceNear(world, "delivery_meal", { spot[1], spot[2] }, { extra = { state = state } })
end

SS.Interactions.door_pay = {
    label = "Pay for Delivery", category = "Visitors", targetActor = true, pose = "use", dur = 2, manualOnly = true,
    test = function(world, actor, target)
        if not V.IsMember(world, actor) then return false, "Only household members can pay." end
        if not Sv.CanPay(actor) then return false, "Only a teen or an adult can pay for that." end
        if not target or target.role ~= "courier" then return false, "Nothing to pay for." end
        local vs = target.roleData and target.roleData.vs
        if not vs or vs.state ~= "door" then return false, "They're not at the door yet." end
        local v = Sv.VisitOf(world, target)
        local item = v and Sv.MenuItem(v.menu)
        if not item or v.settled then return false, "Nothing to pay for." end
        local total = item.price + RD.services.food.fee
        if (world.money or 0) < total then return false, "Not enough money (" .. money(total) .. ")." end
        return true
    end,
    onStart = function(world, actor, act)
        local c = world.actors[act.tid]
        local v = c and Sv.VisitOf(world, c)
        local item = v and Sv.MenuItem(v.menu)
        if not item or v.settled then return false, "Nothing to pay for." end
        local total = item.price + RD.services.food.fee
        if (world.money or 0) < total then return false, "Not enough money (" .. money(total) .. ")." end
        v.settled, v.state, v.leftAt = true, "done", world.time
        v.charged, v.amount = true, total
        Sv.stats.charges = Sv.stats.charges + 1
        SS.Money(world, -total, "food", "Food delivery: " .. item.name)
        V.Sfx(RD.sfx.till)
        SS.Emit("serviceCharged", world, v, total)
        c.carry = nil
        actor.carry = "shopping_bag"
        local meal = Sv.PlaceMeal(world, actor, item)
        actor.carry = nil
        local text = string.format("%s paid %s for %s.", actor.name, money(total), item.name)
        if not meal then text = text .. (V.Text("mealNowhere") or ""); SS.Needs.Add(actor, "hunger", item.hunger) end
        V.Notice(world, nil, text)
        history(world, v, text)
        V.Say(world, c, "farewell", { reason = "delivered" })
        c.roleData.vs.greeted = true
        V.Leave(world, c, "done")
        SS.Emit("serviceSettled", world, v, "done", total)
        SS.Emit("foodDelivered", world, v, meal)
        prune(world)
    end,
}
SS.Interactions.door_dismiss = {
    label = "Send Home", category = "Visitors", targetActor = true, pose = "talk", dur = 2, manualOnly = true,
    test = function(world, actor, target)
        if not V.IsMember(world, actor) then return false, "Only household members can do that." end
        if not target or not WORKER_ROLES[target.role or ""] then return false, "They're not working here." end
        local v = Sv.VisitOf(world, target)
        if not v or v.settled then return false, "They're already done." end
        local vs = target.roleData.vs
        if vs.state == "leaving" then return false, "They're already leaving." end
        if actor.age == "child" or actor.age == "infant" or (actor.kind or "human") ~= "human" then
            return false, "Only adults can send workers home."
        end
        return true
    end,
    onStart = function(world, actor, act)
        local t = world.actors[act.tid]
        local v = t and Sv.VisitOf(world, t)
        if not v then return false, "They're already done." end
        return Sv.Dismiss(world, v.id)
    end,
}

SS.Interactions.eat_delivery = {
    label = "Eat Takeaway", category = "Basics", slot = "grab", pose = "eat_stand", carry = "bowl", dur = 12,
    gain = { hunger = 45, fun = 3 }, advert = { hunger = 42, fun = 3 },
    test = function(world, actor, obj)
        local st = obj and obj.state or {}
        if st.spoiled then return false, "It's gone off." end
        if (st.servings or 0) <= 0 then return false, "It's all gone." end
        return true
    end,
    onStart = function(world, actor, act, obj)
        local st = obj and obj.state
        if not st or st.spoiled or (st.servings or 0) <= 0 then return false, "It's all gone." end
        st.servings = st.servings - 1
        actor.carry = "bowl"
    end,
    onEnd = function(world, actor, act, obj)
        if actor.carry == "bowl" then actor.carry = nil end
        if obj and world.lot.objects[obj.id] and (obj.state.servings or 0) <= 0 then
            local x, y, lv, parent, pslot = obj.x, obj.y, obj.level, obj.parent, obj.pslot
            V.RemoveObject(world, obj.id)
            V.AddObject(world, "delivery_box", x, y, lv, { parent = parent, pslot = pslot })
        end
    end,
}
SS.Interactions.toss_delivery = {
    label = "Throw Away", category = "Chores", slot = "grab", pose = "clean", dur = 1.5,
    -- only leftovers are worth throwing away on their own initiative (never a fresh meal)
    advertise = function(world, actor, obj)
        if obj and obj.def == "delivery_meal" and not obj.state.spoiled and (obj.state.servings or 0) > 0 then return nil end
        return { room = 8 }
    end,
    test = function(world, actor, obj)
        if obj and obj.def == "delivery_meal" and not obj.state.spoiled and (obj.state.servings or 0) > 0 and actor.role then
            return false, "Not theirs to throw away."
        end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        if status == "done" and act.oid then V.RemoveObject(world, act.oid) end
    end,
}

-- Meals left out spoil.
local function spoilMeals(world)
    for _, oid in ipairs(sortedIds(world.lot.objects)) do
        local o = world.lot.objects[oid]
        if o.def == "delivery_meal" and o.state and not o.state.spoiled and world.time - (o.state.t or world.time) >= RD.mealSpoilAfter then
            o.state.spoiled = true
            SS.Emit("lotChanged", "state", oid)
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Framework events
SS.On("visitorSpawned", function(world, a, role)
    local v = Sv.VisitOf(world, a)
    if v and v.state == "booked" then v.state, v.rid = "arriving", a.id end
end)
SS.On("visitorCancelled", function(world, r)
    local vid = r and r.data and r.data.visit
    local v = vid and Sv.Get(world, vid)
    if v and not v.settled and v.state == "booked" then
        local S = RD.services[v.kind]
        Sv.Settle(world, v, "failed", "no " .. (S and S.label:lower() or "worker") .. " was available (" .. tostring(r.why) .. ").")
    end
end)
SS.On("visitorLeft", function(world, a, role, why)
    -- a worker removed by something else (death, fire, a reset): close the visit without an invoice
    local vid = a and a.roleData and a.roleData.visit
    local v = vid and Sv.Get(world, vid)
    if v and not v.settled then Sv.Settle(world, v, "ended", "left early (" .. tostring(why) .. ")") end
end)

function Sv.Hour(world, h)
    spoilMeals(world)
end
function Sv.Day(world)
    local hh = world.household
    local b = hh and Sv.State(world).bookings[hh.id]
    if not b then return end
    for _, kind in ipairs({ "cleaner", "gardener" }) do
        if b[kind] and b[kind].lotId == world.lot.id then Sv.ScheduleRegular(world, kind) end
    end
end

-- After a load: open visits whose worker is gone end quietly (never invoiced); booked visits keep
-- their saved request; regular bookings get today's visit if missing.
function Sv.Attach(world)
    local s = Sv.State(world)
    for _, id in ipairs(sortedIds(s.visits)) do
        local v = s.visits[id]
        if v.lotId == world.lot.id and OPEN[v.state] then
            local req = v.req and V.GetRequest(world, v.req)
            if v.state == "booked" then
                if not req or req.state ~= "pending" then v.settled, v.state, v.why = true, "ended", "the booking was lost" end
            elseif not Sv.Worker(world, v) then
                v.settled, v.state, v.why = true, "ended", "the visit ended while the game was closed"
            end
        end
    end
    local hh = world.household
    local b = hh and s.bookings[hh.id]
    if b then
        for _, kind in ipairs({ "cleaner", "gardener" }) do
            if b[kind] and b[kind].lotId == world.lot.id then Sv.ScheduleRegular(world, kind) end
        end
    end
end

SS.Sim.Register({ name = "services", order = 41, hour = Sv.Hour, day = Sv.Day, attach = Sv.Attach })

SS.Save.RegisterValidator(function(root, p)
    if root.services ~= nil and type(root.services) ~= "table" then root.services = nil; p[#p + 1] = "service records reset" end
    local s = root.services
    if not s then return true end
    if type(s.visits) ~= "table" then s.visits = {} end
    for id, v in pairs(s.visits) do
        if type(v) ~= "table" or not RD.services[v.kind] or type(v.at) ~= "number" then
            s.visits[id] = nil
            p[#p + 1] = "dropped a damaged service booking"
        else
            v.fixed = type(v.fixed) == "table" and v.fixed or {}
            v.tasks = tonumber(v.tasks) or 0
        end
    end
    for _, k in ipairs({ "bookings", "lastWorker" }) do if type(s[k]) ~= "table" then s[k] = {} end end
    s.nextId = tonumber(s.nextId) or 1
    return true
end)
