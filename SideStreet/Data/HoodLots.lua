-- SideStreet neighbourhood lot blueprints: the 7 houses (4 premade homes, 3 homes for sale),
-- 3 empty parcels and placeholder layouts for the 4 community venues (used only when the
-- outings module's SS.Venues.BuildLot is missing). Sim/HoodLots.lua turns a blueprint into
-- real, editable lot data (walls, floors, doors, windows, stairs, roof, fences, pool, paths,
-- objects). Owner: hood module.
--
-- Blueprint fields (lot-local cells; the street runs along j = h):
--   name, desc, w, h, land (price of the land), entry = {i, j} (row h-1), tier, style
--   roof = { style, material, color }, ext = { wall finish candidates (first that exists) }
--   rooms = { { lv, i0, j0, i1, j1, name, floor = {...}, paint = {...}, group = "x" } }
--       Walls are generated automatically: on the edge between a room cell and a non-room cell
--       (exterior wall), and between two rooms of different groups (partition). Rooms sharing
--       a group are open plan. Wall finishes come from the room on each side (paint) or `ext`.
--   doors / arches / windows = { { lv, edgeKey, front = true? } }
--   outdoor = { { lv, i0, j0, i1, j1, { floor candidates } } }   paths, porches, decks, balconies
--   stairs = { { x, y, f } }   (stairs_straight; wells upstairs and railings are automatic)
--   fence = { back = true, west = {j0, j1}, east = {j0, j1}, gateFront = bool }
--   pool = { i0, j0, i1, j1, depth }
--   mailbox = { x, y, f }
--   items = { { role, lv, x, y, f, extra... } }  roles are resolved through SS.Catalog.Find
--       (HL.roles below) with a fallback to the 15 base object ids; `n` picks the n-th
--       cheapest match for variety; dining = table + auto chairs (`chairs`); `pairWith`
--       places a companion only when the primary bed sleeps one.
--   spawn = { { x, y, lv } }  where residents stand when the household is created
local _, SS = ...
local HL = SS.HoodLots or {}
SS.HoodLots = HL

---------------------------------------------------------------------------
-- Furnishing roles: catalogue queries (ARCHITECTURE 7 tags) in preference order, price bands
-- per tier (ARCHITECTURE 9.7 scale), and the base-object fallback. `base = false` means the
-- item is skipped when the catalogue has nothing suitable (decor that has no base stand-in).
---------------------------------------------------------------------------
HL.roles = {
    fridge = { q = { { tag = "fridge" } }, band = { budget = { nil, 800 }, mid = { 700, 1600 }, lux = { 1500 } }, base = "fridge_basic" },
    stove = { q = { { tag = "stove" } }, band = { budget = { nil, 700 }, mid = { 600, 1200 }, lux = { 1100 } }, base = "stove_basic" },
    counter = { q = { { tag = "counter" } }, band = { budget = { nil, 200 }, mid = { 150, 500 }, lux = { 400 } }, base = "counter_basic" },
    ksink = { q = { { tag = "sink" } }, band = { budget = { nil, 300 }, mid = { 200, 700 }, lux = { 600 } }, base = "counter_basic" },
    dishwasher = { q = { { tag = "dishwasher" } }, band = { budget = { nil, 600 }, mid = { 500, 1100 }, lux = { 1000 } }, base = false },
    microwave = { q = { { tag = "microwave" } }, base = false },
    coffee = { q = { { tag = "coffee" } }, base = false },
    grill = { q = { { tag = "grill" } }, base = false },
    bin = { q = { { tag = "bin" } }, base = "bin_indoor" },
    bin_out = { q = { { tag = "bin_outdoor" } }, base = false },
    toilet = { q = { { tag = "toilet" } }, band = { budget = { nil, 450 }, mid = { 400, 800 }, lux = { 750 } }, base = "toilet_basic" },
    basin = { q = { { tag = "basin" } }, band = { budget = { nil, 250 }, mid = { 200, 600 }, lux = { 500 } }, base = "sink_pedestal" },
    shower = { q = { { tag = "shower" } }, band = { budget = { nil, 800 }, mid = { 600, 1500 }, lux = { 1400 } }, base = "shower_basic" },
    bath = { q = { { tag = "bath" }, { tag = "shower" } }, band = { budget = { nil, 1000 }, mid = { 800, 2000 }, lux = { 1800 } }, base = "shower_basic" },
    bed = { q = { { tag = "bed", sub = "single" }, { tag = "bed" } }, band = { budget = { nil, 600 }, mid = { 450, 1400 }, lux = { 1200 } }, base = "bed_single", sleeps = 1 },
    bed2 = { q = { { tag = "bed", sub = "double" }, { tag = "bed" } }, band = { budget = { nil, 900 }, mid = { 700, 2000 }, lux = { 1800 } }, base = "bed_single", sleeps = 2 },
    bed_child = { q = { { tag = "bed_child" }, { tag = "bed", sub = "single" } }, base = "bed_single", sleeps = 1 },
    chair = { q = { { tag = "seat", cat = "seating", sub = "dining" }, { tag = "seat", cat = "seating" } }, band = { budget = { nil, 120 }, mid = { 90, 300 }, lux = { 250, 900 } }, base = "chair_dining" },
    armchair = { q = { { tag = "seat", cat = "seating", sub = "armchair" }, { tag = "seat", cat = "seating" } }, band = { budget = { 200, 450 }, mid = { 300, 800 }, lux = { 600 } }, base = "armchair_basic" },
    sofa = { q = { { tag = "sofa" }, { tag = "seat", cat = "seating", sub = "armchair" } }, band = { budget = { nil, 600 }, mid = { 500, 1200 }, lux = { 1100 } }, base = "armchair_basic" },
    outdoor_seat = { q = { { tag = "seat", cat = "outdoor" }, { tag = "seat", style = "garden" } }, base = "chair_dining" },
    table = { q = { { tag = "table_dining" } }, band = { budget = { nil, 300 }, mid = { 200, 900 }, lux = { 800 } }, base = "table_small" },
    endtable = { q = { { cat = "surfaces", sub = "end" }, { cat = "surfaces", sub = "coffee" } }, base = false },
    desk = { q = { { cat = "surfaces", sub = "desk" } }, base = "table_small" },
    tv = { q = { { tag = "tv" } }, band = { budget = { nil, 700 }, mid = { 600, 2000 }, lux = { 1800 } }, base = "tv_basic" },
    stereo = { q = { { tag = "stereo" }, { tag = "radio" } }, base = false },
    computer = { q = { { tag = "computer" } }, base = false },
    phone = { q = { { tag = "phone" } }, base = false },
    smoke_alarm = { q = { { tag = "smoke_alarm" } }, base = false },
    lamp = { q = { { tag = "lamp", cat = "lighting" } }, band = { budget = { nil, 120 }, mid = { 80, 400 }, lux = { 300 } }, base = "lamp_floor" },
    lamp_out = { q = { { tag = "lamp", cat = "outdoor" }, { tag = "lamp", sub = "outdoor" } }, base = "lamp_floor" },
    plant = { q = { { cat = "decor", sub = "plant" }, { cat = "decor", tag = "flowers" } }, base = "plant_pot" },
    painting = { q = { { tag = "painting" } }, band = { budget = { nil, 300 }, mid = { 200, 1500 }, lux = { 1200 } }, base = false },
    sculpture = { q = { { cat = "decor", sub = "sculpture" } }, base = "plant_pot" },
    rug = { q = { { tag = "rug" } }, base = false },
    clock = { q = { { cat = "decor", sub = "clock" } }, base = false },
    bookshelf = { q = { { tag = "bookshelf" } }, base = false },
    dresser = { q = { { tag = "dresser" } }, base = false },
    mirror = { q = { { tag = "mirror" } }, base = false },
    fireplace = { q = { { tag = "fireplace" } }, base = false },
    piano = { q = { { tag = "piano" } }, base = false },
    easel = { q = { { tag = "easel" } }, base = false },
    chess = { q = { { tag = "chess" } }, base = false },
    exercise = { q = { { tag = "exercise" } }, base = false },
    game = { q = { { tag = "game" }, { tag = "arcade" } }, base = false },
    toybox = { q = { { tag = "toybox" } }, base = false },
    kid_play = { q = { { tag = "kid_play" } }, base = false },
    garden_plot = { q = { { tag = "garden_plot" }, { tag = "planter" } }, base = false },
    tree = { landscape = true, q = { { tag = "tree" } }, base = "plant_pot" },
    shrub = { landscape = true, q = { { tag = "shrub" } }, base = "plant_pot" },
    flowers = { landscape = true, q = { { tag = "flowers" } }, base = false },
    fountain = { landscape = true, q = { { tag = "fountain" }, { tag = "birdbath" } }, base = false },
    -- community anchors (placeholder venues only)
    register = { q = { { tag = "register" } }, base = "counter_basic" },
    display = { q = { { tag = "display_clothing" }, { tag = "display_gift" }, { tag = "display_books" }, { tag = "display_decor" } }, base = "table_small" },
    podium = { q = { { tag = "podium" } }, base = "counter_basic" },
    bar = { q = { { tag = "bar" } }, base = "counter_basic" },
    dj = { q = { { tag = "dj_booth" }, { tag = "dj" } }, base = "counter_basic" },
    dance = { q = { { tag = "dance" } }, base = false },
    pool_table = { q = { { tag = "pool_table" }, { tag = "darts" } }, base = "table_small" },
    mailbox = { q = { { tag = "mailbox" } }, base = "hood_mailbox" },
}

-- Base object ids that stand in for a tag while the catalogue lacks tags on them.
HL.BASE_KIND = {
    fridge_basic = "fridge", stove_basic = "stove", counter_basic = "counter", bed_single = "bed",
    toilet_basic = "toilet", shower_basic = "shower", sink_pedestal = "basin", armchair_basic = "seat",
    chair_dining = "seat", table_small = "table", tv_basic = "tv", lamp_floor = "lamp", plant_pot = "plant",
    bin_indoor = "bin", hood_mailbox = "mailbox", stairs_straight = "stairs",
}

local B = {}
HL.blueprints = B

---------------------------------------------------------------------------
-- 1. Juniper Bungalow (4 Juniper Lane): the existing starter (SS.Fixtures.StarterLot) kept
--    exactly as it was, plus a lot entry at the end of its path and a curbside mailbox.
---------------------------------------------------------------------------
B.kettering = {
    starter = true, name = "Juniper Bungalow", land = 5200, tier = "budget", style = "starter",
    desc = "A one-bedroom bungalow with sage siding, a proud fern population and exactly one dining chair.",
    entry = { 4, 10 }, mailbox = { 3, 10, 2 }, frontDoor = "x:4:9",
}

---------------------------------------------------------------------------
-- 2. The Halloran house (3 Juniper Lane): two-story family home with real stairs, a porch,
--    a fenced back garden and five rooms upstairs.
---------------------------------------------------------------------------
B.halloran = {
    name = "Halloran House", w = 18, h = 16, land = 9000, tier = "mid", style = "traditional",
    desc = "A slate-roofed two-story family home: porch swing energy, homework on every surface, a stair that creaks on step four.",
    entry = { 8, 15 },
    roof = { style = "gable", material = "shingle", color = "slate" },
    ext = { "siding_blue", "siding_sky", "siding_sage" },
    rooms = {
        { 0, 3, 3, 6, 11, "Living room", floor = { "wood_honey", "wood" }, paint = { "paint_cream" } },
        { 0, 7, 6, 9, 11, "Hall", floor = { "wood_oak", "wood" }, paint = { "paint_cream" } },
        { 0, 7, 3, 9, 5, "Cloakroom", floor = { "tile_white", "tile" }, paint = { "paint_seafoam" } },
        { 0, 10, 3, 14, 7, "Kitchen", floor = { "tile_check", "tile" }, paint = { "paint_cream" }, group = "kd" },
        { 0, 10, 8, 14, 11, "Dining room", floor = { "wood_honey", "wood" }, paint = { "paint_cream" }, group = "kd" },
        { 1, 7, 6, 9, 11, "Landing", floor = { "carpet_blue", "carpet" }, paint = { "paint_cream" } },
        { 1, 7, 3, 9, 5, "Bathroom", floor = { "tile_white", "tile" }, paint = { "paint_seafoam" } },
        { 1, 10, 3, 14, 7, "Main bedroom", floor = { "carpet_rose", "carpet" }, paint = { "paint_cream" } },
        { 1, 3, 3, 6, 7, "Pip's room", floor = { "carpet_green", "carpet" }, paint = { "paint_cream" } },
        { 1, 3, 8, 6, 11, "Juno's room", floor = { "carpet_lilac", "carpet" }, paint = { "paint_cream" } },
        { 1, 10, 8, 14, 11, "Studio", floor = { "wood_oak", "wood" }, paint = { "paint_cream" } },
    },
    doors = {
        { 0, "x:8:12", front = true }, { 0, "x:8:6" }, { 0, "y:15:5" },
        { 1, "x:8:6" }, { 1, "y:10:6" }, { 1, "y:7:6" }, { 1, "y:7:10" }, { 1, "y:10:10" },
    },
    arches = { { 0, "y:7:10" }, { 0, "y:10:10" } },
    windows = {
        { 0, "y:3:5" }, { 0, "y:3:9" }, { 0, "x:4:12" }, { 0, "x:5:12" }, { 0, "x:12:12" }, { 0, "x:13:12" },
        { 0, "x:13:3" }, { 0, "y:15:9" }, { 0, "x:5:3" },
        { 1, "y:3:5" }, { 1, "x:4:3" }, { 1, "y:3:10" }, { 1, "x:4:12" }, { 1, "x:12:3" }, { 1, "y:15:5" },
        { 1, "x:12:12" }, { 1, "y:15:10" }, { 1, "x:8:12" }, { 1, "x:8:3" },
    },
    stairs = { { 7, 7, 0 } },
    outdoor = {
        { 0, 6, 12, 10, 12, { "deck_cedar", "deck", "wood" } },
        { 0, 8, 13, 8, 15, { "path_flagstone", "path" } },
        { 0, 15, 4, 16, 6, { "path_brick", "path" } },
        { 0, 9, 1, 11, 2, { "path_flagstone", "path" } },
    },
    fence = { back = true, west = { 0, 11 }, east = { 0, 11 } },
    mailbox = { 7, 15, 2 },
    items = {
        -- kitchen and dining
        { "fridge", 0, 10, 3, 0 }, { "counter", 0, 11, 3, 0 }, { "stove", 0, 12, 3, 0 }, { "counter", 0, 13, 3, 0 },
        { "ksink", 0, 14, 3, 0 }, { "bin", 0, 14, 6, 1 }, { "dishwasher", 0, 10, 6, 3 },
        { "dining", 0, 12, 9, 0, chairs = 4 },
        { "phone", 0, 14, 11, 1 }, { "smoke_alarm", 0, 13, 7, 2 },
        -- living room
        { "tv", 0, 3, 6, 3 }, { "sofa", 0, 5, 6, 1 }, { "armchair", 0, 5, 8, 1 }, { "lamp", 0, 3, 3, 0 },
        { "bookshelf", 0, 4, 3, 0 }, { "plant", 0, 6, 3, 0 }, { "rug", 0, 3, 11, 0 }, { "lamp", 0, 6, 11, 2 },
        -- cloakroom
        { "toilet", 0, 7, 3, 0 }, { "basin", 0, 9, 3, 0 },
        -- hall
        { "plant", 0, 9, 7, 1 }, { "clock", 0, 9, 11, 1 },
        -- upstairs
        { "toilet", 1, 7, 3, 0 }, { "basin", 1, 8, 3, 0 }, { "bath", 1, 9, 3, 0 },
        { "bed2", 1, 12, 4, 0 }, { "bed", 1, 14, 4, 0, pairWith = -1 }, { "dresser", 1, 10, 3, 0 }, { "lamp", 1, 10, 7, 3 },
        { "mirror", 1, 11, 3, 0 },
        { "bed_child", 1, 3, 4, 0 }, { "toybox", 1, 6, 3, 0 }, { "lamp", 1, 6, 7, 2 }, { "desk", 1, 3, 7, 3 },
        { "bed_child", 1, 3, 9, 0 }, { "toybox", 1, 6, 11, 2 }, { "lamp", 1, 5, 11, 2 },
        { "easel", 1, 10, 11, 0 }, { "desk", 1, 14, 9, 1 }, { "computer", 1, 13, 11, 2 }, { "lamp", 1, 14, 11, 1 },
        { "bookshelf", 1, 12, 8, 0 }, { "chair", 1, 13, 9, 3 },
        { "smoke_alarm", 1, 9, 10, 1 },
        -- garden
        { "tree", 0, 2, 14, 0 }, { "tree", 0, 15, 14, 0 }, { "tree", 0, 1, 1, 0 }, { "tree", 0, 16, 1, 0 },
        { "shrub", 0, 11, 13, 0 }, { "flowers", 0, 5, 13, 0 }, { "flowers", 0, 6, 13, 0 },
        { "kid_play", 0, 4, 1, 0 }, { "garden_plot", 0, 13, 1, 0 }, { "bin_out", 0, 17, 7, 1 },
        { "outdoor_seat", 0, 9, 12, 0 }, { "lamp_out", 0, 10, 13, 0 },
    },
    spawn = { { 8, 9, 0 }, { 9, 10, 0 }, { 4, 8, 0 }, { 5, 10, 0 } },
}

---------------------------------------------------------------------------
-- 3. The roommate house (5 Juniper Lane): cramped kitchen, one bathroom for three, clutter.
---------------------------------------------------------------------------
B.roommates = {
    name = "Juniper Flatshare", w = 16, h = 13, land = 7800, tier = "budget", style = "eclectic",
    desc = "Three bedrooms, one bathroom, one counter and a sofa on the front lawn that nobody admits to owning.",
    entry = { 4, 12 },
    roof = { style = "hip", material = "shingle", color = "moss" },
    ext = { "stucco_mustard", "paint_cream" },
    rooms = {
        { 0, 2, 2, 5, 4, "Kitchen", floor = { "lino_yellow", "tile" }, paint = { "paint_cream" }, group = "kl" },
        { 0, 2, 5, 8, 9, "Living room", floor = { "carpet_brown", "carpet" }, paint = { "paint_cream" }, group = "kl" },
        { 0, 6, 2, 8, 4, "Bathroom", floor = { "tile_white", "tile" }, paint = { "paint_seafoam" } },
        { 0, 9, 5, 13, 5, "Hall", floor = { "wood_pine", "wood" }, paint = { "paint_cream" } },
        { 0, 9, 2, 13, 4, "Priya's room", floor = { "wood_oak", "wood" }, paint = { "paint_seafoam" } },
        { 0, 9, 6, 11, 9, "Gus's room", floor = { "carpet_brown", "carpet" }, paint = { "paint_cream" } },
        { 0, 12, 6, 13, 9, "Mo's room", floor = { "carpet_green", "carpet" }, paint = { "paint_cream" } },
    },
    doors = { { 0, "x:4:10", front = true }, { 0, "x:7:5" }, { 0, "x:10:5" }, { 0, "x:10:6" }, { 0, "x:12:6" } },
    arches = { { 0, "y:9:5" } },
    windows = {
        { 0, "x:6:10" }, { 0, "x:7:10" }, { 0, "y:2:7" }, { 0, "x:3:2" }, { 0, "x:11:2" }, { 0, "y:14:3" },
        { 0, "x:10:10" }, { 0, "y:14:7" }, { 0, "x:7:2" },
    },
    outdoor = { { 0, 4, 10, 4, 12, { "path_concrete", "path" } }, { 0, 3, 10, 3, 10, { "path_concrete", "path" } } },
    fence = { back = true },
    mailbox = { 3, 12, 2 },
    items = {
        -- the cramped kitchen: one counter, one sink, one stove, one fridge
        { "fridge", 0, 2, 2, 0, state = { dirt = 40 } }, { "counter", 0, 3, 2, 0, state = { dirt = 75, dirty = true } },
        { "stove", 0, 4, 2, 0, state = { dirt = 70, dirty = true } }, { "ksink", 0, 5, 2, 0, state = { dirt = 60, dirty = true } },
        { "bin", 0, 2, 4, 3, state = { full = true, dirt = 55, dirty = true } }, { "microwave", 0, 5, 4, 1 },
        -- living room
        { "dining", 0, 3, 7, 0, chairs = 3 },
        { "tv", 0, 8, 6, 1 }, { "sofa", 0, 6, 6, 3 }, { "armchair", 0, 6, 8, 3 }, { "stereo", 0, 8, 9, 1 },
        { "lamp", 0, 2, 9, 0 }, { "plant", 0, 8, 7, 1 }, { "bin", 0, 5, 9, 2 }, { "rug", 0, 7, 9, 2 },
        { "game", 0, 5, 5, 0 }, { "smoke_alarm", 0, 2, 5, 0 },
        -- bathroom (one, shared)
        { "toilet", 0, 6, 2, 0, state = { dirt = 50 } }, { "basin", 0, 7, 2, 0, state = { dirt = 45 } }, { "shower", 0, 8, 2, 0, state = { dirt = 55, dirty = true } },
        -- Priya: tidy
        { "bed", 0, 12, 2, 1 }, { "bookshelf", 0, 9, 2, 0 }, { "plant", 0, 13, 4, 1 }, { "desk", 0, 9, 4, 3 },
        -- Gus: messy musician
        { "bed", 0, 9, 8, 0 }, { "stereo", 0, 11, 9, 1 }, { "lamp", 0, 11, 6, 1 }, { "bin", 0, 10, 9, 2, state = { full = true } },
        -- Mo: cook in training
        { "bed", 0, 13, 7, 0 }, { "lamp", 0, 13, 9, 2 },
        -- yard: overgrown, and that sofa
        { "armchair", 0, 10, 11, 0 }, { "tree", 0, 1, 1, 0 }, { "tree", 0, 14, 11, 0 }, { "tree", 0, 15, 1, 0 },
        { "shrub", 0, 1, 11, 0 }, { "bin_out", 0, 6, 11, 0 }, { "plant", 0, 8, 11, 0 },
    },
    spawn = { { 3, 5, 0 }, { 7, 7, 0 }, { 4, 8, 0 } },
}

---------------------------------------------------------------------------
-- 4. The Ashcombe residence (2 Alder Row): affluent, over-decorated, pool on the side.
---------------------------------------------------------------------------
B.ashcombe = {
    name = "Ashcombe Residence", w = 24, h = 18, land = 13000, tier = "lux", style = "traditional",
    desc = "A long charcoal-roofed house with a gallery hallway, a pool nobody has time to swim in and more ornaments than anyone has time to dust.",
    entry = { 9, 17 },
    roof = { style = "hip", material = "slate", color = "charcoal" },
    ext = { "brick_red", "stone_grey", "paint_cream" },
    rooms = {
        { 0, 2, 2, 7, 6, "Main suite", floor = { "carpet_cream", "carpet" }, paint = { "wallpaper_damask", "paint_cream" } },
        { 0, 8, 2, 10, 5, "Suite bath", floor = { "marble_white", "tile" }, paint = { "tile_mint", "paint_seafoam" } },
        { 0, 8, 6, 10, 12, "Gallery", floor = { "parquet", "wood" }, paint = { "paint_gallery", "paint_cream" } },
        { 0, 2, 7, 7, 12, "Salon", floor = { "parquet", "wood" }, paint = { "wallpaper_stripe", "paint_cream" } },
        { 0, 11, 2, 16, 7, "Kitchen", floor = { "marble_white", "tile" }, paint = { "paint_cream" }, group = "kd" },
        { 0, 11, 8, 16, 12, "Dining room", floor = { "parquet", "wood" }, paint = { "wallpaper_damask", "paint_cream" }, group = "kd" },
    },
    doors = { { 0, "x:9:13", front = true }, { 0, "y:8:4" }, { 0, "y:8:6" }, { 0, "y:11:7" }, { 0, "y:17:4" } },
    arches = { { 0, "y:8:10" }, { 0, "y:11:10" } },
    windows = {
        { 0, "x:3:2" }, { 0, "x:5:2" }, { 0, "y:2:4" }, { 0, "y:2:9" }, { 0, "y:2:11" }, { 0, "x:3:13" }, { 0, "x:5:13" },
        { 0, "x:8:13" }, { 0, "x:10:13" }, { 0, "x:12:13" }, { 0, "x:14:13" }, { 0, "x:13:2" }, { 0, "x:15:2" },
        { 0, "y:17:9" }, { 0, "y:17:11" }, { 0, "x:9:2" },
    },
    outdoor = {
        { 0, 17, 2, 23, 10, { "deck_teak", "deck", "wood" } },
        { 0, 9, 13, 9, 17, { "path_stone", "path" } }, { 0, 7, 14, 11, 14, { "path_stone", "path" } },
    },
    pool = { 19, 3, 22, 8, 2 },
    fence = { back = true, west = { 0, 12 }, east = { 0, 12 } },
    mailbox = { 8, 17, 2 },
    items = {
        -- main suite
        { "bed2", 0, 4, 3, 0 }, { "bed", 0, 2, 3, 0, pairWith = -1 }, { "dresser", 0, 7, 2, 0 }, { "mirror", 0, 6, 2, 0 },
        { "painting", 0, 3, 6, 2 }, { "painting", 0, 5, 6, 2, n = 2 }, { "plant", 0, 2, 6, 0 }, { "lamp", 0, 6, 5, 1 },
        { "rug", 0, 4, 6, 0 },
        -- suite bath
        { "bath", 0, 8, 2, 0 }, { "basin", 0, 9, 2, 0 }, { "toilet", 0, 10, 2, 0 }, { "shower", 0, 10, 5, 1 }, { "plant", 0, 8, 5, 2 },
        -- gallery
        { "painting", 0, 10, 7, 1, n = 3 }, { "painting", 0, 8, 8, 3, n = 4 }, { "sculpture", 0, 10, 9, 1 },
        { "sculpture", 0, 8, 12, 3, n = 2 }, { "plant", 0, 10, 12, 1 }, { "clock", 0, 8, 11, 3 }, { "lamp", 0, 10, 11, 1 },
        { "smoke_alarm", 0, 8, 7, 3 },
        -- salon
        { "tv", 0, 2, 8, 3 }, { "sofa", 0, 4, 8, 1 }, { "sofa", 0, 4, 9, 1, n = 2 }, { "fireplace", 0, 2, 10, 3 },
        { "armchair", 0, 5, 11, 2 }, { "armchair", 0, 6, 11, 2, n = 2 }, { "piano", 0, 6, 8, 0 },
        { "plant", 0, 2, 7, 0 }, { "plant", 0, 7, 12, 2 }, { "plant", 0, 2, 12, 3 }, { "lamp", 0, 3, 12, 2 },
        { "lamp", 0, 7, 7, 1 }, { "sculpture", 0, 7, 9, 0 }, { "painting", 0, 3, 7, 0, n = 5 }, { "rug", 0, 5, 10, 0 },
        { "endtable", 0, 3, 11, 0 }, { "clock", 0, 5, 7, 0 },
        -- kitchen
        { "fridge", 0, 11, 2, 0 }, { "counter", 0, 12, 2, 0 }, { "stove", 0, 13, 2, 0 }, { "counter", 0, 14, 2, 0, n = 2 },
        { "ksink", 0, 15, 2, 0 }, { "dishwasher", 0, 16, 2, 0 }, { "coffee", 0, 16, 3, 1 }, { "bin", 0, 16, 6, 1 },
        { "microwave", 0, 12, 5, 0 }, { "phone", 0, 11, 6, 3 }, { "smoke_alarm", 0, 15, 7, 2 },
        -- dining
        { "dining", 0, 13, 10, 0, chairs = 6 }, { "painting", 0, 11, 12, 3, n = 6 }, { "plant", 0, 16, 12, 1 },
        { "plant", 0, 16, 8, 1 }, { "sculpture", 0, 11, 8, 3, n = 3 },
        -- pool deck and garden
        { "outdoor_seat", 0, 18, 2, 0 }, { "outdoor_seat", 0, 20, 9, 2 }, { "outdoor_seat", 0, 21, 9, 2 },
        { "lamp_out", 0, 17, 10, 0 }, { "grill", 0, 23, 2, 0 }, { "fountain", 0, 5, 15, 0 },
        { "tree", 0, 1, 15, 0 }, { "tree", 0, 22, 15, 0 }, { "tree", 0, 21, 12, 0 }, { "tree", 0, 1, 1, 0 }, { "tree", 0, 12, 0, 0 },
        { "shrub", 0, 3, 14, 0 }, { "shrub", 0, 14, 14, 0 }, { "shrub", 0, 15, 14, 0 },
        { "flowers", 0, 6, 14, 0 }, { "flowers", 0, 12, 14, 0 }, { "flowers", 0, 13, 14, 0 },
        { "bin_out", 0, 17, 12, 0 }, { "lamp_out", 0, 8, 16, 0 }, { "lamp_out", 0, 10, 16, 0 },
    },
    spawn = { { 9, 10, 0 }, { 4, 10, 0 } },
}

---------------------------------------------------------------------------
-- 5. Wren Cottage (2 Juniper Lane): the cheapest furnished home for sale.
---------------------------------------------------------------------------
B.wren_cottage = {
    name = "Wren Cottage", w = 14, h = 12, land = 6000, tier = "budget", style = "starter",
    desc = "A terracotta-roofed cottage with one bedroom, a kitchenette and a garden gnome that came with the deeds.",
    entry = { 6, 11 },
    roof = { style = "gable", material = "clay", color = "terracotta" },
    ext = { "paint_cream" },
    rooms = {
        { 0, 3, 2, 5, 3, "Bathroom", floor = { "tile_white", "tile" }, paint = { "paint_seafoam" } },
        { 0, 6, 2, 7, 3, "Kitchenette", floor = { "tile_check", "tile" }, paint = { "paint_cream" }, group = "main" },
        { 0, 3, 4, 7, 8, "Living room", floor = { "wood_pine", "wood" }, paint = { "paint_cream" }, group = "main" },
        { 0, 8, 6, 10, 8, "Dining nook", floor = { "wood_pine", "wood" }, paint = { "paint_cream" }, group = "main" },
        { 0, 8, 2, 10, 5, "Bedroom", floor = { "carpet_rose", "carpet" }, paint = { "paint_cream" } },
    },
    doors = { { 0, "x:6:9", front = true }, { 0, "x:4:4" }, { 0, "x:9:6" } },
    windows = { { 0, "x:4:9" }, { 0, "x:9:9" }, { 0, "y:3:6" }, { 0, "x:9:2" }, { 0, "y:11:4" }, { 0, "y:11:7" }, { 0, "x:7:2" } },
    outdoor = { { 0, 6, 9, 6, 11, { "path_brick", "path" } } },
    fence = { back = true, west = { 0, 8 }, east = { 0, 8 } },
    mailbox = { 5, 11, 2 },
    items = {
        { "fridge", 0, 6, 2, 0 }, { "stove", 0, 7, 2, 0 }, { "counter", 0, 5, 4, 0 }, { "bin", 0, 3, 4, 0 },
        { "toilet", 0, 3, 2, 0 }, { "basin", 0, 4, 2, 0 }, { "shower", 0, 5, 2, 0 },
        { "bed", 0, 10, 3, 0 }, { "lamp", 0, 8, 2, 0 },
        { "tv", 0, 3, 6, 3 }, { "armchair", 0, 5, 6, 1 }, { "lamp", 0, 3, 8, 0 },
        { "dining", 0, 9, 7, 0, chairs = 2 }, { "plant", 0, 10, 6, 1 }, { "smoke_alarm", 0, 7, 8, 2 },
        { "tree", 0, 1, 10, 0 }, { "tree", 0, 12, 1, 0 }, { "flowers", 0, 4, 10, 0 }, { "sculpture", 0, 8, 10, 0 },
    },
    spawn = { { 5, 7, 0 }, { 6, 6, 0 } },
}

---------------------------------------------------------------------------
-- 6. Foxglove House (8 Juniper Lane): a mid-priced furnished home for sale.
---------------------------------------------------------------------------
B.hollyhock = {
    name = "Foxglove House", w = 16, h = 14, land = 8000, tier = "mid", style = "contemporary",
    desc = "Two bedrooms, a sensible bathroom, a proper dining table and foxgloves taller than the fence.",
    entry = { 4, 13 },
    roof = { style = "hip", material = "clay", color = "brick" },
    ext = { "siding_white", "siding_sage" },
    rooms = {
        { 0, 2, 2, 5, 5, "Bedroom", floor = { "carpet_blue", "carpet" }, paint = { "paint_cream" } },
        { 0, 6, 2, 8, 4, "Bathroom", floor = { "tile_white", "tile" }, paint = { "paint_seafoam" } },
        { 0, 6, 5, 8, 5, "Hall", floor = { "wood_oak", "wood" }, paint = { "paint_cream" } },
        { 0, 9, 2, 13, 5, "Second bedroom", floor = { "carpet_green", "carpet" }, paint = { "paint_cream" } },
        { 0, 2, 6, 7, 10, "Living room", floor = { "wood_oak", "wood" }, paint = { "paint_cream" } },
        { 0, 8, 6, 13, 10, "Kitchen and dining", floor = { "tile_slate", "tile" }, paint = { "paint_cream" } },
    },
    doors = { { 0, "x:4:11", front = true }, { 0, "y:6:5" }, { 0, "x:7:5" }, { 0, "y:9:5" }, { 0, "x:12:2" } },
    arches = { { 0, "x:7:6" }, { 0, "y:8:8" } },
    windows = {
        { 0, "x:3:2" }, { 0, "y:2:4" }, { 0, "x:10:2" }, { 0, "y:14:3" }, { 0, "x:6:11" }, { 0, "x:10:11" }, { 0, "x:11:11" },
        { 0, "y:2:8" }, { 0, "y:14:8" }, { 0, "x:7:2" },
    },
    outdoor = { { 0, 4, 11, 4, 13, { "path_flagstone", "path" } }, { 0, 11, 0, 13, 1, { "path_brick", "path" } } },
    fence = { back = true, west = { 0, 10 }, east = { 0, 10 } },
    mailbox = { 3, 13, 2 },
    items = {
        { "fridge", 0, 9, 6, 0 }, { "counter", 0, 10, 6, 0 }, { "stove", 0, 11, 6, 0 }, { "counter", 0, 12, 6, 0 },
        { "ksink", 0, 13, 6, 0 }, { "dishwasher", 0, 8, 6, 0 }, { "bin", 0, 13, 8, 1 },
        { "dining", 0, 11, 9, 0, chairs = 4 },
        { "tv", 0, 2, 7, 3 }, { "sofa", 0, 4, 7, 1 }, { "armchair", 0, 4, 9, 1 }, { "lamp", 0, 2, 6, 0 },
        { "plant", 0, 2, 10, 0 }, { "bookshelf", 0, 7, 10, 2 }, { "rug", 0, 3, 9, 0 }, { "phone", 0, 6, 6, 0 },
        { "bed2", 0, 3, 2, 0 }, { "bed", 0, 5, 2, 0, pairWith = -1 }, { "dresser", 0, 2, 5, 3 }, { "lamp", 0, 4, 5, 2 },
        { "toilet", 0, 6, 2, 0 }, { "basin", 0, 7, 2, 0 }, { "bath", 0, 8, 2, 0 },
        { "bed", 0, 12, 3, 0 }, { "desk", 0, 10, 2, 0 }, { "computer", 0, 9, 3, 3 }, { "lamp", 0, 13, 5, 1 },
        { "smoke_alarm", 0, 7, 9, 1 },
        { "tree", 0, 1, 12, 0 }, { "tree", 0, 14, 12, 0 }, { "tree", 0, 1, 0, 0 }, { "flowers", 0, 6, 12, 0 },
        { "flowers", 0, 7, 12, 0 }, { "flowers", 0, 9, 12, 0 }, { "garden_plot", 0, 8, 0, 0 }, { "outdoor_seat", 0, 12, 0, 0 },
    },
    spawn = { { 4, 8, 0 }, { 5, 9, 0 } },
}

---------------------------------------------------------------------------
-- 7. The Larchmont (1 Alder Row): upscale two-story home for sale, balcony and lap pool.
---------------------------------------------------------------------------
B.larchmont = {
    name = "The Larchmont", w = 20, h = 16, land = 11000, tier = "lux", style = "contemporary",
    desc = "Two stories of clean lines, a balcony for dramatic announcements and a lap pool for undramatic laps.",
    entry = { 10, 15 },
    roof = { style = "hip", material = "metal", color = "pewter" },
    ext = { "render_white", "siding_white", "paint_cream" },
    rooms = {
        { 0, 3, 5, 8, 10, "Living room", floor = { "wood_ash", "wood" }, paint = { "paint_cream" } },
        { 0, 9, 5, 10, 10, "Stair hall", floor = { "tile_slate", "tile" }, paint = { "paint_cream" } },
        { 0, 11, 2, 14, 6, "Kitchen", floor = { "tile_slate", "tile" }, paint = { "paint_cream" }, group = "kd" },
        { 0, 11, 7, 14, 10, "Dining room", floor = { "wood_ash", "wood" }, paint = { "paint_cream" }, group = "kd" },
        { 0, 3, 2, 6, 4, "Study", floor = { "wood_walnut", "wood" }, paint = { "paint_cream" } },
        { 0, 7, 2, 10, 4, "Powder room", floor = { "tile_white", "tile" }, paint = { "paint_seafoam" } },
        { 1, 9, 5, 10, 10, "Landing", floor = { "carpet_grey", "carpet" }, paint = { "paint_cream" } },
        { 1, 7, 2, 10, 4, "Bathroom", floor = { "marble_white", "tile" }, paint = { "paint_seafoam" } },
        { 1, 11, 2, 14, 6, "Main bedroom", floor = { "carpet_grey", "carpet" }, paint = { "paint_cream" } },
        { 1, 3, 5, 8, 10, "Second bedroom", floor = { "carpet_blue", "carpet" }, paint = { "paint_cream" } },
        { 1, 11, 7, 14, 10, "Third bedroom", floor = { "carpet_green", "carpet" }, paint = { "paint_cream" } },
        { 1, 3, 2, 6, 4, "Dressing room", floor = { "wood_walnut", "wood" }, paint = { "paint_cream" } },
    },
    doors = {
        { 0, "x:10:11", front = true }, { 0, "x:10:5" }, { 0, "x:5:5" }, { 0, "y:11:5" }, { 0, "y:15:4" },
        { 1, "x:10:5" }, { 1, "y:11:6" }, { 1, "y:9:9" }, { 1, "y:11:9" }, { 1, "x:4:5" }, { 1, "x:10:11" },
    },
    arches = { { 0, "y:9:9" }, { 0, "y:11:9" } },
    windows = {
        { 0, "x:4:11" }, { 0, "x:6:11" }, { 0, "y:3:7" }, { 0, "x:4:2" }, { 0, "x:12:11" }, { 0, "x:13:11" }, { 0, "y:15:8" },
        { 0, "x:12:2" }, { 0, "x:8:2" },
        { 1, "x:4:11" }, { 1, "x:6:11" }, { 1, "y:3:7" }, { 1, "x:4:2" }, { 1, "x:12:2" }, { 1, "y:15:3" }, { 1, "y:15:5" },
        { 1, "x:12:11" }, { 1, "x:13:11" }, { 1, "y:15:9" }, { 1, "x:8:2" },
    },
    stairs = { { 9, 6, 0 } },
    outdoor = {
        { 0, 8, 11, 11, 11, { "deck_ash", "deck", "wood" } },
        { 0, 10, 12, 10, 15, { "path_concrete", "path" } },
        { 0, 15, 2, 19, 9, { "deck_ash", "deck", "wood" } },
        { 1, 9, 11, 10, 11, { "deck_ash", "deck", "wood" } },
    },
    pool = { 16, 3, 18, 8, 2 },
    fence = { back = true, west = { 0, 9 }, east = { 0, 9 } },
    mailbox = { 9, 15, 2 },
    items = {
        { "fridge", 0, 11, 2, 0 }, { "counter", 0, 12, 2, 0 }, { "stove", 0, 13, 2, 0 }, { "ksink", 0, 14, 2, 0 },
        { "dishwasher", 0, 14, 3, 1 }, { "coffee", 0, 12, 5, 0 }, { "bin", 0, 14, 6, 1 }, { "microwave", 0, 13, 5, 0 },
        { "dining", 0, 13, 9, 0, chairs = 4 }, { "smoke_alarm", 0, 11, 7, 3 },
        { "tv", 0, 3, 7, 3 }, { "sofa", 0, 5, 7, 1 }, { "armchair", 0, 5, 9, 1 }, { "lamp", 0, 3, 5, 0 },
        { "plant", 0, 8, 5, 1 }, { "piano", 0, 7, 10, 2 }, { "painting", 0, 3, 10, 3 }, { "rug", 0, 4, 10, 0 },
        { "desk", 0, 4, 2, 0 }, { "chair", 0, 4, 3, 2 }, { "computer", 0, 5, 2, 0 }, { "bookshelf", 0, 6, 2, 0 }, { "lamp", 0, 3, 2, 0 },
        { "toilet", 0, 7, 2, 0 }, { "basin", 0, 8, 2, 0 }, { "phone", 0, 10, 10, 1 },
        -- upstairs
        { "bed2", 1, 12, 3, 0 }, { "bed", 1, 14, 3, 0, pairWith = -1 }, { "dresser", 1, 11, 2, 0 }, { "lamp", 1, 14, 6, 1 },
        { "painting", 1, 11, 5, 3, n = 2 },
        { "toilet", 1, 7, 2, 0 }, { "basin", 1, 8, 2, 0 }, { "bath", 1, 9, 2, 0 }, { "shower", 1, 10, 2, 0 },
        { "bed", 1, 4, 6, 0 }, { "desk", 1, 7, 6, 1 }, { "lamp", 1, 3, 10, 0 }, { "exercise", 1, 6, 10, 2 },
        { "bed", 1, 13, 8, 0 }, { "lamp", 1, 14, 10, 1 }, { "bookshelf", 1, 12, 10, 2 },
        { "dresser", 1, 3, 2, 0 }, { "mirror", 1, 5, 2, 0 }, { "smoke_alarm", 1, 10, 8, 1 },
        { "outdoor_seat", 1, 9, 11, 0 },
        -- garden and pool
        { "outdoor_seat", 0, 15, 9, 2 }, { "outdoor_seat", 0, 19, 9, 2 }, { "lamp_out", 0, 15, 2, 0 },
        { "tree", 0, 1, 13, 0 }, { "tree", 0, 18, 13, 0 }, { "tree", 0, 1, 1, 0 }, { "tree", 0, 12, 0, 0 },
        { "shrub", 0, 7, 13, 0 }, { "shrub", 0, 13, 13, 0 }, { "flowers", 0, 8, 12, 0 }, { "flowers", 0, 12, 12, 0 },
        { "lamp_out", 0, 9, 14, 0 }, { "bin_out", 0, 16, 11, 0 },
    },
    spawn = { { 6, 8, 0 }, { 10, 9, 0 } },
}

---------------------------------------------------------------------------
-- Empty buildable parcels (land only; a few trees and a curbside mailbox).
---------------------------------------------------------------------------
B.parcel_small = {
    name = "Juniper Lane parcel", w = 12, h = 10, land = 4500, empty = true,
    desc = "A small flat parcel with room for a starter home and one ambitious hedge.",
    entry = { 6, 9 }, mailbox = { 5, 9, 2 },
    items = { { "tree", 0, 1, 1, 0 }, { "tree", 0, 10, 2, 0 } },
}
B.parcel_medium = {
    name = "Juniper Lane corner parcel", w = 16, h = 13, land = 8500, empty = true,
    desc = "A medium parcel with an old oak at the back and a view of the crescent.",
    entry = { 8, 12 }, mailbox = { 7, 12, 2 },
    items = { { "tree", 0, 2, 1, 0 }, { "tree", 0, 13, 2, 0 }, { "shrub", 0, 1, 11, 0 } },
}
B.parcel_large = {
    name = "Alder Row estate parcel", w = 22, h = 18, land = 13500, empty = true,
    desc = "A generous parcel for a big house, a bigger garden or a truly unwise pool.",
    entry = { 11, 17 }, mailbox = { 10, 17, 2 },
    items = { { "tree", 0, 2, 2, 0 }, { "tree", 0, 18, 1, 0 }, { "tree", 0, 20, 12, 0 }, { "shrub", 0, 1, 16, 0 } },
}

---------------------------------------------------------------------------
-- Placeholder community venues (only when SS.Venues.BuildLot is missing). Marked
-- lot.placeholder = true everywhere they appear; distinct names, shapes and interiors.
---------------------------------------------------------------------------
B.venue_cafe = {
    name = "The Toasted Almond", w = 18, h = 14, land = 12000, venue = "cafe", placeholder = true,
    desc = "Placeholder cafe layout: a dining room, a kitchen and a patio.",
    entry = { 8, 13 }, roof = { style = "gable", material = "clay", color = "terracotta" }, ext = { "brick_red", "paint_cream" },
    rooms = {
        { 0, 3, 5, 14, 9, "Dining room", floor = { "tile_check", "tile" }, paint = { "paint_cream" } },
        { 0, 3, 2, 10, 4, "Kitchen", floor = { "tile_white", "tile" }, paint = { "paint_cream" } },
        { 0, 11, 2, 14, 4, "Restroom", floor = { "tile_white", "tile" }, paint = { "paint_seafoam" } },
    },
    doors = { { 0, "x:8:10", front = true }, { 0, "x:6:5" }, { 0, "x:12:5" } },
    windows = { { 0, "x:5:10" }, { 0, "x:11:10" }, { 0, "x:13:10" }, { 0, "y:3:7" }, { 0, "y:15:7" }, { 0, "x:4:2" } },
    outdoor = { { 0, 3, 10, 14, 11, { "deck", "wood" } }, { 0, 8, 12, 8, 13, { "path" } } },
    items = {
        { "fridge", 0, 3, 2, 0 }, { "counter", 0, 4, 2, 0 }, { "stove", 0, 5, 2, 0 }, { "stove", 0, 7, 2, 0, n = 2 },
        { "counter", 0, 8, 2, 0 }, { "ksink", 0, 9, 2, 0 }, { "bin", 0, 10, 4, 1 },
        { "toilet", 0, 11, 2, 0 }, { "basin", 0, 13, 2, 0 },
        { "podium", 0, 9, 9, 2 }, { "register", 0, 5, 6, 0 },
        { "dining", 0, 11, 6, 0, chairs = 2 }, { "dining", 0, 13, 8, 0, chairs = 2 }, { "dining", 0, 4, 8, 0, chairs = 2 },
        { "dining", 0, 7, 7, 0, chairs = 2 },
        { "dining", 0, 4, 10, 0, chairs = 2 }, { "dining", 0, 12, 10, 0, chairs = 2 },
        { "plant", 0, 3, 9, 0 }, { "plant", 0, 14, 5, 1 }, { "lamp", 0, 3, 5, 1 },
    },
}
B.venue_shops = {
    name = "Cobbler's Yard", w = 26, h = 20, land = 16000, venue = "shops", placeholder = true,
    desc = "Placeholder shopping courtyard: four small shops around a paved yard.",
    entry = { 13, 19 }, roof = { style = "gable", material = "clay", color = "brick" }, ext = { "brick_red", "paint_cream" },
    rooms = {
        { 0, 2, 2, 7, 7, "Clothing", floor = { "wood" }, paint = { "paint_cream" } },
        { 0, 10, 2, 15, 7, "Gifts and flowers", floor = { "tile" }, paint = { "paint_seafoam" } },
        { 0, 18, 2, 23, 7, "Books and magazines", floor = { "carpet" }, paint = { "paint_cream" } },
        { 0, 2, 10, 7, 15, "Home goods", floor = { "wood" }, paint = { "paint_cream" } },
        { 0, 19, 10, 23, 13, "Restrooms", floor = { "tile" }, paint = { "paint_seafoam" } },
    },
    doors = { { 0, "x:5:8" }, { 0, "x:12:8" }, { 0, "x:21:8" }, { 0, "y:8:12" }, { 0, "y:19:12" } },
    windows = { { 0, "x:3:8" }, { 0, "x:14:8" }, { 0, "x:19:8" }, { 0, "y:8:14" }, { 0, "x:4:2" }, { 0, "x:12:2" }, { 0, "x:20:2" } },
    outdoor = { { 0, 9, 9, 17, 17, { "path_stone", "path" } }, { 0, 13, 18, 13, 19, { "path" } }, { 0, 2, 8, 23, 8, { "path" } } },
    items = {
        { "register", 0, 6, 3, 0 }, { "display", 0, 3, 5, 0 }, { "display", 0, 5, 5, 0, n = 2 }, { "mirror", 0, 2, 2, 0 },
        { "register", 0, 14, 3, 0 }, { "display", 0, 11, 5, 0, n = 3 }, { "plant", 0, 13, 5, 0 }, { "flowers", 0, 15, 6, 1 },
        { "register", 0, 22, 3, 0 }, { "bookshelf", 0, 19, 2, 0 }, { "display", 0, 19, 5, 0, n = 4 }, { "chair", 0, 23, 6, 1 },
        { "register", 0, 3, 11, 0 }, { "display", 0, 5, 13, 0 }, { "lamp", 0, 2, 15, 0 },
        { "toilet", 0, 20, 10, 0 }, { "basin", 0, 22, 10, 0 },
        { "outdoor_seat", 0, 10, 14, 0 }, { "outdoor_seat", 0, 16, 14, 0 }, { "fountain", 0, 13, 13, 0 },
        { "plant", 0, 9, 9, 0 }, { "plant", 0, 17, 9, 0 }, { "lamp_out", 0, 9, 17, 0 }, { "lamp_out", 0, 17, 17, 0 },
        { "tree", 0, 1, 18, 0 }, { "tree", 0, 24, 18, 0 },
    },
}
B.venue_park = {
    name = "Linden Green", w = 30, h = 22, land = 0, venue = "park", placeholder = true,
    desc = "Placeholder park: lawns, paths, benches, picnic tables and a restroom block.",
    entry = { 15, 21 }, roof = { style = "flat", material = "metal", color = "moss" }, ext = { "stone_grey", "paint_cream" },
    rooms = { { 0, 2, 2, 6, 5, "Restroom block", floor = { "tile" }, paint = { "paint_seafoam" } } },
    doors = { { 0, "x:4:6" } },
    windows = { { 0, "y:7:3" } },
    outdoor = { { 0, 15, 0, 15, 21, { "path_gravel", "path" } }, { 0, 0, 12, 29, 12, { "path_gravel", "path" } }, { 0, 4, 6, 4, 11, { "path" } } },
    items = {
        { "toilet", 0, 2, 2, 0 }, { "basin", 0, 5, 2, 0 },
        { "outdoor_seat", 0, 14, 5, 3 }, { "outdoor_seat", 0, 16, 8, 1 }, { "outdoor_seat", 0, 10, 13, 0 }, { "outdoor_seat", 0, 20, 11, 2 },
        { "dining", 0, 22, 5, 0, chairs = 2 }, { "dining", 0, 25, 8, 0, chairs = 2 }, { "grill", 0, 27, 3, 0 },
        { "chess", 0, 8, 16, 0 }, { "kid_play", 0, 22, 17, 0 }, { "fountain", 0, 18, 15, 0 },
        { "tree", 0, 1, 9, 0 }, { "tree", 0, 9, 2, 0 }, { "tree", 0, 11, 8, 0 }, { "tree", 0, 20, 2, 0 }, { "tree", 0, 27, 11, 0 },
        { "tree", 0, 5, 18, 0 }, { "tree", 0, 12, 19, 0 }, { "tree", 0, 26, 19, 0 }, { "tree", 0, 18, 9, 0 },
        { "flowers", 0, 14, 14, 0 }, { "flowers", 0, 16, 14, 0 }, { "lamp_out", 0, 14, 11, 0 }, { "lamp_out", 0, 16, 13, 0 },
        { "bin_out", 0, 14, 20, 0 },
    },
}
B.venue_club = {
    name = "The Velvet Metronome", w = 22, h = 16, land = 14000, venue = "club", placeholder = true,
    desc = "Placeholder social venue: a dance hall with a bar, games corner and back rooms.",
    entry = { 9, 15 }, roof = { style = "flat", material = "metal", color = "charcoal" }, ext = { "brick_red", "paint_cream" },
    rooms = {
        { 0, 2, 2, 15, 11, "Hall", floor = { "tile" }, paint = { "paint_cream" } },
        { 0, 16, 2, 19, 5, "Restrooms", floor = { "tile" }, paint = { "paint_seafoam" } },
        { 0, 16, 6, 19, 11, "Games room", floor = { "carpet" }, paint = { "paint_cream" } },
    },
    doors = { { 0, "x:9:12", front = true }, { 0, "y:16:4" }, { 0, "y:16:8" } },
    windows = { { 0, "x:4:12" }, { 0, "x:13:12" }, { 0, "y:2:6" }, { 0, "y:20:9" } },
    outdoor = { { 0, 9, 12, 9, 15, { "path" } }, { 0, 7, 12, 11, 12, { "path" } } },
    items = {
        { "bar", 0, 3, 2, 0 }, { "bar", 0, 4, 2, 0 }, { "bar", 0, 5, 2, 0 }, { "fridge", 0, 2, 2, 0 },
        { "dj", 0, 9, 2, 0 }, { "stereo", 0, 10, 2, 0 }, { "dance", 0, 9, 5, 0 },
        { "chair", 0, 3, 5, 2 }, { "chair", 0, 4, 5, 2 }, { "dining", 0, 13, 5, 0, chairs = 2 }, { "dining", 0, 13, 9, 0, chairs = 2 },
        { "sofa", 0, 2, 9, 3 }, { "lamp", 0, 15, 2, 1 }, { "lamp", 0, 2, 11, 0 }, { "plant", 0, 15, 11, 1 },
        { "toilet", 0, 16, 2, 0 }, { "basin", 0, 18, 2, 0 },
        { "pool_table", 0, 18, 8, 0 }, { "game", 0, 19, 11, 2 }, { "chair", 0, 16, 10, 0 },
        { "tree", 0, 1, 14, 0 }, { "tree", 0, 20, 14, 0 }, { "lamp_out", 0, 8, 13, 0 },
    },
}
