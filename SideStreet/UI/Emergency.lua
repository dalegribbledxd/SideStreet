-- SideStreet emergency and arrival banners.
--
-- Every SS.Sim.Emergency(world, text, severity) call (fire, collapse, burglary, an important
-- arrival) reaches the `emergency` bus event. The simulation already drops fast speeds to
-- normal; this file makes sure of it, optionally pauses (Options > Game), and shows a banner at
-- the top of the lot that says what happened in words and symbols, not colour alone:
--   info       "i  ARRIVAL"     teal,  fades after a few seconds
--   warning    "!  WARNING"     amber, stays a little longer
--   emergency  "!! EMERGENCY"   red,   stays until dismissed or the danger is over
-- Banners are pooled (at most E.CAP shown), identical messages merge with a count, and the
-- emergency banner's border only pulses when reduced motion/flashes is off. Audio precedence is
-- handled by the audio director, which listens to the same event.
local _, SS = ...
local UI = SS.UI
local K = UI.Kit
local E = UI.Emergency or {}
UI.Emergency = E

E.CAP = 3                 -- banners on screen at once
E.QUEUE_CAP = 8           -- waiting banners (older ones drop)
E.HISTORY_CAP = 20        -- recent alerts kept for diagnostics
E.HOLD = { info = 6, warning = 12, emergency = 45 }   -- real seconds before a banner retires
E.STYLE = {
    info = { glyph = "i", word = "ARRIVAL", colour = "accent" },
    warning = { glyph = "!", word = "WARNING", colour = "sun" },
    emergency = { glyph = "!!", word = "EMERGENCY", colour = "danger" },
}
E.active = E.active or {}     -- { text, severity, ref, count, t, untilT }
E.queue = E.queue or {}
E.history = E.history or {}

local function now() return (GetTime and GetTime()) or 0 end
local function world() return SS.Sim.world end

-- Who or where an alert is about: an explicit ref (actor id, object id or {x, y, level}), else
-- a resident of this lot named in the text (first match in sorted id order).
function E.ResolveRef(w, text, ref)
    if not w then return nil end
    if type(ref) == "table" and type(ref.x) == "number" then return ref end
    if type(ref) == "string" then
        local a = w.actors[ref]
        if a then return { x = a.x, y = a.y, level = a.level or 0, actor = ref } end
        local o = w.lot.objects[ref]
        if o then return { x = o.x + 0.5, y = o.y + 0.5, level = o.level or 0, obj = ref } end
    end
    if type(text) == "string" then
        for _, id in ipairs(SS.Sim.ActorIds(w)) do
            local a = w.actors[id]
            if a.name and a.name ~= "" and text:find(a.name, 1, true) then
                return { x = a.x, y = a.y, level = a.level or 0, actor = id }
            end
        end
        -- first names too ("Roz is nearby"), when unambiguous (the journal's name matcher)
        if SS.Journal and SS.Journal.FindNames then
            for _, id in ipairs(SS.Journal.FindNames(w, text)) do
                local a = w.actors[id]
                if a then return { x = a.x, y = a.y, level = a.level or 0, actor = id } end
            end
        end
    end
    return nil
end

function E.Push(text, severity, ref)
    if type(text) ~= "string" or text == "" then return end
    severity = E.STYLE[severity] and severity or "emergency"
    local t = now()
    local h = E.history
    h[#h + 1] = { text = text, severity = severity, t = t, gameT = world() and world().time }
    while #h > E.HISTORY_CAP do table.remove(h, 1) end
    for _, list in ipairs({ E.active, E.queue }) do
        for _, b in ipairs(list) do
            if b.text == text then
                b.count = (b.count or 1) + 1
                b.untilT = t + (E.HOLD[severity] or 10)
                b.ref = E.ResolveRef(world(), text, ref) or b.ref
                E.Render()
                return b
            end
        end
    end
    local b = { text = text, severity = severity, ref = E.ResolveRef(world(), text, ref), count = 1, t = t,
        untilT = t + (E.HOLD[severity] or 10) }
    local q = E.queue
    q[#q + 1] = b
    while #q > E.QUEUE_CAP do table.remove(q, 1) end
    E.Pump()
    return b
end

-- Move queued banners into free slots; emergencies jump the queue.
function E.Pump()
    local q, act = E.queue, E.active
    table.sort(q, function(a, b)
        local pa, pb = a.severity == "emergency" and 0 or 1, b.severity == "emergency" and 0 or 1
        if pa ~= pb then return pa < pb end
        return a.t < b.t
    end)
    while #act < E.CAP and #q > 0 do act[#act + 1] = table.remove(q, 1) end
    -- an emergency waiting behind calmer banners replaces the oldest calm one
    if #q > 0 and q[1].severity == "emergency" then
        for n = #act, 1, -1 do
            if act[n].severity ~= "emergency" then
                table.remove(act, n)
                act[#act + 1] = table.remove(q, 1)
                break
            end
        end
    end
    E.Render()
end

function E.Dismiss(n)
    local b = E.active[n]
    if not b then return end
    table.remove(E.active, n)
    E.Pump()
end

function E.Clear()
    for n = #E.active, 1, -1 do E.active[n] = nil end
    for n = #E.queue, 1, -1 do E.queue[n] = nil end
    E.Render()
end

-- Emergencies stay while a fire is burning on the lot.
local function stillDangerous(b)
    if b.severity ~= "emergency" then return false end
    local w = world()
    if not w or not (SS.Fire and SS.Fire.Active) then return false end
    local ok, active = pcall(SS.Fire.Active, w)
    return ok and active and true or false
end

-- Real-time upkeep (called every client frame by UI/Main.lua while the window is open).
function E.Update(el)
    local act = E.active
    if #act == 0 then return end
    local t = now()
    local changed = false
    for n = #act, 1, -1 do
        local b = act[n]
        if b.untilT <= t then
            if stillDangerous(b) then b.untilT = t + 5 else table.remove(act, n); changed = true end
        end
    end
    if changed then E.Pump() end
    -- pulse the emergency border (never when reduced motion/flashes is on)
    local rows = E.rows
    if not rows then return end
    local pulse = not UI.Pref("reducedMotion")
    for n, row in ipairs(rows) do
        local b = act[n]
        if b and row:IsShown() and b.severity == "emergency" then
            local a = pulse and (0.55 + 0.45 * math.abs(math.sin(t * 3))) or 1
            row.edge:SetAlpha(a)
        elseif row:IsShown() then
            row.edge:SetAlpha(1)
        end
    end
end

---------------------------------------------------------------------------
-- Frames (pooled rows, created with the window)
---------------------------------------------------------------------------
function E.Create(f)
    if E.frame then return end
    local holder = CreateFrame("Frame", nil, UI.viewport)
    holder:SetFrameStrata("DIALOG"); holder:SetFrameLevel(40)
    holder:SetPoint("TOPLEFT", UI.viewport, "TOPLEFT", 50, -74)
    holder:SetPoint("TOPRIGHT", UI.viewport, "TOPRIGHT", -50, -74)
    holder:SetHeight(E.CAP * 34)
    E.frame = holder
    E.rows = {}
    for n = 1, E.CAP do
        local row = CreateFrame("Frame", nil, holder)
        row:SetHeight(30)
        row:SetPoint("TOPLEFT", 0, -(n - 1) * 34); row:SetPoint("TOPRIGHT", 0, -(n - 1) * 34)
        row.edge = K.Tex(row, "BACKGROUND", "danger"); row.edge:SetAllPoints()
        row.bg = K.Tex(row, "BORDER", "dark"); row.bg:SetPoint("TOPLEFT", 3, -3); row.bg:SetPoint("BOTTOMRIGHT", -3, 3)
        row.glyph = K.Text(row, 14, "sun", "CENTER"); row.glyph:SetPoint("LEFT", 8, 0); row.glyph:SetWidth(22)
        row.icon = row:CreateTexture(nil, "OVERLAY"); row.icon:SetPoint("CENTER", row.glyph, "CENTER", 0, 0); row.icon:Hide()
        row.word = K.Text(row, 10, "sun", "LEFT"); row.word:SetPoint("LEFT", row.glyph, "RIGHT", 4, 0); row.word:SetWidth(72)
        row.text = K.Text(row, 12, "paper", "LEFT"); row.text:SetPoint("LEFT", row.word, "RIGHT", 4, 0); row.text:SetPoint("RIGHT", -150, 0)
        row.close = K.Button(row, "x", 22, 20, function() E.Dismiss(n) end, "Dismiss this message")
        row.close:SetPoint("RIGHT", -6, 0)
        row.pause = K.Button(row, "Pause", 50, 20, function() UI.RequestSpeed(nil); E.Render() end, function()
            local w = world()
            return (w and w.speed == 0) and "Resume the game (Space)" or "Pause the game (Space)"
        end)
        row.pause:SetPoint("RIGHT", row.close, "LEFT", -4, 0)
        row.show = K.Button(row, "Show", 50, 20, function() E.ShowRef(n) end, "Centre the view on who or where this is about")
        row.show:SetPoint("RIGHT", row.pause, "LEFT", -4, 0)
        row:Hide()
        E.rows[n] = row
    end
    E.Render()
end

function E.ShowRef(n)
    local b = E.active[n]
    local ref = b and b.ref
    if not ref then UI.Notice("This message is not tied to a place on the lot."); return end
    local w = world()
    -- follow a person to where they are now
    if ref.actor and w and w.actors[ref.actor] then
        local a = w.actors[ref.actor]
        ref.x, ref.y, ref.level = a.x, a.y, a.level or 0
    end
    if UI.CenterOn then UI.CenterOn(ref.x, ref.y, ref.level) end
end

function E.Render()
    local rows = E.rows
    if not rows then return end
    local w = world()
    for n, row in ipairs(rows) do
        local b = E.active[n]
        if b then
            local st = E.STYLE[b.severity]
            local c = K.C(st.colour)
            row.edge:SetColorTexture(c[1], c[2], c[3], 1)
            row.glyph:SetText(st.glyph)
            K.IconOrGlyph(row.icon, row.glyph, "banner_" .. b.severity, 20)
            row.word:SetText(st.word)
            row.text:SetText(b.text .. ((b.count or 1) > 1 and ("  (x" .. b.count .. ")") or ""))
            row.show:SetShown(b.ref ~= nil)
            row.pause:SetLabel((w and w.speed == 0) and "Resume" or "Pause")
            row:Show()
        else
            row:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Bus hooks
---------------------------------------------------------------------------
SS.On("emergency", function(text, severity, w, ref)
    w = w or world()
    severity = severity or "emergency"
    if w and w == world() then
        -- the simulation drops fast speeds already; make sure, and pause if the player asked to.
        -- In a mode that keeps the house paused (build, buy) the speed it will resume at drops too.
        if w.speed and w.speed > 1 then SS.Sim.SetSpeed(1) end
        if UI.CurrentMode and UI.CurrentMode().pausesSim and (UI.resumeSpeed or 0) > 1 then UI.resumeSpeed = 1 end
        if severity == "emergency" and UI.Pref("pauseOnEmergency") and w.speed ~= 0 then
            SS.Sim.SetSpeed(0)
            UI.Notice("Paused for the emergency (Options > Game). Space resumes.", "warn")
        end
    end
    E.Push(text, severity, ref)
end)

SS.On("worldAttached", function() E.Clear() end)
SS.On("uiTheme", function() E.Render() end)
SS.On("speed", function() if E.rows then E.Render() end end)

if UI.OnCreate then UI.OnCreate(function(f) E.Create(f) end) end
if UI.OnEveryFrame then UI.OnEveryFrame(function(el) E.Update(el) end) end
