-- SideStreet pets: dog and cat behaviour sets (role "pet" drives them through the shared
-- executor), bowls, beds, litter, toys, relieving outside and accidents, human-pet interactions
-- and training (sit, house training), visitor greetings and barking, adoption from the pet shop or
-- the shelter with naming, the declared actor budget (2 per household), neglect (the shelter
-- collects a starving pet) and the aquarium / small-animal enclosure.
-- Owner: family module. Data: Data/Pets.lua (SS.PetData).
--
-- Saved: person.kind = "dog" | "cat", person.decay, person.role = "pet", person.pet = { species,
--   breed, coat, pattern, traits, training = { sit, house }, owner, source, adoptedAt, named,
--   lastMess, lastGood, critMin, warned, nap }.  Object states: pet_bowl { portions, stocked },
--   litter { dirt, dirty, full }, aquarium { fish, fedAt, dirt, dirty, hungry, empty, lossAt }.
-- Runtime only: person.pet.busy / plan / greet cool-downs live under actor.tmp.
local _, SS = ...
local U = SS.U
local W = SS.World
local F = SS.Family
local FD = SS.FamilyData
local PD = SS.PetData
local PC, PB = PD.care, PD.behaviour
local P = {}
SS.Pets = P

local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

function P.State(a)
    if type(a.pet) ~= "table" then a.pet = {} end
    local pt = a.pet
    pt.training = type(pt.training) == "table" and pt.training or { sit = 0, house = 0 }
    pt.traits = type(pt.traits) == "table" and pt.traits or { friendly = 5, active = 5, smart = 5, playful = 5 }
    pt.species = pt.species or a.kind
    return pt
end

local function tmp(a)
    a.tmp = a.tmp or {}
    return a.tmp
end

function P.Species(a) return PD.species[a.kind] end

function P.PickName(world, species, hh)
    local pool = PD.names[species] or PD.names.dog
    local used = {}
    for _, r in ipairs(F.Members(world, hh)) do used[r.name] = true end
    local start = SS.RandomInt(world, "pets", 1, #pool)
    for k = 0, #pool - 1 do
        local n = pool[(start + k - 1) % #pool + 1]
        if not used[n] then return n end
    end
    return pool[start]
end

-- Validate a player-chosen name: trimmed, 1..nameMax printable characters.
function P.CleanName(name)
    if type(name) ~= "string" then return nil, "Type a name first." end
    name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    name = name:gsub("[%c|]", "")
    if #name == 0 then return nil, "Type a name first." end
    if #name > PD.nameMax then return nil, "Names can be at most " .. PD.nameMax .. " characters." end
    return name
end

function P.Rename(world, pet, name)
    local clean, why = P.CleanName(name)
    if not clean then return false, why end
    local old = pet.name
    pet.name = clean
    P.State(pet).named = true
    if old ~= clean then F.Journal(world, old .. " is now called " .. clean .. ".") end
    SS.Emit("petRenamed", world, pet, old)
    return true
end

-- A new animal (not yet in a household). spec = { species, breed?, coat?, pattern?, name?, source? }
function P.NewPet(world, spec)
    local root = F.Root(world)
    local species = spec.species
    local sp = PD.species[species]
    assert(sp, "SideStreet: unknown pet species " .. tostring(species))
    local breedId = spec.breed or F.Pick(world, "pets", sortedKeys(PD.breeds[species]))
    local b = PD.breeds[species][breedId]
    local coat = spec.coat or F.Pick(world, "pets", b.coats)
    local pattern = spec.pattern or F.Pick(world, "pets", b.patterns)
    local traits = {}
    for _, k in ipairs({ "friendly", "active", "smart", "playful" }) do
        traits[k] = U.clamp(b.traits[k] + SS.RandomInt(world, "pets", -2, 2), 0, 10)
    end
    local col = PD.coats[coat] or PD.coats.tan
    local id = F.NewId(world, "r_pet")
    local p = {
        id = id, name = spec.name or P.PickName(world, species), kind = species, age = "adult",
        pronoun = SS.Random(world, "pets") < 0.5 and "she" or "he",
        householdId = nil, lotId = nil, x = 0.5, y = 0.5, level = 0, facing = 0,
        look = { skin = col[1], hair = col[2], top = col[1], bottom = col[1], shoes = col[2], hairStyle = "short",
            species = species, breed = breedId, coat = coat, pattern = pattern, size = b.size, ears = b.ears, tail = b.tail },
        needs = { hunger = 50, energy = 60, bladder = 60, hygiene = 70, fun = 40, social = 40, comfort = 50, room = 0 },
        personality = { neat = 5, outgoing = traits.friendly, active = traits.active, playful = traits.playful, nice = traits.friendly },
        skills = {}, interests = {}, memories = {},
        decay = { awake = U.deepcopy(sp.decayAwake), sleep = U.deepcopy(sp.decaySleep) },
        role = "pet", roleData = {},
        bio = "A " .. string.lower(b.name) .. " (" .. string.gsub(coat, "_", " ") .. ").",
        pet = { species = species, breed = breedId, coat = coat, pattern = pattern, traits = traits,
            training = { sit = sp.startTraining.sit, house = sp.startTraining.house },
            source = spec.source, named = spec.name ~= nil, bornAt = root.time },
    }
    root.residents[id] = p
    return p
end

function P.Setup(world, a)
    local sp = P.Species(a)
    if not sp or F.ForeignRole(a, "pet") then return end
    a.decay = a.decay or { awake = U.deepcopy(sp.decayAwake), sleep = U.deepcopy(sp.decaySleep) }
    if not F.StreetWalking(a) then
        a.role = "pet"
        a.roleData = type(a.roleData) == "table" and a.roleData or {}
    end
    a.noNeeds = nil
    P.State(a)
end

-- Put a pet on the session lot near (i, j).
function P.Place(world, pet, i, j)
    P.Setup(world, pet)
    local ci, cj = F.FreeCellNear(world, 0, i, j, 8, { notDoor = true })
    if not ci then ci, cj = SS.Street.EntryCell(world) end
    pet.away = nil
    local a = SS.Sim.AddActor(world, pet.id, ci, cj, 0)
    if a then a.role = "pet" end
    return a
end

function P.Detach(world, a)
    if not F.IsPet(a) then return end
    local t = a.tmp
    if t then t.busy, t.plan = nil, nil end
    if a.pet then a.pet.nap = nil end
end

---------------------------------------------------------------------------
-- Objects the pets use
---------------------------------------------------------------------------
-- Nearest object of `list` (a shared tag-index list) passing pred(world, a, o). The predicates are
-- plain functions, so a pet's per-step checks create no closures.
local function nearest(world, a, list, pred)
    local best, bestD
    for n = 1, #list do
        local o = list[n]
        if not pred or pred(world, a, o) then
            local d = math.abs(o.x + 0.5 - a.x) + math.abs(o.y + 0.5 - a.y) + math.abs((o.level or 0) - (a.level or 0)) * 6
            if not bestD or d < bestD then best, bestD = o, d end
        end
    end
    return best
end

local function reachable(world, a, o, slot)
    local cool = a.cool and a.cool[o.id .. ":" .. slot]
    return not cool or cool <= world.time
end

local function bowlOk(world, a, o)
    return o.state and (o.state.portions or 0) > 0 and reachable(world, a, o, "pet_eat")
        and not (o.res and o.res.front and o.res.front ~= a.id)
end
local function bedOk(world, a, o)
    return not (o.res and o.res.petbed and o.res.petbed ~= a.id) and reachable(world, a, o, "pet_bed_sleep")
end
local function litterOk(world, a, o)
    return (o.state and o.state.dirt or 0) < PC.litterFullAt and not (o.res and o.res.tray and o.res.tray ~= a.id)
        and reachable(world, a, o, "pet_use_litter")
end
local function toyOk(world, a, o)
    return not (o.res and o.res.front and o.res.front ~= a.id) and reachable(world, a, o, "pet_toy_play")
end

function P.BowlWithFood(world, a) return nearest(world, a, F.ObjectsWithTag(world, "pet_bowl"), bowlOk) end
function P.FreeBed(world, a) return nearest(world, a, F.ObjectsWithTag(world, "pet_bed"), bedOk) end
function P.UsableLitter(world, a) return nearest(world, a, F.ObjectsWithTag(world, "litter"), litterOk) end
function P.FreeToy(world, a) return nearest(world, a, F.ObjectsWithTag(world, "pet_toy"), toyOk) end

function P.Messes(world)
    local out = {}
    for id, o in pairs(world.lot.objects) do if o.def == "pet_mess" then out[#out + 1] = o end end
    table.sort(out, F.ById)
    return out
end

---------------------------------------------------------------------------
-- Pet-only interactions (the pet is the actor)
---------------------------------------------------------------------------
local I = SS.Interactions

local function petOnly(species)
    return function(world, actor)
        if not F.IsPet(actor) then return false, "That's for pets." end
        if species and actor.kind ~= species then return false, "That's for " .. species .. "s." end
        return true
    end
end

I.pet_eat = {
    label = "Eat from Bowl", category = "Pet", slot = "front", pose = "eat", dur = PC.eat.dur,
    advert = {}, manualOnly = true, kinds = { dog = true, cat = true },
    test = function(world, actor, o)
        if not F.IsPet(actor) then return false, "That's the pets' food." end
        if not o.state or (o.state.portions or 0) <= 0 then return false, "The bowl is empty." end
        return true
    end,
    onStart = function(world, actor, act, o)
        if not o or not o.state or (o.state.portions or 0) <= 0 then return false, "The bowl is empty." end
        o.state.portions = o.state.portions - 1
        o.state.stocked = o.state.portions > 0 or nil
        SS.Emit("lotChanged", "state", o.id)
    end,
    onTick = function(world, actor, act, o, dt) F.TickGain(world, act, actor, { hunger = PC.eat.hunger }, PC.eat.dur, dt) end,
}

I.pet_bed_sleep = {
    label = "Sleep in Pet Bed", category = "Pet", slot = "petbed", pose = "sleep", sleeping = true, maxDur = 300,
    rate = { energy = PC.bedRest.energy, comfort = PC.bedRest.comfort }, untilFull = "energy",
    wakeOn = { hunger = -60, bladder = -45 }, advert = {}, manualOnly = true, kinds = { dog = true, cat = true },
    test = petOnly(),
}

I.pet_use_litter = {
    label = "Use Litter Box", category = "Pet", slot = "tray", pose = "sit", dur = 3,
    gain = { bladder = 200, hygiene = -2 }, advert = {}, manualOnly = true, kinds = { cat = true },
    test = function(world, actor, o)
        if not F.IsPet(actor) then return false, "That's the cat's." end
        if (o.state and o.state.dirt or 0) >= PC.litterFullAt then return false, "The litter box is too dirty to use." end
        return true
    end,
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        o.state = o.state or {}
        -- a hooded box gets dirty more slowly (catalogue quality.dirtRate, x1 = normal)
        o.state.dirt = math.min(100, (o.state.dirt or 0) + PC.litterDirtPerUse * F.Quality(o, "dirtRate", 1))
        o.state.dirty = o.state.dirt >= 50 or nil
        o.state.full = o.state.dirt >= PC.litterFullAt or nil
        SS.Emit("lotChanged", "state", o.id)
        P.State(actor).lastGood = { t = world.time, kind = "litter" }
    end,
}

I.pet_toy_play = {
    label = "Play with Toy", category = "Pet", slot = "front", pose = "play", maxDur = PC.toy.maxDur,
    rate = { fun = PC.toy.fun, energy = -4 }, untilFull = "fun", advert = {}, manualOnly = true, kinds = { dog = true, cat = true },
    test = petOnly(),
}

---------------------------------------------------------------------------
-- Accidents, relieving outside, praise and scolding windows
---------------------------------------------------------------------------
function P.Accident(world, a)
    local pt = P.State(a)
    local n = a.needs
    n.bladder = 90
    SS.Needs.Add(a, "hygiene", -10)
    local messes = P.Messes(world)
    local o
    if #messes < PB.messCap then
        local i, j = F.FreeCellNear(world, a.level or 0, math.floor(a.x), math.floor(a.y), 3, { minR = 1, notDoor = true, open = true })
        if not i then i, j = F.FreeCellNear(world, a.level or 0, math.floor(a.x), math.floor(a.y), 5, { minR = 1 }) end
        if i then
            if SS.Maintenance and SS.Maintenance.Mess then
                o = SS.Maintenance.Mess(world, "pet", i, j, a.level or 0)
            end
            if not o then o = F.AddObject(world, "pet_mess", i, j, a.level or 0, 0, { by = a.id, t = world.time }) end
        end
    end
    pt.lastMess = { t = world.time, oid = o and o.id }
    pt.messes = (pt.messes or 0) + 1
    local indoor = W.RoomAt(world, a.level or 0, math.floor(a.x), math.floor(a.y)) ~= 0
    local text = a.name .. " had an accident" .. (indoor and " indoors" or "") .. "."
    F.Journal(world, text)
    local seen
    for _, id in ipairs(F.ActorIds(world)) do
        local q = world.actors[id]
        if F.IsAdult(q) and q.householdId == a.householdId and not q.sleeping then seen = q; break end
    end
    if seen then
        if not F.Say(world, seen, "pet_mess", { pet = a.id, petName = a.name, mess = true }) then
            SS.Actions.Message(world, seen, text .. " It needs cleaning up.", "hygiene")
        end
    else
        SS.Emit("notice", a, text)
    end
    SS.Emit("petMess", world, a, o)
    return o
end

function P.ReliefOutside(world, a)
    local pt = P.State(a)
    a.needs.bladder = 100
    pt.lastGood = { t = world.time, kind = "outside" }
    local t = tmp(a)
    t.busy = { kind = "relieve", untilT = world.time + PB.reliefDur, pose = "sit" }
    SS.Emit("petRelieved", world, a)
end

local function outdoorCell(world, a)
    local lv = 0
    local i, j = math.floor(a.x), math.floor(a.y)
    -- nearest outdoor free cell by rings, preferring cells away from the door
    local ci, cj = F.FreeCellNear(world, lv, i, j, math.max(world.lot.w, world.lot.h), { outdoor = true, notDoor = true })
    return ci, cj
end

---------------------------------------------------------------------------
-- The pet role: needs-driven routine through the shared executor
---------------------------------------------------------------------------
local function order(a, o)
    a.queue = a.queue or {}
    o.manual = false
    a.queue[#a.queue + 1] = o
end

-- Favourite person of the household at home and awake (highest pet -> person life), for
-- affection and begging.
local function favourite(world, a)
    local best, bestV
    local ids = F.ActorIds(world)
    for n = 1, #ids do
        local q = world.actors[ids[n]]
        if q and F.IsHuman(q) and not F.IsInfant(q) and q.householdId == a.householdId and not q.role and not q.dead
            and not q.sleeping then
            local v = F.Rel(world, a.id, q.id).life + (a.pet and a.pet.owner == q.id and 10 or 0)
            if not bestV or v > bestV or (v == bestV and q.id < best.id) then best, bestV = q, v end
        end
    end
    return best
end

local function goNear(world, a, q)
    local i, j = F.FreeCellNear(world, q.level or 0, math.floor(q.x), math.floor(q.y), 3, { minR = 1 })
    if i then order(a, { iid = "goto", x = i, y = j, level = q.level or 0 }); return true end
end

local function isNight(world)
    local h = (world.time % 1440) / 60
    return h >= 22 or h < 6
end

local function startNap(world, a)
    local pt = P.State(a)
    pt.nap = true
    a.sleeping = true
    a.pose = "sleep"
end

-- Visitors: greet (friendly) or bark (dogs) / keep away (cats), once per visitor per window.
local function reactToVisitors(world, a, pt, t)
    t.greetCool = t.greetCool or {}
    local sp = P.Species(a)
    for _, id in ipairs(F.ActorIds(world)) do
        local v = world.actors[id]
        if v ~= a and F.IsHuman(v) and v.householdId ~= a.householdId and not v.dead
            and (t.greetCool[id] or -1e9) <= world.time
            and math.abs(v.x - a.x) + math.abs(v.y - a.y) <= PD.visitorRadius and (v.level or 0) == (a.level or 0) then
            t.greetCool[id] = world.time + PD.visitorReactCooldown
            local rel = F.PeekRel(world, a.id, v.id).life
            local friendlyAt = a.kind == "cat" and PB.catFriendlyAt or PB.visitorFriendlyAt
            local friendly = pt.traits.friendly >= friendlyAt or rel >= 20
            if friendly then
                goNear(world, a, v)
                t.plan = { kind = "greet", tid = v.id }
                SS.Needs.Add(v, "social", PB.greetVisitor.social)
                SS.Needs.Add(v, "fun", PB.greetVisitor.fun)
                F.Change(world, a.id, v.id, PB.greetVisitor.rel, 1)
                F.Change(world, v.id, a.id, PB.greetVisitor.rel, 1)
                a.balloon = { icon = "social", text = a.name .. " greets " .. v.name .. ".", untilT = world.time + 6, kind = "speech" }
                SS.Emit("petGreeted", world, a, v, "greet")
            elseif sp.barksAtStrangers then
                t.busy = { kind = "bark", untilT = world.time + PB.barkDur, pose = "bark" }
                a.facing = SS.Grid.dirToFacing(v.x - a.x, v.y - a.y)
                SS.Needs.Add(v, "comfort", PB.barkVisitor.comfort)
                F.Change(world, a.id, v.id, PB.barkVisitor.rel, 0)
                F.Change(world, v.id, a.id, PB.barkVisitor.rel, 0)
                a.balloon = { icon = "alert", text = a.name .. " barks at " .. v.name .. ".", untilT = world.time + 6, kind = "alert" }
                if SS.Audio and SS.Audio.Sfx then SS.Audio.Sfx("dog_bark") end
                SS.Emit("petGreeted", world, a, v, "bark")
            else
                t.busy = { kind = "wary", untilT = world.time + PB.barkDur, pose = "sit" }
                a.balloon = { icon = "alert", text = a.name .. " watches " .. v.name .. " warily.", untilT = world.time + 6, kind = "thought" }
                SS.Emit("petGreeted", world, a, v, "wary")
            end
            -- bounded cool-down table
            local n = 0
            for k, until_ in pairs(t.greetCool) do
                if until_ <= world.time then t.greetCool[k] = nil else n = n + 1 end
            end
            return true
        end
    end
end

-- Choose what to do next (idle pets only).
function P.Decide(world, a)
    local pt, t = P.State(a), tmp(a)
    local sp = P.Species(a)
    local n = a.needs
    -- 1) the call of nature
    if n.bladder <= sp.needToGoAt then
        if sp.usesLitter then
            local lit = P.UsableLitter(world, a)
            if lit then order(a, { oid = lit.id, iid = "pet_use_litter" }); return "litter" end
        elseif sp.relievesOutdoors then
            -- one decision per urge: a house-trained dog asks to go out; an untrained one may not
            if t.urgeOut == nil then t.urgeOut = SS.Random(world, "pets") * 100 < (pt.training.house or 0) + 10 end
            if t.urgeOut then
                local i, j = outdoorCell(world, a)
                if i and not (t.outCool and t.outCool > world.time) then
                    order(a, { iid = "goto", x = i, y = j, level = 0 })
                    t.plan = { kind = "relieve", since = world.time }
                    a.balloon = { icon = "bladder", text = a.name .. " needs to go out.", untilT = world.time + 8, kind = "thought" }
                    return "outside"
                end
            else
                a.balloon = { icon = "bladder", text = a.name .. " needs to go out.", untilT = world.time + 8, kind = "thought" }
            end
        end
    end
    -- 2) food
    if n.hunger <= PB.eatBelow then
        local bowl = P.BowlWithFood(world, a)
        if bowl then order(a, { oid = bowl.id, iid = "pet_eat" }); return "eat" end
        if (t.begAt or -1e9) + PD.begCooldown <= world.time then
            local q = favourite(world, a)
            if q then
                t.begAt = world.time
                goNear(world, a, q)
                t.plan = { kind = "beg", tid = q.id }
                SS.Actions.Message(world, q, a.name .. " is hungry: " .. (#F.ObjectsWithTag(world, "pet_bowl") > 0 and "fill the food bowl." or "there is no pet bowl to fill."), "hunger")
                return "beg"
            end
        end
    end
    -- 3) rest
    if n.energy <= PB.sleepBelow or (isNight(world) and n.energy <= PB.nightSleepBelow) then
        local bed = P.FreeBed(world, a)
        if bed then order(a, { oid = bed.id, iid = "pet_bed_sleep" }); return "bed" end
        startNap(world, a)
        return "nap"
    end
    -- 4) grooming (cats keep themselves clean)
    if sp.selfGrooms and n.hygiene <= PB.groomBelow then
        t.busy = { kind = "groom", untilT = world.time + PC.selfGroom.dur, pose = "groom", gain = { hygiene = PC.selfGroom.hygiene }, dur = PC.selfGroom.dur }
        return "groom"
    end
    -- 5) play
    if n.fun <= PB.playBelow then
        local toy = P.FreeToy(world, a)
        if toy then order(a, { oid = toy.id, iid = "pet_toy_play" }); return "toy" end
    end
    -- 6) company
    if n.social <= PB.socialBelow or n.fun <= PB.playBelow then
        local q = favourite(world, a)
        if q and F.Dist(q, a) <= PB.seekMaxDist then
            goNear(world, a, q)
            t.plan = { kind = "nuzzle", tid = q.id }
            return "seek"
        end
    end
    -- 7) wander a little
    if SS.Random(world, "pets") < PB.wanderChance * (0.5 + (pt.traits.active or 5) / 10) then
        local r = PB.wanderRadius
        local di, dj = SS.RandomInt(world, "pets", -r, r), SS.RandomInt(world, "pets", -r, r)
        local i, j = F.FreeCellNear(world, a.level or 0, math.floor(a.x) + di, math.floor(a.y) + dj, 2)
        if i then order(a, { iid = "goto", x = i, y = j, level = a.level or 0 }); return "wander" end
    end
    return "idle"
end

-- Plans that finish when the walk arrives (relieving outside, greeting, begging, nuzzling).
local function finishPlan(world, a, pt, t)
    local plan = t.plan
    t.plan = nil
    if plan.kind == "relieve" then
        local outside = W.RoomAt(world, a.level or 0, math.floor(a.x), math.floor(a.y)) == 0
        if outside then P.ReliefOutside(world, a) else t.outCool = world.time + 20 end
    elseif plan.kind == "greet" then
        t.busy = { kind = "greet", untilT = world.time + PB.greetDur, pose = "greet" }
    elseif plan.kind == "beg" then
        t.busy = { kind = "beg", untilT = world.time + PB.begDur, pose = "beg" }
        a.balloon = { icon = "hunger", text = a.name .. " is begging for food.", untilT = world.time + 8, kind = "thought" }
    elseif plan.kind == "nuzzle" then
        local q = world.actors[plan.tid]
        if q and F.Dist(q, a) <= 3 then
            t.busy = { kind = "nuzzle", untilT = world.time + PB.nuzzleDur, pose = "nuzzle", gain = { social = 20, fun = 8 }, dur = PB.nuzzleDur }
            SS.Needs.Add(q, "social", 4)
            SS.Needs.Add(q, "fun", 3)
            F.Change(world, a.id, q.id, 1, 0.3)
            F.Change(world, q.id, a.id, 1, 0.3)
            a.facing = SS.Grid.dirToFacing(q.x - a.x, q.y - a.y)
        end
    end
end

function P.Tick(world, a, dt)
    if not F.IsPet(a) then return end
    if not a.decay or a.role ~= "pet" then P.Setup(world, a) end
    local pt, t = P.State(a), tmp(a)
    local sp = P.Species(a)
    local n = a.needs
    local now = world.time
    if n.bladder > sp.needToGoAt then t.urgeOut = nil end
    -- nature cannot always wait
    if n.bladder <= -95 or (n.bladder <= sp.accidentAt and not (t.plan and t.plan.kind == "relieve") and (
        (sp.relievesOutdoors and (pt.training.house or 0) < 100) or (sp.usesLitter and not P.UsableLitter(world, a)))) then
        if not (a.act and (a.act.iid == "pet_use_litter")) then
            if a.act then SS.Actions.Cancel(world, a, 0) end
            if pt.nap then pt.nap = nil; a.sleeping = nil end
            P.Accident(world, a)
        end
    end
    -- neglect: a pet left starving runs off to the shelter (warned at half time)
    if n.hunger <= PD.runawayHunger then
        pt.critMin = (pt.critMin or 0) + dt
        if not pt.warned and pt.critMin >= PD.runawayAfter / 2 then
            pt.warned = true
            local text = a.name .. " is starving and miserable. Feed them soon or they may run away."
            F.Journal(world, text)
            if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "warning") end
        end
        if pt.critMin >= PD.runawayAfter then return P.RunAway(world, a) end
    elseif (pt.critMin or 0) > 0 then
        pt.critMin = math.max(0, pt.critMin - dt)
        if pt.critMin == 0 then pt.warned = nil end
    end
    -- napping on the floor
    if pt.nap then
        a.sleeping = true
        a.pose = "sleep"
        SS.Needs.Add(a, "comfort", PC.floorNapComfort * dt / 60)
        if n.energy >= PB.wakeAt or n.hunger <= -50 or n.bladder <= sp.needToGoAt - 10 or (a.act or (a.queue and #a.queue > 0)) then
            pt.nap = nil
            a.sleeping = nil
        else
            return
        end
    end
    -- short role poses (barking, grooming, begging, relieving)
    if t.busy then
        local b = t.busy
        if b.gain and b.dur then
            local frac = math.min(dt, math.max(0, b.untilT - now)) / b.dur
            for k, v in pairs(b.gain) do SS.Needs.Add(a, k, v * frac) end
        end
        if now >= b.untilT or a.act or (a.queue and #a.queue > 0) then
            t.busy = nil
        else
            a.pose = b.pose or "idle"
            return
        end
    end
    if a.act or (a.queue and #a.queue > 0) then return end
    if t.plan then return finishPlan(world, a, pt, t) end
    if reactToVisitors(world, a, pt, t) then return end
    if (t.nextDecide or -1) > now then return end
    t.nextDecide = now + PD.decideEvery
    P.Decide(world, a)
end

SS.Roles.pet = { label = "Pet", useAutonomy = false, resident = true, family = true,
    tick = function(world, a, dt) P.Tick(world, a, dt) end }
F.DeclareResidentRole("pet", "Pet")

function P.RunAway(world, a)
    local name = a.name
    local hh = a.householdId
    F.TakeIntoCare(world, a.id, "ran away")
    local text = name .. " ran away after going hungry for too long. The animal shelter picked them up."
    F.Journal(world, text)
    if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "warning") end
    for _, m in ipairs(F.Members(world, hh, F.IsHuman)) do SS.Needs.Add(m, "social", -15) end
    F.Record(world, "pet_ran_away", { rid = a.id, hh = hh })
    SS.Emit("petRanAway", world, a)
end

---------------------------------------------------------------------------
-- People with pets (targetActor on the pet): affection, play, treats, brushing, training, walks
---------------------------------------------------------------------------
local function withPet(opts)
    return function(world, actor, pet)
        if not pet or not F.IsPet(pet) then return false, "That's for pets." end
        if not actor or not F.IsHuman(actor) or F.IsInfant(actor) then return false, "Only people can do that." end
        if opts.adult and not F.IsAdult(actor) then return false, "Only a grown-up can do that." end
        if opts.species and pet.kind ~= opts.species then return false, "Only " .. opts.species .. "s do that." end
        if opts.household and actor.householdId ~= pet.householdId then return false, pet.name .. " isn't your pet." end
        if opts.awake and pet.sleeping then return false, pet.name .. " is asleep." end
        if opts.check then return opts.check(world, actor, pet, P.State(pet)) end
        return true
    end
end

local function relBoth(world, a, b, d, l)
    F.Change(world, a.id, b.id, d, l or 0)
    F.Change(world, b.id, a.id, d, l or 0)
end

-- The pet stops wandering and faces the person for the length of the interaction.
local function hold(world, actor, pet, minutes, pose)
    if pet.act and pet.act.iid ~= "pet_bed_sleep" then SS.Actions.Cancel(world, pet, 0) end
    pet.queue = {}
    local t = tmp(pet)
    t.plan = nil
    t.busy = { kind = "with", untilT = world.time + minutes, pose = pose or "sit" }
    if pet.pet then pet.pet.nap = nil end
    pet.sleeping = nil
    pet.facing = SS.Grid.dirToFacing(actor.x - pet.x, actor.y - pet.y)
end

local function petAction(def)
    local base = {
        category = "Pet", targetActor = true, advert = {}, kinds = { human = true },
        onStart = function(world, actor, act)
            local pet, why = F.TargetInReach(world, actor, act)
            if not pet then return false, why end
            if def.charge then
                local ok, err = F.ChargeOnce(world, act, def.charge, def.ledger or def.label)
                if not ok then return false, err end
            end
            hold(world, actor, pet, (def.dur or 5) + 1, def.petPose)
            if def.start then return def.start(world, actor, act, pet) end
        end,
        onTick = function(world, actor, act, _, dt)
            local pet = world.actors[act.tid]
            if not pet then act.complete = true; return end
            if def.petGain then F.TickGain(world, act, pet, def.petGain, def.dur, dt) end
            if def.humanGain then F.TickGain(world, act, actor, def.humanGain, def.dur, dt) end
        end,
        onEnd = function(world, actor, act, _, status)
            local pet = world.actors[act.tid]
            if pet and tmp(pet).busy and tmp(pet).busy.kind == "with" then tmp(pet).busy = nil end
            if status == "done" and pet and def.done then def.done(world, actor, act, pet) end
        end,
    }
    for k, v in pairs(def) do if base[k] == nil then base[k] = v end end
    return base
end

I.pet_pet = petAction({
    label = "Pet", pose = "use", dur = PC.pet.dur, petPose = "happy",
    petGain = { social = PC.pet.petSocial }, humanGain = { social = PC.pet.humanSocial, fun = PC.pet.humanFun },
    test = withPet({ awake = true }),
    done = function(world, actor, act, pet) relBoth(world, actor, pet, PC.pet.rel, PC.pet.life) end,
})

I.pet_play = petAction({
    label = "Play", pose = "play", dur = PC.play.dur, petPose = "play",
    petGain = { fun = PC.play.petFun, energy = PC.play.petEnergy, social = PC.play.petSocial },
    humanGain = { fun = PC.play.humanFun, energy = PC.play.humanEnergy },
    test = withPet({ awake = true, check = function(world, actor, pet)
        if pet.needs.energy < -20 then return false, pet.name .. " is too tired to play." end
        return true
    end }),
    done = function(world, actor, act, pet) relBoth(world, actor, pet, PC.play.rel, 1) end,
})

I.pet_treat = petAction({
    label = "Give a Treat", pose = "use", dur = PC.treat.dur, petPose = "eat", charge = PC.treat.cost, ledger = "Pet treats",
    petGain = { hunger = PC.treat.petHunger, social = PC.treat.petSocial },
    test = withPet({ awake = true, check = function(world, actor) return F.CanAfford(world, PC.treat.cost) end }),
    done = function(world, actor, act, pet) relBoth(world, actor, pet, PC.treat.rel, 1) end,
})

I.pet_groom = petAction({
    label = "Brush", pose = "use", dur = PC.groom.dur, petPose = "sit",
    petGain = { hygiene = PC.groom.petHygiene, social = 5 }, humanGain = { hygiene = PC.groom.humanHygiene },
    test = withPet({ awake = true, check = function(world, actor, pet)
        if pet.needs.hygiene >= 90 then return false, pet.name .. " is already clean and shiny." end
        return true
    end }),
    done = function(world, actor, act, pet) relBoth(world, actor, pet, PC.groom.rel, 0.5) end,
})

-- Praise right after going outside / using the litter box teaches house training.
I.pet_praise = petAction({
    label = "Praise", pose = "talk", dur = PC.praise.dur, petPose = "happy",
    petGain = { social = PC.praise.petSocial },
    test = withPet({ household = true, awake = true }),
    done = function(world, actor, act, pet)
        local pt = P.State(pet)
        relBoth(world, actor, pet, PC.praise.rel, 0.5)
        if pt.lastGood and world.time - pt.lastGood.t <= PC.praise.window and pet.kind == "dog" then
            local before = pt.training.house
            pt.training.house = math.min(100, before + PC.praise.houseGain)
            pt.lastGood = nil
            SS.Actions.Message(world, actor, pet.name .. " is learning: house training " .. math.floor(pt.training.house) .. "%.", "fun")
            P.CheckTrained(world, pet, "house", before)
        end
    end,
})

I.pet_scold = petAction({
    label = "Scold", pose = "argue", dur = PC.scold.dur, petPose = "sad",
    petGain = { social = PC.scold.petSocial },
    test = withPet({ household = true, awake = true }),
    done = function(world, actor, act, pet)
        local pt = P.State(pet)
        if pt.lastMess and world.time - pt.lastMess.t <= PC.scold.window then
            relBoth(world, actor, pet, PC.scold.rel, 0)
            if pet.kind == "dog" then
                local before = pt.training.house
                pt.training.house = math.min(100, before + PC.scold.houseGain)
                P.CheckTrained(world, pet, "house", before)
            end
            pt.lastMess = nil
            SS.Actions.Message(world, actor, pet.name .. " looks guilty and understands.", "social")
        else
            relBoth(world, actor, pet, PC.scold.wrongRel, -1)
            SS.Actions.Message(world, actor, pet.name .. " has no idea what that was for.", "social")
        end
    end,
})

function P.TrainGain(world, pet, trainer)
    local pt = P.State(pet)
    local T = PC.train
    local g = T.base + T.perSmart * (pt.traits.smart or 5)
    if SS.Needs.Mood(pet) > 0 then g = g + T.moodBonus end
    if trainer and trainer.id == pt.owner then g = g + 1 end
    return g
end

function P.CheckTrained(world, pet, skill, before)
    local pt = P.State(pet)
    if before < 100 and pt.training[skill] >= 100 then
        local text = skill == "sit" and (pet.name .. " has learned to sit on command!") or (pet.name .. " is fully house trained!")
        F.Journal(world, text)
        SS.Emit("notice", pet, text)
        SS.Emit("petTrained", world, pet, skill)
    end
end

local function trainAction(skill, label, species)
    return petAction({
        label = label, pose = "talk", dur = PC.train.dur, petPose = "sit",
        petGain = { fun = PC.train.petFun }, humanGain = { fun = PC.train.humanFun },
        test = withPet({ household = true, awake = true, species = species, check = function(world, actor, pet, pt)
            if pet.needs.energy < PC.train.minEnergy then return false, pet.name .. " is too tired to learn anything." end
            if (pt.training[skill] or 0) >= 100 then return false, pet.name .. " already knows this." end
            return true
        end }),
        done = function(world, actor, act, pet)
            local pt = P.State(pet)
            local before = pt.training[skill] or 0
            pt.training[skill] = math.min(100, before + P.TrainGain(world, pet, actor))
            relBoth(world, actor, pet, 1, 0.3)
            SS.Actions.Message(world, actor, pet.name .. ": " .. label:gsub("^Train: ", "") .. " " .. math.floor(pt.training[skill]) .. "%.", "fun")
            P.CheckTrained(world, pet, skill, before)
            SS.Emit("petTrainingSession", world, pet, skill, pt.training[skill])
        end,
    })
end
I.pet_train_sit = trainAction("sit", "Train: Sit")
I.pet_train_house = trainAction("house", "Train: House Manners", "dog")

I.pet_cmd_sit = petAction({
    label = "Ask to Sit", pose = "talk", dur = PC.commandSit.dur, petPose = "sit",
    test = withPet({ household = true, awake = true }),
    done = function(world, actor, act, pet)
        local pt = P.State(pet)
        if SS.Random(world, "pets") * 100 < (pt.training.sit or 0) then
            tmp(pet).busy = { kind = "sit", untilT = world.time + 3, pose = "sit" }
            SS.Needs.Add(actor, "fun", PC.commandSit.humanFun)
            SS.Needs.Add(pet, "social", PC.commandSit.petSocial)
            SS.Actions.Message(world, actor, pet.name .. " sits. Good " .. (pet.kind == "dog" and "dog" or "cat") .. "!", "fun")
            SS.Emit("petObeyed", world, pet, actor)
        else
            SS.Actions.Message(world, actor, pet.name .. " looks at " .. actor.name .. " and does something else entirely.", "fun")
        end
    end,
})

-- Take the dog for a walk: both leave the lot for a while and come back refreshed.
I.pet_walk = petAction({
    label = "Take for a Walk", pose = "talk", dur = 1, petPose = "happy",
    test = withPet({ household = true, awake = true, species = "dog", check = function(world, actor, pet)
        if not F.IsAdult(actor) then return false, "Only a grown-up can take the dog out." end
        local ok, why = F.CanLeave(world, { actor.id })
        if not ok then return false, why end
        return true
    end }),
    done = function(world, actor, act, pet) P.StartWalk(world, actor, pet) end,
})

function P.StartWalk(world, human, pet)
    local back = world.time + PD.species.dog.walkMinutes
    SS.Sim.Schedule(world, back, "pets.walk_back", { human = human.id, pet = pet.id }, world.lot.id)
    for _, a in ipairs({ human, pet }) do
        if SS.Street.Depart then SS.Street.Depart(world, a, "walk", nil, { with = (a == human) and pet.id or human.id })
        else SS.Sim.RemoveActor(world, a.id, { reason = "walk" }) end
    end
    F.Journal(world, human.name .. " took " .. pet.name .. " for a walk.")
end

SS.On("scheduled", function(ev, world)
    if not world or ev.kind ~= "pets.walk_back" then return end
    local root = F.Root(world)
    local W_ = PC.walk
    local h, p = root.residents[ev.data.human], root.residents[ev.data.pet]
    for _, r in ipairs({ h, p }) do
        if r and not r.dead and not r.lotId and r.away and r.away.reason == "walk" then
            r.away = nil
            local a = SS.Street.Arrive and SS.Street.Arrive(world, r.id) or nil
            if not world.actors[r.id] then
                local i, j = SS.Street.EntryCell(world)
                SS.Sim.AddActor(world, r.id, i, j, 0)
            end
            local pa = world.actors[r.id]
            if pa and F.OwnPet(pa) and not F.StreetWalking(pa) then P.Setup(world, pa) end
        end
    end
    if h and p and world.actors[h.id] and world.actors[p.id] then
        SS.Needs.Add(p, "fun", W_.petFun); SS.Needs.Add(p, "social", W_.petSocial); p.needs.bladder = 100
        SS.Needs.Add(h, "fun", W_.humanFun); SS.Needs.Add(h, "energy", W_.humanEnergy)
        relBoth(world, h, p, W_.rel, 1)
        P.State(p).lastGood = { t = world.time, kind = "outside" }
        SS.Emit("petWalked", world, h, p)
    end
end)

---------------------------------------------------------------------------
-- Pet care objects (people): bowls, litter, messes
---------------------------------------------------------------------------
I.pet_fill_bowl = {
    label = "Fill Pet Bowl", category = "Pet", slot = "front", pose = "use", dur = PC.fillBowl.dur,
    ages = { adult = true, child = true }, kinds = { human = true },
    test = function(world, actor, o)
        if not F.IsHuman(actor) or F.IsInfant(actor) then return false, "Only people can do that." end
        if not o then return false, F.GONE end
        if o.state and (o.state.portions or 0) >= PC.fillBowl.portions then return false, "The bowl is already full." end
        return F.CanAfford(world, PC.fillBowl.cost)
    end,
    onStart = function(world, actor, act, o)
        if not o then return false, F.GONE end
        local ok, why = F.ChargeOnce(world, act, PC.fillBowl.cost, "Pet food")
        if not ok then return false, why end
    end,
    onEnd = function(world, actor, act, o, status)
        if not o or not act.charged then return end
        -- the food is bought once it is in the bowl, even if interrupted part-way
        o.state = o.state or {}
        o.state.portions = PC.fillBowl.portions
        o.state.stocked = true
        SS.Emit("lotChanged", "state", o.id)
        SS.Emit("petBowlFilled", world, actor, o)
    end,
}
SS.Tags.Attach("pet_bowl", "pet_fill_bowl")

I.pet_clean_litter = {
    label = "Clean Litter Box", category = "Pet", slot = "front", pose = "clean", dur = PC.cleanLitter.dur,
    gain = { hygiene = PC.cleanLitter.humanHygiene }, ages = { adult = true, child = true }, kinds = { human = true },
    advertise = function(world, actor, o)
        local d = o.state and o.state.dirt or 0
        if d >= 50 and F.IsHuman(actor) and not F.IsInfant(actor) then return { room = 20 + d / 4 } end
    end,
    test = function(world, actor, o)
        if not F.IsHuman(actor) or F.IsInfant(actor) then return false, "Only people can do that." end
        if not o then return false, F.GONE end
        if not o.state or (o.state.dirt or 0) < 5 then return false, "The litter box is clean." end
        return true
    end,
    onTick = function(world, actor, act, o, dt)
        if not o then return F.Gone(world, actor, act) end
        if not o.state then return end
        local frac = math.min(dt, PC.cleanLitter.dur - act.t) / PC.cleanLitter.dur
        act.data.start = act.data.start or o.state.dirt or 0
        o.state.dirt = math.max(0, (o.state.dirt or 0) - act.data.start * frac)
    end,
    onEnd = function(world, actor, act, o, status)
        if not o or not o.state then return end
        if status == "done" then o.state.dirt = 0 end
        o.state.dirty = (o.state.dirt or 0) >= 50 or nil
        o.state.full = (o.state.dirt or 0) >= PC.litterFullAt or nil
        SS.Emit("lotChanged", "state", o.id)
    end,
}
SS.Tags.Attach("litter", "pet_clean_litter")

I.pet_clean_mess = {
    label = "Clean Up Mess", category = "Pet", slot = "front", pose = "clean", dur = PC.cleanMess.dur, chore = true, traits = { neat = 1 },
    gain = { hygiene = PC.cleanMess.humanHygiene }, advert = { room = 35 }, ages = { adult = true, child = true }, kinds = { human = true },
    test = function(world, actor, o)
        if not F.IsHuman(actor) or F.IsInfant(actor) then return false, "Only people can do that." end
        return true
    end,
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        F.RemoveObject(world, o.id)
        SS.Emit("messCleaned", world, actor, "pet_mess")
    end,
}

-- People notice hungry pets, full litter boxes and lonely animals.
SS.Actions.RegisterCandidates(function(world, actor, cands)
    if actor.role or not F.IsHuman(actor) or F.IsInfant(actor) or not F.IsMember(world, actor) then return end
    local ids = F.ActorIds(world)
    local any, hungry = false, false
    for n = 1, #ids do
        local p = world.actors[ids[n]]
        if p and F.IsPet(p) and p.householdId == actor.householdId then
            any = true
            if p.needs.hunger <= 40 then hungry = true end
        end
    end
    if not any then return end
    if hungry and not P.BowlWithFood(world, actor) then
        local bowl = nearest(world, actor, F.ObjectsWithTag(world, "pet_bowl"))
        if bowl and not F.AutoCooling(world, actor, bowl.id, "pet_fill_bowl") and SS.Actions.Available(world, actor, bowl, "pet_fill_bowl") then
            cands[#cands + 1] = { oid = bowl.id, iid = "pet_fill_bowl", s = 34 }
        end
    end
    -- a little affection when the pet or the person could use it
    for n = 1, #ids do
        local p = world.actors[ids[n]]
        if not (p and F.IsPet(p) and p.householdId == actor.householdId) then
            -- not one of this household's pets
        elseif not p.sleeping and (p.needs.social <= 20 or actor.needs.social <= 10) then
            local s = 10 + (100 - p.needs.social) / 8 + (100 - (actor.needs.social or 0)) / 10
            if s > 12 and not F.AutoCooling(world, actor, p.id, "pet_pet") and SS.Actions.Available(world, actor, p, "pet_pet") then
                cands[#cands + 1] = { tid = p.id, iid = "pet_pet", s = s }
            end
        elseif not p.sleeping and p.needs.fun <= 20 and (actor.needs.fun or 0) <= 40 and F.IsAdult(actor) then
            local s = 8 + (100 - p.needs.fun) / 8 + (100 - (actor.needs.fun or 0)) / 12
            if s > 12 and not F.AutoCooling(world, actor, p.id, "pet_play") and SS.Actions.Available(world, actor, p, "pet_play") then
                cands[#cands + 1] = { tid = p.id, iid = "pet_play", s = s }
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Adoption (pet shop and shelter by phone; the courier brings the animal), rehoming
---------------------------------------------------------------------------
function P.Fee(species, source)
    local sp = PD.species[species]
    if not sp then return 0 end
    return source == "shelter" and sp.shelterFee or sp.adoptFee
end

function P.AdoptCheck(world, caller, species, source)
    if not caller or not F.IsAdult(caller) then return false, "Only an adult can adopt a pet." end
    if not world.household or caller.householdId ~= world.household.id then return false, "Only a member of this household can adopt a pet." end
    if not world.household.lotId then return false, "The household needs a home first." end
    local ok, why = F.HasRoom(world, world.household, "pet", 1)
    if not ok then return false, why end
    local fee = P.Fee(species or "dog", source)
    if (world.money or 0) < fee then return false, "Adoption costs " .. U.fmtMoney(fee) .. "; the household can't afford it." end
    return true
end

-- spec = { species = "dog"|"cat"|nil (shelter: whichever is waiting), breed?, coat?, source = "shop"|"shelter" }
function P.Adopt(world, caller, spec)
    spec = spec or {}
    local source = spec.source or "shop"
    local species = spec.species
    local waiting
    if source == "shelter" then
        waiting = P.ShelterAnimal(world, species, world.household.id)
        if waiting then species = waiting.kind end
        species = species or (SS.Random(world, "pets") < 0.5 and "dog" or "cat")
    end
    species = species or "dog"
    local ok, why = P.AdoptCheck(world, caller, species, source)
    if not ok then return false, why end
    local s = F.State(world)
    local id = F.NewId(world, "p")
    local fee = P.Fee(species, source)
    local rec = { id = id, kind = "pet", species = species, breed = spec.breed, coat = spec.coat, source = source,
        rid = nil, waiting = waiting and waiting.id or nil, hh = world.household.id, lotId = world.household.lotId,
        caller = caller.id, fee = fee, state = "scheduled", t = F.Root(world).time }
    s.pending[id] = rec
    local delay = SS.RandomInt(world, "pets", 60, 120)
    local v = F.RequestVisit(world, "npc_pet_courier", "pet_delivery", world.household, { pid = id }, delay)
    rec.visit, rec.dueAt = v.id, v.dueAt
    local where = source == "shelter" and "the Linden Hollow Animal Shelter" or "the pet shop"
    local what = waiting and ("a " .. (PD.species[species].label):lower() .. " from the shelter") or ("a " .. (PD.species[species].label):lower())
    F.Journal(world, caller.name .. " arranged to adopt " .. what .. ".")
    return true, "The courier from " .. where .. " will bring " .. what .. " " .. F.DelayText(delay)
        .. ". The " .. U.fmtMoney(fee) .. " fee is paid on arrival."
end

-- An animal waiting at the shelter (never one this household gave up or let run away).
function P.ShelterAnimal(world, species, excludeHh)
    local root = F.Root(world)
    local shelter = root.households[FD.shelterHousehold.id]
    if not shelter then return nil end
    local ids = {}
    for _, rid in ipairs(shelter.members) do
        local r = root.residents[rid]
        if r and not r.dead and F.IsPet(r) and (not species or r.kind == species)
            and not (r.fam and r.fam.removedFrom == excludeHh) then ids[#ids + 1] = rid end
    end
    table.sort(ids)
    return ids[1] and root.residents[ids[1]] or nil
end

F.visitTasks.pet_delivery = function(world, worker, vrec)
    local s = F.State(world)
    local root = F.Root(world)
    local rec = s.pending[vrec.data.pid]
    if not rec or rec.state ~= "scheduled" then return false, "Nothing to deliver." end
    local hh = root.households[rec.hh]
    if not hh or (hh.flags and hh.flags.ended) then rec.state = "cancelled"; return false, "The household is gone." end
    if rec.rid then rec.state = "done"; return true end
    local ok = F.HasRoom(world, hh, "pet", 0)
    if not ok then
        rec.state = "cancelled"
        local text = "The pet delivery was cancelled: the household already has its " .. PD.maxPerHousehold .. " pets."
        F.Journal(world, text)
        return false, text
    end
    if (hh.money or 0) < rec.fee then
        rec.state = "cancelled"
        local text = "The pet courier left: the household can't cover the " .. U.fmtMoney(rec.fee) .. " adoption fee any more."
        F.Journal(world, text)
        SS.Emit("notice", worker, text)
        return false, text
    end
    local pet = rec.waiting and root.residents[rec.waiting]
    if pet and (pet.dead or pet.householdId ~= FD.shelterHousehold.id) then pet = nil end
    if not pet then pet = P.NewPet(world, { species = rec.species, breed = rec.breed, coat = rec.coat, source = rec.source }) end
    rec.rid, rec.state = pet.id, "done"
    F.HouseholdMoney(world, hh, -rec.fee, "family", (rec.source == "shelter" and "Shelter adoption: " or "Pet shop: ") .. pet.name)
    rec.charged = rec.fee
    F.MoveResident(world, pet.id, hh.id, { reason = "adopted" })
    local pt = P.State(pet)
    pt.owner = rec.caller
    pt.adoptedAt = root.time
    pt.source = rec.source
    pt.critMin, pt.warned, pt.nap = 0, nil, nil
    if pet.fam then pet.fam.removedFrom = nil end
    pet.needs.hunger = math.max(pet.needs.hunger or 0, 40)
    for _, m in ipairs(F.Members(world, hh, F.IsHuman)) do
        local base = m.id == rec.caller and 15 or 5
        F.Change(world, pet.id, m.id, base, base / 2)
        F.Change(world, m.id, pet.id, base, base / 2)
    end
    if world.household == hh then
        local i, j
        if worker then i, j = math.floor(worker.x), math.floor(worker.y) else
            local oi, oj, ii, ij = F.FrontDoor(world)
            i, j = ii or oi, ij or oj
        end
        P.Place(world, pet, i, j)
    end
    local text = "Welcome home, " .. pet.name .. "! (" .. PD.breeds[pet.kind][pt.breed].name .. ")"
    F.Journal(world, text)
    SS.Emit("notice", worker, text)
    F.Record(world, "pet_adopted", { rid = pet.id, hh = hh.id, source = rec.source })
    SS.Emit("familyArrival", world, pet, "pet")
    SS.Emit("familyNaming", world, pet)
    return true, text
end
F.visitRefused.pet_delivery = function(world, vrec)
    local rec = F.State(world).pending[vrec.data.pid]
    if rec and rec.state == "scheduled" then rec.state = "cancelled" end
    vrec.state = "cancelled"
    F.Journal(world, "The pet courier was sent away; the adoption is cancelled.")
end

-- Give a pet up to the shelter (the UI confirms first).
function P.Rehome(world, pet)
    if not F.IsPet(pet) then return false, "Only pets can be rehomed." end
    if not world.household or pet.householdId ~= world.household.id then return false, "That pet doesn't live here." end
    local name = pet.name
    F.TakeIntoCare(world, pet.id, "rehomed")
    for _, m in ipairs(F.Members(world, world.household, F.IsHuman)) do
        SS.Needs.Add(m, "social", -10)
        F.Change(world, m.id, pet.id, -10, 0)
    end
    F.Journal(world, name .. " went to live at the animal shelter.")
    SS.Emit("petRehomed", world, pet)
    return true
end

if SS.Phone and SS.Phone.RegisterCall then
    local function call(id, label, order, spec)
        SS.Phone.RegisterCall({ id = id, label = label, category = "Family", order = order,
            test = function(world, caller)
                local species = spec.species
                if spec.source == "shelter" and not species then
                    local w = P.ShelterAnimal(world, nil, world.household and world.household.id)
                    species = w and w.kind or "dog"
                end
                return P.AdoptCheck(world, caller, species, spec.source)
            end,
            run = function(world, caller) return P.Adopt(world, caller, spec) end })
    end
    call("pets_shop_dog", "Pet Shop: Adopt a Dog", 20, { species = "dog", source = "shop" })
    call("pets_shop_cat", "Pet Shop: Adopt a Cat", 21, { species = "cat", source = "shop" })
    call("pets_shelter", "Animal Shelter: Adopt a Pet", 22, { source = "shelter" })
end

---------------------------------------------------------------------------
-- Aquarium / small-animal enclosure (tag aquarium)
---------------------------------------------------------------------------
local AQ = PD.aquarium

-- How many animals this tank holds: the design's quality.capacity (a fishbowl 1, the reef
-- aquarium 8), else the data default (catalogue FA-2).
function P.AquariumCapacity(o)
    return math.floor(F.Quality(o, "capacity", AQ.capacity))
end

function P.AquariumState(world, o)
    if not o then return nil end
    o.state = o.state or {}
    local st = o.state
    if st.fish == nil then st.fish = math.min(AQ.startAnimals, P.AquariumCapacity(o)) end
    st.fedAt = st.fedAt or F.Root(world).time
    st.dirt = st.dirt or 0
    return st
end

function P.AquariumHour(world, o)
    local st = P.AquariumState(world, o)
    local now = world.time
    st.dirt = math.min(100, st.dirt + AQ.dirtPerHour * F.Quality(o, "dirtRate", 1))
    st.dirty = st.dirt >= AQ.dirtyAt or nil
    local sinceFed = now - st.fedAt
    st.hungry = (st.fish > 0 and sinceFed >= AQ.hungryAfter) or nil
    local starving = sinceFed >= AQ.starveAfter
    local sick = st.dirt >= AQ.sickAt
    if st.fish > 0 and (starving or sick) and now - (st.lossAt or 0) >= AQ.lossEvery then
        st.fish = st.fish - 1
        st.lossAt = now
        local why = sick and "the water was filthy" or "nobody fed them"
        local text = "One of the aquarium's residents didn't make it: " .. why .. "." .. (st.fish == 0 and " The tank is empty now." or "")
        F.Journal(world, text)
        SS.Emit("notice", nil, text)
        SS.Emit("aquariumLoss", world, o, why)
    end
    st.empty = st.fish == 0 or nil
end

F.RegisterEnv(function(world, o, def)
    if not o.state or not SS.Tags.Has(def, "aquarium") then return nil end
    local st = o.state
    local d = 0
    if st.dirty then d = d + AQ.dirtyEnv end
    if st.empty and (def.env or 0) > 0 then d = d - def.env * (1 - AQ.emptyEnvFactor) end
    return d
end)

local function aqTest(check)
    return function(world, actor, o)
        if not F.IsHuman(actor) or F.IsInfant(actor) then return false, "Only people can do that." end
        if not o then return false, F.GONE end
        local st = P.AquariumState(world, o)
        if check then return check(world, actor, o, st) end
        return true
    end
end

I.aq_feed = {
    label = "Feed the Fish", category = "Pet", slot = "front", pose = "use", dur = AQ.feedDur,
    ages = { adult = true, child = true }, kinds = { human = true },
    test = aqTest(function(world, actor, o, st)
        if st.fish <= 0 then return false, "The tank is empty." end
        if world.time - st.fedAt < 360 then return false, "They were fed recently." end
        return F.CanAfford(world, AQ.feedCost)
    end),
    onStart = function(world, actor, act, o)
        if not o then return false, F.GONE end
        local ok, why = F.ChargeOnce(world, act, AQ.feedCost, "Fish food")
        if not ok then return false, why end
        local st = P.AquariumState(world, o)
        st.fedAt, st.hungry = world.time, nil
        SS.Emit("lotChanged", "state", o.id)
    end,
}
I.aq_clean = {
    label = "Clean the Tank", category = "Pet", slot = "front", pose = "clean", dur = AQ.cleanDur,
    gain = { hygiene = -4 }, ages = { adult = true, child = true }, kinds = { human = true },
    advertise = function(world, actor, o)
        local st = o.state
        if st and (st.dirt or 0) >= AQ.dirtyAt then return { room = 25 } end
    end,
    test = aqTest(function(world, actor, o, st)
        if st.dirt < 10 then return false, "The water is already clear." end
        return true
    end),
    onTick = function(world, actor, act, o, dt)
        if not o then return F.Gone(world, actor, act) end
        local st = P.AquariumState(world, o)
        act.data.start = act.data.start or st.dirt
        local frac = math.min(dt, AQ.cleanDur - act.t) / AQ.cleanDur
        st.dirt = math.max(0, st.dirt - act.data.start * frac)
    end,
    onEnd = function(world, actor, act, o, status)
        if not o then return end
        local st = P.AquariumState(world, o)
        if status == "done" then st.dirt = 0 end
        st.dirty = st.dirt >= AQ.dirtyAt or nil
        SS.Emit("lotChanged", "state", o.id)
    end,
}
I.aq_watch = {
    label = "Watch the Fish", category = "Fun", slot = "front", pose = "idle", maxDur = AQ.watchMaxDur,
    rate = { fun = AQ.watchFun, comfort = AQ.watchComfort }, untilFull = "fun", ages = { adult = true, child = true }, kinds = { human = true },
    advertise = function(world, actor, o)
        local st = o.state
        if st and (st.fish or AQ.startAnimals) > 0 and F.IsHuman(actor) and not F.IsInfant(actor) then
            return { fun = st.dirty and 12 or 25, comfort = 5 }
        end
    end,
    test = aqTest(function(world, actor, o, st)
        if st.fish <= 0 then return false, "There's nothing in the tank to watch." end
        return true
    end),
}
I.aq_restock = {
    label = "Restock the Tank", category = "Pet", slot = "front", pose = "use", dur = 5, manualOnly = true,
    ages = { adult = true }, kinds = { human = true },
    test = aqTest(function(world, actor, o, st)
        if not F.IsAdult(actor) then return false, "Only a grown-up can buy new fish." end
        if st.fish >= P.AquariumCapacity(o) then return false, "The tank is full." end
        if st.dirty then return false, "Clean the tank first." end
        return F.CanAfford(world, AQ.stockCost)
    end),
    onStart = function(world, actor, act, o)
        if not o then return false, F.GONE end
        local ok, why = F.ChargeOnce(world, act, AQ.stockCost, "New fish for the aquarium")
        if not ok then return false, why end
        local st = P.AquariumState(world, o)
        st.fish = math.min(P.AquariumCapacity(o), st.fish + AQ.startAnimals)
        st.empty, st.fedAt, st.hungry = nil, world.time, nil
        SS.Emit("lotChanged", "state", o.id)
    end,
}
for _, iid in ipairs({ "aq_feed", "aq_clean", "aq_watch", "aq_restock" }) do SS.Tags.Attach("aquarium", iid) end
F.DeclareReads("clean:litter", "clean:aquarium", "capacity:aquarium")

SS.Actions.RegisterCandidates(function(world, actor, cands)
    if actor.role or not F.IsHuman(actor) or F.IsInfant(actor) or not F.IsMember(world, actor) then return end
    for _, o in ipairs(F.ObjectsWithTag(world, "aquarium")) do
        local st = o.state
        if st and st.hungry and not F.AutoCooling(world, actor, o.id, "aq_feed") and SS.Actions.Available(world, actor, o, "aq_feed") then
            cands[#cands + 1] = { oid = o.id, iid = "aq_feed", s = 26 }
        end
    end
end)

---------------------------------------------------------------------------
-- System, events, validator
---------------------------------------------------------------------------
SS.On("actorAdded", function(world, a)
    if world and a and F.OwnPet(a) and (a.role ~= "pet" or not a.decay) then P.Setup(world, a) end
end)
-- back from the street (a walk, an outing): the pet role returns once the pet is on the lot
SS.On("streetArrived", function(world, a)
    if world and type(a) == "table" and F.OwnPet(a) and a.role ~= "pet" then P.Setup(world, a) end
end)

SS.Sim.Register({
    name = "pets", order = 44,
    attach = function(world)
        for _, id in ipairs(F.ActorIds(world)) do
            local a = world.actors[id]
            if F.OwnPet(a) then
                P.Setup(world, a)
                a.sleeping = a.pet.nap or nil
            end
        end
        for _, o in ipairs(F.ObjectsWithTag(world, "aquarium")) do P.AquariumState(world, o) end
    end,
    hour = function(world, h)
        for _, o in ipairs(F.ObjectsWithTag(world, "aquarium")) do P.AquariumHour(world, o) end
        -- neglected pets cool toward the household
        for _, id in ipairs(F.ActorIds(world)) do
            local a = world.actors[id]
            if F.OwnPet(a) and a.needs and ((a.needs.hunger or 0) <= -50 or (a.needs.social or 0) <= -50) then
                for _, m in ipairs(F.Members(world, a.householdId, F.IsHuman)) do
                    F.Change(world, a.id, m.id, PB.hungryRelPerHour, 0)
                end
            end
        end
    end,
})

SS.Save.RegisterValidator(function(root, problems)
    for _, id in ipairs(F.SortedIds(root.residents)) do
        local r = root.residents[id]
        -- a dog or cat wearing another module's role belongs to that module (F.ForeignRole)
        if type(r) == "table" and (r.kind == "dog" or r.kind == "cat") and not F.ForeignRole(r, "pet") then
            if type(r.pet) ~= "table" then r.pet = {}; problems[#problems + 1] = "pet data restored for " .. tostring(id) end
            local pt = r.pet
            pt.species = r.kind
            pt.training = type(pt.training) == "table" and pt.training or { sit = 0, house = 0 }
            pt.traits = type(pt.traits) == "table" and pt.traits or { friendly = 5, active = 5, smart = 5, playful = 5 }
            if not PD.breeds[r.kind][pt.breed or ""] then pt.breed = sortedKeys(PD.breeds[r.kind])[1] end
            local sp = PD.species[r.kind]
            if type(r.decay) ~= "table" or type(r.decay.awake) ~= "table" then
                r.decay = { awake = U.deepcopy(sp.decayAwake), sleep = U.deepcopy(sp.decaySleep) }
            end
            if r.lotId and r.role ~= "arriving" and r.role ~= "departing" then r.role = "pet"; r.roleData = type(r.roleData) == "table" and r.roleData or {} end
        end
    end
    -- the declared pet budget: a save holding more pets than the budget is reported (never silently dropped)
    for _, hid in ipairs(F.SortedIds(root.households)) do
        local hh = root.households[hid]
        if type(hh) == "table" and type(hh.members) == "table" and not (hh.flags and hh.flags.service) then
            local pets = {}
            for _, rid in ipairs(hh.members) do
                local r = root.residents[rid]
                if r and (r.kind == "dog" or r.kind == "cat") and not r.dead then pets[#pets + 1] = rid end
            end
            table.sort(pets)
            if #pets > PD.maxPerHousehold then
                problems[#problems + 1] = "household " .. tostring(hid) .. " had more pets than the declared budget"
            end
        end
    end
    return true
end)

-- Status summary for the UI (Pets page).
function P.Status(world, pet)
    local pt = P.State(pet)
    local b = PD.breeds[pet.kind] and PD.breeds[pet.kind][pt.breed]
    local owner = pt.owner and F.Root(world).residents[pt.owner]
    return {
        species = PD.species[pet.kind] and PD.species[pet.kind].label or pet.kind,
        breed = b and b.name or "Mixed", coat = (pt.coat or ""):gsub("_", " "), pattern = pt.pattern,
        sit = math.floor(pt.training.sit or 0), house = math.floor(pt.training.house or 0),
        traits = pt.traits, owner = owner and owner.name or "the household",
        asleep = pet.sleeping and true or false, messes = pt.messes or 0,
    }
end
