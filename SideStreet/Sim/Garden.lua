-- SideStreet gardening: plots and planters (plant seeds, growth stages, watering, weeds, wilting,
-- dying and rotting from neglect, harvest into the household inventory), decorative plants that
-- wilt without water and drag the room score down, garden ornaments (fountain, birdbath), the
-- gardener service hook SS.Garden.Tend, and selling produce to the greengrocer's buyer.
-- Owner: family module. Growth and yield: Data/Plants.lua (SS.PlantData). Not a farming game.
--
-- Object state (saved on the lot object):
--   plot/planter: crop, stage (0 bare .. 4 ready), grow (effective minutes), water, weeds, dryMin,
--     wilted, wiltedMin, dead, rotten, ripeMin, careHours, goodHours, care, plantedAt
--   tree/shrub/flowers: water, dryMin, wilted       birdbath: water, empty
-- root.garden = { harvests, sold, lastHarvest } (small counters for the UI).
local _, SS = ...
local U = SS.U
local F = SS.Family
local PL = SS.PlantData
local PT, DEC = PL.plot, PL.decorative
local Gd = {}
SS.Garden = Gd

local DECOR_TAGS = { "flowers", "shrub", "tree" }

-- Which garden behaviour an object definition has: "plot" | "decor" (+ key) | "fountain" | "birdbath" | nil.
function Gd.Kind(def)
    if not def or not def.tags then return nil end
    if SS.Tags.Has(def, "garden_plot") then return "plot", "garden_plot" end
    if SS.Tags.Has(def, "planter") then return "plot", "planter" end
    for _, t in ipairs(DECOR_TAGS) do if SS.Tags.Has(def, t) then return "decor", t end end
    if SS.Tags.Has(def, "fountain") then return "fountain" end
    if SS.Tags.Has(def, "birdbath") then return "birdbath" end
    return nil
end

function Gd.Root(world)
    local root = F.Root(world)
    local g = root.garden
    if type(g) ~= "table" then g = {}; root.garden = g end
    g.harvests = g.harvests or 0
    g.sold = g.sold or 0
    return g
end

local function clearPlot(st)
    st.crop, st.stage, st.grow = nil, 0, 0
    st.wilted, st.wiltedMin, st.dead, st.rotten, st.ripeMin = nil, 0, nil, nil, 0
    st.dryMin, st.careHours, st.goodHours, st.care, st.plantedAt = 0, 0, 0, nil, nil
end
Gd.ClearPlot = clearPlot

function Gd.State(world, o)
    if not o then return nil end
    o.state = o.state or {}
    local st = o.state
    local kind = Gd.Kind(SS.Objects[o.def])
    if kind == "plot" then
        st.stage = st.stage or 0
        st.grow = st.grow or 0
        st.water = st.water or 60
        st.weeds = st.weeds or 0
        st.dryMin = st.dryMin or 0
        st.careHours = st.careHours or 0
        st.goodHours = st.goodHours or 0
        st.ripeMin = st.ripeMin or 0
        st.wiltedMin = st.wiltedMin or 0
    elseif kind == "decor" then
        st.water = st.water or 100
        st.dryMin = st.dryMin or 0
    elseif kind == "birdbath" then
        st.water = st.water or 100
    end
    return st, kind
end

function Gd.StageFor(crop, grow)
    local stage = 1
    for k = 1, 3 do if grow >= crop.stageHours[k] * 60 then stage = k + 1 end end
    return stage
end

-- Stage names for the UI.
function Gd.StageName(st)
    if st.dead then return st.rotten and "Rotted" or "Dead" end
    local n = PL.stages[st.stage or 0] or ""
    if st.wilted then n = n .. " (wilting)" end
    return n
end

---------------------------------------------------------------------------
-- Hourly growth and deterioration (only the lot being played changes)
---------------------------------------------------------------------------
local function say(world, o, text, kind)
    F.Journal(world, text)
    SS.Emit("notice", nil, text)
    SS.Emit("gardenChanged", world, o, kind)
end

function Gd.PlotHour(world, o, hours)
    local st, _ = Gd.State(world, o)
    local def = SS.Objects[o.def]
    local _, key = Gd.Kind(def)
    local crop = st.crop and PL.crops[st.crop]
    local name = crop and crop.name or "The plot"
    -- weeds spread on every plot (slowly on bare soil, very slowly in planters)
    local wr = PT.weedsPerHour * (crop and 1 or 0.5) * (key == "planter" and PT.planterWeedsFactor or 1)
    if st.weeds >= PT.weedsSlow then wr = wr * PT.weedsSlowFactor end
    st.weeds = math.min(100, st.weeds + wr * hours)
    if not crop or st.dead then
        st.water = math.max(0, st.water - PT.bareDryPerHour * hours)
        return
    end
    st.water = math.max(0, st.water - crop.waterUse * hours)
    if st.water <= 0 then st.dryMin = st.dryMin + 60 * hours else st.dryMin = 0 end
    if st.wilted then
        st.wiltedMin = st.wiltedMin + 60 * hours
        if st.wiltedMin >= PT.dieAfter then
            st.dead, st.wilted = true, nil
            say(world, o, "The " .. name:lower() .. " died from lack of water.", "died")
            SS.Emit("lotChanged", "state", o.id)
            return
        end
    elseif st.dryMin >= PT.wiltAfter then
        st.wilted, st.wiltedMin = true, 0
        say(world, o, "The " .. name:lower() .. " are wilting. Water them soon.", "wilted")
        SS.Emit("lotChanged", "state", o.id)
    end
    -- growth: only watered, living plants grow; dry soil and weeds slow them down
    if not st.wilted and st.stage < 4 and st.water > 0 then
        -- a raised bed grows faster (catalogue quality.speed, x1 = normal)
        local f = F.Quality(o, "speed", 1)
        if st.water < PT.dryAt then f = f * PT.dryFactor end
        f = f * (1 - st.weeds / 200)
        st.grow = st.grow + 60 * hours * f
        local ns = Gd.StageFor(crop, st.grow)
        if ns > st.stage then
            st.stage = ns
            SS.Emit("lotChanged", "state", o.id)
            if ns == 4 then
                st.ripeMin = 0
                say(world, o, "The " .. name:lower() .. (crop.kind == "flowers" and " are in full bloom" or " are ready to harvest") .. ".", "ripe")
            end
        end
    end
    if st.stage == 4 then
        st.ripeMin = st.ripeMin + 60 * hours
        if st.ripeMin >= PT.rotAfter then
            st.dead, st.rotten, st.wilted = true, true, nil
            say(world, o, "The " .. name:lower() .. " were left too long and rotted.", "rotted")
            SS.Emit("lotChanged", "state", o.id)
            return
        end
    end
    -- care quality decides the yield
    st.careHours = st.careHours + hours
    if st.water >= PT.careGood.water and st.weeds <= PT.careGood.weeds and not st.wilted then st.goodHours = st.goodHours + hours end
    st.care = math.floor(100 * st.goodHours / math.max(1, st.careHours) + 0.5)
end

function Gd.DecorHour(world, o, key, hours)
    local st = Gd.State(world, o)
    local D = DEC[key]
    st.water = math.max(0, st.water - D.waterUse * hours)
    if st.water <= 0 then st.dryMin = st.dryMin + 60 * hours else st.dryMin = 0 end
    if not st.wilted and st.dryMin >= D.wiltAfter then
        st.wilted = true
        local def = SS.Objects[o.def]
        say(world, o, "The " .. ((def and def.name) or key):lower() .. " is wilting and needs water.", "wilted")
        SS.Emit("lotChanged", "state", o.id)
    end
end

function Gd.BirdbathHour(world, o, hours)
    local st = Gd.State(world, o)
    st.water = math.max(0, st.water - PL.birdbath.waterUse * hours)
    local empty = st.water <= 0 or nil
    if empty ~= st.empty then st.empty = empty; SS.Emit("lotChanged", "state", o.id) end
end

-- Garden objects on this lot (sorted by id). A shared, read-only list kept until family's tag
-- index is rebuilt (the object set changed), so it costs nothing to ask for it again.
local GARDEN_TAGS = { "garden_plot", "planter", "flowers", "shrub", "tree", "fountain", "birdbath" }
local objCache = { gen = -1 }
function Gd.Objects(world)
    local gen = F.TagIndexGen(world)
    local c = objCache
    if c.list and c.gen == gen and c.lot == world.lot then return c.list end
    local out, seen = {}, {}
    for _, tag in ipairs(GARDEN_TAGS) do
        for _, o in ipairs(F.ObjectsWithTag(world, tag)) do
            if not seen[o] and Gd.Kind(SS.Objects[o.def]) then seen[o] = true; out[#out + 1] = o end
        end
    end
    table.sort(out, F.ById)
    c.list, c.gen, c.lot = out, gen, world.lot
    return out
end

function Gd.Hour(world, hours)
    hours = hours or 1
    for _, o in ipairs(Gd.Objects(world)) do
        local kind, key = Gd.Kind(SS.Objects[o.def])
        if kind == "plot" then Gd.PlotHour(world, o, hours)
        elseif kind == "decor" then Gd.DecorHour(world, o, key, hours)
        elseif kind == "birdbath" then Gd.BirdbathHour(world, o, hours) end
    end
end

-- Room score: wilted or dead plants, weedy beds and an empty birdbath look bad; blooming beds good.
-- When household-core's room breakdown already scores `state.wilted` (less decoration, some mess),
-- the wilting part is left to it so a wilted plant is not counted twice.
F.RegisterEnv(function(world, o, def)
    local st = o.state
    if not st then return nil end
    local kind, key = Gd.Kind(def)
    local coreWilt = F.CoreScoresWilted()
    if kind == "plot" then
        local d = 0
        local crop = st.crop and PL.crops[st.crop]
        if crop and not st.dead and not st.wilted and (st.stage or 0) >= 3 then d = d + (crop.env or 0) end
        if st.wilted and not coreWilt then d = d + PT.wiltedEnv end
        if st.dead then d = d + PT.deadEnv end
        if (st.weeds or 0) >= PT.weedyAt then d = d + PT.weedyEnv end
        return d
    elseif kind == "decor" then
        if st.wilted and not coreWilt then return DEC[key].wiltedEnv - (def.env or 0) end
    elseif kind == "birdbath" then
        if st.empty then return PL.birdbath.emptyEnv end
    end
end)

---------------------------------------------------------------------------
-- Care: what needs doing, Tend (the gardener service hook), and the task list
---------------------------------------------------------------------------
-- Does this garden object need care? Returns the kind of job ("water" or "weed", the visitors
-- gardener's contract: "weed" covers clearing dead plants too) or false, and the list of reasons
-- ("water", "weed", "clear", "refill").
local JOB = { water = "water", refill = "water", weed = "weed", clear = "weed" }
function Gd.NeedsCare(world, o)
    local def = o and SS.Objects[o.def]
    local kind = Gd.Kind(def)
    if not kind then return false, {} end
    local st = Gd.State(world, o)
    local why = {}
    if kind == "plot" then
        if st.dead then why[#why + 1] = "clear"
        else
            if st.crop and (st.water < PT.needsWaterBelow or st.wilted) then why[#why + 1] = "water" end
            if st.weeds >= PT.needsWeedingAt then why[#why + 1] = "weed" end
        end
    elseif kind == "decor" then
        if st.water < PT.needsWaterBelow or st.wilted then why[#why + 1] = "water" end
        -- decorative plants never grow weeds here; weeds another module put on one are pulled too
        if (tonumber(st.weeds) or 0) > 0 then why[#why + 1] = "weed" end
    elseif kind == "birdbath" then
        if st.water < 30 then why[#why + 1] = "refill" end
    end
    if #why == 0 then return false, why end
    return JOB[why[1]], why
end

-- Everything in the garden that needs care, sorted by urgency then id (the gardener's route).
function Gd.Tasks(world)
    local out = {}
    for _, o in ipairs(Gd.Objects(world)) do
        local need, why = Gd.NeedsCare(world, o)
        if need then
            local st = o.state
            local urg = (st.wilted and 100 or 0) + (st.dead and 50 or 0) + (100 - (st.water or 100)) * 0.5 + (st.weeds or 0) * 0.3
            out[#out + 1] = { obj = o, id = o.id, why = why, urgency = urg }
        end
    end
    table.sort(out, function(a, b) if a.urgency ~= b.urgency then return a.urgency > b.urgency end return a.id < b.id end)
    return out
end

local function water(st, kind)
    st.water = 100
    st.dryMin = 0
    if st.wilted and not st.dead then
        st.wilted, st.wiltedMin = nil, 0
        return true
    end
end

-- Apply a round of care to one object: water, weed, clear dead plants, refill the birdbath.
-- Used by residents ("Tend Garden") and the visitors module's gardener. Returns ok, text.
function Gd.Tend(world, o, who)
    if not o or not world.lot.objects[o.id] then return false, "That plant is gone." end
    local def = SS.Objects[o.def]
    local kind = Gd.Kind(def)
    if not kind then return false, "There's nothing to tend there." end
    local st = Gd.State(world, o)
    local did = {}
    if kind == "plot" then
        if st.dead then
            clearPlot(st)
            did[#did + 1] = "cleared the dead plants"
        else
            if st.crop and st.water < 90 then
                if water(st) then did[#did + 1] = "revived the wilting plants" else did[#did + 1] = "watered" end
            end
            if st.weeds >= 5 then st.weeds = 0; did[#did + 1] = "pulled the weeds" end
        end
    elseif kind == "decor" then
        if st.water < 90 or st.wilted then
            if water(st) then did[#did + 1] = "revived it" else did[#did + 1] = "watered it" end
        end
        if (tonumber(st.weeds) or 0) > 0 then st.weeds = 0; did[#did + 1] = "pulled the weeds" end
    elseif kind == "birdbath" then
        if st.water < 90 then st.water, st.empty = 100, nil; did[#did + 1] = "refilled the birdbath" end
    end
    if #did == 0 then return false, "Nothing needed doing there." end
    SS.Emit("lotChanged", "state", o.id)
    local text = (who and who.name or "The gardener") .. " " .. table.concat(did, " and ") .. " (" .. (def.name or o.def) .. ")."
    SS.Emit("gardenTended", world, o, who, did)
    return true, text
end

-- Weather another module brings to the garden: events' garden_stress family calls
-- SS.Garden.Stress(world, obj, "dry_spell") and records the event only when this returns true.
-- A dry spell takes `PL.stress.dry_spell.water` out of a living plant's water (bed or decorative
-- plant) and, if that leaves it dry, brings its wilting `dryMin` minutes closer. Nothing is
-- scripted beyond that: the plant then needs water (NeedsCare says so), residents or the gardener
-- can water it, and the usual 12 hours dry before wilting runs from there. Returns false (the
-- plants coped) for an unknown cause, a missing object, a bare or dead bed, an ornament, or a
-- plant already wilting.
function Gd.Stress(world, o, cause)
    local S = PL.stress and PL.stress[cause]
    if not S or not o or world.lot.objects[o.id] ~= o then return false end
    local st, kind = Gd.State(world, o)
    if kind == "plot" then
        if not st.crop or st.dead then return false end
    elseif kind ~= "decor" then
        return false
    end
    if st.wilted then return false end
    local water0, dry0 = st.water, st.dryMin or 0
    st.water = math.max(0, st.water - (S.water or 0))
    if st.water <= 0 then st.dryMin = dry0 + (S.dryMin or 0) end
    if st.water == water0 and (st.dryMin or 0) == dry0 then return false end
    SS.Emit("gardenChanged", world, o, "stressed")
    SS.Emit("lotChanged", "state", o.id)
    return true
end

---------------------------------------------------------------------------
-- Interactions
---------------------------------------------------------------------------
local I = SS.Interactions

local function person(world, actor)
    if not actor or not F.IsHuman(actor) or F.IsInfant(actor) then return false, "Only people can garden." end
    return true
end

-- Planting needs a crop choice, so it is offered from the object menu (UI/Family.lua) rather
-- than attached by tag: SS.Actions.Order(world, actor, oid, "garden_plant", nil, nil, { data = { crop = id } }).
function Gd.PlantCheck(world, actor, o, cropId)
    local ok, why = person(world, actor)
    if not ok then return false, why end
    if not o then return false, F.GONE end
    if Gd.Kind(SS.Objects[o.def]) ~= "plot" then return false, "You can only plant in a garden plot or planter." end
    local st = Gd.State(world, o)
    if st.dead then return false, "Clear the dead plants first." end
    if st.crop then return false, "Something is already growing here." end
    if cropId then
        local crop = PL.crops[cropId]
        if not crop then return false, "Unknown seeds." end
        return F.CanAfford(world, crop.seedCost)
    end
    return true
end

I.garden_plant = {
    label = "Plant Seeds", category = "Garden", slot = "front", pose = "use", dur = PT.plantDur, manualOnly = true,
    ages = { adult = true, child = true }, kinds = { human = true },
    test = function(world, actor, o) return Gd.PlantCheck(world, actor, o, nil) end,
    onStart = function(world, actor, act, o)
        if not o then return false, F.GONE end
        local cropId = act.data.crop or PL.cropOrder[1]
        local ok, why = Gd.PlantCheck(world, actor, o, not act.charged and cropId or nil)
        if not ok then return false, why end
        local crop = PL.crops[cropId]
        ok, why = F.ChargeOnce(world, act, crop.seedCost, "Seeds: " .. crop.name, "garden")
        if not ok then return false, why end
        local st = Gd.State(world, o)
        clearPlot(st)
        st.crop, st.stage, st.plantedAt = cropId, 1, world.time
        st.weeds = 0
        st.water = math.max(st.water or 0, 50)
        SS.Emit("lotChanged", "state", o.id)
        SS.Emit("gardenPlanted", world, actor, o, cropId)
    end,
    onEnd = function(world, actor, act, o, status)
        if status == "done" and act.charged then
            local crop = PL.crops[act.data.crop or PL.cropOrder[1]]
            SS.Needs.Add(actor, "fun", 4)
            F.Journal(world, actor.name .. " planted " .. crop.name:lower() .. ".")
        end
    end,
}

I.garden_water = {
    label = "Water", category = "Garden", slot = "front", pose = "use", dur = PT.waterDur,
    ages = { adult = true, child = true }, kinds = { human = true },
    test = function(world, actor, o)
        local ok, why = person(world, actor)
        if not ok then return false, why end
        if not o then return false, F.GONE end
        local st, kind = Gd.State(world, o)
        if kind == "plot" then
            if st.dead then return false, "It's too late for these plants: clear them." end
            if not st.crop then return false, "Nothing is planted here." end
        elseif kind ~= "decor" then
            return false, "That doesn't need watering."
        end
        if st.water >= 95 and not st.wilted then return false, "The soil is already moist." end
        return true
    end,
    onStart = function(world, actor, act, o)
        if not o then return false, F.GONE end
        -- (a can left in hand from before, e.g. an old save, is this one: it goes back afterwards)
        if not actor.carry or actor.carry == "watering_can" then actor.carry = "watering_can"; act.data.can = true end
        act.data.start = Gd.State(world, o).water
    end,
    onTick = function(world, actor, act, o, dt)
        if not o then return F.Gone(world, actor, act) end
        local st = o.state
        if not st then return end
        local frac = math.min(dt, PT.waterDur - act.t) / PT.waterDur
        st.water = math.min(100, st.water + (100 - (act.data.start or 0)) * frac)
    end,
    onEnd = function(world, actor, act, o, status)
        if act.data.can and actor.carry == "watering_can" then actor.carry = nil end
        if not o or not o.state then return end
        if status == "done" then
            local revived = water(o.state)
            if revived then SS.Actions.Message(world, actor, "The plants perked up.", "fun") end
            SS.Needs.Add(actor, "fun", 2)
        end
        SS.Emit("lotChanged", "state", o.id)
    end,
}

I.garden_weed = {
    label = "Pull Weeds", category = "Garden", slot = "front", pose = "clean", dur = PT.weedDur,
    gain = { hygiene = -5, fun = 3 }, ages = { adult = true, child = true }, kinds = { human = true },
    test = function(world, actor, o)
        local ok, why = person(world, actor)
        if not ok then return false, why end
        if not o then return false, F.GONE end
        local st, kind = Gd.State(world, o)
        if kind ~= "plot" then return false, "No weeds there." end
        if st.weeds < 10 then return false, "There are hardly any weeds." end
        return true
    end,
    onTick = function(world, actor, act, o, dt)
        if not o then return F.Gone(world, actor, act) end
        local st = o.state
        if not st then return end
        act.data.start = act.data.start or st.weeds
        local frac = math.min(dt, PT.weedDur - act.t) / PT.weedDur
        st.weeds = math.max(0, st.weeds - act.data.start * frac)
    end,
    onEnd = function(world, actor, act, o, status)
        if o and o.state and status == "done" then o.state.weeds = 0 end
        if o then SS.Emit("lotChanged", "state", o.id) end
    end,
}

-- Yield from data: the crop's range scaled by how well the plot was looked after.
function Gd.Yield(world, st)
    local crop = PL.crops[st.crop]
    local y = crop.yield
    local care = (st.care or 50) / 100
    local n = y[1] + math.floor((y[2] - y[1]) * care + SS.Random(world, "garden"))
    return U.clamp(n, y[1], y[2])
end

function Gd.Harvest(world, actor, o)
    local st = Gd.State(world, o)
    local crop = st.crop and PL.crops[st.crop]
    if not crop or st.stage < 4 or st.dead then return nil end
    local n = Gd.Yield(world, st)
    local item
    if crop.kind == "flowers" then
        item = { kind = "gift", name = "Bouquet of " .. crop.name, value = crop.value * n,
            data = { crop = st.crop, qty = n, garden = true, quality = st.care, harvestedAt = world.time } }
    else
        item = { kind = "food", name = crop.name, value = crop.value * n,
            data = { crop = st.crop, qty = n, garden = true, ingredient = crop.ingredient, quality = st.care, harvestedAt = world.time } }
    end
    if SS.Inventory and SS.Inventory.Add then SS.Inventory.Add(world, item) end
    local g = Gd.Root(world)
    g.harvests = g.harvests + 1
    g.lastHarvest = { crop = st.crop, qty = n, t = world.time, by = actor and actor.id }
    local cropId = st.crop
    clearPlot(st)
    SS.Emit("lotChanged", "state", o.id)
    local text = (actor and actor.name or "Someone") .. " harvested " .. n .. " " .. (crop.kind == "flowers" and ("stems of " .. crop.name:lower()) or crop.name:lower()) .. "."
    F.Journal(world, text)
    if actor then F.Say(world, actor, "garden_harvest", { crop = cropId, qty = n, objDef = o.def }) end
    SS.Emit("harvest", world, actor, item, cropId)
    return item, n
end

I.garden_harvest = {
    label = "Harvest", category = "Garden", slot = "front", pose = "use", dur = PT.harvestDur,
    gain = { fun = 12 }, ages = { adult = true, child = true }, kinds = { human = true },
    advertise = function(world, actor, o)
        local st = o.state
        if st and st.stage == 4 and not st.dead then return { fun = 25 } end
    end,
    test = function(world, actor, o)
        local ok, why = person(world, actor)
        if not ok then return false, why end
        if not o then return false, F.GONE end
        local st, kind = Gd.State(world, o)
        if kind ~= "plot" then return false, "Nothing to harvest." end
        if st.dead then return false, "The crop is ruined." end
        if not st.crop then return false, "Nothing is planted here." end
        if st.stage < 4 then return false, "Not ready yet: " .. Gd.StageName(st) .. "." end
        return true
    end,
    onEnd = function(world, actor, act, o, status)
        if status == "done" and o then Gd.Harvest(world, actor, o) end
    end,
}

I.garden_clear = {
    label = "Clear Dead Plants", category = "Garden", slot = "front", pose = "clean", dur = PT.clearDur,
    gain = { hygiene = -3 }, advert = { room = 15 }, ages = { adult = true, child = true }, kinds = { human = true },
    test = function(world, actor, o)
        local ok, why = person(world, actor)
        if not ok then return false, why end
        if not o then return false, F.GONE end
        local st = Gd.State(world, o)
        if not st.dead then return false, "Nothing dead to clear." end
        return true
    end,
    onEnd = function(world, actor, act, o, status)
        if status == "done" and o then clearPlot(Gd.State(world, o)); SS.Emit("lotChanged", "state", o.id) end
    end,
}

I.garden_tend = {
    label = "Tend Garden", category = "Garden", slot = "front", pose = "use", dur = PT.tendDur,
    gain = { fun = 6, hygiene = -4 }, ages = { adult = true, child = true }, kinds = { human = true },
    test = function(world, actor, o)
        if actor and actor.role and actor.role ~= "gardener" and actor.role ~= "guest" then return false, "Only the household or the gardener tends the garden." end
        if not actor or not F.IsHuman(actor) or F.IsInfant(actor) then return false, "Only people can garden." end
        if not Gd.NeedsCare(world, o) then return false, "Everything here is in good shape." end
        return true
    end,
    onEnd = function(world, actor, act, o, status)
        if status == "done" and o then
            local ok, text = Gd.Tend(world, o, actor)
            if ok then SS.Actions.Message(world, actor, text, "fun") end
        end
    end,
}

for _, tag in ipairs({ "garden_plot", "planter" }) do
    for _, iid in ipairs({ "garden_water", "garden_weed", "garden_harvest", "garden_clear", "garden_tend" }) do SS.Tags.Attach(tag, iid) end
end
for _, tag in ipairs(DECOR_TAGS) do
    SS.Tags.Attach(tag, "garden_water")
    SS.Tags.Attach(tag, "garden_tend")
end

-- Fountain and birdbath -------------------------------------------------------------
local FO, BB = PL.fountain, PL.birdbath

I.garden_coin = {
    label = "Toss a Coin", category = "Fun", slot = "front", pose = "use", dur = FO.coinDur,
    gain = { fun = FO.fun, comfort = FO.comfort }, ages = { adult = true, child = true }, kinds = { human = true },
    test = function(world, actor)
        local ok, why = person(world, actor)
        if not ok then return false, why end
        return F.CanAfford(world, FO.coinCost)
    end,
    onStart = function(world, actor, act, o)
        if not o then return false, F.GONE end
        local ok, why = F.ChargeOnce(world, act, FO.coinCost, "A coin in the fountain", "fun")
        if not ok then return false, why end
    end,
    onEnd = function(world, actor, act, o, status)
        if status == "done" then SS.Actions.Message(world, actor, actor.name .. " made a wish.", "fun") end
    end,
}
I.garden_admire = {
    label = "Admire the Fountain", category = "Fun", slot = "front", pose = "idle", maxDur = FO.admireMaxDur,
    rate = { fun = FO.admireFun, comfort = 6 }, untilFull = "fun", advert = { fun = 20, comfort = 5 },
    ages = { adult = true, child = true }, kinds = { human = true },
    test = person,
}
SS.Tags.Attach("fountain", "garden_coin")
SS.Tags.Attach("fountain", "garden_admire")

I.garden_refill_birdbath = {
    label = "Refill Birdbath", category = "Garden", slot = "front", pose = "use", dur = BB.refillDur,
    ages = { adult = true, child = true }, kinds = { human = true },
    test = function(world, actor, o)
        local ok, why = person(world, actor)
        if not ok then return false, why end
        if not o then return false, F.GONE end
        if Gd.State(world, o).water >= 90 then return false, "It's full." end
        return true
    end,
    onEnd = function(world, actor, act, o, status)
        if status == "done" and o then
            local st = Gd.State(world, o)
            st.water, st.empty = 100, nil
            SS.Emit("lotChanged", "state", o.id)
        end
    end,
}
I.garden_watch_birds = {
    label = "Watch the Birds", category = "Fun", slot = "front", pose = "idle", maxDur = BB.watchMaxDur,
    rate = { fun = BB.watchFun, comfort = BB.watchComfort }, untilFull = "fun",
    advertise = function(world, actor, o)
        if o.state and (o.state.water or 100) > 0 then return { fun = 22, comfort = 8 } end
    end,
    ages = { adult = true, child = true }, kinds = { human = true },
    test = function(world, actor, o)
        local ok, why = person(world, actor)
        if not ok then return false, why end
        if not o then return false, F.GONE end
        if Gd.State(world, o).water <= 0 then return false, "No birds come to an empty birdbath." end
        local h = (world.time % 1440) / 60
        if h < 6 or h >= 20 then return false, "The birds are asleep." end
        return true
    end,
}
SS.Tags.Attach("birdbath", "garden_refill_birdbath")
SS.Tags.Attach("birdbath", "garden_watch_birds")

-- The interaction that does a task's job: one job gets its own interaction (water, weed, clear,
-- refill); several at once, or weeds on a decorative plant (garden_weed is for beds), get
-- "Tend Garden", which does everything in one go.
function Gd.TaskInteraction(t)
    local kind = Gd.Kind(SS.Objects[t.obj.def])
    local iid
    for _, w in ipairs(t.why) do
        if w == "water" then iid = "garden_water"
        elseif w == "weed" and not iid then iid = kind == "plot" and "garden_weed" or "garden_tend"
        elseif w == "clear" and not iid then iid = "garden_clear"
        elseif w == "refill" and not iid then iid = "garden_refill_birdbath" end
    end
    if #t.why > 1 and kind ~= "birdbath" then iid = "garden_tend" end
    return iid
end

-- Residents look after the garden when idle (the active ones more often). The task list is walked
-- in order of urgency and the first tasks this resident can actually do are offered, so one task
-- nobody may do (a bed the visiting gardener has reserved, say) never stops the rest of the care.
local OFFER, LOOK = 2, 8
local taskCache = { t = -1 }
SS.Actions.RegisterCandidates(function(world, actor, cands)
    if actor.role or not F.IsHuman(actor) or F.IsInfant(actor) or not F.IsMember(world, actor) then return end
    -- one list per sim step, shared by everyone who thinks in it (the offers are re-checked below)
    local gen = F.TagIndexGen(world)
    local c = taskCache
    if c.t ~= world.time or c.gen ~= gen or c.lot ~= world.lot then c.tasks, c.t, c.gen, c.lot = Gd.Tasks(world), world.time, gen, world.lot end
    local tasks = c.tasks
    if #tasks == 0 then return end
    local active = (actor.personality and actor.personality.active) or 5
    local offered = 0
    for n = 1, math.min(#tasks, LOOK) do
        local t = tasks[n]
        if world.lot.objects[t.id] == t.obj then
            local iid = Gd.TaskInteraction(t)
            local ok = false
            -- a job that just failed for this resident (no way to reach the bed, say) waits out the
            -- executor's cool-down like any object action; one that is refused is tried as Tend
            if iid and not F.AutoCooling(world, actor, t.id, iid) then
                ok = SS.Actions.Available(world, actor, t.obj, iid)
                if not ok and iid ~= "garden_tend" and not F.AutoCooling(world, actor, t.id, "garden_tend") then
                    iid = "garden_tend"
                    ok = SS.Actions.Available(world, actor, t.obj, iid)
                end
            end
            if ok then
                local s = 14 + active + (t.obj.state.wilted and 10 or 0) + math.min(10, t.urgency / 15) - 2 * offered
                cands[#cands + 1] = { oid = t.obj.id, iid = iid, s = s }
                offered = offered + 1
                if offered >= OFFER then return end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Selling produce: the greengrocer's buyer visits and pays for everything harvested
---------------------------------------------------------------------------
function Gd.Sellable(world, hh)
    hh = F.Household(world, hh)
    local out, total = {}, 0
    for _, it in ipairs(hh and hh.inventory or {}) do
        if type(it) == "table" and it.data and it.data.garden and it.value then
            out[#out + 1] = it
            total = total + it.value
        end
    end
    return out, math.floor(total * PL.sale.share)
end

function Gd.SellCheck(world, caller)
    if not caller or not F.IsAdult(caller) then return false, "Only an adult can arrange a sale." end
    if not world.household or caller.householdId ~= world.household.id then return false, "Only a member of this household can sell its produce." end
    local items = Gd.Sellable(world)
    if #items == 0 then return false, "There's no harvested produce or flowers to sell." end
    if F.VisitPending(world, "produce_sale", world.household.id) then return false, "The buyer is already on the way." end
    return true
end

function Gd.RequestSale(world, caller)
    local ok, why = Gd.SellCheck(world, caller)
    if not ok then return false, why end
    local delay = SS.RandomInt(world, "garden", PL.sale.arrive[1], PL.sale.arrive[2])
    F.RequestVisit(world, "npc_produce_buyer", "produce_sale", world.household, { caller = caller.id }, delay)
    local _, total = Gd.Sellable(world)
    return true, "The greengrocer's buyer will come by " .. F.DelayText(delay) .. ". Your harvest is worth about " .. U.fmtMoney(total) .. " today."
end

F.visitTasks.produce_sale = function(world, worker, vrec)
    local root = F.Root(world)
    local hh = root.households[vrec.hh]
    if not hh then return false, "The household is gone." end
    if vrec.paid then return true end
    local items, total = Gd.Sellable(world, hh)
    if #items == 0 or total <= 0 then
        local text = "The greengrocer's buyer found nothing left to buy."
        F.Journal(world, text)
        return false, text
    end
    -- remove the goods first, then pay once
    for _, it in ipairs(items) do
        local removed = false
        if world.household == hh and SS.Inventory and SS.Inventory.Remove then removed = SS.Inventory.Remove(world, it) end
        if not removed then
            for n = #hh.inventory, 1, -1 do if hh.inventory[n] == it then table.remove(hh.inventory, n) end end
        end
    end
    vrec.paid = total
    F.HouseholdMoney(world, hh, total, "sale", "Sold garden produce to the greengrocer")
    local g = Gd.Root(world)
    g.sold = g.sold + total
    local text = "Sold " .. #items .. " harvest" .. (#items == 1 and "" or "s") .. " to the greengrocer for " .. U.fmtMoney(total) .. "."
    F.Journal(world, text)
    SS.Emit("notice", worker, text)
    SS.Emit("produceSold", world, total, #items)
    return true, text
end
F.visitRefused.produce_sale = function(world, vrec)
    vrec.state = "cancelled"
    F.Journal(world, "The greengrocer's buyer was sent away without buying anything.")
end

if SS.Phone and SS.Phone.RegisterCall then
    SS.Phone.RegisterCall({ id = "garden_sell", label = "Sell Produce to the Greengrocer", category = "Family", order = 30,
        test = function(world, caller) return Gd.SellCheck(world, caller) end,
        run = function(world, caller) return Gd.RequestSale(world, caller) end })
end

---------------------------------------------------------------------------
-- System and validator
---------------------------------------------------------------------------
-- Props garden actions put in hands: a stray one is put away on attach (F.PutAwayProps).
Gd.PROPS = { watering_can = "garden_water" }

-- Growth speed is read from the design (Gd.PlotHour); buy mode may show it for plots and planters.
F.DeclareReads("speed:garden_plot", "speed:planter")

-- Garden objects keep a moisture level in o.state.water (0..100; plots, planters, decorative
-- plants, the birdbath). The renderer reads it as a level (R.STATE_LEVEL) and the visitors'
-- gardener reads it too. Household-core's effect list (SS.Maintenance.Effects, merged tree) shows
-- running water for any object whose state.water is set, so every plant on a lot got a splashing
-- tap, and on the shops lot the effect at a shrub by the wall sent the art renderer's bump walk
-- into a loop that never ends (requests HC-15 and AR-1). Until M.Effects checks
-- `state.water == true` (a tap or shower that is on), family drops the water effects it adds for
-- objects whose state.water is a number. Nothing is allocated; with HC-15 in place this finds
-- nothing to drop.
function Gd.WaterFxFilter(world, out)
    local objs = world and world.lot and world.lot.objects
    if type(out) ~= "table" or not objs then return out end
    local n, k = #out, 0
    for q = 1, n do
        local e = out[q]
        local o = type(e) == "table" and e.ref ~= nil and objs[e.ref]
        local st = o and o.state
        if not ((e.fx == "water" or e.effect == "water") and st and type(st.water) == "number") then
            k = k + 1
            out[k] = e
        end
    end
    for q = k + 1, n do out[q] = nil end
    return out
end
function Gd.InstallWaterFxFilter()
    local M = SS.Maintenance
    if type(M) ~= "table" or type(M.Effects) ~= "function" or Gd.wrappedFor == M then return false end
    Gd.wrappedFor = M
    local orig = M.Effects
    Gd.wrappedEffects = function(world, out) return Gd.WaterFxFilter(world, orig(world, out)) end
    M.Effects = Gd.wrappedEffects
    return true
end
Gd.InstallWaterFxFilter()

SS.Sim.Register({
    name = "garden", order = 46,
    attach = function(world)
        Gd.InstallWaterFxFilter()
        for _, o in ipairs(Gd.Objects(world)) do Gd.State(world, o) end
        F.PutAwayProps(world, Gd.PROPS)
    end,
    hour = function(world, h) Gd.Hour(world, 1) end,
})

SS.Save.RegisterValidator(function(root, problems)
    if root.garden ~= nil and type(root.garden) ~= "table" then root.garden = nil end
    for lid, lot in pairs(root.hood and root.hood.lots or {}) do
        for oid, o in pairs(type(lot.objects) == "table" and lot.objects or {}) do
            if type(o) == "table" and type(o.state) == "table" and o.state.crop ~= nil and not PL.crops[o.state.crop] then
                clearPlot(o.state)
                problems[#problems + 1] = "cleared an unknown crop on " .. tostring(oid)
            end
        end
    end
    return true
end)
