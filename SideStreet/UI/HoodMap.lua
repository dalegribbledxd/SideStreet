-- SideStreet neighbourhood map scene: the composed isometric view of Linden Hollow.
-- Pure Lua draw lists (tested offline) plus a pooled-texture painter for the client.
--
--   * Ground, streets, sidewalks, verges, crossings and zones are merged into square blocks and
--     drawn with map tiles (SS.Art "map:<kind>" when the art module ships them, else tinted floor
--     tiles). Scenery trees and a few landmarks stand beyond the lots.
--   * Every lot shows its own exterior, generated from its saved data: a cached simplified draw
--     list built by SS.Render.BuildStatic on a temporary session (HoodLots.WithLot) with a "roof"
--     camera, filtered to what shows from outside (exterior walls, doors, windows, fences, garden
--     objects, trees, pool, paths), plus the roof. When the renderer draws roof pieces itself
--     (items of kind "roof") those are used; otherwise a stepped roof is generated from the
--     enclosed top-story footprint, in the lot's roof style and colour.
--   * The selected lot can show a roof-cutaway preview (walls cut, simplified furnished interior).
--   * Cache key: lot.version, a content signature (so an edit that forgot to bump the version is
--     still seen), map rotation, quality and preview level. Only visible lots are composed.
--   * Picking works on the saved geometry (per-cell heights), so removing a roof in the cutaway
--     preview never breaks hit-testing.
-- Owner: hood module (docs/modules/hood.md).
local _, SS = ...
local G = SS.Grid
local HD, H, HL = SS.HoodData, SS.Hood, SS.HoodLots
local M = SS.HoodMap or {}
SS.HoodMap = M

M.MARGIN, M.TOP = 24, 160      -- canvas margins at zoom 1 (TOP leaves room for tall things at the back)
M.MAXK = 8                     -- largest merged ground block (cells; larger blocks blur the tile texture)
M.RISE = 0.5                   -- fallback roof: tiles of rise per step (matches SS.Roof.RISE)
M.MAX_STEPS = 6                -- fallback roof: steps before the roof levels off
M.NEAR_ZOOM = 0.24             -- at or above: sidewalks, lane markings and full tree detail
M.MEDIUM_ZOOM = 0.3            -- at or above: lots use "medium" quality (all garden objects)
M.SLOTS = 64                   -- textures per painter frame (4 draw layers x 16 sublevels)
M.PICK_ZMAX, M.PICK_STEP = 9, 0.25

local W = SS.World
local LEVELS = function() return (W and W.LEVELS) or 2 end
local STORY = function() return (W and W.STORY) or 2.25 end

local function sortedKeys(t)
    local ks = {}
    for k in pairs(t or {}) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
    return ks
end

-- Sorted keys of `t`, cached in `c` (a table the caller keeps): rebuilt only when the key set
-- changed (checked by count and membership, without allocating). For the per-pick and
-- per-compose lot lists.
local function idLess(a, b) return tostring(a) < tostring(b) end
local function cachedIds(t, c)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    local list = c.list
    local ok = c.t == t and c.n == n and list ~= nil
    if ok then for i = 1, #list do if t[list[i]] == nil then ok = false; break end end end
    if not ok then
        list = list or {}
        for i = #list, 1, -1 do list[i] = nil end
        for k in pairs(t) do list[#list + 1] = k end
        table.sort(list, idLess)
        c.t, c.n, c.list = t, n, list
    end
    return list
end
M.CachedIds = cachedIds
local lotIdsC, placeIdsC = {}, {}

-- Numeric fingerprint of the map placements (count and a position checksum), no allocation.
local function layoutKey(root)
    local n, acc = 0, 0
    for _, p in pairs(root.hood.layout.lots) do
        n = n + 1
        acc = (acc + (p.x + 3) * 7919 + (p.y + 3) * 104729 + p.w * 31 + p.h * 17 + (p.rot or 0) * 3) % 2147483647
    end
    return n, acc
end
M.LayoutKey = layoutKey

local function spr(name) local A = SS.Art; return name and A and A.sprites and A.sprites[name] end
local function artScale() return (SS.Art and SS.Art.scale) or 1 end
M.Sprite = spr

---------------------------------------------------------------------------
-- View: rotation r (0..3) of the whole map, zoom (canvas pixels per logical pixel).
---------------------------------------------------------------------------
function M.NewView(rot, zoom)
    local MW, MH = HD.map.w, HD.map.h
    rot = (rot or 0) % 4
    local vW, vH = G.viewSize(rot, MW, MH)
    return { r = rot, zoom = zoom or HD.Tuning.zooms[HD.Tuning.defaultZoom], MW = MW, MH = MH, vW = vW, vH = vH,
        ox = vH * 32 + M.MARGIN, oy = M.TOP }
end

function M.CanvasSize(view) return (view.vW + view.vH) * 32 + 2 * M.MARGIN, (view.vW + view.vH) * 16 + M.TOP + M.MARGIN end
function M.ViewToCanvas(view, U, V, z) return (U - V) * 32 + view.ox, (U + V) * 16 - (z or 0) * 32 + view.oy end
function M.MapToCanvas(view, mx, my, z)
    local U, V = G.vpos(mx, my, view.r, view.MW, view.MH)
    return M.ViewToCanvas(view, U, V, z)
end
-- Canvas pixel (zoom 1) on the plane of height z -> continuous map position.
function M.CanvasToMap(view, px, py, z)
    local a = (px - view.ox) / 32
    local b = (py - view.oy + (z or 0) * 32) / 16
    return G.wpos((a + b) / 2, (b - a) / 2, view.r, view.MW, view.MH)
end
-- Painter's depth of a continuous map position (larger = nearer the viewer).
function M.Depth(view, mx, my)
    local U, V = G.vpos(mx, my, view.r, view.MW, view.MH)
    return U + V
end

-- Zoom-1 canvas rectangle visible in a viewport of vpW x vpH pixels (canvas centred + pan).
function M.VisibleRect(view, vpW, vpH, panX, panY, margin)
    local cw, ch = M.CanvasSize(view)
    local z = view.zoom
    margin = margin or 64
    local cx = cw * z / 2 - (panX or 0)
    local cy = ch * z / 2 + (panY or 0)
    return { x0 = (cx - vpW / 2) / z - margin, x1 = (cx + vpW / 2) / z + margin,
        y0 = (cy - vpH / 2) / z - margin, y1 = (cy + vpH / 2) / z + margin }
end

local function boxHits(b, r) return not r or (b and b.x1 >= r.x0 and b.x0 <= r.x1 and b.y1 >= r.y0 and b.y0 <= r.y1) end
M.BoxHits = boxHits

---------------------------------------------------------------------------
-- Primitives: { s = sprite, x, y (anchor, zoom-1 canvas px), k (scale) or kw/kh, r, g, b, a,
--               d (depth), lv (level), o (order within its source), lot, kind }
---------------------------------------------------------------------------
local function prim(list, s, x, y, k, r, g, b, a, d, lv, kind)
    local p = { s = s, x = x, y = y, k = k or 1, r = r or 1, g = g or 1, b = b or 1, a = a or 1, d = d or 0, lv = lv or 0,
        kind = kind, o = #list + 1 }
    list[#list + 1] = p
    return p
end
M.Prim = prim

-- Screen box of a primitive (zoom 1).
local function primBox(p, box)
    local s = spr(p.s)
    if not s then return box end
    local sc = artScale()
    local kw, kh = p.kw or p.k, p.kh or p.k
    local x0 = p.x - s[6] / sc * kw
    local y0 = p.y - s[7] / sc * kh
    local x1, y1 = x0 + s[4] / sc * kw, y0 + s[5] / sc * kh
    if not box then return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 } end
    if x0 < box.x0 then box.x0 = x0 end
    if y0 < box.y0 then box.y0 = y0 end
    if x1 > box.x1 then box.x1 = x1 end
    if y1 > box.y1 then box.y1 = y1 end
    return box
end
M.PrimBox = primBox

-- Scale that makes a diamond floor sprite cover n x n cells.
local function diamondScale(sprite, n)
    local s = spr(sprite)
    if not s then return n end
    return n * 64 * artScale() / s[4]
end

---------------------------------------------------------------------------
-- Sprites for ground, floors, roofs and scenery (art manifest first, then fallbacks)
---------------------------------------------------------------------------
local FLOOR_GUESS = { { "grass", "grass" }, { "lawn", "grass" }, { "wood", "wood" }, { "deck", "wood" }, { "carpet", "carpet" },
    { "rug", "carpet" }, { "tile", "tile" }, { "marble", "tile" }, { "lino", "tile" }, { "path", "path" }, { "stone", "path" },
    { "paving", "path" }, { "patio", "path" }, { "gravel", "path" }, { "brick", "path" }, { "concrete", "path" },
    { "sand", "path" }, { "dirt", "path" } }

-- A plain tile sprite for a base floor name ("grass", "path", "tile", "wood", "carpet"): the art
-- manifest's floor list when it has one (0.1 art, or the art module's compatibility table), else
-- the flat terrain tile for grass, else the next base floor that exists. The art module's
-- compatibility table has no "grass" or "path" floors, so this never assumes one. Cached per
-- manifest; nil only when the manifest has no floor or terrain tile at all (nothing is drawn then).
local BASE_CHAIN = {
    grass = { "grass", "tile", "carpet", "wood" }, path = { "path", "tile", "carpet", "wood", "grass" },
    tile = { "tile", "path", "carpet", "wood", "grass" }, wood = { "wood", "tile", "carpet", "grass" },
    carpet = { "carpet", "tile", "wood", "grass" },
}
local BASE_TERRAIN = { grass = "terrain:grass:0000:00" }
local baseCache, baseFor = {}, nil
local function baseTry(A, n, strict)
    local ok, l = pcall(function() return A.floors and A.floors[n] end)
    if ok and type(l) == "table" and l[1] and (not strict or spr(l[1])) then return l[1] end
    local t = BASE_TERRAIN[n]
    if t and spr(t) then return t end
end
function M.BaseFloor(name)
    local A = SS.Art
    if not A then return nil end
    if baseFor ~= A.sprites then baseCache, baseFor = {}, A.sprites end
    local hit = baseCache[name]
    if hit ~= nil then return hit or nil end
    local s
    local chain = BASE_CHAIN[name] or BASE_CHAIN.tile
    for pass = 1, 2 do
        s = baseTry(A, name, pass == 1)
        if not s then for _, n in ipairs(chain) do s = baseTry(A, n, pass == 1); if s then break end end end
        if s then break end
    end
    baseCache[name] = s or false
    return s
end

-- Floor finish -> sprite, r, g, b.
function M.FloorSprite(fid)
    local A = SS.Art
    local list = A.floors[fid]
    local fin = SS.Finishes and SS.Finishes.floors and SS.Finishes.floors[fid]
    if not list and fin and fin.art then list = A.floors[fin.art] end
    if not list then
        local s = tostring(fid)
        for _, p in ipairs(FLOOR_GUESS) do if s:find(p[1], 1, true) and A.floors[p[2]] then list = A.floors[p[2]]; break end end
    end
    local c = fin and type(fin.tint) == "table" and fin.tint or nil
    return (list and list[1]) or M.BaseFloor("grass"), c and c[1] or 1, c and c[2] or 1, c and c[3] or 1
end

-- Ground kinds: "map:<kind>" art when present, else a floor tile times a tint.
HD.GroundArt = HD.GroundArt or {
    lawn = { "grass", { 0.86, 0.93, 0.8 } }, verge = { "grass", { 0.8, 0.9, 0.74 } }, woods = { "grass", { 0.62, 0.8, 0.62 } },
    orchard = { "grass", { 0.86, 0.96, 0.7 } }, green = { "grass", { 0.96, 1, 0.92 } },
    meadow = { "grass", { 1, 1, 0.62 } }, field = { "grass", { 1, 0.84, 0.46 } }, pond = { "path", { 0.42, 0.64, 0.96 } },
    road = { "path", { 0.5, 0.5, 0.54 } }, sidewalk = { "path", { 0.98, 0.96, 0.92 } }, crossing = { "path", { 0.82, 0.82, 0.84 } },
    marking = { "path", { 1, 0.92, 0.5 } }, pool = { "path", { 0.4, 0.7, 1 } },
}
-- The art module's map tiles come in variants ("<name>", "<name>:1", "<name>:2"); a cell picks one
-- from its position, so the same place always shows the same tile.
local function variant(own, vx, vy)
    if not vx then return own end
    local v = (vx * 7 + vy * 13) % 3
    if v > 0 and spr(own .. ":" .. v) then return own .. ":" .. v end
    return own
end
M.Variant = variant

function M.GroundSprite(kind, vx, vy)
    local own = "map:" .. kind
    if spr(own) then return variant(own, vx, vy), 1, 1, 1 end
    local g = HD.GroundArt[kind] or HD.GroundArt.lawn
    return M.BaseFloor(g[1]), g[2][1], g[2][2], g[2][3]
end

local function roofRGB(lot)
    local c = lot.roof and lot.roof.color
    if type(c) == "table" and type(c[1]) == "number" then return c end
    if SS.Build and SS.Build.ROOF_COLORS then
        for _, e in ipairs(SS.Build.ROOF_COLORS) do if e.id == c then return e.rgb end end
    end
    return HD.RoofColor[c] or HD.RoofColor.terracotta
end
M.RoofRGB = roofRGB

-- The map roof texture for a material: hood's own names (shingle, slate, clay, metal), or a
-- catalogue roof finish ("roof_asphalt") through its pattern (SS.Finishes.roofs[id].look.pattern).
local function roofMaterial(m)
    if type(m) ~= "string" then return nil end
    local F = SS.Finishes
    local rf = F and type(F.roofs) == "table" and F.roofs[m]
    local pat = type(rf) == "table" and type(rf.look) == "table" and rf.look.pattern
    if type(pat) == "string" then return pat end
    return (m:gsub("^roof_", ""))
end
M.RoofMaterial = roofMaterial

local function roofSprite(lot)
    local m = lot.roof and lot.roof.material
    if m and spr("map:roof:" .. m) then return "map:roof:" .. m end
    local pat = roofMaterial(m)
    if pat and spr("map:roof:" .. pat) then return "map:roof:" .. pat end
    if spr("map:roof") then return "map:roof" end
    return M.BaseFloor("tile")
end

-- The build module's roof geometry for a saved lot (SS.Roof.PiecesForLot, cached by build per
-- lot.version): one piece per roofed cell with its height, corner offsets and resolved colour, so
-- per-building overrides and catalogue colours show on the map as they do on the lot. Returns
-- the pieces with their top height (tiles) filled in, or nil (no build module, or no roof).
M.roofSigs = M.roofSigs or setmetatable({}, { __mode = "k" })
-- Build caches roof pieces by lot.version; an edit that forgot to bump it (a recolour written
-- directly) still shows, because our content signature drops build's entry when the lot changed.
-- Run before anything reads build's pieces: M.RoofPieces and the renderer (BuildStatic).
function M.SyncRoofCache(lot)
    local R = SS.Roof
    if not (R and lot) then return end
    local sig = M.Signature(lot)
    if M.roofSigs[lot] ~= sig then
        if type(R.Invalidate) == "function" then pcall(R.Invalidate, lot) end
        M.roofSigs[lot] = sig
    end
end

function M.RoofPieces(lot)
    local R = SS.Roof
    if not (R and type(R.PiecesForLot) == "function") then return nil end
    M.SyncRoofCache(lot)
    local ok, data = pcall(R.PiecesForLot, lot)
    if not ok or type(data) ~= "table" or type(data.pieces) ~= "table" or #data.pieces == 0 then return nil end
    local rise = R.RISE or M.RISE
    local out = {}
    for _, p in ipairs(data.pieces) do
        if type(p) == "table" and type(p.i) == "number" and type(p.j) == "number" and type(p.z) == "number"
            and p.i >= 0 and p.j >= 0 and p.i < lot.w and p.j < lot.h then
            local c, sum, lo, hi = type(p.c) == "table" and p.c or { 0, 0, 0, 0 }, 0, 1e9, -1e9
            for n = 1, 4 do
                local v = tonumber(c[n]) or 0
                sum = sum + v
                if v < lo then lo = v end
                if v > hi then hi = v end
            end
            out[#out + 1] = { i = p.i, j = p.j, level = p.level or 0, section = p.section or p.level or 0,
                top = p.z + sum / 4 * rise, peak = p.z + hi * rise, sloped = hi > lo,
                rgb = type(p.rgb) == "table" and type(p.rgb[1]) == "number" and p.rgb or nil }
        end
    end
    return #out > 0 and out or nil
end

---------------------------------------------------------------------------
-- Ground: kinds per map cell (lots excluded), merged into square blocks per level of detail.
---------------------------------------------------------------------------
function M.GroundKind(mx, my, far)
    local g = H.GroundAt(mx, my)
    if g == "road" or g == "sidewalk" then
        if far then return "road" end
        if g == "road" then
            for _, s in ipairs(HD.map.streets) do
                local inside = mx >= s.x0 and mx <= s.x1 and my >= s.y0 and my <= s.y1
                if not inside and mx >= s.x0 - 1 and mx <= s.x1 + 1 and my >= s.y0 - 1 and my <= s.y1 + 1 then return "crossing" end
            end
        end
        return g
    end
    if g == "lawn" and not far then
        for d = 0, 3 do
            local dv = G.DIRS[d]
            if H.StreetAt(mx + dv[1], my + dv[2]) then return "verge" end
        end
    end
    return g
end

local function layoutSig(root)
    local parts = {}
    for _, id in ipairs(sortedKeys(root.hood.layout.lots)) do
        local p = root.hood.layout.lots[id]
        parts[#parts + 1] = id .. ":" .. p.x .. "," .. p.y .. "," .. p.w .. "," .. p.h
    end
    return table.concat(parts, ";")
end
M.LayoutSig = layoutSig

M.ground = M.ground or {}
function M.GroundBlocks(root, far)
    local n, acc = layoutKey(root)
    local c = M.ground[far and "far" or "near"]
    if c and c.n == n and c.acc == acc then return c.blocks end
    local MW, MH = HD.map.w, HD.map.h
    local skip = {}
    for _, pl in pairs(root.hood.layout.lots) do
        for y = pl.y, pl.y + pl.h - 1 do for x = pl.x, pl.x + pl.w - 1 do skip[y * MW + x + 1] = true end end
    end
    local kind = {}
    for my = 0, MH - 1 do
        for mx = 0, MW - 1 do
            local k = my * MW + mx + 1
            kind[k] = (not skip[k]) and M.GroundKind(mx, my, far) or false
        end
    end
    local covered, blocks = {}, {}
    for my = 0, MH - 1 do
        for mx = 0, MW - 1 do
            local k0 = my * MW + mx + 1
            local g = kind[k0]
            if g and not covered[k0] then
                local n = 1
                while n < M.MAXK and mx + n < MW and my + n < MH do
                    local ok = true
                    for t = 0, n do
                        local a = (my + n) * MW + mx + t + 1
                        local b = (my + t) * MW + mx + n + 1
                        if kind[a] ~= g or covered[a] or kind[b] ~= g or covered[b] then ok = false; break end
                    end
                    if not ok then break end
                    n = n + 1
                end
                for y = my, my + n - 1 do for x = mx, mx + n - 1 do covered[y * MW + x + 1] = true end end
                blocks[#blocks + 1] = { x = mx, y = my, n = n, kind = g }
            end
        end
    end
    M.ground[far and "far" or "near"] = { n = n, acc = acc, blocks = blocks }
    return blocks
end

local function groundPrims(root, view, far, out, rect)
    for _, b in ipairs(M.GroundBlocks(root, far)) do
        local s, r, g, bb = M.GroundSprite(b.kind, b.x, b.y)
        local x, y = M.MapToCanvas(view, b.x + b.n / 2, b.y + b.n / 2, 0)
        local half = b.n * 32
        if not rect or (x + half >= rect.x0 and x - half <= rect.x1 and y + half / 2 >= rect.y0 and y - half / 2 <= rect.y1) then
            local p = prim(out, s, x, y, diamondScale(s, b.n), r, g, bb, 1, 0, 0, "ground")
            p.ground = b.kind
            p.fx0, p.fy0, p.fx1, p.fy1 = x - half, y - half / 2, x + half, y + half / 2
        end
    end
end

-- Lane markings (dashes on the centre line) and the street's own tiles: near detail only.
local function streetMarks(view, out, rect)
    local s, r, g, b = M.GroundSprite("marking")
    for _, st in ipairs(HD.map.streets) do
        local mid
        if st.axis == "h" then
            mid = (st.y0 + st.y1 + 1) / 2
            for x = st.x0 + 1, st.x1 - 1, 3 do
                if not H.GroundAt(x, math.floor(mid)) or H.GroundAt(x, math.floor(mid)) == "road" then
                    local cross = false
                    for _, o in ipairs(HD.map.streets) do
                        if o ~= st and x >= o.x0 - 1 and x <= o.x1 + 1 and mid >= o.y0 and mid <= o.y1 + 1 then cross = true end
                    end
                    if not cross then
                        local px, py = M.MapToCanvas(view, x + 0.5, mid, 0.01)
                        if not rect or (px >= rect.x0 and px <= rect.x1 and py >= rect.y0 and py <= rect.y1) then
                            local p = prim(out, s, px, py, diamondScale(s, 0.35), r, g, b, 1, 0, 0, "marking")
                            p.fx0, p.fy0, p.fx1, p.fy1 = px, py, px, py
                        end
                    end
                end
            end
        else
            mid = (st.x0 + st.x1 + 1) / 2
            for y = st.y0 + 1, st.y1 - 1, 3 do
                local cross = false
                for _, o in ipairs(HD.map.streets) do
                    if o ~= st and y >= o.y0 - 1 and y <= o.y1 + 1 and mid >= o.x0 and mid <= o.x1 + 1 then cross = true end
                end
                if not cross then
                    local px, py = M.MapToCanvas(view, mid, y + 0.5, 0.01)
                    if not rect or (px >= rect.x0 and px <= rect.x1 and py >= rect.y0 and py <= rect.y1) then
                        local p = prim(out, s, px, py, diamondScale(s, 0.35), r, g, b, 1, 0, 0, "marking")
                        p.fx0, p.fy0, p.fx1, p.fy1 = px, py, px, py
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Scenery: trees and landmarks (static, not simulated).
---------------------------------------------------------------------------
local TREE_TINT = {
    broad = { { 0.42, 0.62, 0.34 }, { 0.5, 0.7, 0.38 }, { 0.58, 0.78, 0.42 } },
    pine = { { 0.3, 0.48, 0.34 }, { 0.36, 0.56, 0.38 }, { 0.42, 0.62, 0.42 } },
    fruit = { { 0.5, 0.66, 0.34 }, { 0.6, 0.74, 0.4 }, { 0.86, 0.5, 0.42 } },
    verge = { { 0.44, 0.64, 0.36 }, { 0.52, 0.72, 0.4 }, { 0.6, 0.8, 0.46 } },
    shrub = { { 0.4, 0.6, 0.34 }, { 0.48, 0.68, 0.38 } },
    flowers = { { 0.9, 0.56, 0.66 }, { 0.98, 0.86, 0.46 } },
}
-- Appends a tree standing at map position (mx, my) to `out` (depth d). kind: broad|pine|fruit|verge|shrub|flowers.
function M.TreePrims(out, view, mx, my, kind, size, d, far, zBase)
    zBase = zBase or 0
    size = size or 1
    local own = "map:tree:" .. kind
    if spr(own) then
        own = variant(own, math.floor(mx), math.floor(my))
        local x, y = M.MapToCanvas(view, mx, my, zBase)
        prim(out, own, x, y, size, 1, 1, 1, 1, d, 0, "tree")
        return
    end
    local grass = M.BaseFloor("grass")
    local tints = TREE_TINT[kind] or TREE_TINT.broad
    if kind == "shrub" or kind == "flowers" then
        local x, y = M.MapToCanvas(view, mx, my, zBase + 0.18 * size)
        local t = tints[1]
        prim(out, grass, x, y, diamondScale(grass, 0.8 * size), t[1], t[2], t[3], 1, d, 0, "tree")
        if not far then
            local t2 = tints[2]
            x, y = M.MapToCanvas(view, mx, my, zBase + 0.34 * size)
            prim(out, grass, x, y, diamondScale(grass, 0.45 * size), t2[1], t2[2], t2[3], 1, d, 0, "tree")
        end
        return
    end
    local white = SS.Art.icons and SS.Art.icons.white
    if white and spr(white) and not far then
        local x, y = M.MapToCanvas(view, mx, my, zBase + 0.35 * size)
        local p = prim(out, white, x, y, 1, 0.42, 0.3, 0.2, 1, d, 0, "tree")
        p.kw, p.kh = 0.7 * size, 2.6 * size
    end
    local layers
    if kind == "pine" then
        layers = { { 0.8, 1.3 }, { 1.35, 0.95 }, { 1.85, 0.6 }, { 2.2, 0.28 } }
    else
        layers = { { 1.0, 1.3 }, { 1.35, 1.45 }, { 1.7, 1.05 }, { 1.95, 0.5 } }
    end
    for n, L in ipairs(layers) do
        if not far or n == 1 or n == 3 then
            local t = tints[math.min(#tints, math.ceil(n * #tints / #layers))]
            local x, y = M.MapToCanvas(view, mx, my, zBase + L[1] * size)
            prim(out, grass, x, y, diamondScale(grass, L[2] * size), t[1], t[2], t[3], 1, d, 0, "tree")
        end
    end
end

-- A solid block (stacked slabs) on map cells [x0, x0+w) x [y0, y0+h) from z0 to z1, optional roof.
function M.BlockPrims(out, view, x0, y0, w, h, z0, z1, rgb, roof, d)
    local tile = M.BaseFloor("tile")
    local squares = {}
    local cov = {}
    for y = y0, y0 + h - 1 do
        for x = x0, x0 + w - 1 do
            if not cov[y * 1000 + x] then
                local n = 1
                while x + n < x0 + w and y + n < y0 + h do n = n + 1 end
                n = math.min(n, x0 + w - x, y0 + h - y)
                for yy = y, y + n - 1 do for xx = x, x + n - 1 do cov[yy * 1000 + xx] = true end end
                squares[#squares + 1] = { x, y, n }
            end
        end
    end
    local step = 0.25
    local z = z0
    while z <= z1 + 1e-6 do
        local f = 0.62 + 0.38 * ((z - z0) / math.max(0.01, z1 - z0))
        for _, sq in ipairs(squares) do
            local px, py = M.MapToCanvas(view, sq[1] + sq[3] / 2, sq[2] + sq[3] / 2, z)
            prim(out, tile, px, py, diamondScale(tile, sq[3]), rgb[1] * f, rgb[2] * f, rgb[3] * f, 1, d, 0, "landmark")
        end
        z = z + step
    end
    if roof then
        local steps = math.floor(math.min(w, h) / 2 + 0.5)
        for n = 1, steps do
            local f = 0.72 + 0.28 * n / steps
            local ix, iy, iw, ih = x0 + n - 1, y0 + n - 1, w - 2 * (n - 1), h - 2 * (n - 1)
            if roof.style == "gable" then
                if w >= h then ix, iw = x0, w else iy, ih = y0, h end
            end
            if iw <= 0 or ih <= 0 then break end
            local zz = z1 + (n - 0.5) * M.RISE
            local sub = {}
            M.Squares(ix, iy, iw, ih, sub)
            for _, sq in ipairs(sub) do
                local px, py = M.MapToCanvas(view, sq[1] + sq[3] / 2, sq[2] + sq[3] / 2, zz)
                prim(out, tile, px, py, diamondScale(tile, sq[3]), roof.rgb[1] * f, roof.rgb[2] * f, roof.rgb[3] * f, 1, d, 0, "landmark")
            end
        end
    end
end

-- Greedy square cover of a rectangle: appends { x, y, n } squares.
function M.Squares(x0, y0, w, h, out)
    out = out or {}
    local cov = {}
    for y = y0, y0 + h - 1 do
        for x = x0, x0 + w - 1 do
            if not cov[(y - y0) * 4096 + (x - x0)] then
                local n = math.min(x0 + w - x, y0 + h - y)
                -- shrink until the square is free
                local ok = false
                while n > 1 and not ok do
                    ok = true
                    for yy = y, y + n - 1 do
                        for xx = x, x + n - 1 do if cov[(yy - y0) * 4096 + (xx - x0)] then ok = false end end
                    end
                    if not ok then n = n - 1 end
                end
                for yy = y, y + n - 1 do for xx = x, x + n - 1 do cov[(yy - y0) * 4096 + (xx - x0)] = true end end
                out[#out + 1] = { x, y, n }
            end
        end
    end
    return out
end

local LANDMARK = {
    water_tower = function(out, view, e, d)
        local legs = { 0.6, 0.6, 0.6 }
        M.BlockPrims(out, view, e.x, e.y, 1, 1, 0, 3.2, legs, nil, d)
        M.BlockPrims(out, view, e.x - 1, e.y - 1, 3, 3, 3.4, 4.6, { 0.72, 0.78, 0.82 }, { style = "hip", rgb = { 0.5, 0.56, 0.6 } }, d)
    end,
    barn = function(out, view, e, d)
        M.BlockPrims(out, view, e.x - 2, e.y - 1, 5, 4, 0, 1.75, { 0.66, 0.24, 0.2 }, { style = "gable", rgb = { 0.36, 0.34, 0.32 } }, d)
    end,
    bus_stop = function(out, view, e, d)
        M.BlockPrims(out, view, e.x, e.y, 2, 1, 0, 1.0, { 0.5, 0.62, 0.7 }, { style = "flat", rgb = { 0.3, 0.4, 0.46 } }, d)
    end,
    footbridge = function(out, view, e, d)
        local wood = M.BaseFloor("wood")
        for n = -2, 2 do
            local px, py = M.MapToCanvas(view, e.x + n + 0.5, e.y + 0.5, 0.15)
            prim(out, wood, px, py, diamondScale(wood, 1), 0.86, 0.72, 0.56, 1, d, 0, "landmark")
        end
    end,
    bench = function(out, view, e, d)
        M.BlockPrims(out, view, e.x, e.y, 1, 1, 0, 0.3, { 0.56, 0.4, 0.26 }, nil, d)
    end,
}

local function sceneryPrims(view, out, far, rect)
    for _, t in ipairs(H.SceneryTrees()) do
        local mx, my = t.x + 0.5, t.y + 0.5
        local px, py = M.MapToCanvas(view, mx, my, 0)
        if not rect or (px >= rect.x0 - 80 and px <= rect.x1 + 80 and py >= rect.y0 - 20 and py <= rect.y1 + 120) then
            local first = #out + 1
            M.TreePrims(out, view, mx, my, t.kind, t.s or 1, M.Depth(view, mx, my), far)
            for n = first, #out do local p = out[n]; p.fx0, p.fy0, p.fx1, p.fy1 = px - 80, py - 120, px + 80, py + 20 end
        end
    end
    for _, e in ipairs(HD.map.landmarks or {}) do
        local f = LANDMARK[e.kind]
        local mx, my = e.x + 0.5, e.y + 0.5
        local px, py = M.MapToCanvas(view, mx, my, 0)
        -- drawn art per view rotation (map:landmark:<kind> in rotation 0, :r1-:r3 in the others);
        -- a rotation without art uses the block model
        local own = "map:landmark:" .. tostring(e.kind) .. ((view.r ~= 0) and (":r" .. view.r) or "")
        if (f or spr(own)) and (not rect or (px >= rect.x0 - 120 and px <= rect.x1 + 120 and py >= rect.y0 - 40 and py <= rect.y1 + 200)) then
            local first = #out + 1
            if spr(own) then
                -- drawn landmark art (docs/art_requests/hood.md), anchored at its base cell
                prim(out, own, px, py, 1, 1, 1, 1, 1, M.Depth(view, mx, my) + 1, 0, "landmark")
            else
                local list = {}
                f(list, view, e, M.Depth(view, mx, my) + 1)
                for _, p in ipairs(list) do p.o = #out + 1; out[#out + 1] = p end
            end
            for n = first, #out do local p = out[n]; p.fx0, p.fy0, p.fx1, p.fy1 = px - 120, py - 200, px + 120, py + 40 end
        end
    end
end

-- The whole map's static scenery for a view rotation and detail level (ground blocks, lane
-- markings, trees, landmarks) as primitives, built once and kept until the placements, the art
-- or its scale change. Compose only picks the ones inside the visible rectangle.
M.static = M.static or {}
function M.StaticPrims(root, view, far)
    local n, acc = layoutKey(root)
    local slot = view.r * 2 + (far and 2 or 1)
    local c = M.static[slot]
    local art, scale = SS.Art, artScale()
    if c and c.n == n and c.acc == acc and c.art == art and c.scale == scale and c.sprites == (art and art.sprites) then return c end
    c = { n = n, acc = acc, art = art, scale = scale, sprites = art and art.sprites, flats = {}, items = {} }
    groundPrims(root, view, far, c.flats, nil)
    c.ground = #c.flats
    if not far then streetMarks(view, c.flats, nil) end
    sceneryPrims(view, c.items, far, nil)
    M.static[slot] = c
    return c
end

---------------------------------------------------------------------------
-- Lot geometry from saved data: enclosed (indoor) cells, roof sections, heights.
---------------------------------------------------------------------------
-- Walls that close a room for roofing (fences, gates, railings and half walls do not).
local ENCLOSING = { wall = true, door = true, window = true, arch = true }

local function wellCells(lot)
    local well = { [0] = {}, [1] = {} }
    for _, o in pairs(lot.objects or {}) do
        local def = SS.Objects[o.def]
        local st = def and def.stairs
        if st then
            local lv = (o.level or 0) + 1
            well[lv] = well[lv] or {}
            for _, c in ipairs(st.run or {}) do
                local dx, dy = G.rot(c[1], c[2], o.f or 0)
                local i, j = o.x + dx, o.y + dy
                if i >= 0 and j >= 0 and i < lot.w and j < lot.h then well[lv][j * lot.w + i + 1] = true end
            end
        end
    end
    return well
end

-- Returns geo = { indoor[level][idx], roofed[level][idx], well[level][idx], top }.
function M.Enclosure(lot)
    local w, h = lot.w, lot.h
    local well = wellCells(lot)
    local geo = { indoor = {}, roofed = {}, well = well, top = 0 }
    for lv = 0, LEVELS() - 1 do
        local floor = lot.floor[lv] or {}
        local walls = lot.walls[lv] or {}
        local function has(i, j)
            if i < 0 or j < 0 or i >= w or j >= h then return false end
            if lv == 0 then return true end
            local k = j * w + i + 1
            return floor[k] ~= nil and not (well[lv] and well[lv][k])
        end
        local function barrier(i, j, ni, nj)
            local wl = walls[G.edgeBetween(i, j, ni, nj)]
            return wl and ENCLOSING[wl.kind]
        end
        local out = {}
        local stack = {}
        local any = false
        for j = 0, h - 1 do
            for i = 0, w - 1 do
                if has(i, j) then
                    any = true
                    local seed = (i == 0 or j == 0 or i == w - 1 or j == h - 1)
                    if not seed and lv > 0 then
                        for d = 0, 3 do
                            local dv = G.DIRS[d]
                            local ni, nj = i + dv[1], j + dv[2]
                            local nk = nj * w + ni + 1
                            if not has(ni, nj) and not (well[lv] and well[lv][nk]) and not barrier(i, j, ni, nj) then seed = true end
                        end
                    end
                    if seed and not out[j * w + i + 1] then out[j * w + i + 1] = true; stack[#stack + 1] = { i, j } end
                end
            end
        end
        while #stack > 0 do
            local c = table.remove(stack)
            for d = 0, 3 do
                local dv = G.DIRS[d]
                local ni, nj = c[1] + dv[1], c[2] + dv[2]
                local nk = nj * w + ni + 1
                if has(ni, nj) and not out[nk] and not barrier(c[1], c[2], ni, nj) then
                    out[nk] = true
                    stack[#stack + 1] = { ni, nj }
                end
            end
        end
        local indoor = {}
        for j = 0, h - 1 do
            for i = 0, w - 1 do
                local k = j * w + i + 1
                if has(i, j) and not out[k] then indoor[k] = true end
            end
        end
        -- a stairwell opening inside the upper story counts as indoor there
        if lv > 0 and well[lv] then
            for k in pairs(well[lv]) do
                local i, j = (k - 1) % w, math.floor((k - 1) / w)
                for d = 0, 3 do
                    local dv = G.DIRS[d]
                    local ni, nj = i + dv[1], j + dv[2]
                    if ni >= 0 and nj >= 0 and ni < w and nj < h and indoor[nj * w + ni + 1] then indoor[k] = true end
                end
            end
        end
        geo.indoor[lv] = indoor
        if any and lv > 0 and next(floor) then geo.top = lv end
    end
    for lv = 0, LEVELS() - 1 do
        local roofed = {}
        local above = lot.floor[lv + 1]
        for k in pairs(geo.indoor[lv]) do
            local covered = (lv + 1 < LEVELS()) and ((above and above[k]) or (well[lv + 1] and well[lv + 1][k]))
            if not covered then roofed[k] = true end
        end
        geo.roofed[lv] = roofed
    end
    return geo
end

local function normStyle(s)
    if SS.Roof and SS.Roof.NormStyle then return SS.Roof.NormStyle(s) end
    if s == "hipped" or s == "hips" or s == "pyramid" then return "hip" end
    if s == "flat" or s == "deck" then return "flat" end
    if s == "shed" or s == "mansard" or s == "hip" then return s end
    return "gable"
end

-- Roof sections (4-connected roofed cells per level) with a step count per cell by style.
-- Returns list of { level, cells = { idx... }, steps = { [idx] = n }, max, style }.
function M.RoofSections(lot, geo)
    local w, h = lot.w, lot.h
    local style = normStyle(lot.roof and lot.roof.style)
    local out = {}
    for lv = 0, LEVELS() - 1 do
        local roofed = geo.roofed[lv]
        local seen = {}
        for _, k in ipairs(sortedKeys(roofed)) do
            if not seen[k] then
                local cells, set = {}, {}
                local stack = { k }
                seen[k] = true
                local x0, y0, x1, y1 = 1e9, 1e9, -1, -1
                while #stack > 0 do
                    local c = table.remove(stack)
                    cells[#cells + 1] = c
                    set[c] = true
                    local i, j = (c - 1) % w, math.floor((c - 1) / w)
                    if i < x0 then x0 = i end
                    if i > x1 then x1 = i end
                    if j < y0 then y0 = j end
                    if j > y1 then y1 = j end
                    for d = 0, 3 do
                        local dv = G.DIRS[d]
                        local ni, nj = i + dv[1], j + dv[2]
                        local nk = nj * w + ni + 1
                        if ni >= 0 and nj >= 0 and ni < w and nj < h and roofed[nk] and not seen[nk] then
                            seen[nk] = true
                            stack[#stack + 1] = nk
                        end
                    end
                end
                table.sort(cells)
                local steps, maxs = {}, 0
                local alongX = (x1 - x0) >= (y1 - y0)
                for _, c in ipairs(cells) do
                    local i, j = (c - 1) % w, math.floor((c - 1) / w)
                    local n
                    if style == "flat" then
                        n = 1
                    elseif style == "gable" or style == "shed" then
                        local a, b = 0, 0
                        if alongX then
                            while set[(j - a) * w + i + 1] and j - a >= 0 do a = a + 1 end
                            while set[(j + b) * w + i + 1] and j + b < h do b = b + 1 end
                        else
                            while set[j * w + (i - a) + 1] and i - a >= 0 do a = a + 1 end
                            while set[j * w + (i + b) + 1] and i + b < w do b = b + 1 end
                        end
                        n = (style == "shed") and b or math.min(a, b)
                    else
                        -- hip / mansard: 8-neighbour distance to the outside
                        n = 0
                        local r = 0
                        while n == 0 do
                            r = r + 1
                            for dj = -r, r do
                                for di = -r, r do
                                    if math.max(math.abs(di), math.abs(dj)) == r then
                                        local ni, nj = i + di, j + dj
                                        if ni < 0 or nj < 0 or ni >= w or nj >= h or not set[nj * w + ni + 1] then n = r end
                                    end
                                end
                            end
                            if r > 32 then n = r end
                        end
                    end
                    local cap = (style == "mansard") and 2 or M.MAX_STEPS
                    n = math.max(1, math.min(n, cap))
                    steps[c] = n
                    if n > maxs then maxs = n end
                end
                out[#out + 1] = { level = lv, cells = cells, steps = steps, max = maxs, style = style }
            end
        end
    end
    return out
end

-- Per-cell top heights (tiles) for picking: roofs, walls, tall objects, trees.
function M.Heights(lot, geo, sections)
    geo = geo or M.Enclosure(lot)
    sections = sections or M.RoofSections(lot, geo)
    local w = lot.w
    local hts = {}
    local function up(k, z) if not hts[k] or hts[k] < z then hts[k] = z end end
    for k = 1, lot.w * lot.h do hts[k] = 0.02 end
    for lv = 0, LEVELS() - 1 do
        for key, wl in pairs(lot.walls[lv] or {}) do
            local _, _, _, ai, aj, bi, bj = G.parseEdge(key)
            local top = lv * STORY() + ((ENCLOSING[wl.kind] and STORY()) or 1)
            for _, c in ipairs({ { ai, aj }, { bi, bj } }) do
                if c[1] >= 0 and c[2] >= 0 and c[1] < lot.w and c[2] < lot.h then up(c[2] * w + c[1] + 1, top) end
            end
        end
        for k in pairs(geo.indoor[lv] or {}) do up(k, (lv + 1) * STORY()) end
    end
    local pieces = M.RoofPieces(lot)
    if pieces then
        for _, p in ipairs(pieces) do up(p.j * w + p.i + 1, p.peak + 0.05) end
    else
        for _, s in ipairs(sections) do
            local zb = (s.level + 1) * STORY()
            for _, c in ipairs(s.cells) do up(c, zb + (s.style == "flat" and 0.2 or s.steps[c] * M.RISE)) end
        end
    end
    for _, o in pairs(lot.objects or {}) do
        if o.x and o.y and o.x >= 0 and o.y >= 0 and o.x < lot.w and o.y < lot.h then
            local z = (o.level or 0) * STORY() + ((o.landscape == "tree") and 2.6 or 1)
            up(o.y * w + o.x + 1, z)
        end
    end
    return hts
end

---------------------------------------------------------------------------
-- Lot content signature (edits that forget lot.version still invalidate the preview).
---------------------------------------------------------------------------
local function strhash(s, h)
    h = h or 5381
    for n = 1, #s do h = (h * 33 + s:byte(n)) % 2147483647 end
    return h
end

function M.Signature(lot)
    local acc, cnt = 0, 0
    local function add(s) acc = (acc + strhash(s)) % 2147483647; cnt = cnt + 1 end
    for lv = 0, LEVELS() - 1 do
        for k, f in pairs(lot.floor[lv] or {}) do add(lv .. "f" .. k .. "=" .. tostring(f)) end
        for k, wl in pairs(lot.walls[lv] or {}) do
            add(lv .. "w" .. k .. "=" .. tostring(wl.kind) .. ":" .. tostring(wl.a) .. ":" .. tostring(wl.b) .. ":" .. tostring(wl.style))
        end
    end
    for id, o in pairs(lot.objects or {}) do
        add("o" .. tostring(id) .. "=" .. tostring(o.def) .. ":" .. tostring(o.x) .. ":" .. tostring(o.y) .. ":" .. tostring(o.f) .. ":" .. tostring(o.level)
            .. ":" .. tostring(o.variant) .. ":" .. tostring(o.state and (o.state.burnt or o.state.broken)))
    end
    for k, p in pairs(lot.pool or {}) do add("p" .. k .. "=" .. tostring(type(p) == "table" and p.depth or p)) end
    local r = lot.roof or {}
    local col = type(r.color) == "table" and table.concat(r.color, ",") or tostring(r.color)
    add("r=" .. tostring(r.style) .. ":" .. tostring(r.material) .. ":" .. col)
    if type(r.sections) == "table" then for k, v in pairs(r.sections) do add("rs" .. tostring(k) .. "=" .. tostring(v.style) .. tostring(v.color) .. tostring(v.material)) end end
    if type(r.overrides) == "table" then
        for k, v in pairs(r.overrides) do
            add("ro" .. tostring(k) .. "=" .. (type(v) == "table" and (tostring(v.style) .. tostring(v.color) .. tostring(v.material)) or tostring(v)))
        end
    end
    for k, t in pairs(lot.terrain or {}) do add("t" .. tostring(k) .. "=" .. tostring(t)) end
    return string.format("%d:%d:%d", lot.version or 0, cnt, acc)
end

---------------------------------------------------------------------------
-- Per-lot preview: cached simplified draw list.
---------------------------------------------------------------------------
M.cache = M.cache or {}
M.sigs = M.sigs or {}
M.heightCache = M.heightCache or {}
M.stats = M.stats or { builds = 0, hits = 0, invalidations = 0 }

function M.Invalidate(lotId)
    M.stats.invalidations = M.stats.invalidations + 1
    if lotId then
        for k in pairs(M.cache) do if k:sub(1, #lotId + 1) == lotId .. "|" then M.cache[k] = nil end end
        M.sigs[lotId], M.heightCache[lotId] = nil, nil
    else
        M.cache, M.sigs, M.heightCache = {}, {}, {}
        M.static, M.ground = {}, {}
    end
end

-- Recompute content signatures (on entering the map, after edits). Returns changed lot ids.
function M.Refresh(root)
    local changed = {}
    for _, id in ipairs(sortedKeys(root.hood.lots)) do
        local sig = M.Signature(root.hood.lots[id])
        if M.sigs[id] ~= sig then changed[#changed + 1] = id end
        M.sigs[id] = sig
    end
    return changed
end

local function sigOf(root, lotId)
    local s = M.sigs[lotId]
    if not s then s = M.Signature(root.hood.lots[lotId]); M.sigs[lotId] = s end
    return s
end

-- Keep the number of cache entries bounded (oldest use first).
local useClock = 0
local function trimCache()
    local cap = HD.Tuning.previewCacheCap or 48
    local n = 0
    for _ in pairs(M.cache) do n = n + 1 end
    while n > cap do
        local oldK, oldT
        for k, c in pairs(M.cache) do if not oldT or c.used < oldT or (c.used == oldT and k < oldK) then oldK, oldT = k, c.used end end
        M.cache[oldK] = nil
        n = n - 1
    end
end

function M.LotHeights(root, lotId)
    local lot = root.hood.lots[lotId]
    local sig = sigOf(root, lotId)
    local c = M.heightCache[lotId]
    if c and c.sig == sig then return c.h end
    local geo = M.Enclosure(lot)
    local hts = M.Heights(lot, geo, M.RoofSections(lot, geo))
    M.heightCache[lotId] = { sig = sig, h = hts }
    return hts
end

local function wallKindHasArt(kind)
    local A = SS.Art.walls or {}
    return A[kind .. ":full:x"] ~= nil
end

-- Fallback pieces for wall kinds the renderer has no art for (fences, gates, railings, half walls, arches).
local FENCE_TINT = { fence = { 0.95, 0.94, 0.9 }, gate = { 0.86, 0.8, 0.7 }, railing = { 0.3, 0.3, 0.32 }, halfwall = { 0.9, 0.86, 0.78 } }

-- Build the preview entry for one lot. quality: "low" | "medium" (exterior) | "high" (cutaway interior).
function M.BuildLotPreview(root, lotId, rot, quality, level)
    local lot = root.hood.lots[lotId]
    local pl = root.hood.layout and root.hood.layout.lots[lotId]
    if not lot or not pl then return nil, "That lot is not on the map." end
    local view = M.NewView(rot, 1)
    local lr = (pl.rot + view.r) % 4
    local geo = M.Enclosure(lot)
    local sections = M.RoofSections(lot, geo)
    local e = { lotId = lotId, flats = {}, items = {}, quality = quality, level = level or 0, rot = view.r, top = geo.top,
        counts = { walls = 0, objects = 0, roof = 0, floors = 0, trees = 0, fences = 0, pool = 0 } }
    local W_, H_ = lot.w, lot.h
    local cutaway = quality == "high"
    local previewLevel = math.min(level or 0, geo.top)
    -- lot position -> map canvas and depth
    local function mapXY(x, y, z)
        local mx, my = H.LotPosToMap(pl, x, y)
        return M.MapToCanvas(view, mx, my, z)
    end
    local function mapDepth(x, y) local mx, my = H.LotPosToMap(pl, x, y); return M.Depth(view, mx, my) end
    local function cellDepth(i, j) return mapDepth(i + 0.5, j + 0.5) end
    local function roofedAt(lv, i, j) return geo.roofed[lv] and geo.roofed[lv][j * W_ + i + 1] end
    local function indoorAt(lv, i, j) return geo.indoor[lv] and geo.indoor[lv][j * W_ + i + 1] end

    M.SyncRoofCache(lot)
    local ok, err = HL.WithLot(root, lot, function(world)
        rawset(world, "time", 12 * 60)
        local cam = { r = lr, zoom = 1, walls = cutaway and "cut" or "roof", level = cutaway and previewLevel or (LEVELS() - 1), panX = 0, panY = 0 }
        local R = SS.Render
        local floors, items = R.BuildStatic(world, cam)
        -- affine lot canvas -> map canvas (the renderer's scale may differ from ours)
        local ua, va = G.vpos(0, 0, lr, W_, H_)
        local ub, vb = G.vpos(W_, 0, lr, W_, H_)
        local lax, lay = R.ToCanvas(world, cam, ua, va, 0)
        local lbx, lby = R.ToCanvas(world, cam, ub, vb, 0)
        local max_, may_ = mapXY(0, 0, 0)
        local mbx, mby = mapXY(W_, 0, 0)
        local ll = math.sqrt((lbx - lax) ^ 2 + (lby - lay) ^ 2)
        local ml = math.sqrt((mbx - max_) ^ 2 + (mby - may_) ^ 2)
        local s = (ll > 0) and (ml / ll) or 1
        local tx, ty = max_ - s * lax, may_ - s * lay
        local dOff = mapDepth(0, 0) - (ua + va)
        e.scale = s
        local artRoof = false
        for _, it in ipairs(items) do if it.kind == "roof" then artRoof = true; break end end
        e.artRoof = artRoof

        local function addLayers(it, d, lv, kind)
            for _, L in ipairs(it.layers) do
                local x = (L[5] or it.x) * s + tx
                local y = (L[6] or it.y) * s + ty
                prim(e.items, L[1], x, y, s, L[2], L[3], L[4], 1, d, lv, kind)
            end
        end

        -- flats: level 0 floors and pool
        if cutaway then
            for _, f in ipairs(floors) do
                local x, y = f.x * s + tx, f.y * s + ty
                local i, j = f.cell[1], f.cell[2]
                local isPool = lot.pool and lot.pool[j * W_ + i + 1]
                local sp, r, g, b = f.sprite, f.tint[1], f.tint[2], f.tint[3]
                if isPool then sp, r, g, b = M.GroundSprite("pool") end
                prim(e.flats, sp, x, y, s, r, g, b, 1, 0, 0, isPool and "pool" or "floor")
                e.counts.floors = e.counts.floors + 1
            end
        else
            local groups = {}
            for j = 0, H_ - 1 do
                for i = 0, W_ - 1 do
                    local k = j * W_ + i + 1
                    if not indoorAt(0, i, j) then
                        local key = (lot.pool and lot.pool[k]) and "~pool" or tostring((lot.floor[0] or {})[k] or "grass")
                        groups[key] = groups[key] or {}
                        groups[key][k] = true
                    end
                end
            end
            for _, key in ipairs(sortedKeys(groups)) do
                local set = groups[key]
                local cov = {}
                local sp, r, g, b
                if key == "~pool" then sp, r, g, b = M.GroundSprite("pool") else sp, r, g, b = M.FloorSprite(key) end
                for j = 0, H_ - 1 do
                    for i = 0, W_ - 1 do
                        local k = j * W_ + i + 1
                        if set[k] and not cov[k] then
                            local n = 1
                            while i + n < W_ and j + n < H_ and n < M.MAXK do
                                local okk = true
                                for t = 0, n do
                                    local a = (j + n) * W_ + i + t + 1
                                    local b2 = (j + t) * W_ + i + n + 1
                                    if not set[a] or cov[a] or not set[b2] or cov[b2] then okk = false; break end
                                end
                                if not okk then break end
                                n = n + 1
                            end
                            for y = j, j + n - 1 do for x = i, i + n - 1 do cov[y * W_ + x + 1] = true end end
                            local px, py = mapXY(i + n / 2, j + n / 2, 0)
                            prim(e.flats, sp, px, py, diamondScale(sp, n), r, g, b, 1, 0, 0, key == "~pool" and "pool" or "floor")
                            if key == "~pool" then e.counts.pool = e.counts.pool + 1 else e.counts.floors = e.counts.floors + 1 end
                        end
                    end
                end
            end
            -- upper outdoor floors (balconies, decks): standing squares at story height
            for lv = 1, LEVELS() - 1 do
                local fl = lot.floor[lv] or {}
                for _, k in ipairs(sortedKeys(fl)) do
                    local i, j = (k - 1) % W_, math.floor((k - 1) / W_)
                    if not indoorAt(lv, i, j) and not (geo.well[lv] and geo.well[lv][k]) then
                        local sp, r, g, b = M.FloorSprite(fl[k])
                        local px, py = mapXY(i + 0.5, j + 0.5, lv * STORY())
                        prim(e.items, sp, px, py, diamondScale(sp, 1), r * 0.95, g * 0.95, b * 0.95, 1, cellDepth(i, j) - 0.98, lv, "floor")
                        e.counts.floors = e.counts.floors + 1
                    end
                end
            end
        end

        -- standing items from the renderer
        local lotObjs = lot.objects
        local drawnLand = {}
        -- (cutaway of an upper story) a lower-level item under that story's floor is hidden by it
        local function coveredAbove(lv, i, j)
            if not cutaway or lv >= previewLevel then return false end
            if i < 0 or j < 0 or i >= W_ or j >= H_ then return false end
            local k = j * W_ + i + 1
            local f = lot.floor[lv + 1]
            return (f and f[k] ~= nil) or (geo.well[lv + 1] and geo.well[lv + 1][k]) or false
        end
        for _, it in ipairs(items) do
            local lv = it.level or 0
            local d = (it.key - lv * 1000) + dOff
            local hidden = false
            if cutaway and lv < previewLevel then
                if it.kind == "wall" then
                    local _, _, _, ai, aj, bi, bj = G.parseEdge(it.ref)
                    local fi, fj = ai, aj
                    local inA = ai >= 0 and aj >= 0 and ai < W_ and aj < H_
                    local inB = bi >= 0 and bj >= 0 and bi < W_ and bj < H_
                    if inB and (not inA or cellDepth(bi, bj) > cellDepth(ai, aj)) then fi, fj = bi, bj end
                    hidden = coveredAbove(lv, fi, fj)
                elseif it.kind == "obj" and lotObjs[it.ref] then
                    local o = lotObjs[it.ref]
                    hidden = coveredAbove(lv, o.x, o.y)
                end
            end
            if hidden then
                -- skipped: under the upper story's floor
            elseif it.kind == "floor" then
                if cutaway then
                    for _, L in ipairs(it.layers) do
                        local x = (L[5] or it.x) * s + tx
                        local y = (L[6] or it.y) * s + ty
                        local mx, my = M.CanvasToMap(view, x, y, lv * STORY())
                        prim(e.items, L[1], x, y, s, L[2], L[3], L[4], 1, M.Depth(view, mx, my) - 0.98, lv, "floor")
                    end
                end
            elseif it.kind == "wall" then
                local keep = true
                if not cutaway then
                    local _, _, _, ai, aj, bi, bj = G.parseEdge(it.ref)
                    local ina = ai >= 0 and aj >= 0 and ai < W_ and aj < H_ and indoorAt(lv, ai, aj)
                    local inb = bi >= 0 and bj >= 0 and bi < W_ and bj < H_ and indoorAt(lv, bi, bj)
                    if ina and inb then keep = false
                    elseif ina or inb then
                        -- exterior wall: only the faces turned toward the viewer show under the roof
                        local oi, oj, ii, ij = bi, bj, ai, aj
                        if inb then oi, oj, ii, ij = ai, aj, bi, bj end
                        keep = cellDepth(oi, oj) > cellDepth(ii, ij)
                    end
                end
                if keep then addLayers(it, d, lv, "wall"); e.counts.walls = e.counts.walls + 1 end
            elseif it.kind == "obj" then
                local o = lotObjs[it.ref]
                local keep = o ~= nil
                if o and not cutaway then
                    keep = not indoorAt(o.level or 0, o.x, o.y)
                    if keep and quality == "low" then
                        local def = SS.Objects[o.def]
                        local fp = def and def.fp and #def.fp or 1
                        keep = o.landscape ~= nil or fp > 1 or (def and def.light ~= nil)
                    end
                elseif o and cutaway then
                    keep = (o.level or 0) <= previewLevel
                end
                if keep and o and o.landscape and o.def == "plant_pot" then
                    keep = false -- drawn below as a map tree/shrub (the fallback object has only a pot)
                end
                if keep then
                    addLayers(it, d, lv, "obj"); e.counts.objects = e.counts.objects + 1
                    if o.landscape then drawnLand[it.ref] = true; e.counts.trees = e.counts.trees + 1 end
                end
            elseif it.kind == "roof" then
                -- the renderer's gable ends are "roof" items too, but coloured by their wall finish:
                -- they are marked "gable" so the roof colour is read from the roof pieces only
                if not cutaway then
                    local gable = type(it.ref) == "string" and it.ref:sub(1, 6) == "gable:"
                    addLayers(it, d, lv, gable and "gable" or "roof"); e.counts.roof = e.counts.roof + 1
                end
            else
                addLayers(it, d, lv, it.kind or "extra")
            end
        end

        -- walls the renderer has no art for (fences, gates, railings, half walls, arches)
        for lv = 0, LEVELS() - 1 do
            if not cutaway or lv <= previewLevel then
                for _, key in ipairs(sortedKeys(lot.walls[lv] or {})) do
                    local wl = lot.walls[lv][key]
                    if not wallKindHasArt(wl.kind) then
                        local axis, i, j = G.parseEdge(key)
                        local x1, y1, x2, y2
                        if axis == "x" then x1, y1, x2, y2 = i, j, i + 1, j else x1, y1, x2, y2 = i, j, i, j + 1 end
                        local u1, v1 = G.vpos(x1, y1, lr, W_, H_)
                        local u2, v2 = G.vpos(x2, y2, lr, W_, H_)
                        local vaxis = (math.abs(v1 - v2) < 1e-6) and "x" or "y"
                        local mxp, myp = (x1 + x2) / 2, (y1 + y2) / 2
                        local px, py = mapXY(mxp, myp, lv * STORY())
                        local sprite
                        if wl.kind == "arch" then
                            local A = SS.Art.walls["door:full:" .. vaxis]
                            sprite = A and A.wall
                        else
                            local A = SS.Art.walls["wall:short:" .. vaxis]
                            sprite = A and A.wall
                        end
                        if sprite then
                            local fin = SS.Finishes.walls[wl.a or ""] or SS.Finishes.walls[wl.b or ""]
                            local c = (wl.kind ~= "arch" and FENCE_TINT[wl.kind]) or (fin and fin.color) or { 0.9, 0.9, 0.88 }
                            if wl.kind == "fence" and fin and fin.color then c = fin.color end
                            -- depth: the edge midpoint (walls sort by their edge like the renderer)
                            prim(e.items, sprite, px, py, e.scale or 1, c[1], c[2], c[3], 1, mapDepth(mxp, myp), lv, "fence")
                            e.counts.fences = e.counts.fences + 1
                        end
                    end
                end
            end
        end
        -- landscape the renderer did not draw (the pot stand-in, or a catalogue tree without art
        -- yet) drawn as map trees / shrubs / flowers
        for _, id in ipairs(sortedKeys(lotObjs)) do
            local o = lotObjs[id]
            if o.landscape and not drawnLand[id] and (not cutaway or (o.level or 0) <= previewLevel)
                and (o.def == "plant_pot" or cutaway or not indoorAt(o.level or 0, o.x, o.y)) then
                local kind = (o.landscape == "tree") and ((o.x + o.y) % 3 == 0 and "pine" or "broad") or o.landscape
                if kind == "fountain" then kind = "shrub" end
                local mx, my = H.LotPosToMap(pl, o.x + 0.5, o.y + 0.5)
                local list = {}
                M.TreePrims(list, view, mx, my, kind, (o.landscape == "tree") and 1.1 or 1, cellDepth(o.x, o.y), quality == "low", (o.level or 0) * STORY())
                for _, p in ipairs(list) do p.o = #e.items + 1; e.items[#e.items + 1] = p end
                e.counts.trees = e.counts.trees + 1
            end
        end
    end)
    if ok == nil and err then return nil, err end

    -- build's roof geometry when the build module is present: one slab per run of cells at the same
    -- height and colour (greedy squares, like the fallback), shaded by height within its section
    local pieces = (not cutaway and not e.artRoof) and M.RoofPieces(lot) or nil
    if pieces then
        local sp, base = roofSprite(lot), roofRGB(lot)
        local secLo, secHi, secD = {}, {}, {}
        for _, p in ipairs(pieces) do
            local k = p.section
            if not secLo[k] or p.top < secLo[k] then secLo[k] = p.top end
            if not secHi[k] or p.top > secHi[k] then secHi[k] = p.top end
            local dd = cellDepth(p.i, p.j)
            if not secD[k] or dd > secD[k] then secD[k] = dd end
        end
        -- sets of equal height and colour per section
        local sets, order = {}, {}
        for _, p in ipairs(pieces) do
            local rgb = p.rgb or base
            local key = tostring(p.section) .. "|" .. string.format("%.2f", p.top) .. "|" .. string.format("%.3f,%.3f,%.3f", rgb[1], rgb[2], rgb[3])
            local st = sets[key]
            if not st then st = { cells = {}, top = p.top, rgb = rgb, section = p.section, level = p.level, sloped = false }; sets[key] = st; order[#order + 1] = key end
            st.cells[p.j * W_ + p.i + 1] = true
            st.sloped = st.sloped or p.sloped
        end
        table.sort(order, function(a, b)
            local A, B = sets[a], sets[b]
            if A.top ~= B.top then return A.top < B.top end
            return a < b
        end)
        for rank, key in ipairs(order) do
            local st = sets[key]
            local lo, hi = secLo[st.section], secHi[st.section]
            local f = (hi > lo) and (0.7 + 0.3 * (st.top - lo) / (hi - lo)) or (st.sloped and 0.85 or 0.86)
            local cov = {}
            for _, c in ipairs(sortedKeys(st.cells)) do
                if not cov[c] then
                    local i, j = (c - 1) % W_, math.floor((c - 1) / W_)
                    local m = 1
                    while i + m < W_ and j + m < H_ do
                        local okk = true
                        for t = 0, m do
                            local a = (j + m) * W_ + i + t + 1
                            local b = (j + t) * W_ + i + m + 1
                            if not st.cells[a] or cov[a] or not st.cells[b] or cov[b] then okk = false; break end
                        end
                        if not okk then break end
                        m = m + 1
                    end
                    for y = j, j + m - 1 do for x = i, i + m - 1 do cov[y * W_ + x + 1] = true end end
                    local px, py = mapXY(i + m / 2, j + m / 2, st.top)
                    local p = prim(e.items, sp, px, py, diamondScale(sp, m), st.rgb[1] * f, st.rgb[2] * f, st.rgb[3] * f, 1,
                        secD[st.section] + 0.45 + rank * 0.0001, st.level, "roof")
                    p.step = rank
                    e.counts.roof = e.counts.roof + 1
                end
            end
        end
        e.buildRoof = true
    end

    -- fallback roof: stepped slabs over each section, in the lot's style and colour
    if not cutaway and not e.artRoof and not pieces then
        local rgb = roofRGB(lot)
        local sp = roofSprite(lot)
        for _, sec in ipairs(sections) do
            local zb = (sec.level + 1) * STORY()
            local dmax = -1e9
            for _, c in ipairs(sec.cells) do
                local i, j = (c - 1) % W_, math.floor((c - 1) / W_)
                local dd = cellDepth(i, j)
                if dd > dmax then dmax = dd end
            end
            for n = 1, sec.max do
                local set = {}
                for _, c in ipairs(sec.cells) do if sec.steps[c] >= n then set[c] = true end end
                local f = (sec.style == "flat") and 0.86 or (0.7 + 0.3 * n / sec.max)
                local z = zb + ((sec.style == "flat") and 0.12 or (n - 0.5) * M.RISE)
                local cov = {}
                for _, c in ipairs(sec.cells) do
                    if set[c] and not cov[c] then
                        local i, j = (c - 1) % W_, math.floor((c - 1) / W_)
                        local m = 1
                        while i + m < W_ and j + m < H_ do
                            local okk = true
                            for t = 0, m do
                                local a = (j + m) * W_ + i + t + 1
                                local b = (j + t) * W_ + i + m + 1
                                if not set[a] or cov[a] or not set[b] or cov[b] then okk = false; break end
                            end
                            if not okk then break end
                            m = m + 1
                        end
                        for y = j, j + m - 1 do for x = i, i + m - 1 do cov[y * W_ + x + 1] = true end end
                        local px, py = mapXY(i + m / 2, j + m / 2, z)
                        local p = prim(e.items, sp, px, py, diamondScale(sp, m), rgb[1] * f, rgb[2] * f, rgb[3] * f, 1, dmax + 0.45 + n * 0.0001, sec.level, "roof")
                        p.step = n
                        e.counts.roof = e.counts.roof + 1
                    end
                end
            end
        end
    end

    -- keep the detailed (cutaway) preview within its budget: drop small decor first
    if cutaway then
        local cap = HD.Tuning.detailedCap or 420
        if #e.items > cap then
            local function prio(p)
                if p.kind == "wall" or p.kind == "floor" or p.kind == "fence" then return 3 end
                if p.kind == "tree" then return 2 end
                return 1
            end
            local keep = {}
            for _, p in ipairs(e.items) do keep[#keep + 1] = p end
            table.sort(keep, function(a, b) if prio(a) ~= prio(b) then return prio(a) > prio(b) end return a.o < b.o end)
            local cut = {}
            for n = cap + 1, #keep do cut[keep[n]] = true end
            local list = {}
            for _, p in ipairs(e.items) do if not cut[p] then list[#list + 1] = p end end
            e.items = list
            e.trimmed = #keep - cap
        end
    end
    for n, p in ipairs(e.items) do p.o, p.lot = n, lotId end
    for n, p in ipairs(e.flats) do p.o, p.lot = n, lotId end
    local box
    for _, p in ipairs(e.flats) do box = primBox(p, box) end
    for _, p in ipairs(e.items) do box = primBox(p, box) end
    e.box = box or { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
    e.count = #e.flats + #e.items
    return e
end

-- Cached preview. Key: version + content signature + rotation + quality (+ level for cutaways).
function M.LotPreview(root, lotId, rot, quality, level)
    local sig = sigOf(root, lotId)
    local suffix = "|" .. (rot % 4) .. "|" .. quality .. "|" .. ((quality == "high") and tostring(level or 0) or "-")
    local k = lotId .. "|" .. sig .. suffix
    useClock = useClock + 1
    local c = M.cache[k]
    if c then c.used = useClock; M.stats.hits = M.stats.hits + 1; return c.entry, true end
    -- a stale entry of this lot for the same view (older version or content) is dropped
    local prefix = lotId .. "|"
    for key in pairs(M.cache) do
        if key ~= k and key:sub(1, #prefix) == prefix and key:sub(-#suffix) == suffix then M.cache[key] = nil end
    end
    local e, why = M.BuildLotPreview(root, lotId, rot, quality, level)
    if not e then return nil, false, why end
    e.key = k
    M.stats.builds = M.stats.builds + 1
    M.cache[k] = { entry = e, used = useClock }
    trimCache()
    return e, false
end

---------------------------------------------------------------------------
-- Composition
---------------------------------------------------------------------------
-- Quality for a lot at this zoom (the selected lot's cutaway is "high").
function M.QualityFor(view, lotId, opts)
    if opts and opts.cutaway and opts.selected == lotId then return "high" end
    return (view.zoom >= M.MEDIUM_ZOOM) and "medium" or "low"
end

-- Compose the scene. opts: rect (visible zoom-1 canvas rect), selected, cutaway (bool),
-- previewLevel, hover. Returns scene = { flats, marks, items, lots (visible ids), counts }.
local function inRect(p, r) return not r or (p.fx1 >= r.x0 and p.fx0 <= r.x1 and p.fy1 >= r.y0 and p.fy0 <= r.y1) end
-- Painter's order: depth, level, source (lots by id, scenery last), order within the source.
local function itemLess(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if a.lv ~= b.lv then return a.lv < b.lv end
    local sa, sb = a.src or 0, b.src or 0
    if sa ~= sb then return sa < sb end
    return a.o < b.o
end
local SCENERY_SRC = 100000

-- Compose the scene. opts: rect (visible zoom-1 canvas rect), selected, cutaway (bool),
-- previewLevel, hover, reuse (a scene table from an earlier call to refill instead of allocating
-- a new one; the neighbourhood view passes its own). Returns scene = { flats, marks, items,
-- lots (visible ids), counts }. Ground, markings and scenery come from M.StaticPrims and lot
-- exteriors from the per-lot preview cache; only the lists of what is visible are rebuilt.
function M.Compose(root, view, opts)
    opts = opts or {}
    local far = view.zoom < M.NEAR_ZOOM
    local rect = opts.rect
    local scene = opts.reuse
    if scene then
        for _, k in ipairs({ "flats", "marks", "items", "lots" }) do
            local t = scene[k]
            for i = #t, 1, -1 do t[i] = nil end
        end
        scene.counts.ground, scene.counts.lots, scene.counts.trees, scene.far = 0, 0, 0, far
    else
        scene = { flats = {}, marks = {}, items = {}, lots = {}, counts = { ground = 0, lots = 0, trees = 0 }, far = far }
    end
    local st = M.StaticPrims(root, view, far)
    local flats, items = scene.flats, scene.items
    for i = 1, st.ground do local p = st.flats[i]; if inRect(p, rect) then flats[#flats + 1] = p end end
    scene.counts.ground = #flats
    for i = st.ground + 1, #st.flats do local p = st.flats[i]; if inRect(p, rect) then flats[#flats + 1] = p end end
    local placed = root.hood.layout.lots
    for n, id in ipairs(cachedIds(root.hood.lots, lotIdsC)) do
        if placed[id] then
            local q = M.QualityFor(view, id, opts)
            local e = M.LotPreview(root, id, view.r, q, opts.previewLevel)
            if e and boxHits(e.box, rect) then
                scene.lots[#scene.lots + 1] = id
                for _, p in ipairs(e.flats) do flats[#flats + 1] = p end
                for _, p in ipairs(e.items) do items[#items + 1] = p; p.src = n end
                scene.counts.lots = scene.counts.lots + e.count
            end
        end
    end
    local trees = 0
    for _, p in ipairs(st.items) do
        if inRect(p, rect) then items[#items + 1] = p; p.src = SCENERY_SRC; trees = trees + 1 end
    end
    scene.counts.trees = trees
    table.sort(items, itemLess)
    if opts.hover and opts.hover ~= opts.selected then M.FootprintPrims(root, view, opts.hover, scene.marks, { 1, 1, 0.85 }, 0.28) end
    if opts.selected then M.FootprintPrims(root, view, opts.selected, scene.marks, { 1, 0.86, 0.4 }, 0.42) end
    scene.total = #scene.flats + #scene.marks + #scene.items
    return scene
end

-- Precise footprint highlight: the lot's cells as translucent squares on the ground.
function M.FootprintPrims(root, view, lotId, out, rgb, alpha)
    local pl = root.hood.layout.lots[lotId]
    if not pl then return out end
    local s = M.BaseFloor("tile")
    for _, sq in ipairs(M.Squares(pl.x, pl.y, pl.w, pl.h)) do
        local px, py = M.MapToCanvas(view, sq[1] + sq[3] / 2, sq[2] + sq[3] / 2, 0.03)
        local p = prim(out, s, px, py, diamondScale(s, sq[3]), rgb[1], rgb[2], rgb[3], alpha, 0, 0, "highlight")
        p.lot = lotId
    end
    return out
end

-- Footprint outline: 4 canvas corner points (zoom 1) of the lot's map rectangle.
function M.FootprintOutline(root, view, lotId)
    local pl = root.hood.layout.lots[lotId]
    if not pl then return nil end
    local pts = {}
    for n, c in ipairs({ { pl.x, pl.y }, { pl.x + pl.w, pl.y }, { pl.x + pl.w, pl.y + pl.h }, { pl.x, pl.y + pl.h } }) do
        local x, y = M.MapToCanvas(view, c[1], c[2], 0.03)
        pts[n] = { x, y }
    end
    return pts
end

-- Street-front label anchor of a lot (canvas, zoom 1): the middle of its street edge.
function M.LabelPos(root, view, lotId)
    local lot, pl = root.hood.lots[lotId], root.hood.layout.lots[lotId]
    if not lot or not pl then return nil end
    local mx, my = H.LotPosToMap(pl, lot.w / 2, lot.h + 0.6)
    return M.MapToCanvas(view, mx, my, 0)
end

-- Canvas position (zoom 1) that centres a lot (for "centre on the selected lot").
function M.LotCentre(root, view, lotId)
    local lot, pl = root.hood.lots[lotId], root.hood.layout.lots[lotId]
    if not lot or not pl then return nil end
    local mx, my = H.LotPosToMap(pl, lot.w / 2, lot.h / 2)
    return M.MapToCanvas(view, mx, my, 1)
end

---------------------------------------------------------------------------
-- Picking (saved geometry, so the cutaway never breaks it)
---------------------------------------------------------------------------
function M.LotAtMap(root, mx, my)
    local cx, cy = math.floor(mx), math.floor(my)
    local placed = root.hood.layout.lots
    for _, id in ipairs(cachedIds(placed, placeIdsC)) do
        local pl = placed[id]
        if cx >= pl.x and cy >= pl.y and cx < pl.x + pl.w and cy < pl.y + pl.h and root.hood.lots[id] then
            local i, j = H.MapToLot(pl, cx, cy)
            if i then return id, i, j end
        end
    end
end

-- Could the cursor (zoom-1 canvas px, py) touch placement `pl` at any height up to PICK_ZMAX?
-- The screen box of the lot's map rectangle from the ground to PICK_ZMAX.
local function pickBoxHit(view, pl, px, py)
    local x0, y0, x1, y1
    for c = 1, 4 do
        local mx = (c == 2 or c == 3) and pl.x + pl.w or pl.x
        local my = (c >= 3) and pl.y + pl.h or pl.y
        local x, y = M.MapToCanvas(view, mx, my, 0)
        if not x0 or x < x0 then x0 = x end
        if not x1 or x > x1 then x1 = x end
        if not y0 or y < y0 then y0 = y end
        if not y1 or y > y1 then y1 = y end
    end
    return px >= x0 and px <= x1 and py >= y0 - M.PICK_ZMAX * 32 and py <= y1
end

-- Returns kind, ref: "lot", lotId | "street", street | "landmark", landmark | "ground", kind | nil.
-- The front-most lot surface under the cursor: only lots whose screen box holds the cursor are
-- tested, each by walking its own ray down from PICK_ZMAX to the ground in PICK_STEP steps; the
-- highest hit wins (the lower id on a tie). No tables are allocated.
function M.Pick(root, view, px, py)
    local placed = root.hood.layout.lots
    local bestZ, bestId, bestX, bestY = -1
    for _, id in ipairs(cachedIds(placed, placeIdsC)) do
        local pl, lot = placed[id], root.hood.lots[id]
        if lot and pickBoxHit(view, pl, px, py) then
            local hts
            local z = M.PICK_ZMAX
            while z >= 0 and z > bestZ do
                local mx, my = M.CanvasToMap(view, px, py, z)
                local cx, cy = math.floor(mx), math.floor(my)
                if cx >= pl.x and cy >= pl.y and cx < pl.x + pl.w and cy < pl.y + pl.h then
                    local i, j = H.MapToLot(pl, cx, cy)
                    if i then
                        hts = hts or M.LotHeights(root, id)
                        if (hts[j * lot.w + i + 1] or 0) >= z - 1e-6 then
                            bestZ, bestId, bestX, bestY = z, id, mx, my
                            break
                        end
                    end
                end
                z = z - M.PICK_STEP
            end
        end
    end
    if bestId then return "lot", bestId, bestX, bestY end
    local mx, my = M.CanvasToMap(view, px, py, 0)
    if mx < 0 or my < 0 or mx >= HD.map.w or my >= HD.map.h then return nil end
    for _, e in ipairs(HD.map.landmarks or {}) do
        if math.abs(mx - (e.x + 0.5)) <= 2 and math.abs(my - (e.y + 0.5)) <= 2 then return "landmark", e, mx, my end
    end
    local s = H.StreetAt(math.floor(mx), math.floor(my))
    if s then return "street", s, mx, my end
    return "ground", H.GroundAt(math.floor(mx), math.floor(my)), mx, my
end

---------------------------------------------------------------------------
-- Client painter: pooled textures in frames of M.SLOTS strictly ordered draw slots.
---------------------------------------------------------------------------
M.LAYERS = { "BACKGROUND", "BORDER", "ARTWORK", "OVERLAY" }

function M.NewPainter(parent)
    local P = { frames = {}, painted = 0, lines = {}, labels = {} }
    local canvas = CreateFrame("Frame", nil, parent)
    canvas:SetSize(10, 10)
    canvas:SetPoint("CENTER")
    P.canvas = canvas
    P.top = CreateFrame("Frame", nil, canvas)
    P.top:SetAllPoints(canvas)

    function P:Texture(n)
        local fi = math.floor((n - 1) / M.SLOTS) + 1
        local f = self.frames[fi]
        if not f then
            f = CreateFrame("Frame", nil, canvas)
            f:SetAllPoints(canvas)
            f.tex = {}
            self.frames[fi] = f
        end
        f:SetFrameLevel((canvas:GetFrameLevel() or 1) + fi)
        f:Show()
        local slot = (n - 1) % M.SLOTS
        local t = f.tex[slot + 1]
        if not t then
            t = f:CreateTexture(nil, M.LAYERS[math.floor(slot / 16) + 1], nil, (slot % 16) - 8)
            f.tex[slot + 1] = t
        end
        return t
    end

    -- Paint primitives in order (lists are concatenated). Returns the number of textures used.
    function P:Paint(lists, zoom)
        local A = SS.Art
        local size = A.sheetSize
        local sc = artScale()
        local n = 0
        for _, list in ipairs(lists) do
            for _, p in ipairs(list) do
                local s = A.sprites[p.s]
                if s then
                    n = n + 1
                    local t = self:Texture(n)
                    SS.Render.SetTex(t, A.sheets[s[1]])
                    t:SetTexCoord(s[2] / size, (s[2] + s[4]) / size, s[3] / size, (s[3] + s[5]) / size)
                    local kw, kh = (p.kw or p.k) / sc, (p.kh or p.k) / sc
                    t:SetSize(math.max(0.01, s[4] * kw * zoom), math.max(0.01, s[5] * kh * zoom))
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", canvas, "TOPLEFT", (p.x - s[6] * kw) * zoom, -(p.y - s[7] * kh) * zoom)
                    t:SetVertexColor(p.r, p.g, p.b, p.a or 1)
                    t:Show()
                end
            end
        end
        -- hide what is left over
        local lastFrame = math.floor((math.max(n, 1) - 1) / M.SLOTS) + 1
        for fi, f in ipairs(self.frames) do
            if fi > lastFrame or n == 0 then
                f:Hide()
            elseif fi == lastFrame then
                for slot = (n - 1) % M.SLOTS + 2, #f.tex do f.tex[slot]:Hide() end
            end
        end
        self.painted = n
        self.top:SetFrameLevel((canvas:GetFrameLevel() or 1) + #self.frames + 2)
        return n
    end

    -- Outline lines (zoom-1 points, closed). Uses Line objects when the client has them. `set`
    -- names an independent outline ("select" by default, "hover" for the hovered lot).
    function P:Outline(pts, rgb, thick, zoom, set)
        set = set or "select"
        self.lineSets = self.lineSets or { select = self.lines }
        local lines = self.lineSets[set]
        if not lines then lines = {}; self.lineSets[set] = lines end
        for _, l in ipairs(lines) do l:Hide() end
        if not pts then return 0 end
        local shown = 0
        for n = 1, #pts do
            local a, b = pts[n], pts[n % #pts + 1]
            local l = lines[n]
            if not l and self.top.CreateLine then
                l = self.top:CreateLine(nil, "OVERLAY", nil, set == "hover" and 1 or 2)
                lines[n] = l
            end
            if l then
                l:SetThickness(thick or 2)
                l:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)
                l:SetStartPoint("TOPLEFT", canvas, a[1] * zoom, -a[2] * zoom)
                l:SetEndPoint("TOPLEFT", canvas, b[1] * zoom, -b[2] * zoom)
                l:Show()
                shown = shown + 1
            end
        end
        return shown
    end

    -- Text labels: list of { text, x, y (zoom 1), size, rgb }.
    function P:Labels(list, zoom)
        local K = SS.UI and SS.UI.Kit
        for n, L in ipairs(list) do
            local fs = self.labels[n]
            if not fs then
                fs = K and K.Text(self.top, L.size or 11, L.rgb or { 1, 1, 1 }, "CENTER") or self.top:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                if fs.SetShadowOffset then fs:SetShadowOffset(1, -1) end
                self.labels[n] = fs
            end
            fs:SetText(L.text)
            if L.rgb then fs:SetTextColor(L.rgb[1], L.rgb[2], L.rgb[3]) end
            fs:ClearAllPoints()
            fs:SetPoint("CENTER", canvas, "TOPLEFT", L.x * zoom, -L.y * zoom)
            fs:Show()
        end
        for n = #list + 1, #self.labels do self.labels[n]:Hide() end
    end

    function P:Size(w, h) canvas:SetSize(w, h) end
    return P
end

-- Street and lot labels for the current view (zoom 1 positions).
function M.Labels(root, view, opts)
    local out = {}
    opts = opts or {}
    for _, s in ipairs(HD.map.streets) do
        local mx, my
        if s.axis == "h" then mx, my = s.x0 + (s.x1 - s.x0) * 0.18, (s.y0 + s.y1 + 1) / 2
        else mx, my = (s.x0 + s.x1 + 1) / 2, s.y0 + (s.y1 - s.y0) * 0.3 end
        local x, y = M.MapToCanvas(view, mx, my, 0)
        out[#out + 1] = { text = s.name, x = x, y = y, size = 11, rgb = { 1, 0.97, 0.86 }, kind = "street" }
    end
    if view.zoom >= M.NEAR_ZOOM or opts.addresses then
        for _, id in ipairs(sortedKeys(root.hood.lots)) do
            local x, y = M.LabelPos(root, view, id)
            if x then
                local lot = root.hood.lots[id]
                local txt = lot.kind == "community" and (lot.name or lot.address) or lot.address
                out[#out + 1] = { text = txt, x = x, y = y, size = 10, rgb = { 1, 1, 1 }, kind = "lot", lot = id }
            end
        end
    end
    return out
end

-- Invalidate previews when anything on a lot changes (build, buy, move out, bulldoze).
if SS.On then
    SS.On("lotChanged", function(_, ref)
        local root = SS.Sim and SS.Sim.root
        if type(ref) == "string" and root and root.hood and root.hood.lots[ref] then M.Invalidate(ref) end
        local w = SS.Sim and SS.Sim.world
        if w and w.lot and w.lot.id then M.sigs[w.lot.id] = nil end
    end)
    SS.On("lotBulldozed", function(_, lotId) if lotId then M.Invalidate(lotId) end end)
end
