-- SideStreet neighbourhood data: the Linden Hollow map (streets, lot placements, scenery),
-- hood tuning (prices, move-in/out policy, creator budget), creator appearance options,
-- personality archetypes and the neighbourhood's lot mailbox fixture.
-- Owner: hood module (docs/modules/hood.md). Static definitions only; saved state lives in
-- root.hood / root.households / root.residents (Sim/Hood.lua, Sim/Households.lua).
local _, SS = ...
local HD = {}
SS.HoodData = HD

---------------------------------------------------------------------------
-- Tuning (all prices on the ARCHITECTURE.md 9.7 scale; nothing hard-coded in Sim/UI)
---------------------------------------------------------------------------
HD.Tuning = {
    startMoney = 20000,          -- every new household (9.7)
    capacity = 8,                -- living human members per household
    personalityBudget = 25,      -- creator points, spent in full
    personalityMax = 10,
    interestMax = 10,
    nameMax = 16, householdNameMax = 24, bioMax = 200,
    newHouseholdTime = 8 * 60,   -- a brand-new household's own clock starts on day 1, 8:00
    partnerRomance = 65,         -- starting romance for spouses and partners (premades and the creator)
    foodBuffer = 500,            -- cash a household must keep after buying a home (careers' economy value wins)
    -- Structure appraisal (land is lot.price; furnishings use SS.Economy.ResaleValue).
    structure = {
        floorBase = 5,           -- per floor tile, plus the finish's own price (fallback floorFinish)
        floorFinish = 8,
        wallBase = 60,           -- per wall edge, plus both side finishes (fallback wallFinish each)
        wallFinish = 4,
        door = 260, window = 180, arch = 120, fence = 22, gate = 90, railing = 30, halfwall = 45,
        roofPerCell = 14,        -- per roofed top-story cell
        poolPerCell = 240,
        storyBonus = 400,        -- per extra story that has floor area
    },
    upperFloorOutdoorArea = 0,
    -- Map preview
    previewCacheCap = 48,
    zooms = { 0.12, 0.17, 0.24, 0.34, 0.48 },
    defaultZoom = 2,
    qualities = { "low", "medium", "high" },
    detailedCap = 420,           -- max draw items for the selected lot's cutaway preview
}

-- Structure prices per wall kind (the appraisal and the move-out settlement use these).
HD.WallPrice = { wall = true, door = "door", window = "window", arch = "arch", fence = "fence", gate = "gate",
    railing = "railing", halfwall = "halfwall" }

---------------------------------------------------------------------------
-- The map: Linden Hollow. Map cells (x east, y south). Street bands are inclusive cell
-- rectangles: the outer row/column on each side is sidewalk, the inner cells are road.
-- Lot placements: bbox corner (x, y) and rotation `rot` = the view rotation that turns the
-- lot's local frame into the map (lot cell (i,j) -> (x,y) + Grid.vcell(i,j,rot,w,h)); the
-- lot's street edge (local j = h) always touches a sidewalk.
---------------------------------------------------------------------------
HD.map = {
    id = "linden_hollow", name = "Linden Hollow", w = 120, h = 110,
    hoodId = "hood_linden", -- root.hood.id of the saves this map belongs to (Fixtures, Save)
    blurb = "A slightly crooked suburb of cul-de-sac optimists, one bus stop from the town centre.",
    streets = {
        { id = "juniper", name = "Juniper Lane", x0 = 0, y0 = 40, x1 = 119, y1 = 45, axis = "h" },
        { id = "alder", name = "Alder Row", x0 = 20, y0 = 78, x1 = 119, y1 = 83, axis = "h" },
        { id = "quarry", name = "Quarry Road", x0 = 20, y0 = 0, x1 = 25, y1 = 109, axis = "v" },
        { id = "tamsin", name = "Tamsin Crescent", x0 = 84, y0 = 46, x1 = 89, y1 = 77, axis = "v" },
    },
    -- Where the streets leave the map (the rest of town). Purely descriptive (labels).
    exits = {
        { street = "juniper", side = "west", text = "To the bus depot" },
        { street = "juniper", side = "east", text = "To the town centre" },
        { street = "quarry", side = "north", text = "To the quarry lakes" },
        { street = "quarry", side = "south", text = "To the ring road" },
        { street = "alder", side = "east", text = "To Pellham Market" },
    },
    -- 10 residential + 4 community lots. `street` + `number` make the address. `slot` is the
    -- space reserved on the map (map orientation, cells); the lot is anchored to the street edge
    -- of its slot and centred along the street (community lots come from the outings module's
    -- builder, whose sizes may differ from the placeholder layouts). Residential slots default to
    -- the blueprint size.
    lots = {
        -- north side of Juniper Lane (street edge faces south, onto the lane)
        { id = "lot_juniper_2", street = "juniper", number = 2, x = 28, y = 28, rot = 0, kind = "residential", blueprint = "wren_cottage" },
        { id = "lot_juniper_4", street = "juniper", number = 4, x = 44, y = 29, rot = 0, kind = "residential", blueprint = "kettering" },
        { id = "lot_juniper_6", street = "juniper", number = 6, x = 60, y = 30, rot = 0, kind = "residential", blueprint = "parcel_small" },
        { id = "lot_juniper_8", street = "juniper", number = 8, x = 74, y = 26, rot = 0, kind = "residential", blueprint = "hollyhock" },
        { id = "lot_juniper_10", street = "juniper", number = 10, x = 94, y = 22, rot = 0, kind = "community", venue = "cafe", slot = { w = 20, h = 18 } },
        -- south side of Juniper Lane (street edge faces north)
        { id = "lot_juniper_3", street = "juniper", number = 3, x = 28, y = 46, rot = 2, kind = "residential", blueprint = "halloran" },
        { id = "lot_juniper_5", street = "juniper", number = 5, x = 48, y = 46, rot = 2, kind = "residential", blueprint = "roommates" },
        { id = "lot_juniper_7", street = "juniper", number = 7, x = 66, y = 46, rot = 2, kind = "residential", blueprint = "parcel_medium" },
        { id = "lot_juniper_9", street = "juniper", number = 9, x = 90, y = 46, rot = 2, kind = "community", venue = "park", slot = { w = 30, h = 22 } },
        -- north side of Alder Row (street edge faces south)
        { id = "lot_alder_1", street = "alder", number = 1, x = 28, y = 62, rot = 0, kind = "residential", blueprint = "larchmont" },
        { id = "lot_alder_3", street = "alder", number = 3, x = 52, y = 60, rot = 0, kind = "residential", blueprint = "parcel_large" },
        -- south side of Alder Row (street edge faces north)
        { id = "lot_alder_2", street = "alder", number = 2, x = 28, y = 84, rot = 2, kind = "residential", blueprint = "ashcombe" },
        { id = "lot_alder_4", street = "alder", number = 4, x = 56, y = 84, rot = 2, kind = "community", venue = "club", slot = { w = 22, h = 18 } },
        { id = "lot_alder_6", street = "alder", number = 6, x = 82, y = 84, rot = 2, kind = "community", venue = "shops", slot = { w = 26, h = 22 } },
    },
    -- Scenery beyond the lots: ground zones (tints/sprites), trees and a few landmarks.
    zones = {
        { kind = "woods", x0 = 0, y0 = 0, x1 = 19, y1 = 37 },
        { kind = "meadow", x0 = 26, y0 = 0, x1 = 119, y1 = 20 },
        { kind = "pond", x0 = 4, y0 = 52, x1 = 13, y1 = 63 },
        { kind = "woods", x0 = 0, y0 = 86, x1 = 19, y1 = 109 },
        { kind = "orchard", x0 = 96, y0 = 70, x1 = 119, y1 = 77 },
        { kind = "green", x0 = 74, y0 = 60, x1 = 83, y1 = 77 },
        { kind = "field", x0 = 110, y0 = 86, x1 = 119, y1 = 109 },
        { kind = "meadow", x0 = 26, y0 = 104, x1 = 81, y1 = 109 },
    },
    landmarks = {
        { kind = "water_tower", x = 108, y = 8, label = "Linden Hollow water tower" },
        { kind = "bus_stop", x = 58, y = 40, label = "Juniper Lane bus stop" },
        { kind = "footbridge", x = 9, y = 58, label = "Pond footbridge" },
        { kind = "barn", x = 114, y = 96, label = "Old Pellham barn" },
        { kind = "bench", x = 78, y = 68, label = "Memorial bench on the green" },
    },
    -- scattered scenery trees are generated deterministically from the zones and verges
    treeSeed = 20260924,
}

HD.StreetName = {}
for _, s in ipairs(HD.map.streets) do HD.StreetName[s.id] = s.name end

-- Ground tints by zone (fallback while dedicated map tiles are pending; see docs/art_requests/hood.md).
HD.ZoneTint = {
    lawn = { 0.56, 0.74, 0.44 }, woods = { 0.34, 0.52, 0.32 }, meadow = { 0.70, 0.78, 0.46 },
    orchard = { 0.50, 0.68, 0.40 }, pond = { 0.36, 0.58, 0.78 }, field = { 0.80, 0.74, 0.46 },
    green = { 0.52, 0.76, 0.46 }, lot = { 0.60, 0.80, 0.48 },
    road = { 0.36, 0.36, 0.38 }, sidewalk = { 0.80, 0.78, 0.72 }, marking = { 0.95, 0.90, 0.60 },
    crossing = { 0.92, 0.92, 0.88 },
}

-- Roof colour names -> RGB (the preview's fallback roof and the info panel swatch).
HD.RoofColor = {
    terracotta = { 0.78, 0.40, 0.28 }, slate = { 0.36, 0.40, 0.46 }, moss = { 0.42, 0.52, 0.32 },
    charcoal = { 0.24, 0.24, 0.26 }, sand = { 0.84, 0.74, 0.54 }, brick = { 0.62, 0.26, 0.20 },
    teal = { 0.24, 0.52, 0.52 }, plum = { 0.46, 0.28, 0.42 }, copper = { 0.60, 0.44, 0.30 },
    white = { 0.90, 0.90, 0.86 }, blue = { 0.30, 0.42, 0.62 }, green = { 0.30, 0.46, 0.34 },
    cedar = { 0.55, 0.42, 0.30 }, pewter = { 0.62, 0.64, 0.66 },
}

-- Venue information for the neighbourhood panel. The outings module's Data/Venues.lua is
-- preferred when it provides SS.Venues.Info(kind) (guarded in Sim/Hood.lua).
HD.VenueInfo = {
    shops = { label = "Shopping courtyard", hours = "Open 9 AM - 8 PM",
        activities = { "Browse clothing, gifts and flowers", "Books and magazines", "Small decor and household goods", "Try on outfits" } },
    cafe = { label = "Cafe and restaurant", hours = "Open 7 AM - 11 PM",
        activities = { "Be seated and order a meal", "Coffee and cake", "Dates and catch-ups" } },
    park = { label = "Public park", hours = "Open all day",
        activities = { "Picnic and grill", "Benches and people-watching", "Chess and play", "Public restroom" } },
    club = { label = "Social venue", hours = "Open 6 PM - 2 AM",
        activities = { "Dance to the DJ", "Pool and darts", "Drinks at the bar", "Party space" } },
}

-- Placeholder names used only when the outings module's builder is missing.
HD.VenueNames = {
    shops = "Cobbler's Yard", cafe = "The Toasted Almond", park = "Linden Green", club = "The Velvet Metronome",
}

---------------------------------------------------------------------------
-- Creator options. These are exactly the options docs/art_requests/hood.md asks the art
-- module to draw; UI/Create.lua marks an option "art pending" while the manifest lacks it.
---------------------------------------------------------------------------
HD.SkinTones = {
    { id = "porcelain", name = "Porcelain", c = { 0.98, 0.87, 0.78 } },
    { id = "shell", name = "Shell", c = { 0.94, 0.78, 0.64 } },
    { id = "honey", name = "Honey", c = { 0.87, 0.67, 0.52 } },
    { id = "sand", name = "Sandstone", c = { 0.78, 0.58, 0.42 } },
    { id = "amber", name = "Amber", c = { 0.66, 0.47, 0.31 } },
    { id = "clay", name = "Clay", c = { 0.55, 0.37, 0.24 } },
    { id = "walnut", name = "Walnut", c = { 0.42, 0.27, 0.17 } },
    { id = "ebony", name = "Ebony", c = { 0.29, 0.19, 0.13 } },
}
HD.HairColors = {
    { id = "black", name = "Ink black", c = { 0.10, 0.09, 0.09 } },
    { id = "darkbrown", name = "Dark brown", c = { 0.24, 0.15, 0.09 } },
    { id = "chestnut", name = "Chestnut", c = { 0.35, 0.20, 0.12 } },
    { id = "auburn", name = "Auburn", c = { 0.50, 0.22, 0.12 } },
    { id = "copper", name = "Copper", c = { 0.72, 0.38, 0.18 } },
    { id = "golden", name = "Golden", c = { 0.86, 0.68, 0.36 } },
    { id = "ash", name = "Ash blonde", c = { 0.80, 0.74, 0.60 } },
    { id = "grey", name = "Silver grey", c = { 0.62, 0.62, 0.64 } },
    { id = "white", name = "Snow white", c = { 0.92, 0.92, 0.90 } },
    { id = "plum", name = "Plum dye", c = { 0.46, 0.20, 0.44 } },
    { id = "teal", name = "Teal dye", c = { 0.18, 0.52, 0.54 } },
}
HD.HairStyles = {
    { id = "short", name = "Short crop" }, { id = "long", name = "Long and loose" },
    { id = "bob", name = "Chin bob" }, { id = "curly", name = "Curly mop" },
    { id = "bun", name = "Top bun" }, { id = "ponytail", name = "Ponytail" },
    { id = "afro", name = "Rounded afro" }, { id = "braids", name = "Braids" },
    { id = "buzz", name = "Buzz cut" }, { id = "bald", name = "Bald" },
}
HD.Bodies = { { id = "average", name = "Average" }, { id = "slim", name = "Slim" }, { id = "broad", name = "Broad" } }
HD.Faces = {
    { id = 1, name = "Round, soft brows" }, { id = 2, name = "Oval, freckles" }, { id = 3, name = "Square jaw" },
    { id = 4, name = "Heart, dimples" }, { id = 5, name = "Long, glasses" }, { id = 6, name = "Wide, beard or stubble" },
}
HD.OutfitKinds = { "everyday", "sleep", "swim", "work", "formal" }
HD.OutfitLabel = { everyday = "Everyday", sleep = "Sleepwear", swim = "Swimwear", work = "Work", formal = "Formal" }
HD.OutfitStyles = {
    everyday = { { id = "tee_jeans", name = "Tee and jeans" }, { id = "blouse_skirt", name = "Blouse and skirt" },
        { id = "sweater_slacks", name = "Sweater and slacks" }, { id = "overalls", name = "Dungarees" },
        { id = "hoodie_shorts", name = "Hoodie and shorts" }, { id = "cardigan_dress", name = "Cardigan dress" } },
    sleep = { { id = "pajamas", name = "Striped pyjamas" }, { id = "nightgown", name = "Nightgown" }, { id = "tee_shorts", name = "Tee and shorts" } },
    swim = { { id = "trunks", name = "Swim trunks" }, { id = "one_piece", name = "One-piece" }, { id = "two_piece", name = "Two-piece" }, { id = "shorty", name = "Shorty wetsuit" } },
    work = { { id = "shirt_tie", name = "Shirt and tie" }, { id = "scrubs", name = "Scrubs" }, { id = "apron", name = "Apron and whites" },
        { id = "coveralls", name = "Coveralls" }, { id = "blazer", name = "Blazer" } },
    formal = { { id = "suit", name = "Suit" }, { id = "gown", name = "Evening gown" }, { id = "vest", name = "Waistcoat and bow tie" },
        { id = "cocktail", name = "Cocktail dress" } },
}
HD.ClothColors = {
    { 0.25, 0.62, 0.62 }, { 0.22, 0.25, 0.42 }, { 0.40, 0.26, 0.16 }, { 0.78, 0.30, 0.26 }, { 0.93, 0.80, 0.40 },
    { 0.36, 0.56, 0.30 }, { 0.55, 0.40, 0.68 }, { 0.92, 0.92, 0.88 }, { 0.16, 0.16, 0.18 }, { 0.86, 0.52, 0.62 },
    { 0.58, 0.60, 0.64 }, { 0.30, 0.46, 0.72 },
}
HD.Pronouns = { "she", "he", "they" }
HD.Ages = { "adult", "child" }

---------------------------------------------------------------------------
-- Personality: the five dimensions (0..10 each, 25 points in the creator), their labels,
-- and the tradeoffs the creator explains. Behaviour lives in the social module
-- (SS.Personality.Modify); these texts describe what it is asked to do (ARCHITECTURE 9).
---------------------------------------------------------------------------
HD.Dims = { "neat", "outgoing", "active", "playful", "nice" }
HD.DimInfo = {
    neat = { name = "Neatness", low = "Sloppy", high = "Neat",
        lowText = "Shrugs off mess and leaves plates behind; the room score suffers for everyone.",
        highText = "Cleans up readily and washes hands, but notices mess sooner and spends time on chores." },
    outgoing = { name = "Sociability", low = "Shy", high = "Outgoing",
        lowText = "Tires of company quickly and needs less of it; slower to make friends.",
        highText = "Makes friends easily and enjoys a crowd, but gets lonely fast when left alone." },
    active = { name = "Activity", low = "Lazy", high = "Active",
        lowText = "Loves a sofa and a long nap; exercise is a chore.",
        highText = "Values exercise and moves quickly, but gets restless and bored when idle." },
    playful = { name = "Playfulness", low = "Serious", high = "Playful",
        lowText = "Prefers books and study; jokes and games do less for them.",
        highText = "Prefers games, jokes and toys, and has fun easily, but studies grudgingly." },
    nice = { name = "Agreeableness", low = "Grouchy", high = "Nice",
        lowText = "Picks rude replies and accepts fewer social offers; keeps rivals.",
        highText = "Kind in conversation and forgiving, but easier to take advantage of." },
}

-- Original sign-like archetypes (each spends exactly 25 points).
HD.Presets = {
    { id = "kettle", name = "The Kettle", text = "Warm, chatty, always boiling over with plans.", p = { neat = 4, outgoing = 8, active = 5, playful = 5, nice = 3 } },
    { id = "lighthouse", name = "The Lighthouse", text = "Steady, tidy and kind; keeps everyone off the rocks.", p = { neat = 8, outgoing = 3, active = 4, playful = 2, nice = 8 } },
    { id = "weathervane", name = "The Weathervane", text = "Restless and playful; points wherever the fun blows.", p = { neat = 2, outgoing = 6, active = 8, playful = 8, nice = 1 } },
    { id = "bookend", name = "The Bookend", text = "Quiet, orderly and serious; holds the shelf together.", p = { neat = 9, outgoing = 2, active = 3, playful = 1, nice = 10 } },
    { id = "firework", name = "The Firework", text = "Loud, bright, gone in a flash, leaves a mess.", p = { neat = 1, outgoing = 9, active = 7, playful = 7, nice = 1 } },
    { id = "teapot", name = "The Teapot", text = "Gentle and homely; prefers a long sit to a long run.", p = { neat = 6, outgoing = 5, active = 1, playful = 4, nice = 9 } },
    { id = "compass", name = "The Compass", text = "Driven and athletic; always knows where the gym is.", p = { neat = 6, outgoing = 4, active = 10, playful = 2, nice = 3 } },
    { id = "porch_swing", name = "The Porch Swing", text = "Easygoing and sociable; happiest doing nothing with friends.", p = { neat = 3, outgoing = 8, active = 1, playful = 6, nice = 7 } },
    { id = "paper_kite", name = "The Paper Kite", text = "Dreamy and playful; brilliant ideas, lost keys.", p = { neat = 1, outgoing = 3, active = 6, playful = 10, nice = 5 } },
    { id = "garden_gnome", name = "The Garden Gnome", text = "Grumpy, tidy and set in their ways; secretly soft.", p = { neat = 10, outgoing = 1, active = 5, playful = 5, nice = 4 } },
    { id = "jukebox", name = "The Jukebox", text = "Social and fun; a song for every mood, a mess for every song.", p = { neat = 2, outgoing = 10, active = 4, playful = 8, nice = 1 } },
    { id = "hearth", name = "The Hearth", text = "Balanced and warm; the one everyone phones first.", p = { neat = 5, outgoing = 5, active = 5, playful = 5, nice = 5 } },
}

-- Interests: the social module's Data/Topics.lua (SS.Topics) is authoritative. This list is
-- the fallback the creator and premades use when SS.Topics is missing or empty.
HD.FallbackTopics = {
    { id = "sports", name = "Sports" }, { id = "cooking", name = "Cooking" }, { id = "music", name = "Music" },
    { id = "travel", name = "Travel" }, { id = "pets", name = "Pets" }, { id = "money", name = "Money" },
    { id = "fashion", name = "Fashion" }, { id = "films", name = "Films" }, { id = "science", name = "Science" },
    { id = "gardening", name = "Gardening" }, { id = "townnews", name = "Town news" }, { id = "art", name = "Art" },
    { id = "computers", name = "Computers" }, { id = "weather", name = "Weather" }, { id = "books", name = "Books" },
}

-- Creator relationship choices (a's role toward b). Family kinds go through
-- SS.Social.SetFamily; partner/roommate are flags (documented in docs/modules/hood.md).
HD.RelKinds = {
    { id = "none", name = "No tie" },
    { id = "spouse", name = "Spouse", adultsOnly = true, family = "spouse", life = 70, daily = 40 },
    { id = "partner", name = "Partner", adultsOnly = true, flag = "partner", life = 60, daily = 35 },
    { id = "parent", name = "Parent of", family = "parent", life = 60, daily = 30 },
    { id = "child", name = "Child of", family = "child", life = 60, daily = 30 },
    { id = "sibling", name = "Sibling", family = "sibling", life = 45, daily = 20 },
    { id = "roommate", name = "Roommate", flag = "roommate", life = 20, daily = 15 },
}

---------------------------------------------------------------------------
-- Lot fixture: the curbside mailbox. The hood module places one on every residential lot
-- next to the entry (every house must have one). Its behaviour arrives by the `mailbox`
-- tag (visitors: mail; careers: bills). A catalogue mailbox with that tag is preferred when
-- one exists; this definition keeps saves loadable either way.
---------------------------------------------------------------------------
SS.Objects = SS.Objects or {}
SS.Objects.hood_mailbox = {
    name = "Curbside Mailbox", cat = "system", sub = "fixture", buyable = false, price = 0, env = 0,
    desc = "Receives bills, catalogues and the occasional postcard from someone who is clearly having a better time than you.",
    tags = { "mailbox" }, slots = { front = { approaches = { { 0, 1 } }, face = 2 } }, actions = {},
    art = { model = "docs/art_requests/hood.md#mailbox" },
}
if SS.Tags and SS.Tags.Apply then SS.Tags.Apply(SS.Objects.hood_mailbox) end
