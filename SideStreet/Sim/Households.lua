-- SideStreet household management: create (from the creator), reopen/update, delete, move in,
-- move out (furniture sold or packed), evict a member, move a resident between households,
-- merge households, and bulldoze a vacant lot. Every operation is one transaction: it checks
-- everything first, then changes the save and settles money exactly once (SS.Money through a
-- household view, with a transaction id recorded in household.tx so a repeated call is refused).
-- Owner: hood module (docs/modules/hood.md). Events: householdCreated(root, hh),
-- householdUpdated(root, hh), householdDeleted(root, hhId), householdMoved(root, hh, fromLot, toLot, how),
-- residentMoved(root, rid, fromHh, toHh), householdsMerged(root, into, fromId), lotBulldozed(root, lotId),
-- movedIn(world|root, hhId) (visitors' welcome), householdChanged(world, rid, fromId, toId) (Transfer),
-- householdClosed(root, hh, reason) (Close / End).
local _, SS = ...
local HD, H, HL = SS.HoodData, SS.Hood, SS.HoodLots
local U = SS.U
local HH = SS.Households or {}
SS.Households = HH

HH.TX_CAP = 40
local T = HD.Tuning

local function sortedKeys(t)
    local ks = {}
    for k in pairs(t or {}) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
    return ks
end

local function rootOf(w) return (w and w.root) or w end

local function inList(list, v) for n, x in ipairs(list or {}) do if x == v then return n end end end

local function living(root, hh)
    local out = {}
    for _, rid in ipairs(hh.members or {}) do
        local r = root.residents[rid]
        if r and not r.dead then out[#out + 1] = r end
    end
    return out
end
HH.Living = living

local function adultsIn(list)
    local n = 0
    for _, r in ipairs(list) do if r.age == "adult" then n = n + 1 end end
    return n
end

local function nextTx(root, kind)
    root.hood.nextTx = (root.hood.nextTx or 0) + 1
    return kind .. ":" .. root.hood.nextTx
end

-- Was transaction `txId` already settled for this household (its bounded log, HH.TX_CAP)?
function HH.TxSettled(hh, txId)
    if not (txId and type(hh) == "table" and type(hh.tx) == "table") then return false end
    for _, t in ipairs(hh.tx) do
        if t.id == txId or (type(t.id) == "string" and t.id:sub(1, #txId + 1) == txId .. ":") then return true end
    end
    return false
end

-- A caller's transaction id (opts.tx: the neighbourhood mints one per confirmed action) or a
-- fresh one. A caller's id that was already settled refuses the whole operation up front, so a
-- retried or repeated request is answered "already done" and never charges twice.
local function txFor(root, hh, opts, kind)
    local id = type(opts) == "table" and opts.tx
    if id then
        if HH.TxSettled(hh, id) then return nil, "That was already done; nothing was charged again." end
        return id
    end
    return nextTx(root, kind)
end
HH.TxFor = txFor

-- Settle money for a household exactly once. Returns ok, why.
function HH.Settle(root, hh, delta, category, text, txId)
    hh.tx = type(hh.tx) == "table" and hh.tx or {}
    if txId then
        for _, t in ipairs(hh.tx) do if t.id == txId then return false, "That transaction was already settled." end end
    end
    local view = H.View(root, hh)
    if delta ~= 0 then SS.Money(view, delta, category, text) end
    hh.tx[#hh.tx + 1] = { id = txId, t = view.time, amount = delta, cat = category, text = text }
    while #hh.tx > HH.TX_CAP do table.remove(hh.tx, 1) end
    return true
end

-- Park (or restore) the scheduled events bound to a lot when its household leaves (arrives), so
-- nothing of theirs fires for the next occupant and their own events follow them.
local function parkEvents(root, fromLot, toKey)
    for _, ev in ipairs(root.scheduled or {}) do if ev.lotId == fromLot then ev.lotId = toKey end end
end
HH.ParkEvents = parkEvents

-- Drop the scheduled events bound to `key` (a lot id, or "hh:<id>" for a household's parked
-- events): a deleted or merged-away household's parked events and a bulldozed lot's events never
-- fire, and past-due ones would be walked over on every step. Returns the number dropped.
local function dropEvents(root, key)
    local s, n = root.scheduled, 0
    if type(s) ~= "table" then return 0 end
    for i = #s, 1, -1 do
        if s[i].lotId == key then table.remove(s, i); n = n + 1 end
    end
    return n
end
HH.DropEvents = dropEvents

-- Runtime and resumable action state of a person who changes place (the core's saved mirrors
-- `doing` / `orders`, carried things and scratch data included), so nothing from the old lot is
-- resumed on the new one.
local function clearRuntime(r)
    r.act, r.queue, r.sleeping, r.walking, r.onObj, r.pose, r.nextThink, r.balloon, r.carry = nil, nil, nil, nil, nil, nil, nil, nil, nil
    r.doing, r.orders, r.held, r.tmp = nil, nil, nil, nil
end
HH.ClearRuntime = clearRuntime

-- A person about to change place is taken off the attached session first (H.LeaveSession: the
-- action finishes, reservations and carried things are settled, actorRemoved is heard).
local function leave(root, rid) return H.LeaveSession(root, rid) end

-- `leftLot`: the home they lived on before (marked when they leave it while away, H.MarkLeft).
local function placeAtHome(root, hh, r, n, leftLot)
    local lot = hh.lotId and root.hood.lots[hh.lotId]
    if lot then
        local i, j, lv = H.SpawnCell(lot, n)
        -- placed at the new home now: an "away" record from the old home (at work or school when
        -- they moved) no longer applies; the old lot's return event finds them housed
        r.lotId, r.x, r.y, r.level, r.away, r.leftLotId = hh.lotId, i + 0.5, j + 0.5, lv, nil, nil
    else
        -- no home: someone away keeps their away record (careers' and the street's), and the
        -- home they left is marked so the ride home does not leave them living there
        if leftLot ~= hh.lotId then H.MarkLeft(root, r, leftLot) end
        r.lotId, r.x, r.y, r.level = nil, 0.5, 0.5, 0
    end
    clearRuntime(r)
end

---------------------------------------------------------------------------
-- Lists
---------------------------------------------------------------------------
function HH.List(root)
    root = rootOf(root)
    local out = {}
    for _, id in ipairs(sortedKeys(root.households)) do out[#out + 1] = root.households[id] end
    return out
end

-- The household bin: households without a lot that still have living members. Service households
-- (Family Services, the shelter) and households whose story ended are never in it.
function HH.Bin(root)
    root = rootOf(root)
    local out = {}
    for _, hh in ipairs(HH.List(root)) do
        if not hh.lotId and #living(root, hh) > 0 and not H.IsSpecial(hh) then out[#out + 1] = hh end
    end
    return out
end

-- Households a person or household can join (merge and move targets, move-in choices): every
-- household except service and ended ones and `exceptId`. Sorted by id.
function HH.Choices(root, exceptId)
    root = rootOf(root)
    local out = {}
    for _, hh in ipairs(HH.List(root)) do
        if hh.id ~= exceptId and not H.IsSpecial(hh) and (hh.lotId or #living(root, hh) > 0) then out[#out + 1] = hh end
    end
    return out
end

-- Cash a household must keep after buying a home, for groceries until the first payday
-- (careers' economy value when present).
function HH.FoodBuffer()
    local CD = SS.CareerData
    local v = CD and type(CD.economy) == "table" and CD.economy.foodBuffer
    return type(v) == "number" and v or T.foodBuffer or 500
end

---------------------------------------------------------------------------
-- Creator specs
---------------------------------------------------------------------------
local function find(list, id) for _, e in ipairs(list) do if e.id == id then return e end end end
local function relKind(id) for _, k in ipairs(HD.RelKinds) do if k.id == id then return k end end end
HH.RelKind = relKind

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- Normalise one member's look (fills colours from ids, defaults missing parts).
function HH.NormalizeLook(look)
    look = type(look) == "table" and look or {}
    local out = {}
    local skin = find(HD.SkinTones, look.skinId) or HD.SkinTones[3]
    local hair = find(HD.HairColors, look.hairId) or HD.HairColors[3]
    out.skinId, out.skin = skin.id, { skin.c[1], skin.c[2], skin.c[3] }
    out.hairId, out.hair = hair.id, { hair.c[1], hair.c[2], hair.c[3] }
    out.hairStyle = find(HD.HairStyles, look.hairStyle) and look.hairStyle or "short"
    out.body = find(HD.Bodies, look.body) and look.body or "average"
    out.face = find(HD.Faces, look.face) and look.face or 1
    out.outfits = {}
    for _, kind in ipairs(HD.OutfitKinds) do
        local o = look.outfits and look.outfits[kind] or {}
        local styles = HD.OutfitStyles[kind]
        local function col(c, n) if type(c) == "table" and type(c[1]) == "number" then return { c[1], c[2], c[3] } end
            local d = HD.ClothColors[n]; return { d[1], d[2], d[3] } end
        out.outfits[kind] = { style = find(styles, o.style) and o.style or styles[1].id,
            top = col(o.top, 1), bottom = col(o.bottom, 2), shoes = col(o.shoes, 3) }
    end
    local e = out.outfits.everyday
    out.top, out.bottom, out.shoes = { e.top[1], e.top[2], e.top[3] }, { e.bottom[1], e.bottom[2], e.bottom[3] }, { e.shoes[1], e.shoes[2], e.shoes[3] }
    return out
end

-- Validate a creator spec: { name, bio, members = { { name, age, pronoun, bio, look, personality,
-- interests, rid? }... }, rels = { { a = index, b = index, kind = relKindId }... } }.
-- Returns ok, problems (player-facing sentences).
function HH.ValidateSpec(spec)
    local p = {}
    if type(spec) ~= "table" then return false, { "Nothing to save." } end
    local hn = trim(spec.name)
    if hn == "" then p[#p + 1] = "Give the household a name." end
    if #hn > T.householdNameMax then p[#p + 1] = "The household name is longer than " .. T.householdNameMax .. " letters." end
    if spec.bio and #tostring(spec.bio) > T.bioMax then p[#p + 1] = "The household description is longer than " .. T.bioMax .. " letters." end
    local m = spec.members or {}
    if #m < 1 then p[#p + 1] = "A household needs at least one person." end
    if #m > T.capacity then p[#p + 1] = "A household holds at most " .. T.capacity .. " people." end
    local adults, names = 0, {}
    for n, mem in ipairs(m) do
        local who = "Person " .. n
        local nm = trim(mem.name)
        if nm == "" then p[#p + 1] = who .. " needs a name."
        else
            who = nm
            if #nm > T.nameMax * 2 + 1 then p[#p + 1] = nm .. "'s name is too long." end
            if names[nm:lower()] then p[#p + 1] = "Two people are called " .. nm .. "." end
            names[nm:lower()] = true
        end
        if mem.age ~= "adult" and mem.age ~= "child" then p[#p + 1] = who .. " needs an age (adult or child)." end
        if mem.age == "adult" then adults = adults + 1 end
        if not inList(HD.Pronouns, mem.pronoun) then p[#p + 1] = who .. " needs pronouns." end
        if mem.bio and #tostring(mem.bio) > T.bioMax then p[#p + 1] = who .. "'s bio is too long." end
        local pers, sum = mem.personality or {}, 0
        for _, d in ipairs(HD.Dims) do
            local v = pers[d]
            if type(v) ~= "number" or v < 0 or v > T.personalityMax or v ~= math.floor(v) then
                p[#p + 1] = who .. ": " .. HD.DimInfo[d].name .. " must be a whole number from 0 to " .. T.personalityMax .. "."
            else sum = sum + v end
        end
        if sum > T.personalityBudget then p[#p + 1] = who .. " uses " .. sum .. " personality points; the budget is " .. T.personalityBudget .. "."
        else
            -- the social module's own check (the personality model belongs to it)
            local P = SS.Personality
            if P and P.Validate then
                local okc, valid, why = pcall(P.Validate, pers, T.personalityBudget)
                if okc and not valid then p[#p + 1] = who .. ": " .. tostring(why or "personality is not valid") end
            end
        end
        for k, v in pairs(mem.interests or {}) do
            if not H.TopicValid(k) then p[#p + 1] = who .. " has an unknown interest (" .. tostring(k) .. ")."
            elseif type(v) ~= "number" or v < 0 or v > T.interestMax then p[#p + 1] = who .. "'s interest in " .. k .. " is out of range." end
        end
        local look = mem.look or {}
        if look.skinId and not find(HD.SkinTones, look.skinId) then p[#p + 1] = who .. " has an unknown skin tone." end
        if look.hairStyle and not find(HD.HairStyles, look.hairStyle) then p[#p + 1] = who .. " has an unknown hair style." end
    end
    if #m > 0 and adults == 0 then p[#p + 1] = "Children cannot live on their own: add at least one adult." end
    local pairs_ = {}
    for _, rel in ipairs(spec.rels or {}) do
        local k = relKind(rel.kind)
        local a, b = m[rel.a], m[rel.b]
        if not k then p[#p + 1] = "Unknown relationship " .. tostring(rel.kind) .. "."
        elseif k.id ~= "none" then
            if not a or not b or rel.a == rel.b then p[#p + 1] = "A relationship needs two different people."
            else
                local key = math.min(rel.a, rel.b) .. "-" .. math.max(rel.a, rel.b)
                if pairs_[key] then p[#p + 1] = (a.name or "?") .. " and " .. (b.name or "?") .. " have two relationships set." end
                pairs_[key] = true
                if k.adultsOnly and (a.age ~= "adult" or b.age ~= "adult") then p[#p + 1] = k.name .. " is for two adults." end
                if k.id == "parent" and (a.age ~= "adult" or b.age ~= "child") then p[#p + 1] = "A parent must be an adult and the child a child." end
                if k.id == "child" and (a.age ~= "child" or b.age ~= "adult") then p[#p + 1] = "A child's parent must be an adult." end
            end
        end
    end
    return #p == 0, p
end

-- Needs for a freshly created person (the same for everyone; nothing depends on looks or pronouns).
local function freshNeeds()
    local out = {}
    for _, k in ipairs(SS.Tuning.needs) do out[k] = 50 end
    out.room = 20
    return out
end

local function personFromSpec(root, rid, mem, hhId)
    local src = {
        name = trim(mem.name), age = mem.age, pronoun = mem.pronoun, bio = mem.bio and trim(mem.bio) or nil,
        look = HH.NormalizeLook(mem.look), personality = {}, interests = {}, skills = {}, needs = freshNeeds(),
    }
    for _, d in ipairs(HD.Dims) do src.personality[d] = mem.personality[d] end
    for k, v in pairs(mem.interests or {}) do src.interests[k] = v end
    for _, s in ipairs((SS.Skills and SS.Skills.LIST) or { "cooking", "mechanical", "charisma", "body", "logic", "creativity" }) do src.skills[s] = 0 end
    return H.NewPerson(root, rid, src, hhId, nil)
end

-- The creator's kind of tie in a's record toward b: spouse, parent (a is b's parent), child,
-- sibling, roommate, partner or "none".
function HH.KindOf(r)
    if type(r) ~= "table" or type(r.flags) ~= "table" then return "none" end
    local f = r.flags.family
    if f == "spouse" then return "spouse" elseif f == "parent" then return "parent" elseif f == "child" then return "child"
    elseif f == "sibling" then return "sibling" elseif f == "roommate" or r.flags.roommate then return "roommate"
    elseif r.flags.partner then return "partner" end
    return "none"
end

local function relSpec(k, a, b, mode)
    local r = { a, b, ab = { k.daily or 20, k.life or 20 }, ba = { k.daily or 20, k.life or 20 }, mode = mode }
    if k.family then r.family = k.family end
    if k.flag == "partner" then r.flag = "partner" elseif k.flag == "roommate" then r.family = "roommate" end
    return r
end

-- Ties from a creator spec. `before` (HH.Update) maps "a>b" to the kind of tie the pair had
-- before the edit, for members who stay: an unchanged tie keeps its feelings exactly (only its
-- flags are asserted); a changed tie clears the old flags and raises feelings to at least the new
-- kind's starting values (a family tie drops romance); a pair that already knew each other and
-- gains a tie is raised the same way; a pair that never met starts at the kind's values; and a tie
-- the player removed loses its flags (feelings stay). Returns the number of ties set.
local function applySpecRels(root, ids, spec, before)
    local n, listed = 0, {}
    for _, rel in ipairs(spec.rels or {}) do
        local k = relKind(rel.kind)
        local a, b = ids[rel.a], ids[rel.b]
        if k and k.id ~= "none" and a and b then
            listed[a .. ">" .. b], listed[b .. ">" .. a] = true, true
            local old = before and before[a .. ">" .. b]
            local mode
            if old == k.id then mode = "keep"
            elseif old and old ~= "none" then
                H.ClearRelation(root, a, b)
                mode = "raise"
                if k.family and k.family ~= "spouse" and k.family ~= "roommate" then
                    for _, pr in ipairs({ { a, b }, { b, a } }) do
                        local r = H.PeekRel(root, pr[1], pr[2])
                        if r then r.romance = 0 end
                    end
                end
            else
                local ra, rb = H.PeekRel(root, a, b), H.PeekRel(root, b, a)
                if (ra and ra.flags and ra.flags.met) or (rb and rb.flags and rb.flags.met) then mode = "raise" end
            end
            H.ApplyRelation(root, relSpec(k, a, b, mode))
            n = n + 1
        end
    end
    if before then
        -- each removed pair once, whichever direction still carried the tie
        local keys, seen = {}, {}
        for key, old in pairs(before) do
            if old ~= "none" and not listed[key] then
                local a, b = key:match("^(.-)>(.+)$")
                if a and b then
                    local pk = a < b and (a .. ">" .. b) or (b .. ">" .. a)
                    if not seen[pk] then seen[pk] = true; keys[#keys + 1] = pk end
                end
            end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local a, b = key:match("^(.-)>(.+)$")
            H.ClearRelation(root, a, b)
        end
    end
    return n
end

-- Create a household from a creator spec. It goes to the household bin with the §9.7 starting
-- money. Returns hh or nil, why, problems.
function HH.Create(root, spec)
    root = rootOf(root)
    local ok, problems = HH.ValidateSpec(spec)
    if not ok then return nil, problems[1], problems end
    local id = H.NewHouseholdId(root)
    local hh = { id = id, name = trim(spec.name), bio = spec.bio and trim(spec.bio) or "", money = T.startMoney,
        members = {}, ledger = {}, journal = {}, inventory = {}, flags = { created = true }, tx = {},
        clock = T.newHouseholdTime }
    local ids = {}
    for n, mem in ipairs(spec.members) do
        local rid = H.NewResidentId(root, "rc")
        root.residents[rid] = personFromSpec(root, rid, mem, id)
        hh.members[n] = rid
        ids[n] = rid
    end
    root.households[id] = hh
    applySpecRels(root, ids, spec)
    hh.tx[1] = { id = "create:" .. id, t = hh.clock, amount = 0, cat = "start", text = "New household with " .. U.fmtMoney(hh.money) }
    SS.Emit("householdCreated", root, hh)
    return hh
end

-- A creator spec for an existing household (reopening it in the creator).
function HH.ToSpec(root, hhId)
    root = rootOf(root)
    local hh = root.households[hhId]
    if not hh then return nil, "That household no longer exists." end
    local spec = { id = hh.id, name = hh.name, bio = hh.bio, members = {}, rels = {} }
    local index = {}
    for _, rid in ipairs(hh.members) do
        local r = root.residents[rid]
        if r and not r.dead then
            local mem = { rid = rid, name = r.name, age = r.age, pronoun = r.pronoun or "they", bio = r.bio,
                look = U.deepcopy(r.look or {}), personality = U.deepcopy(r.personality or {}), interests = U.deepcopy(r.interests or {}) }
            spec.members[#spec.members + 1] = mem
            index[rid] = #spec.members
        end
    end
    local rel = root.social and root.social.rel or {}
    for a, ia in pairs(index) do
        for b, ib in pairs(index) do
            if ia < ib then
                local kind = HH.KindOf(rel[a .. ">" .. b])
                if kind ~= "none" then spec.rels[#spec.rels + 1] = { a = ia, b = ib, kind = kind } end
            end
        end
    end
    table.sort(spec.rels, function(x, y) if x.a ~= y.a then return x.a < y.a end return x.b < y.b end)
    return spec
end

-- Save an edited spec over an existing household: members keep their ids; new members join
-- (capacity 8); members dropped from the spec leave the household and stay in town.
function HH.Update(root, hhId, spec)
    root = rootOf(root)
    local hh = root.households[hhId]
    if not hh then return nil, "That household no longer exists." end
    local ok, problems = HH.ValidateSpec(spec)
    if not ok then return nil, problems[1], problems end
    -- the ties between the members who stay, as they were before this edit
    local before = {}
    do
        local stay = {}
        for _, mem in ipairs(spec.members) do
            local r = mem.rid and root.residents[mem.rid]
            if r and r.householdId == hhId then stay[#stay + 1] = mem.rid end
        end
        local rel = root.social and root.social.rel or {}
        for _, x in ipairs(stay) do
            for _, y in ipairs(stay) do
                if x ~= y then before[x .. ">" .. y] = HH.KindOf(rel[x .. ">" .. y]) end
            end
        end
    end
    local keep, ids, joined, left = {}, {}, {}, {}
    for n, mem in ipairs(spec.members) do
        local r = mem.rid and root.residents[mem.rid]
        if r and r.householdId == hhId then
            r.name, r.age, r.pronoun, r.bio = trim(mem.name), mem.age, mem.pronoun, mem.bio and trim(mem.bio) or r.bio
            r.look = HH.NormalizeLook(mem.look)
            for _, d in ipairs(HD.Dims) do r.personality[d] = mem.personality[d] end
            r.interests = {}
            for k, v in pairs(mem.interests or {}) do r.interests[k] = v end
            ids[n] = r.id
        else
            local rid = H.NewResidentId(root, "rc")
            local p = personFromSpec(root, rid, mem, hhId)
            root.residents[rid] = p
            if hh.lotId then placeAtHome(root, hh, p, n) end
            ids[n] = rid
            joined[#joined + 1] = rid
        end
        keep[ids[n]] = true
    end
    local members = {}
    for _, rid in ipairs(hh.members) do
        local r = root.residents[rid]
        if keep[rid] or (r and r.dead) then members[#members + 1] = rid
        elseif r then
            -- left the household in the creator: stays in town as a townie, off the lot
            leave(root, rid)
            H.MarkLeft(root, r, hh.lotId)
            r.householdId, r.townie = nil, true; r.lotId = nil; clearRuntime(r)
            left[#left + 1] = rid
        end
    end
    for n = 1, #spec.members do if not inList(members, ids[n]) then members[#members + 1] = ids[n] end end
    hh.members = members
    hh.name, hh.bio = trim(spec.name), spec.bio and trim(spec.bio) or hh.bio
    applySpecRels(root, ids, spec, before)
    for _, rid in ipairs(left) do SS.Emit("residentMoved", root, rid, hhId, nil) end
    for _, rid in ipairs(joined) do left[#left + 1] = rid end
    H.SyncSession(root, left)
    SS.Emit("householdUpdated", root, hh)
    return hh
end

---------------------------------------------------------------------------
-- Delete
---------------------------------------------------------------------------
local function dropRelations(root, rid)
    local rel = root.social and root.social.rel
    if not rel then return end
    local pre, post = rid .. ">", ">" .. rid
    for _, k in ipairs(sortedKeys(rel)) do
        if k:sub(1, #pre) == pre or k:sub(-#post) == post then rel[k] = nil end
    end
end

-- Delete a household without a home. Its people are removed unless they live elsewhere (are on
-- another lot right now, or already belong to another household): those stay in town.
function HH.Delete(root, hhId)
    root = rootOf(root)
    local hh = root.households[hhId]
    if not hh then return false, "That household no longer exists." end
    if hh.lotId then return false, "The " .. hh.name .. " household still lives at " .. (root.hood.lots[hh.lotId].address or hh.lotId) .. ". Move them out first." end
    if root.active and root.active.householdId == hhId then return false, "You are playing the " .. hh.name .. " household. Switch to another household first." end
    local removed, kept, gone = 0, 0, {}
    for _, rid in ipairs(hh.members) do
        local r = root.residents[rid]
        if r and r.householdId == hhId then
            if r.lotId then
                r.householdId, r.townie = nil, true
                kept = kept + 1
            else
                root.residents[rid] = nil
                dropRelations(root, rid)
                removed = removed + 1
                gone[#gone + 1] = rid
            end
        end
    end
    root.households[hhId] = nil
    dropEvents(root, "hh:" .. hhId)
    H.SyncSession(root, gone)
    -- siblings drop what they keep about people who no longer exist (visit requests, calls, ...)
    if #gone > 0 then SS.Emit("residentsDeleted", root, gone, hhId) end
    SS.Emit("householdDeleted", root, hhId)
    return true, string.format("Deleted the %s household (%d removed, %d staying in town).", hh.name, removed, kept)
end

---------------------------------------------------------------------------
-- Move in / move out
---------------------------------------------------------------------------
-- Price and checks for moving `hhId` into `lotId`. Returns quote table (ok, why, price parts).
function HH.MoveInQuote(root, hhId, lotId)
    root = rootOf(root)
    local hh, lot = root.households[hhId], root.hood.lots[lotId]
    local q = { ok = false }
    if not hh then q.why = "That household no longer exists."; return q end
    if not lot then q.why = "Unknown lot."; return q end
    q.total, q.land, q.structure, q.contents = H.Appraise(root, lot, nil)
    q.money = hh.money or 0
    q.after = q.money - q.total
    if lot.kind == "community" then q.why = "Nobody can live at a community venue."; return q end
    if H.IsService(hh) then q.why = hh.name .. " is run by the town and never moves into a home."; return q end
    if H.IsEnded(hh) then q.why = "The story of the " .. hh.name .. " household has ended."; return q end
    if hh.lotId then q.why = "The " .. hh.name .. " household already has a home. Move them out first."; return q end
    local owner = H.Owner(root, lotId)
    if owner then q.why = "The " .. owner.name .. " household lives there."; return q end
    if #living(root, hh) == 0 then q.why = "Nobody is left in the " .. hh.name .. " household."; return q end
    if root.outing then q.why = "Finish the current outing first."; return q end
    if q.total > q.money then
        q.why = string.format("%s costs %s; the %s household has %s.", lot.address or lotId, U.fmtMoney(q.total), hh.name, U.fmtMoney(q.money))
        return q
    end
    q.buffer = HH.FoodBuffer()
    if q.after < q.buffer then
        q.why = string.format("%s costs %s. Buying it would leave the %s household %s, less than %s for groceries until the first payday.",
            lot.address or lotId, U.fmtMoney(q.total), hh.name, U.fmtMoney(q.after), U.fmtMoney(q.buffer))
        return q
    end
    q.ok = true
    q.text = string.format("Move the %s household into %s for %s (land %s, building %s, furnishings %s). They keep %s.",
        hh.name, lot.address or lotId, U.fmtMoney(q.total), U.fmtMoney(q.land), U.fmtMoney(q.structure), U.fmtMoney(q.contents), U.fmtMoney(q.after))
    return q
end

-- opts.tx: the caller's transaction id (a repeated id is refused before anything changes).
function HH.MoveIn(root, hhId, lotId, opts)
    root = rootOf(root)
    local tx, whyTx = txFor(root, root.households[hhId], opts, "movein")
    if not tx then return false, whyTx, { ok = false, why = whyTx } end
    local q = HH.MoveInQuote(root, hhId, lotId)
    if not q.ok then return false, q.why, q end
    local hh, lot = root.households[hhId], root.hood.lots[lotId]
    local ok, why = HH.Settle(root, hh, -q.total, "property", "Bought " .. (lot.address or lotId), tx)
    if not ok then return false, why, q end
    hh.lotId = lotId
    lot.forSale = nil
    local n, moved = 0, {}
    for _, rid in ipairs(hh.members) do
        local r = root.residents[rid]
        if r and not r.dead then
            n = n + 1
            leave(root, rid)
            placeAtHome(root, hh, r, n)
            moved[#moved + 1] = rid
        end
    end
    parkEvents(root, "hh:" .. hh.id, lotId)
    local cur = root.active and root.households[root.active.householdId]
    if not cur or not H.Playable(root, cur) then
        -- nobody playable was being played: the household moving in is played from now on
        if not (root.pendingEnd and cur and root.pendingEnd.hh == cur.id) then H.Handover(root, hh); q.activeChanged = true end
    end
    H.SyncSession(root, moved)
    -- visitors' welcome visit follows once (flags.movedInAt, the "movedIn" event)
    hh.flags = type(hh.flags) == "table" and hh.flags or {}
    hh.flags.movedInAt = H.Clock(root, hh)
    hh.flags.welcomed, hh.flags.welcomeScheduled = nil, nil   -- a new home, a new welcome
    SS.Emit("householdMoved", root, hh, nil, lotId, "in")
    local w = SS.Sim and SS.Sim.world
    SS.Emit("movedIn", (w and w.root == root and w.household == hh) and w or root, hh.id)
    return true, q.text, q
end

-- mode: "sell" (everything stays and is sold with the house) | "pack" (furniture goes to the
-- household inventory; land and building are sold).
function HH.MoveOutQuote(root, hhId, mode)
    root = rootOf(root)
    local hh = root.households[hhId]
    local q = { ok = false, mode = mode }
    if not hh then q.why = "That household no longer exists."; return q end
    if not hh.lotId then q.why = "The " .. hh.name .. " household has no home to leave."; return q end
    if H.IsEnded(hh) then q.why = "The story of the " .. hh.name .. " household has ended. Put the house on the market instead."; return q end
    if mode ~= "sell" and mode ~= "pack" then q.why = "Choose to sell or pack the furniture."; return q end
    local lot = root.hood.lots[hh.lotId]
    q.total, q.land, q.structure, q.contents = H.Appraise(root, lot, hh)
    q.packValue, q.packCount = H.PackableValue(root, lot, hh)
    q.credit = (mode == "sell") and q.total or math.max(0, q.total - q.packValue)
    if root.outing then q.why = "Finish the current outing first."; return q end
    local others = 0
    for _, o in ipairs(HH.List(root)) do if o ~= hh and H.Playable(root, o) then others = others + 1 end end
    if others == 0 then q.why = "At least one household must keep a home, or there is nobody left to play."; return q end
    q.ok = true
    if mode == "sell" then
        q.text = string.format("Sell %s with its furniture for %s. The %s household goes to the household bin with %s.",
            lot.address, U.fmtMoney(q.credit), hh.name, U.fmtMoney((hh.money or 0) + q.credit))
    else
        q.text = string.format("Sell the land and building of %s for %s and pack %d pieces of furniture (worth %s) into the household inventory.",
            lot.address, U.fmtMoney(q.credit), q.packCount, U.fmtMoney(q.packValue))
    end
    return q
end

-- opts.tx: the caller's transaction id (a repeated id is refused before anything changes).
-- When the played household moves out, play passes to the next household with a home through
-- H.Play (H.Handover), so its members come home, starter jobs start and householdPlayed is heard.
function HH.MoveOut(root, hhId, mode, opts)
    root = rootOf(root)
    local tx, whyTx = txFor(root, root.households[hhId], opts, "moveout")
    if not tx then return false, whyTx, { ok = false, why = whyTx } end
    local q = HH.MoveOutQuote(root, hhId, mode)
    if not q.ok then return false, q.why, q end
    local hh = root.households[hhId]
    local lotId = hh.lotId
    local lot = root.hood.lots[lotId]
    local wasActive = root.active and root.active.householdId == hhId
    -- furniture first (pack), then the single money settlement
    if mode == "pack" then
        local view = H.View(root, hh)
        local packed = 0
        for _, oid in ipairs(sortedKeys(lot.objects)) do
            local o = lot.objects[oid]
            if o and H.Movable(o) then
                local def = SS.Objects[o.def]
                local val
                if SS.Economy and SS.Economy.ResaleValue then local okv, v = pcall(SS.Economy.ResaleValue, view, o); val = okv and v or nil end
                val = val or math.floor((def.price or 0) * 0.8)
                local item = { kind = "object", def = o.def, name = def.name, value = val,
                    data = { variant = o.variant, state = o.state and U.deepcopy(o.state) or nil, paid = o.paid, bought = o.bought } }
                if SS.Inventory and SS.Inventory.Add then SS.Inventory.Add(view, item)
                else hh.inventory = hh.inventory or {}; hh.inventory[#hh.inventory + 1] = item end
                lot.objects[oid] = nil
                packed = packed + 1
            end
        end
        -- anything left standing on a packed parent drops to the floor record-wise
        for _, o in pairs(lot.objects) do if o.parent and not lot.objects[o.parent] then o.parent, o.pslot = nil, nil end end
        lot.version = (lot.version or 1) + 1
        q.packed = packed
    end
    local ok, why = HH.Settle(root, hh, q.credit, "property", (mode == "sell" and "Sold " or "Sold (furniture packed) ") .. (lot.address or lotId), tx)
    if not ok then return false, why, q end
    local left = {}
    for _, rid in ipairs(hh.members) do
        local r = root.residents[rid]
        if r and r.lotId == lotId then
            leave(root, rid)
            r.lotId, r.x, r.y, r.level = nil, 0.5, 0.5, 0; clearRuntime(r)
            left[#left + 1] = rid
        end
    end
    parkEvents(root, lotId, "hh:" .. hh.id)
    hh.lotId = nil
    if wasActive then
        -- the household keeps its own clock; the next household with a home is played
        local nxt = H.NextPlayable(root, hh.id)
        if nxt then H.Handover(root, nxt) else hh.clock = root.time end
        q.activeChanged = true
    end
    H.SyncSession(root, left)
    SS.Emit("householdMoved", root, hh, lotId, nil, mode)
    SS.Emit("lotChanged", "moveout", lotId)
    return true, q.text, q
end

---------------------------------------------------------------------------
-- Members: evict, move between households, merge
---------------------------------------------------------------------------
-- Evict one member: they leave with an equal share of the savings and start their own household
-- in the bin. Returns ok, why, newHousehold.
function HH.Evict(root, hhId, rid, opts)
    root = rootOf(root)
    local hh = root.households[hhId]
    if not hh then return false, "That household no longer exists." end
    local tx, whyTx = txFor(root, hh, opts, "evict")
    if not tx then return false, whyTx end
    local r = root.residents[rid]
    if not r or r.householdId ~= hhId or not inList(hh.members, rid) then return false, "They are not in the " .. hh.name .. " household." end
    if r.dead then return false, r.name .. " has passed away." end
    if r.age ~= "adult" then return false, "Children cannot live on their own." end
    local alive = living(root, hh)
    if #alive < 2 then return false, r.name .. " is the whole household. Move the household out instead." end
    local restAdults = adultsIn(alive) - 1
    local restKids = #alive - adultsIn(alive)
    if restAdults == 0 and restKids > 0 then return false, "The children need an adult at home." end
    if root.outing then return false, "Finish the current outing first." end
    local share = math.floor(math.max(0, hh.money or 0) / #alive)
    local nid = H.NewHouseholdId(root)
    local surname = r.name:match("(%S+)$") or r.name
    local new = { id = nid, name = surname, bio = r.name .. " moved out of the " .. hh.name .. " household.", money = 0,
        members = { rid }, ledger = {}, journal = {}, inventory = {}, flags = { created = true }, tx = {}, clock = H.Clock(root, hh) }
    root.households[nid] = new
    HH.Settle(root, hh, -share, "household", r.name .. " moved out with their share", tx .. ":out")
    HH.Settle(root, new, share, "household", "Share of the " .. hh.name .. " savings", tx .. ":in")
    table.remove(hh.members, inList(hh.members, rid))
    leave(root, rid)
    H.MarkLeft(root, r, hh.lotId)
    r.householdId = nid
    r.lotId, r.x, r.y, r.level = nil, 0.5, 0.5, 0
    clearRuntime(r)
    H.SyncSession(root, { rid })
    SS.Emit("residentMoved", root, rid, hhId, nid)
    return true, string.format("%s moved out with %s.", r.name, U.fmtMoney(share)), new
end

-- Move one resident into another household (8 living members at most).
function HH.MoveResident(root, rid, toId)
    root = rootOf(root)
    local r = root.residents[rid]
    local to = root.households[toId]
    if not r or r.dead then return false, "Nobody to move." end
    if not to then return false, "That household no longer exists." end
    if H.IsService(to) then return false, to.name .. " is run by the town; people only go there through the family module." end
    if H.IsEnded(to) then return false, "The story of the " .. to.name .. " household has ended." end
    local fromId = r.householdId
    local from = fromId and root.households[fromId]
    if from and H.IsService(from) then return false, r.name .. " is in the care of " .. from.name .. "." end
    if fromId == toId then return false, r.name .. " already lives with the " .. to.name .. " household." end
    if #living(root, to) >= T.capacity then return false, "The " .. to.name .. " household is full (" .. T.capacity .. " people)." end
    if root.outing then return false, "Finish the current outing first." end
    if from then
        local alive = living(root, from)
        if #alive == 1 and from.lotId then return false, r.name .. " is the whole " .. from.name .. " household. Merge the households instead." end
        if r.age == "adult" and adultsIn(alive) == 1 and #alive > 1 then return false, "The children would be left without an adult." end
        if root.active and root.active.householdId == fromId and #alive == 1 then return false, "You are playing the " .. from.name .. " household. Switch first." end
        table.remove(from.members, inList(from.members, rid))
    end
    to.members[#to.members + 1] = rid
    r.householdId, r.townie = toId, nil
    leave(root, rid)
    placeAtHome(root, to, r, #to.members, from and from.lotId)
    if from and #living(root, from) == 0 and not from.lotId then
        -- the old household is empty: its savings follow the resident, then it is removed
        local amount = from.money or 0
        local tx = nextTx(root, "merge")
        if amount ~= 0 then
            HH.Settle(root, from, -amount, "household", "Savings moved to the " .. to.name .. " household", tx .. ":out")
            HH.Settle(root, to, amount, "household", r.name .. " brought savings", tx .. ":in")
        end
        root.households[fromId] = nil
        dropEvents(root, "hh:" .. fromId)
        SS.Emit("householdDeleted", root, fromId)
    end
    H.SyncSession(root, { rid })
    SS.Emit("residentMoved", root, rid, fromId, toId)
    return true, r.name .. " now lives with the " .. to.name .. " household."
end

-- Merge household `fromId` into `intoId`: people, savings and (when only `from` has one) home.
function HH.Merge(root, fromId, intoId, opts)
    root = rootOf(root)
    local from, into = root.households[fromId], root.households[intoId]
    if not from or not into then return false, "That household no longer exists." end
    local tx, whyTx = txFor(root, into, opts, "merge")
    if not tx then return false, whyTx end
    if fromId == intoId then return false, "Choose two different households." end
    for _, h in ipairs({ from, into }) do
        if H.IsService(h) then return false, h.name .. " is run by the town and cannot merge." end
        if H.IsEnded(h) then return false, "The story of the " .. h.name .. " household has ended." end
    end
    local total = #living(root, from) + #living(root, into)
    if total > T.capacity then return false, string.format("Together they would be %d people; a household holds at most %d.", total, T.capacity) end
    if from.lotId and into.lotId then return false, "Both households have a home. Move one of them out first." end
    if root.outing then return false, "Finish the current outing first." end
    local amount = from.money or 0
    if amount ~= 0 then
        HH.Settle(root, from, -amount, "household", "Savings moved to the " .. into.name .. " household", tx .. ":out")
        HH.Settle(root, into, amount, "household", "The " .. from.name .. " household moved in", tx .. ":in")
    end
    if from.lotId and not into.lotId then
        into.lotId = from.lotId
        parkEvents(root, "hh:" .. into.id, into.lotId)
    end
    for _, item in ipairs(from.inventory or {}) do into.inventory = into.inventory or {}; into.inventory[#into.inventory + 1] = item end
    -- everyone lives at the merged household's home; people already there stay where they stand
    local moved = {}
    local function settle(rid, n)
        local r = root.residents[rid]
        if r and not r.dead and r.lotId ~= into.lotId then
            leave(root, rid)
            placeAtHome(root, into, r, n)
            moved[#moved + 1] = rid
        end
    end
    for _, rid in ipairs(from.members) do
        local r = root.residents[rid]
        if r then
            into.members[#into.members + 1] = rid
            r.householdId = intoId
        end
    end
    for n, rid in ipairs(into.members) do settle(rid, n) end
    local wasPlayed = root.active and root.active.householdId == fromId
    if wasPlayed then
        -- the played household merged away: the merged household is played from now on, on the
        -- clock that was running (its own paused clock is dropped)
        root.active = { householdId = intoId, lotId = into.lotId }
        into.clock = nil
    elseif root.active and root.active.householdId == intoId then
        root.active.lotId = into.lotId
    end
    root.households[fromId] = nil
    dropEvents(root, "hh:" .. fromId)
    -- the session follows: a merged-away played household is attached again as the merged one
    -- (H.Play), and people who joined the played household's home become actors there
    H.SyncSession(root, moved)
    SS.Emit("householdsMerged", root, into, fromId)
    return true, string.format("The %s household joined the %s household.", from.name, into.name)
end

---------------------------------------------------------------------------
-- Family and events contracts: transfers, closing and ending a household
---------------------------------------------------------------------------
local function removeAll(list, v)
    for n = #list, 1, -1 do if list[n] == v then table.remove(list, n) end end
end

local function humansIn(root, hh)
    local n = 0
    for _, r in ipairs(living(root, hh)) do if r.kind == nil or r.kind == "human" then n = n + 1 end end
    return n
end

-- Move one resident (a person or a pet) into household `toId` for the family module (moving in,
-- births, adoptions, care). Guarantees: the resident is listed exactly once (out of the old
-- household's members, appended to the new one) and r.householdId = toId.
-- opts.money == "sole": when the mover was the last living member of the old household, its cash
-- moves in one ledger entry per side (never into or out of a service household) and the old
-- household closes; otherwise no money moves. opts.keepOpen: never close the old household here.
-- opts.reason: the closing reason. Position on a lot is the caller's business (not changed here).
-- Emits householdChanged(world, rid, fromId, toId) and residentMoved. Returns ok, movedAmount | why.
function HH.Transfer(world, rid, toId, opts)
    opts = type(opts) == "table" and opts or {}
    local root = rootOf(world)
    local r = root.residents[rid]
    local to = root.households[toId]
    if not r then return false, "That person no longer exists." end
    if not to then return false, "That household no longer exists." end
    to.members = type(to.members) == "table" and to.members or {}
    local fromId = r.householdId
    local from = fromId and root.households[fromId]
    if fromId == toId then
        if not inList(to.members, rid) then to.members[#to.members + 1] = rid end
        return true, 0
    end
    if H.IsEnded(to) then return false, "The story of the " .. (to.name or "?") .. " household has ended." end
    local human = r.kind == nil or r.kind == "human"
    if human and not r.dead and not H.IsService(to) and humansIn(root, to) >= T.capacity then
        return false, "The " .. (to.name or "?") .. " household is full (" .. T.capacity .. " people)."
    end
    if from then removeAll(from.members or {}, rid) end
    removeAll(to.members, rid)
    to.members[#to.members + 1] = rid
    r.householdId = toId
    if not H.IsService(to) then r.townie = nil end
    local moved = 0
    if from and not H.IsService(from) and not opts.keepOpen and #living(root, from) == 0 then
        if opts.money == "sole" and (from.money or 0) > 0 and not H.IsService(to) then
            moved = from.money
            local tx = nextTx(root, "transfer")
            HH.Settle(root, from, -moved, "household", (r.name or "?") .. " moved out and took the household savings", tx .. ":out")
            HH.Settle(root, to, moved, "household", (r.name or "?") .. " moved in with their savings", tx .. ":in")
        end
        HH.Close(world, fromId, opts.reason or "everyone moved out")
    end
    SS.Emit("householdChanged", world, rid, fromId, toId)
    SS.Emit("residentMoved", root, rid, fromId, toId)
    return true, moved
end

-- Close a household nobody is left in (family: everyone moved out or went into care). The record
-- stays (members, deceased, ledger, relationships); flags.ended = { t, reason, lotId } is set when
-- the caller has not set it; its lot is released (on the market, contents and memorials as they
-- are) and nobody is deleted or moved. The played household is not switched here: the attached
-- session keeps running until the player picks another household (H.Play, the neighbourhood, or
-- the save validator on the next load). Returns ok, text.
function HH.Close(world, hhId, reason)
    local root = rootOf(world)
    local hh = root.households[hhId]
    if not hh then return false, "That household no longer exists." end
    if H.IsService(hh) then return false, hh.name .. " is run by the town and never closes." end
    hh.flags = type(hh.flags) == "table" and hh.flags or {}
    if not hh.flags.ended then hh.flags.ended = { t = H.Clock(root, hh), reason = reason or "closed", lotId = hh.lotId } end
    if type(hh.flags.ended) == "table" then hh.flags.ended.lotId = hh.flags.ended.lotId or hh.lotId end
    local lotId = hh.lotId
    local lot = lotId and root.hood.lots[lotId]
    if lotId then
        -- a closed household is never played again: what was scheduled for its home is dropped
        dropEvents(root, lotId)
        hh.lotId = nil
        if lot then lot.forSale = true end
        SS.Emit("lotChanged", "closed", lotId)
    end
    SS.Emit("householdClosed", root, hh, reason)
    return true, "The " .. (hh.name or "?") .. " household has closed" .. (lot and ("; " .. (lot.address or lotId) .. " is on the market.") or ".")
end

-- End a household (family: nobody controllable is left). The same as Close.
function HH.End(world, hhId, reason) return HH.Close(world, hhId, reason or "ended") end

---------------------------------------------------------------------------
-- Bulldoze
---------------------------------------------------------------------------
function HH.BulldozeCheck(root, lotId)
    root = rootOf(root)
    local lot = root.hood.lots[lotId]
    if not lot then return false, "Unknown lot." end
    if lot.kind == "community" then return false, "Community venues can be edited but not bulldozed." end
    local owner = H.Owner(root, lotId)
    if owner then return false, "The " .. owner.name .. " household lives there. Move them out first; bulldozing never removes anyone." end
    if root.outing and root.outing.lotId == lotId then return false, "An outing is under way there." end
    return true
end

-- Clear a vacant residential lot to bare land (a mailbox stays by the entry). Nobody is harmed:
-- anyone standing there is sent home first.
function HH.Bulldoze(root, lotId)
    root = rootOf(root)
    local ok, why = HH.BulldozeCheck(root, lotId)
    if not ok then return false, why end
    local lot = root.hood.lots[lotId]
    for _, rid in ipairs(sortedKeys(root.residents)) do
        local r = root.residents[rid]
        if r.lotId == lotId then leave(root, rid); r.lotId, r.x, r.y, r.level = nil, 0.5, 0.5, 0; clearRuntime(r) end
    end
    local grass = HL.Finish("floors", { "grass", "lawn" }, "grass")
    lot.floor = { [0] = {}, [1] = {} }
    for j = 0, lot.h - 1 do for i = 0, lot.w - 1 do lot.floor[0][j * lot.w + i + 1] = grass end end
    lot.walls = { [0] = {}, [1] = {} }
    lot.objects = {}
    lot.pool, lot.diag, lot.terrain, lot.roof, lot.fires = nil, nil, nil, nil, nil
    lot.frontDoor, lot.spawn, lot.mailbox = nil, nil, nil
    lot.empty = true
    lot.version = (lot.version or 1) + 1
    lot.desc = "Cleared land, ready for building."
    HL.AddMailbox(lot)
    -- whatever was scheduled for the old house (a leak, a visit) goes with it
    dropEvents(root, lotId)
    -- an edit session open on this lot sees bare land at once
    local w = H.Session(root)
    if w and w.lot == lot and SS.World and SS.World.Rebuild then pcall(SS.World.Rebuild, w) end
    SS.Emit("lotBulldozed", root, lotId)
    SS.Emit("lotChanged", "bulldoze", lotId)
    return true, (lot.address or lotId) .. " is bare land now."
end
