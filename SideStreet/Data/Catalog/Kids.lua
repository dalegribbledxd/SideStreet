-- Buy-mode catalogue: Childcare & Pets (brief §8.1: at least 10 designs).
-- Owner: catalogue module. Care behaviour attaches by tag from the family module:
--   crib (infant sleep and settling), highchair (feeding), toybox / kid_play (children's play; the
--   executor reads rates.fun), pet_bed (pet sleep), pet_bowl (feeding; three meals per fill, a
--   family constant), litter (emptying), pet_toy (pet play), aquarium (feed and clean tanks; fish
--   watching reads rates.fun). Cribs, pet beds and scratching posts carry no rates: the family module
--   runs infant and pet sleep and play on its own numbers. quality.dirtRate on litter boxes, tanks and
--   the highchair is requested (docs/requests/catalogue.md FA-2), not read yet.
-- Slot names follow the family module (Sim/Family.lua F.SLOT_DEFAULTS): "front" is where a carer or
-- player stands (cribs, highchairs, toys, bowls, tanks), "petbed" is the pet's spot on a pet bed and
-- "tray" the cat's spot in a litter box; cribs keep "crib" and highchairs "baby" for the infant.
-- kidOnly items are refused to adults by the executor's eligibility check (request filed);
-- pet items carry pet = true so autonomy offers them to pets only.
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("kids")
local var = K.var
local LOW = { "table", "desk", "end", "shelf", "counter" }
-- The cat steps into the litter tray (family's "tray" slot); people clean it from "front".
local function TRAY() return { cell = { 0, 0 }, approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 } }, face = 0, on = true, group = "tray", pose = "sit" } end

---------------------------------------------------------------------------------------------------
-- Baby care
---------------------------------------------------------------------------------------------------
add("crib_bassinet", {
    name = "Wicker Bassinet", sub = "baby", style = "starter", material = "fabric", price = 180, env = 2,
    rooms = { "bedroom", "kids" }, height = 0.8,
    desc = "A woven basket on rocking legs, small enough to sit beside the parents' bed for the three-in-the-morning shift. Infants sleep here; adults settle them from the side.",
    slots = { crib = { cell = { 0, 0 }, approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 } }, face = 0, on = true, group = "crib", pose = "sleep" },
        front = K.around("carry") },
    tags = { "crib" },
    variants = var("natural:Natural Wicker:0.86,0.74,0.52", "white:White Wicker:0.96,0.94,0.90", "grey:Dove Grey:0.70,0.70,0.72"),
})

add("crib_convertible", {
    name = "Sleigh Crib with Mobile", sub = "baby", style = "traditional", material = "wood", price = 650, env = 6,
    rooms = { "kids", "bedroom" }, fp = K.rect(1, 2), height = 1.1,
    desc = "A solid cherry crib with a musical mobile of felt moons. Infants sleep here, and it lifts the nursery's room score far above a basket.",
    slots = { crib = { cell = { 0, 0 }, approaches = { { 1, 0 }, { -1, 0 }, { 1, 1 }, { -1, 1 } }, face = 0, on = true, group = "crib", pose = "sleep" },
        front = { approaches = { { 1, 0 }, { -1, 0 }, { 0, 2 } }, face = 2, pose = "carry" } },
    tags = { "crib" },
    variants = var("cherry:Cherry:0.58,0.30,0.20", "white:White:0.96,0.96,0.95", "sage:Sage:0.60,0.68,0.56"),
})

add("highchair", {
    name = "Wipe-Clean Highchair", sub = "baby", style = "starter", material = "wood", price = 90, env = 0,
    rooms = { "kitchen", "dining" }, height = 1.0,
    desc = "A tall seat with a tray engineered to survive porridge, peas and the scientific study of gravity. Feed an infant here without wearing the meal.",
    slots = { baby = { cell = { 0, 0 }, approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 } }, face = 0, on = true, group = "baby", pose = "sit" },
        front = { approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 } }, face = 2, pose = "use" } },
    tags = { "highchair" }, quality = { dirtRate = 1.5 },
    variants = var("white:White:0.96,0.96,0.95", "beech:Beech:0.86,0.72,0.52", "red:Red:0.80,0.20,0.18"),
})

---------------------------------------------------------------------------------------------------
-- Toys and play
---------------------------------------------------------------------------------------------------
add("toybox", {
    name = "Painted Toy Chest", sub = "toys", style = "starter", material = "wood", price = 80, env = 2,
    rooms = { "kids" }, height = 0.55, kidOnly = true,
    desc = "A lidded chest of blocks, puppets and one plastic dinosaur with a strong personality. Children play here; tidying up is a separate and much rarer event.",
    rates = { fun = 20 }, slots = { front = K.front(1, "play") }, tags = { "toybox" },
    surfaces = K.surf("end", 0.55, 1, 1, 1),
    variants = var("primary:Primary Colours:0.86,0.30,0.22", "pastel:Pastel:0.74,0.84,0.90", "natural:Natural Pine:0.82,0.64,0.40"),
})

add("play_activity_table", {
    name = "Bead Maze Activity Table", sub = "toys", style = "contemporary", material = "plastic", price = 120, env = 1,
    rooms = { "kids" }, height = 0.6, kidOnly = true,
    desc = "A low table of looping wires, sliding beads and spinning cogs that keeps small hands busy while grown-ups finish a sentence. Cheap, cheerful fun for a child.",
    rates = { fun = 22 },
    slots = { front = { approaches = { { 0, 1 } }, face = 2, pose = "play", group = "player" },
        player2 = { approaches = { { 0, -1 } }, face = 0, pose = "play", group = "player" } },
    tags = { "kid_play" },
    variants = var("bright:Bright:0.94,0.56,0.24", "ocean:Ocean:0.30,0.56,0.76", "forest:Forest:0.40,0.62,0.36"),
})

add("play_rocking_horse", {
    name = "Dapple-Grey Rocking Horse", sub = "toys", style = "traditional", material = "wood", price = 260, env = 5,
    rooms = { "kids" }, fp = K.rect(1, 2), height = 1.0, kidOnly = true,
    desc = "A carved horse on bow rockers with a real horsehair mane and a glass eye that follows you. Hours of galloping fun without any stable bills.",
    rates = { fun = 28 },
    slots = { front = { cell = { 0, 0 }, approaches = { { 1, 0 }, { -1, 0 } }, face = 0, on = true, group = "player", pose = "play" } },
    tags = { "kid_play" },
    variants = var("dapple:Dapple Grey:0.78,0.78,0.80", "chestnut:Chestnut:0.62,0.34,0.20", "painted:Painted Carousel:0.94,0.84,0.60"),
})

add("play_dollhouse", {
    name = "Three-Storey Dollhouse", sub = "toys", style = "traditional", material = "wood", price = 300, env = 6,
    rooms = { "kids", "bedroom" }, fp = K.rect(2, 1), height = 1.0, kidOnly = true,
    desc = "A hinged house with tiny wallpaper, a tiny grandfather clock and a tiny family that has clearly seen things. More fun than the activity table and a lift to the room.",
    rates = { fun = 30 },
    slots = { front = { approaches = { { 0, 1 } }, face = 2, pose = "play", group = "player" },
        player2 = { approaches = { { 1, 1 } }, face = 2, pose = "play", group = "player" } },
    tags = { "kid_play" },
    variants = var("victorian:Victorian Blue:0.52,0.64,0.80", "cottage:Rose Cottage:0.92,0.72,0.74", "modern:Modernist White:0.94,0.94,0.92"),
})

add("play_fort", {
    name = "Backyard Fort with Slide", sub = "toys", style = "garden", material = "wood", price = 1400, env = 8,
    rooms = { "outdoor", "venue" }, fp = K.rect(3, 2), height = 2.4, outdoor = true, groundOnly = true, kidOnly = true,
    desc = "A timber fort with a lookout deck, a wavy slide, a climbing wall and a flag for declaring independence. The most fun play set sold, and a centrepiece for the garden.",
    rates = { fun = 40 },
    slots = { front = { approaches = { { 0, 2 } }, face = 2, pose = "play", group = "player" },
        player2 = { approaches = { { 1, 2 } }, face = 2, pose = "play", group = "player" },
        player3 = { approaches = { { 2, 2 } }, face = 2, pose = "play", group = "player" },
        player4 = { approaches = { { 3, 0 }, { 3, 1 } }, face = 3, pose = "play", group = "player" } },
    tags = { "kid_play" }, quality = { breakChance = 0.0008, repairDifficulty = 3 },
    variants = var("natural:Natural Cedar:0.72,0.46,0.30", "red:Red Roof:0.80,0.20,0.18", "green:Green Roof:0.30,0.52,0.34"),
})

---------------------------------------------------------------------------------------------------
-- Pet care
---------------------------------------------------------------------------------------------------
add("pet_bed_basic", {
    name = "Fleece Pet Cushion", sub = "pets", style = "starter", material = "fabric", price = 40, env = 0,
    rooms = { "living", "bedroom", "kitchen" }, height = 0.2, pet = true,
    desc = "A round fleece cushion that pets will use, eventually, after first trying every human bed in the house. Somewhere cosy for a dog or cat to sleep.",
    slots = { petbed = { cell = { 0, 0 }, approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }, face = 0, on = true, group = "petbed", pose = "sleep" } },
    tags = { "pet_bed" },
    variants = var("grey:Grey:0.66,0.66,0.68", "tartan:Tartan:0.66,0.20,0.20", "blue:Blue:0.40,0.52,0.74"),
})

add("pet_bed_deluxe", {
    name = "Four-Poster Pet Bed", sub = "pets", style = "eclectic", material = "fabric", price = 220, env = 4,
    rooms = { "living", "bedroom" }, height = 0.7, pet = true,
    desc = "A miniature canopy bed with velvet curtains, for the animal who already runs the household. Pets sleep in it like any bed; the room score is the difference.",
    slots = { petbed = { cell = { 0, 0 }, approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 } }, face = 0, on = true, group = "petbed", pose = "sleep" } },
    tags = { "pet_bed" },
    variants = var("velvet:Plum Velvet:0.46,0.20,0.40", "gold:Gold Brocade:0.86,0.70,0.36", "teal:Teal Velvet:0.16,0.46,0.48"),
})

add("pet_bowl", {
    name = "Twin Steel Pet Bowls", sub = "pets", style = "starter", material = "metal", price = 20, env = 0,
    rooms = { "kitchen" }, height = 0.1, pet = true,
    desc = "One bowl for food, one for water, both pushed noisily round the floor at breakfast. Fill it and it holds three meals.",
    slots = { front = K.front(1, "eat") }, tags = { "pet_bowl" },
    variants = var("steel:Steel:0.80,0.82,0.84", "red:Red Enamel:0.80,0.20,0.18", "blue:Blue Enamel:0.26,0.40,0.78"),
})

add("pet_bowl_auto", {
    name = "Raised Feeding Station", sub = "pets", style = "contemporary", material = "wood", price = 60, env = 2,
    rooms = { "kitchen" }, height = 0.3, pet = true,
    desc = "Glazed bowls set into a raised oak stand, so the kibble stays off the floor and the kitchen stays presentable. Holds three meals per fill, like any bowl.",
    slots = { front = K.front(1, "eat") }, tags = { "pet_bowl" },
    variants = var("oak:Oak:0.72,0.52,0.32", "walnut:Walnut:0.42,0.28,0.18", "white:Painted White:0.94,0.94,0.92"),
})

add("litter_tray", {
    name = "Open Litter Tray", sub = "pets", style = "starter", material = "plastic", price = 45, env = 0,
    rooms = { "bathroom", "kitchen" }, height = 0.15, pet = true,
    desc = "A plastic tray, a bag of grit and a very direct feedback system for anyone who forgets to empty it. Cats use it; it gets dirty at the normal rate.",
    slots = { front = K.front(1, "clean"), tray = TRAY() }, tags = { "litter" },
    quality = { dirtRate = 1.0 },
    variants = var("grey:Grey:0.62,0.62,0.62", "blue:Blue:0.40,0.52,0.74", "pink:Pink:0.92,0.66,0.72"),
})

add("litter_hooded", {
    name = "Hooded Litter Box", sub = "pets", style = "contemporary", material = "plastic", price = 80, env = 2,
    rooms = { "bathroom", "kitchen" }, height = 0.45, pet = true,
    desc = "A domed box with a swing door and a charcoal filter, so the business stays out of sight and the room looks better for it. Cats use it like any tray.",
    slots = { front = K.front(1, "clean"), tray = TRAY() }, tags = { "litter" },
    quality = { dirtRate = 0.5 },
    variants = var("white:White:0.96,0.96,0.95", "grey:Graphite:0.30,0.31,0.33", "sand:Sand:0.86,0.78,0.62"),
})

add("scratch_post", {
    name = "Sisal Scratching Tower", sub = "pets", style = "eclectic", material = "fabric", price = 110, env = 1,
    rooms = { "living", "bedroom" }, height = 1.4, pet = true,
    desc = "Three sisal posts, two carpeted perches and a dangling mouse, offered in the hope that the sofa will be spared. Pets play here instead of on the furniture.",
    slots = { front = K.around("play") }, tags = { "pet_toy" },
    variants = var("beige:Beige:0.86,0.78,0.62", "grey:Grey:0.66,0.66,0.68", "pink:Pink:0.92,0.66,0.72"),
})

---------------------------------------------------------------------------------------------------
-- Tanks and habitats
---------------------------------------------------------------------------------------------------
add("fishbowl", {
    name = "Goldfish Bowl", sub = "tank", style = "starter", material = "glass", price = 60, env = 3,
    rooms = { "living", "bedroom", "kids", "study" }, mount = "surface", fits = LOW, height = 0.3,
    desc = "One round bowl, one goldfish, one small castle the goldfish never visits. Feed it daily and change the water; watching it is mildly soothing.",
    rates = { fun = 8 }, slots = { front = K.around("use") }, tags = { "aquarium" },
    quality = { capacity = 1, dirtRate = 1.5 },
    variants = var("gold:Goldfish:0.96,0.60,0.20", "betta:Blue Betta:0.26,0.40,0.78", "pair:Two Goldfish:0.96,0.52,0.24"),
})

add("hamster_habitat", {
    name = "Hamster Habitat with Tubes", sub = "tank", style = "eclectic", material = "plastic", price = 120, env = 2,
    rooms = { "kids", "bedroom" }, mount = "surface", fits = LOW, height = 0.4,
    desc = "A plastic palace of tunnels, a wheel and a sleeping loft for one small, nocturnal, extremely busy tenant. Feed and clean it; children love watching.",
    rates = { fun = 14 }, slots = { front = K.around("use") }, tags = { "aquarium" },
    quality = { capacity = 1, dirtRate = 1.2 },
    variants = var("orange:Orange Tubes:0.96,0.56,0.20", "blue:Blue Tubes:0.30,0.52,0.86", "green:Green Tubes:0.44,0.76,0.34"),
})

add("aquarium", {
    name = "Coral Reef Aquarium", sub = "tank", style = "contemporary", material = "glass", price = 900, env = 12,
    rooms = { "living", "study", "venue" }, fp = K.rect(2, 1), height = 1.4, powered = true,
    desc = "A lit two-tile tank of tropical fish drifting past rock and anemone as though they have nowhere to be. Big room boost, calming to watch, needs feeding and cleaning.",
    rates = { fun = 18 }, slots = { front = K.frontWide(2, "idle") }, tags = { "aquarium" },
    quality = { capacity = 8, dirtRate = 0.8, breakChance = 0.001, repairDifficulty = 4 },
    startState = { on = true },
    variants = var("reef:Reef:0.20,0.56,0.76", "freshwater:Freshwater Plants:0.30,0.60,0.40", "night:Night Blue:0.16,0.20,0.46"),
})
