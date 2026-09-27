-- SideStreet interaction definitions shared by the executor (Sim/Actions.lua).
-- Owner: household-core module. Field reference: ARCHITECTURE.md 8 and docs/modules/household-core.md.
-- This file holds the data part of the everyday interactions (labels, slots, poses, durations,
-- effects, adverts). Behaviour (onStart/onTick/onEnd/next, advertise functions, tests) is added
-- by Sim/Chains.lua, Sim/Maintenance.lua and Sim/Leisure.lua, and attached to objects by tag.
-- Other modules add their own interactions in their own files (SS.Interactions.<id> = {...})
-- and attach them with SS.Tags.Attach(tag, id).
--
-- gain  = total change over the whole duration (applied incrementally, so an interrupted action
--         gives only the part already performed).
-- rate  = change per sim hour while performing (object `rates` override these).
-- Extra executor fields used here: estimate (minutes, for scoring), exertion (0..3), chore,
-- leisure, privacy, outfit, sleeping, wakeOn, traits = { trait = weight }, topic, noise, risk,
-- hidden (chain steps, never on a menu), useTags (objects that can host a hidden step),
-- redirect(world, actor, order) -> order, keepHeld, whenBroken, householdOnly, service, ages, kinds,
-- usesHeld = { heldKind = true } (a player order for this keeps the matching carried item in hand),
-- noInterrupt (need-critical: other modules never pull someone out of it for a doorbell or a phone
-- call; sleeping actions are treated the same), guestForbidden (guests may not; service may).
local _, SS = ...
SS.Interactions = SS.Interactions or {}
local I = SS.Interactions

local ADULT_CHILD = { adult = true, child = true }

local base = {
    -- Food: a quick bite from the fridge (never a full meal; cooking is the chain in Sim/Chains.lua).
    -- Less than the smallest cooked portion (SS.Food.snack), and each snack soon after another
    -- fills less (Tuning.food.snackRepeat, applied in Sim/Chains.lua), so the fridge is no refill.
    snack = {
        label = "Have a Snack", category = "Food", slot = { "front", "use" }, pose = "eat_stand", carry = "snack", dur = 15,
        cost = 4, ledger = "Groceries: snack", ledgerCat = "food", ages = ADULT_CHILD,
        gain = { hunger = 12, bladder = -4 }, advert = { hunger = 12 },
    },

    -- Sleep and rest ----------------------------------------------------------------------
    sleep = {
        label = "Sleep", category = "Rest", slot = "bed", pose = "sleep", sleeping = true, maxDur = 600, outfit = "sleep",
        rate = { energy = 12, comfort = 8 }, untilFull = "energy", holdNight = true, advert = { energy = 70, comfort = 10 },
        wakeOn = { bladder = -75, hunger = -75 }, ages = ADULT_CHILD,
    },
    nap = {
        label = "Nap", category = "Rest", slot = "bed", pose = "sleep", sleeping = true, dur = 90,
        rate = { energy = 12, comfort = 8 }, advert = { energy = 25, comfort = 10 },
        wakeOn = { bladder = -60, hunger = -60 }, ages = ADULT_CHILD,
    },
    sofa_nap = {
        label = "Nap on the Sofa", category = "Rest", slot = { "lie", "seat" }, pose = "lie", sleeping = true, dur = 60,
        rate = { energy = 7, comfort = 6 }, advert = { energy = 18, comfort = 8 },
        wakeOn = { bladder = -60, hunger = -60 }, ages = ADULT_CHILD,
    },
    relax_bed = {
        label = "Lie Down", category = "Rest", slot = "bed", pose = "lie", maxDur = 45,
        rate = { comfort = 22, energy = 2 }, untilFull = "comfort", advert = { comfort = 22 }, ages = ADULT_CHILD,
    },
    make_bed = {
        label = "Make the Bed", category = "Chores", slot = "bed", pose = "clean", dur = 2, chore = true, noWear = true,
        requireState = { unmade = true }, requireText = "The bed is already made.", traits = { neat = 1 },
        householdOnly = true, service = true, ages = ADULT_CHILD,
    },

    -- Bathroom ----------------------------------------------------------------------------
    toilet = {
        label = "Use Toilet", category = "Bathroom", slot = "seat", pose = "sit", dur = 8, privacy = true, noInterrupt = true,
        gain = { bladder = 200, hygiene = -2 }, advert = { bladder = 90 }, ages = ADULT_CHILD,
    },
    shower = {
        label = "Take a Shower", category = "Bathroom", slot = "stand", pose = "shower", dur = 20, privacy = true, noInterrupt = true,
        gain = { hygiene = 160, comfort = 6 }, advert = { hygiene = 70 }, ages = ADULT_CHILD,
    },
    bathe = {
        label = "Take a Bath", category = "Bathroom", slot = { "bath", "stand", "seat" }, pose = "bathe", dur = 35, privacy = true, noInterrupt = true,
        gain = { hygiene = 170, comfort = 30, fun = 6 }, advert = { hygiene = 60, comfort = 25 }, ages = ADULT_CHILD,
    },
    washhands = {
        label = "Wash Hands", category = "Bathroom", slot = { "front", "use" }, pose = "wash", dur = 3,
        gain = { hygiene = 12 }, advert = { hygiene = 8 }, ages = ADULT_CHILD,
    },

    -- Seating -----------------------------------------------------------------------------
    sit = {
        label = "Sit", category = "Rest", slot = "seat", pose = "sit", maxDur = 60,
        rate = { comfort = 25 }, untilFull = "comfort", advert = { comfort = 30 }, ages = ADULT_CHILD,
    },

    -- Television (channels, capacity and skills: Sim/Leisure.lua) --------------------------
    watchtv = {
        label = "Watch TV", category = "Fun", slot = "viewer", pose = "idle", maxDur = 120, leisure = true,
        rate = { fun = 28 }, untilFull = "fun", advert = { fun = 40, comfort = 8 }, usesState = "on", ages = ADULT_CHILD,
        group = true, traits = { playful = 0.3, active = -0.3 },
    },

    -- Lights and clocks -------------------------------------------------------------------
    lampon = {
        label = "Turn On", category = "Home", slot = { "front", "use" }, pose = "use", dur = 0.5, setState = { on = true },
        requireState = { on = false }, requireText = "It's already on.", noWear = true, ages = ADULT_CHILD,
    },
    lampoff = {
        label = "Turn Off", category = "Home", slot = { "front", "use" }, pose = "use", dur = 0.5, setState = { on = false },
        advert = {}, manualOnly = true, requireState = { on = true }, requireText = "It's already off.", noWear = true, ages = ADULT_CHILD,
    },
    set_alarm = {
        label = "Set Alarm", category = "Home", slot = { "front", "use" }, pose = "use", dur = 0.3, manualOnly = true,
        noWear = true, ages = ADULT_CHILD,
    },
    alarm_off = {
        label = "Alarm Off", category = "Home", slot = { "front", "use" }, pose = "use", dur = 0.3, noWear = true,
        ages = ADULT_CHILD,
    },
}
for k, v in pairs(base) do I[k] = v end
