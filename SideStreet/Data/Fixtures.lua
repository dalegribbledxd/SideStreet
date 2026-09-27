-- SideStreet fixtures: the original starter bungalow (4 Juniper Lane) and its resident, and the
-- new-game entry point. Owner: hood module.
-- Walls: "x:i:j" is the edge along x at y=j (between cells (i,j-1) and (i,j));
--        "y:i:j" is the edge along y at x=i (between cells (i-1,j) and (i,j)).
-- Wall finishes: a = side with the lower cell coordinate, b = the other side.
local _, SS = ...

local function starterLot()
    local lot = {
        id = "lot_juniper_4", address = "4 Juniper Lane", w = 14, h = 11,
        kind = "residential", price = 0, version = 1,
        floor = { [0] = {}, [1] = {} }, walls = { [0] = {}, [1] = {} }, objects = {},
        roof = { style = "hipped", material = "shingle", color = "terracotta" },
    }
    local x0, y0, x1, y1 = 2, 2, 10, 8 -- house interior cells, inclusive
    local function setFloor(i, j, f) lot.floor[0][j * lot.w + i + 1] = f end
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do setFloor(i, j, "grass") end
    end
    for j = y0, y1 do
        for i = x0, x1 do setFloor(i, j, (i >= 8 and j <= 4) and "tile" or "wood") end
    end
    setFloor(4, 9, "path"); setFloor(4, 10, "path")
    local EXT, INT, BATH = "siding_sage", "paint_cream", "paint_seafoam"
    local W0 = lot.walls[0]
    local function wall(key, kind, a, b) W0[key] = { kind = kind or "wall", a = a, b = b } end
    for i = x0, x1 do
        wall("x:" .. i .. ":" .. y0, "wall", EXT, (i >= 8) and BATH or INT)
        wall("x:" .. i .. ":" .. (y1 + 1), "wall", INT, EXT)
    end
    for j = y0, y1 do
        wall("y:" .. x0 .. ":" .. j, "wall", EXT, INT)
        wall("y:" .. (x1 + 1) .. ":" .. j, "wall", (j <= 4) and BATH or INT, EXT)
    end
    -- bathroom partition
    for j = 2, 4 do wall("y:8:" .. j, "wall", INT, BATH) end
    for i = 8, 10 do wall("x:" .. i .. ":5", "wall", BATH, INT) end
    W0["x:9:5"].kind = "door"
    W0["x:4:9"].kind = "door"      -- front door
    W0["x:7:9"].kind = "window"
    W0["x:4:2"].kind = "window"
    W0["y:2:5"].kind = "window"
    W0["y:11:6"].kind = "window"

    local n = 0
    local function obj(def, x, y, f)
        n = n + 1
        local id = "o" .. n
        lot.objects[id] = { id = id, def = def, x = x, y = y, f = f or 0, level = 0 }
    end
    obj("fridge_basic", 2, 2, 0)
    obj("counter_basic", 3, 2, 0)
    obj("stove_basic", 4, 2, 0)
    obj("counter_basic", 5, 2, 0)
    obj("bin_indoor", 6, 2, 0)
    obj("bed_single", 10, 6, 1)
    obj("toilet_basic", 8, 2, 0)
    obj("sink_pedestal", 9, 2, 0)
    obj("shower_basic", 10, 2, 0)
    obj("table_small", 3, 6, 0)
    obj("chair_dining", 3, 7, 2)
    obj("tv_basic", 5, 4, 0)
    obj("armchair_basic", 5, 6, 2)
    obj("lamp_floor", 7, 7, 0)
    obj("plant_pot", 2, 8, 0)
    obj("plant_pot", 7, 3, 0)
    obj("plant_pot", 12, 9, 0)
    obj("plant_pot", 5, 9, 0)
    lot.nextObj = n + 1
    return lot
end

SS.Fixtures = {}
SS.Fixtures.StarterLot = starterLot

-- The original single-lot starter world (schema 2): Roz Kettering at 4 Juniper Lane. The
-- neighbourhood (SS.Hood.NewNeighborhood) starts from exactly this world and adds the rest of
-- Linden Hollow around it, so the starter household, lot layout and needs never change.
function SS.Fixtures.StarterWorld(seed)
    local T = SS.Tuning
    local lot = starterLot()
    return {
        schema = SS.SCHEMA, seed = seed or 12345, time = T.startTime, speed = 1,
        settings = { freeWill = true, walls = "cut", music = true, effects = true },
        hood = { id = "hood_linden", name = "Linden Hollow", lots = { [lot.id] = lot } },
        households = {
            hh_kettering = { id = "hh_kettering", name = "Kettering", money = T.startMoney, members = { "r1" },
                lotId = lot.id, ledger = {}, journal = {} },
        },
        residents = {
            r1 = {
                id = "r1", name = "Roz Kettering", age = "adult", householdId = "hh_kettering", lotId = lot.id,
                bio = "Tax clerk by day, amateur fern whisperer by night. Believes every problem can be solved with a snack.",
                look = { skin = { 0.87, 0.67, 0.52 }, hair = { 0.35, 0.20, 0.12 }, hairStyle = "long",
                         top = { 0.25, 0.62, 0.62 }, bottom = { 0.22, 0.25, 0.42 }, shoes = { 0.40, 0.26, 0.16 } },
                needs = { hunger = 20, energy = 45, bladder = 10, hygiene = 40, fun = 5, social = 30, comfort = 20, room = 0 },
                personality = { neat = 5, outgoing = 5, active = 5, playful = 5, nice = 5 },
                x = 4.5, y = 7.5, level = 0, facing = 0,
            },
        },
        active = { householdId = "hh_kettering", lotId = lot.id },
    }
end

-- A new save root (schema 2): the whole neighbourhood when the hood module is loaded, with the
-- starter household active; otherwise the single-lot starter world.
function SS.Fixtures.NewWorld(seed)
    if SS.Hood and SS.Hood.NewNeighborhood then return SS.Hood.NewNeighborhood(seed) end
    return SS.Fixtures.StarterWorld(seed)
end
