-- Buy-mode catalogue: Skill & Entertainment (brief §8.1: at least 14 designs).
-- Owner: catalogue module. Behaviour attaches by tag: bookshelf, chess, easel, piano, instrument,
-- exercise, arcade, pinball, pool_table, darts, dance, dj, workbench, telescope (household-core
-- activity, careers skill gain via SS.Skills) and game (household-core). rates.fun is fun per sim
-- hour where the activity reads it (games, instruments, telescope, dance, DJ); bookcases, easels,
-- the workbench and exercise machines carry none because their activities set their own fun.
-- quality.skill is requested (docs/requests/catalogue.md HC-3), not read yet. Multi-player objects
-- have a "player" slot group, one place per player.
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("skill")
local var = K.var

add("bookcase_basic", {
    name = "Cinderblock Bookshelf", sub = "books", style = "starter", material = "wood", price = 90, env = 1,
    rooms = { "study", "living", "bedroom" }, height = 1.4,
    desc = "Planks on concrete blocks, holding a dictionary, three thrillers and a cookbook with one page permanently stuck. Borrow a book to read for fun or to study a skill.",
    slots = { front = K.front(1, "read") }, tags = { "bookshelf" },
    quality = { skill = 0.8 },
    variants = var("grey:Grey Block:0.62,0.62,0.60", "painted:Painted Block:0.82,0.52,0.40", "pine:Pine Planks:0.82,0.64,0.40"),
})

add("bookcase_modern", {
    name = "Cube Grid Bookcase", sub = "books", style = "contemporary", material = "wood", price = 380, env = 3,
    rooms = { "study", "living" }, height = 1.8,
    desc = "Nine lacquered cubes for books, records and one ornament per cube arranged with suspicious precision. Books to read and study, plus two display cubes on top.",
    slots = { front = K.front(1, "read") }, tags = { "bookshelf" },
    surfaces = K.surf("shelf", 1.8, 1, 1, 2), quality = { skill = 1.1 },
    variants = var("white:Gloss White:0.96,0.96,0.96", "black:Black:0.14,0.14,0.15", "oak:Oak Veneer:0.72,0.54,0.34"),
})

add("bookcase_oak", {
    name = "Library Oak Bookcase", sub = "books", style = "traditional", material = "wood", price = 650, env = 5,
    rooms = { "study", "living" }, fp = K.rect(2, 1), height = 2.1,
    desc = "Floor-to-cornice oak shelving packed with atlases, encyclopaedias and a ladder rail for show. A serious lift to the room score; the books inside teach what any book teaches.",
    slots = { front = K.frontWide(2, "read") }, tags = { "bookshelf" },
    quality = { skill = 1.3 },
    variants = var("oak:Golden Oak:0.72,0.52,0.30", "walnut:Walnut:0.42,0.28,0.18", "green:Library Green:0.18,0.34,0.26"),
})

add("chess_table", {
    name = "Walnut Chess Table", sub = "games", style = "traditional", material = "wood", price = 500, env = 4,
    rooms = { "study", "living" }, fp = { { 0, -1 }, { 0, 0 }, { 0, 1 } }, height = 0.8,
    desc = "An inlaid board on a pedestal table with a stool at each end, for two players and one long silence. Sharpens logic; losing gracefully is sold separately.",
    rates = { fun = 22 },
    slots = {
        player1 = { cell = { 0, -1 }, approaches = { { -1, -1 }, { 1, -1 }, { 0, -2 } }, face = 0, on = true, group = "player", pose = "sit" },
        player2 = { cell = { 0, 1 }, approaches = { { -1, 1 }, { 1, 1 }, { 0, 2 } }, face = 2, on = true, group = "player", pose = "sit" },
    },
    tags = { "chess" }, quality = { skill = 1.2 },
    variants = var("walnut:Walnut & Maple:0.42,0.28,0.18", "marble:Marble:0.92,0.92,0.90", "ebony:Ebony & Ivory:0.14,0.12,0.11"),
})

add("table_boardgame", {
    name = "Folding Games Table", sub = "games", style = "starter", material = "metal", price = 150, env = 1,
    rooms = { "living", "kids", "dining" }, height = 0.7,
    desc = "A card table with a felt top and a drawer full of counters, dice and disputed rules. Up to four players; family game night fun for the price of a pizza.",
    rates = { fun = 24 },
    slots = {
        player1 = { approaches = { { 0, 1 } }, face = 2, group = "player", pose = "play" },
        player2 = { approaches = { { 0, -1 } }, face = 0, group = "player", pose = "play" },
        player3 = { approaches = { { 1, 0 } }, face = 1, group = "player", pose = "play" },
        player4 = { approaches = { { -1, 0 } }, face = 3, group = "player", pose = "play" },
    },
    tags = { "game" },
    variants = var("green:Green Felt:0.20,0.44,0.28", "red:Red Felt:0.62,0.16,0.16", "blue:Blue Felt:0.20,0.30,0.60"),
})

add("easel_basic", {
    name = "Folding Artist's Easel", sub = "creative", style = "starter", material = "wood", price = 250, env = 2,
    rooms = { "study", "living", "outdoor" }, height = 1.7,
    desc = "Three wooden legs, one canvas and unlimited potential for paintings of fruit. Practise creativity and paint pictures you can hang or sell.",
    slots = { front = K.front(1, "paint") }, tags = { "easel" },
    quality = { skill = 1.0 },
    variants = var("beech:Beech:0.86,0.72,0.52", "walnut:Walnut:0.42,0.28,0.18", "white:White:0.94,0.94,0.92"),
})

add("easel_studio", {
    name = "Studio Master Easel", sub = "creative", style = "eclectic", material = "wood", price = 1100, env = 4,
    rooms = { "study", "living" }, height = 2.0,
    desc = "A crank-adjusted oak studio easel with a paint tray, a lamp clamp and an air of genius. A handsome studio piece for the room; the paintings are only as good as the painter.",
    slots = { front = K.front(1, "paint") }, tags = { "easel" },
    quality = { skill = 1.5 },
    variants = var("oak:Oak:0.72,0.52,0.30", "black:Black:0.14,0.14,0.15", "red:Cinnabar:0.72,0.24,0.16"),
})

add("piano_upright", {
    name = "Parlour Upright Piano", sub = "creative", style = "traditional", material = "wood", price = 1800, env = 6,
    rooms = { "living" }, fp = { { 0, 0 }, { 0, 1 } }, height = 1.3,
    desc = "A walnut upright with its own bench and one key that sticks on humid days. Play for fun and creativity; the whole room hears practice, like it or not.",
    rates = { fun = 26 },
    slots = { player = { cell = { 0, 1 }, approaches = { { 1, 1 }, { -1, 1 }, { 0, 2 } }, face = 2, on = true, group = "player", pose = "sit" } },
    tags = { "piano", "instrument" }, quality = { skill = 1.2 },
    variants = var("walnut:Walnut:0.42,0.28,0.18", "black:Black Lacquer:0.10,0.10,0.11", "white:White Lacquer:0.96,0.96,0.96"),
})

add("piano_grand", {
    name = "Concert Baby Grand", sub = "creative", style = "traditional", material = "wood", price = 4800, env = 14,
    rooms = { "living" }, fp = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 }, { 0, 2 } }, height = 1.4,
    desc = "A gleaming baby grand whose lid alone could shelter a family of four. The most fun instrument in the catalogue, plus a huge room score.",
    rates = { fun = 34 },
    slots = { player = { cell = { 0, 2 }, approaches = { { -1, 2 }, { 1, 2 }, { 0, 3 } }, face = 2, on = true, group = "player", pose = "sit" } },
    tags = { "piano", "instrument" }, quality = { skill = 1.6 },
    variants = var("black:Concert Black:0.08,0.08,0.09", "white:Ivory White:0.96,0.94,0.88", "rosewood:Rosewood:0.44,0.18,0.12"),
})

add("guitar_stand", {
    name = "Acoustic Guitar on Stand", sub = "creative", style = "eclectic", material = "wood", price = 300, env = 2,
    rooms = { "living", "bedroom" }, height = 1.1,
    desc = "A six-string on a folding stand, propped in the corner so it looks like someone plays it. Someone could: practise for fun and creativity.",
    rates = { fun = 20 }, slots = { front = K.front(1, "play") }, tags = { "instrument" },
    quality = { skill = 1.0 },
    variants = var("natural:Natural Spruce:0.90,0.76,0.52", "sunburst:Sunburst:0.64,0.30,0.14", "black:Black:0.12,0.12,0.12"),
})

add("exercise_bench", {
    name = "Iron Pump Weight Bench", sub = "fitness", style = "starter", material = "metal", price = 450, env = 0,
    rooms = { "living", "study", "outdoor" }, fp = { { 0, 0 }, { 0, 1 } }, height = 1.2,
    desc = "A padded bench, a bar and plates painted the colour of determination. Builds body skill and sweat in equal measure; showers are strongly advised afterwards.",
    slots = { seat = { cell = { 0, 0 }, approaches = { { 1, 0 }, { -1, 0 }, { 1, 1 }, { -1, 1 } }, face = 0, on = true, pose = "exercise" } },
    tags = { "exercise" }, quality = { skill = 1.0, breakChance = 0.001, repairDifficulty = 1 },
    variants = var("black:Black & Chrome:0.14,0.14,0.15", "red:Red Vinyl:0.72,0.16,0.16", "blue:Blue Vinyl:0.20,0.30,0.60"),
})

add("exercise_treadmill", {
    name = "Stride-o-Matic Treadmill", sub = "fitness", style = "contemporary", material = "plastic", price = 350, env = 1,
    rooms = { "living", "study" }, fp = { { 0, 0 }, { 0, 1 } }, height = 1.4, powered = true,
    desc = "A motorised belt with a heart-rate readout that flatters no one. Cheaper than a weight bench and the same body-skill workout, though the motor breaks down more often.",
    slots = { run = { cell = { 0, 1 }, approaches = { { 1, 1 }, { -1, 1 }, { 0, 2 } }, face = 2, on = true, pose = "exercise" } },
    tags = { "exercise" }, quality = { skill = 1.4, breakChance = 0.004, repairDifficulty = 4 },
    variants = var("grey:Grey:0.56,0.58,0.60", "black:Black:0.14,0.14,0.15", "white:White:0.94,0.94,0.94"),
})

add("arcade_cabinet", {
    name = "Galaxy Barrage Arcade Cabinet", sub = "games", style = "eclectic", material = "wood", price = 1000, env = 3,
    rooms = { "living", "kids", "venue" }, height = 1.8, powered = true,
    desc = "An upright cabinet where pixel saucers descend in formation and high scores are guarded like heirlooms. Loud, bright, and more fun than most television.",
    rates = { fun = 38 }, slots = { front = K.front(1, "play") }, tags = { "arcade", "game" },
    quality = { breakChance = 0.006, repairDifficulty = 4 },
    variants = var("purple:Nebula Purple:0.40,0.20,0.56", "black:Black & Neon:0.12,0.12,0.14", "red:Red Alert:0.72,0.14,0.14"),
})

add("pinball", {
    name = "Tilt King Pinball Table", sub = "games", style = "eclectic", material = "wood", price = 1400, env = 4,
    rooms = { "living", "venue" }, fp = { { 0, 0 }, { 0, 1 } }, height = 1.8, powered = true,
    desc = "Bumpers, ramps and a backglass painted with a heroic mechanic fighting a volcano. Top fun for one player; it tilts, it rings, it occasionally needs a repair.",
    rates = { fun = 42 },
    slots = { front = { approaches = { { 0, 2 } }, face = 2, pose = "play" } },
    tags = { "pinball", "game" }, quality = { breakChance = 0.006, repairDifficulty = 5 },
    variants = var("volcano:Volcano:0.86,0.34,0.14", "space:Space Race:0.18,0.24,0.56", "circus:Circus:0.94,0.78,0.20"),
})

add("pool_table", {
    name = "Felt and Oak Pool Table", sub = "games", style = "traditional", material = "wood", price = 2200, env = 6,
    rooms = { "living", "venue" }, fp = K.rect(2, 1), height = 0.85,
    desc = "Green baize, oak rails and leather pockets that swallow balls with a satisfying thunk. Two players, big fun, and a little body skill for all the leaning.",
    rates = { fun = 36 },
    slots = {
        player1 = { approaches = { { -1, 0 }, { 0, 1 }, { 0, -1 } }, face = 3, group = "player", pose = "play" },
        player2 = { approaches = { { 2, 0 }, { 1, 1 }, { 1, -1 } }, face = 1, group = "player", pose = "play" },
    },
    tags = { "pool_table" }, quality = { skill = 1.1, capacity = 2 },
    variants = var("green:Green Baize:0.16,0.42,0.24", "red:Claret Baize:0.50,0.10,0.14", "blue:Blue Baize:0.14,0.28,0.56"),
})

add("dartboard", {
    name = "Pub Dartboard", sub = "games", style = "eclectic", material = "wood", price = 80, env = 1,
    rooms = { "living", "venue" }, mount = "wall", height = 1.8,
    desc = "A bristle board in a cabinet with a chalk scoreboard, for two players and a tape line two tiles out. Cheap, cheerful fun; keep the cat elsewhere.",
    rates = { fun = 20 },
    slots = {
        player1 = { approaches = { { 0, 2 } }, face = 2, group = "player", pose = "play" },
        player2 = { approaches = { { 1, 2 }, { -1, 2 } }, face = 2, group = "player", pose = "play" },
    },
    tags = { "darts" }, quality = { capacity = 2 },
    variants = var("classic:Classic:0.14,0.40,0.24", "oak:Oak Cabinet:0.72,0.52,0.30", "black:Black Cabinet:0.14,0.14,0.15"),
})

add("dance_floor", {
    name = "Light-Up Dance Floor", sub = "party", style = "eclectic", material = "glass", price = 1500, env = 5,
    rooms = { "living", "venue" }, fp = K.rect(2, 2), height = 0.1, noBlock = true, powered = true,
    desc = "Four cells of glass tiles that light up underfoot in time with the music. Room for four dancers; pair it with a stereo and the party finds its own feet.",
    rates = { fun = 30 },
    slots = {
        dancer1 = { cell = { 0, 0 }, approaches = { { 0, 0 } }, face = 0, on = true, group = "dancer", pose = "dance" },
        dancer2 = { cell = { 1, 0 }, approaches = { { 1, 0 } }, face = 0, on = true, group = "dancer", pose = "dance" },
        dancer3 = { cell = { 0, 1 }, approaches = { { 0, 1 } }, face = 0, on = true, group = "dancer", pose = "dance" },
        dancer4 = { cell = { 1, 1 }, approaches = { { 1, 1 } }, face = 0, on = true, group = "dancer", pose = "dance" },
    },
    tags = { "dance" }, quality = { capacity = 4, breakChance = 0.002, repairDifficulty = 3 },
    variants = var("rainbow:Rainbow:0.90,0.60,0.80", "blue:Ice Blue:0.60,0.80,0.96", "gold:Gold:0.96,0.82,0.40"),
})

add("dj_deck_home", {
    name = "Bedroom DJ Deck", sub = "party", style = "contemporary", material = "plastic", price = 900, env = 3,
    rooms = { "living", "bedroom" }, height = 1.1, powered = true,
    desc = "Two turntables and a mixer on a stand, for a resident who says 'drop' a lot. Loud, creative fun that doubles as party music.",
    rates = { fun = 30 }, slots = { front = K.front(1, "use") }, tags = { "dj" },
    noise = 6, quality = { skill = 1.2, breakChance = 0.003, repairDifficulty = 3 },
    variants = var("black:Black:0.14,0.14,0.15", "silver:Silver:0.78,0.80,0.82", "white:White:0.94,0.94,0.94"),
})

add("telescope", {
    name = "Stargazer Telescope", sub = "hobby", style = "garden", material = "metal", price = 600, env = 2,
    rooms = { "outdoor", "study" }, height = 1.6,
    desc = "A brass refractor on a tripod, aimed at the stars and occasionally at the neighbours' new conservatory. Practises logic by night; the stars only come out after dark.",
    rates = { fun = 18 }, slots = { front = K.front(1, "use") }, tags = { "telescope" },
    quality = { skill = 1.2 },
    variants = var("brass:Brass:0.84,0.68,0.34", "white:White:0.94,0.94,0.94", "navy:Navy:0.16,0.20,0.36"),
})

add("workbench", {
    name = "Tinkerer's Workbench", sub = "hobby", style = "starter", material = "wood", price = 400, env = 0,
    rooms = { "study", "outdoor" }, fp = K.rect(2, 1), height = 1.5,
    desc = "A scarred bench with a vice, a pegboard of tools and a coffee tin of unidentified screws. Practise mechanical skill here before trying it on the dishwasher.",
    slots = { front = K.frontWide(2, "repair") }, tags = { "workbench" },
    quality = { skill = 1.3 },
    variants = var("pine:Pine:0.82,0.64,0.40", "red:Red Steel:0.66,0.16,0.14", "grey:Grey Steel:0.52,0.54,0.56"),
})
