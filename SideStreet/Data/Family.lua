-- SideStreet family tuning: household growth, infants and children, child welfare, parties.
-- Owner: family module (docs/modules/family.md). Every price, period and threshold lives here,
-- not in code. Times are sim minutes, rates are per sim hour, needs use the -100..100 scale.
local _, SS = ...

SS.FamilyData = {
    -- Household capacity (brief §9: 1-8 controllable members). Pets are counted separately.
    capacity = 8,
    petMax = 2,                  -- declared actor budget: at most 2 pets per household

    -- Family's mess objects (party plates and rubbish, pet accidents) name household-core's mess
    -- kinds. Where the room score has no mess kinds (the pre-integration stub), this decoration
    -- penalty stands in for them.
    messEnv = { plate = -4, trash = -5, puddle = -6 },

    -- Special lot-less households that hold people in care (never playable, never shown as a bin
    -- household by the family UI). Created on demand with stable ids.
    servicesHousehold = { id = "hh_family_services", name = "Linden Hollow Family Services" },
    shelterHousehold = { id = "hh_pet_shelter", name = "Linden Hollow Animal Shelter" },

    -- Service NPCs (stable identities, one person each; visitors framework roles). `outfit` is the
    -- uniform style of their work outfit (look.outfits.work.style), one of the art module's person
    -- outfits (SS.Art.person.outfits: "welfare" is the welfare officer the visitors framework also
    -- uses, "courier" has a cap and satchel, "gardener_apron" a half apron and boots), drawn in the
    -- colours of `look`. An unknown style would be drawn as the plain "work" outfit.
    npcs = {
        npc_family_services = { name = "Odile Brannock", role = "family_services", pronoun = "she", outfit = "welfare",
            look = { skin = { 0.55, 0.38, 0.27 }, hair = { 0.16, 0.12, 0.10 }, hairStyle = "long",
                top = { 0.30, 0.36, 0.52 }, bottom = { 0.22, 0.22, 0.26 }, shoes = { 0.18, 0.14, 0.12 } },
            bio = "Caseworker for Linden Hollow Family Services. Carries a clipboard and a spare pacifier." },
        npc_pet_courier = { name = "Harlan Pike", role = "pet_courier", pronoun = "he", outfit = "courier",
            look = { skin = { 0.93, 0.76, 0.62 }, hair = { 0.72, 0.52, 0.24 }, hairStyle = "short",
                top = { 0.25, 0.55, 0.33 }, bottom = { 0.40, 0.34, 0.24 }, shoes = { 0.30, 0.20, 0.12 } },
            bio = "Delivers animals for the pet shop and the shelter. Covered in a fine layer of fur." },
        npc_produce_buyer = { name = "Merritt Vance", role = "produce_buyer", pronoun = "they", outfit = "gardener_apron",
            look = { skin = { 0.76, 0.56, 0.40 }, hair = { 0.30, 0.22, 0.16 }, hairStyle = "short",
                top = { 0.70, 0.46, 0.20 }, bottom = { 0.25, 0.30, 0.22 }, shoes = { 0.28, 0.20, 0.14 } },
            bio = "Buys backyard vegetables for the Corner Greengrocer. Judges tomatoes by the pound." },
    },

    -- Service visits: arrival delay after the request (min..max minutes, seeded), how long the
    -- worker may try to reach the door before working from where they stand, spawn retries.
    visit = { approachTimeout = 45, spawnRetries = 2, retryDelay = 60, performDur = 6,
        removalReturns = 2 },   -- a refused removal visit comes back this many times, then is carried out by the office

    -- Moving in (social menu "Ask to Move In"): the target's feelings toward the asker.
    moveIn = { minLife = 40, minDaily = 15, rejectCooldown = 360, rejectDaily = -6 },
    -- Money rule when someone moves in (explicit, shown before confirming):
    --   "sole": if the mover was the only member of their old household, that household's cash comes
    --   with them in one ledger entry and the old household closes; otherwise no money moves.
    moveInMoney = "sole",

    -- Commitment: "Propose Commitment", then "Hold Commitment Ceremony".
    propose = { askerMinLife = 50, minLife = 60, minDaily = 30, rejectCooldown = 720, rejectDaily = -10 },
    ceremony = { dur = 30, lifeBonus = 10, cheerDur = 20 },

    -- New children. Both need an adult, free capacity and money.
    baby = { planCost = 300, minFunds = 800, dueMinutes = 2 * 1440, partnerMinLife = 50 },
    adoption = { fee = 250, minFunds = 400, arrive = { 90, 180 }, blockAfterRemoval = 7 * 1440,
        childFee = 250 },

    -- Infants (age = "infant"). Needs: hunger, energy, hygiene (diaper), social, fun.
    infant = {
        decayAwake = { hunger = -10, energy = -7, hygiene = -7, social = -6, fun = -6, comfort = 0, bladder = 0 },
        decaySleep = { hunger = -4, energy = 16, hygiene = -3, social = 0, fun = 0, comfort = 0, bladder = 0 },
        cribSleepBonus = 10,          -- extra energy per hour asleep in a crib
        carriedSocial = 6,            -- social per hour while held
        sleepAt = -30, wakeAt = 90,   -- falls asleep below / wakes above this energy
        cribSleepAt = 40,             -- in a crib a tired infant settles to sleep below this energy
        carriedSleepAt = 0,           -- dozes off in someone's arms below this energy
        cryAt = { hunger = -20, hygiene = -30, social = -30, fun = -40, energy = -10 },
        cryWakeHunger = -40,          -- a sleeping infant wakes up crying below this hunger
        soothedFor = 40,              -- minutes a soothed infant won't cry about social or fun
        careMinutes = 3 * 1440,       -- 3 days of good care, then the infant becomes a child
        goodMin = -40, goodAvg = -10, -- "good care": every need above goodMin and the average above goodAvg
        startNeeds = { hunger = 40, energy = 60, hygiene = 70, social = 40, fun = 30, bladder = 50, comfort = 50, room = 0 },
        feed = { hunger = 70, dur = 15, cost = 2 },
        highchair = { hunger = 90, fun = 10, dur = 20, cost = 3 },
        change = { hygiene = 100, dur = 8 },
        soothe = { social = 40, fun = 10, dur = 10 },
        play = { fun = 50, social = 30, dur = 20 },
        rock = { dur = 12, social = 15, energyNeed = 60 },   -- rock to sleep (energy below energyNeed)
        celebrateDur = 15,
        cryLineEvery = 45,            -- minutes between spoken reactions to the same crying spell
        carryIdlePutDown = 30,        -- an idle carrier puts the baby down (crib first) after this long
        careScore = { base = 30, crying = 20, caregiver = 1.6, nightOthers = 0.5, woken = 60, wokenFor = 45 },
        -- woken: someone woken by the crying deals with it before going back to bed (for wokenFor minutes)
    },
    -- Crying and night disruption (noise rule). noise = loud - distance - (otherRoom and wallPenalty)
    -- - levelPenalty * floors apart. A sleeper exposed to noise >= wakeNoise accumulates exposure
    -- (noise units x minutes); at wakeExposure they wake. The assigned caregiver wakes as soon as
    -- noise >= caregiverNoise.
    noise = { loud = 12, wallPenalty = 4, levelPenalty = 6, wakeNoise = 3, wakeExposure = 30, caregiverNoise = 1,
        comfortHit = 4 },

    -- Children (age = "child").
    child = {
        toybox = { fun = 30, maxDur = 60 }, play = { fun = 35, maxDur = 60 },
        -- free will offers Play Together at most once per `cooldown` minutes per adult, and only
        -- while the pair's fun is below full (urgency = the two fun shortfalls / 200, summed)
        playTogether = { fun = 30, social = 20, dur = 20, rel = 6, cooldown = 180, minUrgency = 0.3 },
        tuckIn = { social = 20, comfort = 10, dur = 8, rel = 4, sleepBonus = 2, from = 19 * 60, to = 23 * 60 },
    },

    -- Neglect and protective services (brief §16.2). Non-graphic: warnings, visits, removal.
    neglect = {
        warnAt = -50, warnCooldown = 120,            -- per dependent and need
        criticalInfant = -80, criticalChild = -90,   -- sustained below this = documented neglect
        strikeAfter = 60,                            -- minutes of critical neglect per strike
        strikeCooldown = 360,                        -- at most one strike per dependent per 6 hours
        aloneInfantStrike = 60,                      -- infant with no adult on the lot
        aloneChildNight = 120,                       -- child alone between 22:00 and 06:00
        inspectAt = 2, removeAt = 3,                 -- strikes that bring an inspection / a removal
        inspectDelay = 60, removeDelay = 30,
        forgiveAfter = 3 * 1440,                     -- a strike is forgiven after 3 days without incidents
        okAtInspection = -30,                        -- all needs above this at the visit = warning only
    },

    -- Guardian lost (A39): who may take over.
    guardian = { friendMinLife = 30, adultFriendMinLife = 50, pickupDelay = 30, fallbackAfter = 180 },

    -- Parties.
    party = {
        maxGuests = 8, minGuests = 1, cooldown = 12 * 60,
        startOptions = { 0, 60, 120 },           -- minutes from the call
        arrivalWindow = { 5, 60 },               -- guests arrive this many minutes after the start
        stayMargin = 30,                         -- the visitors framework keeps guests this long past the end
                                                 -- (the party sends them home itself at the end)
        joinRetries = 5, joinRetryEvery = 3, joinNear = 4,   -- a guest's blocked walk in from the door
        duration = 240, lateHour = 2,            -- ends after 4 hours, or at 2 AM, whichever first
        platter = { cost = 120, servings = 12, eatDur = 10, hunger = 40, fun = 5 },
        acceptLife = 10, acceptBase = 0.45, acceptPerLife = 0.012, acceptOutgoing = 0.03,
        strangersFill = 3,                       -- strangers invited only when fewer known people than this
        sampleEvery = 10,
        -- score parts (0..100 each): fun = guests' average enjoyment (fun and social needs, 0..100),
        -- social = successful conversations per guest-hour, food = servings eaten per guest, music =
        -- share of samples with music in earshot, room = the rooms' scores, needs = share of basic
        -- needs (hunger, energy, bladder, hygiene, comfort) above zero
        weights = { fun = 0.25, social = 0.20, food = 0.15, music = 0.15, room = 0.10, needs = 0.15 },
        -- atmosphere: music in earshot lifts a guest's fun; a silent party drags (per hour, guests only)
        atmosphere = { musicFun = 6, silenceFun = -8 },
        socialsPerGuestHour = 2.5,               -- this many social interactions per guest-hour = full marks
        earlyLeavePenalty = 8, earlyLeaveCap = 32,
        goodAt = 65, badAt = 35,
        miserableMood = -35, miserableSamples = 3, exhaustedEnergy = -60,
        homebodyOutgoing = 3, homebodyAfter = 90, homebodyFun = 30,
        homebodyChance = 0.2,                    -- per sample while a shy guest stays bored past homebodyAfter
        leaveWaitSamples = 2,                    -- a guest who decided to go finishes an ordered action first (samples)
        rel = { dailyPerPoint = 0.4, lifePerPoint = 0.1 },   -- per satisfaction point above/below 50
        -- a conversation lands when a roll beats: base + perLife * relationship + perOutgoing *
        -- (average outgoing - 5) + music bonus; otherwise it is an awkward exchange that doesn't count
        mingle = { dur = 12, social = 30, fun = 10, base = 0.55, perLife = 0.004, perOutgoing = 0.05, music = 0.08,
            min = 0.15, max = 0.95, awkwardSocial = 5, awkwardFun = -6 },
        dance = { dur = 20, fun = 40, social = 10, energy = -6 },
        toast = { dur = 5, radius = 6 },
        rubbishPerGuests = 3,
        leaveWeight = { miserable = 1.0, hungry = 1.0, left = 1.0, exhausted = 0.5, homebody = 0.5 },
        musicRadius = 8,                         -- a stereo or radio this close (same floor) is heard
        hungryLeave = -60,                       -- a starving guest leaves when there is no food
        toastCooldown = 60,
        spotsCap = 12,                           -- remembered guest positions (where the rubbish ends up)
        historyCap = 10,
        -- guests arrive hungrier around dinner and tired late at night (minutes of the day, need shift)
        arrivalShift = { dinnerFrom = 17 * 60, dinnerTo = 20 * 60, dinnerHunger = -30,
            lateFrom = 21 * 60, lateEnergy = -40, lateTo = 5 * 60 },
        arrivalNeeds = { hunger = { 10, 50 }, energy = { 20, 70 }, bladder = { 30, 80 }, hygiene = { 40, 90 },
            fun = { 0, 40 }, social = { -10, 40 }, comfort = { 20, 60 } },
    },

    -- Name pools for new babies and adopted children (original, common first names).
    nameMax = 20,                -- longest first name the player can type for a new family member
    names = {
        she = { "Ivy", "Maren", "Tess", "Clover", "Juniper", "Nell", "Rosalind", "Wren", "Opal", "Sadie", "Lark", "Hazel" },
        he = { "Otis", "Felix", "Rowan", "Jasper", "Milo", "Ezra", "Hollis", "Tobin", "Arlo", "Silas", "Crispin", "Emmett" },
        they = { "Sage", "Robin", "Ellis", "Quinn", "Arden", "Marlow", "Remy", "Jules" },
    },
    -- Look palettes for generated children (skin/hair; outfits are bright play colours).
    skins = { { 0.98, 0.84, 0.72 }, { 0.93, 0.76, 0.62 }, { 0.84, 0.64, 0.48 }, { 0.72, 0.52, 0.36 },
        { 0.55, 0.38, 0.27 }, { 0.40, 0.27, 0.19 } },
    hairs = { { 0.12, 0.10, 0.09 }, { 0.30, 0.20, 0.12 }, { 0.55, 0.36, 0.18 }, { 0.80, 0.62, 0.34 },
        { 0.64, 0.26, 0.12 }, { 0.90, 0.82, 0.60 } },
    playColours = { { 0.95, 0.60, 0.30 }, { 0.40, 0.70, 0.90 }, { 0.95, 0.80, 0.30 }, { 0.55, 0.80, 0.45 },
        { 0.85, 0.50, 0.70 }, { 0.60, 0.55, 0.90 } },
}

-- System objects for parties (family owns their behaviour; never sold, never counted as designs).
-- The "dishes" and "rubbish" tags let the visitors module's cleaner clear the party mess too, and
-- tell the social module's lines what kind of mess it is. `mess` is household-core's mess kind: its
-- room score counts it with its own weights (Tuning.room.mess). Where the room score does not know
-- mess kinds, family adds FD.messEnv[kind] to the object's decoration instead (Sim/Family.lua).
local ALL4 = { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }
SS.Objects.party_platter = {
    name = "Party Platter", cat = "system", buyable = false, price = 0, env = 2, noBlock = false,
    desc = "Tiny sandwiches, a mountain of crisps and one lonely olive that nobody will admit to wanting.",
    slots = { front = { approaches = ALL4, face = 2 } }, actions = { "party_eat" }, tags = { "party_food" },
    art = { model = "system:party_platter", states = { "full", "half", "empty" } },
}
SS.Objects.party_plates = {
    name = "Stack of Dirty Party Plates", cat = "system", buyable = false, price = 0, env = 0, mess = "plate", noBlock = true,
    desc = "The party is over. The plates remain, like guests who never got the hint.",
    slots = { front = { approaches = ALL4, face = 2 } }, actions = { "party_clean_plates" }, tags = { "dishes", "mess" },
    art = { model = "system:party_plates" },
}
SS.Objects.party_rubbish = {
    name = "Party Rubbish", cat = "system", buyable = false, price = 0, env = 0, mess = "trash", noBlock = true,
    desc = "Napkins, cups and a paper hat. Evidence of a good time, or at least a time.",
    slots = { front = { approaches = ALL4, face = 2 } }, actions = { "party_clean_rubbish" }, tags = { "rubbish", "mess" },
    art = { model = "system:party_rubbish" },
}
