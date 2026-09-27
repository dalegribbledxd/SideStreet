-- SideStreet isometric lot renderer (art module; docs/ART.md sections 3 and 5 to 9).
--
-- Layout is pure Lua (BuildStatic / BuildActors: tested offline, used by the preview and the
-- ground-truth comparison in tests/run_tests.py); the Apply functions map it onto pooled WoW
-- frames and textures.
--
-- Sorting (docs/ART.md section 6). Every drawn thing has a view-space box (u0, v0, z0)-(u1, v1, z1).
-- Two things are ordered only when their screen hexagons overlap (exact test on the three
-- view-invariant axes u - v, u - z, v - z); then any separating axis says which is nearer (all
-- separating axes agree for overlapping projections). Static things (floors above ground, walls,
-- openings, fences, objects, roofs, build previews) form a DAG sorted once per layout (Kahn, cycles
-- broken by depth) and are levelled by longest path, so every WoW frame level holds only
-- non-overlapping things. People, vehicles and effects are placed every frame between the statics
-- they overlap; a static that must be in front of a person but sits too low is bumped (with
-- everything in front of it) and restored the next frame. Occupants are drawn right above the
-- object they use, with the object's occupant overlay (pre-cut offline by a true depth test)
-- in the same frame right above them.
local _, SS = ...
local G, W = SS.Grid, SS.World
local R = SS.Render or {}
SS.Render = R
local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt

R.cam = R.cam or { r = 0, zoom = 1, walls = "cut", panX = 0, panY = 0, level = 0 }
R.ZOOMS = { 0.25, 0.5, 1, 1.5, 2 }
R.MARGIN = 16
R.BAND = 2                 -- street band depth beyond the lot's j = h edge (tiles)
R.STRIDE = 4               -- frame levels between two static levels (room for people)
R.PLACEHOLDER = "fx:missing"
R.statics, R.effects = R.statics or {}, R.effects or {}
R.missing, R.missingTotal, R.missingNames = 0, 0, {}
R.stats = R.stats or {}
R.state = R.state or { items = {}, floors = {}, ground = {}, objKeys = {}, statics = 0 }
R.tierMode = R.tierMode or "auto"   -- "auto" (lo at zoom <= 1), "hi", "lo"
local EPS = 1e-4

local function Art() return SS.Art end
local function SC() return (SS.Art and SS.Art.scale) or 1 end
local function STORY() return W.STORY end
local function TOP() return floor((W.LEVELS * W.STORY + 3) * 32 + 16) end

---------------------------------------------------------------------------------------------------
-- Canvas geometry: the lot plus the street band, in logical pixels at zoom 1.
---------------------------------------------------------------------------------------------------
local geo = {}
local function frameOf(world, cam)
    local lot = world.lot
    local r = (cam.r or 0) % 4
    if geo.lot == lot and geo.w == lot.w and geo.h == lot.h and geo.r == r then return geo end
    local minX, maxX, minY, maxY = 1e9, -1e9, 1e9, -1e9
    local xs = { -1, lot.w + 1 }
    local ys = { 0, lot.h + R.BAND }
    for a = 1, 2 do
        for b = 1, 2 do
            local u, v = G.vpos(xs[a], ys[b], r, lot.w, lot.h)
            local sx, sy = (u - v) * 32, (u + v) * 16
            if sx < minX then minX = sx end
            if sx > maxX then maxX = sx end
            if sy < minY then minY = sy end
            if sy > maxY then maxY = sy end
        end
    end
    geo.lot, geo.w, geo.h, geo.r = lot, lot.w, lot.h, r
    geo.ox, geo.oy = -minX + R.MARGIN, -minY + TOP()
    geo.cw, geo.ch = maxX - minX + 2 * R.MARGIN, maxY - minY + TOP() + R.MARGIN
    return geo
end

function R.CanvasSize(world, cam)
    local f = frameOf(world, cam)
    return f.cw, f.ch
end

-- view position (tiles) -> canvas pixel at zoom 1
function R.ToCanvas(world, cam, u, v, z)
    local f = frameOf(world, cam)
    return (u - v) * 32 + f.ox, (u + v) * 16 - (z or 0) * 32 + f.oy
end

-- canvas pixel (zoom 1) -> world position on the floor plane of `level` (default 0)
function R.FromCanvas(world, cam, px, py, level)
    local f = frameOf(world, cam)
    py = py + (level or 0) * W.STORY * 32
    local a = (px - f.ox) / 32
    local b = (py - f.oy) / 16
    local u, v = (a + b) / 2, (b - a) / 2
    return G.wpos(u, v, cam.r, world.lot.w, world.lot.h)
end

-- Largest zoom (continuous) at which the whole lot fits a viewport of vw x vh pixels.
function R.WholeLotZoom(world, cam, vw, vh)
    local cw, ch = R.CanvasSize(world, cam)
    if not vw or vw <= 0 or not vh or vh <= 0 then return R.ZOOMS[1] end
    return min(vw / cw, vh / ch)
end

---------------------------------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------------------------------
local function sprite(name) return name and SS.Art.sprites[name] end
R.Sprite = sprite

-- A sprite name that exists, else the placeholder (counted), else nil.
local function use(name)
    if name and SS.Art.sprites[name] then return name end
    R.missing = R.missing + 1
    R.missingTotal = R.missingTotal + 1
    if name then R.missingNames[name] = true end
    if SS.Art.sprites[R.PLACEHOLDER] then return R.PLACEHOLDER end
    return nil
end
R.Use = use

local function hex(s)
    local r, g, b = tostring(s):match("^#(%x%x)(%x%x)(%x%x)$")
    if not r then return nil end
    return { tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255 }
end

local function lightTint(world, roomLight, level, roomId)
    local key = level * 1000 + roomId
    local L = roomLight[key]
    if L == nil then
        L = W.RoomLight(world, level, roomId)
        roomLight[key] = L
    end
    local f = 0.5 + 0.5 * L
    return f, f, min(1, f + 0.1 * (1 - L))
end
R.LightTint = lightTint

-- The shell's detail level (ui-shell 2e): SS.Perf.quality == "reduced" drops optional visuals
-- (person ground shadows, water shimmer, decorative effects).
function R.Reduced()
    local P = SS.Perf
    return P ~= nil and P.quality == "reduced"
end

-- Visible levels for a camera: all levels up to cam.level; "roof" mode shows everything.
function R.VisibleLevels(world, cam)
    local top = cam.level or 0
    if cam.walls == "roof" then top = W.LEVELS - 1 end
    return top
end

local function groundZ(world, x, y)
    if W.GroundZ then
        local ok, z = pcall(W.GroundZ, world, x, y)
        if ok and type(z) == "number" then return z end
    end
    return 0
end

local function cellZ(lot, i, j)
    local T = SS.Terrain
    if T and T.CellZ then
        local ok, z = pcall(T.CellZ, lot, i, j)
        if ok and type(z) == "number" then return z end
    end
    return 0
end

-- View corner order (nw, ne, se, sw of the view cell) -> world corner index (1..4), per rotation.
local VIEW = {}
do
    local corners = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
    for r = 0, 3 do
        local map = {}
        for n, vc in ipairs(corners) do
            local x, y = G.wpos(vc[1], vc[2], r, 1, 1)
            for m, wc in ipairs(corners) do
                if abs(wc[1] - x) < 1e-9 and abs(wc[2] - y) < 1e-9 then map[n] = m end
            end
        end
        VIEW[r] = map
    end
end
R.VIEW = VIEW
-- world direction bits (1 = north/-y, 2 = east/+x, 4 = south/+y, 8 = west/-x) -> view bits
-- (1 = -v, 2 = +u, 4 = +v, 8 = -u) for rotation r
local DIRBIT = { { 0, -1, 1 }, { 1, 0, 2 }, { 0, 1, 4 }, { -1, 0, 8 } }
local function viewMask(mask, r)
    local out = 0
    for _, d in ipairs(DIRBIT) do
        if floor(mask / d[3]) % 2 == 1 then
            -- rotate the world direction into view: vpos is affine; use the linear part
            local u1, v1 = G.vpos(d[1], d[2], r, 0, 0)
            local u0, v0 = G.vpos(0, 0, r, 0, 0)
            local du, dv = u1 - u0, v1 - v0
            local bit = (dv < -0.5 and 1) or (du > 0.5 and 2) or (dv > 0.5 and 4) or 8
            out = out + bit
        end
    end
    return out
end
R.ViewMask = viewMask

---------------------------------------------------------------------------------------------------
-- Finishes: pattern + colours for walls, floors, terrain, roofs (docs/ART.md section 3)
---------------------------------------------------------------------------------------------------
local NAME_FALLBACK = { { "wood", "planks" }, { "oak", "planks" }, { "board", "planks" }, { "tile", "tiles" },
    { "carpet", "carpet" }, { "path", "stone" }, { "flag", "stone" }, { "brick", "brick" }, { "siding", "siding" } }
local OLD_FLOORS = {
    wood = { "planks", { 0.78, 0.58, 0.36 }, { 0.55, 0.38, 0.22 } },
    tile = { "checker", { 0.93, 0.91, 0.86 }, { 0.16, 0.17, 0.2 } },
    carpet = { "carpet", { 0.66, 0.24, 0.2 }, { 0.5, 0.16, 0.14 } },
    path = { "stone", { 0.74, 0.72, 0.68 }, { 0.52, 0.5, 0.47 } },
    grass = { "grass", { 0.36, 0.56, 0.25 }, { 0.29, 0.48, 0.2 } },
}
local TERRAIN_DEFAULT = {
    grass = { "grass", { 0.36, 0.56, 0.25 }, { 0.29, 0.48, 0.2 } },
    dirt = { "dirt", { 0.42, 0.29, 0.2 }, { 0.3, 0.21, 0.14 } },
    sand = { "sand", { 0.86, 0.78, 0.61 }, { 0.78, 0.71, 0.52 } },
    stone = { "stone", { 0.6, 0.59, 0.56 }, { 0.48, 0.46, 0.43 } },
}
local PATTERN_DEFAULT_COL = { planks = { 0.78, 0.58, 0.36 }, tiles = { 0.92, 0.92, 0.9 }, carpet = { 0.7, 0.62, 0.52 },
    grass = { 0.36, 0.56, 0.25 }, stone = { 0.72, 0.7, 0.66 } }

local function patternFor(kind, id, look)
    local A = SS.Art
    local set = (kind == "walls" and A.wallPatterns) or (kind == "floors" and A.floorPatterns)
        or (kind == "terrain" and A.terrainPatterns) or A.roofPatterns or {}
    if look and look.pattern and set[look.pattern] then return look.pattern end
    local s = tostring(id or "")
    if set[s] then return s end
    for _, p in ipairs(NAME_FALLBACK) do if s:find(p[1], 1, true) and set[p[2]] then return p[2] end end
    if kind == "walls" then return set.paint and "paint" or next(set) end
    if kind == "floors" then return set.planks and "planks" or next(set) end
    if kind == "terrain" then return set.grass and "grass" or next(set) end
    return set.shingle and "shingle" or next(set)
end

local finCache = {}
-- Returns pattern, base colour, accent colour (tables; never nil).
function R.Finish(kind, id)
    local key = kind .. "|" .. tostring(id)
    local c = finCache[key]
    if c and c.ver == SS.Finishes then return c[1], c[2], c[3] end
    local F = SS.Finishes and SS.Finishes[kind]
    local e = F and F[id]
    local look = type(e) == "table" and e.look or nil
    local pat, col, col2
    if kind == "floors" and OLD_FLOORS[id] and not look then
        local o = OLD_FLOORS[id]
        pat, col, col2 = o[1], o[2], o[3]
        if not (SS.Art.floorPatterns or {})[pat] then pat = patternFor(kind, id, nil) end
    elseif kind == "terrain" and TERRAIN_DEFAULT[id] and not look then
        local o = TERRAIN_DEFAULT[id]
        pat, col, col2 = o[1], o[2], o[3]
        if not (SS.Art.terrainPatterns or {})[pat] then pat = patternFor(kind, id, nil) end
    else
        pat = patternFor(kind, id, look)
        col = (look and look.color) or (type(e) == "table" and e.color) or PATTERN_DEFAULT_COL[pat] or { 0.9, 0.88, 0.84 }
        col2 = (look and (look.color2 or look.accent)) or { col[1] * 0.7, col[2] * 0.7, col[3] * 0.7 }
    end
    finCache[key] = { pat, col, col2, ver = SS.Finishes }
    return pat, col, col2
end

---------------------------------------------------------------------------------------------------
-- Boxes and the order test
---------------------------------------------------------------------------------------------------
-- box = { u0, v0, z0, u1, v1, z1 }
local function hexOverlap(a, b)
    -- u - v
    if a[4] - a[2] <= b[1] - b[5] + EPS or b[4] - b[2] <= a[1] - a[5] + EPS then return false end
    -- u - z
    if a[4] - a[3] <= b[1] - b[6] + EPS or b[4] - b[3] <= a[1] - a[6] + EPS then return false end
    -- v - z
    if a[5] - a[3] <= b[2] - b[6] + EPS or b[5] - b[3] <= a[2] - a[6] + EPS then return false end
    return true
end
R.HexOverlap = hexOverlap

-- true when a is farther than b (draw a first), false when nearer; the boxes' projections overlap.
-- Intersecting boxes: a wall-like thing's plane decides (pa = 1 for a plane u = pv, 2 for v = pv),
-- else the centres' depth.
local function behind(a, b)
    if a[4] <= b[1] + EPS then return true end
    if b[4] <= a[1] + EPS then return false end
    if a[5] <= b[2] + EPS then return true end
    if b[5] <= a[2] + EPS then return false end
    if a[6] <= b[3] + EPS then return true end
    if b[6] <= a[3] + EPS then return false end
    -- a doorway's hole column: a person (or effect) standing in the hole is in front of it
    if a.hole and b.dyn then return true end
    if b.hole and a.dyn then return false end
    if a.pa and not b.pa then
        local c = (a.pa == 1) and (b[1] + b[4]) / 2 or (b[2] + b[5]) / 2
        return c > a.pv
    elseif b.pa and not a.pa then
        local c = (b.pa == 1) and (a[1] + a[4]) / 2 or (a[2] + a[5]) / 2
        return c < b.pv
    end
    local da = a[1] + a[4] + a[2] + a[5] + a[3] + a[6]
    local db = b[1] + b[4] + b[2] + b[5] + b[3] + b[6]
    if da ~= db then return da < db end
    return (a.tie or 0) < (b.tie or 0)
end
R.Behind = behind

local function box(u0, v0, z0, u1, v1, z1)
    return { u0, v0, z0, u1, v1, z1 }
end

---------------------------------------------------------------------------------------------------
-- Static layout
---------------------------------------------------------------------------------------------------
local LEVEL_KEY = 1000

local function newItem(ctx, kind, ref, level, x, y, b)
    local it = { kind = kind, ref = ref, level = level, x = x, y = y, layers = {}, box = b }
    ctx.items[#ctx.items + 1] = it
    return it
end

local function addLayer(it, name, r, g, b, x, y, alpha, c0, c1, c2, c3)
    local s = use(name)
    if not s then return nil end
    local L = { s, r or 1, g or 1, b or 1, x, y, alpha, c0, c1, c2, c3 }
    it.layers[#it.layers + 1] = L
    return L
end
R.AddLayer = addLayer

-- Ground layer entries (drawn below every item, in order of `row`): accents, terrain, pool,
-- street band, shadows and cell marks on level 0.
local function addGround(ctx, row, sub, name, x, y, r, g, b, alpha, cell)
    local s = use(name)
    if not s then return nil end
    local e = { sprite = s, x = x, y = y, tint = { r or 1, g or 1, b or 1 }, alpha = alpha, row = row, sub = sub, cell = cell,
        seq = #ctx.ground + 1 }
    ctx.ground[#ctx.ground + 1] = e
    return e
end

-- An object's art: its own record, else the design a system id is drawn with (SS.Art.objectAlias,
-- docs/ART.md 2.9: the outings' sys_bar_stool is the catalogue's chrome bar stool).
local function objArt(def)
    local A = SS.Art.objects
    if not A then return nil end
    local a = A[def]
    if a then return a end
    local al = SS.Art.objectAlias
    al = al and al[def]
    return al and A[al] or nil
end
R.ObjArt = objArt
-- Objects drawn as nothing: their effects show them (the events module's flames).
local function invisible(def)
    local inv = SS.Art.invisible
    if inv and inv[def] then return true end
    local d = SS.Objects and SS.Objects[def]
    return d ~= nil and d.invisible == true
end
R.Invisible = invisible
local DEFAULT_FP = { { 0, 0 } }

-- Which rendered state an object shows (docs/ART.md 2.4): damage first (SS.Art.objStateOrder:
-- burnt, broken, dead, rotten, spoiled, wilted), then a growth stage, then the design's pick (a
-- field that selects a look, docs/ART.md 5.2), then the working states in STATE_PRIORITY, then any
-- other authored state, then dirty, else base.
local STATE_PRIORITY = { "cooking", "burning", "on", "open", "full", "cooked", "spoiled", "water", "stocked" }
R.STATE_PRIORITY = STATE_PRIORITY
-- A look is on when its o.state value is true. Some modules keep levels in o.state (garden plots:
-- water and weeds 0..100; the birdbath's water): a number turns a look on only past its threshold
-- here, and never by being a number (every number, 0 included, is truthy in Lua).
local STATE_LEVEL = { water = 0, weeds = 39.999, full = 0, stocked = 0 }
R.STATE_LEVEL = STATE_LEVEL
local function stateOn(k, v)
    if v == true then return true end
    if type(v) == "number" then
        local t = STATE_LEVEL[k]
        return t ~= nil and v > t
    end
    return false
end
R.StateOn = stateOn

-- A design's pick (art.pick = { field, values, ge, when, unless }): the look a field of o (or
-- o.state) selects. `values` maps tostring(value) to a look; `ge` = { {n, look}, ... } ascending,
-- the largest n with value >= n wins. A look the art does not have is ignored ("base" always
-- exists). `when` names a state that must be on (a TV's programme shows only while it is on),
-- `unless` lists states that switch the pick off (a ringing alarm clock shows ringing, not set).
-- A dotted field reads a nested table (household-core's alarm: "alarm.on" is o.alarm.on).
local FIELD_PATH = {}
local function fieldValue(o, f)
    local path = FIELD_PATH[f]
    if path == nil then
        path = false
        if f:find(".", 1, true) then
            path = {}
            for part in f:gmatch("[^%.]+") do path[#path + 1] = part end
        end
        FIELD_PATH[f] = path
    end
    if not path then
        local v = o[f]
        if v == nil and type(o.state) == "table" then v = o.state[f] end
        return v
    end
    local t = o
    for i = 1, #path do
        if type(t) ~= "table" then return nil end
        t = t[path[i]]
    end
    return t
end
R.FieldValue = fieldValue

local function pickLook(o, pk, S)
    local st = o.state
    if pk.when and not (type(st) == "table" and stateOn(pk.when, st[pk.when])) then return nil end
    local un = pk.unless
    if un and type(st) == "table" then
        for i = 1, #un do if stateOn(un[i], st[un[i]]) then return nil end end
    end
    local v = fieldValue(o, pk.field)
    if v == nil then return nil end
    local vals = pk.values
    if vals then
        local l = vals[tostring(v)]
        if l and (l == "base" or S[l]) then return l end
    end
    local ge = pk.ge
    if ge and type(v) == "number" then
        for i = #ge, 1, -1 do
            local e = ge[i]
            if v >= e[1] and (e[2] == "base" or S[e[2]]) then return e[2] end
        end
    end
    return nil
end
R.PickLook = pickLook

-- Counted items (docs/ART.md 5.2; the aquarium's fish): art.count = { field, under, item, max,
-- lit, full }. While o.state[field] is a number (below `full`, when the design has one) the object
-- shows its underlay, the design without its animals (under .. "_o" when a lit design is off,
-- .. "_d" when dirty, "_o_d" both), and R.CountItems names the item looks drawn over it: item ..
-- i .. the same suffix, i = 1 .. min(count, max). Each item look holds only that animal's own
-- pixels (tools/build_art.py cut_count_items).
local function countSuffix(o, C, st)
    local off = C.lit and not stateOn("on", st.on)
    local dirty = stateOn("dirty", st.dirty) or (type(o.dirt) == "number" and o.dirt > 60)
    if off then return dirty and "_o_d" or "_o" end
    return dirty and "_d" or ""
end
local function countUnderlay(o, art, st)
    local C = art.count
    local n = tonumber(st[C.field])
    if not n or (C.full and n >= C.full) then return nil end
    local S = art.states
    local u = C.under .. countSuffix(o, C, st)
    if S[u] then return u end
    if S[C.under] then return C.under end
    return nil
end
local countOut = {}
local function countItems(o, art, sname)
    local out = countOut
    for q = #out, 1, -1 do out[q] = nil end
    local C = art and art.count
    local st = o.state
    if not (C and C.item and C.max and type(st) == "table" and type(sname) == "string") then return out end
    if sname:sub(1, #C.under) ~= C.under then return out end
    local n = tonumber(st[C.field])
    if not n then return out end
    local suf = sname:sub(#C.under + 1)
    local S = art.states
    for i = 1, math.min(math.floor(n), C.max) do
        local l = C.item .. i .. suf
        if S[l] then out[#out + 1] = l elseif S[C.item .. i] then out[#out + 1] = C.item .. i end
    end
    return out
end
R.CountItems = countItems

local function filthyAt()
    local T = SS.Tuning
    return (T and T.filthyAt) or 85
end

-- Garden plots and planters (docs/ART.md 5.5): the design's look under the crop patches
-- (R.GardenPatches). The design shows its soil: bare (stage 0, and under dead plants), seeded rows
-- (stage 1), its seedlings (stage 2; bare under wilted ones) and, for a crop the art does not draw,
-- its own generic plants (stage<n>). Weeds and dry soil are patches, so the design's own
-- weeds look is not used. nil for burnt or broken (the design's look, no patches).
local function gardenUnderlay(o, art, st)
    local GA = SS.Art.garden
    if not (GA and art.garden) or type(st) ~= "table" then return nil end
    local S = art.states
    if (stateOn("burnt", st.burnt) and S.burnt) or (stateOn("broken", st.broken) and S.broken) then return nil end
    local stage = tonumber(st.stage) or 0
    if stage <= 0 or (stateOn("dead", st.dead) and stage >= 1) then return "base" end
    if stage == 1 then return S.stage1 and "stage1" or "base" end
    if stage == 2 then
        if stateOn("wilted", st.wilted) then return "base" end
        return S.stage2 and "stage2" or "base"
    end
    if GA.crops and GA.crops[st.crop] then return "base" end
    -- the design's own wilted look is its bare soil tinted: its growing plants read better
    local sn = "stage" .. tostring(math.min(stage, 4))
    return S[sn] and sn or "base"
end

function R.ObjectState(o, art)
    art = art or objArt(o.def)
    if not art then return nil end
    local st = o.state
    local S = art.states
    if type(st) == "table" then
        if art.garden then
            local g = gardenUnderlay(o, art, st)
            if g then return g end
        end
        for _, k in ipairs(SS.Art.objStateOrder or {}) do if stateOn(k, st[k]) and S[k] then return k end end
        if art.count then
            local u = countUnderlay(o, art, st)
            if u then return u end
        end
        if st.stage ~= nil and S["stage" .. tostring(st.stage)] then return "stage" .. tostring(st.stage) end
        if art.pick then
            local l = pickLook(o, art.pick, S)
            if l then return l end
        end
        for _, k in ipairs(STATE_PRIORITY) do if stateOn(k, st[k]) and S[k] then return k end end
        -- any other authored state: the alphabetically first one set (deterministic, no sort)
        local pick
        for k, v in pairs(st) do
            if S[k] and k ~= "dirty" and k ~= "base" and stateOn(k, v) and (not pick or k < pick) then pick = k end
        end
        if pick then return pick end
        -- very dirty (household-core Tuning.filthyAt) shows the filthy look where there is one
        if S.filthy and type(o.dirt) == "number" and o.dirt >= filthyAt() then return "filthy" end
        if (stateOn("dirty", st.dirty) or (type(o.dirt) == "number" and o.dirt > 60)) and S.dirty then return "dirty" end
    else
        if art.pick then
            local l = pickLook(o, art.pick, S)
            if l then return l end
        end
        if S.filthy and type(o.dirt) == "number" and o.dirt >= filthyAt() then return "filthy" end
        if type(o.dirt) == "number" and o.dirt > 60 and S.dirty then return "dirty" end
    end
    return "base"
end

local function variantTint(o, art)
    local def = SS.Objects[o.def]
    if def and def.variants and o.variant then
        for _, v in ipairs(def.variants) do
            if (v.id == o.variant or v == o.variant) and type(v.tint) == "table" then return v.tint end
        end
    end
    if def and def.variants and def.variants[1] and type(def.variants[1].tint) == "table" and not o.variant then
        return def.variants[1].tint
    end
    local d = art and art.tintDefault
    return d or { 1, 1, 1 }
end
R.VariantTint = variantTint

-- Where a surface item put down without a slot rests (docs/ART.md 5.4): on the top of the
-- object under its cell (the art's `top`, the height of its geometry above each footprint cell's
-- centre), else on the floor. Cached per object until the lot's objects change.
local restCache = setmetatable({}, { __mode = "k" })
local function restHeight(world, o)
    local lot = world.lot
    local ver = SS.RT and SS.RT.version or 0
    local lv = o.level or 0
    local c = restCache[o]
    if c and c.ver == ver and c.x == o.x and c.y == o.y and c.lv == lv and c.lot == lot then return c.z end
    local z = 0
    for _, b in pairs(lot.objects) do
        if b ~= o and (b.level or 0) == lv and not b.parent then
            local bdef = SS.Objects and SS.Objects[b.def]
            local bart = objArt(b.def)
            if bart and bart.top and ((bdef and bdef.mount) or bart.mount) ~= "surface" then
                local fp = bart.fp or DEFAULT_FP
                local f = (b.f or 0) % 4
                for n = 1, #fp do
                        local dx, dy = G.rot(fp[n][1], fp[n][2], f)
                    if b.x + dx == o.x and b.y + dy == o.y then
                        local t = bart.top[n] or 0
                        if t > z then z = t end
                    end
                end
            end
        end
    end
    c = c or {}
    c.ver, c.x, c.y, c.lv, c.lot, c.z = ver, o.x, o.y, lv, lot, z
    restCache[o] = c
    return z
end
R.RestHeight = restHeight

-- Object anchor in view space (the origin cell centre). An item on a surface (o.parent, the
-- catalogue's lamp on a table) stands at its slot at the surface height: SS.Placement.SurfacePos
-- (catalogue) gives that point; without it, at its cell centre at o.z (household-core's
-- SpawnOnSurface records the slot height there). A surface item with no parent (a pan left on the
-- stove) rests on the top of the object under it; everything else stands on the floor.
local function objAnchor(world, cam, o)
    local lot = world.lot
    local lv = o.level or 0
    local P = o.parent and SS.Placement
    if P and type(P.SurfacePos) == "function" then
        local ok, x, y, z = pcall(P.SurfacePos, world, o)
        if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
            local u, v = G.vpos(x, y, cam.r, lot.w, lot.h)
            return u, v, z + (lv == 0 and cellZ(lot, o.x, o.y) or 0)
        end
    end
    local u, v = G.vcell(o.x, o.y, cam.r, lot.w, lot.h)
    local z = lv * W.STORY + (lv == 0 and cellZ(lot, o.x, o.y) or 0)
    if o.parent and type(o.z) == "number" then
        z = z + o.z
    elseif not o.parent then
        local d = SS.Objects and SS.Objects[o.def]
        local mount = d and d.mount
        if mount == nil then
            local art = objArt(o.def)
            mount = art and art.mount
        end
        if mount == "surface" then z = z + restHeight(world, o) end
    end
    return u + 0.5, v + 0.5, z
end
R.ObjAnchor = objAnchor

local function addObject(ctx, world, cam, id, o, ghost)
    local art = objArt(o.def)
    local lot = world.lot
    local au, av, az = objAnchor(world, cam, o)
    local x, y = R.ToCanvas(world, cam, au, av, az)
    local lv = o.level or 0
    local k = ((o.f or 0) + cam.r) % 4
    local tr, tg, tb = 1, 1, 1
    if not ghost then tr, tg, tb = lightTint(world, ctx.roomLight, lv, W.RoomAt(world, lv, o.x, o.y)) end
    local alpha = ghost and 0.55 or nil
    if ghost then
        if ghost.valid == false then tr, tg, tb = 1, 0.45, 0.4 else tr, tg, tb = 0.6, 1, 0.6 end
    end
    local first, lastIt
    local ub = { 1e9, 1e9, 1e9, -1e9, -1e9, -1e9 }
    if not art then
        -- missing art: a neutral placeholder the size of the footprint cell, counted
        local it = newItem(ctx, ghost and "ghost" or "obj", id, lv, x, y, box(au - 0.45, av - 0.45, az, au + 0.45, av + 0.45, az + 1))
        it.key = lv * LEVEL_KEY + au + av
        addLayer(it, nil, tr, tg, tb, nil, nil, alpha)
        if #it.layers == 0 then ctx.items[#ctx.items] = nil; return nil end
        ctx.objKeys[id] = it
        return it
    end
    local sname = ghost and "base" or R.ObjectState(o, art)
    local S = art.states[sname] or art.states.base
    local rec = S[k] or S[tostring(k)]
    if not rec then return nil end
    local vt = variantTint(o, art)
    -- a decal (puddle, scorch mark) lies on the floor: a flat box at the floor, so it sorts behind
    -- everything standing on its cell and stays pickable (docs/ART.md 2.9)
    local decal = art.decal
    for n, p in ipairs(rec.p) do
        local b = box(au + p[3], av + p[4], az + p[5], au + p[6], av + p[7], az + p[8])
        if decal then b[3], b[6] = az, az end
        if b[1] < ub[1] then ub[1] = b[1] end
        if b[2] < ub[2] then ub[2] = b[2] end
        if b[3] < ub[3] then ub[3] = b[3] end
        if b[4] > ub[4] then ub[4] = b[4] end
        if b[5] > ub[5] then ub[5] = b[5] end
        if b[6] > ub[6] then ub[6] = b[6] end
        local it = newItem(ctx, ghost and "ghost" or "obj", id, lv, x, y, b)
        it.piece = rec.n and rec.n[n]
        it.def, it.k, it.state, it.au, it.av, it.az = o.def, k, sname, au, av, az
        it.key = lv * LEVEL_KEY + (b[1] + b[4] + b[2] + b[5]) / 2
        if p[1] ~= "" then addLayer(it, p[1], tr, tg, tb, nil, nil, alpha) end
        if p[2] ~= "" then addLayer(it, p[2], vt[1] * tr, vt[2] * tg, vt[3] * tb, nil, nil, alpha) end
        if #it.layers == 0 then ctx.items[#ctx.items] = nil else first = first or it; lastIt = it end
    end
    -- counted items (the aquarium's fish) over the underlay, as layers of the last piece
    if art.count and not ghost and lastIt then
        local items = countItems(o, art, sname)
        for q = 1, #items do
            local IS = art.states[items[q]]
            local ir = IS and (IS[k] or IS[tostring(k)])
            if ir then
                for _, p in ipairs(ir.p) do
                    if p[1] ~= "" and sprite(p[1]) then addLayer(lastIt, p[1], tr, tg, tb, nil, nil, alpha) end
                end
            end
        end
    end
    if lastIt then
        lastIt.objBox = ub
        ctx.objKeys[id] = lastIt
        ctx.objPieces[id] = ctx.objPieces[id] or {}
        for n = #ctx.items, 1, -1 do
            local it = ctx.items[n]
            if it.ref ~= id then break end
            it.objBox = ub
            ctx.objPieces[id][#ctx.objPieces[id] + 1] = it
        end
    end
    -- contact shadow
    if rec.sh and not ghost and not decal then
        if lv == 0 and not o.parent then
            addGround(ctx, 1e6, 2, rec.sh, x, y, 1, 1, 1, 1, nil)
        else
            local it = newItem(ctx, "shadow", id, lv, x, y, box(ub[1], ub[2], az - 0.0005, ub[4], ub[5], az - 0.0005))
            it.key = lv * LEVEL_KEY + au + av - 0.5
            addLayer(it, rec.sh, 1, 1, 1)
        end
    end
    return lastIt
end

-- The crop patches of a garden design (docs/ART.md 5.5), one per footprint cell at the soil
-- point the build measured (art.garden.soil, design-local): { {look, crop | false}, ... } in draw
-- order (dry soil, weeds, the plants). The look names are SS.Art.garden's.
local patchOut = {}
local function gardenPatches(o, art)
    local out = patchOut
    for q = #out, 1, -1 do out[q] = nil end
    local GA = SS.Art.garden
    local st = o.state
    if not (GA and art.garden) or type(st) ~= "table" then return out end
    local S = art.states
    if (stateOn("burnt", st.burnt) and S.burnt) or (stateOn("broken", st.broken) and S.broken) then return out end
    local stage = tonumber(st.stage) or 0
    local water = tonumber(st.water)
    if water and water < 20 then out[#out + 1] = { "dry", false } end
    local weeds = tonumber(st.weeds)
    if weeds and weeds >= 60 then out[#out + 1] = { "weeds", false } end
    if stateOn("dead", st.dead) and stage >= 1 then
        out[#out + 1] = { "dead", false }
    elseif stage == 2 and stateOn("wilted", st.wilted) then
        out[#out + 1] = { "sprout_w", false }
    elseif stage >= 3 and GA.crops and GA.crops[st.crop] then
        local s4 = stage >= 4
        local look = s4 and "4" or "3"
        if s4 and stateOn("rotten", st.rotten) then look = "4r"
        elseif stateOn("wilted", st.wilted) then look = look .. "w" end
        out[#out + 1] = { look, st.crop }
    end
    return out
end
R.GardenPatches = gardenPatches

local function cropSprite(size, crop, look, k)
    if crop then return "crop:" .. size .. ":" .. crop .. ":" .. look .. ":" .. k end
    return "crop:" .. size .. ":" .. look .. ":" .. k
end
R.CropSprite = cropSprite

-- Lay the patches on the soil: layers of the object's last piece (so they draw right after the
-- design and pick as the object), each footprint cell from the back, shadows under the plants.
local cellOrder, NO_SOIL = {}, {}
local function addCrops(ctx, world, cam, o, art, it)
    local P = gardenPatches(o, art)
    if #P == 0 or not it then return end
    local GA = SS.Art.garden
    local lot = world.lot
    local lv = o.level or 0
    local _, _, az = objAnchor(world, cam, o)
    local f = (o.f or 0) % 4
    local k = (f + cam.r) % 4
    local tr, tg, tb = lightTint(world, ctx.roomLight, lv, W.RoomAt(world, lv, o.x, o.y))
    local soil = art.garden.soil or NO_SOIL
    local size = art.garden.size or "bed"
    for q = #cellOrder, 1, -1 do cellOrder[q] = nil end
    for n = 1, #soil do
        local sp = soil[n]
        local rx, ry = G.rot(sp[1] - 0.5, sp[2] - 0.5, f)
        local u, v = G.vpos(o.x + 0.5 + rx, o.y + 0.5 + ry, cam.r, lot.w, lot.h)
        cellOrder[#cellOrder + 1] = { u + v, u, v, az + (sp[3] or 0) }
    end
    table.sort(cellOrder, function(a, b) return a[1] < b[1] end)
    for _, c in ipairs(cellOrder) do
        local x, y = R.ToCanvas(world, cam, c[2], c[3], c[4])
        for _, p in ipairs(P) do
            local nm = cropSprite(size, p[2] or nil, p[1], k)
            if p[1] == "dry" then
                addLayer(it, nm, tr, tg, tb, x, y, GA.dryAlpha or 0.7)
            else
                if sprite(nm .. ":sh") then addLayer(it, nm .. ":sh", 1, 1, 1, x, y) end
                addLayer(it, nm, tr, tg, tb, x, y)
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Floors, terrain, pools, street band
---------------------------------------------------------------------------------------------------
local function floorSprite(pat, u, v, r)
    local fp = SS.Art.floorPatterns or {}
    local a = (fp[pat] and fp[pat].aniso) and (r % 2) or 0
    return "floor:" .. pat .. ":" .. a .. ":" .. (u % 2) .. (v % 2)
end
R.FloorSprite = floorSprite

local function terrainKey(lot, i, j, r)
    local T = SS.Terrain
    if not (T and T.TilePattern) then return "0000", 0 end
    local ok, o, base = pcall(T.TilePattern, lot, i, j)
    if not ok or type(o) ~= "table" then return "0000", 0 end
    local m = VIEW[r % 4]
    return (o[m[1]] or 0) .. (o[m[2]] or 0) .. (o[m[3]] or 0) .. (o[m[4]] or 0), base or 0
end
R.TerrainKey = terrainKey

local function groundCells(ctx, world, cam)
    local lot = world.lot
    local r = cam.r % 4
    local step = (SS.Terrain and SS.Terrain.STEP) or 0.25
    local water = lot.terrain and lot.terrain.water
    local pools = {}
    if SS.Pool and SS.Pool.Pieces then
        local ok, P = pcall(SS.Pool.Pieces, world)
        if ok and type(P) == "table" and P.cells then
            for _, c in ipairs(P.cells) do pools[c.j * lot.w + c.i + 1] = c end
        end
    elseif lot.pool then
        for k, e in pairs(lot.pool) do
            local i, j = (k - 1) % lot.w, floor((k - 1) / lot.w)
            local function has(ni, nj) return W.InLot(lot, ni, nj) and lot.pool[nj * lot.w + ni + 1] ~= nil end
            local mask = (has(i, j - 1) and 1 or 0) + (has(i + 1, j) and 2 or 0) + (has(i, j + 1) and 4 or 0) + (has(i - 1, j) and 8 or 0)
            pools[k] = { i = i, j = j, mask = mask, copingStyle = "white_stone", water = { 0.36, 0.68, 0.88 }, z = 0 }
        end
    end
    local FX = SS.RenderFx
    local wf = FX and FX.WaterFrame and FX.WaterFrame("pool") or 0
    local wfp = FX and FX.WaterFrame and FX.WaterFrame("pond") or 0
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do
            local idx = j * lot.w + i + 1
            local u, v = G.vcell(i, j, r, lot.w, lot.h)
            local tr, tg, tb = lightTint(world, ctx.roomLight, 0, W.RoomAt(world, 0, i, j))
            local fid = W.FloorAt(lot, 0, i, j)
            local pc = pools[idx]
            local pondId = water and water[idx]
            local row = u + v
            if pc then
                local z = pc.z or cellZ(lot, i, j)
                local x, y = R.ToCanvas(world, cam, u + 0.5, v + 0.5, z)
                local vm = viewMask(pc.mask or 0, r)
                local wcol = pc.water or { 0.36, 0.68, 0.88 }
                local base = addGround(ctx, row, 0, "poolwater:" .. wf, x, y, wcol[1] * tr, wcol[2] * tg, wcol[3] * tb, nil, { i, j })
                if base and base.sprite ~= R.PLACEHOLDER then base.anim, base.animKind = "poolwater:", "pool" end
                if vm ~= 15 then   -- a cell with pool on all four sides has no coping
                    local cs = tostring(pc.copingStyle or "white_stone")
                    if not sprite("pool:" .. cs .. ":" .. vm) then cs = "white_stone" end
                    addGround(ctx, row, 1, "pool:" .. cs .. ":" .. vm, x, y, tr, tg, tb)
                end
                if base then
                    ctx.floors[#ctx.floors + 1] = { sprite = base.sprite, x = x, y = y, tint = base.tint, cell = { i, j }, level = 0, pool = true }
                end
            elseif pondId then
                local z = cellZ(lot, i, j)
                local x, y = R.ToCanvas(world, cam, u + 0.5, v + 0.5, z)
                local function has(ni, nj) return W.InLot(lot, ni, nj) and water[nj * lot.w + ni + 1] ~= nil end
                local mask = (has(i, j - 1) and 1 or 0) + (has(i + 1, j) and 2 or 0) + (has(i, j + 1) and 4 or 0) + (has(i - 1, j) and 8 or 0)
                local pid = tostring(pondId)
                if not sprite("pond:" .. pid .. ":0:0") then pid = "pond_clear" end
                local prefix = "pond:" .. pid .. ":" .. viewMask(mask, r) .. ":"
                local e = addGround(ctx, row, 0, prefix .. wfp, x, y, tr, tg, tb, nil, { i, j })
                if e and e.sprite ~= R.PLACEHOLDER then e.anim, e.animKind = prefix, "pond" end
                if e then ctx.floors[#ctx.floors + 1] = { sprite = e.sprite, x = x, y = y, tint = e.tint, cell = { i, j }, level = 0, pond = true } end
            else
                local key, base = terrainKey(lot, i, j, r)
                local z = base * step
                local x, y = R.ToCanvas(world, cam, u + 0.5, v + 0.5, z)
                local name, name2, col, col2
                if fid and fid ~= "grass" then
                    local pat, c1, c2 = R.Finish("floors", fid)
                    name = floorSprite(pat, u, v, r)
                    col, col2 = c1, c2
                else
                    local paint = (SS.Terrain and SS.Terrain.Paint and SS.Terrain.Paint(lot, i, j)) or fid or "grass"
                    local pat, c1, c2 = R.Finish("terrain", paint)
                    name = "terrain:" .. pat .. ":" .. key .. ":" .. (u % 2) .. (v % 2)
                    if not sprite(name) then name = "terrain:" .. pat .. ":0000:" .. (u % 2) .. (v % 2) end
                    col, col2 = c1, c2
                end
                local s = use(name)
                if s then
                    local e = { sprite = s, x = x, y = y, tint = { col[1] * tr, col[2] * tg, col[3] * tb }, cell = { i, j }, level = 0,
                        row = row, sub = 0 }
                    ctx.floors[#ctx.floors + 1] = e
                    if sprite(name .. ":a") then
                        e.accent = name .. ":a"
                        e.accentTint = { col2[1] * tr, col2[2] * tg, col2[3] * tb }
                        addGround(ctx, row, 1, name .. ":a", x, y, col2[1] * tr, col2[2] * tg, col2[3] * tb)
                    end
                end
            end
        end
    end
end

-- Earth faces under raised ground along the lot's visible (near) edges.
local function skirts(ctx, world, cam)
    local T = SS.Terrain
    if not (T and T.CornerH) then return end
    local lot = world.lot
    local r = cam.r % 4
    local step = T.STEP or 0.25
    local vW, vH = G.viewSize(r, lot.w, lot.h)
    -- near edges in view: u = vW (axis v faces +u) and v = vH (axis u faces +v)
    for n = 0, vW - 1 do
        -- the edge along u at v = vH between view corners (n, vH) and (n + 1, vH)
        local x0, y0 = G.wpos(n, vH, r, lot.w, lot.h)
        local x1, y1 = G.wpos(n + 1, vH, r, lot.w, lot.h)
        local ok, h0 = pcall(T.CornerH, lot, floor(x0 + 0.5), floor(y0 + 0.5))
        local ok2, h1 = pcall(T.CornerH, lot, floor(x1 + 0.5), floor(y1 + 0.5))
        if ok and ok2 then
            local h = min(h0 or 0, h1 or 0)
            if h > 0 then
                local x, y = R.ToCanvas(world, cam, n + 0.5, vH, h * step)
                addGround(ctx, 1e5, 3, "skirt:u:" .. min(12, h), x, y, 1, 1, 1)
            end
        end
    end
    for n = 0, vH - 1 do
        local x0, y0 = G.wpos(vW, n, r, lot.w, lot.h)
        local x1, y1 = G.wpos(vW, n + 1, r, lot.w, lot.h)
        local ok, h0 = pcall(T.CornerH, lot, floor(x0 + 0.5), floor(y0 + 0.5))
        local ok2, h1 = pcall(T.CornerH, lot, floor(x1 + 0.5), floor(y1 + 0.5))
        if ok and ok2 then
            local h = min(h0 or 0, h1 or 0)
            if h > 0 then
                local x, y = R.ToCanvas(world, cam, vW, n + 0.5, h * step)
                addGround(ctx, 1e5, 3, "skirt:v:" .. min(12, h), x, y, 1, 1, 1)
            end
        end
    end
end

-- The street band beyond j = h: per column a sidewalk + curb + road cross-section (2 tiles).
-- Sprite street:<o>:<p>: o = view orientation of the lot-to-street direction (0 = +v, 1 = +u,
-- 2 = -v, 3 = -u), p = column parity (lane dashes).
local function streetBand(ctx, world, cam)
    local lot = world.lot
    local r = cam.r % 4
    local u0, v0 = G.vpos(0, 0, r, lot.w, lot.h)
    local u1, v1 = G.vpos(0, 1, r, lot.w, lot.h)
    local du, dv = u1 - u0, v1 - v0
    local o = (dv > 0.5 and 0) or (du > 0.5 and 1) or (dv < -0.5 and 2) or 3
    for i = -1, lot.w do
        -- centre of the band cell column i (world): x = i + 0.5, y = h + 1
        local u, v = G.vpos(i + 0.5, lot.h + R.BAND / 2, r, lot.w, lot.h)
        local x, y = R.ToCanvas(world, cam, u, v, 0)
        local row = u + v
        addGround(ctx, row, 0, "street:" .. o .. ":" .. (((i % 2) + 2) % 2), x, y, 1, 1, 1)
    end
end

---------------------------------------------------------------------------------------------------
-- Walls, openings, fences, railings, half walls
---------------------------------------------------------------------------------------------------
-- Edge key -> view axis ("u" | "v"), midpoint (mu, mv), near cell (ni, nj), far cell, and whether
-- the near cell is side a; plus the edge's view along-coordinate range start (s0).
local function edgeView(lot, key, r)
    local axis, i, j, ai, aj, bi, bj = G.parseEdge(key)
    local x1, y1, x2, y2
    if axis == "x" then x1, y1, x2, y2 = i, j, i + 1, j else x1, y1, x2, y2 = i, j, i, j + 1 end
    local u1, v1 = G.vpos(x1, y1, r, lot.w, lot.h)
    local u2, v2 = G.vpos(x2, y2, r, lot.w, lot.h)
    local vaxis, mu, mv, s0
    if abs(v1 - v2) < 1e-6 then vaxis, mu, mv, s0 = "u", min(u1, u2) + 0.5, v1, min(u1, u2)
    else vaxis, mu, mv, s0 = "v", u1, min(v1, v2) + 0.5, min(v1, v2) end
    local ka, kb = -1e9, -1e9
    if W.InLot(lot, ai, aj) then local u, v = G.vcell(ai, aj, r, lot.w, lot.h); ka = u + v end
    if W.InLot(lot, bi, bj) then local u, v = G.vcell(bi, bj, r, lot.w, lot.h); kb = u + v end
    local nearIsA
    if ka ~= -1e9 and kb ~= -1e9 then nearIsA = ka > kb
    else
        -- boundary edge: the in-lot cell is near when it lies on the + side of the wall line
        local inA = W.InLot(lot, ai, aj)
        local ci, cj = inA and ai or bi, inA and aj or bj
        local u, v = G.vcell(ci, cj, r, lot.w, lot.h)
        local plus = (vaxis == "u") and (v >= mv - 1e-6) or (u >= mu - 1e-6)
        nearIsA = (inA and plus) or ((not inA) and not plus)
    end
    return vaxis, mu, mv, nearIsA, ai, aj, bi, bj, s0
end
R.EdgeView = edgeView

local function wallBox(vaxis, mu, mv, z0, z1, t)
    t = t or 0.125
    if vaxis == "u" then return box(mu - 0.5 - t / 2, mv - t / 2, z0, mu + 0.5 + t / 2, mv + t / 2, z1) end
    return box(mu - t / 2, mv - 0.5 - t / 2, z0, mu + t / 2, mv + 0.5 + t / 2, z1)
end

-- Is the wall on edge `key` drawn short in wall mode `mode` (the rule addWall uses)?
local function wallShortAt(world, cam, level, key, mode)
    if mode == "down" then return true end
    if mode ~= "cut" then return false end
    local lot = world.lot
    local _, _, _, nearIsA, ai, aj, bi, bj = edgeView(lot, key, cam.r % 4)
    if nearIsA then return W.InLot(lot, bi, bj) and W.RoomAt(world, level, bi, bj) > 0 end
    return W.InLot(lot, ai, aj) and W.RoomAt(world, level, ai, aj) > 0
end
R.WallShortAt = wallShortAt

-- Wall and window mounts (catalogue: SS.Objects[def].mount, or the art's own mount) hang on the
-- wall behind each footprint cell (the object's local -y edge). When that wall is drawn short
-- (cutaway, walls down) the mount would float in the air, so it is hidden with its wall.
function R.MountHidden(world, cam, o, mode)
    if mode ~= "cut" and mode ~= "down" then return false end
    local def = SS.Objects and SS.Objects[o.def]
    local art = objArt(o.def)
    local mount = (def and def.mount) or (art and art.mount)
    if mount ~= "wall" and mount ~= "window" then return false end
    local lot = world.lot
    local level = o.level or 0
    local walls = W.Walls(lot, level)
    local fp = (def and def.fp) or (art and art.fp) or DEFAULT_FP
    local f = o.f or 0
    local bx, by = G.rot(0, -1, f)
    for n = 1, #fp do
        local dx, dy = G.rot(fp[n][1], fp[n][2], f)
        local i, j = o.x + dx, o.y + dy
        local key = G.edgeBetween(i, j, i + bx, j + by)
        if walls[key] and wallShortAt(world, cam, level, key, mode) then return true end
    end
    return false
end

local function setPlane(b, vaxis, mu, mv)
    if vaxis == "u" then b.pa, b.pv = 2, mv else b.pa, b.pv = 1, mu end
    return b
end

local function fixtureOf(kind, style)
    local A = SS.Art
    local F = A.fixtures or {}
    local s = style
    if s and not F[s] and A.fixtureAlias then s = A.fixtureAlias[s] or s end
    if s and F[s] then return s, F[s] end
    local d = (kind == "window" and "window_basic") or (kind == "arch" and "arch_round") or "door_basic"
    if F[d] then return d, F[d] end
    for k2, v in pairs(F) do if (v.kind == kind) or (kind == "door" and v.kind == "door") then return k2, v end end
    return nil
end
R.FixtureOf = fixtureOf

local function fenceId(kind, style)
    local A = SS.Art
    if kind == "railing" then
        local R_ = A.railings or {}
        if style and R_[style] then return style end
        if style and A.railingAlias and A.railingAlias[style] then return A.railingAlias[style] end
        return R_.railing_timber and "railing_timber" or next(R_)
    end
    local F = A.fences or {}
    if style and F[style] then return style end
    if style and A.fenceAlias and A.fenceAlias[style] then return A.fenceAlias[style] end
    return F.fence_picket and "fence_picket" or next(F)
end

-- a burnt doorway's tints: the frame, the wall above the hole, the jambs (multipliers)
local BURNT_CHAR, BURNT_SOOT_TOP, BURNT_SOOT_SIDE = 0.30, 0.45, 0.72
R.BURNT_CHAR, R.BURNT_SOOT_TOP, R.BURNT_SOOT_SIDE = BURNT_CHAR, BURNT_SOOT_TOP, BURNT_SOOT_SIDE

-- The wall/opening item(s) of one edge.
local function addWall(ctx, world, cam, level, key, wl, mode)
    local lot = world.lot
    local r = cam.r % 4
    local vaxis, mu, mv, nearIsA, ai, aj, bi, bj, s0 = edgeView(lot, key, r)
    local z = level * W.STORY
    local farIndoor
    if nearIsA then farIndoor = W.InLot(lot, bi, bj) and W.RoomAt(world, level, bi, bj) > 0
    else farIndoor = W.InLot(lot, ai, aj) and W.RoomAt(world, level, ai, aj) > 0 end
    local short = (mode == "down") or (mode == "cut" and farIndoor)
    local hname = short and "short" or "full"
    local kind = wl.kind or "wall"
    local nearRoom = 0
    if nearIsA and W.InLot(lot, ai, aj) then nearRoom = W.RoomAt(world, level, ai, aj)
    elseif (not nearIsA) and W.InLot(lot, bi, bj) then nearRoom = W.RoomAt(world, level, bi, bj) end
    local tr, tg, tb = lightTint(world, ctx.roomLight, level, nearRoom)
    local x, y = R.ToCanvas(world, cam, mu, mv, z)
    local depthKey = level * LEVEL_KEY + mu + mv
    local B = SS.Art.build or {}
    local H = short and (B.short or 0.375) or W.STORY
    if kind == "fence" or kind == "gate" or kind == "railing" then
        local fid = fenceId(kind, wl.style)
        local name
        if kind == "railing" then name = "railing:" .. tostring(fid) .. ":" .. vaxis
        elseif kind == "gate" then name = "gate:" .. tostring(fid) .. ":" .. vaxis .. ":" .. (ctx.openEdges[key] and "open" or "closed")
        else name = "fence:" .. tostring(fid) .. ":" .. vaxis end
        local fh = ((kind == "railing" and SS.Art.railings or SS.Art.fences) or {})[fid]
        local b = setPlane(wallBox(vaxis, mu, mv, z, z + ((fh and fh.h) or 1.0) + 0.1, 0.12), vaxis, mu, mv)
        local it = newItem(ctx, "wall", key, level, x, y, b)
        it.key, it.fence = depthKey, true
        addLayer(it, name, tr, tg, tb)
        if kind == "gate" then
            it.door = { closed = "gate:" .. tostring(fid) .. ":" .. vaxis .. ":closed", open = "gate:" .. tostring(fid) .. ":" .. vaxis .. ":open",
                layer = 1, wx = 0, wy = 0 }
            ctx.doors[#ctx.doors + 1] = it
        end
        return
    end
    local fin = nearIsA and wl.a or wl.b
    local pat, col, col2 = R.Finish("walls", fin)
    local cr, cg, cb = col[1] * tr, col[2] * tg, col[3] * tb
    local ar, ag, ab = col2[1] * tr, col2[2] * tg, col2[3] * tb
    if kind == "halfwall" then
        local b = setPlane(wallBox(vaxis, mu, mv, z, z + (B.half or 0.9)), vaxis, mu, mv)
        local it = newItem(ctx, "wall", key, level, x, y, b)
        it.key = depthKey
        local nm = "halfwall:" .. pat .. ":" .. vaxis
        addLayer(it, nm, cr, cg, cb)
        if sprite(nm .. ":a") then addLayer(it, nm .. ":a", ar, ag, ab) end
        return
    end
    local wname = "wall:" .. pat .. ":" .. vaxis .. ":" .. hname
    local hasAcc = sprite(wname .. ":a") ~= nil
    if kind == "wall" then
        local b = setPlane(wallBox(vaxis, mu, mv, z, z + H), vaxis, mu, mv)
        local it = newItem(ctx, "wall", key, level, x, y, b)
        it.key, it.short = depthKey, short
        addLayer(it, wname, cr, cg, cb)
        if hasAcc then addLayer(it, wname .. ":a", ar, ag, ab) end
        return
    end
    -- door / window / arch: strips of the plain wall around the hole + the frame sprite, split
    -- into three sort pieces along the wall (left jamb, the opening, right jamb)
    local sid, fx = fixtureOf(kind, wl.style)
    if not fx then
        local b = setPlane(wallBox(vaxis, mu, mv, z, z + H), vaxis, mu, mv)
        local it = newItem(ctx, "wall", key, level, x, y, b)
        it.key, it.short = depthKey, short
        addLayer(it, wname, cr, cg, cb)
        use(nil)
        return
    end
    local half = "1"
    if (fx.w or 1) == 2 then
        local pk = wl.pair
        local pvax, pmu, pmv
        if pk then pvax, pmu, pmv = edgeView(lot, pk, r) end
        local mine = (vaxis == "u") and mu or mv
        local other = pk and ((vaxis == "u") and pmu or pmv) or (mine + 1)
        half = (mine < other) and "L" or "R"
    end
    local strips = fx.strips and fx.strips[vaxis] and fx.strips[vaxis][hname] and fx.strips[vaxis][hname][half]
    local ws = sprite(wname)
    local wb = SS.Art.wallBox and SS.Art.wallBox[vaxis .. ":" .. hname]
    local sc = SC()
    local fkind = (fx.kind == "window") and "window" or "door"
    local fbase = fkind .. ":" .. sid .. ":" .. vaxis .. ":" .. hname
    local suffix = (half == "1") and "" or (":" .. half)
    local closed = fbase .. suffix
    local open = fbase .. ":open" .. suffix
    local fsp = sprite(closed)
    local osp = sprite(open)
    -- doors whose leaves swing: the open frame sprite has no leaf; the swung leaf is its own item
    -- with a sort box on the far side of the wall (docs/ART.md section 3.4)
    local leafName = fbase .. ":leaf" .. suffix
    local lb = fx.leaf and fx.leaf[half]
    if not (lb and sprite(leafName)) then lb = nil end
    -- a door the fire burned through (events: kind "arch", burnt, the door's style kept): its own
    -- frame without the leaf (the open frame), charred, a soot fan on the wall above the hole, and
    -- nothing that opens (docs/ART.md 3.4)
    local burnt = wl.burnt and kind == "arch"
    if burnt then
        if osp and fkind == "door" then closed, fsp = open, osp end
        osp, lb = nil, nil
    end
    -- screen columns (hi sprite px relative to the wall anchor) of the hole's start and end
    local t = B.wallT or 0.125
    local off = (half == "R") and 1 or 0
    local hs0, hs1 = (fx.s0 or 0.12) - off, (fx.s1 or 0.88) - off
    local function colOf(s)
        -- front face point at along-coordinate s (0..1 on this edge) relative to the anchor
        if vaxis == "u" then return (s - 0.5 - t / 2) * 64 * sc end
        return (t / 2 - (s - 0.5)) * 64 * sc
    end
    local c0, c1 = colOf(max(0, hs0)), colOf(min(1, hs1))
    if c0 > c1 then c0, c1 = c1, c0 end
    -- pieces: 1 = low screen x side, 2 = middle (the hole), 3 = high screen x side
    local pieces = {}
    local along0 = (vaxis == "u") and (mu - 0.5) or (mv - 0.5)
    local function pieceBox(p)
        local a0, a1
        local lo, hi = max(0, hs0), min(1, hs1)
        if p == 2 then a0, a1 = lo, hi
        else
            local lowSide = (vaxis == "u") and (p == 1) or (vaxis == "v" and p == 3)
            if lowSide then a0, a1 = -t / 2, lo else a0, a1 = hi, 1 + t / 2 end
        end
        local b
        if vaxis == "u" then b = box(along0 + a0, mv - t / 2, z, along0 + a1, mv + t / 2, z + H)
        else b = box(mu - t / 2, along0 + a0, z, mu + t / 2, along0 + a1, z + H) end
        if p == 2 and fx.kind ~= "window" and not lb and osp then
            -- (manifests without a separate leaf) the open leaf swings to the far side
            if vaxis == "u" then b[2] = mv - 0.9 else b[1] = mu - 0.9 end
        end
        setPlane(b, vaxis, mu, mv)
        -- a walkable hole: whoever stands in it is drawn in front of it (see behind())
        if p == 2 and fx.kind ~= "window" then b.hole = true end
        return b
    end
    for p = 1, 3 do
        local it = newItem(ctx, "wall", key, level, x, y, pieceBox(p))
        it.key, it.short, it.opening = depthKey + (p - 2) * 0.01, short, sid
        pieces[p] = it
    end
    local function pieceOfX(xa, xb)
        local xm = (xa + xb) / 2
        if xm < c0 then return pieces[1] elseif xm > c1 then return pieces[3] end
        return pieces[2]
    end
    if ws and wb and strips then
        local n = #strips
        for q = 1, n - 3, 4 do
            local x0, y0, x1, y1 = strips[q], strips[q + 1], strips[q + 2], strips[q + 3]
            -- strip rects are in the cropped wall sprite; express the column range relative to the anchor
            local xa, xb = x0 - wb.ox, x1 - wb.ox
            local target = pieceOfX(xa, xb)
            if xa < c0 and xb > c0 then
                -- split a jamb rect straddling the hole start
                local cut = floor(c0 + wb.ox + 0.5)
                cut = cut - cut % 2
                if cut > x0 and cut < x1 then
                    addLayer(pieceOfX(xa, cut - wb.ox), wname, cr, cg, cb, nil, nil, nil, x0, y0, cut, y1)
                    if hasAcc then addLayer(pieceOfX(xa, cut - wb.ox), wname .. ":a", ar, ag, ab, nil, nil, nil, x0, y0, cut, y1) end
                    x0 = cut; xa = cut - wb.ox; target = pieceOfX(xa, xb)
                end
            end
            if xa < c1 and xb > c1 then
                local cut = floor(c1 + wb.ox + 0.5)
                cut = cut - cut % 2
                if cut > x0 and cut < x1 then
                    addLayer(pieceOfX(xa, cut - wb.ox), wname, cr, cg, cb, nil, nil, nil, x0, y0, cut, y1)
                    if hasAcc then addLayer(pieceOfX(xa, cut - wb.ox), wname .. ":a", ar, ag, ab, nil, nil, nil, x0, y0, cut, y1) end
                    x0 = cut; xa = cut - wb.ox; target = pieceOfX(xa, xb)
                end
            end
            addLayer(target, wname, cr, cg, cb, nil, nil, nil, x0, y0, x1, y1)
            if hasAcc then addLayer(target, wname .. ":a", ar, ag, ab, nil, nil, nil, x0, y0, x1, y1) end
        end
    else
        addLayer(pieces[2], wname, cr, cg, cb)
        if hasAcc then addLayer(pieces[2], wname .. ":a", ar, ag, ab) end
    end
    if fsp then
        -- the frame sprite, cut into the same three column ranges (sprite px); the open frame has
        -- its own crop box, so its column ranges are worked out from its own anchor
        local function colRange(sp, p)
            local fax = sp[6]
            local q0, q1 = floor(c0 + fax + 0.5), floor(c1 + fax + 0.5)
            local a0, a1
            if p == 1 then a0, a1 = 0, q0 elseif p == 2 then a0, a1 = q0, q1 else a0, a1 = q1, sp[4] end
            a0, a1 = max(0, a0), min(sp[4], a1)
            a0, a1 = a0 - a0 % 2, a1 - a1 % 2
            if p == 3 then a1 = sp[4] end
            return a0, a1
        end
        for p = 1, 3 do
            local a0, a1 = colRange(fsp, p)
            if a1 > a0 then
                local L = addLayer(pieces[p], closed, tr, tg, tb, nil, nil, nil, a0, 0, a1, fsp[5])
                if L and fkind == "door" and osp then
                    local o0, o1 = colRange(osp, p)
                    pieces[p].door = pieces[p].door or { closed = closed, open = (o1 > o0) and open or false,
                        layer = #pieces[p].layers, wx = 0, wy = 0, cc = { a0, 0, a1, fsp[5] }, co = { o0, 0, o1, osp[5] } }
                end
            end
        end
    end
    if lb and fsp then
        -- the swung-open leaf: transparent (alpha 0) while the door is closed
        local s0_, s1_, d0_, d1_ = lb[1], lb[2], lb[3], lb[4]
        local zt = z + min(H, lb[5] or H)
        local b
        if vaxis == "u" then b = box(along0 + s0_, mv + d0_, z, along0 + s1_, mv + d1_, zt)
        else b = box(mu + d0_, along0 + s0_, z, mu + d1_, along0 + s1_, zt) end
        local it = newItem(ctx, "wall", key, level, x, y, b)
        it.key, it.short, it.opening, it.leaf = depthKey - 0.02, short, sid, true
        local L = addLayer(it, leafName, tr, tg, tb, nil, nil, 0)
        if L then
            it.door = { leaf = leafName, layer = 1, wx = 0, wy = 0 }
            pieces[4] = it
        end
    end
    if burnt then
        -- charred frame; soot darkest on the wall above the opening, lighter on the jambs beside it
        for p = 1, 3 do
            local it = pieces[p]
            for q = 1, #it.layers do
                local L = it.layers[q]
                local k = BURNT_SOOT_SIDE
                if L[1] == closed then k = BURNT_CHAR
                elseif L[8] and ws and (L[11] - L[9]) < 0.7 * ws[5] then
                    k = BURNT_SOOT_TOP   -- a short strip: the wall over the hole (jambs run full height)
                end
                L[2], L[3], L[4] = L[2] * k, L[3] * k, L[4] * k
            end
            it.burnt = true
        end
    end
    local ex, ey = G.wpos(mu, mv, r, lot.w, lot.h)
    for p = 1, 4 do
        local it = pieces[p]
        if it then
            if it.door then it.door.wx, it.door.wy = ex, ey; ctx.doors[#ctx.doors + 1] = it end
            if #it.layers == 0 then
                for n = #ctx.items, 1, -1 do if ctx.items[n] == it then table.remove(ctx.items, n); break end end
            end
        end
    end
end

-- Diagonal walls and fences (lot.diag): one piece filling the cell corner to corner.
local function addDiag(ctx, world, cam, level, idx, d, mode)
    local lot = world.lot
    local r = cam.r % 4
    local i, j = (idx - 1) % lot.w, floor((idx - 1) / lot.w)
    local u, v = G.vcell(i, j, r, lot.w, lot.h)
    local z = level * W.STORY
    -- world dir 0 runs (i,j)->(i+1,j+1): seen end-on ("edge") at even rotations
    local vk = ((d.dir or 0) + r) % 2 == 0 and "edge" or "face"
    local x, y = R.ToCanvas(world, cam, u + 0.5, v + 0.5, z)
    local tr, tg, tb = lightTint(world, ctx.roomLight, level, W.RoomAt(world, level, i, j))
    local it
    if d.kind == "fence" then
        local fid = fenceId("fence", d.style)
        it = newItem(ctx, "wall", "d:" .. level .. ":" .. idx, level, x, y, box(u, v, z, u + 1, v + 1, z + 1.2))
        addLayer(it, "fencediag:" .. tostring(fid) .. ":" .. vk, tr, tg, tb)
    else
        local short = (mode == "down") or (mode == "cut")
        local hname = short and "short" or "full"
        -- the visible side: the half nearer the viewer
        local wx, wy = G.wpos(u + 0.75, v + 0.75, r, lot.w, lot.h)
        local side
        if SS.Build and SS.Build.DiagSideAt then
            local ok, s = pcall(SS.Build.DiagSideAt, d.dir or 0, wx - i, wy - j)
            if ok then side = s end
        end
        if not side then
            local fx, fy = wx - i, wy - j
            if (d.dir or 0) == 0 then side = (fx > fy) and "a" or "b" else side = (fx + fy < 1) and "a" or "b" end
        end
        local pat, col, col2 = R.Finish("walls", d[side] or d.a or d.b)
        local H = short and ((SS.Art.build or {}).short or 0.375) or W.STORY
        it = newItem(ctx, "wall", "d:" .. level .. ":" .. idx, level, x, y, box(u, v, z, u + 1, v + 1, z + H))
        it.short = short
        local nm = "diag:" .. pat .. ":" .. vk .. ":" .. hname
        addLayer(it, nm, col[1] * tr, col[2] * tg, col[3] * tb)
        if sprite(nm .. ":a") then addLayer(it, nm .. ":a", col2[1] * tr, col2[2] * tg, col2[3] * tb) end
    end
    it.key = level * LEVEL_KEY + u + v + 1
end

---------------------------------------------------------------------------------------------------
-- Roofs (roof mode) from SS.Roof.Pieces(world)
---------------------------------------------------------------------------------------------------
local function roofPattern(material)
    local A = SS.Art
    local set = A.roofPatterns or {}
    if material and set[material] then return material end
    local F = SS.Finishes and SS.Finishes.roofs
    local e = F and (F[material] or F["roof_" .. tostring(material)])
    local look = e and e.look
    if look and set[look.pattern] then return look.pattern end
    local s = tostring(material or "")
    for p in pairs(set) do if s:find(p, 1, true) then return p end end
    if s:find("asphalt", 1, true) then return "shingle" end
    if s:find("cedar", 1, true) then return "shake" end
    return set.shingle and "shingle" or next(set)
end
R.RoofPattern = roofPattern

-- Roof trims (build art request; docs/ART.md 3.5): a ridge cap where two tiles meet at a peak (on
-- the front tile's back edge), a hip cap along the fold of a one-corner tile, and a fascia with a
-- gutter along a low front edge no other roof tile continues. rec = { z, level, u, v, c1..c4 }
-- (view corners nw, ne, se, sw); roofAt maps level and view cell to rec for one layout.
local roofRecs, roofAt = {}, {}
local TRIM_DARK = 0.84
local function roofCell(level, u, v) return (level * 512 + u + 128) * 512 + v + 128 end
local function sameEdge(a, ca, cb, b, da, db, rise)
    -- a's corners ca, cb meet b's corners da, db at the same heights
    return b and abs((a.z + ca * rise) - (b.z + da * rise)) < 1e-3 and abs((a.z + cb * rise) - (b.z + db * rise)) < 1e-3
end
local function roofTrims(it, rec, rise, cr, cg, cb)
    local S = SS.Art.sprites
    local c1, c2, c3, c4 = rec.c1, rec.c2, rec.c3, rec.c4
    local n = c1 + c2 + c3 + c4
    if n == 0 or n == 4 then return end
    local lv, u, v = rec.level, rec.u, rec.v
    -- ridge caps on the back edges: both tiles have the shared edge as their top and fall away
    if c1 == 1 and c2 == 1 and (c3 == 0 or c4 == 0) then
        local b = roofAt[roofCell(lv, u, v - 1)]
        if b and b.c3 == 1 and b.c4 == 1 and (b.c1 == 0 or b.c2 == 0) and sameEdge(rec, c2, c1, b, b.c3, b.c4, rise)
            and S["rooftrim:ridge:v0"] then addLayer(it, "rooftrim:ridge:v0", cr, cg, cb) end
    end
    if c1 == 1 and c4 == 1 and (c2 == 0 or c3 == 0) then
        local b = roofAt[roofCell(lv, u - 1, v)]
        if b and b.c2 == 1 and b.c3 == 1 and (b.c1 == 0 or b.c4 == 0) and sameEdge(rec, c1, c4, b, b.c2, b.c3, rise)
            and S["rooftrim:ridge:u0"] then addLayer(it, "rooftrim:ridge:u0", cr, cg, cb) end
    end
    -- hip cap: one high corner
    if n == 1 then
        local nm = "rooftrim:hip:" .. c1 .. c2 .. c3 .. c4
        if S[nm] then addLayer(it, nm, cr, cg, cb) end
    end
    -- eaves on the front edges
    if c2 == 0 and c3 == 0 and S["rooftrim:eave:u1"] then
        local b = roofAt[roofCell(lv, u + 1, v)]
        if not (b and sameEdge(rec, c2, c3, b, b.c1, b.c4, rise)) then addLayer(it, "rooftrim:eave:u1", cr, cg, cb) end
    end
    if c3 == 0 and c4 == 0 and S["rooftrim:eave:v1"] then
        local b = roofAt[roofCell(lv, u, v + 1)]
        if not (b and sameEdge(rec, c4, c3, b, b.c1, b.c2, rise)) then addLayer(it, "rooftrim:eave:v1", cr, cg, cb) end
    end
end
R.RoofTrims = roofTrims

local function addRoofs(ctx, world, cam)
    local Rf = SS.Roof
    if not (Rf and Rf.Pieces) then return end
    local ok, P = pcall(Rf.Pieces, world)
    if not ok or type(P) ~= "table" then return end
    local lot = world.lot
    local r = cam.r % 4
    local rise = Rf.RISE or 0.5
    local pieces = P.pieces or {}
    for k in pairs(roofAt) do roofAt[k] = nil end
    for q, p in ipairs(pieces) do
        local vc
        if Rf.ViewCorners then vc = Rf.ViewCorners(p.c, r) else
            local m = VIEW[r]; vc = { p.c[m[1]], p.c[m[2]], p.c[m[3]], p.c[m[4]] }
        end
        local u, v = G.vcell(p.i, p.j, r, lot.w, lot.h)
        local rec = roofRecs[q] or {}
        roofRecs[q] = rec
        rec.z, rec.level, rec.u, rec.v = p.z or 0, p.level or 0, u, v
        rec.c1, rec.c2, rec.c3, rec.c4 = vc[1] or 0, vc[2] or 0, vc[3] or 0, vc[4] or 0
        roofAt[roofCell(rec.level, u, v)] = rec
    end
    for q, p in ipairs(pieces) do
        local rec = roofRecs[q]
        local u, v = rec.u, rec.v
        local keyc = rec.c1 .. rec.c2 .. rec.c3 .. rec.c4
        if keyc == "1111" then keyc = "0000" end
        local x, y = R.ToCanvas(world, cam, u + 0.5, v + 0.5, p.z)
        local top = (rec.c1 + rec.c2 + rec.c3 + rec.c4 > 0) and rise or 0
        local it = newItem(ctx, "roof", "roof:" .. p.i .. ":" .. p.j .. ":" .. (p.level or 0), p.level or 0, x, y,
            box(u, v, p.z, u + 1, v + 1, p.z + top + 0.02))
        it.key = (p.level or 0) * LEVEL_KEY + u + v + 1.5
        local rgb = p.rgb or { 0.6, 0.4, 0.3 }
        addLayer(it, "roof:" .. roofPattern(p.material) .. ":" .. keyc, rgb[1], rgb[2], rgb[3])
        if #it.layers == 0 then ctx.items[#ctx.items] = nil
        else roofTrims(it, rec, rise, rgb[1] * TRIM_DARK, rgb[2] * TRIM_DARK, rgb[3] * TRIM_DARK) end
    end
    for _, g in ipairs(P.gables or {}) do
        local vaxis, mu, mv, _, _, _, _, _, s0 = edgeView(lot, g.edgeKey, r)
        local pat, col, col2 = R.Finish("walls", g.finish)
        -- which corner comes first along the view axis
        local axis, i, j = G.parseEdge(g.edgeKey)
        local x1, y1 = i, j
        local u1, v1 = G.vpos(x1, y1, r, lot.w, lot.h)
        local firstAtStart = ((vaxis == "u") and abs(u1 - s0) < 1e-6) or ((vaxis == "v") and abs(v1 - s0) < 1e-6)
        local ha, hb = g.h1 or 0, g.h2 or 0
        if not firstAtStart then ha, hb = hb, ha end
        local top = max(ha, hb)
        for s = 0, top - 1 do
            local lo_, hi_ = (ha >= s + 1) and 1 or 0, (hb >= s + 1) and 1 or 0
            local shape = (lo_ == 1 and hi_ == 1) and "full" or (lo_ == 0 and hi_ == 1 and "rise") or (lo_ == 1 and "fall") or nil
            if shape then
                local zs = g.z + s * rise
                local x, y = R.ToCanvas(world, cam, mu, mv, zs)
                local b = setPlane(wallBox(vaxis, mu, mv, zs, zs + rise), vaxis, mu, mv)
                local it = newItem(ctx, "roof", "gable:" .. g.edgeKey .. ":" .. s, g.level or 0, x, y, b)
                it.key = (g.level or 0) * LEVEL_KEY + mu + mv + 1.4
                local nm = "gable:" .. pat .. ":" .. vaxis .. ":" .. shape
                addLayer(it, nm, col[1], col[2], col[3])
                if sprite(nm .. ":a") then addLayer(it, nm .. ":a", col2[1], col2[2], col2[3]) end
                if #it.layers == 0 then ctx.items[#ctx.items] = nil end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Cell marks and ghost
---------------------------------------------------------------------------------------------------
local function addMarks(ctx, world, cam)
    local marks = R.cellMarks
    if type(marks) ~= "table" then return end
    local lot = world.lot
    local r = cam.r % 4
    local top = R.VisibleLevels(world, cam)
    for n = 1, #marks do
        local m = marks[n]
        local lv = m.level or 0
        if type(m.i) == "number" and type(m.j) == "number" and lv <= top then
            local u, v = G.vcell(m.i, m.j, r, lot.w, lot.h)
            local z = lv * W.STORY + ((lv == 0 and W.InLot(lot, m.i, m.j)) and cellZ(lot, m.i, m.j) or 0)
            local x, y = R.ToCanvas(world, cam, u + 0.5, v + 0.5, z)
            local c = m.color or { 1, 1, 1, 0.5 }
            local name = m.grid and "fx:grid" or "fx:cell"
            if lv == 0 then
                addGround(ctx, 2e6, 4, name, x, y, c[1], c[2], c[3], c[4] or 0.5)
            else
                local it = newItem(ctx, "mark", "mark:" .. n, lv, x, y, box(u, v, z + 0.001, u + 1, v + 1, z + 0.001))
                it.key = lv * LEVEL_KEY + u + v
                addLayer(it, name, c[1], c[2], c[3], nil, nil, c[4] or 0.5)
            end
        end
    end
end

local function addGhost(ctx, world, cam)
    local g = R.ghost
    if type(g) ~= "table" or not g.def then return end
    local o = { def = g.def, x = floor(g.x or 0), y = floor(g.y or 0), f = g.f or 0, level = g.level or 0, variant = g.variant }
    if (o.level or 0) > R.VisibleLevels(world, cam) then return end
    addObject(ctx, world, cam, "ghost", o, g)
    if type(g.blocked) == "table" then
        local lot = world.lot
        for _, c in ipairs(g.blocked) do
            local u, v = G.vcell(c[1], c[2], cam.r % 4, lot.w, lot.h)
            local x, y = R.ToCanvas(world, cam, u + 0.5, v + 0.5, (o.level or 0) * W.STORY)
            addGround(ctx, 2e6, 5, "fx:cell", x, y, 1, 0.25, 0.2, 0.6)
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Sort: overlap graph, Kahn with priority, longest-path levels, screen buckets
---------------------------------------------------------------------------------------------------
local BX, BY = 2, 1          -- bucket size in u - v units and in screen-y tile units
local function screenRect(b)
    -- X = u - v; Y = (u + v) / 2 - z  (screen down)
    return b[1] - b[5], b[4] - b[2], (b[1] + b[2]) / 2 - b[6], (b[4] + b[5]) / 2 - b[3]
end
R.ScreenRect = screenRect

local function bucketsOf(b)
    local x0, x1, y0, y1 = screenRect(b)
    return floor(x0 / BX), floor(x1 / BX), floor(y0 / BY), floor(y1 / BY)
end

local function heapPush(h, it)
    local n = #h + 1
    h[n] = it
    while n > 1 do
        local p = floor(n / 2)
        if h[p].prio <= it.prio then break end
        h[n], h[p] = h[p], it
        n = p
    end
end
local function heapPop(h)
    local n = #h
    if n == 0 then return nil end
    local top = h[1]
    local last = h[n]
    h[n] = nil
    n = n - 1
    if n > 0 then
        local i = 1
        h[1] = last
        while true do
            local l, rr, m = i * 2, i * 2 + 1, i
            if l <= n and h[l].prio < h[m].prio then m = l end
            if rr <= n and h[rr].prio < h[m].prio then m = rr end
            if m == i then break end
            h[i], h[m] = h[m], h[i]
            i = m
        end
    end
    return top
end

local function sortStatic(items)
    local n = #items
    local buckets = {}
    for i = 1, n do
        local it = items[i]
        local b = it.box
        b.tie = i
        it.idx, it.indeg, it.succ, it.lvl = i, 0, {}, 1
        it.prio = (it.level or 0) * 100000 + (b[1] + b[4] + b[2] + b[5] + b[3] + b[6]) / 2 + (it.kind == "shadow" and -0.5 or 0)
        local bx0, bx1, by0, by1 = bucketsOf(b)
        it.bk = { bx0, bx1, by0, by1 }
        for bx = bx0, bx1 do
            local col = buckets[bx]
            if not col then col = {}; buckets[bx] = col end
            for by = by0, by1 do
                local cell = col[by]
                if not cell then cell = {}; col[by] = cell end
                cell[#cell + 1] = i
            end
        end
    end
    local edges = 0
    for bx, col in pairs(buckets) do
        for by, cell in pairs(col) do
            for a = 1, #cell do
                local ia = cell[a]
                local A_ = items[ia]
                for c = a + 1, #cell do
                    local ib = cell[c]
                    local B_ = items[ib]
                    -- process each pair once: in the bucket holding the top-left corner of their overlap
                    local ox = max(A_.bk[1], B_.bk[1])
                    local oy = max(A_.bk[3], B_.bk[3])
                    if ox == bx and oy == by and hexOverlap(A_.box, B_.box) then
                        local ab = behind(A_.box, B_.box)
                        if ab then
                            A_.succ[#A_.succ + 1] = ib; B_.indeg = B_.indeg + 1
                        else
                            B_.succ[#B_.succ + 1] = ia; A_.indeg = A_.indeg + 1
                        end
                        edges = edges + 1
                    end
                end
            end
        end
    end
    -- Kahn, smallest priority first; cycles are broken at the smallest remaining priority
    local heap, out, done = {}, {}, {}
    for i = 1, n do if items[i].indeg == 0 then heapPush(heap, items[i]) end end
    local cycles = 0
    while #out < n do
        local it = heapPop(heap)
        if not it then
            local best
            for i = 1, n do
                local c = items[i]
                if not done[i] and (not best or c.prio < best.prio) then best = c end
            end
            it = best
            cycles = cycles + 1
        end
        if not done[it.idx] then
            done[it.idx] = true
            out[#out + 1] = it
            for _, s in ipairs(it.succ) do
                -- an edge into an item already out closed a cycle broken above: it neither lifts
                -- that item's level (which would reorder it after the break) nor counts
                if not done[s] then
                    local t = items[s]
                    if t.lvl < it.lvl + 1 then t.lvl = it.lvl + 1 end
                    t.indeg = t.indeg - 1
                    if t.indeg == 0 then heapPush(heap, t) end
                end
            end
        end
    end
    -- rebuild indices in draw order, and keep only the edges that point forward in it: an edge
    -- that closed a broken cycle would let PlaceDynamic's bump walk go round that cycle forever
    -- (catalogue AR-0). Every kept edge goes from a lower to a higher index and a lower to a
    -- higher level, so the walk ends.
    for i = 1, n do out[i].idx = i end
    for i = 1, n do
        local s = out[i].succ
        local m = 0
        for q = 1, #s do
            local t = items[s[q]]
            if t.idx > i then m = m + 1; s[m] = t end
        end
        for q = #s, m + 1, -1 do s[q] = nil end
    end
    local grid = {}
    for i = 1, n do
        local it = out[i]
        local bk = it.bk
        for bx = bk[1], bk[2] do
            local col = grid[bx]
            if not col then col = {}; grid[bx] = col end
            for by = bk[3], bk[4] do
                local cell = col[by]
                if not cell then cell = {}; col[by] = cell end
                cell[#cell + 1] = it
            end
        end
    end
    return out, grid, edges, cycles
end
R.SortStatic = sortStatic

---------------------------------------------------------------------------------------------------
-- BuildStatic
---------------------------------------------------------------------------------------------------
function R.BuildStatic(world, cam)
    R.missing = 0
    local lot = world.lot
    local ctx = { items = {}, floors = {}, ground = {}, objKeys = {}, objPieces = {}, roomLight = {}, doors = {},
        openEdges = R.openEdges or {} }
    local top = R.VisibleLevels(world, cam)
    groundCells(ctx, world, cam)
    skirts(ctx, world, cam)
    streetBand(ctx, world, cam)
    for level = 0, top do
        local z = level * W.STORY
        -- upper floors: one flat item per tile (sorted like everything else)
        if level > 0 then
            local well = SS.RT and SS.RT.well and SS.RT.well[level]
            for j = 0, lot.h - 1 do
                for i = 0, lot.w - 1 do
                    local f = W.FloorAt(lot, level, i, j)
                    if f and not (well and well[W.idx(lot, i, j)]) then
                        local u, v = G.vcell(i, j, cam.r, lot.w, lot.h)
                        local x, y = R.ToCanvas(world, cam, u + 0.5, v + 0.5, z)
                        local tr, tg, tb = lightTint(world, ctx.roomLight, level, W.RoomAt(world, level, i, j))
                        local pat, col, col2 = R.Finish("floors", f)
                        local name = floorSprite(pat, u, v, cam.r % 4)
                        local it = newItem(ctx, "floor", "floor" .. level .. ":" .. i .. ":" .. j, level, x, y, box(u, v, z, u + 1, v + 1, z))
                        it.key = level * LEVEL_KEY + u + v - 0.9
                        addLayer(it, name, col[1] * tr, col[2] * tg, col[3] * tb)
                        if sprite(name .. ":a") then addLayer(it, name .. ":a", col2[1] * tr, col2[2] * tg, col2[3] * tb) end
                    end
                end
            end
        end
        local mode = (level < (cam.level or 0) or cam.walls == "roof") and "up" or cam.walls
        for id, o in pairs(lot.objects) do
            if (o.level or 0) == level and not o.hidden and not invisible(o.def) and not R.MountHidden(world, cam, o, mode) then
                local last = addObject(ctx, world, cam, id, o)
                local oart = last and objArt(o.def)
                if oart and oart.garden then addCrops(ctx, world, cam, o, oart, last) end
            end
        end
        for key, wl in pairs(W.Walls(lot, level)) do addWall(ctx, world, cam, level, key, wl, mode) end
        local dg = lot.diag and lot.diag[level]
        if type(dg) == "table" then
            for idx, d in pairs(dg) do if type(d) == "table" then addDiag(ctx, world, cam, level, idx, d, mode) end end
        end
    end
    if cam.walls == "roof" then addRoofs(ctx, world, cam) end
    addMarks(ctx, world, cam)
    addGhost(ctx, world, cam)
    -- extra static items from other modules (build previews): fn(world, cam, items, floors, objKeys)
    local nBefore = #ctx.items
    for _, fn in ipairs(R.statics) do pcall(fn, world, cam, ctx.items, ctx.floors, ctx.objKeys) end
    for n = nBefore + 1, #ctx.items do
        local it = ctx.items[n]
        if not it.box then
            -- a foreign item without a box: a thin box at its key's depth on its level
            local lv = it.level or 0
            local x = it.x or 0
            local d = (it.key or 0) - lv * LEVEL_KEY
            local a = ((x - frameOf(world, cam).ox) / 32)
            local u, v = (a + d) / 2, (d - a) / 2
            it.box = box(u - 0.5, v - 0.5, lv * W.STORY, u + 0.5, v + 0.5, lv * W.STORY + W.STORY)
        end
        it.key = it.key or ((it.level or 0) * LEVEL_KEY)
        for _, L in ipairs(it.layers or {}) do
            if not sprite(L[1]) then L[1] = use(L[1]) or R.PLACEHOLDER end
        end
    end
    local sorted, grid, edges, cycles = sortStatic(ctx.items)
    -- keys: monotone along the draw order, close to each item's depth (level * 1000 + u + v)
    local run = -1e9
    for i = 1, #sorted do
        local it = sorted[i]
        local k = it.key or ((it.level or 0) * LEVEL_KEY)
        if k < run then k = run end
        it.key = k
        run = k
    end
    table.sort(ctx.ground, function(a, b)
        if a.row ~= b.row then return a.row < b.row end
        if (a.sub or 0) ~= (b.sub or 0) then return (a.sub or 0) < (b.sub or 0) end
        return (a.seq or 0) < (b.seq or 0)   -- table.sort is not stable: keep insertion order
    end)
    ctx.floorsByRow = true
    R.state.grid, R.state.doors, R.state.objPieces = grid, ctx.doors, ctx.objPieces
    R.stats.edges, R.stats.cycles, R.stats.items = edges, cycles, #sorted
    local maxLvl = 0
    for i = 1, #sorted do if sorted[i].lvl > maxLvl then maxLvl = sorted[i].lvl end end
    R.stats.levels = maxLvl
    R.missingStatic = R.missing
    return ctx.floors, sorted, ctx.objKeys, ctx.ground
end

---------------------------------------------------------------------------------------------------
-- People (docs/ART.md section 7)
---------------------------------------------------------------------------------------------------
local AGE_CODE = { adult = "a", child = "c", infant = "i" }
local HEIGHT = { adult = 1.5, child = 1.05, infant = 0.55 }

-- Name cache: names[fkey][layer] -> "p:<fkey>:<layer>" (built once; no per-frame strings)
local nameCache = {}
local function pname(fkey, layer)
    local t = nameCache[fkey]
    if not t then t = {}; nameCache[fkey] = t end
    local s = t[layer]
    if not s then s = "p:" .. fkey .. ":" .. layer; t[layer] = s end
    return s
end
local fkeyCache = {}
local function fkeyOf(code, pose, fi, k)
    local a = fkeyCache[code]
    if not a then a = {}; fkeyCache[code] = a end
    local b = a[pose]
    if not b then b = {}; a[pose] = b end
    local c = b[fi]
    if not c then c = {}; b[fi] = c end
    local s = c[k]
    if not s then s = code .. ":" .. pose .. ":" .. fi .. ":" .. k; c[k] = s end
    return s
end

local function hasPose(pose, age)
    local P = SS.Art.poses and SS.Art.poses[pose]
    return P and P.ages and P.ages[age] and true or false
end

-- Art pose for an actor (the executor's pose names; ARCHITECTURE.md section 8). `carry` overrides
-- a.carry (an outfit's item, R.OutfitItem).
function R.ArtPose(a, age, seated, carry)
    local A = SS.Art
    local pose = a.pose or "idle"
    carry = carry or a.carry
    if a.swimming then
        if a.act and a.act.iid == "pool_float" and hasPose("float", age) then return "float" end
        if a.walking and hasPose("swim", age) then return "swim" end
        if hasPose("tread", age) then return "tread" end
    end
    if age == "infant" then
        local m = A.poseInfant and A.poseInfant[pose]
        if a.walking then m = A.poseInfant and A.poseInfant.walk end
        if m and hasPose(m, age) then return m end
        return hasPose("infant_sit", age) and "infant_sit" or pose
    end
    local grip = carry and A.grips and A.grips[carry]
    if a.walking or pose == "walk" or pose == "run" then
        if grip and hasPose("walk_carry_" .. grip, age) then return "walk_carry_" .. grip end
        if pose == "run" and hasPose("run", age) then return "run" end
        return "walk"
    end
    if seated then
        local s = A.poseSeated and A.poseSeated[pose]
        if s and hasPose(s, age) then return s end
        if hasPose(pose, age) and SS.Art.poses[pose].seated then return pose end
        return hasPose("sit", age) and "sit" or pose
    end
    if grip and (pose == "idle" or pose == "carry") and hasPose("carry_" .. grip, age) then return "carry_" .. grip end
    if hasPose(pose, age) then return pose end
    local al = A.poseAlias and A.poseAlias[pose]
    if al and hasPose(al, age) then return al end
    return "idle"
end

-- Pose variants (docs/ART.md 7.11, tools/art/poses_more.py): a game pose drawn differently by
-- what the actor uses. SS.Art.poseVariants[game pose] = { { match = { tags, use, iid, def }, pose },
-- ... }: the first entry whose match names one of the target design's tags, its venueUse, the
-- action's interaction id or the design id wins (playing at a pool table is play_cue, at a
-- dartboard play_throw, at an arcade cabinet play_cabinet; cooking at a hob is cook_stir).
-- (In a do block: the file is at Lua 5.1's 200-local limit.)
do
local function listHas(l, x)
    if not (l and x) then return false end
    for i = 1, #l do if l[i] == x then return true end end
    return false
end
local function variantMatch(m, def, d, iid)
    if not m then return false end
    if listHas(m.def, def) or listHas(m.iid, iid) then return true end
    if d then
        if d.venueUse and listHas(m.use, d.venueUse) then return true end
        local tags = d.tags
        if tags and m.tags then
            for i = 1, #tags do if listHas(m.tags, tags[i]) then return true end end
        end
    end
    return false
end
function R.PoseVariant(world, a, age)
    local V = SS.Art.poseVariants
    local list = V and V[a.pose or "idle"]
    if not list then return nil end
    local act = a.act
    local oid = act and ((act.target and act.target.oid) or act.oid)
    local o = oid and world.lot and world.lot.objects[oid]
    local def = o and o.def
    local d = def and SS.Objects and SS.Objects[def]
    local iid = act and act.iid
    for i = 1, #list do
        local e = list[i]
        if variantMatch(e.match, def, d, iid) and hasPose(e.pose, age) then return e.pose end
    end
    return nil
end
end

-- hold_hands (social): two people face to face on neighbouring cells with both hands joined
-- halfway. Drawn only while the partner is there: another actor holding hands, on the same
-- level, about one tile straight ahead and facing back; otherwise the person stands idle.
function R.HoldPartner(world, a)
    local f = (a.facing or 0) % 4
    local d = G.DIRS[f]
    local lv = a.level or 0
    for _, b in pairs(world.actors) do
        if b ~= a and b.pose == "hold_hands" and (b.level or 0) == lv and ((b.facing or 0) % 4) == (f + 2) % 4 then
            local rx, ry = b.x - a.x, b.y - a.y
            local along = rx * d[1] + ry * d[2]
            local side = rx * d[2] - ry * d[1]
            if along > 0.7 and along < 1.3 and side > -0.3 and side < 0.3 then return b end
        end
    end
    return nil
end

-- An outfit's item (SS.Art.outfitItems[style], tools/art/poses_more.py): a prop the wearer holds
-- while carrying nothing else (the caseworker's and the bill collector's clipboard).
function R.OutfitItem(a)
    if a.carry then return nil end
    local items = SS.Art.outfitItems
    if not items then return nil end
    local look = a.look
    local kind = a.outfit or "everyday"
    local o = look and look.outfits and look.outfits[kind]
    return items[(o and o.style) or kind] or items[kind]
end

local function frameIndex(a, pose, n, fps, t)
    if n <= 1 then return 0 end
    if pose == "walk" or pose == "run" or pose:sub(1, 11) == "walk_carry_" or pose == "swim" or pose == "infant_crawl" then
        return floor((a.stride or 0) * (pose == "run" and 2.2 or 3)) % n
    end
    return floor(t * (fps > 0 and fps or 2)) % n
end

local NONE = {}   -- shared read-only empty table (no per-frame garbage)
local DEFAULT_SET = { top = "tee", bottom = "trousers", shoes = "shoes", details = NONE }
-- An outfit id the art does not draw: the first style whose keyword it contains
-- (SS.Art.person.outfitKeywords, e.g. "uniform_barista" -> the bartender's), memoised per id.
local styleMemo = setmetatable({}, { __mode = "k" })
local function styleByKeyword(P, style)
    local m = styleMemo[P]
    if not m then m = {}; styleMemo[P] = m end
    local r = m[style]
    if r == nil then
        r = false
        local low = string.lower(style)
        for _, kw in ipairs(P.outfitKeywords or NONE) do
            if P.outfits[kw[2]] and string.find(low, kw[1], 1, true) then r = kw[2]; break end
        end
        m[style] = r
    end
    return r or nil
end
R.StyleByKeyword = styleByKeyword

-- The outfit drawn: `a.outfit` is normally a kind (everyday, sleep, swim, work, formal) whose style
-- is `look.outfits[kind].style`. Visiting NPCs may instead name a style directly (events sets
-- `a.outfit = "burglar" | "registrar" | "firefighter" | "police"` on a look without outfits).
-- Order: the look's style for the kind, else that style by keyword, else the kind's default
-- style, else the kind itself as a style id, else the kind by keyword, else "everyday".
local function outfitOf(a)
    local A = SS.Art
    local P = A.person or NONE
    local PO = P.outfits
    local look = a.look or NONE
    local kind = a.outfit or "everyday"
    local o = look.outfits and look.outfits[kind]
    local style = o and o.style
    if not (style and PO and PO[style]) then
        local kw = type(style) == "string" and PO and styleByKeyword(P, style)
        style = kw or (P.kindDefault and P.kindDefault[kind])
        if not style and PO then
            if PO[kind] then style = kind
            elseif type(kind) == "string" then style = styleByKeyword(P, kind) end
        end
        style = style or "everyday"
    end
    local set = (P.outfits and P.outfits[style]) or DEFAULT_SET
    local cols = o or NONE
    return set, cols.top or look.top, cols.bottom or look.bottom, cols.shoes or look.shoes
end

local WHITE = { 1, 1, 1 }
local GREY = { 0.8, 0.8, 0.8 }
local function ageFallback(age, fam, name)
    local fb = SS.Art.person and SS.Art.person.fallback and SS.Art.person.fallback[age]
    local t = fb and fb[fam]
    if t then
        if t[name] ~= nil then return t[name] end
        if t["*"] ~= nil then return t["*"] end
    end
    return name
end

-- Fill `L` (reused array of layer tables) with the person's layers for one frame.
-- Returns the number of layers.
-- (put() works on module-level state instead of a per-call closure: no per-frame garbage)
local plL, plN, plS, plTr, plTg, plTb, plA, plKx = nil, 0, nil, 1, 1, 1, nil, nil
local EMPTY = NONE
-- body: a layer of the body and its clothes, drawn at the build's width (plKx); the head, face,
-- hair, hat and props keep their own width
local function plPut(name, col, body)
    if not name or not plS[name] then return end
    plN = plN + 1
    local l = plL[plN]
    if not l then l = {}; plL[plN] = l end
    col = col or WHITE
    l[1], l[2], l[3], l[4], l[5], l[6], l[7] = name, (col[1] or 1) * plTr, (col[2] or 1) * plTg, (col[3] or 1) * plTb, nil, nil, plA
    l[8], l[9], l[10], l[11], l[12], l[13], l[14] = nil, nil, nil, nil, nil, nil, body and plKx or nil
end

-- kx: the build's width factor (R.BuildWidth) or nil; carry: the prop held (default a.carry)
local function personLayers(L, a, fkey, age, pose, tr, tg, tb, alpha, kx, carry)
    local S = SS.Art.sprites
    local look = a.look or EMPTY
    plL, plN, plS, plTr, plTg, plTb, plA, plKx = L, 0, S, tr, tg, tb, alpha, kx
    local put = plPut
    local skin = look.skin or GREY
    local hairc = look.hair or GREY
    local set, top, bottom, shoes = outfitOf(a)
    local face = tonumber(look.face) or 1
    local ages = SS.Art.person and SS.Art.person.ages and SS.Art.person.ages[age]
    if ages and ages.faces then
        local ok = false
        for _, f in ipairs(ages.faces) do if f == face then ok = true end end
        if not ok then face = ages.faces[1] end
    end
    put(pname(fkey, "skin"), skin, true)
    put(pname(fkey, "head" .. face), skin)
    put(pname(fkey, "eyes" .. face), nil)
    put(pname(fkey, "beard" .. face), hairc)
    local tints = SS.Art.person and SS.Art.person.tints or EMPTY
    local sh = ageFallback(age, "shoes", set.shoes)
    if sh and sh ~= "none" then put(pname(fkey, "sh:" .. sh), shoes or GREY, true) end
    local bo = ageFallback(age, "bottom", set.bottom)
    if bo and bo ~= "none" then put(pname(fkey, "bo:" .. bo), bottom or GREY, true) end
    local to = ageFallback(age, "top", set.top)
    if to and to ~= "none" then put(pname(fkey, "to:" .. to), top or GREY, true) end
    for _, d in ipairs(set.details or EMPTY) do
        local nm = "de:" .. d
        local t = tints[nm]
        put(pname(fkey, nm), (t == "top" and top) or (t == "bottom" and bottom) or (t == "shoes" and shoes) or nil, true)
    end
    local hs = look.hairStyle or "short"
    if not S[pname(fkey, "ha:" .. hs)] then hs = "short" end
    if set.hat then
        local nm = "ht:" .. set.hat
        if S[pname(fkey, nm)] then
            local t = tints[nm]
            -- a hat hides long hair badly; keep hair (the hat is cut against the reference hair)
            put(pname(fkey, "ha:" .. hs), hairc)
            put(pname(fkey, nm), (t == "top" and top) or nil)
        else
            put(pname(fkey, "ha:" .. hs), hairc)
        end
    else
        put(pname(fkey, "ha:" .. hs), hairc)
    end
    -- props: the carried prop, and the pose's own props
    local P = SS.Art.poses and SS.Art.poses[pose]
    carry = carry or a.carry
    if carry then put(pname(fkey, "pr:" .. carry), nil) end
    if P and P.props then
        for _, pr in ipairs(P.props) do
            if pr ~= carry and not (SS.Art.grips and SS.Art.grips[pr] and pose:find("carry", 1, true)) then
                put(pname(fkey, "pr:" .. pr), nil)
            end
        end
    end
    return plN
end
R.PersonLayers = personLayers

-- The object slot an occupant is in: act.target.slotName when the art has it, else the nearest
-- slot anchor to the actor's position.
-- A ghost (events module: actor.ghost, the dead resident from their own saved look) is the
-- person's own layers, translucent, tinted pale green and cut off at mid-shin so it floats with no
-- feet and no floor shadow; events adds the ghost_glow effect at chest height (events art request 4).
local GHOST_ALPHA, GHOST_R, GHOST_G, GHOST_B, GHOST_CUT = 0.45, 0.80, 1.0, 0.90, 14   -- cut: hi px above the feet
R.GHOST_ALPHA, R.GHOST_CUT = GHOST_ALPHA, GHOST_CUT
local function ghostLayers(L, n)
    local S = SS.Art.sprites
    for q = 1, n do
        local l = L[q]
        local s = l and S[l[1]]
        if s then
            l[2], l[3], l[4] = l[2] * GHOST_R, l[3] * GHOST_G, l[4] * GHOST_B
            local bot = s[7] - GHOST_CUT   -- the cut line in the sprite's own px from its top
            if bot <= 0 then
                l[7] = 0
            elseif bot < s[5] then
                l[8], l[9], l[10], l[11] = 0, 0, s[4], bot
            end
        end
    end
end
R.GhostLayers = ghostLayers

local function occupantSlot(world, a, o, art)
    local slots = art.slots
    if not slots or not next(slots) then return nil end
    local sn = a.act and a.act.target and a.act.target.slotName
    if sn and slots[sn] then return sn, slots[sn] end
    local best, bd, bs
    for name, s in pairs(slots) do
        local lx, ly = s.at[1] - 0.5, s.at[2] - 0.5
        local rx, ry = G.rot(lx, ly, o.f or 0)
        local wx, wy = o.x + 0.5 + rx, o.y + 0.5 + ry
        local d = (wx - a.x) ^ 2 + (wy - a.y) ^ 2
        if not bd or d < bd or (d == bd and name < bs) then best, bd, bs = s, d, name end
    end
    return bs, best
end
R.OccupantSlot = occupantSlot

---------------------------------------------------------------------------------------------------
-- BuildActors: dynamic draw items (people, vehicles, effects). Items and their layer tables are
-- pooled: the same tables come back every frame (no per-frame garbage).
---------------------------------------------------------------------------------------------------
-- Animal sprite names, cached: animalName(kind, pose, k) -> "pet:<kind>:<pose>:<k>"
local animalNames = {}
local function animalName(kind, pose, k)
    kind, pose = tostring(kind or "animal"), tostring(pose or "idle")
    local byKind = animalNames[kind]
    if not byKind then byKind = {}; animalNames[kind] = byKind end
    local byPose = byKind[pose]
    if not byPose then
        byPose = {}
        for q = 0, 3 do byPose[q] = "pet:" .. kind .. ":" .. pose .. ":" .. q end
        byKind[pose] = byPose
    end
    return byPose[k]
end

-- Pets (docs/ART.md 7.6): the breed (look.breed, else the species' default), its pattern
-- (look.pattern when the breed has it, else its first), the pose (a.walking walks; SS.Art.pets.alias
-- maps other modules' pose names; a cat never barks) and the frame. Sprite names are cached per
-- breed, pattern, pose, frame and facing: { p, s, d, sh } ("pet:<breed>:<pose>:<fi>:<k>:<layer>").
local PET_P, PET_S = { 0.78, 0.58, 0.36 }, { 0.95, 0.88, 0.74 }
local petNameCache = {}
-- A look without a known breed of its species: the breed sharing most of look.size, look.ears
-- and look.tail (ties go to the species' default, then to the first id), cached per look table.
local breedMemo = setmetatable({}, { __mode = "k" })
local function nearestBreed(PA, look, species)
    local m = breedMemo[look]
    if m and m[1] == look.breed and m[2] == look.size and m[3] == look.ears and m[4] == look.tail and m[5] == species
        and m[7] == PA then
        return m[6]
    end
    local def = PA.default and PA.default[species]
    local best, bestScore = nil, -1
    local ids = {}
    for id, b in pairs(PA.breeds) do if b.species == species then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local b = PA.breeds[id]
        local sc = ((b.size == look.size) and 4 or 0) + ((b.ears == look.ears) and 2 or 0) + ((b.tail == look.tail) and 1 or 0)
        if sc > bestScore or (sc == bestScore and id == def) then best, bestScore = id, sc end
    end
    if bestScore == 0 and def and PA.breeds[def] then best = def end
    breedMemo[look] = { look.breed, look.size, look.ears, look.tail, species, best, PA }
    return best
end
-- The height a pet on an object (a.onObj: a pet bed) rests at: the object's surface height
-- (SS.Art.objects[def].top) on the pet's cell, 0 when the cell has none.
local function objTopAt(o, cx, cy)
    local art = objArt(o.def)
    if not (art and art.top) then return 0 end
    local fp = art.fp or DEFAULT_FP
    local f = (o.f or 0) % 4
    for n = 1, #fp do
        local dx, dy = G.rot(fp[n][1], fp[n][2], f)
        if o.x + dx == cx and o.y + dy == cy then return art.top[n] or 0 end
    end
    return 0
end
local function petPose(a, PA, species)
    local poses = PA.poses and PA.poses[species]
    if not poses then return nil end
    local pose = a.pose or "idle"
    if a.walking then pose = "walk" end
    if not poses[pose] then
        local al = PA.alias and PA.alias[pose]
        if al and poses[al] then pose = al
        elseif pose == "bark" and poses.sit then pose = "sit"
        else pose = "idle" end
    end
    return pose, poses[pose]
end
local function petSprites(a, k, t)
    local PA = SS.Art.pets
    if not PA or not PA.breeds then return nil end
    local look = a.look or {}
    local species = look.species or a.kind
    if species ~= "dog" and species ~= "cat" then return nil end
    local bid = look.breed
    local breed = bid and PA.breeds[bid]
    if not breed or breed.species ~= species then
        bid = nearestBreed(PA, look, species)
        breed = bid and PA.breeds[bid]
    end
    if not breed then return nil end
    local pat = look.pattern
    local okPat = false
    for _, p in ipairs(breed.patterns or {}) do if p == pat then okPat = true end end
    if not okPat then pat = breed.patterns and breed.patterns[1] or "solid" end
    local pose, P = petPose(a, PA, species)
    if not P then return nil end
    local fi = frameIndex(a, pose, P.n or 1, P.fps or 2, t)
    local c1 = petNameCache[bid]
    if not c1 then c1 = {}; petNameCache[bid] = c1 end
    local c2 = c1[pat]
    if not c2 then c2 = {}; c1[pat] = c2 end
    local c3 = c2[pose]
    if not c3 then c3 = {}; c2[pose] = c3 end
    local key = fi * 4 + k
    local e = c3[key]
    if not e then
        local base = "pet:" .. bid .. ":" .. pose .. ":" .. fi .. ":" .. k .. ":"
        local S = SS.Art.sprites
        e = { p = base .. "p:" .. pat, s = base .. "s:" .. pat, d = base .. "d", sh = base .. "sh" }
        for q, nm in pairs(e) do if not S[nm] then e[q] = nil end end
        c3[key] = e
    end
    if not (e.p or e.s or e.d) then return nil end
    return e, breed, bid, pose, fi
end
R.PetSprites = petSprites
R.PetPose = petPose

-- Pet occupant overlays (docs/ART.md 7.6): a pet in a pet bed or litter tray slot is drawn at the
-- slot like a seated person, with the object's pixels in front of it drawn over it, cut per breed:
-- SS.Art.petOverlays[design][slot][breed][pose] = { n, off = { [k] = { dx, dy } } } and sprites
-- "pov:<design>:<slot>:<breed>:<pose>:<fi>:<k>" (and ":t"), k the object's view rotation.
local PET_SLOT = { pet_bed = true, litter = true }
local povCache = {}
local function povName(def, slot, bid, pose, fi, k)
    local key = def .. "\0" .. slot .. "\0" .. bid .. "\0" .. pose
    local t = povCache[key]
    if not t then t = {}; povCache[key] = t end
    local idx = fi * 4 + k
    local e = t[idx]
    if not e then
        local nm = "pov:" .. def .. ":" .. slot .. ":" .. bid .. ":" .. pose .. ":" .. fi .. ":" .. k
        e = { nm, nm .. ":t" }
        t[idx] = e
    end
    return e[1], e[2]
end
R.PetOverlayName = povName

-- Occupant overlay names, cached: ovName(def, slot, age, pose, fi, k) -> name, name .. ":t"
local ovCache = {}
local function ovName(def, slot, age, pose, fi, k)
    local key = def .. "\0" .. slot .. "\0" .. age .. "\0" .. pose
    local t = ovCache[key]
    if not t then t = {}; ovCache[key] = t end
    local idx = fi * 4 + k
    local e = t[idx]
    if not e then
        local nm = "ov:" .. def .. ":" .. slot .. ":" .. age .. ":" .. pose .. ":" .. fi .. ":" .. k
        e = { nm, nm .. ":t" }
        t[idx] = e
    end
    return e[1], e[2]
end
R.OverlayName = ovName

local dynPool, dynOut = {}, {}
local shadowOf = {}      -- fkey -> "p:<fkey>:shadow" or false (cached: no per-frame string work)
local function dynItem(n)
    local it = dynPool[n]
    if not it then
        it = { layers = {}, box = { 0, 0, 0, 0, 0, 0 }, nl = 0 }
        dynPool[n] = it
    end
    return it
end

-- A resident's body build (look.body, hood's creator: average, slim, broad) as a width factor on
-- the average person frames: SS.Art.personBuilds.width[build][age], measured by the build on the
-- rendered builds (docs/ART.md 7.8). nil for the average build, infants and unknown builds.
local function buildWidth(look, age)
    local b = look and look.body
    if not b or b == "average" or age == "infant" then return nil end
    local PB = SS.Art.personBuilds
    local w = PB and PB.width and PB.width[b]
    local f = w and (w[age] or w.adult)
    if type(f) ~= "number" or f == 1 then return nil end
    return f
end
R.BuildWidth = buildWidth

local function setBox(b, u0, v0, z0, u1, v1, z1)
    b[1], b[2], b[3], b[4], b[5], b[6] = u0, v0, z0, u1, v1, z1
    b.pa, b.pv, b.tie, b.dyn = nil, nil, nil, true
end

local function trimLayers(it, n)
    local L = it.layers
    for q = n + 1, #L do L[q][1] = nil end
    it.nl = n
end

local function now(world)
    local gt = rawget(_G, "GetTime")
    return (gt and gt()) or (world.time or 0) * 0.5
end

-- Turning (brief 6.3 "turn"; docs/ART.md 7.9). People and pets are drawn in 4 facings, so a
-- quarter turn is the next facing. A half turn shows the facing in between for R.TURN_STEP
-- seconds of real time (clockwise), so someone turning round is seen to turn instead of flipping.
-- Renderer-side state, weak-keyed by the actor table: a new session, lot or load starts every
-- actor already facing its way, and the camera's rotation never counts as a turn. An occupant
-- of an object slot faces the slot's way at once (its overlay is cut for that facing).
R.TURN_STEP = 0.14
local turnFrom = setmetatable({}, { __mode = "k" })
local turnTo = setmetatable({}, { __mode = "k" })
local turnT0 = setmetatable({}, { __mode = "k" })
local function turnFacing(a, target, t, instant)
    target = target % 4
    local to = turnTo[a]
    if to == nil or instant then
        turnFrom[a], turnTo[a], turnT0[a] = target, target, t
        return target
    end
    if to ~= target then
        -- start a turn (or redirect one) from the facing shown now
        local from = turnFrom[a]
        local shown = to
        if from ~= to and t - turnT0[a] < R.TURN_STEP then shown = (from + 1) % 4 end
        turnFrom[a], turnTo[a], turnT0[a] = shown, target, t
        to = target
    end
    local from = turnFrom[a]
    if from == to then return to end
    if (to - from) % 4 ~= 2 or t - turnT0[a] >= R.TURN_STEP then
        turnFrom[a] = to
        return to
    end
    return (from + 1) % 4
end
R.TurnFacing = turnFacing

-- An infant being carried (family: pose "carried", its carrier holds carry = "baby" on the same
-- cell and level) is drawn by the carrier's baby prop in their arms, not a second time on the floor.
local function carriedInArms(world, a)
    if a.pose ~= "carried" then return false end
    local cx, cy, lv = floor(a.x or 0), floor(a.y or 0), a.level or 0
    for _, b in pairs(world.actors) do
        if b ~= a and b.carry == "baby" and (b.level or 0) == lv and floor(b.x or -1) == cx and floor(b.y or -1) == cy then
            return true
        end
    end
    return false
end
R.CarriedInArms = carriedInArms

function R.BuildActors(world, cam, objKeys)
    local out = dynOut
    for n = #out, 1, -1 do out[n] = nil end
    local lot, A = world.lot, SS.Art
    local top = R.VisibleLevels(world, cam)
    local t = now(world)
    local count = 0
    -- R.missing = sprites missing in the last layout plus those missing in this frame
    R.missing = R.missingStatic or 0
    local roomLight = R._roomLight or {}
    R._roomLight = roomLight
    for q in pairs(roomLight) do roomLight[q] = nil end
    local ids = R._actorIds or {}
    R._actorIds = ids
    for q = #ids, 1, -1 do ids[q] = nil end
    for id in pairs(world.actors) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local a = world.actors[id]
        local lv = a.level or 0
        local hidden = a.hidden or carriedInArms(world, a)
        if lv <= top and not hidden and (a.kind or "human") == "human" then
            local age = a.age or "adult"
            if not AGE_CODE[age] then age = "adult" end
            local o = a.onObj and lot.objects[a.onObj]
            local oart = o and objArt(o.def)
            local slotName, slot = nil, nil
            if o and oart then slotName, slot = occupantSlot(world, a, o, oart) end
            local seated = (slot and slot.kind == "seat") or (o and not slot and a.pose == "sit")
            local carry = a.carry or R.OutfitItem(a)
            local pose = R.ArtPose(a, age, seated, carry)
            if not slot and pose == a.pose then pose = R.PoseVariant(world, a, age) or pose end
            if pose == "hold_hands" and not R.HoldPartner(world, a) then pose = "idle" end
            local occPose, occ
            if slot then
                local map = A.occupy and A.occupy[slot.kind]
                occPose = map and (map[a.pose or "idle"] or map["*"])
                local byAge = slot.occ and (slot.occ[age] or slot.occ.adult)
                occ = byAge and occPose and byAge[occPose]
                if occ then pose = occPose end
            end
            local P = A.poses and A.poses[pose]
            if not (P and P.ages and P.ages[age]) then pose = "idle"; P = A.poses and A.poses.idle end
            local nfr = (P and P.ages and P.ages[age]) or 1
            local fi = frameIndex(a, pose, nfr, (P and P.fps) or 2, t)
            local facing = a.facing or 0
            if o and slot then facing = ((o.f or 0) + (slot.face or 0)) % 4 end
            facing = turnFacing(a, facing, t, o and slot and true or nil)
            local k = (facing + cam.r) % 4
            local code = AGE_CODE[age]
            local fkey = fkeyOf(code, pose, fi, k)
            local u, v = G.vpos(a.x, a.y, cam.r, lot.w, lot.h)
            local gz = (lv == 0) and groundZ(world, a.x, a.y) or 0
            local z = lv * W.STORY + gz + (a.z or 0)
            local x, y
            if o and slot and occ then
                -- the occupant stands at the slot anchor: object anchor + an even pixel offset
                local au, av, az = objAnchor(world, cam, o)
                local ox, oy = R.ToCanvas(world, cam, au, av, az)
                local off = occ.off and (occ.off[k] or occ.off[tostring(k)])
                local ko = ((o.f or 0) + cam.r) % 4
                off = occ.off and (occ.off[ko] or occ.off[tostring(ko)]) or off
                x, y = ox + (off and off[1] or 0), oy + (off and off[2] or 0)
            else
                x, y = R.ToCanvas(world, cam, u, v, z)
            end
            count = count + 1
            local it = dynItem(count)
            it.kind, it.ref, it.level, it.x, it.y, it.key = "actor", id, lv, x, y, lv * LEVEL_KEY + u + v + 0.01
            it.onObj, it.occ, it.fkey, it.pose = nil, nil, fkey, pose
            it.age, it.fi, it.k, it.vu, it.vv, it.vz, it.slot = age, fi, k, u, v, z, nil
            local tr, tg, tb = lightTint(world, roomLight, lv, W.RoomAt(world, lv, floor(a.x), floor(a.y)))
            local alpha = (a.ghost and GHOST_ALPHA) or nil
            -- a slim or broad resident draws the average frames at its build's width, except in an
            -- object slot: the occupant overlays are cut against the average body
            local kx = not (o and slot and occ) and buildWidth(a.look, age) or nil
            local n = personLayers(it.layers, a, fkey, age, pose, tr, tg, tb, alpha, kx, carry)
            if a.ghost and n > 0 then ghostLayers(it.layers, n) end
            if n == 0 then
                -- no art for this frame: a counted placeholder
                local ph = use(nil)
                if ph then
                    local l = it.layers[1] or {}
                    it.layers[1] = l
                    l[1], l[2], l[3], l[4], l[5], l[6], l[7] = ph, 1, 1, 1, nil, nil, alpha
                    l[8], l[9], l[10], l[11], l[12], l[13], l[14] = nil, nil, nil, nil, nil, nil, nil
                    n = 1
                end
            end
            -- the soft ground shadow of a standing, walking or kneeling person, under the body (the
            -- first layer); seated, lying and swimming poses have none
            if n > 0 and not (o and slot and occ) and not a.ghost and not R.Reduced() then
                local shn = shadowOf[fkey]
                if shn == nil then
                    shn = pname(fkey, "shadow")
                    if not A.sprites[shn] then shn = false end
                    shadowOf[fkey] = shn
                end
                if shn then
                    local L = it.layers
                    local spare = L[n + 1] or {}
                    for q = n, 1, -1 do L[q + 1] = L[q] end
                    L[1] = spare
                    spare[1], spare[2], spare[3], spare[4], spare[5], spare[6], spare[7] = shn, 1, 1, 1, nil, nil, alpha
                    spare[8], spare[9], spare[10], spare[11], spare[12], spare[13], spare[14] = nil, nil, nil, nil, nil, nil, kx
                    n = n + 1
                    it.shadowLayer = 1
                else
                    it.shadowLayer = nil
                end
            else
                it.shadowLayer = nil
            end
            -- occupant overlay: the object's pixels in front of the occupant, drawn right above
            if o and slot and occ then
                local ko = ((o.f or 0) + cam.r) % 4
                local nfo = occ.n or 1
                local ofi = fi % nfo
                local ov, ovt = ovName(oart.id or o.def, slotName, (slot.occ[age] and age) or "adult", pose, ofi, ko)
                local S = A.sprites
                local au, av, az = objAnchor(world, cam, o)
                local ox, oy = R.ToCanvas(world, cam, au, av, az)
                local otr, otg, otb = lightTint(world, roomLight, o.level or 0, W.RoomAt(world, o.level or 0, o.x, o.y))
                if S[ov] then
                    n = n + 1
                    local l = it.layers[n] or {}
                    it.layers[n] = l
                    l[1], l[2], l[3], l[4], l[5], l[6], l[7] = ov, otr, otg, otb, ox, oy, nil
                    l[8], l[9], l[10], l[11], l[12], l[13], l[14] = nil, nil, nil, nil, nil, nil, nil
                end
                if S[ovt] then
                    local vt = variantTint(o, oart)
                    n = n + 1
                    local l = it.layers[n] or {}
                    it.layers[n] = l
                    l[1], l[2], l[3], l[4], l[5], l[6], l[7] = ovt, vt[1] * otr, vt[2] * otg, vt[3] * otb, ox, oy, nil
                    l[8], l[9], l[10], l[11], l[12], l[13], l[14] = nil, nil, nil, nil, nil, nil, nil
                end
                it.onObj, it.occ, it.slot = a.onObj, true, slotName
            end
            trimLayers(it, n)
            -- sort box: the occupied object's box, else a body-sized column
            local ob = o and objKeys and objKeys[a.onObj] and objKeys[a.onObj].objBox
            if ob then
                setBox(it.box, ob[1], ob[2], ob[3], ob[4], ob[5], ob[6])
            else
                local h = HEIGHT[age] or 1.5
                local rad = (age == "adult") and 0.16 or 0.13
                if P and P.lying and not o then
                    setBox(it.box, u - 0.45, v - 0.45, z, u + 0.45, v + 0.45, z + 0.4)
                elseif a.swimming then
                    setBox(it.box, u - rad, v - rad, z - 0.6, u + rad, v + rad, z + 0.6)
                else
                    setBox(it.box, u - rad, v - rad, z, u + rad, v + rad, z + h)
                end
            end
            it.box.tie = 1e6 + count
            out[#out + 1] = it
        elseif lv <= top and not hidden then
            -- pets (family: a.kind = "dog" | "cat", drawn by breed, pattern and coat colours,
            -- docs/ART.md 7.6); any other animal without art is a counted placeholder
            local u, v = G.vpos(a.x, a.y, cam.r, lot.w, lot.h)
            local z = lv * W.STORY + ((lv == 0) and groundZ(world, a.x, a.y) or 0) + (a.z or 0)
            local po = a.onObj and lot.objects[a.onObj]
            if po and (po.level or 0) ~= lv then po = nil end
            local poart = po and objArt(po.def)
            -- a pet slot (pet bed, litter tray): the pet faces the slot's way at once, like a seated person
            local pslotName, pslot = nil, nil
            if poart then
                pslotName, pslot = occupantSlot(world, a, po, poart)
                if not (pslot and PET_SLOT[pslot.kind]) then pslotName, pslot = nil, nil end
            end
            local facing = a.facing or 0
            if pslot then facing = ((po.f or 0) + (pslot.face or 0)) % 4 end
            local k = (turnFacing(a, facing, t, pslot and true or nil) + cam.r) % 4
            local tr, tg, tb = lightTint(world, roomLight, lv, W.RoomAt(world, lv, floor(a.x), floor(a.y)))
            local names, breed, bid, ppose, pfi = petSprites(a, k, t)
            -- the slot's overlay for this breed and pose, when the art has one
            local prec
            if pslot and names then
                local POV = A.petOverlays
                local byDef = POV and POV[poart.id or po.def]
                local bySlot = byDef and byDef[pslotName]
                local byBreed = bySlot and bySlot[bid]
                prec = byBreed and byBreed[ppose]
            end
            local x, y
            if prec then
                -- at the slot: object anchor + an even pixel offset (the overlay's own placement)
                local au, av, az = objAnchor(world, cam, po)
                local ox, oy = R.ToCanvas(world, cam, au, av, az)
                local ko = ((po.f or 0) + cam.r) % 4
                local off = prec.off and (prec.off[ko] or prec.off[tostring(ko)])
                x, y = ox + (off and off[1] or 0), oy + (off and off[2] or 0)
            else
                if po then z = z + objTopAt(po, floor(a.x), floor(a.y)) end
                x, y = R.ToCanvas(world, cam, u, v, z)
            end
            count = count + 1
            local it = dynItem(count)
            it.kind, it.ref, it.level, it.x, it.y, it.key = "actor", id, lv, x, y, lv * LEVEL_KEY + u + v + 0.01
            it.onObj, it.occ, it.fkey, it.pose, it.slot, it.shadowLayer = nil, nil, nil, a.pose, nil, nil
            it.age, it.fi, it.k, it.vu, it.vv, it.vz = nil, pfi or 0, k, u, v, z
            local n = 0
            if names then
                local look = a.look or {}
                local c1 = type(look.skin) == "table" and look.skin or PET_P
                local c2 = type(look.hair) == "table" and look.hair or PET_S
                local alpha = (a.ghost and GHOST_ALPHA) or nil
                -- the contact shadow on the floor; none in a slot (like a seated person) or for a ghost
                if names.sh and not prec and not a.ghost and not R.Reduced() then
                    n = n + 1
                    local l = it.layers[n] or {}
                    it.layers[n] = l
                    l[1], l[2], l[3], l[4], l[5], l[6], l[7] = names.sh, 1, 1, 1, nil, nil, alpha
                    l[8], l[9], l[10], l[11], l[12], l[13], l[14] = nil, nil, nil, nil, nil, nil, nil
                    it.shadowLayer = 1
                end
                for q = 1, 3 do
                    local nm = (q == 1 and names.p) or (q == 2 and names.s) or names.d
                    if nm then
                        local c = (q == 1 and c1) or (q == 2 and c2) or nil
                        n = n + 1
                        local l = it.layers[n] or {}
                        it.layers[n] = l
                        if c then
                            l[1], l[2], l[3], l[4] = nm, (c[1] or c.r or 1) * tr, (c[2] or c.g or 1) * tg, (c[3] or c.b or 1) * tb
                        else
                            l[1], l[2], l[3], l[4] = nm, tr, tg, tb
                        end
                        l[5], l[6], l[7] = nil, nil, alpha
                        l[8], l[9], l[10], l[11], l[12], l[13], l[14] = nil, nil, nil, nil, nil, nil, nil
                    end
                end
            end
            if n == 0 then
                local s = use(animalName(a.kind, a.pose, k))
                if s then
                    n = 1
                    local l = it.layers[1] or {}
                    it.layers[1] = l
                    l[1], l[2], l[3], l[4], l[5], l[6], l[7] = s, 1, 1, 1, nil, nil, nil
                    l[8], l[9], l[10], l[11], l[12], l[13], l[14] = nil, nil, nil, nil, nil, nil, nil
                end
            end
            -- the pet overlay: the object's pixels in front of the pet, drawn right above it
            if n > 0 and prec then
                local ko = ((po.f or 0) + cam.r) % 4
                local ofi = (pfi or 0) % (prec.n or 1)
                local ov, ovt = povName(poart.id or po.def, pslotName, bid, ppose, ofi, ko)
                local S = A.sprites
                local au, av, az = objAnchor(world, cam, po)
                local ox, oy = R.ToCanvas(world, cam, au, av, az)
                local otr, otg, otb = lightTint(world, roomLight, po.level or 0, W.RoomAt(world, po.level or 0, po.x, po.y))
                if S[ov] then
                    n = n + 1
                    local l = it.layers[n] or {}
                    it.layers[n] = l
                    l[1], l[2], l[3], l[4], l[5], l[6], l[7] = ov, otr, otg, otb, ox, oy, nil
                    l[8], l[9], l[10], l[11], l[12], l[13], l[14] = nil, nil, nil, nil, nil, nil, nil
                end
                if S[ovt] then
                    local vt = variantTint(po, poart)
                    n = n + 1
                    local l = it.layers[n] or {}
                    it.layers[n] = l
                    l[1], l[2], l[3], l[4], l[5], l[6], l[7] = ovt, vt[1] * otr, vt[2] * otg, vt[3] * otb, ox, oy, nil
                    l[8], l[9], l[10], l[11], l[12], l[13], l[14] = nil, nil, nil, nil, nil, nil, nil
                end
                it.onObj, it.occ, it.slot = a.onObj, true, pslotName
            end
            if n > 0 then
                trimLayers(it, n)
                -- sort box: the occupied object's box in a slot, else a body-sized box
                local ob = prec and objKeys and objKeys[a.onObj] and objKeys[a.onObj].objBox
                if ob then
                    setBox(it.box, ob[1], ob[2], ob[3], ob[4], ob[5], ob[6])
                else
                    local h = breed and breed.h or 0.6
                    local r = breed and math.min(0.35, (breed.len or 0.5) * 0.5) or 0.25
                    setBox(it.box, u - r, v - r, z, u + r, v + r, z + h)
                end
                it.box.tie = 1e6 + count
                out[#out + 1] = it
            else
                count = count - 1
            end
        end
    end
    -- vehicles on the street band
    count = R.CollectVehicles(world, cam, out, count, t)
    -- effects from every registered provider
    if SS.RenderFx and SS.RenderFx.Collect then
        count = SS.RenderFx.Collect(world, cam, out, count, dynItem, trimLayers, setBox)
    end
    R._dynCount = count
    return out
end

---------------------------------------------------------------------------------------------------
-- Street vehicles (SS.Street.vehicles, owned by visitors): body + paint + ground shadow, the
-- curb-side door open while riders board (state parked, t < 0.5 or doorOpen), light-bar flashing
-- (fire truck, police car) while arriving or parked, livery decals and a slight bob while driving.
-- Paint: the livery colour, else a colour from the kind's paint list picked by the vehicle id (so
-- visitors' cars differ), else the kind's default paint.
---------------------------------------------------------------------------------------------------
local vehPaint = setmetatable({}, { __mode = "k" })
local vehNames = {}
local function vehName(kind, k, suffix)
    local t = vehNames[kind]
    if not t then t = {}; vehNames[kind] = t end
    local key = k .. (suffix or "")
    local s = t[key]
    if not s then s = "veh:" .. kind .. ":" .. key; t[key] = s end
    return s
end
R.VehicleSprite = vehName
local function paintOf(veh, vt)
    if not vt then return WHITE end
    local c = veh.livery and vt.livery and vt.livery[veh.livery]
    if c then return c end
    local list = vt.paints
    if list and #list > 1 then
        local p = vehPaint[veh]
        if not p then
            local id, h = tostring(veh.id or veh.i or 0), 0
            for q = 1, #id do h = (h * 31 + id:byte(q)) % 65521 end
            p = list[(h % #list) + 1]
            vehPaint[veh] = p
        end
        return p
    end
    return vt.paint or WHITE
end
R.VehiclePaint = paintOf
local function vlayer(it, n, name, r, g, b, x, y)
    local l = it.layers[n]
    if not l then l = {}; it.layers[n] = l end
    l[1], l[2], l[3], l[4], l[5], l[6], l[7] = name, r, g, b, x, y, nil
    l[8], l[9], l[10], l[11], l[12], l[13], l[14] = nil, nil, nil, nil, nil, nil, nil
end
function R.CollectVehicles(world, cam, out, count, t)
    local St = SS.Street
    if not (St and type(St.vehicles) == "table") then return count end
    local A = SS.Art
    local S = A.sprites
    local lot = world.lot
    local roadZ = A.vehicleRoadZ or 0
    for _, veh in ipairs(St.vehicles) do
        if type(veh) == "table" and veh.kind and not veh.hidden then
            -- visitors' Sim/Street.lua: x (current position) and i (parking column) are column
            -- indices; the column's centre (where riders board, St.CurbPos) is x + 0.5
            local vx = (veh.x or veh.i or 0) + 0.5
            local vy = veh.y or (lot.h + 1.25)
            local u, v = G.vpos(vx, vy, cam.r, lot.w, lot.h)
            local x, y = R.ToCanvas(world, cam, u, v, roadZ)
            local dir = ((veh.dir or 1) > 0) and 1 or -1
            local facing = dir > 0 and 3 or 1
            local k = (facing + cam.r) % 4
            local vt = A.vehicles and A.vehicles[veh.kind]
            local kind = veh.kind
            if not (vt and S[vehName(kind, k)]) then
                kind = (A.vehicles and A.vehicles.car and S[vehName("car", k)]) and "car" or kind
                vt = A.vehicles and A.vehicles[kind]
            end
            local st = veh.state
            local moving = st == "arriving" or st == "leaving"
            local suffix
            local sts = vt and vt.states
            if st == "parked" and (veh.doorOpen or (veh.t or 0) < 0.5) then
                local o = dir > 0 and ":openr" or ":openl"
                if sts and sts[o:sub(2)] then suffix = o end
            end
            local calm = world.settings and world.settings.reducedMotion
            if not suffix and sts and sts.flash and st ~= "leaving" and (calm or floor((t or 0) * 2.5) % 2 == 1) then suffix = ":flash" end
            local base = vehName(kind, k, suffix)
            if not S[base] then base = vehName(kind, k) end
            count = count + 1
            local it = dynItem(count)
            it.kind, it.ref, it.level, it.x, it.y, it.key = "vehicle", veh.id or veh.kind, 0, x, y, u + v
            it.onObj, it.occ, it.fkey, it.pose = nil, nil, nil, nil
            it.shadowLayer, it.slot, it.age = nil, nil, nil
            local by = (moving and floor((t or 0) * 8) % 2 == 1) and -0.5 or nil
            local n = 0
            local sh = vehName(kind, k, ":sh")
            if S[sh] then n = n + 1; vlayer(it, n, sh, 1, 1, 1, nil, nil); it.shadowLayer = 1 end
            local s = use(base)
            if s then
                n = n + 1
                vlayer(it, n, s, 1, 1, 1, nil, by and (y + by) or nil)
                local tn = s .. ":t"
                if S[tn] then
                    local c = paintOf(veh, vt)
                    n = n + 1
                    vlayer(it, n, tn, c[1], c[2], c[3], nil, by and (y + by) or nil)
                end
                local lg = veh.livery and vt and vt.logos and vt.logos[veh.livery] and (vehName(kind, k, ":logo:" .. veh.livery))
                if lg and S[lg] then n = n + 1; vlayer(it, n, lg, 1, 1, 1, nil, by and (y + by) or nil) end
            end
            trimLayers(it, n)
            local half = (veh.len or (vt and vt.len) or 2) / 2
            local du = G.vpos(1, 0, cam.r, 0, 0) - G.vpos(0, 0, cam.r, 0, 0)
            if abs(du) > 0.5 then setBox(it.box, u - half, v - 0.45, roadZ, u + half, v + 0.45, roadZ + 1.4)
            else setBox(it.box, u - 0.45, v - half, roadZ, u + 0.45, v + half, roadZ + 1.4) end
            it.box.tie = 2e6 + count
            if n > 0 then out[#out + 1] = it end
        end
    end
    return count
end

-- Merge actors into the static order by key (offline previews; the client uses frame levels).
function R.Merge(items, actors)
    local all = {}
    for n = 1, #items do all[n] = items[n] end
    for n = 1, #actors do all[#all + 1] = actors[n] end
    table.sort(all, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        if a.kind ~= b.kind then return a.kind ~= "actor" end
        return tostring(a.ref) < tostring(b.ref)
    end)
    return all
end

---------------------------------------------------------------------------------------------------
-- Dynamic placement: levels for people/vehicles/effects between the statics, with bumping.
-- Works on R.state (items with .lvl, .succ, grid). Returns the number of bumped statics.
---------------------------------------------------------------------------------------------------
local bumped, nb = {}, 0
local dynBehind, dynFront, dynDyn = {}, {}, {}
local work = {}
local stamp = 0

local function listFor(t, i)
    local l = t[i]
    if not l then l = { n = 0 }; t[i] = l end
    l.n = 0
    return l
end

function R.PlaceDynamic(items, grid, dyn)
    local STRIDE = R.STRIDE
    -- restore last frame's bumps
    for q = 1, nb do local s = bumped[q]; s.cur = s.lvl * STRIDE; s.bumped = nil; bumped[q] = nil end
    nb = 0
    for i = 1, #items do local it = items[i]; if not it.cur then it.cur = it.lvl * STRIDE end end
    local nd = #dyn
    stamp = stamp + 1
    for d = 1, nd do
        local a = dyn[d]
        a.dl = 0
        local bh, fr = listFor(dynBehind, d), listFor(dynFront, d)
        local ab = a.box
        if grid then
            local x0, x1, y0, y1 = screenRect(ab)
            local seen = stamp * 1000 + d
            for bx = floor(x0 / BX), floor(x1 / BX) do
                local col = grid[bx]
                if col then
                    for by = floor(y0 / BY), floor(y1 / BY) do
                        local cell = col[by]
                        if cell then
                            for q = 1, #cell do
                                local s = cell[q]
                                if s.seen ~= seen then
                                    s.seen = seen
                                    local skip = false
                                    if a.onObj and s.ref == a.onObj and s.kind == "obj" then
                                        -- the occupant is always drawn above its own object
                                        bh.n = bh.n + 1; bh[bh.n] = s; skip = true
                                    end
                                    if not skip and hexOverlap(s.box, ab) then
                                        if behind(s.box, ab) then bh.n = bh.n + 1; bh[bh.n] = s
                                        else fr.n = fr.n + 1; fr[fr.n] = s end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        local dd = listFor(dynDyn, d)
        for e = 1, d - 1 do
            local b = dyn[e]
            if hexOverlap(b.box, ab) then
                dd.n = dd.n + 1
                dd[dd.n] = e
            end
        end
    end
    -- relax: dyn level > every static/dyn behind it; statics in front are bumped above it
    local iter = 0
    local changed = true
    while changed and iter < 8 do
        changed = false
        iter = iter + 1
        for d = 1, nd do
            local a = dyn[d]
            local need = 0
            local bh = dynBehind[d]
            for q = 1, bh.n do local c = bh[q].cur + 1; if c > need then need = c end end
            local dd = dynDyn[d]
            for q = 1, dd.n do
                local b = dyn[dd[q]]
                if behind(b.box, a.box) then
                    if b.dl + 1 > need then need = b.dl + 1 end
                end
            end
            if need > a.dl then a.dl = need; changed = true end
            -- dyns placed earlier that must be in front of this one
            for q = 1, dd.n do
                local b = dyn[dd[q]]
                if not behind(b.box, a.box) and b.dl <= a.dl then b.dl = a.dl + 1; changed = true end
            end
            local fr = dynFront[d]
            for q = 1, fr.n do
                local s = fr[q]
                if s.cur <= a.dl then
                    -- bump s and everything in front of it (successors)
                    local wn = 1
                    work[1] = s
                    s.cur = a.dl + 1
                    while wn > 0 do
                        local x = work[wn]; work[wn] = nil; wn = wn - 1
                        if not x.bumped then x.bumped = true; nb = nb + 1; bumped[nb] = x end
                        local sc_ = x.succ
                        for m = 1, #sc_ do
                            local y = sc_[m]
                            if y.cur <= x.cur then
                                y.cur = x.cur + 1
                                wn = wn + 1; work[wn] = y
                            end
                        end
                    end
                    changed = true
                end
            end
        end
    end
    return nb
end

---------------------------------------------------------------------------------------------------
-- Picking (masks are MASK_CELL x MASK_CELL hi sprite px cells)
---------------------------------------------------------------------------------------------------
-- px, py: hi sprite pixels relative to the sprite's top-left corner.
function R.MaskHit(name, px, py)
    local s = SS.Art.sprites[name]
    if not s then return false end
    if px < 0 or py < 0 or px >= s[4] or py >= s[5] then return false end
    if not s[10] or s[10] == "" then return false end
    local cell = SS.Art.maskCell or 8
    local cx, cy = floor(px / cell), floor(py / cell)
    local bit = cy * s[8] + cx
    local pos = floor(bit / 4) + 1
    local ch = s[10]:sub(pos, pos)
    local n = tonumber(ch, 16) or 0
    local b = 3 - bit % 4
    return floor(n / 2 ^ b) % 2 == 1
end

-- Does draw item `it` cover canvas point (px, py) (zoom 1)?
local function itemHit(it, px, py)
    local sc = SC()
    local L = it.layers
    for l = 1, (it.nl or #L) do
        local ly = L[l]
        local name = ly and ly[1]
        local s = name and SS.Art.sprites[name]
        if s and s[10] ~= "" and (ly[7] or it.alpha) ~= 0 then
            local ax, ay = (ly[5] or it.x), (ly[6] or it.y)
            local hx = (px - ax) * sc / (ly[14] or 1) + s[6]
            local hy = (py - ay) * sc + s[7]
            if (not ly[8] or (hx >= ly[8] and hx < ly[10] and hy >= ly[9] and hy < ly[11])) and R.MaskHit(name, hx, hy) then
                return true
            end
        end
    end
    return false
end
R.ItemHit = itemHit

-- Front-most item under a canvas point (zoom 1); items in draw order.
function R.PickItems(items, px, py)
    for n = #items, 1, -1 do
        local it = items[n]
        if it.kind ~= "floor" and not it.short and it.kind ~= "shadow" and it.kind ~= "mark" and itemHit(it, px, py) then return it end
    end
end

local pickOut = {}
-- Everything under the cursor, front to back: { {kind, ref, wx, wy, level} ... }; walls stop the
-- list (things fully behind a wall are not offered). Deterministic for the same scene and point.
function R.PickAllAt(world, px, py)
    local out = {}
    local cam = R.cam
    local lv = cam.level or 0
    local wx, wy = R.FromCanvas(world, cam, px, py, lv)
    local cands = {}
    for _, it in ipairs(R.state.actors or {}) do
        if itemHit(it, px, py) then cands[#cands + 1] = it end
    end
    for _, it in ipairs(R.state.items or {}) do
        if (it.kind == "obj" or (it.kind == "wall" and not it.short) or it.kind == "roof") and itemHit(it, px, py) then
            cands[#cands + 1] = it
        end
    end
    -- topmost first: the client draws higher frame levels later, and at an equal level a dynamic
    -- frame (person) after the static ones
    table.sort(cands, function(a, b)
        local la, lb = a.cur or a.dl or 0, b.cur or b.dl or 0
        if la ~= lb then return la > lb end
        local da, db = a.cur == nil, b.cur == nil
        if da ~= db then return da end
        return tostring(a.ref) < tostring(b.ref)
    end)
    local seen = {}
    for _, it in ipairs(cands) do
        if it.kind == "wall" or it.kind == "roof" then break end
        local kind = (it.kind == "actor") and "actor" or "obj"
        if (it.kind == "actor" or it.kind == "obj") and not seen[kind .. tostring(it.ref)] then
            seen[kind .. tostring(it.ref)] = true
            out[#out + 1] = { kind = kind, ref = it.ref, wx = wx, wy = wy, level = it.level or lv }
        end
    end
    if W.InLot(world.lot, floor(wx), floor(wy)) then out[#out + 1] = { kind = "cell", wx = wx, wy = wy, level = lv } end
    return out
end

function R.PickAll(world)
    local px, py = R.CursorToCanvas()
    if not px then return {} end
    return R.PickAllAt(world, px, py)
end

-- Returns kind, ref, worldX, worldY, level for the thing under the cursor.
function R.Pick(world)
    local list = R.PickAll(world)
    local e = list[1]
    if not e then return end
    return e.kind, e.ref, e.wx, e.wy, e.level
end

---------------------------------------------------------------------------------------------------
-- WoW frame layer
---------------------------------------------------------------------------------------------------
local pool, used = {}, 0
local dynFrames = {}
local groundTex = {}
local groundRows = {}

local function sheetPath(n)
    local A = SS.Art
    if (R.tier == "lo" or A.loOnly) and A.sheetsLo and A.sheetsLo[n] then return A.sheetsLo[n] end
    return A.sheets[n]
end

-- Texture filter probe result lives in SS.Compat; fall back to the plain call.
function R.SetTex(tex, file)
    if tex.ssFile == file then return end
    tex.ssFile = file
    if SS.Compat and SS.Compat.caps and SS.Compat.caps.textureFilter then
        tex:SetTexture(file, nil, nil, "LINEAR")
    else
        tex:SetTexture(file)
    end
end

-- Place a sprite layer on a texture. x, y: anchor in canvas px (zoom 1). Crop in hi sprite px.
-- k: optional size multiplier (effects), blend: optional blend mode ("ADD" for glows).
-- k scales the sprite about its anchor; kx scales its width only (a resident's body build, 7.8)
local function setSprite(tex, name, zoom, x, y, r, g, b, a, c0, c1, c2, c3, k, blend, kx)
    local s = SS.Art.sprites[name]
    if not s then tex:Hide(); return end
    local size = SS.Art.sheetSize
    local sc = SC()
    if k and k ~= 1 then sc = sc / k end
    kx = kx or 1
    blend = blend or "BLEND"
    if tex.ssBlend ~= blend then tex:SetBlendMode(blend); tex.ssBlend = blend end
    local sx, sy, w, h = s[2], s[3], s[4], s[5]
    local ox, oy = 0, 0
    if c0 then
        sx, sy = s[2] + c0, s[3] + c1
        w, h = c2 - c0, c3 - c1
        ox, oy = c0, c1
    end
    R.SetTex(tex, sheetPath(s[1]))
    tex:SetTexCoord(sx / size, (sx + w) / size, sy / size, (sy + h) / size)
    tex:SetSize(max(0.01, w / sc * zoom * kx), max(0.01, h / sc * zoom))
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", R.canvas, "TOPLEFT", (x + (ox - s[6]) / sc * kx) * zoom, -(y + (oy - s[7]) / sc) * zoom)
    tex:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
    tex:Show()
end
R.SetSprite = setSprite

function R.OnArtFormat(fmt)
    -- every texture re-resolves its sheet file on the next layout
    for _, f in ipairs(pool) do for _, t in ipairs(f.tex) do t.ssFile = nil end end
    for _, f in pairs(dynFrames) do for _, t in ipairs(f.tex) do t.ssFile = nil end end
    for _, t in ipairs(groundTex) do t.ssFile = nil end
    if SS.UI then SS.UI.dirty = true end
end
R.SetArtFormat = function(fmt)
    if SS.Art and SS.Art.SetFormat then return SS.Art.SetFormat(fmt) end
    return false, "no art manifest"
end

function R.Init(viewport)
    R.viewport = viewport
    local canvas = CreateFrame("Frame", nil, viewport)
    canvas:SetSize(10, 10)
    R.canvas = canvas
    R.floorFrame = CreateFrame("Frame", nil, canvas)
    R.floorFrame:SetAllPoints(canvas)
    R.overlay = CreateFrame("Frame", nil, canvas)
    R.overlay:SetAllPoints(canvas)
    R.marker = R.overlay:CreateTexture(nil, "OVERLAY")
    R.bubble = R.overlay:CreateTexture(nil, "OVERLAY", nil, 1)
    R.bubbleIcon = R.overlay:CreateTexture(nil, "OVERLAY", nil, 2)
    R.progressTex = R.overlay:CreateTexture(nil, "OVERLAY", nil, 1)
    R.progressFill = R.overlay:CreateTexture(nil, "OVERLAY", nil, 2)
    R.stats.allocated = (R.stats.allocated or 0) + 5
    R.balloonTex = {}
    R.xrayTex = {}
    -- the configured art format from saved settings (ui-shell's /sidestreet art switch)
    local db = rawget(_G, "SideStreetDB")
    local fmt = type(db) == "table" and type(db.settings) == "table" and db.settings.artFormat
    if (fmt == "blp" or fmt == "tga") and SS.Art and SS.Art.SetFormat and SS.Art.format ~= fmt then SS.Art.SetFormat(fmt) end
end

local function getFrame(n)
    local f = pool[n]
    if not f then
        f = CreateFrame("Frame", nil, R.canvas)
        f:SetAllPoints(R.canvas)
        f.tex = {}
        pool[n] = f
    end
    f:Show()
    return f
end

local function fillFrame(f, it, zoom)
    local L = it.layers
    local n = it.nl or #L
    for l = 1, n do
        local ly = L[l]
        local t = f.tex[l]
        if not t then
            t = f:CreateTexture(nil, "ARTWORK", nil, min(7, l - 1)); f.tex[l] = t
            R.stats.allocated = (R.stats.allocated or 0) + 1
        end
        if l > 8 then t:SetDrawLayer("OVERLAY", min(7, l - 9)) end
        setSprite(t, ly[1], zoom, ly[5] or it.x, ly[6] or it.y, ly[2], ly[3], ly[4], ly[7] or it.alpha, ly[8], ly[9], ly[10], ly[11], ly[12], ly[13], ly[14])
    end
    for l = n + 1, #f.tex do f.tex[l]:Hide() end
end

local function groundRowFrame(n)
    local f = groundRows[n]
    if not f then
        f = CreateFrame("Frame", nil, R.canvas)
        f:SetAllPoints(R.canvas)
        f.tex = {}
        groundRows[n] = f
    end
    f:Show()
    return f
end

function R.Layout(world)
    local cam = R.cam
    local zoom = cam.zoom
    -- a lean package built with tools/build_art.py --lo-only ships only the lo tier (SS.Art.loOnly)
    if SS.Art.loOnly or R.tierMode == "lo" then R.tier = "lo" elseif R.tierMode == "hi" then R.tier = "hi"
    else R.tier = (zoom <= 1) and "lo" or "hi" end
    local cw, ch = R.CanvasSize(world, cam)
    R.canvas:SetSize(cw * zoom, ch * zoom)
    R.canvas:ClearAllPoints()
    R.canvas:SetPoint("CENTER", R.viewport, "CENTER", cam.panX, cam.panY)
    local floors, items, objKeys, ground = R.BuildStatic(world, cam)
    R.state.floors, R.state.items, R.state.objKeys, R.state.ground = floors, items, objKeys, ground
    local base = R.canvas:GetFrameLevel()
    -- ground: floor tiles and ground entries in one frame per view diagonal (back to front)
    local rows, rowOf = {}, {}
    local function rowIndex(row)
        local q = rowOf[row]
        if not q then rows[#rows + 1] = row; q = true; rowOf[row] = q end
    end
    for _, e in ipairs(floors) do rowIndex(e.row or 0) end
    for _, e in ipairs(ground) do rowIndex(e.row or 0) end
    table.sort(rows)
    for q, row in ipairs(rows) do rowOf[row] = q end
    local perRow = {}
    local water = {}
    R.state.water = water
    if SS.RenderFx then SS.RenderFx.lastWater = -1 end
    local function put(e, sub)
        local q = rowOf[e.row or 0]
        local f = groundRowFrame(q)
        f:SetFrameLevel(base + q)
        perRow[q] = (perRow[q] or 0) + 1
        local t = f.tex[perRow[q]]
        if not t then
            t = f:CreateTexture(nil, "BACKGROUND"); f.tex[perRow[q]] = t
            R.stats.allocated = (R.stats.allocated or 0) + 1
        end
        t:SetDrawLayer((sub or 0) >= 2 and "ARTWORK" or "BACKGROUND", min(7, sub or 0))
        local tn = e.tint or WHITE
        setSprite(t, e.sprite, zoom, e.x, e.y, tn[1], tn[2], tn[3], e.alpha or 1)
        if e.anim then water[#water + 1] = { t, e } end
    end
    for _, e in ipairs(floors) do if not e.pool and not e.pond then put(e, 0) end end
    for _, e in ipairs(ground) do put(e, e.sub or 0) end
    for q = 1, #groundRows do
        local f = groundRows[q]
        local n = perRow[q] or 0
        if n == 0 and q > #rows then f:Hide() end
        for l = n + 1, #f.tex do f.tex[l]:Hide() end
    end
    R.groundLevels = #rows + 1
    local vis = 0
    for q = 1, #rows do vis = vis + (perRow[q] or 0) end
    local sbase = base + R.groundLevels
    R.staticBase = sbase
    for n = 1, #items do
        local it = items[n]
        it.cur = it.lvl * R.STRIDE
        local f = getFrame(n)
        f:SetFrameLevel(min(9000, sbase + it.cur))
        fillFrame(f, it, zoom)
        it.frame = f
    end
    for n = #items + 1, #pool do pool[n]:Hide() end
    for n = 1, #items do vis = vis + (items[n].nl or #items[n].layers) end
    R.stats.visibleStatic = vis
    R.stats.visible = vis + (R.stats.visibleDynamic or 0)
    R.state.statics = #items
    local top = 0
    for n = 1, #items do if items[n].cur > top then top = items[n].cur end end
    R.overlay:SetFrameLevel(min(9500, sbase + top + 64))
    R.layoutTime = world.time
    R.layoutZoom = zoom
end

-- Door leaves open while someone is in or next to the doorway.
local function updateDoors(world, zoom)
    local doors = R.state.doors
    if not doors then return end
    for _, it in ipairs(doors) do
        local d = it.door
        local open = false
        for _, a in pairs(world.actors) do
            if (a.level or 0) == (it.level or 0) and abs(a.x - d.wx) < 0.75 and abs(a.y - d.wy) < 0.75 then open = true; break end
        end
        if open ~= (d.isOpen or false) then
            d.isOpen = open
            local L = it.layers[d.layer]
            if L then
                if d.leaf then
                    L[7] = (not open) and 0 or nil     -- the leaf item is transparent while the door is shut
                else
                    L[1] = open and d.open or d.closed
                    local c = open and d.co or d.cc
                    if c then L[8], L[9], L[10], L[11] = c[1], c[2], c[3], c[4] end
                end
                if it.frame and it.frame.tex[d.layer] then
                    local t = it.frame.tex[d.layer]
                    setSprite(t, L[1], zoom, L[5] or it.x, L[6] or it.y, L[2], L[3], L[4], L[7], L[8], L[9], L[10], L[11])
                end
            end
        end
    end
end
R.UpdateDoors = updateDoors

local function hideBalloons(from)
    local bt = R.balloonTex or {}
    for q = from, #bt do bt[q].bg:Hide(); bt[q].icon:Hide() end
end

-- Overlay entries (drawn above everything): the selection marker over the selected person, a
-- progress bar over them while they perform a timed action, and a speech/thought balloon (with its
-- icon) over every visible person that has one, at most 12.
-- Fills the pooled overlayOut list with { name, x, y, k, r, g, b, a, c0, c1, c2, c3,
-- what = "xray" | "marker" | "progress" | "progress_fill" | "balloon" | "icon" } and returns the
-- count (no per-frame garbage).
local overlayOut = {}
local function ovEntry(n, what, name, x, y, k, r, g, b, a, c0, c1, c2, c3)
    local e = overlayOut[n]
    if not e then e = {}; overlayOut[n] = e end
    e[1], e[2], e[3], e[4], e.what = name, x, y, k, what
    e[5], e[6], e[7], e[8] = r or 1, g or 1, b or 1, a or 1
    e[9], e[10], e[11], e[12] = c0, c1, c2, c3
    return n
end
R.XRAY_ALPHA = 0.45

-- How far the person's current action is (0..1), or nil when there is nothing to show: the
-- contextual progress indicator over the selected person (brief 6.3). Only the "perform" phase of
-- an action counts. It uses the shell's own measure when present, so the bar over the person and
-- the bar in the control panel always agree; otherwise the same rule: duration, until a need is
-- full, or the maximum duration.
function R.ActProgress(a)
    local act = a and a.act
    if not act or act.phase ~= "perform" then return nil end
    local f
    local UIm = SS.UI
    if UIm and type(UIm.ActProgress) == "function" then
        f = UIm.ActProgress(a, act)
    else
        local ia = SS.Interactions and SS.Interactions[act.iid]
        if not ia then return nil end
        local t = act.t or 0
        if ia.dur and ia.dur > 0 then f = t / ia.dur
        elseif ia.untilFull then f = (((a.needs and a.needs[ia.untilFull]) or 0) + 100) / 198
        elseif ia.maxDur and ia.maxDur > 0 then f = t / ia.maxDur end
    end
    if type(f) ~= "number" or f ~= f or f <= 0 then return nil end
    return min(1, f)
end
function R.OverlayEntries(world, dyn, selectedId)
    local n = 0
    local balloons = 0
    local A = SS.Art
    local S = A.sprites
    for q = 1, #dyn do
        local it = dyn[q]
        if it.kind == "actor" then
            local a = world.actors[it.ref]
            local head = (a and (((a.kind or "human") ~= "human") and 0.7 or HEIGHT[a.age or "adult"]) or 1.5) * 32
            if it.ref == selectedId and a and (a.level or 0) < ((R.cam and R.cam.level) or 0) then
                -- the selected person is below the floor being viewed: a see-through silhouette on top
                -- so the upper floor never hides them (brief 6.2)
                for l = 1, it.nl or 0 do
                    local L = it.layers[l]
                    if L[1] and l ~= it.shadowLayer then
                        n = ovEntry(n + 1, "xray", L[1], L[5] or it.x, L[6] or it.y, nil, L[2], L[3], L[4], R.XRAY_ALPHA)
                    end
                end
            end
            if it.ref == selectedId and S["icon:marker"] then
                local bob = (world.settings and world.settings.reducedMotion) and 0 or math.sin(now(world) * 3) * 3
                n = ovEntry(n + 1, "marker", "icon:marker", it.x, it.y - head - 14 + bob, nil)
            end
            if it.ref == selectedId and a and S["icon:progress"] and S["icon:progress_fill"] then
                local frac = R.ActProgress(a)
                if frac then
                    local fs = S["icon:progress_fill"]
                    n = ovEntry(n + 1, "progress", "icon:progress", it.x, it.y - head - 2, nil)
                    n = ovEntry(n + 1, "progress_fill", "icon:progress_fill", it.x, it.y - head - 2, nil,
                        1, 1, 1, 1, 0, 0, max(1, floor(fs[4] * frac + 0.5)), fs[5])
                end
            end
            local bal = a and a.balloon
            if bal and bal.untilT and bal.untilT < world.time then bal = nil end
            if bal and balloons < 12 then
                local kind = bal.kind or "speech"
                local BL = A.balloons
                local brec = BL and (BL[kind] or BL.speech)
                local bs = (brec and brec.sprite) or ("balloon:" .. kind)
                if not S[bs] then bs = "icon:bubble"; brec = nil end
                if S[bs] then
                    balloons = balloons + 1
                    local bx, by = it.x + 14, it.y - head - 8
                    n = ovEntry(n + 1, "balloon", bs, bx, by, nil)
                    local ic = bal.icon and A.icons and A.icons[bal.icon]
                    if ic and S[ic] then
                        if brec then
                            -- the icon centred in the balloon body (offset from the tail tip, logical px)
                            n = ovEntry(n + 1, "icon", ic, bx + (brec.ix or 0), by + (brec.iy or -14.5), brec.iconScale or 0.62)
                        else
                            local bsp = S[bs]
                            n = ovEntry(n + 1, "icon", ic, bx, by - (bsp and bsp[7] / SC() * 0.55 or 16), nil)
                        end
                    end
                end
            end
        end
    end
    for q = n + 1, #overlayOut do overlayOut[q][1] = nil end
    return n
end
R.overlayOut = overlayOut

-- Per-frame: people, vehicles and effects, placed between the statics.
function R.UpdateActors(world, selectedId)
    local cam = R.cam
    local zoom = cam.zoom
    local items = R.state.items
    local sbase = R.staticBase or (R.canvas:GetFrameLevel() + 2)
    local dyn = R.BuildActors(world, cam, R.state.objKeys)
    R.state.actors = dyn
    local nbump = R.PlaceDynamic(items, R.state.grid, dyn)
    -- statics bumped this frame (or restored) get their frame levels
    for n = 1, #items do
        local it = items[n]
        local want = min(9000, sbase + it.cur)
        if it.frame and it.appliedLevel ~= want then it.frame:SetFrameLevel(want); it.appliedLevel = want end
    end
    for n = 1, #dyn do
        local it = dyn[n]
        local f = dynFrames[n]
        if not f then
            f = CreateFrame("Frame", nil, R.canvas)
            f:SetAllPoints(R.canvas)
            f.tex = {}
            dynFrames[n] = f
        end
        f:Show()
        f:SetFrameLevel(min(9000, sbase + it.dl))
        fillFrame(f, it, zoom)
        it.frameLevel = it.dl
    end
    for n = #dyn + 1, #dynFrames do dynFrames[n]:Hide() end
    updateDoors(world, zoom)
    if SS.RenderFx and SS.RenderFx.AnimateWater and not R.Reduced() then SS.RenderFx.AnimateWater(R.state.water, zoom, setSprite) end
    -- selection marker and balloons (overlay frame, above everything)
    local no = R.OverlayEntries(world, dyn, selectedId)
    local shown = 0
    local markerShown, progShown = false, false
    local bt = R.balloonTex
    local xr = R.xrayTex
    local nx = 0
    for q = 1, no do
        local e = overlayOut[q]
        local what = e.what
        if what == "xray" and xr then
            nx = nx + 1
            local t = xr[nx]
            if not t then
                t = R.overlay:CreateTexture(nil, "OVERLAY", nil, 1); xr[nx] = t
                R.stats.allocated = (R.stats.allocated or 0) + 1
            end
            setSprite(t, e[1], zoom, e[2], e[3], e[5], e[6], e[7], e[8])
        elseif what == "marker" then
            setSprite(R.marker, e[1], zoom, e[2], e[3], 1, 1, 1, 1)
            markerShown = true
        elseif what == "progress" and R.progressTex then
            setSprite(R.progressTex, e[1], zoom, e[2], e[3], 1, 1, 1, 1)
            progShown = true
        elseif what == "progress_fill" and R.progressFill then
            setSprite(R.progressFill, e[1], zoom, e[2], e[3], 1, 1, 1, 1, e[9], e[10], e[11], e[12])
        elseif bt and what == "balloon" then
            shown = shown + 1
            local t = bt[shown]
            if not t then
                t = { bg = R.overlay:CreateTexture(nil, "OVERLAY", nil, 3), icon = R.overlay:CreateTexture(nil, "OVERLAY", nil, 4) }
                R.stats.allocated = (R.stats.allocated or 0) + 2
                bt[shown] = t
            end
            setSprite(t.bg, e[1], zoom, e[2], e[3], 1, 1, 1, 1)
            t.icon:Hide()
        elseif bt and what == "icon" and bt[shown] then
            setSprite(bt[shown].icon, e[1], zoom, e[2], e[3], 1, 1, 1, 1, nil, nil, nil, nil, e[4])
        end
    end
    hideBalloons(shown + 1)
    if xr then for q = nx + 1, #xr do xr[q]:Hide() end end
    if not markerShown and R.marker then R.marker:Hide() end
    if not progShown and R.progressTex then R.progressTex:Hide(); R.progressFill:Hide() end
    if R.bubble then R.bubble:Hide(); R.bubbleIcon:Hide() end
    R.stats.bumped = nbump
    R.stats.dynamic = #dyn
    -- ui-shell's /sidestreet perf: textures shown and textures created (brief 22)
    local dv = nx + shown * 2 + (markerShown and 1 or 0) + (progShown and 2 or 0)
    for n = 1, #dyn do dv = dv + (dyn[n].nl or 0) end
    R.stats.visibleDynamic = dv
    R.stats.visible = (R.stats.visibleStatic or 0) + dv
end

---------------------------------------------------------------------------------------------------
-- Offline draw list (docs/ART.md section 8.4): every texture the client shows for (world, cam), in
-- the client's exact draw order, without creating frames. The order is what Layout/UpdateActors
-- produce: the ground row frames (one per view diagonal, back to front; inside a row the
-- BACKGROUND then ARTWORK draw layers, sublevel, then creation order), then the static and dynamic
-- item frames by frame level (statics before dynamics at an equal level, then list order; inside a
-- frame the layers in index order), then the overlay (marker, balloons). Used by the offline
-- preview, the ground-truth comparison (tools/art/gt.py) and the tests. Entries:
-- { name, x, y, r, g, b, a, c0, c1, c2, c3, k, blend, kind =, ref =, level =, part = "ground" |
--   "item" | "overlay", layer = n, item = it }. Allocates (offline use only).
---------------------------------------------------------------------------------------------------
function R.DrawList(world, cam, selectedId)
    local out = {}
    local floors, items, objKeys, ground = R.BuildStatic(world, cam)
    R.state.floors, R.state.items, R.state.objKeys, R.state.ground = floors, items, objKeys, ground
    local rows, rowOf = {}, {}
    for _, e in ipairs(floors) do local r = e.row or 0; if not rowOf[r] then rowOf[r] = true; rows[#rows + 1] = r end end
    for _, e in ipairs(ground) do local r = e.row or 0; if not rowOf[r] then rowOf[r] = true; rows[#rows + 1] = r end end
    table.sort(rows)
    for q, r in ipairs(rows) do rowOf[r] = q end
    local g, seq = {}, 0
    for _, e in ipairs(floors) do
        if not e.pool and not e.pond then seq = seq + 1; g[#g + 1] = { e, 0, seq } end
    end
    for _, e in ipairs(ground) do seq = seq + 1; g[#g + 1] = { e, e.sub or 0, seq } end
    table.sort(g, function(a, b)
        local ra, rb = rowOf[a[1].row or 0], rowOf[b[1].row or 0]
        if ra ~= rb then return ra < rb end
        local la, lb = (a[2] >= 2) and 1 or 0, (b[2] >= 2) and 1 or 0
        if la ~= lb then return la < lb end
        local sa, sb = min(7, a[2]), min(7, b[2])
        if sa ~= sb then return sa < sb end
        return a[3] < b[3]
    end)
    for _, q in ipairs(g) do
        local e = q[1]
        local tn = e.tint or WHITE
        out[#out + 1] = { e.sprite, e.x, e.y, tn[1], tn[2], tn[3], e.alpha or 1, kind = e.pool and "pool" or "ground",
            ref = e.cell and (e.cell[1] .. "," .. e.cell[2]) or e.sprite, level = e.level or 0, part = "ground", item = e }
    end
    for n = 1, #items do items[n].cur = items[n].lvl * R.STRIDE end
    local dyn = R.BuildActors(world, cam, objKeys)
    R.state.actors = dyn
    R.PlaceDynamic(items, R.state.grid, dyn)
    updateDoors(world, cam.zoom or 1)
    local order = {}
    for n = 1, #items do order[#order + 1] = { items[n].cur, 0, n, items[n] } end
    for n = 1, #dyn do order[#order + 1] = { dyn[n].dl, 1, n, dyn[n] } end
    table.sort(order, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[3] < b[3]
    end)
    for _, q in ipairs(order) do
        local it = q[4]
        local L = it.layers
        for l = 1, (it.nl or #L) do
            local ly = L[l]
            if ly[1] then
                out[#out + 1] = { ly[1], ly[5] or it.x, ly[6] or it.y, ly[2] or 1, ly[3] or 1, ly[4] or 1, ly[7] or it.alpha or 1,
                    ly[8], ly[9], ly[10], ly[11], ly[12], ly[13], kx = ly[14], kind = it.kind, ref = it.ref, level = it.level or 0,
                    part = "item", layer = l, item = it, dynamic = q[2] == 1, shadow = (it.kind == "shadow") or (it.shadowLayer == l) }
            end
        end
    end
    local no = R.OverlayEntries(world, dyn, selectedId)
    for q = 1, no do
        local e = overlayOut[q]
        out[#out + 1] = { e[1], e[2], e[3], e[5], e[6], e[7], e[8], e[9], e[10], e[11], e[12], e[4], nil, kind = e.what, ref = e.what,
            level = 99, part = "overlay" }
    end
    return out
end

-- Cursor (screen) -> canvas pixel at zoom 1
function R.CursorToCanvas()
    local x, y = GetCursorPosition()
    local s = R.canvas:GetEffectiveScale()
    x, y = x / s, y / s
    local left, top = R.canvas:GetLeft(), R.canvas:GetTop()
    if not left then return end
    return (x - left) / R.cam.zoom, (top - y) / R.cam.zoom
end

---------------------------------------------------------------------------------------------------
-- Extension API used by other modules
---------------------------------------------------------------------------------------------------
-- Extra static draw items (build previews): fn(world, cam, items, floors, objKeys). Items:
-- { key, x, y, ref, kind, level, layers = { {sprite, r, g, b, x?, y?, alpha?} }, alpha?, box? }.
function R.RegisterStatic(fn) R.statics[#R.statics + 1] = fn end
-- Effects drawn every frame: fn(world, cam, out) appending { level, x, y, z (world tiles),
-- effect | fx = name, frame = n?, scale = s? } (see Render/Effects.lua).
function R.RegisterEffects(fn) R.effects[#R.effects + 1] = fn end
-- Placement ghost: { def, variant, x, y, f, level, valid = bool, blocked = { {i,j}... } } or nil.
function R.SetGhost(g) R.ghost = g; if SS.UI then SS.UI.dirty = true end end
-- Cell highlights for tools: list of { i, j, level, color = {r,g,b,a}, grid? } or nil.
function R.SetCellMarks(list) R.cellMarks = list; if SS.UI then SS.UI.dirty = true end end
-- Portrait from the person's actual look (skin, face, eyes, beard, hair style and colour, outfit
-- top, hat): the same tinted layers as the lot sprite. Uses the dedicated close-up portrait
-- frame (SS.Art.portrait.frames[age] = "<age code>:portrait:0:0", its square in
-- SS.Art.portrait.box[age]; docs/ART.md 7.7) when the manifest has it, else a head-and-shoulders
-- crop of the front idle frame. textures: an array of textures in one frame
-- of size x size px (UI.Kit.Portrait); unused ones are hidden. Returns true when drawn.
-- A pet (kind or look.species dog/cat) gets a head-and-chest crop of its own idle frame facing
-- the viewer, in its coat colours (ui-shell art request A8).
local portraitL, portraitProxy = {}, {}
local PORTRAIT_SKIP = { ["sh:"] = true, ["bo:"] = true, ["pr:"] = true }
local petPortraitProxy, petPortraitNames, petPortraitCols = {}, {}, {}
local function drawPetPortrait(textures, person, size)
    local A = SS.Art
    local P = petPortraitProxy
    P.look, P.kind, P.pose, P.walking, P.stride, P.act = person.look, person.kind, "idle", nil, 0, nil
    local k = (A.portrait and A.portrait.k) or 0
    local e = petSprites(P, k, 0)
    if not e then return false end
    local look = person.look or EMPTY
    local c1 = type(look.skin) == "table" and look.skin or PET_P
    local c2 = type(look.hair) == "table" and look.hair or PET_S
    local N, C = petPortraitNames, petPortraitCols
    N[1], N[2], N[3] = e.p or false, e.s or false, e.d or false
    C[1], C[2], C[3] = c1, c2, WHITE
    -- the union box of the layers, relative to the feet anchor (hi sprite px)
    local x0, y0, x1, y1
    for q = 1, 3 do
        local s = N[q] and A.sprites[N[q]]
        if s then
            local a0, b0 = -s[6], -s[7]
            x0, y0 = min(x0 or a0, a0), min(y0 or b0, b0)
            x1, y1 = max(x1 or a0 + s[4], a0 + s[4]), max(y1 or b0 + s[5], b0 + s[5])
        end
    end
    if not x0 then return false end
    -- a square from the top of the pet: the head and chest facing the viewer
    local side = min(x1 - x0, y1 - y0)
    local cx0 = (x0 + x1) / 2 - side / 2
    local cy0 = y0 - side * 0.04
    local cx1, cy1 = cx0 + side, cy0 + side
    local z, used = A.sheetSize, 0
    local kk = size / side
    for q = 1, 3 do
        local name = N[q]
        local s = name and A.sprites[name]
        if s and used < #textures then
            local sx0, sy0 = -s[6], -s[7]
            local ix0, iy0 = max(sx0, cx0), max(sy0, cy0)
            local ix1, iy1 = min(sx0 + s[4], cx1), min(sy0 + s[5], cy1)
            if ix1 > ix0 and iy1 > iy0 then
                used = used + 1
                local t = textures[used]
                R.SetTex(t, A.sheets[s[1]])
                local tx0, ty0 = s[2] + (ix0 - sx0), s[3] + (iy0 - sy0)
                t:SetTexCoord(tx0 / z, (tx0 + ix1 - ix0) / z, ty0 / z, (ty0 + iy1 - iy0) / z)
                t:SetSize(max(0.01, (ix1 - ix0) * kk), max(0.01, (iy1 - iy0) * kk))
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", t:GetParent(), "TOPLEFT", (ix0 - cx0) * kk, -(iy0 - cy0) * kk)
                local c = C[q]
                t:SetVertexColor(c[1] or 1, c[2] or 1, c[3] or 1, 1)
                if t.SetBlendMode and t.ssBlend ~= "BLEND" then t:SetBlendMode("BLEND"); t.ssBlend = "BLEND" end
                t:Show()
            end
        end
    end
    return used > 0
end
R.DrawPetPortrait = drawPetPortrait

function R.DrawPortrait(textures, person, size)
    if type(textures) ~= "table" then return false end
    for _, t in ipairs(textures) do t:Hide() end
    local A = SS.Art
    if not person or not A or not A.sprites then return false end
    local species = (type(person.look) == "table" and person.look.species) or person.kind
    if species == "dog" or species == "cat" then return drawPetPortrait(textures, person, size or 48) end
    size = size or 48
    local age = person.age or "adult"
    if not AGE_CODE[age] then age = "adult" end
    local code = AGE_CODE[age]
    local PT = A.portrait or {}
    local proxy = portraitProxy
    proxy.look, proxy.outfit, proxy.carry, proxy.act = person.look, person.outfit, nil, nil
    local dedicated = PT.frames and PT.frames[age]
    local fkey, crop
    if dedicated then
        fkey = dedicated
        crop = PT.box and PT.box[age]
    else
        local k = PT.k or 0
        fkey = fkeyOf(code, "idle", 0, k)
        local c = PT.crop and PT.crop[age]
        if c then
            crop = c
        else
            -- default: a square around the head, in hi sprite px relative to the feet anchor
            local sc = SC()
            local hgt = (HEIGHT[age] or 1.5) * 32 * sc
            local side = hgt * 0.42
            crop = { -side / 2, -hgt - side * 0.12, side / 2, -hgt + side * 0.88 }
        end
    end
    local n = personLayers(portraitL, proxy, fkey, age, dedicated and "portrait" or "idle", 1, 1, 1, nil)
    local z = A.sheetSize
    local used = 0
    for q = 1, n do
        local L = portraitL[q]
        local name = L[1]
        local fam = name:match(":([a-z]+:)[^:]*$")
        local s = A.sprites[name]
        if s and not (fam and PORTRAIT_SKIP[fam]) and used < #textures then
            local x0, y0, x1, y1 = -s[6], -s[7], -s[6] + s[4], -s[7] + s[5]
            local cx0, cy0, cx1, cy1
            if crop then cx0, cy0, cx1, cy1 = crop[1], crop[2], crop[3], crop[4]
            else
                -- the dedicated frame is a square canvas with its anchor at the bottom centre
                local side = (PT.side and PT.side[age]) or PT.size or 128
                cx0, cy0, cx1, cy1 = -side / 2, -side, side / 2, 0
            end
            local ix0, iy0, ix1, iy1 = max(x0, cx0), max(y0, cy0), min(x1, cx1), min(y1, cy1)
            if ix1 > ix0 and iy1 > iy0 then
                used = used + 1
                local t = textures[used]
                local k = size / (cx1 - cx0)
                R.SetTex(t, A.sheets[s[1]])
                local tx0, ty0 = s[2] + (ix0 - x0), s[3] + (iy0 - y0)
                t:SetTexCoord(tx0 / z, (tx0 + ix1 - ix0) / z, ty0 / z, (ty0 + iy1 - iy0) / z)
                t:SetSize(max(0.01, (ix1 - ix0) * k), max(0.01, (iy1 - iy0) * k))
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", t:GetParent(), "TOPLEFT", (ix0 - cx0) * k, -(iy0 - cy0) * k)
                t:SetVertexColor(L[2] or 1, L[3] or 1, L[4] or 1, 1)
                if t.SetBlendMode and t.ssBlend ~= "BLEND" then t:SetBlendMode("BLEND"); t.ssBlend = "BLEND" end
                t:Show()
            end
        end
    end
    return used > 0
end

-- Screen position (canvas-relative, zoom applied) of an actor's head, or nil; third value: the
-- frame the position is relative to.
function R.ActorScreenPos(actorId)
    local list = R.state.actors
    if not list then return nil end
    for n = 1, #list do
        local it = list[n]
        if it.kind == "actor" and it.ref == actorId then
            local w = SS.Sim and SS.Sim.world
            local a = w and w.actors and w.actors[actorId]
            local head = (a and (((a.kind or "human") ~= "human") and 0.7 or HEIGHT[a.age or "adult"]) or 1.5) * 32
            return it.x * R.cam.zoom, (it.y - head) * R.cam.zoom, R.canvas
        end
    end
end
