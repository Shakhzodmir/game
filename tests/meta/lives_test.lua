local lives = require("meta.lives")
local Meta = require("meta.meta")
local H = require("tests.meta.helper")

local T = H.T0
local R = 1200 -- regen seconds
local DAY = 86400

-- Moves the lives to `now` and returns the status there.
local function at(ls, now)
	lives.update(ls, now)
	return lives.status(ls)
end

describe("lives", function()
	local ls
	before_each(function()
		ls = lives.restore(nil)
		lives.update(ls, T)
	end)

	it("start full", function()
		assert_same(at(ls, T), { count = 5, max = 5, next_in_seconds = 0, infinite_seconds = 0 })
	end)

	it("start the regen timer when the first life is taken", function()
		assert_true(lives.consume(ls))
		assert_same(at(ls, T), { count = 4, max = 5, next_in_seconds = R, infinite_seconds = 0 })
		lives.update(ls, T + 100)
		assert_true(lives.consume(ls))
		local st = at(ls, T + 100)
		assert_eq(st.count, 3)
		assert_eq(st.next_in_seconds, R - 100, "the running timer is kept")
	end)

	it("give one life every 20 minutes up to the maximum", function()
		for _ = 1, 5 do lives.consume(ls) end
		assert_eq(at(ls, T).count, 0)
		assert_eq(at(ls, T + R - 1).count, 0)
		assert_eq(at(ls, T + R).count, 1)
		local st = at(ls, T + 3 * R + 7)
		assert_eq(st.count, 3)
		assert_eq(st.next_in_seconds, R - 7)
		st = at(ls, T + 50 * R)
		assert_eq(st.count, 5)
		assert_eq(st.next_in_seconds, 0)
		assert_eq(ls.next_at, 0)
	end)

	it("do not go below zero", function()
		for _ = 1, 5 do assert_true(lives.consume(ls)) end
		assert_false(lives.consume(ls))
		assert_eq(ls.count, 0)
	end)

	it("refill to the maximum and stop the timer", function()
		lives.consume(ls)
		lives.consume(ls)
		lives.update(ls, T + 5)
		lives.refill(ls)
		assert_same(at(ls, T + 5), { count = 5, max = 5, next_in_seconds = 0, infinite_seconds = 0 })
	end)

	it("stack infinite lives minutes", function()
		assert_eq(lives.add_infinite(ls, 15), 900)
		lives.update(ls, T + 60)
		assert_eq(lives.add_infinite(ls, 30), 900 - 60 + 1800)
		assert_eq(at(ls, T + 60).infinite_seconds, 2640)
		lives.update(ls, T + 2699)
		assert_true(lives.infinite_active(ls))
		lives.update(ls, T + 2700)
		assert_false(lives.infinite_active(ls))
		-- after expiry new minutes count from now
		lives.update(ls, T + 10000)
		assert_eq(lives.add_infinite(ls, 15), 900)
		assert_error(function() lives.add_infinite(ls, -1) end, "non-negative")
		assert_error(function() lives.add_infinite(ls, 1.5) end, "non-negative")
	end)

	it("let a level be played with infinite lives and no regular life", function()
		for _ = 1, 5 do lives.consume(ls) end
		assert_false(lives.can_play(ls))
		lives.add_infinite(ls, 15)
		assert_true(lives.can_play(ls))
		lives.update(ls, T + 900)
		assert_false(lives.can_play(ls))
	end)

	it("restore sanitized state", function()
		local r = lives.restore({ count = 9, next_at = -3, last_seen = "x", clock = 5, infinite_until = 1.5 })
		assert_same(r, { count = 5, next_at = 0, last_seen = 0, clock = 0, infinite_until = 1 })
		r = lives.restore({ count = 2, last_seen = T })
		assert_eq(r.next_at, T + R, "a missing timer restarts from the last seen time")
		assert_eq(r.clock, T, "a missing device time is the last seen time")
		r = lives.restore({ count = 2, next_at = T + 10 * R, last_seen = T, clock = T + 50 })
		assert_eq(r.next_at, T + R, "a timer beyond one period is impossible and restarts")
		assert_eq(r.clock, T, "the device time is never after the last seen time")
	end)
end)

describe("lives with the device clock turned back", function()
	local ls
	before_each(function()
		ls = lives.restore(nil)
		lives.update(ls, T)
	end)

	it("do not regenerate sooner: the timer waits for real time", function()
		lives.consume(ls)
		lives.consume(ls)
		assert_eq(at(ls, T + 1000).next_in_seconds, 200)
		-- the device clock jumps a day back: nothing is granted, the timer stands still
		local st = at(ls, T - DAY)
		assert_eq(st.count, 3)
		assert_eq(st.next_in_seconds, 200)
		assert_eq(ls.last_seen, T + 1000)
		assert_eq(ls.clock, T - DAY)
		assert_eq(at(ls, T - DAY + 5000).count, 3, "still before the last seen time")
		-- back to real time: regen continues where it stopped
		assert_eq(at(ls, T + R).count, 4)
	end)

	it("keep infinite lives running down, never extended or frozen", function()
		lives.add_infinite(ls, 30)
		assert_eq(at(ls, T + 300).infinite_seconds, 1500)
		assert_true(lives.update(ls, T - DAY), "the end time moved")
		assert_eq(lives.infinite_seconds(ls), 1500, "turning the clock back does not add time")
		assert_eq(at(ls, T - DAY + 600).infinite_seconds, 900, "and it keeps running")
		assert_eq(at(ls, T - DAY + 1500).infinite_seconds, 0)
		assert_eq(at(ls, T - DAY + 1860).infinite_seconds, 0)
		-- the clock goes forward to real time: nothing comes back
		assert_eq(at(ls, T + 400).infinite_seconds, 0)
	end)

	it("do not revive infinite lives that ran out", function()
		lives.add_infinite(ls, 15)
		assert_eq(at(ls, T + 1000).infinite_seconds, 0)
		assert_false(lives.update(ls, T + 500), "nothing was running")
		assert_eq(lives.infinite_seconds(ls), 0)
		assert_eq(at(ls, T + 600).infinite_seconds, 0)
	end)

	it("spend infinite time when a clock that was behind is corrected forward", function()
		lives.update(ls, T - DAY)
		lives.add_infinite(ls, 30)
		assert_eq(at(ls, T - DAY + 600).infinite_seconds, 1200)
		assert_eq(at(ls, T).infinite_seconds, 0)
	end)

	it("keep the remaining time of a clock that was ahead and is corrected back", function()
		lives.update(ls, T + 3600) -- the clock runs an hour ahead
		lives.add_infinite(ls, 30)
		assert_eq(at(ls, T + 3600 + 60).infinite_seconds, 1740)
		assert_eq(at(ls, T + 120).infinite_seconds, 1740, "the correction takes nothing")
		assert_eq(at(ls, T + 180).infinite_seconds, 1680)
	end)
end)

describe("lives in the meta", function()
	-- levels 10 and 20 give 45 minutes of infinite lives; play after they ran out
	local P = T + 10000

	it("regenerate across app restarts", function()
		local m = H.new()
		H.advance_to(m, 21)
		for _ = 1, 3 do H.lose(m, P) end
		assert_same(m:lives(P), { count = 2, max = 5, next_in_seconds = R, infinite_seconds = 0 })
		local saved = m:serialize()
		-- the app is closed for 2 periods and 100 s
		local m2 = Meta.load(H.districts(), saved, nil, 1, P + 2 * R + 100)
		assert_same(m2:lives(P + 2 * R + 100), { count = 4, max = 5, next_in_seconds = R - 100, infinite_seconds = 0 })
	end)

	it("regenerate from the last seen time after a restart with the clock set back", function()
		local m = H.new()
		H.advance_to(m, 21)
		H.lose(m, P)
		m:lives(P + 600)
		local m2 = Meta.load(H.districts(), m:serialize(), nil, 1, P - 3600)
		assert_same(m2:lives(P - 3600), { count = 4, max = 5, next_in_seconds = 600, infinite_seconds = 0 })
	end)

	it("cannot be farmed with infinite lives by turning the clock back", function()
		local m = H.new()
		H.advance_to(m, 21)
		m:grant({ infinite_minutes = 30 }, "iap", P)
		-- a day back, then a loss every 10 minutes for a whole day
		local back = P - DAY
		local free, charged = 0, 0
		for i = 0, DAY - 600, 600 do
			local now = back + i
			if m:start_level({ id = 21, difficulty = "hard" }, nil, now) then
				m:note_move()
				local r = m:finish_level({ won = false, level_id = 21 }, now)
				if r.life_lost then charged = charged + 1 else free = free + 1 end
			end
		end
		assert_eq(free, 3, "only the 30 minutes that were left are free")
		assert_eq(charged, 5)
		assert_eq(m:lives(back + DAY).infinite_seconds, 0)
	end)

	it("run out after the clock is set back and 31 minutes pass, also across a restart", function()
		local m = H.new()
		H.advance_to(m, 21)
		m:grant({ infinite_minutes = 30 }, "iap", P)
		assert_eq(m:lives(P - DAY).infinite_seconds, 1800)
		local m2 = Meta.load(H.districts(), m:serialize(), nil, 1, P - DAY + 60)
		assert_eq(m2:lives(P - DAY + 60).infinite_seconds, 1740)
		local later = P - DAY + 31 * 60
		assert_eq(m2:lives(later).infinite_seconds, 0)
		local r = assert(m2:start_level({ id = 21, difficulty = "easy" }, nil, later))
		assert_true(r.life_at_stake)
		m2:note_move()
		assert_true(m2:finish_level({ won = false, level_id = 21 }, later).life_lost)
		assert_eq(m2:lives(later).count, 4)
	end)

	it("save the moved end time of infinite lives", function()
		local m = H.new()
		H.advance_to(m, 21)
		m:grant({ infinite_minutes = 30 }, "iap", P)
		m:serialize()
		assert_false(m:dirty())
		m:lives(P + 60)
		assert_false(m:dirty(), "time passing alone is not a change")
		m:lives(P - DAY)
		assert_true(m:dirty(), "the clock went back while infinite lives ran")
	end)

	it("refill for 600 coins", function()
		local m = H.new()
		H.advance_to(m, 21)
		H.lose(m, P)
		H.lose(m, P)
		local coins = m:coins()
		m:drain_ledger()
		assert_same(m:refill_offer(P), { price = 600, available = true, affordable = true })
		assert_true(m:refill_lives(P))
		assert_eq(m:coins(), coins - 600)
		assert_eq(m:lives(P).count, 5)
		assert_same(m:drain_ledger(), {
			{ item = "coins", delta = -600, balance = coins - 600, reason = "refill_lives", flow = "sink" },
		})
	end)

	it("refuse a refill when full, during infinite lives or when coins are short", function()
		local m = H.new()
		assert_same(m:refill_offer(T), { price = 600, available = false, affordable = false, reason = "full" })
		local ok, why = m:refill_lives(T)
		assert_false(ok)
		assert_eq(why, "full")
		H.advance_to(m, 21)
		H.lose(m, P)
		m:grant({ infinite_minutes = 10 }, "event", P)
		H.give(m, "coins", 1000)
		assert_same(m:refill_offer(P), { price = 600, available = false, affordable = true, reason = "infinite_active" })
		local coins = m:coins()
		ok, why = m:refill_lives(P)
		assert_false(ok)
		assert_eq(why, "infinite_active")
		assert_eq(m:coins(), coins)
		assert_true(m:refill_offer(P + 600).available, "infinite lives ran out")
		H.give(m, "coins", -m:coins() + 599)
		m:drain_ledger()
		assert_same(m:refill_offer(P + 600), { price = 600, available = true, affordable = false })
		ok, why = m:refill_lives(P + 600)
		assert_false(ok)
		assert_eq(why, "not_enough_coins")
		assert_eq(m:coins(), 599)
		assert_eq(m:lives(P + 600).count, 4)
		assert_same(m:drain_ledger(), {})
	end)

	it("ignore the fraction of a second", function()
		local m = H.new()
		m:lives(T + 0.9)
		assert_eq(m.s.lives.last_seen, T)
		assert_eq(m.s.lives.clock, T)
	end)

	it("reject a bad now with an error at the calling line", function()
		local m = H.new()
		local calls = {
			function() m:lives(nil) end,
			function() m:lives(-1) end,
			function() m:lives(0 / 0) end,
			function() m:lives(math.huge) end,
			function() m:refill_offer("now") end,
			function() m:refill_lives() end,
			function() m:can_start(1) end,
			function() m:start_level({ id = 1, difficulty = "easy" }, nil) end,
			function() m:grant({ coins = 1 }, "x") end,
			function() Meta.load(H.districts(), nil, nil, 1) end,
		}
		for i, call in ipairs(calls) do
			local ok, err = pcall(call)
			assert_false(ok, "call " .. i)
			assert_true(tostring(err):find("lives_test%.lua:%d+: meta: 'now' must be") ~= nil,
				"call " .. i .. " blames the caller: " .. tostring(err))
		end
		m:start_level({ id = 1, difficulty = "easy" }, nil, T)
		local ok, err = pcall(function() m:finish_level({ won = true, level_id = 1, moves_at_win = 0 }) end)
		assert_false(ok)
		assert_true(tostring(err):find("lives_test%.lua:%d+: meta: 'now' must be") ~= nil, tostring(err))
	end)
end)
