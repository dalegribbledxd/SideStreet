-- SideStreet object catalogue: the shared definition kit, derived ratings, validation and queries.
-- Owner: catalogue module. Field reference: ARCHITECTURE.md §7; notes: docs/modules/catalogue.md.
-- The designs live in Data/Catalog/<Category>.lua (one file per buy-mode category); build-catalogue
-- items (stairs) live with the finishes in Data/Finishes.lua.
--
-- Local frame: the object's front faces +y. Facing k rotates by R^k (0 = +y, 1 = -x, 2 = -y, 3 = +x).
-- Footprint cells, slot cells, approaches and surface cells are all in this local frame.
-- A slot is { approaches = {{dx,dy},...}, face, on = bool, group = "seat"|"bed"|..., cell = {dx,dy}, pose }.
--   on = true: the actor moves onto the object (seat, bed side, shower); `cell` says which footprint
--   cell (default {0,0}). Otherwise the actor stands on an approach cell and faces the object.
-- height (tiles) is the object's top: floor and surface items measure from their own base; wall and
--   window items hang at their real height, so height is the top edge above the floor; ceiling items
--   give how far they hang below the ceiling (SS.World.STORY above the floor).
-- Every design has a visual spec at def.art.model = "design/catalog/<cat>.json#<id>" (written by
--   design/catalog/_generate.py, schema sidestreet-model-1 of docs/ART.md on the art branch).
-- Ratings shown in buy mode are never typed in: C.DeriveRatings computes them from the numbers the
-- simulation reads (rates, quality, env, light). tests/test_catalogue.lua checks every definition.
local _, SS = ...
SS.Objects = SS.Objects or {}
local C = SS.Catalog or {}
SS.Catalog = C
C.order = C.order or {}   -- buy-mode design ids in definition order
C.OWN_SLOTS = C.OWN_SLOTS or {}   -- id -> sorted slot names declared by the catalogue (see C.Define)

---------------------------------------------------------------------------------------------------
-- Vocabularies
---------------------------------------------------------------------------------------------------
C.STYLES = { "starter", "traditional", "contemporary", "eclectic", "garden" }
C.STYLE_LABEL = { starter = "Starter", traditional = "Traditional", contemporary = "Contemporary",
    eclectic = "Eclectic", garden = "Garden & Patio" }
C.ROOMS = { "kitchen", "dining", "living", "bedroom", "bathroom", "study", "kids", "outdoor", "venue" }
C.ROOM_LABEL = { kitchen = "Kitchen", dining = "Dining", living = "Living", bedroom = "Bedroom", bathroom = "Bathroom",
    study = "Study", kids = "Kids", outdoor = "Outdoor", venue = "Venue" }
C.MOUNTS = { floor = true, wall = true, ceiling = true, surface = true, window = true }
C.SURFACE_KINDS = { counter = true, table = true, desk = true, shelf = true, ["end"] = true }
C.ALL_SURFACES = { "counter", "table", "desk", "shelf", "end" }

-- Tag vocabulary (ARCHITECTURE.md §7): tag -> module that attaches behaviour to it.
C.TAGS = {}
local function owner(mod, list) for tag in list:gmatch("%S+") do C.TAGS[tag] = mod end end
owner("household-core", "fridge stove oven microwave coffee toaster counter dishwasher sink bin bin_outdoor grill buffet "
    .. "table_dining bed bed_child toilet shower bath basin seat sofa tv stereo radio computer game book lamp "
    .. "clock_alarm dresser mirror rug painting")
owner("events", "smoke_alarm burglar_alarm fireplace memorial extinguisher")   -- extinguisher: docs/requests/events.md CT-2
owner("visitors", "phone mailbox doorbell newspaper")
owner("household-core+careers", "bookshelf chess easel piano instrument exercise arcade pinball pool_table darts dance dj "
    .. "workbench telescope")
owner("family", "crib toybox kid_play highchair pet_bed pet_bowl litter pet_toy aquarium garden_plot planter tree shrub "
    .. "flowers fountain birdbath")
owner("outings", "register display_clothing changing_booth display_gift display_books display_decor podium waiter_station "
    .. "cafe_kitchen cafe_table dj_booth bar restroom")

-- Occupant poses (ARCHITECTURE.md §6 pose list) plus "garden", the family module's gardening pose
-- (requested from the art module in docs/art_requests/catalogue.md). Slot poses must come from here.
C.POSES = {}
for p in ("idle walk run sit sleep use talk laugh argue eat eat_stand cook wash bathe shower clean repair exercise "
    .. "celebrate panic mourn collapse carry swim dance read play paint phone greet hug kiss cry sit_talk sit_eat type lie garden"):gmatch("%S+") do
    C.POSES[p] = true
end

-- Main material of each design (def.material): what it is mostly made of and how readily it burns. The
-- events module's fire spread reads it (Data/Events.lua fire.material: fabric 1.4 ... stone 0) when a
-- design has no quality.fireRisk. Every design names one; tests check it against the model spec.
C.MATERIALS = {}
for m in ("fabric wood paper plastic wicker leather metal chrome stone glass porcelain ceramic plant"):gmatch("%S+") do C.MATERIALS[m] = true end

-- Object state keys the renderer understands (ARCHITECTURE.md §5), plus the ones sibling modules set:
-- mail (careers), lit (events: fireplaces), ringing (events/household-core: alarms, phones, clocks),
-- unmade (household-core: beds), weeds (family: garden plots). o.state.stage = n is drawn with the
-- model spec's "stage<n>" look (design/catalog/*.json).
C.STATES = { on = true, open = true, broken = true, dirty = true, burning = true, burnt = true, wilted = true, stage = true,
    water = true, full = true, cooking = true, cooked = true, spoiled = true, occupied = true, mail = true,
    lit = true, ringing = true, unmade = true, weeds = true }

-- Buy-mode categories. `min` is the brief §8.1 minimum; `tiers` are the price bands used to label
-- cheap / midrange / aspirational pieces (price <= cheap, <= mid, above).
C.CATEGORIES = {
    { id = "seating", label = "Seating", short = "Seats", min = 16, tiers = { 150, 600 }, file = "Seating",
        subs = { { "dining", "Dining chairs" }, { "desk", "Desk chairs" }, { "stool", "Stools" }, { "armchair", "Armchairs" },
            { "sofa", "Sofas & loveseats" }, { "recliner", "Recliners" }, { "lounge", "Lounge seating" }, { "bench", "Benches" }, { "outdoor", "Outdoor chairs" } } },
    { id = "sleeping", label = "Sleeping", short = "Beds", min = 8, tiers = { 450, 1200 }, file = "Sleeping",
        subs = { { "single", "Single beds" }, { "double", "Double beds" }, { "child", "Children's beds" }, { "compact", "Compact sleepers" } } },
    { id = "surfaces", label = "Tables & Surfaces", short = "Tables", min = 12, tiers = { 150, 600 }, file = "Surfaces",
        subs = { { "dining", "Dining tables" }, { "desk", "Desks" }, { "coffee", "Coffee & end tables" }, { "counter", "Kitchen counters" },
            { "display", "Sideboards" }, { "outdoor", "Outdoor tables" } } },
    { id = "kitchen", label = "Kitchen & Food", short = "Kitchen", min = 16, tiers = { 200, 900 }, file = "Kitchen",
        subs = { { "fridge", "Fridges" }, { "stove", "Stoves" }, { "small", "Small appliances" }, { "dishwasher", "Dishwashers" },
            { "bin", "Bins" }, { "grill", "Grills" }, { "serving", "Serving" } } },
    { id = "plumbing", label = "Plumbing", short = "Bath", min = 10, tiers = { 400, 1000 }, file = "Plumbing",
        subs = { { "toilet", "Toilets" }, { "sink", "Sinks & basins" }, { "shower", "Showers" }, { "bath", "Baths" } } },
    { id = "electronics", label = "Electronics & Utilities", short = "Electric", min = 10, tiers = { 150, 1000 }, file = "Electronics",
        subs = { { "tv", "Televisions" }, { "audio", "Radios & stereos" }, { "computer", "Computers" }, { "phone", "Phones" },
            { "safety", "Clocks & safety" } } },
    { id = "lighting", label = "Lighting", short = "Lights", min = 14, tiers = { 60, 300 }, file = "Lighting",
        subs = { { "table", "Table lamps" }, { "floor", "Floor lamps" }, { "wall", "Wall lights" }, { "ceiling", "Ceiling lights" },
            { "outdoor", "Outdoor lights" } } },
    { id = "skill", label = "Skill & Entertainment", short = "Hobbies", min = 14, tiers = { 400, 1200 }, file = "Skill",
        subs = { { "books", "Books & study" }, { "games", "Games" }, { "creative", "Art & music" }, { "fitness", "Fitness" },
            { "party", "Dance & DJ" }, { "hobby", "Science & tinkering" } } },
    { id = "storage", label = "Storage & Dressing", short = "Storage", min = 10, tiers = { 150, 600 }, file = "Storage",
        subs = { { "dresser", "Dressers & wardrobes" }, { "mirror", "Mirrors" }, { "shelf", "Shelves & cabinets" } } },
    { id = "decor", label = "Decoration", short = "Decor", min = 24, tiers = { 100, 800 }, file = "Decor",
        subs = { { "art", "Paintings & posters" }, { "rug", "Rugs" }, { "window", "Curtains & blinds" }, { "plant", "Indoor plants" },
            { "sculpture", "Sculptures" }, { "clock", "Clocks" }, { "clutter", "Vases, books & clutter" }, { "hanging", "Wall hangings" },
            { "fireplace", "Fireplaces" } } },
    { id = "outdoor", label = "Outdoor & Garden", short = "Garden", min = 14, tiers = { 100, 400 }, file = "Outdoor",
        subs = { { "tree", "Trees" }, { "shrub", "Shrubs" }, { "flowers", "Flower beds" }, { "planter", "Planters" },
            { "water", "Fountains & birdbaths" }, { "seating", "Garden seating" }, { "games", "Outdoor games" },
            { "garden", "Plots & tools" }, { "accent", "Path accents" } } },
    { id = "kids", label = "Childcare & Pets", short = "Kids/Pets", min = 10, tiers = { 100, 300 }, file = "Kids",
        subs = { { "baby", "Baby care" }, { "toys", "Toys & play" }, { "pets", "Pet care" }, { "tank", "Tanks & habitats" } } },
    { id = "community", label = "Community & Service", short = "Venue", min = 10, tiers = { 500, 1200 }, file = "Community",
        subs = { { "shop", "Registers & displays" }, { "clothing", "Clothing" }, { "dining", "Restaurant" }, { "club", "Club & bar" },
            { "public", "Public utilities" } } },
}
C.CAT = {}
for n, c in ipairs(C.CATEGORIES) do
    c.order = n
    c.subLabel = {}
    for _, s in ipairs(c.subs) do c.subLabel[s[1]] = s[2] end
    C.CAT[c.id] = c
end
C.MIN_TOTAL = 168

---------------------------------------------------------------------------------------------------
-- Derived ratings (0..10). Only numbers another module actually reads become ratings:
--   rates[need]          comfort/energy/fun per sim hour, read by the executor while the object is
--                        used (Actions applyEffects: `def.rates[need]` replaces the interaction's
--                        rate; sitting or lying on it gives posture comfort; TV and music fun go
--                        through Leisure.EquipmentFun). C.RATE_READ lists, per need, the tags whose
--                        interactions read it; Validate refuses a rate nothing reads.
--   washing gains        a shower's, bath's or basin's hygiene/comfort is a one-off gain the
--                        executor scales by 0.7 + 0.06 x the rating, so for those the rating
--                        itself is the number the simulation uses (rates only set the rating).
--   quality.cooking      0..10 appliance quality for meal quality and burns (household-core
--                        Chains.ApplianceQ), cooking appliances only (C.CookTags)
--   quality.breakChance  base chance to break per use, rising with wear (household-core
--                        Maintenance.OnUse); a design without one breaks at household-core's
--                        per-tag default (SS.Tuning.breakChance), rated the same way -> Durability
--   quality.fireRisk     multiplier on every cooking fire chance, 1 = normal (Chains.FireChance,
--                        events Fire.CookingChance); cooking appliances without one are x1 -> Safety
--   env                  decoration value into the room score (World.RoomScore)
--   light                light output into room lighting (World.RoomLight)
-- Read but not rated: quality.capacity where C.CAPACITY_READ names the tag (dishwasher load, bin
-- size, standing spots, players, sleepers), quality.repairDifficulty (repairs), quality.range
-- (events' alarms), def.noise (World.NoiseAt while the object is on), def.appreciates (resale).
-- Requested, not read yet (docs/requests/catalogue.md HC-3, FA-2, FA-3): quality.skill (practice
-- rate), quality.speed (work speed), quality.freshness (fridge spoil time), quality.dirtRate (dirt
-- per use), and capacity on fridges, garden plots and tanks. Their ratings and "holds" lines appear
-- only once the reading module calls C.SetReader(key), so buy mode never shows a number that
-- changes nothing.
-- `use` picks the scale for comfort/hygiene: a sofa's comfort per hour is not a bed's.
---------------------------------------------------------------------------------------------------
C.RATE_TOPS = {
    sit = { comfort = 60 }, sleep = { comfort = 16, energy = 20 }, wash = { comfort = 45, hygiene = 600 },
    basin = { hygiene = 300 }, toilet = { comfort = 40, hygiene = 30 }, other = { comfort = 60, hygiene = 300 },
}
C.READERS = C.READERS or {}   -- "skill" / "speed:garden_plot" ... -> true once a module reads it (C.SetReader)
C.FUN_TOP, C.ENERGY_TOP, C.ENV_TOP = 50, 20, 25
C.BREAK_TOP, C.FIRE_TOP = 0.01, 2   -- break chance per use at which durability is 0; fire multiplier at which safety is 0

-- Which tags' interactions read def.rates[need] (merged tree, household-core executor plus the
-- modules that attach interactions): "rate" = replaces the interaction's rate per hour, "posture" =
-- sitting on it while doing something else, "gain" = scales a one-off washing gain via the rating.
C.RATE_READ = {
    comfort = { seat = "rate", sofa = "rate", bed = "rate", bed_child = "rate", toilet = "posture", restroom = "posture",
        shower = "gain", bath = "gain" },
    energy = { bed = "rate", bed_child = "rate" },
    hygiene = { basin = "gain", sink = "gain", shower = "gain", bath = "gain" },
    fun = { tv = "rate", radio = "rate", stereo = "rate", computer = "rate", game = "rate", chess = "rate", piano = "rate",
        instrument = "rate", arcade = "rate", pinball = "rate", pool_table = "rate", darts = "rate", dance = "rate", dj = "rate",
        telescope = "rate", toybox = "rate", kid_play = "rate", aquarium = "rate", bath = "gain" },
}
-- quality.capacity is read for these tags (format for the buy-mode line; false = shown another way).
C.CAPACITY_READ = {
    dishwasher = "loads %d dishes", bin = "holds %d rubbish", bin_outdoor = "holds %d rubbish",
    stereo = "room for %d around it", radio = "room for %d around it", dj = "room for %d around it",
    dance = "room for %d dancers", tv = "room for %d around it", pool_table = "%d players", darts = "%d players",
    bed = false,   -- household-core's HoodLots.Sleeps; buy mode already shows the sleepers
}
C.COOK_TAGS_FALLBACK = { stove = true, oven = true, microwave = true, grill = true, toaster = true }
-- Capacity another module has been asked to read (docs/requests/catalogue.md): kept as data, not shown.
C.CAPACITY_ASKED = { fridge = true, garden_plot = true, aquarium = true }
-- def.noise is heard only while the object is on (World.NoiseAt): things that switch on.
C.NOISE_TAGS = { stereo = true, radio = true, dj = true, dj_booth = true, tv = true, dishwasher = true }
C.QUALITY_KEYS = { cooking = true, breakChance = true, fireRisk = true, repairDifficulty = true, capacity = true, range = true,
    skill = true, speed = true, freshness = true, dirtRate = true }

function C.SortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local function rnd(v)
    v = math.floor(v + 0.5)
    if v < 0 then return 0 elseif v > 10 then return 10 end
    return v
end

function C.Has(def, tag)
    for _, t in ipairs(def.tags or {}) do if t == tag then return true end end
    return false
end

-- Tags that cook (household-core Food.applianceTags when loaded).
function C.CookTags()
    local at = SS.Food and SS.Food.applianceTags
    if type(at) ~= "table" then return C.COOK_TAGS_FALLBACK end
    local t = {}
    for _, list in pairs(at) do
        for _, tag in ipairs(list) do t[tag] = true end
    end
    return t
end

function C.IsCooker(def)
    local ct = C.CookTags()
    for _, t in ipairs(def.tags or {}) do if ct[t] then return true end end
    return false
end

-- The break chance per use the simulation rolls for this design (before wear): its own, else
-- household-core's default for its first tag that has one (Maintenance.BreakChance), else nil.
function C.BreakChance(def)
    local q = def.quality or {}
    if q.breakChance then return q.breakChance, true end
    local tb = SS.Tuning and SS.Tuning.breakChance
    if type(tb) ~= "table" then return nil end
    for _, t in ipairs(def.tags or {}) do
        if tb[t] ~= nil then return tb[t], false end
    end
end

-- Does anything read this need from def.rates? Returns the way it is read ("rate", "posture", "gain").
function C.RateRead(def, need)
    local by = C.RATE_READ[need]
    if not by then return nil end
    for _, t in ipairs(def.tags or {}) do if by[t] then return by[t] end end
end

-- Has a module declared (C.SetReader) that it reads this requested field for this design? A key
-- alone ("speed") covers every design; "speed:garden_plot" covers designs with that tag only.
function C.Reads(key, def)
    if C.READERS[key] then return true end
    for _, t in ipairs(def.tags or {}) do
        if C.READERS[key .. ":" .. t] then return true end
    end
    return false
end

-- Is quality.capacity read for this design? Returns the format (or false for beds) and the tag.
function C.CapacityRead(def)
    for _, t in ipairs(def.tags or {}) do
        if C.CAPACITY_READ[t] ~= nil then return C.CAPACITY_READ[t], t end
    end
    if C.Reads("capacity", def) then return "holds %d" end
end

-- The buy-mode capacity line, only when the capacity is read ("loads 12 dishes").
function C.CapacityText(def)
    local q = def.quality or {}
    if type(q.capacity) ~= "number" then return nil end
    local fmt = C.CapacityRead(def)
    if not fmt then return nil end
    return string.format(fmt, q.capacity)
end

-- Does a module read quality[key] for this design today? (Requested fields turn true when their
-- reader calls C.SetReader.) Tests use it to tell a real difference from a recolour.
local GATED = { skill = "skill", speed = "speed", freshness = "freshness", dirtRate = "clean" }
function C.QualityRead(def, key)
    if key == "breakChance" or key == "repairDifficulty" or key == "range" then return true end
    if key == "cooking" or key == "fireRisk" then return C.IsCooker(def) end
    if key == "capacity" then return C.CapacityRead(def) ~= nil end
    if GATED[key] then return C.Reads(GATED[key], def) end
    return false
end

-- The object's principal use (scale for its ratings). Explicit def.use wins.
function C.Use(def)
    if def.use then return def.use end
    if C.Has(def, "bed") or C.Has(def, "bed_child") or C.Has(def, "crib") or C.Has(def, "pet_bed") then return "sleep" end
    if C.Has(def, "shower") or C.Has(def, "bath") then return "wash" end
    if C.Has(def, "toilet") or C.Has(def, "restroom") then return "toilet" end
    if C.Has(def, "basin") or C.Has(def, "sink") then return "basin" end
    if C.Has(def, "seat") or C.Has(def, "sofa") then return "sit" end
    return "other"
end

local function gainText(rating, what)
    return string.format("each %s x%.2f (%s)", what, 0.7 + 0.06 * rating, "0.7 + 0.06 x rating")
end

-- Returns ratings table (only keys with a real source) and a parallel table of source text.
function C.DeriveRatings(def)
    local r, src = {}, {}
    local rates, q = def.rates or {}, def.quality or {}
    local tops = C.RATE_TOPS[C.Use(def)] or C.RATE_TOPS.other
    if rates.comfort then
        r.comfort = rnd(10 * rates.comfort / tops.comfort)
        local how = C.RateRead(def, "comfort")
        if how == "gain" then src.comfort = gainText(r.comfort, "wash's comfort")
        elseif how == "posture" then src.comfort = rates.comfort .. " comfort per hour, a share of it while seated on it"
        else src.comfort = rates.comfort .. " comfort per hour" end
    end
    if rates.energy then r.energy = rnd(10 * rates.energy / C.ENERGY_TOP); src.energy = rates.energy .. " energy per hour" end
    if rates.fun then
        r.fun = rnd(10 * rates.fun / C.FUN_TOP)
        src.fun = C.RateRead(def, "fun") == "gain" and gainText(r.fun, "soak's fun") or (rates.fun .. " fun per hour")
    end
    if rates.hygiene then
        r.hygiene = rnd(10 * rates.hygiene / (tops.hygiene or 240))
        src.hygiene = gainText(r.hygiene, "wash's hygiene")
    end
    if (def.env or 0) > 0 then r.room = rnd(10 * def.env / C.ENV_TOP); src.room = "adds " .. def.env .. " to the room score" end
    if def.light then r.light = rnd(10 * def.light); src.light = "light output " .. def.light end
    local cooker = C.IsCooker(def)
    if q.cooking and cooker then r.cooking = rnd(q.cooking); src.cooking = "cooking quality " .. q.cooking .. " of 10 (meal quality and burns)" end
    local reads = C.Reads
    if q.skill and reads("skill", def) then r.skill = rnd(5 * q.skill); src.skill = "skill practice x" .. q.skill end
    if q.speed and reads("speed", def) then r.speed = rnd(5 * q.speed); src.speed = "works at x" .. q.speed .. " speed" end
    if q.freshness and reads("freshness", def) then r.freshness = rnd(5 * q.freshness); src.freshness = "food keeps x" .. q.freshness .. " longer" end
    local bc, own = C.BreakChance(def)
    if bc and bc > 0 then
        r.durability = rnd(10 * (1 - bc / C.BREAK_TOP))
        src.durability = string.format("%.2f%% base chance to break per use, rising with wear%s", bc * 100, own and "" or " (standard for its kind)")
    end
    if q.fireRisk or cooker then
        local fr = q.fireRisk or 1
        r.safety = rnd(10 * (1 - fr / C.FIRE_TOP))
        src.safety = string.format("cooking fire chance x%.2f (1 = an ordinary appliance)", fr)
    end
    if q.dirtRate and reads("clean", def) then r.clean = rnd(5 / q.dirtRate); src.clean = "gets dirty x" .. q.dirtRate .. " as fast" end
    return r, src
end

-- A module that starts reading one of the requested quality fields calls this once at load
-- (guarded: `if SS.Catalog and SS.Catalog.SetReader then SS.Catalog.SetReader("skill") end`);
-- every design's ratings are derived again so buy mode shows the new rating from then on.
-- key: "skill" | "speed" | "freshness" | "clean" | "capacity", alone (every design) or with ":<tag>"
-- for the designs with that tag only ("speed:garden_plot", "capacity:fridge", "clean:litter").
function C.SetReader(key)
    if C.READERS[key] then return end
    C.READERS[key] = true
    for _, id in ipairs(C.order) do
        local def = SS.Objects[id]
        if def then def.ratings, def.ratingSource = C.DeriveRatings(def) end
    end
end

C.RATING_ORDER = { "comfort", "energy", "fun", "hygiene", "cooking", "skill", "speed", "freshness", "light", "room", "clean", "durability", "safety" }
C.RATING_LABEL = { comfort = "Comfort", energy = "Energy", fun = "Fun", hygiene = "Hygiene", cooking = "Cooking", skill = "Skill",
    speed = "Speed", freshness = "Freshness", light = "Light", room = "Room", clean = "Cleanliness", durability = "Durability", safety = "Safety" }

function C.Tier(def)
    local cat = C.CAT[def.cat]
    if not cat then return "mid" end
    if def.price <= cat.tiers[1] then return "cheap" elseif def.price <= cat.tiers[2] then return "mid" end
    return "premium"
end
C.TIER_LABEL = { cheap = "Budget", mid = "Midrange", premium = "Aspirational" }

---------------------------------------------------------------------------------------------------
-- Geometry helpers
---------------------------------------------------------------------------------------------------
local function rot(a, b, k)
    k = k % 4
    if k == 1 then return -b, a elseif k == 2 then return -a, -b elseif k == 3 then return b, -a end
    return a, b
end
C.rot = rot

-- Footprint set: "dx,dy" -> true (local).
function C.FootSet(def)
    if def._fset then return def._fset end
    local s = {}
    for _, c in ipairs(def.fp or { { 0, 0 } }) do s[c[1] .. "," .. c[2]] = true end
    rawset(def, "_fset", s)
    return s
end

-- Size of the local bounding box: w (x), d (y) in cells.
function C.Size(def)
    local minx, maxx, miny, maxy = 1e9, -1e9, 1e9, -1e9
    for _, c in ipairs(def.fp or { { 0, 0 } }) do
        if c[1] < minx then minx = c[1] end; if c[1] > maxx then maxx = c[1] end
        if c[2] < miny then miny = c[2] end; if c[2] > maxy then maxy = c[2] end
    end
    return maxx - minx + 1, maxy - miny + 1, minx, miny
end

-- Surface slots flattened: { { key = "n:k", surface = n, slot = k, cell = {dx,dy}, z, kind, off = {ox,oy} }, ... }.
-- obj.pslot of a child resting on a surface is the slot key "n:k" (surface n, slot k), the same key
-- World.SurfaceSlots (household-core) uses. `off` is the slot's offset from the cell centre (local tiles):
-- the per-count pattern below plus the surface's own `off` (a shallow wall shelf moves its row to the wall).
local OFFSETS = {
    [1] = { { 0, 0 } }, [2] = { { -0.22, 0 }, { 0.22, 0 } }, [3] = { { -0.28, 0 }, { 0, 0 }, { 0.28, 0 } },
    [4] = { { -0.2, -0.2 }, { 0.2, -0.2 }, { -0.2, 0.2 }, { 0.2, 0.2 } },
}
C.SLOT_OFFSETS = OFFSETS
function C.SurfaceSlots(def)
    if def._sslots then return def._sslots end
    local out = {}
    for n, s in ipairs(def.surfaces or {}) do
        local offs = OFFSETS[s.slots or 1] or OFFSETS[1]
        local so = s.off or { 0, 0 }
        for k = 1, (s.slots or 1) do
            local o = offs[k] or { 0, 0 }
            out[#out + 1] = { key = n .. ":" .. k, surface = n, slot = k, cell = s.cell or { 0, 0 }, z = s.z, kind = s.kind,
                off = { o[1] + so[1], o[2] + so[2] } }
        end
    end
    rawset(def, "_sslots", out)
    return out
end
function C.SurfaceSlot(def, key)
    for _, s in ipairs(C.SurfaceSlots(def)) do if s.key == key then return s end end
end

-- Number of seats / bed sides / other occupant places.
function C.Places(def, group)
    local n = 0
    for _, sl in pairs(def.slots or {}) do if sl.group == group then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------------------------------
-- Definition kit used by the category files (short constructors keep the data readable).
---------------------------------------------------------------------------------------------------
local K = {}
C.K = K

-- Stand in front and use (front faces +y). dist = how far in front (TV viewing distance).
function K.front(dist, pose)
    return { approaches = { { 0, dist or 1 } }, face = 2, pose = pose or "use" }
end
-- Use from the front of a wide object: approach cells along its front edge (cells 0..w-1).
function K.frontWide(w, pose, dy)
    local a = {}
    for x = 0, w - 1 do a[#a + 1] = { x, dy or 1 } end
    return { approaches = a, face = 2, pose = pose or "use" }
end
-- Use from any side of a 1x1 object that sits on a surface or is small (approach any neighbour).
function K.around(pose)
    return { approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }, face = 2, pose = pose or "use" }
end
-- Mounted (wall/ceiling) things are used from their own (non-blocking) cell or its neighbours.
function K.under(pose)
    return { approaches = { { 0, 0 }, { 0, 1 }, { 1, 0 }, { -1, 0 } }, face = 2, pose = pose or "use" }
end
-- A single seat on the object's own cell, entered from the front or the sides.
function K.seat(pose)
    return { approaches = { { 0, 1 }, { 1, 0 }, { -1, 0 } }, face = 0, on = true, group = "seat", pose = pose or "sit" }
end
-- n seats in a row along +x (sofas, benches). Returns slots table seat1..seatn.
function K.seatRow(n, pose)
    local s = {}
    for x = 0, n - 1 do
        local ap = { { x, 1 } }
        if x == 0 then ap[#ap + 1] = { -1, 0 } end
        if x == n - 1 then ap[#ap + 1] = { n, 0 } end
        s["seat" .. (x + 1)] = { cell = { x, 0 }, approaches = ap, face = 0, on = true, group = "seat", pose = pose or "sit" }
    end
    return s
end
-- A single bed (cells {0,0} head, {0,1} foot) entered from either side.
function K.bedSingle(pose)
    return { bed = { cell = { 0, 0 }, approaches = { { 1, 0 }, { -1, 0 }, { 1, 1 }, { -1, 1 } }, face = 0, on = true, group = "bed", pose = pose or "sleep" } }
end
-- A double bed 2 wide x 2 deep: two sides, each entered from its own side.
function K.bedDouble(pose)
    return {
        bed1 = { cell = { 0, 0 }, approaches = { { -1, 0 }, { -1, 1 } }, face = 0, on = true, group = "bed", pose = pose or "sleep" },
        bed2 = { cell = { 1, 0 }, approaches = { { 2, 0 }, { 2, 1 } }, face = 0, on = true, group = "bed", pose = pose or "sleep" },
    }
end
-- Rectangular footprint w (along x) by d (along y, toward the front).
function K.rect(w, d)
    local fp = {}
    for y = 0, (d or 1) - 1 do for x = 0, (w or 1) - 1 do fp[#fp + 1] = { x, y } end end
    return fp
end
-- One surface per cell of a w x d rectangle.
-- `off` (optional) moves every slot of each surface by {ox, oy} tiles from the cell centre, e.g. toward
-- the wall for a shallow wall shelf.
function K.surf(kind, z, w, d, slots, off)
    local s = {}
    for y = 0, (d or 1) - 1 do
        for x = 0, (w or 1) - 1 do
            s[#s + 1] = { cell = { x, y }, z = z, kind = kind, slots = slots or 1, off = off and { off[1], off[2] } or nil }
        end
    end
    return s
end
-- Variants from "id:Name:r,g,b" strings (tint is the main material colour the art module applies).
function K.var(...)
    local out = {}
    for n = 1, select("#", ...) do
        local s = select(n, ...)
        local id, name, col = s:match("^([%w_]+):([^:]+):?(.*)$")
        local v = { id = id, name = name }
        if col and col ~= "" then
            local r, g, b = col:match("([%d%.]+),([%d%.]+),([%d%.]+)")
            v.tint = { tonumber(r), tonumber(g), tonumber(b) }
        end
        out[#out + 1] = v
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------------------------------
local DEFAULTS_NOBLOCK = { wall = true, ceiling = true, surface = true, window = true }

-- Finalise one definition (defaults, derived fields) and register it.
function C.Define(cat, id, def)
    def.id = id
    def.cat = def.cat or cat
    def.fp = def.fp or { { 0, 0 } }
    def.mount = def.mount or "floor"
    def.env = def.env or 0
    def.slots = def.slots or {}
    def.actions = def.actions or {}
    def.tags = def.tags or {}
    def.rooms = def.rooms or { "living" }
    def.variants = def.variants or K.var("standard:Standard")
    if def.noBlock == nil then def.noBlock = (DEFAULTS_NOBLOCK[def.mount] or def.rug) and true or false end
    if def.mount == "surface" then def.fits = def.fits or C.ALL_SURFACES end
    def.height = def.height or 1
    def.art = def.art or { model = "design/catalog/" .. def.cat .. ".json#" .. id }
    -- visitors' work slot (docs/requests/visitors.md): a standing, ungrouped `front` is also the "svc"
    -- place where repair workers, cleaners, gardeners and callers stand, so a household user and a
    -- visitor never hold the same spot under two names (the same rule as SS.Visitors.EnsureSlot)
    local front = def.slots.front
    if front and not front.on and front.group == nil and not def.slots.svc then front.group = "svc" end
    -- the slot names this module declares (the model specs mirror these; other modules may add their
    -- own at run time, e.g. visitors' svc fallback, which the specs do not need to draw)
    local own = {}
    for name in pairs(def.slots) do own[#own + 1] = name end
    table.sort(own)
    C.OWN_SLOTS[id] = own
    -- seats: the executor's TV-viewer logic looks for def.seat
    if def.seat == nil and C.Places(def, "seat") > 0 and C.Has(def, "seat") then def.seat = true end
    def.ratings, def.ratingSource = C.DeriveRatings(def)
    def.tier = C.Tier(def)
    if SS.Objects[id] and SS.Objects[id] ~= def then SS.Log("catalogue: %s defined twice", id) end
    SS.Objects[id] = def
    if def.buyable ~= false and C.CAT[def.cat] then C.order[#C.order + 1] = id end
    if SS.Tags and SS.Tags.Apply then SS.Tags.Apply(def) end
    return def
end

-- Returns a function add(id, def) bound to one category.
function C.Category(cat)
    return function(id, def) return C.Define(cat, id, def) end
end

---------------------------------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------------------------------
-- query = { cat, sub, tag, style, maxPrice, minPrice, buyable } -> cheapest matching def id (ties by id), or nil.
-- Kept stable for premade houses, venues and services (hood, outings, visitors).
function C.Find(query)
    if type(query) ~= "table" then return nil end
    local best, bestPrice
    for id, def in pairs(SS.Objects) do
        local ok = def.buyable ~= false
        if query.buyable == false then ok = true end
        if query.cat and def.cat ~= query.cat then ok = false end
        if query.sub and def.sub ~= query.sub then ok = false end
        if query.style and def.style ~= query.style then ok = false end
        if query.tag and not C.Has(def, query.tag) then ok = false end
        if query.maxPrice and (def.price or 0) > query.maxPrice then ok = false end
        if query.minPrice and (def.price or 0) < query.minPrice then ok = false end
        if query.room and not C.InRoom(def, query.room) then ok = false end
        if ok and (not best or def.price < bestPrice or (def.price == bestPrice and id < best)) then best, bestPrice = id, def.price end
    end
    return best
end

function C.InRoom(def, room)
    for _, r in ipairs(def.rooms or {}) do if r == room then return true end end
    return false
end

-- Case-insensitive plain-text match over the name, category and subcategory labels, style,
-- rooms, tags and variant names ("walnut" finds every design sold in walnut).
function C.Matches(def, text)
    if not text or text == "" then return true end
    text = text:lower()
    local hay = def._hay
    if not hay then
        local cat = C.CAT[def.cat]
        local parts = { def.name, cat and cat.label or "", cat and cat.subLabel[def.sub or ""] or "", C.STYLE_LABEL[def.style or ""] or "",
            table.concat(def.rooms or {}, " "), table.concat(def.tags or {}, " ") }
        for _, v in ipairs(def.variants or {}) do parts[#parts + 1] = v.name or "" end
        hay = table.concat(parts, " "):lower()
        rawset(def, "_hay", hay)
    end
    return hay:find(text, 1, true) ~= nil
end

-- Filtered, sorted list of design ids. f = { cat, sub, room, style, text, sort = "price"|"-price"|"name", community = bool }
-- community: true lists venue-only designs too (editing a community lot); false hides them.
function C.List(f)
    f = f or {}
    local out = {}
    for _, id in ipairs(C.order) do
        local def = SS.Objects[id]
        local ok = def ~= nil
        if ok and f.cat and def.cat ~= f.cat then ok = false end
        if ok and f.sub and def.sub ~= f.sub then ok = false end
        if ok and f.room and not C.InRoom(def, f.room) then ok = false end
        if ok and f.style and def.style ~= f.style then ok = false end
        if ok and f.community == false and def.community then ok = false end
        if ok and f.text and not C.Matches(def, f.text) then ok = false end
        if ok then out[#out + 1] = id end
    end
    local sort = f.sort or "price"
    table.sort(out, function(a, b)
        local da, db = SS.Objects[a], SS.Objects[b]
        if sort == "name" then if da.name ~= db.name then return da.name < db.name end
        elseif sort == "-price" then if da.price ~= db.price then return da.price > db.price end
        elseif da.price ~= db.price then return da.price < db.price end
        return a < b
    end)
    return out
end

function C.Count(cat)
    local n = 0
    for _, id in ipairs(C.order) do if not cat or SS.Objects[id].cat == cat then n = n + 1 end end
    return n
end

-- Variant record by id (default: first).
function C.Variant(def, vid)
    for _, v in ipairs(def.variants or {}) do if v.id == vid then return v end end
    return def.variants and def.variants[1]
end

-- Plain-language placement requirements for buy mode.
function C.Requirements(def)
    local t = {}
    local m = def.mount
    if m == "wall" then t[#t + 1] = "Hangs on a solid wall"
    elseif m == "window" then t[#t + 1] = "Fits a window"
    elseif m == "ceiling" then t[#t + 1] = "Needs a ceiling (indoors, or under an upper floor)"
    elseif m == "surface" then
        local kinds = {}
        for _, k in ipairs(def.fits or C.ALL_SURFACES) do kinds[#kinds + 1] = k end
        t[#t + 1] = "Goes on a " .. table.concat(kinds, "/") .. " surface"
    elseif def.rug then t[#t + 1] = "Lies flat; furniture can stand on it and rugs can layer"
    else t[#t + 1] = "Stands on a flat floor" end
    if def.outdoor then t[#t + 1] = "outdoors only" end
    if def.groundOnly then t[#t + 1] = "ground level only" end
    if def.wallBack then t[#t + 1] = "needs a wall behind it" end
    if def.community then t[#t + 1] = "community venues only" end
    if def.kidOnly then t[#t + 1] = "children only" end
    if def.adultOnly then t[#t + 1] = "adults only" end
    if def.pet then t[#t + 1] = "for pets" end
    if def.staffOnly then t[#t + 1] = "staff only" end
    if def.powered then t[#t + 1] = "uses electricity" end
    if def.appreciates then t[#t + 1] = "keeps its full value when sold" end
    local n = 0
    for _ in pairs(def.slots or {}) do n = n + 1 end
    if n > 0 and not def.noBlock then t[#t + 1] = "keep its approach cells clear" end
    return table.concat(t, "; ") .. "."
end

---------------------------------------------------------------------------------------------------
-- Validation (used by tests and /sidestreet diag). Returns a list of problems (empty = valid).
---------------------------------------------------------------------------------------------------
local function isColor(c) return type(c) == "table" and type(c[1]) == "number" and type(c[2]) == "number" and type(c[3]) == "number" end
C.isColor = isColor

function C.Validate(id, def)
    local p = {}
    local function bad(msg) p[#p + 1] = id .. ": " .. msg end
    if type(def.name) ~= "string" or #def.name < 3 then bad("name") end
    if type(def.desc) ~= "string" or #def.desc < 40 then bad("description too short") end
    if not C.CAT[def.cat] then bad("unknown category " .. tostring(def.cat)) end
    local cat = C.CAT[def.cat]
    if cat and not cat.subLabel[def.sub or ""] then bad("unknown subcategory " .. tostring(def.sub)) end
    local okStyle = false
    for _, s in ipairs(C.STYLES) do if s == def.style then okStyle = true end end
    if not okStyle then bad("style " .. tostring(def.style)) end
    if type(def.price) ~= "number" or def.price <= 0 or def.price ~= math.floor(def.price) then bad("price") end
    if type(def.env) ~= "number" then bad("env") end
    if type(def.rooms) ~= "table" or #def.rooms == 0 then bad("rooms") end
    for _, r in ipairs(def.rooms or {}) do if not C.ROOM_LABEL[r] then bad("room " .. tostring(r)) end end
    if not C.MOUNTS[def.mount] then bad("mount " .. tostring(def.mount)) end
    if type(def.height) ~= "number" or def.height <= 0 then bad("height") end
    -- footprint: unique, contiguous, contains {0,0}
    local fs = C.FootSet(def)
    local n, seen = 0, {}
    for _, c in ipairs(def.fp) do
        local k = c[1] .. "," .. c[2]
        if seen[k] then bad("duplicate footprint cell " .. k) end
        seen[k] = true
        n = n + 1
    end
    if not fs["0,0"] then bad("footprint must contain 0,0") end
    if n > 1 then
        local reach, stack = { ["0,0"] = true }, { { 0, 0 } }
        while #stack > 0 do
            local c = table.remove(stack)
            for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                local k = (c[1] + d[1]) .. "," .. (c[2] + d[2])
                if fs[k] and not reach[k] then reach[k] = true; stack[#stack + 1] = { c[1] + d[1], c[2] + d[2] } end
            end
        end
        for k in pairs(fs) do if not reach[k] then bad("footprint not contiguous at " .. k) end end
    end
    if def.mount ~= "floor" and n > 1 and def.mount ~= "wall" and def.mount ~= "window" then bad("only floor/wall/window mounts may span cells") end
    -- slots
    for name, sl in pairs(def.slots) do
        if type(sl.approaches) ~= "table" or #sl.approaches == 0 then bad("slot " .. name .. " has no approaches") end
        if type(sl.face) ~= "number" or sl.face < 0 or sl.face > 3 then bad("slot " .. name .. " face") end
        if sl.cell and not fs[sl.cell[1] .. "," .. sl.cell[2]] then bad("slot " .. name .. " cell outside footprint") end
        for _, a in ipairs(sl.approaches or {}) do
            local k = a[1] .. "," .. a[2]
            if fs[k] and not def.noBlock then bad("slot " .. name .. " approach " .. k .. " inside its own footprint") end
            if math.abs(a[1]) > 4 or math.abs(a[2]) > 4 then bad("slot " .. name .. " approach too far") end
        end
        if sl.on and not sl.cell and n > 1 then bad("slot " .. name .. " needs a cell on a multi-cell object") end
        if sl.pose and not C.POSES[sl.pose] then bad("slot " .. name .. " pose " .. tostring(sl.pose) .. " is not in the pose list") end
    end
    -- surfaces
    for k, s in ipairs(def.surfaces or {}) do
        if not C.SURFACE_KINDS[s.kind] then bad("surface " .. k .. " kind") end
        if type(s.z) ~= "number" or s.z <= 0 or s.z > 2.2 then bad("surface " .. k .. " height") end
        if not s.cell or not fs[s.cell[1] .. "," .. s.cell[2]] then bad("surface " .. k .. " cell outside footprint") end
        if s.slots ~= nil and (type(s.slots) ~= "number" or s.slots < 1 or s.slots > #OFFSETS or s.slots ~= math.floor(s.slots)) then
            bad("surface " .. k .. " slots must be 1.." .. #OFFSETS)
        end
        if s.off ~= nil and (type(s.off) ~= "table" or type(s.off[1]) ~= "number" or type(s.off[2]) ~= "number"
            or math.abs(s.off[1]) > 0.45 or math.abs(s.off[2]) > 0.45) then
            bad("surface " .. k .. " off must be {ox, oy} within 0.45 of the cell centre")
        end
    end
    if def.mount == "surface" then
        for _, k in ipairs(def.fits or {}) do if not C.SURFACE_KINDS[k] then bad("fits " .. tostring(k)) end end
    end
    -- actions must exist; tags must be in the vocabulary
    for _, iid in ipairs(def.actions) do
        if not (SS.Interactions and SS.Interactions[iid]) then bad("action " .. iid .. " does not exist") end
    end
    for _, t in ipairs(def.tags) do if not C.TAGS[t] then bad("tag " .. t .. " not in the vocabulary") end end
    -- ratings must equal the derivation
    local r = C.DeriveRatings(def)
    for k, v in pairs(r) do if def.ratings[k] ~= v then bad("rating " .. k .. " is not derived") end end
    for k in pairs(def.ratings) do if r[k] == nil then bad("rating " .. k .. " has no source") end end
    -- rates keys are needs, and something reads each one for this design's tags
    for k, v in pairs(def.rates or {}) do
        if type(v) ~= "number" then bad("rate " .. k) end
        local isNeed = false
        for _, need in ipairs(SS.Tuning.needs) do if need == k then isNeed = true end end
        if not isNeed then bad("rate " .. k .. " is not a need") end
        if not C.RateRead(def, k) then bad("rate " .. k .. " is read by nothing for tags " .. table.concat(def.tags or {}, ",")) end
    end
    -- quality: known keys, sane ranges, and only where a module reads (or has been asked to read) them
    local q = def.quality or {}
    for k in pairs(q) do
        if not C.QUALITY_KEYS[k] then bad("quality." .. tostring(k) .. " is not a catalogue field") end
    end
    if q.breakChance ~= nil and (type(q.breakChance) ~= "number" or q.breakChance <= 0 or q.breakChance > C.BREAK_TOP) then
        bad("breakChance must be above 0 and at most " .. C.BREAK_TOP .. " per use")
    end
    if q.fireRisk ~= nil and (type(q.fireRisk) ~= "number" or q.fireRisk < 0 or q.fireRisk > 3) then bad("fireRisk is a multiplier from 0 to 3") end
    if (q.fireRisk ~= nil or q.cooking ~= nil) and not C.IsCooker(def) then bad("cooking and fireRisk belong on cooking appliances only") end
    if q.cooking ~= nil and (type(q.cooking) ~= "number" or q.cooking < 0 or q.cooking > 10) then bad("cooking is 0..10") end
    if q.dirtRate and (q.dirtRate <= 0 or q.dirtRate > 5) then bad("dirtRate") end
    if q.capacity ~= nil then
        if type(q.capacity) ~= "number" or q.capacity < 1 or q.capacity ~= math.floor(q.capacity) then bad("capacity must be a whole number") end
        local asked = false
        for _, t in ipairs(def.tags or {}) do if C.CAPACITY_ASKED[t] then asked = true end end
        if C.CapacityRead(def) == nil and not asked then bad("capacity is read by nothing for tags " .. table.concat(def.tags or {}, ",")) end
    end
    if def.noise ~= nil then
        local noisy = false
        for _, t in ipairs(def.tags or {}) do if C.NOISE_TAGS[t] then noisy = true end end
        if type(def.noise) ~= "number" or def.noise < 0 or def.noise > 10 then bad("noise is 0..10") end
        if not noisy then bad("noise only counts on things that switch on (" .. table.concat(C.SortedKeys(C.NOISE_TAGS), ", ") .. ")") end
    end
    if def.light and (type(def.light) ~= "number" or def.light <= 0 or def.light > 1) then bad("light") end
    -- variants
    if type(def.variants) ~= "table" or #def.variants < 2 then bad("needs at least 2 colour/material variants") end
    local vs = {}
    for _, v in ipairs(def.variants or {}) do
        if vs[v.id] then bad("duplicate variant " .. tostring(v.id)) end
        vs[v.id] = true
        if type(v.name) ~= "string" then bad("variant name") end
        if v.tint and not isColor(v.tint) then bad("variant tint") end
    end
    if not C.MATERIALS[def.material or ""] then bad("material " .. tostring(def.material) .. " is not in C.MATERIALS") end
    for k, v in pairs(def.startState or {}) do if not C.STATES[k] then bad("startState " .. k) end end
    for _, flag in ipairs({ "powered", "kidOnly", "adultOnly", "pet", "community", "staffOnly", "outdoor", "groundOnly", "rug", "noBlock", "wallBack", "appreciates" }) do
        if def[flag] ~= nil and type(def[flag]) ~= "boolean" then bad("flag " .. flag) end
    end
    if not (def.art and type(def.art.model) == "string" and def.art.model:find("^design/catalog/" .. def.cat .. "%.json#" .. id .. "$")) then bad("art model path") end
    return p
end

-- Validate every buy-mode design. Returns total problems list.
function C.ValidateAll()
    local all = {}
    for _, id in ipairs(C.order) do
        for _, msg in ipairs(C.Validate(id, SS.Objects[id])) do all[#all + 1] = msg end
    end
    return all
end
