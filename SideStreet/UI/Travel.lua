-- SideStreet going-out screens. Owner: outings module (docs/modules/outings.md).
--   * "Outing" mode (F6, fullscreen, pauses the house while choosing):
--       at home   - the destination chooser: a venue (hours, open on arrival, activities, repairs),
--                   which residents go (a subset, each with a reason when they can't), one guest or a
--                   date who meets the party there, then "Call a Taxi" (or cancel a taxi on its way);
--       at a venue - the outing screen: score, date, log and money spent; the cafe menu (prices and
--                   quality, choose a dish, ask for a table, pay and leave); the shops' stock per
--                   vendor (buy, cancel); "Go Home".
--   * a live-mode "Outing" tab (the selected resident's outing at a glance),
--   * context-menu entries (buy from a display, change outfit at a booth, give a gift, go out/home),
--   * SS.UI.OpenTravel(ref): opens the mode; ref may be a venue lot id (hood's "Visit") or the
--     resident placing the call (the phone's "Call a Taxi").
-- Nothing here touches WoW frames at load time; frames are built the first time the mode opens.
local _, SS = ...
local UI = SS.UI
local V, Tr, VD, U = SS.Venues, SS.Travel, SS.VenueData, SS.U
local T = VD.tuning
local K = UI.Kit
local TU = { sel = { going = {}, vendor = "clothing" }, rows = {}, btn = {}, text = {} }
UI.Travel = TU

local function world() return SS.Sim.world end
local function rootOf(w) return w and (w.root or w) end
local function money(v) return U.fmtMoney(v or 0) end
local function col(name) return K.COL[name] or K.COL.ink end
local function the(name)
    if not name or name == "" then return "it" end
    if name:match("^The ") or name:match("^the ") then return name end
    return "the " .. name
end

TU.HELP = {
    "Outing (F6): pick a venue and who goes. A taxi collects them from the curb; one friend or a date can meet you there.",
    "At a venue the same screen shows the outing: its score, the date, what was spent, the cafe menu and the shop shelves, and Go Home.",
}
for _, line in ipairs(Tr.POLICY) do TU.HELP[#TU.HELP + 1] = line end

---------------------------------------------------------------------------------------------------
-- Selection model (plain data; the tests and the buttons use the same functions)
function TU.OnOuting(w) w = w or world(); return w and V.Active(w) ~= nil end

-- Venues for the chooser, with a one-line status each.
function TU.Destinations(w)
    local out = {}
    for _, d in ipairs(Tr.Destinations(w)) do
        local status
        if not d.valid then status = "Closed for repairs"
        elseif not d.openAtArrival then status = "Closed when you'd arrive (" .. d.hours .. ")"
        else status = d.hours end
        d.status = status
        out[#out + 1] = d
    end
    return out
end

-- Default picks: the first venue that is valid and open on arrival; the selected resident (or the
-- first who can go).
function TU.ResetChoice(w, ref)
    w = w or world()
    local sel = TU.sel
    sel.going, sel.guest, sel.date, sel.msg = {}, nil, false, nil
    local root = rootOf(w)
    local dests = TU.Destinations(w)
    if ref and root.hood.lots[ref] and V.Kind(root.hood.lots[ref]) then sel.venue = ref
    elseif not (sel.venue and root.hood.lots[sel.venue]) then
        sel.venue = nil
        for _, d in ipairs(dests) do if not sel.venue and d.valid and d.openAtArrival then sel.venue = d.id end end
        sel.venue = sel.venue or (dests[1] and dests[1].id)
    end
    local host = (ref and root.residents[ref] and ref) or UI.selected
    local cands = Tr.Candidates(w)
    for _, c in ipairs(cands) do if c.ok and c.rid == host then sel.going[c.rid] = true end end
    if not next(sel.going) then
        for _, c in ipairs(cands) do if c.ok and not next(sel.going) and c.age ~= "child" then sel.going[c.rid] = true end end
    end
    sel.host = host
end

function TU.GoingList(w)
    local out = {}
    for _, c in ipairs(Tr.Candidates(w or world())) do if TU.sel.going[c.rid] then out[#out + 1] = c.rid end end
    return out
end

function TU.ChooseVenue(id) TU.sel.venue = id; TU.sel.msg = nil; TU.Refresh() end

function TU.Toggle(rid)
    local w = world()
    for _, c in ipairs(Tr.Candidates(w)) do
        if c.rid == rid then
            if not c.ok then TU.sel.msg = c.why; TU.Refresh(); return false, c.why end
            TU.sel.going[rid] = not TU.sel.going[rid] or nil
        end
    end
    TU.sel.msg = nil
    TU.Refresh()
    return true
end

-- Cycle the guest through the warmest candidates who can come (then back to nobody).
function TU.NextGuest()
    local w = world()
    local list = {}
    local host = TU.GoingList(w)[1]
    for _, g in ipairs(Tr.GuestCandidates(w, host, 8)) do
        local kind = TU.sel.venue and V.Kind(rootOf(w).hood.lots[TU.sel.venue])
        local here = w.actors[g.rid] ~= nil
        local ok = V.CanVisit(w, rootOf(w).residents[g.rid], kind, here and { rideAlong = true } or nil)
        if ok then list[#list + 1] = g.rid end
    end
    local cur, nxt = TU.sel.guest, nil
    if not cur then nxt = list[1]
    else
        for n, rid in ipairs(list) do if rid == cur then nxt = list[n + 1] end end
    end
    TU.sel.guest = nxt
    if not nxt then TU.sel.date = false end
    TU.Refresh()
    return nxt
end

function TU.ToggleDate()
    if not TU.sel.guest then TU.sel.msg = "Invite someone first; a date meets you there."; TU.Refresh(); return false end
    TU.sel.date = not TU.sel.date
    TU.Refresh()
    return TU.sel.date
end

function TU.Options()
    local opts = {}
    if TU.sel.guest then opts.guests = { TU.sel.guest }; opts.date = TU.sel.date or nil end
    return opts
end

function TU.Check(w)
    w = w or world()
    if not TU.sel.venue then return false, "Pick a venue to visit." end
    return Tr.CanGo(w, TU.GoingList(w), TU.sel.venue, TU.Options())
end

-- "Call a Taxi": back to the house while it comes.
function TU.Go()
    local w = world()
    local ok, why = Tr.Go(w, TU.GoingList(w), TU.sel.venue, TU.Options())
    TU.sel.msg = why
    if ok and UI.SetMode then UI.SetMode("live") else TU.Refresh() end
    return ok, why
end

function TU.CancelTaxi()
    local ok, why = Tr.Cancel(world())
    TU.sel.msg = ok and "Taxi cancelled." or why
    TU.Refresh()
    return ok, why
end

function TU.GoHome()
    local ok, why = Tr.GoHome(world(), {})
    TU.sel.msg = ok and "Taxi home called." or why
    if ok and UI.SetMode and UI.mode == "travel" then UI.SetMode("live") else TU.Refresh() end
    return ok, why
end

-- The resident the outing screen acts for (the selected one if they are on this outing).
function TU.Actor(w)
    w = w or world()
    local o = V.Active(w)
    local a = UI.selected and w.actors[UI.selected]
    if a and o and V.InParty(o, a.id) and V.IsMember(w, a) then return a end
    for _, rid in ipairs(o and o.participants or {}) do if w.actors[rid] then return w.actors[rid] end end
    return a
end

---------------------------------------------------------------------------------------------------
-- Text for the screens and the tab (pure; tested offline)
local function verdictWord(score)
    return score >= 65 and "going well" or score < 35 and "going badly" or "so-so"
end

function TU.OutingLines(w)
    w = w or world()
    local o = V.Active(w)
    if not o then return {} end
    local lines = {}
    local kind = V.Kind(w.lot)
    local left = V.MinutesToClose(kind, w.time)
    lines[#lines + 1] = string.format("%s  -  %s", w.lot.name or "Venue", left and string.format("closes in %d min", math.floor(left)) or V.HoursText(kind))
    lines[#lines + 1] = string.format("Outing: %d/100 (%s)", math.floor(o.score or 50), verdictWord(o.score or 50))
    local d = o.date
    if d then
        local who = rootOf(w).residents[d.with]
        local st = ({ waiting = "on the way", on = "together", stood_up = "never came", ended_early = "ended early", good = "went well", fine = "went fine", bad = "went badly" })[d.state or ""] or tostring(d.state)
        lines[#lines + 1] = string.format("Date with %s: %d/100 (%s)", who and who.name or "?", math.floor(d.score or 50), st)
    end
    local hh = w.household
    local spent = (o.home and o.home.money or 0) - (hh and hh.money or 0)
    lines[#lines + 1] = "Spent so far: " .. money(math.max(0, spent))
    return lines
end

function TU.LogLines(w, n)
    local o = V.Active(w or world())
    local out = {}
    local log = o and o.log or {}
    for k = math.max(1, #log - (n or 8) + 1), #log do out[#out + 1] = SS.Sim.ClockText(log[k].t):gsub("^Day %d+%s+", "") .. "  " .. log[k].text end
    return out
end

-- The selected resident's cafe or shop status (nil when neither).
function TU.StatusLine(w, a)
    w = w or world()
    if not a then return nil end
    if SS.Dining and SS.Dining.IsCafe(w) then
        local p = SS.Dining.PartyOf(w, a.id)
        if not p then return a.name .. " hasn't asked for a table." end
        local s = SS.Dining.StateText(p) .. "; " .. SS.Dining.OrderText(p.orders[a.id])
        return s .. string.format("; bill so far %s", money(SS.Dining.RunningTotal(w, p)))
    end
    if SS.Shopping and SS.Shopping.IsShops(w) then
        local ord = SS.Shopping.ActiveOrder(w, a.id)
        return ord and SS.Shopping.OrderText(ord) or (a.name .. " is just looking.")
    end
    return nil
end

function TU.VenueDetail(d)
    if not d then return "" end
    local lines = { d.label .. " at " .. d.address, d.desc or "" }
    lines[#lines + 1] = "Hours: " .. d.hours .. (d.openAtArrival and "" or "  (closed when you'd arrive)")
    if not d.valid then lines[#lines + 1] = "Closed for repairs: " .. table.concat(d.problems or {}, " ") end
    lines[#lines + 1] = "Things to do: " .. table.concat(d.activities or {}, ", ") .. "."
    if (d.visits or 0) > 0 then lines[#lines + 1] = string.format("Visited %d time%s.", d.visits, d.visits == 1 and "" or "s") end
    return table.concat(lines, "\n")
end

function TU.TripLine(w)
    local trip = Tr.Pending(w)
    if trip then
        local lot = rootOf(w).hood.lots[trip.dest]
        if trip.state == "waiting" then
            return string.format("A taxi to %s arrives in %d min.", lot and lot.name or "home", math.max(0, math.floor(trip.taxiAt - w.time)))
        end
        return "The taxi is at the curb; everyone is heading out to it."
    end
    local arrive = (w.time or 0) + T.taxiWait + T.ride
    return string.format("Taxi in %d min, a %d min ride: there at %s. Home stays frozen until you return.", T.taxiWait, T.ride,
        SS.Sim.ClockText(arrive):gsub("^Day %d+%s+", ""))
end

---------------------------------------------------------------------------------------------------
-- Frames
local ROW_H = 22

local function makeButton(parent, label, w, h, fn, tip)
    local b = K.Button(parent, label, w, h or ROW_H, fn, tip)
    b.label:ClearAllPoints(); b.label:SetPoint("LEFT", 8, 0); b.label:SetJustifyH("LEFT")
    b.label:SetWidth(w - 16)
    return b
end

local function heading(parent, text, x, y)
    local t = K.Text(parent, 13, col("ink"))
    t:SetPoint("TOPLEFT", x, y)
    t:SetText(text)
    return t
end

local function block(parent, x, y, w, h, size)
    local t = K.Text(parent, size or 11, col("ink"))
    t:SetPoint("TOPLEFT", x, y); t:SetWidth(w); if h then t:SetHeight(h) end
    t:SetJustifyV("TOP")
    return t
end

local function buildHome(f)
    local p = CreateFrame("Frame", nil, f)
    p:SetAllPoints(f)
    TU.homePage = p
    heading(p, "Where to?", 16, -56)
    TU.rows.venues = {}
    for n = 1, 6 do
        local b = makeButton(p, "", 300, 34, function(self) if self.ref then TU.ChooseVenue(self.ref) end end)
        b:SetPoint("TOPLEFT", 16, -76 - (n - 1) * 38)
        b.sub = K.Text(b, 10, K.COL.white); b.sub:SetPoint("BOTTOMLEFT", 8, 3); b.sub:SetWidth(284)
        b.label:ClearAllPoints(); b.label:SetPoint("TOPLEFT", 8, -3)
        TU.rows.venues[n] = b
    end
    TU.text.venue = block(p, 16, -76 - 6 * 38 - 6, 300, 170, 11)

    heading(p, "Who's going?", 336, -56)
    TU.rows.people = {}
    for n = 1, T.maxParty do
        local b = makeButton(p, "", 260, ROW_H, function(self) if self.ref then TU.Toggle(self.ref) end end,
            function(self) return self.why or "Click to add or remove." end)
        b:SetPoint("TOPLEFT", 336, -76 - (n - 1) * (ROW_H + 3))
        TU.rows.people[n] = b
    end
    local gy = -76 - T.maxParty * (ROW_H + 3) - 14
    heading(p, "Meet someone there", 336, gy)
    TU.btn.guest = makeButton(p, "Guest: nobody", 260, ROW_H, function() TU.NextGuest() end,
        "Invite one friend (warmest first). They make their own way and may say no, or not turn up.")
    TU.btn.guest:SetPoint("TOPLEFT", 336, gy - 20)
    TU.btn.date = makeButton(p, "It's a date: no", 260, ROW_H, function() TU.ToggleDate() end,
        "A date has its own score: time together, activities, conversation, comfort and waiting all count.")
    TU.btn.date:SetPoint("TOPLEFT", 336, gy - 20 - ROW_H - 3)

    heading(p, "The trip", 616, -56)
    TU.text.trip = block(p, 616, -76, 280, 48, 11)
    TU.text.check = block(p, 616, -128, 280, 44, 11)
    TU.btn.go = K.Button(p, "Call a Taxi", 136, 26, function() TU.Go() end, "Call the taxi now; the chosen residents walk out to it.")
    TU.btn.go:SetPoint("TOPLEFT", 616, -178)
    TU.btn.cancel = K.Button(p, "Cancel the Taxi", 136, 26, function() TU.CancelTaxi() end, "Send the taxi away; anyone in it steps back out.")
    TU.btn.cancel:SetPoint("TOPLEFT", 760, -178)
    TU.text.policy = block(p, 616, -216, 280, 200, 10)
    TU.text.policy:SetText(table.concat(Tr.POLICY, "\n\n"))
end

local function buildVenue(f)
    local p = CreateFrame("Frame", nil, f)
    p:SetAllPoints(f)
    TU.venuePage = p
    heading(p, "This outing", 16, -56)
    TU.text.summary = block(p, 16, -76, 300, 80, 12)
    TU.rows.who = {}
    for n = 1, T.maxParty do
        local b = makeButton(p, "", 146, 20, function(self) if self.ref then UI.selected = self.ref; if UI.Select then pcall(UI.Select, self.ref) end; TU.Refresh() end end,
            "Act for this resident")
        b:SetPoint("TOPLEFT", 16 + ((n - 1) % 2) * 152, -160 - math.floor((n - 1) / 2) * 23)
        TU.rows.who[n] = b
    end
    heading(p, "What happened", 16, -260)
    TU.text.log = block(p, 16, -280, 300, 170, 10)
    TU.btn.home = K.Button(p, "Go Home", 110, 26, function() TU.GoHome() end, "Call the taxi home for everyone on the outing.")
    TU.btn.home:SetPoint("TOPLEFT", 16, -460)
    TU.btn.back = K.Button(p, "Back", 80, 26, function() if UI.SetMode then UI.SetMode("live") end end, "Back to the venue")
    TU.btn.back:SetPoint("TOPLEFT", 132, -460)

    -- right side: the cafe menu or the shop shelves (or the venue's activities)
    TU.text.place = heading(p, "", 336, -56)
    TU.text.status = block(p, 336, -76, 560, 32, 11)
    TU.btn.vendors = {}
    for n, vendor in ipairs(VD.VENDOR_ORDER) do
        local v = VD.vendors[vendor]
        local b = K.Button(p, v.label, 136, 20, function() TU.sel.vendor = vendor; TU.Refresh() end, v.name)
        b:SetPoint("TOPLEFT", 336 + (n - 1) * 140, -110)
        TU.btn.vendors[vendor] = b
    end
    TU.rows.items = {}
    for n = 1, 13 do
        local r = CreateFrame("Frame", nil, p)
        r:SetSize(560, 22)
        r:SetPoint("TOPLEFT", 336, -136 - (n - 1) * 25)
        r.text = K.Text(r, 11, col("ink")); r.text:SetPoint("LEFT", 0, 0); r.text:SetWidth(470)
        r.btn = K.Button(r, "Buy", 78, 20, function(self) if r.onClick then r.onClick() end end, function() return r.why or r.tip or "" end)
        r.btn:SetPoint("RIGHT", 0, 0)
        TU.rows.items[n] = r
    end
    TU.btn.table = K.Button(p, "Ask for a Table", 130, 24, function() TU.AskTable() end, "Walk to the host stand; the whole party is seated together.")
    TU.btn.table:SetPoint("TOPLEFT", 336, -470)
    TU.btn.pay = K.Button(p, "Pay and Leave", 130, 24, function() TU.PayLeave() end, "Settle the bill for what was served and get up (works at every step).")
    TU.btn.pay:SetPoint("TOPLEFT", 472, -470)
    TU.btn.cancelBuy = K.Button(p, "Put It Back", 130, 24, function() TU.CancelBuy() end, "Cancel this purchase; nothing is charged.")
    TU.btn.cancelBuy:SetPoint("TOPLEFT", 608, -470)
end

function TU.Create(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    K.Tex(f, "BACKGROUND", K.COL.panel):SetAllPoints()
    TU.frame = f
    TU.text.title = K.Text(f, 16, col("ink")); TU.text.title:SetPoint("TOPLEFT", 16, -12)
    TU.text.sub = K.Text(f, 11, col("inkSoft")); TU.text.sub:SetPoint("TOPLEFT", 16, -34); TU.text.sub:SetText(Tr.POLICY_SHORT)
    TU.text.msg = K.Text(f, 12, col("warn")); TU.text.msg:SetPoint("TOPRIGHT", -16, -14); TU.text.msg:SetWidth(420); TU.text.msg:SetJustifyH("RIGHT")
    buildHome(f)
    buildVenue(f)
    return f
end

---------------------------------------------------------------------------------------------------
-- Cafe and shop actions from the outing screen
function TU.AskTable()
    local w = world()
    local a = TU.Actor(w)
    if not a then return false, "Nobody to ask." end
    local ok, why = SS.Dining.Request(w, a, {})
    TU.sel.msg = ok and nil or why
    TU.Refresh()
    return ok, why
end

function TU.PayLeave()
    local w = world()
    local a = TU.Actor(w)
    local ok, why = SS.Dining.PayAndLeave(w, a and a.id)
    TU.sel.msg = ok and "Paid up." or why
    TU.Refresh()
    return ok, why
end

function TU.ChooseDish(itemId)
    local w = world()
    local a = TU.Actor(w)
    if not a then return false, "Nobody to order for." end
    local ok, why = SS.Dining.Choose(w, a.id, itemId)
    TU.sel.msg = ok and nil or why
    TU.Refresh()
    return ok, why
end

function TU.BuyItem(stockId)
    local w = world()
    local a = TU.Actor(w)
    if not a then return false, "Nobody to buy for." end
    local ok, why = SS.Shopping.Buy(w, a, stockId)
    TU.sel.msg = why
    if ok and UI.SetMode and UI.mode == "travel" then UI.SetMode("live") else TU.Refresh() end
    return ok, why
end

function TU.CancelBuy()
    local w = world()
    local a = TU.Actor(w)
    local ok, why = SS.Shopping.CancelOrder(w, a or {}, "changed their mind")
    TU.sel.msg = ok and "Put it back." or why
    TU.Refresh()
    return ok, why
end

---------------------------------------------------------------------------------------------------
-- Refresh: on open and on every click at once; otherwise only when something it shows changed
-- (the events below mark the screen dirty; checked twice a second) and a slow safety refresh
-- every few seconds. The screen pauses the household, so most of the time nothing changes and
-- nothing is recomputed; venue validation behind it is cached per lot (SS.Venues.ValidateCached).
TU.dirty = true
TU.SAFETY_REFRESH = 5
for _, ev in ipairs({ "money", "taxiCalled", "taxiCancelled", "outingStarted", "outingEnded", "worldAttached", "lotChanged",
    "actionStarted", "actionEnded", "inventory", "notice", "dateEnded", "outingConcluded", "orderPlaced", "timeSkipped" }) do
    SS.On(ev, function() TU.dirty = true end)
end
local function setRow(b, label, sub, active, usable, why)
    b:Show()
    b.label:SetText(label)
    if b.sub then b.sub:SetText(sub or "") end
    b:SetActive(active and true or false)
    b:SetUsable(usable ~= false, why)
    b.why = why
end

local function refreshHome(w)
    local sel = TU.sel
    TU.text.title:SetText("Go Out")
    local dests = TU.Destinations(w)
    local cur
    for n, b in ipairs(TU.rows.venues) do
        local d = dests[n]
        if d then
            b.ref = d.id
            setRow(b, d.name, d.label .. "  -  " .. d.status, d.id == sel.venue, true)
            if d.id == sel.venue then cur = d end
        else
            b.ref = nil; b:Hide()
        end
    end
    TU.text.venue:SetText(TU.VenueDetail(cur))
    local cands = Tr.Candidates(w)
    for n, b in ipairs(TU.rows.people) do
        local c = cands[n]
        if c then
            b.ref = c.rid
            local label = (sel.going[c.rid] and "[x] " or "[  ] ") .. c.name .. (c.age ~= "adult" and ("  (" .. c.age .. ")") or "")
            setRow(b, label, nil, sel.going[c.rid], c.ok, (not c.ok) and c.why or nil)
        else
            b.ref = nil; b:Hide()
        end
    end
    local g = sel.guest and rootOf(w).residents[sel.guest]
    TU.btn.guest.label:SetText("Guest: " .. (g and g.name or "nobody"))
    TU.btn.date.label:SetText("It's a date: " .. (sel.date and "yes" or "no"))
    TU.btn.date:SetUsable(g ~= nil, "Invite someone first.")
    TU.text.trip:SetText(TU.TripLine(w))
    local pending = Tr.Pending(w)
    local ok, why = TU.Check(w)
    if pending then ok, why = false, "A taxi is already on its way." end
    TU.text.check:SetText(ok and ("Ready: " .. #TU.GoingList(w) .. " going" .. (g and (", " .. g.name .. (sel.date and " on a date" or " meeting you")) or "") .. ".") or (why or ""))
    TU.text.check:SetTextColor(unpack(ok and col("good") or col("warn")))
    TU.btn.go:SetUsable(ok, why)
    if pending then TU.btn.cancel:Show() else TU.btn.cancel:Hide() end
end

local function refreshVenue(w)
    local o = V.Active(w)
    local a = TU.Actor(w)
    TU.text.title:SetText(w.lot.name or "Outing")
    TU.text.summary:SetText(table.concat(TU.OutingLines(w), "\n"))
    local party = {}
    for _, rid in ipairs(o.participants or {}) do if w.actors[rid] then party[#party + 1] = w.actors[rid] end end
    for n, b in ipairs(TU.rows.who) do
        local p = party[n]
        if p then b.ref = p.id; setRow(b, p.name, nil, a == p, true) else b.ref = nil; b:Hide() end
    end
    TU.text.log:SetText(table.concat(TU.LogLines(w, 10), "\n"))
    local pending = Tr.Pending(w)
    TU.btn.home:SetUsable(not pending, "The taxi is on its way.")
    TU.text.status:SetText(TU.StatusLine(w, a) or "")
    local kind = V.Kind(w.lot)
    local rows = {}
    for _, b in pairs(TU.btn.vendors) do b:Hide() end
    TU.btn.table:Hide(); TU.btn.pay:Hide(); TU.btn.cancelBuy:Hide()
    if kind == "cafe" then
        TU.text.place:SetText("Menu")
        for _, r in ipairs(SS.Dining.MenuRows(w, a and a.id)) do
            local m = r.item
            rows[#rows + 1] = {
                text = string.format("%s%s  %s  (%s, quality %d/10)", r.chosen and "> " or "", m.name, money(m.price), m.course, m.quality),
                label = r.chosen and "Chosen" or "Choose", usable = r.affordable, why = (not r.affordable) and "The household can't afford it." or nil,
                tip = m.desc, onClick = function() TU.ChooseDish(m.id) end,
            }
        end
        local p = a and SS.Dining.PartyOf(w, a.id)
        TU.btn.table:Show(); TU.btn.pay:Show()
        local okT, whyT = true, nil
        if a then okT, whyT = SS.Dining.CanDine(w, a) end
        TU.btn.table:SetUsable(a ~= nil and okT, whyT)
        TU.btn.pay:SetUsable(p ~= nil, "Not dining right now.")
    elseif kind == "shops" then
        TU.text.place:SetText(VD.vendors[TU.sel.vendor].name)
        for vendor, b in pairs(TU.btn.vendors) do b:Show(); b:SetActive(vendor == TU.sel.vendor) end
        for _, r in ipairs(SS.Shopping.Stock(w, TU.sel.vendor)) do
            local e = r.entry
            local why = a and SS.Shopping.CannotBuy(w, a, e)
            rows[#rows + 1] = {
                text = string.format("%s  %s  (%d left)", e.name, money(e.price), r.left),
                label = "Buy", usable = why == nil and a ~= nil, why = why, tip = e.desc,
                onClick = function() TU.BuyItem(e.id) end,
            }
        end
        TU.btn.cancelBuy:Show()
        TU.btn.cancelBuy:SetUsable(a ~= nil and SS.Shopping.ActiveOrder(w, a.id) ~= nil, "Nothing picked out.")
    else
        TU.text.place:SetText("Things to do here")
        for _, line in ipairs(VD.kinds[kind].activities or {}) do rows[#rows + 1] = { text = line } end
    end
    for n, r in ipairs(TU.rows.items) do
        local d = rows[n]
        if d then
            r:Show()
            r.text:SetText(d.text)
            r.onClick, r.why, r.tip = d.onClick, d.why, d.tip
            if d.onClick then
                r.btn:Show(); r.btn.label:SetText(d.label); r.btn:SetUsable(d.usable ~= false, d.why)
            else
                r.btn:Hide()
            end
        else
            r:Hide()
        end
    end
end

function TU.Refresh()
    local w = world()
    if not TU.frame or not w then return end
    TU.dirty, TU.acc, TU.refreshes = false, 0, (TU.refreshes or 0) + 1
    local out = TU.OnOuting(w)
    TU.homePage:SetShown(not out)
    TU.venuePage:SetShown(out)
    if out then refreshVenue(w) else refreshHome(w) end
    TU.text.msg:SetText(TU.sel.msg or "")
end

---------------------------------------------------------------------------------------------------
-- The mode
TU.mode = {
    label = "Outing", order = 60, key = "F6", fullscreen = true, pausesSim = true,
    tip = "Go out: pick a venue and who goes; at a venue, the outing screen",
    help = TU.HELP,
    create = function(parent) return TU.Create(parent) end,
    canEnter = function(w)
        if not w then return false, "No game is loaded." end
        if w.editVenue then return false, "Not while editing a venue." end
        if w.lot.kind == "community" and not V.Active(w) then return false, "Venues are visited from home." end
        -- the music for this screen: the venue's own while out, the house's otherwise
        TU.mode.audio = Tr.AudioMode(w) or "live"
        return true
    end,
    enter = function(w)
        TU.acc = 0
        if not TU.OnOuting(w) then TU.ResetChoice(w, TU.pendingRef) end
        TU.pendingRef = nil
        TU.Refresh()
    end,
    exit = function() TU.sel.msg = nil end,
    update = function(el)
        TU.acc = (TU.acc or 0) + (el or 0)
        TU.since = (TU.since or 0) + (el or 0)
        if TU.acc >= 0.5 and (TU.dirty or TU.since >= TU.SAFETY_REFRESH) then
            TU.since = 0
            TU.Refresh()
        elseif TU.acc >= 0.5 then
            TU.acc = 0
        end
    end,
}
UI.RegisterMode("travel", TU.mode)

-- Open the chooser (at home) or the outing screen (at a venue). ref: a venue lot id to preselect,
-- or the resident who asked (the phone). Returns ok, why.
function UI.OpenTravel(ref)
    local w = world()
    if not w then return false, "No game is loaded." end
    if not UI.frame or not UI.SetMode then return false, "The destination chooser needs the game window." end
    local ok, why = TU.mode.canEnter(w)
    if not ok then if UI.Notice then UI.Notice(why) end; return false, why end
    TU.pendingRef = ref
    if UI.mode == "travel" then
        if not TU.OnOuting(w) then TU.ResetChoice(w, ref) end
        TU.pendingRef = nil
        TU.Refresh()
        return true
    end
    UI.SetMode("travel")
    return UI.mode == "travel", UI.mode == "travel" and nil or "Couldn't open the outing screen."
end

---------------------------------------------------------------------------------------------------
-- Live-mode tab: the selected resident's outing at a glance
function TU.TabLines(w, a)
    w = w or world()
    if not w then return {} end
    if V.Active(w) then
        local lines = TU.OutingLines(w)
        local s = TU.StatusLine(w, a and V.IsMember(w, a) and a or TU.Actor(w))
        if s then lines[#lines + 1] = s end
        return lines
    end
    local tr = rootOf(w).travel
    local h = tr and tr.history and tr.history[#tr.history]
    local lines = { Tr.POLICY_SHORT }
    local trip = Tr.Pending(w)
    if trip then lines[#lines + 1] = TU.TripLine(w) end
    if h and h.kind == "home" and h.venue then
        local name = VD.kinds[h.venue] and VD.kinds[h.venue].name or h.venue
        lines[#lines + 1] = string.format("Last outing: %s, score %d%s, spent %s.", name, math.floor(h.score or 0),
            h.verdict and (" (" .. h.verdict .. ")") or "", money(math.max(0, h.spent or 0)))
    end
    return lines
end

UI.RegisterTab("outing", {
    label = "Outing", order = 70, tip = "Going out: the current outing, or where to next",
    create = function(parent)
        local f = CreateFrame("Frame", nil, parent)
        f:SetAllPoints(parent)
        f.text = K.Text(f, 11, col("ink")); f.text:SetPoint("TOPLEFT", 4, -4); f.text:SetWidth(300); f.text:SetJustifyV("TOP")
        f.btn = K.Button(f, "Go Out", 100, 22, function()
            local w = world()
            if w and V.Active(w) then TU.GoHome() else UI.OpenTravel(UI.selected) end
        end, "Go out, or go home from a venue")
        f.btn:SetPoint("TOPRIGHT", -4, -4)
        f.open = K.Button(f, "Details", 100, 22, function() UI.OpenTravel() end, "The outing screen (F6)")
        f.open:SetPoint("TOPRIGHT", -4, -30)
        TU.tab = f
        return f
    end,
    refresh = function(f, a, w)
        f.text:SetText(table.concat(TU.TabLines(w, a), "\n"))
        local out = V.Active(w) ~= nil
        f.btn.label:SetText(out and "Go Home" or "Go Out")
        if out then f.btn:SetUsable(Tr.Pending(w) == nil, "The taxi is on its way.")
        else
            local ok, why = TU.mode.canEnter(w)
            f.btn:SetUsable(ok and Tr.Pending(w) == nil, why or "A taxi is already on its way.")
        end
    end,
})

---------------------------------------------------------------------------------------------------
-- Context menus
UI.RegisterMenu("self", function(w, a, ref, entries)
    if not a or not V.IsMember(w, a) then return end
    if V.Active(w) then
        local ok, why = Tr.Pending(w) == nil, "The taxi is on its way."
        entries[#entries + 1] = { label = "Go Home", desc = "Call the taxi home for everyone on the outing.", order = 80,
            disabled = not ok, reason = why, onClick = function() TU.GoHome() end }
        if SS.Dining and SS.Dining.PartyOf(w, a.id) then
            entries[#entries + 1] = { label = "Pay and Leave", desc = "Settle the bill for what was served and get up.", order = 81,
                onClick = function() SS.Dining.PayAndLeave(w, a.id) end }
        end
        if SS.Shopping and SS.Shopping.ActiveOrder(w, a.id) then
            entries[#entries + 1] = { label = "Put It Back", desc = "Cancel this purchase; nothing is charged.", order = 82,
                onClick = function() SS.Shopping.CancelOrder(w, a, "changed their mind") end }
        end
    elseif w.lot.kind ~= "community" and not w.editVenue then
        local ok, why = TU.mode.canEnter(w)
        if ok and Tr.Pending(w) then ok, why = false, "A taxi is already on its way." end
        entries[#entries + 1] = { label = "Go Out...", desc = "Choose a venue and who goes (F6).", order = 80,
            disabled = not ok, reason = why, onClick = function() UI.OpenTravel(a.id) end }
    end
end)

-- Give a bought gift to someone (the social module's own gift interaction may add its own entry).
UI.RegisterMenu("actor", function(w, a, ref, entries)
    local target = ref and w.actors[ref]
    if not a or not target or target == a or not V.IsMember(w, a) or not SS.Shopping then return end
    local gifts = SS.Shopping.Gifts(w)
    if #gifts == 0 then return end
    local sub = {}
    for n, it in ipairs(gifts) do
        if n > 8 then break end
        local okA, why = SS.Actions.Available(w, a, target, "outing_give_gift")
        sub[#sub + 1] = { label = it.name, desc = it.data and it.data.desc or nil, disabled = not okA, reason = why,
            onClick = function() SS.Actions.Order(w, a, nil, "outing_give_gift", nil, nil, { tid = target.id, data = { uid = it.uid } }) end }
    end
    entries[#entries + 1] = { label = "Give a Gift", desc = "Give " .. target.name .. " something from the household's things.", order = 60, submenu = sub }
end)

-- Buy straight from a shop display; change at a booth into a bought outfit.
UI.RegisterMenu("obj", function(w, a, oid, entries)
    local o = w.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return end
    if SS.Shopping and SS.Shopping.IsShops(w) then
        local vendor
        for tag, v in pairs(VD.displayVendor) do if SS.Tags.Has(def, tag) then vendor = v end end
        if vendor then
            local sub = {}
            for _, r in ipairs(SS.Shopping.Stock(w, vendor)) do
                local e = r.entry
                local why = (not a and "Select a resident first.") or SS.Shopping.CannotBuy(w, a, e)
                sub[#sub + 1] = { label = string.format("%s (%s)", e.name, money(e.price)), desc = e.desc, disabled = why ~= nil, reason = why,
                    onClick = function() SS.Shopping.Buy(w, a, e.id) end }
            end
            entries[#entries + 1] = { label = "Buy...", desc = VD.vendors[vendor].name .. ": pick something, then pay at the till.", order = 20, submenu = sub }
        end
    end
    -- the bar's menu: pick the drink (the plain "Order a Drink" lets the resident choose)
    if V.Active(w) and V.Supports(def, "bar_drink") then
        local iid = V.IidFor(def, "bar_drink")
        local okA, whyA
        if a then okA, whyA = SS.Actions.Available(w, a, o, iid) else okA, whyA = false, "Select a resident first." end
        local tab = a and V.Tab(w, "drink", a.id)
        local funds = a and V.Funds(w, a)
        local sub = {}
        for _, d in ipairs(VD.drinks) do
            local why = whyA
            if okA and tab and tab.item ~= d.id then why = "Finish the " .. (V.Drink(tab.item) or d).name .. " first (already paid for)."
            elseif okA and not tab and funds and funds < d.price then why = "Not enough money (" .. money(d.price) .. ")." end
            local fx = string.format("fun +%d, social +%d%s", d.fun or 0, d.social or 0, d.energy and (", energy +" .. d.energy) or "")
            sub[#sub + 1] = { label = string.format("%s (%s)", d.name, (tab and tab.item == d.id) and "paid" or money(d.price)), desc = fx,
                disabled = why ~= nil, reason = why,
                onClick = function() SS.Actions.Order(w, a, oid, iid, nil, nil, { data = { drink = d.id } }) end }
        end
        entries[#entries + 1] = { label = "Order a Drink...", desc = "Pick a drink from the bar's menu; it is paid for when it is handed over.", order = 22, submenu = sub }
    end
    if a and V.Supports(def, "wear_bought") and #(a.wardrobe or {}) > 0 then
        local sub = {}
        for _, wd in ipairs(a.wardrobe) do
            sub[#sub + 1] = { label = wd.name .. (wd.worn and " (wearing)" or ""), onClick = function()
                SS.Actions.Order(w, a, oid, V.IidFor(def, "wear_bought"), nil, nil, { data = { wid = wd.id } })
            end }
        end
        entries[#entries + 1] = { label = "Wear a Bought Outfit...", desc = "Wear one of " .. a.name .. "'s bought outfits.", order = 21, submenu = sub }
    end
end)

---------------------------------------------------------------------------------------------------
-- Help (the ui-shell help panel lists registered topics; the mode's own help covers older shells)
if UI.RegisterHelp then
    UI.RegisterHelp("outings", { title = "Going out", order = 60, lines = TU.HELP })
end
