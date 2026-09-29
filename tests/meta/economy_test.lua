local C = require("meta.config")
local economy = require("meta.economy")
local H = require("tests.meta.helper")

local function state(coins)
	local s = { wallet = economy.restore_wallet(nil), stats = economy.restore_stats(nil) }
	s.wallet.coins = coins or 0
	return s
end

describe("economy ledger", function()
	it("applies changes and records them with a reason", function()
		local s, ledger = state(100), {}
		assert_true(economy.apply(s, ledger, "booster_pack", { { "coins", -60 }, { "stick", 3 } }))
		assert_eq(s.wallet.coins, 40)
		assert_eq(s.wallet.stick, 3)
		assert_same(ledger, {
			{ item = "coins", delta = -60, balance = 40, reason = "booster_pack", flow = "sink" },
			{ item = "stick", delta = 3, balance = 3, reason = "booster_pack", flow = "source" },
		})
	end)

	it("never lets a balance go negative and changes nothing on failure", function()
		local s, ledger = state(100), {}
		s.wallet.riff = 1
		local ok, why = economy.apply(s, ledger, "x", { { "riff", -1 }, { "coins", -101 } })
		assert_false(ok)
		assert_eq(why, "not_enough_coins")
		assert_eq(s.wallet.riff, 1, "the first change is not applied either")
		assert_eq(s.wallet.coins, 100)
		assert_same(ledger, {})
		assert_same(s.stats, { wins = 0, losses = 0, coins_earned = 0, coins_spent = 0 })
	end)

	it("checks repeated items against the running balance", function()
		local s, ledger = state(0), {}
		s.wallet.sub = 1
		local ok, why = economy.apply(s, ledger, "x", { { "sub", -1 }, { "sub", -1 } })
		assert_false(ok)
		assert_eq(why, "not_enough_sub")
		assert_eq(s.wallet.sub, 1)
	end)

	it("skips zero changes", function()
		local s, ledger = state(10), {}
		assert_true(economy.apply(s, ledger, "x", { { "coins", 0 } }))
		assert_same(ledger, {})
	end)

	it("counts coins earned and spent", function()
		local s, ledger = state(0), {}
		economy.apply(s, ledger, "a", { { "coins", 500 } })
		economy.apply(s, ledger, "b", { { "coins", -120 } })
		economy.apply(s, ledger, "c", { { "coins", 30 } })
		assert_eq(s.stats.coins_earned, 530)
		assert_eq(s.stats.coins_spent, 120)
		assert_eq(s.wallet.coins, s.stats.coins_earned - s.stats.coins_spent)
	end)

	it("rejects programming mistakes", function()
		local s = state(0)
		assert_error(function() economy.apply(s, {}, "x", { { "gems", 1 } }) end, "unknown wallet item")
		assert_error(function() economy.apply(s, {}, "x", { { "coins", 1.5 } }) end, "integer")
		assert_error(function() economy.apply(s, {}, nil, { { "coins", 1 } }) end, "reason")
	end)

	it("sanitizes a stored wallet", function()
		local w = economy.restore_wallet({ coins = -5, stars = 3.7, stick = "x", gems = 4 })
		assert_same(w, { coins = 0, stars = 3, stick = 0, row_light = 0, col_light = 0, remix = 0, riff = 0, sub = 0, disco = 0 })
	end)
end)

describe("economy rewards", function()
	it("pays 25 x difficulty + 5 per move left", function()
		for _, d in ipairs(C.difficulties) do assert_true(economy.is_difficulty(d), d) end
		assert_false(economy.is_difficulty("brutal"))
		assert_same({ economy.win_reward("easy", 0) }, { 25, 1 })
		assert_same({ economy.win_reward("medium", 4) }, { 45, 1 })
		assert_same({ economy.win_reward("hard", 0) }, { 50, 2 })
		assert_same({ economy.win_reward("super_hard", 10) }, { 125, 3 })
		assert_error(function() economy.win_reward("brutal", 0) end, "difficulty")
		assert_error(function() economy.win_reward("easy", -1) end, "moves_at_win")
		assert_error(function() economy.win_reward("easy", nil) end, "moves_at_win")
	end)

	it("fills a chest every 10 levels from the booster rotation", function()
		local expected = {
			{ 60, { "stick" }, 15 },
			{ 70, { "row_light", "riff" }, 30 },
			{ 80, { "col_light" }, 15 },
			{ 90, { "sub", "remix" }, 30 },
			{ 100, { "disco" }, 15 },
			{ 110, { "stick", "row_light" }, 30 },
			{ 120, { "riff" }, 15 },
			{ 130, { "col_light", "sub" }, 30 },
			{ 140, { "remix" }, 15 },
			{ 150, { "disco", "stick" }, 30 },
		}
		for k = 1, 10 do
			local chest = economy.level_chest(10 * k)
			assert_same(chest, { k = k, coins = expected[k][1], boosters = expected[k][2], infinite_minutes = expected[k][3] }, "chest " .. k)
		end
		assert_eq(economy.level_chest(15), nil)
		assert_eq(economy.level_chest(1), nil)
		assert_eq(economy.level_chest(0), nil)
	end)

	it("walks past a locked booster instead of dealing a neighbour twice", function()
		-- row_light unlocks at 30: chest 2 (opened on the way to level 21) skips it
		H.with_unlocks({ row_light = 30 }, function()
			assert_same(economy.level_chest(10).boosters, { "stick" })
			assert_same(economy.level_chest(20).boosters, { "riff", "col_light" }, "no riff twice")
			assert_same(economy.level_chest(30).boosters, { "sub" }, "the walk goes on after col_light")
			assert_same(economy.level_chest(40).boosters, { "remix", "disco" })
			assert_same(economy.level_chest(50).boosters, { "stick" })
			assert_same(economy.level_chest(60).boosters, { "row_light", "riff" }, "open now, dealt on the next lap")
		end)
	end)

	it("gives the fallback while nothing is unlocked and then continues the walk", function()
		H.with_unlocks({ stick = 15, row_light = 15, riff = 15, col_light = 15, sub = 15, remix = 15, disco = 15 }, function()
			assert_same(economy.level_chest(10).boosters, { "stick" }, "fallback")
			assert_same(economy.level_chest(20).boosters, { "stick", "row_light" }, "the walk did not move")
		end)
		H.with_unlocks({ stick = 50, row_light = 50, riff = 50, col_light = 50, sub = 50, remix = 50, disco = 50 }, function()
			assert_same(economy.level_chest(20).boosters, { "stick", "stick" })
		end)
		-- only the stick open: every slot ends on it
		H.with_unlocks({ row_light = 50, riff = 50, col_light = 50, sub = 50, remix = 50, disco = 50 }, function()
			assert_same(economy.level_chest(20).boosters, { "stick", "stick" })
		end)
	end)

	it("prices continues 700, 1400, 2100 and then stops", function()
		assert_eq(economy.continue_price(1), 700)
		assert_eq(economy.continue_price(2), 1400)
		assert_eq(economy.continue_price(3), 2100)
		assert_eq(economy.continue_price(4), nil)
	end)
end)

describe("economy in the meta", function()
	it("starts with 500 coins recorded in the ledger", function()
		local m = H.new()
		assert_eq(m:coins(), 500)
		assert_same(m:drain_ledger(), { { item = "coins", delta = 500, balance = 500, reason = "start", flow = "source" } })
		assert_same(m:drain_ledger(), {})
	end)

	it("pays the win reward and the chest of level 10", function()
		local m = H.new()
		H.advance_to(m, 10)
		m:drain_ledger()
		local coins = m:coins()
		local r = H.win(m, H.T0, "easy", 7)
		assert_eq(r.coins, 25 + 35)
		assert_eq(r.stars, 1)
		assert_same(r.chest, { k = 1, coins = 60, boosters = { "stick" }, infinite_minutes = 15 })
		assert_eq(m:coins(), coins + 60 + 60)
		assert_eq(m:lives(H.T0).infinite_seconds, 900)
		local ledger = m:drain_ledger()
		assert_eq(H.ledger_sum(ledger, "coins", "level_win"), 60)
		assert_eq(H.ledger_sum(ledger, "stars", "level_win"), 1)
		assert_eq(H.ledger_sum(ledger, "coins", "level_chest"), 60)
		assert_eq(H.ledger_sum(ledger, "stick", "level_chest"), 1)
		assert_eq(H.ledger_sum(ledger, "infinite_minutes", "level_chest"), 15)
	end)

	it("stacks infinite lives from chests", function()
		local m = H.new()
		H.advance_to(m, 20)
		assert_eq(m:lives(H.T0).infinite_seconds, 900)
		H.win(m, H.T0 + 60)
		assert_eq(m:lives(H.T0 + 60).infinite_seconds, 900 - 60 + 1800)
	end)
end)
