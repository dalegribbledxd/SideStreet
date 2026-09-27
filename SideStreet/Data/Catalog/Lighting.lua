-- Buy-mode catalogue: Lighting (brief §8.1: at least 14 designs).
-- Owner: catalogue module. Every light has light = 0..1 (output into World.RoomLight while
-- state.on is true), starts switched on, and lists "lampon"/"lampoff" (household-core). Tag lamp
-- lets household-core add automatic switching. Mounts: table lamps go on surfaces, wall lights on
-- solid walls, ceiling lights need a ceiling (indoor room, or under an upper floor).
local _, SS = ...
local C = SS.Catalog
local K = C.K
local add = C.Category("lighting")
local var = K.var
local LAMP_TOPS = { "table", "desk", "end", "shelf", "counter" }
local function lamp(def)
    -- fresh tables per definition: SS.Tags.Apply appends to def.actions
    def.actions, def.tags, def.startState = { "lampon", "lampoff" }, { "lamp" }, { on = true }
    def.slots = def.slots or { front = (def.mount == "wall" or def.mount == "ceiling") and K.under("use") or K.around("use") }
    return def
end

add("lamp_floor", lamp({ -- original 0.1.0 object
    name = "Standing Lamp, Linen Shade", sub = "floor", style = "starter", material = "fabric", price = 55, env = 4, light = 0.8,
    rooms = { "living", "bedroom", "study" }, height = 1.6,
    desc = "For illuminating the room, not your financial decisions. A tall reading light that brightens a small room for very little money.",
    slots = { front = K.front() },
    variants = var("linen:Linen & Brass:0.94,0.90,0.80", "white:White & Chrome:0.96,0.96,0.96", "green:Green & Bronze:0.40,0.52,0.36"),
}))

add("lamp_floor_arc", lamp({
    name = "Arc Floor Lamp", sub = "floor", style = "contemporary", material = "metal", price = 320, env = 6, light = 0.9,
    rooms = { "living", "study" }, height = 2.0,
    desc = "A marble base and a steel arc that leans over the sofa like a curious giraffe. Bright, wide light and a strong design statement.",
    slots = { front = K.front() },
    variants = var("steel:Steel & Marble:0.80,0.82,0.84", "brass:Brass & Marble:0.84,0.70,0.40", "black:Black & Granite:0.16,0.16,0.17"),
}))

add("lamp_floor_tiffany", lamp({
    name = "Stained-Glass Floor Lamp", sub = "floor", style = "eclectic", material = "glass", price = 480, env = 8, light = 0.6,
    rooms = { "living", "study" }, height = 1.7,
    desc = "A leaded shade in dragonfly glass that throws jewel-coloured light across the ceiling. Gives more atmosphere than brightness, and plenty of both.",
    slots = { front = K.front() },
    variants = var("dragonfly:Dragonfly:0.40,0.62,0.52", "poppy:Poppy:0.86,0.36,0.24", "wisteria:Wisteria:0.58,0.48,0.80"),
}))

add("lamp_table_basic", lamp({
    name = "Budget Bedside Lamp", sub = "table", style = "starter", material = "fabric", price = 25, env = 1, light = 0.5,
    rooms = { "bedroom", "living", "study" }, mount = "surface", fits = LAMP_TOPS, height = 0.5,
    desc = "A ceramic base, a pleated shade and a switch cord that is always on the far side. Modest light for a nightstand or desk at pocket-money prices.",
    variants = var("white:White:0.96,0.96,0.95", "blue:Blue:0.40,0.52,0.74", "yellow:Yellow:0.96,0.86,0.42"),
}))

add("lamp_table_brass", lamp({
    name = "Brass Banker's Lamp", sub = "table", style = "traditional", material = "metal", price = 140, env = 4, light = 0.6,
    rooms = { "study", "living" }, mount = "surface", fits = LAMP_TOPS, height = 0.45,
    desc = "A green glass shade on a brass stem, as seen on every desk where money was once counted slowly. Warm, focused light for a desk or side table.",
    variants = var("green:Green Glass:0.20,0.46,0.30", "amber:Amber Glass:0.86,0.58,0.20", "blue:Cobalt Glass:0.18,0.30,0.70"),
}))

add("lamp_table_lava", lamp({
    name = "Lava Glow Lamp", sub = "table", style = "eclectic", material = "glass", price = 90, env = 4, light = 0.3,
    rooms = { "bedroom", "living", "kids" }, mount = "surface", fits = LAMP_TOPS, height = 0.5,
    desc = "Warm wax rising and sinking through coloured liquid, forever and very slowly. Dim but hypnotic; residents have been known to watch it instead of the television.",
    variants = var("orange:Orange & Red:0.96,0.46,0.20", "purple:Purple & Pink:0.62,0.30,0.72", "green:Green & Yellow:0.52,0.86,0.30"),
}))

add("lamp_table_ceramic", lamp({
    name = "Ceramic Gourd Table Lamp", sub = "table", style = "contemporary", material = "fabric", price = 180, env = 5, light = 0.7,
    rooms = { "living", "bedroom" }, mount = "surface", fits = LAMP_TOPS, height = 0.65,
    desc = "A glazed gourd-shaped base under a wide drum shade. Generous, even light and the smug air of something bought in a gallery shop.",
    variants = var("celadon:Celadon:0.66,0.80,0.70", "oxblood:Oxblood Glaze:0.54,0.14,0.14", "cream:Cream Crackle:0.94,0.90,0.80"),
}))

add("light_wall_sconce", lamp({
    name = "Candle-Arm Wall Sconce", sub = "wall", style = "traditional", material = "metal", price = 110, env = 4, light = 0.5,
    rooms = { "living", "dining", "bedroom" }, mount = "wall", height = 1.8,
    desc = "Two electric candles on curled brass arms, for rooms that want to feel like they have a history. Hangs on a solid wall and gives soft, flattering light.",
    variants = var("brass:Brass:0.84,0.68,0.34", "iron:Black Iron:0.14,0.14,0.14", "silver:Silver:0.82,0.84,0.86"),
}))

add("light_wall_strip", lamp({
    name = "Brushed Steel Wall Bar", sub = "wall", style = "contemporary", material = "metal", price = 160, env = 3, light = 0.7,
    rooms = { "bathroom", "kitchen", "living" }, mount = "wall", height = 1.9,
    desc = "A slim steel bar with a frosted diffuser that lights a bathroom mirror or a hallway without fuss. Bright, even and hard to argue with.",
    variants = var("steel:Steel:0.80,0.82,0.84", "black:Black:0.14,0.14,0.15", "white:White:0.96,0.96,0.96"),
}))

add("light_ceiling_bulb", lamp({
    name = "Bare Bulb Pendant", sub = "ceiling", style = "starter", material = "glass", price = 20, env = 0, light = 0.6,
    rooms = { "kitchen", "bathroom", "bedroom", "living", "study", "dining" }, mount = "ceiling", height = 0.5,
    desc = "One bulb on one flex, lighting the room with the warmth of an interrogation. Cheap, bright enough to cook by, and no shade to dust.",
    variants = var("clear:Clear Bulb:0.98,0.96,0.86", "amber:Amber Bulb:0.96,0.72,0.36"),
}))

add("light_ceiling_flush", lamp({
    name = "Frosted Flush Ceiling Light", sub = "ceiling", style = "traditional", material = "glass", price = 85, env = 2, light = 0.8,
    rooms = { "kitchen", "bathroom", "bedroom", "living", "study", "dining" }, mount = "ceiling", height = 0.2,
    desc = "A frosted glass dome that sits tight to the ceiling and quietly collects moths. Bright, even light for any room with a ceiling.",
    variants = var("frost:Frosted:0.94,0.94,0.92", "etched:Etched Flowers:0.92,0.90,0.86", "amber:Amber:0.92,0.78,0.52"),
}))

add("light_ceiling_pendant", lamp({
    name = "Trio Glass Pendant", sub = "ceiling", style = "contemporary", material = "glass", price = 420, env = 6, light = 0.9,
    rooms = { "kitchen", "dining", "living" }, mount = "ceiling", height = 0.8,
    desc = "Three hand-blown glass globes on staggered cords, hung low over a table to make dinner look professionally photographed. Bright and decorative.",
    variants = var("smoke:Smoked Glass:0.46,0.46,0.48", "clear:Clear Glass:0.90,0.94,0.96", "copper:Copper Glass:0.74,0.46,0.30"),
}))

add("light_chandelier", lamp({
    name = "Crystal Cascade Chandelier", sub = "ceiling", style = "traditional", material = "metal", price = 1800, env = 12, light = 1.0,
    rooms = { "dining", "living" }, mount = "ceiling", height = 1.0,
    desc = "Two hundred crystal drops arranged to catch every light in the room and throw it back with interest. The brightest fixture sold, and a room-score showpiece.",
    variants = var("crystal:Clear Crystal:0.94,0.96,0.98", "amber:Amber Crystal:0.92,0.74,0.40", "black:Black Crystal:0.20,0.20,0.24"),
}))

add("light_outdoor_post", lamp({
    name = "Lamppost Lantern", sub = "outdoor", style = "garden", material = "metal", price = 240, env = 3, light = 0.9,
    rooms = { "outdoor", "venue" }, height = 2.4, groundOnly = true,
    desc = "A cast lantern on a fluted post that lights the path and makes the house look expected. Bright enough for the whole front garden.",
    slots = { front = K.front() },
    variants = var("black:Black:0.14,0.14,0.14", "green:Heritage Green:0.20,0.36,0.26", "copper:Copper:0.74,0.46,0.30"),
}))

add("light_outdoor_path", lamp({
    name = "Solar Path Light", sub = "outdoor", style = "garden", material = "metal", price = 30, env = 1, light = 0.3,
    rooms = { "outdoor" }, height = 0.5, outdoor = true,
    desc = "A little stake with a solar cap that glows politely all evening. Dim on its own, lovely in a row along a garden path.",
    slots = { front = K.around("use") },
    variants = var("steel:Steel:0.80,0.82,0.84", "copper:Copper:0.74,0.46,0.30", "black:Black:0.14,0.14,0.15"),
}))

add("light_outdoor_wall", lamp({
    name = "Porch Carriage Lantern", sub = "outdoor", style = "traditional", material = "metal", price = 95, env = 2, light = 0.6,
    rooms = { "outdoor" }, mount = "wall", height = 1.8,
    desc = "A glass-sided lantern for beside the front door, so visitors can find the bell and you can see who they are first. Hangs on an outside wall.",
    variants = var("black:Black:0.14,0.14,0.14", "brass:Brass:0.84,0.68,0.34", "white:White:0.96,0.96,0.96"),
}))

add("light_string", lamp({
    name = "Festoon String Lights", sub = "outdoor", style = "eclectic", material = "wood", price = 150, env = 5, light = 0.5,
    rooms = { "outdoor", "venue" }, fp = K.rect(2, 1), height = 2.2, groundOnly = true,
    desc = "Two poles and a swag of round bulbs between them, turning any yard into a party waiting for guests. Soft light over two cells of patio.",
    slots = { front = K.frontWide(2) },
    variants = var("warm:Warm White:0.98,0.90,0.70", "multi:Multicolour:0.90,0.50,0.40", "cool:Cool White:0.92,0.96,0.98"),
}))
