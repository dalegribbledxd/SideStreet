-- SideStreet community lot layouts (the 4 venues) and the lot builder SS.Venues.BuildLot.
-- Owner: outings module. The hood module places these lots on the neighbourhood map:
--   local lot, problems = SS.Venues.BuildLot(kind, id, address)
--   kind = "shops" | "cafe" | "park" | "club"; id/address optional (defaults below).
-- The builder is pure Lua (no WoW API, no Sim files needed), so it may run at data-load time.
-- Objects are furnished through SS.Catalog.Find with slot/fit checks and fall back to the outings
-- system objects (Data/Venues.lua) or base objects, so a valid venue results before and after the
-- catalogue integration. Wall keys: "x:i:j" = edge along x at y=j (between (i,j-1) and (i,j));
-- "y:i:j" = edge along y at x=i (between (i-1,j) and (i,j)). Wall finish a = lower-coordinate side.
local _, SS = ...
local VD = SS.VenueData
SS.Venues = SS.Venues or {}
local V = SS.Venues
local CL = { templates = {}, VERSION = 1 }
SS.CommunityLots = CL

---------------------------------------------------------------------------------------------------
-- small local grid helpers (same formulas as Sim/Grid.lua, which loads later)
local function rot(a, b, k)
    k = k % 4
    if k == 1 then return -b, a elseif k == 2 then return -a, -b elseif k == 3 then return b, -a end
    return a, b
end
local function edgeBetween(i, j, ni, nj)
    if ni == i + 1 then return "y:" .. ni .. ":" .. j
    elseif ni == i - 1 then return "y:" .. i .. ":" .. j
    elseif nj == j + 1 then return "x:" .. i .. ":" .. nj
    else return "x:" .. i .. ":" .. j end
end
CL.rot, CL.edgeBetween = rot, edgeBetween

local function sortedKeys(t)
    local ks = {}
    for k in pairs(t or {}) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
    return ks
end

-- Finish resolution: prefs are ids (used when they exist) or attribute tables matched against
-- the finish entry or its visual descriptor (pattern etc.); the last resort is `fallback`.
local function finishMatches(def, attrs)
    for k, v in pairs(attrs) do
        local got = def[k]
        if got == nil and type(def.vis) == "table" then got = def.vis[k] end
        if got == nil and type(def.look) == "table" then got = def.look[k] end
        if got ~= v then return false end
    end
    return true
end
function CL.Finish(kind, prefs, fallback)
    local F = SS.Finishes and SS.Finishes[kind]
    if type(F) ~= "table" then return fallback end
    for _, p in ipairs(prefs or {}) do
        if type(p) == "string" then
            if F[p] then return p end
        elseif type(p) == "table" then
            for _, id in ipairs(sortedKeys(F)) do
                if type(F[id]) == "table" and finishMatches(F[id], p) then return id end
            end
        end
    end
    if fallback and F[fallback] then return fallback end
    return fallback
end

---------------------------------------------------------------------------------------------------
-- Catalogue candidates for a furnishing spec, best first: SS.Catalog.Find's answer, then other
-- catalogue definitions matching the same query (price, id order), then the fallback.
local function matchesQuery(id, def, q)
    if def.buyable == false then return false end
    if q.cat and def.cat ~= q.cat then return false end
    if q.sub and def.sub ~= q.sub then return false end
    if q.style and def.style ~= q.style then return false end
    if q.tag and not (SS.Tags and SS.Tags.Has(def, q.tag)) then return false end
    if q.maxPrice and (def.price or 0) > q.maxPrice then return false end
    if q.minPrice and (def.price or 0) < q.minPrice then return false end
    return true
end

local function slotOrGroup(def, name)
    local slots = def.slots or {}
    if slots[name] then return true end
    for _, s in pairs(slots) do if s.group == name then return true end end
    return false
end

-- Does a definition offer what the venue needs from this anchor?
function CL.Suits(def, spec)
    if not def then return false end
    local mount = def.mount or "floor"
    if mount ~= "floor" then return false end
    for _, s in ipairs(spec.slots or {}) do
        if not slotOrGroup(def, s) then return false end
    end
    if spec.seat and not (def.seat and slotOrGroup(def, "seat")) then return false end
    if spec.actions and #(def.actions or {}) == 0 then return false end
    -- a venue activity anchor must offer that activity (a catalogue chess table that only has the
    -- household's own chess game would leave the park without its venue game)
    if spec.activity then
        local ok = false
        for _, a in ipairs(def.actions or {}) do
            if a == spec.activity or a:match("^([^@]+)@") == spec.activity then ok = true end
        end
        if not ok then return false end
    end
    if spec.cells and #(def.fp or { { 0, 0 } }) ~= spec.cells then return false end
    -- anchors that stand where customers are (the waiter station on the dining floor): no
    -- staff-only designs (they close their room to customers), and the named slots must have a
    -- public spot (the counter fallback's pickup)
    if spec.public then
        if def.staffOnly then return false end
        for _, name in ipairs(spec.publicSlots or {}) do
            local ok = false
            for sname, sl in pairs(def.slots or {}) do
                if (sname == name or sl.group == name) and not sl.staff then ok = true end
            end
            if not ok then return false end
        end
    end
    return true
end

function CL.Candidates(spec)
    local out, seen = {}, {}
    local function add(id)
        if id and SS.Objects[id] and not seen[id] then seen[id] = true; out[#out + 1] = id end
    end
    local q
    if spec.tag or spec.query then
        q = {}
        for k, v in pairs(spec.query or {}) do q[k] = v end
        if spec.tag then q.tag = spec.tag end
        if SS.Catalog and SS.Catalog.Find then add(SS.Catalog.Find(q)) end
        local more = {}
        for id, def in pairs(SS.Objects) do
            if not seen[id] and matchesQuery(id, def, q) then more[#more + 1] = id end
        end
        table.sort(more, function(a, b)
            local pa, pb = SS.Objects[a].price or 0, SS.Objects[b].price or 0
            if pa ~= pb then return pa < pb end
            return a < b
        end)
        for n = 1, math.min(#more, 8) do add(more[n]) end
    end
    local list = {}
    for _, id in ipairs(out) do if CL.Suits(SS.Objects[id], spec) then list[#list + 1] = id end end
    if spec.fallback and SS.Objects[spec.fallback] then
        local dup = false
        for _, id in ipairs(list) do if id == spec.fallback then dup = true end end
        if not dup then list[#list + 1] = spec.fallback end
    end
    return list
end

---------------------------------------------------------------------------------------------------
-- Lot assembly
local function idx(lot, i, j) return j * lot.w + i + 1 end
local function inLot(lot, i, j) return i >= 0 and j >= 0 and i < lot.w and j < lot.h end

local function fillFloor(lot, i0, j0, i1, j1, finish)
    for j = j0, j1 do
        for i = i0, i1 do
            if inLot(lot, i, j) then lot.floor[0][idx(lot, i, j)] = finish end
        end
    end
end

local function setWall(lot, key, kind, a, b, style)
    local w = lot.walls[0][key]
    if w then
        w.kind = kind or w.kind
        if a then w.a = a end
        if b then w.b = b end
        if style then w.style = style end
    else
        lot.walls[0][key] = { kind = kind or "wall", a = a, b = b, style = style }
    end
end

-- Walls round an interior rectangle (cells i0..i1 x j0..j1): ext outside, int inside.
local function building(lot, b, ext, int)
    local i0, j0, i1, j1 = b[1], b[2], b[3], b[4]
    for i = i0, i1 do
        setWall(lot, "x:" .. i .. ":" .. j0, "wall", ext, int)       -- north: a = outside (j0-1)
        setWall(lot, "x:" .. i .. ":" .. (j1 + 1), "wall", int, ext) -- south: a = inside
    end
    for j = j0, j1 do
        setWall(lot, "y:" .. i0 .. ":" .. j, "wall", ext, int)       -- west: a = outside
        setWall(lot, "y:" .. (i1 + 1) .. ":" .. j, "wall", int, ext) -- east: a = inside
    end
end

-- placement fit: footprint in lot, free, not across walls, every slot keeps a usable approach
local function footprint(def, x, y, f)
    local out = {}
    for n, c in ipairs(def.fp or { { 0, 0 } }) do
        local dx, dy = rot(c[1], c[2], f)
        out[n] = { x + dx, y + dy }
    end
    return out
end

local function approachOk(lot, occ, cells, ax, ay)
    if not inLot(lot, ax, ay) or occ[idx(lot, ax, ay)] then return false end
    for _, c in ipairs(cells) do
        if math.abs(c[1] - ax) + math.abs(c[2] - ay) == 1 then
            local w = lot.walls[0][edgeBetween(ax, ay, c[1], c[2])]
            if not w or w.kind == "door" or w.kind == "arch" or w.kind == "gate" then return true end
            return false
        end
    end
    return true -- not adjacent (e.g. a dart line): standing cell only
end

function CL.Fits(lot, occ, keep, def, x, y, f)
    local cells = footprint(def, x, y, f)
    for _, c in ipairs(cells) do
        if not inLot(lot, c[1], c[2]) then return false, "outside the lot" end
        local k = idx(lot, c[1], c[2])
        if occ[k] then return false, "cell taken" end
        if keep[k] then return false, "keeps a walkway clear" end
    end
    for a = 1, #cells do
        for b = a + 1, #cells do
            local ca, cb = cells[a], cells[b]
            if math.abs(ca[1] - cb[1]) + math.abs(ca[2] - cb[2]) == 1 and lot.walls[0][edgeBetween(ca[1], ca[2], cb[1], cb[2])] then
                return false, "crosses a wall"
            end
        end
    end
    local fpSet = {}
    for _, c in ipairs(cells) do fpSet[idx(lot, c[1], c[2])] = true end
    for _, name in ipairs(sortedKeys(def.slots)) do
        local s = def.slots[name]
        local ok = false
        for _, ap in ipairs(s.approaches or {}) do
            local dx, dy = rot(ap[1], ap[2], f)
            local ax, ay = x + dx, y + dy
            if not fpSet[inLot(lot, ax, ay) and idx(lot, ax, ay) or -1] and approachOk(lot, occ, cells, ax, ay) then ok = true end
        end
        if not ok then return false, "slot " .. name .. " has no free approach" end
    end
    return true, cells
end

-- Cells an anchor's users stand on; later objects must not cover them.
local function protectApproaches(lot, keep, def, x, y, f)
    for _, s in pairs(def.slots or {}) do
        for _, ap in ipairs(s.approaches or {}) do
            local dx, dy = rot(ap[1], ap[2], f)
            if inLot(lot, x + dx, y + dy) then keep[idx(lot, x + dx, y + dy)] = true end
        end
    end
end

local function newObject(lot, defId, x, y, f)
    local n = lot.nextId
    lot.nextId = n + 1
    lot.nextObj = lot.nextId
    local id = "o" .. n
    local def = SS.Objects[defId]
    local o = { id = id, def = defId, x = x, y = y, f = f or 0, level = 0 }
    if def.startState then
        o.state = {}
        for k, v in pairs(def.startState) do o.state[k] = v end
    end
    lot.objects[id] = o
    return o
end

CL.NewObject, CL.ProtectApproaches, CL.Footprint = newObject, protectApproaches, footprint

-- Place one template entry. Returns the object or nil, reason.
function CL.Place(lot, occ, keep, entry, force)
    local spec = VD.furnish[entry.use]
    if not spec then return nil, "unknown furnishing '" .. tostring(entry.use) .. "'" end
    local x, y, f = entry[1], entry[2], entry[3] or 0
    -- A wider design placed for the previous entry (a two-seat catalogue bench standing where the
    -- template pairs two single benches) already covers this spot: nothing more to place.
    local here = not force and inLot(lot, x, y) and occ[idx(lot, x, y)]
    if here and lot.objects[here] and lot.objects[here].use == entry.use then return lot.objects[here], "covered" end
    local why
    local list = force and { force } or CL.Candidates(spec)
    for _, defId in ipairs(list) do
        local def = SS.Objects[defId]
        local ok, cells = CL.Fits(lot, occ, keep, def, x, y, f)
        if ok then
            local o = newObject(lot, defId, x, y, f)
            o.anchor, o.vendor, o.staffRole, o.use = spec.anchor, entry.vendor, spec.staff, entry.use
            for _, c in ipairs(cells) do occ[idx(lot, c[1], c[2])] = o.id end
            if spec.anchor and not spec.seat then protectApproaches(lot, keep, def, x, y, f) end
            return o
        end
        why = defId .. ": " .. tostring(cells)
    end
    return nil, why or "no candidate"
end

-- Build a venue lot from its template. Returns lot, problems (array of strings; empty when clean).
function V.BuildLot(kind, id, address)
    local tpl = CL.templates[kind]
    assert(tpl, "SideStreet: unknown venue kind " .. tostring(kind))
    local info = VD.kinds[kind]
    local lot = {
        id = id or ("lot_venue_" .. kind), address = address or info.address, name = info.name,
        kind = "community", venue = kind, w = tpl.w, h = tpl.h, price = 0, street = "south",
        entry = { tpl.entry[1], tpl.entry[2] }, gather = { tpl.gather[1], tpl.gather[2] },
        floor = { [0] = {}, [1] = {} }, walls = { [0] = {}, [1] = {} }, objects = {},
        nextId = 1, nextObj = 1, version = 1, template = kind, templateVersion = CL.VERSION,
        staffOnly = { [0] = {} }, staffAreas = {}, fires = {},
    }
    local problems = {}
    local roofMat = CL.Finish("roofs", tpl.roof.material, nil) or CL.Finish("roof", tpl.roof.material, nil) or "shingle"
    lot.roof = { style = tpl.roof.style, material = roofMat, color = tpl.roof.color }
    fillFloor(lot, 0, 0, lot.w - 1, lot.h - 1, CL.Finish("floors", tpl.ground, "grass"))
    local doorStyle = CL.Finish("doors", tpl.doorStyle or {}, nil)
    local winStyle = CL.Finish("windows", tpl.windowStyle or {}, nil)
    for _, b in ipairs(tpl.buildings or {}) do
        local ext = CL.Finish("walls", b.ext, "siding_sage")
        local int = CL.Finish("walls", b.int, "paint_cream")
        if b.floor then fillFloor(lot, b[1], b[2], b[3], b[4], CL.Finish("floors", b.floor, "wood")) end
        building(lot, b, ext, int)
        for _, p in ipairs(b.partitions or {}) do
            local pint = CL.Finish("walls", p.finish or b.int, "paint_cream")
            for _, key in ipairs(p) do setWall(lot, key, "wall", pint, pint) end
        end
        for _, key in ipairs(b.doors or {}) do setWall(lot, key, "door", nil, nil, doorStyle) end
        for _, key in ipairs(b.windows or {}) do setWall(lot, key, "window", nil, nil, winStyle) end
        for _, key in ipairs(b.arches or {}) do setWall(lot, key, "arch") end
    end
    -- floor overlays (paths, paving, restroom tiles, dance floor) go over the building floors
    for _, fl in ipairs(tpl.floors or {}) do
        fillFloor(lot, fl[1], fl[2], fl[3], fl[4], CL.Finish("floors", fl[5], fl.fallback or "path"))
    end
    local fence = CL.Finish("fences", tpl.fenceStyle or {}, nil)
    if not fence and SS.Finishes and type(SS.Finishes.fences) == "table" then fence = sortedKeys(SS.Finishes.fences)[1] end
    for _, fw in ipairs(tpl.fences or {}) do
        setWall(lot, fw[1], fw[2] or "fence", nil, nil, fence or "picket")
    end
    -- staff-only cells: lot.staffOnly[level][cellIndex] = true (the visitors framework's format);
    -- lot.staffAreas keeps the rectangles for the UI and docs
    for _, r in ipairs(tpl.staffOnly or {}) do
        lot.staffAreas[#lot.staffAreas + 1] = { r[1], r[2], r[3], r[4] }
        for j = r[2], r[4] do for i = r[1], r[3] do if inLot(lot, i, j) then lot.staffOnly[0][idx(lot, i, j)] = true end end end
    end
    local occ, keep = {}, {}
    keep[idx(lot, lot.entry[1], lot.entry[2])] = true
    keep[idx(lot, lot.gather[1], lot.gather[2])] = true
    for _, r in ipairs(tpl.clear or {}) do
        for j = r[2], r[4] do for i = r[1], r[3] do if inLot(lot, i, j) then keep[idx(lot, i, j)] = true end end end
    end
    -- door cells on both sides stay clear
    for key, w in pairs(lot.walls[0]) do
        if w.kind == "door" or w.kind == "gate" or w.kind == "arch" then
            local axis, i, j = key:match("^(%a):(%-?%d+):(%-?%d+)$")
            i, j = tonumber(i), tonumber(j)
            local cells = axis == "x" and { { i, j - 1 }, { i, j } } or { { i - 1, j }, { i, j } }
            for _, c in ipairs(cells) do if inLot(lot, c[1], c[2]) then keep[idx(lot, c[1], c[2])] = true end end
        end
    end
    for _, e in ipairs(tpl.objects) do
        local o, why = CL.Place(lot, occ, keep, e)
        if not o then problems[#problems + 1] = string.format("%s at %d,%d: %s", tostring(e.use), e[1], e[2], tostring(why)) end
    end
    return lot, problems
end

---------------------------------------------------------------------------------------------------
-- TEMPLATES. Every venue: exterior walls with doors and windows, roofs, floors, paths, lawn,
-- landscaping, lighting, a public restroom, and its staff and service anchors.
-- objects: { x, y, facing, use = furnish spec (Data/Venues.lua VD.furnish), vendor = ... }
local P = { pattern = "brick" }

-- 1. Shopping courtyard: four shopfronts round a paved courtyard with a fountain.
CL.templates.shops = {
    w = 26, h = 22, entry = { 13, 21 }, gather = { 13, 16 },
    roof = { style = "gable", material = { "slate", { pattern = "slate" }, "tile", "shingle" }, color = "slate_blue" },
    ground = { "grass" },
    doorStyle = { { style = "contemporary" } }, windowStyle = { { style = "contemporary" } },
    floors = {
        { 7, 7, 18, 20, { "brick_paver", { pattern = "brick" }, "path" } },     -- courtyard paving
        { 9, 4, 16, 6, { "brick_paver", { pattern = "brick" }, "path" } },      -- restroom forecourt
        { 13, 21, 13, 21, { "path" } },
    },
    buildings = {
        -- A: Hem & Haw Outfitters (clothing), door on the courtyard side
        { 2, 1, 8, 6, ext = { { pattern = "brick" }, "siding_sage" }, int = { { pattern = "wallpaper" }, "paint_cream" },
          floor = { { pattern = "planks" }, "wood" }, doors = { "x:5:7" }, windows = { "x:3:7", "x:7:7", "y:2:3" } },
        -- B: Dog-Ear Books & News
        { 17, 1, 23, 6, ext = { { pattern = "brick" }, "siding_sage" }, int = { { pattern = "panelling" }, "paint_cream" },
          floor = { { pattern = "carpet" }, "carpet" }, doors = { "x:20:7" }, windows = { "x:18:7", "x:22:7", "y:24:3" } },
        -- C: Petal Pusher Gifts & Flowers
        { 1, 9, 6, 15, ext = { { pattern = "stucco" }, "siding_sage" }, int = { { pattern = "plaster" }, "paint_seafoam" },
          floor = { { pattern = "tile grid" }, "tile" }, doors = { "y:7:12" }, windows = { "y:7:10", "y:7:14", "x:3:9" } },
        -- D: Knick & Knack Home Goods
        { 19, 9, 24, 15, ext = { { pattern = "stucco" }, "siding_sage" }, int = { { pattern = "stripes" }, "paint_cream" },
          floor = { { pattern = "planks" }, "wood" }, doors = { "y:19:12" }, windows = { "y:25:10", "y:25:14", "x:22:9" } },
        -- E: public restroom block (two single rooms)
        { 11, 1, 14, 3, ext = { { pattern = "brick" }, "siding_sage" }, int = { { pattern = "tile" }, "paint_seafoam" },
          floor = { { pattern = "tile grid" }, "tile" }, doors = { "x:11:4", "x:14:4" },
          partitions = { { "y:13:1", "y:13:2", "y:13:3" } } },
    },
    clear = { { 13, 17, 13, 20 }, { 5, 7, 5, 8 }, { 20, 7, 20, 8 }, { 7, 12, 8, 12 }, { 17, 12, 18, 12 } },
    objects = {
        -- clothing
        { 2, 1, 0, use = "rack_clothing", vendor = "clothing" },
        { 5, 1, 0, use = "rack_clothing", vendor = "clothing" },
        { 8, 1, 0, use = "changing_booth", vendor = "clothing" },
        { 2, 4, 3, use = "rack_clothing", vendor = "clothing" },
        { 7, 4, 0, use = "register", vendor = "clothing" },
        { 2, 6, 0, use = "plant" },
        -- books
        { 17, 1, 0, use = "rack_books", vendor = "books" },
        { 20, 1, 0, use = "rack_books", vendor = "books" },
        { 23, 3, 1, use = "rack_books", vendor = "books" },
        { 18, 4, 0, use = "register", vendor = "books" },
        { 23, 1, 0, use = "armchair" },
        { 23, 6, 2, use = "lamp" },
        -- gifts and flowers
        { 1, 9, 0, use = "stand_gifts", vendor = "gifts" },
        { 4, 9, 0, use = "stand_gifts", vendor = "gifts" },
        { 1, 13, 3, use = "stand_gifts", vendor = "gifts" },
        { 4, 14, 2, use = "register", vendor = "gifts" },
        { 6, 9, 0, use = "plant" },
        -- home decor
        { 20, 9, 0, use = "shelf_decor", vendor = "decor" },
        { 23, 9, 0, use = "shelf_decor", vendor = "decor" },
        { 24, 13, 1, use = "shelf_decor", vendor = "decor" },
        { 21, 14, 2, use = "register", vendor = "decor" },
        { 19, 15, 2, use = "lamp" },
        -- restroom block
        { 12, 1, 0, use = "stall" },
        { 13, 1, 0, use = "stall" },
        { 11, 1, 0, use = "basin" },
        { 14, 1, 0, use = "basin" },
        -- courtyard
        { 12, 11, 0, use = "fountain" },
        { 10, 11, 3, use = "bench" },
        { 10, 12, 3, use = "bench" },
        { 15, 11, 1, use = "bench" },
        { 15, 12, 1, use = "bench" },
        { 9, 9, 0, use = "lamp_post" },
        { 17, 9, 0, use = "lamp_post" },
        { 9, 17, 0, use = "lamp_post" },
        { 17, 17, 0, use = "lamp_post" },
        { 16, 14, 0, use = "bin" },
        { 10, 19, 0, use = "flowers" },
        { 11, 19, 0, use = "flowers" },
        { 15, 19, 0, use = "flowers" },
        { 16, 19, 0, use = "flowers" },
        { 12, 20, 0, use = "sign" },
        { 17, 20, 1, use = "payphone" },
        -- lawn edges
        { 1, 18, 0, use = "tree" },
        { 3, 20, 0, use = "tree" },
        { 23, 18, 0, use = "tree" },
        { 24, 20, 0, use = "tree" },
        { 9, 2, 0, use = "tree" },
        { 16, 2, 0, use = "tree" },
        { 1, 17, 0, use = "shrub" },
        { 24, 17, 0, use = "shrub" },
        { 8, 9, 0, use = "shrub" },
        { 18, 9, 0, use = "shrub" },
    },
}

-- 2. Cafe/restaurant: host stand at the door, tables for two and four, a staff-only kitchen with
-- a range and pass, a waiter station, two restrooms, and a front garden.
CL.templates.cafe = {
    w = 20, h = 18, entry = { 10, 17 }, gather = { 10, 15 },
    roof = { style = "hip", material = { "tile", { pattern = "tile" }, "shingle" }, color = "terracotta" },
    ground = { "grass" },
    floors = {
        { 10, 13, 10, 17, { "path" } },
        { 9, 14, 11, 15, { "path" } },
        { 2, 2, 5, 3, { { pattern = "tile grid" }, "tile" } },     -- restrooms
        { 12, 2, 17, 6, { { pattern = "tile grid" }, "tile" } },   -- kitchen
    },
    buildings = {
        { 2, 2, 17, 12, ext = { { pattern = "brick" }, "siding_sage" }, int = { { pattern = "wallpaper" }, "paint_cream" },
          floor = { { pattern = "herringbone" }, { pattern = "planks" }, "wood" },
          doors = { "x:10:13", "x:13:7", "x:3:4", "x:4:4" },
          windows = { "x:4:13", "x:6:13", "x:14:13", "x:16:13", "y:2:7", "y:2:10", "y:18:9", "y:18:11" },
          partitions = {
              -- kitchen (i 12..17, j 2..6)
              { "y:12:2", "y:12:3", "y:12:4", "y:12:5", "y:12:6", "x:12:7", "x:13:7", "x:14:7", "x:15:7", "x:16:7", "x:17:7",
                finish = { { pattern = "tile" }, "paint_seafoam" } },
              -- two restrooms (i 2..3 and 4..5, j 2..3)
              { "y:4:2", "y:4:3", "y:6:2", "y:6:3", "x:2:4", "x:3:4", "x:4:4", "x:5:4", finish = { { pattern = "tile" }, "paint_seafoam" } },
          } },
    },
    staffOnly = { { 12, 2, 17, 6 } },
    clear = { { 10, 12, 10, 12 }, { 13, 6, 13, 8 }, { 8, 8, 8, 11 }, { 11, 5, 11, 9 }, { 4, 8, 11, 8 } },
    objects = {
        -- service anchors first
        { 11, 11, 1, use = "podium" },
        { 15, 2, 0, use = "kitchen" },
        { 15, 8, 0, use = "waiter_station" },
        -- tables (anchors), then their chairs
        { 3, 6, 0, use = "cafe_table" },
        { 6, 6, 0, use = "cafe_table" },
        { 3, 10, 0, use = "cafe_table" },
        { 9, 6, 0, use = "cafe_table" },
        { 16, 11, 0, use = "cafe_table" },
        { 6, 10, 0, use = "cafe_table_long" },
        { 13, 10, 0, use = "cafe_table_long" },
        { 3, 5, 0, use = "dining_chair" }, { 3, 7, 2, use = "dining_chair" },
        { 6, 5, 0, use = "dining_chair" }, { 6, 7, 2, use = "dining_chair" },
        { 3, 9, 0, use = "dining_chair" }, { 3, 11, 2, use = "dining_chair" },
        { 9, 5, 0, use = "dining_chair" }, { 9, 7, 2, use = "dining_chair" },
        { 16, 10, 0, use = "dining_chair" }, { 16, 12, 2, use = "dining_chair" },
        { 6, 9, 0, use = "dining_chair" }, { 7, 9, 0, use = "dining_chair" },
        { 6, 11, 2, use = "dining_chair" }, { 7, 11, 2, use = "dining_chair" },
        { 13, 9, 0, use = "dining_chair" }, { 14, 9, 0, use = "dining_chair" },
        { 13, 11, 2, use = "dining_chair" }, { 14, 11, 2, use = "dining_chair" },
        -- restrooms
        { 2, 2, 0, use = "stall" },
        { 5, 2, 0, use = "stall" },
        { 3, 2, 0, use = "basin" },
        { 4, 2, 0, use = "basin" },
        -- kitchen fittings (decorative prep counters)
        { 12, 2, 0, use = "prep_counter" }, { 13, 2, 0, use = "prep_counter" }, { 17, 2, 0, use = "prep_counter" },
        -- dining room decor
        { 11, 3, 0, use = "pastry" },
        { 8, 2, 0, use = "menu_board" },
        { 2, 12, 0, use = "plant" },
        { 17, 7, 0, use = "lamp" },
        { 2, 8, 3, use = "payphone" },
        { 7, 3, 0, use = "plant" },
        -- front garden
        { 8, 15, 0, use = "sign" },
        { 7, 14, 0, use = "flowers" }, { 13, 14, 0, use = "flowers" },
        { 6, 14, 0, use = "flowers" }, { 14, 14, 0, use = "flowers" },
        { 1, 15, 0, use = "tree" }, { 18, 15, 0, use = "tree" },
        { 8, 16, 0, use = "lamp_post" }, { 12, 16, 0, use = "lamp_post" },
        { 15, 16, 1, use = "bench" }, { 4, 16, 3, use = "bench" },
        { 1, 1, 0, use = "shrub" }, { 18, 1, 0, use = "shrub" },
        { 12, 15, 0, use = "bin" },
    },
}

-- 3. Public park: lawns and paths, a fountain plaza with benches, a picnic area with a coin grill,
-- chess tables, a climbing frame, a restroom block, trees, hedges, flower beds and lamp posts.
CL.templates.park = {
    w = 26, h = 22, entry = { 13, 21 }, gather = { 13, 15 },
    roof = { style = "flat", material = { "metal", { pattern = "metal" }, "shingle" }, color = "moss" },
    ground = { "grass" },
    floors = {
        { 13, 12, 13, 21, { "path" } },                                  -- main path from the gate
        { 2, 13, 23, 13, { "path" } },                                   -- cross path
        { 10, 5, 16, 11, { { pattern = "stone" }, "path" } },           -- fountain plaza
        { 3, 3, 9, 11, { { pattern = "stone" }, "path" }, fallback = "path" }, -- picnic lawn pad
        { 18, 5, 22, 9, { { pattern = "stone" }, "path" } },            -- chess corner
        { 20, 4, 23, 4, { "path" } },
    },
    buildings = {
        { 20, 1, 23, 3, ext = { { pattern = "stone" }, "siding_sage" }, int = { { pattern = "tile" }, "paint_seafoam" },
          floor = { { pattern = "tile grid" }, "tile" }, doors = { "x:21:4", "x:22:4" },
          windows = { "y:20:2", "y:24:2" }, -- small frosted windows on each end
          partitions = { { "y:22:1", "y:22:2", "y:22:3" } } },
    },
    fences = {
        { "x:0:21" }, { "x:1:21" }, { "x:2:21" }, { "x:3:21" }, { "x:4:21" }, { "x:5:21" }, { "x:6:21" }, { "x:7:21" },
        { "x:8:21" }, { "x:9:21" }, { "x:10:21" }, { "x:11:21" }, { "x:12:21" }, { "x:13:21", "gate" }, { "x:14:21" },
        { "x:15:21" }, { "x:16:21" }, { "x:17:21" }, { "x:18:21" }, { "x:19:21" }, { "x:20:21" }, { "x:21:21" },
        { "x:22:21" }, { "x:23:21" }, { "x:24:21" }, { "x:25:21" },
    },
    clear = { { 13, 12, 13, 20 }, { 2, 13, 23, 13 }, { 11, 10, 14, 10 } },
    objects = {
        -- restrooms
        { 20, 1, 0, use = "stall" },
        { 23, 1, 0, use = "stall" },
        { 21, 1, 0, use = "basin" },
        { 22, 1, 0, use = "basin" },
        -- fountain plaza and benches
        { 12, 7, 0, use = "fountain" },
        { 10, 7, 3, use = "bench" }, { 10, 8, 3, use = "bench" },
        { 15, 7, 1, use = "bench" }, { 15, 8, 1, use = "bench" },
        { 12, 5, 0, use = "bench" }, { 13, 5, 0, use = "bench" },
        -- picnic area
        { 4, 5, 0, use = "picnic_table" },
        { 4, 4, 0, use = "picnic_seat" }, { 5, 4, 0, use = "picnic_seat" },
        { 4, 6, 2, use = "picnic_seat" }, { 5, 6, 2, use = "picnic_seat" },
        { 4, 9, 0, use = "picnic_table" },
        { 4, 8, 0, use = "picnic_seat" }, { 5, 8, 0, use = "picnic_seat" },
        { 4, 10, 2, use = "picnic_seat" }, { 5, 10, 2, use = "picnic_seat" },
        { 8, 5, 1, use = "grill" },
        { 8, 9, 1, use = "grill" },
        { 3, 11, 0, use = "bin" },
        -- chess corner
        { 19, 7, 0, use = "chess" },
        { 21, 7, 0, use = "chess" },
        { 19, 5, 0, use = "bench" },
        { 21, 9, 2, use = "bench" },
        -- playground
        { 17, 15, 0, use = "playground" },
        { 22, 15, 1, use = "bench" }, { 22, 16, 1, use = "bench" },
        -- lamps
        { 12, 12, 0, use = "lamp_post" }, { 14, 12, 0, use = "lamp_post" },
        { 2, 12, 0, use = "lamp_post" }, { 23, 12, 0, use = "lamp_post" },
        { 16, 10, 0, use = "lamp_post" },
        -- landscaping
        { 1, 1, 0, use = "tree" }, { 6, 1, 0, use = "tree" }, { 10, 2, 0, use = "tree" }, { 16, 2, 0, use = "tree" },
        { 1, 15, 0, use = "tree" }, { 2, 18, 0, use = "tree" }, { 6, 17, 0, use = "tree" }, { 9, 15, 0, use = "tree" },
        { 24, 10, 0, use = "tree" }, { 24, 18, 0, use = "tree" }, { 20, 19, 0, use = "tree" }, { 16, 18, 0, use = "tree" },
        { 5, 20, 0, use = "shrub" }, { 8, 20, 0, use = "shrub" }, { 18, 20, 0, use = "shrub" }, { 21, 20, 0, use = "shrub" },
        { 11, 5, 0, use = "flowers" }, { 14, 5, 0, use = "flowers" },
        { 10, 11, 0, use = "flowers" }, { 16, 11, 0, use = "flowers" },
        { 11, 15, 0, use = "flowers" }, { 15, 15, 0, use = "flowers" },
        { 11, 20, 0, use = "sign" },
        { 15, 20, 2, use = "payphone" },
        { 14, 16, 0, use = "bin" },
    },
}

-- 4. Social club: a dance floor in front of the DJ booth, a juice bar with a bartender, pool and
-- darts, tall mingling tables for the party space, lounge chairs, restrooms and a front walk.
CL.templates.club = {
    w = 22, h = 18, entry = { 11, 17 }, gather = { 11, 14 },
    roof = { style = "flat", material = { "metal", { pattern = "metal" }, "shingle" }, color = "charcoal" },
    ground = { "grass" },
    floors = {
        { 11, 13, 11, 17, { "path" } },
        { 10, 14, 12, 15, { "path" } },
        { 2, 2, 5, 3, { { pattern = "tile grid" }, "tile" } },                  -- restrooms
        { 11, 4, 13, 6, { "dance_floor", { pattern = "checker" }, "tile" } },   -- dance floor
        { 17, 4, 19, 8, { { pattern = "tile grid" }, "tile" } },               -- bar service strip
    },
    buildings = {
        { 2, 2, 19, 12, ext = { { pattern = "brick" }, "siding_sage" }, int = { { pattern = "panelling" }, { pattern = "stripes" }, "paint_cream" },
          floor = { { pattern = "planks" }, "wood" },
          doors = { "x:11:13", "x:3:4", "x:4:4" },
          windows = { "x:4:13", "x:7:13", "x:15:13", "x:18:13", "y:2:7", "y:20:9" },
          partitions = {
              { "y:4:2", "y:4:3", "y:6:2", "y:6:3", "x:2:4", "x:3:4", "x:4:4", "x:5:4", finish = { { pattern = "tile" }, "paint_seafoam" } },
          } },
    },
    staffOnly = { { 19, 4, 19, 8 }, { 9, 2, 11, 2 } },
    clear = { { 11, 7, 11, 12 }, { 3, 6, 3, 6 }, { 6, 4, 17, 4 } },
    objects = {
        { 9, 3, 0, use = "dj_booth" },
        { 12, 3, 0, use = "dance" },
        { 18, 5, 1, use = "bar" },
        { 4, 9, 0, use = "pool_table" },
        { 2, 6, 3, use = "darts" },
        { 8, 9, 0, use = "cocktail" },
        { 14, 9, 0, use = "cocktail" },
        { 16, 11, 0, use = "cocktail" },
        { 7, 12, 2, use = "armchair" }, { 8, 12, 2, use = "armchair" },
        { 14, 12, 2, use = "armchair" }, { 13, 12, 2, use = "armchair" },
        { 2, 12, 2, use = "stool" }, { 3, 12, 2, use = "stool" },
        -- restrooms
        { 2, 2, 0, use = "stall" }, { 5, 2, 0, use = "stall" },
        { 3, 2, 0, use = "basin" }, { 4, 2, 0, use = "basin" },
        -- decor
        { 19, 2, 0, use = "plant" }, { 19, 12, 0, use = "plant" }, { 7, 2, 0, use = "lamp" }, { 16, 2, 0, use = "lamp" },
        -- front walk
        { 9, 15, 0, use = "sign" },
        { 8, 14, 0, use = "lamp_post" }, { 14, 14, 0, use = "lamp_post" },
        { 1, 14, 0, use = "shrub" }, { 20, 14, 0, use = "shrub" },
        { 1, 16, 0, use = "tree" }, { 20, 16, 0, use = "tree" },
        { 13, 15, 0, use = "flowers" }, { 9, 14, 0, use = "flowers" },
        { 14, 16, 1, use = "payphone" },
        { 16, 15, 0, use = "bin" },
    },
}

