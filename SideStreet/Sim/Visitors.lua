-- SideStreet visitors: the roles framework (arrival, door, greeting, permissions, departure, save/load
-- reconciliation) and the visitor kinds built on it (walk-bys, welcome visits, invited friends,
-- spontaneous social calls, the paper carrier and the mail carrier). Services (Sim/Services.lua) and
-- other modules' roles (collector, firefighter, police, burglar, death visitor, child welfare, party
-- guests, venue staff) run on the same framework. Owner: visitors module. Full reference:
-- docs/modules/visitors.md.
--
-- A role actor is a person record (root.residents) on the lot with actor.role = name and
-- actor.roleData = { <caller data>..., vs = <framework state> }. Framework states:
--   arriving  off the lot: riding in, stepping out at the curb, walking the sidewalk to the entry cell
--   approach  on the lot: routing to the front door (bounded attempts)
--   door      at the door: rang or knocked, waiting to be greeted (bounded wait)
--   visit     let in: executor autonomy with guest permissions (role.useAutonomy)
--   task      the role's own tick drives them (services, emergency roles, staff)
--   leaving   routing back to the entry, then walking off to their vehicle or along the sidewalk
--   passing   walking along the sidewalk only (walk-bys, paper carrier)
-- Pathfinding is never retried endlessly: every goal gets tuning.routeRetries attempts with a
-- cooldown, then the visitor gives up with an explanation (A35).
-- Visits never run on a lot nobody simulates: leaving a lot for another household's ends them as
-- of that lot's last simulated minute (V.EndLotVisits, from V.Attach). Roles other modules put
-- straight into SS.Roles, and resident roles (`resident = true` in SS.Roles or in this registry:
-- family's pets and infants), are never run, restricted, listed, sent home or cleared (V.Owns,
-- V.Resident).
local _, SS = ...
local RD = SS.RoleData
local TUN = RD.tuning
local W, G, U = SS.World, SS.Grid, SS.U
local St = SS.Street
local V = SS.Visitors or {}
SS.Visitors = V
V.roles = V.roles or {}
V.stats = { searches = 0, routeFails = 0, spawns = 0, removed = 0, helps = 0, deferred = 0, lines = {}, walkbys = 0 }
V.bathOcc = { [0] = {}, [1] = {} }

local function hourOf(t) return math.floor(t / 60) % 24 end
local function clockText(t)
    local m = math.floor(t % 1440)
    local h, mm = math.floor(m / 60), m % 60
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d %s", h12, mm, h < 12 and "AM" or "PM")
end
V.ClockText = clockText

local function sortedIds(t)
    local ids = {}
    for k in pairs(t) do ids[#ids + 1] = k end
    table.sort(ids)
    return ids
end
V.SortedIds = sortedIds

-- Saved state: root.visitors = { requests = { [id] = req }, nextReq, cool = {...}, lastUsed = {...},
-- perLot = { [lotId] = { paperDay, mailDay } }, history = { bounded } }
function V.State(world)
    local root = world.root or world
    local s = root.visitors
    if type(s) ~= "table" then s = {}; root.visitors = s end
    s.requests = s.requests or {}
    s.nextReq = s.nextReq or 1
    s.cool = s.cool or {}
    s.lastUsed = s.lastUsed or {}
    s.perLot = s.perLot or {}
    s.history = s.history or {}
    s.timers = s.timers or {}
    return s
end

-- Timers on a lot's clock. The core scheduler (SS.Sim.Schedule) moves world.time forward to an
-- event's minute inside a step, which shifts the clock; visitor timers run from the visitors system
-- tick instead (never earlier than `at`, at most one sub-step later) and are saved in
-- root.visitors.timers. V.After(world, at, kind, data[, lotId]) -> timer | nil, why; handlers in
-- V.timerHandlers[kind]. Bounded: ambient kinds (walk-bys, the paper, the mail) are refused once
-- tuning.timerCap timers wait; required ones (arrivals, returns) evict the latest ambient timer or
-- use the headroom up to tuning.timerHardCap, and past that fail with a reason the caller handles.
V.timerHandlers = V.timerHandlers or {}
V.AMBIENT_TIMERS = { ["visitors.walkby"] = true, ["visitors.paper"] = true, ["visitors.mail"] = true }
function V.After(world, at, kind, data, lotId)
    local s = V.State(world)
    local list = s.timers
    if #list >= TUN.timerCap then
        if V.AMBIENT_TIMERS[kind] then return nil, "Too much is already scheduled; this can wait." end
        for n = #list, 1, -1 do
            if V.AMBIENT_TIMERS[list[n].kind] then table.remove(list, n); break end
        end
        if #list >= TUN.timerHardCap then
            SS.Log("visitors: timer queue full (%d); refused %s", #list, tostring(kind))
            return nil, "Too many visits are already arranged. Try again later."
        end
    end
    local ev = { at = at, kind = kind, data = data or {}, lotId = lotId or world.lot.id }
    local n = #list
    while n >= 1 and list[n].at > at do n = n - 1 end
    table.insert(list, n + 1, ev)
    return ev
end
function V.CancelTimers(world, pred)
    local list = V.State(world).timers
    local removed = 0
    for n = #list, 1, -1 do if pred(list[n]) then table.remove(list, n); removed = removed + 1 end end
    return removed
end
function V.RunTimers(world)
    local list = V.State(world).timers
    local n, guard = 1, 0
    while list[n] and list[n].at <= world.time and guard < 64 do
        local ev = list[n]
        if ev.lotId == nil or ev.lotId == world.lot.id then
            table.remove(list, n)
            guard = guard + 1
            local h = V.timerHandlers[ev.kind]
            if h then h(world, ev) end
        else
            n = n + 1
        end
    end
end

local function perLot(world, lotId)
    local s = V.State(world)
    lotId = lotId or world.lot.id
    local p = s.perLot[lotId]
    if not p then p = {}; s.perLot[lotId] = p end
    return p
end
V.PerLot = perLot

-- Authored narration/flavour text (RD.text): V.Text("mealNowhere"), V.Text("news", n).
function V.Text(key, n)
    local t = RD.text and RD.text[key]
    if type(t) == "table" and n then return t[n] end
    return t
end

---------------------------------------------------------------------------------------------------
-- Role registry
--   SS.Visitors.RegisterRole(name, def)   def fields (all optional except label):
--     label, access ("public"|"guest"|"service"|"household"|"intruder"|"emergency"|"staff"),
--     class (cap group; default from access), arrive ("door"|"door_enter"|"direct"|"sidewalk"|"none"),
--     vehicle (kind), livery, pool (NPC identity pool), outfit (uniform style), useAutonomy, noNeeds,
--     timeout (minutes on the lot), doorWait (minutes), important (slow the game on arrival),
--     tick(world, actor, dt)            runs in the "task" state (and alongside "visit")
--     onArrive(world, actor)            stepped onto the lot
--     onDoor(world, actor)              reached the front door
--     onGreet(world, actor, member, how), onLetIn(world, actor, member)
--     onLeave(world, actor, why)        leaving starts (called once)
--     onRemoved(world, actor, why)      gone from the lot (identity already restored)
--     onTimeout(world, actor)           timeout reached (default: leave)
--     onBlocked(world, actor)           could not reach the door or get in
--     onIgnored(world, actor) -> true   nobody answered the door (true: skip the default reaction)
--     reconcile(world, actor) -> "resume" | "leave" | "remove" | "keep"   after a load
--     afterDoor = "visit" | "task"      state after being let in (default: task when tick exists)
-- SS.Roles[name] is a wrapper whose tick runs the framework; the def stays in SS.Visitors.roles.
local ARRIVE_BY_ACCESS = { guest = "door", public = "door", service = "door_enter", emergency = "direct",
    intruder = "direct", household = "direct", staff = "none" }
local CLASS_BY_ACCESS = { guest = "social", public = "social", service = "service", emergency = "emergency",
    intruder = "intruder", household = "household", staff = "staff" }

local function wrap(name, def)
    return setmetatable({ name = name, def = def, framework = true, label = def.label or name, useAutonomy = def.useAutonomy and true or false,
        noNeeds = def.noNeeds, tick = function(world, actor, dt) return V.RoleTick(world, actor, dt) end }, { __index = def })
end

-- Resident roles: roles that people who live on the lot wear so their owner's brain runs (family's
-- "pet" and "infant"). A role is resident when its SS.Roles entry or its entry in this registry
-- says `resident = true` (family's stopgap declaration puts pets and infants in SS.Visitors.roles
-- with access "household"; either place counts). The framework never runs, restricts, caps, lists,
-- greets, sends home, removes or clears a resident role, and its wearer counts as a household
-- member. Registering one through RegisterRole records its label and leaves SS.Roles to the owner.
function V.Resident(role)
    if role == nil then return false end
    local d = V.roles[role]
    if type(d) == "table" and d.resident then return true end
    local r = SS.Roles[role]
    return type(r) == "table" and r.resident and true or false
end

local function install(name, def)
    if def.resident then
        local cur = SS.Roles[name]
        if cur == nil or (type(cur) == "table" and rawget(cur, "framework")) then SS.Roles[name] = def end
    else
        SS.Roles[name] = wrap(name, def)
    end
end
function V.RegisterRole(name, def)
    def = def or {}
    def.name = name
    V.roles[name] = def
    install(name, def)
    return def
end
for name, def in pairs(V.roles) do def.name = name; install(name, def) end

-- Is this role run by the framework (a visitor, worker or transit role)? Roles other modules put
-- straight into SS.Roles, and resident roles (V.Resident), are not: the framework never removes,
-- restricts or clears them.
function V.Owns(role) return role ~= nil and V.roles[role] ~= nil and not V.Resident(role) end
-- Is this actor on the lot as a visitor, worker or responder (a framework role other than the street's
-- internal walking roles)? A resident role is not a visit.
function V.IsVisitor(world, a)
    local role = a and a.role
    if not V.Owns(role) then return false end
    return not V.roles[role].internal
end
-- Access level and cap class of a framework role (nil for roles the framework does not own).
function V.AccessOf(role) if not V.Owns(role) then return nil end; return V.roles[role].access or "guest" end
function V.ClassOf(role)
    if not V.Owns(role) then return nil end
    local d = V.roles[role]
    return d.class or CLASS_BY_ACCESS[d.access or "guest"] or "other"
end
-- Minutes a role stays on the lot: def.timeout, else the class default (tuning.classTimeout);
-- false (in either) means no timeout. Returns nil for "no timeout".
local function timeoutFor(def)
    local t = def.timeout
    if t == nil then
        t = TUN.classTimeout[V.ClassOf(def.name or "") or "other"]
        if t == nil then t = TUN.classTimeout.other end
    end
    if t == false or type(t) ~= "number" then return nil end
    return t
end
V.TimeoutFor = timeoutFor
local function timeoutAt(world, def, override)
    if override == false then return nil end
    local t = override or timeoutFor(def)
    return t and (world.time + t) or nil
end

-- built-in roles from Data/Roles.lua (behaviour hooks are added below and in Sim/Services.lua)
for name, d in pairs(RD.roles) do
    local def = V.roles[name] or {}
    for k, v in pairs(d) do if def[k] == nil then def[k] = v end end
    V.RegisterRole(name, def)
end

---------------------------------------------------------------------------------------------------
-- People helpers
-- A household member present as themselves (not wearing a visitor role; a resident role such as an
-- infant's or a pet's, or any role another module gave them, still counts as a member).
function V.IsMember(world, a)
    return a and world.household and a.householdId == world.household.id and not V.Owns(a.role) and not a.dead and true or false
end
local function human(a) return (a.kind or "human") == "human" end
function V.MembersPresent(world)
    local out = {}
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if V.IsMember(world, a) and human(a) then out[#out + 1] = a end
    end
    return out
end
-- The same test without building a list (called every tick while a caller waits at the door).
function V.AnyMemberPresent(world)
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if V.IsMember(world, a) and human(a) then return true end
    end
    return false
end
function V.HomeLot(world)
    local hh = world.household
    return hh and hh.lotId == world.lot.id and world.lot.kind ~= "community" and true or false
end
function V.Busy(a) return a.act ~= nil or (a.queue ~= nil and #a.queue > 0) end

-- Read a relationship without creating it: daily, life, record (nil when the pair never met).
function V.RelPeek(world, a, b)
    local r
    if SS.Social and SS.Social.Get then r = SS.Social.Get(world, a, b)
    elseif SS.Social and SS.Social.Peek then r = SS.Social.Peek(world, a, b)
    else
        local root = world.root or world
        local rel = root.social and root.social.rel
        r = rel and rel[a .. ">" .. b]
    end
    if type(r) == "table" then return r.daily or 0, r.life or 0, r end
    return 0, 0, nil
end
-- Has anyone in the household met this person (a relationship record either way)?
function V.Knows(world, rid)
    local hh = world.household
    for _, mid in ipairs(hh and hh.members or {}) do
        local _, _, r1 = V.RelPeek(world, rid, mid)
        if r1 then return true end
        local _, _, r2 = V.RelPeek(world, mid, rid)
        if r2 then return true end
    end
    return false
end
local function relChange(world, a, b, pair)
    if a and b and pair and SS.Social and SS.Social.Change then SS.Social.Change(world, a, b, pair[1], pair[2]) end
end
V.RelChange = relChange
-- best mutual feeling between a person and any household member
function V.BestRel(world, rid)
    local hh = world.household
    local best = -1e9
    for _, mid in ipairs(hh and hh.members or {}) do
        local d1, l1 = V.RelPeek(world, rid, mid)
        local d2, l2 = V.RelPeek(world, mid, rid)
        local s = (d1 + l1 + d2 + l2) / 2
        if s > best then best = s end
    end
    return best == -1e9 and 0 or best
end
function V.CloseFriend(world, rid)
    local hh = world.household
    for _, mid in ipairs(hh and hh.members or {}) do
        local _, l = V.RelPeek(world, rid, mid)
        if l >= TUN.friendLife then return true end
    end
    return false
end

-- Lines go through the social module's pool (SS.Lines.Say). The fallback is plain functional text,
-- not a joke; it keeps the player informed when a situation has no authored line yet.
function V.Say(world, actor, situation, ctx, fallback, icon)
    V.stats.lines[situation] = (V.stats.lines[situation] or 0) + 1
    local text
    if SS.Lines and SS.Lines.Say then text = SS.Lines.Say(world, actor, situation, ctx or {}) end
    text = text or fallback
    if text and actor then actor.balloon = { kind = "speech", icon = icon or "social", text = text, untilT = world.time + 12 } end
    return text
end
-- V.quiet: set while a lot the player is leaving for another household is closed down; its notices
-- go to that household's journal (Services history) instead of the screen.
function V.Notice(world, actor, text, icon)
    if not text or V.quiet then return end
    if actor and SS.Actions and SS.Actions.Message then SS.Actions.Message(world, actor, text, icon or "social")
    else SS.Emit("notice", actor, text) end
end
function V.Journal(world, text)
    if world.household and SS.Actions and SS.Actions.Journal then SS.Actions.Journal(world, text) end
end
-- A help message: shown once per visitor, recorded in the journal.
function V.Help(world, actor, text)
    local vs = actor and actor.roleData and actor.roleData.vs
    if vs and vs.helped then return end
    if vs then vs.helped = true end
    V.stats.helps = V.stats.helps + 1
    V.Notice(world, actor, text, "noroute")
    V.Journal(world, text)
    SS.Emit("visitorHelp", world, actor, text)
end
local function sfx(name) if SS.Audio and SS.Audio.Sfx then SS.Audio.Sfx(name) end end
V.Sfx = sfx

local function history(world, text)
    local h = V.State(world).history
    h[#h + 1] = { t = world.time, text = text }
    while #h > TUN.historyCap do table.remove(h, 1) end
end

---------------------------------------------------------------------------------------------------
-- Persistent identities: stable NPCs per role pool, and the townie fallback.
local GEN_FIRST = { "Robin", "Ari", "Jo", "Sam", "Noor", "Remy", "Tess", "Kai" }
local GEN_LAST = { "Calloway", "Brandt", "Osei", "Varga", "Lund", "Moreau", "Adair", "Pike" }

function V.EnsureNPC(world, entry, pool)
    local root = world.root
    local r = root.residents[entry.id]
    if r then return r end
    local skills = {}
    for k, v in pairs(RD.skills[pool] or {}) do skills[k] = v end
    r = {
        id = entry.id, name = entry.name, npc = true, pool = pool, kind = "human", age = "adult", pronoun = entry.pronoun or "they",
        look = U.deepcopy(entry.look), outfit = "work",
        needs = { hunger = 60, energy = 60, bladder = 60, hygiene = 60, fun = 30, social = 30, comfort = 40, room = 0 },
        personality = { neat = 6, outgoing = 5, active = 6, playful = 4, nice = 6 }, interests = {}, skills = skills,
        x = 0, y = 0, level = 0, facing = 0,
    }
    root.residents[entry.id] = r
    return r
end

-- Is this person free to come to the active lot? Returns ok, why.
function V.Available(world, r)
    if not r then return false, "Unknown person." end
    local name = r.name or "They"
    if r.dead then return false, name .. " has passed away." end
    if world.actors[r.id] then return false, name .. " is already here." end
    if r.away then return false, name .. " is away right now." end
    local root = world.root
    if world.household and r.householdId == world.household.id then return false, name .. " lives here." end
    local hh = r.householdId and root.households[r.householdId]
    if r.lotId and not (hh and hh.lotId == r.lotId) then return false, name .. " is somewhere else right now." end
    if root.outing and root.outing.participants then
        for _, rid in ipairs(root.outing.participants) do if rid == r.id then return false, name .. " is out." end end
    end
    return true
end

function V.PoolPick(world, role, data)
    local def = V.roles[role] or {}
    local poolName = def.pool or role
    local list = RD.pools[poolName]
    local st = V.State(world)
    local prefer = data and data.prefer
    local best, bestT
    for _, e in ipairs(list or {}) do
        local r = world.root.residents[e.id]
        local free = (not r) or (V.Available(world, r))
        if free then
            if e.id == prefer then return V.EnsureNPC(world, e, poolName) end
            local t = st.lastUsed[e.id] or -1e9
            if not best or t < bestT then best, bestT = e, t end
        end
    end
    if best then return V.EnsureNPC(world, best, poolName) end
    for n = 1, 8 do
        local id = "npc_" .. role .. "_" .. n
        local r = world.root.residents[id]
        if not r then
            local uniform = def.outfit or RD.poolUniform[poolName] or "staff"
            return V.EnsureNPC(world, { id = id, name = GEN_FIRST[n] .. " " .. GEN_LAST[(n * 3) % #GEN_LAST + 1], pronoun = "they",
                look = RD.GeneratedLook(uniform, n) }, poolName)
        elseif V.Available(world, r) then
            return r
        end
    end
    return nil
end

local function isTownie(world, r)
    if type(r) ~= "table" or r.npc or r.dead or not human(r) or r.age == "infant" then return false end
    local hh = world.household
    return not (hh and r.householdId == hh.id)
end
V.IsTownie = isTownie

-- Top the neighbourhood up to tuning.townieMin townies from Data/Roles.lua (stable ids, never twice).
function V.EnsureTownies(world)
    local root = world.root
    local have = 0
    for _, r in pairs(root.residents) do if isTownie(world, r) then have = have + 1 end end
    local made = 0
    for _, e in ipairs(RD.townies) do
        if have >= TUN.townieMin then break end
        if not root.residents[e.id] then
            root.residents[e.id] = {
                id = e.id, name = e.name, townie = true, kind = "human", age = e.age or "adult", pronoun = e.pronoun, bio = e.bio,
                personality = U.deepcopy(e.personality), interests = {}, look = U.deepcopy(e.look), outfit = "everyday",
                needs = { hunger = 50, energy = 55, bladder = 60, hygiene = 60, fun = 30, social = 20, comfort = 40, room = 0 },
                skills = {}, x = 0, y = 0, level = 0, facing = 0,
            }
            have, made = have + 1, made + 1
        end
    end
    return made
end

-- Street townies (no household) come from home rested: for the visit their needs are topped up to
-- ordinary levels. Like everyone's, their saved needs come back when the visit ends (V.HomeRecord),
-- so a visit never changes the needs of a paused household's resident or a townie (§5.4).
local TOWNIE_REST = { hunger = 50, energy = 55, bladder = 60, hygiene = 60, comfort = 40 }
local function refreshTownie(world, r)
    if not r.townie or r.householdId or type(r.needs) ~= "table" then return end
    for k, v in pairs(TOWNIE_REST) do
        if (r.needs[k] or 0) < v then r.needs[k] = v end
    end
end

-- Candidate visitors: townies and residents of other households who are free now, sorted by id.
function V.Candidates(world)
    local out = {}
    local root = world.root
    for _, id in ipairs(sortedIds(root.residents)) do
        local r = root.residents[id]
        if isTownie(world, r) and V.Available(world, r) then out[#out + 1] = r end
    end
    return out
end

-- People the household knows (any relationship either way), best first; falls back to neighbours.
function V.KnownPeople(world, limit)
    local out = {}
    local root = world.root
    for _, id in ipairs(sortedIds(root.residents)) do
        local r = root.residents[id]
        if isTownie(world, r) then out[#out + 1] = { r = r, score = V.BestRel(world, id) } end
    end
    table.sort(out, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.r.id < b.r.id end)
    while #out > (limit or 12) do table.remove(out) end
    return out
end

---------------------------------------------------------------------------------------------------
-- Rooms, doors and permissions
local function isBedDef(def)
    if SS.Tags.Has(def, "bed") or SS.Tags.Has(def, "bed_child") then return true end
    for name, sl in pairs(def.slots or {}) do
        if (name == "bed" or sl.group == "bed") and sl.on then return true end
    end
    return false
end
local function isBathDef(def)
    if SS.Tags.Has(def, "toilet") or SS.Tags.Has(def, "shower") or SS.Tags.Has(def, "bath") then return true end
    for _, iid in ipairs(def.actions or {}) do
        if iid == "toilet" or iid == "shower" or iid == "bath" then return true end
    end
    return false
end
-- Somewhere customers sit (a chair, a bench, a dining or cafe table): a room holding one stays open
-- to them. A toilet's or a bed's "seat" slot does not count.
local function isSeatDef(def)
    if isBathDef(def) or isBedDef(def) then return false end
    if def.seat or def.cat == "seating" then return true end
    return SS.Tags.Has(def, "seat") or SS.Tags.Has(def, "table_dining") or SS.Tags.Has(def, "cafe_table")
        or SS.Tags.Has(def, "table") or false
end
V.IsBedDef, V.IsBathDef, V.IsSeatDef = isBedDef, isBathDef, isSeatDef

-- Derived per rebuild: bedrooms (private unless they hold an exterior door or the house is one room),
-- bathrooms, staff-only rooms (rooms holding a def.staffOnly object, plus lot.staffOnly cells).
function V.RoomInfo(world)
    local c = V.rooms
    local lot = world.lot
    if c and c.rt == SS.RT and c.lot == lot and c.ver == lot.version then return c end
    c = { rt = SS.RT, lot = lot, ver = lot.version, private = {}, bath = {}, staff = {}, bed = {}, doorRoom = {}, hasStaff = false,
        staffCells = {}, seatRoom = {} }
    for lv = 0, W.LEVELS - 1 do
        c.private[lv], c.bath[lv], c.staff[lv], c.bed[lv], c.doorRoom[lv] = {}, {}, {}, {}, {}
        c.staffCells[lv], c.seatRoom[lv] = {}, {}
    end
    local community = lot.kind == "community"
    local staffObjs
    for _, o in pairs(lot.objects) do
        local def = SS.Objects[o.def]
        local lv = o.level or 0
        if def and lv < W.LEVELS and W.InLot(lot, o.x, o.y) then
            local room = W.RoomAt(world, lv, o.x, o.y)
            if room > 0 then
                if isBedDef(def) then c.bed[lv][room] = true end
                if isBathDef(def) then c.bath[lv][room] = true end
                if def.staffOnly then
                    c.hasStaff = true
                    if community then staffObjs = staffObjs or {}; staffObjs[#staffObjs + 1] = { o, def, lv, room }
                    else c.staff[lv][room] = true end
                elseif community and isSeatDef(def) then
                    c.seatRoom[lv][room] = true
                end
            end
        end
    end
    -- On a community lot a staff-only design closes the room it stands in, unless customers sit in
    -- that room (a staff counter in a dining room): then only the design's own cells and the cells its
    -- slots are used from are staff-only, so the customers keep their tables (outings VI-1).
    for _, e in ipairs(staffObjs or {}) do
        local o, def, lv, room = e[1], e[2], e[3], e[4]
        if c.seatRoom[lv][room] then
            local cells = c.staffCells[lv]
            for _, fc in ipairs(G.footprint(def, o)) do
                if W.InLot(lot, fc[1], fc[2]) then cells[fc[2] * lot.w + fc[1] + 1] = true end
            end
            for _, sl in pairs(def.slots or {}) do
                for _, ap in ipairs(sl.approaches or {}) do
                    local dx, dy = G.rot(ap[1], ap[2], o.f or 0)
                    local i, j = o.x + dx, o.y + dy
                    if W.InLot(lot, i, j) and W.RoomAt(world, lv, i, j) == room then cells[j * lot.w + i + 1] = true end
                end
            end
        else
            c.staff[lv][room] = true
        end
    end
    local indoor = 0
    for _, rooms in pairs(SS.RT.rooms or {}) do
        for _, r in pairs(rooms) do if not r.outdoor then indoor = indoor + 1 end end
    end
    for lv = 0, W.LEVELS - 1 do
        for key, wl in pairs(lot.walls[lv] or {}) do
            if wl.kind == "door" then
                local _, _, _, ai, aj, bi, bj = G.parseEdge(key)
                local ra = W.InLot(lot, ai, aj) and W.RoomAt(world, lv, ai, aj) or 0
                local rb = W.InLot(lot, bi, bj) and W.RoomAt(world, lv, bi, bj) or 0
                if (ra == 0) ~= (rb == 0) then c.doorRoom[lv][ra > 0 and ra or rb] = true end
            end
        end
        for room in pairs(c.bed[lv]) do
            if indoor > 1 and not c.doorRoom[lv][room] and not c.bath[lv][room] then c.private[lv][room] = true end
        end
    end
    if type(lot.staffOnly) == "table" then
        for _, cells in pairs(lot.staffOnly) do if type(cells) == "table" and next(cells) then c.hasStaff = true end end
    end
    V.rooms = c
    return c
end

-- Access level of an actor on this lot: household | guest | outside (a guest not invited in) |
-- public | service | staff | emergency | intruder.
-- A role the framework does not own (one put straight into SS.Roles) keeps the access its SS.Roles
-- entry declares (a staff lock admits a service or staff role, an emergency crew passes any lock);
-- with a guest-like or no declared access, and for resident roles (family's pets and infants), the
-- actor gets the access it would have without a role: household members stay household.
local FOREIGN_ACCESS = { household = true, service = true, staff = true, emergency = true, intruder = true }
function V.Access(world, who)
    local role = who.role
    local acc = V.AccessOf(role)
    if not acc and role ~= nil and not V.Resident(role) then
        local r = SS.Roles[role]
        if type(r) == "table" and FOREIGN_ACCESS[r.access] then return r.access end
    end
    if not acc then
        if world.lot.kind == "community" then return "public" end
        local hh = world.household
        if hh and who.householdId == hh.id then return "household" end
        if not human(who) then return "household" end
        return "guest"
    end
    if acc == "guest" or acc == "public" then
        local vs = who.roleData and who.roleData.vs
        if vs and vs.invitedIn then return "guest" end
        return "outside"
    end
    return acc
end

-- The permission rule inside A*: blocks entering (never leaving) a room the actor may not use.
local function passHook(world, level, i, j, ni, nj, wall, who)
    if not who then return end
    local acc = V.Access(world, who)
    if acc == "household" or acc == "emergency" or acc == "intruder" then return end
    if wall and wall.locked then
        if wall.locked == "staff" then
            if acc ~= "staff" and acc ~= "service" then return false end
        else
            return false
        end
    end
    local info = V.RoomInfo(world)
    local lot = world.lot
    local rooms = SS.RT.room and SS.RT.room[level]
    local w = lot.w
    local nIdx, cIdx = nj * w + ni + 1, j * w + i + 1
    local nroom = rooms and rooms[nIdx] or 0
    local croom = rooms and rooms[cIdx] or 0
    if info.hasStaff and acc ~= "staff" and acc ~= "service" then
        local cells = type(lot.staffOnly) == "table" and lot.staffOnly[level]
        local sc = info.staffCells[level]
        local toStaff = info.staff[level][nroom] or (cells and cells[nIdx]) or sc[nIdx]
        local fromStaff = info.staff[level][croom] or (cells and cells[cIdx]) or sc[cIdx]
        if toStaff and not fromStaff then return false end
    end
    if nroom == 0 or nroom == croom then return end
    if acc == "outside" then return false end
    if acc ~= "service" and info.private[level][nroom] then return false end
    if info.bath[level][nroom] then
        local occ = V.bathOcc[level] and V.bathOcc[level][nroom]
        if occ and occ ~= who.id then return false end
    end
end
W.RegisterPassHook(passHook)
V.PassHook = passHook

-- Who is in which bathroom (refreshed each sim minute). Privacy for visitors: a guest or worker
-- never walks into a bathroom somebody else is in.
local function updateBathOcc(world)
    local info = V.RoomInfo(world)
    for lv = 0, W.LEVELS - 1 do
        local t = V.bathOcc[lv]
        if not t then t = {}; V.bathOcc[lv] = t end
        for k in pairs(t) do t[k] = nil end
    end
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        local lv = a.level or 0
        local i, j = math.floor(a.x), math.floor(a.y)
        if lv < W.LEVELS and W.InLot(world.lot, i, j) then
            local room = W.RoomAt(world, lv, i, j)
            if room > 0 and info.bath[lv][room] and not V.bathOcc[lv][room] then V.bathOcc[lv][room] = id end
        end
    end
end
V.UpdateBathOcc = updateBathOcc

-- Exterior doors on level 0 (a door with outdoors on one side), nearest to the street entry first.
local doorCache = {}
function V.Doors(world)
    local lot = world.lot
    if doorCache.rt == SS.RT and doorCache.lot == lot and doorCache.ver == lot.version then return doorCache.list end
    local list = {}
    local ei, ej = St.EntryCell(world)
    for key, wl in pairs(lot.walls[0] or {}) do
        if wl.kind == "door" then
            local _, _, _, ai, aj, bi, bj = G.parseEdge(key)
            if W.InLot(lot, ai, aj) and W.InLot(lot, bi, bj) then
                local ra, rb = W.RoomAt(world, 0, ai, aj), W.RoomAt(world, 0, bi, bj)
                if (ra == 0) ~= (rb == 0) then
                    local si, sj, ii, ij = ai, aj, bi, bj
                    if ra ~= 0 then si, sj, ii, ij = bi, bj, ai, aj end
                    list[#list + 1] = { key = key, stand = { si, sj, 0 }, inside = { ii, ij, 0 },
                        dist = math.abs(si - ei) + math.abs(sj - ej), locked = wl.locked }
                end
            end
        end
    end
    table.sort(list, function(a, b) if a.dist ~= b.dist then return a.dist < b.dist end return a.key < b.key end)
    doorCache.rt, doorCache.lot, doorCache.ver, doorCache.list = SS.RT, lot, lot.version, list
    return list
end
function V.DoorFor(world, vs)
    local doors = V.Doors(world)
    local d = doors[(vs and vs.doorIdx) or 1] or doors[1]
    if d then return d end
    local ei, ej = St.EntryCell(world)
    return { stand = { ei, ej, 0 }, none = true }
end

function V.FindTagged(world, tag)
    local lot = world.lot
    for _, oid in ipairs(sortedIds(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and SS.Tags.Has(def, tag) then return o end
    end
end
function V.Doorbell(world) return V.FindTagged(world, "doorbell") end

-- The work slot visitors' object interactions use (phone calls, answering, mail, admiring, every
-- service task): one name, "svc", so a phone user and a repair worker can never hold the same spot
-- under two names. Resolution, in order:
--   1. the definition declares slots.svc itself (what docs/requests/visitors.md asks catalogue for);
--   2. a slot already in the "svc" group;
--   3. the object's own `front` slot, when it is a standing slot with no group (beside the object,
--      or on it with a standing pose, like a payphone booth's): it is tagged group = "svc", so the
--      executor reserves it under its real name ("front") and household use of the front and a
--      visitor's svc use exclude each other (no alias, no second reservation key);
--   4. otherwise a separate svc slot on the free sides of the footprint, avoiding cells other slots
--      already approach from when any remain (wall-mounted objects: in front only).
-- This is the only change visitors makes to shared definitions, and it is idempotent.
local STANDING_POSE = { stand = true, phone = true, use = true, idle = true, talk = true }
function V.EnsureSlot(def, name)
    name = name or "svc"
    def.slots = def.slots or {}
    if def.slots[name] then return name end
    for _, sl in pairs(def.slots) do if sl.group == name then return name end end
    local front = def.slots.front
    if front and front.group == nil and (not front.on or STANDING_POSE[front.pose or "stand"]) then front.group = name; return name end
    local fp = def.fp or { { 0, 0 } }
    local inFp, used, seen, ap, spare = {}, {}, {}, {}, {}
    for _, c in ipairs(fp) do inFp[c[1] .. "," .. c[2]] = true end
    for _, sl in pairs(def.slots) do
        for _, a in ipairs(sl.approaches or {}) do used[a[1] .. "," .. a[2]] = true end
    end
    local dirs = (def.mount == "wall") and { { 0, 1 } } or { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }
    for _, d in ipairs(dirs) do
        for _, c in ipairs(fp) do
            local ax, ay = c[1] + d[1], c[2] + d[2]
            local k = ax .. "," .. ay
            if not inFp[k] and not seen[k] then
                seen[k] = true
                if used[k] then spare[#spare + 1] = { ax, ay } else ap[#ap + 1] = { ax, ay } end
            end
        end
    end
    if #ap == 0 then ap = spare end
    def.slots[name] = { approaches = ap, face = 2 }
    return name
end

---------------------------------------------------------------------------------------------------
-- Bounded routing through the shared executor.
-- V.Goto(world, actor, vs, goals, tag[, maxTries, cooldown]) -> "arrived" | "moving" | "wait" | "failed"
-- One A* search per attempt (counted in V.stats.searches). A failed or interrupted walk counts as an
-- attempt; after maxTries the caller gives up. Never retries every frame.
function V.Goto(world, a, vs, goals, tag, maxTries, cooldown)
    maxTries, cooldown = maxTries or TUN.routeRetries, cooldown or TUN.routeCooldown
    if vs.gotoTag ~= tag then vs.gotoTag, vs.tries, vs.nextTry, vs.ordered = tag, 0, nil, nil end
    local lv = a.level or 0
    local ci, cj = math.floor(a.x), math.floor(a.y)
    for n = 1, #goals do
        local g = goals[n]
        if g[1] == ci and g[2] == cj and (g[3] or 0) == lv then vs.tries, vs.ordered = 0, nil; return "arrived", g end
    end
    if V.Busy(a) then return "moving" end
    if vs.ordered then
        vs.ordered = nil
        vs.tries = (vs.tries or 0) + 1
        vs.nextTry = world.time + cooldown
        V.stats.routeFails = V.stats.routeFails + 1
    end
    if (vs.tries or 0) >= maxTries then return "failed" end
    if vs.nextTry and world.time < vs.nextTry then return "wait" end
    V.stats.searches = V.stats.searches + 1
    local path, gi = SS.Nav.FindPath(world, ci, cj, lv, goals, a)
    if not path then
        vs.tries = (vs.tries or 0) + 1
        vs.nextTry = world.time + cooldown
        V.stats.routeFails = V.stats.routeFails + 1
        if vs.tries >= maxTries then return "failed" end
        return "wait"
    end
    local g = goals[gi]
    SS.Actions.Order(world, a, nil, "goto", g[1], g[2], { level = g[3] or 0, data = { visitorGoto = true } })
    vs.ordered = true
    return "moving"
end

-- One counted search: can this actor reach the interaction's approach cells?
function V.Reachable(world, a, obj, iid)
    if not (SS.Actions.ResolveSlot and SS.Nav.FindPath) then return true end
    local tgt = SS.Actions.ResolveSlot(world, a, obj, iid)
    if not tgt then return false end
    V.stats.searches = V.stats.searches + 1
    return SS.Nav.FindPath(world, math.floor(a.x), math.floor(a.y), a.level or 0, tgt.approaches, a) ~= nil
end

-- For other modules' roles (staff going to their post, police to a room, a firefighter to a fire):
-- bounded routing that ends in a help message instead of endless retries.
-- V.Route(world, actor, goals, tag, opts) -> "arrived" | "moving" | "wait" | "failed"
-- opts: help (text shown once on failure), leave (true: leave the lot on failure), tries, cooldown.
function V.Route(world, a, goals, tag, opts)
    opts = opts or {}
    local rd = a.roleData
    if type(rd) ~= "table" then rd = {}; a.roleData = rd end
    rd.vs = rd.vs or { state = "task", since = world.time, mode = "none", onLot = true, tries = 0 }
    local res = V.Goto(world, a, rd.vs, goals, tag, opts.tries, opts.cooldown)
    if res == "failed" then
        V.Help(world, a, opts.help or ((a.name or "Someone") .. " can't get where they need to go (the way is blocked)."))
        if opts.leave and a.role then V.Leave(world, a, "blocked") end
    end
    return res
end

---------------------------------------------------------------------------------------------------
-- System objects placed by visitors (newspaper, welcome treats; Services adds the delivered meal).
function V.NewObjectId(lot)
    local n = math.max(lot.nextId or 1, lot.nextObj or 1)
    while lot.objects["o" .. n] do n = n + 1 end
    lot.nextId = n + 1
    if lot.nextObj then lot.nextObj = n + 1 end
    return "o" .. n
end
-- Objects that never block a cell (ARCHITECTURE §7 noBlock, items resting on a surface).
local function nonBlocking(def, o)
    if W.NonBlocking then return W.NonBlocking(def, o) end
    return def and (def.noBlock or def.mount == "surface" or (o and o.parent)) and true or false
end
V.NonBlocking = nonBlocking
-- After adding or removing an object. Anything that blocks cells needs the full navigation rebuild;
-- a non-blocking system object (the paper, treats, a meal) only changes the object set, so it skips
-- the rebuild: household-core's World.ObjectsChanged refreshes object caches when present, and the
-- occupancy entry a baseline rebuild may have recorded for a removed item is cleared in place.
local function afterEdit(world, o, def, removed)
    local lot = world.lot
    if nonBlocking(def, o) then
        local rt = SS.RT
        local lv = o.level or 0
        local occ = rt and rt.occ and rt.occ[lv]
        if removed and occ and W.InLot(lot, o.x, o.y) then
            local k = W.idx(lot, o.x, o.y)
            if occ[k] == o.id then occ[k] = nil end
        end
        if W.ObjectsChanged then W.ObjectsChanged() end
        V.stats.lightEdits = (V.stats.lightEdits or 0) + 1
    else
        lot.version = (lot.version or 1) + 1
        SS.World.Rebuild(world)
        St.InvalidateEntry()
        V.rooms, doorCache.rt = nil, nil
        V.stats.rebuilds = (V.stats.rebuilds or 0) + 1
    end
    SS.Emit("lotChanged", "object", o.id)
end
function V.AddObject(world, defId, x, y, level, extra)
    local lot = world.lot
    local def = SS.Objects[defId]
    if not def then return nil end
    local id = V.NewObjectId(lot)
    local o = { id = id, def = defId, x = x, y = y, f = 0, level = level or 0,
        state = def.startState and U.deepcopy(def.startState) or {}, bought = world.time, paid = 0,
        owner = world.household and world.household.id }
    if extra then for k, v in pairs(extra) do o[k] = v end end
    lot.objects[id] = o
    afterEdit(world, o, def, false)
    return o
end
function V.RemoveObject(world, oid)
    local o = world.lot.objects[oid]
    if not o then return false end
    world.lot.objects[oid] = nil
    afterEdit(world, o, SS.Objects[o.def], true)
    return true
end

-- Surface slots of an object, keyed "n:k" (surface n, slot k), the convention catalogue and
-- household-core share: { key, i, j, level, z, kind, child }. household-core's World.SurfaceSlots
-- is used when present; this fallback reads def.surfaces / def.surface the same way. A legacy
-- numeric pslot (1) counts as "1:1".
function V.SurfaceSlots(world, obj)
    if W.SurfaceSlots then return W.SurfaceSlots(world, obj) end
    local def = SS.Objects[obj.def]
    if not def then return {} end
    local surfs = {}
    if type(def.surfaces) == "table" and #def.surfaces > 0 then
        for n, sf in ipairs(def.surfaces) do surfs[n] = { cell = sf.cell or { 0, 0 }, z = sf.z or def.height or 0.75, kind = sf.kind or "table", slots = sf.slots or 1 } end
    elseif def.surface then
        local kind = (def.cat == "kitchen" or SS.Tags.Has(def, "counter")) and "counter" or "table"
        for n, c in ipairs(def.fp or { { 0, 0 } }) do surfs[n] = { cell = { c[1], c[2] }, z = def.height or 0.75, kind = kind, slots = 1 } end
    end
    local used = {}
    for cid, c in pairs(world.lot.objects) do
        if c.parent == obj.id then
            local key = c.pslot
            if type(key) == "number" then key = "1:" .. key end
            used[key or "1:1"] = cid
        end
    end
    local out = {}
    for n, sf in ipairs(surfs) do
        local dx, dy = G.rot(sf.cell[1], sf.cell[2], obj.f or 0)
        for k = 1, sf.slots do
            local key = n .. ":" .. k
            out[#out + 1] = { key = key, i = obj.x + dx, j = obj.y + dy, level = obj.level or 0, z = sf.z, kind = sf.kind, child = used[key] }
        end
    end
    return out
end

-- The nearest surface (table/counter) to `near` with a free slot: surfaceObj, slot | nil.
-- opts.kinds limits slot kinds ({ counter = true, table = true }).
function V.FindSurface(world, near, opts)
    local lot = world.lot
    local best, bestSlot, bestD
    for _, oid in ipairs(sortedIds(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and (def.surface or def.surfaces) and not o.parent and not (o.state and (o.state.broken or o.state.burnt)) then
            local d = near and (math.abs(o.x - near[1]) + math.abs(o.y - near[2]) + math.abs((o.level or 0) - (near[3] or 0)) * 6) or 0
            if not bestD or d < bestD then
                for _, sl in ipairs(V.SurfaceSlots(world, o)) do
                    if not sl.child and (not (opts and opts.kinds) or opts.kinds[sl.kind]) then best, bestSlot, bestD = o, sl, d; break end
                end
            end
        end
    end
    return best, bestSlot
end

-- Put a system object on a free surface slot near `near`. Returns the object or nil.
function V.PlaceOnSurface(world, defId, near, extra, opts)
    local surface, slot = V.FindSurface(world, near, opts)
    if not surface then return nil end
    local fields = { parent = surface.id, pslot = slot.key, z = slot.z }
    for k, v in pairs(extra or {}) do fields[k] = v end
    return V.AddObject(world, defId, slot.i, slot.j, surface.level or 0, fields)
end

-- A free floor cell near `near` (outdoor when opts.outdoor): not blocked, not holding another floor
-- object (non-blocking items included, so two papers never share a cell), not the street entry or a
-- door's cells. Nearest ring first, then the street side, then west to east.
function V.FindFloorSpot(world, near, opts)
    opts = opts or {}
    local lot = world.lot
    local cands = {}
    local avoid = {}
    local ei, ej = St.EntryCell(world)
    avoid[ei .. "," .. ej] = true
    for _, d in ipairs(V.Doors(world)) do avoid[d.stand[1] .. "," .. d.stand[2]] = true; avoid[d.inside[1] .. "," .. d.inside[2]] = true end
    for _, o in pairs(lot.objects) do
        if (o.level or 0) == 0 and not o.parent then avoid[o.x .. "," .. o.y] = true end
    end
    for r = 1, opts.radius or 3 do
        for dj = -r, r do
            for di = -r, r do
                if math.max(math.abs(di), math.abs(dj)) == r then
                    local i, j = near[1] + di, near[2] + dj
                    if W.InLot(lot, i, j) and not W.Blocked(world, 0, i, j) and not avoid[i .. "," .. j]
                        and (not opts.outdoor or W.RoomAt(world, 0, i, j) == 0) then
                        cands[#cands + 1] = { i, j, r }
                    end
                end
            end
        end
    end
    table.sort(cands, function(a, b) if a[3] ~= b[3] then return a[3] < b[3] end if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    return cands
end

-- Place a system object on the floor near `near`. A blocking object is only kept where the street
-- entry still reaches the front door (one search per candidate, at most 3 candidates); a
-- non-blocking one (paper, treats, meal) cannot cut anything off and takes the first free spot.
function V.PlaceNear(world, defId, near, opts)
    local def = SS.Objects[defId]
    if not def then return nil end
    local cands = V.FindFloorSpot(world, near, opts)
    if nonBlocking(def, nil) then
        local c = cands[1]
        return c and V.AddObject(world, defId, c[1], c[2], 0, opts and opts.extra) or nil
    end
    local door = V.DoorFor(world, {})
    local ei, ej = St.EntryCell(world)
    for n = 1, math.min(#cands, 3) do
        local c = cands[n]
        local o = V.AddObject(world, defId, c[1], c[2], 0, opts and opts.extra)
        V.stats.searches = V.stats.searches + 1
        if door.none or SS.Nav.FindPath(world, ei, ej, 0, { door.stand }, nil) then return o end
        V.RemoveObject(world, o.id)
    end
    return nil
end

---------------------------------------------------------------------------------------------------
-- Requests: V.Request(world, role, data) -> requestId | nil, why
-- data: rid (a specific person; nil = the role's NPC pool), at (arrival time; default now + delay),
--   delay, window (random extra minutes), key (dedupe; default role:rid), invited, host (rid), vehicle
--   (kind, or false for on foot), arrive (mode override), priority = "emergency" (skips caps and
--   staleness), walkIn, stayUntil, party, welcome, gift, visit (service visit id), lotId.
-- A pending or active request with the same key is never duplicated: the existing id is returned
-- with "already". Requests are saved and fire through the scheduler on their lot's clock.
-- Does a request still stand for dedupe? Pending ones do. An active one stops counting once its
-- visitor is on the way out (leaving, walking off, or already gone) or its service visit has settled,
-- so calling again while the last worker or courier walks back to the van books a real new visit.
function V.RequestOpen(world, r)
    if r.state == "pending" then return true end
    if r.state ~= "active" then return false end
    local vid = r.data and r.data.visit
    local sv = vid and SS.Services and SS.Services.Get and SS.Services.Get(world, vid)
    if sv and sv.settled then return false end
    if r.lotId ~= world.lot.id then return true end
    local a = r.rid and world.actors[r.rid]
    if not a or not a.role then return false end
    local vs = a.roleData and a.roleData.vs
    if vs and (vs.state == "leaving" or vs.state == "passing" or vs.leaveCalled) then return false end
    return true
end
-- The standing request with this key on a lot, if any: id, request.
function V.OpenRequest(world, key, lotId)
    local s = V.State(world)
    lotId = lotId or world.lot.id
    for _, id in ipairs(sortedIds(s.requests)) do
        local r = s.requests[id]
        if r.key == key and r.lotId == lotId and V.RequestOpen(world, r) then return id, r end
    end
end

function V.Request(world, role, data)
    data = data or {}
    if not V.Owns(role) then return nil, "Nobody does that job here." end
    local s = V.State(world)
    local lotId = data.lotId or world.lot.id
    local key = data.key or (role .. ":" .. tostring(data.rid or "any"))
    local open = V.OpenRequest(world, key, lotId)
    if open then return open, "already" end
    if data.rid and world.actors[data.rid] and world.actors[data.rid].role then
        return nil, (world.actors[data.rid].name or "They") .. " is already here."
    end
    local at = data.at or (world.time + (data.delay or 0))
    if data.window and data.window > 0 then at = at + SS.RandomInt(world, "visitors", 0, data.window) end
    local id = "vr" .. s.nextReq
    s.nextReq = s.nextReq + 1
    local copy = {}
    for k, v in pairs(data) do
        local tv = type(v)
        if tv == "string" or tv == "number" or tv == "boolean" then copy[k] = v end
    end
    local r = { id = id, role = role, lotId = lotId, at = at, rid = data.rid, key = key, data = copy,
        state = "pending", created = world.time, defers = 0 }
    s.requests[id] = r
    V.PruneRequests(world)
    if at <= world.time and lotId == world.lot.id then
        V.Fulfil(world, id)
    else
        local ev, why = V.After(world, at, "visitors.arrive", { req = id }, lotId)
        if not ev then
            r.state, r.why = "cancelled", "busy"
            SS.Emit("visitorCancelled", world, r)
            return nil, why
        end
    end
    return id
end

function V.PruneRequests(world)
    local s = V.State(world)
    local n = 0
    for _ in pairs(s.requests) do n = n + 1 end
    if n <= TUN.requestCap then return end
    local settled = {}
    for id, r in pairs(s.requests) do
        if r.state ~= "pending" and r.state ~= "active" then settled[#settled + 1] = r end
    end
    table.sort(settled, function(a, b) if a.created ~= b.created then return a.created < b.created end return a.id < b.id end)
    for k = 1, math.min(#settled, n - TUN.requestCap) do s.requests[settled[k].id] = nil end
end

function V.GetRequest(world, id) return V.State(world).requests[id] end

-- Cancel a pending request (no one comes) or send an active visitor home.
function V.CancelRequest(world, id, why)
    local r = V.State(world).requests[id]
    if not r then return false, "No such visit." end
    if r.state == "pending" then
        r.state, r.why = "cancelled", why or "cancelled"
        V.CancelTimers(world, function(ev) return ev.kind == "visitors.arrive" and ev.data and ev.data.req == id end)
        SS.Emit("visitorCancelled", world, r)
        return true
    elseif r.state == "active" then
        local a = r.rid and world.actors[r.rid]
        if a then V.Leave(world, a, why or "cancelled") end
        return true
    end
    return false, "That visit is already over."
end

local function requestFail(world, r, why, notice)
    r.state, r.why = "cancelled", why
    SS.Emit("visitorCancelled", world, r)
    if notice then V.Notice(world, nil, notice) end
end

-- Scheduled arrival of a request. Stale social visits are dropped; capped ones are deferred a few
-- times, then cancelled with a notice.
function V.Fulfil(world, id)
    local s = V.State(world)
    local r = s.requests[id]
    if not r or r.state ~= "pending" then return end
    if r.lotId ~= world.lot.id then return end
    if not V.Owns(r.role) then return requestFail(world, r, "no_role") end
    local def = V.roles[r.role]
    local class = V.ClassOf(r.role)
    local urgent = r.data.priority == "emergency" or class == "emergency"
    if not urgent and world.time - r.at > TUN.maxLate and (class == "social" or class == "delivery") and not r.data.visit then
        return requestFail(world, r, "stale")
    end
    if not urgent and V.CountClass(world, class) >= (TUN.caps[class] or TUN.caps.other) then
        if r.defers < TUN.maxDefers then
            r.defers = r.defers + 1
            V.stats.deferred = V.stats.deferred + 1
            r.at = world.time + TUN.deferMinutes
            local ev, why = V.After(world, r.at, "visitors.arrive", { req = id }, r.lotId)
            if ev then return end
            return requestFail(world, r, "busy", (def.label or r.role) .. " couldn't come: " .. why)
        end
        return requestFail(world, r, "cap", (def.label or r.role) .. " couldn't come: too many visitors on the lot.")
    end
    -- A role may take over its own arrival when the request comes due: def.onDue(world, request) ->
    -- the actor it put on the lot, or nil when it is no longer wanted. Events' responders (requests
    -- with source = "events" and an eventId) go through SS.Events.Arrive, which checks the responder
    -- is still needed (the fire still burns, everyone still sleeps) and spawns them through V.Spawn
    -- itself. Events' other requests (a drop-in guest has no eventId) arrive the ordinary way.
    local due = def.onDue
    if not due and r.data.source == "events" and r.data.eventId ~= nil and SS.Events and SS.Events.Arrive then
        due = function(w, req)
            return SS.Events.Arrive(w, { role = req.role, rid = req.rid, eventId = req.data.eventId, vehicle = req.data.vehicle })
        end
    end
    if due then
        local okDue, a = pcall(due, world, r)
        if not okDue then SS.Log("visitors: arrival hand-off for %s failed: %s", tostring(r.role), tostring(a)) end
        if okDue and type(a) == "table" and world.actors[a.id] and a.role then
            r.state, r.rid = "active", a.id
            local vs = type(a.roleData) == "table" and a.roleData.vs
            if vs and not vs.req then vs.req = id end
        else
            r.state, r.why = "done", "handed_over"
        end
        return
    end
    local data = {}
    for k, v in pairs(r.data) do data[k] = v end
    data.req = id
    local a, why = V.Spawn(world, r.rid, r.role, data)
    if not a then
        local who = r.rid and world.root.residents[r.rid]
        return requestFail(world, r, why or "unavailable", (r.data.invited and who) and ((who.name or "Your guest") .. " can't come after all: " .. (why or "unavailable")) or nil)
    end
    r.state, r.rid = "active", a.id
end

function V.CountClass(world, class)
    local n = 0
    for _, a in pairs(world.actors) do
        if a.role and V.ClassOf(a.role) == class then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------------------------------
-- Where a person was before a visit, so leaving puts them back exactly: their lot and spot on it
-- (residents of other households), their away record, any role another module had given them
-- (kept aside, restored on the way out), and their needs. A visitor's household is paused while
-- another is played (§5.4: inactive households do not secretly age or change), so the needs they
-- had at home come back when the visit ends; what the visit did to relationships stays (those live
-- in the social records, not on the person).
function V.HomeRecord(r)
    local h = { lotId = r.lotId, away = r.away }
    if r.lotId then h.x, h.y, h.level, h.facing = r.x, r.y, r.level or 0, r.facing or 0 end
    if r.role and not V.Owns(r.role) then h.role, h.roleData = r.role, r.roleData end
    if type(r.needs) == "table" then
        local n = {}
        for k, v in pairs(r.needs) do if type(v) == "number" then n[k] = v end end
        h.needs = n
    end
    return h
end
function V.RestoreHome(a, home)
    home = home or {}
    a.lotId, a.away = home.lotId, home.away
    if home.lotId and home.x then a.x, a.y, a.level, a.facing = home.x, home.y, home.level or 0, home.facing or 0 end
    if home.role then a.role, a.roleData = home.role, home.roleData end
    V.RestoreNeeds(a, home)
end
-- Put back the needs saved in a home record (only the needs it holds; nothing when it holds none).
function V.RestoreNeeds(a, home)
    local n = home and home.needs
    if type(n) ~= "table" then return end
    if type(a.needs) ~= "table" then a.needs = {} end
    for k, v in pairs(n) do a.needs[k] = v end
end

---------------------------------------------------------------------------------------------------
-- Spawn: put a person on the lot's street in a role and start the arrival.
-- V.Spawn(world, rid|nil, role, data) -> actor | nil, why. rid nil picks a stable NPC from the role's
-- pool. data as for Request, plus i, j, level (arrive = "none": appear there), side (-1/1: which end
-- of the sidewalk). The actor is in world.actors at once (off the lot until they walk on).
function V.Spawn(world, rid, role, data)
    data = data or {}
    if V.Resident(role) then return nil, "That's a role for people who live here, not a visit." end
    local def = V.roles[role]
    if not def then
        -- an unknown name gets a plain framework role; a role another module keeps in SS.Roles is theirs
        if SS.Roles[role] ~= nil then return nil, "That role isn't a visit." end
        def = V.RegisterRole(role, { label = role })
    end
    local root = world.root
    if not rid then
        local r = V.PoolPick(world, role, data)
        if not r then return nil, "Nobody is available for that." end
        rid = r.id
    end
    local r = root.residents[rid]
    if not r then return nil, "Unknown person." end
    if r.dead and not (def.ghost or data.ghost) then return nil, (r.name or "They") .. " has passed away." end
    if world.actors[rid] then return nil, (r.name or "They") .. " is already here." end
    if not (def.ghost or data.ghost or data.force) then
        local ok, why = V.Available(world, r)
        if not ok then return nil, why end
    end
    local class = V.ClassOf(role)
    if not data.force and data.priority ~= "emergency" and class ~= "emergency"
        and V.CountClass(world, class) >= (TUN.caps[class] or TUN.caps.other) then
        return nil, "There are already too many visitors here."
    end
    local home = V.HomeRecord(r)
    refreshTownie(world, r)
    local mode = data.arrive or def.arrive or ARRIVE_BY_ACCESS[def.access or "guest"] or "door"
    local vs = {
        state = "arriving", since = world.time, mode = mode, home = home,
        invited = data.invited and true or nil, host = data.host, walkIn = (data.walkIn or data.autoEnter) and true or nil,
        req = data.req, welcome = data.welcome and true or nil, gift = data.gift and true or nil, group = data.group,
        stayUntil = data.stayUntil, timeoutAt = timeoutAt(world, def, data.timeout), tries = 0,
    }
    local ei, ej = St.EntryCell(world)
    local a = SS.Sim.AddActor(world, rid, ei, ej, 0)
    if not a then return nil, "They can't come right now." end
    a.role = role
    local rd = {}
    for k, v in pairs(data) do
        local tv = type(v)
        if tv == "string" or tv == "number" or tv == "boolean" then rd[k] = v end
    end
    rd.vs = vs
    a.roleData = rd
    a.noNeeds = def.noNeeds or nil
    a.tmp = {}
    a.cool = nil   -- autonomy cooldowns from an earlier visit (another lot's object ids) never carry over
    if r.npc then a.outfit = "work" end
    if data.gift then a.carry = "gift" end
    V.State(world).lastUsed[rid] = world.time
    V.stats.spawns = V.stats.spawns + 1
    if mode == "none" then
        if data.i and data.j then a.x, a.y, a.level = data.i + 0.5, data.j + 0.5, data.level or 0 end
    elseif mode == "sidewalk" then
        local side = data.side or ((SS.Random(world, "visitors") < 0.5) and -1 or 1)
        local start, path = St.PassPath(world, side)
        a.x, a.y = start[1], start[2]
        vs.side, vs.state = side, "passing"
        St.SetPath(a, path)
        a.tmp.offLot = true
    else
        local kind = data.vehicle
        if kind == nil then kind = def.vehicle end
        local v = kind and St.CallVehicle(world, kind, { owner = "visitor:" .. rid, hold = true, wait = math.min(timeoutFor(def) or TUN.vehicle.maxWait, TUN.vehicle.maxWait),
            passengers = { rid }, livery = data.livery or def.livery })
        if v then
            vs.vehicleKind = kind
            a.tmp.vehicle, a.tmp.inVehicle = v.id, v.id
            a.x, a.y = v.x, v.y
        else
            local side = data.side or ((SS.Random(world, "visitors") < 0.5) and -1 or 1)
            local l, rr = St.SidewalkEnds(world)
            a.x, a.y = side < 0 and l or rr, St.SidewalkY(world)
            vs.side = side
        end
        a.tmp.offLot = true
    end
    SS.Emit("visitorSpawned", world, a, role)
    if mode == "none" then V.OnLot(world, a, vs, def) end
    return a
end

function V.SetState(world, a, vs, st)
    vs.state, vs.since = st, world.time
    vs.tries, vs.nextTry, vs.gotoTag, vs.ordered = 0, nil, nil, nil
    SS.Emit("visitorState", world, a, st)
end

-- Stepped onto the entry cell (or appeared in place).
function V.OnLot(world, a, vs, def)
    vs.onLot, vs.arrivedAt = true, world.time
    if a.tmp then a.tmp.offLot = nil end
    if a.role == "arriving" then return V.FinishArrival(world, a) end
    SS.Emit("visitorArrived", world, a, a.role)
    if def.onArrive then def.onArrive(world, a) end
    if not a.role or not a.roleData or a.roleData.vs ~= vs then return end
    local m = vs.mode
    V.SetState(world, a, vs, (m == "door" or m == "door_enter") and "approach" or "task")
end

-- Start leaving (walk out). why: home, asked, timeout, night, needs, time, nobody, ignored, refused,
-- blocked, done, emergency, goodbye, cancelled... opts.immediate removes them at once (restoring
-- their identity), used for reloads and system resets.
function V.Leave(world, a, why, opts)
    if not a then return false end
    if not a.role then
        -- stub compatibility: a non-role actor asked to leave is simply taken off the lot
        SS.Sim.RemoveActor(world, a.id, { reason = why or "home" })
        return true
    end
    -- a resident role (a pet, a baby) or any role the framework does not run is never sent away here,
    -- nor is a resident walking out or in (the street's own roles finish that walk themselves)
    if not V.Owns(a.role) then return false, V.Resident(a.role) and "They live here." or "They're not a visitor." end
    if V.roles[a.role].internal then return false, "They live here." end
    local rd = a.roleData
    if type(rd) ~= "table" then rd = {}; a.roleData = rd end
    local vs = rd.vs
    if not vs then vs = { state = "task", since = world.time, mode = "none", onLot = true }; rd.vs = vs end
    if opts and opts.immediate then return V.Remove(world, a, why) end
    if vs.state == "leaving" or vs.state == "passing" then return true end
    local def = V.roles[a.role] or {}
    if not vs.leaveCalled then
        vs.leaveCalled = true
        if def.onLeave then def.onLeave(world, a, why) end
        if not a.role then return true end
    end
    if a.act then SS.Actions.Cancel(world, a, 0) end
    if not a.act then a.queue = {} end
    vs.leaveWhy = why or "home"
    V.SetState(world, a, vs, "leaving")
    SS.Emit("visitorLeaving", world, a, why)
    return true
end

-- Remove from the lot now and restore their identity (townies go home, NPCs off duty). A resident
-- role or a role the framework does not run is left alone (returns false); a resident walking out
-- or in finishes that walk instead (their own role comes back).
function V.Remove(world, a, why)
    local rd = a.roleData
    local vs = type(rd) == "table" and rd.vs or {}
    local role = a.role
    if role and not V.Owns(role) then return false, V.Resident(role) and "They live here." or "They're not a visitor." end
    if role == "departing" or role == "arriving" then V.FinishTransit(world, a, vs); return true end
    local def = role and V.roles[role] or {}
    if role and not vs.leaveCalled and def.onLeave then vs.leaveCalled = true; def.onLeave(world, a, why) end
    local home = vs.home
    a.role, a.roleData, a.noNeeds, a.carry, a.cool = nil, nil, nil, nil, nil
    if a.tmp then a.tmp = nil end
    if world.actors[a.id] then SS.Sim.RemoveActor(world, a.id, { reason = why or "home" }) end
    V.RestoreHome(a, home)
    a.balloon = nil
    if a.npc then a.outfit = "work" end
    V.stats.removed = V.stats.removed + 1
    local req = vs.req and V.State(world).requests[vs.req]
    if req and req.state == "active" and req.rid == a.id then req.state, req.why = "done", why end
    if vs.welcome and vs.group then V.WelcomeSettle(world, vs.group) end
    if role and role ~= "walkby" and role ~= "paper" then history(world, (a.name or "?") .. " (" .. ((def.label) or role) .. ") left: " .. tostring(why)) end
    if def.onRemoved then def.onRemoved(world, a, why) end
    SS.Emit("visitorLeft", world, a, role, why)
    return true
end

-- Residents walking out to the street (SS.Street.Depart) and back in (SS.Street.Arrive). While
-- they walk they wear the internal roles "departing" / "arriving". A role another module had given
-- them (a pet's "pet", an infant's "infant") is kept aside in vs.prev and put back when the walk
-- ends, so the street never strips a role it does not own.
function V.ForeignRole(a)
    if a.role and not V.Owns(a.role) then return { role = a.role, roleData = a.roleData } end
    local vs = a.roleData and a.roleData.vs
    return vs and vs.prev or nil
end
function V.RestorePrevRole(a, vs)
    local prev = vs and vs.prev
    a.role, a.roleData = prev and prev.role or nil, prev and prev.roleData or nil
end

function V.BeginDeparture(world, a, away, v)
    if a.act then SS.Actions.Cancel(world, a, 0) end
    if not a.act then a.queue = {} end
    local prev = V.ForeignRole(a)
    a.role = "departing"
    a.roleData = { vs = { state = "leaving", since = world.time, mode = "none", onLot = true, depart = true, away = away,
        leaveWhy = away.reason, timeoutAt = timeoutAt(world, V.roles.departing), tries = 0, invitedIn = true, prev = prev } }
    a.tmp = a.tmp or {}
    a.tmp.vehicle, a.tmp.wp, a.tmp.exitSet = v and v.id, nil, nil
    SS.Emit("streetDeparting", world, a, away.reason)
end

function V.BeginArrival(world, rid, opts)
    local r = world.root.residents[rid]
    if not r or (r.dead and not r.ghost) then return nil end
    r.away = nil
    local prev = V.ForeignRole(r)
    local ei, ej = St.EntryCell(world)
    local a = SS.Sim.AddActor(world, rid, ei, ej, 0)
    if not a then return nil end
    a.role = "arriving"
    a.roleData = { vs = { state = "arriving", since = world.time, mode = "none", reason = opts.reason,
        timeoutAt = timeoutAt(world, V.roles.arriving), tries = 0, prev = prev } }
    a.tmp = {}
    local v = opts.vehicleId and St.VehicleById(opts.vehicleId)
    if not v and opts.vehicle then v = St.CallVehicle(world, opts.vehicle, { owner = "arrive:" .. rid, passengers = { rid } }) end
    if v then
        a.tmp.inVehicle, a.x, a.y = v.id, v.x, v.y
    else
        a.x, a.y = St.CurbPos(world, ei)
    end
    a.tmp.offLot = true
    return a
end

function V.FinishArrival(world, a)
    local vs = a.roleData and a.roleData.vs
    local reason = vs and vs.reason
    V.RestorePrevRole(a, vs)
    if a.tmp then a.tmp.offLot, a.tmp.wp = nil, nil end
    a.pose, a.walking = "idle", nil
    St.stats.arrivals = St.stats.arrivals + 1
    SS.Emit("streetArrived", world, a, reason)
end

-- End a resident's walk out or in at once: someone walking out has left (with their away record),
-- someone walking in is home (put on the entry cell if still on the street). Their own role, if
-- another module gave them one, comes back either way.
function V.FinishTransit(world, a, vs)
    vs = vs or (type(a.roleData) == "table" and a.roleData.vs) or nil
    if a.role == "departing" then return St.FinishDeparture(world, a, vs and vs.away) end
    if a.role == "arriving" then
        if world.actors[a.id] and ((a.tmp and a.tmp.offLot) or St.IsOffLot(world, a.x, a.y)) then
            local ei, ej = St.EntryCell(world)
            a.x, a.y, a.level = ei + 0.5, ej + 0.5, 0
        end
        return V.FinishArrival(world, a)
    end
end

-- A resident who can't get on or off the lot normally: bounded recovery with a diagnostic.
local function forceOntoLot(world, a)
    local lot = world.lot
    local ei, ej = St.EntryCell(world)
    for r = 0, math.max(lot.w, lot.h) do
        for dj = -r, r do
            for di = -r, r do
                local i, j = ei + di, ej + dj
                if W.InLot(lot, i, j) and not W.Blocked(world, 0, i, j) then
                    a.x, a.y, a.level = i + 0.5, j + 0.5, 0
                    SS.Log("visitors: moved %s onto the lot at %d,%d (entry blocked)", a.id, i, j)
                    return true
                end
            end
        end
    end
    return false
end

V.roles.departing.onTimeout = function(world, a)
    local vs = a.roleData.vs
    V.Help(world, a, a.name .. " couldn't get out to the street in time, so they left through the garden (route blocked).")
    St.FinishDeparture(world, a, vs.away)
end
V.roles.arriving.onTimeout = function(world, a)
    forceOntoLot(world, a)
    V.FinishArrival(world, a)
end

---------------------------------------------------------------------------------------------------
-- The state machine
local H = {}
local NO_THINK = { arriving = true, approach = true, door = true, leaving = true, passing = true }

function V.RoleTick(world, a, dt)
    if not V.Owns(a.role) then return end
    local def = V.roles[a.role]
    local rd = a.roleData
    if type(rd) ~= "table" then rd = {}; a.roleData = rd end
    local vs = rd.vs
    if not vs then
        -- a role set by another module without V.Spawn: they are already in place
        vs = { state = "task", since = world.time, mode = "none", onLot = true, invitedIn = true, tries = 0,
            timeoutAt = timeoutAt(world, def) }
        rd.vs = vs
    end
    a.tmp = a.tmp or {}
    if NO_THINK[vs.state] or not def.useAutonomy then a.nextThink = world.time + 1 end
    if vs.timeoutAt and world.time >= vs.timeoutAt and vs.state ~= "leaving" and vs.state ~= "passing" then
        vs.timeoutAt = nil
        if def.onTimeout then def.onTimeout(world, a) else V.Leave(world, a, "timeout") end
        return
    end
    local h = H[vs.state]
    if h then h(world, a, vs, def, dt) end
end

local function entryBlocked(world, a, vs, def)
    vs.tries = (vs.tries or 0) + 1
    V.stats.routeFails = V.stats.routeFails + 1
    if vs.tries >= TUN.entryRetries then
        if a.role == "arriving" then
            V.Help(world, a, a.name .. " couldn't get onto the lot from the street (every entry cell is blocked).")
            forceOntoLot(world, a)
            return V.FinishArrival(world, a)
        end
        if def.onBlocked then def.onBlocked(world, a) end
        if not a.role then return end
        V.Say(world, a, "visitor_refused", { reason = "blocked" })
        V.Help(world, a, a.name .. " couldn't get onto the lot: everything along the street is blocked.")
        return V.Leave(world, a, "blocked")
    end
    vs.nextTry = world.time + TUN.entryCooldown
    if vs.tries == 2 then V.Say(world, a, "visitor_wait", { reason = "blocked", waitMin = math.floor(world.time - (vs.since or world.time)) }) end
end

H.arriving = function(world, a, vs, def, dt)
    local tmp = a.tmp
    if tmp.inVehicle then
        local v = St.VehicleById(tmp.inVehicle)
        if v and v.state == "arriving" then a.x, a.y, a.pose = v.x, v.y, "idle"; return end
        tmp.inVehicle = nil
        if v then a.x, a.y = St.CurbPos(world, v.i) else a.x, a.y = St.CurbPos(world, (St.EntryCell(world))) end
    end
    if not tmp.wp then
        if vs.nextTry and world.time < vs.nextTry then a.pose = "idle"; return end
        local wp = St.ArrivalPath(world, a)
        if not wp then return entryBlocked(world, a, vs, def) end
        St.SetPath(a, wp)
    end
    if St.FollowPath(world, a, dt) then V.OnLot(world, a, vs, def) end
end

H.passing = function(world, a, vs, def, dt)
    if def.onPass then
        def.onPass(world, a, vs, dt)
        if a.role == nil or not a.roleData or a.roleData.vs ~= vs or vs.state ~= "passing" then return end
    end
    if not a.tmp.wp then return V.Remove(world, a, "passed") end
    if St.FollowPath(world, a, dt) then V.Remove(world, a, "passed") end
end

-- Ring the doorbell (a `doorbell` object on the lot) or knock.
function V.Ring(world, a, vs)
    vs.rings, vs.lastRing = (vs.rings or 0) + 1, world.time
    local bell = V.Doorbell(world)
    if bell then
        bell.state = bell.state or {}
        bell.state.ringing = true
        bell.ringUntil = world.time + 1 -- the shared object tick silences a ringing object without it
        V.ringingBell = { oid = bell.id, untilT = world.time + 1 }
        sfx(RD.sfx.doorbell)
    else
        sfx(RD.sfx.knock)
    end
    a.balloon = { kind = "alert", icon = "ring", untilT = world.time + 3 }
    SS.Emit("doorbell", world, a, bell)
end

function V.AtDoor(world, a, vs, def, door)
    vs.atDoorAt = world.time
    if door and door.inside then
        a.facing = G.dirToFacing(door.inside[1] - door.stand[1], door.inside[2] - door.stand[2])
    end
    V.Ring(world, a, vs)
    SS.Emit("visitorAtDoor", world, a, a.role)
    if def.onDoor then def.onDoor(world, a) end
    if not a.role or a.roleData.vs ~= vs then return end
    if vs.mode == "door_enter" then
        vs.invitedIn = true
        return V.SetState(world, a, vs, "task")
    end
    V.SetState(world, a, vs, "door")
    vs.doorUntil = world.time + (def.doorWait or (vs.invited and TUN.doorWaitInvited or TUN.doorWait))
    local label = (def.label or a.role):lower()
    local text = a.name .. (vs.welcome and " and some neighbours are at the door to welcome you."
        or vs.invited and " has arrived and is at the door."
        or (" is at the door (" .. label .. ")."))
    V.Notice(world, nil, text)
    if vs.invited or vs.welcome or def.important then SS.Sim.Emergency(world, text, "info") end
    V.SummonAnswer(world, a, vs)
end

-- Invited guests, the welcome party and food couriers get the door answered: with free will on, the
-- nearest free household member drops an optional activity and goes to the door (at most one member
-- per ring, a few tries per visitor). Uninvited callers rely on ordinary autonomy (door candidates).
local NO_INTERRUPT = { toilet = true, shower = true, bath = true, sleep = true, nap = true, cook = true,
    eat = true, drink = true, eat_meal = true, eat_snack = true, eat_delivery = true, eat_treat = true }
local EAT_POSES = { eat = true, eat_stand = true, sit_eat = true }
V.NO_INTERRUPT = NO_INTERRUPT
-- Is this action something a member should not be pulled out of to answer the door or chat
-- (bathroom, sleep, cooking, eating or drinking)? Honours household-core's ia.noInterrupt too.
function V.NoInterrupt(act)
    if not act then return false end
    if act.manual or NO_INTERRUPT[act.iid] then return true end
    local ia = SS.Interactions[act.iid]
    if not ia then return false end
    return (ia.sleeping or ia.noInterrupt or ia.privacy or EAT_POSES[ia.pose or ""]) and true or false
end
function V.SummonAnswer(world, v, vs)
    if vs.greeted or (vs.summons or 0) >= 3 then return nil end
    if not (vs.invited or vs.welcome or v.role == "courier" or (V.roles[v.role] or {}).summon) then return nil end
    if not (world.settings and world.settings.freeWill) then return nil end
    if V.BeingAnswered(world, v) then return nil end
    vs.summons = (vs.summons or 0) + 1
    local iid = (v.role == "courier") and "door_pay" or "door_greet"
    local best, bestD
    for _, m in ipairs(V.MembersPresent(world)) do
        local busy = m.sleeping or V.NoInterrupt(m.act) or (m.queue and m.queue[1] and m.queue[1].manual)
        if m.age ~= "infant" and not busy and SS.Actions.Available(world, m, v, iid) then
            local d = math.abs(m.x - v.x) + math.abs(m.y - v.y) + ((m.level or 0) ~= 0 and 6 or 0)
            if not bestD or d < bestD or (d == bestD and m.id < best.id) then best, bestD = m, d end
        end
    end
    if not best then return nil end
    if best.act then SS.Actions.Cancel(world, best, 0) end
    best.queue = best.queue or {}
    table.insert(best.queue, 1, { tid = v.id, iid = iid, manual = false })
    SS.Emit("visitorAnswering", world, v, best)
    return best
end

function V.CannotReach(world, a, vs, def)
    if def.onBlocked then def.onBlocked(world, a) end
    if not a.role then return end
    V.Say(world, a, "visitor_refused", { reason = "blocked" })
    V.Help(world, a, a.name .. " couldn't reach the front door (the way is blocked) and left.")
    V.Leave(world, a, "blocked")
end

H.approach = function(world, a, vs, def)
    if V.Busy(a) then return end
    local door = V.DoorFor(world, vs)
    local res = V.Goto(world, a, vs, { door.stand }, "door" .. tostring(vs.doorIdx or 1))
    if res == "arrived" then return V.AtDoor(world, a, vs, def, door) end
    if res == "failed" then
        if (vs.doorIdx or 1) < #V.Doors(world) then vs.doorIdx = (vs.doorIdx or 1) + 1; return end
        return V.CannotReach(world, a, vs, def)
    end
    if res == "wait" and (vs.tries or 0) >= 2 and not vs.saidWait then
        vs.saidWait = true
        V.Say(world, a, "visitor_wait", { reason = "blocked", waitMin = math.floor(world.time - (vs.since or world.time)) })
    end
end

-- Nobody answered the door in time.
function V.Ignored(world, a, vs, def)
    SS.Emit("visitorIgnored", world, a)
    if def.onIgnored and def.onIgnored(world, a) then
        if a.role then V.Leave(world, a, "ignored") end
        return
    end
    local hh = world.household
    -- Nobody was home the whole time (everyone at work or out): an uninvited caller can't hold that
    -- against them. Standing up someone you invited still counts.
    local nobody = not vs.homeSeen and not V.AnyMemberPresent(world)
    if vs.invited or not nobody then
        for _, mid in ipairs(hh and hh.members or {}) do relChange(world, a.id, mid, TUN.rel.ignored) end
    end
    V.Say(world, a, "visitor_refused", { reason = "ignored", invited = vs.invited })
    if vs.gift and not vs.giftGiven then V.GiveGift(world, nil, a, vs) end
    if nobody then
        V.Notice(world, nil, "Nobody was home, so " .. a.name .. " went home.")
    else
        V.Notice(world, nil, "Nobody answered the door, so " .. a.name .. " went home.")
    end
    if vs.welcome and hh then hh.flags = hh.flags or {}; hh.flags.welcomed = true end
    V.Leave(world, a, "ignored")
end

H.door = function(world, a, vs, def)
    local t = world.time
    if not V.Busy(a) and (not a.balloon or a.balloon.kind ~= "speech") then a.pose = "idle" end
    if not vs.greeted then
        if not vs.homeSeen and V.AnyMemberPresent(world) then vs.homeSeen = true end
        if vs.invited and vs.walkIn and t - vs.since >= TUN.walkInDelay then return V.LetIn(world, a, vs, nil) end
        if vs.invited and t - vs.since >= TUN.friendLetIn and V.CloseFriend(world, a.id) then return V.LetIn(world, a, vs, nil) end
        if (vs.rings or 0) < TUN.maxRings and t - (vs.lastRing or t) >= TUN.reRing then
            V.Ring(world, a, vs)
            V.SummonAnswer(world, a, vs)
        end
        if not vs.saidWait and t >= vs.since + (vs.doorUntil - vs.since) / 2 then
            vs.saidWait = true
            V.Say(world, a, "visitor_wait", { invited = vs.invited, rings = vs.rings, waitMin = math.floor(t - vs.since) })
            V.Notice(world, nil, a.name .. " is still waiting at the door.")
        end
    end
    if t >= (vs.doorUntil or t) then
        if vs.greeted then
            V.Say(world, a, "farewell", {})
            return V.Leave(world, a, "goodbye")
        end
        return V.Ignored(world, a, vs, def)
    end
end

-- Should a visiting guest go home? Returns a reason or nil.
function V.ShouldGo(world, a, vs)
    if SS.Fire and SS.Fire.Active and SS.Fire.Active(world) then return "emergency" end
    local t = world.time
    if vs.stayUntil then
        if t >= vs.stayUntil then return "time" end
    else
        if vs.leaveAt and t >= vs.leaveAt then return "time" end
        local h = hourOf(t)
        if h >= TUN.nightStart or h < TUN.nightEnd then return "night" end
    end
    if not a.noNeeds and a.needs then
        if (a.needs.energy or 0) < TUN.leaveEnergy or (a.needs.hunger or 0) < TUN.leaveHunger then return "needs" end
        if SS.Needs and SS.Needs.Mood and SS.Needs.Mood(a) < TUN.leaveMood then return "needs" end
    end
    if world.household and #V.MembersPresent(world) == 0 then
        vs.aloneSince = vs.aloneSince or t
        if t - vs.aloneSince >= TUN.nobodyHome then return "nobody" end
    else
        vs.aloneSince = nil
    end
end

-- Keep guests out of private rooms, other people's beds, and a bathroom someone else is in, by
-- cooling those candidates in the executor's autonomy table (actor.cool) before they are chosen.
local GUEST_NEVER = { phone_answer = true, recycle_paper = true, toss_delivery = true, lampon = true, lampoff = true }
function V.GuestCooldowns(world, a)
    a.cool = a.cool or {}
    local info = V.RoomInfo(world)
    local t = world.time
    local lot = world.lot
    for oid, o in pairs(lot.objects) do
        local def = SS.Objects[o.def]
        if def and def.actions and #def.actions > 0 then
            local lv = o.level or 0
            local room = (lv < W.LEVELS and W.InLot(lot, o.x, o.y)) and W.RoomAt(world, lv, o.x, o.y) or 0
            local private = info.private[lv] and info.private[lv][room]
            local occ = info.bath[lv] and info.bath[lv][room] and V.bathOcc[lv] and V.bathOcc[lv][room]
            local busyBath = occ and occ ~= a.id
            if info.hasStaff and (info.staff[lv][room] or def.staffOnly) then private = true end
            for _, iid in ipairs(def.actions) do
                local ia = SS.Interactions[iid]
                -- never: private rooms, sleeping, household-only actions, and anything that costs the
                -- household money (guests eat what is served, delivered or brought, not the fridge)
                if private or GUEST_NEVER[iid] or (ia and (ia.sleeping or ia.guestForbidden or ia.householdOnly or (ia.cost or 0) > 0)) then
                    a.cool[oid .. ":" .. iid] = t + 30
                elseif busyBath then
                    a.cool[oid .. ":" .. iid] = t + 6
                end
            end
        end
    end
end

-- Now and then a guest wanders off to admire the most expensive ornament (while the host talks).
function V.MaybeAdmire(world, a, vs)
    if (vs.nextAdmire or 0) > world.time or V.Busy(a) then return end
    vs.nextAdmire = world.time + TUN.admireCool
    if SS.Random(world, "visitors") > 0.5 then return end
    local info = V.RoomInfo(world)
    local best, bestP
    for _, oid in ipairs(sortedIds(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and def.cat ~= "system" and (def.price or 0) >= TUN.admirePrice and (def.cat == "decor" or (def.env or 0) >= 5) then
            local lv = o.level or 0
            local room = W.InLot(world.lot, o.x, o.y) and W.RoomAt(world, lv, o.x, o.y) or 0
            if not (info.private[lv] and info.private[lv][room]) and (not bestP or def.price > bestP) then best, bestP = o, def.price end
        end
    end
    if best and V.Reachable(world, a, best, "guest_admire") then
        SS.Actions.Order(world, a, best.id, "guest_admire")
    end
end

-- Guests keep their own free will even when the player has switched the household's off (the
-- executor's Think only runs with settings.freeWill; see docs/requests/visitors.md).
local function guestThink(world, a)
    local st = world.settings
    if not st or st.freeWill or V.Busy(a) or (a.nextThink or 0) > world.time then return end
    st.freeWill = true
    local ok, err = pcall(SS.Actions.Think, world, a)
    st.freeWill = false
    if not ok then SS.Log("visitors: guest think failed: %s", tostring(err)) end
end

H.visit = function(world, a, vs, def, dt)
    if def.tick then
        def.tick(world, a, dt)
        if not a.role or not a.roleData or a.roleData.vs ~= vs or vs.state ~= "visit" then return end
    end
    if world.time >= (vs.nextCheck or 0) then
        vs.nextCheck = world.time + TUN.checkEvery
        V.GuestCooldowns(world, a)
        local why = V.ShouldGo(world, a, vs)
        if why then
            if why ~= "emergency" then V.Say(world, a, "farewell", { reason = why }) end
            if why == "time" or why == "night" then
                if not a.noNeeds and SS.Needs and SS.Needs.Mood and SS.Needs.Mood(a) > 20 and vs.host then
                    relChange(world, a.id, vs.host, TUN.rel.goodVisit)
                end
            end
            return V.Leave(world, a, why)
        end
        V.MaybeAdmire(world, a, vs)
    end
    if def.useAutonomy then guestThink(world, a) end
end

H.task = function(world, a, vs, def, dt)
    if def.tick then def.tick(world, a, dt) end
end

-- The departing resident's ride left without them: they walk back onto the lot.
local function missedRide(world, a, vs)
    St.stats.missed = St.stats.missed + 1
    local away = vs.away or {}
    V.Notice(world, a, a.name .. " missed their ride.", "noroute")
    SS.Emit("streetMissed", world, a, away.reason, away.data)
    a.role = "arriving"
    a.roleData = { vs = { state = "arriving", since = world.time, mode = "none", reason = "missed", tries = 0,
        timeoutAt = timeoutAt(world, V.roles.arriving), prev = vs.prev } }
    a.tmp.wp, a.tmp.exitSet, a.tmp.vehicle = nil, nil, nil
end

-- Off the lot: walk to the vehicle / curb / end of the sidewalk, then board or disappear.
function V.StreetExit(world, a, vs, dt)
    local tmp = a.tmp
    if not tmp.exitSet then
        local v = St.VehicleById(tmp.vehicle)
        if not v and vs.vehicleKind and not vs.depart then
            local def = V.roles[a.role] or {}
            v = St.CallVehicle(world, vs.vehicleKind, { owner = "visitor:" .. a.id, hold = true, wait = 30, livery = def.livery })
            tmp.vehicle = v and v.id
        end
        local target
        if v then target = { kind = "vehicle", i = v.i }
        elseif vs.depart then target = { kind = "curb" }
        else target = { kind = "end", side = vs.side or ((a.x < world.lot.w / 2) and -1 or 1) } end
        St.SetPath(a, St.ExitPath(world, a, target))
        tmp.exitSet, tmp.exitTarget = true, target.kind
    end
    if not St.FollowPath(world, a, dt) then return end
    if tmp.exitTarget == "vehicle" then
        local v = St.VehicleById(tmp.vehicle)
        if v and v.state == "arriving" then a.pose = "idle"; return end
        if not v or v.state == "leaving" then
            if vs.depart then return missedRide(world, a, vs) end
            tmp.exitSet, tmp.vehicle, vs.vehicleKind = nil, nil, nil
            return
        end
        St.BoardOne(world, v, a)
        if not vs.depart and v.owner == "visitor:" .. a.id then St.ReleaseVehicle(world, v) end
    end
    if vs.depart then return St.FinishDeparture(world, a, vs.away) end
    return V.Remove(world, a, vs.leaveWhy)
end

local function stuckInside(world, a, vs, def)
    V.Help(world, a, a.name .. " couldn't find a way out to the street, so they were shown out. Check for blocked doors or paths.")
    if vs.depart then return St.FinishDeparture(world, a, vs.away) end
    V.Remove(world, a, vs.leaveWhy or "blocked")
end

H.leaving = function(world, a, vs, def, dt)
    if not vs.onLot then return V.StreetExit(world, a, vs, dt) end
    if a.act then return end
    -- drop anything queued that isn't the walk out (chains from an interrupted action)
    if a.queue and #a.queue > 0 then
        local q = a.queue[1]
        if not (q.iid == "goto" and q.data and q.data.visitorGoto) then a.queue = {} else return end
    end
    local goals = St.EntryCells(world)
    if #goals == 0 then
        local ei, ej = St.EntryCell(world)
        goals = { { ei, ej, 0 } }
    end
    local res = V.Goto(world, a, vs, goals, "exit", TUN.exitRetries, TUN.exitCooldown)
    if res == "arrived" then
        vs.onLot = false
        a.tmp.offLot = true
        return V.StreetExit(world, a, vs, dt)
    elseif res == "failed" then
        return stuckInside(world, a, vs, def)
    end
end

---------------------------------------------------------------------------------------------------
-- Greeting, inviting in, asking to leave (household member -> visitor).
function V.CanAnswer(world, m, t, how)
    if not V.IsMember(world, m) or not human(m) then return false, "Only household members can do that." end
    if m.age == "infant" then return false, "Too young for that." end
    if not t or not V.Owns(t.role) then return false, "They live here." end
    local vs = t.roleData and t.roleData.vs
    if not vs then return false, "They're busy." end
    if not vs.onLot or (t.tmp and t.tmp.offLot) then return false, "They're still out on the street." end
    local acc = V.AccessOf(t.role)
    local guestLike = acc == "guest" or acc == "public"
    if how == "greet" then
        if not guestLike then return false, "They're here on business." end
        if vs.state == "approach" or vs.state == "arriving" then return false, "They haven't reached the door yet." end
        if vs.state ~= "door" then return false, "They're already inside." end
        if vs.greeted then return false, "Already greeted." end
        return true
    elseif how == "invite" then
        if not guestLike then return false, "They're here on business." end
        if m.age == "child" then return false, "Only adults can invite visitors in." end
        if vs.state ~= "door" then return false, "They're not waiting at the door." end
        return true
    elseif how == "ask" then
        if acc == "emergency" or acc == "intruder" or acc == "household" or acc == "staff" then return false, "You can't send them away." end
        if acc == "service" and t.role ~= "courier" and t.role ~= "mail" then return false, "Use Send Home to dismiss a service worker." end
        if m.age == "child" then return false, "Only adults can ask visitors to leave." end
        if vs.state == "leaving" or vs.state == "passing" then return false, "They're already leaving." end
        return true
    end
    return false, "Not possible."
end

-- Group members (a welcome party) waiting together.
local function groupOf(world, v)
    local vs = v.roleData.vs
    if not vs.group then return { v } end
    local out = {}
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        local s = a.role and a.roleData and a.roleData.vs
        if s and s.group == vs.group and s.state == "door" then out[#out + 1] = a end
    end
    if #out == 0 then out[1] = v end
    return out
end

function V.LetIn(world, v, vs, member)
    local def = V.roles[v.role] or {}
    vs.invitedIn = true
    if member then relChange(world, v.id, member.id, TUN.rel.invite) end
    local nextState = def.afterDoor or (def.tick and "task" or "visit")
    if nextState == "visit" and not vs.leaveAt then
        vs.leaveAt = world.time + SS.RandomInt(world, "visitors", TUN.visitMin, TUN.visitMax)
    end
    V.SetState(world, v, vs, nextState)
    if def.onLetIn then def.onLetIn(world, v, member) end
    SS.Emit("visitorLetIn", world, v, member)
    return true
end

function V.GiveGift(world, member, v, vs)
    local carrier
    for _, a in ipairs(groupOf(world, v)) do
        local s = a.roleData.vs
        if s.gift and not s.giftGiven then carrier = a end
    end
    if not carrier then return end
    local cvs = carrier.roleData.vs
    cvs.giftGiven = true
    carrier.carry = nil
    local door = V.DoorFor(world, cvs)
    local placed
    if member then
        placed = V.PlaceOnSurface(world, "welcome_treats", { math.floor(member.x), math.floor(member.y), member.level or 0 })
    end
    if not placed then placed = V.PlaceNear(world, "welcome_treats", door.stand, { outdoor = not member }) end
    if not placed and SS.Inventory and SS.Inventory.Add then
        SS.Inventory.Add(world, { kind = "gift", name = RD.text.objects.welcome_treats.name, value = 15, data = { from = carrier.id } })
    end
    if member then relChange(world, member.id, carrier.id, TUN.rel.gift) end
    local text = member and (carrier.name .. " brought a plate of welcome treats.")
        or (carrier.name .. " left a plate of welcome treats on the doorstep.")
    V.Notice(world, nil, text)
    V.Journal(world, "The neighbours came to welcome the household. " .. text)
    SS.Emit("visitorGift", world, carrier, member, placed)
end

-- Outcome of a door interaction. how = "greet" | "invite" | "ask".
function V.OnGreet(world, member, v, how)
    local vs = v.roleData and v.roleData.vs
    if not vs then return false, "They're not visiting." end
    local def = V.roles[v.role] or {}
    v.facing = G.dirToFacing(member.x - v.x, member.y - v.y)
    member.facing = G.dirToFacing(v.x - member.x, v.y - member.y)
    if how == "ask" then return V.AskToLeave(world, member, v) end
    local group = groupOf(world, v)
    for _, g in ipairs(group) do
        local gs = g.roleData.vs
        if not gs.greeted then
            gs.greeted, gs.greetedBy = true, member.id
            gs.doorUntil = world.time + TUN.doorWaitGreeted
            relChange(world, g.id, member.id, TUN.rel.greet)
            relChange(world, member.id, g.id, TUN.rel.greet)
            g.pose = "greet"
            SS.Emit("visitorGreeted", world, g, member)
            if def.onGreet then def.onGreet(world, g, member, how) end
        end
    end
    V.Say(world, v, "visitor_greet", { host = member.id, listener = member.id, invited = vs.invited, welcome = vs.welcome }, nil, "social")
    -- the welcome party introduces itself through the social module's own conversation (guarded)
    if vs.welcome and not vs.introduced and SS.Conversation and SS.Conversation.Start then
        vs.introduced = true
        pcall(SS.Conversation.Start, world, v, member, "introduce", false)
    end
    if vs.welcome then
        local hh = world.household
        if hh then hh.flags = hh.flags or {}; hh.flags.welcomed = true end
        V.GiveGift(world, member, v, vs)
    end
    if how == "invite" or vs.invited then
        for _, g in ipairs(group) do
            if g.role and g.roleData.vs.state == "door" then V.LetIn(world, g, g.roleData.vs, member) end
        end
    end
    return true
end

function V.AskToLeave(world, member, v)
    local vs = v.roleData.vs
    local atDoor = vs.state == "door" or vs.state == "approach"
    if atDoor then
        V.Say(world, v, "visitor_refused", { host = member.id, listener = member.id, invited = vs.invited })
        relChange(world, v.id, member.id, vs.invited and TUN.rel.refusedInvited or TUN.rel.refused)
    else
        V.Say(world, member, "ask_leave", { target = v.id })
    end
    SS.Emit("visitorRefused", world, v, member)
    for _, g in ipairs(atDoor and groupOf(world, v) or { v }) do V.Leave(world, g, "asked") end
    return true
end

local function doorInteraction(label, how, pose)
    return {
        label = label, category = "Visitors", targetActor = true, pose = pose or "greet", dur = 3, manualOnly = true,
        test = function(world, actor, target) return V.CanAnswer(world, actor, target, how) end,
        onStart = function(world, actor, act)
            local v = world.actors[act.tid]
            if not v or not v.role then return false, "They've gone." end
            local ok, why = V.CanAnswer(world, actor, v, how)
            if not ok then return false, why end
            return V.OnGreet(world, actor, v, how)
        end,
    }
end
SS.Interactions.door_greet = doorInteraction("Greet", "greet", "greet")
SS.Interactions.door_invite = doorInteraction("Invite In", "invite", "greet")
SS.Interactions.door_ask = doorInteraction("Ask to Leave", "ask", "talk")
V.DOOR_IIDS = { door_greet = true, door_invite = true, door_ask = true, door_pay = true, door_dismiss = true }

-- Someone in the household is already on their way to this visitor?
function V.BeingAnswered(world, v)
    for id, a in pairs(world.actors) do
        if not a.role then
            if a.act and a.act.tid == v.id and V.DOOR_IIDS[a.act.iid] then return a end
            for _, q in ipairs(a.queue or {}) do if q.tid == v.id and V.DOOR_IIDS[q.iid] then return a end end
        end
    end
end

-- Walk-by -> door visitor ("Invite Over" from the menu, or a friendly neighbour dropping by).
function V.CallOver(world, member, walker)
    if not walker or walker.role ~= "walkby" then return false, "They're not passing by." end
    if V.CountClass(world, "social") >= TUN.caps.social then return false, "There are already too many guests here." end
    local vs = walker.roleData.vs
    walker.role = "guest"
    walker.noNeeds = nil
    vs.mode, vs.invited, vs.host = "door", member and true or nil, member and member.id or nil
    vs.timeoutAt = timeoutAt(world, V.roles.guest)
    walker.tmp.wp = nil
    V.SetState(world, walker, vs, "arriving")
    if member then
        member.balloon = { kind = "speech", icon = "social", text = nil, untilT = world.time + 5 }
        V.Notice(world, nil, member.name .. " waved " .. walker.name .. " over.")
    end
    SS.Emit("visitorCalledOver", world, walker, member)
    return true
end

---------------------------------------------------------------------------------------------------
-- Visitor kinds

-- Invited friend (phone call or the social "Invite Over"). Returns ok, message, requestId.
function V.Invite(world, host, rid, opts)
    opts = opts or {}
    local r = world.root.residents[rid]
    if not r then return false, "Unknown person." end
    local ok, why = V.Available(world, r)
    if not ok then return false, why end
    local key = "guest:" .. rid
    local openId = V.OpenRequest(world, key)
    if openId then return false, r.name .. " is already on the way.", openId end
    local h = hourOf(world.time)
    if not opts.force and (h < TUN.invite.earliest or h >= TUN.invite.latest) then
        return false, "It's too late to invite anyone over. Try between " .. TUN.invite.earliest .. " AM and " .. (TUN.invite.latest - 12) .. " PM."
    end
    if not opts.force then
        local d, l = V.RelPeek(world, rid, host.id)
        local out = (r.personality and r.personality.outgoing or 5) - 5
        local p = U.clamp(TUN.invite.baseAccept + (d + l) / 250 + out * 0.03, 0.1, 0.97)
        if SS.Random(world, "visitors") > p then
            SS.Emit("visitorDeclined", world, host, r)
            return false, r.name .. " can't make it right now."
        end
    end
    local at = world.time + (opts.lead or TUN.invite.lead)
    local id, why2 = V.Request(world, "guest", { rid = rid, at = at, window = opts.window or TUN.invite.window, invited = true,
        host = host.id, key = key, walkIn = opts.walkIn, stayUntil = opts.stayUntil, party = opts.party })
    if not id then return false, why2 end
    local req = V.State(world).requests[id]
    return true, r.name .. " is coming over (around " .. clockText(req.at) .. ").", id
end

-- Hourly: a friend may drop by uninvited (cooldowns and friendship-based chance).
function V.MaybeSocialCall(world)
    local S = TUN.social
    local st = V.State(world)
    if (st.cool.social or -1e9) > world.time then return end
    if V.CountClass(world, "social") > 0 then return end
    if SS.Fire and SS.Fire.Active and SS.Fire.Active(world) then return end
    if not V.AnyMemberPresent(world) then return end -- nobody home (at work, out): no one to call on
    local best, bestS
    for _, r in ipairs(V.Candidates(world)) do
        if (st.cool["p:" .. r.id] or -1e9) <= world.time then
            local s = V.BestRel(world, r.id)
            if s >= S.minRel and (not bestS or s > bestS) then best, bestS = r, s end
        end
    end
    if not best then return end
    local chance = S.base + S.relBonus * math.min(bestS, 100) / 100
    if SS.Random(world, "visitors") >= chance then return end
    st.cool.social = world.time + S.globalCool
    st.cool["p:" .. best.id] = world.time + S.personCool
    return V.Request(world, "guest", { rid = best.id, delay = 5, window = 45, key = "guest:" .. best.id, spontaneous = true })
end

-- Move-in welcome: 2-3 neighbours with a gift, arriving together in the daytime.
-- Flags on the household (saved): welcomeDue (a welcome is owed), welcomeScheduled (a party is on
-- its way), welcomed (it happened: greeted, or ignored at the door and the treats left on the step),
-- welcomeTries (attempts, at most tuning.welcome.maxTries), welcomeRetryAt (earliest next attempt).
-- A party that never reached the door (stale, capped, blocked, a lot switch) clears welcomeScheduled
-- so a later hour schedules another one; after maxTries the welcome is dropped for good.
function V.ScheduleWelcome(world)
    local hh = world.household
    if not hh or not V.HomeLot(world) then return false end
    hh.flags = hh.flags or {}
    local f = hh.flags
    if f.welcomed or f.welcomeScheduled then return false end
    local C = TUN.welcome
    if (f.welcomeTries or 0) >= (C.maxTries or 3) then return false end
    f.welcomeTries = (f.welcomeTries or 0) + 1
    local cands = {}
    for _, r in ipairs(V.Candidates(world)) do if r.age ~= "child" then cands[#cands + 1] = r end end
    if #cands == 0 then
        f.welcomeRetryAt = world.time + (C.retryGap or 360)
        return false, "nobody"
    end
    local n = math.min(#cands, SS.RandomInt(world, "visitors", C.min, C.max))
    local picked = {}
    for k = 1, n do
        local idx = SS.RandomInt(world, "visitors", 1, #cands)
        picked[#picked + 1] = table.remove(cands, idx)
    end
    local t = world.time
    local h = hourOf(t)
    local at
    if h >= C.earliest and h < C.latest - 2 then at = t + SS.RandomInt(world, "visitors", 60, 120)
    else
        local day = math.floor(t / 1440) + ((h >= C.earliest) and 1 or 0)
        at = day * 1440 + C.earliest * 60 + SS.RandomInt(world, "visitors", 0, 120)
    end
    local group = "welcome:" .. hh.id
    local placed = 0
    for k, r in ipairs(picked) do
        local id = V.Request(world, "guest", { rid = r.id, at = at + (k - 1), key = "guest:" .. r.id, welcome = true, gift = (placed == 0),
            group = group, vehicle = false, side = 1 })
        if id and V.State(world).requests[id].data.welcome then placed = placed + 1 end
    end
    if placed == 0 then
        f.welcomeRetryAt = world.time + (C.retryGap or 360)
        return false, "nobody"
    end
    f.welcomeScheduled, f.welcomeRetryAt = true, nil
    return true, at
end

-- Is anyone from this welcome party still expected or here?
local function welcomeOpen(world, group)
    local s = V.State(world)
    for _, id in ipairs(sortedIds(s.requests)) do
        local r = s.requests[id]
        if r.data.group == group and r.data.welcome and (r.state == "pending" or r.state == "active") then
            if r.state == "pending" then return true end
            local a = r.rid and world.actors[r.rid]
            if a and a.role then return true end
        end
    end
    return false
end
-- A welcome visitor or request ended. If the party is over and the welcome never happened, free the
-- schedule so a later hour tries again (bounded by maxTries).
function V.WelcomeSettle(world, group)
    local hh = world and world.household
    if not hh or type(group) ~= "string" or group ~= "welcome:" .. hh.id then return end
    local f = hh.flags or {}
    hh.flags = f
    if f.welcomed or not f.welcomeScheduled then return end
    if welcomeOpen(world, group) then return end
    f.welcomeScheduled = nil
    f.welcomeRetryAt = world.time + (TUN.welcome.retryGap or 360)
    SS.Emit("welcomeMissed", world, hh.id, f.welcomeTries or 0)
end
SS.On("visitorCancelled", function(world, r)
    if world and r and r.data and r.data.welcome then V.WelcomeSettle(world, r.data.group) end
end)

-- A household that just moved in (hood sets flags.movedInAt and emits "movedIn"), or a brand-new
-- game's household in its first days, is owed a welcome visit; it is scheduled (and retried) hourly.
function V.CheckWelcome(world)
    local hh = world.household
    if not hh or not V.HomeLot(world) then return end
    hh.flags = hh.flags or {}
    local f = hh.flags
    if f.welcomed then return end
    if not f.welcomeDue then
        local moved = f.movedInAt
        if (moved and world.time - moved < 3 * 1440) or (not moved and not f.visitorsSeen and world.time < TUN.welcome.newGameDays * 1440) then
            f.welcomeDue = true
        end
    end
    f.visitorsSeen = true
    if f.welcomeDue and not f.welcomeScheduled and (f.welcomeTries or 0) < (TUN.welcome.maxTries or 3)
        and world.time >= (f.welcomeRetryAt or 0) then
        V.ScheduleWelcome(world)
    end
end
SS.On("movedIn", function(world, hhId)
    if not world or not world.household or world.household.id ~= hhId then return end
    local f = world.household.flags or {}
    world.household.flags = f
    f.movedInAt = f.movedInAt or world.time
    if not f.welcomed then f.welcomeDue = true end
    V.CheckWelcome(world)
end)

-- Walk-bys: persistent townies passing on the sidewalk (never a copy, never someone dead or away).
function V.SpawnWalkby(world, rid)
    if V.CountClass(world, "walkby") >= TUN.caps.walkby then return nil end
    local st = V.State(world)
    local pick
    if rid then
        pick = world.root.residents[rid]
    else
        local cands = {}
        for _, r in ipairs(V.Candidates(world)) do
            if (st.cool["w:" .. r.id] or -1e9) <= world.time then cands[#cands + 1] = r end
        end
        pick = SS.Pick(world, "visitors", cands)
    end
    if not pick then return nil end
    st.cool["w:" .. pick.id] = world.time + TUN.walkby.personCool
    local a = V.Spawn(world, pick.id, "walkby", {})
    if a then V.stats.walkbys = V.stats.walkbys + 1 end
    return a
end

V.roles.walkby.onPass = function(world, a, vs)
    if vs.waved or world.time < (vs.nextLook or 0) then return end
    vs.nextLook = world.time + 1
    for _, m in ipairs(V.MembersPresent(world)) do
        local i, j = math.floor(m.x), math.floor(m.y)
        if (m.level or 0) == 0 and W.InLot(world.lot, i, j) and W.RoomAt(world, 0, i, j) == 0
            and math.abs(m.x - a.x) <= 3 and m.y >= world.lot.h - 4 then
            local s = V.BestRel(world, a.id)
            if s >= 0 then
                vs.waved = true
                a.balloon = { kind = "speech", icon = "social", untilT = world.time + 4 }
                V.Say(world, a, "greet", { target = m.id, passing = true })
                relChange(world, a.id, m.id, TUN.rel.wave)
                relChange(world, m.id, a.id, TUN.rel.wave)
                local st = V.State(world)
                if s >= 30 and SS.Random(world, "visitors") < 0.25 and (st.cool.social or -1e9) <= world.time then
                    st.cool.social = world.time + TUN.social.globalCool
                    V.CallOver(world, nil, a)
                end
                return
            end
        end
    end
end

-- The morning paper: a carrier walks the sidewalk and tosses it near the entry. At most
-- tuning.paper.maxPile papers lie around; the carrier skips the house until they are picked up.
function V.SpawnPaper(world)
    local hh = world.household
    if not V.HomeLot(world) or (hh.flags and hh.flags.noPaper) then return nil end
    local p = perLot(world)
    local day = math.floor(world.time / 1440)
    if p.paperDay == day then return nil end
    p.paperDay = day
    return V.Spawn(world, nil, "paper", { force = true })
end
function V.CountTagged(world, tag)
    local n = 0
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        if def and SS.Tags.Has(def, tag) then n = n + 1 end
    end
    return n
end
V.roles.paper.onPass = function(world, a, vs)
    if vs.tossed then return end
    local ei, ej = St.EntryCell(world)
    if math.abs(a.x - (ei + 0.5)) > 0.6 then return end
    vs.tossed = true
    a.pose = "use"
    if V.CountTagged(world, "newspaper") >= TUN.paper.maxPile then
        V.Notice(world, nil, "The paper carrier skipped the house: old papers are piling up by the path.")
        return
    end
    local o = V.PlaceNear(world, "newspaper", { ei, ej }, { outdoor = true, extra = { state = { day = math.floor(world.time / 1440) } } })
    if o then
        sfx(RD.sfx.paper)
        SS.Emit("newspaperDelivered", world, o)
    end
end

-- The mail carrier: the van parks, the carrier walks to the mailbox (tag `mailbox`), delivers, leaves.
-- Bills are careers': SS.Economy.DeliverMail(world, mailbox) moves waiting bills into the mailbox and
-- sets its `mail` state; "mailDelivered"(world, mailbox, carrier) fires either way.
function V.SpawnMail(world)
    if not V.HomeLot(world) then return nil end
    local p = perLot(world)
    local day = math.floor(world.time / 1440)
    if p.mailDay == day then return nil end
    p.mailDay = day
    return V.Spawn(world, nil, "mail", { force = true })
end
function V.DeliverMail(world, carrier, box)
    local n = 0
    if SS.Economy and SS.Economy.DeliverMail then n = SS.Economy.DeliverMail(world, box) or 0 end
    sfx(RD.sfx.mail)
    if carrier then carrier.balloon = { kind = "speech", icon = (SS.Art and SS.Art.icons and SS.Art.icons.mail) and "mail" or "bubble", untilT = world.time + 4 } end
    if not box and n > 0 then V.Notice(world, nil, "No mailbox: the post was left at the front door.") end
    SS.Emit("mailDelivered", world, box, carrier, n)
    return n
end
V.roles.mail.tick = function(world, a, dt)
    local vs = a.roleData.vs
    if V.Busy(a) then return end
    if vs.delivered then return V.Leave(world, a, "done") end
    local box = V.FindTagged(world, "mailbox")
    if box then
        if vs.orderedMail then
            vs.orderedMail = nil
            local le = a.tmp.lastEnd
            if le and le.iid == "mail_deliver" and le.status == "done" then vs.delivered = true; return end
            vs.mailTries = (vs.mailTries or 0) + 1
            if vs.mailTries >= 2 then V.DeliverMail(world, a, nil); vs.delivered = true; return end
        end
        V.EnsureSlot(SS.Objects[box.def], "svc")
        if V.Reachable(world, a, box, "mail_deliver") then
            SS.Actions.Order(world, a, box.id, "mail_deliver")
            vs.orderedMail = true
        else
            vs.mailTries = (vs.mailTries or 0) + 1
            if vs.mailTries >= 2 then V.DeliverMail(world, a, nil); vs.delivered = true end
        end
    else
        local door = V.DoorFor(world, vs)
        local res = V.Goto(world, a, vs, { door.stand }, "maildoor")
        if res == "arrived" or res == "failed" then V.DeliverMail(world, a, nil); vs.delivered = true end
    end
end
SS.Interactions.mail_deliver = {
    label = "Deliver Mail", category = "Service", slot = "svc", pose = "use", dur = 1, manualOnly = true,
    test = function(world, actor) return actor.role == "mail", "Only the mail carrier does that." end,
    onEnd = function(world, actor, act, obj, status)
        if status == "done" then V.DeliverMail(world, actor, world.lot.objects[act.oid]) end
    end,
}

---------------------------------------------------------------------------------------------------
-- System objects: the morning paper and the welcome treats (behaviour below; no catalogue entry).
local FOUR = { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }
local OT = RD.text.objects
SS.Objects.newspaper = {
    name = OT.newspaper.name, cat = "system", buyable = false, price = 0, env = -1, noBlock = true, fp = { { 0, 0 } },
    desc = OT.newspaper.desc,
    -- one slot, "front", which other modules' paper actions name too (careers' job listings), so only
    -- one person handles the paper at a time; group "grab" lets an action asking for "grab" find it
    tags = { "newspaper" }, slots = { front = { approaches = FOUR, face = 2, group = "grab" } },
    actions = {}, startState = {},
}
SS.Objects.welcome_treats = {
    name = OT.welcome_treats.name, cat = "system", buyable = false, price = 0, env = 1, noBlock = true, fp = { { 0, 0 } },
    desc = OT.welcome_treats.desc,
    slots = { grab = { approaches = FOUR, face = 2 } }, actions = { "eat_treat" }, startState = { servings = 6 },
}
SS.Tags.Apply(SS.Objects.newspaper)

local function setCarry(actor, prop) actor.carry = prop end
local function clearCarry(actor, prop) if actor.carry == prop then actor.carry = nil end end

SS.Interactions.read_paper = {
    label = "Read the Paper", category = "Fun", slot = "front", pose = "read", carry = "newspaper", dur = 20,
    gain = { fun = 12 }, advert = { fun = 10 },
    onStart = function(world, actor, act, obj)
        if obj then obj.state = obj.state or {}; obj.state.read = true end
        setCarry(actor, "newspaper")
    end,
    onEnd = function(world, actor) clearCarry(actor, "newspaper") end,
}
SS.Interactions.recycle_paper = {
    label = "Recycle the Paper", category = "Chores", slot = "front", pose = "clean", dur = 1.5,
    -- today's unread paper is not clutter yet
    advertise = function(world, actor, obj)
        local st = obj and obj.state or {}
        if st.read or (st.day and st.day < math.floor(world.time / 1440)) then return { room = 6 } end
        return nil
    end,
    onEnd = function(world, actor, act, obj, status)
        if status == "done" and act.oid then V.RemoveObject(world, act.oid) end
    end,
}
SS.Interactions.eat_treat = {
    label = "Have a Treat", category = "Basics", slot = "grab", pose = "eat_stand", carry = "snack", dur = 5,
    gain = { hunger = 12, fun = 4 }, advert = { hunger = 10, fun = 5 },
    test = function(world, actor, obj)
        return (obj.state and (obj.state.servings or 0) > 0) and true or false, "The plate is empty."
    end,
    onStart = function(world, actor, act, obj)
        if not obj or (obj.state.servings or 0) <= 0 then return false, "The plate is empty." end
        obj.state.servings = obj.state.servings - 1
        setCarry(actor, "snack")
    end,
    onEnd = function(world, actor, act, obj)
        clearCarry(actor, "snack")
        if obj and (obj.state.servings or 0) <= 0 and world.lot.objects[obj.id] then V.RemoveObject(world, obj.id) end
    end,
}
SS.Tags.Attach("newspaper", "read_paper")
SS.Tags.Attach("newspaper", "recycle_paper")

SS.Interactions.guest_admire = {
    label = "Admire", category = "Visitors", slot = "svc", pose = "idle", dur = 6, manualOnly = true, gain = { fun = 5 },
    test = function(world, actor) return V.Owns(actor.role), "Guests do this." end,
    onStart = function(world, actor, act, obj)
        local o = world.lot.objects[act.oid]
        local def = o and SS.Objects[o.def]
        if not def then return false, "It's gone." end
        actor.facing = G.dirToFacing(o.x + 0.5 - actor.x, o.y + 0.5 - actor.y)
        local vs = actor.roleData and actor.roleData.vs
        V.Say(world, actor, "visitor_ornament", { objDef = o.def, price = def.price, host = vs and vs.host })
        SS.Emit("visitorAdmired", world, actor, o)
    end,
}
-- every definition an admirer might pick needs the generic service slot
local function ensureAdmireSlots()
    for _, def in pairs(SS.Objects) do
        if (def.price or 0) >= TUN.admirePrice and def.cat ~= "system" then V.EnsureSlot(def, "svc") end
    end
end

---------------------------------------------------------------------------------------------------
-- Autonomy: household members answer the door (invited guests and food couriers first).
SS.Actions.RegisterCandidates(function(world, actor, cands)
    if actor.role or not V.IsMember(world, actor) or not human(actor) or actor.age == "infant" then return end
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local v = world.actors[id]
        local vs = V.IsVisitor(world, v) and v.roleData and v.roleData.vs
        if vs and vs.state == "door" and vs.onLot and not vs.greeted and not V.BeingAnswered(world, v) then
            local iid, s
            if v.role == "courier" then
                iid = "door_pay"
                local hunger = actor.needs and actor.needs.hunger or 0
                s = 20 + math.max(0, (60 - hunger)) * 0.4
            elseif vs.invited then
                iid, s = "door_greet", 45
            else
                local out = actor.personality and actor.personality.outgoing or 5
                local d, l = V.RelPeek(world, actor.id, v.id)
                iid, s = "door_greet", 8 + out * 1.6 + (d + l) / 20
            end
            local dist = math.abs(v.x - actor.x) + math.abs(v.y - actor.y)
            s = s / (1 + dist * 0.02)
            if SS.Interactions[iid] and s > 12 and SS.Actions.Available(world, actor, v, iid) then
                cands[#cands + 1] = { tid = v.id, iid = iid, s = s }
            end
        end
    end
end)

---------------------------------------------------------------------------------------------------
-- Guests socialise with the household. The social module's interactions (category "Social",
-- targetActor, autonomous) are offered to visiting guests, scored by need urgency like any object
-- action; until that module registers any, "Chat" (visit_chat) stands in. Bounded: the two nearest
-- awake members, one think per guest per think interval.
local socialCache = { list = nil, key = nil }
function V.InvalidateSocial() socialCache.list = nil end
function V.SocialIids(world)
    local key = math.floor((world and world.time or 0) / 60)
    if socialCache.list and socialCache.key == key then return socialCache.list end
    local list = {}
    for iid, ia in pairs(SS.Interactions) do
        if type(ia) == "table" and ia.category == "Social" and ia.targetActor and not ia.manualOnly and not ia.guestForbidden
            and not ia.householdOnly and (ia.advert or ia.advertise) and (ia.cost or 0) <= 0 then
            list[#list + 1] = iid
        end
    end
    table.sort(list)
    socialCache.list, socialCache.key = list, key
    return list
end

local FALLBACK_SOCIAL = { "visit_chat" }
local function urgency(v) local x = (100 - v) / 100; return x * x end
local function socialScore(world, actor, target, ia)
    local advert = ia.advertise and ia.advertise(world, actor, target) or ia.advert
    if not advert then return 0 end
    local s = 0
    for need, amt in pairs(advert) do
        local v = actor.needs[need] or 0
        s = s + math.min(amt, 100 - v) * urgency(v)
    end
    return s
end

SS.Actions.RegisterCandidates(function(world, actor, cands)
    local role = actor.role
    if not role or not actor.needs then return end
    local def = V.roles[role]
    if not def or not def.useAutonomy or V.AccessOf(role) ~= "guest" then return end
    local vs = actor.roleData and actor.roleData.vs
    if not vs or vs.state ~= "visit" then return end
    local list = V.SocialIids(world)
    if #list == 0 then
        -- the stand-in chat only while the social module is absent: once it is loaded its own
        -- autonomy offers guests its socials (introduce, small talk ...), so a second chat is not added
        if SS.Socials and type(SS.Socials.byIid) == "table" and next(SS.Socials.byIid) then return end
        list = FALLBACK_SOCIAL
    end
    local near, nd = {}, {}
    for _, m in ipairs(V.MembersPresent(world)) do
        if m.age ~= "infant" and not m.sleeping and not V.NoInterrupt(m.act) and (m.level or 0) == (actor.level or 0) then
            local d = math.abs(m.x - actor.x) + math.abs(m.y - actor.y)
            local k = #near + 1
            near[k], nd[k] = m, d
            while k > 1 and (nd[k] < nd[k - 1] or (nd[k] == nd[k - 1] and near[k].id < near[k - 1].id)) do
                near[k], near[k - 1] = near[k - 1], near[k]
                nd[k], nd[k - 1] = nd[k - 1], nd[k]
                k = k - 1
            end
        end
    end
    for n = 1, math.min(2, #near) do
        local m, d = near[n], nd[n]
        for _, iid in ipairs(list) do
            local cool = actor.cool and actor.cool[m.id .. ":" .. iid]
            local ia = SS.Interactions[iid]
            if ia and (not cool or cool <= world.time) then
                local s = socialScore(world, actor, m, ia) / (1 + d * 0.04)
                if SS.Personality and SS.Personality.Modify then s = SS.Personality.Modify(world, actor, m, iid, s) end
                if s > 12 and SS.Actions.Available(world, actor, m, iid) then cands[#cands + 1] = { tid = m.id, iid = iid, s = s } end
            end
        end
    end
end)

SS.Interactions.visit_chat = {
    label = "Chat", category = "Visitors", targetActor = true, pose = "talk", dur = 20,
    gain = { social = 30, fun = 6 }, advert = { social = 30, fun = 4 },
    test = function(world, actor, target)
        if not (actor.role and V.AccessOf(actor.role) == "guest") then return false, "Only visitors chat like this." end
        if not target or target.sleeping then return false, "They're asleep." end
        if not V.IsMember(world, target) then return false, "They don't live here." end
        if not human(target) or target.age == "infant" then return false, "They can't chat back." end
        return true
    end,
    onStart = function(world, actor, act)
        local target = act.tid and world.actors[act.tid]
        if not target then return false, "They're gone." end
        actor.facing = G.dirToFacing(target.x - actor.x, target.y - actor.y)
        V.Say(world, actor, "smalltalk", { target = target.id, host = target.id }, nil, "social")
        target.balloon = { kind = "speech", icon = "social", untilT = world.time + 4 }
    end,
    onEnd = function(world, actor, act, _, status)
        local target = act.tid and world.actors[act.tid]
        if status ~= "done" or not target then return end
        if SS.Needs and SS.Needs.Add then SS.Needs.Add(target, "social", 12) end
        relChange(world, actor.id, target.id, TUN.rel.visitChat)
        relChange(world, target.id, actor.id, TUN.rel.visitChat)
        SS.Emit("visitorChatted", world, actor, target)
    end,
}

---------------------------------------------------------------------------------------------------
-- A short description of what a role actor is doing (UI lists, the inspector).
local STATE_TEXT = { arriving = "on the way", approach = "walking up to the door", door = "waiting at the door", visit = "visiting",
    task = "busy", leaving = "leaving", passing = "walking past" }
-- nil for anyone who is not a visitor (household members, resident roles such as pets and babies,
-- residents walking out or in).
function V.Describe(world, a)
    if not V.IsVisitor(world, a) then return nil end
    local def = V.roles[a.role]
    local vs = a.roleData and a.roleData.vs or {}
    local st = STATE_TEXT[vs.state] or vs.state or "here"
    if vs.state == "door" and vs.greeted then st = "chatting at the door" end
    if def.describe then st = def.describe(world, a, vs) or st end
    return string.format("%s (%s): %s", a.name or a.id, def.label or a.role, st)
end

-- Guests expected soon (pending requests on this lot), earliest first.
function V.Expected(world)
    local out = {}
    local s = V.State(world)
    for _, id in ipairs(sortedIds(s.requests)) do
        local r = s.requests[id]
        if r.state == "pending" and r.lotId == world.lot.id and not r.data.visit then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.id < b.id end)
    return out
end

---------------------------------------------------------------------------------------------------
-- System hooks
-- the lot's last simulated minute (saved in perLot): a lot switch or a jump in time is measured from it
local tickLot = { world = nil, pl = nil }
function V.SystemTick(world, dt)
    if tickLot.world ~= world then tickLot.world, tickLot.pl = world, perLot(world) end
    tickLot.pl.lastT = world.time + dt
    V.RunTimers(world)
    if V.occWorld ~= world or world.time >= (V.nextOcc or 0) or world.time < (V.nextOcc or 0) - 2 then
        updateBathOcc(world)
        V.nextOcc, V.occWorld = world.time + 1, world
    end
    local rb = V.ringingBell
    if rb and world.time >= rb.untilT then
        local o = world.lot.objects[rb.oid]
        if o and o.state then o.state.ringing = nil end
        if o then o.ringUntil = nil end
        V.ringingBell = nil
    end
end

function V.Hour(world, h)
    if not V.HomeLot(world) then return end
    local hr = h % 24
    local wb = TUN.walkby
    if hr >= wb.first and hr <= wb.last then
        for _ = 1, wb.maxPerHour do
            if SS.Random(world, "visitors") < wb.perHour then
                V.After(world, world.time + SS.RandomInt(world, "visitors", 0, 55), "visitors.walkby", {})
            end
        end
    end
    if hr >= TUN.social.first and hr <= TUN.social.last then V.MaybeSocialCall(world) end
    if hr == TUN.paper.hour then
        V.After(world, world.time + SS.RandomInt(world, "visitors", 0, TUN.paper.spread), "visitors.paper", {})
    end
    if hr == TUN.mail.hour and TUN.mail.weekdays[math.floor(world.time / 1440) % 7] then
        V.After(world, world.time + SS.RandomInt(world, "visitors", 0, TUN.mail.spread), "visitors.mail", {})
    end
    V.PruneRequests(world)
    V.CheckWelcome(world)
end

V.timerHandlers["visitors.arrive"] = function(world, ev) V.Fulfil(world, ev.data and ev.data.req) end
V.timerHandlers["visitors.walkby"] = function(world) V.SpawnWalkby(world) end
V.timerHandlers["visitors.paper"] = function(world) V.SpawnPaper(world) end
V.timerHandlers["visitors.mail"] = function(world) V.SpawnMail(world) end
V.timerHandlers["street.return"] = function(world, ev) St.HandleReturn(world, ev.data) end
-- anything another module put on the core scheduler under these kinds still works
SS.On("scheduled", function(ev, world)
    local h = world and ev.kind and ev.kind:sub(1, 9) == "visitors." and V.timerHandlers[ev.kind]
    if h then h(world, ev) end
end)

SS.On("actionEnded", function(actor, act, status, why)
    if actor and V.Owns(actor.role) then
        actor.tmp = actor.tmp or {}
        actor.tmp.lastEnd = { iid = act and act.iid, oid = act and act.oid, tid = act and act.tid, status = status, why = why }
    end
end)

-- Someone else took a role actor off the lot (death, a reset): close their request, restore their
-- identity (a townie goes home, a resident of another household back to their own lot) and clear the
-- role so they never come back as a half-visitor. away.keepRole keeps the role (a module moving a
-- role actor on purpose). Only roles on this framework are touched: a resident role (family's pets
-- and infants) or a role another module put straight into SS.Roles is theirs to manage.
SS.On("actorRemoved", function(world, a, away)
    if not (a and world and V.Owns(a.role)) then return end
    local role = a.role
    local vs = type(a.roleData) == "table" and a.roleData.vs or nil
    local req = vs and vs.req and V.State(world).requests[vs.req]
    local why = away and away.reason or "removed"
    if req and req.state == "active" and req.rid == a.id then req.state, req.why = "done", why end
    SS.Emit("visitorLeft", world, a, role, why)
    if away and away.keepRole then return end
    if not a.dead and vs and vs.home then V.RestoreHome(a, vs.home)
    elseif vs and vs.prev then V.RestorePrevRole(a, vs) end
    if a.role == role then a.role, a.roleData = nil, nil end
    a.noNeeds, a.carry, a.cool = nil, nil, nil
    if a.tmp then a.tmp = nil end
    V.stats.removed = V.stats.removed + 1
    local def = V.roles[role]
    if def and def.onRemoved then def.onRemoved(world, a, why) end
    if vs and vs.welcome and vs.group then V.WelcomeSettle(world, vs.group) end
end)

-- Props that only exist while an action runs (actions are runtime, so after a load or a switch any
-- of these still in hand is stale). Role props (a gift, the courier's bag) come back from saved state.
local ACTION_PROPS = { phone = true, newspaper = true, snack = true, bowl = true, trash_bag = true, wrench = true,
    watering_can = true, mop = true, plate_stack = true }
V.ACTION_PROPS = ACTION_PROPS

-- After a load or a lot switch: resume safely or send home; never duplicate anyone. A resident role
-- (a pet, an infant) or a role another module registered straight in SS.Roles is not ours: it is
-- left exactly as it is.
function V.Reconcile(world, a)
    if not V.Owns(a.role) then return end
    local def = V.roles[a.role]
    local rd = a.roleData
    if type(rd) ~= "table" then rd = {}; a.roleData = rd end
    a.tmp = {}
    if a.carry and ACTION_PROPS[a.carry] then a.carry = nil end
    local vs0 = rd.vs
    if vs0 and vs0.gift and not vs0.giftGiven then a.carry = "gift" elseif a.carry == "gift" then a.carry = nil end
    -- a member of this lot's own household still wearing a visitor role (they were out visiting when
    -- the household was switched to): the visit is over, they are simply home
    if vs0 and vs0.home and vs0.home.lotId == world.lot.id and world.household and a.householdId == world.household.id
        and a.role ~= "departing" and a.role ~= "arriving" then
        return V.StripRole(world, a, "lot_switch")
    end
    if def.reconcile then
        local r = def.reconcile(world, a)
        if r == "leave" then return V.Leave(world, a, "reload")
        elseif r == "remove" then return V.Remove(world, a, "reload")
        elseif r == "keep" then return end
        if not a.role then return end
    end
    local vs = rd.vs
    if not vs then return end
    if a.role == "departing" then return St.FinishDeparture(world, a, vs.away) end
    if a.role == "arriving" then return V.FinishArrival(world, a) end
    local s = vs.state
    if s == "passing" then return V.Remove(world, a, "reload") end
    vs.tries, vs.nextTry, vs.ordered, vs.gotoTag = 0, nil, nil, nil
    if not vs.onLot then
        if s == "leaving" then return V.Remove(world, a, vs.leaveWhy or "reload") end
        -- Sim.Attach moved them onto the nearest free lot cell: continue as if they just stepped on
        return V.OnLot(world, a, vs, def)
    end
    if vs.vehicleKind and s ~= "leaving" then
        local v = St.CallVehicle(world, vs.vehicleKind, { owner = "visitor:" .. a.id, hold = true, parked = true,
            wait = math.max(5, math.min(TUN.vehicle.maxWait, (vs.timeoutAt or world.time + 60) - world.time)), livery = def.livery })
        a.tmp.vehicle = v and v.id
    end
end

-- End a visit without taking the person off the lot they are on (they are already home): close the
-- request, give back any role another module had given them, drop the visitor role.
function V.StripRole(world, a, why)
    local role = a.role
    if not V.Owns(role) then return false end
    local vs = type(a.roleData) == "table" and a.roleData.vs or nil
    local s = V.State(world)
    local req = vs and vs.req and s.requests[vs.req]
    if req and req.state == "active" and req.rid == a.id then req.state, req.why = "done", why end
    local home = vs and vs.home
    a.role, a.roleData = nil, nil
    if home and home.role then a.role, a.roleData = home.role, home.roleData
    elseif vs and vs.prev then V.RestorePrevRole(a, vs) end
    V.RestoreNeeds(a, home)
    a.noNeeds, a.carry, a.cool, a.tmp, a.balloon = nil, nil, nil, nil, nil
    if a.away and home and home.away == nil then a.away = nil end
    V.stats.removed = V.stats.removed + 1
    history(world, (a.name or "?") .. " (" .. ((V.roles[role] or {}).label or tostring(role)) .. ") went home: " .. tostring(why))
    SS.Emit("visitorLeft", world, a, role, why)
    return true
end

-- A visitor becomes someone who lives here (family: moving in, a guardian arriving): the visit ends
-- where they stand, without taking them off the lot. Their request closes, a vehicle held for them
-- goes, a welcome party is settled, the role's onLeave/onRemoved run (why = "released") and the role,
-- framework state and visit-only fields are dropped. Someone still on the street steps onto the entry
-- cell. They keep the needs they have now (they are about to be played). Returns true, or false and why
-- for someone who is not a visitor (a resident role, a household member, a resident walking out or in).
function V.Release(world, a, why)
    if not a or not V.Owns(a.role) then return false, "They're not a visitor." end
    local role = a.role
    local def = V.roles[role]
    if def.internal then return false, "They live here." end
    why = why or "released"
    local vs = type(a.roleData) == "table" and a.roleData.vs or {}
    if not vs.leaveCalled and def.onLeave then vs.leaveCalled = true; def.onLeave(world, a, why) end
    local req = vs.req and V.State(world).requests[vs.req]
    if req and req.state == "active" and req.rid == a.id then req.state, req.why = "done", why end
    local vid = a.tmp and a.tmp.vehicle
    local v = vid and St.VehicleById(vid)
    if v and v.owner == "visitor:" .. a.id then St.ReleaseVehicle(world, v) end
    if world.actors[a.id] and ((a.tmp and a.tmp.offLot) or St.IsOffLot(world, a.x, a.y)) then
        local ei, ej = St.EntryCell(world)
        a.x, a.y, a.level = ei + 0.5, ej + 0.5, 0
    end
    if a.act then SS.Actions.Cancel(world, a, 0) end
    if not a.act then a.queue = {} end
    a.role, a.roleData, a.noNeeds, a.cool, a.tmp, a.balloon = nil, nil, nil, nil, nil, nil
    if a.carry and (ACTION_PROPS[a.carry] or a.carry == "gift" or a.carry == "shopping_bag") then a.carry = nil end
    if world.actors[a.id] then a.lotId, a.away = world.lot.id, nil end
    V.stats.released = (V.stats.released or 0) + 1
    if vs.welcome and vs.group then V.WelcomeSettle(world, vs.group) end
    history(world, (a.name or "?") .. " (" .. (def.label or role) .. ") stayed: " .. tostring(why))
    if def.onRemoved then def.onRemoved(world, a, why) end
    SS.Emit("visitorReleased", world, a, role, why)
    SS.Emit("visitorLeft", world, a, role, why)
    return true
end

-- A visitor who had not reached the door (still on the street or walking up) when the lot was left
-- goes back on the list: their request is pending again (the same person when it named one) and
-- fires when the lot is next played. Bounded by tuning.maxRequeue per request.
function V.Requeue(world, a, vs)
    local r = vs and vs.req and V.State(world).requests[vs.req]
    if not r or r.state ~= "active" or r.rid ~= a.id then return false end
    if (r.requeued or 0) >= (TUN.maxRequeue or 3) then return false end
    r.state, r.why, r.rid = "pending", nil, r.data.rid
    r.at = world.time + 5
    r.requeued = (r.requeued or 0) + 1
    local ev = V.After(world, r.at, "visitors.arrive", { req = r.id }, r.lotId)
    if not ev then
        r.state, r.why = "cancelled", "busy"
        SS.Emit("visitorCancelled", world, r)
        return false
    end
    vs.requeued = true
    SS.Emit("visitorRequeued", world, r, a)
    return true
end

-- Every visit on a lot ends (the player switched to another household's lot, or the lot's clock moved
-- while it was not simulated). t is the lot's last simulated minute: the visits settle as of then,
-- so nothing is billed for time nobody played. Visitors not yet at the door are requeued (V.Requeue);
-- everyone else goes home at once with their identity restored (townies home, residents of other
-- households back on their own lot). Residents walking out finish leaving; residents walking in are
-- home. A role keeps its actors with def.onSwitch = "keep" (or a function returning "keep"); staff
-- roles (venue staff) are kept by default. Quiet: the player is looking at another lot.
function V.EndLotVisits(world, why, t)
    local view = world
    if t and math.abs(t - world.time) > 1e-6 then
        view = setmetatable({ time = t }, { __index = world, __newindex = world })
    end
    local ended = 0
    local wasQuiet = V.quiet
    V.quiet = true
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        local def = a and V.Owns(a.role) and V.roles[a.role]
        if def then
            local vs = type(a.roleData) == "table" and a.roleData.vs or nil
            local keep = def.onSwitch
            if type(keep) == "function" then keep = keep(view, a, why) end
            if keep == nil and def.access == "staff" then keep = "keep" end
            if keep ~= "keep" and world.actors[id] and a.role == def.name then
                ended = ended + 1
                if a.role == "departing" or a.role == "arriving" then
                    V.FinishTransit(view, a, vs)
                else
                    if vs and (vs.state == "arriving" or vs.state == "approach") then V.Requeue(view, a, vs) end
                    V.Remove(view, a, why)
                end
            end
        end
    end
    V.quiet = wasQuiet
    if ended > 0 then V.stats.switchEnded = (V.stats.switchEnded or 0) + ended end
    return ended
end

-- Members of this lot's household still visiting another lot (a save or a switch that left them
-- there): their visit ends on that lot, through a session of it, and they come home.
function V.CollectStrays(world)
    local hh = world.household
    if not hh or hh.lotId ~= world.lot.id then return 0 end
    local root = world.root
    local n = 0
    for _, rid in ipairs(hh.members or {}) do
        local r = root.residents[rid]
        local where = r and r.lotId
        if r and not r.dead and V.Owns(r.role) and where and where ~= world.lot.id and root.hood.lots[where] then
            local other = SS.Sim.NewSession(root, where)
            if other.actors[rid] then
                local wasQuiet = V.quiet
                V.quiet = true
                V.Remove(other, r, "lot_switch")
                V.quiet = wasQuiet
                n = n + 1
            end
        end
    end
    return n
end

-- Residents whose home is this lot but who are not in the session (restored by EndLotVisits or
-- CollectStrays after the session was built) step back in where they were (the entry if that spot
-- is now blocked).
local function bringBack(world)
    local root = world.root
    for _, rid in ipairs(sortedIds(root.residents)) do
        local r = root.residents[rid]
        if r.lotId == world.lot.id and not r.dead and not world.actors[rid] then
            local i, j, lv = math.floor(r.x or 0), math.floor(r.y or 0), r.level or 0
            if not W.InLot(world.lot, i, j) or W.Blocked(world, lv, i, j) then
                i, j = St.EntryCell(world)
                lv = 0
            end
            local a = SS.Sim.AddActor(world, rid, i, j, lv)
            if a then a.cool, a.tmp = nil, nil end
        end
    end
end

local function clockIsOuting(world)
    local clk = rawget(world, "clock")
    return clk ~= nil and clk ~= world.root
end

function V.Attach(world)
    V.rooms, doorCache.rt, V.occWorld, V.ringingBell = nil, nil, nil, nil
    tickLot.world, tickLot.pl = nil, nil
    St.InvalidateEntry()
    local s = V.State(world)
    local prev = V.prev
    V.prev = nil
    ensureAdmireSlots()
    V.EnsureTownies(world)
    -- (a) the player left another household's lot: its visits end as of its last simulated minute.
    -- Not for an outing (the home clock is frozen and the travel module brings guests along) nor for
    -- the same household looking at another lot (an edit session): those resume.
    if prev and prev.root == world.root and prev.lotId ~= world.lot.id and not prev.outing and not clockIsOuting(world) then
        local sameHH = prev.hhId ~= nil and world.household ~= nil and prev.hhId == world.household.id
        if not sameHH then V.EndLotVisits(prev.world, "lot_switch", prev.lastT) end
    end
    -- (b) this lot's clock moved while nobody simulated it: visits end as of the last simulated minute
    local pl = perLot(world)
    if pl.lastT and math.abs(world.time - pl.lastT) > TUN.resumeGap then V.EndLotVisits(world, "away", pl.lastT) end
    pl.lastT = world.time
    -- (c) members of this household left visiting elsewhere come home
    V.CollectStrays(world)
    bringBack(world)
    for _, a in pairs(world.actors) do
        if a.carry and ACTION_PROPS[a.carry] and not a.act then a.carry = nil end
    end
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and a.role then V.Reconcile(world, a) end
    end
    for _, id in ipairs(sortedIds(s.requests)) do
        local r = s.requests[id]
        if r.state == "active" and r.lotId == world.lot.id and not (r.rid and world.actors[r.rid] and world.actors[r.rid].role) then
            r.state, r.why = "done", "reload"
        end
    end
    -- a doorbell ringing when the game was saved is silent on load (only doorbells: an alarm clock or
    -- a smoke alarm belongs to the modules that ring them)
    for _, o in pairs(world.lot.objects) do
        local def = SS.Objects[o.def]
        if def and SS.Tags.Has(def, "doorbell") and o.state and o.state.ringing then o.state.ringing, o.ringUntil = nil, nil end
    end
    V.CheckWelcome(world)
end

function V.Detach(world)
    V.rooms, doorCache.rt, V.occWorld = nil, nil, nil
    tickLot.world, tickLot.pl = nil, nil
    for lv = 0, W.LEVELS - 1 do local t = V.bathOcc[lv]; if t then for k in pairs(t) do t[k] = nil end end end
    local ok, pl = pcall(perLot, world)
    V.prev = { world = world, root = world.root, lotId = world.lot and world.lot.id,
        hhId = world.household and world.household.id, lastT = (ok and pl.lastT) or world.time, outing = clockIsOuting(world) }
end

SS.Sim.Register({ name = "visitors", order = 40, tick = V.SystemTick, hour = V.Hour, attach = V.Attach, detach = V.Detach })

-- ARCHITECTURE §5 lists actor.carry as runtime (never saved), but the core runtime list does not
-- strip it yet (requested in docs/requests/visitors.md). Declared here through the core's own API so
-- a prop in hand (the phone mid-call) never survives a save; role props come back in V.Reconcile.
if SS.Save and SS.Save.RegisterRuntime then SS.Save.RegisterRuntime("actor", "carry") end

-- Save validation: default/repair visitor records; never report a problem for a healthy save.
-- Exposed as V.ValidateSave(root, problems) so tests can check visitors' own rules apart from other
-- modules' validators (events clears every role on the dead, for one).
function V.ValidateSave(root, p)
    if root.visitors ~= nil and type(root.visitors) ~= "table" then root.visitors = nil; p[#p + 1] = "visitor records reset" end
    local s = root.visitors
    if s then
        if type(s.requests) ~= "table" then s.requests = {} end
        for id, r in pairs(s.requests) do
            if type(r) ~= "table" or type(r.role) ~= "string" or type(r.at) ~= "number" then
                s.requests[id] = nil
                p[#p + 1] = "dropped a damaged visit request"
            else
                r.data = type(r.data) == "table" and r.data or {}
                r.defers = tonumber(r.defers) or 0
                if r.rid and not root.residents[r.rid] and (r.state == "pending" or r.state == "active") then
                    r.state = "cancelled"
                    p[#p + 1] = "cancelled a visit by a missing person"
                end
            end
        end
        for _, k in ipairs({ "cool", "lastUsed", "perLot", "history", "timers" }) do if type(s[k]) ~= "table" then s[k] = {} end end
        for n = #s.timers, 1, -1 do
            local ev = s.timers[n]
            if type(ev) ~= "table" or type(ev.at) ~= "number" or type(ev.kind) ~= "string" then table.remove(s.timers, n) end
        end
        table.sort(s.timers, function(a, b) return a.at < b.at end)
        s.nextReq = tonumber(s.nextReq) or 1
    end
    for _, a in pairs(root.residents or {}) do
        if type(a) == "table" then
            if a.role ~= nil and type(a.role) ~= "string" then a.role = nil end
            if a.role and type(a.roleData) ~= "table" then a.roleData = {} end
            -- only roles on this framework: a module's own or resident role (a pet's) is that module's to validate
            if a.dead and a.role and a.role ~= "ghost" and V.Owns(a.role) then a.role, a.roleData = nil, nil end
        end
    end
    return true
end
SS.Save.RegisterValidator(function(root, p) return V.ValidateSave(root, p) end)
