-- The end of the content: levels 99 and 100, and the town "after" (meta level scenario, public API only).

local json = require("tools.lib.json")
local Meta = require("meta.meta")
local C = require("meta.config")
local H = require("tests.meta.helper")

local function difficulty_of(n)
	local f = assert(io.open(string.format("content/levels/level_%04d.json", n), "r"))
	local d = json.decode(f:read("*a"))
	f:close()
	return d.difficulty
end

-- Plays levels up to and including `last` with the difficulty of their level files.
local function play_to(m, last, now)
	while m:level_to_play() and m:level_to_play() <= last do
		H.win(m, now, difficulty_of(m:level_to_play()), 3)
		H.claim_chests(m, now)
	end
end

describe("the end of the content", function()
	it("has stars for the whole town in the shipped levels", function()
		local m = H.new(5)
		play_to(m, C.levels.count, H.T0)
		local cost = 0
		for _, d in ipairs(H.districts().districts) do
			for _, t in ipairs(d.tasks) do cost = cost + t.cost end
		end
		assert_true(m:stars() >= cost, "stars " .. m:stars() .. " < the town's " .. cost)
	end)

	it("level 99 leads to 100, level 100 ends in all_done with its rewards paid", function()
		local m = H.new(5)
		play_to(m, 98, H.T0)
		assert_eq(m:level_to_play(), 99)
		local r99 = H.win(m, H.T0, difficulty_of(99), 3)
		assert_eq(r99.next_level, 100)
		local coins0 = m:coins()
		local r100 = H.win(m, H.T0, difficulty_of(100), 3)
		assert_eq(r100.next_level, nil, "no next level after the last")
		assert_true(r100.coins > 0)
		assert_true(m:all_done())
		assert_eq(m:level_to_play(), nil)
		-- the chest of level 100 waits and can be taken once
		local waiting = m:pending_chests()
		assert_true(#waiting >= 1)
		local found = false
		for _, w in ipairs(waiting) do if w.level_id == 100 then found = true end end
		assert_true(found, "level 100's chest waits to be taken")
		local before = m:coins()
		assert_true(before > coins0)
		H.claim_chests(m, H.T0)
		assert_eq(#m:pending_chests(), 0)
		assert_true(m:coins() > before, "the chest paid coins")
		local ok = m:claim_level_chest(100, H.T0)
		assert_false(ok, "a chest is paid once")
	end)

	it("refuses every start after the last level and stays healthy", function()
		local m = H.new(5)
		play_to(m, 100, H.T0)
		for _, id in ipairs({ 1, 50, 99, 100, 101 }) do
			local ok, why = m:can_start(id, H.T0)
			assert_false(ok)
			assert_eq(why, "all_done")
			local run, why2 = m:start_level({ id = id, difficulty = "easy" }, nil, H.T0)
			assert_false(run and true or false)
			assert_eq(why2, "all_done")
		end
		assert_eq(m:run(), nil)
		assert_same(m:streak_boosters_for_next_start(), {})
		local lives = m:lives(H.T0 + 100000)
		assert_true(lives ~= nil)
		assert_eq(m:serialize().progress.beaten, 100)
	end)

	it("lets the player finish the whole town with the stars of the levels, concerts included", function()
		local m = H.new(5)
		play_to(m, 100, H.T0)
		local chests = 0
		while m:current_district() do
			local d = m:current_district()
			local nt = m:next_task()
			assert_true(nt ~= nil)
			local res = assert(m:complete_task(nt.district, nt.id))
			if res.chest then chests = chests + 1 end
			assert_true(m:set_view(d, "concert"))
			assert_eq(m:view(d), "concert")
		end
		assert_eq(chests, #H.districts().districts)
		assert_eq(m:next_task(), nil)
		for _, d in ipairs(m:districts()) do assert_true(d.complete, d.id) end
		-- everything still saves and loads
		local t = m:serialize()
		local m2 = Meta.load(H.districts(), H.json_round_trip(t), nil, 1, H.T0)
		assert_true(m2:all_done())
		assert_eq(m2:current_district(), nil)
		assert_eq(m2:serialize().progress.beaten, 100)
	end)
end)
