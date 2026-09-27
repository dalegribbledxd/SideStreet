-- Buy-mode catalogue: Community & Service (brief §8.1: at least 10 designs).
-- Owner: catalogue module. community = true: shown and placeable only while editing a community
-- lot (lot.kind == "community") or in sandbox. Behaviour attaches by tag from the outings module
-- (register, display_*, changing_booth, podium, waiter_station, cafe_kitchen, cafe_table, dj_booth,
-- bar, restroom); the public bench is an ordinary household-core seat. Slot names and groups match
-- Data/Venues.lua VD.furnish on the outings branch so SS.Venues.BuildLot can use these designs
-- instead of its system fallbacks:
--   register: customer, line (group), staff | displays: browse (group) | changing_booth: booth
--   podium: guest (group), staff | waiter_station: staff, pickup (group, public) | cafe_kitchen: cook, pass
--   dj_booth: staff, request | bar: staff, patron (group) | restroom: seat (+ "toilet" action)
-- staff = true marks slots only venue staff use; staffOnly = true objects are never offered to patrons.
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("community")
local var = K.var
local VENUE = { "venue" }
local function browse(w)
    local s = {}
    for x = 0, (w or 1) - 1 do s["browse" .. (x + 1)] = { approaches = { { x, 1 } }, face = 2, group = "browse", pose = "use" } end
    return s
end

---------------------------------------------------------------------------------------------------
-- Shops: registers and product displays
---------------------------------------------------------------------------------------------------
add("register_basic", {
    name = "Corner Shop Till Counter", sub = "shop", style = "starter", material = "wood", price = 900, env = 1,
    rooms = VENUE, height = 1.25, community = true, powered = true,
    desc = "A wooden counter, a cash drawer that sticks in wet weather and a bell customers ring exactly once. The shopkeeper serves one customer while two more queue.",
    slots = {
        customer = { approaches = { { 0, 1 } }, face = 2, pose = "talk" },
        line1 = { approaches = { { 0, 2 } }, face = 2, group = "line", pose = "idle" },
        line2 = { approaches = { { 1, 2 } }, face = 2, group = "line", pose = "idle" },
        staff = { approaches = { { 0, -1 } }, face = 0, staff = true, pose = "use" },
    },
    tags = { "register" }, surfaces = K.surf("counter", 0.95, 1, 1, 1),
    quality = { speed = 1.0 },
    variants = var("oak:Oak:0.72,0.52,0.30", "green:Shop Green:0.24,0.44,0.34", "red:Postbox Red:0.74,0.14,0.14"),
})

add("register_deluxe", {
    name = "Glass-Top Checkout Island", sub = "shop", style = "contemporary", material = "wood", price = 2200, env = 4,
    rooms = VENUE, fp = K.rect(2, 1), height = 1.3, community = true, powered = true,
    desc = "A backlit glass counter with a card reader, a gift-wrap station and a till that beeps in a pleasing key. Serves one customer while three more queue.",
    slots = {
        customer = { approaches = { { 0, 1 } }, face = 2, pose = "talk" },
        line1 = { approaches = { { 0, 2 } }, face = 2, group = "line", pose = "idle" },
        line2 = { approaches = { { 1, 2 } }, face = 2, group = "line", pose = "idle" },
        line3 = { approaches = { { 1, 1 } }, face = 2, group = "line", pose = "idle" },
        staff = { approaches = { { 0, -1 }, { 1, -1 } }, face = 0, staff = true, pose = "use" },
    },
    tags = { "register" }, surfaces = K.surf("counter", 1.0, 2, 1, 1),
    quality = { speed = 1.5, breakChance = 0.001, repairDifficulty = 4 },
    variants = var("white:White & Glass:0.96,0.96,0.96", "black:Black & Glass:0.14,0.14,0.15", "walnut:Walnut & Glass:0.42,0.28,0.18"),
})

add("rack_clothing", {
    name = "Chrome Clothing Rail", sub = "clothing", style = "starter", material = "fabric", price = 300, env = 2,
    rooms = VENUE, fp = K.rect(2, 1), height = 1.6, community = true,
    desc = "Two tiles of rail loaded with hangers, sorted by size in theory and by chaos in practice. Customers browse outfits here before trying them on.",
    slots = browse(2), tags = { "display_clothing" }, startState = { full = true },
    variants = var("chrome:Chrome:0.84,0.86,0.88", "brass:Brass:0.84,0.68,0.34", "black:Black:0.14,0.14,0.15"),
})

add("mannequin_display", {
    name = "Mannequin Trio Display", sub = "clothing", style = "contemporary", material = "fabric", price = 650, env = 6,
    rooms = VENUE, fp = K.rect(2, 1), height = 1.9, community = true,
    desc = "Three faceless mannequins striking poses of great confidence in this season's outfits. Customers browse clothing here, and it lifts the shop's room score far above a rail.",
    slots = browse(2), tags = { "display_clothing" }, startState = { full = true },
    variants = var("white:Gloss White:0.97,0.97,0.97", "wood:Wooden Artist:0.82,0.64,0.40", "black:Matte Black:0.14,0.14,0.15"),
})

add("changing_booth", {
    name = "Curtained Changing Booth", sub = "clothing", style = "traditional", material = "wood", price = 500, env = 2,
    rooms = VENUE, height = 2.1, community = true, privacy = true,
    desc = "A velvet-curtained cubicle with a hook, a stool and a mirror tilted to be generous. One shopper tries outfits on here in private.",
    slots = { booth = { approaches = { { 0, 1 } }, face = 0, on = true, pose = "idle" } },
    tags = { "changing_booth" },
    variants = var("crimson:Crimson Velvet:0.62,0.12,0.16", "navy:Navy Velvet:0.16,0.20,0.40", "linen:Linen:0.94,0.90,0.80"),
})

add("stand_flowers", {
    name = "Flower Cart Gift Stand", sub = "shop", style = "garden", material = "wood", price = 400, env = 7,
    rooms = VENUE, fp = K.rect(2, 1), height = 1.5, community = true,
    desc = "A painted barrow of buckets, bouquets and ribboned boxes, the natural habitat of the forgotten anniversary. Customers browse gifts and flowers here.",
    slots = browse(2), tags = { "display_gift" }, startState = { full = true },
    variants = var("green:Market Green:0.30,0.52,0.36", "blue:Cornflower:0.40,0.52,0.80", "cream:Cream:0.94,0.90,0.80"),
})

add("rack_magazines", {
    name = "Spinner Book and Magazine Rack", sub = "shop", style = "starter", material = "chrome", price = 350, env = 2,
    rooms = VENUE, height = 1.7, community = true,
    desc = "A squeaky wire carousel of paperbacks and glossy weeklies that everybody spins and nobody oils. Two customers browse books and magazines at once.",
    slots = { browse1 = { approaches = { { 0, 1 } }, face = 2, group = "browse", pose = "use" },
        browse2 = { approaches = { { 1, 0 }, { -1, 0 } }, face = 3, group = "browse", pose = "use" } },
    tags = { "display_books" }, startState = { full = true },
    variants = var("chrome:Chrome:0.84,0.86,0.88", "red:Red:0.74,0.14,0.14", "white:White:0.96,0.96,0.95"),
})

add("shelf_decor_display", {
    name = "Stepped Home-Goods Display", sub = "shop", style = "eclectic", material = "wood", price = 450, env = 5,
    rooms = VENUE, fp = K.rect(2, 1), height = 1.8, community = true,
    desc = "Tiered shelves of lamps, vases and cushions arranged to suggest a better life is only one purchase away. Customers browse home decor to take home.",
    slots = browse(2), tags = { "display_decor" }, startState = { full = true },
    surfaces = { { cell = { 0, 0 }, z = 1.2, kind = "shelf", slots = 2, off = { 0, -0.23 } }, { cell = { 1, 0 }, z = 1.2, kind = "shelf", slots = 2, off = { 0, -0.23 } } },
    variants = var("birch:Birch:0.90,0.82,0.66", "painted:Painted Teal:0.20,0.54,0.56", "black:Black:0.14,0.14,0.15"),
})

---------------------------------------------------------------------------------------------------
-- Restaurant
---------------------------------------------------------------------------------------------------
add("podium_host", {
    name = "Maitre d' Host Podium", sub = "dining", style = "traditional", material = "wood", price = 600, env = 3,
    rooms = VENUE, height = 1.2, community = true,
    desc = "A walnut lectern with a brass lamp, the reservation book and a pen chained on for everyone's safety. Guests wait here to be greeted and seated.",
    slots = {
        guest1 = { approaches = { { 0, 1 } }, face = 2, group = "guest", pose = "idle" },
        guest2 = { approaches = { { -1, 1 } }, face = 2, group = "guest", pose = "idle" },
        guest3 = { approaches = { { 1, 1 } }, face = 2, group = "guest", pose = "idle" },
        staff = { approaches = { { 0, -1 } }, face = 0, staff = true, pose = "talk" },
    },
    tags = { "podium" },
    variants = var("walnut:Walnut:0.42,0.28,0.18", "black:Black Lacquer:0.12,0.12,0.13", "oak:Oak:0.72,0.52,0.30"),
})

add("waiter_station", {
    name = "Waiter Service Station", sub = "dining", style = "contemporary", material = "metal", price = 700, env = 0,
    rooms = VENUE, height = 1.0, community = true,
    desc = "Order pads, polished cutlery, folded napkins and a hatch where plates appear as if by magic. Waiters work from behind it; customers collect their food at the front when nobody can reach their table.",
    -- not staffOnly: it stands in the dining room, and a staffOnly design closes its room to customers
    -- (outings request CA-1). Staff use the back; the two pickup places at the front are public.
    slots = { staff = { approaches = { { 0, -1 } }, face = 0, staff = true, pose = "use" },
        pickup1 = { approaches = { { 0, 1 } }, face = 2, group = "pickup", pose = "use" },
        pickup2 = { approaches = { { 1, 0 } }, face = 1, group = "pickup", pose = "use" } },
    tags = { "waiter_station" }, surfaces = K.surf("counter", 1.0, 1, 1, 2),
    quality = { speed = 1.2 },
    variants = var("steel:Steel:0.80,0.82,0.84", "oak:Oak:0.72,0.52,0.30", "black:Black:0.14,0.14,0.15"),
})

add("cafe_kitchen_line", {
    name = "Commercial Range and Prep Line", sub = "dining", style = "contemporary", material = "metal", price = 3000, env = 0,
    rooms = VENUE, fp = K.rect(2, 1), height = 0.95, community = true, staffOnly = true, powered = true,
    desc = "Six burners, a flat-top grill and a ticket rail that is never empty at lunchtime. Only staff cook here; the meals are as good as the cook.",
    slots = { cook = { approaches = { { 0, 1 } }, face = 2, staff = true, pose = "cook" },
        pass = { approaches = { { 1, 1 } }, face = 2, staff = true, pose = "use" } },
    tags = { "cafe_kitchen" }, startState = { on = false },
    quality = { speed = 1.4, breakChance = 0.002, repairDifficulty = 5 },
    variants = var("steel:Stainless:0.80,0.82,0.84", "black:Black & Brass:0.14,0.14,0.15", "red:Red Enamel:0.74,0.14,0.14"),
})

add("cafe_table_two", {
    name = "Marble Bistro Table for Two", sub = "dining", style = "traditional", material = "metal", price = 250, env = 3,
    rooms = VENUE, height = 0.75, community = true,
    desc = "A round marble top on a wrought-iron base, just wide enough for two plates and one shared dessert. Pair with two chairs; the waiter serves guests here.",
    tags = { "cafe_table" }, surfaces = K.surf("table", 0.75, 1, 1, 2),
    variants = var("white:White Marble:0.94,0.94,0.92", "green:Green Marble:0.30,0.46,0.38", "black:Black Marble:0.16,0.16,0.17"),
})

add("cafe_table_four", {
    name = "Four-Top Cafe Table", sub = "dining", style = "contemporary", material = "plastic", price = 480, env = 3,
    rooms = VENUE, fp = K.rect(2, 1), height = 0.85, community = true,
    desc = "A two-tile laminate table with a condiment caddy and a wobble fixed by a folded menu. Seats four diners with chairs around it.",
    tags = { "cafe_table" }, surfaces = K.surf("table", 0.75, 2, 1, 2),
    variants = var("birch:Birch:0.90,0.82,0.66", "red:Diner Red:0.80,0.20,0.18", "white:White:0.96,0.96,0.95"),
})

---------------------------------------------------------------------------------------------------
-- Club and bar
---------------------------------------------------------------------------------------------------
add("bar_juice", {
    name = "Neon Juice Bar Counter", sub = "club", style = "eclectic", material = "wood", price = 1800, env = 6,
    rooms = VENUE, fp = K.rect(3, 1), height = 1.05, community = true, powered = true,
    desc = "Three tiles of polished counter, chrome taps of fizzy fruit concoctions and a neon sign that hums in B flat. A bartender serves three patrons at once.",
    slots = {
        staff = { approaches = { { 1, -1 }, { 0, -1 }, { 2, -1 } }, face = 0, staff = true, pose = "use" },
        patron1 = { approaches = { { 0, 1 } }, face = 2, group = "patron", pose = "idle" },
        patron2 = { approaches = { { 1, 1 } }, face = 2, group = "patron", pose = "idle" },
        patron3 = { approaches = { { 2, 1 } }, face = 2, group = "patron", pose = "idle" },
    },
    tags = { "bar" }, surfaces = K.surf("counter", 1.05, 3, 1, 1),
    quality = { speed = 1.0 },
    variants = var("pink:Pink Neon:0.94,0.36,0.62", "blue:Blue Neon:0.26,0.52,0.94", "green:Green Neon:0.36,0.86,0.44"),
})

add("dj_booth", {
    name = "Spinning-Deck DJ Booth", sub = "club", style = "eclectic", material = "metal", price = 2500, env = 5,
    rooms = VENUE, fp = K.rect(2, 1), height = 1.3, community = true, powered = true,
    desc = "Twin turntables, a mixer with more knobs than a submarine and a crate of records sorted by crowd reaction. A DJ plays here and patrons shout requests.",
    slots = { staff = { approaches = { { 1, -1 }, { 0, -1 } }, face = 0, staff = true, pose = "play" },
        request = { approaches = { { 0, 1 } }, face = 2, pose = "talk" } },
    tags = { "dj_booth" }, startState = { on = false },
    noise = 7, quality = { breakChance = 0.002, repairDifficulty = 4 },
    variants = var("black:Black & Chrome:0.14,0.14,0.15", "white:White Gloss:0.96,0.96,0.96", "purple:Purple Glow:0.46,0.22,0.62"),
})

---------------------------------------------------------------------------------------------------
-- Public utilities
---------------------------------------------------------------------------------------------------
add("restroom_stall", {
    name = "Public Restroom Stall", sub = "public", style = "starter", material = "metal", price = 1200, env = -2,
    rooms = VENUE, height = 2.0, community = true, privacy = true,
    desc = "A partitioned cubicle with a lock that shows red, a sturdy toilet and graffiti of surprisingly high literary quality. Patrons use it in private.",
    rates = { comfort = 8 },
    slots = { seat = { approaches = { { 0, 1 } }, face = 0, on = true, pose = "sit" } },
    actions = { "toilet" }, tags = { "restroom" },
    quality = { breakChance = 0.004, dirtRate = 1.6, repairDifficulty = 2 },
    variants = var("steel:Steel Partitions:0.80,0.82,0.84", "green:Green Laminate:0.40,0.60,0.46", "white:White Laminate:0.96,0.96,0.95"),
})

add("payphone", {
    name = "Coin Payphone Booth", sub = "public", style = "starter", material = "metal", price = 300, env = 1,
    rooms = VENUE, height = 2.1, community = true,
    desc = "A glass booth with a phone that takes coins, a directory missing every useful page and an unexplained umbrella. Patrons call a taxi or a friend from here.",
    -- the caller steps into the booth (front); repair workers stand at the sides or back (svc)
    slots = { front = { approaches = { { 0, 1 } }, face = 0, on = true, pose = "phone" },
        svc = { approaches = { { 1, 0 }, { -1, 0 }, { 0, -1 } }, face = 2, pose = "repair" } }, tags = { "phone" },
    variants = var("red:Heritage Red:0.74,0.14,0.14", "silver:Silver:0.80,0.82,0.84", "green:Green:0.24,0.44,0.26"),
})

add("bench_waiting", {
    name = "Planter-End Waiting Bench", sub = "public", style = "contemporary", material = "stone", price = 550, env = 2,
    rooms = VENUE, fp = K.rect(3, 1), height = 1.0, community = true,
    desc = "Three hardwood seats bolted between two concrete planters, with armrests placed to stop anyone lying down. Patrons wait for a table, a taxi or an apology here.",
    rates = { comfort = 14 }, slots = K.seatRow(3), actions = { "sit" }, tags = { "seat" },
    quality = { breakChance = 0.0004 },
    variants = var("oak:Oiled Hardwood:0.62,0.44,0.26", "grey:Grey Slats:0.56,0.58,0.60", "green:Park Green:0.20,0.40,0.26"),
})

add("bin_public", {
    name = "Park Litter Bin", sub = "public", style = "starter", material = "wood", price = 150, env = 0,
    rooms = VENUE, height = 0.9, community = true,
    desc = "A slatted bin with a lid shaped to discourage seagulls and a sign asking nicely. Visitors drop their rubbish here instead of on the lawn.",
    slots = { front = K.front(1, "use") }, tags = { "bin_outdoor" },
    quality = { capacity = 20 },
    variants = var("green:Park Green:0.20,0.40,0.26", "black:Black:0.14,0.14,0.15", "wood:Timber Slats:0.60,0.40,0.24"),
})
