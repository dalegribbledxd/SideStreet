-- SideStreet events UI: the Incidents tab, context-menu entries (fight the fire, call the fire
-- service or the police, plead with the Registrar, restore or haul away burnt things, debug
-- fire), and the household-ended continuation dialog. Owner: events module.
--
-- This file is listed in the events section of the TOC, which loads before UI/Kit.lua, so it
-- installs itself lazily: at load when SS.UI already has its registries, otherwise on the first
-- "worldAttached" (Boot attaches the world before it builds the window). docs/requests/events.md
-- asks the orchestrator for a "# [ui: events]" TOC section after UI\Kit.lua and for this file in
-- events' ownership; the lazy install keeps working either way. Mock tests only prove the wiring
-- runs without errors; nothing here has been seen in the client.
local _, SS = ...
local EU = SS.EventsUI or {}
SS.EventsUI = EU
local Ev = SS.Events
local floor = math.floor

local KIND_LABEL = {
    fire = "Fire", death = "Death", mourning = "Mourning", burglary = "Burglary", leak = "Leak", pests = "Pests",
    breakdown = "Breakdown", spoiled_food = "Spoiled food", garden = "Garden", argument = "Argument", work = "Work",
    party = "Party", bills = "Bills", visit = "Visitor", phone = "Phone call", starvation = "Hunger", shock = "Shock",
    ghost = "Ghost", guardian_lost = "No guardian", household_end = "The end", comic_casserole = "Mystery casserole",
    comic_parcel = "Stray parcel", comic_coins = "Lucky find", comic_pigeon = "Pigeon", comic_broadcast = "Midnight broadcast",
    comic_gnome = "Garden gnome", comic_hiccups = "Hiccups",
    -- kinds other modules record through SS.Events.Record
    career_chance = "Work", bill_collection = "Bill collector", report_card = "Report card", neglect = "Neglect report",
    removal = "Taken into care", adoption = "Adoption", birth = "Birth", commitment = "Commitment", grew_up = "Birthday",
    pet_adopted = "New pet", pet_ran_away = "Pet ran away",
}
EU.KIND_LABEL = KIND_LABEL

-- What the player can do about an open record (plain text for the list and tooltips).
local function hint(world, e)
    if e.kind == "fire" then
        if e.state == "active" then return "Get everyone out. Call the fire service if nobody has." end
        local d = SS.Fire and SS.Fire.Damage(world, e)
        if d then return string.format("%d charred, %d scorch, %d burnt: clear, restore or replace.", d.charred, d.scorch, d.burnt) end
    elseif e.kind == "leak" then return "Repair the fixture and mop up the puddles."
    elseif e.kind == "pests" then return "Clean up the mess and spray the colonies."
    elseif e.kind == "breakdown" then return "Repair it yourself or call a repair service."
    elseif e.kind == "burglary" then return e.data.stolen and ("Stolen: " .. e.data.stolen.name) or "An intruder is about."
    elseif e.kind == "mourning" then return "Visiting the memorial helps."
    elseif e.kind == "starvation" then return "Food, now."
    elseif e.kind == "death" then return "The Registrar of Departures will call."
    elseif e.kind == "comic_broadcast" then return "Switch it off at the set."
    elseif e.kind == "bills" and e.data.kind == "overdue" then return "Pay the overdue bills."
    elseif e.kind == "guardian_lost" then return "No grown-up is looking after the household."
    elseif e.kind == "household_end" then return "Choose how to continue."
    end
    return nil
end
EU.Hint = hint

-- Rows for the tab: open records first (newest first), then the last few resolved ones.
function EU.Rows(world, max)
    max = max or 12
    local s = Ev.State(world)
    local open, done = {}, {}
    for n = #s.list, 1, -1 do
        local e = s.list[n]
        if not e.lotId or e.lotId == world.lot.id or e.hh == (world.household and world.household.id) then
            if e.state ~= "resolved" then open[#open + 1] = e elseif #done < 6 then done[#done + 1] = e end
        end
    end
    local out = {}
    for _, e in ipairs(open) do if #out < max then out[#out + 1] = e end end
    for _, e in ipairs(done) do if #out < max then out[#out + 1] = e end end
    return out
end

function EU.RowText(world, e)
    local label = KIND_LABEL[e.kind] or e.kind
    local state = e.state == "active" and "now" or e.state == "aftermath" and "aftermath" or (e.outcome or "done")
    local when = SS.Sim.ClockText(e.t)
    return string.format("%s (%s) - %s", label, state:gsub("_", " "), when), hint(world, e)
end

-- Per-person status lines for the selected resident (grief, hunger clock, hiccups).
function EU.PersonLines(world, a)
    local out = {}
    if not a then return out end
    local p = Ev.PersonIf(world, a.id)
    if SS.Death and SS.Death.Grief then
        local g = SS.Death.Grief(world, a.id)
        if g > 0 then out[#out + 1] = string.format("Grieving (about %d more hours).", math.ceil(g)) end
    end
    if SS.Hazards and SS.Hazards.StarvationStatus then
        local st = SS.Hazards.StarvationStatus(world, a)
        if st and st.minutesLeft then out[#out + 1] = string.format("Starving: %d hours left without food.", math.max(0, math.ceil(st.minutesLeft / 60)))
        elseif st then out[#out + 1] = "Dangerously hungry." end
    end
    if p and p.hiccups and p.hiccups > world.time then out[#out + 1] = "Has the hiccups." end
    if p and p.onFire then out[#out + 1] = "ON FIRE." end
    return out
end

---------------------------------------------------------------------------------------------------
-- Continuation dialog (never uncloseable: Close always works; the choice can be made later
-- from the Incidents tab).
function EU.ShowEnded(world)
    local UI, K = SS.UI, SS.UI and SS.UI.Kit
    local pe = world.root.pendingEnd
    if not pe or not UI or not K or not UI.frame then return nil end
    local hh = world.root.households[pe.hh]
    local f = EU.endFrame
    if not f then
        f = CreateFrame("Frame", nil, UI.frame)
        f:SetSize(420, 170)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        K.Tex(f, "BACKGROUND", K.COL.panel):SetAllPoints()
        f.title = K.Text(f, 15); f.title:SetPoint("TOP", 0, -12); f.title:SetWidth(390)
        f.body = K.Text(f, 12, nil, "CENTER"); f.body:SetPoint("TOP", f.title, "BOTTOM", 0, -8); f.body:SetWidth(390)
        f.buttons = {}
        for n, ch in ipairs(SS.Death.CHOICES) do
            local b = K.Button(f, ch.label, 190, 24, function()
                f:Hide()
                local ok, msg = SS.Death.Continue(SS.Sim.world, ch.id)
                if UI.Notice and msg then UI.Notice(msg) end
            end, ch.desc)
            b:SetPoint("BOTTOMLEFT", 12 + (n - 1) * 200, 40)
            f.buttons[n] = b
        end
        f.close = K.Button(f, "Close", 80, 20, function()
            f:Hide()
            local tab = UI.tabs and UI.tabs.incidents and UI.tabs.incidents.frame
            if tab and tab.endBtn then tab.endBtn:SetShown(SS.Sim.world and SS.Sim.world.root.pendingEnd ~= nil) end
        end, "Close this for now. You can choose later from the Incidents tab.")
        f.close:SetPoint("BOTTOM", 0, 10)
        EU.endFrame = f
    end
    f.title:SetText("The " .. ((hh and hh.name) or "") .. " household has come to an end")
    -- another module may already have released the house (family: everyone went into care)
    local released = hh and hh.lotId == nil
    if released then
        f.body:SetText("Nobody is left to carry on here, and the house has already been handed back to the neighbourhood. Their memorials and history stay.")
    else
        f.body:SetText("Nobody is left to carry on here. Their memorials and history stay in the neighbourhood.")
    end
    for n, b in ipairs(f.buttons) do b:SetShown(not released or SS.Death.CHOICES[n].id == "keep") end
    f:Show()
    return f
end

-- Family's continuation hook (family request EV-2): family calls UI.ShowContinuation instead of
-- its own dialog, so the player sees one dialog: this one.
function EU.ShowContinuation(world, hh, reason)
    world = world or SS.Sim.world
    if not world then return nil end
    if SS.Death and SS.Death.AdoptEnd and hh then SS.Death.AdoptEnd(world, hh, reason) end
    return EU.ShowEnded(world)
end

---------------------------------------------------------------------------------------------------
-- The Incidents tab.
local function createTab(parent)
    local K = SS.UI.Kit
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.person = K.Text(f, 11, K.COL.warn); f.person:SetPoint("TOPLEFT", 4, -2); f.person:SetWidth(410)
    f.list = K.PagedList(f, 5, 17, function(r)
        r.text = K.Text(r, 11); r.text:SetPoint("LEFT", 4, 0); r.text:SetWidth(400)
        K.Tooltip(r, function(self) return self.tip or "" end)
    end, function(r, e)
        local line, tip = EU.RowText(SS.Sim.world, e)
        r.text:SetText(line)
        r.tip = tip or line
    end)
    f.list.frame:SetPoint("TOPLEFT", 0, -16); f.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    f.endBtn = K.Button(f, "Continue...", 80, 16, function() EU.ShowEnded(SS.Sim.world) end, "The household has ended: choose how to continue.")
    f.endBtn:SetPoint("TOPRIGHT", -2, -1)
    return f
end

local function refreshTab(f, actor, world)
    if not f or not world then return end
    local lines = EU.PersonLines(world, actor)
    f.person:SetText(table.concat(lines, "  "))
    f.list:SetItems(EU.Rows(world, 20))
    f.endBtn:SetShown(world.root.pendingEnd ~= nil)
end
EU.RefreshTab = refreshTab

---------------------------------------------------------------------------------------------------
-- Context menus.
local function objMenu(world, actor, oid, entries)
    local o = world.lot.objects[oid]
    if not o or not SS.Fire then return end
    if o.state and o.state.burnt then
        local cost = SS.Fire.RestoreCost(world, o)
        local canPay = (world.money or 0) >= cost
        entries[#entries + 1] = { label = "Restore fire damage (" .. SS.U.fmtMoney(cost) .. ")", order = 20,
            desc = "A restorer makes it good as new. Nothing fixes itself after a fire.",
            disabled = not canPay, reason = not canPay and "The household cannot afford it." or nil,
            onClick = function() local ok, msg = SS.Fire.Restore(world, oid); if SS.UI.Notice then SS.UI.Notice(msg) end end }
        entries[#entries + 1] = { label = "Haul away for scrap", order = 21,
            desc = "Removes it for a little scrap money. Buy a replacement in buy mode.",
            onClick = function()
                SS.UI.Confirm("Haul the fire-damaged item away?", function()
                    local ok, msg = SS.Fire.Discard(world, oid); if SS.UI.Notice then SS.UI.Notice(msg) end
                end)
            end }
    end
    local def = SS.Objects[o.def]
    -- the midnight broadcast: switch the set off (only while it is playing by itself)
    if o.state and o.state.selfOn and Ev.ForTarget(world, "comic_broadcast", oid) and actor then
        local ok, why = SS.Actions.Available(world, actor, o, "ev_hush")
        entries[#entries + 1] = { label = "Switch It Off", order = 2, disabled = not ok, reason = why,
            desc = "It switched itself on in the night. Switch it off (and unplug it, just in case).",
            onClick = function() SS.Actions.Order(world, actor, oid, "ev_hush", nil, nil, { data = { source = "player" } }) end }
    end
    if def and Ev.HasTag(def, "memorial") and o.state then
        entries[#entries + 1] = { label = "In memory of " .. (o.state.name or "someone"), order = 1, disabled = true,
            reason = "Day " .. (o.state.day or "?") .. ". " .. ((SS.EventsData.death.causes[o.state.cause or "unknown"] or {}).label or "") }
    end
end

-- ref for "cell" menus: { i, j, level } (or { i = , j = , level = }); see docs/requests/events.md.
local function cellMenu(world, actor, ref, entries)
    local pick = type(ref) == "table" and ref or EU.lastCell
    if not pick or not SS.Fire then return end
    local i, j, lv = pick[1] or pick.i, pick[2] or pick.j, pick[3] or pick.level or 0
    if not i or not j then return end
    i, j = floor(i), floor(j)
    local best
    for _, c in ipairs(SS.Fire.SortedCells(world.lot, true)) do
        if c.level == lv and Ev.Dist(c.i, c.j, i, j) <= 1 then best = c; break end
    end
    if best and actor then
        local ok, why = SS.Actions.Available(world, actor, world.lot.objects[best.flames], "ev_extinguish")
        entries[#entries + 1] = { label = "Put Out the Fire", order = 1, disabled = not ok, reason = why,
            desc = "Fighting a fire is risky without mechanical skill or an extinguisher.",
            onClick = function() SS.Actions.Order(world, actor, best.flames, "ev_extinguish", nil, nil, { data = { source = "player" } }) end }
    end
    if EU.DebugOn(world) then
        entries[#entries + 1] = { label = "Start a fire here (debug)", order = 99,
            desc = "Debug: starts a real fire on this cell through the normal fire system.",
            onClick = function()
                local e, why = SS.Fire.DebugIgnite(world, lv, i, j)
                if not e and why and SS.UI.Notice then SS.UI.Notice(why) end
            end }
    end
end

local function actorMenu(world, actor, ref, entries)
    local target = world.actors[ref]
    if not target or not actor then return end
    if target.role == "registrar" then
        local ok, why = SS.Actions.Available(world, actor, target, "ev_plea")
        local e = target.roleData and Ev.Find(world, target.roleData.eventId)
        entries[#entries + 1] = { label = "Plead for " .. ((e and e.data.name) or "their return"), order = 5, disabled = not ok, reason = why,
            desc = "One plea per departure. The Registrar decides once; he does not hear the same case twice.",
            onClick = function() SS.Actions.Order(world, actor, nil, "ev_plea", nil, nil, { tid = target.id }) end }
    elseif target.role == "burglar" then
        local b = target
        local e = b.roleData and Ev.Find(world, b.roleData.eventId)
        entries[#entries + 1] = { label = "Call the Police", order = 5, disabled = not e or e.data.police ~= nil,
            reason = e and e.data.police and "The police are already on the way." or nil,
            onClick = function() Ev.Pseudo(world, actor, "ev_call_police", { ev = e.id }) end }
    end
end

local function selfMenu(world, actor, ref, entries)
    if not actor then return end
    local e = SS.Fire and SS.Fire.Event(world)
    if e and e.state == "active" then
        entries[#entries + 1] = { label = "Call the Fire Service", order = 1, disabled = e.data.called ~= nil,
            reason = e.data.called and "They are already on the way." or nil,
            onClick = function() Ev.Pseudo(world, actor, "ev_call_fire", { ev = e.id }) end }
        -- the nearest burning cell, so fighting works even where the floor cannot be clicked
        local c = SS.Fire.NearestCell(world, actor)
        local flames = c and c.flames and world.lot.objects[c.flames]
        if flames then
            local ok, why = SS.Actions.Available(world, actor, flames, "ev_extinguish")
            entries[#entries + 1] = { label = "Fight the Fire", order = 2, disabled = not ok, reason = why,
                desc = "Fighting a fire is risky without mechanical skill or an extinguisher.",
                onClick = function() SS.Actions.Order(world, actor, flames.id, "ev_extinguish", nil, nil, { data = { source = "player" } }) end }
        end
    end
    local b = SS.Hazards and SS.Hazards.BurglarOnLot(world)
    local be = b and Ev.Find(world, b.roleData.eventId)
    if be then
        entries[#entries + 1] = { label = "Call the Police", order = 3, disabled = be.data.police ~= nil,
            reason = be.data.police and "The police are already on the way." or nil,
            onClick = function() Ev.Pseudo(world, actor, "ev_call_police", { ev = be.id }) end }
    end
end

EU.menus = { obj = objMenu, cell = cellMenu, actor = actorMenu, self = selfMenu }

---------------------------------------------------------------------------------------------------
-- Debug switches: "/sidestreet debug" turns debug on for this game (world.settings.debug), which
-- adds "Start a fire here (debug)" to floor menus; "/sidestreet fire" starts a fire where the
-- selected resident stands; "/sidestreet event <family>" runs an event family now (eligibility
-- still applies). Registered into ui-shell's Boot.commands table when it exists.
function EU.DebugOn(world) return world and world.settings and world.settings.debug and true or false end

function EU.SetDebug(world, on)
    if not world then return false, "No game is running yet." end
    world.settings = world.settings or {}
    if on == nil then on = not world.settings.debug end
    world.settings.debug = on and true or nil
    return true, on and "Events debug is on: floor menus offer \"Start a fire here\"; /sidestreet fire and /sidestreet event <family> work."
        or "Events debug is off."
end

local function say(msg) if msg and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then DEFAULT_CHAT_FRAME:AddMessage("SideStreet: " .. msg) end end
EU.debugCommands = {
    debug = function(arg)
        local w = SS.Sim.world
        local on = nil
        if arg == "on" then on = true elseif arg == "off" then on = false end
        local ok, msg = EU.SetDebug(w, on)
        say(msg)
        return ok
    end,
    fire = function()
        local w = SS.Sim.world
        if not w then say("No game is running yet."); return false end
        if not EU.DebugOn(w) then say("Turn debug on first: /sidestreet debug"); return false end
        -- beside the selected resident (never under them), else the middle of the lot
        local a = SS.UI and SS.UI.SelectedActor and SS.UI.SelectedActor()
        local ai, aj, lv
        if a then ai, aj, lv = Ev.CellOf(a) else ai, aj, lv = floor(w.lot.w / 2), floor(w.lot.h / 2), 0 end
        local i, j = Ev.FreeCell(w, lv, ai, aj, function(ci, cj)
            if a and ci == ai and cj == aj then return false end
            return not (SS.Fire.BurningAt and SS.Fire.BurningAt(w, lv, ci, cj))
        end, 4)
        if not i then say("No free spot for a debug fire near there."); return false end
        local e, why = SS.Fire.DebugIgnite(w, lv, i, j)
        say(e and ("Debug fire started at " .. i .. "," .. j .. ".") or ("No fire: " .. tostring(why)))
        return e ~= nil
    end,
    event = function(arg)
        local w = SS.Sim.world
        if not w then say("No game is running yet."); return false end
        if not EU.DebugOn(w) then say("Turn debug on first: /sidestreet debug"); return false end
        if not arg then
            local ids = {}
            for _, f in ipairs(SS.EventsData.families) do ids[#ids + 1] = f.id end
            say("Event families: " .. table.concat(ids, ", "))
            return false
        end
        local e, why = Ev.Debug(w, arg)
        say(e and ("Started " .. arg .. ".") or (arg .. " did not run: " .. tostring(why)))
        return e ~= nil
    end,
}

function EU.InstallCommands()
    local B = SS.Boot
    if EU.commandsInstalled or not (B and type(B.commands) == "table") then return false end
    EU.commandsInstalled = true
    for name, fn in pairs(EU.debugCommands) do
        if B.commands[name] == nil then B.commands[name] = fn end
    end
    if type(B.HELP) == "table" then
        B.HELP[#B.HELP + 1] = "Debug: /sidestreet debug [on|off] - events debug (a \"Start a fire here\" floor menu entry)"
        B.HELP[#B.HELP + 1] = "Debug: /sidestreet fire - start a fire where the selected resident stands; event <family> - run an event now"
    end
    return true
end

---------------------------------------------------------------------------------------------------
function EU.Install()
    local UI = SS.UI
    if EU.installed or not (UI and UI.RegisterTab and UI.RegisterMenu) then return false end
    EU.installed = true
    UI.RegisterTab("incidents", { label = "Incidents", order = 70, tip = "What has happened to the household, and what still needs doing.",
        create = createTab, refresh = refreshTab })
    UI.RegisterMenu("obj", objMenu)
    UI.RegisterMenu("cell", cellMenu)
    UI.RegisterMenu("actor", actorMenu)
    UI.RegisterMenu("self", selfMenu)
    -- one continuation dialog: family's UI steps aside when this is set (family request EV-2)
    UI.ShowContinuation = EU.ShowContinuation
    SS.On("householdEnded", function(world, hh, reason) EU.ShowContinuation(world, hh, reason) end)
    return true
end

if SS.UI and SS.UI.RegisterTab then EU.Install() end
EU.InstallCommands()
SS.On("worldAttached", function(world)
    EU.Install()
    EU.InstallCommands()
    if world.root.pendingEnd and SS.UI and SS.UI.frame then EU.ShowEnded(world) end
end)
