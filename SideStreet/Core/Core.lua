-- SideStreet core: namespace, small utilities, deterministic RNG, bounded log.
-- Pure Lua 5.1; no WoW API calls at load time (the offline test harness loads this file).
local ADDON, SS = ...
SS.ADDON = ADDON or "SideStreet"
-- Object tags: systems attach interactions to every object definition carrying a tag
-- (e.g. SS.Tags.Attach("bookshelf", "study_cooking")). Object data loads before Sim files,
-- so attaching at load time patches all current definitions; later definitions call Apply.
SS.Tags = { map = {} }
function SS.Tags.Attach(tag, iid)
    local m = SS.Tags.map
    m[tag] = m[tag] or {}
    for _, v in ipairs(m[tag]) do if v == iid then return end end
    m[tag][#m[tag] + 1] = iid
    for id, def in pairs(SS.Objects or {}) do SS.Tags.Apply(def) end
end
function SS.Tags.Has(def, tag)
    for _, t in ipairs(def.tags or {}) do if t == tag then return true end end
    return false
end
function SS.Tags.Apply(def)
    for _, tag in ipairs(def.tags or {}) do
        for _, iid in ipairs(SS.Tags.map[tag] or {}) do
            def.actions = def.actions or {}
            local have = false
            for _, a in ipairs(def.actions) do if a == iid then have = true; break end end
            if not have then def.actions[#def.actions + 1] = iid end
        end
    end
end

SS.VERSION = "0.2.0"
SS.SCHEMA = 2

local U = {}
SS.U = U

function U.clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

function U.deepcopy(t, seen)
    if type(t) ~= "table" then return t end
    seen = seen or {}
    if seen[t] then error("SideStreet: cyclic table in save data") end
    seen[t] = true
    local out = {}
    for k, v in pairs(t) do
        local tk, tv = type(k), type(v)
        if (tk == "string" or tk == "number" or tk == "boolean")
            and (tv == "string" or tv == "number" or tv == "boolean" or tv == "table") then
            out[k] = U.deepcopy(v, seen)
        end
    end
    seen[t] = nil
    return out
end

function U.round(v) return math.floor(v + 0.5) end

-- Park-Miller minimal standard RNG. Products stay below 2^53, so results are
-- identical in WoW and in the offline harness for a given seed.
function U.rng(state)
    state = (state * 16807) % 2147483647
    return state, state / 2147483647
end

-- Seeded, saved random streams: SS.Random(world, "fire") -> [0,1). Each system uses its
-- own stream name so adding one system never changes another system's rolls. State lives in
-- root.rng[stream] (saved), seeded from root.seed and the stream name.
function SS.Random(world, stream)
    local root = world.root or world
    root.rng = root.rng or {}
    local st = root.rng[stream]
    if not st then
        local h = (root.seed or 1) % 2147483646 + 1
        for i = 1, #stream do h = (h * 31 + stream:byte(i)) % 2147483646 + 1 end
        st = h
    end
    local v
    st, v = U.rng(st)
    root.rng[stream] = st
    return v
end
function SS.RandomInt(world, stream, lo, hi) return lo + math.floor(SS.Random(world, stream) * (hi - lo + 1)) end
function SS.Pick(world, stream, list) if #list == 0 then return nil end; return list[SS.RandomInt(world, stream, 1, #list)] end

function U.fmtMoney(v) return "\194\167" .. tostring(math.floor(v)) end -- section-sign as the currency mark

-- Bounded ring log (debug/diagnostic). Never grows past its cap.
local LOG_CAP = 200
SS.logBuf, SS.logPos = {}, 0
function SS.Log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    SS.logPos = SS.logPos % LOG_CAP + 1
    SS.logBuf[SS.logPos] = ok and msg or tostring(fmt)
end

-- Simple event bus between sim, UI and audio (not WoW events).
local subs = {}
function SS.On(name, fn)
    subs[name] = subs[name] or {}
    table.insert(subs[name], fn)
end
function SS.Emit(name, ...)
    local l = subs[name]
    if not l then return end
    for i = 1, #l do l[i](...) end
end
