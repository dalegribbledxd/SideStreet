-- SideStreet household creator (fullscreen mode "create"): design 1-8 people (adults and
-- children) with names, a household name and bio, appearance (skin tone, hair style and colour,
-- body, face, and outfits for everyday, sleep, swim, work and formal), pronouns, family, partner
-- and roommate ties, the five personality dimensions on a 25-point budget with archetype presets,
-- randomise and the tradeoffs in words, and interests. Saving creates the household in the
-- household bin with the starting money (SS.Households.Create) or updates a reopened household
-- (SS.Households.Update: members keep their ids). Looks and pronouns never set skills or
-- personality: nothing in this file reads one to change the other.
-- The spec logic is pure (CU.* functions on st.spec) so tests can drive it without frames.
-- Owner: hood module (docs/modules/hood.md).
local _, SS = ...
local UI = SS.UI
local HD, H, HH = SS.HoodData, SS.Hood, SS.Households
local U = SS.U
local T = HD.Tuning
local CU = SS.CreateUI or {}
SS.CreateUI = CU

CU.state = CU.state or { spec = nil, sel = 1, tab = "identity", editing = nil, outfit = "everyday", problems = {} }
local st = CU.state

local function notice(msg) if msg and UI.Notice then UI.Notice(msg) end end
local function root() return (SS.HoodUI and SS.HoodUI.Root and SS.HoodUI.Root()) or (SS.Sim and SS.Sim.root) end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function find(list, id) for n, e in ipairs(list) do if e.id == id then return e, n end end end
local function copy3(c) return { c[1], c[2], c[3] } end
local function money(v) return U.fmtMoney(v) end

-- Original name suggestions (first names for adults and children, household surnames).
CU.FirstNames = { "Mara", "Tobin", "Ines", "Calder", "Priya", "Otis", "Wren", "Dmitri", "Lale", "Ansel", "Noor", "Felix",
    "Juno", "Rafe", "Tamsin", "Soren", "Ada", "Ezra", "Lucia", "Bram" }
CU.ChildNames = { "Pip", "Milo", "Hazel", "Kit", "Bea", "Arlo", "Nell", "Rory", "Tess", "Olly", "Suki", "Finn" }
CU.Surnames = { "Penhallow", "Quillon", "Ashdown", "Merrow", "Tolliver", "Brandish", "Okoro", "Lindell", "Farrant", "Dunmore",
    "Whitlock", "Amberly" }

---------------------------------------------------------------------------
-- Random numbers: the save's "creator" stream (deterministic per save), or a local stream
-- when no game is loaded.
---------------------------------------------------------------------------
local localSeed = 12345
function CU.Rand()
    local r = root()
    if r and SS.Random then return SS.Random(r, "creator") end
    local v
    localSeed, v = U.rng(localSeed)
    return v
end
local function randInt(lo, hi) return lo + math.floor(CU.Rand() * (hi - lo + 1)) end
local function pick(list) return list[randInt(1, #list)] end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------
function CU.SplitName(name, fallbackLast)
    name = trim(name)
    local first, last = name:match("^(.-)%s+(%S+)$")
    if not first or first == "" then return name, fallbackLast or "" end
    return first, last
end

function CU.SyncName(mem)
    mem.first, mem.last = trim(mem.first), trim(mem.last)
    mem.name = trim(mem.first .. " " .. mem.last)
    return mem.name
end

-- A household name nobody in town uses yet.
function CU.SuggestSurname()
    local r = root()
    local used = {}
    for _, hh in pairs(r and r.households or {}) do used[(hh.name or ""):lower()] = true end
    for _, n in ipairs(CU.Surnames) do if not used[n:lower()] then return n end end
    return CU.Surnames[1]
end

function CU.SuggestFirst(spec, age)
    local used = {}
    for _, m in ipairs(spec and spec.members or {}) do used[(m.first or ""):lower()] = true end
    local pool = age == "child" and CU.ChildNames or CU.FirstNames
    local start = randInt(1, #pool)
    for k = 0, #pool - 1 do
        local n = pool[(start + k - 1) % #pool + 1]
        if not used[n:lower()] then return n end
    end
    return pool[start]
end

---------------------------------------------------------------------------
-- Appearance
---------------------------------------------------------------------------
-- Sprite names the art module is asked to provide (docs/art_requests/hood.md). Colours are tints
-- of shared layers, so skin, hair colour and clothing colours need the base layer only.
CU.ArtName = {
    skin = function() return "portrait:head" end,
    hair = function() return "portrait:head" end,
    hairStyle = function(id) return "portrait:hair:" .. id end,
    face = function(id) return "portrait:face:" .. tostring(id) end,
    body = function(id) return "person:body:" .. id end,
    outfit = function(id, kind) return "person:outfit:" .. kind .. ":" .. id end,
}
function CU.HasArt(part, id, kind)
    local f = CU.ArtName[part]
    local A = SS.Art
    if not (f and A and A.sprites) then return false end
    return A.sprites[f(id, kind)] ~= nil
end

local function styleIds(kind) local out = {} for _, s in ipairs(HD.OutfitStyles[kind]) do out[#out + 1] = s.id end return out end

function CU.DefaultLook(n)
    n = n or 1
    local look = {
        skinId = HD.SkinTones[(n * 3) % #HD.SkinTones + 1].id,
        hairId = HD.HairColors[(n * 5) % #HD.HairColors + 1].id,
        hairStyle = HD.HairStyles[(n * 3) % #HD.HairStyles + 1].id,
        body = HD.Bodies[n % #HD.Bodies + 1].id,
        face = HD.Faces[n % #HD.Faces + 1].id,
        outfits = {},
    }
    for k, kind in ipairs(HD.OutfitKinds) do
        local styles = HD.OutfitStyles[kind]
        look.outfits[kind] = { style = styles[(n + k) % #styles + 1].id,
            top = copy3(HD.ClothColors[(n * 2 + k) % #HD.ClothColors + 1]),
            bottom = copy3(HD.ClothColors[(n + k * 3) % #HD.ClothColors + 1]),
            shoes = copy3(HD.ClothColors[(n + 8) % #HD.ClothColors + 1]) }
    end
    return look
end

local function colourIndex(c)
    if type(c) ~= "table" then return 0 end
    for n, p in ipairs(HD.ClothColors) do
        if math.abs(p[1] - c[1]) < 0.005 and math.abs(p[2] - c[2]) < 0.005 and math.abs(p[3] - c[3]) < 0.005 then return n end
    end
    return 0
end
CU.ColourIndex = colourIndex

local LOOK_LISTS = {
    skin = { list = HD.SkinTones, field = "skinId" }, hair = { list = HD.HairColors, field = "hairId" },
    hairStyle = { list = HD.HairStyles, field = "hairStyle" }, body = { list = HD.Bodies, field = "body" },
    face = { list = HD.Faces, field = "face" },
}
CU.LookParts = { "skin", "hairStyle", "hair", "body", "face" }
CU.LookLabel = { skin = "Skin tone", hairStyle = "Hair style", hair = "Hair colour", body = "Body", face = "Face" }

-- Current option of a look part: entry, index.
function CU.LookValue(mem, part)
    local L = LOOK_LISTS[part]
    local e, n = find(L.list, mem.look[L.field])
    if not e then e, n = L.list[1], 1 end
    return e, n
end

function CU.SetLook(mem, part, id)
    local L = LOOK_LISTS[part]
    if not L then return false, "Unknown part of the look." end
    if not find(L.list, id) then return false, "That option does not exist." end
    mem.look[L.field] = id
    return true
end

function CU.CycleLook(mem, part, dir)
    local L = LOOK_LISTS[part]
    local _, n = CU.LookValue(mem, part)
    local e = L.list[(n - 1 + (dir or 1)) % #L.list + 1]
    mem.look[L.field] = e.id
    return e
end

-- Outfits: field is "style", "top", "bottom" or "shoes".
function CU.CycleOutfit(mem, kind, field, dir)
    mem.look.outfits = mem.look.outfits or {}
    local o = mem.look.outfits[kind]
    if not o then o = CU.DefaultLook(1).outfits[kind]; mem.look.outfits[kind] = o end
    if field == "style" then
        local styles = HD.OutfitStyles[kind]
        local _, n = find(styles, o.style)
        o.style = styles[((n or 1) - 1 + (dir or 1)) % #styles + 1].id
        return o.style
    end
    local n = colourIndex(o[field])
    n = (math.max(n, 1) - 1 + (dir or 1)) % #HD.ClothColors + 1
    if colourIndex(o[field]) == 0 and (dir or 1) > 0 then n = 1 end
    o[field] = copy3(HD.ClothColors[n])
    return n
end

function CU.RandomLook(mem)
    local look = { skinId = pick(HD.SkinTones).id, hairId = pick(HD.HairColors).id, hairStyle = pick(HD.HairStyles).id,
        body = pick(HD.Bodies).id, face = pick(HD.Faces).id, outfits = {} }
    for _, kind in ipairs(HD.OutfitKinds) do
        look.outfits[kind] = { style = pick(styleIds(kind)), top = copy3(pick(HD.ClothColors)), bottom = copy3(pick(HD.ClothColors)),
            shoes = copy3(pick(HD.ClothColors)) }
    end
    mem.look = look
    return look
end

-- A person-shaped table for portraits, wearing `outfitKind`.
function CU.Person(mem, outfitKind)
    local look = HH.NormalizeLook(mem.look)
    local o = look.outfits[outfitKind or "everyday"] or look.outfits.everyday
    look.top, look.bottom, look.shoes = copy3(o.top), copy3(o.bottom), copy3(o.shoes)
    look.outfitStyle = o.style
    return { name = mem.name ~= "" and mem.name or "?", age = mem.age, pronoun = mem.pronoun, look = look, outfit = outfitKind or "everyday" }
end

---------------------------------------------------------------------------
-- Members and the spec
---------------------------------------------------------------------------
function CU.NewMember(spec, age)
    age = age or "adult"
    local n = #spec.members + 1
    local mem = { first = CU.SuggestFirst(spec, age), last = trim(spec.name), age = age,
        pronoun = HD.Pronouns[(n - 1) % #HD.Pronouns + 1], bio = "", look = CU.DefaultLook(n + #(spec.name or "")),
        personality = {}, interests = {} }
    for _, d in ipairs(HD.Dims) do mem.personality[d] = 5 end
    mem.interests = CU.DefaultInterests(mem, n)
    CU.SyncName(mem)
    return mem
end

function CU.NewSpec()
    local spec = { name = CU.SuggestSurname(), bio = "", members = {}, rels = {} }
    spec.members[1] = CU.NewMember(spec, "adult")
    return spec
end

-- Prepare a spec from SS.Households.ToSpec for editing (first/last names).
function CU.FromSpec(spec)
    for _, m in ipairs(spec.members) do
        m.first, m.last = CU.SplitName(m.name, spec.name)
        m.bio = m.bio or ""
        m.look = m.look or CU.DefaultLook(1)
        m.personality = m.personality or {}
        for _, d in ipairs(HD.Dims) do if type(m.personality[d]) ~= "number" then m.personality[d] = 0 end end
        m.interests = m.interests or {}
        CU.SyncName(m)
    end
    spec.bio = spec.bio or ""
    spec.rels = spec.rels or {}
    return spec
end

function CU.AddMember(spec, age)
    if #spec.members >= T.capacity then return false, "A household holds at most " .. T.capacity .. " people." end
    if age ~= "adult" and age ~= "child" then return false, "Choose adult or child." end
    spec.members[#spec.members + 1] = CU.NewMember(spec, age)
    return true, nil, #spec.members
end

function CU.RemoveMember(spec, idx)
    local m = spec.members[idx]
    if not m then return false, "Nobody to remove there." end
    if #spec.members == 1 then return false, "A household needs at least one person." end
    local adults = 0
    for _, o in ipairs(spec.members) do if o.age == "adult" then adults = adults + 1 end end
    if m.age == "adult" and adults == 1 then return false, "Children cannot live on their own: keep at least one adult." end
    table.remove(spec.members, idx)
    local rels = {}
    for _, r in ipairs(spec.rels) do
        if r.a ~= idx and r.b ~= idx then
            rels[#rels + 1] = { a = r.a > idx and r.a - 1 or r.a, b = r.b > idx and r.b - 1 or r.b, kind = r.kind }
        end
    end
    spec.rels = rels
    return true
end

local INVERSE = { parent = "child", child = "parent" }
local function kindDef(id) for _, k in ipairs(HD.RelKinds) do if k.id == id then return k end end end

-- Relationship of member i toward member j: kind id (from i's side), rel entry, entry index.
function CU.RelBetween(spec, i, j)
    for n, r in ipairs(spec.rels) do
        if r.a == i and r.b == j then return r.kind, r, n end
        if r.a == j and r.b == i then return INVERSE[r.kind] or r.kind, r, n end
    end
    return "none"
end

-- Which ties i can have toward j (by age; family kinds come from HD.RelKinds).
function CU.RelChoices(spec, i, j)
    local a, b = spec.members[i], spec.members[j]
    local out = {}
    if not (a and b) or i == j then return out end
    for _, k in ipairs(HD.RelKinds) do
        local ok = true
        if k.adultsOnly and (a.age ~= "adult" or b.age ~= "adult") then ok = false end
        if k.id == "parent" and (a.age ~= "adult" or b.age ~= "child") then ok = false end
        if k.id == "child" and (a.age ~= "child" or b.age ~= "adult") then ok = false end
        if k.id == "roommate" and (a.age ~= "adult" or b.age ~= "adult") then ok = false end
        if ok then out[#out + 1] = k.id end
    end
    return out
end

local EXCLUSIVE = { spouse = true, partner = true }
function CU.SetRel(spec, i, j, kind)
    local a, b = spec.members[i], spec.members[j]
    if not (a and b) or i == j then return false, "A relationship needs two different people." end
    local k = kindDef(kind)
    if not k then return false, "Unknown relationship." end
    local allowed = false
    for _, id in ipairs(CU.RelChoices(spec, i, j)) do if id == kind then allowed = true end end
    if not allowed then
        if k.adultsOnly or kind == "roommate" then return false, k.name .. " is for two adults." end
        if kind == "parent" then return false, "A parent must be an adult and the other person a child." end
        if kind == "child" then return false, "Only a child can be the child of an adult." end
        return false, "That tie does not fit these two."
    end
    if EXCLUSIVE[kind] then
        for n2, other in ipairs(spec.members) do
            if n2 ~= i and n2 ~= j then
                for _, who in ipairs({ i, j }) do
                    local ck = CU.RelBetween(spec, who, n2)
                    if EXCLUSIVE[ck] then
                        return false, spec.members[who].name .. " already has a " .. kindDef(ck).name:lower() .. " (" .. other.name .. ")."
                    end
                end
            end
        end
    end
    local _, _, idx = CU.RelBetween(spec, i, j)
    if idx then table.remove(spec.rels, idx) end
    if kind ~= "none" then spec.rels[#spec.rels + 1] = { a = i, b = j, kind = kind } end
    return true
end

function CU.CycleRel(spec, i, j, dir)
    local choices = CU.RelChoices(spec, i, j)
    if #choices == 0 then return false, "Pick two different people." end
    local cur = CU.RelBetween(spec, i, j)
    local n = 1
    for k, id in ipairs(choices) do if id == cur then n = k end end
    for step = 1, #choices do
        local id = choices[(n - 1 + step * (dir or 1)) % #choices + 1]
        local ok, why = CU.SetRel(spec, i, j, id)
        if ok then return true, id end
        if step == #choices then return false, why end
    end
    return false, "No other tie fits."
end

-- Change a member's age; ties that no longer fit are dropped (reported).
function CU.SetAge(spec, idx, age)
    local m = spec.members[idx]
    if not m then return false, "Nobody there." end
    if age ~= "adult" and age ~= "child" then return false, "Choose adult or child." end
    if m.age == age then return true end
    if age == "child" then
        local adults = 0
        for _, o in ipairs(spec.members) do if o.age == "adult" then adults = adults + 1 end end
        if adults <= 1 then return false, "Someone has to be an adult: children cannot live on their own." end
    end
    m.age = age
    local dropped = {}
    for n = #spec.rels, 1, -1 do
        local r = spec.rels[n]
        local ok = false
        for _, id in ipairs(CU.RelChoices(spec, r.a, r.b)) do if id == r.kind then ok = true end end
        if not ok then
            dropped[#dropped + 1] = spec.members[r.a == idx and r.b or r.a].name
            table.remove(spec.rels, n)
        end
    end
    if #dropped > 0 then return true, "Ties that no longer fit were removed (" .. table.concat(dropped, ", ") .. ")." end
    return true
end

function CU.SetPronoun(mem, p)
    for _, x in ipairs(HD.Pronouns) do if x == p then mem.pronoun = p; return true end end
    return false, "Choose she, he or they."
end

---------------------------------------------------------------------------
-- Personality and interests. The social module's personality model is used when it is present
-- (SS.Personality: LABELS, Describe, TRADEOFFS, Validate, DefaultInterests, RandomInterests);
-- this module's own data (HD.DimInfo, HD.FallbackTopics) otherwise.
---------------------------------------------------------------------------
local function PS()
    local P = SS.Personality
    if type(P) == "table" and type(P.LABELS) == "table" and type(P.TRADEOFFS) == "table" then return P end
end
CU.PersonalityModel = PS

-- { name, low, high, icon? } for a dimension.
function CU.DimLabel(d)
    local P = PS()
    local L = P and P.LABELS[d]
    if type(L) == "table" and L.name then return L end
    local info = HD.DimInfo[d]
    return { name = info.name, low = info.low, high = info.high }
end

-- The sentence for a value (social's band sentences; this module's low/high text otherwise).
function CU.DimBand(d, v)
    local P = PS()
    if P and P.Describe then
        local ok, text = pcall(P.Describe, d, v)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    local info = HD.DimInfo[d]
    if v <= 3 then return info.lowText elseif v >= 7 then return info.highText end
    return "Between " .. info.low:lower() .. " and " .. info.high:lower() .. ": a little of both, no extremes."
end

-- What the dimension trades off in play (the "explain tradeoffs" text).
function CU.DimTradeoff(d)
    local P = PS()
    local text = P and P.TRADEOFFS[d]
    if type(text) == "string" and text ~= "" then return text end
    local info = HD.DimInfo[d]
    return info.high .. ": " .. info.highText .. " " .. info.low .. ": " .. info.lowText
end

function CU.PointsUsed(mem)
    local s = 0
    for _, d in ipairs(HD.Dims) do s = s + (mem.personality[d] or 0) end
    return s
end
function CU.PointsLeft(mem) return T.personalityBudget - CU.PointsUsed(mem) end

function CU.SetDim(mem, dim, v)
    if not HD.DimInfo[dim] then return false, "Unknown personality trait." end
    v = math.floor(tonumber(v) or 0)
    if v < 0 or v > T.personalityMax then return false, HD.DimInfo[dim].name .. " goes from 0 to " .. T.personalityMax .. "." end
    local cur = mem.personality[dim] or 0
    if v > cur and CU.PointsUsed(mem) - cur + v > T.personalityBudget then
        return false, "No points left: the budget is " .. T.personalityBudget .. ". Take a point from another trait first."
    end
    mem.personality[dim] = v
    return true
end

function CU.ApplyPreset(mem, id)
    local p = find(HD.Presets, id)
    if not p then return false, "Unknown archetype." end
    for _, d in ipairs(HD.Dims) do mem.personality[d] = p.p[d] end
    return true, p
end

function CU.MatchPreset(mem)
    for _, p in ipairs(HD.Presets) do
        local same = true
        for _, d in ipairs(HD.Dims) do if p.p[d] ~= mem.personality[d] then same = false end end
        if same then return p end
    end
end

-- Spend all 25 points at random (each trait 0..10).
function CU.RandomPersonality(mem)
    local pers = {}
    for _, d in ipairs(HD.Dims) do pers[d] = 0 end
    for _ = 1, T.personalityBudget do
        local open = {}
        for _, d in ipairs(HD.Dims) do if pers[d] < T.personalityMax then open[#open + 1] = d end end
        local d = pick(open)
        pers[d] = pers[d] + 1
    end
    mem.personality = pers
    return pers
end

-- Tradeoffs in words for the current values (the creator's explanation text): one line per
-- dimension with the value's sentence.
function CU.Tradeoffs(mem)
    local out = {}
    for _, d in ipairs(HD.Dims) do
        local L, v = CU.DimLabel(d), mem.personality[d] or 0
        local word = (v <= 3 and L.low) or (v >= 7 and L.high) or "Balanced"
        out[#out + 1] = string.format("%s %d (%s): %s", L.name, v, word, CU.DimBand(d, v))
    end
    return out
end

-- Personality check for one member: SS.Personality.Validate (budget 25) when present.
-- Returns ok, why.
function CU.CheckPersonality(mem)
    local P = PS()
    if P and P.Validate then
        local ok, valid, why = pcall(P.Validate, mem.personality, T.personalityBudget)
        if ok then
            if valid then return true end
            return false, type(why) == "string" and why or "Check the personality points."
        end
    end
    local used = CU.PointsUsed(mem)
    if used > T.personalityBudget then return false, "That uses " .. used .. " points; the budget is " .. T.personalityBudget .. "." end
    return true
end

function CU.SetInterest(mem, topic, v)
    if not H.TopicValid(topic) then return false, "Unknown interest." end
    v = math.floor(tonumber(v) or 0)
    if v < 0 or v > T.interestMax then return false, "Interests go from 0 to " .. T.interestMax .. "." end
    mem.interests[topic] = v > 0 and v or nil
    return true
end

local function validInterests(map)
    local out = {}
    for k, v in pairs(type(map) == "table" and map or {}) do
        if H.TopicValid(k) and type(v) == "number" then
            v = math.max(0, math.min(T.interestMax, math.floor(v)))
            if v > 0 then out[k] = v end
        end
    end
    return out
end

-- A person-like view of a member for the social module's interest functions.
local function asPerson(mem, n)
    return { id = "creator:" .. (n or 1) .. ":" .. tostring(mem.first or mem.name or ""), age = mem.age, personality = mem.personality }
end

-- Random interests: SS.Personality.RandomInterests on the save's "creator" stream when present
-- (2-3 loves, 1-2 dislikes); otherwise 2-4 topics at random.
function CU.RandomInterests(mem)
    local P = PS()
    local r = root()
    if P and P.RandomInterests and r and SS.RandomInt then
        local ok, map = pcall(P.RandomInterests, r, asPerson(mem), "creator")
        if ok and type(map) == "table" and next(map) then
            mem.interests = validInterests(map)
            return mem.interests
        end
    end
    local topics = H.Topics()
    local out = {}
    local n = randInt(2, 4)
    for _ = 1, n do
        local t = pick(topics)
        out[t.id] = randInt(3, T.interestMax)
    end
    mem.interests = out
    return out
end

-- Starting interests for a new member that follow the personality (SS.Personality.DefaultInterests
-- when present; none otherwise, the player picks).
function CU.DefaultInterests(mem, n)
    local P = PS()
    if P and P.DefaultInterests then
        local ok, map = pcall(P.DefaultInterests, asPerson(mem, n))
        if ok and type(map) == "table" then return validInterests(map) end
    end
    return {}
end

-- Randomise one member: looks, personality and interests (never skills; names stay).
function CU.Randomise(mem)
    CU.RandomLook(mem)
    CU.RandomPersonality(mem)
    CU.RandomInterests(mem)
end

---------------------------------------------------------------------------
-- Validation and saving
---------------------------------------------------------------------------
function CU.SetHouseholdName(spec, name)
    local old = trim(spec.name)
    name = tostring(name or "")
    for _, m in ipairs(spec.members) do
        if trim(m.last) == old or trim(m.last) == "" then m.last = trim(name); CU.SyncName(m) end
    end
    spec.name = name
end

function CU.Validate(spec)
    spec = spec or st.spec
    for _, m in ipairs(spec.members) do CU.SyncName(m) end
    local ok, problems = HH.ValidateSpec(spec)
    return ok, problems
end

-- Save the creator's household. Returns hh or nil, why, problems.
function CU.Save()
    local r = root()
    if not r then return nil, "No game is loaded." end
    local spec = st.spec
    if not spec then return nil, "Nothing to save." end
    local ok, problems = CU.Validate(spec)
    st.problems = problems or {}
    if not ok then
        notice(problems[1])
        CU.Refresh()
        return nil, problems[1], problems
    end
    local hh, why, probs
    if st.editing and r.households[st.editing] then hh, why, probs = HH.Update(r, st.editing, spec)
    else hh, why, probs = HH.Create(r, spec) end
    if not hh then
        st.problems = probs or { why }
        notice(why)
        CU.Refresh()
        return nil, why, probs
    end
    local msg = st.editing and ("Saved the " .. hh.name .. " household.")
        or ("The " .. hh.name .. " household moved into town with " .. money(hh.money) .. ". Pick a lot for sale to move them in.")
    notice(msg)
    st.spec, st.editing, st.problems = nil, nil, {}
    if SS.HoodUI and SS.HoodUI.Open and UI.modes.hood then SS.HoodUI.Open(nil, hh.id)
    elseif UI.SetMode then UI.SetMode(st.returnMode or "live") end
    return hh, msg
end

-- Start a new household (hhId nil) or reopen one.
function CU.Begin(hhId)
    local r = root()
    if hhId then
        local spec, why = HH.ToSpec(r, hhId)
        if not spec then return false, why end
        if #spec.members == 0 then return false, "Nobody is left in that household to edit." end
        st.spec, st.editing = CU.FromSpec(spec), hhId
    else
        st.spec, st.editing = CU.NewSpec(), nil
    end
    st.sel, st.tab, st.problems, st.outfit = 1, "identity", {}, "everyday"
    return true
end

function CU.Open(hhId)
    if not root() then notice("No game is loaded."); return false end
    local ok, why = CU.Begin(hhId)
    if not ok then notice(why); return false, why end
    if UI.mode ~= "create" then
        st.returnMode = UI.mode
        st.opened = true
        if UI.SetMode then UI.SetMode("create") end
    else CU.Refresh() end
    return true
end

function CU.Cancel()
    st.spec, st.editing, st.problems = nil, nil, {}
    local back = st.returnMode
    if not (back and (back == "live" or UI.modes[back])) or back == "create" then back = UI.modes.hood and "hood" or "live" end
    if UI.SetMode then UI.SetMode(back) end
end

function CU.Member() return st.spec and st.spec.members[st.sel] end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local K = UI.Kit
local COL = K.COL
local TABS = { { "identity", "Identity" }, { "looks", "Looks" }, { "personality", "Personality" }, { "interests", "Interests" }, { "family", "Ties" } }

local function button(parent, label, w, h, onClick, tip)
    local b
    b = K.Button(parent, label, w, h, onClick, function()
        local t = b.ssTipText or tip or ""
        if b.ssWhyText then t = (t ~= "" and (t .. "\n") or "") .. "Unavailable: " .. b.ssWhyText end
        return t
    end)
    b.ssTipText = tip
    local click = b:GetScript("OnClick")
    b:SetScript("OnClick", function(self, btn)
        if self.ssDisabled then notice(self.ssWhyText or "Not available right now."); return end
        if click then click(self, btn) end
    end)
    if b.RegisterForClicks then b:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    return b
end
local function usable(b, on, why) b.ssWhyText = (not on) and why or nil; b:SetUsable(on and true or false) end

local function editBox(parent, w, maxLetters, onChange, multi)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetSize(w, multi and 44 or 20)
    e:SetAutoFocus(false)
    if e.SetFontObject then e:SetFontObject(GameFontHighlightSmall or GameFontHighlight) end
    if e.SetTextColor then e:SetTextColor(0.12, 0.1, 0.08) end
    if multi and e.SetMultiLine then e:SetMultiLine(true) end
    e:SetMaxLetters(maxLetters)
    if e.SetTextInsets then e:SetTextInsets(4, 4, 2, 2) end
    K.Tex(e, "BACKGROUND", { 1, 1, 1, 0.9 }):SetAllPoints()
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEnterPressed", function(self) if not multi then self:ClearFocus() end end)
    e:SetScript("OnTextChanged", function(self, user) if user then onChange(self:GetText()) end end)
    e:SetScript("OnEditFocusLost", function(self) onChange(self:GetText()); CU.Refresh() end)
    return e
end

-- A "< value >" row.
local function cycler(parent, label, x, y, w, onCycle, tip)
    local row = {}
    row.label = K.Text(parent, 11); row.label:SetPoint("TOPLEFT", x, y - 3); row.label:SetText(label)
    row.prev = button(parent, "<", 20, 20, function(_, btn) onCycle(-1, btn) end, tip)
    row.prev:SetPoint("TOPLEFT", x + 96, y)
    row.value = K.Text(parent, 11, COL.ink, "CENTER"); row.value:SetPoint("TOPLEFT", x + 118, y - 3); row.value:SetWidth(w - 164)
    row.next = button(parent, ">", 20, 20, function(_, btn) onCycle(1, btn) end, tip)
    row.next:SetPoint("TOPLEFT", x + w - 44, y)
    row.swatch = K.Tex(parent, "ARTWORK", { 1, 1, 1, 1 }); row.swatch:SetSize(16, 16); row.swatch:SetPoint("TOPLEFT", x + w - 20, y - 2)
    row.swatch:Hide()
    return row
end

local function page(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetPoint("TOPLEFT", 0, -28); p:SetPoint("BOTTOMRIGHT")
    p:Hide()
    return p
end

local function changed() CU.Refresh() end

local function buildIdentity(p)
    local w = {}
    local l1 = K.Text(p, 11); l1:SetPoint("TOPLEFT", 8, -10); l1:SetText("First name")
    w.first = editBox(p, 140, T.nameMax, function(t) local m = CU.Member(); if m then m.first = t; CU.SyncName(m) end end)
    w.first:SetPoint("TOPLEFT", 96, -6)
    w.suggest = button(p, "Suggest", 64, 20, function()
        local m = CU.Member(); if not m then return end
        m.first = CU.SuggestFirst(st.spec, m.age); CU.SyncName(m); changed()
    end, "Suggest an unused first name")
    w.suggest:SetPoint("LEFT", w.first, "RIGHT", 6, 0)
    local l2 = K.Text(p, 11); l2:SetPoint("TOPLEFT", 8, -36); l2:SetText("Last name")
    w.last = editBox(p, 140, T.nameMax, function(t) local m = CU.Member(); if m then m.last = t; CU.SyncName(m) end end)
    w.last:SetPoint("TOPLEFT", 96, -32)
    local l3 = K.Text(p, 11); l3:SetPoint("TOPLEFT", 8, -64); l3:SetText("Age")
    w.ages = {}
    for n, age in ipairs(HD.Ages) do
        local b = button(p, age == "adult" and "Adult" or "Child", 70, 20, function()
            local ok, why = CU.SetAge(st.spec, st.sel, age)
            notice(why); if ok then changed() end
        end, age == "adult" and "Grown-up: works, pays bills, can be a parent, spouse or roommate." or "School-age child: goes to school; needs an adult at home.")
        b:SetPoint("TOPLEFT", 96 + (n - 1) * 74, -60)
        w.ages[age] = b
    end
    local l4 = K.Text(p, 11); l4:SetPoint("TOPLEFT", 8, -90); l4:SetText("Pronouns")
    w.pron = {}
    for n, pr in ipairs(HD.Pronouns) do
        local b = button(p, pr, 54, 20, function() local m = CU.Member(); if m then CU.SetPronoun(m, pr); changed() end end,
            "How the game refers to this person. It never changes skills, personality or looks.")
        b:SetPoint("TOPLEFT", 96 + (n - 1) * 58, -86)
        w.pron[pr] = b
    end
    local l5 = K.Text(p, 11); l5:SetPoint("TOPLEFT", 8, -116); l5:SetText("About them")
    w.bio = editBox(p, 300, T.bioMax, function(t) local m = CU.Member(); if m then m.bio = t end end, true)
    w.bio:SetPoint("TOPLEFT", 96, -112)
    w.note = K.Text(p, 10, COL.inkSoft); w.note:SetPoint("TOPLEFT", 8, -166); w.note:SetWidth(400)
    if w.note.SetWordWrap then w.note:SetWordWrap(true) end
    w.note:SetText("Pronouns and looks are only how someone is described and drawn. Skills start at zero for everyone; personality comes only from the points you spend.")
    return w
end

local function buildLooks(p)
    local w = { rows = {} }
    local y = -6
    for _, part in ipairs(CU.LookParts) do
        w.rows[part] = cycler(p, CU.LookLabel[part], 8, y, 380, function(d)
            local m = CU.Member(); if m then CU.CycleLook(m, part, d); changed() end
        end)
        y = y - 24
    end
    local l = K.Text(p, 11); l:SetPoint("TOPLEFT", 8, y - 6); l:SetText("Outfits")
    w.kinds = {}
    for n, kind in ipairs(HD.OutfitKinds) do
        local b = button(p, HD.OutfitLabel[kind], 70, 20, function() st.outfit = kind; changed() end, "Show and change the " .. HD.OutfitLabel[kind]:lower() .. " outfit")
        b:SetPoint("TOPLEFT", 60 + (n - 1) * 72, y - 2)
        w.kinds[kind] = b
    end
    y = y - 28
    w.outfit = {}
    for _, field in ipairs({ "style", "top", "bottom", "shoes" }) do
        local label = ({ style = "Style", top = "Top colour", bottom = "Bottom colour", shoes = "Shoes colour" })[field]
        w.outfit[field] = cycler(p, label, 8, y, 380, function(d)
            local m = CU.Member(); if m then CU.CycleOutfit(m, st.outfit, field, d); changed() end
        end)
        y = y - 24
    end
    w.random = button(p, "Randomise looks", 120, 20, function() local m = CU.Member(); if m then CU.RandomLook(m); changed() end end,
        "New random skin, hair, body, face and outfits (personality and skills are untouched)")
    w.random:SetPoint("TOPLEFT", 8, y - 6)
    w.art = K.Text(p, 10, COL.inkSoft); w.art:SetPoint("TOPLEFT", 136, y - 10); w.art:SetWidth(270)
    return w
end

local function buildPersonality(p)
    local w = { rows = {} }
    local y = -6
    for _, d in ipairs(HD.Dims) do
        local info = CU.DimLabel(d)
        local row = {}
        row.name = K.Text(p, 11); row.name:SetPoint("TOPLEFT", 8, y - 3); row.name:SetText(info.name)
        -- hovering the trait's name explains its tradeoffs
        row.hit = CreateFrame("Frame", nil, p)
        row.hit:SetSize(90, 18); row.hit:SetPoint("TOPLEFT", 6, y)
        if row.hit.EnableMouse then row.hit:EnableMouse(true) end
        K.Tooltip(row.hit, function() return info.name .. "\n" .. CU.DimTradeoff(d) end)
        row.low = K.Text(p, 9, COL.inkSoft, "RIGHT"); row.low:SetPoint("TOPRIGHT", p, "TOPLEFT", 150, y - 5); row.low:SetText(info.low)
        row.minus = button(p, "-", 18, 18, function()
            local m = CU.Member(); if not m then return end
            st.focusDim = d
            local ok, why = CU.SetDim(m, d, (m.personality[d] or 0) - 1); notice(why); changed()
        end, "One point less " .. info.high:lower())
        row.minus:SetPoint("TOPLEFT", 154, y)
        row.pips = {}
        for n = 1, T.personalityMax do
            local pip = CreateFrame("Button", nil, p)
            pip:SetSize(13, 16)
            pip:SetPoint("TOPLEFT", 174 + (n - 1) * 15, y - 1)
            pip.tex = K.Tex(pip, "ARTWORK", COL.barBg); pip.tex:SetAllPoints()
            pip:SetScript("OnClick", function()
                local m = CU.Member(); if not m then return end
                st.focusDim = d
                local v = (m.personality[d] == n) and n - 1 or n
                local ok, why = CU.SetDim(m, d, v); notice(why); changed()
            end)
            row.pips[n] = pip
        end
        row.plus = button(p, "+", 18, 18, function()
            local m = CU.Member(); if not m then return end
            st.focusDim = d
            local ok, why = CU.SetDim(m, d, (m.personality[d] or 0) + 1); notice(why); changed()
        end, "One point more " .. info.high:lower())
        row.plus:SetPoint("TOPLEFT", 174 + T.personalityMax * 15 + 2, y)
        row.high = K.Text(p, 9, COL.inkSoft); row.high:SetPoint("TOPLEFT", 174 + T.personalityMax * 15 + 24, y - 5); row.high:SetText(info.high)
        w.rows[d] = row
        y = y - 22
    end
    w.points = K.Text(p, 11); w.points:SetPoint("TOPLEFT", 8, y - 4)
    w.random = button(p, "Randomise", 80, 20, function() local m = CU.Member(); if m then CU.RandomPersonality(m); changed() end end,
        "Spend all " .. T.personalityBudget .. " points at random")
    w.random:SetPoint("TOPLEFT", 330, y)
    y = y - 26
    w.presets = {}
    for n, pr in ipairs(HD.Presets) do
        local b = button(p, (pr.name:gsub("^The ", "")), 100, 18, function()
            local m = CU.Member(); if m then CU.ApplyPreset(m, pr.id); changed() end
        end, pr.name .. ": " .. pr.text)
        b:SetPoint("TOPLEFT", 8 + ((n - 1) % 4) * 104, y - math.floor((n - 1) / 4) * 20)
        w.presets[pr.id] = b
    end
    y = y - 64
    w.trade = K.Text(p, 9, COL.ink); w.trade:SetPoint("TOPLEFT", 8, y); w.trade:SetWidth(410)
    if w.trade.SetWordWrap then w.trade:SetWordWrap(true) end
    w.trade:SetJustifyV("TOP")
    return w
end

local function buildInterests(p)
    local w = { btns = {} }
    local topics = H.Topics()
    for n = 1, math.min(#topics, 24) do
        local t = topics[n]
        local b = button(p, t.name, 134, 20, function(_, btn)
            local m = CU.Member(); if not m then return end
            local v = (m.interests[t.id] or 0) + ((btn == "RightButton") and -1 or 1)
            if v > T.interestMax then v = 0 end
            if v < 0 then v = 0 end
            CU.SetInterest(m, t.id, v); changed()
        end, "Left click: more interest. Right click: less. Interests give people something to talk about.")
        b:SetPoint("TOPLEFT", 8 + ((n - 1) % 3) * 138, -6 - math.floor((n - 1) / 3) * 23)
        b.topic = t
        w.btns[n] = b
    end
    local y = -6 - math.ceil(math.min(#topics, 24) / 3) * 23 - 6
    w.random = button(p, "Randomise", 80, 20, function() local m = CU.Member(); if m then CU.RandomInterests(m); changed() end end, "Pick a few interests at random")
    w.random:SetPoint("TOPLEFT", 8, y)
    w.clear = button(p, "Clear", 60, 20, function() local m = CU.Member(); if m then m.interests = {}; changed() end end, "No interests")
    w.clear:SetPoint("LEFT", w.random, "RIGHT", 6, 0)
    return w
end

local function buildFamily(p)
    local w = { rows = {} }
    w.head = K.Text(p, 11); w.head:SetPoint("TOPLEFT", 8, -8); w.head:SetWidth(410)
    for n = 1, T.capacity - 1 do
        local row = {}
        row.name = K.Text(p, 11); row.name:SetPoint("TOPLEFT", 8, -32 - (n - 1) * 24); row.name:SetWidth(180)
        row.btn = button(p, "", 140, 20, function(_, btn)
            if not row.j then return end
            local ok, why = CU.CycleRel(st.spec, st.sel, row.j, btn == "RightButton" and -1 or 1)
            if not ok then notice(why) end
            changed()
        end, "Click to change the tie (right click goes back). Spouses and partners are for two adults; parents and children need an adult and a child.")
        row.btn:SetPoint("TOPLEFT", 200, -30 - (n - 1) * 24)
        w.rows[n] = row
    end
    w.note = K.Text(p, 10, COL.inkSoft); w.note:SetPoint("TOPLEFT", 8, -32 - (T.capacity - 1) * 24 - 4); w.note:SetWidth(410)
    if w.note.SetWordWrap then w.note:SetWordWrap(true) end
    w.note:SetText("Family ties are permanent. Spouses, partners and roommates start as friends who live together; people with no tie start as acquaintances.")
    return w
end

local function build(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    CU.frame = f
    K.Tex(f, "BACKGROUND", COL.panel):SetAllPoints()
    local W = {}
    CU.w = W

    -- top: household name, description, save/cancel
    local top = CreateFrame("Frame", nil, f)
    top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(58)
    K.Tex(top, "ARTWORK", COL.panelDark):SetAllPoints()
    W.title = K.Text(top, 13); W.title:SetPoint("TOPLEFT", 8, -6)
    local hl = K.Text(top, 11); hl:SetPoint("TOPLEFT", 8, -33); hl:SetText("Household")
    W.hhName = editBox(top, 140, T.householdNameMax, function(t) if st.spec then CU.SetHouseholdName(st.spec, t) end end)
    W.hhName:SetPoint("TOPLEFT", 72, -30)
    local bl = K.Text(top, 11); bl:SetPoint("TOPLEFT", 222, -33); bl:SetText("Description")
    W.hhBio = editBox(top, 300, T.bioMax, function(t) if st.spec then st.spec.bio = t end end)
    W.hhBio:SetPoint("TOPLEFT", 296, -30)
    W.cancel = button(top, "Cancel", 70, 22, function() CU.Cancel() end, "Leave without saving (Esc)")
    W.cancel:SetPoint("TOPRIGHT", -8, -6)
    W.save = button(top, "Save household", 110, 22, function() CU.Save() end, "Save and go to the neighbourhood")
    W.save:SetPoint("RIGHT", W.cancel, "LEFT", -6, 0)
    W.moneyText = K.Text(top, 10, COL.inkSoft, "RIGHT"); W.moneyText:SetPoint("TOPRIGHT", -8, -34); W.moneyText:SetWidth(280)

    -- left: members
    local left = CreateFrame("Frame", nil, f)
    left:SetPoint("TOPLEFT", 0, -58); left:SetPoint("BOTTOMLEFT"); left:SetWidth(190)
    K.Tex(left, "BACKGROUND", COL.panelDark):SetAllPoints()
    W.count = K.Text(left, 11); W.count:SetPoint("TOPLEFT", 8, -6)
    W.members = {}
    for n = 1, T.capacity do
        local r = CreateFrame("Button", nil, left)
        r:SetSize(178, 40)
        r:SetPoint("TOPLEFT", 6, -24 - (n - 1) * 43)
        r.bg = K.Tex(r, "BACKGROUND", COL.panel); r.bg:SetAllPoints()
        r.portrait = SS.HoodUI and SS.HoodUI.Portrait and SS.HoodUI.Portrait(r, 36)
        if r.portrait then r.portrait:SetPoint("LEFT", 2, 0); r.portrait:EnableMouse(false) end
        r.name = K.Text(r, 11); r.name:SetPoint("TOPLEFT", 42, -5); r.name:SetWidth(132)
        r.detail = K.Text(r, 9, COL.inkSoft); r.detail:SetPoint("BOTTOMLEFT", 42, 5)
        r:SetScript("OnClick", function() if st.spec and st.spec.members[n] then st.sel = n; changed() end end)
        W.members[n] = r
    end
    W.addAdult = button(left, "+ Adult", 58, 20, function()
        local ok, why, idx = CU.AddMember(st.spec, "adult"); notice(why); if ok then st.sel = idx end; changed()
    end, "Add a grown-up (up to " .. T.capacity .. " people)")
    W.addAdult:SetPoint("BOTTOMLEFT", 6, 8)
    W.addChild = button(left, "+ Child", 58, 20, function()
        local ok, why, idx = CU.AddMember(st.spec, "child"); notice(why); if ok then st.sel = idx end; changed()
    end, "Add a child (up to " .. T.capacity .. " people)")
    W.addChild:SetPoint("LEFT", W.addAdult, "RIGHT", 2, 0)
    W.remove = button(left, "Remove", 56, 20, function()
        local ok, why = CU.RemoveMember(st.spec, st.sel); notice(why)
        if ok then st.sel = math.max(1, math.min(st.sel, #st.spec.members)) end
        changed()
    end, "Remove the selected person from the household")
    W.remove:SetPoint("LEFT", W.addChild, "RIGHT", 2, 0)

    -- right: portrait preview and problems
    local right = CreateFrame("Frame", nil, f)
    right:SetPoint("TOPRIGHT", 0, -58); right:SetPoint("BOTTOMRIGHT"); right:SetWidth(250)
    K.Tex(right, "BACKGROUND", COL.panelDark):SetAllPoints()
    W.portrait = SS.HoodUI and SS.HoodUI.Portrait and SS.HoodUI.Portrait(right, 150)
    if W.portrait then W.portrait:SetPoint("TOP", 0, -10) end
    W.outfitName = K.Text(right, 10, COL.inkSoft, "CENTER"); W.outfitName:SetPoint("TOP", 0, -164); W.outfitName:SetWidth(234)
    W.summary = K.Text(right, 10); W.summary:SetPoint("TOPLEFT", 8, -182); W.summary:SetWidth(234)
    if W.summary.SetWordWrap then W.summary:SetWordWrap(true) end
    W.summary:SetJustifyV("TOP")
    W.problems = K.Text(right, 10, COL.warn); W.problems:SetPoint("BOTTOMLEFT", 8, 8); W.problems:SetWidth(234)
    if W.problems.SetWordWrap then W.problems:SetWordWrap(true) end
    W.randomAll = button(right, "Randomise person", 120, 20, function() local m = CU.Member(); if m then CU.Randomise(m); changed() end end,
        "Random looks, personality and interests for the selected person")
    W.randomAll:SetPoint("TOPRIGHT", -8, -10)

    -- centre: tabs and pages
    local mid = CreateFrame("Frame", nil, f)
    mid:SetPoint("TOPLEFT", 196, -62); mid:SetPoint("BOTTOMRIGHT", -256, 4)
    W.mid = mid
    W.tabs, W.pages = {}, {}
    for n, t in ipairs(TABS) do
        local id = t[1]
        local b = button(mid, t[2], 82, 22, function() st.tab = id; changed() end)
        b:SetPoint("TOPLEFT", (n - 1) * 85, 0)
        W.tabs[id] = b
        W.pages[id] = page(mid)
    end
    W.identity = buildIdentity(W.pages.identity)
    W.looks = buildLooks(W.pages.looks)
    W.personality = buildPersonality(W.pages.personality)
    W.interests = buildInterests(W.pages.interests)
    W.family = buildFamily(W.pages.family)
    f:Hide()
    return f
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
local function setSwatch(t, c) if c then t:SetColorTexture(c[1], c[2], c[3], 1); t:Show() else t:Hide() end end

local function pendingMark(part, id, kind) return CU.HasArt(part, id, kind) and "" or " *" end

function CU.Refresh()
    local W = CU.w
    if not (W and CU.frame) then return end
    local spec = st.spec
    if not spec then return end
    if st.sel > #spec.members then st.sel = #spec.members end
    if st.sel < 1 then st.sel = 1 end
    local m = spec.members[st.sel]
    local r = root()
    W.title:SetText(st.editing and ("Editing the " .. ((r and r.households[st.editing] and r.households[st.editing].name) or spec.name) .. " household")
        or "Create a household")
    if not (W.hhName.HasFocus and W.hhName:HasFocus()) then W.hhName:SetText(spec.name or "") end
    if not (W.hhBio.HasFocus and W.hhBio:HasFocus()) then W.hhBio:SetText(spec.bio or "") end
    W.moneyText:SetText(st.editing and "Money and home are unchanged by editing."
        or ("New households start with " .. money(T.startMoney) .. " in the household bin."))
    W.count:SetText(string.format("People (%d of %d)", #spec.members, T.capacity))
    for n, row in ipairs(W.members) do
        local mem = spec.members[n]
        if mem then
            row:Show()
            row.name:SetText(mem.name ~= "" and mem.name or "(no name)")
            row.detail:SetText((mem.age == "child" and "Child" or "Adult") .. ", " .. mem.pronoun .. (CU.MatchPreset(mem) and (", " .. CU.MatchPreset(mem).name) or ""))
            local c = n == st.sel and COL.accentHi or COL.panel
            row.bg:SetColorTexture(c[1], c[2], c[3], n == st.sel and 0.6 or 1)
            if row.portrait then SS.HoodUI.DrawPortrait(row.portrait, CU.Person(mem, "everyday")) end
        else
            row:Hide()
        end
    end
    local full = #spec.members >= T.capacity
    usable(W.addAdult, not full, "A household holds at most " .. T.capacity .. " people.")
    usable(W.addChild, not full, "A household holds at most " .. T.capacity .. " people.")
    local canRemove, whyRemove = #spec.members > 1, "A household needs at least one person."
    if canRemove and m.age == "adult" then
        local adults = 0
        for _, o in ipairs(spec.members) do if o.age == "adult" then adults = adults + 1 end end
        if adults == 1 then canRemove, whyRemove = false, "Children cannot live on their own: keep at least one adult." end
    end
    usable(W.remove, canRemove, whyRemove)

    for id, b in pairs(W.tabs) do b:SetActive(id == st.tab); W.pages[id]:SetShown(id == st.tab) end

    -- identity
    local I = W.identity
    if not (I.first.HasFocus and I.first:HasFocus()) then I.first:SetText(m.first or "") end
    if not (I.last.HasFocus and I.last:HasFocus()) then I.last:SetText(m.last or "") end
    if not (I.bio.HasFocus and I.bio:HasFocus()) then I.bio:SetText(m.bio or "") end
    for age, b in pairs(I.ages) do b:SetActive(m.age == age) end
    for pr, b in pairs(I.pron) do b:SetActive(m.pronoun == pr) end

    -- looks
    local L = W.looks
    local pending = 0
    for _, part in ipairs(CU.LookParts) do
        local e = CU.LookValue(m, part)
        local row = L.rows[part]
        local mark = pendingMark(part, e.id)
        if mark ~= "" then pending = pending + 1 end
        row.value:SetText(e.name .. mark)
        setSwatch(row.swatch, (part == "skin" or part == "hair") and e.c or nil)
    end
    for kind, b in pairs(L.kinds) do b:SetActive(kind == st.outfit) end
    local o = (m.look.outfits or {})[st.outfit] or {}
    local style = find(HD.OutfitStyles[st.outfit], o.style) or HD.OutfitStyles[st.outfit][1]
    local omark = pendingMark("outfit", style.id, st.outfit)
    if omark ~= "" then pending = pending + 1 end
    L.outfit.style.value:SetText(style.name .. omark)
    for _, field in ipairs({ "top", "bottom", "shoes" }) do
        local n = colourIndex(o[field])
        L.outfit[field].value:SetText(n > 0 and ("Colour " .. n) or "Custom")
        setSwatch(L.outfit[field].swatch, o[field])
    end
    L.art:SetText(pending > 0 and "* art pending: the portrait uses a simple stand-in until the art module draws this option." or "")

    -- personality
    local P = W.personality
    for _, d in ipairs(HD.Dims) do
        local v = m.personality[d] or 0
        for n, pip in ipairs(P.rows[d].pips) do
            local c = n <= v and COL.accentHi or COL.barBg
            pip.tex:SetColorTexture(c[1], c[2], c[3], 1)
        end
        usable(P.rows[d].minus, v > 0, "Already at zero.")
        usable(P.rows[d].plus, v < T.personalityMax and CU.PointsLeft(m) > 0, v >= T.personalityMax and "Already at the maximum." or "No points left.")
    end
    local left = CU.PointsLeft(m)
    P.points:SetText(string.format("Points left: %d of %d%s", left, T.personalityBudget, left > 0 and " (unspent points are simply unused)" or ""))
    local match = CU.MatchPreset(m)
    for id, b in pairs(P.presets) do b:SetActive(match and match.id == id) end
    local focus = st.focusDim or HD.Dims[1]
    P.trade:SetText((match and (match.name .. ": " .. match.text .. "\n") or "") .. table.concat(CU.Tradeoffs(m), "\n")
        .. "\n\n" .. CU.DimLabel(focus).name .. " in play: " .. CU.DimTradeoff(focus))

    -- interests
    for _, b in ipairs(W.interests.btns) do
        local v = m.interests[b.topic.id] or 0
        b.label:SetText(b.topic.name .. (v > 0 and (": " .. v) or ""))
        b:SetActive(v > 0)
    end

    -- ties
    local F = W.family
    F.head:SetText(#spec.members > 1 and ("Ties of " .. m.name .. " to the others") or "Add more people to set family, partner and roommate ties.")
    local k = 0
    for j, other in ipairs(spec.members) do
        if j ~= st.sel then
            k = k + 1
            local row = F.rows[k]
            if row then
                row.j = j
                row.name:SetText(other.name .. " (" .. other.age .. ")"); row.name:Show()
                local kind = CU.RelBetween(spec, st.sel, j)
                local def = kindDef(kind)
                row.btn.label:SetText(def and def.name or kind)
                row.btn:Show()
            end
        end
    end
    for n = k + 1, #F.rows do F.rows[n].j = nil; F.rows[n].name:Hide(); F.rows[n].btn:Hide() end

    -- preview
    if W.portrait then SS.HoodUI.DrawPortrait(W.portrait, CU.Person(m, st.outfit)) end
    W.outfitName:SetText(HD.OutfitLabel[st.outfit] .. ": " .. style.name)
    local ints = {}
    for _, t in ipairs(H.Topics()) do if (m.interests[t.id] or 0) > 0 then ints[#ints + 1] = t.name .. " " .. m.interests[t.id] end end
    local summary = {
        m.name ~= "" and m.name or "(no name)",
        (m.age == "child" and "Child" or "Adult") .. ", " .. m.pronoun,
        "Personality: " .. (match and match.name or "custom") .. string.format(" (%d/%d points)", CU.PointsUsed(m), T.personalityBudget),
        "Interests: " .. (#ints > 0 and table.concat(ints, ", ") or "none yet"),
    }
    if m.bio and m.bio ~= "" then summary[#summary + 1] = m.bio end
    W.summary:SetText(table.concat(summary, "\n"))
    local ok, problems = CU.Validate(spec)
    st.problems = problems or {}
    usable(W.save, ok, problems and problems[1])
    W.problems:SetText(ok and "" or ("To save:\n- " .. table.concat(problems, "\n- ", 1, math.min(#problems, 6))))
end

UI.RegisterMode("create", {
    label = "Create", order = 91, fullscreen = true, pausesSim = true, audio = "create",
    tip = "Household creator: design 1-" .. T.capacity .. " people",
    help = { "Create a household of 1-" .. T.capacity .. " people: names, looks, personality (" .. T.personalityBudget .. " points), interests and ties.",
        "Save puts the household in the household bin with " .. money(T.startMoney) .. ". Esc cancels." },
    keys = { ESCAPE = true, Q = true, E = true, SPACE = true, MINUS = true, EQUALS = true, TAB = true, H = true, HOME = true,
        LEFT = true, RIGHT = true, UP = true, DOWN = true, PAGEUP = true, PAGEDOWN = true, ["1"] = true, ["2"] = true, ["3"] = true },
    create = build,
    canEnter = function(w)
        if not (w and (w.root or w).households) then return false, "No game is loaded." end
        return true
    end,
    enter = function()
        if not st.opened then st.returnMode = CU.lastMode or "live" end
        st.opened = nil
        if not st.spec then CU.Begin(nil) end
        CU.Refresh()
    end,
    exit = function() end,
    onKey = function(key)
        if key == "ESCAPE" then CU.Cancel() end
        return true   -- the creator swallows lot keys (rotate, speed, pause) while it is open
    end,
})

-- The mode the creator returns to on Cancel when it was opened from the toolbar.
if SS.On then
    SS.On("uiMode", function(name) if name ~= "create" then CU.lastMode = name end end)
end
