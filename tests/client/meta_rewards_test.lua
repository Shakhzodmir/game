local rewards = require("client.rewards")
local show_mod = require("screens.town.show")

describe("client.rewards", function()
	before_each(function() rewards.clear() end)

	it("normalizes results and drops bad fields", function()
		local r = rewards.normalize({ won = true, stars = "2", coins = -5, chest = { coins = 60, boosters = { "stick", 3 } },
			unlocked = { "riff", "", false }, level_id = "10" })
		assert_eq(r.stars, 2)
		assert_eq(r.coins, 0)
		assert_eq(r.level_id, 10)
		assert_same(r.chest.boosters, { "stick" })
		assert_same(r.unlocked, { "riff" })
		assert_eq(rewards.normalize("nope"), nil)
		local loss = rewards.normalize({ won = false, stars = 3, coins = 9, life_lost = true, streak_lost = 2 })
		assert_eq(loss.stars, 0)
		assert_eq(loss.coins, 0)
	end)

	it("queues results, holds their amounts and pops them in order", function()
		assert_eq(rewards.push({ won = true, stars = 1, coins = 30 }), 1)
		assert_eq(rewards.push({ won = true, stars = 2, coins = 50, chest = { coins = 60 } }), 2)
		assert_same(rewards.held(), { coins = 140, stars = 3 })
		assert_eq(rewards.pop().coins, 30)
		assert_same(rewards.held(), { coins = 110, stars = 2 })
		assert_eq(rewards.count(), 1)
		assert_eq(rewards.push(nil), nil)
	end)

	it("keeps at most MAX results", function()
		for i = 1, rewards.MAX + 3 do rewards.push({ won = true, stars = 1, level_id = i }) end
		assert_eq(rewards.count(), rewards.MAX)
		assert_eq(rewards.peek().level_id, 4)
	end)

	it("turns a result into steps: win, streak, chest, unlock / loss", function()
		local r = rewards.normalize({ won = true, stars = 2, coins = 40, streak = 2, chest = { coins = 60 }, unlocked = { "riff" } })
		local kinds = {}
		for i, s in ipairs(rewards.steps(r)) do kinds[i] = s.kind end
		assert_same(kinds, { "win", "streak", "chest", "unlock" })
		local l = rewards.steps(rewards.normalize({ won = false, life_lost = true, streak_lost = 3 }))
		assert_eq(#l, 1)
		assert_eq(l[1].kind, "loss")
		assert_same(rewards.steps(rewards.normalize({ won = false })), {})
	end)

	it("splits amounts into chunks that add up", function()
		for _, case in ipairs({ { 7, 3 }, { 100, 7 }, { 2, 5 }, { 0, 3 } }) do
			local sum = 0
			for _, c in ipairs(rewards.chunks(case[1], case[2])) do sum = sum + c end
			assert_eq(sum, case[1])
		end
		assert_eq(rewards.flyers("stars", 3), 3)
		assert_eq(rewards.flyers("stars", 9), 5)
		assert_eq(rewards.flyers("coins", 0), 0)
		assert_true(rewards.flyers("coins", 500) <= 10)
	end)
end)

describe("screens.town.show", function()
	local function fake_town()
		local t = { popups = { n = 0 } }
		function t.popups:count() return self.n end
		t.fx = { cleared = 0 }
		function t.fx:clear() self.cleared = self.cleared + 1 end
		return t
	end

	it("runs steps one after another", function()
		local t = fake_town()
		local sh = show_mod.new(t)
		local log, dones = {}, {}
		for i = 1, 2 do
			sh:push({ name = "s" .. i, run = function(done) log[#log + 1] = "run" .. i; dones[i] = done end,
				after = function() log[#log + 1] = "after" .. i end })
		end
		sh:update()
		assert_eq(sh:name(), "s1")
		sh:update()
		assert_same(log, { "run1" })
		dones[1]()
		dones[1]() -- a second done is ignored
		sh:update()
		assert_same(log, { "run1", "after1", "run2" })
		dones[2]()
		assert_false(sh:busy())
	end)

	it("waits while a popup is open or the screen is leaving", function()
		local t = fake_town()
		local sh = show_mod.new(t)
		local ran = false
		sh:push({ name = "x", run = function() ran = true end })
		t.popups.n = 1
		sh:update()
		assert_false(ran)
		t.popups.n = 0
		t.leaving = true
		sh:update()
		assert_false(ran)
		t.leaving = false
		sh:update()
		assert_true(ran)
	end)

	it("skips a skippable step to its end state; a late done is ignored", function()
		local t = fake_town()
		local sh = show_mod.new(t)
		local late, finished, after = nil, false, 0
		sh:push({ name = "task", skippable = true, run = function(done) late = done end,
			finish = function() finished = true end, after = function() after = after + 1 end })
		sh:push({ name = "concert", run = function() end })
		sh:update()
		assert_true(sh:skippable())
		assert_true(sh:skip())
		assert_true(finished)
		assert_eq(after, 1)
		assert_eq(t.fx.cleared, 1)
		late()
		assert_eq(after, 1)
		sh:update()
		assert_eq(sh:name(), "concert")
		assert_false(sh:skip()) -- not skippable
		sh:clear()
		assert_false(sh:busy())
	end)
end)
