-- SideStreet community venues at run time: anchors and validation, venue editing rules, staff on
-- stable venue-role identities, townie patrons, date guests, the outing/date score, and the park
-- and social-club activities. Owner: outings module (docs/modules/outings.md).
--
-- A venue lot is "live" only while the household is on an outing there (root.outing.lotId ==
-- lot.id). Previewing or editing a venue from the neighbourhood attaches the lot with nobody on it.
-- Travel (Sim/Travel.lua) moves people between lots; Shopping and Dining add their own flows.
local _, SS = ...
local VD = SS.VenueData
local CL = SS.CommunityLots
local V = SS.Venues or {}
SS.Venues = V
local T = VD.tuning
local U = SS.U
local G, W = SS.Grid, SS.World

---------------------------------------------------------------------------------------------------
-- Small helpers
local function sortedKeys(t)
    local ks = {}
    for k in pairs(t or {}) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
    return ks
end
V.SortedKeys = sortedKeys

local function idx(lot, i, j) return j * lot.w + i + 1 end
local function inLot(lot, i, j) return i >= 0 and j >= 0 and i < lot.w and j < lot.h end
local function rootOf(x) return x and (x.root or x) end
local function cellOf(a) return math.floor(a.x), math.floor(a.y) end

local function tagged(def, tag) return def and SS.Tags.Has(def, tag) end

function V.Kind(lot) return lot and lot.kind == "community" and lot.venue or nil end
function V.Info(kind) return VD.kinds[kind] end

-- Is this session a venue with the household on an outing here? Returns the outing record.
function V.Active(world)
    if not world or not world.lot then return nil end
    local root = rootOf(world)
    local o = root.outing
    if o and o.lotId == world.lot.id and V.Kind(world.lot) then return o end
    return nil
end

-- Household member of the session's household (money, control)?
function V.IsMember(world, actor)
    return actor and world.household and actor.householdId == world.household.id and not actor.npc and not actor.role
end

function V.Say(world, actor, situation, ctx, icon)
    if not actor then return nil end
    local text
    if SS.Lines and SS.Lines.Say then
        local ok, t = pcall(SS.Lines.Say, world, actor, situation, ctx or {})
        if ok then text = t end
    end
    if not text then
        local pool = VD.reactions[situation]
        if pool and #pool > 0 then
            local n = SS.RandomInt(world, "outings.lines", 1, #pool)
            text = pool[n]
            ctx = ctx or {}
            text = text:gsub("{(%w+)}", function(k) return tostring(ctx[k] or "") end)
        end
    end
    if text then
        if SS.Actions and SS.Actions.Message then SS.Actions.Message(world, actor, actor.name .. ": " .. text, icon) end
    end
    return text
end

-- Bounded outing log (shown in the outing summary and the journal on return).
function V.Log(world, text)
    local o = rootOf(world).outing
    if not o then return end
    o.log = o.log or {}
    o.log[#o.log + 1] = { t = world.time, text = text }
    while #o.log > 30 do table.remove(o.log, 1) end
end

function V.Notice(world, text)
    if SS.UI and SS.UI.Notice then pcall(SS.UI.Notice, text) end
    SS.Emit("notice", nil, text)
end

---------------------------------------------------------------------------------------------------
-- Opening hours (on the outing clock)
function V.HourOf(time) return (time / 60) % 24 end

function V.IsOpen(kind, time)
    local k = VD.kinds[kind]
    local h = k and k.hours
    if not h then return true end
    local hr = V.HourOf(time)
    if h.open < h.close then return hr >= h.open and hr < h.close end
    return hr >= h.open or hr < h.close
end

local function hourText(h)
    h = h % 24
    local ap = h < 12 and "AM" or "PM"
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return h12 .. " " .. ap
end
V.HourText = hourText

function V.HoursText(kind)
    local k = VD.kinds[kind]
    local h = k and k.hours
    if not h then return "Open all day and night" end
    return "Open " .. hourText(h.open) .. " to " .. hourText(h.close)
end

-- Minutes until closing (nil when always open or already closed).
function V.MinutesToClose(kind, time)
    local k = VD.kinds[kind]
    local h = k and k.hours
    if not h or not V.IsOpen(kind, time) then return nil end
    local hr = V.HourOf(time)
    local left = h.close - hr
    if left <= 0 then left = left + 24 end
    return left * 60
end

---------------------------------------------------------------------------------------------------
-- Anchors: what each object provides to a venue (staff posts, service points, public facilities).
V.ANCHOR_LABEL = {
    register = "shop tills", display_clothing = "clothing rails", display_gift = "gift and flower stands",
    display_books = "book and magazine racks", display_decor = "home goods shelves", changing_booth = "changing booths",
    restroom = "restroom toilets", seating = "public seats", podium = "host stands", waiter_station = "waiter stations",
    kitchen = "kitchen ranges", cafe_table = "cafe tables", dining_seat = "chairs at cafe tables",
    picnic = "picnic tables", grill = "grills", recreation = "recreation spots (chess, play)",
    landscaping = "trees, shrubs and flower beds", dj_booth = "DJ booths", dance = "dance floors",
    games = "games (pool, darts)", bar = "bars", party = "tall mingling tables", fountain = "fountains",
}
V.ANCHOR_ONE = {
    register = "shop till", display_clothing = "clothing rail", display_gift = "gift and flower stand",
    display_books = "book and magazine rack", display_decor = "home goods shelf", changing_booth = "changing booth",
    restroom = "restroom toilet", seating = "public seat", podium = "host stand", waiter_station = "waiter station",
    kitchen = "kitchen range", cafe_table = "cafe table", dining_seat = "chair at a cafe table",
    picnic = "picnic table", grill = "grill", recreation = "recreation spot (chess, play)",
    landscaping = "tree, shrub or flower bed", dj_booth = "DJ booth", dance = "dance floor",
    games = "game (pool, darts)", bar = "bar", party = "tall mingling table", fountain = "fountain",
}
-- "1 host stand", "2 host stands"
function V.AnchorCount(n, k)
    local label = n == 1 and (V.ANCHOR_ONE[k] or k) or (V.ANCHOR_LABEL[k] or k)
    return n .. " " .. label
end
V.ROLE_BY_ANCHOR = { register = "shopkeeper", podium = "host", waiter_station = "waiter", kitchen = "cook", dj_booth = "dj", bar = "bartender" }
V.STAFF_ROLES = { "shopkeeper", "host", "waiter", "cook", "dj", "bartender" }
V.IS_STAFF_ROLE = {}
for _, r in ipairs(V.STAFF_ROLES) do V.IS_STAFF_ROLE[r] = true end

local RECREATION_USE = { chess = true, play = true }
local GAMES_USE = { pool = true, darts = true }
local LANDSCAPE_TAGS = { "tree", "shrub", "flowers", "planter", "fountain", "birdbath" }

-- Anchor kinds of one definition (dining_seat is positional and added by the scanner).
function V.AnchorKinds(def)
    local out = {}
    if not def then return out end
    local use = def.venueUse
    local function add(k) out[#out + 1] = k end
    if tagged(def, "register") then add("register") end
    for _, t in ipairs({ "display_clothing", "display_gift", "display_books", "display_decor", "changing_booth",
        "podium", "waiter_station", "cafe_table", "dj_booth", "bar" }) do
        if tagged(def, t) then add(t) end
    end
    if tagged(def, "cafe_kitchen") then add("kitchen") end
    if tagged(def, "restroom") or tagged(def, "toilet") then add("restroom") end
    if def.seat then add("seating") end
    if use == "dance" or tagged(def, "dance") then add("dance") end
    if (use and GAMES_USE[use]) or tagged(def, "pool_table") or tagged(def, "darts") or tagged(def, "arcade") or tagged(def, "pinball") then add("games") end
    if (use and RECREATION_USE[use]) or tagged(def, "chess") or tagged(def, "kid_play") then add("recreation") end
    if use == "grill" or tagged(def, "grill") then add("grill") end
    if use == "picnic" or (def.cat == "surfaces" and def.sub == "outdoor") then add("picnic") end
    if use == "mingle" or tagged(def, "buffet") then add("party") end
    if use == "fountain" or tagged(def, "fountain") then add("fountain") end
    local land = def.landscape
    if not land then for _, t in ipairs(LANDSCAPE_TAGS) do if tagged(def, t) then land = true end end end
    if land then add("landscaping") end
    return out
end

-- World cells of a slot's approaches.
function V.SlotCells(o, sl)
    local out = {}
    for _, ap in ipairs(sl.approaches or {}) do
        local dx, dy = G.rot(ap[1], ap[2], o.f or 0)
        out[#out + 1] = { o.x + dx, o.y + dy, o.level or 0 }
    end
    return out
end

-- Staff post cells of an anchor object: approaches of slots marked staff (or named staff/cook).
-- The post comes first: the "staff" slot, then "cook", then any other staff-marked slot
-- (a catalogue waiter station marks its pickup slot staff too; that is not where the waiter stands).
local POST_ORDER = { staff = 1, cook = 2 }
function V.StaffCells(o, def)
    local out, names = {}, {}
    for _, name in ipairs(sortedKeys(def.slots)) do
        local sl = def.slots[name]
        if sl.staff or POST_ORDER[name] then names[#names + 1] = name end
    end
    table.sort(names, function(a, b)
        local ra, rb = POST_ORDER[a] or 3, POST_ORDER[b] or 3
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    for _, name in ipairs(names) do
        for _, c in ipairs(V.SlotCells(o, def.slots[name])) do out[#out + 1] = c end
    end
    return out
end

local NOBLOCK_MOUNT = { wall = true, ceiling = true, surface = true, window = true }
local function nonBlocking(def, o)
    if W.NonBlocking then return W.NonBlocking(def, o) end
    if not def then return true end
    if def.noBlock or (def.mount and NOBLOCK_MOUNT[def.mount]) then return true end
    return o and o.parent and true or false
end

local function stairCells(o, def)
    local st = def.stairs
    local function at(p) local dx, dy = G.rot(p[1], p[2], o.f or 0); return { o.x + dx, o.y + dy } end
    local run = {}
    for n = 1, #st.run do run[n] = at(st.run[n]) end
    return at(st.bottom), at(st.top), run
end

-- Occupancy of a lot from its saved data alone (no session needed).
function V.Occupancy(lot)
    local occ, wells, stairs = { [0] = {}, [1] = {} }, { [0] = {}, [1] = {} }, {}
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def then
            local lv = o.level or 0
            if occ[lv] and not nonBlocking(def, o) then
                for _, c in ipairs(G.footprint(def, o)) do
                    if inLot(lot, c[1], c[2]) then occ[lv][idx(lot, c[1], c[2])] = oid end
                end
            end
            if def.stairs and lv == 0 then
                local b, tp, run = stairCells(o, def)
                stairs[#stairs + 1] = { bottom = b, top = tp }
                for _, c in ipairs(run) do if inLot(lot, c[1], c[2]) then wells[1][idx(lot, c[1], c[2])] = oid end end
            end
        end
    end
    return occ, wells, stairs
end

local function openEdge(lot, lv, i, j, ni, nj)
    local walls = lot.walls[lv]
    local wl = walls and walls[G.edgeBetween(i, j, ni, nj)]
    return not wl or W.OPENINGS[wl.kind] == true
end

-- Cells reachable on foot from the lot's entry (walls, openings, footprints, stairs; no people,
-- no permissions: staff may use staff-only areas). Returns seen[level][idx], occ, problem.
function V.ReachMap(lot)
    local occ, wells, stairs = V.Occupancy(lot)
    local seen = { [0] = {}, [1] = {} }
    local function walk(lv, i, j)
        if not inLot(lot, i, j) then return false end
        local k = idx(lot, i, j)
        if occ[lv][k] then return false end
        if lv > 0 then
            local fl = lot.floor[lv]
            if not (fl and fl[k]) or wells[lv][k] then return false end
        end
        return true
    end
    local e = lot.entry or { math.floor(lot.w / 2), lot.h - 1 }
    if not walk(0, e[1], e[2]) then return seen, occ, "the entrance is blocked" end
    local links = {}
    for _, st in ipairs(stairs) do
        local a = { 0, st.bottom[1], st.bottom[2] }
        local b = { 1, st.top[1], st.top[2] }
        links[0 .. ":" .. a[2] .. ":" .. a[3]] = b
        links[1 .. ":" .. b[2] .. ":" .. b[3]] = a
    end
    local q, head = { { 0, e[1], e[2] } }, 1
    seen[0][idx(lot, e[1], e[2])] = true
    while q[head] do
        local c = q[head]
        head = head + 1
        local lv, i, j = c[1], c[2], c[3]
        for d = 0, 3 do
            local dv = G.DIRS[d]
            local ni, nj = i + dv[1], j + dv[2]
            if walk(lv, ni, nj) and not seen[lv][idx(lot, ni, nj)] and openEdge(lot, lv, i, j, ni, nj) then
                seen[lv][idx(lot, ni, nj)] = true
                q[#q + 1] = { lv, ni, nj }
            end
        end
        local l = links[lv .. ":" .. i .. ":" .. j]
        if l and walk(l[1], l[2], l[3]) and not seen[l[1]][idx(lot, l[2], l[3])] then
            seen[l[1]][idx(lot, l[2], l[3])] = true
            q[#q + 1] = l
        end
    end
    return seen, occ
end

-- Can people reach this object (public slots) and can staff reach its post (staff slots)?
local function objectReach(lot, seen, o, def)
    local lv = o.level or 0
    local s = seen[lv] or {}
    local pub, staff, hasPub, hasStaff = false, false, false, false
    for name, sl in pairs(def.slots or {}) do
        local isStaff = sl.staff or name == "staff"
        if isStaff then hasStaff = true else hasPub = true end
        for _, c in ipairs(V.SlotCells(o, sl)) do
            if inLot(lot, c[1], c[2]) and s[idx(lot, c[1], c[2])] then
                if isStaff then staff = true else pub = true end
            end
        end
    end
    if not hasPub and not hasStaff then
        -- no slots: reachable when a neighbouring cell is, with no wall between
        local fp = {}
        local cells = G.footprint(def, o)
        for _, c in ipairs(cells) do fp[c[1] .. ":" .. c[2]] = true end
        for _, c in ipairs(cells) do
            for d = 0, 3 do
                local dv = G.DIRS[d]
                local ni, nj = c[1] + dv[1], c[2] + dv[2]
                if not fp[ni .. ":" .. nj] and inLot(lot, ni, nj) and s[idx(lot, ni, nj)] and openEdge(lot, lv, c[1], c[2], ni, nj) then pub = true end
            end
        end
        hasPub = true
    end
    local ok = (not hasPub or pub) and (not hasStaff or staff)
    return ok, pub, staff
end

-- Scan a lot: anchors by kind (reachable only), all anchors, unreachable list.
function V.ScanLot(lot)
    local seen, occ, problem = V.ReachMap(lot)
    local rep = { counts = {}, all = {}, anchors = {}, unreachable = {}, problem = problem, seen = seen }
    local tableCells = {}
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and (tagged(def, "cafe_table") or tagged(def, "table_dining")) then
            for _, c in ipairs(G.footprint(def, o)) do tableCells[c[1] .. ":" .. c[2] .. ":" .. (o.level or 0)] = oid end
        end
    end
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def then
            local kinds = V.AnchorKinds(def)
            if def.seat then
                for _, c in ipairs(G.footprint(def, o)) do
                    for d = 0, 3 do
                        local dv = G.DIRS[d]
                        if tableCells[(c[1] + dv[1]) .. ":" .. (c[2] + dv[2]) .. ":" .. (o.level or 0)] then
                            kinds[#kinds + 1] = "dining_seat"
                            break
                        end
                    end
                    if kinds[#kinds] == "dining_seat" then break end
                end
            end
            if #kinds > 0 then
                local ok = objectReach(lot, seen, o, def)
                for _, k in ipairs(kinds) do
                    rep.all[k] = (rep.all[k] or 0) + 1
                    if ok then
                        rep.counts[k] = (rep.counts[k] or 0) + 1
                        rep.anchors[k] = rep.anchors[k] or {}
                        table.insert(rep.anchors[k], oid)
                    end
                end
                if not ok then rep.unreachable[#rep.unreachable + 1] = oid end
            end
        end
    end
    return rep
end

-- Rooms as the sim divides them: regions bounded by any wall edge (doors and fences included);
-- a region that touches the lot border is outdoors (0). Level 0 only (venues are single-storey).
function V.RoomMap(lot)
    local room, walls, n = {}, lot.walls[0] or {}, 0
    for j = 0, lot.h - 1 do
        for i = 0, lot.w - 1 do
            local k0 = idx(lot, i, j)
            if not room[k0] then
                n = n + 1
                local q, head, cells, outside = { { i, j } }, 1, {}, false
                room[k0] = n
                while q[head] do
                    local c = q[head]
                    head = head + 1
                    cells[#cells + 1] = c
                    if c[1] == 0 or c[2] == 0 or c[1] == lot.w - 1 or c[2] == lot.h - 1 then outside = true end
                    for d = 0, 3 do
                        local dv = G.DIRS[d]
                        local ni, nj = c[1] + dv[1], c[2] + dv[2]
                        if inLot(lot, ni, nj) and not room[idx(lot, ni, nj)] and not walls[G.edgeBetween(c[1], c[2], ni, nj)] then
                            room[idx(lot, ni, nj)] = n
                            q[#q + 1] = { ni, nj }
                        end
                    end
                end
                if outside then for _, c in ipairs(cells) do room[idx(lot, c[1], c[2])] = 0 end end
            end
        end
    end
    return room
end

-- A staff-only design (def.staffOnly) closes the room it stands in to customers (the visitors
-- framework's rule). Returns problem strings for staff-only designs sharing an indoor room with
-- something customers must use.
function V.StaffRoomProblems(lot)
    local staffIn, room = {}, nil
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        if def and def.staffOnly and (o.level or 0) == 0 and inLot(lot, o.x, o.y) then
            room = room or V.RoomMap(lot)
            local r = room[idx(lot, o.x, o.y)]
            if r and r > 0 and not staffIn[r] then staffIn[r] = oid end
        end
    end
    if not room then return {} end
    local out, told = {}, {}
    for _, oid in ipairs(sortedKeys(lot.objects)) do
        local o = lot.objects[oid]
        local def = SS.Objects[o.def]
        local r = def and (o.level or 0) == 0 and inLot(lot, o.x, o.y) and room[idx(lot, o.x, o.y)]
        local sid = r and staffIn[r]
        if sid and sid ~= oid and not def.staffOnly and not told[sid] then
            local public = def.seat and true or false
            if not public and #V.AnchorKinds(def) > 0 then
                for name, sl in pairs(def.slots or {}) do if not sl.staff and name ~= "staff" then public = true end end
            end
            if public then
                told[sid] = true
                local sdef = SS.Objects[lot.objects[sid].def]
                out[#out + 1] = string.format("%s is for staff only, and customers are kept out of the room it stands in (with %s). Move it into a kitchen or back room.",
                    sdef.name or sid, def.name or oid)
            end
        end
    end
    return out
end

-- Validate a venue lot against its requirements (Data/Venues.lua VD.required). Accepts a lot, or
-- a root/session plus lot id. Returns ok, problems (strings), report.
function V.Validate(lotOrRoot, lotId)
    local lot = lotOrRoot
    if lotId or (lotOrRoot and lotOrRoot.hood) then
        local root = rootOf(lotOrRoot)
        lot = root.hood and root.hood.lots[lotId]
    end
    if type(lot) ~= "table" then return false, { "That venue lot does not exist." }, {} end
    local kind = V.Kind(lot)
    if not kind then return true, {}, {} end
    local rep = V.ScanLot(lot)
    local problems = {}
    if rep.problem then problems[#problems + 1] = "The entrance is blocked, so nobody can get in." end
    local need = VD.required[kind] or {}
    for _, k in ipairs(sortedKeys(need)) do
        local have = rep.counts[k] or 0
        if have < need[k] then
            local total = rep.all[k] or 0
            local extra = (total > have) and string.format(" (%d more cannot be reached)", total - have) or ""
            local want = V.AnchorCount(need[k], k):gsub("^(%d+) ", "%1 reachable ", 1)
            problems[#problems + 1] = string.format("Needs at least %s; has %d%s.", want, have, extra)
        end
    end
    for _, why in ipairs(V.StaffRoomProblems(lot)) do problems[#problems + 1] = why end
    return #problems == 0, problems, rep
end

-- Validation is a full scan (occupancy, a reachability flood fill, rooms): about 2 ms a venue.
-- The chooser and the hood ask often, so the verdict is cached per lot and recomputed only when
-- something it depends on changes. The key is a cheap fingerprint of those inputs (objects and
-- where they stand, walls and openings, upper floors, the entry, the lot's version): order-free
-- sums over the lot tables, no allocation, so an edit by any path (build, buy, the hood, a direct
-- table write) is noticed without anyone having to invalidate the cache.
local vcache = setmetatable({}, { __mode = "k" })
local function strSig(v)
    if type(v) == "number" then return v end
    local s = type(v) == "string" and v or ""
    local n = #s
    if n == 0 then return 0 end
    return n * 131 + s:byte(1) * 7 + s:byte(n) * 3 + s:byte(math.floor((n + 1) / 2)) * 5
end
local function lotPrint(lot)
    local n, sum = 0, 0
    for id, o in pairs(lot.objects or {}) do
        n = n + 1
        sum = sum + ((o.x or 0) * 7919 + (o.y or 0) * 6007 + (o.level or 0) * 31 + (o.f or 0) * 5 + strSig(o.def) * 13
            + (o.parent and 17 or 0)) * (1 + strSig(id) % 97)
    end
    for lv, walls in pairs(lot.walls or {}) do
        if type(walls) == "table" then
            for key, wl in pairs(walls) do
                n = n + 1
                sum = sum + (strSig(key) + strSig(type(wl) == "table" and wl.kind or nil) * 11) * ((tonumber(lv) or 0) + 2)
            end
        end
    end
    for lv, fl in pairs(lot.floor or {}) do
        if type(fl) == "table" and (tonumber(lv) or 0) > 0 then
            for k in pairs(fl) do n = n + 1; sum = sum + strSig(k) * 3 * (tonumber(lv) or 1) end
        end
    end
    local e = lot.entry
    sum = sum + (e and ((e[1] or 0) * 101 + (e[2] or 0) * 103) or 0) + (lot.w or 0) * 1009 + (lot.h or 0) * 1013 + (lot.version or 0) * 100003
    return n, sum
end
V.LotPrint = lotPrint

-- V.Validate with a per-lot cache. The returned problems/report are shared: read them, never
-- change them.
function V.ValidateCached(lot)
    if type(lot) ~= "table" or not V.Kind(lot) then return V.Validate(lot) end
    local n, sum = lotPrint(lot)
    local c = vcache[lot]
    if c and c.n == n and c.sum == sum then return c.ok, c.problems, c.rep end
    local ok, problems, rep = V.Validate(lot)
    vcache[lot] = { n = n, sum = sum, ok = ok, problems = problems, rep = rep }
    return ok, problems, rep
end

-- The venue's verdict for visits: the lot as it is now. A "needs repairs" record left by an edit
-- is cleared as soon as the lot validates again, whatever repaired it (restored anchors, the save
-- validator, a sibling's edit flow), and refreshed while it does not.
function V.Verdict(root, lotId)
    root = rootOf(root)
    local lot = root.hood and root.hood.lots[lotId]
    local ok, problems = V.ValidateCached(lot)
    local rec = root.venues and root.venues[lotId]
    if rec then
        if ok then rec.invalid = nil
        elseif rec.invalid then rec.invalid = problems end
    end
    return ok, problems
end

---------------------------------------------------------------------------------------------------
-- Venue editing (from neighbourhood management; the hood module sets world.editVenue = true).
-- No household cash is spent (SS.Build.IsFree), the catalogue is filtered, and anchors stay.

-- Buy-mode filter for venue editing: community designs plus ordinary furnishing categories that
-- make sense in a public place (no beds, cribs or pet items). System objects are never sold.
V.COMMUNITY_CATS = { community = true, seating = true, surfaces = true, lighting = true, decor = true, outdoor = true,
    plumbing = true, kitchen = true, skill = true, electronics = true, storage = true }
function V.CatalogFilter(def)
    if type(def) == "string" then def = SS.Objects[def] end
    if not def or def.buyable == false or def.cat == "system" then return false end
    if def.community then return true end
    if def.kidOnly or def.pet then return false end
    return V.COMMUNITY_CATS[def.cat] == true
end
V.IsCommunityItem = V.CatalogFilter

function V.CanEdit(world)
    local lot = world and world.lot
    if not V.Kind(lot) then return false, "Only community venues are edited here." end
    local root = rootOf(world)
    if root.outing and root.outing.lotId == lot.id then return false, "The household is visiting this venue right now; edit it after they go home." end
    if root.travel and root.travel.pending and root.travel.pending.dest == lot.id then return false, "A taxi is on its way to this venue; edit it later." end
    return true
end

-- Would removing (or moving away) this object break the venue? Returns ok, why.
function V.CanRemove(world, obj)
    local lot = world and world.lot
    local kind = V.Kind(lot)
    if not kind or not obj then return true end
    local def = SS.Objects[obj.def]
    local kinds = V.AnchorKinds(def)
    if #kinds == 0 and not (def and def.seat) then return true end
    local _, _, rep = V.ValidateCached(lot)
    local need = VD.required[kind] or {}
    local mine = {}
    for k, list in pairs(rep.anchors or {}) do
        for _, oid in ipairs(list) do if oid == obj.id then mine[k] = true end end
    end
    for _, k in ipairs(sortedKeys(mine)) do
        if need[k] and (rep.counts[k] or 0) - 1 < need[k] then
            return false, string.format("%s needs at least %s; this one is required. Place another first.",
                lot.name or "This venue", V.AnchorCount(need[k], k))
        end
    end
    return true
end

-- Re-add missing staff/service anchors from the venue's template (same place when free, else the
-- nearest spot that fits and is reachable). Returns added count and the remaining problems.
function V.RestoreAnchors(lot)
    local kind = V.Kind(lot)
    if not kind then return 0, {} end
    local ok, problems, rep = V.Validate(lot)
    if ok then return 0, {} end
    local tpl = V.BuildLot(kind, lot.id, lot.address)
    local need = VD.required[kind] or {}
    local tplRep = V.ScanLot(tpl)
    local added = 0
    local function flatOcc()
        local occ = {}
        local o0 = V.Occupancy(lot)
        for k, v in pairs(o0[0]) do occ[k] = v end
        return occ
    end
    local function keepSet()
        local keep = {}
        if lot.entry then keep[idx(lot, lot.entry[1], lot.entry[2])] = true end
        if lot.gather then keep[idx(lot, lot.gather[1], lot.gather[2])] = true end
        for key, wl in pairs(lot.walls[0] or {}) do
            if W.OPENINGS[wl.kind] then
                local _, _, _, ai, aj, bi, bj = G.parseEdge(key)
                if inLot(lot, ai, aj) then keep[idx(lot, ai, aj)] = true end
                if inLot(lot, bi, bj) then keep[idx(lot, bi, bj)] = true end
            end
        end
        return keep
    end
    for _, k in ipairs(sortedKeys(need)) do
        local guard = 0
        while (rep.counts[k] or 0) < need[k] and guard < 12 do
            guard = guard + 1
            local placed = false
            for _, toid in ipairs(tplRep.anchors[k] or {}) do
                if placed then break end
                local to = tpl.objects[toid]
                local def = SS.Objects[to.def]
                local exists = false
                for _, o in pairs(lot.objects) do
                    if o.def == to.def and o.x == to.x and o.y == to.y and (o.level or 0) == 0 then exists = true end
                end
                if not exists and def then
                    local occ, keep = flatOcc(), keepSet()
                    for r = 0, 6 do
                        if placed then break end
                        for dy = -r, r do
                            if placed then break end
                            for dx = -r, r do
                                if (math.abs(dx) == r or math.abs(dy) == r) and not placed then
                                    local x, y = to.x + dx, to.y + dy
                                    if CL.Fits(lot, occ, keep, def, x, y, to.f or 0) then
                                        local n = math.max(lot.nextObj or 1, lot.nextId or 1)
                                        while lot.objects["o" .. n] do n = n + 1 end
                                        lot.nextId = n
                                        local o = CL.NewObject(lot, to.def, x, y, to.f or 0)
                                        o.anchor, o.vendor, o.staffRole, o.use, o.restored = to.anchor, to.vendor, to.staffRole, to.use, true
                                        local ok2, _, rep2 = V.Validate(lot)
                                        if (rep2.counts[k] or 0) > (rep.counts[k] or 0) then
                                            placed, rep, added = true, rep2, added + 1
                                        else
                                            lot.objects[o.id] = nil
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if not placed then break end
        end
    end
    lot.version = (lot.version or 1) + 1
    local ok2, remaining = V.Validate(lot)
    if added > 0 then SS.Emit("lotChanged", "venueRestored", lot.id) end
    return added, ok2 and {} or remaining
end

-- The hood calls this when the player leaves venue editing. Records the verdict on the lot:
-- an invalid venue cannot be visited until it is fixed (V.RestoreAnchors or more editing).
function V.EndEdit(world)
    local lot = world and world.lot
    if not V.Kind(lot) then return true, {} end
    local ok, problems = V.Validate(lot)
    local root = rootOf(world)
    root.venues = root.venues or {}
    local rec = root.venues[lot.id] or {}
    root.venues[lot.id] = rec
    rec.edited = root.time
    rec.invalid = (not ok) and problems or nil
    lot.version = (lot.version or 1) + 1
    return ok, problems
end

-- Venue record in the save (visits, staff identities, verdict).
function V.Record(root, lotId)
    root = rootOf(root)
    root.venues = root.venues or {}
    local r = root.venues[lotId]
    if not r then r = { visits = 0, staff = {} }; root.venues[lotId] = r end
    r.staff = r.staff or {}
    r.visits = r.visits or 0
    return r
end

-- Public-lot information for the neighbourhood panel and the destination chooser.
function V.LotInfo(root, lotId)
    root = rootOf(root)
    local lot = root.hood and root.hood.lots[lotId]
    local kind = V.Kind(lot)
    if not kind then return nil end
    local k = VD.kinds[kind]
    local now = root.time or 0
    local ok, problems = V.Verdict(root, lotId)
    local rec = root.venues and root.venues[lotId]
    return {
        id = lotId, kind = kind, name = lot.name or k.name, address = lot.address or k.address, label = k.label,
        desc = k.desc, activities = k.activities, hours = V.HoursText(kind), open = V.IsOpen(kind, now),
        valid = ok, problems = problems, visits = rec and rec.visits or 0,
    }
end

-- Venue lots of the neighbourhood, in kind order then id.
function V.List(root)
    root = rootOf(root)
    local out = {}
    for id, lot in pairs(root.hood and root.hood.lots or {}) do
        if V.Kind(lot) then out[#out + 1] = id end
    end
    local order = {}
    for n, k in ipairs(VD.KIND_ORDER) do order[k] = n end
    table.sort(out, function(a, b)
        local ka, kb = order[root.hood.lots[a].venue] or 9, order[root.hood.lots[b].venue] or 9
        if ka ~= kb then return ka < kb end
        return a < b
    end)
    return out
end

-- Pre-integration convenience: a neighbourhood without community lots gets the four standard
-- venues (the hood module places them on its map when it integrates). Returns ids added.
function V.EnsureLots(root)
    root = rootOf(root)
    if #V.List(root) > 0 then return {} end
    local added = {}
    for _, kind in ipairs(VD.KIND_ORDER) do
        local lot = V.BuildLot(kind)
        if not root.hood.lots[lot.id] then
            root.hood.lots[lot.id] = lot
            added[#added + 1] = lot.id
        end
    end
    return added
end

---------------------------------------------------------------------------------------------------
-- Staff-only areas: a pass hook keeps customers out of kitchens and behind counters. Cached per
-- lot (a flat cell set), cheap inside A*.
local function staffGrid(lot, level)
    local so = lot.staffOnly
    if type(so) ~= "table" then return nil end
    local cells = so[level or 0]
    if type(cells) ~= "table" or next(cells) == nil then return nil end
    return cells
end
V.StaffGrid = staffGrid

function V.IsStaff(actor) return actor and actor.role and V.IS_STAFF_ROLE[actor.role] == true end

W.RegisterPassHook(function(world, level, i, j, ni, nj, wall, who)
    if not who then return end
    local lot = world.lot
    if not lot.staffOnly then return end
    local cells = staffGrid(lot, level)
    if not cells then return end
    if cells[idx(lot, ni, nj)] and not cells[idx(lot, i, j)] and not V.IsStaff(who) then return false end
end)

---------------------------------------------------------------------------------------------------
-- Interaction variants: catalogue anchors may name their slots differently from the outings
-- system objects. V.IidFor(def, iid) returns iid when the definition has the interaction's slot
-- (name or group), else a lazily made copy using the definition's first public slot.
local variants = {}
local function hasSlot(def, name)
    local slots = def and def.slots or {}
    if slots[name] then return true end
    for _, s in pairs(slots) do if s.group == name then return true end end
    return false
end
V.HasSlot = hasSlot

function V.IidFor(def, iid)
    local ia = SS.Interactions[iid]
    if not ia or not def then return iid end
    if not ia.slot or ia.slot == "viewer" or ia.targetActor or hasSlot(def, ia.slot) then return iid end
    local pick
    for _, name in ipairs(sortedKeys(def.slots)) do
        local s = def.slots[name]
        if not s.staff and name ~= "staff" then pick = s.group or name; break end
    end
    if not pick then return iid end
    local vid = iid .. "@" .. pick
    if not SS.Interactions[vid] then
        local copy = {}
        for k, v in pairs(ia) do copy[k] = v end
        copy.slot, copy.variantOf = pick, iid
        SS.Interactions[vid] = copy
        variants[vid] = true
    end
    return vid
end

function V.BaseIid(iid)
    local ia = SS.Interactions[iid]
    return ia and ia.variantOf or iid
end

-- Does this definition offer the interaction (itself or a slot variant of it)?
function V.Supports(def, iid)
    local base = V.BaseIid(iid)
    for _, a in ipairs(def and def.actions or {}) do
        if a == base or V.BaseIid(a) == base then return true end
    end
    return false
end

-- Swap outings interactions on a definition for the variant matching its slots, so menus and
-- autonomy offer an interaction the executor can resolve. Idempotent; dedupes.
function V.FixActions(def)
    if not def or not def.actions or not def.slots then return end
    local out, seen, changed = {}, {}, false
    for _, a in ipairs(def.actions) do
        local ia = SS.Interactions[a]
        local use = a
        if ia and ia.outings and not ia.variantOf then use = V.IidFor(def, a) end
        if use ~= a then changed = true end
        if not seen[use] then seen[use] = true; out[#out + 1] = use else changed = true end
    end
    if changed then
        -- a base id re-added by a later tag attach is dropped when its variant is present
        local final = {}
        for _, a in ipairs(out) do
            local ia = SS.Interactions[a]
            if not (ia and ia.outings and not ia.variantOf and seen[V.IidFor(def, a)] and V.IidFor(def, a) ~= a) then final[#final + 1] = a end
        end
        def.actions = final
    end
end

function V.FixAllActions()
    for _, id in ipairs(sortedKeys(SS.Objects)) do V.FixActions(SS.Objects[id]) end
end

---------------------------------------------------------------------------------------------------
-- Runtime scan of the live venue (cached on the session until the lot changes).
local lotEpoch = 0
SS.On("lotChanged", function(kind) if kind ~= "state" then lotEpoch = lotEpoch + 1 end end)
SS.On("worldAttached", function() lotEpoch = lotEpoch + 1; V.FixAllActions() end)
function V.Invalidate() lotEpoch = lotEpoch + 1 end

function V.RT(world)
    local rt = rawget(world, "_venueRT")
    if rt and rt.epoch == lotEpoch and rt.lotVer == world.lot.version then return rt end
    local rep = V.ScanLot(world.lot)
    rt = { epoch = lotEpoch, lotVer = world.lot.version, rep = rep, anchors = rep.anchors, staffPosts = {}, byVendor = {}, regByVendor = {} }
    -- staff posts: one staff member per staff anchor, numbered per role in object order
    local perRole = {}
    for _, oid in ipairs(sortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def then
            for _, k in ipairs(V.AnchorKinds(def)) do
                local role = V.ROLE_BY_ANCHOR[k]
                if role then
                    perRole[role] = (perRole[role] or 0) + 1
                    rt.staffPosts[#rt.staffPosts + 1] = { role = role, n = perRole[role], oid = oid }
                end
            end
        end
    end
    -- vendors: displays by vendor; each vendor's till (o.vendor match, else same room, else nearest)
    for _, oid in ipairs(sortedKeys(world.lot.objects)) do
        local o = world.lot.objects[oid]
        local def = SS.Objects[o.def]
        if def then
            for tag, vendor in pairs(VD.displayVendor) do
                if tagged(def, tag) then
                    rt.byVendor[vendor] = rt.byVendor[vendor] or {}
                    table.insert(rt.byVendor[vendor], oid)
                end
            end
        end
    end
    for _, vendor in ipairs(VD.VENDOR_ORDER) do rt.byVendor[vendor] = rt.byVendor[vendor] or {} end
    local regs = rt.anchors.register or {}
    for _, vendor in ipairs(VD.VENDOR_ORDER) do
        local pick
        for _, rid in ipairs(regs) do if world.lot.objects[rid].vendor == vendor then pick = rid end end
        if not pick and #rt.byVendor[vendor] > 0 and #regs > 0 then
            local d0 = world.lot.objects[rt.byVendor[vendor][1]]
            local best, bd
            for _, rid in ipairs(regs) do
                local r = world.lot.objects[rid]
                local d = math.abs(r.x - d0.x) + math.abs(r.y - d0.y)
                if W.RoomAt and SS.RT and SS.RT.room and W.RoomAt(world, 0, r.x, r.y) == W.RoomAt(world, 0, d0.x, d0.y) then d = d - 100 end
                if not bd or d < bd then best, bd = rid, d end
            end
            pick = best
        end
        rt.regByVendor[vendor] = pick
    end
    -- the till's vendor (the first in vendor order when two vendors share a till)
    rt.vendorByReg = {}
    for _, vendor in ipairs(VD.VENDOR_ORDER) do
        local r = rt.regByVendor[vendor]
        if r and not rt.vendorByReg[r] then rt.vendorByReg[r] = vendor end
    end
    rawset(world, "_venueRT", rt)
    return rt
end

function V.Anchors(world, kind)
    return V.RT(world).anchors[kind] or {}
end

---------------------------------------------------------------------------------------------------
-- Walking helper for NPCs: bounded route attempts with a path pre-check (no notice spam).
-- Returns "arrived" | "moving" | "busy" | "waiting" | "blocked".
function V.PathTo(world, actor, goals)
    local si, sj = cellOf(actor)
    local ok, path, why = pcall(SS.Nav.FindPath, world, si, sj, actor.level or 0, goals, actor)
    if not ok then return nil, "error" end
    return path, why
end

function V.Walk(world, actor, i, j, level, key)
    actor.tmp = actor.tmp or {}
    local tmp = actor.tmp
    local lv = level or 0
    local ci, cj = cellOf(actor)
    if ci == i and cj == j and (actor.level or 0) == lv then
        tmp.walk = nil
        return "arrived"
    end
    local wk = tmp.walk
    if wk and (wk.i ~= i or wk.j ~= j or wk.key ~= key) then wk = nil end
    if not wk then wk = { i = i, j = j, key = key, tries = 0, next = 0 }; tmp.walk = wk end
    if actor.act and actor.act.iid == "goto" then return "moving" end
    if actor.act or (actor.queue and #actor.queue > 0) then return "busy" end
    if wk.tries >= T.staffRetries then return "blocked" end
    if world.time < wk.next then return "waiting" end
    local path, why = V.PathTo(world, actor, { { i, j, lv } })
    wk.next = world.time + T.staffRetryGap
    if not path then
        if why == "budget" then wk.next = world.time; return "waiting" end
        wk.tries = wk.tries + 1
        return wk.tries >= T.staffRetries and "blocked" or "waiting"
    end
    wk.tries = wk.tries + 1
    SS.Actions.Order(world, actor, nil, "goto", i, j, { level = lv })
    return "moving"
end

function V.ResetWalk(actor) if actor.tmp then actor.tmp.walk = nil end end

-- Order an object interaction for an NPC after checking it is available and reachable.
function V.TryUse(world, actor, oid, iid, data)
    local o = world.lot.objects[oid]
    if not o then return false, "gone" end
    local def = SS.Objects[o.def]
    if not V.Supports(def, iid) then return false, "not offered here" end
    iid = V.IidFor(def, iid)
    local ok, why = SS.Actions.Available(world, actor, o, iid)
    if not ok then return false, why end
    local tgt = SS.Actions.ResolveSlot(world, actor, o, iid)
    if tgt and tgt.approaches then
        local path, pwhy = V.PathTo(world, actor, tgt.approaches)
        if not path then return false, pwhy or "unreachable" end
    end
    SS.Actions.Order(world, actor, oid, iid, nil, nil, data and { data = data } or nil)
    return true
end

-- Free cell near (i, j) that is standable (for waiting spots).
function V.FreeNear(world, i, j, level, maxR)
    for r = 0, maxR or 4 do
        for dy = -r, r do
            for dx = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local x, y = i + dx, j + dy
                    if inLot(world.lot, x, y) and not W.Blocked(world, level or 0, x, y) then return x, y end
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Staff: stable venue-role identities. One record per venue post, created once and reused on every
-- visit (root.residents, npc = "staff"); they are only on the lot while the household visits.
local function copy3(c) return { c[1], c[2], c[3] } end

function V.StaffRecord(root, lot, role, n)
    root = rootOf(root)
    local rid = string.format("staff_%s_%s_%d", lot.id, role, n)
    local r = root.residents[rid]
    if r then return r end
    local sd = VD.staff[role]
    local names = sd.names
    local name = names[((n - 1) % #names) + 1]
    if n > #names then name = name .. " " .. string.char(64 + math.floor((n - 1) / #names) + 1) .. "." end
    local h = 7
    for c in rid:gmatch(".") do h = (h * 31 + c:byte()) % 99991 end
    local L = VD.STAFF_LOOKS[(h % #VD.STAFF_LOOKS) + 1]
    local uni = sd.uniform
    local skills = {}
    for k, v in pairs(sd.skills or {}) do skills[k] = v end
    r = {
        id = rid, name = name, npc = "staff", staffOf = lot.id, staffRole = role, kind = "human", age = "adult", pronoun = "they",
        look = { skin = copy3(L.skin), hair = copy3(L.hair), hairStyle = L.hairStyle, body = "average", face = (h % 4) + 1,
            top = copy3(uni.top), bottom = copy3(uni.bottom), shoes = copy3(uni.shoes),
            outfits = { work = { style = "uniform_" .. role, top = copy3(uni.top), bottom = copy3(uni.bottom), shoes = copy3(uni.shoes) } } },
        outfit = "work", personality = { neat = 6, outgoing = 6, active = 5, playful = 4, nice = 7 }, interests = {},
        needs = { hunger = 60, energy = 60, bladder = 60, hygiene = 60, fun = 40, social = 40, comfort = 40, room = 0 },
        skills = skills, memories = {}, x = 0.5, y = 0.5, level = 0, facing = 0,
        bio = string.format("%s at %s.", sd.label, lot.name or "the venue"),
    }
    root.residents[rid] = r
    local rec = V.Record(root, lot.id)
    rec.staff[role .. "#" .. n] = rid
    return r
end

-- Put every staff member on duty at their post (idempotent). Closed venues keep them away.
function V.StaffOnDuty(world)
    local o = V.Active(world)
    if not o then return end
    local rt = V.RT(world)
    o.staff = o.staff or {}
    for _, post in ipairs(rt.staffPosts) do
        local r = V.StaffRecord(world.root, world.lot, post.role, post.n)
        local anchor = world.lot.objects[post.oid]
        local def = anchor and SS.Objects[anchor.def]
        if def and not world.actors[r.id] and not r.dead then
            local cells = V.StaffCells(anchor, def)
            local ci, cj
            for _, c in ipairs(cells) do
                if not ci and inLot(world.lot, c[1], c[2]) and not W.Blocked(world, c[3] or 0, c[1], c[2]) then ci, cj = c[1], c[2] end
            end
            if not ci then ci, cj = V.FreeNear(world, anchor.x, anchor.y, anchor.level or 0, 4) end
            if ci then
                local a = SS.Sim.AddActor(world, r.id, ci, cj, anchor.level or 0)
                if a then
                    a.role, a.noNeeds = post.role, true
                    a.roleData = { anchor = post.oid, n = post.n, post = { ci, cj, anchor.level or 0 }, vs = V.RoleState(world, nil) }
                    a.away = nil
                    a.outfit = "work"
                    o.staff[post.role .. "#" .. post.n] = r.id
                end
            end
        elseif world.actors[r.id] then
            local a = world.actors[r.id]
            a.role, a.noNeeds = post.role, true
            a.roleData = a.roleData or {}
            a.roleData.anchor, a.roleData.n = post.oid, post.n
            o.staff[post.role .. "#" .. post.n] = r.id
        end
    end
end

-- Take one staff member off the lot (end of shift or end of visit).
function V.StaffOff(world, rid)
    local a = world.actors[rid]
    if not a then return end
    SS.Sim.RemoveActor(world, rid, nil)
    a.role, a.roleData, a.noNeeds, a.away = nil, nil, nil, nil
    a.lotId = nil
    local o = rootOf(world).outing
    if o and o.staff then for k, v in pairs(o.staff) do if v == rid then o.staff[k] = nil end end end
end

-- The staff member working a role (first on duty and at their post if possible).
function V.StaffFor(world, role, anchorOid)
    local best
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a.role == role and (not anchorOid or (a.roleData and a.roleData.anchor == anchorOid)) then
            if not best then best = a end
            if V.AtPost(world, a) then return a end
        end
    end
    return best
end

function V.AtPost(world, a)
    local p = a and a.roleData and a.roleData.post
    if not p then return false end
    local i, j = cellOf(a)
    return i == p[1] and j == p[2] and (a.level or 0) == (p[3] or 0) and not (a.act and a.act.iid == "goto")
end

-- Face the anchor while standing at the post.
local function faceAnchor(world, a)
    local o = a.roleData and world.lot.objects[a.roleData.anchor]
    if o then a.facing = G.dirToFacing(o.x + 0.5 - a.x, o.y + 0.5 - a.y) end
end

V.roleBrains = {}

-- Visitors-framework hooks for the outings roles. The framework state (roleData.vs) is created by
-- this module with no timeout, so the framework only runs the role's tick ("task" state); after a
-- load the outings module repairs its own actors ("keep"). If another module sends one of them away
-- through SS.Visitors.Leave, RoleLeft records it and the person is returned to their own home.
local leaveHomes = {}
function V.KeepRole() return "keep" end
function V.RoleLeft(world, a, why)
    local rd = a and a.roleData
    if not rd then return end
    if rd.home then
        leaveHomes[a.id] = { lotId = rd.home.lotId, x = rd.home.x, y = rd.home.y, level = rd.home.level, facing = rd.home.facing,
            noNeeds = rd.prevNoNeeds }
    end
    local o = V.Active(world)
    for _, g in ipairs(o and o.guests or {}) do
        if g.rid == a.id and g.state == "here" then g.state, g.leftAt, g.why = "left", world.time, why or "left" end
    end
    if SS.Dining and SS.Dining.MemberGone then SS.Dining.MemberGone(world, a.id, "left") end
end
SS.On("actorRemoved", function(world, r)
    local h = r and leaveHomes[r.id]
    if not h then return end
    leaveHomes[r.id] = nil
    r.lotId, r.x, r.y, r.level, r.facing = h.lotId, h.x, h.y, h.level or 0, h.facing or 0
    r.noNeeds = h.noNeeds or nil
end)

-- Framework state for a role actor placed by this module (see above).
function V.RoleState(world, home)
    return { state = "task", since = world.time, mode = "none", onLot = true, invitedIn = true, tries = 0,
        home = { lotId = home and home.lotId or nil } }
end

-- Shared staff tick: stay at the post while open, walk out at closing, then role-specific work.
function V.StaffTick(world, a, dt)
    local out = V.Active(world)
    if not out then return end
    a.roleData = a.roleData or {}
    local rd = a.roleData
    if rd.leaving then
        local i, j = SS.Street.EntryCell(world)
        local st = V.Walk(world, a, i, j, 0, "leave")
        if st == "arrived" or st == "blocked" then V.StaffOff(world, a.id) end
        return
    end
    local brain = V.roleBrains[a.role]
    if brain and brain(world, a, dt) then return end
    -- default: return to the post and stand ready
    local p = rd.post
    if not p then return end
    if a.act or (a.queue and #a.queue > 0) then return end
    local st = V.Walk(world, a, p[1], p[2], p[3] or 0, "post")
    if st == "arrived" then
        faceAnchor(world, a)
        if a.pose ~= "use" then a.pose = "idle" end
        rd.blocked = nil
    elseif st == "blocked" then
        if not rd.blocked then
            rd.blocked = true
            V.Log(world, string.format("%s (%s) can't reach the post.", a.name, VD.staff[a.role] and VD.staff[a.role].label or a.role))
        end
    end
end

for _, role in ipairs(V.STAFF_ROLES) do
    SS.Visitors.RegisterRole(role, { label = VD.staff[role].label, tick = V.StaffTick, useAutonomy = false, noNeeds = true,
        access = "staff", staff = true, arrive = "none", reconcile = V.KeepRole, onLeave = V.RoleLeft })
end

---------------------------------------------------------------------------------------------------
-- Eligibility: the same persistent people, never dead, away or somewhere else.
local function atOwnHome(root, r)
    if not r.lotId then return true end
    local hh = r.householdId and root.households[r.householdId]
    return hh and hh.lotId == r.lotId
end

-- Can resident r (not in the visiting household) come to the venue? Returns ok, why.
-- opts.rideAlong: they are visiting the household right now and will ride in the taxi with it.
function V.CanVisit(world, r, forKind, opts)
    local root = rootOf(world)
    if not r then return false, "Nobody by that name." end
    if r.dead or r.ghost then return false, r.name .. " has passed away." end
    if r.npc or r.staffOf then return false, r.name .. " is working." end
    if (r.kind or "human") ~= "human" then return false, "Pets stay home." end
    if r.age == "infant" then return false, "Babies don't go out on their own." end
    if forKind == "club" and r.age == "child" then return false, "The club is for grown-ups." end
    if opts and opts.rideAlong then
        if root.active and r.lotId == root.active.lotId then return true end
        return false, r.name .. " isn't here to ride along."
    end
    if r.away then return false, r.name .. " is out (" .. tostring(r.away.reason or "away") .. ")." end
    if r.role then return false, r.name .. " is busy visiting somewhere." end
    if root.active and r.lotId and r.lotId == root.active.lotId then return false, r.name .. " is at your place right now." end
    if not atOwnHome(root, r) then return false, r.name .. " is somewhere else." end
    return true
end

local function homeOf(r)
    return { lotId = r.lotId, x = r.x, y = r.y, level = r.level or 0, facing = r.facing or 0 }
end

-- Bring a non-household resident onto the venue as `role`, remembering where they were.
function V.BringIn(world, rid, role, data)
    local root = rootOf(world)
    local r = root.residents[rid]
    local ok = V.CanVisit(world, r)
    if not ok then return nil end
    local home = homeOf(r)
    local i, j = SS.Street.EntryCell(world)
    local a = SS.Sim.AddActor(world, rid, i, j, 0)
    if not a then return nil end
    a.role = role
    a.roleData = data or {}
    a.roleData.home = home
    a.roleData.prevNoNeeds = a.noNeeds and true or false
    a.roleData.vs = V.RoleState(world, home)
    a.away = nil
    return a
end

-- Send a visitor back to where they came from (their own home lot, frozen there).
function V.SendHome(world, a)
    local rd = a.roleData or {}
    local home = rd.home
    local prev = rd.prevNoNeeds
    SS.Sim.RemoveActor(world, a.id, nil)
    a.role, a.roleData, a.away = nil, nil, nil
    a.noNeeds = prev or nil
    if home then
        a.lotId, a.x, a.y, a.level, a.facing = home.lotId, home.x, home.y, home.level or 0, home.facing or 0
    else
        a.lotId = nil
    end
    a.pose, a.carry = "idle", nil
end

-- Walk out, then go home. Bounded: after the retries they are sent home from where they stand.
local function leaveTick(world, a)
    local i, j = SS.Street.EntryCell(world)
    local st = V.Walk(world, a, i, j, 0, "leave")
    if st == "arrived" or st == "blocked" then V.SendHome(world, a) end
end
V.LeaveTick = leaveTick

---------------------------------------------------------------------------------------------------
-- Patrons: a capped trickle of townies and neighbours, chosen deterministically.
function V.PatronCount(world)
    local n = 0
    for _, a in pairs(world.actors) do if a.role == "venue_patron" then n = n + 1 end end
    return n
end

function V.ActorCount(world)
    local n = 0
    for _ in pairs(world.actors) do n = n + 1 end
    return n
end

function V.PatronCandidates(world)
    local root = rootOf(world)
    local o = root.outing
    local kind = V.Kind(world.lot)
    local party = {}
    for _, rid in ipairs(o and o.participants or {}) do party[rid] = true end
    for _, g in ipairs(o and o.guests or {}) do party[g.rid] = true end
    local list = {}
    for _, rid in ipairs(sortedKeys(root.residents)) do
        local r = root.residents[rid]
        if not party[rid] and not world.actors[rid] and r.householdId ~= (world.household and world.household.id)
            and not (o and o.seen and o.seen[rid]) and V.CanVisit(world, r, kind) then
            list[#list + 1] = rid
        end
    end
    return list
end

function V.SpawnPatron(world)
    local o = V.Active(world)
    local kind = V.Kind(world.lot)
    local cap = VD.kinds[kind].patronCap or 3
    if V.PatronCount(world) >= cap or V.ActorCount(world) >= T.crowdCap then return nil, "full" end
    local list = V.PatronCandidates(world)
    if #list == 0 then return nil, "nobody" end
    local rid = SS.Pick(world, "outings.patron", list)
    local stay = SS.RandomInt(world, "outings.patron", T.patronStay[1], T.patronStay[2])
    local a = V.BringIn(world, rid, "venue_patron", { leaveAt = world.time + stay, nextAt = world.time + 1 })
    if a then
        a.noNeeds = true
        o.seen = o.seen or {}
        o.seen[rid] = true
        o.patronsSeen = (o.patronsSeen or 0) + 1
    end
    return a
end

-- Activities a patron may pick at each venue kind (interaction ids on anchor kinds).
V.PATRON_ACTIVITIES = {
    shops = { { "display_clothing", "shop_browse" }, { "display_gift", "shop_browse" }, { "display_books", "shop_browse" },
        { "display_decor", "shop_browse" }, { "seating", "people_watch" }, { "fountain", "venue_admire" } },
    cafe = { { "podium", "dine" }, { "seating", "people_watch" } },
    park = { { "seating", "people_watch" }, { "recreation", "venue_chess" }, { "recreation", "venue_play" },
        { "fountain", "venue_admire" } },
    club = { { "dance", "venue_dance" }, { "bar", "bar_drink" }, { "games", "venue_pool" }, { "games", "venue_darts" },
        { "party", "venue_mingle" }, { "seating", "sit" } },
}

function V.PatronTick(world, a, dt)
    local out = V.Active(world)
    local rd = a.roleData or {}
    a.roleData = rd
    if not out then return end
    if rd.leaving then leaveTick(world, a); return end
    local kind = V.Kind(world.lot)
    if world.time >= (rd.leaveAt or 0) or out.closing or not V.IsOpen(kind, world.time) then
        if SS.Dining and SS.Dining.PartyOf and SS.Dining.PartyOf(world, a.id) then
            if not rd.askedBill then rd.askedBill = true; SS.Dining.LeaveParty(world, a.id, "time") end
            return
        end
        rd.leaving = true
        if a.act then SS.Actions.Cancel(world, a, 0) end
        return
    end
    if a.act or (a.queue and #a.queue > 0) then return end
    if world.time < (rd.nextAt or 0) then return end
    rd.nextAt = world.time + T.patronActivityGap * (0.5 + SS.Random(world, "outings.patron"))
    local acts = V.PATRON_ACTIVITIES[kind] or {}
    if #acts == 0 then return end
    local start = SS.RandomInt(world, "outings.patron", 1, #acts)
    for k = 0, #acts - 1 do
        local pick = acts[((start + k - 1) % #acts) + 1]
        if pick[2] == "dine" then
            if SS.Dining and SS.Dining.PatronDine and SS.Dining.PatronDine(world, a) then return end
        else
            local list = V.Anchors(world, pick[1])
            if #list > 0 then
                local n0 = SS.RandomInt(world, "outings.patron", 1, #list)
                for m = 0, #list - 1 do
                    local oid = list[((n0 + m - 1) % #list) + 1]
                    if V.TryUse(world, a, oid, pick[2]) then return end
                end
            end
        end
    end
end

SS.Visitors.RegisterRole("venue_patron", { label = "Patron", tick = V.PatronTick, useAutonomy = false, noNeeds = true, access = "public",
    arrive = "none", reconcile = V.KeepRole, onLeave = V.RoleLeft })

---------------------------------------------------------------------------------------------------
-- Guests: an invited friend or date partner meets the party at the venue (or never turns up).
function V.GuestTick(world, a, dt)
    local out = V.Active(world)
    local rd = a.roleData or {}
    a.roleData = rd
    if not out then return end
    if rd.leaving then leaveTick(world, a); return end
    -- stay close to the host now and then (a date is spent together)
    local host = rd.with and world.actors[rd.with]
    if host and not a.act and (not a.queue or #a.queue == 0) and world.time >= (rd.nextFollow or 0) then
        rd.nextFollow = world.time + 12
        local d = math.abs(host.x - a.x) + math.abs(host.y - a.y)
        if d > 4 then
            local fi, fj = V.FreeNear(world, math.floor(host.x), math.floor(host.y), host.level or 0, 2)
            if fi then V.Walk(world, a, fi, fj, host.level or 0, "follow") end
        end
    end
end

SS.Visitors.RegisterRole("outing_guest", { label = "Guest", tick = V.GuestTick, useAutonomy = true, noNeeds = false, access = "guest",
    arrive = "none", reconcile = V.KeepRole, onLeave = V.RoleLeft })

-- Acceptance of an invitation (deterministic roll; warmer relationships accept more often).
function V.InviteRoll(world, hostRid, guestRid)
    local rel = 0
    if SS.Social and SS.Social.Rel then
        local r = SS.Social.Rel(world, guestRid, hostRid)
        rel = (r.daily or 0) * 0.6 + (r.life or 0) * 0.4
    end
    local p = U.clamp(0.45 + rel / 120, 0.1, 0.95)
    local roll = SS.Random(world, "outings.guest")
    local accepted = roll < p
    local stoodUp = accepted and rel < 10 and SS.Random(world, "outings.guest") < 0.12
    return accepted, stoodUp, p
end

-- Guests arrive on schedule (outing clock), bounded by the crowd cap.
function V.GuestArrivals(world)
    local out = V.Active(world)
    for _, g in ipairs(out.guests or {}) do
        if g.state == "coming" and world.time >= (g.arriveAt or 0) then
            local r = world.root.residents[g.rid]
            local ok, why = V.CanVisit(world, r)
            if ok and V.ActorCount(world) < T.crowdCap then
                local a = V.BringIn(world, g.rid, "outing_guest", { with = g.with, date = g.date })
                if a then
                    g.state, g.arrivedAt = "here", world.time
                    if out.date and out.date.with == g.rid and not out.date.ended then
                        out.date.state, out.date.startedAt = "on", world.time
                        a.roleData.date = true
                    end
                    out.seen = out.seen or {}
                    out.seen[g.rid] = true
                    local ax, ay = world.lot.gather and world.lot.gather[1], world.lot.gather and world.lot.gather[2]
                    if ax then V.Walk(world, a, ax, ay, 0, "arrive") end
                    V.Say(world, a, "greet_guest", { name = world.root.residents[g.with] and world.root.residents[g.with].name or "" })
                    V.Log(world, a.name .. " arrived.")
                else
                    g.state = "declined"
                end
            else
                g.state = "declined"
                V.Notice(world, (r and r.name or "Your guest") .. " couldn't make it after all: " .. (why or "the venue is full") .. ".")
            end
        elseif g.state == "stood_up" and not g.noticed and world.time >= (g.arriveAt or 0) + 30 then
            g.noticed = true
            local host = world.actors[g.with]
            local r = world.root.residents[g.rid]
            if host then V.Say(world, host, "date_stood_up", { name = r and r.name or "", venue = world.lot.name }) end
            V.ScoreEvent(world, "stood_up", -30, { g.with })
            V.Log(world, (r and r.name or "The guest") .. " never showed up.")
            if out.date and out.date.with == g.rid then
                out.date.state, out.date.ended = "stood_up", world.time
                SS.Emit("dateEnded", world, out.date, "stood_up")
            end
        end
    end
end

-- A guest leaves early (a date gone wrong, or the host went home first).
function V.GuestLeave(world, rid, why)
    local out = V.Active(world)
    local a = world.actors[rid]
    if not a then return end
    a.roleData = a.roleData or {}
    a.roleData.leaving = true
    if a.act then SS.Actions.Cancel(world, a, 0) end
    for _, g in ipairs(out and out.guests or {}) do if g.rid == rid then g.state, g.leftAt, g.why = "left", world.time, why end end
    if SS.Dining and SS.Dining.MemberGone then SS.Dining.MemberGone(world, rid, "left") end
end

---------------------------------------------------------------------------------------------------
-- Outing and date score: a stateful 0..100 value (starting at 50) moved only by what happens:
--   * engagement events: activities (together counts more; the same activity repeated counts less
--     each time), conversation (social exchanges and social actions between party members, table
--     talk, the date pair's relationship change), meals, purchases, gifts and rounds;
--   * conditions: comfort (average mood) and company (the date pair near each other) count only
--     while the outing is engaged, i.e. within T.engagedWindow minutes of something actually done,
--     and each is capped per outing (T.factorCap). Misery (critical needs, a low mood) always counts;
--   * waiting (queues, tables, food), a stood-up date, a bill the household couldn't cover;
--   * boredom: with nothing done for T.engagedWindow minutes the score drifts down to T.boredFloor.
-- Sitting about for hours therefore never makes an outing good; doing things together does.
local function clampScore(v) return U.clamp(v, 0, 100) end

local function sortedIds(list)
    local out = {}
    for _, a in ipairs(list) do out[#out + 1] = a.id end
    table.sort(out)
    return out
end
V.SortedIds = sortedIds

local function inParty(o, rid)
    for _, id in ipairs(o.participants or {}) do if id == rid then return true end end
    for _, g in ipairs(o.guests or {}) do if g.rid == rid and g.state == "here" then return true end end
    return false
end
V.InParty = inParty

-- Kinds that count as something actually done (they refresh the engagement clock).
V.ENGAGE = { activities = true, conversation = true, meal = true, shopping = true, gift = true, group = true }

-- Add `amount` to one factor of a score record (the outing, or the date), within the factor's cap.
local function addFactor(rec, kind, amount)
    rec.factors = rec.factors or {}
    local have = rec.factors[kind] or 0
    local cap = T.factorCap and T.factorCap[kind]
    if cap then
        if amount > 0 and cap[2] then amount = math.max(0, math.min(amount, cap[2] - have)) end
        if amount < 0 and cap[1] then amount = math.min(0, math.max(amount, cap[1] - have)) end
    end
    if amount == 0 then return 0 end
    rec.factors[kind] = have + amount
    rec.score = clampScore((rec.score or 50) + amount)
    return amount
end

-- amount applies to the outing score; the date score changes when a date member is involved.
-- rids: the people involved (a date is "engaged" when both of the pair are among them).
-- opts.passive: a measurement, not an engagement (the relationship drift of the date pair).
function V.ScoreEvent(world, kind, amount, rids, opts)
    local o = rootOf(world).outing
    if not o then return end
    local engage = V.ENGAGE[kind] and not (opts and opts.passive)
    addFactor(o, kind, amount)
    if engage then o.engagedAt = world.time end
    local d = o.date
    if d and not d.ended then
        local by, with = false, false
        for _, rid in ipairs(rids or {}) do
            if rid == d.by then by = true end
            if rid == d.with then with = true end
        end
        if by or with then addFactor(d, kind, amount) end
        if engage and by and with then d.engagedAt = world.time end
    end
end

-- Bounded relationship bumps between two people on this outing (no farming).
function V.RelBump(world, aId, bId, amount)
    local o = rootOf(world).outing
    if not o or aId == bId or not (SS.Social and SS.Social.Change) then return end
    o.rel = o.rel or {}
    local key = aId .. ">" .. bId
    local got = o.rel[key] or 0
    local cap = 14
    if amount > 0 then amount = math.min(amount, cap - got) end
    if amount == 0 then return end
    o.rel[key] = got + amount
    SS.Social.Change(world, aId, bId, amount, amount * 0.25)
    SS.Social.Change(world, bId, aId, amount, amount * 0.25)
end

local function relDaily(world, a, b)
    if not (SS.Social and SS.Social.Rel) then return 0 end
    return SS.Social.Rel(world, a, b).daily or 0
end

-- What someone is doing that counts as taking part (nil when idle): an activity, a meal, shopping,
-- or a conversation. Walking to it does not count; only performing.
local ENGAGING_CATS = { Social = true, Romance = true }
function V.EngagedIn(a)
    local act = a and a.act
    if not act or not act.performed then return nil end
    local ia = SS.Interactions[act.iid]
    if not ia then return nil end
    local base = V.BaseIid(act.iid)
    if ia.venueActivity or ia.leisure or ia.dining or ia.shopping or (ia.targetActor and ENGAGING_CATS[ia.category]) then return base end
    return nil
end

-- Are the two date partners doing something together right now (the same activity with each
-- other, at the same table, or talking to each other)?
local function togetherNow(world, a, b)
    local ea, eb = V.EngagedIn(a), V.EngagedIn(b)
    if not ea or not eb then return false end
    if (a.act.tid == b.id) or (b.act.tid == a.id) then return true end
    if a.act.data and a.act.data.withDate and b.act.data and b.act.data.withDate then return true end
    local Dn = SS.Dining
    if Dn and Dn.PartyOf then
        local pa = Dn.PartyOf(world, a.id)
        if pa and pa == Dn.PartyOf(world, b.id) and pa.present and pa.present[a.id] and pa.present[b.id] then return true end
    end
    return false
end
V.TogetherNow = togetherNow

-- Periodic evaluation (every T.scoreEvery minutes).
local present = {}
function V.ScoreTick(world)
    local o = V.Active(world)
    if not o then return end
    local now = world.time
    for n = #present, 1, -1 do present[n] = nil end
    for _, rid in ipairs(o.participants or {}) do
        local a = world.actors[rid]
        if a then present[#present + 1] = a end
    end
    for _, g in ipairs(o.guests or {}) do
        local a = g.state == "here" and world.actors[g.rid]
        if a then present[#present + 1] = a end
    end
    local moodSum, n = 0, 0
    for _, a in ipairs(present) do
        moodSum, n = moodSum + SS.Needs.Mood(a), n + 1
        for _, need in ipairs(SS.Tuning.needs) do
            if need ~= "room" and (a.needs[need] or 0) < -60 then V.ScoreEvent(world, "needs", -2, { a.id }) end
        end
        -- someone in the middle of an activity, a meal or a chat keeps the outing engaged
        if V.EngagedIn(a) then o.engagedAt = now end
    end
    local win = T.engagedWindow or 30
    local engaged = o.engagedAt and now - o.engagedAt < win
    if n > 0 then
        local avg = moodSum / n
        if avg > 30 then
            if engaged then V.ScoreEvent(world, "comfort", 2, nil) end
        elseif avg < -20 then
            V.ScoreEvent(world, "comfort", -3, nil)
        end
    end
    -- boredom: nothing done for a while (the outing has been under way at least that long)
    local since = o.engagedAt or o.arrivedAt or o.time
    if now - since >= win and (o.score or 50) > (T.boredFloor or 45) then addFactor(o, "boredom", -1) end
    local d = o.date
    if d and not d.ended then
        local a, b = world.actors[d.by], world.actors[d.with]
        if a and b then
            if togetherNow(world, a, b) then d.engagedAt = now end
            local dEngaged = d.engagedAt and now - d.engagedAt < win
            local avg = (SS.Needs.Mood(a) + SS.Needs.Mood(b)) / 2
            if avg > 30 and dEngaged then addFactor(d, "comfort", 2) end
            -- the pair's feelings for each other, as the social system measures them
            local rel = relDaily(world, d.by, d.with) + relDaily(world, d.with, d.by)
            if d.relLast then
                local delta = rel - d.relLast
                if math.abs(delta) >= 0.5 then V.ScoreEvent(world, "conversation", U.clamp(delta * 0.6, -8, 8), { d.by, d.with }, { passive = true }) end
            end
            d.relLast = rel
            -- company: near each other while doing things together
            local dist = math.abs(a.x - b.x) + math.abs(a.y - b.y)
            if dist <= 4 and dEngaged then addFactor(d, "company", 1) end
            local dSince = d.engagedAt or d.startedAt or now
            if now - dSince >= win and (d.score or 50) > (T.boredFloor or 45) then addFactor(d, "boredom", -1) end
            -- a graceful early ending for a date going badly
            if (d.score or 50) < T.dateEndBelow and now - (d.startedAt or now) >= T.dateMinMinutes then
                d.ended, d.state = now, "ended_early"
                V.Say(world, b, "date_bad", { name = a.name, venue = world.lot.name })
                V.RelBump(world, d.with, d.by, -4)
                V.GuestLeave(world, d.with, "date went badly")
                V.Log(world, b.name .. " ended the date early.")
                SS.Emit("dateEnded", world, d, "ended_early")
            end
        end
    end
end

-- The date partner of someone on a date (nil otherwise).
local function datePartner(o, rid)
    local d = o and o.date
    if not d or d.ended then return nil end
    if rid == d.by then return d.with end
    if rid == d.with then return d.by end
    return nil
end
V.DatePartner = datePartner

-- Completed actions feed the score: activities (+, together more, repeats less), conversations (+/-).
local ACT_RIDS = {}
SS.On("actionEnded", function(actor, act, status, why)
    local world = SS.Sim.world
    local o = world and V.Active(world)
    if not o or not act or not actor then return end
    if not inParty(o, actor.id) then return end
    local ia = SS.Interactions[act.iid]
    if not ia then return end
    -- an activity counts when it ran its course, or ran a while before the player moved on
    local enjoyed = status == "done" or (status == "cancelled" and act.performed and (act.t or 0) >= 5)
    local base = V.BaseIid(act.iid)
    if enjoyed and (ia.venueActivity or (ia.leisure and act.oid and not ia.sleeping)) then
        o.actCount = o.actCount or {}
        local key = actor.id .. ":" .. base
        local reps = (o.actCount[key] or 0) + 1
        o.actCount[key] = reps
        local together = act.data and act.data.together
        local value = (ia.venueActivity and (together and 3 or 1) or 1) / reps
        for n = #ACT_RIDS, 1, -1 do ACT_RIDS[n] = nil end
        ACT_RIDS[1] = actor.id
        local partner = datePartner(o, actor.id)
        if partner and act.data and act.data.withDate then ACT_RIDS[2] = partner end
        V.ScoreEvent(world, "activities", value, ACT_RIDS)
        o.activities = (o.activities or 0) + 1
    end
    -- conversations: the social module reports each exchange itself (socialExchange below); other
    -- social actions between party members count when they end
    if (ia.targetActor or ia.category == "Social" or ia.category == "Romance") and not ia.social and not ia.outings
        and act.tid and inParty(o, act.tid) then
        if status == "done" then V.ScoreEvent(world, "conversation", 2, { actor.id, act.tid })
        elseif status == "failed" then V.ScoreEvent(world, "conversation", -3, { actor.id, act.tid }) end
    end
end)

-- The social module's exchanges (each line of a real conversation), when it is present.
SS.On("socialExchange", function(world, ex)
    world = world or SS.Sim.world
    local o = world and V.Active(world)
    if not o or type(ex) ~= "table" or not ex.a or not ex.b then return end
    if not (inParty(o, ex.a) and inParty(o, ex.b)) then return end
    V.ScoreEvent(world, "conversation", ex.ok == false and -2 or 1.5, { ex.a, ex.b })
end)

-- Final evaluation when the party leaves: reactions, relationships (once), memories, journal.
function V.Conclude(world)
    local o = V.Active(world) or rootOf(world).outing
    if not o or o.concluded then return end
    o.concluded = true
    local lotName = world.lot.name or "the venue"
    local score = o.score or 50
    local members = {}
    for _, rid in ipairs(o.participants or {}) do
        local a = world.root.residents[rid]
        if a then members[#members + 1] = a end
    end
    local d = o.date
    if d then
        local a, b = world.root.residents[d.by], world.root.residents[d.with]
        if a and b and not d.ended then
            d.ended = world.time
            local ds = d.score or 50
            if ds >= 70 then
                d.state = "good"
                if world.actors[b.id] then V.Say(world, b, "date_good", { name = a.name, venue = lotName }) end
                V.RelBump(world, a.id, b.id, 6)
                if SS.Social and SS.Social.Change then SS.Social.Change(world, a.id, b.id, 0, 5); SS.Social.Change(world, b.id, a.id, 0, 5) end
            elseif ds >= 40 then
                d.state = "fine"
                if world.actors[b.id] then V.Say(world, b, "date_ok", { name = a.name, venue = lotName }) end
                V.RelBump(world, a.id, b.id, 2)
            else
                d.state = "bad"
                if world.actors[b.id] then V.Say(world, b, "date_bad", { name = a.name, venue = lotName }) end
                V.RelBump(world, a.id, b.id, -5)
            end
            SS.Emit("dateEnded", world, d, d.state)
        end
        if a and b then
            local mem = string.format("A %s date with %s at %s.", d.state == "good" and "lovely" or d.state == "fine" and "pleasant"
                or d.state == "stood_up" and "no-show" or "disappointing", b.name, lotName)
            a.memories = a.memories or {}
            a.memories[#a.memories + 1] = { t = world.time, text = mem, kind = "date", score = d.score }
            while #a.memories > 30 do table.remove(a.memories, 1) end
        end
    end
    local verdict = score >= 65 and "good" or score < 35 and "bad" or "ok"
    o.verdict = verdict
    if members[1] and world.actors[members[1].id] then
        if verdict == "good" then V.Say(world, members[1], "outing_good", { venue = lotName })
        elseif verdict == "bad" then V.Say(world, members[1], "outing_bad", { venue = lotName }) end
    end
    for _, a in ipairs(members) do
        a.memories = a.memories or {}
        a.memories[#a.memories + 1] = { t = world.time, text = string.format("Went out to %s (%s time).", lotName,
            verdict == "good" and "a great" or verdict == "bad" and "a rotten" or "a fair"), kind = "outing", score = score }
        while #a.memories > 30 do table.remove(a.memories, 1) end
    end
    if SS.Actions and SS.Actions.Journal and world.journal then
        local names = {}
        for _, a in ipairs(members) do names[#names + 1] = a.name end
        SS.Actions.Journal(world, string.format("%s went out to %s (outing score %d).", table.concat(names, ", "), lotName, math.floor(score)))
    end
    SS.Emit("outingConcluded", world, o)
end

---------------------------------------------------------------------------------------------------
-- Venue audio: ambient music for the venue kind while the live lot is shown (guarded).
function V.AudioMode(world)
    local kind = world and V.Kind(world.lot)
    if not kind then return nil end
    return VD.kinds[kind].audio
end

-- Music allowed? The save's setting, then the shell's own (account-wide) preference when it has one.
function V.MusicOn(world)
    if world and world.settings and world.settings.music == false then return false end
    if SS.UI and SS.UI.SoundOn then
        local ok, on = pcall(SS.UI.SoundOn, "music")
        if ok and on == false then return false end
    end
    return true
end

function V.PlayAudio(world)
    local mode = V.AudioMode(world)
    if not mode or not (SS.Audio and SS.Audio.SetMode) then return end
    if not V.MusicOn(world) then return end
    pcall(SS.Audio.SetMode, mode)
end

SS.On("uiMode", function(name)
    local w = SS.Sim.world
    if name == "live" and w and V.Active(w) then V.PlayAudio(w) end
end)

---------------------------------------------------------------------------------------------------
-- The live-venue system: hours, staff, patrons, guests, score (staggered to once a sim minute).
local function closeVenue(world, o)
    o.closing = true
    local lead
    for _, rid in ipairs(o.participants or {}) do lead = lead or world.actors[rid] end
    if lead then V.Say(world, lead, "venue_closed", { venue = world.lot.name }) else V.Notice(world, (world.lot.name or "The venue") .. " is closing.") end
    V.Log(world, (world.lot.name or "The venue") .. " closed for the night.")
    if SS.Shopping and SS.Shopping.OnClose then SS.Shopping.OnClose(world) end
    if SS.Dining and SS.Dining.OnClose then SS.Dining.OnClose(world) end
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a and V.IS_STAFF_ROLE[a.role or ""] then a.roleData = a.roleData or {}; a.roleData.leaving = true end
    end
    if SS.Travel and SS.Travel.GoHome and not (rootOf(world).travel and rootOf(world).travel.pending) then
        SS.Travel.GoHome(world, { reason = "closing" })
    end
end

function V.Tick(world, dt)
    local o = V.Active(world)
    if not o then return end
    local kind = V.Kind(world.lot)
    local rt = rawget(world, "_venueTick") or { acc = 0 }
    rawset(world, "_venueTick", rt)
    rt.acc = rt.acc + dt
    if rt.acc < 1 then return end
    rt.acc = 0
    local open = V.IsOpen(kind, world.time)
    if not open and not o.closing and (o.wasOpen ~= false) then
        closeVenue(world, o)
    end
    o.wasOpen = open
    -- last call: 30 minutes before closing
    local left = V.MinutesToClose(kind, world.time)
    if left and left <= 30 and not o.lastCall then
        o.lastCall = true
        V.Notice(world, (world.lot.name or "The venue") .. ": last orders, closing in half an hour.")
    end
    if open and not o.closing then
        if world.time >= (o.staffCheck or 0) then
            o.staffCheck = world.time + 30
            V.StaffOnDuty(world)
        end
        if world.time >= (o.nextPatronAt or 0) then
            o.nextPatronAt = world.time + SS.RandomInt(world, "outings.patron", T.patronArriveGap[1], T.patronArriveGap[2])
            V.SpawnPatron(world)
        end
    end
    V.GuestArrivals(world)
    V.WatchTabs(world, o)
    if world.time >= (o.nextScore or 0) then
        o.nextScore = world.time + T.scoreEvery
        V.ScoreTick(world)
    end
end

function V.OnAttach(world)
    local o = V.Active(world)
    if not o then return end
    rawset(world, "_venueRT", nil)
    -- repair roles after a load (runtime fields were stripped; roles/roleData are saved)
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local a = world.actors[id]
        if a.npc == "staff" then
            a.role = a.role or a.staffRole
            a.noNeeds = true
            a.roleData = a.roleData or {}
        elseif a.role == "venue_patron" then
            a.noNeeds = true
        end
    end
    if V.IsOpen(V.Kind(world.lot), world.time) and not o.closing then V.StaffOnDuty(world) end
    -- paid cooks and drinks carry on after a load (their actions are runtime-only)
    V.ResumeTabs(world)
    -- a tab left from a visit when the money ran short is settled now, as far as money goes
    if world.household then V.SettleOwed(world, world.household.id) end
    V.PlayAudio(world)
end

SS.Sim.Register({ name = "outings_venue", order = 60, tick = V.Tick, attach = V.OnAttach })

---------------------------------------------------------------------------------------------------
-- Park and social-club activities. venueActivity = true feeds the outing score.
local I = SS.Interactions

-- Sorted actor ids of the session without a new table per call (the step loop's hot paths use it):
-- rebuilt when someone arrives or leaves.
local idCache = setmetatable({}, { __mode = "k" })
local actorEpoch = 0
SS.On("actorAdded", function() actorEpoch = actorEpoch + 1 end)
SS.On("actorRemoved", function() actorEpoch = actorEpoch + 1 end)
SS.On("worldAttached", function() actorEpoch = actorEpoch + 1 end)
function V.ActorIds(world)
    local c = idCache[world]
    local n = 0
    for _ in pairs(world.actors) do n = n + 1 end
    if c and c.epoch == actorEpoch and c.n == n then return c, n end
    c = c or {}
    for k = #c, 1, -1 do c[k] = nil end
    for id in pairs(world.actors) do c[#c + 1] = id end
    table.sort(c)
    c.n, c.epoch = #c, actorEpoch
    idCache[world] = c
    return c, c.n
end

-- Others doing the same activity (on the same object, or within `radius`). Fills and returns a
-- scratch list that is reused on the next call (read it before calling again).
local othersBuf = {}
local function othersUsing(world, actor, iidBase, oid, radius)
    local out = othersBuf
    for n = #out, 1, -1 do out[n] = nil end
    local ids, n = V.ActorIds(world)
    for k = 1, n do
        local b = world.actors[ids[k]]
        if b and b ~= actor and b.act and b.act.performed and V.BaseIid(b.act.iid) == iidBase then
            if (oid and b.act.target and b.act.target.oid == oid) or (radius and math.abs(b.x - actor.x) + math.abs(b.y - actor.y) <= radius) then
                out[#out + 1] = b
            end
        end
    end
    return out
end
V.OthersUsing = othersUsing

-- Group bonus: shared activities give social/fun and small relationship gains with the others.
-- Marks the activity as done together (and with the date partner, when they are among the others).
local function groupTick(world, actor, act, dt, iidBase, oid, radius, social, fun)
    local others = othersUsing(world, actor, iidBase, oid, radius)
    if #others == 0 then return end
    act.data = act.data or {}
    act.data.together = true
    local partner = datePartner(rootOf(world).outing, actor.id)
    if partner and not act.data.withDate then
        for _, b in ipairs(others) do if b.id == partner then act.data.withDate = true end end
    end
    if not actor.noNeeds then
        SS.Needs.Add(actor, "social", social * dt / 60)
        SS.Needs.Add(actor, "fun", fun * dt / 60)
    end
    act.data.relT = (act.data.relT or 0) + dt
    if act.data.relT >= 10 then
        act.data.relT = 0
        for _, b in ipairs(others) do
            if actor.id < b.id then V.RelBump(world, actor.id, b.id, 1) end
        end
    end
end
V.GroupTick = groupTick

local function venueOpenTest(world, actor)
    local o = V.Active(world)
    if not o then return false, "Only at a community venue." end
    if o.closing then return false, (world.lot.name or "The venue") .. " is closing." end
    return true
end

local function staffPresent(world, role)
    local s = V.StaffFor(world, role)
    return s and V.AtPost(world, s), s
end

---------------------------------------------------------------------------------------------------
-- Who pays at a venue. The playing household pays for its members (and treats the people at its
-- own table). Anyone else pays from their own household's money: SS.Money on a session of that
-- household, so the charge lands in their own ledger. A townie with no household pays from a
-- pocket the save does not track (there is no money record for them), so nothing moves.
function V.PayerOf(world, actor)
    if not actor then return nil end
    if V.IsMember(world, actor) then return world.household and world.household.id, world end
    local root = rootOf(world)
    local hid = actor.householdId
    local hh = hid and root.households and root.households[hid]
    if type(hh) == "table" and hh ~= world.household and not actor.npc then return hid, nil end
    return nil
end

-- A session that SS.Money can charge for another household (their own home lot when they have
-- one, else a minimal money-and-ledger view of the household record).
function V.Wallet(world, hid)
    local root = rootOf(world)
    if world.household and world.household.id == hid then return world end
    local hh = hid and root.households[hid]
    if type(hh) ~= "table" then return nil end
    if hh.lotId and root.hood and root.hood.lots[hh.lotId] and SS.Sim.NewSession then
        local ok, s = pcall(SS.Sim.NewSession, root, hh.lotId, hid)
        if ok and s and s.household == hh then return s end
    end
    hh.ledger = type(hh.ledger) == "table" and hh.ledger or {}
    local HH = { money = true, ledger = true, journal = true }
    return setmetatable({ root = root, household = hh }, {
        __index = function(_, k)
            if k == "time" then return root.time end
            if HH[k] then return hh[k] end
            return root[k]
        end,
        __newindex = function(t, k, v) if HH[k] then hh[k] = v else rawset(t, k, v) end end,
    })
end

-- Money this person can spend here (nil: an untracked pocket, no limit).
function V.Funds(world, actor)
    local hid, w = V.PayerOf(world, actor)
    if w then return world.money or 0 end
    if hid then return rootOf(world).households[hid].money or 0 end
    return nil
end

function V.CanPay(world, actor, amount)
    local f = V.Funds(world, actor)
    return f == nil or f >= amount
end

-- Charge a venue purchase once. Returns paid (0 when nothing is tracked), payer household id;
-- or false, why (nothing charged).
function V.Pay(world, actor, amount, cat, text)
    if not amount or amount <= 0 then return 0 end
    local hid, w = V.PayerOf(world, actor)
    if not hid then return 0 end
    w = w or V.Wallet(world, hid)
    if not w then return 0 end
    if (w.money or 0) < amount then return false, "Not enough money (" .. U.fmtMoney(amount) .. ")." end
    SS.Money(w, -amount, cat or "leisure", text)
    return amount, hid
end

-- A bill that must be paid even when the money has run short (a meal already eaten): what the
-- payer has is taken now and the rest is owed, never waived. The rest becomes a bill in the post
-- when the careers module handles bills (SS.Economy.Bill returns the bill), else a tab at this
-- venue in the save (root.venues[lotId].owed[householdId]) that is settled on the next visit.
-- Returns paid, rest, how ("paid" | "bill" | "tab" | "untracked").
function V.PayOrOwe(world, hid, amount, cat, text)
    if not amount or amount <= 0 then return 0, 0, "paid" end
    local w = hid and V.Wallet(world, hid)
    if not w then return 0, 0, "untracked" end
    local have = math.max(0, math.floor(w.money or 0))
    local pay = math.min(have, amount)
    if pay > 0 then SS.Money(w, -pay, cat or "leisure", text) end
    local rest = amount - pay
    if rest <= 0 then
        -- paid in full: an older tab here is settled too, as far as the money goes (a patron's
        -- household is only ever charged when one of them is here)
        if hid ~= (world.household and world.household.id) then V.SettleOwed(world, hid) end
        return pay, 0, "paid"
    end
    local E = SS.Economy
    if E and E.Bill then
        local ok, b = pcall(E.Bill, w, rest, "venue", (text or "Venue") .. " (the rest, on account)")
        if ok and b then return pay, rest, "bill" end
    end
    local rec = V.Record(rootOf(world), world.lot.id)
    rec.owed = rec.owed or {}
    rec.owed[hid] = (rec.owed[hid] or 0) + rest
    return pay, rest, "tab"
end

-- Settle what a household still owes this venue (on the next visit), as far as its money goes.
-- Returns the amount settled.
function V.SettleOwed(world, hid)
    local root = rootOf(world)
    local rec = root.venues and world.lot and root.venues[world.lot.id]
    local owed = rec and rec.owed and hid and rec.owed[hid]
    if not owed or owed <= 0 then return 0 end
    local w = V.Wallet(world, hid)
    local pay = w and math.min(math.max(0, math.floor(w.money or 0)), owed) or 0
    if pay <= 0 then return 0 end
    SS.Money(w, -pay, "dining", string.format("%s: settled the tab from last time", world.lot.name or "Venue"))
    rec.owed[hid] = owed - pay
    if rec.owed[hid] <= 0 then rec.owed[hid] = nil end
    if world.household and world.household.id == hid then
        V.Notice(world, string.format("%s: settled %s owed from the last visit%s.", world.lot.name or "The venue", U.fmtMoney(pay),
            rec.owed[hid] and (" (" .. U.fmtMoney(rec.owed[hid]) .. " still owed)") or ""))
    end
    return pay
end

-- Give money back to whoever paid (same category, so the ledger nets out).
function V.Refund(world, hid, amount, cat, text)
    if not hid or not amount or amount <= 0 then return false end
    local w = V.Wallet(world, hid)
    if not w then return false end
    SS.Money(w, amount, cat or "leisure", text)
    return true
end

---------------------------------------------------------------------------------------------------
-- Paid orders that take a while: the grill's cook and a drink at the bar. The record lives in the
-- save (root.outing.tabs[kind][rid] = { paid, payer, progress, total, item, oid, at }) from the
-- moment money moves, so no path loses what was paid for:
--   finished               -> the result (a plate; the whole drink); the record closes;
--   interrupted/cancelled  -> grill: a plate when the cook was at least half done, else a full
--                             refund; drink: the rest waits at the bar and the next "Order a Drink"
--                             finishes it with no new charge;
--   reload                 -> actions are runtime-only, so V.ResumeTabs (on attach) queues the same
--                             interaction again and it carries on where it stopped, with no charge;
--   the outing ends        -> an unfinished cook is refunded; a drink less than half drunk is
--                             refunded, otherwise it counts as had.
-- Never both a refund and the result, never neither.
V.TAB_KINDS = { "drink", "grill" }
V.TAB_IID = { grill = "park_grill", drink = "bar_drink" }
V.TAB_ANCHOR = { grill = "grill", drink = "bar" }
V.TAB_CAT = { grill = "food", drink = "leisure" }

function V.Tab(world, kind, rid)
    local o = rootOf(world).outing
    local t = o and o.tabs and o.tabs[kind]
    return t and t[rid]
end

local function openTab(world, kind, rid, rec)
    local o = rootOf(world).outing
    o.tabs = o.tabs or {}
    o.tabs[kind] = o.tabs[kind] or {}
    o.tabs[kind][rid] = rec
    return rec
end
V.OpenTab = openTab

local function tabDone(rec) return (rec.progress or 0) >= (rec.total or 0) - 1e-6 end

-- Close one tab. how: "done" | "cancel" (interrupted; still at the venue) | "leave" (the outing
-- ends, or the person has left). Returns "result" | "refund" | "kept" | nil (no tab).
function V.SettleTab(world, kind, rid, how)
    local rec = V.Tab(world, kind, rid)
    if not rec then return nil end
    local root = rootOf(world)
    local r = root.residents[rid]
    local name = r and r.name or "Someone"
    local frac = (rec.total or 0) > 0 and (rec.progress or 0) / rec.total or 1
    local out
    if how == "done" or tabDone(rec) then out = "result"
    elseif kind == "grill" then out = (how == "cancel" and frac >= 0.5) and "result" or "refund"
    elseif how == "cancel" then return "kept"
    else out = frac < 0.5 and "refund" or "result" end
    root.outing.tabs[kind][rid] = nil
    local lotName = world.lot and world.lot.name or "The venue"
    if out == "result" then
        if kind == "grill" then
            V.AddFood(world, rid, 1)
            if not tabDone(rec) then V.Log(world, name .. " took the food off the grill a little early.") end
        end
    elseif (rec.paid or 0) > 0 then
        local what = kind == "grill" and "grill kiosk" or "drink"
        V.Refund(world, rec.payer, rec.paid, V.TAB_CAT[kind], string.format("%s: %s refund", lotName, what))
        V.Log(world, string.format("%s's %s was refunded (%s).", name, what, U.fmtMoney(rec.paid)))
        if rec.payer and world.household and rec.payer == world.household.id then
            V.Notice(world, string.format("%s: %s refunded to %s (%s).", lotName, what, name, U.fmtMoney(rec.paid)))
        end
    end
    return out
end

-- Everything still open when the outing ends (going home, closing, an outing ended offline).
function V.SettleTabs(world, how)
    local o = rootOf(world).outing
    if not (o and o.tabs) then return end
    for _, kind in ipairs(V.TAB_KINDS) do
        for _, rid in ipairs(sortedKeys(o.tabs[kind])) do V.SettleTab(world, kind, rid, how or "leave") end
    end
end

-- Is this person on their way out (the taxi home has come for them, or a guest/patron is leaving)?
-- A cook stopped because of that settles as "leave" (the fee back), not as a plate to carry off.
function V.Leaving(world, actor)
    if not actor then return false end
    if actor.roleData and actor.roleData.leaving then return true end
    local root = rootOf(world)
    local trip = root.travel and root.travel.pending
    if trip and trip.kind == "home" and trip.from == (world.lot and world.lot.id) and (trip.state ~= "waiting" or (world.time or 0) >= (trip.taxiAt or math.huge)) then
        for _, rid in ipairs(trip.rids or {}) do if rid == actor.id then return true end end
    end
    return false
end

local function busyWith(a, iid)
    if a.act and V.BaseIid(a.act.iid) == iid then return true end
    for _, q in ipairs(a.queue or {}) do if V.BaseIid(q.iid) == iid then return true end end
    return false
end

-- Where a tab can carry on: its own object when still there, else the nearest anchor of its kind.
local function tabObject(world, kind, rec, a)
    local o = rec.oid and world.lot.objects[rec.oid]
    if o and V.Supports(SS.Objects[o.def], V.TAB_IID[kind]) then return o end
    local best, bd
    for _, oid in ipairs(V.Anchors(world, V.TAB_ANCHOR[kind])) do
        local c = world.lot.objects[oid]
        if c and V.Supports(SS.Objects[c.def], V.TAB_IID[kind]) then
            local d = a and (math.abs(c.x - a.x) + math.abs(c.y - a.y)) or 0
            if not bd or d < bd then best, bd = c, d end
        end
    end
    return best
end

-- After a load (actions are not saved): queue each open tab's interaction again for its person.
function V.ResumeTabs(world)
    local o = V.Active(world)
    if not (o and o.tabs) then return end
    for _, kind in ipairs(V.TAB_KINDS) do
        for _, rid in ipairs(sortedKeys(o.tabs[kind])) do
            local rec = o.tabs[kind][rid]
            local a = world.actors[rid]
            local obj = a and tabObject(world, kind, rec, a)
            if a and obj and not (a.roleData and a.roleData.leaving) and not busyWith(a, V.TAB_IID[kind]) then
                rec.idle = nil
                SS.Actions.Order(world, a, obj.id, V.IidFor(SS.Objects[obj.def], V.TAB_IID[kind]), nil, nil, { data = { resume = true } })
            elseif not a then
                V.SettleTab(world, kind, rid, "leave")
            elseif not obj then
                V.SettleTab(world, kind, rid, "cancel")
            end
        end
    end
end

-- Once a minute: a tab whose person left the lot settles; a cook nobody is attending to (the
-- action was dropped by some other path) settles after a few minutes.
local function watchTabs(world, o)
    if not o.tabs then return end
    for _, kind in ipairs(V.TAB_KINDS) do
        for _, rid in ipairs(sortedKeys(o.tabs[kind])) do
            local rec = o.tabs[kind][rid]
            local a = world.actors[rid]
            if not a then V.SettleTab(world, kind, rid, "leave")
            elseif busyWith(a, V.TAB_IID[kind]) then rec.idle = nil
            elseif kind == "grill" then
                rec.idle = rec.idle or world.time
                if world.time - rec.idle >= 3 then V.SettleTab(world, kind, rid, "cancel") end
            end
        end
    end
end
V.WatchTabs = watchTabs

I.venue_dance = {
    label = "Dance", category = "Fun", slot = "dancer", pose = "dance", maxDur = 45, venueActivity = true, leisure = true,
    rate = { fun = 30, energy = -6, social = 4 }, advert = { fun = 32, social = 8 },
    test = function(world, actor)
        local ok, why = venueOpenTest(world, actor)
        if not ok then return ok, why end
        return true
    end,
    onStart = function(world, actor, act)
        local o = act.oid and world.lot.objects[act.oid]
        if o then o.state = o.state or {}; o.state.on = true end
    end,
    onTick = function(world, actor, act, obj, dt)
        local dj = staffPresent(world, "dj")
        if dj and not actor.noNeeds then SS.Needs.Add(actor, "fun", 8 * dt / 60) end
        groupTick(world, actor, act, dt, "venue_dance", nil, 5, 14, 6)
    end,
}

I.dj_request = {
    label = "Request a Song", category = "Fun", slot = "request", pose = "talk", dur = 3, venueActivity = true, leisure = true,
    gain = { fun = 8, social = 6 }, advert = { fun = 12, social = 6 },
    test = function(world, actor)
        local ok, why = venueOpenTest(world, actor)
        if not ok then return ok, why end
        if not staffPresent(world, "dj") then return false, "The DJ isn't at the decks." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" then return end
        local _, dj = staffPresent(world, "dj")
        if dj then
            V.Say(world, dj, "dj", {})
            V.RelBump(world, actor.id, dj.id, 1)
        end
        local o = rootOf(world).outing
        if o then o.requests = (o.requests or 0) + 1 end
        SS.Emit("djRequest", world, actor)
    end,
}

-- Drinks: the player picks one from the bar's menu (act.data.drink); otherwise a tired person
-- takes the espresso tonic, a lonely one the most sociable drink, and anyone else picks at random
-- among what they can afford (named stream, so it replays exactly).
local DRINK_TIME = 8
V.DRINK_TIME = DRINK_TIME
local drinkById = {}
for _, d in ipairs(VD.drinks) do drinkById[d.id] = d end
function V.Drink(id) return id and drinkById[id] or nil end

function V.CheapestDrink()
    local p
    for _, d in ipairs(VD.drinks) do if not p or d.price < p then p = d.price end end
    return p or 0
end

function V.PickDrink(world, actor)
    local funds = V.Funds(world, actor)
    local list = {}
    for _, d in ipairs(VD.drinks) do if not funds or d.price <= funds then list[#list + 1] = d end end
    if #list == 0 then return nil end
    local n = actor and actor.needs or {}
    if (n.energy or 50) < 25 then
        for _, d in ipairs(list) do if d.energy then return d end end
    end
    if (n.social or 50) < 25 then
        local best
        for _, d in ipairs(list) do if not best or (d.social or 0) > (best.social or 0) then best = d end end
        return best
    end
    return list[SS.RandomInt(world, "outings.bar", 1, #list)]
end

I.bar_drink = {
    label = "Order a Drink", category = "Fun", slot = "patron", pose = "eat_stand", dur = DRINK_TIME, venueActivity = true, leisure = true,
    advert = { fun = 14, social = 6 }, carry = "cup",
    test = function(world, actor, obj)
        -- the rest of a drink already paid for can always be finished
        if V.Tab(world, "drink", actor.id) then return true end
        local ok, why = venueOpenTest(world, actor)
        if not ok then return ok, why end
        if not staffPresent(world, "bartender") then return false, "Nobody is serving at the bar." end
        if not V.CanPay(world, actor, V.CheapestDrink()) then
            return false, "Drinks start at " .. U.fmtMoney(V.CheapestDrink()) .. "; " .. (V.IsMember(world, actor) and "the household" or actor.name) .. " can't afford one."
        end
        return true
    end,
    -- commit point: the bartender hands the drink over and it is paid for once (a tab in the save)
    onStart = function(world, actor, act)
        act.data = act.data or {}
        local rec = V.Tab(world, "drink", actor.id)
        if rec then
            act.data.drink = rec.item
        else
            local d = V.Drink(act.data.drink) or V.PickDrink(world, actor)
            if not d then return false, "Nothing on the bar's menu is affordable." end
            local paid, payer = V.Pay(world, actor, d.price, "leisure", (world.lot.name or "Bar") .. ": " .. d.name)
            if paid == false then return false, payer end
            rec = openTab(world, "drink", actor.id, { item = d.id, paid = paid, payer = payer, progress = 0, total = DRINK_TIME,
                at = world.time, oid = act.target and act.target.oid })
            act.data.drink = d.id
            local _, bt = staffPresent(world, "bartender")
            if bt then bt.pose = "use"; V.RelBump(world, actor.id, bt.id, 1) end
        end
        act.data.tab = true
        actor.carry = "cup"
    end,
    onTick = function(world, actor, act, obj, dt)
        local rec = V.Tab(world, "drink", actor.id)
        if not rec then act.complete = true; return end
        local d = V.Drink(rec.item) or VD.drinks[1]
        local step = math.min(dt, (rec.total or DRINK_TIME) - (rec.progress or 0))
        if step > 0 then
            rec.progress = (rec.progress or 0) + step
            if not actor.noNeeds then
                local f = step / (rec.total or DRINK_TIME)
                SS.Needs.Add(actor, "fun", d.fun * f)
                SS.Needs.Add(actor, "social", (d.social or 0) * f)
                if d.energy then SS.Needs.Add(actor, "energy", d.energy * f) end
            end
        end
        groupTick(world, actor, act, dt, "bar_drink", nil, 3, 10, 2)
        if tabDone(rec) then act.complete = true end
    end,
    onEnd = function(world, actor, act, obj, status)
        if actor.carry == "cup" then actor.carry = nil end
        local rec = act.data and act.data.tab and V.Tab(world, "drink", actor.id)
        if rec then V.SettleTab(world, "drink", actor.id, tabDone(rec) and "done" or "cancel") end
    end,
}

-- Buy a round: everyone standing near the bar (at most 10) gets a cup of punch. It is paid when the
-- drinks are handed over at the end, so an interrupted round costs nothing and gives nothing.
local function roundFor(world, actor)
    local punch = VD.drinks[#VD.drinks]
    local people = {}
    for _, id in ipairs(SS.Sim.ActorIds(world)) do
        local b = world.actors[id]
        if not V.IsStaff(b) and math.abs(b.x - actor.x) + math.abs(b.y - actor.y) <= 6 and #people < 10 then people[#people + 1] = b end
    end
    return punch.price * #people, people, punch
end
V.RoundFor = roundFor

I.bar_round = {
    label = "Buy a Round", category = "Social", slot = "patron", pose = "celebrate", dur = 4, manualOnly = true, venueActivity = true,
    advert = {},
    test = function(world, actor)
        local ok, why = venueOpenTest(world, actor)
        if not ok then return ok, why end
        if not staffPresent(world, "bartender") then return false, "Nobody is serving at the bar." end
        local cost = roundFor(world, actor)
        if not V.CanPay(world, actor, cost) then return false, "A round costs " .. U.fmtMoney(cost) .. "; that's more than there is to spend." end
        return true
    end,
    onStart = function(world, actor, act)
        local _, people = roundFor(world, actor)
        act.data = act.data or {}
        act.data.people = {}
        for _, b in ipairs(people) do act.data.people[#act.data.people + 1] = b.id end
        V.Say(world, actor, "round", {})
    end,
    -- "done" also ends a stopped action (the executor walks off the object and finishes "done"),
    -- so only a round that ran its full time is handed over and paid for
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or not act.data or not act.data.people or act.data.shared then return end
        if (act.t or 0) < I.bar_round.dur - 1e-6 then return end
        local here = {}
        for _, id in ipairs(act.data.people) do if world.actors[id] then here[#here + 1] = id end end
        act.data.people = here
        if #here == 0 then return end
        local punch = VD.drinks[#VD.drinks]
        local cost = punch.price * #here
        local paid, why = V.Pay(world, actor, cost, "leisure", (world.lot.name or "Bar") .. ": a round for " .. #here)
        if paid == false then
            V.Notice(world, actor.name .. " couldn't cover the round after all: " .. why)
            return
        end
        act.data.shared, act.data.paid = true, paid
        for _, id in ipairs(act.data.people) do
            local b = world.actors[id]
            if b and b ~= actor then
                if not b.noNeeds then SS.Needs.Add(b, "social", 12); SS.Needs.Add(b, "fun", 8) end
                V.RelBump(world, b.id, actor.id, 3)
            end
        end
        if not actor.noNeeds then SS.Needs.Add(actor, "social", 15); SS.Needs.Add(actor, "fun", 10) end
        V.ScoreEvent(world, "group", 4, { actor.id })
    end,
}

local function gameIa(label, slot, pose, fun, skill, groupSocial)
    return {
        label = label, category = "Fun", slot = slot, pose = pose, maxDur = 45, venueActivity = true, leisure = true,
        rate = { fun = fun }, advert = { fun = fun + 4 }, skill = skill,
        test = function(world, actor) return venueOpenTest(world, actor) end,
        onTick = function(world, actor, act, obj, dt)
            if skill and not SS.Actions.EffectMult and SS.Skills and SS.Skills.Gain then
                for name, per in pairs(skill) do SS.Skills.Gain(world, actor, name, per * dt / 60) end
            end
            groupTick(world, actor, act, dt, V.BaseIid(act.iid), act.target and act.target.oid, nil, groupSocial, 6)
        end,
    }
end
I.venue_pool = gameIa("Play Pool", "player", "play", 24, { body = 0.2, logic = 0.2 }, 16)
I.venue_darts = gameIa("Throw Darts", "thrower", "play", 22, { body = 0.25 }, 14)
I.venue_chess = gameIa("Play Chess", "player", "play", 18, { logic = 0.6 }, 14)
I.venue_play = gameIa("Play on the Climbing Frame", "play", "play", 34, { body = 0.3 }, 10)
I.venue_play.ages = { child = true, adult = true }
I.venue_play.rate = { fun = 34, energy = -8 }

I.venue_mingle = {
    label = "Mingle", category = "Social", slot = "mingle", pose = "talk", maxDur = 30, venueActivity = true, leisure = true,
    rate = { social = 26, fun = 8 }, advert = { social = 30, fun = 6 },
    test = function(world, actor) return venueOpenTest(world, actor) end,
    onTick = function(world, actor, act, obj, dt)
        groupTick(world, actor, act, dt, "venue_mingle", act.target and act.target.oid, nil, 12, 6)
        local others = othersUsing(world, actor, "venue_mingle", act.target and act.target.oid)
        actor.pose = (#others > 0) and ((SS.Random(world, "outings.anim") < 0.2) and "laugh" or "talk") or "idle"
        act.pose = actor.pose
    end,
}

-- Fountain: toss a coin and make a wish (a coin from the household purse), or just admire it.
I.venue_wish = {
    label = "Toss a Coin and Wish", category = "Fun", slot = "edge", pose = "use", dur = 2, venueActivity = true, manualOnly = true,
    gain = { fun = 6 }, advert = {},
    test = function(world, actor)
        if not V.Active(world) then return false, "Only at a community venue." end
        if not V.CanPay(world, actor, VD.picnic.wishPrice) then return false, "Not even a coin to spare." end
        return true
    end,
    -- the coin goes in when the wish is made (the end), so an interrupted wish costs nothing
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" or (act.t or 0) < I.venue_wish.dur - 1e-6 then return end
        act.data = act.data or {}
        if act.data.paid then return end
        local paid = V.Pay(world, actor, VD.picnic.wishPrice, "leisure", "Fountain wish")
        if paid == false then return end
        act.data.paid = paid
        V.Say(world, actor, "wish", {})
    end,
}

I.venue_admire = {
    label = "Admire the Fountain", category = "Fun", slot = "edge", pose = "idle", maxDur = 15, venueActivity = true, leisure = true,
    rate = { fun = 10, comfort = 2 }, advert = { fun = 10 },
    test = function(world, actor) if not V.Active(world) then return false, "Only at a community venue." end return true end,
}

-- People-watching from a public bench (outdoors at a venue).
I.people_watch = {
    label = "Watch the World Go By", category = "Fun", slot = "seat", pose = "sit", maxDur = 40, venueActivity = true, leisure = true, keepOnTalkEnd = true,
    rate = { fun = 12, comfort = 14 }, advert = { fun = 12, comfort = 12 },
    test = function(world, actor, obj)
        if not V.Active(world) then return false, "Best enjoyed at the park or the shops." end
        return true
    end,
    onTick = function(world, actor, act, obj, dt)
        local near = 0
        for _, b in pairs(world.actors) do
            if b ~= actor and math.abs(b.x - actor.x) + math.abs(b.y - actor.y) <= 6 then near = near + 1 end
        end
        if near > 0 and not actor.noNeeds then SS.Needs.Add(actor, "fun", math.min(near, 4) * 2 * dt / 60) end
    end,
}

-- Coin-operated park grill: the kiosk fee is paid once when the cooking starts and the cook is a
-- tab in the save (see "Paid orders that take a while" above): finished -> a plate; stopped at
-- half-cooked or later -> a plate; stopped earlier -> the fee back; a reload carries on cooking.
-- Then eat at a picnic seat or bench.
I.park_grill = {
    label = "Grill a Picnic Lunch", category = "Food", slot = "cook", pose = "cook", dur = VD.picnic.cookTime, venueActivity = true,
    advert = { hunger = 40 },
    advertise = function(world, actor)
        if V.FoodOf(world, actor.id) > 0 or V.Tab(world, "grill", actor.id) then return nil end
        return { hunger = 40 }
    end,
    test = function(world, actor, obj)
        if not V.Active(world) then return false, "Only at the park." end
        if V.Tab(world, "grill", actor.id) then return true end -- a cook already paid for carries on
        if not V.CanPay(world, actor, VD.picnic.price) then return false, "The grill kiosk costs " .. U.fmtMoney(VD.picnic.price) .. "." end
        return true
    end,
    onStart = function(world, actor, act, obj)
        act.data = act.data or {}
        local rec = V.Tab(world, "grill", actor.id)
        if not rec then
            local paid, payer = V.Pay(world, actor, VD.picnic.price, "food", (world.lot.name or "Park") .. ": grill kiosk")
            if paid == false then return false, payer end
            rec = openTab(world, "grill", actor.id, { paid = paid, payer = payer, progress = 0, total = VD.picnic.cookTime, at = world.time })
        else
            act.data.resumed = true
        end
        rec.oid, rec.idle = act.target and act.target.oid, nil
        act.data.tab = true
        local o = act.target and world.lot.objects[act.target.oid]
        if o then o.state = o.state or {}; o.state.on, o.state.cooking = true, true end
    end,
    onTick = function(world, actor, act, obj, dt)
        local rec = V.Tab(world, "grill", actor.id)
        if not rec then act.complete = true; return end
        rec.progress = math.min(rec.total or VD.picnic.cookTime, (rec.progress or 0) + dt)
        if tabDone(rec) then act.complete = true end
    end,
    onEnd = function(world, actor, act, obj, status)
        local o = act.target and world.lot.objects[act.target.oid]
        if o and o.state then o.state.cooking, o.state.on = nil, false end
        local rec = act.data and act.data.tab and V.Tab(world, "grill", actor.id)
        if not rec then return end
        local full = tabDone(rec)
        local out = V.SettleTab(world, "grill", actor.id, full and "done" or (V.Leaving(world, actor) and "leave" or "cancel"))
        if out == "result" then
            actor.carry = "plate_food"
            if full and SS.Skills and SS.Skills.Gain then SS.Skills.Gain(world, actor, "cooking", 0.1) end
        end
    end,
    next = function(world, actor, act)
        if V.FoodOf(world, actor.id) <= 0 then return nil end
        local seat = V.NearestPicnicSeat(world, actor)
        if seat then return { oid = seat, iid = "picnic_eat" } end
    end,
}

function V.FoodOf(world, rid)
    local o = rootOf(world).outing
    local f = o and o.food and o.food[rid]
    return f and f.plates or 0
end

function V.AddFood(world, rid, n)
    local o = rootOf(world).outing
    if not o then return end
    o.food = o.food or {}
    local f = o.food[rid] or { plates = 0, left = 1 }
    f.plates = f.plates + n
    o.food[rid] = f
end

function V.NearestPicnicSeat(world, actor)
    local best, bd
    for _, oid in ipairs(V.Anchors(world, "seating")) do
        local o = world.lot.objects[oid]
        local def = o and SS.Objects[o.def]
        if def and not (o.res and o.res.seat) then
            local d = math.abs(o.x - actor.x) + math.abs(o.y - actor.y)
            if o.def == "sys_picnic_seat" then d = d - 3 end
            if not bd or d < bd then best, bd = oid, d end
        end
    end
    return best
end

I.picnic_eat = {
    label = "Eat a Picnic Lunch", category = "Food", slot = "seat", pose = "sit_eat", dur = VD.picnic.eatTime, venueActivity = true, keepOnTalkEnd = true,
    advert = { hunger = 45 },
    advertise = function(world, actor) if V.FoodOf(world, actor.id) > 0 then return { hunger = 45 } end end,
    test = function(world, actor)
        if V.FoodOf(world, actor.id) <= 0 then return false, "Grill some food first." end
        return true
    end,
    onStart = function(world, actor) actor.carry = "plate_food" end,
    onTick = function(world, actor, act, obj, dt)
        local o = rootOf(world).outing
        local f = o and o.food and o.food[actor.id]
        act.data = act.data or {}
        if act.data.ate then return end
        if not f or f.plates <= 0 then act.complete = true; act.stopRequested = true; return end
        local portion = math.min(dt / VD.picnic.eatTime, f.left or 1)
        f.left = math.max(0, (f.left or 1) - portion)
        if not actor.noNeeds then SS.Needs.Add(actor, "hunger", VD.picnic.hunger * portion) end
        groupTick(world, actor, act, dt, "picnic_eat", nil, 3, 14, 4)
        if f.left <= 1e-6 then
            f.plates, f.left = f.plates - 1, 1
            act.data.ate = true
            act.complete = true
        end
    end,
    -- a meal that ran its full time is finished (no rounding crumbs left on the plate); an
    -- interrupted one keeps what is left for later (partial benefit only)
    onEnd = function(world, actor, act, obj, status)
        if actor.carry == "plate_food" then actor.carry = nil end
        act.data = act.data or {}
        if status == "done" and not act.data.ate then
            local o = rootOf(world).outing
            local f = o and o.food and o.food[actor.id]
            if f and f.plates > 0 and (f.left or 1) < 0.05 then f.plates, f.left = f.plates - 1, 1; act.data.ate = true end
        end
    end,
}

for _, id in ipairs({ "venue_dance", "dj_request", "bar_drink", "bar_round", "venue_pool", "venue_darts", "venue_chess",
    "venue_play", "venue_mingle", "venue_wish", "venue_admire", "people_watch", "park_grill", "picnic_eat" }) do
    I[id].outings = true
end

-- Attach the activities to the system anchors (catalogue anchors get them by tag where the tag
-- vocabulary names them; the chess/pool/darts/dance tags belong to household-core, so venue
-- versions are attached only to the outings system objects and venue lots).
local function addActions(defId, list)
    local def = SS.Objects[defId]
    if not def then return end
    def.actions = def.actions or {}
    for _, iid in ipairs(list) do
        local have = false
        for _, a in ipairs(def.actions) do if a == iid then have = true end end
        if not have then def.actions[#def.actions + 1] = iid end
    end
end
addActions("sys_dance_light", { "venue_dance" })
addActions("sys_pool_table", { "venue_pool" })
addActions("sys_dartboard", { "venue_darts" })
addActions("sys_cocktail_table", { "venue_mingle" })
addActions("sys_park_chess", { "venue_chess" })
addActions("sys_playground", { "venue_play" })
addActions("sys_park_fountain", { "venue_admire", "venue_wish" })
addActions("sys_park_grill", { "park_grill" })
addActions("sys_picnic_seat", { "picnic_eat", "people_watch" })
addActions("sys_public_bench", { "people_watch", "picnic_eat" })
SS.Tags.Attach("dj_booth", "dj_request")
SS.Tags.Attach("bar", "bar_drink")
SS.Tags.Attach("bar", "bar_round")
