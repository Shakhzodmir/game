-- Rest, end of move, noise, shuffle (11, 12.2) and the end of the level (13).

local C = require("core.const")
local R = require("core.rng")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
local P1 = { "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }

local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or P1)
	return g
end

local function types(ev)
	local out = {}
	for _, e in ipairs(ev) do out[#out + 1] = e.type end
	return out
end

describe("core flow: rest (11)", function()
	it("rest_flag follows the board: cleared by commands, set again at rest", function()
		local g = fresh()
		g:step()
		assert_true(g.s.rest_flag)
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		assert_false(g.s.rest_flag)
		g:step()
		assert_false(g.s.rest_flag)
		local n = g:run_to_rest()
		assert_true(n > 20)
		assert_true(g.s.rest_flag)
		assert_true(g:is_stable())
		assert_eq(g:run_to_rest(), 0)
	end)

	it("clears the end-of-move queue at rest and goes out of moves at 0", function()
		local g = fresh(nil, { moves = 5 })
		g.s.moves_left = 1
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		g:run_to_rest()
		assert_same(g.s.eom, {})
		assert_eq(g:status().state, "out_of_moves")
		assert_false(g:status().stuck)
		local st = H.of_type(g:drain_events(), "state")
		assert_same(st[#st], { t = g.s.tick, type = "state", state = "out_of_moves" })
		assert_true(g.s.rest_flag, "boosters stay possible")
	end)
end)

describe("core flow: noise growth (11)", function()
	local ROWS = { "rrgrby", "yrgbyr", "rgNyrg", "gbyrgb", "byrgby", "yrggbg" }

	it("grows one noise per queued action that did not hit noise", function()
		local g = fresh(ROWS)
		local copy = { unpack(g.s.rng[R.EFFECTS]) }
		g:input({ type = "swap", from = { 5, 6 }, to = { 6, 6 } })
		g:run_to_rest()
		local ev = H.of_type(g:drain_events(), "noise_spread")
		assert_eq(#ev, 1)
		-- pairs: noise (3,3) with (3,2) up, (2,3) left, (4,3) right, (3,4) down
		local n = R.int(copy, 4)
		local want = ({ { 3, 2 }, { 2, 3 }, { 4, 3 }, { 3, 4 } })[n]
		assert_same({ ev[1].fx, ev[1].fy, ev[1].x, ev[1].y }, { 3, 3, want[1], want[2] })
		local p = g.s.objs[ev[1].id]
		assert_same({ p.kind, p.blocker, p.hp }, { C.K_BLOCKER, C.BK_NOISE, 1 })
	end)

	it("does not grow after an action whose cascade hit noise", function()
		local g = fresh({ "rrgNby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		g:run_to_rest()
		local ev = g:drain_events()
		assert_eq(#H.of_type(ev, "noise_spread"), 0)
		assert_eq(#H.of_type(ev, "destroy"), 1)
	end)

	it("credits an action merged into a credited one (1.3.10)", function()
		local g = fresh(ROWS)
		g.s.eom = { { a = 1, noise_hit = false, merged = 2 }, { a = 2, noise_hit = true, merged = 0 },
			{ a = 3, noise_hit = false, merged = 0 } }
		g:step()
		assert_eq(#H.of_type(g:drain_events(), "noise_spread"), 1, "only action 3 grows noise")
		assert_same(g.s.eom, {})
	end)

	it("never grows onto spawner cells or wired pieces", function()
		local g = fresh({ "rrNrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
		g.s.wires[9] = 1 -- (3,2) under the noise
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		g:step()
		assert_same(H.of_type(g:drain_events(), "noise_spread"), {})
	end)
end)

describe("core flow: shuffle (12.2)", function()
	it("shuffles a board without moves at rest and locks the moved pieces", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_false(g:has_move())
		g:step()
		local ev = g:drain_events()
		assert_same(types(ev), { "shuffle" })
		assert_eq(ev[1].duration, 30)
		assert_true(#ev[1].moves > 0)
		local o = g.s.objs[ev[1].moves[1].id]
		assert_same({ o.state, o.tk, o.td }, { C.S_SWAP, C.TM_LOCK, 31 })
		assert_false(g.s.rest_flag)
		assert_eq(g.s.moves_left, 20, "no move spent")
		for _ = 1, 30 do g:step() end
		assert_eq(o.state, C.S_IDLE)
		assert_eq(o.settle, 31)
		assert_true(g:has_move())
	end)

	it("falls back to a Riff from a wired piece, then from noise, then gets stuck", function()
		local g = fresh({ "MMMMMM", "MMMMMM", "MMMrMM", "MMMMMM", "MMMMMM", "MMMMMM" })
		g.s.wires[16] = 1
		g:step()
		local ev = g:drain_events()
		assert_same(types(ev), { "freed", "shuffle" })
		assert_same(ev[2].riff, { id = 16, x = 4, y = 3, from = "wires" })
		assert_eq(g.s.wires[16], 0)
		assert_eq(g.s.objs[16].special, C.SP_RIFF)

		local g2 = fresh({ "MMMMMM", "MMMMMM", "MMMNMM", "MMMMMM", "MMMMMM", "MMMMMN" }, {
			goals = { { type = "break", item = "noise", count = 1 } },
			slots = { { at = { 0, 0 }, type = "noise" } },
		})
		g2:step()
		ev = g2:drain_events()
		assert_same(types(ev), { "destroy", "shuffle" }, "not the last noise: no goal")

		local g3 = fresh({ "MMMMMM", "MMMMMM", "MMMNMM", "MMMMMM", "MMMMMM", "MMMMMM" }, {
			goals = { { type = "break", item = "noise", count = 1 } },
			slots = { { at = { 0, 0 }, type = "noise" } },
		})
		g3:step()
		ev = g3:drain_events()
		assert_same(types(ev), { "destroy", "goal", "state", "shuffle" }, "the last noise counts")

		local g4 = fresh({ "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM" })
		g4:step()
		ev = g4:drain_events()
		assert_same(ev, { { t = 1, type = "state", state = "out_of_moves", reason = "stuck" } })
		assert_true(g4:status().stuck)
		assert_same({ g4:input({ type = "continue", moves = 5 }) }, { false, "no_candidates" })
	end)

	it("remix shuffles at execution and reports ok = false with fewer than two candidates", function()
		local g = fresh()
		g:step()
		assert_same({ g:input({ type = "booster", booster = "remix" }) }, { true, "ok" })
		g:step()
		local ev = g:drain_events()
		assert_eq(ev[1].type, "booster")
		assert_true(ev[1].ok)
		assert_eq(ev[2].type, "shuffle")
		local g2 = fresh()
		g2:step()
		g2:input({ type = "booster", booster = "remix" })
		H.board(g2, { "MMMMMM", "MMMMMM", "MMMrMM", "MMMMMM", "MMMMMM", "MMMMMM" })
		g2:step()
		assert_same(g2:drain_events()[1], { t = 2, type = "booster", booster = "remix", ok = false })
		assert_same(g2.s.unplaced, { C.IT_REMIX })
	end)
end)

describe("core flow: win and final concert (13)", function()
	local function winning_game(moves_left, timing)
		local g = fresh(nil, { goals = { { type = "collect", color = "red", count = 3 } } }, { timing = timing })
		g.s.moves_left = moves_left
		g.s.goal_left = { 3 }
		return g
	end

	it("goes to won_wait at the last goal, then to concert at rest with phase records", function()
		local g = winning_game(4)
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		for _ = 1, 11 do g:step() end
		local ev = g:drain_events()
		local k = 0
		for i, e in ipairs(ev) do
			if e.type == "state" then k = i end
		end
		assert_same(ev[k], { t = 11, type = "state", state = "won_wait" })
		assert_same({ ev[k - 1].type, ev[k - 1].left }, { "goal", 0 })
		assert_same({ g:input({ type = "swap", from = { 5, 6 }, to = { 6, 6 } }) }, { false, "bad_state" })
		-- run until the concert starts
		while g.s.state == C.G_WON_WAIT do g:step() end
		local s = g.s
		local tc = s.tick
		assert_eq(s.tc, tc)
		assert_eq(s.moves_at_win, 3)
		assert_eq(s.concert_A, 1)
		local q = {}
		for _, r in ipairs(s.queue) do q[#q + 1] = { r.due, r.kind, r.d[1] or 0 } end
		assert_same(q, {
			{ tc + 2, C.R_CONCERT_A, 1 }, { tc + 4, C.R_CONCERT_A, 2 }, { tc + 6, C.R_CONCERT_A, 3 },
			{ tc + 9, C.R_CONCERT_B, 0 },
		})
		g:step()
		g:step()
		ev = g:drain_events()
		assert_same(types(ev), { "moves", "concert_riff", "score" })
		local riff = s.objs[ev[2].id]
		assert_same({ riff.special, riff.axis, riff.mv, riff.wv }, { C.SP_RIFF, C.AX_H, 2, 0 })
		assert_eq(ev[3].delta, 300)
	end)

	it("plays the concert to complete and reports the result", function()
		local g = winning_game(2)
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		local n = 0
		while g.s.state ~= C.G_COMPLETE do
			g:step()
			n = n + 1
			assert_true(n < 5000, "concert must end")
		end
		assert_eq(g.s.moves_left, 0)
		local r = g:result()
		assert_eq(r.moves_at_win, 2)
		assert_eq(r.stars, 1)
		assert_true(r.won)
		assert_true(r.score >= 600)
		assert_same(r.unplaced, {})
		assert_eq(g.s.rounds >= 1, true)
	end)

	it("skip switches the concert to turbo", function()
		local g = winning_game(3)
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		while g.s.state ~= C.G_CONCERT do g:step() end
		assert_same({ g:input({ type = "skip" }) }, { true, "ok" })
		assert_eq(g.s.queue[1].due, g.s.tick + 1)
		local n = 0
		while g.s.state ~= C.G_COMPLETE do
			g:step()
			n = n + 1
		end
		assert_true(n < 60, "turbo concert is quick: " .. n)
	end)
end)
