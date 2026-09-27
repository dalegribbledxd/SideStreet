-- Buy-mode catalogue: Interior Decoration (brief §8.1: at least 24 designs).
-- Owner: catalogue module. Decoration works through env (added to the room score in
-- World.RoomScore, which feeds the Room need). Tags: painting and book (household-core: view /
-- read), rug (household-core), fireplace (events: sparks and fire risk). Rugs lie flat,
-- never block walking, sit under furniture and layer over each other. Curtains and blinds mount on
-- a window; paintings, posters, clocks and hangings on a solid wall; small pieces on surfaces.
-- appreciates = true (original art from §900): sells for what was paid, never depreciated
-- (careers' SS.Economy.ResaleValue and Placement's fallback both read it).
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("decor")
local var = K.var
local TOPS = { "table", "desk", "counter", "shelf", "end" }
local function art(def)
    def.mount = def.mount or "wall"
    def.tags = def.tags or { "painting" }
    def.slots = def.slots or { view = { approaches = { { 0, 1 }, { 0, 2 } }, face = 2, pose = "idle" } }
    def.rooms = def.rooms or { "living", "dining", "bedroom", "study" }
    def.sub = def.sub or "art"
    return def
end

add("plant_pot", { -- original 0.1.0 object
    name = "Potted Fiddle Fern", sub = "plant", style = "starter", material = "plant", price = 45, env = 10,
    rooms = { "living", "bedroom", "bathroom", "kitchen", "study" }, height = 1.0,
    desc = "Makes any room feel lived in, mainly by the fern. A cheap, cheerful lift for the room score that never needs watering.",
    variants = var("terracotta:Terracotta Pot:0.76,0.42,0.28", "white:White Pot:0.96,0.96,0.95", "blue:Blue Glaze:0.24,0.40,0.66"),
})

add("plant_rubber", {
    name = "Rubber Plant in Terracotta", sub = "plant", style = "traditional", material = "plant", price = 120, env = 12,
    rooms = { "living", "study", "dining" }, height = 1.6,
    desc = "Glossy leaves the size of dinner plates on a plant too stubborn to die. Tall, dark green and reliably good for a room.",
    variants = var("terracotta:Terracotta:0.76,0.42,0.28", "brass:Brass Planter:0.84,0.68,0.34", "black:Black Planter:0.14,0.14,0.15"),
})

add("plant_palm", {
    name = "Parlour Palm", sub = "plant", style = "eclectic", material = "plant", price = 260, env = 14,
    rooms = { "living", "dining" }, height = 2.1,
    desc = "Arching fronds in a wicker basket, bringing a hotel-lobby calm to any corner. One of the best room-score boosts under three hundred.",
    variants = var("wicker:Wicker Basket:0.84,0.70,0.46", "white:White Ceramic:0.96,0.96,0.95", "jade:Jade Ceramic:0.36,0.64,0.52"),
})

add("plant_cactus", {
    name = "Windowsill Cactus", sub = "plant", style = "starter", material = "plant", price = 20, env = 4,
    rooms = { "kitchen", "bedroom", "study", "bathroom" }, mount = "surface", fits = TOPS, height = 0.3,
    desc = "A small cactus in a painted pot that asks nothing of anyone, which makes it the best-adjusted member of most households. Goes on any surface.",
    variants = var("red:Red Pot:0.76,0.24,0.20", "yellow:Yellow Pot:0.96,0.84,0.36", "blue:Blue Pot:0.28,0.46,0.74"),
})

add("plant_orchid", {
    name = "Orchid in Glazed Pot", sub = "plant", style = "contemporary", material = "plant", price = 140, env = 7,
    rooms = { "living", "bathroom", "bedroom", "dining" }, mount = "surface", fits = TOPS, height = 0.6,
    desc = "A single arching stem of white blooms that makes a side table look professionally styled. Elegant, compact and quietly smug.",
    variants = var("white:White Blooms:0.97,0.96,0.96", "magenta:Magenta Blooms:0.84,0.26,0.60", "yellow:Yellow Blooms:0.96,0.86,0.40"),
})

add("poster_band", art({
    name = "Tour Poster, Loud Band", style = "eclectic", material = "paper", price = 40, env = 4,
    rooms = { "bedroom", "kids", "living" }, height = 1.8,
    desc = "A curling poster for a band whose name is mostly exclamation marks. Hangs on a wall and adds a little personality for pocket money.",
    variants = var("red:Red Print:0.84,0.20,0.16", "neon:Neon Print:0.40,0.96,0.40", "mono:Black & White:0.20,0.20,0.20"),
}))

add("poster_travel", art({
    name = "Retro Travel Poster", style = "contemporary", material = "paper", price = 75, env = 5, height = 1.8,
    desc = "A framed print of a seaside resort drawn in four flat colours and one heroic seagull. Cheap wall art with holiday optimism baked in.",
    variants = var("seaside:Seaside:0.36,0.66,0.84", "mountain:Mountains:0.46,0.60,0.44", "city:City Lights:0.30,0.24,0.46"),
}))

add("painting_landscape", art({
    name = "Pastoral Hills Oil Painting", style = "traditional", material = "fabric", price = 400, env = 10, height = 1.9,
    desc = "Rolling green hills, one contented cow and a sky with ambitions. A gilt-framed oil that makes any room feel ten percent more inherited.",
    variants = var("gilt:Gilt Frame:0.86,0.70,0.40", "walnut:Walnut Frame:0.42,0.28,0.18", "black:Black Frame:0.14,0.14,0.15"),
}))

add("painting_abstract", art({
    name = "Primary Squares Abstract", style = "contemporary", material = "fabric", price = 1200, env = 15, height = 2.0, appreciates = true,
    desc = "Three rectangles in red, blue and yellow, arranged with a confidence that costs extra. Visitors will say they could have done it; they did not. Original art keeps its full value if you ever sell it.",
    variants = var("primary:Primary:0.84,0.20,0.20", "pastel:Pastel:0.90,0.76,0.80", "mono:Monochrome:0.40,0.40,0.40"),
}))

add("painting_portrait", art({
    name = "Portrait of a Stern Ancestor", style = "traditional", material = "fabric", price = 2400, env = 18, height = 2.1, appreciates = true,
    desc = "A gentleman in a ruff who disapproves of everything that has happened since he was painted. Excellent for the room score and for ending arguments early, and he sells for what you paid.",
    variants = var("gilt:Heavy Gilt:0.86,0.70,0.40", "ebony:Ebony Frame:0.14,0.12,0.11", "silver:Silver Leaf:0.82,0.84,0.86"),
}))

add("painting_masterwork", art({
    name = "The Great Picnic Masterpiece", style = "eclectic", material = "fabric", price = 5000, env = 25, fp = K.rect(2, 1), height = 2.2, appreciates = true,
    desc = "A wall-wide canvas of a family picnic in which every face is plotting something. The single greatest room-score boost in the catalogue, spanning two wall sections, and it never loses value.",
    slots = { view = { approaches = { { 0, 1 }, { 1, 1 }, { 0, 2 }, { 1, 2 } }, face = 2, pose = "idle" } },
    variants = var("gilt:Museum Gilt:0.86,0.70,0.40", "white:Gallery White:0.96,0.96,0.95", "black:Gallery Black:0.14,0.14,0.15"),
}))

add("rug_rag", {
    name = "Braided Rag Rug", sub = "rug", style = "starter", material = "fabric", price = 35, env = 3,
    rooms = { "kitchen", "bedroom", "living", "bathroom" }, height = 0.02, rug = true,
    desc = "Old shirts braided into a round rug by someone with patience and a surplus of plaid. Warms up a floor tile; layers happily under furniture.",
    tags = { "rug" },
    variants = var("plaid:Plaid Mix:0.66,0.32,0.28", "blue:Denim Mix:0.34,0.44,0.62", "earth:Earth Mix:0.62,0.50,0.36"),
})

add("rug_shag", {
    name = "Shag Pile Rug", sub = "rug", style = "eclectic", material = "fabric", price = 180, env = 6,
    rooms = { "living", "bedroom" }, fp = K.rect(2, 1), height = 0.03, rug = true,
    desc = "Long fibres in a colour last fashionable when the house was built, and fashionable again now. Two cells of deep, toe-swallowing texture.",
    tags = { "rug" },
    variants = var("orange:Burnt Orange:0.86,0.46,0.18", "avocado:Avocado:0.56,0.62,0.30", "cream:Cream:0.94,0.90,0.80"),
})

add("rug_geometric", {
    name = "Geometric Wool Rug", sub = "rug", style = "contemporary", material = "fabric", price = 420, env = 9,
    rooms = { "living", "dining", "study" }, fp = K.rect(2, 2), height = 0.02, rug = true,
    desc = "Hand-tufted triangles in grey, ochre and teal that make the sofa look deliberate. Four cells of floor turned into a design decision.",
    tags = { "rug" },
    variants = var("ochre:Ochre & Teal:0.80,0.62,0.26", "grey:Grey & Blush:0.66,0.62,0.64", "navy:Navy & White:0.18,0.22,0.40"),
})

add("rug_persian", {
    name = "Heirloom Medallion Rug", sub = "rug", style = "traditional", material = "fabric", price = 900, env = 12,
    rooms = { "living", "dining", "study", "bedroom" }, fp = K.rect(2, 2), height = 0.02, rug = true,
    desc = "A dense wool rug with a central medallion and borders so intricate they have their own plot. Four cells of real presence; spills become family legends.",
    tags = { "rug" },
    variants = var("red:Madder Red:0.62,0.16,0.14", "blue:Indigo:0.18,0.22,0.46", "ivory:Ivory:0.92,0.88,0.78"),
})

add("curtains_basic", {
    name = "Gingham Cafe Curtains", sub = "window", style = "starter", material = "fabric", price = 40, env = 3,
    rooms = { "kitchen", "bathroom", "bedroom", "living" }, mount = "window", height = 1.5,
    desc = "Half-height checked curtains on a tension rod, for privacy at breakfast and a hint of country in the kitchen. Fits any window.",
    variants = var("red:Red Check:0.84,0.30,0.28", "blue:Blue Check:0.40,0.54,0.80", "yellow:Yellow Check:0.96,0.84,0.40"),
})

add("curtains_velvet", {
    name = "Velvet Drape Curtains", sub = "window", style = "traditional", material = "fabric", price = 260, env = 6,
    rooms = { "living", "bedroom", "dining" }, mount = "window", height = 2.2,
    desc = "Floor-length velvet with tasselled tie-backs, heavy enough to muffle a brass band. Dresses any window in theatrical grandeur.",
    variants = var("crimson:Crimson:0.60,0.10,0.14", "emerald:Emerald:0.10,0.40,0.24", "gold:Old Gold:0.80,0.64,0.26"),
})

add("blinds", {
    name = "Slatted Venetian Blinds", sub = "window", style = "contemporary", material = "wood", price = 70, env = 2,
    rooms = { "study", "kitchen", "bathroom", "bedroom", "living" }, mount = "window", height = 2.1,
    desc = "Aluminium slats that tilt open for light and closed for privacy, and gather dust at both angles. Neat, modern and fits any window.",
    variants = var("white:White:0.96,0.96,0.95", "silver:Silver:0.80,0.82,0.84", "wood:Wood Slat:0.72,0.52,0.30"),
})

add("sculpture_bust", {
    name = "Marble Bust of Nobody in Particular", sub = "sculpture", style = "traditional", material = "stone", price = 900, env = 14, appreciates = true,
    rooms = { "living", "study", "dining" }, height = 1.7,
    desc = "A noble marble head on a fluted pedestal, sculpted from a model the workshop swears was not the foreman. Instant gravitas, a strong room score and a resale price that never drops.",
    variants = var("white:White Marble:0.94,0.94,0.92", "bronze:Bronze:0.62,0.44,0.26", "black:Black Marble:0.16,0.16,0.17"),
})

add("sculpture_modern", {
    name = "Twisted Chrome Sculpture", sub = "sculpture", style = "contemporary", material = "chrome", price = 1600, env = 17, appreciates = true,
    rooms = { "living", "dining" }, height = 1.8,
    desc = "A ribbon of polished steel knotted into a shape critics describe as either hope or plumbing. Reflects the whole room back at itself, improved, and holds its price like a collector's piece.",
    variants = var("chrome:Chrome:0.86,0.88,0.90", "gold:Gold:0.90,0.74,0.34", "red:Red Enamel:0.76,0.14,0.14"),
})

add("figurine_cat", {
    name = "Ceramic Cat Figurine", sub = "sculpture", style = "eclectic", material = "ceramic", price = 55, env = 4,
    rooms = { "living", "bedroom", "kitchen" }, mount = "surface", fits = TOPS, height = 0.35,
    desc = "A glazed cat sitting with its tail wrapped round its paws, radiating judgement at a very reasonable price. Goes on any shelf or table.",
    variants = var("ginger:Ginger:0.90,0.56,0.24", "black:Black:0.14,0.14,0.15", "blue:Willow Blue:0.40,0.56,0.80"),
})

add("clock_grandfather", {
    name = "Longcase Grandfather Clock", sub = "clock", style = "traditional", material = "wood", price = 1300, env = 12,
    rooms = { "living", "dining", "study" }, height = 2.2,
    desc = "A tall oak case with a brass pendulum and a face that has outlasted three owners. A dignified room-score piece; it keeps time better than the residents.",
    variants = var("oak:Oak:0.72,0.52,0.30", "mahogany:Mahogany:0.42,0.16,0.10", "black:Ebonised:0.14,0.12,0.11"),
})

add("clock_wall", {
    name = "Kitchen Wall Clock", sub = "clock", style = "starter", material = "plastic", price = 35, env = 2,
    rooms = { "kitchen", "dining", "study" }, mount = "wall", height = 1.9,
    desc = "A round clock with big numbers, readable from across the kitchen while the toast burns. Cheap, cheerful and honest about lateness.",
    variants = var("white:White:0.96,0.96,0.95", "red:Red:0.76,0.16,0.16", "chrome:Chrome:0.84,0.86,0.88"),
})

add("clock_cuckoo", {
    name = "Carved Cuckoo Clock", sub = "clock", style = "eclectic", material = "wood", price = 220, env = 6,
    rooms = { "living", "kitchen", "dining" }, mount = "wall", height = 2.0,
    desc = "A carved chalet with pine-cone weights and a small wooden bird waiting behind a tiny door for its moment. Pure charm for the room score.",
    variants = var("walnut:Walnut:0.42,0.28,0.18", "painted:Painted Alpine:0.72,0.30,0.24", "white:White:0.94,0.94,0.92"),
})

add("vase_bud", {
    name = "Bud Vase with Daisy", sub = "clutter", style = "starter", material = "glass", price = 30, env = 3,
    rooms = { "kitchen", "dining", "bedroom", "living" }, mount = "surface", fits = TOPS, height = 0.3,
    desc = "One slender glass vase, one daisy and one small burst of cheer on a table or sill. The cheapest way to make a surface look cared for.",
    variants = var("clear:Clear Glass:0.86,0.92,0.94", "blue:Blue Glass:0.30,0.46,0.80", "amber:Amber Glass:0.86,0.58,0.20"),
})

add("vase_floor", {
    name = "Tall Floor Vase with Reeds", sub = "clutter", style = "eclectic", material = "ceramic", price = 220, env = 7,
    rooms = { "living", "dining" }, height = 1.4,
    desc = "A waist-high glazed urn bristling with dried reeds that rustle meaningfully when anyone walks past. Fills an empty corner with style.",
    variants = var("teal:Teal Glaze:0.20,0.54,0.56", "sand:Sand Glaze:0.86,0.78,0.62", "black:Black Glaze:0.14,0.14,0.15"),
})

add("books_stack", {
    name = "Stack of Unread Classics", sub = "clutter", style = "traditional", material = "paper", price = 25, env = 2,
    rooms = { "living", "study", "bedroom" }, mount = "surface", fits = TOPS, height = 0.25,
    desc = "Five weighty novels with uncracked spines, chosen for the colour of their covers. Residents can actually read them, which will surprise the previous owner.",
    slots = { front = K.around("read") }, tags = { "book" },
    variants = var("classic:Classic Cloth:0.46,0.22,0.18", "paper:Paperbacks:0.86,0.66,0.40", "leather:Leather Bound:0.36,0.20,0.12"),
})

add("clutter_magazines", {
    name = "Fanned Magazine Pile", sub = "clutter", style = "contemporary", material = "paper", price = 15, env = 1,
    rooms = { "living", "bathroom" }, mount = "surface", fits = TOPS, height = 0.05,
    desc = "Glossy magazines arranged in a casual fan that took eleven minutes to get right. Makes a coffee table look lived on in the good way.",
    variants = var("glossy:Glossy Mix:0.90,0.60,0.60", "interiors:Interiors:0.80,0.80,0.74", "gardening:Gardening:0.50,0.70,0.44"),
})

add("tapestry", {
    name = "Woven Wall Tapestry", sub = "hanging", style = "eclectic", material = "fabric", price = 350, env = 8,
    rooms = { "living", "bedroom" }, mount = "wall", fp = K.rect(2, 1), height = 2.0,
    desc = "A two-section wall hanging of a stag, a moon and something that may be a tax inspector. Warms a big blank wall and absorbs a surprising amount of echo.",
    variants = var("forest:Forest:0.26,0.40,0.26", "sunset:Sunset:0.86,0.50,0.30", "indigo:Indigo:0.22,0.26,0.50"),
})

add("hanging_macrame", {
    name = "Macrame Owl Hanging", sub = "hanging", style = "eclectic", material = "fabric", price = 60, env = 4,
    rooms = { "living", "bedroom", "kitchen" }, mount = "wall", height = 1.8,
    desc = "Knotted jute in the shape of an owl with wooden-bead eyes, made during a very long winter. Homely, inexpensive and faintly watchful.",
    variants = var("natural:Natural Jute:0.86,0.76,0.58", "white:White Cotton:0.96,0.96,0.94", "rust:Rust Dye:0.70,0.36,0.22"),
})

add("fireplace", {
    name = "Fieldstone Fireplace", sub = "fireplace", style = "traditional", material = "stone", price = 1500, env = 14,
    rooms = { "living", "dining" }, fp = K.rect(2, 1), height = 2.2, wallBack = true,
    desc = "A hearth of rough fieldstone with an oak mantel, built against a wall. A cosy centrepiece; an open fire carries a real fire risk, so keep a smoke alarm nearby.",
    slots = { front = K.frontWide(2, "use") }, tags = { "fireplace" },
    surfaces = K.surf("shelf", 1.3, 2, 1, 1),
    variants = var("fieldstone:Fieldstone:0.62,0.58,0.52", "brick:Red Brick:0.66,0.30,0.22", "white:Whitewashed:0.92,0.90,0.86"),
})

add("fireplace_gas", {
    name = "Glass-Front Gas Fire", sub = "fireplace", style = "contemporary", material = "metal", price = 1200, env = 10,
    rooms = { "living", "bedroom" }, fp = K.rect(2, 1), height = 1.2, wallBack = true, powered = true,
    desc = "A sealed glass firebox with a ribbon of blue-gold flame and a remote control. The glow of a hearth in a slimmer, cheaper box: no mantel and no ash, but a fire all the same.",
    slots = { front = K.frontWide(2, "use") }, tags = { "fireplace" },
    quality = { breakChance = 0.002, repairDifficulty = 5 },
    variants = var("black:Black Surround:0.14,0.14,0.15", "white:White Surround:0.96,0.96,0.95", "steel:Steel Surround:0.78,0.80,0.82"),
})
