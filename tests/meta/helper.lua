-- Shared fixtures for the meta tests (not a test file itself).

local json = require("tools.lib.json")
local Meta = require("meta.meta")
local economy = require("meta.economy")

local H = {}

H.T0 = 1700000000 -- a fixed "now" in seconds

local districts
function H.districts()
	if not districts then
		local f = assert(io.open("content/districts.json", "r"))
		districts = json.decode(f:read("*a"))
		f:close()
	end
	return districts
end

function H.new(seed)
	return Meta.new(H.districts(), seed or 42)
end

-- Starts the next level and wins it.
function H.win(m, now, difficulty, moves_at_win)
	local id = m:level_to_play()
	assert(m:start_level({ id = id, difficulty = difficulty or "easy" }, nil, now or H.T0))
	return m:finish_level({ won = true, level_id = id, moves_at_win = moves_at_win or 0 }, now or H.T0)
end

-- Starts the next level, makes a move and loses it.
function H.lose(m, now, quit)
	local id = m:level_to_play()
	assert(m:start_level({ id = id, difficulty = "easy" }, nil, now or H.T0))
	m:note_move()
	return m:finish_level({ won = false, level_id = id, quit_after_first_move = quit or false }, now or H.T0)
end

-- Wins easy levels until `level` is the next one to play.
function H.advance_to(m, level, now)
	while m:level_to_play() < level do H.win(m, now) end
end

-- Puts resources into the wallet directly (test setup only).
function H.give(m, item, n)
	assert(economy.apply(m.s, m.ledger, "test", { { item, n } }))
end

-- Sum of ledger deltas for an item, optionally only for one reason.
function H.ledger_sum(entries, item, reason)
	local sum = 0
	for _, e in ipairs(entries) do
		if e.item == item and (reason == nil or e.reason == reason) then sum = sum + e.delta end
	end
	return sum
end

-- Runs fn with booster unlock levels changed ({[id] = level}), as a config
-- update would, and restores them afterwards even if fn fails.
function H.with_unlocks(levels, fn)
	local C = require("meta.config")
	local old = {}
	for _, def in ipairs(C.boosters) do
		old[def.id] = def.unlock
		if levels[def.id] then def.unlock = levels[def.id] end
	end
	local ok, err = pcall(fn)
	for _, def in ipairs(C.boosters) do def.unlock = old[def.id] end
	if not ok then error(err, 0) end
end

-- A copy of content/districts.json to edit in a test.
function H.districts_copy()
	return json.decode(json.encode(H.districts()))
end

function H.json_round_trip(t)
	return json.decode(json.encode(t))
end

-- Difficulty sawtooth of plan v1 (4 easy, 3 medium, 2 hard, 1 super hard per
-- ten levels; 1..20 easy; 21..50 without super hard). A test fixture only.
local BLOCK = { "easy", "medium", "easy", "hard", "easy", "medium", "super_hard", "easy", "medium", "hard" }
function H.sawtooth(level)
	if level <= 20 then return "easy" end
	local d = BLOCK[(level - 1) % 10 + 1]
	if level <= 50 and d == "super_hard" then return "medium" end
	return d
end

return H
