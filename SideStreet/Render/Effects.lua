-- SideStreet effects layer (art module; docs/ART.md section 9).
--
-- Modules add effect draw items through SS.Render.RegisterEffects(fn(world, cam, out)); each
-- provider appends plain records { level, x, y, z, effect | fx, frame?, scale?, alpha?, color?,
-- ref? } (x, y in world tiles, z in tiles above the floor of `level`). Every frame the renderer
-- turns them into pooled draw items (Collect) that are sorted with the people, so smoke behind a
-- person stays behind them. Sprites come from the art manifest: SS.Art.effects[name] = { n, fps,
-- blend, h, prio } and sprites "fx:<name>:<frame>". Unknown names draw the counted placeholder.
-- Animated pool and pond water (tile frames swapped in place, no relayout) also lives here.
local _, SS = ...
local FX = SS.RenderFx or {}
SS.RenderFx = FX
local floor, min = math.floor, math.min

FX.MAX = 64            -- effect items per frame (optional ones are dropped first beyond this)
FX.dropped = 0         -- items dropped by the cap in the last frame
FX.unknown = {}        -- effect names without art (counted through SS.Render.Use as well)

-- Defaults when the manifest has no entry (or is an older one). prio 1 = essential feedback.
FX.DEFAULTS = {
    fire = { n = 8, fps = 10, h = 0.9, prio = 1 },
    hearth_fire = { n = 8, fps = 10, h = 0.5, prio = 2 },
    smoke = { n = 8, fps = 6, h = 1.2, prio = 1 },
    sparks = { n = 8, fps = 12, h = 0.5, prio = 1, blend = "ADD" },
    water = { n = 8, fps = 8, h = 0.4, prio = 2 },
    water_spray = { n = 8, fps = 12, h = 1.0, prio = 1 },
    steam = { n = 8, fps = 6, h = 0.8, prio = 2 },
    zzz = { n = 8, fps = 3, h = 0.6, prio = 3 },
    hearts = { n = 8, fps = 4, h = 0.6, prio = 3 },
    notes = { n = 8, fps = 4, h = 0.6, prio = 3 },
    stink = { n = 8, fps = 4, h = 0.7, prio = 3 },
    alarm_flash = { n = 4, fps = 4, h = 0.4, prio = 1, blend = "ADD" },
    ghost_glow = { n = 8, fps = 6, h = 1.6, prio = 2, blend = "ADD" },
    splash = { n = 8, fps = 10, h = 0.6, prio = 2 },
    ripple = { n = 8, fps = 6, h = 0.1, prio = 3 },
    dust = { n = 6, fps = 10, h = 0.2, prio = 3 },
}
FX.ALIAS = { fx_fire = "fire", flames = "fire", spark = "sparks", heart = "hearts", music = "notes",
    sleep = "zzz", stench = "stink", spray = "water_spray", leak = "water", puddle_drip = "water",
    dust_puff = "dust", thud = "dust", poof = "dust" }

local function def(name)
    local A = SS.Art
    local d = A and A.effects and A.effects[name]
    return d or FX.DEFAULTS[name]
end
FX.Def = def

-- Sprite names per effect and frame, built once (no per-frame strings).
local names = {}
local function fxName(name, f)
    local t = names[name]
    if not t then t = {}; names[name] = t end
    local s = t[f]
    if not s then s = "fx:" .. name .. ":" .. f; t[f] = s end
    return s
end
FX.Name = fxName

local function now(world)
    local gt = rawget(_G, "GetTime")
    return (gt and gt()) or (world.time or 0) * 0.5
end

-- Scratch list the providers append to (reused every frame).
local raw, order = {}, {}
local stamp = 0

-- Collect provider items and append pooled draw items to `out`. Returns the new item count.
-- dynItem(n) -> pooled item; trimLayers(it, n); setBox(box, u0, v0, z0, u1, v1, z1).
function FX.Collect(world, cam, out, count, dynItem, trimLayers, setBox)
    local R = SS.Render
    for q = #raw, 1, -1 do raw[q] = nil end
    for _, fn in ipairs(R.effects or {}) do
        local ok, err = pcall(fn, world, cam, raw)
        if not ok then
            FX.lastError = tostring(err)
        end
    end
    local n = #raw
    FX.dropped = 0
    if n == 0 then return count end
    local lot = world.lot
    local G, W = SS.Grid, SS.World
    local top = R.VisibleLevels(world, cam)
    local t = now(world)
    -- priority order (stable: provider order within a priority)
    for q = #order, 1, -1 do order[q] = nil end
    for p = 1, 3 do
        for q = 1, n do
            local e = raw[q]
            if type(e) == "table" then
                local name = e.effect or e.fx
                name = FX.ALIAS[name] or name
                local d = name and def(name)
                local pr = (d and d.prio) or 2
                if pr == p then order[#order + 1] = e end
            end
        end
    end
    local used = 0
    local Sp = SS.Art.sprites
    -- reduced detail (SS.Perf.quality) drops the decorative effects (priority 3: zzz, hearts, notes,
    -- stink, ripples); reduced motion holds pulsing additive effects on one frame
    local reduced = R.Reduced and R.Reduced()
    local calm = world.settings and world.settings.reducedMotion
    for q = 1, #order do
        local e = order[q]
        local lv = e.level or 0
        local dq = def(FX.ALIAS[e.effect or e.fx] or e.effect or e.fx)
        if reduced and dq and (dq.prio or 2) >= 3 then
            FX.dropped = FX.dropped + 1
        elseif lv <= top and type(e.x) == "number" and type(e.y) == "number" then
            if used >= FX.MAX then
                FX.dropped = FX.dropped + 1
            else
                local name = e.effect or e.fx
                name = FX.ALIAS[name] or name
                local d = def(name)
                local sname
                if e.sprite and Sp[e.sprite] then
                    sname = e.sprite
                elseif d then
                    local nf = d.n or 1
                    local f = e.frame and (floor(e.frame) % nf) or (floor(t * (d.fps or 6)) % nf)
                    if calm and d.blend == "ADD" and not e.frame then f = 0 end
                    sname = fxName(name, f)
                    if not Sp[sname] then sname = fxName(name, 0) end
                end
                if not (sname and Sp[sname]) then
                    if name then FX.unknown[name] = true end
                    sname = R.Use(sname or ("fx:" .. tostring(name)))
                end
                if sname then
                    used = used + 1
                    count = count + 1
                    local it = dynItem(count)
                    local u, v = G.vpos(e.x, e.y, cam.r, lot.w, lot.h)
                    local gz = 0
                    if lv == 0 and W.GroundZ then
                        local ok, g = pcall(W.GroundZ, world, e.x, e.y)
                        if ok and type(g) == "number" then gz = g end
                    end
                    local z = lv * W.STORY + gz + (e.z or 0)
                    local x, y = R.ToCanvas(world, cam, u, v, z)
                    it.kind, it.ref, it.level, it.x, it.y, it.key = "fx", e.ref or name, lv, x, y, lv * 1000 + u + v + 0.02
                    it.onObj, it.occ, it.fkey, it.pose = nil, nil, nil, nil
                    it.shadowLayer, it.slot, it.age = nil, nil, nil
                    local l = it.layers[1]
                    if not l then l = {}; it.layers[1] = l end
                    local c = e.color
                    l[1], l[2], l[3], l[4] = sname, c and c[1] or 1, c and c[2] or 1, c and c[3] or 1
                    l[5], l[6], l[7] = nil, nil, e.alpha
                    l[8], l[9], l[10], l[11] = nil, nil, nil, nil
                    l[12] = (e.scale and e.scale ~= 1) and e.scale or nil
                    l[13] = d and d.blend or nil
                    l[14] = nil
                    trimLayers(it, 1)
                    local h = (d and d.h or 0.5) * (e.scale or 1)
                    local rad = 0.2 * (e.scale or 1)
                    setBox(it.box, u - rad, v - rad, z, u + rad, v + rad, z + h)
                    it.box.tie = 3e6 + count
                    out[#out + 1] = it
                end
            end
        end
    end
    if R.stats then R.stats.fx, R.stats.fxDropped = used, FX.dropped end
    return count
end

---------------------------------------------------------------------------------------------------
-- Water animation: pool water ("poolwater:<f>") and ponds ("pond:<id>:<mask>:<f>") are ground
-- tiles; their frame is swapped in place a few times a second (only the water textures change).
---------------------------------------------------------------------------------------------------
FX.WATER_FPS = 3
local waterFrameNames = {}
-- names[prefix][f] = prefix .. f (built once)
function FX.FrameName(prefix, f)
    local t = waterFrameNames[prefix]
    if not t then t = {}; waterFrameNames[prefix] = t end
    local s = t[f]
    if not s then s = prefix .. f; t[f] = s end
    return s
end

local function frames(kind)
    local A = SS.Art
    local w = A and A.water
    if kind == "pond" then return (w and w.pondFrames) or 2 end
    return (w and w.frames) or 4
end
FX.WaterFrames = frames

-- The current water frame (0-based) for a kind ("pool" | "pond"); the layout uses frame 0 when
-- no clock is available.
function FX.WaterFrame(kind, t)
    local gt = rawget(_G, "GetTime")
    t = t or (gt and gt()) or 0
    return floor(t * FX.WATER_FPS) % frames(kind or "pool")
end
SS.Render = SS.Render or {}
SS.Render.WaterFrame = function(kind, t) return FX.WaterFrame(kind, t) end

-- Swap the frames of the laid-out water textures: entries { tex, e } where e.anim = prefix,
-- e.animKind = "pool" | "pond". Returns true when a swap happened.
FX.lastWater = -1
function FX.AnimateWater(list, zoom, setSprite)
    if not list or #list == 0 then return false end
    local gt = rawget(_G, "GetTime")
    local t = (gt and gt()) or 0
    local fpool = FX.WaterFrame("pool", t)
    local fpond = FX.WaterFrame("pond", t)
    local key = fpool * 16 + fpond
    if key == FX.lastWater then return false end
    FX.lastWater = key
    local Sp = SS.Art.sprites
    for q = 1, #list do
        local rec = list[q]
        local e = rec[2]
        local nm = FX.FrameName(e.anim, e.animKind == "pond" and fpond or fpool)
        if Sp[nm] then
            local tn = e.tint
            setSprite(rec[1], nm, zoom, e.x, e.y, tn[1], tn[2], tn[3], e.alpha or 1)
        end
    end
    return true
end

return FX
