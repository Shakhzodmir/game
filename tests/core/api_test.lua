-- The public API (17.3): constructor options, queries and their shapes,
-- clones that share nothing, and the purity of every query.

local core = require("core.game")
local C = require("core.const")
local R = require("core.rng")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
local P1 = { "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }

local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or P1)
	return g
end

describe("core api: core.new and its options (17.3)", function()
	local lvl = H.load(FULL)

	it("returns nil and a list of messages for wrong options", function()
		local bad = {
			{}, { seed = 0 }, { seed = 1.5 }, { seed = "1" }, { seed = 2147483647 },
			{ seed = 1, attempt = -1 }, { seed = 1, salt = 1.5 }, { seed = 1, help = 3 }, { seed = 1, help = -1 },
			{ seed = 1, boosters = "riff" }, { seed = 1, boosters = { "stick" } }, { seed = 1, boosters = { "riff", "hammer" } },
			{ seed = 1, timing = "fast" }, { seed = 1, input_lock = 1 },
		}
		for k, opts in ipairs(bad) do
			local g, errs = core.new(lvl, opts)
			assert_eq(g, nil, "options " .. k)
			assert_true(type(errs) == "table" and #errs >= 1 and type(errs[1]) == "string", "messages " .. k)
		end
		local g, errs = core.new(nil, { seed = 1 })
		assert_eq(g, nil)
		assert_true(#errs >= 1)
	end)

	it("accepts the documented defaults and the full range of choices", function()
		for _, opts in ipairs({
			{ seed = 1 }, { seed = 2147483646, attempt = 7, salt = 2147483646, help = 2, boosters = { "riff", "sub", "disco", "riff" },
				timing = "turbo", input_lock = true },
		}) do
			local g = core.new(lvl, opts)
			assert_true(g ~= nil)
		end
		local g = core.new(lvl, { seed = 4 })
		local rep = g:replay()
		assert_same({ rep.attempt, rep.salt, rep.help, rep.timing, rep.input_lock, rep.boosters }, { 0, 0, 0, "normal", false, {} })
		assert_eq(g:status().tick, 0)
	end)

	it("a game at tick 0 is at rest, with the start events silent", function()
		local g = core.new(lvl, { seed = 4 })
		assert_true(g:is_stable())
		assert_same(g:drain_events(), {})
		assert_true(g:has_move())
	end)

	it("the attempt seed of 3.1 is exported", function()
		assert_eq(core.attempt_seed(42, 1, 0), R.attempt_seed(42, 1, 0))
	end)
end)

describe("core api: pieces() and cells() (17.3)", function()
	it("pieces lists every slot object once, by ascending key, with exactly the documented fields", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgLlrg", "gbllrg", "byrMby", "yrgSyA" }, { goals = { { type = "collect", color = "red", count = 9 } } })
		local list = g:pieces()
		local prev = 0
		for _, p in ipairs(list) do
			local key = (p.y - 1) * 6 + p.x
			assert_true(key > prev, "ascending key")
			prev = key
		end
		-- 36 cells, the column covers four
		assert_eq(#list, 33)
		local by = {}
		for _, p in ipairs(list) do by[p.x .. "," .. p.y] = p end
		assert_same(by["1,1"], { id = 1, x = 1, y = 1, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0, hidden = false, pinned = false })
		assert_same(by["3,3"], { id = by["3,3"].id, x = 3, y = 3, kind = "blocker", item = "column", hp = 6, state = "idle", offx = 0, offy = 0, hidden = false, pinned = false })
		assert_eq(by["4,3"], nil, "the other cells of the column have no entry")
		assert_same(by["4,5"], { id = by["4,5"].id, x = 4, y = 5, kind = "mic", state = "idle", offx = 0, offy = 0, hidden = false, pinned = false })
		assert_same(by["4,6"], { id = by["4,6"].id, x = 4, y = 6, kind = "special", special = "sub", state = "idle", offx = 0, offy = 0, hidden = false, pinned = false })
		assert_same(by["6,6"], { id = by["6,6"].id, x = 6, y = 6, kind = "blocker", item = "balloon", color = "red", hp = 1, state = "idle", offx = 0, offy = 0, hidden = false, pinned = false })
	end)

	it("a Riff reports its axis; offsets, pins, hidden and states follow the object", function()
		local g = fresh({ "RVgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local o = H.obj_at(g, 3, 3)
		o.state, o.offx, o.offy = C.S_FALL, -360, 1200
		H.obj_at(g, 4, 3).pins = { 3 }
		local by = {}
		for _, p in ipairs(g:pieces()) do by[p.x .. "," .. p.y] = p end
		assert_same({ by["1,1"].special, by["1,1"].axis }, { "riff", "h" })
		assert_same({ by["2,1"].special, by["2,1"].axis }, { "riff", "v" })
		assert_same({ by["3,3"].state, by["3,3"].offx, by["3,3"].offy }, { "fall", -360, 1200 })
		assert_true(by["4,3"].pinned)
		assert_false(by["3,3"].pinned)
	end)

	it("cells() lists W*H entries with exists, spawner, exit, floor and wires; exits exist only with a deliver goal", function()
		local g = fresh(nil, { floor = { { at = { 2, 2 }, hp = 2 } }, overlay = { { at = { 0, 3 }, type = "wires", hp = 1 } } })
		local cells = g:cells()
		assert_eq(#cells, 36)
		assert_same(cells[1], { exists = true, spawner = true, exit = false, floor = 0, wires = 0 })
		assert_same(cells[15], { exists = true, spawner = false, exit = false, floor = 2, wires = 0 }, "(3,3)")
		assert_same(cells[19], { exists = true, spawner = false, exit = false, floor = 0, wires = 1 }, "(1,4)")
		assert_false(cells[31].exit)
		local d = fresh(nil, { goals = { { type = "deliver", count = 1 } }, mic = { total = 1, on_board_max = 1, gap_moves = 0 } })
		assert_true(d:cells()[31].exit)
		assert_false(d:cells()[25].exit)
	end)
end)

describe("core api: status() and result() (17.3)", function()
	it("status has exactly state, stuck, tick, moves_left, score and the goals' remainders in order", function()
		local g = fresh(nil, { goals = { { type = "collect", color = "red", count = 9 }, { type = "collect", color = "blue", count = 4 } } })
		assert_same(g:status(), { state = "playing", stuck = false, tick = 0, moves_left = 20, score = 0, goals = { 9, 4 } })
		local st = g:status()
		st.goals[1] = 0
		assert_eq(g:status().goals[1], 9, "a copy")
	end)

	it("result is nil while the game is on and a table once it is complete or lost", function()
		local g = fresh()
		for _, st in ipairs({ C.G_PLAYING, C.G_WON_WAIT, C.G_CONCERT, C.G_OUT }) do
			g.s.state = st
			assert_eq(g:result(), nil, "state " .. st)
		end
		g.s.state = C.G_COMPLETE
		assert_true(g:result().won)
		g.s.state = C.G_LOST
		assert_false(g:result().won)
	end)
end)

-- Every table reachable from a state, but the level.
local function collect_tables(root, skip, into)
	if type(root) ~= "table" or root == skip or into[root] then return end
	into[root] = true
	for _, v in pairs(root) do -- order-independent
		collect_tables(v, skip, into)
	end
end

describe("core api: clones (17.3)", function()
	it("share nothing with the original but the level, even in the middle of a busy tick", function()
		local lvl = H.load({ "#######", "#R#S#V#", "##D#B##", "#B#S#R#", "##V#D##", "#S#B#V#", "#######" },
			{ moves = 30, colors = { "red", "green", "blue", "yellow" }, goals = { { type = "collect", color = "green", count = 300 } } })
		local g = core.new(lvl, { seed = 11, boosters = { "riff" } })
		g:run_to_rest()
		g:input({ type = "tap", at = { 4, 2 } }) -- the Sabwoofer
		for _ = 1, 2 do g:step() end
		assert_true(#g.s.queue > 0 and next(g.s.sources) ~= nil, "a busy moment")
		local c = g:clone()
		local mine, theirs = {}, {}
		collect_tables(g.s, g.s.level, mine)
		collect_tables(c.s, g.s.level, theirs)
		for t in pairs(theirs) do -- order-independent
			assert_true(not mine[t], "a table is shared with the clone")
		end
		assert_true(c.s.level == g.s.level)
		assert_eq(c:hash(), g:hash())
		-- a long run of the clone does not touch the original
		local h = g:hash()
		c:run_to_rest()
		assert_eq(g:hash(), h)
	end)

	it("a reseeded clone differs only in the three streams it renews", function()
		local g = fresh()
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		for _ = 1, 5 do g:step() end
		local plain, re = g:clone(), g:clone({ reseed = 3 })
		for k = 1, 4 do
			local same = table.concat(plain.s.rng[k], ",") == table.concat(re.s.rng[k], ",")
			assert_eq(same, k == R.INIT, "stream " .. k)
		end
		re.s.rng[R.SPAWN], re.s.rng[R.EFFECTS], re.s.rng[R.SHUFFLE] = plain.s.rng[R.SPAWN], plain.s.rng[R.EFFECTS], plain.s.rng[R.SHUFFLE]
		assert_eq(re:hash(), plain:hash())
		-- the folded seed uses the act of the moment
		local seed = R.fold_seed(g.s.header.seed, g.s.act, 3)
		assert_same(g:clone({ reseed = 3 }).s.rng[R.SPAWN], R.stream(seed, R.SPAWN))
	end)

	it("a bot looks ahead only on reseeded clones: the spawn colours of the real game stay hidden", function()
		local function future(game)
			game:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
			game:run_to_rest()
			return table.concat(H.picture(game), "/")
		end
		local g = fresh()
		local real = future(g:clone()) -- the same game, same streams: the same future
		assert_eq(future(g:clone()), real)
		assert_eq(future(g), real)
		local differs = 0
		for k = 1, 4 do
			if future(fresh():clone({ reseed = k })) ~= real then differs = differs + 1 end
		end
		assert_true(differs >= 3, "reseeded clones draw their own colours")
		-- and the same reseed is repeatable
		assert_eq(future(fresh():clone({ reseed = 2 })), future(fresh():clone({ reseed = 2 })))
	end)

	it("clones of a clone and the original keep apart; the replay of a clone continues the history", function()
		local g = fresh()
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		local c = g:clone()
		c:run_to_rest()
		c:input({ type = "booster", booster = "stick", at = { 2, 2 } })
		assert_eq(#g:replay().commands, 1)
		assert_eq(#c:replay().commands, 2)
	end)

	it("set_timing('turbo') on a clone does not change the original, and set_timing rejects other names", function()
		local g = fresh()
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		local c = g:clone()
		c:set_timing("turbo")
		assert_eq(g.s.timing, C.TIMING_NORMAL)
		assert_eq(g.s.swaps[1].due, 11)
		assert_error(function() c:set_timing("warp") end, "set_timing")
	end)
end)

describe("core api: turbo switch (15.1.8)", function()
	it("clamps every timer to now + its turbo value, renumbers the records, zeroes the delays", function()
		local g = fresh({ "byrgby", "_rgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g:step() -- a spawn falls with a delay; tick 1
		g:input({ type = "swap", from = { 3, 2 }, to = { 4, 2 } })
		g.s.queue[#g.s.queue + 1] = { due = 40, seq = 9, kind = C.R_CONCERT_B, d = {} }
		g.s.queue[#g.s.queue + 1] = { due = 3, seq = 12, kind = C.R_CONCERT_A, d = { 1 } }
		table.sort(g.s.queue, function(a, b) return a.due < b.due or (a.due == b.due and a.seq < b.seq) end)
		g.s.seq = 30
		local lock = H.obj_at(g, 1, 6)
		lock.state, lock.tk, lock.td = C.S_SWAP, C.TM_LOCK, 31
		local clear = H.obj_at(g, 2, 6)
		clear.state, clear.tk, clear.td = C.S_CLEAR, C.TM_CLEAR, 12
		local faller = H.obj_at(g, 1, 1)
		faller.delay = 5
		g:set_timing("turbo")
		-- now = tick + 1 = 2
		assert_eq(lock.td, 3, "shuffle lock: now + 1")
		assert_eq(clear.td, 3, "clear: now + 1")
		assert_eq(g.s.swaps[1].due, 3, "swap: now + 1")
		assert_eq(faller.delay, 0)
		assert_same({ g.s.queue[1].due, g.s.queue[1].seq, g.s.queue[2].due, g.s.queue[2].seq }, { 2, 1, 2, 2 })
		assert_eq(g.s.seq, #g.s.queue)
		assert_eq(g.s.queue[1].kind, C.R_CONCERT_A, "the earlier record stays first")
	end)

	it("never lengthens a timer that is already shorter", function()
		local g = fresh()
		g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) -- a failed swap: 14 ticks
		g:step()
		g:set_timing("turbo")
		assert_eq(g.s.swaps[1].due, 3)
		local g2 = fresh()
		g2:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		for _ = 1, 9 do g2:step() end -- the swap ends in tick 11, now = 10
		g2:set_timing("turbo")
		assert_eq(g2.s.swaps[1].due, 11, "min(11, 10 + 1)")
	end)
end)

describe("core api: run_to_rest (17.3)", function()
	it("returns the number of ticks; the limit itself is allowed, one tick more is an error", function()
		local function game()
			local g = fresh()
			g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
			return g
		end
		local n = game():run_to_rest()
		assert_true(n > 20)
		assert_eq(game():run_to_rest(n), n)
		assert_error(function() game():run_to_rest(n - 1) end, "run_to_rest")
		assert_eq(game():run_to_rest(n + 5), n)
	end)
end)
