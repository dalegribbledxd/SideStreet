-- SideStreet visitors data: role templates, stable NPC identities, services and prices, food menu,
-- vehicle kinds, townie fallback pool, phone call tuning and every visitors tuning knob.
-- Owner: visitors module. Behaviour lives in Sim/Street.lua, Sim/Visitors.lua, Sim/Services.lua and
-- Sim/Phone.lua. Everything here is plain data; prices follow ARCHITECTURE.md §9.7 (services charge
-- §10-§50 per hour plus call-outs).
--
-- This file loads in the data phase, before every Sim file. It also creates the early registries
-- (SS.Visitors.RegisterRole, SS.Phone.RegisterCall, SS.Street) so modules whose Sim files load before
-- Sim/Visitors.lua (careers) can register roles and calls at load time. Sim/Visitors.lua and
-- Sim/Phone.lua take over the same tables and process anything registered early.
local _, SS = ...
SS.Roles = SS.Roles or {}

local RD = {}
SS.RoleData = RD

---------------------------------------------------------------------------------------------------
-- Tuning (sim minutes unless noted). Every visitor timer, cap and chance is here.
RD.tuning = {
    -- simultaneous role actors on one lot, per class; requests over the cap queue (defer) instead
    caps = { social = 10, service = 3, delivery = 2, walkby = 2, emergency = 6, intruder = 2, staff = 10, household = 99, other = 4 },
    requestCap = 64,          -- request records kept (settled ones are pruned first)
    historyCap = 30,          -- visit history rows kept per save
    timerCap = 200,           -- saved visitor timers: ambient ones (walk-bys, paper, mail) stop here
    timerHardCap = 400,       -- required timers (arrivals, returns) may use the rest, then fail loudly
    resumeGap = 30,           -- a lot whose clock moved this many minutes while it was not simulated
                              -- sends its visitors home (paid up to the last simulated minute)
    workProgressCap = 16,     -- saved per-task work progress entries per worker
    maxRequeue = 3,           -- a visitor still on the way when the lot is left comes again at most this often
    maxLate = 720,            -- a social visit or delivery more than 12 h overdue is dropped
    deferMinutes = 20,        -- a capped request retries after this
    maxDefers = 3,            -- ... this many times, then it is cancelled with a notice
    -- bounded pathfinding: attempts per goal and the pause between attempts (A35)
    routeRetries = 3, routeCooldown = 10,
    exitRetries = 3, exitCooldown = 5,
    entryRetries = 3, entryCooldown = 10,
    -- door
    doorWait = 60,            -- uninvited visitor waits this long for an answer
    doorWaitInvited = 90,     -- invited visitor waits longer
    doorWaitGreeted = 30,     -- greeted but not invited in: lingers this long for "Invite In"
    friendLetIn = 20,         -- invited close friends let themselves in after this
    friendLife = 50,          -- life score (visitor -> any member) that makes a close friend
    walkInDelay = 5,          -- invited party guests with walkIn come straight in after this
    reRing = 20, maxRings = 3,
    -- visiting
    visitMin = 150, visitMax = 300,            -- length of an ordinary visit
    nightStart = 23, nightEnd = 6,             -- guests leave in these hours (party guests use stayUntil)
    leaveEnergy = -50, leaveHunger = -60, leaveMood = -40,
    nobodyHome = 15,                           -- minutes without any household member before guests go
    checkEvery = 5,                            -- guest leave/cooldown checks
    admireCool = 90, admirePrice = 800,        -- guest admiring an expensive ornament
    -- relationship effects (daily, life), applied through SS.Social.Change when present
    rel = {
        greet = { 6, 1 }, invite = { 8, 2 }, ignored = { -8, -2 }, refused = { -10, -3 }, refusedInvited = { -15, -5 },
        goodVisit = { 4, 2 }, gift = { 5, 2 }, wave = { 2, 0 }, chat = { 6, 2 }, badtime = { -4, -1 }, visitChat = { 3, 1 },
    },
    -- ambient visitors
    walkby = { first = 7, last = 21, perHour = 0.45, maxPerHour = 2, personCool = 180 },
    social = { first = 9, last = 20, base = 0.03, relBonus = 0.10, globalCool = 480, personCool = 1440, minRel = 10 },
    welcome = { min = 2, max = 3, earliest = 10, latest = 17, newGameDays = 2, maxTries = 3, retryGap = 360 },
    invite = { lead = 30, window = 60, earliest = 8, latest = 21, baseAccept = 0.55 },
    paper = { hour = 6, spread = 45, maxPile = 3 },
    mail = { hour = 10, spread = 60, weekdays = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true } },
    townieMin = 4,            -- fallback neighbours are created only while fewer townies exist
    -- default minutes on the lot per role class when a role sets no `timeout` (false = never)
    classTimeout = { social = 600, walkby = 30, delivery = 90, service = 360, emergency = 360, intruder = 240,
        staff = false, household = 180, other = 480 },
    -- ages that may spend household money (book services, order food, pay the courier)
    payAges = { adult = true, teen = true, elder = true, young_adult = true },
    -- street geometry, in tiles beyond the lot's j = h edge (the renderer's road band is 2 tiles)
    geometry = { sidewalk = 0.3, curb = 0.7, lane = 1.25, farLane = 1.75, band = 2, sidewalkEnd = 0.8 },
    vehicle = { arrive = 1.5, leave = 1.5, travel = 12, wait = 30, maxWait = 240, cap = 6, boardGrace = 0.5 },
}

---------------------------------------------------------------------------------------------------
-- Vehicle kinds (SS.Street.vehicles[n].kind). len in tiles along the street; livery picks a paint
-- variant of the same model. The art module draws these (docs/art_requests/visitors.md).
RD.vehicles = {
    carpool          = { label = "Carpool", len = 2, owner = "careers" },
    -- careers' carpool rises with career level (careers V1; designs in careers' art requests)
    hatchback        = { label = "Carpool", len = 2, owner = "careers" },
    sedan            = { label = "Carpool", len = 2, owner = "careers" },
    estate           = { label = "Carpool", len = 2, owner = "careers" },
    towncar          = { label = "Town Car", len = 3, owner = "careers" },
    limousine        = { label = "Limousine", len = 4, owner = "careers" },
    school_bus       = { label = "School Bus", len = 4, owner = "careers" },
    taxi             = { label = "Taxi", len = 2, owner = "outings" },
    fire_truck       = { label = "Fire Engine", len = 4, owner = "events" },
    police_car       = { label = "Patrol Car", len = 2, owner = "events" },
    service_van      = { label = "Service Van", len = 3, owner = "visitors" },
    delivery_scooter = { label = "Delivery Scooter", len = 1, owner = "visitors" },
    mail_van         = { label = "Mail Van", len = 3, owner = "visitors" },
    car              = { label = "Car", len = 2, owner = "any" },
}

---------------------------------------------------------------------------------------------------
-- Built-in roles (behaviour attached in Sim/Visitors.lua and Sim/Services.lua).
-- access: public | guest | service | household | intruder | emergency | staff
-- class: cap group. arrive: door | door_enter | direct | sidewalk | none (see docs/modules/visitors.md)
-- outfit: uniform style id for the art module (NPC look.outfits.work.style); nil = own clothes.
RD.roles = {
    guest = { label = "Guest", access = "guest", class = "social", arrive = "door", useAutonomy = true, timeout = 600, social = true,
        desc = "A friend, neighbour or party guest. Waits at the door until greeted; visits with guest permissions." },
    walkby = { label = "Passer-by", access = "public", class = "walkby", arrive = "sidewalk", noNeeds = true, timeout = 30, social = true,
        desc = "A neighbour walking past on the sidewalk." },
    paper = { label = "Paper Carrier", access = "public", class = "delivery", arrive = "sidewalk", noNeeds = true, timeout = 30, social = false,
        pool = "paper", outfit = "paper_carrier", desc = "Tosses the morning paper onto the lot." },
    mail = { label = "Mail Carrier", access = "service", class = "delivery", arrive = "direct", vehicle = "mail_van", noNeeds = true, social = false,
        timeout = 45, pool = "mail", outfit = "mail_carrier", desc = "Brings the post to the mailbox." },
    courier = { label = "Delivery Courier", access = "service", class = "delivery", arrive = "door", vehicle = "delivery_scooter", social = false,
        noNeeds = true, timeout = 90, doorWait = 30, pool = "courier", outfit = "courier", desc = "Hands over a meal at the door." },
    cleaner = { label = "Cleaner", access = "service", class = "service", arrive = "door_enter", vehicle = "service_van", livery = "cleaner",
        noNeeds = true, social = false, timeout = 300, pool = "cleaner", outfit = "cleaner_tunic", desc = "Mops puddles, clears dishes and rubbish, scrubs fixtures." },
    repair = { label = "Repair Technician", access = "service", class = "service", arrive = "door_enter", vehicle = "service_van", livery = "repair",
        noNeeds = true, social = false, timeout = 360, pool = "repair", outfit = "repair_overalls", desc = "Fixes broken objects with real in-world work." },
    gardener = { label = "Gardener", access = "service", class = "service", arrive = "door_enter", vehicle = "service_van", livery = "garden",
        noNeeds = true, social = false, timeout = 240, pool = "gardener", outfit = "gardener_apron", desc = "Waters and weeds plants that need it." },
    departing = { label = "Heading Out", access = "household", class = "household", arrive = "none", internal = true, timeout = 180 },
    arriving = { label = "Coming Home", access = "household", class = "household", arrive = "none", internal = true, timeout = 120 },
}

---------------------------------------------------------------------------------------------------
-- Services (§15.2; the cleaner, repair technician, gardener and food delivery are the visitors
-- module's; fire, police, child welfare and bill collection are other modules' roles).
-- callout + rate per hour, billed per started quarter hour of work, one ledger entry at completion
-- or departure. open/close: hours the service will arrive; calls outside them book the next opening.
RD.services = {
    cleaner = {
        label = "Cleaner", role = "cleaner", callout = 20, rate = 15, open = 8, close = 18, leadMin = 30, leadMax = 90,
        maxWork = 180, regular = true, needsWork = true,
        desc = "Mops puddles, clears dirty dishes and rubbish, empties full bins and scrubs dirty fixtures, in that order.",
        noWork = "Nothing needs cleaning right now.",
    },
    repair = {
        label = "Repair Technician", role = "repair", callout = 35, rate = 40, open = 7, close = 20, leadMin = 45, leadMax = 120,
        maxWork = 240, attempts = 3, success = 0.9, needsWork = true,
        desc = "Fixes objects that are actually broken. Each repair takes real time on site and can take more than one try.",
        noWork = "Nothing is broken right now.",
    },
    gardener = {
        label = "Gardener", role = "gardener", callout = 15, rate = 20, open = 7, close = 19, leadMin = 30, leadMax = 90,
        maxWork = 120, regular = true, needsWork = true,
        desc = "Waters and weeds plants that need care.",
        noWork = "No plants need watering or weeding right now.",
    },
    food = {
        label = "Food Delivery", role = "courier", fee = 8, open = 10, close = 23, leadMin = 25, leadMax = 45,
        desc = "A hot meal brought to the door. Someone has to answer and pay; unanswered deliveries are not charged.",
    },
}
RD.chargeWhenNoWork = false     -- a worker who finds nothing to do leaves without charging
RD.quarter = 15                 -- billing unit in minutes

-- Food delivery menu (original dishes). servings feed that many people.
RD.menu = {
    { id = "casserole", name = "Corner Kitchen Casserole Box", price = 32, servings = 4, hunger = 60,
      desc = "Four hearty portions of something baked and bubbling." },
    { id = "noodles", name = "Noodle Nook Family Tray", price = 28, servings = 4, hunger = 55,
      desc = "Noodles for four, chopsticks for three, forks for the rest." },
    { id = "pie", name = "Hot Wheel Veggie Pie", price = 36, servings = 6, hunger = 50,
      desc = "Six generous slices; the crust arrives slightly before the filling." },
}
RD.mealSpoilAfter = 1440        -- a delivered meal left for a day spoils

-- Cleaner task kinds in priority order (lower first) and household-core chore names they map to.
RD.cleanPriority = { puddle = 1, dishes = 2, rubbish = 3, bin = 3, fixture = 4 }
RD.cleanChore = { puddle = "mop", dishes = "dishes", rubbish = "rubbish", bin = "empty_bin", fixture = "scrub" }
RD.cleanMinutes = { puddle = 6, dishes = 5, rubbish = 5, bin = 5, fixture = 10 }
RD.repairPriority = { plumbing = 1, kitchen = 2, electronics = 3, lighting = 4 }
RD.repairBase, RD.repairPerDifficulty = 20, 10  -- minutes of work per repair attempt
RD.tendMinutes = 15
RD.plantTags = { "garden_plot", "planter", "tree", "shrub", "flowers", "birdbath" }

---------------------------------------------------------------------------------------------------
-- Stable NPC identities per role pool. The same person tends to come back (a household's regular
-- cleaner). Pools for other modules' roles are optional conveniences: a role with `pool = "police"`
-- uses these; roles without a pool get generated stable ids npc_<role>_<n>.
local function look(skin, hair, style, top, bottom, shoes, uniform)
    return {
        skin = skin, hair = hair, hairStyle = style, body = "average", face = 1,
        top = top, bottom = bottom, shoes = shoes,               -- legacy everyday colours (renderer reads these)
        outfits = { everyday = { style = uniform or "everyday", top = top, bottom = bottom, shoes = shoes },
                    work = { style = uniform or "everyday", top = top, bottom = bottom, shoes = shoes } },
    }
end
local SKIN = { { 0.96, 0.80, 0.66 }, { 0.87, 0.67, 0.52 }, { 0.72, 0.52, 0.38 }, { 0.55, 0.38, 0.26 }, { 0.40, 0.27, 0.18 }, { 0.93, 0.74, 0.58 } }
local HAIR = { { 0.12, 0.10, 0.09 }, { 0.35, 0.20, 0.12 }, { 0.62, 0.42, 0.20 }, { 0.80, 0.70, 0.45 }, { 0.55, 0.55, 0.55 }, { 0.50, 0.18, 0.10 } }
local SHOE = { 0.18, 0.16, 0.15 }
RD.uniforms = {
    cleaner_tunic   = { top = { 0.55, 0.45, 0.70 }, bottom = { 0.26, 0.26, 0.32 } },
    repair_overalls = { top = { 0.88, 0.55, 0.18 }, bottom = { 0.28, 0.33, 0.46 } },
    gardener_apron  = { top = { 0.36, 0.56, 0.26 }, bottom = { 0.46, 0.37, 0.24 } },
    courier         = { top = { 0.82, 0.22, 0.20 }, bottom = { 0.16, 0.16, 0.19 } },
    mail_carrier    = { top = { 0.32, 0.46, 0.70 }, bottom = { 0.21, 0.23, 0.31 } },
    paper_carrier   = { top = { 0.90, 0.76, 0.22 }, bottom = { 0.30, 0.36, 0.56 } },
    firefighter     = { top = { 0.76, 0.22, 0.16 }, bottom = { 0.22, 0.22, 0.22 } },
    police          = { top = { 0.20, 0.26, 0.46 }, bottom = { 0.15, 0.17, 0.25 } },
    collector       = { top = { 0.44, 0.44, 0.47 }, bottom = { 0.30, 0.30, 0.33 } },
    welfare         = { top = { 0.56, 0.62, 0.50 }, bottom = { 0.32, 0.30, 0.28 } },
    staff           = { top = { 0.95, 0.93, 0.88 }, bottom = { 0.18, 0.18, 0.20 } },
}
local function uni(name, n)
    local u = RD.uniforms[name]
    return look(SKIN[(n - 1) % #SKIN + 1], HAIR[(n * 2 - 1) % #HAIR + 1], (n % 2 == 0) and "long" or "short", u.top, u.bottom, SHOE, name)
end
RD.pools = {
    cleaner  = { { id = "npc_cleaner_1", name = "Marisol Pettibone", pronoun = "she", n = 1 }, { id = "npc_cleaner_2", name = "Gus Whitlow", pronoun = "he", n = 4 },
                 { id = "npc_cleaner_3", name = "Ines Oduya", pronoun = "she", n = 5 } },
    repair   = { { id = "npc_repair_1", name = "Tobias Crane", pronoun = "he", n = 2 }, { id = "npc_repair_2", name = "Ruth Kaminski", pronoun = "she", n = 1 },
                 { id = "npc_repair_3", name = "Deshawn Ellery", pronoun = "he", n = 4 } },
    gardener = { { id = "npc_gardener_1", name = "Ffion Marsh", pronoun = "she", n = 6 }, { id = "npc_gardener_2", name = "Otis Fairweather", pronoun = "he", n = 3 } },
    courier  = { { id = "npc_courier_1", name = "Kip Yamada", pronoun = "he", n = 2 }, { id = "npc_courier_2", name = "Lottie Brennan", pronoun = "she", n = 1 },
                 { id = "npc_courier_3", name = "Samir Haddad", pronoun = "he", n = 3 } },
    mail     = { { id = "npc_mail_1", name = "Vera Oakes", pronoun = "she", n = 5 }, { id = "npc_mail_2", name = "Hollis Grant", pronoun = "he", n = 4 } },
    paper    = { { id = "npc_paper_1", name = "Benny Tran", pronoun = "he", n = 6 }, { id = "npc_paper_2", name = "Maisie Fold", pronoun = "she", n = 2 } },
    -- optional pools for other modules' roles
    firefighter = { { id = "npc_firefighter_1", name = "Captain Bea Holloway", pronoun = "she", n = 3 }, { id = "npc_firefighter_2", name = "Arlo Quist", pronoun = "he", n = 1 },
                    { id = "npc_firefighter_3", name = "Pim Achterberg", pronoun = "he", n = 4 }, { id = "npc_firefighter_4", name = "Sunny Okafor", pronoun = "she", n = 5 } },
    police   = { { id = "npc_police_1", name = "Officer Dana Wexler", pronoun = "she", n = 2 }, { id = "npc_police_2", name = "Officer Lyle Bristow", pronoun = "he", n = 6 } },
    collector = { { id = "npc_collector_1", name = "Mortimer Glass", pronoun = "he", n = 1 }, { id = "npc_collector_2", name = "Priya Lomax", pronoun = "she", n = 4 } },
    welfare  = { { id = "npc_welfare_1", name = "Harriet Voss", pronoun = "she", n = 2 }, { id = "npc_welfare_2", name = "Emeka Rowe", pronoun = "he", n = 5 } },
}
local POOL_UNIFORM = { cleaner = "cleaner_tunic", repair = "repair_overalls", gardener = "gardener_apron", courier = "courier", mail = "mail_carrier",
    paper = "paper_carrier", firefighter = "firefighter", police = "police", collector = "collector", welfare = "welfare" }
RD.poolUniform = POOL_UNIFORM
for pool, list in pairs(RD.pools) do
    for _, e in ipairs(list) do e.look = uni(POOL_UNIFORM[pool] or "staff", e.n) end
end
RD.skills = { cleaner = { cooking = 2, mechanical = 3 }, repair = { mechanical = 9, logic = 4 }, gardener = { creativity = 3 } }

-- Generated look for a role without a pool entry (stable per index n).
function RD.GeneratedLook(uniformName, n)
    return uni(RD.uniforms[uniformName] and uniformName or "staff", n or 1)
end

---------------------------------------------------------------------------------------------------
-- Fallback neighbours. The hood module owns the real townie pool; these are created only while a
-- save has fewer than tuning.townieMin townies, so walk-bys, welcome visits, invitations and calls
-- always have real, persistent people to use. Ids are stable (tn_*); they never duplicate.
RD.townies = {
    { id = "tn_delphine", name = "Delphine Arkwright", pronoun = "she", age = "adult",
      bio = "Retired choir director who reviews every lawn on the street, out loud.",
      personality = { neat = 8, outgoing = 7, active = 3, playful = 4, nice = 6 },
      look = look(SKIN[1], HAIR[5], "long", { 0.62, 0.30, 0.42 }, { 0.30, 0.28, 0.35 }, SHOE) },
    { id = "tn_walt", name = "Walt Pemberton", pronoun = "he", age = "adult",
      bio = "Walks a dog that isn't his. The owner has never complained.",
      personality = { neat = 4, outgoing = 8, active = 7, playful = 6, nice = 7 },
      look = look(SKIN[2], HAIR[2], "short", { 0.30, 0.52, 0.40 }, { 0.42, 0.36, 0.28 }, SHOE) },
    { id = "tn_yusuf", name = "Yusuf Adeyemi", pronoun = "he", age = "adult",
      bio = "Night-shift baker. Knows everyone's order and most of their secrets.",
      personality = { neat = 6, outgoing = 5, active = 5, playful = 7, nice = 8 },
      look = look(SKIN[5], HAIR[1], "short", { 0.86, 0.80, 0.62 }, { 0.22, 0.24, 0.30 }, SHOE) },
    { id = "tn_clementine", name = "Clementine Rook", pronoun = "she", age = "adult",
      bio = "Amateur astronomer, professional over-sharer.",
      personality = { neat = 3, outgoing = 9, active = 4, playful = 8, nice = 5 },
      look = look(SKIN[3], HAIR[6], "long", { 0.90, 0.58, 0.20 }, { 0.20, 0.30, 0.46 }, SHOE) },
    { id = "tn_marco", name = "Marco Villanueva", pronoun = "he", age = "adult",
      bio = "Runs the street's unofficial tool library from his garage.",
      personality = { neat = 5, outgoing = 6, active = 8, playful = 5, nice = 7 },
      look = look(SKIN[4], HAIR[1], "short", { 0.25, 0.35, 0.60 }, { 0.40, 0.40, 0.42 }, SHOE) },
    { id = "tn_hattie", name = "Hattie Lindqvist", pronoun = "she", age = "adult",
      bio = "Knits cosies for objects that did not ask for them.",
      personality = { neat = 7, outgoing = 4, active = 2, playful = 6, nice = 9 },
      look = look(SKIN[6], HAIR[4], "long", { 0.70, 0.78, 0.55 }, { 0.46, 0.30, 0.30 }, SHOE) },
}

---------------------------------------------------------------------------------------------------
-- Phone (§12 household communication). Incoming calls roll on the hour.
RD.phone = {
    first = 9, last = 21,          -- incoming calls only in these hours
    chance = 0.12,                 -- per hour when allowed
    cool = 240,                    -- minutes between incoming calls
    ringFor = 4,                   -- minutes the phone rings before the call is missed
    missedCap = 10,
    friendRel = 15,                -- chat and invite calls only come from people this friendly (best
                                   -- mutual daily + life with a member, see SS.Visitors.BestRel)
    chatRel = 0,                   -- outgoing "Chat on the Phone" needs someone the household has met
    kinds = { { id = "chat", w = 40 }, { id = "invite", w = 35 }, { id = "news", w = 25 } },
    len = { chat = 20, invite = 5, news = 8, badtime = 3, missed = 0 },
    callLen = 3,                   -- default minutes on the phone for an outgoing call
    chatLen = 20,
    categories = {
        -- Emergency first (events' request: the fire service and police are the calls to find fast)
        { id = "Emergency", label = "Emergency" }, { id = "Services", label = "Services" }, { id = "Friends", label = "Friends" },
        { id = "Travel", label = "Travel" }, { id = "Family", label = "Family" }, { id = "Other", label = "Other" },
    },
}

-- Sound effect ids requested from the audio director (SS.Audio.Sfx / Loop; guarded calls).
RD.sfx = { doorbell = "doorbell", knock = "knock", ring = "phone_ring", pickup = "phone_pickup", hangup = "phone_hangup",
    arrive = "vehicle_arrive", leave = "vehicle_leave", paper = "paper_thud", mail = "mail_drop", till = "cash" }

---------------------------------------------------------------------------------------------------
-- Authored text owned by this module, kept in one place so it can be localised or swapped. Spoken
-- character lines go through the social module's pool (SS.Lines.Say situations); these are the
-- narration and flavour strings visitors shows itself. Look up with SS.Visitors.Text(key[, n]).
RD.text = {
    -- what a caller shares on a news call (one picked at random)
    news = {
        "the corner shop is doing two-for-one on something nobody can identify",
        "somebody's hedge has been sculpted into a shape the street is still arguing about",
        "the bus timetable changed and nobody told the bus",
        "there's a lost cat poster up for a cat that is sitting right next to it",
        "the community noticeboard now has a noticeboard of its own",
    },
    -- the newsdesk rings when nobody the household knows is around to call
    newsdesk = "The morning paper's newsdesk",
    newsdeskCall = "%s rang to read out a headline: %s.",
    -- a delivered meal with no surface or floor spot to go on
    mealNowhere = " (There was nowhere to put it down, so it was eaten on the doorstep.)",
    -- system objects placed by visitors
    objects = {
        newspaper = { name = "Morning Paper", desc = "Today's news, folded tight enough to stun a hedge. Job listings inside." },
        welcome_treats = { name = "Plate of Welcome Treats",
            desc = "Homemade biscuits from the neighbours. Some are shaped like the house; one is shaped like a question." },
        delivery_meal = { name = "Takeaway Meal", desc = "Still warm. The lid says 'Enjoy!' in a font that has clearly been through a lot." },
        delivery_box = { name = "Empty Takeaway Box", desc = "Evidence. Grease-spotted, fragrant, and destined for the bin." },
    },
}

---------------------------------------------------------------------------------------------------
-- Early registries (see the header). Sim/Visitors.lua, Sim/Phone.lua and Sim/Street.lua extend these
-- same tables, so a role or call registered here keeps working.
local V = SS.Visitors or {}
SS.Visitors = V
V.roles = V.roles or {}
if not V.RegisterRole then
    function V.RegisterRole(name, def)
        def = def or {}
        V.roles[name] = def
        SS.Roles[name] = def      -- re-wrapped by Sim/Visitors.lua when it loads
        return def
    end
end
local Ph = SS.Phone or {}
SS.Phone = Ph
Ph.calls = Ph.calls or {}
if not Ph.RegisterCall then
    function Ph.RegisterCall(def) Ph.calls[def.id] = def; return def end
end
local St = SS.Street or {}
SS.Street = St
St.vehicles = St.vehicles or {}
