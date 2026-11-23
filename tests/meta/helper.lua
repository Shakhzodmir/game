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

-- Claims every level chest waiting in the meta (a won level's chest is paid only when it is claimed).
function H.claim_chests(m, now)
	for _, w in ipairs(m:pending_chests()) do assert(m:claim_level_chest(w.level_id, now or H.T0)) end
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

-- The content of a newer build: the districts of this build and `n` more after the last one, shaped like the
-- districts of Part 2 (twenty levels, six tasks of 1, 4, 5, 5, 5 and 6 stars, a chest). This build knows none of the
-- added ones: it is what a rolled-back site meets in the save of a player who bought tasks there. Whatever
-- content/districts.json holds (the branches that add districts merge into this one), the added ids are never real
-- ones, so the tests count from `#H.districts().districts` and never from a district number.
H.NEWER_IDS = { "rollback_fixture_1", "rollback_fixture_2", "rollback_fixture_3", "rollback_fixture_4",
	"rollback_fixture_5", "rollback_fixture_6" }
function H.newer_districts(n)
	local d = H.districts_copy()
	for i = 1, n or 2 do
		local list = d.districts
		local tasks = {}
		for j, cost in ipairs({ 1, 4, 5, 5, 5, 6 }) do
			tasks[j] = { id = "task_" .. j, name = { en = "Task " .. j }, cost = cost, stem = "beat" }
		end
		list[#list + 1] = { id = H.NEWER_IDS[i], name = { en = H.NEWER_IDS[i] }, first = list[#list].last + 1,
			last = list[#list].last + 20, chest = { coins = 500, boosters = { "stick" } }, tasks = tasks }
	end
	return d
end

-- The ids of the `n` districts of H.newer_districts(n) that this build does not know, in order.
function H.newer_ids(n)
	local out = {}
	for i = 1, n do out[i] = H.NEWER_IDS[i] end
	return out
end

-- Runs fn() as one build of the game: the level count and the songbook stretches are global in meta/config.lua
-- (town.validate binds them, so every Meta.new / Meta.load / cloudsync.summarize does), so the content of that build
-- is bound first and the content of this build again afterwards, even when fn fails. Returns what fn returns.
function H.as_build(content, fn)
	local town = require("meta.town")
	town.validate(content)
	local res = { pcall(fn) }
	town.validate(H.districts())
	if not res[1] then error(res[2], 0) end
	return unpack(res, 2)
end

-- Buys every task of every district in order, giving the stars it lacks (test setup only).
function H.build_everything(m)
	local guard = 0
	while m:current_district() do
		guard = guard + 1
		assert(guard < 1000, "the town does not complete")
		local task = m:next_task()
		if not task.affordable then H.give(m, "stars", task.cost - m:stars()) end
		assert(m:complete_task(task.district, task.id))
	end
end

-- A player of a newer build (the content of H.newer_districts) who bought every task of the districts of this build
-- and keeps `stars` unspent. Returns two saves of that one player, both after a JSON round trip: the first as it is
-- then (a device that stopped syncing here) and the second after `bought` tasks of the newer districts were bought
-- on another device (the account's copy). This build knows none of those tasks.
function H.newer_player(newer, seed, levels, stars, bought)
	return H.as_build(newer, function()
		local m = Meta.new(newer, seed)
		H.advance_to(m, levels)
		local own = {}
		for _, d in ipairs(H.districts().districts) do own[d.id] = true end
		local function buy()
			local task = m:next_task()
			if not task.affordable then H.give(m, "stars", task.cost - m:stars()) end
			assert(m:complete_task(task.district, task.id))
		end
		while own[m:current_district()] do buy() end
		if m:stars() < stars then H.give(m, "stars", stars - m:stars()) end
		local stale = H.json_round_trip(m:serialize())
		for _ = 1, bought do buy() end
		return stale, H.json_round_trip(m:serialize())
	end)
end

-- Runs fn(...) under a budget of VM instructions instead of seconds: a hang turns into a failure at the same
-- place on every machine (a normal Meta.load takes about 5e4 instructions). Returns finished, results (the
-- pcall results). LuaJIT runs compiled traces that never fire the count hook, so its JIT is off meanwhile.
function H.within_budget(budget, fn, ...)
	local hit = false
	if jit then jit.off() end
	debug.sethook(function()
		hit = true
		error("instruction budget", 0)
	end, "", budget)
	local res = { pcall(fn, ...) }
	debug.sethook()
	if jit then jit.on() end
	return not hit, res
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
