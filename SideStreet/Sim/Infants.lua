-- SideStreet infants: their own needs and decay, care interactions (bottle, diaper, soothe, play,
-- carry, crib, highchair, rock to sleep), caregiver assignment and adult autonomy that answers
-- crying, the crying noise rule that wakes sleepers, and the transition to child after a defined
-- period of good care. Owner: family module. Tuning: SS.FamilyData.infant and .noise.
-- Neglect warnings, strikes and the protective-service visit live in Sim/Family.lua.
--
-- Saved: person.infant = { careMin, badMin, since, asleep, crib (oid), caregiver (rid), soothedUntil,
--   crying, cryingSince, feeds, changes, nightWakes }. Infants carry role "infant" (resident role,
--   useAutonomy = false) and actor.decay (their own passive change).
-- Runtime only: infant.carriedBy / infant.chair / infant.feeding are reconciled on load: the baby
--   is set down beside whoever was holding it, never duplicated.
local _, SS = ...
local U = SS.U
local W = SS.World
local F = SS.Family
local FD = SS.FamilyData
local ID, NZ = FD.infant, FD.noise
local Inf = {}
SS.Infants = Inf

local NEEDS = { "hunger", "energy", "hygiene", "social", "fun" }
Inf.NEEDS = NEEDS

function Inf.State(p)
    if type(p.infant) ~= "table" then p.infant = {} end
    local s = p.infant
    s.careMin = s.careMin or 0
    s.badMin = s.badMin or 0
    return s
end

-- Make a person an infant: own decay tables, the resident role, care state.
function Inf.Setup(world, p)
    -- a baby wearing another module's role is left to that module (F.ForeignRole)
    if F.ForeignRole(p, "infant") then return p.infant end
    p.kind, p.age = "human", "infant"
    p.decay = { awake = U.deepcopy(ID.decayAwake), sleep = U.deepcopy(ID.decaySleep) }
    if not F.StreetWalking(p) then
        p.role = "infant"
        p.roleData = type(p.roleData) == "table" and p.roleData or {}
    end
    p.noNeeds = nil
    p.needs = p.needs or {}
    for _, k in ipairs(SS.Tuning.needs) do p.needs[k] = p.needs[k] or 0 end
    local s = Inf.State(p)
    s.since = s.since or F.Root(world).time
    return s
end

---------------------------------------------------------------------------
-- Where the baby is: held, in a crib, in a highchair, or on the floor
---------------------------------------------------------------------------
function Inf.OnLot(world, hhId)
    local out = {}
    for _, id in ipairs(F.ActorIds(world)) do
        local p = world.actors[id]
        if F.OwnInfant(p) and not p.dead and (not hhId or p.householdId == hhId) then out[#out + 1] = p end
    end
    return out
end

function Inf.Carrier(world, p)
    local s = p.infant
    local c = s and s.carriedBy and world.actors[s.carriedBy]
    if c and c.carry == "baby" and not c.dead then return c end
end

-- The infant this actor is holding, if any.
function Inf.Held(world, actor)
    if not actor or actor.carry ~= "baby" then return nil end
    local id = actor.tmp and actor.tmp.baby
    local p = id and world.actors[id]
    if p and p.infant and p.infant.carriedBy == actor.id then return p end
    local ids = F.ActorIds(world)
    for n = 1, #ids do
        local q = world.actors[ids[n]]
        if q and q.infant and q.infant.carriedBy == actor.id and F.OwnInfant(q) and not q.dead then return q end
    end
end

function Inf.CribOccupant(world, o)
    local ids = F.ActorIds(world)
    for n = 1, #ids do
        local q = world.actors[ids[n]]
        if q and q.infant and q.infant.crib == o.id and F.OwnInfant(q) and not q.dead then return q end
    end
end

-- A free crib on this lot, nearest to `near` (an actor) when given.
function Inf.FreeCrib(world, near)
    local best, bestD
    for _, o in ipairs(F.ObjectsWithTag(world, "crib")) do
        if not Inf.CribOccupant(world, o) then
            local d = near and (math.abs(o.x + 0.5 - near.x) + math.abs(o.y + 0.5 - near.y) + math.abs((o.level or 0) - (near.level or 0)) * 6) or 0
            if not bestD or d < bestD then best, bestD = o, d end
        end
    end
    return best
end

local function releaseCarrier(world, s)
    local c = s.carriedBy and world.actors and world.actors[s.carriedBy]
    if c then
        if c.carry == "baby" then c.carry = nil end
        if c.tmp then c.tmp.baby, c.tmp.carrySince = nil, nil end
    end
    s.carriedBy = nil
end

function Inf.LeaveCrib(world, p)
    local s = Inf.State(p)
    local o = s.crib and world.lot.objects[s.crib]
    if o then
        if o.res and o.res.occupant == p.id then o.res.occupant = nil end
        if o.state and o.state.occupied then o.state.occupied = nil; SS.Emit("lotChanged", "state", o.id) end
    end
    s.crib = nil
    p.onObj = nil
end

function Inf.IntoCrib(world, p, o)
    local s = Inf.State(p)
    releaseCarrier(world, s)
    if s.crib and s.crib ~= o.id then Inf.LeaveCrib(world, p) end
    s.crib, s.chair = o.id, nil
    o.res = o.res or {}
    o.res.occupant = p.id
    o.state = o.state or {}
    if not o.state.occupied then o.state.occupied = true; SS.Emit("lotChanged", "state", o.id) end
    p.x, p.y, p.level, p.z = o.x + 0.5, o.y + 0.5, o.level or 0, nil
    p.onObj = o.id
    if p.needs.energy <= ID.cribSleepAt and p.needs.hunger > ID.cryWakeHunger then s.asleep = true end
    p.pose = s.asleep and "lie" or "sit"
end

function Inf.PickUp(world, carrier, p)
    local s = Inf.State(p)
    if s.crib then Inf.LeaveCrib(world, p) end
    releaseCarrier(world, s)
    s.chair = nil
    s.carriedBy = carrier.id
    carrier.carry = "baby"
    carrier.tmp = carrier.tmp or {}
    carrier.tmp.baby, carrier.tmp.carrySince = p.id, world.time
    p.x, p.y, p.level, p.z, p.facing = carrier.x, carrier.y, carrier.level or 0, carrier.z, carrier.facing
    p.onObj = nil
    p.pose = "carried"
    SS.Emit("infantCarried", world, p, carrier)
end

-- Set the baby down on a free floor cell beside whoever holds it (or where it is).
function Inf.PutDown(world, p, why)
    local s = Inf.State(p)
    local c = s.carriedBy and world.actors[s.carriedBy]
    releaseCarrier(world, s)
    if s.crib then Inf.LeaveCrib(world, p) end
    s.chair = nil
    local from = c or p
    local lv = from.level or 0
    local ci, cj = math.floor(from.x), math.floor(from.y)
    local i, j = F.FreeCellNear(world, lv, ci, cj, 4, { minR = 1, notDoor = true, sameRoom = true })
    if not i then i, j = F.FreeCellNear(world, lv, ci, cj, 10) end
    if i then p.x, p.y, p.level = i + 0.5, j + 0.5, lv end
    p.z, p.onObj = nil, nil
    p.pose = s.asleep and "lie" or "sit"
    if why and c then SS.Actions.Message(world, c, c.name .. " put " .. p.name .. " down " .. why .. ".", "social") end
end

function Inf.Detach(world, p)
    local s = p.infant
    if not s then return end
    releaseCarrier(world, s)
    if s.crib and world.lot then Inf.LeaveCrib(world, p) end
    s.crib, s.chair, s.feeding = nil, nil, nil
end

-- A new or returning infant enters the session lot (a crib when one is free).
-- The default caregiver: a parent who lives here, else the first adult of the household.
function Inf.DefaultCaregiver(world, p)
    local root = F.Root(world)
    local hh = p.householdId and root.households[p.householdId]
    if not hh then return nil end
    local fam = F.Fam(p)
    for _, rid in ipairs(fam.parents or {}) do
        local r = root.residents[rid]
        if r and F.Alive(r) and F.IsAdult(r) and r.householdId == hh.id then return rid end
    end
    for _, rid in ipairs(hh.members) do
        local r = root.residents[rid]
        if r and F.Alive(r) and F.IsAdult(r) and F.IsHuman(r) then return rid end
    end
end

-- Keep a valid caregiver: assign a default when there is none or the old one left the household.
function Inf.EnsureCaregiver(world, p)
    local s = Inf.State(p)
    local cur = s.caregiver and F.Root(world).residents[s.caregiver]
    if cur and F.Alive(cur) and cur.householdId == p.householdId then return s.caregiver end
    local rid = Inf.DefaultCaregiver(world, p)
    s.caregiver = nil
    if rid then Inf.SetCaregiver(world, p, rid) end
    return rid
end

function Inf.PlaceNew(world, p, i, j)
    Inf.Setup(world, p)
    local ci, cj = F.FreeCellNear(world, 0, i, j, 10, { indoor = true, notDoor = true })
    if not ci then ci, cj = F.FreeCellNear(world, 0, i, j, 16) end
    if not ci then ci, cj = SS.Street.EntryCell(world) end
    p.away = nil
    local a = SS.Sim.AddActor(world, p.id, ci, cj, 0)
    if not a then return nil end
    a.role = "infant"
    local crib = Inf.FreeCrib(world, a)
    if crib then Inf.IntoCrib(world, a, crib) else a.pose = "sit" end
    Inf.EnsureCaregiver(world, a)
    return a
end

function Inf.SetCaregiver(world, p, rid)
    local s = Inf.State(p)
    s.caregiver = rid
    local who = rid and F.Root(world).residents[rid]
    if who then F.Journal(world, who.name .. " is now " .. p.name .. "'s main caregiver.") end
    SS.Emit("caregiverChanged", world, p, rid)
end

---------------------------------------------------------------------------
-- Needs, sleep, crying, good care, and the transition to child
---------------------------------------------------------------------------
local CARRY_OK = { ["goto"] = true, fam_respond = true, fam_cheer = true, sit = true, watchtv = true }
function Inf.CarryOk(iid)
    return iid ~= nil and (CARRY_OK[iid] or iid:sub(1, 7) == "infant_")
end

local CRY_ORDER = { "hunger", "hygiene", "energy", "social", "fun" }
function Inf.CryReason(p, s, now)
    if s.asleep then return nil end
    local n, C = p.needs, ID.cryAt
    for _, k in ipairs(CRY_ORDER) do
        if (n[k] or 0) <= C[k] then
            if (k ~= "social" and k ~= "fun") or (s.soothedUntil or -1) <= now then return k end
        end
    end
end

function Inf.GoodCare(p)
    local sum, good = 0, true
    for _, k in ipairs(NEEDS) do
        local v = p.needs[k] or 0
        sum = sum + v
        if v <= ID.goodMin then good = false end
    end
    return good and (sum / #NEEDS) > ID.goodAvg
end

local function nearestAwakeAdult(world, p)
    local best, bestD
    for _, id in ipairs(F.ActorIds(world)) do
        local q = world.actors[id]
        if F.IsAdult(q) and not q.sleeping and not F.IsNpc(q) then
            local d = F.Dist(q, p)
            if not bestD or d < bestD then best, bestD = q, d end
        end
    end
    return best, bestD
end

function Inf.Tick(world, p, dt)
    if not F.IsInfant(p) then return end
    if not p.decay then Inf.Setup(world, p) end
    local s = Inf.State(p)
    local now = world.time
    -- held: follow the carrier; a carrier who starts something else sets the baby down first
    local c = s.carriedBy and world.actors[s.carriedBy]
    if s.carriedBy and (not c or c.carry ~= "baby" or c.dead) then
        Inf.PutDown(world, p); c = nil
    elseif c and c.act and c.act.phase == "perform" and not Inf.CarryOk(c.act.iid) then
        Inf.PutDown(world, p, "to " .. string.lower(c.act.label or "do something else")); c = nil
    end
    if c then
        p.x, p.y, p.level, p.z, p.facing, p.onObj = c.x, c.y, c.level or 0, c.z, c.facing, nil
    else
        local chair = s.chair and world.lot.objects[s.chair]
        if s.chair and (not chair or not s.feeding or not world.actors[s.feeding]
            or not world.actors[s.feeding].act or world.actors[s.feeding].act.iid ~= "infant_highchair") then
            s.chair, chair = nil, nil
            s.feeding = nil
            Inf.PutDown(world, p)
        end
        if chair then
            p.x, p.y, p.level, p.onObj = chair.x + 0.5, chair.y + 0.5, chair.level or 0, chair.id
        else
            local o = s.crib and world.lot.objects[s.crib]
            if s.crib and not o then s.crib = nil; p.onObj = nil end
            if o then
                p.x, p.y, p.level, p.onObj = o.x + 0.5, o.y + 0.5, o.level or 0, o.id
                if not (o.res and o.res.occupant == p.id) then o.res = o.res or {}; o.res.occupant = p.id end
            end
        end
    end
    -- sleep and waking
    local n = p.needs
    if s.asleep then
        if n.energy >= ID.wakeAt then
            s.asleep = nil
        elseif n.hunger <= ID.cryWakeHunger or n.hygiene <= ID.cryAt.hygiene - 20 then
            s.asleep = nil
            s.wokeUp = now
        end
    elseif not s.feeding then
        local at = (s.crib and ID.cribSleepAt) or (c and ID.carriedSleepAt) or ID.sleepAt
        if n.energy <= at and n.hunger > ID.cryWakeHunger then s.asleep = true end
    end
    p.sleeping = s.asleep or nil
    -- crying (the noise rule in the infants system hears it)
    local why = Inf.CryReason(p, s, now)
    if why ~= s.crying then
        s.crying = why
        s.cryingSince = why and now or nil
        s.cryLineAt = nil
        if why then SS.Emit("infantCrying", world, p, why) end
    end
    if why then
        if not p.balloon or (p.balloon.untilT or 0) < now + 1 or p.balloon.icon ~= why then
            p.balloon = { icon = why, text = p.name .. " is crying: " .. string.lower(SS.Tuning.needLabel[why]) .. ".", untilT = now + 10, kind = "alert" }
        end
        if not s.cryLineAt or now - s.cryLineAt >= ID.cryLineEvery then
            s.cryLineAt = now
            local q = nearestAwakeAdult(world, p)
            if q then F.Say(world, q, "infant_cry", { need = why, infant = p.id, name = p.name }) end
        end
    end
    p.pose = (c and "carried") or (s.asleep and "lie") or (why and "cry") or (s.chair and "sit") or (s.crib and "lie") or "sit"
    -- good care accumulates toward the transition (only while on the lot and looked after)
    if Inf.GoodCare(p) then s.careMin = s.careMin + dt else s.badMin = s.badMin + dt end
    if s.careMin >= ID.careMinutes and not c and not s.chair then Inf.GrowUp(world, p) end
end

SS.Roles.infant = { label = "Infant", useAutonomy = false, resident = true, family = true,
    tick = function(world, a, dt) Inf.Tick(world, a, dt) end }
F.DeclareResidentRole("infant", "Infant")

-- Carried babies feel held; cribs make better sleep.
SS.Needs.RegisterRateHook(function(world, a, need, rate)
    local s = a.infant
    if not s then return rate end
    if need == "energy" and a.sleeping and s.crib then return rate + ID.cribSleepBonus end
    if need == "social" and s.carriedBy then return rate + ID.carriedSocial end
    return rate
end)

function Inf.GrowUp(world, p)
    if not F.IsInfant(p) then return end
    local s = Inf.State(p)
    Inf.Detach(world, p)
    local root = F.Root(world)
    p.age = "child"
    p.role, p.roleData, p.decay, p.sleeping = nil, nil, nil, nil
    local fam = F.Fam(p)
    fam.grewUpAt = root.time
    fam.infancy = { careMin = math.floor(s.careMin), badMin = math.floor(s.badMin), feeds = s.feeds or 0,
        changes = s.changes or 0, nightWakes = s.nightWakes or 0 }
    p.infant = nil
    p.needs.bladder = math.max(p.needs.bladder or 0, 60)
    p.needs.comfort = math.max(p.needs.comfort or 0, 40)
    p.needs.fun = math.min(100, (p.needs.fun or 0) + 30)
    local i, j = F.FreeCellNear(world, p.level or 0, math.floor(p.x), math.floor(p.y), 6, { notDoor = true })
    if i then p.x, p.y = i + 0.5, j + 0.5 end
    p.onObj, p.z = nil, nil
    p.pose = "celebrate"
    p.act, p.queue = nil, {}
    -- the small celebration: everyone at home who is free comes to cheer
    local cheering = {}
    for _, id in ipairs(F.ActorIds(world)) do
        local q = world.actors[id]
        if q ~= p and F.IsHuman(q) and not F.IsInfant(q) and not F.IsNpc(q) and not q.sleeping
            and not (q.act and q.act.manual) and (q.householdId == p.householdId or q.role == "guest") then
            if q.act then SS.Actions.Cancel(world, q, 0) end
            q.queue = q.queue or {}
            table.insert(q.queue, 1, { iid = "fam_cheer", tid = p.id, manual = false })
            cheering[#cheering + 1] = q
        end
    end
    if cheering[1] then p.queue[1] = { iid = "fam_cheer", tid = cheering[1].id, manual = false } end
    p.balloon = { icon = "fun", text = p.name .. " is a big kid now!", untilT = world.time + 30, kind = "speech" }
    local days = math.floor(fam.infancy.careMin / 1440 * 10 + 0.5) / 10
    local text = p.name .. " has grown from a baby into a child after " .. days .. " days of good care. Time to celebrate!"
    F.Journal(world, text)
    if SS.Sim.Emergency then SS.Sim.Emergency(world, text, "info") end
    F.Record(world, "grew_up", { rid = p.id })
    SS.Emit("infantGrewUp", world, p, #cheering)
    return true
end

---------------------------------------------------------------------------
-- The noise rule: crying wakes sleepers (caregiver first), and bothers people nearby
---------------------------------------------------------------------------
function Inf.Noise(world, src, dst)
    local n = NZ.loud - (math.abs(src.x - dst.x) + math.abs(src.y - dst.y))
    local sl, dl = src.level or 0, dst.level or 0
    if sl ~= dl then
        n = n - NZ.levelPenalty * math.abs(sl - dl)
    elseif W.RoomAt(world, sl, math.floor(src.x), math.floor(src.y)) ~= W.RoomAt(world, dl, math.floor(dst.x), math.floor(dst.y)) then
        n = n - NZ.wallPenalty
    end
    return n
end

-- Returns false when the sleeper can't be woken (household-core's Wake refuses someone who has
-- passed out, or isn't in a sleeping action).
function Inf.WakeSleeper(world, q, src)
    q.tmp = q.tmp or {}
    q.tmp.cryExposure = 0
    if SS.Actions.Wake then
        if not SS.Actions.Wake(world, q, "infant_cry") then return false end
    else
        SS.Actions.Cancel(world, q, 0)
    end
    q.tmp.wokenBy, q.tmp.wokenAt = src.id, world.time
    SS.Needs.Add(q, "comfort", -NZ.comfortHit)
    local s = Inf.State(src)
    s.nightWakes = (s.nightWakes or 0) + 1
    q.nextThink = nil
    SS.Actions.Message(world, q, q.name .. " was woken by " .. src.name .. " crying.", "energy")
    SS.Emit("infantWokeSleeper", world, src, q)
    return true
end

local CRIERS = {}
function Inf.NoiseRule(world, dt)
    local criers, nc = CRIERS, 0
    local ids = F.ActorIds(world)
    for n = 1, #ids do
        local p = world.actors[ids[n]]
        if p and p.infant and p.infant.crying and F.IsInfant(p) then nc = nc + 1; criers[nc] = p end
    end
    for k = #criers, nc + 1, -1 do criers[k] = nil end
    if nc == 0 then return end
    for n = 1, #ids do
        local q = world.actors[ids[n]]
        if q and F.IsHuman(q) and not F.IsInfant(q) and not q.dead then
            local loud, src = 0, nil
            for k = 1, nc do
                local p = criers[k]
                local nz = Inf.Noise(world, p, q)
                if nz > loud then loud, src = nz, p end
            end
            if src then
                if q.sleeping then
                    local care = src.infant.caregiver == q.id
                    if loud >= (care and NZ.caregiverNoise or NZ.wakeNoise) then
                        q.tmp = q.tmp or {}
                        q.tmp.cryExposure = (q.tmp.cryExposure or 0) + loud * dt
                        if care or q.tmp.cryExposure >= NZ.wakeExposure then Inf.WakeSleeper(world, q, src) end
                    end
                elseif loud >= NZ.wakeNoise then
                    SS.Needs.Add(q, "comfort", -NZ.comfortHit * dt / 60)
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Care interactions (people -> infant: targetActor; carrier -> crib/highchair: objects)
---------------------------------------------------------------------------
local I = SS.Interactions

-- opts: adult (grown-ups only), awake (not while asleep), check = fn(world, actor, p, s) -> ok, why
local function careTest(opts)
    return function(world, actor, p)
        if not p or not F.IsInfant(p) then return false, "That's for babies." end
        if not actor or not F.IsHuman(actor) or F.IsInfant(actor) then return false, "Only people can do that." end
        if opts.adult and not F.IsAdult(actor) then return false, "Only a grown-up can do that." end
        if actor.householdId ~= p.householdId then return false, "Only " .. p.name .. "'s family can do that." end
        local s = Inf.State(p)
        local holder = s.carriedBy and world.actors[s.carriedBy]
        if holder and holder ~= actor then return false, holder.name .. " is holding " .. p.name .. "." end
        if opts.awake and s.asleep then return false, p.name .. " is asleep." end
        if opts.check then return opts.check(world, actor, p, s) end
        return true
    end
end

local function careDone(world, actor, p, counter)
    local s = Inf.State(p)
    if counter then s[counter] = (s[counter] or 0) + 1 end
    F.Change(world, actor.id, p.id, 2, 0.5)
    F.Change(world, p.id, actor.id, 2, 0.5)
    SS.Emit("infantCared", world, p, actor, counter)
end

local function holdFree(world, actor)
    if actor.carry and actor.carry ~= "baby" then return false, actor.name .. "'s hands are full." end
    return true
end

I.infant_feed = {
    label = "Feed Bottle", category = "Baby", targetActor = true, pose = "use", dur = ID.feed.dur,
    advert = {}, ages = { adult = true }, kinds = { human = true },
    test = careTest({ adult = true, awake = true, check = function(world, actor, p)
        if p.needs.hunger >= 95 then return false, p.name .. " isn't hungry." end
        return F.CanAfford(world, ID.feed.cost)
    end }),
    onStart = function(world, actor, act)
        local p, why = F.TargetInReach(world, actor, act)
        if not p then return false, why end
        local ok, err = F.ChargeOnce(world, act, ID.feed.cost, "Baby formula")
        if not ok then return false, err end
        p.infant.feeding = actor.id
        if not actor.carry then actor.carry = "bottle" end
    end,
    onTick = function(world, actor, act, _, dt)
        local p = world.actors[act.tid]
        if not p or not p.infant then act.complete = true; return end
        F.TickGain(world, act, p, { hunger = ID.feed.hunger }, ID.feed.dur, dt)
    end,
    onEnd = function(world, actor, act, _, status)
        if actor.carry == "bottle" then actor.carry = nil end
        local p = world.actors[act.tid]
        if p and p.infant then
            p.infant.feeding = nil
            if status == "done" then careDone(world, actor, p, "feeds") end
        end
    end,
}

I.infant_change = {
    label = "Change Diaper", category = "Baby", targetActor = true, pose = "use", dur = ID.change.dur,
    advert = {}, ages = { adult = true }, kinds = { human = true },
    test = careTest({ adult = true, check = function(world, actor, p)
        if p.needs.hygiene >= 90 then return false, p.name .. " is clean and dry." end
        return true
    end }),
    onStart = function(world, actor, act)
        local p, why = F.TargetInReach(world, actor, act)
        if not p then return false, why end
    end,
    onTick = function(world, actor, act, _, dt)
        local p = world.actors[act.tid]
        if not p or not p.infant then act.complete = true; return end
        F.TickGain(world, act, p, { hygiene = ID.change.hygiene }, ID.change.dur, dt)
        F.TickGain(world, act, actor, { hygiene = -3 }, ID.change.dur, dt)
    end,
    onEnd = function(world, actor, act, _, status)
        local p = world.actors[act.tid]
        if p and status == "done" then careDone(world, actor, p, "changes") end
    end,
}

I.infant_soothe = {
    label = "Soothe", category = "Baby", targetActor = true, pose = "hug", dur = ID.soothe.dur,
    advert = {}, ages = { adult = true, child = true }, kinds = { human = true },
    test = careTest({ awake = true, check = function(world, actor, p, s)
        if not s.crying and p.needs.social >= 90 then return false, p.name .. " is perfectly content." end
        return true
    end }),
    onStart = function(world, actor, act)
        local p, why = F.TargetInReach(world, actor, act)
        if not p then return false, why end
    end,
    onTick = function(world, actor, act, _, dt)
        local p = world.actors[act.tid]
        if not p or not p.infant then act.complete = true; return end
        F.TickGain(world, act, p, { social = ID.soothe.social, fun = ID.soothe.fun }, ID.soothe.dur, dt)
        F.TickGain(world, act, actor, { social = 6 }, ID.soothe.dur, dt)
    end,
    onEnd = function(world, actor, act, _, status)
        local p = world.actors[act.tid]
        if p and p.infant and status == "done" then
            p.infant.soothedUntil = world.time + ID.soothedFor
            careDone(world, actor, p, "soothes")
        end
    end,
}

I.infant_play = {
    label = "Play with Baby", category = "Baby", targetActor = true, pose = "play", dur = ID.play.dur,
    advert = {}, ages = { adult = true, child = true }, kinds = { human = true },
    test = careTest({ awake = true, check = function(world, actor, p)
        if p.needs.energy <= ID.cryAt.energy then return false, p.name .. " is too tired to play." end
        if p.needs.fun >= 95 then return false, p.name .. " has had plenty of fun." end
        return true
    end }),
    onStart = function(world, actor, act)
        local p, why = F.TargetInReach(world, actor, act)
        if not p then return false, why end
    end,
    onTick = function(world, actor, act, _, dt)
        local p = world.actors[act.tid]
        if not p or not p.infant then act.complete = true; return end
        F.TickGain(world, act, p, { fun = ID.play.fun, social = ID.play.social, energy = -4 }, ID.play.dur, dt)
        F.TickGain(world, act, actor, { fun = 15, social = 8 }, ID.play.dur, dt)
    end,
    onEnd = function(world, actor, act, _, status)
        local p = world.actors[act.tid]
        if p and status == "done" then careDone(world, actor, p, "plays") end
    end,
}

local function carrierNext(world, actor, act)
    local d = act.data or {}
    if d.toCrib then
        local crib = Inf.FreeCrib(world, actor)
        if crib then return { oid = crib.id, iid = "infant_to_crib" } end
    end
    if d.rock then return { iid = "infant_rock", tid = act.tid } end
end

I.infant_pickup = {
    label = "Pick Up", category = "Baby", targetActor = true, pose = "use", dur = 1,
    advert = {}, ages = { adult = true }, kinds = { human = true },
    test = careTest({ adult = true, check = function(world, actor, p, s)
        if s.carriedBy == actor.id then return false, actor.name .. " is already holding " .. p.name .. "." end
        local ok, why = holdFree(world, actor)
        if not ok then return false, why end
        if actor.carry == "baby" then return false, actor.name .. " is already holding a baby." end
        return true
    end }),
    onStart = function(world, actor, act)
        local p, why = F.TargetInReach(world, actor, act)
        if not p then return false, why end
    end,
    onEnd = function(world, actor, act, _, status)
        if status ~= "done" then return end
        local p = world.actors[act.tid]
        if not p or not F.IsInfant(p) or (p.infant.carriedBy and p.infant.carriedBy ~= actor.id) then return end
        Inf.PickUp(world, actor, p)
    end,
    next = carrierNext,
}

I.infant_put_down = {
    label = "Put Down", category = "Baby", targetActor = true, pose = "use", dur = 1,
    advert = {}, ages = { adult = true }, kinds = { human = true },
    test = function(world, actor, p)
        if not p or not F.IsInfant(p) or not p.infant or p.infant.carriedBy ~= actor.id then return false, "Not holding the baby." end
        return true
    end,
    onEnd = function(world, actor, act, _, status)
        local p = world.actors[act.tid]
        if status == "done" and p and p.infant and p.infant.carriedBy == actor.id then Inf.PutDown(world, p) end
    end,
}

I.infant_rock = {
    label = "Rock to Sleep", category = "Baby", targetActor = true, pose = "hug", dur = ID.rock.dur,
    advert = {}, ages = { adult = true }, kinds = { human = true },
    test = careTest({ adult = true, awake = true, check = function(world, actor, p, s)
        if s.carriedBy ~= actor.id then return false, "Pick " .. p.name .. " up first." end
        if p.needs.energy >= ID.rock.energyNeed then return false, p.name .. " isn't sleepy." end
        return true
    end }),
    onTick = function(world, actor, act, _, dt)
        local p = world.actors[act.tid]
        if not p or not p.infant or p.infant.carriedBy ~= actor.id then act.complete = true; return end
        F.TickGain(world, act, p, { social = ID.rock.social }, ID.rock.dur, dt)
    end,
    onEnd = function(world, actor, act, _, status)
        local p = world.actors[act.tid]
        if status == "done" and p and p.infant and p.infant.carriedBy == actor.id then
            p.infant.asleep = true
            p.sleeping = true
            careDone(world, actor, p, "rocks")
        end
    end,
    next = function(world, actor, act)
        local crib = Inf.FreeCrib(world, actor)
        if crib and actor.carry == "baby" then return { oid = crib.id, iid = "infant_to_crib" } end
    end,
}

I.infant_to_crib = {
    label = "Put Baby in Crib", category = "Baby", slot = "front", pose = "use", dur = 3,
    ages = { adult = true }, kinds = { human = true },
    test = function(world, actor, o)
        local p = Inf.Held(world, actor)
        if not p then return false, "Pick up a baby first." end
        local occ = o and Inf.CribOccupant(world, o)
        if occ and occ ~= p then return false, occ.name .. " is already in this crib." end
        return true
    end,
    onEnd = function(world, actor, act, o, status)
        if status ~= "done" or not o then return end
        local p = Inf.Held(world, actor)
        if p then
            Inf.IntoCrib(world, p, o)
            SS.Needs.Add(actor, "social", 4)
        end
    end,
}
SS.Tags.Attach("crib", "infant_to_crib")

I.infant_highchair = {
    label = "Feed in Highchair", category = "Baby", slot = "front", pose = "use", dur = ID.highchair.dur,
    ages = { adult = true }, kinds = { human = true },
    test = function(world, actor, o)
        local p = Inf.Held(world, actor)
        if not p then return false, "Bring a baby to the highchair first." end
        if p.needs.hunger >= 95 then return false, p.name .. " isn't hungry." end
        return F.CanAfford(world, ID.highchair.cost)
    end,
    onStart = function(world, actor, act, o)
        if not o then return false, "The highchair is gone." end
        local p = Inf.Held(world, actor)
        if not p then return false, "The baby isn't here." end
        local ok, why = F.ChargeOnce(world, act, ID.highchair.cost, "Baby food")
        if not ok then return false, why end
        releaseCarrier(world, p.infant)
        p.infant.chair, p.infant.feeding = o.id, actor.id
        p.infant.asleep = nil
        act.data.baby = p.id
    end,
    onTick = function(world, actor, act, o, dt)
        local p = world.actors[act.data.baby or ""]
        if not p or not p.infant then act.complete = true; return end
        F.TickGain(world, act, p, { hunger = ID.highchair.hunger, fun = ID.highchair.fun }, ID.highchair.dur, dt)
    end,
    onEnd = function(world, actor, act, o, status)
        local p = world.actors[act.data.baby or ""]
        if not p or not p.infant then return end
        p.infant.chair, p.infant.feeding = nil, nil
        if world.actors[actor.id] and not actor.carry then Inf.PickUp(world, actor, p) else Inf.PutDown(world, p) end
        if status == "done" then careDone(world, actor, p, "feeds") end
    end,
}
SS.Tags.Attach("highchair", "infant_highchair")

---------------------------------------------------------------------------
-- Caregiver autonomy: adults (and children, for play) answer crying and low needs
---------------------------------------------------------------------------
local function isNight(world)
    local h = (world.time % 1440) / 60
    return h >= 22 or h < 7
end

-- Best care for this infant from this person: iid, score, data (or nil).
function Inf.CareChoice(world, actor, p)
    local s = Inf.State(p)
    local n = p.needs
    local adult = F.IsAdult(actor)
    if s.carriedBy and s.carriedBy ~= actor.id then return nil end
    if s.chair then return nil end
    local iid, urg, data
    if s.asleep then
        if adult and not s.crib and s.carriedBy ~= actor.id and Inf.FreeCrib(world, actor) then
            return "infant_pickup", 22, { toCrib = true }
        end
        return nil
    end
    if adult and n.hunger < 40 then iid, urg = "infant_feed", 40 - n.hunger
    elseif adult and n.hygiene < 40 then iid, urg = "infant_change", 40 - n.hygiene
    elseif adult and n.energy < 30 then
        urg = 30 - n.energy
        if s.carriedBy == actor.id then
            iid = "infant_rock"
        elseif not s.crib and Inf.FreeCrib(world, actor) then
            iid, data = "infant_pickup", { toCrib = true }
        else
            iid, data = "infant_pickup", { rock = true }
        end
    elseif n.social < 20 then iid, urg = "infant_soothe", 20 - n.social
    elseif n.fun < 20 then iid, urg = "infant_play", 20 - n.fun
    end
    if not iid then return nil end
    local C = ID.careScore
    local score = C.base + urg * 0.4 + (s.crying and C.crying or 0)
    if s.caregiver == actor.id then
        score = score * C.caregiver
    elseif s.caregiver and isNight(world) and world.actors[s.caregiver] then
        score = score * C.nightOthers
    end
    if not adult then score = score * 0.6 end
    -- they're up anyway: whoever the crying woke settles the baby before going back to bed
    local t = actor.tmp
    if t and t.wokenBy == p.id and world.time - (t.wokenAt or -1e9) <= C.wokenFor then score = score + C.woken end
    return iid, score, data
end

SS.Actions.RegisterCandidates(function(world, actor, cands)
    if actor.role or not F.IsHuman(actor) or F.IsInfant(actor) or not F.IsMember(world, actor) then return end
    local ids = F.ActorIds(world)
    local any = false
    for n = 1, #ids do
        local p = world.actors[ids[n]]
        if p and F.OwnInfant(p) and not p.dead and p.householdId == actor.householdId then any = true; break end
    end
    if not any then return end
    local held = Inf.Held(world, actor)
    if held then
        local hs = held.infant
        local crib = Inf.FreeCrib(world, actor)
        local since = actor.tmp and actor.tmp.carrySince or world.time
        if crib and F.AutoCooling(world, actor, crib.id, "infant_to_crib") then crib = nil end
        if crib and (hs.asleep or held.needs.energy <= ID.cribSleepAt) then
            cands[#cands + 1] = { oid = crib.id, iid = "infant_to_crib", s = 45 }
        elseif world.time - since >= ID.carryIdlePutDown then
            if crib then cands[#cands + 1] = { oid = crib.id, iid = "infant_to_crib", s = 30 }
            else cands[#cands + 1] = { tid = held.id, iid = "infant_put_down", s = 25 } end
        end
    end
    for n = 1, #ids do
        local p = world.actors[ids[n]]
        if p and F.OwnInfant(p) and not p.dead and p.householdId == actor.householdId then
            local iid, s, data = Inf.CareChoice(world, actor, p)
            if iid and s > 12 and not F.AutoCooling(world, actor, p.id, iid) and SS.Actions.Available(world, actor, p, iid) then
                cands[#cands + 1] = { tid = p.id, iid = iid, s = s, data = data }
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Events, system, validator
---------------------------------------------------------------------------
-- A carrier who starts an unrelated action puts the baby down first (the tick also checks).
SS.On("actionStarted", function(actor, act)
    local world = SS.Sim.world
    if not world or not actor or actor.carry ~= "baby" or not act or Inf.CarryOk(act.iid) then return end
    local p = Inf.Held(world, actor)
    if p then Inf.PutDown(world, p, "to " .. string.lower(act.label or "do something else")) end
end)

SS.On("actorRemoved", function(world, a, away)
    if not world or not a then return end
    if a.carry == "baby" then
        for _, p in ipairs(Inf.OnLot(world)) do
            if p.infant and p.infant.carriedBy == a.id then Inf.PutDown(world, p) end
        end
        a.carry = nil
    end
    if a.infant then Inf.Detach(world, a) end
end)

-- A caregiver who moves out or dies is replaced by the default one.
local function recheckCaregivers(world)
    if not world or not world.actors then return end
    for _, p in ipairs(Inf.OnLot(world)) do
        local cg = p.infant and p.infant.caregiver
        local r = cg and F.Root(world).residents[cg]
        if cg and (not r or r.dead or r.householdId ~= p.householdId) then Inf.EnsureCaregiver(world, p) end
    end
end
SS.On("householdChanged", function(world) recheckCaregivers(world) end)
SS.On("death", function(world) recheckCaregivers(world) end)

SS.On("actorAdded", function(world, a)
    if world and a and F.OwnInfant(a) and (a.role ~= "infant" or not a.decay) then Inf.Setup(world, a) end
end)
SS.On("streetArrived", function(world, a)
    if world and type(a) == "table" and F.OwnInfant(a) and a.role ~= "infant" then Inf.Setup(world, a) end
end)

Inf.PROPS = { bottle = "infant_feed" }
local acc = 0
SS.Sim.Register({
    name = "infants", order = 42,
    attach = function(world)
        acc = 0
        local ids = F.ActorIds(world)
        for _, id in ipairs(ids) do
            local p = world.actors[id]
            if F.OwnInfant(p) then
                if p.role ~= "infant" or not p.decay then Inf.Setup(world, p) end
                local s = Inf.State(p)
                if s.carriedBy then
                    local c = world.actors[s.carriedBy]
                    s.carriedBy = nil
                    if c then
                        if c.carry == "baby" then c.carry = nil end
                        p.x, p.y, p.level = c.x, c.y, c.level or 0
                    end
                    Inf.PutDown(world, p)
                end
                s.chair, s.feeding = nil, nil
                local o = s.crib and world.lot.objects[s.crib]
                if s.crib and (not o or not SS.Tags.Has(SS.Objects[o.def] or {}, "crib")) then s.crib = nil end
                if s.crib then Inf.IntoCrib(world, p, o) end
                p.sleeping = s.asleep or nil
                if p.householdId == (world.household and world.household.id) then Inf.EnsureCaregiver(world, p) end
            end
        end
        for _, id in ipairs(ids) do
            local a = world.actors[id]
            if a.carry == "baby" and not Inf.Held(world, a) then a.carry = nil end
        end
        -- a bottle from an interrupted feed is put away (the feed starts again from the top, and
        -- takes a bottle out again, when household-core resumes it)
        F.PutAwayProps(world, Inf.PROPS)
        for _, o in ipairs(F.ObjectsWithTag(world, "crib")) do
            if o.state and o.state.occupied and not Inf.CribOccupant(world, o) then o.state.occupied = nil end
        end
    end,
    tick = function(world, dt)
        acc = acc + dt
        if acc >= 1 then
            local step = acc
            acc = 0
            Inf.NoiseRule(world, step)
        end
    end,
})

SS.Save.RegisterValidator(function(root, problems)
    for _, id in ipairs(F.SortedIds(root.residents)) do
        local r = root.residents[id]
        if type(r) == "table" and r.age == "infant" and F.ForeignRole(r, "infant") then
            -- left to the module whose role the baby wears
        elseif type(r) == "table" and r.age == "infant" then
            if type(r.infant) ~= "table" then r.infant = {}; problems[#problems + 1] = "infant care state restored for " .. tostring(id) end
            local s = r.infant
            s.careMin = type(s.careMin) == "number" and s.careMin or 0
            s.badMin = type(s.badMin) == "number" and s.badMin or 0
            if type(r.decay) ~= "table" or type(r.decay.awake) ~= "table" or type(r.decay.sleep) ~= "table" then
                r.decay = { awake = U.deepcopy(ID.decayAwake), sleep = U.deepcopy(ID.decaySleep) }
            end
            -- a baby saved mid-walk keeps the street's transit role; visitors finishes the walk on load
            if r.lotId and r.role ~= "infant" and r.role ~= "arriving" and r.role ~= "departing" then r.role = "infant"; r.roleData = r.roleData or {} end
        elseif type(r) == "table" and r.infant ~= nil then
            r.infant = nil
        end
    end
    return true
end)

-- Status summary for the UI (Baby page).
function Inf.Status(world, p)
    local s = Inf.State(p)
    local c = Inf.Carrier(world, p)
    local where = c and ("held by " .. c.name) or (s.chair and "in the highchair") or (s.crib and "in the crib") or "on the floor"
    local cg = s.caregiver and F.Root(world).residents[s.caregiver]
    return {
        where = where, asleep = s.asleep and true or false, crying = s.crying,
        careMin = s.careMin, careLeft = math.max(0, ID.careMinutes - s.careMin), good = Inf.GoodCare(p),
        caregiver = cg and cg.name or nil, caregiverId = s.caregiver, nightWakes = s.nightWakes or 0,
        feeds = s.feeds or 0, changes = s.changes or 0,
    }
end
