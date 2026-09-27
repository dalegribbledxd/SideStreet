-- SideStreet community venues: venue kinds, vendors, stock, cafe menu, bar drinks, staff,
-- tuning, anchor furnishing specs, and the outings module's system objects.
-- Owner: outings module (see ARCHITECTURE.md and docs/modules/outings.md).
-- Pure data (plus system object definitions); behaviour lives in Sim/Travel.lua, Sim/Venues.lua,
-- Sim/Shopping.lua and Sim/Dining.lua. All names and text are original.
local _, SS = ...

local VD = {}
SS.VenueData = VD

---------------------------------------------------------------------------------------------------
-- Tuning (sim minutes unless noted). Prices are in the section-sign currency (ARCHITECTURE.md §9.7).
VD.tuning = {
    taxiWait = 8,            -- minutes between calling a taxi and it pulling up at the curb
    taxiBoardLimit = 60,     -- the taxi waits this long for everyone to walk out, then leaves
    boardRetries = 3,        -- walk-to-taxi route attempts per person before they are left behind
    ride = 15,               -- outing clock minutes spent in the taxi on the way out
    maxParty = 8,            -- residents per outing (household cap)
    maxGuests = 1,           -- invited people meeting the party there (a date partner)
    guestDelay = { 10, 25 }, -- an accepted guest arrives this many minutes after the party
    guestPatience = 90,      -- a guest leaves on their own after this long if the date is going badly
    crowdCap = 24,           -- hard cap on actors on a venue lot (staff + party + guests + patrons)
    patronArriveGap = { 12, 30 }, -- minutes between townie patrons walking in
    patronStay = { 50, 140 },     -- how long a townie patron stays
    patronActivityGap = 20,  -- minutes between a patron's activity choices
    staffRetries = 3,        -- a staff member retries a blocked route this many times, then reports it
    staffRetryGap = 4,       -- minutes between those retries
    scoreEvery = 10,         -- outing/date score update period
    dateEndBelow = 20,       -- a date this bad ends early (gracefully)
    dateMinMinutes = 40,     -- ...but only after this long together
    engagedWindow = 30,      -- conditions (comfort, company) count only within this many minutes of
                             -- something actually done (an activity, a conversation, a meal ...)
    boredFloor = 45,         -- with nothing done for engagedWindow minutes the score drifts down to here
    -- per-outing (and per-date) totals a factor may reach; repeated activities count less each time
    factorCap = { comfort = { -20, 10 }, company = { -10, 10 }, conversation = { -30, 25 }, activities = { -10, 30 },
        shopping = { 0, 10 }, gift = { -12, 12 }, group = { 0, 12 }, meal = { -20, 15 } },
    inventoryCap = 60,       -- household storage slots for bought goods
    wardrobeCap = 24,        -- outfits per person
    restock = 3,             -- units of each stock item on the shelf at the start of a visit
    lineWait = 45,           -- longest a customer queues before giving up
    queueCap = 5,            -- people allowed in one register line (more are asked to come back)
    serveTime = 3,           -- minutes the shopkeeper takes to ring up a purchase
    pickTime = 3,            -- minutes spent inspecting an item before choosing it
    clerkWait = 20,          -- longest a customer waits at an unattended register
    payRetries = 3,          -- times a shopper beaten to the till goes back into line on their own
    tableWaitMax = 45,       -- longest a party waits for a table before giving up
    orderTime = 2,           -- minutes the waiter spends taking an order
    foodWaitMax = 90,        -- longest a party waits for food before the host cancels and apologises
    missingGrace = 20,       -- minutes a seated party waits for a missing companion
    hostCoverWait = 25,      -- minutes an escalated table task waits for a busy host before the counter
    counterWaitMax = 30,     -- minutes a diner waits for someone else to finish at a busy counter spot
    billTime = 1,
    tableTalkSocial = 22,    -- per hour, seated diners with company
    tableTalkFun = 8,
}

---------------------------------------------------------------------------------------------------
-- The four venue kinds (lot.venue). Hours: open/close hours on the outing clock; nil = always open;
-- close < open wraps past midnight.
VD.kinds = {
    shops = {
        label = "Shopping courtyard", name = "Marigold Row Shops", address = "1 Marigold Row",
        desc = "Four little shopfronts around a paved courtyard with a fountain. Everyone swears they are only looking.",
        hours = { open = 8, close = 21 }, audio = "venue_shops", patronCap = 4,
        activities = { "Clothes with a changing booth", "Gifts and flowers", "Books and magazines",
            "Home decor to place later", "Courtyard benches and fountain", "Public restroom" },
        roles = { "shopkeeper" },
    },
    cafe = {
        label = "Cafe and restaurant", name = "The Butterdish Cafe", address = "12 Pantry Street",
        desc = "A corner cafe with a host stand, a proper kitchen and tables for two or four. The gravy has a following.",
        hours = { open = 7, close = 23 }, audio = "venue_cafe", patronCap = 3,
        activities = { "Be seated by the host", "Order from the menu", "Dine with company", "Public restroom" },
        roles = { "host", "waiter", "cook" },
    },
    park = {
        label = "Public park", name = "Hollyhock Green", address = "Hollyhock Green",
        desc = "Lawns, shade trees, a coin grill by the picnic tables, chess boards, a climbing frame and a restroom block.",
        hours = nil, audio = "venue_park", patronCap = 5,
        activities = { "Picnic and grill", "Chess tables", "Climbing frame", "Fountain wishes",
            "Benches for people-watching", "Public restroom" },
        roles = {},
    },
    club = {
        label = "Social club", name = "The Gramophone Room", address = "40 Crescent Parade",
        desc = "A dance floor, a resident DJ, pool and darts, a juice bar and tall tables for loud conversations.",
        hours = { open = 16, close = 3 }, audio = "venue_club", patronCap = 6,
        activities = { "Dance to the DJ", "Request a song", "Pool and darts", "Juice bar and rounds",
            "Mingle at the tall tables", "Public restroom" },
        roles = { "dj", "bartender" },
    },
}
VD.KIND_ORDER = { "shops", "cafe", "park", "club" }

---------------------------------------------------------------------------------------------------
-- Vendors in the shopping courtyard. Each display tag belongs to one vendor.
VD.vendors = {
    clothing = { name = "Hem & Haw Outfitters", display = "display_clothing", label = "Clothing" },
    gifts = { name = "Petal Pusher Gifts & Flowers", display = "display_gift", label = "Gifts and flowers" },
    books = { name = "Dog-Ear Books & News", display = "display_books", label = "Books and magazines" },
    decor = { name = "Knick & Knack Home Goods", display = "display_decor", label = "Home decor" },
}
VD.VENDOR_ORDER = { "clothing", "gifts", "books", "decor" }
VD.displayVendor = { display_clothing = "clothing", display_gift = "gifts", display_books = "books", display_decor = "decor" }

---------------------------------------------------------------------------------------------------
-- Stock. Clothing unlocks a wearable outfit (person.wardrobe, and look.outfits[slot] when that slot
-- is empty). Styles are outfit silhouettes the art module draws (docs/art_requests/outings.md).
local function c(r, g, b) return { r, g, b } end
VD.stock = {}
VD.stock.clothing = {
    { id = "cl_cardigan", name = "Weekend Cardigan Set", slot = "everyday", style = "cardigan", price = 85,
      top = c(0.72, 0.55, 0.36), bottom = c(0.30, 0.32, 0.40), shoes = c(0.35, 0.24, 0.16),
      desc = "Soft enough for Saturdays, respectable enough for a surprise visit from a landlord." },
    { id = "cl_sunday", name = "Sunday Best Two-Piece", slot = "formal", style = "suit", price = 240,
      top = c(0.20, 0.24, 0.36), bottom = c(0.20, 0.24, 0.36), shoes = c(0.10, 0.10, 0.10),
      desc = "Sharp lapels and a quiet pocket for keeping your opinions until after dessert." },
    { id = "cl_lagoon", name = "Lagoon Stripe Swimsuit", slot = "swim", style = "swim_stripe", price = 60,
      top = c(0.15, 0.55, 0.62), bottom = c(0.95, 0.95, 0.90), shoes = c(0.90, 0.80, 0.55),
      desc = "Horizontal stripes, vertical confidence." },
    { id = "cl_nightowl", name = "Flannel Night Owl Pyjamas", slot = "sleep", style = "pyjamas", price = 45,
      top = c(0.45, 0.22, 0.25), bottom = c(0.45, 0.22, 0.25), shoes = c(0.60, 0.50, 0.40),
      desc = "Tartan flannel with a tiny embroidered owl who has seen your 2 AM snacking." },
    { id = "cl_office", name = "Pressed Office Separates", slot = "work", style = "office", price = 160,
      top = c(0.86, 0.88, 0.92), bottom = c(0.25, 0.25, 0.28), shoes = c(0.18, 0.12, 0.08),
      desc = "Crisp shirt, sensible trousers. Promotion not included, but not ruled out." },
    { id = "cl_denim", name = "Denim Everything Outfit", slot = "everyday", style = "denim", price = 110,
      top = c(0.30, 0.42, 0.62), bottom = c(0.22, 0.30, 0.50), shoes = c(0.85, 0.85, 0.82),
      desc = "Denim jacket, denim jeans. A bold commitment to one fabric." },
    { id = "cl_velvet", name = "Velvet Evening Ensemble", slot = "formal", style = "gown", price = 380,
      top = c(0.42, 0.10, 0.28), bottom = c(0.42, 0.10, 0.28), shoes = c(0.12, 0.08, 0.10),
      desc = "Deep plum velvet for dinners where the napkins are folded into shapes." },
    { id = "cl_tracksuit", name = "Tracksuit of Good Intentions", slot = "everyday", style = "tracksuit", price = 70,
      top = c(0.20, 0.50, 0.30), bottom = c(0.20, 0.50, 0.30), shoes = c(0.92, 0.92, 0.92),
      desc = "Designed for jogging. Mostly worn for sitting near people who jog." },
    { id = "cl_sundress", name = "Garden Party Sundress Set", slot = "everyday", style = "sundress", price = 95,
      top = c(0.96, 0.80, 0.42), bottom = c(0.96, 0.80, 0.42), shoes = c(0.80, 0.62, 0.45),
      desc = "Buttercup yellow with pockets deep enough for a sandwich." },
    { id = "cl_bowling", name = "Retro Bowling Shirt Combo", slot = "everyday", style = "bowling", price = 75,
      top = c(0.78, 0.25, 0.20), bottom = c(0.18, 0.18, 0.20), shoes = c(0.70, 0.20, 0.18),
      desc = "Two-tone shirt with a stitched name tag reading 'Guest'. It suits everyone." },
    { id = "cl_polka", name = "Polka-Dot Bathing Set", slot = "swim", style = "swim_dots", price = 55,
      top = c(0.88, 0.30, 0.38), bottom = c(0.88, 0.30, 0.38), shoes = c(0.95, 0.95, 0.95),
      desc = "Red with white dots, for people who like to be found quickly at the pool." },
    { id = "cl_cloud", name = "Cloud-Soft Lounge Pyjamas", slot = "sleep", style = "lounge", price = 65,
      top = c(0.70, 0.78, 0.90), bottom = c(0.70, 0.78, 0.90), shoes = c(0.92, 0.92, 0.95),
      desc = "Pale blue brushed cotton. Guaranteed to make Monday feel slightly further away." },
}

-- Gifts become transferable inventory items (kind "gift"). appeal: interest topics that make the
-- recipient more likely to love it; romantic gifts need an existing warm relationship.
VD.stock.gifts = {
    { id = "gf_daisies", name = "Hand-Tied Daisy Bunch", giftType = "flowers", price = 25, appeal = { "gardening", "nature" },
      desc = "Cheerful, inexpensive and impossible to misinterpret." },
    { id = "gf_roses", name = "Dozen Crimson Roses", giftType = "flowers", price = 60, romantic = true, appeal = { "romance", "fashion" },
      desc = "A declaration in twelve parts. Give only if you mean at least nine of them." },
    { id = "gf_orchid", name = "Potted Mini Orchid", giftType = "plant", price = 45, appeal = { "gardening", "art" },
      desc = "Elegant, demanding, and a little smug about both." },
    { id = "gf_caramels", name = "Box of Salted Caramels", giftType = "sweets", price = 18, appeal = { "cooking", "food" },
      desc = "Twelve caramels, a ribbon, and an honest chance the box arrives with eleven." },
    { id = "gf_snowglobe", name = "Snow Globe With a Tiny Bus", giftType = "trinket", price = 22, appeal = { "travel", "town" },
      desc = "Shake it and the little bus is late in a blizzard. Very realistic." },
    { id = "gf_crossword", name = "Pocket Crossword Omnibus", giftType = "puzzle", price = 15, appeal = { "books", "science" },
      desc = "Four hundred puzzles and one pencil that will be lost by puzzle six." },
    { id = "gf_candle", name = "Scented Candle: Rainy Library", giftType = "candle", price = 30, appeal = { "books", "art" },
      desc = "Smells of old paper and gentle weather. Does not smell of overdue fines." },
    { id = "gf_bracelet", name = "Friendship Bracelet Kit", giftType = "craft", price = 12, appeal = { "art", "fashion" },
      desc = "Thread in six colours and instructions that assume patience." },
    { id = "gf_tea", name = "Deluxe Tea Sampler Tin", giftType = "tea", price = 35, appeal = { "cooking", "travel" },
      desc = "Twenty teas from places the recipient will now describe at length." },
    { id = "gf_hedgehog", name = "Plush Hedgehog With Opinions", giftType = "plush", price = 28, appeal = { "pets", "films" },
      desc = "Soft, spiky-looking and faintly disapproving. Children adore it; so do some accountants." },
}

-- Books and magazines become inventory items (kind "book") that residents read in any seat.
-- topic: an interest that reading nudges up; skill: a skill practised while reading (books only).
VD.stock.books = {
    { id = "bk_casserole", name = "The Casserole Chronicles", price = 30, topic = "cooking", skill = "cooking",
      desc = "Forty baked dishes and one heartfelt essay about a lid that never fit." },
    { id = "bk_fixit", name = "Fix It Before Dinner", price = 35, topic = "science", skill = "mechanical",
      desc = "A home-repair primer with a whole chapter titled 'Is It Plugged In?'" },
    { id = "bk_charm", name = "Charm Without Effort (Some Effort Required)", price = 28, topic = "fashion", skill = "charisma",
      desc = "Practical advice for eye contact, small talk and leaving parties on a high note." },
    { id = "bk_chess", name = "The Patient Chess Player", price = 32, topic = "science", skill = "logic",
      desc = "Openings, endgames, and how to look thoughtful while losing a rook." },
    { id = "bk_brush", name = "Brush Strokes for Beginners", price = 26, topic = "art", skill = "creativity",
      desc = "Watercolour lessons for anyone who has ever painted a sky that looked like soup." },
    { id = "bk_stretch", name = "Stretch, Breathe, Regret Nothing", price = 24, topic = "sports", skill = "body",
      desc = "A friendly fitness plan that begins, reasonably, with finding your trainers." },
    { id = "bk_mystery", name = "The Hollow Oak Mysteries, Volume 3", price = 18, topic = "books",
      desc = "The gardener did it. Or did he? (He did. But the journey is lovely.)" },
    { id = "bk_almanac", name = "The Globetrotter's Almanac", price = 22, topic = "travel",
      desc = "Timetables, phrasebooks and packing lists for trips that may remain theoretical." },
    { id = "mg_garden", name = "Weekly Garden Gazette", price = 6, topic = "gardening", magazine = true,
      desc = "This week: slugs, and how to forgive them." },
    { id = "mg_circuit", name = "Pixel & Circuit Monthly", price = 7, topic = "computers", magazine = true,
      desc = "Reviews of machines that will be obsolete by the time you finish the review." },
    { id = "mg_screen", name = "Screen Scene Weekly", price = 5, topic = "films", magazine = true,
      desc = "Film gossip, cinema listings and a crossword that is mostly actors' surnames." },
    { id = "mg_kickoff", name = "Kickoff Quarterly", price = 6, topic = "sports", magazine = true,
      desc = "Match reports written with the breathless urgency of a lost dog poster." },
}

-- Home decor is sold as real catalogue objects that go into household inventory and are placed
-- later with the catalogue's inventory placement. The shop sells each object at its catalogue
-- price (so buy-here-sell-at-home never makes money). Stock is chosen at runtime from these rules,
-- first rule first, distinct definitions only; the fallbacks are base objects that always exist.
VD.stock.decor = {
    rules = {
        { cat = "decor", maxPrice = 400, take = 4 },
        { cat = "lighting", maxPrice = 300, take = 2 },
        { cat = "storage", maxPrice = 250, take = 1 },
        { cat = "outdoor", maxPrice = 200, take = 1 },
        { cat = "seating", maxPrice = 150, take = 1 },
        { cat = "surfaces", maxPrice = 150, take = 1 },
        { cat = "kitchen", maxPrice = 60, take = 1 },
        { cat = "electronics", maxPrice = 120, take = 1 },
    },
    maxItems = 12,
    fallback = { "plant_pot", "lamp_floor", "bin_indoor", "chair_dining", "table_small" },
    mounts = { floor = true, surface = true, wall = true, [""] = true },
}

---------------------------------------------------------------------------------------------------
-- Cafe menu. quality 1..10 (the cook's skill moves it a little), prep = kitchen minutes,
-- eat = minutes to finish, hunger = total gained by finishing a quality-5 portion.
VD.menu = {
    { id = "m_crumpets", name = "Buttered Crumpet Stack", course = "light", price = 6, quality = 5, prep = 6, eat = 12, hunger = 28,
      desc = "Three crumpets, one generous opinion about butter." },
    { id = "m_soup", name = "Soup of the Undecided Day", course = "light", price = 7, quality = 5, prep = 5, eat = 12, hunger = 30,
      desc = "Changes daily. Nobody in the kitchen will say what it was yesterday." },
    { id = "m_salad", name = "Garden Plate Salad", course = "light", price = 9, quality = 6, prep = 6, eat = 14, hunger = 32,
      desc = "Leaves, radishes, toasted seeds and a dressing with ambition." },
    { id = "m_toastie", name = "Grilled Cheese Deluxe", course = "main", price = 8, quality = 5, prep = 8, eat = 14, hunger = 42,
      desc = "Two cheeses fighting for control of one sandwich." },
    { id = "m_burger", name = "Butterdish Burger", course = "main", price = 12, quality = 6, prep = 12, eat = 18, hunger = 55,
      desc = "A tall burger held together by a toothpick and hope." },
    { id = "m_hotpot", name = "Shepherd's Hotpot", course = "main", price = 15, quality = 7, prep = 16, eat = 20, hunger = 64,
      desc = "Slow-cooked, crispy on top, and served in a dish that stays hot until spring." },
    { id = "m_fish", name = "Fish Supper With Minted Peas", course = "main", price = 16, quality = 6, prep = 14, eat = 20, hunger = 60,
      desc = "Crisp batter, chunky chips, and peas that insist they are a vegetable course." },
    { id = "m_stroganoff", name = "Mushroom Stroganoff", course = "main", price = 18, quality = 7, prep = 15, eat = 20, hunger = 58,
      desc = "Creamy, peppery and adored by people who say they do not like mushrooms." },
    { id = "m_chicken", name = "Lemon-Herb Roast Chicken", course = "main", price = 22, quality = 8, prep = 20, eat = 22, hunger = 70,
      desc = "The dish the cook makes for the cook's own birthday." },
    { id = "m_tasting", name = "Chef's Tasting Plate", course = "main", price = 34, quality = 9, prep = 24, eat = 24, hunger = 62,
      desc = "Seven small things arranged like a museum exhibit. Each one is delicious." },
    { id = "m_pudding", name = "Sticky Toffee Pudding", course = "dessert", price = 7, quality = 7, prep = 5, eat = 10, hunger = 22,
      desc = "Warm sponge in toffee sauce. Spoons have been known to disappear into it." },
    { id = "m_tea", name = "Pot of House Tea", course = "drink", price = 3, quality = 5, prep = 3, eat = 8, hunger = 6,
      desc = "Strong enough to stand a teaspoon in, gentle enough to chat over." },
    { id = "m_cocoa", name = "Cocoa With a Whipped Cloud", course = "drink", price = 4, quality = 6, prep = 4, eat = 8, hunger = 10,
      desc = "Hot chocolate under a hat of cream. Leaves an honest moustache." },
}

-- Juice bar at the social club (non-alcoholic, original names).
VD.drinks = {
    { id = "d_grapefruit", name = "Fizzy Grapefruit Cooler", price = 5, fun = 10, social = 6 },
    { id = "d_cherry", name = "Midnight Cherry Soda", price = 5, fun = 12, social = 5 },
    { id = "d_ginger", name = "Ginger Thunder", price = 6, fun = 14, social = 6 },
    { id = "d_lime", name = "Minted Lime Spritz", price = 7, fun = 15, social = 8 },
    { id = "d_espresso", name = "Espresso Tonic", price = 6, fun = 10, social = 4, energy = 12 },
    { id = "d_punch", name = "House Punch, One Cup", price = 4, fun = 8, social = 8 },
}

-- Park grill (a coin-operated public grill; the fee buys the kiosk's sausages and corn).
VD.picnic = { price = 10, hunger = 48, cookTime = 18, eatTime = 22, wishPrice = 1 }

---------------------------------------------------------------------------------------------------
-- Staff roles (stable venue-role identities on the visitors framework). Names are per slot index,
-- so shopkeeper #2 at a venue is always the same person. Uniform colours for art.
VD.staff = {
    shopkeeper = { label = "Shopkeeper", names = { "Opal Finch", "Rudy Marchetti", "Hester Quill", "Dev Okafor", "Wren Castellanos", "Tobias Brightwater" },
        uniform = { top = c(0.35, 0.55, 0.45), bottom = c(0.25, 0.25, 0.28), shoes = c(0.20, 0.14, 0.10) } },
    host = { label = "Host", names = { "Lionel Ashby", "Priya Holloway" },
        uniform = { top = c(0.15, 0.15, 0.18), bottom = c(0.15, 0.15, 0.18), shoes = c(0.08, 0.08, 0.08) } },
    waiter = { label = "Waiter", names = { "Bea Tran", "Sol Ferris", "Nadia Kowalczyk", "Otis Merriweather" },
        uniform = { top = c(0.95, 0.94, 0.90), bottom = c(0.12, 0.12, 0.14), shoes = c(0.10, 0.10, 0.10) } },
    cook = { label = "Cook", names = { "Marguerite Ellery", "Gus Pennington" }, skills = { cooking = 7 },
        uniform = { top = c(0.97, 0.97, 0.97), bottom = c(0.30, 0.30, 0.32), shoes = c(0.20, 0.20, 0.20) } },
    dj = { label = "DJ", names = { "Casey Spindle", "Juniper Vale" },
        uniform = { top = c(0.20, 0.15, 0.35), bottom = c(0.10, 0.10, 0.12), shoes = c(0.85, 0.20, 0.30) } },
    bartender = { label = "Bartender", names = { "Rosalind Vane", "Marcus Oyelaran" },
        uniform = { top = c(0.55, 0.18, 0.20), bottom = c(0.12, 0.12, 0.12), shoes = c(0.10, 0.10, 0.10) } },
}
VD.STAFF_LOOKS = {
    { skin = c(0.96, 0.80, 0.69), hair = c(0.30, 0.20, 0.12), hairStyle = "short" },
    { skin = c(0.55, 0.37, 0.26), hair = c(0.08, 0.06, 0.05), hairStyle = "long" },
    { skin = c(0.87, 0.67, 0.52), hair = c(0.85, 0.72, 0.40), hairStyle = "short" },
    { skin = c(0.40, 0.27, 0.19), hair = c(0.10, 0.08, 0.07), hairStyle = "short" },
    { skin = c(0.93, 0.76, 0.62), hair = c(0.55, 0.22, 0.10), hairStyle = "long" },
    { skin = c(0.72, 0.53, 0.38), hair = c(0.25, 0.25, 0.28), hairStyle = "long" },
}

---------------------------------------------------------------------------------------------------
-- Reactions: the outings module's own fallback lines, used when SS.Lines (social) has nothing for a
-- situation. Original text; {name} = the other person, {venue} = the venue, {item} = the thing.
VD.reactions = {
    date_good = { "What a lovely time. Same place next week?", "I haven't laughed like that in ages, {name}.",
        "Tonight was exactly what I needed." },
    date_ok = { "That was nice. Really, it was nice.", "Pleasant evening. Let's do it again sometime." },
    date_bad = { "I should be getting home. Early start. Very early. Possibly forever.",
        "Well. That was an evening.", "I think I left the oven on. At my house. Goodbye." },
    date_stood_up = { "Still waiting... they did say this place, didn't they?", "Stood up at {venue}. Marvellous." },
    outing_good = { "Best trip out in ages!", "{venue} was a treat." },
    outing_bad = { "Remind me why we left the house?", "Let's never speak of {venue} again." },
    venue_closed = { "{venue} is closing up. Time to head home.", "Last orders! The lights are going down at {venue}." },
    venue_wait = { "Is anybody actually working here?", "I've grown roots waiting for this table." },
    dine_good = { "Compliments to the cook!", "I'd come back just for the {item}." },
    dine_bad = { "The {item} was... an experience.", "I've had better meals out of a toaster." },
    shop_checkout = { "Bagged it. The {item} is mine!", "Worth every penny. Probably." },
    shop_broke = { "Not enough in the account for the {item}. Hmm.", "Card says no. The {item} stays here." },
    gift_good = { "For me? Oh, {name}, I love it!", "You remembered! Thank you!" },
    gift_bad = { "Oh. A {item}. How... thoughtful. Keep it, really.", "I couldn't possibly accept this, {name}." },
    wish = { "Wished for a raise. The fountain looked doubtful.", "Wished for sunshine. Fingers crossed.",
        "Wished for nothing in particular, just to be safe.", "Wished that sandal would find its owner." },
    dj = { "Coming right up, one floor-filler!", "Great choice. The crowd will thank you.", "Oh, I love this one." },
    round = { "Drinks are on me!", "A round for the table!" },
    greet_guest = { "There you are! Sorry I'm late.", "Hello again! This place looks fun." },
    host_greet = { "Welcome in! Right this way.", "Table's ready. Mind the step.", "Lovely to see you. Follow me." },
    shop_browse = { "Ooh, look at this one.", "Just looking. Mostly.", "I could spend all afternoon in here." },
}

---------------------------------------------------------------------------------------------------
-- Anchor furnishing specs used by SS.Venues.BuildLot. A catalogue definition is used when it has
-- the tag/query and the named slots (exact slot name or slot group) and fits the layout; otherwise
-- the outings system object `fallback` is placed. `seat`: needs def.seat and a "seat" slot or group.
-- `actions`: needs at least one interaction. `anchor`: the staff/service role this marks.
VD.furnish = {
    register = { tag = "register", slots = { "customer", "staff" }, fallback = "sys_register", anchor = "register", staff = "shopkeeper" },
    rack_clothing = { tag = "display_clothing", slots = { "browse" }, fallback = "sys_rack_clothing", anchor = "display" },
    changing_booth = { tag = "changing_booth", slots = { "booth" }, fallback = "sys_changing_booth", anchor = "changing_booth" },
    stand_gifts = { tag = "display_gift", slots = { "browse" }, fallback = "sys_stand_flowers", anchor = "display" },
    rack_books = { tag = "display_books", slots = { "browse" }, fallback = "sys_rack_books", anchor = "display" },
    shelf_decor = { tag = "display_decor", slots = { "browse" }, fallback = "sys_shelf_decor", anchor = "display" },
    podium = { tag = "podium", slots = { "guest", "staff" }, fallback = "sys_host_podium", anchor = "podium", staff = "host" },
    waiter_station = { tag = "waiter_station", slots = { "staff", "pickup" }, public = true, publicSlots = { "pickup" },
        fallback = "sys_waiter_station", anchor = "waiter_station", staff = "waiter" },
    kitchen = { tag = "cafe_kitchen", slots = { "cook", "pass" }, fallback = "sys_cafe_kitchen", anchor = "kitchen", staff = "cook" },
    cafe_table = { tag = "cafe_table", cells = 1, fallback = "sys_cafe_table", anchor = "cafe_table" },
    cafe_table_long = { tag = "cafe_table", cells = 2, fallback = "sys_cafe_table_long", anchor = "cafe_table" },
    dining_chair = { query = { cat = "seating", tag = "seat", maxPrice = 160 }, seat = true, fallback = "chair_dining" },
    armchair = { query = { cat = "seating", tag = "seat", minPrice = 250, maxPrice = 800 }, seat = true, fallback = "armchair_basic" },
    dj_booth = { tag = "dj_booth", slots = { "staff", "request" }, fallback = "sys_dj_booth", anchor = "dj_booth", staff = "dj" },
    bar = { tag = "bar", slots = { "staff", "patron" }, fallback = "sys_bar", anchor = "bar", staff = "bartender" },
    dance = { fallback = "sys_dance_light", anchor = "dance" },
    pool_table = { tag = "pool_table", activity = "venue_pool", fallback = "sys_pool_table", anchor = "games" },
    darts = { tag = "darts", activity = "venue_darts", fallback = "sys_dartboard", anchor = "games" },
    chess = { tag = "chess", activity = "venue_chess", fallback = "sys_park_chess", anchor = "recreation" },
    playground = { tag = "kid_play", activity = "venue_play", cells = 6, fallback = "sys_playground", anchor = "recreation" },
    grill = { fallback = "sys_park_grill", anchor = "grill" },
    picnic_table = { fallback = "sys_picnic_table", anchor = "picnic" },
    picnic_seat = { fallback = "sys_picnic_seat" },
    bench = { query = { cat = "seating", sub = "bench" }, seat = true, fallback = "sys_public_bench", anchor = "seating" },
    stool = { query = { cat = "seating", sub = "stool" }, seat = true, fallback = "sys_bar_stool", anchor = "seating" },
    cocktail = { fallback = "sys_cocktail_table", anchor = "party" },
    stall = { tag = "restroom", slots = { "seat" }, actions = true, fallback = "sys_restroom_stall", anchor = "restroom" },
    basin = { tag = "basin", actions = true, cells = 1, fallback = "sink_pedestal" },
    tree = { tag = "tree", cells = 1, fallback = "sys_park_tree" },
    shrub = { tag = "shrub", cells = 1, fallback = "sys_park_shrub" },
    flowers = { tag = "flowers", cells = 1, fallback = "sys_flowerbed" },
    lamp_post = { query = { cat = "lighting", sub = "outdoor" }, cells = 1, fallback = "sys_lamp_post" },
    lamp = { query = { cat = "lighting", tag = "lamp" }, cells = 1, fallback = "lamp_floor" },
    plant = { query = { cat = "decor", sub = "plant" }, cells = 1, fallback = "plant_pot" },
    bin = { tag = "bin_outdoor", cells = 1, fallback = "sys_public_bin" },
    fountain = { fallback = "sys_park_fountain", anchor = "fountain" },
    payphone = { fallback = "sys_payphone", anchor = "payphone" },
    sign = { fallback = "sys_venue_sign" },
    menu_board = { fallback = "sys_menu_board" },
    pastry = { fallback = "sys_pastry_case" },
    prep_counter = { query = { cat = "kitchen", tag = "counter" }, cells = 1, fallback = "counter_basic" },
}

-- What each venue needs to be valid: anchor kind -> minimum count (checked with reachability).
VD.required = {
    shops = { register = 4, display_clothing = 1, display_gift = 1, display_books = 1, display_decor = 1, changing_booth = 1, restroom = 1, seating = 2 },
    cafe = { podium = 1, waiter_station = 1, kitchen = 1, cafe_table = 3, dining_seat = 6, restroom = 1 },
    park = { seating = 4, picnic = 1, grill = 1, restroom = 1, recreation = 2, landscaping = 6 },
    club = { dj_booth = 1, dance = 1, games = 2, bar = 1, seating = 4, party = 2, restroom = 1 },
}

---------------------------------------------------------------------------------------------------
-- System objects (ARCHITECTURE.md §9.13): functional community anchors the outings module owns.
-- buyable = false, cat = "system": they never count toward the 168 catalogue designs and are not
-- sold in buy mode. Venue editing keeps or restores them (SS.Venues.RestoreAnchors).
local FRONT = { approaches = { { 0, 1 } }, face = 2 }
local SEAT4 = { approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }, face = 0, on = true }
local function browse2()
    return {
        browse1 = { approaches = { { 0, 1 } }, face = 2, group = "browse" },
        browse2 = { approaches = { { 1, 1 } }, face = 2, group = "browse" },
    }
end
local TWO = { { 0, 0 }, { 1, 0 } }

local sys = {
    sys_register = {
        name = "Courtyard Till Counter", fp = { { 0, 0 } }, env = 1, height = 0.9, tags = { "register" },
        desc = "A counter, a cash drawer and a bell that the shopkeeper pretends not to hear the third time.",
        slots = {
            customer = { approaches = { { 0, 1 } }, face = 2 },
            line1 = { approaches = { { 0, 2 } }, face = 2, group = "line" },
            line2 = { approaches = { { 1, 2 } }, face = 2, group = "line" },
            staff = { approaches = { { 0, -1 } }, face = 0, staff = true },
        },
        actions = {},
    },
    sys_rack_clothing = {
        name = "Outfit Rail", fp = TWO, env = 2, tags = { "display_clothing" },
        desc = "Two metres of hangers arranged by colour, then by optimism.",
        slots = browse2(), actions = {}, startState = { full = true },
    },
    sys_changing_booth = {
        name = "Changing Booth", fp = { { 0, 0 } }, env = 1, privacy = true, tags = { "changing_booth" },
        desc = "A curtained booth with a mirror that is kinder than most.",
        slots = { booth = { approaches = { { 0, 1 } }, face = 0, on = true } }, actions = {},
    },
    sys_stand_flowers = {
        name = "Flower and Gift Stand", fp = TWO, env = 4, tags = { "display_gift" },
        desc = "Buckets of blooms on the left, small ribboned boxes on the right, a faint smell of lilies everywhere.",
        slots = browse2(), actions = {}, startState = { full = true },
    },
    sys_rack_books = {
        name = "Book and Magazine Rack", fp = TWO, env = 2, tags = { "display_books" },
        desc = "Paperbacks up top, magazines below, and a stool nobody is allowed to read on.",
        slots = browse2(), actions = {}, startState = { full = true },
    },
    sys_shelf_decor = {
        name = "Home Goods Shelving", fp = TWO, env = 3, tags = { "display_decor" },
        desc = "Vases, lamps and small furniture, each with a price tag tied on with string.",
        slots = browse2(), actions = {}, startState = { full = true },
    },
    sys_host_podium = {
        name = "Host Stand", fp = { { 0, 0 } }, env = 1, tags = { "podium" },
        desc = "A lectern with the seating chart, three pencils and a small bell for emergencies involving gravy.",
        slots = {
            guest1 = { approaches = { { 0, 1 } }, face = 2, group = "guest" },
            guest2 = { approaches = { { -1, 1 } }, face = 2, group = "guest" },
            guest3 = { approaches = { { 1, 1 } }, face = 2, group = "guest" },
            staff = { approaches = { { 0, -1 } }, face = 0, staff = true },
        },
        actions = {},
    },
    sys_waiter_station = {
        name = "Waiter Station", fp = { { 0, 0 } }, env = 0, height = 0.9, tags = { "waiter_station" },
        desc = "Order pads, clean cutlery and the little tray that carries everyone's hopes.",
        slots = {
            staff = { approaches = { { 0, -1 } }, face = 0, staff = true },
            pickup1 = { approaches = { { 0, 1 } }, face = 2, group = "pickup" },
            pickup2 = { approaches = { { 1, 1 } }, face = 2, group = "pickup" },
        },
        actions = {},
    },
    sys_cafe_kitchen = {
        name = "Cafe Range and Prep Line", fp = TWO, env = 0, height = 0.9, staffOnly = true, tags = { "cafe_kitchen" },
        desc = "Six burners, a flat-top and a ticket rail that is never, ever empty at lunchtime.",
        slots = {
            cook = { approaches = { { 0, 1 } }, face = 2, staff = true },
            pass = { approaches = { { 1, 1 } }, face = 2, staff = true },
        },
        actions = {}, startState = { on = false },
    },
    sys_cafe_table = {
        name = "Bistro Table for Two", fp = { { 0, 0 } }, env = 2, height = 0.75, tags = { "cafe_table" },
        surfaces = { { cell = { 0, 0 }, z = 0.75, kind = "table", slots = 2 } },
        desc = "Round, marble-topped and exactly one elbow too small for two people with opinions.",
        slots = {}, actions = {},
    },
    sys_cafe_table_long = {
        name = "Four-Top Dining Table", fp = TWO, env = 2, height = 0.75, tags = { "cafe_table" },
        surfaces = { { cell = { 0, 0 }, z = 0.75, kind = "table", slots = 2 }, { cell = { 1, 0 }, z = 0.75, kind = "table", slots = 2 } },
        desc = "Seats four, or three and a coat.",
        slots = {}, actions = {},
    },
    sys_dj_booth = {
        name = "DJ Booth", fp = TWO, env = 3, tags = { "dj_booth" },
        desc = "Two turntables, one microphone and a crate of records sorted by how loudly people cheer.",
        slots = {
            staff = { approaches = { { 1, -1 } }, face = 0, staff = true },
            request = { approaches = { { 0, 1 } }, face = 2 },
        },
        actions = {}, startState = { on = false },
    },
    sys_dance_light = {
        name = "Dance Floor Light Column", fp = { { 0, 0 } }, env = 3, light = 0.6, tags = {}, venueUse = "dance",
        desc = "A column of coloured bulbs that marks the dance floor and flatters everyone on it.",
        slots = {}, actions = {}, startState = { on = false },
    },
    sys_bar = {
        name = "Juice Bar Counter", fp = { { 0, 0 }, { 1, 0 }, { 2, 0 } }, env = 3, height = 1.0, tags = { "bar" },
        desc = "Polished wood, chrome taps of fizzy things and a bartender who remembers your order and your excuses.",
        slots = {
            staff = { approaches = { { 1, -1 } }, face = 0, staff = true },
            patron1 = { approaches = { { 0, 1 } }, face = 2, group = "patron" },
            patron2 = { approaches = { { 1, 1 } }, face = 2, group = "patron" },
            patron3 = { approaches = { { 2, 1 } }, face = 2, group = "patron" },
        },
        actions = {},
    },
    sys_pool_table = {
        name = "Club Pool Table", fp = TWO, env = 2, tags = {}, venueUse = "pool",
        desc = "Green felt, two cues with slightly different personalities and a pocket that eats the eight ball.",
        slots = {
            player1 = { approaches = { { -1, 0 } }, face = 3, group = "player" },
            player2 = { approaches = { { 2, 0 } }, face = 1, group = "player" },
        },
        actions = {},
    },
    sys_dartboard = {
        name = "Dartboard Stand", fp = { { 0, 0 } }, env = 1, tags = {}, venueUse = "darts",
        desc = "A cork board on a sturdy stand, pocked with the evidence of confident beginners.",
        slots = {
            thrower1 = { approaches = { { 0, 2 } }, face = 2, group = "thrower" },
            thrower2 = { approaches = { { 1, 2 } }, face = 2, group = "thrower" },
        },
        actions = {},
    },
    sys_cocktail_table = {
        name = "Tall Mingling Table", fp = { { 0, 0 } }, env = 2, height = 1.05, tags = {}, venueUse = "mingle",
        desc = "Elbow height, drink sized and perfect for conversations that need to end politely.",
        slots = {
            spot1 = { approaches = { { 0, 1 } }, face = 2, group = "mingle" },
            spot2 = { approaches = { { 1, 0 } }, face = 1, group = "mingle" },
            spot3 = { approaches = { { 0, -1 } }, face = 0, group = "mingle" },
            spot4 = { approaches = { { -1, 0 } }, face = 3, group = "mingle" },
        },
        actions = {},
    },
    sys_park_grill = {
        name = "Coin-Op Park Grill", fp = { { 0, 0 } }, env = 0, tags = {}, venueUse = "grill",
        desc = "Drop a coin in the kiosk box and the council's finest sausages appear, along with some corn.",
        slots = { cook = FRONT }, actions = {}, startState = { on = false },
    },
    sys_picnic_table = {
        name = "Picnic Table", fp = TWO, env = 2, height = 0.75, tags = {}, venueUse = "picnic",
        surfaces = { { cell = { 0, 0 }, z = 0.75, kind = "table", slots = 2 }, { cell = { 1, 0 }, z = 0.75, kind = "table", slots = 2 } },
        desc = "Weathered planks carved with initials, hearts and one arithmetic problem.",
        slots = {}, actions = {},
    },
    sys_picnic_seat = {
        name = "Picnic Bench Seat", fp = { { 0, 0 } }, env = 0, seat = true, rates = { comfort = 12 }, ratings = { comfort = 3 },
        desc = "Half a bench, bolted down in case anyone gets ideas.", tags = { "seat" },
        slots = { seat = SEAT4 }, actions = { "sit" },
    },
    sys_park_chess = {
        name = "Stone Chess Table", fp = { { 0, 0 } }, env = 2, tags = {}, venueUse = "chess",
        desc = "A chessboard set into granite. The pieces are chained on, which says a lot about the neighbourhood.",
        slots = {
            player1 = { approaches = { { 0, 1 } }, face = 2, group = "player" },
            player2 = { approaches = { { 0, -1 } }, face = 0, group = "player" },
        },
        actions = {},
    },
    sys_playground = {
        name = "Climbing Frame and Slide", fp = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } }, env = 4,
        tags = {}, venueUse = "play",
        desc = "Ladders, a rope bridge and a slide that is faster than it looks, on purpose.",
        slots = {
            play1 = { approaches = { { -1, 0 } }, face = 3, group = "play" },
            play2 = { approaches = { { -1, 1 } }, face = 3, group = "play" },
            play3 = { approaches = { { 3, 0 } }, face = 1, group = "play" },
            play4 = { approaches = { { 3, 1 } }, face = 1, group = "play" },
            play5 = { approaches = { { 1, 2 } }, face = 2, group = "play" },
            play6 = { approaches = { { 1, -1 } }, face = 0, group = "play" },
        },
        actions = {},
    },
    sys_park_fountain = {
        landscape = true, name = "Hollyhock Fountain", fp = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }, env = 12, tags = {}, venueUse = "fountain",
        desc = "Three tiers of splashing water and a basin full of coins, wishes and one sandal.",
        slots = {
            edge1 = { approaches = { { 0, 2 } }, face = 2, group = "edge" },
            edge2 = { approaches = { { 1, 2 } }, face = 2, group = "edge" },
            edge3 = { approaches = { { -1, 0 } }, face = 3, group = "edge" },
            edge4 = { approaches = { { 2, 1 } }, face = 1, group = "edge" },
        },
        actions = {}, startState = { on = true },
    },
    sys_public_bench = {
        name = "Slatted Park Bench Seat", fp = { { 0, 0 } }, env = 1, seat = true, rates = { comfort = 15 }, ratings = { comfort = 3 },
        desc = "Green slats, a small brass plaque and a view of other people's lives.", tags = { "seat" },
        slots = { seat = SEAT4 }, actions = { "sit" },
    },
    sys_bar_stool = {
        name = "Chrome Bar Stool", fp = { { 0, 0 } }, env = 1, seat = true, rates = { comfort = 12 }, ratings = { comfort = 3 },
        desc = "Spins a full circle, which is at least one more circle than anyone needs.", tags = { "seat" },
        slots = { seat = SEAT4 }, actions = { "sit" },
    },
    sys_restroom_stall = {
        name = "Public Restroom Stall", fp = { { 0, 0 } }, env = 0, privacy = true, tags = { "restroom", "toilet" },
        desc = "A clean stall with a lock that works on the second try.",
        slots = { seat = { approaches = { { 0, 1 } }, face = 0, on = true } }, actions = { "toilet" },
    },
    sys_lamp_post = {
        name = "Iron Lamp Post", fp = { { 0, 0 } }, env = 2, light = 1, tags = {},
        desc = "Keeps the path lit and the moths busy.", slots = {}, actions = {}, startState = { on = true },
    },
    sys_park_tree = {
        landscape = true, name = "Shade Maple", fp = { { 0, 0 } }, env = 6, tags = {},
        desc = "Planted by the council, climbed by everybody else.", slots = {}, actions = {},
    },
    sys_park_shrub = {
        landscape = true, name = "Clipped Box Hedge", fp = { { 0, 0 } }, env = 3, tags = {},
        desc = "Trimmed into a ball by a gardener with a steady hand and a lot of free time.", slots = {}, actions = {},
    },
    sys_flowerbed = {
        landscape = true, name = "Council Flower Bed", fp = { { 0, 0 } }, env = 5, tags = {},
        desc = "Seasonal bedding in cheerful rows, weeded by volunteers every other Tuesday.", slots = {}, actions = {},
    },
    sys_public_bin = {
        name = "Public Litter Bin", fp = { { 0, 0 } }, env = 0, tags = {},
        desc = "Painted green, emptied daily, largely ignored by the pigeons.", slots = {}, actions = {},
    },
    sys_payphone = {
        name = "Public Payphone", fp = { { 0, 0 } }, env = 0, tags = {}, venueUse = "payphone",
        desc = "A payphone with the taxi company's number scratched helpfully into the paint.",
        slots = { front = FRONT }, actions = {},
    },
    sys_venue_sign = {
        name = "Venue Sign", fp = { { 0, 0 } }, env = 2, tags = {},
        desc = "Painted letters on a post: the name of the place, in case the smell of coffee was not enough.",
        slots = {}, actions = {},
    },
    sys_menu_board = {
        name = "Chalk Menu Board", fp = { { 0, 0 } }, env = 2, tags = {},
        desc = "Today's specials in cheerful chalk. The spelling of 'croissant' changes daily.",
        slots = {}, actions = {},
    },
    sys_pastry_case = {
        name = "Pastry Display Case", fp = { { 0, 0 } }, env = 3, height = 1.0, tags = {},
        desc = "Glass-fronted and full of things that are best described as 'glazed'.",
        slots = {}, actions = {},
    },
}

-- The dance light's dancer slots: a 3 x 3 floor in front of the column.
do
    local s = sys.sys_dance_light.slots
    local n = 0
    for dy = 1, 3 do
        for dx = -1, 1 do
            n = n + 1
            s["dancer" .. n] = { approaches = { { dx, dy } }, face = 2, group = "dancer" }
        end
    end
end

for id, def in pairs(sys) do
    def.cat, def.buyable, def.community, def.price = "system", false, true, 0
    def.style = def.style or "garden"
    def.outings = true
    SS.Objects[id] = def
    if SS.Tags and SS.Tags.Apply then SS.Tags.Apply(def) end
end
VD.SYSTEM_OBJECTS = {}
for id in pairs(sys) do VD.SYSTEM_OBJECTS[#VD.SYSTEM_OBJECTS + 1] = id end
table.sort(VD.SYSTEM_OBJECTS)
