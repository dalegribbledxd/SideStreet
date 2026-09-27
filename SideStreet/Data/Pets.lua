-- SideStreet pets: species behaviour sets, original breeds and coats (look data), names,
-- training, prices, and the aquarium/small-animal enclosure. Owner: family module.
-- Pets are persons in root.residents with kind = "dog" | "cat" and person.pet = { ... }.
-- Needs use the human -100..100 scale; decay per sim hour; all prices on the §9.7 scale.
local _, SS = ...

SS.PetData = {
    maxPerHousehold = 2,   -- declared actor budget (also SS.FamilyData.petMax)

    species = {
        dog = {
            label = "Dog",
            decayAwake = { hunger = -6, energy = -5, bladder = -7, hygiene = -3, fun = -6, social = -5, comfort = -3 },
            decaySleep = { hunger = -2, energy = 10, bladder = -3, hygiene = -1, fun = 0, social = -1, comfort = 2 },
            -- behaviour set
            relievesOutdoors = true,   -- goes outside when house trained; untrained dogs have accidents
            usesLitter = false,
            selfGrooms = false,        -- needs brushing by a person
            barksAtStrangers = true,
            accidentAt = -40,          -- untrained: an accident indoors below this bladder
            needToGoAt = -15,          -- shows a "needs to go out" balloon below this
            startTraining = { sit = 0, house = 20 },
            walkMinutes = 30,          -- "Take for a Walk" leaves the lot for this long
            voice = "bark",
            adoptFee = 300, shelterFee = 80,
        },
        cat = {
            label = "Cat",
            decayAwake = { hunger = -5, energy = -4, bladder = -5, hygiene = -2, fun = -4, social = -3, comfort = -2 },
            decaySleep = { hunger = -2, energy = 11, bladder = -2, hygiene = -1, fun = 0, social = 0, comfort = 2 },
            relievesOutdoors = false,
            usesLitter = true,
            selfGrooms = true,
            barksAtStrangers = false,
            accidentAt = -60,          -- only when there is no usable litter tray
            needToGoAt = -20,
            startTraining = { sit = 0, house = 100 },   -- cats arrive litter trained
            voice = "meow",
            adoptFee = 250, shelterFee = 60,
        },
    },

    -- Original breeds (look data for the art module: size, ears, tail, coat patterns).
    -- traits bias: friendly, active, smart, playful (0..10), varied +-2 per animal (seeded).
    breeds = {
        dog = {
            porchside_hound = { name = "Porchside Hound", size = "medium", ears = "long", tail = "straight",
                coats = { "tan", "chestnut", "black_tan" }, patterns = { "solid", "saddle" },
                traits = { friendly = 7, active = 5, smart = 5, playful = 6 } },
            brambleback_terrier = { name = "Brambleback Terrier", size = "small", ears = "folded", tail = "short",
                coats = { "wheat", "grey", "white" }, patterns = { "solid", "patched" },
                traits = { friendly = 5, active = 9, smart = 6, playful = 8 } },
            lakeshore_retriever = { name = "Lakeshore Retriever", size = "large", ears = "floppy", tail = "feathered",
                coats = { "gold", "cream", "chocolate" }, patterns = { "solid" },
                traits = { friendly = 9, active = 7, smart = 7, playful = 8 } },
            twotone_shepherd = { name = "Two-Tone Shepherd", size = "large", ears = "pointed", tail = "bushy",
                coats = { "black_tan", "grey", "sable" }, patterns = { "saddle", "solid" },
                traits = { friendly = 5, active = 7, smart = 9, playful = 5 } },
            teacup_puffball = { name = "Teacup Puffball", size = "tiny", ears = "tufted", tail = "curled",
                coats = { "white", "cream", "apricot" }, patterns = { "solid" },
                traits = { friendly = 6, active = 3, smart = 4, playful = 6 } },
            spotted_coach = { name = "Spotted Coach Dog", size = "medium", ears = "floppy", tail = "straight",
                coats = { "white" }, patterns = { "spotted" },
                traits = { friendly = 6, active = 8, smart = 6, playful = 7 } },
        },
        cat = {
            windowsill_shorthair = { name = "Windowsill Shorthair", size = "medium", ears = "upright", tail = "long",
                coats = { "grey_blue", "black", "cream", "ginger" }, patterns = { "solid", "tabby" },
                traits = { friendly = 6, active = 5, smart = 6, playful = 6 } },
            fluffmantle_longhair = { name = "Fluffmantle Longhair", size = "large", ears = "tufted", tail = "plume",
                coats = { "white", "silver", "cream" }, patterns = { "solid", "smoke" },
                traits = { friendly = 5, active = 3, smart = 5, playful = 4 } },
            pointed_moonface = { name = "Pointed Moonface", size = "medium", ears = "large", tail = "long",
                coats = { "cream" }, patterns = { "points" },
                traits = { friendly = 8, active = 6, smart = 7, playful = 7 } },
            marmalade_tabby = { name = "Marmalade Tabby", size = "medium", ears = "upright", tail = "long",
                coats = { "ginger" }, patterns = { "tabby" },
                traits = { friendly = 7, active = 6, smart = 5, playful = 8 } },
            tuxedo_stray = { name = "Tuxedo Stray", size = "small", ears = "notched", tail = "kinked",
                coats = { "black" }, patterns = { "tuxedo", "patched" },
                traits = { friendly = 4, active = 7, smart = 8, playful = 5 } },
        },
    },

    -- Coat colours (primary, secondary) used by breeds; the renderer tints pet layers with these.
    coats = {
        tan = { { 0.78, 0.58, 0.36 }, { 0.95, 0.88, 0.74 } },
        chestnut = { { 0.55, 0.30, 0.16 }, { 0.90, 0.80, 0.66 } },
        black_tan = { { 0.12, 0.10, 0.09 }, { 0.72, 0.48, 0.26 } },
        wheat = { { 0.88, 0.76, 0.52 }, { 0.96, 0.92, 0.80 } },
        grey = { { 0.52, 0.52, 0.54 }, { 0.84, 0.84, 0.84 } },
        white = { { 0.96, 0.95, 0.92 }, { 0.14, 0.12, 0.12 } },
        gold = { { 0.90, 0.68, 0.34 }, { 0.98, 0.86, 0.60 } },
        cream = { { 0.95, 0.88, 0.72 }, { 0.78, 0.64, 0.48 } },
        chocolate = { { 0.36, 0.22, 0.14 }, { 0.52, 0.36, 0.24 } },
        sable = { { 0.62, 0.44, 0.24 }, { 0.20, 0.16, 0.12 } },
        apricot = { { 0.95, 0.74, 0.52 }, { 0.98, 0.90, 0.78 } },
        grey_blue = { { 0.50, 0.56, 0.64 }, { 0.78, 0.82, 0.86 } },
        black = { { 0.10, 0.10, 0.11 }, { 0.95, 0.95, 0.93 } },
        ginger = { { 0.90, 0.54, 0.22 }, { 0.98, 0.84, 0.62 } },
        silver = { { 0.78, 0.80, 0.82 }, { 0.40, 0.42, 0.46 } },
    },

    -- Original pet names (the player can rename a pet when it arrives or from its menu).
    names = {
        dog = { "Biscuit", "Pepper", "Noodle", "Waffles", "Juniper", "Scout", "Pickle", "Ranger", "Toffee",
            "Bramble", "Captain", "Dumpling", "Moss", "Sprocket", "Clementine", "Bosco" },
        cat = { "Marmalade", "Pixel", "Soot", "Custard", "Whiskerton", "Nutmeg", "Olive", "Tabitha", "Mochi",
            "Ember", "Pebble", "Sir Fluff", "Parsnip", "Velvet", "Tinsel", "Quill" },
    },
    nameMax = 20,

    -- Human-pet interactions (effects per completed action).
    care = {
        pet = { dur = 6, petSocial = 35, humanSocial = 8, humanFun = 8, rel = 3, life = 1 },
        play = { dur = 15, petFun = 50, petEnergy = -8, petSocial = 10, humanFun = 25, humanEnergy = -4, rel = 4 },
        treat = { dur = 3, cost = 2, petHunger = 12, petSocial = 5, rel = 5 },
        groom = { dur = 12, petHygiene = 70, humanHygiene = -3, rel = 2 },
        praise = { dur = 3, petSocial = 10, houseGain = 20, window = 30, rel = 2 },
        scold = { dur = 3, houseGain = 15, window = 30, rel = -4, wrongRel = -8, petSocial = -10 },
        train = { dur = 12, base = 5, perSmart = 1.5, moodBonus = 4, petFun = -5, minEnergy = -30, humanFun = 5 },
        commandSit = { dur = 3, humanFun = 10, petSocial = 5 },
        walk = { petFun = 40, petSocial = 20, humanFun = 20, humanEnergy = -10, rel = 5 },
        fillBowl = { dur = 4, cost = 5, portions = 3 },
        eat = { dur = 8, hunger = 45 },       -- one portion
        cleanLitter = { dur = 8, humanHygiene = -5 },
        cleanMess = { dur = 10, humanHygiene = -4 },
        bedRest = { energy = 12, comfort = 15 },     -- on top of sleeping decay
        toy = { maxDur = 25, fun = 45 },
        selfGroom = { dur = 10, hygiene = 30 },
        floorNapComfort = -2,
        litterDirtPerUse = 22,
        litterFullAt = 90,
    },

    -- Autonomy (pet role tick): decide every n minutes when idle; greet/bark once per visitor per window.
    decideEvery = 3,
    visitorReactCooldown = 120,
    visitorRadius = 8,
    begCooldown = 60,
    runawayAfter = 24 * 60,      -- minutes of critical hunger before a neglected pet runs away (warned at half)
    runawayHunger = -90,

    -- Pet behaviour tuning (role tick).
    behaviour = {
        eatBelow = 35, sleepBelow = 25, nightSleepBelow = 65, wakeAt = 95, groomBelow = 40,
        playBelow = 35, socialBelow = 35, wanderChance = 0.35, wanderRadius = 5,
        begDur = 4, greetDur = 3, barkDur = 3, reliefDur = 2, groomDur = 10, nuzzleDur = 5,
        seekMaxDist = 30, visitorFriendlyAt = 6, catFriendlyAt = 7,
        greetVisitor = { social = 6, fun = 4, rel = 2 }, barkVisitor = { comfort = -6, rel = -1 },
        hungryRelPerHour = -3,       -- a hungry or lonely pet cools toward the household
        messCap = 6,                 -- at most this many pet messes on a lot (the table stays bounded)
    },

    -- Aquarium / small-animal enclosure (tag "aquarium"), functional when sold with the tag.
    aquarium = {
        startAnimals = 3, stockCost = 40, capacity = 6,
        feedCost = 1, feedDur = 3, cleanDur = 20, watchMaxDur = 30, watchFun = 20, watchComfort = 5,
        dirtPerHour = 0.8, dirtyAt = 50, sickAt = 90,
        hungryAfter = 24 * 60, starveAfter = 48 * 60, lossEvery = 24 * 60,
        dirtyEnv = -3, emptyEnvFactor = 0.3,
    },
}

-- System object: a pet accident on the floor (family owns its behaviour; never sold). The "puddle"
-- tag lets the visitors module's cleaner mop it up; "pet_mess" comes first so lines call it a pet mess.
local ALL4 = { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }
SS.Objects.pet_mess = {
    name = "Pet Accident", cat = "system", buyable = false, price = 0, env = 0, mess = "puddle", noBlock = true,
    desc = "A small, damp reminder that house training is still a work in progress. Clean it before someone steps in it.",
    slots = { front = { approaches = ALL4, face = 2 } }, actions = { "pet_clean_mess" }, tags = { "pet_mess", "puddle", "mess" },
    art = { model = "system:pet_mess", states = { "puddle", "pile" } },
}
