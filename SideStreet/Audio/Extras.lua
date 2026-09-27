-- SideStreet audio extras: what the Sims-parity extras need beyond the director's mode playlists.
--
--   * Stations and the piano. While the household is in live mode (or throwing a party) on its
--     lot, a piano being played switches the music to that player's piano pieces (piano_lNN, NN =
--     creativity 1-10), and otherwise a stereo or radio that is on plays its station's playlist
--     (station_<id>). Nothing on: the mode's own playlist, as before.
--   * Event stings. Game events ask for short stings by name (baby, wedding, romance, kiss, ...).
--     Each name has its own cooldown so busy households do not turn into a jingle machine.
--
-- Everything goes through the director (SS.Audio): categories, caps, the emergency override and
-- the sound options all still apply, and a missing file degrades to another variant or silence.
local _, SS = ...
local AD = SS.Audio
local X = {}
AD.Extras = X

local function now() return (GetTime and GetTime()) or 0 end

-- Seconds between two plays of the same sting name.
X.COOLDOWN = {
    social_good = 40, social_fail = 30, social_attack = 20, kiss = 15, kiss_passionate = 15,
    kiss_refused = 15, romance = 30, sleep = 120, danger = 20, flood = 30, spooky = 30,
    fire_alarm = 20, default = 5,
}
-- An emergency alarm cue right after a sting that already announced it (the smoke alarm's fire
-- sting, the burglar's danger sting) is skipped, so two stingers never sound on top of each other.
X.ALARM_AFTER_STING = 2
-- Playlist modes a station or the piano may take over.
X.OVERRIDE_IN = { live = true, party = true }

X.last = {}
X.override = nil

local function current(world) return world ~= nil and SS.Sim and SS.Sim.world == world end

local function played(world, id)
    local a = world and world.actors and world.actors[id]
    return a ~= nil and world.household ~= nil and a.householdId == world.household.id
end

-- When a sting's files are all refused (the extras were not copied in), these names borrow a
-- core cue instead; the rest stay silent, as they were before the extras.
X.FALLBACK = { fire_alarm = "fire", danger = "tension", baby = "arrival", wedding = "party_good" }

local function allRefused(name)
    local l = AD.Index().cues[name]
    if not l or #l == 0 then return true end
    for _, n in ipairs(l) do if not AD.refused[n.id] then return false end end
    return true
end
X.AllRefused = allRefused

local baseCue = AD.Cue
local function cueOrFallback(name)
    local ok = baseCue(name)
    if not ok and X.FALLBACK[name] and allRefused(name) then ok = baseCue(X.FALLBACK[name]) end
    return ok
end

function X.Sting(name)
    local t = now()
    local cd = X.COOLDOWN[name] or X.COOLDOWN.default
    if X.last[name] and X.last[name] + cd > t then return false end
    local ok = cueOrFallback(name)
    if ok then
        X.last[name] = t
        X.stingAt = t
    end
    return ok
end

-- Stings stand in for the alarm cue of the emergency they come with.
-- (events asks for "fire_alarm" when the smoke alarm goes off and "burglar_alarm" when the
-- burglar alarm does; both come just before their emergency)
function AD.Cue(name)
    if name == "emergency" and X.stingAt and now() - X.stingAt < X.ALARM_AFTER_STING then return false end
    if name == "fire_alarm" then return X.Sting("fire_alarm") end
    if name == "burglar_alarm" then return X.Sting("danger") end
    return baseCue(name)
end

---------------------------------------------------------------------------
-- Stations and the piano
---------------------------------------------------------------------------
local MUSIC_TAGS = { "stereo", "radio", "dj" }   -- household-core's music sources (Sim/Leisure.lua)
local tagCache = setmetatable({}, { __mode = "k" })
local function kindOf(def)
    if not def or not (SS.Tags and SS.Tags.Has) then return nil end
    local k = tagCache[def]
    if k == nil then
        k = false
        if SS.Tags.Has(def, "piano") then k = "piano"
        else
            for _, tag in ipairs(MUSIC_TAGS) do if SS.Tags.Has(def, tag) then k = "music"; break end end
        end
        tagCache[def] = k
    end
    return k or nil
end

local function creativity(actor)
    local S = SS.Skills
    return (S and S.Level and tonumber(S.Level(actor, "creativity"))) or 0
end

-- The playlist a station or the piano asks for on the current lot, or nil.
function X.Wanted()
    local world = SS.Sim and SS.Sim.world
    local lot = world and world.lot
    if not lot or not lot.objects then return nil end
    -- the piano: someone at it right now (performing play_instrument)
    for _, b in pairs(world.actors or {}) do
        local act = b.act
        if act and act.iid == "play_instrument" and act.oid then
            local o = lot.objects[act.oid]
            if o and kindOf(SS.Objects and SS.Objects[o.def]) == "piano" and (act.phase == nil or act.phase == "perform") then
                local lv = math.max(1, math.min(10, math.floor(creativity(b))))
                return string.format("piano_l%02d", lv)
            end
        end
    end
    -- a stereo or radio that is on: the one switched on last wins
    local best, bestT
    for id, o in pairs(lot.objects) do
        if o.state and o.state.on and o.station and kindOf(SS.Objects and SS.Objects[o.def]) == "music" then
            local t = X.tunedAt and X.tunedAt[id] or 0
            if not best or t > bestT or (t == bestT and id < best.id) then best, bestT = o, t end
        end
    end
    if best then return "station_" .. tostring(best.station) end
    return nil
end

-- Re-decide the override and let the director pick the music again if it changed.
function X.Refresh()
    local want = X.Wanted()
    if want == X.override then return end
    X.override = want
    if AD.active and AD.mode and X.OVERRIDE_IN[AD.mode] then AD.RefreshMusic() end
end

local baseDesired = AD.DesiredPlaylist
function AD.DesiredPlaylist()
    local o = X.override
    if o and AD.mode and X.OVERRIDE_IN[AD.mode] and not AD.InEmergency() then
        local ix = AD.Index()
        local list = {}
        for _, n in ipairs(ix.playlists[o] or {}) do if n.file then list[#list + 1] = n end end
        -- a station whose files are all refused (not installed) leaves the mode's own music on
        local any = false
        for _, n in ipairs(list) do if not AD.refused[n.id] then any = true; break end end
        if any then return o, list end
    end
    return baseDesired()
end

SS.On("actionStarted", function(actor, act)
    if act and act.iid == "play_instrument" then X.Refresh() end
    if act and act.iid == "sleep" then
        local w = SS.Sim and SS.Sim.world
        if w and actor and played(w, actor.id) then X.Sting("sleep") end
    end
end)
SS.On("actionEnded", function(actor, act)
    if act and act.iid == "play_instrument" then X.Refresh() end
end)
SS.On("lotChanged", function(kind, id)
    if kind ~= "state" then return end
    local w = SS.Sim and SS.Sim.world
    local o = w and w.lot and w.lot.objects and w.lot.objects[id]
    if o and kindOf(SS.Objects and SS.Objects[o.def]) == "music" then
        X.tunedAt = X.tunedAt or {}
        if o.state and o.state.on then X.tunedAt[id] = now() else X.tunedAt[id] = nil end
        X.Refresh()
    end
end)
SS.On("worldAttached", function() X.tunedAt = nil; X.Refresh() end)
SS.On("uiMode", function() X.Refresh() end)
SS.On("skillUp", function() X.Refresh() end)

---------------------------------------------------------------------------
-- Event stings
---------------------------------------------------------------------------
SS.On("familyArrival", function(world, _, kind)
    if current(world) and kind == "baby" then X.Sting("baby") end
end)
SS.On("aquariumLoss", function(world) if current(world) then X.Sting("death_fish") end end)
SS.On("ghost", function(world) if current(world) then X.Sting("spooky") end end)
SS.On("commitment", function(world) if current(world) then X.Sting("wedding") end end)
SS.On("engaged", function(world) if current(world) then X.Sting("romance") end end)
SS.On("careerDemoted", function(world) if current(world) then X.Sting("career_fail") end end)
SS.On("careerMissed", function(world, _, _, outcome)
    if current(world) and outcome == "fired" then X.Sting("career_fail") end
end)
SS.On("relFlag", function(world, aId, bId, flag, value)
    if not current(world) or not value then return end
    if (flag == "love" or flag == "crush") and (played(world, aId) or played(world, bId)) then X.Sting("romance") end
end)
SS.On("eventStarted", function(world, e)
    if not current(world) or type(e) ~= "table" then return end
    if e.family == "burglary" then X.Sting("danger")
    elseif e.family == "pipe_leak" then X.Sting("flood") end
end)

local function partners(world, a, b)
    local So = SS.Social
    if not (So and So.Rel) then return false end
    local ok, r = pcall(So.Rel, world, a, b)
    return ok and type(r) == "table" and r.flags and (r.flags.love or r.flags.partner or r.flags.engaged) and true or false
end

SS.On("socialExchange", function(world, x)
    if not current(world) or type(x) ~= "table" then return end
    if not (played(world, x.a) or played(world, x.b)) then return end
    if x.id == "kiss" then
        if not x.ok then X.Sting("kiss_refused")
        elseif partners(world, x.a, x.b) then X.Sting("kiss_passionate")
        else X.Sting("kiss") end
    elseif x.id == "argue" then
        X.Sting("social_attack")
    elseif x.ok then
        local d = SS.Socials and SS.Socials.byId and SS.Socials.byId[x.id]
        if not (d and d.kind == "hostile") then X.Sting("social_good") end
    else
        X.Sting("social_fail")
    end
end)

-- A proposal that ends without an engagement was turned down (family writes no event for it).
SS.On("actionEnded", function(actor, act, status)
    if not (act and act.iid == "fam_propose" and status == "done" and act.tid) then return end
    local w = SS.Sim and SS.Sim.world
    if not (w and actor and played(w, actor.id)) then return end
    local F = SS.Family
    local fam = F and F.Fam and F.Fam(actor)
    if not (fam and fam.engaged == act.tid) then X.Sting("proposal_refused") end
end)
