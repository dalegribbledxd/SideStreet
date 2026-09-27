-- SideStreet phone and visitors UI: the "Phone" toolbar button and panel (categorised "Call..."
-- list with sub-options, expected visits with Cancel, missed calls), context-menu entries on phones,
-- doorbells and visitors (Greet, Invite In, Ask to Leave, Pay for Delivery, Send Home, Invite Over),
-- and a "Visitors" live tab. Owner: visitors module. Every call made here sends the selected resident
-- to a real phone (SS.Phone.Place); nothing happens from the menu by itself.
-- Nothing touches WoW frames at load time; the panel is built on first use.
local _, SS = ...
local UI = SS.UI
local K = UI.Kit
local COL = K.COL
local P = {}
UI.Phone = P

local function world() return SS.Sim.world end
local function caller() return UI.SelectedActor and UI.SelectedActor() end
local function notice(msg) if msg and UI.Notice then UI.Notice(msg) end end

---------------------------------------------------------------------------------------------------
-- Panel
local ROWS, ROW_H = 8, 22

local function setRow(row, label, enabled, tip, onClick)
    row.label:SetText(label .. (enabled and "" or "  (unavailable)"))
    row.label:SetTextColor(enabled and COL.ink[1] or COL.inkSoft[1], enabled and COL.ink[2] or COL.inkSoft[2], enabled and COL.ink[3] or COL.inkSoft[3])
    row.tipText, row.onClick, row.enabled = tip, onClick, enabled
end

function P.Create()
    if P.frame then return P.frame end
    local f = CreateFrame("Frame", nil, UI.frame)
    f:SetFrameStrata("DIALOG")
    f:SetSize(280, 400)
    f:SetPoint("TOPRIGHT", UI.frame, "TOPRIGHT", -10, -60)
    f:EnableMouse(true)
    K.Tex(f, "BACKGROUND", COL.panel):SetAllPoints()
    f.title = K.Text(f, 14); f.title:SetPoint("TOPLEFT", 10, -8); f.title:SetText("Phone")
    f.who = K.Text(f, 11, COL.inkSoft); f.who:SetPoint("TOPLEFT", 10, -26); f.who:SetWidth(200)
    local close = K.Button(f, "X", 22, 20, function() P.Hide() end, "Close the phone")
    close:SetPoint("TOPRIGHT", -6, -6)
    f.close = close
    -- category buttons (only categories that have numbers are shown)
    f.cats = {}
    for n = 1, #SS.Phone.categories do
        local b = K.Button(f, "", 84, 20, function(self) P.ShowCategory(self.catId) end)
        b:SetPoint("TOPLEFT", 10 + ((n - 1) % 3) * 88, -44 - math.floor((n - 1) / 3) * 23)
        b:Hide()
        f.cats[n] = b
    end
    f.back = K.Button(f, "< Back", 60, 18, function() P.ShowCategory(P.cat) end, "Back to the list")
    f.back:SetPoint("TOPLEFT", 10, -94)
    f.back:Hide()
    f.heading = K.Text(f, 12); f.heading:SetPoint("TOPLEFT", 76, -95); f.heading:SetWidth(190)
    f.list = K.PagedList(f, ROWS, ROW_H, function(row)
        row.bg = K.Tex(row, "BACKGROUND", COL.panelDark); row.bg:SetAllPoints()
        row.hi = K.Tex(row, "HIGHLIGHT", COL.accentHi); row.hi:SetAllPoints()
        row.label = K.Text(row, 11); row.label:SetPoint("LEFT", 6, 0); row.label:SetWidth(250)
        row:SetScript("OnClick", function(self)
            if not self.enabled then notice(self.tipText); return end
            if self.onClick then self.onClick() end
        end)
        K.Tooltip(row, function(self) return self.tipText end)
    end, function(row, item)
        setRow(row, item.label, item.enabled, item.tip, item.onClick)
    end)
    f.list.frame:SetPoint("TOPLEFT", 10, -116)
    f.list.frame:SetSize(260, ROWS * ROW_H + 20)
    -- expected visits and missed calls
    f.expTitle = K.Text(f, 12); f.expTitle:SetPoint("TOPLEFT", 10, -318); f.expTitle:SetText("Expected")
    f.exp = {}
    for n = 1, 3 do
        local line = K.Text(f, 10, COL.inkSoft); line:SetPoint("TOPLEFT", 10, -334 - (n - 1) * 18); line:SetWidth(190)
        local b = K.Button(f, "Cancel", 54, 16, function(self) P.CancelVisit(self.vid) end, "Cancel before they reach the door: no charge")
        b:SetPoint("TOPLEFT", 214, -332 - (n - 1) * 18)
        b:Hide()
        f.exp[n] = { line = line, btn = b }
    end
    f.missed = K.Text(f, 10, COL.inkSoft); f.missed:SetPoint("BOTTOMLEFT", 10, 6); f.missed:SetWidth(260)
    f.acc = 0
    f:SetScript("OnUpdate", function(self, el)
        self.acc = self.acc + (el or 0)
        if self.acc >= 0.5 then self.acc = 0; P.RefreshStatus() end
    end)
    f:Hide()
    P.frame = f
    return f
end

function P.IsShown() return P.frame and P.frame:IsShown() or false end
function P.Hide() if P.frame then P.frame:Hide() end end
function P.Show()
    if not UI.frame then return end
    local f = P.Create()
    f:Show()
    P.RefreshCategories()
    P.ShowCategory(P.cat or "Services")
    P.RefreshStatus()
end
function P.Toggle() if P.IsShown() then P.Hide() else P.Show() end end

function P.RefreshCategories()
    local f, w = P.frame, world()
    if not f or not w then return end
    local cats = SS.Phone.CallsByCategory(w, caller())
    P.catList = cats
    for n, b in ipairs(f.cats) do
        local c = cats[n]
        if c then
            b.label:SetText(c.label)
            b.catId = c.id
            b:Show()
        else
            b:Hide()
        end
    end
    local have = false
    for _, c in ipairs(cats) do if c.id == P.cat then have = true end end
    if not have then P.cat = cats[1] and cats[1].id end
end

-- The list of calls in a category (each row places the call or opens its options).
function P.CallItems(cat)
    local w, a = world(), caller()
    local items = {}
    for _, def in ipairs(SS.Phone.Calls(w, a, cat)) do
        local ok, why = SS.Phone.Check(w, a, def)
        local label = SS.Phone.Label(w, a, def) .. (def.options and "  >" or "")
        items[#items + 1] = { id = def.id, label = label, enabled = ok, tip = ok and def.desc or why,
            onClick = function()
                if def.options then P.ShowOptions(def) else P.Place(def.id) end
            end }
    end
    return items
end

function P.ShowCategory(cat)
    local f = P.frame
    if not f then return end
    P.cat, P.opened = cat, nil
    f.back:Hide()
    for _, b in ipairs(f.cats) do b:SetActive(b.catId == cat) end
    f.heading:SetText("")
    f.list:SetItems(P.CallItems(cat))
    local a = caller()
    f.who:SetText(a and ("Calling as " .. a.name) or "Select someone in the household to make calls")
end

function P.OptionItems(def)
    local w, a = world(), caller()
    local items = {}
    for _, o in ipairs(SS.Phone.Options(w, a, def) or {}) do
        local ok, why = SS.Phone.Check(w, a, def, o.arg)
        if ok and o.disabled then ok, why = false, o.reason end
        items[#items + 1] = { label = o.label, enabled = ok, tip = ok and o.desc or why, onClick = function() P.Place(def.id, o.arg) end }
    end
    if #items == 0 then items[1] = { label = "Nobody to call", enabled = false, tip = "Nobody on this list yet." } end
    return items
end

function P.ShowOptions(def)
    local f = P.frame
    P.opened = def.id
    f.back:Show()
    f.heading:SetText(SS.Phone.Label(world(), caller(), def))
    f.list:SetItems(P.OptionItems(def))
end

function P.Place(callId, arg)
    local w, a = world(), caller()
    local ok, msg = SS.Phone.Place(w, a, callId, arg)
    notice(msg)
    if ok then P.Hide() end
    return ok, msg
end

function P.CancelVisit(vid)
    local ok, msg = SS.Services.Cancel(world(), vid)
    notice(msg)
    P.RefreshStatus()
    return ok, msg
end

function P.RefreshStatus()
    local f, w = P.frame, world()
    if not f or not w or not f:IsShown() then return end
    local rows = {}
    for _, v in ipairs(SS.Services.Expected(w)) do
        local S = SS.RoleData.services[v.kind]
        local state = v.committed and "here now" or ("around " .. SS.Visitors.ClockText(v.at))
        rows[#rows + 1] = { text = S.label .. ": " .. state .. (v.regular and " (daily)" or ""), vid = (not v.committed) and v.id or nil }
    end
    for _, r in ipairs(SS.Visitors.Expected(w)) do
        local who = r.rid and w.root.residents[r.rid]
        rows[#rows + 1] = { text = (who and who.name or r.role) .. ": around " .. SS.Visitors.ClockText(r.at) }
    end
    f.expTitle:SetText(#rows > #f.exp and string.format("Expected (%d; the first %d shown)", #rows, #f.exp) or "Expected")
    for n, e in ipairs(f.exp) do
        local row = rows[n]
        e.line:SetText(row and row.text or (n == 1 and "Nobody is expected." or ""))
        e.btn.vid = row and row.vid
        e.btn:SetShown(row and row.vid ~= nil)
    end
    local missed = SS.Phone.MissedFor(w)
    local last = missed[#missed]
    local who = last and last.from and w.root.residents[last.from]
    f.missed:SetText(#missed > 0 and string.format("Missed calls: %d (last: %s, %s)", #missed, who and who.name or "unknown",
        SS.Visitors.ClockText(last.t)) or "No missed calls.")
end

UI.RegisterToolbar("phone", { label = "Phone", width = 50, order = 30,
    tip = "Call services, friends and more. The selected resident walks to a phone to make the call.",
    onClick = function() P.Toggle() end })

---------------------------------------------------------------------------------------------------
-- Context menus
local V = SS.Visitors

-- "Call..." on a phone object: categories > calls > options, placing the call at this phone.
local function callMenu(w, a, oid)
    local sub = {}
    for _, c in ipairs(SS.Phone.CallsByCategory(w, a)) do
        local calls = {}
        for _, def in ipairs(c.calls) do
            local ok, why = SS.Phone.Check(w, a, def)
            local e = { label = SS.Phone.Label(w, a, def), desc = def.desc, disabled = not ok, reason = why }
            if def.options and ok then
                e.submenu = {}
                for _, o in ipairs(SS.Phone.Options(w, a, def) or {}) do
                    local ok2, why2 = SS.Phone.Check(w, a, def, o.arg)
                    if ok2 and o.disabled then ok2, why2 = false, o.reason end
                    e.submenu[#e.submenu + 1] = { label = o.label, desc = o.desc, disabled = not ok2, reason = why2,
                        onClick = function() notice(select(2, SS.Phone.Place(w, a, def.id, o.arg, oid))) end }
                end
            else
                e.onClick = function() notice(select(2, SS.Phone.Place(w, a, def.id, nil, oid))) end
            end
            calls[#calls + 1] = e
        end
        sub[#sub + 1] = { label = c.label, submenu = calls }
    end
    return sub
end

-- The first visitor waiting at the door who isn't being answered yet.
function P.WaitingVisitor(w)
    for _, id in ipairs(SS.Sim.ActorIds(w)) do
        local v = w.actors[id]
        local vs = V.IsVisitor(w, v) and v.roleData and v.roleData.vs
        if vs and vs.state == "door" and not vs.greeted and not V.BeingAnswered(w, v) then return v end
    end
end

UI.RegisterMenu("obj", function(w, a, oid, entries)
    local o = w.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return end
    if SS.Tags.Has(def, "phone") then
        local ok, why = true, nil
        if not a then ok, why = false, "Select a resident first." elseif not V.IsMember(w, a) then ok, why = false, "Only the household uses the phone." end
        entries[#entries + 1] = { label = "Call...", order = 5, desc = "Make a call from this phone.", disabled = not ok, reason = why,
            submenu = ok and callMenu(w, a, oid) or nil }
    end
    if SS.Tags.Has(def, "doorbell") then
        local v = P.WaitingVisitor(w)
        local iid = v and (v.role == "courier" and "door_pay" or "door_greet")
        local ok, why = false, "Nobody is at the door."
        if v and a then ok, why = SS.Actions.Available(w, a, v, iid) elseif v then why = "Select a resident first." end
        entries[#entries + 1] = { label = "Answer the Door", order = 5, desc = v and (v.name .. " is at the door.") or nil,
            disabled = not ok, reason = why,
            onClick = function() SS.Actions.Order(w, a, nil, iid, nil, nil, { tid = v.id }) end }
    end
end)

-- The front door itself: clicking the floor just inside or outside an exterior door while someone
-- waits offers "Answer the Door" (ref = { i, j, level } or { i = , j = , level = }).
function P.DoorAt(w, i, j, level)
    if (level or 0) ~= 0 then return nil end
    for _, d in ipairs(V.Doors(w)) do
        if (d.stand[1] == i and d.stand[2] == j) or (d.inside[1] == i and d.inside[2] == j) then return d end
    end
end
UI.RegisterMenu("cell", function(w, a, ref, entries)
    if type(ref) ~= "table" then return end
    local i, j = ref.i or ref[1], ref.j or ref[2]
    if not (i and j) or not P.DoorAt(w, math.floor(i), math.floor(j), ref.level or ref[3]) then return end
    local v = P.WaitingVisitor(w)
    if not v then return end
    local iid = v.role == "courier" and "door_pay" or "door_greet"
    local ok, why = false, "Select a resident first."
    if a then ok, why = SS.Actions.Available(w, a, v, iid) end
    entries[#entries + 1] = { label = "Answer the Door", order = 5, desc = v.name .. " is at the door.", disabled = not ok, reason = why,
        onClick = function() SS.Actions.Order(w, a, nil, iid, nil, nil, { tid = v.id }) end }
end)

local DOOR = {
    { iid = "door_greet", order = 1 }, { iid = "door_invite", order = 2 }, { iid = "door_pay", order = 3 },
    { iid = "door_ask", order = 8 }, { iid = "door_dismiss", order = 9 },
}
local RELEVANT = {
    guest = { door_greet = true, door_invite = true, door_ask = true },
    courier = { door_pay = true, door_ask = true },
    mail = { door_ask = true },
    cleaner = { door_dismiss = true }, repair = { door_dismiss = true }, gardener = { door_dismiss = true },
}

UI.RegisterMenu("actor", function(w, a, rid, entries)
    local t = w.actors[rid]
    if not t or not t.role or not a or not V.IsMember(w, a) then return end
    local rel = RELEVANT[t.role]
    local acc = V.AccessOf(t.role)
    if not rel and (acc == "guest" or acc == "public") and t.role ~= "walkby" then rel = RELEVANT.guest end
    for _, d in ipairs(DOOR) do
        if rel and rel[d.iid] then
            local ok, why = SS.Actions.Available(w, a, t, d.iid)
            local ia = SS.Interactions[d.iid]
            entries[#entries + 1] = { label = ia.label, order = d.order, disabled = not ok, reason = why,
                onClick = function() SS.Actions.Order(w, a, nil, d.iid, nil, nil, { tid = t.id }) end }
        end
    end
    if t.role == "walkby" then
        local vs = t.roleData and t.roleData.vs
        local ok, why = true, nil
        if a.age == "child" then ok, why = false, "Only adults can invite visitors over." end
        if not V.HomeLot(w) then ok, why = false, "You can only invite people to your own home." end
        entries[#entries + 1] = { label = "Invite Over", order = 1, disabled = not ok, reason = why,
            desc = "Wave them in: they come up to the door as an invited guest.",
            onClick = function()
                local done, msg = V.CallOver(w, a, t)
                if not done then notice(msg) end
            end }
    end
end)

---------------------------------------------------------------------------------------------------
-- "Visitors" live tab: who is here, who is expected, missed calls.
local LINES = 9
UI.RegisterTab("visitors", { label = "Visitors", order = 60, tip = "Visitors, service workers and expected arrivals",
    create = function(parent)
        local f = CreateFrame("Frame", nil, parent)
        f:SetAllPoints(parent)
        f.lines = {}
        for n = 1, LINES do
            local t = K.Text(f, 11)
            t:SetPoint("TOPLEFT", 4, -2 - (n - 1) * 15)
            t:SetWidth(410)
            f.lines[n] = t
        end
        return f
    end,
    refresh = function(f, actor, w)
        local out = P.TabLines(w)
        local key = table.concat(out, "\n")
        if key == f.last then return end
        f.last = key
        for n = 1, LINES do f.lines[n]:SetText(out[n] or "") end
    end,
})

-- Text lines for the tab (also used by tests).
function P.TabLines(w)
    local out = {}
    local here = {}
    for _, id in ipairs(SS.Sim.ActorIds(w)) do
        local a = w.actors[id]
        if V.IsVisitor(w, a) then here[#here + 1] = V.Describe(w, a) end
    end
    out[#out + 1] = #here > 0 and ("Here now (" .. #here .. "):") or "Nobody is visiting."
    for n = 1, math.min(#here, 4) do out[#out + 1] = "  " .. here[n] end
    local exp = {}
    for _, v in ipairs(SS.Services.Expected(w)) do
        if not v.committed then exp[#exp + 1] = SS.RoleData.services[v.kind].label .. " around " .. V.ClockText(v.at) end
    end
    for _, r in ipairs(V.Expected(w)) do
        local who = r.rid and w.root.residents[r.rid]
        exp[#exp + 1] = (who and who.name or r.role) .. " around " .. V.ClockText(r.at)
    end
    if #exp > 0 then out[#out + 1] = "Expected: " .. table.concat(exp, "; ") end
    local missed = SS.Phone.MissedFor(w)
    if #missed > 0 then out[#out + 1] = "Missed calls: " .. #missed end
    return out
end
