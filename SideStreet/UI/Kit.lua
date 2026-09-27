-- SideStreet UI kit: the shared look (warm cream panels, teal controls, wood trim), player
-- preferences (text scale, high contrast, reduced motion, captions, sound categories), widget
-- builders, and the extension registries other modules use to add modes (build, buy,
-- neighbourhood, creator), panel tabs, context-menu entries, toolbar buttons and help topics.
-- Everything here is created lazily; nothing touches WoW frames at load time.
local _, SS = ...
local UI = SS.UI or {}
SS.UI = UI
local K = {}
UI.Kit = K

---------------------------------------------------------------------------
-- Palette. K.COL keeps its original keys (other modules read them at creation time).
-- K.C(name) returns the colour for the current contrast setting; widgets built with colour
-- *names* are re-skinned when the player switches high contrast on or off.
---------------------------------------------------------------------------
K.COL = {
    bg = { 0.16, 0.18, 0.17, 0.97 },          -- window back, behind the lot
    panel = { 0.95, 0.91, 0.82, 1 },          -- cream paper
    panelDark = { 0.87, 0.81, 0.69, 1 },      -- deeper cream (headers, wells)
    ink = { 0.20, 0.16, 0.12 }, inkSoft = { 0.42, 0.36, 0.29 },
    paper = { 1, 0.96, 0.88 },                -- light text on dark
    accent = { 0.16, 0.50, 0.48, 1 },         -- teal controls
    accentHi = { 0.25, 0.64, 0.60, 1 },
    accentDeep = { 0.10, 0.32, 0.31, 1 },     -- title bar
    trim = { 0.45, 0.32, 0.21, 1 },           -- wood trim around panels
    sun = { 0.96, 0.74, 0.30, 1 },            -- selection / attention
    disabled = { 0.58, 0.57, 0.53, 1 },
    warn = { 0.86, 0.38, 0.26 }, good = { 0.36, 0.66, 0.32 }, barBg = { 0.33, 0.29, 0.25, 1 },
    danger = { 0.70, 0.20, 0.18, 1 }, white = { 1, 1, 1 },
    shade = { 0, 0, 0, 0.55 },                -- dim overlays
    dark = { 0.11, 0.12, 0.12, 0.96 },        -- menus, tooltips-like panels
}
local COL = K.COL
-- High contrast: stronger ink and edges; nothing in the game relies on colour alone anyway.
K.HC = {
    panel = { 1, 1, 1, 1 }, panelDark = { 0.86, 0.86, 0.86, 1 }, ink = { 0, 0, 0 }, inkSoft = { 0.12, 0.12, 0.12 },
    paper = { 1, 1, 1 }, accent = { 0, 0.30, 0.30, 1 }, accentHi = { 0, 0.46, 0.46, 1 }, accentDeep = { 0, 0.18, 0.18, 1 },
    trim = { 0, 0, 0, 1 }, sun = { 1, 0.85, 0, 1 }, warn = { 0.90, 0.10, 0 }, good = { 0, 0.52, 0 },
    barBg = { 0.08, 0.08, 0.08, 1 }, danger = { 0.85, 0, 0, 1 }, bg = { 0, 0, 0, 1 }, dark = { 0, 0, 0, 0.98 },
}

function K.C(name)
    if type(name) == "table" then return name end
    if UI.Pref and UI.Pref("highContrast") and K.HC[name] then return K.HC[name] end
    return COL[name] or COL.white
end

local skinned = setmetatable({}, { __mode = "k" })   -- texture -> colour name
local fonts = setmetatable({}, { __mode = "k" })     -- fontstring -> { size, colourName }

function K.Tex(parent, layer, c, sub)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    if c then
        if type(c) == "string" then skinned[t] = c end
        local col = K.C(c)
        t:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
    end
    return t
end

-- Font size honours the player's text-scale setting (accessibility). c may be a colour
-- table or a colour name; named colours follow the high-contrast setting.
function K.Text(parent, size, c, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local font = fs:GetFont() or STANDARD_TEXT_FONT
    fs.ssFont = font
    fonts[fs] = { size or 12, type(c) == "string" and c or nil }
    fs:SetFont(font, K.ScaledSize(size or 12), "")
    local col = K.C(c or "ink")
    fs:SetTextColor(col[1], col[2], col[3])
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

function K.ScaledSize(size)
    local scale = (UI.Pref and UI.Pref("textScale")) or 1
    return math.floor(size * scale + 0.5)
end

-- Change a registered font string's base size later (keeps text scaling).
function K.SetTextSize(fs, size)
    local e = fonts[fs]
    if e then e[1] = size end
    fs:SetFont(fs.ssFont or (fs:GetFont()), K.ScaledSize(size), "")
end

function K.SetTextColor(fs, name)
    local e = fonts[fs]
    if e then e[2] = type(name) == "string" and name or nil end
    local col = K.C(name)
    fs:SetTextColor(col[1], col[2], col[3])
end

-- Re-apply text scale and named colours everywhere (after an Options change).
function K.ApplyTheme()
    for fs, e in pairs(fonts) do
        fs:SetFont(fs.ssFont or (fs:GetFont()), K.ScaledSize(e[1]), "")
        if e[2] then local col = K.C(e[2]); fs:SetTextColor(col[1], col[2], col[3]) end
    end
    for t, name in pairs(skinned) do
        local col = K.C(name)
        t:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
    end
    SS.Emit("uiTheme")
end

-- Base sizes of every live SideStreet font string: count, smallest, largest (readability tests).
function K.FontStats()
    local n, lo, hi = 0, nil, nil
    for _, e in pairs(fonts) do
        n = n + 1
        if not lo or e[1] < lo then lo = e[1] end
        if not hi or e[1] > hi then hi = e[1] end
    end
    return n, lo, hi
end

-- Counts for leak tests and diagnostics.
function K.RegistryCounts()
    local nf, nt = 0, 0
    for _ in pairs(fonts) do nf = nf + 1 end
    for _ in pairs(skinned) do nt = nt + 1 end
    return nf, nt
end

---------------------------------------------------------------------------
-- Player preferences (SideStreetDB.settings): apply to every save, the title screen and the
-- tutorial. They are mirrored into the running world's root.settings so gameplay modules
-- (renderer, effects) can read world.settings.reducedMotion etc. as ARCHITECTURE §5 says.
-- World rules (Free Will, sandbox money, auto-slow) stay per save in root.settings.
---------------------------------------------------------------------------
UI.PREF_DEFAULTS = {
    textScale = 1, highContrast = false, reducedMotion = false, captions = true, edgeScroll = false,
    perfOverlay = false, noConfirm = false, musicChannel = "Master", suppressGameMusic = false,
    showHints = true, panelCollapsed = false, pauseOnEmergency = false, detail = "auto",
}
UI.SOUND_CATS = { "music", "ambience", "effects", "voices" }
UI.TEXT_SCALES = { 0.85, 1, 1.15, 1.3, 1.5 }
local MIRRORED = { textScale = true, highContrast = true, reducedMotion = true, captions = true }

local function dbSettings()
    if not (SS.Save and SS.Save.DB) then return nil end
    local s = SS.Save.DB().settings
    if type(s.sound) ~= "table" then
        -- first run: carry over the stage-1 world toggles if a world is running
        local w = SS.Sim and SS.Sim.world
        local ws = w and w.settings or {}
        s.sound = { music = ws.music ~= false, ambience = true, effects = ws.effects ~= false, voices = true }
    end
    for _, c in ipairs(UI.SOUND_CATS) do if type(s.sound[c]) ~= "boolean" then s.sound[c] = true end end
    return s
end
UI.PrefsTable = dbSettings

function UI.Pref(key)
    local s = dbSettings()
    local v = s and s[key]
    if v == nil then v = UI.PREF_DEFAULTS[key] end
    return v
end

function UI.SetPref(key, value)
    local s = dbSettings()
    if not s then return end
    s[key] = value
    local w = SS.Sim and SS.Sim.world
    if w and MIRRORED[key] then w.settings[key] = value end
    SS.Emit("settings", key, value)
    if key == "textScale" or key == "highContrast" then K.ApplyTheme() end
end

function UI.SoundOn(cat)
    local s = dbSettings()
    if not s then return true end
    return s.sound[cat] ~= false
end

function UI.SetSound(cat, on)
    local s = dbSettings()
    if not s then return end
    s.sound[cat] = on and true or false
    local w = SS.Sim and SS.Sim.world
    if w then UI.MirrorPrefs(w.root or w) end
    SS.Emit("settings", "sound." .. cat, on)
end

-- Copy the player's preferences into a save root's settings (called on every attach).
function UI.MirrorPrefs(root)
    local s = dbSettings()
    if not s or not root then return end
    root.settings = root.settings or {}
    for k in pairs(MIRRORED) do root.settings[k] = UI.Pref(k) end
    root.settings.sound = root.settings.sound or {}
    for _, c in ipairs(UI.SOUND_CATS) do root.settings.sound[c] = s.sound[c] end
    root.settings.music, root.settings.effects = s.sound.music, s.sound.effects -- stage-1 keys
end

-- Per-save rules live in root.settings; repair them on load (ARCHITECTURE §5 validators).
if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        local st = type(root.settings) == "table" and root.settings or {}
        root.settings = st
        if type(st.freeWill) ~= "boolean" then st.freeWill = true end
        if type(st.autoSlow) ~= "boolean" then st.autoSlow = true end
        if st.sandboxMoney ~= nil and type(st.sandboxMoney) ~= "boolean" then st.sandboxMoney = false end
        if type(st.sound) ~= "table" then st.sound = {} end
        root.shell = type(root.shell) == "table" and root.shell or {}
        if root.shell.sandboxUsed ~= nil and type(root.shell.sandboxUsed) ~= "boolean" then root.shell.sandboxUsed = true end
        return true
    end)
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------
-- Tooltip: text, or a function returning text or { title, line, line... }. Disabled controls
-- append the reason they are unavailable.
function K.ShowTip(owner, content, anchor)
    if type(content) == "function" then content = content(owner) end
    local why = owner.ssDisabled and owner.ssWhy
    if (not content or content == "") and not why then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_TOP")
    if type(content) == "table" then
        GameTooltip:SetText(content[1] or "", 1, 0.95, 0.85, 1, true)
        for n = 2, #content do GameTooltip:AddLine(content[n], 0.9, 0.9, 0.9, true) end
    else
        GameTooltip:SetText(content or "", 1, 1, 1, 1, true)
    end
    if why then GameTooltip:AddLine("Unavailable: " .. why, 1, 0.55, 0.45, true) end
    GameTooltip:Show()
end

function K.Tooltip(owner, textOrFn, anchor)
    owner.ssTip = textOrFn
    owner:SetScript("OnEnter", function(self) K.ShowTip(self, self.ssTip, anchor) end)
    owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Flat button. b:SetActive(on) highlights; b:SetUsable(on, reason) greys out and explains.
function K.Button(parent, label, w, h, onClick, tip)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h or 22)
    b.edge = K.Tex(b, "BACKGROUND", "accentDeep"); b.edge:SetAllPoints()
    b.bg = K.Tex(b, "BORDER", "accent"); b.bg:SetPoint("TOPLEFT", 1, -1); b.bg:SetPoint("BOTTOMRIGHT", -1, 2)
    b.hi = K.Tex(b, "HIGHLIGHT", "accentHi"); b.hi:SetPoint("TOPLEFT", 1, -1); b.hi:SetPoint("BOTTOMRIGHT", -1, 2)
    b.label = K.Text(b, 11, "paper", "CENTER"); b.label:SetPoint("CENTER", 0, 1); b.label:SetText(label or "")
    -- active state is also shown by an underline, not colour alone (made up front, so toggling
    -- a button never creates regions)
    b.ul = K.Tex(b, "OVERLAY", "sun"); b.ul:SetPoint("BOTTOMLEFT", 3, 3); b.ul:SetPoint("BOTTOMRIGHT", -3, 3); b.ul:SetHeight(2); b.ul:Hide()
    b:SetScript("OnClick", function(self, btn)
        if self.ssDisabled then
            if self.ssWhy and UI.Notice then UI.Notice(self.ssWhy) end
            return
        end
        if SS.Audio and SS.Audio.Cue then SS.Audio.Cue("click") end
        if onClick then onClick(self, btn) end
    end)
    K.Tooltip(b, tip)
    function b:SetActive(on)
        self.ssActive = on
        local c = K.C(self.ssDisabled and "disabled" or on and "accentHi" or "accent")
        self.bg:SetColorTexture(c[1], c[2], c[3], 1)
        self.ul:SetShown(on and true or false)
    end
    function b:SetUsable(on, why)
        self.ssDisabled = not on
        self.ssWhy = (not on) and why or nil
        self:SetActive(self.ssActive)
        self.label:SetAlpha(on and 1 or 0.7)
    end
    function b:SetLabel(t) self.label:SetText(t) end
    -- Optional art icon from SS.Art.icons[name] (docs/art_requests/ui-shell.md lists the names).
    -- Without that art the button keeps its text exactly as before. replaceLabel: the icon stands
    -- in for a short label (the tooltip still names the action); otherwise it sits left of it.
    function b:SetIcon(name, replaceLabel)
        local sprite = name and SS.Art and SS.Art.icons and SS.Art.icons[name]
        if not (sprite and SS.Art.sprites and SS.Art.sprites[sprite]) then
            if self.icon then self.icon:Hide() end
            self.label:ClearAllPoints(); self.label:SetPoint("CENTER", 0, 1); self.label:Show()
            return false
        end
        self.icon = self.icon or self:CreateTexture(nil, "OVERLAY")
        local h = math.max(8, (self:GetHeight() or 20) - 6)
        K.SetSprite(self.icon, sprite, h, h)
        self.icon:ClearAllPoints()
        if replaceLabel then
            self.icon:SetPoint("CENTER", 0, 1); self.label:Hide()
        else
            self.icon:SetPoint("LEFT", 3, 1)
            self.label:ClearAllPoints(); self.label:SetPoint("CENTER", h / 2, 1); self.label:Show()
        end
        return true
    end
    return b
end

-- An art icon where one exists, else the text glyph. t: a texture made up front; fs: the glyph.
function K.IconOrGlyph(t, fs, iconName, size)
    if iconName and K.SetIcon(t, iconName, size, size) then fs:Hide(); return true end
    t:Hide(); fs:Show()
    return false
end

-- Framed panel: cream body, wood trim, a title strip and an optional close button.
--   local p = K.Panel(parent, "Journal", 420, 300, { close = true, movable = true, strata = "DIALOG" })
--   p.body is the content area.
function K.Panel(parent, title, w, h, opts)
    opts = opts or {}
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(w, h)
    if opts.strata then p:SetFrameStrata(opts.strata) end
    if opts.level then p:SetFrameLevel(opts.level) end
    p.trim = K.Tex(p, "BACKGROUND", opts.dark and "trim" or "trim"); p.trim:SetAllPoints()
    p.bgTex = K.Tex(p, "BORDER", opts.dark and "dark" or "panel")
    p.bgTex:SetPoint("TOPLEFT", 2, -2); p.bgTex:SetPoint("BOTTOMRIGHT", -2, 2)
    p:EnableMouse(true)
    local th = title and 22 or 0
    if title then
        p.head = K.Tex(p, "ARTWORK", "accentDeep")
        p.head:SetPoint("TOPLEFT", 2, -2); p.head:SetPoint("TOPRIGHT", -2, -2); p.head:SetHeight(20)
        p.title = K.Text(p, 12, "paper"); p.title:SetPoint("TOPLEFT", 8, -5); p.title:SetText(title)
        if opts.movable then
            p:SetMovable(true); p:RegisterForDrag("LeftButton")
            p:SetScript("OnDragStart", function(self) self:StartMoving() end)
            p:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        end
    end
    if opts.close then
        p.close = K.Button(p, "x", 20, 18, function() p:Hide() end, "Close (Esc)")
        p.close:SetPoint("TOPRIGHT", -3, -3)
    end
    p.body = CreateFrame("Frame", nil, p)
    p.body:SetPoint("TOPLEFT", 8, -(th + 6)); p.body:SetPoint("BOTTOMRIGHT", -8, 8)
    return p
end

-- Toggle with a box and an explicit ON/OFF word (state never shown by colour alone).
function K.Check(parent, label, get, set, tip, w)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 240, 20)
    b.box = K.Tex(b, "ARTWORK", "barBg"); b.box:SetSize(16, 16); b.box:SetPoint("LEFT", 0, 0)
    b.fill = K.Tex(b, "OVERLAY", "accentHi"); b.fill:SetSize(10, 10); b.fill:SetPoint("CENTER", b.box, "CENTER")
    b.state = K.Text(b, 10, "inkSoft"); b.state:SetPoint("RIGHT", -2, 0); b.state:SetWidth(30)
    b.label = K.Text(b, 11, "ink"); b.label:SetPoint("LEFT", b.box, "RIGHT", 6, 0); b.label:SetPoint("RIGHT", b.state, "LEFT", -4, 0)
    b.label:SetText(label)
    function b:Refresh()
        local on = get() and true or false
        self.fill:SetShown(on)
        self.state:SetText(on and "ON" or "OFF")
    end
    b:SetScript("OnClick", function(self)
        if self.ssDisabled then if self.ssWhy and UI.Notice then UI.Notice(self.ssWhy) end; return end
        set(not get())
        if SS.Audio and SS.Audio.Cue then SS.Audio.Cue("click") end
        self:Refresh()
    end)
    K.Tooltip(b, tip)
    function b:SetUsable(on, why) self.ssDisabled = not on; self.ssWhy = (not on) and why or nil; self:SetAlpha(on and 1 or 0.55) end
    b:Refresh()
    return b
end

-- "- value +" stepper over a list of values.
function K.Stepper(parent, label, values, get, set, fmt, tip, w)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w or 240, 22)
    f.label = K.Text(f, 11, "ink"); f.label:SetPoint("LEFT"); f.label:SetText(label)
    local function idx()
        local cur, best, bd = get(), 1, 1e9
        for n, v in ipairs(values) do local d = math.abs(v - cur); if d < bd then best, bd = n, d end end
        return best
    end
    f.plus = K.Button(f, "+", 22, 20, function() set(values[math.min(#values, idx() + 1)]); f:Refresh() end, tip)
    f.plus:SetPoint("RIGHT")
    f.value = K.Text(f, 11, "ink", "CENTER"); f.value:SetPoint("RIGHT", f.plus, "LEFT", -2, 0); f.value:SetWidth(44)
    f.minus = K.Button(f, "-", 22, 20, function() set(values[math.max(1, idx() - 1)]); f:Refresh() end, tip)
    f.minus:SetPoint("RIGHT", f.value, "LEFT", -2, 0)
    function f:Refresh() self.value:SetText(fmt and fmt(get()) or tostring(get())) end
    f:Refresh()
    return f
end

-- Label and a button that cycles through named choices: { { value, "Label" }, ... }.
function K.Choice(parent, label, choices, get, set, tip, w)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w or 240, 22)
    f.label = K.Text(f, 11, "ink"); f.label:SetPoint("LEFT"); f.label:SetText(label)
    local function idx()
        local cur = get()
        for n, c in ipairs(choices) do if c[1] == cur then return n end end
        return 1
    end
    f.btn = K.Button(f, "", 96, 20, function()
        local n = idx() % #choices + 1
        set(choices[n][1])
        f:Refresh()
    end, tip)
    f.btn:SetPoint("RIGHT")
    function f:Refresh() self.btn:SetLabel(choices[idx()][2]) end
    function f:SetUsable(on, why) self.btn:SetUsable(on, why); self:SetAlpha(on and 1 or 0.6) end
    f:Refresh()
    return f
end

-- Need/status bar over -100..100 with a zero tick. Negative values also get a hatch pattern
-- and callers print the number and a word, so the state never depends on colour alone.
function K.Bar(parent, w, h)
    local b = CreateFrame("Frame", nil, parent)
    b:SetSize(w, h)
    b.bg = K.Tex(b, "BACKGROUND", "barBg"); b.bg:SetAllPoints()
    b.fill = K.Tex(b, "ARTWORK", { 1, 1, 1, 1 }); b.fill:SetPoint("LEFT"); b.fill:SetHeight(h)
    b.stripes = {}
    for n = 1, 6 do
        local s = K.Tex(b, "OVERLAY", { 0, 0, 0, 0.35 }); s:SetSize(2, h)
        s:SetPoint("LEFT", b, "LEFT", math.floor(w * (n - 0.5) / 12), 0)
        b.stripes[n] = s
    end
    b.zero = K.Tex(b, "OVERLAY", { 0, 0, 0, 0.7 }); b.zero:SetSize(1, h); b.zero:SetPoint("LEFT", b, "LEFT", math.floor(w / 2), 0)
    b.w = w
    function b:SetBarWidth(nw)
        nw = math.max(20, math.floor(nw))
        if nw == self.w then return end
        self.w = nw
        self:SetWidth(nw)
        for n = 1, 6 do self.stripes[n]:ClearAllPoints(); self.stripes[n]:SetPoint("LEFT", self, "LEFT", math.floor(nw * (n - 0.5) / 12), 0) end
        self.zero:ClearAllPoints(); self.zero:SetPoint("LEFT", self, "LEFT", math.floor(nw / 2), 0)
        if self.v then self:SetValue(self.v) end
    end
    function b:SetValue(v)
        self.v = v
        local frac = (v + 100) / 200
        self.fill:SetWidth(math.max(1, frac * self.w))
        local r, g
        if v < 0 then r, g = 0.85, 0.30 + (v + 100) / 200 * 0.45 else r, g = 0.45 + (1 - v / 100) * 0.35, 0.70 end
        if UI.Pref and UI.Pref("highContrast") then
            if v < -55 then r, g = 0.95, 0.10 elseif v < 0 then r, g = 1, 0.65 else r, g = 0.15, 0.75 end
        end
        self.fill:SetColorTexture(r, g, 0.22, 1)
        -- hatch only across the filled part of a negative bar
        local fillW = frac * self.w
        for n = 1, 6 do self.stripes[n]:SetShown(v < 0 and (self.w * (n - 0.5) / 12) < fillW) end
    end
    return b
end

-- Four thin edges around a frame (selection, tutorial highlights). Returns the outline frame.
function K.Outline(parent, target, colourName, thick)
    local o = CreateFrame("Frame", nil, parent)
    o:SetFrameStrata("DIALOG")
    o.edges = {}
    thick = thick or 2
    for n = 1, 4 do o.edges[n] = K.Tex(o, "OVERLAY", colourName or "sun") end
    function o:Attach(t)
        self:ClearAllPoints()
        if not t then self:Hide(); return end
        self:SetPoint("TOPLEFT", t, "TOPLEFT", -3, 3); self:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", 3, -3)
        local e = self.edges
        e[1]:ClearAllPoints(); e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT"); e[1]:SetHeight(thick)
        e[2]:ClearAllPoints(); e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT"); e[2]:SetHeight(thick)
        e[3]:ClearAllPoints(); e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT"); e[3]:SetWidth(thick)
        e[4]:ClearAllPoints(); e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT"); e[4]:SetWidth(thick)
        self:Show()
    end
    o:Attach(target)
    return o
end

-- Draw a sprite from the art atlas into a texture (icons, catalogue thumbnails, portraits).
function K.SetSprite(t, spriteName, w, h)
    local s = SS.Art and SS.Art.sprites[spriteName]
    if not s then t:Hide(); return false end
    local size = SS.Art.sheetSize
    SS.Render.SetTex(t, SS.Art.sheets[s[1]])
    t:SetTexCoord(s[2] / size, (s[2] + s[4]) / size, s[3] / size, (s[3] + s[5]) / size)
    if w then
        local sc = math.min(w / s[4], (h or w) / s[5])
        t:SetSize(s[4] * sc, s[5] * sc)
    end
    t:Show()
    return true
end

-- Icon by name from SS.Art.icons (need icons, balloons, markers). Returns false if absent.
function K.SetIcon(t, iconName, w, h)
    local sprite = SS.Art and SS.Art.icons and SS.Art.icons[iconName]
    if not sprite then t:Hide(); return false end
    return K.SetSprite(t, sprite, w, h)
end

---------------------------------------------------------------------------
-- Portraits. SS.Render.DrawPortrait (art module) draws a person's portrait from their actual
-- look into an array of textures. Until art replaces the stub (which hides everything), the kit
-- draws a head-and-shoulders crop of the person's idle sprite layers, tinted with their colours.
-- When there is no person art at all, it draws a tile instead (K.FallbackTile): the person's
-- clothing colour, a face-coloured centre with their initial, and a ring in their mood colour.
---------------------------------------------------------------------------
K.PORTRAIT_LAYERS = 8
function K.Portrait(parent, size)
    local p = CreateFrame("Button", nil, parent)
    p:SetSize(size, size)
    p.back = K.Tex(p, "BACKGROUND", { 0.55, 0.72, 0.78, 1 }); p.back:SetAllPoints()
    p.layers = {}
    for n = 1, K.PORTRAIT_LAYERS do
        local t = p:CreateTexture(nil, "ARTWORK", nil, n - 1)
        t:SetPoint("CENTER")
        t:Hide()
        p.layers[n] = t
    end
    p.size = size
    return p
end

local function colourOf(look, part)
    if not look then return nil end
    local c = look[part]
    if type(c) ~= "table" and type(look.outfits) == "table" then
        local o = look.outfits.everyday
        c = type(o) == "table" and o[part] or nil
    end
    if type(c) == "table" and type(c[1]) == "number" then return c end
    return nil
end

function K.FallbackPortrait(p, person)
    local Art = SS.Art
    local persons = Art and Art.persons
    if not persons then return false end
    local look = person.look or {}
    local body = persons["short:idle:0"]
    local hair = persons[(look.hairStyle or "short") .. ":idle:0"] or body
    if not body then return false end
    local order = { { body.skin, colourOf(look, "skin") }, { body.bottom, colourOf(look, "bottom") },
        { body.top, colourOf(look, "top") }, { hair and hair.hair, colourOf(look, "hair") } }
    local z = Art.sheetSize
    local cropH = 22
    local n = 0
    for _, L in ipairs(order) do
        local s = L[1] and Art.sprites[L[1]]
        if s and n < #p.layers then
            n = n + 1
            local t = p.layers[n]
            SS.Render.SetTex(t, Art.sheets[s[1]])
            t:SetTexCoord(s[2] / z, (s[2] + s[4]) / z, s[3] / z, (s[3] + math.min(cropH, s[5])) / z)
            local scale = (p.size - 4) / math.max(s[4], cropH)
            t:SetSize(s[4] * scale, math.min(cropH, s[5]) * scale)
            t:ClearAllPoints(); t:SetPoint("TOP", p, "TOP", 0, -2)
            local c = L[2] or { 0.8, 0.8, 0.8 }
            t:SetVertexColor(c[1], c[2], c[3], 1)
            t:Show()
        end
    end
    return n > 0
end

-- The mood ring's colour: the same scale as the mood bar (UI.MoodColour), neutral trim when the
-- person has no needs to read (a visitor record, a placeholder).
local function moodOf(person)
    if type(person.needs) ~= "table" or not (SS.Needs and SS.Needs.Mood) then return nil end
    local ok, m = pcall(SS.Needs.Mood, person)
    if ok and type(m) == "number" then return m end
    return nil
end
local function ringColour(fb, person)
    local m = moodOf(person)
    local r, g, b
    if m and UI.MoodColour then r, g, b = UI.MoodColour(m)
    else local c = K.C("trim"); r, g, b = c[1], c[2], c[3] end
    if fb.ringR ~= r or fb.ringG ~= g or fb.ringB ~= b then
        fb.ringR, fb.ringG, fb.ringB = r, g, b
        for n = 1, 4 do fb.ring[n]:SetColorTexture(r, g, b, 1) end
    end
end

-- First letter of a name (UTF-8 aware), upper-cased.
local function initialOf(name)
    if type(name) ~= "string" or name == "" then return "?" end
    local ch = name:match("^[%z\1-\127\194-\244][\128-\191]*") or name:sub(1, 1)
    return ch:upper()
end

-- The last fallback: a tile that needs no art. Its regions are created once per portrait, the
-- first time it is needed, and reused for every later person.
function K.FallbackTile(p, person)
    local fb = p.fb
    if not fb then
        fb = { ring = {} }
        fb.tile = p:CreateTexture(nil, "BORDER")
        local th = math.max(1, math.floor(p.size / 14 + 0.5))
        local inset = th + math.max(1, math.floor(p.size / 11))
        fb.tile:SetPoint("TOPLEFT", th, -th); fb.tile:SetPoint("BOTTOMRIGHT", -th, th)
        fb.face = p:CreateTexture(nil, "ARTWORK", nil, 7)
        fb.face:SetPoint("TOPLEFT", inset, -inset); fb.face:SetPoint("BOTTOMRIGHT", -inset, inset)
        local sides = { { "TOPLEFT", "TOPRIGHT", nil, th }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, th },
            { "TOPLEFT", "BOTTOMLEFT", th, nil }, { "TOPRIGHT", "BOTTOMRIGHT", th, nil } }
        for n, sd in ipairs(sides) do
            local t = p:CreateTexture(nil, "BORDER", nil, 1)
            t:SetPoint(sd[1]); t:SetPoint(sd[2])
            if sd[3] then t:SetWidth(sd[3]) else t:SetHeight(sd[4]) end
            fb.ring[n] = t
        end
        fb.initial = K.Text(p, math.max(9, math.floor(p.size * 0.42)), "ink", "CENTER")
        fb.initial:SetPoint("CENTER", 0, 0)
        p.fb = fb
    end
    local look = person.look
    local top = colourOf(look, "top") or K.C("accent")
    local skin = colourOf(look, "skin") or K.C("panel")
    fb.tile:SetColorTexture(top[1], top[2], top[3], 1)
    fb.face:SetColorTexture(skin[1], skin[2], skin[3], 1)
    fb.initial:SetText(initialOf(person.name))
    fb.ringR = nil
    ringColour(fb, person)
    fb.tile:Show(); fb.face:Show(); fb.initial:Show()
    for n = 1, 4 do fb.ring[n]:Show() end
    fb.shown = true
    return true
end

local function hideTile(p)
    local fb = p.fb
    if not fb or not fb.shown then return end
    fb.tile:Hide(); fb.face:Hide(); fb.initial:Hide()
    for n = 1, 4 do fb.ring[n]:Hide() end
    fb.shown = false
end

-- Draw `person` into portrait `p`, only when the person or their look changed. The tile's mood
-- ring follows the mood between redraws (a colour change only; nothing is allocated).
function K.DrawPortrait(p, person, force)
    if not person then
        for _, t in ipairs(p.layers) do t:Hide() end
        hideTile(p)
        p.ssFor, p.ssLook = nil, nil
        p.ssDrawnBy = nil
        return
    end
    if not force and p.ssFor == person and p.ssLook == person.look and p.ssOutfit == person.outfit then
        if p.fb and p.fb.shown then ringColour(p.fb, person) end
        return
    end
    p.ssFor, p.ssLook, p.ssOutfit = person, person.look, person.outfit
    for _, t in ipairs(p.layers) do t:Hide() end
    hideTile(p)
    local shown = false
    if SS.Render and SS.Render.DrawPortrait then
        local ok = pcall(SS.Render.DrawPortrait, p.layers, person, p.size)
        if ok then for _, t in ipairs(p.layers) do if t:IsShown() then shown = true; break end end end
    end
    p.ssDrawnBy = shown and "renderer" or nil
    if not shown and K.FallbackPortrait(p, person) then shown = true; p.ssDrawnBy = "sprites" end
    if not shown then K.FallbackTile(p, person); p.ssDrawnBy = "tile" end
end

---------------------------------------------------------------------------
-- Paged list: a fixed number of pooled rows over any number of items (virtualised catalogue).
--   local list = K.PagedList(parent, rows, rowHeight, buildRow(rowFrame), fillRow(rowFrame, item, index))
--   list:SetItems(items); list:Page(1); list:Refresh()
-- Rows are created once; paging never creates frames. The mouse wheel pages.
---------------------------------------------------------------------------
function K.PagedList(parent, rows, rowH, buildRow, fillRow)
    local L = { rows = {}, items = {}, page = 1, perPage = rows }
    local f = CreateFrame("Frame", nil, parent)
    L.frame = f
    for n = 1, rows do
        local r = CreateFrame("Button", nil, f)
        r:SetHeight(rowH)
        r:SetPoint("TOPLEFT", 0, -(n - 1) * rowH); r:SetPoint("TOPRIGHT", 0, -(n - 1) * rowH)
        buildRow(r)
        L.rows[n] = r
    end
    L.pageText = K.Text(f, 10, "inkSoft", "CENTER")
    L.pageText:SetPoint("BOTTOM", 0, 2)
    L.prev = K.Button(f, "<", 20, 16, function() L:Page(L.page - 1) end, "Previous page")
    L.prev:SetPoint("BOTTOMLEFT", 0, 0)
    L.next = K.Button(f, ">", 20, 16, function() L:Page(L.page + 1) end, "Next page")
    L.next:SetPoint("BOTTOMRIGHT", 0, 0)
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, d) L:Page(L.page - d) end)
    function L:SetItems(items) self.items = items or {}; self:Page(1) end
    function L:Pages() return math.max(1, math.ceil(#self.items / self.perPage)) end
    function L:Page(p)
        self.page = math.max(1, math.min(p, self:Pages()))
        for n = 1, self.perPage do
            local idx = (self.page - 1) * self.perPage + n
            local item = self.items[idx]
            if item then self.rows[n]:Show(); fillRow(self.rows[n], item, idx) else self.rows[n]:Hide() end
        end
        self.pageText:SetText(self.page .. " / " .. self:Pages())
        self.prev:SetUsable(self.page > 1, "This is the first page.")
        self.next:SetUsable(self.page < self:Pages(), "This is the last page.")
    end
    function L:Refresh() self:Page(self.page) end
    return L
end

---------------------------------------------------------------------------
-- Extension registries. Registering after the window exists is fine: the window rebuilds its
-- mode buttons, tab strip and toolbar the next time it refreshes (UI.registryVersion).
---------------------------------------------------------------------------
UI.registryVersion = UI.registryVersion or 0
local function bump() UI.registryVersion = UI.registryVersion + 1 end

-- Modes. Exactly one is active; "live" is built into UI/Main.lua.
--   UI.RegisterMode(name, {
--     label = "Build", order = 20, key = "F2", tip = "...",
--     fullscreen = false,        -- true: hides the lot viewport and bottom panel (neighbourhood, creator)
--     pausesSim = true,          -- build/buy pause the household; the previous speed returns on exit
--     audio = "build",           -- music mode for SS.Audio.SetMode (defaults to the mode name)
--     create = fn(parent) -> frame,   -- built once, lazily; parent is the bottom panel (or the whole
--                                     -- content area when fullscreen)
--     canEnter = fn(world) -> ok, why,
--     enter = fn(world), exit = fn(world),
--     click = fn(btn, kind, ref, wx, wy, level) -> true if handled (lot clicks while in this mode),
--     mouseMove = fn(wx, wy, level),  -- cursor over the lot (placement ghosts)
--     keys = { R = true, DELETE = true },   -- keys this mode consumes while active
--     keyHelp = { { "R", "Rotate the object" }, ... },  -- shown in the keybinding reference
--     help = { "line", ... },          -- shown in the help panel under the mode's name
--     onKey = fn(key) -> true if handled (Esc: return true when a tool was cancelled),
--     update = fn(elapsed),
--   })
UI.modes = UI.modes or {}
function UI.RegisterMode(name, def)
    def.name = name
    UI.modes[name] = def
    bump()
end

-- Live-mode panel tabs (Needs is built in).
--   UI.RegisterTab(name, { label = "Relationships", order = 20, tip = "...", create = fn(parent) -> frame,
--                          refresh = fn(frame, actor, world), replaces = { "skills" } })
-- The shell registers read-only fallback tabs (personality, relationships, skills, career) that
-- a module's own tab with the same name, or one listing them in `replaces`, takes over.
UI.tabs = UI.tabs or {}
function UI.RegisterTab(name, def)
    def.name = name
    local old = UI.tabs[name]
    if old and not old.fallback and def.fallback then return end -- never let a fallback override a real tab
    UI.tabs[name] = def
    bump()
end

-- Context-menu providers. kind: "actor" (a person clicked while another is selected),
-- "self" (the selected person clicked), "obj" (an object), "cell" (floor/terrain),
-- "purchase" (buying, selling or moving a placed object; shown in the object menu's
-- "Manage" group).
--   UI.RegisterMenu(kind, fn(world, actor, ref, entries))  -- append entries:
--     { label = "Chat", desc = "tooltip", disabled = false, reason = "why not", order = 10,
--       cost = 25, privacy = "text", danger = "text", category = "Social", onClick = fn() }
--     or { label = ..., submenu = { ...entries } }
UI.menuProviders = UI.menuProviders or {}
function UI.RegisterMenu(kind, fn)
    UI.menuProviders[kind] = UI.menuProviders[kind] or {}
    table.insert(UI.menuProviders[kind], fn)
end
function UI.CollectMenu(kind, world, actor, ref)
    local entries = {}
    for _, fn in ipairs(UI.menuProviders[kind] or {}) do
        local ok, err = pcall(fn, world, actor, ref, entries)
        if not ok then SS.Log("menu provider (%s) failed: %s", kind, tostring(err)) end
    end
    table.sort(entries, function(a, b)
        if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) < (b.order or 50) end
        return tostring(a.label) < tostring(b.label)
    end)
    return entries
end

-- Toolbar buttons added by modules (e.g. phone).
--   UI.RegisterToolbar(name, { label = "Phone", width = 50, order = 10, tip = "...", onClick = fn(button),
--                              usable = fn(world) -> ok, why })
UI.toolbarExtras = UI.toolbarExtras or {}
function UI.RegisterToolbar(name, def)
    def.name = name
    UI.toolbarExtras[name] = def
    bump()
end

-- Help topics (the help panel lists them; the keybinding reference is built from the modes).
--   UI.RegisterHelp(id, { title = "Outings", order = 60, lines = { "..." } })
UI.helpTopics = UI.helpTopics or {}
function UI.RegisterHelp(id, def)
    def.id = id
    UI.helpTopics[id] = def
    bump()
end

---------------------------------------------------------------------------
-- Notices: short messages at the top of the lot. Queued and bounded, so a burst of messages
-- never grows memory; shown by UI/Main.lua (and queued while the window is closed).
--   UI.Notice(text [, kind = "info"|"warn"|"good" [, icon]])
---------------------------------------------------------------------------
UI.NOTICE_CAP = 12
UI.noticeQueue = UI.noticeQueue or {}
function UI.Notice(text, kind, icon)
    if not text or text == "" then return end
    local q = UI.noticeQueue
    -- merge an identical message that is still waiting
    for n = 1, #q do if q[n].text == text then q[n].count = (q[n].count or 1) + 1; return end end
    q[#q + 1] = { text = text, kind = kind or "info", icon = icon }
    while #q > UI.NOTICE_CAP do table.remove(q, 1) end
    if UI.OnNotice then UI.OnNotice() end
end

-- Confirmation for destructive actions (sell, bulldoze, evict, delete household, overwrite a
-- save). UI/Main.lua implements the dialog (UI.ShowConfirm). Without it, the action runs only
-- if the player switched confirmations off; otherwise it is declined (never silently done).
function UI.Confirm(text, onYes, onNo)
    if UI.ShowConfirm then return UI.ShowConfirm(text, onYes, onNo) end
    if UI.Pref("noConfirm") then onYes() elseif onNo then onNo() end
end
