-- SideStreet neighbourhood mode (F5): the composed map of Linden Hollow as the game's control
-- surface. Hover highlights a lot's footprint; clicking selects it and shows the information
-- panel (occupied / for sale / public) with the actions that fit: play the household, move a
-- household in with an explicit total, move out (furniture sold or packed), edit the lot (build and
-- buy; community lots with no household charges), bulldoze with confirmation, visit a venue, and
-- return to the current household. A household panel covers the household bin, household
-- selection, creating and reopening households, merging, moving and evicting members.
-- The last selected household and lot are remembered (SideStreetDB.ui.hood).
-- Owner: hood module (docs/modules/hood.md).
local _, SS = ...
local UI = SS.UI
local HD, H, HH, HL, M = SS.HoodData, SS.Hood, SS.Households, SS.HoodLots, SS.HoodMap
local U = SS.U
local HU = SS.HoodUI or {}
SS.HoodUI = HU

HU.PANEL_W, HU.TOP_H = 300, 30
HU.state = HU.state or { rot = 0, zoomIdx = HD.Tuning.defaultZoom, panX = 0, panY = 0, cutaway = true, level = 0, tab = "lot" }
local st = HU.state

local function rootOf(w) return w and (w.root or w) end
function HU.Root() return (SS.Sim and SS.Sim.root) or rootOf(SS.Sim and SS.Sim.world) end
local function money(v) return U.fmtMoney(math.floor(v or 0)) end
local function notice(msg) if msg and UI.Notice then UI.Notice(msg) end end

local function sortedKeys(t)
    local ks = {}
    for k in pairs(t or {}) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
    return ks
end

---------------------------------------------------------------------------
-- Selection memory
---------------------------------------------------------------------------
local function db() return SS.Save and SS.Save.DB and SS.Save.DB() end
function HU.Remember()
    local d = db()
    if not d then return end
    d.ui = d.ui or {}
    d.ui.hood = { lot = st.lot, hh = st.hh, rot = st.rot, zoomIdx = st.zoomIdx, cutaway = st.cutaway, tab = st.tab }
end
function HU.Recall(root)
    local d = db()
    local r = d and d.ui and d.ui.hood
    if type(r) == "table" and not HU.recalled then
        if r.lot and root.hood.lots[r.lot] then st.lot = r.lot end
        if r.hh and root.households[r.hh] then st.hh = r.hh end
        if type(r.rot) == "number" then st.rot = r.rot % 4 end
        if type(r.zoomIdx) == "number" and HD.Tuning.zooms[r.zoomIdx] then st.zoomIdx = r.zoomIdx end
        if r.cutaway ~= nil then st.cutaway = r.cutaway and true or false end
        if r.tab == "lot" or r.tab == "household" then st.tab = r.tab end
    end
    HU.recalled = true
    if st.lot and not root.hood.lots[st.lot] then st.lot = nil end
    if st.hh and not root.households[st.hh] then st.hh = nil end
    if not st.hh and root.active then st.hh = root.active.householdId end
    if not st.lot and root.active then st.lot = root.active.lotId end
end

---------------------------------------------------------------------------
-- Information (pure; the panel and the tests read it)
---------------------------------------------------------------------------
local STATUS_TEXT = {
    occupied = "Occupied", furnished = "For sale (furnished)", empty = "For sale (unfurnished)", community = "Public venue",
    ended = "Empty home (story ended)",
}
-- Status words for a lot: occupied, for sale (furnished / unfurnished), empty parcel, public venue.
function HU.StatusText(root, lotId)
    local lot = root.hood.lots[lotId]
    local status = H.LotStatus(root, lotId)
    if status == "empty" then
        local walls = false
        for _, lv in pairs(lot.walls or {}) do if next(lv) then walls = true; break end end
        if not walls then return "Empty parcel (for sale)" end
    end
    return STATUS_TEXT[status] or status
end

local function stories(lot)
    for _ in pairs(lot.floor[1] or {}) do return 2 end
    return 1
end

local function furnishing(root, lot)
    local n = 0
    for _, o in pairs(lot.objects or {}) do if H.Movable(o) then n = n + 1 end end
    local walls = 0
    for _ in pairs(lot.walls[0] or {}) do walls = walls + 1 end
    if n > 0 then return string.format("Furnished (%d pieces included in the price)", n), n end
    if walls > 0 then return "Unfurnished house", 0 end
    return "Bare land (no building)", 0
end

-- Returns { lotId, status, title, name, subtitle, lines = {}, hints = {}, desc, portraits = {rid},
--           household, venue }.
function HU.LotInfo(root, lotId, hhId)
    local lot = root.hood.lots[lotId]
    if not lot then return nil end
    local status = H.LotStatus(root, lotId)
    local info = { lotId = lotId, status = status, title = lot.address or lotId, name = lot.name, lines = {}, hints = {},
        portraits = {}, desc = lot.desc, statusText = HU.StatusText(root, lotId) }
    local L = info.lines
    if status == "occupied" then
        local hh = H.Owner(root, lotId)
        info.household = hh.id
        info.subtitle = "Home of the " .. hh.name .. " household"
        for _, rid in ipairs(hh.members) do
            local r = root.residents[rid]
            if r and not r.dead then info.portraits[#info.portraits + 1] = rid end
        end
        local total, land, structure, contents = H.Appraise(root, lot, hh)
        L[#L + 1] = string.format("Residents: %d", #info.portraits)
        L[#L + 1] = "Household cash: " .. money(hh.money)
        L[#L + 1] = string.format("Estimated value: %s (land %s, building %s, furnishings %s)", money(total), money(land), money(structure), money(contents))
        L[#L + 1] = string.format("%d x %d lot, %s", lot.w, lot.h, stories(lot) == 2 and "two stories" or "one story")
        local desc = {}
        if hh.bio and hh.bio ~= "" then desc[#desc + 1] = hh.bio end
        if lot.desc then desc[#desc + 1] = lot.desc end
        info.desc = table.concat(desc, " ")
        local p = hh.problem and SS.Premades and SS.Premades.problems[hh.problem.id]
        if p then
            info.problem = (hh.problem.solved and "Solved: " or "Problem: ") .. p.title .. (hh.problem.solved and "" or (". " .. p.hint))
        end
        if root.active and root.active.householdId == hh.id then info.playing = true end
    elseif status == "ended" then
        local hh = H.Owner(root, lotId)
        info.household = hh.id
        info.subtitle = "The story of the " .. hh.name .. " household ended here"
        local names = {}
        for _, d in ipairs(type(hh.deceased) == "table" and hh.deceased or {}) do names[#names + 1] = d.name end
        for _, rid in ipairs(hh.members or {}) do
            local r = root.residents[rid]
            if r and r.dead then names[#names + 1] = r.name end
        end
        local memorials = 0
        for _, o in pairs(lot.objects or {}) do if H.IsMemorial(o) then memorials = memorials + 1 end end
        if #names > 0 then L[#L + 1] = "In memory of " .. table.concat(names, ", ") end
        L[#L + 1] = string.format("Memorials on the lot: %d", memorials)
        local total, land, structure, contents = H.Appraise(root, lot, nil)
        L[#L + 1] = string.format("Value if sold: %s (land %s, building %s, furnishings %s)", money(total), money(land), money(structure), money(contents))
        L[#L + 1] = string.format("%d x %d lot, %s", lot.w, lot.h, stories(lot) == 2 and "two stories" or "one story")
        local pe = root.pendingEnd
        if type(pe) == "table" and pe.hh == hh.id then
            info.hints[#info.hints + 1] = "Choose how the story continues: keep the house as it is, or sell it."
        else
            info.hints[#info.hints + 1] = "The house stays exactly as it was. Put it on the market to let another household move in."
        end
    elseif status == "community" then
        local vi = H.VenueInfo(lot.venue)
        info.venue = lot.venue
        info.subtitle = (vi.label or lot.venue) .. (lot.placeholder and " (placeholder layout)" or "")
        if vi.hours then L[#L + 1] = vi.hours end
        L[#L + 1] = "Activities:"
        for _, a in ipairs(vi.activities or {}) do L[#L + 1] = "  - " .. a end
        L[#L + 1] = string.format("%d x %d lot", lot.w, lot.h)
        if lot.placeholder then info.hints[#info.hints + 1] = "This venue uses a placeholder layout until the outings module's venue builder is present." end
        local verdict = type(root.venues) == "table" and type(root.venues[lotId]) == "table" and root.venues[lotId].invalid
        if type(verdict) == "table" and verdict[1] then
            info.hints[#info.hints + 1] = "Closed after the last edit: " .. tostring(verdict[1])
        end
    else
        local hh = hhId and root.households[hhId]
        local total, land, structure, contents = H.Appraise(root, lot, nil)
        local fdesc, pieces = furnishing(root, lot)
        info.price, info.pieces = total, pieces
        info.subtitle = (status == "furnished") and "Furnished home, ready to move in" or (fdesc:find("^Bare") and "Empty parcel, ready to build on" or "Unfurnished house")
        L[#L + 1] = string.format("Size: %d x %d (%d cells), %s", lot.w, lot.h, lot.w * lot.h, stories(lot) == 2 and "two stories" or (fdesc:find("^Bare") and "no building" or "one story"))
        L[#L + 1] = string.format("Price: %s (land %s, building %s, furnishings %s)", money(total), money(land), money(structure), money(contents))
        L[#L + 1] = "Furnishing: " .. fdesc
        info.hints = H.Hints(root, lot, hh)
    end
    return info
end

-- Actions for a lot given the chosen household. Each: { id, label, enabled, why, tip, danger }.
function HU.LotActions(root, lotId, hhId)
    local lot = root.hood.lots[lotId]
    if not lot then return {} end
    local status = H.LotStatus(root, lotId)
    local acts = {}
    local function add(id, label, ok, why, tip, extra)
        local a = { id = id, label = label, enabled = ok and true or false, why = (not ok) and why or nil, tip = tip }
        if extra then for k, v in pairs(extra) do a[k] = v end end
        acts[#acts + 1] = a
        return a
    end
    local active = root.active and root.households[root.active.householdId]
    local editModes = UI.modes and (UI.modes.build or UI.modes.buy)
    if status == "occupied" then
        local hh = H.Owner(root, lotId)
        local playing = active == hh
        local okPlay, whyPlay = true, nil
        if H.LivingMembers(root, hh) == 0 then okPlay, whyPlay = false, "Nobody is left in the " .. hh.name .. " household." end
        if root.outing and not playing then okPlay, whyPlay = false, "Finish the current outing first." end
        add("play", playing and ("Return to the " .. hh.name .. " household") or ("Play the " .. hh.name .. " household"), okPlay, whyPlay,
            "Load this household on their lot and switch to live mode. Other households stay paused.", { primary = true })
        local qs = HH.MoveOutQuote(root, hh.id, "sell")
        add("moveout_sell", "Move out, sell furnished (" .. (qs.credit and money(qs.credit) or "?") .. ")", qs.ok, qs.why,
            "The house is sold with its furniture. The household keeps its people and relationships and goes to the household bin.", { danger = true, quote = qs })
        local qp = HH.MoveOutQuote(root, hh.id, "pack")
        add("moveout_pack", string.format("Move out, pack furniture (%s + %d items)", qp.credit and money(qp.credit) or "?", qp.packCount or 0), qp.ok, qp.why,
            "Land and building are sold; movable furniture goes to the household inventory to place in the next home.", { danger = true, quote = qp })
        local okEdit, whyEdit = playing, "Play the " .. hh.name .. " household to change their home."
        if not editModes then okEdit, whyEdit = false, "Build and buy modes are not in this build." end
        add("edit", "Edit this house (build and buy)", okEdit, whyEdit, "Build and buy on this lot as the household living here.")
        add("household", "Show the " .. hh.name .. " household", true, nil, "Household details, members and management.")
    elseif status == "ended" then
        local hh = H.Owner(root, lotId)
        local pe = root.pendingEnd
        if type(pe) == "table" and pe.hh == hh.id then
            add("end_keep", "Keep the house as it is", true, nil, "The house and its memorials stay exactly as they are, off the market.", { primary = true })
            add("end_sell", "Sell the house", true, nil, "The house goes on the market; the memorials move with the family records.")
        else
            add("release", "Put the house on the market", true, nil, "The house goes on the market; the memorials move with the family records.", { primary = true })
        end
        local _, whyPlay = H.Playable(root, hh)
        add("play", "Play the " .. hh.name .. " household", false, whyPlay, "Nobody is left to play in this household.")
        local okEdit, whyEdit = editModes ~= nil, "Build and buy modes are not in this build."
        if okEdit and root.outing then okEdit, whyEdit = false, "Finish the current outing first." end
        add("edit", "Edit this house (free, nobody is charged)", okEdit, whyEdit, "Build and buy on the house. Nobody lives here, so nothing is charged.")
    elseif status == "community" then
        local T = SS.Travel
        local okVisit, whyVisit = T ~= nil and T.Go ~= nil, "Travel is not in this build."
        if okVisit and not active then okVisit, whyVisit = false, "Choose a household to play first." end
        if okVisit and root.outing then okVisit, whyVisit = false, "The household is already out. Go home first." end
        -- the outings module's verdict after the last edit (SS.Venues.EndEdit): an unusable venue
        local verdict = type(root.venues) == "table" and type(root.venues[lotId]) == "table" and root.venues[lotId].invalid
        local broken = type(verdict) == "table" and verdict[1] ~= nil
        if okVisit and broken then okVisit, whyVisit = false, "This venue cannot open: " .. tostring(verdict[1]) end
        add("visit", "Visit with the " .. (active and active.name or "current") .. " household", okVisit, whyVisit,
            "Returns to your household and calls a taxi to this venue (the household's own trip, on the outing clock).", { primary = true })
        local okEdit, whyEdit = editModes ~= nil, "Build and buy modes are not in this build."
        if okEdit and root.outing then okEdit, whyEdit = false, "Finish the current outing first." end
        add("edit", "Edit this venue (free, no household charges)", okEdit, whyEdit,
            "Build and buy on the venue. Venues are edited from the neighbourhood, never charged to a household.")
        if broken then
            local V = SS.Venues
            local okFix, whyFix = V ~= nil and type(V.RestoreAnchors) == "function", "The venue repair is not in this build: edit the venue instead."
            if okFix and root.outing then okFix, whyFix = false, "Finish the current outing first." end
            add("fix_venue", "Fix venue (put back what it needs)", okFix, whyFix,
                "Puts back the counters, seats and staff spots the venue needs to open. Nothing is charged.")
        end
    else
        local hh = hhId and root.households[hhId]
        local q = hh and HH.MoveInQuote(root, hh.id, lotId)
        if hh then
            add("movein", string.format("Move in the %s household (%s)", hh.name, money(q.total)), q.ok, q.why,
                q.ok and q.text or "Moving in costs the lot's full price.", { primary = true, quote = q })
        else
            add("movein", "Move in a household", false, "Choose a household first (Households).", "Pick a household in the list, then its total price shows here.")
        end
        local okEdit, whyEdit = editModes ~= nil, "Build and buy modes are not in this build."
        if okEdit and root.outing then okEdit, whyEdit = false, "Finish the current outing first." end
        add("edit", "Edit this lot (free while nobody lives here)", okEdit, whyEdit,
            "Build and buy on the vacant lot. The price of what you build is reflected in its sale price.")
        local okB, whyB = HH.BulldozeCheck(root, lotId)
        local bare = true
        for _ in pairs(lot.objects or {}) do bare = false; break end
        if okB then
            local objs = 0
            for _, o in pairs(lot.objects) do if not (SS.Objects[o.def] and SS.Tags.Has(SS.Objects[o.def], "mailbox")) then objs = objs + 1 end end
            local walls = 0
            for _, lv in pairs(lot.walls) do for _ in pairs(lv) do walls = walls + 1 end end
            if objs == 0 and walls == 0 then okB, whyB = false, "There is nothing to bulldoze: this is bare land." end
        end
        add("bulldoze", "Bulldoze to bare land", okB, whyB, "Removes the building, garden and furniture. Nobody is harmed or deleted.", { danger = true })
    end
    local okHome, whyHome = active ~= nil, "No household is being played."
    if active and not H.Playable(root, active) and not (type(root.pendingEnd) == "table" and root.pendingEnd.hh == active.id) then
        local nxt = H.NextPlayable(root, active.id)
        if nxt then okHome, whyHome = true, nil
        else okHome, whyHome = false, "Nobody is left to play. Create a household or move one from the bin into a home." end
        add("home", nxt and ("Play the " .. nxt.name .. " household") or "Return to the current household", okHome, whyHome,
            "The story of the " .. active.name .. " household has ended. Continue with another household.")
        return acts
    end
    add("home", "Return to the current household", okHome, whyHome, "Back to the household you were playing.")
    return acts
end

-- Household information and actions for the household panel.
function HU.HouseholdInfo(root, hhId)
    local hh = root.households[hhId]
    if not hh then return nil end
    local lot = hh.lotId and root.hood.lots[hh.lotId]
    local info = { id = hh.id, title = "The " .. hh.name .. " household", members = {}, lines = {}, desc = hh.bio }
    for _, rid in ipairs(hh.members) do
        local r = root.residents[rid]
        if r then info.members[#info.members + 1] = { rid = rid, name = r.name, age = r.age, dead = r.dead, pronoun = r.pronoun } end
    end
    local living = H.LivingMembers(root, hh)
    info.subtitle = string.format("%d %s - %s", living, living == 1 and "person" or "people", lot and ("lives at " .. lot.address) or "in the household bin")
    info.lines[#info.lines + 1] = "Household cash: " .. money(hh.money)
    if lot then
        local total = H.Appraise(root, lot, hh)
        info.lines[#info.lines + 1] = "Home value: " .. money(total)
    end
    if #(hh.inventory or {}) > 0 then info.lines[#info.lines + 1] = string.format("Stored furniture and items: %d", #hh.inventory) end
    if root.active and root.active.householdId == hh.id then info.lines[#info.lines + 1] = "You are playing this household." end
    local p = hh.problem and SS.Premades and SS.Premades.problems[hh.problem.id]
    if p then info.lines[#info.lines + 1] = (hh.problem.solved and "Solved: " or "Problem: ") .. p.title end
    return info
end

function HU.HouseholdActions(root, hhId)
    local hh = root.households[hhId]
    if not hh then return {} end
    local acts = {}
    local function add(id, label, ok, why, tip, extra)
        local a = { id = id, label = label, enabled = ok and true or false, why = (not ok) and why or nil, tip = tip }
        if extra then for k, v in pairs(extra) do a[k] = v end end
        acts[#acts + 1] = a
    end
    local playing = root.active and root.active.householdId == hh.id
    local okPlay, whyPlay = hh.lotId ~= nil, "The " .. hh.name .. " household has no home. Select a lot for sale and move them in."
    if okPlay and H.LivingMembers(root, hh) == 0 then okPlay, whyPlay = false, "Nobody is left in the household." end
    if H.IsSpecial(hh) then okPlay, whyPlay = H.Playable(root, hh) end
    if okPlay and root.outing and not playing then okPlay, whyPlay = false, "Finish the current outing first." end
    add("play", playing and "Return to this household" or "Play this household", okPlay, whyPlay, "Switch to this household in live mode.", { primary = true })
    add("showlot", hh.lotId and "Show their home on the map" or "Find a home (select a lot for sale)", true, nil, "Select the household's lot, or pick a lot to move into.")
    add("edit", "Edit people in the creator", UI.modes and UI.modes.create ~= nil, "The household creator is not in this build.",
        "Reopen the household in the creator: names, looks, personality, interests, relationships.")
    local okM, whyM = true, nil
    if #HH.Choices(root, hh.id) == 0 then okM, whyM = false, "There is no other household to join." end
    if H.IsSpecial(hh) then okM, whyM = false, select(2, H.Playable(root, hh)) end
    add("merge", "Merge into another household...", okM, whyM, "All members and savings join another household (8 people at most).")
    local okD, whyD = hh.lotId == nil, "Move the household out before deleting it."
    if okD and playing then okD, whyD = false, "You are playing this household." end
    add("delete", "Delete household", okD, whyD, "Removes the household. People who live elsewhere stay in town; nobody on a lot is deleted.", { danger = true })
    return acts
end

---------------------------------------------------------------------------
-- Running actions
---------------------------------------------------------------------------
-- After the attached session changed: select a household member, refresh the main window.
local function afterAttach(world)
    if not (UI and UI.frame) then return end
    UI.selected = nil
    local ids = {}
    for id, a in pairs(world.actors or {}) do
        if world.household and a.householdId == world.household.id then ids[#ids + 1] = id end
    end
    table.sort(ids)
    UI.selected = ids[1]
    UI.dirty = true
    if UI.RefreshPortrait then pcall(UI.RefreshPortrait) end
    if UI.RefreshToolbar then pcall(UI.RefreshToolbar) end
end
HU.AfterAttach = afterAttach

-- After a household operation: the simulation re-attaches the played household itself when it
-- has to (SS.Hood.SyncSession / Handover); the main window only needs refreshing then.
local function afterOp(w0)
    local w = SS.Sim and SS.Sim.world
    if w and w ~= w0 then afterAttach(w) elseif w then UI.dirty = true end
end

-- A transaction id for one confirmed action (unique across saves: root.hood's counter). It goes
-- with the operation, so a confirmation that fires twice is refused the second time.
local function newTx(root, kind)
    root.hood.nextTx = (root.hood.nextTx or 0) + 1
    return "ui:" .. kind .. ":" .. root.hood.nextTx
end

-- Attach the played household again (after an edit session or from the map). Returns world.
function HU.ReturnHome(root, msg)
    root = root or HU.Root()
    if not root then return nil end
    local w = SS.Sim.world
    local a = root.active
    if not a then return w end
    -- a venue edit ends with the outings module's verdict (root.venues[lotId]): an unusable venue
    -- is refused in the destination chooser until it is fixed
    if w and w.editSession and not w.editSession.verdict then
        w.editSession.verdict = true
        local V = SS.Venues
        if V and type(V.EndEdit) == "function" then
            local ok, good, problems = pcall(V.EndEdit, w)
            if ok and good == false then
                local first = type(problems) == "table" and problems[1]
                msg = (msg and (msg .. " ") or "") .. "The venue cannot open like this" .. (first and (": " .. tostring(first)) or "")
                    .. ". Use Fix venue on the map or edit it again."
            end
        end
    end
    -- the played household's story ended (and its continuation was answered): continue with the
    -- next playable household instead of an empty house; never leave the player stuck
    local ahh = root.households[a.householdId]
    local waiting = type(root.pendingEnd) == "table" and ahh and root.pendingEnd.hh == ahh.id
    if not root.outing and not waiting and not (ahh and H.Playable(root, ahh)) then
        local nxt = H.NextPlayable(root, a.householdId)
        if not nxt then
            notice("Nobody is left to play. Create a household or move one from the bin into a home.")
            return nil
        end
        local ok, why, world = H.Play(root, nxt.id)
        if not ok then notice(why); return nil end
        if w and w.editSession then M.Invalidate(w.editSession.lotId) end
        afterAttach(world)
        st.hh = nxt.id
        notice(msg or ("Now playing the " .. nxt.name .. " household."))
        return world
    end
    local lotId = (root.outing and root.outing.lotId) or a.lotId
    local fromEdit = w and w.editSession
    local ahhRec = root.households[a.householdId]
    local sameHh = w and w.root == root and w.household == ahhRec
    if sameHh and w.lot and w.lot.id == lotId and not fromEdit then return w end
    if fromEdit then M.Invalidate(fromEdit.lotId) end
    -- the session plays another household record than the save's played one (merged away,
    -- handed over): play it properly (members home, starter jobs, householdPlayed)
    if not root.outing and not sameHh and ahhRec and H.Playable(root, ahhRec) then
        local ok, why, world = H.Play(root, a.householdId)
        if ok then
            afterAttach(world)
            if msg then notice(msg) end
            return world
        end
        notice(why)
    end
    local world = SS.Sim.Attach(root, lotId, a.householdId)
    afterAttach(world)
    if msg then notice(msg) end
    return world
end

-- Leaving build/buy for live mode ends an edit session (the vacant lot or venue is not played).
function HU.EndEdit()
    local w = SS.Sim and SS.Sim.world
    if not (w and w.editSession) then return false end
    local lot = w.lot
    local root = w.root
    local hh = root.active and root.households[root.active.householdId]
    HU.ReturnHome(root, "Finished editing " .. (lot.name or lot.address or lot.id) .. (hh and (". Back to the " .. hh.name .. " household.") or "."))
    return true
end

-- Confirmation: the ui-shell dialog when present (UI.Confirm), the player's "no confirmations"
-- setting, otherwise the neighbourhood's own Yes/No box. Never runs a destructive action silently.
function HU.Confirm(text, onYes, onNo)
    local d = db()
    onNo = onNo or function() notice("Cancelled: nothing was changed.") end
    if UI.ShowConfirm or (d and d.settings and d.settings.noConfirm) then return UI.Confirm(text, onYes, onNo) end
    local c = HU.confirm
    if not c then
        if not HU.frame then if onNo then onNo() end; return end
        c = CreateFrame("Frame", nil, HU.frame)
        c:SetFrameStrata("FULLSCREEN_DIALOG")
        c:SetSize(340, 120)
        c:SetPoint("CENTER")
        c:EnableMouse(true)
        UI.Kit.Tex(c, "BACKGROUND", UI.Kit.COL.panel):SetAllPoints()
        c.text = UI.Kit.Text(c, 12); c.text:SetPoint("TOPLEFT", 12, -12); c.text:SetWidth(316)
        if c.text.SetWordWrap then c.text:SetWordWrap(true) end
        c.yes = UI.Kit.Button(c, "Yes", 100, 22, function() local f = c.onYes; c:Hide(); c.onYes, c.onNo = nil, nil; if f then f() end end)
        c.yes:SetPoint("BOTTOMRIGHT", c, "BOTTOM", -6, 10)
        c.no = UI.Kit.Button(c, "No", 100, 22, function() local f = c.onNo; c:Hide(); c.onYes, c.onNo = nil, nil; if f then f() end end)
        c.no:SetPoint("BOTTOMLEFT", c, "BOTTOM", 6, 10)
        HU.confirm = c
    end
    c.text:SetText(text)
    c.onYes, c.onNo = onYes, onNo
    c:Show()
end

local function editModeName()
    if UI.modes.build then return "build" end
    if UI.modes.buy then return "buy" end
end

-- Runs a lot or household action by id. Returns ok, message.
function HU.Run(id, lotId, hhId)
    local root = HU.Root()
    if not root then return false, "No game is loaded." end
    local acts = lotId and HU.LotActions(root, lotId, hhId) or HU.HouseholdActions(root, hhId)
    local act
    for _, a in ipairs(acts) do if a.id == id then act = a end end
    if not act then return false, "That action is not available here." end
    if not act.enabled then notice(act.why); return false, act.why end
    if id == "play" then
        local target = hhId
        if lotId then local o = H.Owner(root, lotId); target = o and o.id end
        local ok, why, world = H.Play(root, target)
        if not ok then notice(why); return false, why end
        afterAttach(world)
        st.hh = target
        HU.Remember()
        if UI.SetMode then UI.SetMode("live") end
        return true, "Playing the " .. root.households[target].name .. " household."
    elseif id == "home" then
        local world = HU.ReturnHome(root)
        if not world then return false, "Nobody is left to play." end
        if UI.SetMode then UI.SetMode("live") end
        return true
    elseif id == "end_keep" or id == "end_sell" then
        local choice = (id == "end_sell") and "sell" or "keep"
        local owner = H.Owner(root, lotId)
        local ok, why
        local w = SS.Sim.world
        if SS.Death and SS.Death.Continue and w and w.root == root then
            ok, why = SS.Death.Continue(w, choice)   -- events resolves its record and calls H.OnHouseholdEnded
        else
            ok = H.OnHouseholdEnded(root, owner, choice)
            root.pendingEnd = nil
            why = choice == "sell" and "The house is on the market. Pick another household in the neighbourhood."
                or "The house stays as it was. Pick another household in the neighbourhood."
        end
        notice(why)
        M.Invalidate(lotId)
        st.hh = nil
        HU.Refresh(true)
        return ok and true or false, why
    elseif id == "release" then
        local owner = H.Owner(root, lotId)
        local lot = root.hood.lots[lotId]
        local done, msg
        HU.Confirm("Put " .. (lot.address or lotId) .. " on the market? The memorials move with the " .. owner.name .. " family records.", function()
            local ok, why = H.ReleaseLot(root, owner.id)
            notice(why)
            M.Invalidate(lotId)
            HU.Refresh(true)
            done, msg = ok, why
        end)
        return done or false, msg or "Waiting for confirmation."
    elseif id == "fix_venue" then
        local V = SS.Venues
        local lot = root.hood.lots[lotId]
        local ok, added, left = pcall(V.RestoreAnchors, lot)
        if not ok then
            local why = "The venue could not be fixed: " .. tostring(added)
            notice(why)
            return false, why
        end
        added = tonumber(added) or 0
        local okV, good, problems = true, (type(left) ~= "table" or left[1] == nil), left
        if type(V.Validate) == "function" then okV, good, problems = pcall(V.Validate, lot) end
        root.venues = type(root.venues) == "table" and root.venues or {}
        root.venues[lotId] = type(root.venues[lotId]) == "table" and root.venues[lotId] or {}
        local rec = root.venues[lotId]
        if okV and good then rec.invalid = nil elseif okV then rec.invalid = type(problems) == "table" and problems or { tostring(problems) } end
        if added > 0 then lot.version = (lot.version or 1) + 1 end
        M.Invalidate(lotId)
        HU.Refresh(true)
        local why = (rec.invalid == nil) and string.format("%s is ready to open again (%d item%s put back).", lot.name or lot.address or lotId, added, added == 1 and "" or "s")
            or ("Still not usable: " .. tostring(rec.invalid[1]) .. ". Edit the venue to fix it.")
        notice(why)
        return rec.invalid == nil, why
    elseif id == "movein" then
        local w0 = SS.Sim.world
        local ok, why = HH.MoveIn(root, hhId, lotId, { tx = newTx(root, "movein") })
        afterOp(w0)
        notice(why)
        M.Invalidate(lotId)
        HU.Refresh(true)
        return ok, why
    elseif id == "moveout_sell" or id == "moveout_pack" then
        local mode = (id == "moveout_sell") and "sell" or "pack"
        local owner = H.Owner(root, lotId)
        local q = act.quote
        local done
        local tx = newTx(root, "moveout")
        HU.Confirm(q.text .. " Relationships and people are kept.", function()
            local w0 = SS.Sim.world
            local ok, why = HH.MoveOut(root, owner.id, mode, { tx = tx })
            notice(why)
            -- moving the played household out passes play to the next household (SS.Hood.Handover)
            afterOp(w0)
            M.Invalidate(lotId)
            st.hh = owner.id
            HU.Refresh(true)
            done = ok
        end)
        return done or false, done and q.text or "Waiting for confirmation."
    elseif id == "edit" then
        local world, why = H.EditSession(root, lotId)
        if not world then notice(why); return false, why end
        afterAttach(world)
        local lot = root.hood.lots[lotId]
        HU.editing = lotId
        local m = editModeName()
        if m and UI.SetMode then UI.SetMode(m) end
        return true, "Editing " .. (lot.name or lot.address) .. (world.editVenue and " (free: no household is charged)." or ".")
    elseif id == "bulldoze" then
        local lot = root.hood.lots[lotId]
        local done
        HU.Confirm("Bulldoze " .. lot.address .. "? The building, garden and furniture are removed. Nobody is harmed or deleted.", function()
            local ok, why = HH.Bulldoze(root, lotId)
            notice(why)
            M.Invalidate(lotId)
            HU.Refresh(true)
            done = ok
        end)
        return done or false
    elseif id == "visit" then
        local world = HU.ReturnHome(root)
        if not world then return false, "No household is being played." end
        if UI.OpenTravel then
            if UI.SetMode then UI.SetMode("live") end
            UI.OpenTravel(lotId)
            return true
        end
        local rids = {}
        if SS.Travel.Candidates then
            for _, c in ipairs(SS.Travel.Candidates(world)) do if c.ok then rids[#rids + 1] = c.rid end end
        else
            for _, id in ipairs(sortedKeys(world.actors)) do
                local a = world.actors[id]
                if world.household and a.householdId == world.household.id and not a.dead then rids[#rids + 1] = id end
            end
        end
        if #rids == 0 then notice("Nobody in the household can go out right now."); return false, "Nobody in the household can go out right now." end
        local ok, why = SS.Travel.Go(world, rids, lotId)
        notice(why)
        if ok and UI.SetMode then UI.SetMode("live") end
        return ok, why
    elseif id == "household" or id == "showlot" then
        if id == "household" then
            local o = H.Owner(root, lotId)
            if o then HU.SelectHousehold(o.id) end
        else
            local hh = root.households[hhId]
            if hh and hh.lotId then HU.SelectLot(hh.lotId, true) else HU.ShowList(true); notice("Select a lot marked for sale, then move the " .. hh.name .. " household in.") end
        end
        return true
    elseif id == "delete" then
        local hh = root.households[hhId]
        local done
        HU.Confirm("Delete the " .. hh.name .. " household? Its people are removed unless they live elsewhere.", function()
            local ok, why = HH.Delete(root, hhId)
            notice(why)
            if ok then st.hh = root.active and root.active.householdId end
            HU.Refresh(true)
            done = ok
        end)
        return done or false
    elseif id == "merge" then
        local rows = {}
        for _, o in ipairs(HH.Choices(root, hhId)) do
            do
                local oid = o.id
                rows[#rows + 1] = { "Join the " .. o.name .. " household", function()
                    local w0 = SS.Sim.world
                    local ok, why = HH.Merge(root, hhId, oid, { tx = newTx(root, "merge") })
                    notice(why)
                    if ok then st.hh = oid end
                    -- merging the played household away re-attaches the merged one (SS.Hood.SyncSession)
                    afterOp(w0)
                    HU.Refresh(true)
                end }
            end
        end
        if UI.ShowMenu then UI.ShowMenu("Merge the " .. root.households[hhId].name .. " household into...", nil, rows) end
        return true
    end
    return false
end

-- Household edit ("edit" from the household panel) reopens the creator.
function HU.RunHousehold(id, hhId)
    if id == "edit" then
        if SS.CreateUI and SS.CreateUI.Open then SS.CreateUI.Open(hhId); return true end
        return false, "The household creator is not in this build."
    end
    return HU.Run(id, nil, hhId)
end

-- Member actions: move to another household, evict.
function HU.MemberMenu(rid)
    local root = HU.Root()
    local r = root and root.residents[rid]
    if not r then return end
    local rows = {}
    for _, o in ipairs(HH.Choices(root, r.householdId)) do
        do
            local oid = o.id
            rows[#rows + 1] = { "Move to the " .. o.name .. " household", function()
                local w0 = SS.Sim.world
                local ok, why = HH.MoveResident(root, rid, oid)
                afterOp(w0)
                notice(why)
                HU.Refresh(true)
            end }
        end
    end
    rows[#rows + 1] = { "Move out on their own (evict)", function()
        local tx = newTx(root, "evict")
        HU.Confirm(r.name .. " leaves the household with an equal share of the savings and starts a household in the bin.", function()
            local w0 = SS.Sim.world
            -- someone evicted from the played household leaves the lot now (SS.Hood.SyncSession)
            local ok, why = HH.Evict(root, r.householdId, rid, { tx = tx })
            afterOp(w0)
            notice(why)
            HU.Refresh(true)
        end)
    end }
    if UI.ShowMenu then UI.ShowMenu(r.name, nil, rows) end
    return rows
end

---------------------------------------------------------------------------
-- Selection and view
---------------------------------------------------------------------------
function HU.View() return M.NewView(st.rot, HD.Tuning.zooms[st.zoomIdx]) end

function HU.SelectLot(lotId, centre)
    local root = HU.Root()
    if not root or (lotId and not root.hood.lots[lotId]) then return end
    if st.lot ~= lotId then st.level = 0 end
    st.lot = lotId
    st.tab = "lot"
    if centre and lotId then HU.CentreOn(lotId) end
    HU.Remember()
    HU.dirty = true
    HU.RefreshPanel()
end

function HU.SelectHousehold(hhId)
    st.hh = hhId
    st.tab = "household"
    HU.Remember()
    HU.RefreshPanel()
    if HU.list and HU.list.frame and HU.list.frame:IsShown() then HU.RefreshList() end
end

function HU.CentreOn(lotId)
    local root = HU.Root()
    local view = HU.View()
    local x, y = M.LotCentre(root, view, lotId)
    if not x then return end
    local cw, ch = M.CanvasSize(view)
    st.panX, st.panY = (cw / 2 - x) * view.zoom, (y - ch / 2) * view.zoom
    HU.dirty = true
end

function HU.Zoom(d)
    local n = math.max(1, math.min(#HD.Tuning.zooms, st.zoomIdx + d))
    if n == st.zoomIdx then return end
    local old, new = HD.Tuning.zooms[st.zoomIdx], HD.Tuning.zooms[n]
    st.panX, st.panY = st.panX * new / old, st.panY * new / old
    st.zoomIdx = n
    HU.Remember()
    HU.dirty = true
end

function HU.Rotate(d)
    st.rot = (st.rot + d) % 4
    if st.lot then HU.CentreOn(st.lot) else st.panX, st.panY = 0, 0 end
    HU.Remember()
    HU.dirty = true
end

function HU.SetLevel(lv)
    local root = HU.Root()
    local lot = root and st.lot and root.hood.lots[st.lot]
    local top = (lot and next(lot.floor[1] or {})) and 1 or 0
    st.level = math.max(0, math.min(top, lv))
    HU.dirty = true
    HU.RefreshPanel()
end

-- Compose the scene for the current view (also used by the tests without frames).
function HU.Scene(root, vpW, vpH)
    local view = HU.View()
    local rect = vpW and M.VisibleRect(view, vpW, vpH, st.panX, st.panY) or nil
    -- the view refills one scene table instead of allocating a new one per relayout
    HU.sceneBuf = HU.sceneBuf or { flats = {}, marks = {}, items = {}, lots = {}, counts = {} }
    return M.Compose(root, view, { rect = rect, selected = st.lot, cutaway = st.cutaway, previewLevel = st.level, reuse = HU.sceneBuf }), view
end

-- Pick at a zoom-1 canvas point. Returns kind, ref.
function HU.PickAt(px, py)
    local root = HU.Root()
    return M.Pick(root, HU.View(), px, py)
end

function HU.HoverText(root, kind, ref)
    if kind == "lot" then
        local lot = root.hood.lots[ref]
        local status = H.LotStatus(root, ref)
        local who = ""
        if status == "occupied" or status == "ended" then who = " - the " .. H.Owner(root, ref).name .. " household"
        elseif status == "community" then who = " - " .. (lot.name or "") end
        return lot.address .. who .. " - " .. HU.StatusText(root, ref)
    elseif kind == "street" then return ref.name
    elseif kind == "landmark" then return ref.label
    elseif kind == "ground" then
        local names = { woods = "Hollow Woods", pond = "Millpond", meadow = "Meadow", orchard = "Old orchard", field = "Pellham fields", green = "The green" }
        return names[ref] or ""
    end
    return ""
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local K = UI.Kit
local COL = K.COL

local function usable(b, on, why)
    b.ssWhyText = (not on) and why or nil
    if b.SetUsable then b:SetUsable(on and true or false, why) end
end

local function button(parent, label, w, h, onClick, tip)
    local b
    b = K.Button(parent, label, w, h, onClick, function()
        local t = b.ssTipText or tip or ""
        if b.ssWhyText then t = (t ~= "" and (t .. "\n") or "") .. "Unavailable: " .. b.ssWhyText end
        return t
    end)
    b.ssTipText = tip
    local click = b:GetScript("OnClick")
    b:SetScript("OnClick", function(self, btn)
        if self.ssDisabled then notice(self.ssWhyText or "Not available right now."); return end
        if click then click(self, btn) end
    end)
    return b
end

-- Portrait: SS.Render.DrawPortrait into layered textures, with a drawn fallback (skin, hair,
-- initials) while the art module's portraits are pending.
function HU.Portrait(parent, size)
    local p = CreateFrame("Button", nil, parent)
    p:SetSize(size, size)
    p.back = K.Tex(p, "BACKGROUND", { 0.55, 0.72, 0.78, 1 }); p.back:SetAllPoints()
    p.layers = {}
    for n = 1, 8 do
        local t = p:CreateTexture(nil, "ARTWORK", nil, n - 1)
        t:SetPoint("CENTER")
        t:Hide()
        p.layers[n] = t
    end
    p.face = K.Tex(p, "BORDER", { 0.9, 0.75, 0.6, 1 })
    p.face:SetPoint("BOTTOM", 0, 2); p.face:SetSize(size * 0.56, size * 0.62)
    p.hair = K.Tex(p, "BORDER", { 0.3, 0.2, 0.1, 1 }, 1)
    p.hair:SetPoint("BOTTOM", p.face, "TOP", 0, -size * 0.14); p.hair:SetSize(size * 0.62, size * 0.2)
    p.initials = K.Text(p, 10, { 0.15, 0.12, 0.1 }, "CENTER")
    p.initials:SetPoint("BOTTOM", 0, 3)
    p.size = size
    return p
end

function HU.DrawPortrait(p, person)
    for _, t in ipairs(p.layers) do t:Hide() end
    if not person then p.face:Hide(); p.hair:Hide(); p.initials:SetText(""); return false end
    local shown = false
    if SS.Render and SS.Render.DrawPortrait then
        local ok = pcall(SS.Render.DrawPortrait, p.layers, person, p.size)
        if ok then for _, t in ipairs(p.layers) do if t:IsShown() then shown = true end end end
    end
    p.face:SetShown(not shown); p.hair:SetShown(not shown)
    local look = person.look or {}
    local skin = type(look.skin) == "table" and look.skin or { 0.9, 0.75, 0.6 }
    local hair = type(look.hair) == "table" and look.hair or { 0.3, 0.2, 0.1 }
    p.face:SetColorTexture(skin[1], skin[2], skin[3], 1)
    p.hair:SetColorTexture(hair[1], hair[2], hair[3], 1)
    if look.hairStyle == "bald" or look.hairStyle == "buzz" then p.hair:SetHeight(p.size * 0.06) else p.hair:SetHeight(p.size * 0.2) end
    local ini = ""
    for w in tostring(person.name or "?"):gmatch("%S+") do ini = ini .. w:sub(1, 1) end
    p.initials:SetText(shown and "" or ini:sub(1, 2))
    return shown
end

local function build(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    HU.frame = f
    K.Tex(f, "BACKGROUND", { 0.16, 0.2, 0.18, 1 }):SetAllPoints()

    -- top bar
    local top = CreateFrame("Frame", nil, f)
    top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(HU.TOP_H)
    K.Tex(top, "ARTWORK", COL.panelDark):SetAllPoints()
    HU.title = K.Text(top, 13); HU.title:SetPoint("LEFT", 8, 0)
    HU.title:SetText(HD.map.name .. " - neighbourhood")
    HU.playing = K.Text(top, 11, COL.inkSoft); HU.playing:SetPoint("LEFT", HU.title, "RIGHT", 12, 0)
    local x = -6
    local function right(b) b:SetPoint("RIGHT", top, "RIGHT", x, 0); x = x - b:GetWidth() - 4 end
    right(button(top, "+", 24, 22, function() HU.Zoom(1) end, "Zoom in (= or mouse wheel)"))
    right(button(top, "-", 24, 22, function() HU.Zoom(-1) end, "Zoom out (- or mouse wheel)"))
    right(button(top, "E", 24, 22, function() HU.Rotate(1) end, "Rotate the map (E)"))
    right(button(top, "Q", 24, 22, function() HU.Rotate(-1) end, "Rotate the map (Q)"))
    HU.createBtn = button(top, "Create", 56, 22, function()
        if SS.CreateUI and SS.CreateUI.Open then SS.CreateUI.Open(nil) end
    end, "Create a new household (1-8 people). It starts in the household bin with " .. money(HD.Tuning.startMoney) .. ".")
    right(HU.createBtn)
    HU.listBtn = button(top, "Households", 80, 22, function() HU.ShowList(not (HU.list and HU.list.frame:IsShown())) end,
        "Every household, including the household bin (households without a home).")
    right(HU.listBtn)
    HU.homeBtn = button(top, "Return home", 86, 22, function() HU.Run("home") end, "Back to the household you are playing (Esc).")
    right(HU.homeBtn)

    -- map viewport
    local vp = CreateFrame("Frame", nil, f)
    vp:SetPoint("TOPLEFT", 0, -HU.TOP_H); vp:SetPoint("BOTTOMRIGHT", -HU.PANEL_W, 0)
    if vp.SetClipsChildren then vp:SetClipsChildren(true) end
    K.Tex(vp, "BACKGROUND", { 0.2, 0.26, 0.22, 1 }):SetAllPoints()
    vp:EnableMouse(true); vp:EnableMouseWheel(true)
    HU.viewport = vp
    HU.painter = M.NewPainter(vp)
    vp:SetScript("OnMouseDown", function(_, btn) HU.MouseDown(btn) end)
    vp:SetScript("OnMouseUp", function(_, btn) HU.MouseUp(btn) end)
    vp:SetScript("OnMouseWheel", function(_, d) HU.Zoom(d > 0 and 1 or -1) end)
    vp:SetScript("OnSizeChanged", function() HU.dirty = true end)
    local hf = CreateFrame("Frame", nil, f)
    hf:SetFrameStrata("DIALOG")
    hf:SetPoint("BOTTOMLEFT", vp, "BOTTOMLEFT", 6, 6); hf:SetPoint("BOTTOMRIGHT", vp, "BOTTOMRIGHT", -6, 6); hf:SetHeight(34)
    HU.hoverText = K.Text(hf, 12, { 1, 0.96, 0.84 }); HU.hoverText:SetPoint("BOTTOMLEFT", 0, 16)
    if HU.hoverText.SetShadowOffset then HU.hoverText:SetShadowOffset(1, -1) end
    HU.helpText = K.Text(hf, 10, { 0.85, 0.85, 0.8 }); HU.helpText:SetPoint("BOTTOMLEFT", 0, 0)
    HU.helpText:SetText("Click a lot to select it. Right-drag: pan. Wheel or -/=: zoom. Q/E: rotate. Page Up/Down: preview floor. Esc: back to your household.")

    -- side panel
    local side = CreateFrame("Frame", nil, f)
    side:SetPoint("TOPRIGHT", 0, -HU.TOP_H); side:SetPoint("BOTTOMRIGHT"); side:SetWidth(HU.PANEL_W)
    K.Tex(side, "BACKGROUND", COL.panel):SetAllPoints()
    HU.side = side
    HU.tabLot = button(side, "Lot", 70, 20, function() st.tab = "lot"; HU.RefreshPanel() end, "The selected lot")
    HU.tabLot:SetPoint("TOPLEFT", 8, -6)
    HU.tabHh = button(side, "Household", 90, 20, function() st.tab = "household"; HU.RefreshPanel() end, "The selected household")
    HU.tabHh:SetPoint("LEFT", HU.tabLot, "RIGHT", 4, 0)
    HU.cutBtn = button(side, "Cutaway", 70, 20, function() st.cutaway = not st.cutaway; HU.Remember(); HU.dirty = true; HU.RefreshPanel() end,
        "Show the selected lot with its roof off: a simplified furnished interior.")
    HU.cutBtn:SetPoint("TOPRIGHT", -8, -6)

    local pw = HU.PANEL_W - 16
    HU.pTitle = K.Text(side, 14); HU.pTitle:SetPoint("TOPLEFT", 8, -34); HU.pTitle:SetWidth(pw)
    HU.pSub = K.Text(side, 11, COL.inkSoft); HU.pSub:SetPoint("TOPLEFT", HU.pTitle, "BOTTOMLEFT", 0, -3); HU.pSub:SetWidth(pw)
    HU.portraits = {}
    for n = 1, HD.Tuning.capacity do
        local p = HU.Portrait(side, 32)
        p:SetPoint("TOPLEFT", 8 + (n - 1) * 35, -72)
        p:SetScript("OnClick", function(self) if self.rid then HU.MemberMenu(self.rid) end end)
        K.Tooltip(p, function(self) return self.tip end)
        HU.portraits[n] = p
    end
    HU.pBody = K.Text(side, 11); HU.pBody:SetPoint("TOPLEFT", 8, -110); HU.pBody:SetWidth(pw)
    if HU.pBody.SetWordWrap then HU.pBody:SetWordWrap(true) end
    HU.pBody:SetJustifyV("TOP")
    HU.levelBtns = {}
    for lv = 0, 1 do
        local b = button(side, lv == 0 and "Ground floor" or "Upstairs", 96, 20, function() HU.SetLevel(lv) end,
            lv == 0 and "Preview the ground floor (Page Down)" or "Preview the upper floor (Page Up)")
        HU.levelBtns[lv] = b
    end
    HU.levelBtns[0]:SetPoint("BOTTOMLEFT", side, "BOTTOMLEFT", 8, 8 + 7 * 26)
    HU.levelBtns[1]:SetPoint("LEFT", HU.levelBtns[0], "RIGHT", 4, 0)
    HU.actionBtns = {}
    for n = 1, 7 do
        local b = button(side, "", pw, 22, function(self) if self.act then HU.OnAction(self.act) end end)
        b:SetPoint("BOTTOMLEFT", side, "BOTTOMLEFT", 8, 8 + (7 - n) * 26)
        HU.actionBtns[n] = b
    end
    HU.BuildList(f)
    f:Hide()
    return f
end

function HU.OnAction(act)
    if st.tab == "household" then
        if act.id == "edit" then return HU.RunHousehold("edit", st.hh) end
        return HU.Run(act.id, nil, st.hh)
    end
    return HU.Run(act.id, st.lot, st.hh)
end

-- Households list (the household bin and every household with a home).
function HU.BuildList(f)
    local lf = CreateFrame("Frame", nil, f)
    lf:SetPoint("TOPLEFT", HU.viewport, "TOPLEFT", 6, -6)
    lf:SetSize(250, 300)
    lf:SetFrameStrata("DIALOG")
    K.Tex(lf, "BACKGROUND", COL.panel):SetAllPoints()
    local head = K.Text(lf, 12); head:SetPoint("TOPLEFT", 8, -6); head:SetText("Households")
    local close = button(lf, "x", 20, 18, function() HU.ShowList(false) end, "Close")
    close:SetPoint("TOPRIGHT", -4, -4)
    local rows = K.PagedList(lf, 8, 30, function(r)
        r.bg = K.Tex(r, "BACKGROUND", COL.panelDark); r.bg:SetPoint("TOPLEFT", 0, -1); r.bg:SetPoint("BOTTOMRIGHT", 0, 1)
        r.name = K.Text(r, 11); r.name:SetPoint("TOPLEFT", 6, -3)
        r.detail = K.Text(r, 9, COL.inkSoft); r.detail:SetPoint("BOTTOMLEFT", 6, 3)
        r.money = K.Text(r, 10, { 0.15, 0.4, 0.18 }, "RIGHT"); r.money:SetPoint("TOPRIGHT", -6, -3)
        r:SetScript("OnClick", function(self) if self.hhId then HU.SelectHousehold(self.hhId) end end)
    end, function(r, e)
        r.hhId = e.id
        r.name:SetText(e.name .. (e.playing and "  (playing)" or ""))
        r.detail:SetText(e.detail)
        r.money:SetText(e.money)
        local c = (e.id == st.hh) and COL.accentHi or COL.panelDark
        r.bg:SetColorTexture(c[1], c[2], c[3], (e.id == st.hh) and 0.45 or 1)
    end)
    rows.frame:SetPoint("TOPLEFT", 4, -26); rows.frame:SetPoint("BOTTOMRIGHT", -4, 30)
    local create = button(lf, "Create household", 120, 20, function() if SS.CreateUI and SS.CreateUI.Open then SS.CreateUI.Open(nil) end end,
        "Design 1-8 people. New households start in the household bin with " .. money(HD.Tuning.startMoney) .. ".")
    create:SetPoint("BOTTOMLEFT", 6, 6)
    HU.list = rows
    HU.list.frame = lf
    lf:Hide()
end

-- Rows for the households list: bin first, then households with homes.
function HU.ListEntries(root)
    local out = {}
    local active = root.active and root.active.householdId
    for pass = 1, 2 do
        for _, hh in ipairs(HH.List(root)) do
            local binned = hh.lotId == nil
            if (pass == 1) == binned and H.LivingMembers(root, hh) > 0 and not H.IsSpecial(hh) then
                local lot = hh.lotId and root.hood.lots[hh.lotId]
                out[#out + 1] = { id = hh.id, name = hh.name, money = money(hh.money), playing = hh.id == active, bin = binned,
                    detail = string.format("%d %s - %s", H.LivingMembers(root, hh), H.LivingMembers(root, hh) == 1 and "person" or "people",
                        lot and lot.address or "household bin") }
            end
        end
    end
    return out
end

function HU.ShowList(on)
    if not HU.list then return end
    HU.list.frame:SetShown(on and true or false)
    if on then HU.RefreshList() end
end

function HU.RefreshList()
    local root = HU.Root()
    if not (root and HU.list) then return end
    local items = HU.ListEntries(root)
    local page = HU.list.page or 1
    HU.list:SetItems(items)
    HU.list:Page(page)
end

---------------------------------------------------------------------------
-- Panel refresh
---------------------------------------------------------------------------
local function fillActions(acts)
    for n, b in ipairs(HU.actionBtns) do
        local a = acts[n]
        if a then
            b.act = a
            if b.label then b.label:SetText(a.label) end
            b.ssTipText = a.tip
            usable(b, a.enabled, a.why)
            b:Show()
        else
            b.act = nil
            b:Hide()
        end
    end
end

function HU.RefreshPanel()
    local root = HU.Root()
    if not (root and HU.frame) then return end
    local active = root.active and root.households[root.active.householdId]
    HU.playing:SetText(active and ("Playing: the " .. active.name .. " household" .. (active.lotId and (", " .. root.hood.lots[active.lotId].address) or "")) or "No household is being played")
    usable(HU.homeBtn, active ~= nil, "No household is being played.")
    usable(HU.createBtn, SS.CreateUI ~= nil, "The household creator is not in this build.")
    HU.tabLot:SetActive(st.tab == "lot"); HU.tabHh:SetActive(st.tab == "household")
    HU.cutBtn:SetActive(st.cutaway)
    for _, p in ipairs(HU.portraits) do p:Hide(); p.rid = nil end
    local body = {}
    local showLevels = false
    if st.tab == "household" then
        local info = st.hh and HU.HouseholdInfo(root, st.hh)
        if not info then
            HU.pTitle:SetText("No household selected")
            HU.pSub:SetText("Open Households to choose one, or create a new household.")
            fillActions({})
        else
            HU.pTitle:SetText(info.title)
            HU.pSub:SetText(info.subtitle)
            local n = 0
            for _, m in ipairs(info.members) do
                if not m.dead and n < #HU.portraits then
                    n = n + 1
                    local p = HU.portraits[n]
                    p.rid = m.rid
                    p.tip = m.name .. " (" .. (m.age or "adult") .. ")\nClick: move to another household or move out."
                    HU.DrawPortrait(p, root.residents[m.rid])
                    p:Show()
                end
            end
            for _, l in ipairs(info.lines) do body[#body + 1] = l end
            local names = {}
            for _, m in ipairs(info.members) do names[#names + 1] = m.name .. (m.dead and " (remembered)" or "") end
            body[#body + 1] = "Members: " .. table.concat(names, ", ")
            if info.desc and info.desc ~= "" then body[#body + 1] = ""; body[#body + 1] = info.desc end
            fillActions(HU.HouseholdActions(root, st.hh))
        end
    else
        local info = st.lot and HU.LotInfo(root, st.lot, st.hh)
        if not info then
            HU.pTitle:SetText(HD.map.name)
            HU.pSub:SetText(HD.map.blurb)
            fillActions({})
        else
            HU.pTitle:SetText(info.title .. (info.name and (" - " .. info.name) or ""))
            HU.pSub:SetText(info.statusText .. ": " .. (info.subtitle or ""))
            for n, rid in ipairs(info.portraits) do
                local p = HU.portraits[n]
                if p then
                    local r = root.residents[rid]
                    p.rid = rid
                    p.tip = r.name .. " (" .. (r.age or "adult") .. ")"
                    HU.DrawPortrait(p, r)
                    p:Show()
                end
            end
            for _, l in ipairs(info.lines) do body[#body + 1] = l end
            if info.problem then body[#body + 1] = info.problem end
            if #info.hints > 0 then
                body[#body + 1] = ""
                for _, h in ipairs(info.hints) do body[#body + 1] = "* " .. h end
            end
            if info.desc and info.desc ~= "" then body[#body + 1] = ""; body[#body + 1] = info.desc end
            fillActions(HU.LotActions(root, st.lot, st.hh))
            local lot = root.hood.lots[st.lot]
            showLevels = st.cutaway and next(lot.floor[1] or {}) ~= nil
        end
    end
    HU.pBody:ClearAllPoints()
    HU.pBody:SetPoint("TOPLEFT", 8, (HU.portraits[1]:IsShown()) and -110 or -72)
    HU.pBody:SetText(table.concat(body, "\n"))
    for lv, b in pairs(HU.levelBtns) do b:SetShown(showLevels); b:SetActive(st.level == lv) end
    if HU.list and HU.list.frame:IsShown() then HU.RefreshList() end
end

---------------------------------------------------------------------------
-- Drawing and input
---------------------------------------------------------------------------
function HU.Relayout()
    local root = HU.Root()
    if not (root and HU.painter) then return end
    local vp = HU.viewport
    local vw, vh = vp:GetWidth() or 600, vp:GetHeight() or 400
    if vw < 10 then vw = 600 end
    if vh < 10 then vh = 400 end
    local scene, view = HU.Scene(root, vw, vh)
    local cw, ch = M.CanvasSize(view)
    local P = HU.painter
    P:Size(cw * view.zoom, ch * view.zoom)
    P.canvas:ClearAllPoints()
    P.canvas:SetPoint("CENTER", vp, "CENTER", st.panX, st.panY)
    P:Paint({ scene.flats, scene.marks, scene.items }, view.zoom)
    P:Outline(st.lot and M.FootprintOutline(root, view, st.lot) or nil, { 1, 0.86, 0.4 }, 2, view.zoom, "select")
    P:Outline((HU.hover and HU.hover ~= st.lot) and M.FootprintOutline(root, view, HU.hover) or nil, { 1, 1, 0.92 }, 1.5, view.zoom, "hover")
    P:Labels(M.Labels(root, view), view.zoom)
    HU.scene, HU.laidAt = scene, { panX = st.panX, panY = st.panY }
    HU.dirty = false
    return scene
end

local function cursorCanvas()
    local P = HU.painter
    if not P then return end
    local x, y = GetCursorPosition()
    local s = P.canvas:GetEffectiveScale() or 1
    x, y = x / s, y / s
    local left, top = P.canvas:GetLeft(), P.canvas:GetTop()
    if not left then return end
    local z = HD.Tuning.zooms[st.zoomIdx]
    return (x - left) / z, (top - y) / z
end
HU.CursorCanvas = cursorCanvas

function HU.MouseDown(btn)
    if btn == "RightButton" or btn == "MiddleButton" then
        local x, y = GetCursorPosition()
        HU.pan = { x = x, y = y, px = st.panX, py = st.panY, moved = false }
    end
end

function HU.MouseUp(btn)
    if btn == "RightButton" or btn == "MiddleButton" then
        local moved = HU.pan and HU.pan.moved
        HU.pan = nil
        if moved then HU.Remember(); HU.dirty = true end
        return
    end
    if btn ~= "LeftButton" then return end
    local px, py = cursorCanvas()
    if not px then return end
    local kind, ref = HU.PickAt(px, py)
    if kind == "lot" then HU.SelectLot(ref) end
end

function HU.SetHover(kind, ref)
    local root = HU.Root()
    local id = (kind == "lot") and ref or nil
    if HU.hover ~= id then
        HU.hover = id
        if HU.painter then
            local view = HU.View()
            HU.painter:Outline((id and id ~= st.lot) and M.FootprintOutline(root, view, id) or nil, { 1, 1, 0.92 }, 1.5, view.zoom, "hover")
        end
    end
    if HU.hoverText then HU.hoverText:SetText(kind and HU.HoverText(root, kind, ref) or "") end
end

local hoverAcc = 0
function HU.Update(el)
    if not (HU.frame and HU.frame:IsShown()) then return end
    if HU.pan then
        local x, y = GetCursorPosition()
        local s = HU.frame:GetEffectiveScale() or 1
        local dx, dy = (x - HU.pan.x) / s, (y - HU.pan.y) / s
        if math.abs(dx) + math.abs(dy) > 3 then HU.pan.moved = true end
        st.panX, st.panY = HU.pan.px + dx, HU.pan.py + dy
        HU.painter.canvas:ClearAllPoints()
        HU.painter.canvas:SetPoint("CENTER", HU.viewport, "CENTER", st.panX, st.panY)
    end
    if HU.dirty then HU.Relayout() end
    hoverAcc = hoverAcc + (el or 0)
    if hoverAcc > 0.08 and not HU.pan and HU.viewport:IsMouseOver() then
        hoverAcc = 0
        local px, py = cursorCanvas()
        if px then HU.SetHover(HU.PickAt(px, py)) end
    end
end

local KEYS = { Q = true, E = true, MINUS = true, EQUALS = true, LEFT = true, RIGHT = true, UP = true, DOWN = true, PAGEUP = true, PAGEDOWN = true, HOME = true }
function HU.OnKey(key)
    if key == "Q" then HU.Rotate(-1) elseif key == "E" then HU.Rotate(1)
    elseif key == "MINUS" then HU.Zoom(-1) elseif key == "EQUALS" then HU.Zoom(1)
    elseif key == "LEFT" then st.panX = st.panX + 80; HU.dirty = true
    elseif key == "RIGHT" then st.panX = st.panX - 80; HU.dirty = true
    elseif key == "UP" then st.panY = st.panY - 80; HU.dirty = true
    elseif key == "DOWN" then st.panY = st.panY + 80; HU.dirty = true
    elseif key == "PAGEUP" then HU.SetLevel(st.level + 1)
    elseif key == "PAGEDOWN" then HU.SetLevel(st.level - 1)
    elseif key == "HOME" then if st.lot then HU.CentreOn(st.lot) end
    else return false end
    return true
end

-- Full refresh (after a transaction): signatures, panel, list, map.
function HU.Refresh(force)
    local root = HU.Root()
    if not root then return end
    if force then M.Refresh(root) end
    HU.dirty = true
    if HU.frame then HU.RefreshPanel() end
end

-- Open the neighbourhood (optionally selecting a lot). Used by the title screen and the creator.
function HU.Open(lotId, hhId)
    local root = HU.Root()
    if root and root.hood then HU.Recall(root) end
    if hhId then st.hh = hhId; st.tab = "household" end
    if lotId then st.lot = lotId; st.tab = hhId and st.tab or "lot" end
    if UI.mode ~= "hood" and UI.SetMode then UI.SetMode("hood") else HU.Refresh(true) end
end

UI.RegisterMode("hood", {
    label = "Hood", order = 90, key = "F5", fullscreen = true, pausesSim = true, audio = "hood",
    tip = "Neighbourhood: every lot and household in " .. HD.map.name .. " (F5)",
    help = { "The neighbourhood: click a lot for its details and actions; Households lists the household bin.",
        "Q/E rotate, wheel zooms, right-drag pans. Esc returns to your household." },
    keys = KEYS,
    create = build,
    canEnter = function(w)
        local root = rootOf(w)
        if not root or type(root.hood) ~= "table" then return false, "No neighbourhood is loaded." end
        return true
    end,
    enter = function(w)
        local root = rootOf(w)
        if w and w.editSession then HU.EndEdit() end
        -- map placements: rebuilt when missing; another neighbourhood's placements follow its lots
        if H.EnsureNeighborhood and (not root.hood.layout or (H.IsLinden and not H.IsLinden(root))) then
            pcall(H.EnsureNeighborhood, root)
        end
        HU.Recall(root)
        M.Refresh(root)
        if st.lot and not HU.centred then HU.CentreOn(st.lot); HU.centred = true end
        HU.dirty = true
        HU.RefreshPanel()
        HU.Relayout()
    end,
    exit = function()
        HU.Remember()
        HU.pan = nil
        if HU.list then HU.ShowList(false) end
    end,
    onKey = function(key) return HU.OnKey(key) end,
    update = function(el) HU.Update(el) end,
})

-- Leaving build/buy for live mode ends a neighbourhood edit session; returning to the map shows
-- the edited lot's new exterior.
if SS.On then
    SS.On("uiMode", function(name)
        if name ~= "live" then return end
        if HU.EndEdit() then return end
        -- leaving the map (Esc) while the attached household's story has ended: continue with the
        -- next playable household (ReturnHome notices when there is none)
        local w = SS.Sim and SS.Sim.world
        local root = w and w.root
        local a = root and root.active
        local ahh = a and root.households[a.householdId]
        if ahh and not root.outing and not H.Playable(root, ahh) and not (type(root.pendingEnd) == "table" and root.pendingEnd.hh == ahh.id) then
            HU.ReturnHome(root)
        end
    end)
end
