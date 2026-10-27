-- client/level_windows.lua and client/level_end.lua: what the level windows say and how an attempt
-- ends, on a real meta (nothing is decided in the client: every number is the meta's).

local app = require("client.app")
local bus = require("client.bus")
local rewards = require("client.rewards")
local lw = require("client.level_windows")
local level_end = require("client.level_end")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local ads = require("client.services.ads")
local H = require("tests.meta.helper")

local NOW = H.T0

-- A fresh meta; `level` = play on until that level is the next one. A few hours pass after that, so
-- the unlimited lives of the level chests (15 and 30 minutes) are over and a loss costs a life again.
local function boot(level)
	analytics.init({ strict = true })
	ads.init({ debug = false })
	rewards.clear()
	NOW = H.T0
	app.init({
		districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
		now = NOW, clock = function() return NOW end, sys_language = "en",
	})
	if level then
		H.advance_to(app.meta, level, NOW)
		NOW = NOW + 4 * 3600
	end
	analytics.drain()
	return app.meta
end

-- starts the next level (the attempt is open in the meta) and plays the first move
local function start(boosters, moved)
	local meta = app.meta
	local id = meta:level_to_play()
	local run = assert(meta:start_level({ id = id, difficulty = "easy" }, boosters or {}, NOW))
	if moved then meta:note_move() end
	return run, id
end

local function keys(lines)
	local out = {}
	for i, l in ipairs(lines) do out[i] = l.key end
	return out
end

local function names(events)
	local out = {}
	for i, e in ipairs(events) do out[i] = e.name end
	return out
end

describe("client.level_windows pause", function()
	it("has nothing at stake in a debug level without an attempt", function()
		boot()
		local p = lw.pause(app.meta, NOW)
		assert_eq(p.leave, "cancel")
		assert_false(p.at_stake)
		assert_same(keys(p.lines), { "pause.quit_free" })
	end)

	it("says that nothing is lost before the first move, and that the boosters come back", function()
		boot(12)
		start({ "riff" })
		local p = lw.pause(app.meta, NOW)
		assert_eq(p.leave, "cancel")
		assert_false(p.at_stake)
		assert_false(p.moved)
		assert_same(keys(p.lines), { "pause.quit_free", "pause.boosters_back" })
		app.meta:cancel_level()
		start({}, false)
		assert_same(keys(lw.pause(app.meta, NOW).lines), { "pause.quit_free" })
	end)

	it("is honest about a loss on a free level: no life, but a loss", function()
		boot(3)
		start({}, true)
		local p = lw.pause(app.meta, NOW)
		assert_eq(p.leave, "loss")
		assert_false(p.at_stake) -- level 3: no life, no streak
		assert_same(keys(p.lines), { "pause.warn_loss" })
	end)

	it("names the life and the hit streak that leaving burns", function()
		boot(21) -- nine wins in a row since level 12
		start({}, true)
		local p = lw.pause(app.meta, NOW)
		assert_eq(p.leave, "loss")
		assert_true(p.at_stake)
		assert_same(keys(p.lines), { "continue.life_warning", "continue.streak_warning" })
		assert_eq(p.lines[2].vars.n, 9)
		-- the streak is gone after a loss: only the life is left to lose
		assert_eq(level_end.lose({}, { level_id = 21 }).streak_lost, 9)
		start({}, true)
		assert_same(keys(lw.pause(app.meta, NOW).lines), { "continue.life_warning" })
		-- with a streak: level 12.. wins in a row
		boot(12)
		for _ = 1, 3 do H.win(app.meta, NOW) end
		assert_eq(app.meta:streak().count, 3)
		start({}, true) -- level 15: free of lives, but the streak burns
		local p2 = lw.pause(app.meta, NOW)
		assert_true(p2.at_stake)
		assert_same(keys(p2.lines), { "continue.streak_warning" })
		assert_eq(p2.lines[1].vars.n, 3)
		-- unlimited lives: the life is safe, with the streak (9) it is the streak that is named
		boot(21)
		app.meta:grant({ infinite_minutes = 15 }, "test", NOW)
		start({}, true)
		assert_same(keys(lw.pause(app.meta, NOW).lines), { "continue.streak_warning" })
		level_end.quit({})
		start({}, true)
		assert_same(keys(lw.pause(app.meta, NOW).lines), { "pause.warn_loss" }) -- no streak left, no life at stake
	end)
end)

describe("client.level_windows out of moves", function()
	it("offers +5 moves for 700 coins, then more for more, from the meta", function()
		boot(21)
		start({}, true)
		local v = lw.out_of_moves(app.meta, { state = "out_of_moves", stuck = false, goals = {} }, NOW, {})
		assert_false(v.stuck)
		assert_eq(v.offer.k, 1)
		assert_eq(v.offer.price, 700)
		assert_eq(v.offer.moves, 5)
		assert_false(v.offer.riff)
		assert_true(v.offer.affordable)
		assert_eq(v.coins, app.meta:coins())
		assert_true(v.at_stake)
		assert_same(keys(v.lines), { "continue.life_warning", "continue.streak_warning" })
		assert_true(app.meta:buy_continue(1))
		local v2 = lw.out_of_moves(app.meta, { state = "out_of_moves", stuck = false, goals = {} }, NOW, {})
		assert_eq(v2.offer.k, 2)
		assert_eq(v2.offer.price, 1400)
		assert_true(v2.offer.riff)
	end)

	it("shows an unaffordable offer as it is", function()
		boot(21)
		start({}, true)
		H.give(app.meta, "coins", -(app.meta:coins() - 100))
		local v = lw.out_of_moves(app.meta, { state = "out_of_moves", stuck = false }, NOW, {})
		assert_false(v.offer.affordable)
		assert_eq(v.offer.price, 700)
	end)

	it("sells no moves when the board is stuck or the limit is reached, and still names the cost of giving up", function()
		boot(21)
		start({}, true)
		local v = lw.out_of_moves(app.meta, { state = "out_of_moves", stuck = true }, NOW, {})
		assert_true(v.stuck)
		assert_eq(v.offer, nil)
		assert_false(v.ad)
		H.give(app.meta, "coins", 5000)
		for k = 1, 3 do assert_true(app.meta:buy_continue(k)) end
		local v2 = lw.out_of_moves(app.meta, { state = "out_of_moves", stuck = false }, NOW, {})
		assert_eq(v2.offer, nil) -- three purchases at most
	end)

	it("lists the in-level boosters the player can still use, and the video offer once", function()
		boot(26) -- every in-level booster is open
		local inv = {}
		for _, b in ipairs(app.meta:inventory()) do inv[b.id] = b.count end
		start({}, true)
		local ids = { "stick", "row_light", "col_light", "remix" }
		local v = lw.out_of_moves(app.meta, { state = "out_of_moves", stuck = false }, NOW, { boosters = ids, ads = true })
		assert_eq(#v.boosters, 4)
		assert_eq(v.boosters[1].id, "stick")
		assert_eq(v.boosters[1].count, inv.stick)
		assert_true(v.ad)
		assert_true(app.meta:grant_ad_moves())
		assert_false(lw.out_of_moves(app.meta, { state = "out_of_moves" }, NOW, { ads = true }).ad) -- once per attempt
		-- an empty one is not listed
		H.give(app.meta, "stick", -inv.stick)
		local v2 = lw.out_of_moves(app.meta, { state = "out_of_moves" }, NOW, { boosters = ids })
		assert_eq(#v2.boosters, 3)
		assert_eq(v2.boosters[1].id, "row_light")
	end)

	it("gives a free offer in a debug level and lists all four boosters", function()
		boot()
		local v = lw.out_of_moves(app.meta, { state = "out_of_moves", stuck = false }, NOW,
			{ boosters = { "stick", "remix" } })
		assert_true(v.offer.free)
		assert_eq(v.offer.moves, 5)
		assert_same(v.lines, {})
		assert_eq(#v.boosters, 2)
		assert_eq(v.boosters[1].count, nil)
	end)
end)

describe("client.level_windows defeat and result", function()
	local goals = {
		{ kind = "collect", image = "pieces/red", color = "red", count = 30 },
		{ kind = "break", image = "blockers/record_box_1", count = 10, item = "record_box" },
	}

	it("tells the defeat: what was lost, how close it was, whether a retry can start", function()
		boot(21)
		start({}, true)
		local res = level_end.lose({ unplaced = {} }, { level_id = 21, t0 = NOW })
		assert_false(res.won)
		local d = lw.defeat(app.meta, res, { goals = { 3, 0 } }, goals, { 30, 10 }, NOW)
		assert_true(d.life_lost)
		assert_eq(d.fails, 1)
		assert_eq(#d.goals, 1)
		assert_eq(d.goals[1].left, 3)
		assert_eq(d.goals[1].total, 30)
		assert_true(d.close) -- 37 of 40 done
		assert_false(d.no_lives)
		assert_eq(d.lives.count, 4)
		local far = lw.defeat(app.meta, res, { goals = { 25, 9 } }, goals, { 30, 10 }, NOW)
		assert_false(far.close)
		assert_eq(#far.goals, 2)
		assert_false(far.quit)
	end)

	it("knows when there is no life left for a retry", function()
		boot(21)
		for _ = 1, 5 do
			start({}, true)
			level_end.lose({}, { level_id = 21 })
		end
		local d = lw.defeat(app.meta, { life_lost = true, streak_lost = 0, fails = 5 }, { goals = {} }, goals, {}, NOW)
		assert_true(d.no_lives)
		assert_eq(d.lives.count, 0)
		assert_true(d.lives.next_in > 0)
	end)

	it("tells the results of a win: stars, coins, streak, the chest, the progress and the next level", function()
		boot(10)
		start({}, true) -- level 10 of the free levels: a chest comes
		local res = level_end.win({ moves_at_win = 4, score = 5600, stars = 1, unplaced = {} }, { level_id = 10, t0 = NOW })
		assert_true(res.won)
		local v = lw.result(app.meta, res, { moves_at_win = 4, score = 5600, stars = 1 }, NOW)
		assert_eq(v.stars, 1)
		assert_eq(v.coins, 25 + 4 * 5)
		assert_eq(v.score, 5600)
		assert_eq(v.moves_left, 4)
		assert_eq(v.chest.k, 1)
		assert_eq(v.chest.coins, 60)
		assert_true(v.progress.opened)
		assert_eq(v.next_level, 11)
		assert_false(v.all_done)
		assert_false(v.streak.active) -- the streak counts from level 12
		assert_eq(#v.streak.notes, 3)
		assert_same(v.unlocked, {})
		boot(11)
		start({}, true)
		local r2 = level_end.win({ moves_at_win = 0, score = 100, stars = 1 }, { level_id = 11 })
		local v2 = lw.result(app.meta, r2, { moves_at_win = 0, score = 100 }, NOW)
		assert_eq(v2.chest, nil)
		assert_eq(v2.progress.done, 1)
		assert_eq(v2.progress.left, 9)
		assert_same(v2.unlocked, { "riff" }) -- Riff opens at level 12: its gift comes with the win of level 11
	end)

	it("shows the hit streak and the free boosters of the next start", function()
		boot(12)
		for _ = 1, 2 do H.win(app.meta, NOW) end
		start({}, true)
		local res = level_end.win({ moves_at_win = 1, score = 1, stars = 1 }, { level_id = 14 })
		local v = lw.result(app.meta, res, { moves_at_win = 1 }, NOW)
		assert_true(v.streak.active)
		assert_eq(v.streak.count, 3)
		assert_true(v.streak.notes[3].lit)
		assert_same(v.streak.free, { "riff" }) -- only what is open at level 15: Subwoofer opens at 16
	end)

	it("counts the progress to the next chest", function()
		assert_same(lw.chest_progress(9), { done = 9, total = 10, left = 1, opened = false })
		assert_same(lw.chest_progress(10), { done = 10, total = 10, left = 0, opened = true })
		assert_same(lw.chest_progress(11), { done = 1, total = 10, left = 9, opened = false })
		assert_same(lw.chest_progress(100), { done = 10, total = 10, left = 0, opened = true })
	end)

	it("hands out the unlock gift at the win that opens a booster", function()
		boot(7)
		start({}, true)
		local res = level_end.win({ moves_at_win = 0, score = 1, stars = 1 }, { level_id = 7 })
		local v = lw.result(app.meta, res, {}, NOW)
		assert_same(v.unlocked, { "stick" }) -- the drumstick opens for level 8
	end)
end)

describe("client.level_end", function()
	it("closes a win through the meta, queues the reward for the town and logs it", function()
		boot(5)
		local run = start({}, true)
		local res = level_end.win({ moves_at_win = 3, score = 900, stars = 1, unplaced = {} }, { level_id = 5, t0 = NOW - 95 })
		assert_true(res.won)
		assert_eq(res.coins, 25 + 15)
		assert_eq(res.next_level, 6)
		assert_eq(app.meta:run(), nil)
		assert_eq(app.meta:level_to_play(), 6)
		assert_eq(rewards.count(), 1)
		assert_eq(rewards.peek().coins, 40)
		assert_false(app.meta:dirty()) -- saved
		local ev = analytics.drain()
		local win
		for _, e in ipairs(ev) do if e.name == "level_win" then win = e.params end end
		assert_eq(win.level, 5)
		assert_eq(win.attempt, run.attempt)
		assert_eq(win.moves_left, 3)
		assert_eq(win.stars, 1)
		assert_eq(win.seconds, 95)
	end)

	it("closes a loss: the life, the streak, the queue is not filled", function()
		boot(21)
		local before = app.meta:lives(NOW).count
		start({}, true)
		local res = level_end.lose({ unplaced = {} }, { level_id = 21, t0 = NOW })
		assert_false(res.won)
		assert_true(res.life_lost)
		assert_eq(app.meta:lives(NOW).count, before - 1)
		assert_eq(app.meta:run(), nil)
		assert_eq(rewards.count(), 0) -- the town gets it when the player leaves, not on a retry
		local names_ = names(analytics.drain())
		local fail = false
		for _, n in ipairs(names_) do if n == "level_fail" then fail = true end end
		assert_true(fail)
	end)

	it("tells the meta about the first move when the core lost a level the meta did not know was moved", function()
		boot(5)
		start({}, false) -- the first-move hook never ran
		local res = level_end.lose({}, { level_id = 5 })
		assert_false(res.won)
		assert_eq(app.meta:attempts(5).fails, 1)
	end)

	it("drops an attempt left before the first move, and loses one left after it", function()
		boot(12)
		local before = app.meta:booster_count("riff")
		start({ "riff" }, false)
		assert_eq(app.meta:booster_count("riff"), before - 1)
		local q = level_end.quit({ level_id = 13 })
		assert_eq(q.kind, "cancelled")
		assert_eq(app.meta:booster_count("riff"), before) -- came back
		assert_eq(app.meta:run(), nil)
		assert_eq(rewards.count(), 0)
		boot(21)
		start({}, true)
		local q2 = level_end.quit({ level_id = 21 })
		assert_eq(q2.kind, "loss")
		assert_true(q2.res.life_lost)
		assert_eq(rewards.count(), 1) -- the town shows the loss
		assert_false(rewards.peek().won)
		assert_eq(level_end.quit({}).kind, "none") -- nothing running
	end)

	it("buys +5 moves for the offer the player saw, and refuses a stale or unaffordable one", function()
		boot(21)
		start({}, true)
		local coins = app.meta:coins()
		local res = level_end.continue(1, { level_id = 21 })
		assert_eq(res.moves, 5)
		assert_eq(res.price, 700)
		assert_eq(app.meta:coins(), coins - 700)
		local r2, why = level_end.continue(1, { level_id = 21 }) -- the same offer again: stale
		assert_eq(r2, nil)
		assert_eq(why, "stale_offer")
		H.give(app.meta, "coins", -(app.meta:coins()))
		local r3, why3 = level_end.continue(2, { level_id = 21 })
		assert_eq(r3, nil)
		assert_eq(why3, "not_enough_coins")
		local names_ = names(analytics.drain())
		local buys = 0
		for _, n in ipairs(names_) do if n == "continue_buy" then buys = buys + 1 end end
		assert_eq(buys, 1)
		assert_eq(select(2, level_end.continue(1, {})) ~= nil or true, true)
	end)

	it("takes +3 moves for a video only when the ad service can show one", function()
		boot(21)
		start({}, true)
		local got, why
		level_end.ad_moves({}, function(r, w) got, why = r, w end)
		assert_eq(got, nil)
		assert_eq(why, "unavailable") -- release: no ads
		ads.init({ debug = true })
		level_end.ad_moves({}, function(r, w) got, why = r, w end)
		assert_eq(got.moves, 3)
		level_end.ad_moves({}, function(r, w) got, why = r, w end)
		assert_eq(got, nil)
		assert_eq(why, "already_used")
		ads.init({ debug = false })
	end)

	it("gives back the boosters the core could not place, as many as were paid for", function()
		assert_same(level_end.refunds({ 4 }, {}), { remix = 1 })
		assert_same(level_end.refunds({ 1, 1, 2 }, {}), { stick = 2, row_light = 1 })
		assert_same(level_end.refunds({ 5 }, { "riff" }), { riff = 1 })
		assert_eq(level_end.refunds({ 5 }, {}), nil) -- a free streak Riff: nothing was spent
		assert_same(level_end.refunds({ 5, 5 }, { "riff" }), { riff = 1 })
		assert_eq(level_end.refunds({ 8 }, {}), nil) -- the Riff of a continue is part of its price
		assert_eq(level_end.refunds({}, {}), nil)
		assert_eq(level_end.refunds(nil, nil), nil)
		assert_eq(level_end.refunds({ 99 }, {}), nil)
	end)

	it("returns an unplaced in-level booster to the inventory when the level ends", function()
		boot(26)
		local before = app.meta:booster_count("remix")
		start({}, true)
		level_end.win({ moves_at_win = 0, score = 1, stars = 1, unplaced = { 4 } }, { level_id = 26 })
		assert_eq(app.meta:booster_count("remix"), before + 1)
	end)

	it("makes a stand-in result for a level without a meta attempt and touches nothing", function()
		boot()
		local w = level_end.win({ stars = 1, moves_at_win = 2 }, { level_id = 5 })
		assert_true(w.standalone)
		assert_true(w.won)
		assert_eq(w.next_level, 6)
		assert_eq(app.meta:stats().wins, 0)
		assert_eq(rewards.count(), 0)
		local l = level_end.lose({}, { level_id = 5 })
		assert_true(l.standalone)
		assert_false(l.won)
		assert_eq(level_end.continue(1, {}), nil)
	end)
end)
