-- SideStreet guided tutorial.
--
-- A short tour that runs on the real game systems with its own practice household (a fresh
-- world from SS.Fixtures.NewWorld with a fixed seed). It never touches the player's saves: the
-- tutorial world is kept in SideStreetDB.tutorial (step, progress snapshot), never in the slots
-- or the checkpoint, and the game in progress is checkpointed before the tour starts and comes
-- back when it ends. It can be skipped (a step or the whole tour), resumed where it was left
-- (closing the window, combat and /reload keep the step and the practice household) and
-- replayed from the start.
--
-- Each step watches real state or real events (a selection, an order in the executor's queue,
-- the pause, the camera, Free Will, panels opening, a mode visit) and moves on by itself; the
-- purely explanatory steps have a Next button.
local _, SS = ...
local UI = SS.UI
local K = UI.Kit
local TU = SS.Tutorial or {}
SS.Tutorial = TU

TU.SEED = 4242
TU.active = false
TU.flags = {}
TU.CHECK_EVERY = 0.25
TU.DONE_PAUSE = 1.2     -- real seconds the "done" tick shows before the next step

local function world() return SS.Sim.world end
local function state()
    local db = SS.Save.DB()
    db.tutorial = type(db.tutorial) == "table" and db.tutorial or {}
    return db.tutorial
end
TU.DB = state

local function member(w, id)
    local a = w and id and w.actors[id]
    return a and w.household and a.householdId == w.household.id and not a.role and a or nil
end

local function anyManual(w)
    if not w then return false end
    for _, id in ipairs(SS.Sim.ActorIds(w)) do
        local a = member(w, id)
        if a then
            if a.act and a.act.manual then return true end
            for _, o in ipairs(a.queue or {}) do if o.manual then return true end end
        end
    end
    return false
end

local function shown(f) return f ~= nil and f:IsShown() end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------
TU.STEPS = {
    { id = "welcome", title = "Welcome",
      text = "This short tour uses the real game with a practice household that is kept apart from your saves. Everything you do here really happens. Click Next to begin.",
      manual = true },
    { id = "select", title = "Choose someone",
      text = "Click a person on the lot, or their portrait at the bottom left, to select them.",
      target = function() return UI.portraitBtns and UI.portraitBtns[1] end,
      enter = function() UI.Select(nil) end,
      check = function(w) return member(w, UI.selected) ~= nil end },
    { id = "needs", title = "Needs",
      text = "These bars are the selected person's needs. Each one shows a number, an arrow for the trend and a word as well as a colour. Point at a bar to see what raises it, then click Next.",
      target = function() return UI.needsFrame end,
      enter = function() if UI.SelectTab then UI.SelectTab("needs") end end,
      manual = true },
    { id = "order", title = "Give an order",
      text = "Click an object, such as the fridge or a chair, and pick an action. Or click the floor and choose Go Here. Menus explain cost, privacy, danger and why something is unavailable.",
      target = function() return UI.viewport end,
      check = function(w) return TU.flags.ordered or anyManual(w) end },
    { id = "queue", title = "The queue",
      text = "What they are doing now and what comes next are at the bottom right. Give a second order, then click a queued action (or Cancel) to remove it.",
      target = function() return UI.queueFrame end,
      check = function() return TU.flags.cancelled end, skippable = true },
    { id = "pause", title = "Pause",
      text = "Pause with the II button or the Space key. Pausing never loses anything, and pause is always one click away.",
      target = function() return UI.speedBtns and UI.speedBtns[0] end,
      enter = function(w) if w and w.speed == 0 then SS.Sim.SetSpeed(1) end end,
      check = function(w) return w and w.speed == 0 end },
    { id = "speed", title = "Speed",
      text = "Now run time faster: press 2 or click 3x (3 is 10x). Speed changes only the simulation, never the music, captions or animations.",
      target = function() return UI.speedBtns and UI.speedBtns[2] end,
      check = function(w) return w and w.speed >= 2 end },
    { id = "camera", title = "Look around",
      text = "Q and E rotate the view, the mouse wheel or - and = zoom, right-drag or the arrow keys pan, and Tab cycles the walls. Rotate once and zoom once.",
      target = function() return UI.camStrip end,
      enter = function()
          local cam = SS.Render.cam
          TU.flags.camR, TU.flags.camZ = cam.r, cam.zoom
      end,
      check = function()
          local cam = SS.Render.cam
          if cam.r ~= TU.flags.camR then TU.flags.rotated = true end
          if cam.zoom ~= TU.flags.camZ then TU.flags.zoomed = true end
          return TU.flags.rotated and TU.flags.zoomed
      end },
    { id = "freewill", title = "Free Will",
      text = "With Free Will on, people look after themselves when they have nothing to do. Turn it on with the Free Will button on the bar.",
      target = function() return UI.fwBtn end,
      enter = function(w) if w then w.settings.freeWill = false; UI.RefreshToolbar() end end,
      check = function(w) return w and w.settings.freeWill end },
    { id = "why", title = "Why did they do that?",
      text = "Click Why? under the portrait (or press I) to see what this person considered, the scores, the reasons, and any route that failed.",
      target = function() return UI.whyBtn end,
      check = function() return UI.Inspector and shown(UI.Inspector.frame) end },
    { id = "journal", title = "The story so far",
      text = "The journal (J) keeps the household's notable moments with a portrait of who they are about. Open it.",
      target = function() return UI.journalBtn end,
      check = function() return SS.Journal and shown(SS.Journal.frame) end },
    { id = "modes", title = "Build and buy",
      text = "The mode buttons on the bar change what you do: build and buy the house, visit the neighbourhood. Open another mode, look around, then press Esc to come back.",
      target = function() return UI.modeAnchor end,
      skipIf = function()
          for name in pairs(UI.modes) do if name ~= "create" then return nil end end
          return "No other modes are in this build yet."
      end,
      check = function() return TU.flags.visitedMode and UI.mode == "live" end },
    { id = "save", title = "Saving",
      text = "The Save button keeps up to three games plus a checkpoint. The tutorial is kept separately, so your own saves are never touched. Open the save window.",
      target = function() return UI.saveBtn end,
      check = function() return UI.Title and UI.Title.saves and shown(UI.Title.saves.frame) end },
    { id = "done", title = "That's the tour",
      text = "You can replay it any time from the title screen or with /sidestreet tutorial. Finish takes you back to the title screen to start a game of your own.",
      manual = true, last = true },
}
TU.TOTAL = #TU.STEPS

function TU.State()
    local st = state()
    return { step = st.step or 1, total = TU.TOTAL, done = st.done and true or false,
        inProgress = (TU.active or st.world ~= nil) and not st.finishedRun and true or false, active = TU.active }
end

---------------------------------------------------------------------------
-- Bus: facts the steps need
---------------------------------------------------------------------------
SS.On("uiCancel", function() if TU.active then TU.flags.cancelled = true end end)
SS.On("actionStarted", function(a, act)
    if TU.active and type(act) == "table" and act.manual then TU.flags.ordered = true end
end)
SS.On("uiMode", function(name) if TU.active and name ~= "live" then TU.flags.visitedMode = true end end)

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
local function newTutorialWorld()
    local w = SS.Fixtures.NewWorld(TU.SEED)
    w.tutorial = true
    w.settings = w.settings or {}
    w.settings.freeWill = false   -- the practice household waits for your orders at first
    return w
end

-- Put the player's own game aside (checkpointed) before the tour takes the window.
local function setAside()
    local w = world()
    if w and not TU.active and not w.root.tutorial and not SS.Boot.IsPlaceholder(w) then
        SS.Boot.Checkpoint()
        TU.prevRoot = w.root
    end
end

function TU.Start(replay)
    local st = state()
    setAside()
    st.world, st.finishedRun = nil, nil
    st.step = 1
    st.startedAt = time and time() or 0
    TU.active = true
    TU.flags = {}
    SS.Boot.UseWorld(newTutorialWorld(), { tutorial = true })
    if UI.HideTitle then UI.HideTitle(true) end
    TU.EnterStep(1)
    UI.Notice(replay and "Tutorial restarted from the beginning. Your saves are not touched." or "Tutorial started. Your saves are not touched.")
end

function TU.Resume()
    local st = state()
    if TU.active and world() and world().root.tutorial then
        if UI.HideTitle then UI.HideTitle(true) end
        TU.ShowCard()
        return true
    end
    local root
    if st.world then
        root = SS.U.deepcopy(st.world)
        if not (SS.Save.Migrate(root) and SS.Save.Validate(root)) then root = nil end
    end
    if not root then
        UI.Notice("The tutorial's practice household could not be restored; starting the tour again.", "warn")
        TU.Start(true)
        return false
    end
    setAside()
    root.tutorial = true
    TU.active = true
    TU.flags = {}
    SS.Boot.UseWorld(root, { tutorial = true })
    if UI.HideTitle then UI.HideTitle(true) end
    TU.EnterStep(st.step or 1)
    UI.Notice("Tutorial resumed at step " .. (st.step or 1) .. " of " .. TU.TOTAL .. ".")
    return true
end

-- Keep the practice household and step (window closing, logout, loading a real game).
function TU.SaveProgress()
    if not TU.active then return false end
    local w = world()
    if not (w and w.root.tutorial) then return false end
    local ok, snap = pcall(SS.Save.Snapshot, w)
    if ok and SS.Save.Validate(SS.U.deepcopy(snap)) then
        state().world = snap
        return true
    end
    return false
end

-- Leave the tour (after Finish or Skip). Brings back the game that was set aside, else the
-- checkpoint, else the title screen.
function TU.Stop(finished)
    local st = state()
    TU.active = false
    TU.flags = {}
    TU.HideCard()
    st.world = nil
    if finished then st.done, st.finishedRun = true, true; st.step = TU.TOTAL end
    if not finished then st.skipped = true end
    local back = TU.prevRoot
    TU.prevRoot = nil
    if back then
        SS.Boot.UseWorld(back)
    else
        local ok = SS.Boot.Continue()
        if not ok then
            -- no game of the player's own yet: back to the start choice, over a fresh household
            SS.Boot.AttachPlaceholder()
            if UI.ShowTitle then UI.ShowTitle("first") end
            return
        end
    end
    if finished and UI.ShowTitle then UI.ShowTitle() end
end

function TU.Skip()
    UI.Confirm("Leave the tutorial? You can replay it any time from the title screen.", function()
        TU.Stop(false)
        UI.Notice("Tutorial closed. Replay it from the title screen or with /sidestreet tutorial.")
    end)
end

-- Another game was loaded (save manager, new game): the tour steps aside, keeping its progress.
function TU.Suspend()
    if not TU.active then return end
    TU.SaveProgress()
    TU.active = false
    TU.HideCard()
    TU.prevRoot = nil
end

---------------------------------------------------------------------------
-- Steps: enter, check, advance
---------------------------------------------------------------------------
function TU.EnterStep(n)
    local st = state()
    n = math.max(1, math.min(n, TU.TOTAL))
    st.step = n
    TU.doneAt = nil
    local step = TU.STEPS[n]
    local why = step.skipIf and step.skipIf()
    if why then
        UI.Notice("Tutorial: skipped \"" .. step.title .. "\" - " .. why)
        if n < TU.TOTAL then return TU.EnterStep(n + 1) end
    end
    if step.enter then step.enter(world()) end
    TU.ShowCard()
    SS.Emit("tutorialStep", n, step.id)
end

function TU.Next()
    local st = state()
    local n = st.step or 1
    local step = TU.STEPS[n]
    if step.last then TU.Stop(true); return end
    if SS.Audio and SS.Audio.Cue then SS.Audio.Cue("milestone") end
    TU.EnterStep(n + 1)
end

function TU.Update(el)
    if not TU.active or not TU.card or not TU.card:IsShown() then return end
    TU.acc = (TU.acc or 0) + el
    if TU.doneAt then
        TU.doneAt = TU.doneAt - el
        if TU.doneAt <= 0 then TU.doneAt = nil; TU.Next() end
        return
    end
    if TU.acc < TU.CHECK_EVERY then return end
    TU.acc = 0
    local step = TU.STEPS[state().step or 1]
    TU.PlaceHighlight(step)
    if step.check then
        local ok, done = pcall(step.check, world())
        if ok and done then
            TU.doneAt = TU.DONE_PAUSE
            TU.card.status:SetText("Done!")
            K.SetTextColor(TU.card.status, "good")
        end
    end
end

---------------------------------------------------------------------------
-- The tutorial card and the highlight
---------------------------------------------------------------------------
function TU.CreateCard()
    if TU.card then return TU.card end
    local c = K.Panel(UI.frame, "Tutorial", 330, 176, { movable = true, strata = "DIALOG", level = 95 })
    c:SetPoint("TOPLEFT", UI.frame, "TOPLEFT", 12, -(UI.TITLE_H + UI.BAR_H + 10))
    c.step = K.Text(c.body, 10, "inkSoft"); c.step:SetPoint("TOPLEFT")
    c.bar = K.Tex(c.body, "ARTWORK", "barBg"); c.bar:SetPoint("TOPLEFT", 0, -14); c.bar:SetSize(314, 4)
    c.fill = K.Tex(c.body, "OVERLAY", "accentHi"); c.fill:SetPoint("TOPLEFT", c.bar, "TOPLEFT"); c.fill:SetHeight(4)
    c.text = K.Text(c.body, 11, "ink"); c.text:SetPoint("TOPLEFT", 0, -24); c.text:SetPoint("TOPRIGHT", 0, -24); c.text:SetJustifyV("TOP")
    c.status = K.Text(c.body, 11, "inkSoft"); c.status:SetPoint("BOTTOMLEFT", 0, 26)
    c.next = K.Button(c.body, "Next", 70, 20, function() TU.Next() end, "Go on to the next step")
    c.next:SetPoint("BOTTOMRIGHT", 0, 0)
    c.skipStep = K.Button(c.body, "Skip step", 70, 20, function() TU.Next() end, "Move on without doing this step")
    c.skipStep:SetPoint("RIGHT", c.next, "LEFT", -4, 0)
    c.leave = K.Button(c.body, "Leave tour", 80, 20, function() TU.Skip() end, "Stop the tutorial (asks first). Replay it any time from the title screen.")
    c.leave:SetPoint("BOTTOMLEFT", 0, 0)
    c:Hide()
    TU.card = c
    TU.outline = K.Outline(UI.frame, nil, "sun", 3)
    TU.outline:SetFrameLevel(120)
    return c
end

function TU.ShowCard()
    if not UI.frame then return end
    local c = TU.CreateCard()
    local n = state().step or 1
    local step = TU.STEPS[n]
    c.title:SetText("Tutorial: " .. step.title)
    c.step:SetText("Step " .. n .. " of " .. TU.TOTAL)
    c.fill:SetWidth(math.max(1, 314 * n / TU.TOTAL))
    c.text:SetText(step.text)
    c.status:SetText(step.manual and "" or "Waiting for you to try it...")
    K.SetTextColor(c.status, "inkSoft")
    c.next:SetLabel(step.last and "Finish" or "Next")
    c.next:SetShown(step.manual and true or false)
    c.skipStep:SetShown(not step.manual)
    c:Show()
    TU.PlaceHighlight(step)
end

function TU.PlaceHighlight(step)
    if not TU.outline then return end
    local target = step and step.target and step.target()
    if target and target.IsVisible and target:IsVisible() and not (UI.clean) then TU.outline:Attach(target) else TU.outline:Attach(nil) end
end

function TU.HideCard()
    if TU.card then TU.card:Hide() end
    if TU.outline then TU.outline:Attach(nil) end
end

if UI.OnEveryFrame then UI.OnEveryFrame(function(el) TU.Update(el) end) end
-- the card follows the window: shown again when the window reopens mid-tour
if UI.OnCreate then
    UI.OnCreate(function(f)
        f:HookScript("OnShow", function() if TU.active then TU.ShowCard() end end)
    end)
end
SS.On("cleanView", function(on)
    if not TU.active or not TU.card then return end
    if on then TU.HideCard() else TU.ShowCard() end
end)
