-- SideStreet shopping at the courtyard shops: browse in-world displays, pick an item, queue at the
-- vendor's till, the shopkeeper rings it up, pay once, and receive a persistent result:
--   clothing -> a wearable outfit (person.wardrobe; look.outfits[slot] when that slot is empty);
--               change at the changing booth or a dresser at home ("wear_bought")
--   gifts    -> transferable inventory items (kind "gift"); given with a Give Gift interaction
--   books    -> inventory items (kind "book") read in any seat ("read_owned"): interests and skills
--   decor    -> real catalogue objects in household inventory, placed later with the catalogue
-- Buying is always the player's order: residents browse on their own, but never buy on their own.
-- Owner: outings module (docs/modules/outings.md).
local _, SS = ...
local VD = SS.VenueData
local T = VD.tuning
local U = SS.U
local V = SS.Venues
local Sh = SS.Shopping or {}
SS.Shopping = Sh

local function rootOf(x) return x and (x.root or x) end
local I = SS.Interactions
-- "the Cardigan" but "The Patient Chess Player" (titles that already carry an article)
local function the(name)
    name = name or "item"
    if name:match("^The ") or name:match("^A ") then return name end
    return "the " .. name
end
Sh.The = the

---------------------------------------------------------------------------------------------------
-- Stock
local decorCache
local function objectCount()
    local n = 0
    for _ in pairs(SS.Objects) do n = n + 1 end
    return n
end

-- Decor stock: real catalogue designs chosen by the rules (distinct, sorted), with base fallbacks.
function Sh.DecorStock()
    local n = objectCount()
    if decorCache and decorCache.n == n then return decorCache.list end
    local rules = VD.stock.decor
    local list, seen = {}, {}
    for _, rule in ipairs(rules.rules) do
        local ids = {}
        for id, def in pairs(SS.Objects) do
            if def.buyable ~= false and def.cat == rule.cat and (def.price or 0) > 0 and (def.price or 0) <= rule.maxPrice
                and rules.mounts[def.mount or ""] and not def.community and not def.stairs and not seen[id] then
                ids[#ids + 1] = id
            end
        end
        table.sort(ids, function(a, b)
            local pa, pb = SS.Objects[a].price, SS.Objects[b].price
            if pa ~= pb then return pa < pb end
            return a < b
        end)
        local take = rule.take or math.max(1, math.floor(rules.maxItems / #rules.rules))
        for k = 1, math.min(take, #ids) do
            if #list < rules.maxItems then seen[ids[k]] = true; list[#list + 1] = ids[k] end
        end
    end
    for _, id in ipairs(rules.fallback) do
        if #list < rules.maxItems and SS.Objects[id] and not seen[id] then seen[id] = true; list[#list + 1] = id end
    end
    local out = {}
    for _, id in ipairs(list) do
        local def = SS.Objects[id]
        out[#out + 1] = { id = "dc_" .. id, def = id, name = def.name, price = def.price, desc = def.desc, vendor = "decor", kind = "object" }
    end
    decorCache = { n = n, list = out }
    return out
end

function Sh.Catalog(vendor)
    if vendor == "decor" then return Sh.DecorStock() end
    local src = VD.stock[vendor]
    local out = {}
    for _, e in ipairs(src or {}) do
        local c = {}
        for k, v in pairs(e) do c[k] = v end
        c.vendor = vendor
        c.kind = vendor == "clothing" and "clothing" or vendor == "gifts" and "gift" or "book"
        out[#out + 1] = c
    end
    return out
end

local entryCache = {}
function Sh.Entry(stockId)
    if not stockId then return nil end
    local e = entryCache[stockId]
    if e then return e end
    for _, vendor in ipairs(VD.VENDOR_ORDER) do
        for _, c in ipairs(Sh.Catalog(vendor)) do
            if c.id == stockId then
                if vendor ~= "decor" then entryCache[stockId] = c end
                return c
            end
        end
    end
end

local function shopState(world)
    local o = rootOf(world).outing
    if not o then return nil end
    o.shop = o.shop or { orders = {}, nextId = 1, queues = {}, stock = {}, receipts = {} }
    local s = o.shop
    s.orders, s.queues, s.stock, s.receipts = s.orders or {}, s.queues or {}, s.stock or {}, s.receipts or {}
    s.nextId = s.nextId or 1
    return s
end
Sh.State = shopState

function Sh.Left(world, stockId)
    local s = shopState(world)
    if not s then return 0 end
    local v = s.stock[stockId]
    if v == nil then v = T.restock end
    return v
end

function Sh.IsShops(world) return V.Active(world) and world.lot.venue == "shops" end

-- Display rows for the UI: every stock entry with what is left and whether it can be bought.
function Sh.Stock(world, vendor)
    local out = {}
    for _, e in ipairs(Sh.Catalog(vendor)) do
        out[#out + 1] = { entry = e, left = Sh.Left(world, e.id), price = e.price, affordable = (world.money or 0) >= e.price }
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Orders (one open order per shopper; saved in root.outing.shop so a reload never duplicates)
local OPEN = { picking = true, picked = true, queued = true, paying = true }
Sh.OPEN = OPEN

function Sh.ActiveOrder(world, rid)
    local s = shopState(world)
    if not s then return nil end
    for _, id in ipairs(V.SortedKeys(s.orders)) do
        local o = s.orders[id]
        if o.rid == rid and OPEN[o.state] then return o end
    end
end

function Sh.Order(world, id)
    local s = shopState(world)
    return s and s.orders[id]
end

local function vendorName(vendor) return VD.vendors[vendor] and VD.vendors[vendor].name or "The shop" end

function Sh.OrderText(order)
    local e = Sh.Entry(order.stockId)
    local name = e and e.name or order.stockId
    local st = order.state
    if st == "picking" then return "Choosing " .. the(name)
    elseif st == "picked" then return "Holding " .. the(name) .. "; ready to pay"
    elseif st == "queued" then return "In line to pay for " .. the(name)
    elseif st == "paying" then return "Paying for " .. the(name)
    elseif st == "paid" then return "Bought " .. the(name)
    elseif st == "declined" then return "Couldn't buy " .. the(name) .. (order.why and (": " .. order.why) or "")
    else return "Cancelled: " .. name end
end

-- Inventory capacity and validity (the catalogue owns inventory; this checks before paying).
function Sh.InventoryProblem(world)
    local hh = world.household
    if not hh then return "No household to take it home." end
    if hh.inventory ~= nil and type(hh.inventory) ~= "table" then return "The household's storage record is damaged." end
    local n = 0
    if SS.Inventory and SS.Inventory.List then
        local ok, list = pcall(SS.Inventory.List, world)
        if not ok or type(list) ~= "table" then return "The household's storage can't be read." end
        n = #list
    end
    local cap = math.min(T.inventoryCap, (SS.Inventory and SS.Inventory.CAP) or T.inventoryCap)
    if n >= cap then return "Household storage is full (" .. cap .. " items). Place or give away something first." end
    return nil
end

local function owns(world, actor, entry)
    if entry.kind == "clothing" then
        for _, w in ipairs(actor.wardrobe or {}) do if w.stockId == entry.id then return true end end
    end
    return false
end

-- Why can't this shopper buy this item right now? nil when fine.
function Sh.CannotBuy(world, actor, entry)
    if not Sh.IsShops(world) then return "Only at the shops." end
    local o = rootOf(world).outing
    if o.closing then return vendorName(entry.vendor) .. " is closing." end
    if not V.IsMember(world, actor) then return "Only your household shops here." end
    if Sh.Left(world, entry.id) <= 0 then return "Sold out." end
    if owns(world, actor, entry) then return actor.name .. " already owns " .. the(entry.name) .. "." end
    if (world.money or 0) < entry.price then return "Costs " .. U.fmtMoney(entry.price) .. "; the household has " .. U.fmtMoney(world.money or 0) .. "." end
    if entry.kind == "clothing" then
        if #(actor.wardrobe or {}) >= T.wardrobeCap then return actor.name .. "'s wardrobe is full." end
    else
        local p = Sh.InventoryProblem(world)
        if p then return p end
    end
    local rt = V.RT(world)
    if #(rt.byVendor[entry.vendor] or {}) == 0 then return vendorName(entry.vendor) .. " has no display here." end
    if not rt.regByVendor[entry.vendor] then return vendorName(entry.vendor) .. " has no till." end
    return nil
end

local function nearestDisplay(world, actor, vendor)
    local rt = V.RT(world)
    local best, bd
    for _, oid in ipairs(rt.byVendor[vendor] or {}) do
        local o = world.lot.objects[oid]
        if o then
            local d = math.abs(o.x - actor.x) + math.abs(o.y - actor.y)
            if not bd or d < bd then best, bd = oid, d end
        end
    end
    return best
end

local function isShopAct(act)
    local b = act and V.BaseIid(act.iid)
    return b == "shop_pick" or b == "shop_queue" or b == "shop_pay"
end

-- Player: buy this item. Starts (or changes) the shopper's order and sends them to a display.
function Sh.Buy(world, actor, stockId)
    local entry = Sh.Entry(stockId)
    if not entry then return false, "That isn't sold here." end
    local why = Sh.CannotBuy(world, actor, entry)
    if why then return false, why end
    local s = shopState(world)
    local order = Sh.ActiveOrder(world, actor.id)
    local msg
    if order and order.stockId == stockId then
        return Sh.Continue(world, actor, order)
    elseif order then
        local old = Sh.Entry(order.stockId)
        msg = string.format("%s changed their mind: %s instead of %s.", actor.name, the(entry.name), old and the(old.name) or "the other thing")
        Sh.Unqueue(world, actor.id)
        order.stockId, order.vendor, order.state, order.changed = stockId, entry.vendor, "picking", (order.changed or 0) + 1
        if isShopAct(actor.act) then SS.Actions.Cancel(world, actor, 0) end
    else
        order = { id = "so" .. s.nextId, rid = actor.id, stockId = stockId, vendor = entry.vendor, state = "picking", createdAt = world.time }
        s.nextId = s.nextId + 1
        s.orders[order.id] = order
        -- bounded: keep the latest 40 orders
        local ids = V.SortedKeys(s.orders)
        if #ids > 40 then
            for n = 1, #ids - 40 do if not OPEN[s.orders[ids[n]].state] then s.orders[ids[n]] = nil end end
        end
    end
    local disp = nearestDisplay(world, actor, entry.vendor)
    order.display = disp
    order.register = V.RT(world).regByVendor[entry.vendor]
    local d = world.lot.objects[disp]
    SS.Actions.Order(world, actor, disp, V.IidFor(SS.Objects[d.def], "shop_pick"), nil, nil, { data = { order = order.id } })
    if msg then V.Notice(world, msg) end
    SS.Emit("shopOrder", world, actor, order)
    return true, msg
end

-- Carry an existing order on from where it stands (after a reload or a failed step).
function Sh.Continue(world, actor, order)
    order = order or Sh.ActiveOrder(world, actor.id)
    if not order then return false, "Nothing chosen yet." end
    if isShopAct(actor.act) then return true end
    local nxt
    if order.state == "picking" then
        local disp = order.display and world.lot.objects[order.display] or world.lot.objects[nearestDisplay(world, actor, order.vendor) or ""]
        if not disp then return false, "The display is gone." end
        order.display = disp.id
        nxt = { oid = disp.id, iid = V.IidFor(SS.Objects[disp.def], "shop_pick") }
    else
        order.state = "picked"
        local why
        nxt, why = Sh.NextStep(world, actor, order)
        if not nxt then return false, why or "The till is gone." end
    end
    SS.Actions.Order(world, actor, nxt.oid, nxt.iid, nil, nil, { data = { order = order.id } })
    return true
end

function Sh.CancelOrder(world, actor, why)
    local order = Sh.ActiveOrder(world, actor.id)
    if not order then return false, "Nothing to cancel." end
    order.state, order.why = "cancelled", why or "changed their mind"
    Sh.Unqueue(world, actor.id)
    if isShopAct(actor.act) then SS.Actions.Cancel(world, actor, 0) end
    SS.Emit("shopOrder", world, actor, order)
    return true
end

---------------------------------------------------------------------------------------------------
-- Queues at the tills
function Sh.Queue(world, regOid)
    local s = shopState(world)
    s.queues[regOid] = s.queues[regOid] or {}
    return s.queues[regOid]
end

function Sh.Unqueue(world, rid)
    local s = shopState(world)
    if not s then return end
    for _, q in pairs(s.queues) do
        for n = #q, 1, -1 do if q[n] == rid then table.remove(q, n) end end
    end
end

local function clerkFor(world, regOid)
    local k = V.StaffFor(world, "shopkeeper", regOid)
    return k, k and V.AtPost(world, k)
end
Sh.Clerk = clerkFor

-- Customer slot holder of a till (nil when free).
local function customerSlotName(def)
    if def.slots and def.slots.customer then return "customer" end
    for name, sl in pairs(def.slots or {}) do if not sl.staff and name ~= "staff" and not sl.group then return name end end
    return "customer"
end

local function holder(world, reg, except)
    local def = SS.Objects[reg.def]
    local slot = customerSlotName(def)
    local h = reg.res and reg.res[slot]
    if h then
        local a = world.actors[h]
        if not a or not a.act or V.BaseIid(a.act.iid) ~= "shop_pay" then
            -- stale hold (the shopper moved on)
            if not (a and a.act and V.BaseIid(a.act.iid) == "shop_queue") then reg.res[slot] = nil; h = nil end
        end
    end
    if not h then
        -- someone already sent to pay here who has not set off yet (their order is next in line)
        for _, rid in ipairs(SS.Sim.ActorIds(world)) do
            local a = world.actors[rid]
            local nq = a and rid ~= except and a.queue and a.queue[1]
            if nq and nq.oid == reg.id and V.BaseIid(nq.iid) == "shop_pay" then h = rid; break end
        end
    end
    return h, slot
end

function Sh.RegisterBusy(world, regOid)
    local reg = world.lot.objects[regOid]
    if not reg then return false end
    local q = Sh.Queue(world, regOid)
    return (holder(world, reg) ~= nil) or #q > 0
end

-- What comes after choosing: pay straight away at a free till, else join the line.
function Sh.NextStep(world, actor, order)
    local reg = order.register and world.lot.objects[order.register]
    if not reg then
        order.register = V.RT(world).regByVendor[order.vendor]
        reg = order.register and world.lot.objects[order.register]
    end
    if not reg then return nil, vendorName(order.vendor) .. " has no till." end
    local def = SS.Objects[reg.def]
    local q = Sh.Queue(world, reg.id)
    local h = holder(world, reg, actor.id)
    if not h and (#q == 0 or q[1] == actor.id) then
        return { oid = reg.id, iid = V.IidFor(def, "shop_pay"), data = { order = order.id } }
    end
    local inLine = false
    for _, rid in ipairs(q) do if rid == actor.id then inLine = true end end
    if not inLine and #q >= T.queueCap then
        return nil, "The line at " .. vendorName(order.vendor) .. " is full; " .. actor.name .. " is holding the item. Try paying again in a moment."
    end
    if V.HasSlot(def, "line") then
        return { oid = reg.id, iid = "shop_queue", data = { order = order.id } }
    end
    return { oid = reg.id, iid = V.IidFor(def, "shop_queue"), data = { order = order.id } }
end

local function orderOf(world, actor, act)
    local id = act and act.data and act.data.order
    local o = id and Sh.Order(world, id)
    if o and o.rid == actor.id then return o end
    return Sh.ActiveOrder(world, actor.id)
end

---------------------------------------------------------------------------------------------------
-- Delivery: the persistent result, then payment, in one step (never one without the other).
local function newUid(world, prefix)
    local root = rootOf(world)
    root.outingsItems = (root.outingsItems or 0) + 1
    return prefix .. root.outingsItems
end

function Sh.Deliver(world, actor, entry, order)
    if entry.kind == "clothing" then
        actor.wardrobe = actor.wardrobe or {}
        if #actor.wardrobe >= T.wardrobeCap then return false, actor.name .. "'s wardrobe is full." end
        local w = { id = newUid(world, "wd"), stockId = entry.id, name = entry.name, slot = entry.slot, style = entry.style,
            top = { unpack(entry.top) }, bottom = { unpack(entry.bottom) }, shoes = { unpack(entry.shoes) },
            boughtAt = world.time, from = world.lot.name }
        actor.wardrobe[#actor.wardrobe + 1] = w
        actor.look = actor.look or {}
        actor.look.outfits = actor.look.outfits or {}
        local unlocked = false
        if not actor.look.outfits[entry.slot] then
            actor.look.outfits[entry.slot] = { style = w.style, top = { unpack(w.top) }, bottom = { unpack(w.bottom) }, shoes = { unpack(w.shoes) } }
            w.worn = true
            unlocked = true
        end
        return true, nil, { kind = "wardrobe", id = w.id, unlocked = unlocked }
    end
    local p = Sh.InventoryProblem(world)
    if p then return false, p end
    local item = { uid = newUid(world, "it"), name = entry.name, value = entry.price,
        data = { stockId = entry.id, boughtAt = world.time, boughtBy = actor.id, from = world.lot.name } }
    if entry.kind == "gift" then
        item.kind = "gift"
        item.data.giftType, item.data.romantic = entry.giftType, entry.romantic
        item.data.appeal = {}
        for n, t in ipairs(entry.appeal or {}) do item.data.appeal[n] = t end
        -- the social module's gift interactions read these: giftable, flowers, topic
        item.data.giftable, item.data.topic = true, entry.appeal and entry.appeal[1] or nil
        if entry.giftType == "flowers" then item.data.flowers = true end
    elseif entry.kind == "book" then
        item.kind = "book"
        item.data.topic, item.data.skill, item.data.magazine, item.data.reads = entry.topic, entry.skill, entry.magazine, 0
    else
        item.kind, item.def = "object", entry.def
        -- like a buy-mode purchase: resale follows the catalogue's depreciation rules
        item.data.bought, item.data.paid = world.time, entry.price
        if not SS.Objects[entry.def] then return false, "That design is no longer made." end
    end
    local ok, added, why = pcall(SS.Inventory.Add, world, item)
    if not ok or not added then return false, (ok and why) or "The household's storage wouldn't take it." end
    return true, nil, { kind = "inventory", id = item.uid }
end

function Sh.Commit(world, actor, order)
    if order.state == "paid" then return true end
    local entry = Sh.Entry(order.stockId)
    if not entry then order.state, order.why = "cancelled", "no longer sold"; return false, "That item is no longer sold here." end
    if Sh.Left(world, order.stockId) <= 0 then order.state, order.why = "cancelled", "sold out"; return false, "Sold out: " .. the(entry.name) .. "." end
    local price = entry.price
    if (world.money or 0) < price then
        order.state, order.why = "declined", "not enough money"
        V.Say(world, actor, "shop_broke", { item = entry.name, amount = price - (world.money or 0) })
        return false, "Not enough money for " .. the(entry.name) .. " (" .. U.fmtMoney(price) .. ")."
    end
    local ok, why, result = Sh.Deliver(world, actor, entry, order)
    if not ok then order.state, order.why = "declined", why; return false, why end
    SS.Money(world, -price, "shopping", vendorName(entry.vendor) .. ": " .. entry.name)
    local s = shopState(world)
    s.stock[order.stockId] = Sh.Left(world, order.stockId) - 1
    order.state, order.price, order.paidAt, order.result = "paid", price, world.time, result
    s.receipts[#s.receipts + 1] = { order = order.id, rid = actor.id, name = entry.name, price = price, t = world.time }
    while #s.receipts > 20 do table.remove(s.receipts, 1) end
    V.ScoreEvent(world, "shopping", 2, { actor.id })
    V.Log(world, string.format("%s bought %s for %s.", actor.name, the(entry.name), U.fmtMoney(price)))
    V.Say(world, actor, "shop_checkout", { item = entry.name, amount = price })
    local extra = ""
    if result and result.kind == "wardrobe" then
        extra = result.unlocked and " New outfit unlocked." or " Added to the wardrobe."
    elseif entry.kind == "object" then extra = " It's in household storage, ready to place at home."
    elseif entry.kind == "book" then extra = " Read it in any seat."
    elseif entry.kind == "gift" then extra = " Give it to someone special." end
    V.Notice(world, string.format("Bought %s for %s.%s", the(entry.name), U.fmtMoney(price), extra))
    SS.Emit("purchase", world, actor, entry, result)
    return true
end

---------------------------------------------------------------------------------------------------
-- Interactions
local function shopTest(world, actor)
    if not Sh.IsShops(world) then return false, "Only at the shops." end
    if rootOf(world).outing.closing then return false, "The shops are closing." end
    return true
end

I.shop_browse = {
    label = "Browse", category = "Fun", slot = "browse", pose = "use", maxDur = 20, venueActivity = true, leisure = true, outings = true,
    -- advertised above a bench or an armchair, so shoppers left to themselves do browse
    rate = { fun = 18 }, advert = { fun = 24 },
    test = function(world, actor) return shopTest(world, actor) end,
    onTick = function(world, actor, act, obj, dt)
        V.GroupTick(world, actor, act, dt, "shop_browse", nil, 3, 10, 4)
        if not act.data.said and act.t > 5 and V.IsMember(world, actor) and SS.Random(world, "outings.lines") < 0.05 then
            act.data.said = true
            -- the line may name something on this display (the social module's {item} slot)
            local def = obj and SS.Objects[obj.def]
            local item
            for _, tag in ipairs(def and def.tags or {}) do
                local vendor = VD.displayVendor[tag]
                if vendor and not item then
                    local list = Sh.Catalog(vendor)
                    if #list > 0 then item = list[SS.RandomInt(world, "outings.lines", 1, #list)].name end
                end
            end
            V.Say(world, actor, "shop_browse", { item = item })
        end
    end,
}

I.shop_pick = {
    label = "Pick Out an Item", category = "Shopping", shopping = true, slot = "browse", pose = "use", dur = T.pickTime, manualOnly = true, outings = true,
    advert = {},
    test = function(world, actor)
        local ok, why = shopTest(world, actor)
        if not ok then return ok, why end
        local o = Sh.ActiveOrder(world, actor.id)
        if not o then return false, "Choose something to buy first." end
        if Sh.Left(world, o.stockId) <= 0 then return false, "Sold out." end
        return true
    end,
    onStart = function(world, actor, act)
        local o = orderOf(world, actor, act)
        if not o then return false, "Nothing chosen." end
        act.data.order = o.id
        actor.carry = nil
    end,
    onEnd = function(world, actor, act, obj, status)
        local o = orderOf(world, actor, act)
        if o and status == "done" and o.state == "picking" then
            o.state = "picked"
            actor.carry = "shopping_bag"
        end
    end,
    next = function(world, actor, act)
        local o = orderOf(world, actor, act)
        if o and o.state == "picked" then
            local nxt, why = Sh.NextStep(world, actor, o)
            if not nxt and why then V.Notice(world, why) end
            return nxt
        end
    end,
}

I.shop_queue = {
    label = "Wait in Line", category = "Shopping", shopping = true, slot = "line", pose = "idle", maxDur = T.lineWait, manualOnly = true, outings = true,
    advert = {},
    test = function(world, actor)
        local o = Sh.ActiveOrder(world, actor.id)
        if not o or (o.state ~= "picked" and o.state ~= "queued") then return false, "Pick something out first." end
        return true
    end,
    onStart = function(world, actor, act, obj)
        local o = orderOf(world, actor, act)
        if not o then return false, "Nothing to pay for." end
        local q = Sh.Queue(world, o.register)
        local have = false
        for _, rid in ipairs(q) do if rid == actor.id then have = true end end
        if not have then q[#q + 1] = actor.id end
        o.state = "queued"
        act.data.order = o.id
    end,
    onTick = function(world, actor, act, obj, dt)
        local o = orderOf(world, actor, act)
        if not o or o.state ~= "queued" then act.complete = true; return end
        local reg = world.lot.objects[o.register]
        if not reg then act.data.fail = "The till is gone."; act.complete = true; return end
        local q = Sh.Queue(world, reg.id)
        if q[1] == actor.id and not holder(world, reg, actor.id) then
            local def = SS.Objects[reg.def]
            local slot = customerSlotName(def)
            reg.res = reg.res or {}
            reg.res[slot] = actor.id      -- hold the till for the head of the line
            act.data.ready = true
            act.complete = true
        end
        if act.t + dt >= T.lineWait and not act.data.ready then
            act.data.fail = actor.name .. " gave up waiting in line."
        end
    end,
    onEnd = function(world, actor, act, obj, status)
        local o = orderOf(world, actor, act)
        if not act.data.ready then
            Sh.Unqueue(world, actor.id)
            if o and o.state == "queued" then o.state = "picked" end
            if act.data.fail or status == "done" then
                V.Say(world, actor, "venue_wait", {})
                V.Notice(world, act.data.fail or (actor.name .. " gave up waiting in line."))
                V.ScoreEvent(world, "waiting", -3, { actor.id })
            end
        end
    end,
    next = function(world, actor, act)
        local o = orderOf(world, actor, act)
        if act.data.ready and o then
            local reg = world.lot.objects[o.register]
            return { oid = o.register, iid = V.IidFor(SS.Objects[reg.def], "shop_pay"), data = { order = o.id } }
        end
    end,
}

I.shop_pay = {
    label = "Pay at the Till", category = "Shopping", shopping = true, slot = "customer", pose = "idle", maxDur = T.clerkWait + T.serveTime + 10,
    manualOnly = true, outings = true, advert = {},
    test = function(world, actor)
        local o = Sh.ActiveOrder(world, actor.id)
        if not o or not OPEN[o.state] or o.state == "picking" then return false, "Pick something out first." end
        return true
    end,
    onStart = function(world, actor, act)
        local o = orderOf(world, actor, act)
        if not o then return false, "Nothing to pay for." end
        act.data.order = o.id
        o.state = "paying"
        Sh.Unqueue(world, actor.id)
        act.data.serve, act.data.wait = act.data.serve or 0, act.data.wait or 0
    end,
    onTick = function(world, actor, act, obj, dt)
        local o = orderOf(world, actor, act)
        if not o or o.state ~= "paying" then act.complete = true; return end
        local clerk, atPost = clerkFor(world, o.register)
        if clerk and atPost then
            act.data.serve = act.data.serve + dt
            clerk.pose = "use"
            clerk.facing = SS.Grid.dirToFacing(actor.x - clerk.x, actor.y - clerk.y)
            actor.pose = "talk"
            if act.data.serve >= T.serveTime then
                local ok, why = Sh.Commit(world, actor, o)
                if not ok then act.data.fail = why end
                clerk.pose = "idle"
                act.complete = true
            end
        else
            actor.pose = "idle"
            act.data.wait = act.data.wait + dt
            if act.data.wait >= T.clerkWait then
                act.data.fail = "Nobody came to serve at the till."
                act.complete = true
            end
        end
    end,
    onEnd = function(world, actor, act, obj, status)
        local o = orderOf(world, actor, act)
        if o and o.state == "paying" then o.state = "picked" end
        -- beaten to the till on the way (someone else got there first): join the line instead,
        -- automatically, a bounded number of times
        if o and o.state == "picked" and status == "failed" and not act.performed and not act.data.fail
            and (o.payTries or 0) < T.payRetries then
            o.payTries = (o.payTries or 0) + 1
            o.resume = true
            return
        end
        if o and o.state ~= "paid" then
            local why = act.data.fail or (status ~= "done" and "Checkout interrupted; the item is still held.") or nil
            if why then V.Notice(world, why) end
        end
        if o and o.state == "paid" then actor.carry = "shopping_bag" end
    end,
}

---------------------------------------------------------------------------------------------------
-- The shopkeeper: stays at the till while anyone is in line; otherwise tidies the displays.
V.roleBrains.shopkeeper = function(world, a, dt)
    local rd = a.roleData
    local reg = rd.anchor
    local busy = Sh.RegisterBusy(world, reg)
    if rd.tidy then
        if busy then
            rd.tidy, rd.tidyT = nil, nil
            V.ResetWalk(a)
            if a.act and a.act.iid == "goto" then SS.Actions.Cancel(world, a, 0) end
            return false
        end
        local st = V.Walk(world, a, rd.tidy[1], rd.tidy[2], 0, "tidy")
        if st == "arrived" then
            rd.tidyT = (rd.tidyT or 0) + dt
            a.pose = "use"
            if rd.tidyT >= 3 then rd.tidy, rd.tidyT = nil, nil; a.pose = "idle" end
            return true
        elseif st == "blocked" then
            rd.tidy, rd.tidyT = nil, nil
            return false
        end
        return true
    end
    if not busy and V.AtPost(world, a) and world.time >= (rd.nextTidy or (world.time + 20)) then
        rd.nextTidy = world.time + 30 + SS.RandomInt(world, "outings.staff", 0, 30)
        local rt = V.RT(world)
        local vendor = rt.vendorByReg and rt.vendorByReg[reg]
        local list = vendor and rt.byVendor[vendor] or {}
        if #list > 0 then
            local d = world.lot.objects[list[SS.RandomInt(world, "outings.staff", 1, #list)]]
            local def = d and SS.Objects[d.def]
            for _, name in ipairs(V.SortedKeys(def and def.slots or {})) do
                for _, c in ipairs(V.SlotCells(d, def.slots[name])) do
                    if not rd.tidy and not SS.World.Blocked(world, 0, c[1], c[2]) then rd.tidy = { c[1], c[2] } end
                end
            end
        end
        if not rd.nextTidy then rd.nextTidy = world.time + 30 end
    elseif not rd.nextTidy then
        rd.nextTidy = world.time + 20
    end
    return false
end

---------------------------------------------------------------------------------------------------
-- Visit lifecycle
function Sh.Settle(world, reason)
    local s = shopState(world)
    if not s then return end
    for _, id in ipairs(V.SortedKeys(s.orders)) do
        local o = s.orders[id]
        if OPEN[o.state] then o.state, o.why = "cancelled", reason or "left the shops" end
    end
    s.queues = {}
end

function Sh.OnClose(world)
    local s = shopState(world)
    if not s then return end
    local any = false
    for _, id in ipairs(V.SortedKeys(s.orders)) do
        local o = s.orders[id]
        if OPEN[o.state] and o.state ~= "paying" then
            o.state, o.why = "cancelled", "the shops closed"
            local a = world.actors[o.rid]
            if a and isShopAct(a.act) then SS.Actions.Cancel(world, a, 0) end
            any = true
        end
    end
    s.queues = {}
    if any then V.Notice(world, "The shops closed before checkout; nothing was charged.") end
end

-- After a load: open orders go back to "picked"/"picking" (no money moved yet) and shoppers
-- who are idle carry on with their purchase once, automatically.
function Sh.OnAttach(world)
    if not Sh.IsShops(world) then return end
    local s = shopState(world)
    s.queues = {}
    for _, id in ipairs(V.SortedKeys(s.orders)) do
        local o = s.orders[id]
        if o.state == "queued" or o.state == "paying" then o.state = "picked"; o.resume = true
        elseif o.state == "picking" or o.state == "picked" then o.resume = true end
    end
    for _, reg in pairs(world.lot.objects) do if reg.res then reg.res = nil end end
end

function Sh.Tick(world, dt)
    if not Sh.IsShops(world) then return end
    local s = shopState(world)
    s.acc = (s.acc or 0) + dt
    if s.acc < 1 then return end
    s.acc = 0
    for _, id in ipairs(V.SortedKeys(s.orders)) do
        local o = s.orders[id]
        if o.resume and OPEN[o.state] then
            local a = world.actors[o.rid]
            local manualQueued = false
            for _, q in ipairs(a and a.queue or {}) do if q.manual ~= false then manualQueued = true end end
            if not a then o.state, o.why, o.resume = "cancelled", "shopper left", nil
            elseif (not a.act or not a.act.manual) and not manualQueued then
                o.resume = nil
                local ok, why = Sh.Continue(world, a, o)
                if not ok and why then V.Notice(world, why) end
            end
        end
        -- a shopper who left the lot mid-purchase: the order lapses (nothing charged)
        if OPEN[o.state] and not world.actors[o.rid] then o.state, o.why = "cancelled", "shopper left" end
    end
    -- drop queue entries for shoppers no longer waiting
    for regOid, q in pairs(s.queues) do
        for n = #q, 1, -1 do
            local a = world.actors[q[n]]
            if not a or not a.act or V.BaseIid(a.act.iid) ~= "shop_queue" then
                local o = a and Sh.ActiveOrder(world, a.id)
                if not (a and a.queue and a.queue[1] and V.BaseIid(a.queue[1].iid) == "shop_queue") then
                    table.remove(q, n)
                    if o and o.state == "queued" then o.state = "picked" end
                end
            end
        end
    end
end

SS.Sim.Register({ name = "outings_shopping", order = 61, tick = Sh.Tick, attach = Sh.OnAttach })

---------------------------------------------------------------------------------------------------
-- Using what was bought: reading, wearing, giving.
local function hhItems(world, kind)
    if not (SS.Inventory and SS.Inventory.List) then return {} end
    local ok, list = pcall(SS.Inventory.List, world, kind)
    return ok and list or {}
end

function Sh.Books(world) return hhItems(world, "book") end
function Sh.Gifts(world) return hhItems(world, "gift") end
function Sh.DecorItems(world) return hhItems(world, "object") end

function Sh.FindItem(world, uid, kind)
    for _, it in ipairs(hhItems(world, kind)) do if it.uid == uid then return it end end
end

local function pickBook(world, uid)
    if uid then return Sh.FindItem(world, uid, "book") end
    local best
    for _, it in ipairs(Sh.Books(world)) do
        if not best or (it.data and it.data.reads or 0) < (best.data and best.data.reads or 0) then best = it end
    end
    return best
end

I.read_owned = {
    label = "Read a Book", category = "Fun", slot = "seat", pose = "read", maxDur = 60, leisure = true, outings = true, carry = "book",
    rate = { fun = 16 },
    advertise = function(world, actor)
        if #Sh.Books(world) == 0 then return nil end
        return { fun = 18 }
    end,
    advert = { fun = 18 },
    test = function(world, actor, obj)
        if not V.IsMember(world, actor) then return false, "Only the household's own books." end
        if #Sh.Books(world) == 0 then return false, "No books or magazines at hand; the shops sell some." end
        return true
    end,
    onStart = function(world, actor, act)
        local it = pickBook(world, act.data and act.data.uid)
        if not it then return false, "That book isn't here any more." end
        act.data.uid = it.uid
        actor.carry = it.data and it.data.magazine and "newspaper" or "book"
        if it.data and it.data.skill then act.skill = { [it.data.skill] = 0.5 } end
    end,
    onTick = function(world, actor, act, obj, dt)
        local it = Sh.FindItem(world, act.data.uid, "book")
        if not it then act.complete = true; return end
        local d = it.data or {}
        if d.topic then
            actor.interests = actor.interests or {}
            actor.interests[d.topic] = math.min(10, (actor.interests[d.topic] or 0) + 0.04 * dt)
        end
        if d.magazine and not actor.noNeeds then SS.Needs.Add(actor, "fun", 6 * dt / 60) end
        if d.skill and not SS.Actions.EffectMult and SS.Skills and SS.Skills.Gain then SS.Skills.Gain(world, actor, d.skill, 0.5 * dt / 60) end
        if d.magazine and act.t >= 30 then act.complete = true end
    end,
    onEnd = function(world, actor, act)
        local it = act.data and Sh.FindItem(world, act.data.uid, "book")
        if it and act.t >= 10 then it.data = it.data or {}; it.data.reads = (it.data.reads or 0) + 1 end
        if actor.carry == "book" or actor.carry == "newspaper" then actor.carry = nil end
    end,
}

-- Outfits bought here: wear one (booth at the shops, or a dresser at home).
function Sh.Wardrobe(actor) return actor and actor.wardrobe or {} end

function Sh.Wear(world, actor, wid)
    local pick
    for _, w in ipairs(actor.wardrobe or {}) do
        if (wid and w.id == wid) or (not wid and not w.worn and not pick) then pick = w end
    end
    if not pick and not wid then pick = (actor.wardrobe or {})[#(actor.wardrobe or {})] end
    if not pick then return false, "No outfit to change into." end
    actor.look = actor.look or {}
    actor.look.outfits = actor.look.outfits or {}
    actor.look.outfits[pick.slot] = { style = pick.style, top = { unpack(pick.top) }, bottom = { unpack(pick.bottom) }, shoes = { unpack(pick.shoes) } }
    actor.outfit = pick.slot
    if pick.slot == "everyday" then
        actor.look.top, actor.look.bottom, actor.look.shoes = { unpack(pick.top) }, { unpack(pick.bottom) }, { unpack(pick.shoes) }
    end
    for _, w in ipairs(actor.wardrobe) do if w.slot == pick.slot then w.worn = (w == pick) end end
    SS.Emit("outfitChanged", world, actor, actor.outfit, pick) -- same shape as the dresser's event, plus the bought outfit
    return true, pick
end

I.wear_bought = {
    label = "Change Into a New Outfit", category = "Basics", slot = "booth", pose = "use", dur = 2, manualOnly = true, outings = true,
    advert = {}, privacy = true,
    test = function(world, actor)
        if #(actor.wardrobe or {}) == 0 then return false, "No bought outfits yet; Hem & Haw Outfitters sells them." end
        return true
    end,
    onEnd = function(world, actor, act, obj, status)
        if status ~= "done" then return end
        local ok, pick = Sh.Wear(world, actor, act.data and act.data.wid)
        if ok then V.Notice(world, actor.name .. " changed into " .. the(pick.name) .. ".") end
    end,
}

-- Gifts. The social module's own gift interaction (SS.Interactions.give_gift) consumes these items
-- when present; this is the outings fallback so bought gifts always have a use.
local function relOf(world, a, b)
    if not (SS.Social and SS.Social.Rel) then return 0 end
    local r = SS.Social.Rel(world, a, b)
    return (r.daily or 0) * 0.5 + (r.life or 0) * 0.5
end

function Sh.GiftChance(world, giver, target, item)
    local d = item.data or {}
    local rel = relOf(world, target.id, giver.id)
    local p = 0.55 + rel / 200
    for _, topic in ipairs(d.appeal or {}) do
        if target.interests and (target.interests[topic] or 0) >= 5 then p = p + 0.2 end
    end
    if d.romantic then p = p + ((rel >= 40) and 0.15 or -0.45) end
    return U.clamp(p, 0.05, 0.97)
end

-- Resolve a gift once. Returns accepted (bool), text.
function Sh.GiveGift(world, giver, target, uid)
    local item = Sh.FindItem(world, uid, "gift")
    if not item then
        local k = Sh.FindItem(world, uid, "keepsake")
        local owner = k and k.data and rootOf(world).residents[k.data.owner or ""]
        if k then return false, "That was a present to " .. (owner and owner.name or "someone") .. "; it's theirs to keep." end
        return false, "That gift isn't in the household's things."
    end
    local p = Sh.GiftChance(world, giver, target, item)
    local accepted = SS.Random(world, "outings.gift") < p
    if accepted then
        local root = rootOf(world)
        local hh = target.householdId and root.households[target.householdId]
        item.data = item.data or {}
        local prev = { item.data.from, item.data.givenAt, item.data.owner }
        item.data.from, item.data.givenAt = giver.id, world.time
        item.data.owner = target.id
        if hh and hh == world.household then
            -- a housemate keeps it: it stays in the shared things as the recipient's keepsake, no
            -- longer a gift anyone can give again (nor listed by the social module's gift picker),
            -- and it resells for half what it cost
            item.kind, item.data.given, item.data.giftable = "keepsake", true, false
            item.value = math.floor((item.value or 0) / 2)
            SS.Emit("inventory", world, "update", item)
        else
            -- someone from elsewhere takes it home: it leaves this household's things only when it
            -- has somewhere to go, and comes straight back if it can't be kept
            local pos = SS.Inventory.IndexOf and SS.Inventory.IndexOf(world, item)
            SS.Inventory.Remove(world, item)
            local placed = false
            if hh and SS.Inventory.AddToHousehold then
                local ok, added = pcall(SS.Inventory.AddToHousehold, world, hh.id, item)
                placed = ok and added ~= nil and added ~= false
            elseif hh and hh.lotId and root.hood.lots[hh.lotId] and SS.Sim.NewSession then
                local ok, sess = pcall(SS.Sim.NewSession, root, hh.lotId, hh.id)
                if ok and sess then
                    local ok2, added = pcall(SS.Inventory.Add, sess, item)
                    placed = ok2 and added ~= nil and added ~= false
                end
            elseif hh then
                hh.inventory = type(hh.inventory) == "table" and hh.inventory or {}
                if #hh.inventory < T.inventoryCap then hh.inventory[#hh.inventory + 1] = item; placed = true end
            else
                target.keepsakes = target.keepsakes or {}
                target.keepsakes[#target.keepsakes + 1] = { name = item.name, from = giver.id, t = world.time, giftType = item.data.giftType }
                while #target.keepsakes > 12 do table.remove(target.keepsakes, 1) end
                placed = true
            end
            if not placed then
                item.data.from, item.data.givenAt, item.data.owner = prev[1], prev[2], prev[3]
                if SS.Inventory.Insert and pos then SS.Inventory.Insert(world, item, pos) else SS.Inventory.Add(world, item) end
                return false, target.name .. " has nowhere to keep " .. the(item.name) .. "; it's still in the household's things."
            end
        end
        if SS.Social and SS.Social.Change then
            SS.Social.Change(world, target.id, giver.id, 10, 3)
            SS.Social.Change(world, giver.id, target.id, 4, 1)
        end
        target.memories = target.memories or {}
        target.memories[#target.memories + 1] = { t = world.time, text = giver.name .. " gave me " .. item.name .. ".", kind = "gift" }
        while #target.memories > 30 do table.remove(target.memories, 1) end
        V.Say(world, target, "gift_good", { name = giver.name, item = item.name })
        if V.Active(world) then V.ScoreEvent(world, "gift", 6, { giver.id, target.id }) end
        SS.Emit("giftGiven", world, giver, target, item, true)
        return true, target.name .. " loved " .. the(item.name) .. "."
    end
    if SS.Social and SS.Social.Change then SS.Social.Change(world, target.id, giver.id, -4, 0) end
    V.Say(world, target, "gift_bad", { name = giver.name, item = item.name })
    if V.Active(world) then V.ScoreEvent(world, "gift", -4, { giver.id, target.id }) end
    SS.Emit("giftGiven", world, giver, target, item, false)
    return false, target.name .. " turned down " .. the(item.name) .. ". It's still in the household's things."
end

I.outing_give_gift = {
    label = "Give a Gift", category = "Social", targetActor = true, pose = "talk", dur = 3, manualOnly = true, outings = true,
    advert = {}, carry = "gift",
    test = function(world, actor, target)
        if not target or target == actor then return false, "Give it to someone else." end
        if (target.kind or "human") ~= "human" or target.age == "infant" then return false, "They can't take a gift." end
        if not V.IsMember(world, actor) then return false, "Only the household's own gifts." end
        if #Sh.Gifts(world) == 0 then return false, "No gifts at hand; Petal Pusher Gifts & Flowers sells them." end
        return true
    end,
    onStart = function(world, actor, act)
        local uid = act.data and act.data.uid
        if not uid then local g = Sh.Gifts(world)[1]; uid = g and g.uid end
        if not uid or not Sh.FindItem(world, uid, "gift") then return false, "That gift isn't here any more." end
        act.data.uid = uid
        actor.carry = "gift"
    end,
    onEnd = function(world, actor, act, obj, status)
        if actor.carry == "gift" then actor.carry = nil end
        if status ~= "done" or act.data.resolved then return end
        act.data.resolved = true
        local target = world.actors[act.tid]
        if not target then return end
        local _, text = Sh.GiveGift(world, actor, target, act.data.uid)
        V.Notice(world, text)
    end,
}

SS.Tags.Attach("display_clothing", "shop_browse")
SS.Tags.Attach("display_gift", "shop_browse")
SS.Tags.Attach("display_books", "shop_browse")
SS.Tags.Attach("display_decor", "shop_browse")
SS.Tags.Attach("changing_booth", "wear_bought")
SS.Tags.Attach("dresser", "wear_bought")
SS.Tags.Attach("seat", "read_owned")
