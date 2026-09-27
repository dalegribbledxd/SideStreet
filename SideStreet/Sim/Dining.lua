-- SideStreet dining at the cafe: the host seats the party (pairs and groups together, and their
-- conversation carries on at the table), the waiter takes orders from the menu (Data/Venues.lua),
-- the cook prepares them at the range, the waiter serves, the diners eat (partial benefit when
-- interrupted), the bill is paid once, and the party leaves.
--
-- Recovery paths (every one ends with the diners able to pay, leave and go home):
--   blocked waiter  -> the host takes over the table's order, service and bill; if the host can't
--                      get there either, the food waits at the counter and the diners collect it
--   removed seat    -> reseated at the same table, then at another free table, then at the counter
--   cancelled date  -> the companion leaves; their unserved dish is cancelled (never charged)
--   missing partner -> the table waits T.missingGrace minutes, then orders without them
--   no table        -> the party waits up to T.tableWaitMax, then gives up (nothing charged)
--   no host         -> after a few minutes the party seats itself
--   slow kitchen    -> after T.foodWaitMax the host apologises and cancels the dish (not charged)
--   Pay and Leave   -> any time: served dishes are charged once, the rest are cancelled
-- Money moves once per party (party.bill.paid), only for the household's parties, only for dishes
-- actually served. Everything is saved in root.outing.dining, so a reload never charges twice.
-- Owner: outings module (docs/modules/outings.md).
local _, SS = ...
local VD = SS.VenueData
local T = VD.tuning
local U = SS.U
local V = SS.Venues
local G = SS.Grid
local W = SS.World
local Dn = SS.Dining or {}
SS.Dining = Dn
local I = SS.Interactions

local function rootOf(x) return x and (x.root or x) end
local sortedKeys = V.SortedKeys

---------------------------------------------------------------------------------------------------
-- Menu
local menuById = {}
for _, m in ipairs(VD.menu) do menuById[m.id] = m end
function Dn.MenuItem(id) return id and menuById[id] or nil end
Dn.COURSE_ORDER = { "light", "main", "dessert", "drink" }

---------------------------------------------------------------------------------------------------
-- State (root.outing.dining): arrays in creation order, bounded.
-- party.state: checkin (walking to the host stand) | waiting (for a table) | seating (walking to the
-- seats) | seated (waiting to order) | ordered | eating | bill (asked for the bill) | paid (standing
-- up) | left | cancelled (gave up; nothing charged)
local ACTIVE = { checkin = true, waiting = true, seating = true, seated = true, ordered = true, eating = true, bill = true, paid = true }
local AT_TABLE = { seating = true, seated = true, ordered = true, eating = true, bill = true }
local BILLABLE = { served = true, eaten = true }
Dn.ACTIVE, Dn.AT_TABLE = ACTIVE, AT_TABLE

function Dn.State(world)
    local o = rootOf(world).outing
    if not o then return nil end
    o.dining = o.dining or {}
    local d = o.dining
    d.parties = d.parties or {}
    d.tickets = d.tickets or {}
    d.tasks = d.tasks or {}
    d.nextId = d.nextId or 1
    return d
end

local function newId(d, prefix)
    local id = prefix .. d.nextId
    d.nextId = d.nextId + 1
    return id
end

function Dn.IsCafe(world) return V.Active(world) ~= nil and world.lot.venue == "cafe" end

function Dn.Party(world, pid)
    local d = Dn.State(world)
    for _, p in ipairs(d and d.parties or {}) do if p.id == pid then return p end end
end

local function isMember(p, rid)
    for _, id in ipairs(p.members) do if id == rid then return true end end
    return false
end

-- The active party a person dines with (nil when none).
function Dn.PartyOf(world, rid)
    local d = Dn.State(world)
    for _, p in ipairs(d and d.parties or {}) do
        if ACTIVE[p.state] and p.state ~= "paid" and isMember(p, rid) and not p.gone[rid] then return p end
    end
end

-- Drop the oldest finished entries until the list fits.
local function prune(list, keep, isOpen)
    local k = 1
    while #list > keep and k <= #list do
        if not isOpen(list[k]) then table.remove(list, k) else k = k + 1 end
    end
end

local function note(world, p, text)
    p.log = p.log or {}
    p.log[#p.log + 1] = text
    while #p.log > 12 do table.remove(p.log, 1) end
    V.Log(world, text)
end

-- Player-facing notice only for the household's own parties.
local function tell(world, p, text)
    note(world, p, text)
    if p.household then V.Notice(world, text) end
end

-- The same news once per party (a fallback that repeats for each new task says it once).
-- p.told holds a few fixed keys only.
local function tellOnce(world, p, key, text)
    p.told = p.told or {}
    if p.told[key] then return end
    p.told[key] = true
    tell(world, p, text)
end

local function the(name) return SS.Shopping and SS.Shopping.The and SS.Shopping.The(name) or ("the " .. name) end

---------------------------------------------------------------------------------------------------
-- Tables and seats (runtime, cached with the venue scan)
function Dn.Tables(world)
    local rt = V.RT(world)
    if rt.dining then return rt.dining end
    local lot = world.lot
    local tables, used = {}, {}
    local seatList = V.Anchors(world, "dining_seat")
    for _, toid in ipairs(V.Anchors(world, "cafe_table")) do
        local t = lot.objects[toid]
        local def = t and SS.Objects[t.def]
        if def then
            local cells = {}
            for _, c in ipairs(G.footprint(def, t)) do cells[c[1] .. ":" .. c[2]] = true end
            local seats = {}
            for _, soid in ipairs(seatList) do
                local s = lot.objects[soid]
                local sdef = s and SS.Objects[s.def]
                if sdef and not used[soid] and (s.level or 0) == (t.level or 0) then
                    local adj = false
                    for _, c in ipairs(G.footprint(sdef, s)) do
                        for dir = 0, 3 do
                            local dv = G.DIRS[dir]
                            if cells[(c[1] + dv[1]) .. ":" .. (c[2] + dv[2])] then adj = true end
                        end
                    end
                    if adj then seats[#seats + 1] = soid; used[soid] = true end
                end
            end
            if #seats > 0 then tables[#tables + 1] = { oid = toid, seats = seats, cap = #seats, cells = cells, level = t.level or 0 } end
        end
    end
    local out = { tables = tables, byTable = {}, seatTable = {} }
    for _, t in ipairs(tables) do
        out.byTable[t.oid] = t
        for _, s in ipairs(t.seats) do out.seatTable[s] = t.oid end
    end
    rt.dining = out
    return out
end

-- Party id holding a seat (nil when free).
local function seatHolder(world, soid)
    local d = Dn.State(world)
    for _, p in ipairs(d.parties) do
        if AT_TABLE[p.state] or p.state == "waiting" or p.state == "checkin" then
            for rid, s in pairs(p.seats) do if s == soid and not p.gone[rid] then return p end end
        end
    end
end

local function seatFree(world, soid, p)
    local o = world.lot.objects[soid]
    if not o then return false end
    local h = seatHolder(world, soid)
    if h and h ~= p then return false end
    for _, rid in pairs(o.res or {}) do
        if not (p and isMember(p, rid)) then return false end
    end
    return true
end
Dn.SeatFree = seatFree

local function tableTaken(world, t, p)
    for _, s in ipairs(t.seats) do
        local h = seatHolder(world, s)
        if h and h ~= p then return true end
    end
    return false
end

local function freeSeats(world, t, p)
    local out = {}
    for _, s in ipairs(t.seats) do if seatFree(world, s, p) then out[#out + 1] = s end end
    return out
end

-- Tables for a party: the smallest free table that seats everyone; else neighbouring free tables.
function Dn.FindTables(world, p, n)
    local tabs = Dn.Tables(world).tables
    local best, bestCap
    for _, t in ipairs(tabs) do
        if not tableTaken(world, t, p) then
            local free = #freeSeats(world, t, p)
            if free >= n and (not bestCap or t.cap < bestCap) then best, bestCap = t, t.cap end
        end
    end
    if best then return { best } end
    -- a big party: start at the largest free table and add the nearest free ones
    local start
    for _, t in ipairs(tabs) do
        if not tableTaken(world, t, p) and (not start or #freeSeats(world, t, p) > #freeSeats(world, start, p)) then start = t end
    end
    if not start then return nil end
    local s0 = world.lot.objects[start.oid]
    local rest = {}
    for _, t in ipairs(tabs) do
        if t ~= start and not tableTaken(world, t, p) then
            local o = world.lot.objects[t.oid]
            rest[#rest + 1] = { t = t, d = math.abs(o.x - s0.x) + math.abs(o.y - s0.y) }
        end
    end
    table.sort(rest, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.t.oid < b.t.oid end)
    local pick, have = { start }, #freeSeats(world, start, p)
    for _, r in ipairs(rest) do
        if have >= n then break end
        pick[#pick + 1] = r.t
        have = have + #freeSeats(world, r.t, p)
    end
    if have < n then return nil end
    return pick
end

---------------------------------------------------------------------------------------------------
-- Party creation
local function companionsOf(world, lead)
    local o = V.Active(world)
    local out = { lead.id }
    local function add(rid)
        if #out >= 6 or rid == lead.id then return end
        local a = world.actors[rid]
        if a and not a.dead and not Dn.PartyOf(world, rid) and not (a.roleData and a.roleData.leaving) then
            for _, x in ipairs(out) do if x == rid then return end end
            out[#out + 1] = rid
        end
    end
    if V.IsMember(world, lead) then
        for _, rid in ipairs(o.participants or {}) do add(rid) end
        for _, g in ipairs(o.guests or {}) do if g.state == "here" then add(g.rid) end end
    elseif lead.role == "outing_guest" and lead.roleData and lead.roleData.with then
        add(lead.roleData.with)
    end
    return out
end

local function cheapest()
    local p
    for _, m in ipairs(VD.menu) do if not p or m.price < p then p = m.price end end
    return p or 0
end

-- Can this person start a meal here now? Returns ok, why.
function Dn.CanDine(world, actor)
    if not Dn.IsCafe(world) then return false, "Only at the cafe." end
    local o = V.Active(world)
    if o.closing then return false, (world.lot.name or "The cafe") .. " is closing." end
    local left = V.MinutesToClose("cafe", world.time)
    if left and left <= 30 then return false, "Last orders have been called; the kitchen is closing." end
    if Dn.PartyOf(world, actor.id) then return false, actor.name .. " already has a table." end
    if V.IsStaff(actor) then return false, "Staff eat after their shift." end
    if V.IsMember(world, actor) and (world.money or 0) < cheapest() then
        return false, "The household can't afford anything on the menu (from " .. U.fmtMoney(cheapest()) .. ")."
    end
    local funds = not V.IsMember(world, actor) and V.Funds(world, actor)
    if funds and funds < cheapest() then return false, actor.name .. " can't afford anything on the menu." end
    if #Dn.Tables(world).tables == 0 then return false, "There are no tables to sit at." end
    return true
end

-- Make a party. opts = { members = {rid}, patron = bool }.
function Dn.NewParty(world, lead, opts)
    opts = opts or {}
    local d = Dn.State(world)
    local members = opts.members or companionsOf(world, lead)
    local hh = false
    local root = rootOf(world)
    for _, rid in ipairs(members) do
        local r = root.residents[rid]
        if r and world.household and r.householdId == world.household.id then hh = true end
    end
    local p = {
        id = newId(d, "dp"), lead = lead.id, members = {}, household = hh, patron = opts.patron and true or nil,
        state = "checkin", createdAt = world.time, seats = {}, orders = {}, present = {}, gone = {}, missing = {},
        wants = {}, tables = {}, reseats = {}, log = {}, talk = 0,
    }
    for n, rid in ipairs(members) do p.members[n] = rid end
    d.parties[#d.parties + 1] = p
    prune(d.parties, 16, function(x) return ACTIVE[x.state] end)
    local names = {}
    for _, rid in ipairs(p.members) do names[#names + 1] = root.residents[rid] and root.residents[rid].name or rid end
    note(world, p, "Table for " .. #p.members .. ": " .. table.concat(names, ", ") .. ".")
    SS.Emit("dinerParty", world, p, "new")
    return p
end

local function podium(world)
    local list = V.Anchors(world, "podium")
    return list[1] and world.lot.objects[list[1]]
end

-- Player (or the UI): ask for a table. The lead walks to the host stand; everyone dines together.
function Dn.Request(world, lead, opts)
    local ok, why = Dn.CanDine(world, lead)
    if not ok then return false, why end
    local p = Dn.NewParty(world, lead, opts)
    local pod = podium(world)
    if pod then
        SS.Actions.Order(world, lead, pod.id, V.IidFor(SS.Objects[pod.def], "dine_request"), nil, nil, { data = { party = p.id } })
    else
        p.state, p.checkinAt = "waiting", world.time
    end
    if p.household then V.Notice(world, lead.name .. " asks for a table for " .. #p.members .. ".") end
    return true, p
end

function Dn.CheckIn(world, p)
    if p.state ~= "checkin" then return end
    p.state, p.checkinAt = "waiting", world.time
    note(world, p, "Checked in at the host stand.")
end

---------------------------------------------------------------------------------------------------
-- Seating
local function sitOrder(world, p, rid)
    local a = world.actors[rid]
    local soid = p.seats[rid]
    local seat = soid and world.lot.objects[soid]
    if not a or not seat then return false end
    if a.act and V.BaseIid(a.act.iid) == "dine_sit" and a.act.target and a.act.target.oid == soid then return true end
    for _, q in ipairs(a.queue or {}) do if V.BaseIid(q.iid) == "dine_sit" and q.oid == soid then return true end end
    SS.Actions.Order(world, a, soid, V.IidFor(SS.Objects[seat.def], "dine_sit"), nil, nil, { data = { party = p.id } })
    return true
end
Dn.SitOrder = sitOrder

-- Assign tables and seats and send everyone to sit. host = staff actor or nil (seated themselves).
function Dn.SeatParty(world, p, host)
    local want = {}
    for _, rid in ipairs(p.members) do if not p.gone[rid] then want[#want + 1] = rid end end
    if #want == 0 then return false end
    local tabs = Dn.FindTables(world, p, #want)
    if not tabs then return false end
    local seats = {}
    for _, t in ipairs(tabs) do for _, s in ipairs(freeSeats(world, t, p)) do seats[#seats + 1] = s end end
    p.tables = {}
    for n, t in ipairs(tabs) do p.tables[n] = t.oid end
    for n, rid in ipairs(want) do p.seats[rid] = seats[n] end
    p.state, p.seatingAt = "seating", world.time
    for _, rid in ipairs(want) do sitOrder(world, p, rid) end
    if host then
        V.Say(world, host, "host_greet", { venue = world.lot.name })
        note(world, p, host.name .. " seated the party.")
    else
        tell(world, p, "Nobody was at the host stand, so the party found a table themselves.")
    end
    SS.Emit("dinerParty", world, p, "seated")
    return true
end

-- A seat is gone or can't be reached: same table, then any free table, then the counter.
function Dn.Reseat(world, p, rid, why)
    p.reseats[rid] = (p.reseats[rid] or 0) + 1
    local a = world.actors[rid]
    local name = a and a.name or rid
    local old = p.seats[rid]
    p.seats[rid] = nil
    if p.reseats[rid] <= 3 then
        local info = Dn.Tables(world)
        for _, toid in ipairs(p.tables) do
            local t = info.byTable[toid]
            if t then
                for _, s in ipairs(freeSeats(world, t, p)) do
                    if s ~= old and not p.seats[rid] then
                        local mine = false
                        for other, s2 in pairs(p.seats) do if s2 == s and other ~= rid then mine = true end end
                        if not mine then p.seats[rid] = s end
                    end
                end
            end
        end
        if not p.seats[rid] then
            for _, t in ipairs(info.tables) do
                if not p.seats[rid] and not tableTaken(world, t, p) then
                    for _, s in ipairs(freeSeats(world, t, p)) do
                        local mine = false
                        for other, s2 in pairs(p.seats) do if s2 == s and other ~= rid then mine = true end end
                        if not mine and s ~= old and not p.seats[rid] then
                            p.seats[rid] = s
                            local have = false
                            for _, x in ipairs(p.tables) do if x == t.oid then have = true end end
                            if not have then p.tables[#p.tables + 1] = t.oid end
                        end
                    end
                end
            end
        end
    end
    if p.seats[rid] then
        tell(world, p, string.format("%s moved to another seat (%s).", name, why or "the seat was gone"))
        if a then sitOrder(world, p, rid) end
        return "seat"
    end
    -- no seat anywhere: eat standing at the counter
    p.counter = p.counter or {}
    p.counter[rid] = true
    tell(world, p, string.format("No seat for %s (%s); they'll eat at the counter.", name, why or "the seat was gone"))
    local ord = p.orders[rid]
    if a and ord and ord.state == "served" then Dn.CounterOrder(world, p, rid, "eat") end
    return "counter"
end

---------------------------------------------------------------------------------------------------
-- Ordering and the kitchen
-- Money left for more dishes. The household's own table: its money less everything already
-- ordered and not yet paid at every one of its open tables. A patron: their own funds less their
-- own open order (nil funds: an untracked pocket, no limit).
local function committed(ord)
    local m = ord and menuById[ord.item or ""]
    return (m and ord.state ~= "cancelled" and ord.state ~= "none") and m.price or 0
end
local function budgetLeft(world, p, rid)
    if p.household then
        local spent = 0
        local d = Dn.State(world)
        for _, q in ipairs(d and d.parties or {}) do
            if q.household and not (q.bill and q.bill.paid) then
                for _, ord in pairs(q.orders) do spent = spent + committed(ord) end
            end
        end
        return (world.money or 0) - spent
    end
    local a = rid and (world.actors[rid] or rootOf(world).residents[rid])
    local funds = a and V.Funds(world, a)
    if not funds then return math.huge end
    return funds - committed(p.orders[rid])
end
Dn.BudgetLeft = budgetLeft

-- Default choice: hungry people order a main, others something light; the household keeps the
-- bill modest (at most a sixth of its money per person); patrons pick at random.
local function defaultChoice(world, p, a)
    local hungry = a and a.needs and (a.needs.hunger or 0) < 10
    local course = hungry and "main" or "light"
    if a and a.age == "child" and not hungry then course = "dessert" end
    local list = {}
    for _, m in ipairs(VD.menu) do if m.course == course then list[#list + 1] = m end end
    if #list == 0 then list = VD.menu end
    local left = budgetLeft(world, p, a and a.id)
    local cap = p.household and math.min(left, math.max(cheapest(), (world.money or 0) / 6)) or left
    local afford = {}
    for _, m in ipairs(list) do if m.price <= cap then afford[#afford + 1] = m end end
    -- nothing on that course fits: the cheapest dish that does, else nothing (a glass of water)
    if #afford == 0 then
        local best
        for _, m in ipairs(VD.menu) do if m.price <= left and (not best or m.price < best.price) then best = m end end
        return best and best.id or nil
    end
    local k = SS.RandomInt(world, "outings.dine", 1, #afford)
    return afford[k].id
end

-- Choose a dish before ordering (or change a dish the kitchen hasn't started).
function Dn.Choose(world, rid, itemId)
    local p = Dn.PartyOf(world, rid)
    if not p then return false, "Get a table first." end
    local m = menuById[itemId or ""]
    if not m then return false, "That isn't on the menu." end
    local ord = p.orders[rid]
    if ord and ord.state ~= "cancelled" then
        local tk = Dn.Ticket(world, ord.ticket)
        if not tk or tk.state ~= "queued" then return false, "Too late to change: the kitchen has started." end
        if m.price - (menuById[ord.item] and menuById[ord.item].price or 0) > budgetLeft(world, p, rid) then
            return false, "The household can't afford " .. the(m.name) .. "."
        end
        local old = menuById[ord.item]
        ord.item, tk.item, tk.prep = m.id, m.id, m.prep
        tell(world, p, string.format("Changed the order: %s instead of %s.", the(m.name), old and the(old.name) or "the other dish"))
        return true
    end
    if m.price > budgetLeft(world, p, rid) then return false, "The household can't afford " .. the(m.name) .. "." end
    p.wants[rid] = m.id
    return true
end

function Dn.Ticket(world, id)
    local d = Dn.State(world)
    for _, tk in ipairs(d and d.tickets or {}) do if tk.id == id then return tk end end
end

-- The waiter (or host, or the counter) takes these people's orders: tickets go to the kitchen.
-- Only people at the table are asked (opts.onLot: everyone of the party on the lot, used when
-- the order is placed at the counter).
function Dn.TakeOrders(world, p, rids, opts)
    local d = Dn.State(world)
    local lines = {}
    for _, rid in ipairs(rids or p.members) do
        local a = world.actors[rid]
        local here = p.present[rid] or (p.counter and p.counter[rid]) or (opts and opts.onLot and a ~= nil)
        if not p.gone[rid] and not p.orders[rid] and here then
            local item = p.wants[rid] or defaultChoice(world, p, a)
            local m = item and menuById[item]
            local left = budgetLeft(world, p, rid)
            if m and m.price > left then
                -- the cheapest thing that fits, else a glass of water (free)
                m = nil
                for _, x in ipairs(VD.menu) do if x.price <= left and (not m or x.price < m.price) then m = x end end
            end
            if m then
                local tk = { id = newId(d, "tk"), party = p.id, rid = rid, item = m.id, prep = m.prep, t = 0, state = "queued", at = world.time }
                d.tickets[#d.tickets + 1] = tk
                p.orders[rid] = { item = m.id, state = "ordered", ticket = tk.id, at = world.time }
                lines[#lines + 1] = string.format("%s: %s (%s)", a and a.name or rid, m.name, U.fmtMoney(m.price))
            else
                p.orders[rid] = { item = nil, state = "none", at = world.time, note = "water" }
                lines[#lines + 1] = (a and a.name or rid) .. ": a glass of water"
            end
        end
    end
    prune(d.tickets, 48, function(x) return x.state == "queued" or x.state == "cooking" or x.state == "ready" end)
    if #lines > 0 then
        if p.state == "seated" or p.state == "seating" then p.state = "ordered" end
        p.orderedAt = p.orderedAt or world.time
        tell(world, p, "Ordered. " .. table.concat(lines, "; ") .. ".")
        SS.Emit("dinerOrder", world, p)
    end
    return #lines
end

local function cancelTicket(world, p, rid, why)
    local ord = p.orders[rid]
    if not ord or BILLABLE[ord.state] or ord.state == "cancelled" or ord.state == "none" then return false end
    local tk = Dn.Ticket(world, ord.ticket)
    if tk and tk.state ~= "served" then tk.state = "cancelled" end
    ord.state, ord.why = "cancelled", why
    return true
end

---------------------------------------------------------------------------------------------------
-- Service tasks (waiter first; the host takes over when the waiter can't; then the counter)
local TASK_TIME = { order = T.orderTime, serve = 0.5, bill = T.billTime }

function Dn.AddTask(world, kind, p, extra)
    local d = Dn.State(world)
    for _, t in ipairs(d.tasks) do
        if t.party == p.id and t.kind == kind and (t.state == "open" or t.state == "doing") then
            if extra and extra.rids then
                for _, r in ipairs(extra.rids) do
                    local have = false
                    for _, x in ipairs(t.rids) do if x == r then have = true end end
                    if not have then t.rids[#t.rids + 1] = r end
                end
            end
            return t
        end
    end
    local t = { id = newId(d, "st"), kind = kind, party = p.id, state = "open", at = world.time, rids = {}, failed = {} }
    for _, r in ipairs(extra and extra.rids or {}) do t.rids[#t.rids + 1] = r end
    d.tasks[#d.tasks + 1] = t
    prune(d.tasks, 32, function(x) return x.state == "open" or x.state == "doing" end)
    -- a table the staff already couldn't reach: straight to the host, or to the counter
    if p.counterMode then Dn.CounterFallback(world, t, p)
    elseif p.skip and next(p.skip) then t.escalated, t.escalatedAt = true, world.time end
    return t
end

local function openTask(d, p, kind)
    for _, t in ipairs(d.tasks) do
        if t.party == p.id and (not kind or t.kind == kind) and (t.state == "open" or t.state == "doing") then return t end
    end
end

-- Where to stand to serve a party: a free cell next to its table, nearest the worker.
function Dn.ServiceCell(world, p, a)
    local best, bd
    for _, toid in ipairs(p.tables) do
        local t = world.lot.objects[toid]
        local def = t and SS.Objects[t.def]
        if def then
            local lv = t.level or 0
            local fp = {}
            local cells = G.footprint(def, t)
            for _, c in ipairs(cells) do fp[c[1] .. ":" .. c[2]] = true end
            for _, c in ipairs(cells) do
                for dir = 0, 3 do
                    local dv = G.DIRS[dir]
                    local ni, nj = c[1] + dv[1], c[2] + dv[2]
                    if not fp[ni .. ":" .. nj] and W.InLot(world.lot, ni, nj) and not W.Blocked(world, lv, ni, nj) then
                        local dd = a and (math.abs(ni + 0.5 - a.x) + math.abs(nj + 0.5 - a.y)) or 0
                        if not bd or dd < bd then best, bd = { ni, nj, lv }, dd end
                    end
                end
            end
        end
    end
    if not best and p.tables[1] then
        local t = world.lot.objects[p.tables[1]]
        if t then
            local fi, fj = V.FreeNear(world, t.x, t.y, t.level or 0, 3)
            if fi then best = { fi, fj, t.level or 0 } end
        end
    end
    return best
end

-- The kitchen pass (where plates are picked up): the range's pass slot, else the waiter station.
function Dn.PassCell(world)
    for _, oid in ipairs(V.Anchors(world, "kitchen")) do
        local k = world.lot.objects[oid]
        local def = SS.Objects[k.def]
        local sl = def and def.slots and def.slots.pass
        if sl then
            local c = V.SlotCells(k, sl)[1]
            if c then return c end
        end
    end
    for _, oid in ipairs(V.Anchors(world, "waiter_station")) do
        local ws = world.lot.objects[oid]
        local c = V.StaffCells(ws, SS.Objects[ws.def])[1]
        if c then return c end
    end
end

-- The counter: a waiter station (its public side), even when its staff side is cut off.
function Dn.Counter(world)
    local list = V.Anchors(world, "waiter_station")
    if list[1] then return list[1] end
    for _, oid in ipairs(sortedKeys(world.lot.objects)) do
        local def = SS.Objects[world.lot.objects[oid].def]
        if def and SS.Tags.Has(def, "waiter_station") then return oid end
    end
end

-- Counter fallback: the diners go to the waiter station's public side themselves.
-- Send a diner to the waiter station's public side. Returns ok, why, busy: busy means someone
-- else holds the counter spot right now (a one-spot catalogue station), so the caller waits and
-- tries again instead of spending one of its bounded attempts.
function Dn.CounterOrder(world, p, rid, kind)
    local a = world.actors[rid]
    local ws = Dn.Counter(world)
    local o = ws and world.lot.objects[ws]
    if not a then return false, "not on the lot" end
    if not o then return false, "no waiter station" end
    if a.act and V.BaseIid(a.act.iid) == "dine_counter" and a.act.data and a.act.data.kind == kind then return true end
    for _, q in ipairs(a.queue or {}) do
        if V.BaseIid(q.iid) == "dine_counter" and q.data and q.data.kind == kind then return true end
    end
    local iid = V.IidFor(SS.Objects[o.def], "dine_counter")
    if SS.Actions.ResolveSlot then
        local tgt, why = SS.Actions.ResolveSlot(world, a, o, iid)
        if not tgt then return false, why, true end
    end
    local ok, why = SS.Actions.Order(world, a, ws, iid, nil, nil, { data = { party = p.id, kind = kind } })
    if ok == false then return false, why end
    -- stand up from the table first (the seat stays theirs)
    if a.act and V.BaseIid(a.act.iid) == "dine_sit" then
        a.act.data.toCounter = true
        a.act.complete = true
    end
    return true
end

-- A busy counter spot: wait (bounded by counterWaitMax minutes per party and purpose).
local function counterWait(world, p, key)
    p.counterWait = p.counterWait or {}
    local since = p.counterWait[key]
    if not since then p.counterWait[key] = world.time; return true end
    return world.time - since < (VD.tuning.counterWaitMax or 30)
end

function Dn.CounterFallback(world, task, p)
    task.state = "counter"
    p.counterMode = true
    local lead
    for _, rid in ipairs(p.members) do
        if not lead and world.actors[rid] and not p.gone[rid] and (p.present[rid] or rid == p.lead) then lead = rid end
    end
    if task.kind == "order" then
        tellOnce(world, p, "counterOrder", "Nobody could get to the table to take the order; ordering at the counter instead.")
        local ok, busy = false, false
        if lead then
            local _, why
            ok, why, busy = Dn.CounterOrder(world, p, lead, "order")
        end
        -- a busy counter: the table loop sends them again once the spot is free
        if not ok and not busy then Dn.TakeOrders(world, p, nil, { onLot = true }) end
    elseif task.kind == "serve" and not Dn.Counter(world) then
        -- no counter at all: the cook carries the plates out
        local n = Dn.ServeReady(world, p)
        if n > 0 then tellOnce(world, p, "cookOut", "With no waiter able to reach the table, the cook brought the food out.") end
    elseif task.kind == "serve" then
        local d = Dn.State(world)
        local any = false
        for _, tk in ipairs(d.tickets) do
            if tk.party == p.id and tk.state == "ready" then
                tk.state = "counter"
                local ord = p.orders[tk.rid]
                if ord and ord.state ~= "cancelled" then ord.state = "counter" end
                if world.actors[tk.rid] then Dn.CounterOrder(world, p, tk.rid, "pickup") end
                any = true
            end
        end
        if any then tellOnce(world, p, "counterFood", "The staff can't reach the table: the food is waiting at the counter.") end
    elseif task.kind == "bill" then
        Dn.Pay(world, p, "at the counter")
    end
end

local function takeTask(world, a, role)
    local d = Dn.State(world)
    local rd = a.roleData
    local cur = rd.task
    if cur then
        for _, t in ipairs(d.tasks) do if t.id == cur and t.state == "doing" and t.by == a.id then return t end end
        rd.task = nil
    end
    for _, t in ipairs(d.tasks) do
        local tp = (t.state == "open") and Dn.Party(world, t.party)
        if tp and not t.failed[a.id] and not (tp.skip and tp.skip[a.id]) and (role == "waiter" or t.escalated) then
            if t.kind ~= "serve" or Dn.ReadyFor(world, t.party) then
                t.state, t.by, t.phase, t.t, t.cell = "doing", a.id, (t.kind == "serve") and "pickup" or "go", 0, nil
                rd.task = t.id
                V.ResetWalk(a)
                return t
            end
        end
    end
end

function Dn.ReadyFor(world, pid)
    local d = Dn.State(world)
    for _, tk in ipairs(d.tickets) do if tk.party == pid and tk.state == "ready" then return true end end
    return false
end

local function failTask(world, a, task, role, p)
    task.failed[a.id] = true
    task.state, task.by, task.phase = "open", nil, nil
    a.roleData.task = nil
    if a.carry == "plate_food" then a.carry = nil end
    V.ResetWalk(a)
    p.skip = p.skip or {}
    p.skip[a.id] = true
    if role == "waiter" then
        task.escalated, task.escalatedAt = true, world.time
        note(world, p, a.name .. " can't get to the table; the host is covering it.")
        if p.household then V.Notice(world, a.name .. " (waiter) can't reach your table; the host will cover it.") end
    else
        Dn.CounterFallback(world, task, p)
    end
    return false
end

local function faceTable(world, a, p)
    local t = p.tables[1] and world.lot.objects[p.tables[1]]
    if t then a.facing = G.dirToFacing(t.x + 0.5 - a.x, t.y + 0.5 - a.y) end
end

function Dn.ServeReady(world, p)
    local d = Dn.State(world)
    local n = 0
    for _, tk in ipairs(d.tickets) do
        if tk.party == p.id and tk.state == "ready" then
            tk.state = "served"
            local ord = p.orders[tk.rid]
            if ord and (ord.state == "ordered" or ord.state == "cooking" or ord.state == "ready") then
                ord.state, ord.servedAt = "served", world.time
                n = n + 1
            end
        end
    end
    if n > 0 and (p.state == "ordered" or p.state == "seated") then p.state = "eating" end
    return n
end

local function completeTask(world, a, task, p)
    task.state, task.doneAt = "done", world.time
    a.roleData.task = nil
    V.ResetWalk(a)
    if task.kind == "order" then
        Dn.TakeOrders(world, p, task.rids[1] and task.rids or nil)
    elseif task.kind == "serve" then
        local n = Dn.ServeReady(world, p)
        if n > 0 then note(world, p, a.name .. " served " .. n .. (n == 1 and " dish." or " dishes.")) end
        if a.carry == "plate_food" then a.carry = nil end
    elseif task.kind == "bill" then
        Dn.Pay(world, p, "at the table")
    end
end

-- One service worker's step (the waiter's brain, and the host's for escalated tasks).
function Dn.WorkTask(world, a, dt, role)
    local d = Dn.State(world)
    if not d or not Dn.IsCafe(world) or a.roleData.leaving then return false end
    local task = takeTask(world, a, role)
    if not task then return false end
    local p = Dn.Party(world, task.party)
    if not p or not (AT_TABLE[p.state]) then
        task.state = "done"
        a.roleData.task = nil
        if a.carry == "plate_food" then a.carry = nil end
        return false
    end
    if task.phase == "pickup" then
        local c = Dn.PassCell(world)
        if not c then task.phase = "go"; return true end
        local st = V.Walk(world, a, c[1], c[2], c[3] or 0, "pass" .. task.id)
        if st == "arrived" then
            task.phase = "go"
            a.carry = "plate_food"
            V.ResetWalk(a)
        elseif st == "blocked" then
            return failTask(world, a, task, role, p)
        end
        return true
    end
    if task.phase == "go" then
        task.cell = task.cell or Dn.ServiceCell(world, p, a)
        local c = task.cell
        if not c then return failTask(world, a, task, role, p) end
        local st = V.Walk(world, a, c[1], c[2], c[3] or 0, "table" .. task.id)
        if st == "arrived" then
            task.phase, task.t = "at", 0
            faceTable(world, a, p)
        elseif st == "blocked" then
            return failTask(world, a, task, role, p)
        end
        return true
    end
    if task.phase == "at" then
        task.t = (task.t or 0) + dt
        a.pose = (task.kind == "order" or task.kind == "bill") and "talk" or "use"
        faceTable(world, a, p)
        if task.t >= (TASK_TIME[task.kind] or 1) then
            a.pose = "idle"
            completeTask(world, a, task, p)
        end
        return true
    end
    return false
end

V.roleBrains.waiter = function(world, a, dt) return Dn.WorkTask(world, a, dt, "waiter") end

-- Host: seats waiting parties from the stand; covers the waiter's tasks when escalated.
V.roleBrains.host = function(world, a, dt)
    local d = Dn.State(world)
    if not d or not Dn.IsCafe(world) then return false end
    if a.roleData.task or (not V.AtPost(world, a) and a.roleData.coverT) then
        if Dn.WorkTask(world, a, dt, "host") then return true end
    end
    if not V.AtPost(world, a) then return false end
    for _, p in ipairs(d.parties) do
        if p.state == "waiting" and world.time >= (p.checkinAt or 0) + 1 and world.time >= (p.nextTry or 0) then
            p.nextTry = world.time + 1
            if Dn.SeatParty(world, p, a) then return false end
        end
    end
    -- nobody waiting: cover an escalated task
    for _, t in ipairs(d.tasks) do
        if t.state == "open" and t.escalated and not t.failed[a.id] then
            a.roleData.coverT = world.time
            return Dn.WorkTask(world, a, dt, "host")
        end
    end
    a.roleData.coverT = nil
    return false
end

-- Cook: works the oldest ticket at the range; plates go to the pass for the waiter.
V.roleBrains.cook = function(world, a, dt)
    local d = Dn.State(world)
    if not d or not Dn.IsCafe(world) then return false end
    if not V.AtPost(world, a) then return false end
    local kitchen = world.lot.objects[a.roleData.anchor or ""]
    local tk
    for _, x in ipairs(d.tickets) do
        if (x.state == "cooking" or x.state == "queued") and not tk then tk = x end
    end
    if not tk then
        if kitchen and kitchen.state and kitchen.state.on then kitchen.state.on, kitchen.state.cooking = false, nil end
        if a.pose == "cook" then a.pose = "idle" end
        return false
    end
    local p = Dn.Party(world, tk.party)
    if not p or not AT_TABLE[p.state] then tk.state = "cancelled"; return true end
    if tk.state == "queued" then
        tk.state, tk.startedAt = "cooking", world.time
        local ord = p.orders[tk.rid]
        if ord and ord.state == "ordered" then ord.state = "cooking" end
    end
    if kitchen then kitchen.state = kitchen.state or {}; kitchen.state.on, kitchen.state.cooking = true, true end
    a.pose = "cook"
    local skill = a.skills and a.skills.cooking or 5
    tk.t = tk.t + dt * (0.8 + skill * 0.05)
    if tk.t >= tk.prep then
        tk.state, tk.readyAt = "ready", world.time
        local ord = p.orders[tk.rid]
        if ord and ord.state == "cooking" then ord.state = "ready" end
        tk.quality = (a.skills and a.skills.cooking or 5)
        Dn.AddTask(world, "serve", p)
    end
    return true
end

---------------------------------------------------------------------------------------------------
-- Eating, table talk and the meal's verdict
local function companions(world, p, rid)
    local out = {}
    for _, other in ipairs(p.members) do
        if other ~= rid and p.present[other] and world.actors[other] then out[#out + 1] = world.actors[other] end
    end
    return out
end

function Dn.RateMeal(world, p, a, ord)
    local m = menuById[ord.item or ""]
    if not m then return end
    local tk = Dn.Ticket(world, ord.ticket)
    local cook = tk and tk.quality or 5
    local q = m.quality + (cook - 5) * 0.3 + (SS.Random(world, "outings.dine") * 2 - 1)
    local wait = (ord.servedAt or world.time) - (ord.at or world.time)
    if wait > 40 then q = q - 1.5 end
    if ord.eaten and ord.eaten < 1 then q = q - 0.5 end
    q = U.clamp(q, 1, 10)
    ord.rating = math.floor(q * 10 + 0.5) / 10
    local rid = a.id
    if not a.noNeeds then SS.Needs.Add(a, "fun", (q - 5) * 2) end
    if q >= 7 then
        V.Say(world, a, "dine_good", { item = m.name, meal = m.name, quality = ord.rating, waitMin = math.floor(wait) })
        V.ScoreEvent(world, "meal", 3, { rid })
    elseif q <= 4 then
        V.Say(world, a, "dine_bad", { item = m.name, meal = m.name, quality = ord.rating, waitMin = math.floor(wait) })
        V.ScoreEvent(world, "meal", -4, { rid })
    end
    if m.price >= 20 and q < 6 then V.ScoreEvent(world, "price", -2, { rid }) end
    if wait > 30 then V.ScoreEvent(world, "waiting", -2, { rid }) end
    local comp = companions(world, p, rid)
    if #comp > 0 then
        local rids = { rid }
        for _, b in ipairs(comp) do rids[#rids + 1] = b.id end
        V.ScoreEvent(world, "company", 2, rids)
        if q >= 6 then for _, b in ipairs(comp) do V.RelBump(world, rid, b.id, 1) end end
    end
    SS.Emit("mealEaten", world, a, m, q)
end

-- Shared by the seat and the counter: eat a served dish (partial benefit if interrupted).
local function eatTick(world, a, act, p, dt, sitting)
    local ord = p.orders[a.id]
    if not ord or ord.state ~= "served" then return false end
    local m = menuById[ord.item or ""]
    if not m then ord.state = "eaten"; return false end
    local portion = math.min(dt / m.eat, 1 - (ord.eaten or 0))
    ord.eaten = (ord.eaten or 0) + portion
    if not a.noNeeds then SS.Needs.Add(a, "hunger", m.hunger * portion) end
    a.carry = (m.course == "drink") and "cup" or "plate_food"
    act.pose = sitting and "sit_eat" or "eat_stand"
    if ord.eaten >= 0.999 then
        ord.eaten, ord.state, ord.doneAt = 1, "eaten", world.time
        a.carry = nil
        Dn.RateMeal(world, p, a, ord)
    end
    return true
end

-- Conversation at the table: the social module's session when it is present (guarded), plus the
-- table's own talk (social and fun for everyone with company, and a bounded relationship lift).
-- Table talk through the social module's conversations when it is present. A conversation that
-- ends (tired of talking, urgent hunger while the food is on its way, the stay limit) finishes the
-- seated action it was attached to; dine_sit then sits straight back down without talk for a
-- while (see dine_sit.onEnd/next), so the meal never ends because a chat did.
local QUIET_AFTER_TALK = 20
local function talkReady(world, a)
    local C = SS.Conversation
    if C and C.Busy then
        local ok, busy = pcall(C.Busy, world, a, a, nil)
        if ok and busy then return false end
    end
    return true
end

local function joinTalk(world, p, a, act)
    local C = SS.Conversation
    if not (C and C.NewSession and C.AddMember and C.SessionOf) then return end
    if act.data.quiet or (p.quiet and (p.quiet[a.id] or 0) > world.time) then return end
    local comp = companions(world, p, a.id)
    if #comp == 0 then return end
    if not talkReady(world, a) then return end
    for _, b in ipairs(comp) do if not C.SessionOf(b.id) and not talkReady(world, b) then return end end
    pcall(function()
        local sess = C.SessionOf(a.id)
        for _, b in ipairs(comp) do sess = sess or C.SessionOf(b.id) end
        if not sess then sess = C.NewSession(world, a, comp[1]) end
        C.AddMember(world, sess, a, "in", act)
        for _, b in ipairs(comp) do
            if not (sess.members and sess.members[b.id]) and b.act and V.BaseIid(b.act.iid) == "dine_sit" then C.AddMember(world, sess, b, "in", b.act) end
        end
    end)
end

local function leaveTalk(world, a, act, status)
    local C = SS.Conversation
    if act.data and act.data.conv and C and C.OnActEnd then pcall(C.OnActEnd, world, a, act, status) end
end

local function tableTalk(world, p, a, act, dt)
    local comp = companions(world, p, a.id)
    if #comp == 0 then return end
    act.data.together = true
    if not a.noNeeds then
        SS.Needs.Add(a, "social", T.tableTalkSocial * dt / 60)
        SS.Needs.Add(a, "fun", T.tableTalkFun * dt / 60)
    end
    act.data.talkT = (act.data.talkT or 0) + dt
    if act.data.talkT >= 10 then
        act.data.talkT = 0
        p.talk = (p.talk or 0) + 1
        for _, b in ipairs(comp) do
            if a.id < b.id then V.RelBump(world, a.id, b.id, 1) end
        end
        -- table talk counts toward the outing a bounded number of times per table (a meal is not
        -- a clock that pays out); the people at the table are the ones talking
        p.talkScored = p.talkScored or {}
        if (p.talkScored[a.id] or 0) < 4 then
            p.talkScored[a.id] = (p.talkScored[a.id] or 0) + 1
            local rids = { a.id }
            for _, b in ipairs(comp) do rids[#rids + 1] = b.id end
            V.ScoreEvent(world, "conversation", 1, rids)
        end
    end
    if act.pose ~= "sit_eat" then
        local social = a.pose == "talk" or a.pose == "laugh" or a.pose == "argue"
        act.pose = social and "sit_talk" or ((SS.Random(world, "outings.anim") < 0.05) and "sit_talk" or "sit")
    end
end

---------------------------------------------------------------------------------------------------
-- Interactions
local function cafeTest(world, actor)
    if not Dn.IsCafe(world) then return false, "Only at the cafe." end
    return true
end

I.dine_request = {
    label = "Ask for a Table", category = "Food", slot = "guest", pose = "talk", dur = 1, manualOnly = true, outings = true,
    advert = {},
    test = function(world, actor)
        local ok, why = cafeTest(world, actor)
        if not ok then return ok, why end
        local p = Dn.PartyOf(world, actor.id)
        if p and p.state ~= "checkin" then return false, actor.name .. " already has a table." end
        if not p then return Dn.CanDine(world, actor) end
        return true
    end,
    onStart = function(world, actor, act)
        local p = act.data.party and Dn.Party(world, act.data.party) or Dn.PartyOf(world, actor.id)
        if not p then
            local ok, why = Dn.CanDine(world, actor)
            if not ok then return false, why end
            p = Dn.NewParty(world, actor)
        end
        act.data.party = p.id
    end,
    onEnd = function(world, actor, act, obj, status)
        local p = act.data.party and Dn.Party(world, act.data.party)
        if not p then return end
        if status == "cancelled" and p.state == "checkin" and actor.id == p.lead then
            p.state, p.why = "cancelled", "changed their mind"
            tell(world, p, actor.name .. " changed their mind about eating here.")
            return
        end
        -- done, or the stand couldn't be reached: either way they are waiting for a table now
        Dn.CheckIn(world, p)
    end,
}

I.dine_sit = {
    label = "Sit at the Table", category = "Food", slot = "seat", pose = "sit", maxDur = 600, manualOnly = true, outings = true, keepOnTalkEnd = true, dining = true,
    advert = {}, rate = { comfort = 6 },
    test = function(world, actor, obj)
        local p = Dn.PartyOf(world, actor.id)
        if not p or not AT_TABLE[p.state] then return false, "Ask the host for a table first." end
        if obj and p.seats[actor.id] ~= obj.id then return false, "That seat is for someone else." end
        return true
    end,
    onStart = function(world, actor, act, obj)
        local p = Dn.PartyOf(world, actor.id)
        if not p then return false, "The table was given away." end
        act.data.party = p.id
        p.present[actor.id] = true
        p.missing[actor.id] = nil
        if p.away then p.away[actor.id] = nil end
        if actor.carry and actor.carry ~= "plate_food" then actor.carry = nil end
        joinTalk(world, p, actor, act)
    end,
    onTick = function(world, actor, act, obj, dt)
        local p = Dn.Party(world, act.data.party)
        if not p or not AT_TABLE[p.state] or p.gone[actor.id] then act.complete = true; return end
        if act.target and p.seats[actor.id] ~= act.target.oid then act.complete = true; return end
        if not eatTick(world, actor, act, p, dt, true) then
            if actor.carry == "plate_food" or actor.carry == "cup" then actor.carry = nil end
            act.pose = "sit"
        end
        tableTalk(world, p, actor, act, dt)
    end,
    onEnd = function(world, actor, act, obj, status)
        local p = act.data and act.data.party and Dn.Party(world, act.data.party)
        leaveTalk(world, actor, act, status)
        if p and status == "done" and act.data.leaving and not act.data.toCounter and AT_TABLE[p.state] and not p.gone[actor.id]
            and p.seats[actor.id] == (act.target and act.target.oid) then
            -- the conversation ended, not the meal: stay at the table (next sits straight back down)
            act.data.resit = true
            p.quiet = p.quiet or {}
            p.quiet[actor.id] = world.time + QUIET_AFTER_TALK
            p.present[actor.id] = nil
            return
        end
        if actor.carry == "plate_food" or actor.carry == "cup" then actor.carry = nil end
        if not p then return end
        p.present[actor.id] = nil
        if AT_TABLE[p.state] and not p.gone[actor.id] and p.seats[actor.id] == (act.target and act.target.oid) then
            if status == "failed" then
                Dn.Reseat(world, p, actor.id, "couldn't get to the seat")
            elseif (status == "cancelled" or status == "done") and not act.data.toCounter then
                p.away = p.away or {}
                p.away[actor.id] = world.time
                if p.household and status == "cancelled" then
                    V.Notice(world, actor.name .. " stepped away from the table; the seat is kept (Return to Table, or Pay and Leave).")
                end
            end
        end
    end,
    next = function(world, actor, act)
        if not (act.data and act.data.resit and act.target) then return nil end
        local p = Dn.Party(world, act.data.party or "")
        if not p or not AT_TABLE[p.state] or p.seats[actor.id] ~= act.target.oid then return nil end
        return { oid = act.target.oid, iid = act.iid, manual = act.manual, data = { party = p.id, quiet = true } }
    end,
}

-- At the waiter station's public side: order, collect food, or pay (the counter fallback).
I.dine_counter = {
    label = "Go to the Counter", category = "Food", slot = "pickup", pose = "talk", dur = 1.5, manualOnly = true, outings = true,
    advert = {},
    test = function(world, actor)
        local p = Dn.PartyOf(world, actor.id)
        if not p then return false, "Nothing to collect." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" then return end
        local p = Dn.Party(world, act.data.party or "") or Dn.PartyOf(world, actor.id)
        if not p then return end
        local kind = act.data.kind or "pickup"
        if kind == "order" then
            Dn.TakeOrders(world, p, nil, { onLot = true })
        elseif kind == "pay" then
            Dn.Pay(world, p, "at the counter")
        elseif kind == "pickup" or kind == "eat" then
            local d = Dn.State(world)
            for _, tk in ipairs(d.tickets) do
                if tk.party == p.id and tk.rid == actor.id and (tk.state == "counter" or tk.state == "ready") then
                    tk.state = "served"
                    local ord = p.orders[actor.id]
                    if ord and ord.state ~= "cancelled" and not BILLABLE[ord.state] then ord.state, ord.servedAt = "served", world.time end
                end
            end
            if p.state == "ordered" or p.state == "seated" then p.state = "eating" end
            act.data.collected = true
        end
    end,
    next = function(world, actor, act)
        local p = Dn.Party(world, act.data.party or "")
        if not p or not act.data.collected then return nil end
        local ord = p.orders[actor.id]
        if not ord or ord.state ~= "served" then return nil end
        local soid = p.seats[actor.id]
        local seat = soid and world.lot.objects[soid]
        if seat and not (p.counter and p.counter[actor.id]) then
            return { oid = soid, iid = V.IidFor(SS.Objects[seat.def], "dine_sit"), data = { party = p.id } }
        end
        return { oid = act.oid, iid = V.IidFor(SS.Objects[world.lot.objects[act.oid].def], "dine_counter_eat"), data = { party = p.id } }
    end,
}

I.dine_counter_eat = {
    label = "Eat at the Counter", category = "Food", slot = "pickup", pose = "eat_stand", maxDur = 60, manualOnly = true, outings = true, dining = true,
    advert = {},
    test = function(world, actor)
        local p = Dn.PartyOf(world, actor.id)
        local ord = p and p.orders[actor.id]
        if not ord or ord.state ~= "served" then return false, "No food waiting." end
        return true
    end,
    onStart = function(world, actor, act)
        local p = Dn.PartyOf(world, actor.id)
        if not p then return false, "No food waiting." end
        act.data.party = p.id
    end,
    onTick = function(world, actor, act, obj, dt)
        local p = Dn.Party(world, act.data.party)
        if not p or not eatTick(world, actor, act, p, dt, false) then act.complete = true end
    end,
    onEnd = function(world, actor) if actor.carry == "plate_food" or actor.carry == "cup" then actor.carry = nil end end,
}

SS.Tags.Attach("podium", "dine_request")
SS.Tags.Attach("waiter_station", "dine_counter")
SS.Tags.Attach("waiter_station", "dine_counter_eat")

---------------------------------------------------------------------------------------------------
-- The bill: once per party, only the household's money, only for dishes served.
function Dn.BillTotal(world, p)
    local total, items = 0, {}
    for _, rid in ipairs(p.members) do
        local ord = p.orders[rid]
        local m = ord and menuById[ord.item or ""]
        if m and BILLABLE[ord.state] then
            total = total + m.price
            items[#items + 1] = { rid = rid, item = m.id, name = m.name, price = m.price, eaten = ord.eaten or 0 }
        end
    end
    return total, items
end

function Dn.Pay(world, p, how)
    if p.bill and p.bill.paid then return true, "Already paid." end
    -- cancel what hasn't reached the table (never charged)
    for _, rid in ipairs(p.members) do cancelTicket(world, p, rid, "left before it was served") end
    local total, items = Dn.BillTotal(world, p)
    p.bill = { total = total, items = items, paid = true, at = world.time, how = how }
    local lotName = world.lot and world.lot.name or "the cafe"
    if p.household and total > 0 then
        -- the household pays for everyone at its own table (guests are its treat)
        local paid, rest, how2 = V.PayOrOwe(world, world.household.id, total, "dining", string.format("%s: meal for %d", lotName, #items))
        p.bill.charged = paid
        if rest <= 0 then
            tell(world, p, string.format("Paid %s for the meal %s.", U.fmtMoney(total), how or ""))
        else
            p.bill.owed, p.bill.owedHow = rest, how2
            tell(world, p, string.format("The household had only %s of the %s bill; the other %s %s.", U.fmtMoney(paid), U.fmtMoney(total), U.fmtMoney(rest),
                how2 == "bill" and "comes as a bill in the post" or "goes on the household's tab here, settled on the next visit"))
            V.ScoreEvent(world, "bill", -5, { p.lead })
        end
    elseif total > 0 then
        -- patrons: each pays for their own dish from their own household (a townie with no
        -- household pays from a pocket the save does not track)
        p.bill.charged = 0
        for _, it in ipairs(items) do
            local r = world.actors[it.rid] or rootOf(world).residents[it.rid]
            local hid = r and V.PayerOf(world, r)
            if hid then
                local paid, rest = V.PayOrOwe(world, hid, it.price, "dining", string.format("%s: %s", lotName, it.name))
                p.bill.charged = p.bill.charged + paid
                if rest > 0 then p.bill.owed = (p.bill.owed or 0) + rest end
            end
        end
    elseif p.household then
        tell(world, p, "Nothing was served, so there was nothing to pay.")
    end
    if p.state ~= "cancelled" then p.state = "paid" end
    p.paidAt = world.time
    local d = Dn.State(world)
    for _, t in ipairs(d and d.tasks or {}) do
        if t.party == p.id and (t.state == "open" or t.state == "doing") then t.state = "done" end
    end
    SS.Emit("dinerPaid", world, p, total)
    return true
end

-- Player: settle up now and get up from the table (works at every step).
function Dn.PayAndLeave(world, rid)
    local p = Dn.PartyOf(world, rid)
    if not p then return false, "Not dining right now." end
    if p.state == "checkin" or p.state == "waiting" then
        p.state, p.why = "cancelled", "left before being seated"
        tell(world, p, "Left before being seated; nothing to pay.")
        Dn.ReleaseParty(world, p)
        return true
    end
    Dn.Pay(world, p, "before leaving")
    Dn.ReleaseParty(world, p)
    return true
end

-- Everyone stands up (their table actions end at the next tick).
function Dn.ReleaseParty(world, p)
    if p.state == "paid" then p.state = "left" end
    p.leftAt = world.time
    for _, rid in ipairs(p.members) do
        local a = world.actors and world.actors[rid]
        if a and a.act and (V.BaseIid(a.act.iid) == "dine_sit" or V.BaseIid(a.act.iid) == "dine_counter_eat" or V.BaseIid(a.act.iid) == "dine_counter"
            or V.BaseIid(a.act.iid) == "dine_request") then
            a.act.complete = true
            a.act.stopRequested = true
        end
        if a and a.queue then
            for n = #a.queue, 1, -1 do
                local b = V.BaseIid(a.queue[n].iid)
                if b == "dine_sit" or b == "dine_counter" or b == "dine_counter_eat" then table.remove(a.queue, n) end
            end
        end
        if a and a.role == "venue_patron" and a.roleData then a.roleData.dined = true end
    end
    SS.Emit("dinerParty", world, p, "left")
end

-- A member left the venue (a date walked out, a patron's time was up).
function Dn.MemberGone(world, rid, why)
    local p = Dn.PartyOf(world, rid)
    if not p then return end
    p.gone[rid] = true
    p.present[rid] = nil
    cancelTicket(world, p, rid, why or "left")
    local r = rootOf(world).residents[rid]
    note(world, p, string.format("%s left the table (%s).", r and r.name or rid, why or "left"))
    local anyone = false
    for _, m in ipairs(p.members) do if not p.gone[m] then anyone = true end end
    if not anyone then
        Dn.Pay(world, p, "when the last diner left")
        Dn.ReleaseParty(world, p)
    end
end

-- A patron (or anyone) leaving: pay if they're the last, else just leave the table.
function Dn.LeaveParty(world, rid, why)
    local p = Dn.PartyOf(world, rid)
    if not p then return end
    local others = false
    for _, m in ipairs(p.members) do if m ~= rid and not p.gone[m] then others = true end end
    if others then Dn.MemberGone(world, rid, why) else Dn.Pay(world, p, "on the way out"); Dn.ReleaseParty(world, p) end
end

---------------------------------------------------------------------------------------------------
-- Patrons dine too (capped: two patron parties at a time, one meal each).
function Dn.PatronDine(world, a)
    if not Dn.IsCafe(world) or (a.roleData and a.roleData.dined) then return false end
    local d = Dn.State(world)
    local n = 0
    for _, p in ipairs(d.parties) do if p.patron and ACTIVE[p.state] then n = n + 1 end end
    if n >= 2 then return false end
    if not Dn.CanDine(world, a) then return false end
    local members = { a.id }
    -- sometimes two patrons share a table
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local b = world.actors[id]
        if #members < 2 and b ~= a and b.role == "venue_patron" and not b.act and not Dn.PartyOf(world, id)
            and not (b.roleData and (b.roleData.dined or b.roleData.leaving)) and SS.Random(world, "outings.patron") < 0.5 then
            members[#members + 1] = id
        end
    end
    local p = Dn.NewParty(world, a, { members = members, patron = true })
    local pod = podium(world)
    if pod then
        SS.Actions.Order(world, a, pod.id, V.IidFor(SS.Objects[pod.def], "dine_request"), nil, nil, { data = { party = p.id } })
    else
        p.state, p.checkinAt = "waiting", world.time
    end
    for _, rid in ipairs(members) do
        local b = world.actors[rid]
        if b and b.roleData then b.roleData.dined = true end
    end
    return true
end

---------------------------------------------------------------------------------------------------
-- The dining system: once a sim minute, move every party along (and apply the recovery rules).
local function allDone(world, p)
    local any = false
    for _, rid in ipairs(p.members) do
        if not p.gone[rid] then
            local ord = p.orders[rid]
            if ord then
                any = true
                local finished = ord.state == "eaten" or ord.state == "none" or ord.state == "cancelled"
                -- someone who walked off (missing) with a dish on the table doesn't hold up the bill
                if not finished and not (p.missing[rid] and ord.state == "served") then return false end
            elseif p.present[rid] or not p.missing[rid] then
                return false
            end
        end
    end
    return any
end

local function staffPresent(world, role)
    local s = V.StaffFor(world, role)
    return s and V.AtPost(world, s) and s or nil
end

function Dn.Tick(world, dt)
    if not Dn.IsCafe(world) then return end
    local d = Dn.State(world)
    d.acc = (d.acc or 0) + dt
    if d.acc < 1 then return end
    d.acc = 0
    local now = world.time
    for _, p in ipairs(d.parties) do
        -- seats that vanished
        if AT_TABLE[p.state] then
            for _, rid in ipairs(p.members) do
                local s = p.seats[rid]
                if s and not world.lot.objects[s] and not p.gone[rid] then Dn.Reseat(world, p, rid, "the chair was taken away") end
            end
        end
        if p.state == "checkin" then
            if now - p.createdAt >= 20 then Dn.CheckIn(world, p) end
        elseif p.state == "waiting" then
            if not staffPresent(world, "host") and now >= (p.checkinAt or now) + 5 then Dn.SeatParty(world, p, nil) end
            if p.state == "waiting" then
                local waited = now - (p.checkinAt or now)
                if waited >= T.tableWaitMax then
                    p.state, p.why = "cancelled", "no table came free"
                    tell(world, p, "No table came free after " .. math.floor(waited) .. " minutes, so the party gave up. Nothing was charged.")
                    V.ScoreEvent(world, "waiting", -6, p.members)
                    local lead = world.actors[p.lead]
                    if lead then V.Say(world, lead, "venue_wait", {}) end
                    Dn.ReleaseParty(world, p)
                elseif waited >= 15 and not p.waitNoted then
                    p.waitNoted = true
                    V.ScoreEvent(world, "waiting", -2, p.members)
                end
            end
        elseif p.state == "seating" then
            local present, want = 0, 0
            for _, rid in ipairs(p.members) do
                if not p.gone[rid] then
                    want = want + 1
                    if p.present[rid] then present = present + 1 end
                end
            end
            if want == 0 then
                p.state = "cancelled"
            elseif present == want or (present > 0 and now >= p.seatingAt + T.missingGrace) then
                p.state, p.seatedAt = "seated", now
                local rids = {}
                for _, rid in ipairs(p.members) do
                    if p.present[rid] then rids[#rids + 1] = rid
                    elseif not p.gone[rid] then
                        p.missing[rid] = true
                        local r = rootOf(world).residents[rid]
                        tell(world, p, string.format("%s hasn't come to the table; ordering without them for now.", r and r.name or rid))
                    end
                end
                Dn.AddTask(world, "order", p, { rids = rids })
            elseif present == 0 and now >= p.seatingAt + T.missingGrace * 2 then
                -- nobody made it to the table: give it back (nothing ordered, nothing charged)
                p.state, p.why = "cancelled", "nobody sat down"
                tell(world, p, "Nobody sat down, so the table was given to someone else.")
                Dn.ReleaseParty(world, p)
            end
        end
        if p.state == "seated" or p.state == "ordered" or p.state == "eating" then
            -- someone who stepped away and hasn't come back counts as missing after the grace
            for _, rid in ipairs(p.members) do
                if p.away and p.away[rid] and not p.present[rid] and not p.missing[rid] and now - p.away[rid] >= T.missingGrace then
                    p.missing[rid] = true
                    local r = rootOf(world).residents[rid]
                    note(world, p, string.format("%s hasn't come back to the table.", r and r.name or rid))
                end
            end
            -- plates left at the counter too long go back to the kitchen (not charged)
            for _, tk in ipairs(d.tickets) do
                if tk.party == p.id and tk.state == "counter" and now - (tk.readyAt or now) >= 30 then
                    cancelTicket(world, p, tk.rid, "nobody collected it")
                    tk.state = "cancelled"
                end
            end
            -- late arrivals get their order taken
            for _, rid in ipairs(p.members) do
                if p.present[rid] and not p.orders[rid] and not p.gone[rid] then
                    p.missing[rid] = nil
                    Dn.AddTask(world, "order", p, { rids = { rid } })
                end
            end
            -- a slow kitchen: the host apologises and cancels the dish (not charged)
            for _, rid in ipairs(p.members) do
                local ord = p.orders[rid]
                if ord and (ord.state == "ordered" or ord.state == "cooking") and now - ord.at >= T.foodWaitMax then
                    cancelTicket(world, p, rid, "the kitchen couldn't manage it")
                    local r = rootOf(world).residents[rid]
                    local host = staffPresent(world, "host")
                    tell(world, p, string.format("%s apologises: %s's dish never came out of the kitchen. It won't be on the bill.",
                        host and host.name or "The manager", r and r.name or rid))
                    V.ScoreEvent(world, "waiting", -6, { rid })
                    if world.actors[rid] then V.Say(world, world.actors[rid], "venue_wait", {}) end
                end
            end
            -- the table's own escalations: an open task nobody takes goes to the host, then the counter
            for _, t in ipairs(d.tasks) do
                if t.party == p.id and t.state == "open" then
                    local w = staffPresent(world, "waiter")
                    if not t.escalated and now - t.at >= 6 and (not w or (p.skip and p.skip[w.id])) then
                        t.escalated, t.escalatedAt = true, now
                    elseif t.escalated then
                        -- the host covers: give up on table service after 10 minutes when there is no
                        -- host who can reach this table, or after hostCoverWait when the host is
                        -- simply busy covering other tables
                        local host = V.StaffFor(world, "host")
                        local hostOut = not host or (p.skip and p.skip[host.id]) or t.failed[host.id]
                        local waited = now - (t.escalatedAt or now)
                        if waited >= (hostOut and 10 or (T.hostCoverWait or 25)) then Dn.CounterFallback(world, t, p) end
                    end
                end
            end
            -- ready food nobody is bringing (no serve task open): make one
            if Dn.ReadyFor(world, p.id) and not openTask(d, p, "serve") then
                local counter = false
                for _, tk in ipairs(d.tickets) do if tk.party == p.id and tk.state == "counter" then counter = true end end
                if not counter then Dn.AddTask(world, "serve", p) end
            end
            -- counter mode and the order still isn't in: send someone to the counter again (bounded),
            -- then the kitchen takes it through the hatch
            if p.counterMode and p.state == "seated" then
                local placed = false
                for _, rid in ipairs(p.members) do if p.orders[rid] then placed = true end end
                local lead
                for _, rid in ipairs(p.members) do if not lead and world.actors[rid] and not p.gone[rid] then lead = rid end end
                local la = lead and world.actors[lead]
                local going = la and ((la.act and V.BaseIid(la.act.iid) == "dine_counter") or (la.queue and la.queue[1] and V.BaseIid(la.queue[1].iid) == "dine_counter"))
                if not placed and not going then
                    p.counterSent = p.counterSent or {}
                    local k = p.counterSent.order or 0
                    local sent, busy = false, false
                    if la and k < 3 then
                        local _, why
                        sent, why, busy = Dn.CounterOrder(world, p, lead, "order")
                        if sent then p.counterSent.order = k + 1; if p.counterWait then p.counterWait.order = nil end end
                    end
                    if sent or (busy and counterWait(world, p, "order")) then
                        -- on the way, or waiting for the counter spot
                    else
                        Dn.TakeOrders(world, p, nil, { onLot = true })
                        tell(world, p, "The cook took the order through the kitchen hatch.")
                    end
                end
            end
            -- counter plates nobody collects: send the diner (once per minute, bounded by the executor)
            for _, tk in ipairs(d.tickets) do
                if tk.party == p.id and tk.state == "counter" and world.actors[tk.rid] and not p.gone[tk.rid] then
                    local a = world.actors[tk.rid]
                    if not a.act or (V.BaseIid(a.act.iid) ~= "dine_counter" and V.BaseIid(a.act.iid) ~= "dine_counter_eat") then
                        p.counterSent = p.counterSent or {}
                        if (p.counterSent[tk.rid] or 0) < 3 and not (a.queue and #a.queue > 0) then
                            local sent, _, busy = Dn.CounterOrder(world, p, tk.rid, "pickup")
                            if sent then
                                p.counterSent[tk.rid] = (p.counterSent[tk.rid] or 0) + 1
                                if p.counterWait then p.counterWait[tk.rid] = nil end
                            elseif not (busy and counterWait(world, p, tk.rid)) then
                                -- counted either way once the wait for the spot runs out
                                p.counterSent[tk.rid] = (p.counterSent[tk.rid] or 0) + 1
                            end
                        end
                    end
                end
            end
            if allDone(world, p) then
                p.state, p.billAt = "bill", now
                Dn.AddTask(world, "bill", p)
                note(world, p, "Asked for the bill.")
            end
        elseif p.state == "bill" then
            local t = openTask(d, p, "bill")
            if not t and not (p.bill and p.bill.paid) then Dn.AddTask(world, "bill", p) end
            if now - (p.billAt or now) >= 15 and not (p.bill and p.bill.paid) then
                Dn.Pay(world, p, "at the counter (nobody brought the bill)")
            end
        end
        if p.state == "paid" then Dn.ReleaseParty(world, p) end
    end
    -- the kitchen's plates for parties that ended are cleared
    for _, tk in ipairs(d.tickets) do
        if tk.state == "queued" or tk.state == "cooking" or tk.state == "ready" or tk.state == "counter" then
            local p = Dn.Party(world, tk.party)
            if not p or not AT_TABLE[p.state] then tk.state = "cancelled" end
        end
    end
end

-- Kitchen closes (venue closing): unserved dishes are cancelled; seated parties settle up.
function Dn.OnClose(world)
    local d = Dn.State(world)
    if not d then return end
    local any = false
    for _, p in ipairs(d.parties) do
        if ACTIVE[p.state] and p.state ~= "paid" then
            any = any or p.household
            if p.state == "checkin" or p.state == "waiting" then
                p.state, p.why = "cancelled", "closing"
                Dn.ReleaseParty(world, p)
            else
                Dn.Pay(world, p, "at closing")
                Dn.ReleaseParty(world, p)
            end
        end
    end
    if any then V.Notice(world, "The kitchen has closed; anything not yet served was taken off the bill.") end
end

-- Leaving the venue (going home, or an outing ended without the venue attached): every open
-- party pays once for what was served. Safe on a data-only session (no actors).
function Dn.Settle(world, reason)
    local d = Dn.State(world)
    if not d then return end
    for _, p in ipairs(d.parties) do
        if ACTIVE[p.state] and not (p.bill and p.bill.paid) then
            if p.state == "checkin" or p.state == "waiting" then
                p.state, p.why = "cancelled", reason or "left"
            else
                Dn.Pay(world, p, "on the way out")
            end
        end
        if p.state == "paid" then p.state, p.leftAt = "left", world.time end
    end
    for _, tk in ipairs(d.tickets) do
        if tk.state ~= "served" and tk.state ~= "cancelled" then tk.state = "cancelled" end
    end
    for _, t in ipairs(d.tasks) do if t.state == "open" or t.state == "doing" then t.state = "done" end end
end

-- After a load: tasks restart, the kitchen goes quiet until the cook is back, seated diners sit
-- back down (their seats and orders are saved), and nobody is charged again.
function Dn.OnAttach(world)
    if not Dn.IsCafe(world) then return end
    local d = Dn.State(world)
    for _, t in ipairs(d.tasks) do
        if t.state == "doing" then t.state, t.by, t.phase = "open", nil, nil end
    end
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a.roleData and a.roleData.task then a.roleData.task = nil end
    end
    for _, oid in ipairs(V.Anchors(world, "kitchen")) do
        local k = world.lot.objects[oid]
        if k.state then k.state.on, k.state.cooking = false, nil end
    end
    for _, p in ipairs(d.parties) do
        p.present = {}
        p.gone = p.gone or {}
        p.missing = p.missing or {}
        if p.state == "checkin" then p.state, p.checkinAt = "waiting", world.time end
        if AT_TABLE[p.state] then
            for _, rid in ipairs(p.members) do
                local a = world.actors[rid]
                if a and not p.gone[rid] and p.seats[rid] and not a.act then sitOrder(world, p, rid) end
            end
        end
        if p.state == "paid" then p.state = "left" end
    end
end

SS.Sim.Register({ name = "outings_dining", order = 62, tick = Dn.Tick, attach = Dn.OnAttach })

---------------------------------------------------------------------------------------------------
-- Reading for the UI
function Dn.MenuRows(world, rid)
    local p = rid and Dn.PartyOf(world, rid)
    local left = p and budgetLeft(world, p, rid) or (world.money or 0)
    local rows = {}
    for _, course in ipairs(Dn.COURSE_ORDER) do
        for _, m in ipairs(VD.menu) do
            if m.course == course then
                rows[#rows + 1] = { item = m, price = m.price, quality = m.quality, affordable = m.price <= left,
                    chosen = p and (p.wants[rid] == m.id or (p.orders[rid] and p.orders[rid].item == m.id)) or false }
            end
        end
    end
    return rows
end

local STATE_TEXT = {
    checkin = "Going to the host stand", waiting = "Waiting for a table", seating = "Being seated", seated = "Waiting to order",
    ordered = "Waiting for the food", eating = "Eating", bill = "Waiting for the bill", paid = "Paid", left = "Left", cancelled = "Gave up",
}
function Dn.StateText(p) return STATE_TEXT[p.state] or p.state end

local ORDER_TEXT = { ordered = "ordered", cooking = "in the kitchen", ready = "ready at the pass", counter = "waiting at the counter",
    served = "on the table", eaten = "finished", cancelled = "cancelled (not charged)", none = "water only" }
function Dn.OrderText(ord)
    if not ord then return "not ordered yet" end
    local m = menuById[ord.item or ""]
    local s = ORDER_TEXT[ord.state] or ord.state
    if ord.state == "served" and ord.eaten and ord.eaten > 0 then s = string.format("eating (%d%%)", math.floor(ord.eaten * 100)) end
    return (m and m.name or "Water") .. ": " .. s
end

-- Running bill (what would be charged now).
function Dn.RunningTotal(world, p)
    local total = Dn.BillTotal(world, p)
    return total
end
