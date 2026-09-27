-- SideStreet persistence on top of WoW SavedVariables (SideStreetDB).
-- "Save" updates the in-memory SavedVariables table. The client writes it to disk
-- on logout or /reload; a crash before that loses the session (documented in README).
local _, SS = ...
local U = SS.U
local Save = {}
SS.Save = Save

Save.SLOTS = 3
local RUNTIME_ACTOR = { "act", "queue", "sleeping", "walking", "onObj", "pose", "cool", "nextThink", "lastThink", "balloon", "stride", "tmp" }
local RUNTIME_OBJECT = { "res", "watchers", "tmp" }

-- Systems declare their runtime-only fields (never saved) and validators (repair/reject).
--   Save.RegisterRuntime("actor" | "object", key)
--   Save.RegisterValidator(fn(root, problems) -> false, reason to reject; else repairs in place)
-- Convention: put scratch state under `tmp` (actor.tmp / object.tmp), which is always stripped.
Save.validators = {}
function Save.RegisterRuntime(kind, key)
    local list = kind == "object" and RUNTIME_OBJECT or RUNTIME_ACTOR
    for _, k in ipairs(list) do if k == key then return end end
    list[#list + 1] = key
end
function Save.RegisterValidator(fn) Save.validators[#Save.validators + 1] = fn end

local function stamp()
    local f = rawget(_G, "time") or os.time
    return f()
end

function Save.DB()
    local db = rawget(_G, "SideStreetDB")
    if type(db) ~= "table" then
        db = {}
        _G.SideStreetDB = db
    end
    db.schema = db.schema or SS.SCHEMA
    db.slots = db.slots or {}
    db.settings = db.settings or {}
    db.ui = db.ui or {}
    return db
end

-- Data-only copy of the save root with runtime fields removed. Accepts a session or a root.
function Save.Snapshot(world)
    local root = world.root or world
    local w = U.deepcopy(root)
    for _, a in pairs(w.residents or {}) do
        for _, k in ipairs(RUNTIME_ACTOR) do a[k] = nil end
        a.z = nil
    end
    for _, lot in pairs(w.hood and w.hood.lots or {}) do
        for _, o in pairs(lot.objects or {}) do
            for _, k in ipairs(RUNTIME_OBJECT) do o[k] = nil end
        end
    end
    return w
end

local function validLot(lot, id, p)
    if type(lot) ~= "table" or type(lot.w) ~= "number" or type(lot.h) ~= "number" then return false end
    if lot.w < 1 or lot.w > 64 or lot.h < 1 or lot.h > 64 then return false end
    lot.id = lot.id or id
    lot.floor = type(lot.floor) == "table" and lot.floor or {}
    lot.walls = type(lot.walls) == "table" and lot.walls or {}
    for level = 0, 1 do
        lot.floor[level] = type(lot.floor[level]) == "table" and lot.floor[level] or {}
        lot.walls[level] = type(lot.walls[level]) == "table" and lot.walls[level] or {}
    end
    lot.objects = type(lot.objects) == "table" and lot.objects or {}
    for oid, o in pairs(lot.objects) do
        if type(o) ~= "table" or not SS.Objects[o.def] or type(o.x) ~= "number" or type(o.y) ~= "number" then
            lot.objects[oid] = nil
            p[#p + 1] = "removed invalid object " .. tostring(oid) .. " on " .. tostring(id)
        end
    end
    lot.version = type(lot.version) == "number" and lot.version or 1
    return true
end

-- Returns ok, problems (array of strings). Repairs small problems in place.
function Save.Validate(w)
    local p = {}
    if type(w) ~= "table" then return false, { "save is not a table" } end
    if type(w.hood) ~= "table" or type(w.hood.lots) ~= "table" then return false, { "missing neighbourhood" } end
    for id, lot in pairs(w.hood.lots) do
        if not validLot(lot, id, p) then return false, { "lot " .. tostring(id) .. " is damaged" } end
    end
    if type(w.residents) ~= "table" or type(w.households) ~= "table" then return false, { "missing residents or households" } end
    if type(w.time) ~= "number" then w.time = SS.Tuning.startTime; p[#p + 1] = "clock reset" end
    for id, a in pairs(w.residents) do
        if type(a) ~= "table" or type(a.needs) ~= "table" or type(a.x) ~= "number" or type(a.y) ~= "number" then
            w.residents[id] = nil
            p[#p + 1] = "removed invalid resident " .. tostring(id)
        elseif a.lotId and not w.hood.lots[a.lotId] then
            a.lotId = nil
            p[#p + 1] = "resident " .. tostring(id) .. " lost their lot"
        end
    end
    for id, h in pairs(w.households) do
        if type(h) ~= "table" then
            w.households[id] = nil
        else
            if type(h.money) ~= "number" then h.money = 0; p[#p + 1] = "money reset for " .. tostring(id) end
            h.members = type(h.members) == "table" and h.members or {}
            local keep = {}
            for _, rid in ipairs(h.members) do if w.residents[rid] then keep[#keep + 1] = rid end end
            if #keep ~= #h.members then p[#p + 1] = "dropped missing members from " .. tostring(id) end
            h.members = keep
            h.ledger = type(h.ledger) == "table" and h.ledger or {}
            h.journal = type(h.journal) == "table" and h.journal or {}
            if h.lotId and not w.hood.lots[h.lotId] then h.lotId = nil; p[#p + 1] = "household " .. tostring(id) .. " lost its lot" end
        end
    end
    w.settings = type(w.settings) == "table" and w.settings or {}
    w.scheduled = type(w.scheduled) == "table" and w.scheduled or {}
    if type(w.active) ~= "table" or not w.hood.lots[w.active.lotId or ""] then
        w.active = nil
        for id, h in pairs(w.households) do if h.lotId then w.active = { householdId = id, lotId = h.lotId }; break end end
        if not w.active then return false, { "no playable household" } end
        p[#p + 1] = "active household reset"
    end
    for _, fn in ipairs(Save.validators) do
        local ok, why = fn(w, p)
        if ok == false then return false, { why or "a game system rejected the save" } end
    end
    return true, p
end

-- Schema migrations: MIGRATE[n] upgrades a world from schema n to n+1.
Save.MIGRATE = {}

-- 1 -> 2: single lot/household save becomes a neighbourhood with one lot; walls/floors get levels.
Save.MIGRATE[1] = function(w)
    local lot = w.lot
    lot.kind, lot.price, lot.version = lot.kind or "residential", lot.price or 0, 1
    lot.floor = { [0] = lot.floor or {}, [1] = {} }
    lot.walls = { [0] = lot.walls or {}, [1] = {} }
    lot.roof = lot.roof or { style = "hipped", material = "shingle", color = "terracotta" }
    for _, o in pairs(lot.objects or {}) do o.level = o.level or 0 end
    local hh = w.household or { id = "hh_1", name = "Household", members = {} }
    hh.money, hh.ledger, hh.journal, hh.lotId = w.money or 0, w.ledger or {}, w.journal or {}, lot.id
    w.hood = { id = "hood_linden", name = "Linden Hollow", lots = { [lot.id] = lot } }
    w.households = { [hh.id] = hh }
    w.residents = w.actors or {}
    for _, a in pairs(w.residents) do a.lotId, a.householdId, a.level = lot.id, hh.id, 0 end
    w.active = { householdId = hh.id, lotId = lot.id }
    w.lot, w.household, w.actors, w.money, w.ledger, w.journal = nil, nil, nil, nil, nil, nil
end

function Save.Migrate(w)
    local v = w.schema or 1
    while v < SS.SCHEMA do
        local f = Save.MIGRATE[v]
        if not f then return false end
        local ok = pcall(f, w)
        if not ok then return false end
        v = v + 1
        w.schema = v
    end
    return v == SS.SCHEMA
end

function Save.Write(slot, world, name)
    local db = Save.DB()
    local snap = Save.Snapshot(world)
    local ok, problems = Save.Validate(snap)
    if not ok then return false, "Save refused, the game state failed validation: " .. table.concat(problems, "; ") end
    local prev = db.slots[slot]
    if prev and prev.world and Save.Validate(U.deepcopy(prev.world)) then
        db.lastGood = { slot = slot, savedAt = prev.savedAt, world = prev.world }
    end
    db.slots[slot] = { name = name or (prev and prev.name) or ("Save " .. slot), savedAt = stamp(), world = snap }
    db.active = slot
    return true
end

-- Returns world or nil, message.
function Save.Read(slot)
    local db = Save.DB()
    local s = db.slots[slot]
    if not s or not s.world then return nil, "Slot " .. slot .. " is empty." end
    local w = U.deepcopy(s.world)
    if not Save.Migrate(w) then return nil, "Save uses an unknown schema." end
    local ok, problems = Save.Validate(w)
    if not ok then
        if db.lastGood and db.lastGood.slot == slot then
            local g = U.deepcopy(db.lastGood.world)
            if Save.Migrate(g) and Save.Validate(g) then return g, "Slot " .. slot .. " was damaged; loaded the previous good save." end
        end
        return nil, "Slot " .. slot .. " is damaged: " .. table.concat(problems, "; ")
    end
    return w, (#problems > 0) and ("Loaded with repairs: " .. table.concat(problems, "; ")) or nil
end
