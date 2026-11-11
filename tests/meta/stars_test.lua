-- Stars by score: thresholds, records that never go down, replays, super stars, the old saves.

local Meta = require("meta.meta")
local save = require("meta.save")
local stars = require("meta.stars")
local H = require("tests.meta.helper")

local T = H.T0

local function win(m, score, st, opts)
	local id = m:level_to_play()
	assert(m:start_level({ id = id, difficulty = (opts and opts.difficulty) or "easy" }, nil, T))
	return m:finish_level({ won = true, level_id = id, moves_at_win = 0, stars = st, score = score,
		concert = opts and opts.concert }, T)
end

local function reload(m)
	local back = Meta.load(H.districts(), H.json_round_trip(m:serialize()), nil, 7, T)
	return back
end

describe("stars from the score (meta/stars.lua)", function()
	local t = { 1000, 2000, 3000 }

	it("gives 1 star for any win and 2 and 3 from the thresholds", function()
		assert_eq(stars.rate(t, 0), 1)
		assert_eq(stars.rate(t, 999), 1)
		assert_eq(stars.rate(t, 1999), 1)
		assert_eq(stars.rate(t, 2000), 2)
		assert_eq(stars.rate(t, 2999), 2)
		assert_eq(stars.rate(t, 3000), 3)
		assert_eq(stars.rate(t, 10 ^ 9), 3)
		assert_eq(stars.rate(nil, 5000), 1, "no thresholds: 1 star")
	end)

	it("says where the score stands on the scale", function()
		local p = stars.progress(t, 500)
		assert_eq(p.stars, 1)
		assert_eq(p.to, 2000)
		assert_true(p.frac > 0.24 and p.frac < 0.26)
		p = stars.progress(t, 2500)
		assert_eq(p.stars, 2)
		assert_eq(p.from, 2000)
		assert_eq(p.to, 3000)
		assert_true(p.frac > 0.49 and p.frac < 0.51)
		p = stars.progress(t, 4000)
		assert_eq(p.stars, 3)
		assert_eq(p.to, nil)
		assert_eq(p.frac, 1)
	end)

	it("checks the shape of an entry", function()
		assert_same(stars.check_entry({ kind = "normal", t = { 1, 2, 3 } }), {})
		assert_true(#stars.check_entry({ kind = "normal", t = { 3, 2, 1 } }) > 0, "descending")
		assert_true(#stars.check_entry({ kind = "normal", t = { 1, 1, 3 } }) > 0, "equal")
		assert_true(#stars.check_entry({ kind = "normal", t = { 1, 2 } }) > 0, "two thresholds")
		assert_true(#stars.check_entry({ kind = "boss", t = { 1, 2, 3 } }) > 0, "unknown kind")
		assert_true(#stars.check_entry({ kind = "normal", t = { 0, 2, 3 } }) > 0, "zero")
		assert_true(#stars.check_entry({ kind = "normal", t = { 1.5, 2, 3 } }) > 0, "fraction")
	end)
end)

describe("star records in the meta", function()
	it("pays the stars of the score into the wallet, once per new star", function()
		local m = H.new()
		local r = win(m, 100, 2)
		assert_eq(r.stars, 2)
		assert_eq(r.gained, 2)
		assert_eq(r.best, 2)
		assert_false(r.new_best_score, "the first win of a level is not a record to cheer")
		assert_eq(m:stars(), 2)
		assert_eq(m:level_stars(1), 2)
		assert_eq(m:level_score(1), 100)
	end)

	it("pays by the old rule when the caller sends no stars", function()
		local m = H.new()
		H.advance_to(m, 20)
		local r = H.win(m, T, "super_hard")
		assert_eq(r.stars, 3)
		assert_eq(r.gained, 3)
	end)

	it("raises a record on a replay and never lowers it", function()
		local m = H.new()
		win(m, 100, 2)
		assert_eq(m:stars(), 2)
		local r = m:record_replay({ level_id = 1, difficulty = "easy", stars = 1, score = 50 })
		assert_eq(r.gained, 0)
		assert_eq(r.best, 2)
		assert_eq(m:stars(), 2)
		assert_eq(m:level_score(1), 100, "a lower score is not a record")
		r = m:record_replay({ level_id = 1, difficulty = "easy", stars = 3, score = 900 })
		assert_eq(r.gained, 1)
		assert_eq(r.best, 3)
		assert_true(r.new_best_score)
		assert_eq(m:stars(), 3)
		r = m:record_replay({ level_id = 1, difficulty = "easy", stars = 2, score = 10 })
		assert_eq(r.gained, 0)
		assert_eq(m:level_stars(1), 3)
		assert_eq(m:stars(), 3)
	end)

	it("a replay pays no win coins, no life and no streak (a raised star record pays record coins, WP-15)", function()
		local m = H.new()
		win(m, 100, 1)
		local coins, wins = m:coins(), m:stats().wins
		local r = m:record_replay({ level_id = 1, difficulty = "easy", stars = 3, score = 5000 })
		assert_eq(m:coins(), coins + r.coins) -- only the record coins, not the win coins of the level
		assert_true(r.coins < require("meta.config").coins.win_base * 3)
		assert_eq(m:stats().wins, wins)
	end)

	it("refuses a replay of a level not beaten yet or during an attempt", function()
		local m = H.new()
		local ok, why = m:record_replay({ level_id = 1, difficulty = "easy", stars = 3 })
		assert_false(ok)
		assert_eq(why, "not_beaten")
		win(m, 100, 1)
		assert_true(m:start_level({ id = 2, difficulty = "easy" }, nil, T))
		ok, why = m:record_replay({ level_id = 1, difficulty = "easy", stars = 3 })
		assert_false(ok)
		assert_eq(why, "running")
		ok, why = m:record_replay({ level_id = 2, difficulty = "easy", stars = 3 })
		assert_false(ok)
	end)

	it("rejects stars outside 1..3 and a bad score", function()
		local m = H.new()
		assert_true(m:start_level({ id = 1, difficulty = "easy" }, nil, T))
		assert_error(function() m:finish_level({ won = true, level_id = 1, moves_at_win = 0, stars = 4 }, T) end)
		assert_error(function() m:finish_level({ won = true, level_id = 1, moves_at_win = 0, stars = 0 }, T) end)
		assert_error(function() m:finish_level({ won = true, level_id = 1, moves_at_win = 0, score = -1 }, T) end)
		assert_error(function() m:finish_level({ won = true, level_id = 1, moves_at_win = 0, concert = 1 }, T) end)
	end)

	it("keeps the old stars of a save from before the stars by score", function()
		local m = H.new()
		for _ = 1, 20 do H.win(m, T, "hard") end -- the old rule: 2 stars each
		local t = H.json_round_trip(m:serialize())
		t.level_stars, t.level_scores, t.super_stars = nil, nil, nil
		t.checksum = nil
		t.checksum = save.checksum(t)
		local back = Meta.load(H.districts(), t, nil, 7, T)
		assert_eq(back:stars(), m:stars())
		assert_eq(back:level_stars(5), 0, "no record, difficulty unknown")
		assert_eq(back:level_stars(5, "hard"), 2, "a beaten level is worth what the old rule paid")
		assert_eq(back:level_stars(21, "hard"), 0, "a level not beaten is worth nothing")
		-- a replay with fewer stars takes nothing away; with more it adds only the difference
		local r = back:record_replay({ level_id = 5, difficulty = "hard", stars = 1, score = 10 })
		assert_eq(r.gained, 0)
		assert_eq(back:stars(), m:stars())
		r = back:record_replay({ level_id = 5, difficulty = "hard", stars = 3, score = 10 })
		assert_eq(r.gained, 1)
		assert_eq(back:stars(), m:stars() + 1)
	end)

	it("survives the save, the JSON round trip and an old build in between", function()
		local m = H.new()
		win(m, 700, 3, { difficulty = "super_hard", concert = true })
		local back = reload(m)
		assert_eq(back:level_stars(1), 3)
		assert_eq(back:level_score(1), 700)
		assert_eq(back:super_stars().balance, 3)
		-- a build that does not know the fields (its save.fields lacks them) keeps them as extras and
		-- writes them back, so updating the app again finds the records
		local t = H.json_round_trip(m:serialize())
		local districts = require("meta.town").validate(H.districts())
		local fields = save.fields
		local old = {}
		for _, f in ipairs(fields) do
			if f ~= "level_stars" and f ~= "level_scores" and f ~= "super_stars" then old[#old + 1] = f end
		end
		save.fields = old
		local ok, again = pcall(function()
			local raw = assert(save.decode(t))
			local state = assert(save.restore(raw, districts))
			return save.serialize(state)
		end)
		save.fields = fields
		assert_true(ok, tostring(again))
		assert_same(again.level_stars, t.level_stars)
		assert_same(again.level_scores, t.level_scores)
		assert_same(again.super_stars, t.super_stars)
	end)

	it("restores hostile record fields as empty or clamped", function()
		local m = H.new()
		win(m, 100, 2)
		local t = H.json_round_trip(m:serialize())
		t.level_stars = { ["1"] = 99, ["03"] = 2, ["x"] = 1, ["2"] = -4, ["4"] = "3" }
		t.level_scores = "bad"
		t.super_stars = { levels = { ["1"] = 7 }, spent = -5 }
		t.checksum = nil
		t.checksum = save.checksum(t)
		local back = Meta.load(H.districts(), t, nil, 7, T)
		assert_eq(back:level_stars(1), 3, "clamped to 3")
		assert_eq(back:level_stars(3), 0)
		assert_eq(back:level_stars(2), 0)
		assert_eq(back:level_stars(4), 0)
		assert_eq(back:level_score(1), 0)
		assert_eq(back:super_stars().spent, 0)
		assert_eq(back:super_stars().balance, 3)
	end)
end)

describe("coins for an improved replay (WP-15)", function()
	local C = require("meta.config")

	it("pays coins for the stars a better replay adds, and nothing for an equal or worse one", function()
		local m = H.new()
		win(m, 100, 1) -- level 1, easy, 1 star
		local coins, st = m:coins(), m:stars()
		local r = m:record_replay({ level_id = 1, difficulty = "easy", stars = 3, score = 5000 })
		assert_eq(r.gained, 2)
		assert_eq(r.coins, C.replay.coins_per_star * 2 * C.coins.win_mult.easy)
		assert_eq(m:coins(), coins + r.coins)
		assert_eq(m:stars(), st + 2)
		-- the same record again, and a worse one: nothing is paid, nothing is taken
		for _, stars in ipairs({ 3, 2, 1 }) do
			local again = m:record_replay({ level_id = 1, difficulty = "easy", stars = stars, score = 6000 })
			assert_eq(again.gained, 0)
			assert_eq(again.coins, 0)
		end
		assert_eq(m:coins(), coins + r.coins)
		assert_eq(m:stars(), st + 2)
	end)

	it("pays more on a harder level (the difficulty multiplier) and one star at a time", function()
		local m = H.new()
		win(m, 100, 1, { difficulty = "hard" })
		local r = m:record_replay({ level_id = 1, difficulty = "hard", stars = 2, score = 3000 })
		assert_eq(r.coins, C.replay.coins_per_star * 1 * C.coins.win_mult.hard)
		r = m:record_replay({ level_id = 1, difficulty = "hard", stars = 3, score = 4000 })
		assert_eq(r.coins, C.replay.coins_per_star * 1 * C.coins.win_mult.hard)
		assert_true(C.coins.win_mult.hard > C.coins.win_mult.easy)
	end)

	it("writes the coins to the ledger under the record reason and touches neither lives nor the streak", function()
		local m = H.new()
		win(m, 100, 1)
		m:drain_ledger()
		local lives, streak = m:lives(T).count, m:streak().count
		local r = m:record_replay({ level_id = 1, difficulty = "easy", stars = 3, score = 5000 })
		local sum = H.ledger_sum(m:drain_ledger(), "coins", "level_stars_up")
		assert_eq(sum, r.coins)
		assert_eq(m:lives(T).count, lives)
		assert_eq(m:streak().count, streak)
	end)

	it("keeps the coins when the save is loaded again", function()
		local m = H.new()
		win(m, 100, 1)
		m:record_replay({ level_id = 1, difficulty = "easy", stars = 3, score = 5000 })
		local back = reload(m)
		assert_eq(back:coins(), m:coins())
		assert_eq(back:level_stars(1, "easy"), 3)
	end)
end)

describe("a save with 89 levels beaten (WP-15)", function()
	it("loads whole: coins, stars, bought tasks stay, and a better replay pays record coins", function()
		local m = H.new(3)
		H.advance_to(m, 89)
		H.give(m, "stars", 40)
		local done = 0
		for _ = 1, 4 do
			local nt = m:next_task()
			assert_true(nt ~= nil)
			assert(m:complete_task(nt.district, nt.id))
			done = done + 1
		end
		local coins, st = m:coins(), m:stars()
		local back = reload(m)
		assert_eq(back:coins(), coins)
		assert_eq(back:stars(), st)
		assert_eq(back:level_to_play(), 89)
		local before = back:next_task()
		assert_eq(before.id, m:next_task().id, "the tasks bought stay bought, the next one is the same")
		local r = back:record_replay({ level_id = 5, difficulty = "easy", stars = 3, score = 9000 })
		assert_true(r.gained >= 1 and r.coins > 0, "a level won before the stars by score is worth its old stars; a better replay pays")
		assert_eq(back:coins(), coins + r.coins)
		assert_eq(back:stars(), st + r.gained)
	end)
end)

describe("super stars", function()
	it("come from concert levels, as many as the best stars of the level", function()
		local m = H.new()
		local r = win(m, 100, 2, { concert = true })
		assert_eq(r.super_gained, 2)
		assert_true(r.concert)
		assert_eq(m:super_stars().balance, 2)
		r = m:record_replay({ level_id = 1, difficulty = "easy", stars = 3, score = 200, concert = true })
		assert_eq(r.super_gained, 1)
		assert_eq(m:super_stars().balance, 3)
		r = m:record_replay({ level_id = 1, difficulty = "easy", stars = 1, score = 200, concert = true })
		assert_eq(r.super_gained, 0)
		assert_eq(m:super_stars().balance, 3, "never down")
		assert_same(m:super_stars().levels, { [1] = 3 })
	end)

	it("are kept for a level that stopped being a concert (WP-14: 70 and 90 were concerts, the district ends are now)", function()
		-- the meta stores super stars by level id and knows nothing about which levels are concerts: that is the
		-- `kind` of stars.json, read by the client. An old save with super stars at 70 and 90 loses none of them.
		local m = H.new()
		H.advance_to(m, 70)
		local r = win(m, 24000, 3, { difficulty = "super_hard", concert = true }) -- level 70
		assert_eq(r.super_gained, 3)
		H.advance_to(m, 90)
		r = win(m, 22000, 2, { difficulty = "super_hard", concert = true }) -- level 90
		assert_eq(r.super_gained, 2)
		local back = reload(m)
		assert_same(back:super_stars().levels, { [70] = 3, [90] = 2 })
		assert_eq(back:super_stars().earned, 5)
		assert_eq(back:super_stars().balance, 5)
		-- a replay of level 70 as a normal level (no concert flag) pays nothing and takes nothing
		r = back:record_replay({ level_id = 70, difficulty = "super_hard", stars = 3, score = 24000 })
		assert_eq(r.super_gained, 0)
		assert_same(back:super_stars().levels, { [70] = 3, [90] = 2 })
	end)

	it("a normal level pays none", function()
		local m = H.new()
		local r = win(m, 100, 3)
		assert_eq(r.super_gained, 0)
		assert_eq(m:super_stars().earned, 0)
	end)

	it("are not for sale yet: the safe default has no sinks", function()
		local C = require("meta.config")
		assert_eq(#C.super_stars.sinks, 0)
		local m = H.new()
		win(m, 100, 3, { concert = true })
		local ok, why = m:spend_super_stars("anything")
		assert_false(ok)
		assert_eq(why, "unknown_sink")
		assert_eq(m:super_stars().balance, 3)
	end)

	it("can be spent on a configured sink, never below zero", function()
		local C = require("meta.config")
		local m = H.new()
		win(m, 100, 3, { concert = true })
		C.super_stars.sinks = { { id = "song", price = 2 }, { id = "deco", price = 5 } }
		local ok, err = pcall(function()
			assert_true(m:spend_super_stars("song"))
			assert_eq(m:super_stars().balance, 1)
			local fine, why = m:spend_super_stars("song")
			assert_false(fine)
			assert_eq(why, "not_enough_super_stars")
			assert_eq(reload(m):super_stars().balance, 1, "the spending is saved")
		end)
		C.super_stars.sinks = {}
		if not ok then error(err, 0) end
	end)
end)
