-- Build-mode visual feedback: plan previews (valid/invalid cells, wall segments, diagonal cells,
-- terrain corners, landings, roof sections), hover highlights and the grid overlay.
-- Owner: build module (see ARCHITECTURE.md §10 "Tool feedback", docs/modules/build.md).
--
-- Everything goes through the renderer's extension API:
--   SS.Render.SetCellMarks(list)   coloured cell highlights { i, j, level, color = {r,g,b,a} }
--   SS.Render.RegisterStatic(fn)   extra draw items (ghost wall segments along previewed edges)
-- The functions that turn a plan into marks and items are pure Lua (BF.MarksFor, BF.EdgeItems) so
-- they are tested offline; drawing them is the renderer's job.
local _, SS = ...
local G, W = SS.Grid, SS.World
local BF = { grid = false, marks = nil, edges = nil, level = 0 }
SS.BuildFx = BF

BF.COL = {
    ok = { 0.30, 0.85, 0.42, 0.45 },
    bad = { 0.92, 0.26, 0.20, 0.55 },
    erase = { 0.96, 0.62, 0.18, 0.50 },
    landing = { 0.30, 0.62, 0.96, 0.50 },
    clear = { 0.96, 0.90, 0.30, 0.40 },
    roof = { 0.72, 0.52, 0.92, 0.35 },
    hover = { 1.00, 1.00, 1.00, 0.28 },
    corner = { 0.55, 0.85, 0.95, 0.45 },
    gridA = { 1, 1, 1, 0.07 },
    gridB = { 1, 1, 1, 0.02 },
}

-- Faint copies of the line colours (cells beside a previewed edge), made once.
local FAINT = {}
for _, id in ipairs({ "ok", "bad", "erase" }) do
    local c = BF.COL[id]
    FAINT[id] = { c[1], c[2], c[3], c[4] * 0.45 }
end

local function mark(list, i, j, level, col)
    list[#list + 1] = { i = i, j = j, level = level or 0, color = col }
end

-- Fill marks for a plan through put(i, j, level, color). Shared by BF.MarksFor (a fresh list,
-- for tests and tools) and BF.Show (reused buffers, no table churn while the cursor moves).
local seenCorner = {}
local function fillPlan(put, plan, level)
    if not plan then return end
    local pv = plan.preview or {}
    local failed = not plan.ok
    local cells, diag, corners, edges = pv.cells, pv.diag, pv.corners, pv.edges
    local nEdges = edges and #edges or 0
    for n = 1, cells and #cells or 0 do
        local c = cells[n]
        local col = BF.COL.ok
        if c.bad or (failed and not c.landing and not c.clear and nEdges == 0) then col = BF.COL.bad
        elseif c.erase then col = BF.COL.erase
        elseif c.landing then col = failed and BF.COL.bad or BF.COL.landing
        elseif c.clear then col = BF.COL.clear
        elseif c.roof then col = BF.COL.roof end
        put(c.i, c.j, c.level or level, col)
    end
    for n = 1, diag and #diag or 0 do
        local d = diag[n]
        put(d.i, d.j, d.level or level, (d.bad or failed) and BF.COL.bad or (d.erase and BF.COL.erase or BF.COL.ok))
    end
    -- terrain corners: highlight the (up to 4) cells touching each changed corner once
    if corners and #corners > 0 then
        for k in pairs(seenCorner) do seenCorner[k] = nil end
        for n = 1, #corners do
            local c = corners[n]
            if not c.area then
                for dj = -1, 0 do
                    for di = -1, 0 do
                        local i, j = c.i + di, c.j + dj
                        local key = (j + 2) * 65536 + (i + 2)
                        if not seenCorner[key] then
                            seenCorner[key] = true
                            put(i, j, 0, failed and BF.COL.bad or BF.COL.corner)
                        end
                    end
                end
            end
        end
    end
    -- edges: the cells on both sides get a faint mark too (so a line reads even without ghosts)
    for n = 1, nEdges do
        local e = edges[n]
        local _, _, _, ai, aj, bi, bj = G.parseEdge(e.key)
        local faint = (e.bad or failed) and FAINT.bad or (e.erase and FAINT.erase or FAINT.ok)
        put(ai, aj, e.level or level, faint)
        put(bi, bj, e.level or level, faint)
    end
end

-- Cell marks for a plan preview (a fresh list). Bounded by the plan's own size.
function BF.MarksFor(plan, level)
    local out = {}
    fillPlan(function(i, j, lv, col) mark(out, i, j, lv, col) end, plan, level)
    return out
end

-- Grid overlay: one faint mark per cell of the current level, alternating shades. Each carries
-- grid = true so a renderer with a line-grid tile ("fx:grid", docs/art_requests/build.md) can draw
-- the tile outline instead of a filled highlight.
function BF.GridMarks(lot, level)
    local out = {}
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do
            mark(out, i, j, level, ((i + j) % 2 == 0) and BF.COL.gridA or BF.COL.gridB)
            out[#out].grid = true
        end
    end
    return out
end

-- The list handed to the renderer is rebuilt in place on every preview: its mark tables come
-- from a pool that only grows (to the largest preview seen, grid included), so moving the cursor
-- allocates nothing once the pool is warm.
local buf, pool, used = {}, {}, 0
local function put(i, j, level, col, grid)
    used = used + 1
    local m = pool[used]
    if not m then m = {}; pool[used] = m end
    m.i, m.j, m.level, m.color, m.grid = i, j, level or 0, col, grid
    buf[used] = m
end
local function putPlain(i, j, level, col) put(i, j, level, col, nil) end
BF.PoolSize = function() return #pool end

-- Ghost wall segments for previewed edges, in the renderer's draw-item format:
-- { key, x, y, ref, kind = "buildfx", level, layers = { { sprite, r, g, b } } }.
function BF.EdgeItems(world, cam, edges)
    local items = {}
    if not edges or #edges == 0 then return items end
    local lot, Art = world.lot, SS.Art
    local r = cam.r or 0
    for _, e in ipairs(edges) do
        local axis, i, j = G.parseEdge(e.key)
        local x1, y1, x2, y2
        if axis == "x" then x1, y1, x2, y2 = i, j, i + 1, j else x1, y1, x2, y2 = i, j, i, j + 1 end
        local u1, v1 = G.vpos(x1, y1, r, lot.w, lot.h)
        local u2, v2 = G.vpos(x2, y2, r, lot.w, lot.h)
        local vaxis, mu, mv
        if math.abs(v1 - v2) < 1e-6 then vaxis, mu, mv = "x", math.min(u1, u2) + 0.5, v1
        else vaxis, mu, mv = "y", u1, math.min(v1, v2) + 0.5 end
        local kind = e.kind
        if kind == "erase" or kind == "paint" then kind = "wall" end
        local sp = Art.walls and (Art.walls[(kind or "wall") .. ":full:" .. vaxis] or Art.walls["wall:full:" .. vaxis])
        local level = e.level or 0
        if sp and sp.wall then
            local col = e.bad and BF.COL.bad or (e.erase and BF.COL.erase or BF.COL.ok)
            local x, y = SS.Render.ToCanvas(world, cam, mu, mv, level * W.STORY)
            items[#items + 1] = { key = level * 1000 + mu + mv + 0.02, x = x, y = y, ref = "fx:" .. e.key, kind = "buildfx", level = level,
                layers = { { sp.wall, col[1], col[2], col[3] } }, alpha = 0.6 }
        end
    end
    return items
end

-- Current preview state set by the build UI.
function BF.Show(world, plan, hover, level)
    BF.plan, BF.level = plan, level or 0
    local before = used
    used = 0
    if BF.grid and world then
        local lot = world.lot
        local lv = level or 0
        for j = 0, lot.h - 1 do
            for i = 0, lot.w - 1 do put(i, j, lv, ((i + j) % 2 == 0) and BF.COL.gridA or BF.COL.gridB, true) end
        end
    end
    fillPlan(putPlain, plan, level)
    if hover then for n = 1, #hover do local h = hover[n]; put(h[1], h[2], h[3] or level, BF.COL.hover, nil) end end
    for n = used + 1, before do buf[n] = nil end
    BF.marks = buf
    BF.edges = plan and plan.preview and plan.preview.edges or nil
    if SS.Render and SS.Render.SetCellMarks then SS.Render.SetCellMarks(used > 0 and buf or nil) end
end

function BF.Clear()
    BF.plan, BF.marks, BF.edges = nil, nil, nil
    if SS.Render and SS.Render.SetCellMarks then SS.Render.SetCellMarks(nil) end
end

function BF.SetGrid(on, world, level)
    BF.grid = on and true or false
    BF.Show(world, BF.plan, nil, level or BF.level)
end

-- Ghost segments join the renderer's static items while a preview is up.
if SS.Render and SS.Render.RegisterStatic then
    SS.Render.RegisterStatic(function(world, cam, items)
        if not BF.edges or not (SS.UI and SS.UI.mode == "build") then return end
        for _, it in ipairs(BF.EdgeItems(world, cam, BF.edges)) do items[#items + 1] = it end
    end)
end
