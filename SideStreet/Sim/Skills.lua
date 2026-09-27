-- Skills: six skill families (cooking, mechanical, charisma, body, logic, creativity), levels 0-10.
-- Owner: careers module (docs/modules/careers.md). Data: SS.CareerData.skills (Data/Careers.lua).
--
-- Values are stored as floats in person.skills[name] (0..10); the whole part is the level.
-- SS.Skills.Gain(world, actor, skill, points, opts) adds practice points: the rate depends on
-- activity quality (opts.quality), mood, personality (where sensible) and age, and each level costs
-- more points than the last (a gradual curve). Children learn more slowly and have their own caps.
-- Level-ups give feedback (SS.Actions.Message) and emit "skillUp"(world, actor, skill, level).
-- Other modules read outcomes through the helpers at the bottom (cooking quality, burn chance,
-- repair reliability, shock risk, social bonus, art quality) or through Level().
local _, SS = ...
local S = SS.Skills or {}
SS.Skills = S
S.LIST = { "cooking", "mechanical", "charisma", "body", "logic", "creativity" }
S.MAX = 10

local function data() return SS.CareerData.skills end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

function S.Label(skill) return data().labels[skill] or skill end
function S.Valid(skill) return data().labels[skill] ~= nil end

function S.Value(actor, skill) return (actor and actor.skills and actor.skills[skill]) or 0 end
-- Whole level 0..10 (the stub signature: Level(actor, skill)).
function S.Level(actor, skill) return math.floor(S.Value(actor, skill) + 1e-9) end
-- Fraction of the way to the next level (0..1).
function S.Progress(actor, skill)
    local v = S.Value(actor, skill)
    return v - math.floor(v + 1e-9)
end

-- Highest level this person can reach in a skill (children have lower caps, infants none).
function S.Cap(actor, skill)
    if actor.age == "infant" then return 0 end
    if actor.age == "child" then return data().childCaps[skill] or S.MAX end
    return S.MAX
end

-- Practice points needed to go from `level` to `level + 1`.
function S.Cost(level)
    local c = data().curve
    return c.base + c.perLevel * level
end

-- Total practice points from 0 to a (fractional) value; used by tests and the UI.
function S.PointsTo(value)
    local pts, lvl = 0, 0
    while lvl + 1 <= value + 1e-9 do pts = pts + S.Cost(lvl); lvl = lvl + 1 end
    if value > lvl then pts = pts + (value - lvl) * S.Cost(lvl) end
    return pts
end

-- Learning-rate multiplier for this person now. opts.quality: activity/object quality (1 = normal);
-- opts.noMood: ignore mood (flat rewards).
function S.Rate(world, actor, skill, opts)
    local d = data()
    local r = 1
    if actor.age == "child" then r = r * d.childRate end
    if not (opts and opts.noMood) and actor.needs and SS.Needs and SS.Needs.Mood then
        local m = clamp(SS.Needs.Mood(actor), -d.moodClamp, d.moodClamp)
        r = r * (1 + m * d.moodFactor)
    end
    local p = d.personality[skill]
    if p and actor.personality then
        local v = actor.personality[p.dim] or 5
        if p.sign < 0 then v = 10 - v end
        r = r * (d.personalityMin + (d.personalityMax - d.personalityMin) * clamp(v, 0, 10) / 10)
    end
    if opts and opts.quality then r = r * opts.quality end
    return r
end

local function levelUp(world, actor, skill, level)
    local name = actor.name or "Someone"
    local text = string.format("%s reached %s level %d.", name, S.Label(skill), level)
    if level >= S.Cap(actor, skill) and actor.age == "child" and level < S.MAX then
        text = text .. " That is as far as a child can take it for now."
    end
    if world and SS.Actions and SS.Actions.Message then SS.Actions.Message(world, actor, text, "skill_" .. skill) end
    if world and data().journalLevels[level] and SS.Actions and SS.Actions.Journal and world.journal then
        SS.Actions.Journal(world, string.format("%s is now a level %d %s talent.", name, level, S.Label(skill):lower()))
    end
    if SS.Audio and SS.Audio.Cue then SS.Audio.Cue("skill") end
    SS.Emit("skillUp", world, actor, skill, level)
end

local function setValue(world, actor, skill, v, silent)
    actor.skills = actor.skills or {}
    local before = S.Level(actor, skill)
    actor.skills[skill] = v
    local after = S.Level(actor, skill)
    if after > before and not silent then levelUp(world, actor, skill, after) end
    return v
end

-- Add practice points (1 point = 1 level at level 0 with a rate of 1). Negative amounts remove
-- that many points. Returns the new value. Stub signature kept; opts is an optional extension:
--   opts.quality (object/activity quality multiplier), opts.noMood, opts.raw (no rate at all), opts.silent.
function S.Gain(world, actor, skill, amount, opts)
    if not actor or not S.Valid(skill) or not amount or amount == 0 then return S.Value(actor or {}, skill) end
    local cur = S.Value(actor, skill)
    local cap = S.Cap(actor, skill)
    if amount > 0 then
        if cur >= cap then return cur end
        local pts = amount * ((opts and opts.raw) and 1 or S.Rate(world, actor, skill, opts))
        local v = cur
        while pts > 1e-12 and v < cap - 1e-12 do
            local lvl = math.floor(v + 1e-9)
            local need = (lvl + 1 - v) * S.Cost(lvl)
            if pts >= need then
                v = lvl + 1
                pts = pts - need
            else
                v = v + pts / S.Cost(lvl)
                pts = 0
            end
        end
        return setValue(world, actor, skill, math.min(v, cap), opts and opts.silent)
    end
    -- losses: points come off the current level's cost, never below 0
    local v = cur
    local pts = -amount
    while pts > 1e-12 and v > 0 do
        local lvl = math.floor(v - 1e-9)
        local have = (v - lvl) * S.Cost(lvl)
        if pts >= have then v = lvl; pts = pts - have else v = v - pts / S.Cost(lvl); pts = 0 end
    end
    return setValue(world, actor, skill, math.max(0, v), true)
end
-- Alias used by activity code that wants to be explicit about practice.
S.Practice = S.Gain

-- Add or remove whole/fractional levels directly (chance-event rewards; no mood or curve).
function S.Adjust(world, actor, skill, levels)
    if not S.Valid(skill) or not levels or levels == 0 then return S.Value(actor, skill) end
    local v = clamp(S.Value(actor, skill) + levels, 0, S.Cap(actor, skill))
    return setValue(world, actor, skill, v, levels < 0)
end

-- Requirements check: req = { skill = level }. Returns ok, missing list { { skill, have, need } } (sorted).
function S.Meets(actor, req)
    local missing = {}
    for _, sk in ipairs(S.LIST) do
        local need = req and req[sk]
        if need and S.Level(actor, sk) < need then missing[#missing + 1] = { sk, S.Level(actor, sk), need } end
    end
    return #missing == 0, missing
end

---------------------------------------------------------------------------------------------------
-- Outcomes other modules read (documented in docs/modules/careers.md). All deterministic.

-- Meal quality 0..100 from cooking level and appliance quality (0..10, default 5).
function S.CookQuality(actor, applianceQuality)
    local q = 18 + S.Level(actor, "cooking") * 6 + (applianceQuality or 5) * 2.2
    return clamp(q, 0, 100)
end
-- Chance (0..1) that a cooking attempt burns. risk: appliance risk multiplier (default 1).
function S.BurnChance(actor, risk)
    local c = math.max(0.02, 0.32 - 0.03 * S.Level(actor, "cooking"))
    return clamp(c * (risk or 1), 0, 0.95)
end
-- Chance (0..1) that one repair attempt succeeds. difficulty 1 (easy) .. 5 (hard), default 2.
function S.RepairChance(actor, difficulty)
    return clamp(0.40 + 0.07 * S.Level(actor, "mechanical") - 0.08 * ((difficulty or 2) - 1), 0.10, 0.98)
end
-- Repair time multiplier (skilled people are faster): 1.0 at level 0 down to 0.5 at level 10.
function S.RepairSpeed(actor) return 1 - 0.05 * S.Level(actor, "mechanical") end
-- Chance (0..1) of an electric shock during an electrical repair.
function S.ShockChance(actor) return math.max(0.01, 0.12 - 0.011 * S.Level(actor, "mechanical")) end
-- Points added to social acceptance scores (0..15).
function S.SocialBonus(actor) return S.Level(actor, "charisma") * 1.5 end
-- Art quality 0..100 for a painting/craft; minutes spent add a little (capped).
function S.ArtQuality(actor, minutes)
    local q = 10 + S.Level(actor, "creativity") * 8 + math.min(10, (minutes or 0) / 30)
    return clamp(q, 0, 100)
end
-- Sale value multiplier for crafted art: 0.5 at quality 0, 3.0 at quality 100.
function S.ArtValueFactor(quality) return 0.5 + 2.5 * clamp(quality or 0, 0, 100) / 100 end
-- Exercise/fitness recovery multiplier (body level makes workouts more efficient): 1.0 .. 1.5.
function S.FitnessFactor(actor) return 1 + 0.05 * S.Level(actor, "body") end

---------------------------------------------------------------------------------------------------
-- Save validation: every human gets the six skills, clamped to their caps.
if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        -- repairs damaged values only: a person without skills (or without one skill) is left as saved,
        -- so a valid save loads unchanged (missing skills read as 0)
        for id, p in pairs(root.residents or {}) do
            if type(p) == "table" and (p.kind == nil or p.kind == "human") and p.skills ~= nil then
                if type(p.skills) ~= "table" then
                    p.skills = nil
                    problems[#problems + 1] = "reset damaged skills for " .. tostring(id)
                else
                    for _, sk in ipairs(S.LIST) do
                        local v = p.skills[sk]
                        if v ~= nil then
                            if type(v) ~= "number" or v ~= v then
                                problems[#problems + 1] = "reset skill " .. sk .. " for " .. tostring(id)
                                p.skills[sk] = 0
                            else
                                local c = clamp(v, 0, S.Cap(p, sk))
                                if c ~= v then p.skills[sk] = c end
                            end
                        end
                    end
                end
            end
        end
    end)
end
