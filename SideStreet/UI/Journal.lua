-- SideStreet household story journal.
--
-- The journal is the household's own list (household.journal, saved with the game), written by
-- every module through SS.Actions.Journal(world, text) or, with participants, SS.Journal.Add.
-- It is bounded (J.CAP entries; the oldest are let go) and holds data only.
--
-- Each entry is { t, text } and gains, once, a few derived fields (still plain data):
--   who  = { rid, ... }   participants (given by the writer, else the residents named in the text)
--   kind = "fire" | ...   a story category for the symbol shown beside it
--   lot, x, y, level      a scene bookmark: where the first participant was when it was written.
--                         SS.Journal.Add records it at once. SS.Actions.Journal (household-core)
--                         stores only { t, text }, so the shell wraps it (J.WrapWriter) and
--                         enriches the entry the moment it is written; entries that bypass the
--                         wrapper (household-core's own local calls) are enriched by the shell's
--                         system at the start of the next simulation step, before anyone moves
--                         again. Entries found unenriched when a household is attached were
--                         written while it was not being played: they get lot = false (no place),
--                         never a made-up spot.
-- The panel shows a portrait of the first participant as the entry's "bookmark" picture (the
-- addon cannot take or store screenshots) and can centre the view on the bookmarked spot.
local _, SS = ...
local UI = SS.UI
local K = UI.Kit
local J = SS.Journal or {}
SS.Journal = J

J.CAP = 40            -- same bound as the executor's journal writer
J.WHO_CAP = 4
J.KINDS = {
    { "fire", "Fire", "!!", { "fire", "burn", "smoke", "flames" } },
    { "death", "Loss", "+", { "died", "passed away", "ghost", "memorial", "grave", "mourn" } },
    { "family", "Family", "&", { "baby", "born", "birthday", "grew up", "child", "adopt", "pet", "puppy", "kitten" } },
    { "career", "Work", "$", { "promot", "demot", "job", "work", "fired", "shift", "school", "report card", "grade" } },
    { "skill", "Skill", "^", { "skill", "level", "talent" } },
    { "social", "People", "*", { "friend", "love", "kiss", "argu", "fight", "married", "date", "relationship", "enemy", "hug" } },
    { "party", "Party", "#", { "party", "guest", "celebrat" } },
    { "money", "Money", "\194\167", { "\194\167", "bill", "paid", "bought", "sold", "purchase", "funds", "repo" } },
    { "mishap", "Mishap", "~", { "accident", "fell asleep", "broke", "puddle", "collapsed", "passed out", "burglar", "flood" } },
    { "home", "Home", "=", { "moved", "house", "built", "room", "garden" } },
}
J.KIND_BY_ID = {}
for _, k in ipairs(J.KINDS) do J.KIND_BY_ID[k[1]] = k end

local function world() return SS.Sim.world end

function J.Classify(text)
    local low = tostring(text or ""):lower()
    for _, k in ipairs(J.KINDS) do
        for _, word in ipairs(k[4]) do
            if low:find(word, 1, true) then return k[1] end
        end
    end
    return "story"
end

-- Residents named in the text: full names first, then unambiguous first names, household
-- members before others. Sorted ids keep it deterministic.
function J.FindNames(w, text)
    local out = {}
    if type(text) ~= "string" or not w or not w.root then return out end
    local res = w.root.residents
    local ids = {}
    for id in pairs(res) do ids[#ids + 1] = id end
    table.sort(ids)
    local hh = w.household
    local members = {}
    if hh then for _, rid in ipairs(hh.members or {}) do members[rid] = true end end
    table.sort(ids, function(a, b)
        local ma, mb = members[a] and 0 or 1, members[b] and 0 or 1
        if ma ~= mb then return ma < mb end
        return a < b
    end)
    local seen = {}
    for _, id in ipairs(ids) do
        local r = res[id]
        if r.name and #r.name > 2 and text:find(r.name, 1, true) and #out < J.WHO_CAP then out[#out + 1] = id; seen[id] = true end
    end
    local firstCount = {}
    for _, id in ipairs(ids) do
        local first = res[id].name and res[id].name:match("^(%S+)")
        if first then firstCount[first] = (firstCount[first] or 0) + 1 end
    end
    for _, id in ipairs(ids) do
        local r = res[id]
        local first = r.name and r.name:match("^(%S+)")
        if not seen[id] and first and #first > 2 and #out < J.WHO_CAP and (firstCount[first] == 1 or members[id]) then
            local s, e = text:find(first, 1, true)
            -- whole word only
            if s and not text:sub(s - 1, s - 1):match("%w") and not text:sub(e + 1, e + 1):match("%w") then
                out[#out + 1] = id
                seen[id] = true
            end
        end
    end
    return out
end

-- Fill the derived fields of one entry. Each field is filled only when missing, so an entry that
-- arrives with some of them (a kind from the writer, participants from J.Add) keeps them. `lot`
-- is the marker: set once, to the lot id, or to false when noPlace says the place is unknown.
function J.Enrich(w, e, noPlace)
    if type(e) ~= "table" or e.lot ~= nil then return e end
    if type(e.who) ~= "table" then e.who = J.FindNames(w, e.text) end
    for n = #e.who, J.WHO_CAP + 1, -1 do e.who[n] = nil end
    if type(e.kind) ~= "string" then e.kind = J.Classify(e.text) end
    if noPlace then
        e.lot = false
        return e
    end
    e.lot = w.lot and w.lot.id or false
    local first = e.who[1] and w.actors and w.actors[e.who[1]]
    if first and e.x == nil then e.x, e.y, e.level = first.x, first.y, first.level or 0 end
    return e
end

-- Enrich new entries. Cheap when nothing is new: entries are only ever appended, so an unchanged
-- newest entry means nothing was written since the last call (one length read, one comparison,
-- no allocation), and it can run every simulation step. Otherwise every entry without a `lot` is
-- filled (at most J.CAP). Returns how many entries it filled.
local seenLast = setmetatable({}, { __mode = "k" })
function J.EnrichAll(w, noPlace)
    w = w or world()
    local list = w and w.journal
    if type(list) ~= "table" then return 0 end
    local n = #list
    local newest = list[n]
    if seenLast[list] == newest and (type(newest) ~= "table" or newest.lot ~= nil) then return 0 end
    local filled = 0
    for i = 1, n do
        local e = list[i]
        if type(e) == "table" and e.lot == nil then
            J.Enrich(w, e, noPlace)
            filled = filled + 1
        end
    end
    seenLast[list] = newest
    J.enriched = (J.enriched or 0) + filled
    return filled
end

-- Enrich on write: SS.Actions.Journal(world, text, ...) is wrapped once so the entry it appends is
-- enriched immediately (participants, category and the participant's position at that moment)
-- and the open panel hears the `journal` event. Idempotent; keeps every return value; if
-- household-core forwards to SS.Journal.Add (the request in docs/requests/ui-shell.md §1) the
-- wrapper finds the entry already done and does nothing.
function J.WrapWriter()
    local A = SS.Actions
    if type(A) ~= "table" or type(A.Journal) ~= "function" or A.Journal == J.writer then return false end
    local orig = A.Journal
    local function after(w, ...)
        if type(w) == "table" and w == world() and type(w.journal) == "table" then
            local n = #w.journal
            if J.EnrichAll(w) > 0 and SS.Emit then SS.Emit("journal", w, w.journal[n]) end
        end
        return ...
    end
    J.writer = function(w, ...) return after(w, orig(w, ...)) end
    J.writerOrig = orig
    A.Journal = J.writer
    return true
end
J.WrapWriter()

-- Write a notable event with participants: SS.Journal.Add(world, text, who, kind).
-- who: an actor, an id, or a list of either (household-core's SS.Actions.Journal forwards its own
-- optional `who` here). When it names nobody (nil, or nothing usable), the participants are the
-- residents named in the text, exactly as for a plain SS.Actions.Journal entry.
function J.Add(w, text, who, kind)
    w = w or world()
    if not w or type(text) ~= "string" or text == "" then return nil end
    local list = w.journal
    if type(list) ~= "table" then return nil end
    local ids = {}
    if type(who) == "string" then ids[1] = who
    elseif type(who) == "table" and type(who.id) == "string" then ids[1] = who.id
    elseif type(who) == "table" then
        for _, x in ipairs(who) do
            local id = type(x) == "table" and x.id or x
            if type(id) == "string" and #ids < J.WHO_CAP then ids[#ids + 1] = id end
        end
    end
    local e = { t = w.time, text = text, who = ids[1] and ids or nil }
    if type(kind) == "string" then e.kind = kind end
    list[#list + 1] = e
    while #list > J.CAP do table.remove(list, 1) end
    J.Enrich(w, e)
    SS.Emit("journal", w, e)
    return e
end

-- Entries newest first, optionally only those involving `rid`.
function J.Entries(w, rid)
    w = w or world()
    local out = {}
    local list = w and w.journal
    if type(list) ~= "table" then return out end
    J.EnrichAll(w)
    for n = #list, 1, -1 do
        local e = list[n]
        if not rid then out[#out + 1] = e
        else
            for _, id in ipairs(e.who or {}) do if id == rid then out[#out + 1] = e; break end end
        end
    end
    return out
end

-- Entries that bypassed the wrapper are enriched at the start of the next simulation step
-- (before anyone moves again) and when a lot session ends. On attach the list is kept inside its
-- bound, and entries written while the household was not being played get no place.
SS.Sim.Register({ name = "shell_journal", order = 95,
    tick = function(w)
        if J.EnrichAll(w) > 0 and SS.Emit then SS.Emit("journal", w, w.journal[#w.journal]) end
    end,
    detach = function(w) J.EnrichAll(w) end,
    attach = function(w)
        local list = w.journal
        if type(list) == "table" then while #list > J.CAP do table.remove(list, 1) end end
        J.EnrichAll(w, true)
    end,
})

if SS.Save and SS.Save.RegisterValidator then
    SS.Save.RegisterValidator(function(root, problems)
        for _, hh in pairs(root.households or {}) do
            if type(hh) == "table" and type(hh.journal) == "table" then
                local keep = {}
                for _, e in ipairs(hh.journal) do
                    if type(e) == "table" and type(e.text) == "string" then
                        if e.who ~= nil and type(e.who) ~= "table" then e.who = nil end
                        if type(e.who) == "table" then
                            local ids = {}
                            for _, id in ipairs(e.who) do if type(id) == "string" and #ids < J.WHO_CAP then ids[#ids + 1] = id end end
                            e.who = ids
                        end
                        keep[#keep + 1] = e
                    end
                end
                while #keep > J.CAP do table.remove(keep, 1) end
                if #keep ~= #hh.journal then problems[#problems + 1] = "journal of " .. tostring(hh.id) .. " tidied" end
                hh.journal = keep
            end
        end
        return true
    end)
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
J.ROWS = 5
J.ROW_H = 56

local function shortName(w, rid)
    local r = w and w.root.residents[rid]
    if not r then return "someone" end
    return r.name and (r.name:match("^(%S+)") or r.name) or rid
end

function J.Create()
    if J.frame then return J.frame end
    local p = K.Panel(UI.frame, "Household story", 540, 420, { close = true, movable = true, strata = "DIALOG", level = 75 })
    p:SetPoint("CENTER", -30, 10)
    J.frame = p
    p.filterBtns = {}
    p.head = K.Text(p.body, 10, "inkSoft"); p.head:SetPoint("TOPLEFT", 0, -26); p.head:SetPoint("TOPRIGHT", 0, -26)
    p.list = K.PagedList(p.body, J.ROWS, J.ROW_H, function(r)
        r.port = K.Portrait(r, 44)
        r.port:SetPoint("LEFT", 2, 0)
        r.port:EnableMouse(false)
        r.glyph = K.Text(r, 14, "accentDeep", "CENTER"); r.glyph:SetPoint("CENTER", r.port, "CENTER", 0, 0); r.glyph:SetWidth(40)
        r.kindIcon = r:CreateTexture(nil, "OVERLAY"); r.kindIcon:SetPoint("CENTER", r.port, "CENTER", 0, 0); r.kindIcon:Hide()
        r.when = K.Text(r, 10, "inkSoft"); r.when:SetPoint("TOPLEFT", r.port, "TOPRIGHT", 8, -1); r.when:SetWidth(300)
        r.text = K.Text(r, 11, "ink"); r.text:SetPoint("TOPLEFT", r.when, "BOTTOMLEFT", 0, -2); r.text:SetPoint("RIGHT", r, "RIGHT", -60, 0)
        r.text:SetJustifyV("TOP")
        r.who = K.Text(r, 9, "inkSoft"); r.who:SetPoint("BOTTOMLEFT", r.port, "BOTTOMRIGHT", 8, 1); r.who:SetWidth(300)
        r.show = K.Button(r, "Show", 50, 18, function(self) J.ShowScene(self:GetParent().entry) end,
            "Centre the view on where this happened (the scene bookmark)")
        r.show:SetPoint("RIGHT", -2, 0)
        r.line = K.Tex(r, "BACKGROUND", "panelDark"); r.line:SetPoint("BOTTOMLEFT", 0, 0); r.line:SetPoint("BOTTOMRIGHT", 0, 0); r.line:SetHeight(1)
    end, function(r, e) J.FillRow(r, e) end)
    p.list.frame:SetPoint("TOPLEFT", 0, -42); p.list.frame:SetPoint("BOTTOMRIGHT", 0, 16)
    p.foot = K.Text(p.body, 9, "inkSoft"); p.foot:SetPoint("BOTTOMLEFT", 0, -4); p.foot:SetPoint("BOTTOMRIGHT", 0, -4)
    p.foot:SetText("The journal keeps the latest " .. J.CAP .. " stories; older ones are let go. A portrait marks who each story is about.")
    UI.RegisterFloating(p)
    p:Hide()
    return p
end

function J.FillRow(r, e)
    local w = world()
    r.entry = e
    local k = J.KIND_BY_ID[e.kind or "story"]
    r.when:SetText((UI.ClockText and UI.ClockText(e.t or 0) or tostring(e.t)) .. "   " .. (k and k[2] or "Story"))
    r.text:SetText(e.text or "")
    local person = e.who and e.who[1] and w and w.root.residents[e.who[1]]
    if person then
        K.DrawPortrait(r.port, person)
        r.glyph:SetText("")
        r.kindIcon:Hide()
    else
        K.DrawPortrait(r.port, nil)
        r.glyph:SetText(k and k[3] or "*")
        K.IconOrGlyph(r.kindIcon, r.glyph, "journal_" .. (k and k[1] or "story"), 28)
    end
    local names = {}
    for _, id in ipairs(e.who or {}) do names[#names + 1] = shortName(w, id) end
    r.who:SetText(#names > 0 and ("With " .. table.concat(names, ", ")) or "")
    local here = w and e.lot == w.lot.id and e.x
    r.show:SetUsable(here and true or false, e.lot and w and e.lot ~= w.lot.id and "That happened on another lot." or "No place was recorded for this story.")
end

function J.ShowScene(e)
    local w = world()
    if not e or not w then return end
    if e.lot ~= w.lot.id or not e.x then
        UI.Notice(e.lot and e.lot ~= w.lot.id and "That happened on another lot." or "No place was recorded for this story.")
        return
    end
    if UI.CenterOn then UI.CenterOn(e.x, e.y, e.level or 0) end
end

function J.Refresh()
    local p = J.frame
    if not p then return end
    local w = world()
    -- filter buttons: everyone + household members (at most 8)
    local members = UI.Members and UI.Members() or {}
    local defs = { { id = false, label = "Everyone" } }
    for _, r in ipairs(members) do defs[#defs + 1] = { id = r.id, label = r.name:match("^(%S+)") or r.name } end
    for _, b in ipairs(p.filterBtns) do b:Hide() end
    local prev
    for n, d in ipairs(defs) do
        local b = p.filterBtns[n]
        if not b then
            b = K.Button(p.body, "", 60, 18, function(self) J.filter = self.rid or nil; J.Refresh() end, function(self)
                return self.rid and ("Only stories involving " .. self.fullName) or "Every story"
            end)
            p.filterBtns[n] = b
        end
        b.rid = d.id or nil
        b.fullName = d.id and w and w.root.residents[d.id] and w.root.residents[d.id].name or ""
        b:SetLabel(d.label)
        b:ClearAllPoints()
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 3, 0) else b:SetPoint("TOPLEFT", 0, 0) end
        b:SetActive((J.filter or false) == (d.id or false))
        b:Show()
        prev = b
    end
    local items = J.Entries(w, J.filter)
    local total = (w and type(w.journal) == "table") and #w.journal or 0
    if not w then p.head:SetText("No game is running.")
    elseif #items == 0 then p.head:SetText(J.filter and "No stories about this person yet." or "Nothing notable has happened yet. Stories appear here as life happens.")
    else p.head:SetText(string.format("%d %s%s, newest first.", #items, #items == 1 and "story" or "stories", J.filter and "" or (" of " .. J.CAP .. " kept"))) end
    p.list:SetItems(items)
    J.shownCount = total
end

function UI.ToggleJournal()
    local p = J.Create()
    if p:IsShown() then p:Hide(); return end
    J.Refresh()
    p:Show()
end

SS.On("journal", function() if J.frame and J.frame:IsShown() then J.Refresh() end end)
SS.On("worldAttached", function() J.filter = nil; if J.frame and J.frame:IsShown() then J.Refresh() end end)
-- new entries written while the panel is open (checked twice a second, only when open)
local acc = 0
if UI.OnEveryFrame then
    UI.OnEveryFrame(function(el, w)
        if not J.frame or not J.frame:IsShown() then return end
        acc = acc + el
        if acc < 0.5 then return end
        acc = 0
        local n = (w and type(w.journal) == "table") and #w.journal or 0
        local last = w and type(w.journal) == "table" and w.journal[n]
        if n ~= J.shownCount or (type(last) == "table" and last.lot == nil) then J.Refresh() end
    end)
end
