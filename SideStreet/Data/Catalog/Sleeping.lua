-- Buy-mode catalogue: Sleeping (brief §8.1: at least 8 designs).
-- Owner: catalogue module. "sleep" and "nap" (household-core) are listed directly and read
-- rates.energy / rates.comfort (per sim hour) from the bed in use. Double beds have two bed sides
-- (slot group "bed"), so two sleepers never share one side. Tag bed / bed_child lets
-- household-core attach bed making, waking and child routines.
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("sleeping")
local var = K.var
local SINGLE = { { 0, 0 }, { 0, 1 } }
local DOUBLE = K.rect(2, 2)

add("bed_single", { -- original 0.1.0 object
    name = "Slumberbarn Single Bed", sub = "single", style = "starter", material = "fabric", price = 300, env = 1,
    rooms = { "bedroom" }, fp = SINGLE, height = 0.9,
    desc = "Sleeps one adult, or one adult and a large amount of guilt. Budget springs and an honest pillow give fair rest; the springs voice their concerns overnight.",
    rates = { energy = 13, comfort = 8 }, slots = K.bedSingle(), actions = { "sleep", "nap" }, tags = { "bed" },
    variants = var("pine:Pine:0.80,0.62,0.40", "white:White Metal:0.92,0.92,0.90", "blue:Blue Quilt:0.40,0.52,0.74"),
})

add("bed_single_standard", {
    name = "Maplewood Captain's Bed", sub = "single", style = "traditional", material = "fabric", price = 650, env = 3,
    rooms = { "bedroom" }, fp = SINGLE, height = 0.95,
    desc = "Solid maple with two drawers underneath for sweaters, secrets and escaped socks. A proper mattress gives noticeably better rest than the budget beds.",
    rates = { energy = 15, comfort = 10 }, slots = K.bedSingle(), actions = { "sleep", "nap" }, tags = { "bed" },
    variants = var("maple:Honey Maple:0.84,0.64,0.40", "cherry:Cherry:0.58,0.30,0.20", "green:Hunter Green Quilt:0.22,0.40,0.28"),
})

add("bed_single_luxury", {
    name = "Daybreak Memory-Foam Single", sub = "single", style = "contemporary", material = "fabric", price = 1300, env = 4,
    rooms = { "bedroom" }, fp = SINGLE, height = 1.1,
    desc = "Seven layers of foam that learn your shape by the second night and forgive your posture by the third. The fastest rest a single sleeper can buy.",
    rates = { energy = 18, comfort = 13 }, slots = K.bedSingle(), actions = { "sleep", "nap" }, tags = { "bed" },
    variants = var("white:Cloud White:0.95,0.95,0.96", "grey:Storm Grey:0.46,0.48,0.52", "sand:Sand:0.86,0.78,0.64"),
})

add("bed_double_budget", {
    name = "Twin-Spring Double Bed", sub = "double", style = "starter", material = "fabric", price = 450, env = 1,
    rooms = { "bedroom" }, fp = DOUBLE, height = 1.15,
    desc = "Room for two, springs for about one and a half. The mattress dips toward the middle, which some couples call romance and others call a border dispute.",
    rates = { energy = 12, comfort = 7 }, slots = K.bedDouble(), actions = { "sleep", "nap" }, tags = { "bed" },
    quality = { capacity = 2 },
    variants = var("brass:Brass Frame:0.80,0.66,0.34", "pine:Pine:0.80,0.62,0.40", "floral:Floral Quilt:0.84,0.56,0.62"),
})

add("bed_double_standard", {
    name = "Heritage Oak Double", sub = "double", style = "traditional", material = "fabric", price = 1100, env = 4,
    rooms = { "bedroom" }, fp = DOUBLE, height = 1.25,
    desc = "A panelled oak headboard and a firm pocket-spring mattress with a proper side for each sleeper. Restful, respectable, and the sort of bed that gets made most mornings.",
    rates = { energy = 15, comfort = 11 }, slots = K.bedDouble(), actions = { "sleep", "nap" }, tags = { "bed" },
    quality = { capacity = 2 },
    variants = var("oak:Golden Oak:0.72,0.52,0.30", "walnut:Walnut:0.42,0.28,0.18", "paint:Duck-Egg Paint:0.70,0.82,0.80"),
})

add("bed_double_platform", {
    name = "Low Platform Double", sub = "double", style = "contemporary", material = "fabric", price = 1800, env = 6,
    rooms = { "bedroom" }, fp = DOUBLE, height = 0.8,
    desc = "A walnut platform so low and wide it looks like a very polite stage. A latex mattress and two generous sides give deep, quiet rest.",
    rates = { energy = 17, comfort = 13 }, slots = K.bedDouble(), actions = { "sleep", "nap" }, tags = { "bed" },
    quality = { capacity = 2 },
    variants = var("walnut:Walnut:0.42,0.28,0.18", "ash:Pale Ash:0.88,0.80,0.66", "black:Black Oak:0.16,0.15,0.14"),
})

add("bed_double_luxury", {
    name = "Canopy of Serenity Four-Poster", sub = "double", style = "traditional", material = "fabric", price = 3000, env = 10,
    rooms = { "bedroom" }, fp = DOUBLE, height = 2.1,
    desc = "Four carved posts, a gauze canopy and a mattress stuffed with the finest regret-free wool. The best rest in the catalogue; waking up on time remains your own problem.",
    rates = { energy = 20, comfort = 16 }, slots = K.bedDouble(), actions = { "sleep", "nap" }, tags = { "bed" },
    quality = { capacity = 2 },
    variants = var("mahogany:Mahogany & Ivory:0.40,0.16,0.12", "gilt:Gilt & Rose:0.86,0.70,0.40", "ebony:Ebony & Silver:0.14,0.12,0.12"),
})

add("bed_child", {
    name = "Rocket Ship Kid's Bed", sub = "child", style = "eclectic", material = "fabric", price = 400, env = 4,
    rooms = { "kids", "bedroom" }, fp = SINGLE, height = 1.3, kidOnly = true,
    desc = "A child's single bed dressed as a rocket, with fins, portholes and a countdown painted on the headboard. Children rest well in it; launch is not included.",
    rates = { energy = 15, comfort = 11 }, slots = K.bedSingle(), actions = { "sleep", "nap" }, tags = { "bed_child" },
    variants = var("red:Rocket Red:0.84,0.20,0.16", "silver:Moon Silver:0.78,0.80,0.84", "blue:Deep Space Blue:0.14,0.18,0.42"),
})

add("bed_child_toddler", {
    name = "Little Dreamer Toddler Bed", sub = "child", style = "starter", material = "fabric", price = 300, env = 2,
    rooms = { "kids" }, fp = SINGLE, height = 0.6, kidOnly = true,
    desc = "Low to the ground with rails on both sides, so the only thing that falls out at night is the stuffed rabbit. Sized and priced for small people.",
    rates = { energy = 13, comfort = 9 }, slots = K.bedSingle(), actions = { "sleep", "nap" }, tags = { "bed_child" },
    variants = var("white:White:0.95,0.95,0.94", "pink:Blossom:0.94,0.72,0.78", "yellow:Duckling:0.98,0.88,0.40"),
})

add("futon", {
    name = "Low-Slung Futon Mattress", sub = "compact", style = "eclectic", material = "fabric", price = 320, env = 1,
    rooms = { "bedroom", "study", "living" }, fp = SINGLE, height = 0.4,
    desc = "A slim cotton mattress on a low slatted frame, sized for box rooms and studies. Basic rest at a basic price, ideal for the guest you'd like to see leave on time.",
    rates = { energy = 9, comfort = 5 }, slots = K.bedSingle(), actions = { "sleep", "nap" }, tags = { "bed" },
    variants = var("indigo:Indigo:0.22,0.24,0.46", "saffron:Saffron:0.90,0.62,0.18", "natural:Natural Cotton:0.90,0.86,0.76"),
})

add("bed_murphy", {
    name = "Hide-Away Wall Bed", sub = "compact", style = "contemporary", material = "wood", price = 900, env = 3,
    rooms = { "bedroom", "study", "living" }, fp = SINGLE, height = 2.0, wallBack = true,
    desc = "A cabinet bed that stands against a wall and folds down at night with a thud the neighbours set their clocks by. Decent rest; its floor space stays reserved, so plan around it.",
    rates = { energy = 12, comfort = 9 }, slots = K.bedSingle(), actions = { "sleep", "nap" }, tags = { "bed" },
    quality = { breakChance = 0.001, repairDifficulty = 3 },
    variants = var("white:Gloss White:0.94,0.94,0.93", "oak:Light Oak:0.80,0.64,0.44", "grey:Concrete Grey:0.56,0.56,0.56"),
})
