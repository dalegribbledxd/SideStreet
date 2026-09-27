-- Buy mode (F2): the shopping catalogue, the placement ghost, picking up / moving / rotating /
-- selling / storing placed objects, and placing things from the household inventory.
-- Owner: catalogue module. Notes: docs/modules/catalogue.md ("Buy mode").
-- Built lazily the first time the mode is entered; nothing touches WoW frames at load time.
--
-- Panel (the bottom panel, UI.PANEL_H = 150 px):
--   left    category buttons in two columns: the twelve home categories, Venue (community lots and
--           sandbox only) and Stored (the household inventory)
--   middle  subcategory, room and style cycles; search box; sort; "affordable only"; the list
--           (K.PagedList: B.ROWS pooled rows, whatever the catalogue size; SS.Catalogue.list)
--   right   details (thumbnail, name, price and tier, footprint and places, real ratings, colour
--           variant, description, placement requirements), a status line and the tool buttons
-- On the lot (mode.click / mode.mouseMove):
--   holding a design or a stored object: a ghost follows the cursor (SS.Render.SetGhost) coloured by
--     validity, with the cells at fault and the approach cells (SS.Render.SetCellMarks); left click
--     places it (Shift, or Repeat on: keep placing more); R / Shift+R or the arrow buttons rotate;
--     right click or Esc stops holding it. Nothing is charged until something is actually placed.
--   empty hand: click an object to pick it up (it moves with everything resting on it; click to put
--     it down, Esc/right click to leave it where it was); Shift+click sells it; Ctrl+click copies it.
--   holding a placed object: Sell (its value is on the button; asks first when things rest on it),
--     Store (to the household inventory), Copy, Delete key = Sell.
-- Undo / Redo (Ctrl+Z / Ctrl+Y) walk SS.Undo; the history ends when you go back to live mode.
-- The last category, subcategory, room, style, sort and toggles are kept in SideStreetDB.ui.buy.
local _, SS = ...
local UI = SS.UI
local K = UI.Kit
local C, P, Inv = SS.Catalog, SS.Placement, SS.Inventory
local B = SS.Catalogue or {}
SS.Catalogue = B

B.ROWS, B.ROW_H = 5, 17
B.STORED = "stored"
B.SORTS = { "price", "-price", "name" }
B.SORT_LABEL = { price = "Price: low", ["-price"] = "Price: high", name = "Name A-Z" }
B.SORT_TIP = { price = "Cheapest first", ["-price"] = "Most expensive first", name = "Alphabetical" }
B.KIND_LABEL = { object = "Furniture", gift = "Gifts", book = "Books", clothing = "Clothing", food = "Food", produce = "Produce",
    craft = "Crafts", misc = "Other" }
B.state = B.state or { tool = nil, search = "", variant = {} }
local st = B.state

local function money(v) return SS.U.fmtMoney(v or 0) end
local function getWorld() return SS.Sim.world end
-- Colours: names on the ui-shell kit (theme and high contrast follow), tables on the baseline kit.
local function col(name) if K.C then return name end return K.COL[name] or K.COL.ink end
local function tint(fs, name)
    if K.SetTextColor then K.SetTextColor(fs, name)
    else local c = K.COL[name] or K.COL.ink; fs:SetTextColor(c[1], c[2], c[3]) end
end
local function cue(name) if SS.Audio and SS.Audio.Cue then SS.Audio.Cue(name) end end
local function notice(text, kind) if text and UI.Notice then UI.Notice(text, kind) end end
local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

-- Saved browsing state: SideStreetDB.ui.buy = { cat, sub, room, style, sort, affordable, rep }.
function B.DB()
    local ui = SS.Save.DB().ui
    if type(ui.buy) ~= "table" then ui.buy = {} end
    return ui.buy
end

-- Venue (community) designs are offered only while furnishing a community lot, or in sandbox.
function B.VenueAllowed(w)
    return w and w.lot and (w.lot.kind == "community" or P.Sandbox(w)) and true or false
end

-- The Stored tab and the Store button exist only where furniture may go to (and come from) the
-- household inventory: the household's own home (P.InventoryHere), never a venue edited for free.
function B.StoredAllowed(w)
    return w and P.InventoryHere(w) and true or false
end

-- What the household would receive for a sale worth `v` right now (nothing while editing for free).
local function payout(w, v) return w and P.Payout(w, v) or 0 end

-- Restore the remembered browsing state (anything no longer valid falls back to a default).
function B.LoadPrefs(w)
    local d = B.DB()
    local cat = d.cat
    if cat ~= B.STORED and not C.CAT[cat or ""] then cat = "seating" end
    if cat == B.STORED and not B.StoredAllowed(w) then cat = (w and w.editVenue and B.VenueAllowed(w)) and "community" or "seating" end
    if cat == "community" and not B.VenueAllowed(w) then cat = "seating" end
    if cat ~= B.STORED and w and w.editVenue and B.VenueCount(w, cat) == 0 then cat = "community" end
    st.cat = cat
    st.sub = nil
    if cat ~= B.STORED and d.sub and C.CAT[cat].subLabel[d.sub] then st.sub = d.sub end
    st.room = C.ROOM_LABEL[d.room or ""] and d.room or nil
    local okStyle = false
    for _, s in ipairs(C.STYLES) do if s == d.style then okStyle = true end end
    st.style = okStyle and d.style or nil
    st.sort = B.SORT_LABEL[d.sort or ""] and d.sort or "price"
    st.affordable = d.affordable and true or false
    st.rep = d.rep and true or false
end

function B.SavePrefs()
    local d = B.DB()
    d.cat, d.sub, d.room, d.style, d.sort = st.cat, st.cat ~= B.STORED and st.sub or nil, st.room, st.style, st.sort
    d.affordable, d.rep = st.affordable or nil, st.rep or nil
end

---------------------------------------------------------------------------------------------------
-- The list (pure: usable without frames)
---------------------------------------------------------------------------------------------------
local function itemMatches(it, text)
    if not text or text == "" then return true end
    local def = it.def and SS.Objects[it.def]
    local hay = ((it.name or "") .. " " .. (it.kind or "") .. " " .. (def and def.name or "")):lower()
    return hay:find(text:lower(), 1, true) ~= nil
end

-- Entries for the current state: design ids (catalogue) or inventory items (Stored).
-- A search looks through every category (the room and style filters still apply).
function B.Items(w)
    w = w or getWorld()
    if not w then return {} end
    if st.cat == B.STORED then
        local out = {}
        if not B.StoredAllowed(w) then return out end
        for _, it in ipairs(Inv.List(w)) do
            if (not st.sub or it.kind == st.sub) and itemMatches(it, st.search) then out[#out + 1] = it end
        end
        local sort = st.sort
        table.sort(out, function(a, b)
            if sort == "name" then if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
            elseif sort == "-price" then if (a.value or 0) ~= (b.value or 0) then return (a.value or 0) > (b.value or 0) end
            elseif (a.value or 0) ~= (b.value or 0) then return (a.value or 0) < (b.value or 0) end
            return tostring(a.id) < tostring(b.id)
        end)
        return out
    end
    local text = st.search ~= "" and st.search or nil
    local list = C.List({ cat = (not text) and st.cat or nil, sub = (not text) and st.sub or nil, room = st.room, style = st.style,
        text = text, sort = st.sort, community = B.VenueAllowed(w) })
    if w.editVenue then
        -- furnishing a community venue: only designs that suit a public place (P.VenueOK)
        local out = {}
        for _, id in ipairs(list) do if P.VenueOK(w, SS.Objects[id]) then out[#out + 1] = id end end
        list = out
    end
    if st.affordable and not P.IsFree(w) then
        local out, cash = {}, w.money or 0
        for _, id in ipairs(list) do if SS.Objects[id].price <= cash then out[#out + 1] = id end end
        list = out
    end
    return list
end

-- While a venue is edited, how many designs of a category suit it (0 greys the category button out).
-- Cached per lot and editing state: the answer only changes with them.
function B.VenueCount(w, cat)
    if not (w and w.editVenue) then return C.Count(cat) end
    local key = tostring(w.lot) .. ":" .. tostring(w.editVenue)
    if B.venueKey ~= key then
        B.venueKey, B.venueCounts = key, {}
        for _, id in ipairs(C.order) do
            local def = SS.Objects[id]
            if P.VenueOK(w, def) then B.venueCounts[def.cat] = (B.venueCounts[def.cat] or 0) + 1 end
        end
    end
    return B.venueCounts[cat] or 0
end

-- Can the household pay for a design right now? (Always true while editing for free.)
function B.Affordable(w, def)
    return P.IsFree(w) or (def.price or 0) <= (w.money or 0)
end

---------------------------------------------------------------------------------------------------
-- Thumbnails: SS.Art.thumbs[defId] (per variant or one), else the object's own sprite (the main
-- slice of its origin cell, facing 0), else a category icon, else the category's short name.
---------------------------------------------------------------------------------------------------
function B.ThumbSprite(defId, variant)
    local A = SS.Art
    local def = SS.Objects[defId]
    if not (A and A.sprites and def) then return nil end
    local th = A.thumbs and A.thumbs[defId]
    if type(th) == "table" then th = th[variant or ""] or th.base or th[1] end
    if type(th) == "string" and A.sprites[th] then return th, "thumb" end
    local art = A.objects and A.objects[defId]
    if type(art) == "table" and type(art.states) == "table" then
        -- docs/ART.md 2.x: the model's rendered thumbnail, else the base state's first piece at rotation 0
        if type(art.thumb) == "string" and A.sprites[art.thumb] then return art.thumb, "thumb" end
        local base = art.states.base
        local rec = type(base) == "table" and (base[0] or base["0"])
        local p = type(rec) == "table" and type(rec.p) == "table" and rec.p[1]
        if type(p) == "table" and type(p[1]) == "string" and A.sprites[p[1]] then return p[1], "sprite" end
    elseif type(art) == "table" then
        -- 0.1 layout: objects[def][variant][rotation] = { { dx, dy, piece, sprite }, ... }
        local set = art[variant or ""] or art.base
        if not set then for _, k in ipairs(sortedKeys(art)) do set = art[k]; break end end
        local slices = type(set) == "table" and (set[0] or set[1])
        if type(slices) == "table" then
            local pick
            for _, sl in ipairs(slices) do
                if type(sl) == "table" and sl[1] == 0 and sl[2] == 0 and sl[3] == "main" then pick = sl[4]; break end
            end
            pick = pick or (type(slices[1]) == "table" and slices[1][4]) or nil
            if pick and A.sprites[pick] then return pick, "sprite" end
        end
    end
    local alias = defId .. ":base:0:0,0:main"   -- the 0.1 sprite name, kept by the art build as an alias
    if A.sprites[alias] then return alias, "sprite" end
    local icons = A.icons or {}
    for _, name in ipairs({ "cat_" .. tostring(def.cat), def.cat or "", "room" }) do
        if icons[name] and A.sprites[icons[name]] then return icons[name], "icon" end
    end
end

function B.ShowThumb(tex, label, defId, variant)
    local def = defId and SS.Objects[defId]
    local sprite, kind = nil, nil
    if def then sprite, kind = B.ThumbSprite(defId, variant) end
    if sprite and K.SetSprite(tex, sprite, 52, 52) then
        label:SetText("")
        return kind
    end
    tex:Hide()
    local cat = def and C.CAT[def.cat]
    label:SetText(cat and cat.short or (def and def.name) or "")
    return nil
end

---------------------------------------------------------------------------------------------------
-- Text helpers for the details panel
---------------------------------------------------------------------------------------------------
function B.RatingsText(def)
    local t = {}
    for _, k in ipairs(C.RATING_ORDER) do
        local v = def.ratings and def.ratings[k]
        if v then t[#t + 1] = C.RATING_LABEL[k] .. " " .. v end
    end
    if #t == 0 then return "Decorative: no need ratings" end
    return table.concat(t, "  ")
end

function B.RatingsTip(def)
    local lines = { def.name .. ": ratings out of 10" }
    for _, k in ipairs(C.RATING_ORDER) do
        local v = def.ratings and def.ratings[k]
        if v then lines[#lines + 1] = C.RATING_LABEL[k] .. " " .. v .. "/10: " .. (def.ratingSource[k] or "") end
    end
    if #lines == 1 then lines[2] = "It adds nothing measurable beyond its looks." end
    return lines
end

function B.FootprintText(def)
    local w, d = C.Size(def)
    local t = { "Footprint " .. w .. "x" .. d }
    local seats, beds = C.Places(def, "seat"), C.Places(def, "bed")
    if seats > 0 then t[#t + 1] = seats .. (seats == 1 and " seat" or " seats") end
    if beds > 0 then t[#t + 1] = beds .. (beds == 1 and " sleeper" or " sleepers") end
    local slots = #C.SurfaceSlots(def)
    if slots > 0 then t[#t + 1] = slots .. (slots == 1 and " surface spot" or " surface spots") end
    local cap = C.CapacityText(def)   -- only a capacity some module reads ("loads 12 dishes")
    if cap then t[#t + 1] = cap end
    local mounts = { wall = "wall-mounted", ceiling = "ceiling-mounted", surface = "goes on a surface", window = "fits a window" }
    if mounts[def.mount] then t[#t + 1] = mounts[def.mount] end
    return table.concat(t, " - ")
end

function B.PriceText(w, def)
    local t = money(def.price) .. " - " .. (C.TIER_LABEL[def.tier] or "") .. " - " .. (C.STYLE_LABEL[def.style] or "")
    if P.IsFree(w) then return t .. " (free while editing)" end
    if not B.Affordable(w, def) then t = t .. " - short by " .. money(def.price - (w.money or 0)) end
    return t
end

-- What selling a placed object means, in words (value and depreciation disclosed).
function B.SaleText(w, oid)
    local o = w.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return "" end
    local total, lines = P.Quote(w, oid)
    if P.IsFree(w) then return "Removing the " .. def.name .. " pays nothing back while editing for free." end
    local own = lines[1]
    local t
    if own and own.full then
        t = "Sells for " .. money(own.value) .. ": a full refund (bought today and not used yet)."
    elseif def.appreciates and own and own.value >= (o.paid or def.price) then
        t = "Sells for " .. money(own.value) .. ": original art keeps its value."
    else
        local paid = o.paid or def.price
        t = "Sells for " .. money(own and own.value or 0) .. " (paid " .. money(paid) .. "; used furniture loses "
            .. money(math.max(0, paid - (own and own.value or 0))) .. ")."
    end
    if #lines > 1 then
        local names = {}
        for n = 2, #lines do names[#names + 1] = lines[n].name .. " " .. money(lines[n].value) end
        t = t .. " With what rests on it (" .. table.concat(names, ", ") .. "): " .. money(total) .. "."
    end
    return t
end

---------------------------------------------------------------------------------------------------
-- Tools: holding a design ("buy"), a stored object ("item") or a picked-up object ("move")
---------------------------------------------------------------------------------------------------
function B.SetStatus(text, kind)
    st.status, st.statusKind = text, kind
    if B.frame then
        B.status:SetText(text or "")
        tint(B.status, kind == "warn" and "warn" or kind == "good" and "good" or "inkSoft")
    end
end

local function marksFor(g)
    local out = {}
    local lv = g.level or 0
    for _, c in ipairs(g.approaches or {}) do
        out[#out + 1] = { i = c[1], j = c[2], level = lv, color = c.ok and { 0.30, 0.60, 1.00, 0.45 } or { 1.00, 0.60, 0.20, 0.55 } }
    end
    for _, c in ipairs(g.blocked or {}) do out[#out + 1] = { i = c[1], j = c[2], level = lv, color = { 1.00, 0.20, 0.15, 0.55 } } end
    return out
end

function B.ClearGhost()
    st.ghost, st.ghostKey = nil, nil
    if SS.Render.SetGhost then SS.Render.SetGhost(nil) end
    if SS.Render.SetCellMarks then SS.Render.SetCellMarks(nil) end
end

-- Recompute the ghost at the cursor (skipped when nothing relevant changed since the last frame).
-- Runs on every mouse move: the change test compares fields in one reused table (no strings or
-- tables are made unless the ghost really has to be rebuilt).
st.gk = st.gk or {}
local function ghostSame(gk, t, c, w, fine)
    return gk.tool == t and gk.def == t.def and gk.x == c.x and gk.y == c.y and gk.level == c.level and gk.f == t.f
        and gk.variant == t.variant and gk.fine == fine and gk.lot == w.lot and gk.version == (w.lot.version or 0)
        and gk.money == (w.money or 0) and gk.turned == (t.turned and true or false)
end
local function ghostRemember(gk, t, c, w, fine)
    gk.tool, gk.def, gk.x, gk.y, gk.level, gk.f, gk.variant, gk.fine = t, t.def, c.x, c.y, c.level, t.f, t.variant, fine
    gk.lot, gk.version, gk.money, gk.turned = w.lot, w.lot.version or 0, w.money or 0, t.turned and true or false
end
function B.UpdateGhost(force)
    local w = getWorld()
    local t, c = st.tool, st.cursor
    if not (w and t and c) then B.ClearGhost(); return end
    local def = SS.Objects[t.def]
    if not def then B.ClearGhost(); return end
    -- items on surfaces follow the cursor within a cell (quarter-tile steps pick the slot)
    local fine = def.mount == "surface" and (math.floor(c.px * 4) * 4096 + math.floor(c.py * 4)) or 0
    if st.ghostKey and not force and ghostSame(st.gk, t, c, w, fine) then return st.ghost end
    local f = t.f
    if t.auto and not t.turned then
        local af = P.AutoFacing(w, def, c.x, c.y, c.level, f, t.family)
        if af then f = af end
    end
    t.shownF = f
    local price = (t.kind == "buy" and not P.IsFree(w)) and def.price or nil
    local g = P.Ghost(w, t.def, c.x, c.y, f, c.level, { variant = t.variant, px = c.px, py = c.py, ignore = t.family, price = price, moving = t.oid })
    ghostRemember(st.gk, t, c, w, fine)
    st.ghost, st.ghostKey = g, true
    SS.Render.SetGhost(g)
    if SS.Render.SetCellMarks then SS.Render.SetCellMarks(marksFor(g)) end
    if not g.valid and g.reason then B.SetStatus(g.reason, "warn")
    elseif st.statusKind == "warn" then B.SetStatus(B.HoldHint(), nil) end
    return g
end

-- The cursor on the lot (one table, updated in place: this runs on every mouse move).
function B.SetCursor(wx, wy, level)
    if type(wx) ~= "number" or type(wy) ~= "number" or wx ~= wx or wy ~= wy then return end
    local c = st.cursor
    if not c then c = {}; st.cursor = c end
    c.x, c.y, c.level, c.px, c.py = math.floor(wx), math.floor(wy), level or 0, wx, wy
end

function B.HoldHint()
    local t = st.tool
    if not t then return "Pick something from the list, or click an object on the lot to pick it up." end
    local def = SS.Objects[t.def]
    local name = def and def.name or "it"
    if t.kind == "move" then return "Moving the " .. name .. ": click to put it down. R rotates; Esc leaves it where it was." end
    return "Placing the " .. name .. ": click the lot. R rotates; Shift+click places several; Esc or right-click stops."
end

-- Hold a design from the catalogue.
function B.HoldDesign(defId, variant, f)
    local def = SS.Objects[defId]
    if not def then return false end
    B.ClearGhost()
    st.tool = { kind = "buy", def = defId, variant = variant or st.variant[defId] or (def.variants[1] and def.variants[1].id), f = f or st.lastF or 0,
        auto = P.IsChair(def) and f == nil }
    st.selected = defId
    B.SetStatus(B.HoldHint())
    B.UpdateGhost(true)
    B.RefreshDetails()
    return true
end

-- Hold a stored object item (placing it takes it out of the inventory).
function B.HoldItem(item)
    local def = type(item) == "table" and item.kind == "object" and item.def and SS.Objects[item.def]
    local w = getWorld()
    if item and not B.StoredAllowed(w) then
        local _, why = P.InventoryHere(w or {})
        st.tool, st.selected = nil, nil
        B.ClearGhost()
        B.SetStatus(why or "The household inventory is not available here.", "warn")
        B.RefreshDetails()
        return false
    end
    st.selected = item
    if not def then
        st.tool = nil
        B.ClearGhost()
        B.SetStatus(item and ((item.name or "This item") .. " is used from live mode (gifts, books, clothing and food); it can be sold here.") or B.HoldHint())
        B.RefreshDetails()
        return false
    end
    B.ClearGhost()
    st.tool = { kind = "item", def = item.def, item = item, variant = item.data and item.data.variant, f = st.lastF or 0 }
    B.SetStatus(B.HoldHint())
    B.UpdateGhost(true)
    B.RefreshDetails()
    return true
end

-- Pick up a placed object to move it (children come along).
function B.PickUp(oid)
    local w = getWorld()
    local o = w and w.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return false end
    if P.BuildPiece(def) then
        notice("Use build mode for the " .. def.name .. ".")
        B.SetStatus("Use build mode for the " .. def.name .. ".", "warn")
        return false
    end
    local family = { [oid] = true }
    for _, c in ipairs(P.Children(w, oid)) do family[c] = true end
    B.ClearGhost()
    st.tool = { kind = "move", oid = oid, def = o.def, variant = o.variant, f = o.f or 0, family = family,
        from = { x = o.x, y = o.y, f = o.f or 0, level = o.level or 0 } }
    st.selected = nil
    st.focus = oid
    if not st.cursor then st.cursor = { x = o.x, y = o.y, level = o.level or 0, px = o.x + 0.5, py = o.y + 0.5 } end
    B.SetStatus(B.HoldHint())
    B.UpdateGhost(true)
    B.RefreshDetails()
    return true
end

-- Stop holding anything (never charges: nothing was bought yet, a picked-up object never moved).
function B.Cancel(silent)
    local t = st.tool
    st.tool = nil
    B.ClearGhost()
    if t and not silent then
        B.SetStatus(t.kind == "move" and "Left where it was." or "Stopped placing; nothing was charged.")
    end
    B.RefreshDetails()
    return t ~= nil
end

function B.Rotate(dir)
    dir = dir or 1
    local t = st.tool
    local w = getWorld()
    if t then
        t.f = ((t.shownF or t.f or 0) + dir) % 4
        t.turned = true
        st.lastF = t.kind ~= "move" and t.f or st.lastF
        B.UpdateGhost(true)
        return true
    end
    -- empty hand: turn the object last placed or picked up where it stands
    local oid = st.focus
    if w and oid and w.lot.objects[oid] then
        local ok, why = P.Rotate(w, oid, dir)
        if ok then cue("place"); B.SetStatus("Turned the " .. SS.Objects[w.lot.objects[oid].def].name .. ".", "good")
        else notice(why); B.SetStatus(why, "warn") end
        B.Refresh()
        return ok
    end
    B.SetStatus("Pick something up (or place something) to rotate it.", "warn")
    return false
end

-- Place whatever is held at the cursor.
function B.PlaceHeld()
    local w = getWorld()
    local t, c = st.tool, st.cursor
    if not (w and t) then return false end
    if not c then B.SetStatus("Point at the lot to place it.", "warn"); return false end
    local def = SS.Objects[t.def]
    local f = t.shownF or t.f or 0
    if t.auto and not t.turned then f = P.AutoFacing(w, def, c.x, c.y, c.level, f, t.family) or f end
    local opts = { variant = t.variant, px = c.px, py = c.py }
    local ok, why, oid
    if t.kind == "buy" then
        ok, why, oid = P.Buy(w, t.def, c.x, c.y, f, c.level, opts)
        if ok then B.SetStatus("Bought the " .. def.name .. (P.IsFree(w) and "." or (" for " .. money(w.lot.objects[oid].paid or 0) .. ".")), "good") end
    elseif t.kind == "item" then
        ok, why, oid = P.PlaceItem(w, t.item, c.x, c.y, f, c.level, opts)
        if ok then B.SetStatus("Placed the " .. def.name .. " from the inventory.", "good") end
    elseif t.kind == "move" then
        local o = w.lot.objects[t.oid]
        if not o then B.Cancel(true); B.SetStatus("That object is no longer here.", "warn"); return false end
        if o.x == c.x and o.y == c.y and (o.f or 0) == f % 4 and (o.level or 0) == c.level and not o.parent then
            B.Cancel(true)
            B.SetStatus("Put back where it was.")
            return true
        end
        ok, why, oid = P.Move(w, t.oid, c.x, c.y, f, c.level, opts)
        if ok then B.SetStatus("Moved the " .. def.name .. " (moving is free).", "good") end
    end
    if not ok then
        notice(why)
        B.SetStatus(why, "warn")
        return false, why
    end
    cue("place")
    st.focus = oid
    local keep = t.kind == "buy" and (st.rep or (IsShiftKeyDown and IsShiftKeyDown()))
    if keep then
        st.ghostKey = nil
    else
        st.tool = nil
        B.ClearGhost()
    end
    B.Refresh()
    return true, nil, oid
end

-- Sell a placed object (value shown; asks first when things rest on it). opts.live: started from live
-- mode's object menu, where there is no undo: the history is cleared once the sale has happened
-- (after the confirmation, when one is asked), so it can never be undone from buy mode later.
local function endLive(opts)
    if opts and opts.live and UI.mode ~= "buy" and UI.mode ~= "build" and SS.Undo and SS.Undo.Clear then SS.Undo.Clear() end
end
function B.SellPlaced(oid, opts)
    local w = getWorld()
    local o = w and oid and w.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return false end
    local function done(ok, why, value)
        endLive(opts)
        if ok then
            if st.tool and st.tool.oid == oid then st.tool = nil; B.ClearGhost() end
            if st.focus == oid then st.focus = nil end
            B.SetStatus("Sold the " .. def.name .. (value and value > 0 and (" for " .. money(value)) or "") .. ".", "good")
        else
            notice(why)
            B.SetStatus(why, "warn")
        end
        B.Refresh()
        return ok
    end
    local ok, why, value, ask = P.Sell(w, oid)
    if ok then return done(ok, why, value) end
    if not (ask and ask.needConfirm) then return done(false, why) end
    local text = def.name .. " has " .. ask.count .. (ask.count == 1 and " thing" or " things") .. " resting on it. Sell "
        .. (ask.count == 1 and "it" or "them") .. " too? " .. B.SaleText(w, oid)
    UI.Confirm(text, function()
        done(P.Sell(w, oid, { withChildren = true }))
    end, function() B.SetStatus("Kept the " .. def.name .. ".") end)
    return nil
end

function B.StorePlaced(oid, opts)
    local w = getWorld()
    local o = w and oid and w.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def then return false end
    local n = #P.Children(w, oid)
    local ok, why = P.Store(w, oid)
    endLive(opts)
    if ok then
        if st.tool and st.tool.oid == oid then st.tool = nil; B.ClearGhost() end
        if st.focus == oid then st.focus = nil end
        B.SetStatus("Put the " .. def.name .. (n > 0 and (" and " .. n .. (n == 1 and " thing" or " things") .. " on it") or "") .. " in the household inventory.", "good")
    else
        notice(why)
        B.SetStatus(why, "warn")
    end
    B.Refresh()
    return ok
end

-- Eyedropper: hold a new copy of a placed object's design, colour and facing.
function B.Copy(oid)
    local w = getWorld()
    local e, why = P.Eyedropper(w, oid)
    if not e then notice(why); B.SetStatus(why, "warn"); return false end
    if st.tool and st.tool.kind == "move" then B.Cancel(true) end
    local def = SS.Objects[e.def]
    st.cat, st.sub, st.search = def.cat, nil, ""
    if B.searchBox then B.searchBox:SetText("") end
    st.variant[e.def] = e.variant
    B.Refresh(true)
    B.ShowEntry(e.def)
    B.HoldDesign(e.def, e.variant, e.f)
    B.SetStatus("Copied the " .. def.name .. ": click to place another.")
    return true
end

function B.SellStored(item)
    local w = getWorld()
    if not w then return false end
    local ok, why, value = P.SellItem(w, item)
    if ok then
        if st.tool and st.tool.item == item then st.tool = nil; B.ClearGhost() end
        if st.selected == item then st.selected = nil end
        B.SetStatus("Sold " .. (item.name or "the item") .. ((value or 0) > 0 and (" for " .. money(value) .. ".") or "."), "good")
    else
        notice(why)
        B.SetStatus(why, "warn")
    end
    B.Refresh()
    return ok
end

local function undoLabel(tx)
    if not tx then return nil end
    if SS.Undo.Describe then return SS.Undo.Describe(tx) end
    return tx.label
end
function B.UndoTip()
    local tx = SS.Undo.Peek and SS.Undo.Peek() or SS.Undo.stack[#SS.Undo.stack]
    return tx and ("Undo: " .. undoLabel(tx) .. " (Ctrl+Z)") or "Nothing to undo."
end
function B.RedoTip()
    local tx = SS.Undo.PeekRedo and SS.Undo.PeekRedo() or SS.Undo.redo[#SS.Undo.redo]
    return tx and ("Redo: " .. undoLabel(tx) .. " (Ctrl+Y)") or "Nothing to redo."
end

function B.Undo()
    local w = getWorld()
    if not w then return false end
    if st.tool and st.tool.kind == "move" then B.Cancel(true) end
    local tip = B.UndoTip()
    local ok, why = SS.Undo.Undo(w)
    if ok then B.SetStatus(tip:gsub(" %(Ctrl%+Z%)$", "") .. ".", "good")
    else why = why or "Nothing to undo."; notice(why); B.SetStatus(why, "warn") end
    st.ghostKey = nil
    B.Refresh()
    return ok
end

function B.Redo()
    local w = getWorld()
    if not w then return false end
    if st.tool and st.tool.kind == "move" then B.Cancel(true) end
    local tip = B.RedoTip()
    local ok, why = SS.Undo.Redo(w)
    if ok then B.SetStatus(tip:gsub(" %(Ctrl%+Y%)$", "") .. ".", "good")
    else why = why or "Nothing to redo."; notice(why); B.SetStatus(why, "warn") end
    st.ghostKey = nil
    B.Refresh()
    return ok
end

---------------------------------------------------------------------------------------------------
-- Browsing actions
---------------------------------------------------------------------------------------------------
function B.SetCategory(cat)
    local w = getWorld()
    if cat == B.STORED and not B.StoredAllowed(w) then
        local _, why = P.InventoryHere(w or {})
        B.SetStatus(why or "The household inventory is not available here.", "warn")
        return false
    end
    if cat == "community" and not B.VenueAllowed(w) then
        B.SetStatus("Venue equipment is for community lots.", "warn")
        return false
    end
    if cat ~= B.STORED and C.CAT[cat] and w and w.editVenue and B.VenueCount(w, cat) == 0 then
        B.SetStatus("Nothing in " .. C.CAT[cat].label .. " is sold for public venues.", "warn")
        return false
    end
    st.cat, st.sub = cat, nil
    if st.tool and st.tool.kind ~= "move" then B.Cancel(true) end
    B.SavePrefs()
    B.Refresh(true)
    return true
end

local function cycle(list, cur, dir)
    local n = 0
    for k, v in ipairs(list) do if v == cur then n = k end end
    n = (n + (dir or 1)) % (#list + 1)
    return list[n]   -- index 0 = nil = "all"
end

function B.SubList()
    if st.cat == B.STORED then
        local kinds, seen = {}, {}
        local w = getWorld()
        for _, it in ipairs(w and Inv.List(w) or {}) do
            if not seen[it.kind] then seen[it.kind] = true; kinds[#kinds + 1] = it.kind end
        end
        table.sort(kinds)
        return kinds
    end
    local out = {}
    for _, s in ipairs(C.CAT[st.cat].subs) do out[#out + 1] = s[1] end
    return out
end

function B.CycleSub(dir) st.sub = cycle(B.SubList(), st.sub, dir); B.SavePrefs(); B.Refresh(true) end
function B.CycleRoom(dir)
    local rooms = {}
    for _, r in ipairs(C.ROOMS) do if r ~= "venue" or B.VenueAllowed(getWorld()) then rooms[#rooms + 1] = r end end
    st.room = cycle(rooms, st.room, dir); B.SavePrefs(); B.Refresh(true)
end
function B.CycleStyle(dir) st.style = cycle(C.STYLES, st.style, dir); B.SavePrefs(); B.Refresh(true) end
function B.CycleSort()
    local n = 1
    for k, v in ipairs(B.SORTS) do if v == st.sort then n = k end end
    st.sort = B.SORTS[n % #B.SORTS + 1]
    B.SavePrefs(); B.Refresh(true)
end
function B.ToggleAffordable() st.affordable = not st.affordable; B.SavePrefs(); B.Refresh(true) end
function B.ToggleRepeat() st.rep = not st.rep; B.SavePrefs(); B.RefreshButtons() end
function B.SetSearch(text)
    text = tostring(text or "")
    if text == st.search then return end
    st.search = text
    B.Refresh(true)
end

-- Cycle the colour/material variant of the selected design (the held one follows).
function B.CycleVariant(dir)
    local id = type(st.selected) == "string" and st.selected or (st.tool and st.tool.kind == "buy" and st.tool.def)
    local def = id and SS.Objects[id]
    if not def or #def.variants < 2 then return false end
    local cur = st.variant[id] or def.variants[1].id
    local n = 1
    for k, v in ipairs(def.variants) do if v.id == cur then n = k end end
    n = (n - 1 + (dir or 1)) % #def.variants + 1
    st.variant[id] = def.variants[n].id
    if st.tool and st.tool.kind == "buy" and st.tool.def == id then st.tool.variant = st.variant[id]; B.UpdateGhost(true) end
    B.RefreshDetails()
    return true
end

-- A row of the list was clicked.
function B.Choose(entry)
    local w = getWorld()
    if not w then return end
    if type(entry) == "string" then
        if st.tool and st.tool.kind == "move" then B.Cancel(true) end
        B.HoldDesign(entry)
    elseif type(entry) == "table" then
        if st.tool and st.tool.kind == "move" then B.Cancel(true) end
        B.HoldItem(entry)
    end
    if B.list then B.list:Page(B.list.page) end
end

-- Page the list so that `entry` is visible.
function B.ShowEntry(entry)
    if not B.list then return end
    for n, it in ipairs(B.list.items or {}) do
        if it == entry then B.list:Page(math.floor((n - 1) / B.list.perPage) + 1); return true end
    end
end

---------------------------------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------------------------------
local function fillRow(r, entry)
    local w = getWorld()
    r.entry = entry
    local selected = entry == st.selected or (st.tool and ((st.tool.kind == "buy" and st.tool.def == entry) or (st.tool.item and st.tool.item == entry)))
    r.sel:SetShown(selected and true or false)
    if type(entry) == "string" then
        local def = SS.Objects[entry]
        local can = w and B.Affordable(w, def)
        r.name:SetText(def.name)
        r.price:SetText((can and "" or "! ") .. money(def.price))
        tint(r.name, can and "ink" or "inkSoft")
        tint(r.price, can and "ink" or "warn")
    else
        r.name:SetText(entry.name or "?")
        r.price:SetText(money(w and payout(w, P.ItemValue(w, entry)) or 0))
        tint(r.name, entry.kind == "object" and "ink" or "inkSoft")
        tint(r.price, "ink")
    end
end

local function rowTip(r)
    local e = r.entry
    local w = getWorld()
    if type(e) == "string" then
        local def = SS.Objects[e]
        local lines = { def.name, B.PriceText(w, def), B.FootprintText(def), B.RatingsText(def) }
        if w and not B.Affordable(w, def) then lines[#lines + 1] = "The household cannot afford this yet." end
        return lines
    elseif type(e) == "table" then
        return { e.name or "?", (B.KIND_LABEL[e.kind] or e.kind or "") .. " - sells for " .. money(w and payout(w, P.ItemValue(w, e)) or 0)
                .. ((w and P.IsFree(w)) and " (nothing is paid while money is off)" or ""),
            e.kind == "object" and "Click, then click the lot to place it." or "Used from live mode; it can be sold here." }
    end
end

function B.Create(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    B.frame = f
    -- left: categories (2 columns x 7 rows)
    B.catBtns = {}
    local cats = {}
    for _, c in ipairs(C.CATEGORIES) do cats[#cats + 1] = { id = c.id, label = c.short, tip = c.label } end
    cats[#cats + 1] = { id = B.STORED, label = "Stored", tip = "The household inventory: stored furniture, gifts, books and more" }
    for n, c in ipairs(cats) do
        local b = K.Button(f, c.label, 56, 16, function() B.SetCategory(c.id) end, c.tip)
        local colN, rowN = (n - 1) % 2, math.floor((n - 1) / 2)
        b:SetPoint("TOPLEFT", 4 + colN * 57, -4 - rowN * 17)
        -- category icon beside the label when the art module provides it (docs/art_requests/catalogue.md)
        if b.SetIcon then b:SetIcon("cat_" .. tostring(c.id)) end
        B.catBtns[c.id] = b
    end
    -- middle: filters
    local mx = 120
    B.subBtn = K.Button(f, "All", 100, 16, function(_, btn) B.CycleSub(btn == "RightButton" and -1 or 1) end, "Subcategory (click to cycle)")
    B.subBtn:SetPoint("TOPLEFT", mx, -4)
    B.roomBtn = K.Button(f, "Any room", 76, 16, function(_, btn) B.CycleRoom(btn == "RightButton" and -1 or 1) end, "Room filter (click to cycle)")
    B.roomBtn:SetPoint("LEFT", B.subBtn, "RIGHT", 2, 0)
    B.styleBtn = K.Button(f, "Any style", 76, 16, function(_, btn) B.CycleStyle(btn == "RightButton" and -1 or 1) end, "Style filter (click to cycle)")
    B.styleBtn:SetPoint("LEFT", B.roomBtn, "RIGHT", 2, 0)
    for _, b in ipairs({ B.subBtn, B.roomBtn, B.styleBtn }) do b:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    local eb = CreateFrame("EditBox", nil, f)
    eb:SetSize(86, 16)
    eb:SetPoint("TOPLEFT", mx, -22)
    eb:SetAutoFocus(false)
    eb:SetFontObject(GameFontHighlightSmall)
    eb:SetMaxLetters(32)
    eb:SetTextInsets(4, 4, 0, 0)
    local ink = K.COL.ink
    eb:SetTextColor(ink[1], ink[2], ink[3])
    local ebg = K.Tex(eb, "BACKGROUND", col("panelDark")); ebg:SetAllPoints()
    eb.hint = K.Text(eb, 10, col("inkSoft")); eb.hint:SetPoint("LEFT", 4, 0); eb.hint:SetText("Search...")
    eb:SetScript("OnTextChanged", function(self) local t = self:GetText() or ""; self.hint:SetShown(t == ""); B.SetSearch(t) end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    K.Tooltip(eb, "Search every category by name, room, style, tag or colour")
    B.searchBox = eb
    B.clearBtn = K.Button(f, "x", 14, 16, function() eb:SetText(""); B.SetSearch("") end, "Clear the search")
    B.clearBtn:SetPoint("LEFT", eb, "RIGHT", 1, 0)
    B.sortBtn = K.Button(f, "Price: low", 72, 16, function() B.CycleSort() end, function() return "Sort: " .. B.SORT_TIP[st.sort or "price"] .. " (click to change)" end)
    B.sortBtn:SetPoint("LEFT", B.clearBtn, "RIGHT", 2, 0)
    B.affordBtn = K.Button(f, "Affordable", 76, 16, function() B.ToggleAffordable() end, "Show only what the household can pay for right now")
    B.affordBtn:SetPoint("LEFT", B.sortBtn, "RIGHT", 2, 0)
    -- middle: the virtualised list
    B.list = K.PagedList(f, B.ROWS, B.ROW_H, function(r)
        r.sel = K.Tex(r, "BACKGROUND", { 0.96, 0.74, 0.30, 0.35 }); r.sel:SetAllPoints(); r.sel:Hide()
        r.hi = K.Tex(r, "HIGHLIGHT", { 0.25, 0.64, 0.60, 0.30 }); r.hi:SetAllPoints()
        r.name = K.Text(r, 11, col("ink")); r.name:SetPoint("LEFT", 3, 0); r.name:SetWidth(180); r.name:SetWordWrap(false)
        r.price = K.Text(r, 11, col("ink"), "RIGHT"); r.price:SetPoint("RIGHT", -3, 0)
        r:SetScript("OnClick", function(self) if self.entry ~= nil then B.Choose(self.entry) end end)
        K.Tooltip(r, rowTip)
    end, function(r, entry) fillRow(r, entry) end)
    B.list.frame:SetPoint("TOPLEFT", mx, -41)
    B.list.frame:SetSize(256, B.ROWS * B.ROW_H + 20)
    B.count = K.Text(B.list.frame, 9, col("inkSoft"), "CENTER"); B.count:SetPoint("BOTTOM", 0, 12)
    -- right: details
    local d = CreateFrame("Frame", nil, f)
    d:SetPoint("TOPLEFT", 382, 0); d:SetPoint("BOTTOMRIGHT", -4, 0)
    B.details = d
    d.thumbBg = K.Tex(d, "BACKGROUND", col("panelDark")); d.thumbBg:SetSize(56, 56); d.thumbBg:SetPoint("TOPLEFT", 0, -4)
    d.thumb = d:CreateTexture(nil, "ARTWORK"); d.thumb:SetPoint("CENTER", d.thumbBg, "CENTER"); d.thumb:SetSize(52, 52); d.thumb:Hide()
    d.thumbLabel = K.Text(d, 9, col("inkSoft"), "CENTER"); d.thumbLabel:SetPoint("CENTER", d.thumbBg, "CENTER")
    d.name = K.Text(d, 13, col("ink")); d.name:SetPoint("TOPLEFT", 62, -4); d.name:SetPoint("RIGHT", -2, 0); d.name:SetWordWrap(false)
    d.line1 = K.Text(d, 11, col("ink")); d.line1:SetPoint("TOPLEFT", 62, -21); d.line1:SetPoint("RIGHT", -2, 0); d.line1:SetWordWrap(false)
    d.line2 = K.Text(d, 11, col("inkSoft")); d.line2:SetPoint("TOPLEFT", 62, -34); d.line2:SetPoint("RIGHT", -2, 0); d.line2:SetWordWrap(false)
    d.line3 = K.Text(d, 11, col("ink")); d.line3:SetPoint("TOPLEFT", 62, -47); d.line3:SetPoint("RIGHT", -2, 0); d.line3:SetWordWrap(false)
    d.rateHit = CreateFrame("Frame", nil, d); d.rateHit:SetPoint("TOPLEFT", 62, -45); d.rateHit:SetPoint("RIGHT", -2, 0); d.rateHit:SetHeight(14)
    d.rateHit:EnableMouse(true)
    K.Tooltip(d.rateHit, function() local def = B.DetailDef(); return def and B.RatingsTip(def) or nil end)
    d.variant = K.Button(d, "Colour", 120, 16, function(_, btn) B.CycleVariant(btn == "RightButton" and -1 or 1) end, "Colour and material (click to cycle)")
    d.variant:SetPoint("TOPLEFT", 0, -63)
    d.variant:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    d.req = K.Text(d, 10, col("ink")); d.req:SetPoint("TOPLEFT", 126, -65); d.req:SetPoint("RIGHT", -2, 0); d.req:SetWordWrap(false)
    d.desc = K.Text(d, 10, col("inkSoft")); d.desc:SetPoint("TOPLEFT", 0, -82); d.desc:SetPoint("RIGHT", -2, 0)
    d.desc:SetHeight(34); d.desc:SetWordWrap(true); d.desc:SetJustifyV("TOP")
    B.status = K.Text(d, 10, col("inkSoft")); B.status:SetPoint("BOTTOMLEFT", 0, 23); B.status:SetPoint("RIGHT", -2, 0); B.status:SetWordWrap(false)
    -- tool buttons
    local bar = {}
    local function add(key, label, w, fn, tip)
        local b = K.Button(d, label, w, 18, fn, tip)
        bar[#bar + 1] = b
        B[key] = b
        return b
    end
    add("rotLBtn", "<", 22, function() B.Rotate(-1) end, "Rotate anticlockwise (Shift+R)")
    add("rotRBtn", ">", 22, function() B.Rotate(1) end, "Rotate clockwise (R)")
    add("sellBtn", "Sell", 84, function() B.SellSelected() end, function() return B.SellTip() end)
    add("storeBtn", "Store", 48, function() B.StoreSelected() end, "Put the object you are holding (and what rests on it) in the household inventory")
    add("copyBtn", "Copy", 44, function() if st.tool and st.tool.kind == "move" then B.Copy(st.tool.oid) end end, "Buy another one like the object you are holding (Ctrl+click an object)")
    add("cancelBtn", "Cancel", 52, function() B.Cancel() end, "Stop placing, or leave the object where it was (Esc, right-click); nothing is charged")
    add("undoBtn", "Undo", 44, function() B.Undo() end, function() return B.UndoTip() end)
    add("redoBtn", "Redo", 44, function() B.Redo() end, function() return B.RedoTip() end)
    add("repeatBtn", "Repeat", 60, function() B.ToggleRepeat() end, "Keep placing more of the same design after each purchase (or hold Shift while clicking)")
    B.bar = bar
    B.Layout(0)
    f:SetScript("OnSizeChanged", function(self, w) B.Layout(w or self:GetWidth()) end)
    return f
end

-- Tool buttons in one row when the details column is wide enough, else two rows.
function B.Layout(width)
    if not B.bar then return end
    local right = (width and width > 0) and (width - 386) or 534
    local twoRows = right < 450
    local prev
    local n = 0
    for _, b in ipairs(B.bar) do
        b:ClearAllPoints()
        if b:IsShown() then
            n = n + 1
            if twoRows and n == 7 then b:SetPoint("BOTTOMLEFT", 0, 22)
            elseif n == 1 or not prev then b:SetPoint("BOTTOMLEFT", 0, 2)
            else b:SetPoint("LEFT", prev, "RIGHT", 2, 0) end
            prev = b
        end
    end
    B.status:ClearAllPoints()
    B.status:SetPoint("BOTTOMLEFT", twoRows and 170 or 0, twoRows and 25 or 23)
    B.status:SetPoint("RIGHT", -2, 0)
    B.twoRows = twoRows
end

-- The design shown in the details panel (selected design, held design or held object's design).
function B.DetailDef()
    local t = st.tool
    if t then return SS.Objects[t.def] end
    if type(st.selected) == "string" then return SS.Objects[st.selected] end
    if type(st.selected) == "table" and st.selected.def then return SS.Objects[st.selected.def] end
end

function B.SellTip()
    local w = getWorld()
    local t = st.tool
    if w and t and t.kind == "move" and w.lot.objects[t.oid] then return B.SaleText(w, t.oid) .. " (Delete)" end
    if w and type(st.selected) == "table" then
        if P.IsFree(w) then return "Selling " .. (st.selected.name or "it") .. " pays nothing while money is off." end
        return "Sell " .. (st.selected.name or "it") .. " for " .. money(P.ItemValue(w, st.selected)) .. "."
    end
    return "Pick up a placed object (click it on the lot) or choose a stored item to sell it."
end

function B.SellSelected()
    local t = st.tool
    if t and t.kind == "move" then return B.SellPlaced(t.oid) end
    if type(st.selected) == "table" then return B.SellStored(st.selected) end
    B.SetStatus(B.SellTip(), "warn")
    return false
end

function B.StoreSelected()
    local t = st.tool
    if t and t.kind == "move" then return B.StorePlaced(t.oid) end
    B.SetStatus("Pick up a placed object (click it on the lot) to store it.", "warn")
    return false
end

function B.RefreshButtons()
    if not B.frame then return end
    local w = getWorld()
    local venue = B.VenueAllowed(w)
    for id, b in pairs(B.catBtns) do
        if id ~= B.STORED and w and w.editVenue then
            b:SetUsable(B.VenueCount(w, id) > 0, "Not sold for public venues.")
        else
            b:SetUsable(true)
        end
        b:SetActive(id == st.cat)
        if id == "community" then b:SetShown(venue) end
    end
    local storedOK = B.StoredAllowed(w)
    local stored = (w and storedOK) and Inv.Count(w) or 0
    B.catBtns[B.STORED].label:SetText("Stored" .. (stored > 0 and (" " .. stored) or ""))
    B.catBtns[B.STORED]:SetShown(storedOK)
    if B.storeBtn:IsShown() ~= storedOK then B.storeBtn:SetShown(storedOK); B.Layout(B.frame:GetWidth()) end
    local subLabel
    if st.cat == B.STORED then subLabel = st.sub and (B.KIND_LABEL[st.sub] or st.sub) or "All items"
    else subLabel = st.sub and C.CAT[st.cat].subLabel[st.sub] or ("All " .. C.CAT[st.cat].label:lower()) end
    B.subBtn.label:SetText(subLabel)
    B.subBtn:SetActive(st.sub ~= nil)
    B.roomBtn.label:SetText(st.room and C.ROOM_LABEL[st.room] or "Any room")
    B.roomBtn:SetActive(st.room ~= nil)
    B.styleBtn.label:SetText(st.style and C.STYLE_LABEL[st.style] or "Any style")
    B.styleBtn:SetActive(st.style ~= nil)
    B.sortBtn.label:SetText(B.SORT_LABEL[st.sort or "price"])
    B.affordBtn:SetActive(st.affordable)
    B.repeatBtn:SetActive(st.rep)
    local t = st.tool
    local holdingPlaced = t and t.kind == "move" and w and w.lot.objects[t.oid] ~= nil
    local storedSel = type(st.selected) == "table" and not t
    B.cancelBtn:SetUsable(t ~= nil, "You are not holding anything.")
    B.copyBtn:SetUsable(holdingPlaced and true or false, "Pick up a placed object first (or Ctrl+click it).")
    B.storeBtn:SetUsable(holdingPlaced and true or false, "Pick up a placed object first.")
    local itemSel = type(st.selected) == "table" and w and Inv.IndexOf(w, st.selected) and (not t or t.kind == "item")
    if holdingPlaced then
        local total = P.Quote(w, t.oid)
        B.sellBtn.label:SetText(P.IsFree(w) and "Remove" or ("Sell " .. money(total)))
        B.sellBtn:SetUsable(true)
    elseif itemSel and storedOK then
        B.sellBtn.label:SetText(P.IsFree(w) and "Sell (§0)" or ("Sell " .. money(P.ItemValue(w, st.selected))))
        B.sellBtn:SetUsable(true)
    else
        B.sellBtn.label:SetText("Sell")
        B.sellBtn:SetUsable(false, "Pick up a placed object or choose a stored item first.")
    end
    local _ = storedSel
    B.undoBtn:SetUsable(#SS.Undo.stack > 0, "Nothing to undo.")
    B.redoBtn:SetUsable(#SS.Undo.redo > 0, "Nothing to redo.")
end

function B.RefreshDetails()
    if not B.frame then return end
    local d = B.details
    local w = getWorld()
    local def = B.DetailDef()
    local t = st.tool
    if not def or not w then
        d.name:SetText(st.cat == B.STORED and "Household inventory" or "Buy mode")
        d.line1:SetText(w and (P.IsFree(w) and "Everything is free while you edit this lot." or ("The household has " .. money(w.money or 0) .. ".")) or "")
        d.line2:SetText("")
        d.line3:SetText("")
        d.req:SetText("")
        d.desc:SetText(st.cat == B.STORED and "Stored furniture goes back on the lot from here; gifts, books and clothing are used from live mode."
            or "Choose a category, then pick a design. Click an object on the lot to move, sell or store it.")
        d.variant:Hide()
        B.ShowThumb(d.thumb, d.thumbLabel, nil)
        B.RefreshButtons()
        return
    end
    local variant = t and t.variant or st.variant[def.id] or (def.variants[1] and def.variants[1].id)
    B.ShowThumb(d.thumb, d.thumbLabel, def.id, variant)
    d.name:SetText(def.name)
    if t and t.kind == "move" and w.lot.objects[t.oid] then
        d.line1:SetText("Placed - " .. B.SaleText(w, t.oid))
    elseif type(st.selected) == "table" and not (t and t.kind == "buy") then
        d.line1:SetText("Stored - sells for " .. money(payout(w, P.ItemValue(w, st.selected))) .. (P.IsFree(w) and " while money is off" or "")
            .. " - " .. (C.STYLE_LABEL[def.style] or ""))
    else
        d.line1:SetText(B.PriceText(w, def))
    end
    d.line2:SetText(B.FootprintText(def))
    d.line3:SetText(B.RatingsText(def))
    d.req:SetText(C.Requirements(def))
    d.desc:SetText(def.desc or "")
    local v = C.Variant(def, variant)
    d.variant.label:SetText((v and v.name or "Standard") .. (#def.variants > 1 and ("  (" .. #def.variants .. ")") or ""))
    d.variant:Show()
    local canChange = #def.variants > 1 and not (t and t.kind ~= "buy") and type(st.selected) ~= "table"
    d.variant:SetUsable(canChange and true or false, t and t.kind ~= "buy" and "Placed and stored objects keep their colour." or "This design comes in one finish.")
    B.RefreshButtons()
end

-- Rebuild the list (reset = back to page 1) and everything that depends on money or the lot.
function B.Refresh(reset)
    local w = getWorld()
    B.items = B.Items(w)
    st.money = w and w.money
    if not B.frame then return end
    B.list.items = B.items
    B.list:Page(reset and 1 or (B.list.page or 1))
    local total = st.cat == B.STORED and (w and Inv.Count(w) or 0) or C.Count(st.search == "" and st.cat or nil)
    if st.cat ~= B.STORED and st.search == "" and w and w.editVenue then total = B.VenueCount(w, st.cat) end
    B.count:SetText(#B.items .. " of " .. total)
    st.ghostKey = nil
    if st.tool then B.UpdateGhost(true) end
    B.RefreshDetails()
end

---------------------------------------------------------------------------------------------------
-- Mode registration
---------------------------------------------------------------------------------------------------
local KEYS = setmetatable({ R = true, DELETE = true, BACKSPACE = true },
    { __index = function(_, k) if k == "Z" or k == "Y" then return IsControlKeyDown and IsControlKeyDown() or false end end })

B.mode = {
    label = "Buy", order = 10, key = "F2", audio = "buy", pausesSim = true,
    tip = "Buy mode: furnish the home (F2)",
    keys = KEYS,
    keyHelp = {
        { "R / Shift+R", "Rotate what you are holding (or the object you last placed)" },
        { "Esc / right-click", "Stop placing, or leave a picked-up object where it was (nothing is charged)" },
        { "Shift+click", "Keep placing more of the same design; on an object: sell it" },
        { "Ctrl+click", "Copy an object's design, colour and facing (eyedropper)" },
        { "Delete", "Sell the object you are holding" },
        { "Ctrl+Z / Ctrl+Y", "Undo / redo recent purchases, moves and sales" },
    },
    help = {
        "Buy mode pauses the household. Pick a category (or search), choose a design and click the lot to buy and place it.",
        "The ghost turns red where it cannot go and says why; blue squares are where people stand to use it.",
        "Click a placed object to pick it up and move it for free; things resting on it come along.",
        "Selling shows the value first: a full refund on the day of purchase if nobody has used it, less once it is used.",
        "Store puts furniture in the household inventory (the Stored tab), from where it can be placed again.",
        "Undo covers recent buy and build steps until you go back to live mode.",
    },
    canEnter = function(w) return P.CanEnter(w) end,
    create = function(parent)
        local f = B.Create(parent)
        return f
    end,
    enter = function(w)
        B.LoadPrefs(w)
        st.tool, st.cursor, st.selected, st.focus, st.search = nil, nil, nil, nil, ""
        if B.searchBox then B.searchBox:SetText("") end
        B.SetStatus(P.IsFree(w) and "Editing for free: nothing costs money here." or B.HoldHint())
        B.Refresh(true)
    end,
    exit = function()
        st.tool, st.cursor = nil, nil
        B.ClearGhost()
        if B.searchBox then B.searchBox:ClearFocus() end
        B.SavePrefs()
    end,
    click = function(btn, kind, ref, wx, wy, level)
        local w = getWorld()
        if not w then return false end
        level = level or (SS.Render.cam and SS.Render.cam.level) or 0
        if btn == "RightButton" then
            if st.tool then B.Cancel(); return true end
            return false
        end
        if btn ~= "LeftButton" then return false end
        if st.tool then
            if not wx then B.SetStatus("Point at the lot to place it.", "warn"); return true end
            B.SetCursor(wx, wy, level)
            B.PlaceHeld()
            return true
        end
        if kind == "obj" and ref and w.lot.objects[ref] then
            if IsShiftKeyDown and IsShiftKeyDown() then B.SellPlaced(ref)
            elseif IsControlKeyDown and IsControlKeyDown() then B.Copy(ref)
            else B.PickUp(ref) end
            return true
        end
        return true   -- floor clicks in buy mode give no orders
    end,
    mouseMove = function(wx, wy, level)
        if not st.tool then return end
        B.SetCursor(wx, wy, level)
        B.UpdateGhost()
    end,
    onKey = function(key)
        if key == "ESCAPE" then return B.Cancel() end
        if key == "R" then B.Rotate((IsShiftKeyDown and IsShiftKeyDown()) and -1 or 1); return true end
        if key == "DELETE" or key == "BACKSPACE" then
            if st.tool and st.tool.kind == "move" then B.SellPlaced(st.tool.oid)
            elseif type(st.selected) == "table" then B.SellStored(st.selected)
            else B.SetStatus("Pick up an object to sell it.", "warn") end
            return true
        end
        if (key == "Z" or key == "Y") and IsControlKeyDown and IsControlKeyDown() then
            if key == "Z" then B.Undo() else B.Redo() end
            return true
        end
        return false
    end,
    update = function(elapsed)
        B.acc = (B.acc or 0) + (elapsed or 0)
        if B.acc < 0.25 then return end
        B.acc = 0
        local w = getWorld()
        if w and (B.dirty or st.money ~= w.money) then
            B.dirty = false
            B.Refresh()
        end
    end,
}
UI.RegisterMode("buy", B.mode)

-- Anything that changes the lot or the inventory while buy mode is open refreshes the panel
-- (at most four times a second, from update()).
SS.On("lotChanged", function() if UI.mode == "buy" then B.dirty = true; st.ghostKey = nil end end)
SS.On("inventory", function() if UI.mode == "buy" then B.dirty = true end end)
-- Undo history belongs to build/buy sessions (build's Undo also clears itself on this event).
SS.On("uiMode", function(name) if name ~= "buy" and name ~= "build" and SS.Undo and SS.Undo.Clear then SS.Undo.Clear() end end)
SS.On("worldAttached", function() st.tool, st.cursor, st.focus, st.selected = nil, nil, nil, nil end)

-- Live mode's object menu ("Manage" group, ui-shell): move, sell or store without hunting for it.
UI.RegisterMenu("purchase", function(w, _, oid, entries)
    local o = w and w.lot.objects[oid]
    local def = o and SS.Objects[o.def]
    if not def or P.BuildPiece(def) then return end
    local okEnter, whyEnter = P.CanEnter(w)
    entries[#entries + 1] = { label = "Move this", order = 60, desc = "Open buy mode holding the " .. def.name .. " (moving is free).",
        disabled = not okEnter, reason = whyEnter,
        onClick = function() UI.SetMode("buy"); if UI.mode == "buy" then B.PickUp(oid) end end }
    if def.buyable ~= false or o.paid then
        local total = P.Quote(w, oid)
        local sellOk, sellWhy = P.CanSell(w, oid)
        local gets = payout(w, total)
        entries[#entries + 1] = { label = "Sell for " .. money(gets), order = 61, desc = B.SaleText(w, oid), cost = -gets,
            disabled = not (okEnter and sellOk), reason = whyEnter or sellWhy,
            onClick = function() B.SellPlaced(oid, { live = true }) end }
        local invOK, invWhy = P.InventoryHere(w)
        entries[#entries + 1] = { label = "Put in household inventory", order = 62, desc = "Store the " .. def.name .. " (and what rests on it) for later.",
            disabled = not (okEnter and sellOk and invOK), reason = whyEnter or sellWhy or invWhy,
            onClick = function() B.StorePlaced(oid, { live = true }) end }
    end
end)

if UI.RegisterHelp then
    UI.RegisterHelp("buy", { title = "Buy mode", order = 20, lines = B.mode.help })
end
