-- Career, skills and money UI: the Work tab (job or school), the Skills tab, the Money tab (funds,
-- weekly summary, bills, sandbox money), the household ledger window, decision popups (career chance
-- events, job offers, report cards, promotions) and context-menu entries.
-- Owner: careers module (docs/modules/careers.md). Everything is built lazily from UI hooks; nothing
-- touches WoW frames at load time. Works with both the baseline kit and the ui-shell kit (colour names
-- when K.C exists, colour tables otherwise).
local _, SS = ...
local UI = SS.UI or {}
SS.UI = UI
local CU = UI.Career or {}
UI.Career = CU

local function K() return UI.Kit end
-- colours the baseline kit does not name (the ui-shell kit has them all)
local FALLBACK = { paper = { 1, 0.96, 0.88 }, trim = { 0.45, 0.32, 0.21, 1 }, accentDeep = { 0.10, 0.32, 0.31, 1 },
    inkSoft = { 0.42, 0.37, 0.31 }, ink = { 0.20, 0.17, 0.14 }, warn = { 0.85, 0.35, 0.25 }, good = { 0.35, 0.68, 0.30 },
    panel = { 0.93, 0.89, 0.80, 1 }, barBg = { 0.30, 0.28, 0.26, 1 } }
local function rgb(name)
    if type(name) == "table" then return name end
    local k = K()
    if k.C and (k.COL[name] or not FALLBACK[name]) then return k.C(name) end
    return k.COL[name] or FALLBACK[name] or k.COL.ink
end
local function cname(name)
    if type(name) == "table" then return name end
    if K().C and K().COL[name] then return name end
    return rgb(name)
end
local function text(parent, size, colour, justify)
    local fs = K().Text(parent, size or 11, cname(colour or "ink"), justify)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    return fs
end
local function tex(parent, layer, colour) return K().Tex(parent, layer, cname(colour)) end
local function setColour(fs, name)
    if K().SetTextColor then K().SetTextColor(fs, name) else local c = rgb(name); fs:SetTextColor(c[1], c[2], c[3]) end
end
local function button(parent, label, w, h, fn, tip) return K().Button(parent, label, w, h, fn, tip) end
local function usable(b, on, why)
    b.ssWhyText = (not on) and why or nil
    if b.SetUsable then b:SetUsable(on, why) end
end
local function money(v)
    if UI.Money then return UI.Money(v) end
    return SS.U.fmtMoney(v)
end
local function world() return SS.Sim.world end
local function clock(t) return SS.Sim.ClockText(t) end
local function notice(msg, kind) if msg and UI.Notice then UI.Notice(msg, kind) end end
local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

-- A -100..100 (or lo..hi) horizontal bar with a label, drawn with plain textures.
local function bar(parent, w, h)
    local b = CreateFrame("Frame", nil, parent)
    b:SetSize(w, h)
    b.bg = tex(b, "BACKGROUND", "barBg"); b.bg:SetAllPoints()
    b.fill = K().Tex(b, "ARTWORK", { 1, 1, 1, 1 }); b.fill:SetPoint("LEFT"); b.fill:SetHeight(h)
    b.mark = K().Tex(b, "OVERLAY", { 0, 0, 0, 0.7 }); b.mark:SetSize(1, h)
    b.w = w
    function b:SetValue(v, lo, hi, markAt)
        lo, hi = lo or -100, hi or 100
        local frac = math.max(0, math.min(1, (v - lo) / (hi - lo)))
        self.fill:SetWidth(math.max(1, frac * self.w))
        local good = v >= (markAt or 0)
        if good then self.fill:SetColorTexture(0.36, 0.66, 0.32, 1) else self.fill:SetColorTexture(0.86, 0.38, 0.26, 1) end
        self.mark:ClearAllPoints()
        self.mark:SetPoint("LEFT", self, "LEFT", math.floor(((markAt or 0) - lo) / (hi - lo) * self.w), 0)
    end
    return b
end

---------------------------------------------------------------------------------------------------
-- Popups: a small queue of dialogs (decisions and news). Bounded; duplicates (same key) merge.
---------------------------------------------------------------------------------------------------
CU.queue = CU.queue or {}
CU.POPUP_CAP = 6
CU.MAX_ROWS = 6

local function buildPopup()
    local parent = UI.frame or UIParent
    local p = CreateFrame("Frame", nil, parent)
    p:SetFrameStrata("DIALOG")
    p:SetSize(400, 200)
    p:SetPoint("CENTER", parent, "CENTER", 0, 40)
    p:EnableMouse(true)
    p.trim = tex(p, "BACKGROUND", "trim"); p.trim:SetAllPoints()
    p.body = tex(p, "BORDER", "panel"); p.body:SetPoint("TOPLEFT", 2, -2); p.body:SetPoint("BOTTOMRIGHT", -2, 2)
    p.head = tex(p, "ARTWORK", "accentDeep"); p.head:SetPoint("TOPLEFT", 2, -2); p.head:SetPoint("TOPRIGHT", -2, -2); p.head:SetHeight(20)
    p.title = text(p, 12, "paper"); p.title:SetPoint("TOPLEFT", 8, -5); p.title:SetWidth(360)
    p.close = button(p, "x", 20, 18, function() CU.ClosePopup("closed") end, "Close (decide later)")
    p.close:SetPoint("TOPRIGHT", -3, -3)
    p.text = text(p, 11, "ink"); p.text:SetPoint("TOPLEFT", 10, -28); p.text:SetWidth(380)
    if p.text.SetWordWrap then p.text:SetWordWrap(true) end
    p.text:SetJustifyV("TOP")
    p.rows = {}
    for n = 1, CU.MAX_ROWS do
        local r = CreateFrame("Frame", nil, p)
        r:SetSize(380, 34)
        r.label = text(r, 11, "ink"); r.label:SetPoint("TOPLEFT", 0, -2); r.label:SetWidth(290)
        r.sub = text(r, 10, "inkSoft"); r.sub:SetPoint("TOPLEFT", 0, -16); r.sub:SetWidth(290)
        r.btn = button(r, "", 84, 22, function(self) CU.PopupChoice(n) end, function(self) return self.ssTipText or self.ssWhyText or "" end)
        r.btn:SetPoint("RIGHT", 0, 0)
        p.rows[n] = r
    end
    p:Hide()
    if UI.RegisterFloating then UI.RegisterFloating(p, function() CU.ClosePopup("closed") end) end
    CU.popup = p
    return p
end

-- spec = { key, kind, title, text, rows = { { label, sub, button, tip, disabled = why, fn } }, onClose }
function CU.ShowPopup(spec)
    for n, q in ipairs(CU.queue) do
        if spec.key and q.key == spec.key then CU.queue[n] = spec; if n == 1 and CU.popup and CU.popup:IsShown() then CU.Render() end; return end
    end
    CU.queue[#CU.queue + 1] = spec
    while #CU.queue > CU.POPUP_CAP do table.remove(CU.queue, 2) end
    if #CU.queue == 1 then CU.Render() end
end

function CU.Current() return CU.queue[1] end

function CU.Render()
    local spec = CU.queue[1]
    if not spec then if CU.popup then CU.popup:Hide() end; return end
    if not UI.frame then return end -- shown when the window next opens
    local p = CU.popup or buildPopup()
    p.title:SetText(spec.title or "")
    p.text:SetText(spec.text or "")
    local chars = #(spec.text or "")
    local lines = math.max(1, math.ceil(chars * 6 / 380))
    local th = math.max(lines * 13, p.text:GetStringHeight() or 0)
    p.text:SetHeight(th)
    local y = -34 - th
    for n, r in ipairs(p.rows) do
        local row = spec.rows and spec.rows[n]
        if row then
            r:ClearAllPoints(); r:SetPoint("TOPLEFT", 10, y)
            r.label:SetText(row.label or "")
            r.sub:SetText(row.sub or "")
            r.btn.label:SetText(row.button or "Choose")
            r.btn.ssTipText = row.tip
            usable(r.btn, not row.disabled, row.disabled)
            r:Show()
            y = y - ((row.sub and row.sub ~= "") and 36 or 26)
        else
            r:Hide()
        end
    end
    p:SetHeight(-y + 10)
    p:Show()
    if SS.Audio and SS.Audio.Cue then SS.Audio.Cue("alert") end
end

function CU.PopupChoice(n)
    local spec = CU.queue[1]
    local row = spec and spec.rows and spec.rows[n]
    if not row then return end
    if row.disabled then notice(row.disabled); return end
    local keep = row.fn and row.fn()
    if keep ~= "keep" then
        table.remove(CU.queue, 1)
        CU.Render()
    else
        CU.Render()
    end
    UI.dirty = true
end

function CU.ClosePopup(why)
    local spec = table.remove(CU.queue, 1)
    if spec and spec.onClose then spec.onClose(why) end
    CU.Render()
end

---------------------------------------------------------------------------------------------------
-- Popup builders
---------------------------------------------------------------------------------------------------
function CU.ChanceRows(w, actor)
    local c = actor.career
    local p = c and c.pending
    local e = p and SS.Career.ChanceDef(p.id)
    if not e then return nil end
    local rows = {}
    for n, ch in ipairs(e.choices) do
        local tip = ch.tip or ""
        if ch.check then
            tip = tip .. string.format(" Chance of success: %d%% (%s %d).", math.floor(SS.Career.CheckChance(actor, ch.check) * 100 + 0.5),
                SS.Skills.Label(ch.check.skill), SS.Skills.Level(actor, ch.check.skill))
        end
        rows[#rows + 1] = { label = ch.label, sub = ch.tip, button = "Choose", tip = tip,
            fn = function()
                local wd = world()
                local a = wd and wd.root.residents[actor.id]
                if not a then return end
                local ok, msg = SS.Career.ResolveChance(wd, a, n, "player")
                if not ok then notice(msg) end
            end }
    end
    return e, rows
end

function CU.ShowChance(w, actor)
    local e, rows = CU.ChanceRows(w, actor)
    if not e then return end
    CU.ShowPopup({ key = "chance:" .. actor.id, kind = "chance", title = e.title .. " (" .. actor.name .. ")",
        text = e.text .. "\n\nIf nobody decides, " .. actor.name .. " takes the safe option.", rows = rows })
end

-- The offers popup. A list longer than the popup's rows is shown in pages: the last row turns the page,
-- so every listed opening can be reached (the job line can read out up to 11).
function CU.ShowOffers(w, actor, source, list, page)
    list = list or {}
    local rows = {}
    local listedDay = math.floor((w and w.time or 0) / 1440)
    local per = #list > CU.MAX_ROWS and CU.MAX_ROWS - 1 or CU.MAX_ROWS
    local pages = math.max(1, math.ceil(#list / per))
    page = math.max(1, math.min(page or 1, pages))
    for k = (page - 1) * per + 1, math.min(#list, page * per) do
        local off = list[k]
        local sub = string.format("%s. %s per shift. Carpool: %s.", off.shift, money(off.pay), off.carpool)
        if not off.ok then sub = sub .. " " .. (off.why or "") end
        rows[#rows + 1] = { label = string.format("%s (%s, level %d)", off.title, off.name, off.level), sub = sub,
            button = "Take Job", tip = off.desc, disabled = (not off.ok) and off.why or nil, offer = off,
            fn = function()
                local wd = world()
                local a = wd and wd.root.residents[actor.id]
                if not a then return end
                if math.floor(wd.time / 1440) ~= listedDay then notice("Those listings are from another day. Look again for today's jobs."); return end
                local go = function()
                    local ok, msg = SS.Career.Accept(wd, a, off.track, off.level, source)
                    notice(msg)
                end
                if a.career then
                    UI.Confirm(string.format("%s already works as a %s. Take the new job and leave the old one?", a.name, SS.Career.Title(a) or "worker"), go)
                else
                    go()
                end
            end }
    end
    if pages > 1 then
        local nextPage = page % pages + 1
        rows[#rows + 1] = { label = "More openings", sub = string.format("Page %d of %d. %d openings in all.", page, pages, #list),
            button = nextPage == 1 and "First Page" or "Next Page", tip = "Show the other openings.", more = true,
            fn = function() CU.ShowOffers(w, actor, source, list, nextPage); return "keep" end }
    end
    local src = source == "computer" and "Job listings online" or source == "phone" and "The job line"
        or source == "seen" and "Today's job listings" or "Jobs in today's newspaper"
    local text = "No openings today. Try again tomorrow."
    if #list > 0 then
        text = string.format("%d opening%s today. New listings every day. Jobs need the skills and friends shown; better jobs have longer hours or odd shifts.",
            #list, #list == 1 and "" or "s")
    end
    CU.ShowPopup({ key = "offers:" .. actor.id, kind = "offers", title = src .. " (" .. actor.name .. ")", text = text, rows = rows,
        page = page, pages = pages, total = #list })
end

---------------------------------------------------------------------------------------------------
-- Event hooks (popups for decisions and important news)
---------------------------------------------------------------------------------------------------
SS.On("careerOffers", function(w, actor, source, list) CU.ShowOffers(w, actor, source, list) end)
SS.On("careerChance", function(w, actor, e) CU.ShowChance(w, actor) end)
SS.On("careerChanceResolved", function(w, actor)
    for n = #CU.queue, 1, -1 do
        if CU.queue[n].key == "chance:" .. actor.id then
            table.remove(CU.queue, n)
            if n == 1 then CU.Render() end
        end
    end
end)
SS.On("careerPromoted", function(w, actor, level)
    local lv = SS.Career.Current(actor)
    if not lv then return end
    CU.ShowPopup({ key = "promo:" .. actor.id, kind = "news", title = "Promotion: " .. actor.name,
        text = string.format("%s is now a %s: %s per shift, %s.", actor.name, lv.title, money(SS.Career.Pay(w, lv)), SS.Career.ShiftText(lv)),
        rows = { { label = "Wonderful.", button = "OK" } } })
end)
SS.On("careerEnded", function(w, actor, reason)
    if reason ~= "fired" then return end
    CU.ShowPopup({ key = "fired:" .. actor.id, kind = "news", title = "Job lost: " .. actor.name,
        text = actor.name .. " no longer has a job. Look in the newspaper or on a computer for a new one; skills are kept.",
        rows = { { label = "Back to the job hunt.", button = "OK" } } })
end)
SS.On("reportCard", function(w, child, letter, score, eff)
    CU.ShowPopup({ key = "report:" .. child.id, kind = "news", title = "Report card: " .. child.name .. " - " .. letter,
        text = eff.text .. string.format(" (Class score %d of 100.)", math.floor(score + 0.5)),
        rows = { { label = (letter == "A" or letter == "B") and "Well done." or "We'll work on it.", button = "OK" } } })
end)
SS.On("worldAttached", function()
    CU.queue = {}
    if CU.popup then CU.popup:Hide() end
    local w = world()
    if not w then return end
    for _, m in ipairs(SS.Career.Members(w)) do
        if m.career and m.career.pending then CU.ShowChance(w, m) end
    end
end)

---------------------------------------------------------------------------------------------------
-- Work tab (job, or school for children)
---------------------------------------------------------------------------------------------------
function CU.CreateWork(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.title = text(f, 12, "ink"); f.title:SetPoint("TOPLEFT", 4, -2); f.title:SetWidth(250)
    f.lines = {}
    for n = 1, 4 do
        local fs = text(f, 10, "inkSoft"); fs:SetPoint("TOPLEFT", 4, -18 - (n - 1) * 13); fs:SetWidth(250)
        f.lines[n] = fs
    end
    f.perfLabel = text(f, 10, "ink"); f.perfLabel:SetPoint("TOPLEFT", 4, -72); f.perfLabel:SetWidth(90)
    f.perf = bar(f, 150, 10); f.perf:SetPoint("LEFT", f.perfLabel, "RIGHT", 2, 0)
    f.status = text(f, 10, "ink"); f.status:SetPoint("TOPLEFT", 4, -86); f.status:SetWidth(250)
    f.reqTitle = text(f, 10, "ink"); f.reqTitle:SetPoint("TOPLEFT", 262, -2); f.reqTitle:SetWidth(160)
    f.req = {}
    for n = 1, 6 do
        local fs = text(f, 10, "inkSoft"); fs:SetPoint("TOPLEFT", 262, -16 - (n - 1) * 12); fs:SetWidth(160)
        f.req[n] = fs
    end
    f.b1 = button(f, "", 80, 18, function() CU.WorkButton(1) end, function(self) return self.ssTipText or self.ssWhyText or "" end)
    f.b1:SetPoint("BOTTOMLEFT", 4, 2)
    f.b2 = button(f, "", 80, 18, function() CU.WorkButton(2) end, function(self) return self.ssTipText or self.ssWhyText or "" end)
    f.b2:SetPoint("LEFT", f.b1, "RIGHT", 4, 0)
    f.b3 = button(f, "", 80, 18, function() CU.WorkButton(3) end, function(self) return self.ssTipText or self.ssWhyText or "" end)
    f.b3:SetPoint("LEFT", f.b2, "RIGHT", 4, 0)
    CU.work = f
    return f
end

local function setButton(b, label, tip, fn, disabled)
    if not label then b:Hide(); b.fn = nil; return end
    b.label:SetText(label)
    b.ssTipText = tip
    b.fn = fn
    usable(b, not disabled, disabled)
    b:Show()
end

function CU.WorkButton(n)
    local f = CU.work
    local b = f and f["b" .. n]
    if not b or not b.fn then return end
    if b.ssWhyText then notice(b.ssWhyText); return end
    b.fn()
    UI.dirty = true
end

-- Lines describing an adult's job (used by the tab and by tests).
function CU.JobLines(w, a)
    local lv, c = SS.Career.Current(a)
    local t = SS.Career.Track(c.track)
    local out = {}
    out.title = string.format("%s  (%s, level %d of %d)", lv.title, t.name, c.level, #t.levels)
    out[1] = string.format("Salary %s per shift. %s.", money(SS.Career.Pay(w, lv)), SS.Career.ShiftText(lv))
    out[2] = string.format("Days worked %d (%s at this level). Earned %s.", c.daysWorked or 0, plural(c.shiftsAtLevel or 0, "shift"), money(c.earned or 0))
    out[3] = string.format("Vacation days %d. Warnings %d. Carpool: %s. Outfit: %s.", c.vacation or 0, c.warnings or 0, lv.carpool, (lv.outfit:gsub("_", " ")))
    local cw = c.coworker
    out[4] = cw and string.format("Coworker: %s (friendship %d).", cw.name, math.floor(cw.rel or 0)) or ""
    out.perf = c.perf
    local sh = c.shift
    if c.pending then
        local e = SS.Career.ChanceDef(c.pending.id)
        out.status = "Decision waiting at work: " .. (e and e.title or "?")
    elseif sh and sh.state == "away" then
        out.status = string.format("At work until %s (home about %s).", SS.Career.ClockText(sh.finish), SS.Career.ClockText(sh.returnAt or sh.finish))
    elseif sh and sh.state == "waiting" then
        out.status = string.format("The carpool is at the curb. It leaves at %s.", SS.Career.ClockText(sh.start))
    elseif sh then
        out.status = string.format("Next shift %s (carpool %s)%s.", clock(sh.start), SS.Career.ClockText(sh.pickupAt),
            (c.dayOff == sh.start) and ", taking it off" or "")
    else
        out.status = "No shift planned."
    end
    local ok, rows, top = SS.Career.PromotionStatus(w, a)
    if top == "top" then
        out.reqTitle = "Top of the career."
        out.req = { "Keep performance up to stay here." }
    else
        local nxt = SS.Career.LevelDef(c.track, c.level + 1)
        out.reqTitle = string.format("Next: %s (%s)", nxt.title, money(SS.Career.Pay(w, nxt)))
        out.req = {}
        for _, r in ipairs(rows) do
            out.req[#out.req + 1] = string.format("%s %s: %d / %d", r.met and "[ok]" or "[  ]", r.label, r.have, r.need)
        end
    end
    return out
end

function CU.SchoolLines(w, a)
    local s = SS.School.Record(a)
    local out = {}
    out.title = string.format("School: grade %s (%d of 100)", s.letter, math.floor(s.score + 0.5))
    local hw = s.homework
    if hw and hw.done then out[1] = "Homework: done for " .. SS.Career.DAY_NAMES[hw.forDay % 7] .. "."
    elseif hw then out[1] = string.format("Homework: due %s, %d of %d minutes done. Sit at a chair facing a desk or table.",
        SS.Career.DAY_NAMES[hw.forDay % 7], math.floor(hw.minutes or 0), SS.School.HomeworkMinutes())
    else out[1] = "Homework: none right now." end
    local b = w.household.schoolBus or {}
    if b.state == "waiting" then out[2] = "The school bus is at the curb until " .. SS.Career.ClockText(SS.CareerData.school.busAt + SS.CareerData.school.busWait) .. "."
    elseif s.trip and s.trip.state == "away" then out[2] = "At school; home about " .. SS.Career.ClockText(SS.CareerData.school.returnAt) .. "."
    elseif b.busAt then out[2] = "Next bus: " .. clock(b.busAt) .. "."
    else out[2] = "School runs Monday to Friday; the bus comes at " .. SS.Career.ClockText(SS.CareerData.school.busAt) .. "." end
    local cn = SS.CareerData.school.concern
    local worry = s.concern >= cn.referralAt and "referred to the welfare office" or s.concern >= cn.meetingAt and "meeting requested"
        or s.concern >= cn.noteAt and "a note was sent home" or s.concern > 0 and "a little worried" or "none"
    out[3] = string.format("School's concern: %s (%d). Absences: %d.", worry, s.concern, #s.absences)
    local last = s.reports[#s.reports]
    out[4] = (last and ("Last report card: " .. last.letter .. ".") or "First report card on Friday afternoon.")
        .. ((s.plan and w.time < s.plan.untilT) and " Study plan active." or "")
    out.perf = s.score
    out.status = s.aloneSince and ("Home alone since " .. SS.Career.ClockText(s.aloneSince) .. ".") or ""
    out.reqTitle = "Grades come from:"
    out.req = { "Homework done each school day", "Mood when leaving for the bus", "Not missing the bus",
        "Logic " .. SS.CareerData.school.homework.logicBonusAt .. "+ helps homework" }
    return out
end

function CU.RefreshWork(f, a, w)
    if not f or not a or not w then return end
    local out
    f.b1.fn, f.b2.fn, f.b3.fn = nil, nil, nil
    if a.career and SS.Career.Current(a) then
        out = CU.JobLines(w, a)
        local c = a.career
        f.perfLabel:SetText(string.format("Performance %d", math.floor(c.perf + 0.5)))
        f.perf:SetValue(c.perf, -100, 100, SS.CareerData.rules.promoteAt)
        local dayWhy
        if not c.shift or c.shift.state == "away" then dayWhy = "There is no shift coming up." elseif (c.vacation or 0) <= 0 then dayWhy = "No vacation days left (one every " .. SS.CareerData.rules.vacationEvery .. " shifts worked)." end
        setButton(f.b1, "Day Off", "Use a vacation day for the next shift: no pay, no penalty.", function()
            local ok, msg = SS.Career.TakeDayOff(world(), a); notice(msg)
        end, dayWhy)
        setButton(f.b2, "Quit Job", "Leave this job (skills are kept).", function()
            UI.Confirm(string.format("Quit the job as a %s?", SS.Career.Title(a) or "worker"), function()
                local ok, msg = SS.Career.Quit(world(), a); if not ok then notice(msg) end
            end)
        end, (c.shift and (c.shift.state == "away" or c.shift.state == "waiting")) and "They can quit once they are home." or nil)
        if c.pending then
            setButton(f.b3, "Decide", "A decision is waiting at work.", function() CU.ShowChance(world(), a) end)
        else
            setButton(f.b3, nil)
        end
    elseif SS.Career.SchoolAge(a) then
        out = CU.SchoolLines(w, a)
        f.perfLabel:SetText(string.format("Class score %d", math.floor(out.perf + 0.5)))
        f.perf:SetValue(out.perf, 0, 100, 55)
        local hw = a.school and a.school.homework
        setButton(f.b1, "Homework", "Sit down at a chair facing a desk or table to do homework.", function() CU.OrderHomework(world(), a) end,
            (not hw) and "No homework right now." or hw.done and "Homework is already done." or nil)
        setButton(f.b2, nil); setButton(f.b3, nil)
    else
        out = { title = SS.Career.WorkingAge(a) and "No job" or (a.name .. " is too young for a job."), perf = 0, req = {} }
        if SS.Career.WorkingAge(a) then
            out[1] = "Look for work in the newspaper (a few listings a day)"
            out[2] = "or on a computer (more listings), or call the job line."
            local past = a.careerPast and a.careerPast[#a.careerPast]
            out[3] = past and string.format("Last job: %s (%s).", past.title or "?", past.reason) or ""
            out.reqTitle = "Skills help you get better jobs."
        end
        f.perfLabel:SetText("")
        f.perf:SetValue(0, -100, 100, 0)
        local hh = w.household
        local seen = hh and hh.jobOffers and hh.jobOffers.day == math.floor(w.time / 1440)
        setButton(f.b1, "Offers", "See today's job listings the household has already found.", function()
            SS.Career.ShowOffers(world(), a, "seen")
        end, (not SS.Career.WorkingAge(a)) and "Jobs are for grown-ups." or (not seen) and "Read a newspaper or search on a computer first." or nil)
        setButton(f.b2, nil); setButton(f.b3, nil)
    end
    f.title:SetText(out.title or "")
    for n = 1, 4 do f.lines[n]:SetText(out[n] or "") end
    f.status:SetText(out.status or "")
    f.reqTitle:SetText(out.reqTitle or "")
    for n = 1, 6 do f.req[n]:SetText(out.req and out.req[n] or "") end
    f.perf:SetShown(f.perfLabel:GetText() ~= "")
    CU.lastWork = out
end

-- Send a child to the nearest chair where homework works.
function CU.OrderHomework(w, a)
    local best, bestD
    local ids = {}
    for oid in pairs(w.lot.objects) do ids[#ids + 1] = oid end
    table.sort(ids)
    for _, oid in ipairs(ids) do
        local o = w.lot.objects[oid]
        local def = SS.Objects[o.def]
        local listed = false
        for _, iid in ipairs(def and def.actions or {}) do if iid == "school_homework" then listed = true end end
        if listed and SS.Actions.Available(w, a, o, "school_homework") then
            local d = math.abs(o.x + 0.5 - a.x) + math.abs(o.y + 0.5 - a.y)
            if not bestD or d < bestD then best, bestD = oid, d end
        end
    end
    if not best then notice("There is no free chair facing a desk or table."); return false end
    SS.Actions.Order(w, a, best, "school_homework")
    return true
end

---------------------------------------------------------------------------------------------------
-- Skills tab
---------------------------------------------------------------------------------------------------
function CU.CreateSkills(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.rows = {}
    for n, sk in ipairs(SS.Skills.LIST) do
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(416, 17)
        r:SetPoint("TOPLEFT", 4, -2 - (n - 1) * 18)
        r.label = text(r, 11, "ink"); r.label:SetPoint("LEFT"); r.label:SetWidth(80); r.label:SetText(SS.Skills.Label(sk))
        r.level = text(r, 11, "ink", "RIGHT"); r.level:SetPoint("LEFT", r.label, "RIGHT", 0, 0); r.level:SetWidth(22)
        r.segs = {}
        for k = 1, 10 do
            local s = CreateFrame("Frame", nil, r)
            s:SetSize(18, 10)
            s:SetPoint("LEFT", r.level, "RIGHT", 6 + (k - 1) * 20, 0)
            s.bg = tex(s, "BACKGROUND", "barBg"); s.bg:SetAllPoints()
            s.fill = K().Tex(s, "ARTWORK", { 0.25, 0.64, 0.60, 1 }); s.fill:SetPoint("LEFT"); s.fill:SetHeight(10)
            r.segs[k] = s
        end
        r.note = text(r, 10, "inkSoft"); r.note:SetPoint("LEFT", r.segs[10], "RIGHT", 6, 0); r.note:SetWidth(100)
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(SS.Skills.Label(sk) .. ": " .. SS.CareerData.skills.help[sk], 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r.skill = sk
        f.rows[n] = r
    end
    CU.skills = f
    return f
end

function CU.RefreshSkills(f, a, w)
    if not f or not a then return end
    for _, r in ipairs(f.rows) do
        local sk = r.skill
        local lvl = SS.Skills.Level(a, sk)
        local prog = SS.Skills.Progress(a, sk)
        local cap = SS.Skills.Cap(a, sk)
        r.level:SetText(tostring(lvl))
        for k = 1, 10 do
            local s = r.segs[k]
            local frac = (k <= lvl) and 1 or (k == lvl + 1) and prog or 0
            s.fill:SetWidth(math.max(0.01, frac * 18))
            s.fill:SetShown(frac > 0)
            s:SetAlpha(k <= cap and 1 or 0.35)
        end
        if cap < SS.Skills.MAX then r.note:SetText("child cap " .. cap)
        elseif lvl >= SS.Skills.MAX then r.note:SetText("mastered")
        else r.note:SetText(string.format("%d%% to %d", math.floor(prog * 100), lvl + 1)) end
    end
end

---------------------------------------------------------------------------------------------------
-- Money tab: funds, this week, bills, sandbox
---------------------------------------------------------------------------------------------------
local E = function() return SS.Economy end

function CU.CreateMoney(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.funds = text(f, 12, "ink"); f.funds:SetPoint("TOPLEFT", 4, -2); f.funds:SetWidth(300)
    f.worth = text(f, 10, "inkSoft"); f.worth:SetPoint("TOPLEFT", 4, -18); f.worth:SetWidth(300)
    f.week = text(f, 10, "ink"); f.week:SetPoint("TOPLEFT", 4, -31); f.week:SetWidth(300)
    f.cats = text(f, 10, "inkSoft"); f.cats:SetPoint("TOPLEFT", 4, -44); f.cats:SetWidth(300)
    f.bills = {}
    for n = 1, 3 do
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(300, 18)
        r:SetPoint("TOPLEFT", 4, -60 - (n - 1) * 19)
        r.label = text(r, 10, "ink"); r.label:SetPoint("LEFT"); r.label:SetWidth(240)
        r.pay = button(r, "Pay", 50, 16, function() CU.PayBill(n) end, function(self) return self.ssTipText or self.ssWhyText or "" end)
        r.pay:SetPoint("RIGHT")
        f.bills[n] = r
    end
    f.note = text(f, 10, "warn"); f.note:SetPoint("BOTTOMLEFT", 4, 2); f.note:SetWidth(300)
    f.payAll = button(f, "Pay All Bills", 110, 18, function() CU.PayAll() end, function(self) return self.ssTipText or self.ssWhyText or "" end)
    f.payAll:SetPoint("TOPRIGHT", -4, -2)
    f.ledger = button(f, "Ledger", 110, 18, function() CU.OpenLedger() end, "Every income and expense, by category")
    f.ledger:SetPoint("TOPRIGHT", -4, -24)
    f.sandbox = button(f, "Sandbox: OFF", 110, 18, function() CU.ToggleSandbox() end,
        "Sandbox money lets you set the household's funds freely. It marks this household as a sandbox game in the ledger.")
    f.sandbox:SetPoint("TOPRIGHT", -4, -50)
    f.pressure = button(f, "Pressure: Standard", 110, 18, function() CU.CyclePressure() end, function()
        local w = world()
        local tip = { "Money pressure (difficulty for this save)" }
        local P = SS.CareerData.economy.pressure
        local cur = w and E().Pressure(w) or P.default
        for _, id in ipairs(P.order) do
            local lv = P.levels[id]
            tip[#tip + 1] = (id == cur and "> " or "  ") .. lv.label .. ": " .. lv.desc
        end
        tip[#tip + 1] = "Click to change. Applies from the next bill and the next shift."
        return table.concat(tip, "\n")
    end)
    f.pressure:SetPoint("TOPRIGHT", -4, -92)
    f.presets = {}
    for n, v in ipairs(SS.CareerData.economy.sandbox.presets) do
        local b = button(f, money(v), 36, 16, function() CU.SetSandboxFunds(v) end, "Sandbox: set funds to " .. money(v))
        b:SetPoint("TOPRIGHT", -4 - (3 - n) * 37, -72)
        f.presets[n] = b
    end
    CU.money = f
    return f
end

-- Net worth walks every object on the lot and the 7-day summary every daily row, so the Money tab
-- (refreshed several times a second while open) keeps them until money moves, the lot changes, a
-- bill event happens or an in-game hour passes (resale values depreciate by the day).
local worth = { dirty = true }
local function worthDirty() worth.dirty = true end
for _, ev in ipairs({ "money", "lotChanged", "billPaid", "repossessed", "collectionDone", "worldAttached" }) do SS.On(ev, worthDirty) end
function CU.Worth(w)
    local hour = math.floor((w.time or 0) / 60)
    if worth.dirty or worth.w ~= w or worth.hour ~= hour or worth.version ~= (w.lot and w.lot.version) or worth.money ~= w.money then
        worth.dirty, worth.w, worth.hour, worth.version, worth.money = false, w, hour, w.lot and w.lot.version, w.money
        worth.total, worth.cash, worth.home = E().NetWorth(w)
        worth.cats, worth.inc, worth.spend = E().Summary(w, 7)
        worth.computed = (worth.computed or 0) + 1
    end
    return worth
end

function CU.MoneyLines(w)
    local hh = w.household
    local out = {}
    local wv = CU.Worth(w)
    local cats, inc, spend = wv.cats, wv.inc, wv.spend
    local total, cash, home = wv.total, wv.cash, wv.home
    out.funds = "Funds: " .. money(w.money or 0) .. (E().SandboxUsed(w) and "   (sandbox game)" or "")
    out.worth = string.format("Home value %s. Net worth %s.", money(home), money(total))
    out.week = string.format("Last 7 days: +%s in, -%s out.", money(inc), money(spend))
    local parts = {}
    for _, cat in ipairs(SS.CareerData.economy.ledger.order) do
        local v = cats[cat]
        if v and v ~= 0 and #parts < 4 then parts[#parts + 1] = string.format("%s %s%s", E().CatLabel(cat), v > 0 and "+" or "-", money(math.abs(v))) end
    end
    out.cats = table.concat(parts, ", ")
    out.bills = {}
    for _, b in ipairs(E().OpenBills(w)) do
        local due
        if b.state == "posted" then due = "in the post"
        elseif w.time >= b.due then due = "OVERDUE since " .. clock(b.due)
        else due = string.format("due %s", clock(b.due)) end
        local col = E().Collection(w, b.collectionId)
        local owed = E().Owed(w, b)
        local amount = money(b.amount)
        if col and col.state ~= "cancelled" and col.state ~= "done" then
            due = "sent to the collector"
            if owed < b.amount then amount = string.format("%s (of %s; the collector covered the rest)", money(owed), money(b.amount)) end
        end
        out.bills[#out.bills + 1] = { bill = b, owed = owed, text = string.format("%s %s - %s", b.text, amount, due),
            payable = E().Payable(w, b) }
    end
    local st = E().State(hh)
    if st.arrears > 0 then out.note = "Arrears " .. money(st.arrears) .. " will be withheld from wages."
    elseif #out.bills == 0 then out.note = "No bills to pay. Bills arrive in the mailbox every " .. SS.CareerData.economy.bills.everyDays .. " days."
    else out.note = "" end
    return out
end

function CU.RefreshMoney(f, a, w)
    if not f or not w or not w.household then return end
    local out = CU.MoneyLines(w)
    f.funds:SetText(out.funds)
    f.worth:SetText(out.worth)
    f.week:SetText(out.week)
    f.cats:SetText(out.cats)
    f.billItems = out.bills
    for n, r in ipairs(f.bills) do
        local item = out.bills[n]
        if item then
            r.label:SetText(item.text)
            local why
            if not item.payable then why = item.bill.state == "posted" and "It has not arrived yet." or "The collector is dealing with it."
            elseif (w.money or 0) < (item.owed or item.bill.amount) then why = "Not enough money." end
            usable(r.pay, not why, why)
            r:Show()
        else
            r:Hide()
        end
    end
    f.note:SetText(out.note or "")
    local payable = E().PayableBills(w)
    usable(f.payAll, #payable > 0, #payable == 0 and "There are no bills to pay." or nil)
    local on = E().SandboxOn(w)
    f.sandbox.label:SetText(on and "Sandbox: ON" or "Sandbox: OFF")
    local _, pr = E().Pressure(w)
    f.pressure.label:SetText("Pressure: " .. pr.label)
    for _, b in ipairs(f.presets) do b:SetShown(on) end
end

local function payer(w)
    local a = UI.SelectedActor and UI.SelectedActor()
    if a and SS.Career.IsMember(w, a) and SS.Career.WorkingAge(a) then return a end
    return E().AnyAdult(w)
end

function CU.PayBill(n)
    local w = world()
    local f = CU.money
    local item = f and f.billItems and f.billItems[n]
    if not w or not item then return end
    local paid, total, left, why = E().PayBills(w, payer(w), item.bill.id)
    notice(paid > 0 and ("Paid " .. money(total) .. ".") or why)
    UI.dirty = true
end

function CU.PayAll()
    local w = world()
    if not w then return end
    local paid, total, left, why = E().PayBills(w, payer(w))
    notice(paid > 0 and string.format("Paid %s (%s).%s", plural(paid, "bill"), money(total), why and (" " .. why) or "") or why)
    UI.dirty = true
end

function CU.ToggleSandbox()
    local w = world()
    if not w then return end
    if E().SandboxOn(w) then
        E().SetSandbox(w, false)
        notice("Sandbox money is off. The household stays marked as a sandbox game.")
    else
        UI.Confirm("Turn on sandbox money? You can then set funds freely, and this household is marked as a sandbox game in its ledger (for good).",
            function() E().SetSandbox(w, true); notice("Sandbox money is on."); UI.dirty = true end)
    end
    UI.dirty = true
end

-- Money pressure: Relaxed -> Standard -> Tight -> Relaxed.
function CU.CyclePressure()
    local w = world()
    if not w then return end
    local P = SS.CareerData.economy.pressure
    local cur = E().Pressure(w)
    local nextId = P.order[1]
    for n, id in ipairs(P.order) do if id == cur then nextId = P.order[n % #P.order + 1] end end
    local ok, msg = E().SetPressure(w, nextId)
    notice(msg)
    UI.dirty = true
end

function CU.SetSandboxFunds(v)
    local w = world()
    if not w then return end
    local ok, msg = E().SandboxSetMoney(w, v)
    notice(msg)
    UI.dirty = true
end

---------------------------------------------------------------------------------------------------
-- Ledger window
---------------------------------------------------------------------------------------------------
CU.FILTERS = { { nil, "All" }, { "in", "Income" }, { "out", "Spending" } }
for _, cat in ipairs(SS.CareerData.economy.ledger.order) do
    CU.FILTERS[#CU.FILTERS + 1] = { cat, SS.CareerData.economy.ledger.labels[cat] }
end

local function buildLedger()
    local parent = UI.frame or UIParent
    local p = CreateFrame("Frame", nil, parent)
    p:SetFrameStrata("DIALOG")
    p:SetSize(480, 340)
    p:SetPoint("CENTER", parent, "CENTER", 0, 20)
    p:EnableMouse(true)
    p.trim = tex(p, "BACKGROUND", "trim"); p.trim:SetAllPoints()
    p.bgt = tex(p, "BORDER", "panel"); p.bgt:SetPoint("TOPLEFT", 2, -2); p.bgt:SetPoint("BOTTOMRIGHT", -2, 2)
    p.head = tex(p, "ARTWORK", "accentDeep"); p.head:SetPoint("TOPLEFT", 2, -2); p.head:SetPoint("TOPRIGHT", -2, -2); p.head:SetHeight(20)
    p.title = text(p, 12, "paper"); p.title:SetPoint("TOPLEFT", 8, -5); p.title:SetText("Household ledger")
    p.close = button(p, "x", 20, 18, function() p:Hide() end, "Close")
    p.close:SetPoint("TOPRIGHT", -3, -3)
    p.filters = {}
    for n, fl in ipairs(CU.FILTERS) do
        local col, row = (n - 1) % 7, math.floor((n - 1) / 7)
        local b = button(p, fl[2], 64, 16, function() CU.ledgerFilter = fl[1]; CU.RefreshLedger() end, "Show " .. fl[2]:lower())
        b:SetPoint("TOPLEFT", 8 + col * 66, -26 - row * 18)
        b.filter = fl[1]
        p.filters[n] = b
    end
    p.sum = text(p, 10, "ink"); p.sum:SetPoint("TOPLEFT", 8, -66); p.sum:SetWidth(460)
    p.sandbox = text(p, 10, "warn"); p.sandbox:SetPoint("TOPLEFT", 8, -80); p.sandbox:SetWidth(460)
    p.list = K().PagedList(p, 11, 20, function(r)
        r.when = text(r, 10, "inkSoft"); r.when:SetPoint("LEFT", 2, 0); r.when:SetWidth(96)
        r.what = text(r, 10, "ink"); r.what:SetPoint("LEFT", r.when, "RIGHT", 4, 0); r.what:SetWidth(250)
        r.cat = text(r, 10, "inkSoft"); r.cat:SetPoint("LEFT", r.what, "RIGHT", 4, 0); r.cat:SetWidth(46)
        r.amt = text(r, 10, "ink", "RIGHT"); r.amt:SetPoint("RIGHT", -2, 0); r.amt:SetWidth(60)
    end, function(r, e)
        r.when:SetText(clock(e.t or 0))
        r.what:SetText(e.text or "")
        r.cat:SetText(E().CatLabel(E().Cat(e.cat, e.text)))
        local amt = e.amount or 0
        r.amt:SetText((amt > 0 and "+" or amt < 0 and "-" or "") .. money(math.abs(amt)))
        setColour(r.amt, amt > 0 and "good" or amt < 0 and "warn" or "inkSoft")
    end)
    p.list.frame:SetPoint("TOPLEFT", 8, -96)
    p.list.frame:SetPoint("BOTTOMRIGHT", -8, 8)
    p:Hide()
    if UI.RegisterFloating then UI.RegisterFloating(p) end
    CU.ledgerFrame = p
    return p
end

function CU.LedgerItems(w, filter) return E().LedgerEntries(w, filter) end

function CU.RefreshLedger()
    local p = CU.ledgerFrame
    local w = world()
    if not p or not w then return end
    for _, b in ipairs(p.filters) do b:SetActive(b.filter == CU.ledgerFilter) end
    local items = CU.LedgerItems(w, CU.ledgerFilter)
    local cats, inc, spend = E().Summary(w, 7)
    local parts = {}
    for _, cat in ipairs(SS.CareerData.economy.ledger.order) do
        local v = cats[cat]
        if v and v ~= 0 then parts[#parts + 1] = string.format("%s %s%s", E().CatLabel(cat), v > 0 and "+" or "-", money(math.abs(v))) end
    end
    p.sum:SetText(string.format("Funds %s. Last 7 days +%s / -%s. %s", money(w.money or 0), money(inc), money(spend), table.concat(parts, ", ")))
    p.sandbox:SetText(E().SandboxUsed(w) and "Sandbox money has been used in this household: its fortune is not a normal game." or "")
    p.list:SetItems(items)
    CU.ledgerItems = items
end

function CU.OpenLedger(filter)
    if not UI.frame then return false end
    local p = CU.ledgerFrame or buildLedger()
    CU.ledgerFilter = filter
    p:Show()
    CU.RefreshLedger()
    return true
end

---------------------------------------------------------------------------------------------------
-- Registration: tabs, menus, help
---------------------------------------------------------------------------------------------------
UI.RegisterTab("career", { label = "Work", order = 50, tip = "Job or school: title, pay, shift, performance and what the next promotion needs",
    create = function(parent) return CU.CreateWork(parent) end,
    refresh = function(f, a, w) CU.RefreshWork(f, a, w) end })
UI.RegisterTab("skills", { label = "Skills", order = 40, tip = "The six skills (0-10), practised with the right objects",
    create = function(parent) return CU.CreateSkills(parent) end,
    refresh = function(f, a, w) CU.RefreshSkills(f, a, w) end })
UI.RegisterTab("finances", { label = "Money", order = 60, tip = "Household funds, bills, the weekly summary, the ledger and sandbox money",
    create = function(parent) return CU.CreateMoney(parent) end,
    refresh = function(f, a, w) CU.RefreshMoney(f, a, w) end })

-- The selected person, clicked: work actions.
UI.RegisterMenu("self", function(w, actor, ref, entries)
    local a = actor or (w and w.actors[ref])
    if not a or not w or not SS.Career.IsMember(w, a) then return end
    local c = a.career
    if c then
        local why
        if not c.shift or c.shift.state == "away" then why = "There is no shift coming up." elseif (c.vacation or 0) <= 0 then why = "No vacation days left." end
        entries[#entries + 1] = { label = "Take a Day Off", order = 70, disabled = why ~= nil, reason = why,
            desc = "Use a vacation day for the next shift.", onClick = function() local ok, msg = SS.Career.TakeDayOff(world(), a); notice(msg) end }
        if c.pending then
            entries[#entries + 1] = { label = "Work Decision...", order = 69, desc = "Something happened at work.", onClick = function() CU.ShowChance(world(), a) end }
        end
    elseif SS.Career.WorkingAge(a) then
        local seen = w.household.jobOffers and w.household.jobOffers.day == math.floor(w.time / 1440)
        entries[#entries + 1] = { label = "Today's Job Offers", order = 70, disabled = not seen,
            reason = "Read a newspaper or search on a computer first.", onClick = function() SS.Career.ShowOffers(world(), a, "seen") end }
    elseif SS.Career.SchoolAge(a) and a.school and a.school.homework and not a.school.homework.done then
        entries[#entries + 1] = { label = "Do Homework", order = 70, onClick = function() CU.OrderHomework(world(), a) end }
    end
end)

-- Another person clicked: meet the counselor, help with homework.
UI.RegisterMenu("actor", function(w, actor, ref, entries)
    local target = w and w.actors[ref]
    if not target or not actor then return end
    for _, iid in ipairs({ "school_meet", "school_help" }) do
        local ia = SS.Interactions[iid]
        local relevant = (iid == "school_meet" and target.role == "counselor") or (iid == "school_help" and SS.Career.SchoolAge(target) and SS.Career.IsMember(w, target))
        if relevant then
            local ok, why = SS.Actions.Available(w, actor, target, iid)
            entries[#entries + 1] = { label = ia.label, order = 30, disabled = not ok, reason = why,
                onClick = function() SS.Actions.Order(world(), actor, nil, iid, nil, nil, { tid = target.id }) end }
        end
    end
end)

if UI.RegisterHelp then
    UI.RegisterHelp("careers", { title = "Work, school and money", order = 55, lines = {
        "Find a job with a newspaper or a computer (Look for a Job), or call the job line on the phone.",
        "The carpool comes an hour before each shift. Workers change and walk to the curb; pay arrives when they get home.",
        "Someone eating when the carpool or the school bus arrives finishes the meal first, as long as they can still leave on time.",
        "A day of six hours or more at work or school includes a lunch break, so hunger recovers a little halfway through; children still come home ready for a snack.",
        "Missing the carpool gets a warning, then a demotion, then the sack. Being late costs performance.",
        "Performance comes from mood when leaving, skills for the next job and friends. The Work tab shows what a promotion needs.",
        "Children take the school bus on weekdays. Homework at a chair facing a desk or table keeps grades up; report cards come on Fridays.",
        "Bills come every three days in the mailbox. Unpaid bills bring warnings, a final notice and then the bill collector.",
        "The Money tab shows funds, bills and the ledger. Sandbox money is an option there and marks the household as sandbox.",
        "Money pressure on the Money tab (Relaxed, Standard, Tight) makes bills and wages easier or harder for this save.",
    } })
end
