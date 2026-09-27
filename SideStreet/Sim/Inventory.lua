-- Household inventory: stored objects, bought goods, gifts, books, clothing, produce.
-- Owner: catalogue module. Notes: docs/modules/catalogue.md ("Inventory").
--
-- Saved in household.inventory (an array, oldest first). Other modules add their own items:
--   item = { id = "i<n>" (assigned), kind = "object"|"gift"|"book"|"clothing"|"food"|"produce"|...,
--            def = objectDefId? (kind "object"), name, value (resale value in §), t (time added),
--            data = { ... } }   -- data is owned by whoever added the item
-- Object items (kind "object") come from Sim/Placement.lua (P.Store) or from shops (outings): their
-- data may carry variant, state, bought, paid, used and children = { { def, variant, pslot, state,
-- bought, paid, used }, ... } for things that were resting on the object's surfaces.
-- Every change emits SS.Emit("inventory", world, "add"|"remove", item).
--
-- Limits (the stub's contract is kept: an add from the game itself is never refused):
--   Inv.CAP  (200) is the storage limit for what the PLAYER chooses to put in: buy mode's Store
--            (Placement), shop purchases (outings) and gifts (social) check Inv.Full / Inv.Room first
--            and refuse with a reason. Inv.Add(world, item, { player = true }) applies it too.
--   Everything the game moves in by itself (furniture that lost its wall, a move-out, build edits,
--   undo, produce, crafts, parcels, the save validator) is always accepted, above CAP too, so
--   nothing is ever lost. Only Inv.HARD (1000) bounds the list: past it, loose goods (anything
--   that is not an object) are refused with a notice; furniture is still accepted, since it comes
--   off a lot and the lot's own size bounds it. Saves are never trimmed.
-- A lot edited from the neighbourhood (hood's H.EditSession: world.editVenue / world.editSession)
-- has no household inventory: world.household there is only the viewer, the household the player
-- plays, which does not own the lot. Nothing is added to it from such a session (Inv.Add refuses
-- with a notice, whoever calls it), so no furniture or value moves from an edited lot to the
-- played household. Placement's own paths ask SS.Placement.InventoryHere first; this also covers
-- callers that do not (build's displaced furniture, docs/requests/catalogue.md BU-1).
local _, SS = ...
local Inv = {}
SS.Inventory = Inv

Inv.CAP = 200    -- what the player can choose to store (Store, shops, gifts)
Inv.HARD = 1000  -- absolute bound for loose goods added by the game (objects are never refused)

local function list(world)
    local hh = world and world.household
    if not hh then return nil end
    hh.inventory = hh.inventory or {}
    return hh.inventory, hh
end

-- Fill the fields every item needs. Returns the item.
function Inv.Normalize(hh, item)
    item.kind = item.kind or "misc"
    item.data = type(item.data) == "table" and item.data or {}
    local def = item.def and SS.Objects[item.def]
    if not item.name then item.name = def and def.name or item.kind end
    if type(item.value) ~= "number" then item.value = def and def.price or 0 end
    if not item.id then
        hh.nextInv = (hh.nextInv or 0) + 1
        item.id = "i" .. hh.nextInv
    end
    return item
end

-- How many items a household holds (the played one, or a household record).
local function countOf(hh)
    return type(hh) == "table" and type(hh.inventory) == "table" and #hh.inventory or 0
end
-- Is the player's storage full? (the played household, or `hh`, a household record)
function Inv.Full(world, hh) return countOf(hh or (world and world.household)) >= Inv.CAP end
-- Free places left for the player's own choices (never negative).
function Inv.Room(world, hh) return math.max(0, Inv.CAP - countOf(hh or (world and world.household))) end

-- May this item go into a list of n items? Returns ok, why. opts.player: the player chose it (CAP).
local function admit(n, item, opts, whose)
    if opts and opts.player and n >= Inv.CAP then
        return false, (whose or "The household") .. " inventory is full (" .. Inv.CAP .. " items). Sell or place something first."
    end
    if n >= Inv.HARD and item.kind ~= "object" then
        return false, (whose or "The household") .. " storage is overflowing (" .. n .. " items): the " .. tostring(item.name or item.kind or "item") .. " could not be kept."
    end
    return true
end

-- Is this world a lot edited from the neighbourhood (no household inventory; see the header)?
local function editing(world)
    return world and (world.editVenue or world.editSession) and true or false
end
Inv.Editing = editing

-- Add an item to the household's inventory. Returns item, or nil and a reason.
-- Never refused for objects (except from a lot edited from the neighbourhood, which has no
-- household inventory); loose goods only past Inv.HARD; opts.player applies the CAP.
function Inv.Add(world, item, opts)
    local inv, hh = list(world)
    if not inv then return nil, "There is no household here to keep it." end
    if type(item) ~= "table" then return nil, "Nothing to add." end
    if editing(world) then
        local def = item.def and SS.Objects[item.def]
        local name = tostring(item.name or (def and def.name) or item.kind or "item")
        local why = "Nothing goes to the household inventory while a lot is edited from the neighbourhood: nobody keeps the "
            .. name .. " (undo the edit to get it back)."
        if not (opts and opts.player) then SS.Emit("notice", nil, why) end
        return nil, why
    end
    local ok, why = admit(#inv, item, opts)
    if not ok then
        if not (opts and opts.player) then SS.Emit("notice", nil, why) end
        return nil, why
    end
    Inv.Normalize(hh, item)
    item.t = item.t or world.time
    inv[#inv + 1] = item
    SS.Emit("inventory", world, "add", item)
    return item
end

-- Add an item to any household's inventory (gifts handed to another household: social module).
-- The active household goes through Inv.Add; others are written straight into the save root.
-- Same rules as Inv.Add. Returns item, or nil and a reason.
function Inv.AddToHousehold(world, householdId, item, opts)
    if world.household and world.household.id == householdId then return Inv.Add(world, item, opts) end
    local root = world.root or world
    local hh = root.households and root.households[householdId]
    if type(hh) ~= "table" then return nil, "That household no longer exists." end
    if type(item) ~= "table" then return nil, "Nothing to add." end
    hh.inventory = type(hh.inventory) == "table" and hh.inventory or {}
    local ok, why = admit(#hh.inventory, item, opts, "Their")
    if not ok then return nil, why end
    Inv.Normalize(hh, item)
    item.t = item.t or world.time
    hh.inventory[#hh.inventory + 1] = item
    SS.Emit("inventory", world, "add", item, householdId)
    return item
end

-- Remove an item (by reference or id). Returns true if it was there.
function Inv.Remove(world, item)
    local inv = list(world) or {}
    for n = #inv, 1, -1 do
        if inv[n] == item or (type(item) == "string" and inv[n].id == item) then
            local it = table.remove(inv, n)
            SS.Emit("inventory", world, "remove", it)
            return true
        end
    end
    return false
end

-- Items, optionally of one kind, in inventory order.
function Inv.List(world, kind)
    local out = {}
    for _, it in ipairs(world.household and world.household.inventory or {}) do
        if not kind or it.kind == kind then out[#out + 1] = it end
    end
    return out
end

function Inv.Get(world, id)
    for _, it in ipairs(world.household and world.household.inventory or {}) do
        if it.id == id then return it end
    end
end

function Inv.Count(world, kind) return #Inv.List(world, kind) end

-- Total resale value of everything stored (net worth uses item.value too).
function Inv.Value(world)
    local v = 0
    for _, it in ipairs(world.household and world.household.inventory or {}) do v = v + (tonumber(it.value) or 0) end
    return v
end

-- Put an item back at a given position (undo of a removal keeps the original order).
function Inv.Insert(world, item, pos)
    local inv, hh = list(world)
    if not inv or editing(world) then return nil end
    Inv.Normalize(hh, item)
    pos = math.max(1, math.min(pos or (#inv + 1), #inv + 1))
    table.insert(inv, pos, item)
    SS.Emit("inventory", world, "add", item)
    return item
end

function Inv.IndexOf(world, item)
    for n, it in ipairs(world.household and world.household.inventory or {}) do if it == item then return n end end
end

-- Save validation: every household's inventory is an array of item tables; object items whose
-- definition no longer exists are dropped (with a problem line) so saves never break. A list above
-- Inv.CAP is kept whole (the game may put furniture there past the player's limit): never trimmed.
if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        for hid, hh in pairs(root.households or {}) do
            if type(hh) == "table" then
                if hh.inventory ~= nil and type(hh.inventory) ~= "table" then
                    hh.inventory = {}
                    problems[#problems + 1] = "inventory reset for " .. tostring(hid)
                end
                local inv = hh.inventory or {}
                local keep, seen = {}, {}
                for _, it in ipairs(inv) do
                    local ok = type(it) == "table"
                    if ok and it.kind == "object" and not SS.Objects[it.def or ""] then
                        ok = false
                        problems[#problems + 1] = "dropped stored object with unknown design " .. tostring(it.def) .. " from " .. tostring(hid)
                    end
                    if ok and type(it.data) == "table" and type(it.data.children) == "table" then
                        local kids = {}
                        for _, c in ipairs(it.data.children) do
                            if type(c) == "table" and SS.Objects[c.def or ""] then kids[#kids + 1] = c
                            else problems[#problems + 1] = "dropped a stored item's unknown attachment in " .. tostring(hid) end
                        end
                        it.data.children = kids
                    end
                    if ok then
                        Inv.Normalize(hh, it)
                        if seen[it.id] then hh.nextInv = (hh.nextInv or 0) + 1; it.id = "i" .. hh.nextInv end
                        seen[it.id] = true
                        keep[#keep + 1] = it
                    end
                end
                if #keep > Inv.CAP then SS.Log("inventory of %s holds %d items (player limit %d): kept", tostring(hid), #keep, Inv.CAP) end
                if hh.inventory ~= nil or #keep > 0 then hh.inventory = keep end
            end
        end
    end)
end
