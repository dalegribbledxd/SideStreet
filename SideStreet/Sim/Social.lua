-- Relationships: directional daily/life scores, romance, rivalry, family, household, history.
-- Owner: social module. Saved in root.social (plain data):
--   rel["a>b"] = a's feelings toward b:
--     { daily = -100..100 (short-term rapport), life = -100..100 (long-term relationship),
--       romance = 0..100 (a's attraction to b), rivalry = 0..100 (a's competitive grudge),
--       flags = { family = kind (a's role toward b), partner, married, met, ex, deceased,   -- explicit
--                 friend, best, crush, love, rival, enemy, household },                  -- derived
--       last = { { t, id, ok, me, d, l }, ... } (bounded history, newest last),
--       conflict = { t, reason } | nil,
--       noted = { flag = true } | nil (notable flags already journalled for this pair) }
--   cool["a>b:key"] = untilT   (rejection cooldowns; survive save/load, never retried continuously)
--   upset[rid] = { untilT, reason, by }   (someone is hurt/grieving; comforting is possible)
-- One-sided feelings are normal: "a>b" and "b>a" are separate records.
local _, SS = ...
local U = SS.U
local So = { HISTORY = 12, MAX_PER_OWNER = 64 }
SS.Social = So

-- Thresholds and daily drift (tuning knobs, see docs/modules/social.md).
So.T = {
    friend = 40, best = 75, bestDaily = 45, enemy = -50,
    crush = 25, love = 60, loveLife = 35, rival = 40,
    decayToLife = 0.3,   -- each day, daily moves this fraction of the way toward life
    lifeDrift = 0.06,    -- each day, life moves this fraction toward the day's rapport
    romanceDecay = 2,    -- romance lost per day without romantic contact (non-partners)
    rivalryDecay = 3,
    conflictDays = 3,    -- a conflict can be apologised for within this many days
}

-- Family kinds: a's role toward b, and the inverse for b toward a.
So.INVERSE = {
    parent = "child", child = "parent", sibling = "sibling", spouse = "spouse", guardian = "ward", ward = "guardian",
    grandparent = "grandchild", grandchild = "grandparent", aunt_uncle = "niece_nephew", niece_nephew = "aunt_uncle",
    cousin = "cousin", step_parent = "step_child", step_child = "step_parent", in_law = "in_law", roommate = "roommate",
}
-- Close family and guardian ties exclude romance.
So.CLOSE = {
    parent = true, child = true, sibling = true, guardian = true, ward = true, grandparent = true, grandchild = true,
    aunt_uncle = true, niece_nephew = true, cousin = true, step_parent = true, step_child = true,
}
-- How b appears to a when a>b.flags.family == kind ("Bea is Roz's daughter" when Roz is the parent).
So.FAMILY_LABEL = {
    parent = "Child", child = "Parent", sibling = "Sibling", spouse = "Spouse", guardian = "Ward", ward = "Guardian",
    grandparent = "Grandchild", grandchild = "Grandparent", aunt_uncle = "Niece/Nephew", niece_nephew = "Aunt/Uncle",
    cousin = "Cousin", step_parent = "Stepchild", step_child = "Step-parent", in_law = "In-law", roommate = "Roommate",
}
local EXPLICIT = { family = true, partner = true, married = true, met = true, ex = true, deceased = true }

function So.Data(world)
    local root = world.root or world
    local s = root.social
    if type(s) ~= "table" then s = {}; root.social = s end
    s.rel = s.rel or {}
    s.cool = s.cool or {}
    s.upset = s.upset or {}
    return s, root
end

local function key(a, b) return a .. ">" .. b end
So.Key = key

-- Runtime indexes over the saved tables (never saved; keyed weakly by the table they index, so a
-- loaded or replaced save simply builds fresh ones). They let the autonomy scan answer "who does
-- a have feelings about", "is a partnered elsewhere" and "is there any cooldown between a and b"
-- without walking every record or building throwaway strings.
local IDX = setmetatable({}, { __mode = "k" })
local function relIndex(s)
    local ix = IDX[s.rel]
    if not ix then
        ix = { out = {}, partners = {} }
        for k, r in pairs(s.rel) do
            local a, b = k:match("^(.-)>(.*)$")
            if a then
                ix.out[a] = ix.out[a] or {}
                ix.out[a][b] = r
            end
        end
        IDX[s.rel] = ix
    end
    return ix
end
local function coolIndex(s)
    local ix = IDX[s.cool]
    if not ix then
        ix = {}
        for k, t in pairs(s.cool) do
            local a, b = k:match("^(.-)>(.-):")
            if a and type(t) == "number" then
                ix[a] = ix[a] or {}
                if not ix[a][b] or ix[a][b] < t then ix[a][b] = t end
            end
        end
        IDX[s.cool] = ix
    end
    return ix
end
function So.InvalidateIndexes(world)
    local root = world and (world.root or world)
    local s = root and root.social
    if type(s) == "table" then
        if s.rel then IDX[s.rel] = nil end
        if s.cool then IDX[s.cool] = nil end
    end
end

local function newRec() return { daily = 0, life = 0, romance = 0, rivalry = 0, flags = {}, last = {} } end

-- Directional record from a toward b (created on demand). Kept compatible with the stub.
function So.Rel(world, aId, bId)
    local s = So.Data(world)
    local k = key(aId, bId)
    local r = s.rel[k]
    if not r then
        r = newRec(); s.rel[k] = r
        local ix = IDX[s.rel]
        if ix then ix.out[aId] = ix.out[aId] or {}; ix.out[aId][bId] = r end
    else
        r.romance, r.rivalry = r.romance or 0, r.rivalry or 0
        r.flags, r.last = r.flags or {}, r.last or {}
    end
    return r
end

-- Read-only lookup (nil if the pair never met).
function So.Get(world, aId, bId)
    local root = world.root or world
    return root.social and root.social.rel and root.social.rel[key(aId, bId)]
end
-- Read without creating (family's and visitors' scans): the same as So.Get.
So.Peek = So.Get
-- The events module's director starts an argument (see SS.Conversation.StartConflict).
function So.StartConflict(world, a, b, source)
    local C = SS.Conversation
    if not (C and C.StartConflict) then return false end
    return C.StartConflict(world, a, b, source) and true or false
end

local function person(world, id)
    local root = world.root or world
    return root.residents and root.residents[id]
end

function So.SameHousehold(world, aId, bId)
    local a, b = person(world, aId), person(world, bId)
    return a and b and a.householdId ~= nil and a.householdId == b.householdId or false
end

local function isActiveOwner(world, aId)
    if world.actors and world.actors[aId] then return true end
    local hh = world.household
    if hh and hh.members then for _, m in ipairs(hh.members) do if m == aId then return true end end end
    return false
end

local function journal(world, text)
    if SS.Actions and SS.Actions.Journal and world.household then
        pcall(SS.Actions.Journal, world, text)
    end
end

local function nameOf(world, id)
    local p = person(world, id)
    return p and p.name or id
end
So.NameOf = nameOf

local function firstName(world, id)
    local n = nameOf(world, id)
    return (n:match("^(%S+)")) or n
end
So.FirstName = firstName

local NOTABLE = {
    friend = "%s now counts %s as a friend.", best = "%s thinks of %s as a best friend.",
    love = "%s has fallen for %s.", enemy = "%s can't stand %s any more.", rival = "%s sees %s as a rival.",
}

-- Recompute derived flags; emit "relFlag" (world, a, b, flag, value) for every change and
-- journal notable ones for the household being played.
-- Flags have hysteresis so a score hovering at a threshold does not flap: a flag is gained at its
-- threshold and only lost once the score falls a margin past it (So.T.keep). A notable flag is
-- journalled once per pair (r.noted remembers which were announced), not every time it returns.
local FLAGS = { "enemy", "rival", "crush", "household", "friend", "best", "love" }
local newFlags = {}
So.T.keep = { friend = 5, enemy = 5, rival = 10, crush = 5, love = 5, bestLife = 10, bestDaily = 15 }
function So.Refresh(world, aId, bId, r)
    r = r or So.Get(world, aId, bId)
    if not r then return end
    local T, K, f = So.T, So.T.keep, r.flags
    local a, b = person(world, aId), person(world, bId)
    local adults = a and b and a.age == "adult" and b.age == "adult"
    local romance, rivalry = r.romance or 0, r.rivalry or 0
    local new = newFlags
    new.enemy = (r.life <= T.enemy or (f.enemy and r.life <= T.enemy + K.enemy)) or nil
    new.rival = (rivalry >= T.rival or (f.rival and rivalry >= T.rival - K.rival)) or nil
    new.crush = adults and (romance >= T.crush or (f.crush and romance >= T.crush - K.crush)) or nil
    new.household = So.SameHousehold(world, aId, bId) or nil
    new.friend = (not new.enemy and (r.life >= T.friend or (f.friend and r.life >= T.friend - K.friend))) or nil
    new.best = (new.friend and ((r.life >= T.best and r.daily >= T.bestDaily)
        or (f.best and r.life >= T.best - K.bestLife and r.daily >= T.bestDaily - K.bestDaily))) or nil
    new.love = adults and ((romance >= T.love and r.life >= T.loveLife)
        or (f.love and romance >= T.love - K.love and r.life >= T.loveLife - K.love)) or nil
    for i = 1, #FLAGS do
        local flag = FLAGS[i]
        local v = new[flag] or nil
        if (f[flag] or nil) ~= v then
            f[flag] = v
            SS.Emit("relFlag", world, aId, bId, flag, v or false)
            if v and NOTABLE[flag] and not (r.noted and r.noted[flag]) and isActiveOwner(world, aId) then
                r.noted = r.noted or {}
                r.noted[flag] = true
                journal(world, string.format(NOTABLE[flag], firstName(world, aId), firstName(world, bId)))
            end
        end
    end
    return r
end

-- Change a's feelings toward b: d = { daily, life, romance, rivalry } (any subset).
function So.Adjust(world, aId, bId, d)
    local r = So.Rel(world, aId, bId)
    if d.daily then r.daily = U.clamp(r.daily + d.daily, -100, 100) end
    if d.life then r.life = U.clamp(r.life + d.life, -100, 100) end
    if d.romance then r.romance = U.clamp((r.romance or 0) + d.romance, 0, 100) end
    if d.rivalry then r.rivalry = U.clamp((r.rivalry or 0) + d.rivalry, 0, 100) end
    So.Refresh(world, aId, bId, r)
    return r
end

-- Stub-compatible: change daily and life of a toward b.
function So.Change(world, aId, bId, daily, life)
    return So.Adjust(world, aId, bId, { daily = daily or 0, life = life or 0 })
end

-- Family tie (both directions). kind is a's role toward b: "parent", "child", "sibling",
-- "spouse", "guardian", "ward", "grandparent", "aunt_uncle", "cousin", "roommate", ...
-- "spouse" also marks the pair married and partnered (family's commitment ceremony).
function So.SetFamily(world, aId, bId, kind)
    local ra, rb = So.Rel(world, aId, bId), So.Rel(world, bId, aId)
    ra.flags.family = kind
    rb.flags.family = So.INVERSE[kind] or kind
    ra.flags.met, rb.flags.met = true, true
    if kind == "spouse" then
        ra.flags.married, rb.flags.married = true, true
        ra.flags.partner, rb.flags.partner = true, true
        ra.flags.ex, rb.flags.ex = nil, nil
    end
    SS.Emit("relFlag", world, aId, bId, "family", kind)
    SS.Emit("relFlag", world, bId, aId, "family", rb.flags.family)
    So.Refresh(world, aId, bId, ra); So.Refresh(world, bId, aId, rb)
end

function So.ClearFamily(world, aId, bId)
    local ra, rb = So.Get(world, aId, bId), So.Get(world, bId, aId)
    if ra then ra.flags.family = nil; ra.flags.married = nil end
    if rb then rb.flags.family = nil; rb.flags.married = nil end
end

-- Steady partners (both directions). on=false ends it and marks them exes.
function So.SetPartner(world, aId, bId, on)
    local ra, rb = So.Rel(world, aId, bId), So.Rel(world, bId, aId)
    if on then
        ra.flags.partner, rb.flags.partner = true, true
        ra.flags.ex, rb.flags.ex = nil, nil
        journal(world, firstName(world, aId) .. " and " .. firstName(world, bId) .. " are going steady.")
    else
        local was = ra.flags.partner
        ra.flags.partner, rb.flags.partner = nil, nil
        ra.flags.married, rb.flags.married = nil, nil
        if ra.flags.family == "spouse" then ra.flags.family = nil end
        if rb.flags.family == "spouse" then rb.flags.family = nil end
        if was then
            ra.flags.ex, rb.flags.ex = true, true
            journal(world, firstName(world, aId) .. " and " .. firstName(world, bId) .. " broke up.")
        end
    end
    SS.Emit("relFlag", world, aId, bId, "partner", on and true or false)
    SS.Emit("relFlag", world, bId, aId, "partner", on and true or false)
end

function So.IsPartner(world, aId, bId)
    local r = So.Get(world, aId, bId)
    return r and (r.flags.partner or r.flags.married or r.flags.family == "spouse") and true or false
end

-- a's records by the other person's id (read-only view of a runtime index; do not modify).
local NONE = {}
function So.Out(world, aId)
    local ix = relIndex(So.Data(world))
    return ix.out[aId] or NONE
end

local function partnered(r) return r.flags.partner or r.flags.married or r.flags.family == "spouse" end

-- Everyone a has a partner/spouse tie with (sorted ids).
function So.Partners(world, aId)
    local out = {}
    for bId, r in pairs(So.Out(world, aId)) do
        if partnered(r) then out[#out + 1] = bId end
    end
    table.sort(out)
    return out
end

-- Is a partnered with anyone other than exceptId? (No allocation: used by the autonomy scan.)
function So.HasOtherPartner(world, aId, exceptId)
    for bId, r in pairs(So.Out(world, aId)) do
        if bId ~= exceptId and partnered(r) then return true end
    end
    return false
end

-- Family kind between a and b in either direction (a's role toward b), or nil.
function So.FamilyKind(world, aId, bId)
    local r = So.Get(world, aId, bId)
    if r and r.flags.family then return r.flags.family end
    local q = So.Get(world, bId, aId)
    if q and q.flags.family then return So.INVERSE[q.flags.family] or q.flags.family end
    return nil
end

function So.IsCloseFamily(world, aId, bId)
    local k = So.FamilyKind(world, aId, bId)
    return k and So.CLOSE[k] or false
end

-- Romance rules as a plain yes/no (no reason text is built).
function So.RomanceAllowed(world, aId, bId)
    local a, b = person(world, aId), person(world, bId)
    if not a or not b or aId == bId then return false end
    if (a.kind and a.kind ~= "human") or (b.kind and b.kind ~= "human") then return false end
    if a.age ~= "adult" or b.age ~= "adult" or a.dead or b.dead then return false end
    local k = So.FamilyKind(world, aId, bId)
    return not (k and So.CLOSE[k])
end

-- Romance rules: adults only, humans only, both alive, no close family or guardian ties.
-- No gender or pronoun restriction.
function So.CanRomance(world, aId, bId)
    local a, b = person(world, aId), person(world, bId)
    if not a or not b or aId == bId then return false, "Nobody to romance." end
    if (a.kind and a.kind ~= "human") or (b.kind and b.kind ~= "human") then return false, "Romance is for people." end
    if a.age ~= "adult" or b.age ~= "adult" then return false, "Romance is for adults only." end
    if a.dead or b.dead then return false, "They have passed away." end
    local k = So.FamilyKind(world, aId, bId)
    if k and So.CLOSE[k] then return false, "They are family (" .. (So.FAMILY_LABEL[k] or k):lower() .. ")." end
    return true
end

-- a's friends (directional: a counts b as a friend); mutual=true requires both directions.
function So.Friends(world, aId, mutual)
    local out = {}
    local s = So.Data(world)
    for b, r in pairs(So.Out(world, aId)) do
        if r.flags.friend then
            local back = s.rel[key(b, aId)]
            local p = person(world, b)
            if p and not p.dead and (not mutual or (back and back.flags.friend)) then out[#out + 1] = b end
        end
    end
    table.sort(out)
    return out
end
function So.CountFriends(world, aId, mutual) return #So.Friends(world, aId, mutual) end

-- Everyone a has a record with (sorted by life, then id).
function So.Known(world, aId)
    local out = {}
    local mine = So.Out(world, aId)
    for b in pairs(mine) do out[#out + 1] = b end
    table.sort(out, function(x, y)
        local rx, ry = mine[x], mine[y]
        if rx.life ~= ry.life then return rx.life > ry.life end
        return x < y
    end)
    return out
end

-- History ------------------------------------------------------------------
-- Record an interaction on both directions: a did `id` to b (ok = accepted/succeeded).
function So.Record(world, aId, bId, id, ok, dA, lA, dB, lB)
    local t = world.time or 0
    local ra, rb = So.Rel(world, aId, bId), So.Rel(world, bId, aId)
    local ea = { t = t, id = id, ok = ok and true or false, me = true, d = U.round((dA or 0) * 10) / 10, l = U.round((lA or 0) * 10) / 10 }
    local eb = { t = t, id = id, ok = ok and true or false, me = false, d = U.round((dB or 0) * 10) / 10, l = U.round((lB or 0) * 10) / 10 }
    ra.last[#ra.last + 1] = ea
    rb.last[#rb.last + 1] = eb
    while #ra.last > So.HISTORY do table.remove(ra.last, 1) end
    while #rb.last > So.HISTORY do table.remove(rb.last, 1) end
    ra.flags.met, rb.flags.met = true, true
end

-- Count recent history entries on a>b: opts = { id, window (minutes), me = bool, ok = bool, cat }.
function So.Recent(world, aId, bId, opts)
    local r = So.Get(world, aId, bId)
    if not r then return 0 end
    local now = world.time or 0
    local from = now - (opts.window or 1440)
    local n = 0
    for i = #r.last, 1, -1 do
        local e = r.last[i]
        if e.t < from then break end
        if (opts.id == nil or e.id == opts.id) and (opts.me == nil or e.me == opts.me) and (opts.ok == nil or e.ok == opts.ok)
            and (opts.cat == nil or (SS.Socials and SS.Socials.byId[e.id] and SS.Socials.byId[e.id].cat == opts.cat)) then
            n = n + 1
        end
    end
    return n
end

-- Same as So.Recent with positional filters and no table to build (the autonomy scan's version):
-- id (nil = any), window minutes, me (nil = either), ok (nil = either).
function So.Count(world, aId, bId, id, window, me, ok)
    local r = So.Get(world, aId, bId)
    if not r then return 0 end
    local from = (world.time or 0) - (window or 1440)
    local n, last = 0, r.last
    for i = #last, 1, -1 do
        local e = last[i]
        if e.t < from then break end
        if (id == nil or e.id == id) and (me == nil or e.me == me) and (ok == nil or e.ok == ok) then n = n + 1 end
    end
    return n
end

-- Newest history entry of a>b with positional filters (no allocation).
function So.Last(world, aId, bId, id, me, ok)
    local r = So.Get(world, aId, bId)
    if not r then return nil end
    for i = #r.last, 1, -1 do
        local e = r.last[i]
        if (id == nil or e.id == id) and (me == nil or e.me == me) and (ok == nil or e.ok == ok) then return e end
    end
end

-- Last history entry of a>b matching a predicate-ish filter (newest first).
function So.LastEntry(world, aId, bId, opts)
    local r = So.Get(world, aId, bId)
    if not r then return nil end
    for i = #r.last, 1, -1 do
        local e = r.last[i]
        if (opts.id == nil or e.id == opts.id) and (opts.me == nil or e.me == opts.me) and (opts.ok == nil or e.ok == opts.ok) then return e end
    end
end

-- Conflict and reconciliation ------------------------------------------------
function So.MarkConflict(world, aId, bId, reason)
    local t = world.time or 0
    local ra, rb = So.Rel(world, aId, bId), So.Rel(world, bId, aId)
    -- another quarrel while one is still open is the same incident: it keeps that incident's
    -- record id (conflict.ev), so the apology still settles the record
    local ev = (ra.conflict and ra.conflict.ev) or (rb.conflict and rb.conflict.ev)
    ra.conflict = { t = t, reason = reason, ev = ev }
    rb.conflict = { t = t, reason = reason, ev = ev }
end

-- Recent unresolved conflict between a and b (either record), or nil.
function So.Conflict(world, aId, bId)
    local r = So.Get(world, aId, bId)
    local c = r and r.conflict
    if c and (world.time or 0) - c.t <= So.T.conflictDays * 1440 then return c end
    return nil
end

function So.Reconcile(world, aId, bId)
    local ra, rb = So.Get(world, aId, bId), So.Get(world, bId, aId)
    local had = (ra and ra.conflict) or (rb and rb.conflict)
    if ra then ra.conflict = nil end
    if rb then rb.conflict = nil end
    if had then
        journal(world, firstName(world, aId) .. " and " .. firstName(world, bId) .. " made up.")
        SS.Emit("reconciled", world, aId, bId)
    end
    return had and true or false
end

-- Upset (hurt feelings, grief) ----------------------------------------------------
function So.SetUpset(world, rid, minutes, reason, byId)
    local s = So.Data(world)
    local t = (world.time or 0) + minutes
    local cur = s.upset[rid]
    if not cur or cur.untilT < t then s.upset[rid] = { untilT = t, reason = reason, by = byId } end
end
function So.Upset(world, rid)
    local s = So.Data(world)
    local u = s.upset[rid]
    if u and u.untilT > (world.time or 0) then return u end
    return nil
end
function So.ClearUpset(world, rid) So.Data(world).upset[rid] = nil end

-- Cooldowns (rejections, repeated attempts) ------------------------------------------
function So.SetCooldown(world, aId, bId, k, minutes)
    local s = So.Data(world)
    local t = (world.time or 0) + minutes
    s.cool[key(aId, bId) .. ":" .. k] = t
    local ix = coolIndex(s)
    ix[aId] = ix[aId] or {}
    if not ix[aId][bId] or ix[aId][bId] < t then ix[aId][bId] = t end
end
-- Does any cooldown from a toward b still run? (No string is built.)
function So.AnyCooldown(world, aId, bId)
    local ix = coolIndex(So.Data(world))
    local ia = ix[aId]
    local t = ia and ia[bId]
    return t ~= nil and t > (world.time or 0)
end
function So.Cooldown(world, aId, bId, k)
    local s = So.Data(world)
    if not So.AnyCooldown(world, aId, bId) then return nil end
    local t = s.cool[key(aId, bId) .. ":" .. k]
    if t and t > (world.time or 0) then return t end
    return nil
end

-- Clock guard ------------------------------------------------------------------------
-- world.time can move backwards: coming home from an outing resumes the home clock where it
-- stopped (outings' time policy), while cooldowns, history and conflicts written at the venue
-- were stamped on the outing clock. When the clock is seen to go back by R minutes, every social
-- timestamp moves back by R too, so ages and remaining cooldowns stay exactly as the people lived
-- them (a cooldown set at the venue expires on schedule at home, and one set at home before
-- leaving has aged by the length of the outing). Checked on attach and on every social tick.
-- dt: the step about to run (the clock reads t + dt once it is over), so a rewind right after
-- this step is measured from exactly where the clock stopped.
function So.ClockCheck(world, dt)
    local s = So.Data(world)
    local t = world.time or 0
    local last = s.clock
    if type(last) == "number" and t < last - 1e-6 then So.ShiftTimes(world, t - last) end
    s.clock = t + (dt or 0)
end

function So.ShiftTimes(world, delta)
    local s = So.Data(world)
    for _, r in pairs(s.rel) do
        for _, e in ipairs(r.last or {}) do if type(e.t) == "number" then e.t = e.t + delta end end
        if r.conflict and type(r.conflict.t) == "number" then r.conflict.t = r.conflict.t + delta end
    end
    for k, t in pairs(s.cool) do if type(t) == "number" then s.cool[k] = t + delta end end
    IDX[s.cool] = nil
    for _, u in pairs(s.upset) do if type(u) == "table" and type(u.untilT) == "number" then u.untilT = u.untilT + delta end end
    for _, inv in ipairs(s.invites or {}) do
        if type(inv.t) == "number" then inv.t = inv.t + delta end
        if type(inv.at) == "number" then inv.at = inv.at + delta end
        if type(inv.next) == "number" then inv.next = inv.next + delta end
    end
    local ln = s.lines
    for _, m in pairs(ln and ln.mem or {}) do
        if type(m.at) == "table" then for id, t in pairs(m.at) do if type(t) == "number" then m.at[id] = t + delta end end end
    end
    SS.Emit("socialClockShift", world, delta)
end

-- Daily drift -----------------------------------------------------------------------
-- Daily scores decay toward life; life follows sustained rapport slowly; romance fades without
-- contact; grudges cool. Only records owned by people being played (on this lot or in this
-- household) change: inactive households stay paused.
function So.DayTick(world)
    local s = So.Data(world)
    local T = So.T
    local now = world.time or 0
    local keys = {}
    for k in pairs(s.rel) do keys[#keys + 1] = k end
    table.sort(keys)
    local perOwner = {}
    for _, k in ipairs(keys) do
        local r = s.rel[k]
        local aId, bId = k:match("^(.-)>(.*)$")
        perOwner[aId] = (perOwner[aId] or 0) + 1
        if aId and isActiveOwner(world, aId) then
            local oldDaily = r.daily
            r.life = U.clamp(r.life + (oldDaily - r.life) * T.lifeDrift, -100, 100)
            r.daily = U.clamp(oldDaily + (r.life - oldDaily) * T.decayToLife, -100, 100)
            local partnered = r.flags.partner or r.flags.married
            if not partnered and (r.romance or 0) > 0 then
                local recentRomance = 0
                for i = #r.last, 1, -1 do
                    local e = r.last[i]
                    if now - e.t > 2880 then break end
                    local sd = SS.Socials and SS.Socials.byId[e.id]
                    if sd and sd.kind == "romantic" then recentRomance = recentRomance + 1 end
                end
                if recentRomance == 0 then r.romance = math.max(0, r.romance - T.romanceDecay) end
            end
            if (r.rivalry or 0) > 0 then r.rivalry = math.max(0, r.rivalry - T.rivalryDecay) end
            if r.conflict and now - r.conflict.t > T.conflictDays * 1440 then r.conflict = nil end
            So.Refresh(world, aId, bId, r)
        end
    end
    -- prune empty records and expired cooldowns/upsets (bounded tables)
    for _, k in ipairs(keys) do
        local r = s.rel[k]
        local explicit = false
        for f in pairs(r.flags) do if EXPLICIT[f] and f ~= "met" then explicit = true end end
        if not explicit and math.abs(r.daily) < 1 and math.abs(r.life) < 1 and (r.romance or 0) < 1 and (r.rivalry or 0) < 1 and #r.last == 0 then
            s.rel[k] = nil
        end
    end
    for k, t in pairs(s.cool) do if t <= now then s.cool[k] = nil end end
    for k, u in pairs(s.upset) do if type(u) ~= "table" or u.untilT <= now then s.upset[k] = nil end end
    So.Trim(world)
    IDX[s.rel], IDX[s.cool] = nil, nil
end

-- Keep at most MAX_PER_OWNER records per person: drop the weakest non-family, non-partner ones.
function So.Trim(world)
    local s = So.Data(world)
    local by = {}
    for k, r in pairs(s.rel) do
        local aId = k:match("^(.-)>")
        by[aId] = by[aId] or {}
        by[aId][#by[aId] + 1] = k
    end
    for _, list in pairs(by) do
        if #list > So.MAX_PER_OWNER then
            table.sort(list, function(x, y)
                local rx, ry = s.rel[x], s.rel[y]
                -- keep family, partners, strong feelings and recent contact
                local wx = math.abs(rx.life) + math.abs(rx.daily) * 0.3 + (rx.romance or 0) + #rx.last * 2
                    + (rx.flags.family and 1000 or 0) + (rx.flags.partner and 1000 or 0)
                local wy = math.abs(ry.life) + math.abs(ry.daily) * 0.3 + (ry.romance or 0) + #ry.last * 2
                    + (ry.flags.family and 1000 or 0) + (ry.flags.partner and 1000 or 0)
                if wx ~= wy then return wx > wy end
                return x < y
            end)
            for n = So.MAX_PER_OWNER + 1, #list do s.rel[list[n]] = nil end
            IDX[s.rel] = nil
        end
    end
end

-- Refresh household flags for everyone on the lot (household membership can change in hood).
function So.RefreshHousehold(world)
    local s = So.Data(world)
    for k, r in pairs(s.rel) do
        local aId, bId = k:match("^(.-)>(.*)$")
        local same = So.SameHousehold(world, aId, bId) or nil
        if (r.flags.household or nil) ~= same then So.Refresh(world, aId, bId, r) end
    end
end

-- People who live together know each other. On attach and every day, each pair of living people
-- in the household being played gets a record both ways marked met (scores untouched), so the
-- Relationships tab lists housemates and a read-only scan (So.Peek, events' director) finds them.
-- Bounded: n members make n*(n-1) records, which are never trimmed (household flag). Returns the
-- number of pairs introduced.
function So.MeetHousehold(world)
    local root = world.root or world
    local hh = world.household
    if not (hh and type(hh.members) == "table" and root.residents) then return 0 end
    local list = {}
    for _, id in ipairs(hh.members) do
        local p = root.residents[id]
        if type(p) == "table" and not p.dead and (p.kind == nil or p.kind == "human") and p.householdId == hh.id then list[#list + 1] = id end
    end
    table.sort(list)
    local n = 0
    for i = 1, #list do
        for j = i + 1, #list do
            local a, b = list[i], list[j]
            local ra, rb = So.Get(world, a, b), So.Get(world, b, a)
            if not (ra and ra.flags.met and rb and rb.flags.met) then
                ra, rb = So.Rel(world, a, b), So.Rel(world, b, a)
                ra.flags.met, rb.flags.met = true, true
                So.Refresh(world, a, b, ra)
                So.Refresh(world, b, a, rb)
                n = n + 1
            end
        end
    end
    return n
end

-- Do a and b know each other? Met either way, or living in the same household (for callers that
-- must not create records, such as scans).
function So.Knows(world, aId, bId)
    local ra, rb = So.Get(world, aId, bId), So.Get(world, bId, aId)
    if (ra and ra.flags and ra.flags.met) or (rb and rb.flags and rb.flags.met) then return true end
    return So.SameHousehold(world, aId, bId) and true or false
end

-- One-line summary of a>b for tooltips: "Friend, crush | daily 34, life 51".
function So.FlagText(world, aId, bId)
    local r = So.Get(world, aId, bId)
    if not r then return "Strangers" end
    local f, out = r.flags, {}
    if f.family then out[#out + 1] = So.FAMILY_LABEL[f.family] or f.family end
    if f.married then out[#out + 1] = "Married"
    elseif f.partner then out[#out + 1] = "Partner" end
    if f.household then out[#out + 1] = "Household" end
    if f.best then out[#out + 1] = "Best friend" elseif f.friend then out[#out + 1] = "Friend" end
    if f.love then out[#out + 1] = "In love" elseif f.crush then out[#out + 1] = "Crush" end
    if f.enemy then out[#out + 1] = "Enemy" end
    if f.rival then out[#out + 1] = "Rival" end
    if f.ex then out[#out + 1] = "Ex" end
    if f.deceased then out[#out + 1] = "Deceased" end
    if #out == 0 then out[1] = f.met and "Acquaintance" or "Strangers" end
    return table.concat(out, ", ")
end

-- Death keeps the relationships and marks them (events module owns the death itself).
SS.On("death", function(world, actor, cause)
    if not world or not actor then return end
    local s = So.Data(world)
    local suffix = ">" .. actor.id
    for k, r in pairs(s.rel) do
        if k:sub(-#suffix) == suffix then
            r.flags.deceased = true
            local aId = k:sub(1, #k - #suffix)
            local p = person(world, aId)
            if p and not p.dead and (r.life >= 30 or r.flags.family or r.flags.partner) then
                So.SetUpset(world, aId, 2880, "grief", actor.id)
            end
        end
    end
end)

-- Save validator: repair types, clamp numbers, drop records about people who no longer exist,
-- keep history bounded.
if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        if root.social ~= nil and type(root.social) ~= "table" then root.social = nil; problems[#problems + 1] = "social data reset" end
        local s = root.social or {}
        root.social = s
        s.rel = type(s.rel) == "table" and s.rel or {}
        s.cool = type(s.cool) == "table" and s.cool or {}
        s.upset = type(s.upset) == "table" and s.upset or {}
        local res = root.residents or {}
        local dropped = 0
        for k, r in pairs(s.rel) do
            local aId, bId
            if type(k) == "string" then aId, bId = k:match("^(.-)>(.*)$") end
            if not aId or not res[aId] or not res[bId] or type(r) ~= "table" then
                s.rel[k] = nil; dropped = dropped + 1
            else
                r.daily = type(r.daily) == "number" and U.clamp(r.daily, -100, 100) or 0
                r.life = type(r.life) == "number" and U.clamp(r.life, -100, 100) or 0
                r.romance = type(r.romance) == "number" and U.clamp(r.romance, 0, 100) or 0
                r.rivalry = type(r.rivalry) == "number" and U.clamp(r.rivalry, 0, 100) or 0
                r.flags = type(r.flags) == "table" and r.flags or {}
                r.last = type(r.last) == "table" and r.last or {}
                for i = #r.last, 1, -1 do
                    local e = r.last[i]
                    if type(e) ~= "table" or type(e.t) ~= "number" or type(e.id) ~= "string" then table.remove(r.last, i) end
                end
                while #r.last > So.HISTORY do table.remove(r.last, 1) end
                if r.conflict ~= nil and (type(r.conflict) ~= "table" or type(r.conflict.t) ~= "number") then r.conflict = nil end
                if r.noted ~= nil then
                    if type(r.noted) ~= "table" then r.noted = nil
                    else for fk in pairs(r.noted) do if not NOTABLE[fk] then r.noted[fk] = nil end end end
                end
            end
        end
        if dropped > 0 then problems[#problems + 1] = "dropped " .. dropped .. " relationship records about missing people" end
        -- keepsakes: gifts held by people without a household (bounded, only for people who exist)
        if s.keepsakes ~= nil then
            if type(s.keepsakes) ~= "table" then s.keepsakes = nil
            else
                for rid, list in pairs(s.keepsakes) do
                    if type(list) ~= "table" or not res[rid] then s.keepsakes[rid] = nil
                    else
                        for i = #list, 1, -1 do if type(list[i]) ~= "table" then table.remove(list, i) end end
                        while #list > 12 do table.remove(list, 1) end
                        if #list == 0 then s.keepsakes[rid] = nil end
                    end
                end
            end
        end
        -- invitations waiting to be booked (bounded list of plain records)
        if s.invites ~= nil then
            if type(s.invites) ~= "table" then s.invites = nil
            else
                for i = #s.invites, 1, -1 do
                    local r = s.invites[i]
                    if type(r) ~= "table" or type(r.guest) ~= "string" or type(r.host) ~= "string" or type(r.t) ~= "number"
                        or type(r.at) ~= "number" or type(r.state) ~= "string" then
                        table.remove(s.invites, i)
                    elseif r.state == "pending" and (not res[r.guest] or not res[r.host]) then
                        r.state, r.why = "cancelled", "someone is no longer around"
                    end
                end
                while #s.invites > 20 do table.remove(s.invites, 1) end
            end
        end
        for k, t in pairs(s.cool) do if type(t) ~= "number" or type(k) ~= "string" then s.cool[k] = nil end end
        for k, u in pairs(s.upset) do if type(u) ~= "table" or type(u.untilT) ~= "number" or not res[k] then s.upset[k] = nil end end
        IDX[s.rel], IDX[s.cool] = nil, nil
    end)
end
