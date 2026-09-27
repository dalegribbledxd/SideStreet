-- Buy-mode catalogue: Storage, Mirrors & Dressing (brief §8.1: at least 10 designs).
-- Owner: catalogue module. Tag dresser: household-core attaches outfit changes. Tag mirror: charisma
-- practice (quality.skill is requested, docs/requests/catalogue.md HC-3, not read yet). Shelves and
-- cabinets carry typed shelf slots for ornaments, plants, lamps and books (Sim/Placement.lua).
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("storage")
local var = K.var

add("dresser_basic", {
    name = "Three-Drawer Pine Dresser", sub = "dresser", style = "starter", material = "wood", price = 200, env = 1,
    rooms = { "bedroom", "kids" }, height = 0.95,
    desc = "Three drawers: one for socks, one for shirts, one that sticks and therefore holds everything else. Change outfits here; the top holds two small things.",
    slots = { front = K.front(1, "use") }, tags = { "dresser" }, surfaces = K.surf("end", 0.95, 1, 1, 2),
    variants = var("pine:Pine:0.82,0.64,0.40", "white:White:0.94,0.94,0.92", "blue:Nursery Blue:0.62,0.74,0.88"),
})

add("dresser_tall", {
    name = "Highboy Chest of Drawers", sub = "dresser", style = "traditional", material = "wood", price = 650, env = 4,
    rooms = { "bedroom" }, height = 1.5,
    desc = "Seven graduated drawers on cabriole legs, tall enough to hide a birthday present from anyone under five feet. Change outfits here, with two ornament spots on top.",
    slots = { front = K.front(1, "use") }, tags = { "dresser" }, surfaces = K.surf("shelf", 1.5, 1, 1, 2),
    variants = var("cherry:Cherry:0.58,0.30,0.20", "walnut:Walnut:0.42,0.28,0.18", "painted:Painted Sage:0.60,0.68,0.56"),
})

add("wardrobe", {
    name = "Double-Door Wardrobe", sub = "dresser", style = "traditional", material = "wood", price = 900, env = 5,
    rooms = { "bedroom" }, fp = K.rect(2, 1), height = 2.0,
    desc = "A carved oak wardrobe deep enough to lose a winter coat in, and possibly a small country. Change outfits here in considerable style.",
    slots = { front = K.frontWide(2, "use") }, tags = { "dresser" },
    variants = var("oak:Oak:0.72,0.52,0.30", "mahogany:Mahogany:0.42,0.16,0.10", "white:French White:0.94,0.92,0.88"),
})

add("wardrobe_modern", {
    name = "Sliding Mirror Wardrobe", sub = "dresser", style = "contemporary", material = "wood", price = 1300, env = 5,
    rooms = { "bedroom" }, fp = K.rect(2, 1), height = 2.1,
    desc = "Full-height mirrored doors that glide aside to reveal rails, shelves and your entire life choices. Change outfits here, and the doors double as a practice mirror.",
    slots = { front = K.frontWide(2, "use") }, tags = { "dresser", "mirror" },
    quality = { skill = 1.0 },
    variants = var("mirror:Mirror & White:0.90,0.92,0.94", "bronze:Bronze Mirror:0.66,0.54,0.40", "black:Mirror & Black:0.16,0.16,0.17"),
})

add("mirror_bathroom", {
    name = "Medicine Cabinet Mirror", sub = "mirror", style = "starter", material = "glass", price = 90, env = 1,
    rooms = { "bathroom" }, mount = "wall", height = 1.7,
    desc = "A mirrored cabinet for plasters, aspirin and the anti-wrinkle cream nobody admits to buying. Practise charisma while you floss.",
    slots = { front = K.under("use") }, tags = { "mirror" },
    quality = { skill = 0.9 },
    variants = var("white:White Frame:0.96,0.96,0.95", "chrome:Chrome Frame:0.84,0.86,0.88", "oak:Oak Frame:0.72,0.52,0.30"),
})

add("mirror_full", {
    name = "Full-Length Cheval Mirror", sub = "mirror", style = "traditional", material = "glass", price = 350, env = 3,
    rooms = { "bedroom" }, height = 1.8,
    desc = "A tilting oval mirror on a mahogany stand that shows the whole outfit, head to regrettable shoes. Practise charisma speeches and admire the result.",
    slots = { front = K.front(1, "talk") }, tags = { "mirror" },
    quality = { skill = 1.2 },
    variants = var("mahogany:Mahogany:0.42,0.16,0.10", "gilt:Gilt:0.86,0.70,0.40", "white:White:0.94,0.94,0.92"),
})

add("mirror_sunburst", {
    name = "Sunburst Wall Mirror", sub = "mirror", style = "eclectic", material = "metal", price = 280, env = 6,
    rooms = { "living", "dining", "bedroom" }, mount = "wall", height = 1.9,
    desc = "A round mirror in a blaze of gilded rays, as if the wall had a very good idea. Mostly decoration, but you can still practise a winning smile in it.",
    slots = { front = K.under("talk") }, tags = { "mirror" },
    quality = { skill = 1.0 },
    variants = var("gold:Gold:0.90,0.74,0.34", "silver:Silver:0.82,0.84,0.86", "bronze:Bronze:0.62,0.44,0.26"),
})

add("vanity_table", {
    name = "Hollywood Vanity with Stool", sub = "mirror", style = "eclectic", material = "wood", price = 480, env = 4,
    rooms = { "bedroom" }, fp = { { 0, 0 }, { 0, 1 } }, height = 1.6,
    desc = "A kidney-shaped dressing table ringed with bulb lights and a padded stool in front. Sit and practise charisma in the glow; two small things fit on top.",
    slots = { seat = { cell = { 0, 1 }, approaches = { { 1, 1 }, { -1, 1 }, { 0, 2 } }, face = 2, on = true, pose = "sit" } },
    tags = { "mirror" }, surfaces = { { cell = { 0, 0 }, z = 0.75, kind = "table", slots = 2 } },
    quality = { skill = 1.3 },
    variants = var("white:White & Pink:0.96,0.92,0.92", "black:Black & Gold:0.14,0.12,0.10", "mint:Mint & Chrome:0.66,0.86,0.76"),
})

add("shelf_wall", {
    name = "Floating Wall Shelf", sub = "shelf", style = "starter", material = "wood", price = 45, env = 0,
    rooms = { "living", "bedroom", "kitchen", "study", "bathroom" }, mount = "wall", height = 1.3,
    desc = "A plank with hidden brackets that appears to float, as long as nobody looks underneath. Two display slots at eye level for plants, ornaments or a radio.",
    surfaces = K.surf("shelf", 1.3, 1, 1, 2, { 0, -0.36 }),
    variants = var("oak:Oak:0.72,0.52,0.30", "white:White:0.96,0.96,0.95", "walnut:Walnut:0.42,0.28,0.18"),
})

add("shelf_unit", {
    name = "Wire Utility Shelving", sub = "shelf", style = "starter", material = "chrome", price = 70, env = 0,
    rooms = { "kitchen", "study", "bedroom" }, height = 1.8,
    desc = "Chrome wire shelves on adjustable posts, as found in garages, pantries and optimistic first apartments. Two shelves with two slots each.",
    surfaces = { { cell = { 0, 0 }, z = 0.6, kind = "shelf", slots = 2 }, { cell = { 0, 0 }, z = 1.3, kind = "shelf", slots = 2 } },
    variants = var("chrome:Chrome:0.84,0.86,0.88", "black:Black:0.14,0.14,0.15", "white:White:0.96,0.96,0.95"),
})

add("cabinet_display", {
    name = "Glass Curio Cabinet", sub = "shelf", style = "traditional", material = "wood", price = 750, env = 6,
    rooms = { "living", "dining" }, height = 1.9,
    desc = "A lit glass cabinet with three shelves for porcelain, trophies and the gravy boat from the wedding. Anything displayed inside looks important, which is the whole idea.",
    surfaces = { { cell = { 0, 0 }, z = 0.5, kind = "shelf", slots = 1 }, { cell = { 0, 0 }, z = 1.0, kind = "shelf", slots = 1 }, { cell = { 0, 0 }, z = 1.5, kind = "shelf", slots = 1 } },
    variants = var("mahogany:Mahogany:0.42,0.16,0.10", "walnut:Walnut:0.42,0.28,0.18", "white:White:0.94,0.94,0.92"),
})

add("console_media", {
    name = "Low Media Console", sub = "shelf", style = "contemporary", material = "wood", price = 380, env = 3,
    rooms = { "living", "study" }, fp = K.rect(2, 1), height = 0.55,
    desc = "A long, low sideboard in matte lacquer with push-to-open doors and a cable hole for every excuse. Two cells of top surface for a radio, a plant or a stack of remotes.",
    surfaces = K.surf("shelf", 0.55, 2, 1, 2),
    variants = var("white:Matte White:0.94,0.94,0.92", "oak:Pale Oak:0.80,0.66,0.46", "black:Charcoal:0.20,0.20,0.22"),
})

add("chest_blanket", {
    name = "Cedar Blanket Chest", sub = "shelf", style = "traditional", material = "wood", price = 240, env = 2,
    rooms = { "bedroom" }, fp = K.rect(2, 1), height = 0.5,
    desc = "A cedar-lined chest that keeps moths off the spare blankets and makes a handy seat-height shelf at the foot of a bed. Two cells of top surface.",
    surfaces = K.surf("end", 0.5, 2, 1, 1),
    variants = var("cedar:Cedar:0.72,0.46,0.30", "painted:Painted Folk:0.30,0.44,0.62", "oak:Oak:0.72,0.52,0.30"),
})
