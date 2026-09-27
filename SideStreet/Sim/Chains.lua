-- Household chains: cooking and eating, dishes and rubbish, drinks, sleep and waking,
-- bathroom routines, lights and alarm clocks. Owner: household-core.
--
-- Every chain is a sequence of ordinary executor interactions linked by `next`, with the
-- intermediate state kept in the world rather than in a hidden timer:
--   * food in progress is a system object on a real surface slot or appliance (food_prep,
--     food_cooking), served food is a platter or a plate (food_platter, food_plate), and
--     finished plates become dirty dishes (plate_dirty) until someone washes them;
--   * what a person carries between steps is `actor.held` (saved) with a visible prop
--     (`actor.carry`); if a step does not complete, the item is put down where it can be picked
--     up again (SettleHeld), so nothing is duplicated or silently lost.
-- Money: ingredients are charged once, at the fridge (cook_meal commit). Leftovers, continuing
-- a half-cooked dish and eating a served plate never charge again.
local _, SS = ...
local T, W, G, U = SS.Tuning, SS.World, SS.Grid, SS.U
local A, M, F = SS.Actions, SS.Maintenance, SS.Food
local FT = T.food
local I = SS.Interactions
local C = {}
SS.Chains = C

local function level(o) return o and o.level or 0 end
local function skillOf(actor, name) return (SS.Skills and SS.Skills.Level and SS.Skills.Level(actor, name)) or 0 end
local function isMember(world, actor) return A.IsMember(world, actor) end
local function freeWill(world) return world.settings and world.settings.freeWill end
local function hourOf(world) return (world.time % 1440) / 60 end
local function isNight(world)
    local m = world.time % 1440
    return m >= T.nightStart or m < T.nightEnd
end
C.IsNight = isNight

-- Legacy object tags ---------------------------------------------------------------------
-- The 15 stage-1 objects predate the tag table. Until the catalogue gives them tags, they get
-- the matching household tags here (only when a definition has no tags at all).
C.LEGACY_TAGS = {
    fridge_basic = { "fridge" }, counter_basic = { "counter" }, stove_basic = { "stove", "oven" },
    bed_single = { "bed" }, toilet_basic = { "toilet" }, shower_basic = { "shower" }, sink_pedestal = { "basin", "mirror" },
    armchair_basic = { "seat" }, chair_dining = { "seat" }, table_small = { "table_dining" }, tv_basic = { "tv" },
    lamp_floor = { "lamp" }, bin_indoor = { "bin" },
}
do
    local ids = {}
    for id in pairs(C.LEGACY_TAGS) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local def = SS.Objects[id]
        if def and def.tags == nil then
            def.tags = C.LEGACY_TAGS[id]
            SS.Tags.Apply(def)
        end
    end
end

local function hasAnyTag(def, tags)
    if not def then return false end
    for n = 1, #tags do if SS.Tags.Has(def, tags[n]) then return true end end
    return false
end
C.HasAnyTag = hasAnyTag

local function distTo(actor, o)
    return math.abs(o.x + 0.5 - actor.x) + math.abs(o.y + 0.5 - actor.y) + math.abs(level(o) - (actor.level or 0)) * T.levelCost
end

-- System objects -------------------------------------------------------------------------
local sysdef = M.SystemDef
SS.Objects.food_prep = sysdef({ name = "Food in Progress", mount = "surface", noBlock = true, mess = "food",
    desc = "Ingredients halfway to becoming dinner. They are not getting any fresher.",
    actions = { "continue_cooking", "discard_food" } })
SS.Objects.food_cooking = sysdef({ name = "Pan on the Heat", mount = "surface", noBlock = true,
    desc = "Something is cooking. Someone should probably be watching it.",
    actions = { "continue_cooking", "discard_food" } })
SS.Objects.food_platter = sysdef({ name = "Serving Dish", mount = "surface", noBlock = true, mess = "food",
    desc = "Help yourself. Everyone else already has.",
    actions = { "grab_plate", "store_leftovers", "discard_food" } })
SS.Objects.food_plate = sysdef({ name = "Plate of Food", mount = "surface", noBlock = true, mess = "food",
    desc = "Someone's meal, paused. It will not wait forever.",
    actions = { "eat_plate", "discard_food" } })
SS.Objects.plate_dirty = sysdef({ name = "Dirty Dishes", mount = "surface", noBlock = true, mess = "plate", tags = { "dishes" },
    desc = "Evidence of a meal. The sink is that way.",
    actions = { "clear_plate" } })

-- Held items -----------------------------------------------------------------------------
-- actor.held = { kind = <HELD kind>, ...food/rubbish fields }. Saved; the prop follows it.
C.HELD = {
    ingredients = "groceries", prepared = "bowl", dish = "plate_stack", plate = "plate_food", burnt = "plate_food",
    dirty = "plate_dirty", scraps = "plate_dirty", trash = "trash_bag", bag = "trash_bag", drink = "cup", cup = "cup", book = "book",
}
C.FOOD_KINDS = { ingredients = true, prepared = true, dish = true, plate = true, burnt = true }
local FOOD_KEYS = { "recipe", "q", "q0", "servings", "left", "prepDone", "prepNeed", "cookDone", "cookNeed", "burnAt",
    "madeAt", "burnt", "appliance", "count", "units", "container", "drink", "topic", "skill", "garden", "party" }

local function copyFields(src, dst)
    dst = dst or {}
    for _, k in ipairs(FOOD_KEYS) do dst[k] = src[k] end
    return dst
end
C.CopyFields = copyFields

function C.PropFor(h)
    if not h then return nil end
    if h.kind == "dirty" and (h.count or 1) > 1 then return "plate_stack" end
    return C.HELD[h.kind]
end

function C.Hold(world, actor, kind, fields)
    local h = fields or {}
    h.kind = kind
    actor.held = h
    actor.carry = C.PropFor(h)
    if actor.tmp then actor.tmp.heldTries = nil end
    return h
end

function C.Drop(world, actor)
    actor.held = nil
    actor.carry = nil
end

local function held(actor, kind)
    local h = actor.held
    if not h then return nil end
    if kind and h.kind ~= kind then return nil end
    return h
end
C.Held = held

-- Finding things ---------------------------------------------------------------------------
-- Nearest object with one of `tags` on which `iid` is available for the actor. Busy ones are
-- returned only when nothing is free (the executor then waits). Returns obj or nil, reason.
function C.FindUsable(world, actor, tags, iid, data, filter)
    local best, bestD, busy, busyD, why
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if def and hasAnyTag(def, tags) and (not filter or filter(o, def)) then
            local ok, r, code = A.Available(world, actor, o, iid, data)
            local d = distTo(actor, o)
            if ok then
                if not bestD or d < bestD then best, bestD = o, d end
            elseif code == "busy" or code == "privacy" then
                if not busyD or d < busyD then busy, busyD = o, d end
            elseif not why then
                why = r
            end
        end
    end
    local o = best or busy
    return o, (not o) and why or nil
end

-- Nearest object with a free surface slot of `kinds` within maxD tiles of (i, j) on `lv`.
-- preferTags (optional) make matching surfaces count as 3 tiles closer. Returns obj, slot.
function C.FindSurfaceNear(world, lv, i, j, maxD, kinds, preferTags)
    local best, bestSlot, bestD
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if def and level(o) == lv and not o.parent and W.Surfaces(def) then
            local d = math.abs(o.x - i) + math.abs(o.y - j)
            if d <= (maxD or 99) then
                local slot = W.FreeSurfaceSlot(world, o, kinds)
                if slot then
                    if preferTags and hasAnyTag(def, preferTags) then d = d - 3 end
                    if not bestD or d < bestD then best, bestSlot, bestD = o, slot, d end
                end
            end
        end
    end
    return best, bestSlot
end

-- Can the actor reach a place to use `iid` on `o`? (slot resolution + static reachability)
local PROBE_TGT = {} -- these checks only read the resolved target (ResolveSlot's `into`)
local function reachable(world, actor, o, iid)
    local tgt, why, code = A.ResolveSlot(world, actor, o, iid, PROBE_TGT)
    if not tgt then return code == "busy", why end
    if actor.onObj then return true end
    return SS.Nav.Reachable(world, math.floor(actor.x), math.floor(actor.y), actor.level or 0, tgt.approaches)
end

local function usable(o)
    local def = SS.Objects[o.def]
    return not (o.state and o.state.broken and A.BrokenPolicy(def) == "unavailable")
end

-- Kitchen summary (cached per layout/state version): which appliance kinds work, whether any
-- preparation surface has room. Used for cheap recipe filtering in free will.
local kitchen = {}
function C.Kitchen(world)
    local rt = SS.RT
    if kitchen.ver == rt.objVer and kitchen.env == rt.env and kitchen.lot == world.lot then return kitchen end
    local kinds, prep, fridge = {}, false, false
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if def and usable(o) then
            for kind, tags in pairs(F.applianceTags) do
                if hasAnyTag(def, tags) then kinds[kind] = true end
            end
            if SS.Tags.Has(def, "fridge") then fridge = true end
            if not prep and not o.parent and W.Surfaces(def) and W.FreeSurfaceSlot(world, o, F.prepKinds) then prep = true end
        end
    end
    kitchen = { ver = rt.objVer, env = rt.env, lot = world.lot, kinds = kinds, prep = prep, fridge = fridge }
    return kitchen
end

-- Appliances ----------------------------------------------------------------------------------
function C.ApplianceServes(def, kind)
    if not kind then return false end
    local tags = F.applianceTags[kind]
    return tags and hasAnyTag(def, tags) or false
end

function C.ApplianceQ(def)
    if not def then return FT.applianceDefaultQ end
    return (def.quality and def.quality.cooking) or (def.ratings and def.ratings.hunger) or FT.applianceDefaultQ
end

-- An appliance of `kind` the actor could cook on (free first, busy ones as a fallback).
-- first = true: any one will do (the first free one found, not the nearest), for yes/no checks.
function C.FindAppliance(world, actor, kind, hintId, exceptId, first)
    if hintId then
        local o = world.lot.objects[hintId]
        if o and o.id ~= exceptId and usable(o) and C.ApplianceServes(SS.Objects[o.def], kind) and not (o.cooking and world.lot.objects[o.cooking]) then
            local ok = reachable(world, actor, o, "cook_heat")
            if ok then return o end
        end
    end
    local best, bestD, busy, busyD
    local tags = F.applianceTags[kind] or {}
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if def and oid ~= exceptId and hasAnyTag(def, tags) and usable(o) then
            local cooking = o.cooking and world.lot.objects[o.cooking]
            local tgt, _, code = A.ResolveSlot(world, actor, o, "cook_heat", PROBE_TGT)
            local d = distTo(actor, o)
            if tgt and not cooking and (actor.onObj or SS.Nav.Reachable(world, math.floor(actor.x), math.floor(actor.y), actor.level or 0, tgt.approaches)) then
                if first then return o end
                if not bestD or d < bestD then best, bestD = o, d end
            elseif (code == "busy" or cooking) and (not busyD or d < busyD) then
                busy, busyD = o, d
            end
        end
    end
    return best or busy
end

-- A counter or table with room to prepare food, reachable by the actor (the nearest; first =
-- true: any one will do, for yes/no checks).
function C.FindPrepSurface(world, actor, exceptId, first)
    local best, bestD, busy, busyD
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if def and oid ~= exceptId and not o.parent and W.Surfaces(def) and usable(o) and W.FreeSurfaceSlot(world, o, F.prepKinds) then
            local tgt, _, code = A.ResolveSlot(world, actor, o, "cook_prep", PROBE_TGT)
            local d = distTo(actor, o) + (SS.Tags.Has(def, "counter") and 0 or 2)
            if tgt and (actor.onObj or SS.Nav.Reachable(world, math.floor(actor.x), math.floor(actor.y), actor.level or 0, tgt.approaches)) then
                if first then return o end
                if not bestD or d < bestD then best, bestD = o, d end
            elseif code == "busy" and (not busyD or d < busyD) then
                busy, busyD = o, d
            end
        end
    end
    return best or busy
end

-- Recipes --------------------------------------------------------------------------------
function C.SpeedMult(actor) return 1 / (1 + skillOf(actor, "cooking") * FT.speedPerSkill) end

function C.MealQuality(world, actor, r, appliance, noise)
    local skill = skillOf(actor, "cooking")
    local aq = appliance and C.ApplianceQ(SS.Objects[appliance.def]) or FT.applianceDefaultQ
    local q = FT.qualityBase + FT.qualityPerSkill * skill + FT.qualityPerAppliance * aq - (r.difficulty or 0) * 0.5
        - FT.missingSkill * math.max(0, (r.skill or 0) - skill)
    if appliance and (appliance.dirt or 0) >= T.dirtyAt then q = q - 0.05 end
    if noise then q = q + (SS.Random(world, "cooking") * 2 - 1) * FT.qualityNoise end
    return U.clamp(q, 0.05, 1)
end

function C.BurnChance(actor, r, appliance)
    if not r.appliance then return 0 end
    local B = FT.burn
    local skill = skillOf(actor, "cooking")
    local def = appliance and SS.Objects[appliance.def]
    local p = B.base - B.perSkill * skill + B.perMissingSkill * math.max(0, (r.skill or 0) - skill)
        - B.perApplianceQ * C.ApplianceQ(def) + (r.difficulty or 0)
    if appliance and (appliance.dirt or 0) >= T.dirtyAt then p = p + B.dirty end
    p = p * (B.appliance[r.appliance] or 1)
    return U.clamp(p, B.min, B.max)
end

-- Hunger and fun of one portion at quality q.
function C.Portion(recipeId, q)
    local r = F.recipes[recipeId]
    if not r then return 0, 0 end
    local hq = FT.hungerQuality
    local hunger = r.hunger * (hq[1] + hq[2] * q)
    local fun = math.max(-6, (q - 0.5) * FT.funQuality) + (r.fun or 0) * q
    return hunger, fun
end

-- People on the lot who would eat now (household members present, awake, hunger below 30).
function C.Eaters(world)
    local n = 0
    for _, a in pairs(world.actors) do
        if isMember(world, a) and a.needs and not a.sleeping and (a.kind or "human") == "human" and (a.age or "adult") ~= "infant" and (a.needs.hunger or 0) < 30 then
            n = n + 1
        end
    end
    return math.max(1, n)
end

-- Whether `actor` can cook recipe `id` here. Returns ok, why.
function C.CanCook(world, actor, id, applianceId, auto)
    local r = F.recipes[id]
    if not r then return false, "Unknown recipe." end
    if (actor.age or "adult") == "child" and r.appliance then
        return false, "Too young to use the " .. (F.applianceLabel[r.appliance] or r.appliance) .. "."
    end
    if auto and (r.skill or 0) > skillOf(actor, "cooking") + FT.autoSkillMargin then return false, "Too advanced for this cook." end
    if r.prep > 0 and not C.FindPrepSurface(world, actor, nil, true) then return false, "No free counter or table to prepare food on." end
    if r.appliance and not C.FindAppliance(world, actor, r.appliance, applianceId, nil, true) then
        return false, "Needs a working " .. (F.applianceLabel[r.appliance] or r.appliance) .. "."
    end
    return true
end

-- Choose a recipe (deterministic): fits the hour, the appliances, the cook's skill, the
-- household's hunger and money; recently cooked dishes appeal less. kindHint limits the
-- appliance (cooking "here" on a stove). Returns id or nil, why.
-- Within one decision (Actions.thinking is set for the length of an A.Think) the same question
-- gets the same answer: the advertiser, the price and the test of every fridge ask it again.
local recipeMemo = {}
local chooseRecipe
C.stats = C.stats or { recipeChoices = 0 } -- recipe choices actually worked out (tests, probes)
function C.ChooseRecipe(world, actor, applianceDef, auto)
    local gen = A.thinking
    if not gen then return chooseRecipe(world, actor, applianceDef, auto) end
    local m = recipeMemo
    auto = auto and true or false
    if m.gen == gen and m.actor == actor and m.appliance == applianceDef and m.auto == auto and m.world == world and m.t == world.time then
        return m.id, m.why
    end
    local id, why = chooseRecipe(world, actor, applianceDef, auto)
    m.gen, m.actor, m.appliance, m.auto, m.world, m.t, m.id, m.why = gen, actor, applianceDef, auto, world, world.time, id, why
    return id, why
end
function chooseRecipe(world, actor, applianceDef, auto)
    C.stats.recipeChoices = C.stats.recipeChoices + 1
    local K = C.Kitchen(world)
    local skill = skillOf(actor, "cooking")
    local eaters = C.Eaters(world)
    local hour = hourOf(world)
    local money = world.money or 0
    local urgent = U.clamp((100 - (actor.needs and actor.needs.hunger or 0)) / 100, 0, 2)
    -- up for work or school (the breakfast plan): something that is ready and eaten before the ride
    local plan = auto and actor.tmp and actor.tmp.plan
    local left = plan and plan.kind == "breakfast" and (plan.untilT or 0) > world.time and (plan.untilT - world.time) or nil
    local speed = C.SpeedMult(actor)
    local best, bestV, why
    for _, id in ipairs(F.order) do
        local r = F.recipes[id]
        local ok = true
        if applianceDef and not C.ApplianceServes(applianceDef, r.appliance) then ok = false end
        if ok and r.appliance and not K.kinds[r.appliance] then ok = false; why = why or ("Needs a working " .. (F.applianceLabel[r.appliance] or r.appliance) .. ".") end
        if ok and r.prep > 0 and not K.prep then ok = false; why = why or "No free counter or table to prepare food on." end
        if ok and (actor.age or "adult") == "child" and r.appliance then ok = false; why = why or "Too young to cook that." end
        if ok and auto and (r.skill or 0) > skill + FT.autoSkillMargin then ok = false end
        if ok and isMember(world, actor) and r.cost > money then ok = false; why = why or "The household can't afford the groceries." end
        if ok then
            local q = C.MealQuality(world, actor, r, nil, false)
            local hunger, fun = C.Portion(id, q)
            local v = hunger + math.max(0, fun) * 0.5
            v = v * math.max(0.4, 1 - 0.12 * math.abs(r.servings - eaters))
            if r.hours then
                local inside = hour >= r.hours[1] and hour < r.hours[2]
                v = v * (inside and 1.25 or 0.7)
            end
            if r.kind == "dessert" then v = v * 0.6 end
            if isMember(world, actor) and r.cost > money * 0.1 then v = v * 0.5 end
            v = v / (1 + (r.prep + r.cook) * 0.006 * urgent)
            v = v * (1 - C.BurnChance(actor, r, nil) * 0.8)
            v = v * (0.6 + 0.4 * SS.Needs.RepFactor(world, actor, "recipe:" .. id))
            if left then v = v * ((2 + (r.prep + r.cook) * speed + FT.eatMinutes <= left) and 1.3 or 0.3) end
            if not bestV or v > bestV then best, bestV = id, v end
        end
    end
    if not best then return nil, why or "Nothing can be cooked here." end
    return best
end

-- The recipe an order refers to; chooses (and records in `data`) when none was given, so the
-- cost, the menu text and the cooking always agree.
local function recipeOf(world, actor, obj, data)
    if data and data.recipe and F.recipes[data.recipe] then return data.recipe end
    local applianceDef
    if obj then
        local def = SS.Objects[obj.def]
        if def and not SS.Tags.Has(def, "fridge") then applianceDef = def end
    end
    local id, why = C.ChooseRecipe(world, actor, applianceDef, not (data and data.manual))
    if id and data then data.recipe = id end
    return id, why
end
C.RecipeOf = recipeOf

-- Plans ----------------------------------------------------------------------------------
-- A household plan (e.g. "meal": dinner is on the table) raises interactions with the same
-- `plan` field in free will for its duration.
function C.SetPlan(world, kind, minutes, oid)
    for _, a in pairs(world.actors) do
        if isMember(world, a) then
            a.tmp = a.tmp or {}
            a.tmp.plan = { kind = kind, untilT = world.time + minutes, oid = oid }
        end
    end
end

-- Next steps -----------------------------------------------------------------------------
function C.EatOrder(world, actor)
    local seat = C.FindDiningSeat(world, actor)
    if seat then return { oid = seat.id, iid = "eat_seat" } end
    return { iid = "eat_here" }
end

function C.DishOrder(world, actor)
    local h = actor.held
    if not h or (h.kind ~= "dirty" and h.kind ~= "cup") then return nil end
    local dw = C.FindUsable(world, actor, { "dishwasher" }, "load_dishwasher")
    if dw then return { oid = dw.id, iid = "load_dishwasher" } end
    local s = C.FindUsable(world, actor, { "sink" }, "wash_dishes")
    if s then return { oid = s.id, iid = "wash_dishes" } end
    s = C.FindUsable(world, actor, { "basin" }, "wash_dishes")
    if s then return { oid = s.id, iid = "wash_dishes" } end
    return nil
end

function C.DisposeOrder(world, actor)
    local b = C.FindUsable(world, actor, { "bin" }, "throw_away") or C.FindUsable(world, actor, { "bin_outdoor" }, "throw_away")
    if b then return { oid = b.id, iid = "throw_away" } end
    return { iid = "drop_trash" }
end

function C.ServeSurface(world, actor)
    local best, bestD
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if def and not o.parent and W.Surfaces(def) and usable(o) and W.FreeSurfaceSlot(world, o, F.serveKinds) then
            local ok = reachable(world, actor, o, "serve_food")
            if ok then
                local d = distTo(actor, o)
                if hasAnyTag(def, { "table_dining", "buffet" }) then d = d - 6 end
                if not bestD or d < bestD then best, bestD = o, d end
            end
        end
    end
    return best
end

-- The step that follows whatever food the actor holds.
function C.NextCookStep(world, actor)
    local h = actor.held
    if not h then return nil end
    local r = F.recipes[h.recipe or ""]
    if h.kind == "ingredients" then
        if not r then return C.DisposeOrder(world, actor) end
        if r.prep > 0 then
            local s = C.FindPrepSurface(world, actor)
            if s then return { oid = s.id, iid = "cook_prep" } end
            return nil
        end
        if r.appliance then
            local ap = C.FindAppliance(world, actor, r.appliance, h.appliance)
            if ap then return { oid = ap.id, iid = "cook_heat" } end
            return nil
        end
        C.FinishMeal(world, actor)
        return C.NextCookStep(world, actor)
    elseif h.kind == "prepared" then
        if r and r.appliance then
            local ap = C.FindAppliance(world, actor, r.appliance, h.appliance)
            if ap then return { oid = ap.id, iid = "cook_heat" } end
            return nil
        end
        C.FinishMeal(world, actor)
        return C.NextCookStep(world, actor)
    elseif h.kind == "dish" then
        if (h.servings or 1) <= 1 then
            h.kind = "plate"; h.left = 1; actor.carry = C.PropFor(h)
            return C.EatOrder(world, actor)
        end
        local s = C.ServeSurface(world, actor)
        if s then return { oid = s.id, iid = "serve_food" } end
        return nil
    elseif h.kind == "plate" then
        return C.EatOrder(world, actor)
    elseif h.kind == "burnt" or h.kind == "scraps" or h.kind == "trash" then
        return C.DisposeOrder(world, actor)
    end
    return nil
end

-- What to do next with anything held (idle continuation).
function C.NextFor(world, actor)
    local h = actor.held
    if not h then return nil end
    if C.FOOD_KINDS[h.kind] then return C.NextCookStep(world, actor) end
    if h.kind == "dirty" or h.kind == "cup" then return C.DishOrder(world, actor) end
    if h.kind == "scraps" or h.kind == "trash" then return C.DisposeOrder(world, actor) end
    if h.kind == "bag" then return M.BagOrder(world, actor) end
    if h.kind == "drink" then return { iid = "drink_held" } end
    if h.kind == "book" and SS.Leisure and SS.Leisure.ReturnBookOrder then return SS.Leisure.ReturnBookOrder(world, actor) end
    return nil
end

-- Called by the executor when someone is idle with something in hand: carry on with the
-- natural next step (at most twice), else put it down. With Free Will off, household members
-- only put things down (no self-directed chores behind the player's back).
function C.IdleHeld(world, actor)
    if not actor.held then return end
    actor.tmp = actor.tmp or {}
    local tries = actor.tmp.heldTries or 0
    local nxt
    if tries < 2 and (freeWill(world) or not isMember(world, actor)) then nxt = C.NextFor(world, actor) end
    if nxt then
        actor.tmp.heldTries = tries + 1
        nxt.chain, nxt.manual = true, false
        A.QueueFront(world, actor, nxt)
    else
        actor.tmp.heldTries = nil
        C.SettleHeld(world, actor, "idle")
    end
end

-- Put down whatever is held, where it can be dealt with later (food on a nearby surface,
-- rubbish on the floor). Nothing is duplicated and nothing disappears silently.
function C.SettleHeld(world, actor, why)
    local h = actor.held
    if not h then return end
    actor.held, actor.carry = nil, nil
    if actor.tmp then actor.tmp.heldTries = nil end
    local lv = actor.level or 0
    local i, j = math.floor(actor.x), math.floor(actor.y)
    local k = h.kind
    local placed
    if k == "bag" then
        if W.Blocked(world, lv, i, j) then i, j = SS.Nav.NearestFree(world, lv, i, j, 3) end
        if i then placed = M.Spawn(world, "trash_bag", lv, i, j, { units = h.units or 1 }) end
    elseif k == "trash" or k == "scraps" then
        placed = M.SpawnTrash(world, lv, i, j, h.units or 1)
        if h.container then
            local surf, slot = C.FindSurfaceNear(world, lv, i, j, 3, F.serveKinds)
            if surf then M.SpawnOnSurface(world, "plate_dirty", surf, slot, { count = 1 }).state.stage = 1
            else M.Spawn(world, "plate_dirty", lv, i, j, { count = 1 }).state.stage = 1 end
        end
    elseif k == "drink" or k == "cup" then
        placed = M.SpawnClutter(world, lv, i, j, "cup")
    elseif k == "book" then
        placed = M.SpawnClutter(world, lv, i, j, "book")
    elseif k == "dirty" then
        local surf, slot = C.FindSurfaceNear(world, lv, i, j, 3, F.serveKinds)
        if surf then placed = M.SpawnOnSurface(world, "plate_dirty", surf, slot, { count = h.count or 1 })
        else
            if W.Blocked(world, lv, i, j) then i, j = SS.Nav.NearestFree(world, lv, i, j, 3) end
            if i then placed = M.Spawn(world, "plate_dirty", lv, i, j, { count = h.count or 1 }) end
        end
        if placed then placed.state.stage = h.count or 1 end
    elseif C.FOOD_KINDS[k] then
        local defId = (k == "plate") and "food_plate" or ((k == "dish" or k == "burnt") and "food_platter" or "food_prep")
        local surf, slot = C.FindSurfaceNear(world, lv, i, j, 3, F.serveKinds)
        if surf then
            placed = M.SpawnOnSurface(world, defId, surf, slot, copyFields(h))
            C.FoodState(placed, k)
        else
            placed = M.SpawnTrash(world, lv, i, j, 1)
            if isMember(world, actor) then A.Message(world, actor, "Nowhere to put the food down; it ended up as rubbish.", "hunger") end
        end
    end
    if placed and (placed.def == "plate_dirty" or placed.def == "clutter") then placed.leftBy = actor.id end
    SS.Emit("heldSettled", world, actor, k, why, placed)
    return placed
end

-- Does this person tidy up after themselves this time? what: "plate" (after a meal), "dishes"
-- (a used cup to the sink), "bed" (after getting up), "hands" (after the toilet). The social
-- module's SS.Personality.WillTidy(world, actor, what) decides when present (it rolls on the
-- "personality" stream); otherwise p (from Tuning, by neatness) is rolled on `stream`.
function C.WillTidy(world, actor, what, p, stream)
    local P = SS.Personality
    if P and P.WillTidy then
        local ok, r = pcall(P.WillTidy, world, actor, what)
        if ok and r ~= nil then return r and true or false end
    end
    return SS.Random(world, stream or "tidy") < p
end

-- A tidy person clearing up after someone else in the household grumbles about it
-- (line situation "chores_argument"; the social module owns the words and any fallout).
function C.GrumbleAbout(world, actor, obj)
    local by = obj and obj.leftBy
    if not by or by == actor.id or not A.IsMember(world, actor) then return end
    local other = world.root.residents[by]
    if not other or other.householdId ~= actor.householdId then return end
    local neat = actor.personality and actor.personality.neat or 5
    if neat < T.grumbleNeat then return end
    A.Say(world, actor, "chores_argument", { listener = by, objDef = obj.def, oid = obj.id, role = "speaker" }, "annoyed")
    SS.Emit("choresGrumble", world, actor, other, obj.def)
end

-- Object states for the renderer (ARCHITECTURE 5: stage, cooking, cooked, burnt, spoiled).
function C.FoodState(o, kind)
    o.state = o.state or {}
    local r = F.recipes[o.recipe or ""]
    o.label = r and r.name or nil
    if o.def == "food_prep" then
        o.state.stage = ((o.prepDone or 0) >= (o.prepNeed or 0) and (o.prepNeed or 0) > 0) and "prepped" or ((o.prepDone or 0) > 0 and "prep" or "raw")
    elseif o.def == "food_platter" then
        o.state.cooked = not o.burnt or nil
        o.state.burnt = o.burnt or nil
        o.state.stage = o.servings or 1
    elseif o.def == "food_plate" then
        o.state.cooked = true
        o.state.stage = (o.left or 1) >= 0.75 and "full" or ((o.left or 1) >= 0.35 and "half" or "little")
    end
    if o.spoiled then o.state.spoiled = true end
end

-- The prepared food becomes a finished dish (quality settled once, stored on the food).
function C.FinishMeal(world, actor, appliance)
    local h = actor.held
    if not h then return end
    local r = F.recipes[h.recipe]
    local q = h.q0 or C.GardenBonus(h, C.MealQuality(world, actor, r, appliance, true))
    h.q, h.q0 = q, nil
    h.madeAt = world.time
    h.burnt = nil
    if (r.servings or 1) > 1 then
        h.kind, h.servings = "dish", h.servings or r.servings
    else
        h.kind, h.left = "plate", 1
    end
    actor.carry = C.PropFor(h)
    if q >= FT.proudAt and isMember(world, actor) then
        SS.Needs.Feel(world, actor, "proud")
        A.Say(world, actor, "proud_meal", { meal = r.name, recipe = h.recipe, quality = math.floor(q * 10 + 0.5) }, "proud")
    end
    A.Journal(world, string.format("%s made %s (%s).", actor.name or "Someone", r.name, C.QualityWord(q)), actor)
    SS.Emit("mealCooked", world, actor, h.recipe, q)
end

function C.QualityWord(q)
    if q >= 0.85 then return "delicious" elseif q >= 0.65 then return "good" elseif q >= 0.4 then return "edible" end
    return "barely edible"
end

-- A dish burns: smoke, a ruined meal, a documented fire risk (FT.fireOnBurn * recipe.fireRisk
-- * appliance quality.fireRisk) handed to the events module's SS.Fire.Ignite.
-- The documented cooking fire risk. Burning: FT.fireOnBurn * recipe.fireRisk * the appliance's
-- quality.fireRisk (cheap stoves are riskier). Burnt food left on live heat: FT.unattendedFire per
-- hour, scaled by the appliance's quality.fireRisk. Returns a probability (per burn, or per hour).
-- With the events module present, a cook's burn uses its SS.Fire.CookingChance(actor, stoveDef)
-- (0.2%..8%, falling with cooking skill, scaled by quality.fireRisk) times the recipe's fireRisk,
-- so there is one tuning place for fire.
function C.FireChance(recipeId, applianceDef, unattended, actor)
    local q = applianceDef and applianceDef.quality and applianceDef.quality.fireRisk or 1
    if unattended then return math.min(1, FT.unattendedFire * q) end
    local r = F.recipes[recipeId or ""] or {}
    if actor and SS.Fire and SS.Fire.CookingChance then
        local ok, p = pcall(SS.Fire.CookingChance, actor, applianceDef)
        if ok and type(p) == "number" then return math.min(1, p * (r.fireRisk or 1)) end
    end
    return math.min(1, FT.fireOnBurn * (r.fireRisk or 1) * q)
end

function C.Burn(world, food, appliance, actor)
    if food.burnt then return end
    food.burnt = true
    food.state = food.state or {}
    food.state.burnt, food.state.cooking, food.state.cooked = true, nil, nil
    SS.Emit("lotChanged", "state", food.id)
    W.Touch()
    local r = F.recipes[food.recipe or ""] or {}
    local def = appliance and SS.Objects[appliance.def]
    if appliance and SS.Random(world, "cookfire") < C.FireChance(food.recipe, def, false, actor) then C.Ignite(world, appliance) end
    if actor then
        SS.Needs.Feel(world, actor, "frustrated")
        A.Say(world, actor, "burnt_meal", { meal = r.name, recipe = food.recipe, objDef = appliance and appliance.def or nil }, "burnt")
        A.Message(world, actor, "Burnt the " .. (r.name or "food") .. "!", "burnt")
    end
    A.Journal(world, (r.name or "A meal") .. " burnt" .. (actor and "" or " on an unattended stove") .. ".")
    SS.Emit("mealBurnt", world, food, actor)
end

function C.Ignite(world, appliance)
    if appliance.fireStarted then return end
    appliance.fireStarted = world.time
    SS.Emit("cookingFire", world, appliance)
    if SS.Fire and SS.Fire.Ignite then
        local ok, err = pcall(SS.Fire.Ignite, world, level(appliance), appliance.x, appliance.y, "cooking", appliance.id)
        if not ok then SS.Log("Fire.Ignite failed: %s", tostring(err)) end
    end
end

function C.HeatOff(world, appliance)
    if not appliance then return end
    appliance.cooking = nil
    appliance.fireStarted = nil
    appliance.state = appliance.state or {}
    appliance.state.cooking = nil
    appliance.state.on = nil
    SS.Emit("lotChanged", "state", appliance.id)
end

-- Dining seats: seats next to a table surface first, then any seat. Nil when none is usable.
function C.FindDiningSeat(world, actor)
    local best, bestD
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if def and (def.seat or hasAnyTag(def, { "seat", "sofa" })) and not o.parent then
            local ok = A.Available(world, actor, o, "eat_seat")
            if ok then
                local d = distTo(actor, o)
                local dining = false
                for k = 0, 3 do
                    local dv = G.DIRS[k]
                    local t = W.InLot(world.lot, o.x + dv[1], o.y + dv[2]) and W.ObjectAt(world, level(o), o.x + dv[1], o.y + dv[2])
                    local td = t and SS.Objects[t.def]
                    if td and W.Surfaces(td) then dining = true; break end
                end
                if not dining then d = d + 8 end
                if SS.Tags.Has(def, "sofa") then d = d + 4 end
                if not bestD or d < bestD or (d == bestD and oid < best.id) then best, bestD = o, d end
            end
        end
    end
    return best
end

-- Cooking --------------------------------------------------------------------------------
local function foodObj(world, act) return act.data.food and world.lot.objects[act.data.food] end

-- Groceries for a recipe; a bigger batch (data.servings, e.g. a party pot) costs pro rata.
function C.GroceryCost(r, data)
    local n = data and data.servings
    if n and n ~= r.servings and (r.servings or 1) > 0 then return math.ceil(r.cost * n / r.servings) end
    return r.cost
end

-- Garden produce (family module): harvested food in the household inventory with
-- data.ingredient and data.qty > 0. One portion of it replaces the grocery bill for a normal
-- batch and makes the meal a little better (Food.gardenBonus). Returns the item or nil.
function C.GardenIngredient(world, actor)
    if not (actor and isMember(world, actor) and SS.Inventory and SS.Inventory.List) then return nil end
    local ok, list = pcall(SS.Inventory.List, world, "food")
    if not ok or type(list) ~= "table" then return nil end
    for _, it in ipairs(list) do
        if type(it) == "table" and it.data and it.data.ingredient and (tonumber(it.data.qty) or 0) > 0 then return it end
    end
    return nil
end

-- Use one portion of garden produce (called once, at the commit point). True when used.
function C.UseGardenIngredient(world, actor)
    local it = C.GardenIngredient(world, actor)
    if not it then return false end
    it.data.qty = it.data.qty - 1
    if it.data.qty <= 0 and SS.Inventory.Remove then SS.Inventory.Remove(world, it) end
    SS.Emit("inventory", world, "use", it)
    return true
end

function C.GardenBonus(h, q)
    if h and h.garden then return math.min(1, q + FT.gardenBonus) end
    return q
end

I.cook_meal = {
    label = "Cook a Meal", category = "Food", slot = { "front", "use" }, pose = "use", dur = 1.5, carry = "groceries",
    ages = { adult = true, child = true }, householdOnly = true, ledgerCat = "food", traits = { nice = 0.2, active = 0.1 },
    keepHeld = false,
    estimate = function(world, actor, obj)
        local r = F.recipes[recipeOf(world, actor, obj, nil) or ""]
        if not r then return 30 end
        return 2 + (r.prep + r.cook) * C.SpeedMult(actor) + FT.eatMinutes
    end,
    costFn = function(world, actor, obj, data)
        local id = recipeOf(world, actor, obj, data)
        local r = id and F.recipes[id]
        if not r then return 0 end
        if not (data and data.servings) and C.GardenIngredient(world, actor) then return 0, "From the garden: " .. r.name end
        return C.GroceryCost(r, data), "Groceries: " .. r.name
    end,
    test = function(world, actor, obj, data)
        if actor.held then return false, "Hands are full." end
        local id, why = recipeOf(world, actor, obj, data)
        if not id then return false, why end
        return C.CanCook(world, actor, id, data and data.appliance, not (data and data.manual))
    end,
    advertise = function(world, actor, obj)
        if not isMember(world, actor) then return nil end
        -- a meal is already on the table, on the stove or in the fridge: eat that instead
        if C.FoodWaiting(world) then return nil end
        local id = recipeOf(world, actor, obj, nil)
        if not id then return nil end
        local r = F.recipes[id]
        local q = C.MealQuality(world, actor, r, nil, false)
        local hunger, fun = C.Portion(id, q)
        local eaters = C.Eaters(world)
        return A.Advert("c795", "hunger", hunger * (1 + 0.15 * math.min(3, eaters - 1)), "fun", math.max(0, fun))
    end,
    onStart = function(world, actor, act, obj)
        local id = recipeOf(world, actor, obj, act.data)
        if not id then return false, "Nothing to cook." end
        act.data.recipe = id
        local r = F.recipes[id]
        -- restarted after a load: the groceries (bought or from the garden) were taken the first time
        if act.restarted or act.data.fromGarden then return end
        -- no grocery bill was due because garden produce was in the pantry: use it now (once)
        if isMember(world, actor) and not act.charged and (act.cost or 0) == 0 and (r.cost or 0) > 0 and not act.data.servings then
            if C.UseGardenIngredient(world, actor) then
                act.data.fromGarden = true
            else
                -- someone else used the last of it in the meantime: buy groceries after all
                if (world.money or 0) < r.cost then return false, "Not enough money." end
                A.Charge(world, r.cost, "Groceries: " .. r.name, "food")
                act.charged = true
            end
        end
        SS.Needs.RepAdd(world, actor, "recipe:" .. id)
    end,
    onEnd = function(world, actor, act, obj, status)
        -- Once the groceries are out (paid), they exist in the world whatever happens next.
        if not act.performed or actor.held then return end
        local r = F.recipes[act.data.recipe or ""]
        if not r then return end
        local rs = C.SpeedMult(actor)
        local n = act.data.servings or r.servings
        local scale = math.max(1, n / math.max(1, r.servings or 1))
        C.Hold(world, actor, "ingredients", { recipe = act.data.recipe, servings = n, appliance = act.data.appliance,
            prepNeed = r.prep * rs * math.sqrt(scale), cookNeed = r.cook * rs, madeAt = world.time,
            garden = act.data.fromGarden or nil, party = act.data.party })
    end,
    next = function(world, actor) return C.NextCookStep(world, actor) end,
}

-- "Cook Here" on an appliance: the same chain, starting at the fridge with this appliance.
I.cook_at = {
    label = "Cook Here", category = "Food", slot = { "front", "use" }, pose = "use", manualOnly = true,
    ages = { adult = true, child = true }, householdOnly = true,
    costFn = I.cook_meal.costFn,
    test = function(world, actor, obj, data)
        if actor.held then return false, "Hands are full." end
        local id, why = recipeOf(world, actor, obj, data)
        if not id then return false, why end
        if not C.Kitchen(world).fridge then return false, "There's no fridge to get ingredients from." end
        return C.CanCook(world, actor, id, obj.id, false)
    end,
    redirect = function(world, actor, order)
        local obj = world.lot.objects[order.oid or ""]
        if not obj then return false, "That object is gone." end
        local data = order.data or {}
        data.manual = true
        local id, why = recipeOf(world, actor, obj, data)
        if not id then return false, why end
        local fridge = C.FindUsable(world, actor, { "fridge" }, "cook_meal", { recipe = id, appliance = obj.id, manual = true })
        if not fridge then return false, "There's no fridge to get ingredients from." end
        return { oid = fridge.id, iid = "cook_meal", data = { recipe = id, appliance = obj.id, manual = true } }
    end,
}

-- A group meal for a party (family module): the host cooks one big pot of Food.groupServings
-- portions through the normal chain (fridge -> counter -> heat -> serving dish), paid once at
-- the fridge, pro rata. opts = { party = recordId, recipe = id? }. Returns true, recipeId or
-- false, why. The best big-pot recipe the host can make is chosen when none is given.
function C.GroupMeal(world, host, opts)
    opts = opts or {}
    if not (host and world.actors[host.id or ""] == host) then return false, "The host isn't here." end
    if not isMember(world, host) then return false, "Only a resident can cook for the household's guests." end
    if (host.age or "adult") ~= "adult" then return false, "A grown-up has to cook for a party." end
    local fridge = C.FindUsable(world, host, { "fridge" }, "cook_meal", { manual = true })
    if not fridge then return false, "There's no fridge to get ingredients from." end
    local n = FT.groupServings
    local best, why
    local candidates = opts.recipe and { opts.recipe } or F.order
    for _, id in ipairs(candidates) do
        local r = F.recipes[id]
        if r and (r.servings or 1) >= FT.groupMinServings then
            local ok, w = C.CanCook(world, host, id, nil, true)
            if ok then
                local b = best and F.recipes[best]
                if not b or (r.skill or 0) > (b.skill or 0) or ((r.skill or 0) == (b.skill or 0) and r.hunger > b.hunger) then best = id end
            else
                why = why or w
            end
        end
    end
    if not best then return false, why or "No big-pot recipe can be cooked here." end
    local data = { recipe = best, servings = n, manual = true, party = opts.party }
    local cost = C.GroceryCost(F.recipes[best], data)
    if (world.money or 0) < cost then return false, "Groceries for a party meal cost " .. U.fmtMoney(cost) .. "; not enough money." end
    if not A.Order(world, host, fridge.id, "cook_meal", nil, nil, { data = data }) then return false, "The host's queue is full." end
    SS.Emit("groupMeal", world, host, best, opts.party)
    return true, best
end

I.cook_prep = {
    usesHeld = { ingredients = true },
    label = "Prepare Food", category = "Food", hidden = true, slot = { "front", "use", "stand" }, pose = "cook", noInterrupt = true,
    useTags = { "counter", "table_dining" }, ages = { adult = true, child = true }, householdOnly = true, noise = 1,
    findAlt = function(world, actor, act) return C.FindPrepSurface(world, actor, act.oid) end,
    test = function(world, actor, obj, data)
        local food = data and data.food and world.lot.objects[data.food]
        if food then
            if food.parent ~= obj.id then return false, "The food isn't here." end
            if food.cook and food.cook ~= actor.id and world.actors[food.cook] then return false, "Someone is already working on it." end
            return true
        end
        if not held(actor, "ingredients") then return false, "Nothing to prepare." end
        if not W.FreeSurfaceSlot(world, obj, F.prepKinds) then return false, "No free space here." end
        return true
    end,
    onStart = function(world, actor, act, obj)
        local food = foodObj(world, act)
        if not food then
            local h = held(actor, "ingredients")
            local slot = W.FreeSurfaceSlot(world, obj, F.prepKinds)
            if not h or not slot then return false, "No free space to prepare food." end
            food = M.SpawnOnSurface(world, "food_prep", obj, slot, copyFields(h))
            C.Drop(world, actor)
            act.data.food = food.id
        end
        food.cook = actor.id
        food.state.stage = "prep"
        act.dur = math.max(0.25, ((food.prepNeed or 0) - (food.prepDone or 0)) / C.Speed(obj))
        act.skill = { cooking = FT.prepSkill }
    end,
    onResume = function(world, actor, act, obj)
        local food = foodObj(world, act)
        if food then food.cook = actor.id end
        act.skill = { cooking = FT.prepSkill }
    end,
    onTick = function(world, actor, act, obj, dt)
        local food = foodObj(world, act)
        if not food then act.failWhy = "The food is gone."; return end
        food.prepDone = (food.prepDone or 0) + dt * C.Speed(obj)
    end,
    onEnd = function(world, actor, act, obj, status)
        local food = foodObj(world, act)
        if not food then return end
        food.cook = nil
        if status == "done" then
            local fields = copyFields(food)
            fields.prepDone = fields.prepNeed
            act.removing = true
            M.Remove(world, food)
            C.Hold(world, actor, "prepared", fields)
        else
            C.FoodState(food)
            if isMember(world, actor) and act.performed then A.Message(world, actor, "The food was left half-prepared on the counter.", "hunger") end
        end
    end,
    next = function(world, actor) return C.NextCookStep(world, actor) end,
}

I.cook_heat = {
    usesHeld = { ingredients = true, prepared = true },
    label = "Cook", category = "Food", hidden = true, slot = { "front", "use" }, pose = "cook", noise = 1, risk = 0.05, noInterrupt = true,
    useTags = { "stove", "oven", "microwave", "grill", "toaster" }, ages = { adult = true }, householdOnly = true,
    findAlt = function(world, actor, act)
        local food = act.data.food and world.lot.objects[act.data.food]
        if food then return nil end -- the pot stays where it is
        local h = actor.held
        local r = h and F.recipes[h.recipe or ""]
        return r and r.appliance and C.FindAppliance(world, actor, r.appliance, nil, act.oid) or nil
    end,
    test = function(world, actor, obj, data)
        local food = data and data.food and world.lot.objects[data.food]
        local h = actor.held
        local rid = food and food.recipe or (h and h.recipe)
        local r = rid and F.recipes[rid]
        if not r or not r.appliance then return false, "Nothing to cook." end
        if not C.ApplianceServes(SS.Objects[obj.def], r.appliance) then return false, "This isn't a " .. (F.applianceLabel[r.appliance] or "cooker") .. "." end
        local cooking = obj.cooking and world.lot.objects[obj.cooking]
        if cooking and cooking ~= food then return false, "Something is already cooking there." end
        if food then
            if food.cook and food.cook ~= actor.id and world.actors[food.cook] then return false, "Someone is already cooking it." end
        elseif not (h and (h.kind == "prepared" or h.kind == "ingredients")) then
            return false, "Nothing to cook."
        end
        return true
    end,
    onStart = function(world, actor, act, obj)
        local food = foodObj(world, act)
        local def = SS.Objects[obj.def]
        if not food then
            local h = actor.held
            if not h then return false, "Nothing to cook." end
            local r = F.recipes[h.recipe]
            food = M.Spawn(world, "food_cooking", level(obj), obj.x, obj.y, copyFields(h))
            -- the pan sits on the cooker (`appliance`, drawn at the cooker's height `z`); it is not a
            -- surface child (`parent`), because a hob or oven door is not a place to set things down
            food.z = def.height or 0.9
            food.appliance = obj.id
            W.ObjectsChanged()
            food.cookNeed = food.cookNeed or r.cook
            -- quality and the burn are rolled once per dish and stored with it, so stopping and
            -- restarting (or moving the pan to another cooker) cannot re-roll them
            if not food.q0 then
                food.q0 = C.GardenBonus(food, C.MealQuality(world, actor, r, obj, true))
                if SS.Random(world, "cooking") < C.BurnChance(actor, r, obj) then
                    food.burnAt = food.cookNeed * (0.45 + 0.4 * SS.Random(world, "cooking"))
                end
            end
            C.Drop(world, actor)
            act.data.food = food.id
        end
        food.cook = actor.id
        food.state.cooking = true
        obj.cooking = food.id
        obj.state = obj.state or {}
        obj.state.cooking, obj.state.on = true, true
        SS.Emit("lotChanged", "state", obj.id)
        act.dur = math.max(0.25, ((food.cookNeed or 0) - (food.cookDone or 0)) / C.Speed(obj))
        act.skill = { cooking = FT.cookSkill }
    end,
    onResume = function(world, actor, act, obj)
        local food = foodObj(world, act)
        if food then food.cook = actor.id end
        act.skill = { cooking = FT.cookSkill }
    end,
    onTick = function(world, actor, act, obj, dt)
        local food = foodObj(world, act)
        if not food then act.failWhy = "The food is gone."; return end
        if food.burnt then act.complete = true; return end
        food.cookDone = (food.cookDone or 0) + dt * C.Speed(obj)
        if food.burnAt and food.cookDone >= food.burnAt then
            C.Burn(world, food, obj, actor)
            act.complete = true
        end
    end,
    onEnd = function(world, actor, act, obj, status)
        local food = foodObj(world, act)
        if not food then
            if obj and obj.cooking == act.data.food then C.HeatOff(world, obj) end
            return
        end
        food.cook = nil
        if status == "done" or food.burnt then
            local fields = copyFields(food)
            local burnt = food.burnt
            act.removing = true
            M.Remove(world, food)
            C.HeatOff(world, obj)
            if burnt then
                C.Hold(world, actor, "burnt", fields).container = true
            else
                C.Hold(world, actor, "prepared", fields)
                C.FinishMeal(world, actor, obj)
            end
        elseif obj and obj.state and obj.state.broken then
            -- the cooker broke under the pan: the heat is off and the dish waits, half-cooked
            C.HeatOff(world, obj)
            food.state.cooking = nil
            if isMember(world, actor) then
                local d = SS.Objects[obj.def]
                A.Message(world, actor, "The " .. (d and d.name or "cooker") .. " broke with the " .. ((F.recipes[food.recipe or ""] or {}).name or "food") .. " on it.", "broken")
            end
        elseif act.performed then
            -- left on the heat: it keeps cooking unattended (system tick) and needs attention
            if isMember(world, actor) then A.Message(world, actor, "Left the " .. ((F.recipes[food.recipe or ""] or {}).name or "food") .. " cooking on the heat.", "hunger") end
            SS.Emit("cookingUnattended", world, food, obj)
        end
    end,
    next = function(world, actor) return C.NextCookStep(world, actor) end,
}

-- A pan whose cooker is broken (unusable) has to move to another one.
function C.PanNeedsMove(world, food)
    if food.def ~= "food_cooking" or food.burnt then return false end
    local ap = world.lot.objects[food.appliance or food.parent or ""]
    return ap ~= nil and not usable(ap)
end

-- Unfinished food that cannot go on for want of a working cooker: returns the reason, else nil.
-- (Without this, picking it up and putting it down again would loop.)
function C.StuckFood(world, actor, food)
    local r = F.recipes[food.recipe or ""]
    if not (r and r.appliance) or food.burnt then return nil end
    local needsHeat
    if food.def == "food_cooking" then needsHeat = C.PanNeedsMove(world, food)
    elseif food.def == "food_prep" then needsHeat = (food.prepDone or 0) >= (food.prepNeed or 0) end
    if not needsHeat then return nil end
    local ap = world.lot.objects[food.appliance or food.parent or ""]
    if C.FindAppliance(world, actor, r.appliance, nil, ap and food.def == "food_cooking" and ap.id or nil) then return nil end
    local d = ap and food.def == "food_cooking" and SS.Objects[ap.def]
    if d then return "The " .. d.name .. " is broken and there is nothing else to cook it on." end
    return "There is nothing working to cook it on."
end

-- Continue whatever an unfinished dish needs (prep, heat, take it off, throw it out).
I.continue_cooking = {
    label = "Continue Cooking", category = "Food", slot = "around", pose = "use", dur = 0.3,
    ages = { adult = true, child = true }, householdOnly = true, service = false,
    test = function(world, actor, obj)
        if obj.cook and obj.cook ~= actor.id and world.actors[obj.cook] then return false, "Someone is already on it." end
        if obj.spoiled then return false, "It has gone off; throw it away." end
        if obj.def == "food_prep" and actor.held then return false, "Hands are full." end
        local r = F.recipes[obj.recipe or ""]
        if obj.def == "food_prep" and r and r.appliance and (actor.age or "adult") == "child" then return false, "Too young to cook that." end
        if obj.def == "food_cooking" and (actor.age or "adult") == "child" then return false, "Too young to use the cooker." end
        local stuck = C.StuckFood(world, actor, obj)
        if stuck then return false, stuck end
        if obj.def == "food_cooking" and actor.held and C.PanNeedsMove(world, obj) then return false, "Hands are full." end
        return true
    end,
    advertise = function(world, actor, obj)
        if not isMember(world, actor) or obj.spoiled then return nil end
        if obj.def == "food_cooking" then
            if obj.burnt then return nil end
            local urgent = obj.state and obj.state.cooked
            return A.Advert("c1107", "hunger", urgent and 40 or 25, "room", urgent and 30 or 10)
        end
        return A.Advert("c1109", "hunger", 20)
    end,
    redirect = function(world, actor, order)
        local food = world.lot.objects[order.oid or ""]
        if not food then return false, "It's gone." end
        if food.def == "food_cooking" then
            if food.burnt then return { oid = food.id, iid = "discard_food" } end
            local ap = world.lot.objects[food.appliance or food.parent or ""]
            if not ap then return false, "The cooker is gone." end
            -- the cooker broke under it: take the pan off and finish it on another one
            if C.PanNeedsMove(world, food) then return { oid = food.id, iid = "pick_up_food" } end
            return { oid = ap.id, iid = "cook_heat", data = { food = food.id } }
        end
        if food.def == "food_prep" then
            local surf = world.lot.objects[food.parent or ""]
            if surf and (food.prepDone or 0) < (food.prepNeed or 0) then
                return { oid = surf.id, iid = "cook_prep", data = { food = food.id } }
            end
            return { oid = food.id, iid = "pick_up_food" }
        end
        return false, "Nothing to continue."
    end,
}

-- Pick up food that is ready for its next step (prepared food, a finished pot off the heat).
I.pick_up_food = {
    label = "Pick Up", category = "Food", hidden = true, slot = "around", pose = "use", dur = 0.3,
    ages = { adult = true, child = true }, householdOnly = true,
    test = function(world, actor, obj)
        if actor.held then return false, "Hands are full." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj then return end
        local fields = copyFields(obj)
        local kind = (obj.def == "food_prep") and (((obj.prepDone or 0) > 0 or (obj.prepNeed or 0) == 0) and "prepared" or "ingredients") or "dish"
        if obj.def == "food_cooking" then
            -- a pan taken off a (broken) cooker: still to be cooked, wherever works
            local ap = world.lot.objects[obj.appliance or obj.parent or ""]
            if ap and ap.cooking == obj.id then C.HeatOff(world, ap) end
            kind, fields.appliance = "prepared", nil
        end
        act.removing = true
        M.Remove(world, obj)
        C.Hold(world, actor, kind, fields)
    end,
    next = function(world, actor) return C.NextCookStep(world, actor) end,
}

-- Turn the heat off under a pot (it stays there, half-cooked, until someone continues).
I.turn_off_heat = {
    label = "Turn Off the Heat", category = "Food", slot = { "front", "use" }, pose = "use", dur = 0.3, noWear = true,
    requireState = { cooking = true }, requireText = "Nothing is cooking.", ages = { adult = true, child = true },
    care = true, -- looking after the cooker, not using it: open on an adults-only grill too (Actions.DesignFor)
    advertise = function(world, actor, obj)
        local food = obj.cooking and world.lot.objects[obj.cooking]
        if food and food.burnt and isMember(world, actor) then return A.Advert("c1164", "room", 35) end
        return nil
    end,
    test = function(world, actor, obj)
        local food = obj.cooking and world.lot.objects[obj.cooking]
        if food and food.cook and world.actors[food.cook] and food.cook ~= actor.id then return false, "Someone is cooking there." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj then return end
        local food = obj.cooking and world.lot.objects[obj.cooking]
        C.HeatOff(world, obj)
        if food then food.state.cooking = nil end
    end,
}

-- Serving and eating ---------------------------------------------------------------------
I.serve_food = {
    usesHeld = { dish = true },
    label = "Serve", category = "Food", hidden = true, slot = { "front", "use", "stand" }, pose = "use", dur = 0.5,
    useTags = { "table_dining", "buffet", "counter" }, ages = { adult = true, child = true },
    findAlt = function(world, actor, act) return C.ServeSurface(world, actor) end,
    test = function(world, actor, obj)
        if not held(actor, "dish") then return false, "Nothing to serve." end
        if not W.FreeSurfaceSlot(world, obj, F.serveKinds) then return false, "No room to put it down here." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        local h = held(actor, "dish")
        if status ~= "done" or not h or not obj then return end
        local slot = W.FreeSurfaceSlot(world, obj, F.serveKinds)
        if not slot then act.failWhy = "No room to put it down."; return end
        local p = M.SpawnOnSurface(world, "food_platter", obj, slot, copyFields(h))
        C.FoodState(p)
        C.Drop(world, actor)
        act.data.platter = p.id
        local r = F.recipes[p.recipe or ""]
        C.SetPlan(world, "meal", FT.planMinutes, p.id)
        actor.balloon = { icon = "hunger", text = (r and r.name or "Food") .. " is served!", untilT = world.time + 10, kind = "speech" }
        SS.Emit("mealServed", world, actor, p)
    end,
    next = function(world, actor, act)
        local p = act.data.platter and world.lot.objects[act.data.platter]
        if p and actor.needs and (actor.needs.hunger or 0) < 60 then return { oid = p.id, iid = "grab_plate" } end
    end,
}

local function edible(o)
    return o and not o.spoiled and not o.burnt and not (o.state and (o.state.spoiled or o.state.burnt))
end

I.grab_plate = {
    label = "Grab a Plate", category = "Food", slot = "around", pose = "use", dur = 0.5, plan = "meal",
    ages = { adult = true, child = true },
    estimate = function() return FT.eatMinutes + 2 end,
    test = function(world, actor, obj)
        if actor.held and not held(actor, "dish") then return false, "Hands are full." end
        if not edible(obj) then return false, obj.burnt and "It's burnt." or "It has gone off." end
        if (obj.servings or 0) < 1 then return false, "None left." end
        return true
    end,
    advertise = function(world, actor, obj)
        if not edible(obj) or (obj.servings or 0) < 1 then return nil end
        local hunger, fun = C.Portion(obj.recipe, obj.q or 0.5)
        return A.Advert("c1228", "hunger", hunger, "fun", math.max(0, fun))
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj or not world.lot.objects[obj.id] then return end
        if (obj.servings or 0) < 1 then act.failWhy = "None left."; return end
        obj.servings = obj.servings - 1
        C.Hold(world, actor, "plate", { recipe = obj.recipe, q = obj.q, left = 1, madeAt = obj.madeAt })
        if obj.servings <= 0 then
            -- the empty serving dish stays behind as a dirty dish
            local parent = world.lot.objects[obj.parent or ""]
            local slotKey, z = obj.pslot, obj.z
            act.removing = true
            M.Remove(world, obj)
            local d
            if parent then
                d = M.Spawn(world, "plate_dirty", level(parent), obj.x, obj.y, { count = 1 })
                d.parent, d.pslot, d.z = parent.id, slotKey, z
                W.ObjectsChanged()
            else
                d = M.Spawn(world, "plate_dirty", level(obj), obj.x, obj.y, { count = 1 })
            end
            d.state.stage = 1
        else
            C.FoodState(obj)
            SS.Emit("lotChanged", "state", obj.id)
        end
    end,
    next = function(world, actor) if held(actor, "plate") then return C.EatOrder(world, actor) end end,
}

-- Eating (seated or standing). The gain comes from the held plate: portion size and quality,
-- scaled by how much is left; an interruption keeps the rest on the plate.
local function startEating(world, actor, act, standing)
    local h = held(actor, "plate")
    if not h then return false, "Nothing to eat." end
    local left = h.left or 1
    local hunger, fun = C.Portion(h.recipe, h.q or 0.5)
    act.data.left0 = left
    act.data.gain = { hunger = hunger * left, fun = fun * left, bladder = FT.eatBladder * left }
    act.gain = act.data.gain
    act.dur = math.max(1, FT.eatMinutes * left)
    if standing then act.rates = { comfort = FT.standComfort } end
    actor.carry = "plate_food"
    act.data.socialT = 0
end

local function eatingNearby(world, actor)
    local n = 0
    for id, b in pairs(world.actors) do
        if b ~= actor and b.act and b.act.phase == "perform" and (b.act.iid == "eat_seat" or b.act.iid == "eat_here")
            and (b.level or 0) == (actor.level or 0) and math.abs(b.x - actor.x) + math.abs(b.y - actor.y) <= 3 then
            n = n + 1
        end
    end
    return n
end

local function tickEating(world, actor, act, dt)
    local h = held(actor, "plate")
    if not h then act.failWhy = "The food is gone."; return end
    h.left = (act.data.left0 or 1) * math.max(0, 1 - (act.t + dt) / math.max(0.01, act.dur))
    -- company at the table
    if eatingNearby(world, actor) > 0 then
        SS.Needs.Add(actor, "social", FT.eatSocial * dt / 60)
        act.data.socialT = (act.data.socialT or 0) + dt
        if act.data.socialT >= T.shareRel.every then
            act.data.socialT = 0
            for id, b in pairs(world.actors) do
                if b ~= actor and b.act and (b.act.iid == "eat_seat" or b.act.iid == "eat_here") and SS.Social and SS.Social.Change
                    and math.abs(b.x - actor.x) + math.abs(b.y - actor.y) <= 3 then
                    SS.Social.Change(world, actor.id, id, T.shareRel.daily, T.shareRel.life)
                end
            end
        end
    end
end

-- After a meal: the plate goes to the sink (neat people, by chance) or is left on the table.
local function afterMeal(world, actor, act, status)
    local h = held(actor, "plate")
    if not h then return end
    if status == "done" or (h.left or 0) < 0.05 then
        h.kind, h.left, h.count = "dirty", nil, 1
        h.recipe, h.q = nil, nil
        actor.carry = "plate_dirty"
        local neat = actor.personality and actor.personality.neat or 5
        local p = FT.tidy.base + FT.tidy.perNeat * neat
        if C.WillTidy(world, actor, "plate", p, "tidy") then
            act.data.tidy = true
        else
            -- left behind on the nearest table (tidiness depends on personality)
            local placed = C.SettleHeld(world, actor, "left")
            if A.IsMember(world, actor) then
                A.Say(world, actor, "messy_plate", { objDef = placed and placed.def or "plate_dirty", oid = placed and placed.id or nil })
            end
        end
    end
end

local function eatNext(world, actor, act)
    if act.data.tidy and held(actor, "dirty") then
        local o = C.DishOrder(world, actor)
        if o then o.optional = true; return o end
    end
end

I.eat_seat = {
    usesHeld = { plate = true },
    label = "Eat", category = "Food", hidden = true, slot = "seat", pose = "sit_eat", ages = { adult = true, child = true },
    useTags = { "seat", "sofa" },
    findAlt = function(world, actor, act) return C.FindDiningSeat(world, actor) end,
    test = function(world, actor, obj)
        local h = held(actor, "plate")
        if not h then return false, "Nothing to eat." end
        return true
    end,
    onStart = function(world, actor, act, obj) return startEating(world, actor, act, false) end,
    onResume = function(world, actor, act, obj) act.gain = act.data.gain; actor.carry = "plate_food" end,
    onTick = function(world, actor, act, obj, dt) tickEating(world, actor, act, dt) end,
    onEnd = function(world, actor, act, obj, status) afterMeal(world, actor, act, status) end,
    next = eatNext,
}

I.eat_here = {
    usesHeld = { plate = true },
    label = "Eat Standing", category = "Food", hidden = true, slot = "here", pose = "eat_stand", ages = { adult = true, child = true },
    test = function(world, actor)
        if not held(actor, "plate") then return false, "Nothing to eat." end
        return true
    end,
    onStart = function(world, actor, act) return startEating(world, actor, act, true) end,
    onResume = function(world, actor, act) act.gain = act.data.gain; act.rates = { comfort = FT.standComfort }; actor.carry = "plate_food" end,
    onTick = function(world, actor, act, obj, dt) tickEating(world, actor, act, dt) end,
    onEnd = function(world, actor, act, obj, status) afterMeal(world, actor, act, status) end,
    next = eatNext,
}

-- A plate someone left (partly eaten): pick it up and finish it.
I.eat_plate = {
    label = "Eat This", category = "Food", slot = "around", pose = "use", dur = 0.3, ages = { adult = true, child = true },
    estimate = function(world, actor, obj) return FT.eatMinutes * (obj and obj.left or 1) + 1 end,
    test = function(world, actor, obj)
        if actor.held then return false, "Hands are full." end
        if not edible(obj) then return false, "It has gone off." end
        return true
    end,
    advertise = function(world, actor, obj)
        if not edible(obj) then return nil end
        local hunger, fun = C.Portion(obj.recipe, obj.q or 0.5)
        return A.Advert("c1377", "hunger", hunger * (obj.left or 1), "fun", math.max(0, fun) * (obj.left or 1))
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj or not world.lot.objects[obj.id] then return end
        local fields = copyFields(obj)
        act.removing = true
        M.Remove(world, obj)
        C.Hold(world, actor, "plate", fields)
    end,
    next = function(world, actor) if held(actor, "plate") then return C.EatOrder(world, actor) end end,
}

-- Throw food away (spoiled, burnt, unwanted): scraps to the bin, the plate to the sink.
I.discard_food = {
    label = "Throw Away", category = "Chores", slot = "around", pose = "clean", dur = 1, chore = true, noWear = true,
    traits = { neat = 1 }, householdOnly = true, service = true, ages = { adult = true, child = true },
    test = function(world, actor, obj)
        if actor.held then return false, "Hands are full." end
        if obj.cook and obj.cook ~= actor.id and world.actors[obj.cook] then return false, "Someone is using it." end
        if obj.def == "food_cooking" and (actor.age or "adult") == "child" and not obj.burnt then return false, "Too young to use the cooker." end
        return true
    end,
    advertise = function(world, actor, obj)
        if obj.spoiled or obj.burnt then return A.Advert("c1400", "room", 30) end
        return nil
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj or not world.lot.objects[obj.id] then return end
        local units = math.max(1, math.ceil((obj.servings or 1) * (obj.left or 1) / 2))
        local container = obj.def ~= "food_prep"
        if obj.def == "food_cooking" then
            local ap = world.lot.objects[obj.appliance or obj.parent or ""]
            if ap and ap.cooking == obj.id then C.HeatOff(world, ap) end
        end
        act.removing = true
        M.Remove(world, obj)
        C.Hold(world, actor, "scraps", { units = units, container = container })
    end,
    next = function(world, actor) return C.DisposeOrder(world, actor) end,
}

-- Leftovers: a platter goes into the fridge (kept longer), portions come back out later.
I.store_leftovers = {
    label = "Put Away Leftovers", category = "Food", slot = "around", pose = "use", dur = 0.5, chore = true, noWear = true,
    traits = { neat = 0.8 }, householdOnly = true, ages = { adult = true, child = true },
    test = function(world, actor, obj)
        if actor.held then return false, "Hands are full." end
        if not edible(obj) then return false, "It has gone off." end
        local fridge = C.FindUsable(world, actor, { "fridge" }, "put_in_fridge", { probe = true })
        if not fridge then return false, "There's no room in a fridge." end
        return true
    end,
    advertise = function(world, actor, obj)
        if not edible(obj) or (obj.servings or 0) < 1 then return nil end
        -- once the meal has been sitting a while, tidy people put it away
        if world.time - (obj.madeAt or world.time) < 60 then return nil end
        return A.Advert("c1433", "room", 16)
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj or not world.lot.objects[obj.id] then return end
        local fields = copyFields(obj)
        act.removing = true
        M.Remove(world, obj)
        C.Hold(world, actor, "dish", fields).stored = true
    end,
    next = function(world, actor)
        local fridge = C.FindUsable(world, actor, { "fridge" }, "put_in_fridge")
        if fridge then return { oid = fridge.id, iid = "put_in_fridge" } end
    end,
}

-- The catalogue's quality.freshness (its HC-3): food keeps this many times longer in a better
-- fridge (1 = an ordinary one).
function C.Freshness(o)
    local def = o and SS.Objects[o.def]
    local f = def and def.quality and def.quality.freshness
    if type(f) == "number" and f > 0 then return f end
    return 1
end

-- Room left in a fridge for `servings` more: a design with quality.capacity holds that many
-- servings (the catalogue's HC-3: 12, 18, 30); without one it holds Tuning.food.stockCap dishes.
function C.FridgeTakes(o, servings)
    local def = o and SS.Objects[o.def]
    local cap = def and def.quality and def.quality.capacity
    local stock = o.stock or {}
    if type(cap) ~= "number" then return #stock < FT.stockCap end
    if #stock >= FT.stockMaxEntries then return false end
    local used = 0
    for n = 1, #stock do used = used + (stock[n].servings or 1) end
    return used + (servings or 1) <= cap
end

local function stockSpoiled(o, e, world)
    local mult = FT.fridgeSpoilMult * C.Freshness(o)
    if o.state and o.state.broken then mult = 1 end
    local r = F.recipes[e.recipe or ""] or {}
    return world.time - (e.at or 0) >= (r.spoilHours or FT.spoilHours) * 60 * mult
end

I.put_in_fridge = {
    usesHeld = { dish = true },
    label = "Put in Fridge", category = "Food", hidden = true, slot = { "front", "use" }, pose = "use", dur = 1, noWear = true,
    useTags = { "fridge" }, householdOnly = true, ages = { adult = true, child = true },
    test = function(world, actor, obj, data)
        if not (data and data.probe) and not held(actor, "dish") then return false, "Nothing to put away." end
        local h = held(actor, "dish")
        if not C.FridgeTakes(obj, h and h.servings or 1) then return false, "The fridge is full." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        local h = held(actor, "dish")
        if status ~= "done" or not h or not obj then return end
        obj.stock = obj.stock or {}
        if not C.FridgeTakes(obj, h.servings or 1) then act.failWhy = "The fridge is full."; return end
        obj.stock[#obj.stock + 1] = { recipe = h.recipe, q = h.q or 0.5, servings = h.servings or 1, at = h.madeAt or world.time }
        C.Drop(world, actor)
        SS.Emit("lotChanged", "state", obj.id)
    end,
}

local function freshStock(world, o)
    for n, e in ipairs(o.stock or {}) do
        if not e.spoiled and not stockSpoiled(o, e, world) and (e.servings or 0) > 0 then return e, n end
    end
end

-- Food that is already waiting or on its way (a served dish, a meal being made, fresh
-- leftovers): free will eats that instead of starting another meal. Cached per state version
-- and 10 sim minutes (spoilage moves with time).
local waiting = { v = false }
-- A dish on its way that needs a cooker of a kind none of which works (the stove broke under it
-- and there is no other) can't be finished: it is not a meal on its way. Counting it as one kept
-- anyone from cooking again (even a salad) until it spoiled.
local function finishable(world, recipe, food)
    local r = F.recipes[recipe or ""]
    if not (r and r.appliance) then return true end
    if food and food.def == "food_cooking" and not C.PanNeedsMove(world, food) then return true end
    return C.Kitchen(world).kinds[r.appliance] == true
end
C.Finishable = function(world, food) return finishable(world, food and food.recipe, food) end

function C.FoodWaiting(world)
    local rt = SS.RT
    local slot = math.floor(world.time / 10)
    if waiting.ver == rt.objVer and waiting.env == rt.env and waiting.slot == slot and waiting.lot == world.lot then return waiting.v end
    local v = false
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        if o then
            if o.def == "food_platter" and edible(o) and (o.servings or 0) > 0 then v = "served"; break end
            if (o.def == "food_prep" or o.def == "food_cooking") and edible(o) and finishable(world, o.recipe, o) then v = "cooking"; break end
            if o.stock and freshStock(world, o) then v = "leftovers"; break end
        end
    end
    if not v then
        for _, a in pairs(world.actors) do
            local h = a.held
            if h and (h.kind == "ingredients" or h.kind == "prepared") and isMember(world, a) and finishable(world, h.recipe) then v = "cooking"; break end
        end
    end
    waiting.ver, waiting.env, waiting.slot, waiting.lot, waiting.v = rt.objVer, rt.env, slot, world.lot, v
    return v
end

I.eat_leftovers = {
    label = "Eat Leftovers", category = "Food", slot = { "front", "use" }, pose = "use", dur = 1.5, ages = { adult = true, child = true },
    estimate = function() return FT.eatMinutes + 3 end,
    test = function(world, actor, obj)
        if actor.held then return false, "Hands are full." end
        if not freshStock(world, obj) then return false, "No leftovers in the fridge." end
        return true
    end,
    advertise = function(world, actor, obj)
        local e = freshStock(world, obj)
        if not e then return nil end
        local hunger, fun = C.Portion(e.recipe, (e.q or 0.5) * FT.leftoverQ)
        return A.Advert("c1520", "hunger", hunger, "fun", math.max(0, fun))
    end,
    onEnd = function(world, actor, act, obj, status)
        if not act.performed or not obj then return end
        local e, n = freshStock(world, obj)
        if not e then act.failWhy = "The leftovers are gone."; return end
        e.servings = e.servings - 1
        if e.servings <= 0 then table.remove(obj.stock, n) end
        C.Hold(world, actor, "plate", { recipe = e.recipe, q = (e.q or 0.5) * FT.leftoverQ, left = 1, madeAt = world.time })
    end,
    next = function(world, actor) if held(actor, "plate") then return C.EatOrder(world, actor) end end,
}

I.clean_fridge = {
    label = "Throw Out Spoiled Food", category = "Chores", slot = { "front", "use" }, pose = "clean", dur = 2, chore = true, noWear = true,
    traits = { neat = 1 }, householdOnly = true, service = true, ages = { adult = true, child = true },
    test = function(world, actor, obj)
        if actor.held then return false, "Hands are full." end
        for _, e in ipairs(obj.stock or {}) do if e.spoiled then return true end end
        return false, "Nothing has gone off."
    end,
    advertise = function(world, actor, obj)
        for _, e in ipairs(obj.stock or {}) do if e.spoiled then return A.Advert("c1542", "room", 22) end end
        return nil
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj then return end
        local units = 0
        for n = #(obj.stock or {}), 1, -1 do
            if obj.stock[n].spoiled then units = units + 1; table.remove(obj.stock, n) end
        end
        obj.state = obj.state or {}
        obj.state.spoiled = nil
        SS.Emit("lotChanged", "state", obj.id)
        if units > 0 then C.Hold(world, actor, "scraps", { units = units }) end
    end,
    next = function(world, actor) if held(actor, "scraps") then return C.DisposeOrder(world, actor) end end,
}

-- Dishes -----------------------------------------------------------------------------------
I.clear_plate = {
    -- keepHeld: a clear that fails (someone else took the dish first) keeps the stack already
    -- carried; it goes on to the sink instead of back on the table (social's HC-13 livelock)
    usesHeld = { dirty = true }, keepHeld = true,
    label = "Clear Dishes", category = "Chores", slot = "around", pose = "clean", dur = 0.5, chore = "dishes", noWear = true,
    traits = { neat = 1.2 }, guestForbidden = true, service = true, ages = { adult = true, child = true },
    test = function(world, actor, obj)
        local h = actor.held
        if h and not (h.kind == "dirty" and (h.count or 1) + (obj.count or 1) <= 6) then return false, "Hands are full." end
        return true
    end,
    advertise = function(world, actor, obj) return A.Advert("c1569", "room", 10 + 4 * (obj.count or 1)) end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not obj or not world.lot.objects[obj.id] then return end
        local n = obj.count or 1
        C.GrumbleAbout(world, actor, obj)
        act.removing = true
        M.Remove(world, obj)
        local h = held(actor, "dirty")
        if h then h.count = (h.count or 1) + n; actor.carry = C.PropFor(h)
        else C.Hold(world, actor, "dirty", { count = n }) end
    end,
    next = function(world, actor)
        local h = held(actor, "dirty")
        if not h then return nil end
        -- gather another nearby dirty dish before heading to the sink
        if (h.count or 1) < 4 then
            local best, bestD
            for _, oid in ipairs(W.ObjectIds(world)) do
                local o = world.lot.objects[oid]
                if o and o.def == "plate_dirty" and level(o) == (actor.level or 0) then
                    local d = distTo(actor, o)
                    if d <= 5 and (not bestD or d < bestD) and A.Available(world, actor, o, "clear_plate") then best, bestD = o, d end
                end
            end
            if best then return { oid = best.id, iid = "clear_plate" } end
        end
        return C.DishOrder(world, actor)
    end,
}

I.wash_dishes = {
    usesHeld = { dirty = true, cup = true },
    label = "Wash Dishes", category = "Chores", slot = { "front", "use" }, pose = "wash", chore = true,
    useTags = { "sink", "basin" }, householdOnly = true, service = true, ages = { adult = true, child = true },
    traits = { neat = 0.6 },
    test = function(world, actor)
        local h = actor.held
        if not h or (h.kind ~= "dirty" and h.kind ~= "cup") then return false, "No dirty dishes in hand." end
        return true
    end,
    onStart = function(world, actor, act, obj)
        local h = actor.held
        act.dur = FT.washPerPlate * (h and h.count or 1) / C.Speed(obj)
        act.rates = M.NeatRates(actor, { hygiene = -3 })
    end,
    onResume = function(world, actor, act) act.rates = M.NeatRates(actor, { hygiene = -3 }) end,
    onEnd = function(world, actor, act, obj, status)
        if status == "done" then C.Drop(world, actor) end
    end,
}

I.load_dishwasher = {
    usesHeld = { dirty = true, cup = true },
    label = "Load Dishwasher", category = "Chores", slot = { "front", "use" }, pose = "use", dur = 1, chore = true, noWear = true,
    householdOnly = true, service = true, ages = { adult = true, child = true },
    test = function(world, actor, obj)
        local h = actor.held
        if not h or (h.kind ~= "dirty" and h.kind ~= "cup") then return false, "No dirty dishes in hand." end
        if obj.state and obj.state.on then return false, "It's running." end
        if (obj.load or 0) >= C.DishwasherCap(obj) then return false, "It's full." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        local h = actor.held
        if status ~= "done" or not h or not obj then return end
        local cap = C.DishwasherCap(obj)
        local n = math.min(h.count or 1, cap - (obj.load or 0))
        obj.load = (obj.load or 0) + n
        h.count = (h.count or 1) - n
        if h.count <= 0 then C.Drop(world, actor) else actor.carry = C.PropFor(h) end
        if obj.load >= cap then C.RunDishwasher(world, obj) end
    end,
    next = function(world, actor) if actor.held then return C.DishOrder(world, actor) end end,
}

I.run_dishwasher = {
    label = "Run Dishwasher", category = "Chores", slot = { "front", "use" }, pose = "use", dur = 0.3, noWear = true,
    householdOnly = true, service = true, ages = { adult = true, child = true },
    test = function(world, actor, obj)
        if obj.state and obj.state.on then return false, "It's already running." end
        if (obj.load or 0) <= 0 then return false, "It's empty." end
        return true
    end,
    advertise = function(world, actor, obj)
        if (obj.load or 0) >= C.DishwasherCap(obj) * 0.5 and not (obj.state and obj.state.on) then return A.Advert("c1653", "room", 14) end
    end,
    onEnd = function(world, actor, act, obj, status) if status == "done" and obj then C.RunDishwasher(world, obj) end end,
}

-- The catalogue's quality.speed on the cooker, counter, sink, coffee maker or dishwasher used (its
-- HC-3): work there goes this many times as fast (1 = an ordinary one; missing or not positive = 1).
function C.Speed(obj)
    local def = obj and SS.Objects[obj.def]
    local sp = def and def.quality and def.quality.speed
    if type(sp) == "number" and sp > 0 then return sp end
    return 1
end

function C.DishwasherCap(o)
    local def = SS.Objects[o.def]
    return def and def.quality and def.quality.capacity or FT.dishwasherCap
end

function C.RunDishwasher(world, o)
    o.state = o.state or {}
    o.state.on = true
    o.runUntil = world.time + FT.dishwasherMinutes / C.Speed(o)
    SS.Emit("lotChanged", "state", o.id)
end

-- Rubbish ------------------------------------------------------------------------------------
I.throw_away = {
    usesHeld = { scraps = true, trash = true, burnt = true, plate = true, dish = true, ingredients = true, prepared = true },
    label = "Throw Away", category = "Chores", hidden = true, slot = { "front", "use" }, pose = "use", dur = 0.5, noWear = true,
    useTags = { "bin", "bin_outdoor" }, ages = { adult = true, child = true },
    test = function(world, actor)
        local h = actor.held
        if not h or not (h.kind == "scraps" or h.kind == "trash" or h.kind == "burnt" or C.FOOD_KINDS[h.kind]) then return false, "Nothing to throw away." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        local h = actor.held
        if status ~= "done" or not h or not obj then return end
        local units = h.units or math.max(1, math.ceil((h.servings or 1) / 2))
        M.AddToBin(world, obj, units)
        if h.container or h.kind == "burnt" or h.kind == "plate" or h.kind == "dish" then
            C.Hold(world, actor, "dirty", { count = 1 })
        else
            C.Drop(world, actor)
        end
    end,
    next = function(world, actor) if held(actor, "dirty") then return C.DishOrder(world, actor) end end,
}

-- No bin anywhere: the rubbish goes on the floor (a pile that lowers the room score).
I.drop_trash = {
    usesHeld = { scraps = true, trash = true, burnt = true, plate = true, dish = true, ingredients = true, prepared = true, bag = true },
    label = "Drop Rubbish", category = "Chores", hidden = true, slot = "here", pose = "use", dur = 0.3, ages = { adult = true, child = true },
    onEnd = function(world, actor, act, obj, status)
        local h = actor.held
        if status ~= "done" or not h then return end
        M.SpawnTrash(world, actor.level or 0, math.floor(actor.x), math.floor(actor.y), h.units or 1)
        if isMember(world, actor) then A.Message(world, actor, "There's no bin, so the rubbish went on the floor.", "trash") end
        if h.container or h.kind == "burnt" then C.Hold(world, actor, "dirty", { count = 1 }) else C.Drop(world, actor) end
    end,
    next = function(world, actor) if held(actor, "dirty") then return C.DishOrder(world, actor) end end,
}

-- Drinks -----------------------------------------------------------------------------------
local function drinkFor(obj)
    local def = obj and SS.Objects[obj.def]
    if def and SS.Tags.Has(def, "coffee") then return "coffee" end
    if def and SS.Tags.Has(def, "fridge") then return "juice" end
    return "water"
end
C.DrinkFor = drinkFor

I.grab_drink = {
    label = "Pour a Drink", category = "Food", slot = { "front", "use" }, pose = "use", dur = 1, ages = { adult = true, child = true },
    ledgerCat = "food",
    costFn = function(world, actor, obj, data)
        local d = F.drinks[(data and data.drink) or drinkFor(obj)]
        return d and d.cost or 0, "Groceries: " .. (d and d.name or "drink")
    end,
    test = function(world, actor, obj, data)
        if actor.held then return false, "Hands are full." end
        local id = (data and data.drink) or drinkFor(obj)
        if id == "coffee" and (actor.age or "adult") == "child" then return false, "Coffee is for grown-ups." end
        return true
    end,
    advertise = function(world, actor, obj)
        local id = drinkFor(obj)
        local d = F.drinks[id]
        local h = hourOf(world)
        if id == "coffee" and h >= 5 and h < 12 and (actor.age or "adult") ~= "child" then return A.Advert("c1734", "energy", d.energy, "fun", d.fun) end
        if id == "juice" then return A.Advert("c1735", "fun", d.fun * 2, "hunger", d.hunger) end
        return nil
    end,
    onStart = function(world, actor, act, obj)
        act.data.drink = act.data.drink or drinkFor(obj)
        act.dur = I.grab_drink.dur / C.Speed(obj)
    end,
    onEnd = function(world, actor, act, obj, status)
        if not act.performed or actor.held then return end
        C.Hold(world, actor, "drink", { drink = act.data.drink or drinkFor(obj) })
    end,
    next = function(world, actor) if held(actor, "drink") then return { iid = "drink_held" } end end,
}

I.make_coffee = {
    label = "Make Coffee", category = "Food", slot = { "front", "use" }, pose = "use", dur = 3, noise = 1,
    ages = { adult = true }, ledgerCat = "food", cost = F.drinks.coffee.cost, ledger = "Groceries: coffee",
    test = function(world, actor) if actor.held then return false, "Hands are full." end return true end,
    onStart = function(world, actor, act, obj) act.dur = I.make_coffee.dur / C.Speed(obj) end,
    advertise = function(world, actor, obj)
        local h = hourOf(world)
        if h >= 5 and h < 13 then return A.Advert("c1752", "energy", F.drinks.coffee.energy, "fun", F.drinks.coffee.fun) end
        return A.Advert("c1753", "energy", F.drinks.coffee.energy * 0.5)
    end,
    onEnd = function(world, actor, act, obj, status)
        if not act.performed or actor.held then return end
        C.Hold(world, actor, "drink", { drink = "coffee" })
    end,
    next = function(world, actor) if held(actor, "drink") then return { iid = "drink_held" } end end,
}

I.drink_held = {
    usesHeld = { drink = true },
    label = "Drink", category = "Food", hidden = true, slot = "here", pose = "eat_stand", ages = { adult = true, child = true },
    test = function(world, actor) if not held(actor, "drink") then return false, "Nothing to drink." end return true end,
    onStart = function(world, actor, act)
        local h = held(actor, "drink")
        local d = F.drinks[h.drink] or F.drinks.water
        act.data.gain = { bladder = d.bladder, fun = d.fun, energy = d.energy, hunger = d.hunger }
        act.gain = act.data.gain
        act.dur = d.minutes
        actor.carry = "cup"
    end,
    onResume = function(world, actor, act) act.gain = act.data.gain; actor.carry = "cup" end,
    onEnd = function(world, actor, act, obj, status)
        local h = held(actor, "drink")
        if not h or status ~= "done" then return end
        h.kind, h.drink, h.count = "cup", nil, 1
        local neat = actor.personality and actor.personality.neat or 5
        if C.WillTidy(world, actor, "dishes", FT.tidy.base + FT.tidy.perNeat * neat, "tidy") then act.data.tidy = true
        else C.SettleHeld(world, actor, "left") end
    end,
    next = function(world, actor, act)
        if act.data.tidy and held(actor, "cup") then
            local o = C.DishOrder(world, actor)
            if o then o.optional = true; return o end
        end
    end,
}

-- Snack: a quick bite standing at the fridge; messy people leave the wrapper behind. Less than
-- the smallest cooked portion, and each snack soon after another fills less (the factor is fixed
-- when the snack starts and kept through a reload), so clicking the fridge is never a refill.
local function snackFactor(world, actor) return SS.Needs.RepFactor(world, actor, "snack", FT.snackRepeat) end
C.SnackFactor = snackFactor
I.snack.gain = { hunger = F.snack.hunger, bladder = -4 }
I.snack.advert = { hunger = F.snack.hunger }
I.snack.advertise = function(world, actor) return A.Advert("c1798", "hunger", F.snack.hunger * snackFactor(world, actor)) end
I.snack.onStart = function(world, actor, act)
    act.data.snackMult = act.data.snackMult or snackFactor(world, actor)
    act.mult = { hunger = act.data.snackMult }
end
I.snack.onResume = function(world, actor, act)
    act.mult = { hunger = act.data.snackMult or 1 }
end
I.snack.onEnd = function(world, actor, act, obj, status)
    if not act.performed then return end
    -- what was eaten counts towards the next snack (a snack cut short counts for its share)
    local dur = act.dur or I.snack.dur
    SS.Needs.RepAdd(world, actor, "snack", math.min(1, (act.t or 0) / math.max(1, dur)), FT.snackRepeat)
    if status ~= "done" or not isMember(world, actor) then return end
    local neat = actor.personality and actor.personality.neat or 5
    if SS.Random(world, "tidy") < (10 - neat) * 0.03 then
        M.SpawnClutter(world, actor.level or 0, math.floor(actor.x), math.floor(actor.y), "wrapper")
    end
end

-- Sleep and waking ----------------------------------------------------------------------------
C.WAKE_TEXT = {
    alarm = "The alarm went off.", noise = "Woken up by the noise.", emergency = "Woken by the commotion!",
    work = "Time to get up for work.", school = "Time to get up for school.", player = "Woken up.",
    infant_cry = "Woken by the baby crying.", doorbell = "Woken by the doorbell.", phone = "Woken by the phone.",
}

-- Wake a sleeper. status "done" (a proper wake-up: alarm, work, school) lets the morning
-- routine follow (making the bed); anything else is an interrupted sleep.
function C.WakeUp(world, actor, why, status)
    local act = actor.act
    local ia = act and I[act.iid]
    if not (act and ia and ia.sleeping and act.phase == "perform") then return false end
    if act.iid == "collapse" and why ~= "emergency" then return false end
    act.data.wokeBy = why
    A.Interrupt(world, actor, C.WAKE_TEXT[why] or why, status or "interrupted")
    -- a proper wake-up (alarm, work, school) means getting up: no going back to bed for a while
    -- unless exhausted (Tuning.stayUpAfterWake); a noise or a crying baby is only an interruption
    if (status or "interrupted") == "done" then
        actor.tmp = actor.tmp or {}
        actor.tmp.upUntil = world.time + T.stayUpAfterWake
    end
    -- up for work or school: a quick breakfast before the ride (Tuning.breakfast; Actions.Score)
    if why == "work" or why == "school" then C.GetReady(world, actor) end
    SS.Emit("wokeUp", world, actor, why)
    return true
end

-- Public: this person has to leave at `leaveAt` (the carpool, the school bus). If hungry, food that
-- is done by then comes first and longer cooking is put off (Tuning.breakfast). Called on a work or
-- school wake-up; careers and school may call it for someone who is already up. Returns true when
-- the plan was set.
function C.GetReady(world, actor, leaveAt)
    if not (actor and actor.needs) or (actor.needs.hunger or 0) >= T.breakfast.below then return false end
    actor.tmp = actor.tmp or {}
    actor.tmp.plan = { kind = "breakfast", untilT = leaveAt or (world.time + T.breakfast.window) }
    return true
end

-- Public: careers/school/visitors ask for someone to be woken (e.g. the carpool is coming).
function C.RequestWake(world, actor, why) return C.WakeUp(world, actor, why or "work", "done") end

local function alarmNoiseAt(world, lv, i, j)
    local total = 0
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        if o and o.state and o.state.ringing and level(o) == lv then
            local d = math.abs(o.x - i) + math.abs(o.y - j)
            if d <= T.noiseRadius then
                local v = T.alarmNoise * (1 - d / (T.noiseRadius + 1))
                if W.RoomAt(world, lv, o.x, o.y) ~= W.RoomAt(world, lv, i, j) then v = v * T.noiseWall end
                total = total + v
            end
        end
    end
    return total
end
C.AlarmNoiseAt = alarmNoiseAt

local function sleepTick(world, actor, act, obj, dt)
    local data = act.data
    if (data.noiseAt or 0) > world.time then return end
    data.noiseAt = world.time + T.noiseCheck
    local lv = actor.level or 0
    local i, j = math.floor(actor.x), math.floor(actor.y)
    local alarm = alarmNoiseAt(world, lv, i, j)
    local e = actor.needs.energy or 0
    if alarm >= 2 and e > T.alarmSleepThrough then
        C.WakeUp(world, actor, "alarm", "done")
        return
    end
    local noise = W.NoiseAt(world, lv, i, j, actor.id) - alarm
    act.mult = act.mult or {}
    act.mult.energy = math.max(0.4, 1 - T.noisePenalty * math.max(0, noise))
    data.noise = noise
    if noise >= T.noiseWake and e > T.noiseWakeMinEnergy then
        C.WakeUp(world, actor, "noise", "interrupted")
    end
end

-- Sleeping places per bed: slots in the "bed" group (a double bed has two), else one.
local function bedSides(def)
    local n = 0
    for name, sl in pairs(def and def.slots or {}) do
        if sl.group == "bed" or name == "bed" then n = n + 1 end
    end
    return math.max(1, n)
end
C.BedSides = bedSides

-- How strongly this bed belongs to someone else in the household: 1 = free to take,
-- lower when other members already sleep there and no side is left for this actor.
function C.BedClaim(world, actor, obj)
    if not obj or actor.bed == obj.id then return 1 end
    local others = 0
    for _, id in ipairs(world.household and world.household.members or {}) do
        local m = world.root.residents[id]
        if m and m ~= actor and m.bed == obj.id and not m.dead then others = others + 1 end
    end
    if others >= bedSides(SS.Objects[obj.def]) then return T.bedClaimed end
    return 1
end

local function sleepAdvert(world, actor, obj, base, napOnly)
    local def = obj and SS.Objects[obj.def]
    local childBed = def and SS.Tags.Has(def, "bed_child")
    local child = (actor.age or "adult") == "child"
    if childBed and not child then return nil end
    local night = isNight(world)
    local e = actor.needs.energy or 0
    if napOnly then
        if night or e > T.napMaxEnergy then return nil end
        return A.Advert("c1930", "energy", base, "comfort", 8)
    end
    -- just got up for the alarm, work or school: bed waits (unless exhausted)
    local up = actor.tmp and actor.tmp.upUntil
    if up and up > world.time and e > (T.critical.energy or -80) then return nil end
    local mult = night and T.sleepNight or T.sleepDay
    if not night and e > T.napMaxEnergy then mult = mult * 0.5 end
    -- eat first: bed on an empty stomach means waking hungry (unless too exhausted to care)
    if (actor.needs.hunger or 0) <= (T.warn.hunger or -20) and e > (T.critical.energy or -80) then mult = mult * T.sleepHungry end
    if actor.bed == (obj and obj.id) then mult = mult * T.ownBed end
    if child and childBed then mult = mult * T.childBedPref end
    mult = mult * C.BedClaim(world, actor, obj)
    return A.Advert("c1942", "energy", base * mult, "comfort", 10)
end

local function bedTest(world, actor, obj)
    local def = obj and SS.Objects[obj.def]
    if def and SS.Tags.Has(def, "bed_child") and (actor.age or "adult") ~= "child" then return false, "That bed is too small." end
    return true
end

I.sleep.test = bedTest
I.sleep.advertise = function(world, actor, obj) return sleepAdvert(world, actor, obj, 70) end
I.sleep.onStart = function(world, actor, act, obj)
    act.data.night = isNight(world)
    act.data.noiseAt = world.time + 1
    actor.bed = obj and obj.id or actor.bed
    if obj then
        obj.state = obj.state or {}
        obj.state.unmade = true
        SS.Emit("lotChanged", "state", obj.id)
    end
end
I.sleep.onTick = sleepTick
-- Woken in the night by something that is only an interruption (a need, a noise, the baby, the
-- doorbell or phone, the player): back to bed once it is dealt with. Not after an alarm, work,
-- school or an emergency. Runtime only (actor.tmp.backToBed): a reload forgets it.
local BACK_TO_BED = { noise = true, infant_cry = true, doorbell = true, phone = true, player = true }
local function nightEndAfter(t)
    local day = math.floor(t / 1440)
    if t % 1440 >= T.nightStart then day = day + 1 end
    return day * 1440 + T.nightEnd
end
C.NightEndAfter = nightEndAfter

-- Called by the executor when this person is about to choose something: while the night lasts,
-- with no need pressing (below Tuning.urgent) and the bed quiet enough to sleep in, queue sleep in
-- that bed. Returns true when it queued it. Stops trying Tuning.backToBedMin before the night's end.
function C.BackToBed(world, actor)
    local bb = actor.tmp and actor.tmp.backToBed
    if not bb then return false end
    if world.time >= bb.untilT - (T.backToBedMin or 0) or not isNight(world) then actor.tmp.backToBed = nil; return false end
    for _, need in ipairs(T.needs) do
        if need ~= "room" and need ~= "social" and need ~= "fun" and need ~= "comfort" and need ~= "energy"
            and (actor.needs[need] or 0) < T.urgent then return false end
    end
    local bed = world.lot.objects[bb.oid]
    if not bed then actor.tmp.backToBed = nil; return false end
    if W.NoiseAt(world, level(bed), bed.x, bed.y, actor.id) >= T.noiseWake then return false end
    if not A.Available(world, actor, bed, "sleep") then return false end
    actor.tmp.backToBed = nil
    actor.queue = actor.queue or {}
    table.insert(actor.queue, { oid = bed.id, iid = "sleep", manual = false, quiet = true })
    if A.SyncOrders then A.SyncOrders(actor) end
    return true
end

I.sleep.onEnd = function(world, actor, act, obj, status)
    if not act.performed then return end
    local woke = act.data.wokeBy
    if status ~= "done" and obj and isMember(world, actor) and isNight(world) and woke and (BACK_TO_BED[woke] or T.needLabel[woke]) then
        actor.tmp = actor.tmp or {}
        actor.tmp.backToBed = { oid = obj.id, untilT = nightEndAfter(world.time) }
    end
    if act.data.wokeBy and (actor.needs.energy or 0) < T.groggyBelow then SS.Needs.Feel(world, actor, "groggy") end
    if status == "done" and isMember(world, actor) then
        local neat = actor.personality and actor.personality.neat or 5
        if C.WillTidy(world, actor, "bed", T.makeBed.base + T.makeBed.perNeat * neat, "tidy") then act.data.makeBed = true end
    end
end
I.sleep.next = function(world, actor, act, obj)
    if act.data.makeBed and obj and obj.state and obj.state.unmade then return { oid = obj.id, iid = "make_bed", optional = true } end
end

I.nap.test = bedTest
I.nap.advertise = function(world, actor, obj) return sleepAdvert(world, actor, obj, 30, true) end
I.nap.onStart = function(world, actor, act) act.data.noiseAt = world.time + 1 end
I.nap.onTick = sleepTick
I.nap.onEnd = function(world, actor, act)
    if act.performed and act.data.wokeBy and (actor.needs.energy or 0) < T.groggyBelow then SS.Needs.Feel(world, actor, "groggy") end
end

I.sofa_nap.advertise = function(world, actor, obj) return sleepAdvert(world, actor, obj, 18, true) end
I.sofa_nap.onStart = I.nap.onStart
I.sofa_nap.onTick = sleepTick
I.sofa_nap.onEnd = I.nap.onEnd

I.relax_bed.test = bedTest

I.make_bed.advertise = function(world, actor, obj)
    local neat = actor.personality and actor.personality.neat or 5
    if neat < 4 then return nil end
    return A.Advert("c1994", "room", 6 + neat * 1.5)
end
I.make_bed.onEnd = function(world, actor, act, obj, status)
    if status == "done" and obj and obj.state then
        obj.state.unmade = nil
        SS.Emit("lotChanged", "state", obj.id)
        W.Touch()
    end
end

-- Alarm clocks: obj.alarm = { at = minute of day, on = bool } (saved). Ringing is loud; it
-- wakes sleepers who can hear it unless they are exhausted (Tuning.alarmSleepThrough).
I.set_alarm.onEnd = function(world, actor, act, obj, status)
    if status ~= "done" or not obj then return end
    local at = act.data.at or T.alarmDefault
    obj.alarm = { at = at % 1440, on = true }
    A.Message(world, actor, "Alarm set for " .. C.ClockText(at) .. ".", "clock")
end
I.alarm_off.test = function(world, actor, obj)
    if obj.state and obj.state.ringing then return true end
    if obj.alarm and obj.alarm.on then return true end
    return false, "No alarm is set."
end
I.alarm_off.advertise = function(world, actor, obj)
    if obj.state and obj.state.ringing and not actor.sleeping then return A.Advert("c2018", "comfort", 20, "room", 20) end
end
I.alarm_off.onEnd = function(world, actor, act, obj, status)
    if status ~= "done" or not obj then return end
    if obj.state and obj.state.ringing then
        obj.state.ringing = nil
        obj.ringUntil = nil
    elseif obj.alarm then
        obj.alarm.on = false
        A.Message(world, actor, "Alarm switched off.", "clock")
    end
    SS.Emit("lotChanged", "state", obj.id)
end

function C.ClockText(minutes)
    local m = math.floor(minutes % 1440)
    local h, mm = math.floor(m / 60), m % 60
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d %s", h12, mm, h < 12 and "AM" or "PM")
end

-- Wake sleepers for emergencies (fire, burglary...). Events module emits `emergency`.
SS.On("emergency", function(text, severity, world)
    world = world or (SS.Sim and SS.Sim.world)
    if severity ~= "emergency" or not world or not world.actors then return end
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and a.sleeping then C.WakeUp(world, a, "emergency", "interrupted") end
    end
end)

-- Bathroom ------------------------------------------------------------------------------------
local function maybePuddle(world, actor, act, obj, kind)
    local p = T.puddle[kind] or 0
    if (actor.age or "adult") == "child" then p = p * T.puddle.child end
    if obj and obj.state and obj.state.broken then p = p * 2 end
    if p > 0 and SS.Random(world, "puddle") < p then
        local ap = act.approach or { math.floor(actor.x), math.floor(actor.y), actor.level or 0 }
        M.SpawnPuddle(world, ap[3] or 0, ap[1], ap[2], kind)
    end
end

local function filthyCheck(world, actor, obj)
    if obj and (obj.dirt or 0) >= T.filthyAt and actor.needs and not actor.noNeeds then SS.Needs.Feel(world, actor, "disgusted") end
end

I.toilet.onStart = function(world, actor, act, obj) filthyCheck(world, actor, obj) end
I.toilet.onEnd = function(world, actor, act, obj, status)
    if status ~= "done" or not act.performed then return end
    local neat = actor.personality and actor.personality.neat or 5
    if C.WillTidy(world, actor, "hands", T.handwash.base + T.handwash.perNeat * neat, "handwash") then act.data.wash = true end
end
I.toilet.next = function(world, actor, act)
    if not act.data.wash then return nil end
    local b = C.FindUsable(world, actor, { "basin", "sink" }, "washhands")
    if b then return { oid = b.id, iid = "washhands", optional = true } end
end

-- Running water: state.water = true on the tap or shower while it runs (the model specs draw it).
-- A shower in a bath (bath_shower_combo: the filled tub under `water`, the spray under `on`) runs
-- as state.on instead, so it shows the spray and not a full tub (catalogue's HC-4).
local function waterOn(world, obj, on, spray)
    if not obj then return end
    obj.state = obj.state or {}
    local def = SS.Objects[obj.def]
    if spray and def and SS.Tags.Has(def, "bath") then
        obj.state.on = on or nil
        obj.state.water = nil
    else
        obj.state.water = on or nil
    end
    SS.Emit("lotChanged", "state", obj.id)
end
C.WaterOn = waterOn

I.shower.onStart = function(world, actor, act, obj) filthyCheck(world, actor, obj); waterOn(world, obj, true, true) end
I.shower.onResume = function(world, actor, act, obj) waterOn(world, obj, true, true) end
I.shower.onEnd = function(world, actor, act, obj, status)
    waterOn(world, obj, false, true)
    if not act.performed then return end
    maybePuddle(world, actor, act, obj, "shower")
    if status == "done" and (actor.needs.hygiene or 0) >= 80 then SS.Needs.Feel(world, actor, "refreshed") end
end
I.bathe.onStart = function(world, actor, act, obj) filthyCheck(world, actor, obj); waterOn(world, obj, true) end
I.bathe.onResume = function(world, actor, act, obj) waterOn(world, obj, true) end
-- the tap runs while hands or dishes are washed at a basin or sink
I.washhands.onStart = function(world, actor, act, obj) waterOn(world, obj, true) end
I.washhands.onResume = I.washhands.onStart
I.washhands.onEnd = function(world, actor, act, obj, status) waterOn(world, obj, false) end
do
    local start, resume, stop = I.wash_dishes.onStart, I.wash_dishes.onResume, I.wash_dishes.onEnd
    I.wash_dishes.onStart = function(world, actor, act, obj) start(world, actor, act, obj); waterOn(world, obj, true) end
    I.wash_dishes.onResume = function(world, actor, act, obj) resume(world, actor, act, obj); waterOn(world, obj, true) end
    I.wash_dishes.onEnd = function(world, actor, act, obj, status) waterOn(world, obj, false); stop(world, actor, act, obj, status) end
end
I.bathe.onEnd = function(world, actor, act, obj, status)
    waterOn(world, obj, false)
    if not act.performed then return end
    maybePuddle(world, actor, act, obj, "bath")
    if status == "done" then SS.Needs.Feel(world, actor, "refreshed") end
end

-- Lights: people switch a lamp on when the room they are in is dark.
I.lampon.advertise = function(world, actor, obj)
    local lv = actor.level or 0
    local room = W.RoomAt(world, lv, math.floor(actor.x), math.floor(actor.y))
    if room == 0 or level(obj) ~= lv or W.ObjRoom(world, obj) ~= room then return nil end
    if W.RoomLight(world, lv, room) >= 0.35 then return nil end
    return A.Advert("c2107", "room", 18)
end

-- Tags -------------------------------------------------------------------------------------
for _, t in ipairs({
    { "fridge", { "snack", "cook_meal", "eat_leftovers", "grab_drink", "clean_fridge" } },
    { "stove", { "cook_at", "turn_off_heat" } }, { "oven", { "cook_at", "turn_off_heat" } },
    { "microwave", { "cook_at", "turn_off_heat" } }, { "grill", { "cook_at", "turn_off_heat" } },
    { "toaster", { "cook_at", "turn_off_heat" } }, { "coffee", { "make_coffee" } },
    { "dishwasher", { "run_dishwasher" } }, { "sink", { "wash_dishes", "washhands", "grab_drink" } },
    { "basin", { "washhands" } },
    { "bed", { "sleep", "nap", "relax_bed", "make_bed" } }, { "bed_child", { "sleep", "nap", "relax_bed", "make_bed" } },
    { "toilet", { "toilet" } }, { "shower", { "shower" } }, { "bath", { "bathe" } },
    { "seat", { "sit" } }, { "sofa", { "sit", "sofa_nap" } },
    { "lamp", { "lampon", "lampoff" } }, { "clock_alarm", { "set_alarm", "alarm_off" } },
}) do
    for _, iid in ipairs(t[2]) do SS.Tags.Attach(t[1], iid) end
end

-- Systems ------------------------------------------------------------------------------------
-- Unattended cooking, alarms and dishwashers (checked once per sim minute), spoilage (hourly).
local lastT
local function spoil(world, o)
    if o.spoiled then return end
    o.spoiled = true
    o.state = o.state or {}
    o.state.spoiled = true
    SS.Emit("lotChanged", "state", o.id)
    SS.Emit("foodSpoiled", world, o)
end

-- Processes the window (world.time - dt, world.time].
function C.Minute(world, dt)
    local ids = W.ObjectIds(world)
    local objects = world.lot.objects
    local mod = world.time % 1440
    local prev = (world.time - dt) % 1440
    for n = 1, #ids do
        local o = objects[ids[n]]
        if o then
            if o.def == "food_cooking" then
                local ap = objects[o.appliance or o.parent or ""]
                local cookActive = o.cook and world.actors[o.cook] and world.actors[o.cook].act and world.actors[o.cook].act.data
                    and world.actors[o.cook].act.data.food == o.id
                if not ap then
                    -- the cooker is gone: C.FixOrphans turns the pan into plain food
                elseif not cookActive and ap.cooking == o.id and ap.state and ap.state.on then
                    local r = F.recipes[o.recipe or ""] or {}
                    o.cook = nil
                    if not o.burnt then
                        o.cookDone = (o.cookDone or 0) + dt * C.Speed(ap)
                        if o.burnAt and o.cookDone >= o.burnAt then
                            C.Burn(world, o, ap, nil)
                        elseif o.cookDone >= (o.cookNeed or 0) then
                            if F.autoOff[r.appliance or ""] then
                                o.state.cooking, o.state.cooked = nil, true
                                C.HeatOff(world, ap)
                            else
                                if not o.state.cooked then o.state.cooked = true; SS.Emit("lotChanged", "state", o.id) end
                                if o.cookDone >= (o.cookNeed or 0) + FT.overcook then C.Burn(world, o, ap, nil) end
                            end
                        end
                    elseif SS.Random(world, "cookfire") < 1 - (1 - C.FireChance(o.recipe, SS.Objects[ap.def], true)) ^ (dt / 60) then
                        C.Ignite(world, ap)
                    end
                end
            elseif o.alarm and o.alarm.on then
                local at = o.alarm.at
                local crossed = (prev < mod and at > prev and at <= mod) or (prev > mod and (at > prev or at <= mod))
                if crossed and not (o.state and o.state.broken) then
                    o.state = o.state or {}
                    o.state.ringing = true
                    o.ringUntil = world.time + T.alarmRing
                    SS.Emit("lotChanged", "state", o.id)
                    SS.Emit("alarmRinging", world, o)
                    for _, a in pairs(world.actors) do
                        if a.sleeping and a.act and a.act.data then a.act.data.noiseAt = world.time end
                    end
                end
            end
            -- only a ring with an end time stops here (the alarm clocks rung above, and other
            -- modules' phones, doorbells and alarms that keep ringUntil); a ring without one is
            -- its owner's to stop (visitors' 5c)
            if o.state and o.state.ringing and o.ringUntil and o.ringUntil <= world.time then
                o.state.ringing, o.ringUntil = nil, nil
                SS.Emit("lotChanged", "state", o.id)
            end
            if o.runUntil and o.runUntil <= world.time then
                o.runUntil, o.load = nil, 0
                if o.state then o.state.on = nil end
                SS.Emit("lotChanged", "state", o.id)
                SS.Emit("dishesDone", world, o)
            end
        end
    end
end

function C.Hour(world, h)
    local ids = W.ObjectIds(world)
    local objects = world.lot.objects
    for n = 1, #ids do
        local o = objects[ids[n]]
        if o then
            if (o.def == "food_prep" or o.def == "food_platter" or o.def == "food_plate") and not o.spoiled then
                local r = F.recipes[o.recipe or ""] or {}
                if world.time - (o.madeAt or o.bought or world.time) >= (r.spoilHours or FT.spoilHours) * 60 then spoil(world, o) end
            end
            if o.stock then
                local any = false
                for _, e in ipairs(o.stock) do
                    if not e.spoiled and stockSpoiled(o, e, world) then e.spoiled = true end
                    if e.spoiled then any = true end
                end
                o.state = o.state or {}
                if (o.state.spoiled and true or false) ~= any then o.state.spoiled = any or nil; SS.Emit("lotChanged", "state", o.id) end
            end
        end
    end
end

-- Objects resting on a surface that was sold or moved away drop to the floor.
local orphanCheck = false
SS.On("lotChanged", function(kind) if kind ~= "state" and kind ~= "system" then orphanCheck = true end end)
function C.FixOrphans(world)
    orphanCheck = false
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        local lost = o and ((o.parent and not world.lot.objects[o.parent])
            or (o.def == "food_cooking" and not world.lot.objects[o.appliance or o.parent or ""]))
        if lost then
            o.parent, o.pslot, o.z, o.appliance = nil, nil, nil, nil
            if o.def == "food_cooking" then
                -- the cooker went away mid-cook: the pan is just food now
                o.def = "food_prep"
                o.state.cooking = nil
            end
            local lv = level(o)
            if W.Blocked(world, lv, o.x, o.y) then
                local i, j = SS.Nav.NearestFree(world, lv, o.x, o.y, 3)
                if i then o.x, o.y = i, j end
            end
            W.ObjectsChanged()
        end
    end
end

SS.Sim.Register({
    name = "core.chains", order = 40,
    attach = function(world) lastT = world.time; orphanCheck = true end,
    tick = function(world, dt)
        if orphanCheck then C.FixOrphans(world) end
        if not lastT or lastT > world.time then lastT = world.time end
        if world.time - lastT >= 1 then
            local step = world.time - lastT
            lastT = world.time
            C.Minute(world, step)
        end
    end,
    hour = function(world, h) C.Hour(world, h) end,
})

-- Saved-data validation --------------------------------------------------------------------
local FOOD_DEFS = { food_prep = true, food_cooking = true, food_platter = true, food_plate = true }
SS.Save.RegisterValidator(function(root, problems)
    for id, a in pairs(root.residents or {}) do
        if type(a) == "table" then
            if a.held ~= nil and (type(a.held) ~= "table" or not C.HELD[a.held.kind] or (C.FOOD_KINDS[a.held.kind] and not F.recipes[a.held.recipe or ""])) then
                a.held = nil
                problems[#problems + 1] = "dropped an unreadable carried item for " .. tostring(id)
            end
            if a.carry ~= nil and not A.PROPS[a.carry] then a.carry = nil end
            if a.held then a.carry = C.PropFor(a.held) end
            if a.feel ~= nil then
                if type(a.feel) ~= "table" then a.feel = nil
                else
                    for n = #a.feel, 1, -1 do
                        local f = a.feel[n]
                        if type(f) ~= "table" or not T.feel[f.kind] or type(f.untilT) ~= "number" then table.remove(a.feel, n) end
                    end
                    while #a.feel > T.feelCap do table.remove(a.feel, 1) end
                end
            end
            if a.doing ~= nil and (type(a.doing) ~= "table" or type(a.doing.iid) ~= "string") then a.doing = nil end
            if a.orders ~= nil then
                if type(a.orders) ~= "table" then a.orders = nil
                else
                    for n = #a.orders, 1, -1 do
                        local o = a.orders[n]
                        if type(o) ~= "table" or type(o.iid) ~= "string" then table.remove(a.orders, n) end
                    end
                    while #a.orders > T.maxQueue + 2 do table.remove(a.orders) end
                end
            end
            if a.bed ~= nil and type(a.bed) ~= "string" then a.bed = nil end
        end
    end
    for lotId, lot in pairs(root.hood and root.hood.lots or {}) do
        for oid, o in pairs(lot.objects or {}) do
            if type(o) == "table" then
                if FOOD_DEFS[o.def] and not F.recipes[o.recipe or ""] then
                    lot.objects[oid] = nil
                    problems[#problems + 1] = "removed unreadable food " .. tostring(oid)
                else
                    if o.stock ~= nil then
                        if type(o.stock) ~= "table" then o.stock = nil
                        else
                            for n = #o.stock, 1, -1 do
                                local e = o.stock[n]
                                if type(e) ~= "table" or not F.recipes[e.recipe or ""] then table.remove(o.stock, n) end
                            end
                            -- a fridge with a capacity is limited in servings when food goes in
                            -- (C.FridgeTakes); what a save holds is kept, up to a sane number of dishes
                            local odef = SS.Objects[o.def or ""]
                            local cap = odef and odef.quality and odef.quality.capacity
                            local most = type(cap) == "number" and FT.stockMaxEntries or FT.stockCap
                            while #o.stock > most do table.remove(o.stock, 1) end
                        end
                    end
                    if o.alarm ~= nil and (type(o.alarm) ~= "table" or type(o.alarm.at) ~= "number") then o.alarm = nil end
                    for _, k in ipairs({ "fill", "load", "dirt", "wear", "servings", "left", "count", "units", "repairProgress" }) do
                        if o[k] ~= nil and type(o[k]) ~= "number" then o[k] = nil end
                    end
                end
            end
        end
    end
    return true
end)

-- Menus (UI registry lives in UI/Kit.lua, loaded after the simulation) ------------------------
local menusDone = false
function C.RegisterMenus()
    local UI = SS.UI
    if menusDone or not (UI and UI.RegisterMenu) then return end
    menusDone = true
    UI.RegisterMenu("obj", function(world, actor, oid, entries)
        local o = world and world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if not def or not actor then return end
        local iid
        if SS.Tags.Has(def, "fridge") then iid = "cook_meal"
        else
            for kind in pairs(F.applianceTags) do if C.ApplianceServes(def, kind) then iid = "cook_at" end end
        end
        if iid then
            local sub = {}
            for _, id in ipairs(F.order) do
                local r = F.recipes[id]
                local fits = iid == "cook_meal" or C.ApplianceServes(def, r.appliance)
                if fits then
                    local data = { recipe = id, manual = true }
                    local ok, why = A.Available(world, actor, o, iid, data)
                    sub[#sub + 1] = { label = string.format("%s (%s, serves %d)", r.name, U.fmtMoney(r.cost), r.servings),
                        desc = r.desc .. string.format(" Skill %d. Takes about %d min.", r.skill, math.floor((r.prep + r.cook) * C.SpeedMult(actor) + 0.5)),
                        disabled = not ok, reason = why,
                        onClick = function() A.Order(world, actor, oid, iid, nil, nil, { data = { recipe = id, manual = true } }) end }
                end
            end
            if #sub > 0 then entries[#entries + 1] = { label = "Cook...", order = 5, desc = "Choose a recipe.", submenu = sub } end
        end
        if SS.Tags.Has(def, "clock_alarm") then
            local sub = {}
            for h = 5, 10 do
                sub[#sub + 1] = { label = C.ClockText(h * 60), onClick = function() A.Order(world, actor, oid, "set_alarm", nil, nil, { data = { at = h * 60 } }) end }
            end
            entries[#entries + 1] = { label = "Set Alarm For...", order = 6, submenu = sub }
        end
        if SS.Tags.Has(def, "fridge") or SS.Tags.Has(def, "sink") then
            local d = drinkFor(o)
            local ok, why = A.Available(world, actor, o, "grab_drink", { drink = d })
            entries[#entries + 1] = { label = "Drink: " .. F.drinks[d].name, order = 7, disabled = not ok, reason = why,
                onClick = function() A.Order(world, actor, oid, "grab_drink", nil, nil, { data = { drink = d } }) end }
        end
    end)
    UI.RegisterMenu("self", function(world, actor, ref, entries)
        if not actor or not actor.held then return end
        local h = actor.held
        if h.kind == "plate" then
            entries[#entries + 1] = { label = "Eat", order = 5, onClick = function()
                local o = C.EatOrder(world, actor)
                A.Order(world, actor, o.oid, o.iid, nil, nil, { chain = true })
            end }
        end
        entries[#entries + 1] = { label = "Put It Down", order = 6, desc = "Put down what's in hand.",
            onClick = function() if not actor.act then C.SettleHeld(world, actor, "player") end end,
            disabled = actor.act ~= nil, reason = "Busy right now." }
    end)
end
SS.On("worldAttached", function() C.RegisterMenus() end)

-- The catalogue's requested quality fields household-core reads (its HC-3), declared to it so buy
-- mode shows their ratings (it hides a field nobody reads), each only for the tags where it changes
-- something. speed: cookers, counters, sinks, coffee makers, dishwashers (Chains.Speed); freshness
-- and capacity: fridges; clean: the tags that get dirty with use (Tuning.dirtPerUse, M.DirtRate);
-- skill: the tags an interaction that practises a skill is attached to (Actions.SkillFactor scales
-- the executor's skill gain by the object's factor; a book borrowed from a shelf carries the
-- shelf's), found by C.SkillTags when the declaration runs. A chair's skill factor is read by
-- nothing and stays hidden.
C.READS = { "freshness", "capacity:fridge", "speed:stove", "speed:oven", "speed:microwave", "speed:grill",
    "speed:toaster", "speed:counter", "speed:sink", "speed:coffee", "speed:dishwasher" }
do
    local tags = {}
    for tag in pairs(T.dirtPerUse) do tags[#tags + 1] = tag end
    table.sort(tags)
    for n = 1, #tags do C.READS[#C.READS + 1] = "clean:" .. tags[n] end
end
-- Tags whose attached interactions practise a skill: a fixed `skill` table, or `givesSkill` for the
-- ones that set it when they start (crafts, studying, reading). Sorted.
function C.SkillTags()
    local out = {}
    local map = SS.Tags and SS.Tags.map or {}
    for tag, list in pairs(map) do
        for n = 1, #list do
            local ia = I[list[n]]
            if ia and (type(ia.skill) == "table" or ia.givesSkill) then out[#out + 1] = tag; break end
        end
    end
    table.sort(out)
    return out
end
function C.DeclareReads()
    local cat = SS.Catalog
    if not (cat and cat.SetReader) then return false end
    for n = 1, #C.READS do cat.SetReader(C.READS[n]) end
    local tags = C.SkillTags()
    for n = 1, #tags do cat.SetReader("skill:" .. tags[n]) end
    return true
end
C.DeclareReads()
