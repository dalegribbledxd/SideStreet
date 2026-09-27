-- SideStreet interaction executor and autonomy. Owner: household-core.
-- Player orders and free-will choices run through one lifecycle with explicit states:
--   queued -> select -> route -> (wait) -> (enter) -> perform -> (exit) -> done
--                                                        | interrupted | failed | cancelled
-- * select: availability, slot choice and reservation (a busy slot or a private room -> wait)
-- * route:  A* (budgeted), walking, yielding to people in the way, replanning
-- * wait:   bounded wait near the target, then an alternative object or a reasoned failure
-- * enter/exit: stepping onto/off an object (bed, seat, shower)
-- * perform: commit point on the first tick (money once, state, outfit, onStart), then
--   incremental effects, so an interruption only grants what was actually done.
-- Cleanup (reservations, privacy, props, carried items, outfit, onEnd, chains) is identical
-- whoever started the action and however it ended.
-- In-progress actions and queues are mirrored into saved fields (`doing`, `orders`) so a
-- reload resumes them without charging, spawning or reserving twice (Sim.Attach -> A.Resume).
local _, SS = ...
local T, G, W, U = SS.Tuning, SS.Grid, SS.World, SS.U
local A = {}
SS.Actions = A

A.STATES = { "queued", "select", "route", "wait", "enter", "perform", "exit", "done", "interrupted", "failed", "cancelled" }
A.PHASES = { select = true, route = true, wait = true, enter = true, perform = true, exit = true }

-- Pose and prop vocabulary (ARCHITECTURE.md 8). Poses outside it fall back to "use".
A.POSES = {}
for _, p in ipairs({ "idle", "walk", "run", "sit", "sleep", "use", "talk", "laugh", "argue", "eat", "eat_stand", "cook",
    "wash", "bathe", "shower", "clean", "repair", "exercise", "celebrate", "panic", "mourn", "collapse", "carry", "swim",
    "dance", "read", "play", "paint", "phone", "greet", "hug", "kiss", "cry", "sit_talk", "sit_eat", "type", "lie", "carried" }) do A.POSES[p] = true end
A.PROPS = {}
for _, p in ipairs({ "plate_food", "plate_dirty", "snack", "cup", "bowl", "book", "newspaper", "trash_bag", "groceries",
    "gift", "flowers", "baby", "toy", "mop", "wrench", "watering_can", "extinguisher", "phone", "bottle", "shopping_bag",
    "plate_stack" }) do A.PROPS[p] = true end

local function now(world) return world.time end
local I = SS.Interactions

-- "Alex Rivera" -> "Alex" (lines and balloons use first names).
function A.FirstName(p)
    local n = p and p.name
    if not n then return nil end
    return (n:match("^(%S+)")) or n
end

function A.Message(world, actor, text, icon)
    actor.balloon = { icon = icon, text = text, untilT = now(world) + 20 }
    SS.Emit("notice", actor, text)
end

-- A short in-character line through the social module's authored pools (SS.Lines). Shown as a
-- speech balloon; rate-limited per actor (T.sayCooldown minutes) unless the lines module keeps its
-- own limits (SS.Lines.RATE_LIMITED: per speaker, per situation, per household hour, important
-- situations exempt), which then decide alone. Returns the text or nil (no line fits).
function A.Say(world, actor, situation, ctx, icon)
    local L = SS.Lines
    if not (L and L.Say) then return nil end
    actor.cool = actor.cool or {}
    local selfLimited = L.RATE_LIMITED
    if not selfLimited and (actor.cool.say or -1e9) > world.time then return nil end
    local ok, text = pcall(L.Say, world, actor, situation, ctx or {})
    if not ok or not text then return nil end
    if not selfLimited then actor.cool.say = world.time + T.sayCooldown end
    actor.balloon = { icon = icon, text = text, untilT = world.time + 12, kind = "speech" }
    SS.Emit("line", world, actor, situation, text)
    return text
end

-- Household journal. who: an actor, an id, or a list of either (optional); kind: "social", "work",
-- "danger", ... (optional). The ui-shell's SS.Journal.Add records participants, the scene bookmark
-- and emits "journal" when present; the plain fallback keeps the same 40-entry cap.
local function journal(world, text, who, kind)
    local j = world.journal
    if not j then return end
    if SS.Journal and SS.Journal.Add then
        -- a plain two-argument call: the people are found from the names in the text
        if who == nil and SS.Journal.FindNames then
            local okN, names = pcall(SS.Journal.FindNames, world, text)
            if okN and type(names) == "table" and #names > 0 then who = names end
        end
        local ok, res = pcall(SS.Journal.Add, world, text, who, kind)
        if ok then return res end
        SS.Log("Journal.Add failed: %s", tostring(res))
    end
    j[#j + 1] = { t = world.time, text = text }
    while #j > 40 do table.remove(j, 1) end
end
A.Journal = journal

-- Every household money change goes through here: one ledger entry, one "money" event.
-- category: "food", "bills", "wages", "purchase", "sale", "service", "gift", "fine", "debug", ...
function A.Money(world, delta, category, text)
    world.money = (world.money or 0) + delta
    local l = world.ledger
    if l then
        l[#l + 1] = { t = world.time, amount = delta, cat = category, text = text }
        while #l > T.ledgerCap do table.remove(l, 1) end
    end
    SS.Emit("money", delta, text, category, world)   -- world: which household moved it (family pays on other households' views)
end
SS.Money = A.Money

function A.Charge(world, amount, text, category)
    A.Money(world, -amount, category or "expense", text)
end

function A.IsMember(world, actor)
    return world.household ~= nil and actor.householdId == world.household.id
end

function A.SetPose(actor, pose)
    if pose and not A.POSES[pose] then pose = "use" end
    actor.pose = pose or "idle"
end

local function freeWill(world) return world.settings and world.settings.freeWill end

-- Needs already urgent when an autonomous choice was made. Commitment: the choice was made
-- knowing about them (nothing better was available), so they don't abandon it later; only a
-- need that *becomes* urgent or critical afterwards does. Without this, a need nothing on the lot
-- can fix (the only shower broken) makes people drop everything every few minutes.
local function lowNeeds(actor)
    local out
    local needs = actor.needs
    if not needs or actor.noNeeds then return nil end
    for n = 1, #T.needs do
        local k = T.needs[n]
        if (needs[k] or 0) < T.urgent then out = out or {}; out[k] = true end
    end
    return out
end

-- Queue mirror (saved as `orders`) -------------------------------------------------------
local function syncOrders(actor)
    if actor.orders ~= actor.queue then actor.orders = actor.queue end
end
A.SyncOrders = syncOrders

-- Compact saved mirror of the current action (`doing`).
local function mirror(actor, act)
    local d = act.save
    if not d then
        d = {}
        act.save = d
    end
    d.iid, d.oid, d.tid, d.x, d.y, d.level = act.iid, act.oid, act.tid, act.x, act.y, act.level
    d.manual, d.data, d.chain, d.optional = act.manual, act.data, act.chain, act.optional
    d.charged, d.performed, d.t, d.phase, d.label = act.charged, act.performed, act.t, act.phase, act.label
    d.slot = act.target and act.target.slotName or nil
    d.key = act.target and act.target.key or nil
    d.dur, d.maxDur = act.dur, act.maxDur
    d.restarted = act.restarted
    actor.doing = d
end
A.Mirror = mirror

-- Permissions, refusals, cost -----------------------------------------------------------

-- A visiting role's definition (visitors keeps them in SS.Visitors.roles; SS.Roles holds the
-- runtime wrappers and roles other modules register directly).
local function roleDef(actor)
    local r = actor.role
    if not r then return nil end
    return (SS.Visitors and SS.Visitors.roles and SS.Visitors.roles[r]) or (SS.Roles and SS.Roles[r])
end
A.RoleDef = roleDef

-- Who may use an interaction: kinds (people by default), ages, household-only vs guest vs
-- service access (visitor roles declare `access`). `householdOnly` keeps everyone else out
-- unless `service` lets service workers in; `guestForbidden` (the visitors module's field) keeps
-- guests out of household chores while the household and service workers may do them.
function A.CanUse(world, actor, ia)
    local kind = actor.kind or "human"
    if ia.kinds then
        if not ia.kinds[kind] then return false, "Not something a " .. kind .. " can do." end
    elseif kind ~= "human" then
        return false, "Only people can do that."
    end
    local age = actor.age or "adult"
    if ia.ages then
        if not ia.ages[age] then return false, (age == "child") and "That's for grown-ups." or "Not at this age." end
    elseif age == "infant" then
        return false, "Babies can't do that."
    end
    if (ia.householdOnly or ia.guestForbidden) and not A.IsMember(world, actor) then
        local role = roleDef(actor)
        local access = role and role.access or "guest"
        if not (access == "household" or (access == "service" and ia.service)) then
            if ia.householdOnly or access ~= "guest" then return false, "That's for the household." end
            return false, "Guests don't do the chores here."
        end
    end
    return true
end

-- The design's own age and pet flags (catalogue: kidOnly, adultOnly, pet), for every interaction on
-- it, including ones other modules add later. Looking after the thing is not using it: chores,
-- repairs and interactions marked `care` (turning off a grill) stay open to anyone the interaction
-- itself allows; on a pet item an interaction that names the kinds it is for (family's bowl filling
-- and litter cleaning) decides alone. Catalogue's HC-1.
local KID_AGES = { child = true, toddler = true }
function A.DesignFor(actor, ia, def)
    if not (def.kidOnly or def.adultOnly or def.pet) then return true end
    if ia.care or ia.chore or ia.whenBroken then return true end
    local age = actor.age or "adult"
    if def.kidOnly and not KID_AGES[age] then return false, "That's for children." end
    if def.adultOnly and (KID_AGES[age] or age == "infant") then return false, "Only adults can use that." end
    if def.pet and (actor.kind or "human") == "human" and not ia.kinds and not ia.petCare then return false, "That's for pets." end
    return true
end

-- Does this action (on this object) relieve a need that is already urgent or critical? A chore
-- that fixes the very thing making someone miserable (a filthy room, a broken fridge when they
-- are starving) is not refused for misery, or low mood would lock itself in.
local function relievesUrgent(world, actor, ia, obj)
    local adv = ia.advert
    if ia.advertise and obj then
        local ok, a = pcall(ia.advertise, world, actor, obj)
        if ok then adv = a end
    end
    if type(adv) ~= "table" then return false end
    for need, amt in pairs(adv) do
        if type(amt) == "number" and amt > 0 and actor.needs[need] then
            local st = SS.Needs.Status(actor, need)
            if st == "urgent" or st == "critical" then return true, need end
        end
    end
    return false
end
A.RelievesUrgent = relievesUrgent

-- Refusal of unsuitable actions: too tired or miserable for exertion and chores (unless the chore
-- relieves an urgent need), too bored to clean, or another need is critical and this is only leisure.
local BASIC_NEEDS = { "bladder", "hunger", "energy" }
function A.Refusal(world, actor, ia, obj)
    if actor.noNeeds or not actor.needs then return nil end
    if ia.exertion or ia.chore then
        if (actor.needs.energy or 0) < T.refuseEnergy then return "Too tired to " .. (ia.label or "that"):lower() .. "." end
        local mood = SS.Needs.Mood(actor, world)
        if mood < T.refuseMood and not (ia.chore and relievesUrgent(world, actor, ia, obj)) then
            return "Too miserable to " .. (ia.label or "that"):lower() .. "."
        end
    end
    if ia.chore and (actor.needs.fun or 0) < T.refuseFun then
        local neat = actor.personality and actor.personality.neat or 5
        if neat < 8 then return "Too bored to " .. (ia.label or "that"):lower() .. "; needs some fun first." end
    end
    if ia.leisure then
        for _, need in ipairs(BASIC_NEEDS) do
            if SS.Needs.Status(actor, need) == "critical" and not (ia.advert and ia.advert[need]) then
                return "Can't think about that: " .. T.needLabel[need] .. " comes first."
            end
        end
    end
    return nil
end

local COST_DATA = {} -- stands in for an order's data when there is none (emptied before each use)
function A.CostOf(world, actor, obj, iid, data)
    local ia = I[iid]
    if not ia then return 0 end
    if ia.costFn then
        if not data then
            for k in pairs(COST_DATA) do COST_DATA[k] = nil end
            data = COST_DATA
        end
        local c, text = ia.costFn(world, actor, obj, data)
        return c or 0, text
    end
    return ia.cost or 0, ia.ledger
end

-- Broken objects: unavailable or degraded by type (Tuning.brokenPolicy; default unavailable).
function A.BrokenPolicy(def)
    if not def then return "unavailable" end
    if def.brokenPolicy then return def.brokenPolicy end
    for _, tag in ipairs(def.tags or {}) do
        local p = T.brokenPolicy[tag]
        if p then return p end
    end
    if def.seat then return "degraded" end
    return "unavailable"
end

-- Slots ------------------------------------------------------------------------------------

local function objCellFree(world, lv, i, j) return not W.Blocked(world, lv, i, j) end

-- Target records. Callers that only look at a resolved target (availability checks) pass a
-- scratch table `into` that is refilled in place, with its cell lists reused (see ResolveSlot).
local EMPTY_SLOT = { approaches = {} } -- shared, read-only
local function target(into, obj, key, slot, approaches, on, face, faceObj, viaViewer)
    local t = into or {}
    t.obj, t.slotName, t.key, t.slot, t.approaches, t.on = obj, key, key, slot, approaches, on
    t.face, t.faceObj, t.viaViewer = face, faceObj, viaViewer
    return t
end
-- A cell list: a new one, or the scratch record's own list with its cells recycled.
local function cellList(into)
    if not into then return {}, nil end
    local list, pool = into._cells, into._cellPool
    if not list then list, pool = {}, {}; into._cells, into._cellPool = list, pool end
    for n = #list, 1, -1 do pool[#pool + 1] = list[n]; list[n] = nil end
    return list, pool
end
local function pushCell(list, pool, i, j, lv)
    local c
    if pool then c = pool[#pool]; pool[#pool] = nil end
    if c then c[1], c[2], c[3] = i, j, lv else c = { i, j, lv } end
    list[#list + 1] = c
end
local function onCell(into, i, j, lv)
    if not into then return { i, j, lv } end
    local c = into._on or {}
    into._on = c
    c[1], c[2], c[3] = i, j, lv
    return c
end
local slotApproaches -- defined below

-- Seats and standing spots for watching a viewer object (TV).
local STAND_SPOTS = { { 0, 2 }, { -1, 2 }, { 1, 2 }, { 0, 3 }, { -1, 3 }, { 1, 3 } }
local STAND_SLOTS, STAND_KEYS = {}, {}
for k = 1, #STAND_SPOTS do STAND_SLOTS[k] = { approaches = { STAND_SPOTS[k] } }; STAND_KEYS[k] = "stand" .. k end
local function resolveViewer(world, actor, obj, into)
    local fx, fy = G.rot(0, 1, obj.f or 0)
    local best, bestD, bestSlot
    local lv = obj.level or 0
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        local sd = o and SS.Objects[o.def]
        if sd and sd.seat and o.f == ((obj.f or 0) + 2) % 4 and (o.level or 0) == lv and not (o.state and o.state.broken and A.BrokenPolicy(sd) == "unavailable") then
            local dx, dy = o.x - obj.x, o.y - obj.y
            local along = dx * fx + dy * fy
            local side = math.abs(dx * fy - dy * fx)
            if along >= 1 and along <= 4 and side <= 1 then
                for name, sl in pairs(sd.slots or {}) do
                    if sl.on and (name == "seat" or sl.group == "seat") then
                        local holder = o.res and o.res[name]
                        if not holder or holder == actor.id then
                            local d = along + side + (holder == actor.id and -10 or 0)
                            if not bestD or d < bestD or (d == bestD and (o.id < best.id or (o.id == best.id and name < bestSlot))) then
                                best, bestD, bestSlot = o, d, name
                            end
                        end
                    end
                end
            end
        end
    end
    if best then
        local sl = SS.Objects[best.def].slots[bestSlot]
        local oi, oj = best.x, best.y
        if sl.cell then local cx, cy = G.rot(sl.cell[1], sl.cell[2], best.f); oi, oj = best.x + cx, best.y + cy end
        return target(into, best, bestSlot, sl, slotApproaches(best, bestSlot, sl), onCell(into, oi, oj, lv),
            ((sl.face or 0) + best.f) % 4, nil, obj.id)
    end
    -- standing spots in front of the set
    local busy
    local n = 0
    for k = 1, #STAND_SPOTS do
        if n >= T.tvStandSpots then break end
        local dx, dy = G.rot(STAND_SPOTS[k][1], STAND_SPOTS[k][2], obj.f or 0)
        local i, j = obj.x + dx, obj.y + dy
        if W.InLot(world.lot, i, j) and objCellFree(world, lv, i, j) then
            n = n + 1
            local key = STAND_KEYS[n]
            local holder = obj.res and obj.res[key]
            if not holder or holder == actor.id then
                local cells, pool = cellList(into)
                pushCell(cells, pool, i, j, lv)
                return target(into, obj, key, STAND_SLOTS[k], cells, nil, ((obj.f or 0) + 2) % 4)
            end
            busy = holder
        end
    end
    local other = busy and world.actors[busy]
    return nil, busy and ((other and other.name or "Someone") .. " is using it.") or "No place to watch from.", busy and "busy" or "slot"
end

-- Approach cells around an object (system objects, items on surfaces, puddles).
-- out/pool (optional): a list to fill and spare cells to reuse (a scratch target's).
local function aroundCells(world, obj, out, pool)
    local lv = obj.level or 0
    out = out or {}
    -- items on a surface are reached from their host's approach cells (a pan: from its cooker's)
    local host = obj.parent or obj.appliance
    local parent = host and world.lot.objects[host]
    if parent then
        local pdef = SS.Objects[parent.def]
        for _, sl in pairs(pdef and pdef.slots or EMPTY_SLOT) do
            if not sl.on then
                for n = 1, #(sl.approaches or EMPTY_SLOT.approaches) do
                    local dx, dy = G.rot(sl.approaches[n][1], sl.approaches[n][2], parent.f or 0)
                    local i, j = parent.x + dx, parent.y + dy
                    if objCellFree(world, lv, i, j) then pushCell(out, pool, i, j, lv) end
                end
            end
        end
    end
    local def = SS.Objects[obj.def]
    if def and W.NonBlocking(def, obj) and not parent and objCellFree(world, lv, obj.x, obj.y) then pushCell(out, pool, obj.x, obj.y, lv) end
    for k = 0, 3 do
        local d = G.DIRS[k]
        local i, j = obj.x + d[1], obj.y + d[2]
        if W.InLot(world.lot, i, j) and objCellFree(world, lv, i, j) and W.CanStepStatic(world, lv, obj.x, obj.y, i, j) then
            local dup = false
            for n = 1, #out do if out[n][1] == i and out[n][2] == j then dup = true end end
            if not dup then pushCell(out, pool, i, j, lv) end
        end
    end
    return out
end
A.AroundCells = function(world, obj) return aroundCells(world, obj) end

local function resolveAround(world, actor, obj, into)
    local holder = obj.res and obj.res.use
    if holder and holder ~= actor.id then
        local other = world.actors[holder]
        return nil, (other and other.name or "Someone") .. " is using it.", "busy"
    end
    local list, pool = cellList(into)
    local cells = aroundCells(world, obj, list, pool)
    if #cells == 0 then return nil, "Nobody can reach it.", "slot" end
    return target(into, obj, "use", EMPTY_SLOT, cells, nil, nil, true)
end

-- Standing spots near an object (dancing to a stereo, listening, watching a performance).
local SPOT_KEYS, spotKeyCount = {}, 0
local function spotKey(i, j)
    local row = SPOT_KEYS[j]
    if not row then row = {}; SPOT_KEYS[j] = row end
    local key = row[i]
    if not key then
        if spotKeyCount >= 4096 then SPOT_KEYS, spotKeyCount = {}, 0; row = {}; SPOT_KEYS[j] = row end
        key = "spot:" .. i .. ":" .. j
        row[i] = key
        spotKeyCount = spotKeyCount + 1
    end
    return key
end
local function resolveSpot(world, actor, obj, ia, into)
    local def = SS.Objects[obj.def]
    local cap = (def and def.quality and def.quality.capacity) or ia.capacity or T.danceCap
    local r = ia.radius or T.danceRadius
    local lv = obj.level or 0
    local used, mine = 0, nil
    for k, v in pairs(obj.res or EMPTY_SLOT) do
        if type(k) == "string" and k:sub(1, 5) == "spot:" then
            used = used + 1
            if v == actor.id then mine = k end
        end
    end
    if mine then
        local i, j = mine:match("^spot:(%-?%d+):(%-?%d+)$")
        i, j = tonumber(i), tonumber(j)
        local cells, pool = cellList(into)
        pushCell(cells, pool, i, j, lv)
        return target(into, obj, mine, EMPTY_SLOT, cells, nil, nil, true)
    end
    if used >= cap then return nil, "There's no room for anyone else.", "busy" end
    local bi, bj, bestD
    local room = W.ObjRoom(world, obj)
    for dj = -r, r do
        for di = -r, r do
            local i, j = obj.x + di, obj.y + dj
            if (di ~= 0 or dj ~= 0) and W.InLot(world.lot, i, j) and objCellFree(world, lv, i, j) and W.RoomAt(world, lv, i, j) == room then
                if not (obj.res and obj.res[spotKey(i, j)]) then
                    local d = math.abs(i + 0.5 - actor.x) + math.abs(j + 0.5 - actor.y) + (math.abs(di) + math.abs(dj)) * 0.5
                    if not bestD or d < bestD then bi, bj, bestD = i, j, d end
                end
            end
        end
    end
    if not bestD then return nil, "There's no room for anyone else.", "busy" end
    local cells, pool = cellList(into)
    pushCell(cells, pool, bi, bj, lv)
    return target(into, obj, spotKey(bi, bj), EMPTY_SLOT, cells, nil, nil, true)
end

-- Approach cells of an object's named slot, cached per object until the object moves, turns or
-- changes definition (they are offsets from the object alone: other objects coming and going
-- do not change them). The lists are shared (a target's approaches, an action's goal cells):
-- read-only.
local DEFAULT_APPROACHES = { { 0, 1 } }
function slotApproaches(obj, slotName, slot)
    local rt = SS.RT
    local cache = rt.approachCache
    if not cache then cache = setmetatable({}, { __mode = "k" }); rt.approachCache = cache end
    local c = cache[obj]
    local lv, f = obj.level or 0, obj.f or 0
    if not c or c.x ~= obj.x or c.y ~= obj.y or c.f ~= f or c.level ~= lv or c.def ~= obj.def then
        c = { x = obj.x, y = obj.y, f = f, level = lv, def = obj.def, lists = {} }
        cache[obj] = c
    end
    local list = c.lists[slotName]
    if list and list.slot == slot then return list end
    list = { slot = slot }
    local aps = slot.approaches or DEFAULT_APPROACHES
    for n = 1, #aps do
        local dx, dy = G.rot(aps[n][1], aps[n][2], f)
        list[n] = { obj.x + dx, obj.y + dy, lv }
    end
    c.lists[slotName] = list
    return list
end

-- Resolve where an actor goes to perform `iid` on object `obj`.
-- Returns target table or nil, reason, code ("busy" = temporarily taken, "slot" = impossible).
-- into (optional): a table to fill instead of a new one, for callers that only look at the result
-- (availability checks); its `approaches` list is shared and must not be changed.
local GROUP = {}
function A.ResolveSlot(world, actor, obj, iid, into)
    local ia = I[iid]
    local def = SS.Objects[obj.def]
    if not ia or not def then return nil, "Unknown action.", "slot" end
    local mode = ia.slot
    if mode == "viewer" then return resolveViewer(world, actor, obj, into) end
    if mode == "spot" then return resolveSpot(world, actor, obj, ia, into) end
    local slots = def.slots or {}
    if mode == "around" or (def.approachAround and (mode == nil or (type(mode) == "string" and not slots[mode]))) then
        return resolveAround(world, actor, obj, into)
    end
    local slotName, slot
    for k = #GROUP, 1, -1 do GROUP[k] = nil end
    local group = GROUP
    local fallback = false
    if type(mode) == "table" then
        for _, name in ipairs(mode) do
            if slots[name] then slotName, slot = name, slots[name]; break end
            for sn, sl in pairs(slots) do if sl.group == name then group[#group + 1] = sn end end
            if #group > 0 then break end
        end
    elseif mode then
        if slots[mode] then slotName, slot = mode, slots[mode]
        else for sn, sl in pairs(slots) do if sl.group == mode then group[#group + 1] = sn end end end
    end
    if not slot and #group == 0 then
        -- fallback: any slot the definition has (catalogue objects with other slot names)
        fallback = true
        for sn, sl in pairs(slots) do if sl.approaches then group[#group + 1] = sn end end
        if #group == 0 then
            if def.approachAround ~= false then return resolveAround(world, actor, obj, into) end
            return nil, "Nobody can use that from here.", "slot"
        end
    end
    if not slot then
        table.sort(group)
        local pick, pickD, busy
        for _, name in ipairs(group) do
            local sl = slots[name]
            local holder = obj.res and obj.res[name]
            if holder and holder ~= actor.id then busy = holder
            else
                local ap = sl.approaches and sl.approaches[1] or DEFAULT_APPROACHES[1]
                local dx, dy = G.rot(ap[1], ap[2], obj.f or 0)
                local d = math.abs(obj.x + dx + 0.5 - actor.x) + math.abs(obj.y + dy + 0.5 - actor.y)
                if holder == actor.id then d = -1 end
                if not pickD or d < pickD then pick, pickD = name, d end
            end
        end
        for k = #group, 1, -1 do group[k] = nil end
        if pick then slotName, slot = pick, slots[pick]
        elseif busy then
            local other = world.actors[busy]
            return nil, (other and other.name or "Someone") .. " is using it.", "busy"
        else return nil, "Nobody can use that from here.", "slot" end
    end
    local holder = obj.res and obj.res[slotName]
    if holder and holder ~= actor.id then
        local other = world.actors[holder]
        return nil, (other and other.name or "Someone") .. " is using it.", "busy"
    end
    local lv = obj.level or 0
    local approaches = slotApproaches(obj, slotName, slot)
    -- chores (cleaning, repairs, making the bed) are done standing beside the object: an "on"
    -- slot (a toilet seat, a bed) only lends its approach cells, nobody sits or lies down to scrub
    local stand = ia.chore and slot.on
    -- work done on the object itself (repairs, cleaning) or through a borrowed slot can be done
    -- from any free side when every approach of that slot is taken up by furniture (a TV's
    -- viewing spot two tiles out with a sofa on it)
    if (fallback or ia.chore) and (stand or not slot.on) then
        local free = false
        for n = 1, #approaches do
            local c = approaches[n]
            if W.InLot(world.lot, c[1], c[2]) and not W.Blocked(world, lv, c[1], c[2]) then free = true; break end
        end
        if not free then return resolveAround(world, actor, obj, into) end
    end
    if stand then return target(into, obj, slotName, slot, approaches, nil, nil, true) end
    local on
    if slot.on then
        local oi, oj = obj.x, obj.y
        if slot.cell then local cx, cy = G.rot(slot.cell[1], slot.cell[2], obj.f or 0); oi, oj = obj.x + cx, obj.y + cy end
        on = onCell(into, oi, oj, lv)
    end
    return target(into, obj, slotName, slot, approaches, on, ((slot.face or 0) + (obj.f or 0)) % 4)
end

-- Privacy (bathrooms): while someone performs a `privacy` interaction in an indoor room, other
-- people may not step into that room; they wait outside. Map rebuilt every step from actors.
A.privacy = {}
-- Bumped whenever who uses which bathroom privately changes (a waiter whose way was shut by
-- privacy re-plans only then).
A.privacyVersion = 0
local pvShadow = {}
local function privacyTouched() A.privacyVersion = A.privacyVersion + 1 end
local function privacyCompare()
    local pv = A.privacy
    local changed = false
    for k, v in pairs(pv) do if pvShadow[k] ~= v then changed = true; break end end
    if not changed then for k, v in pairs(pvShadow) do if pv[k] ~= v then changed = true; break end end end
    if changed then
        for k in pairs(pvShadow) do pvShadow[k] = nil end
        for k, v in pairs(pv) do pvShadow[k] = v end
        privacyTouched()
    end
end
local function privacyKey(level, room) return (level or 0) * 100000 + room end
function A.PrivacyHolder(world, level, room)
    if room == 0 then return nil end
    return A.privacy[privacyKey(level, room)]
end

-- Availability for menus and autonomy. Returns ok, reason, code. Codes: "busy" and "privacy"
-- are temporary (the executor waits); everything else is a refusal with a reason.
A.availHooks = {}
function A.RegisterAvailability(fn) A.availHooks[#A.availHooks + 1] = fn end
-- Access rules for roles (party guests never use beds, service workers keep off household
-- things): fn(world, actor, obj, iid) -> false, why. Same list as the availability hooks.
function A.RegisterAccessHook(fn) A.availHooks[#A.availHooks + 1] = fn end

-- A forecast line for a menu entry that is available (e.g. "Risky: 18% chance of a shock").
-- Interactions declare hint(world, actor, obj, data) -> text or nil.
function A.Hint(world, actor, obj, iid, data)
    local ia = I[iid]
    if not (ia and ia.hint) then return nil end
    local ok, text = pcall(ia.hint, world, actor, obj, data)
    if ok then return text end
    return nil
end

local AVAIL_TGT = {} -- availability only looks at the resolved target: one scratch record
function A.Available(world, actor, obj, iid, data)
    local ia = I[iid]
    if not ia then return false, "Unknown action.", "unknown" end
    local ok, why = A.CanUse(world, actor, ia)
    if not ok then return false, why, "who" end
    local def = obj and not ia.targetActor and SS.Objects[obj.def]
    if def and (def.kidOnly or def.adultOnly or def.pet) then
        local fok, fwhy = A.DesignFor(actor, ia, def)
        if not fok then return false, fwhy, "who" end
    end
    if def and obj.state and obj.state.broken and not ia.whenBroken and A.BrokenPolicy(def) == "unavailable" then
        return false, "It's broken and needs a repair.", "broken"
    end
    if ia.requireState and obj then
        for k, v in pairs(ia.requireState) do
            local cur = obj.state and obj.state[k] or false
            if cur ~= v then return false, ia.requireText or "Not applicable right now.", "state" end
        end
    end
    local cost = A.CostOf(world, actor, obj, iid, data)
    if cost > 0 and A.IsMember(world, actor) and (world.money or 0) < cost then
        return false, "Costs " .. U.fmtMoney(cost) .. "; the household cannot afford it.", "money"
    end
    local refuse = A.Refusal(world, actor, ia, obj)
    if refuse then return false, refuse, "refuse" end
    if ia.test then
        local tok, twhy = ia.test(world, actor, obj, data)
        if not tok then return false, twhy or "Not possible right now.", "test" end
    end
    for n = 1, #A.availHooks do
        local hok, hwhy, hcode = A.availHooks[n](world, actor, obj, iid, ia)
        if hok == false then return false, hwhy, hcode or "hook" end
    end
    if ia.targetActor or not obj or ia.slot == "here" then return true end
    local tgt, rwhy, code = A.ResolveSlot(world, actor, obj, iid, AVAIL_TGT)
    if not tgt then return false, rwhy, code end
    -- privacy: the target is inside a room someone else is using privately
    local lv = obj.level or 0
    local ai, aj = math.floor(actor.x), math.floor(actor.y)
    local myRoom = W.RoomAt(world, actor.level or 0, ai, aj)
    for n = 1, #tgt.approaches do
        local c = tgt.approaches[n]
        local room = W.RoomAt(world, c[3] or lv, c[1], c[2])
        local holder = A.PrivacyHolder(world, c[3] or lv, room)
        if holder and holder ~= actor.id and not (myRoom == room and (actor.level or 0) == (c[3] or lv)) then
            local other = world.actors[holder]
            return false, (other and other.name or "Someone") .. " is using the bathroom.", "privacy"
        end
    end
    if not actor.onObj and not SS.Nav.Reachable(world, ai, aj, actor.level or 0, tgt.approaches) then
        return false, "Can't get there from here.", "unreachable"
    end
    return true
end

-- Reservations ---------------------------------------------------------------------------

local function refreshOccupied(world, o)
    if not o or not o.state or o.state.occupied == nil then return end
    local any = false
    for _, v in pairs(o.res or {}) do
        local a = world.actors[v]
        if a and a.onObj == o.id then any = true end
    end
    if not any then o.state.occupied = nil end
end

-- Fridges and dishwashers show their `open` look while someone is using one (catalogue's HC-4);
-- it closes when the last user is done.
local function openLook(world, o, open, except)
    local def = o and SS.Objects[o.def]
    if not (def and (SS.Tags.Has(def, "fridge") or SS.Tags.Has(def, "dishwasher"))) then return end
    if not open then
        for id, a in pairs(world.actors) do
            local x = a.act
            if id ~= except and x and x.committed and x.target and x.target.oid == o.id then open = true; break end
        end
    end
    local st = o.state
    if ((st and st.open) == true) ~= open then
        o.state = st or {}
        o.state.open = open or nil
        SS.Emit("lotChanged", "state", o.id)
    end
end
A.OpenLook = openLook

local function release(world, act)
    if not act then return end
    if act.target then
        local o = world.lot.objects[act.target.oid]
        local key = act.target.key or act.target.slotName
        if o and o.res and o.res[key] == act.actorId then o.res[key] = nil end
        if o then refreshOccupied(world, o) end
        if o and act.committed and o.state and o.state.open then openLook(world, o, false, act.actorId) end
        local v = act.target.viewer and world.lot.objects[act.target.viewer]
        if v and v.watchers then
            v.watchers[act.actorId] = nil
            if not next(v.watchers) then
                if v.state and not act.keepOn and not v.keepOn then v.state.on = false end
                v.watchers = nil
                SS.Emit("lotChanged", "state", v.id)
            end
        end
    end
    if act.privacyKey and A.privacy[act.privacyKey] == act.actorId then A.privacy[act.privacyKey] = nil; privacyTouched() end
end

-- Held items (carried plates, ingredients, bags) are settled by the chains module when an
-- action that holds them does not complete.
local function settleHeld(world, actor, why)
    if actor.held and SS.Chains and SS.Chains.SettleHeld then SS.Chains.SettleHeld(world, actor, why) end
end

local function finish(world, actor, status, reason)
    local act = actor.act
    if not act then return end
    release(world, act)
    actor.act = nil
    actor.doing = nil
    local ia = I[act.iid]
    local target = act.oid and world.lot.objects[act.oid]
    if ia and ia.onEnd then ia.onEnd(world, actor, act, target, status) end
    if ia and act.performed then
        if ia.outfit and act.data and act.data.prevOutfit and actor.outfit == ia.outfit and not act.keepOutfit then
            actor.outfit = act.data.prevOutfit
        end
        if ia.carry and actor.carry == ia.carry and not actor.held then actor.carry = nil end
        local fun = ia.rate and ia.rate.fun or ia.gain and ia.gain.fun or (act.rates and act.rates.fun)
        if fun and fun > 0 and act.t > 0 then SS.Needs.RepAdd(world, actor, ia.repKey or act.iid, 0.5 + act.t / 60) end
    end
    if status ~= "done" and actor.held and not (ia and ia.keepHeld) then settleHeld(world, actor, status) end
    if ia and ia.next and status == "done" then
        local nxt = ia.next(world, actor, act, target)
        if nxt then
            if nxt.manual == nil then nxt.manual = act.manual end
            nxt.chain = true
            if not (nxt.optional and not freeWill(world) and A.IsMember(world, actor)) then
                actor.queue = actor.queue or {}
                table.insert(actor.queue, 1, nxt)
                syncOrders(actor)
            end
        end
    end
    actor.sleeping, actor.walking, actor.onObj = nil, nil, nil
    actor.z = nil
    actor.pose = "idle"
    if status == "failed" then
        if not act.quiet then A.Message(world, actor, reason or "Could not do that.", "noroute") end
        actor.cool = actor.cool or {}
        if not act.manual then
            -- the same key for object, person and provider choices ("<oid or tid>:<iid>"); a longer
            -- rest someone else set (events' 24 hours after a shock) is kept with its reason
            local key = (act.oid or act.tid or "") .. ":" .. act.iid
            local untilT = world.time + (act.routeFailed and T.routeFailCooldown or T.failCooldown)
            actor.tmp = actor.tmp or {}
            actor.tmp.coolWhy = actor.tmp.coolWhy or {}
            if (actor.cool[key] or -1e9) < untilT then
                actor.cool[key] = untilT
                actor.tmp.coolWhy[key] = reason or "Could not do that."
            end
        end
        if act.routeFailed then
            actor.tmp = actor.tmp or {}
            local rf = actor.tmp.routeFails or {}
            actor.tmp.routeFails = rf
            rf[#rf + 1] = { t = world.time, iid = act.iid, oid = act.oid, why = reason }
            while #rf > 6 do table.remove(rf, 1) end
        end
        if act.manual and A.IsMember(world, actor) and not act.quiet then SS.Needs.Feel(world, actor, "frustrated") end
    end
    SS.Emit("actionEnded", actor, act, status, reason)
end

A.Finish = function(world, actor, status, reason) finish(world, actor, status, reason) end

-- Graceful interruption from outside (emergency, wake-up, a player order replacing free will,
-- a deleted object). People on furniture step off first. status defaults to "interrupted".
function A.Interrupt(world, actor, why, status)
    local act = actor.act
    if not act then return end
    status = status or "interrupted"
    if (act.phase == "perform" or act.phase == "enter") and act.target and act.target.on and actor.onObj then
        act.interruptWhy, act.interruptStatus = why or "interrupted", status
        if act.phase == "enter" then act.phase = "exit"; act.endStatus = status; act.endWhy = why; actor.onObj = nil end
    elseif act.phase == "exit" then
        act.endStatus = act.endStatus or status
    else
        finish(world, actor, status, why)
    end
end

-- Wake someone who is asleep (a crying baby, a caller at the door): the sleep ends
-- "interrupted" with the reason (Chains.WAKE_TEXT[why] or why); energy already gained is kept and
-- the sleep outfit comes off. Returns false when the person isn't asleep yet (still walking to
-- bed) or has passed out. Emits wokeUp(world, actor, why).
function A.Wake(world, actor, why)
    local act = actor and actor.act
    local ia = act and I[act.iid]
    if not (ia and ia.sleeping) then return false end
    if not (SS.Chains and SS.Chains.WakeUp and SS.Chains.WakeUp(world, actor, why or "player", "interrupted")) then return false end
    if actor.needs and (actor.needs.energy or 0) < 30 then
        actor.balloon = { icon = "energy", kind = "thought", untilT = world.time + 15 }
    end
    return true
end

-- Orders ------------------------------------------------------------------------------------
local function reserve(world, actor, act, tgt)
    act.target = { oid = tgt.obj.id, slotName = tgt.slotName, key = tgt.key or tgt.slotName, on = tgt.on, face = tgt.face,
        viewer = tgt.viaViewer, faceObj = tgt.faceObj }
    act.goalCells = tgt.approaches
    tgt.obj.res = tgt.obj.res or {}
    tgt.obj.res[act.target.key] = actor.id
    act.path, act.pi = nil, nil
    act.phase = "route"
    mirror(actor, act)
end

-- A spot to wait near `obj` (outside a private room when privateRoom is given).
function A.WaitSpot(world, actor, obj, privateLevel, privateRoom)
    local lv = obj and (obj.level or 0) or (actor.level or 0)
    local ci, cj = obj and obj.x or math.floor(actor.x), obj and obj.y or math.floor(actor.y)
    local start = SS.Nav.RegionAt(world, actor.level or 0, math.floor(actor.x), math.floor(actor.y))
    local avoid = {}
    if obj then
        for _, a in pairs(world.actors) do if a ~= actor then avoid[math.floor(a.x) .. ":" .. math.floor(a.y)] = true end end
    end
    local anyPrivate = next(A.privacy) ~= nil
    local i, j = SS.Nav.NearestFree(world, lv, ci, cj, 5, function(i, j)
        local room = W.RoomAt(world, lv, i, j)
        if privateRoom and room == privateRoom then return false end
        -- never inside a bathroom someone else is using (the way to it is shut anyway)
        if anyPrivate then
            local holder = A.PrivacyHolder(world, lv, room)
            if holder and holder ~= actor.id then return false end
        end
        if avoid[i .. ":" .. j] then return false end
        if math.abs(i - ci) + math.abs(j - cj) < 2 and not privateRoom then return false end
        local r = SS.Nav.RegionAt(world, lv, i, j)
        return not start or r == start
    end)
    if i then return { i, j, lv } end
end

local function enterWait(world, actor, act, obj, why, code)
    local limit = act.manual and T.waitManual or T.waitAuto
    act.phase = "wait"
    -- the wait is bounded for the whole action: waiting again (the way was shut again after a
    -- re-check) keeps the first deadline and the annoyance clock
    local since = act.waitSince or world.time
    act.waitSince = since
    act.wait = { why = why, code = code, untilT = since + limit, nextCheck = world.time + T.waitCheck, t0 = since }
    local lv, room
    local pia = I[act.iid]
    if obj and (code == "privacy" or (pia and pia.privacy)) then
        -- a bathroom fixture: wait outside the room (it becomes private as soon as the person
        -- ahead starts), not beside the fixture
        lv = obj.level or 0
        room = W.ObjRoom(world, obj)
        if room == 0 then lv, room = nil, nil end
    end
    local spot = A.WaitSpot(world, actor, obj, lv, room)
    if spot then
        local ai, aj = math.floor(actor.x), math.floor(actor.y)
        if not (spot[1] == ai and spot[2] == aj) then act.waitGoal = { spot } end
    end
    act.path, act.pi = nil, nil
    mirror(actor, act)
    SS.Emit("actionWaiting", world, actor, act, why)
end

-- The target may have changed since the action was chosen: broken on the way, switched on by
-- someone else, already repaired, taken over. Checked again on arrival, at the commit point
-- (before any money moves) and when the object breaks. Returns ok, why, code; code "broken" means
-- another object of the same kind may do instead.
local function stillValid(world, actor, act, ia)
    if not ia or ia.targetActor or act.cellTarget or not act.oid then return true end
    local obj = world.lot.objects[act.oid]
    if not obj or (act.target and not world.lot.objects[act.target.oid]) then return false, "That object is gone.", "gone" end
    local def = SS.Objects[obj.def]
    local st = obj.state
    if st and st.broken and not ia.whenBroken and A.BrokenPolicy(def) == "unavailable" then
        return false, "The " .. ((def and def.name) or "thing") .. " is broken.", "broken"
    end
    if ia.requireState then
        for k, v in pairs(ia.requireState) do
            local cur = st and st[k] or false
            if cur ~= v then return false, ia.requireText or "Not applicable right now.", "state" end
        end
    end
    if ia.test then
        local ok, why = ia.test(world, actor, obj, act.data)
        if not ok then return false, why or "Not possible right now.", "test" end
    end
    for n = 1, #A.availHooks do
        local hok, hwhy, hcode = A.availHooks[n](world, actor, obj, act.iid, ia)
        if hok == false then return false, hwhy, hcode or "hook" end
    end
    return true
end
A.StillValid = stillValid

-- The target stopped being usable before the commit point. A broken or vanished object is
-- swapped for another one offering the same thing (the other toilet) when there is one;
-- otherwise the action fails with the reason, stepping off first if the person is on it.
-- Returns true when the action goes on (with the new target).
local function targetLost(world, actor, act, why, code)
    if (code == "broken" or code == "gone") and not actor.onObj and act.phase ~= "enter" then
        local alt = A.Alternative(world, actor, act)
        local tgt = alt and A.ResolveSlot(world, actor, alt, act.iid)
        if tgt then
            release(world, act)
            act.target, act.wait, act.waitGoal = nil, nil, nil
            act.oid = alt.id
            reserve(world, actor, act, tgt)
            SS.Emit("actionAlternative", world, actor, act, alt)
            return true
        end
    end
    if act.target and act.target.on and (actor.onObj or act.phase == "enter") then
        act.phase = "exit"
        act.endStatus, act.endWhy = "failed", why
        actor.onObj = nil
        mirror(actor, act)
        return false
    end
    finish(world, actor, "failed", why)
    return false
end

-- Check an action that has not reached its commit point yet against its (possibly changed)
-- target: Maintenance.Break calls this for everyone on their way to, waiting for or stepping
-- onto an object that just broke. Returns true when the action goes on.
function A.Recheck(world, actor)
    local act = actor.act
    if not act or act.performed or act.phase == "exit" or act.phase == "perform" then return true end
    local ok, why, code = stillValid(world, actor, act, I[act.iid])
    if ok then return true end
    return targetLost(world, actor, act, why, code)
end

-- Start an action record from an order. Returns true when it is under way.
-- order = { iid, oid? (object), tid? (target actor), x?, y?, level?, manual, data?, chain?, optional?,
--           charged?, performed?, t? (resume) }
local function begin(world, actor, order)
    local act = { iid = order.iid, oid = order.oid, tid = order.tid, manual = order.manual, actorId = actor.id,
        phase = "select", t = order.t or 0, data = order.data or {}, chain = order.chain, optional = order.optional,
        charged = order.charged, performed = order.performed, x = order.x, y = order.y, level = order.level,
        dur = order.dur, maxDur = order.maxDur, quiet = order.quiet, restarted = order.restarted }
    actor.act = act
    if not order.manual then act.low0 = order.low0 or lowNeeds(actor) end
    local ia = I[order.iid]
    -- redirect: an interaction that really starts somewhere else ("Cook Here" on a stove starts at
    -- the fridge; "Continue Cooking" on a pot goes to the step that needs doing). Once per order.
    if ia and ia.redirect and not order.redirected then
        local nord, why = ia.redirect(world, actor, order)
        if nord == false then act.label = ia.label; finish(world, actor, "failed", why or "Not possible right now."); return false end
        if nord then
            nord.redirected = true
            if nord.manual == nil then nord.manual = order.manual end
            if nord.chain == nil then nord.chain = order.chain end
            if nord.optional == nil then nord.optional = order.optional end
            actor.act = nil
            return begin(world, actor, nord)
        end
    end
    if order.iid == "goto" then
        act.goalCells = { { order.x, order.y, order.level or actor.level or 0 } }
        act.label = "Go Here"
        act.phase = "route"
        mirror(actor, act)
        return true
    end
    if not ia then finish(world, actor, "failed", "Unknown action."); return false end
    act.label = ia.label
    if ia.targetActor then
        local target = order.tid and world.actors[order.tid]
        if not target then finish(world, actor, "failed", "They're not here any more."); return false end
        local ok, why = A.Available(world, actor, target, order.iid, act.data)
        if not ok then finish(world, actor, "failed", why); return false end
        local ti, tj = math.floor(target.x), math.floor(target.y)
        local lv = target.level or 0
        local cells = { { ti, tj + 1, lv }, { ti + 1, tj, lv }, { ti, tj - 1, lv }, { ti - 1, tj, lv } }
        -- someone joining a group stands beside it, not on top of a member: spots other people
        -- stand on are only used when every spot is taken (order kept, so routing is deterministic).
        -- A side cell that is furniture or behind a wall from the target is no spot at all (it
        -- was a lone unreachable goal when the other spots had people on them: social's HC-14).
        local free, taken = {}, {}
        for n = 1, 4 do
            local c = cells[n]
            if not W.Blocked(world, lv, c[1], c[2]) and W.CanStepStatic(world, lv, ti, tj, c[1], c[2]) then
                local busy = false
                for _, p in pairs(world.actors) do
                    if p ~= actor and p ~= target and (p.level or 0) == lv and math.floor(p.x) == c[1] and math.floor(p.y) == c[2] then busy = true; break end
                end
                if busy then taken[#taken + 1] = c else free[#free + 1] = c end
            end
        end
        if #free == 0 and #taken == 0 then finish(world, actor, "failed", "There's no room to stand beside them."); return false end
        act.goalCells = (#free > 0) and free or taken
        act.phase = "route"
        mirror(actor, act)
        return true
    end
    if ia.slot == "cell" then
        -- a floor cell target (the curb, a spot outdoors): order.x, order.y, order.level
        if not order.x then finish(world, actor, "failed", "Nowhere to go."); return false end
        local ok, why = A.Available(world, actor, nil, order.iid, act.data)
        if not ok then finish(world, actor, "failed", why); return false end
        act.goalCells = { { order.x, order.y, order.level or actor.level or 0 } }
        act.cellTarget = true
        act.phase = "route"
        mirror(actor, act)
        return true
    end
    if ia.slot == "here" or not order.oid then
        if ia.slot ~= "here" then finish(world, actor, "failed", "That object is gone."); return false end
        local ok, why = A.Available(world, actor, nil, order.iid, act.data)
        if not ok then finish(world, actor, "failed", why); return false end
        act.phase = "perform"
        act.approach = { math.floor(actor.x), math.floor(actor.y), actor.level or 0 }
        mirror(actor, act)
        return true
    end
    local obj = world.lot.objects[order.oid]
    if not obj then finish(world, actor, "failed", "That object is gone."); return false end
    act.cost, act.ledgerText = A.CostOf(world, actor, obj, order.iid, act.data)
    local ok, why, code = A.Available(world, actor, obj, order.iid, act.data)
    if not ok then
        if code == "busy" or code == "privacy" then enterWait(world, actor, act, obj, why, code); return true end
        finish(world, actor, "failed", why)
        return false
    end
    local tgt, rwhy = A.ResolveSlot(world, actor, obj, order.iid)
    if not tgt then finish(world, actor, "failed", rwhy); return false end
    reserve(world, actor, act, tgt)
    return true
end

local function cellOf(actor) return math.floor(actor.x), math.floor(actor.y) end

-- Occupancy by people (rebuilt every step) ------------------------------------------------
A.cellOwner = {}
local function cellKey(world, level, i, j) return (level or 0) * 100000 + j * 256 + i end
function A.CellOwner(world, level, i, j) return A.cellOwner[cellKey(world, level, i, j)] end

-- Per-step bookkeeping: people's cells, bathroom privacy, think budget.
A.thinkBudget, A.inStep = 1e9, false
function A.NewStep(world)
    local occ = A.cellOwner
    for k in pairs(occ) do occ[k] = nil end
    local pv = A.privacy
    for k in pairs(pv) do pv[k] = nil end
    for id, a in pairs(world.actors) do
        if not a.onObj then
            local k = cellKey(world, a.level, math.floor(a.x), math.floor(a.y))
            if not occ[k] or id < occ[k] then occ[k] = id end
        end
        local act = a.act
        if act and act.privacyKey and act.phase ~= "exit" then pv[act.privacyKey] = id end
    end
    privacyCompare()
    A.thinkBudget = T.maxThinksPerStep
end

local function priority(actor)
    local act = actor.act
    return (act and act.manual) and 2 or 1
end

-- An actor stands in the next cell: wait briefly, ask an idle person to step aside, route
-- around people standing still, and after Tuning.yieldMax pass through (never deadlock).
local function yieldTo(world, actor, act, otherId, c, dt)
    local B = world.actors[otherId]
    if not B or B == actor or (B.level or 0) ~= (c[3] or 0) or B.onObj then return "pass" end
    act.yieldT = (act.yieldT or 0) + dt
    local limit = T.yieldMax
    if not B.act and not (B.queue and #B.queue > 0) then
        -- ask them to step aside (one record per person, refilled; idleUpkeep reads it next step)
        local tmp = B.tmp or {}
        B.tmp = tmp
        local s = tmp.shooRec or {}
        tmp.shooRec = s
        s.by, s.t, s.i, s.j = actor.id, world.time, c[1], c[2]
        tmp.shoo = s
        if act.yieldT > limit then return "pass" end
        return "wait"
    end
    if not B.walking then
        if not act.avoided then act.avoided = true; return "avoid" end
        if act.yieldT > limit then return "pass" end
        return "wait"
    end
    local mine, theirs = priority(actor), priority(B)
    if mine > theirs or (mine == theirs and actor.id < B.id) then limit = limit * 0.25 end
    if act.yieldT > limit then return "pass" end
    return "wait"
end

local PLAN_OPTS = { budget = true } -- the executor's searches are budgeted per step (Nav.FindPath)
-- People standing still, for a search that routes around them. Reused (cleared and refilled) by
-- every such search; routeFailed's probe runs straight after the failed search, same step, so it
-- still holds that search's set.
local AVOID = {}
local AVOID_OPTS = { avoid = AVOID, budget = true }
local PROBE_OPTS = { noHooks = true, force = true, avoid = nil }

-- Plan a route to act.goalCells (or a wait spot). Returns "ok", "defer", or "fail" (with reason).
local function plan(world, actor, act, goals, avoidPeople)
    local si, sj = cellOf(actor)
    local opts = PLAN_OPTS
    if avoidPeople then
        for k in pairs(AVOID) do AVOID[k] = nil end
        local lot = world.lot
        local plane = lot.w * lot.h
        for _, b in pairs(world.actors) do
            if b ~= actor and not b.walking and not b.onObj then
                AVOID[(b.level or 0) * plane + math.floor(b.y) * lot.w + math.floor(b.x)] = true
            end
        end
        opts = AVOID_OPTS
    end
    local path, why, rule = SS.Nav.FindPath(world, si, sj, actor.level or 0, goals, actor, opts)
    act.avoidUsed = avoidPeople and true or nil
    if path then
        act.path, act.pi = path, 1
        return "ok"
    end
    if why == "budget" then return "defer" end
    return "fail", why, rule
end

-- Move toward (tx,ty) by up to dist tiles. Returns remaining distance, arrived.
local function stepToward(actor, tx, ty, dist)
    local dx, dy = tx - actor.x, ty - actor.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d > 0.0001 then actor.facing = G.dirToFacing(dx, dy) end
    if d <= dist then
        actor.x, actor.y = tx, ty
        actor.stride = (actor.stride or 0) + d
        return dist - d, true
    end
    actor.x, actor.y = actor.x + dx / d * dist, actor.y + dy / d * dist
    actor.stride = (actor.stride or 0) + dist
    return 0, false
end
A.StepToward = stepToward

-- Walk a stair flight: waypoints from the bottom cell through the run cells to the top
-- landing (or the reverse). The actor keeps the lower level while on the flight and
-- carries a height offset z (tiles); the level switches on arrival. Returns unused distance.
function A.ClimbStairs(world, actor, act, node, dist)
    local lot = world.lot
    local o = lot.objects[node.stairs]
    local st = o and W.StairInfo(o)
    if not st then act.path = nil; return 0 end
    local sp = T.stairSpeed or 0.6
    if not act.flight then
        local up = (node[3] or 0) > (actor.level or 0)
        local pts = {}
        local nrun = #st.run
        if up then
            for n = 1, nrun do pts[#pts + 1] = { st.run[n][1] + 0.5, st.run[n][2] + 0.5, W.STORY * n / (nrun + 1) } end
            pts[#pts + 1] = { st.top[1] + 0.5, st.top[2] + 0.5, W.STORY }
        else
            actor.level = st.level
            actor.z = W.STORY
            for n = nrun, 1, -1 do pts[#pts + 1] = { st.run[n][1] + 0.5, st.run[n][2] + 0.5, W.STORY * n / (nrun + 1) } end
            pts[#pts + 1] = { st.bottom[1] + 0.5, st.bottom[2] + 0.5, 0 }
        end
        act.flight = { pts = pts, k = 1, up = up, fromZ = actor.z or 0 }
    end
    local fl = act.flight
    while dist > 0 and fl.pts[fl.k] do
        local p = fl.pts[fl.k]
        local sx, sy = actor.x, actor.y
        local arrived
        local seg = math.sqrt((p[1] - sx) ^ 2 + (p[2] - sy) ^ 2)
        local startZ = actor.z or 0
        local rem
        rem, arrived = stepToward(actor, p[1], p[2], dist * sp)
        local moved = dist * sp - rem
        if seg > 1e-6 then actor.z = startZ + (p[3] - startZ) * math.min(1, moved / seg) else actor.z = p[3] end
        dist = rem / sp
        if arrived then actor.z = p[3]; fl.k = fl.k + 1 end
    end
    if not fl.pts[fl.k] then
        actor.level = node[3] or 0
        actor.z = nil
        act.flight = nil
        act.pi = act.pi + 1
    end
    return dist
end

-- Follow act.path. Returns "arrived" | "moving" | "replan" | "avoid".
local function followPath(world, actor, act, dt)
    actor.walking = true
    actor.pose = "walk"
    local speed = T.walkSpeed
    if actor.needs and not actor.noNeeds and SS.Needs.Status(actor, "energy") == "critical" then speed = speed * T.criticalWalk end
    local dist = speed * dt
    while dist > 0 and act.path and act.path[act.pi] do
        local c = act.path[act.pi]
        if c.stairs then
            dist = A.ClimbStairs(world, actor, act, c, dist)
            if not act.path then return "replan" end
        else
            if W.Blocked(world, c[3] or 0, c[1], c[2]) then return "replan" end
            local ci, cj = cellOf(actor)
            if (ci ~= c[1] or cj ~= c[2]) and act.passCell ~= c then
                local other = A.cellOwner[cellKey(world, c[3], c[1], c[2])]
                if other and other ~= actor.id then
                    local r = yieldTo(world, actor, act, other, c, dt)
                    if r == "wait" then actor.walking = nil; actor.pose = "idle"; return "moving" end
                    if r == "avoid" then return "avoid" end
                    act.passCell = c
                end
            end
            local arrived
            dist, arrived = stepToward(actor, c[1] + 0.5, c[2] + 0.5, dist)
            if arrived then act.pi = act.pi + 1; act.yieldT = nil; act.passCell = nil end
        end
    end
    if act.path and not act.path[act.pi] then return "arrived" end
    if not act.path then return "replan" end
    return "moving"
end

-- A route could not be planned. Blocked only by rules (privacy) -> wait; blocked by a lock or
-- another rule (staff only, visiting permissions) -> fail saying so; otherwise fail. `rule` is
-- what the search's pre-check found ("lock" / "privacy"): then no probe search is needed.
local function waitForBathroom(world, actor, act)
    local obj = act.target and world.lot.objects[act.target.oid]
    release(world, act)
    act.target = nil
    enterWait(world, actor, act, obj, "Someone is using the bathroom.", "privacy")
    -- the way is shut by someone's privacy: nothing to re-plan until who uses which bathroom changes
    act.wait.pv = A.privacyVersion
end
local function routeFailed(world, actor, act, why, rule)
    local ruled = false
    if rule == "privacy" and act.phase ~= "wait" then
        waitForBathroom(world, actor, act)
        return
    elseif rule then
        ruled = true
    elseif act.goalCells and why == "blocked" then
        local si, sj = cellOf(actor)
        -- same people-avoid set as the failed search, so people in the way are never taken for a lock
        PROBE_OPTS.avoid = act.avoidUsed and AVOID or nil
        local p2 = SS.Nav.FindPath(world, si, sj, actor.level or 0, act.goalCells, actor, PROBE_OPTS)
        PROBE_OPTS.avoid = nil
        if p2 and next(A.privacy) and act.phase ~= "wait" then
            waitForBathroom(world, actor, act)
            return
        end
        ruled = p2 ~= nil
    end
    local what = act.oid and world.lot.objects[act.oid] and SS.Objects[world.lot.objects[act.oid].def]
    act.routeFailed = true
    if ruled then
        finish(world, actor, "failed", what and ("The way to the " .. what.name .. " is locked or off limits.") or "The way there is locked or off limits.")
    else
        finish(world, actor, "failed", what and ("Can't find a way to the " .. what.name .. ".") or "Can't find a way there.")
    end
end

-- Alternative object offering the same interaction (another toilet, another chair).
-- Chain steps that are not on the object's menu name the tags that can host them (ia.useTags),
-- or supply their own finder (ia.findAlt(world, actor, act) -> obj).
function A.Alternative(world, actor, act)
    local ia = I[act.iid]
    if ia and ia.findAlt then return ia.findAlt(world, actor, act) end
    local tags = ia and ia.useTags
    local best, bestD
    for _, oid in ipairs(W.ObjectIds(world)) do
        local o = world.lot.objects[oid]
        if o and oid ~= act.oid then
            local def = SS.Objects[o.def]
            local has = false
            for _, iid in ipairs(def and def.actions or {}) do if iid == act.iid then has = true; break end end
            if not has and tags and def then
                for n = 1, #tags do if SS.Tags.Has(def, tags[n]) then has = true; break end end
            end
            if has and A.Available(world, actor, o, act.iid, act.data) then
                local d = math.abs(o.x + 0.5 - actor.x) + math.abs(o.y + 0.5 - actor.y) + math.abs((o.level or 0) - (actor.level or 0)) * T.levelCost
                if not bestD or d < bestD or (d == bestD and oid < best.id) then best, bestD = o, d end
            end
        end
    end
    return best
end

local function faceTarget(world, actor, act)
    local o = act.target and world.lot.objects[act.target.oid]
    if not o then return end
    if act.target.face and not act.target.faceObj then actor.facing = act.target.face
    else
        local dx, dy = o.x + 0.5 - actor.x, o.y + 0.5 - actor.y
        if math.abs(dx) + math.abs(dy) > 0.01 then actor.facing = G.dirToFacing(dx, dy) end
    end
end

-- Effects --------------------------------------------------------------------------------

-- Multiplier for a need effect from the object's quality, dirt, damage and fun repetition.
function A.EffectMult(world, actor, act, ia, need, def, obj)
    local m = 1
    if obj and obj.state and obj.state.broken and A.BrokenPolicy(def) == "degraded" then m = m * T.degraded end
    if need == "hygiene" and obj and (obj.dirt or 0) >= T.dirtyAt then m = m * T.dirtyGainMult end
    if need == "fun" and act.repFactor then m = m * act.repFactor end
    if act.mult and act.mult[need] then m = m * act.mult[need] end
    return m
end

local function applyEffects(world, actor, act, ia, dt)
    local obj = act.target and world.lot.objects[act.target.oid]
    local def = obj and SS.Objects[obj.def]
    local dur = act.dur or ia.dur
    local gain = act.gain or ia.gain
    if gain and dur and dur > 0 then
        local frac = math.min(dt, dur - act.t) / dur
        if frac > 0 then
            for need, amt in pairs(gain) do
                local q = 1
                if amt > 0 and def and def.ratings and def.ratings[need] and not act.gain then q = 0.7 + 0.06 * def.ratings[need] end
                SS.Needs.Add(actor, need, amt * frac * q * (amt > 0 and A.EffectMult(world, actor, act, ia, need, def, obj) or 1))
            end
        end
    end
    local rates = act.rates or ia.rate
    if rates then
        for need, r in pairs(rates) do
            local rr = (not act.rates and def and def.rates and def.rates[need]) or r
            if rr > 0 then rr = rr * A.EffectMult(world, actor, act, ia, need, def, obj) end
            SS.Needs.Add(actor, need, rr * dt / 60)
        end
    end
    -- posture: sitting or lying on something while doing another activity (watching from the
    -- sofa, eating at the table) gives part of that seat's comfort; standing gives none
    if act.target and act.target.on and def and def.rates and def.rates.comfort and def.rates.comfort > 0
        and not (rates and rates.comfort) then
        SS.Needs.Add(actor, "comfort", def.rates.comfort * T.postureShare * dt / 60)
    end
    local skill = act.skill or ia.skill
    if skill and SS.Skills and SS.Skills.Gain then
        local f = A.SkillFactor(def)
        for name, perHour in pairs(skill) do SS.Skills.Gain(world, actor, name, perHour * dt / 60 * f) end
    end
end

-- Practice on a better design goes faster: the catalogue's quality.skill (1 = normal practice).
function A.SkillFactor(def)
    local q = def and def.quality and def.quality.skill
    if type(q) == "number" and q > 0 then return q end
    return 1
end

local function addresses(ia, act, need, world, actor)
    if ia.advert and ia.advert[need] then return true end
    local r = act.rates or ia.rate
    if r and r[need] and r[need] > 0 then return true end
    local g = act.gain or ia.gain
    if g and g[need] and g[need] > 0 then return true end
    -- dynamic adverts (repairing the only shower is the way to get clean): asked once per action
    if ia.advertise and world and actor then
        if act.advCache == nil then
            local o = act.oid and world.lot.objects[act.oid]
            local adv = o and ia.advertise(world, actor, o)
            -- kept for the whole action: a copy (advertisers refill their own table)
            if adv then
                local copy = {}
                for k, v in pairs(adv) do copy[k] = v end
                adv = copy
            end
            act.advCache = adv or false
        end
        local adv = act.advCache
        if adv and (adv[need] or 0) > 0 then return true end
    end
    return false
end


-- Returns stop, why, status.
local function shouldStop(world, actor, act, ia)
    if act.stopRequested then return true, nil, "cancelled" end
    if act.interruptWhy then return true, act.interruptWhy, act.interruptStatus or "interrupted" end
    if act.complete then return true, nil, "done" end
    if act.failWhy then return true, act.failWhy, "failed" end
    local dur = act.dur or ia.dur
    if dur and act.t >= dur then return true, nil, "done" end
    -- night sleep holds through the night (Tuning.sleepHoldMax): full energy at 2 a.m. is no reason
    -- to get up; the night's end, a need, an alarm, work or school, a noise or an emergency is
    local hold = ia.holdNight and act.t < (T.sleepHoldMax or 0) and SS.Chains and SS.Chains.IsNight and SS.Chains.IsNight(world)
    local maxDur = act.maxDur or ia.maxDur
    if maxDur and act.t >= maxDur and not hold then return true, nil, "done" end
    if ia.untilFull and actor.needs[ia.untilFull] >= 98 and not hold then return true, nil, "done" end
    if actor.noNeeds then return false end
    if ia.wakeOn then
        for need, lim in pairs(ia.wakeOn) do
            if actor.needs[need] <= lim then return true, need, "interrupted" end
        end
    end
    -- optional activities stop when a different need becomes urgent (autonomous) or critical
    -- (player-ordered open-ended leisure); short actions and chores finish first.
    if not dur and act.t >= 2 and not ia.sleeping then
        local low0 = act.low0
        for _, need in ipairs(T.needs) do
            if need ~= "room" and need ~= "social" and not (low0 and low0[need] and not act.manual) and not addresses(ia, act, need, world, actor) then
                local v = actor.needs[need]
                if (not act.manual and v < T.urgent) or (act.manual and ia.leisure and v <= (T.critical[need] or -80)) then
                    return true, need, "interrupted"
                end
            end
        end
    end
    return false
end

-- Commit point: the first perform tick (and the resume path after a load).
local function commit(world, actor, act, ia)
    local o = act.target and world.lot.objects[act.target.oid]
    local member = A.IsMember(world, actor)
    if not act.performed then
        -- last check before anything happens: nothing is charged or changed for a target that
        -- broke or changed state since it was chosen
        local ok, why, code = stillValid(world, actor, act, ia)
        if not ok then targetLost(world, actor, act, why, code); return false end
        local cost = act.cost or A.CostOf(world, actor, o or (act.oid and world.lot.objects[act.oid]), act.iid, act.data)
        if cost and cost > 0 and member and not act.charged then
            if (world.money or 0) < cost then finish(world, actor, "failed", "Not enough money."); return false end
            A.Charge(world, cost, act.ledgerText or ia.ledger or ia.label, ia.ledgerCat or "food")
            act.charged = true
        end
        if ia.setState and o then
            o.state = o.state or {}
            for k, v in pairs(ia.setState) do o.state[k] = v end
            SS.Emit("lotChanged", "state", o.id)
            W.Touch()
        end
        if ia.outfit then
            -- a restart after a load finds the person already changed: keep what they wore before
            act.data.prevOutfit = act.data.prevOutfit or actor.outfit or "everyday"
            actor.outfit = ia.outfit
        end
    end
    if ia.usesState and act.oid then
        local tv = world.lot.objects[act.oid]
        if tv then
            tv.state = tv.state or {}
            tv.state[ia.usesState] = true
            tv.watchers = tv.watchers or {}
            tv.watchers[actor.id] = true
            act.target.viewer = act.oid
        end
    end
    if o and act.target.on then
        o.state = o.state or {}
        o.state.occupied = true
    end
    if ia.privacy and o then
        local room = W.ObjRoom(world, o)
        if room > 0 then
            act.privacyKey = privacyKey(o.level or 0, room)
            A.privacy[act.privacyKey] = actor.id
            privacyTouched()
        end
    end
    -- a baby in arms is never swapped for a prop; the family module puts the baby down on
    -- actionStarted when the action can't be done holding one, and the prop is applied then
    if ia.carry and actor.carry ~= "baby" then actor.carry = ia.carry end
    local fun = (ia.rate and ia.rate.fun) or (ia.gain and ia.gain.fun)
    if fun and fun > 0 then act.repFactor = SS.Needs.RepFactor(world, actor, ia.repKey or act.iid) end
    if not act.performed then
        act.performed = true
        -- a restart (after a load, when the action could not continue in place) already wore the
        -- object once; onStart handlers see act.restarted and skip one-time effects
        if SS.Maintenance and SS.Maintenance.OnUse and o and not ia.noWear and not act.restarted then SS.Maintenance.OnUse(world, actor, o, ia, act) end
        if ia.onStart then
            local ok, why = ia.onStart(world, actor, act, act.oid and world.lot.objects[act.oid])
            if ok == false then finish(world, actor, "failed", why); return false end
            if actor.act ~= act then return false end
        end
        mirror(actor, act)
        SS.Emit("actionStarted", actor, act)
        if ia.carry and actor.carry == nil and actor.act == act then actor.carry = ia.carry end
    else
        if ia.onResume then ia.onResume(world, actor, act, act.oid and world.lot.objects[act.oid]) end
        if actor.act ~= act then return false end
    end
    act.committed = true
    if o then openLook(world, o, true) end
    return true
end

-- Idle helpers: step aside when asked, and bounded recovery from a blocked cell.
local function idleUpkeep(world, actor)
    local tmp = actor.tmp
    local ci, cj = cellOf(actor)
    local lv = actor.level or 0
    -- people on the street (off the lot, or walked along by the street/visitor code) are not ours
    -- to recover: only someone standing inside a solid cell of the lot is moved
    local street = not W.InLot(world.lot, ci, cj) or (tmp and (tmp.offLot or tmp.wp or tmp.inVehicle))
    if not actor.onObj and not street and W.Blocked(world, lv, ci, cj) then
        local ni, nj = SS.Nav.NearestFree(world, lv, ci, cj, 6, nil, true)
        if ni then
            actor.x, actor.y = ni + 0.5, nj + 0.5
            SS.Log("Recovered %s from a blocked cell to %d,%d", tostring(actor.id), ni, nj)
        end
        return
    end
    if tmp and tmp.shoo then
        local s = tmp.shoo
        tmp.shoo = nil
        if world.time - s.t > 1 then return end
        local by = world.actors[s.by]
        local bi, bj = by and math.floor(by.x) or -99, by and math.floor(by.y) or -99
        local bact = by and by.act
        local bpath, bpi = bact and bact.path, bact and bact.pi or 1
        local ni, nj = SS.Nav.NearestFree(world, lv, ci, cj, T.shooDistance, function(i, j)
            if i == ci and j == cj then return false end
            if i == s.i and j == s.j then return false end
            if i == bi and j == bj then return false end
            -- never further along the passer's way (in a one-tile corridor that only pushes the
            -- person ahead of them, step after step): off it or not at all (they are passed)
            if bpath then
                for n = bpi, #bpath do
                    local c = bpath[n]
                    if c[1] == i and c[2] == j and (c[3] or 0) == lv then return false end
                end
            end
            if A.cellOwner[cellKey(world, lv, i, j)] then return false end
            -- never into a room someone is using privately (a bathroom in use)
            local holder = next(A.privacy) and A.PrivacyHolder(world, lv, W.RoomAt(world, lv, i, j))
            if holder and holder ~= actor.id then return false end
            return SS.Nav.RegionAt(world, lv, i, j) == SS.Nav.RegionAt(world, lv, ci, cj)
        end)
        if ni then
            actor.queue = actor.queue or {}
            -- stepping aside is a courtesy: if it can't be done it just doesn't happen (no message)
            table.insert(actor.queue, 1, { iid = "goto", x = ni, y = nj, level = lv, manual = false, chain = true, shoo = true, quiet = true })
            syncOrders(actor)
        end
    end
end

function A.Update(world, actor, dt)
    if actor.orders ~= actor.queue then syncOrders(actor) end
    local act = actor.act
    if not act then
        local order = actor.queue and actor.queue[1]
        if order then
            table.remove(actor.queue, 1)
            if order.optional and not freeWill(world) and A.IsMember(world, actor) then return end
            -- a new plan puts down what's in hand, unless the order is for that very item
            -- (eating the plate you carry, putting the bag in the outdoor bin)
            if actor.held and not order.chain then
                local oia = I[order.iid]
                local uses = oia and oia.usesHeld
                if not (uses and uses[actor.held.kind]) then settleHeld(world, actor, "new order") end
            end
            if not begin(world, actor, order) then return end
            act = actor.act
            if not act then return end
        else
            if actor.held and SS.Chains and SS.Chains.IdleHeld then SS.Chains.IdleHeld(world, actor) end
            idleUpkeep(world, actor)
            return
        end
    elseif act.save ~= actor.doing then
        mirror(actor, act)
    end
    local ia = I[act.iid]
    actor.walking = nil
    local phase = act.phase

    if phase == "select" then
        -- re-entry after a load or an alternative switch: resolve and reserve again
        local obj = act.oid and world.lot.objects[act.oid]
        if not obj then finish(world, actor, "failed", "That object is gone."); return end
        local ok, why, code = A.Available(world, actor, obj, act.iid, act.data)
        if not ok then
            if code == "busy" or code == "privacy" then enterWait(world, actor, act, obj, why, code); return end
            finish(world, actor, "failed", why); return
        end
        local tgt, rwhy = A.ResolveSlot(world, actor, obj, act.iid)
        if not tgt then finish(world, actor, "failed", rwhy); return end
        reserve(world, actor, act, tgt)
        return
    end

    if phase == "wait" then
        local wt = act.wait
        local obj = act.oid and world.lot.objects[act.oid]
        if not obj then finish(world, actor, "failed", "That object is gone."); return end
        if act.waitGoal and not act.path then
            local r = plan(world, actor, act, act.waitGoal)
            if r == "fail" then act.waitGoal = nil end
        end
        if act.path then
            local r = followPath(world, actor, act, dt)
            if r ~= "moving" then act.path, act.pi, act.waitGoal = nil, nil, nil end
        else
            actor.pose = "idle"
        end
        -- bathroom annoyance
        if not wt.annoyed and world.time - wt.t0 >= T.annoyAfter and A.IsMember(world, actor) then
            local ia2 = I[act.iid]
            if wt.code == "privacy" or (ia2 and ia2.privacy) then
                wt.annoyed = true
                SS.Needs.Feel(world, actor, "annoyed")
                local hid = A.PrivacyHolder(world, obj.level or 0, W.ObjRoom(world, obj))
                if not hid or hid == actor.id then
                    for _, v in pairs(obj.res or {}) do if v ~= actor.id then hid = v; break end end
                end
                local holder = hid and hid ~= actor.id and world.actors[hid]
                A.Say(world, actor, "bathroom_queue", { objDef = obj.def, holder = holder and A.FirstName(holder) or nil,
                    listener = holder or nil, waitMin = math.floor(world.time - wt.t0) }, "bladder")
                SS.Emit("bathroomQueue", world, actor, obj)
            end
        end
        if world.time >= wt.nextCheck then
            wt.nextCheck = world.time + T.waitCheck
            local ok, why, code
            if wt.pv and wt.pv == A.privacyVersion then
                -- the route was shut by a bathroom in use and nobody's privacy has changed since:
                -- no reservation, no route (the target itself may look free)
                ok, why, code = false, wt.why, "privacy"
            else
                wt.pv = nil
                ok, why, code = A.Available(world, actor, obj, act.iid, act.data)
            end
            if ok then
                local tgt = A.ResolveSlot(world, actor, obj, act.iid)
                if tgt then
                    act.wait, act.waitGoal = nil, nil
                    reserve(world, actor, act, tgt)
                    return
                end
            end
            if code ~= "busy" and code ~= "privacy" then finish(world, actor, "failed", why); return end
            wt.why = why
            if world.time >= wt.untilT then
                local alt = A.Alternative(world, actor, act)
                local tgt = alt and A.ResolveSlot(world, actor, alt, act.iid)
                if tgt then
                    act.oid = alt.id
                    act.wait, act.waitGoal = nil, nil
                    reserve(world, actor, act, tgt)
                    SS.Emit("actionAlternative", world, actor, act, alt)
                    return
                end
                if A.IsMember(world, actor) then SS.Needs.Feel(world, actor, "frustrated") end
                finish(world, actor, "failed", "Gave up waiting: " .. (why or "it stayed busy."))
                return
            end
        end
        return
    end

    if phase == "route" then
        if not act.path then
            local r, why, rule = plan(world, actor, act, act.goalCells, act.avoidNext)
            act.avoidNext = nil
            if r == "defer" then actor.pose = "idle"; return end
            if r == "fail" and act.avoidUsed and why == "blocked" and not act.avoidRetried then
                -- only people standing still are in the way: plan through them instead (they are
                -- asked to step aside, and yielding ends in passing), once per action
                act.avoidRetried = true
                act.avoidUsed = nil
                return
            end
            if r == "fail" then routeFailed(world, actor, act, why, rule); return end
        end
        local r = followPath(world, actor, act, dt)
        if r == "replan" or r == "avoid" then
            act.path = nil
            act.routeTries = (act.routeTries or 0) + 1
            if r == "avoid" then act.avoidNext = true end
            if act.routeTries > T.routeRetries + (r == "avoid" and 2 or 0) then
                act.routeFailed = true
                finish(world, actor, "failed", "Something keeps blocking the way.")
            end
            return
        end
        if r == "moving" then return end
        -- arrived
        if act.iid == "goto" then finish(world, actor, "done"); return end
        if ia and ia.targetActor then
            local target = world.actors[act.tid]
            if not target then finish(world, actor, "failed", "They left."); return end
            actor.facing = G.dirToFacing(target.x - actor.x, target.y - actor.y)
            act.phase = "perform"
            mirror(actor, act)
            return
        end
        if act.cellTarget then
            act.approach = { math.floor(actor.x), math.floor(actor.y), actor.level or 0 }
            act.phase = "perform"
            mirror(actor, act)
            return
        end
        local o = act.target and world.lot.objects[act.target.oid]
        if not o then finish(world, actor, "failed", "That object is gone."); return end
        -- the target may have changed on the way (broken, switched on, repaired by someone else)
        if not act.performed then
            local ok, why, code = stillValid(world, actor, act, ia)
            if not ok then targetLost(world, actor, act, why, code); return end
        end
        act.approach = { math.floor(actor.x), math.floor(actor.y), actor.level or 0 }
        if act.target.on then act.phase = "enter" else
            act.phase = "perform"
            faceTarget(world, actor, act)
        end
        mirror(actor, act)
        return
    end

    if phase == "enter" then
        actor.walking = true
        actor.pose = "walk"
        local on = act.target.on
        local _, arrived = stepToward(actor, on[1] + 0.5, on[2] + 0.5, T.walkSpeed * dt)
        if arrived then
            act.phase = "perform"
            actor.facing = act.target.face
            actor.onObj = act.target.oid
            mirror(actor, act)
        end
        return
    end

    if phase == "perform" then
        if not act.committed then
            if not commit(world, actor, act, ia) then return end
        end
        if ia.onTick then
            ia.onTick(world, actor, act, act.oid and world.lot.objects[act.oid], dt)
            if actor.act ~= act then return end
        end
        A.SetPose(actor, act.pose or ((ia.slot == "viewer" and act.target and act.target.on) and "sit" or ia.pose))
        actor.sleeping = ia.sleeping or nil
        applyEffects(world, actor, act, ia, dt)
        act.t = act.t + dt
        if act.save then act.save.t = act.t end
        local stop, why, status = shouldStop(world, actor, act, ia)
        if stop then
            if why and ia.sleeping and T.needLabel[why] then
                if act.data and not act.data.wokeBy then act.data.wokeBy = why end
                A.Message(world, actor, "Woke up: " .. T.needLabel[why] .. " can't wait.", why)
            end
            -- the reason travels with failures and with explicit interrupts (A.Interrupt / A.Wake:
            -- "Woken by the baby crying."); a need-driven stop reports only its status
            local reason = (status == "failed" or (act.interruptWhy ~= nil and why == act.interruptWhy)) and why or nil
            if act.target and act.target.on and actor.onObj then
                act.phase = "exit"
                act.endStatus, act.endWhy = status, reason
                actor.onObj = nil
                mirror(actor, act)
            else
                finish(world, actor, status, reason)
            end
        end
        return
    end

    if phase == "exit" then
        actor.walking = true
        actor.pose = "walk"
        actor.sleeping = nil
        actor.onObj = nil
        local ap = act.approach or { math.floor(actor.x), math.floor(actor.y) }
        local _, arrived = stepToward(actor, ap[1] + 0.5, ap[2] + 0.5, T.walkSpeed * dt)
        if arrived then finish(world, actor, act.endStatus or (act.stopRequested and "cancelled") or "done", act.endWhy) end
    end
end

-- Player order. Manual orders pre-empt free-will actions (current and queued).
function A.Order(world, actor, oid, iid, x, y, extra)
    actor.queue = actor.queue or {}
    if iid ~= "goto" and not I[iid] then A.Message(world, actor, "Unknown action.", "noroute"); return false end
    for n = #actor.queue, 1, -1 do
        if not actor.queue[n].manual then table.remove(actor.queue, n) end
    end
    if #actor.queue >= T.maxQueue then A.Message(world, actor, "The queue is full.", "noroute"); syncOrders(actor); return false end
    local order = { oid = oid, iid = iid, manual = true, x = x, y = y }
    if extra then for k, v in pairs(extra) do order[k] = v end end
    table.insert(actor.queue, order)
    syncOrders(actor)
    if actor.act and not actor.act.manual then A.Interrupt(world, actor, "The player gave an order.", "interrupted") end
    return true
end

-- Queue a follow-up at the front (chains, services, other modules).
function A.QueueFront(world, actor, order)
    actor.queue = actor.queue or {}
    table.insert(actor.queue, 1, order)
    syncOrders(actor)
end

-- index 0 (or none) cancels the current action (gracefully if the actor is on an object); n > 0
-- removes the n-th queued order.
function A.Cancel(world, actor, index)
    if index == nil or index == 0 then
        local act = actor.act
        if not act then return end
        if act.phase == "perform" and act.target and act.target.on and actor.onObj then
            act.stopRequested = true
        elseif act.phase == "enter" then
            act.phase = "exit"
            act.endStatus = "cancelled"
        elseif act.phase ~= "exit" then
            finish(world, actor, "cancelled")
        end
    elseif actor.queue and actor.queue[index] then
        table.remove(actor.queue, index)
        syncOrders(actor)
    end
end

function A.Busy(actor) return actor.act ~= nil or (actor.queue ~= nil and #actor.queue > 0) end

-- Resume after a load (called by Sim.Attach): the saved `doing` record becomes the current
-- action again. Performing actions on a free slot continue in place (no second charge, no
-- second onStart); everything else re-enters the lifecycle at select/route.
function A.Resume(world, actor)
    local d = actor.doing
    actor.doing = nil
    actor.queue = type(actor.orders) == "table" and actor.orders or {}
    actor.orders = actor.queue
    for n = #actor.queue, 1, -1 do
        local o = actor.queue[n]
        if type(o) ~= "table" or (o.iid ~= "goto" and not I[o.iid]) or (o.oid and not world.lot.objects[o.oid]) then table.remove(actor.queue, n) end
    end
    if type(d) ~= "table" or not d.iid or (d.iid ~= "goto" and not I[d.iid]) then return false end
    local order = { iid = d.iid, oid = d.oid, tid = d.tid, x = d.x, y = d.y, level = d.level, manual = d.manual,
        data = type(d.data) == "table" and d.data or {}, chain = d.chain, optional = d.optional,
        charged = d.charged, performed = d.performed, t = d.performed and d.t or 0, dur = d.dur, maxDur = d.maxDur }
    local ia = I[d.iid]
    local obj = d.oid and world.lot.objects[d.oid]
    if d.performed and (d.phase == "perform" or d.phase == "exit") and ia and obj and d.key then
        -- continue in place when the same slot is free
        local tgt = A.ResolveSlot(world, actor, obj, d.iid)
        if tgt and (tgt.key == d.key or ia.slot == "viewer" or ia.slot == "spot" or ia.slot == "around") then
            local act = { iid = d.iid, oid = d.oid, manual = d.manual, actorId = actor.id, phase = "perform", t = d.t or 0,
                data = order.data, chain = d.chain, optional = d.optional, charged = d.charged, performed = true,
                label = ia.label, resumed = true, dur = d.dur, maxDur = d.maxDur }
            actor.act = act
            act.target = { oid = tgt.obj.id, slotName = tgt.slotName, key = tgt.key, on = tgt.on, face = tgt.face, viewer = tgt.viaViewer, faceObj = tgt.faceObj }
            tgt.obj.res = tgt.obj.res or {}
            tgt.obj.res[tgt.key] = actor.id
            act.approach = tgt.approaches[1] and { tgt.approaches[1][1], tgt.approaches[1][2], tgt.approaches[1][3] } or { math.floor(actor.x), math.floor(actor.y), actor.level or 0 }
            if tgt.on then
                actor.x, actor.y, actor.level = tgt.on[1] + 0.5, tgt.on[2] + 0.5, tgt.on[3]
                actor.onObj = tgt.obj.id
                actor.facing = tgt.face
            else
                local ap = act.approach
                if not W.Blocked(world, ap[3] or 0, ap[1], ap[2]) then actor.x, actor.y, actor.level = ap[1] + 0.5, ap[2] + 0.5, ap[3] or 0 end
                faceTarget(world, actor, act)
            end
            if d.phase == "exit" then act.complete = true end
            actor.sleeping = ia.sleeping or nil
            mirror(actor, act)
            return true
        end
    end
    if d.performed and ia and (ia.slot == "here" or ia.slot == "cell") then
        local act = { iid = d.iid, manual = d.manual, actorId = actor.id, phase = "perform", t = d.t or 0, data = order.data,
            chain = d.chain, charged = d.charged, performed = true, label = ia.label, resumed = true, dur = d.dur, maxDur = d.maxDur,
            approach = { math.floor(actor.x), math.floor(actor.y), actor.level or 0 } }
        actor.act = act
        mirror(actor, act)
        return true
    end
    -- restart from select (keeping the charged flag: no second charge; `restarted`: no second
    -- wear, outfit capture or one-time onStart effects)
    order.restarted = (d.performed or d.restarted) and true or nil
    order.performed = nil
    order.t = 0
    table.insert(actor.queue, 1, order)
    return false
end

-- Utility scoring ------------------------------------------------------------------------
-- Candidate providers add non-object choices: fn(world, actor, cands) appending
-- { tid = actorId | oid = objectId, iid = interactionId, s = score, data = {...}?, why = "..."? }.
-- Only add candidates whose score > Tuning.minScore and that A.Available accepts.
A.candidateProviders = {}
function A.RegisterCandidates(fn) A.candidateProviders[#A.candidateProviders + 1] = fn end

local function urgency(v) local x = (100 - v) / 100; return x * x end
A.Urgency = urgency

-- Personality fit from the interaction's trait weights: traits = { neat = 1, playful = 0.5, ... }.
-- The social module may take this over by setting SS.Personality.handlesTraits = true.
function A.TraitFit(actor, ia)
    if not ia.traits or (SS.Personality and SS.Personality.handlesTraits) then return 1 end
    local p = actor.personality
    if not p then return 1 end
    local f = 1
    for trait, w in pairs(ia.traits) do
        f = f + w * ((p[trait] or 5) - 5) * T.traitWeight
    end
    return U.clamp(f, 0.25, 2.5)
end

function A.InterestFit(actor, topic)
    if not topic or not actor.interests then return 1 end
    local v = actor.interests[topic]
    if not v then return 1 end
    return U.clamp(1 + (v - 5) * T.interestWeight, 0.6, 1.4)
end

-- Relief multiplier for a need from the object's quality (rates relative to the interaction's
-- base rates, or 0..10 ratings for one-off gains).
function A.QualityMult(def, ia, need)
    if not def then return 1 end
    if ia.rate and ia.rate[need] and def.rates and def.rates[need] and ia.rate[need] > 0 then
        return U.clamp(def.rates[need] / ia.rate[need], 0.3, 2.5)
    end
    if def.ratings and def.ratings[need] then return 0.75 + 0.05 * def.ratings[need] end
    return 1
end

-- Dynamic advertisers fill a scratch table per call site instead of building a new one on every
-- decision: A.Advert(key, need1, amount1, need2, amount2, need3, amount3) empties and refills the
-- table kept for `key` and returns it. Whoever calls an advertiser reads the result at once
-- (A.Score, A.Explain, a scorer in another module) and copies it if it keeps it (the executor's
-- act.advCache does).
local ADVERTS = {}
function A.Advert(key, n1, v1, n2, v2, n3, v3)
    local t = ADVERTS[key]
    if not t then t = {}; ADVERTS[key] = t end
    for k in pairs(t) do t[k] = nil end
    if n1 then t[n1] = v1 end
    if n2 then t[n2] = v2 end
    if n3 then t[n3] = v3 end
    return t
end

local function hashJitter(a, b)
    local h = 7
    for n = 1, #a do h = (h * 31 + a:byte(n)) % 100003 end
    for n = 1, #b do h = (h * 37 + b:byte(n)) % 100003 end
    return (h % 1000) / 1000 - 0.5
end

-- Score an interaction on an object for an actor. detail (optional table) receives the factors.
function A.Score(world, actor, obj, iid, detail)
    local ia = I[iid]
    if not ia or ia.manualOnly or not (ia.advert or ia.advertise) then return 0 end
    -- cheap state filters first, so unusable offers never crowd the candidate list
    if obj and not ia.targetActor then
        local fdef = SS.Objects[obj.def]
        if fdef and (fdef.kidOnly or fdef.adultOnly or fdef.pet) and not A.DesignFor(actor, ia, fdef) then return 0 end
        local st = obj.state
        if st and st.broken and not ia.whenBroken then
            local bdef = SS.Objects[obj.def]
            if bdef and A.BrokenPolicy(bdef) == "unavailable" then return 0 end
        end
        if ia.requireState then
            for k, v in pairs(ia.requireState) do
                if ((st and st[k]) or false) ~= v then return 0 end
            end
        end
    end
    -- a dynamic advertiser that returns nil means "not on offer here" (never the static advert)
    local advert
    if ia.advertise then advert = ia.advertise(world, actor, obj) else advert = ia.advert end
    if not advert then return 0 end
    local def = obj and SS.Objects[obj.def]
    -- the advert is read here, once (a dynamic advertiser's table is refilled on its next call)
    local s, uMax, offersFun, offersFood = 0, 0, false, false
    for need, amt in pairs(advert) do
        local v = actor.needs[need] or 0
        local q = A.QualityMult(def, ia, need)
        local useful = math.min(amt * q, 100 - v)
        if useful > 0 then s = s + useful * urgency(v) end
        if amt > 0 then
            uMax = math.max(uMax, urgency(v))
            if need == "fun" then offersFun = true elseif need == "hunger" then offersFood = true end
        end
    end
    if s <= 0 then return 0 end
    local base = s
    local pm = A.TraitFit(actor, ia)
    local im = A.InterestFit(actor, ia.topic)
    local rm = 1
    if offersFun and ia.leisure then rm = SS.Needs.RepFactor(world, actor, ia.repKey or iid) end
    local d = 0
    if obj then
        d = math.abs(obj.x + 0.5 - actor.x) + math.abs(obj.y + 0.5 - actor.y) + math.abs((obj.level or 0) - (actor.level or 0)) * T.levelCost
    end
    local tm = 1 / (1 + d * T.travelCost)
    local mm = 1
    local cost = A.CostOf(world, actor, obj, iid)
    if cost > 0 and A.IsMember(world, actor) then mm = 1 - math.min(0.5, cost / math.max(1, world.money or 0) * T.moneyPenalty) end
    local sm = 1
    if obj and obj.state and obj.state.broken then sm = T.degraded end
    if ia.risk then sm = sm * math.max(0.1, 1 - ia.risk * T.safetyPenalty * 5) end
    local cm = 1
    if ia.group and obj and obj.res then
        local others = 0
        for _, v in pairs(obj.res) do if v ~= actor.id then others = others + 1 end end
        if others > 0 then
            local out = actor.personality and actor.personality.outgoing or 5
            cm = 1 + T.socialContext * (0.5 + out / 10)
        end
    end
    -- duration: fixed-length activities that take long are less attractive the more urgent the
    -- need (a quick snack beats an hour of cooking when starving); open-ended ones are not penalised.
    local dm = 1
    local est = ia.estimate and ia.estimate(world, actor, obj) or ia.dur
    if est and est > T.durationFree then
        dm = math.max(T.durationFloor, 1 / (1 + (est - T.durationFree) * T.durationCost * uMax))
    end
    local pb = 1
    local plan = actor.tmp and actor.tmp.plan
    if plan and (plan.untilT or 0) > world.time then
        if ia.plan and plan.kind == ia.plan then
            pb = T.planBonus
        elseif plan.kind == "breakfast" and offersFood and (actor.needs.hunger or 0) < T.breakfast.below then
            -- up for work or school: food that is done before the ride comes first
            pb = ((est or 0) <= plan.untilT - world.time) and T.breakfast.bonus or T.breakfast.late
        end
    end
    local jm = 1 + T.jitter * hashJitter(actor.id or "", (obj and obj.id or "") .. iid)
    s = s * pm * im * rm * tm * mm * sm * cm * pb * jm * dm
    if SS.Personality and SS.Personality.Modify then s = SS.Personality.Modify(world, actor, obj, iid, s) or s end
    if detail then
        detail.relief, detail.trait, detail.interest, detail.repeat_, detail.travel, detail.money = base, pm, im, rm, tm, mm
        detail.safety, detail.social, detail.plan, detail.jitter, detail.dist = sm, cm, pb, jm, d
        detail.duration, detail.minutes = dm, est
    end
    return s
end

-- Human-readable reasons for the inspector.
function A.Explain(world, actor, obj, iid)
    local d = {}
    local s = A.Score(world, actor, obj, iid, d)
    local ia = I[iid]
    local advert = {}
    if ia then
        if ia.advertise then advert = ia.advertise(world, actor, obj) or {} else advert = ia.advert or {} end
    end
    local needs = {}
    for need, amt in pairs(advert) do
        if amt > 0 then needs[#needs + 1] = string.format("%s+%d (now %d)", T.needLabel[need] or need, amt, actor.needs[need] or 0) end
    end
    table.sort(needs)
    local parts = { table.concat(needs, ", ") }
    local function f(name, v) if v and math.abs(v - 1) > 0.02 then parts[#parts + 1] = string.format("%s x%.2f", name, v) end end
    f("personality", d.trait); f("interest", d.interest); f("repetition", d.repeat_); f("money", d.money)
    f("safety", d.safety); f("company", d.social); f("plan", d.plan); f("duration", d.duration)
    parts[#parts + 1] = string.format("%.0f tiles", d.dist or 0)
    return table.concat(parts, "; "), s
end

local function candidateObj(world, c) return c.oid and world.lot.objects[c.oid] end

-- Is waiting for a busy target reasonable (urgent need it addresses)?
local function worthWaiting(actor, ia)
    for need, amt in pairs(ia.advert or {}) do
        if amt > 0 and (actor.needs[need] or 0) < T.urgent then return true end
    end
    return false
end

-- Expected minutes until a busy object frees up: the shortest remaining time among the people
-- holding it (fixed-length uses count down; open-ended ones assume their maximum length).
local function busyRemaining(world, obj)
    local best
    for _, holder in pairs(obj.res or {}) do
        local b = world.actors[holder]
        local act = b and b.act
        if act then
            local ia = I[act.iid]
            local total = act.dur or (ia and (ia.dur or ia.maxDur)) or 30
            local left = total - ((act.phase == "perform" and act.t) or 0)
            if not best or left < best then best = left end
        end
    end
    return best or 0
end
A.BusyRemaining = busyRemaining

-- Autonomy scratch. Candidate tables for object offers are recycled per actor: the previous
-- decision's rows go back to the actor's pool when the next decision is made (the inspector reads
-- actor.lastThink fresh each time it draws). Cooldown keys ("oid:iid") are built once per pair.
-- A row's `why` (the inspector's explanation) is worked out when something reads it, from the
-- scores as they are at that moment (in the attached world), instead of on every decision.
local COOL_KEYS, coolKeyCount = {}, 0
local function coolKey(oid, iid)
    local byO = COOL_KEYS[iid]
    if not byO then byO = {}; COOL_KEYS[iid] = byO end
    local key = byO[oid]
    if not key then
        if coolKeyCount >= 4096 then COOL_KEYS, coolKeyCount = {}, 0; byO = {}; COOL_KEYS[iid] = byO end
        key = oid .. ":" .. iid
        byO[oid] = key
        coolKeyCount = coolKeyCount + 1
    end
    return key
end
A.CoolKey = coolKey

local WHY_MT = {
    __index = function(c, k)
        if k ~= "why" then return nil end
        -- rows keep only the actor's id: actor.lastThink is runtime data, but the save snapshot
        -- copies before it strips runtime fields, so nothing in it may point back at the world
        local w = SS.Sim and SS.Sim.world
        local a = w and w.actors and w.actors[rawget(c, "_aid")]
        local obj = a and c.oid and w.lot and w.lot.objects[c.oid]
        if not (obj and a and a.needs and I[c.iid]) then return nil end
        local why = A.Explain(w, a, obj, c.iid)
        rawset(c, "why", why)
        return why
    end,
}

local function candLess(a, b)
    if a.s ~= b.s then return a.s > b.s end
    local ka, kb = a.oid or a.tid or "", b.oid or b.tid or ""
    if ka ~= kb then return ka < kb end
    return a.iid < b.iid
end

-- Recycle the rows of the actor's previous decision (only rows this function made).
local function recycle(tmp, lt, from)
    local pool = tmp.candPool
    if not pool then pool = {}; tmp.candPool = pool end
    for n = #lt, from, -1 do
        local c = lt[n]
        lt[n] = nil
        if type(c) == "table" and rawget(c, "_pooled") then
            setmetatable(c, nil)
            for k in pairs(c) do c[k] = nil end
            if #pool < 64 then pool[#pool + 1] = c end
        end
    end
    return pool
end

local PICK = {}

-- A.thinking: a number while one decision is being made (nil otherwise). Helpers that are asked
-- the same question by several candidates of one decision (Chains' recipe choice) may keep their
-- answer for as long as it stays the same number; nothing changes the world in between.
A.thinking = nil
local thinkGen = 0
local think
function A.Think(world, actor)
    thinkGen = thinkGen + 1
    A.thinking = thinkGen
    think(world, actor)
    A.thinking = nil
end
function think(world, actor)
    if actor.act or (actor.queue and #actor.queue > 0) then return end
    local member = A.IsMember(world, actor)
    if member and not freeWill(world) then return end
    if (actor.nextThink or 0) > world.time then return end
    if A.inStep then
        if A.thinkBudget <= 0 then return end
        A.thinkBudget = A.thinkBudget - 1
    end
    actor.nextThink = world.time + T.thinkInterval
    local objects = world.lot.objects
    local cool = actor.cool
    local tmp = actor.tmp
    if not tmp then tmp = {}; actor.tmp = tmp end
    local cands = actor.lastThink
    local pool
    if type(cands) == "table" and rawget(cands, "_mine") then
        pool = recycle(tmp, cands, 1)
        cands.t, cands.chosen, cands.routeFails = nil, nil, nil
    else
        cands = { _mine = true }
        pool = tmp.candPool or {}
        tmp.candPool = pool
    end
    local coolWhy = tmp.coolWhy
    if cool then
        for k, t in pairs(cool) do
            if t <= world.time then cool[k] = nil; if coolWhy then coolWhy[k] = nil end end
        end
    end
    if cool and next(cool) == nil then cool = nil end
    local skipped
    for _, oid in ipairs(W.ObjectIds(world)) do
        local obj = objects[oid]
        local def = obj and SS.Objects[obj.def]
        local acts = def and def.actions
        if acts then
            for k = 1, #acts do
                local iid = acts[k]
                local ia = I[iid]
                if ia and not ia.manualOnly and (ia.advert or ia.advertise) then
                    local key = cool and coolKey(oid, iid)
                    local c = key and cool[key]
                    if not c or c <= world.time then
                        local s = A.Score(world, actor, obj, iid)
                        if s > T.minScore then
                            local np = #pool
                            local row = pool[np]
                            if row then pool[np] = nil else row = {} end
                            row.oid, row.iid, row.s, row._pooled = oid, iid, s, true
                            cands[#cands + 1] = row
                        end
                    elseif coolWhy and coolWhy[key] and (not skipped or #skipped < 4) then
                        -- resting after a failure: keep it visible in the inspector with its reason
                        skipped = skipped or {}
                        skipped[#skipped + 1] = { oid = oid, iid = iid, s = 0, ok = false, skipped = true,
                            reason = coolWhy[key] .. " (not retried for now)" }
                    end
                end
            end
        end
    end
    -- other candidate sources (social with people present, pets, off-object activities); a choice
    -- that is resting after a failure ("<oid or tid>:<iid>", as for object offers) is left out,
    -- so a failing provider offer is not retried on every decision
    local nObj = #cands
    for n = 1, #A.candidateProviders do A.candidateProviders[n](world, actor, cands) end
    if cool and #cands > nObj then
        local nc, keep = #cands, nObj
        for n = nObj + 1, nc do
            local c = cands[n]
            local key = c.iid and coolKey(c.oid or c.tid or "", c.iid)
            local t = key and cool[key]
            if t and t > world.time then
                if coolWhy and coolWhy[key] and (not skipped or #skipped < 4) then
                    skipped = skipped or {}
                    skipped[#skipped + 1] = { oid = c.oid, tid = c.tid, iid = c.iid, s = 0, ok = false, skipped = true,
                        reason = coolWhy[key] .. " (not retried for now)" }
                end
            else
                keep = keep + 1
                cands[keep] = c
            end
        end
        for n = keep + 1, nc do cands[n] = nil end
    end
    table.sort(cands, candLess)
    -- availability for the best few (the expensive part), with reasons for the inspector
    local checked, best = 0, nil
    for n = 1, #cands do
        local c = cands[n]
        if checked >= T.availChecks then break end
        local obj = candidateObj(world, c)
        if obj then
            checked = checked + 1
            local ok, why, code = A.Available(world, actor, obj, c.iid, c.data)
            if ok then c.ok = true
            elseif code == "busy" or code == "privacy" then
                -- only worth queueing when urgent and the object frees up soon (a toilet, not a
                -- chair someone has just settled into)
                if worthWaiting(actor, I[c.iid]) and (code == "privacy" or busyRemaining(world, obj) <= T.waitAuto) then
                    c.ok, c.wait = true, true; c.s = c.s * T.busyPenalty
                    c.reason = why
                else
                    c.reason = why .. " Not worth waiting for."
                end
            else
                c.ok, c.reason = false, why
                -- rejected offers rest for a while so the next decision looks further down the list
                cool = actor.cool or {}
                actor.cool = cool
                local key = coolKey(c.oid or c.tid or "", c.iid)
                local untilT = world.time + (code == "unreachable" and T.routeFailCooldown or T.rejectCooldown)
                coolWhy = coolWhy or {}
                tmp.coolWhy = coolWhy
                if (cool[key] or -1e9) < untilT then cool[key] = untilT; coolWhy[key] = why end
            end
        else
            c.ok = true
        end
        if c.ok and (not best or c.s > best.s) then best = c end
    end
    -- up in the night for a need or a noise: back to bed once nothing is pressing, that is once
    -- no available choice scores Tuning.backToBedOver or more (the crying baby that woke this
    -- person, an urgent need). Set by the sleep interaction's end; Chains.BackToBed queues it.
    local backToBed = tmp.backToBed and (not best or best.s < T.backToBedOver) and SS.Chains
        and SS.Chains.BackToBed and SS.Chains.BackToBed(world, actor)
    if backToBed then best = nil end
    -- choose: weighted among available candidates within pickWindow of the best
    local chosen = best
    if best then
        local np, total = 0, 0
        for n = 1, #cands do
            local c = cands[n]
            if c.ok and c.s >= best.s * (1 - T.pickWindow) then np = np + 1; PICK[np] = c; total = total + c.s end
        end
        if np > 1 then
            local r = SS.Random(world, "autonomy") * total
            for n = 1, np do
                r = r - PICK[n].s
                if r <= 0 then chosen = PICK[n]; break end
            end
        end
        for n = 1, np do PICK[n] = nil end
    end
    -- inspector data: top candidates with reasons, then offers resting after a failure
    if chosen and #cands > 12 then
        -- the chosen row stays listed even when it came from further down
        for n = 13, #cands do if cands[n] == chosen then cands[n], cands[12] = cands[12], chosen; break end end
    end
    recycle(tmp, cands, 13)
    if skipped then for n = 1, #skipped do cands[#cands + 1] = skipped[n] end end
    for n = 1, #cands do
        local c = cands[n]
        if n <= 8 and c.oid and not c.skipped and rawget(c, "why") == nil and getmetatable(c) == nil then
            c._aid = actor.id
            setmetatable(c, WHY_MT)
        end
        c.label = I[c.iid] and I[c.iid].label or c.iid
    end
    cands.t = world.time
    cands.chosen = chosen
    cands.backToBed = backToBed or nil
    cands.routeFails = tmp.routeFails
    actor.lastThink = cands -- for the autonomy inspector (runtime only)
    if chosen then
        actor.queue = actor.queue or {}
        table.insert(actor.queue, { oid = chosen.oid, tid = chosen.tid, iid = chosen.iid, manual = false, data = chosen.data })
        syncOrders(actor)
        local lc = tmp.lastChoice or {}
        lc.iid, lc.oid, lc.t, lc.s = chosen.iid, chosen.oid, world.time, chosen.s
        tmp.lastChoice = lc
    end
end

-- Mid-route reconsideration with commitment: an autonomous optional action is only abandoned
-- for a need that has become critical and that it does not address.
function A.Reconsider(world, actor)
    local act = actor.act
    if not act or act.manual or act.chain or act.phase == "perform" or act.phase == "exit" or actor.noNeeds then return end
    if (act.reconsiderAt or 0) > world.time then return end
    act.reconsiderAt = world.time + 5
    local ia = I[act.iid]
    if not ia then return end
    local low0 = act.low0
    for _, need in ipairs(T.needs) do
        if need ~= "room" and need ~= "social" and not (low0 and low0[need]) and SS.Needs.Status(actor, need) == "critical"
            and not addresses(ia, act, need, world, actor) then
            local mine = act.oid and world.lot.objects[act.oid] and A.Score(world, actor, world.lot.objects[act.oid], act.iid) or 0
            local urgentScore = 60 * urgency(actor.needs[need])
            if urgentScore > mine * T.commitMargin then
                A.Interrupt(world, actor, T.needLabel[need] .. " became critical.", "interrupted")
                actor.nextThink = world.time
                return
            end
        end
    end
end

-- Severe-need consequences (non-graphic): bladder accident, collapse from exhaustion.
-- Starvation is the events module's pathway (needWarning events come from Needs).
function A.Consequences(world, actor)
    local needs = actor.needs
    if needs.bladder <= -100 then
        needs.bladder = T.accident.bladder
        SS.Needs.Add(actor, "hygiene", T.accident.hygiene)
        local lv = actor.level or 0
        local ci, cj = cellOf(actor)
        if SS.Maintenance and SS.Maintenance.SpawnPuddle then SS.Maintenance.SpawnPuddle(world, lv, ci, cj, "accident") end
        local room = W.RoomAt(world, lv, ci, cj)
        local witnesses = 0
        for id, b in pairs(world.actors) do
            if b ~= actor and (b.level or 0) == lv and W.RoomAt(world, lv, math.floor(b.x), math.floor(b.y)) == room and (room ~= 0 or math.abs(b.x - actor.x) + math.abs(b.y - actor.y) < 6) then
                witnesses = witnesses + 1
                if b.needs and not b.noNeeds then SS.Needs.Feel(world, b, "disgusted") end
                if witnesses == 1 then A.Say(world, b, "puddle", { objDef = "puddle", listener = actor }, "disgusted") end
            end
        end
        SS.Needs.Feel(world, actor, "embarrassed", witnesses > 0 and 1.5 or 1)
        if actor.act then A.Interrupt(world, actor, "Had an accident.", "interrupted") end
        A.Message(world, actor, (actor.name or "Someone") .. " couldn't make it to the bathroom.", "bladder")
        journal(world, (actor.name or "Someone") .. " had an embarrassing accident" .. (witnesses > 0 and " in front of company." or "."), actor)
        SS.Emit("accident", world, actor, "bladder", witnesses)
    end
    if needs.energy <= -100 and not actor.sleeping then
        if actor.act then finish(world, actor, "interrupted", "Passed out.") end
        settleHeld(world, actor, "collapse")
        actor.queue = {}
        syncOrders(actor)
        local act = { iid = "collapse", manual = true, actorId = actor.id, phase = "perform", t = 0, label = "Passed Out", data = {},
            approach = { cellOf(actor) } }
        act.approach[3] = actor.level or 0
        actor.act = act
        mirror(actor, act)
        A.Message(world, actor, (actor.name or "Someone") .. " passed out from exhaustion.", "energy")
        journal(world, (actor.name or "Someone") .. " fell asleep on the floor.", actor)
        SS.Emit("collapse", world, actor)
    end
end

I.collapse = { label = "Passed Out", category = "Rest", pose = "collapse", sleeping = true, dur = 120, rate = { energy = 8, comfort = -6 }, advert = {}, manualOnly = true, slot = "here" }

-- Bathroom privacy as a passage rule: nobody steps into a room someone else is using privately.
-- Marked { privacy = true }: a way shut only by this rule is worth waiting for (Nav's room check).
W.RegisterPassHook(function(world, level, i, j, ni, nj, wall, who)
    if not who or next(A.privacy) == nil then return end
    local rTo = W.RoomAt(world, level, ni, nj)
    if rTo == 0 then return end
    local holder = A.privacy[privacyKey(level, rTo)]
    if holder and holder ~= who.id and W.RoomAt(world, level, i, j) ~= rTo then return false end
end, { privacy = true })
