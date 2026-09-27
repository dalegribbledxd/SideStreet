-- SideStreet tuning data (owner: household-core). Every rate, threshold and knob the household
-- simulation uses lives here so balance changes never need code changes.
-- Needs use a -100..+100 scale (0 = neutral, below `urgent` = urgent). Rates are per simulated
-- hour unless a name says otherwise. See docs/modules/household-core.md for what each knob drives.
local _, SS = ...

SS.Tuning = {
    needs = { "hunger", "energy", "bladder", "hygiene", "fun", "social", "comfort", "room" },
    needLabel = {
        hunger = "Hunger", energy = "Energy", bladder = "Bladder", hygiene = "Hygiene",
        fun = "Fun", social = "Social", comfort = "Comfort", room = "Room",
    },
    -- passive change while awake / while sleeping (per sim hour). Room is not a timer: it follows
    -- the room the person stands in (Needs.Tick), so it has no entry here.
    decayAwake = { hunger = -5.5, energy = -4.5, bladder = -8.5, hygiene = -3.0, fun = -4.0, social = -2.5, comfort = -5.0 },
    decaySleep = { hunger = -2.2, energy = 0, bladder = -3.5, hygiene = -1.0, fun = 0, social = -1.0, comfort = 0 },
    walkingExtra = { energy = -1.5, comfort = -2.0 }, -- added while walking
    postureShare = 0.5,  -- share of a seat's/bed's comfort rate gained while doing something else on it
    -- exertion (interaction field `exertion`, 0..3): extra passive change per unit per hour
    exertion = { hunger = -1.6, energy = -5, hygiene = -4, comfort = -3 },
    -- life-stage multipliers on passive decay (the family module may override with actor.decay)
    ageDecay = { child = { fun = 1.3, energy = 1.15, hunger = 0.9, social = 1.1 } },
    roomApproach = 50,   -- how fast the Room need moves toward the current room's score (points/hour)

    -- thresholds: warn (thought balloon), urgent (interrupts optional activities), critical (notices,
    -- refusals, slower walking). Per need; `urgent` stays a single number for older callers.
    warn = { hunger = -20, energy = -25, bladder = -25, hygiene = -35, fun = -35, social = -40, comfort = -40, room = -45 },
    urgent = -55,
    critical = { hunger = -80, energy = -80, bladder = -80, hygiene = -85, fun = -85, social = -85, comfort = -85, room = -90 },
    warnCooldown = 90,   -- sim minutes between repeated warnings for the same need
    warnText = {
        hunger = { "%s is getting hungry.", "%s is starving and needs a proper meal now." },
        energy = { "%s is getting tired.", "%s is exhausted and may pass out soon." },
        bladder = { "%s needs the bathroom.", "%s is about to have an accident." },
        hygiene = { "%s could use a wash.", "%s smells. Other people are noticing." },
        fun = { "%s is bored.", "%s is miserably bored and won't do chores." },
        social = { "%s is lonely.", "%s is desperately lonely." },
        comfort = { "%s is uncomfortable.", "%s aches all over and needs to sit or lie down." },
        room = { "%s dislikes this room.", "%s can't stand being in this room." },
    },
    criticalWalk = 0.8,  -- walking speed multiplier while energy is critical
    grumbleNeat = 7,     -- neatness from which clearing up someone else's mess draws a remark
    plushSeatPrice = 700, -- seats at or above this price may draw an "expensive chair" remark
    plushRemark = 0.3,   -- chance of that remark per sitting
    fxCap = 48,          -- effect descriptors household-core hands the renderer per frame
    stinkAt = -60,       -- hygiene at or below which a person gives off a visible stink
    trendSmooth = 1 / 6, -- sim hours over which the needs panel's change direction is smoothed
    trendDeadband = 1.5, -- points per hour below which a need counts as steady
    -- overall mood summary words (first row whose floor the mood is above)
    moodLabels = { { 40, "Cheerful" }, { 10, "Content" }, { -20, "Grumpy" }, { -50, "Miserable" }, { -101, "Desperate" } },

    -- mood weights; low values are amplified non-linearly in Needs.Mood. Personality shifts the
    -- weights: weight * (1 + coef * (trait - 5)).
    moodWeight = { hunger = 1.3, energy = 1.3, bladder = 1.3, hygiene = 0.9, fun = 0.8, social = 0.7, comfort = 0.7, room = 0.6 },
    moodTrait = {
        neat = { room = 0.07, hygiene = 0.05 },
        outgoing = { social = 0.09 },
        active = { comfort = -0.04, energy = 0.03 },
        playful = { fun = 0.08 },
        nice = { social = 0.02 },
    },
    -- short emotional reactions (saved on the person as `feel`, at most feelCap at once)
    feel = {
        embarrassed = { mood = -18, dur = 180, icon = "embarrassed", text = "embarrassed" },
        frustrated = { mood = -12, dur = 90, icon = "frustrated", text = "frustrated" },
        annoyed = { mood = -8, dur = 60, icon = "annoyed", text = "annoyed" },
        groggy = { mood = -6, dur = 90, icon = "energy", text = "groggy" },
        disgusted = { mood = -8, dur = 60, icon = "disgusted", text = "disgusted" },
        proud = { mood = 10, dur = 120, icon = "proud", text = "proud" },
        refreshed = { mood = 6, dur = 90, icon = "hygiene", text = "refreshed" },
        -- raised by other modules through Needs.Feel (events: a death; social: a rival's flirting)
        grieving = { mood = -30, dur = 2880, icon = "grief", text = "grieving" },
        jealous = { mood = -15, dur = 240, icon = "jealous", text = "jealous" },
    },
    feelCap = 3,
    -- refusal of unsuitable actions (interaction flags `exertion`, `chore`)
    refuseEnergy = -60,  -- too tired for exercise, dancing, chores and repairs
    refuseMood = -55,    -- too miserable for exercise and chores
    refuseFun = -80,     -- too bored to do chores (unless neat >= 8)

    speeds = { [0] = 0, [1] = 1, [2] = 3, [3] = 10 }, -- sim minutes per real second
    speedLabel = { [0] = "Paused", [1] = "Normal (1 min/s)", [2] = "Fast (x3)", [3] = "Very fast (x10)" },
    walkSpeed = 2.4,     -- tiles per sim minute
    stairSpeed = 0.6,    -- fraction of walk speed on stairs
    maxRealStep = 0.25,  -- clamp one frame's real seconds (bounded catch-up after a stall)
    subStep = 0.25,      -- sim minutes per simulation sub-step
    startTime = 8 * 60,  -- day 1, 8:00
    startMoney = 1200,   -- the stage-1 starter fixture (4 Juniper Lane) keeps this balance
    newHouseholdMoney = 20000, -- ARCHITECTURE 9.7: a brand-new household's starting cash

    ledgerCap = 400,     -- money ledger entries kept (world.ledger); about two months of a busy household
    sayCooldown = 20,    -- minutes between one person's spoken lines, when SS.Lines keeps no limits of its own

    -- executor ----------------------------------------------------------------------------
    maxQueue = 8,
    waitManual = 30,     -- sim minutes a player-ordered action waits for a busy slot / private room
    waitAuto = 12,       -- same, for free-will choices
    waitCheck = 0.5,     -- sim minutes between availability re-checks while waiting
    yieldMax = 2,        -- sim minutes an actor yields to another before replanning / passing through
    routeRetries = 3,    -- replans after a blocked step before the action fails
    pathsPerStep = 4,    -- A* searches allowed per simulation step (the rest wait a step)
    pathExpandCap = 4000, -- node expansions per search (bounded work on huge lots)
    pathAvoidExpand = 400, -- node expansions for a search that routes around people standing still;
                           -- a detour that needs more is not worth it (the plain route is used and
                           -- the person in the way steps aside or is passed)
    pathExpandPerStep = 6000, -- node expansions per simulation step for the executor's own searches
    pathReverseAfter = 256, -- a search still going after this many expansions also walks back from
                           -- the goal, one cell per expansion: a goal fenced off by a rule the door
                           -- check can't see (staff-only cells, fire) fails once its own side is
                           -- used up, not after the whole lot (routes found in play need far fewer)
    scheduleMaxPerStep = 256, -- scheduled events fired in one step at most (the rest fire on the next step)
    failCooldown = 30,   -- sim minutes before autonomy retries a failed object/action
    routeFailCooldown = 60, -- after "can't get there": the same target is skipped this long
    rejectCooldown = 15, -- an offer that failed its availability check is not reconsidered for this long
    shooDistance = 2,    -- idle people step aside this far for someone passing

    -- autonomy ----------------------------------------------------------------------------
    -- What the Free Will switch does, in the words the options/help screens show (tests check
    -- the behaviour against this text).
    freeWillHelp = {
        on = "Free Will on: when idle, residents look after their own needs, tidy up and find something to do.",
        off = "Free Will off: residents only do what you order. They still wake for alarms and emergencies, "
            .. "and accidents and collapse still happen. Visitors always act on their own.",
    },
    thinkInterval = 2,   -- sim minutes between autonomy decisions for an idle actor
    thinkSpread = 0.37,  -- per-actor stagger (sim minutes) so actors don't think on the same step
    maxThinksPerStep = 3,
    minScore = 12,       -- candidates below this are ignored
    availChecks = 14,    -- how many top-scored candidates get the (expensive) availability check
    pickWindow = 0.10,   -- pick randomly (weighted) among candidates within 10% of the best
    commitMargin = 1.6,  -- a critical need only replaces a committed choice when this much better
    travelCost = 0.04,   -- score / (1 + tiles * travelCost)
    levelCost = 6,       -- tiles-equivalent per storey of travel
    busyPenalty = 0.45,  -- a busy target is only worth waiting for when urgent
    moneyPenalty = 4,    -- score * (1 - min(0.5, cost / money * moneyPenalty))
    interestWeight = 0.05, -- per interest point away from 5
    traitWeight = 0.11,  -- per personality point away from 5, times the interaction's trait weight
    socialContext = 0.25, -- group activities with people already doing them
    jitter = 0.06,       -- deterministic per actor/object spread so housemates don't all pick one object
    repetition = { step = 0.28, floor = 0.35, halfLife = 240 }, -- fun from repeating one activity
    planBonus = 1.5,     -- "dinner is served" and similar plans
    durationFree = 15,   -- fixed-length activities up to this many minutes carry no duration cost
    durationCost = 0.004, -- score / (1 + (minutes - durationFree) * durationCost * urgency)
    durationFloor = 0.55,
    safetyPenalty = 0.2, -- risky interactions: score * (1 - risk * safetyPenalty * 5)

    -- sleep ---------------------------------------------------------------------------------
    nightStart = 21 * 60, nightEnd = 7 * 60,
    sleepNight = 1.45,   -- sleep advert multiplier at night
    sleepDay = 0.5,      -- ... during the day (naps are for daytime)
    napMaxEnergy = 45,   -- naps are considered below this energy in daytime
    ownBed = 1.15,       -- people prefer the bed they slept in last (actor.bed, saved)
    childBedPref = 1.6,  -- children prefer a child-sized bed when there is one (clearly: not a coin toss with a big bed)
    bedClaimed = 0.35,   -- a bed whose sides all belong to other household members is a last resort
    bedDefault = { energy = 12, comfort = 8 },
    noiseWake = 5,       -- noise units that wake a sleeper
    noiseWakeMinEnergy = 25, -- exhausted people sleep through anything
    noisePenalty = 0.07, -- recovery lost per noise unit
    noiseRadius = 6,
    noiseWall = 0.35,    -- noise carried into another room
    noiseCheck = 5,      -- sim minutes between noise checks per sleeper
    groggyBelow = 55,    -- woken before this energy -> groggy
    alarmDefault = 7 * 60,
    alarmNoise = 7,
    alarmRing = 15,      -- minutes an alarm rings unless someone turns it off
    alarmSleepThrough = -30, -- energy below which a sleeper sleeps through a ringing alarm
    makeBed = { base = 0.1, perNeat = 0.09 }, -- chance a person makes their bed after getting up
    sleepHoldMax = 720,  -- night sleep: someone whose energy fills during the night window sleeps on
                         -- until the night ends (nightEnd) instead of getting up at two in the
                         -- morning, for at most this many minutes in bed; someone woken in the
                         -- night by a need or a noise goes back to bed once it is dealt with
    backToBedMin = 30,   -- ... unless less than this many minutes of the night are left
    backToBedOver = 60,  -- ... and not while a choice scores this much or more (Actions.Score scale:
                         -- the crying baby that woke them, an urgent need): that comes first
    stayUpAfterWake = 120, -- minutes after an alarm, work or school wake-up before bed appeals again
                         -- (unless energy is critical): getting up means getting up
    sleepHungry = 0.3,   -- sleep advert x this while hunger is at its warning level (eat first),
                         -- unless energy is critical; going to bed hungry means waking starving
    breakfast = { window = 30, below = 40, bonus = 2.5, late = 0.5 }, -- after a work/school wake-up:
                         -- for `window` minutes food scores x bonus when hunger < below if it fits the
                         -- window (x late if it does not: a meal abandoned for the carpool is wasted)

    -- bathroom ------------------------------------------------------------------------------
    handwash = { base = 0.15, perNeat = 0.085 },
    puddle = { shower = 0.12, bath = 0.22, child = 2 },
    annoyAfter = 3,      -- sim minutes waiting for a bathroom before annoyance
    accident = { hygiene = -45, bladder = 60 },

    -- food ----------------------------------------------------------------------------------
    food = {
        hungerQuality = { 0.75, 0.45 }, -- hunger per portion = recipe hunger * (a + b * quality)
        funQuality = 18,               -- fun from a meal = (quality - 0.5) * funQuality + recipe fun * quality
        qualityBase = 0.35, qualityPerSkill = 0.055, qualityPerAppliance = 0.025, qualityNoise = 0.08,
        missingSkill = 0.08,           -- quality lost per cooking level below the recipe's
        applianceDefaultQ = 3,         -- appliance cooking quality (0..10) when the definition gives none
        burn = { base = 0.12, perSkill = 0.032, perMissingSkill = 0.08, perApplianceQ = 0.012, dirty = 0.05, min = 0.02, max = 0.85,
                 appliance = { stove = 1, oven = 0.8, grill = 1.2, microwave = 0.35, toaster = 0.5 } },
        fireOnBurn = 0.05,             -- chance a burn ignites: fireOnBurn * recipe.fireRisk * appliance quality.fireRisk
        overcook = 20,                 -- sim minutes a finished pot survives unattended on live heat before burning
        unattendedFire = 0.3,          -- chance per hour that burnt food left on live heat ignites
        spoilHours = 10, fridgeSpoilMult = 4, -- x the fridge's quality.freshness (Chains.Freshness)
        stockCap = 6,                  -- dishes a fridge without quality.capacity holds (with one: that many servings)
        stockMaxEntries = 40,          -- dishes any fridge holds at most (a bound on saved stock)
        eatMinutes = 18,               -- eating a full portion
        eatBladder = -8,               -- bladder per full portion (food and the drink with it)
        standComfort = -10,            -- comfort per hour while eating standing up
        snackCost = 4,
        -- snacks one after another fill less and less: hunger x max(floor, 1 - step * recent), where
        -- recent halves every halfLife minutes (six snacks in a row cannot take starving to full)
        snackRepeat = { step = 0.35, floor = 0.2, halfLife = 120 },
        eatSocial = 4,                 -- social per hour when eating at a table with others
        prepSkill = 0.25, cookSkill = 0.35, -- cooking practice per hour of preparing / cooking
        speedPerSkill = 0.06,          -- preparation and cooking time / (1 + skill * speedPerSkill)
        autoSkillMargin = 2,           -- free will avoids recipes more than this many levels above the cook
        tidy = { base = 0.1, perNeat = 0.085 }, -- chance to take the plate to the sink after eating
        washPerPlate = 2.5,            -- minutes per dish at a sink or basin
        leftoverQ = 0.92,              -- leftovers from the fridge keep this share of their quality
        planMinutes = 90,              -- "dinner is served" lasts this long for the household
        proudAt = 0.8,                 -- meal quality that makes the cook proud
        gardenBonus = 0.1,             -- meal quality added when cooked with home-grown produce
        groupServings = 8,             -- portions in a group meal pot (parties: SS.Chains.GroupMeal)
        groupMinServings = 4,          -- recipes serving at least this many can be cooked as a group meal
        dishwasherCap = 8, dishwasherMinutes = 60, dishwasherNoise = 3,
        drinkCap = 1,
    },

    -- maintenance ---------------------------------------------------------------------------
    dirtPerUse = { toilet = 9, shower = 7, bath = 8, basin = 3, sink = 3, stove = 7, oven = 6, microwave = 4,
                   grill = 9, counter = 4, coffee = 3, toaster = 3, dishwasher = 2, fridge = 1, table_dining = 2 },
    dirtyAt = 50, filthyAt = 85,
    dirtyGainMult = 0.8, -- a dirty fixture gives this share of its benefit
    wearPerUse = 1,
    breakChance = {      -- per use when the definition gives no quality.breakChance
        toilet = 0.006, shower = 0.005, bath = 0.004, basin = 0.003, sink = 0.004, dishwasher = 0.008,
        fridge = 0.002, stove = 0.006, oven = 0.004, microwave = 0.006, coffee = 0.006, toaster = 0.006,
        tv = 0.004, stereo = 0.004, radio = 0.004, computer = 0.006, game = 0.004, lamp = 0.002,
        clock_alarm = 0.002, arcade = 0.006, pinball = 0.006, exercise = 0.004, bed = 0.001, seat = 0.001,
    },
    -- broken objects: "unavailable" (no normal use) or "degraded" (works worse)
    brokenPolicy = {
        bed = "degraded", bed_child = "degraded", seat = "degraded", sofa = "degraded", fridge = "degraded",
        piano = "degraded", instrument = "degraded",
    },
    degraded = 0.5,
    leakPerHour = 0.35,  -- broken plumbing: chance per hour of a new puddle (up to leakCap per fixture)
    leakCap = 3,
    repair = { base = 30, perSkill = 0.15, success = 0.35, successPerSkill = 0.07, perDifficulty = 0.1,
               minSuccess = 0.2, maxSuccess = 0.97, skill = 0.35,
               blockedShare = 0.5 },  -- a broken object advertises this share of its own relief as "repair me"
    shock = { base = 0.12, perSkill = 1 / 12, perDifficulty = 0.03 },
    powered = { stove = true, oven = true, microwave = true, coffee = true, toaster = true, dishwasher = true, fridge = true,
                tv = true, stereo = true, radio = true, computer = true, game = true, lamp = true, clock_alarm = true,
                arcade = true, pinball = true, dj = true },
    scrubMinutes = { base = 4, perDirt = 0.1 },
    maxPuddles = 16, outdoorDryHours = 3,
    bin = { indoorCap = 10, outdoorCap = 6, collectHour = 7, collectDays = { [0] = true, [3] = true } },

    -- room score ----------------------------------------------------------------------------
    room = {
        lightWeight = 80, lightMid = 0.45, outdoorLight = 40,
        decorWeight = 8, outdoorDecor = 1.5, smallRoom = 6, smallRoomPenalty = -15, crowded = 0.55, crowdedPenalty = -10,
        mess = { plate = 6, food = 1, spoiled = 12, trash = 12, bag = 6, binFull = 8, puddle = 8, dirty = 4, filthy = 8,
                 unmade = 2, clutter = 3, broken = 6, wilted = 4, burnt = 8 },
        messScale = 10,  -- mess * messScale / sqrt(max(area, 10))
        cacheMinutes = 10,
    },

    -- leisure -------------------------------------------------------------------------------
    channelInterest = 0.12, -- per interest point away from 5: how much a show's topic changes its fun
    tvChannels = {
        { id = "drama", name = "Harbour Lights (drama)", fun = 30, topic = "films" },
        { id = "comedy", name = "Laugh Track Lane (sitcom)", fun = 34, topic = "films", playful = 1 },
        { id = "cooking", name = "A Pinch of Salt (cooking)", fun = 18, skill = { cooking = 0.06 }, topic = "cooking" },
        { id = "fitness", name = "Wake Up & Stretch (fitness)", fun = 14, skill = { body = 0.08 }, topic = "sports", workout = true },
        { id = "news", name = "The Six O'Clock Roundup (news)", fun = 10, skill = { logic = 0.03 }, topic = "news" },
        { id = "cartoons", name = "Saturday Scramble (cartoons)", fun = 16, funChild = 38, topic = "films" },
    },
    stations = {
        { id = "pop", name = "Sunbeam Pop 101", fun = 30, dance = 1.1 },
        { id = "jazz", name = "Velvet Lounge Jazz", fun = 26, dance = 0.8 },
        { id = "country", name = "Porchlight Country", fun = 24, dance = 0.9 },
        { id = "classical", name = "Parlour Classics", fun = 22, dance = 0.5, skill = { logic = 0.01 } },
        { id = "latin", name = "Cha-Cha Carousel", fun = 30, dance = 1.3 },
        { id = "rock", name = "Garage Static", fun = 28, dance = 1.0 },
    },
    tvStandSpots = 3,    -- viewers who stand when every facing seat is taken
    -- the set itself matters: a set's catalogue fun rate over the starter model's is added to what
    -- is on (a widescreen makes any programme better by the same amount); never below 40 % of it
    mediaRefFun = { tv = 28, music = 22 },
    mediaMinShare = 0.4,
    danceCap = 4, danceRadius = 3,
    musicNoise = 4, tvNoise = 3, instrumentNoise = 4,
    -- a skilled player (creativity >= skilled) entertains the room: people in the same room within
    -- roomRadius tiles get bystander + perSkill * creativity fun per hour; people who stop to listen
    -- ("Listen", listen_instrument) get listen + listenPerSkill * creativity fun per hour and some
    -- company (social 6/h and a little relationship with the player and other listeners); the
    -- player enjoys an audience (fun x audienceFun, social per hour)
    instrument = { skilled = 4, roomRadius = 6, bystander = 2, perSkill = 0.5, listen = 10, listenPerSkill = 1.0,
        audienceFun = 1.2, audienceSocial = 3 },
    shareRel = { daily = 2, life = 0.3, every = 30 }, -- relationship gain per 30 min of a shared activity
    -- Money-making crafts. A piece's value = mode value * (valueBase + valueQ * quality^2); quality
    -- rises with skill (0.2 + 0.07 per level, +0.2 for careful work, +-0.12 luck) and skill also
    -- shortens the work (minutes / (1 + 0.05 * skill)). Scaled to the careers module's wages: a
    -- beginner earns about half an entry-level wage per hour, a master about a mid-career wage
    -- (painting: about 9, 24 and 45 per hour at skill 0, 5 and 10; entry-level jobs pay about 15-17
    -- and levels 3-4 about 33-70 per hour). Each sale on the same day fetches less
    -- (1 - saleStep per earlier sale that day, at least saleFloor): a flooded market.
    craft = {
        painting = { quick = { minutes = 45, value = 12 }, careful = { minutes = 180, value = 45 },
                     skill = "creativity", gain = 0.3 },
        woodwork = { quick = { minutes = 60, value = 12 }, careful = { minutes = 150, value = 36 },
                     skill = "mechanical", gain = 0.3 },
        valueBase = 0.3, valueQ = 1.7,
        saleStep = 0.15, saleFloor = 0.4,
        maxOnLot = 12,   -- unsold crafts on one lot (placing beyond this goes to storage)
    },
}
