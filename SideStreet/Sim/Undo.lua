-- Undo/redo for build and buy transactions (money-safe).
-- Owner: build module (see ARCHITECTURE.md, docs/modules/build.md).
--
-- A transaction is recorded AFTER its caller has applied it and charged it:
--   local tx = SS.Undo.Begin(world, "Place wall")
--   tx.ops[#tx.ops + 1] = { redo = fn, undo = fn, checkUndo = fn?, checkRedo = fn? }   -- check*() -> ok, why
--   tx.cost = 120            -- money the caller actually took (negative = money it paid out, e.g. a sale)
--   SS.Undo.Commit(world, tx)
-- Undo reverts the ops in reverse order and returns exactly tx.cost; Redo re-applies them and takes
-- tx.cost again. Money only ever moves by the recorded amount, so undo/redo can never create money:
--   * a transaction's money is settled once per direction (tx.done flips each time),
--   * redo refuses when the household cannot pay, and undoing a sale refuses when it cannot repay
--     (in free/sandbox editing too: tx.cost is what was actually moved, 0 for a free edit),
--   * the history is dropped on lot switch, load, and whenever the player returns to live mode
--     (time never passes inside build/buy, so nothing can be used and then refunded at full price),
--   * every op may carry checkUndo()/checkRedo(); if any fails nothing is changed and no money moves.
local _, SS = ...
local U = { stack = {}, redo = {}, CAP = 30, session = { spent = 0, refunded = 0, count = 0 } }
SS.Undo = U

local function fmt(v) return SS.U.fmtMoney(v) end

function U.Begin(world, label)
    return { label = label or "Edit", ops = {}, cost = 0, t = world and world.time, lotId = world and world.lot and world.lot.id, done = true }
end

-- Human-readable description for the UI: "Place 6 walls (§468)" / "Sell lamp (refund §44)".
function U.Describe(tx)
    if not tx then return "" end
    local c = tx.cost or 0
    if c > 0 then return tx.label .. " (" .. fmt(c) .. ")"
    elseif c < 0 then return tx.label .. " (refund " .. fmt(-c) .. ")" end
    return tx.label
end

local function track(cost, sign)
    local s = U.session
    local c = (cost or 0) * sign
    if c > 0 then s.spent = s.spent + c elseif c < 0 then s.refunded = s.refunded - c end
end

function U.Commit(world, tx)
    tx.done = true
    tx.lotId = tx.lotId or (world and world.lot and world.lot.id)
    U.stack[#U.stack + 1] = tx
    if #U.stack > U.CAP then table.remove(U.stack, 1) end
    U.redo = {}
    U.session.count = U.session.count + 1
    track(tx.cost, 1)
    SS.Emit("undoChanged")
    return tx
end

function U.Peek() return U.stack[#U.stack] end
function U.PeekRedo() return U.redo[#U.redo] end
function U.CanUndo() return #U.stack > 0 end
function U.CanRedo() return #U.redo > 0 end

local function checkAll(tx, field)
    for n = 1, #tx.ops do
        local op = tx.ops[n]
        local chk = op[field]
        if chk then
            local ok, why = chk()
            if not ok then return false, why or "The lot has changed since; this step can no longer be reversed." end
        end
    end
    return true
end

-- After any undo/redo: derived caches, lot version, stranded people, neighbourhood previews.
local function after(world, kind, tx)
    if SS.Build and SS.Build.AfterEdit then
        SS.Build.AfterEdit(world, kind, tx.label)
    else
        if world.lot then world.lot.version = (world.lot.version or 0) + 1 end
        if SS.World and SS.World.Rebuild then SS.World.Rebuild(world) end
        SS.Emit("lotChanged", kind, tx.label)
    end
end

-- Returns ok, why.
function U.Undo(world)
    local tx = U.stack[#U.stack]
    if not tx then return false, "Nothing to undo." end
    if tx.lotId and world.lot and tx.lotId ~= world.lot.id then U.Clear(); return false, "That change belongs to another lot." end
    -- tx.cost is what the commit really moved (0 when it was free), so undo and redo settle
    -- exactly that, whatever free/sandbox editing is now: switching it on or off between a commit
    -- and its undo never charges a free edit, never skips repaying a paid one, and the
    -- affordability checks always apply, so money can't go negative
    local cost = tx.cost or 0
    if cost < 0 and (world.money or 0) < -cost then
        return false, "Undoing this would take back " .. fmt(-cost) .. "; the household only has " .. fmt(world.money or 0) .. "."
    end
    local ok, why = checkAll(tx, "checkUndo")
    if not ok then return false, why end
    table.remove(U.stack)
    for n = #tx.ops, 1, -1 do tx.ops[n].undo() end
    tx.done = false
    if cost ~= 0 then SS.Money(world, cost, cost > 0 and "refund" or "build", "Undo: " .. tx.label) end
    track(cost, -1)
    U.redo[#U.redo + 1] = tx
    after(world, "undo", tx)
    SS.Emit("undoChanged")
    return true
end

function U.Redo(world)
    local tx = U.redo[#U.redo]
    if not tx then return false, "Nothing to redo." end
    if tx.lotId and world.lot and tx.lotId ~= world.lot.id then U.Clear(); return false, "That change belongs to another lot." end
    local cost = tx.cost or 0
    if cost > 0 and (world.money or 0) < cost then
        return false, "Redo costs " .. fmt(cost) .. "; the household only has " .. fmt(world.money or 0) .. "."
    end
    local ok, why = checkAll(tx, "checkRedo")
    if not ok then return false, why end
    table.remove(U.redo)
    for n = 1, #tx.ops do tx.ops[n].redo() end
    tx.done = true
    if cost ~= 0 then SS.Money(world, -cost, cost > 0 and "build" or "refund", "Redo: " .. tx.label) end
    track(cost, 1)
    U.stack[#U.stack + 1] = tx
    after(world, "redo", tx)
    SS.Emit("undoChanged")
    return true
end

-- Undo history never survives a lot switch, a load, or a return to live mode.
function U.Clear()
    U.stack, U.redo = {}, {}
    SS.Emit("undoChanged")
end
function U.ResetSession() U.session = { spent = 0, refunded = 0, count = 0 } end

SS.On("worldAttached", function() U.Clear(); U.ResetSession() end)
SS.On("uiMode", function(name)
    if name ~= "build" and name ~= "buy" then U.Clear(); U.ResetSession() end
end)
