-- Dirt, wear, breakage, repair, puddles, clutter, bins and rubbish. Owner: household-core.
-- * Every use of a fixture adds dirt (Tuning.dirtPerUse by tag) and wear; breakage is rolled per
--   use from def.quality.breakChance (or Tuning.breakChance by tag), scaled by wear.
-- * Broken objects are unavailable or degraded by type (Actions.BrokenPolicy); broken plumbing
--   leaks puddles. Repairs take time, keep partial progress, can fail by mechanical skill, and
--   electrical repairs carry a shock risk handed to SS.Hazards.Electrocute (events module).
-- * Puddles, rubbish piles, trash bags and clutter are system objects (cat "system", not
--   buyable, never counted as catalogue designs) that lower the room score until cleaned.
-- * Indoor bins fill; emptying makes a trash bag that goes to the outdoor bin (or the curb);
--   outdoor bins are collected on Tuning.bin.collectDays.
local _, SS = ...
local T, W, G = SS.Tuning, SS.World, SS.Grid
local M = {}
SS.Maintenance = M
local I = SS.Interactions

-- System objects -----------------------------------------------------------------------------
local function sysdef(d)
    d.cat, d.buyable, d.price, d.system = "system", false, 0, true
    d.env = d.env or 0
    d.slots = d.slots or {}
    d.actions = d.actions or {}
    d.tags = d.tags or {}
    d.approachAround = true
    return d
end
M.SystemDef = sysdef

SS.Objects.puddle = sysdef({ name = "Puddle", mess = "puddle", noBlock = true, mount = "floor",
    desc = "Water where water should not be. Someone will step in it, and it will be you.", actions = { "mop" } })
SS.Objects.trash_pile = sysdef({ name = "Pile of Rubbish", mess = "trash", noBlock = true, mount = "floor", tags = { "rubbish" },
    desc = "A small monument to putting things off.", actions = { "clean_trash" } })
SS.Objects.trash_bag = sysdef({ name = "Trash Bag", mess = "bag", noBlock = true, mount = "floor",
    desc = "Tied, full and waiting for a volunteer.", actions = { "take_out_bag" } })
SS.Objects.clutter = sysdef({ name = "Clutter", mess = "clutter", noBlock = true, mount = "floor",
    desc = "Left exactly where it was last useful.", actions = { "tidy_clutter" } })

-- Object helpers ------------------------------------------------------------------------------
-- System object ids use their own counter ("s<n>", lot.nextSys) so they never collide with
-- catalogue placement ids.
function M.NewId(lot)
    local n = lot.nextSys or 1
    while lot.objects["s" .. n] do n = n + 1 end
    lot.nextSys = n + 1
    return "s" .. n
end

function M.Spawn(world, defId, level, i, j, fields)
    local lot = world.lot
    local id = M.NewId(lot)
    local o = { id = id, def = defId, x = i, y = j, f = 0, level = level or 0, state = {}, bought = world.time, paid = 0 }
    if fields then for k, v in pairs(fields) do o[k] = v end end
    lot.objects[id] = o
    W.ObjectsChanged()
    SS.Emit("lotChanged", "system", id)
    return o
end

function M.Remove(world, o)
    if not o or not world.lot.objects[o.id] then return end
    for _, a in pairs(world.actors) do
        local act = a.act
        if act and (act.oid == o.id or (act.target and act.target.oid == o.id)) and act.iid ~= nil and not act.removing then
            SS.Actions.Interrupt(world, a, "It's gone.", "failed")
        end
    end
    world.lot.objects[o.id] = nil
    W.ObjectsChanged()
    SS.Emit("lotChanged", "system", o.id)
end

-- Put a system object on a free typed surface slot of `surfaceObj`.
function M.SpawnOnSurface(world, defId, surfaceObj, slot, fields)
    local o = M.Spawn(world, defId, surfaceObj.level or 0, slot.i, slot.j, fields)
    o.parent, o.pslot, o.z = surfaceObj.id, slot.key, slot.z
    W.ObjectsChanged()
    return o
end

function M.HasTag(def, tag) return def and SS.Tags.Has(def, tag) end

local function firstTagValue(def, tbl)
    for _, tag in ipairs(def and def.tags or {}) do
        if tbl[tag] ~= nil then return tbl[tag], tag end
    end
end
M.FirstTagValue = firstTagValue

function M.IsPowered(def)
    if not def then return false end
    if def.powered ~= nil then return def.powered end
    if firstTagValue(def, T.powered) then return true end
    return def.cat == "electronics" or def.cat == "lighting"
end

-- Dirt ------------------------------------------------------------------------------------
function M.Dirty(world, obj, amount)
    obj.state = obj.state or {}
    if obj.dirt == nil and obj.state.dirt then obj.dirt = obj.state.dirt end
    obj.state.dirt = nil
    local before = obj.dirt or 0
    obj.dirt = math.max(0, math.min(100, before + amount))
    local was = obj.state.dirty
    obj.state.dirty = obj.dirt >= T.dirtyAt or nil
    if (was and true or false) ~= (obj.state.dirty and true or false) then
        SS.Emit("lotChanged", "state", obj.id)
    end
    W.Touch()
    return obj.dirt
end

-- Breakage ---------------------------------------------------------------------------------
function M.BreakChance(def)
    if def and def.quality and def.quality.breakChance then return def.quality.breakChance end
    return firstTagValue(def, T.breakChance) or 0
end

-- Break an object (state.broken = true); repairs clear it. why: "wear", "event", "misuse".
function M.Break(world, obj, why)
    obj.state = obj.state or {}
    if obj.state.broken then return false end
    obj.state.broken = true
    obj.repairProgress = nil
    if obj.state.on and not SS.Tags.Has(SS.Objects[obj.def] or {}, "fridge") then obj.state.on = false end
    SS.Emit("lotChanged", "state", obj.id)
    SS.Emit("objectBroken", world, obj, why)
    W.Touch()
    local def = SS.Objects[obj.def]
    if world.journal then SS.Actions.Journal(world, (def and def.name or "Something") .. " broke.") end
    -- anyone using an object that just became unusable stops; anyone on the way to it, waiting
    -- for it or stepping onto it takes another one or gives up with the reason (never uses it)
    if SS.Actions.BrokenPolicy(def) == "unavailable" then
        local ids = SS.Sim.ActorIds(world)
        for n = 1, #ids do
            local a = world.actors[ids[n]]
            local act = a and a.act
            if act and not (I[act.iid] and I[act.iid].whenBroken)
                and ((act.target and act.target.oid == obj.id) or act.oid == obj.id) then
                if act.phase == "perform" and (act.committed or act.performed) then
                    act.failWhy = (def and def.name or "It") .. " broke!"
                elseif act.phase ~= "exit" and SS.Actions.Recheck then
                    SS.Actions.Recheck(world, a)
                end
            end
        end
    end
    return true
end

-- The catalogue's quality.dirtRate (its HC-3): a design that gets dirty this many times as fast per
-- use (1 = an ordinary one; a luxury toilet 0.4).
function M.DirtRate(def)
    local r = def and def.quality and def.quality.dirtRate
    if type(r) == "number" and r >= 0 then return r end
    return 1
end

-- Called by the executor at the commit point of every object interaction.
function M.OnUse(world, actor, obj, ia, act)
    local def = SS.Objects[obj.def]
    if not def or def.system then return end
    local dirt = firstTagValue(def, T.dirtPerUse)
    if dirt and not ia.chore then M.Dirty(world, obj, dirt * M.DirtRate(def)) end
    obj.wear = (obj.wear or 0) + T.wearPerUse
    if ia.chore or ia.whenBroken then return end
    -- sitting in something plush is worth a remark now and then (line situation "expensive_chair")
    if def.seat and (def.price or 0) >= T.plushSeatPrice and ia.slot and (ia.pose == "sit" or ia.pose == "read" or ia.pose == "sit_eat")
        and SS.Random(world, "lines") < T.plushRemark then
        SS.Actions.Say(world, actor, "expensive_chair", { objDef = obj.def, price = def.price }, "comfort")
    end
    local p = M.BreakChance(def)
    if p > 0 and not (obj.state and obj.state.broken) then
        local chance = p * (0.5 + math.min(2, (obj.wear or 0) / 100))
        if SS.Random(world, "wear") < chance and M.Break(world, obj, "wear") then
            SS.Actions.Say(world, actor, "broken_object", { objDef = obj.def }, "broken")
        end
    end
end

-- Puddles -----------------------------------------------------------------------------------
function M.PuddleAt(world, level, i, j)
    for _, o in pairs(world.lot.objects) do
        if o.def == "puddle" and o.x == i and o.y == j and (o.level or 0) == level then return o end
    end
end

function M.CountDef(world, defId)
    local n = 0
    for _, o in pairs(world.lot.objects) do if o.def == defId then n = n + 1 end end
    return n
end

function M.SpawnPuddle(world, level, i, j, cause)
    level = level or 0
    if not W.InLot(world.lot, i, j) then return nil end
    if W.Blocked(world, level, i, j) then
        i, j = SS.Nav.NearestFree(world, level, i, j, 2)
        if not i then return nil end
    end
    local p = M.PuddleAt(world, level, i, j)
    if p then
        p.size = math.min(3, (p.size or 1) + 1)
        p.state.stage = p.size
        W.Touch()
        return p
    end
    if M.CountDef(world, "puddle") >= T.maxPuddles then return nil end
    p = M.Spawn(world, "puddle", level, i, j, { size = 1, cause = cause, madeAt = world.time })
    p.state.stage = 1
    SS.Emit("puddle", world, p, cause)
    return p
end

-- Rubbish and clutter --------------------------------------------------------------------------
function M.SpawnTrash(world, level, i, j, units)
    if W.Blocked(world, level, i, j) then
        i, j = SS.Nav.NearestFree(world, level, i, j, 3)
        if not i then return nil end
    end
    for _, o in pairs(world.lot.objects) do
        if o.def == "trash_pile" and o.x == i and o.y == j and (o.level or 0) == level then
            o.units = (o.units or 1) + (units or 1)
            W.Touch()
            return o
        end
    end
    return M.Spawn(world, "trash_pile", level, i, j, { units = units or 1 })
end

function M.SpawnClutter(world, level, i, j, kind)
    local surf, slot
    if SS.Chains and SS.Chains.FindSurfaceNear then surf, slot = SS.Chains.FindSurfaceNear(world, level, i, j, 2, SS.Food.serveKinds) end
    local o
    if surf then o = M.SpawnOnSurface(world, "clutter", surf, slot, { kind = kind })
    else
        if W.Blocked(world, level, i, j) then i, j = SS.Nav.NearestFree(world, level, i, j, 2) end
        if not i then return nil end
        o = M.Spawn(world, "clutter", level, i, j, { kind = kind })
    end
    o.state.stage = kind
    return o
end

-- Bins --------------------------------------------------------------------------------------
function M.BinCapacity(def, outdoor)
    return (def and def.quality and def.quality.capacity) or (outdoor and T.bin.outdoorCap or T.bin.indoorCap)
end

-- Add rubbish units to a bin. Overflow spills a rubbish pile beside it. Returns spilled units.
function M.AddToBin(world, bin, units)
    local def = SS.Objects[bin.def]
    local outdoor = SS.Tags.Has(def, "bin_outdoor")
    local cap = M.BinCapacity(def, outdoor)
    bin.fill = (bin.fill or 0) + units
    bin.state = bin.state or {}
    local spill = 0
    if bin.fill > cap then
        spill = bin.fill - cap
        bin.fill = cap
        local fx, fy = G.rot(1, 0, bin.f or 0)
        M.SpawnTrash(world, bin.level or 0, bin.x + fx, bin.y + fy, spill)
        SS.Emit("binOverflow", world, bin)
    end
    local full = bin.fill >= cap
    if (bin.state.full and true or false) ~= full then bin.state.full = full or nil; SS.Emit("lotChanged", "state", bin.id) end
    W.Touch()
    return spill
end

-- Repairs ------------------------------------------------------------------------------------
function M.RepairDifficulty(def)
    local d = def and def.quality and def.quality.repairDifficulty
    if d then return d end
    if M.IsPowered(def) then return 2 end
    return 1
end

function M.RepairMinutes(def, actor)
    local mech = SS.Skills and SS.Skills.Level and SS.Skills.Level(actor, "mechanical") or 0
    return T.repair.base * M.RepairDifficulty(def) / (1 + mech * T.repair.perSkill)
end

function M.RepairChance(def, actor)
    local mech = SS.Skills and SS.Skills.Level and SS.Skills.Level(actor, "mechanical") or 0
    local R = T.repair
    return SS.U.clamp(R.success + mech * R.successPerSkill - (M.RepairDifficulty(def) - 1) * R.perDifficulty, R.minSuccess, R.maxSuccess)
end

function M.ShockChance(def, actor)
    if not M.IsPowered(def) then return 0 end
    local mech = SS.Skills and SS.Skills.Level and SS.Skills.Level(actor, "mechanical") or 0
    local S = T.shock
    return math.max(0, S.base * (1 - mech * S.perSkill) + (M.RepairDifficulty(def) - 1) * S.perDifficulty)
end

-- The shock check for one electrical repair attempt: "ok" | "shock" | "fatal". The events
-- module's SS.Hazards.Electrocute(world, actor, obj) rolls and applies the outcome when present
-- (risk from mechanical skill and standing water); otherwise M.ShockChance is rolled here and a
-- shock is a non-lethal jolt.
function M.ShockCheck(world, actor, obj)
    if SS.Hazards and SS.Hazards.Electrocute then
        local ok, r = pcall(SS.Hazards.Electrocute, world, actor, obj)
        if not ok then SS.Log("Electrocute hook failed: %s", tostring(r)); r = "ok" end
        if r ~= "ok" and r ~= "shock" and r ~= "fatal" then r = "ok" end
        if r ~= "ok" then SS.Emit("shock", world, actor, obj, r) end
        return r
    end
    local p = M.ShockChance(SS.Objects[obj.def], actor)
    if p <= 0 or SS.Random(world, "repair") >= p then return "ok" end
    SS.Emit("shock", world, actor, obj, "shock")
    SS.Needs.Add(actor, "energy", -15)
    SS.Needs.Add(actor, "hygiene", -20)
    SS.Needs.Add(actor, "comfort", -20)
    SS.Needs.Feel(world, actor, "frustrated", 1.5)
    SS.Actions.Message(world, actor, (actor.name or "Someone") .. " got a nasty jolt from the wiring.", "danger")
    return "shock"
end

-- Menu forecast for an electrical repair: chance per attempt and whether water is close by.
function M.ShockRisk(world, actor, obj)
    local def = obj and SS.Objects[obj.def]
    if not M.IsPowered(def) then return 0, false end
    if SS.Hazards and SS.Hazards.ElectricRisk then
        local ok, c, wet = pcall(SS.Hazards.ElectricRisk, world, actor, obj)
        if ok and type(c) == "number" then return c, wet and true or false end
    end
    return M.ShockChance(def, actor), false
end

-- Mark a broken object repaired (household repairs and the repair technician). how: "self" |
-- "service"; a professional repair also resets wear. Returns true when it was broken.
function M.Repair(world, obj, actor, how)
    if not (obj and obj.state and obj.state.broken) then return false end
    obj.state.broken = nil
    obj.repairProgress = nil
    obj.wear = (how == "service") and 0 or math.floor((obj.wear or 0) * 0.5)
    SS.Emit("lotChanged", "state", obj.id)
    SS.Emit("objectRepaired", world, obj, actor)
    W.Touch()
    return true
end

-- Clean-up done by someone else's interaction (the cleaner service): household-core removes or
-- resets its own mess. what: "puddle" | "dishes" | "rubbish" | "bin" | "fixture". Returns true
-- when handled here; nil when the object isn't one of ours (the caller deals with it).
function M.Clean(world, obj, actor, what)
    if not (obj and world.lot.objects[obj.id]) then return nil end
    local d = obj.def
    if (what == "puddle" and d == "puddle") or (what == "dishes" and d == "plate_dirty")
        or (what == "rubbish" and (d == "trash_pile" or d == "trash_bag" or d == "clutter")) then
        M.Remove(world, obj)
        return true
    end
    local def = SS.Objects[d]
    if what == "bin" and def and (SS.Tags.Has(def, "bin") or SS.Tags.Has(def, "bin_outdoor")) then
        obj.fill = 0
        obj.state = obj.state or {}
        obj.state.full = nil
        SS.Emit("lotChanged", "state", obj.id)
        W.Touch()
        return true
    end
    if what == "fixture" and def and not def.system then
        M.Dirty(world, obj, -100)
        return true
    end
    return nil
end

-- Messes made by other modules join the one mess system (room score, clean-up adverts, the
-- cleaner service, pests): kind "plates" | "rubbish" | "puddle" | "clutter"; opts = { count
-- (plates, 1-6, default 3), units (rubbish), cause (puddle), clutter (book|cup|wrapper|newspaper) }.
-- Returns the object, or nil for other kinds ("pet": the family module keeps its own pet mess with
-- its own clean-up and house-training) or when there's no room for it.
function M.Mess(world, kind, i, j, level, opts)
    opts = opts or {}
    level = level or 0
    if not (i and j and W.InLot(world.lot, i, j)) then return nil end
    if kind == "puddle" then return M.SpawnPuddle(world, level, i, j, opts.cause or "mess") end
    if kind == "rubbish" then return M.SpawnTrash(world, level, i, j, opts.units or 1) end
    if kind == "clutter" then return M.SpawnClutter(world, level, i, j, opts.clutter or "wrapper") end
    if kind == "plates" then
        local n = math.max(1, math.min(6, math.floor(opts.count or 3)))
        local surf, slot
        if SS.Chains and SS.Chains.FindSurfaceNear then surf, slot = SS.Chains.FindSurfaceNear(world, level, i, j, 2, SS.Food.serveKinds) end
        local o
        if surf then
            o = M.SpawnOnSurface(world, "plate_dirty", surf, slot, { count = n })
        else
            if W.Blocked(world, level, i, j) then i, j = SS.Nav.NearestFree(world, level, i, j, 2) end
            if not i then return nil end
            o = M.Spawn(world, "plate_dirty", level, i, j, { count = n })
        end
        o.state.stage = n
        return o
    end
    return nil
end

-- Interactions -------------------------------------------------------------------------------
local function neatRates(actor, base)
    local neat = actor.personality and actor.personality.neat or 5
    local r = {}
    for k, v in pairs(base or {}) do r[k] = v end
    r.fun = (r.fun or 0) + (neat - 5) * 2
    return r
end
M.NeatRates = neatRates

local function choreAdvert(amount)
    return function(world, actor, obj) return { room = amount } end
end

local function heldIs(actor, kind) return actor.held and actor.held.kind == kind end

-- Clean a dirty fixture.
I.scrub = {
    label = "Clean", category = "Chores", slot = { "front", "use", "stand", "seat" }, pose = "clean", chore = "scrub", noWear = true,
    traits = { neat = 1 }, guestForbidden = true, service = true, ages = { adult = true, child = true },
    test = function(world, actor, obj)
        if (obj.dirt or 0) < 15 then return false, "It's already clean." end
        return true
    end,
    advertise = function(world, actor, obj)
        local d = obj.dirt or 0
        if d < 30 then return nil end
        return SS.Actions.Advert("m419", "room", 10 + d * 0.3)
    end,
    onStart = function(world, actor, act, obj)
        act.dur = T.scrubMinutes.base + (obj.dirt or 0) * T.scrubMinutes.perDirt
        act.data.dirt0 = obj.dirt or 0
        act.rates = neatRates(actor, { hygiene = -4, energy = -2 })
    end,
    onTick = function(world, actor, act, obj, dt)
        if not obj then return end
        local d0 = act.data.dirt0 or 0
        M.Dirty(world, obj, -d0 * dt / math.max(1, act.dur or 5))
    end,
    onEnd = function(world, actor, act, obj, status)
        if obj and status == "done" then M.Dirty(world, obj, -100) end
    end,
}

-- Repair a broken object (progress is kept on the object between attempts).
I.repair = {
    label = "Repair", category = "Chores", slot = { "front", "use", "stand", "seat", "bed" }, pose = "repair", carry = "wrench", chore = "repair",
    exertion = 1, whenBroken = true, noWear = true, requireState = { broken = true }, requireText = "It isn't broken.",
    traits = { neat = 0.3, active = 0.3 }, guestForbidden = true, service = true, ages = { adult = true },
    advertise = function(world, actor, obj)
        local def = SS.Objects[obj.def]
        local mech = SS.Skills and SS.Skills.Level and SS.Skills.Level(actor, "mechanical") or 0
        local base = 18 + mech * 3
        local m = 1
        if M.IsPowered(def) and mech < 2 then m = 0.4 end -- people avoid wiring they don't understand
        local adv = SS.Actions.Advert("m:repair", "room", base * m)
        -- fixing it is the way back to what it is for: a broken shower is worth mending when
        -- someone needs a wash (half the relief its own actions offer)
        for _, iid in ipairs(def and def.actions or {}) do
            local ia = I[iid]
            if ia and not ia.whenBroken and not ia.chore and type(ia.advert) == "table" then
                for need, amt in pairs(ia.advert) do
                    if amt > 0 then adv[need] = math.max(adv[need] or 0, amt * T.repair.blockedShare * m) end
                end
            end
        end
        return adv
    end,
    onStart = function(world, actor, act, obj)
        local def = SS.Objects[obj.def]
        act.data.need = M.RepairMinutes(def, actor)
        act.rates = neatRates(actor, { hygiene = -5 })
        act.skill = { mechanical = T.repair.skill }
    end,
    onResume = function(world, actor, act, obj)
        act.rates = neatRates(actor, { hygiene = -5 })
        act.skill = { mechanical = T.repair.skill }
    end,
    onTick = function(world, actor, act, obj, dt)
        if not obj then return end
        obj.repairProgress = (obj.repairProgress or 0) + dt
        local need = act.data.need or 30
        -- electrical risk once per attempt, half way through (events decides the outcome)
        if not act.data.shockRolled and obj.repairProgress >= need * 0.5 then
            act.data.shockRolled = true
            if M.IsPowered(SS.Objects[obj.def]) then
                local r = M.ShockCheck(world, actor, obj)
                if r ~= "ok" then
                    act.data.shocked = r
                    if actor.act == act then act.failWhy = (r == "fatal") and "A severe shock." or "Got a shock; the repair stopped." end
                    return
                end
            end
        end
        if obj.repairProgress >= need then
            -- the work is done: it either holds or it doesn't. A failed attempt ends as "failed"
            -- (the service module retries on its own terms; the household gets a cooldown).
            -- Whoever orders a professional may set the odds: data.success (0..1).
            local def = SS.Objects[obj.def]
            obj.repairProgress = nil
            local chance = type(act.data.success) == "number" and act.data.success or M.RepairChance(def, actor)
            if SS.Random(world, "repair") < chance then
                act.data.fixed = true
                act.complete = true
            else
                act.data.failed = true
                if not act.manual then SS.Needs.Feel(world, actor, "frustrated") end
                SS.Emit("repairFailed", world, obj, actor)
                act.failWhy = "The repair didn't take. The " .. (def and def.name or "thing") .. " is still broken."
            end
        end
    end,
    onEnd = function(world, actor, act, obj, status)
        if not obj or status ~= "done" or not act.data.fixed then return end
        local def = SS.Objects[obj.def]
        M.Repair(world, obj, actor, (actor.role and "service") or "self")
        SS.Actions.Message(world, actor, (def and def.name or "It") .. " works again.", "repair")
        SS.Needs.Feel(world, actor, "proud", 0.5)
    end,
}

-- Menu forecast (SS.Actions.Hint): electrical repairs say how risky they are.
I.repair.hint = function(world, actor, obj)
    local chance, wet = M.ShockRisk(world, actor, obj)
    if not chance or chance <= 0 then return nil end
    return string.format("Risky: %d%% chance of a shock%s.", math.floor(chance * 100 + 0.5), wet and " (standing water nearby)" or "")
end

-- Mop up a puddle.
I.mop = {
    label = "Mop Up", category = "Chores", slot = "around", pose = "clean", carry = "mop", chore = "mop", dur = 3, noWear = true,
    traits = { neat = 1 }, guestForbidden = true, service = true, ages = { adult = true, child = true },
    advertise = choreAdvert(30),
    onStart = function(world, actor, act, obj)
        act.rates = neatRates(actor, { hygiene = -2 })
        act.dur = 2 + (obj.size or 1)
    end,
    onEnd = function(world, actor, act, obj, status)
        if obj and status == "done" then act.removing = true; M.Remove(world, obj) end
    end,
}

-- Rubbish piles become a bag that goes out.
I.clean_trash = {
    label = "Clean Up Rubbish", category = "Chores", slot = "around", pose = "clean", chore = "rubbish", dur = 4, noWear = true, keepHeld = false,
    traits = { neat = 1 }, guestForbidden = true, service = true, ages = { adult = true, child = true },
    advertise = choreAdvert(34),
    onStart = function(world, actor, act, obj) act.rates = neatRates(actor, { hygiene = -6 }) end,
    onEnd = function(world, actor, act, obj, status)
        if obj and status == "done" then
            act.removing = true
            M.Remove(world, obj)
            SS.Chains.Hold(world, actor, "bag", { units = obj.units or 1 })
        end
    end,
    next = function(world, actor, act) return M.BagOrder(world, actor) end,
}

I.take_out_bag = {
    label = "Take Out", category = "Chores", slot = "around", pose = "use", dur = 0.5, chore = true, noWear = true,
    traits = { neat = 0.8 }, householdOnly = true, service = true, ages = { adult = true, child = true },
    test = function(world, actor, obj)
        if obj.curb then return false, "It's waiting for collection." end
        return true
    end,
    advertise = function(world, actor, obj) if obj.curb then return nil end return SS.Actions.Advert("m557", "room", 24) end,
    onEnd = function(world, actor, act, obj, status)
        if obj and status == "done" then
            act.removing = true
            M.Remove(world, obj)
            SS.Chains.Hold(world, actor, "bag", { units = obj.units or 1 })
        end
    end,
    next = function(world, actor, act) return M.BagOrder(world, actor) end,
}

-- Put things away / in the bin.
I.tidy_clutter = {
    label = "Tidy Up", category = "Chores", slot = "around", pose = "clean", chore = true, dur = 1.5, noWear = true,
    traits = { neat = 1.2 }, householdOnly = true, service = true, ages = { adult = true, child = true },
    advertise = choreAdvert(16),
    onEnd = function(world, actor, act, obj, status)
        if obj and status == "done" then
            local kind = obj.kind
            SS.Chains.GrumbleAbout(world, actor, obj)
            act.removing = true
            M.Remove(world, obj)
            if kind == "wrapper" or kind == "newspaper" then SS.Chains.Hold(world, actor, "trash", { units = 1 })
            elseif kind == "cup" then SS.Chains.Hold(world, actor, "dirty", { cup = true }) end
        end
    end,
    next = function(world, actor, act)
        if heldIs(actor, "trash") then return SS.Chains.DisposeOrder(world, actor) end
        if heldIs(actor, "dirty") then return SS.Chains.DishOrder(world, actor) end
    end,
}

-- Empty an indoor bin into a bag.
I.empty_bin = {
    label = "Empty Bin", category = "Chores", slot = { "front", "use" }, pose = "use", chore = "empty_bin", dur = 2, noWear = true,
    traits = { neat = 1 }, guestForbidden = true, service = true, ages = { adult = true, child = true },
    test = function(world, actor, obj)
        if (obj.fill or 0) <= 0 then return false, "It's empty." end
        if actor.held then return false, "Hands are full." end
        return true
    end,
    advertise = function(world, actor, obj)
        local def = SS.Objects[obj.def]
        local cap = M.BinCapacity(def, false)
        local frac = (obj.fill or 0) / cap
        if frac < 0.6 then return nil end
        return SS.Actions.Advert("m603", "room", 20 + frac * 25)
    end,
    onEnd = function(world, actor, act, obj, status)
        if obj and status == "done" then
            local units = obj.fill or 0
            obj.fill = 0
            if obj.state then obj.state.full = nil end
            SS.Emit("lotChanged", "state", obj.id)
            W.Touch()
            SS.Chains.Hold(world, actor, "bag", { units = math.max(1, math.ceil(units / 4)) })
        end
    end,
    next = function(world, actor, act) return M.BagOrder(world, actor) end,
}

-- Carry a bag to the outdoor bin.
I.put_out_trash = {
    usesHeld = { bag = true },
    label = "Put Out Trash", category = "Chores", slot = { "front", "use" }, pose = "use", dur = 1, noWear = true, keepHeld = false,
    householdOnly = true, service = true, ages = { adult = true, child = true }, manualOnly = true,
    test = function(world, actor, obj)
        if not heldIs(actor, "bag") then return false, "Nothing to put out." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        if not obj or status ~= "done" or not heldIs(actor, "bag") then return end
        local def = SS.Objects[obj.def]
        local cap = M.BinCapacity(def, true)
        if (obj.fill or 0) >= cap then
            -- full: the bag waits beside it for collection
            local fx, fy = G.rot(1, 0, obj.f or 0)
            local i, j = obj.x + fx, obj.y + fy
            if W.Blocked(world, obj.level or 0, i, j) then i, j = SS.Nav.NearestFree(world, obj.level or 0, obj.x, obj.y, 2) end
            if i then M.Spawn(world, "trash_bag", obj.level or 0, i, j, { units = actor.held.units or 1, curb = true }) end
            SS.Actions.Message(world, actor, "The outdoor bin is full; the bag waits beside it for collection.", "trash")
        else
            obj.fill = (obj.fill or 0) + 1
            obj.state = obj.state or {}
            if obj.fill >= cap then obj.state.full = true end
            SS.Emit("lotChanged", "state", obj.id)
        end
        actor.held, actor.carry = nil, nil
    end,
}

-- No outdoor bin: the bag goes to the curb by the lot entry.
I.curb_bag = {
    usesHeld = { bag = true },
    label = "Put Bag by the Curb", category = "Chores", slot = "cell", pose = "use", dur = 0.5, noWear = true, manualOnly = true,
    householdOnly = true, service = true, ages = { adult = true, child = true },
    test = function(world, actor) if not heldIs(actor, "bag") then return false, "Nothing to put out." end return true end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not heldIs(actor, "bag") then return end
        local i, j = math.floor(actor.x), math.floor(actor.y)
        M.Spawn(world, "trash_bag", actor.level or 0, i, j, { units = actor.held.units or 1, curb = true })
        actor.held, actor.carry = nil, nil
    end,
}

-- Order to dispose of a carried bag: outdoor bin, else the curb.
function M.BagOrder(world, actor)
    if not heldIs(actor, "bag") then return nil end
    local bin = SS.Chains.FindUsable(world, actor, { "bin_outdoor" }, "put_out_trash")
    if bin then return { oid = bin.id, iid = "put_out_trash" } end
    local i, j
    if SS.Street and SS.Street.EntryCell then i, j = SS.Street.EntryCell(world) end
    if not (i and j) then i, j = math.floor(world.lot.w / 2), world.lot.h - 1 end
    if W.Blocked(world, 0, i, j) then i, j = SS.Nav.NearestFree(world, 0, i, j, 3) end
    if i then return { iid = "curb_bag", x = i, y = j, level = 0 } end
end

-- Systems ------------------------------------------------------------------------------------
local PLUMBING = { toilet = true, shower = true, bath = true, basin = true, sink = true, dishwasher = true }
local function isPlumbing(def)
    for _, t in ipairs(def and def.tags or {}) do if PLUMBING[t] then return true end end
    return false
end
M.IsPlumbing = isPlumbing

function M.Hour(world, h)
    local hourOfDay = h % 24
    local day = math.floor(h / 24)
    local ids = W.ObjectIds(world)
    for n = 1, #ids do
        local o = world.lot.objects[ids[n]]
        if o then
            local def = SS.Objects[o.def]
            -- broken plumbing leaks
            if o.state and o.state.broken and isPlumbing(def) then
                o.leaks = o.leaks or 0
                if o.leaks < T.leakCap and SS.Random(world, "leak") < T.leakPerHour then
                    local k = SS.RandomInt(world, "leak", 0, 3)
                    local d = G.DIRS[k]
                    if M.SpawnPuddle(world, o.level or 0, o.x + d[1], o.y + d[2], "leak") then o.leaks = o.leaks + 1 end
                end
            elseif o.leaks and not (o.state and o.state.broken) then
                o.leaks = nil
            end
            -- outdoor puddles dry
            if o.def == "puddle" and W.ObjRoom(world, o) == 0 and world.time - (o.madeAt or world.time) >= T.outdoorDryHours * 60 then
                M.Remove(world, o)
            end
        end
    end
    -- rubbish collection
    if hourOfDay == T.bin.collectHour and T.bin.collectDays[day % 7] then
        local collected = 0
        for n = 1, #ids do
            local o = world.lot.objects[ids[n]]
            local def = o and SS.Objects[o.def]
            if o and def and SS.Tags.Has(def, "bin_outdoor") and (o.fill or 0) > 0 then
                collected = collected + o.fill
                o.fill = 0
                if o.state then o.state.full = nil end
                SS.Emit("lotChanged", "state", o.id)
            elseif o and o.def == "trash_bag" and o.curb then
                collected = collected + 1
                M.Remove(world, o)
            end
        end
        if collected > 0 then SS.Emit("trashCollected", world, collected) end
    end
end

-- Effect descriptors for the renderer (ARCHITECTURE §10: modules add effect draw items; art draws
-- them). Household-core makes its visible states legible: zzz over sleepers, steam from cooking
-- pots and running showers, water from running fixtures and leaks, notes from music, stink from
-- rubbish, spoiled food and very unwashed people, smoke from burnt food on live heat, sparks from
-- broken electrical objects. Items: { fx, level, x, y, z, ref } in lot cell coordinates (x, y are
-- cell centres or actor positions; z in tiles above the floor). Bounded by Tuning.fxCap.
local MUSIC_TAGS = { "stereo", "radio", "dj" }
local FX_PLAYING = { play_instrument = "notes", dj_spin = "notes" }
local function hasAny(def, tags)
    for n = 1, #tags do if SS.Tags.Has(def, tags[n]) then return true end end
    return false
end
-- Effect records are reused: the renderer copies them into its own draw items every frame
-- (Render/Effects.lua Collect), so the records handed out by one call are overwritten by the next.
local FX_POOL, fxUsed, fxOut, fxCap = {}, 0, nil, 0
local BIN_TAGS = { "bin", "bin_outdoor" }
local function addFx(fx, level, x, y, z, ref)
    if #fxOut >= fxCap then return end
    fxUsed = fxUsed + 1
    local r = FX_POOL[fxUsed]
    if not r then r = {}; FX_POOL[fxUsed] = r end
    r.fx, r.level, r.x, r.y, r.z, r.ref = fx, level or 0, x, y, z, ref
    fxOut[#fxOut + 1] = r
end

function M.Effects(world, out)
    out = out or {}
    fxOut, fxCap, fxUsed = out, T.fxCap, 0
    local add = addFx
    for id, a in pairs(world.actors) do
        local lv = a.level or 0
        if a.sleeping then add("zzz", lv, a.x, a.y, 1.1, id) end
        if a.needs and not a.noNeeds and (a.needs.hygiene or 0) <= T.stinkAt then add("stink", lv, a.x, a.y, 1.0, id) end
        local act = a.act
        if act and act.phase == "perform" and FX_PLAYING[act.iid] then add(FX_PLAYING[act.iid], lv, a.x, a.y, 1.6, id) end
    end
    for id, o in pairs(world.lot.objects) do
        local st = o.state
        if st then
            local def = SS.Objects[o.def]
            local lv = o.level or 0
            local x, y = o.x + 0.5, o.y + 0.5
            -- running water is the flag itself (Chains' waterOn); garden objects keep a 0..100
            -- moisture level in the same field, which is no running tap (family's HC-15)
            if st.water == true then add(SS.Tags.Has(def, "shower") and "steam" or "water", lv, x, y, 1.0, id)
            elseif st.on == true and def and SS.Tags.Has(def, "shower") and SS.Tags.Has(def, "bath") then
                add("steam", lv, x, y, 1.0, id)   -- a shower running in a bath (Chains' waterOn: its spray is `on`)
            end
            if st.cooking and not (o.parent or o.appliance) then add("steam", lv, x, y, 1.0, id) end
            if st.burnt and (o.appliance or o.parent) then
                local heat = world.lot.objects[o.appliance or o.parent]
                if heat and heat.state and heat.state.cooking then add("smoke", lv, x, y, 1.1, id) end
            end
            if st.on and def and hasAny(def, MUSIC_TAGS) then add("notes", lv, x, y, 1.2, id) end
            if st.spoiled or (st.full and def and hasAny(def, BIN_TAGS)) then add("stink", lv, x, y, 0.6, id) end
            if st.broken and def and M.IsPowered(def) then add("sparks", lv, x, y, 0.8, id) end
            if st.broken and o.leaks and o.leaks > 0 then add("water", lv, x, y, 0.2, id) end
        end
        if o.def == "trash_pile" then add("stink", o.level or 0, o.x + 0.5, o.y + 0.5, 0.4, id) end
    end
    fxOut = nil
    return out
end

SS.Sim.Register({ name = "core.maintenance", order = 45, hour = function(world, h) M.Hour(world, h) end,
    attach = function(world)
        -- register once with the renderer when it exists (it loads after the simulation files)
        if not M.fxRegistered and SS.Render and SS.Render.RegisterEffects then
            M.fxRegistered = true
            SS.Render.RegisterEffects(function(w, cam, out) M.Effects(w, out) end)
        end
    end })

-- Attach behaviour by tag (ARCHITECTURE.md 7). -----------------------------------------------
M.DIRT_TAGS = { "toilet", "shower", "bath", "basin", "sink", "stove", "oven", "microwave", "grill", "counter", "fridge",
    "dishwasher", "coffee", "toaster", "table_dining" }
M.BREAK_TAGS = { "toilet", "shower", "bath", "basin", "sink", "dishwasher", "fridge", "stove", "oven", "microwave", "coffee",
    "toaster", "tv", "stereo", "radio", "computer", "game", "lamp", "clock_alarm", "arcade", "pinball", "exercise", "bed",
    "bed_child", "seat", "sofa", "piano", "instrument", "grill", "dj", "easel", "workbench", "telescope" }
for _, tag in ipairs(M.DIRT_TAGS) do SS.Tags.Attach(tag, "scrub") end
for _, tag in ipairs(M.BREAK_TAGS) do SS.Tags.Attach(tag, "repair") end
SS.Tags.Attach("bin", "empty_bin")
SS.Tags.Attach("bin_outdoor", "put_out_trash")   -- on the bin's menu while carrying a bag
