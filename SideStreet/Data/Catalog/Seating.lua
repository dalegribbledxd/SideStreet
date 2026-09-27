-- Buy-mode catalogue: Seating (brief §8.1: at least 16 designs).
-- Owner: catalogue module. Behaviour: "sit" (household-core) is listed directly; tags seat/sofa let
-- household-core attach more (eat at a table, nap on a sofa, watch TV from a seat facing it).
-- rates.comfort is the comfort per sim hour the executor applies while seated (Actions.lua uses def.rates).
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("seating")
local var = K.var

add("chair_folding", {
    name = "Foldaway Guest Chair", sub = "dining", style = "starter", material = "metal", price = 60, env = 0,
    rooms = { "dining", "kitchen", "living" }, height = 0.9,
    desc = "Folds flat for the cupboard and unfolds with a noise like a small argument. One seat, minimal comfort, maximum readiness for surprise guests.",
    rates = { comfort = 12 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("steel:Steel Grey:0.62,0.64,0.66", "beige:Beige:0.86,0.80,0.68", "black:Black:0.18,0.18,0.20"),
})

add("chair_dining", { -- original 0.1.0 object (saves reference this id)
    name = "Ladderback Dining Chair", sub = "dining", style = "starter", material = "wood", price = 80, env = 1,
    rooms = { "dining", "kitchen" }, height = 1.0,
    desc = "Upright, wooden and quietly certain that posture is a moral issue. One seat that pairs with any table it faces; fair comfort, sermons included.",
    rates = { comfort = 18 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("pine:Pine:0.80,0.62,0.40", "oak:Oak:0.66,0.48,0.30", "painted:Farmhouse White:0.93,0.92,0.88"),
})

add("chair_bistro", {
    name = "Bentwood Cafe Chair", sub = "dining", style = "eclectic", material = "wood", price = 110, env = 2,
    rooms = { "dining", "kitchen", "venue" }, height = 0.95,
    desc = "Steam-bent beech curled into the shape of a very relaxed pretzel. Light enough to drag to the window, sturdy enough to survive the argument about dragging it back.",
    rates = { comfort = 22 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("walnut:Walnut Stain:0.45,0.30,0.18", "black:Black Lacquer:0.15,0.14,0.14", "red:Pillar-Box Red:0.72,0.16,0.14"),
})

add("chair_padded", {
    name = "Upholstered Dining Chair", sub = "dining", style = "traditional", material = "fabric", price = 120, env = 2,
    rooms = { "dining" }, height = 1.05,
    desc = "A cushioned seat and a button-tufted back for dinners that run long because nobody wants to stand up first. The comfiest dining seat in the budget aisle.",
    rates = { comfort = 26 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("damask:Rose Damask:0.72,0.48,0.50", "sage:Sage Linen:0.62,0.70,0.58", "navy:Navy Velvet:0.20,0.24,0.40"),
})

add("chair_desk_basic", {
    name = "Swivel Task Chair", sub = "desk", style = "starter", material = "fabric", price = 90, env = 0,
    rooms = { "study", "bedroom" }, height = 1.0,
    desc = "Five casters, one gas lift and a lean-back mechanism that engages whenever the phone rings. Adequate comfort for homework, taxes and pretending to do either.",
    rates = { comfort = 20 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("charcoal:Charcoal:0.24,0.25,0.27", "blue:Office Blue:0.22,0.34,0.56", "teal:Teal:0.16,0.50,0.50"),
})

add("chair_desk_exec", {
    name = "Executive Lumbar Throne", sub = "desk", style = "contemporary", material = "leather", price = 650, env = 3,
    rooms = { "study" }, height = 1.3,
    desc = "Leather-look, high-backed and adjustable in eleven directions, three of them useful. Makes any desk feel like a corner office; the salary is sold separately.",
    rates = { comfort = 40 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("black:Black Leather:0.12,0.12,0.13", "oxblood:Oxblood:0.42,0.12,0.12", "cream:Cream:0.90,0.86,0.76"),
})

add("stool_kitchen", {
    name = "Counter Perch Stool", sub = "stool", style = "starter", material = "wood", price = 65, env = 0,
    rooms = { "kitchen", "dining" }, height = 0.7,
    desc = "A round seat on a tall stalk, built for breakfast at the counter. Backless by design, which discourages lingering and encourages posture.",
    rates = { comfort = 12 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("birch:Birch:0.88,0.76,0.58", "black:Black:0.16,0.16,0.17", "mint:Mint:0.66,0.86,0.76"),
})

add("stool_bar_chrome", {
    name = "Chrome Diner Stool", sub = "stool", style = "eclectic", material = "leather", price = 115, env = 2,
    rooms = { "kitchen", "venue" }, height = 0.8,
    desc = "Red vinyl, a chrome pedestal and a full-circle spin that delights anyone under ten or over three coffees. Seats one at a counter or bar.",
    rates = { comfort = 16 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("red:Cherry Vinyl:0.78,0.14,0.16", "turquoise:Turquoise Vinyl:0.20,0.66,0.68", "black:Black Vinyl:0.14,0.14,0.15"),
})

add("armchair_basic", { -- original 0.1.0 object
    name = "Fernwood Easy Chair", sub = "armchair", style = "traditional", material = "fabric", price = 280, env = 3,
    rooms = { "living", "study", "bedroom" }, height = 1.1,
    desc = "Deep enough to lose a remote in, shallow enough to find it again by Thursday. Solid comfort for reading, watching TV and waiting for the kettle.",
    rates = { comfort = 35 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("moss:Moss Tweed:0.44,0.52,0.36", "rust:Rust Corduroy:0.66,0.36,0.22", "oatmeal:Oatmeal:0.84,0.78,0.66"),
})

add("armchair_wingback", {
    name = "Wingback Reading Chair", sub = "armchair", style = "traditional", material = "fabric", price = 720, env = 5,
    rooms = { "living", "study" }, height = 1.35,
    desc = "High wings keep draughts off your ears and relatives out of your peripheral vision. Excellent comfort for long books and short tempers.",
    rates = { comfort = 46 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("tartan:Hunting Tartan:0.36,0.20,0.18", "chintz:Chintz:0.86,0.72,0.70", "leather:Tan Leather:0.62,0.40,0.24"),
})

add("armchair_pod", {
    name = "Egg Pod Lounge Chair", sub = "lounge", style = "contemporary", material = "plastic", price = 800, env = 6,
    rooms = { "living", "study" }, height = 1.4,
    desc = "A fibreglass shell lined with foam, shaped like a hatching idea. Very comfortable; getting out again requires a small plan and a witness.",
    rates = { comfort = 44 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("white:Gloss White:0.95,0.95,0.94", "orange:Tangerine:0.95,0.52,0.16", "graphite:Graphite:0.30,0.31,0.33"),
})

add("beanbag", {
    name = "Squish Beanbag", sub = "lounge", style = "eclectic", material = "leather", price = 90, env = 1,
    rooms = { "kids", "living", "bedroom" }, height = 0.6,
    desc = "Twelve thousand foam beads that remember your shape and gossip about it. Surprisingly comfortable, undeniably low, and impossible to leave with dignity.",
    rates = { comfort = 30 }, slots = { seat = K.seat("sit") }, actions = { "sit" }, tags = { "seat" },
    variants = var("purple:Grape:0.50,0.30,0.62", "lime:Lime:0.66,0.84,0.30", "denim:Denim:0.28,0.38,0.58", "leopard:Leopard Print:0.80,0.62,0.34"),
})

add("loveseat_basic", {
    name = "Two-Seat Settee", sub = "sofa", style = "starter", material = "fabric", price = 340, env = 2,
    rooms = { "living" }, fp = K.rect(2, 1), height = 1.0,
    desc = "Seats two people who like each other, or one person and a strategic pile of coats. Firm cushions, sensible fabric, compact footprint.",
    rates = { comfort = 28 }, slots = K.seatRow(2), actions = { "sit" }, tags = { "seat", "sofa" },
    variants = var("brown:Coffee Brown:0.44,0.32,0.24", "blue:Cornflower:0.46,0.56,0.80", "check:Picnic Check:0.80,0.30,0.28"),
})

add("sofa_budget", {
    name = "Springback Budget Sofa", sub = "sofa", style = "starter", material = "fabric", price = 300, env = 1,
    rooms = { "living" }, fp = K.rect(3, 1), height = 1.0,
    desc = "Three seats, one of which contains a spring with strong opinions about where you should sit. Cheap, cheerful, and comfier than the floor by a clear margin.",
    rates = { comfort = 24 }, slots = K.seatRow(3), actions = { "sit" }, tags = { "seat", "sofa" },
    variants = var("mustard:Mustard:0.84,0.66,0.24", "olive:Olive:0.46,0.48,0.26", "grey:Dove Grey:0.66,0.66,0.66"),
})

add("sofa_chesterfield", {
    name = "Buttoned Chesterfield Sofa", sub = "sofa", style = "traditional", material = "leather", price = 1200, env = 6,
    rooms = { "living", "study" }, fp = K.rect(3, 1), height = 1.0,
    desc = "Deep-buttoned leather with rolled arms that have heard every family secret since rolled arms were invented. Seats three in real comfort; naps are strongly implied.",
    rates = { comfort = 48 }, slots = K.seatRow(3), actions = { "sit" }, tags = { "seat", "sofa" },
    variants = var("oxblood:Oxblood Leather:0.40,0.10,0.10", "tan:Saddle Tan:0.66,0.42,0.22", "bottle:Bottle Green:0.12,0.30,0.20"),
})

add("sofa_sectional", {
    name = "Modular Cloud Sectional", sub = "sofa", style = "contemporary", material = "fabric", price = 1500, env = 7,
    rooms = { "living" }, fp = K.rect(3, 1), height = 0.9,
    desc = "Three deep modules of feather-wrapped foam that swallow a sitter whole and return them rested. The most comfortable sofa in the showroom.",
    rates = { comfort = 54 }, slots = K.seatRow(3), actions = { "sit" }, tags = { "seat", "sofa" },
    variants = var("chalk:Chalk Boucle:0.92,0.90,0.86", "slate:Slate Wool:0.36,0.40,0.44", "clay:Terracotta Linen:0.76,0.44,0.32"),
})

add("recliner_basic", {
    name = "Lean-Back Recliner", sub = "recliner", style = "traditional", material = "fabric", price = 450, env = 2,
    rooms = { "living" }, height = 1.15,
    desc = "Pull the lever and the footrest leaps up like it has waited all day for this. Great comfort; the lever jams now and then, and a handy resident can fix it.",
    rates = { comfort = 50 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    quality = { breakChance = 0.001, repairDifficulty = 2 },
    variants = var("brown:Chocolate Vinyl:0.34,0.22,0.16", "plaid:Lodge Plaid:0.56,0.24,0.20", "blue:Navy Microfibre:0.18,0.22,0.38"),
})

add("recliner_power", {
    name = "PowerLift Deluxe Recliner", sub = "recliner", style = "contemporary", material = "leather", price = 780, env = 4,
    rooms = { "living" }, height = 1.2, powered = true,
    desc = "A motorised recline with a hum so soothing it has put three reviewers to sleep mid-sentence. Top-tier comfort; it needs power, and a repair if the motor sulks.",
    rates = { comfort = 58 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    quality = { breakChance = 0.0006, repairDifficulty = 4 },
    variants = var("black:Black:0.14,0.14,0.15", "stone:Stone:0.72,0.68,0.60", "burgundy:Burgundy:0.46,0.14,0.18"),
})

add("chair_patio_plastic", {
    name = "Stackable Patio Chair", sub = "outdoor", style = "garden", material = "plastic", price = 60, env = 0,
    rooms = { "outdoor", "venue" }, height = 0.9,
    desc = "Moulded in one piece from weatherproof plastic and optimism. Stacks ten high, shrugs off rain, and leaves a faint grid on the backs of your legs.",
    rates = { comfort = 14 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("white:White:0.95,0.95,0.94", "green:Garden Green:0.30,0.52,0.30", "terracotta:Terracotta:0.76,0.42,0.28"),
})

add("chair_adirondack", {
    name = "Cedar Slatback Lawn Chair", sub = "outdoor", style = "garden", material = "wood", price = 240, env = 3,
    rooms = { "outdoor" }, height = 1.0,
    desc = "Wide arms for a drink, a sloped seat for watching clouds, and a recline so deep that standing up is a two-part project. Weathers to a handsome silver.",
    rates = { comfort = 28 }, slots = { seat = K.seat() }, actions = { "sit" }, tags = { "seat" },
    variants = var("cedar:Natural Cedar:0.72,0.46,0.30", "white:Beach White:0.93,0.92,0.88", "red:Barn Red:0.62,0.18,0.14", "yellow:Buttercup:0.96,0.84,0.36"),
})

add("bench_park", {
    name = "Cast-Iron Park Bench", sub = "bench", style = "garden", material = "wood", price = 350, env = 2,
    rooms = { "outdoor", "venue" }, fp = K.rect(2, 1), height = 0.95,
    desc = "Two seats of green slats on scrolled iron legs, as found outside every library that ever mattered. Built for public parks and private sulks alike.",
    rates = { comfort = 16 }, slots = K.seatRow(2), actions = { "sit" }, tags = { "seat" },
    variants = var("green:Park Green:0.20,0.40,0.26", "black:Black Iron:0.14,0.14,0.14", "teak:Teak Slats:0.60,0.40,0.24"),
})

add("chaise_lounge", {
    name = "Poolside Chaise Lounger", sub = "lounge", style = "garden", material = "fabric", price = 420, env = 3,
    rooms = { "outdoor" }, fp = { { 0, 0 }, { 0, 1 } }, height = 0.8,
    desc = "An adjustable back, quick-dry webbing and a length that implies you are staying a while. Comfortable enough to forget the sunscreen; the lawn will remember.",
    rates = { comfort = 40 },
    slots = { seat = { cell = { 0, 0 }, approaches = { { 1, 0 }, { -1, 0 }, { 1, 1 }, { -1, 1 } }, face = 0, on = true, group = "seat", pose = "lie" } },
    actions = { "sit" }, tags = { "seat" },
    variants = var("stripe:Blue Stripe:0.30,0.50,0.78", "white:White Webbing:0.94,0.94,0.92", "teak:Teak:0.62,0.42,0.26"),
})
