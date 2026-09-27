-- Buy-mode catalogue: Plumbing (brief §8.1: at least 10 designs).
-- Owner: catalogue module. "toilet", "shower" and "washhands" are listed directly; tags toilet,
-- shower, bath, basin and sink let household-core attach bathing, dish washing, dirt, leaks and
-- repairs. Showers, baths and basins: the executor scales each wash's fixed hygiene/comfort gain by
-- the rating derived from rates (x(0.7 + 0.06 x rating)); toilets: rates.comfort is the seated
-- comfort share. quality.breakChance is the chance per use of a clog or leak (household-core's own
-- defaults: 0.003-0.006; budget designs use exactly those). quality.dirtRate is requested
-- (docs/requests/catalogue.md HC-3), not read yet. privacy = true: the bathroom privacy rule applies.
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("plumbing")
local var = K.var
local TOILET_SEAT = function() return { seat = { approaches = { { 0, 1 } }, face = 0, on = true, pose = "sit" } } end

add("toilet_basic", { -- original 0.1.0 object
    name = "Porcelain Diplomat Toilet", sub = "toilet", style = "starter", material = "porcelain", price = 300, env = 0,
    rooms = { "bathroom" }, height = 0.8, privacy = true,
    desc = "Handles every negotiation with quiet dignity and flushes at a volume that suggests it has feelings. Cold seat, basic comfort, clogs now and then.",
    rates = { comfort = 10 }, slots = TOILET_SEAT(), actions = { "toilet" }, tags = { "toilet" },
    quality = { breakChance = 0.006, dirtRate = 1.0, repairDifficulty = 2 },
    variants = var("white:White:0.96,0.96,0.95", "avocado:Avocado:0.56,0.62,0.30", "pink:Blush Pink:0.94,0.76,0.78"),
})

add("toilet_standard", {
    name = "Comfort-Height Toilet", sub = "toilet", style = "traditional", material = "porcelain", price = 600, env = 1,
    rooms = { "bathroom" }, height = 0.85, privacy = true,
    desc = "A taller bowl, a padded seat and a soft-close lid that ends the slamming debate forever. Twice as comfortable as budget models and clogs half as often.",
    rates = { comfort = 20 }, slots = TOILET_SEAT(), actions = { "toilet" }, tags = { "toilet" },
    quality = { breakChance = 0.003, dirtRate = 0.8, repairDifficulty = 2 },
    variants = var("white:White:0.96,0.96,0.95", "ivory:Ivory:0.96,0.92,0.82", "wood:Oak Seat:0.70,0.52,0.32"),
})

add("toilet_luxury", {
    name = "Throne of Tranquility Toilet", sub = "toilet", style = "contemporary", material = "porcelain", price = 1200, env = 3,
    rooms = { "bathroom" }, height = 0.9, privacy = true, powered = true,
    desc = "A heated seat, a built-in rinse and a glaze that gleams as if it has something to prove. The comfiest toilet in the catalogue, and it almost never clogs.",
    rates = { comfort = 36 }, slots = TOILET_SEAT(), actions = { "toilet" }, tags = { "toilet" },
    quality = { breakChance = 0.001, dirtRate = 0.4, repairDifficulty = 4 },
    variants = var("white:Gloss White:0.97,0.97,0.97", "black:Matte Black:0.14,0.14,0.15", "grey:Stone Grey:0.62,0.62,0.60"),
})

add("toilet_cistern", {
    name = "High-Cistern Pull-Chain Toilet", sub = "toilet", style = "eclectic", material = "porcelain", price = 750, env = 3,
    rooms = { "bathroom" }, height = 2.2, privacy = true, wallBack = true,
    desc = "A cast-iron tank up near the ceiling and a brass chain to summon a flush like a small indoor waterfall. Sturdier than the standard bowl and far more theatrical.",
    rates = { comfort = 16 }, slots = TOILET_SEAT(), actions = { "toilet" }, tags = { "toilet" },
    quality = { breakChance = 0.002, dirtRate = 0.9, repairDifficulty = 3 },
    variants = var("black:Black Tank:0.16,0.16,0.17", "green:Bottle Green:0.20,0.38,0.28", "white:White Tank:0.94,0.94,0.92"),
})

add("sink_pedestal", { -- original 0.1.0 object
    name = "Pedestal Sink with Mirror", sub = "sink", style = "starter", material = "porcelain", price = 150, env = 1,
    rooms = { "bathroom" }, height = 1.6,
    desc = "Wash your hands, check your teeth and practise saying no to the next dinner invitation. A small basin with a mirror above it.",
    rates = { hygiene = 180 }, slots = { front = K.front(1, "wash") }, actions = { "washhands" }, tags = { "basin", "mirror" },
    quality = { breakChance = 0.003, dirtRate = 1.0, repairDifficulty = 2 },
    variants = var("white:White:0.96,0.96,0.95", "blue:Powder Blue:0.70,0.80,0.90", "chrome:Chrome Taps:0.84,0.86,0.88"),
})

add("sink_vanity", {
    name = "Double Vanity Basin", sub = "sink", style = "traditional", material = "wood", price = 700, env = 4,
    rooms = { "bathroom" }, fp = K.rect(2, 1), height = 1.7,
    desc = "Two basins in a marble-topped cabinet, so a couple can brush their teeth side by side in resentful harmony. A more thorough wash than a pedestal sink.",
    rates = { hygiene = 240 },
    slots = { front1 = { approaches = { { 0, 1 } }, face = 2, group = "front", pose = "wash" }, front2 = { approaches = { { 1, 1 } }, face = 2, group = "front", pose = "wash" } },
    actions = { "washhands" }, tags = { "basin", "mirror" },
    quality = { breakChance = 0.0018, dirtRate = 0.8, repairDifficulty = 2 },
    variants = var("marble:White Marble:0.94,0.94,0.92", "walnut:Walnut & Granite:0.42,0.28,0.18", "sage:Sage & Brass:0.60,0.68,0.56"),
})

add("sink_washstand", {
    name = "Marble-Top Washstand", sub = "sink", style = "eclectic", material = "wood", price = 420, env = 3,
    rooms = { "bathroom", "bedroom" }, height = 1.7,
    desc = "A round china bowl sunk into a marble-topped stand with a tilting mirror, rescued from a hotel that never quite existed. Washes better than a pedestal sink, dresses the room better too.",
    rates = { hygiene = 210 }, slots = { front = K.front(1, "wash") }, actions = { "washhands" }, tags = { "basin", "mirror" },
    quality = { breakChance = 0.0022, dirtRate = 0.9, repairDifficulty = 2 },
    variants = var("marble:White Marble:0.94,0.94,0.92", "rose:Rose Marble:0.86,0.70,0.68", "slate:Slate Top:0.36,0.38,0.40"),
})

add("sink_kitchen_basic", {
    name = "Stainless Kitchen Sink", sub = "sink", style = "starter", material = "wood", price = 200, env = 0,
    rooms = { "kitchen" }, height = 1.1,
    desc = "A single steel bowl in a counter-height cabinet, for dishes, hand washing and the occasional houseplant rescue. Drips a little when it breaks.",
    rates = { hygiene = 150 }, slots = { front = K.front(1, "wash") }, actions = { "washhands" }, tags = { "sink" },
    quality = { speed = 1.0, breakChance = 0.004, dirtRate = 1.0, repairDifficulty = 2 },
    variants = var("white:White Cabinet:0.94,0.94,0.92", "wood:Wood Cabinet:0.76,0.58,0.38", "green:Green Cabinet:0.46,0.56,0.40"),
})

add("sink_kitchen_farmhouse", {
    name = "Farmhouse Apron Sink", sub = "sink", style = "traditional", material = "wood", price = 650, env = 3,
    rooms = { "kitchen" }, height = 1.15,
    desc = "A deep fireclay basin with a front apron and a bridge tap, big enough to bathe a roasting tin or a small dog. A more thorough hand wash than the basic sink, and half the breakdowns.",
    rates = { hygiene = 210 }, slots = { front = K.front(1, "wash") }, actions = { "washhands" }, tags = { "sink" },
    quality = { speed = 1.3, breakChance = 0.002, dirtRate = 0.8, repairDifficulty = 2 },
    variants = var("white:White Fireclay:0.96,0.96,0.95", "black:Black Fireclay:0.16,0.16,0.17", "copper:Hammered Copper:0.74,0.46,0.30"),
})

add("shower_basic", { -- original 0.1.0 object
    name = "Downpour Lite Shower", sub = "shower", style = "starter", material = "ceramic", price = 650, env = 0,
    rooms = { "bathroom" }, height = 2.1, privacy = true,
    desc = "Water pressure somewhere between a sigh and a firm suggestion, behind frosted glass for the modest. Gets the job done; the drain sulks now and then.",
    rates = { hygiene = 480, comfort = 18 }, slots = { stand = { approaches = { { 0, 1 } }, face = 0, on = true, group = "bath", pose = "shower" } },
    actions = { "shower" }, tags = { "shower" },
    quality = { breakChance = 0.005, dirtRate = 1.0, repairDifficulty = 2 },
    variants = var("frost:Frosted Glass:0.86,0.92,0.94", "white:White Tile:0.96,0.96,0.95", "blue:Blue Tile:0.50,0.66,0.84"),
})

add("shower_rain", {
    name = "Rainfall Glass Shower", sub = "shower", style = "contemporary", material = "stone", price = 1400, env = 4,
    rooms = { "bathroom" }, height = 2.2, privacy = true,
    desc = "A dinner-plate rain head behind clear glass, delivering water like a warm cloud with a grudge against grime. The most thorough clean in the catalogue, and comfier than a basic stall.",
    rates = { hygiene = 600, comfort = 30 }, slots = { stand = { approaches = { { 0, 1 } }, face = 0, on = true, group = "bath", pose = "shower" } },
    actions = { "shower" }, tags = { "shower" },
    quality = { breakChance = 0.0017, dirtRate = 0.6, repairDifficulty = 3 },
    variants = var("clear:Clear & Chrome:0.84,0.90,0.92", "black:Black Frame:0.16,0.16,0.17", "brass:Brushed Brass:0.84,0.70,0.42"),
})

add("bath_basic", {
    name = "Enamel Soaker Tub", sub = "bath", style = "starter", material = "porcelain", price = 700, env = 1,
    rooms = { "bathroom" }, fp = { { 0, 0 }, { 0, 1 } }, height = 0.7, privacy = true,
    desc = "A plain enamel bath for long soaks and longer excuses. Slower to clean you than a shower but kinder to sore feet; leaves a puddle if you climb out carelessly.",
    rates = { hygiene = 360, comfort = 24 },
    slots = { bath = { cell = { 0, 0 }, approaches = { { 1, 0 }, { -1, 0 }, { 1, 1 }, { -1, 1 } }, face = 0, on = true, group = "bath", pose = "bathe" } },
    tags = { "bath" },
    quality = { breakChance = 0.004, dirtRate = 1.0, repairDifficulty = 2 },
    variants = var("white:White:0.96,0.96,0.95", "avocado:Avocado:0.56,0.62,0.30", "peach:Peach:0.96,0.78,0.66"),
})

add("bath_shower_combo", {
    name = "Tub and Shower Combo", sub = "bath", style = "traditional", material = "porcelain", price = 900, env = 2,
    rooms = { "bathroom" }, fp = { { 0, 0 }, { 0, 1 } }, height = 2.1, privacy = true,
    desc = "A bath with a shower over it and a curtain that clings with real affection. One fixture covers both habits, so a small bathroom can offer showers and soaks.",
    rates = { hygiene = 420, comfort = 20 },
    slots = { stand = { cell = { 0, 0 }, approaches = { { 1, 0 }, { -1, 0 }, { 1, 1 }, { -1, 1 } }, face = 0, on = true, group = "bath", pose = "shower" } },
    actions = { "shower" }, tags = { "bath", "shower" },
    quality = { breakChance = 0.004, dirtRate = 0.9, repairDifficulty = 2 },
    variants = var("white:White & Floral Curtain:0.96,0.96,0.95", "blue:Blue & Stripe Curtain:0.50,0.66,0.84", "green:Green & Fern Curtain:0.50,0.66,0.46"),
})

add("bath_clawfoot", {
    name = "Clawfoot Heritage Bath", sub = "bath", style = "traditional", material = "porcelain", price = 2200, env = 7,
    rooms = { "bathroom" }, fp = { { 0, 0 }, { 0, 1 } }, height = 0.85, privacy = true,
    desc = "Cast iron on four brass lion's feet, deep enough to read an entire novel in before the water cools. A premium soak that cleans as well as a shower and far more comfortably.",
    rates = { hygiene = 480, comfort = 34 },
    slots = { bath = { cell = { 0, 0 }, approaches = { { 1, 0 }, { -1, 0 }, { 1, 1 }, { -1, 1 } }, face = 0, on = true, group = "bath", pose = "bathe" } },
    tags = { "bath" },
    quality = { breakChance = 0.002, dirtRate = 0.8, repairDifficulty = 3 },
    variants = var("white:White & Brass:0.96,0.96,0.95", "black:Black & Chrome:0.14,0.14,0.15", "rose:Rose & Gold:0.86,0.62,0.62"),
})

add("bath_jet", {
    name = "Whirlpool Jet Spa Bath", sub = "bath", style = "contemporary", material = "porcelain", price = 3500, env = 8,
    rooms = { "bathroom" }, fp = K.rect(2, 2), height = 0.7, privacy = true, powered = true,
    desc = "A corner tub with twelve jets and a control panel that promises moods. The most luxurious soak money can buy; the pump needs power and an occasional repair.",
    rates = { hygiene = 540, comfort = 42 },
    slots = { bath = { cell = { 0, 0 }, approaches = { { -1, 0 }, { 0, -1 }, { 2, 0 }, { 0, 2 } }, face = 0, on = true, group = "bath", pose = "bathe" } },
    tags = { "bath" },
    quality = { breakChance = 0.003, dirtRate = 0.6, repairDifficulty = 5 },
    variants = var("white:Arctic White:0.97,0.97,0.97", "sand:Desert Sand:0.88,0.80,0.66", "black:Midnight:0.12,0.12,0.14"),
})
