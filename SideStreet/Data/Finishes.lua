-- SideStreet build catalogues: floor and wall finishes, doors, windows, roofs, fences (with gates),
-- railings, terrain paints, and the three staircase object definitions.
-- Owner: catalogue module (data). Build mode (Sim/Build.lua, build module) places them; the art
-- module renders them from the `look` descriptor. Notes: docs/modules/catalogue.md.
--
-- Every entry: id (map key), name, price, style (starter|traditional|contemporary|eclectic|garden),
-- desc (one original line), look = the procedural visual descriptor of docs/ART.md section 3 (art module):
--   pattern  per kind: F.FLOOR_PATTERNS, F.WALL_PATTERNS, F.TERRAIN_PATTERNS, F.ROOF_PATTERNS
--            (doors, windows, fences, gates and railings are drawn per style id; their look
--            pattern is one of F.PIECE_PATTERNS and describes the main material)
--   color    main colour {r,g,b} 0..1
--   color2   accent as ART.md defines it per pattern: grout (tiles, tile, hex, mosaic, cobble),
--            mortar (brick), the lower panel (wainscot), the second square (checker, check), the
--            stripe or motif colour (stripe, pinstripe, damask, floral, rug_border), else the
--            darker grain / fleck tone
--   scale    pattern repeats per tile (1 = default board/tile/brick size)   finish  matte|satin|gloss|metal
--   accent   trim, hardware or grout colour (informative for the modellers)
-- Walls and floors also keep `color` (= look.color): Render/Lot.lua tints wall sprites with it.
-- Prices: floors and terrain per tile, walls per wall side, fences and railings per segment,
-- roofs per roof tile, doors/windows/gates per piece. Tiers: F.Tier(kind, entry).
local _, SS = ...
local F = SS.Finishes or {}
SS.Finishes = F

F.FLOOR_PATTERNS = { "planks", "parquet", "herringbone", "tiles", "checker", "hex", "mosaic", "marble", "terrazzo", "stone",
    "slate", "brick", "cobble", "concrete", "carpet", "shag", "rug_border", "lino", "deck", "gravel", "grass", "dirt", "sand", "rubber" }
F.WALL_PATTERNS = { "paint", "plaster", "stucco", "stripe", "pinstripe", "damask", "floral", "check", "wainscot", "panel", "tile",
    "brick", "stone", "siding", "shingle", "log", "concrete" }
F.TERRAIN_PATTERNS = { "grass", "dirt", "stone", "sand" }
F.ROOF_PATTERNS = { "shingle", "shake", "clay", "slate", "metal", "thatch" }
F.PIECE_PATTERNS = { "none", "wood", "planks", "panel", "stripes" }
local function set(list) local t = {} for _, v in ipairs(list) do t[v] = true end return t end
F.PATTERN_OK = { floors = set(F.FLOOR_PATTERNS), walls = set(F.WALL_PATTERNS), terrain = set(F.TERRAIN_PATTERNS),
    roofs = set(F.ROOF_PATTERNS), doors = set(F.PIECE_PATTERNS), windows = set(F.PIECE_PATTERNS), fences = set(F.PIECE_PATTERNS),
    railings = set(F.PIECE_PATTERNS) }
-- Patterns whose color2 is the joint colour (grout or mortar), per ART.md section 3.
local JOINTED = set({ "tiles", "tile", "hex", "mosaic", "cobble", "brick" })
F.KINDS = { "floors", "walls", "doors", "windows", "roofs", "fences", "railings", "terrain" }
F.TIERS = { floors = { 6, 18 }, walls = { 6, 16 }, doors = { 150, 500 }, windows = { 150, 350 }, roofs = { 4, 8 },
    fences = { 20, 35 }, railings = { 30, 60 }, terrain = { 0, 1 } }

local function hex(s)
    local r, g, b = s:match("^#(%x%x)(%x%x)(%x%x)$")
    return { tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255 }
end
F.hex = hex
local function look(pattern, c1, c2, scale, accent, finish)
    local color2 = JOINTED[pattern] and (accent or c2 or c1) or (c2 or c1)
    return { pattern = pattern, color = hex(c1), color2 = hex(color2), scale = scale or 1, accent = hex(accent or c2 or c1),
        finish = finish or "matte" }
end

---------------------------------------------------------------------------------------------------
-- Floors (48+). outdoor = true: paving, decking and lawn types that keep a cell outdoors.
---------------------------------------------------------------------------------------------------
F.floors = {}
local function floor(id, name, style, price, pattern, c1, c2, scale, accent, finish, desc, extra)
    local e = { name = name, style = style, price = price, look = look(pattern, c1, c2, scale, accent, finish), desc = desc }
    e.color = e.look.color
    for k, v in pairs(extra or {}) do e[k] = v end
    F.floors[id] = e
end
local OUT = { outdoor = true }
-- wood
floor("wood", "Honey Oak Boards", "traditional", 12, "planks", "#c89458", "#9c6c3c", 1.0, "#6e4a2c", "satin", "Warm oak strips that creak on the third board from the door, as tradition demands.")
floor("floor_laminate", "Oak-Look Laminate", "starter", 5, "planks", "#c9a070", "#a88050", 1.0, "#8a6440", "satin", "A photograph of oak under a tough clear skin. From a standing height, nobody can tell.")
floor("floor_pine_boards", "Knotty Pine Boards", "starter", 6, "planks", "#dcb47c", "#b88a52", 1.2, "#6b4a2a", "matte", "Soft pine with a knot every foot or so, each one a small brown eye watching you mop.")
floor("floor_painted_boards", "Painted Cottage Boards", "eclectic", 9, "planks", "#9cc0d8", "#86aac4", 1.0, "#f2f0e8", "satin", "Floorboards painted duck-egg blue, worn pale in all the places people actually walk.")
floor("floor_bamboo", "Pale Bamboo Strip", "contemporary", 16, "planks", "#e2c89a", "#ccae7a", 1.6, "#b09060", "satin", "Narrow strips of pressed bamboo, harder than oak and smugger about it.")
floor("floor_reclaimed", "Reclaimed Barn Boards", "eclectic", 18, "planks", "#9a7a5c", "#6e5440", 0.9, "#3a2c22", "matte", "Boards rescued from a barn, nail holes and all. Every scuff looks deliberate here.")
floor("floor_walnut_planks", "Wide Walnut Planks", "traditional", 22, "planks", "#6e4a32", "#4a2f1f", 0.8, "#2e1e14", "satin", "Broad dark planks that make any room look as though it has a library, even if it has a television.")
floor("floor_ebony", "Ebonised Oak", "contemporary", 26, "planks", "#3a2e28", "#241c18", 1.0, "#141010", "gloss", "Oak stained almost black. Shows every crumb, which the brochure calls honesty.")
floor("floor_parquet_block", "Basketweave Block Parquet", "traditional", 24, "parquet", "#b8864e", "#8e6236", 1.0, "#5a3c22", "satin", "Square oak blocks laid at right angles to their neighbours, a chessboard for people who prefer wood.")
floor("floor_oak_herringbone", "Oak Herringbone Parquet", "traditional", 30, "herringbone", "#c09060", "#946a40", 1.0, "#5c3e24", "satin", "Hundreds of little oak blocks laid in a zigzag by someone with enormous patience.")
-- tile and stone
floor("tile", "Checkerboard Tile", "starter", 10, "checker", "#f0ece2", "#2a2a2e", 1.0, "#9a968e", "gloss", "Black and white squares for kitchens that want to feel like a milk bar.")
floor("floor_lino", "Speckled Vinyl Sheet", "starter", 3, "lino", "#d8d0bc", "#a8a08c", 2.0, "#8c8474", "satin", "One seamless sheet of flecked vinyl. Forgives spills, footprints and most decisions.")
floor("floor_lino_check", "Diner Check Linoleum", "eclectic", 7, "checker", "#c83a32", "#f2eee4", 1.4, "#8a2a24", "gloss", "Red and cream checks that make every breakfast feel like it comes with a milkshake.")
floor("floor_rubber", "Rubber Play Tiles", "starter", 7, "rubber", "#6aa0d8", "#e8c040", 1.0, "#4a7ab0", "matte", "Interlocking foam squares in primary colours. Soft landings for small people and dropped toast.")
floor("floor_tile_white", "White Square Tile", "starter", 8, "tiles", "#f2f2ee", "#e4e4de", 2.0, "#b8b8b0", "gloss", "Plain glazed squares with grey grout. Looks clean for a week, then looks like a floor.")
floor("floor_tile_terracotta", "Terracotta Quarry Tile", "traditional", 14, "tiles", "#b86a44", "#a45a38", 1.2, "#e0d4c0", "matte", "Sun-coloured clay squares that stay cool underfoot and warm in the eye.")
floor("floor_brick_indoor", "Herringbone Brick Floor", "traditional", 16, "herringbone", "#a45a42", "#8a4634", 1.6, "#cfc4b2", "matte", "Old brick pavers laid in a zigzag indoors, for a kitchen that remembers being a farm.")
floor("floor_concrete", "Polished Concrete", "contemporary", 15, "concrete", "#b8b4ac", "#a09c94", 1.0, "#8c8880", "gloss", "Ground and sealed until it shines. Cold, clean and very sure of itself.")
floor("floor_tile_hex", "Hexagon Mosaic", "eclectic", 18, "hex", "#f0eee8", "#2a2a2e", 3.0, "#c8c4bc", "gloss", "Tiny six-sided tiles with a black flower border, as in a very good old bathroom.")
floor("floor_tile_slate", "Riven Slate Tile", "contemporary", 20, "slate", "#4e5458", "#3a4044", 1.0, "#6a6e70", "matte", "Split slate with a rippled face that grips wet feet. Handsome by a back door.")
floor("floor_tile_large", "Large-Format Porcelain", "contemporary", 24, "tiles", "#d8d4cc", "#ccc8c0", 0.5, "#c0bcb4", "satin", "Huge pale tiles with barely any grout. The floor equivalent of a quiet voice.")
floor("floor_terrazzo", "Terrazzo Chip", "eclectic", 28, "terrazzo", "#ece6dc", "#c86a4a", 3.0, "#5a7a8a", "gloss", "Marble chips set in cement and polished flat, like confetti preserved for posterity.")
floor("floor_encaustic", "Patterned Encaustic Tile", "eclectic", 32, "mosaic", "#e8e0cc", "#2c5a70", 1.0, "#b8483a", "matte", "Cement tiles with inlaid star patterns that nobody tires of, least of all visitors.")
floor("floor_marble", "White Veined Marble", "traditional", 40, "marble", "#eeebe4", "#a9a49c", 1.0, "#8a857c", "gloss", "Pale marble with grey veins. Guests take off their shoes without being asked.")
floor("floor_marble_black", "Black Marble with Gold Vein", "contemporary", 45, "marble", "#262424", "#c8a050", 1.0, "#101010", "gloss", "Polished black stone shot through with gold, for a lobby or a very confident bathroom.")
-- carpet and soft
floor("carpet", "Brick-Red Carpet", "starter", 8, "carpet", "#a4524a", "#8d443d", 1.0, "#6a3430", "matte", "A hard-wearing red twist that hides juice, mud and most of the evidence.")
floor("floor_carpet_beige", "Oatmeal Berber Carpet", "starter", 6, "carpet", "#cfc2a6", "#b8aa8c", 1.2, "#9a8e74", "matte", "Looped beige carpet, the colour estate agents recommend and nobody remembers.")
floor("floor_carpet_blue", "Navy Twist Pile", "contemporary", 12, "carpet", "#2e3c5e", "#24304c", 1.0, "#18203a", "matte", "Deep navy pile that makes a bedroom feel like the quiet part of a hotel.")
floor("floor_carpet_shag", "Avocado Shag", "eclectic", 10, "shag", "#7a8a3a", "#62722c", 0.8, "#4a5620", "matte", "Long green pile that swallows dropped earrings and returns them years later.")
floor("floor_carpet_stripe", "Banded Border Carpet", "eclectic", 14, "rug_border", "#e6d6b0", "#b8483a", 2.0, "#2c4a6a", "matte", "Cream carpet with a bold red-and-navy band around the edge, like a welcome mat that took over the room.")
floor("floor_carpet_rose", "Wine Carpet with Gold Border", "traditional", 18, "rug_border", "#8a3a44", "#c8a070", 1.0, "#5a2430", "matte", "A woven wine-red carpet with a scrolled gold border, for a parlour with standards.")
floor("floor_carpet_plush", "Deep Plush Cream", "contemporary", 20, "carpet", "#ece4d2", "#ddd4c0", 1.0, "#c8bea8", "matte", "Ankle-deep cream pile. Beautiful, soft, and doomed the moment grape juice arrives.")
floor("floor_sisal", "Woven Sisal Matting", "garden", 11, "carpet", "#c8b48a", "#a8946a", 1.5, "#806c4a", "matte", "Natural plant fibre woven in a tight basket pattern. Rustles slightly, pleasantly.")
floor("floor_cork", "Cork Tiles", "eclectic", 9, "tiles", "#b8905c", "#96703e", 1.6, "#6a4c2c", "satin", "Springy, warm and quiet; the floor that makes dropped plates bounce instead of break.")
-- outdoor: lawn, decking, paving (stays outdoors; build treats these as exterior surfaces)
floor("grass", "Lawn", "garden", 0, "grass", "#5a8e3e", "#4a7a32", 1.0, "#3a6428", "matte", "Plain green lawn: the ground a lot comes with, before anyone has ideas.", OUT)
floor("floor_grass_clover", "Clover Lawn", "garden", 1, "grass", "#6a9e46", "#8ab860", 1.2, "#e8e8e0", "matte", "Grass laced with white clover. Bees approve; barefoot children have opinions.", OUT)
floor("floor_grass_meadow", "Long Meadow Grass", "garden", 2, "grass", "#7a9a48", "#a8b060", 0.8, "#d8c060", "matte", "Unmown grass with buttercups, sold as a lifestyle rather than a neglected lawn.", OUT)
floor("floor_turf", "Artificial Turf", "contemporary", 4, "grass", "#4aa040", "#3a8a34", 1.4, "#2a6a26", "satin", "Perfect green plastic lawn that never needs mowing and never quite smells right.", OUT)
floor("path", "Flagstone Path", "garden", 6, "stone", "#b4aa98", "#948a78", 1.0, "#6a7a4a", "matte", "Irregular stones with moss in the joints, leading somewhere pleasant at a gentle pace.", OUT)
floor("floor_paving_concrete", "Concrete Slab Paving", "starter", 4, "tiles", "#bdb8ae", "#a8a39a", 0.5, "#8a867e", "matte", "Square grey slabs for a patio that gets the job done and asks for nothing.", OUT)
floor("floor_asphalt", "Asphalt Drive", "starter", 3, "concrete", "#3c3c40", "#2e2e32", 1.0, "#e8e0c8", "matte", "Smooth black tarmac for parking, chalk drawings and the occasional bike race.", OUT)
floor("floor_gravel", "Pea Gravel", "garden", 3, "gravel", "#c8bca4", "#a89c84", 1.0, "#8a7e68", "matte", "Small round stones that crunch underfoot and announce every visitor in advance.", OUT)
floor("floor_deck_pine", "Boardwalk Decking", "starter", 9, "deck", "#c8a070", "#a8804e", 1.0, "#6a4c2c", "matte", "Treated pine decking with grooved boards, good for a porch or a barbecue corner.", OUT)
floor("floor_paving_brick", "Brick Paver Path", "traditional", 9, "brick", "#a4523c", "#8a4230", 1.4, "#c8bea8", "matte", "Red clay pavers in a running bond, laid on sand the old-fashioned way.", OUT)
floor("floor_paving_cobble", "Cobblestone Setts", "traditional", 12, "cobble", "#8a8680", "#6e6a64", 2.2, "#5a5650", "matte", "Rounded granite setts that look romantic and play havoc with heels.", OUT)
floor("floor_deck_cedar", "Cedar Decking", "garden", 14, "deck", "#b07a50", "#8a5a38", 1.0, "#5a3c26", "satin", "Aromatic red cedar boards that silver gracefully if you let them.", OUT)
floor("floor_paving_sandstone", "Sandstone Patio Slabs", "traditional", 16, "stone", "#d8c49c", "#bca880", 0.8, "#9a8a6c", "matte", "Big honey-coloured slabs laid in random sizes, as if the patio grew naturally.", OUT)
floor("floor_deck_composite", "Grey Composite Decking", "contemporary", 18, "deck", "#8a8a88", "#747472", 1.0, "#5a5a58", "satin", "Recycled boards that never splinter, warp or need oiling; they just quietly stay grey.", OUT)
floor("floor_paving_mosaic", "Pebble Mosaic Paving", "eclectic", 22, "mosaic", "#9a9288", "#e8e0d0", 3.0, "#4a4440", "matte", "River pebbles set on edge in swirling patterns by a craftsperson with a view on spirals.", OUT)
floor("floor_paving_granite", "Honed Granite Setts", "contemporary", 26, "slate", "#6e6e70", "#58585a", 1.2, "#3e3e40", "matte", "Charcoal granite blocks with crisp joints, for a courtyard that means business.", OUT)

---------------------------------------------------------------------------------------------------
-- Walls (48+): paint, wallpaper, panelling, tile, brick, siding, stone, stucco and plaster.
---------------------------------------------------------------------------------------------------
F.walls = {}
local function wall(id, name, style, price, family, pattern, c1, c2, scale, accent, finish, desc)
    local e = { name = name, style = style, price = price, family = family, look = look(pattern, c1, c2, scale, accent, finish), desc = desc }
    e.color = e.look.color
    F.walls[id] = e
end
F.WALL_FAMILIES = { "paint", "wallpaper", "panelling", "tile", "brick", "siding", "stone", "stucco" }
-- paint
wall("paint_cream", "Buttermilk Paint", "starter", 4, "paint", "paint", "#f9e8c2", nil, 1, "#e8d4a8", "matte", "A soft yellow-cream that makes any room look like the morning after a good night's sleep.")
wall("paint_seafoam", "Seafoam Bathroom Paint", "starter", 4, "paint", "paint", "#b2e0d6", nil, 1, "#94c8bc", "satin", "A steam-proof pale green-blue that says 'bathroom' in a calm voice.")
wall("paint_white", "Gallery White", "contemporary", 3, "paint", "paint", "#f4f2ee", nil, 1, "#e0ddd6", "matte", "The white that makes paintings look expensive and fingerprints look criminal.")
wall("paint_sky", "Nursery Sky Blue", "starter", 4, "paint", "paint", "#b8d4ec", nil, 1, "#98b8d8", "matte", "A gentle blue with no clouds, for rooms where naps are negotiated.")
wall("paint_grey", "Pebble Grey", "contemporary", 4, "paint", "paint", "#b4b2ac", nil, 1, "#98968f", "matte", "A warm mid-grey that goes with everything and commits to nothing.")
wall("paint_sage", "Sage Green", "traditional", 4, "paint", "paint", "#a8b89a", nil, 1, "#8a9a7e", "matte", "Muted herb green that makes a kitchen feel like it grows its own parsley.")
wall("paint_blush", "Blush Pink", "eclectic", 4, "paint", "paint", "#ecc4c0", nil, 1, "#d4a8a4", "matte", "A pink so soft it could apologise on your behalf.")
wall("paint_navy", "Midnight Navy", "contemporary", 5, "paint", "paint", "#27324c", nil, 1, "#1a2238", "matte", "Deep blue for a study or bedroom that wants to feel like ten o'clock at night.")
wall("paint_terracotta", "Terracotta Wash", "eclectic", 5, "paint", "paint", "#c8764e", nil, 1, "#a85c3a", "matte", "A sunbaked orange-brown that brings the Mediterranean indoors, minus the ferry.")
wall("paint_mustard", "Mustard Seed", "eclectic", 5, "paint", "paint", "#d4a830", nil, 1, "#b48a20", "matte", "A bold yellow-brown for households that like their walls to have an opinion.")
wall("paint_charcoal", "Charcoal Accent", "contemporary", 6, "paint", "paint", "#3a3a3e", nil, 1, "#28282c", "matte", "Nearly black. Makes brass lamps glow and small rooms feel mysterious rather than small.")
wall("paint_limewash", "Chalky Limewash", "traditional", 7, "paint", "plaster", "#e8e2d4", "#d8d0c0", 0.6, "#c8bea8", "matte", "Brushed-on mineral paint with soft cloudy variation, like an old farmhouse that was loved.")
-- wallpaper
wall("paper_check", "Gingham Kitchen Paper", "starter", 8, "wallpaper", "check", "#f2ece0", "#d8584e", 2.5, "#f2ece0", "matte", "Red-and-white checks for a kitchen that bakes, or at least intends to.")
wall("paper_stars", "Starry Night Nursery Paper", "starter", 10, "wallpaper", "floral", "#2c3a64", "#f2e08a", 2.0, "#f2e08a", "matte", "Deep blue paper scattered with gold stars, for bedtime stories with a ceiling of their own.")
wall("paper_stripe_regency", "Regency Stripe Wallpaper", "traditional", 12, "wallpaper", "stripe", "#e6dcc0", "#6a8a6a", 1.5, "#c8b88a", "satin", "Wide stripes of cream and green, the wallpaper of well-mannered drawing rooms.")
wall("paper_pinstripe", "Grey Pinstripe Wallpaper", "contemporary", 12, "wallpaper", "pinstripe", "#d8d8d6", "#a8a8a6", 4.0, "#888886", "matte", "Fine grey pinstripes, as though the wall had been fitted for a suit.")
wall("paper_floral", "Cottage Rose Wallpaper", "garden", 14, "wallpaper", "floral", "#f2eadc", "#d88a90", 1.2, "#7aa070", "matte", "Climbing roses on a cream ground. Grandmothers and garden centres approve.")
wall("paper_geo", "Atomic Starburst Wallpaper", "eclectic", 16, "wallpaper", "floral", "#e8dcc0", "#d4703a", 1.5, "#2c6a70", "matte", "Boomerangs and starbursts in orange and teal, straight from a very optimistic decade.")
wall("paper_damask_gold", "Gold Damask Wallpaper", "traditional", 18, "wallpaper", "damask", "#6a2a30", "#c8a050", 1.0, "#c8a050", "satin", "Wine-red paper with a gold damask flourish. The dining room will insist on candles.")
wall("paper_tropical", "Palm Leaf Wallpaper", "eclectic", 20, "wallpaper", "floral", "#e8eee0", "#3a7a4a", 1.0, "#2a5a38", "matte", "Big glossy banana leaves on white, for a bathroom that thinks it is on holiday.")
wall("paper_grasscloth", "Grasscloth Wallpaper", "contemporary", 22, "wallpaper", "pinstripe", "#c4b48e", "#a8986e", 2.0, "#8a7a54", "matte", "Real woven grass on paper backing; textured, quiet and a little bit smug.")
wall("paper_flock", "Velvet Flock Wallpaper", "eclectic", 24, "wallpaper", "damask", "#8a1c24", "#5a1018", 1.0, "#c8a050", "satin", "Raised velvet flocking in deep red, as seen in the finest curry houses and haunted hotels.")
-- panelling
wall("panel_shiplap", "Painted Shiplap", "starter", 10, "panelling", "siding", "#f0eee8", "#d8d6d0", 2.0, "#c0beb8", "satin", "Overlapping painted boards, turning any wall into a seaside cottage by suggestion.")
wall("panel_knotty_pine", "Knotty Pine Cabin Boards", "eclectic", 12, "panelling", "panel", "#d4a870", "#b48a52", 1.2, "#6b4a2a", "satin", "Tongue-and-groove pine with plenty of knots. Instant log cabin; bring your own snow.")
wall("panel_beadboard", "White Beadboard", "garden", 14, "panelling", "panel", "#f2f0ea", "#dcdad4", 3.0, "#c8c6c0", "satin", "Narrow vertical boards with a bead between each, the uniform of good porches and bathrooms.")
wall("panel_oak", "Oak Wainscot Panelling", "traditional", 22, "panelling", "wainscot", "#e8dcc4", "#b48450", 1.0, "#8e6238", "satin", "Raised oak panels to waist height with cream plaster above. Solid, calm and fond of portraits.")
wall("panel_walnut", "Walnut Library Panelling", "traditional", 30, "panelling", "panel", "#5e3e28", "#40281a", 1.0, "#c8a050", "gloss", "Floor-to-ceiling dark walnut panels. Thinking deep thoughts becomes practically compulsory.")
-- tile
wall("tile_check_bath", "Checkerboard Bathroom Tile", "starter", 9, "tile", "check", "#f2f2ee", "#3a6aa8", 2.0, "#c8c8c4", "gloss", "Blue and white checks from floor to shoulder, for a bathroom with a cheerful attitude.")
wall("tile_mint", "Mint Square Tile", "eclectic", 12, "tile", "tile", "#b4e0c8", "#a0ccb4", 2.0, "#f2f2ee", "gloss", "Minty glazed squares with white grout. Makes toothpaste feel at home.")
wall("tile_subway", "White Subway Tile", "contemporary", 14, "tile", "brick", "#f4f4f0", "#e8e8e4", 3.0, "#8a8a86", "gloss", "Bevelled white rectangles in a brick bond, the backsplash that suits every kitchen.")
wall("tile_hex_black", "Black Hexagon Tile", "contemporary", 18, "tile", "tile", "#2a2a2e", "#222226", 2.0, "#e8e8e4", "gloss", "Matte black hexagons with bright grout, like a honeycomb that went to art school.")
wall("tile_mosaic_pool", "Blue Glass Mosaic", "eclectic", 20, "tile", "tile", "#3a88b8", "#62a8d0", 5.0, "#e8f0f2", "gloss", "Thousands of tiny glass squares in shades of pool water. Shimmers when the shower runs.")
wall("tile_zellige", "Hand-Glazed Green Zellige", "eclectic", 26, "tile", "tile", "#3a7a5a", "#4e9070", 2.5, "#d8d4c8", "gloss", "Uneven handmade tiles whose glaze pools and ripples, so every one catches the light differently.")
wall("tile_marble", "Marble Slab Wall", "traditional", 34, "tile", "tile", "#eceae4", "#a8a49c", 0.5, "#8a857c", "gloss", "Book-matched marble slabs for a bathroom that expects to be photographed.")
-- brick
wall("brick_red", "Red Common Brick", "starter", 10, "brick", "brick", "#a4523c", "#8a4230", 1.0, "#cfc4b2", "matte", "Plain red brick with pale mortar. Sturdy, honest and nearly impossible to hang a picture on.")
wall("brick_white", "Whitewashed Brick", "garden", 12, "brick", "brick", "#e8e2d8", "#d4ccc0", 1.0, "#b8b0a4", "matte", "Brick painted chalky white with the texture left showing, for a bright sunroom.")
wall("brick_yellow", "Yellow Stock Brick", "traditional", 14, "brick", "brick", "#c8ac78", "#a8905c", 1.0, "#e0d8c8", "matte", "Sandy-yellow brick that weathers to a golden grey, the colour of older city terraces.")
wall("brick_glazed", "Glazed Blue Brick", "eclectic", 22, "brick", "brick", "#2c5a8a", "#244c78", 1.0, "#e8e4dc", "gloss", "Shiny cobalt bricks that turn a garden wall or bathroom into a quiet showpiece.")
-- siding
wall("siding_vinyl", "Grey Vinyl Siding", "starter", 5, "siding", "siding", "#b8bab8", "#a4a6a4", 1.0, "#f2f2f0", "satin", "Maintenance-free grey siding. It will outlast the mortgage, and possibly the house.")
wall("siding_sage", "Sage Clapboard Siding", "starter", 8, "siding", "siding", "#a3c29e", "#8aa886", 1.0, "#f2f0e8", "satin", "Painted clapboard in soft sage with white trim, the colour of a very contented cottage.")
wall("siding_white", "White Clapboard", "traditional", 8, "siding", "siding", "#f0eee8", "#dcdad4", 1.0, "#2c3a4a", "satin", "Classic white clapboard with dark trim; looks right on every street ever painted.")
wall("siding_barn", "Barn Red Board-and-Batten", "garden", 9, "siding", "panel", "#8a2c24", "#70221c", 2.0, "#f0eee8", "matte", "Vertical boards with narrow battens in barn red, for a house with farmyard ambitions.")
wall("siding_metal", "Corrugated Steel Cladding", "contemporary", 12, "siding", "panel", "#9aa0a4", "#848a8e", 3.0, "#5a6064", "metal", "Ribbed steel sheet for a studio or workshop look. Rain sounds tremendous on it.")
wall("siding_shingle", "Cedar Shingle Siding", "garden", 14, "siding", "shingle", "#a47a54", "#86603e", 1.5, "#f0eee8", "matte", "Overlapping cedar shingles that fade to a soft silver by the sea, or by the bins.")
-- stone
wall("stone_river", "River Rock", "eclectic", 20, "stone", "stone", "#9a9288", "#7a746a", 0.6, "#c8c0b0", "matte", "Rounded river stones set in mortar, like a lodge that someone built by hand one summer.")
wall("stone_fieldstone", "Fieldstone Wall", "traditional", 24, "stone", "stone", "#a49c8c", "#847c6c", 0.8, "#c8c0b0", "matte", "Rough stones of every size fitted together like a puzzle with no picture on the box.")
wall("stone_slate_stack", "Stacked Slate Veneer", "contemporary", 26, "stone", "stone", "#5a5e62", "#46494c", 2.0, "#34373a", "matte", "Thin slate strips stacked tight with no visible mortar. Dramatic behind a fireplace.")
wall("stone_ashlar", "Dressed Limestone Ashlar", "traditional", 30, "stone", "brick", "#d8ceb8", "#c4baa4", 0.5, "#b0a690", "matte", "Big smooth-cut limestone blocks. Makes a house look like it has a coat of arms somewhere.")
-- stucco and plaster
wall("stucco_white", "White Stucco", "contemporary", 7, "stucco", "stucco", "#f2f0ea", "#e2e0da", 1.0, "#c8c6c0", "matte", "Smooth white render for crisp modern boxes and hillside villas alike.")
wall("stucco_peach", "Peach Stucco", "garden", 8, "stucco", "stucco", "#f0c8a4", "#e0b890", 1.0, "#f2f0e8", "matte", "Warm peach render that glows at sunset and hides a lot of minor cracks.")
wall("stucco_adobe", "Sunbaked Adobe", "eclectic", 9, "stucco", "stucco", "#c89a70", "#b0845c", 0.7, "#8a6440", "matte", "Earthy rounded render the colour of desert clay, cool inside on hot days.")
wall("concrete_board", "Board-Formed Concrete", "contemporary", 16, "stucco", "concrete", "#b0aca4", "#9c988f", 1.0, "#88847c", "matte", "Concrete poured against timber boards so the grain is printed on it. Brutal, but charming.")
wall("plaster_venetian", "Polished Venetian Plaster", "traditional", 28, "stucco", "plaster", "#d8c8a8", "#c4b08c", 0.6, "#a89470", "gloss", "Layer upon layer of burnished lime plaster with a soft marbled sheen, applied by the very patient.")

---------------------------------------------------------------------------------------------------
-- Doors (12+): width 2 = double (spans 2 edges); kind "arch" = opening without a door.
-- look.shape: rect | arch | round | keyhole; look.glass: nil | clear | frosted | reeded | stained | mesh.
---------------------------------------------------------------------------------------------------
F.doors = {}
local function door(id, name, style, price, desc, opts)
    local e = { name = name, style = style, price = price, desc = desc, width = opts.width or 1, kind = opts.kind or "door",
        glass = opts.glass and true or false }
    e.look = { pattern = opts.pattern or "none", color = hex(opts.base), color2 = hex(opts.base2 or opts.base), accent = hex(opts.accent or "#c8a050"),
        scale = 1, finish = opts.finish or "satin", shape = opts.shape or "rect", glass = opts.glass, height = opts.height or 2.1 }
    F.doors[id] = e
end
door("door_screen", "Sprung Screen Door", "garden", 80, "A mesh door on a spring that closes with a smack loud enough to announce every trip to the garden.", { base = "#f2f0e8", glass = "mesh", accent = "#2c2c2c" })
door("door_basic", "Flat Pine Door", "starter", 90, "A plain slab door with a round knob. It opens, it closes, it asks nothing more of life.", { base = "#dcc49c", pattern = "wood", accent = "#b8b8b4" })
door("arch_round", "Plaster Round Arch", "traditional", 140, "A doorless opening with a smooth curved top, so rooms can chat without shouting through wood.", { kind = "arch", base = "#f2ece0", shape = "arch" })
door("arch_wide", "Wide Square Opening", "contemporary", 210, "Two tiles of open wall with a crisp square head, for open-plan living with a hint of boundaries.", { kind = "arch", width = 2, base = "#f2f0ea" })
door("door_panel", "Four-Panel Cottage Door", "traditional", 240, "Four raised panels, brass lever and a latch that clicks like a well-kept promise.", { base = "#f0ece2", pattern = "panel", accent = "#c8a050" })
door("arch_keyhole", "Keyhole Arch", "eclectic", 260, "A tall arched opening that pinches in at the shoulders, as if the room beyond is a secret.", { kind = "arch", base = "#e8d8bc", shape = "keyhole", accent = "#2c6a70" })
door("door_pocket", "Sliding Pocket Door", "contemporary", 300, "A flush door that disappears into the wall, winning the argument about where to put the bookcase.", { base = "#d8d4cc", accent = "#888888", finish = "matte" })
door("door_stable", "Two-Part Stable Door", "eclectic", 320, "Top and bottom open separately, so you can chat to the postman without letting the dog out.", { base = "#5a8a6a", pattern = "planks", accent = "#2c2c2c" })
door("door_glass", "Reeded-Glass Door", "contemporary", 380, "A slim black frame around ribbed glass: daylight comes through, details do not.", { base = "#2a2a2e", glass = "reeded", accent = "#b8b8b4", finish = "metal" })
door("door_front_oak", "Studded Oak Front Door", "traditional", 650, "Heavy oak with iron studs and a lion knocker; guests feel they ought to have made an appointment.", { base = "#8a5a34", pattern = "planks", accent = "#2c2c2c", shape = "arch", height = 2.3 })
door("door_double_french", "Glazed French Doors", "traditional", 760, "A pair of many-paned doors that open wide onto a patio, a view or a dramatic entrance.", { width = 2, base = "#f2f0ea", glass = "clear", accent = "#c8a050" })
door("door_double_patio", "Aluminium Patio Slider", "contemporary", 900, "Two tiles of floor-to-ceiling glass that glide on a track; birds occasionally fail to notice it.", { width = 2, base = "#8a8e92", glass = "clear", accent = "#4a4e52", finish = "metal", height = 2.2 })
door("door_double_grand", "Carved Double Entrance Doors", "eclectic", 1250, "Two tall carved doors with stained-glass lights above, for a front hall that expects applause.", { width = 2, base = "#5a3a24", pattern = "panel", glass = "stained", accent = "#c8a050", shape = "arch", height = 2.4 })

---------------------------------------------------------------------------------------------------
-- Windows (12+), varied sizes: look.size = { w = tiles wide, h = glass height, sill = sill height };
-- light = daylight multiplier for the room (1 = standard).
---------------------------------------------------------------------------------------------------
F.windows = {}
local function window(id, name, style, price, desc, opts)
    local e = { name = name, style = style, price = price, desc = desc, width = opts.w or 1, light = opts.light or 1 }
    e.look = { pattern = "none", color = hex(opts.frame), color2 = hex(opts.frame), accent = hex(opts.accent or opts.frame), scale = 1,
        finish = opts.finish or "satin", glass = opts.glass or "clear", shape = opts.shape or "rect", panes = opts.panes or 1,
        size = { w = opts.w or 1, h = opts.h, sill = opts.sill } }
    F.windows[id] = e
end
window("window_basic", "Aluminium Slider Window", "starter", 80, "A plain sliding pane in a thin metal frame. Lets light in and lets flies negotiate.", { frame = "#c8ccd0", h = 0.9, sill = 1.0, light = 0.9 })
window("window_frosted", "Frosted Privacy Window", "starter", 110, "Obscured glass for the bathroom: the sun gets in, the neighbours do not.", { frame = "#f2f2ee", glass = "frosted", h = 0.8, sill = 1.2, light = 0.7 })
window("window_sash", "Double-Hung Sash Window", "traditional", 150, "Two sliding sashes with a brass catch, and a sash cord that has seen things.", { frame = "#f2f0ea", h = 1.3, sill = 0.8, panes = 6, accent = "#c8a050" })
window("window_clerestory", "High Transom Strip", "contemporary", 160, "A narrow band of glass up near the ceiling, for light without an audience.", { frame = "#2a2a2e", h = 0.4, sill = 1.8, light = 0.8, finish = "metal" })
window("window_porthole", "Round Porthole", "eclectic", 170, "A brass-ringed circle of glass, for rooms that like to pretend they are at sea.", { frame = "#c8a050", h = 0.6, sill = 1.1, shape = "round", light = 0.6, finish = "metal" })
window("window_casement", "Leaded Casement", "traditional", 190, "A hinged window of small diamond panes held together with lead and old-fashioned stubbornness.", { frame = "#3a3a3a", h = 1.1, sill = 0.9, panes = 12, light = 0.85 })
window("window_shutter", "Shuttered Farmhouse Window", "garden", 210, "A tall window with louvred shutters painted green, which nobody has closed since 1978.", { frame = "#f2f0ea", accent = "#3a6a4a", h = 1.3, sill = 0.8, panes = 4 })
window("window_cafe", "Awning Cafe Window", "eclectic", 230, "A wide pane that tilts out at the bottom under a striped fabric awning.", { frame = "#f2f0ea", accent = "#c8483a", h = 1.0, sill = 1.0, light = 0.9 })
window("window_tall", "Full-Height Glazing", "contemporary", 320, "Floor-to-ceiling glass in a slim frame; the garden becomes part of the room.", { frame = "#2a2a2e", h = 2.1, sill = 0.05, light = 1.3, finish = "metal" })
window("window_arched", "Arched Fanlight Window", "traditional", 360, "A tall window with a half-round fan of glass on top, like a sunrise that stayed.", { frame = "#f2f0ea", h = 1.6, sill = 0.7, shape = "arch", panes = 8, light = 1.1 })
window("window_wide", "Two-Tile Picture Window", "contemporary", 420, "One huge fixed pane across two tiles, framing the view like an expensive landscape painting.", { w = 2, frame = "#8a8e92", h = 1.4, sill = 0.6, light = 1.4, finish = "metal" })
window("window_bay", "Cushioned Bay Window", "traditional", 520, "A two-tile angled bay of glazing, the natural home of cats, books and daydreams.", { w = 2, frame = "#f2f0ea", h = 1.5, sill = 0.5, panes = 9, light = 1.4 })
window("window_stained", "Stained Glass Rose Window", "eclectic", 540, "A round window of coloured glass that paints the floor in jewels every afternoon.", { frame = "#3a3a3a", glass = "stained", h = 1.0, sill = 1.1, shape = "round", light = 0.8 })

---------------------------------------------------------------------------------------------------
-- Roofs (6 materials), each with colour options { id, name, rgb }; price per roof tile.
---------------------------------------------------------------------------------------------------
F.roofs = {}
local function roof(id, name, style, price, pattern, desc, colors)
    local cols = {}
    for n, c in ipairs(colors) do cols[n] = { id = c[1], name = c[2], rgb = hex(c[3]) } end
    F.roofs[id] = { name = name, style = style, price = price, desc = desc, colors = cols,
        look = { pattern = pattern, color = cols[1].rgb, color2 = cols[1].rgb, accent = hex("#e8e4dc"), scale = 1, finish = "matte" } }
end
roof("roof_asphalt", "Three-Tab Asphalt Shingle", "starter", 3, "shingle", "Tar-paper shingles in tidy rows; they keep the rain out for twenty years and ask for nothing but a gutter clean.",
    { { "charcoal", "Charcoal", "#44464a" }, { "brown", "Weathered Brown", "#6a5040" }, { "green", "Forest Green", "#3e5a44" }, { "red", "Barn Red", "#7a3228" } })
roof("roof_cedar", "Hand-Split Cedar Shake", "garden", 6, "shake", "Thick split cedar shingles that start golden and silver with age, like a well-kept beard.",
    { { "natural", "Natural Cedar", "#a47a54" }, { "silver", "Silvered", "#8a8a84" }, { "honey", "Honey Stain", "#b88a50" }, { "moss", "Mossy", "#6a7454" } })
roof("roof_thatch", "Reed Thatch", "eclectic", 7, "thatch", "A deep blanket of water reed with a patterned ridge; warm in winter and home to at least one opinionated wren.",
    { { "golden", "Golden Reed", "#c8a864" }, { "aged", "Aged Brown", "#8a7250" }, { "straw", "Pale Straw", "#dcc890" } })
roof("roof_clay", "Mission Clay Tile", "traditional", 8, "clay", "Half-round fired clay tiles laid in rolling rows, for a house that faces the sun on purpose.",
    { { "terracotta", "Terracotta", "#b8603c" }, { "sand", "Sandstone", "#d0a878" }, { "blend", "Old Blend", "#a45a44" }, { "glazed", "Green Glaze", "#4a7a52" } })
roof("roof_metal", "Standing-Seam Steel", "contemporary", 9, "metal", "Long steel panels with raised seams that shed snow and turn a rainstorm into a drum solo.",
    { { "graphite", "Graphite", "#3a3e42" }, { "silver", "Galvanised", "#a4aaae" }, { "copper", "Copper", "#b0643c" }, { "slate", "Slate Blue", "#4a5a6a" } })
roof("roof_slate", "Natural Slate", "traditional", 11, "slate", "Split slates hung on copper nails, heavy, handsome and likely to outlive everyone reading this.",
    { { "blue", "Blue-Grey", "#4a5460" }, { "purple", "Heather Purple", "#5a4a58" }, { "green", "Green Slate", "#4a5a50" }, { "black", "Black", "#2a2c2e" } })

---------------------------------------------------------------------------------------------------
-- Fences (4+ families), each with a matching gate (a gate routes like a door). Price per segment.
---------------------------------------------------------------------------------------------------
F.fences = {}
local function fence(id, name, style, price, height, pattern, c1, accent, desc, gate)
    F.fences[id] = { name = name, style = style, price = price, desc = desc, height = height,
        look = look(pattern, c1, nil, 1, accent, "satin"),
        gate = { name = gate[1], price = gate[2], desc = gate[3] } }
end
fence("fence_ranch", "Post-and-Rail Fence", "garden", 16, 1.1, "planks", "#a07850", "#6a4c30",
    "Two rough rails between chunky posts: marks the boundary and gives a leaning spot for chats.",
    { "Five-Bar Field Gate", 85, "A wide timber gate with a diagonal brace and a latch that needs a knack." })
fence("fence_picket", "Painted Picket Fence", "traditional", 22, 0.9, "panel", "#f2f0ea", "#c8c6c0",
    "Pointed white pickets at knee height, the international symbol for 'we have a nice lawn'.",
    { "Picket Garden Gate", 110, "A little arched gate that squeaks exactly once to announce each guest." })
fence("fence_bamboo", "Bamboo Screen Fence", "eclectic", 26, 1.8, "stripes", "#c8b070", "#2c2c2c",
    "Bundled bamboo poles lashed with black cord, for a garden that would rather be a tea house.",
    { "Bamboo Moon Gate", 130, "A round-topped bamboo gate that makes every entrance feel ceremonial." })
fence("fence_board", "Close-Board Privacy Fence", "starter", 30, 1.8, "planks", "#8a6a4a", "#5a4430",
    "Tall overlapping boards that hide the garden from the street and the barbecue from the neighbours.",
    { "Close-Board Side Gate", 140, "A tall solid gate with a bolt, so the bins can come and go discreetly." })
fence("fence_iron", "Spear-Top Iron Railings", "contemporary", 58, 1.4, "none", "#2a2a2c", "#c8a050",
    "Black iron bars with spear tips and a gilded finial or two, for a front garden with a dress code.",
    { "Scrolled Iron Gate", 290, "A heavy iron gate with scrollwork and a satisfying clang when it shuts." })

-- Balcony and deck railings (build places them on edges; not fences, no gates).
F.railings = {}
local function railing(id, name, style, price, pattern, c1, accent, desc)
    F.railings[id] = { name = name, style = style, price = price, desc = desc, look = look(pattern, c1, nil, 1, accent, "satin") }
end
railing("railing_rope", "Rope and Post Railing", "garden", 24, "none", "#a07850", "#d8c8a0", "Timber posts linked by thick hemp rope, for decks with a seafaring streak.")
railing("railing_timber", "Turned Spindle Balustrade", "traditional", 36, "wood", "#f2f0ea", "#8a5a34", "White turned spindles under an oak handrail, perfect for leaning on during speeches.")
railing("railing_steel", "Horizontal Cable Rail", "contemporary", 55, "none", "#9aa0a4", "#2a2a2e", "Thin steel cables strung tight between posts, all view and very little railing.")
railing("railing_glass", "Frameless Glass Balustrade", "contemporary", 90, "none", "#cfe8ee", "#b8bcc0", "Clear panels on steel shoes; the balcony looks like it floats, and fingerprints look like art.")

---------------------------------------------------------------------------------------------------
-- Terrain paints (per tile, ground level outdoors).
---------------------------------------------------------------------------------------------------
F.terrain = {}
local function paint(id, name, style, price, pattern, c1, c2, desc)
    F.terrain[id] = { name = name, style = style, price = price, desc = desc, look = look(pattern, c1, c2, 1, c2, "matte") }
end
paint("grass", "Green Lawn", "garden", 0, "grass", "#5a8e3e", "#4a7a32", "Plain growing grass, the default state of optimism.")
paint("grass_dry", "Sun-Scorched Grass", "garden", 0, "grass", "#a8a060", "#8a8448", "Tired yellow grass from a long hot summer and a forgotten sprinkler.")
paint("dirt", "Bare Earth", "starter", 1, "dirt", "#6a4a32", "#4e3624", "Turned brown soil, ready for vegetables, mud pies or regret.")
paint("mulch", "Bark Mulch", "garden", 2, "dirt", "#5a3a26", "#7a5238", "Shredded bark that keeps weeds down and borders looking deliberately tidy.")
paint("sand", "Soft Sand", "eclectic", 2, "sand", "#dcc89c", "#c8b484", "Pale fine sand that gets into shoes, pockets and conversations.")
paint("stone", "Crushed Stone", "traditional", 2, "stone", "#9a968e", "#7a766e", "Grey chippings that crunch pleasantly and drain after every storm.")

---------------------------------------------------------------------------------------------------
-- Staircases: object definitions with `stairs = { bottom, top, run }` (World.StairInfo). The build
-- module places them; stairs_straight is the 0.1.0 id saves reference. Geometry matches the build
-- module's own fallbacks (stairs_long, stairs_turn) so plans and tests agree.
---------------------------------------------------------------------------------------------------
local C = SS.Catalog
local K = C.K
local function stairs(id, def)
    def.buyable = false
    def.rooms = { "living", "outdoor" }
    def.sub = "stairs"
    return C.Define("build_stairs", id, def)
end
stairs("stairs_straight", {
    name = "Straight-Run Oak Stairs", style = "traditional", material = "wood", price = 450, env = 0, fp = { { 0, 0 }, { 0, 1 } }, height = 2.25,
    desc = "Twelve honest oak treads with turned newel posts. Connects two floors in the most direct way known to carpentry.",
    -- bottom: where you start on this level; top: landing on the level above; run: cells climbed (the upstairs stairwell)
    stairs = { bottom = { 0, 2 }, top = { 0, -1 }, run = { { 0, 1 }, { 0, 0 } } },
    variants = K.var("oak:Oak:0.72,0.52,0.30", "white:Painted White Risers:0.94,0.94,0.92", "walnut:Walnut:0.42,0.28,0.18"),
})
stairs("stairs_long", {
    name = "Floating Steel-and-Glass Stairs", style = "contemporary", material = "wood", price = 1100, env = 3, fp = { { 0, 0 }, { 0, 1 }, { 0, 2 } }, height = 2.25,
    desc = "Thick timber treads cantilevered from a steel spine behind a glass rail. A gentle three-tile climb that looks like sculpture.",
    stairs = { bottom = { 0, 3 }, top = { 0, -1 }, run = { { 0, 2 }, { 0, 1 }, { 0, 0 } } },
    variants = K.var("oak:Oak & Steel:0.72,0.52,0.30", "black:Black & Steel:0.16,0.16,0.17", "white:White & Glass:0.94,0.94,0.92"),
})
stairs("stairs_turn", {
    name = "Painted Quarter-Turn Stairs", style = "eclectic", material = "wood", price = 780, env = 1, fp = { { 0, 0 }, { 0, 1 }, { 1, 0 } }, height = 2.25,
    desc = "Cottage stairs with a painted runner that climb, turn a corner at a winder landing and arrive upstairs slightly out of breath. Fits an L-shaped corner where a straight run will not.",
    stairs = { bottom = { 0, 2 }, top = { 2, 0 }, run = { { 0, 1 }, { 0, 0 }, { 1, 0 } } },
    variants = K.var("runner:Red Runner:0.74,0.20,0.20", "stripe:Striped Runner:0.30,0.42,0.62", "bare:Painted Grey:0.62,0.62,0.60"),
})
F.STAIRS = { "stairs_straight", "stairs_long", "stairs_turn" }

---------------------------------------------------------------------------------------------------
-- Coordinated style sets: finishes (and a few catalogue designs) that furnish a room in one style.
---------------------------------------------------------------------------------------------------
F.SETS = {
    starter = { walls = { "paint_cream", "paint_sky", "siding_vinyl", "paper_check", "tile_check_bath", "brick_red" },
        floors = { "floor_laminate", "floor_lino", "carpet", "floor_carpet_beige", "floor_paving_concrete" },
        doors = { "door_basic" }, windows = { "window_basic", "window_frosted" }, roof = "roof_asphalt", fence = "fence_board" },
    traditional = { walls = { "panel_oak", "paper_stripe_regency", "paper_damask_gold", "siding_white", "brick_yellow", "tile_marble" },
        floors = { "wood", "floor_oak_herringbone", "floor_carpet_rose", "floor_marble", "floor_paving_sandstone" },
        doors = { "door_panel", "door_front_oak", "door_double_french", "arch_round" }, windows = { "window_sash", "window_arched", "window_bay" },
        roof = "roof_slate", fence = "fence_picket", stairs = "stairs_straight" },
    contemporary = { walls = { "paint_white", "paint_charcoal", "paper_grasscloth", "tile_subway", "siding_metal", "concrete_board" },
        floors = { "floor_concrete", "floor_tile_large", "floor_carpet_plush", "floor_ebony", "floor_deck_composite" },
        doors = { "door_glass", "door_pocket", "door_double_patio", "arch_wide" }, windows = { "window_tall", "window_wide", "window_clerestory" },
        roof = "roof_metal", fence = "fence_iron", stairs = "stairs_long" },
    eclectic = { walls = { "paint_mustard", "paper_geo", "paper_flock", "tile_zellige", "brick_glazed", "stucco_adobe" },
        floors = { "floor_terrazzo", "floor_encaustic", "floor_carpet_shag", "floor_reclaimed", "floor_paving_mosaic" },
        doors = { "door_stable", "arch_keyhole", "door_double_grand" }, windows = { "window_porthole", "window_stained", "window_cafe" },
        roof = "roof_thatch", fence = "fence_bamboo", stairs = "stairs_turn" },
    garden = { walls = { "siding_barn", "siding_shingle", "panel_beadboard", "brick_white", "stucco_peach", "paper_floral" },
        floors = { "grass", "path", "floor_deck_cedar", "floor_gravel", "floor_sisal" },
        doors = { "door_screen" }, windows = { "window_shutter" }, roof = "roof_cedar", fence = "fence_ranch" },
}

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------
-- cheap | mid | premium for a finish entry of `kind` (uses the gate price for fences' gates via kind "gates").
function F.Tier(kind, e)
    local t = F.TIERS[kind]
    if not t or not e then return "mid" end
    if e.price <= t[1] then return "cheap" elseif e.price <= t[2] then return "mid" end
    return "premium"
end

function F.Count(kind)
    local n = 0
    for _ in pairs(F[kind] or {}) do n = n + 1 end
    return n
end

-- Sorted ids of one kind (price, then id); optional style filter.
function F.List(kind, style)
    local out = {}
    for id, e in pairs(F[kind] or {}) do if not style or e.style == style then out[#out + 1] = id end end
    table.sort(out, function(a, b)
        local ea, eb = F[kind][a], F[kind][b]
        if ea.price ~= eb.price then return ea.price < eb.price end
        return a < b
    end)
    return out
end

-- Validation (tests and diagnostics): returns a list of problems.
function F.Validate()
    local p = {}
    local styles = {}
    for _, s in ipairs(C.STYLES) do styles[s] = true end
    local function checkLook(kind, where, lk)
        if type(lk) ~= "table" then p[#p + 1] = where .. ": no look"; return end
        if not (F.PATTERN_OK[kind] and F.PATTERN_OK[kind][lk.pattern or ""]) then p[#p + 1] = where .. ": pattern " .. tostring(lk.pattern) end
        if not C.isColor(lk.color) then p[#p + 1] = where .. ": colour" end
        if not C.isColor(lk.color2) then p[#p + 1] = where .. ": colour2" end
        if type(lk.scale) ~= "number" or lk.scale <= 0 then p[#p + 1] = where .. ": scale" end
    end
    for _, kind in ipairs(F.KINDS) do
        for id, e in pairs(F[kind]) do
            local where = kind .. "." .. id
            if type(e.name) ~= "string" or #e.name < 3 then p[#p + 1] = where .. ": name" end
            if type(e.desc) ~= "string" or #e.desc < 20 then p[#p + 1] = where .. ": desc" end
            if type(e.price) ~= "number" or e.price < 0 or e.price ~= math.floor(e.price) then p[#p + 1] = where .. ": price" end
            if not styles[e.style or ""] then p[#p + 1] = where .. ": style " .. tostring(e.style) end
            checkLook(kind, where, e.look)
            if (kind == "walls" or kind == "floors") and not C.isColor(e.color) then p[#p + 1] = where .. ": color" end
            if kind == "doors" and not (e.width == 1 or e.width == 2) then p[#p + 1] = where .. ": width" end
            if kind == "windows" and not (e.look.size and e.look.size.h and e.look.size.sill) then p[#p + 1] = where .. ": size" end
            if kind == "fences" and not (e.gate and e.gate.name and e.gate.price and e.gate.price > 0) then p[#p + 1] = where .. ": gate" end
            if kind == "roofs" and (type(e.colors) ~= "table" or #e.colors < 3) then p[#p + 1] = where .. ": colours" end
        end
    end
    for style, set in pairs(F.SETS) do
        for kind, ids in pairs(set) do
            local map = (kind == "roof" and F.roofs) or (kind == "fence" and F.fences) or (kind == "stairs" and SS.Objects) or F[kind]
            if type(ids) == "string" then ids = { ids } end
            for _, id in ipairs(ids) do
                local e = map and map[id]
                if not e then p[#p + 1] = "set " .. style .. "." .. kind .. ": missing " .. id
                elseif e.style ~= style then p[#p + 1] = "set " .. style .. "." .. kind .. ": " .. id .. " is " .. tostring(e.style) end
            end
        end
    end
    for _, id in ipairs(F.STAIRS) do
        local d = SS.Objects[id]
        if not (d and d.stairs and d.stairs.bottom and d.stairs.top and d.stairs.run) then p[#p + 1] = "stairs " .. id .. " missing" end
    end
    return p
end
