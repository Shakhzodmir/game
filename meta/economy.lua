-- Wallet, ledger and reward formulas.
--
-- The wallet holds every countable resource: coins, stars and one count per
-- booster. economy.apply() is the only function that changes it. Each change
-- carries a reason tag and is appended to the ledger (an array the facade
-- hands to analytics), so every source and sink of the economy is visible.

local C = require("meta.config")
local inventory = require("meta.inventory")
local util = require("meta.util")

local M = {}

-- Wallet items in a fixed order: coins, stars, then boosters in catalogue order.
M.items = { "coins", "stars" }
for _, id in ipairs(inventory.ids) do M.items[#M.items + 1] = id end

function M.restore_wallet(t)
	t = type(t) == "table" and t or {}
	local w = {}
	for _, item in ipairs(M.items) do w[item] = util.int(t[item], 0, 0) end
	return w
end

local STATS = { "wins", "losses", "coins_earned", "coins_spent" }

function M.restore_stats(t)
	t = type(t) == "table" and t or {}
	local s = {}
	for _, k in ipairs(STATS) do s[k] = util.int(t[k], 0, 0) end
	return s
end

-- Appends one ledger entry. `balance` is the balance after the change.
function M.record(ledger, item, delta, balance, reason)
	ledger[#ledger + 1] = {
		item = item,
		delta = delta,
		balance = balance,
		reason = reason,
		flow = delta > 0 and "source" or "sink",
	}
end

-- Applies a list of changes {{item, delta}, ...} to state.wallet, all or
-- nothing. If any balance would drop below zero nothing changes and it
-- returns false, "not_enough_<item>". Zero deltas are ignored.
-- Coin changes also update state.stats.coins_earned / coins_spent.
function M.apply(state, ledger, reason, changes)
	if type(reason) ~= "string" or reason == "" then error("meta: ledger reason must be a string", 2) end
	local w = state.wallet
	local after = {}
	for _, c in ipairs(changes) do
		local item, delta = c[1], c[2]
		if w[item] == nil then error("meta: unknown wallet item '" .. tostring(item) .. "'", 2) end
		if not util.is_int(delta) then error("meta: delta for " .. item .. " must be an integer", 2) end
		local v = (after[item] or w[item]) + delta
		if v < 0 then return false, "not_enough_" .. item end
		after[item] = v
	end
	for _, c in ipairs(changes) do
		local item, delta = c[1], c[2]
		if delta ~= 0 then
			w[item] = w[item] + delta
			if item == "coins" then
				if delta > 0 then
					state.stats.coins_earned = state.stats.coins_earned + delta
				else
					state.stats.coins_spent = state.stats.coins_spent - delta
				end
			end
			M.record(ledger, item, delta, w[item], reason)
		end
	end
	return true
end

-- Turns a list of booster ids into wallet changes, one per id, in catalogue order.
function M.booster_changes(ids, sign, changes)
	changes = changes or {}
	for _, id in ipairs(inventory.ids) do
		local n = 0
		for _, x in ipairs(ids) do
			if x == id then n = n + 1 end
		end
		if n > 0 then changes[#changes + 1] = { id, sign * n } end
	end
	return changes
end

function M.check_difficulty(d)
	if not C.stars[d] then error("meta: unknown difficulty '" .. tostring(d) .. "'", 3) end
	return d
end

-- Coins and stars for a win.
function M.win_reward(difficulty, moves_at_win)
	M.check_difficulty(difficulty)
	if not util.is_int(moves_at_win) or moves_at_win < 0 then
		error("meta: moves_at_win must be a non-negative integer", 2)
	end
	local coins = C.coins.win_base * C.coins.win_mult[difficulty] + C.coins.per_move_left * moves_at_win
	return coins, C.stars[difficulty]
end

-- Boosters dealt from the chest rotation starting at 1-based position `pos`.
local function rotation_pick(pos, reached)
	local rot = C.level_chest.rotation
	for step = 0, #rot - 1 do
		local id = rot[(pos - 1 + step) % #rot + 1]
		if inventory.is_unlocked(id, reached) then return id end
	end
	return C.level_chest.fallback
end

-- Content of the chest for beating `level_id`, or nil if that level has none.
-- `reached` is the level the player moves on to (decides which boosters are
-- unlocked). Chest k deals the next boosters of the rotation after the ones
-- chests 1..k-1 dealt, so the sequence is fixed and needs no saved state.
function M.level_chest(level_id, reached)
	local cfg = C.level_chest
	if level_id % cfg.every ~= 0 then return nil end
	local k = level_id / cfg.every
	local function count(j) return j % 2 == 1 and cfg.boosters_odd or cfg.boosters_even end
	local pos = 1
	for j = 1, k - 1 do pos = pos + count(j) end
	local boosters = {}
	for i = 0, count(k) - 1 do boosters[#boosters + 1] = rotation_pick(pos + i, reached) end
	return {
		k = k,
		coins = cfg.coins_base + cfg.coins_per_k * k,
		boosters = boosters,
		infinite_minutes = k % 2 == 1 and cfg.infinite_minutes_odd or cfg.infinite_minutes_even,
	}
end

-- Price of the k-th "+5 moves" in an attempt, or nil past the limit.
function M.continue_price(k)
	return C.continues.prices[k]
end

return M
