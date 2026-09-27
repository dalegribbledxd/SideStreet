-- SideStreet options: display and accessibility, sound, game rules and window; and, at the end of
-- this file, the diagnostics panel (UI.Diag) that Options, the title screen and /sidestreet diag
-- and perf open.
--
-- Player preferences live in SideStreetDB.settings (UI.Pref / UI.SetPref in UI/Kit.lua) and apply
-- to every save, the title screen and the tutorial; they persist through WoW's SavedVariables.
-- Game rules that belong to one save (Free Will, sandbox money) live in that save's
-- root.settings and are marked "this save" in the panel.
--
-- Sound: SideStreet cannot set a volume per sound (PlaySoundFile has no gain), so there are no
-- fake sliders. What it genuinely controls: four category switches, and which WoW channel its
-- music plays on (Master, or Music so the game's own Music volume and mute apply to it). The
-- optional "pause the game's own music" switch is explicit and reversible (see Audio/Director).
local _, SS = ...
local UI = SS.UI
local K = UI.Kit
local O = UI.Options or {}
UI.Options = O

O.SECTIONS = { { "display", "Display" }, { "sound", "Sound" }, { "game", "Game" }, { "window", "Window" } }
O.W, O.H = 470, 430

local function world() return SS.Sim.world end
local function pct(v) return math.floor(v * 100 + 0.5) .. "%" end

local SOUND_TIPS = {
    music = "Mode music: neighbourhood, build, buy, live, venues and parties. Stops whenever the window closes.",
    ambience = "Background beds: street, evening, cafe, park, club and shops.",
    effects = "Interface cues and household sounds (doors, dishes, alarms). Emergency alarms are effects too.",
    voices = "People's babble. Captions show what they say whether or not voices are on.",
}
local SOUND_LABEL = { music = "Music", ambience = "Ambience", effects = "Effects and cues", voices = "Voices" }
local ROLE_FOR = { music = { "music" }, ambience = { "ambience" }, effects = { "cue", "sfx" }, voices = { "voice" } }

-- "1 of 11 produced" for a sound category (from the audio manifest).
function O.SoundCount(cat)
    local ix = SS.Audio and SS.Audio.Index and SS.Audio.Index()
    if not ix then return "" end
    local present, total = 0, 0
    for _, role in ipairs(ROLE_FOR[cat] or {}) do
        local r = ix.byRole[role]
        if r then present, total = present + r.present, total + r.total end
    end
    return string.format("%d of %d sounds produced", present, total)
end

local function addRow(sec, ctl, h)
    ctl:ClearAllPoints()
    ctl:SetPoint("TOPLEFT", sec, "TOPLEFT", 4, -sec.y)
    sec.y = sec.y + (h or 24)
    O.controls[#O.controls + 1] = ctl
    return ctl
end

local function note(sec, str, h)
    local fs = K.Text(sec, 10, "inkSoft")
    fs:SetPoint("TOPLEFT", sec, "TOPLEFT", 26, -sec.y + 2)
    fs:SetWidth(O.W - 60)
    fs:SetText(str or "")
    sec.y = sec.y + (h or 14)
    return fs
end

local function header(sec, str)
    local fs = K.Text(sec, 12, "accentDeep")
    fs:SetPoint("TOPLEFT", sec, "TOPLEFT", 2, -sec.y)
    fs:SetText(str)
    sec.y = sec.y + 18
    return fs
end

function O.BuildDisplay(sec)
    header(sec, "Reading and contrast")
    addRow(sec, K.Stepper(sec, "Text size", UI.TEXT_SCALES, function() return UI.Pref("textScale") end,
        function(v) UI.SetPref("textScale", v) end, pct, "Scales every SideStreet text. Some panels grow with it.", O.W - 40))
    addRow(sec, K.Check(sec, "High contrast", function() return UI.Pref("highContrast") end, function(v) UI.SetPref("highContrast", v) end,
        "Stronger text and edges and bolder need colours. Needs always also show numbers, arrows, words and a hatch pattern.", O.W - 40))
    addRow(sec, K.Check(sec, "Reduced motion and flashes", function() return UI.Pref("reducedMotion") end, function(v) UI.SetPref("reducedMotion", v) end,
        "No pulsing banners; the renderer and effects read this setting to calm animations and flashes.", O.W - 40))
    addRow(sec, K.Check(sec, "Dialogue captions", function() return UI.Pref("captions") end, function(v) UI.SetPref("captions", v) end,
        "Show what people say as text next to them, independent of voices.", O.W - 40))
    addRow(sec, K.Check(sec, "Hints on first visits", function() return UI.Pref("showHints") end, function(v) UI.SetPref("showHints", v) end,
        "The first time you open a mode, a one-line hint explains it.", O.W - 40))
    header(sec, "View")
    addRow(sec, K.Check(sec, "Scroll at the window edges", function() return UI.Pref("edgeScroll") end, function(v) UI.SetPref("edgeScroll", v) end,
        "Move the view when the pointer rests at the edge of the lot. Right-drag and the arrow keys always work.", O.W - 40))
    addRow(sec, K.Check(sec, "Performance overlay", function() return UI.Pref("perfOverlay") end, function(v)
        UI.SetPref("perfOverlay", v); if UI.Diag and UI.Diag.RefreshOverlay then UI.Diag.RefreshOverlay() end
    end, "Small live numbers in the corner of the lot: client framerate as reported, SideStreet's Lua time, sprites and memory.", O.W - 40))
    addRow(sec, K.Choice(sec, "Detail level", { { "auto", "Automatic" }, { "normal", "Full" }, { "reduced", "Reduced" } },
        function() return UI.Pref("detail") end, function(v) UI.SetPref("detail", v); if SS.Perf then SS.Perf.UpdateQuality() end end,
        { "Detail level", "Automatic lowers optional detail (captions, panel refresh rate, optional effects) when SideStreet's own Lua time stays high, and restores it when things calm down.",
            "Full and Reduced fix the level." }, O.W - 40))
end

function O.BuildSound(sec)
    header(sec, "Sound categories (saved for every game)")
    O.soundNotes = {}
    for _, cat in ipairs(UI.SOUND_CATS) do
        addRow(sec, K.Check(sec, SOUND_LABEL[cat], function() return UI.SoundOn(cat) end, function(v) UI.SetSound(cat, v) end,
            SOUND_TIPS[cat], O.W - 40), 20)
        O.soundNotes[cat] = note(sec, "", 16)
    end
    header(sec, "Where the music plays")
    addRow(sec, K.Choice(sec, "Music channel", { { "Master", "Master" }, { "Music", "Music" } },
        function() return UI.Pref("musicChannel") end, function(v) UI.SetPref("musicChannel", v) end,
        { "Music channel", "Master: SideStreet's music plays at the game's master volume, even if the game's music is off.",
            "Music: it follows the game's Music volume slider and Music switch (Game Menu > Options > Audio).",
            "SideStreet cannot set a volume of its own; these are the real controls." }, O.W - 40))
    addRow(sec, K.Check(sec, "Pause the game's own music while open", function() return UI.Pref("suppressGameMusic") end,
        function(v) UI.SetPref("suppressGameMusic", v) end,
        { "Pause the game's own music", "Only if you tick this: while SideStreet's music plays it turns the game's music setting off, and turns it back on when SideStreet closes.",
            "If you change the game's music setting yourself in the meantime, SideStreet leaves your choice alone." }, O.W - 40))
    O.nowPlaying = note(sec, "", 28)
    note(sec, "Changes of music are a short silence and a fresh start, never a crossfade: the client offers no fades or per-sound volume.", 28)
end

function O.BuildGame(sec)
    header(sec, "This save")
    O.fwCheck = addRow(sec, K.Check(sec, "Free Will", function() local w = world(); return w and w.settings.freeWill end,
        function(v) local w = world(); if w then w.settings.freeWill = v and true or false; UI.RefreshToolbar() end end,
        { "Free Will (this save)", "On: idle residents look after themselves.", "Off: they only follow your orders; safety reactions still happen." }, O.W - 40))
    O.sandboxCheck = addRow(sec, K.Check(sec, "Sandbox money", function() local w = world(); return w and w.settings.sandboxMoney end,
        function(v)
            local w = world()
            if not w then return end
            if v then
                UI.Confirm("Turn on sandbox money for this save? The debug command /sidestreet money can then add funds, and the save is marked as a sandbox game in the title bar.", function()
                    w.settings.sandboxMoney = true
                    O.Refresh()
                    UI.RefreshToolbar()
                end)
            else
                w.settings.sandboxMoney = false
                UI.RefreshToolbar()
            end
        end, { "Sandbox money (this save)", "Allows /sidestreet money N. Clearly labelled; off by default. Free building on community lots is handled by the build module." }, O.W - 40))
    O.sandboxNote = note(sec, "", 16)
    header(sec, "Every game")
    addRow(sec, K.Check(sec, "Pause when an emergency starts", function() return UI.Pref("pauseOnEmergency") end,
        function(v) UI.SetPref("pauseOnEmergency", v) end,
        "Emergencies always drop the game to normal speed; tick this to pause instead, so you can plan.", O.W - 40))
    addRow(sec, K.Check(sec, "Ask before destructive actions", function() return not UI.Pref("noConfirm") end,
        function(v)
            if v then UI.SetPref("noConfirm", false); return end
            UI.Confirm("Stop asking before selling, deleting, overwriting saves and similar actions? They will happen as soon as you click.", function()
                UI.SetPref("noConfirm", true)
                O.Refresh()
            end)
        end, "Selling, bulldozing, deleting households, overwriting or deleting saves ask first.", O.W - 40))
    note(sec, "Pause is always one click (II on the bar) or one key (Space) away.", 16)
end

function O.BuildWindow(sec)
    header(sec, "Window and view")
    local function btn(label, fnc, tip)
        local b = K.Button(sec, label, 220, 22, fnc, tip)
        addRow(sec, b, 26)
        return b
    end
    btn("Reset window size and place", function()
        local db = SS.Save.DB()
        db.ui.x, db.ui.y, db.ui.w, db.ui.h = 0, 0, 980, 680
        if UI.frame then
            UI.frame:ClearAllPoints(); UI.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0); UI.frame:SetSize(980, 680)
            UI.ApplyLayout()
        end
        UI.Notice("Window reset to 980 x 680 in the middle of the screen.")
    end, "Put the window back in the middle at its standard size")
    btn("Forget remembered cameras", function()
        SS.Save.DB().ui.cams = {}
        UI.Notice("Camera memory cleared; each lot opens with the standard view.")
    end, "SideStreet remembers rotation, zoom, walls, floor and position per lot")
    btn("Reset all options", function()
        UI.Confirm("Reset every option on this panel to its default? Saves and game rules are not touched.", function() O.ResetAll() end)
    end, "Text size, contrast, captions, sounds, hints and the rest go back to their defaults")
    btn("Diagnostics", function() if UI.Diag and UI.Diag.Toggle then UI.Diag.Toggle(true) end end,
        "Compatibility report and performance numbers (/sidestreet diag)")
    btn("Keys for every mode", function() UI.ToggleHelp("keys") end, "The keybinding reference")
    note(sec, "SideStreet remembers the window's size and place, the last selected person per household, and each lot's camera.", 28)
end

function O.ResetAll()
    local s = UI.PrefsTable()
    if not s then return end
    for k in pairs(UI.PREF_DEFAULTS) do s[k] = nil end
    for _, c in ipairs(UI.SOUND_CATS) do s.sound[c] = true end
    local w = world()
    if w then UI.MirrorPrefs(w.root) end
    K.ApplyTheme()
    for _, key in ipairs({ "sound.music", "sound.ambience", "sound.effects", "sound.voices", "musicChannel", "suppressGameMusic" }) do
        SS.Emit("settings", key, nil)
    end
    SS.Emit("settings", "reset", nil)
    if UI.ApplyLayout then UI.ApplyLayout() end
    O.Refresh()
    UI.Notice("Options reset to their defaults.")
end

function O.Create()
    if O.frame then return O.frame end
    local p = K.Panel(UI.frame, "Options", O.W, O.H, { close = true, movable = true, strata = "DIALOG", level = 80 })
    p:SetPoint("CENTER", 0, 20)
    O.frame = p
    O.controls = {}
    O.tabs, O.sections = {}, {}
    local prev
    for _, sd in ipairs(O.SECTIONS) do
        local id = sd[1]
        local b = K.Button(p.body, sd[2], 90, 20, function() O.Show(id) end, sd[2] .. " options")
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 0, 0) end
        prev = b
        O.tabs[id] = b
        local sec = CreateFrame("Frame", nil, p.body)
        sec:SetPoint("TOPLEFT", 0, -26); sec:SetPoint("BOTTOMRIGHT", 0, 0)
        sec.y = 4
        sec:Hide()
        O.sections[id] = sec
    end
    O.BuildDisplay(O.sections.display)
    O.BuildSound(O.sections.sound)
    O.BuildGame(O.sections.game)
    O.BuildWindow(O.sections.window)
    UI.RegisterFloating(p)
    p:Hide()
    O.Show("display")
    return p
end

function O.Show(id)
    O.section = id
    for sid, sec in pairs(O.sections) do sec:SetShown(sid == id) end
    for sid, b in pairs(O.tabs) do b:SetActive(sid == id) end
    O.Refresh()
end

function O.Refresh()
    if not O.frame then return end
    for _, c in ipairs(O.controls) do if c.Refresh then c:Refresh() end end
    local w = world()
    local why = "Start or continue a game first: this rule belongs to a save."
    O.fwCheck:SetUsable(w ~= nil, why)
    O.sandboxCheck:SetUsable(w ~= nil, why)
    local used = w and w.root.shell and w.root.shell.sandboxUsed
    O.sandboxNote:SetText(used and "This save has used sandbox money." or "")
    for _, cat in ipairs(UI.SOUND_CATS) do
        local fs = O.soundNotes[cat]
        if fs then fs:SetText(O.SoundCount(cat) .. (UI.SoundOn(cat) and "" or "  (muted)")) end
    end
    if SS.Audio and SS.Audio.Status and O.nowPlaying then
        local s = SS.Audio.Status()
        local line
        if not s.active then line = "Sound plays only while the window is open."
        elseif not UI.SoundOn("music") then line = "Music is switched off."
        elseif s.track then line = "Now playing: " .. s.track .. " (" .. tostring(s.playlist) .. " playlist)."
        else line = "Silent: no finished track exists for this mode yet (the soundtrack is planned)." end
        O.nowPlaying:SetText(line)
    end
end

function UI.ToggleOptions(section)
    local p = O.Create()
    if p:IsShown() and not section then p:Hide(); return end
    O.Show(section or O.section or "display")
    p:Show()
end

SS.On("settings", function() if O.frame and O.frame:IsShown() then O.Refresh() end end)
SS.On("worldAttached", function() if O.frame and O.frame:IsShown() then O.Refresh() end end)

---------------------------------------------------------------------------
-- Diagnostics (UI.Diag). Kept in this file (it was UI/Diag.lua): the module's file list in the
-- brief names Options, and the diagnostics panel is reached from Options > Window.
-- The in-window panel behind /sidestreet diag and /sidestreet perf, and
-- the optional on-screen performance overlay.
--
-- Pages: Compatibility (SS.Compat checks, each with what to do), Performance (SS.Perf numbers,
-- measured, never estimated), Audio (the director's status and manifest counts), Data (saves,
-- registries, bounded buffers). Lines are shown through a paged list of pooled rows.
---------------------------------------------------------------------------
do
    local D = UI.Diag or {}
    UI.Diag = D

    D.ROWS = 20
    D.PAGES = { { "compat", "Compatibility" }, { "perf", "Performance" }, { "audio", "Audio" }, { "data", "Data" } }

    local function world() return SS.Sim.world end
    local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

    -- Break long lines so the paged list can show them in fixed rows.
    local function wrapInto(out, line, width)
        width = width or 96
        line = tostring(line)
        while #line > width do
            local cut = line:sub(1, width):match("^.*()%s") or width
            if cut < width * 0.5 then cut = width end
            out[#out + 1] = line:sub(1, cut)
            line = "      " .. line:sub(cut + 1):gsub("^%s+", "")
        end
        out[#out + 1] = line
    end

    function D.DataLines()
        local lines = {}
        local db = SS.Save.DB()
        local used = 0
        for s = 1, SS.Save.SLOTS do if db.slots[s] and db.slots[s].world then used = used + 1 end end
        lines[#lines + 1] = string.format("Saves: %d of %d slots used; checkpoint %s; previous-good copies: %s%s.", used, SS.Save.SLOTS,
            db.checkpoint and db.checkpoint.world and "kept" or "none", db.lastGood and "slot" or "", db.checkpointPrev and " checkpoint" or "")
        lines[#lines + 1] = "Disk: WoW writes SideStreet's saved data at logout or /reload; a client crash before that loses the newest changes."
        local w = world()
        if w then
            lines[#lines + 1] = string.format("Game: %s%s, %s household, schema %s.", tostring(w.lot.address or w.lot.id),
                w.root.tutorial and " (tutorial practice household)" or "", w.household and w.household.name or "no", tostring(w.root.schema))
            lines[#lines + 1] = string.format("Bounded lists: journal %d of %d, ledger %d of 120, notices waiting %d of %d, log %d of 200.",
                type(w.journal) == "table" and #w.journal or 0, SS.Journal and SS.Journal.CAP or 40, type(w.ledger) == "table" and #w.ledger or 0,
                #UI.noticeQueue, UI.NOTICE_CAP, count(SS.logBuf))
        end
        lines[#lines + 1] = string.format("Registries: %d modes, %d tabs, %d menu kinds, %d toolbar buttons, %d help topics.",
            count(UI.modes), count(UI.tabs), count(UI.menuProviders), count(UI.toolbarExtras), count(UI.helpTopics))
        local modes = {}
        for name in pairs(UI.modes) do modes[#modes + 1] = name end
        table.sort(modes)
        lines[#lines + 1] = "Modes: live" .. (#modes > 0 and (", " .. table.concat(modes, ", ")) or " only (other modes arrive with their modules)")
        local fonts, texes = K.RegistryCounts()
        lines[#lines + 1] = string.format("Interface pools: %d captions allocated (cap %d), %d menu rows, %d themed texts, %d themed textures.",
            UI.captionPool and #UI.captionPool or 0, UI.CAPTION_CAP, UI.menu and #UI.menu.buttons or 0, fonts, texes)
        local cams = type(db.ui.cams) == "table" and count(db.ui.cams) or 0
        lines[#lines + 1] = string.format("Remembered cameras: %d of %d lots.", cams, UI.CAM_CAP or 40)
        local tu = SS.Tutorial and SS.Tutorial.State and SS.Tutorial.State()
        if tu then lines[#lines + 1] = string.format("Tutorial: step %d of %d%s%s.", tu.step, tu.total, tu.active and ", running" or "", tu.done and ", completed before" or "") end
        local E = UI.Emergency
        if E and E.history and #E.history > 0 then
            lines[#lines + 1] = "Recent alerts:"
            for n = #E.history, math.max(1, #E.history - 4), -1 do
                local h = E.history[n]
                lines[#lines + 1] = "   " .. h.severity .. ": " .. h.text
            end
        end
        lines[#lines + 1] = "Recent log (newest last):"
        local buf, pos = SS.logBuf, SS.logPos or 0
        local cap = 200
        for k = 7, 0, -1 do
            local idx = ((pos - 1 - k) % cap) + 1
            if buf[idx] then lines[#lines + 1] = "   " .. buf[idx] end
        end
        return lines
    end

    function D.Lines(page)
        local raw
        if page == "compat" then raw = SS.Compat.Report()
        elseif page == "perf" then raw = SS.Perf.Report()
        elseif page == "audio" then raw = SS.Audio.Report and SS.Audio.Report() or { "Audio report unavailable." }
        else raw = D.DataLines() end
        local out = {}
        for _, l in ipairs(raw) do wrapInto(out, l, 100) end
        return out
    end

    function D.Create()
        if D.frame then return D.frame end
        local p = K.Panel(UI.frame, "Diagnostics", 640, 420, { close = true, movable = true, strata = "DIALOG", level = 88 })
        p:SetPoint("CENTER", 0, 0)
        D.frame = p
        D.tabs = {}
        local prev
        for _, pd in ipairs(D.PAGES) do
            local id = pd[1]
            local b = K.Button(p.body, pd[2], 100, 20, function() D.Show(id) end, pd[2])
            if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 0, 0) end
            prev = b
            D.tabs[id] = b
        end
        p.refresh = K.Button(p.body, "Refresh", 70, 20, function() if D.page == "compat" then SS.Compat.Probe(true) end; D.Show(D.page) end,
            "Measure again (compatibility probes run again too)")
        p.refresh:SetPoint("TOPRIGHT", 0, 0)
        p.reset = K.Button(p.body, "Reset counters", 100, 20, function() SS.Perf.Reset(); D.Show("perf") end, "Start the performance counters from zero")
        p.reset:SetPoint("RIGHT", p.refresh, "LEFT", -4, 0)
        p.overlay = K.Button(p.body, "Overlay", 70, 20, function() UI.SetPref("perfOverlay", not UI.Pref("perfOverlay")); D.RefreshOverlay(); D.Show(D.page) end,
            "Show or hide the small performance overlay on the lot")
        p.overlay:SetPoint("RIGHT", p.reset, "LEFT", -4, 0)
        p.list = K.PagedList(p.body, D.ROWS, 16, function(r)
            r.text = K.Text(r, 10, "ink"); r.text:SetPoint("LEFT", 2, 0); r.text:SetPoint("RIGHT", -2, 0)
        end, function(r, line)
            r.text:SetText(line)
            local mark = line:match("^%[(%u+)%]")
            K.SetTextColor(r.text, mark == "FAIL" and "warn" or mark == "WARN" and "warn" or (line:find("^%s+%->") and "accentDeep") or "ink")
        end)
        p.list.frame:SetPoint("TOPLEFT", 0, -26); p.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)
        UI.RegisterFloating(p)
        p:Hide()
        return p
    end

    function D.Show(page)
        D.page = page or D.page or "compat"
        for id, b in pairs(D.tabs) do b:SetActive(id == D.page) end
        D.frame.overlay:SetActive(UI.Pref("perfOverlay"))
        D.frame.list:SetItems(D.Lines(D.page))
    end

    function D.Toggle(force, page)
        if not UI.frame then UI.Create() end
        local p = D.Create()
        if p:IsShown() and not force then p:Hide(); return end
        p:Show()
        D.Show(page or D.page or "compat")
    end

    ---------------------------------------------------------------------------
    -- Overlay: a few live lines in the lot's bottom-left corner, updated once a second (memory
    -- every five seconds, because reading it scans every addon).
    ---------------------------------------------------------------------------
    function D.CreateOverlay()
        if D.ov then return D.ov end
        local o = CreateFrame("Frame", nil, UI.viewport)
        o:SetFrameStrata("DIALOG"); o:SetFrameLevel(30)
        o:SetPoint("BOTTOMLEFT", 6, 6); o:SetSize(300, 78)
        o.bg = K.Tex(o, "BACKGROUND", { 0, 0, 0, 0.6 }); o.bg:SetAllPoints()
        o.lines = {}
        for n = 1, 5 do
            local fs = K.Text(o, 10, "paper"); fs:SetPoint("TOPLEFT", 6, -4 - (n - 1) * 14); fs:SetPoint("RIGHT", -6, 0)
            o.lines[n] = fs
        end
        o:EnableMouse(false)
        o:Hide()
        D.ov = o
        return o
    end

    function D.RefreshOverlay()
        if not UI.viewport then return end
        local o = D.CreateOverlay()
        o:SetShown(UI.Pref("perfOverlay") and not UI.clean)
        D.UpdateOverlay(true)
    end

    function D.UpdateOverlay(memToo)
        local o = D.ov
        if not o or not o:IsShown() then return end
        local s = SS.Perf.Snapshot()
        o.lines[1]:SetText(s.fps and string.format("Client: %.0f fps (GetFramerate)", s.fps) or "Client framerate: not available")
        o.lines[2]:SetText(string.format("SideStreet: %.1f updates/s, %.2f ms each (max %.1f)", s.updateRate, s.frameMs, s.maxFrameMs))
        local sim, lay, act, ui = s.subs.sim, s.subs.layout, s.subs.actors, s.subs.ui
        o.lines[3]:SetText(string.format("ms/s  sim %.1f  layout %.1f  actors %.1f  ui %.1f", sim.msPerSec, lay.msPerSec, act.msPerSec, ui.msPerSec))
        o.lines[4]:SetText(string.format("Sprites %s/%s  people %s  objects %s  detail %s", tostring(s.visibleSprites or "-"), tostring(s.allocatedSprites or "-"),
            tostring(s.actors or "-"), tostring(s.objects or "-"), s.quality))
        if memToo then
            local kb = SS.Compat.MemoryKB()
            D.memText = kb and string.format("Lua memory (SideStreet only): %.0f KB", kb) or "Lua memory: not available"
        end
        o.lines[5]:SetText(D.memText or "")
    end

    local acc, memAcc = 0, 0
    if UI.OnEveryFrame then
        UI.OnEveryFrame(function(el)
            if not D.ov or not D.ov:IsShown() then return end
            acc, memAcc = acc + el, memAcc + el
            if acc < 1 then return end
            acc = 0
            local mem = memAcc >= 5
            if mem then memAcc = 0 end
            D.UpdateOverlay(mem)
        end)
    end
    if UI.OnCreate then UI.OnCreate(function() if UI.Pref("perfOverlay") then D.RefreshOverlay() end end) end
    SS.On("cleanView", function() if D.ov then D.RefreshOverlay() end end)
    SS.On("settings", function(key) if key == "perfOverlay" or key == "reset" then D.RefreshOverlay() end end)
end
