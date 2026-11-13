-- WP-13: the number of levels and the stretch of levels of every district are data (content/districts.json:
-- `first`, `last`), not code. A batch of new levels and a new district are added by data only.

local Meta = require("meta.meta")
local C = require("meta.config")
local town = require("meta.town")
local util = require("meta.util")
local H = require("tests.meta.helper")

-- The shipped game: D districts, N levels (the tests below add fictitious districts after them).
local D = #H.districts().districts
local N = H.districts().districts[D].last

-- A copy of the shipped districts with extra districts after the last one. extra = {{id, size}, ...}.
local function extended(extra)
	local d = util.copy(H.districts())
	local first = d.districts[#d.districts].last + 1
	for _, e in ipairs(extra) do
		d.districts[#d.districts + 1] = {
			id = e.id, first = first, last = first + e.size - 1, name = { en = e.id },
			chest = { coins = 100, boosters = {} },
			tasks = { { id = e.id .. "1", cost = 1, stem = "beat" }, { id = e.id .. "2", cost = 2, stem = "bass" } },
		}
		first = first + e.size
	end
	return d
end

-- Runs fn, then puts the shipped binding back whatever happened (the config is process-wide state).
local function guarded(fn)
	local ok, err = pcall(fn)
	town.validate(H.districts())
	if not ok then error(err, 0) end
end

local function validate_error(d, needle)
	local ok, err = pcall(town.validate, d)
	town.validate(H.districts())
	assert_false(ok, "expected an error containing '" .. needle .. "'")
	assert_true(tostring(err):find(needle, 1, true) ~= nil, "error was: " .. tostring(err))
end

describe("level count and district stretches from the data", function()
	it("the shipped districts.json gives 120 levels in six stretches of 20", function()
		guarded(function()
			town.validate(H.districts())
			assert_eq(C.levels.count, 120)
			assert_eq(#C.songbook.districts, 6)
			assert_eq(N, 120)
			assert_eq(D, 6)
			for i, d in ipairs(C.songbook.districts) do
				assert_eq(d.first, (i - 1) * 20 + 1)
				assert_eq(d.last, i * 20)
				assert_eq(d.id, H.districts().districts[i].id)
			end
		end)
	end)

	it("one more district extends the count and the songbook", function()
		guarded(function()
			town.validate(extended({ { id = "bossa", size = 30 } }))
			assert_eq(C.levels.count, N + 30)
			assert_eq(#C.songbook.districts, D + 1)
			assert_same(C.songbook.districts[D + 1], { id = "bossa", first = N + 1, last = N + 30 })
			local sb = require("meta.songbook")
			assert_eq(sb.total("bossa"), 30)
			assert_eq(sb.of_level(N + 15), "bossa")
			assert_eq(select(2, sb.of_level(N + 15)), 15)
			assert_eq(sb.of_level(N + 31), nil)
		end)
	end)

	it("districts need not have 20 levels", function()
		guarded(function()
			town.validate(extended({ { id = "a", size = 7 }, { id = "b", size = 32 }, { id = "c", size = 1 } }))
			assert_eq(C.levels.count, N + 40)
			assert_eq(#C.songbook.districts, D + 3)
			assert_eq(C.songbook.districts[D + 3].last, N + 40)
		end)
	end)

	it("fixtures without first/last keep the defaults, and a data build does not leak into them", function()
		guarded(function()
			town.validate(extended({ { id = "x", size = 20 } }))
			assert_eq(C.levels.count, N + 20)
			town.validate({ districts = {
				{ id = "a", name = { en = "A" }, chest = { coins = 1, boosters = {} },
					tasks = { { id = "a1", cost = 1, stem = "beat" } } } } })
			assert_eq(C.levels.count, 100) -- the defaults of meta/config.lua: five districts of 20
			assert_eq(#C.songbook.districts, 5)
		end)
	end)

	it("rejects stretches with a gap, an overlap, a wrong start, a partial list or a district too long", function()
		local d = extended({ { id = "z", size = 10 } })
		d.districts[D + 1].first = N + 2
		validate_error(d, "gap")
		d = extended({ { id = "z", size = 10 } })
		d.districts[D + 1].first = N
		validate_error(d, "overlap")
		d = util.copy(H.districts())
		d.districts[1].first = 2
		validate_error(d, "first level is 2, expected 1")
		d = util.copy(H.districts())
		d.districts[3].last = 30
		validate_error(d, "square: last level 30 is before the first 41")
		d = util.copy(H.districts())
		d.districts[2].first = nil
		validate_error(d, "jazz: 'first' and 'last' must be whole levels")
		d = util.copy(H.districts())
		d.districts[2].first, d.districts[2].last = nil, nil
		validate_error(d, "either every district has")
		d = extended({ { id = "big", size = C.songbook.pool + 1 } })
		validate_error(d, "big:")
		d = util.copy(H.districts())
		d.districts[1].last = 20.5
		validate_error(d, "whole levels")
	end)

	it("a failed town.validate leaves the bound level count and stretches as they were", function()
		guarded(function()
			town.validate(extended({ { id = "bossa", size = 30 } }))
			assert_eq(C.levels.count, N + 30)
			local function still_130(d, why) -- "130" from the days of 100 shipped levels: N + 30 now
				local ok = pcall(town.validate, d)
				assert_false(ok, why)
				assert_eq(C.levels.count, N + 30, why)
				assert_eq(#C.songbook.districts, D + 1, why)
				assert_eq(C.songbook.districts[D + 1].last, N + 30, why)
			end
			local d = extended({ { id = "bossa", size = 30 }, { id = "next", size = 10 } })
			d.districts[D + 2].first = N + 40
			still_130(d, "a gap")
			d = extended({ { id = "bossa", size = 30 }, { id = "huge", size = C.songbook.pool + 1 } })
			still_130(d, "a district that is too long")
			d = extended({ { id = "bossa", size = 30 }, { id = "next", size = 10 } })
			d.districts[D + 2].tasks = {}
			still_130(d, "a district without tasks")
		end)
	end)

	it("rejects a repeated district id in check_districts", function()
		local ok, why = C.check_districts({ { id = "a", first = 1, last = 2 }, { id = "a", first = 3, last = 4 } })
		assert_eq(ok, nil)
		assert_true(why:find("the id repeats district 1", 1, true) ~= nil)
	end)

	it("check_districts and bind_districts report the problem and change nothing", function()
		guarded(function()
			local ok, why = C.bind_districts({ { id = "a", first = 2, last = 5 } })
			assert_false(ok)
			assert_true(why:find("expected 1", 1, true) ~= nil)
			assert_eq(C.levels.count, N)
			assert_eq(select(2, C.check_districts({})), "no districts")
			assert_true(C.bind_districts({ { id = "only", first = 1, last = 3 } }))
			assert_eq(C.levels.count, 3)
			assert_true(C.bind_districts(nil))
			assert_eq(C.levels.count, 100) -- the defaults of meta/config.lua
		end)
	end)
end)

describe("a batch of new levels and a new district added by data", function()
	local function difficulty_of(n)
		return n % 20 == 0 and "hard" or "easy"
	end
	local function play_to(m, last, now)
		while m:level_to_play() and m:level_to_play() <= last do
			H.win(m, now, difficulty_of(m:level_to_play()), 3)
			H.claim_chests(m, now)
		end
	end

	it("plays 1..N+30 through the meta: the end is level N+30, not the shipped last level N", function()
		guarded(function()
			local m = Meta.new(extended({ { id = "bossa", size = 30 } }), 5)
			play_to(m, N, H.T0)
			assert_false(m:all_done(), "the shipped last level is not the end of a build with 30 more")
			assert_eq(m:level_to_play(), N + 1)
			play_to(m, N + 29, H.T0)
			assert_eq(m:level_to_play(), N + 30)
			local r = H.win(m, H.T0, "easy", 3)
			assert_eq(r.next_level, nil)
			assert_true(m:all_done())
			local ok, why = m:can_start(N + 30, H.T0)
			assert_false(ok)
			assert_eq(why, "all_done")
			assert_eq(m:serialize().progress.beaten, N + 30)
		end)
	end)

	it("pays a level chest every tenth level of the new batch, once", function()
		guarded(function()
			local m = Meta.new(extended({ { id = "bossa", size = 30 } }), 5)
			play_to(m, N + 19, H.T0)
			local waiting = {}
			H.win(m, H.T0, "easy", 3)  -- level N + 20
			for _, w in ipairs(m:pending_chests()) do waiting[w.level_id] = true end
			assert_true(waiting[N + 20], "the chest of level N + 20 waits")
			local before = m:coins()
			H.claim_chests(m, H.T0)
			assert_true(m:coins() > before)
			assert_false(m:claim_level_chest(N + 20, H.T0), "paid once")
		end)
	end)

	it("the songbook of the new district fills level by level and is ready at its last level", function()
		guarded(function()
			local m = Meta.new(extended({ { id = "bossa", size = 30 } }), 5)
			play_to(m, N, H.T0)
			for _, d in ipairs(H.districts().districts) do m:songbook_seen(d.id) end
			assert_eq(m:songbook_pending(), nil)
			play_to(m, N + 15, H.T0)
			local song = m:song_of("bossa")
			assert_eq(#song.lines, 15)
			assert_false(song.ready)
			play_to(m, N + 30, H.T0)
			song = m:song_of("bossa")
			assert_eq(#song.lines, 30)
			assert_true(song.ready)
			assert_eq(m:songbook_pending(), "bossa")
		end)
	end)

	it("a save from the 100-level build (five districts) continues at level 101 in the shipped build, nothing lost", function()
		guarded(function()
			local five = util.copy(H.districts())
			while #five.districts > 5 do five.districts[#five.districts] = nil end
			assert_eq(five.districts[5].last, 100)
			local old = Meta.new(five, 5)
			play_to(old, 100, H.T0)
			assert_true(old:all_done())
			local saved = H.json_round_trip(old:serialize())
			local coins, stars = old:coins(), old:stars()
			local m = Meta.load(H.districts(), saved, nil, 5, H.T0)
			assert_false(m:all_done())
			assert_eq(m:level_to_play(), 101)
			assert_eq(m:serialize().progress.beaten, 100)
			assert_true(m:coins() >= coins, "coins never shrink")
			assert_true(m:stars() >= stars, "stars never shrink")
			local sixth = H.districts().districts[6]
			assert_eq(m:song_of(sixth.id).total, sixth.last - sixth.first + 1)
			assert_true(m:can_start(101, H.T0))
		end)
	end)

	it("a save from the shipped build continues at the next level in a build with 30 more, nothing lost", function()
		guarded(function()
			local old = Meta.new(H.districts(), 5)
			play_to(old, N, H.T0)
			assert_true(old:all_done())
			local saved = H.json_round_trip(old:serialize())
			local coins, stars = old:coins(), old:stars()
			local m = Meta.load(extended({ { id = "bossa", size = 30 } }), saved, nil, 5, H.T0)
			assert_false(m:all_done())
			assert_eq(m:level_to_play(), N + 1)
			assert_eq(m:serialize().progress.beaten, N)
			assert_true(m:coins() >= coins, "coins never shrink")
			assert_true(m:stars() >= stars, "stars never shrink")
			assert_eq(m:song_of("bossa").total, 30)
			local ok = m:can_start(N + 1, H.T0)
			assert_true(ok)
		end)
	end)

	it("a save from a build with MORE levels is kept whole in a build with fewer (progress never shrinks)", function()
		guarded(function()
			local big = Meta.new(extended({ { id = "bossa", size = 30 } }), 5)
			play_to(big, N + 30, H.T0)
			local saved = H.json_round_trip(big:serialize())
			local small = Meta.load(H.districts(), saved, nil, 5, H.T0)
			assert_eq(C.levels.count, N)
			assert_true(small:all_done())
			assert_eq(small:level_to_play(), nil)
			assert_eq(small:serialize().progress.beaten, N + 30, "beaten is not cut to the levels this build has")
			assert_true(small:coins() >= big:coins())
			-- and loading it again in the bigger build continues where it ended
			local again = Meta.load(extended({ { id = "bossa", size = 30 } }), small:serialize(), nil, 5, H.T0)
			assert_true(again:all_done())
			assert_eq(again:serialize().progress.beaten, N + 30)
		end)
	end)

	it("the town gains a district: its tasks, stars and chest work like the shipped ones", function()
		guarded(function()
			local m = Meta.new(extended({ { id = "bossa", size = 30 } }), 5)
			play_to(m, N + 30, H.T0)
			H.give(m, "stars", 1000)
			local chests = 0
			while m:current_district() do
				local nt = m:next_task()
				local res = assert(m:complete_task(nt.district, nt.id))
				if res.chest then chests = chests + 1 end
			end
			assert_eq(chests, D + 1)
			assert_eq(m:current_district(), nil)
		end)
	end)
end)
