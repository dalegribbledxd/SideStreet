-- SideStreet bootstrap: WoW events, start-up flow, slash commands, combat safety, checkpoints.
--
-- Start-up (ARCHITECTURE §9.15, brief §4):
--   * The window opens only on an explicit action (/sidestreet, never by itself, never in combat).
--   * A returning player continues where they left off: the checkpoint (kept whenever the window
--     closes), else the last used save slot, on the active lot.
--   * The very first time, a ready household is loaded underneath and the title screen offers the
--     three starts (tutorial, ready household, create a household).
--   * A new game opens the neighbourhood when that mode exists (UI.SetMode("hood")).
-- Combat: the window hides, the house pauses and goes silent, and dialogs close as "No".
-- Nothing is simulated while the window is closed or the player is offline.
local ADDON, SS = ...
local Boot = SS.Boot or {}
SS.Boot = Boot

local function say(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff6fc5b8SideStreet|r: " .. msg) end
end
Boot.Say = say

local function db() return SS.Save.DB() end
local function tutorialWorld(w) return w and w.root and w.root.tutorial end

---------------------------------------------------------------------------
-- Worlds
---------------------------------------------------------------------------
-- Attach a save root and bring the window up to date. opts.mode enters a mode afterwards.
function Boot.UseWorld(root, opts)
    opts = opts or {}
    if root.root then root = root.root end
    -- a checkpoint put off by combat is kept before its world goes away
    if Boot.pendingCheckpoint then Boot.pendingCheckpoint = nil; Boot.Checkpoint() end
    if SS.Tutorial and SS.Tutorial.active and not root.tutorial then SS.Tutorial.Suspend() end
    if SS.UI.mode and SS.UI.mode ~= "live" and SS.UI.frame then SS.UI.SetMode("live") end
    -- The outgoing world's systems finish their session first (journal enrichment, open visits,
    -- timers), exactly as Boot.Detach does, once per switch and whatever is loaded next. The shell
    -- runs these hooks itself, each guarded (one that fails is logged and the switch goes on), and
    -- then lets go of the old session so Sim.Attach does not run them a second time: depending on
    -- the household-core version, Sim.Attach runs them unguarded for the same root only, or for
    -- any previous session.
    local old = SS.Sim.world
    if old then
        for _, sys in ipairs(SS.Sim.systems or {}) do
            if sys.detach then
                local ok, err = pcall(sys.detach, old)
                if not ok then SS.Log("detach %s failed: %s", tostring(sys.name), tostring(err)) end
            end
        end
        SS.Sim.world = nil
    end
    local w = SS.Sim.Attach(root)
    if SS.UI.frame then
        SS.UI.dirty = true
        SS.UI.RefreshPortrait()
        SS.UI.RefreshToolbar()
    end
    if opts.mode and SS.UI.modes[opts.mode] and SS.UI.frame then SS.UI.SetMode(opts.mode) end
    return w
end

-- Forget the running world without loading another (only when nothing else can be shown).
function Boot.Detach()
    local w = SS.Sim.world
    if not w then return end
    for _, sys in ipairs(SS.Sim.systems or {}) do
        if sys.detach then pcall(sys.detach, w) end
    end
    SS.Sim.world = nil
    SS.Sim.root = nil
    if SS.Audio and SS.Audio.ClearLoops then SS.Audio.ClearLoops() end
end

-- Quick checkpoint of the game in progress, in memory (WoW writes it to disk at logout or
-- /reload). The previous checkpoint is kept as checkpointPrev when it is still valid, so a bad
-- write never replaces the last good one. The tutorial keeps its own progress instead.
--
-- Cost: one deep copy (the snapshot itself). The snapshot is already a private copy, so it is
-- validated in place (small repairs land in the stored copy, never in the running game), and a
-- checkpoint written here is stamped as validated for this save schema, so when it is replaced it
-- becomes the previous checkpoint without being copied and validated again. Only a checkpoint
-- without that stamp (from an older version of the addon) is copied and checked before it is kept.
function Boot.Checkpoint()
    local w = SS.Sim.world
    if not w then return false, "No game is running." end
    if tutorialWorld(w) then
        if SS.Tutorial and SS.Tutorial.SaveProgress then SS.Tutorial.SaveProgress() end
        return false, "The tutorial keeps its progress separately; your checkpoint is untouched."
    end
    if Boot.IsPlaceholder(w) then return false, "Nothing to keep yet: choose how to start first." end
    Boot.pendingCheckpoint = nil
    local ok, snap = pcall(SS.Save.Snapshot, w)
    if not ok then return false, "Checkpoint failed: " .. tostring(snap) end
    local valid, problems = SS.Save.Validate(snap)
    if not valid then
        SS.Log("checkpoint refused: %s", table.concat(problems or {}, "; "))
        return false, "Checkpoint refused, the game state failed validation: " .. table.concat(problems or {}, "; ")
    end
    local d = db()
    local old = d.checkpoint
    if old and old.world then
        if old.validSchema == SS.SCHEMA then
            d.checkpointPrev = old
        else
            local copy = SS.U.deepcopy(old.world)
            if SS.Save.Migrate(copy) and SS.Save.Validate(copy) then d.checkpointPrev = { savedAt = old.savedAt, world = old.world } end
        end
    end
    d.checkpoint = { savedAt = time and time() or 0, world = snap, validSchema = SS.SCHEMA }
    Boot.checkpoints = (Boot.checkpoints or 0) + 1
    return true
end

-- A world from saved data: checkpoint, its previous copy, then the last used slot.
-- Returns root, message, source or nil, reason.
function Boot.LoadInitialWorld()
    local d = db()
    local reasons = {}
    local function try(entry, label)
        if not (entry and entry.world) then return nil end
        local w = SS.U.deepcopy(entry.world)
        if not SS.Save.Migrate(w) then reasons[#reasons + 1] = label .. " uses an unknown save format"; return nil end
        local ok, problems = SS.Save.Validate(w)
        if not ok then reasons[#reasons + 1] = label .. " is damaged (" .. table.concat(problems or {}, "; ") .. ")"; return nil end
        return w, problems
    end
    local w, problems = try(d.checkpoint, "the checkpoint")
    if w then
        return w, (#problems > 0) and ("Resumed with repairs: " .. table.concat(problems, "; ")) or "Resumed where you left off.", "checkpoint"
    end
    w = try(d.checkpointPrev, "the previous checkpoint")
    if w then return w, "The last checkpoint was damaged; resumed from the one before it.", "checkpointPrev" end
    if d.active then
        local w2, msg = SS.Save.Read(d.active)
        if w2 then return w2, msg or ("Resumed from slot " .. d.active .. "."), "slot" end
        reasons[#reasons + 1] = msg
    end
    return nil, #reasons > 0 and table.concat(reasons, "; ") or nil
end

function Boot.NewWorldRoot()
    local seed = ((time and time() or 12345) % 2147483000) + 1
    local w = SS.Fixtures.NewWorld(seed)
    return w
end

-- The household shown under the first-launch choice. It is not the player's game until they
-- choose: it is never checkpointed, never "continued" and never set aside by the tutorial.
function Boot.AttachPlaceholder()
    local root = Boot.NewWorldRoot()
    Boot.placeholder = root
    Boot.UseWorld(root)
    return root
end

function Boot.IsPlaceholder(w)
    local root = w and (w.root or w)
    return root ~= nil and root == Boot.placeholder
end

-- The first-launch choice was moved past by something other than its own buttons (a module
-- changing mode, the title hidden directly) while the placeholder was underneath: that household
-- is the player's game from now on, exactly as if they had chosen "Play a ready household". It
-- stops being a placeholder, so it runs, is checkpointed and can be saved.
function Boot.AdoptPlaceholder()
    local w = SS.Sim.world
    if not (w and Boot.IsPlaceholder(w)) then return false end
    Boot.placeholder = nil
    local d = db()
    d.ui.welcomed = true
    d.active = nil
    Boot.Checkpoint()
    return true
end

-- kind: "ready" (the household's lot, live mode), "hood" (neighbourhood view when the mode
-- exists), "create" (household creation when the mode exists, else the neighbourhood, else the lot).
function Boot.NewGame(kind)
    local w = Boot.NewWorldRoot()
    local d = db()
    d.ui.welcomed = true
    d.active = nil
    Boot.placeholder = nil
    Boot.UseWorld(w)
    Boot.Checkpoint()
    if SS.UI.frame and SS.UI.HideTitle then SS.UI.HideTitle(true) end
    local modes = SS.UI.modes
    if kind == "create" then
        if modes.create then SS.UI.SetMode("create")
        elseif modes.hood then SS.UI.SetMode("hood"); SS.UI.Notice("Household creation is not in this build; here is the neighbourhood.")
        else SS.UI.Notice("Household creation is not in this build yet; you are playing the ready household.") end
    elseif kind == "hood" and modes.hood then
        SS.UI.SetMode("hood")
    else
        SS.UI.Notice("Welcome home. H shows the controls; the title screen (Menu) has the tutorial and your saves.")
    end
    return w
end

-- Continue: the checkpoint (or slot). fromMenu: the player asked explicitly.
function Boot.Continue()
    local w, msg = Boot.LoadInitialWorld()
    if not w then return false, msg or "There is nothing to continue yet." end
    Boot.UseWorld(w)
    if SS.UI.HideTitle then SS.UI.HideTitle(true) end
    if msg then SS.UI.Notice(msg) end
    return true
end

---------------------------------------------------------------------------
-- Opening and closing
---------------------------------------------------------------------------
function Boot.Open()
    if InCombatLockdown() then
        say("SideStreet opens after combat.")
        return false
    end
    local d = db()
    local firstRun = false
    if not SS.Sim.world then
        local st = SS.Tutorial and SS.Tutorial.State and SS.Tutorial.State()
        if st and st.inProgress and not SS.Tutorial.active then
            SS.UI.Show()
            SS.Tutorial.Resume()
            return true
        end
        local w, msg = Boot.LoadInitialWorld()
        if w then
            d.ui.welcomed = true
            Boot.UseWorld(w)
            Boot.pendingNotice = msg
        else
            if msg then Boot.pendingNotice = "Your saved game could not be loaded: " .. msg .. ". Your slots are untouched; a fresh household is ready." end
            firstRun = not d.ui.welcomed
            if firstRun then Boot.AttachPlaceholder() else Boot.UseWorld(Boot.NewWorldRoot()) end
        end
    end
    -- reopened while the placeholder is still underneath (the player closed the window on the
    -- first-launch choice): the choice comes back, never the placeholder household on its own
    if Boot.IsPlaceholder(SS.Sim.world) then firstRun = true end
    SS.UI.Show()
    if firstRun and SS.UI.ShowTitle then SS.UI.ShowTitle("first") end
    if Boot.pendingNotice then SS.UI.Notice(Boot.pendingNotice, "warn"); Boot.pendingNotice = nil end
    return true
end

function Boot.Toggle()
    if SS.UI.IsShown() then SS.UI.Hide() else Boot.Open() end
end

---------------------------------------------------------------------------
-- WoW events
---------------------------------------------------------------------------
function Boot.OnEvent(event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        SS.Save.DB()
        SS.Compat.Probe(true)
        if SS.Perf and SS.Perf.Install then SS.Perf.Install() end
        -- an explicit music suppression left over from a crash is put back now
        if SS.Audio and SS.Audio.RestoreGameMusic then SS.Audio.RestoreGameMusic() end
        Boot.loaded = true
    elseif event == "PLAYER_REGEN_DISABLED" then
        if SS.UI.CancelDialogs then SS.UI.CancelDialogs() end
        if SS.UI.IsShown() then
            SS.UI.Hide("combat")
            say("Combat started: the house is paused, hidden and quiet. Type /sidestreet after combat to go back.")
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- the checkpoint put off when combat closed the window (see UI.OnHidden)
        if Boot.pendingCheckpoint then Boot.pendingCheckpoint = nil; Boot.Checkpoint() end
        local a = db().audio
        if type(a) == "table" and a.restorePending and SS.Audio.RestoreGameMusic then SS.Audio.RestoreGameMusic() end
        if SS.UI.hideReason == "combat" and not SS.UI.IsShown() then
            SS.UI.hideReason = nil
            say("Combat is over. /sidestreet opens your household again.")
        end
    elseif event == "PLAYER_LEAVING_WORLD" then
        -- a loading screen (or logout/reload) takes focus: close cleanly, never reopen by itself
        if SS.UI.CancelDialogs then SS.UI.CancelDialogs() end
        if SS.UI.IsShown() then
            SS.UI.Hide("loading")
            say("Loading screen: the house is paused and closed. /sidestreet opens it again.")
        end
    elseif event == "PLAYER_LOGOUT" then
        if SS.UI.IsShown() then
            if SS.UI.SaveGeometry then pcall(SS.UI.SaveGeometry) end
            if SS.UI.camLot and SS.UI.SaveCamera then pcall(SS.UI.SaveCamera, SS.UI.camLot) end
        end
        Boot.Checkpoint()
        if SS.Audio and SS.Audio.Shutdown then SS.Audio.Shutdown() end
        if SS.Audio and SS.Audio.RestoreGameMusic then SS.Audio.RestoreGameMusic() end
    end
end

-- The event frame is created when this file runs (a frame without WoW API calls beyond
-- CreateFrame/RegisterEvent is how every addon receives ADDON_LOADED).
local ev = CreateFrame("Frame")
Boot.eventFrame = ev
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_LEAVING_WORLD", "PLAYER_LOGOUT" }) do ev:RegisterEvent(e) end
ev:SetScript("OnEvent", function(_, event, arg1) Boot.OnEvent(event, arg1) end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
Boot.HELP = {
    "/sidestreet - open or close the window",
    "/sidestreet diag - compatibility report (and the diagnostics panel when the window is open)",
    "/sidestreet perf - performance numbers; perf overlay - toggle the on-screen overlay; perf reset",
    "/sidestreet pause - pause or resume the household",
    "/sidestreet title - the title screen (new game, continue, saves)",
    "/sidestreet tutorial - start or resume the guided tour; tutorial restart - from the beginning",
    "/sidestreet reset - start a new game (asks first; your 3 save slots are kept)",
    "/sidestreet art tga|blp - art file format (when the art module supports switching)",
    "Debug: /sidestreet advance N - run N minutes (1-1440) of normal simulation",
    "Sandbox only: /sidestreet money N - add N to household funds (Options > Game > Sandbox money)",
}

local cmds = {}

cmds[""] = function() Boot.Toggle() end
cmds.open = function() if not SS.UI.IsShown() then Boot.Open() end end
cmds.toggle = cmds[""]
cmds.close = function() SS.UI.Hide() end
cmds.hide = cmds.close
cmds.help = function() for _, l in ipairs(Boot.HELP) do say(l) end end

cmds.diag = function()
    for _, line in ipairs(SS.Compat.Report()) do say(line) end
    if SS.Audio and SS.Audio.Report then for _, line in ipairs(SS.Audio.Report()) do say(line) end end
    if SS.UI.IsShown() and SS.UI.Diag then SS.UI.Diag.Toggle(true, "compat") end
end

cmds.perf = function(arg)
    if arg == "overlay" then
        SS.UI.SetPref("perfOverlay", not SS.UI.Pref("perfOverlay"))
        if SS.UI.Diag then SS.UI.Diag.RefreshOverlay() end
        say("Performance overlay " .. (SS.UI.Pref("perfOverlay") and "on" or "off") .. (SS.UI.IsShown() and "." or " (shows when the window is open)."))
        return
    end
    if arg == "reset" then SS.Perf.Reset(); say("Performance counters reset."); return end
    for _, line in ipairs(SS.Perf.Report()) do say(line) end
    if SS.UI.IsShown() and SS.UI.Diag then SS.UI.Diag.Toggle(true, "perf") end
end

cmds.pause = function()
    local w = SS.Sim.world
    if not w then say("No game is running yet."); return end
    if not SS.UI.RequestSpeed(nil) and SS.UI.CurrentMode().pausesSim then
        local r = SS.UI.resumeSpeed or 0
        say((SS.UI.CurrentMode().label or "This") .. " mode keeps the house paused; " ..
            (r == 0 and "it stays paused when you leave." or ("it resumes at " .. SS.UI.SpeedLabel(r) .. " when you leave.")))
        return
    end
    say(w.speed == 0 and "Paused." or ("Running at " .. SS.UI.SpeedLabel(w.speed) .. "."))
end

cmds.title = function()
    if InCombatLockdown() then say("SideStreet opens after combat."); return end
    if not SS.UI.IsShown() and not Boot.Open() then return end
    SS.UI.ShowTitle()
end
cmds.menu = cmds.title

cmds.tutorial = function(arg)
    if InCombatLockdown() then say("SideStreet opens after combat."); return end
    if not SS.UI.IsShown() then
        if not SS.Sim.world then
            -- open straight into the tour without loading a game first
            local d = db()
            d.ui.welcomed = true
        end
        SS.UI.Show()
    end
    local st = SS.Tutorial.State()
    if arg == "restart" or arg == "replay" then SS.Tutorial.Start(true)
    elseif arg == "skip" or arg == "stop" then if SS.Tutorial.active then SS.Tutorial.Stop(false) end
    elseif st.inProgress then SS.Tutorial.Resume()
    else SS.Tutorial.Start(st.done) end
end

cmds.reset = function(arg)
    local function doIt()
        Boot.NewGame(SS.UI.modes.hood and "hood" or "ready")
        say("New game started. Your save slots are kept.")
    end
    if arg == "confirm" then
        if not SS.UI.IsShown() and not InCombatLockdown() then Boot.Open() end
        doIt()
        return
    end
    if InCombatLockdown() then say("Not during combat."); return end
    SS.UI.Confirm("Start a new game? The game in progress is replaced; your 3 save slots are kept. (/sidestreet reset confirm does this without asking.)", function()
        if not SS.UI.IsShown() then Boot.Open() end
        doIt()
    end, function() say("Reset cancelled.") end)
end

cmds.advance = function(arg)
    local w = SS.Sim.world
    local m = tonumber(arg)
    if not w then say("No game is running yet."); return end
    if not m then say("Usage: /sidestreet advance N (minutes, 1-1440)."); return end
    m = math.max(1, math.min(1440, math.floor(m)))
    SS.Sim.Advance(w, m)
    SS.UI.dirty = true
    say("Debug: advanced " .. m .. " sim minutes through the normal simulation (scheduled events were not skipped).")
end

cmds.money = function(arg)
    local w = SS.Sim.world
    local n = tonumber(arg)
    if not w or not w.household then say("No household is running."); return end
    if not w.settings.sandboxMoney then
        say("Sandbox money is off for this save. Turn it on in Options > Game (the save is then marked as sandbox).")
        return
    end
    -- tonumber accepts "nan", "inf" and "1e999": only a finite, non-zero amount is money
    if not n or n ~= n or n == math.huge or n == -math.huge or n == 0 then say("Usage: /sidestreet money N (sandbox only; N a whole amount between -1000000 and 1000000)."); return end
    n = math.max(-1000000, math.min(1000000, math.floor(n)))
    SS.Money(w, n, "debug", "Sandbox money (debug command)")
    w.root.shell = w.root.shell or {}
    w.root.shell.sandboxUsed = true
    say(string.format("Sandbox: %s %s. This save is marked as a sandbox game.", n > 0 and "added" or "removed", SS.UI.Money(math.abs(n))))
end

cmds.art = function(arg)
    if arg ~= "tga" and arg ~= "blp" then say("Usage: /sidestreet art tga|blp"); return end
    local set = (SS.Art and type(SS.Art.SetFormat) == "function" and SS.Art.SetFormat)
        or (SS.Render and type(SS.Render.SetArtFormat) == "function" and SS.Render.SetArtFormat)
    db().settings.artFormat = arg
    if not set then
        say("Remembered '" .. arg .. "', but this build's art has no format switch yet, so nothing changed on screen.")
        return
    end
    local ok, res, reason = pcall(set, arg)
    if ok and res ~= false then
        SS.UI.dirty = true
        say("Art format: " .. arg .. ". If the lot looks wrong, switch back with /sidestreet art tga.")
    else
        say("The art module refused '" .. arg .. "': " .. tostring(ok and (reason or "no reason given") or res))
    end
end

function Boot.Slash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    local f = cmds[cmd or ""]
    if f then return f(arg ~= "" and arg or nil) end
    say("Unknown command '" .. msg .. "'.")
    cmds.help()
end
Boot.commands = cmds

SLASH_SIDESTREET1 = "/sidestreet"
SLASH_SIDESTREET2 = "/sstreet"
SlashCmdList.SIDESTREET = function(msg) Boot.Slash(msg) end
