-- SideStreet autonomy inspector ("Why?"): what the selected person is doing and why.
--
-- Reads only runtime data the executor already keeps (nothing is saved or changed):
--   actor.act / actor.queue                       current and queued actions
--   actor.lastThink = { {oid|tid, iid, s, ok, wait, reason, why, label}..., t, chosen, routeFails }
--                                                 the last free-will decision (top candidates with
--                                                 scores, availability reasons and score breakdown)
--   actor.tmp.routeFails / actor.cool             recent route failures and retry cooldowns
--   actor.tmp.coolWhy["oid:iid"]                  why a rested offer failed (shown with its cooldown)
--   actionEnded(actor, act, "failed", why)        failures seen while the window was open
-- Older executors that only store a sorted candidate list are shown too (without reasons).
local _, SS = ...
local UI = SS.UI
local K = UI.Kit
local T = SS.Tuning
local I = UI.Inspector or {}
UI.Inspector = I

I.ROWS = 8
I.FAIL_CAP = 6
I.fails = {}          -- [actorId] = { {t, iid, oid, tid, why}... } (runtime only, bounded)

local function world() return SS.Sim.world end

SS.On("actionEnded", function(actor, act, status, why)
    if status ~= "failed" or type(actor) ~= "table" or not actor.id or type(act) ~= "table" then return end
    local w = world()
    local list = I.fails[actor.id]
    if not list then list = {}; I.fails[actor.id] = list end
    list[#list + 1] = { t = w and w.time or 0, iid = act.iid, oid = act.oid, tid = act.tid, why = why, route = act.routeFailed and true or nil }
    while #list > I.FAIL_CAP do table.remove(list, 1) end
end)
SS.On("worldAttached", function() I.fails = {} end)
SS.On("actorRemoved", function(_, a) if a and a.id then I.fails[a.id] = nil end end)

function I.Label(iid)
    local ia = SS.Interactions and SS.Interactions[iid]
    if iid == "goto" then return "Go Here" end
    return ia and ia.label or tostring(iid)
end

-- "the Fridge", "Roz", "here"
function I.TargetName(w, c)
    if c.oid then
        local o = w.lot.objects[c.oid]
        local d = o and SS.Objects[o.def]
        return d and d.name or tostring(c.oid)
    end
    if c.tid then
        local a = w.actors[c.tid] or (w.root.residents and w.root.residents[c.tid])
        return a and a.name or tostring(c.tid)
    end
    return "here"
end

local function mins(v) return string.format("%d min", math.max(0, math.floor(v + 0.5))) end

-- Candidate rows for the panel: { rank, label, target, score, status, why, chosen }
function I.Candidates(w, a)
    local lt = a.lastThink
    local out = {}
    if type(lt) ~= "table" then return out end
    local chosen = lt.chosen
    for n, c in ipairs(lt) do
        if type(c) == "table" and c.iid then
            local status
            if chosen == c then status = "chosen"
            elseif c.ok == false then status = "no: " .. tostring(c.reason or "not available")
            elseif c.wait then status = "would wait: " .. tostring(c.reason or "in use")
            elseif c.ok then status = "possible"
            else status = n == 1 and not chosen and "chosen" or "not checked" end
            if not chosen and n == 1 and c.ok == nil then chosen = c end
            out[#out + 1] = { rank = n, label = c.label or I.Label(c.iid), target = I.TargetName(w, c), score = c.s or 0,
                status = status, why = c.why, chosen = (chosen == c) }
        end
    end
    return out
end

function I.Failures(w, a)
    local out, seen = {}, {}
    local function add(list)
        for _, f in ipairs(list or {}) do
            local key = tostring(f.t) .. tostring(f.iid)
            if not seen[key] then seen[key] = true; out[#out + 1] = f end
        end
    end
    local lt = type(a.lastThink) == "table" and a.lastThink
    add(lt and lt.routeFails)
    add(a.tmp and a.tmp.routeFails)
    add(I.fails[a.id])
    table.sort(out, function(x, y) return (x.t or 0) > (y.t or 0) end)
    for n = #out, 5, -1 do out[n] = nil end
    return out
end

function I.Cooldowns(w, a)
    local out = {}
    local whyOf = type(a.tmp) == "table" and type(a.tmp.coolWhy) == "table" and a.tmp.coolWhy or nil
    for key, untilT in pairs(a.cool or {}) do
        if type(untilT) == "number" and untilT > w.time then
            local oid, iid = tostring(key):match("^(.-):(.+)$")
            if iid then
                local why = whyOf and whyOf[key]
                out[#out + 1] = { label = I.Label(iid), target = I.TargetName(w, { oid = w.lot.objects[oid] and oid or nil, tid = w.actors[oid] and oid or nil }),
                    left = untilT - w.time, why = type(why) == "string" and why or nil }
            end
        end
    end
    table.sort(out, function(x, y) if x.left ~= y.left then return x.left < y.left end return x.label < y.label end)
    return out
end

-- Why nothing was decided (plain words).
function I.NoDecisionReason(w, a)
    if a.role then return "Visitors and staff follow their role's script (" .. tostring(a.role) .. "); their own choices appear here when they make any." end
    if not w.settings.freeWill then return "Free Will is off: this person only does what you order." end
    if a.act and a.act.manual then return "Busy with your order; free will waits until the queue is empty." end
    if a.queue and #a.queue > 0 then return "Has queued actions; decides again when the queue is empty." end
    return "Has not decided anything since this lot opened."
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
function I.Create()
    if I.frame then return I.frame end
    local p = K.Panel(UI.frame, "Why?", 480, 440, { close = true, movable = true, strata = "DIALOG", level = 72 })
    p:SetPoint("TOPRIGHT", UI.frame, "TOPRIGHT", -20, -70)
    I.frame = p
    local b = p.body
    p.state = K.Text(b, 11, "ink"); p.state:SetPoint("TOPLEFT"); p.state:SetPoint("TOPRIGHT")
    p.doing = K.Text(b, 10, "ink"); p.doing:SetPoint("TOPLEFT", 0, -16); p.doing:SetPoint("TOPRIGHT", 0, -16)
    p.queue = K.Text(b, 10, "inkSoft"); p.queue:SetPoint("TOPLEFT", 0, -30); p.queue:SetPoint("TOPRIGHT", 0, -30)
    p.decision = K.Text(b, 11, "accentDeep"); p.decision:SetPoint("TOPLEFT", 0, -48); p.decision:SetPoint("TOPRIGHT", 0, -48)
    -- column heads
    local heads = K.Text(b, 9, "inkSoft"); heads:SetPoint("TOPLEFT", 0, -64)
    heads:SetText("#   action and target                                   score    result")
    p.rows = {}
    for n = 1, I.ROWS do
        local r = CreateFrame("Button", nil, b)
        r:SetHeight(26)
        r:SetPoint("TOPLEFT", 0, -76 - (n - 1) * 27); r:SetPoint("TOPRIGHT", 0, -76 - (n - 1) * 27)
        r.bg = K.Tex(r, "BACKGROUND", "panelDark"); r.bg:SetAllPoints(); r.bg:SetAlpha(n % 2 == 0 and 0.5 or 0.2)
        r.rank = K.Text(r, 10, "inkSoft"); r.rank:SetPoint("TOPLEFT", 2, -2); r.rank:SetWidth(16)
        r.what = K.Text(r, 10, "ink"); r.what:SetPoint("TOPLEFT", 20, -2); r.what:SetWidth(270)
        r.score = K.Text(r, 10, "ink", "RIGHT"); r.score:SetPoint("TOPLEFT", 292, -2); r.score:SetWidth(40)
        r.status = K.Text(r, 9, "inkSoft"); r.status:SetPoint("TOPLEFT", 338, -2); r.status:SetPoint("RIGHT", -2, 0)
        r.why = K.Text(r, 9, "inkSoft"); r.why:SetPoint("TOPLEFT", 20, -14); r.why:SetPoint("RIGHT", -2, 0)
        K.Tooltip(r, function(self)
            local c = self.cand
            if not c then return nil end
            local tip = { c.label .. " (" .. c.target .. ")", string.format("Score %.1f: %s", c.score, c.status) }
            if c.why then tip[#tip + 1] = "Why: " .. c.why end
            tip[#tip + 1] = "Scores add up what each need would gain, weighted by how low that need is (urgency grows with the square of the shortfall), then adjust for distance, personality, interests, repetition and cost."
            return tip
        end)
        r:Hide()
        p.rows[n] = r
    end
    local y = -76 - I.ROWS * 27 - 4
    p.failHead = K.Text(b, 11, "accentDeep"); p.failHead:SetPoint("TOPLEFT", 0, y)
    p.fails = K.Text(b, 10, "ink"); p.fails:SetPoint("TOPLEFT", 0, y - 14); p.fails:SetPoint("RIGHT", 0, 0); p.fails:SetJustifyV("TOP")
    p.cool = K.Text(b, 9, "inkSoft"); p.cool:SetPoint("BOTTOMLEFT", 0, 0); p.cool:SetPoint("BOTTOMRIGHT", 0, 0)
    UI.RegisterFloating(p)
    p:Hide()
    return p
end

function I.Refresh()
    local p = I.frame
    if not p or not p:IsShown() then return end
    local w = world()
    local a = UI.SelectedActor and UI.SelectedActor()
    if not w or not a then
        p.title:SetText("Why?")
        p.state:SetText("Select a person to see how they decide what to do.")
        p.doing:SetText(""); p.queue:SetText(""); p.decision:SetText(""); p.failHead:SetText(""); p.fails:SetText(""); p.cool:SetText("")
        for _, r in ipairs(p.rows) do r:Hide() end
        return
    end
    p.title:SetText("Why? " .. a.name)
    local next = a.nextThink and (a.nextThink - w.time) or nil
    local worst, wv = SS.Needs.Worst(a)
    p.state:SetText(string.format("Free Will %s.  Lowest need: %s %d.%s", w.settings.freeWill and "on" or "off",
        worst and T.needLabel[worst] or "-", math.floor(wv or 0), (next and next > 0) and ("  Next free-will check in " .. mins(next) .. ".") or ""))
    local act = a.act
    if act then
        local tgt = I.TargetName(w, { oid = act.oid, tid = act.tid })
        p.doing:SetText("Doing: " .. (UI.ActLabel and UI.ActLabel(act) or I.Label(act.iid)) .. (tgt ~= "here" and (" (" .. tgt .. ")") or "")
            .. "  - " .. (act.manual and "your order" or "their own choice") .. (act.phase and ("; " .. act.phase) or ""))
    else
        p.doing:SetText("Doing: nothing right now.")
    end
    local q = {}
    for n, o in ipairs(a.queue or {}) do
        if n > 3 then q[#q + 1] = "+" .. (#a.queue - 3) .. " more"; break end
        q[#q + 1] = (UI.OrderLabel and UI.OrderLabel(o)) or I.Label(o.iid)
    end
    p.queue:SetText(#q > 0 and ("Queued: " .. table.concat(q, ", ")) or "Queue empty.")
    local cands = I.Candidates(w, a)
    local lt = a.lastThink
    if #cands == 0 then
        p.decision:SetText(I.NoDecisionReason(w, a))
    else
        local ch
        for _, c in ipairs(cands) do if c.chosen then ch = c end end
        local when = type(lt) == "table" and lt.t and UI.ClockText(lt.t) or "earlier"
        p.decision:SetText("Last decision (" .. when .. "): " .. (ch and (ch.label .. " at " .. ch.target) or "nothing was possible"))
    end
    for n, r in ipairs(p.rows) do
        local c = cands[n]
        r.cand = c
        if c then
            r.rank:SetText(tostring(c.rank))
            r.what:SetText((c.chosen and "> " or "") .. c.label .. "  -  " .. c.target)
            r.score:SetText(string.format("%.1f", c.score))
            r.status:SetText(c.status)
            K.SetTextColor(r.status, c.chosen and "good" or (c.status:find("^no") and "warn" or "inkSoft"))
            r.why:SetText(c.why or "")
            r:Show()
        else
            r:Hide()
        end
    end
    local fails = I.Failures(w, a)
    p.failHead:SetText(#fails > 0 and "Recent failures" or "No recent failures")
    local fl = {}
    for _, f in ipairs(fails) do
        local tgt = I.TargetName(w, f)
        fl[#fl + 1] = string.format("%s  %s%s: %s", UI.ClockText(f.t or 0):match("^%S+ (%S+ %S+)") or "", I.Label(f.iid),
            tgt ~= "here" and (" (" .. tgt .. ")") or "", tostring(f.why or (f.route and "no route" or "failed")))
    end
    p.fails:SetText(table.concat(fl, "\n"))
    local cd = I.Cooldowns(w, a)
    if #cd > 0 then
        local parts = {}
        for n = 1, math.min(3, #cd) do
            parts[#parts + 1] = cd[n].label .. " (" .. cd[n].target .. ") in " .. mins(cd[n].left) .. (cd[n].why and (", because " .. cd[n].why) or "")
        end
        p.cool:SetText("Won't retry yet: " .. table.concat(parts, "; ") .. (#cd > 3 and (" and " .. (#cd - 3) .. " more") or ""))
    else
        p.cool:SetText("")
    end
end

function UI.ToggleInspector()
    local p = I.Create()
    if p:IsShown() then p:Hide(); return end
    p:Show()
    I.Refresh()
end

local acc = 0
if UI.OnEveryFrame then
    UI.OnEveryFrame(function(el)
        if not I.frame or not I.frame:IsShown() then return end
        acc = acc + el
        if acc >= 0.5 then acc = 0; I.Refresh() end
    end)
end
SS.On("selected", function() if I.frame and I.frame:IsShown() then I.Refresh() end end)
