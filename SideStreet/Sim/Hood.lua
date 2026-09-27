-- SideStreet neighbourhood: builds Linden Hollow (10 residential + 4 community lots, premade
-- households, townies), validates the map, answers lot questions (status, appraisal, info),
-- switches the played household (per-household clocks keep inactive households paused), runs
-- the premade starter problems and keeps roster, ownership and relationships consistent.
-- Owner: hood module (docs/modules/hood.md). Household transactions live in Sim/Households.lua.
--
-- Saved data it adds (all plain tables):
--   root.hood.layout = { map = mapId, version, lots = { [lotId] = { x, y, w, h, rot, lw, lh } } }
--   root.hood.nextResident, root.hood.nextHousehold      -- stable id counters
--   household.clock      -- the household's own paused clock while another household is played
--   household.problem = { id, solved, solvedAt, progress, announced }
--   household.flags = { premade, jobsAssigned, ... }, household.tx = { bounded transaction log }
--   person.starterJob = { track, level } until the household is first played; person.townie = true
--   lot.name, lot.desc, lot.blueprint, lot.entry, lot.frontDoor, lot.mailbox, lot.spawn, lot.tier,
--   lot.placeholder (community lot built without the outings builder), lot.empty (bare parcel)
local _, SS = ...
local HD, HL, PM = SS.HoodData, SS.HoodLots, SS.Premades
local G, U = SS.Grid, SS.U
local H = SS.Hood or {}
SS.Hood = H

H.DEFAULT_LOT = "lot_juniper_4"
H.DEFAULT_HOUSEHOLD = "hh_kettering"

local function sortedKeys(t)
    local ks = {}
    for k in pairs(t or {}) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
    return ks
end
H.sortedKeys = sortedKeys

local function mapEntry(lotId)
    for _, e in ipairs(HD.map.lots) do if e.id == lotId then return e end end
end
H.MapEntry = mapEntry

---------------------------------------------------------------------------
-- Map geometry
---------------------------------------------------------------------------
function H.MapSize(w, h, rot) if (rot or 0) % 2 == 1 then return h, w end return w, h end

-- Placement of a lot (lw x lh) in its map slot: anchored to the street edge, centred along it.
function H.Place(e, lw, lh)
    local rot = (e.rot or 0) % 4
    local mw, mh = H.MapSize(lw, lh, rot)
    local sw, sh = e.slot and e.slot.w or mw, e.slot and e.slot.h or mh
    local x0, y0
    if rot == 0 then y0 = e.y + sh - mh; x0 = e.x + math.floor((sw - mw) / 2)
    elseif rot == 2 then y0 = e.y; x0 = e.x + math.floor((sw - mw) / 2)
    elseif rot == 3 then x0 = e.x + sw - mw; y0 = e.y + math.floor((sh - mh) / 2)
    else x0 = e.x; y0 = e.y + math.floor((sh - mh) / 2) end
    return { x = x0, y = y0, w = mw, h = mh, rot = rot, lw = lw, lh = lh }
end

-- Lot cell (i, j) -> map cell; works for cells just outside the lot too (the street row).
function H.LotToMap(pl, i, j)
    local u, v
    local r, W, Hh = pl.rot, pl.lw, pl.lh
    if r == 1 then u, v = Hh - 1 - j, i elseif r == 2 then u, v = W - 1 - i, Hh - 1 - j elseif r == 3 then u, v = j, W - 1 - i else u, v = i, j end
    return pl.x + u, pl.y + v
end

-- Map cell -> lot cell (or nil when outside the lot).
function H.MapToLot(pl, mx, my)
    local u, v = mx - pl.x, my - pl.y
    if u < 0 or v < 0 or u >= pl.w or v >= pl.h then return nil end
    local x, y = G.wpos(u + 0.5, v + 0.5, pl.rot, pl.lw, pl.lh)
    return math.floor(x), math.floor(y)
end

-- Continuous lot position -> continuous map position.
function H.LotPosToMap(pl, x, y)
    local u, v = G.vpos(x, y, pl.rot, pl.lw, pl.lh)
    return pl.x + u, pl.y + v
end

local function rectsTouch(a, b) -- inclusive cell rectangles overlap or share an edge
    return a.x0 <= b.x1 + 1 and b.x0 <= a.x1 + 1 and a.y0 <= b.y1 + 1 and b.y0 <= a.y1 + 1
        and not ((a.x0 == b.x1 + 1 or b.x0 == a.x1 + 1) and (a.y0 == b.y1 + 1 or b.y0 == a.y1 + 1))
end
local function rectsOverlap(a, b) return a.x0 <= b.x1 and b.x0 <= a.x1 and a.y0 <= b.y1 and b.y0 <= a.y1 end

function H.StreetAt(mx, my)
    for _, s in ipairs(HD.map.streets) do
        if mx >= s.x0 and mx <= s.x1 and my >= s.y0 and my <= s.y1 then return s end
    end
end

-- Kind of map ground at a cell: "road" | "sidewalk" | "crossing" | zone kind | "lawn".
function H.GroundAt(mx, my)
    local s = H.StreetAt(mx, my)
    if s then
        local edge = (s.axis == "h") and (my == s.y0 or my == s.y1) or ((s.axis == "v") and (mx == s.x0 or mx == s.x1))
        -- inside another street's band: intersection (road, crossing stripes at its sides)
        for _, o in ipairs(HD.map.streets) do
            if o ~= s and mx >= o.x0 and mx <= o.x1 and my >= o.y0 and my <= o.y1 then return "road" end
        end
        return edge and "sidewalk" or "road"
    end
    for _, z in ipairs(HD.map.zones) do
        if mx >= z.x0 and mx <= z.x1 and my >= z.y0 and my <= z.y1 then return z.kind end
    end
    return "lawn"
end

-- Validates the neighbourhood map and layout. Returns ok, problems, info.
function H.ValidateMap(root)
    local problems, info = {}, { residential = 0, community = 0, venues = {}, streets = #HD.map.streets }
    local map = HD.map
    local layout = root and root.hood and root.hood.layout
    if not layout or type(layout.lots) ~= "table" then return false, { "no neighbourhood layout" }, info end
    local rects = {}
    for _, lotId in ipairs(sortedKeys(root.hood.lots)) do
        local lot = root.hood.lots[lotId]
        local pl = layout.lots[lotId]
        if not pl then
            problems[#problems + 1] = lotId .. " has no map placement"
        else
            if lot.kind == "community" then
                info.community = info.community + 1
                if lot.venue then
                    if info.venues[lot.venue] then problems[#problems + 1] = "two " .. lot.venue .. " venues" end
                    info.venues[lot.venue] = lotId
                end
            else
                info.residential = info.residential + 1
            end
            if pl.lw ~= lot.w or pl.lh ~= lot.h then problems[#problems + 1] = lotId .. " placement size does not match the lot" end
            local r = { x0 = pl.x, y0 = pl.y, x1 = pl.x + pl.w - 1, y1 = pl.y + pl.h - 1, id = lotId }
            if r.x0 < 0 or r.y0 < 0 or r.x1 >= map.w or r.y1 >= map.h then problems[#problems + 1] = lotId .. " lies outside the map" end
            for _, o in ipairs(rects) do
                if rectsOverlap(r, o) then problems[#problems + 1] = lotId .. " overlaps " .. o.id end
            end
            for _, s in ipairs(map.streets) do
                if rectsOverlap(r, s) then problems[#problems + 1] = lotId .. " overlaps " .. s.name end
            end
            rects[#rects + 1] = r
            -- every cell beyond the street edge (j = h) is on the lot's street (its sidewalk)
            local want = lot.mapStreet
            for i = 0, lot.w - 1 do
                local mx, my = H.LotToMap(pl, i, lot.h)
                local s = H.StreetAt(mx, my)
                if not s or (want and s.id ~= want) then
                    problems[#problems + 1] = lotId .. " street edge does not meet " .. tostring(want); break
                end
            end
        end
    end
    for lotId in pairs(layout.lots) do
        if not root.hood.lots[lotId] then problems[#problems + 1] = "placement for missing lot " .. lotId end
    end
    -- streets form one connected network
    local seen, queue = { [1] = true }, { 1 }
    while #queue > 0 do
        local a = table.remove(queue)
        for b, s in ipairs(map.streets) do
            if not seen[b] and rectsTouch(map.streets[a], s) then seen[b] = true; queue[#queue + 1] = b end
        end
    end
    for n, s in ipairs(map.streets) do if not seen[n] then problems[#problems + 1] = s.name .. " is not connected" end end
    -- intersections (streets that cross or meet)
    info.intersections = 0
    for a = 1, #map.streets do
        for b = a + 1, #map.streets do
            if rectsTouch(map.streets[a], map.streets[b]) then info.intersections = info.intersections + 1 end
        end
    end
    -- addresses unique
    local addr = {}
    for id, lot in pairs(root.hood.lots) do
        if lot.address then
            if addr[lot.address] then problems[#problems + 1] = "address " .. lot.address .. " used twice" end
            addr[lot.address] = id
        end
    end
    return #problems == 0, problems, info
end

-- Deterministic scenery trees: verges along streets and inside the zones (map cells).
function H.SceneryTrees()
    if H._trees then return H._trees end
    local out = {}
    local st = HD.map.treeSeed
    local function rnd() st = (st * 16807) % 2147483647; return st / 2147483647 end
    local occupied = {}
    local function lotAt(mx, my)
        for _, e in ipairs(HD.map.lots) do
            local w, h = e.slot and e.slot.w, e.slot and e.slot.h
            if not w then
                local bp = HL.blueprints[e.blueprint]
                local lw, lh = bp.w, bp.h
                if bp.starter then lw, lh = 14, 11 end
                w, h = H.MapSize(lw, lh, e.rot)
            end
            if mx >= e.x - 1 and mx <= e.x + w and my >= e.y - 1 and my <= e.y + h then return true end
        end
    end
    local density = { woods = 0.22, orchard = 0.14, meadow = 0.03, green = 0.05, field = 0.01, lawn = 0.035, pond = 0 }
    for my = 0, HD.map.h - 1 do
        for mx = 0, HD.map.w - 1 do
            local g = H.GroundAt(mx, my)
            local r = rnd()
            local d = density[g]
            if d and r < d and not lotAt(mx, my) and not occupied[mx .. "," .. my] then
                out[#out + 1] = { x = mx, y = my, kind = (g == "orchard") and "fruit" or ((rnd() < 0.3) and "pine" or "broad"), s = 0.8 + rnd() * 0.5 }
                occupied[mx .. "," .. my] = true
            end
        end
    end
    -- verge trees: every 6th cell just outside each sidewalk
    for _, s in ipairs(HD.map.streets) do
        if s.axis == "h" then
            for mx = s.x0 + 3, s.x1 - 1, 6 do
                for _, my in ipairs({ s.y0 - 1, s.y1 + 1 }) do
                    if my >= 0 and my < HD.map.h and not H.StreetAt(mx, my) and not lotAt(mx, my) and not occupied[mx .. "," .. my] then
                        out[#out + 1] = { x = mx, y = my, kind = "verge", s = 1 }
                        occupied[mx .. "," .. my] = true
                    end
                end
            end
        else
            for my = s.y0 + 3, s.y1 - 1, 6 do
                for _, mx in ipairs({ s.x0 - 1, s.x1 + 1 }) do
                    if mx >= 0 and mx < HD.map.w and not H.StreetAt(mx, my) and not lotAt(mx, my) and not occupied[mx .. "," .. my] then
                        out[#out + 1] = { x = mx, y = my, kind = "verge", s = 1 }
                        occupied[mx .. "," .. my] = true
                    end
                end
            end
        end
    end
    H._trees = out
    return out
end

---------------------------------------------------------------------------
-- Building the neighbourhood
---------------------------------------------------------------------------
H.venueCache = {}

-- A community lot from the outings module's builder (guarded), else a clearly marked placeholder.
function H.BuildVenue(kind, id, address)
    local V = SS.Venues
    if V and V.BuildLot then
        local key = kind .. "|" .. id .. "|" .. address
        local c = H.venueCache[key]
        if not c then
            local ok, lot, problems = pcall(V.BuildLot, kind, id, address)
            if ok and type(lot) == "table" and lot.w and lot.h and lot.floor and lot.walls and lot.objects then
                c = { lot = lot, problems = problems or {} }
                H.venueCache[key] = c
            else
                SS.Log("Venue builder failed for %s: %s", kind, tostring(lot))
            end
        end
        if c then
            local lot = U.deepcopy(c.lot)
            lot.id, lot.address, lot.kind, lot.venue = id, address, "community", kind
            lot.floor[1] = lot.floor[1] or {}
            lot.walls[1] = lot.walls[1] or {}
            lot.entry = lot.entry or { math.floor(lot.w / 2), lot.h - 1 }
            return lot, c.problems
        end
    end
    local lot, problems = HL.BuildCached("venue_" .. kind, id, address)
    lot.kind, lot.venue, lot.placeholder = "community", kind, true
    lot.name = lot.name or HD.VenueNames[kind]
    return lot, problems
end

function H.Address(e) return e.number .. " " .. (HD.StreetName[e.street] or e.street) end

-- Build one map lot (fresh, as originally designed).
function H.BuildMapLot(e)
    local address = H.Address(e)
    local lot, problems
    if e.kind == "community" then lot, problems = H.BuildVenue(e.venue, e.id, address)
    else lot, problems = HL.BuildCached(e.blueprint, e.id, address) end
    lot.mapStreet = e.street
    lot.street = "south"
    return lot, problems
end

-- Topic list for interests: the social module's SS.Topics.list when present, else the fallback.
function H.Topics()
    local T = SS.Topics
    if type(T) == "table" and type(T.list) == "table" and #T.list > 0 then return T.list end
    return HD.FallbackTopics
end
function H.TopicValid(id)
    for _, t in ipairs(H.Topics()) do if t.id == id then return true end end
    return false
end

local function fullNeeds(n)
    local out = {}
    for _, k in ipairs(SS.Tuning.needs) do out[k] = (n and n[k]) or 30 end
    return out
end

-- Unique ids (persistent counters in root.hood).
function H.NewResidentId(root, prefix)
    root.hood.nextResident = root.hood.nextResident or 1
    local id
    repeat
        id = (prefix or "rc") .. root.hood.nextResident
        root.hood.nextResident = root.hood.nextResident + 1
    until not root.residents[id]
    return id
end
function H.NewHouseholdId(root)
    root.hood.nextHousehold = root.hood.nextHousehold or 1
    local id
    repeat
        id = "hh_c" .. root.hood.nextHousehold
        root.hood.nextHousehold = root.hood.nextHousehold + 1
    until not root.households[id]
    return id
end

-- Where a person stands when they arrive home: the lot's spawn cells, then the entry row.
function H.SpawnCell(lot, n)
    local sp = lot.spawn
    if sp and #sp > 0 then
        local s = sp[((n - 1) % #sp) + 1]
        return s[1], s[2], s[3] or 0
    end
    local e = lot.entry or { math.floor(lot.w / 2), lot.h - 1 }
    local off = { 0, -1, 1, -2, 2, -3, 3, -4 }
    local i = e[1] + (off[((n - 1) % #off) + 1])
    if i < 0 or i >= lot.w then i = e[1] end
    return i, math.max(0, e[2] - 1), 0
end

local function newPerson(root, rid, src, hhId, lotId, n)
    local r = {
        id = rid, name = src.name, kind = "human", age = src.age or "adult", pronoun = src.pronoun or "they",
        householdId = hhId, lotId = lotId, bio = src.bio, look = U.deepcopy(src.look or {}),
        personality = U.deepcopy(src.personality or { neat = 5, outgoing = 5, active = 5, playful = 5, nice = 5 }),
        interests = {}, skills = U.deepcopy(src.skills or {}), needs = fullNeeds(src.needs),
        outfit = "everyday", facing = 0, level = 0, x = 0.5, y = 0.5,
        starterJob = src.starterJob and U.deepcopy(src.starterJob) or nil,
    }
    for k, v in pairs(src.interests or {}) do if H.TopicValid(k) then r.interests[k] = v end end
    if lotId then
        local lot = root.hood.lots[lotId]
        local i, j, lv = H.SpawnCell(lot, n or 1)
        r.x, r.y, r.level = i + 0.5, j + 0.5, lv
    end
    return r
end
H.NewPerson = newPerson

local function setRel(root, a, b, v, romance)
    local So = SS.Social
    local r
    if So and So.Rel then r = So.Rel(root, a, b)
    else
        root.social = root.social or { rel = {} }
        root.social.rel = root.social.rel or {}
        r = root.social.rel[a .. ">" .. b] or { daily = 0, life = 0, flags = {} }
        root.social.rel[a .. ">" .. b] = r
    end
    r.flags = r.flags or {}
    if So and So.Adjust and (v or romance) then
        -- the social module's own path (clamps, refreshes friend/love flags): deltas to the spec values
        So.Adjust(root, a, b, { daily = v and (v[1] - (r.daily or 0)) or nil, life = v and (v[2] - (r.life or 0)) or nil,
            romance = romance and (romance - (r.romance or 0)) or nil })
    else
        if v then r.daily, r.life = v[1], v[2] end
        if romance then r.romance = romance end
    end
    r.flags.met = true
    return r
end

local function peekRel(root, a, b)
    return root.social and type(root.social.rel) == "table" and root.social.rel[a .. ">" .. b] or nil
end
H.PeekRel = peekRel

-- Apply one relation spec { a, b, family =, flag =, ab = {daily, life}, ba = {...}, romance =,
-- mode = nil | "keep" | "raise" }.
-- Uses SS.Social (SetFamily, SetPartner, Adjust) when present; spouses and partners start with
-- romance (spec.romance, default HD.Tuning.partnerRomance) so they are a couple from day one.
-- mode "keep": the tie's flags are asserted and the feelings (daily, life, romance) are left
-- exactly as they are (a household reopened in the creator and saved). mode "raise": feelings
-- are raised to at least the spec's values, never lowered (a pair that knew each other gets a
-- new tie). No mode: the spec's values are set (a new pair).
function H.ApplyRelation(root, spec)
    local a, b = spec[1], spec[2]
    if not root.residents[a] or not root.residents[b] or a == b then return false end
    local So = SS.Social
    local friendLife = So and So.T and So.T.friend or 40
    local ab, ba = spec.ab and { spec.ab[1], spec.ab[2] }, spec.ba and { spec.ba[1], spec.ba[2] }
    if spec.flag == "friend" then
        if ab then ab[2] = math.max(ab[2], friendLife) end
        if ba then ba[2] = math.max(ba[2], friendLife) end
    end
    local couple = spec.family == "spouse" or spec.flag == "partner"
    local romance = spec.romance or (couple and (HD.Tuning.partnerRomance or 65)) or nil
    local romA, romB = romance, romance
    if spec.mode == "keep" then
        ab, ba, romA, romB = nil, nil, nil, nil
    elseif spec.mode == "raise" then
        local ca, cb = peekRel(root, a, b), peekRel(root, b, a)
        local function up(v, cur) if v and cur then return { math.max(v[1], cur.daily or 0), math.max(v[2], cur.life or 0) } end return v end
        ab, ba = up(ab, ca), up(ba, cb)
        if romA and ca then romA = math.max(romA, ca.romance or 0) end
        if romB and cb then romB = math.max(romB, cb.romance or 0) end
    end
    local ra, rb = setRel(root, a, b, ab, romA), setRel(root, b, a, ba, romB)
    if spec.family and not (spec.mode == "keep" and ra.flags.family == spec.family and rb.flags.family ~= nil) then
        if So and So.SetFamily then So.SetFamily(root, a, b, spec.family)
        else ra.flags.family = spec.family; rb.flags.family = spec.family end
    end
    if (spec.flag == "partner" or spec.family == "spouse") and not (ra.flags.partner and rb.flags.partner) then
        if So and So.SetPartner then So.SetPartner(root, a, b, true)
        else ra.flags.partner, rb.flags.partner = true, true end
    end
    if spec.flag == "friend" and not (So and So.Refresh) then ra.flags.friend, rb.flags.friend = true, true end
    if So and So.Refresh then
        pcall(So.Refresh, root, a, b, ra)
        pcall(So.Refresh, root, b, a, rb)
    end
    ra.flags.met, rb.flags.met = true, true
    return true
end

-- Remove the creator tie between a and b (family, marriage, partner, roommate flags, both ways).
-- Their feelings stay as they are; nobody is marked an ex (it is an edit, not a break-up).
function H.ClearRelation(root, a, b)
    local So = SS.Social
    for _, pr in ipairs({ { a, b }, { b, a } }) do
        local r = peekRel(root, pr[1], pr[2])
        if r and type(r.flags) == "table" then
            r.flags.family, r.flags.married, r.flags.partner, r.flags.roommate = nil, nil, nil, nil
            if So and So.Refresh then pcall(So.Refresh, root, pr[1], pr[2], r) end
        end
    end
end

local function newHousehold(spec, money, lotId)
    return {
        id = spec.id, name = spec.name, bio = spec.bio, money = money, members = {}, lotId = lotId,
        ledger = {}, journal = {}, inventory = {}, flags = { premade = true }, tx = {},
        problem = spec.problem and { id = spec.problem, solved = false, progress = 0 } or nil,
    }
end

-- Add the premade households (and their members) that are not in the save yet. A household is
-- skipped when any of its people already exist or its lot is taken. Returns number added.
function H.AddPremades(root)
    local added = 0
    local T = SS.Tuning
    for _, spec in ipairs(PM.households) do
        if not spec.starter and not root.households[spec.id] then
            local clash = false
            for _, rid in ipairs(spec.members or {}) do if root.residents[rid] or not PM.people[rid] then clash = true end end
            if spec.lot and (not root.hood.lots[spec.lot] or H.Owner(root, spec.lot)) then clash = true end
            if not clash then
                local hh = newHousehold(spec, spec.money or T.startMoney, spec.lot)
                hh.clock = root.time
                root.households[spec.id] = hh
                for n, rid in ipairs(spec.members) do
                    root.residents[rid] = newPerson(root, rid, PM.people[rid], spec.id, spec.lot, n)
                    hh.members[#hh.members + 1] = rid
                end
                added = added + 1
            end
        end
    end
    for _, tid in ipairs(sortedKeys(PM.townies)) do
        if not root.residents[tid] then
            local t = newPerson(root, tid, PM.townies[tid], nil, nil)
            t.townie = true
            root.residents[tid] = t
            added = added + 1
        end
    end
    for _, rel in ipairs(PM.relations) do
        local ka = root.social and root.social.rel and root.social.rel[rel[1] .. ">" .. rel[2]]
        if not ka then H.ApplyRelation(root, rel) end
    end
    return added
end

-- The whole neighbourhood for a new game (SS.Fixtures.NewWorld delegates here). Roz Kettering's
-- starter world is taken from SS.Fixtures.StarterWorld unchanged and stays the active household.
function H.NewNeighborhood(seed)
    local root = SS.Fixtures.StarterWorld(seed)
    root.hood.name = HD.map.name
    root.hood.layout = { map = HD.map.id, version = 1, lots = {} }
    root.hood.nextResident, root.hood.nextHousehold = 1, 1
    for _, e in ipairs(HD.map.lots) do
        local lot = H.BuildMapLot(e)
        root.hood.lots[e.id] = lot
        root.hood.layout.lots[e.id] = H.Place(e, lot.w, lot.h)
    end
    -- the starter household (Roz), kept exactly; premade extras only
    local hk = root.households[H.DEFAULT_HOUSEHOLD]
    if hk then
        for _, spec in ipairs(PM.households) do
            if spec.id == hk.id then
                hk.bio = spec.bio
                hk.problem = spec.problem and { id = spec.problem, solved = false, progress = 0 } or nil
            end
        end
        hk.inventory = hk.inventory or {}
        hk.flags = { premade = true }
        hk.tx = {}
    end
    local roz = root.residents.r1
    if roz then
        roz.kind, roz.pronoun = roz.kind or "human", roz.pronoun or "she"
        roz.interests = {}
        for k, v in pairs(PM.roz.interests) do if H.TopicValid(k) then roz.interests[k] = v end end
    end
    H.AddPremades(root)
    return root
end

-- Old saves (a single lot, or a neighbourhood from an earlier layout): add the missing map lots,
-- the premade households whose people and lots are free, and the map placements. Returns what
-- it did (list of strings; empty when nothing was needed).
-- Only Linden Hollow saves are upgraded (root.hood.id "hood_linden", or none). Any other
-- neighbourhood (a test world, an imported hood) keeps its lots and people exactly: it only gets
-- map placements for the lots it has, on demand (the map view), and nothing is reported.
function H.IsLinden(root)
    local id = type(root) == "table" and type(root.hood) == "table" and root.hood.id
    return id == nil or id == HD.map.hoodId
end

local function placeOnly(root)
    local L = type(root.hood.layout) == "table" and root.hood.layout or { map = HD.map.id, version = 1 }
    root.hood.layout = L
    L.lots = type(L.lots) == "table" and L.lots or {}
    local rx, used = 0, {}
    for _, id in ipairs(sortedKeys(root.hood.lots)) do
        local lot, e = root.hood.lots[id], mapEntry(id)
        local w, h = lot.w or 10, lot.h or 10
        local pl = L.lots[id]
        if not pl or pl.lw ~= w or pl.lh ~= h then
            if e then L.lots[id] = H.Place(e, w, h)
            else L.lots[id] = { x = rx, y = HD.map.h + 2, w = w, h = h, rot = 0, lw = w, lh = h, reserve = true } end
        end
        if not e then rx = rx + w + 2 end
        used[id] = true
    end
    for id in pairs(L.lots) do if not used[id] then L.lots[id] = nil end end
    return {}
end

-- A home kept from an older save gets what every house of a new game has: its blueprint's name,
-- description and land price, a lot entry on the street row (the blueprint's), the front-door
-- record and a mailbox by the entry. Walls, floors, furniture and people are not touched.
-- Returns what it added (empty when nothing was missing).
function H.FitHome(lot, e)
    local did = {}
    local id = lot.id or (e and e.id) or "?"
    local bp = e and e.blueprint and HL.blueprints[e.blueprint] or nil
    if bp then
        lot.name = lot.name or bp.name
        lot.desc = lot.desc or bp.desc
        if (lot.price or 0) == 0 and bp.land then lot.price = bp.land end
        lot.tier, lot.style = lot.tier or bp.tier, lot.style or bp.style
        lot.blueprint = lot.blueprint or e.blueprint
    end
    local function onRow(c) return type(c) == "table" and c[2] == lot.h - 1 and c[1] >= 0 and c[1] < lot.w end
    local want = bp and bp.entry and onRow(bp.entry) and bp.entry or nil
    -- an earlier upgrade put the entry mid-row without a door or mailbox record: the blueprint's
    -- entry (the end of the house's path) replaces it
    local oldDefault = type(lot.entry) == "table" and lot.entry[1] == math.floor(lot.w / 2) and lot.entry[2] == lot.h - 1
        and not lot.frontDoor and not lot.mailbox
    if not onRow(lot.entry) or (want and oldDefault and (want[1] ~= lot.entry[1])) then
        lot.entry = want and { want[1], want[2] } or { math.floor(lot.w / 2), lot.h - 1 }
        did[#did + 1] = "entry for " .. id
    end
    if not lot.empty and not HL.IsOpening(lot, lot.frontDoor) then
        local fd = (bp and HL.IsOpening(lot, bp.frontDoor)) and bp.frontDoor or HL.FindFrontDoor(lot)
        if fd then lot.frontDoor = fd; did[#did + 1] = "front door for " .. id end
    end
    local hasBox = false
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        if HL.IsKind(o.def, "mailbox") and (o.level or 0) == 0 then hasBox = true; lot.mailbox = lot.mailbox or oid end
    end
    if not hasBox then
        local oid = HL.AddMailbox(lot)
        if oid then did[#did + 1] = "mailbox for " .. id end
    end
    if #did > 0 then lot.version = (lot.version or 1) + 1 end
    return did
end

function H.EnsureNeighborhood(root)
    if not H.IsLinden(root) then return placeOnly(root) end
    local did = {}
    root.hood.layout = type(root.hood.layout) == "table" and root.hood.layout or nil
    local fresh = root.hood.layout == nil
    if fresh then root.hood.layout = { map = HD.map.id, version = 1, lots = {} }; did[#did + 1] = "map layout rebuilt" end
    local L = root.hood.layout
    L.lots = type(L.lots) == "table" and L.lots or {}
    for _, e in ipairs(HD.map.lots) do
        local lot = root.hood.lots[e.id]
        if not lot then
            lot = H.BuildMapLot(e)
            root.hood.lots[e.id] = lot
            did[#did + 1] = "added " .. e.id
        elseif lot.kind == "community" and not lot.venue then
            lot.venue = e.venue
        end
        lot.mapStreet = lot.mapStreet or e.street
        local pl = L.lots[e.id]
        if not pl or pl.lw ~= lot.w or pl.lh ~= lot.h then
            L.lots[e.id] = H.Place(e, lot.w, lot.h)
            if pl then did[#did + 1] = "re-placed " .. e.id end
        end
        if lot.kind ~= "community" then
            for _, d in ipairs(H.FitHome(lot, e)) do did[#did + 1] = d end
        elseif not lot.entry then
            lot.entry = { math.floor(lot.w / 2), lot.h - 1 }; did[#did + 1] = "entry for " .. e.id
        end
    end
    -- lots that are not on the map (imported or from another layout): park them in the reserve row
    local rx = 0
    for _, id in ipairs(sortedKeys(root.hood.lots)) do
        local lot = root.hood.lots[id]
        if not mapEntry(id) and (not L.lots[id] or L.lots[id].lw ~= lot.w or L.lots[id].lh ~= lot.h) then
            L.lots[id] = { x = rx, y = HD.map.h + 2, w = lot.w, h = lot.h, rot = 0, lw = lot.w, lh = lot.h, reserve = true }
            did[#did + 1] = "reserve placement for " .. id
        end
        if not mapEntry(id) then rx = rx + (lot.w or 10) + 2 end
    end
    for id in pairs(L.lots) do if not root.hood.lots[id] then L.lots[id] = nil; did[#did + 1] = "dropped placement " .. id end end
    root.hood.nextResident = root.hood.nextResident or 1
    root.hood.nextHousehold = root.hood.nextHousehold or 1
    if fresh then
        local n = H.AddPremades(root)
        if n > 0 then did[#did + 1] = "added " .. n .. " premade households and townies" end
    end
    return did
end

---------------------------------------------------------------------------
-- Lot questions
---------------------------------------------------------------------------
function H.Owner(root, lotId)
    local best
    for _, id in ipairs(sortedKeys(root.households)) do
        local hh = root.households[id]
        if hh.lotId == lotId and (not best or (H.IsEnded(best) and not H.IsEnded(hh))) then best = hh end
    end
    return best
end

local LANDSCAPE = { tree = true, shrub = true, flowers = true, mailbox = true, fountain = true, birdbath = true }

-- Objects the household owns and may pack: buyable, not build items, not landscaping or fixtures.
function H.Movable(o)
    if o.landscape then return false end
    local def = SS.Objects[o.def]
    if not def or def.buyable == false or def.cat == "system" then return false end
    if type(def.cat) == "string" and def.cat:find("^build") then return false end
    if def.stairs then return false end
    for _, t in ipairs(def.tags or {}) do if LANDSCAPE[t] then return false end end
    if HL.BASE_KIND[o.def] == "mailbox" then return false end
    return true
end

function H.Furnished(lot)
    for _, o in pairs(lot.objects or {}) do
        local def = SS.Objects[o.def]
        if H.Movable(o) and not (def and def.cat == "outdoor") then return true end
    end
    return false
end

-- "occupied" | "ended" (kept by a household whose story ended) | "furnished" | "empty" | "community"
function H.LotStatus(root, lotId)
    local lot = root.hood.lots[lotId]
    if not lot then return nil end
    if lot.kind == "community" then return "community" end
    local owner = H.Owner(root, lotId)
    if owner then return H.IsEnded(owner) and "ended" or "occupied" end
    return H.Furnished(lot) and "furnished" or "empty"
end

-- Structure value when the economy module does not provide one (HD.Tuning.structure).
function H.StructureValue(lot)
    local S = HD.Tuning.structure
    local fin = SS.Finishes or {}
    local v = 0
    local levels = 0
    for lv, walls in pairs(lot.walls or {}) do
        for _, wl in pairs(walls) do
            local k = wl.kind or "wall"
            if k == "wall" then
                local fa = fin.walls and fin.walls[wl.a]
                local fb = fin.walls and fin.walls[wl.b]
                v = v + S.wallBase + (fa and fa.price or S.wallFinish) + (fb and fb.price or S.wallFinish)
            else
                v = v + (S[k] or S.wallBase)
            end
        end
    end
    local grass = { grass = true, lawn = true }
    for lv, fl in pairs(lot.floor or {}) do
        local any = false
        for _, fid in pairs(fl) do
            if not grass[fid] then
                local f = fin.floors and fin.floors[fid]
                v = v + S.floorBase + (f and f.price or S.floorFinish)
                any = true
            end
        end
        if any and lv > 0 then levels = levels + 1 end
    end
    v = v + levels * S.storyBonus
    -- roofed top cells (indoor floors not covered by an upper floor)
    local f0, f1 = lot.floor[0] or {}, lot.floor[1] or {}
    local roofed = 0
    for k, fid in pairs(f1) do roofed = roofed + 1 end
    for k, fid in pairs(f0) do
        if not grass[fid] and not f1[k] and not tostring(fid):find("path") and not tostring(fid):find("deck") then roofed = roofed + 1 end
    end
    if lot.roof then v = v + roofed * S.roofPerCell end
    for _ in pairs(lot.pool or {}) do v = v + S.poolPerCell end
    return math.floor(v)
end

-- A money/time view of a household for SS.Money and SS.Economy (no session needed).
function H.View(root, hh)
    return setmetatable({ root = root, household = hh, hood = root.hood }, {
        __index = function(_, k)
            if k == "money" or k == "ledger" or k == "journal" then return hh and hh[k] end
            if k == "time" then
                if hh and hh.clock and not (root.active and root.active.householdId == hh.id) then return hh.clock end
                return root.time
            end
            return root[k]
        end,
        __newindex = function(t, k, v)
            if (k == "money" or k == "ledger" or k == "journal") and hh then hh[k] = v else rawset(t, k, v) end
        end,
    })
end

-- Appraisal: total, land, structure, contents. Uses SS.Economy.LotValue (adds this module's
-- structure estimate when the economy stub returns only a total).
function H.Appraise(root, lotOrId, hh)
    local lot = type(lotOrId) == "table" and lotOrId or root.hood.lots[lotOrId]
    if not lot then return 0, 0, 0, 0 end
    local view = H.View(root, hh or H.Owner(root, lot.id))
    local E = SS.Economy
    local total, land, structure, contents
    if E and E.LotValue then
        local ok, a, b, c, d = pcall(E.LotValue, view, lot)
        if ok and type(a) == "number" then total, land, structure, contents = a, b, c, d end
    end
    if not total then
        total, land = lot.price or 0, lot.price or 0
        for _, o in pairs(lot.objects or {}) do
            local def = SS.Objects[o.def]
            if def and def.buyable ~= false then total = total + math.floor((def.price or 0) * 0.8) end
        end
    end
    if structure == nil then
        land = lot.price or 0
        structure = H.StructureValue(lot)
        contents = math.max(0, total - land)
        total = land + structure + contents
    end
    return math.floor(total), math.floor(land or 0), math.floor(structure or 0), math.floor(contents or 0)
end

-- Resale value of the objects that would be packed (movable household furniture).
function H.PackableValue(root, lot, hh)
    local view = H.View(root, hh)
    local v, n = 0, 0
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        if H.Movable(o) then
            local val
            if SS.Economy and SS.Economy.ResaleValue then
                local ok, r = pcall(SS.Economy.ResaleValue, view, o)
                val = ok and r or nil
            end
            if not val then local def = SS.Objects[o.def]; val = math.floor((def and def.price or 0) * 0.8) end
            v, n = v + val, n + 1
        end
    end
    return v, n
end

-- Suitability hints for an unoccupied lot (bedrooms, baths, size, budget).
function H.Hints(root, lot, hh)
    local hints = {}
    local beds = HL.BedCapacity(lot)
    local have = HL.KindsPresent(lot)
    local baths = 0
    for _, o in pairs(lot.objects) do if HL.IsKind(o.def, "toilet") then baths = baths + 1 end end
    if lot.empty or not H.Furnished(lot) then
        local area = lot.w * lot.h
        hints[#hints + 1] = string.format("Bare land: %d x %d cells (%s). Build to your own plan.", lot.w, lot.h,
            area < 150 and "a compact starter" or area < 260 and "room for a family house" or "room for a big house and garden")
    else
        hints[#hints + 1] = string.format("Sleeps %d; %d bathroom%s.", beds, baths, baths == 1 and "" or "s")
        if not have.fridge or not have.stove then hints[#hints + 1] = "No working kitchen yet." end
        if next(lot.floor[1] or {}) then hints[#hints + 1] = "Two stories with stairs." end
        if lot.pool and next(lot.pool) then hints[#hints + 1] = "Has a pool." end
    end
    if hh then
        local n = H.LivingMembers(root, hh)
        if beds > 0 and beds < n then hints[#hints + 1] = string.format("Too few beds for the %d %s.", n, hh.name) end
        local price = H.Appraise(root, lot, nil)
        if price > (hh.money or 0) then hints[#hints + 1] = "The " .. hh.name .. " household cannot afford it."
        else
            local HHm = SS.Households
            local buffer = (HHm and HHm.FoodBuffer and HHm.FoodBuffer()) or HD.Tuning.foodBuffer or 500
            if (hh.money or 0) - price < buffer then
                hints[#hints + 1] = string.format("Buying it would leave less than %s for groceries until the first payday.", U.fmtMoney(buffer))
            end
        end
    end
    return hints
end

function H.LivingMembers(root, hh)
    local n = 0
    for _, rid in ipairs(hh.members or {}) do
        local r = root.residents[rid]
        if r and not r.dead then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- Special households: the town's service households (Family Services care, the Animal Shelter;
-- flags.service, lot-less, never played) and households whose story has ended (flags.ended).
-- Neither shows in the household bin, the move-in choices or the merge and move targets.
---------------------------------------------------------------------------
function H.IsService(hh)
    if type(hh) ~= "table" then return false end
    if type(hh.flags) == "table" and hh.flags.service then return true end
    local F = SS.Family
    if F and F.IsServiceHousehold then
        local ok, v = pcall(F.IsServiceHousehold, hh)
        if ok and v then return true end
    end
    return false
end

function H.IsEnded(hh)
    return type(hh) == "table" and type(hh.flags) == "table" and hh.flags.ended ~= nil and hh.flags.ended ~= false
end

function H.IsSpecial(hh) return H.IsService(hh) or H.IsEnded(hh) end

-- Can `hh` be played now? Returns ok, why (a player-facing sentence).
function H.Playable(root, hh)
    if type(hh) ~= "table" then return false, "That household no longer exists." end
    local name = hh.name or "?"
    if H.IsService(hh) then return false, name .. " is run by the town and cannot be played." end
    if H.IsEnded(hh) then return false, "The story of the " .. name .. " household has ended." end
    if not hh.lotId or not root.hood.lots[hh.lotId] then return false, "The " .. name .. " household has no home yet. Move them into a lot first." end
    if H.LivingMembers(root, hh) == 0 then return false, "Nobody is left in the " .. name .. " household." end
    return true
end

-- The first playable household by id other than `exceptId` (nil when there is none).
function H.NextPlayable(root, exceptId)
    for _, id in ipairs(sortedKeys(root.households)) do
        local hh = root.households[id]
        if id ~= exceptId and H.Playable(root, hh) then return hh end
    end
end

-- Make `hh` the active household without attaching a session: the current household's clock is
-- parked and `hh` resumes its own (the save stays consistent; the next attach plays `hh`).
function H.SetActive(root, hh)
    local cur = root.active and root.households[root.active.householdId]
    if cur ~= hh then
        if cur then cur.clock = root.time end
        if hh.clock then root.time = hh.clock end
    end
    hh.clock = nil
    root.active = { householdId = hh.id, lotId = hh.lotId }
    return root.active
end

-- Venue info for the panel (outings data when it has it).
function H.VenueInfo(kind)
    local info = HD.VenueInfo[kind] or { label = kind, activities = {} }
    local VD = SS.VenueData
    if VD and VD.kinds and VD.kinds[kind] then
        local k = VD.kinds[kind]
        info = { label = k.label or info.label, hours = info.hours, activities = k.activities or info.activities, name = k.name }
    end
    -- the real opening hours are the outings module's
    local V = SS.Venues
    if V and type(V.HoursText) == "function" then
        local ok, text = pcall(V.HoursText, kind)
        if ok and type(text) == "string" and text ~= "" then
            local out = {}
            for k, v in pairs(info) do out[k] = v end
            out.hours = text
            return out
        end
    end
    return info
end

---------------------------------------------------------------------------
-- Playing a household: per-household clocks, roster at home, starter jobs.
---------------------------------------------------------------------------

-- Bring a household's members home (members that are not dead, away or on an outing and not on
-- their lot). Returns number placed.
function H.BringHome(root, hh)
    local lot = hh.lotId and root.hood.lots[hh.lotId]
    if not lot then return 0 end
    local n = 0
    for k, rid in ipairs(hh.members) do
        local r = root.residents[rid]
        local onOuting = root.outing and root.outing.participants and (function()
            for _, p in ipairs(root.outing.participants) do if p == rid then return true end end
        end)()
        if r and not r.dead and not onOuting and r.lotId ~= hh.lotId and not (r.away and r.away.untilT) then
            local i, j, lv = H.SpawnCell(lot, k)
            r.lotId, r.x, r.y, r.level, r.away = hh.lotId, i + 0.5, j + 0.5, lv, nil
            n = n + 1
        end
    end
    return n
end

-- Switch the played household. Returns ok, why, world (the attached session).
-- The old session is detached first (its detach hooks still see its own household, time and
-- active record), then the clocks switch, the members come home and the new session attaches.
function H.Play(root, hhId)
    if root.root then root = root.root end
    local hh = root.households[hhId]
    local okP, whyP = H.Playable(root, hh)
    if not okP then return false, whyP end
    local pe = root.pendingEnd
    local ended = type(pe) == "table" and root.households[pe.hh]
    if ended and ended ~= hh then
        return false, "First choose how the story of the " .. (ended.name or "?") .. " household continues (keep the house or sell it)."
    end
    local cur = root.active and root.households[root.active.householdId]
    if root.outing and cur and cur ~= hh then return false, "Finish the current outing first." end
    H.DetachSession()
    H.SwitchClock(root, hh)
    H.BringHome(root, hh)
    root.active = { householdId = hh.id, lotId = hh.lotId }
    local world = SS.Sim.Attach(root, hh.lotId, hh.id)
    H.AssignStarterJobs(world, hh)
    SS.Emit("householdPlayed", world, hh)
    return true, nil, world
end

---------------------------------------------------------------------------
-- The attached session follows the save. Household operations change who lives where and which
-- household is played; these keep SS.Sim.world in step (actors added and taken off through the
-- core's AddActor / RemoveActor so every module hears actorAdded / actorRemoved).
---------------------------------------------------------------------------
-- The session attached to this save (nil when none is, or another save's session is attached).
function H.Session(root)
    local w = SS.Sim and SS.Sim.world
    if w and root and w.root == (root.root or root) then return w end
end

-- Run the attached session's detach hooks and forget it, so a following SS.Sim.Attach does not
-- detach it a second time. Used before a clock switch (H.Play). The core's own Sim.Detach is used
-- when it exists.
function H.DetachSession()
    local Sim = SS.Sim
    local w = Sim and Sim.world
    if not w then return end
    if type(Sim.Detach) == "function" then Sim.Detach(w); if Sim.world == w then Sim.world = nil end; return end
    for _, sys in ipairs(Sim.systems or {}) do
        if sys.detach then sys.detach(w) end
    end
    Sim.world = nil
end

-- Take a resident off the attached session (their action is cancelled, reservations and carried
-- things settled, actorRemoved emitted) without losing their saved place: RemoveActor clears the
-- place, so it is restored here and the caller moves them on. Returns true when they were an actor.
function H.LeaveSession(root, rid)
    local w = H.Session(root)
    local r = w and w.actors[rid]
    if not r then return false end
    local lotId, x, y, level, away = r.lotId, r.x, r.y, r.level, r.away
    SS.Sim.RemoveActor(w, rid, nil)
    r.lotId, r.x, r.y, r.level, r.away = lotId, x, y, level, away
    return true
end

-- Make `hh` the played household. With a session attached to this save it is switched through
-- H.Play (detach, clocks, members home, starter jobs, householdPlayed); without one the save
-- only records it (H.SetActive + H.BringHome) and the next attach plays it. Returns ok, why, world.
function H.Handover(root, hh)
    if H.Session(root) then
        local ok, why, world = H.Play(root, hh.id)
        if ok then return true, nil, world end
        H.SetActive(root, hh)
        H.BringHome(root, hh)
        return false, why
    end
    H.SetActive(root, hh)
    H.BringHome(root, hh)
    return true
end

-- After a household operation: when the attached session's household no longer exists as that
-- record (merged away, replaced), the played household is attached again through H.Play; else
-- the session's actors are brought in line with the saved places of `rids`: someone who now
-- lives on the session's lot and is not an actor is added at their saved cell, and an actor who no
-- longer belongs there is taken off. Returns the (possibly new) session.
function H.SyncSession(root, rids)
    if root and root.root then root = root.root end
    local w = H.Session(root)
    if not w then return nil end
    local hh = w.household
    if hh and root.households[hh.id] ~= hh then
        if w.editSession then
            local es = w.editSession
            local nw = H.EditSession(root, w.lot.id)
            if nw then nw.editSession.householdId = root.active and root.active.householdId; nw.editSession.verdict = es.verdict; return nw end
        end
        local a = root.active
        local ahh = a and root.households[a.householdId]
        if ahh and H.Playable(root, ahh) then
            local ok, _, nw = H.Play(root, ahh.id)
            if ok then return nw end
        end
        if a and a.lotId and root.hood.lots[a.lotId] then return SS.Sim.Attach(root, a.lotId, a.householdId) end
        return w
    end
    local lotId = w.lot.id
    for _, rid in ipairs(rids or {}) do
        local r = root.residents[rid]
        if w.actors[rid] then
            if not r then
                -- the record is gone (deleted): take the actor off without restoring a place
                SS.Sim.RemoveActor(w, rid, nil)
            elseif r.lotId ~= lotId and not r.dead then
                H.LeaveSession(root, rid)
            end
        elseif r and not r.dead and r.lotId == lotId then
            SS.Sim.AddActor(w, rid, math.floor(r.x or 0), math.floor(r.y or 0), r.level or 0)
        end
    end
    return w
end

-- A person who leaves a household while away (evicted, moved to a household without a home, or
-- taken out of the household in the creator while at work or school) keeps `r.leftLotId`: the
-- home they left. The ride home (careers' carpool, the street's arrival) does not know they moved
-- and may still drop them at that door. There they do not live any more: they go to their own
-- household's home, or to town. Only people with that mark are moved; anyone another module brings
-- onto the lot (a guest, a walk-by, a test's neighbour) is left alone, and so is anyone with a role.
function H.MarkLeft(root, r, lotId)
    if r and type(lotId) == "string" and not r.dead and not r.lotId and type(r.away) == "table" then
        r.leftLotId = lotId
        return true
    end
    return false
end

-- Is `r` a stray on `lotId` (played there by household `hhId`)? Returns true and their own
-- household (nil for a townie, who goes into town). Service and ended households are left to the
-- modules that run them.
local function isStray(root, r, lotId, hhId)
    if r.dead or r.role or r.leftLotId ~= lotId or (hhId and r.householdId == hhId) then return false end
    local own = r.householdId and root.households[r.householdId]
    if own and H.IsSpecial(own) then return false end
    return true, own
end

local function sendHome(root, own, r)
    local lot = own and own.lotId and root.hood.lots[own.lotId]
    if lot then
        local n = 1
        for k, m in ipairs(own.members or {}) do if m == r.id then n = k end end
        local i, j, lv = H.SpawnCell(lot, n)
        r.lotId, r.x, r.y, r.level = own.lotId, i + 0.5, j + 0.5, lv
    else
        r.lotId, r.x, r.y, r.level = nil, 0.5, 0.5, 0
    end
    r.away, r.leftLotId = nil, nil
    if SS.Households and SS.Households.ClearRuntime then SS.Households.ClearRuntime(r) end
end

-- The attached session's strays go home (allocation-free when there are none; checked every tick
-- by the "hood" system). Returns the number sent home.
local strayBuf = {}
function H.SendStraysHome(world)
    local root, hh, lot = world and world.root, world and world.household, world and world.lot
    if not (root and root.residents and root.households and root.hood and hh and lot and world.actors) then return 0 end
    if world.editSession or hh.lotId ~= lot.id or root.households[hh.id] ~= hh then return 0 end
    local lotId = lot.id
    local n = 0
    for id, a in pairs(world.actors) do
        local r = root.residents[id]
        if r and r.leftLotId == lotId and not a.role and isStray(root, r, lotId, hh.id) then n = n + 1; strayBuf[n] = id end
    end
    if n == 0 then return 0 end
    if n > 1 then table.sort(strayBuf) end
    local sent = 0
    for k = 1, n do
        local rid = strayBuf[k]
        strayBuf[k] = nil
        local r = root.residents[rid]
        local stray, own
        if r and world.actors[rid] then stray, own = isStray(root, r, lotId, hh.id) end
        if stray then
            SS.Sim.RemoveActor(world, rid, nil)
            sendHome(root, own, r)
            sent = sent + 1
            local text = string.format("%s does not live here any more and heads %s.", r.name or rid,
                (own and own.lotId) and ("home to " .. (root.hood.lots[own.lotId].address or "their own house")) or "into town")
            if SS.Actions and SS.Actions.Journal then SS.Actions.Journal(world, text) end
            SS.Emit("residentSentHome", world, rid, own and own.id)
        end
    end
    return sent
end

-- Park the current household's clock and resume `hh`'s own clock.
function H.SwitchClock(root, hh)
    local cur = root.active and root.households[root.active.householdId]
    if cur == hh then return end
    local from = root.time
    if cur then cur.clock = root.time end
    if hh.clock then root.time = hh.clock end
    hh.clock = nil
    SS.Emit("householdClock", root, hh.id, from, root.time)
end

-- The household's own time (active: root.time; others: their paused clock).
function H.Clock(root, hh)
    if root.active and root.active.householdId == hh.id then return root.time end
    return hh.clock or root.time
end

function H.AssignStarterJobs(world, hh)
    hh.flags = hh.flags or {}
    if hh.flags.jobsAssigned then return end
    local C, CD = SS.Career, SS.CareerData
    if not (C and C.Hire and CD and CD.tracks) then return end
    for _, rid in ipairs(hh.members) do
        local r = world.root.residents[rid]
        local job = r and r.starterJob
        if job and not r.dead and not r.career and CD.tracks[job.track] then
            local ok = pcall(C.Hire, world, r, job.track, job.level, "premade")
            if ok then r.starterJob = nil end
        end
    end
    hh.flags.jobsAssigned = true
end

-- A temporary session to edit a lot that is not the played household's home. Community lots and
-- unowned lots are edited for free (world.editVenue); the result is attached as SS.Sim.world.
-- Leaving build/buy for live mode (or opening the map) re-attaches the played household.
function H.EditSession(root, lotId)
    local lot = root.hood.lots[lotId]
    if not lot then return nil, "Unknown lot." end
    local owner = H.Owner(root, lotId)
    if owner and not H.IsEnded(owner) then
        if root.active and root.active.householdId == owner.id then
            return SS.Sim.Attach(root, lotId, owner.id)
        end
        return nil, "The " .. owner.name .. " household lives there. Play them to change their home."
    end
    if root.outing then return nil, "Finish the current outing first." end
    -- The session keeps the played household as its viewer (toolbar, portraits), but editVenue
    -- tells build and buy never to charge it; nobody of theirs is on this lot.
    local world = SS.Sim.Attach(root, lotId, nil)
    world.editVenue = true
    world.editSession = { lotId = lotId, community = lot.kind == "community",
        householdId = root.active and root.active.householdId }
    return world
end

---------------------------------------------------------------------------
-- The end of a household's story (events: the last resident died; family: nobody is left at
-- home). The record stays; its lot is kept as it is or put on the market.
---------------------------------------------------------------------------
function H.IsMemorial(o)
    if type(o) ~= "table" then return false end
    if o.def == "ev_grave" or o.def == "ev_urn" then return true end
    local def = SS.Objects[o.def]
    return def ~= nil and SS.Tags ~= nil and SS.Tags.Has(def, "memorial") and true or false
end

-- Put an ended household's house on the market: its memorials move with the family records
-- (household.memorials, at most 20), the lot is unowned and priced like any other. Returns ok, text.
function H.ReleaseLot(root, hhId)
    if root.root then root = root.root end
    local hh = root.households[hhId]
    if not hh then return false, "That household no longer exists." end
    if not H.IsEnded(hh) then return false, "The " .. (hh.name or "?") .. " household still lives there. Move them out instead." end
    local lotId = hh.lotId
    local lot = lotId and root.hood.lots[lotId]
    if not lot then return false, "The " .. (hh.name or "?") .. " household has no house to sell." end
    hh.memorials = type(hh.memorials) == "table" and hh.memorials or {}
    local moved = 0
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        if H.IsMemorial(o) then
            local s = type(o.state) == "table" and o.state or {}
            hh.memorials[#hh.memorials + 1] = { def = o.def, rid = s.rid, name = s.name, died = s.died, cause = s.cause, from = lotId }
            lot.objects[oid] = nil
            moved = moved + 1
        end
    end
    while #hh.memorials > 20 do table.remove(hh.memorials, 1) end
    for _, o in pairs(lot.objects) do if o.parent and not lot.objects[o.parent] then o.parent, o.pslot = nil, nil end end
    if type(hh.flags.ended) == "table" then hh.flags.ended.lotId = hh.flags.ended.lotId or lotId end
    hh.lotId = nil
    lot.forSale = true
    lot.version = (lot.version or 1) + 1
    -- the household's story has ended: nothing scheduled for the house is kept for it
    if SS.Households and SS.Households.DropEvents then SS.Households.DropEvents(root, lotId) end
    local w = SS.Sim and SS.Sim.world
    if moved > 0 and w and w.root == root and w.lot == lot and SS.World and SS.World.Rebuild then pcall(SS.World.Rebuild, w) end
    SS.Emit("lotChanged", "release", lotId)
    return true, (lot.address or lotId) .. " is on the market." ..
        (moved > 0 and string.format(" %d memorial%s went with the %s family records.", moved, moved == 1 and "" or "s", hh.name or "") or "")
end

-- events HO-1: the continuation choice. "keep": the household is ended in the roster and keeps
-- its house exactly as it is, memorials included, off the market (it can be put on the market
-- later from the neighbourhood). "sell": the house goes on the market (H.ReleaseLot). The
-- played household is not switched here: the player picks one in the neighbourhood (leaving the
-- neighbourhood without choosing plays the next playable household). Returns true when handled.
function H.OnHouseholdEnded(world, hh, choice)
    local root = type(world) == "table" and (world.root or world) or nil
    if not root or type(root.households) ~= "table" then return false end
    if type(hh) ~= "table" then hh = root.households[hh] end
    if type(hh) ~= "table" or root.households[hh.id] ~= hh then return false end
    choice = (choice == "sell") and "sell" or "keep"
    hh.flags = type(hh.flags) == "table" and hh.flags or {}
    local ended = hh.flags.ended
    if type(ended) ~= "table" then
        ended = { t = type(ended) == "number" and ended or H.Clock(root, hh), reason = "all_gone" }
        hh.flags.ended = ended
    end
    ended.choice = choice
    ended.lotId = ended.lotId or hh.lotId
    local lot = hh.lotId and root.hood.lots[hh.lotId]
    if lot then
        if choice == "sell" then H.ReleaseLot(root, hh.id) else lot.forSale = nil end
    end
    SS.Emit("householdClosed", root, hh, choice)
    return true
end

---------------------------------------------------------------------------
-- Starter problems (checked hourly for the household being played)
---------------------------------------------------------------------------
local function seatCount(lot)
    local n = 0
    for _, o in pairs(lot.objects) do
        local def = SS.Objects[o.def]
        if def then
            local places = 0
            for name, sl in pairs(def.slots or {}) do if sl.group == "seat" or (not sl.group and name:find("^seat")) then places = places + 1 end end
            if places == 0 and (def.seat or SS.Tags.Has(def, "seat")) then places = 1 end
            n = n + places
        end
    end
    return n
end
H.SeatCount = seatCount

local function skillLevel(r, skill)
    if SS.Skills and SS.Skills.Level then
        local ok, v = pcall(SS.Skills.Level, r, skill)
        if ok and type(v) == "number" then return v end
    end
    return math.floor(r.skills and r.skills[skill] or 0)
end

-- Returns met (bool), done (n goals met), total, text per goal.
function H.EvaluateProblem(world, hh)
    local p = hh.problem and PM.problems[hh.problem.id]
    if not p then return false, 0, 0, {} end
    local root = world.root or world
    local done, lines = 0, {}
    for _, g in ipairs(p.goal) do
        local ok, txt = false, ""
        if g[1] == "seats" then
            local lot = hh.lotId and root.hood.lots[hh.lotId]
            local n = lot and seatCount(lot) or 0
            ok, txt = n >= g[2], string.format("Seats at home: %d of %d", n, g[2])
        elseif g[1] == "skill" then
            local r = root.residents[g[2]]
            local lv = r and skillLevel(r, g[3]) or 0
            ok, txt = r ~= nil and lv >= g[4], string.format("%s's %s: %d of %d", r and r.name or g[2], g[3], lv, g[4])
        elseif g[1] == "rel" then
            local rr = root.social and root.social.rel and root.social.rel[g[2] .. ">" .. g[3]]
            local d = rr and rr.daily or 0
            local a, b = root.residents[g[2]], root.residents[g[3]]
            ok, txt = d >= g[4], string.format("%s's feeling for %s: %d of %d", a and a.name or g[2], b and b.name or g[3], math.floor(d), g[4])
        elseif g[1] == "money" then
            ok, txt = (hh.money or 0) >= g[2], string.format("Savings: %s of %s", U.fmtMoney(hh.money or 0), U.fmtMoney(g[2]))
        elseif g[1] == "job" then
            local r = root.residents[g[2]]
            ok, txt = r ~= nil and r.career ~= nil, (r and r.name or g[2]) .. " has a job"
        end
        if ok then done = done + 1 end
        lines[#lines + 1] = { ok = ok, text = txt }
    end
    return done == #p.goal, done, #p.goal, lines
end

function H.CheckProblem(world)
    local hh = world.household
    if not hh or not hh.problem or hh.problem.solved then return end
    local p = PM.problems[hh.problem.id]
    if not p then return end
    if not hh.problem.announced then
        hh.problem.announced = true
        if SS.Actions and SS.Actions.Journal then SS.Actions.Journal(world, "Household problem: " .. p.title .. ". " .. p.hint) end
    end
    local met, done, total = H.EvaluateProblem(world, hh)
    hh.problem.progress = total > 0 and done / total or 0
    if met then
        hh.problem.solved, hh.problem.solvedAt = true, world.time
        local text = "Problem solved: " .. p.title .. "."
        if SS.Actions and SS.Actions.Journal then SS.Actions.Journal(world, text) end
        SS.Emit("notice", nil, text)
        SS.Emit("hoodProblemSolved", world, hh, hh.problem.id)
    end
end

if SS.Sim and SS.Sim.Register then
    SS.Sim.Register({ name = "hood", order = 95,
        tick = function(world) H.SendStraysHome(world) end,
        hour = function(world) H.CheckProblem(world) end,
    })
end

---------------------------------------------------------------------------
-- Walk-bys: the same persistent people from elsewhere in the neighbourhood.
---------------------------------------------------------------------------
-- Residents who can appear on `lotId` as passers-by or visitors: townies and members of other
-- households (not service households or ended ones) who are not dead, away (in care, at work or
-- school), on an outing or already on another lot. Sorted by id.
function H.WalkByCandidates(root, lotId)
    if root.root then root = root.root end
    local active = root.active and root.active.householdId
    local out = {}
    for _, rid in ipairs(sortedKeys(root.residents)) do
        local r = root.residents[rid]
        local hh = r.householdId and root.households[r.householdId]
        local eligible = (r.townie or (hh and hh.id ~= active)) and (r.kind == nil or r.kind == "human")
        if hh and H.IsSpecial(hh) then eligible = false end   -- in care, or a household whose story ended
        local away = type(r.away) == "table" and r.away.reason ~= "home"
        if eligible and not r.dead and not r.role and not away then
            local here = r.lotId
            local atHome = hh and here == hh.lotId
            if (here == nil or atHome) and here ~= lotId then out[#out + 1] = rid end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Consistency: roster, membership, ownership, active household. Repairs in place and returns a
-- list of what it repaired (empty for a consistent save).
---------------------------------------------------------------------------
function H.Reconcile(root)
    local fixed = {}
    local lots, hhs, res = root.hood.lots, root.households, root.residents
    -- ownership: one household per residential lot. When two claim a lot, the household whose
    -- people are on it keeps it (then the played household, then the lower id).
    local claims = {}
    for _, id in ipairs(sortedKeys(hhs)) do
        local hh = hhs[id]
        if hh.lotId then
            local lot = lots[hh.lotId]
            if not lot or lot.kind == "community" then
                fixed[#fixed + 1] = id .. " cannot own " .. tostring(hh.lotId); hh.lotId = nil
            else
                claims[hh.lotId] = claims[hh.lotId] or {}
                table.insert(claims[hh.lotId], id)
            end
        end
    end
    local function presence(hh, lotId)
        local n = 0
        for _, rid in ipairs(type(hh.members) == "table" and hh.members or {}) do
            local r = res[rid]
            if r and not r.dead and r.lotId == lotId and r.householdId == hh.id then n = n + 1 end
        end
        return n
    end
    for _, lotId in ipairs(sortedKeys(claims)) do
        local list = claims[lotId]
        if #list > 1 then
            local best, bestScore
            for _, id in ipairs(list) do
                local score = presence(hhs[id], lotId) * 10 + ((root.active and root.active.householdId == id) and 5 or 0)
                if not bestScore or score > bestScore then best, bestScore = id, score end
            end
            for _, id in ipairs(list) do
                if id ~= best then
                    fixed[#fixed + 1] = id .. " and " .. best .. " both owned " .. lotId .. " (kept by " .. best .. ")"
                    hhs[id].lotId = nil
                end
            end
        end
    end
    -- a household left without a lot whose living people all stand on one unowned home gets it back
    local owned = {}
    for _, id in ipairs(sortedKeys(hhs)) do if hhs[id].lotId then owned[hhs[id].lotId] = id end end
    for _, id in ipairs(sortedKeys(hhs)) do
        local hh = hhs[id]
        if not hh.lotId and type(hh.members) == "table" and not H.IsSpecial(hh) then
            local at, n, same = nil, 0, true
            for _, rid in ipairs(hh.members) do
                local r = res[rid]
                if r and not r.dead then
                    n = n + 1
                    if not r.lotId or (at and r.lotId ~= at) then same = false end
                    at = at or r.lotId
                end
            end
            local lot = at and lots[at]
            if n > 0 and same and lot and lot.kind ~= "community" and not owned[at] and not (root.outing and root.outing.lotId == at) then
                hh.lotId, owned[at] = at, id
                fixed[#fixed + 1] = id .. " rehomed at " .. at .. " (their people live there)"
            end
        end
    end
    for _, id in ipairs(sortedKeys(hhs)) do
        local hh = hhs[id]
        if hh.id ~= id then hh.id = id; fixed[#fixed + 1] = "household id " .. id end
        if type(hh.name) ~= "string" or hh.name == "" then hh.name = "Household"; fixed[#fixed + 1] = "name for " .. id end
        hh.flags = type(hh.flags) == "table" and hh.flags or {}
        hh.inventory = type(hh.inventory) == "table" and hh.inventory or {}
        hh.tx = type(hh.tx) == "table" and hh.tx or {}
        hh.members = type(hh.members) == "table" and hh.members or {}
        -- members: unique, existing, pointing back
        local seen, keep = {}, {}
        for _, rid in ipairs(hh.members) do
            local r = res[rid]
            if r and not seen[rid] then
                if r.householdId ~= id then
                    if r.householdId and hhs[r.householdId] then
                        -- listed in two households: the resident's own record wins
                        local other = hhs[r.householdId]
                        local listed = false
                        for _, m in ipairs(other.members or {}) do if m == rid then listed = true end end
                        if listed then fixed[#fixed + 1] = rid .. " removed from " .. id .. " (lives with " .. r.householdId .. ")"
                        else r.householdId = id; keep[#keep + 1] = rid; fixed[#fixed + 1] = rid .. " rejoined " .. id end
                    else
                        r.householdId = id; keep[#keep + 1] = rid; fixed[#fixed + 1] = rid .. " points to " .. id
                    end
                else
                    keep[#keep + 1] = rid
                end
                seen[rid] = true
            end
        end
        if #keep ~= #hh.members then hh.members = keep end
        if hh.problem and (type(hh.problem) ~= "table" or not PM.problems[hh.problem.id]) then hh.problem = nil end
        if type(hh.clock) ~= "number" then hh.clock = nil end
    end
    for _, rid in ipairs(sortedKeys(res)) do
        local r = res[rid]
        -- the dead keep their householdId for the family records but leave the members list
        -- (events: household.deceased); they are never added back
        if r.householdId and not r.dead then
            local hh = hhs[r.householdId]
            local listed = false
            if hh then for _, m in ipairs(hh.members) do if m == rid then listed = true end end end
            if not listed then
                if hh and #hh.members < HD.Tuning.capacity then
                    hh.members[#hh.members + 1] = rid; fixed[#fixed + 1] = rid .. " added to " .. hh.id
                else
                    r.householdId = nil; r.townie = true; fixed[#fixed + 1] = rid .. " lost their household"
                end
            end
        end
    end
    -- someone who left a household while away and was saved on that old home (dropped at the old
    -- door) goes to their own home, else to town; a mark naming no lot is dropped, and a mark on
    -- someone who has since moved back is spent. The played household's people on an outing to
    -- that house stay where they are.
    local ownerOf = {}
    for _, id in ipairs(sortedKeys(hhs)) do if hhs[id].lotId then ownerOf[hhs[id].lotId] = id end end
    local outingLot = type(root.outing) == "table" and root.outing.lotId
    for _, rid in ipairs(sortedKeys(res)) do
        local r = res[rid]
        local left = r.leftLotId
        if left ~= nil then
            local mine = r.householdId and hhs[r.householdId]
            if type(left) ~= "string" or not root.hood.lots[left] then
                r.leftLotId = nil
                fixed[#fixed + 1] = rid .. ": the home they left is not in the neighbourhood (mark dropped)"
            elseif mine and mine.lotId == left then
                r.leftLotId = nil
            elseif r.lotId == left and left ~= outingLot then
                local stray, own = isStray(root, r, left, ownerOf[left])
                if stray then
                    sendHome(root, own, r)
                    fixed[#fixed + 1] = rid .. " no longer lives on " .. left .. ": sent " .. (r.lotId and ("home to " .. r.lotId) or "to town")
                end
            end
        end
    end
    -- a continuation that was never answered stays until the player chooses (events HO-2)
    local pe = root.pendingEnd
    if pe ~= nil and (type(pe) ~= "table" or not hhs[pe.hh]) then root.pendingEnd, pe = nil, nil; fixed[#fixed + 1] = "stale continuation cleared" end
    -- the active household must be playable and own the active lot (outings keep their own
    -- record; a household waiting for its continuation choice keeps its lot and stays active)
    local a = root.active
    local ahh = a and hhs[a.householdId]
    local waiting = pe and ahh and pe.hh == ahh.id
    if not waiting and (not ahh or not ahh.lotId or H.IsSpecial(ahh) or (ahh.lotId ~= a.lotId and not root.outing)) then
        local pick = ahh and ahh.lotId and not H.IsSpecial(ahh) and ahh or nil
        if pick then
            a.lotId = pick.lotId
            fixed[#fixed + 1] = "active lot set to " .. pick.lotId
        else
            pick = H.NextPlayable(root)
            if pick then
                H.SetActive(root, pick)
                fixed[#fixed + 1] = "active household set to " .. pick.id
            end
        end
    end
    -- the active household runs on root.time; nobody else's clock may be missing forever
    if root.active and hhs[root.active.householdId] then hhs[root.active.householdId].clock = nil end
    -- scheduled events parked for a household that no longer exists or whose story ended, and
    -- events of a bulldozed lot (older saves parked them as "bulldozed:<lot>"): they can never fire
    local sch = root.scheduled
    if type(sch) == "table" then
        local dropped = 0
        for i = #sch, 1, -1 do
            local key = type(sch[i]) == "table" and sch[i].lotId
            if type(key) == "string" then
                local hid = key:match("^hh:(.+)$")
                if (hid and (not hhs[hid] or H.IsEnded(hhs[hid]))) or key:find("^bulldozed:") then
                    table.remove(sch, i); dropped = dropped + 1
                end
            end
        end
        if dropped > 0 then fixed[#fixed + 1] = dropped .. " scheduled event" .. (dropped == 1 and "" or "s") .. " of households or houses that are gone dropped" end
    end
    return fixed
end

-- Save validator: layout, premades for old saves, consistency. Adds a problem line only when it
-- actually repaired or upgraded something (a clean save reports nothing).
function H.Validator(root, problems)
    if type(root.hood) ~= "table" then return end
    local ok, err = pcall(function()
        -- another neighbourhood (a test world, an imported hood) is left as it is
        if H.IsLinden(root) then
            for _, d in ipairs(H.EnsureNeighborhood(root)) do problems[#problems + 1] = "neighbourhood: " .. d end
        end
        for _, d in ipairs(H.Reconcile(root)) do problems[#problems + 1] = "households: " .. d end
    end)
    if not ok then problems[#problems + 1] = "neighbourhood check failed: " .. tostring(err) end
end
if SS.Save and SS.Save.RegisterValidator then SS.Save.RegisterValidator(H.Validator) end

-- The end of a household is decided by the events module (the last resident died: SS.Death
-- then calls H.OnHouseholdEnded with the player's choice) and the family module (nobody left at
-- home: SS.Households.End / Close). This module never marks a household ended by itself.
