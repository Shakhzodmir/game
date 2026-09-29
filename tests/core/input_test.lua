local C = require("core.const")
local MV = require("core.moves")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }

-- No match anywhere; (3,1)-(4,1) makes red (1..3, 1).
local P1 = { "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }

local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or P1)
	return g
end

describe("core input: command validation (5.0)", function()
	it("rejects malformed commands with bad_cmd", function()
		local g = fresh()
		local bad = {
			"swap", {}, { type = "dance" },
			{ type = "swap", from = { 1, 1 } },
			{ type = "swap", from = { 1, 1 }, to = { 1.5, 1 } },
			{ type = "swap", from = { 1, "1" }, to = { 2, 1 } },
			{ type = "tap" },
			{ type = "booster", booster = "hammer" },
			{ type = "booster", booster = "stick" },
			{ type = "booster", booster = "row_light", row = 7 },
			{ type = "booster", booster = "col_light", col = 0 },
			{ type = "continue", moves = 0 },
			{ type = "continue", moves = 61 },
			{ type = "continue", moves = 5, riff = "yes" },
		}
		for _, cmd in ipairs(bad) do
			local ok, why = g:input(cmd)
			assert_false(ok)
			assert_eq(why, "bad_cmd")
		end
		assert_same(g:drain_events(), {})
		assert_same(g.s.cmds, {})
	end)

	it("checks the reasons in order: bad_cmd, bad_state, no_moves, not_rest, bad_cell, not_movable", function()
		local g = fresh()
		g.s.state = C.G_OUT
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 2.5, 1 } }) }, { false, "bad_cmd" })
		assert_same({ g:input({ type = "swap", from = { 9, 9 }, to = { 9, 8 } }) }, { false, "bad_state" })
		g.s.state = C.G_PLAYING
		g.s.moves_left = 0
		assert_same({ g:input({ type = "swap", from = { 9, 9 }, to = { 9, 8 } }) }, { false, "no_moves" })
		assert_same({ g:input({ type = "tap", at = { 1, 1 } }) }, { false, "no_moves" })
		g.s.moves_left = 5
		assert_same({ g:input({ type = "swap", from = { 9, 9 }, to = { 9, 8 } }) }, { false, "bad_cell" })
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 3, 1 } }) }, { false, "bad_cell" }, "not adjacent")
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 0, 1 } }) }, { false, "bad_cell" }, "regular to outside")
		assert_same({ g:input({ type = "tap", at = { 1, 1 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "tap", at = { 0, 1 } }) }, { false, "bad_cell" })
	end)

	it("state table: continue/give_up only out of moves, skip only after the win", function()
		local g = fresh()
		assert_same({ g:input({ type = "continue", moves = 5 }) }, { false, "bad_state" })
		assert_same({ g:input({ type = "give_up" }) }, { false, "bad_state" })
		assert_same({ g:input({ type = "skip" }) }, { false, "bad_state" })
		g.s.state = C.G_WON_WAIT
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 1, 1 } }) }, { false, "bad_state" })
		assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) }, { false, "bad_state" })
	end)

	it("not_movable: empty slot, blocker, wired, pinned or busy pieces", function()
		local g = fresh({ "r_grby", "yXgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "swap", from = { 2, 1 }, to = { 3, 1 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "swap", from = { 1, 2 }, to = { 2, 2 } }) }, { false, "not_movable" })
		g.s.wires[13] = 1 -- (1,3)
		assert_same({ g:input({ type = "swap", from = { 1, 3 }, to = { 2, 3 } }) }, { false, "not_movable" })
		H.obj_at(g, 3, 3).pins = { 7 }
		assert_same({ g:input({ type = "swap", from = { 3, 3 }, to = { 4, 3 } }) }, { false, "not_movable" })
		H.obj_at(g, 5, 5).state = C.S_FALL
		assert_same({ g:input({ type = "swap", from = { 4, 5 }, to = { 5, 5 } }) }, { false, "not_movable" })
	end)
end)

describe("core input: swap (5.1)", function()
	it("accepts a matching swap: counters, action, timers, events, replay", function()
		local g = fresh()
		local ok, res = g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		assert_true(ok)
		assert_eq(res, "ok")
		local s = g.s
		assert_eq(s.act, 1)
		assert_eq(s.moves_left, 19)
		assert_eq(s.moves_made, 1)
		assert_same(s.eom, { { a = 1, noise_hit = false, merged = 0 } })
		assert_false(s.rest_flag)
		for _, x in ipairs({ 3, 4 }) do
			local o = H.obj_at(g, x, 1)
			assert_eq(o.state, C.S_SWAP)
			assert_eq(o.tk, C.TM_SWAP)
			assert_eq(o.td, 11)
		end
		assert_eq(#s.swaps, 1)
		assert_same({ s.swaps[1].kind, s.swaps[1].a, s.swaps[1].from, s.swaps[1].to, s.swaps[1].due }, { 1, 1, 3, 4, 11 })
		assert_same(g:drain_events(), {
			{ t = 1, type = "swap", a = { 3, 1 }, b = { 4, 1 }, ids = { 3, 4 }, duration = 10 },
			{ t = 1, type = "moves", left = 19 },
		})
		assert_same(s.cmds, { { tick = 1, cmd = { type = "swap", from = { 3, 1 }, to = { 4, 1 } } } })
	end)

	it("a swap without a match is a failed swap: bounce, no action, no move", function()
		local g = fresh()
		local ok, res = g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } })
		assert_true(ok)
		assert_eq(res, "fail")
		local s = g.s
		assert_eq(s.act, 0)
		assert_eq(s.moves_left, 20)
		assert_same(s.eom, {})
		assert_false(s.rest_flag, "any accepted swap clears rest_flag")
		assert_eq(H.obj_at(g, 5, 5).tk, C.TM_FAIL)
		assert_eq(H.obj_at(g, 5, 5).td, 15)
		assert_same(g:drain_events(), {
			{ t = 1, type = "swap_fail", a = { 5, 5 }, b = { 6, 5 }, ids = { 29, 30 }, duration = 14 },
		})
		assert_eq(#s.cmds, 1, "failed swaps are recorded")
		for _ = 1, 14 do g:step() end
		assert_eq(H.obj_at(g, 5, 5).state, C.S_SWAP, "tick 14: still bouncing")
		g:step()
		assert_eq(H.obj_at(g, 5, 5).state, C.S_IDLE, "tick 15 = 1 + T.swap_fail")
		assert_eq(H.obj_at(g, 5, 5).settle, 15)
		assert_eq(H.obj_at(g, 5, 5).color, 5, "no exchange")
		assert_eq(#H.of_type(g:drain_events(), "swap_back"), 0)
	end)

	it("two mics or two pieces of one colour always bounce", function()
		local g = fresh({ "MMgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }) }, { true, "fail" })
		-- (1,2)-(2,2) are both red and a red piece is falling into (3,2) that
		-- makes a line through (2,2) on the expected board
		local g2 = fresh({ "rrgrby", "rr_byr", "gbbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local s = g2.s
		local B = require("core.board")
		local o = B.new_obj(s, C.K_REGULAR, { color = 1, state = C.S_FALL, offy = 3600, vy = 300 })
		B.place(s, o, 9)
		assert_same({ g2:input({ type = "swap", from = { 1, 2 }, to = { 2, 2 } }) }, { true, "fail" })
	end)

	it("judges the swap on the expected board: falling pieces at their target cells", function()
		-- (2,2) is empty now; a red piece is falling into it
		local g = fresh({ "byrgby", "r_grby", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_eq(g:can_swap({ 3, 2 }, { 4, 2 }), "fail")
		local B = require("core.board")
		local o = B.new_obj(g.s, C.K_REGULAR, { color = 1, state = C.S_FALL, offy = 3600, vy = 300 })
		B.place(g.s, o, 8)
		assert_eq(g:can_swap({ 3, 2 }, { 4, 2 }), "ok")
		assert_same({ g:input({ type = "swap", from = { 3, 2 }, to = { 4, 2 } }) }, { true, "ok" })
	end)

	it("puts swapping pieces at their destination on the expected board", function()
		local g = fresh()
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		local col = MV.expected_colors(g.s)
		assert_eq(col[3], 1, "red arrives in (3,1)")
		assert_eq(col[4], 4, "green arrives in (4,1)")
		g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } })
		col = MV.expected_colors(g.s)
		assert_eq(col[29], 5, "a failed swap stays in place")
	end)

	it("a special swapped with any movable piece is accepted without a match", function()
		local g = fresh({ "Rbygby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }) }, { true, "ok" })
		assert_eq(g.s.moves_left, 19)
	end)

	it("a special swiped off the board, into a void, blocker or wires is a tap (5.1.5)", function()
		local g = fresh({ "Rbygby", "yXgbyr", "rSbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local swipe = { type = "swap", from = { 1, 1 }, to = { 0, 1 } }
		assert_same({ g:input(swipe) }, { true, "ok" })
		local s = g.s
		local riff = H.obj_at(g, 1, 1)
		assert_eq(riff.state, C.S_ARMED)
		assert_eq(s.act, 1)
		assert_eq(s.moves_left, 19)
		assert_same(s.eom, { { a = 1, noise_hit = false, merged = 0 } })
		assert_eq(#s.queue, 1)
		assert_same({ s.queue[1].due, s.queue[1].kind, s.queue[1].d }, { 1, C.R_ACTIVATE, { riff.id, 1, 0, 1, 1, 0 } })
		assert_same(s.cmds[1].cmd, swipe, "the replay keeps the swap command")
		assert_same(g:drain_events(), { { t = 1, type = "moves", left = 19 } })
		-- into a blocker
		assert_same({ g:input({ type = "swap", from = { 2, 3 }, to = { 2, 2 } }) }, { true, "ok" })
		assert_eq(H.obj_at(g, 2, 3).state, C.S_ARMED)
	end)

	it("can_swap answers like input would, without changing anything", function()
		local g = fresh()
		local h = g:hash()
		assert_eq(g:can_swap({ 3, 1 }, { 4, 1 }), "ok")
		assert_eq(g:can_swap({ 5, 5 }, { 6, 5 }), "fail")
		assert_eq(g:can_swap({ 1, 1 }, { 0, 1 }), "reject")
		assert_eq(g:can_swap({ 1, 1 }, { 3, 1 }), "reject")
		assert_eq(g:hash(), h)
		assert_same(g:drain_events(), {})
		g.s.moves_left = 0
		assert_eq(g:can_swap({ 3, 1 }, { 4, 1 }), "reject")
	end)

	it("input_lock accepts swaps and taps only at rest", function()
		local g = fresh(P1, nil, { input_lock = true })
		assert_same({ g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) }, { true, "fail" })
		assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) }, { false, "not_rest" })
		g:run_to_rest()
		assert_true(g.s.rest_flag)
		assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) }, { true, "ok" })
	end)
end)

describe("core input: tap (5.2)", function()
	it("arms the special at once and queues its activation at now with (a, 1)", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgSyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g:step()
		g:drain_events()
		local sub = H.obj_at(g, 3, 3)
		assert_same({ g:input({ type = "tap", at = { 3, 3 } }) }, { true, "ok" })
		assert_eq(sub.state, C.S_ARMED)
		local s = g.s
		assert_same({ s.queue[1].due, s.queue[1].seq, s.queue[1].d }, { 2, 1, { sub.id, 15, 0, 1, 1, 0 } })
		assert_same(g:drain_events(), { { t = 2, type = "moves", left = 19 } })
		assert_same({ g:input({ type = "tap", at = { 3, 3 } }) }, { false, "not_movable" }, "already armed")
	end)
end)

describe("core input: boosters (5.3) and service commands (5.4)", function()
	it("needs rest; creates an action but spends no move", function()
		local g = fresh()
		g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } })
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 2, 2 } }) }, { false, "not_rest" })
		g:run_to_rest()
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 2, 2 } }) }, { true, "ok" })
		assert_eq(g.s.act, 1)
		assert_eq(g.s.moves_left, 20)
		assert_same(g.s.eom, {})
		assert_same({ g.s.queue[1].kind, g.s.queue[1].d }, { C.R_BOOSTER, { 1, 8, 1, 1 } })
	end)

	it("rejects a stick without effect and a light over a line without effect", function()
		local g = fresh({ "MMMMMM", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 1, 1 } }) }, { false, "bad_cell" })
		assert_same({ g:input({ type = "booster", booster = "row_light", row = 1 }) }, { false, "bad_cell" })
		assert_same({ g:input({ type = "booster", booster = "col_light", col = 1 }) }, { true, "ok" })
		local g2 = fresh({ "M_____", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g2.s.floor[2] = 1
		assert_same({ g2:input({ type = "booster", booster = "stick", at = { 3, 1 } }) }, { false, "bad_cell" })
		assert_same({ g2:input({ type = "booster", booster = "stick", at = { 2, 1 } }) }, { true, "ok" }, "empty slot over a tile")
	end)

	it("remix needs two candidates", function()
		local g = fresh({ "RSBDRS", "SBDRSB", "BDRSBD", "DRSBDR", "RSBDRS", "SBDRrS" })
		assert_same({ g:input({ type = "booster", booster = "remix" }) }, { false, "no_candidates" })
	end)

	it("a booster out of moves returns the game to playing", function()
		local g = fresh()
		g.s.state = C.G_OUT
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 1, 1 } }) }, { true, "ok" })
		assert_same(g:drain_events(), { { t = 1, type = "state", state = "playing" } })
	end)

	it("continue adds moves, may add a Riff, and is refused when stuck", function()
		local g = fresh()
		g.s.state = C.G_OUT
		g.s.moves_left = 0
		assert_same({ g:input({ type = "continue", moves = 5, riff = true }) }, { true, "ok" })
		assert_eq(g.s.moves_left, 5)
		local ev = g:drain_events()
		assert_eq(ev[1].type, "moves")
		assert_eq(ev[2].type, "continue_riff")
		assert_same(ev[3], { t = 1, type = "state", state = "playing" })
		local riff = g.s.objs[ev[2].id]
		assert_eq(riff.special, C.SP_RIFF)
		assert_eq(riff.axis, C.AX_H)
		g.s.state = C.G_OUT
		g.s.stuck = true
		assert_same({ g:input({ type = "continue", moves = 5 }) }, { false, "no_candidates" })
		assert_same({ g:input({ type = "give_up" }) }, { true, "ok" })
		assert_eq(g:status().state, "lost")
		assert_same(g:result(), { won = false, score = 0, moves_at_win = 0, stars = 0, unplaced = {} })
	end)

	it("skip switches to turbo: timers clamped, records moved to now", function()
		local g = fresh()
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		g.s.state = C.G_WON_WAIT
		assert_same({ g:input({ type = "skip" }) }, { true, "ok" })
		assert_eq(g.s.timing, C.TIMING_TURBO)
		assert_eq(g.s.swaps[1].due, 2)
		assert_eq(H.obj_at(g, 3, 1).td, 2)
		g:step()
		g:step()
		assert_eq(H.obj_at(g, 3, 1).color, 1, "the swap ended at tick 2")
	end)
end)
