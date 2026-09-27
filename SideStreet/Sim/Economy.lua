-- Household economy: bills through the mailbox, overdue warnings, the bill collector, property and
-- resale value, the household ledger summaries and the clearly labelled sandbox money option.
-- Owner: careers module (docs/modules/careers.md). Data: SS.CareerData.economy (Data/Careers.lua).
--
-- Saved data (all plain tables):
--   household.bills = { bill... }   bill = { id, kind, text, amount, items, created, state =
--       "posted"|"delivered"|"paid"|"collected"|"cancelled", deliveredAt, due, warned, seen, paidAt, collectionId }
--   household.econ  = { nextId, nextCycleAt, seen, arrears, mail = { item... }, collections = { col... },
--       daily = { [day] = { [cat] = sum, _in, _out } }, sandbox }
--   col = { id, bills = { billId... }, debt, remaining, paid, state = "scheduled"|"requested"|"arrived"|"waiting"|"done"|"cancelled",
--       at, visits, taken = { { oid, def, name, value, credit, t } } }
--       debt is what the bills came to; remaining is what is still owed (bills the household paid since
--       and goods the collector took both come off it); paid is what the household paid toward it.
--   bill.paidAmount: set when a bill of a collection was paid for less than its amount (the collector
--       had already covered the rest).
-- Scheduled events (lot-bound, home lot): "econ.collect" { col }.
-- Events emitted: "billRaised"(world, bill), "billsDelivered"(world, n), "billPaid"(world, bill),
--   "billOverdue"(world, bill, stage), "repossessed"(world, col, takenRecord), "collectionDone"(world, col).
local _, SS = ...
local E = SS.Economy or {}
SS.Economy = E
local U = SS.U

local function D() return SS.CareerData.economy end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function fmt(v) return U.fmtMoney(v) end
E.rt = E.rt or { vehicles = {}, structure = setmetatable({}, { __mode = "k" }) }

local function sortedIds(t)
    local ids = {}
    for k in pairs(t) do ids[#ids + 1] = k end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    return ids
end
E.SortedIds = sortedIds

-- The session is the household's home lot (bills, work and school only run there; venues skip).
function E.IsHome(world)
    local hh = world and world.household
    return hh ~= nil and world.lot ~= nil and hh.lotId == world.lot.id
end

function E.State(hh)
    if type(hh.bills) ~= "table" then hh.bills = {} end
    local st = hh.econ
    if type(st) ~= "table" then st = {}; hh.econ = st end
    st.nextId = st.nextId or 0
    st.arrears = st.arrears or 0
    st.mail = st.mail or {}
    st.collections = st.collections or {}
    st.daily = st.daily or {}
    return st
end

local function nextId(st, prefix)
    st.nextId = st.nextId + 1
    return prefix .. st.nextId
end

-- A spoken line through the social module's Lines situations (bill_arrived, bill_overdue, repo_visit).
-- Uses household-core's Actions.Say (cooldown + balloon) when present; never lets a line error stop
-- the economy.
local function say(world, actor, situation, ctx)
    if not actor or not world.actors[actor.id] then return end
    if SS.Actions and SS.Actions.Say then
        local ok, text = pcall(SS.Actions.Say, world, actor, situation, ctx or {})
        return ok and text or nil
    end
    if SS.Lines and SS.Lines.Say then
        local ok, text = pcall(SS.Lines.Say, world, actor, situation, ctx or {})
        if ok and text and SS.Actions and SS.Actions.Message then SS.Actions.Message(world, actor, text, "bubble") end
        return ok and text or nil
    end
end

local function journal(world, text)
    if SS.Actions and SS.Actions.Journal and world.journal then SS.Actions.Journal(world, text) end
end

local function record(world, kind, data)
    if SS.Events and SS.Events.Record then return SS.Events.Record(world, kind, data) end
end

local function message(world, text, icon)
    -- a household-wide notice: shown on the first adult present, else as a UI notice
    local who
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and not a.role and world.household and a.householdId == world.household.id and a.age ~= "infant" then who = a; break end
    end
    if who and SS.Actions and SS.Actions.Message then SS.Actions.Message(world, who, text, icon)
    elseif SS.UI and SS.UI.Notice then SS.UI.Notice(text) end
    return who
end
E.HouseholdMessage = message

-- First household adult on the lot (for lines and messages).
function E.AnyAdult(world)
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and not a.role and world.household and a.householdId == world.household.id and a.age == "adult" and not a.dead then return a end
    end
end

---------------------------------------------------------------------------------------------------
-- Ledger categories and daily summaries
---------------------------------------------------------------------------------------------------
-- Ledger category for a raw SS.Money category. Generic raw categories ("expense", "other", none)
-- are refined by the entry text through D.ledger.textMap (e.g. "Groceries: ..." is food), so
-- modules that charge through the generic path still land in a useful category.
function E.Cat(raw, text)
    local l = D().ledger
    local c = l.map[raw or "other"] or "other"
    if c == "other" and type(text) == "string" then
        for _, rule in ipairs(l.textMap or {}) do
            if text:find(rule[1]) then return rule[2] end
        end
    end
    return c
end
function E.CatLabel(cat) return D().ledger.labels[cat] or cat end

-- Every SS.Money call emits "money"(delta, text, cat[, world]). We add it to the household's daily
-- totals. We only count it when the household's newest ledger entry is that exact transaction, so a
-- money event from a different (non-attached) household is never attributed to this one.
local function onMoney(delta, text, cat, world)
    world = world or SS.Sim.world
    local hh = world and world.household
    if not hh or type(hh.ledger) ~= "table" then return end
    local last = hh.ledger[#hh.ledger]
    if not last or last.amount ~= delta or last.text ~= text or last.counted then return end
    last.counted = true
    local st = E.State(hh)
    local day = math.floor((last.t or world.time or 0) / 1440)
    local row = st.daily[day]
    if not row then row = {}; st.daily[day] = row end
    local c = E.Cat(cat, text)
    row[c] = (row[c] or 0) + delta
    if delta > 0 then row._in = (row._in or 0) + delta elseif delta < 0 then row._out = (row._out or 0) - delta end
end
SS.On("money", onMoney)

local function pruneDaily(st, today)
    local keep = D().ledger.keepDays
    for day in pairs(st.daily) do
        if type(day) ~= "number" or day < today - keep then st.daily[day] = nil end
    end
end

-- Totals over the last `days` days (including today): { [cat] = sum }, income, spending.
function E.Summary(world, days, hh)
    hh = hh or world.household
    local st = E.State(hh)
    local today = math.floor(world.time / 1440)
    local out, inc, spend = {}, 0, 0
    for day = today - (days or 7) + 1, today do
        local row = st.daily[day]
        if row then
            for k, v in pairs(row) do
                if k == "_in" then inc = inc + v elseif k == "_out" then spend = spend + v else out[k] = (out[k] or 0) + v end
            end
        end
    end
    return out, inc, spend
end

-- Ledger entries newest first, filtered: filter = nil | "in" | "out" | category name.
function E.LedgerEntries(world, filter, hh)
    hh = hh or world.household
    local out = {}
    local l = hh and hh.ledger or {}
    for n = #l, 1, -1 do
        local e = l[n]
        local ok = true
        if filter == "in" then ok = e.amount > 0
        elseif filter == "out" then ok = e.amount < 0
        elseif filter then ok = E.Cat(e.cat, e.text) == filter end
        if ok then out[#out + 1] = e end
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Value: resale (depreciation), structure, lot value, net worth, land price
---------------------------------------------------------------------------------------------------
-- Mark objects as used the first time any action starts on them (ends the same-day full refund).
SS.On("actionStarted", function(actor, act)
    local world = SS.Sim.world
    if not world or not act then return end
    local oid = (act.target and act.target.oid) or act.oid
    local o = oid and world.lot.objects[oid]
    if o and not o.used then o.used = world.time end
end)

-- What an object would sell for now. obj.value (crafted items) overrides the price; def.appreciates
-- items keep their value. Same day and unused: full price back (catalogue's "changed my mind" rule).
function E.ResaleValue(world, obj)
    local def = obj and SS.Objects[obj.def]
    if not def or def.resale == false then return 0 end
    local base = obj.value or obj.paid or def.price or 0
    if base <= 0 then return 0 end
    local dep = D().depreciation
    local t = (world and world.time) or 0
    if obj.bought and not obj.used and t - obj.bought < dep.sameDayMinutes and t >= obj.bought then return math.floor(base) end
    local factor
    if def.appreciates or obj.appreciates then
        factor = 1
    else
        local days = obj.bought and math.max(0, (t - obj.bought) / 1440) or 60 -- premade furniture: long owned
        factor = math.max(dep.floor, dep.initial - dep.perDay * days)
    end
    local st = obj.state
    if st then
        if st.burnt then factor = factor * dep.burnt elseif st.broken then factor = factor * dep.broken end
        if st.dirty then factor = factor * dep.dirty end
    end
    return math.floor(base * factor)
end

local function finishPrice(kind, id)
    local t = SS.Finishes and SS.Finishes[kind]
    local f = t and id and t[id]
    return f and f.price
end

-- Value of walls, openings, floors, extra stories, roof and pool (D.structure). The same rule and
-- numbers as the neighbourhood module's own appraisal (hood's H.StructureValue, used when careers is
-- absent), so a house costs the same whichever module prices it. Cached per lot version; a lotChanged
-- that can change the structure (anything but an object's state) starts a new cache generation.
local LAWN = { grass = true, lawn = true }
function E.StructureValue(lot)
    local c = E.rt.structure[lot]
    if c and c.version == lot.version and c.gen == E.rt.structureGen then return c.value end
    local s = D().structure
    local v = 0
    for _, walls in pairs(lot.walls or {}) do
        for _, wl in pairs(walls) do
            local k = wl.kind or "wall"
            if k == "wall" then
                v = v + s.wall + (finishPrice("walls", wl.a) or s.wallFinish) + (finishPrice("walls", wl.b) or s.wallFinish)
            else
                v = v + (s[k] or s.wall)
            end
        end
    end
    local stories = 0
    for lv, fl in pairs(lot.floor or {}) do
        local any = false
        for _, fid in pairs(fl) do
            if not LAWN[fid] then
                v = v + s.floorBase + (finishPrice("floors", fid) or s.floorFinish)
                any = true
            end
        end
        if any and lv > 0 then stories = stories + 1 end
    end
    v = v + stories * s.storyBonus
    -- roofed cells: every upper-floor cell, and ground cells indoors (not lawn, path or deck) with no floor above
    if lot.roof then
        local f0, f1 = (lot.floor or {})[0] or {}, (lot.floor or {})[1] or {}
        local roofed = 0
        for _ in pairs(f1) do roofed = roofed + 1 end
        for k, fid in pairs(f0) do
            local id = tostring(fid)
            if not LAWN[fid] and not f1[k] and not id:find("path", 1, true) and not id:find("deck", 1, true) then roofed = roofed + 1 end
        end
        v = v + roofed * s.roofPerTile
    end
    for _ in pairs(lot.pool or {}) do v = v + s.poolPerTile end
    v = math.floor(v)
    if c then c.version, c.value, c.gen = lot.version, v, E.rt.structureGen
    else E.rt.structure[lot] = { version = lot.version, value = v, gen = E.rt.structureGen } end
    return v
end
E.rt.structureGen = E.rt.structureGen or 0
-- (object state changes - lights, dirt, the mailbox flag - are most lotChanged events and change no structure)
SS.On("lotChanged", function(kind)
    if kind ~= "state" then E.rt.structureGen = E.rt.structureGen + 1; E.rt.mailbox = nil end
end)

local function isSystem(def) return def.cat == "system" or def.buyable == false end

-- Land value: the lot's price as set by the neighbourhood module; an unpriced lot (nil or 0, as in
-- the stage-1 fixture) is valued by its size on the vacant-land scale.
function E.LandValue(lot)
    local p = tonumber(lot and lot.price)
    if p and p > 0 then return p end
    return lot and lot.w and lot.h and E.LandPrice(lot.w, lot.h) or 0
end

-- Lot value: land + structure + contents (resale). Returns total, land, structure, contents.
function E.LotValue(world, lot)
    lot = lot or (world and world.lot)
    if not lot then return 0, 0, 0, 0 end
    local land = E.LandValue(lot)
    local structure = E.StructureValue(lot)
    local contents = 0
    for _, o in pairs(lot.objects or {}) do
        local def = SS.Objects[o.def]
        if def and (not isSystem(def) or o.value) then contents = contents + E.ResaleValue(world, o) end
    end
    return land + structure + contents, land, structure, contents
end

-- Cash + home value + stored items. Returns total, cash, home, stored.
function E.NetWorth(world, hh)
    hh = hh or world.household
    if not hh then return 0, 0, 0, 0 end
    local root = world.root or world
    local lot = hh.lotId and root.hood and root.hood.lots[hh.lotId]
    local home = lot and E.LotValue(world, lot) or 0
    local stored = 0
    for _, it in ipairs(hh.inventory or {}) do stored = stored + (tonumber(it.value) or 0) end
    return (hh.money or 0) + home + stored, hh.money or 0, home, stored
end

-- Vacant residential land price for a lot of w x h cells (§9.7 band).
function E.LandPrice(w, h)
    local l = D().land
    return math.floor(clamp(l.perCell * w * h, l.min, l.max) / 100 + 0.5) * 100
end

---------------------------------------------------------------------------------------------------
-- Bills and mail
---------------------------------------------------------------------------------------------------
local POWERED_TAGS = { fridge = true, stove = true, oven = true, microwave = true, coffee = true, toaster = true,
    dishwasher = true, tv = true, stereo = true, radio = true, computer = true, game = true, arcade = true, pinball = true,
    dj = true, burglar_alarm = true, grill = false }
local PLUMBING_TAGS = { toilet = true, shower = true, bath = true, sink = true, basin = true, dishwasher = true }

local function tagIn(def, set)
    for _, t in ipairs(def.tags or {}) do if set[t] then return true end end
    return false
end
function E.IsPowered(def)
    if def.powered ~= nil then return def.powered and true or false end
    if def.cat == "electronics" or tagIn(def, POWERED_TAGS) then return true end
    -- untagged legacy kitchen appliances (fridge_basic, stove_basic): the expensive, non-surface ones
    return def.cat == "kitchen" and not def.surface and not def.surfaces and (def.price or 0) >= 200
end
function E.IsPlumbing(def) return def.cat == "plumbing" or tagIn(def, PLUMBING_TAGS) end

-- The regular bill for this lot: property levy from lot value + utilities per appliance/fixture/light
-- + a service charge. Returns amount, items.
function E.CycleBill(world)
    local b = D().bills
    local value = E.LotValue(world, world.lot)
    local levy = value * b.levyRate
    local powered, plumbing, lights = 0, 0, 0
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        if def and not isSystem(def) then
            if E.IsPowered(def) then powered = powered + 1 end
            if E.IsPlumbing(def) then plumbing = plumbing + 1 end
            if (def.light or 0) > 0 then lights = lights + 1 end
        end
    end
    local util = powered * b.utilities.powered + plumbing * b.utilities.plumbing + lights * b.utilities.light
    local _, pr = E.Pressure(world)
    local raw = math.floor(levy + 0.5) + util + b.base
    local total = clamp(math.floor(raw * pr.bills + 0.5), b.min, b.max)
    local items = {
        { "Property levy (" .. fmt(value) .. " home)", math.floor(levy + 0.5) },
        { string.format("Power and water (%d appliances, %d fixtures, %d lights)", powered, plumbing, lights), util },
        { "Service charge", b.base },
    }
    -- the items always add up to the total: money pressure and the min/max limits get their own line
    if total ~= raw then
        local why = pr.bills ~= 1 and (pr.label .. " money pressure") or (total < raw and "Maximum bill" or "Minimum bill")
        items[#items + 1] = { why, total - raw }
    end
    return total, items
end

-- Money pressure (optional difficulty, saved in world.settings.moneyPressure). Returns id, level def.
function E.Pressure(world)
    local P = D().pressure
    local id = world and world.settings and world.settings.moneyPressure
    if not (id and P.levels[id]) then id = P.default end
    return id, P.levels[id]
end

-- Change the money pressure for this save; takes effect from the next bill and the next shift.
function E.SetPressure(world, id)
    local P = D().pressure
    if not (world and P.levels[id]) then return false, "Unknown money pressure: " .. tostring(id) .. "." end
    world.settings = world.settings or {}
    local old = E.Pressure(world)
    world.settings.moneyPressure = id
    local lv = P.levels[id]
    local text = string.format("Money pressure is now %s: %s", lv.label, lv.desc)
    if old ~= id then journal(world, string.format("Money pressure changed from %s to %s.", P.levels[old].label, lv.label)) end
    return true, text
end

-- The wage actually paid for a shift whose listed pay is `base` (money pressure applied).
function E.WageFor(world, base)
    local _, pr = E.Pressure(world)
    return math.floor((base or 0) * pr.wages + 0.5)
end

local function trimBills(hh)
    local keep = D().bills.keepSettled
    local settled = 0
    for n = #hh.bills, 1, -1 do
        local b = hh.bills[n]
        if b.state == "paid" or b.state == "collected" or b.state == "cancelled" then
            settled = settled + 1
            if settled > keep then table.remove(hh.bills, n) end
        end
    end
end

-- Raise a bill for the household. It goes into the post and is delivered to the mailbox at the next
-- delivery (10:00), then it has a due period. Returns the bill (stub signature kept; opts optional:
-- { items = {...}, deliverNow = bool }).
function E.Bill(world, amount, kind, text, opts)
    local hh = world and world.household
    amount = tonumber(amount)
    if not hh or not amount or amount <= 0 then return nil end
    local st = E.State(hh)
    local b = { id = nextId(st, "bill"), kind = kind or "misc", text = text or "Bill", amount = math.floor(amount + 0.5),
        items = opts and opts.items, created = world.time, state = "posted" }
    hh.bills[#hh.bills + 1] = b
    trimBills(hh)
    SS.Emit("billRaised", world, b)
    if opts and opts.deliverNow then E.DeliverMail(world) end
    return b
end

-- Non-bill post (school notes, final notices). kind = "note"|"notice".
function E.Post(world, kind, text, data)
    local hh = world and world.household
    if not hh then return nil end
    local st = E.State(hh)
    local m = { id = nextId(st, "mail"), kind = kind or "note", text = text, data = data, created = world.time, state = "posted" }
    st.mail[#st.mail + 1] = m
    while #st.mail > 20 do table.remove(st.mail, 1) end
    return m
end

-- The lot's mailbox (the lowest id when there are several). Found once per lot version (a lotChanged
-- that is not a state change also forgets it), so autonomy and the mail flag do not scan every object.
function E.Mailbox(world)
    local lot = world.lot
    local c = E.rt.mailbox
    if c and c.lot == lot and c.version == lot.version then
        local o = c.id and lot.objects[c.id]
        if not c.id or o then return o end
    end
    local best
    for oid, o in pairs(lot.objects) do
        local def = SS.Objects[o.def]
        if def and SS.Tags.Has(def, "mailbox") and (not best or tostring(oid) < tostring(best)) then best = oid end
    end
    if c then c.lot, c.version, c.id = lot, lot.version, best
    else E.rt.mailbox = { lot = lot, version = lot.version, id = best } end
    return best and lot.objects[best]
end

local function setFlag(world, on)
    local mb = E.Mailbox(world)
    if not mb then return end
    mb.state = mb.state or {}
    if (mb.state.mail or false) ~= on then
        mb.state.mail = on or nil
        SS.Emit("lotChanged", "state", mb.id)
    end
end

-- Unread delivered mail: bills not yet seen, notes not yet read.
function E.UnreadMail(world)
    local hh = world.household
    local st = E.State(hh)
    local bills, notes = {}, {}
    for _, b in ipairs(hh.bills) do if b.state == "delivered" and not b.seen then bills[#bills + 1] = b end end
    for _, m in ipairs(st.mail) do if m.state == "delivered" then notes[#notes + 1] = m end end
    return bills, notes
end

-- Runtime vehicles on the street (visitors owns SS.Street.vehicles; everything here is guarded).
-- With the visitors module's street (SS.Street.CallVehicle) the vehicle drives in, is held at the
-- curb while we wait for riders and drives off when released. Without it we append a plain entry
-- to SS.Street.vehicles in the documented shape ({ kind, i, state, t, wait, hold, owner }) and
-- remove it ourselves a few minutes after it "leaves". opts.parked: appear already parked (after a load).
local HOLD_WAIT = 240 -- the street's maximum wait; our own events release the vehicle long before

function E.AddVehicle(world, key, kind, opts)
    local St = SS.Street
    if not St then return nil end
    E.RemoveVehicle(world, key, true)
    local v
    if St.CallVehicle then
        v = St.CallVehicle(world, kind, { owner = "careers", hold = true, wait = HOLD_WAIT, parked = opts and opts.parked })
        if v then v.key = key end
    elseif St.AddVehicle then
        v = St.AddVehicle(world, kind, { owner = "careers", key = key })
    elseif type(St.vehicles) == "table" then
        local i = St.EntryCell and St.EntryCell(world) or 0
        v = { kind = kind, i = i, state = "parked", t = 0, wait = HOLD_WAIT, hold = true, owner = "careers", key = key }
        St.vehicles[#St.vehicles + 1] = v
    end
    if v then E.rt.vehicles[key] = v end
    return v
end

local function dropFromStreet(v)
    local St = SS.Street
    if St and type(St.vehicles) == "table" then
        for n = #St.vehicles, 1, -1 do if St.vehicles[n] == v then table.remove(St.vehicles, n) end end
    end
end

-- Send a vehicle away (instant = vanish at once, used when replacing or on reload).
function E.RemoveVehicle(world, key, instant)
    local v = E.rt.vehicles[key]
    if not v then return end
    E.rt.vehicles[key] = nil
    local St = SS.Street
    if instant then dropFromStreet(v); return end
    if St and St.ReleaseVehicle then St.ReleaseVehicle(world, v); return end
    if St and St.RemoveVehicle then St.RemoveVehicle(world, v); return end
    v.state, v.leftAt, v.hold = "leaving", world.time, nil
    E.rt.leaving = E.rt.leaving or {}
    E.rt.leaving[#E.rt.leaving + 1] = v
end

-- The id riders should board when the street walks departing people to their vehicle (visitors'
-- SS.Visitors.BeginDeparture); nil when there is no such street or the vehicle is not waiting.
function E.VehicleFor(world, key)
    local v = E.rt.vehicles[key]
    if not v or not v.id or v.state == "leaving" then return nil end
    if not (SS.Visitors and SS.Visitors.BeginDeparture and SS.Street and SS.Street.VehicleById) then return nil end
    return v.id
end

-- Hand a waiting vehicle to the street for `rids` to board: it is no longer held and leaves once
-- they are aboard (the street's own rule). Without walking departures it simply drives off.
-- Returns the vehicle id riders should board, or nil.
function E.HandOverVehicle(world, key, rids)
    local vid = E.VehicleFor(world, key)
    if not vid then E.RemoveVehicle(world, key); return nil end
    local v = E.rt.vehicles[key]
    E.rt.vehicles[key] = nil
    v.hold = nil
    v.expect = #rids
    v.expectRids = {}
    for n = 1, #rids do v.expectRids[n] = rids[n] end
    return vid
end

local function tickVehicles(world)
    local l = E.rt.leaving
    if not l or #l == 0 then return end
    local St = SS.Street
    for n = #l, 1, -1 do
        local v = l[n]
        if world.time - (v.leftAt or 0) >= 3 or world.time < (v.leftAt or 0) then
            table.remove(l, n)
            dropFromStreet(v)
        end
    end
end
E.TickVehicles = tickVehicles

function E.VehicleShown(key) return E.rt.vehicles[key] ~= nil end

-- Is there a post round today? The visitors module's mail carrier keeps its own days (no post on
-- Sundays there); without it the post comes every day.
function E.IsMailDay(world)
    local V = SS.Visitors
    local md = V and V.SpawnMail and SS.RoleData and SS.RoleData.tuning and SS.RoleData.tuning.mail
    if md and md.weekdays then return md.weekdays[math.floor(world.time / 1440) % 7] and true or false end
    return true
end

-- Deliver everything in the post: bills get their due date; the mailbox flag goes up.
-- Called at the delivery hour (mail van), or by the visitors module's mail carrier on arrival as
-- SS.Economy.DeliverMail(world, mailbox) (the lot has one mailbox; the flag goes on the one found by
-- tag). Idempotent. Returns the number of items delivered. Emits "billsDelivered"(world, n); the
-- visitors module emits its own "mailDelivered"(world, box, carrier, n).
-- only (optional): deliver just this one bill or mail item (a final notice comes by special delivery;
-- everything else in the post waits for the carrier).
function E.DeliverMail(world, box, only)
    local hh = world and world.household
    if not hh then return 0 end
    local st = E.State(hh)
    local b = D().bills
    local n, billN, total = 0, 0, 0
    for _, bill in ipairs(hh.bills) do
        if bill.state == "posted" and (not only or only == bill) then
            bill.state = "delivered"
            bill.deliveredAt = world.time
            bill.due = world.time + b.dueDays * 1440
            bill.warned = 0
            n, billN, total = n + 1, billN + 1, total + bill.amount
        end
    end
    for _, m in ipairs(st.mail) do
        if m.state == "posted" and (not only or only == m) then m.state = "delivered"; m.deliveredAt = world.time; n = n + 1 end
    end
    if n == 0 then return 0 end
    setFlag(world, true)
    local text
    if billN > 0 then
        text = string.format("The mail is here: %d bill%s (%s). Get the mail or pay at the mailbox.", billN, billN == 1 and "" or "s", fmt(total))
    elseif only and only.kind == "notice" then
        text = "A final notice came by special delivery. It is in the mailbox."
    else
        text = "The mail is here."
    end
    if not E.Mailbox(world) then
        text = text .. " There is no mailbox, so it was left on the doorstep: pay from the Money tab."
    end
    message(world, text, "mail")
    local adult = E.AnyAdult(world)
    if billN > 0 and adult then say(world, adult, "bill_arrived", { amount = total, count = billN }) end
    SS.Emit("billsDelivered", world, n)
    return n
end

-- Collect the post (Get Mail): bills are marked seen, notes are read out. Lowers the flag.
function E.GetMail(world, actor)
    local bills, notes = E.UnreadMail(world)
    local total = 0
    for _, b in ipairs(bills) do b.seen = true; total = total + b.amount end
    for _, m in ipairs(notes) do
        m.state = "read"
        if SS.Actions and SS.Actions.Message then SS.Actions.Message(world, actor, m.text, "mail") end
        journal(world, m.text)
    end
    setFlag(world, false)
    if #bills > 0 and SS.Actions and SS.Actions.Message then
        SS.Actions.Message(world, actor, string.format("%d bill%s to pay, %s in total.", #bills, #bills == 1 and "" or "s", fmt(total)), "mail")
        say(world, actor, "bill_arrived", { amount = total, count = #bills })
    end
    return #bills, #notes, total
end

local function collectionOf(world, id)
    if not id then return nil end
    local st = E.State(world.household)
    for _, c in ipairs(st.collections) do if c.id == id then return c end end
end
E.Collection = collectionOf

-- Can this bill be paid now? (Not once the collector is already on the lot for it.)
local function payable(world, b)
    if b.state ~= "delivered" then return false end
    local col = collectionOf(world, b.collectionId)
    if col and (col.state == "arrived" or col.state == "done") then return false end
    return true
end
E.Payable = payable

function E.OpenBills(world, hh)
    hh = hh or world.household
    local out = {}
    for _, b in ipairs(hh and hh.bills or {}) do
        if b.state == "delivered" or b.state == "posted" then out[#out + 1] = b end
    end
    return out
end

function E.PayableBills(world)
    local out = {}
    for _, b in ipairs(world.household.bills or {}) do if payable(world, b) then out[#out + 1] = b end end
    return out
end

-- What paying bill `b` costs now. A bill that belongs to an open collection costs at most what the
-- collection still has outstanding: col.remaining is the one running total of the debt (bills paid
-- by the household and goods the collector took both come off it), so paying the last bills of a
-- collection after the collector already took something never pays that part twice.
local function owed(world, b)
    local col = collectionOf(world, b.collectionId)
    if col and col.state ~= "done" and col.state ~= "cancelled" then
        return math.max(0, math.min(b.amount, col.remaining or b.amount))
    end
    return b.amount
end
E.Owed = owed

local function unscheduleCollect(world, col)
    SS.Sim.Unschedule(world, function(ev) return ev.kind == "econ.collect" and ev.data and ev.data.col == col.id end)
end

local finishCollection -- (defined with the collector below)

-- The household paid `amount` toward collection `col` (one of its bills). The collection's
-- outstanding debt goes down by exactly that; when nothing is left the visit is called off
-- (nothing was taken yet) or closed (goods were taken on an earlier visit, and finishCollection
-- marks any bill they covered as collected). Returns the collection's state.
local function settleTowardCollection(world, col, amount)
    if not col or col.state == "done" or col.state == "cancelled" then return col and col.state end
    col.remaining = math.max(0, (col.remaining or 0) - amount)
    col.paid = (col.paid or 0) + amount
    if col.remaining > 0 then return col.state end
    unscheduleCollect(world, col)
    -- a collector already asked of the visitors framework is called off (nobody comes for a paid debt)
    if col.requestId and SS.Visitors and SS.Visitors.CancelRequest then pcall(SS.Visitors.CancelRequest, world, col.requestId, "paid") end
    if #col.taken > 0 then
        finishCollection(world, col, "paid")
    else
        col.state = "cancelled"
        col.doneAt = world.time
        if col.eventId and SS.Events and SS.Events.Resolve then pcall(SS.Events.Resolve, world, col.eventId, "paid") end
    end
    return col.state
end
E.SettleTowardCollection = settleTowardCollection

-- Is there still something for the collector to collect? A collection whose remaining debt is
-- zero, or none of whose bills is still unpaid, is closed here (called before every visit).
function E.CollectionOpen(world, col)
    if not col or col.state == "done" or col.state == "cancelled" then return false end
    local unpaid = false
    for _, id in ipairs(col.bills) do
        for _, b in ipairs(world.household.bills) do
            if b.id == id and b.state == "delivered" then unpaid = true end
        end
    end
    if not unpaid then col.remaining = 0 end
    if col.remaining <= 0 then settleTowardCollection(world, col, 0); return false end
    return true
end

-- Pay one bill (billId) or every payable bill, oldest first, while money lasts. Each bill is one
-- ledger entry. A bill that is part of an open collection also lowers what the collector comes for.
-- Returns paidCount, paidTotal, unpaidCount, why.
function E.PayBills(world, actor, billId)
    local hh = world.household
    if not hh then return 0, 0, 0, "No household." end
    local st = E.State(hh)
    local list = {}
    for _, b in ipairs(hh.bills) do
        if (not billId or b.id == billId) and payable(world, b) then list[#list + 1] = b end
    end
    table.sort(list, function(a, b) return a.created < b.created or (a.created == b.created and a.id < b.id) end)
    if #list == 0 then return 0, 0, 0, "There are no bills to pay." end
    local paid, total, left = 0, 0, 0
    for _, b in ipairs(list) do
        -- an earlier bill in this loop may have closed its collection (and settled this one)
        if payable(world, b) then
            local amount = owed(world, b)
            if (hh.money or 0) >= amount then
                local col = collectionOf(world, b.collectionId)
                b.state, b.paidAt, b.seen = "paid", world.time, true
                if amount ~= b.amount then b.paidAmount = amount end
                if amount > 0 then
                    local text = "Paid: " .. b.text
                    if amount < b.amount then text = text .. " (the rest was covered by the collector)" end
                    SS.Money(world, -amount, "bills", text)
                end
                paid, total = paid + 1, total + amount
                SS.Emit("billPaid", world, b)
                if col then settleTowardCollection(world, col, amount) end
            else
                left = left + 1
            end
        end
    end
    -- paying at the mailbox also takes the post out of it
    local bills, notes = E.UnreadMail(world)
    if #notes == 0 then
        for _, b in ipairs(bills) do b.seen = true end
        setFlag(world, false)
    end
    trimBills(hh)
    local why
    if left > 0 then why = string.format("Not enough money for %d bill%s.", left, left == 1 and "" or "s") end
    if actor and SS.Actions and SS.Actions.Message then
        if paid > 0 then
            SS.Actions.Message(world, actor, string.format("Paid %d bill%s (%s).%s", paid, paid == 1 and "" or "s", fmt(total), why and (" " .. why) or ""), "mail")
        elseif why then
            SS.Actions.Message(world, actor, why, "mail")
        end
    end
    return paid, total, left, why
end

---------------------------------------------------------------------------------------------------
-- Overdue bills and the collector
---------------------------------------------------------------------------------------------------
local function eligible(world, o)
    local def = SS.Objects[o.def]
    if not def or isSystem(def) then return false end
    if def.structural or def.stairs or (type(def.cat) == "string" and def.cat:sub(1, 6) == "build_") then return false end
    if def.community or def.staffOnly or o.owner and world.household and o.owner ~= world.household.id then return false end
    if SS.Tags.Has(def, "memorial") or SS.Tags.Has(def, "mailbox") or SS.Tags.Has(def, "smoke_alarm") then return false end
    if o.res and next(o.res) then return false end
    return E.ResaleValue(world, o) > 0
end
E.Repossessable = eligible

-- The cheapest eligible object that covers `debt`, else the most valuable one (ties by id).
function E.PickRepossession(world, debt, skip)
    local cover, coverV, best, bestV
    for _, oid in ipairs(sortedIds(world.lot.objects)) do
        local o = world.lot.objects[oid]
        if not (skip and skip[oid]) and eligible(world, o) then
            local v = E.ResaleValue(world, o)
            if v >= debt and (not coverV or v < coverV) then cover, coverV = oid, v end
            if not bestV or v > bestV then best, bestV = oid, v end
        end
    end
    return cover or best
end

finishCollection = function(world, col, why)
    if col.state == "done" then return end
    local hh = world.household
    local st = E.State(hh)
    for _, id in ipairs(col.bills) do
        for _, b in ipairs(hh.bills) do
            if b.id == id and b.state == "delivered" then b.state, b.paidAt, b.seen = "collected", world.time, true end
        end
    end
    local taken = 0
    for _, t in ipairs(col.taken) do taken = taken + t.value end
    col.state = "done"
    col.doneAt = world.time
    if col.remaining > 0 then
        st.arrears = st.arrears + col.remaining
        message(world, string.format("The collector took what they could. %s is still owed and will be withheld from wages.", fmt(col.remaining)), "mail")
    end
    -- what the collector settled: the debt less what the household paid toward it and any arrears
    local settled = math.max(0, col.debt - (col.paid or 0) - col.remaining)
    journal(world, string.format("The bill collector settled %s of overdue bills%s.", fmt(settled),
        #col.taken > 0 and (" by taking " .. #col.taken .. " item" .. (#col.taken == 1 and "" or "s") .. " worth " .. fmt(taken)) or ""))
    if col.eventId and SS.Events and SS.Events.Resolve then SS.Events.Resolve(world, col.eventId, why or "collected") end
    trimBills(hh)
    SS.Emit("collectionDone", world, col)
end

-- The commit point of a repossession: remove the object, record it, settle once. Atomic (one call),
-- so a save can never split it. Returns true if something was taken.
function E.Repossess(world, col, oid)
    local o = world.lot.objects[oid]
    if not o or not col or col.state == "done" or col.state == "cancelled" then return false end
    local def = SS.Objects[o.def]
    local v = E.ResaleValue(world, o)
    -- a household adult reacts to the first thing taken (social's "repo_visit" lines name the object)
    if #col.taken == 0 then
        local adult = E.AnyAdult(world)
        if adult then say(world, adult, "repo_visit", { amount = col.remaining, oid = oid }) end
    end
    -- things resting on it go into household storage (never orphaned)
    for _, cid in ipairs(sortedIds(world.lot.objects)) do
        local c = world.lot.objects[cid]
        if c.parent == oid then
            local cdef = SS.Objects[c.def]
            if SS.Inventory and SS.Inventory.Add then
                SS.Inventory.Add(world, { kind = "object", def = c.def, name = cdef and cdef.name or c.def, value = E.ResaleValue(world, c),
                    data = { variant = c.variant, paid = c.paid } })
            end
            world.lot.objects[cid] = nil
        end
    end
    -- whoever is using it stops
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        local act = a and a.act
        if act and ((act.target and act.target.oid == oid) or act.oid == oid) and SS.Actions and SS.Actions.Finish then
            SS.Actions.Finish(world, a, "failed", "The bill collector took it.")
        end
    end
    world.lot.objects[oid] = nil
    world.lot.version = (world.lot.version or 1) + 1
    if SS.Undo and SS.Undo.Clear then SS.Undo.Clear() end -- no undo refund for a repossessed purchase
    -- credit: the part of the item's value that went toward the debt (an item worth more than what is
    -- still owed settles it; there is no change)
    local rec = { oid = oid, def = o.def, name = def and def.name or o.def, value = v, credit = math.min(v, col.remaining), t = world.time }
    col.taken[#col.taken + 1] = rec
    col.remaining = math.max(0, col.remaining - v)
    SS.Money(world, 0, "bills", string.format("Repossessed: %s (worth %s) toward %s of overdue bills", rec.name, fmt(v), fmt(col.debt)))
    if SS.World and SS.World.Rebuild then SS.World.Rebuild(world) end
    SS.Emit("lotChanged", "object", oid)
    SS.Emit("repossessed", world, col, rec)
    if col.remaining <= 0 or #col.taken >= D().collector.maxObjects then finishCollection(world, col, "collected") end
    return true
end

local function collectorOnLot(world, colId)
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and a.role == "collector" and a.roleData and a.roleData.col == colId then return a end
    end
end

local function scheduleCollect(world, col, at)
    SS.Sim.Unschedule(world, function(ev) return ev.kind == "econ.collect" and ev.data and ev.data.col == col.id end)
    col.at = at
    SS.Sim.Schedule(world, at, "econ.collect", { col = col.id }, world.lot.id)
end

local function nothingToTake(world, col)
    local c = D().collector
    if #col.taken > 0 or col.visits >= c.maxVisits then
        finishCollection(world, col, "partial")
        return
    end
    col.state = "waiting"
    scheduleCollect(world, col, world.time + c.retryDays * 1440)
    message(world, "The bill collector found nothing they could take and left a card. They will be back tomorrow.", "mail")
end

local function spawnCollector(world, col)
    if collectorOnLot(world, col.id) then return end
    if not (SS.Visitors and SS.Visitors.Spawn) then return end
    local a = SS.Visitors.Spawn(world, nil, "collector", { col = col.id, state = "arrive" })
    if not a then
        col.state = "waiting"
        scheduleCollect(world, col, world.time + D().collector.retryDays * 1440)
    elseif col.state ~= "arrived" then
        -- the stub Spawn calls onArrive; a framework that does not still gets a consistent record
        E.CollectorArrived(world, a)
    end
end

function E.CollectorArrived(world, a)
    local col = collectionOf(world, a.roleData and a.roleData.col)
    if not col then return end
    if col.state == "cancelled" or col.state == "done" then return end
    if col.state == "arrived" then return end
    col.state = "arrived"
    col.visits = (col.visits or 0) + 1
    a.roleData.state = a.roleData.state or "arrive"
    local text = string.format("A bill collector is here about %s of overdue bills. They will take belongings to cover it.", fmt(col.remaining))
    if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "warning") end
    message(world, text, "mail")
end

-- Scheduled "econ.collect": ask the visitors framework for the collector (once), else spawn directly.
local function handleCollect(world, ev)
    local col = collectionOf(world, ev.data and ev.data.col)
    if not col or col.state == "done" or col.state == "cancelled" or col.state == "arrived" then return end
    -- the debt may already be settled (bills paid since, or an old save): then nobody comes
    if not E.CollectionOpen(world, col) then return end
    local c = D().collector
    if col.state == "scheduled" and SS.Visitors and SS.Visitors.Request then
        local ok, id = pcall(SS.Visitors.Request, world, "collector", { col = col.id, state = "arrive" })
        if ok and id then
            col.state, col.requestId = "requested", id
            scheduleCollect(world, col, world.time + c.requestTimeout) -- fallback if it never arrives
            return
        end
    end
    spawnCollector(world, col)
end

-- Hourly: warnings, final notices, and a collection for bills two days past due.
local function checkOverdue(world)
    local hh = world.household
    local st = E.State(hh)
    local b = D().bills
    local adult = E.AnyAdult(world)
    local toCollect = {}
    for _, bill in ipairs(hh.bills) do
        if bill.state == "delivered" and bill.due then
            if world.time >= bill.due and (bill.warned or 0) < 1 then
                bill.warned = 1
                message(world, string.format("Overdue: %s (%s). Pay it soon or a final notice follows.", bill.text, fmt(bill.amount)), "mail")
                if adult then say(world, adult, "bill_overdue", { amount = bill.amount, stage = 1, days = 1 }) end
                SS.Emit("billOverdue", world, bill, 1)
            end
            if world.time >= bill.due + b.finalNoticeDays * 1440 and (bill.warned or 0) < 2 then
                bill.warned = 2
                local notice = E.Post(world, "notice", string.format("FINAL NOTICE: %s (%s) is overdue. Unpaid bills will be collected in person.", bill.text, fmt(bill.amount)))
                E.DeliverMail(world, nil, notice) -- (just the notice: other post waits for the carrier)
                if adult then say(world, adult, "bill_overdue", { amount = bill.amount, stage = 2, days = 1 + b.finalNoticeDays }) end
                SS.Emit("billOverdue", world, bill, 2)
                journal(world, "A final notice arrived for " .. bill.text .. ".")
            end
            if world.time >= bill.due + b.collectDays * 1440 and not bill.collectionId then toCollect[#toCollect + 1] = bill end
        end
    end
    if #toCollect > 0 then
        local col = { id = nextId(st, "col"), bills = {}, debt = 0, remaining = 0, paid = 0, state = "scheduled", visits = 0, taken = {}, created = world.time }
        for _, bill in ipairs(toCollect) do
            bill.collectionId = col.id
            col.bills[#col.bills + 1] = bill.id
            col.debt = col.debt + bill.amount
        end
        col.remaining = col.debt
        st.collections[#st.collections + 1] = col
        while #st.collections > 8 do
            local old = st.collections[1]
            if old.state == "done" or old.state == "cancelled" then table.remove(st.collections, 1) else break end
        end
        local ev = record(world, "bill_collection", { col = col.id, debt = col.debt })
        col.eventId = ev and ev.id
        scheduleCollect(world, col, world.time + D().collector.arriveDelay)
        SS.Emit("billOverdue", world, toCollect[1], 3)
    end
end
E.CheckOverdue = checkOverdue

-- Take `amount` from the household for something it cannot refuse (a fine, pay docked at work).
-- What the household has is taken now; any shortfall becomes arrears, withheld from the next wages
-- (E.Garnish), so money never goes below zero and nothing is lost or taken twice.
-- Returns paidNow, deferred.
function E.Debit(world, amount, cat, text)
    local hh = world and world.household
    amount = math.floor((tonumber(amount) or 0) + 0.5)
    if not hh or amount <= 0 then return 0, 0 end
    local now = math.max(0, math.min(amount, math.floor(world.money or 0)))
    local later = amount - now
    if later > 0 then
        local st = E.State(hh)
        st.arrears = st.arrears + later
        text = string.format("%s (%s now, %s withheld from the next wages)", text, fmt(now), fmt(later))
    end
    -- (one ledger line either way; a zero line records a charge that is all deferred)
    SS.Money(world, -now, cat, text)
    return now, later
end

-- Arrears left after a collection are withheld from wages (a share of each paycheck). Returns amount.
function E.Garnish(world, pay)
    local hh = world.household
    local st = hh and E.State(hh)
    if not st or st.arrears <= 0 or pay <= 0 then return 0 end
    local w = math.min(st.arrears, math.floor(pay * D().bills.garnish))
    if w <= 0 then return 0 end
    st.arrears = st.arrears - w
    SS.Money(world, -w, "bills", "Arrears withheld from wages")
    return w
end

---------------------------------------------------------------------------------------------------
-- The collector role (registered on the visitors framework once it is loaded)
---------------------------------------------------------------------------------------------------
local function approachCells(world, o)
    local def = SS.Objects[o.def]
    local G = SS.Grid
    local lv = o.level or 0
    local out, seen = {}, {}
    local function add(i, j)
        local k = i .. ":" .. j
        if not seen[k] and SS.World.InLot(world.lot, i, j) and not SS.World.Blocked(world, lv, i, j) then
            seen[k] = true
            out[#out + 1] = { i, j, lv }
        end
    end
    for _, name in ipairs(sortedIds(def.slots or {})) do
        local sl = def.slots[name]
        for _, ap in ipairs(sl.approaches or {}) do
            local dx, dy = G.rot(ap[1], ap[2], o.f or 0)
            add(o.x + dx, o.y + dy)
        end
    end
    for _, c in ipairs(G.footprint(def, o)) do
        for k = 0, 3 do local d = G.DIRS[k]; add(c[1] + d[1], c[2] + d[2]) end
    end
    return out
end

local function nearObject(a, o)
    local def = SS.Objects[o.def]
    if (a.level or 0) ~= (o.level or 0) then return false end
    local ai, aj = math.floor(a.x), math.floor(a.y)
    for _, c in ipairs(SS.Grid.footprint(def, o)) do
        if math.abs(c[1] - ai) + math.abs(c[2] - aj) <= 1 then return true end
    end
    return false
end

local function walkTo(world, a, o, attempt)
    local cells = approachCells(world, o)
    if #cells == 0 then return false end
    table.sort(cells, function(p, q)
        local dp = math.abs(p[1] + 0.5 - a.x) + math.abs(p[2] + 0.5 - a.y)
        local dq = math.abs(q[1] + 0.5 - a.x) + math.abs(q[2] + 0.5 - a.y)
        if dp ~= dq then return dp < dq end
        return p[1] * 100 + p[2] < q[1] * 100 + q[2]
    end)
    local c = cells[((attempt or 0) % #cells) + 1]
    a.queue = {}
    SS.Actions.Order(world, a, nil, "goto", c[1], c[2], { level = c[3] })
    return true
end

local function leave(world, a, why)
    if SS.Visitors and SS.Visitors.Leave then SS.Visitors.Leave(world, a, why or "done")
    else SS.Sim.RemoveActor(world, a.id, { reason = why or "done" }) end
end

function E.CollectorTick(world, a, dt)
    local rd = a.roleData or {}
    a.roleData = rd
    local col = collectionOf(world, rd.col)
    if not col or col.state == "cancelled" then
        if col and not rd.saidPaid then
            rd.saidPaid = true
            message(world, "The bill collector sees the bills are paid and leaves.", "mail")
        end
        return leave(world, a, "paid")
    end
    if col.state ~= "arrived" and col.state ~= "done" then E.CollectorArrived(world, a) end
    if col.state == "done" then return leave(world, a, "done") end
    local c = D().collector
    rd.state = rd.state or "arrive"
    if rd.state == "arrive" then
        local oid = E.PickRepossession(world, col.remaining, rd.skip)
        if not oid then nothingToTake(world, col); return leave(world, a, "nothing") end
        rd.target, rd.tries, rd.state = oid, 0, "walk"
        if not walkTo(world, a, world.lot.objects[oid], 0) then
            rd.skip = rd.skip or {}
            rd.skip[oid] = true
            rd.state = "arrive"
        end
        return
    end
    if rd.state == "walk" then
        local o = world.lot.objects[rd.target]
        if not o or not eligible(world, o) then rd.state = "arrive"; return end
        if a.act or (a.queue and #a.queue > 0) then return end
        if nearObject(a, o) then
            rd.state, rd.t0 = "take", world.time
            a.facing = SS.Grid.dirToFacing(o.x + 0.5 - a.x, o.y + 0.5 - a.y)
            local def = SS.Objects[o.def]
            message(world, string.format("The bill collector is taking the %s.", def and def.name or "furniture"), "mail")
            return
        end
        rd.tries = (rd.tries or 0) + 1
        if rd.tries > c.walkAttempts then
            rd.skip = rd.skip or {}
            rd.skip[rd.target] = true
            rd.state = "arrive"
            return
        end
        walkTo(world, a, o, rd.tries)
        return
    end
    if rd.state == "take" then
        a.pose = "use"
        local o = world.lot.objects[rd.target]
        if not o then rd.state = "arrive"; return end
        if world.time - (rd.t0 or world.time) >= c.takeMinutes then
            E.Repossess(world, col, rd.target)
            rd.target = nil
            rd.state = col.state == "done" and "leave" or "arrive"
        end
        return
    end
    leave(world, a, "done")
end

-- Role definition for SS.Visitors.RegisterRole. The fields beyond the stub's (arrive, class, pool,
-- vehicle, timeout, reconcile) are the visitors framework's: the collector drives up, walks straight
-- to work (task state, our tick) and after a load resumes where he was. If he is ever removed before
-- finishing (timeout, a forced leave), the hourly check re-sends a visit for what is still owed;
-- col.taken is saved, so nothing is taken twice.
E.COLLECTOR_ROLE = {
    label = "Bill Collector", desc = "Comes for overdue bills and takes something that covers the debt.",
    noNeeds = true, useAutonomy = false, access = "service", class = "service", arrive = "direct",
    pool = "collector", outfit = "collector", vehicle = "car", timeout = 120, important = true,
    reconcile = function(world, a) return "resume" end,
    onArrive = function(world, a) E.CollectorArrived(world, a) end,
    tick = function(world, a, dt) E.CollectorTick(world, a, dt) end,
}

---------------------------------------------------------------------------------------------------
-- Sandbox money (clearly labelled, never confused with normal progression)
---------------------------------------------------------------------------------------------------
function E.SandboxOn(world) return (world and world.settings and world.settings.sandboxMoney) and true or false end

-- Has this household ever used sandbox money? (Shown on the ledger screen.)
function E.SandboxUsed(world, hh)
    hh = hh or world.household
    if hh and hh.flags and hh.flags.sandbox then return true end
    local root = world and (world.root or world)
    -- the shell's /sidestreet money command marks the save instead of the household
    if root and type(root.shell) == "table" and root.shell.sandboxUsed and hh == (world and world.household) then return true end
    if hh and E.State(hh) then
        for _, row in pairs(hh.econ.daily) do if type(row) == "table" and row.debug and row.debug ~= 0 then return true end end
    end
    return false
end

function E.SetSandbox(world, on)
    world.settings = world.settings or {}
    world.settings.sandboxMoney = on and true or false
    if on and world.household then
        world.household.flags = world.household.flags or {}
        if not world.household.flags.sandbox then
            world.household.flags.sandbox = true
            journal(world, "Sandbox money was switched on. From here on this household's fortune is not a normal game.")
        end
    end
    return world.settings.sandboxMoney
end

-- /sidestreet money <n> (via Boot) and the ledger screen's sandbox buttons. Sandbox only.
function E.SandboxSetMoney(world, n)
    if not world or not world.household then return false, "No household is loaded." end
    n = tonumber(n)
    if not n then return false, "Usage: /sidestreet money <amount>" end
    if not E.SandboxOn(world) then
        return false, "Sandbox money is off. Turn it on in the Money tab first; it marks this household as sandbox."
    end
    n = math.floor(clamp(n, 0, 9999999))
    local delta = n - (world.money or 0)
    world.household.flags = world.household.flags or {}
    world.household.flags.sandbox = true
    if delta ~= 0 then SS.Money(world, delta, "debug", "Sandbox: funds set to " .. fmt(n)) end
    return true, "Sandbox: household funds set to " .. fmt(n) .. " (marked as sandbox money in the ledger)."
end

-- Add (or remove) sandbox funds: the shell's "/sidestreet money N" can call this. Sandbox only.
function E.SandboxAdd(world, n)
    if not world or not world.household then return false, "No household is loaded." end
    n = tonumber(n)
    if not n or n == 0 then return false, "Usage: /sidestreet money <amount>" end
    if not E.SandboxOn(world) then
        return false, "Sandbox money is off. Turn it on in the Money tab first; it marks this household as sandbox."
    end
    n = math.floor(clamp(n, -(world.money or 0), 9999999))
    world.household.flags = world.household.flags or {}
    world.household.flags.sandbox = true
    SS.Money(world, n, "debug", string.format("Sandbox: %s %s", n >= 0 and "added" or "removed", fmt(math.abs(n))))
    return true, string.format("Sandbox: %s %s (marked as sandbox money in the ledger).", n >= 0 and "added" or "removed", fmt(math.abs(n)))
end

---------------------------------------------------------------------------------------------------
-- Interactions (mailbox and computer)
---------------------------------------------------------------------------------------------------
local function isAdult(actor) return actor.age == "adult" and (actor.kind == nil or actor.kind == "human") and not actor.role end
local function isMember(world, actor) return world.household and actor.householdId == world.household.id and not actor.role end

local function payTest(world, actor)
    if not isMember(world, actor) then return false, "Only the household pays its bills." end
    if not isAdult(actor) then return false, "Bills need an adult." end
    local list = E.PayableBills(world)
    if #list == 0 then return false, "There are no bills to pay." end
    local cheapest
    for _, b in ipairs(list) do local v = owed(world, b); if not cheapest or v < cheapest then cheapest = v end end
    if (world.money or 0) < cheapest then return false, "Not enough money: the smallest bill is " .. fmt(cheapest) .. "." end
    return true
end

SS.Interactions = SS.Interactions or {}
SS.Interactions.econ_getmail = {
    label = "Get Mail", category = "Household", slot = "front", pose = "use", dur = 3,
    requireState = { mail = true }, advert = { fun = 4 }, ages = { adult = true, child = true }, kinds = { human = true },
    test = function(world, actor) if not isMember(world, actor) then return false, "That is not their post." end return true end,
    onStart = function(world, actor, act) E.GetMail(world, actor) end,
}
SS.Interactions.econ_paybills = {
    label = "Pay Bills", category = "Household", slot = "front", pose = "use", dur = 6, manualOnly = true,
    ages = { adult = true }, kinds = { human = true }, test = payTest,
    onStart = function(world, actor, act) E.PayBills(world, actor, act.data and act.data.bill) end,
}
SS.Interactions.econ_paybills_pc = {
    label = "Pay Bills Online", category = "Household", slot = "front", pose = "type", dur = 10, manualOnly = true,
    ages = { adult = true }, kinds = { human = true },
    test = function(world, actor, obj)
        if obj and obj.state and obj.state.broken then return false, "The computer is broken." end
        return payTest(world, actor)
    end,
    onStart = function(world, actor, act) E.PayBills(world, actor, act.data and act.data.bill) end,
}
SS.Tags.Attach("mailbox", "econ_getmail")
SS.Tags.Attach("mailbox", "econ_paybills")
SS.Tags.Attach("computer", "econ_paybills_pc")

-- Autonomy: a resident fetches mail that has sat in the box for an hour (neat people sooner).
local function mailCandidates(world, actor, cands)
    if not E.IsHome(world) or not isMember(world, actor) or actor.age == "infant" then return end
    local mb = E.Mailbox(world)
    if not (mb and mb.state and mb.state.mail) then return end
    local bills, notes = E.UnreadMail(world)
    local oldest
    for _, b in ipairs(bills) do if not oldest or b.deliveredAt < oldest then oldest = b.deliveredAt end end
    for _, m in ipairs(notes) do if not oldest or m.deliveredAt < oldest then oldest = m.deliveredAt end end
    if not oldest then return end
    local neat = actor.personality and actor.personality.neat or 5
    if world.time - oldest < 90 - neat * 6 then return end
    for _, need in ipairs({ "hunger", "energy", "bladder" }) do
        if (actor.needs[need] or 0) < -30 then return end
    end
    local cool = actor.cool and actor.cool[mb.id .. ":econ_getmail"]
    if cool and cool > world.time then return end
    if SS.Actions.Available(world, actor, mb, "econ_getmail") then
        cands[#cands + 1] = { oid = mb.id, iid = "econ_getmail", s = 13 + neat * 0.8 }
    end
end
if SS.Actions and SS.Actions.RegisterCandidates then SS.Actions.RegisterCandidates(mailCandidates) end

---------------------------------------------------------------------------------------------------
-- Paused-household gap: inactive households are paused (§5.4). If the world clock moved on while
-- this household was not being played, due dates and collection visits move by the same gap.
---------------------------------------------------------------------------------------------------
function E.Gap(world) return rawget(world, "_ssGap") or 0 end

local function applyGap(world, gap)
    local hh = world.household
    local st = E.State(hh)
    for _, b in ipairs(hh.bills) do
        if b.state == "delivered" and b.due then b.due = b.due + gap; b.deliveredAt = (b.deliveredAt or 0) + gap end
    end
    if st.nextCycleAt then st.nextCycleAt = st.nextCycleAt + gap end
    for _, col in ipairs(st.collections) do if col.at then col.at = col.at + gap end end
    local changed = false
    for _, ev in ipairs(world.scheduled) do
        if ev.lotId == world.lot.id and type(ev.kind) == "string" and ev.kind:sub(1, 5) == "econ." then ev.at = ev.at + gap; changed = true end
    end
    if changed then table.sort(world.scheduled, function(a, b) return a.at < b.at end) end
end

---------------------------------------------------------------------------------------------------
-- System: cycle, delivery, overdue checks, collector reconciliation
---------------------------------------------------------------------------------------------------
local registered = false
function E.RegisterLate()
    if registered then return end
    if SS.Visitors and SS.Visitors.RegisterRole then
        SS.Visitors.RegisterRole("collector", E.COLLECTOR_ROLE)
        registered = true
    else
        SS.Roles.collector = E.COLLECTOR_ROLE
    end
    SS.Tags.Attach("mailbox", "econ_getmail")
    SS.Tags.Attach("mailbox", "econ_paybills")
    SS.Tags.Attach("computer", "econ_paybills_pc")
end

local function raiseCycle(world)
    local amount, items = E.CycleBill(world)
    local day = math.floor(world.time / 1440) + 1
    return E.Bill(world, amount, "household", "Household bill (day " .. day .. ")", { items = items })
end
E.RaiseCycleBill = raiseCycle

local function attach(world)
    E.RegisterLate()
    E.rt.vehicles, E.rt.leaving, E.rt.vanUntil, E.rt.mailbox = {}, {}, nil, nil
    rawset(world, "_ssGap", 0)
    if not E.IsHome(world) then return end
    local hh = world.household
    local st = E.State(hh)
    if st.seen and world.time > st.seen + 1 then
        local gap = world.time - st.seen
        rawset(world, "_ssGap", gap)
        applyGap(world, gap)
    end
    st.seen = world.time
    if not st.nextCycleAt then
        st.nextCycleAt = (math.floor(world.time / 1440) + D().bills.everyDays) * 1440
    end
    -- reconcile collections after a load: an "arrived" collection without its collector gets a new visit
    for _, col in ipairs(st.collections) do
        if col.state == "arrived" and not collectorOnLot(world, col.id) then
            col.state = "scheduled"
            scheduleCollect(world, col, world.time + D().collector.arriveDelay)
        elseif (col.state == "scheduled" or col.state == "requested" or col.state == "waiting") then
            local has = false
            for _, ev in ipairs(world.scheduled) do
                if ev.kind == "econ.collect" and ev.data and ev.data.col == col.id then has = true end
            end
            if not has then scheduleCollect(world, col, world.time + D().collector.arriveDelay) end
        end
    end
    -- a collector left on the lot for a finished or unknown collection goes home on its next tick
    local mb = E.Mailbox(world)
    if mb then
        local bills, notes = E.UnreadMail(world)
        mb.state = mb.state or {}
        mb.state.mail = (#bills + #notes > 0) or nil
    end
end

local function tick(world, dt)
    tickVehicles(world)
    -- the mail van drives off a few minutes after delivering
    if E.rt.vanUntil and (world.time >= E.rt.vanUntil or world.time < E.rt.vanUntil - 10) then
        E.rt.vanUntil = nil
        E.RemoveVehicle(world, "mail")
    end
    if not E.IsHome(world) then return end
    local st = world.household.econ
    if st then st.seen = world.time end
end

local function hour(world, h)
    if not E.IsHome(world) then return end
    local st = E.State(world.household)
    local hod = h % 24
    local b = D().bills
    if st.nextCycleAt and world.time >= st.nextCycleAt - 1e-6 then
        st.nextCycleAt = st.nextCycleAt + b.everyDays * 1440
        raiseCycle(world)
    end
    if hod == b.deliverHour then
        -- The visitors module schedules its own mail carrier (van + walk to the mailbox, 10:00-11:00
        -- on its mail days), who delivers through DeliverMail. Without it the post comes with our own
        -- mail van now. Either way the noon fallback below catches anything a carrier could not bring.
        local V = SS.Visitors
        if not (V and V.SpawnMail) then
            local carrier = V and V.MailCarrier and V.MailCarrier(world)
            if not carrier then
                local n = E.DeliverMail(world)
                if n > 0 then
                    E.AddVehicle(world, "mail", "mail_van")
                    E.rt.vanUntil = world.time + 3
                end
            end
        end
    elseif hod == b.carrierDeadlineHour and E.IsMailDay(world) then
        E.DeliverMail(world) -- anything a carrier failed to bring arrives with the midday van
    end
    -- a collector who left the lot before finishing (timeout, forced leave) comes back another time
    for _, col in ipairs(st.collections) do
        if col.state == "arrived" and not collectorOnLot(world, col.id) then
            col.state = "scheduled"
            scheduleCollect(world, col, world.time + D().collector.retryDays * 1440)
        end
    end
    checkOverdue(world)
end

local function day(world, d)
    if not E.IsHome(world) then return end
    pruneDaily(E.State(world.household), d)
end

SS.Sim.Register({ name = "economy", order = 40, attach = attach, tick = tick, hour = hour, day = day })

SS.On("scheduled", function(ev, world)
    if ev.kind == "econ.collect" and world and E.IsHome(world) then handleCollect(world, ev) end
end)


---------------------------------------------------------------------------------------------------
-- Save validation
---------------------------------------------------------------------------------------------------
if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        for hid, hh in pairs(root.households or {}) do
            -- a household that never had bills (hood's other households) is left as saved: E.State creates the
            -- lists when the household is played, so a valid save loads unchanged
            if type(hh) == "table" and hh.bills ~= nil and type(hh.bills) ~= "table" then
                hh.bills = nil
                problems[#problems + 1] = "reset damaged bills for " .. tostring(hid)
            end
            if type(hh) == "table" and hh.bills ~= nil then
                local keep = {}
                for _, b in ipairs(hh.bills) do
                    if type(b) == "table" and type(b.amount) == "number" and b.amount >= 0 and type(b.id) == "string" then
                        b.state = b.state or "posted"
                        b.created = tonumber(b.created) or root.time or 0
                        if b.state == "delivered" and type(b.due) ~= "number" then b.due = (root.time or 0) + D().bills.dueDays * 1440 end
                        keep[#keep + 1] = b
                    else
                        problems[#problems + 1] = "dropped a damaged bill from " .. tostring(hid)
                    end
                end
                hh.bills = keep
            end
            if type(hh) == "table" then
                if hh.econ ~= nil and type(hh.econ) ~= "table" then hh.econ = nil; problems[#problems + 1] = "reset economy for " .. tostring(hid) end
                if hh.econ then
                    local st = E.State(hh)
                    if type(st.arrears) ~= "number" or st.arrears < 0 then st.arrears = 0 end
                    local cols = {}
                    for _, c in ipairs(st.collections) do
                        if type(c) == "table" and type(c.id) == "string" and type(c.bills) == "table" then
                            c.taken = type(c.taken) == "table" and c.taken or {}
                            c.debt = tonumber(c.debt) or 0
                            c.remaining = tonumber(c.remaining) or c.debt
                            c.visits = tonumber(c.visits) or 0
                            -- saves from before partial payments lowered the debt: bills of an open
                            -- collection that were paid since still count against it (once: c.paid is set)
                            if c.paid == nil and c.state ~= "done" and c.state ~= "cancelled" and type(hh.bills) == "table" then
                                local paid = 0
                                for _, id in ipairs(c.bills) do
                                    for _, b in ipairs(hh.bills) do
                                        if b.id == id and b.state == "paid" then paid = paid + b.amount end
                                    end
                                end
                                if paid > 0 then
                                    c.remaining = math.max(0, c.remaining - paid)
                                    problems[#problems + 1] = "lowered collection " .. c.id .. " by bills paid toward it"
                                end
                                c.paid = paid
                            end
                            cols[#cols + 1] = c
                        end
                    end
                    st.collections = cols
                end
            end
        end
    end)
end
