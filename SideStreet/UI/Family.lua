-- SideStreet family UI: the Family tab (household and family tree, baby care status, pet info,
-- garden overview, party planner), context-menu entries for babies, pets, children, partners,
-- party guests and garden plots, the naming dialog for new arrivals, and a fallback continuation
-- dialog when a household ends. Everything goes through the Kit registries (UI.RegisterTab,
-- UI.RegisterMenu); frames are built lazily, never at load time.
-- Owner: family module.
local _, SS = ...
local UI = SS.UI or {}
SS.UI = UI
local U = SS.U
local F = SS.Family
local FD = SS.FamilyData
local FUI = {}
UI.Family = FUI

local PAGES = { "household", "baby", "pets", "garden", "party" }
local PAGE_LABEL = { household = "Household", baby = "Baby", pets = "Pets", garden = "Garden", party = "Party" }
local PAGE_TIP = {
    household = "Who lives here, the family tree, arrivals on the way, and adoptions.",
    baby = "Babies at home: needs, where they are, care progress and the main caregiver.",
    pets = "Pets: breed, training, needs; the aquarium.",
    garden = "Plots, planters and plants: what needs care, harvests and sales.",
    party = "Plan a party: when, food and the guest list. Shows a running party's score.",
}
FUI.page = "household"
FUI.MAX_LINES = 7
FUI.idx = { baby = 1, pets = 1 }
FUI.plan = { startIdx = 1, food = "platter", selected = {}, listPage = 1, touched = false }

local function K() return UI.Kit end
local function COL() return UI.Kit.COL end
local function notice(msg) if msg and UI.Notice then UI.Notice(msg) end end

---------------------------------------------------------------------------
-- Text helpers (plain ASCII: the client font has no box-drawing glyphs)
---------------------------------------------------------------------------
local PRONOUN_WORDS = {
    child = { she = "daughter", he = "son", they = "child" },
    parent = { she = "mother", he = "father", they = "parent" },
    sibling = { she = "sister", he = "brother", they = "sibling" },
    spouse = { she = "partner", he = "partner", they = "partner" },
    guardian = { she = "guardian", he = "guardian", they = "guardian" },
    ward = { she = "ward", he = "ward", they = "ward" },
}
-- How `who` is related to `to` ("daughter", "partner"...), from the family flags (no records created).
function FUI.RelationWord(world, who, to)
    if not who or not to or who.id == to.id then return nil end
    local kind = F.PeekRel(world, who.id, to.id).flags.family
    if not kind then return nil end
    local words = PRONOUN_WORDS[kind]
    return words and (words[who.pronoun or "they"] or words.they) or kind
end

local function ageWord(r)
    if F.IsInfant(r) then return "baby" elseif F.IsChild(r) then return "child" elseif F.IsPet(r) then return r.kind end
    return nil
end

local function short(name) return (name or ""):match("^(%S+)") or name or "" end

local function fmtHours(minutes)
    if minutes >= 2880 then return string.format("%.1f days", minutes / 1440) end
    if minutes >= 120 then return math.floor(minutes / 60 + 0.5) .. " h" end
    return math.floor(minutes + 0.5) .. " min"
end

---------------------------------------------------------------------------
-- Pages: each returns title, body lines, action buttons { label, fn, why (disabled reason), tip }
---------------------------------------------------------------------------
local function callButton(world, actor, id, label, confirmText)
    local c = SS.Phone and SS.Phone.calls and SS.Phone.calls[id]
    if not c then return { label = label, why = "The phone isn't available." } end
    local ok, why = true, nil
    if not actor then ok, why = false, "Select a resident first." else ok, why = c.test(world, actor) end
    return { label = label, why = (not ok) and (why or "Not possible right now.") or nil, tip = c.label,
        fn = function()
            local function go()
                local okR, msg = c.run(world, actor)
                notice(msg or (okR and "Done." or "That didn't work."))
                FUI.dirty = true
            end
            -- adoption is not destructive (the fee is charged at the door and the notice says so):
            -- ask only when the shell has a dialog, never block it on the no-dialog fallback
            if confirmText and UI.ShowConfirm then UI.Confirm(confirmText, go) else go() end
        end }
end

-- The family tree: couples with their children, other dependents, pets, relatives elsewhere,
-- arrivals on the way. Relations are shown from the selected resident's point of view.
function FUI.TreeLines(world, hh, viewer)
    local root = F.Root(world)
    local lines = {}
    local members = F.Members(world, hh)
    local adults, deps, pets = {}, {}, {}
    for _, r in ipairs(members) do
        if F.IsPet(r) then pets[#pets + 1] = r elseif F.IsAdult(r) then adults[#adults + 1] = r else deps[#deps + 1] = r end
    end
    local function tag(r)
        local rel = viewer and FUI.RelationWord(world, r, viewer)
        if viewer and r.id == viewer.id then return " (you)" end
        return rel and (" (" .. rel .. ")") or ""
    end
    local placed, seen = {}, {}
    local function isParentOf(p, k)
        local f = k.fam and k.fam.parents
        if f then for _, id in ipairs(f) do if id == p.id then return true end end end
        return F.PeekRel(world, p.id, k.id).flags.family == "parent" or F.PeekRel(world, p.id, k.id).flags.family == "guardian"
    end
    for _, a in ipairs(adults) do
        if not seen[a.id] then
            seen[a.id] = true
            local sp = F.SpouseOf(world, a.id)
            local spr = sp and root.residents[sp]
            local line = a.name .. tag(a)
            if spr and spr.householdId == hh.id then
                seen[sp] = true
                line = line .. "  +  " .. spr.name .. tag(spr) .. ", committed"
            else
                local engagedTo
                for _, b in ipairs(adults) do
                    if b ~= a and F.PeekRel(world, a.id, b.id).flags.engaged then engagedTo = b end
                end
                if engagedTo and not seen[engagedTo.id] then seen[engagedTo.id] = true; line = line .. "  +  " .. engagedTo.name .. tag(engagedTo) .. ", engaged" end
            end
            lines[#lines + 1] = line
            local kids = {}
            for _, k in ipairs(deps) do
                if not placed[k.id] and (isParentOf(a, k) or (spr and isParentOf(spr, k))) then
                    placed[k.id] = true
                    kids[#kids + 1] = short(k.name) .. " (" .. ageWord(k) .. ")"
                end
            end
            if #kids > 0 then lines[#lines + 1] = "    children: " .. table.concat(kids, ", ") end
        end
    end
    local others = {}
    for _, k in ipairs(deps) do if not placed[k.id] then others[#others + 1] = k.name .. " (" .. ageWord(k) .. ")" .. tag(k) end end
    if #others > 0 then lines[#lines + 1] = "Also at home: " .. table.concat(others, ", ") end
    if #pets > 0 then
        local pl = {}
        for _, p in ipairs(pets) do
            local b = SS.PetData.breeds[p.kind] and SS.PetData.breeds[p.kind][p.pet and p.pet.breed or ""]
            pl[#pl + 1] = p.name .. " (" .. (b and b.name or p.kind) .. ")"
        end
        lines[#lines + 1] = "Pets: " .. table.concat(pl, ", ")
    end
    -- relatives who live elsewhere (from the household's family flags)
    local rel = root.social and root.social.rel
    if rel then
        local mine = {}
        for _, m in ipairs(members) do mine[m.id] = m end
        local found, keys = {}, {}
        for key, r in pairs(rel) do
            if r.flags and r.flags.family then
                local a, b = key:match("^(.-)>(.+)$")
                local other = a and root.residents[a]
                if other and mine[b] and not mine[a] and F.Alive(other) and not F.IsServiceHousehold(other.householdId) then
                    if not found[a] then found[a] = { other = other, to = mine[b], kind = r.flags.family }; keys[#keys + 1] = a end
                end
            end
        end
        table.sort(keys)
        if #keys > 0 then
            local parts = {}
            for n = 1, math.min(3, #keys) do
                local e = found[keys[n]]
                local word = FUI.RelationWord(world, e.other, e.to) or e.kind
                parts[#parts + 1] = e.other.name .. " (" .. short(e.to.name) .. "'s " .. word .. ")"
            end
            lines[#lines + 1] = "Family elsewhere: " .. table.concat(parts, ", ") .. (#keys > 3 and (" and " .. (#keys - 3) .. " more") or "")
        end
    end
    -- on the way
    local coming = {}
    local ids = {}
    for id, p in pairs(root.family and root.family.pending or {}) do
        if p.hh == hh.id and (p.state == "scheduled" or p.state == "onlot") then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local p = root.family.pending[id]
        local when = p.dueAt and SS.Sim.ClockText(p.dueAt) or "soon"
        if p.kind == "baby" then coming[#coming + 1] = "a baby (due " .. when .. ")"
        elseif p.kind == "adopt" then coming[#coming + 1] = "an adopted " .. (p.age == "child" and "child" or "baby") .. " (" .. when .. ")"
        elseif p.kind == "pet" then coming[#coming + 1] = "a " .. string.lower(SS.PetData.species[p.species] and SS.PetData.species[p.species].label or "pet") .. " (" .. when .. ")" end
    end
    if #coming > 0 then lines[#lines + 1] = "On the way: " .. table.concat(coming, "; ") end
    return lines
end

function FUI.PageHousehold(world, actor)
    local hh = world.household
    local c = F.Counts(world, hh)
    local petMax = (SS.PetData and SS.PetData.maxPerHousehold) or FD.petMax
    local title = "The " .. (hh.name or "") .. " household  -  " .. c.humans .. " of " .. FD.capacity .. " people, "
        .. c.pets .. " of " .. petMax .. " pets"
    local lines = FUI.TreeLines(world, hh, actor)
    local wf = F.State(world).welfare[hh.id]
    if wf and ((wf.strikes or 0) > 0 or (wf.warnings or 0) > 0) then
        lines[#lines + 1] = "Family Services: " .. (wf.strikes or 0) .. " report(s) on file, " .. (wf.warnings or 0) .. " formal warning(s)."
    end
    local AD = FD.adoption
    local buttons = {
        callButton(world, actor, "family_adopt_baby", "Adopt Baby", "Adopt a baby? Family Services brings them in a few hours; the " .. U.fmtMoney(AD.fee) .. " fee is paid at the door."),
        callButton(world, actor, "family_adopt_child", "Adopt Child", "Adopt a child? Family Services brings them in a few hours; the " .. U.fmtMoney(AD.childFee) .. " fee is paid at the door."),
        callButton(world, actor, "pets_shop_dog", "Get a Dog", "Adopt a dog from the pet shop for " .. U.fmtMoney(SS.PetData.species.dog.adoptFee) .. "?"),
        callButton(world, actor, "pets_shop_cat", "Get a Cat", "Adopt a cat from the pet shop for " .. U.fmtMoney(SS.PetData.species.cat.adoptFee) .. "?"),
        callButton(world, actor, "pets_shelter", "Shelter", "Adopt a pet from the animal shelter (a lower fee, a grateful animal)?"),
        { label = "Party...", fn = function() FUI.ShowPage("party") end, tip = "Open the party planner" },
    }
    return title, lines, buttons
end

local function needRow(p, keys, labels)
    local parts = {}
    for n, k in ipairs(keys) do parts[#parts + 1] = labels[n] .. " " .. math.floor(p.needs[k] or 0) end
    return table.concat(parts, "   ")
end

local function orderOn(world, actor, target, iid, data)
    if not actor then return { why = "Select a resident first." } end
    local ok, why = SS.Actions.Available(world, actor, target, iid)
    return { why = (not ok) and why or nil, fn = function() SS.Actions.Order(world, actor, nil, iid, nil, nil, { tid = target.id, data = data }) end }
end

function FUI.PageBaby(world, actor)
    local Inf = SS.Infants
    local list = Inf and Inf.OnLot(world, world.household.id) or {}
    if #list == 0 then
        return "No babies at home", { "Babies come by planning one with a committed partner (click them for Family >", "Plan a Baby) or by adoption through the phone. Each needs a crib; a highchair helps.",
            "Babies grow into children after " .. math.floor(FD.infant.careMinutes / 1440) .. " days of good care." }, {}
    end
    local n = ((FUI.idx.baby - 1) % #list) + 1
    FUI.idx.baby = n
    local p = list[n]
    local st = Inf.Status(world, p)
    local title = p.name .. "  -  " .. st.where .. (st.asleep and ", asleep" or "") .. (st.crying and (", crying (" .. string.lower(SS.Tuning.needLabel[st.crying] or st.crying) .. ")") or "")
    local lines = {
        needRow(p, { "hunger", "energy", "hygiene", "social", "fun" }, { "Hunger", "Energy", "Diaper", "Social", "Fun" }),
        "Growing up: " .. fmtHours(st.careMin) .. " of good care so far, " .. fmtHours(st.careLeft) .. " to go" .. (st.good and "" or "  (not well cared for right now)"),
        "Main caregiver: " .. (st.caregiver or "nobody") .. "   Feeds " .. st.feeds .. ", changes " .. st.changes .. ", night wakings " .. st.nightWakes,
    }
    if #list > 1 then lines[#lines + 1] = "Baby " .. n .. " of " .. #list .. " (Next shows the others)." end
    local cg = { label = "Caregiver", tip = "Make the selected resident " .. short(p.name) .. "'s main caregiver" }
    if not actor then cg.why = "Select a resident first."
    elseif not F.IsAdult(actor) or actor.householdId ~= p.householdId then cg.why = "Only a grown-up of this household can be the main caregiver."
    elseif st.caregiverId == actor.id then cg.why = actor.name .. " already is."
    else cg.fn = function() Inf.SetCaregiver(world, p, actor.id); FUI.dirty = true end end
    local feed = orderOn(world, actor, p, "infant_feed"); feed.label = "Feed"
    local change = orderOn(world, actor, p, "infant_change"); change.label = "Change"
    local soothe = orderOn(world, actor, p, "infant_soothe"); soothe.label = "Soothe"
    local hold = Inf.Carrier(world, p) == actor and orderOn(world, actor, p, "infant_put_down") or orderOn(world, actor, p, "infant_pickup")
    hold.label = (Inf.Carrier(world, p) == actor) and "Put Down" or "Pick Up"
    local nextB = { label = "Next", fn = function() FUI.idx.baby = FUI.idx.baby + 1; FUI.dirty = true end }
    if #list < 2 then nextB.why = "There's only one baby." end
    return title, lines, { cg, feed, change, soothe, hold, nextB }
end

function FUI.PagePets(world, actor)
    local P = SS.Pets
    local pets = F.Members(world, world.household, F.OwnPet)
    local lines = {}
    -- the aquarium line is shown with or without pets
    local aq = {}
    for _, o in ipairs(F.ObjectsWithTag(world, "aquarium")) do
        local st = P.AquariumState(world, o)
        aq[#aq + 1] = (st.fish > 0 and (st.fish .. " fish") or "empty") .. ", fed " .. fmtHours(world.time - st.fedAt) .. " ago" .. (st.dirty and ", water murky" or ", water clear")
    end
    if #pets == 0 then
        lines[1] = "No pets yet. Adopt a dog or cat from the pet shop or the shelter (Household page or the phone)."
        lines[2] = "The household may keep up to " .. SS.PetData.maxPerHousehold .. " pets. They need a bowl; a bed, toys and (cats) a litter box help."
        if aq[1] then lines[3] = "Aquarium: " .. table.concat(aq, "; ") end
        return "Pets", lines, {}
    end
    local n = ((FUI.idx.pets - 1) % #pets) + 1
    FUI.idx.pets = n
    local pet = pets[n]
    local a = world.actors[pet.id] or pet
    local s = P.Status(world, a)
    local title = pet.name .. "  -  " .. s.breed .. ", " .. s.coat .. (s.pattern and s.pattern ~= "solid" and (" " .. s.pattern) or "") .. " " .. string.lower(s.species) .. (s.asleep and ", asleep" or "")
    lines[1] = needRow(a, { "hunger", "energy", "fun", "social", "hygiene", "bladder" }, { "Hunger", "Energy", "Fun", "Social", "Clean", "Bladder" })
    lines[2] = "Training: sit " .. s.sit .. "%" .. (pet.kind == "dog" and (", house " .. s.house .. "%") or ", litter trained") .. "   Owner: " .. s.owner .. "   Accidents: " .. s.messes
    lines[3] = "Friendly " .. s.traits.friendly .. ", active " .. s.traits.active .. ", smart " .. s.traits.smart .. ", playful " .. s.traits.playful
        .. (#pets > 1 and ("   (pet " .. n .. " of " .. #pets .. ")") or "")
    if not world.actors[pet.id] then lines[3] = lines[3] .. "   Out right now." end
    if aq[1] then lines[#lines + 1] = "Aquarium: " .. table.concat(aq, "; ") end
    local onLot = world.actors[pet.id]
    local function petBtn(label, iid)
        if not onLot then return { label = label, why = pet.name .. " isn't home right now." } end
        local b = orderOn(world, actor, onLot, iid); b.label = label
        return b
    end
    local rename = { label = "Rename", fn = function() FUI.OpenNaming(world, pet) end }
    local nextB = { label = "Next", fn = function() FUI.idx.pets = FUI.idx.pets + 1; FUI.dirty = true end }
    if #pets < 2 then nextB.why = "There's only one pet." end
    return title, lines, { petBtn("Pet", "pet_pet"), petBtn("Play", "pet_play"), petBtn("Train Sit", "pet_train_sit"), rename, nextB,
        { label = "Rehome", tip = "Give " .. pet.name .. " to the animal shelter", fn = function()
            UI.Confirm("Give " .. pet.name .. " to the animal shelter? The family will miss them.", function()
                local ok, why = P.Rehome(world, pet); notice(ok and (pet.name .. " went to the shelter.") or why); FUI.dirty = true
            end)
        end } }
end

function FUI.PageGarden(world, actor)
    local Gd = SS.Garden
    local PL = SS.PlantData
    local lines = {}
    local plots, decor = {}, 0
    for _, o in ipairs(Gd.Objects(world)) do
        local kind = Gd.Kind(SS.Objects[o.def])
        if kind == "plot" then plots[#plots + 1] = o elseif kind == "decor" then decor = decor + 1 end
    end
    for n = 1, math.min(3, #plots) do
        local st = Gd.State(world, plots[n])
        local crop = st.crop and PL.crops[st.crop]
        lines[#lines + 1] = (SS.Objects[plots[n].def].name or "Plot") .. ": " .. (crop and (crop.name .. ", " .. Gd.StageName(st)) or Gd.StageName(st))
            .. (crop and not st.dead and (" - water " .. math.floor(st.water) .. "%, weeds " .. math.floor(st.weeds) .. "%") or "")
    end
    if #plots > 3 then lines[#lines + 1] = "... and " .. (#plots - 3) .. " more beds" end
    if #plots == 0 then lines[#lines + 1] = "No garden plots or planters yet. Buy one, then click it to plant seeds." end
    local tasks = Gd.Tasks(world)
    local jobs = {}
    for n = 1, math.min(3, #tasks) do jobs[#jobs + 1] = (SS.Objects[tasks[n].obj.def].name or "?") .. " (" .. table.concat(tasks[n].why, ", ") .. ")" end
    lines[#lines + 1] = #tasks == 0 and ("Everything is watered and tidy" .. (decor > 0 and (" (" .. decor .. " decorative plants)") or "") .. ".")
        or ("Needs care: " .. table.concat(jobs, "; ") .. (#tasks > 3 and " ..." or ""))
    local g = Gd.Root(world)
    local items, worth = Gd.Sellable(world)
    lines[#lines + 1] = "Harvests: " .. g.harvests .. "   Sold so far: " .. U.fmtMoney(g.sold) .. "   In the pantry: " .. #items .. " (worth " .. U.fmtMoney(worth) .. ")"
    local tend = { label = "Tend Next" }
    if not actor then tend.why = "Select a resident first."
    elseif not tasks[1] then tend.why = "Nothing needs doing."
    else
        local ok, why = SS.Actions.Available(world, actor, tasks[1].obj, "garden_tend")
        tend.why = (not ok) and why or nil
        tend.fn = function() SS.Actions.Order(world, actor, tasks[1].obj.id, "garden_tend") end
        tend.tip = "Tend " .. (SS.Objects[tasks[1].obj.def].name or "the garden")
    end
    return "Garden", lines, { tend, callButton(world, actor, "garden_sell", "Sell Produce") }
end

-- The party planner and the running party.
local function plannerCandidates(world)
    local list = SS.Parties.Candidates(world, world.household)
    return list
end

function FUI.OpenPlanner(world, caller)
    local plan = FUI.plan
    plan.selected, plan.listPage, plan.touched = {}, 1, true
    for _, rid in ipairs(SS.Parties.DefaultGuests(world, world.household)) do plan.selected[rid] = true end
    if caller and UI.Select and caller.id ~= UI.selected and F.IsMember(world, caller) and not caller.role then UI.Select(caller.id) end
    if UI.tabs and UI.tabs.family and UI.SelectTab and UI.tabBtns and UI.tabBtns.family then UI.SelectTab("family") end
    FUI.ShowPage("party")
end

local function countSelected(plan)
    local n = 0
    for _ in pairs(plan.selected) do n = n + 1 end
    return n
end

function FUI.ToggleGuest(rid)
    local plan = FUI.plan
    if plan.selected[rid] then plan.selected[rid] = nil
    elseif countSelected(plan) >= FD.party.maxGuests then notice("The guest list is capped at " .. FD.party.maxGuests .. " people.")
    else plan.selected[rid] = true end
    FUI.dirty = true
end

function FUI.Invite(world, host)
    local plan = FUI.plan
    local list = {}
    for _, c in ipairs(plannerCandidates(world)) do if plan.selected[c.rid] then list[#list + 1] = c.rid end end
    local ok, text = SS.Parties.Plan(world, host, { start = FD.party.startOptions[plan.startIdx], food = plan.food, guests = list })
    notice(text)
    if ok then plan.selected = {} end
    FUI.dirty = true
    return ok, text
end

-- Food choices: the platter (a system object), a group meal cooked by the host when household-core
-- provides SS.Chains.GroupMeal, or nothing.
local FOOD_LABEL = {
    platter = function() return "Platter " .. U.fmtMoney(FD.party.platter.cost) end,
    meal = function() return "Group Meal" end,
    none = function() return "No Food" end,
}
local FOOD_TIP = {
    platter = function() return "A party platter feeds " .. FD.party.platter.servings .. " (charged when the party starts)" end,
    meal = function() return "The host cooks a group meal when the party starts (groceries as usual)" end,
    none = function() return "No food: hungry guests leave early" end,
}
function FUI.FoodOptions()
    local out = { "platter" }
    if SS.Chains and SS.Chains.GroupMeal then out[#out + 1] = "meal" end
    out[#out + 1] = "none"
    return out
end

function FUI.PageParty(world, actor)
    local Pa = SS.Parties
    local P = FD.party
    local st = Pa.Status(world)
    local lines, buttons = {}, {}
    if st then
        local title = st.state == "planned" and ("Party planned for " .. SS.Sim.ClockText(st.startAt)) or ("Party under way  -  score " .. st.score)
        lines[1] = st.coming .. " of " .. st.invited .. " invited guests coming, " .. st.arrived .. " arrived, " .. st.here .. " here now, " .. st.left .. " gone home."
        lines[2] = "Food: " .. (st.food == "platter" and (st.servings .. " servings left on the platter") or (st.food == "meal" and "a group meal") or "none") .. "   Music: " .. (st.music and "on" or "none")
            .. "   Ends by " .. SS.Sim.ClockText(st.endAt):gsub("^Day %d+%s+", "")
        if st.parts then
            local p = st.parts
            lines[3] = string.format("Enjoyment %d  Conversation %d  Food %d  Music %d  Rooms %d  Needs %d%s",
                p.fun or 0, p.social or 0, p.food or 0, p.music or 0, p.room or 0, p.needs or 0, (p.penalty or 0) > 0 and ("  (-" .. math.floor(p.penalty) .. " early exits)") or "")
        end
        buttons[1] = { label = st.state == "planned" and "Call Off" or "End Party", tip = st.state == "planned" and "Cancel the party (nothing is charged)" or "Thank the guests and end the party now",
            fn = function()
                UI.Confirm(st.state == "planned" and "Call off the party?" or "End the party now? The guests will head home.", function()
                    local ok, text = Pa.End(world, nil, "host")
                    notice(text or (ok and "The party is over." or "No party is running."))
                    FUI.dirty = true
                end)
            end }
        if st.state == "running" and actor then
            local toast = { label = "Toast", tip = "Raise a toast to the guests nearby" }
            local near
            for _, id in ipairs(SS.Sim.ActorIds(world)) do
                local a = world.actors[id]
                if a ~= actor and Pa.GuestOf(world, a) and (not near or F.Dist(a, actor) < F.Dist(near, actor)) then near = a end
            end
            if not near then toast.why = "No guests here yet." else
                local b = orderOn(world, actor, near, "party_toast")
                toast.why, toast.fn = b.why, b.fn
            end
            buttons[2] = toast
        end
        return title, lines, buttons, false
    end
    -- planning
    local plan = FUI.plan
    if not plan.touched then
        plan.touched = true
        for _, rid in ipairs(Pa.DefaultGuests(world, world.household)) do plan.selected[rid] = true end
    end
    local ok, why = Pa.PlanCheck(world, actor)
    local start = P.startOptions[plan.startIdx] or 0
    local n = countSelected(plan)
    local last = Pa.Root(world).history
    last = last[#last]
    lines[1] = (ok and "" or (why .. "  ")) .. n .. " of up to " .. P.maxGuests .. " guests picked. Close friends are likelier to come."
    if last then lines[2] = "Last party: " .. last.text end
    buttons[1] = { label = start == 0 and "Start: Now" or ("Start: " .. math.floor(start / 60) .. " h"), tip = "When the party starts",
        fn = function() plan.startIdx = plan.startIdx % #P.startOptions + 1; FUI.dirty = true end }
    local foods = FUI.FoodOptions()
    local fidx = 1
    for n, f in ipairs(foods) do if f == plan.food then fidx = n end end
    plan.food = foods[fidx]
    buttons[2] = { label = FOOD_LABEL[plan.food](), tip = FOOD_TIP[plan.food](),
        fn = function() plan.food = foods[fidx % #foods + 1]; FUI.dirty = true end }
    buttons[3] = { label = "Invite", tip = "Send the invitations",
        why = (not ok and why) or (not actor and "Select a resident first.") or (n == 0 and "Pick at least one guest.") or nil,
        fn = function() FUI.Invite(world, actor) end }
    buttons[4] = { label = "Clear", fn = function() plan.selected = {}; FUI.dirty = true end }
    local cands = plannerCandidates(world)
    local pages = math.max(1, math.ceil(#cands / 8))
    buttons[5] = { label = "More", why = pages < 2 and "Everyone is on this page." or nil, tip = "Page " .. plan.listPage .. " of " .. pages,
        fn = function() plan.listPage = plan.listPage % pages + 1; FUI.dirty = true end }
    return "Plan a Party", lines, buttons, true, cands
end

local PAGE_FN = { household = "PageHousehold", baby = "PageBaby", pets = "PagePets", garden = "PageGarden", party = "PageParty" }

---------------------------------------------------------------------------
-- The Family tab
---------------------------------------------------------------------------
function FUI.Create(parent)
    local Kt, C = K(), COL()
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.pageBtns = {}
    for n, p in ipairs(PAGES) do
        local b = Kt.Button(f, PAGE_LABEL[p], 70, 18, function() FUI.ShowPage(p) end, PAGE_TIP[p])
        b:SetPoint("TOPLEFT", 0, -(n - 1) * 21)
        f.pageBtns[p] = b
    end
    f.title = Kt.Text(f, 12, C.ink); f.title:SetPoint("TOPLEFT", 78, -2); f.title:SetWidth(344)
    f.body = Kt.Text(f, 10, C.inkSoft); f.body:SetPoint("TOPLEFT", 78, -18); f.body:SetWidth(344)
    f.body:SetJustifyV("TOP"); f.body:SetHeight(78)
    f.actions = {}
    for n = 1, 6 do
        local b = Kt.Button(f, "", 55, 18, function(self) if self.fn then self.fn() end end, function(self) return self.tipText end)
        b:SetPoint("BOTTOMLEFT", 78 + (n - 1) * 58, 0)
        b:Hide()
        f.actions[n] = b
    end
    -- party planner guest grid (2 x 4)
    f.guests = {}
    for n = 1, 8 do
        local b = Kt.Button(f, "", 170, 14, function(self) if self.rid then FUI.ToggleGuest(self.rid) end end, function(self) return self.tipText end)
        b:SetPoint("TOPLEFT", 78 + ((n - 1) % 2) * 174, -34 - math.floor((n - 1) / 2) * 16)
        b.label:SetJustifyH("LEFT")
        b:Hide()
        f.guests[n] = b
    end
    FUI.frame = f
    FUI.dirty = true
    return f
end

function FUI.ShowPage(name)
    if not PAGE_FN[name] then return end
    FUI.page = name
    FUI.dirty = true
    if FUI.frame and SS.Sim.world then FUI.Refresh(FUI.frame, UI.SelectedActor and UI.SelectedActor(), SS.Sim.world) end
end

-- Refreshed with the panel (5 times a second): rebuild the page at most every half second of
-- real time, or at once after a click.
function FUI.Refresh(f, actor, world)
    if not f or not world or not world.household then return end
    local now = (GetTime and GetTime()) or 0
    if not FUI.dirty and FUI.lastAt and now - FUI.lastAt < 0.5 and FUI.lastActor == (actor and actor.id) then return end
    FUI.dirty, FUI.lastAt, FUI.lastActor = false, now, actor and actor.id
    for p, b in pairs(f.pageBtns) do b:SetActive(p == FUI.page) end
    local title, lines, buttons, planner, cands = FUI[PAGE_FN[FUI.page]](world, actor)
    f.title:SetText(title or "")
    lines = lines or {}
    if #lines > FUI.MAX_LINES then   -- the tab area is 122 px high: keep the body inside it
        local cut = {}
        for n = 1, FUI.MAX_LINES - 1 do cut[n] = lines[n] end
        cut[FUI.MAX_LINES] = "... and " .. (#lines - FUI.MAX_LINES + 1) .. " more lines"
        lines = cut
    end
    f.body:SetText(table.concat(lines, "\n"))
    FUI.lastLines = lines
    for n, b in ipairs(f.actions) do
        local d = buttons and buttons[n]
        if d and d.label then
            b.label:SetText(d.label)
            b.fn = (not d.why) and d.fn or nil
            b.tipText = d.why or d.tip or d.label
            b:SetUsable(not d.why)
            b:Show()
        else
            b.fn = nil
            b:Hide()
        end
    end
    -- the guest grid only on the planner
    local plan = FUI.plan
    for n, b in ipairs(f.guests) do
        local c = planner and cands and cands[(plan.listPage - 1) * 8 + n]
        if c then
            local picked = plan.selected[c.rid]
            local acc = SS.Parties.AcceptChance(world, c.rid, world.household, world.time)
            b.rid = c.rid
            b.label:SetText((picked and "[x] " or "[  ] ") .. c.name .. (c.known and "" or "  (stranger)"))
            b.tipText = c.name .. ": relationship " .. math.floor(c.life) .. ", about " .. math.floor(acc * 100 + 0.5) .. "% likely to come"
            b:SetActive(picked and true or false)
            b:Show()
        else
            b.rid = nil
            b:Hide()
        end
    end
    if planner then f.body:SetHeight(14) else f.body:SetHeight(78) end
end

UI.RegisterTab("family", {
    label = "Family", order = 40, tip = "Household, babies, pets, garden and parties",
    create = function(parent) return FUI.Create(parent) end,
    refresh = function(frame, actor, world) FUI.Refresh(frame, actor, world) end,
})

-- The phone's "Throw a Party" call opens the planner when the UI is up.
if SS.Parties then
    SS.Parties.openPlanner = function(world, caller)
        if not UI.frame then return SS.Parties.Plan(world, caller, {}) end
        FUI.OpenPlanner(world, caller)
    end
end

---------------------------------------------------------------------------
-- Context menus
---------------------------------------------------------------------------
local function entry(world, actor, target, iid, order, data, label)
    local ia = SS.Interactions[iid]
    local ok, why = false, "Select a resident first."
    if actor then ok, why = SS.Actions.Available(world, actor, target, iid) end
    return { label = label or (ia and ia.label) or iid, order = order, desc = ia and ia.desc,
        disabled = not ok, reason = why,
        onClick = function() SS.Actions.Order(world, actor, nil, iid, nil, nil, { tid = target.id, data = data }) end }
end

-- People and animals clicked while a resident is selected.
-- The social module has its own "Family" category in the same menu (Ask for Advice, Reminisce; its
-- UI loads first). Family's items join that submenu so the menu has one Family entry; without it
-- family adds its own.
function FUI.AddFamilySubmenu(entries, sub, desc)
    for _, e in ipairs(entries) do
        if e.label == "Family" and type(e.submenu) == "table" then
            local usable = false
            for _, x in ipairs(sub) do
                e.submenu[#e.submenu + 1] = x
                if not x.disabled then usable = true end
            end
            if usable and e.disabled then e.disabled, e.reason = nil, nil end
            return e
        end
    end
    local e = { label = "Family", order = 45, desc = desc, submenu = sub }
    entries[#entries + 1] = e
    return e
end

function FUI.ActorEntries(world, actor, ref, entries)
    local t = world.actors[ref]
    if not t or not actor or t == actor then return end
    local Inf = SS.Infants
    -- a baby or pet wearing another module's role is that module's to offer actions for
    if (F.IsInfant(t) or F.IsPet(t)) and not (F.OwnInfant(t) or F.OwnPet(t)) then return end
    if F.IsInfant(t) then
        local held = Inf.Carrier(world, t)
        entries[#entries + 1] = entry(world, actor, t, "infant_feed", 30)
        entries[#entries + 1] = entry(world, actor, t, "infant_change", 31)
        entries[#entries + 1] = entry(world, actor, t, "infant_soothe", 32)
        entries[#entries + 1] = entry(world, actor, t, "infant_play", 33)
        if held == actor then
            entries[#entries + 1] = entry(world, actor, t, "infant_put_down", 34)
            entries[#entries + 1] = entry(world, actor, t, "infant_rock", 35)
        else
            entries[#entries + 1] = entry(world, actor, t, "infant_pickup", 34)
            entries[#entries + 1] = entry(world, actor, t, "infant_pickup", 35, { toCrib = true }, "Put to Bed")
        end
        local cg = { label = "Make Main Caregiver", order = 40, desc = "The main caregiver answers first, day and night." }
        if not F.IsAdult(actor) or actor.householdId ~= t.householdId then cg.disabled, cg.reason = true, "Only a grown-up of this household can be the main caregiver."
        elseif t.infant and t.infant.caregiver == actor.id then cg.disabled, cg.reason = true, actor.name .. " already is."
        else cg.onClick = function() Inf.SetCaregiver(world, t, actor.id); notice(actor.name .. " is now " .. t.name .. "'s main caregiver.") end end
        entries[#entries + 1] = cg
        if F.IsMember(world, t) then entries[#entries + 1] = { label = "Rename...", order = 41, onClick = function() FUI.OpenNaming(world, t) end } end
        return
    end
    if F.IsPet(t) then
        entries[#entries + 1] = entry(world, actor, t, "pet_pet", 30)
        entries[#entries + 1] = entry(world, actor, t, "pet_play", 31)
        entries[#entries + 1] = entry(world, actor, t, "pet_treat", 32)
        entries[#entries + 1] = entry(world, actor, t, "pet_groom", 33)
        entries[#entries + 1] = entry(world, actor, t, "pet_praise", 34)
        entries[#entries + 1] = entry(world, actor, t, "pet_scold", 35)
        entries[#entries + 1] = { label = "Training", order = 36, desc = "Teach " .. t.name .. " to sit" .. (t.kind == "dog" and ", or house manners" or "") .. ".",
            submenu = { entry(world, actor, t, "pet_train_sit", 1), entry(world, actor, t, "pet_train_house", 2), entry(world, actor, t, "pet_cmd_sit", 3) } }
        if t.kind == "dog" then entries[#entries + 1] = entry(world, actor, t, "pet_walk", 37) end
        if F.IsMember(world, t) then
            entries[#entries + 1] = { label = "Rename...", order = 41, onClick = function() FUI.OpenNaming(world, t) end }
            entries[#entries + 1] = { label = "Rehome...", order = 42, desc = "Give " .. t.name .. " to the animal shelter.", onClick = function()
                UI.Confirm("Give " .. t.name .. " to the animal shelter? The family will miss them.", function()
                    local ok, why = SS.Pets.Rehome(world, t); notice(ok and (t.name .. " went to the shelter.") or why)
                end)
            end }
        end
        return
    end
    if not F.IsHuman(t) then return end
    if F.IsChild(t) then
        entries[#entries + 1] = entry(world, actor, t, "fam_play_together", 30)
        entries[#entries + 1] = entry(world, actor, t, "fam_tuck_in", 31)
    elseif F.IsAdult(t) and not F.IsNpc(t) and not (t.role and t.role ~= "guest") then
        local sub = {}
        if not F.IsMember(world, t) then
            local mv = entry(world, actor, t, "fam_move_in", 1)
            mv.desc = select(2, F.MoveMoneyPreview(world, t.id))
            sub[#sub + 1] = mv
        end
        sub[#sub + 1] = entry(world, actor, t, "fam_propose", 2)
        sub[#sub + 1] = entry(world, actor, t, "fam_ceremony", 3)
        sub[#sub + 1] = entry(world, actor, t, "fam_plan_baby", 4)
        FUI.AddFamilySubmenu(entries, sub, "Moving in, commitment and a baby.")
    end
    if SS.Parties and SS.Parties.Running(world) then
        local sub = { entry(world, actor, t, "party_mingle", 1), entry(world, actor, t, "party_dance", 2), entry(world, actor, t, "party_toast", 3) }
        entries[#entries + 1] = { label = "Party", order = 25, desc = "Mingle, dance or raise a toast.", submenu = sub }
    end
end
UI.RegisterMenu("actor", function(world, actor, ref, entries) FUI.ActorEntries(world, actor, ref, entries) end)

-- The selected resident clicked: baby in arms, party planning.
function FUI.SelfEntries(world, actor, ref, entries)
    if not actor then return end
    local Inf = SS.Infants
    local held = Inf and Inf.Held(world, actor)
    if held then
        entries[#entries + 1] = entry(world, actor, held, "infant_put_down", 20, nil, "Put " .. short(held.name) .. " Down")
        entries[#entries + 1] = entry(world, actor, held, "infant_rock", 21)
        local crib = Inf.FreeCrib(world, actor)
        local e = { label = "Put " .. short(held.name) .. " in the Crib", order = 22 }
        if not crib then e.disabled, e.reason = true, "There's no free crib."
        else
            local ok, why = SS.Actions.Available(world, actor, crib, "infant_to_crib")
            e.disabled, e.reason = not ok, why
            e.onClick = function() SS.Actions.Order(world, actor, crib.id, "infant_to_crib") end
        end
        entries[#entries + 1] = e
    end
    if SS.Parties and F.IsAdult(actor) and F.IsMember(world, actor) then
        local ok, why = SS.Parties.PlanCheck(world, actor)
        local active = SS.Parties.Active(world)
        entries[#entries + 1] = { label = active and "Party Status..." or "Throw a Party...", order = 60,
            disabled = not ok and not active, reason = why, onClick = function() FUI.OpenPlanner(world, actor) end }
    end
end
UI.RegisterMenu("self", function(world, actor, ref, entries) FUI.SelfEntries(world, actor, ref, entries) end)

-- Objects: planting seeds (a crop choice) and a status line for garden beds and aquariums.
function FUI.ObjEntries(world, actor, oid, entries)
    local o = world.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return end
    local Gd = SS.Garden
    local kind = Gd and Gd.Kind(def)
    if kind == "plot" then
        local PL = SS.PlantData
        local st = Gd.State(world, o)
        local sub = {}
        for n, id in ipairs(PL.cropOrder) do
            local crop = PL.crops[id]
            local e = { label = crop.name .. "  " .. U.fmtMoney(crop.seedCost), order = n,
                desc = (crop.kind == "flowers" and "Flowers" or "Produce") .. ": ready in about " .. fmtHours(crop.stageHours[3] * 60) .. " of watered growth." }
            local ok, why = false, "Select a resident first."
            if actor then
                ok, why = Gd.PlantCheck(world, actor, o, id)
                if ok then ok, why = SS.Actions.Available(world, actor, o, "garden_plant") end
            end
            e.disabled, e.reason = not ok, why
            e.onClick = function() SS.Actions.Order(world, actor, oid, "garden_plant", nil, nil, { data = { crop = id } }) end
            sub[#sub + 1] = e
        end
        local plant = { label = "Plant Seeds", order = 5, desc = "Choose what to grow here.", submenu = sub }
        if st.crop or st.dead then plant.disabled, plant.reason = true, st.dead and "Clear the dead plants first." or "Something is already growing here." end
        entries[#entries + 1] = plant
    end
    local status
    if kind == "plot" then
        local st = Gd.State(world, o)
        local crop = st.crop and SS.PlantData.crops[st.crop]
        status = (crop and (crop.name .. ": ") or "") .. Gd.StageName(st) .. (crop and not st.dead and (", water " .. math.floor(st.water) .. "%, weeds " .. math.floor(st.weeds) .. "%, care " .. (st.care or 0) .. "%") or "")
    elseif kind == "decor" then
        local st = Gd.State(world, o)
        status = (st.wilted and "Wilting" or "Healthy") .. ", water " .. math.floor(st.water) .. "%"
    elseif SS.Tags.Has(def, "aquarium") then
        local st = SS.Pets.AquariumState(world, o)
        status = (st.fish > 0 and (st.fish .. " fish") or "Empty") .. ", fed " .. fmtHours(world.time - st.fedAt) .. " ago" .. (st.dirty and ", water murky" or "")
    elseif SS.Tags.Has(def, "crib") and SS.Infants then
        local occ = SS.Infants.CribOccupant(world, o)
        status = occ and (occ.name .. (occ.infant and occ.infant.asleep and " is asleep here" or " is in the crib")) or "Empty"
    end
    if status then
        entries[#entries + 1] = { label = "Status: " .. status, order = 99, desc = status, onClick = function() notice(status) end }
    end
end
UI.RegisterMenu("obj", function(world, actor, oid, entries) FUI.ObjEntries(world, actor, oid, entries) end)

---------------------------------------------------------------------------
-- Naming dialog (new babies, adopted children and pets)
---------------------------------------------------------------------------
local function dialog(name, h)
    local Kt, C = K(), COL()
    local d = CreateFrame("Frame", nil, UI.frame)
    d:SetFrameStrata("DIALOG")
    d:SetSize(320, h)
    d:SetPoint("CENTER", UI.frame, "CENTER", 0, 40)
    Kt.Tex(d, "BACKGROUND", C.panel):SetAllPoints()
    d.title = Kt.Text(d, 13, C.ink); d.title:SetPoint("TOPLEFT", 10, -8); d.title:SetWidth(300)
    d.text = Kt.Text(d, 11, C.inkSoft); d.text:SetPoint("TOPLEFT", 10, -28); d.text:SetWidth(300)
    d:EnableMouse(true)
    d:Hide()
    return d
end

function FUI.CreateNaming()
    if FUI.naming then return FUI.naming end
    if not UI.frame then return nil end
    local Kt = K()
    local d = dialog("naming", 110)
    local eb = CreateFrame("EditBox", nil, d)
    eb:SetSize(200, 20); eb:SetPoint("TOPLEFT", 10, -50)
    Kt.Tex(eb, "BACKGROUND", { 1, 1, 1, 0.8 }):SetAllPoints()
    eb:SetFontObject(GameFontHighlight)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(FD.nameMax)
    eb:SetScript("OnEnterPressed", function() FUI.ConfirmNaming() end)
    eb:SetScript("OnEscapePressed", function() FUI.CloseNaming(true) end)
    d.edit = eb
    d.ok = Kt.Button(d, "Name", 70, 20, function() FUI.ConfirmNaming() end, "Use this name")
    d.ok:SetPoint("BOTTOMRIGHT", -10, 10)
    d.keep = Kt.Button(d, "Keep", 70, 20, function() FUI.CloseNaming(true) end, "Keep the suggested name")
    d.keep:SetPoint("RIGHT", d.ok, "LEFT", -6, 0)
    d.err = Kt.Text(d, 10, COL().warn); d.err:SetPoint("BOTTOMLEFT", 10, 14); d.err:SetWidth(150)
    FUI.naming = d
    return d
end

FUI.namingQueue = {}
function FUI.OpenNaming(world, person)
    local d = FUI.CreateNaming()
    if not d then return false end
    if d:IsShown() and d.person and d.person ~= person then
        FUI.namingQueue[#FUI.namingQueue + 1] = person.id
        return true
    end
    d.world, d.person = world, person
    local pet = F.IsPet(person)
    d.title:SetText(pet and ("Name your new " .. string.lower(SS.PetData.species[person.kind].label)) or ("Welcome, " .. person.name .. "!"))
    d.text:SetText(pet and "Pick a name, or keep the one the shelter gave." or "Choose a first name; the family name stays.")
    d.edit:SetText(pet and person.name or short(person.name))
    d.err:SetText("")
    d:Show()
    d.edit:SetFocus()
    return true
end

function FUI.ConfirmNaming()
    local d = FUI.naming
    if not d or not d.person then return false end
    local text = d.edit:GetText()
    local ok, why
    if F.IsPet(d.person) then ok, why = SS.Pets.Rename(d.world, d.person, text)
    else ok, why = F.RenameFirst(d.world, d.person, text) end
    if not ok then d.err:SetText(why or "That name won't do."); return false end
    FUI.CloseNaming(false)
    return true
end

function FUI.CloseNaming(kept)
    local d = FUI.naming
    if not d then return end
    if kept and d.person and F.IsPet(d.person) and d.person.pet then d.person.pet.named = true end
    d.person = nil
    d.edit:ClearFocus()
    d:Hide()
    FUI.dirty = true
    local nextId = table.remove(FUI.namingQueue, 1)
    local w = SS.Sim.world
    local p = nextId and w and F.Root(w).residents[nextId]
    if p then FUI.OpenNaming(w, p) end
end

SS.On("familyNaming", function(world, person)
    if not world or not person or not UI.frame or world ~= SS.Sim.world then return end
    FUI.OpenNaming(world, person)
end)

---------------------------------------------------------------------------
-- Continuation after a household ends (fallback when no other module shows one)
---------------------------------------------------------------------------
function FUI.CreateContinue()
    if FUI.continueDlg then return FUI.continueDlg end
    if not UI.frame then return nil end
    local Kt = K()
    local d = dialog("continue", 170)
    d.buttons = {}
    for n = 1, 4 do
        local b = Kt.Button(d, "", 300, 20, function(self) if self.fn then self.fn() end end)
        b:SetPoint("TOPLEFT", 10, -62 - (n - 1) * 24)
        d.buttons[n] = b
    end
    FUI.continueDlg = d
    return d
end

function FUI.ShowContinue(world, hh, reason)
    local d = FUI.CreateContinue()
    if not d then return false end
    d.title:SetText("The " .. (hh and hh.name or "") .. " household has ended")
    d.text:SetText(reason or "")
    local opts = F.ContinueOptions(world)
    local rows = {}
    for n = 1, math.min(3, #opts) do
        local o = opts[n]
        rows[#rows + 1] = { label = "Continue with the " .. o.name .. " household (" .. o.members .. ")", fn = function()
            d:Hide()
            local ok, why = F.Continue(world, o.id)
            if not ok then notice(why) end
        end }
    end
    if UI.modes and UI.modes.hood then
        rows[#rows + 1] = { label = "Go to the neighbourhood", fn = function() d:Hide(); UI.SetMode("hood") end }
    end
    if #rows == 0 then
        rows[1] = { label = "Start a new game (your saves are untouched)", fn = function()
            d:Hide()
            if SS.Boot and SS.Boot.UseWorld then SS.Boot.UseWorld(SS.Fixtures.NewWorld(math.random(1, 2147483646))) end
        end }
    end
    for n, b in ipairs(d.buttons) do
        local r = rows[n]
        if r then b.label:SetText(r.label); b.fn = r.fn; b:Show() else b.fn = nil; b:Hide() end
    end
    d.rows = rows
    d:Show()
    return true
end

SS.On("householdEnded", function(world, hh, reason)
    if not world or world ~= SS.Sim.world or hh ~= world.household or not UI.frame then return end
    if UI.ShowContinuation then return UI.ShowContinuation(world, hh, reason) end   -- another module's dialog
    FUI.ShowContinue(world, hh, reason)
end)
