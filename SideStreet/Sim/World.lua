-- SideStreet world queries and derived (non-saved) caches: occupancy, rooms, room scores,
-- surfaces, noise. Owner: household-core.
-- A lot has two levels (0 = ground, 1 = upper). Per level: lot.floor[level][idx], lot.walls[level][edgeKey].
-- Objects carry o.level (default 0). Level-0 cells are always walkable ground; level-1 cells
-- are walkable only where a floor tile exists.
local _, SS = ...
local G = SS.Grid
local W = {}
SS.World = W

W.LEVELS = 2          -- levels 0 and 1
W.STORY = 2.25        -- tiles of height per story (matches 36-voxel walls)

-- Derived runtime state. Rebuilt from saved data; never serialized.
SS.RT = SS.RT or { version = 0, env = 0, objVer = 0 }

local function idx(lot, i, j) return j * lot.w + i + 1 end
W.idx = idx

function W.InLot(lot, i, j) return i >= 0 and j >= 0 and i < lot.w and j < lot.h end

function W.Walls(lot, level) return lot.walls[level or 0] or {} end
function W.Floors(lot, level) return lot.floor[level or 0] or {} end

function W.FloorAt(lot, level, i, j)
    local f = lot.floor[level or 0]
    return f and f[idx(lot, i, j)]
end

function W.WallAt(lot, level, key)
    local w = lot.walls[level or 0]
    return w and w[key]
end

-- Objects that never block a cell: rugs, puddles, wall/ceiling/window mounts, items resting on a
-- surface (anything with a parent), and definitions flagged noBlock.
local NOBLOCK_MOUNT = { wall = true, ceiling = true, surface = true, window = true }
function W.NonBlocking(def, o)
    if not def then return true end
    if def.noBlock or (def.mount and NOBLOCK_MOUNT[def.mount]) then return true end
    if o and o.parent then return true end
    return false
end

-- Stairs: an object whose definition has `stairs = { bottom = {dx,dy}, top = {dx,dy}, run = {{dx,dy},...} }`
-- in local coordinates. The run cells are its footprint on level 0; the cells above the run on
-- level 1 are a stairwell (no floor, blocked); `top` is the landing cell on level 1.
function W.StairInfo(o)
    local def = SS.Objects[o.def]
    local st = def and def.stairs
    if not st then return nil end
    local function at(p) local dx, dy = G.rot(p[1], p[2], o.f); return { o.x + dx, o.y + dy } end
    local run = {}
    for n = 1, #st.run do run[n] = at(st.run[n]) end
    return { bottom = at(st.bottom), top = at(st.top), run = run, level = o.level or 0 }
end

local FLOOD = {}
local function floodRooms(lot, level, rt)
    local room = {}
    rt.room[level] = room
    local rooms = rt.rooms[level] or {}
    rt.rooms[level] = rooms
    local walls = W.Walls(lot, level)
    local walkable = function(i, j)
        if not W.InLot(lot, i, j) then return false end
        if level == 0 then return true end
        return W.FloorAt(lot, level, i, j) ~= nil and not rt.well[level][idx(lot, i, j)]
    end
    -- the flood keeps cell numbers (j * w + i) on one shared stack: no table per cell
    local lw = lot.w
    local function fill(si, sj, id)
        local stack = FLOOD
        local n = 1
        stack[1] = sj * lw + si
        room[idx(lot, si, sj)] = id
        local cells = 0
        while n > 0 do
            local c = stack[n]
            n = n - 1
            cells = cells + 1
            local j = math.floor(c / lw)
            local i = c - j * lw
            for k = 0, 3 do
                local d = G.DIRS[k]
                local ni, nj = i + d[1], j + d[2]
                if W.InLot(lot, ni, nj) and walkable(ni, nj) and not room[idx(lot, ni, nj)] and not walls[W.EdgeKey(i, j, ni, nj)] then
                    room[idx(lot, ni, nj)] = id
                    n = n + 1
                    stack[n] = nj * lw + ni
                end
            end
        end
        return cells
    end
    rooms[0] = { id = 0, outdoor = true, area = 0, level = level }
    -- Outdoor seeds: lot border cells, and (upper level) cells beside a floorless cell with no wall between.
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do
            if walkable(i, j) and not room[idx(lot, i, j)] then
                local outside = (i == 0 or j == 0 or i == lot.w - 1 or j == lot.h - 1)
                if not outside and level > 0 then
                    for k = 0, 3 do
                        local d = G.DIRS[k]
                        local ni, nj = i + d[1], j + d[2]
                        if not walkable(ni, nj) and not walls[W.EdgeKey(i, j, ni, nj)] then outside = true end
                    end
                end
                if outside then rooms[0].area = rooms[0].area + fill(i, j, 0) end
            end
        end
    end
    local rid = 0
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do
            if walkable(i, j) and not room[idx(lot, i, j)] then
                rid = rid + 1
                rooms[rid] = { id = rid, area = fill(i, j, rid), windows = 0, level = level, blocked = 0 }
            end
        end
    end
    for key, wl in pairs(walls) do
        if wl.kind == "window" then
            local _, _, _, ai, aj, bi, bj = G.parseEdge(key)
            for _, c in ipairs({ { ai, aj }, { bi, bj } }) do
                if W.InLot(lot, c[1], c[2]) then
                    local r = rooms[room[idx(lot, c[1], c[2])]]
                    if r and not r.outdoor then r.windows = r.windows + 1 end
                end
            end
        end
    end
    -- furniture density per room (crowding)
    for cell, _ in pairs(rt.occ[level]) do
        local r = rooms[room[cell]]
        if r and not r.outdoor then r.blocked = r.blocked + 1 end
    end
end

-- Hooks for other modules (build: solid build cells and derived build data; family: object
-- states that change a room's score).
--   W.RegisterRebuildHook(fn(world, rt))              after every structural rebuild
--   W.RegisterBlockedHook(fn(world, level, i, j) -> true when the cell is solid)
--   W.RegisterEnvHook(fn(world, obj, def, env) -> env) an object's decoration value in room scores
W.rebuildHooks, W.blockedHooks, W.envHooks = W.rebuildHooks or {}, W.blockedHooks or {}, W.envHooks or {}
function W.RegisterRebuildHook(fn) W.rebuildHooks[#W.rebuildHooks + 1] = fn end
function W.RegisterBlockedHook(fn) W.blockedHooks[#W.blockedHooks + 1] = fn end
function W.RegisterEnvHook(fn) W.envHooks[#W.envHooks + 1] = fn end

function W.Rebuild(world)
    local lot = world.lot
    local old = SS.RT or {}
    local rt = { occ = {}, room = {}, rooms = {}, well = {}, stairs = {}, version = (old.version or 0) + 1, lotId = lot.id,
        env = (old.env or 0) + 1, objVer = (old.objVer or 0) + 1 }
    for level = 0, W.LEVELS - 1 do rt.occ[level], rt.well[level] = {}, {} end
    for id, o in pairs(lot.objects) do
        local def = SS.Objects[o.def]
        if def then
            local lv = o.level or 0
            if lv >= W.LEVELS then lv = W.LEVELS - 1 end
            if not W.NonBlocking(def, o) then
                -- G.footprint's cells, marked without building its lists
                local occ, fp = rt.occ[lv], def.fp
                if fp then
                    for n = 1, #fp do
                        local dx, dy = G.rot(fp[n][1], fp[n][2], o.f)
                        local ci, cj = o.x + dx, o.y + dy
                        if W.InLot(lot, ci, cj) then occ[idx(lot, ci, cj)] = id end
                    end
                elseif W.InLot(lot, o.x, o.y) then
                    occ[idx(lot, o.x, o.y)] = id
                end
            end
            local st = W.StairInfo(o)
            if st then
                st.id = id
                rt.stairs[#rt.stairs + 1] = st
                for n = 1, #st.run do
                    local c = st.run[n]
                    if W.InLot(lot, c[1], c[2]) and lv + 1 < W.LEVELS then rt.well[lv + 1][idx(lot, c[1], c[2])] = id end
                end
            end
        end
    end
    SS.RT = rt
    for level = 0, W.LEVELS - 1 do floodRooms(lot, level, rt) end
    for n = 1, #W.rebuildHooks do W.rebuildHooks[n](world, rt) end
    return rt
end

-- The room environment changed (mess, state, light): room-score caches refresh on next read.
function W.Touch() SS.RT.env = (SS.RT.env or 0) + 1 end
-- The object set changed without a structural rebuild (system objects spawned/removed).
function W.ObjectsChanged() SS.RT.objVer = (SS.RT.objVer or 0) + 1; SS.RT.env = (SS.RT.env or 0) + 1 end

-- Object ids in sorted order (deterministic iteration). Cached until the object set changes.
function W.ObjectIds(world)
    local rt = SS.RT
    if rt.objIds and rt.objIdsVer == rt.objVer and rt.objIdsLot == world.lot then return rt.objIds end
    local ids = {}
    for id in pairs(world.lot.objects) do ids[#ids + 1] = id end
    table.sort(ids)
    rt.objIds, rt.objIdsVer, rt.objIdsLot = ids, rt.objVer, world.lot
    return ids
end

function W.ObjectAt(world, level, i, j)
    local id = SS.RT.occ[level or 0][idx(world.lot, i, j)]
    return id and world.lot.objects[id]
end

-- Is a cell unusable for standing on this level?
-- W.Blocked is the one answer to "is this cell solid". Nav's search inlines the same test while
-- W.Blocked is this function (W.BlockedCore); a module that wraps W.Blocked is called instead.
function W.Blocked(world, level, i, j)
    local lot = world.lot
    level = level or 0
    if not W.InLot(lot, i, j) then return true end
    if SS.RT.occ[level][idx(lot, i, j)] then return true end
    if level > 0 then
        if not W.FloorAt(lot, level, i, j) then return true end
        if SS.RT.well[level][idx(lot, i, j)] then return true end
    end
    local hooks = W.blockedHooks
    for n = 1, #hooks do if hooks[n](world, level, i, j) then return true end end
    return false
end
W.BlockedCore = W.Blocked

-- Passage hooks: systems veto steps (locked doors, privacy, staff-only, pool edges, fire).
--   W.RegisterPassHook(fn(world, level, i, j, ni, nj, wall, who) -> false to block)
-- `wall` is the edge record between the cells (or nil); `who` is the moving actor (or nil
-- for "anyone", e.g. reachability checks). Hooks must be cheap: they run inside A*.
-- Cost hooks add route cost (danger, crowding): fn(world, level, i, j, who) -> extra >= 0.
-- opts.structural = true marks a hook as physical geometry (the build module's diagonal walls and
-- pool water), not a rule: it still applies when a route check ignores rules ("is there a way at
-- all?"), so geometry is never reported as "locked or off limits".
W.passHooks, W.costHooks, W.structuralHooks = {}, {}, {}
W.privacyHooks = W.privacyHooks or {}
function W.RegisterPassHook(fn, opts)
    W.passHooks[#W.passHooks + 1] = fn
    if type(opts) == "table" and opts.structural then W.structuralHooks[#W.structuralHooks + 1] = fn end
    if type(opts) == "table" and opts.privacy then W.privacyHooks[fn] = true end
end
function W.RegisterCostHook(fn) W.costHooks[#W.costHooks + 1] = fn end

-- Wall kinds that are routes (a fence gate and an archway are openings like a door).
W.OPENINGS = { door = true, gate = true, arch = true }

-- Door locks (`wall.locked` on a door or gate; §11.3 route eligibility):
--   "all"            nobody goes in: a closed-off room;
--   "household"      only members of the lot's household (visitors, townies and staff stay out);
--                    `true` means the same (the visitors module's plain lock);
--   "adults"         children and pets stay out (a workshop, the parents' bedroom);
--   "staff"          the household plus staff and service workers (visitors' staff lock: a
--                    back office or a kitchen door on a venue lot).
-- A lock guards the room it leads into: the indoor side of an outside door, otherwise the smaller
-- of the two rooms. Leaving is always allowed, so nobody is trapped. People with `ignoreLocks`, and
-- roles whose access is "emergency" or "intruder" (firefighters, police, a burglar), pass every lock.
W.LOCKS = { all = "Nobody", household = "Household only", adults = "Adults only", staff = "Household, staff and service" }
local function roleAccess(who)
    local r = who.role
    if not r then return nil end
    local def = (SS.Visitors and SS.Visitors.roles and SS.Visitors.roles[r]) or (SS.Roles and SS.Roles[r])
    return type(def) == "table" and def.access or nil
end
function W.LockBlocks(world, lock, who)
    if not lock then return false end
    if who and who.ignoreLocks then return false end
    local acc = who and roleAccess(who)
    if acc == "emergency" or acc == "intruder" then return false end
    if lock == "all" then return true end
    if not who then return false end -- "anyone" reachability checks: every other lock admits someone
    local hh = world.household
    local member = hh ~= nil and who.householdId == hh.id
    if lock == true or lock == "household" then return not member end
    if lock == "staff" then return not (member or acc == "staff" or acc == "service") end
    if lock == "adults" then
        return (who.age or "adult") ~= "adult" or (who.kind or "human") ~= "human"
    end
    return false
end

-- The room a locked edge guards (0 = nothing: both sides outdoors).
function W.GuardedRoom(world, level, i, j, ni, nj)
    local ra, rb = W.RoomAt(world, level, i, j), W.RoomAt(world, level, ni, nj)
    if ra == rb then return 0 end
    if ra == 0 then return rb end
    if rb == 0 then return ra end
    local ia, ib = W.RoomInfo(level, ra), W.RoomInfo(level, rb)
    local ca, cb = ia and ia.area or 0, ib and ib.area or 0
    if ca ~= cb then return ca < cb and ra or rb end
    return math.max(ra, rb)
end

-- Set or clear a lock on a door/gate edge; returns ok, why. Invalidates routes.
function W.SetDoorLock(world, level, key, lock)
    local wl = W.WallAt(world.lot, level or 0, key)
    if not wl or not (wl.kind == "door" or wl.kind == "gate") then return false, "Only doors and gates can be locked." end
    if lock == true then lock = "household" end
    if lock ~= nil and not W.LOCKS[lock] then return false, "Unknown lock setting." end
    wl.locked = lock
    SS.RT.regions, SS.RT.lockComps, SS.RT.lockList = nil, nil, nil
    SS.Emit("lotChanged", "walls", key)
    return true
end

-- Saved lock settings are checked on load: unknown values and locks on non-doors are dropped.
if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        for _, lot in pairs(type(root.hood) == "table" and type(root.hood.lots) == "table" and root.hood.lots or {}) do
            for _, lv in pairs(type(lot) == "table" and type(lot.walls) == "table" and lot.walls or {}) do
                for key, wl in pairs(type(lv) == "table" and lv or {}) do
                    if type(wl) == "table" and wl.locked ~= nil then
                        if not (wl.locked == true or W.LOCKS[wl.locked]) or not (wl.kind == "door" or wl.kind == "gate") then
                            wl.locked = nil
                            if problems then problems[#problems + 1] = "dropped an invalid lock on " .. tostring(key) end
                        end
                    end
                end
            end
        end
        return true
    end)
end

function W.LockHook(world, level, i, j, ni, nj, wall, who)
    if not (wall and wall.locked and W.OPENINGS[wall.kind]) then return end
    local guarded = W.GuardedRoom(world, level, i, j, ni, nj)
    if guarded == 0 or W.RoomAt(world, level, ni, nj) ~= guarded then return end -- leaving is always allowed
    if W.LockBlocks(world, wall.locked, who) then return false end
end
W.RegisterPassHook(W.LockHook)

-- Edge keys between a cell and its 4-neighbours ("y:3:4"), built once per (cell, direction) and
-- then reused, so routing and room checks never build strings in their inner loops. The key only
-- depends on geometry, so one cache serves every lot (bounded by the cells actually visited).
-- Direction index: 0 = +i, 1 = -i, 2 = +j, 3 = -j.
local EDGE_KEYS = {}
local function edgeKey(i, j, ni, nj)
    local d
    if ni == i + 1 then d = 0 elseif ni == i - 1 then d = 1 elseif nj == j + 1 then d = 2 else d = 3 end
    if i < 0 or j < 0 or i > 255 or j > 255 then return G.edgeBetween(i, j, ni, nj) end
    local k = (j * 256 + i) * 4 + d
    local key = EDGE_KEYS[k]
    if not key then key = G.edgeBetween(i, j, ni, nj); EDGE_KEYS[k] = key end
    return key
end
W.EdgeKey = edgeKey
-- The cache itself, for Nav's inner loop: EDGE_KEYS[(j * 256 + i) * 4 + d] with d as above (nil
-- until that edge was first asked for, and for cells outside 0..255; call edgeKey then).
W.EDGE_KEYS = EDGE_KEYS

-- The wall record on the edge between two 4-adjacent cells (or nil).
function W.WallBetween(lot, level, i, j, ni, nj)
    local w = lot.walls[level or 0]
    return w and w[edgeKey(i, j, ni, nj)]
end

-- Walls only (no hooks): used for static reachability.
function W.CanStepStatic(world, level, i, j, ni, nj)
    local w = world.lot.walls[level or 0]
    local wl = w and w[edgeKey(i, j, ni, nj)]
    return not wl or W.OPENINGS[wl.kind] == true
end

-- Walls plus structural pass hooks (geometry, no rules): "is there a way at all" for `who`.
function W.CanStepStructural(world, level, i, j, ni, nj, who)
    local w = world.lot.walls[level or 0]
    local wl = w and w[edgeKey(i, j, ni, nj)]
    if wl and not W.OPENINGS[wl.kind] then return false end
    local hooks = W.structuralHooks
    for n = 1, #hooks do
        if hooks[n](world, level, i, j, ni, nj, wl, who) == false then return false end
    end
    return true
end

-- Can an actor step between two 4-adjacent cells on one level? Doors are routes; walls/windows are not.
function W.CanStep(world, level, i, j, ni, nj, who)
    local w = world.lot.walls[level or 0]
    local wl = w and w[edgeKey(i, j, ni, nj)]
    if wl and not W.OPENINGS[wl.kind] then return false end
    local hooks = W.passHooks
    for n = 1, #hooks do
        if hooks[n](world, level, i, j, ni, nj, wl, who) == false then return false end
    end
    return true
end

function W.StepCost(world, level, i, j, who)
    local c, hooks = 0, W.costHooks
    for n = 1, #hooks do c = c + (hooks[n](world, level, i, j, who) or 0) end
    return c
end

function W.RoomAt(world, level, i, j)
    local r = SS.RT.room[level or 0]
    if not r or not W.InLot(world.lot, i, j) then return 0 end
    return r[idx(world.lot, i, j)] or 0
end

function W.RoomInfo(level, roomId)
    local r = SS.RT.rooms[level or 0]
    return r and r[roomId]
end

-- Room of an object (its anchor cell).
function W.ObjRoom(world, o) return W.RoomAt(world, o.level or 0, o.x, o.y) end

-- 0 at night, 1 in full day, ramps at dawn/dusk.
function W.Daylight(time)
    local h = (time / 60) % 24
    if h < 6 or h >= 20 then return 0 end
    if h < 8 then return (h - 6) / 2 end
    if h >= 18 then return (20 - h) / 2 end
    return 1
end

-- Is this object's light usable (on and not broken)?
local function lightOn(o) return o.state and o.state.on and not o.state.broken end

function W.RoomLight(world, level, roomId)
    local room = W.RoomInfo(level, roomId)
    local day = W.Daylight(world.time)
    if not room or room.outdoor then
        local lamp = 0
        for _, o in pairs(world.lot.objects) do
            local def = SS.Objects[o.def]
            if def and def.light and lightOn(o) and (o.level or 0) == level and W.RoomAt(world, level, o.x, o.y) == 0 then lamp = lamp + def.light * 0.15 end
        end
        return math.min(1, math.max(day, 0.15) + lamp)
    end
    local light = day * math.min(1, room.windows * 6 / math.max(room.area, 1)) * 0.9
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        if def and def.light and lightOn(o) and (o.level or 0) == level and W.RoomAt(world, level, o.x, o.y) == roomId then
            light = light + def.light * math.min(1, 16 / math.max(room.area, 1)) * 0.8
        end
    end
    return math.min(1, light)
end

-- Mess and damage an object contributes to its room (see Tuning.room.mess). System objects
-- declare `mess = "plate"|"food"|"trash"|"bag"|"puddle"|"clutter"`.
local NO_STATE = {}   -- read-only stand-in for an object without state (no table per object)
local function messOf(def, o, M, counts)
    local m = 0
    local st = o.state or NO_STATE
    if def.mess then
        local kind = def.mess
        if kind == "food" and st.spoiled then kind = "spoiled" end
        m = m + (M[kind] or 0)
        counts[kind] = (counts[kind] or 0) + 1
    end
    local dirt = o.dirt or st.dirt or 0
    if dirt >= SS.Tuning.filthyAt then m = m + M.filthy; counts.dirty = (counts.dirty or 0) + 1
    elseif dirt >= SS.Tuning.dirtyAt then m = m + M.dirty; counts.dirty = (counts.dirty or 0) + 1 end
    if st.broken then m = m + M.broken; counts.broken = (counts.broken or 0) + 1 end
    if st.unmade then m = m + M.unmade; counts.unmade = (counts.unmade or 0) + 1 end
    if st.full then m = m + M.binFull; counts.binFull = (counts.binFull or 0) + 1 end
    if st.wilted then m = m + M.wilted; counts.wilted = (counts.wilted or 0) + 1 end
    if st.burnt and not def.mess then m = m + M.burnt; counts.burnt = (counts.burnt or 0) + 1 end
    return m
end

-- Full breakdown of a room's environment score (-100..100) from its real contents:
-- lighting, decoration, usable space, dirt, dishes, spoiled food, rubbish, puddles, broken items,
-- unmade beds, clutter, wilted plants and (outdoors) landscaping. Returns a table: a new one, or
-- `into` refilled (its counts table too), for callers that read it at once and keep nothing.
function W.RoomBreakdown(world, level, roomId, into)
    local room = W.RoomInfo(level, roomId)
    local R = SS.Tuning.room
    local out
    if into then
        out = into
        local counts = out.counts or {}
        for k in pairs(counts) do counts[k] = nil end
        for k in pairs(out) do out[k] = nil end
        out.light, out.decor, out.space, out.mess, out.total, out.counts = 0, 0, 0, 0, 0, counts
        out.roomId, out.outdoor = roomId, room and room.outdoor or false
    else
        out = { light = 0, decor = 0, space = 0, mess = 0, total = 0, counts = {}, roomId = roomId, outdoor = room and room.outdoor or false }
    end
    if not room then return out end
    local light = W.RoomLight(world, level, roomId)
    local decor, mess = 0, 0
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        if def and (o.level or 0) == level and W.RoomAt(world, level, o.x, o.y) == roomId then
            local e = o.env or def.env
            local hooks = W.envHooks
            if #hooks > 0 then
                e = e or 0
                for n = 1, #hooks do e = hooks[n](world, o, def, e) or e end
            end
            if e and e ~= 0 then
                if o.state and (o.state.broken or o.state.burnt or o.state.wilted) and e > 0 then e = e * 0.3 end
                decor = decor + e
            end
            mess = mess + messOf(def, o, R.mess, out.counts)
        end
    end
    out.lightLevel = light
    if room.outdoor then
        out.light = (light - 0.5) * R.outdoorLight
        out.decor = decor * R.outdoorDecor
    else
        out.light = (light - R.lightMid) * R.lightWeight
        out.decor = decor * R.decorWeight / math.sqrt(math.max(room.area, 1))
        local space = 0
        if room.area < R.smallRoom then space = R.smallRoomPenalty end
        if room.area > 0 and (room.blocked or 0) / room.area > R.crowded then space = space + R.crowdedPenalty end
        out.space = space
    end
    out.mess = -mess * R.messScale / math.sqrt(math.max(room.area, 10))
    out.total = SS.U.clamp(out.light + out.decor + out.space + out.mess, -100, 100)
    return out
end

function W.RoomScore(world, level, roomId)
    if not W.RoomInfo(level, roomId) then return 0 end
    return W.RoomBreakdown(world, level, roomId).total
end

-- Surfaces ------------------------------------------------------------------------------
-- A definition's surfaces, normalised: { { cell = {dx,dy}, z, kind, slots } }. Legacy defs use
-- `surface = true` (one slot per footprint cell; kitchen items are counters, others tables).
local surfCache = setmetatable({}, { __mode = "k" })
function W.Surfaces(def)
    if not def then return nil end
    local c = surfCache[def]
    if c then return c ~= false and c or nil end
    local list
    if type(def.surfaces) == "table" and #def.surfaces > 0 then
        list = {}
        for n, s in ipairs(def.surfaces) do
            list[n] = { cell = s.cell or { 0, 0 }, z = s.z or def.height or 0.75, kind = s.kind or "table", slots = s.slots or 1 }
        end
    elseif def.surface then
        list = {}
        local kind = (def.cat == "kitchen" or SS.Tags.Has(def, "counter")) and "counter" or "table"
        for n, c in ipairs(def.fp or { { 0, 0 } }) do
            list[n] = { cell = { c[1], c[2] }, z = def.height or 0.75, kind = kind, slots = 1 }
        end
    end
    surfCache[def] = list or false
    return list
end

-- Slots on an object's surfaces with what (if anything) rests there.
-- Returns array of { key = "n:k", i, j, level, z, kind, child = oid|nil }.
-- Children index (parent id -> { pslot -> child id }), rebuilt when objects change (objVer).
local childIdx = { ver = -1 }
local function children(world, pid)
    local rt = SS.RT
    if childIdx.ver ~= rt.objVer or childIdx.lot ~= world.lot then
        local map = {}
        for id, o in pairs(world.lot.objects) do
            if o.parent and o.pslot then
                map[o.parent] = map[o.parent] or {}
                map[o.parent][o.pslot] = id
            end
        end
        childIdx = { ver = rt.objVer, lot = world.lot, map = map }
    end
    return childIdx.map[pid]
end
W.Children = children

-- The list is cached per object until objects change (objVer) or the object moves, so callers
-- in autonomy scans allocate nothing: treat it as read-only (a new list is built after a change,
-- so a list read earlier keeps showing the earlier state).
local slotKeys = {}
local function slotKey(n, k)
    local t = slotKeys[n]
    if not t then t = {}; slotKeys[n] = t end
    local key = t[k]
    if not key then key = n .. ":" .. k; t[k] = key end
    return key
end
local EMPTY = {}
function W.SurfaceSlots(world, obj)
    local def = SS.Objects[obj.def]
    local surfs = W.Surfaces(def)
    if not surfs then return EMPTY end
    local rt = SS.RT
    local cache = rt.surfSlots
    if not cache then cache = setmetatable({}, { __mode = "k" }); rt.surfSlots = cache end
    local c = cache[obj]
    local lv = obj.level or 0
    if c and c.ver == rt.objVer and c.x == obj.x and c.y == obj.y and c.f == (obj.f or 0) and c.level == lv and c.def == def then
        return c.list
    end
    local used = children(world, obj.id) or EMPTY
    local out = {}
    for n, s in ipairs(surfs) do
        local dx, dy = G.rot(s.cell[1], s.cell[2], obj.f or 0)
        for k = 1, s.slots do
            local key = slotKey(n, k)
            out[#out + 1] = { key = key, i = obj.x + dx, j = obj.y + dy, level = lv, z = s.z, kind = s.kind, child = used[key] }
        end
    end
    cache[obj] = { ver = rt.objVer, x = obj.x, y = obj.y, f = obj.f or 0, level = lv, def = def, list = out }
    return out
end

function W.FreeSurfaceSlot(world, obj, kinds)
    for _, s in ipairs(W.SurfaceSlots(world, obj)) do
        if not s.child and (not kinds or kinds[s.kind]) then return s end
    end
end

-- Noise -----------------------------------------------------------------------------------
-- One noise source's share at (i, j): falls off with distance, damped through walls.
local function noiseShare(world, T, level, i, j, room, n, si, sj, slevel)
    if not n or n <= 0 or slevel ~= level then return 0 end
    local d = math.abs(si - i) + math.abs(sj - j)
    if d > T.noiseRadius then return 0 end
    local v = n * (1 - d / (T.noiseRadius + 1))
    if W.RoomAt(world, level, si, sj) ~= room then v = v * T.noiseWall end
    return v
end

-- Noise units at a cell from running objects (def.noise, or tv/stereo/radio tags while on) and
-- people doing noisy interactions (interaction `noise`). Same room counts fully (minus distance);
-- other rooms are damped by Tuning.noiseWall. `except` = an actor id to ignore (the listener).
function W.NoiseAt(world, level, i, j, except)
    local T = SS.Tuning
    local room = W.RoomAt(world, level, i, j)
    local total = 0
    for _, o in pairs(world.lot.objects) do
        local st = o.state
        if st and (st.on or st.ringing) and not st.broken then
            local def = SS.Objects[o.def]
            local n = def and def.noise
            if not n and def then
                if SS.Tags.Has(def, "stereo") or SS.Tags.Has(def, "radio") or SS.Tags.Has(def, "dj") then n = T.musicNoise
                elseif SS.Tags.Has(def, "tv") then n = T.tvNoise end
            end
            if st.ringing then n = T.alarmNoise end
            total = total + noiseShare(world, T, level, i, j, room, n, o.x, o.y, o.level or 0)
        end
    end
    for id, a in pairs(world.actors) do
        if id ~= except and a.act and a.act.phase == "perform" then
            local ia = SS.Interactions[a.act.iid]
            if ia and ia.noise then total = total + noiseShare(world, T, level, i, j, room, ia.noise, math.floor(a.x), math.floor(a.y), a.level or 0) end
        end
    end
    return total
end
