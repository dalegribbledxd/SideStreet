-- Buy-mode catalogue: Tables & Surfaces (brief §8.1: at least 12 designs).
-- Owner: catalogue module. Surfaces are typed slots (table, desk, counter, shelf, end) that
-- surface-mounted objects snap onto at the surface height (Sim/Placement.lua). Chairs placed
-- facing a table or desk pair with it (SS.Placement.PairedTable). Tag table_dining and counter
-- let household-core attach eating and food preparation.
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("surfaces")
local var = K.var

add("table_small", { -- original 0.1.0 object
    name = "Two-Seat Breakfast Table", sub = "dining", style = "starter", material = "wood", price = 120, env = 1,
    rooms = { "kitchen", "dining" }, height = 0.75,
    desc = "Seats two for breakfast, or one for breakfast and one pile of laundry. A single square top with room for two plates or a lamp and a plate.",
    surfaces = K.surf("table", 0.75, 1, 1, 2), tags = { "table_dining" },
    variants = var("pine:Pine:0.80,0.62,0.40", "white:White Laminate:0.94,0.94,0.92", "red:Diner Red:0.76,0.18,0.16"),
})

add("table_bistro_tiled", {
    name = "Tiled Bistro Table", sub = "dining", style = "eclectic", material = "metal", price = 180, env = 2,
    rooms = { "kitchen", "dining", "outdoor" }, height = 0.75,
    desc = "A wrought-iron pedestal topped with hand-painted tiles that do not quite match, which is the point. Room for two plates, two cups and one very small argument.",
    surfaces = K.surf("table", 0.75, 1, 1, 2), tags = { "table_dining" },
    variants = var("blue:Blue & White Tiles:0.24,0.40,0.66", "sun:Sunflower Tiles:0.90,0.72,0.24", "green:Majolica Green:0.26,0.52,0.40"),
})

add("table_pedestal", {
    name = "Tulip Pedestal Table", sub = "dining", style = "contemporary", material = "metal", price = 260, env = 3,
    rooms = { "kitchen", "dining" }, height = 0.75,
    desc = "A round white top balanced on one flared stem, so nobody ever fights a table leg for knee room again. Seats two, holds two place settings.",
    surfaces = K.surf("table", 0.75, 1, 1, 2), tags = { "table_dining" },
    variants = var("white:White & Marble:0.95,0.95,0.94", "black:Black & Oak:0.16,0.16,0.16", "sage:Sage:0.66,0.76,0.62"),
})

add("table_dining_4", {
    name = "Farmhouse Four-Seater", sub = "dining", style = "traditional", material = "wood", price = 450, env = 3,
    rooms = { "dining", "kitchen" }, fp = K.rect(2, 1), height = 0.75,
    desc = "Thick planks, turned legs and a scrubbed top that has forgiven a thousand spilled gravies. Seats four; two cells of table with two place settings each.",
    surfaces = K.surf("table", 0.75, 2, 1, 2), tags = { "table_dining" },
    variants = var("oak:Scrubbed Oak:0.78,0.62,0.44", "pine:Waxed Pine:0.82,0.64,0.40", "painted:Sage Base:0.60,0.68,0.56"),
})

add("table_dining_glass", {
    name = "Floating Glass Dining Table", sub = "dining", style = "contemporary", material = "glass", price = 900, env = 5,
    rooms = { "dining" }, fp = K.rect(2, 1), height = 0.75,
    desc = "Tempered glass on a brushed steel frame, so you can admire your shoes while you eat. Seats four; fingerprints appear within the hour, free of charge.",
    surfaces = K.surf("table", 0.75, 2, 1, 2), tags = { "table_dining" },
    variants = var("clear:Clear & Steel:0.80,0.88,0.90", "smoke:Smoked & Black:0.36,0.38,0.40", "bronze:Bronze Tint:0.66,0.52,0.36"),
})

add("table_dining_6", {
    name = "Grand Banquet Table", sub = "dining", style = "traditional", material = "wood", price = 1400, env = 7,
    rooms = { "dining" }, fp = K.rect(3, 1), height = 0.78,
    desc = "Three cells of polished mahogany with carved claw feet, built for Sunday roasts and the long silences that follow. Seats six with room for serving dishes.",
    surfaces = K.surf("table", 0.78, 3, 1, 2), tags = { "table_dining" },
    variants = var("mahogany:Mahogany:0.42,0.16,0.10", "walnut:Walnut:0.42,0.28,0.18", "ebonised:Ebonised Oak:0.14,0.12,0.11"),
})

add("desk_basic", {
    name = "Particleboard Study Desk", sub = "desk", style = "starter", material = "wood", price = 110, env = 0,
    rooms = { "study", "bedroom", "kids" }, fp = K.rect(2, 1), height = 0.75,
    desc = "Flat-packed with forty-one screws and a diagram drawn by an optimist. Holds a computer, a lamp and whatever paperwork you are avoiding, two items per side.",
    surfaces = K.surf("desk", 0.75, 2, 1, 2),
    variants = var("beech:Beech Effect:0.86,0.72,0.52", "white:White:0.94,0.94,0.92", "black:Black Ash:0.20,0.19,0.18"),
})

add("desk_glass", {
    name = "Glass-Top Studio Desk", sub = "desk", style = "contemporary", material = "glass", price = 420, env = 3,
    rooms = { "study" }, fp = K.rect(2, 1), height = 0.75,
    desc = "A frosted glass top on chrome trestles, for working in the kind of light that makes deadlines look optional. Four surface slots for a computer, lamp and friends.",
    surfaces = K.surf("desk", 0.75, 2, 1, 2),
    variants = var("frost:Frosted & Chrome:0.86,0.90,0.92", "black:Black Glass:0.18,0.18,0.20", "green:Sea Glass:0.64,0.80,0.74"),
})

add("desk_executive", {
    name = "Partner's Walnut Desk", sub = "desk", style = "traditional", material = "wood", price = 850, env = 5,
    rooms = { "study" }, fp = K.rect(2, 1), height = 0.78,
    desc = "A leather-inlaid walnut desk with nine drawers, one of them locked for reasons nobody remembers. Makes a study look like decisions happen there.",
    surfaces = K.surf("desk", 0.78, 2, 1, 2),
    variants = var("walnut:Walnut & Green Leather:0.42,0.28,0.18", "mahogany:Mahogany & Red Leather:0.42,0.16,0.10", "oak:Oak & Tan Leather:0.70,0.52,0.32"),
})

add("table_coffee_basic", {
    name = "Pine Coffee Table", sub = "coffee", style = "starter", material = "wood", price = 90, env = 1,
    rooms = { "living" }, fp = K.rect(2, 1), height = 0.45,
    desc = "A low pine table for mugs, magazines and feet, officially in that order. Two cells of surface at knee height.",
    surfaces = K.surf("table", 0.45, 2, 1, 1),
    variants = var("pine:Pine:0.82,0.64,0.40", "dark:Dark Stain:0.40,0.28,0.18", "white:Limewash:0.90,0.88,0.82"),
})

add("table_coffee_luxe", {
    name = "Marble Slab Coffee Table", sub = "coffee", style = "contemporary", material = "stone", price = 700, env = 6,
    rooms = { "living" }, fp = K.rect(2, 1), height = 0.4,
    desc = "A single slab of veined marble on brass legs, heavy enough to have its own postcode. Coasters are not optional; they are a lifestyle.",
    surfaces = K.surf("table", 0.4, 2, 1, 2),
    variants = var("carrara:Carrara White:0.94,0.94,0.92", "nero:Nero Black:0.14,0.14,0.15", "verde:Verde Green:0.26,0.42,0.34"),
})

add("table_end", {
    name = "Spindle End Table", sub = "coffee", style = "traditional", material = "wood", price = 65, env = 1,
    rooms = { "living", "bedroom" }, height = 0.6,
    desc = "A small round top on turned spindles, exactly the right height for a lamp, a book and a glass of water that will be knocked over at 3 a.m. One small surface for a lamp or clutter.",
    surfaces = K.surf("end", 0.6, 1, 1, 1),
    variants = var("cherry:Cherry:0.58,0.30,0.20", "oak:Oak:0.70,0.52,0.32", "white:Painted White:0.94,0.93,0.90"),
})

add("table_end_mosaic", {
    name = "Mosaic Side Table", sub = "coffee", style = "eclectic", material = "ceramic", price = 140, env = 3,
    rooms = { "living", "bedroom" }, height = 0.55,
    desc = "Hand-set tiles in forty colours on a wrought-iron base, assembled by someone who clearly had strong feelings about turquoise. Holds one lamp or ornament.",
    surfaces = K.surf("end", 0.55, 1, 1, 1),
    variants = var("turquoise:Turquoise Mix:0.20,0.64,0.66", "sunset:Sunset Mix:0.92,0.52,0.30", "cobalt:Cobalt Mix:0.18,0.30,0.70"),
})

add("sideboard", {
    name = "Walnut Buffet Sideboard", sub = "display", style = "traditional", material = "wood", price = 600, env = 5,
    rooms = { "dining", "living" }, fp = K.rect(2, 1), height = 0.9,
    desc = "Four doors, two drawers and a long top for displaying the good china nobody is allowed to use. Four display slots at waist height.",
    surfaces = K.surf("shelf", 0.85, 2, 1, 2),
    variants = var("walnut:Walnut:0.42,0.28,0.18", "teak:Teak:0.60,0.40,0.24", "painted:Heritage Blue:0.34,0.44,0.56"),
})

add("counter_basic", { -- original 0.1.0 object (was listed under kitchen)
    name = "Plainfield Kitchen Counter", sub = "counter", style = "starter", material = "wood", price = 140, env = 0,
    rooms = { "kitchen" }, height = 1.05,
    desc = "A flat, honest surface for preparing food. Holds a cutting board, a microwave, or a surprising amount of mail; two appliance slots on top.",
    surfaces = K.surf("counter", 0.9, 1, 1, 2), slots = { front = K.front(1, "cook") }, tags = { "counter" },
    quality = { speed = 1.0 },
    variants = var("white:White Laminate:0.94,0.94,0.92", "wood:Wood Laminate:0.76,0.58,0.38", "avocado:Avocado:0.56,0.62,0.30"),
})

add("counter_tile", {
    name = "Tiled Prep Counter", sub = "counter", style = "traditional", material = "wood", price = 320, env = 2,
    rooms = { "kitchen" }, height = 1.05,
    desc = "Glazed tiles over solid cabinets, laid by someone who owned a spirit level and used it. Two appliance slots on top and a smarter look than bare laminate.",
    surfaces = K.surf("counter", 0.9, 1, 1, 2), slots = { front = K.front(1, "cook") }, tags = { "counter" },
    quality = { speed = 1.1 },
    variants = var("cream:Cream Tile:0.94,0.90,0.80", "blue:Delft Blue:0.36,0.48,0.72", "terracotta:Terracotta:0.78,0.44,0.28"),
})

add("counter_steel", {
    name = "Stainless Chef's Counter", sub = "counter", style = "contemporary", material = "metal", price = 750, env = 3,
    rooms = { "kitchen" }, height = 1.05,
    desc = "Commercial-grade steel with a rolled edge and a professional shine that reflects every mistake back at the cook. Two appliance slots and the look of a kitchen that means business.",
    surfaces = K.surf("counter", 0.92, 1, 1, 2), slots = { front = K.front(1, "cook") }, tags = { "counter" },
    quality = { speed = 1.3 },
    variants = var("steel:Brushed Steel:0.78,0.80,0.82", "black:Black Steel:0.20,0.21,0.22", "copper:Copper Trim:0.74,0.46,0.30"),
})

add("counter_island", {
    name = "Butcher-Block Island", sub = "counter", style = "traditional", material = "wood", price = 950, env = 5,
    rooms = { "kitchen" }, fp = K.rect(2, 1), height = 0.92,
    desc = "A freestanding island of end-grain maple that turns any kitchen into a place people linger. Four surface slots and the handsomest worktop in the catalogue.",
    surfaces = K.surf("counter", 0.92, 2, 1, 2),
    slots = { front = { approaches = { { 0, 1 }, { 1, 1 } }, face = 2, pose = "cook" }, back = { approaches = { { 0, -1 }, { 1, -1 } }, face = 0, pose = "cook" } },
    tags = { "counter" }, quality = { speed = 1.2 },
    variants = var("maple:Maple Block:0.86,0.70,0.48", "walnut:Walnut Block:0.46,0.30,0.18", "white:White Base:0.94,0.94,0.92"),
})

add("table_picnic", {
    name = "Weekend Picnic Table", sub = "outdoor", style = "garden", material = "wood", price = 300, env = 2,
    rooms = { "outdoor", "venue" }, fp = { { 0, -1 }, { 1, -1 }, { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }, height = 0.78,
    desc = "A slatted table with a bench bolted to each side, so nobody can wander off mid-sandwich. Seats four and holds four plates; splinters are strictly decorative.",
    surfaces = { { cell = { 0, 0 }, z = 0.75, kind = "table", slots = 2 }, { cell = { 1, 0 }, z = 0.75, kind = "table", slots = 2 } },
    slots = {
        seat1 = { cell = { 0, -1 }, approaches = { { -1, -1 }, { 0, -2 } }, face = 0, on = true, group = "seat", pose = "sit" },
        seat2 = { cell = { 1, -1 }, approaches = { { 2, -1 }, { 1, -2 } }, face = 0, on = true, group = "seat", pose = "sit" },
        seat3 = { cell = { 0, 1 }, approaches = { { -1, 1 }, { 0, 2 } }, face = 2, on = true, group = "seat", pose = "sit" },
        seat4 = { cell = { 1, 1 }, approaches = { { 2, 1 }, { 1, 2 } }, face = 2, on = true, group = "seat", pose = "sit" },
    },
    rates = { comfort = 14 }, actions = { "sit" }, tags = { "table_dining", "seat" },
    variants = var("cedar:Cedar:0.72,0.46,0.30", "green:Park Green:0.26,0.46,0.30", "grey:Weathered Grey:0.60,0.60,0.58"),
})

add("table_patio", {
    name = "Wrought-Iron Patio Table", sub = "outdoor", style = "garden", material = "metal", price = 220, env = 2,
    rooms = { "outdoor" }, height = 0.72,
    desc = "A scrolled iron table with a hole for a sunshade you will buy next summer. Seats two outdoors; the top holds two plates and a jug of something cold.",
    surfaces = K.surf("table", 0.72, 1, 1, 2), tags = { "table_dining" },
    variants = var("black:Black Iron:0.14,0.14,0.14", "white:White Iron:0.93,0.93,0.91", "verdigris:Verdigris:0.40,0.62,0.54"),
})
