-- Buy-mode catalogue: Outdoor & Garden (brief §8.1: at least 14 designs).
-- Owner: catalogue module. Landscaping adds env to the outdoor "room" and to the lot's curb appeal.
-- Gardening behaviour attaches by tag from the family module: garden_plot and planter (one crop
-- each: plant, water, weed, harvest), tree, shrub and flowers (decorative: water, wilt), fountain,
-- birdbath. quality.capacity / quality.speed on garden plots are requested (docs/requests/catalogue.md
-- FA-3), not read yet. Garden seating lists "sit"; outdoor games carry game/exercise (household-core).
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("outdoor")
local var = K.var
-- "front" is the family module's slot name for tending (water, weed, harvest, admire); pose garden.
local TEND = function() return K.around("garden") end

---------------------------------------------------------------------------------------------------
-- Trees
---------------------------------------------------------------------------------------------------
add("tree_birch", {
    name = "Silver Birch Sapling", sub = "tree", style = "garden", material = "plant", price = 150, env = 6,
    rooms = { "outdoor" }, height = 3.2, outdoor = true, groundOnly = true,
    desc = "A slim white-barked tree that sheds catkins on any car parked beneath it. Light shade, instant curb appeal, no fruit.",
    slots = { front = TEND() }, tags = { "tree" },
    variants = var("spring:Spring Green:0.56,0.74,0.36", "autumn:Autumn Gold:0.90,0.70,0.26"),
})

add("tree_oak", {
    name = "Spreading Oak", sub = "tree", style = "traditional", material = "plant", price = 380, env = 11,
    rooms = { "outdoor", "venue" }, height = 4.5, outdoor = true, groundOnly = true,
    desc = "A broad, patient oak already older than the mortgage. Deep shade, acorns for the squirrels and a big boost to how the whole lot looks.",
    slots = { front = TEND() }, tags = { "tree" },
    variants = var("summer:Summer Green:0.30,0.52,0.24", "autumn:Autumn Russet:0.74,0.40,0.18", "copper:Copper Beech Look:0.46,0.22,0.20"),
})

add("tree_fruit", {
    name = "Heirloom Apple Tree", sub = "tree", style = "garden", material = "plant", price = 450, env = 9,
    rooms = { "outdoor" }, height = 3.4, outdoor = true, groundOnly = true,
    desc = "A knobbly apple tree that blossoms every spring and sulks in dry spells. Water it now and then; a big lift to the garden's room score.",
    slots = { front = TEND() }, tags = { "tree" },
    variants = var("red:Red Apples:0.80,0.16,0.14", "green:Green Apples:0.56,0.76,0.26", "pear:Pears:0.82,0.76,0.30"),
})

---------------------------------------------------------------------------------------------------
-- Shrubs
---------------------------------------------------------------------------------------------------
add("shrub_boxwood", {
    name = "Box Hedge Cube", sub = "shrub", style = "starter", material = "plant", price = 45, env = 3,
    rooms = { "outdoor", "venue" }, height = 0.9, outdoor = true,
    desc = "A dense evergreen clipped into an obedient cube. Line a path with a few and the whole yard looks as though it has its affairs in order.",
    slots = { front = TEND() }, tags = { "shrub" },
    variants = var("green:Deep Green:0.22,0.44,0.20", "gold:Golden Tips:0.62,0.64,0.24"),
})

add("shrub_hydrangea", {
    name = "Mophead Hydrangea", sub = "shrub", style = "garden", material = "plant", price = 110, env = 6,
    rooms = { "outdoor", "venue" }, height = 1.1, outdoor = true,
    desc = "A generous shrub of pom-pom blooms whose colour depends on the soil, the weather and possibly its mood. Wilts if forgotten, recovers with water.",
    slots = { front = TEND() }, tags = { "shrub" },
    variants = var("blue:Blue:0.46,0.58,0.88", "pink:Pink:0.92,0.58,0.72", "white:White:0.96,0.96,0.92"),
})

add("shrub_topiary", {
    name = "Spiral Topiary in Lead Urn", sub = "shrub", style = "traditional", material = "plant", price = 520, env = 12,
    rooms = { "outdoor", "venue" }, height = 1.9, outdoor = true,
    desc = "An evergreen trained into a tight corkscrew by a gardener with extraordinary patience and small scissors. A formal showpiece for either side of a front door.",
    slots = { front = TEND() }, tags = { "shrub" },
    variants = var("lead:Lead Grey Urn:0.46,0.48,0.50", "terracotta:Terracotta Urn:0.72,0.42,0.28", "white:White Stone Urn:0.90,0.88,0.84"),
})

---------------------------------------------------------------------------------------------------
-- Flower beds
---------------------------------------------------------------------------------------------------
add("flowerbed_marigold", {
    name = "Marigold Border", sub = "flowers", style = "starter", material = "plant", price = 35, env = 4,
    rooms = { "outdoor", "venue" }, height = 0.35, outdoor = true,
    desc = "A strip of cheerful orange marigolds that forgive most mistakes and brighten any border. The cheapest splash of colour a front yard can buy.",
    slots = { front = TEND() }, tags = { "flowers" },
    variants = var("orange:Orange:0.96,0.56,0.14", "yellow:Yellow:0.98,0.84,0.20", "mixed:Mixed:0.92,0.66,0.22"),
})

add("flowerbed_wildflower", {
    name = "Wildflower Meadow Patch", sub = "flowers", style = "garden", material = "plant", price = 60, env = 5,
    rooms = { "outdoor", "venue" }, height = 0.5, outdoor = true,
    desc = "Poppies, cornflowers and ox-eye daisies sown thick and left to argue among themselves. Feeds bees, needs little watering and looks better the less you fuss.",
    slots = { front = TEND() }, tags = { "flowers" },
    variants = var("meadow:Summer Meadow:0.86,0.30,0.24", "blue:Cornflower Blue:0.36,0.46,0.86", "white:Daisy White:0.96,0.94,0.86"),
})

add("flowerbed_roses", {
    name = "Rose Bed with Brick Edging", sub = "flowers", style = "traditional", material = "plant", price = 240, env = 10,
    rooms = { "outdoor", "venue" }, fp = K.rect(2, 1), height = 0.8, outdoor = true,
    desc = "Two tiles of scented shrub roses behind a neat brick edge. Rewarding if watered and deadheaded, sulky and brown if not.",
    slots = { front = { approaches = { { 0, 1 }, { 1, 1 }, { -1, 0 }, { 2, 0 } }, face = 2, pose = "garden" } }, tags = { "flowers" },
    variants = var("red:Crimson:0.72,0.10,0.16", "pink:Blush Pink:0.94,0.66,0.72", "yellow:Butter Yellow:0.98,0.88,0.44"),
})

---------------------------------------------------------------------------------------------------
-- Planters
---------------------------------------------------------------------------------------------------
add("planter_wood", {
    name = "Herb Crate Planter", sub = "planter", style = "starter", material = "wood", price = 80, env = 3,
    rooms = { "outdoor", "kitchen" }, height = 0.5,
    desc = "A slatted crate of basil, thyme and parsley that works on a patio or by a sunny kitchen door. Snip herbs while they last; needs regular water.",
    slots = { front = TEND() }, tags = { "planter" },
    variants = var("pine:Natural Pine:0.82,0.64,0.40", "blue:Painted Blue:0.36,0.52,0.70", "grey:Weathered Grey:0.62,0.60,0.56"),
})

add("planter_stone", {
    name = "Carved Stone Urn Planter", sub = "planter", style = "traditional", material = "stone", price = 260, env = 8,
    rooms = { "outdoor", "venue" }, height = 1.0, outdoor = true,
    desc = "A pedestal urn spilling ivy and trailing geraniums, heavy enough to survive a storm and two removal crews. Holds one planting and a lot of dignity.",
    slots = { front = TEND() }, tags = { "planter" },
    variants = var("sandstone:Sandstone:0.86,0.76,0.58", "granite:Granite:0.56,0.56,0.56", "moss:Mossy Limestone:0.66,0.70,0.56"),
})

add("planter_windowbox", {
    name = "Geranium Window Box", sub = "planter", style = "garden", material = "wood", price = 90, env = 5,
    rooms = { "outdoor" }, mount = "window", height = 1.0, outdoor = true,
    desc = "A trough of red geraniums that clips under the outside of a window, where the whole street can admire it. Needs a window and some water.",
    slots = { front = K.under("garden") }, tags = { "planter" },
    variants = var("red:Red Geraniums:0.84,0.14,0.16", "white:White Petunias:0.96,0.96,0.94", "purple:Purple Pansies:0.52,0.34,0.72"),
})

---------------------------------------------------------------------------------------------------
-- Water features
---------------------------------------------------------------------------------------------------
add("birdbath", {
    name = "Pedestal Birdbath", sub = "water", style = "garden", material = "stone", price = 140, env = 6,
    rooms = { "outdoor", "venue" }, height = 1.0, outdoor = true, groundOnly = true,
    desc = "A shallow stone bowl on a column where the local sparrows hold noisy committee meetings. Refill it now and then to keep the birds visiting.",
    slots = { front = TEND() }, tags = { "birdbath" },
    variants = var("stone:Stone:0.80,0.78,0.72", "verdigris:Verdigris:0.40,0.64,0.58", "terracotta:Terracotta:0.72,0.42,0.28"),
})

add("fountain_tiered", {
    name = "Three-Tier Courtyard Fountain", sub = "water", style = "traditional", material = "stone", price = 2000, env = 20,
    rooms = { "outdoor", "venue" }, fp = K.rect(2, 2), height = 2.0, outdoor = true, groundOnly = true, powered = true,
    desc = "Three stone bowls pouring into one another inside a round basin, as if water had been taught etiquette. The finest outdoor centrepiece sold; it needs electricity for the pump.",
    slots = { front = { approaches = { { 0, 2 }, { 1, 2 }, { -1, 0 }, { 2, 1 } }, face = 2, pose = "use" } }, tags = { "fountain" },
    quality = { breakChance = 0.002, repairDifficulty = 4 },
    variants = var("limestone:Limestone:0.88,0.84,0.74", "granite:Granite:0.56,0.56,0.56", "bronze:Bronze:0.62,0.44,0.26"),
})

---------------------------------------------------------------------------------------------------
-- Garden seating
---------------------------------------------------------------------------------------------------
add("swing_porch", {
    name = "Canopy Porch Swing", sub = "seating", style = "traditional", material = "wood", price = 380, env = 5,
    rooms = { "outdoor" }, fp = K.rect(2, 1), height = 2.0, outdoor = true,
    desc = "A two-seat swing hung from a striped-canopy frame, for long evenings of gentle creaking and pointed conversation about the neighbours. Seats two outdoors and adds more charm than a bench.",
    rates = { comfort = 30 }, slots = K.seatRow(2), actions = { "sit" }, tags = { "seat" },
    variants = var("stripe:Green Stripe:0.40,0.62,0.44", "red:Red Stripe:0.78,0.24,0.22", "navy:Navy Stripe:0.20,0.26,0.46"),
})

add("hammock", {
    name = "Rope Hammock on Stand", sub = "seating", style = "garden", material = "fabric", price = 260, env = 4,
    rooms = { "outdoor" }, fp = K.rect(2, 1), height = 1.2, outdoor = true,
    desc = "A cotton rope hammock slung on a curved wooden stand, designed for lying back and discovering whether one can get out again with dignity. Very relaxing.",
    rates = { comfort = 40 },
    slots = { seat = { cell = { 0, 0 }, approaches = { { 0, 1 }, { 1, 1 }, { -1, 0 } }, face = 0, on = true, group = "seat", pose = "lie" } },
    actions = { "sit" }, tags = { "seat" },
    variants = var("natural:Natural Cotton:0.92,0.88,0.78", "rainbow:Rainbow:0.86,0.52,0.40", "navy:Navy:0.20,0.26,0.46"),
})

---------------------------------------------------------------------------------------------------
-- Outdoor games
---------------------------------------------------------------------------------------------------
add("game_ringtoss", {
    name = "Lawn Ring Toss", sub = "games", style = "eclectic", material = "wood", price = 90, env = 1,
    rooms = { "outdoor", "venue" }, height = 0.6, outdoor = true,
    desc = "A painted peg board and six rope rings for a game that starts friendly and ends in a recount. Two can play; cheap outdoor fun.",
    rates = { fun = 20 },
    slots = { player1 = { approaches = { { 0, 2 } }, face = 2, pose = "play", group = "player" },
        player2 = { approaches = { { 1, 2 } }, face = 2, pose = "play", group = "player" } },
    tags = { "game" },
    variants = var("red:Red & White:0.84,0.20,0.20", "blue:Blue & Yellow:0.26,0.40,0.78", "natural:Natural Wood:0.82,0.64,0.40"),
})

add("basketball_hoop", {
    name = "Driveway Basketball Hoop", sub = "games", style = "contemporary", material = "plastic", price = 350, env = 0,
    rooms = { "outdoor", "venue" }, height = 3.0, outdoor = true, groundOnly = true,
    desc = "A regulation-ish hoop on a weighted pole for shooting practice until the light goes or the ball lands in a flower bed. Fun and a real workout.",
    rates = { fun = 26 },
    slots = { player1 = { approaches = { { 0, 2 } }, face = 2, pose = "exercise", group = "player" },
        player2 = { approaches = { { 1, 2 }, { -1, 2 } }, face = 2, pose = "exercise", group = "player" } },
    tags = { "game", "exercise" }, quality = { skill = 1.0, breakChance = 0.001, repairDifficulty = 2 },
    variants = var("red:Red Backboard:0.80,0.18,0.16", "white:White Backboard:0.96,0.96,0.96", "black:Black Backboard:0.14,0.14,0.15"),
})

---------------------------------------------------------------------------------------------------
-- Plots and tools
---------------------------------------------------------------------------------------------------
add("garden_plot", {
    name = "Vegetable Patch", sub = "garden", style = "starter", material = "stone", price = 70, env = 2,
    rooms = { "outdoor" }, fp = K.rect(2, 2), height = 0.3, outdoor = true, groundOnly = true,
    desc = "Four tiles of dug earth and a hand-lettered row marker. Plant a crop, water and weed it, and harvest it for the kitchen.",
    slots = { front = { approaches = { { 0, 2 }, { 1, 2 }, { -1, 0 }, { -1, 1 }, { 2, 0 }, { 2, 1 }, { 0, -1 }, { 1, -1 } }, face = 2, pose = "garden" } },
    tags = { "garden_plot" }, quality = { capacity = 4, speed = 1.0 },
    variants = var("loam:Dark Loam:0.36,0.26,0.18", "clay:Clay Soil:0.56,0.36,0.24"),
})

add("garden_plot_raised", {
    name = "Cedar Raised Bed", sub = "garden", style = "garden", material = "wood", price = 380, env = 5,
    rooms = { "outdoor" }, fp = K.rect(2, 1), height = 0.6, outdoor = true, groundOnly = true,
    desc = "A waist-friendly cedar box of rich soil, so the only thing that aches is pride. Grows a crop like any plot and looks far tidier doing it.",
    slots = { front = { approaches = { { 0, 1 }, { 1, 1 }, { -1, 0 }, { 2, 0 }, { 0, -1 }, { 1, -1 } }, face = 2, pose = "garden" } },
    tags = { "garden_plot" }, quality = { capacity = 3, speed = 1.3 },
    variants = var("cedar:Cedar:0.72,0.46,0.30", "grey:Weathered:0.62,0.60,0.56", "green:Painted Sage:0.60,0.68,0.56"),
})

add("tool_rack", {
    name = "Potting Bench and Tool Rack", sub = "garden", style = "garden", material = "wood", price = 160, env = 3,
    rooms = { "outdoor" }, fp = K.rect(2, 1), height = 1.6, outdoor = true,
    desc = "A slatted bench with a pegboard of trowels, forks and one mysterious tool nobody can name. Decorative, with a work top for pots, radios and lanterns.",
    surfaces = K.surf("table", 0.9, 2, 1, 1),
    variants = var("pine:Pine:0.82,0.64,0.40", "green:Shed Green:0.30,0.46,0.34", "grey:Weathered:0.62,0.60,0.56"),
})

---------------------------------------------------------------------------------------------------
-- Path accents
---------------------------------------------------------------------------------------------------
add("gnome", {
    name = "Fishing Garden Gnome", sub = "accent", style = "eclectic", material = "ceramic", price = 30, env = 3,
    rooms = { "outdoor" }, height = 0.5, outdoor = true,
    desc = "A bearded fellow with a rod and an optimistic expression, fishing in a lawn with no pond. Small, cheap and oddly beloved.",
    variants = var("classic:Red Hat:0.80,0.16,0.14", "blue:Blue Hat:0.26,0.40,0.78", "gold:Gilded:0.90,0.74,0.34"),
})

add("stepping_stones", {
    name = "Flagstone Stepping Stones", sub = "accent", style = "garden", material = "stone", price = 20, env = 1,
    rooms = { "outdoor" }, height = 0.05, outdoor = true, rug = true,
    desc = "Three flat stones set into the grass to suggest a path without committing to one. Walkable; lay a row to lead guests round the side.",
    variants = var("slate:Slate:0.42,0.44,0.48", "sandstone:Sandstone:0.86,0.76,0.58", "brick:Brick Pavers:0.66,0.30,0.22"),
})

add("sundial", {
    name = "Bronze Garden Sundial", sub = "accent", style = "traditional", material = "stone", price = 180, env = 6,
    rooms = { "outdoor", "venue" }, height = 0.9, outdoor = true, groundOnly = true,
    desc = "A bronze dial on a stone column, accurate to within twenty minutes on a sunny day and entirely useless on any other. A classic focal point for a path.",
    variants = var("bronze:Bronze:0.62,0.44,0.26", "verdigris:Verdigris:0.40,0.64,0.58", "stone:All Stone:0.80,0.78,0.72"),
})
