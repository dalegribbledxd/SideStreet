-- SideStreet compatibility layer and performance measurement.
--
-- SS.Compat probes what the running client actually supports (each check is a real call, never
-- a guess from a name) and turns the result into an actionable report: every line that is not OK
-- says what the player can do about it. /sidestreet diag prints it; the in-window diagnostics
-- panel (UI.Diag, at the end of UI/Options.lua) shows it.
--
-- SS.Perf measures Lua time per subsystem with debugprofilestop (sim step, autonomy,
-- pathfinding, layout, actors, UI), counts the addon's own update rate, sprites, path searches,
-- actors and objects, and reads Lua memory with GetAddOnMemoryUsage (Lua heap only). The client
-- framerate is shown only as GetFramerate reports it. Nothing here is estimated or invented;
-- offline (mock) numbers are labelled as such by the callers.
--
-- Pure Lua at load time: no WoW API is called until Probe/Install/Report run.
local _, SS = ...
local C = SS.Compat or {}
SS.Compat = C
C.caps = C.caps or {}
C.probed = false
C.TOC_INTERFACE = 16001
C.MIN_W, C.MIN_H = 720, 500

local function has(t, k) return type(t) == "table" and type(t[k]) == "function" end
local function fn(name) return type(_G[name]) == "function" end
local function cvar(name)
    if not fn("GetCVar") then return nil end
    local ok, v = pcall(GetCVar, name)
    if ok then return v end
    return nil
end
C.CVar = cvar

---------------------------------------------------------------------------
-- Probe: one pass over the client's capabilities (repeatable with force = true).
---------------------------------------------------------------------------
function C.Probe(force)
    if C.probed and not force then return C.caps end
    local caps = C.caps
    if fn("GetBuildInfo") then
        local ok, version, build, bdate, iface = pcall(GetBuildInfo)
        if ok then caps.version, caps.build, caps.buildDate, caps.interface = version, build, bdate, iface end
    end
    caps.createFrame = fn("CreateFrame")
    local f = C.probeFrame
    if not f and caps.createFrame then
        local ok, fr = pcall(CreateFrame, "Frame")
        if ok then f = fr; C.probeFrame = fr end
    end
    caps.clipsChildren = has(f, "SetClipsChildren")
    caps.resizeBounds = has(f, "SetResizeBounds")
    caps.minResize = has(f, "SetMinResize")
    caps.propagateKeyboard = has(f, "SetPropagateKeyboardInput")
    caps.keyboard = has(f, "EnableKeyboard")
    caps.hookScript = has(f, "HookScript")
    caps.strata = has(f, "SetFrameStrata") and has(f, "SetToplevel")
    local t = C.probeTex
    if not t and f and has(f, "CreateTexture") then t = f:CreateTexture(); C.probeTex = t end
    caps.textureFilter = (t and has(t, "SetTexture") and pcall(t.SetTexture, t, "Interface\\Buttons\\WHITE8X8", nil, nil, "NEAREST")) and true or false
    caps.texCoord = has(t, "SetTexCoord") and has(t, "SetVertexColor")
    caps.colorTexture = has(t, "SetColorTexture")
    caps.maskTexture = has(f, "CreateMaskTexture")
    caps.cursor = fn("GetCursorPosition")
    caps.playSoundFile = fn("PlaySoundFile")
    caps.stopSound = fn("StopSound")
    caps.timer = type(C_Timer) == "table" and type(C_Timer.NewTimer) == "function"
    caps.getTime = fn("GetTime")
    caps.secrets = fn("issecretvalue")
    caps.memory = fn("UpdateAddOnMemoryUsage") and (fn("GetAddOnMemoryUsage")
        or (type(C_AddOns) == "table" and type(C_AddOns.GetAddOnMemoryUsage) == "function"))
    caps.profile = fn("debugprofilestop")
    caps.framerate = fn("GetFramerate")
    caps.combat = fn("InCombatLockdown")
    caps.cvars = fn("GetCVar")
    caps.screen = fn("GetScreenWidth") and fn("GetScreenHeight")
    caps.font = GameFontNormal ~= nil
    caps.soundHandle = caps.soundHandle or "not verified yet (checked the first time a sound plays)"
    caps.savedVariables = type(rawget(_G, "SideStreetDB")) == "table"
    C.probed = true
    C.probedAt = (fn("GetTime") and GetTime()) or 0
    return caps
end

---------------------------------------------------------------------------
-- Checks: structured, each with a status and an action for the player.
--   { id, label, status = "ok"|"warn"|"fail"|"info"|"design", detail, action }
-- "design" is a statement about SideStreet that the client cannot confirm (it is not a probe).
---------------------------------------------------------------------------
local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

function C.Checks()
    local c = C.Probe()
    local out = {}
    local function add(id, label, status, detail, action)
        out[#out + 1] = { id = id, label = label, status = status, detail = detail, action = action }
    end
    -- client and TOC
    local iface = tonumber(c.interface)
    add("client", "Client", "info", string.format("version %s, build %s, interface %s; SideStreet's TOC declares %d",
        tostring(c.version or "?"), tostring(c.build or "?"), tostring(c.interface or "?"), C.TOC_INTERFACE),
        (iface and iface ~= C.TOC_INTERFACE and tostring(c.build) ~= tostring(C.TOC_INTERFACE))
            and "If the AddOns list calls SideStreet out of date, tick 'Load out of date AddOns'." or nil)
    -- dependencies: read from the client's list of what the TOC declares, not assumed
    local getDeps = type(C_AddOns) == "table" and type(C_AddOns.GetAddOnDependencies) == "function" and C_AddOns.GetAddOnDependencies
    local isLoaded = type(C_AddOns) == "table" and type(C_AddOns.IsAddOnLoaded) == "function" and C_AddOns.IsAddOnLoaded
    local depsOk, deps = false, nil
    if getDeps then depsOk, deps = pcall(function() return { getDeps(SS.ADDON or "SideStreet") } end) end
    if depsOk and type(deps) == "table" then
        local absent = {}
        for _, d in ipairs(deps) do
            local ok, loaded = pcall(isLoaded or function() return false end, d)
            if not (ok and loaded) then absent[#absent + 1] = tostring(d) end
        end
        add("deps", "Dependencies", #absent == 0 and "ok" or "fail",
            #deps == 0 and "none declared in the TOC (C_AddOns.GetAddOnDependencies); no external program is used"
                or (#deps .. " declared: " .. table.concat(deps, ", ") .. (#absent > 0 and ("; not loaded: " .. table.concat(absent, ", ")) or "")),
            #absent > 0 and ("Enable " .. table.concat(absent, ", ") .. " in the AddOns list, or reinstall SideStreet.") or nil)
    else
        add("deps", "Dependencies", "design", "by design, not probed: the TOC declares none and no external program is used (this client cannot list dependencies)", nil)
    end
    -- load order: the systems every screen needs
    local need = { { "Tuning", SS.Tuning }, { "Save", SS.Save }, { "Sim", SS.Sim }, { "Actions", SS.Actions },
        { "Nav", SS.Nav }, { "Render", SS.Render }, { "UI", SS.UI }, { "Audio", SS.Audio }, { "Boot", SS.Boot } }
    local missing = {}
    for _, e in ipairs(need) do if type(e[2]) ~= "table" then missing[#missing + 1] = e[1] end end
    add("load", "Load order", #missing == 0 and "ok" or "fail",
        #missing == 0 and "core, simulation, renderer, interface, audio and start-up loaded in order"
            or ("missing parts: " .. table.concat(missing, ", ")),
        #missing > 0 and "Reinstall SideStreet: some files did not load (check the folder name is exactly Interface\\AddOns\\SideStreet)." or nil)
    add("saved", "Saved data", c.savedVariables and "ok" or "fail",
        c.savedVariables and "SideStreetDB loaded; saves are written to disk by WoW at logout or /reload"
            or "SideStreetDB is not available",
        not c.savedVariables and "Saves cannot persist. Make sure the TOC lists '## SavedVariables: SideStreetDB' and log out normally once." or nil)
    add("clip", "Lot clipping", c.clipsChildren and "ok" or "warn",
        c.clipsChildren and "SetClipsChildren: the lot stays inside its window" or "SetClipsChildren is missing",
        not c.clipsChildren and "The lot may draw past the window edge: zoom out or make the window larger." or nil)
    add("resize", "Window resizing", (c.resizeBounds or c.minResize) and "ok" or "warn",
        c.resizeBounds and "SetResizeBounds" or (c.minResize and "SetMinResize") or "no resize limits",
        not (c.resizeBounds or c.minResize) and string.format("Keep the window at least %dx%d so the panels fit.", C.MIN_W, C.MIN_H) or nil)
    add("keys", "Keyboard", c.propagateKeyboard and "ok" or "warn",
        c.propagateKeyboard and "SetPropagateKeyboardInput: unused keys pass through to the game" or "SetPropagateKeyboardInput is missing",
        not c.propagateKeyboard and "Shortcut keys are limited so SideStreet never swallows your game keys; use the on-screen buttons." or nil)
    add("filter", "Sharp sprites", c.textureFilter and "ok" or "info",
        c.textureFilter and "nearest-neighbour texture filter accepted" or "texture filter argument not accepted",
        not c.textureFilter and "Sprites may look slightly soft; nothing to do." or nil)
    add("tex", "Texture tinting", c.texCoord and "ok" or "fail",
        c.texCoord and "SetTexCoord and SetVertexColor present" or "SetTexCoord or SetVertexColor missing",
        not c.texCoord and "The lot cannot be drawn in this client. Please report the client version shown above." or nil)
    -- art
    local sheets = SS.Art and count(SS.Art.sheets) or 0
    local sprites = SS.Art and count(SS.Art.sprites) or 0
    local missingArt = SS.Render and tonumber(SS.Render.missing) or 0
    add("art", "Art", (sheets > 0 and missingArt == 0) and "ok" or (sheets > 0 and "warn" or "fail"),
        string.format("%d atlas sheets, %d sprites in the manifest; %d draw requests had no sprite%s", sheets, sprites, missingArt,
            (SS.Art and SS.Art.format) and ("; format " .. tostring(SS.Art.format)) or ""),
        (missingArt > 0 or sheets == 0) and "Missing art is drawn as a plain placeholder. If the whole lot is boxes, check that Media\\Art was installed with the addon." or
            "Code cannot see the pixels: if textures look wrong or green, report it with a screenshot.")
    -- sound
    local sound = c.playSoundFile and c.stopSound
    add("soundapi", "Sound playback", sound and "ok" or "fail",
        string.format("PlaySoundFile %s, StopSound %s; handles: %s", c.playSoundFile and "yes" or "NO", c.stopSound and "yes" or "NO", tostring(c.soundHandle)),
        not sound and "SideStreet plays without sound in this client." or nil)
    add("timer", "Timers", c.timer and "ok" or "warn",
        c.timer and "C_Timer.NewTimer" or "C_Timer.NewTimer missing",
        not c.timer and "Music will not move on to the next track; everything else works." or nil)
    if c.cvars then
        local all, music, sfx, amb, dlg = cvar("Sound_EnableAllSound"), cvar("Sound_EnableMusic"), cvar("Sound_EnableSFX"),
            cvar("Sound_EnableAmbience"), cvar("Sound_EnableDialog")
        if all == "0" then
            add("gamesound", "Game sound", "warn", "the game's sound is switched off",
                "SideStreet's music and effects stay silent until you turn sound on (Game Menu > Options > Audio). SideStreet never changes it for you.")
        else
            local ch = SS.UI and SS.UI.Pref and SS.UI.Pref("musicChannel") or "Master"
            local notes, act = {}, {}
            if music == "0" then
                notes[#notes + 1] = "game music off"
                if ch == "Music" then act[#act + 1] = "SideStreet's music follows the game's Music channel, which is off: turn it on, or set Options > Sound > Music channel to Master." end
            end
            if sfx == "0" then notes[#notes + 1] = "sound effects off"; act[#act + 1] = "Effects and cues use the Sound Effects channel, which is off." end
            if amb == "0" then notes[#notes + 1] = "ambient sound off"; act[#act + 1] = "Ambience beds use the Ambience channel, which is off." end
            if dlg == "0" then notes[#notes + 1] = "dialog off"; act[#act + 1] = "Voices use the Dialog channel, which is off (captions still show)." end
            add("gamesound", "Game sound", #act > 0 and "warn" or "ok",
                #notes > 0 and table.concat(notes, ", ") or "the game's sound channels are on",
                #act > 0 and table.concat(act, " ") or nil)
        end
    end
    if SS.Audio and SS.Audio.Status then
        local s = SS.Audio.Status()
        add("audiofiles", "Audio files", (s.refused or 0) > 0 and "warn" or "info",
            string.format("%d of %d manifest sounds are produced; the rest are planned and play as silence. %d refused by the client.",
                s.present or 0, s.manifest or 0, s.refused or 0),
            (s.refused or 0) > 0 and "A packaged sound could not be played: check Media\\Audio is installed, or that game sound is on." or nil)
    end
    add("memory", "Memory reading", c.memory and "ok" or "info",
        c.memory and "GetAddOnMemoryUsage (Lua heap only)" or "not available", not c.memory and "Memory numbers are not shown." or nil)
    add("profile", "Timing", c.profile and "ok" or "info",
        c.profile and "debugprofilestop" or "not available", not c.profile and "Per-system timings are not shown." or nil)
    add("fps", "Framerate", c.framerate and "ok" or "info",
        c.framerate and "GetFramerate (shown exactly as the client reports it)" or "not available",
        not c.framerate and "No framerate is shown; SideStreet never estimates one." or nil)
    add("combat", "Combat safety", c.combat and "ok" or "warn",
        c.combat and "InCombatLockdown: the window hides and pauses when combat starts" or "InCombatLockdown missing",
        not c.combat and "Close SideStreet yourself before a fight." or nil)
    add("secrets", "Restricted values", "info",
        c.secrets and "issecretvalue present; SideStreet reads no combat, unit or chat data" or "issecretvalue absent; SideStreet reads no combat, unit or chat data", nil)
    if c.screen then
        local sw, sh = GetScreenWidth(), GetScreenHeight()
        local small = (sw or 0) < C.MIN_W or (sh or 0) < C.MIN_H
        add("screen", "Screen", small and "warn" or "ok", string.format("%dx%d UI units", sw or 0, sh or 0),
            small and "The window needs about 720x500 UI units: lower the game's UI scale." or nil)
    end
    add("fonts", "Fonts", c.font and "ok" or "warn", c.font and "GameFontNormal available" or "GameFontNormal missing",
        not c.font and "Text may use a fallback font." or nil)
    add("input", "Bindings", "design", "by design, not probed: SideStreet never changes key bindings, casts, buys, chats or touches WoW gold", nil)
    return out
end

-- "design" marks a statement about SideStreet itself rather than a probe of the client; the
-- report counts those apart from the probed checks.
local MARK = { ok = "OK", warn = "WARN", fail = "FAIL", info = "INFO", design = "BY DESIGN" }
function C.Counts(checks)
    local probed, design = 0, 0
    for _, e in ipairs(checks or C.Checks()) do if e.status == "design" then design = design + 1 else probed = probed + 1 end end
    return probed, design
end
function C.Report()
    local checks = C.Checks()
    local probed, design = C.Counts(checks)
    local lines = { string.format("SideStreet %s, save schema %d: %d checks measured at run time, %d stated by design", tostring(SS.VERSION), SS.SCHEMA or 0, probed, design) }
    for _, e in ipairs(checks) do
        lines[#lines + 1] = string.format("[%s] %s: %s", MARK[e.status] or "?", e.label, e.detail)
        if e.action then lines[#lines + 1] = "      -> " .. e.action end
    end
    local w = SS.Sim and SS.Sim.world
    if w then
        local n = 0
        for _ in pairs(w.lot.objects) do n = n + 1 end
        local clock = (SS.UI and SS.UI.ClockText) and SS.UI.ClockText(w.time) or tostring(w.time)
        lines[#lines + 1] = string.format("World: %s, %d objects, %s, speed %s, sim steps %d, path searches %d",
            tostring(w.lot.address or w.lot.id), n, clock, tostring(w.speed), SS.Sim.perf and SS.Sim.perf.steps or 0,
            SS.Nav and SS.Nav.stats and SS.Nav.stats.searches or 0)
    else
        lines[#lines + 1] = "World: none loaded yet (open the window to start or continue a game)."
    end
    local c = C.caps
    if c.memory then
        local kb = C.MemoryKB()
        if kb then lines[#lines + 1] = string.format("Lua memory accounted to SideStreet: %.0f KB (Lua heap only; textures, sounds and the client are not included)", kb) end
    end
    return lines
end

-- Lua memory used by this addon, in KB (or nil). Updating the numbers scans every addon, so
-- callers do it on demand or at most every few seconds.
function C.MemoryKB()
    if not fn("UpdateAddOnMemoryUsage") then return nil end
    local ok = pcall(UpdateAddOnMemoryUsage)
    if not ok then return nil end
    local get = fn("GetAddOnMemoryUsage") and GetAddOnMemoryUsage or (type(C_AddOns) == "table" and C_AddOns.GetAddOnMemoryUsage)
    if not get then return nil end
    local ok2, kb = pcall(get, SS.ADDON or "SideStreet")
    if ok2 and type(kb) == "number" then return kb end
    return nil
end

---------------------------------------------------------------------------
-- SS.Perf: measured costs per subsystem.
--   local t0 = P.Begin(); ...work...; P.End("layout", t0)
-- Subsystems: sim (the whole simulation update, including autonomy and pathfinding), autonomy
-- (decision making), path (route searches), layout (static lot draw lists), actors (moving
-- sprites), ui (panels, captions, notices, mode tools). Values are inclusive: autonomy and path
-- run inside sim. Samples roll over every P.WINDOW real seconds; nothing grows over time.
---------------------------------------------------------------------------
local P = SS.Perf or {}
SS.Perf = P
P.SUBS = { "sim", "autonomy", "path", "layout", "actors", "ui" }
P.LABEL = { sim = "sim step", autonomy = "autonomy", path = "pathfinding", layout = "lot layout", actors = "actors", ui = "interface" }
P.WINDOW = 1
P.BUDGET_MS = 6      -- average SideStreet Lua ms per client frame above which optional detail is reduced
P.RECOVER_MS = 3     -- ... and below which it comes back
P.SLOW_WINDOWS, P.FAST_WINDOWS = 3, 5
P.quality = P.quality or "normal"
P.enabled = true

-- Declared capacity (brief §22): what the game is built and tested for. Values owned by other
-- modules are read from their tuning when present (the numbers here are the documented defaults).
P.CAPACITY = {
    household = 8,        -- residents in one household (the 8-resident stress household)
    guests = 8,           -- party guest list cap (family module: SS.FamilyData.party.maxGuests)
    venueCrowd = 24,      -- actors on a community lot (outings module: SS.VenueData.tuning.crowdCap)
    captions = 8,         -- dialogue captions on screen (4 at reduced detail)
    reducedCaptions = 4,
    actorFps = 30,        -- moving-sprite updates per second at reduced detail (every frame otherwise)
}
function P.Capacity()
    local c = P.CAPACITY
    local fam = type(SS.FamilyData) == "table" and SS.FamilyData.party
    local vt = type(SS.VenueData) == "table" and SS.VenueData.tuning
    local party = type(fam) == "table" and fam.maxGuests
    local venue = type(vt) == "table" and vt.crowdCap
    return {
        household = c.household, guests = tonumber(party) or c.guests, venueCrowd = tonumber(venue) or c.venueCrowd,
        captions = c.captions, reducedCaptions = c.reducedCaptions, actorFps = c.actorFps,
        oneshots = SS.Audio and SS.Audio.CAPS and SS.Audio.CAPS.oneshots, voices = SS.Audio and SS.Audio.CAPS and SS.Audio.CAPS.voices,
        loops = SS.Audio and SS.Audio.CAPS and SS.Audio.CAPS.loops,
    }
end

local function newAcc()
    local t = { ms = {}, calls = {}, maxMs = {}, frames = 0, secs = 0, frameMs = 0, maxFrameMs = 0 }
    for _, s in ipairs(P.SUBS) do t.ms[s], t.calls[s], t.maxMs[s] = 0, 0, 0 end
    return t
end
P.cur, P.last, P.total = newAcc(), newAcc(), newAcc()
P.slow, P.fast = 0, 0
P.wrapped = {}

local function clock()
    local f = debugprofilestop
    if type(f) == "function" then return f() end
    return nil
end

function P.Begin()
    if not P.enabled then return nil end
    return clock()
end

function P.End(name, t0)
    if not t0 then return end
    local t1 = clock()
    if not t1 then return end
    local d = t1 - t0
    local cur = P.cur
    if cur.ms[name] == nil then cur.ms[name], cur.calls[name], cur.maxMs[name] = 0, 0, 0 end
    cur.ms[name] = cur.ms[name] + d
    cur.calls[name] = cur.calls[name] + 1
    if d > cur.maxMs[name] then cur.maxMs[name] = d end
end

function P.FrameBegin()
    if not P.enabled then return nil end
    return clock()
end

local function roll()
    local cur, last, total = P.cur, P.last, P.total
    -- swap cur and last (no new tables), then clear the new cur
    P.last, P.cur = cur, last
    for k in pairs(cur.ms) do
        total.ms[k] = (total.ms[k] or 0) + cur.ms[k]
        total.calls[k] = (total.calls[k] or 0) + cur.calls[k]
        if (cur.maxMs[k] or 0) > (total.maxMs[k] or 0) then total.maxMs[k] = cur.maxMs[k] end
    end
    total.frames, total.secs, total.frameMs = total.frames + cur.frames, total.secs + cur.secs, total.frameMs + cur.frameMs
    if cur.maxFrameMs > total.maxFrameMs then total.maxFrameMs = cur.maxFrameMs end
    local nc = P.cur
    for k in pairs(nc.ms) do nc.ms[k], nc.calls[k], nc.maxMs[k] = 0, 0, 0 end
    nc.frames, nc.secs, nc.frameMs, nc.maxFrameMs = 0, 0, 0, 0
    P.windows = (P.windows or 0) + 1
    -- snapshots of the counters that live elsewhere, so the report can show per-window workload
    local nav = SS.Nav and SS.Nav.stats
    if nav then
        P.navLast = (nav.searches or 0) - (P.navMark or nav.searches or 0)
        P.navMark = nav.searches or 0
    end
    P.UpdateQuality()
end

function P.FrameEnd(t0, elapsed)
    local cur = P.cur
    cur.frames = cur.frames + 1
    cur.secs = cur.secs + (elapsed or 0)
    if t0 then
        local t1 = clock()
        if t1 then
            local d = t1 - t0
            cur.frameMs = cur.frameMs + d
            if d > cur.maxFrameMs then cur.maxFrameMs = d end
        end
    end
    if cur.secs >= P.WINDOW then roll() end
end

-- Detail level: "auto" (default) reduces optional detail when SideStreet's own Lua time stays
-- above the budget for a few seconds, and restores it when it falls well below; "normal" and
-- "reduced" pin it. Reduced detail: captions capped at 4, panels refresh twice a second instead of
-- five times, and the renderer/effects may read SS.Perf.quality to drop optional effects.
function P.Mode()
    local m = SS.UI and SS.UI.Pref and SS.UI.Pref("detail") or "auto"
    return m
end

function P.UpdateQuality()
    local mode = P.Mode()
    local want = P.quality
    local backToAuto = mode == "auto" and P.lastMode ~= nil and P.lastMode ~= "auto"
    P.lastMode = mode
    if mode == "normal" or mode == "reduced" then
        want = mode
    elseif backToAuto then
        want, P.slow, P.fast = "normal", 0, 0   -- switching back to automatic starts from full detail
    else
        local last = P.last
        local avg = last.frames > 0 and last.frameMs / last.frames or 0
        if avg > P.BUDGET_MS then P.slow, P.fast = P.slow + 1, 0
        elseif avg < P.RECOVER_MS then P.fast, P.slow = P.fast + 1, 0
        else P.slow, P.fast = 0, 0 end
        if P.quality == "normal" and P.slow >= P.SLOW_WINDOWS then want = "reduced" end
        if P.quality == "reduced" and P.fast >= P.FAST_WINDOWS then want = "normal" end
    end
    if want ~= P.quality then
        P.quality = want
        P.qualityChanges = (P.qualityChanges or 0) + 1
        if SS.Emit then SS.Emit("perfQuality", want) end
    end
end

function P.Reset()
    P.cur, P.last, P.total = newAcc(), newAcc(), newAcc()
    P.slow, P.fast, P.windows = 0, 0, 0
end

-- Wrap a function with timing. Keeps every return value; creates no tables per call.
local function wrap(tbl, key, name)
    if type(tbl) ~= "table" then return false end
    local orig = tbl[key]
    if type(orig) ~= "function" then return false end
    for _, w in ipairs(P.wrapped) do if w.tbl == tbl and w.key == key and tbl[key] == w.fn then return true end end
    local function finish(t0, ...)
        P.End(name, t0)
        return ...
    end
    local f = function(...)
        local t0 = P.enabled and clock() or nil
        return finish(t0, orig(...))
    end
    tbl[key] = f
    P.wrapped[#P.wrapped + 1] = { tbl = tbl, key = key, fn = f, orig = orig, name = name }
    return true
end

-- Instrument the subsystems once every file has loaded (ADDON_LOADED). Idempotent. Calls made
-- through a function reference captured before this ran are not timed (the report says when a
-- subsystem was never seen).
function P.Install()
    wrap(SS.Sim, "Update", "sim")
    wrap(SS.Actions, "Think", "autonomy")
    wrap(SS.Nav, "FindPath", "path")
    wrap(SS.Render, "Layout", "layout")
    wrap(SS.Render, "UpdateActors", "actors")
    P.installed = true
end

-- Sprites under the lot canvas: allocated textures and the visible ones. Walks the canvas once
-- (called by the report and the overlay, at most once a second).
function P.SpriteCounts()
    local R = SS.Render
    if R and type(R.stats) == "table" and R.stats.allocated then
        return R.stats.visible or 0, R.stats.allocated or 0
    end
    local canvas = R and R.canvas
    if not canvas or not canvas.GetChildren then return nil end
    local vis, alloc = 0, 0
    local function regions(f)
        if not f.GetRegions then return end
        local list = { f:GetRegions() }
        for n = 1, #list do
            local r = list[n]
            if r.GetObjectType and r:GetObjectType() == "Texture" then
                alloc = alloc + 1
                if r:IsShown() and f:IsShown() then vis = vis + 1 end
            end
        end
    end
    local function walk(f, depth)
        regions(f)
        if depth > 3 or not f.GetChildren then return end
        local kids = { f:GetChildren() }
        for n = 1, #kids do walk(kids[n], depth + 1) end
    end
    walk(canvas, 0)
    return vis, alloc
end

local function fmtSub(acc, s, perSec)
    local ms = acc.ms[s] or 0
    local calls = acc.calls[s] or 0
    if perSec and acc.secs > 0 then ms = ms / acc.secs end
    return ms, calls
end

-- Numbers as a table (tests and the overlay read this).
function P.Snapshot()
    local last, total = P.last, P.total
    local snap = { subs = {}, window = last.secs, frames = last.frames, quality = P.quality, mode = P.Mode(),
        installed = P.installed and true or false }
    snap.updateRate = last.secs > 0 and last.frames / last.secs or 0
    snap.frameMs = last.frames > 0 and last.frameMs / last.frames or 0
    snap.maxFrameMs = last.maxFrameMs
    for _, s in ipairs(P.SUBS) do
        local ms, calls = fmtSub(last, s, true)
        snap.subs[s] = { msPerSec = ms, calls = calls, max = last.maxMs[s] or 0, totalMs = total.ms[s] or 0, totalCalls = total.calls[s] or 0 }
    end
    snap.totalFrames = total.frames
    if fn("GetFramerate") then
        local ok, fps = pcall(GetFramerate)
        snap.fps = ok and type(fps) == "number" and fps or nil
    end
    local nav = SS.Nav and SS.Nav.stats
    snap.navSearches = nav and nav.searches or nil
    snap.navExpanded = nav and nav.expanded or nil
    snap.navLast = P.navLast
    local w = SS.Sim and SS.Sim.world
    if w then
        local actors, members, objects, levels = 0, 0, 0, {}
        for _, a in pairs(w.actors) do
            actors = actors + 1
            if w.household and a.householdId == w.household.id and not a.role then members = members + 1 end
        end
        for _, o in pairs(w.lot.objects) do objects = objects + 1; levels[o.level or 0] = true end
        local nl = 0
        for _ in pairs(levels) do nl = nl + 1 end
        snap.actors, snap.members, snap.objects, snap.levels = actors, members, objects, nl
        snap.steps = SS.Sim.perf and SS.Sim.perf.steps or 0
    end
    snap.visibleSprites, snap.allocatedSprites = P.SpriteCounts()
    snap.captions = SS.UI and SS.UI.captionsShown or 0
    snap.captionCap = SS.UI and SS.UI.CaptionCap and SS.UI.CaptionCap() or 0
    return snap
end

-- Benchmark environment (brief §22): client build, viewport, quality, what is on the lot, method.
function P.EnvironmentLine(s)
    local caps = C.caps or {}
    local vw, vh = nil, nil
    local vp = SS.UI and SS.UI.viewport
    if vp and vp.GetWidth then vw, vh = vp:GetWidth(), vp:GetHeight() end
    local cam = SS.Render and SS.Render.cam
    return string.format("Environment: client %s (build %s, interface %s); SideStreet %s; viewport %s at zoom %s; detail %s; %s people and %s objects on the lot; method: debugprofilestop around each call, %d-second windows.",
        tostring(caps.version or "unknown"), tostring(caps.build or "?"), tostring(caps.interface or "?"), tostring(SS.VERSION),
        vw and string.format("%dx%d", vw, vh or 0) or "not shown", tostring(cam and cam.zoom or "?"), tostring(s.quality),
        tostring(s.actors or 0), tostring(s.objects or 0), P.WINDOW)
end

function P.Report(withMemory)
    local s = P.Snapshot()
    local lines = {}
    lines[#lines + 1] = "Performance, measured with debugprofilestop inside this client (numbers from the offline test harness are not in-game results):"
    lines[#lines + 1] = P.EnvironmentLine(s)
    lines[#lines + 1] = s.fps and string.format("Client framerate: %.1f fps, exactly as GetFramerate reports it.", s.fps)
        or "Client framerate: not available (GetFramerate missing); SideStreet does not estimate one."
    if s.frames > 0 then
        lines[#lines + 1] = string.format("SideStreet updates: %.1f per second; its Lua time %.2f ms per update on average, %.2f ms at most (last %.1f s).",
            s.updateRate, s.frameMs, s.maxFrameMs, s.window)
    else
        lines[#lines + 1] = "SideStreet updates: none measured yet (the window has not been open for a full second)."
    end
    local parts = {}
    for _, name in ipairs(P.SUBS) do
        local e = s.subs[name]
        parts[#parts + 1] = string.format("%s %.2f ms/s (%d calls, max %.2f ms)", P.LABEL[name], e.msPerSec, e.calls, e.max)
    end
    lines[#lines + 1] = "Lua time by subsystem: " .. table.concat(parts, "; ") .. ". Autonomy and pathfinding are part of the sim step."
    local never = {}
    for _, name in ipairs(P.SUBS) do if s.subs[name].totalCalls == 0 then never[#never + 1] = P.LABEL[name] end end
    if #never > 0 then lines[#lines + 1] = "Not seen yet: " .. table.concat(never, ", ") .. " (no calls measured since the last reset)." end
    lines[#lines + 1] = string.format("Detail level: %s (%s; optional detail drops above %.1f ms per update and returns below %.1f ms). Reduced detail: at most %d captions, moving sprites updated %d times a second, panels refreshed twice a second; the simulation itself is never thinned.",
        s.quality, s.mode == "auto" and "automatic" or ("set to " .. s.mode .. " in Options"), P.BUDGET_MS, P.RECOVER_MS, P.CAPACITY.reducedCaptions, P.CAPACITY.actorFps)
    local cap = P.Capacity()
    lines[#lines + 1] = string.format("Declared capacity: up to %d people in a household, %d party guests, %d people on a community lot; %d captions; sound caps %s effects, %s voices, %s loops.",
        cap.household, cap.guests, cap.venueCrowd, cap.captions, tostring(cap.oneshots or "?"), tostring(cap.voices or "?"), tostring(cap.loops or "?"))
    if s.navSearches then
        lines[#lines + 1] = string.format("Pathfinding workload: %d searches, %d nodes expanded in total; %s searches in the last window.",
            s.navSearches, s.navExpanded or 0, s.navLast and tostring(s.navLast) or "?")
    end
    if s.actors then
        lines[#lines + 1] = string.format("World: %d people on the lot (%d household), %d objects on %d floor(s), %d sim steps so far.",
            s.actors, s.members, s.objects, s.levels, s.steps)
    end
    if s.visibleSprites then
        lines[#lines + 1] = string.format("Sprites: %d visible, %d allocated (textures under the lot canvas; UI changes are not GPU draw calls). Captions %d of %d.",
            s.visibleSprites, s.allocatedSprites, s.captions or 0, s.captionCap or 0)
    else
        lines[#lines + 1] = "Sprites: the lot has not been drawn yet."
    end
    if withMemory ~= false then
        local kb = C.MemoryKB()
        lines[#lines + 1] = kb and string.format("Lua memory accounted to SideStreet: %.0f KB. This is the Lua heap only: textures, sounds, frames and the client's own memory are not included.", kb)
            or "Lua memory: not available in this client."
    end
    return lines, s
end
