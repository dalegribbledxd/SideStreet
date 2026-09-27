-- SideStreet events data: event-director families, fire / death / hazard tuning, and the
-- events module's system objects (flames, charred remains, scorch marks, memorials, pests,
-- comic-surprise props). Owner: events module (see ARCHITECTURE.md and docs/modules/events.md).
-- Numbers here are the tuning knobs; behaviour lives in Sim/Events.lua, Sim/Fire.lua,
-- Sim/Death.lua and Sim/Hazards.lua. Times are sim minutes unless a name says otherwise.
local _, SS = ...
local D = {}
SS.EventsData = D

D.HOUR, D.DAY = 60, 1440

---------------------------------------------------------------------------------------------------
-- Event director. Rolls happen on simulated hour ticks only (never per frame), with the
-- "events" random stream. Ordinary events and emergencies roll in separate lanes with their
-- own budgets, and every family has its own cooldown, so a household does not get a burglary,
-- a fire, an argument and a death in one afternoon.
D.director = {
    ordinaryPerDay = 2,          -- ordinary events per sim day (director-started plus observed ones)
    ordinaryGap = 6 * 60,        -- minutes between two director-started ordinary events
    comicGap = 2 * 1440,         -- minimum spacing between two comic surprises
    somberGap = 1440,            -- no comic surprise within a day of a fire, burglary or death
    emergencyQuiet = 3 * 1440,   -- no director-started emergency within 3 days of any emergency
    firstQuiet = 12 * 60,        -- a household that just started playing gets 12 quiet hours...
    firstEmergencyQuiet = 2 * 1440, -- ...and two days before the first director-started emergency
    retry = 6 * 60,              -- cooldown after a family was picked but could not run
    maxChance = 0.5,             -- cap on the summed per-hour chance of one lane
    historyCap = 80,             -- bounded event list (active records are never dropped)
    -- emergencies that hold every other director roll back while they are active on the lot;
    -- long-lived records (a death waiting for the Registrar, a household without a guardian)
    -- never block the director
    blocking = { fire = true, burglary = true },
}

-- Responders requested through the visitors framework (SS.Visitors.Request data): emergency
-- priority skips visitors' caps and staleness; "direct" walks straight in from the street.
D.responders = {
    firefighter = { priority = "emergency", arrive = "direct" },
    police = { priority = "emergency", arrive = "direct" },
    burglar = { priority = "emergency", arrive = "direct" },
    registrar = { arrive = "direct" },
}
-- Alarms ring the shared way: state.ringing plus a ring-until time (object.ringUntil), which
-- household-core's object tick honours (it silences any ringing object whose time has passed).
-- An alarm events sets off is kept ringing this far ahead while its fire or burglary lasts.
D.alarmRingHold = 10

D.responderRetry = 30            -- a responder still busy on the lot with another event comes back this much later...
D.responderRetries = 6           -- ...at most this many times

-- lane: "ordinary" | "emergency". chance: per eligible hour. cooldown: minutes after it ran.
-- hours = { from, to } (to exclusive, wraps past midnight). api = the other module's call it
-- needs (documented; eligibility fails cleanly while that module is still a stub).
D.families = {
    { id = "visit_dropin", lane = "ordinary", chance = 0.020, cooldown = 2 * 1440, hours = { 10, 20 }, owner = "visitors", api = "SS.Visitors.Request" },
    { id = "phone_call", lane = "ordinary", chance = 0.020, cooldown = 2 * 1440, hours = { 9, 21 }, owner = "visitors", api = "SS.Phone.Ring" },
    { id = "breakdown", lane = "ordinary", chance = 0.012, cooldown = 3 * 1440, hours = { 7, 23 }, owner = "household-core", api = "SS.Maintenance.Break" },
    { id = "pipe_leak", lane = "ordinary", chance = 0.008, cooldown = 4 * 1440, hours = { 6, 23 }, owner = "events", api = "SS.Maintenance.Break" },
    { id = "argument", lane = "ordinary", chance = 0.010, cooldown = 3 * 1440, hours = { 8, 22 }, owner = "social", api = "SS.Interactions.argue" },
    { id = "work_chance", lane = "ordinary", chance = 0.008, cooldown = 4 * 1440, hours = { 7, 21 }, owner = "careers", api = "SS.Career.ChanceEvent" },
    { id = "garden_stress", lane = "ordinary", chance = 0.006, cooldown = 4 * 1440, hours = { 11, 17 }, owner = "family", api = "SS.Garden.Stress" },
    { id = "comic_casserole", lane = "ordinary", comic = true, chance = 0.008, cooldown = 6 * 1440, hours = { 9, 19 } },
    { id = "comic_parcel", lane = "ordinary", comic = true, chance = 0.008, cooldown = 6 * 1440, hours = { 9, 18 } },
    { id = "comic_coins", lane = "ordinary", comic = true, chance = 0.012, cooldown = 5 * 1440, hours = { 8, 23 } },
    { id = "comic_pigeon", lane = "ordinary", comic = true, chance = 0.008, cooldown = 6 * 1440, hours = { 8, 19 } },
    { id = "comic_broadcast", lane = "ordinary", comic = true, chance = 0.030, cooldown = 7 * 1440, hours = { 0, 4 } },
    { id = "comic_gnome", lane = "ordinary", comic = true, chance = 0.008, cooldown = 7 * 1440, hours = { 7, 20 } },
    { id = "comic_hiccups", lane = "ordinary", comic = true, chance = 0.010, cooldown = 4 * 1440, hours = { 8, 22 } },
    { id = "burglary", lane = "emergency", chance = 0.006, cooldown = 6 * 1440, hours = { 0, 5 } },
    { id = "electrical_fire", lane = "emergency", chance = 0.004, cooldown = 10 * 1440, hours = { 0, 24 } },   -- needs broken or worn-out electrics
}

-- Families that are not rolled: the module watches for them and records them (so they reach
-- the journal and count toward the quiet-period budget), or they follow from conditions.
D.observed = {
    bills = { owner = "careers", how = "money events with category 'bills'; billOverdue / billPaid / collectionDone / repossessed" },
    spoiled_food = { owner = "household-core", how = "objects with state.spoiled, checked hourly" },
    pests = { owner = "events", how = "sustained mess per room, checked hourly" },
    leak = { owner = "events", how = "objectBroken on a plumbing fixture" },
    garden = { owner = "family", how = "objects with state.wilted, checked hourly" },
    work = { owner = "careers", how = "careerPromoted / careerDemoted / careerEnded" },
    party = { owner = "family", how = "partyEnded (family records its own party record; events only fills in when it has not)" },
    argument = { owner = "social", how = "actionEnded for argue / apologize" },
    fire = { owner = "events", how = "SS.Fire.Ignite from cooking, fireplaces, electrics, debug" },
    death = { owner = "events", how = "SS.Death.Kill from starvation, fire, electrocution, drowning" },
    mourning = { owner = "events", how = "follows every death" },
}

---------------------------------------------------------------------------------------------------
-- Fire (brief 16.1). Intensity 0..1 per burning cell; fuel is burnable minutes.
D.fire = {
    step = 1,                    -- the fire model advances once per sim minute
    faultAge = 6 * 60,           -- broken electrics become a fire risk only once left unrepaired this long
    startIntensity = 0.35,
    growth = 0.08,               -- intensity gained per minute while fuel remains (not while being fought)
    decay = 0.15,                -- intensity lost per minute once the fuel is gone
    spreadChance = 0.05,         -- per minute per neighbour at intensity 1 and neighbour fuel 40
    spreadMin = 0.5,             -- a cell spreads only at this intensity or more
    maxCells = 24,               -- bound per lot
    objectFuel = 40,             -- fuel an ordinary flammable object (fireRisk 1) adds to its cell
    floorFuel = { carpet = 28, rug = 28, wood = 18, deck = 18, plank = 18, parquet = 18, grass = 3, default = 0 },
    heatRate = 4,                -- object heat per minute at intensity 1 and fireRisk 1
    burntHeat = 24,              -- heat that leaves an object burnt (and broken)
    destroyHeat = 70,            -- heat that destroys an object and leaves charred remains
    minHeatFactor = 0.15,        -- even non-flammable things scorch slowly
    sourceFactor = 0.6,          -- the object the fire started on heats at least this fast
    sourceFuel = 15,             -- fuel of the ignition source itself (the pan, the frayed cable)
    doorBurn = 25,               -- intensity-minutes that burn a wooden door away to an open doorway
    scorchAfter = 4,             -- a cell that burned this long leaves a scorch mark
    smokeDelay = 1,              -- minutes before a covering smoke alarm detects a new cell
    alarmRange = 3,              -- coverage: same indoor room, or within N steps with no wall between (N = the
                                 -- alarm's def.quality.range when the catalogue sets one, else this)
    responseMin = 8,             -- fire service arrival after the call...
    responseJitter = 4,          -- ...plus 0..4 minutes
    neighbourDelay = 20,         -- a neighbour calls it in after this long if nobody has
    neighbourCells = 3,          -- ...or sooner once this many cells burn
    firefighters = 2,
    ffRate = 0.25,               -- intensity a firefighter removes per minute
    residentRate = 0.06,         -- intensity a resident removes per minute...
    residentSkill = 0.02,        -- ...plus this per mechanical level
    extinguisherBonus = 2,       -- multiplier when the lot has an object tagged "extinguisher"
    catchChance = 0.03,          -- per minute beside a cell while fighting it, scaled by intensity and skill
    standChance = 0.5,           -- per minute standing inside a burning cell
    onFireMinutes = 4,           -- a burning person who has not put themselves out by now dies (non-graphic)
    rollChance = 0.30,           -- per minute chance to put yourself out...
    rollBody = 0.04,             -- ...plus this per body level
    helpRange = 3,               -- a firefighter this close puts a burning person out at once
    panicMin = { 2, 4 },         -- first reaction
    safeDistance = 5,            -- flee target: outdoors and this far from every burning cell
    wakeRange = 3,               -- sleepers wake for a fire this close (or for an alarm)
    seeRange = 6,                -- awake people notice a fire in their room or this close on their level
    cellMapRefresh = 60,         -- the fire's object-per-cell map is rebuilt at least this often (minutes)
    dangerCost = 8,              -- extra route cost beside a burning cell
    inspectMinutes = 5,          -- firefighters check the scene before leaving
    maxTries = 8,                -- a responder that cannot reach work leaves after this many failed orders
    hoseRange = 2,               -- a firefighter who cannot reach a burning cell sprays it from this close
    fightBase = 0.25,            -- resident fight-or-flee weighing: base...
    fightSkill = 0.06,           -- ...plus this per mechanical level...
    fightExtinguisher = 0.25,    -- ...plus this with an extinguisher on the lot...
    fightPerCell = 0.12,         -- ...minus this per burning cell...
    fightIntensity = 0.35,       -- ...minus this times the strongest flame; fight when above 0
    fightMaxCells = 3,           -- nobody tackles a fire bigger than this themselves
    scrapValue = 5,              -- selling charred remains for scrap
    clearMinutes = 12,
    scrubMinutes = 8,
    restoreFactor = 0.3,         -- restoring a burnt object costs this share of its price
    fireRiskByCat = { seating = 1.2, sleeping = 1.2, surfaces = 0.9, decor = 1.0, storage = 1.0, kitchen = 0.3,
        plumbing = 0.05, electronics = 0.7, lighting = 0.6, skill = 0.9, outdoor = 0.6, kids = 1.0, community = 0.8,
        system = 0, default = 0.8 },
    material = { fabric = 1.4, wood = 1.0, paper = 1.6, plastic = 0.8, wicker = 1.3, leather = 1.1, metal = 0.1,
        chrome = 0.1, stone = 0, glass = 0, porcelain = 0.05, ceramic = 0.05, plant = 0.7 },
}

-- Fireplaces (tag "fireplace"): sparks can reach flammable things in front of a lit fireplace.
D.fireplace = {
    burnHours = 4,               -- a lit fire goes out on its own after this long
    sparkChance = 0.06,          -- per hour per flammable object within reach
    reach = 2,                   -- cells in front of the hearth
    unattended = 2,              -- risk multiplier when nobody on the lot is awake
    minRisk = 0.8,               -- only things this flammable catch sparks
}

---------------------------------------------------------------------------------------------------
-- Death and aftermath (brief 16.2-16.3). Every cause has warnings first.
D.death = {
    causes = {
        starvation = { label = "starvation", text = "%s died of hunger after days without a proper meal." },
        fire = { label = "fire", text = "%s was lost in the fire." },
        electrocution = { label = "electrocution", text = "%s took a fatal shock from faulty wiring." },
        drowning = { label = "drowning", text = "%s ran out of strength in the pool." },
        neglect = { label = "neglect", text = "%s did not survive being left without care." },
        unknown = { label = "misfortune", text = "%s has passed away." },
    },
    collapseMinutes = 2,         -- the non-graphic collapse before our own pathways call Kill
    registrarDelay = 45,         -- the Registrar arrives this long after a death...
    registrarJitter = 20,        -- ...plus 0..20 minutes
    registrarWork = 20,          -- minutes spent filing the paperwork at the memorial
    registrarStay = 70,          -- hard limit on the visit
    pleaChance = 0.25,           -- base chance that a plea succeeds (rolled once, at the death)...
    pleaCharisma = 0.03,         -- ...plus this per charisma level of the one pleading
    pleaMinutes = 5,
    mournHours = 48,             -- full grief lasts about this long (scaled by closeness)
    mournRates = { fun = -3, comfort = -2, social = -1 },   -- extra per hour at full grief
    mournRelief = 30,            -- grief removed per hour spent mourning at the memorial
    reactMinutes = 10,           -- witnesses stop and grieve on the spot
    ghost = { chance = 0.10, cooldown = 2 * 1440, from = 22, to = 4, stay = { 30, 60 }, scareRange = 5, scareCooldown = 60 },
}

-- Starvation pathway, driven hourly from Sim/Hazards.lua. Warnings escalate with Hunger; once
-- Hunger sits at -100 the clock below starts and resets as soon as they eat anything.
D.starvation = {
    warnings = {
        { at = -50, text = "%s is very hungry. Food, soon." },
        { at = -80, text = "%s is starving and getting weak.", emergency = "warning" },
        { at = -95, text = "%s will collapse without food.", emergency = "warning" },
    },
    critical = { after = 0, text = "%s is starving to death. Without food, the end comes within a day.", emergency = "emergency" },
    fading = { after = 8 * 60, text = "%s is fading from hunger (16 hours left).", emergency = "emergency" },
    last = { after = 16 * 60, text = "%s has hours left. Feed them now.", emergency = "emergency" },
    fatalAfter = 24 * 60,        -- minutes at -100 Hunger
}

-- Electrocution during electrical repair (household-core calls SS.Hazards.Electrocute).
D.electric = {
    shock = 0.30,                -- base shock chance at mechanical 0 (falls to 0 at level 10)
    wet = 0.25,                  -- extra when standing water is on or beside the cells involved
    fatal = 0.35,                -- after a shock, fatal chance when wet or shocked within `recent`
    recent = 24 * 60,
    shakenWhy = "Still shaken from the last shock; a repair service is safer.",
    minShock = 0.02,
    sparksMinutes = 3,
}

---------------------------------------------------------------------------------------------------
-- Other hazards.
D.burglary = {
    minValue = 1500,             -- lots worth less than this are not worth burgling
    valueScale = 400000,         -- chance rises with lot value: chance + value / valueScale (capped)
    maxChance = 0.05,
    minItemValue = 60,
    -- what a burglar will carry off (never the fridge, stove, bed or plumbing a household needs)
    cats = { electronics = true, decor = true, lighting = true, skill = true, kids = true, outdoor = true, seating = true, storage = true },
    grabMinutes = 6,
    freezeMinutes = 12,          -- an alarm freezes the burglar long enough for the police
    holdMinutes = 10,            -- ...and an officer already on the way in holds them this much longer (once)
    policeResponse = 6,          -- police arrive after the alarm or call...
    policeJitter = 2,            -- ...plus 0..2 minutes
    maxStay = 90,
    seeRange = 5,
    searchMinutes = 5,
    alarmRange = 10,             -- burglar alarm: indoor cells on its level within this many cells (or def.quality.range)
}

D.pests = {
    threshold = 5,               -- mess points in one room...
    hours = 24,                  -- ...sustained this many hours brings pests
    spreadHours = 12,            -- another colony every 12 hours while the mess stays
    cap = 3,                     -- colonies per lot
    sprayCost = 12,
    leaveHours = 24,             -- pests leave by themselves after a day without mess
    cooldown = 12 * 60,          -- after an extermination, pests need this long to return
    hygieneRate = -2,            -- extra hygiene loss per hour in a room with pests
    -- household-core names its mess objects by kind (def.mess = "plate", "trash", ...) and scores
    -- spoiled food, dirt, filth and full bins under the same kind names. Those kinds are worth
    -- these points here; an unknown kind counts 1. household-core's own weights
    -- (SS.Tuning.room.mess, on a larger scale) are used instead when present: kind weight / scale.
    kinds = { plate = 1, food = 1, spoiled = 3, trash = 2, bag = 1, binFull = 2, puddle = 1, dirty = 1, filthy = 2,
        unmade = 0, clutter = 1, broken = 1, wilted = 1, burnt = 2 },
    tuningScale = 4,             -- SS.Tuning.room.mess points per pest mess point
}

D.leak = {
    every = 120,                 -- a broken plumbing fixture adds a puddle this often
    cap = 3,                     -- puddles per leak
    near = 3,                    -- with household-core's leak puddles: those within this many cells of the fixture belong to the leak (it places them beside the fixture, shifted up to 2 cells when blocked)
}

D.breakdown = { eligibleCats = { kitchen = true, plumbing = true, electronics = true, lighting = true, skill = true } }

-- Comic surprises: original, harmless oddities, each with a consequence.
D.comic = {
    casserole = { hunger = 55, goodChance = 0.7, spoilAfter = 24 * 60 },
    parcel = { keepChance = 0.5, cash = { 20, 80 }, returnFun = 8,
        cats = { decor = true, lighting = true, kids = true },   -- what a stray parcel can hold...
        price = { 20, 150 },                                    -- ...in this price band (seeded pick)
        fallback = "plant_pot" },
    coins = { min = 5, max = 40 },
    pigeon = { shooChance = 0.7, fun = 8 },
    broadcast = { energyRate = -6 },
    gnome = { sale = 35 },
    hiccups = { hours = { 2, 4 }, comfortRate = -4 },
}

---------------------------------------------------------------------------------------------------
-- NPC identities used by this module's roles (stable ids, never re-created per visit).
D.npcs = {
    npc_fire_1 = { name = "Captain Odile Marsh", role = "firefighter", outfit = "firefighter",
        look = { skin = { 0.62, 0.45, 0.33 }, hair = { 0.15, 0.12, 0.10 }, hairStyle = "short", top = { 0.72, 0.20, 0.14 }, bottom = { 0.22, 0.22, 0.24 }, shoes = { 0.10, 0.10, 0.10 } } },
    npc_fire_2 = { name = "Firefighter Benji Okafor", role = "firefighter", outfit = "firefighter",
        look = { skin = { 0.40, 0.28, 0.20 }, hair = { 0.08, 0.07, 0.07 }, hairStyle = "short", top = { 0.72, 0.20, 0.14 }, bottom = { 0.22, 0.22, 0.24 }, shoes = { 0.10, 0.10, 0.10 } } },
    -- the visitors module's police pool lists this id too (SS.RoleData.pools.police); when that
    -- pool is loaded its identity is used, and this entry is only the stand-alone fallback
    npc_police_1 = { name = "Officer Dana Wexler", role = "police", outfit = "police",
        look = { skin = { 0.88, 0.70, 0.58 }, hair = { 0.55, 0.36, 0.20 }, hairStyle = "long", top = { 0.16, 0.22, 0.40 }, bottom = { 0.14, 0.16, 0.28 }, shoes = { 0.08, 0.08, 0.08 } } },
    npc_burglar_1 = { name = "Unknown Intruder", role = "burglar", outfit = "burglar",
        look = { skin = { 0.80, 0.62, 0.50 }, hair = { 0.10, 0.10, 0.10 }, hairStyle = "short", top = { 0.12, 0.12, 0.14 }, bottom = { 0.10, 0.10, 0.12 }, shoes = { 0.06, 0.06, 0.06 } } },
    npc_registrar = { name = "Mr. Hollis Vane", title = "Registrar of Departures", role = "registrar", outfit = "registrar",
        look = { skin = { 0.78, 0.76, 0.74 }, hair = { 0.62, 0.62, 0.64 }, hairStyle = "short", top = { 0.42, 0.44, 0.46 }, bottom = { 0.30, 0.31, 0.33 }, shoes = { 0.12, 0.10, 0.08 } } },
}

---------------------------------------------------------------------------------------------------
-- System objects (ARCHITECTURE.md 9.13): functional, not in the catalogue, never counted toward
-- the 168 designs. `fp = {}` with `noBlock = true` means the object occupies no cell (you can
-- walk over it); `invisible = true` means the renderer draws only its effects.
local AROUND = { approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }, face = 2 }
local function sys(def)
    def.cat, def.buyable, def.price = "system", false, def.price or 0
    def.env = def.env or 0
    def.ratings = def.ratings or {}
    def.system = "events"
    return def
end

SS.Objects = SS.Objects or {}
local O = SS.Objects

O.ev_flames = sys{
    name = "Fire", fp = {}, noBlock = true, invisible = true, env = -20,
    desc = "An actual fire. Get out, call for help, or fight it if it is small and you know what you are doing.",
    -- four slots in the "fight" group so several people (and both firefighters) can work one cell
    slots = {
        fight_s = { approaches = { { 0, 1 }, { -1, 1 } }, face = 2, group = "fight" },
        fight_w = { approaches = { { -1, 0 }, { -1, -1 } }, face = 3, group = "fight" },
        fight_n = { approaches = { { 0, -1 }, { 1, -1 } }, face = 0, group = "fight" },
        fight_e = { approaches = { { 1, 0 }, { 1, 1 } }, face = 1, group = "fight" },
    },
    actions = { "ev_extinguish" },
}
O.ev_charred = sys{
    name = "Charred Remains", env = -8, mess = 2,
    desc = "What used to be furniture, now mostly an opinion about furniture. Clear it away; it drags the whole room down until you do.",
    slots = { near = AROUND }, actions = { "ev_clear_charred", "ev_sell_charred" },
}
O.ev_scorch = sys{
    name = "Scorch Marks", fp = {}, noBlock = true, env = -3, mess = 1,
    desc = "Soot on the floor in the shape of a bad afternoon. A good scrub takes it off.",
    slots = { near = AROUND }, actions = { "ev_scrub_scorch" },
}
O.ev_grave = sys{
    name = "Memorial Headstone", env = 2, tags = { "memorial" },
    desc = "A plain stone with a name, two dates and room for flowers. Visiting helps the grief along.",
    slots = { front = AROUND }, actions = { "ev_mourn", "ev_respects" },
}
O.ev_urn = sys{
    name = "Memorial Urn", env = 2, tags = { "memorial" },
    desc = "A modest urn on a small plinth, engraved with a name. Visiting helps the grief along.",
    slots = { front = AROUND }, actions = { "ev_mourn", "ev_respects" },
}
O.ev_pests = sys{
    name = "Crumb Beetle Colony", fp = {}, noBlock = true, env = -12, mess = 2,
    desc = "A small, well-organised colony of crumb beetles. They arrived because of the mess and will stay for it.",
    slots = { near = AROUND }, actions = { "ev_spray_pests" },
}
O.ev_casserole = sys{
    name = "Mystery Casserole", fp = {}, noBlock = true, env = 0,
    desc = "A covered dish left on the step with a note: 'For the new people. Or the old people. Whoever.' It will not stay fresh forever.",
    slots = { near = AROUND }, actions = { "ev_eat_casserole", "ev_bin_casserole" },
}
O.ev_parcel = sys{
    name = "Misdelivered Parcel", fp = {}, noBlock = true, env = 0,
    desc = "Addressed to 'The Occupant, Probably'. It rattles in an intriguing way.",
    slots = { near = AROUND }, actions = { "ev_open_parcel", "ev_return_parcel" },
}
O.ev_pigeon = sys{
    name = "Indignant Pigeon", fp = {}, noBlock = true, env = -6,
    desc = "Came in through a gap nobody knew about. Now it lives here and has notes on the decor.",
    slots = { near = AROUND }, actions = { "ev_shoo_pigeon" },
}
O.ev_gnome = sys{
    name = "Wandering Garden Gnome", fp = {}, noBlock = true, env = 2,
    desc = "Appeared on the lawn overnight with a tiny suitcase. Seems to want to stay. A collector would pay for him.",
    slots = { near = AROUND }, actions = { "ev_adopt_gnome", "ev_sell_gnome" },
}
-- Fallback puddle, only if household-core has not defined one (it owns mopping and puddle
-- behaviour; events creates leak puddles). Theirs wins when present.
if not O.puddle then
    O.puddle = sys{
        name = "Puddle", fp = {}, noBlock = true, env = -6, mess = 1, wet = true,
        desc = "Water where water should not be. Slippery, dreary, and a poor place to fix electrics.",
        slots = { near = AROUND }, actions = { "ev_mop" },
    }
end
