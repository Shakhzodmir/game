-- Linear level progression, attempts, win streak and the attempt in progress.
--
-- State:
--   beaten   highest beaten level (levels are played strictly in order)
--   streak   wins in a row counted from C.streak.from_level on
--   levels   ["<id>"] = {attempts = finished attempts, fails = losses in a row}
--   run      the attempt in progress or nil:
--            {level_id, difficulty, attempt, free, moved, continues, ad_used, boosters}
--            free     = this attempt never costs a life
--            moved    = the player made the first move (or used a booster)
--            boosters = pre-level boosters paid from the inventory (refunded
--                       if the attempt is cancelled before the first move)

local C = require("meta.config")
local inventory = require("meta.inventory")
local util = require("meta.util")

local M = {}

local function restore_run(r)
	if type(r) ~= "table" or not util.is_int(r.level_id) or r.level_id < 1 then return nil end
	if not C.stars[r.difficulty] then return nil end
	local boosters = {}
	if type(r.boosters) == "table" then
		for _, id in ipairs(r.boosters) do
			local def = inventory.def(id)
			if def and def.kind == "pre" then boosters[#boosters + 1] = id end
		end
	end
	return {
		level_id = r.level_id,
		difficulty = r.difficulty,
		attempt = util.int(r.attempt, 1, 1),
		free = r.free == true,
		moved = r.moved == true,
		continues = util.int(r.continues, 0, 0, #C.continues.prices),
		ad_used = r.ad_used == true,
		boosters = boosters,
	}
end

function M.restore(t)
	t = type(t) == "table" and t or {}
	local p = {
		beaten = util.int(t.beaten, 0, 0),
		streak = util.int(t.streak, 0, 0),
		levels = {},
		run = restore_run(t.run),
	}
	if type(t.levels) == "table" then
		for key, rec in pairs(t.levels) do -- order-free: fills a map
			local id = tonumber(key)
			if type(key) == "string" and util.is_int(id) and id >= 1 and type(rec) == "table" then
				p.levels[tostring(id)] = {
					attempts = util.int(rec.attempts, 0, 0),
					fails = util.int(rec.fails, 0, 0),
				}
			end
		end
	end
	if p.run and p.run.level_id ~= p.beaten + 1 then p.run = nil end
	return p
end

-- The level the player is about to play (beaten + 1), also past the last level.
function M.reached(p)
	return p.beaten + 1
end

-- Next unbeaten level, or nil when every shipped level is beaten ("all_done").
function M.level_to_play(p)
	if p.beaten >= C.levels.count then return nil end
	return p.beaten + 1
end

-- Attempt record of a level (a fresh one if the level was never finished).
function M.record(p, level_id)
	return p.levels[tostring(level_id)] or { attempts = 0, fails = 0 }
end

-- Opens an attempt. `level` = {id, difficulty}.
function M.begin(p, level, free, paid_boosters)
	local rec = M.record(p, level.id)
	p.run = {
		level_id = level.id,
		difficulty = level.difficulty,
		attempt = rec.attempts + 1,
		free = free,
		moved = false,
		continues = 0,
		ad_used = false,
		boosters = paid_boosters,
	}
	return p.run
end

-- Closes the attempt in progress as a win or a loss. Returns the closed run
-- and the level's attempt record after the update.
function M.finish(p, won)
	local run = p.run
	p.run = nil
	local key = tostring(run.level_id)
	local rec = p.levels[key] or { attempts = 0, fails = 0 }
	p.levels[key] = rec
	rec.attempts = rec.attempts + 1
	if won then
		rec.fails = 0
		if run.level_id > p.beaten then p.beaten = run.level_id end
		if run.level_id >= C.streak.from_level then p.streak = p.streak + 1 end
	else
		rec.fails = rec.fails + 1
		p.streak = 0
	end
	return run, rec
end

-- Drops the attempt in progress without counting it.
function M.cancel(p)
	local run = p.run
	p.run = nil
	return run
end

return M
