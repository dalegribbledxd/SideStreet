-- SideStreet family: household growth (move in, commitment, babies, adoption), children,
-- child welfare (neglect strikes, inspections, removal), the dependent path when the last adult
-- is lost (A39), and the shared helpers the other family files use (Infants, Pets, Garden, Parties).
-- Owner: family module. Notes: docs/modules/family.md. Tuning: Data/Family.lua.
--
-- Saved data: root.family = { nextId, pending = {}, visits = {}, welfare = {}, cases = {}, cool = {} },
-- person.fam = { spouse, engaged, parents = {rid...}, removedFrom }, household.flags.guardianCase,
-- household.flags.ended, household.flags.service (the lot-less Family Services / shelter households).
local _, SS = ...
local U = SS.U
local G, W = SS.Grid, SS.World
local FD = SS.FamilyData
local F = {}
SS.Family = F

---------------------------------------------------------------------------
-- Small helpers (shared by every family file)
---------------------------------------------------------------------------
function F.Root(world) return world.root or world end

function F.State(world)
    local root = F.Root(world)
    local s = root.family
    if type(s) ~= "table" then s = {}; root.family = s end
    s.nextId = s.nextId or 1
    s.pending = s.pending or {}
    s.visits = s.visits or {}
    s.welfare = s.welfare or {}
    s.cases = s.cases or {}
    s.cool = s.cool or {}
    return s
end

function F.NewId(world, prefix)
    local s = F.State(world)
    local root = F.Root(world)
    local id
    repeat
        id = prefix .. s.nextId
        s.nextId = s.nextId + 1
    until not (root.residents[id] or root.households[id] or s.pending[id] or s.visits[id] or s.cases[id])
    return id
end

function F.KindOf(a) return a.kind or "human" end
function F.IsHuman(a) return a ~= nil and (a.kind == nil or a.kind == "human") end
function F.IsPet(a) return a ~= nil and (a.kind == "dog" or a.kind == "cat") end
function F.IsInfant(a) return F.IsHuman(a) and a.age == "infant" end
function F.IsChild(a) return F.IsHuman(a) and a.age == "child" end
function F.IsAdult(a) return F.IsHuman(a) and (a.age == nil or a.age == "adult") end
function F.IsDependent(a) return F.IsInfant(a) or F.IsChild(a) end
function F.Alive(a) return a ~= nil and not a.dead end
function F.IsNpc(a) return a ~= nil and (a.npc or (type(a.id) == "string" and a.id:sub(1, 4) == "npc_")) end

-- Household of the session (or by id). Members as sorted records.
function F.Household(world, hh)
    local root = F.Root(world)
    if type(hh) == "string" then return root.households[hh] end
    return hh or world.household
end

function F.Members(world, hh, pred)
    local root = F.Root(world)
    hh = F.Household(world, hh)
    local out = {}
    if not hh then return out end
    for _, rid in ipairs(hh.members or {}) do
        local r = root.residents[rid]
        if r and F.Alive(r) and (not pred or pred(r)) then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function F.IsMember(world, a)
    local hh = world.household
    return hh ~= nil and a ~= nil and a.householdId == hh.id
end

function F.IsServiceHousehold(hh)
    if type(hh) == "table" then return hh.flags ~= nil and hh.flags.service == true end
    return hh == FD.servicesHousehold.id or hh == FD.shelterHousehold.id
end

-- People counts: humans (alive members), pets, and people/pets on the way (pending arrivals).
function F.Counts(world, hh)
    local root = F.Root(world)
    hh = F.Household(world, hh)
    local c = { humans = 0, pets = 0, pendingHumans = 0, pendingPets = 0, adults = 0, dependents = 0 }
    if not hh then return c end
    for _, rid in ipairs(hh.members or {}) do
        local r = root.residents[rid]
        if r and F.Alive(r) then
            if F.IsPet(r) then c.pets = c.pets + 1 else
                c.humans = c.humans + 1
                if F.IsAdult(r) then c.adults = c.adults + 1 else c.dependents = c.dependents + 1 end
            end
        end
    end
    for _, p in pairs(root.family and root.family.pending or {}) do
        if p.hh == hh.id and (p.state == "scheduled" or p.state == "onlot") then
            if p.kind == "pet" then c.pendingPets = c.pendingPets + 1 else c.pendingHumans = c.pendingHumans + 1 end
        end
    end
    return c
end

-- Can `n` more people (or pets) join? Pending arrivals count so capacity is never exceeded later.
function F.HasRoom(world, hh, kind, n)
    local c = F.Counts(world, hh)
    n = n or 1
    if kind == "pet" then
        local max = (SS.PetData and SS.PetData.maxPerHousehold) or FD.petMax
        if c.pets + c.pendingPets + n > max then
            return false, "The household already has " .. (c.pets + c.pendingPets) .. " of its " .. max .. " pets (declared limit)."
        end
        return true
    end
    if c.humans + c.pendingHumans + n > FD.capacity then
        return false, "The household is full: " .. (c.humans + c.pendingHumans) .. " of " .. FD.capacity .. " people"
            .. (c.pendingHumans > 0 and " including those on the way." or ".")
    end
    return true
end

function F.Rel(world, a, b) return SS.Social.Rel(world, a, b) end
-- Read a relationship without creating a record (lists and panels scan many pairs; saves stay small).
local NO_REL = setmetatable({ daily = 0, life = 0, flags = setmetatable({}, { __newindex = function() end }) },
    { __newindex = function() end })
function F.PeekRel(world, a, b)
    local root = F.Root(world)
    local rel = root.social and root.social.rel
    local r = rel and rel[a .. ">" .. b]
    if r then return r end
    if SS.Social.Peek then return SS.Social.Peek(world, a, b) or NO_REL end
    return NO_REL
end
function F.Change(world, a, b, daily, life) return SS.Social.Change(world, a, b, daily, life) end

local CLOSE = { parent = true, child = true, sibling = true, guardian = true, ward = true }
function F.CloseFamily(world, a, b)
    local f1 = F.PeekRel(world, a, b).flags.family
    local f2 = F.PeekRel(world, b, a).flags.family
    return (f1 and CLOSE[f1]) or (f2 and CLOSE[f2]) or false
end

function F.Fam(p)
    p.fam = type(p.fam) == "table" and p.fam or {}
    return p.fam
end

function F.SpouseOf(world, rid)
    local r = F.Root(world).residents[rid]
    local s = r and r.fam and r.fam.spouse
    local sp = s and F.Root(world).residents[s]
    if sp and F.Alive(sp) then return s end
end

function F.Committed(world, a, b)
    local ra = F.Root(world).residents[a]
    return ra ~= nil and ra.fam ~= nil and ra.fam.spouse == b
end

function F.Money(world, delta, cat, text) SS.Money(world, delta, cat or "family", text) end

-- When something booked for later will happen, in words: "any minute now", "in about 20 minutes",
-- "in about an hour", "in about 3 hours".
function F.DelayText(minutes)
    minutes = tonumber(minutes) or 0
    if minutes < 1 then return "any minute now" end
    if minutes < 55 then return "in about " .. math.max(5, math.floor(minutes / 5 + 0.5) * 5) .. " minutes" end
    if minutes < 90 then return "in about an hour" end
    return "in about " .. math.floor(minutes / 60 + 0.5) .. " hours"
end

-- A stand-in world for a household that isn't the one being played, so SS.Money can settle its
-- money: money, ledger and journal read and write the household's own, the rest the save's. The
-- hood module's household view when it is there (SS.Hood.View, which also reads that household's
-- own clock), else the same thing here.
local function householdView(world, hh)
    local root = F.Root(world)
    if SS.Hood and SS.Hood.View then return SS.Hood.View(root, hh) end
    return setmetatable({ root = root, household = hh }, {
        __index = function(_, k)
            if k == "money" or k == "ledger" or k == "journal" then return hh[k] end
            if k == "time" then return root.time end
            return root[k]
        end,
        __newindex = function(t, k, v)
            if k == "money" or k == "ledger" or k == "journal" then hh[k] = v else rawset(t, k, v) end
        end,
    })
end
F.HouseholdView = householdView

-- Money for any household, always through SS.Money (one ledger entry, one "money" event, the
-- shared ledger cap): the session's household directly, another household through its view.
function F.HouseholdMoney(world, hh, delta, cat, text)
    hh = F.Household(world, hh)
    if not hh or delta == 0 then return end
    if world.household == hh and world.root then
        SS.Money(world, delta, cat or "family", text)
    else
        hh.money = hh.money or 0
        hh.ledger = hh.ledger or {}
        SS.Money(householdView(world, hh), delta, cat or "family", text)
    end
end

-- Charge an action's price once, at its commit point (act.charged records it across ticks).
function F.ChargeOnce(world, act, amount, text, cat)
    if act.charged or not amount or amount <= 0 then return true end
    if (world.money or 0) < amount then return false, "That costs " .. U.fmtMoney(amount) .. "; the household can't afford it." end
    SS.Money(world, -amount, cat or "family", text)
    act.charged = true
    return true
end

-- A catalogue quality field of an object's design (catalogue FA-2/FA-3), or `default` when the
-- design has none (stand-in objects, older saves). Only positive numbers count.
function F.Quality(o, key, default)
    local def = o and SS.Objects[o.def]
    local q = def and def.quality
    local v = q and q[key]
    if type(v) == "number" and v > 0 then return v end
    return default
end

-- Tell the catalogue which quality fields family reads, so buy mode shows those numbers (it hides
-- a field nobody reads). Keys: "clean:litter", "capacity:aquarium", "speed:garden_plot"...
function F.DeclareReads(...)
    local C = SS.Catalog
    if not (C and C.SetReader) then return false end
    for n = 1, select("#", ...) do C.SetReader((select(n, ...))) end
    return true
end

function F.CanAfford(world, amount)
    if (world.money or 0) < amount then return false, "That costs " .. U.fmtMoney(amount) .. "; the household can't afford it." end
    return true
end

function F.Journal(world, text)
    if world.journal and SS.Actions.Journal then SS.Actions.Journal(world, text) end
end

function F.Notice(world, actor, text, icon)
    if actor then SS.Actions.Message(world, actor, text, icon)
    else SS.Emit("notice", nil, text) end
end

-- Authored line through the social module's pool; the fallback (plain, not a joke) is used only
-- when the pool has nothing for this situation. Returns the text shown.
function F.Say(world, actor, situation, ctx, fallback, icon)
    local text
    if SS.Lines and SS.Lines.Say then text = SS.Lines.Say(world, actor, situation, ctx or {}) end
    if text then
        actor.balloon = { icon = icon, text = text, untilT = world.time + 20, kind = "speech" }
        return text
    end
    if fallback then
        actor.balloon = { icon = icon, text = fallback, untilT = world.time + 20, kind = "speech" }
        return fallback
    end
end

function F.Record(world, kind, data)
    if SS.Events and SS.Events.Record then return SS.Events.Record(world, kind, data) end
end
function F.Resolve(world, ev, outcome)
    local id = type(ev) == "table" and ev.id or ev
    if id and SS.Events and SS.Events.Resolve then SS.Events.Resolve(world, id, outcome) end
end

function F.Pick(world, stream, list) return SS.Pick(world, stream, list) end

function F.Dist(a, b) return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs((a.level or 0) - (b.level or 0)) * 6 end

---------------------------------------------------------------------------
-- Hot-path caches (ARCH §4: no table creation per step in Sim.Step paths).
--
-- Tag index: F.ObjectsWithTag(world, tag) returns a shared, read-only list of the lot's objects
-- carrying `tag`, sorted by id. Lists are built once per tag and kept until the object set can
-- have changed: another lot, a new lot.version, a structural rebuild (SS.RT.version), household-
-- core's object-set counter (SS.RT.objVer), any non-state `lotChanged`, or (checked at most once
-- per sim step, without allocating) a different object count. Callers never modify the lists.
---------------------------------------------------------------------------
local tagIdx = { gen = 0, lists = {} }
local lotGen = 0
F.tagIndexBuilds = 0 -- how often the index was rebuilt (tests and the perf probe read it)
SS.On("lotChanged", function(kind) if kind ~= "state" then lotGen = lotGen + 1 end end)
SS.On("worldAttached", function() lotGen = lotGen + 1 end)

local function countObjects(objects)
    local n = 0
    for _ in pairs(objects) do n = n + 1 end
    return n
end

local function tagIndexFresh(world)
    local c, lot, rt = tagIdx, world.lot, SS.RT or {}
    if c.lot ~= lot or c.ver ~= lot.version or c.rtv ~= rt.version or c.objVer ~= rt.objVer or c.lotGen ~= lotGen then return false end
    if c.checkedAt ~= world.time then
        if countObjects(lot.objects) ~= c.n then return false end
        c.checkedAt = world.time
    end
    return true
end

-- The index's generation: changes whenever the lists were rebuilt (derived caches key on it).
function F.TagIndexGen(world)
    if not tagIndexFresh(world) then
        local c, lot, rt = tagIdx, world.lot, SS.RT or {}
        c.lot, c.ver, c.rtv, c.objVer, c.lotGen = lot, lot.version, rt.version, rt.objVer, lotGen
        c.n, c.checkedAt = countObjects(lot.objects), world.time
        c.lists = {}
        c.gen = c.gen + 1
        F.tagIndexBuilds = F.tagIndexBuilds + 1
    end
    return tagIdx.gen
end

local function byId(a, b) return a.id < b.id end
F.ById = byId

-- Objects carrying a tag on this lot, sorted by id (deterministic). Shared list: read only.
function F.ObjectsWithTag(world, tag)
    F.TagIndexGen(world)
    local lists = tagIdx.lists
    local out = lists[tag]
    if out then return out end
    out = {}
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        if def and SS.Tags.Has(def, tag) then out[#out + 1] = o end
    end
    table.sort(out, byId)
    lists[tag] = out
    return out
end

-- Actor ids on the lot in sorted order, like SS.Sim.ActorIds, but shared and rebuilt (as a new
-- table, so a loop over the old one is never disturbed) only when the set of actors changed.
-- Checking costs one pass over world.actors and allocates nothing. Read only; entries can name an
-- actor who left during the loop, so callers look each one up.
local idCache = { n = -1 }
F.actorIdBuilds = 0
function F.ActorIds(world)
    local c, actors = idCache, world.actors
    local ids = c.ids
    if ids and c.world == world then
        local n = 0
        for _ in pairs(actors) do n = n + 1 end
        if n == c.n then
            local same = true
            for k = 1, n do if not actors[ids[k]] then same = false; break end end
            if same then return ids end
        end
    end
    ids = {}
    for id in pairs(actors) do ids[#ids + 1] = id end
    table.sort(ids)
    c.ids, c.n, c.world = ids, #ids, world
    F.actorIdBuilds = F.actorIdBuilds + 1
    return ids
end

function F.RemoveObject(world, oid)
    if type(oid) == "table" then oid = oid.id end
    local lot = world.lot
    local o = lot.objects[oid]
    if not o then return end
    lot.objects[oid] = nil
    lot.version = (lot.version or 1) + 1
    W.Rebuild(world)
    SS.Emit("lotChanged", "object", oid)
end

-- Place a system object (family-owned, buyable = false) on a free cell. Returns the object.
function F.AddObject(world, def, i, j, level, f, state)
    local lot = world.lot
    lot.nextObj = lot.nextObj or 1
    local id
    repeat
        id = "o" .. lot.nextObj
        lot.nextObj = lot.nextObj + 1
    until not lot.objects[id]
    local o = { id = id, def = def, x = i, y = j, f = f or 0, level = level or 0, state = state or {}, bought = world.time, paid = 0 }
    if world.household then o.owner = world.household.id end
    lot.objects[id] = o
    lot.version = (lot.version or 1) + 1
    W.Rebuild(world)
    SS.Emit("lotChanged", "object", id)
    return o
end

-- Door cells of the lot (edge key -> both cells), cached per rebuild.
local doorCache = { v = -1 }
local function doors(world)
    if doorCache.v == SS.RT.version and doorCache.lot == world.lot.id then return doorCache end
    local list, near = {}, {}
    for key, wl in pairs(W.Walls(world.lot, 0)) do
        if wl.kind == "door" or wl.kind == "gate" or wl.kind == "arch" then
            local _, _, _, ai, aj, bi, bj = G.parseEdge(key)
            list[#list + 1] = { key = key, a = { ai, aj }, b = { bi, bj }, kind = wl.kind }
            near[ai .. ":" .. aj] = true
            near[bi .. ":" .. bj] = true
        end
    end
    table.sort(list, function(x, y) return x.key < y.key end)
    doorCache = { v = SS.RT.version, lot = world.lot.id, list = list, near = near }
    return doorCache
end

-- The front door: the exterior door (outdoor on one side, a room on the other) nearest the lot
-- entry. Returns outside i, j and inside i, j (inside nil when the lot has no house).
function F.FrontDoor(world)
    local ei, ej = SS.Street.EntryCell(world)
    local best, bestD
    for _, d in ipairs(doors(world).list) do
        if d.kind == "door" then
            local ra = W.InLot(world.lot, d.a[1], d.a[2]) and W.RoomAt(world, 0, d.a[1], d.a[2]) or -1
            local rb = W.InLot(world.lot, d.b[1], d.b[2]) and W.RoomAt(world, 0, d.b[1], d.b[2]) or -1
            local out, inn
            if ra == 0 and rb > 0 then out, inn = d.a, d.b elseif rb == 0 and ra > 0 then out, inn = d.b, d.a end
            if out then
                local dist = math.abs(out[1] - ei) + math.abs(out[2] - ej)
                if not bestD or dist < bestD then best, bestD = { out, inn }, dist end
            end
        end
    end
    if best then return best[1][1], best[1][2], best[2][1], best[2][2] end
    return ei, ej
end

function F.NearDoor(world, i, j) return doors(world).near[i .. ":" .. j] == true end

-- Nearest free cell (diamond rings, deterministic). opts: indoor, outdoor, open (>= 3 free
-- neighbours), notDoor, avoid = { ["i:j"] = true }, minR (skip rings closer than this),
-- sameRoom (only cells in the room of (i, j)).
function F.FreeCellNear(world, level, i, j, maxR, opts)
    opts = opts or {}
    local lot = world.lot
    level = level or 0
    local room0 = opts.sameRoom and W.RoomAt(world, level, i, j)
    for r = opts.minR or 0, maxR or 8 do
        for dj = -r, r do
            local rest = r - math.abs(dj)
            local dis = rest == 0 and { 0 } or { -rest, rest }
            for _, di in ipairs(dis) do
                local ci, cj = i + di, j + dj
                if W.InLot(lot, ci, cj) and not W.Blocked(world, level, ci, cj) then
                    local ok = true
                    local room = W.RoomAt(world, level, ci, cj)
                    if opts.indoor and room == 0 then ok = false end
                    if opts.outdoor and room ~= 0 then ok = false end
                    if room0 and room ~= room0 then ok = false end
                    if ok and opts.notDoor and F.NearDoor(world, ci, cj) then ok = false end
                    if ok and opts.avoid and opts.avoid[ci .. ":" .. cj] then ok = false end
                    if ok and opts.open then
                        local free = 0
                        for k = 0, 3 do
                            local d = G.DIRS[k]
                            if not W.Blocked(world, level, ci + d[1], cj + d[2]) and W.CanStep(world, level, ci, cj, ci + d[1], cj + d[2]) then free = free + 1 end
                        end
                        if free < 3 then ok = false end
                    end
                    if ok then return ci, cj end
                end
            end
        end
    end
end

-- Queue a walk for an actor (NPCs, pets). manual defaults to true (orders beat autonomy).
function F.GoTo(world, actor, i, j, level, manual)
    actor.queue = actor.queue or {}
    actor.queue[#actor.queue + 1] = { iid = "goto", x = i, y = j, level = level or 0, manual = manual ~= false }
end

-- Apply a share of `gains` (total over `dur` minutes) to a person for a tick of `dt` minutes.
function F.TickGain(world, act, person, gains, dur, dt)
    if not person or not gains then return end
    local frac = math.min(dt, dur - act.t) / dur
    if frac <= 0 then return end
    for need, amt in pairs(gains) do SS.Needs.Add(person, need, amt * frac) end
end

-- The target of a targetActor action, if still close enough to act on.
function F.TargetInReach(world, actor, act, reach)
    local t = act.tid and world.actors[act.tid]
    if not t then return nil, "They're not here any more." end
    if (t.level or 0) ~= (actor.level or 0) or math.abs(t.x - actor.x) + math.abs(t.y - actor.y) > (reach or 2.6) then
        return nil, (t.name or "They") .. " moved away."
    end
    return t
end

-- The object an interaction works on vanished mid-action (sold, deleted, burnt, cleaned away by
-- someone else). onStart handlers return `false, F.GONE` (the executor fails the start with the
-- reason). onTick handlers call F.Gone: the action ends as failed with the reason, whichever
-- executor runs it, and never ticks on a missing object again.
F.GONE = "It's gone."
function F.Gone(world, actor, act, text)
    text = text or F.GONE
    if act and actor and actor.act == act and SS.Actions.Finish then
        SS.Actions.Finish(world, actor, "failed", text)
    elseif act then
        act.complete = true
    end
    return false, text
end

-- A person record still exists for this id (a target who left the lot is still someone).
function F.Exists(world, rid) return rid ~= nil and F.Root(world).residents[rid] ~= nil end

-- Cooldowns shared across saves (rejections): key -> until time.
function F.Cooling(world, key)
    local s = F.State(world)
    local t = s.cool[key]
    return t ~= nil and t > F.Root(world).time
end
function F.SetCool(world, key, minutes) F.State(world).cool[key] = F.Root(world).time + minutes end

-- Is (object or person id, interaction) on the executor's failure cool-down for this actor? The
-- executor sets actor.cool when free will's choice fails (no route, refused); its own object scan
-- skips those, and every family candidate provider does too, so a target nobody can reach is not
-- offered again straight away while other jobs wait.
function F.AutoCooling(world, actor, id, iid)
    local cool = actor.cool
    if not cool or not id or next(cool) == nil then return false end
    local t = cool[id .. ":" .. iid]
    return t ~= nil and t > world.time
end

-- Put away props left in hand from before a load. `props` maps a prop to the family interaction
-- that takes it out (watering_can -> garden_water). On this branch nothing is mid-action after a
-- load, so any such prop is stray. Household-core's executor resumes actions after a load (before
-- the systems attach), so a prop is kept when the running action explains it:
--   * it is the prop's own interaction (a resumed watering keeps its can);
--   * the running interaction declares that prop (`ia.carry`), or the actor holds an item
--     (`actor.held`, household-core's hands: a resumed meal's plate_food is its prop);
-- otherwise it is put away, so a stray can never blocks the next watering. (household-core's
-- request FA-4.)
function F.PutAwayProps(world, props)
    local ids = F.ActorIds(world)
    for n = 1, #ids do
        local a = world.actors[ids[n]]
        local iid = a and a.carry and props[a.carry]
        if iid then
            local act = a.act
            local ia = act and SS.Interactions[act.iid]
            local explained = act ~= nil and (act.iid == iid or a.held ~= nil or (ia ~= nil and ia.carry == a.carry))
            if not explained then a.carry = nil end
        end
    end
end

---------------------------------------------------------------------------
-- Family-tag slot defaults. Interactions attached by tag name the slots below; objects from the
-- catalogue that lack them get these defaults (all four sides). Requested in docs/requests/family.md.
---------------------------------------------------------------------------
local ALL4 = { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }
local FRONT = { approaches = ALL4, face = 2 }
-- Play sets: Play uses the slot group "player", so a set with several player places (the
-- catalogue's play fort has four) takes several children at once (catalogue's request FA-1).
local PLAYER = { approaches = ALL4, face = 2, group = "player" }
F.SLOT_DEFAULTS = {
    crib = { front = FRONT }, highchair = { front = FRONT }, toybox = { front = FRONT }, kid_play = { front = PLAYER },
    pet_bowl = { front = FRONT }, pet_toy = { front = FRONT }, aquarium = { front = FRONT },
    pet_bed = { petbed = { approaches = ALL4, face = 0, on = true } },
    litter = { front = FRONT, tray = { approaches = ALL4, face = 0, on = true } },
    garden_plot = { front = FRONT }, planter = { front = FRONT },
    tree = { front = FRONT }, shrub = { front = FRONT }, flowers = { front = FRONT },
    fountain = { front = FRONT }, birdbath = { front = FRONT },
}

function F.PrepareDef(def)
    if not def or not def.tags then return end
    for tag, slots in pairs(F.SLOT_DEFAULTS) do
        if SS.Tags.Has(def, tag) then
            def.slots = def.slots or {}
            for name, proto in pairs(slots) do
                if not def.slots[name] then def.slots[name] = U.deepcopy(proto) end
            end
        end
    end
    -- a play set whose own slots name no "player" place: its front is one
    if SS.Tags.Has(def, "kid_play") and not def.slots.player then
        local any = false
        for _, sl in pairs(def.slots) do if sl.group == "player" then any = true; break end end
        if not any and def.slots.front then def.slots.front.group = "player" end
    end
end

-- Idempotent: attach tag interactions and slot defaults to every definition (late ones included).
function F.PrepareDefs()
    for _, def in pairs(SS.Objects) do
        SS.Tags.Apply(def)
        F.PrepareDef(def)
    end
end

---------------------------------------------------------------------------
-- Environment (room score) effects of object states: wilted or dead plants, a dirty or empty
-- aquarium, an empty birdbath. Three ways in, the first that exists:
--   "hook":      SS.World.RegisterEnvHook (requested from household-core, HC-1);
--   "breakdown": household-core's SS.World.RoomBreakdown: family's deltas join the room's
--                decoration part with household-core's own weights (outdoors, or indoors per
--                area) and the total is recomputed, so RoomScore and every breakdown reader agree;
--   "wrapper":   the stub's RoomScore, wrapped with the documented scaling.
-- household-core's breakdown already scores `state.wilted` (less decoration, some mess) and mess
-- kinds (`def.mess`), in any of the three ways; family then leaves those to it.
---------------------------------------------------------------------------
function F.CoreScoresWilted() return W.RoomBreakdown ~= nil end
-- household-core's breakdown counts `def.mess` kinds (dishes, rubbish, puddles) in its mess part
function F.CoreScoresMess() return W.RoomBreakdown ~= nil end

F.envFns = {}
-- fn(world, obj, def) -> delta (added to the object's def.env) or nil
function F.RegisterEnv(fn) F.envFns[#F.envFns + 1] = fn end

function F.EnvDelta(world, o, def)
    local d = 0
    local fns = F.envFns
    for n = 1, #fns do d = d + (fns[n](world, o, def) or 0) end
    return d
end

-- Mess kinds where the room score doesn't count them itself (see F.CoreScoresMess).
F.RegisterEnv(function(world, o, def)
    local kind = def and def.mess
    if type(kind) ~= "string" or F.CoreScoresMess() then return nil end
    return FD.messEnv[kind]
end)

function F.InstallEnv()
    if F.envInstalled then return end
    F.envInstalled = true
    if W.RegisterEnvHook then
        W.RegisterEnvHook(function(world, o, def, env)
            if not o.state then return env end
            return env + F.EnvDelta(world, o, def)
        end)
        F.envMode = "hook"
        return
    end
    local function roomDelta(world, level, roomId)
        local delta = 0
        for _, o in pairs(world.lot.objects) do
            if o.state and (o.level or 0) == level then
                local def = SS.Objects[o.def]
                if def and W.RoomAt(world, level, o.x, o.y) == roomId then delta = delta + F.EnvDelta(world, o, def) end
            end
        end
        return delta
    end
    if W.RoomBreakdown then
        local origB = W.RoomBreakdown
        F.envMode = "breakdown"
        W.RoomBreakdown = function(world, level, roomId)
            local out = origB(world, level, roomId)
            local room = W.RoomInfo(level, roomId)
            if type(out) ~= "table" or not room or not world or not world.lot then return out end
            local delta = roomDelta(world, level, roomId)
            if delta == 0 then return out end
            local R = (SS.Tuning and SS.Tuning.room) or {}
            local scale = room.outdoor and (R.outdoorDecor or 1.5) or (R.decorWeight or 8) / math.sqrt(math.max(room.area or 1, 1))
            out.family = delta * scale
            out.decor = (out.decor or 0) + out.family
            out.total = U.clamp((out.light or 0) + out.decor + (out.space or 0) + (out.mess or 0), -100, 100)
            return out
        end
        return
    end
    local orig = W.RoomScore
    F.envMode = "wrapper"
    W.RoomScore = function(world, level, roomId)
        local base = orig(world, level, roomId)
        local room = W.RoomInfo(level, roomId)
        if not room then return base end
        local delta = roomDelta(world, level, roomId)
        if delta == 0 then return base end
        local scale = room.outdoor and 1.5 or 8 / math.sqrt(math.max(room.area or 1, 1))
        return U.clamp(base + delta * scale, -100, 100)
    end
end

-- A resident walking between the street and the lot wears the street's transit role
-- ("arriving"/"departing") until they step on or off the lot; family's own role (pet, infant)
-- is put back when they arrive ("streetArrived"), never over the top of the walk.
function F.StreetWalking(a)
    return type(a) == "table" and (a.role == "arriving" or a.role == "departing" or (type(a.tmp) == "table" and a.tmp.offLot == true))
end

-- Another module's role on a dog, a cat or a baby: a role registered in SS.Roles that is neither
-- family's own (`own`: "pet" or "infant") nor a street transit role. Family leaves such an actor
-- to the module that gave it that role (no decay tables, no role, no validator repair). A role
-- nobody registered is stale, so family claims the actor back.
function F.ForeignRole(a, own)
    if type(a) ~= "table" then return false end
    local r = a.role
    if r == nil or r == own or r == "arriving" or r == "departing" then return false end
    return type(SS.Roles) == "table" and SS.Roles[r] ~= nil
end
function F.OwnPet(a) return F.IsPet(a) and not F.ForeignRole(a, "pet") end

-- The keys of a table in a fixed order (by their text), for loops over saved records.
function F.SortedIds(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out, function(x, y) return tostring(x) < tostring(y) end)
    return out
end
function F.OwnInfant(a) return F.IsInfant(a) and not F.ForeignRole(a, "infant") end

---------------------------------------------------------------------------
-- Resident roles (pets and infants) and the visitors framework
---------------------------------------------------------------------------
-- Pets and infants carry a role so their own brain runs (SS.Roles[role].tick, no human free
-- will), but they live here. The visitors framework treats any role it doesn't know as a visitor:
-- it drops such actors on load, keeps them out of rooms, and lists them as visitors. Until it
-- treats SS.Roles entries marked `resident = true` as household (requested, VI-1), family lists
-- its resident roles in the visitors registry as household members that are kept as they are
-- after a load. SS.Roles keeps family's own definitions, so the framework never ticks them.
function F.DeclareResidentRole(name, label)
    local V = SS.Visitors
    if not (V and type(V.roles) == "table") or V.roles[name] then return false end
    -- a framework that honours `resident = true` in SS.Roles itself (V.Resident) needs no second
    -- record (visitors' request 0)
    if V.Resident then return false end
    V.roles[name] = { name = name, label = label, access = "household", class = "household", resident = true, family = true,
        social = false, useAutonomy = false, reconcile = function() return "keep" end }
    return true
end

---------------------------------------------------------------------------
-- Households: special care households, moving a resident, ending a household, continuing
---------------------------------------------------------------------------
function F.EnsureHousehold(world, spec)
    local root = F.Root(world)
    local hh = root.households[spec.id]
    if not hh then
        hh = { id = spec.id, name = spec.name, money = 0, members = {}, ledger = {}, journal = {}, flags = { service = true } }
        root.households[spec.id] = hh
    end
    hh.flags = hh.flags or {}
    hh.flags.service = true
    return hh
end

local function removeFrom(list, v)
    for n = #list, 1, -1 do if list[n] == v then table.remove(list, n) end end
end

-- Close a household that has nobody left (its lot becomes vacant; cash stays on its record).
function F.CloseHousehold(world, hh, reason)
    hh.flags = hh.flags or {}
    if hh.flags.ended then return end
    hh.flags.ended = { t = F.Root(world).time, reason = reason, lotId = hh.lotId }
    if SS.Households and SS.Households.Close then
        SS.Households.Close(world, hh.id, reason)
    elseif not (world.household == hh) then
        hh.lotId = nil
    end
end

-- Move a resident between households without duplicating them. Money rule (explicit):
-- opts.money == "sole": when the mover was the only member left in their old household, its cash
-- comes along (one ledger entry each side) and the old household closes. Otherwise no money moves.
-- opts.keepOpen: never close the old household here (taking dependents into care ends it properly).
-- Returns ok, why | amount moved.
function F.MoveResident(world, rid, toId, opts)
    opts = opts or {}
    local root = F.Root(world)
    local r = root.residents[rid]
    local to = root.households[toId]
    if not r then return false, "That person no longer exists." end
    if not to then return false, "That household no longer exists." end
    if SS.Households and SS.Households.Transfer then
        return SS.Households.Transfer(world, rid, toId, opts)
    end
    local fromId = r.householdId
    local from = fromId and root.households[fromId]
    if fromId == toId then
        local have = false
        for _, m in ipairs(to.members) do if m == rid then have = true end end
        if not have then to.members[#to.members + 1] = rid end
        return true, 0
    end
    if from then removeFrom(from.members, rid) end
    removeFrom(to.members, rid)
    to.members[#to.members + 1] = rid
    r.householdId = toId
    local moved = 0
    if from and not F.IsServiceHousehold(from) then
        local left = 0
        for _, m in ipairs(from.members) do
            local mr = root.residents[m]
            if mr and not mr.dead then left = left + 1 end
        end
        if left == 0 and not opts.keepOpen then
            if opts.money == "sole" and (from.money or 0) > 0 and not F.IsServiceHousehold(to) then
                moved = from.money
                F.HouseholdMoney(world, from, -moved, "family", r.name .. " moved out and took the household savings")
                F.HouseholdMoney(world, to, moved, "family", r.name .. " moved in with their savings")
            end
            F.CloseHousehold(world, from, opts.reason or "everyone moved out")
        end
    end
    SS.Emit("householdChanged", world, rid, fromId, toId)
    return true, moved
end

-- Describe the money rule before the player confirms a move.
function F.MoveMoneyPreview(world, rid)
    local root = F.Root(world)
    local r = root.residents[rid]
    local from = r and r.householdId and root.households[r.householdId]
    if not from or F.IsServiceHousehold(from) then return 0, (r and r.name or "They") .. " brings no money." end
    local left = 0
    for _, m in ipairs(from.members) do
        local mr = root.residents[m]
        if mr and not mr.dead and m ~= rid then left = left + 1 end
    end
    if left == 0 and FD.moveInMoney == "sole" and (from.money or 0) > 0 then
        return from.money, r.name .. " lives alone, so their household's " .. U.fmtMoney(from.money) .. " comes with them."
    end
    return 0, r.name .. "'s household keeps its money; nothing is transferred."
end

-- Take a dependent (or pet) into care: off the lot, into the services or shelter household.
function F.TakeIntoCare(world, rid, why)
    local root = F.Root(world)
    local r = root.residents[rid]
    if not r or r.dead then return false end
    local fromId = r.householdId
    if world.actors and world.actors[rid] then
        if SS.Infants and SS.Infants.Detach then SS.Infants.Detach(world, r) end
        if SS.Pets and SS.Pets.Detach then SS.Pets.Detach(world, r) end
        SS.Sim.RemoveActor(world, rid, { reason = "in_care" })
    end
    local spec = F.IsPet(r) and FD.shelterHousehold or FD.servicesHousehold
    F.EnsureHousehold(world, spec)
    -- keepOpen: the caller decides how the old household ends (EndHousehold tells the player why)
    F.MoveResident(world, rid, spec.id, { reason = why, keepOpen = true })
    r.lotId = nil
    r.away = { reason = "in_care" }
    r.role, r.roleData = nil, nil
    local fam = F.Fam(r)
    fam.removedFrom = fromId
    fam.inCareSince = root.time
    fam.careReason = why
    return true
end

-- End the household when nobody controllable is left. Never leaves a broken save: the lot stays,
-- the record is flagged, and the player gets a continuation (another household or the neighbourhood).
function F.EndHousehold(world, hh, reason)
    local root = F.Root(world)
    hh = F.Household(world, hh)
    if not hh then return end
    hh.flags = hh.flags or {}
    if hh.flags.ended then return end
    -- anyone still listed and alive (pets) goes to care first
    for _, rid in ipairs(U.deepcopy(hh.members)) do
        local r = root.residents[rid]
        if r and not r.dead then F.TakeIntoCare(world, rid, reason) end
    end
    hh.flags.ended = { t = root.time, reason = reason, lotId = hh.lotId }
    -- a guardian case still open (the household ended some other way first) closes with it
    local case = hh.flags.guardianCase and F.State(world).cases[hh.flags.guardianCase]
    if case and (case.state == "search" or case.state == "welfare") then
        case.state = "closed"
        F.Resolve(world, case.event, "ended")
    end
    if SS.Households and SS.Households.End then
        SS.Households.End(world, hh.id, reason)
    else
        hh.lotId = nil
    end
    local text = "The " .. (hh.name or "") .. " household has ended: " .. reason
    if world.household == hh then F.Journal(world, text) end
    SS.Emit("householdEnded", world, hh, reason)
    SS.Emit("notice", nil, text .. " Choose another household to continue.")
end

-- Households the player can continue with (members alive, a lot, not ended or special).
function F.ContinueOptions(world)
    local root = F.Root(world)
    local out = {}
    for id, hh in pairs(root.households) do
        if hh.lotId and root.hood.lots[hh.lotId] and not F.IsServiceHousehold(hh) and not (hh.flags and hh.flags.ended) then
            local n = 0
            for _, rid in ipairs(hh.members or {}) do
                local r = root.residents[rid]
                if r and not r.dead and F.IsHuman(r) then n = n + 1 end
            end
            if n > 0 then out[#out + 1] = { id = id, name = hh.name, members = n, lotId = hh.lotId } end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- Play another household after this one ended. With the neighbourhood module the switch goes
-- through SS.Hood.Play (clocks parked and resumed, members brought home, starter jobs,
-- householdPlayed). Events' continuation record for the household that ended is answered first
-- ("keep": family already released or kept its lot), because Hood.Play refuses to switch while
-- it is open. (hood's request FA-1.)
function F.Continue(world, hhId)
    local root = F.Root(world)
    local hh = root.households[hhId]
    if not hh or not hh.lotId then return false, "That household has no home to continue in." end
    local w
    local Hood = SS.Hood
    if Hood and Hood.Play then
        local pe = root.pendingEnd
        if type(pe) == "table" and pe.hh ~= hhId and SS.Death and SS.Death.Continue then
            pcall(SS.Death.Continue, world, "keep")
        end
        local ok, why, w2 = Hood.Play(root, hhId)
        if not ok then return false, why or "That household can't be played right now." end
        w = w2 or SS.Sim.world
    else
        root.active = { householdId = hhId, lotId = hh.lotId }
        w = SS.Sim.Attach(root, hh.lotId, hhId)
    end
    if SS.UI and SS.UI.frame then
        SS.UI.selected = nil
        for _, rid in ipairs(hh.members) do if w.actors[rid] and F.IsHuman(w.actors[rid]) then SS.UI.selected = rid; break end end
        SS.UI.dirty = true
        if SS.UI.RefreshPortrait then SS.UI.RefreshPortrait() end
    end
    return true, w
end

---------------------------------------------------------------------------
-- New people (babies, adopted children)
---------------------------------------------------------------------------
local function mix(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t } end

function F.Surname(world, hh)
    hh = F.Household(world, hh)
    return hh and hh.name or ""
end

function F.PickName(world, pronoun, hh)
    local pool = FD.names[pronoun] or FD.names.they
    local used = {}
    for _, r in ipairs(F.Members(world, hh)) do used[(r.name or ""):match("^(%S+)") or ""] = true end
    local start = SS.RandomInt(world, "family", 1, #pool)
    for k = 0, #pool - 1 do
        local n = pool[(start + k - 1) % #pool + 1]
        if not used[n] then return n end
    end
    return pool[start]
end

-- Validate a player-typed first name: trimmed, printable, 1..nameMax characters.
function F.CleanFirstName(name)
    if type(name) ~= "string" then return nil, "Type a name first." end
    name = name:gsub("[%c|]", ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if #name == 0 then return nil, "Type a name first." end
    if #name > (FD.nameMax or 20) then return nil, "Names can be at most " .. (FD.nameMax or 20) .. " characters." end
    return name
end

-- Rename a new family member (first name; the household surname stays).
function F.RenameFirst(world, person, first)
    local clean, why = F.CleanFirstName(first)
    if not clean then return false, why end
    local old = person.name
    local surname = old:match("%s(%S+)$")
    person.name = surname and (clean .. " " .. surname) or clean
    F.Fam(person).named = true
    if old ~= person.name then F.Journal(world, old .. " is now called " .. person.name .. ".") end
    SS.Emit("personRenamed", world, person, old)
    return true
end

-- spec = { age = "infant"|"child", hh = household, parents = { rid... }, pronoun?, first? }
function F.NewPerson(world, spec)
    local root = F.Root(world)
    local hh = F.Household(world, spec.hh)
    local id = F.NewId(world, "r_fam")
    local r = SS.Random(world, "family")
    local pronoun = spec.pronoun or (r < 0.45 and "she" or r < 0.9 and "he" or "they")
    local first = spec.first or F.PickName(world, pronoun, hh)
    local parents = {}
    for _, pid in ipairs(spec.parents or {}) do
        local p = root.residents[pid]
        if p and p.look then parents[#parents + 1] = p end
    end
    local skin, hair
    if #parents >= 2 then
        skin = mix(parents[1].look.skin, parents[2].look.skin, SS.Random(world, "family"))
        hair = (SS.Random(world, "family") < 0.5 and parents[1] or parents[2]).look.hair
    elseif #parents == 1 then
        skin, hair = parents[1].look.skin, parents[1].look.hair
    else
        skin = F.Pick(world, "family", FD.skins)
        hair = F.Pick(world, "family", FD.hairs)
    end
    local top = F.Pick(world, "family", FD.playColours)
    local bottom = F.Pick(world, "family", FD.playColours)
    local personality = {}
    for _, k in ipairs({ "neat", "outgoing", "active", "playful", "nice" }) do
        local base = 5
        if #parents > 0 then
            local s = 0
            for _, p in ipairs(parents) do s = s + ((p.personality and p.personality[k]) or 5) end
            base = s / #parents
        end
        personality[k] = U.clamp(math.floor(base + SS.RandomInt(world, "family", -2, 2) + 0.5), 0, 10)
    end
    local needs = {}
    if spec.age == "infant" then
        for k, v in pairs(SS.FamilyData.infant.startNeeds) do needs[k] = v end
    else
        needs = { hunger = 40, energy = 50, bladder = 50, hygiene = 50, fun = 30, social = 30, comfort = 40, room = 0 }
    end
    local everyday = { style = "play", top = top, bottom = bottom, shoes = { 0.30, 0.22, 0.16 } }
    local person = {
        id = id, name = first .. (F.Surname(world, hh) ~= "" and (" " .. F.Surname(world, hh)) or ""),
        kind = "human", age = spec.age or "child", pronoun = pronoun,
        householdId = nil, lotId = nil, x = 0.5, y = 0.5, level = 0, facing = 0,
        look = { skin = skin, hair = hair, hairStyle = (pronoun == "she") and "long" or "short", body = "average", face = 1,
            top = top, bottom = bottom, shoes = everyday.shoes,
            outfits = { everyday = everyday, sleep = { style = "pyjamas", top = { 0.80, 0.85, 0.95 }, bottom = { 0.80, 0.85, 0.95 }, shoes = everyday.shoes } } },
        outfit = "everyday", personality = personality, interests = {}, needs = needs,
        skills = { cooking = 0, mechanical = 0, charisma = 0, body = 0, logic = 0, creativity = 0 },
        memories = {}, bio = spec.bio or "",
        fam = { parents = spec.parents and U.deepcopy(spec.parents) or {}, bornAt = root.time },
    }
    root.residents[id] = person
    if spec.age == "infant" and SS.Infants and SS.Infants.Setup then SS.Infants.Setup(world, person) end
    return person
end

-- Set parent/sibling ties for a new child joining `hh`.
function F.LinkFamily(world, child, parents, hh)
    for _, pid in ipairs(parents or {}) do
        SS.Social.SetFamily(world, pid, child.id, "parent")
        F.Change(world, pid, child.id, 30, 20)
        F.Change(world, child.id, pid, 25, 15)
    end
    for _, m in ipairs(F.Members(world, hh)) do
        if m.id ~= child.id and F.IsDependent(m) then
            SS.Social.SetFamily(world, m.id, child.id, "sibling")
            F.Change(world, m.id, child.id, 10, 5)
            F.Change(world, child.id, m.id, 10, 5)
        end
    end
end

-- Bring a new or returning household member onto the session lot near (i, j).
function F.PlaceOnLot(world, person, i, j, opts)
    if F.IsInfant(person) and SS.Infants and SS.Infants.PlaceNew then
        return SS.Infants.PlaceNew(world, person, i, j)
    end
    local ci, cj = F.FreeCellNear(world, 0, i, j, 10, opts)
    if not ci then ci, cj = SS.Street.EntryCell(world) end
    person.away = nil
    return SS.Sim.AddActor(world, person.id, ci, cj, 0)
end

---------------------------------------------------------------------------
-- Service visits (Family Services caseworker, pet courier, produce buyer) on the visitors framework
---------------------------------------------------------------------------
F.visitTasks = {}   -- task -> fn(world, worker|nil, rec) -> ok, text   (worker nil = handled remotely)
F.visitRefused = {} -- task -> fn(world, rec)   (the worker was sent away before finishing)

function F.EnsureNpc(world, rid)
    local root = F.Root(world)
    local spec = FD.npcs[rid]
    local r = root.residents[rid]
    if not r and spec then
        local look = U.deepcopy(spec.look)
        -- everyday clothes and the work outfit (what the visitors framework dresses NPCs in), both
        -- in the NPC's own colours
        look.outfits = look.outfits or {
            everyday = { style = "everyday", top = look.top, bottom = look.bottom, shoes = look.shoes },
            work = { style = spec.outfit or "everyday", top = look.top, bottom = look.bottom, shoes = look.shoes },
        }
        r = { id = rid, name = spec.name, kind = "human", age = "adult", pronoun = spec.pronoun, npc = true,
            look = look, bio = spec.bio, x = 0.5, y = 0.5, level = 0, facing = 0,
            needs = { hunger = 60, energy = 60, bladder = 60, hygiene = 60, fun = 40, social = 40, comfort = 40, room = 0 },
            personality = { neat = 6, outgoing = 6, active = 5, playful = 3, nice = 7 }, skills = {}, interests = {} }
        root.residents[rid] = r
    end
    return r
end

-- Request a visit. data is task-specific. Returns the visit record.
function F.RequestVisit(world, rid, task, hh, data, delay)
    local s = F.State(world)
    hh = F.Household(world, hh)
    local id = F.NewId(world, "v")
    local spec = FD.npcs[rid]
    local rec = { id = id, rid = rid, role = spec.role, task = task, hh = hh and hh.id, lotId = hh and hh.lotId or world.lot.id,
        dueAt = F.Root(world).time + (delay or 0), state = "scheduled", attempts = 0, data = data or {} }
    s.visits[id] = rec
    SS.Sim.Schedule(world, rec.dueAt, "family.visit", { vid = id }, rec.lotId)
    return rec
end

function F.VisitPending(world, task, hhId, pred)
    for _, rec in pairs(F.State(world).visits) do
        if rec.task == task and rec.hh == hhId and (rec.state == "scheduled" or rec.state == "onlot") and (not pred or pred(rec)) then return rec end
    end
end

local function finishVisit(world, rec, state)
    rec.state = state
    rec.doneAt = F.Root(world).time
    -- keep the table bounded: drop old finished visits
    local s = F.State(world)
    local old = {}
    for id, v in pairs(s.visits) do if v.state ~= "scheduled" and v.state ~= "onlot" then old[#old + 1] = v end end
    if #old > 20 then
        table.sort(old, function(a, b) return (a.doneAt or 0) < (b.doneAt or 0) end)
        for n = 1, #old - 20 do s.visits[old[n].id] = nil end
    end
end

-- Run a task once (worker may be nil: handled without a visitor, e.g. no route or no spawn).
function F.PerformVisit(world, rec, worker)
    if rec.performed then return end
    rec.performed = true
    local fn = F.visitTasks[rec.task]
    local ok, text = true, nil
    if fn then ok, text = fn(world, worker, rec) end
    rec.result = ok and "done" or "failed"
    rec.text = text
    finishVisit(world, rec, ok and "done" or "failed")
    return ok, text
end

local function spawnWorker(world, rec)
    local busy = false
    for _, v in pairs(F.State(world).visits) do
        if v ~= rec and v.rid == rec.rid and v.state == "onlot" then busy = true end
    end
    if busy then
        rec.dueAt = F.Root(world).time + 20
        SS.Sim.Schedule(world, rec.dueAt, "family.visit", { vid = rec.id }, rec.lotId)
        return
    end
    F.EnsureNpc(world, rec.rid)
    local a = SS.Visitors and SS.Visitors.Spawn and SS.Visitors.Spawn(world, rec.rid, rec.role, { visit = rec.id, task = rec.task })
    if a then
        rec.state = "onlot"
        a.roleData = a.roleData or {}
        a.roleData.visit = rec.id
        a.roleData.task = rec.task
        a.roleData.stage = "approach"
        a.roleData.since = world.time
        a.roleData.tries = 0
        return
    end
    rec.attempts = rec.attempts + 1
    if rec.attempts <= FD.visit.spawnRetries then
        rec.dueAt = F.Root(world).time + FD.visit.retryDelay
        SS.Sim.Schedule(world, rec.dueAt, "family.visit", { vid = rec.id }, rec.lotId)
    else
        F.PerformVisit(world, rec, nil)
    end
end

-- Role state machine shared by the family service roles: walk to the front door (bounded),
-- do the task in person, leave. The visitors framework owns arrival/departure walking.
function F.WorkerTick(world, a, dt)
    local rd = a.roleData or {}
    local rec = rd.visit and F.State(world).visits[rd.visit]
    if not rec or rec.state ~= "onlot" or rec.performed then
        if not a.act and #(a.queue or {}) == 0 and not rd.leaving then
            rd.leaving = true
            SS.Visitors.Leave(world, a, "done")
        end
        return
    end
    if rd.stage == "approach" then
        if a.act or (a.queue and #a.queue > 0) then
            if world.time - (rd.since or world.time) > FD.visit.approachTimeout then
                SS.Actions.Cancel(world, a, 0); a.queue = {}
                rd.stage, rd.performAt = "perform", world.time + FD.visit.performDur
            end
            return
        end
        local di, dj = F.FrontDoor(world)
        local d = math.abs(a.x - (di + 0.5)) + math.abs(a.y - (dj + 0.5))
        if d <= 1.6 or (rd.tries or 0) >= 3 or world.time - (rd.since or world.time) > FD.visit.approachTimeout then
            rd.stage, rd.performAt = "perform", world.time + FD.visit.performDur
            a.pose = "talk"
        else
            rd.tries = (rd.tries or 0) + 1
            F.GoTo(world, a, di, dj, 0, true)
        end
    elseif rd.stage == "perform" then
        a.pose = "talk"
        if world.time >= (rd.performAt or 0) then
            rd.stage = "leave"
            F.PerformVisit(world, rec, a)
        end
    end
end

function F.WorkerLeft(world, a)
    local rd = a.roleData or {}
    local rec = rd.visit and F.State(world).visits[rd.visit]
    if rec and rec.state == "onlot" and not rec.performed then
        local fn = F.visitRefused[rec.task]
        if fn then fn(world, rec) else finishVisit(world, rec, "cancelled") end
    end
end

-- Family's service roles on the visitors framework. Each is one stable person from FD.npcs,
-- spawned by id (so no visitors pool), dressed in their work outfit (`outfit`, visitors' request 5).
local function registerRole(name, label, outfit)
    if not SS.Visitors or not SS.Visitors.RegisterRole then return end
    SS.Visitors.RegisterRole(name, {
        label = label, useAutonomy = false, noNeeds = true, access = "service", family = true, outfit = outfit,
        tick = F.WorkerTick, onLeave = F.WorkerLeft,
    })
end
registerRole("family_services", "Family Services caseworker", FD.npcs.npc_family_services.outfit)
registerRole("pet_courier", "Pet shop courier", FD.npcs.npc_pet_courier.outfit)
registerRole("produce_buyer", "Greengrocer's buyer", FD.npcs.npc_produce_buyer.outfit)

SS.On("scheduled", function(ev, world)
    if not world then return end
    if ev.kind == "family.visit" then
        local rec = F.State(world).visits[ev.data.vid]
        if rec and rec.state == "scheduled" then spawnWorker(world, rec) end
    elseif ev.kind == "family.baby_due" then
        F.BabyDue(world, ev.data.pid)
    elseif ev.kind == "family.case_fallback" then
        F.CaseFallback(world, ev.data.case)
    end
end)

---------------------------------------------------------------------------
-- Household growth: moving in, commitment, planning a baby, adoption
---------------------------------------------------------------------------
local I = SS.Interactions

local function adultMemberTest(world, actor)
    if not F.IsAdult(actor) then return false, "Only adults can do that." end
    if not F.IsMember(world, actor) then return false, "Only a member of this household can do that." end
    return true
end

local function pairKey(kind, a, b) return kind .. ":" .. a .. ">" .. b end

-- Engage the target for a two-person interaction: they stop what they're doing (unless it is a
-- player order, or they are standing in a doorway) and face the initiator with a pose, until the
-- initiator's action ends.
function F.Engage(world, target, initiator, pose, maxDur)
    if not target or F.IsPet(target) or F.IsInfant(target) then return end
    -- nobody is held in a doorway (they would block everyone's way in and out)
    if not target.onObj and F.NearDoor(world, math.floor(target.x), math.floor(target.y)) then return end
    if target.act and target.act.manual and target.act.iid ~= "fam_respond" then return end
    if target.act and target.act.data and target.act.data.noEngage then return end
    if target.act and target.act.iid == "fam_respond" and target.act.tid == initiator.id then return end
    if target.act then SS.Actions.Cancel(world, target, 0) end
    target.queue = target.queue or {}
    table.insert(target.queue, 1, { iid = "fam_respond", tid = initiator.id, manual = false, data = { pose = pose or "talk", maxDur = maxDur or 60 } })
end

I.fam_respond = {
    label = "Listen", category = "Family", targetActor = true, pose = "talk", maxDur = 120, manualOnly = true, advert = {},
    onStart = function(world, actor, act) act.pose = act.data.pose or "talk" end,
    onTick = function(world, actor, act, _, dt)
        local ini = world.actors[act.tid]
        if not ini or not ini.act or ini.act.tid ~= actor.id or act.t >= (act.data.maxDur or 60) then act.complete = true end
    end,
}

-- Ask to Move In ---------------------------------------------------------------
function F.MoveInCheck(world, actor, target)
    local ok, why = adultMemberTest(world, actor)
    if not ok then return false, why end
    if not target or not F.IsHuman(target) then return false, "Only people can move in." end
    if target.dead then return false, "They are no longer with us." end
    if not F.IsAdult(target) then return false, "Only an adult can be asked to move in; children arrive by adoption." end
    if F.IsMember(world, target) then return false, target.name .. " already lives here." end
    if F.IsNpc(target) or (target.role and target.role ~= "guest") then return false, target.name .. " is here to work." end
    if F.IsServiceHousehold(target.householdId) then return false, target.name .. " can't move in right now." end
    local room, rwhy = F.HasRoom(world, world.household, "human", 1)
    if not room then return false, rwhy end
    if F.Cooling(world, pairKey("movein", actor.id, target.id)) then return false, target.name .. " said no recently. Give it time." end
    return true
end

-- The target refuses to leave dependents with nobody to look after them.
local function wouldStrand(world, target)
    local root = F.Root(world)
    local hh = target.householdId and root.households[target.householdId]
    if not hh then return false end
    local adults, deps = 0, 0
    for _, rid in ipairs(hh.members) do
        local r = root.residents[rid]
        if r and not r.dead and rid ~= target.id then
            if F.IsAdult(r) then adults = adults + 1 elseif F.IsDependent(r) then deps = deps + 1 end
        end
    end
    return deps > 0 and adults == 0
end

function F.MoveIn(world, actor, target)
    local moved
    local ok, res = F.MoveResident(world, target.id, world.household.id, { money = FD.moveInMoney, reason = target.name .. " moved in with " .. actor.name })
    if not ok then return false, res end
    moved = res or 0
    if target.role then
        if SS.Visitors and SS.Visitors.Release then SS.Visitors.Release(world, target) end
        target.role, target.roleData, target.noNeeds = nil, nil, nil
    end
    target.away = nil
    if world.actors[target.id] then target.lotId = world.lot.id end
    local rel = F.Rel(world, actor.id, target.id)
    rel.flags.household = true
    F.Rel(world, target.id, actor.id).flags.household = true
    F.Journal(world, target.name .. " moved in" .. (moved > 0 and (" and brought " .. U.fmtMoney(moved) .. " of savings") or "") .. ".")
    SS.Emit("residentMovedIn", world, target, actor)
    return true
end

I.fam_move_in = {
    label = "Ask to Move In", category = "Family", targetActor = true, pose = "talk", dur = 6, manualOnly = true, advert = {},
    ages = { adult = true }, kinds = { human = true },
    test = function(world, actor, target) return F.MoveInCheck(world, actor, target) end,
    onStart = function(world, actor, act)
        local t, why = F.TargetInReach(world, actor, act)
        if not t then return false, why end
        F.Engage(world, t, actor, "talk", 10)
    end,
    onEnd = function(world, actor, act, _, status)
        if status ~= "done" then return end
        local t = world.actors[act.tid]
        if not t then return end
        local ok, why = F.MoveInCheck(world, actor, t)
        if not ok then SS.Actions.Message(world, actor, why, "social"); return end
        local rel = F.Rel(world, t.id, actor.id)
        local T = FD.moveIn
        local reason
        if rel.life < T.minLife or rel.daily < T.minDaily then reason = t.name .. " doesn't feel close enough to " .. actor.name .. " to share a home."
        elseif wouldStrand(world, t) then reason = t.name .. " can't leave the children at home without an adult."
        elseif t.fam and t.fam.spouse and t.fam.spouse ~= actor.id and F.SpouseOf(world, t.id) then reason = t.name .. " is committed to someone else." end
        if reason then
            F.SetCool(world, pairKey("movein", actor.id, t.id), T.rejectCooldown)
            F.Change(world, actor.id, t.id, T.rejectDaily, 0)
            F.Change(world, t.id, actor.id, math.floor(T.rejectDaily / 2), 0)
            actor.pose = "idle"
            SS.Actions.Message(world, actor, reason, "social")
            return
        end
        local okm, err = F.MoveIn(world, actor, t)
        if okm then SS.Actions.Message(world, actor, t.name .. " said yes and is moving in.", "social")
        else SS.Actions.Message(world, actor, err or "The move didn't work out.", "social") end
    end,
}

-- Propose Commitment and the ceremony ----------------------------------------------
function F.RomanceAllowed(world, a, b)
    if not (F.IsAdult(a) and F.IsAdult(b)) then return false, "Romance is for adults only." end
    if F.CloseFamily(world, a.id, b.id) then return false, "They're family." end
    return true
end

function F.ProposeCheck(world, actor, target)
    if not F.IsAdult(actor) or not F.IsHuman(actor) then return false, "Only adults can propose." end
    if actor.householdId ~= world.household.id then return false, "Only a member of this household can propose here." end
    if not target or not F.IsHuman(target) or target.dead then return false, "Only a person can accept a proposal." end
    local ok, why = F.RomanceAllowed(world, actor, target)
    if not ok then return false, why end
    if F.IsNpc(target) or (target.role and target.role ~= "guest") then return false, target.name .. " is here to work." end
    if F.Committed(world, actor.id, target.id) then return false, "They are already committed to each other." end
    local af, tf = actor.fam or {}, target.fam or {}
    if af.engaged == target.id then return false, "They're already engaged; hold the ceremony." end
    if F.SpouseOf(world, actor.id) then return false, actor.name .. " is already committed to someone." end
    if F.SpouseOf(world, target.id) then return false, target.name .. " is already committed to someone." end
    if F.Rel(world, actor.id, target.id).life < FD.propose.askerMinLife then return false, actor.name .. " isn't that serious about " .. target.name .. " yet." end
    if F.Cooling(world, pairKey("propose", actor.id, target.id)) then return false, target.name .. " said no recently." end
    return true
end

I.fam_propose = {
    label = "Propose Commitment", category = "Romance", targetActor = true, pose = "talk", dur = 6, manualOnly = true, advert = {},
    ages = { adult = true }, kinds = { human = true },
    test = function(world, actor, target) return F.ProposeCheck(world, actor, target) end,
    onStart = function(world, actor, act)
        local t, why = F.TargetInReach(world, actor, act)
        if not t then return false, why end
        F.Engage(world, t, actor, "talk", 10)
    end,
    onEnd = function(world, actor, act, _, status)
        if status ~= "done" then return end
        local t = world.actors[act.tid]
        if not t or not F.ProposeCheck(world, actor, t) then return end
        local rel = F.Rel(world, t.id, actor.id)
        local T = FD.propose
        if rel.life < T.minLife or rel.daily < T.minDaily then
            F.SetCool(world, pairKey("propose", actor.id, t.id), T.rejectCooldown)
            F.Change(world, actor.id, t.id, T.rejectDaily, -2)
            F.Change(world, t.id, actor.id, T.rejectDaily, 0)
            actor.pose = "cry"
            F.Say(world, t, "romance_reject", { rel = rel.life }, nil, "social")
            SS.Actions.Message(world, actor, t.name .. " turned down the proposal.", "social")
            F.Journal(world, actor.name .. " proposed to " .. t.name .. " and was turned down.")
            return
        end
        F.Fam(actor).engaged = t.id
        F.Fam(t).engaged = actor.id
        F.Rel(world, actor.id, t.id).flags.engaged = true
        F.Rel(world, t.id, actor.id).flags.engaged = true
        F.Rel(world, actor.id, t.id).flags.partner = true
        F.Rel(world, t.id, actor.id).flags.partner = true
        F.Change(world, actor.id, t.id, 15, 5)
        F.Change(world, t.id, actor.id, 15, 5)
        actor.pose = "celebrate"
        SS.Actions.Message(world, actor, t.name .. " said yes! Hold the commitment ceremony when you're ready.", "social")
        F.Journal(world, actor.name .. " and " .. t.name .. " are engaged.")
        SS.Emit("engaged", world, actor, t)
    end,
}

function F.CeremonyCheck(world, actor, target)
    if not F.IsAdult(actor) or actor.householdId ~= world.household.id then return false, "Only an adult member of this household can hold the ceremony here." end
    if not target or target.dead then return false, "They're not here." end
    if not (actor.fam and actor.fam.engaged == target.id) then return false, "Propose first: they need to be engaged." end
    if F.SpouseOf(world, target.id) or F.SpouseOf(world, actor.id) then return false, "One of them is already committed." end
    return true
end

I.fam_ceremony = {
    label = "Hold Commitment Ceremony", category = "Romance", targetActor = true, pose = "celebrate", dur = FD.ceremony.dur,
    manualOnly = true, advert = {}, ages = { adult = true }, kinds = { human = true },
    test = function(world, actor, target) return F.CeremonyCheck(world, actor, target) end,
    onStart = function(world, actor, act)
        local t, why = F.TargetInReach(world, actor, act)
        if not t then return false, why end
        F.Engage(world, t, actor, "celebrate", FD.ceremony.dur + 5)
        -- household members and guests present gather to cheer
        for _, id in ipairs(F.ActorIds(world)) do
            local p = world.actors[id]
            if p ~= actor and p ~= t and F.IsHuman(p) and not F.IsInfant(p) and not F.IsNpc(p) and not (p.act and p.act.manual) then
                if p.act then SS.Actions.Cancel(world, p, 0) end
                p.queue = p.queue or {}
                table.insert(p.queue, 1, { iid = "fam_cheer", tid = actor.id, manual = false })
            end
        end
    end,
    onEnd = function(world, actor, act, _, status)
        if status ~= "done" then return end
        local t = world.actors[act.tid] or F.Root(world).residents[act.tid]
        if not t or not F.CeremonyCheck(world, actor, t) then return end
        F.Commit(world, actor, t)
    end,
}

I.fam_cheer = {
    label = "Cheer", category = "Family", targetActor = true, pose = "celebrate", dur = FD.ceremony.cheerDur, manualOnly = true,
    advert = {}, gain = { fun = 10, social = 10 },
}

-- Commitment: spouse/partner flags via SS.Social.SetFamily; the partner moves in if there's room.
function F.Commit(world, a, b)
    SS.Social.SetFamily(world, a.id, b.id, "spouse")
    for _, pair in ipairs({ { a, b }, { b, a } }) do
        local rel = F.Rel(world, pair[1].id, pair[2].id)
        rel.flags.partner = true
        rel.flags.engaged = nil
        rel.flags.committed = true
        F.Change(world, pair[1].id, pair[2].id, 20, FD.ceremony.lifeBonus)
        local fam = F.Fam(pair[1])
        fam.spouse = pair[2].id
        fam.engaged = nil
    end
    local text = a.name .. " and " .. b.name .. " held a commitment ceremony"
    if b.householdId ~= a.householdId then
        local room = F.HasRoom(world, world.household, "human", 1)
        if room and not wouldStrand(world, b) then
            F.MoveIn(world, a, b)
            text = text .. ", and " .. b.name .. " moved in"
        else
            text = text .. "; they'll live apart for now (no room at home)"
        end
    end
    F.Journal(world, text .. ".")
    SS.Actions.Message(world, a, text .. ".", "social")
    F.Record(world, "commitment", { a = a.id, b = b.id })
    SS.Emit("commitment", world, a, b)
end

-- Plan a Baby (committed couples) -------------------------------------------------
function F.BabyCheck(world, actor, target)
    if not F.IsAdult(actor) or actor.householdId ~= world.household.id then return false, "Only an adult of this household can plan a baby." end
    if not target or not F.IsAdult(target) then return false, "Only with an adult partner." end
    if target.householdId ~= actor.householdId then return false, target.name .. " would need to live here first." end
    if not F.Committed(world, actor.id, target.id) then return false, "Only a committed couple can plan a baby here." end
    local room, why = F.HasRoom(world, world.household, "human", 1)
    if not room then return false, why end
    for _, p in pairs(F.State(world).pending) do
        if p.hh == world.household.id and p.kind == "baby" and p.state == "scheduled" then return false, "A baby is already on the way." end
    end
    if (world.money or 0) < FD.baby.minFunds then
        return false, "Babies are expensive: the household needs at least " .. U.fmtMoney(FD.baby.minFunds) .. " (supplies cost " .. U.fmtMoney(FD.baby.planCost) .. ")."
    end
    return true
end

I.fam_plan_baby = {
    label = "Plan a Baby", category = "Family", targetActor = true, pose = "talk", dur = 8, manualOnly = true, advert = {},
    ages = { adult = true }, kinds = { human = true },
    test = function(world, actor, target) return F.BabyCheck(world, actor, target) end,
    onStart = function(world, actor, act)
        local t, why = F.TargetInReach(world, actor, act)
        if not t then return false, why end
        F.Engage(world, t, actor, "talk", 12)
    end,
    onEnd = function(world, actor, act, _, status)
        if status ~= "done" then return end
        local t = world.actors[act.tid]
        if not t then return end
        local ok, why = F.BabyCheck(world, actor, t)
        if not ok then SS.Actions.Message(world, actor, why, "social"); return end
        if F.Rel(world, t.id, actor.id).life < FD.baby.partnerMinLife then
            SS.Actions.Message(world, actor, t.name .. " isn't ready for a baby yet.", "social")
            return
        end
        F.PlanBaby(world, actor, t)
    end,
}

function F.PlanBaby(world, a, b)
    local s = F.State(world)
    local id = F.NewId(world, "p")
    local root = F.Root(world)
    local rec = { id = id, kind = "baby", hh = world.household.id, lotId = world.household.lotId or world.lot.id,
        parents = { a.id, b.id }, dueAt = root.time + FD.baby.dueMinutes, state = "scheduled", t = root.time }
    s.pending[id] = rec
    -- the one commit point for the money: supplies bought now, recorded on the pending record
    F.Money(world, -FD.baby.planCost, "family", "Baby supplies and check-ups")
    rec.charged = FD.baby.planCost
    SS.Sim.Schedule(world, rec.dueAt, "family.baby_due", { pid = id }, rec.lotId)
    local days = math.floor(FD.baby.dueMinutes / 1440 + 0.5)
    SS.Actions.Message(world, a, a.name .. " and " .. b.name .. " are expecting a baby in " .. days .. " days.", "social")
    F.Journal(world, a.name .. " and " .. b.name .. " are expecting a baby.")
    SS.Emit("babyPlanned", world, rec)
    return rec
end

function F.BabyDue(world, pid)
    local rec = F.State(world).pending[pid]
    if not rec or rec.state ~= "scheduled" or rec.rid then return end
    local root = F.Root(world)
    local hh = root.households[rec.hh]
    if not hh or (hh.flags and hh.flags.ended) then rec.state = "cancelled"; return end
    local infant = F.NewPerson(world, { age = "infant", hh = hh, parents = rec.parents })
    rec.rid = infant.id
    rec.state = "done"
    F.MoveResident(world, infant.id, hh.id, { reason = "born" })
    F.LinkFamily(world, infant, rec.parents, hh)
    local near
    for _, pid2 in ipairs(rec.parents) do if world.actors[pid2] then near = world.actors[pid2]; break end end
    local i, j
    if near then
        i, j = math.floor(near.x), math.floor(near.y)
    else
        local oi, oj, ii, ij = F.FrontDoor(world)
        i, j = ii or oi, ij or oj
    end
    if world.household == hh then F.PlaceOnLot(world, infant, i, j, { indoor = true }) end
    local text = "A baby has arrived: welcome home, " .. infant.name .. "!"
    F.Journal(world, text)
    SS.Emit("notice", near, text)
    if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "info") end
    F.Record(world, "birth", { rid = infant.id, parents = rec.parents })
    SS.Emit("familyArrival", world, infant, "baby")
    SS.Emit("familyNaming", world, infant)
end

-- Adoption by phone -----------------------------------------------------------------
function F.AdoptCheck(world, caller, age)
    if not caller or not F.IsAdult(caller) then return false, "Only an adult can arrange an adoption." end
    if caller.householdId ~= (world.household and world.household.id) then return false, "Only a member of this household can arrange an adoption." end
    local room, why = F.HasRoom(world, world.household, "human", 1)
    if not room then return false, why end
    local fee = age == "child" and FD.adoption.childFee or FD.adoption.fee
    if (world.money or 0) < math.max(fee, FD.adoption.minFunds) then
        return false, "The agency needs to see at least " .. U.fmtMoney(math.max(fee, FD.adoption.minFunds)) .. " in the household account (fee " .. U.fmtMoney(fee) .. ")."
    end
    local wf = F.State(world).welfare[world.household.id]
    if wf and (wf.strikes or 0) >= FD.neglect.inspectAt then return false, "Family Services won't approve an adoption while a neglect case is open." end
    if wf and wf.lastRemovalAt and F.Root(world).time - wf.lastRemovalAt < FD.adoption.blockAfterRemoval then
        return false, "Family Services won't approve an adoption so soon after a child was taken into care."
    end
    for _, p in pairs(F.State(world).pending) do
        if p.hh == world.household.id and p.kind == "adopt" and (p.state == "scheduled" or p.state == "onlot") then return false, "An adoption is already being arranged." end
    end
    if not world.household.lotId then return false, "The household needs a home first." end
    return true
end

function F.Adopt(world, caller, age)
    local ok, why = F.AdoptCheck(world, caller, age)
    if not ok then return false, why end
    local s = F.State(world)
    local id = F.NewId(world, "p")
    local delay = SS.RandomInt(world, "family", FD.adoption.arrive[1], FD.adoption.arrive[2])
    local fee = age == "child" and FD.adoption.childFee or FD.adoption.fee
    local rec = { id = id, kind = "adopt", age = age, hh = world.household.id, lotId = world.household.lotId, caller = caller.id,
        fee = fee, state = "scheduled", t = F.Root(world).time }
    s.pending[id] = rec
    local v = F.RequestVisit(world, "npc_family_services", "adoption", world.household, { pid = id }, delay)
    rec.visit = v.id
    rec.dueAt = v.dueAt
    local what = age == "child" and "a child" or "a baby"
    F.Journal(world, caller.name .. " called Family Services to adopt " .. what .. ".")
    return true, "Family Services will bring " .. what .. " " .. F.DelayText(delay) .. ". The " .. U.fmtMoney(fee) .. " fee is paid at the door."
end

-- The adoption visit: pick a child in care (never one taken from this household) or a new one.
F.visitTasks.adoption = function(world, worker, vrec)
    local s = F.State(world)
    local rec = s.pending[vrec.data.pid]
    if not rec or rec.state ~= "scheduled" then return false, "Nothing to deliver." end
    local root = F.Root(world)
    local hh = root.households[rec.hh]
    if not hh or (hh.flags and hh.flags.ended) then rec.state = "cancelled"; return false, "The household is gone." end
    if rec.rid then rec.state = "done"; return true end
    if (hh.money or 0) < rec.fee then
        rec.state = "cancelled"
        local text = "The adoption was postponed: the household can no longer cover the " .. U.fmtMoney(rec.fee) .. " fee."
        F.Journal(world, text)
        SS.Emit("notice", worker, text)
        return false, text
    end
    local room, rwhy = F.HasRoom(world, hh, "human", 0)
    if not room then
        rec.state = "cancelled"
        local text = "The adoption was cancelled at the door: " .. tostring(rwhy) .. " Nothing was charged."
        F.Journal(world, text)
        SS.Emit("notice", worker, text)
        return false, text
    end
    -- a child already in care first
    local child
    local care = root.households[FD.servicesHousehold.id]
    if care then
        local ids = {}
        for _, rid in ipairs(care.members) do
            local r = root.residents[rid]
            if r and not r.dead and r.age == rec.age and not (r.fam and r.fam.removedFrom == hh.id) then ids[#ids + 1] = rid end
        end
        table.sort(ids)
        if ids[1] then child = root.residents[ids[1]] end
    end
    if child then
        child.name = (child.name:match("^(%S+)") or child.name) .. " " .. F.Surname(world, hh)
        child.away = nil
    else
        child = F.NewPerson(world, { age = rec.age, hh = hh })
    end
    rec.rid = child.id
    rec.state = "done"
    F.MoveResident(world, child.id, hh.id, { reason = "adopted" })
    local parents = {}
    local caller = root.residents[rec.caller]
    if caller and not caller.dead and caller.householdId == hh.id then
        parents[1] = caller.id
        local sp = F.SpouseOf(world, caller.id)
        if sp and root.residents[sp].householdId == hh.id then parents[2] = sp end
    else
        for _, a in ipairs(F.Members(world, hh, F.IsAdult)) do parents[#parents + 1] = a.id; if #parents == 2 then break end end
    end
    F.Fam(child).parents = parents
    F.LinkFamily(world, child, parents, hh)
    F.HouseholdMoney(world, hh, -rec.fee, "family", "Adoption fee")
    rec.charged = rec.fee
    if world.household == hh then
        local oi, oj, ii, ij = F.FrontDoor(world)
        local ni, nj = ii or oi, ij or oj
        if worker then ni, nj = math.floor(worker.x), math.floor(worker.y) end
        F.PlaceOnLot(world, child, ni, nj, {})
    end
    local text = "Family Services brought " .. child.name .. " home. Welcome to the family!"
    F.Journal(world, text)
    SS.Emit("notice", worker, text)
    F.Record(world, "adoption", { rid = child.id, hh = hh.id })
    SS.Emit("familyArrival", world, child, "adoption")
    SS.Emit("familyNaming", world, child)
    return true, text
end
F.visitRefused.adoption = function(world, vrec)
    local rec = F.State(world).pending[vrec.data.pid]
    if rec and rec.state == "scheduled" then rec.state = "cancelled" end
    vrec.state = "cancelled"
    F.Journal(world, "The Family Services caseworker was sent away; the adoption is cancelled.")
end

if SS.Phone and SS.Phone.RegisterCall then
    SS.Phone.RegisterCall({ id = "family_adopt_baby", label = "Adopt a Baby", category = "Family", order = 10,
        test = function(world, caller) return F.AdoptCheck(world, caller, "infant") end,
        run = function(world, caller) return F.Adopt(world, caller, "infant") end })
    SS.Phone.RegisterCall({ id = "family_adopt_child", label = "Adopt a Child", category = "Family", order = 11,
        test = function(world, caller) return F.AdoptCheck(world, caller, "child") end,
        run = function(world, caller) return F.Adopt(world, caller, "child") end })
end

---------------------------------------------------------------------------
-- Children: age-appropriate activities, family interactions, supervision
---------------------------------------------------------------------------
local CD = FD.child
local function childOnly(world, actor)
    if not F.IsChild(actor) then return false, "That's for children." end
    return true
end

I.kid_toybox = {
    label = "Play with Toys", category = "Fun", slot = "front", pose = "play", maxDur = CD.toybox.maxDur,
    rate = { fun = CD.toybox.fun }, untilFull = "fun", ages = { child = true }, kinds = { human = true },
    test = childOnly,
    advertise = function(world, actor) if F.IsChild(actor) then return { fun = 45 } end end,
    onTick = function(world, actor, act, obj, dt)
        -- playing next to another child is also social
        for _, id in ipairs(F.ActorIds(world)) do
            local o = world.actors[id]
            if o ~= actor and F.IsChild(o) and o.act and (o.act.iid == "kid_toybox" or o.act.iid == "kid_play") and F.Dist(o, actor) <= 3 then
                SS.Needs.Add(actor, "social", 12 * dt / 60)
                break
            end
        end
    end,
}
I.kid_play = {
    label = "Play", category = "Fun", slot = "player", pose = "play", maxDur = CD.play.maxDur,
    rate = { fun = CD.play.fun, energy = -3 }, untilFull = "fun", ages = { child = true }, kinds = { human = true },
    test = childOnly,
    advertise = function(world, actor) if F.IsChild(actor) then return { fun = 50 } end end,
}
SS.Tags.Attach("toybox", "kid_toybox")
SS.Tags.Attach("kid_play", "kid_play")

local function adultWithChild(world, actor, target)
    if not F.IsAdult(actor) then return false, "Only a grown-up can do that." end
    if not target or not F.IsChild(target) then return false, "That's for children." end
    if target.sleeping then return false, target.name .. " is asleep." end
    return true
end

I.fam_play_together = {
    label = "Play Together", category = "Family", targetActor = true, pose = "play", dur = CD.playTogether.dur,
    gain = { fun = CD.playTogether.fun, social = CD.playTogether.social }, ages = { adult = true }, kinds = { human = true },
    test = adultWithChild,
    advertise = function(world, actor, target) return { fun = 20, social = 25 } end,
    onStart = function(world, actor, act)
        local t, why = F.TargetInReach(world, actor, act)
        if not t then return false, why end
        F.Engage(world, t, actor, "play", CD.playTogether.dur + 4)
    end,
    onTick = function(world, actor, act, _, dt)
        local t = world.actors[act.tid]
        F.TickGain(world, act, t, { fun = CD.playTogether.fun, social = CD.playTogether.social }, CD.playTogether.dur, dt)
    end,
    onEnd = function(world, actor, act, _, status)
        if status ~= "done" or not F.Exists(world, act.tid) then return end
        -- free will waits a while before offering the next session (the cool-down the candidate
        -- provider checks)
        F.SetCool(world, "play:" .. actor.id, CD.playTogether.cooldown or 180)
        F.Change(world, actor.id, act.tid, CD.playTogether.rel, 1)
        F.Change(world, act.tid, actor.id, CD.playTogether.rel, 1)
    end,
}

function F.TuckInCheck(world, actor, target)
    if not F.IsAdult(actor) then return false, "Only a grown-up can tuck someone in." end
    if not target or not F.IsChild(target) then return false, "Only children get tucked in." end
    local m = world.time % 1440
    local tired = (target.needs.energy or 0) < 20
    if not tired and (m < CD.tuckIn.from or m > CD.tuckIn.to) then return false, "It isn't bedtime (7 PM to 11 PM)." end
    if target.tmp and target.tmp.tuckedDay == math.floor(world.time / 1440) then return false, target.name .. " has already been tucked in tonight." end
    return true
end

I.fam_tuck_in = {
    label = "Tuck In", category = "Family", targetActor = true, pose = "hug", dur = CD.tuckIn.dur, manualOnly = false,
    gain = { social = 8 }, ages = { adult = true }, kinds = { human = true },
    test = F.TuckInCheck,
    advertise = function(world, actor, target) return { social = 20 } end,
    onStart = function(world, actor, act)
        local t, why = F.TargetInReach(world, actor, act)
        if not t then return false, why end
    end,
    onTick = function(world, actor, act, _, dt)
        local t = world.actors[act.tid]
        F.TickGain(world, act, t, { social = CD.tuckIn.social, comfort = CD.tuckIn.comfort }, CD.tuckIn.dur, dt)
    end,
    onEnd = function(world, actor, act, _, status)
        if status ~= "done" then return end
        local t = world.actors[act.tid]
        if not t then return end
        t.tmp = t.tmp or {}
        t.tmp.tuckedDay = math.floor(world.time / 1440)
        F.Change(world, actor.id, t.id, CD.tuckIn.rel, 1)
        F.Change(world, t.id, actor.id, CD.tuckIn.rel, 1)
    end,
}

-- A tucked-in child sleeps a little better that night.
SS.Needs.RegisterRateHook(function(world, actor, need, rate)
    if need == "energy" and actor.sleeping and actor.tmp and actor.tmp.tuckedDay and F.IsChild(actor) then
        local d = math.floor(world.time / 1440)
        if actor.tmp.tuckedDay == d or actor.tmp.tuckedDay == d - 1 then return rate + CD.tuckIn.sleepBonus end
    end
    return rate
end)

-- Free will tucks a child in at bedtime only (7 PM to 11 PM). A tired child earlier in the day can
-- still be tucked in by order (F.TuckInCheck). Before fix round 1 free will also went after a child
-- who was merely tired, at any hour: in household-core's A17 day in the merged tree a parent set
-- off at 6:43 PM and the tuck-in failed because the child had walked off to bed meanwhile.
function F.TuckInHour(world)
    local m = world.time % 1440
    return m >= CD.tuckIn.from and m <= CD.tuckIn.to
end

-- Autonomy: adults sometimes play with or tuck in a child (same executor, suitability via test).
SS.Actions.RegisterCandidates(function(world, actor, cands)
    if not F.IsAdult(actor) or actor.role or not F.IsMember(world, actor) then return end
    local bedtime = F.TuckInHour(world)
    for _, id in ipairs(F.ActorIds(world)) do
        local c = world.actors[id]
        if F.IsChild(c) and c.householdId == actor.householdId then
            local ok = bedtime and not F.AutoCooling(world, actor, c.id, "fam_tuck_in") and SS.Actions.Available(world, actor, c, "fam_tuck_in")
            if ok then
                cands[#cands + 1] = { tid = c.id, iid = "fam_tuck_in", s = 26 }
            elseif not F.Cooling(world, "play:" .. actor.id) then
                -- Play Together: not straight after the last session, and only while the pair's
                -- fun is below full
                local urg = ((100 - (actor.needs.fun or 0)) / 200) + ((100 - (c.needs.fun or 0)) / 200)
                local s = 8 + 18 * urg + ((actor.personality and actor.personality.playful) or 5)
                if urg >= (CD.playTogether.minUrgency or 0) and s > 12 and not F.AutoCooling(world, actor, c.id, "fam_play_together")
                    and SS.Actions.Available(world, actor, c, "fam_play_together") then
                    cands[#cands + 1] = { tid = c.id, iid = "fam_play_together", s = s }
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Neglect monitoring and protective services (infants and children)
---------------------------------------------------------------------------
local ND = FD.neglect

function F.Welfare(world, hhId)
    local s = F.State(world)
    local wf = s.welfare[hhId]
    if not wf then wf = { strikes = 0, warnings = 0, log = {} }; s.welfare[hhId] = wf end
    wf.log = wf.log or {}
    return wf
end

-- Is any living adult listed in the household (on the lot or not)? Allocation-free.
function F.HasAdultMember(world, hh)
    local root = F.Root(world)
    hh = F.Household(world, hh)
    for _, rid in ipairs(hh and hh.members or {}) do
        local r = root.residents[rid]
        if r and F.Alive(r) and F.IsAdult(r) then return true end
    end
    return false
end

function F.AdultPresent(world, hh)
    hh = F.Household(world, hh)
    for _, id in ipairs(F.ActorIds(world)) do
        local a = world.actors[id]
        if a and F.IsAdult(a) and a.householdId == hh.id and not a.dead and not F.IsNpc(a) then return a end
    end
end

-- Would these residents leaving the lot strand an infant (or a child at night) without an adult?
-- Other modules (careers carpool, outings taxi) call this before taking people away.
function F.CanLeave(world, rids)
    local hh = world.household
    if not hh then return true end
    local leaving = {}
    for _, r in ipairs(rids or {}) do leaving[type(r) == "table" and r.id or r] = true end
    local adultStays = false
    local infant, child
    for _, id in ipairs(F.ActorIds(world)) do
        local a = world.actors[id]
        if a.householdId == hh.id and not leaving[id] then
            if F.IsAdult(a) and not F.IsNpc(a) then adultStays = true end
            if F.IsInfant(a) then infant = a end
            if F.IsChild(a) then child = a end
        end
    end
    if adultStays then return true end
    if infant then return false, "Someone has to stay home with " .. infant.name .. "." end
    local h = (world.time % 1440) / 60
    if child and (h >= 22 or h < 6) then return false, child.name .. " can't be left home alone at night." end
    return true
end

-- Someone outside the family is worried about a child (the school, careers' request F1): Family
-- Services visits to check. A concern is not documented neglect. The visit finds the home in order
-- (nothing more happens) or the child still in need (one strike, and the usual ladder from there).
-- Returns true when the concern was taken up.
function F.WelfareConcern(world, child, source, info)
    local root = F.Root(world)
    if type(child) == "string" then child = root.residents[child] end
    if type(child) ~= "table" or child.dead or not F.IsDependent(child) then return false end
    local hh = child.householdId and root.households[child.householdId]
    if not hh or F.IsServiceHousehold(hh) or (hh.flags and hh.flags.ended) then return false end
    local why = type(info) == "table" and info.why or nil
    local who = source == "school" and "The school" or "Someone"
    F.Journal(world, who .. " asked Family Services to check on " .. child.name .. (why and (" (" .. tostring(why) .. ")") or "") .. ".")
    SS.Emit("welfareConcern", world, hh, child, source, why)
    if not F.VisitPending(world, "inspect", hh.id) and not F.VisitPending(world, "removal", hh.id) then
        F.RequestVisit(world, "npc_family_services", "inspect", hh, { rid = child.id, concern = source or "concern", why = why }, ND.inspectDelay)
    end
    return true
end

-- Record a documented neglect incident; escalate to an inspection or a removal.
function F.AddStrike(world, hh, dep, reason)
    local root = F.Root(world)
    hh = F.Household(world, hh)
    local wf = F.Welfare(world, hh.id)
    wf.strikes = (wf.strikes or 0) + 1
    wf.lastStrikeAt = root.time
    wf.log[#wf.log + 1] = { t = root.time, rid = dep.id, reason = reason }
    while #wf.log > 10 do table.remove(wf.log, 1) end
    local text = "Neglect reported: " .. dep.name .. " " .. reason .. ". Family Services has been notified (" .. wf.strikes .. " on file)."
    F.Journal(world, text)
    if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "warning") end
    F.Record(world, "neglect", { rid = dep.id, hh = hh.id, reason = reason, strikes = wf.strikes })
    SS.Emit("neglectReported", world, dep, reason, wf.strikes)
    if wf.strikes >= ND.removeAt then
        if not F.VisitPending(world, "removal", hh.id, function(v) return v.data.rid == dep.id end) then
            F.RequestVisit(world, "npc_family_services", "removal", hh, { rid = dep.id }, ND.removeDelay)
        end
    elseif wf.strikes >= ND.inspectAt then
        if not F.VisitPending(world, "inspect", hh.id) then
            F.RequestVisit(world, "npc_family_services", "inspect", hh, { rid = dep.id }, ND.inspectDelay)
        end
    end
    return wf.strikes
end

local INFANT_KEYS, CHILD_KEYS = { "hunger", "hygiene", "energy", "social", "fun" }, { "hunger", "hygiene", "energy" }
local function worstNeed(dep)
    local keys = F.IsInfant(dep) and INFANT_KEYS or CHILD_KEYS
    local wk, wv
    for _, k in ipairs(keys) do
        local v = dep.needs[k] or 0
        if not wv or v < wv then wk, wv = k, v end
    end
    return wk, wv
end
F.WorstNeed = worstNeed

local NEED_TEXT = { hunger = "was left hungry", hygiene = "was left unwashed", energy = "was left exhausted",
    social = "was left alone and crying", fun = "was left bored and crying" }

-- Called every sim minute (from the family system tick): warnings, documented neglect, supervision.
function F.MonitorDependents(world, dt)
    local hh = world.household
    if not hh or F.IsServiceHousehold(hh) then return end
    local adult = F.AdultPresent(world, hh)
    local anyAdultMember = F.HasAdultMember(world, hh)
    local h = (world.time % 1440) / 60
    for _, id in ipairs(F.ActorIds(world)) do
        local dep = world.actors[id]
        if dep and F.IsDependent(dep) and dep.householdId == hh.id and not dep.dead then
            local c = F.Fam(dep)
            c.neglect = c.neglect or { min = 0, alone = 0, warn = {} }
            local ng = c.neglect
            ng.warn = ng.warn or {}
            local wk, wv = worstNeed(dep)
            -- warnings first
            if wv <= ND.warnAt and (ng.warn[wk] or -1e9) + ND.warnCooldown <= world.time then
                ng.warn[wk] = world.time
                local who = adult or dep
                SS.Actions.Message(world, who, dep.name .. " needs care: " .. SS.Tuning.needLabel[wk] .. " is very low.", wk)
                SS.Emit("neglectWarning", world, dep, wk)
            end
            local critical = F.IsInfant(dep) and ND.criticalInfant or ND.criticalChild
            if wv <= critical then ng.min = (ng.min or 0) + dt else ng.min = math.max(0, (ng.min or 0) - dt * 0.5) end
            -- supervision: an infant needs an adult on the lot; a child at night too
            local alone = false
            if anyAdultMember and not adult then
                if F.IsInfant(dep) then alone = true
                elseif h >= 22 or h < 6 then alone = true end
            end
            if alone then
                if (ng.alone or 0) == 0 then
                    SS.Actions.Message(world, dep, dep.name .. " has been left without a grown-up.", "social")
                    SS.Emit("neglectWarning", world, dep, "alone")
                end
                ng.alone = (ng.alone or 0) + dt
            else
                ng.alone = 0
            end
            local strikeReady = (ng.lastStrike or -1e9) + ND.strikeCooldown <= world.time
            if strikeReady and ng.min >= ND.strikeAfter then
                ng.min, ng.lastStrike = 0, world.time
                F.AddStrike(world, hh, dep, NEED_TEXT[wk] or "was neglected")
            elseif strikeReady and ng.alone >= (F.IsInfant(dep) and ND.aloneInfantStrike or ND.aloneChildNight) then
                ng.alone, ng.lastStrike = 0, world.time
                F.AddStrike(world, hh, dep, "was left home without a grown-up")
            end
        end
    end
end

-- Left without a grown-up in a way the supervision rules don't allow (F.CanLeave): an infant at
-- any hour, a child at night.
local function unsupervised(world, dep)
    if F.IsInfant(dep) then return true end
    local h = (F.Root(world).time % 1440) / 60
    return F.IsChild(dep) and (h >= 22 or h < 6)
end

F.visitTasks.inspect = function(world, worker, vrec)
    local root = F.Root(world)
    local hh = root.households[vrec.hh]
    if not hh then return false end
    local dep = root.residents[vrec.data.rid]
    local wf = F.Welfare(world, hh.id)
    -- a visit that follows someone's concern (the school's), not documented neglect
    local concern = vrec.data.concern
    local bad
    if dep and not dep.dead and dep.householdId == hh.id then
        local _, wv = worstNeed(dep)
        if wv <= ND.okAtInspection then bad = dep.name .. " still needed care during the visit" end
        if world.household == hh and not F.AdultPresent(world, hh) and (not concern or unsupervised(world, dep)) then bad = "nobody grown-up was home" end
    end
    if bad then
        local text = "Family Services inspected the home: " .. bad .. "."
        F.Journal(world, text)
        if concern then
            F.AddStrike(world, hh, dep, "still needed care when Family Services checked after " .. (concern == "school" and "the school's" or "a") .. " concern")
        else
            wf.strikes = math.max(wf.strikes or 0, ND.removeAt - 1)
            F.AddStrike(world, hh, dep, "was still neglected at the inspection")
        end
        return true, text
    end
    if concern then
        local text = "Family Services checked on " .. (dep and dep.name or "the children") .. " after "
            .. (concern == "school" and "the school's" or "a") .. " concern and found the home in order."
        F.Journal(world, text)
        if worker then SS.Actions.Message(world, worker, text, "social") end
        return true, text
    end
    wf.warnings = (wf.warnings or 0) + 1
    local text = "Family Services inspected the home and left a formal written warning."
    F.Journal(world, text)
    if worker then SS.Actions.Message(world, worker, text, "social") end
    return true, text
end
F.visitRefused.inspect = function(world, vrec)
    vrec.state = "cancelled"
    local root = F.Root(world)
    local hh = root.households[vrec.hh]
    local dep = root.residents[vrec.data.rid]
    if hh and dep then F.AddStrike(world, hh, dep, "was kept from the caseworker at the door") end
end

F.visitTasks.removal = function(world, worker, vrec)
    local root = F.Root(world)
    local hh = root.households[vrec.hh]
    local dep = root.residents[vrec.data.rid]
    if not hh or not dep or dep.dead or dep.householdId ~= hh.id then return false, "Nobody to collect." end
    F.TakeIntoCare(world, dep.id, "neglect")
    local wf = F.Welfare(world, hh.id)
    wf.strikes = 0
    wf.lastRemovalAt = root.time
    wf.removed = wf.removed or {}
    wf.removed[#wf.removed + 1] = dep.id
    while #wf.removed > 8 do table.remove(wf.removed, 1) end
    for _, a in ipairs(F.Members(world, hh, F.IsAdult)) do
        F.Change(world, a.id, dep.id, -20, -5)
        SS.Needs.Add(a, "social", -30)
    end
    local text = "After repeated neglect, Family Services took " .. dep.name .. " into care."
    F.Journal(world, text)
    if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "warning") end
    F.Record(world, "removal", { rid = dep.id, hh = hh.id })
    SS.Emit("dependentRemoved", world, dep, hh)
    return true, text
end
F.visitRefused.removal = function(world, vrec)
    -- a removal is not optional: the caseworker returns (bounded), then the office carries it out
    vrec.state = "cancelled"
    local hh = F.Root(world).households[vrec.hh]
    if not hh then return end
    local data = U.deepcopy(vrec.data or {})
    data.returns = (data.returns or 0) + 1
    if data.returns > FD.visit.removalReturns then
        F.visitTasks.removal(world, nil, { hh = vrec.hh, data = data })
    else
        F.RequestVisit(world, "npc_family_services", "removal", hh, data, 60)
    end
end

---------------------------------------------------------------------------
-- The last adult is lost (A39): guardian or Family Services, then a valid continuation
---------------------------------------------------------------------------
local GD = FD.guardian

local RELATIVE = { parent = true, child = true, sibling = true, spouse = true, guardian = true, grandparent = true, aunt = true, uncle = true, cousin = true }

function F.FindGuardian(world, hh, deps, formerAdults)
    local root = F.Root(world)
    local best, bestScore
    local ids = {}
    for rid in pairs(root.residents) do ids[#ids + 1] = rid end
    table.sort(ids)
    for _, rid in ipairs(ids) do
        local r = root.residents[rid]
        local ok = r and F.Alive(r) and F.IsAdult(r) and not F.IsNpc(r) and r.householdId ~= hh.id
            and not F.IsServiceHousehold(r.householdId) and not (r.away and r.away.reason == "dead")
        if ok and wouldStrand(world, r) then ok = false end
        if ok and r.householdId then
            local other = root.households[r.householdId]
            if other and other.flags and other.flags.ended then ok = false end
        end
        if ok then
            local score, relative = 0, false
            for _, d in ipairs(deps) do
                local rel = F.PeekRel(world, rid, d.id)
                if rel.flags.family and RELATIVE[rel.flags.family] then relative = true end
                score = score + rel.life
            end
            for _, fa in ipairs(formerAdults or {}) do
                local rel = F.PeekRel(world, rid, fa)
                if rel.flags.family and RELATIVE[rel.flags.family] then relative = true end
                score = score + rel.life * 0.5
            end
            local avg = score / math.max(1, #deps)
            local eligible = relative or avg >= GD.friendMinLife
            if eligible then
                local s = (relative and 1000 or 0) + score
                if not bestScore or s > bestScore then best, bestScore = r, s end
            end
        end
    end
    return best
end

local function splitHousehold(world, hh)
    local adults, deps, pets = {}, {}, {}
    for _, r in ipairs(F.Members(world, hh)) do
        if F.IsPet(r) then pets[#pets + 1] = r
        elseif F.IsAdult(r) then adults[#adults + 1] = r
        else deps[#deps + 1] = r end
    end
    return adults, deps, pets
end
F.Split = splitHousehold

function F.AssignGuardian(world, hh, g, deps, case)
    local root = F.Root(world)
    if g.role then
        if SS.Visitors and SS.Visitors.Release then SS.Visitors.Release(world, g) end
        g.role, g.roleData, g.noNeeds = nil, nil, nil
    end
    F.MoveResident(world, g.id, hh.id, { money = FD.moveInMoney, reason = g.name .. " became a guardian" })
    for _, d in ipairs(deps) do
        local cur = F.Rel(world, g.id, d.id).flags.family
        if not cur or not RELATIVE[cur] or cur == "sibling" then SS.Social.SetFamily(world, g.id, d.id, "guardian") end
        F.Rel(world, g.id, d.id).flags.guardian = true
        F.Change(world, g.id, d.id, 10, 5)
    end
    for _, p in ipairs(F.Members(world, hh, F.IsPet)) do if p.pet then p.pet.owner = g.id end end
    if world.household == hh and not world.actors[g.id] then
        g.away = nil
        local ei, ej = SS.Street.EntryCell(world)
        if SS.Street.Arrive then SS.Street.Arrive(world, g.id) else SS.Sim.AddActor(world, g.id, ei, ej, 0) end
        if not world.actors[g.id] then SS.Sim.AddActor(world, g.id, ei, ej, 0) end
    end
    case.state, case.guardian = "resolved", g.id
    local names = {}
    for _, d in ipairs(deps) do names[#names + 1] = d.name end
    local text = g.name .. " has come to look after " .. table.concat(names, " and ") .. "."
    F.Journal(world, text)
    if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "info") end
    F.Resolve(world, case.event, "guardian")
    SS.Emit("guardianAssigned", world, hh, g)
    return true, text
end

-- Entry point (events calls this when the last adult dies; family also checks every hour and on
-- the death event, so a leaving adult triggers it too). Idempotent while a case is open.
function F.OnGuardianLost(world, household)
    local root = F.Root(world)
    local hh = F.Household(world, household)
    if not hh or F.IsServiceHousehold(hh) or (hh.flags and hh.flags.ended) then return false, "no household" end
    hh.flags = hh.flags or {}
    local adults, deps, pets = splitHousehold(world, hh)
    if #adults > 0 then return false, "adults remain" end
    local s = F.State(world)
    local open = hh.flags.guardianCase and s.cases[hh.flags.guardianCase]
    if open and (open.state == "search" or open.state == "welfare") then return true, open end
    local case = { id = F.NewId(world, "c"), hh = hh.id, t = root.time, state = "search", deps = {}, pets = {} }
    for _, d in ipairs(deps) do case.deps[#case.deps + 1] = d.id end
    for _, p in ipairs(pets) do case.pets[#case.pets + 1] = p.id end
    s.cases[case.id] = case
    hh.flags.guardianCase = case.id
    -- former adults: dead or departed members recorded on the household
    local former = {}
    for _, rid in ipairs(hh.members) do
        local r = root.residents[rid]
        if r and r.dead and F.IsAdult(r) then former[#former + 1] = rid end
    end
    local ev = F.Record(world, "guardian_lost", { hh = hh.id, deps = case.deps })
    case.event = type(ev) == "table" and ev.id or ev
    SS.Emit("guardianLost", world, hh)
    if #deps == 0 then
        -- only pets (or nobody) left: the case closes at once, and so does its record (events FA-4)
        case.state = "closed"
        F.Resolve(world, case.event, "ended")
        F.EndHousehold(world, hh, "nobody is left to look after the house")
        return true, case
    end
    local g = F.FindGuardian(world, hh, deps, former)
    if g then
        F.AssignGuardian(world, hh, g, deps, case)
        return true, case
    end
    case.state = "welfare"
    local names = {}
    for _, d in ipairs(deps) do names[#names + 1] = d.name end
    local text = "Nobody is left to look after " .. table.concat(names, " and ") .. ". Family Services is on the way."
    F.Journal(world, text)
    if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "warning") end
    SS.Emit("notice", nil, text)
    local v = F.RequestVisit(world, "npc_family_services", "guardian", hh, { case = case.id }, GD.pickupDelay)
    case.visit = v.id
    SS.Sim.Schedule(world, root.time + GD.fallbackAfter, "family.case_fallback", { case = case.id }, hh.lotId or world.lot.id)
    return true, case
end

local function closeCaseWithCare(world, case)
    local root = F.Root(world)
    local hh = root.households[case.hh]
    if case.state == "closed" then return end
    if not hh or (hh.flags and hh.flags.ended) then
        -- the household was ended (or deleted) some other way meanwhile: nothing left to settle
        case.state = "closed"
        F.Resolve(world, case.event, "ended")
        return "ended"
    end
    local adults, deps = splitHousehold(world, hh)
    if #adults > 0 then
        -- someone became available since (a relative or partner moved in): no removal
        case.state = "resolved"
        F.Resolve(world, case.event, "guardian")
        return "adult"
    end
    local names = {}
    for _, d in ipairs(deps) do
        names[#names + 1] = d.name
        F.TakeIntoCare(world, d.id, "no guardian")
    end
    case.state = "closed"
    F.Resolve(world, case.event, "care")
    local text = "Family Services took " .. (#names > 0 and table.concat(names, " and ") or "the household's dependents") .. " into care"
    F.EndHousehold(world, hh, text .. ".")
    return "care"
end

F.visitTasks.guardian = function(world, worker, vrec)
    local case = F.State(world).cases[vrec.data.case]
    if not case or case.state ~= "welfare" then return false, "Case already settled." end
    if closeCaseWithCare(world, case) == "adult" then return true, "An adult is home now." end
    return true
end
F.visitRefused.guardian = function(world, vrec)
    vrec.state = "cancelled"
    local case = F.State(world).cases[vrec.data.case]
    if case and case.state == "welfare" then closeCaseWithCare(world, case) end
end

function F.CaseFallback(world, cid)
    local case = F.State(world).cases[cid]
    if case and case.state == "welfare" then
        -- the visit never completed (no route, no spawn): settle it without a visitor
        closeCaseWithCare(world, case)
    end
end

function F.CheckGuardian(world)
    local hh = world.household
    if not hh or F.IsServiceHousehold(hh) or (hh.flags and hh.flags.ended) then return end
    local adults, deps, pets = splitHousehold(world, hh)
    -- called through the table: another module (or a test) may wrap or remove the entry point
    local fn = F.OnGuardianLost
    if #adults == 0 and (#deps > 0 or #pets > 0) and type(fn) == "function" then fn(world, hh) end
end

SS.On("death", function(world, actor, cause)
    if not world or not world.household or not actor or actor.householdId ~= world.household.id then return end
    if F.IsAdult(actor) then F.CheckGuardian(world) end
end)

---------------------------------------------------------------------------
-- System registration, validators
---------------------------------------------------------------------------
local acc = 0
SS.Sim.Register({
    name = "family", order = 40,
    attach = function(world)
        F.PrepareDefs()
        F.InstallEnv()
        acc = 0
        local s = F.State(world)
        -- visits: resume, or reschedule when the worker is no longer on this lot; never lose one
        local have = {}
        for _, ev in ipairs(world.scheduled) do if ev.kind == "family.visit" then have[ev.data.vid] = true end end
        local ids = {}
        for id in pairs(s.visits) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local rec = s.visits[id]
            if rec.lotId == world.lot.id then
                if rec.state == "onlot" then
                    local a = world.actors[rec.rid]
                    if not a or a.role ~= rec.role then
                        rec.state = "scheduled"
                        rec.dueAt = world.time + 30
                        SS.Sim.Schedule(world, rec.dueAt, "family.visit", { vid = id }, rec.lotId)
                    else
                        a.roleData = a.roleData or {}
                        a.roleData.visit = id
                        if a.roleData.stage == "perform" then a.roleData.performAt = world.time + FD.visit.performDur end
                        a.roleData.since = world.time
                    end
                elseif rec.state == "scheduled" and not have[id] then
                    SS.Sim.Schedule(world, math.max(rec.dueAt, world.time), "family.visit", { vid = id }, rec.lotId)
                end
            end
        end
        -- NPC workers left on the lot without an open visit go home
        for _, id in ipairs(F.ActorIds(world)) do
            local a = world.actors[id]
            if a.roleData and a.roleData.visit and FD.npcs[id] then
                local rec = s.visits[a.roleData.visit]
                if not rec or rec.state ~= "onlot" then SS.Visitors.Leave(world, a, "done") end
            end
        end
        -- pending babies whose due event was lost
        for pid, p in pairs(s.pending) do
            if p.kind == "baby" and p.state == "scheduled" and p.lotId == world.lot.id then
                local found = false
                for _, ev in ipairs(world.scheduled) do if ev.kind == "family.baby_due" and ev.data.pid == pid then found = true end end
                if not found then SS.Sim.Schedule(world, math.max(p.dueAt, world.time), "family.baby_due", { pid = pid }, p.lotId) end
            end
        end
    end,
    tick = function(world, dt)
        acc = acc + dt
        if acc >= 1 then
            local step = acc
            acc = 0
            F.MonitorDependents(world, step)
        end
    end,
    hour = function(world, h)
        F.CheckGuardian(world)
    end,
    day = function(world, d)
        local s = F.State(world)
        local now = F.Root(world).time
        for key, t in pairs(s.cool) do if t <= now then s.cool[key] = nil end end
        for hhId, wf in pairs(s.welfare) do
            if (wf.strikes or 0) > 0 and wf.lastStrikeAt and now - wf.lastStrikeAt >= ND.forgiveAfter
                and not F.VisitPending(world, "inspect", hhId) and not F.VisitPending(world, "removal", hhId) then
                wf.strikes = wf.strikes - 1
                wf.lastStrikeAt = now
            end
        end
        -- bounded: finished pending records and closed cases older than a week go
        for id, p in pairs(s.pending) do
            if p.state ~= "scheduled" and p.state ~= "onlot" and now - (p.t or 0) > 7 * 1440 then s.pending[id] = nil end
        end
        for id, c in pairs(s.cases) do
            if (c.state == "closed" or c.state == "resolved") and now - (c.t or 0) > 14 * 1440 then s.cases[id] = nil end
        end
    end,
})

SS.On("worldAttached", function() F.PrepareDefs() end)

SS.Save.RegisterValidator(function(root, problems)
    if root.family ~= nil and type(root.family) ~= "table" then root.family = nil; problems[#problems + 1] = "family data reset" end
    local s = F.State(root)
    for _, k in ipairs({ "pending", "visits", "welfare", "cases", "cool" }) do
        if type(s[k]) ~= "table" then s[k] = {}; problems[#problems + 1] = "family " .. k .. " reset" end
    end
    for _, id in ipairs(F.SortedIds(s.pending)) do
        local p = s.pending[id]
        if type(p) ~= "table" or not root.households[p.hh or ""] then s.pending[id] = nil; problems[#problems + 1] = "dropped a pending arrival for a missing household"
        elseif p.rid and not root.residents[p.rid] then p.state = "done" end
    end
    for id, v in pairs(s.visits) do
        if type(v) ~= "table" or not FD.npcs[v.rid or ""] then s.visits[id] = nil end
    end
    for _, r in pairs(root.residents) do
        if type(r) == "table" and r.fam ~= nil and type(r.fam) ~= "table" then r.fam = nil end
        if type(r) == "table" and r.fam then
            if r.fam.spouse and not root.residents[r.fam.spouse] then r.fam.spouse = nil end
            if r.fam.engaged and not root.residents[r.fam.engaged] then r.fam.engaged = nil end
        end
    end
    -- the special households stay lot-less and flagged
    for _, spec in ipairs({ FD.servicesHousehold, FD.shelterHousehold }) do
        local hh = root.households[spec.id]
        if hh then hh.flags = type(hh.flags) == "table" and hh.flags or {}; hh.flags.service = true; hh.lotId = nil end
    end
    -- No resident is listed by two households: a listed resident stays only where their householdId
    -- points; one whose householdId is missing (or names no household) belongs to the first
    -- household, in id order, that lists them, and householdId is set to it. (Residents listed
    -- nowhere are left alone: the dead are taken off the members list and keep their householdId.)
    local function validHh(hid) return hid ~= nil and type(root.households[hid]) == "table" end
    for _, id in ipairs(F.SortedIds(root.households)) do
        local hh = root.households[id]
        if type(hh) == "table" and type(hh.members) == "table" then
            local keep, seen = {}, {}
            for _, rid in ipairs(hh.members) do
                local r = root.residents[rid]
                if type(r) == "table" and not seen[rid] then
                    if not validHh(r.householdId) then
                        problems[#problems + 1] = "family: " .. tostring(rid) .. " had no household; kept in " .. tostring(id)
                        r.householdId = id
                    end
                    if r.householdId == id then keep[#keep + 1] = rid; seen[rid] = true end
                end
            end
            if #keep ~= #hh.members then problems[#problems + 1] = "family: fixed duplicated household membership in " .. tostring(id) end
            hh.members = keep
        end
    end
    return true
end)
