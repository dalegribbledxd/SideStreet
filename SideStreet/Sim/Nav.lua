-- SideStreet navigation: A* over (level, cell) nodes, 4-connected, no corner cutting.
-- Owner: household-core.
-- Walls sit on tile edges (doors are routes, windows are not); object footprints block
-- cells; upper-level cells need a floor. Stairs link their bottom cell on one level to
-- their top landing on the next, at a fixed traversal cost.
-- Work is bounded: a per-step search budget (Tuning.pathsPerStep), a per-search expansion cap,
-- and a static reachability map (regions) that rejects impossible goals without searching.
-- Search scratch arrays are reused between searches (stamped) and edge keys are cached, so a
-- search allocates only the returned path; goals behind locks, inside or behind a bathroom in use,
-- or in a room the pass hooks keep someone out of fail before any search (Nav.LockReachable,
-- Nav.RoomRule).
local _, SS = ...
local G, W = SS.Grid, SS.World
local Nav = {}
SS.Nav = Nav

Nav.stats = { searches = 0, expanded = 0, rejected = 0, deferred = 0, failed = 0, fenced = 0 }
Nav.STAIR_COST = 4
Nav.budget = 1e9       -- searches left this step (Sim.Step resets it)

Nav.expandLeft = 1e9   -- node expansions left this step
function Nav.NewStep()
    Nav.budget = SS.Tuning.pathsPerStep or 4
    Nav.expandLeft = SS.Tuning.pathExpandPerStep or 6000
end
function Nav.HasBudget() return Nav.budget > 0 end

-- scratch (reused) ---------------------------------------------------------------------------
local DI, DJ = { 0, -1, 0, 1 }, { 1, 0, -1, 0 } -- G.DIRS order 0..3
local NO_KEYS = {}
local EKD = { 2, 1, 3, 0 } -- the same steps as World's edge-key directions (0 = +i, 1 = -i, 2 = +j, 3 = -j)
local stamp = 0
local sStamp, sCost, sCame, sVia, sClosed = {}, {}, {}, {}, {}
local hNode, hF, hN = {}, {}, 0

local function heapPush(node, f)
    hN = hN + 1
    local n = hN
    hNode[n], hF[n] = node, f
    while n > 1 do
        local p = math.floor(n / 2)
        if hF[p] <= hF[n] then break end
        hNode[p], hNode[n] = hNode[n], hNode[p]
        hF[p], hF[n] = hF[n], hF[p]
        n = p
    end
end

local function heapPop()
    local top = hNode[1]
    hNode[1], hF[1] = hNode[hN], hF[hN]
    hN = hN - 1 -- slots past hN keep stale numbers (never read), so the arrays never shrink and regrow
    local n = 1
    while true do
        local l, r, s = n * 2, n * 2 + 1, n
        if l <= hN and hF[l] < hF[s] then s = l end
        if r <= hN and hF[r] < hF[s] then s = r end
        if s == n then break end
        hNode[s], hNode[n] = hNode[n], hNode[s]
        hF[s], hF[n] = hF[n], hF[s]
        n = s
    end
    return top
end

-- Stair links for the current lot: from key -> list of {toKey, stairId, up}
local function stairLinks(world)
    local rt = SS.RT
    if rt.links then return rt.links end
    local lot = world.lot
    local plane = lot.w * lot.h
    local links = {}
    for _, st in ipairs(rt.stairs or {}) do
        local lv = st.level
        if lv + 1 < W.LEVELS and W.InLot(lot, st.bottom[1], st.bottom[2]) and W.InLot(lot, st.top[1], st.top[2]) then
            local a = lv * plane + st.bottom[2] * lot.w + st.bottom[1]
            local b = (lv + 1) * plane + st.top[2] * lot.w + st.top[1]
            links[a] = links[a] or {}; links[a][#links[a] + 1] = { b, st.id, true }
            links[b] = links[b] or {}; links[b][#links[b] + 1] = { a, st.id, false }
        end
    end
    rt.links = links
    return links
end
Nav.StairLinks = stairLinks

-- Static regions: connected components over walls/doors, blocked cells and stairs (no pass
-- hooks, no actors). Rebuilt with SS.RT (World.Rebuild), i.e. only after edits.
function Nav.Regions(world)
    local rt = SS.RT
    if rt.regions and rt.regionsLot == world.lot then return rt.regions end
    local lot = world.lot
    local w, plane = lot.w, lot.w * lot.h
    local reg = {}
    local links = stairLinks(world)
    local nextId = 0
    for l = 0, W.LEVELS - 1 do
        for j = 0, lot.h - 1 do
            for i = 0, w - 1 do
                local k = l * plane + j * w + i
                if not reg[k] and not W.Blocked(world, l, i, j) then
                    nextId = nextId + 1
                    reg[k] = nextId
                    local stack, sn = { k }, 1
                    while sn > 0 do
                        local cur = stack[sn]; stack[sn] = nil; sn = sn - 1
                        local cl = math.floor(cur / plane)
                        local r = cur % plane
                        local ci, cj = r % w, math.floor(r / w)
                        for d = 0, 3 do
                            local dv = G.DIRS[d]
                            local ni, nj = ci + dv[1], cj + dv[2]
                            if W.InLot(lot, ni, nj) then
                                local nk = cl * plane + nj * w + ni
                                if not reg[nk] and not W.Blocked(world, cl, ni, nj) and W.CanStepStatic(world, cl, ci, cj, ni, nj) then
                                    reg[nk] = nextId
                                    sn = sn + 1; stack[sn] = nk
                                end
                            end
                        end
                        local lk = links[cur]
                        if lk then
                            for n = 1, #lk do
                                local nk = lk[n][1]
                                local nl = math.floor(nk / plane)
                                local nr = nk % plane
                                if not reg[nk] and not W.Blocked(world, nl, nr % w, math.floor(nr / w)) then
                                    reg[nk] = nextId
                                    sn = sn + 1; stack[sn] = nk
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    rt.regions, rt.regionsLot = reg, world.lot
    return reg
end

function Nav.RegionAt(world, level, i, j)
    local lot = world.lot
    if not W.InLot(lot, i, j) then return nil end
    return Nav.Regions(world)[(level or 0) * lot.w * lot.h + j * lot.w + i]
end

-- Static reachability: can any goal be reached from the start ignoring people and hooks?
function Nav.Reachable(world, si, sj, slevel, goals)
    local start = Nav.RegionAt(world, slevel or 0, si, sj)
    if not start then return true end -- standing somewhere odd (on furniture): let A* decide
    for n = 1, #goals do
        local g = goals[n]
        if Nav.RegionAt(world, g[3] or 0, g[1], g[2]) == start then return true end
    end
    return false
end

-- Lock-aware reachability ----------------------------------------------------------------------
-- A locked door only stops people *entering* the room it guards (World lock rules); leaving is
-- always allowed. For each set of locks that stop someone (a bit mask over the lock kinds) the lot
-- is split into components with those doors closed, plus one-way exits out of the guarded rooms.
-- A goal whose component can't be reached that way can't be reached by the full search either
-- (every other hook only removes steps), so it fails at once instead of exhausting the search.
-- Rebuilt with SS.RT (World.Rebuild) and when a lock changes (World.SetDoorLock, or a changed
-- `wall.locked` noticed by lockList).
local LOCK_BIT = { all = 1, household = 2, adults = 4, staff = 8 }
local LOCK_KINDS = { "all", "household", "adults", "staff" }
local function lockBit(lock) return LOCK_BIT[(lock == true) and "household" or lock] or 0 end

-- The locked openings the cached maps were built from. Locks are meant to change through
-- World.SetDoorLock (which drops the caches); a lock changed or removed by writing `wall.locked`
-- directly is caught here too (the list is checked against the walls on every use), so a cached
-- map is never stricter than the walls. A lock added directly is simply not used by the pre-check
-- until the next rebuild: the search itself still honours it.
local function lockList(world)
    local rt, lot = SS.RT, world.lot
    local list = rt.lockList
    if list and rt.lockListLot == lot then
        for n = 1, #list do
            local e = list[n]
            local lw = lot.walls[e[1]]
            local wl = lw and lw[e[2]]
            if wl ~= e[3] or wl.locked ~= e[4] then list = nil; break end
        end
        if list then return list end
    end
    list = { set = {} }
    for l = 0, W.LEVELS - 1 do
        for key, wl in pairs(lot.walls[l] or {}) do
            if wl.locked and W.OPENINGS[wl.kind] then list[#list + 1] = { l, key, wl, wl.locked }; list.set[wl] = true end
        end
    end
    rt.lockList, rt.lockListLot, rt.lockComps = list, lot, nil
    return list
end

local function lockMask(world, who)
    local m = 0
    for n = 1, #LOCK_KINDS do
        local kind = LOCK_KINDS[n]
        if W.LockBlocks(world, kind, who) then m = m + LOCK_BIT[kind] end
    end
    return m
end

-- Solid for the lock map: furniture, missing floor, stair wells. Blocked hooks are dynamic and
-- are left out, so the cached map can only be more permissive than a search (never wrong).
local function solid(world, l, i, j)
    local lot, rt = world.lot, SS.RT
    local k = j * lot.w + i + 1
    if rt.occ[l][k] then return true end
    if l > 0 and (not W.FloorAt(lot, l, i, j) or rt.well[l][k]) then return true end
    return false
end

local function lockComps(world, mask)
    local rt = SS.RT
    local set = lockList(world).set -- only the listed locks: the list is what gets re-checked
    local lc = rt.lockComps
    if not lc or lc.lot ~= world.lot then lc = { lot = world.lot }; rt.lockComps = lc end
    if lc[mask] then return lc[mask] end
    local lot = world.lot
    local w, plane = lot.w, lot.w * lot.h
    local links = stairLinks(world)
    local comp, closed, nextId = {}, {}, 0
    for l = 0, W.LEVELS - 1 do
        local walls = lot.walls[l] or {}
        for j = 0, lot.h - 1 do
            for i = 0, w - 1 do
                local k = l * plane + j * w + i
                if not comp[k] and not solid(world, l, i, j) then
                    nextId = nextId + 1
                    comp[k] = nextId
                    local stack, sn = { k }, 1
                    while sn > 0 do
                        local cur = stack[sn]; stack[sn] = nil; sn = sn - 1
                        local cl = math.floor(cur / plane)
                        local r = cur % plane
                        local ci, cj = r % w, math.floor(r / w)
                        local cw = lot.walls[cl] or walls
                        for d = 0, 3 do
                            local dv = G.DIRS[d]
                            local ni, nj = ci + dv[1], cj + dv[2]
                            if ni >= 0 and nj >= 0 and ni < w and nj < lot.h then
                                local nk = cl * plane + nj * w + ni
                                if not comp[nk] and not solid(world, cl, ni, nj) then
                                    local wl = cw[W.EdgeKey(ci, cj, ni, nj)]
                                    local open = not wl or W.OPENINGS[wl.kind]
                                    local b = open and wl and set[wl] and lockBit(wl.locked) or 0
                                    if b > 0 and math.floor(mask / b) % 2 == 1 and W.GuardedRoom(world, cl, ci, cj, ni, nj) ~= 0 then
                                        open = false
                                        closed[#closed + 1] = { cl, ci, cj, ni, nj }
                                    end
                                    if open then
                                        comp[nk] = nextId
                                        sn = sn + 1; stack[sn] = nk
                                    end
                                end
                            end
                        end
                        local lk = links[cur]
                        if lk then
                            for n = 1, #lk do
                                local nk = lk[n][1]
                                local nl = math.floor(nk / plane)
                                local nr = nk % plane
                                if not comp[nk] and not solid(world, nl, nr % w, math.floor(nr / w)) then
                                    comp[nk] = nextId
                                    sn = sn + 1; stack[sn] = nk
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- one-way exits: from the guarded (inside) side of a closed door to the other side
    local exits = {}
    for n = 1, #closed do
        local e = closed[n]
        local l, i, j, ni, nj = e[1], e[2], e[3], e[4], e[5]
        local guarded = W.GuardedRoom(world, l, i, j, ni, nj)
        local inI, inJ, outI, outJ = i, j, ni, nj
        if W.RoomAt(world, l, ni, nj) == guarded then inI, inJ, outI, outJ = ni, nj, i, j end
        local a, b = comp[l * plane + inJ * w + inI], comp[l * plane + outJ * w + outI]
        if a and b and a ~= b then
            local ex = exits[a] or {}
            exits[a] = ex
            local dup = false
            for m = 1, #ex do if ex[m] == b then dup = true; break end end
            if not dup then ex[#ex + 1] = b end
        end
    end
    local c = { comp = comp, exits = exits, n = nextId }
    lc[mask] = c
    return c
end

-- scratch for the component search
local cSeen, cStamp, cQueue = {}, 0, {}
-- Can `who` get from the start to any goal given the locks that stop them? (true when unsure)
function Nav.LockReachable(world, si, sj, slevel, goals, who)
    if not who or #lockList(world) == 0 then return true end
    local mask = lockMask(world, who)
    if mask == 0 then return true end
    local c = lockComps(world, mask)
    local lot = world.lot
    local w, plane = lot.w, lot.w * lot.h
    local s = c.comp[(slevel or 0) * plane + sj * w + si]
    if not s then return true end
    cStamp = cStamp + 1
    local S = cStamp
    cSeen[s] = S
    local qn, qh = 1, 1
    cQueue[1] = s
    while qh <= qn do
        local cur = cQueue[qh]; qh = qh + 1
        for n = 1, #goals do
            local g = goals[n]
            if W.InLot(lot, g[1], g[2]) and c.comp[(g[3] or 0) * plane + g[2] * w + g[1]] == cur then return true end
        end
        local ex = c.exits[cur]
        if ex then
            for n = 1, #ex do
                local b = ex[n]
                if cSeen[b] ~= S then cSeen[b] = S; qn = qn + 1; cQueue[qn] = b end
            end
        end
    end
    return false
end

-- Every goal lies in a room someone else is using privately (a bathroom in use) and the mover is
-- not inside it: no search can get there until they leave.
local function privateGoals(world, si, sj, slevel, goals, who)
    local A = SS.Actions
    if not (who and A and A.privacy and next(A.privacy)) then return false end
    local startRoom = W.RoomAt(world, slevel, si, sj)
    for n = 1, #goals do
        local g = goals[n]
        local gl = g[3] or 0
        local room = W.RoomAt(world, gl, g[1], g[2])
        local holder = room ~= 0 and A.PrivacyHolder(world, gl, room)
        if not holder or holder == who.id or (room == startRoom and gl == slevel) then return false end
    end
    return true
end

-- Door rules: the lot as a graph of "door-free pieces" (cells joined without crossing any wall
-- record, door or not, and without passing furniture, a missing floor or a stair well) whose edges
-- are the openings between two pieces (a door, gate or arch with free cells on both sides) and
-- the stair links. Every pass hook (locks, bathroom privacy, other modules' rules such as
-- visitors' private rooms and locked doors) is asked about each opening in the direction of
-- travel, exactly as the search asks it, so a goal no allowed sequence of openings reaches fails
-- at once, whichever module's rule stops it. Rules on steps inside a piece (staff-only cells,
-- fire) and furniture that other modules block on the fly are not seen here: the check can only
-- say "no way" when the search would find none, never the reverse. Built with SS.RT (after each
-- rebuild, or at load by Nav.Prepare) and asked lazily: openings are tried as the walk reaches
-- them, and a goal in the start's own piece needs no hook at all.
local function roomGraph(world)
    local rt = SS.RT
    local rg = rt.roomGraph
    if rg and rt.roomGraphLot == world.lot then return rg end
    local lot = world.lot
    local w, h, plane = lot.w, lot.h, lot.w * lot.h
    local piece, nPieces = {}, 0
    for l = 0, W.LEVELS - 1 do
        local walls = lot.walls[l] or {}
        for j = 0, h - 1 do
            for i = 0, w - 1 do
                local k = l * plane + j * w + i
                if not piece[k] and not solid(world, l, i, j) then
                    nPieces = nPieces + 1
                    piece[k] = nPieces
                    local stack, sn = { k }, 1
                    while sn > 0 do
                        local cur = stack[sn]; stack[sn] = nil; sn = sn - 1
                        local r = cur - l * plane
                        local ci, cj = r % w, math.floor(r / w)
                        for d = 1, 4 do
                            local ni, nj = ci + DI[d], cj + DJ[d]
                            if ni >= 0 and nj >= 0 and ni < w and nj < h then
                                local nk = l * plane + nj * w + ni
                                if not piece[nk] and not walls[W.EdgeKey(ci, cj, ni, nj)] and not solid(world, l, ni, nj) then
                                    piece[nk] = nPieces
                                    sn = sn + 1; stack[sn] = nk
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    rg = { piece = piece, n = 0, l = {}, i = {}, j = {}, ni = {}, nj = {}, key = {}, to = {}, byNode = {} }
    local function add(l, i, j, ni, nj, key, from, to)
        local n = rg.n + 1
        rg.n = n
        rg.l[n], rg.i[n], rg.j[n], rg.ni[n], rg.nj[n], rg.key[n], rg.to[n] = l, i, j, ni, nj, key or false, to
        local lst = rg.byNode[from]
        if not lst then lst = {}; rg.byNode[from] = lst end
        lst[#lst + 1] = n
    end
    for l = 0, W.LEVELS - 1 do
        local walls = lot.walls[l]
        if walls then
            -- sorted keys: the graph (and so the order openings are tried) is the same every time
            local keys = {}
            for key, wl in pairs(walls) do if W.OPENINGS[wl.kind] then keys[#keys + 1] = key end end
            table.sort(keys)
            for n = 1, #keys do
                local key = keys[n]
                local _, _, _, ai, aj, bi, bj = G.parseEdge(key)
                if W.InLot(lot, ai, aj) and W.InLot(lot, bi, bj) then
                    local pa, pb = piece[l * plane + aj * w + ai], piece[l * plane + bj * w + bi]
                    if pa and pb and pa ~= pb then
                        add(l, ai, aj, bi, bj, key, pa, pb)
                        add(l, bi, bj, ai, aj, key, pb, pa)
                    end
                end
            end
        end
    end
    -- stair links (the search asks no pass hook on a flight, only that both ends are free)
    local links = stairLinks(world)
    local froms = {}
    for from in pairs(links) do froms[#froms + 1] = from end
    table.sort(froms)
    for n = 1, #froms do
        local from = froms[n]
        local pf = piece[from]
        for m = 1, #links[from] do
            local pt = piece[links[from][m][1]]
            if pf and pt and pf ~= pt then add(0, 0, 0, 0, 0, nil, pf, pt) end
        end
    end
    rt.roomGraph, rt.roomGraphLot = rg, lot
    return rg
end
Nav.RoomGraph = roomGraph

local rgSeen, rgGoal, rgStamp, rgQueue = {}, {}, 0, {}
-- Walk the door graph from the start's piece; true when a goal's piece is reached. skip = a set of
-- pass hooks to leave out (the privacy hooks, to tell "wait for the bathroom" from "not allowed").
local function roomsReach(world, rg, start, S, who, skip)
    local lot = world.lot
    local hooks = W.passHooks
    local nHooks = #hooks
    local OPEN = W.OPENINGS
    rgStamp = rgStamp + 1
    local V = rgStamp
    rgSeen[start] = V
    rgQueue[1] = start
    local qh, qn = 1, 1
    while qh <= qn do
        local cur = rgQueue[qh]; qh = qh + 1
        if rgGoal[cur] == S then return true end
        local lst = rg.byNode[cur]
        if lst then
            for m = 1, #lst do
                local e = lst[m]
                local to = rg.to[e]
                if rgSeen[to] ~= V then
                    local ok = true
                    local key = rg.key[e]
                    if key then
                        local l = rg.l[e]
                        local walls = lot.walls[l]
                        local wl = walls and walls[key]
                        if wl and not OPEN[wl.kind] then ok = false end
                        if ok then
                            local i, j, ni, nj = rg.i[e], rg.j[e], rg.ni[e], rg.nj[e]
                            for hn = 1, nHooks do
                                local fn = hooks[hn]
                                if not (skip and skip[fn]) and fn(world, l, i, j, ni, nj, wl, who) == false then ok = false; break end
                            end
                        end
                    end
                    if ok then
                        rgSeen[to] = V
                        qn = qn + 1
                        rgQueue[qn] = to
                    end
                end
            end
        end
    end
    return false
end

-- nil when the openings allow a way (or the check can't tell); otherwise why not: "privacy" (only
-- a bathroom in use stands in the way: waiting helps) or "rule" (a lock or another rule). A hook
-- registered with { privacy = true } is a privacy rule (household-core's bathroom privacy). When
-- the way stays shut without the privacy hooks while a bathroom is in use, another module's hook
-- may be keeping people out of that bathroom too (visitors keep guests out of an occupied one):
-- the check can't tell waiting from refusal then, and leaves it to the search (nil).
local rrStamp = 0
local function roomRule(world, si, sj, slevel, goals, who)
    local lot = world.lot
    if not W.InLot(lot, si, sj) then return nil end
    local w, plane = lot.w, lot.w * lot.h
    local rg = roomGraph(world)
    local piece = rg.piece
    local start = piece[slevel * plane + sj * w + si]
    if not start then return nil end -- standing somewhere odd (on furniture): let the search decide
    rrStamp = rrStamp + 1
    local S = rrStamp
    local any = false
    for n = 1, #goals do
        local g = goals[n]
        local node = W.InLot(lot, g[1], g[2]) and piece[(g[3] or 0) * plane + g[2] * w + g[1]]
        if node then
            if node == start then return nil end
            rgGoal[node] = S
            any = true
        end
    end
    if not any then return nil end
    if roomsReach(world, rg, start, S, who, nil) then return nil end
    if roomsReach(world, rg, start, S, who, W.privacyHooks) then return "privacy" end
    local A = SS.Actions
    if A and A.privacy and next(A.privacy) then return nil end
    return "rule"
end
Nav.RoomRule = roomRule

-- Search scratch: goals by node (stamped), goal coordinates for the heuristic, step directions.
local gStamp, gIdx = {}, {}
local gI, gJ, gL, gN = {}, {}, {}, 0
local gKey, gkN = {}, 0
-- The walk back from the goals (FindPath, after Tuning.pathReverseAfter expansions): stamped seen
-- marks and a queue, reused.
local rvSeen, rvQueue, rvStamp = {}, {}, 0
-- Distance still to go, plus a tie-break: of two cells with the same estimate (cost so far plus
-- distance left) the one nearer the goal comes first. Without it the search in open floor opens
-- every cell of the rectangle between start and goal (919 for an 82-cell route on 48x40); with
-- it, about the route. The tie-break (1/65536 of the distance) never reorders two different whole
-- costs, so routes stay shortest.
local TIE = 1 + 1 / 65536
local abs = math.abs
local function heur(i, j, l)
    local best, sc = 1e9, Nav.STAIR_COST
    for n = 1, gN do
        local d = abs(gI[n] - i) + abs(gJ[n] - j) + abs(gL[n] - l) * sc
        if d < best then best = d end
    end
    return best * TIE
end

-- Get the searches ready at load (Sim.Attach): size the search scratch and the edge-key cache for
-- this lot (grows only: a smaller lot reuses what a bigger one sized), and build the reachability
-- map and the lock maps of the people here, so the first searches during play do not (otherwise a
-- one-off 50-100 KB and a few ms on the first routes after a load). An edit (World.Rebuild)
-- drops the maps again; they are rebuilt by the next search that needs them.
local preparedNodes, preparedW, preparedH = 0, 0, 0
function Nav.Prepare(world)
    local lot = world.lot
    local nodes = lot.w * lot.h * W.LEVELS
    if nodes > preparedNodes then
        for k = preparedNodes, nodes - 1 do
            sStamp[k], sCost[k], sCame[k], sClosed[k] = 0, 0, 0, false
            gStamp[k], gIdx[k] = 0, 0
            rvSeen[k] = 0
        end
        for n = preparedNodes + 1, nodes do hNode[n], hF[n] = 0, 0 end
        preparedNodes = nodes
    end
    if lot.w > preparedW or lot.h > preparedH then
        preparedW, preparedH = math.max(preparedW, lot.w), math.max(preparedH, lot.h)
        local edgeKey = W.EdgeKey
        for j = 0, preparedH - 1 do
            for i = 0, preparedW - 1 do
                edgeKey(i, j, i + 1, j); edgeKey(i, j, i - 1, j); edgeKey(i, j, i, j + 1); edgeKey(i, j, i, j - 1)
            end
        end
    end
    Nav.Regions(world)
    roomGraph(world)
    if #lockList(world) > 0 then
        for _, a in pairs(world.actors) do
            local mask = lockMask(world, a)
            if mask > 0 then lockComps(world, mask) end
        end
    end
end

-- goals: array of {i, j, level}. Start (si, sj, slevel). who: the moving actor (passage/cost hooks).
-- opts (optional): { avoid = { [nodeKey] = extraCost | true }, noHooks = bool, budget = bool, force = bool }
--   avoid: cells to route around (people standing still); true = impassable. Such a search
--          stops after Tuning.pathAvoidExpand expansions ("blocked"): a long detour is not
--          worth it and the caller uses the plain route.
--   noHooks: ignore rule pass hooks (used to tell "blocked by privacy or a lock" from "no way at
--            all"); structural hooks (geometry such as pool water) still apply.
--   budget: the executor's own route planning: refused with "budget" once this step's searches
--           (Tuning.pathsPerStep) or node expansions (Tuning.pathExpandPerStep) are used up, and
--           retried next step. Every other call (other modules, menus, tests) always gets its
--           answer; it still counts against the step.
--   force: never count against the budget (recovery checks).
-- Returns path (array of {i, j, level, stairs=id|nil}, excluding start) and goal index, or
-- nil, reason ("unreachable" | "blocked" | "budget") and, for a way ruled out before searching,
-- what rules it out ("lock": every way in is locked to `who`; "privacy": the goal is in, or only
-- reached through, a bathroom someone else is using; "rule": no sequence of doors that the pass
-- hooks let `who` through reaches the goal's room, e.g. visitors' private rooms). A search
-- allocates nothing but the path it returns: scratch arrays are stamped and reused, edge keys are
-- cached (World.EdgeKey), and goals ruled out by locks, privacy or room rules fail before searching.
function Nav.FindPath(world, si, sj, slevel, goals, who, opts)
    local lot = world.lot
    local w, h, plane = lot.w, lot.h, lot.w * lot.h
    slevel = slevel or 0
    local avoid = opts and opts.avoid
    local noHooks = opts and opts.noHooks
    if not (opts and opts.force) then
        if opts and opts.budget and (Nav.budget <= 0 or Nav.expandLeft <= 0) then Nav.stats.deferred = Nav.stats.deferred + 1; return nil, "budget" end
        Nav.budget = Nav.budget - 1
    end
    stamp = stamp + 1
    local S = stamp
    local anyGoal = false
    gN, gkN = 0, 0
    for n = 1, #goals do
        local g = goals[n]
        local gl = g[3] or 0
        if W.InLot(lot, g[1], g[2]) and not W.Blocked(world, gl, g[1], g[2]) then
            local k = gl * plane + g[2] * w + g[1]
            if gStamp[k] ~= S then gStamp[k], gIdx[k] = S, n; gkN = gkN + 1; gKey[gkN] = k end
            anyGoal = true
        end
        gN = gN + 1
        gI[gN], gJ[gN], gL[gN] = g[1], g[2], gl
    end
    local startKey = slevel * plane + sj * w + si
    if gStamp[startKey] == S then return {}, gIdx[startKey] end
    if not anyGoal then Nav.stats.rejected = Nav.stats.rejected + 1; return nil, "unreachable" end
    if not Nav.Reachable(world, si, sj, slevel, goals) then Nav.stats.rejected = Nav.stats.rejected + 1; return nil, "unreachable" end
    if not noHooks and who then
        if not Nav.LockReachable(world, si, sj, slevel, goals, who) then
            Nav.stats.rejected = Nav.stats.rejected + 1
            return nil, "blocked", "lock"
        end
        if privateGoals(world, si, sj, slevel, goals, who) then
            Nav.stats.rejected = Nav.stats.rejected + 1
            return nil, "blocked", "privacy"
        end
        local rule = roomRule(world, si, sj, slevel, goals, who)
        if rule then
            Nav.stats.rejected = Nav.stats.rejected + 1
            return nil, "blocked", rule
        end
    end
    Nav.stats.searches = Nav.stats.searches + 1
    local links = stairLinks(world)
    local hasCost = #W.costHooks > 0 and not noHooks
    local hooks = noHooks and W.structuralHooks or W.passHooks
    local nHooks = #hooks
    local OPEN = W.OPENINGS
    local edgeKey = W.EdgeKey
    local blocked = W.Blocked
    -- the neighbour test inlined (W.Blocked's own steps and the edge-key cache; about a third of a
    -- failing search's time went on those calls), unless a module has wrapped W.Blocked
    local inline = blocked == W.BlockedCore
    local occ, well, floors = SS.RT.occ, SS.RT.well, lot.floor
    local bHooks = W.blockedHooks
    local nbH = #bHooks
    local EK = (w <= 256 and h <= 256) and W.EDGE_KEYS or NO_KEYS -- the cache covers cells 0..255
    hN = 0
    sStamp[startKey], sCost[startKey], sCame[startKey], sVia[startKey], sClosed[startKey] = S, 0, nil, nil, false
    heapPush(startKey, heur(si, sj, slevel))
    local cap = math.min(plane * W.LEVELS * 2, SS.Tuning.pathExpandCap or 4000)
    -- routing around people is a preference: a short detour or none (the caller falls back to the
    -- plain route), so a way that exists only through them never costs a whole-region search
    if avoid then cap = math.min(cap, SS.Tuning.pathAvoidExpand or 400) end
    local limit = cap
    local found
    -- A search still going after Tuning.pathReverseAfter expansions also walks back from the goals
    -- (breadth first, one cell per expansion) over the steps this search would take in the other
    -- direction: the same walls and furniture, the pass hooks asked in the direction of travel,
    -- the stairs. If that walk runs out of cells without meeting the start or any cell the search
    -- has reached, no way leads to the goals (fenced off by a rule on cells inside a room, which
    -- the door check can't see) and the search stops there, after about twice the goals' own side
    -- instead of everything on the walker's side. Meeting the search proves a way exists: the walk
    -- back stops and the search goes on as before. Not for a search around people (capped anyway).
    local revAt = not avoid and (SS.Tuning.pathReverseAfter or 256) or nil
    local rvV, rvH, rvN, rvUsed, fenced = nil, 1, 0, 0, false
    while hN > 0 and limit > 0 do
        local cur = heapPop()
        if not sClosed[cur] then
            sClosed[cur] = true
            limit = limit - 1
            if gStamp[cur] == S then found = cur; break end
            local l = math.floor(cur / plane)
            local r = cur - l * plane
            local j = math.floor(r / w)
            local i = r - j * w
            local base = sCost[cur]
            local walls = lot.walls[l]
            local occL, wellL, floorL = occ[l], well[l], floors[l]
            local ekBase = (j * 256 + i) * 4
            for d = 1, 4 do
                local ni, nj = i + DI[d], j + DJ[d]
                local free = ni >= 0 and nj >= 0 and ni < w and nj < h
                if free then
                    if inline then
                        local ix = nj * w + ni + 1
                        if occL[ix] or (l > 0 and not (floorL and floorL[ix]) or (l > 0 and wellL[ix])) then free = false
                        elseif nbH > 0 then
                            for n = 1, nbH do if bHooks[n](world, l, ni, nj) then free = false; break end end
                        end
                    else
                        free = not blocked(world, l, ni, nj)
                    end
                end
                if free then
                    local nk = l * plane + nj * w + ni
                    local wl = walls and walls[EK[ekBase + EKD[d]] or edgeKey(i, j, ni, nj)]
                    local ok = not wl or OPEN[wl.kind] == true
                    if ok and nHooks > 0 then
                        for hn = 1, nHooks do
                            if hooks[hn](world, l, i, j, ni, nj, wl, who) == false then ok = false; break end
                        end
                    end
                    local av = avoid and avoid[nk]
                    if av == true and gStamp[nk] ~= S then ok = false end
                    if ok then
                        local nc = base + 1 + (hasCost and W.StepCost(world, l, ni, nj, who) or 0)
                        if av and av ~= true then nc = nc + av end
                        if sStamp[nk] ~= S or nc < sCost[nk] then
                            sStamp[nk], sCost[nk], sCame[nk], sVia[nk], sClosed[nk] = S, nc, cur, nil, false
                            heapPush(nk, nc + heur(ni, nj, l))
                        end
                    end
                end
            end
            local lk = links[cur]
            if lk then
                for n = 1, #lk do
                    local nk, sid = lk[n][1], lk[n][2]
                    local nl = math.floor(nk / plane)
                    local nr = nk - nl * plane
                    local nj = math.floor(nr / w)
                    local ni = nr - nj * w
                    if not blocked(world, nl, ni, nj) then
                        local nc = base + Nav.STAIR_COST
                        if sStamp[nk] ~= S or nc < sCost[nk] then
                            sStamp[nk], sCost[nk], sCame[nk], sVia[nk], sClosed[nk] = S, nc, cur, sid, false
                            heapPush(nk, nc + heur(ni, nj, nl))
                        end
                    end
                end
            end
            -- one cell of the walk back from the goals (see above)
            if revAt and cap - limit >= revAt then
                if not rvV then
                    rvStamp = rvStamp + 1
                    rvV, rvH, rvN = rvStamp, 1, 0
                    for n = 1, gkN do
                        local k = gKey[n]
                        if sStamp[k] == S then revAt = nil; break end -- the search has reached a goal cell
                        if rvSeen[k] ~= rvV then rvSeen[k] = rvV; rvN = rvN + 1; rvQueue[rvN] = k end
                    end
                end
                if revAt then
                    if rvH > rvN then fenced = true; break end
                    local c = rvQueue[rvH]; rvH = rvH + 1
                    rvUsed = rvUsed + 1
                    local cl = math.floor(c / plane)
                    local cr = c - cl * plane
                    local cj = math.floor(cr / w)
                    local ci = cr - cj * w
                    local cwalls = lot.walls[cl]
                    local occC, wellC, floorC = occ[cl], well[cl], floors[cl]
                    local ekC = (cj * 256 + ci) * 4
                    for d = 1, 4 do
                        if not revAt then break end
                        local pi, pj = ci + DI[d], cj + DJ[d]
                        if pi >= 0 and pj >= 0 and pi < w and pj < h then
                            local pk = cl * plane + pj * w + pi
                            local free = rvSeen[pk] ~= rvV
                            if free and pk ~= startKey then
                                if inline then
                                    local ix = pj * w + pi + 1
                                    if occC[ix] or (cl > 0 and not (floorC and floorC[ix]) or (cl > 0 and wellC[ix])) then free = false
                                    elseif nbH > 0 then
                                        for n = 1, nbH do if bHooks[n](world, cl, pi, pj) then free = false; break end end
                                    end
                                else
                                    free = not blocked(world, cl, pi, pj)
                                end
                            end
                            if free then
                                -- the edge between c and p is one wall record whichever way it is crossed
                                local wl = cwalls and cwalls[EK[ekC + EKD[d]] or edgeKey(pi, pj, ci, cj)]
                                local ok = not wl or OPEN[wl.kind] == true
                                if ok and nHooks > 0 then
                                    for hn = 1, nHooks do
                                        if hooks[hn](world, cl, pi, pj, ci, cj, wl, who) == false then ok = false; break end
                                    end
                                end
                                if ok then
                                    if pk == startKey or sStamp[pk] == S then revAt = nil -- met the search: a way exists
                                    else rvSeen[pk] = rvV; rvN = rvN + 1; rvQueue[rvN] = pk end
                                end
                            end
                        end
                    end
                    -- stairs (links run both ways; a flight asks no hook, only that c is free)
                    local clk = revAt and links[c]
                    if clk then
                        for n = 1, #clk do
                            local pk = clk[n][1]
                            if rvSeen[pk] ~= rvV then
                                local pl = math.floor(pk / plane)
                                local pr = pk - pl * plane
                                local pj = math.floor(pr / w)
                                if pk == startKey or sStamp[pk] == S then revAt = nil; break end
                                if not blocked(world, pl, pr - pj * w, pj) then
                                    rvSeen[pk] = rvV; rvN = rvN + 1; rvQueue[rvN] = pk
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local used = cap - limit + rvUsed
    Nav.stats.expanded = Nav.stats.expanded + used
    Nav.expandLeft = Nav.expandLeft - used
    hN = 0 -- the heap's slots are kept (numbers only), so the next search does not grow it again
    if found then
        local path = {}
        local k = found
        local n = 0
        while k ~= startKey do n = n + 1; k = sCame[k] end
        k = found
        for m = n, 1, -1 do
            local l = math.floor(k / plane)
            local r = k - l * plane
            local j = math.floor(r / w)
            path[m] = { r - j * w, j, l, stairs = sVia[k] }
            k = sCame[k]
        end
        return path, gIdx[found]
    end
    Nav.stats.failed = Nav.stats.failed + 1
    if fenced then Nav.stats.fenced = Nav.stats.fenced + 1 end
    return nil, "blocked"
end

-- Nearest free cell around (i, j) on this side of the walls. Returns the first unblocked cell that
-- accept(i, j) (optional) takes, or nil.
--  * Which cells count: those a walk from the start reaches without crossing a wall, window or
--    fence (doors, gates and arches are openings), staying within maxR tiles (Chebyshev) of the
--    start. The walk may pass over furniture (someone standing inside a bed steps out of it).
--  * In which order: ring by ring (Chebyshev distance), each ring scanned row by row from its
--    top-left corner: the order this function has always used, so in open floor the chosen cell
--    is the one it always was (other modules' spot choices depend on it). A cell the walk only
--    reaches by a detour (round a wall, through a door) counts as half its walk away when that is
--    further than its ring, so a cell just behind a wall comes after the free cells on this side
--    that are as near: the waiting spot for a bathroom is outside its door, not in the bedroom
--    behind its wall. Detoured cells of one ring come in walk order.
-- Used for recovering someone left inside furniture, waiting and stepping-aside spots, and where
-- dropped items and mess land. anySide = true: when nothing on this side qualifies, fall back to
-- the nearest cell by ring whatever is in between (recovery only, so nobody is left stuck).
local nfSeen, nfDist, nfStamp, nfQueue, nfFirst = {}, {}, 0, {}, {}
local function ringScan(world, level, i, j, maxR, accept)
    local lot = world.lot
    for r = 0, maxR do
        for dj = -r, r do
            for di = -r, r do
                if math.max(math.abs(di), math.abs(dj)) == r then
                    local ci, cj = i + di, j + dj
                    if W.InLot(lot, ci, cj) and not W.Blocked(world, level, ci, cj) and (not accept or accept(ci, cj)) then return ci, cj end
                end
            end
        end
    end
end

-- A ring-R cell is taken at ring R when the walk reached it within 2R steps (otherwise later, as
-- a detour), it is free and accept takes it.
local function nfTake(world, level, S, accept, ci, cj, R)
    local lot = world.lot
    if ci < 0 or cj < 0 or ci >= lot.w or cj >= lot.h then return false end
    local k = cj * lot.w + ci
    if nfSeen[k] ~= S or nfDist[k] > 2 * R then return false end
    return not W.Blocked(world, level, ci, cj) and (not accept or accept(ci, cj))
end

function Nav.NearestFree(world, level, i, j, maxR, accept, anySide)
    local lot = world.lot
    level = level or 0
    maxR = maxR or math.max(lot.w, lot.h)
    if not W.InLot(lot, i, j) then return ringScan(world, level, i, j, maxR, accept) end
    if not W.Blocked(world, level, i, j) and (not accept or accept(i, j)) then return i, j end
    -- the walk: every cell reached, with its distance in steps; the queue is in step order and
    -- nfFirst[d] is where distance d starts in it
    nfStamp = nfStamp + 1
    local S = nfStamp
    local w, h = lot.w, lot.h
    local start = j * w + i
    nfSeen[start], nfDist[start] = S, 0
    nfQueue[1] = start
    nfFirst[0] = 1
    local qh, qn, maxD = 1, 1, 0
    while qh <= qn do
        local cur = nfQueue[qh]; qh = qh + 1
        local ci = cur % w
        local cj = (cur - ci) / w
        local nd = nfDist[cur] + 1
        for d = 1, 4 do
            local ni, nj = ci + DI[d], cj + DJ[d]
            if ni >= 0 and nj >= 0 and ni < w and nj < h and math.abs(ni - i) <= maxR and math.abs(nj - j) <= maxR then
                local nk = nj * w + ni
                if nfSeen[nk] ~= S and W.CanStepStatic(world, level, ci, cj, ni, nj) then
                    nfSeen[nk], nfDist[nk] = S, nd
                    qn = qn + 1
                    nfQueue[qn] = nk
                    if nd > maxD then maxD = nd; nfFirst[nd] = qn end
                end
            end
        end
    end
    nfFirst[maxD + 1] = qn + 1
    local lastR = math.max(maxR, math.ceil(maxD / 2))
    for R = 1, lastR do
        if R <= maxR then
            -- the ring's own cells, in the old scan order (top row, the sides row by row, bottom row)
            for di = -R, R do if nfTake(world, level, S, accept, i + di, j - R, R) then return i + di, j - R end end
            for dj = -R + 1, R - 1 do
                if nfTake(world, level, S, accept, i - R, j + dj, R) then return i - R, j + dj end
                if nfTake(world, level, S, accept, i + R, j + dj, R) then return i + R, j + dj end
            end
            for di = -R, R do if nfTake(world, level, S, accept, i + di, j + R, R) then return i + di, j + R end end
        end
        -- nearer cells reached only by a detour of 2R - 1 or 2R steps
        for d = 2 * R - 1, math.min(2 * R, maxD) do
            for q = nfFirst[d], nfFirst[d + 1] - 1 do
                local k = nfQueue[q]
                local ci = k % w
                local cj = (k - ci) / w
                if math.max(math.abs(ci - i), math.abs(cj - j)) < R and not W.Blocked(world, level, ci, cj)
                    and (not accept or accept(ci, cj)) then return ci, cj end
            end
        end
    end
    if anySide then return ringScan(world, level, i, j, maxR, accept) end
    return nil
end
