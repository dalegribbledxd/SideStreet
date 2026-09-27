-- SideStreet main window: title bar, control bar (speed, clock, funds, modes), camera strip,
-- lot viewport, household control panel (portraits, selected person, tabs, action queue),
-- context menus, captions, notices, clean view, help and the keybinding reference.
-- Opens only on explicit user action; hides (and pauses, and goes silent) when combat starts.
local _, SS = ...
local T, U = SS.Tuning, SS.U
local UI = SS.UI
local K = UI.Kit
local tex, text, button = K.Tex, K.Text, K.Button
UI.Button = button
UI.selected = nil
UI.mode = "live"

UI.TITLE_H, UI.BAR_H, UI.PANEL_H, UI.PANEL_MIN_H = 24, 32, 158, 30
UI.MAX_PORTRAITS = 8
UI.CAPTION_CAP = 8
UI.MENU_ROWS = 16
UI.WEEKDAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
UI.floating = {}     -- floating panels Esc can close (options, journal, inspector, help, ...)

local function now() return (GetTime and GetTime()) or 0 end
local function world() return SS.Sim.world end

---------------------------------------------------------------------------
-- Formatting helpers
---------------------------------------------------------------------------
function UI.Money(v)
    if type(v) ~= "number" then return "-" end
    local neg = v < 0
    local s = tostring(math.floor(math.abs(v)))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (neg and "-" or "") .. "\194\167" .. out
end

function UI.ClockText(t)
    if type(t) ~= "number" then return "" end
    local day = math.floor(t / 1440)
    local m = math.floor(t % 1440)
    local h, mm = math.floor(m / 60), m % 60
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%s %d:%02d %s  Day %d", UI.WEEKDAYS[day % 7 + 1], h12, mm, h < 12 and "AM" or "PM", day + 1)
end

function UI.SpeedLabel(level)
    if level == 0 then return "II" end
    local base = T.speeds[1] or 1
    return string.format("%gx", (T.speeds[level] or 0) / base)
end

function UI.MoodWord(mood)
    return mood > 40 and "Cheerful" or mood > 10 and "Content" or mood > -20 and "Grumpy" or mood > -50 and "Miserable" or "Desperate"
end

-- A shape to go with the mood colour (never colour alone).
function UI.MoodGlyph(mood)
    return mood > 40 and "++" or mood > 10 and "+" or mood > -20 and "o" or mood > -50 and "-" or "!!"
end

function UI.MoodColour(mood)
    if mood > 40 then return 0.36, 0.72, 0.34 elseif mood > 10 then return 0.64, 0.78, 0.30
    elseif mood > -20 then return 0.95, 0.76, 0.28 elseif mood > -50 then return 0.92, 0.48, 0.22 end
    return 0.85, 0.20, 0.18
end

---------------------------------------------------------------------------
-- Modes
---------------------------------------------------------------------------
UI.liveMode = UI.liveMode or { name = "live", label = "Live", order = 0, key = "F1", audio = "live",
    tip = "Live mode: look after the household (F1)" }

function UI.CurrentMode() return UI.mode == "live" and UI.liveMode or UI.modes[UI.mode] or UI.liveMode end

function UI.ModeList()
    local list = { UI.liveMode }
    for _, m in pairs(UI.modes) do list[#list + 1] = m end
    table.sort(list, function(a, b) if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) < (b.order or 50) end return a.name < b.name end)
    return list
end

function UI.SetMode(name)
    local w = world()
    if not UI.frame or name == UI.mode then return end
    local new = name == "live" and UI.liveMode or UI.modes[name]
    if not new then return end
    if new.canEnter then
        local ok, why = new.canEnter(w)
        if not ok then UI.Notice(why or "Not available right now.", "warn"); return end
    end
    local old = UI.CurrentMode()
    if old.exit then old.exit(w) end
    if old.frame then old.frame:Hide() end
    -- a mode that pauses the household (pausesSim: build, buy, ...) remembers the speed and
    -- gives it back on leaving; the speed is restored only once the new mode is current, so the
    -- speed hold below never mistakes the restore for a change made inside the pausing mode
    local resume
    if old.pausesSim and not new.pausesSim then
        resume = UI.resumeSpeed; UI.resumeSpeed = nil
    elseif new.pausesSim and not old.pausesSim and w then
        UI.resumeSpeed = w.speed
        SS.Sim.SetSpeed(0)
    end
    if new ~= UI.liveMode and not new.frame and new.create then
        new.frame = new.create(new.fullscreen and UI.content or UI.panel)
    end
    UI.mode = name
    if resume and w and SS.Sim.world == w then SS.Sim.SetSpeed(resume) end
    UI.HideMenu()
    if UI.TitleUp and UI.TitleUp() and UI.HideTitle then UI.HideTitle(true) end
    UI.ApplyLayout()
    if new.frame then new.frame:Show() end
    if new.enter then new.enter(w) end
    for n, b in pairs(UI.modeBtns or {}) do b:SetActive(n == name) end
    SS.Audio.SetMode(new.audio or name)
    UI.dirty = true
    UI.ModeHint(new)
    SS.Emit("uiMode", name)
end

-- The player's speed controls: the bar's speed buttons, the keys (Space, 0, 1, 2, 3), the banners'
-- Pause button and /sidestreet pause. level nil toggles pause. Inside a mode that keeps the
-- household paused (pausesSim: build, buy, ...) time never runs: the choice becomes the speed the
-- house resumes at when the player leaves that mode, and a notice says so. Returns true when the
-- simulation's speed actually changed.
function UI.RequestSpeed(level)
    local w = world()
    if not w then return false end
    local mode = UI.CurrentMode()
    if mode.pausesSim then
        local cur = UI.resumeSpeed or w.lastSpeed or 1
        if level == nil then level = (cur == 0) and (w.lastSpeed or 1) or 0 end
        if not T.speeds[level] then return false end
        UI.resumeSpeed = level
        UI.Notice(string.format("%s mode keeps the house paused. %s", mode.label or "This",
            level == 0 and "It stays paused when you leave." or ("It resumes at " .. UI.SpeedLabel(level) .. " when you leave (Esc or F1).")))
        UI.RefreshToolbar()
        return false
    end
    if level == nil then SS.Sim.TogglePause() else SS.Sim.SetSpeed(level) end
    return true
end

-- The speed hold: while a pausing mode is current, any speed change (another module, a debug
-- call) is caught at once and kept for later, so the household never runs for even one frame.
UI.holdingSpeed = false
SS.On("speed", function(level)
    if UI.holdingSpeed or not level or level == 0 or not UI.CurrentMode().pausesSim then return end
    local w = world()
    if not w or w.speed == 0 then return end
    UI.resumeSpeed = level
    UI.holdingSpeed = true
    SS.Sim.SetSpeed(0)
    UI.holdingSpeed = false
end)

-- The first visit to each mode shows its one-line help (Options > Display > Hints).
function UI.ModeHint(m)
    if not UI.Pref("showHints") or m == UI.liveMode then return end
    local db = SS.Save.DB()
    db.ui.seenModes = type(db.ui.seenModes) == "table" and db.ui.seenModes or {}
    if db.ui.seenModes[m.name] then return end
    db.ui.seenModes[m.name] = true
    local line = (m.help and m.help[1]) or m.tip
    if line and line ~= "" then UI.Notice(line .. "  (H: help and keys)") end
end

function UI.Select(id)
    UI.selected = id
    local w = world()
    local a = w and id and w.actors[id]
    if a and a.householdId then
        local db = SS.Save.DB()
        db.ui.lastSel = type(db.ui.lastSel) == "table" and db.ui.lastSel or {}
        db.ui.lastSel[a.householdId] = id
    end
    UI.RefreshPortrait()
    UI.RefreshPortraits()
    SS.Emit("selected", id)
end

function UI.SelectedActor()
    local w = world()
    return w and UI.selected and w.actors[UI.selected]
end

-- Household members in household order (on this lot or away), capped at 8 portraits.
-- out: an array to fill and return instead of a new one (the portrait row reuses one).
function UI.Members(out)
    local w = world()
    if out then for n = #out, 1, -1 do out[n] = nil end else out = {} end
    local hh = w and w.household
    if not hh then return out end
    for _, rid in ipairs(hh.members or {}) do
        local r = w.root.residents[rid]
        if r and not r.dead and #out < UI.MAX_PORTRAITS then out[#out + 1] = r end
    end
    return out
end

-- Pick the selection for a freshly attached world: remembered person, else the first member here.
function UI.RestoreSelection()
    local w = world()
    UI.selected = nil
    if not w then return end
    local db = SS.Save.DB()
    local hh = w.household
    local rem = hh and type(db.ui.lastSel) == "table" and db.ui.lastSel[hh.id]
    if rem and w.actors[rem] then UI.selected = rem; return end
    for _, r in ipairs(UI.Members()) do if w.actors[r.id] then UI.selected = r.id; return end end
    local ids = SS.Sim.ActorIds(w)
    for _, id in ipairs(ids) do if not w.actors[id].role then UI.selected = id; return end end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
function UI.Create()
    if UI.frame then return UI.frame end
    local caps = SS.Compat.Probe()
    local db = SS.Save.DB()
    local f = CreateFrame("Frame", nil, UIParent)
    UI.frame = f
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    local pos = db.ui
    f:SetSize(pos.w or 980, pos.h or 680)
    f:SetPoint("CENTER", UIParent, "CENTER", pos.x or 0, pos.y or 0)
    f:SetMovable(true); f:SetResizable(true); f:SetClampedToScreen(true)
    if caps.resizeBounds then f:SetResizeBounds(720, 500, 1920, 1200) elseif caps.minResize then f:SetMinResize(720, 500) end
    f:EnableMouse(true)
    f:Hide()
    UI.border = tex(f, "BACKGROUND", "trim"); UI.border:SetAllPoints()
    UI.back = tex(f, "BACKGROUND", "bg", 1); UI.back:SetPoint("TOPLEFT", 2, -2); UI.back:SetPoint("BOTTOMRIGHT", -2, 2)

    UI.CreateTitleBar(f)
    UI.CreateBar(f)

    -- viewport (the lot) and the full-window content area for fullscreen modes
    local vp = CreateFrame("Frame", nil, f)
    UI.viewport = vp
    if caps.clipsChildren then vp:SetClipsChildren(true) end
    tex(vp, "BACKGROUND", { 0.36, 0.50, 0.34, 1 }):SetAllPoints()
    vp:EnableMouse(true)
    vp:EnableMouseWheel(true)
    UI.content = CreateFrame("Frame", nil, f)
    SS.Render.Init(vp)
    vp:SetScript("OnMouseDown", function(_, btn) UI.MouseDown(btn) end)
    vp:SetScript("OnMouseUp", function(_, btn) UI.MouseUp(btn) end)
    vp:SetScript("OnMouseWheel", function(_, d) UI.Zoom(d > 0 and 1 or -1) end)
    vp:SetScript("OnSizeChanged", function() if world() then UI.dirty = true end end)

    UI.CreateCameraStrip(vp)
    UI.CreateNotices(f)
    UI.CreateCaptions(vp)
    UI.CreatePanel(f)
    UI.CreateMenu(f)
    UI.CreateHelp(f)
    UI.CreateRestoreButton(f)

    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(f:GetFrameLevel() + 50)
    tex(grip, "OVERLAY", "sun"):SetAllPoints()
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing(); UI.SaveGeometry(); UI.dirty = true end)
    K.Tooltip(grip, "Drag to resize the window")
    UI.grip = grip

    f:EnableKeyboard(true)
    f:SetScript("OnKeyDown", function(self, key) UI.KeyDown(self, key) end)
    f:SetScript("OnUpdate", function(_, el) UI.OnUpdate(el) end)
    f:SetScript("OnHide", function() UI.OnHidden() end)
    f:SetScript("OnShow", function() UI.OnShown() end)

    UI.ApplyLayout()
    for _, fn in ipairs(UI.onCreate or {}) do fn(f) end
    return f
end

-- Hooks for other shell files that build parts of the window lazily.
UI.onCreate = UI.onCreate or {}
function UI.OnCreate(fn)
    UI.onCreate[#UI.onCreate + 1] = fn
    if UI.frame then fn(UI.frame) end
end

-- Art icon on a shell button when art provides it (SS.Art.icons[icon]); a label kept beside the
-- icon widens the button once. Without the art nothing changes.
function UI.WithIcon(b, icon, replace)
    if not icon or b.ssIconName == icon then return b end
    b.ssIconName = icon
    if b:SetIcon(icon, replace) and not replace then b:SetWidth(b:GetWidth() + b:GetHeight() - 4) end
    return b
end

function UI.CreateTitleBar(f)
    local title = CreateFrame("Frame", nil, f)
    UI.titleBar = title
    title:SetPoint("TOPLEFT", 2, -2); title:SetPoint("TOPRIGHT", -2, -2); title:SetHeight(UI.TITLE_H - 2)
    tex(title, "ARTWORK", "accentDeep"):SetAllPoints()
    title:EnableMouse(true); title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() UI.frame:StartMoving() end)
    title:SetScript("OnDragStop", function() UI.frame:StopMovingOrSizing(); UI.SaveGeometry() end)
    UI.titleText = text(title, 12, "paper"); UI.titleText:SetPoint("LEFT", 8, 0); UI.titleText:SetPoint("RIGHT", -200, 0)
    local x = -2
    local function right(b, icon, replace) UI.WithIcon(b, icon, replace); b:SetPoint("RIGHT", title, "RIGHT", x, 0); x = x - b:GetWidth() - 3 end
    right(button(title, "X", 22, 18, function() UI.Hide() end, "Close SideStreet. The house pauses and goes quiet; a checkpoint is kept."), "ui_close", true)
    right(button(title, "?", 22, 18, function() UI.ToggleHelp() end, "Help and the keybinding reference (H)"), "ui_help", true)
    right(button(title, "Options", 56, 18, function() if UI.ToggleOptions then UI.ToggleOptions() end end, "Text size, contrast, captions, sound and gameplay options (O)"), "ui_options")
    right(button(title, "Photo", 46, 18, function() UI.SetCleanView(true) end,
        "Clean view: hides every control so you can take a screenshot with the game's normal screenshot key. Press P or Esc to bring the controls back."), "ui_photo")
    right(button(title, "Menu", 44, 18, function() if UI.ShowTitle then UI.ShowTitle() end end, "Title screen: new game, continue, saves, tutorial and diagnostics"), "ui_menu")
end

function UI.CreateBar(f)
    local bar = CreateFrame("Frame", nil, f)
    UI.bar = bar
    bar:SetPoint("TOPLEFT", 2, -UI.TITLE_H); bar:SetPoint("TOPRIGHT", -2, -UI.TITLE_H); bar:SetHeight(UI.BAR_H)
    tex(bar, "ARTWORK", "panel"):SetAllPoints()
    local line = tex(bar, "OVERLAY", "trim"); line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); line:SetHeight(1)
    UI.speedBtns = {}
    local prev
    for lvl = 0, 3 do
        local b = button(bar, UI.SpeedLabel(lvl), lvl == 3 and 38 or 32, 24, function() UI.RequestSpeed(lvl) end, function()
            local head = T.speedLabel[lvl] or UI.SpeedLabel(lvl)
            local m = UI.CurrentMode()
            if m.pausesSim then
                return { head, (m.label or "This") .. " mode keeps the house paused: time does not pass here.",
                    "Click to choose the speed it resumes at when you leave (now " .. UI.SpeedLabel(UI.resumeSpeed or 1) .. ")." }
            end
            return { head, lvl == 0 and "Pause (Space). Time only passes while the window is open."
                or ("Game speed " .. UI.SpeedLabel(lvl) .. " (key " .. lvl .. "). Speed changes the simulation only, never music or animations.") }
        end)
        if lvl == 0 then UI.WithIcon(b, "ui_pause", true) end   -- 1x/3x/10x keep their explicit multipliers as text
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("LEFT", 6, 0) end
        UI.speedBtns[lvl] = b
        prev = b
    end
    UI.clock = text(bar, 12, "ink"); UI.clock:SetPoint("LEFT", prev, "RIGHT", 8, 0); UI.clock:SetWidth(150)
    local clockHit = CreateFrame("Frame", nil, bar); clockHit:SetAllPoints(UI.clock); clockHit:EnableMouse(true)
    K.Tooltip(clockHit, function()
        local w = world()
        if not w then return nil end
        return { "Clock", "Week " .. (math.floor(w.time / 10080) + 1) .. ", day " .. (math.floor(w.time / 1440) + 1) .. ".",
            "The household's time passes only while this window is open. Nothing happens while you are away." }
    end)
    UI.fundsBtn = button(bar, "", 86, 24, function() UI.OpenLedger() end, function()
        local w = world()
        local tip = { "Household funds", "Click to open the ledger (every payment and income)." }
        if w and w.settings.sandboxMoney then tip[#tip + 1] = "Sandbox money is ON for this save." end
        return tip
    end)
    UI.fundsBtn:SetPoint("LEFT", UI.clock, "RIGHT", 4, 0)
    UI.modeAnchor = UI.fundsBtn
    UI.modeBtns, UI.extraBtns = {}, {}
    UI.BuildModeButtons()
    UI.BuildToolbarExtras()
end

-- Mode buttons from the registry (rebuilt when modules register more modes).
function UI.BuildModeButtons()
    local bar = UI.bar
    for _, b in pairs(UI.modeBtns) do b:Hide() end
    local prev = UI.modeAnchor
    for n, m in ipairs(UI.ModeList()) do
        local b = UI.modeBtns[m.name]
        if not b then
            b = button(bar, m.label, math.max(44, #m.label * 7 + 12), 24, function() UI.SetMode(m.name) end, function(self)
                return { m.label .. (m.key and ("  (" .. m.key .. ")") or ""), m.tip or "" }
            end)
            UI.modeBtns[m.name] = b
            UI.WithIcon(b, m.icon or ("mode_" .. m.name))
        end
        b:ClearAllPoints()
        b:SetPoint("LEFT", prev, "RIGHT", n == 1 and 10 or 2, 0)
        b:SetActive(m.name == UI.mode)
        b:Show()
        prev = b
    end
    UI.modesBuiltFor = UI.registryVersion
end

function UI.BuildToolbarExtras()
    local bar = UI.bar
    for _, b in pairs(UI.extraBtns) do b:Hide() end
    local x = -6
    local function right(b) b:ClearAllPoints(); b:SetPoint("RIGHT", bar, "RIGHT", x, 0); x = x - b:GetWidth() - 3; b:Show() end
    UI.fwBtn = UI.fwBtn or button(bar, "Free Will", 70, 24, function() UI.ToggleFreeWill() end, function()
        return { "Free Will", "On: residents look after their own needs when they have nothing to do.",
            "Off: they only do what you order. Accidents, collapse and other safety reactions still happen." }
    end)
    UI.WithIcon(UI.fwBtn, "ui_freewill")
    right(UI.fwBtn)
    UI.saveBtn = UI.saveBtn or button(bar, "Save", 44, 24, function() UI.OpenSaves() end,
        "Save and load: 3 slots, the automatic checkpoint and the previous-good copy")
    UI.WithIcon(UI.saveBtn, "ui_save")
    right(UI.saveBtn)
    UI.journalBtn = UI.journalBtn or button(bar, "Journal", 56, 24, function() if UI.ToggleJournal then UI.ToggleJournal() end end,
        "The household story journal (J)")
    UI.WithIcon(UI.journalBtn, "ui_journal")
    right(UI.journalBtn)
    local extras = {}
    for _, d in pairs(UI.toolbarExtras) do extras[#extras + 1] = d end
    table.sort(extras, function(a, b) if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) > (b.order or 50) end return a.name > b.name end)
    for _, d in ipairs(extras) do
        local name = d.name
        local b = UI.extraBtns[name]
        if not b then
            -- the click looks the entry up again, so a module re-registering its button (new
            -- label, tip or handler) is followed without a stale closure
            b = button(bar, d.label, d.width or 50, 24, function(self)
                local cur = UI.toolbarExtras[name]
                if cur and cur.onClick then cur.onClick(self) end
            end, d.tip)
            UI.extraBtns[name] = b
        end
        b:SetLabel(d.label or name)
        b:SetWidth(d.width or 50)
        b.ssTip = d.tip
        b.ssIconName = nil
        if d.icon then UI.WithIcon(b, d.icon) end
        right(b)
    end
    UI.extrasBuiltFor = UI.registryVersion
end

-- Camera controls float on the lot's right edge, so they never cover the control panel.
function UI.CreateCameraStrip(vp)
    local s = CreateFrame("Frame", nil, vp)
    UI.camStrip = s
    s:SetFrameStrata("DIALOG"); s:SetFrameLevel(5)
    s:SetPoint("TOPRIGHT", -4, -4); s:SetSize(40, 10)
    tex(s, "BACKGROUND", { 0, 0, 0, 0.25 }):SetAllPoints()
    local defs = {
        { "<Q", function() UI.Rotate(-1) end, "Rotate the view left (Q)", "cam_rotate_left" },
        { "E>", function() UI.Rotate(1) end, "Rotate the view right (E)", "cam_rotate_right" },
        { "+", function() UI.Zoom(1) end, "Zoom in (= or mouse wheel)", "cam_zoom_in" },
        { "-", function() UI.Zoom(-1) end, "Zoom out (- or mouse wheel)", "cam_zoom_out" },
        { "Lot", function() UI.WholeLot() end, "Whole-lot view: fit the entire lot in the window (F)", "cam_whole_lot" },
        { "Me", function() UI.CenterOnSelected() end, "Centre on the selected person (Home)", "cam_centre" },
        { "Wall", function() UI.CycleWalls() end, function()
            local names = { up = "up", cut = "cutaway", down = "down", roof = "roof visible" }
            return { "Walls: " .. (names[SS.Render.cam.walls] or "?"), "Cycle walls up / cutaway / down / roof (Tab)" }
        end, "cam_walls" },
        { "Up", function() UI.ChangeLevel(1) end, "Show the floor above (Page Up)", "cam_floor_up" },
        { "Dn", function() UI.ChangeLevel(-1) end, "Show the floor below (Page Down)", "cam_floor_down" },
    }
    UI.camBtns = {}
    for n, d in ipairs(defs) do
        local b = button(s, d[1], 34, 20, d[2], d[3])
        UI.WithIcon(b, d[4], true)
        b:SetPoint("TOP", 0, -3 - (n - 1) * 22)
        UI.camBtns[n] = b
    end
    s:SetHeight(#defs * 22 + 5)
    UI.levelText = text(s, 10, "paper", "CENTER"); UI.levelText:SetPoint("TOP", s, "BOTTOM", 0, -2)
end

-- Where each region sits, for the current mode, panel state and clean view.
function UI.ApplyLayout()
    local f = UI.frame
    if not f then return end
    local mode = UI.CurrentMode()
    local clean = UI.clean
    local fullscreen = mode.fullscreen
    local panelH = UI.PanelHeight()
    local top = clean and 2 or (UI.TITLE_H + UI.BAR_H)
    UI.titleBar:SetShown(not clean)
    UI.bar:SetShown(not clean)
    local vp = UI.viewport
    vp:ClearAllPoints()
    vp:SetPoint("TOPLEFT", 2, -top)
    vp:SetPoint("BOTTOMRIGHT", -2, (clean or fullscreen) and 2 or (panelH + 2))
    vp:SetShown(not fullscreen)
    UI.content:ClearAllPoints()
    UI.content:SetPoint("TOPLEFT", 2, -top); UI.content:SetPoint("BOTTOMRIGHT", -2, 2)
    UI.panel:ClearAllPoints()
    UI.panel:SetPoint("BOTTOMLEFT", 2, 2); UI.panel:SetPoint("BOTTOMRIGHT", -2, 2); UI.panel:SetHeight(panelH)
    UI.panel:SetShown(not (clean or fullscreen))
    UI.liveFrame:SetShown(UI.mode == "live")
    UI.camStrip:SetShown(not clean)
    UI.noticeFrame:SetShown(not clean)
    if UI.restoreBtn then UI.restoreBtn:SetShown(clean and true or false) end
    UI.grip:SetShown(not clean)
    if UI.OnLayout then UI.OnLayout(clean, fullscreen) end
    UI.dirty = true
end

function UI.PanelHeight()
    if UI.mode == "live" and UI.Pref("panelCollapsed") then return UI.PANEL_MIN_H end
    return UI.PANEL_H
end

---------------------------------------------------------------------------
-- Control panel: portraits row, selected person, tabs (Needs + registered), action queue.
-- UI.panel hosts every mode's panel; UI.liveFrame is live mode's content.
---------------------------------------------------------------------------
function UI.CreatePanel(f)
    local p0 = CreateFrame("Frame", nil, f)
    UI.panel = p0
    tex(p0, "ARTWORK", "panel"):SetAllPoints()
    local edge = tex(p0, "OVERLAY", "trim"); edge:SetPoint("TOPLEFT"); edge:SetPoint("TOPRIGHT"); edge:SetHeight(2)
    local p = CreateFrame("Frame", nil, p0)
    p:SetAllPoints(p0)
    UI.liveFrame = p

    -- portraits row (1-8 members, mood colour + glyph, alert badge, away state)
    UI.portraitBtns = {}
    for n = 1, UI.MAX_PORTRAITS do
        local holder = CreateFrame("Button", nil, p)
        holder:SetSize(26, 26)
        holder:SetPoint("TOPLEFT", 8 + (n - 1) * 28, -4)
        holder.ring = tex(holder, "BACKGROUND", { 0.5, 0.5, 0.5, 1 }); holder.ring:SetAllPoints()
        holder.port = K.Portrait(holder, 22)
        holder.port:SetPoint("CENTER")
        holder.port:EnableMouse(false)
        holder.badge = tex(holder, "OVERLAY", "danger", 2); holder.badge:SetSize(10, 10); holder.badge:SetPoint("TOPRIGHT", 2, 2)
        holder.badgeText = text(holder, 9, "paper", "CENTER"); holder.badgeText:SetPoint("CENTER", holder.badge, "CENTER", 0, 0); holder.badgeText:SetText("!")
        holder.badgeIcon = holder:CreateTexture(nil, "OVERLAY", nil, 3); holder.badgeIcon:SetPoint("TOPRIGHT", 3, 3); holder.badgeIcon:Hide()
        holder.glyph = text(holder, 9, "paper", "LEFT"); holder.glyph:SetPoint("BOTTOMLEFT", 1, 1)
        holder.away = text(holder, 9, "paper", "CENTER"); holder.away:SetPoint("BOTTOM", 0, 1)
        holder:SetScript("OnClick", function(self) UI.PortraitClicked(self.rid) end)
        K.Tooltip(holder, function(self) return UI.PortraitTip(self.rid) end)
        holder:Hide()
        UI.portraitBtns[n] = holder
    end
    UI.collapseBtn = button(p, "v", 22, 18, function() UI.TogglePanel() end, function()
        return UI.Pref("panelCollapsed") and "Show the control panel" or "Collapse the control panel to see more of the house"
    end)
    UI.collapseBtn:SetPoint("TOPRIGHT", -6, -6)

    -- selected person block
    local sel = CreateFrame("Frame", nil, p)
    UI.selBlock = sel
    sel:SetPoint("TOPLEFT", 8, -34); sel:SetSize(214, UI.PANEL_H - 40)
    UI.portrait = K.Portrait(sel, 56)
    UI.portrait:SetPoint("TOPLEFT")
    UI.portrait:SetScript("OnClick", function() UI.CenterOnSelected() end)
    K.Tooltip(UI.portrait, "Click to centre the view on this person (Home)")
    UI.name = text(sel, 13, "ink"); UI.name:SetPoint("TOPLEFT", UI.portrait, "TOPRIGHT", 6, -2); UI.name:SetWidth(150)
    UI.mood = text(sel, 11, "ink"); UI.mood:SetPoint("TOPLEFT", UI.name, "BOTTOMLEFT", 0, -3); UI.mood:SetWidth(150)
    UI.status = text(sel, 10, "inkSoft"); UI.status:SetPoint("TOPLEFT", UI.mood, "BOTTOMLEFT", 0, -3); UI.status:SetWidth(150)
    UI.moodBar = K.Bar(sel, 150, 6); UI.moodBar:SetPoint("TOPLEFT", UI.status, "BOTTOMLEFT", 0, -4)
    UI.whyBtn = button(sel, "Why?", 44, 18, function() if UI.ToggleInspector then UI.ToggleInspector() end end,
        "Autonomy inspector: what this person considered, the scores, the reasons and any route failures (I)")
    UI.whyBtn:SetPoint("TOPLEFT", UI.portrait, "BOTTOMLEFT", 0, -6)
    UI.nextBtn = button(sel, "Next", 44, 18, function() UI.CycleMember(1) end, "Select the next household member (C)")
    UI.nextBtn:SetPoint("LEFT", UI.whyBtn, "RIGHT", 4, 0)

    -- action queue block (right)
    local q = CreateFrame("Frame", nil, p)
    UI.queueFrame = q
    q:SetPoint("TOPRIGHT", -8, -32); q:SetPoint("BOTTOMRIGHT", -8, 6); q:SetWidth(214)
    UI.actTitle = text(q, 11, "ink"); UI.actTitle:SetPoint("TOPLEFT"); UI.actTitle:SetWidth(210)
    local pbg = tex(q, "BACKGROUND", "barBg"); pbg:SetPoint("TOPLEFT", 0, -16); pbg:SetSize(150, 8)
    UI.actBg = pbg
    UI.actFill = tex(q, "ARTWORK", "accentHi"); UI.actFill:SetPoint("LEFT", pbg, "LEFT"); UI.actFill:SetHeight(8)
    UI.actPct = text(q, 9, "inkSoft"); UI.actPct:SetPoint("LEFT", pbg, "RIGHT", 4, 0)
    UI.actCancel = button(q, "Cancel", 50, 16, function() UI.CancelAction(0) end, "Cancel the current action (the person finishes safely: gets up, puts things down)")
    UI.actCancel:SetPoint("TOPRIGHT", 0, -12)
    UI.queueRows = {}
    for n = 1, 5 do
        local b = button(q, "", 210, 16, function() UI.CancelAction(n) end, function()
            local a = UI.SelectedActor()
            local o = a and a.queue and a.queue[n]
            return o and { UI.OrderLabel(o), "Queued. Click to remove it from the queue." } or nil
        end)
        b:SetPoint("TOPLEFT", 0, -30 - (n - 1) * 18)
        b.label:ClearAllPoints(); b.label:SetPoint("LEFT", 6, 0); b.label:SetPoint("RIGHT", -18, 0); b.label:SetJustifyH("LEFT")
        b.x = text(b, 10, "paper", "RIGHT"); b.x:SetPoint("RIGHT", -5, 0); b.x:SetText("x")
        UI.queueRows[n] = b
    end

    -- tab strip and tab area (between the person block and the queue)
    UI.tabStrip = CreateFrame("Frame", nil, p)
    UI.tabStrip:SetPoint("TOPLEFT", 8 + UI.MAX_PORTRAITS * 28 + 8, -6); UI.tabStrip:SetPoint("TOPRIGHT", -34, -6); UI.tabStrip:SetHeight(20)
    UI.tabArea = CreateFrame("Frame", nil, p)
    UI.tabArea:SetPoint("TOPLEFT", sel, "TOPRIGHT", 6, 0)
    UI.tabArea:SetPoint("BOTTOMRIGHT", q, "BOTTOMLEFT", -8, 0)
    UI.tabArea:SetScript("OnSizeChanged", function() UI.LayoutNeeds() end)
    local needsFrame = CreateFrame("Frame", nil, UI.tabArea)
    needsFrame:SetAllPoints(UI.tabArea)
    UI.needsFrame = needsFrame
    UI.tabBtns = {}
    UI.CreateNeeds(needsFrame)
    UI.tab = "needs"
    UI.BuildTabs()
end

-- Needs: icon, label, bar (hatched when negative), value, trend arrows and a state word.
function UI.CreateNeeds(parent)
    UI.bars = {}
    for n, need in ipairs(T.needs) do
        local fr = CreateFrame("Frame", nil, parent)
        fr:SetSize(200, 14)
        local ic = fr:CreateTexture(nil, "ARTWORK"); ic:SetSize(14, 14); ic:SetPoint("LEFT")
        K.SetIcon(ic, need, 14, 14)
        local lbl = text(fr, 10, "ink"); lbl:SetPoint("LEFT", ic, "RIGHT", 3, 0); lbl:SetWidth(52); lbl:SetText(T.needLabel[need])
        local bar = K.Bar(fr, 90, 10); bar:SetPoint("LEFT", lbl, "RIGHT", 2, 0)
        local val = text(fr, 10, "ink"); val:SetPoint("LEFT", bar, "RIGHT", 4, 0); val:SetWidth(44)
        local word = text(fr, 9, "inkSoft"); word:SetPoint("LEFT", val, "RIGHT", 0, 0); word:SetWidth(46)
        fr:EnableMouse(true)
        K.Tooltip(fr, function() return UI.NeedTip(need) end)
        UI.bars[need] = { frame = fr, bar = bar, val = val, word = word, lbl = lbl, index = n }
    end
    UI.LayoutNeeds()
end

function UI.LayoutNeeds()
    if not UI.bars then return end
    local area = UI.tabArea
    local w = math.max(260, area:GetWidth() or 400)
    local h = math.max(80, area:GetHeight() or 110)
    local colW = math.floor(w / 2) - 4
    local rowH = math.floor(math.min(26, (h - 4) / 4))
    for need, b in pairs(UI.bars) do
        local n = b.index
        local col, row = (n - 1) % 2, math.floor((n - 1) / 2)
        b.frame:ClearAllPoints()
        b.frame:SetPoint("TOPLEFT", area, "TOPLEFT", col * (colW + 8), -2 - row * rowH)
        b.frame:SetSize(colW, 14)
        b.bar:SetBarWidth(colW - 14 - 55 - 44 - (colW > 240 and 46 or 0) - 6)
        b.word:SetShown(colW > 240)
    end
end

-- Trend per need: rate of change per sim hour from samples at least 5 sim minutes apart.
UI.trend = {}
function UI.NeedTrend(a, need)
    local tr = UI.trend[a.id]
    local w = world()
    if not tr or not w then return 0 end
    return tr.rate[need] or 0
end

local function sampleTrend(a)
    local w = world()
    local tr = UI.trend[a.id]
    if not tr then
        tr = { t = w.time, v = {}, rate = {} }
        for _, need in ipairs(T.needs) do tr.v[need] = a.needs[need] or 0 end
        UI.trend[a.id] = tr
        return
    end
    local dt = w.time - tr.t
    if dt >= 5 or dt < 0 then
        for _, need in ipairs(T.needs) do
            local v = a.needs[need] or 0
            tr.rate[need] = dt > 0 and (v - tr.v[need]) / dt * 60 or 0
            tr.v[need] = v
        end
        tr.t = w.time
    end
end

function UI.TrendArrow(rate)
    if rate > 20 then return "^^" elseif rate > 3 then return "^" elseif rate < -20 then return "vv" elseif rate < -3 then return "v" end
    return "="
end

function UI.NeedWord(v)
    if v < T.urgent then return "URGENT" elseif v < -20 then return "low" elseif v < 20 then return "ok" end
    return "good"
end

function UI.NeedHelp(need)
    local h = {
        hunger = "eat. Meals from the fridge and stove are better than snacks; an interrupted meal only gives what was eaten.",
        energy = "sleep in a bed (better beds recover faster) or nap. At the very bottom people pass out where they stand.",
        bladder = "use a toilet. If it bottoms out there is an accident and a puddle.",
        hygiene = "shower, bathe or wash hands. Exercise, accidents and mess make it drop.",
        fun = "TV, games, hobbies and people. Doing the same thing over and over gets less fun.",
        social = "talk and spend time with people. Being in the same room is not the same as a conversation.",
        comfort = "sit in comfortable seats or rest in bed. Standing and walking wear it down.",
        room = "follows the room the person is in right now: light, decoration, space, mess and broken things.",
    }
    return h[need] or ""
end

function UI.NeedTip(need)
    local a = UI.SelectedActor()
    local tip = { T.needLabel[need], "Raise it: " .. UI.NeedHelp(need) }
    if a then
        local v = a.needs[need] or 0
        local rate = UI.NeedTrend(a, need)
        tip[#tip + 1] = string.format("Now %d (%s), %s about %d per hour.", v, UI.NeedWord(v),
            rate >= 0 and "rising" or "falling", math.floor(math.abs(rate) + 0.5))
    end
    tip[#tip + 1] = "Scale: -100 (desperate) to +100 (fully satisfied); below " .. T.urgent .. " is urgent."
    return tip
end

---------------------------------------------------------------------------
-- Tabs. Fallback tabs (read-only views of the data model) give personality, relationships,
-- skills and work a home until the social and careers modules register their own.
---------------------------------------------------------------------------
local function tabLines(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.lines = {}
    for n = 1, 8 do
        local fs = text(f, 10, "ink"); fs:SetPoint("TOPLEFT", 4, -2 - (n - 1) * 14); fs:SetPoint("RIGHT", -4, 0)
        f.lines[n] = fs
    end
    function f:Set(list)
        for n = 1, #self.lines do self.lines[n]:SetText(list[n] or "") end
    end
    return f
end

UI.RegisterTab("personality", { label = "Personality", order = 20, fallback = true,
    tip = "Personality: the five traits that shape choices and conversations",
    create = tabLines,
    refresh = function(f, a, w)
        local p = a.personality or {}
        local labels = { neat = "Neat", outgoing = "Outgoing", active = "Active", playful = "Playful", nice = "Nice" }
        local out = {}
        for _, k in ipairs({ "neat", "outgoing", "active", "playful", "nice" }) do
            local v = p[k] or 0
            out[#out + 1] = string.format("%-9s %2d / 10  %s", labels[k], v, string.rep("|", math.floor(v)))
        end
        if a.interests then
            local ids = {}
            for id, v in pairs(a.interests) do if v >= 7 then ids[#ids + 1] = id end end
            table.sort(ids)
            if #ids > 0 then out[#out + 1] = "Loves talking about: " .. table.concat(ids, ", ") end
        end
        f:Set(out)
    end })

UI.RegisterTab("relationships", { label = "Relationships", order = 30, fallback = true,
    tip = "How this person feels about others (each direction is separate)",
    create = tabLines,
    refresh = function(f, a, w)
        local out = {}
        local rel = w.root.social and w.root.social.rel or {}
        local keys = {}
        local prefix = a.id .. ">"
        for key in pairs(rel) do if key:sub(1, #prefix) == prefix then keys[#keys + 1] = key end end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local r = rel[key]
            local other = w.root.residents[key:sub(#prefix + 1)]
            if other and #out < 8 then
                local fam = r.flags and r.flags.family
                out[#out + 1] = string.format("%s: today %d, overall %d%s", other.name, r.daily or 0, r.life or 0, fam and ("  (" .. fam .. ")") or "")
            end
        end
        if #out == 0 then out[1] = "No relationships yet. Talking to people builds them." end
        f:Set(out)
    end })

UI.RegisterTab("skills", { label = "Skills", order = 40, fallback = true,
    tip = "Skill levels (0-10), raised by practice with the right objects",
    create = tabLines,
    refresh = function(f, a, w)
        local out = {}
        local list = SS.Skills and SS.Skills.LIST or { "cooking", "mechanical", "charisma", "body", "logic", "creativity" }
        for _, s in ipairs(list) do
            local v = a.skills and a.skills[s] or 0
            out[#out + 1] = string.format("%-11s %4.1f  %s", s:sub(1, 1):upper() .. s:sub(2), v, string.rep("|", math.floor(v)))
        end
        f:Set(out)
    end })

UI.RegisterTab("career", { label = "Work", order = 50, fallback = true,
    tip = "Job or school: title, pay and schedule",
    create = tabLines,
    refresh = function(f, a, w)
        local c = a.career
        local out = {}
        if type(c) == "table" and (c.track or c.title) then
            out[1] = "Job: " .. tostring(c.title or c.track) .. (c.level and ("  (level " .. c.level .. ")") or "")
            if c.pay then out[#out + 1] = "Pay: " .. UI.Money(c.pay) .. " per shift" end
            if c.performance then out[#out + 1] = "Performance: " .. tostring(c.performance) end
        elseif type(a.school) == "table" and a.school.grade then
            out[1] = "School grade: " .. tostring(a.school.grade)
        else
            out[1] = (a.age == "child") and "Goes to school on weekdays." or "No job. Look for one in the newspaper or on a computer."
        end
        f:Set(out)
    end })

function UI.TabList()
    local list = { { name = "needs", label = "Needs", order = 0, frame = UI.needsFrame, tip = "The eight needs (motives)" } }
    local replaced = {}
    for _, d in pairs(UI.tabs) do
        if not d.fallback then for _, r in ipairs(d.replaces or {}) do replaced[r] = true end end
    end
    for _, d in pairs(UI.tabs) do
        if not (d.fallback and replaced[d.name]) then list[#list + 1] = d end
    end
    table.sort(list, function(a, b) if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) < (b.order or 50) end return a.name < b.name end)
    return list
end

function UI.BuildTabs()
    UI.tabList = UI.TabList()
    for _, b in pairs(UI.tabBtns) do b:Hide() end
    local prev
    local stripW = UI.tabStrip:GetWidth() or 400
    local used = 0
    UI.tabOverflow = {}
    for _, d in ipairs(UI.tabList) do
        local b = UI.tabBtns[d.name]
        local w = math.max(44, #d.label * 6 + 12)
        if not b then
            b = button(UI.tabStrip, d.label, w, 18, function() UI.SelectTab(d.name) end, d.tip or d.label)
            UI.tabBtns[d.name] = b
        end
        b:SetLabel(d.label)
        b:SetWidth(w)
        b.ssTip = d.tip or d.label
        b:ClearAllPoints()
        if stripW > 0 and used + w > stripW - 50 and prev then
            UI.tabOverflow[#UI.tabOverflow + 1] = d
        else
            if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("LEFT", UI.tabStrip, "LEFT", 0, 0) end
            b:Show()
            prev = b
            used = used + w + 2
        end
        b:SetActive(d.name == UI.tab)
    end
    if #UI.tabOverflow > 0 then
        UI.moreTabs = UI.moreTabs or button(UI.tabStrip, "More", 44, 18, function()
            local rows = {}
            for _, d in ipairs(UI.tabOverflow) do rows[#rows + 1] = { d.label, function() UI.SelectTab(d.name) end, tip = d.tip } end
            UI.ShowMenu("More panels", nil, rows)
        end, "More panels")
        UI.moreTabs:ClearAllPoints()
        UI.moreTabs:SetPoint("LEFT", prev, "RIGHT", 2, 0)
        UI.moreTabs:Show()
    elseif UI.moreTabs then UI.moreTabs:Hide() end
    UI.tabsBuiltFor = UI.registryVersion
    local found = false
    for _, d in ipairs(UI.tabList) do if d.name == UI.tab then found = true end end
    if not found then UI.tab = "needs" end
    UI.SelectTab(UI.tab)
end

function UI.SelectTab(name)
    if UI.Pref("panelCollapsed") then UI.SetPref("panelCollapsed", false); UI.ApplyLayout() end
    for _, d in ipairs(UI.tabList or {}) do
        if d.name == name and not d.frame and d.create then d.frame = d.create(UI.tabArea) end
        if d.frame then d.frame:SetShown(d.name == name) end
        if UI.tabBtns[d.name] then UI.tabBtns[d.name]:SetActive(d.name == name) end
    end
    UI.tab = name
    UI.RefreshPanel()
    SS.Emit("uiTab", name)
end

function UI.TogglePanel()
    UI.SetPref("panelCollapsed", not UI.Pref("panelCollapsed"))
    UI.ApplyLayout()
end

---------------------------------------------------------------------------
-- Panel refresh
---------------------------------------------------------------------------
function UI.PortraitClicked(rid)
    local w = world()
    if not w or not rid then return end
    if w.actors[rid] then
        if UI.selected == rid then UI.CenterOnSelected() else UI.Select(rid) end
        return
    end
    local r = w.root.residents[rid]
    local away = r and r.away
    local why = away and away.reason or "not on this lot"
    local back = away and away.untilT and (" until " .. UI.ClockText(away.untilT)) or ""
    UI.Notice((r and r.name or "They") .. " is away (" .. tostring(why) .. ")" .. back .. ".")
end

function UI.PortraitTip(rid)
    local w = world()
    local r = w and rid and w.root.residents[rid]
    if not r then return nil end
    local tip = { r.name }
    if not w.actors[rid] then
        local away = r.away
        tip[#tip + 1] = "Away: " .. tostring(away and away.reason or "not on this lot") ..
            (away and away.untilT and (", back around " .. UI.ClockText(away.untilT)) or "")
        return tip
    end
    local mood = SS.Needs.Mood(r)
    tip[#tip + 1] = string.format("Mood %s (%d)", UI.MoodWord(mood), mood)
    local worst, wv = SS.Needs.Worst(r)
    if worst and wv < 0 then tip[#tip + 1] = string.format("Lowest need: %s %d", T.needLabel[worst], wv) end
    if r.act then tip[#tip + 1] = "Doing: " .. UI.ActLabel(r.act) end
    tip[#tip + 1] = UI.selected == rid and "Click again to centre on them." or "Click to select."
    return tip
end

-- Alert: an urgent need, a failure balloon, or an alert-kind balloon.
function UI.ActorAlert(r)
    for _, need in ipairs(T.needs) do if (r.needs[need] or 0) < T.urgent then return true, T.needLabel[need] end end
    if r.balloon and r.balloon.kind == "alert" then return true, "alert" end
    return false
end

local portraitMembers = {}
function UI.RefreshPortraits()
    if not UI.portraitBtns then return end
    local w = world()
    local members = UI.Members(portraitMembers)
    for n, h in ipairs(UI.portraitBtns) do
        local r = members[n]
        if r then
            h.rid = r.id
            K.DrawPortrait(h.port, r)
            local here = w.actors[r.id] ~= nil
            -- the ring is set once per refresh: the selected person's is sun-coloured, everyone
            -- else's shows their mood (grey while away)
            local sel = UI.selected == r.id and K.C("sun")
            if here then
                local mood = SS.Needs.Mood(r)
                if sel then h.ring:SetColorTexture(sel[1], sel[2], sel[3], 1)
                else
                    local cr, cg, cb = UI.MoodColour(mood)
                    h.ring:SetColorTexture(cr, cg, cb, 1)
                end
                h.glyph:SetText(UI.MoodGlyph(mood))
                local alert = UI.ActorAlert(r)
                local art = alert and K.SetIcon(h.badgeIcon, "badge_alert", 12, 12)
                if not art then h.badgeIcon:Hide() end
                h.badge:SetShown(alert and not art); h.badgeText:SetShown(alert and not art)
                h.away:SetText("")
                h:SetAlpha(1)
            else
                if sel then h.ring:SetColorTexture(sel[1], sel[2], sel[3], 1) else h.ring:SetColorTexture(0.45, 0.45, 0.45, 1) end
                h.glyph:SetText("")
                h.badge:Hide(); h.badgeText:Hide()
                -- away: the art badge where it exists, the word otherwise (never colour alone)
                if K.SetIcon(h.badgeIcon, "badge_away", 12, 12) then h.away:SetText("") else h.badgeIcon:Hide(); h.away:SetText("away") end
                h:SetAlpha(0.55)
            end
            h:Show()
        else
            h.rid = nil
            h:Hide()
        end
    end
end

function UI.RefreshPortrait()
    if not UI.portrait then return end
    local a = UI.SelectedActor()
    K.DrawPortrait(UI.portrait, a)
end

function UI.ActLabel(act)
    local ia = SS.Interactions[act.iid]
    return act.label or (ia and ia.label) or tostring(act.iid)
end

function UI.OrderLabel(o)
    if o.iid == "goto" then return "Go Here" end
    local ia = SS.Interactions[o.iid]
    local label = ia and ia.label or tostring(o.iid)
    local w = world()
    local obj = w and o.oid and w.lot.objects[o.oid]
    local def = obj and SS.Objects[obj.def]
    local tgt = o.tid and w and w.actors[o.tid]
    if tgt then label = label .. " with " .. tgt.name elseif def then label = label .. " (" .. def.name .. ")" end
    return label .. (o.manual and "" or "  [free will]")
end

local PHASE = { plan = "planning", route = "walking there", enter = "getting in", perform = "", exit = "finishing up",
    wait = "waiting", reserve = "waiting for a turn" }

function UI.ActProgress(a, act)
    local ia = SS.Interactions[act.iid]
    if not ia or act.phase ~= "perform" then return 0 end
    local t = act.t or 0
    if ia.dur and ia.dur > 0 then return t / ia.dur
    elseif ia.untilFull then return ((a.needs[ia.untilFull] or 0) + 100) / 198
    elseif ia.maxDur and ia.maxDur > 0 then return t / ia.maxDur end
    return 0
end

function UI.CancelAction(n)
    local a = UI.SelectedActor()
    local w = world()
    if not a or not w then return end
    SS.Actions.Cancel(w, a, n)
    SS.Emit("uiCancel", a, n)
    UI.RefreshPanel()
end

function UI.RefreshPanel()
    local w = world()
    if not w or not UI.name then return end
    local a = UI.SelectedActor()
    if not a then
        UI.name:SetText(w.household and (w.household.name .. " household") or "Nobody selected")
        UI.mood:SetText("Click a person or a portrait to select them.")
        UI.status:SetText("")
        UI.actTitle:SetText("")
        UI.actCancel:Hide(); UI.actFill:SetWidth(1); UI.actPct:SetText("")
        for _, row in ipairs(UI.queueRows) do row:Hide() end
        return
    end
    sampleTrend(a)
    UI.name:SetText(a.name)
    local mood = SS.Needs.Mood(a)
    UI.mood:SetText(string.format("Mood: %s %s (%d)", UI.MoodWord(mood), UI.MoodGlyph(mood), mood))
    UI.moodBar:SetValue(mood)
    local worst, wv = SS.Needs.Worst(a)
    if worst and wv < T.urgent then
        UI.status:SetText("Needs attention: " .. T.needLabel[worst] .. " " .. math.floor(wv))
        K.SetTextColor(UI.status, "warn")
    else
        UI.status:SetText(w.settings.freeWill and "Free Will on" or "Free Will off: waiting for your orders")
        K.SetTextColor(UI.status, "inkSoft")
    end
    if UI.tab ~= "needs" then
        for _, d in ipairs(UI.tabList or {}) do
            if d.name == UI.tab and d.frame and d.refresh then
                local ok, err = pcall(d.refresh, d.frame, a, w)
                if not ok then SS.Log("tab %s refresh failed: %s", d.name, tostring(err)) end
            end
        end
    else
        local hc = UI.Pref("highContrast")
        for _, need in ipairs(T.needs) do
            local b = UI.bars[need]
            local v = a.needs[need] or 0
            b.bar:SetValue(v)
            b.val:SetText(string.format("%d %s", v, UI.TrendArrow(UI.NeedTrend(a, need))))
            K.SetTextColor(b.val, v < T.urgent and "warn" or "ink")
            b.word:SetText(UI.NeedWord(v))
            if hc then b.word:SetText(UI.NeedWord(v):upper()) end
        end
    end
    local act = a.act
    if act then
        local phase = PHASE[act.phase] or act.phase or ""
        UI.actTitle:SetText("Now: " .. UI.ActLabel(act) .. (phase ~= "" and ("  (" .. phase .. ")") or "") .. (act.manual and "" or "  [free will]"))
        local frac = math.max(0, math.min(1, UI.ActProgress(a, act)))
        UI.actFill:SetWidth(math.max(1, frac * 150))
        UI.actPct:SetText(act.phase == "perform" and (math.floor(frac * 100) .. "%") or "")
        UI.actCancel:Show()
    else
        UI.actTitle:SetText(w.settings.freeWill and "Now: deciding what to do" or "Now: waiting for orders")
        UI.actFill:SetWidth(1); UI.actPct:SetText("")
        UI.actCancel:Hide()
    end
    for n, row in ipairs(UI.queueRows) do
        local o = a.queue and a.queue[n]
        if o then row.label:SetText("Next: " .. UI.OrderLabel(o)); row:Show() else row:Hide() end
    end
end

function UI.RefreshToolbar()
    local w = world()
    if not UI.frame then return end
    if UI.modesBuiltFor ~= UI.registryVersion then UI.BuildModeButtons() end
    if UI.extrasBuiltFor ~= UI.registryVersion then UI.BuildToolbarExtras() end
    if UI.tabsBuiltFor ~= UI.registryVersion then UI.BuildTabs() end
    if not w then return end
    UI.clock:SetText(UI.ClockText(w.time))
    UI.fundsBtn.label:SetText(w.household and UI.Money(w.money) or "-")
    -- in a pausing mode the running speeds are dimmed (time does not pass here) and the one the
    -- house will resume at keeps its underline
    local held = UI.CurrentMode().pausesSim
    for lvl, b in pairs(UI.speedBtns) do
        b:SetActive(w.speed == lvl)
        b.label:SetAlpha((held and lvl > 0) and 0.55 or 1)
        if held and lvl > 0 and (UI.resumeSpeed or 1) == lvl then b.ul:Show() end
    end
    UI.fwBtn:SetActive(w.settings.freeWill)
    UI.fwBtn.label:SetText(w.settings.freeWill and "Free Will" or "No Free Will")
    for name, b in pairs(UI.modeBtns) do
        local m = name == "live" and UI.liveMode or UI.modes[name]
        if m and m.canEnter and name ~= UI.mode then
            local ok, why = m.canEnter(w)
            b:SetUsable(ok and true or false, why)
        end
    end
    for name, b in pairs(UI.extraBtns) do
        local d = UI.toolbarExtras[name]
        if d and d.usable then local ok, why = d.usable(w); b:SetUsable(ok and true or false, why) end
    end
    local tut = SS.Tutorial and SS.Tutorial.active
    UI.saveBtn:SetLabel(tut and "Saves" or "Save")
    local hh = w.household
    UI.titleText:SetText("SideStreet  -  " .. (w.lot.address or w.lot.name or w.lot.id) .. (hh and ("  -  " .. hh.name .. " household") or "")
        .. (tut and "  (tutorial)" or "") .. ((w.settings.sandboxMoney or (w.root.shell and w.root.shell.sandboxUsed)) and "  (sandbox)" or ""))
    UI.levelText:SetText("Floor " .. ((SS.Render.cam.level or 0) + 1))
    UI.collapseBtn:SetLabel(UI.Pref("panelCollapsed") and "^" or "v")
end

---------------------------------------------------------------------------
-- Notices (queued in Kit; shown here, 3 at a time, each for about 5 seconds)
---------------------------------------------------------------------------
function UI.CreateNotices(f)
    local nf = CreateFrame("Frame", nil, f)
    UI.noticeFrame = nf
    nf:SetFrameStrata("DIALOG"); nf:SetFrameLevel(20)
    nf:SetPoint("TOPLEFT", UI.viewport, "TOPLEFT", 60, -6); nf:SetPoint("TOPRIGHT", UI.viewport, "TOPRIGHT", -60, -6); nf:SetHeight(66)
    UI.noticeRows = {}
    for n = 1, 3 do
        local row = CreateFrame("Frame", nil, nf)
        row:SetHeight(20)
        row:SetPoint("TOPLEFT", 0, -(n - 1) * 22); row:SetPoint("TOPRIGHT", 0, -(n - 1) * 22)
        row.bg = tex(row, "BACKGROUND", { 0, 0, 0, 0.55 }); row.bg:SetAllPoints()
        row.mark = text(row, 11, "sun", "LEFT"); row.mark:SetPoint("LEFT", 6, 0); row.mark:SetWidth(14)
        row.icon = row:CreateTexture(nil, "OVERLAY"); row.icon:SetPoint("LEFT", 4, 0); row.icon:Hide()
        row.text = text(row, 12, "paper", "CENTER"); row.text:SetPoint("LEFT", 18, 0); row.text:SetPoint("RIGHT", -6, 0)
        row:Hide()
        UI.noticeRows[n] = row
    end
    UI.noticeShown = {}
    -- the uiNotice alias for the old single notice FontString
    UI.notice = UI.noticeRows[1].text
end

local NOTICE_MARK = { info = "i", warn = "!", good = "+" }
UI.NOTICE_TIME = 5
-- Newest on top and shown at once (a refused action's reason must appear when it happens, not
-- after older messages time out); with three on screen the oldest steps aside. A repeated message
-- is counted ("x3") and moves back to the top instead of stacking. UI.notice (the old single
-- notice FontString) is the top row, i.e. always the latest message.
function UI.OnNotice()
    if not UI.noticeRows then return end
    local q = UI.noticeQueue
    local shown = UI.noticeShown
    local t = now()
    local changed = false
    for n = #shown, 1, -1 do if shown[n].untilT <= t then table.remove(shown, n); changed = true end end
    while #q > 0 do
        local e = table.remove(q, 1)
        local at
        for n = 1, #shown do if shown[n].text == e.text then at = n end end
        if at then
            local s = table.remove(shown, at)
            s.count = (s.count or 1) + (e.count or 1)
            e = s
        else
            if SS.Audio and SS.Audio.Cue and e.kind == "warn" then SS.Audio.Cue("alert") end
        end
        e.untilT = t + UI.NOTICE_TIME
        table.insert(shown, 1, e)
        while #shown > #UI.noticeRows do table.remove(shown) end
        changed = true
    end
    if not changed and not UI.noticeDirty then return end
    UI.noticeDirty = false
    for n, row in ipairs(UI.noticeRows) do
        local e = shown[n]
        if e then
            row.text:SetText(e.text .. ((e.count and e.count > 1) and ("  (x" .. e.count .. ")") or ""))
            row.mark:SetText(NOTICE_MARK[e.kind] or "i")
            K.IconOrGlyph(row.icon, row.mark, "notice_" .. (NOTICE_MARK[e.kind] and e.kind or "info"), 14)
            row:Show()
        else row:Hide() end
    end
end

function UI.ClearNotices()
    for n = #UI.noticeQueue, 1, -1 do UI.noticeQueue[n] = nil end
    if UI.noticeShown then for n = #UI.noticeShown, 1, -1 do UI.noticeShown[n] = nil end end
    UI.noticeDirty = true
    UI.OnNotice()
end

---------------------------------------------------------------------------
-- Captions: dialogue text next to the speaker, independent of voices (read from
-- actor.balloon.text; positioned with SS.Render.ActorScreenPos). Pooled, at most 8.
---------------------------------------------------------------------------
function UI.CreateCaptions(vp)
    local cf = CreateFrame("Frame", nil, vp)
    UI.captionFrame = cf
    cf:SetAllPoints(vp)
    cf:SetFrameStrata("DIALOG"); cf:SetFrameLevel(10)
    UI.captionPool = {}
end

local function captionRow(n)
    local c = UI.captionPool[n]
    if c then return c end
    c = CreateFrame("Frame", nil, UI.captionFrame)
    c:SetSize(10, 16)
    c.bg = tex(c, "BACKGROUND", { 0, 0, 0, 0.6 }); c.bg:SetAllPoints()
    c.text = text(c, 11, "paper", "CENTER"); c.text:SetPoint("CENTER")
    c.text:SetWidth(200)
    UI.captionPool[n] = c
    return c
end

function UI.CaptionCap()
    return (SS.Perf and SS.Perf.quality == "reduced") and 4 or UI.CAPTION_CAP
end

-- The actors' ids in sorted order for the captions, kept between frames and rebuilt only when the
-- set of actors changes. Checking costs no allocation: the same count with every kept id still
-- present means the same set.
local capIds, capWorld = {}, nil
function UI.CaptionIds(w)
    local n = 0
    for _ in pairs(w.actors) do n = n + 1 end
    local same = capWorld == w and n == #capIds
    if same then
        for i = 1, #capIds do if not w.actors[capIds[i]] then same = false; break end end
    end
    if not same then
        for i = #capIds, 1, -1 do capIds[i] = nil end
        for id in pairs(w.actors) do capIds[#capIds + 1] = id end
        table.sort(capIds)
        capWorld = w
        UI.captionIdBuilds = (UI.captionIdBuilds or 0) + 1
    end
    return capIds
end

-- Per frame this allocates nothing: the line is rebuilt only when the balloon, its text or the
-- speaker's name changes.
function UI.UpdateCaptions()
    local w = world()
    local used = 0
    if w and UI.Pref("captions") and UI.viewport:IsShown() and SS.Render.ActorScreenPos then
        local cap = UI.CaptionCap()
        local ids = UI.CaptionIds(w)
        for i = 1, #ids do
            if used >= cap then break end
            local id = ids[i]
            local a = w.actors[id]
            local b = a and a.balloon
            if b and b.text and b.text ~= "" and (not b.untilT or b.untilT >= w.time) then
                local x, y, rel = SS.Render.ActorScreenPos(id)
                if x then
                    used = used + 1
                    local c = captionRow(used)
                    if c.bal ~= b or c.balText ~= b.text or c.balKind ~= b.kind or c.who ~= a.name then
                        c.bal, c.balText, c.balKind, c.who = b, b.text, b.kind, a.name
                        local who = a.name and (a.name:match("^(%S+)") or a.name) or "?"
                        local line = (b.kind == "thought" and (who .. " thinks: ") or (who .. ": ")) .. b.text
                        if c.line ~= line then
                            c.line = line
                            c.text:SetText(line)
                            c:SetSize(math.min(210, c.text:GetStringWidth() + 12), c.text:GetStringHeight() + 6)
                        end
                    end
                    c:ClearAllPoints()
                    c:SetPoint("BOTTOM", rel or SS.Render.canvas, "TOPLEFT", x, -y + 6)
                    c:Show()
                end
            end
        end
    end
    for n = used + 1, #UI.captionPool do UI.captionPool[n]:Hide() end
    UI.captionsShown = used
end

---------------------------------------------------------------------------
-- Context menus
---------------------------------------------------------------------------
function UI.CreateMenu(f)
    local m = CreateFrame("Frame", nil, f)
    m:SetFrameStrata("DIALOG"); m:SetFrameLevel(60)
    m:SetSize(240, 40)
    tex(m, "BACKGROUND", "trim"):SetAllPoints()
    local bg = tex(m, "BORDER", "dark"); bg:SetPoint("TOPLEFT", 1, -1); bg:SetPoint("BOTTOMRIGHT", -1, 1)
    m.title = text(m, 12, "sun"); m.title:SetPoint("TOPLEFT", 8, -6); m.title:SetWidth(224)
    m.desc = text(m, 10, { 0.85, 0.85, 0.85 }); m.desc:SetPoint("TOPLEFT", m.title, "BOTTOMLEFT", 0, -2); m.desc:SetWidth(224)
    m.buttons = {}
    m:Hide()
    m:EnableMouse(true)
    UI.menu = m
end

-- entries: { { label, fn, disabledReason, tip = text|table|fn, header = bool }, ... }
-- back: { title, desc, entries, back } of the menu to return to (adds a "<  Back" row).
-- A page never holds more than UI.MENU_ROWS rows, Back included: when the entries do not fit, the
-- page shows as many as fit plus "More  >", which opens the rest (with Back to this page), so
-- every entry of a menu of any length stays reachable and the menu never grows.
function UI.MenuPage(entries, back)
    local cap = UI.MENU_ROWS - (back and 1 or 0)
    local rows, rest = {}, nil
    if back then rows[1] = { "<  Back", function() UI.ShowMenu(back[1], back[2], back[3], back[4]) end, keepOpen = true,
        tip = { "Back", "The previous menu" } } end
    if #entries > cap then
        for n = 1, cap - 1 do rows[#rows + 1] = entries[n] end
        rest = {}
        for n = cap, #entries do rest[#rest + 1] = entries[n] end
    else
        for n = 1, #entries do rows[#rows + 1] = entries[n] end
    end
    return rows, rest
end

function UI.ShowMenu(title, desc, entries, back)
    local m = UI.menu
    if not m then return end
    m.title:SetText(title or "")
    m.desc:SetText(desc or "")
    local rows, rest = UI.MenuPage(entries, back)
    if rest then
        rows[#rows + 1] = { "More  >", function() UI.ShowMenu(title, desc, rest, { title, desc, entries, back }) end, keepOpen = true,
            tip = { "More", #rest .. " more " .. (#rest == 1 and "entry" or "entries") } }
    end
    local y = -12 - m.title:GetStringHeight() - ((desc and desc ~= "") and (m.desc:GetStringHeight() + 4) or 0)
    for n, e in ipairs(rows) do
        local b = m.buttons[n]
        if not b then
            b = button(m, "", 224, 20, function(self)
                if self.why then UI.Notice(self.why, "warn"); return end
                if self.fn then
                    if not self.keepOpen then UI.HideMenu() end
                    self.fn()
                end
            end, function(self) return self.tipText end)
            b.label:ClearAllPoints(); b.label:SetPoint("LEFT", 8, 0); b.label:SetPoint("RIGHT", -6, 0); b.label:SetJustifyH("LEFT")
            m.buttons[n] = b
        end
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", 8, y)
        b.label:SetText(e[1] .. (e[3] and "  (unavailable)" or ""))
        b.fn, b.why, b.keepOpen = e[2], e[3], e.keepOpen
        local tip = e.tip
        if type(tip) == "function" then tip = tip() end
        if e[3] then
            if type(tip) == "table" then tip = { tip[1], unpack(tip, 2) }; tip[#tip + 1] = "Unavailable: " .. e[3]
            else tip = { e[1], tip or "", "Unavailable: " .. e[3] } end
        end
        b.tipText = tip
        b.label:SetAlpha(e[3] and 0.6 or 1)
        b:Show()
        y = y - 22
    end
    for n = #rows + 1, #m.buttons do m.buttons[n]:Hide() end
    m:SetHeight(-y + 6)
    -- place at the cursor, kept inside the window
    local x, cy = GetCursorPosition()
    local s = UI.frame:GetEffectiveScale()
    x, cy = x / s, cy / s
    local fl, fb, fr, ft = UI.frame:GetLeft() or 0, UI.frame:GetBottom() or 0, UI.frame:GetRight() or 2000, UI.frame:GetTop() or 2000
    local mw, mh = m:GetWidth(), m:GetHeight()
    x = math.max(fl, math.min(x + 8, fr - mw))
    cy = math.min(ft, math.max(cy - 8, fb + mh))
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, cy)
    m:Show()
    UI.menuRows = rows
end

function UI.HideMenu() if UI.menu then UI.menu:Hide() end end
function UI.MenuShown() return UI.menu and UI.menu:IsShown() end

-- Convert a registry entry ({label, onClick, disabled, reason, desc, cost, privacy, danger, submenu})
-- to a menu row, with a tooltip that explains cost, privacy, danger and availability.
function UI.MenuRow(e, title)
    local tip = { e.label }
    if e.desc then tip[#tip + 1] = e.desc end
    if e.cost then tip[#tip + 1] = "Costs " .. UI.Money(e.cost) .. "." end
    if e.privacy then tip[#tip + 1] = "Privacy: " .. (e.privacy == true and "needs the room to themselves." or e.privacy) end
    if e.danger then tip[#tip + 1] = "Danger: " .. (e.danger == true and "this can go wrong." or e.danger) end
    if e.submenu then
        return { e.label .. "  >", function()
            local rows = {}
            for _, s in ipairs(e.submenu) do rows[#rows + 1] = UI.MenuRow(s) end
            UI.ShowMenu(e.label, e.desc, rows, UI.menuBack)
        end, e.disabled and (e.reason or "Not available right now.") or nil, tip = tip, keepOpen = true }
    end
    return { e.label, e.onClick, e.disabled and (e.reason or "Not available right now.") or nil, tip = tip }
end

-- Reachability from the actor to any of the goal cells (one bounded search, counted in perf).
function UI.Reachable(w, a, goals)
    if not a or not goals or #goals == 0 then return true end
    local ok, path = pcall(SS.Nav.FindPath, w, math.floor(a.x), math.floor(a.y), a.level or 0, goals, a)
    if not ok then return true end
    return path ~= nil
end

local function needSummary(ia)
    local parts = {}
    local src = ia.gain or ia.advert or {}
    for _, need in ipairs(T.needs) do
        local v = src[need] or (ia.rate and ia.rate[need])
        if v and v ~= 0 then parts[#parts + 1] = T.needLabel[need] .. (v > 0 and " +" or " ") .. math.floor(v) .. ((ia.rate and ia.rate[need] and not (ia.gain and ia.gain[need])) and "/h" or "") end
    end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

local function riskText(ia, obj)
    local out = {}
    if type(ia.risk) == "table" then
        for k, v in pairs(ia.risk) do out[#out + 1] = tostring(k) .. (type(v) == "number" and string.format(" (%d%%)", math.floor(v * 100 + 0.5)) or "") end
        table.sort(out)
    elseif ia.risk then out[1] = tostring(ia.risk) end
    if obj and obj.state then
        if obj.state.burning then out[#out + 1] = "it is on fire" end
        if obj.state.broken then out[#out + 1] = "it is broken" end
    end
    return #out > 0 and table.concat(out, ", ") or nil
end

-- One interaction row with its explanation: availability, cost, privacy, reachability, danger.
function UI.InteractionRow(w, a, obj, iid, reach)
    local ia = SS.Interactions[iid]
    if not ia then return nil end
    local ok, why = true, nil
    if not a then ok, why = false, "Select a person first (click them or their portrait)."
    else ok, why = SS.Actions.Available(w, a, obj, iid) end
    local tip = { ia.label }
    if ia.desc then tip[#tip + 1] = ia.desc end
    local eff = needSummary(ia)
    if eff then tip[#tip + 1] = "Effect: " .. eff end
    if ia.dur then tip[#tip + 1] = string.format("Takes about %d minutes.", math.floor(ia.dur + 0.5)) end
    if ia.cost then tip[#tip + 1] = "Costs " .. UI.Money(ia.cost) .. "." end
    if ia.privacy then tip[#tip + 1] = "Privacy: needs the room to themselves; others wait outside." end
    local risk = riskText(ia, obj)
    if risk then tip[#tip + 1] = "Danger: " .. risk .. "." end
    if ia.ages and a and a.age and not ia.ages[a.age] then ok, why = false, "Not for " .. a.age .. "ren." end
    if ok and a and not ia.targetActor and reach then
        local canReach = reach(ia)
        if not canReach then ok, why = false, "No way to get there from here: something blocks the route." end
    end
    if ok then tip[#tip + 1] = ia.manualOnly and "Only when you ask (never on their own)." or nil end
    return { ia.label, function() SS.Actions.Order(w, a, obj.id, iid) end, (not ok) and why or nil, tip = tip, category = ia.category }
end

function UI.ObjectInfo(w, obj)
    local def = SS.Objects[obj.def]
    local lines = {}
    lines[#lines + 1] = def.desc
    lines[#lines + 1] = "Price " .. UI.Money(def.price or 0) .. (obj.paid and ("; paid " .. UI.Money(obj.paid)) or "") ..
        ((SS.Economy and SS.Economy.ResaleValue) and ("; worth " .. UI.Money(SS.Economy.ResaleValue(w, obj)) .. " if sold") or "")
    if def.ratings then
        local r = {}
        for k, v in pairs(def.ratings) do r[#r + 1] = k .. " " .. v end
        table.sort(r)
        if #r > 0 then lines[#lines + 1] = "Ratings: " .. table.concat(r, ", ") end
    end
    local st = {}
    for k, v in pairs(obj.state or {}) do if v == true then st[#st + 1] = k end end
    table.sort(st)
    if #st > 0 then lines[#lines + 1] = "State: " .. table.concat(st, ", ") end
    return lines
end

function UI.ObjectMenu(oid)
    local w = world()
    local o = w and w.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return end
    local a = UI.SelectedActor()
    local cache = {}
    -- reachability per distinct slot: resolve the slot's approach cells and search once
    local function reachFor(iid)
        return function()
            local okR, tgt = pcall(SS.Actions.ResolveSlot, w, a, o, iid)
            if not okR or not tgt then return true end
            local key = tostring(tgt.obj and tgt.obj.id) .. ":" .. tostring(tgt.slotName)
            if cache[key] == nil then cache[key] = UI.Reachable(w, a, tgt.approaches) end
            return cache[key]
        end
    end
    local first, groups, order = {}, {}, {}
    local actions = def.actions or {}
    for n, iid in ipairs(actions) do
        local row = UI.InteractionRow(w, a, o, iid, reachFor(iid))
        if row then
            local cat = row.category
            if #actions <= 7 or not cat or cat == "Basics" or #first < 5 then first[#first + 1] = row
            else
                if not groups[cat] then groups[cat] = {}; order[#order + 1] = cat end
                table.insert(groups[cat], row)
            end
        end
    end
    local entries = {}
    for _, r in ipairs(first) do entries[#entries + 1] = r end
    table.sort(order)
    for _, cat in ipairs(order) do
        local rows = groups[cat]
        entries[#entries + 1] = { cat .. "  >", function() UI.ShowMenu(def.name .. ": " .. cat, nil, rows, UI.menuBack) end, keepOpen = true,
            tip = { cat, #rows .. " more actions" } }
    end
    for _, e in ipairs(UI.CollectMenu("obj", w, a, oid)) do entries[#entries + 1] = UI.MenuRow(e) end
    local manage = {}
    for _, e in ipairs(UI.CollectMenu("purchase", w, a, oid)) do manage[#manage + 1] = UI.MenuRow(e) end
    local info = UI.ObjectInfo(w, o)
    manage[#manage + 1] = { "About this object", function() UI.ShowMenu(def.name, table.concat(info, "\n"), { { "Close", function() end } }) end,
        tip = info }
    entries[#entries + 1] = { "Manage  >", function() UI.ShowMenu(def.name, nil, manage, UI.menuBack) end, keepOpen = true,
        tip = { "Manage", "Details, value, and buying/selling options for this object" } }
    if #first == 0 and #order == 0 then
        table.insert(entries, 1, { "Nothing to do here", nil, "This object is decorative: it adds to the room's environment score.",
            tip = "Decorative objects make rooms nicer; the Room need follows the room people are in." })
    end
    local desc = def.desc
    if o.state and (o.state.broken or o.state.burning or o.state.dirty) then
        desc = (o.state.burning and "ON FIRE. " or "") .. (o.state.broken and "Broken. " or "") .. (o.state.dirty and "Dirty. " or "") .. (desc or "")
    end
    UI.menuBack = { def.name .. "  " .. UI.Money(def.price or 0), desc, entries }
    UI.ShowMenu(def.name .. "  " .. UI.Money(def.price or 0), desc, entries)
end

function UI.ActorMenu(ref)
    local w = world()
    local target = w.actors[ref]
    if not target then return end
    local isMember = w.household and target.householdId == w.household.id and not target.role
    local entries = UI.CollectMenu(ref == UI.selected and "self" or "actor", w, UI.SelectedActor(), ref)
    if not UI.selected then UI.Select(ref); return end
    if ref == UI.selected and #entries == 0 then UI.CenterOnSelected(); return end
    local rows = {}
    if isMember and ref ~= UI.selected then rows[1] = { "Select " .. target.name, function() UI.Select(ref) end, tip = "Control this person" } end
    for _, e in ipairs(entries) do rows[#rows + 1] = UI.MenuRow(e) end
    if #rows == 0 then
        if isMember then UI.Select(ref) else UI.Notice("There is nothing to do with " .. target.name .. " right now.") end
        return
    end
    if #rows == 1 and rows[1][1]:find("^Select ") then UI.Select(ref); return end
    local mood = SS.Needs.Mood(target)
    local desc = target.role and ("Visiting: " .. tostring(target.role)) or string.format("Mood %s (%d)", UI.MoodWord(mood), mood)
    UI.menuBack = { target.name, desc, rows }
    UI.ShowMenu(target.name, desc, rows)
end

function UI.CellMenu(wx, wy, level)
    local w = world()
    local a = UI.SelectedActor()
    local i, j = math.floor(wx), math.floor(wy)
    level = level or 0
    local rows = {}
    local goWhy
    if not a then goWhy = "Select a person first."
    elseif SS.World.Blocked(w, level, i, j) then goWhy = "Something is in the way there."
    elseif not UI.Reachable(w, a, { { i, j, level } }) then goWhy = "No way to get there from here: walls or furniture block the route." end
    rows[1] = { "Go Here", function() SS.Actions.Order(w, a, nil, "goto", i, j, { level = level }) end, goWhy,
        tip = { "Go Here", "Walk to this spot." } }
    for _, e in ipairs(UI.CollectMenu("cell", w, a, { i = i, j = j, level = level, x = wx, y = wy })) do rows[#rows + 1] = UI.MenuRow(e) end
    if #rows == 1 then
        if goWhy then UI.Notice(goWhy, "warn") else rows[1][2]() end
        return
    end
    UI.menuBack = { "Here", nil, rows }
    UI.ShowMenu("Here", nil, rows)
end

---------------------------------------------------------------------------
-- Selection cycling for overlapping things: clicking the same spot again picks the next one.
-- Uses SS.Render.PickAll (art module) when present, else hit-tests the draw lists here.
---------------------------------------------------------------------------
local function itemHit(it, px, py)
    for l = 1, #it.layers do
        local L = it.layers[l]
        local s = SS.Art.sprites[L[1]]
        if s and SS.Render.MaskHit(L[1], px - ((L[5] or it.x) - s[6]), py - ((L[6] or it.y) - s[7])) then return true end
    end
    return false
end

function UI.PickList(w)
    local R = SS.Render
    local out = {}
    if R.PickAll then
        local ok, list = pcall(R.PickAll, w)
        if ok and type(list) == "table" and #list > 0 then
            for _, e in ipairs(list) do
                local kind, ref = e.kind or e[1], e.ref or e[2]
                if kind then out[#out + 1] = { kind = kind, ref = ref, wx = e.wx or e[3], wy = e.wy or e[4], level = e.level or e[5] } end
            end
            if #out > 0 then return out end
        end
    end
    local ok = pcall(function()
        local px, py = R.CursorToCanvas()
        if not px then return end
        local lv = R.cam.level or 0
        local wx, wy = R.FromCanvas(w, R.cam, px, py, lv)
        local seen = {}
        local actors = R.state.actors or {}
        for n = #actors, 1, -1 do
            local it = actors[n]
            if not seen[it.ref] and itemHit(it, px, py) then seen[it.ref] = true; out[#out + 1] = { kind = "actor", ref = it.ref, wx = wx, wy = wy, level = lv } end
        end
        local items = R.state.items or {}
        for n = #items, 1, -1 do
            local it = items[n]
            if it.kind == "obj" and not seen[it.ref] and itemHit(it, px, py) then seen[it.ref] = true; out[#out + 1] = { kind = "obj", ref = it.ref, wx = wx, wy = wy, level = lv } end
        end
        if SS.World.InLot(w.lot, math.floor(wx), math.floor(wy)) then out[#out + 1] = { kind = "cell", wx = wx, wy = wy, level = lv } end
    end)
    if not ok or #out == 0 then
        local kind, ref, wx, wy, level = R.Pick(w)
        if kind then out = { { kind = kind, ref = ref, wx = wx, wy = wy, level = level } } end
    end
    return out
end

function UI.PickCycled(w)
    local list = UI.PickList(w)
    if #list == 0 then UI.lastPick = nil; return nil end
    local x, y = GetCursorPosition()
    local lp = UI.lastPick
    local idx = 1
    if lp and math.abs(lp.x - x) + math.abs(lp.y - y) <= 4 and #lp.list == #list then
        local same = true
        for n = 1, #list do if lp.list[n].kind ~= list[n].kind or lp.list[n].ref ~= list[n].ref then same = false; break end end
        if same then idx = lp.idx % #list + 1 end
    end
    UI.lastPick = { x = x, y = y, list = list, idx = idx }
    local hit = list[idx]
    if #list > 1 and idx > 1 then
        UI.Notice(string.format("Picked %s (%d of %d here; click again for the next)", UI.PickName(w, hit), idx, #list))
    end
    return hit, idx, #list
end

function UI.PickName(w, hit)
    if hit.kind == "actor" then local a = w.actors[hit.ref]; return a and a.name or "someone" end
    if hit.kind == "obj" then local o = w.lot.objects[hit.ref]; local d = o and SS.Objects[o.def]; return d and d.name or "an object" end
    return "the floor"
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------
function UI.MouseDown(btn)
    if btn == "RightButton" then
        local x, y = GetCursorPosition()
        UI.pan = { x = x, y = y, px = SS.Render.cam.panX, py = SS.Render.cam.panY, moved = false }
    end
end

function UI.MouseUp(btn)
    local w = world()
    if not w then return end
    local mode = UI.CurrentMode()
    if btn == "RightButton" then
        local moved = UI.pan and UI.pan.moved
        UI.pan = nil
        if moved then UI.SaveCamera() end
        if not moved then
            if UI.MenuShown() then UI.HideMenu(); return end
            if mode.click then mode.click("RightButton", SS.Render.Pick(w)) end
        end
        return
    end
    if btn ~= "LeftButton" then return end
    UI.HideMenu()
    local hit = UI.PickCycled(w)
    local kind, ref, wx, wy, level
    if hit then kind, ref, wx, wy, level = hit.kind, hit.ref, hit.wx, hit.wy, hit.level end
    if mode.click and mode.click(btn, kind, ref, wx, wy, level) then return end
    if UI.mode ~= "live" or not hit then return end
    if kind == "actor" then UI.ActorMenu(ref)
    elseif kind == "obj" then UI.ObjectMenu(ref)
    elseif kind == "cell" then UI.CellMenu(wx, wy, level) end
end

-- Keys the window consumes in live mode (everything else passes through to the game).
UI.HANDLED = {
    ESCAPE = true, SPACE = true, ["1"] = true, ["2"] = true, ["3"] = true, ["0"] = true, Q = true, E = true, MINUS = true, EQUALS = true,
    LEFT = true, RIGHT = true, UP = true, DOWN = true, TAB = true, HOME = true, H = true, J = true, O = true, I = true, P = true,
    F = true, C = true, PAGEUP = true, PAGEDOWN = true, ENTER = false,
}

UI.LIVE_KEYS = {
    { "Space / 0", "Pause and resume" }, { "1 / 2 / 3", "Speed 1x, 3x, 10x" },
    { "Q / E", "Rotate the view" }, { "- / = / wheel", "Zoom out / in" }, { "Arrow keys, right-drag", "Pan" },
    { "F", "Whole-lot view" }, { "Home", "Centre on the selected person" }, { "Tab", "Walls up / cutaway / down / roof" },
    { "Page Up / Down", "Floor up / down" }, { "C", "Select the next household member" },
    { "Click", "Select a person; actions for objects, people and floor (click the same spot again to cycle overlapping things)" },
    { "J", "Journal" }, { "O", "Options" }, { "I", "Autonomy inspector" }, { "H", "Help" },
    { "P", "Photo (clean) view: hide all controls; the camera, pause and speed keys still work, other keys go to the game" },
    { "Esc", "One layer at a time: dialog, menu, photo view, the mode's tool, panels, the title screen, the mode, then the window" },
}

-- Topmost visible floating panel (options, journal, inspector, help, ...).
function UI.RegisterFloating(frame, onClose)
    UI.floating[#UI.floating + 1] = { frame = frame, close = onClose }
    frame:HookScript("OnShow", function(self) self.ssShownAt = now() + (#UI.floating * 1e-6) end)
end

function UI.TopFloating()
    local best, bt
    for _, e in ipairs(UI.floating) do
        if e.frame:IsShown() and (not bt or (e.frame.ssShownAt or 0) >= bt) then best, bt = e, e.frame.ssShownAt or 0 end
    end
    return best
end

-- Esc releases one layer at a time: the dialog, the context menu, clean view (so the controls
-- come back before anything invisible changes), the mode's tool, the topmost floating panel, the
-- title screen, the mode (back to live), and finally the window itself (releasing the keyboard).
-- The first-launch choice is never dismissed into the placeholder household underneath (it is
-- not a game yet): there Esc closes the window and the choice waits for the next /sidestreet.
function UI.Escape()
    if UI.confirmDlg and UI.confirmDlg:IsShown() then UI.confirmDlg.no:Click(); return "dialog" end
    if UI.MenuShown() then UI.HideMenu(); return "menu" end
    if UI.clean then UI.SetCleanView(false); return "clean" end
    local mode = UI.CurrentMode()
    if mode.onKey and mode ~= UI.liveMode and mode.onKey("ESCAPE") then return "tool" end
    local fl = UI.TopFloating()
    if fl then if fl.close then fl.close() else fl.frame:Hide() end; return "panel" end
    if UI.TitleUp() and world() then
        if SS.Boot.IsPlaceholder(world()) then UI.Hide(); return "close" end
        if UI.HideTitle then UI.HideTitle() end
        return "title"
    end
    if UI.mode ~= "live" then UI.SetMode("live"); return "mode" end
    UI.Hide()
    return "close"
end

-- Keys that still work in clean (photo) view: pause and speed, and the camera, so the shot can be
-- framed. Every other key passes straight through to the game while the controls are hidden.
UI.CLEAN_KEYS = { ESCAPE = true, P = true, SPACE = true, ["0"] = true, ["1"] = true, ["2"] = true, ["3"] = true,
    Q = true, E = true, MINUS = true, EQUALS = true, LEFT = true, RIGHT = true, UP = true, DOWN = true, TAB = true,
    PAGEUP = true, PAGEDOWN = true, HOME = true, F = true }

-- Which keys the window keeps: a key is consumed (not passed to the game) only when it will
-- actually do something here.
function UI.KeyHandled(key)
    if UI.TitleUp() then return key == "ESCAPE", nil end
    if UI.clean then return UI.CLEAN_KEYS[key] or false, nil end
    local mode = UI.CurrentMode()
    local modeKey
    if UI.liveMode.key == key then modeKey = "live" end
    for name, m in pairs(UI.modes) do if m.key == key and (not modeKey or name < modeKey) then modeKey = name end end
    return (UI.HANDLED[key] or modeKey or (mode.keys and mode.keys[key])) and true or false, modeKey
end

function UI.KeyDown(self, key)
    local mode = UI.CurrentMode()
    local handled, modeKey = UI.KeyHandled(key)
    if SS.Compat.caps.propagateKeyboard and not InCombatLockdown() then self:SetPropagateKeyboardInput(not handled) end
    if not handled then return end
    if key == "ESCAPE" then UI.Escape(); return end
    if UI.TitleUp() then return end
    if modeKey then UI.SetMode(modeKey); return end
    if not UI.clean and mode.onKey and mode.onKey(key) then return end
    if key == "SPACE" or key == "0" then UI.RequestSpeed(nil)
    elseif key == "1" or key == "2" or key == "3" then UI.RequestSpeed(tonumber(key))
    elseif key == "Q" then UI.Rotate(-1) elseif key == "E" then UI.Rotate(1)
    elseif key == "MINUS" then UI.Zoom(-1) elseif key == "EQUALS" then UI.Zoom(1)
    elseif key == "LEFT" then UI.Pan(60, 0) elseif key == "RIGHT" then UI.Pan(-60, 0)
    elseif key == "UP" then UI.Pan(0, -60) elseif key == "DOWN" then UI.Pan(0, 60)
    elseif key == "TAB" then UI.CycleWalls()
    elseif key == "PAGEUP" then UI.ChangeLevel(1) elseif key == "PAGEDOWN" then UI.ChangeLevel(-1)
    elseif key == "HOME" then UI.CenterOnSelected()
    elseif key == "F" then UI.WholeLot()
    elseif key == "C" then UI.CycleMember(1)
    elseif key == "H" then UI.ToggleHelp()
    elseif key == "J" then if UI.ToggleJournal then UI.ToggleJournal() end
    elseif key == "O" then if UI.ToggleOptions then UI.ToggleOptions() end
    elseif key == "I" then if UI.ToggleInspector then UI.ToggleInspector() end
    elseif key == "P" then UI.SetCleanView(not UI.clean) end
end

function UI.CycleMember(d)
    local w = world()
    if not w then return end
    local here = {}
    for _, r in ipairs(UI.Members()) do if w.actors[r.id] then here[#here + 1] = r.id end end
    if #here == 0 then UI.Notice("Nobody from the household is on this lot."); return end
    local idx = 0
    for n, id in ipairs(here) do if id == UI.selected then idx = n end end
    UI.Select(here[(idx + d - 1) % #here + 1])
end

function UI.ToggleFreeWill()
    local w = world()
    if not w then return end
    w.settings.freeWill = not w.settings.freeWill
    UI.Notice(w.settings.freeWill and "Free Will on: residents look after themselves when idle."
        or "Free Will off: residents only follow your orders (safety reactions still happen).")
    UI.RefreshToolbar()
end

-- Stage-1 name kept for callers (music and effects toggles now live in Options).
function UI.ToggleSetting(key)
    local w = world()
    if key == "music" or key == "effects" then UI.SetSound(key, not UI.SoundOn(key)); return end
    if key == "freeWill" then UI.ToggleFreeWill(); return end
    if w then w.settings[key] = not w.settings[key] end
    UI.RefreshToolbar()
end

---------------------------------------------------------------------------
-- Camera: zoom, rotate, walls, floors, pan, whole-lot view, centre, edge scrolling, memory
---------------------------------------------------------------------------
function UI.ApplyPan()
    local cam = SS.Render.cam
    if SS.Render.canvas then
        SS.Render.canvas:ClearAllPoints(); SS.Render.canvas:SetPoint("CENTER", UI.viewport, "CENTER", cam.panX, cam.panY)
    end
end

function UI.Pan(dx, dy)
    local cam = SS.Render.cam
    cam.panX, cam.panY = cam.panX + dx, cam.panY + dy
    UI.ApplyPan()
    UI.camDirty = true
end

function UI.Zoom(d)
    local cam = SS.Render.cam
    local zi = 1
    for n, z in ipairs(SS.Render.ZOOMS) do if z == cam.zoom then zi = n end end
    zi = U.clamp(zi + d, 1, #SS.Render.ZOOMS)
    local nz = SS.Render.ZOOMS[zi]
    cam.panX, cam.panY = cam.panX * nz / cam.zoom, cam.panY * nz / cam.zoom
    cam.zoom = nz
    UI.dirty, UI.camDirty = true, true
end

function UI.Rotate(d)
    local cam = SS.Render.cam
    cam.r = (cam.r + d) % 4
    cam.panX, cam.panY = 0, 0
    UI.dirty, UI.camDirty = true, true
end

function UI.CycleWalls()
    local cam = SS.Render.cam
    cam.walls = cam.walls == "cut" and "down" or cam.walls == "down" and "up" or cam.walls == "up" and "roof" or "cut"
    UI.dirty, UI.camDirty = true, true
    UI.RefreshToolbar()
end

-- Floor up/down: which story is in view (and edited). Lower stories stay visible beneath it.
function UI.ChangeLevel(d)
    local cam = SS.Render.cam
    cam.level = SS.U.clamp((cam.level or 0) + d, 0, SS.World.LEVELS - 1)
    UI.dirty, UI.camDirty = true, true
    UI.RefreshToolbar()
end

-- Whole-lot view: the largest zoom at which the entire lot fits the viewport, centred.
function UI.WholeLot()
    local w = world()
    if not w then return end
    local cam = SS.Render.cam
    local cw, ch = SS.Render.CanvasSize(w, cam)
    local vw, vh = UI.viewport:GetWidth(), UI.viewport:GetHeight()
    local best = SS.Render.ZOOMS[1]
    for _, z in ipairs(SS.Render.ZOOMS) do
        if vw <= 0 or vh <= 0 or (cw * z <= vw and ch * z <= vh) then best = math.max(best, z) end
    end
    cam.zoom = best
    cam.panX, cam.panY = 0, 0
    UI.dirty, UI.camDirty = true, true
end

-- Centre the view on a world position (tiles) on a floor; shows that floor.
function UI.CenterOn(x, y, level)
    local w = world()
    if not w or type(x) ~= "number" or type(y) ~= "number" then return false end
    level = level or 0
    local cam = SS.Render.cam
    local u, v = SS.Grid.vpos(x, y, cam.r, w.lot.w, w.lot.h)
    if level > (cam.level or 0) or cam.walls ~= "roof" then cam.level = level end
    local px, py = SS.Render.ToCanvas(w, cam, u, v, level * SS.World.STORY + 1)
    local cw, ch = SS.Render.CanvasSize(w, cam)
    cam.panX, cam.panY = (cw / 2 - px) * cam.zoom, (py - ch / 2) * cam.zoom
    UI.ApplyPan()
    UI.dirty, UI.camDirty = true, true
    return true
end

function UI.CenterOnSelected()
    local a = UI.SelectedActor()
    if not a then return end
    UI.CenterOn(a.x, a.y, a.level or 0)
end

-- Optional edge scrolling (Options). Real-time speed, independent of game speed.
UI.EDGE, UI.EDGE_SPEED = 14, 420
function UI.EdgeScroll(el)
    if not UI.Pref("edgeScroll") or UI.pan or UI.clean or not UI.viewport:IsVisible() or not UI.viewport:IsMouseOver() then return end
    if UI.MenuShown() then return end
    local x, y = GetCursorPosition()
    local s = UI.viewport:GetEffectiveScale()
    x, y = x / s, y / s
    local l, r, b, t = UI.viewport:GetLeft(), UI.viewport:GetRight(), UI.viewport:GetBottom(), UI.viewport:GetTop()
    if not l then return end
    local dx, dy = 0, 0
    if x - l < UI.EDGE then dx = 1 elseif r - x < UI.EDGE then dx = -1 end
    if y - b < UI.EDGE then dy = 1 elseif t - y < UI.EDGE then dy = -1 end
    if dx ~= 0 or dy ~= 0 then UI.Pan(dx * UI.EDGE_SPEED * el, dy * UI.EDGE_SPEED * el) end
end

-- Remember the camera per lot (rotation, zoom, walls, floor, pan) in SideStreetDB.ui.cams.
UI.CAM_CAP = 40
function UI.SaveCamera(lotId)
    lotId = lotId or UI.camLot
    if not lotId then return end
    local db = SS.Save.DB()
    db.ui.cams = type(db.ui.cams) == "table" and db.ui.cams or {}
    local cam = SS.Render.cam
    local e = db.ui.cams[lotId]
    if type(e) ~= "table" then e = {}; db.ui.cams[lotId] = e end   -- the lot's entry is reused while the camera moves
    e.r, e.zoom, e.walls, e.level, e.panX, e.panY, e.t = cam.r, cam.zoom, cam.walls, cam.level or 0, cam.panX, cam.panY, time and time() or 0
    local n, oldestK, oldestT = 0, nil, nil
    for k, v in pairs(db.ui.cams) do
        n = n + 1
        if not oldestT or (v.t or 0) < oldestT then oldestK, oldestT = k, v.t or 0 end
    end
    if n > UI.CAM_CAP and oldestK then db.ui.cams[oldestK] = nil end
    UI.camDirty = false
end

function UI.RestoreCamera(lotId)
    local db = SS.Save.DB()
    local c = type(db.ui.cams) == "table" and db.ui.cams[lotId]
    local cam = SS.Render.cam
    if c then
        cam.r, cam.walls, cam.level = c.r or 0, c.walls or "cut", c.level or 0
        cam.panX, cam.panY = c.panX or 0, c.panY or 0
        cam.zoom = 1
        for _, z in ipairs(SS.Render.ZOOMS) do if z == c.zoom then cam.zoom = z end end
    else
        cam.r, cam.walls, cam.level, cam.panX, cam.panY, cam.zoom = 0, "cut", 0, 0, 0, 1
    end
    UI.camLot = lotId
    UI.dirty = true
end

-- A world (lot) was attached: save the old lot's camera, restore the new one's, reselect.
SS.On("worldAttached", function(w)
    if UI.camLot and UI.camLot ~= w.lot.id then UI.SaveCamera(UI.camLot) end
    if UI.camLot ~= w.lot.id then UI.RestoreCamera(w.lot.id) end
    UI.trend = {}
    UI.lastPick = nil
    UI.MirrorPrefs(w.root)
    UI.RestoreSelection()
    if UI.frame then
        UI.HideMenu()
        UI.RefreshPortrait()
        UI.RefreshPortraits()
        UI.RefreshToolbar()
        UI.RefreshPanel()
    end
end)

---------------------------------------------------------------------------
-- Clean (photo) view: hides every control; the lot fills the window. A small restore button
-- appears only while the mouse is over the top-right corner, so it stays out of screenshots.
---------------------------------------------------------------------------
function UI.CreateRestoreButton(f)
    local b = button(f, "Show controls", 96, 20, function() UI.SetCleanView(false) end, "Bring the controls back (P or Esc)")
    b:SetFrameStrata("DIALOG"); b:SetFrameLevel(90)
    b:SetPoint("TOPRIGHT", -6, -6)
    b:SetAlpha(0)
    b:HookScript("OnEnter", function(self) self:SetAlpha(1) end)
    b:HookScript("OnLeave", function(self) self:SetAlpha(0) end)
    b:Hide()
    UI.restoreBtn = b
end

function UI.SetCleanView(on)
    on = on and true or false
    if UI.clean == on then return end
    UI.clean = on
    UI.HideMenu()
    if on then
        for _, e in ipairs(UI.floating) do if e.frame:IsShown() then e.frame:Hide() end end
        if UI.help and UI.help:IsShown() then UI.help:Hide() end
        UI.Notice("Photo view: controls hidden. Take your screenshot with the game's screenshot key; P or Esc brings them back.")
    end
    UI.ApplyLayout()
    SS.Emit("cleanView", on)
end

---------------------------------------------------------------------------
-- Confirmation dialog (UI.Confirm). Parented to UIParent so it also works from slash commands.
---------------------------------------------------------------------------
function UI.ShowConfirm(text_, onYes, onNo, opts)
    if UI.Pref("noConfirm") then onYes(); return end
    opts = opts or {}
    local d = UI.confirmDlg
    if not d then
        d = K.Panel(UIParent, "Please confirm", 360, 150, { strata = "FULLSCREEN_DIALOG" })
        d:SetPoint("CENTER", 0, 80)
        d.msg = text(d.body, 12, "ink"); d.msg:SetPoint("TOPLEFT", 4, -4); d.msg:SetPoint("TOPRIGHT", -4, -4)
        d.yes = button(d.body, "Yes", 150, 24, function() local f = d.onYes; d.onYes, d.onNo = nil, nil; d:Hide(); if f then f() end end, "Do it (Enter)")
        d.yes:SetPoint("BOTTOMLEFT", 4, 4)
        d.no = button(d.body, "No", 150, 24, function() local f = d.onNo; d.onYes, d.onNo = nil, nil; d:Hide(); if f then f() end end, "Keep things as they are (Esc)")
        d.no:SetPoint("BOTTOMRIGHT", -4, 4)
        d:EnableKeyboard(true)
        d:SetScript("OnKeyDown", function(self, key)
            local handled = key == "ESCAPE" or key == "ENTER"
            if SS.Compat.caps.propagateKeyboard and not InCombatLockdown() then self:SetPropagateKeyboardInput(not handled) end
            if key == "ESCAPE" then d.no:Click() elseif key == "ENTER" then d.yes:Click() end
        end)
        d:Hide()
        UI.confirmDlg = d
    end
    if d:IsShown() and d.onNo then local f = d.onNo; d.onYes, d.onNo = nil, nil; f() end
    d.msg:SetText(text_ or "Are you sure?")
    d.yes:SetLabel(opts.yes or "Yes, do it")
    d.no:SetLabel(opts.no or "No")
    d.onYes, d.onNo = onYes, onNo
    d:Show()
    return d
end

-- Close any open dialog as "No" (combat, window closing).
function UI.CancelDialogs()
    local d = UI.confirmDlg
    if d and d:IsShown() then d.no:Click() end
end

---------------------------------------------------------------------------
-- Ledger (the careers module's "finances" tab replaces this simple view when registered)
---------------------------------------------------------------------------
function UI.OpenLedger()
    local fin = UI.tabs.finances
    if fin and not fin.fallback then
        if UI.mode ~= "live" then UI.SetMode("live") end
        UI.SelectTab("finances")
        return
    end
    local w = world()
    if not w then return end
    local p = UI.ledger
    if not p then
        p = K.Panel(UI.frame, "Household ledger", 420, 300, { close = true, movable = true, strata = "DIALOG", level = 70 })
        p:SetPoint("CENTER")
        p.sum = text(p.body, 11, "ink"); p.sum:SetPoint("TOPLEFT"); p.sum:SetPoint("TOPRIGHT")
        p.list = K.PagedList(p.body, 11, 20, function(r)
            r.when = text(r, 10, "inkSoft"); r.when:SetPoint("LEFT", 2, 0); r.when:SetWidth(110)
            r.what = text(r, 10, "ink"); r.what:SetPoint("LEFT", r.when, "RIGHT", 4, 0); r.what:SetPoint("RIGHT", -80, 0)
            r.amt = text(r, 10, "ink", "RIGHT"); r.amt:SetPoint("RIGHT", -2, 0); r.amt:SetWidth(76)
        end, function(r, e)
            r.when:SetText(UI.ClockText(e.t or 0))
            r.what:SetText((e.text or e.cat or "") .. (e.cat and e.text and ("  [" .. e.cat .. "]") or ""))
            r.amt:SetText((e.amount or 0) >= 0 and ("+" .. UI.Money(e.amount or 0)) or UI.Money(e.amount or 0))
            K.SetTextColor(r.amt, (e.amount or 0) >= 0 and "good" or "warn")
        end)
        p.list.frame:SetPoint("TOPLEFT", 0, -20); p.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)
        UI.RegisterFloating(p)
        UI.ledger = p
    end
    local items = {}
    local l = w.ledger or {}
    for n = #l, 1, -1 do items[#items + 1] = l[n] end
    local inc, out = 0, 0
    for _, e in ipairs(l) do if (e.amount or 0) >= 0 then inc = inc + e.amount else out = out - e.amount end end
    p.sum:SetText(string.format("Funds %s.  Recent income %s, spending %s (last %d entries).", UI.Money(w.money), UI.Money(inc), UI.Money(out), #l))
    p.list:SetItems(items)
    p:Show()
end

-- Saves: UI/Title.lua provides the full save manager; this is the minimal fallback.
function UI.OpenSaves()
    if UI.ShowSaves then UI.ShowSaves(); return end
    UI.Notice("Save manager unavailable.")
end
UI.SlotMenu = function() return UI.OpenSaves() end   -- the stage-1 name, kept for callers of the old shell

---------------------------------------------------------------------------
-- Help: compact topics plus a keybinding reference built from every registered mode
---------------------------------------------------------------------------
UI.HELP = {
    { id = "start", title = "Getting started", lines = {
        "SideStreet is a household life simulator in a window. Your people have eight needs, a personality and a life to run.",
        "Click a person (or a portrait at the bottom) to select them. Click furniture for its actions, or the floor to walk there.",
        "Menus explain what an action costs, whether it needs privacy, whether it can be reached and whether it is risky; unavailable entries say why.",
        "The panel at the bottom shows the selected person, their needs, the current action with its progress and the queue. Click a queued action to remove it.",
    } },
    { id = "needs", title = "Needs and mood", lines = {
        "Needs run from -100 to +100. Each bar shows the number, a trend arrow (^ rising, v falling, = steady), and a word; negative bars are hatched.",
        "Mood leans on the worst needs: a lovely room does not cancel starvation. A '!' badge on a portrait means an urgent need.",
        "Room follows the room the person is in right now: light, decoration, space, mess and broken things.",
    } },
    { id = "freewill", title = "Free Will and the inspector", lines = {
        "With Free Will on, idle residents choose what to do from what the house offers, weighted by their needs and personality.",
        "With it off they only follow your orders; accidents, collapse and other safety reactions still happen.",
        "The autonomy inspector (I, or 'Why?') shows what the selected person considered, the scores, the reasons and any failed routes.",
    } },
    { id = "time", title = "Time, speed and saving", lines = {
        "Pause (II), 1x, 3x and 10x are simulation speeds only. Music, captions and animations always run in real time.",
        "Emergencies and important arrivals drop the game back to normal speed and show a banner.",
        "Time only passes while the window is open. Closing it, or entering combat, pauses the house and stops its sounds. Nothing happens while you are offline.",
        "Save writes to one of three slots in SideStreet's saved data; a checkpoint is kept whenever the window closes. WoW writes all of it to disk when you log out or /reload.",
    } },
    { id = "access", title = "Accessibility", lines = {
        "Options: text size, high contrast, reduced motion and flashes, captions, and separate music, ambience, effects and voice switches.",
        "Captions show what people say next to them, whether or not voices are on.",
        "Destructive actions ask for confirmation. Pause is always one click (II) or one key (Space) away.",
        "Photo view (P) hides all controls so you can take a screenshot with the game's normal key.",
    } },
    { id = "commands", title = "Slash commands", lines = {
        "/sidestreet opens or closes the window.  /sidestreet diag: compatibility report.  /sidestreet perf: performance numbers (perf overlay toggles the overlay).",
        "/sidestreet pause, /sidestreet tutorial, /sidestreet reset (asks first).",
        "Debug: /sidestreet advance N runs N minutes of normal simulation.  /sidestreet money N works only when sandbox money is on (Options), and marks the save as sandbox.",
        "/sidestreet art tga|blp chooses the art file format when the art module supports it.",
    } },
}

function UI.KeyReference()
    local lines = { "Live mode (F1):" }
    for _, k in ipairs(UI.LIVE_KEYS) do lines[#lines + 1] = "   " .. k[1] .. "  -  " .. k[2] end
    for _, m in ipairs(UI.ModeList()) do
        if m ~= UI.liveMode then
            lines[#lines + 1] = ""
            lines[#lines + 1] = m.label .. " mode" .. (m.key and (" (" .. m.key .. ")") or "") .. ":"
            if m.keyHelp and #m.keyHelp > 0 then
                for _, k in ipairs(m.keyHelp) do lines[#lines + 1] = "   " .. tostring(k[1]) .. "  -  " .. tostring(k[2]) end
            elseif m.keys then
                local ks = {}
                for k in pairs(m.keys) do ks[#ks + 1] = k end
                table.sort(ks)
                lines[#lines + 1] = "   " .. (#ks > 0 and table.concat(ks, ", ") or "no extra keys") .. "  -  used by this mode's tools"
            else
                lines[#lines + 1] = "   no extra keys"
            end
            lines[#lines + 1] = "   Esc  -  cancel the current tool, then return to live mode"
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "SideStreet never changes your WoW key bindings. Keys it does not use pass through to the game while the window is open."
    return lines
end

function UI.HelpTopics()
    local list = {}
    for _, t in ipairs(UI.HELP) do list[#list + 1] = t end
    local modes = { id = "modes", title = "Modes", lines = {} }
    for _, m in ipairs(UI.ModeList()) do
        modes.lines[#modes.lines + 1] = m.label .. (m.key and (" (" .. m.key .. ")") or "") .. ": " .. (m.tip or "")
        for _, l in ipairs(m.help or {}) do modes.lines[#modes.lines + 1] = "   " .. l end
    end
    table.insert(list, 2, modes)
    local extra = {}
    for _, t in pairs(UI.helpTopics) do extra[#extra + 1] = t end
    table.sort(extra, function(a, b) if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) < (b.order or 50) end return a.id < b.id end)
    for _, t in ipairs(extra) do list[#list + 1] = t end
    list[#list + 1] = { id = "keys", title = "Keys (all modes)", lines = UI.KeyReference() }
    return list
end

function UI.CreateHelp(f)
    local h = K.Panel(f, "Help", 620, 380, { close = true, movable = true, strata = "DIALOG", level = 70 })
    h:SetPoint("CENTER", 0, 30)
    h.topicBtns = {}
    h.textFs = text(h.body, 11, "ink")
    h.textFs:SetPoint("TOPLEFT", 150, -2); h.textFs:SetPoint("BOTTOMRIGHT", -2, 2)
    h.textFs:SetJustifyV("TOP")
    h:Hide()
    UI.help = h
    UI.RegisterFloating(h)
end

function UI.ShowHelpTopic(id)
    local h = UI.help
    local topics = UI.HelpTopics()
    for _, b in ipairs(h.topicBtns) do b:Hide() end
    local chosen
    for n, t in ipairs(topics) do
        local b = h.topicBtns[n]
        if not b then
            b = button(h.body, "", 140, 20, function(self) UI.ShowHelpTopic(self.topicId) end)
            b:SetPoint("TOPLEFT", 0, -(n - 1) * 22)
            h.topicBtns[n] = b
        end
        b.topicId = t.id
        b:SetLabel(t.title)
        b:Show()
        b:SetActive(t.id == id)
        if t.id == id then chosen = t end
    end
    chosen = chosen or topics[1]
    h.topic = chosen.id
    h.textFs:SetText(table.concat(chosen.lines, "\n"))
end

function UI.ToggleHelp(topic)
    local h = UI.help
    if not h then return end
    if h:IsShown() and not topic then h:Hide(); return end
    UI.ShowHelpTopic(topic or h.topic or "start")
    h:Show()
end

---------------------------------------------------------------------------
-- Per-frame work
---------------------------------------------------------------------------
local acc, portAcc, actorAcc = 0, 0, 0
UI.REFRESH = 0.2

-- Real-time work other shell files need every frame while the window is open (banner pulse,
-- tutorial checks, perf overlay). Registered once at load; never per frame.
UI.frameHooks = UI.frameHooks or {}
function UI.OnEveryFrame(fn) UI.frameHooks[#UI.frameHooks + 1] = fn end

-- The title/save screen covers the lot: the household does not run behind it.
function UI.TitleUp() return UI.titleFrame ~= nil and UI.titleFrame:IsShown() end
function UI.OnUpdate(el)
    local P = SS.Perf
    local f0 = P and P.FrameBegin()
    local w = world()
    if w then
        -- the household only lives while the lot is on screen (not under the title screen, and
        -- never the placeholder household under the first-launch choice), and never in a mode
        -- that pauses it (a speed written straight into the world is caught here too)
        if not UI.TitleUp() and not SS.Boot.IsPlaceholder(w) then
            if w.speed ~= 0 and UI.CurrentMode().pausesSim then UI.resumeSpeed = w.speed; SS.Sim.SetSpeed(0) end
            SS.Sim.Update(el)
        end
        if UI.pan then
            local x, y = GetCursorPosition()
            local s = UI.frame:GetEffectiveScale()
            local dx, dy = (x - UI.pan.x) / s, (y - UI.pan.y) / s
            if math.abs(dx) + math.abs(dy) > 3 then UI.pan.moved = true end
            local cam = SS.Render.cam
            cam.panX, cam.panY = UI.pan.px + dx, UI.pan.py + dy
            UI.ApplyPan()
        end
        UI.EdgeScroll(el)
        if UI.viewport:IsShown() then
            if UI.dirty or math.abs(w.time - (SS.Render.layoutTime or -1e9)) >= 10 then
                UI.dirty = false
                SS.Render.Layout(w)
            end
            -- reduced detail (SS.Perf.quality): moving sprites update at most 30 times a second
            actorAcc = actorAcc + el
            if not (P and P.quality == "reduced") or actorAcc + 1e-6 >= 1 / ((P.CAPACITY and P.CAPACITY.actorFps) or 30) then
                actorAcc = 0
                SS.Render.UpdateActors(w, UI.selected)
            end
        end
        local mode = UI.CurrentMode()
        if mode.update then mode.update(el) end
        if mode.mouseMove and UI.viewport:IsVisible() and UI.viewport:IsMouseOver() then
            local px, py = SS.Render.CursorToCanvas()
            if px then
                local lv = SS.Render.cam.level or 0
                local wx, wy = SS.Render.FromCanvas(w, SS.Render.cam, px, py, lv)
                mode.mouseMove(wx, wy, lv)
            end
        end
    end
    local u0 = P and P.Begin()
    if w then UI.UpdateCaptions() end
    UI.OnNotice()
    local hooks = UI.frameHooks
    for n = 1, #hooks do hooks[n](el, w) end
    acc = acc + el
    portAcc = portAcc + el
    local interval = (P and P.quality == "reduced") and 0.5 or UI.REFRESH
    if acc > interval then
        acc = 0
        UI.RefreshToolbar()
        UI.RefreshPanel()
        if UI.OnSlowUpdate then UI.OnSlowUpdate(w) end
        if portAcc > 0.5 then portAcc = 0; UI.RefreshPortraits() end
        if UI.camDirty then UI.SaveCamera() end
    end
    if P then P.End("ui", u0); P.FrameEnd(f0, el) end
end

function UI.SaveGeometry()
    local f = UI.frame
    local db = SS.Save.DB()
    local cx, cy = f:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if cx and ux then db.ui.x, db.ui.y = cx - ux, cy - uy end
    db.ui.w, db.ui.h = f:GetWidth(), f:GetHeight()
end

function UI.Show()
    local f = UI.Create()
    if not f:IsShown() then
        f:Show()                              -- OnShow -> UI.OnShown
    elseif f:IsVisible() then
        UI.OnShown()                          -- already open: refresh
    end
end

-- The window became visible: opened, reopened, or the game's interface came back (Alt-Z, a
-- cinematic) while it was open. OnHide (UI.OnHidden) paused and silenced it; this resumes.
function UI.OnShown()
    UI.softHidden = nil
    UI.dirty = true
    local w = world()
    if w then
        if UI.camLot ~= w.lot.id then UI.RestoreCamera(w.lot.id) end
        if not UI.selected or not w.actors[UI.selected] then UI.RestoreSelection() end
        UI.MirrorPrefs(w.root)
    end
    UI.RefreshPortrait()
    UI.RefreshPortraits()
    UI.RefreshToolbar()
    UI.RefreshPanel()
    SS.Audio.Activate()
    local m = UI.CurrentMode()
    SS.Audio.SetMode((UI.titleFrame and UI.titleFrame:IsShown()) and "title" or (m.audio or m.name))
    UI.OnNotice()
end

-- Close the window for real (the X, /sidestreet, Esc, combat, a loading screen). reason: "combat",
-- "loading" or nil.
function UI.Hide(reason)
    local f = UI.frame
    if f and f:IsShown() then
        UI.hideReason = reason
        UI.closing = true
        f:Hide()               -- OnHide -> UI.OnHidden, when the window was on screen
        -- The client sends no OnHide to a frame that was already invisible (the whole game
        -- interface hidden with Alt-Z when combat starts): close it properly here instead.
        if UI.closing then UI.OnHidden() end
    end
end

-- OnHide. Two different things end up here:
--   * a real close (UI.Hide, or anything else that hid the window itself): leave the mode, answer
--     dialogs "No", release input, silence, remember the camera and keep a checkpoint;
--   * the game hiding its whole interface (Alt-Z, a cinematic) while the window stays open: the
--     window is still "shown" but not on screen. Nothing runs while it is invisible (no OnUpdate,
--     so no simulation) and the audio stops, but the mode, tool, dialogs and clean view are kept
--     and no checkpoint is written; OnShow picks everything up again when the interface returns.
function UI.OnHidden()
    local f = UI.frame
    UI.closing = nil
    UI.HideMenu()
    UI.pan = nil
    UI.lastPick = nil
    if SS.Compat.caps.propagateKeyboard and not InCombatLockdown() then f:SetPropagateKeyboardInput(true) end
    SS.Audio.Shutdown()
    if f:IsShown() then UI.softHidden = true; return end
    UI.softHidden = nil
    if UI.mode ~= "live" then UI.SetMode("live") end
    UI.CancelDialogs()
    if UI.clean then UI.clean = false; UI.ApplyLayout() end
    if UI.OnHideHooks then for _, fn in ipairs(UI.OnHideHooks) do fn() end end
    if UI.camLot then UI.SaveCamera(UI.camLot) end
    -- A checkpoint deep-copies the whole neighbourhood (about 9 ms for 14 furnished lots offline). When
    -- combat starts that would be a hitch at the worst moment, so it waits for the end of combat
    -- (or logout); the household is paused while hidden, so nothing is lost by waiting.
    if UI.hideReason == "combat" then
        SS.Boot.pendingCheckpoint = true
    else
        SS.Boot.Checkpoint()
    end
end

-- fn() runs when the window really closes (not when the game hides its whole interface).
function UI.OnHide(fn)
    UI.OnHideHooks = UI.OnHideHooks or {}
    UI.OnHideHooks[#UI.OnHideHooks + 1] = fn
end

function UI.IsShown() return UI.frame and UI.frame:IsShown() end
