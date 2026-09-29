local lives = require("meta.lives")
local Meta = require("meta.meta")
local H = require("tests.meta.helper")

local T = H.T0
local R = 1200 -- regen seconds

describe("lives", function()
	local ls
	before_each(function() ls = lives.restore(nil) end)

	it("start full", function()
		assert_same(lives.status(ls, T), { count = 5, max = 5, next_in_seconds = 0, infinite_seconds = 0 })
	end)

	it("start the regen timer when the first life is taken", function()
		assert_true(lives.consume(ls, T))
		assert_same(lives.status(ls, T), { count = 4, max = 5, next_in_seconds = R, infinite_seconds = 0 })
		assert_true(lives.consume(ls, T + 100))
		local st = lives.status(ls, T + 100)
		assert_eq(st.count, 3)
		assert_eq(st.next_in_seconds, R - 100, "the running timer is kept")
	end)

	it("give one life every 20 minutes up to the maximum", function()
		for _ = 1, 5 do lives.consume(ls, T) end
		assert_eq(lives.status(ls, T).count, 0)
		assert_eq(lives.status(ls, T + R - 1).count, 0)
		assert_eq(lives.status(ls, T + R).count, 1)
		local st = lives.status(ls, T + 3 * R + 7)
		assert_eq(st.count, 3)
		assert_eq(st.next_in_seconds, R - 7)
		st = lives.status(ls, T + 50 * R)
		assert_eq(st.count, 5)
		assert_eq(st.next_in_seconds, 0)
		assert_eq(ls.next_at, 0)
	end)

	it("ignore a clock that went back", function()
		lives.consume(ls, T)
		lives.consume(ls, T)
		assert_eq(lives.status(ls, T + 1000).next_in_seconds, 200)
		-- the device clock jumps a day back: nothing is granted, the timer stands still
		local st = lives.status(ls, T - 86400)
		assert_eq(st.count, 3)
		assert_eq(st.next_in_seconds, 200)
		assert_eq(ls.last_seen, T + 1000)
		-- back to real time: regen continues where it stopped
		assert_eq(lives.status(ls, T + R).count, 4)
	end)

	it("never extend infinite lives when the clock goes back", function()
		lives.add_infinite(ls, 15, T)
		assert_eq(lives.status(ls, T + 300).infinite_seconds, 600)
		assert_eq(lives.status(ls, T).infinite_seconds, 600)
		assert_eq(lives.status(ls, T - 5000).infinite_seconds, 600)
	end)

	it("stack infinite lives minutes", function()
		assert_eq(lives.add_infinite(ls, 15, T), 900)
		assert_eq(lives.add_infinite(ls, 30, T + 60), 900 - 60 + 1800)
		assert_eq(lives.status(ls, T + 60).infinite_seconds, 2640)
		assert_true(lives.infinite_active(ls, T + 2699))
		assert_false(lives.infinite_active(ls, T + 2700))
		-- after expiry new minutes count from now
		assert_eq(lives.add_infinite(ls, 15, T + 10000), 900)
	end)

	it("let a level be played with infinite lives and no regular life", function()
		for _ = 1, 5 do lives.consume(ls, T) end
		assert_false(lives.can_play(ls, T))
		lives.add_infinite(ls, 15, T)
		assert_true(lives.can_play(ls, T))
		assert_false(lives.can_play(ls, T + 900))
	end)

	it("refill to the maximum and stop the timer", function()
		lives.consume(ls, T)
		lives.consume(ls, T)
		lives.refill(ls, T + 5)
		assert_same(lives.status(ls, T + 5), { count = 5, max = 5, next_in_seconds = 0, infinite_seconds = 0 })
	end)

	it("do not go below zero", function()
		for _ = 1, 5 do assert_true(lives.consume(ls, T)) end
		assert_false(lives.consume(ls, T))
		assert_eq(ls.count, 0)
	end)

	it("ignore the fraction of a second and reject a bad now", function()
		lives.consume(ls, T + 0.9)
		assert_eq(ls.last_seen, T)
		assert_error(function() lives.status(ls, nil) end, "now")
		assert_error(function() lives.status(ls, -1) end, "now")
		assert_error(function() lives.status(ls, 0 / 0) end, "now")
	end)

	it("restore sanitized state", function()
		local r = lives.restore({ count = 9, next_at = -3, last_seen = "x", infinite_until = 1.5 })
		assert_same(r, { count = 5, next_at = 0, last_seen = 0, infinite_until = 1 })
		r = lives.restore({ count = 2, last_seen = T })
		assert_eq(r.next_at, T + R, "a missing timer restarts from the last seen time")
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

	it("refill for 600 coins", function()
		local m = H.new()
		H.advance_to(m, 21)
		H.lose(m, P)
		H.lose(m, P)
		local coins = m:coins()
		m:drain_ledger()
		assert_true(m:refill_lives(P))
		assert_eq(m:coins(), coins - 600)
		assert_eq(m:lives(P).count, 5)
		assert_same(m:drain_ledger(), {
			{ item = "coins", delta = -600, balance = coins - 600, reason = "refill_lives", flow = "sink" },
		})
	end)

	it("refuse a refill when full or when coins are short", function()
		local m = H.new()
		local ok, why = m:refill_lives(T)
		assert_false(ok)
		assert_eq(why, "full")
		H.advance_to(m, 21)
		H.lose(m, P)
		H.give(m, "coins", -m:coins() + 599)
		m:drain_ledger()
		ok, why = m:refill_lives(P)
		assert_false(ok)
		assert_eq(why, "not_enough_coins")
		assert_eq(m:coins(), 599)
		assert_eq(m:lives(P).count, 4)
		assert_same(m:drain_ledger(), {})
	end)
end)
