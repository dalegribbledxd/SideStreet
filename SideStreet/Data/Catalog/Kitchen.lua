-- Buy-mode catalogue: Kitchen & Food (brief §8.1: at least 16 designs).
-- Owner: catalogue module. "snack" is listed on fridges; the cooking chain (household-core) attaches
-- by tag (fridge, stove, oven, microwave, coffee, toaster, dishwasher, bin, bin_outdoor, grill, buffet).
-- Read today: quality.cooking on stove/oven/microwave/grill/toaster (Chains.ApplianceQ: meal quality
-- and fewer burns), quality.fireRisk as a multiplier on cooking fires (1 = normal, left out = 1;
-- Chains.FireChance, Fire.CookingChance), quality.breakChance per use (Maintenance; household-core's
-- own defaults are 0.002-0.008, budget designs use exactly those), quality.capacity on dishwashers
-- and bins, and def.noise while a dishwasher runs (World.NoiseAt; 5 wakes a sleeper in the same
-- cell). Requested, not read yet (docs/requests/catalogue.md HC-3): quality.speed, quality.freshness
-- and the fridge's quality.capacity. Grills are adultOnly: children never light them.
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("kitchen")
local var = K.var
local COUNTER_ONLY = { "counter" }
local TOPS = { "counter", "table", "shelf" }

add("fridge_basic", { -- original 0.1.0 object
    name = "Chillmaster 90 Icebox", sub = "fridge", style = "starter", material = "metal", price = 450, env = 0,
    rooms = { "kitchen" }, height = 1.7, powered = true,
    desc = "Keeps food cold and opinions warm. The light comes on every time, which is more than can be said for your cousin. Breaks down now and then and hums about it.",
    slots = { front = K.front() }, actions = { "snack" }, tags = { "fridge" },
    quality = { freshness = 1.0, capacity = 12, breakChance = 0.002, repairDifficulty = 3 },
    variants = var("white:Appliance White:0.95,0.95,0.94", "almond:Almond:0.90,0.84,0.70", "avocado:Avocado:0.56,0.62,0.30"),
})

add("fridge_standard", {
    name = "Frostline Twin-Door Fridge", sub = "fridge", style = "traditional", material = "metal", price = 1100, env = 1,
    rooms = { "kitchen" }, height = 1.8, powered = true,
    desc = "A freezer on top, a fridge below and a door alarm that sighs if you stand there deciding. Breaks down half as often as a budget icebox.",
    slots = { front = K.front() }, actions = { "snack" }, tags = { "fridge" },
    quality = { freshness = 1.4, capacity = 18, breakChance = 0.001, repairDifficulty = 3 },
    variants = var("cream:Cream:0.94,0.90,0.80", "red:Retro Red:0.78,0.16,0.16", "steel:Steel:0.78,0.80,0.82"),
})

add("fridge_luxury", {
    name = "Arctic Estate Refrigerator", sub = "fridge", style = "contemporary", material = "metal", price = 2500, env = 3,
    rooms = { "kitchen" }, fp = K.rect(2, 1), height = 1.9, powered = true,
    desc = "Side-by-side doors, an ice dispenser and enough shelving to lose a whole lasagne in. Breaks down a quarter as often as a budget icebox and lifts the whole kitchen.",
    slots = { front = K.frontWide(2) }, actions = { "snack" }, tags = { "fridge" },
    quality = { freshness = 1.8, capacity = 30, breakChance = 0.0005, repairDifficulty = 5 },
    variants = var("steel:Brushed Steel:0.78,0.80,0.82", "black:Black Glass:0.14,0.14,0.16", "white:Gloss White:0.96,0.96,0.96"),
})

add("stove_basic", { -- original 0.1.0 object
    name = "Hearthline Budget Range", sub = "stove", style = "starter", material = "metal", price = 400, env = 0,
    rooms = { "kitchen" }, height = 0.95, powered = true,
    desc = "Four burners and an oven that has seen things. It cooks honest, ordinary meals; uneven heat burns more dinners than a better range does, and the odd grease fire is its speciality, so keep an extinguisher in mind.",
    slots = { front = K.front(1, "cook") }, tags = { "stove", "oven" },
    quality = { cooking = 3, speed = 1.0, breakChance = 0.006, repairDifficulty = 3 },
    variants = var("white:White Enamel:0.95,0.95,0.94", "harvest:Harvest Gold:0.86,0.66,0.26", "brown:Brown:0.42,0.30,0.22"),
})

add("stove_standard", {
    name = "Duchess Enamel Range", sub = "stove", style = "traditional", material = "metal", price = 900, env = 2,
    rooms = { "kitchen" }, height = 1.0, powered = true,
    desc = "Cast-iron grates, a thermostat that tells the truth and a warming drawer for rolls. Better-tasting meals, fewer burnt ones and roughly half the fire risk of a budget range.",
    slots = { front = K.front(1, "cook") }, tags = { "stove", "oven" },
    quality = { cooking = 5, speed = 1.1, fireRisk = 0.5, breakChance = 0.004, repairDifficulty = 3 },
    variants = var("cream:Cream Enamel:0.94,0.90,0.80", "blue:Duck-Egg Enamel:0.66,0.80,0.80", "black:Black Enamel:0.12,0.12,0.13"),
})

add("stove_luxury", {
    name = "Pro-Series Six-Burner Range", sub = "stove", style = "contemporary", material = "metal", price = 1800, env = 4,
    rooms = { "kitchen" }, fp = K.rect(2, 1), height = 1.0, powered = true,
    desc = "Six sealed burners, a convection oven and flame control fine enough to toast a single sesame seed. The best meals in the catalogue and a fifth of a budget range's fire risk.",
    slots = { front = K.frontWide(2, "cook") }, tags = { "stove", "oven" },
    quality = { cooking = 7, speed = 1.3, fireRisk = 0.2, breakChance = 0.0015, repairDifficulty = 5 },
    variants = var("steel:Stainless:0.78,0.80,0.82", "red:Chef's Red:0.72,0.14,0.14", "graphite:Graphite:0.30,0.31,0.33"),
})

add("microwave_basic", {
    name = "Zapper 700 Microwave", sub = "small", style = "starter", material = "metal", price = 120, env = 0,
    rooms = { "kitchen" }, mount = "surface", fits = COUNTER_ONLY, height = 0.35, powered = true,
    desc = "Reheats leftovers and ready meals exactly as unevenly as you feared. Goes on a counter; meals come out edible rather than impressive.",
    slots = { front = K.front(1, "use") }, tags = { "microwave" },
    quality = { cooking = 3, speed = 2.0, breakChance = 0.006, repairDifficulty = 2 },
    variants = var("white:White:0.95,0.95,0.94", "black:Black:0.16,0.16,0.17", "steel:Steel:0.78,0.80,0.82"),
})

add("microwave_premium", {
    name = "Sensorwave Combination Oven", sub = "small", style = "contemporary", material = "metal", price = 380, env = 1,
    rooms = { "kitchen" }, mount = "surface", fits = COUNTER_ONLY, height = 0.4, powered = true,
    desc = "A microwave with a grill element and a sensor that stops before the soup erupts. Noticeably better food than the Zapper, half its fire risk and a third of its breakdowns.",
    slots = { front = K.front(1, "use") }, tags = { "microwave" },
    quality = { cooking = 5, speed = 1.8, fireRisk = 0.5, breakChance = 0.002, repairDifficulty = 3 },
    variants = var("steel:Steel:0.78,0.80,0.82", "black:Black Glass:0.14,0.14,0.16", "red:Red:0.72,0.16,0.16"),
})

add("coffee_drip", {
    name = "Morning Drip Coffee Maker", sub = "small", style = "starter", material = "plastic", price = 85, env = 0,
    rooms = { "kitchen" }, mount = "surface", fits = TOPS, height = 0.4, powered = true,
    desc = "Gurgles for three minutes and produces something recognisably coffee, with a small morning lift of energy. Goes on a counter or table.",
    slots = { front = K.front(1, "use") }, tags = { "coffee" },
    quality = { speed = 1.0, breakChance = 0.006, repairDifficulty = 1 },
    variants = var("black:Black:0.16,0.16,0.17", "white:White:0.95,0.95,0.94", "red:Red:0.72,0.16,0.16"),
})

add("coffee_espresso", {
    name = "Barista Pro Espresso Machine", sub = "small", style = "contemporary", material = "chrome", price = 950, env = 2,
    rooms = { "kitchen" }, mount = "surface", fits = COUNTER_ONLY, height = 0.5, powered = true,
    desc = "Fifteen bars of pressure, a steam wand and a gauge nobody understands. The same good cup as a drip machine, far fewer breakdowns and a hiss that makes every morning dramatic.",
    slots = { front = K.front(1, "use") }, tags = { "coffee" },
    quality = { speed = 1.4, breakChance = 0.0025, repairDifficulty = 4 },
    variants = var("chrome:Chrome:0.84,0.86,0.88", "copper:Copper:0.74,0.46,0.30", "cream:Cream:0.94,0.90,0.80"),
})

add("toaster", {
    name = "Two-Slot Pop-Up Toaster", sub = "small", style = "starter", material = "chrome", price = 40, env = 0,
    rooms = { "kitchen" }, mount = "surface", fits = TOPS, height = 0.25, powered = true,
    desc = "Two slots, one dial and a spring that launches toast at roughly shoulder height. Toast for breakfast; leave it alone too long and the crumbs may catch.",
    slots = { front = K.front(1, "use") }, tags = { "toaster" },
    quality = { cooking = 3, speed = 1.5, breakChance = 0.006, repairDifficulty = 1 },
    variants = var("chrome:Chrome:0.84,0.86,0.88", "mint:Mint:0.66,0.86,0.76", "black:Black:0.16,0.16,0.17"),
})

add("dishwasher_basic", {
    name = "Rinsemaster Dishwasher", sub = "dishwasher", style = "starter", material = "metal", price = 550, env = 0,
    rooms = { "kitchen" }, height = 0.9, powered = true,
    desc = "Holds eight place settings and cleans them in a cycle that sounds like a washing machine climbing stairs. Loud enough to wake anyone asleep nearby; breaks now and then.",
    slots = { front = K.front(1, "use") }, tags = { "dishwasher" },
    noise = 7, quality = { speed = 1.0, capacity = 8, breakChance = 0.008, repairDifficulty = 3 },
    variants = var("white:White:0.95,0.95,0.94", "almond:Almond:0.90,0.84,0.70", "black:Black:0.16,0.16,0.17"),
})

add("dishwasher_quiet", {
    name = "Whisper-Clean Dishwasher", sub = "dishwasher", style = "contemporary", material = "metal", price = 1300, env = 1,
    rooms = { "kitchen" }, height = 0.9, powered = true,
    desc = "So quiet the household checks twice whether it started, then argues about who forgot the tablet. Twelve place settings, never loud enough to wake a sleeper, and rare breakdowns.",
    slots = { front = K.front(1, "use") }, tags = { "dishwasher" },
    noise = 2, quality = { speed = 1.5, capacity = 12, breakChance = 0.0025, repairDifficulty = 4 },
    variants = var("steel:Stainless:0.78,0.80,0.82", "white:Gloss White:0.96,0.96,0.96", "panel:Wood Panel:0.66,0.48,0.30"),
})

add("bin_indoor", { -- original 0.1.0 object
    name = "Kitchen Pedal Bin", sub = "bin", style = "starter", material = "metal", price = 30, env = 0,
    rooms = { "kitchen" }, height = 0.6,
    desc = "Holds rubbish until someone other than you empties it. Ten loads of scraps before it overflows and starts affecting the room.",
    slots = { front = K.front() }, tags = { "bin" },
    quality = { capacity = 10 },
    variants = var("chrome:Chrome:0.84,0.86,0.88", "white:White:0.95,0.95,0.94", "red:Red:0.72,0.16,0.16"),
})

add("bin_compactor", {
    name = "Trash Crusher Compactor", sub = "bin", style = "contemporary", material = "metal", price = 400, env = 0,
    rooms = { "kitchen" }, height = 0.9, powered = true,
    desc = "Squashes a week of rubbish into one dense, faintly menacing cube. Holds three times as much as a pedal bin, so trips outside become rare events.",
    slots = { front = K.front() }, tags = { "bin" },
    quality = { capacity = 30, breakChance = 0.004, repairDifficulty = 3 },
    variants = var("steel:Stainless:0.78,0.80,0.82", "black:Black:0.16,0.16,0.17", "white:White:0.95,0.95,0.94"),
})

add("bin_outdoor", {
    name = "Curbside Wheelie Bin", sub = "bin", style = "garden", material = "plastic", price = 60, env = 0,
    rooms = { "outdoor" }, height = 1.0, outdoor = true,
    desc = "Where full rubbish bags go to wait for collection day. Holds ten bags; leave it overflowing and the neighbourhood's wildlife will leave reviews.",
    slots = { front = K.front() }, tags = { "bin_outdoor" },
    quality = { capacity = 10 },
    variants = var("green:Council Green:0.24,0.44,0.26", "grey:Grey:0.46,0.48,0.50", "blue:Recycling Blue:0.20,0.36,0.66"),
})

add("grill_charcoal", {
    name = "Kettle Charcoal Grill", sub = "grill", style = "garden", material = "metal", price = 180, env = 1,
    rooms = { "outdoor" }, height = 1.0, outdoor = true, adultOnly = true,
    desc = "A domed kettle on three legs that makes every sausage an occasion. Smoky, decent food; loose embers give it twice the fire risk of a gas grill.",
    slots = { front = K.front(1, "cook") }, tags = { "grill" },
    quality = { cooking = 3, speed = 0.8, breakChance = 0.002, repairDifficulty = 1 },
    variants = var("black:Black:0.14,0.14,0.14", "red:Red:0.72,0.16,0.16", "green:Green:0.24,0.44,0.26"),
})

add("grill_gas", {
    name = "Backyard Gas Grill Deluxe", sub = "grill", style = "garden", material = "metal", price = 850, env = 3,
    rooms = { "outdoor" }, fp = K.rect(2, 1), height = 1.1, outdoor = true, adultOnly = true,
    desc = "Four burners, a side shelf and a lid thermometer that makes everyone an expert. Tastier barbecues with half the fire risk of charcoal.",
    slots = { front = K.frontWide(2, "cook") }, tags = { "grill" },
    quality = { cooking = 5, speed = 1.2, fireRisk = 0.5, breakChance = 0.002, repairDifficulty = 3 },
    variants = var("steel:Stainless:0.78,0.80,0.82", "black:Black:0.14,0.14,0.14", "copper:Copper Lid:0.74,0.46,0.30"),
})

add("tea_trolley", {
    name = "Brass Tea Trolley", sub = "serving", style = "eclectic", material = "metal", price = 180, env = 3,
    rooms = { "dining", "living" }, height = 0.9,
    desc = "Two glass tiers on squeaky brass wheels for serving snacks with a flourish. Set a group meal on it and guests help themselves.",
    surfaces = K.surf("table", 0.8, 1, 1, 2), slots = { front = K.around("use") }, tags = { "buffet" },
    variants = var("brass:Brass:0.84,0.68,0.34", "chrome:Chrome:0.84,0.86,0.88", "black:Black & Gold:0.14,0.12,0.10"),
})

add("buffet_station", {
    name = "Chafing Buffet Station", sub = "serving", style = "traditional", material = "fabric", price = 600, env = 2,
    rooms = { "dining", "venue" }, fp = K.rect(2, 1), height = 0.95,
    desc = "Two warming trays over little burners, built for a party platter. Set group meals here for guests to help themselves; twice the serving space of a trolley.",
    surfaces = K.surf("table", 0.85, 2, 1, 2), slots = { front = K.frontWide(2, "use") }, tags = { "buffet" },
    variants = var("silver:Silver:0.82,0.84,0.86", "brass:Brass:0.84,0.68,0.34", "copper:Copper:0.74,0.46,0.30"),
})
