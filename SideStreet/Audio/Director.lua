-- SideStreet audio director: the single owner of every sound handle this addon starts.
--
-- What it does
--   * Mode music from playlists built out of SS.AudioManifest (entries' `modes`), avoiding
--     immediate repeats, one music handle at a time.
--   * UI/event cues, household effects, voices, loops (shower, phone, alarms) and ambience beds,
--     with priorities, concurrency caps and cooldowns.
--   * Emergency audio takes precedence (music and ambience stop, one alarm cue with a cooldown,
--     so repeated emergencies never stack alarms) until the emergency ends.
--
-- What it honestly cannot do (see docs/modules/ui-shell.md)
--   * PlaySoundFile has no gain, seek, fade or completion callback in the APIs we rely on, so
--     transitions are hard stop/start: a mode change stops the track and starts the new one after
--     a short silent gap; within a mode the next track starts when the previous one has ended
--     (its manifest duration). Nothing here is a crossfade. Reopening restarts a track from the
--     beginning. Loops are restarted when their file ends (a hard restart, not a seamless loop).
--   * It only ever stops handles it started itself (StopSound(handle)); it never stops other
--     addons' or the client's sounds and never changes WoW's audio settings, except the optional,
--     explicit "pause the game's own music" preference, which is reversible and never overwrites
--     a change the player made themselves.
--   * All timing uses real time (GetTime / C_Timer). Game speed and pause never change it.
local _, SS = ...
local AD = SS.Audio or {}
SS.Audio = AD

---------------------------------------------------------------------------
-- Policy (data): priorities, caps, cooldowns, mode aliases/fallbacks, event cues.
---------------------------------------------------------------------------
AD.ROLE_CAT = { music = "music", ambience = "ambience", cue = "effects", ui = "effects", sfx = "effects", loop = "effects", voice = "voices" }
AD.CHANNEL = { effects = "SFX", ambience = "Ambience", voices = "Dialog" }  -- music: preference (Master or Music)
AD.PRIORITY = { emergency = 100, cue = 60, voice = 50, loop = 45, sfx = 40, ambience = 20, music = 10 }
AD.CAPS = { oneshots = 6, voices = 2, loops = 4 }
AD.COOLDOWN = { cue = 0.15, sfx = 0.08, voiceActor = 1.5, voiceAny = 0.35, emergencyCue = 8 }
AD.MODE_GAP = 0.6        -- seconds of silence between a stopped track and the next mode's track
AD.TRACK_GAP = 4         -- seconds of silence between two tracks of the same playlist
AD.EMERGENCY_HOLD = 20   -- seconds an emergency keeps precedence (extended while a fire burns)
AD.MODE_ALIAS = { neighborhood = "hood", neighbourhood = "hood" }
-- If a mode has no produced tracks, try these (genre-compatible) playlists; otherwise silence.
AD.MODE_FALLBACK = { title = "hood", tutorial = "live", night = "live" }
-- Cue fallbacks used only when the named cue has no produced file (kept to related sounds).
AD.CUE_FALLBACK = { emergency = "fire", fire = "alert", purchase = "money", sell = "money" }
-- Ambience bed per mode (live picks day or night from the lot's clock).
AD.AMBIENCE_FOR = { hood = "suburb", title = "suburb", venue_cafe = "cafe", venue_park = "park", venue_club = "club", venue_shops = "shops" }

local function now() return (GetTime and GetTime()) or 0 end

local function soundOn(cat)
    if SS.UI and SS.UI.SoundOn then return SS.UI.SoundOn(cat) end
    return true
end

---------------------------------------------------------------------------
-- Manifest index (rebuilt when the manifest table changes)
---------------------------------------------------------------------------
local index, indexFor
local function splitTags(s)
    local out = {}
    for tag in tostring(s or ""):gmatch("[^,%s]+") do out[#out + 1] = tag end
    return out
end

local function normalize(id, e)
    local role = e.role == "ui" and "cue" or e.role or "sfx"
    local n = { id = id, role = role, dur = tonumber(e.dur or e.duration) or 0, loop = e.loop and true or false }
    n.file = type(e.file) == "string" and e.file ~= "" and e.file or nil
    n.category = e.category or AD.ROLE_CAT[role] or "effects"
    n.priority = e.priority
    local name = e.name
    if not name then
        name = id:gsub("^cue_", ""):gsub("^sfx_", ""):gsub("^amb_", ""):gsub("^loop_", ""):gsub("^voice_", ""):gsub("_%d+$", "")
        if role == "cue" and e.tags and not e.name then name = splitTags(e.tags)[1] or name end
    end
    n.name = name
    n.mood = e.mood or (role == "voice" and name) or nil
    local modes = e.modes
    if type(modes) ~= "table" and role == "music" then modes = splitTags(e.tags) end
    n.modes = {}
    for _, m in ipairs(modes or {}) do n.modes[#n.modes + 1] = AD.MODE_ALIAS[m] or m end
    return n
end

function AD.Index()
    local man = SS.AudioManifest or {}
    if index and indexFor == man then return index end
    local ix = { byId = {}, playlists = {}, cues = {}, sfx = {}, loops = {}, voices = {}, ambience = {},
        total = 0, present = 0, planned = 0, byRole = {} }
    local ids = {}
    for id in pairs(man) do ids[#ids + 1] = id end
    table.sort(ids)
    local function add(bucket, key, n) bucket[key] = bucket[key] or {}; table.insert(bucket[key], n) end
    for _, id in ipairs(ids) do
        local e = man[id]
        if type(e) == "table" then
            local n = normalize(id, e)
            ix.byId[id] = n
            ix.total = ix.total + 1
            if n.file then ix.present = ix.present + 1 else ix.planned = ix.planned + 1 end
            local r = ix.byRole[n.role] or { total = 0, present = 0 }
            r.total = r.total + 1; if n.file then r.present = r.present + 1 end
            ix.byRole[n.role] = r
            if n.role == "music" then
                for _, m in ipairs(n.modes) do add(ix.playlists, m, n) end
            elseif n.role == "cue" then add(ix.cues, n.name, n)
            elseif n.role == "voice" then add(ix.voices, n.mood or "neutral", n)
            elseif n.role == "ambience" then add(ix.ambience, n.name, n)
            else add(ix.sfx, n.name, n) end
            if n.loop and n.role ~= "music" then add(ix.loops, n.name, n) end
        end
    end
    index, indexFor = ix, man
    return ix
end

-- Forget the index (the manifest table was edited in place rather than replaced).
function AD.Reindex() index, indexFor = nil, nil end

local function presentOf(list)
    local out = {}
    for _, n in ipairs(list or {}) do if n.file then out[#out + 1] = n end end
    return out
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
AD.active = AD.active or false     -- true while the game window is open
AD.mode = AD.mode or nil           -- requested music mode ("live", "build", "hood", ...)
AD.music = nil                     -- { id, handle, mode, startedAt, endsAt }
AD.shots = {}                      -- one-shots still playing: { handle, id, prio, voice, endsAt }
AD.loops = {}                      -- [soundId] = { e, owners = {key=true}, n, handle, timer, prio, suspended }
AD.loopOwner = {}                  -- ownerKey -> soundId
AD.lastCue, AD.lastVoice, AD.lastVariant = {}, {}, {}
AD.stats = { played = 0, refused = 0, dropped = 0, stopped = 0, missingCalls = 0, noHandle = 0 }
AD.missing = {}                    -- id or name -> true (asked for, nothing produced / refused)
AD.refused = {}                    -- id -> count of PlaySoundFile refusals
AD.lastTrack = {}                  -- playlist mode -> last track id (no immediate repeats)
local timers = { music = nil, start = nil, emerg = nil, amb = nil }

-- Keyed bookkeeping (cooldowns per actor or sound name, diagnostic "missing" names) is bounded:
-- visitors come and go with new ids and other modules ask for sounds by name, so these tables
-- would otherwise grow over a long session.
AD.KEY_CAP = 128
local keyCount = setmetatable({}, { __mode = "k" })
local function remember(tbl, key, value, t)
    if tbl[key] == nil then
        local c = (keyCount[tbl] or 0) + 1
        if c > AD.KEY_CAP then
            -- drop entries that no longer matter (cooldowns long expired); if all are recent, start over
            c = 0
            for k, v in pairs(tbl) do
                if type(v) ~= "number" or v + 30 < (t or 0) then tbl[k] = nil else c = c + 1 end
            end
            if c >= AD.KEY_CAP then for k in pairs(tbl) do tbl[k] = nil end; c = 0 end
            c = c + 1
        end
        keyCount[tbl] = c
    end
    tbl[key] = value
end
local function markMissing(key)
    if AD.missing[key] == nil then
        local c = (keyCount[AD.missing] or 0)
        if c >= AD.KEY_CAP then AD.stats.missingOverflow = (AD.stats.missingOverflow or 0) + 1; return end
        keyCount[AD.missing] = c + 1
    end
    AD.missing[key] = true
end
AD.Remember, AD.MarkMissing = remember, markMissing

local function cancel(key)
    local t = timers[key]
    if t then t:Cancel(); timers[key] = nil end
end

local function newTimer(key, delay, fn)
    cancel(key)
    if C_Timer and C_Timer.NewTimer then timers[key] = C_Timer.NewTimer(delay, function() timers[key] = nil; fn() end) end
end

-- Timers owned by the director that are still waiting (for leak tests and diagnostics).
function AD.PendingTimers()
    local n = 0
    for _, t in pairs(timers) do if t then n = n + 1 end end
    for _, L in pairs(AD.loops) do if L.timer then n = n + 1 end end
    return n
end

local function stop(handle)
    if type(handle) == "number" and type(StopSound) == "function" then
        StopSound(handle)
        AD.stats.stopped = AD.stats.stopped + 1
    end
end

local function channelFor(n)
    if n.category == "music" then
        local ch = SS.UI and SS.UI.Pref and SS.UI.Pref("musicChannel") or "Master"
        return (ch == "Music") and "Music" or "Master"
    end
    return AD.CHANNEL[n.category] or "SFX"
end

-- Returns a handle (number), true (playing but the client gave no handle), or nil.
local function play(n)
    if not n.file then
        markMissing(n.id)
        AD.stats.missingCalls = AD.stats.missingCalls + 1
        return nil
    end
    if type(PlaySoundFile) ~= "function" then return nil end
    local ok, willPlay, handle = pcall(PlaySoundFile, n.file, channelFor(n))
    if not ok or not willPlay then
        remember(AD.refused, n.id, (AD.refused[n.id] or 0) + 1)
        AD.stats.refused = AD.stats.refused + 1
        if SS.Compat then SS.Compat.caps.soundHandle = "PlaySoundFile refused " .. n.id .. " (file missing or game sound off)" end
        return nil
    end
    AD.stats.played = AD.stats.played + 1
    if handle == nil then
        AD.stats.noHandle = AD.stats.noHandle + 1
        if SS.Compat then SS.Compat.caps.soundHandle = "no handle returned (sounds cannot be stopped early)" end
        return true
    end
    if SS.Compat then SS.Compat.caps.soundHandle = "handles returned (verified by playback)" end
    return handle
end

---------------------------------------------------------------------------
-- Optional, explicit suppression of the client's own music (off by default).
-- Reversible: we remember that *we* switched Sound_EnableMusic off and switch it back on
-- later only if it is still off; if the player changed it themselves meanwhile, we leave it.
---------------------------------------------------------------------------
local function audioDB()
    if not (SS.Save and SS.Save.DB) then return {} end
    local db = SS.Save.DB()
    db.audio = type(db.audio) == "table" and db.audio or {}
    return db.audio
end

function AD.SuppressGameMusic(on)
    if type(GetCVar) ~= "function" or type(SetCVar) ~= "function" then return end
    local st = audioDB()
    if on then
        if st.suppressed then return end
        if GetCVar("Sound_EnableMusic") == "1" then
            SetCVar("Sound_EnableMusic", "0")
            st.suppressed = true
        end
    else
        AD.RestoreGameMusic()
    end
end

function AD.RestoreGameMusic()
    local st = audioDB()
    if not st.suppressed then return end
    if InCombatLockdown and InCombatLockdown() then st.restorePending = true; return end
    if type(GetCVar) == "function" and GetCVar("Sound_EnableMusic") == "0" then SetCVar("Sound_EnableMusic", "1") end
    st.suppressed, st.restorePending = nil, nil
end

local function updateSuppression()
    local want = AD.active and soundOn("music") and SS.UI and SS.UI.Pref and SS.UI.Pref("suppressGameMusic")
    AD.SuppressGameMusic(want and true or false)
end

---------------------------------------------------------------------------
-- Music
---------------------------------------------------------------------------
local function emergencyOn() return AD.emerg and AD.emerg.untilT > now() end

local function isNight()
    local w = SS.Sim and SS.Sim.world
    if not w or not w.time then return false end
    local m = w.time % 1440
    return m >= 21 * 60 or m < 6 * 60
end

-- The playlist mode that should sound now, and its produced tracks.
function AD.DesiredPlaylist()
    local ix = AD.Index()
    local m = AD.mode
    if emergencyOn() then m = "emergency" end
    if not m then return nil, {} end
    if m == "live" and isNight() and #presentOf(ix.playlists.night) > 0 then m = "night" end
    local seen = {}
    while m and not seen[m] do
        seen[m] = true
        local list = presentOf(ix.playlists[m])
        if #list > 0 then return m, list end
        m = AD.MODE_FALLBACK[m]
    end
    return nil, {}
end

local function stopMusic()
    cancel("music"); cancel("start")
    if AD.music then
        if AD.music.handle and not AD.music.ended then stop(AD.music.handle) end
        AD.lastTrackId = AD.music.id
        AD.music = nil
    end
end
AD.StopMusic = function() stopMusic(); updateSuppression() end

-- Entries the client has refused this session (file not installed, e.g. an extra that was not
-- copied in) are passed over while any other entry of the list remains.
local function playable(list)
    local out
    for _, n in ipairs(list) do
        if not AD.refused[n.id] then out = out or {}; out[#out + 1] = n end
    end
    return out or list
end
AD.Playable = playable

local function pickTrack(pm, list)
    local last = AD.lastTrack[pm] or AD.lastTrackId
    list = playable(list)
    local choices = {}
    for _, n in ipairs(list) do if n.id ~= last or #list == 1 then choices[#choices + 1] = n end end
    if #choices == 0 then choices = list end
    local k = (#choices > 1) and math.random(#choices) or 1
    return choices[k]
end

local startTrack
local function onTrackEnd()
    if AD.music then AD.music.ended = true; AD.lastTrackId = AD.music.id; AD.music.handle = nil end
    startTrack()
end

startTrack = function()
    cancel("start")
    if not AD.active or not soundOn("music") then return end
    local pm, list = AD.DesiredPlaylist()
    if not pm then AD.music = nil; AD.silentMode = AD.mode; return end
    AD.silentMode = nil
    local tries, maxTries = 0, #list
    while tries < maxTries and #list > 0 do
        tries = tries + 1
        local n = pickTrack(pm, list)
        local h = play(n)
        AD.lastTrack[pm] = n.id
        if h then
            local t = now()
            AD.music = { id = n.id, handle = h, mode = pm, startedAt = t, endsAt = t + n.dur }
            newTimer("music", math.max(1, n.dur) + AD.TRACK_GAP, onTrackEnd)
            return
        end
        -- refused: drop it from this attempt and try another track of the playlist
        local rest = {}
        for _, x in ipairs(list) do if x ~= n then rest[#rest + 1] = x end end
        list = rest
        if #list == 0 then break end
    end
    AD.music = nil
end

-- Decide what should play now. Keeps the current track if it belongs to the new playlist.
function AD.RefreshMusic()
    if not AD.active or not soundOn("music") then stopMusic(); updateSuppression(); return end
    updateSuppression()
    local pm, list = AD.DesiredPlaylist()
    local cur = AD.music
    if cur and not cur.ended and pm then
        for _, n in ipairs(list) do
            if n.id == cur.id then cur.mode = pm; return end   -- same track fits: no restart
        end
    end
    -- a pending start (a switch a moment ago) counts as playing: quick successive mode changes
    -- re-arm the silent gap instead of starting a track for every mode passed through
    local wasPlaying = (cur and not cur.ended) or timers.start ~= nil
    stopMusic()
    if not pm then AD.silentMode = AD.mode; return end
    if wasPlaying then
        newTimer("start", AD.MODE_GAP, startTrack)  -- hard stop, short silence, then the new track
    else
        startTrack()
    end
end

function AD.SetMode(mode)
    mode = AD.MODE_ALIAS[mode] or mode
    AD.mode = mode
    AD.RefreshMusic()
    AD.RefreshAmbience()
end

---------------------------------------------------------------------------
-- One-shots: cues, effects, voices (priorities, caps, cooldowns)
---------------------------------------------------------------------------
local function prune(t)
    local s = AD.shots
    for n = #s, 1, -1 do if s[n].endsAt <= t then table.remove(s, n) end end
end

-- Make room for a sound of priority `prio`. Returns true if it may play.
local function admit(prio, voice, t)
    prune(t)
    local s = AD.shots
    local count, cap = 0, voice and AD.CAPS.voices or AD.CAPS.oneshots
    for n = 1, #s do if (s[n].voice and true or false) == (voice and true or false) then count = count + 1 end end
    if count < cap and #s < AD.CAPS.oneshots + AD.CAPS.voices then return true end
    -- replace the lowest-priority sound of the same kind if the new one matters more
    local low, lowN
    for n = 1, #s do
        if (s[n].voice and true or false) == (voice and true or false) and (not low or s[n].prio < low) then low, lowN = s[n].prio, n end
    end
    if low and low < prio then
        stop(s[lowN].handle)
        table.remove(s, lowN)
        return true
    end
    AD.stats.dropped = AD.stats.dropped + 1
    return false
end

local function pickVariant(key, list)
    local last = AD.lastVariant[key]
    local choice = list[1]
    if #list > 1 then
        local k = math.random(#list)
        if list[k].id == last then k = k % #list + 1 end
        choice = list[k]
    end
    remember(AD.lastVariant, key, choice.id)
    return choice
end

local function oneShot(list, key, prio, voice)
    local t = now()
    local present = presentOf(list)
    if #present == 0 then
        markMissing(key)
        AD.stats.missingCalls = AD.stats.missingCalls + 1
        return false
    end
    if not admit(prio, voice, t) then return false end
    present = playable(present)
    local n = pickVariant(key, present)
    local h = play(n)
    if not h then
        -- refused (its file is not installed): try the other variants once, so a missing extra
        -- falls back to the core cue under the same name instead of silence
        for _, m in ipairs(present) do
            if m ~= n and not AD.refused[m.id] then
                h = play(m)
                if h then n = m; break end
            end
        end
        if not h then return false end
    end
    table.insert(AD.shots, { handle = h, id = n.id, prio = n.priority or prio, voice = voice, endsAt = t + math.max(0.05, n.dur) })
    return true
end

-- UI and event cues ("click", "money", "alert", "arrival", "bill", "fire", "death", ...).
function AD.Cue(name)
    if not AD.active or not soundOn("effects") or not name then return false end
    local ix = AD.Index()
    local key, seen = name, {}
    while key and not seen[key] and #presentOf(ix.cues[key]) == 0 do
        seen[key] = true
        markMissing("cue:" .. key)
        key = AD.CUE_FALLBACK[key]
    end
    if not key or seen[key] then AD.stats.missingCalls = AD.stats.missingCalls + 1; return false end
    local t = now()
    local cd = (name == "emergency" or name == "fire") and AD.COOLDOWN.emergencyCue or AD.COOLDOWN.cue
    if (AD.lastCue[name] or -1e9) + cd > t then return false end
    remember(AD.lastCue, name, t, t)
    local prio = (name == "emergency" or name == "fire") and AD.PRIORITY.emergency or AD.PRIORITY.cue
    return oneShot(ix.cues[key], "cue:" .. key, prio, false)
end

-- One-shot household effect by name ("doorbell", "dishes", "footstep", ...).
function AD.Sfx(name)
    if not AD.active or not soundOn("effects") or not name then return false end
    local t = now()
    if (AD.lastCue["sfx:" .. name] or -1e9) + AD.COOLDOWN.sfx > t then return false end
    remember(AD.lastCue, "sfx:" .. name, t, t)
    return oneShot(AD.Index().sfx[name], "sfx:" .. name, AD.PRIORITY.sfx, false)
end

-- Babble for an actor in a mood ("neutral", "happy", "laugh", "angry", "sad", "question",
-- "surprise", "effort"). Captions never depend on this (they read the balloon text).
function AD.Voice(actor, mood)
    if not AD.active or not soundOn("voices") then return false end
    local t = now()
    local aid = type(actor) == "table" and actor.id or tostring(actor)
    if (AD.lastVoice[aid] or -1e9) + AD.COOLDOWN.voiceActor > t then return false end
    if (AD.lastVoice["*"] or -1e9) + AD.COOLDOWN.voiceAny > t then return false end
    local ix = AD.Index()
    local list = ix.voices[mood or "neutral"]
    if #presentOf(list) == 0 then
        markMissing("voice:" .. tostring(mood))
        list = ix.voices.neutral
    end
    remember(AD.lastVoice, aid, t, t); AD.lastVoice["*"] = t
    return oneShot(list, "voice:" .. (mood or "neutral"), AD.PRIORITY.voice, true)
end

---------------------------------------------------------------------------
-- Loops, owned by a key (object id, system name). Two owners asking for the same sound share
-- one handle, so two smoke alarms never stack two alarm loops.
---------------------------------------------------------------------------
local function loopCount()
    local n = 0
    for _, L in pairs(AD.loops) do if L.handle then n = n + 1 end end
    return n
end

local startLoop
startLoop = function(L)
    if L.timer then L.timer:Cancel(); L.timer = nil end
    if not AD.active or not soundOn("effects") then L.handle = nil; return end
    if loopCount() >= AD.CAPS.loops then
        -- make room only for something more important
        local lowId, low
        for id, o in pairs(AD.loops) do if o.handle and (not low or o.prio < low) then low, lowId = o.prio, id end end
        if low and low < L.prio then
            local o = AD.loops[lowId]
            stop(o.handle); o.handle = nil; o.suspended = true
            if o.timer then o.timer:Cancel(); o.timer = nil end
        else
            L.suspended = true
            AD.stats.dropped = AD.stats.dropped + 1
            return
        end
    end
    local h = play(L.e)
    if not h then L.handle = nil; return end
    L.handle, L.suspended = h, nil
    if C_Timer and C_Timer.NewTimer then
        L.timer = C_Timer.NewTimer(math.max(0.5, L.e.dur), function() L.timer = nil; L.handle = nil; startLoop(L) end)
    end
end

function AD.Loop(ownerKey, name)
    if not ownerKey or not name then return false end
    local cur = AD.loopOwner[ownerKey]
    if cur then
        local L = AD.loops[cur]
        if L and L.e.name == name then return true end
        AD.StopLoop(ownerKey)
    end
    local list = presentOf(AD.Index().loops[name])
    if #list == 0 then
        markMissing("loop:" .. name)
        AD.stats.missingCalls = AD.stats.missingCalls + 1
        return false
    end
    local e = list[1]
    local L = AD.loops[e.id]
    AD.loopOwner[ownerKey] = e.id
    if L then
        if not L.owners[ownerKey] then L.owners[ownerKey] = true; L.n = L.n + 1 end
        return true
    end
    L = { e = e, owners = { [ownerKey] = true }, n = 1, prio = e.priority or AD.PRIORITY.loop }
    AD.loops[e.id] = L
    startLoop(L)
    return true
end

function AD.StopLoop(ownerKey)
    local id = ownerKey and AD.loopOwner[ownerKey]
    if not id then return end
    AD.loopOwner[ownerKey] = nil
    local L = AD.loops[id]
    if not L then return end
    if L.owners[ownerKey] then L.owners[ownerKey] = nil; L.n = L.n - 1 end
    if L.n <= 0 then
        if L.timer then L.timer:Cancel(); L.timer = nil end
        if L.handle then stop(L.handle) end
        AD.loops[id] = nil
        -- a suspended loop may now fit
        for _, o in pairs(AD.loops) do if o.suspended and not o.handle then startLoop(o); break end end
    end
end

local function pauseLoops()
    for _, L in pairs(AD.loops) do
        if L.timer then L.timer:Cancel(); L.timer = nil end
        if L.handle then stop(L.handle); L.handle = nil end
    end
end

local function resumeLoops()
    local ids = {}
    for id in pairs(AD.loops) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return AD.loops[a].prio > AD.loops[b].prio end)
    for _, id in ipairs(ids) do local L = AD.loops[id]; if L and not L.handle then startLoop(L) end end
end

-- Forget every loop (lot switch: the owners belong to the previous lot).
function AD.ClearLoops()
    pauseLoops()
    AD.loops, AD.loopOwner = {}, {}
end

---------------------------------------------------------------------------
-- Ambience: one bed at a time. Ambience(kind) sets an explicit bed (nil returns to automatic).
---------------------------------------------------------------------------
local function desiredAmbience()
    if emergencyOn() then return nil end
    if AD.ambKind ~= nil then return AD.ambKind or nil end
    local m = AD.mode
    if m == "live" then return isNight() and "night" or "day" end
    return m and AD.AMBIENCE_FOR[m] or nil
end

local function stopAmbience()
    cancel("amb")
    if AD.amb then
        if AD.amb.handle then stop(AD.amb.handle) end
        AD.amb = nil
    end
end

function AD.RefreshAmbience()
    if not AD.active or not soundOn("ambience") then stopAmbience(); return end
    local kind = desiredAmbience()
    if AD.amb and AD.amb.kind == kind and AD.amb.handle then return end
    stopAmbience()
    if not kind then return end
    local list = presentOf(AD.Index().ambience[kind])
    if #list == 0 then markMissing("amb:" .. kind); AD.amb = { kind = kind }; return end
    local n = pickVariant("amb:" .. kind, list)
    local h = play(n)
    AD.amb = { kind = kind, id = n.id, handle = h }
    if h then newTimer("amb", math.max(1, n.dur), function() if AD.amb then AD.amb.handle = nil end; AD.RefreshAmbience() end) end
end

function AD.Ambience(kind)
    AD.ambKind = kind or nil
    if AD.amb then stopAmbience() end
    AD.RefreshAmbience()
end

---------------------------------------------------------------------------
-- Emergencies take precedence
---------------------------------------------------------------------------
local function emergencyCheck()
    local w = SS.Sim and SS.Sim.world
    local burning = w and SS.Fire and SS.Fire.Active and SS.Fire.Active(w)
    if burning and AD.active then
        AD.emerg.untilT = now() + 10
        newTimer("emerg", 10, emergencyCheck)
        return
    end
    AD.emerg = nil
    AD.RefreshMusic()
    AD.RefreshAmbience()
end

function AD.Emergency(text, severity)
    severity = severity or "emergency"
    if severity ~= "emergency" then
        AD.Cue(severity == "warning" and "tension" or "arrival")
        return
    end
    local t = now()
    local fresh = not emergencyOn()
    AD.emerg = { untilT = t + AD.EMERGENCY_HOLD, text = text }
    newTimer("emerg", AD.EMERGENCY_HOLD, emergencyCheck)
    if fresh then
        AD.RefreshMusic()     -- stops mode music (an "emergency" playlist would play instead, but none is planned: see AD.PlaylistCoverage)
        AD.RefreshAmbience()
    end
    AD.Cue("emergency")       -- one alarm cue; the cooldown stops repeated emergencies stacking alarms
end

function AD.InEmergency() return emergencyOn() and true or false end

---------------------------------------------------------------------------
-- Window lifecycle and settings
---------------------------------------------------------------------------
-- The window opened: sound may play again (music restarts from the beginning of a track).
function AD.Activate()
    AD.active = true
    AD.RefreshMusic()
    AD.RefreshAmbience()
    resumeLoops()
end

-- The window closed or combat hid it: stop every handle this addon owns and every timer.
-- Loop requests are remembered (the lot is frozen, so they are still true on reopen).
function AD.Shutdown()
    AD.active = false
    stopMusic()
    stopAmbience()
    pauseLoops()
    for _, s in ipairs(AD.shots) do stop(s.handle) end
    AD.shots = {}
    cancel("emerg"); AD.emerg = nil
    updateSuppression()
end

-- A sound category was switched on or off in Options.
function AD.OnSetting(key)
    if key == "sound.music" or key == "musicChannel" or key == "suppressGameMusic" then
        if key == "musicChannel" then stopMusic() end
        AD.RefreshMusic()
    elseif key == "sound.ambience" then AD.RefreshAmbience()
    elseif key == "sound.effects" then
        if soundOn("effects") then resumeLoops() else
            pauseLoops()
            for n = #AD.shots, 1, -1 do if not AD.shots[n].voice then stop(AD.shots[n].handle); table.remove(AD.shots, n) end end
        end
    elseif key == "sound.voices" and not soundOn("voices") then
        for n = #AD.shots, 1, -1 do if AD.shots[n].voice then stop(AD.shots[n].handle); table.remove(AD.shots, n) end end
    end
end

-- Handles currently believed audible (for tests and diagnostics).
function AD.ActiveHandles()
    local t = now()
    prune(t)
    local n = #AD.shots
    if AD.music and AD.music.handle and not AD.music.ended then n = n + 1 end
    if AD.amb and AD.amb.handle then n = n + 1 end
    for _, L in pairs(AD.loops) do if L.handle then n = n + 1 end end
    return n
end

function AD.Status()
    local ix = AD.Index()
    local missing = 0
    for _ in pairs(AD.missing) do missing = missing + 1 end
    local loops, suspended = 0, 0
    for _, L in pairs(AD.loops) do loops = loops + 1; if L.suspended then suspended = suspended + 1 end end
    local pm = AD.DesiredPlaylist()
    return {
        active = AD.active, mode = AD.mode, playlist = pm, track = AD.music and AD.music.id,
        emergency = emergencyOn() and true or false, ambience = AD.amb and AD.amb.kind, ambienceId = AD.amb and AD.amb.id,
        loops = loops, suspendedLoops = suspended, shots = #AD.shots, handles = AD.ActiveHandles(),
        manifest = ix.total, present = ix.present, planned = ix.planned, byRole = ix.byRole,
        missingAsked = missing, refused = AD.stats.refused, played = AD.stats.played, dropped = AD.stats.dropped,
        noHandle = AD.stats.noHandle, timers = AD.PendingTimers(),
    }
end

-- Music coverage of the manifest as it ships: for every music mode, the tracks planned and
-- produced for it and what actually sounds there (its own playlist, a fallback's, or silence).
-- Emergencies have no playlist by design: mode music stops and one alarm cue plays.
AD.COVERAGE_MODES = { "title", "tutorial", "live", "night", "hood", "create", "build", "buy", "party",
    "venue_cafe", "venue_shops", "venue_club", "venue_park", "emergency" }
function AD.PlaylistCoverage()
    local ix = AD.Index()
    local names, seen = {}, {}
    for _, m in ipairs(AD.COVERAGE_MODES) do if not seen[m] then seen[m] = true; names[#names + 1] = m end end
    local extra = {}
    for m in pairs(ix.playlists) do if not seen[m] then extra[#extra + 1] = m end end
    table.sort(extra)
    for _, m in ipairs(extra) do names[#names + 1] = m end
    local rows, sum = {}, { modes = 0, own = 0, borrowed = 0, silent = 0, missingTracks = 0 }
    for _, m in ipairs(names) do
        local list = ix.playlists[m] or {}
        local produced = #presentOf(list)
        local sounds, k, hop = nil, m, {}
        while k and not hop[k] do
            hop[k] = true
            if #presentOf(ix.playlists[k]) > 0 then sounds = k; break end
            k = AD.MODE_FALLBACK[k]
        end
        rows[#rows + 1] = { mode = m, planned = #list - produced, produced = produced, sounds = sounds }
        sum.modes = sum.modes + 1
        if produced > 0 then sum.own = sum.own + 1 elseif sounds then sum.borrowed = sum.borrowed + 1 else sum.silent = sum.silent + 1 end
    end
    -- distinct music tracks not produced (a track listed under two modes counts once)
    for _, n in pairs(ix.byId) do if n.role == "music" and not n.file then sum.missingTracks = sum.missingTracks + 1 end end
    return rows, sum
end

function AD.CoverageLines()
    local rows, sum = AD.PlaylistCoverage()
    local own, borrow, silent = {}, {}, {}
    for _, r in ipairs(rows) do
        if r.produced > 0 then own[#own + 1] = string.format("%s %d/%d", r.mode, r.produced, r.produced + r.planned)
        elseif r.sounds then borrow[#borrow + 1] = string.format("%s -> %s", r.mode, r.sounds)
        else silent[#silent + 1] = r.mode .. (r.planned > 0 and string.format(" (%d planned)", r.planned) or "") end
    end
    return {
        string.format("Music by mode (this manifest, %d modes): %d with produced tracks of their own, %d borrowing another playlist, %d silent; %d planned tracks not produced.",
            sum.modes, sum.own, sum.borrowed, sum.silent, sum.missingTracks),
        "      own: " .. (#own > 0 and table.concat(own, ", ") or "none"),
        "      borrowing: " .. (#borrow > 0 and table.concat(borrow, ", ") or "none"),
        "      silent: " .. (#silent > 0 and table.concat(silent, ", ") or "none") .. " (an emergency always stops music and plays one alarm cue)",
    }
end

function AD.Report()
    local s = AD.Status()
    local lines = {}
    local function roleLine(role, label)
        local r = s.byRole[role] or { total = 0, present = 0 }
        return string.format("%s %d/%d", label, r.present, r.total)
    end
    lines[#lines + 1] = string.format("Audio files produced: %d of %d manifest entries (%s, %s, %s, %s, %s); the rest are planned and play as silence.",
        s.present, s.manifest, roleLine("music", "music"), roleLine("cue", "cues"), roleLine("sfx", "effects"),
        roleLine("ambience", "ambience"), roleLine("voice", "voices"))
    lines[#lines + 1] = string.format("Audio now: mode %s, playlist %s, track %s, ambience %s, loops %d, one-shots %d, emergency %s.",
        tostring(s.mode), tostring(s.playlist or "silent (no produced track for this mode)"), tostring(s.track or "none"),
        tostring(s.ambienceId or (s.ambience and (s.ambience .. " (missing)")) or "none"), s.loops, s.shots, s.emergency and "yes" or "no")
    lines[#lines + 1] = string.format("Audio counts: %d played, %d refused by the client (missing file or game sound off), %d dropped by caps, %d requests for sounds not produced yet.",
        s.played, s.refused, s.dropped, s.missingAsked)
    for _, l in ipairs(AD.CoverageLines()) do lines[#lines + 1] = l end
    lines[#lines + 1] = "Audio transitions are hard stop/start with a short silent gap (no crossfades, no per-sound volume); tracks restart from the beginning when the window reopens."
    return lines
end

---------------------------------------------------------------------------
-- Bus hooks (pure Lua event bus, safe at load time)
---------------------------------------------------------------------------
SS.On("emergency", function(text, severity) AD.Emergency(text, severity) end)
SS.On("settings", function(key) AD.OnSetting(key) end)
SS.On("worldAttached", function()
    AD.ClearLoops()
    AD.ambKind = nil
    if AD.active then AD.RefreshAmbience() end
end)
SS.On("money", function(delta, text, cat)
    if delta > 0 then AD.Cue(cat == "sale" and "sell" or "money")
    elseif cat == "bills" then AD.Cue("bill")
    elseif cat == "purchase" then AD.Cue("purchase") end
end)
SS.On("death", function() AD.Cue("death") end)
