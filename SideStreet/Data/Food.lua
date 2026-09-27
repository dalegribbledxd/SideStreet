-- SideStreet food data (owner: household-core): recipes, snacks and drinks for the cooking chain
-- in Sim/Chains.lua. All text is original.
--
-- Recipe fields:
--   name, desc, kind = "breakfast" | "meal" | "snack" | "dessert"
--   cost        ingredients for the whole recipe (charged once at the fridge)
--   servings    portions produced (1 = an individual plate, more = a group serving dish)
--   hunger      hunger per full portion at quality 1 (scaled by Tuning.food.hungerQuality)
--   fun         extra fun per portion when well made
--   skill       recommended cooking level (below it the burn chance rises; free will avoids
--               recipes more than 2 levels above the cook)
--   prep        minutes of preparation at a counter/table surface (0 = none)
--   cook        minutes on the appliance (0 = none)
--   appliance   "stove" | "oven" | "microwave" | "grill" | "toaster" | nil (no heat)
--   difficulty  0..1, adds to the burn chance
--   fireRisk    multiplier on ignition chances when it burns (documented in docs/modules)
--   spoilHours  hours before a served dish spoils outside a fridge
--   hours       { from, to } preferred serving window (free will), in hours of the day
local _, SS = ...

SS.Food = {
    recipes = {
        toast = {
            name = "Buttered Toast", kind = "breakfast", cost = 2, servings = 1, hunger = 22, fun = 1, skill = 0,
            prep = 0, cook = 4, appliance = "toaster", difficulty = 0.05, fireRisk = 0.5, spoilHours = 4, hours = { 5, 11 },
            desc = "Bread that has been through something and came out golden.",
        },
        oats = {
            name = "Crunchy Oat Bowl", kind = "breakfast", cost = 3, servings = 1, hunger = 28, fun = 1, skill = 0,
            prep = 3, cook = 0, difficulty = 0, spoilHours = 3, hours = { 5, 11 },
            desc = "Oats, milk and a banana that was one day from a smoothie.",
        },
        sandwich = {
            name = "Deli Stack Sandwich", kind = "meal", cost = 6, servings = 1, hunger = 40, fun = 2, skill = 0,
            prep = 6, cook = 0, difficulty = 0, spoilHours = 6, hours = { 10, 16 },
            desc = "Four layers of commitment between two slices of bread.",
        },
        salad = {
            name = "Garden Crunch Salad", kind = "meal", cost = 8, servings = 2, hunger = 32, fun = 1, skill = 1,
            prep = 10, cook = 0, difficulty = 0.02, spoilHours = 5, hours = { 11, 21 },
            desc = "Leaves, seeds and a dressing with ambitions.",
        },
        noodles = {
            name = "Two-Minute Noodle Cup", kind = "snack", cost = 3, servings = 1, hunger = 30, fun = 0, skill = 0,
            prep = 0, cook = 3, appliance = "microwave", difficulty = 0.02, fireRisk = 0.2, spoilHours = 3,
            desc = "Takes two minutes, or four if you read the instructions.",
        },
        burrito = {
            name = "Freezer Burrito", kind = "meal", cost = 4, servings = 1, hunger = 36, fun = 1, skill = 0,
            prep = 0, cook = 4, appliance = "microwave", difficulty = 0.03, fireRisk = 0.2, spoilHours = 4,
            desc = "Lava in the middle, glacier at both ends.",
        },
        pancakes = {
            name = "Griddle Pancake Stack", kind = "breakfast", cost = 6, servings = 2, hunger = 42, fun = 4, skill = 1,
            prep = 6, cook = 10, appliance = "stove", difficulty = 0.12, fireRisk = 0.8, spoilHours = 5, hours = { 6, 12 },
            desc = "The first one is always a test pancake. It is always eaten anyway.",
        },
        omelette = {
            name = "Three-Egg Omelette", kind = "breakfast", cost = 5, servings = 1, hunger = 45, fun = 3, skill = 1,
            prep = 4, cook = 8, appliance = "stove", difficulty = 0.15, fireRisk = 0.8, spoilHours = 4, hours = { 6, 14 },
            desc = "Folded with confidence, flipped with hope.",
        },
        grilledcheese = {
            name = "Grilled Cheese & Tomato Soup", kind = "meal", cost = 8, servings = 2, hunger = 48, fun = 4, skill = 1,
            prep = 5, cook = 10, appliance = "stove", difficulty = 0.12, fireRisk = 1.0, spoilHours = 6, hours = { 11, 20 },
            desc = "A rainy-day classic, including on sunny days.",
        },
        spaghetti = {
            name = "Spaghetti Night", kind = "meal", cost = 18, servings = 4, hunger = 58, fun = 5, skill = 2,
            prep = 8, cook = 18, appliance = "stove", difficulty = 0.15, fireRisk = 1.0, spoilHours = 10, hours = { 16, 22 },
            desc = "Enough for four people, or two people and tomorrow's lunch.",
        },
        chili = {
            name = "Big-Pot Chili", kind = "meal", cost = 26, servings = 6, hunger = 62, fun = 5, skill = 3,
            prep = 12, cook = 30, appliance = "stove", difficulty = 0.2, fireRisk = 1.2, spoilHours = 12, hours = { 16, 22 },
            desc = "Tastes better the next day, according to people who only made it once.",
        },
        stirfry = {
            name = "Wok-Tossed Stir-Fry", kind = "meal", cost = 16, servings = 3, hunger = 55, fun = 7, skill = 4,
            prep = 12, cook = 10, appliance = "stove", difficulty = 0.35, fireRisk = 1.6, spoilHours = 8, hours = { 16, 22 },
            desc = "High heat, high stakes, a very high smoke alarm.",
        },
        casserole = {
            name = "Friday Casserole", kind = "meal", cost = 24, servings = 6, hunger = 60, fun = 4, skill = 3,
            prep = 12, cook = 35, appliance = "oven", difficulty = 0.18, fireRisk = 0.9, spoilHours = 14, hours = { 16, 22 },
            desc = "Everything in the fridge that still had a good attitude, baked.",
        },
        roast = {
            name = "Sunday Roast Chicken", kind = "meal", cost = 40, servings = 6, hunger = 70, fun = 8, skill = 5,
            prep = 15, cook = 50, appliance = "oven", difficulty = 0.3, fireRisk = 1.1, spoilHours = 12, hours = { 12, 21 },
            desc = "Crisp skin, proud cook, gravy that needs a plan.",
        },
        cake = {
            name = "Lemon Drizzle Cake", kind = "dessert", cost = 18, servings = 8, hunger = 20, fun = 12, skill = 4,
            prep = 15, cook = 35, appliance = "oven", difficulty = 0.3, fireRisk = 0.8, spoilHours = 24,
            desc = "Sharp, sweet and gone faster than it took to cool.",
        },
        burgers = {
            name = "Backyard Burgers", kind = "meal", cost = 20, servings = 4, hunger = 58, fun = 7, skill = 2,
            prep = 8, cook = 14, appliance = "grill", difficulty = 0.22, fireRisk = 1.5, spoilHours = 8, hours = { 11, 21 },
            desc = "Charcoal flavour, delivered whether ordered or not.",
        },
    },
    -- display/menu order
    order = { "toast", "oats", "sandwich", "salad", "noodles", "burrito", "pancakes", "omelette", "grilledcheese",
              "spaghetti", "chili", "stirfry", "casserole", "roast", "cake", "burgers" },
    -- a bite from the fridge: always less than the smallest cooked portion (cake or toast at
    -- quality 0 give 15-16), and less again when repeated (Tuning.food.snackRepeat)
    snack = { name = "Cheese & Crackers", cost = 4, hunger = 12, minutes = 15 },
    drinks = {
        juice = { name = "Glass of Orange Juice", cost = 1, hunger = 3, bladder = -15, fun = 2, energy = 0, minutes = 5 },
        coffee = { name = "Mug of Coffee", cost = 1, hunger = 0, bladder = -14, fun = 3, energy = 14, minutes = 6 },
        water = { name = "Glass of Water", cost = 0, hunger = 0, bladder = -12, fun = 0, energy = 0, minutes = 3 },
    },
    -- which appliance tags can cook which appliance kind (a range with an oven does both)
    applianceTags = {
        stove = { "stove" }, oven = { "oven" }, microwave = { "microwave" }, grill = { "grill" }, toaster = { "toaster" },
    },
    -- appliances that switch themselves off when the time is up (no overcooking)
    autoOff = { microwave = true, toaster = true },
    applianceLabel = { stove = "stove", oven = "oven", microwave = "microwave", grill = "grill", toaster = "toaster" },
    -- surfaces for preparing and serving (typed surface kinds)
    prepKinds = { counter = true, table = true },
    serveKinds = { counter = true, table = true, buffet = true },
}
