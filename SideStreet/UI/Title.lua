-- SideStreet title screen, first-launch choice and save manager.
--
-- Title: Continue, New game, Saves, Tutorial, Options, Help, Diagnostics. It covers the whole
-- window and the household does not run behind it (UI/Main.lua skips the simulation while it
-- is up). The first time SideStreet opens, it offers three ways to start:
--   * a short guided tutorial (UI/Tutorial.lua; its own practice household, never your saves),
--   * a ready-to-play household (opens straight on its lot),
--   * creating a household (the neighbourhood module's "create" mode, when present).
-- "New game" offers the same three and, as the architecture asks, opens the neighbourhood.
--
-- Saves: three named slots with metadata, the automatic checkpoint (kept whenever the window
-- closes) and the previous-good copies. Saving updates SideStreet's saved data in memory; WoW
-- writes it to disk at logout or /reload, and the panel says so.
local _, SS = ...
local UI = SS.UI
local K = UI.Kit
local TT = UI.Title or {}
UI.Title = TT

local function world() return SS.Sim.world end
local function db() return SS.Save.DB() end
local function tutorialOn() return SS.Tutorial and SS.Tutorial.active end

---------------------------------------------------------------------------
-- Save metadata
---------------------------------------------------------------------------
-- Facts about a save root for the slot list: household, address, clock, funds, people.
function TT.Meta(root)
    if type(root) ~= "table" then return nil end
    local m = {}
    local act = type(root.active) == "table" and root.active or {}
    local hh = type(root.households) == "table" and root.households[act.householdId or ""]
    local lot = type(root.hood) == "table" and type(root.hood.lots) == "table" and root.hood.lots[act.lotId or ""]
    m.household = hh and hh.name or "?"
    m.address = lot and (lot.address or lot.name or lot.id) or "?"
    m.time = type(root.time) == "number" and root.time or 0
    m.money = hh and hh.money or 0
    m.people = hh and type(hh.members) == "table" and #hh.members or 0
    m.sandbox = ((type(root.settings) == "table" and root.settings.sandboxMoney) or (type(root.shell) == "table" and root.shell.sandboxUsed)) and true or false
    m.tutorial = root.tutorial and true or false
    m.schema = root.schema
    return m
end

function TT.MetaText(root, savedAt)
    local m = TT.Meta(root)
    if not m then return "Empty" end
    local when = savedAt and (date and date("%Y-%m-%d %H:%M", savedAt)) or nil
    return string.format("%s household, %s  -  %s  -  %s  -  %d %s%s%s", m.household, m.address, UI.ClockText(m.time),
        UI.Money(m.money), m.people, m.people == 1 and "person" or "people", m.sandbox and "  -  sandbox" or "",
        when and ("  -  saved " .. when) or "")
end

-- What "Continue" would open: the running game, the checkpoint or the active slot.
function TT.ContinueTarget()
    local w = world()
    local d = db()
    -- the household loaded under the first-launch choice is not a game in progress yet
    if w and not tutorialOn() and not SS.Boot.IsPlaceholder(w) then return "running", w.root end
    if d.checkpoint and d.checkpoint.world then return "checkpoint", d.checkpoint.world, d.checkpoint.savedAt end
    if d.active and d.slots[d.active] and d.slots[d.active].world then return "slot", d.slots[d.active].world, d.slots[d.active].savedAt end
    return nil
end

---------------------------------------------------------------------------
-- Title frame
---------------------------------------------------------------------------
local HOUSES = {   -- original backdrop: a little street at dusk (x, width, height, body colour)
    { 40, 90, 70, { 0.93, 0.83, 0.62 } }, { 150, 70, 58, { 0.64, 0.78, 0.74 } }, { 240, 110, 84, { 0.90, 0.70, 0.55 } },
    { 370, 80, 62, { 0.80, 0.84, 0.66 } }, { 470, 100, 76, { 0.95, 0.88, 0.72 } }, { 590, 76, 60, { 0.70, 0.74, 0.86 } },
    { 690, 96, 72, { 0.92, 0.76, 0.60 } },
}

local function drawStreet(f)
    local sky = K.Tex(f, "BACKGROUND", "accentDeep"); sky:SetAllPoints()
    local glow = K.Tex(f, "BACKGROUND", { 0.96, 0.74, 0.30, 0.18 }, 1)
    glow:SetPoint("BOTTOMLEFT", 0, 60); glow:SetPoint("BOTTOMRIGHT", 0, 60); glow:SetHeight(120)
    local road = K.Tex(f, "BORDER", { 0.25, 0.25, 0.27, 1 }); road:SetPoint("BOTTOMLEFT"); road:SetPoint("BOTTOMRIGHT"); road:SetHeight(40)
    local curb = K.Tex(f, "BORDER", { 0.62, 0.60, 0.55, 1 }, 1); curb:SetPoint("BOTTOMLEFT", 0, 40); curb:SetPoint("BOTTOMRIGHT", 0, 40); curb:SetHeight(20)
    for n = 0, 11 do
        local dash = K.Tex(f, "ARTWORK", { 0.95, 0.88, 0.55, 1 })
        dash:SetSize(34, 3); dash:SetPoint("BOTTOMLEFT", 20 + n * 80, 18)
    end
    f.houses = {}
    for _, h in ipairs(HOUSES) do
        local x, wdt, hgt, col = h[1], h[2], h[3], h[4]
        local body = K.Tex(f, "ARTWORK", { col[1], col[2], col[3], 1 })
        body:SetPoint("BOTTOMLEFT", x, 60); body:SetSize(wdt, hgt)
        -- stepped roof: three shrinking bands
        for s = 0, 2 do
            local r = K.Tex(f, "ARTWORK", { 0.55 - s * 0.05, 0.30, 0.24, 1 }, 1)
            r:SetPoint("BOTTOMLEFT", x - 6 + s * (wdt / 6), 60 + hgt + s * 8); r:SetSize(wdt + 12 - s * (wdt / 3), 8)
        end
        local win = K.Tex(f, "ARTWORK", { 0.99, 0.85, 0.45, 1 }, 2)
        win:SetPoint("BOTTOMLEFT", x + wdt * 0.2, 60 + hgt * 0.5); win:SetSize(wdt * 0.22, hgt * 0.22)
        local win2 = K.Tex(f, "ARTWORK", { 0.99, 0.85, 0.45, 1 }, 2)
        win2:SetPoint("BOTTOMLEFT", x + wdt * 0.58, 60 + hgt * 0.5); win2:SetSize(wdt * 0.22, hgt * 0.22)
        local door = K.Tex(f, "ARTWORK", { 0.36, 0.24, 0.18, 1 }, 2)
        door:SetPoint("BOTTOMLEFT", x + wdt * 0.42, 60); door:SetSize(wdt * 0.16, hgt * 0.36)
        f.houses[#f.houses + 1] = body
    end
end

function TT.Create()
    if TT.frame then return TT.frame end
    local f = CreateFrame("Frame", nil, UI.frame)
    f:SetPoint("TOPLEFT", 2, -2); f:SetPoint("BOTTOMRIGHT", -2, 2)
    f:SetFrameLevel(UI.frame:GetFrameLevel() + 100)
    f:EnableMouse(true)
    drawStreet(f)
    TT.frame = f
    UI.titleFrame = f
    f.logo = K.Text(f, 40, "paper", "LEFT"); f.logo:SetPoint("TOPLEFT", 36, -30); f.logo:SetText("SideStreet")
    -- A painted backdrop and a logo from the art module when it ships them (SS.Art.ui, see
    -- docs/art_requests/ui-shell.md); the drawn street and the text logo stay otherwise.
    local art = SS.Art and type(SS.Art.ui) == "table" and SS.Art.ui or nil
    if art and type(art.titleBackdrop) == "string" then
        f.backdrop = f:CreateTexture(nil, "ARTWORK", nil, 7)
        f.backdrop:SetAllPoints()
        f.backdrop:SetTexture(art.titleBackdrop)
    end
    if art and type(art.logo) == "string" then
        f.logoTex = f:CreateTexture(nil, "OVERLAY")
        f.logoTex:SetSize(320, 80); f.logoTex:SetPoint("TOPLEFT", 30, -18)
        f.logoTex:SetTexture(art.logo)
        f.logo:SetAlpha(0)   -- the text logo stays as the tagline's anchor
    end
    f.tag = K.Text(f, 13, "sun", "LEFT"); f.tag:SetPoint("TOPLEFT", f.logo, "BOTTOMLEFT", 2, -6)
    f.tag:SetText("A little street of households, lived one day at a time.")
    local col = CreateFrame("Frame", nil, f)
    col:SetPoint("TOPLEFT", 36, -120); col:SetSize(230, 320)
    f.col = col
    local defs = {
        { "continue", "Continue", function() TT.Continue() end, function() return TT.ContinueTip() end },
        { "new", "New game", function() TT.ShowChoice("new") end, "Start a new neighbourhood. Your three save slots are kept." },
        { "saves", "Saves", function() UI.ShowSaves() end, "Save, load, rename or delete: 3 slots, the checkpoint and the previous-good copies" },
        { "tutorial", "Tutorial", function() TT.Tutorial() end, function() return TT.TutorialTip() end },
        { "options", "Options", function() UI.ToggleOptions() end, "Text size, contrast, captions, sounds and game rules" },
        { "help", "Help and keys", function() UI.ToggleHelp() end, "How to play and the keys for every mode" },
        { "diag", "Diagnostics", function() if UI.Diag then UI.Diag.Toggle(true) end end, "Compatibility report and performance numbers" },
        { "close", "Close", function() UI.Hide() end, "Close SideStreet. Nothing happens to your households while it is closed." },
    }
    f.btns = {}
    for n, d in ipairs(defs) do
        local b = K.Button(col, d[2], 220, 28, d[3], d[4])
        K.SetTextSize(b.label, 13)
        b:SetPoint("TOPLEFT", 0, -(n - 1) * 34)
        f.btns[d[1]] = b
    end
    -- right: the start choice card
    local card = K.Panel(f, "How would you like to start?", 380, 290, {})
    card:SetPoint("TOPRIGHT", -36, -120)
    card.lead = K.Text(card.body, 11, "ink"); card.lead:SetPoint("TOPLEFT"); card.lead:SetPoint("TOPRIGHT")
    local choices = {
        { "tutorial", "Guided tutorial", "A short tour that uses the real game with a practice household. Skip, resume or replay it any time; it never touches your saves." },
        { "ready", "Play a ready household", "Move straight into a furnished home with a household that is ready to go." },
        { "create", "Create a household", "Design your own people, then pick a home for them in the neighbourhood." },
    }
    card.opts = {}
    for n, c in ipairs(choices) do
        local b = K.Button(card.body, c[2], 344, 26, function() TT.Choose(c[1]) end, { c[2], c[3] })
        K.SetTextSize(b.label, 12)
        b:SetPoint("TOPLEFT", 4, -40 - (n - 1) * 66)
        local d = K.Text(card.body, 10, "inkSoft"); d:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 2, -3); d:SetWidth(340); d:SetText(c[3])
        b.desc = d
        card.opts[c[1]] = b
    end
    card.cancel = K.Button(card.body, "Back", 60, 20, function() TT.HideChoice() end, "Close this choice")
    card.cancel:SetPoint("BOTTOMRIGHT", 0, 0)
    card:Hide()
    f.card = card
    f.status = K.Text(f, 10, "paper", "LEFT"); f.status:SetPoint("BOTTOMLEFT", 36, 66); f.status:SetPoint("BOTTOMRIGHT", -36, 66)
    f.foot = K.Text(f, 9, "paper", "LEFT"); f.foot:SetPoint("BOTTOMLEFT", 8, 4)
    f.foot:SetText("SideStreet " .. tostring(SS.VERSION) .. ". Saved in SideStreet's saved data; WoW writes it to disk at logout or /reload. Nothing happens to your households while the window is closed.")
    f:Hide()   -- built hidden; the scripts below only see real shows and hides
    f:SetScript("OnShow", function() TT.Refresh(); SS.Audio.SetMode("title") end)
    f:SetScript("OnHide", function()
        if TT.card() then TT.card():Hide() end
        -- The title went away while the window stays on screen, over the placeholder household:
        -- whatever did it (a module changing mode, a stray Hide), the household underneath is now
        -- the player's game (the ready household), so it runs and is checkpointed like any other.
        -- Closing the window or hiding the game's interface is not that: the choice stays.
        if UI.frame and UI.frame:IsVisible() and SS.Boot.IsPlaceholder(world()) then SS.Boot.AdoptPlaceholder() end
        local m = UI.CurrentMode()
        if UI.IsShown() then SS.Audio.SetMode(m.audio or m.name) end
    end)
    f:Hide()
    return f
end

function TT.card() return TT.frame and TT.frame.card end

function TT.ContinueTip()
    local kind, root, savedAt = TT.ContinueTarget()
    if not kind then return { "Continue", "Nothing to continue yet: start a new game or the tutorial." } end
    local what = kind == "running" and "Back to the game in progress" or kind == "checkpoint" and "The checkpoint from when the window last closed" or "Your last saved slot"
    return { "Continue", what .. ":", TT.MetaText(root, savedAt) }
end

function TT.TutorialTip()
    local st = SS.Tutorial and SS.Tutorial.State and SS.Tutorial.State()
    if not st then return "The guided tour" end
    if st.inProgress then return { "Tutorial", "Resume the tour at step " .. st.step .. " of " .. st.total .. ". It uses a practice household, never your saves." } end
    if st.done then return { "Tutorial", "Replay the tour from the start. Your saves are not touched." } end
    return { "Tutorial", "A short guided tour with a practice household. Your saves are not touched." }
end

function TT.Refresh()
    local f = TT.frame
    if not f then return end
    local kind = TT.ContinueTarget()
    f.btns.continue:SetUsable(kind ~= nil, "Nothing to continue yet: start a new game or the tutorial.")
    local st = SS.Tutorial and SS.Tutorial.State and SS.Tutorial.State()
    f.btns.tutorial:SetLabel(st and st.inProgress and ("Resume tutorial (" .. st.step .. "/" .. st.total .. ")") or (st and st.done and "Replay tutorial") or "Tutorial")
    local d = db()
    local used = 0
    for s = 1, SS.Save.SLOTS do if d.slots[s] and d.slots[s].world then used = used + 1 end end
    local line = string.format("%d of %d save slots used.", used, SS.Save.SLOTS)
    if d.checkpoint and d.checkpoint.world then line = line .. "  Checkpoint: " .. TT.MetaText(d.checkpoint.world, d.checkpoint.savedAt) .. "." end
    f.status:SetText(line)
    local card = f.card
    card.opts.create:SetUsable(UI.modes.create ~= nil, "Household creation is provided by the neighbourhood module, which is not in this build.")
end

-- Show the title (optionally with the start choice: "first" or "new").
function UI.ShowTitle(choice)
    if not UI.frame then UI.Create() end
    local f = TT.Create()
    UI.HideMenu()
    f:Show()
    TT.Refresh()
    if choice then TT.ShowChoice(choice) else TT.HideChoice() end
end

-- Leave the title for the game underneath (quiet = called by a mode change or a start flow).
-- The first-launch choice is not dismissed into the placeholder household: the player is asked to
-- choose. Only a programmatic caller (quiet) can move past it, and then the household underneath
-- becomes the ready household (SS.Boot.AdoptPlaceholder), a real game that runs and is saved.
function UI.HideTitle(quiet)
    local f = TT.frame
    if not f or not f:IsShown() then return end
    local w = world()
    if not w then
        if not quiet then UI.Notice("Start or continue a game first.") end
        return
    end
    if SS.Boot.IsPlaceholder(w) then
        if not quiet then UI.Notice("Choose how to start first: the tutorial, the ready household or a household of your own."); return end
        SS.Boot.AdoptPlaceholder()
    end
    f:Hide()
end

function TT.ShowChoice(kind)
    local card = TT.card()
    if not card then return end
    TT.choiceKind = kind
    if kind == "first" then
        card.title:SetText("Welcome! How would you like to start?")
        card.lead:SetText("You can change your mind later: the tutorial is always on the title screen.")
        card.cancel:SetShown(world() ~= nil and not SS.Boot.IsPlaceholder(world()))
    else
        card.title:SetText("New game: how would you like to start?")
        card.lead:SetText(world() and not tutorialOn() and not SS.Boot.IsPlaceholder(world()) and "Your save slots are kept. The game in progress is replaced unless you save it first." or "Your save slots are kept.")
        card.cancel:Show()
    end
    card.opts.ready.desc:SetText(kind == "new" and UI.modes.hood
        and "Opens the neighbourhood from above with a household ready to move in; click its home to play."
        or "Move straight into a furnished home with a household that is ready to go.")
    TT.Refresh()
    card:Show()
end

function TT.HideChoice()
    local card = TT.card()
    if card then card:Hide() end
end

-- The three starts. Everything funnels through SS.Boot so slash commands behave the same.
function TT.Choose(kind)
    local d = db()
    d.ui.welcomed = true
    TT.HideChoice()
    if kind == "tutorial" then
        TT.Tutorial()
        return
    end
    local function go()
        -- first launch: the ready household opens on its lot; a new game from the title opens the
        -- neighbourhood (when that mode exists) so the player sees the street first
        local start = kind == "create" and "create" or (TT.choiceKind == "new" and "hood" or "ready")
        SS.Boot.NewGame(start)
    end
    if TT.choiceKind == "new" and world() and not tutorialOn() and not SS.Boot.IsPlaceholder(world()) then
        UI.Confirm("Start a new game? The game in progress is replaced (your 3 save slots are kept). Save it first from Saves if you want to keep it.", go)
    else
        go()
    end
end

function TT.Continue()
    local kind = TT.ContinueTarget()
    if not kind then UI.Notice("Nothing to continue yet."); return end
    if kind == "running" then UI.HideTitle(); return end
    local ok, msg = SS.Boot.Continue()
    if not ok then UI.Notice(msg or "Could not continue.", "warn") end
end

function TT.Tutorial()
    if not SS.Tutorial then UI.Notice("The tutorial is not available."); return end
    local st = SS.Tutorial.State()
    if st.inProgress then SS.Tutorial.Resume() else SS.Tutorial.Start(st.done) end
end

---------------------------------------------------------------------------
-- Save manager
---------------------------------------------------------------------------
local SM = TT.saves or {}
TT.saves = SM

local function slotRow(parent, y, label)
    local r = CreateFrame("Frame", nil, parent)
    r:SetPoint("TOPLEFT", 0, y); r:SetPoint("TOPRIGHT", 0, y); r:SetHeight(44)
    r.bg = K.Tex(r, "BACKGROUND", "panelDark"); r.bg:SetAllPoints(); r.bg:SetAlpha(0.6)
    r.name = K.Text(r, 12, "ink"); r.name:SetPoint("TOPLEFT", 6, -4); r.name:SetPoint("RIGHT", -200, 0)
    r.meta = K.Text(r, 9, "inkSoft"); r.meta:SetPoint("TOPLEFT", 6, -20); r.meta:SetPoint("RIGHT", -200, 0)
    r.meta:SetJustifyV("TOP")
    r.label = label
    r.btns = {}
    return r
end

local function rowButton(r, key, label, w, fnc, tip)
    local b = K.Button(r, label, w, 20, fnc, tip)
    local x = -4
    for _, k in ipairs(r.btnOrder or {}) do x = x - r.btns[k]:GetWidth() - 4 end
    b:SetPoint("RIGHT", r, "RIGHT", x, 0)
    r.btns[key] = b
    r.btnOrder = r.btnOrder or {}
    r.btnOrder[#r.btnOrder + 1] = key
    return b
end

function SM.Create()
    if SM.frame then return SM.frame end
    local p = K.Panel(UI.frame, "Saves", 600, 430, { close = true, movable = true, strata = "DIALOG", level = 85 })
    p:SetPoint("CENTER", 0, 10)
    SM.frame = p
    local b = p.body
    p.nameLabel = K.Text(b, 11, "ink"); p.nameLabel:SetPoint("TOPLEFT", 0, -4); p.nameLabel:SetText("Name for a new save:")
    local eb = CreateFrame("EditBox", nil, b)
    eb:SetSize(260, 20); eb:SetPoint("LEFT", p.nameLabel, "RIGHT", 8, 0)
    eb.bg = K.Tex(eb, "BACKGROUND", "paper"); eb.bg:SetAllPoints()
    eb:SetFontObject(GameFontHighlight)
    if eb.SetTextColor then local c = K.C("ink"); eb:SetTextColor(c[1], c[2], c[3]) end
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(40)
    eb:SetTextInsets(4, 4, 0, 0)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    K.Tooltip(eb, "Type a name, then press Save on a slot. Press Enter or Esc to stop typing (keys go back to the game).")
    p.nameBox = eb
    p.rows = {}
    for s = 1, SS.Save.SLOTS do
        local r = slotRow(b, -32 - (s - 1) * 50, "Slot " .. s)
        rowButton(r, "delete", "Delete", 54, function() SM.Delete(s) end, "Delete this save (asks first)")
        rowButton(r, "load", "Load", 50, function() SM.Load(s) end, "Load this save (asks first)")
        rowButton(r, "save", "Save here", 72, function() SM.SaveTo(s) end, "Save the game in progress to this slot")
        p.rows[s] = r
    end
    local y = -32 - SS.Save.SLOTS * 50 - 8
    p.cp = slotRow(b, y, "Checkpoint")
    rowButton(p.cp, "load", "Load", 50, function() SM.LoadCheckpoint() end, "Go back to the checkpoint (asks first)")
    rowButton(p.cp, "now", "Checkpoint now", 100, function() SM.CheckpointNow() end, "Keep a checkpoint of the game in progress right now")
    p.good = slotRow(b, y - 50, "Previous good copy")
    rowButton(p.good, "load", "Restore", 60, function() SM.RestoreGood() end, "Load the last copy that passed validation before it was replaced (asks first)")
    p.note = K.Text(b, 10, "inkSoft"); p.note:SetPoint("BOTTOMLEFT", 0, 0); p.note:SetPoint("BOTTOMRIGHT", 0, 0)
    p.note:SetText("Saving updates SideStreet's saved data right away, in memory. WoW writes it to disk when you log out or type /reload; if the game crashes before that, the newest changes are lost. A checkpoint is kept every time the window closes.")
    UI.RegisterFloating(p, function() p.nameBox:ClearFocus(); p:Hide() end)
    p:SetScript("OnHide", function() p.nameBox:ClearFocus() end)
    p:Hide()
    return p
end

function SM.DefaultName()
    local w = world()
    if not w or not w.household then return "My game" end
    return string.format("%s, day %d", w.household.name, math.floor(w.time / 1440) + 1)
end

function SM.Refresh()
    local p = SM.frame
    if not p then return end
    local d = db()
    local w = world()
    local noGame = SM.CannotSave()
    for s, r in ipairs(p.rows) do
        local slot = d.slots[s]
        local filled = slot and slot.world
        r.name:SetText(r.label .. ":  " .. (filled and (slot.name or ("Save " .. s)) or "empty") .. ((d.active == s and filled) and "   (last used)" or ""))
        r.meta:SetText(filled and TT.MetaText(slot.world, slot.savedAt) or "Nothing saved here yet.")
        r.btns.save:SetUsable(not noGame, noGame)
        r.btns.load:SetUsable(filled and true or false, "This slot is empty.")
        r.btns.delete:SetUsable(filled and true or false, "This slot is empty.")
    end
    local cp = d.checkpoint
    p.cp.name:SetText("Checkpoint (kept whenever the window closes)")
    p.cp.meta:SetText(cp and cp.world and TT.MetaText(cp.world, cp.savedAt) or "No checkpoint yet.")
    p.cp.btns.load:SetUsable(cp and cp.world and true or false, "There is no checkpoint yet.")
    p.cp.btns.now:SetUsable(not noGame, noGame)
    local good, where = SM.GoodCopy()
    p.good.name:SetText("Previous good copy" .. (where and ("  (" .. where .. ")") or ""))
    p.good.meta:SetText(good and TT.MetaText(good.world, good.savedAt) or "None yet: one is kept when a save or checkpoint is replaced.")
    p.good.btns.load:SetUsable(good and true or false, "There is no previous copy yet.")
    if (p.nameBox:GetText() or "") == "" then p.nameBox:SetText(SM.DefaultName()) end
end

-- Newest of the two recovery copies (slot overwrite, checkpoint replacement).
function SM.GoodCopy()
    local d = db()
    local a, b = d.lastGood, d.checkpointPrev
    local best, where
    if a and a.world then best, where = a, "before slot " .. tostring(a.slot) .. " was overwritten" end
    if b and b.world and (not best or (b.savedAt or 0) > (best.savedAt or 0)) then best, where = b, "the checkpoint before the last one" end
    return best, where
end

function UI.ShowSaves()
    if not UI.frame then UI.Create() end
    local p = SM.Create()
    p.nameBox:SetText(SM.DefaultName())
    SM.Refresh()
    p:Show()
end

-- Why the game in progress cannot be saved or checkpointed right now (nil when it can).
function SM.CannotSave()
    local w = world()
    if not w then return "Start or continue a game first." end
    if tutorialOn() then return "The tutorial's practice household is kept apart from your saves. Finish or leave the tutorial to save your own game." end
    if SS.Boot.IsPlaceholder(w) then return "Nothing to save yet: choose how to start on the title screen first (tutorial, ready household or create a household)." end
    return nil
end

function SM.SaveTo(s)
    local w = world()
    local why = SM.CannotSave()
    if why then UI.Notice(why, "warn"); return end
    local d = db()
    local name = strtrim and strtrim(SM.frame.nameBox:GetText() or "") or (SM.frame.nameBox:GetText() or "")
    if name == "" then name = SM.DefaultName() end
    name = name:sub(1, 40)
    local function write()
        local ok, err = SS.Save.Write(s, w, name)
        if ok then
            SS.Boot.Checkpoint()
            UI.Notice("Saved to slot " .. s .. ". WoW writes it to disk at logout or /reload.", "good")
        else
            UI.Notice(err or "Save failed.", "warn")
        end
        SM.Refresh()
    end
    local slot = d.slots[s]
    if slot and slot.world then
        UI.Confirm(string.format("Replace slot %d (%s)?\n%s\nThe old save is kept as the previous good copy.", s, slot.name or "", TT.MetaText(slot.world, slot.savedAt)), write)
    else
        write()
    end
end

local function unsavedWarning()
    return (world() and not tutorialOn() and not SS.Boot.IsPlaceholder(world())) and "\nThe game in progress is replaced; anything since your last save is lost unless you save it first." or ""
end

function SM.Load(s)
    local d = db()
    local slot = d.slots[s]
    if not (slot and slot.world) then UI.Notice("Slot " .. s .. " is empty."); return end
    UI.Confirm(string.format("Load slot %d (%s)?%s", s, slot.name or "", unsavedWarning()), function()
        local w, msg = SS.Save.Read(s)
        if not w then UI.Notice(msg or "That save could not be read.", "warn"); return end
        SS.Boot.UseWorld(w)
        d.active = s
        SS.Boot.Checkpoint()
        UI.HideTitle(true)
        UI.Notice(msg or ("Loaded slot " .. s .. "."), msg and "warn" or "good")
        SM.Refresh()
        if SM.frame then SM.frame:Hide() end
    end)
end

function SM.Delete(s)
    local d = db()
    local slot = d.slots[s]
    if not (slot and slot.world) then return end
    UI.Confirm(string.format("Delete slot %d (%s)? This cannot be undone.", s, slot.name or ""), function()
        d.slots[s] = nil
        if d.active == s then d.active = nil end
        UI.Notice("Slot " .. s .. " deleted.")
        SM.Refresh()
        TT.Refresh()
    end, nil)
end

function SM.LoadCheckpoint()
    local d = db()
    if not (d.checkpoint and d.checkpoint.world) then return end
    UI.Confirm("Go back to the checkpoint?" .. unsavedWarning(), function()
        local ok, msg = SS.Boot.Continue(true)
        UI.Notice(ok and "Back at the checkpoint." or (msg or "The checkpoint could not be read."), ok and "good" or "warn")
        SM.Refresh()
        if ok and SM.frame then SM.frame:Hide() end
    end)
end

function SM.CheckpointNow()
    local why = SM.CannotSave()
    if why then UI.Notice(why, "warn"); return end
    local ok, msg = SS.Boot.Checkpoint()
    UI.Notice(ok and "Checkpoint kept (in memory; on disk at logout or /reload)." or (msg or "Checkpoint failed."), ok and "good" or "warn")
    SM.Refresh()
end

function SM.RestoreGood()
    local good = SM.GoodCopy()
    if not good then return end
    UI.Confirm("Load the previous good copy?" .. unsavedWarning(), function()
        local w = SS.U.deepcopy(good.world)
        local okM = SS.Save.Migrate(w)
        local okV, problems = false, nil
        if okM then okV, problems = SS.Save.Validate(w) end
        if not (okM and okV) then UI.Notice("The previous copy is damaged too: " .. table.concat(problems or { "unknown schema" }, "; "), "warn"); return end
        SS.Boot.UseWorld(w)
        SS.Boot.Checkpoint()
        UI.HideTitle(true)
        UI.Notice("Restored the previous good copy.", "good")
        SM.Refresh()
        if SM.frame then SM.frame:Hide() end
    end)
end

SS.On("worldAttached", function(w)
    -- A real game attached underneath the title from outside its own buttons (another screen or
    -- module loading a household) is the game now: the title steps aside so it is not paused
    -- behind a card. The placeholder and the tutorial world keep the title where it is. Every
    -- title flow attaches its world first and then shows or hides the title itself.
    if TT.frame and TT.frame:IsShown() and w and not SS.Boot.IsPlaceholder(w) and not (w.root and w.root.tutorial) and not tutorialOn() then
        TT.frame:Hide()
        return
    end
    if TT.frame and TT.frame:IsShown() then TT.Refresh() end
    if SM.frame and SM.frame:IsShown() then SM.Refresh() end
end)
