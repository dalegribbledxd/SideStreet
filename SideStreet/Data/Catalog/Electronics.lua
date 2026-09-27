-- Buy-mode catalogue: Electronics & Household Utilities (brief §8.1: at least 10 designs).
-- Owner: catalogue module. "watchtv" is listed on televisions (the viewer interaction reads the fun
-- rate). Other behaviour attaches by tag: tv/stereo/radio/computer/game/clock_alarm (household-core),
-- smoke_alarm/burglar_alarm (events), phone/mailbox/doorbell (visitors; mailbox bills: careers).
-- quality.range is the alarm coverage radius in cells for the events module's coverage rule.
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("electronics")
local var = K.var
local DESKTOP = { "desk", "table" }
local SMALL = { "table", "desk", "counter", "shelf", "end" }

add("tv_basic", { -- original 0.1.0 object
    name = "Monovision 19-Inch Television", sub = "tv", style = "starter", material = "plastic", price = 500, env = 2,
    rooms = { "living", "bedroom" }, height = 1.0, powered = true, viewer = true,
    desc = "Nineteen inches of news, cooking shows and advertisements for better televisions. Decent fun from any seat facing it within four tiles.",
    rates = { fun = 28 }, slots = { front2 = K.front(2, "idle") }, actions = { "watchtv" }, tags = { "tv" },
    quality = { breakChance = 0.004, repairDifficulty = 4 },
    variants = var("woodgrain:Woodgrain:0.54,0.38,0.24", "silver:Silver:0.78,0.80,0.82", "black:Black:0.14,0.14,0.15"),
})

add("tv_console", {
    name = "Walnut Console Television", sub = "tv", style = "traditional", material = "wood", price = 1200, env = 4,
    rooms = { "living" }, height = 1.1, powered = true, viewer = true,
    desc = "A big picture in a walnut cabinet with doors that close on the evening news when it gets too honest. Clearer, more fun viewing and fewer repairs than a portable set.",
    rates = { fun = 36 }, slots = { front2 = K.front(2, "idle") }, actions = { "watchtv" }, tags = { "tv" },
    quality = { breakChance = 0.0024, repairDifficulty = 4 },
    variants = var("walnut:Walnut:0.42,0.28,0.18", "teak:Teak:0.60,0.40,0.24", "white:White Lacquer:0.94,0.94,0.92"),
})

add("tv_widescreen", {
    name = "Panoramic 42-Inch Widescreen", sub = "tv", style = "contemporary", material = "plastic", price = 3500, env = 6,
    rooms = { "living" }, fp = K.rect(2, 1), height = 1.3, powered = true, viewer = true,
    desc = "A slim wide screen on a glass stand, so vivid the nature shows make residents check the room for bees. The most fun a television offers, and it seldom breaks.",
    rates = { fun = 46 }, slots = { front2 = { approaches = { { 0, 2 }, { 1, 2 } }, face = 2, pose = "idle" } }, actions = { "watchtv" }, tags = { "tv" },
    quality = { breakChance = 0.0012, repairDifficulty = 6 },
    variants = var("black:Piano Black:0.10,0.10,0.11", "silver:Silver:0.78,0.80,0.82", "walnut:Walnut Stand:0.42,0.28,0.18"),
})

add("radio_kitchen", {
    name = "Countertop Kitchen Radio", sub = "audio", style = "starter", material = "plastic", price = 75, env = 1,
    rooms = { "kitchen", "bedroom", "living" }, mount = "surface", fits = SMALL, height = 0.3, powered = true,
    desc = "Three stations, one speaker and a dial that always lands between two of them. Light fun while you cook; goes on any counter, table or shelf.",
    rates = { fun = 14 }, slots = { front = K.around("use") }, tags = { "radio" },
    noise = 3, quality = { breakChance = 0.004, repairDifficulty = 1 },
    variants = var("cream:Cream:0.94,0.90,0.80", "red:Red:0.72,0.16,0.16", "teal:Teal:0.16,0.50,0.50"),
})

add("stereo_boombox", {
    name = "Boombox Blaster", sub = "audio", style = "eclectic", material = "plastic", price = 180, env = 1,
    rooms = { "bedroom", "kids", "living" }, mount = "surface", fits = SMALL, height = 0.35, powered = true,
    desc = "Twin cassette decks, a bass button and a handle for carrying your opinions to the park. More fun than a radio and loud enough to disturb a sleeper in the next room.",
    rates = { fun = 22 }, slots = { front = K.around("use") }, tags = { "stereo" },
    noise = 5, quality = { breakChance = 0.004, repairDifficulty = 2 },
    variants = var("silver:Silver:0.78,0.80,0.82", "black:Black:0.14,0.14,0.15", "pink:Hot Pink:0.94,0.36,0.62"),
})

add("stereo_hifi", {
    name = "Tower Hi-Fi System", sub = "audio", style = "contemporary", material = "plastic", price = 1100, env = 3,
    rooms = { "living" }, height = 1.2, powered = true,
    desc = "A glass-fronted stack of amplifier, tuner and disc changer between two towering speakers. Room-filling music worth dancing to, loud enough to wake anyone asleep in the same room.",
    rates = { fun = 34 }, slots = { front = K.front(1, "use") }, tags = { "stereo", "dance" },
    noise = 6, quality = { breakChance = 0.0016, repairDifficulty = 4 },
    variants = var("black:Black Ash:0.16,0.16,0.17", "silver:Brushed Silver:0.78,0.80,0.82", "walnut:Walnut Speakers:0.42,0.28,0.18"),
})

add("stereo_jukebox", {
    name = "Bubble-Tube Jukebox", sub = "audio", style = "eclectic", material = "metal", price = 2400, env = 8,
    rooms = { "living", "venue" }, height = 1.6, powered = true,
    desc = "Chrome arches, glowing bubble tubes and a hundred records chosen by someone with excellent, stubborn taste. The best party music in the catalogue and a centrepiece besides.",
    rates = { fun = 40 }, slots = { front = K.front(1, "use") }, tags = { "stereo", "dance" },
    noise = 6, quality = { breakChance = 0.0024, repairDifficulty = 5 },
    variants = var("cherry:Cherry & Chrome:0.74,0.14,0.16", "mint:Mint & Chrome:0.62,0.86,0.74", "walnut:Walnut & Gold:0.42,0.28,0.18"),
})

add("computer_basic", {
    name = "Beige Box Home Computer", sub = "computer", style = "starter", material = "plastic", price = 900, env = 1,
    rooms = { "study", "bedroom", "kids" }, mount = "surface", fits = DESKTOP, height = 0.55, powered = true,
    desc = "A tower, a chunky monitor and a modem that screams like a kettle at a funeral. Good for games, job hunting and study; best with a chair facing the desk.",
    rates = { fun = 24 }, slots = { front = K.front(1, "type") }, tags = { "computer", "game" },
    quality = { skill = 1.0, breakChance = 0.006, repairDifficulty = 4 },
    variants = var("beige:Beige:0.86,0.82,0.72", "grey:Grey:0.62,0.62,0.62", "black:Black:0.14,0.14,0.15"),
})

add("computer_premium", {
    name = "Nebula Pro Workstation", sub = "computer", style = "contemporary", material = "plastic", price = 2400, env = 3,
    rooms = { "study" }, mount = "surface", fits = DESKTOP, height = 0.6, powered = true,
    desc = "A translucent tower with a flat monitor and fans quieter than your conscience. Far more fun to use, and it breaks down a third as often.",
    rates = { fun = 40 }, slots = { front = K.front(1, "type") }, tags = { "computer", "game" },
    quality = { skill = 1.4, breakChance = 0.002, repairDifficulty = 6 },
    variants = var("ice:Ice Blue:0.70,0.84,0.92", "graphite:Graphite:0.30,0.31,0.33", "tangerine:Tangerine:0.95,0.56,0.20"),
})

add("phone_wall", {
    name = "Wall Telephone", sub = "phone", style = "starter", material = "plastic", price = 50, env = 0,
    rooms = { "kitchen", "living" }, mount = "wall", height = 1.4,
    desc = "A coiled cord long enough to reach the fridge, which is where most calls end up. Call friends, services, taxis and invitations; rings when someone wants you.",
    slots = { front = K.under("phone") }, tags = { "phone" },
    variants = var("cream:Cream:0.94,0.90,0.80", "red:Red:0.72,0.16,0.16", "avocado:Avocado:0.56,0.62,0.30"),
})

add("phone_desk", {
    name = "Rotary Desk Phone", sub = "phone", style = "traditional", material = "plastic", price = 85, env = 1,
    rooms = { "study", "living", "bedroom" }, mount = "surface", fits = SMALL, height = 0.2,
    desc = "A heavy handset and a dial that makes you think twice before calling anyone with a nine in their number. Same calls as a wall phone, far more gravitas.",
    slots = { front = K.around("phone") }, tags = { "phone" },
    variants = var("black:Black Bakelite:0.10,0.10,0.10", "ivory:Ivory:0.96,0.92,0.82", "green:Racing Green:0.12,0.30,0.20"),
})

add("clock_alarm", {
    name = "Rooster-Call Alarm Clock", sub = "safety", style = "starter", material = "metal", price = 30, env = 0,
    rooms = { "bedroom" }, mount = "surface", fits = SMALL, height = 0.15,
    desc = "Twin brass bells and a hammer that does not negotiate. Set it by the bed and sleepers wake in time for work or school instead of in time for the apology.",
    slots = { front = K.around("use") }, tags = { "clock_alarm" },
    variants = var("red:Red:0.72,0.16,0.16", "brass:Brass:0.84,0.68,0.34", "blue:Blue:0.28,0.42,0.72"),
})

add("smoke_alarm", {
    name = "Watchful Smoke Detector", sub = "safety", style = "starter", material = "plastic", price = 50, env = 0,
    rooms = { "kitchen", "living", "bedroom", "study", "dining" }, mount = "ceiling", height = 0.1,
    desc = "A white disc that stays silent for years, then shrieks at burnt toast and real fires with equal passion. Detects fire in its room and calls the fire service.",
    tags = { "smoke_alarm" }, quality = { range = 6 },
    variants = var("white:White:0.97,0.97,0.97", "ivory:Ivory:0.96,0.92,0.82"),
})

add("burglar_alarm", {
    name = "Night Owl Burglar Alarm", sub = "safety", style = "contemporary", material = "plastic", price = 250, env = 0,
    rooms = { "living", "kitchen" }, mount = "wall", height = 1.6, powered = true,
    desc = "A keypad, a blinking eye and a siren that makes intruders reconsider their career. Sounds when a burglar enters and summons the police.",
    slots = { front = K.under("use") }, tags = { "burglar_alarm" }, quality = { range = 10 },
    variants = var("white:White:0.97,0.97,0.97", "grey:Grey:0.62,0.62,0.62"),
})

add("fire_extinguisher", {
    name = "Red Canister Fire Extinguisher", sub = "safety", style = "starter", material = "metal", price = 80, env = 0,
    rooms = { "kitchen", "living", "study", "dining", "bedroom" }, mount = "wall", height = 1.0,
    desc = "A red cylinder on a bracket, with a pin, a lever and instructions nobody reads until they must. With one on the lot, residents fight small fires twice as fast and are braver about trying.",
    slots = { front = K.under("use") }, tags = { "extinguisher" },
    variants = var("red:Signal Red:0.80,0.12,0.10", "steel:Brushed Steel:0.78,0.79,0.80"),
})

add("doorbell_chime", {
    name = "Ding-Dong Door Chime", sub = "phone", style = "starter", material = "wood", price = 40, env = 0,
    rooms = { "living", "outdoor" }, mount = "wall", height = 1.3,
    desc = "A brass button by the door and a two-note chime that carries to the back bedroom. Visitors press it and wait to be greeted instead of wandering in.",
    slots = { front = K.under("use") }, tags = { "doorbell" },
    variants = var("brass:Brass:0.84,0.68,0.34", "chrome:Chrome:0.84,0.86,0.88", "black:Black:0.14,0.14,0.15"),
})

add("mailbox_basic", {
    name = "Standard Curbside Mailbox", sub = "phone", style = "starter", material = "metal", price = 50, env = 0,
    rooms = { "outdoor" }, height = 1.2, outdoor = true, groundOnly = true,
    desc = "A tin box on a post with a flag that goes up when there is post. Bills arrive here, along with catalogues for things you already bought.",
    slots = { front = K.front(1, "use") }, tags = { "mailbox" },
    variants = var("black:Black:0.14,0.14,0.15", "red:Red:0.72,0.16,0.16", "green:Green:0.24,0.44,0.26"),
})

add("mailbox_brick", {
    name = "Brick Pillar Mailbox", sub = "phone", style = "traditional", material = "stone", price = 300, env = 3,
    rooms = { "outdoor" }, height = 1.3, outdoor = true, groundOnly = true,
    desc = "A mailbox built into a proper brick pillar with a lamp on top, so the bills arrive looking dignified. Same post, much better kerb appeal.",
    slots = { front = K.front(1, "use") }, tags = { "mailbox" },
    variants = var("red:Red Brick:0.66,0.30,0.22", "yellow:Yellow Brick:0.86,0.74,0.46", "white:Painted Brick:0.92,0.90,0.86"),
})
