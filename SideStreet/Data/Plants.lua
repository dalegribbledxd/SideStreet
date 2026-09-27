-- SideStreet gardening data: crops for plots and planters, decorative plant care, garden
-- ornaments. Owner: family module. Growth and yield live here; Sim/Garden.lua only applies them.
-- This is elementary backyard gardening, not a farming game.
--
-- Plot state (obj.state): crop, stage (0 empty .. 4 ripe/bloom), grow (effective growth minutes),
-- water (0..100), weeds (0..100), wilted, wiltMin, dead, care (0..100), ripeAt, plantedAt.
local _, SS = ...

SS.PlantData = {
    -- Stage names (index = obj.state.stage). Stage 4 is harvestable.
    stages = { [0] = "Bare soil", [1] = "Seeded", [2] = "Sprouting", [3] = "Growing", [4] = "Ready to harvest" },

    -- Crops. kind "produce" goes to household inventory as an ingredient/sellable; "flowers" become
    -- bouquet gift items. stageHours: growth hours (while watered and not wilted) to reach stages 2, 3, 4.
    -- waterUse: water lost per hour. yield: {min, max} units scaled by care. value: price per unit (sale).
    crops = {
        tomato = { name = "Tomatoes", kind = "produce", seedCost = 12, stageHours = { 10, 30, 56 },
            waterUse = 3.0, yield = { 2, 6 }, value = 9, ingredient = "vegetable", env = 2 },
        lettuce = { name = "Lettuce", kind = "produce", seedCost = 6, stageHours = { 6, 18, 32 },
            waterUse = 3.5, yield = { 1, 3 }, value = 7, ingredient = "vegetable", env = 1 },
        carrot = { name = "Carrots", kind = "produce", seedCost = 8, stageHours = { 8, 24, 44 },
            waterUse = 2.5, yield = { 2, 5 }, value = 6, ingredient = "vegetable", env = 1 },
        pepper = { name = "Bell Peppers", kind = "produce", seedCost = 14, stageHours = { 12, 32, 60 },
            waterUse = 2.8, yield = { 2, 5 }, value = 11, ingredient = "vegetable", env = 2 },
        strawberry = { name = "Strawberries", kind = "produce", seedCost = 16, stageHours = { 10, 30, 52 },
            waterUse = 3.2, yield = { 3, 8 }, value = 8, ingredient = "fruit", env = 2 },
        pumpkin = { name = "Pumpkin", kind = "produce", seedCost = 20, stageHours = { 16, 48, 90 },
            waterUse = 3.6, yield = { 1, 2 }, value = 38, ingredient = "vegetable", env = 2 },
        herbs = { name = "Kitchen Herbs", kind = "produce", seedCost = 5, stageHours = { 5, 14, 26 },
            waterUse = 2.2, yield = { 2, 4 }, value = 4, ingredient = "herb", env = 1 },
        tulip = { name = "Tulips", kind = "flowers", seedCost = 10, stageHours = { 8, 24, 40 },
            waterUse = 2.6, yield = { 1, 2 }, value = 24, env = 4 },
        sunflower = { name = "Sunflowers", kind = "flowers", seedCost = 9, stageHours = { 10, 30, 50 },
            waterUse = 3.0, yield = { 1, 3 }, value = 18, env = 4 },
        rose = { name = "Roses", kind = "flowers", seedCost = 22, stageHours = { 14, 40, 72 },
            waterUse = 2.4, yield = { 1, 2 }, value = 45, env = 5 },
    },
    cropOrder = { "herbs", "lettuce", "carrot", "tomato", "pepper", "strawberry", "pumpkin", "tulip", "sunflower", "rose" },

    -- Plot behaviour.
    plot = {
        weedsPerHour = 1.2, weedsSlow = 60, weedsSlowFactor = 0.5, dryAt = 20, dryFactor = 0.75,
        wiltAfter = 12 * 60,          -- minutes at zero water before a crop wilts
        dieAfter = 48 * 60,           -- minutes wilted before it dies
        rotAfter = 72 * 60,           -- minutes ripe and unharvested before it rots
        careGood = { water = 30, weeds = 40 },
        waterDur = 5, weedDur = 10, plantDur = 8, harvestDur = 8, clearDur = 6, tendDur = 15,
        wiltedEnv = -3, deadEnv = -4, weedyAt = 60, weedyEnv = -1,
        bareDryPerHour = 1.0,         -- bare soil still dries out slowly
        planterWeedsFactor = 0.3,     -- indoor/patio planters get far fewer weeds
        needsWaterBelow = 35,         -- the gardener and residents water below this
        needsWeedingAt = 25,          -- ... and weed above this
    },

    -- Decorative plants by tag: water lost per hour (100 = full), wilt after this long at zero,
    -- and the environment penalty while wilted (replaces the object's own env contribution).
    decorative = {
        flowers = { waterUse = 2.5, wiltAfter = 12 * 60, wiltedEnv = -3 },
        shrub = { waterUse = 1.2, wiltAfter = 24 * 60, wiltedEnv = -3 },
        tree = { waterUse = 0.6, wiltAfter = 48 * 60, wiltedEnv = -2 },
        waterDur = 4,
    },

    -- Garden ornaments (family owns tags fountain and birdbath).
    fountain = { coinCost = 1, coinDur = 3, fun = 12, comfort = 4, admireMaxDur = 20, admireFun = 18 },
    birdbath = { waterUse = 2.0, refillDur = 4, watchMaxDur = 30, watchFun = 16, watchComfort = 6, emptyEnv = -1 },

    -- Weather other modules bring (SS.Garden.Stress): a dry spell takes this much water out of a
    -- living plant, and brings wilting this many minutes closer when it leaves the soil dry.
    stress = { dry_spell = { water = 70, dryMin = 6 * 60 } },

    -- Selling produce: the greengrocer's buyer visits and pays this share of the value.
    sale = { share = 1.0, arrive = { 60, 120 } },
}
