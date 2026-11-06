-- Level records: best stars and best score per level, and the super stars of concert levels.
--
-- State (three NEW top-level fields of the save, see the header of meta/save.lua):
--   level_stars   ["<id>"] = best stars 1..3 of a level the player won
--   level_scores  ["<id>"] = best score of a win
--   super_stars   {levels = {["<id>"] = best stars 1..3 of a concert level}, spent = super stars spent}
--
-- A record never goes down: gain() only raises it. A save from before the stars by score has no records:
-- a level at or below `beaten` without one is worth what the old rule paid, C.stars[difficulty]
-- (legacy()), so nothing the player owns shrinks.

local C = require("meta.config")
local progress = require("meta.progress")
local util = require("meta.util")

local M = {}

local function restore_map(t, hi)
	local out = {}
	if type(t) == "table" then
		for key, v in pairs(t) do -- order-free: each key maps to its own level
			if progress.is_level_key(key) and type(v) == "number" then
				local n = util.int(v, 0, 0, hi)
				if n >= 1 then out[key] = n end
			end
		end
	end
	return out
end

function M.restore_stars(t)
	return restore_map(t, 3)
end

function M.restore_scores(t)
	return restore_map(t, 2 ^ 31)
end

function M.restore_super(t)
	t = type(t) == "table" and t or {}
	return { levels = restore_map(t.levels, 3), spent = util.int(t.spent, 0, 0) }
end

-- Stars the old rule paid for a win on a level of this difficulty.
function M.legacy(difficulty)
	return C.stars[difficulty] or 0
end

-- Best stars of a level: the record, else the legacy stars of a beaten level whose difficulty is known,
-- else 0.
function M.best(state, level_id, difficulty)
	local n = state.level_stars[tostring(level_id)]
	if n then return n end
	if difficulty and level_id <= state.progress.beaten then return M.legacy(difficulty) end
	return 0
end

-- Raises the records after a win. Returns {gained = stars new to the wallet, best, super_gained,
-- new_best_score}.
function M.gain(state, level_id, difficulty, stars, score, concert)
	local key = tostring(level_id)
	local prev = M.best(state, level_id, difficulty)
	local best = math.max(prev, stars)
	state.level_stars[key] = best
	local new_best = false
	if score and score > (state.level_scores[key] or 0) then
		state.level_scores[key] = math.min(score, 2 ^ 31)
		new_best = true
	end
	local super_gained = 0
	if concert then
		local sp = state.super_stars.levels
		local before = sp[key] or 0
		if stars > before then
			sp[key] = stars
			super_gained = stars - before
		end
	end
	return { gained = best - prev, best = best, super_gained = super_gained, new_best_score = new_best }
end

-- Super stars owned: earned minus spent.
function M.super_balance(state)
	local sum = 0
	for _, n in pairs(state.super_stars.levels) do sum = sum + n end -- order-free: a sum
	return math.max(0, sum - state.super_stars.spent), sum
end

return M
