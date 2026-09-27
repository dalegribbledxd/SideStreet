-- Social UI: the social context menu (grouped by category, unavailable entries explained),
-- the Relationships tab (both directions, flags, family, history), the Personality tab
-- (dimensions, what they do, interests, social fatigue) and the Chatter tab (recent captions
-- with their expandable detail). Owner: social module.
-- Nothing here touches WoW frames at load: tabs are created lazily by UI/Main.lua.
local _, SS = ...
local UI = SS.UI
local K = UI.Kit
local COL = K.COL
local S, C, So, P, L = SS.Socials, SS.Conversation, SS.Social, SS.Personality, SS.Lines
local SU = {}
SS.SocialUI = SU

local function first(p) return C.First(p) end

-- Colours by palette name. The shell's kit (K.C) resolves names against the current contrast
-- setting and re-skins named textures and text when the player switches high contrast; the
-- pre-integration kit only has the K.COL tables, so fall back to those.
local function named(name) return K.C and name or COL[name] end
local function rgb(name) return (K.C and K.C(name)) or COL[name] end
local function textColor(fs, name)
    if K.SetTextColor then K.SetTextColor(fs, name) return end
    local c = COL[name]
    fs:SetTextColor(c[1], c[2], c[3])
end
SU.Named, SU.RGB = named, rgb
SU.theme = 0   -- bumped on a contrast change so cached lists redraw their dynamic colours
SS.On("uiTheme", function() SU.theme = SU.theme + 1 end)

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------
local CAT_ORDER = {}
for n, c in ipairs(S.CATS) do CAT_ORDER[c] = n end

local CAT_DESC = {
    Hello = "Introductions, greetings and goodbyes.", Talk = "Conversation: small talk, interests, gossip, debate.",
    Fun = "Jokes, stories, teasing and impressions.", Games = "Quick games you can play anywhere.",
    Kind = "Compliments, comfort, apologies and thanks.", Affection = "Friendly physical affection.",
    Romance = "Adult romance. Only between adults who are not close family.", Gifts = "Give something from the household inventory.",
    Invite = "Invite them over or out.", Group = "Group conversations.", Family = "Family and close friends.",
    Kids = "Things to do with children.", Visitors = "Hosting guests.", Mean = "Arguments, insults and other bad ideas.",
}

-- Order a social for actor with target (manual). data: order data (item, lotId).
function SU.Order(world, actor, target, d, data)
    return SS.Actions.Order(world, actor, nil, d.iid, nil, nil, { tid = target.id, data = data or {} })
end

local function ageFits(age, want)
    if want == "any" then return age == "adult" or age == "child" end
    return age == want
end

-- Can this definition ever apply between these two by age? (Hidden otherwise, to keep menus short.)
local function ageRelevant(a, b, d)
    return ageFits(a.age, d.who) and ageFits(b.age, d.whom)
end

local function entryFor(world, actor, target, d, pc)
    local ok, why = C.CanStart(world, actor, target, d, pc)
    local e = { label = d.label, desc = d.desc, order = d.order, disabled = not ok, reason = why }
    if d.id == "give_gift" or d.id == "give_flowers" then
        local kind = d.id == "give_gift" and "gift" or "flowers"
        local items = C.Items(world, actor, kind)
        if ok and #items > 1 then
            local sub = {}
            for n, it in ipairs(items) do
                sub[#sub + 1] = { label = (it.name or kind) .. (it.value and ("  " .. SS.U.fmtMoney(it.value)) or ""), order = n,
                    desc = "Give " .. (it.name or "this") .. " to " .. first(target) .. ".",
                    onClick = function() SU.Order(world, actor, target, d, { item = it }) end }
            end
            e.submenu = sub
            return e
        end
    end
    if d.id == "invite_outing" and ok then
        local root = world.root or world
        local sub = {}
        for _, lotId in ipairs(C.Venues(world)) do
            local lot = root.hood.lots[lotId]
            sub[#sub + 1] = { label = (lot and lot.name) or lotId, desc = "Suggest going to " .. ((lot and lot.name) or "this place") .. " together.",
                onClick = function() SU.Order(world, actor, target, d, { lotId = lotId }) end }
        end
        -- alphabetical by name, as the player reads them
        table.sort(sub, function(x, y) if x.label ~= y.label then return x.label < y.label end return x.desc < y.desc end)
        for n, e in ipairs(sub) do e.order = n end
        if #sub > 1 then e.submenu = sub; return e end
    end
    if ok then e.onClick = function() SU.Order(world, actor, target, d) end end
    return e
end

-- Other modules may put their own items in one of social's categories (family joins "Family").
-- Inside a category the promise holds whoever added what: what you can do now comes first, and
-- the category is greyed out only when nothing in it is possible.
--   SS.SocialUI.AddToCategory(entries, "Family", items [, { order = 45, desc = "..." }])
-- is the way in. SU.SortCategories, the last "actor" menu provider, settles any social category a
-- module appended to directly.
function SU.FindCategory(entries, cat)
    for _, e in ipairs(entries) do
        if (e.socialCat == cat or e.label == cat) and type(e.submenu) == "table" then return e end
    end
end

-- Usable entries first; each group keeps its order (a stable partition, not a sort).
function SU.SettleCategory(e)
    local list = e.submenu
    if type(list) ~= "table" then return e end
    local n, out = #list, {}
    for i = 1, n do if not list[i].disabled then out[#out + 1] = list[i] end end
    local usable = #out
    for i = 1, n do if list[i].disabled then out[#out + 1] = list[i] end end
    for i = 1, n do list[i] = out[i] end
    if usable > 0 then e.disabled, e.reason = nil, nil
    elseif n > 0 then e.disabled, e.reason = true, e.reason or list[1].reason or "Nothing here is possible right now." end
    return e
end

function SU.AddToCategory(entries, cat, items, opts)
    local e = SU.FindCategory(entries, cat)
    if not e then
        e = { label = cat, submenu = {}, socialCat = cat, order = (CAT_ORDER[cat] and 20 + CAT_ORDER[cat]) or (opts and opts.order) or 50,
            desc = (opts and opts.desc) or CAT_DESC[cat] }
        entries[#entries + 1] = e
    end
    for _, x in ipairs(items or {}) do e.submenu[#e.submenu + 1] = x end
    return SU.SettleCategory(e)
end

function SU.SortCategories(world, actor, ref, entries)
    for _, e in ipairs(entries) do
        if e.socialCat and type(e.submenu) == "table" then SU.SettleCategory(e) end
    end
end

-- Common, situation-appropriate interactions shown at the first menu level (up to QUICK_MAX
-- usable ones, in this priority order), above the category submenus.
SU.QUICK = { "apologize", "comfort", "join_group", "introduce", "ask_leave", "play_with", "small_talk", "joke",
    "compliment", "farewell" }
SU.QUICK_MAX = 4

-- Entries for the "actor" menu: the quick picks, then one submenu per category.
function SU.ActorMenu(world, actor, ref, entries)
    if not world or not actor or not ref then return end
    local target = world.actors[ref]
    if not target or target == actor or not C.Human(target) or not C.Human(actor) then return end
    local pc = C.Pair(world, actor, target)
    local quick = 0
    for _, id in ipairs(SU.QUICK) do
        local d = S.byId[id]
        if quick < SU.QUICK_MAX and d and ageRelevant(actor, target, d) and C.CanStart(world, actor, target, d, pc) then
            quick = quick + 1
            local e = entryFor(world, actor, target, d, pc)
            e.order = 10 + quick
            entries[#entries + 1] = e
        end
    end
    local cats, catWhy = {}, {}
    for _, d in ipairs(S.list) do
        if ageRelevant(actor, target, d) then
            cats[d.cat] = cats[d.cat] or {}
            table.insert(cats[d.cat], entryFor(world, actor, target, d, pc))
        else
            catWhy[d.cat] = catWhy[d.cat] or (d.whom == "child" and "Only with children." or d.whom == "adult"
                and (d.cat == "Romance" and "Romance is for adults only." or "Only with adults.")
                or (d.who == "adult" and "Only adults can do that." or "Only children can do that."))
        end
    end
    for _, cat in ipairs(S.CATS) do
        local list = cats[cat]
        if list and #list > 0 then
            local usable = 0
            for _, e in ipairs(list) do if not e.disabled then usable = usable + 1 end end
            table.sort(list, function(x, y)
                if (x.disabled and 1 or 0) ~= (y.disabled and 1 or 0) then return not x.disabled end
                return x.order < y.order
            end)
            local joined = SU.FindCategory(entries, cat)
            if joined then
                -- a module that ran earlier already opened this category: one entry, social's items first
                local theirs = joined.submenu
                joined.submenu = list
                for _, x in ipairs(theirs) do list[#list + 1] = x end
                joined.order, joined.desc, joined.socialCat = 20 + CAT_ORDER[cat], joined.desc or CAT_DESC[cat], cat
                SU.SettleCategory(joined)
            else
                entries[#entries + 1] = { label = cat, submenu = list, order = 20 + CAT_ORDER[cat], socialCat = cat,
                    desc = CAT_DESC[cat], disabled = usable == 0,
                    reason = usable == 0 and (list[1].reason or "Nothing here is possible right now.") or nil }
            end
        elseif catWhy[cat] and (cat == "Romance" or cat == "Kids") then
            -- explain why a whole category is missing
            entries[#entries + 1] = { label = cat, order = 20 + CAT_ORDER[cat], desc = CAT_DESC[cat], disabled = true, reason = catWhy[cat] }
        end
    end
    -- the relationship at a glance
    entries[#entries + 1] = { label = "How do you feel about " .. first(target) .. "?", order = 90, disabled = true,
        reason = So.FlagText(world, actor.id, target.id) .. SU.ScoreText(world, actor.id, target.id),
        desc = "Your side and theirs. Open the Relationships tab for the full picture." }
end

function SU.ScoreText(world, aId, bId)
    local r, q = So.Get(world, aId, bId), So.Get(world, bId, aId)
    local function f(x) return x and string.format("%d/%d", math.floor(x.daily + 0.5), math.floor(x.life + 0.5)) or "0/0" end
    return "  (you: " .. f(r) .. ", them: " .. f(q) .. " daily/lifetime)"
end

-- The selected person's own menu: step out of a conversation.
function SU.SelfMenu(world, actor, ref, entries)
    if not world or not actor then return end
    local sess = C.SessionOf(actor.id)
    if sess then
        entries[#entries + 1] = { label = "Leave Conversation", order = 15,
            desc = "Excuse yourself. The others carry on without you if there are enough of them.",
            onClick = function() C.RemoveMember(world, sess, actor.id, "excused", true); if C.Count(sess) < 2 then C.Dissolve(world, sess, "too few") end end }
    end
end

UI.RegisterMenu("actor", SU.ActorMenu)
UI.RegisterMenu("self", SU.SelfMenu)
UI.RegisterMenu("actor", SU.SortCategories)

-- SortCategories must run after every other module's provider. Modules register theirs as their
-- files load, which is over before any world attaches, so it moves itself to the end then (the
-- relative order of everyone else's providers is untouched).
function SU.SortLast()
    local list = UI.menuProviders and UI.menuProviders.actor
    if type(list) ~= "table" then return end
    for i = #list, 1, -1 do if list[i] == SU.SortCategories then table.remove(list, i) end end
    list[#list + 1] = SU.SortCategories
end
SS.On("worldAttached", SU.SortLast)

---------------------------------------------------------------------------
-- Shared widgets
---------------------------------------------------------------------------
local function bar(parent, w, h)
    local b = CreateFrame("Frame", nil, parent)
    b:SetSize(w, h)
    b.bg = K.Tex(b, "BACKGROUND", named("barBg")); b.bg:SetAllPoints()
    b.mid = K.Tex(b, "BORDER", named("disabled")); b.mid:SetSize(1, h); b.mid:SetPoint("CENTER")
    -- the fill changes colour with the value, so it is coloured from the current palette on every
    -- Set rather than re-skinned by name
    b.fill = K.Tex(b, "ARTWORK"); b.fill:SetHeight(h - 2)
    local c0 = rgb("good")
    b.fill:SetColorTexture(c0[1], c0[2], c0[3], 1)
    b.w = w
    -- signed value -100..100 drawn from the centre
    function b:SetSigned(v)
        v = math.max(-100, math.min(100, v or 0))
        local half = (self.w - 2) / 2
        local len = math.max(1, math.abs(v) / 100 * half)
        self.fill:ClearAllPoints()
        self.fill:SetWidth(len)
        local c = rgb(v >= 0 and "good" or "warn")
        if v >= 0 then self.fill:SetPoint("LEFT", self, "CENTER", 0, 0) else self.fill:SetPoint("RIGHT", self, "CENTER", 0, 0) end
        self.fill:SetColorTexture(c[1], c[2], c[3], 1)
    end
    -- 0..max drawn from the left
    function b:SetValue(v, max)
        local len = math.max(1, (v or 0) / (max or 10) * (self.w - 2))
        self.mid:Hide()
        self.fill:ClearAllPoints()
        self.fill:SetWidth(len)
        self.fill:SetPoint("LEFT", self, "LEFT", 1, 0)
        local c = rgb("accent")
        self.fill:SetColorTexture(c[1], c[2], c[3], 1)
    end
    return b
end
SU.Bar = bar

local function icon(parent, size)
    local t = K.Tex(parent, "ARTWORK")
    t:SetSize(size, size)
    return t
end
local function setIcon(t, name, size)
    local art = SS.Art and SS.Art.icons and SS.Art.icons[name]
    if art and K.SetSprite(t, art, size, size) then return true end
    t:Hide()
    return false
end

---------------------------------------------------------------------------
-- Relationships tab
---------------------------------------------------------------------------
-- Rows for actor: everyone known in either direction, family/household first, then by life.
function SU.RelationshipRows(world, actor)
    local root = world.root or world
    local ids, seen = {}, {}
    for _, id in ipairs(So.Known(world, actor.id)) do if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    -- one-sided: people who have feelings toward the actor the actor never recorded
    local s = So.Data(world)
    local suffix = ">" .. actor.id
    for k in pairs(s.rel) do
        if k:sub(-#suffix) == suffix then
            local id = k:sub(1, #k - #suffix)
            if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
        end
    end
    local rows = {}
    for _, id in ipairs(ids) do
        local p = root.residents[id]
        if p and id ~= actor.id then
            local ab, ba = So.Get(world, actor.id, id), So.Get(world, id, actor.id)
            local fam = So.FamilyKind(world, actor.id, id)
            rows[#rows + 1] = {
                id = id, name = p.name or id, dead = p.dead, fam = fam,
                famLabel = fam and (So.FAMILY_LABEL[fam] or fam) or nil,
                ab = ab, ba = ba, flags = So.FlagText(world, actor.id, id),
                rank = (fam and 0 or 1) + (So.SameHousehold(world, actor.id, id) and 0 or 1),
                life = ab and ab.life or 0,
            }
        end
    end
    table.sort(rows, function(x, y)
        if x.rank ~= y.rank then return x.rank < y.rank end
        if x.life ~= y.life then return x.life > y.life end
        return x.id < y.id
    end)
    return rows
end

local function historyText(world, e)
    local d = S.byId[e.id]
    local label = d and d.label or e.id
    local when = SS.Sim and SS.Sim.ClockText and SS.Sim.ClockText(e.t) or tostring(e.t)
    return string.format("%s  %s %s%s", when, e.me and "You:" or "Them:", label, e.ok and "" or " (went badly)")
end

function SU.RowTooltip(world, actor, row)
    local lines = { row.name .. (row.famLabel and (" (" .. row.famLabel .. ")") or "") }
    local ab, ba = row.ab, row.ba
    local function side(title, r)
        if not r then return title .. ": never met" end
        local extra = {}
        if (r.romance or 0) >= 1 then extra[#extra + 1] = "romance " .. math.floor(r.romance + 0.5) end
        if (r.rivalry or 0) >= 1 then extra[#extra + 1] = "rivalry " .. math.floor(r.rivalry + 0.5) end
        return string.format("%s: daily %d, lifetime %d%s", title, math.floor(r.daily + 0.5), math.floor(r.life + 0.5),
            #extra > 0 and (", " .. table.concat(extra, ", ")) or "")
    end
    lines[#lines + 1] = side(first(actor) .. " toward " .. first({ name = row.name }), ab)
    lines[#lines + 1] = side(first({ name = row.name }) .. " toward " .. first(actor), ba)
    local c = So.Conflict(world, actor.id, row.id)
    if c then lines[#lines + 1] = "Unresolved argument. An apology could fix it." end
    local up = So.Upset(world, row.id)
    if up then lines[#lines + 1] = first({ name = row.name }) .. " is upset (" .. tostring(up.reason) .. ")." end
    if ab and #ab.last > 0 then
        lines[#lines + 1] = "Recently:"
        for i = #ab.last, math.max(1, #ab.last - 4), -1 do lines[#lines + 1] = "  " .. historyText(world, ab.last[i]) end
    end
    return table.concat(lines, "\n")
end

local REL_ROWS, REL_H = 5, 20
function SU.CreateRelationships(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.title = K.Text(f, 11, named("inkSoft")); f.title:SetPoint("TOPLEFT", 4, -2)
    f.title:SetText("Relationships (you -> them | them -> you)")
    local holder = CreateFrame("Frame", nil, f)
    holder:SetPoint("TOPLEFT", 0, -16); holder:SetPoint("BOTTOMRIGHT", 0, 0)
    f.list = K.PagedList(holder, REL_ROWS, REL_H, function(r)
        r.name = K.Text(r, 11, named("ink")); r.name:SetPoint("LEFT", 4, 0); r.name:SetWidth(96)
        r.flags = K.Text(r, 9, named("inkSoft")); r.flags:SetPoint("LEFT", 102, 0); r.flags:SetWidth(120)
        r.out = bar(r, 70, 8); r.out:SetPoint("LEFT", 226, 3)
        r.outLife = bar(r, 70, 4); r.outLife:SetPoint("LEFT", 226, -4)
        r.inn = bar(r, 70, 8); r.inn:SetPoint("LEFT", 304, 3)
        r.innLife = bar(r, 70, 4); r.innLife:SetPoint("LEFT", 304, -4)
        r.nums = K.Text(r, 9, named("inkSoft"), "RIGHT"); r.nums:SetPoint("RIGHT", -2, 0); r.nums:SetWidth(40)
        K.Tooltip(r, function(self) return self.tip end)
    end, function(r, row)
        r.name:SetText(row.name .. (row.dead and " +" or ""))
        r.flags:SetText(row.flags)
        r.out:SetSigned(row.ab and row.ab.daily or 0); r.outLife:SetSigned(row.ab and row.ab.life or 0)
        r.inn:SetSigned(row.ba and row.ba.daily or 0); r.innLife:SetSigned(row.ba and row.ba.life or 0)
        r.nums:SetText(string.format("%d|%d", math.floor((row.ab and row.ab.life or 0) + 0.5), math.floor((row.ba and row.ba.life or 0) + 0.5)))
        r.tip = f.world and f.actor and SU.RowTooltip(f.world, f.actor, row) or row.name
        r.row = row
    end)
    f.list.frame:SetAllPoints(holder)
    f.empty = K.Text(f, 11, named("inkSoft"), "CENTER"); f.empty:SetPoint("CENTER", 0, -8)
    f.empty:SetText("No relationships yet. Go and say hello to someone.")
    return f
end

-- Cheap signature so the list is rebuilt only when something changed (refresh runs 5x a second).
-- Relationship keys are "a>b": only keys whose first or second id is exactly this person count
-- (a plain substring test would also match "ann" inside "joanna>bob").
local sigId, sigPre, sigSuf = nil, nil, nil
function SU.RelKeyHas(k, pre, suf)
    if k:find(pre, 1, true) == 1 then return true end
    local at = #k - #suf + 1
    return at > 1 and k:find(suf, at, true) == at
end
function SU.RelSignature(world, actor)
    if sigId ~= actor.id then sigId, sigPre, sigSuf = actor.id, actor.id .. ">", ">" .. actor.id end
    local s = So.Data(world)
    local sig, n = 0, 0
    for k, r in pairs(s.rel) do
        if SU.RelKeyHas(k, sigPre, sigSuf) then
            n = n + 1
            sig = sig + r.daily * 0.37 + r.life * 1.13 + (r.romance or 0) * 0.07 + #r.last
        end
    end
    return n .. ":" .. string.format("%.2f", sig)
end

function SU.RefreshRelationships(f, actor, world)
    if not actor or not world then return end
    local sig = actor.id .. "|" .. SU.theme .. "|" .. SU.RelSignature(world, actor)
    f.world, f.actor = world, actor
    if f.sig == sig then return end
    f.sig = sig
    local rows = SU.RelationshipRows(world, actor)
    f.rows = rows
    f.list:SetItems(rows)
    if #rows == 0 then f.empty:Show() else f.empty:Hide() end
end

UI.RegisterTab("relationships", { label = "Relationships", order = 20,
    create = SU.CreateRelationships, refresh = SU.RefreshRelationships })

---------------------------------------------------------------------------
-- Personality tab
---------------------------------------------------------------------------
function SU.CreatePersonality(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.dims = {}
    for n, dim in ipairs(P.DIMS) do
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(236, 20); r:SetPoint("TOPLEFT", 2, -(n - 1) * 21 - 2)
        r.ic = icon(r, 16); r.ic:SetPoint("LEFT", 0, 0)
        r.low = K.Text(r, 9, named("inkSoft"), "RIGHT"); r.low:SetPoint("LEFT", 18, 0); r.low:SetWidth(46)
        r.bar = bar(r, 100, 8); r.bar:SetPoint("LEFT", 68, 0)
        r.high = K.Text(r, 9, named("inkSoft")); r.high:SetPoint("LEFT", 172, 0); r.high:SetWidth(60)
        r.low:SetText(P.LABELS[dim].low); r.high:SetText(P.LABELS[dim].high)
        K.Tooltip(r, function(self) return self.tip end)
        r:EnableMouse(true)
        f.dims[dim] = r
    end
    f.interestTitle = K.Text(f, 10, named("inkSoft")); f.interestTitle:SetPoint("TOPLEFT", 244, -2)
    f.interestTitle:SetText("Loves / can't stand")
    f.topics = {}
    for n = 1, 6 do
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(176, 14); r:SetPoint("TOPLEFT", 244, -14 - (n - 1) * 15)
        r.ic = icon(r, 12); r.ic:SetPoint("LEFT", 0, 0)
        r.text = K.Text(r, 10, named("ink")); r.text:SetPoint("LEFT", 16, 0); r.text:SetWidth(160)
        K.Tooltip(r, function(self) return self.tip end)
        r:EnableMouse(true)
        f.topics[n] = r
    end
    f.fatigue = K.Text(f, 9, named("inkSoft")); f.fatigue:SetPoint("BOTTOMLEFT", 244, 4); f.fatigue:SetWidth(176)
    return f
end

-- Topic rows for the tab: up to 4 loves (best first) then up to 2 hates.
function SU.InterestRows(actor)
    local rows = {}
    for _, id in ipairs(P.Loves(actor)) do
        if #rows < 4 then rows[#rows + 1] = { id = id, v = P.Interest(actor, id), love = true } end
    end
    for _, id in ipairs(P.Hates(actor)) do
        if #rows < 6 then rows[#rows + 1] = { id = id, v = P.Interest(actor, id), love = false } end
    end
    return rows
end

function SU.RefreshPersonality(f, actor, world)
    if not actor then return end
    for _, dim in ipairs(P.DIMS) do
        local r = f.dims[dim]
        local v = P.Get(actor, dim)
        r.bar:SetValue(v, P.MAX)
        setIcon(r.ic, P.LABELS[dim].icon, 16)
        r.tip = P.Label(dim, v) .. " (" .. v .. "/10): " .. P.Describe(dim, v) .. "\n\n" .. P.TRADEOFFS[dim]
    end
    local rows = SU.InterestRows(actor)
    for n, r in ipairs(f.topics) do
        local row = rows[n]
        if row then
            local t = SS.Topics.byId[row.id]
            r:Show()
            setIcon(r.ic, t.icon, 12)
            r.text:SetText((row.love and "+ " or "- ") .. t.name .. " (" .. row.v .. ")")
            textColor(r.text, row.love and "ink" or "warn")
            r.tip = t.name .. ": " .. t.blurb
        else
            r:Hide()
        end
    end
    local fat = world and C.Fatigue(world, actor) or 0
    local conv = C.SessionOf(actor.id)
    f.fatigue:SetText(string.format("Social energy %d%%%s", math.floor((1 - fat) * 100 + 0.5), conv and " (chatting)" or ""))
end

UI.RegisterTab("personality", { label = "Personality", order = 25,
    create = SU.CreatePersonality, refresh = SU.RefreshPersonality })

---------------------------------------------------------------------------
-- Chatter tab: recent captions with their detail (click a row to expand it)
---------------------------------------------------------------------------
local CH_ROWS, CH_H = 5, 20
function SU.CreateChatter(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.detail = K.Text(f, 10, named("ink")); f.detail:SetPoint("BOTTOMLEFT", 4, 20); f.detail:SetWidth(416)
    f.detail:SetWordWrap(true)
    local holder = CreateFrame("Frame", nil, f)
    holder:SetPoint("TOPLEFT", 0, 0); holder:SetPoint("BOTTOMRIGHT", 0, 0)
    f.list = K.PagedList(holder, CH_ROWS, CH_H, function(r)
        r.text = K.Text(r, 10, named("ink")); r.text:SetPoint("LEFT", 4, 0); r.text:SetWidth(412)
        r:SetScript("OnClick", function(self)
            if not self.entry then return end
            f.expanded = (f.expanded ~= self.entry) and self.entry or nil
            SU.ShowDetail(f)
        end)
        K.Tooltip(r, function(self) return self.entry and self.entry.detail end)
    end, function(r, e)
        r.entry = e
        r.text:SetText(e.who .. (e.other and (" to " .. e.other) or "") .. ": \"" .. e.text .. "\"")
    end)
    f.list.frame:SetAllPoints(holder)
    f.empty = K.Text(f, 11, named("inkSoft"), "CENTER"); f.empty:SetPoint("CENTER")
    f.empty:SetText("Nothing said worth repeating yet.")
    return f
end

function SU.ShowDetail(f)
    if f.expanded then f.detail:SetText(f.expanded.detail or f.expanded.text); f.detail:Show()
    else f.detail:SetText(""); f.detail:Hide() end
end

function SU.RefreshChatter(f, actor, world)
    if not world then return end
    local s = L.Store(world)
    local last = s.log[#s.log]
    local sig = #s.log .. ":" .. tostring(last and last.t)
    if f.sig == sig then return end
    f.sig = sig
    f.items = L.Recent(world, 40)
    f.list:SetItems(f.items)
    if #f.items == 0 then f.empty:Show() else f.empty:Hide() end
    SU.ShowDetail(f)
end

UI.RegisterTab("chatter", { label = "Chatter", order = 70, create = SU.CreateChatter, refresh = SU.RefreshChatter })
