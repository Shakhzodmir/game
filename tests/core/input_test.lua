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

describe("core input: the order of the refusal reasons (5.0)", function()
	local function reason(g, cmd)
		local ok, why = g:input(cmd)
		assert_false(ok, "should be refused: " .. tostring(cmd.type))
		return why
	end

	it("swap and tap: bad_cmd, bad_state, no_moves, not_rest, bad_cell, not_movable", function()
		for _, kind in ipairs({ "swap", "tap" }) do
			local function cmd(good)
				if kind == "swap" then
					return good and { type = "swap", from = { 1, 1 }, to = { 9, 9 } } or { type = "swap", from = { 1, 1 }, to = { 2.5, 1 } }
				end
				return good and { type = "tap", at = { 9, 9 } } or { type = "tap", at = { 1.5, 1 } }
			end
			-- everything wrong at once: the first reason in the list wins
			local g = fresh(P1, nil, { input_lock = true })
			g.s.state, g.s.moves_left, g.s.rest_flag = C.G_WON_WAIT, 0, false
			assert_eq(reason(g, cmd(false)), "bad_cmd", kind)
			assert_eq(reason(g, cmd(true)), "bad_state", kind)
			g.s.state = C.G_PLAYING
			assert_eq(reason(g, cmd(true)), "no_moves", kind)
			g.s.moves_left = 4
			assert_eq(reason(g, cmd(true)), "not_rest", kind)
			g.s.rest_flag = true
			assert_eq(reason(g, cmd(true)), "bad_cell", kind)
		end
		local g = fresh()
		assert_eq(reason(g, { type = "tap", at = { 1, 1 } }), "not_movable")
	end)

	it("swap: a missing `to` cell beats a missing mover; a far `to` is a bad cell, not a bad command", function()
		local g = fresh({ "_rgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		-- (1,1) is an empty slot: rule 3 (to does not exist) comes before rule 4 (nothing movable)
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 0, 1 } }) }, { false, "bad_cell" })
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "swap", from = { 0, 3 }, to = { 1, 3 } }) }, { false, "bad_cell" }, "from outside the field")
		assert_same({ g:input({ type = "swap", from = { 2, 2 }, to = { 2, 2 } }) }, { false, "bad_cell" }, "from == to")
		assert_same({ g:input({ type = "swap", from = { 2, 2 }, to = { 3, 3 } }) }, { false, "bad_cell" }, "diagonal")
	end)

	it("booster: bad_cmd before bad_state before not_rest before bad_cell / no_candidates", function()
		local g = fresh()
		g.s.state, g.s.rest_flag = C.G_WON_WAIT, false
		assert_eq(reason(g, { type = "booster", booster = "row_light", row = 99 }), "bad_cmd")
		assert_eq(reason(g, { type = "booster", booster = "nope" }), "bad_cmd")
		assert_eq(reason(g, { type = "booster", booster = "col_light" }), "bad_cmd")
		assert_eq(reason(g, { type = "booster", booster = "row_light", row = 2 }), "bad_state")
		g.s.state = C.G_PLAYING
		assert_eq(reason(g, { type = "booster", booster = "row_light", row = 2 }), "not_rest")
		assert_eq(reason(g, { type = "booster", booster = "stick", at = { 99, 99 } }), "not_rest")
		g.s.rest_flag = true
		assert_eq(reason(g, { type = "booster", booster = "stick", at = { 99, 99 } }), "bad_cell")
		assert_eq(reason(g, { type = "booster", booster = "stick", at = { 0, 1 } }), "bad_cell")
		local h = fresh({ "RSBDRS", "SBDRSB", "BDRSBD", "DRSBDR", "RSBDRS", "SBDRrS" })
		assert_eq(reason(h, { type = "booster", booster = "remix" }), "no_candidates")
	end)

	it("continue: bad_cmd before bad_state before no_candidates", function()
		local g = fresh()
		assert_eq(reason(g, { type = "continue", moves = 99 }), "bad_cmd")
		assert_eq(reason(g, { type = "continue", moves = 3, riff = 1 }), "bad_cmd")
		assert_eq(reason(g, { type = "continue", moves = 3 }), "bad_state")
		g.s.state, g.s.stuck = C.G_OUT, true
		assert_eq(reason(g, { type = "continue", moves = 3 }), "no_candidates")
		assert_eq(reason(g, { type = "continue", moves = 0 }), "bad_cmd")
		assert_eq(reason(g, { type = "continue", moves = 2.5 }), "bad_cmd")
		assert_same({ g:input({ type = "continue", moves = 1 }) }, { false, "no_candidates" })
		g.s.stuck = false
		assert_same({ g:input({ type = "continue", moves = 1 }) }, { true, "ok" })
		assert_same({ g:input({ type = "continue", moves = 1 }) }, { false, "bad_state" }, "playing now")
	end)

	it("moves of continue range over 1..60", function()
		for _, n in ipairs({ 1, 30, 60 }) do
			local g = fresh()
			g.s.state, g.s.moves_left = C.G_OUT, 0
			assert_same({ g:input({ type = "continue", moves = n }) }, { true, "ok" })
			assert_eq(g.s.moves_left, n)
		end
	end)

	it("give_up and skip have only the state check", function()
		local g = fresh()
		assert_eq(reason(g, { type = "give_up" }), "bad_state")
		assert_eq(reason(g, { type = "skip" }), "bad_state")
		g.s.state = C.G_CONCERT
		assert_same({ g:input({ type = "skip" }) }, { true, "ok" })
		assert_same({ g:input({ type = "skip" }) }, { true, "ok" }, "skipping again is harmless")
		assert_eq(g.s.timing, C.TIMING_TURBO)
		assert_eq(reason(g, { type = "give_up" }), "bad_state")
		g.s.state = C.G_COMPLETE
		assert_eq(reason(g, { type = "skip" }), "bad_state")
	end)

	it("a refused command changes nothing: no event, no replay entry, the same hash", function()
		local g = fresh()
		local h = g:hash()
		for _, cmd in ipairs({
			{ type = "swap", from = { 1, 1 }, to = { 3, 1 } }, { type = "tap", at = { 1, 1 } }, { type = "skip" },
			{ type = "booster", booster = "stick", at = { 9, 9 } }, { type = "continue", moves = 3 }, { type = "swap" },
		}) do
			assert_false((g:input(cmd)))
		end
		assert_eq(g:hash(), h)
		assert_same(g:drain_events(), {})
		assert_same(g.s.cmds, {})
	end)
end)

describe("core input: coordinates and the replay record (5.0)", function()
	it("accepts {x, y} arrays and {x =, y =} tables alike", function()
		local g = fresh()
		assert_same({ g:input({ type = "swap", from = { x = 3, y = 1 }, to = { x = 4, y = 1 } }) }, { true, "ok" })
		assert_eq(g:can_swap({ x = 5, y = 5 }, { x = 6, y = 5 }), "fail")
		assert_eq(g:can_swap({ 5, 5 }, { x = 6, y = 5 }), "fail")
		-- a half-named table is no coordinate
		assert_same({ g:input({ type = "tap", at = { 3, y = 1 } }) }, { false, "bad_cmd" })
		assert_same({ g:input({ type = "tap", at = { x = 3 } }) }, { false, "bad_cmd" })
		assert_same({ g:input({ type = "tap", at = "3,1" }) }, { false, "bad_cmd" })
	end)

	it("records now = tick + 1 and a copy of the accepted command", function()
		local g = fresh()
		for _ = 1, 4 do g:step() end
		local cmd = { type = "swap", from = { 3, 1 }, to = { 4, 1 } }
		assert_same({ g:input(cmd) }, { true, "ok" })
		cmd.from[1] = 9 -- the caller's later edits must not rewrite the replay
		assert_same(g.s.cmds, { { tick = 5, cmd = { type = "swap", from = { 3, 1 }, to = { 4, 1 } } } })
		assert_eq(g:drain_events()[1].t, 5, "events of a command carry t = now")
	end)

	it("commands of one window apply in the order of the calls and all carry the same tick", function()
		local g = fresh()
		assert_same({ g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) }, { true, "fail" })
		assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) }, { true, "ok" })
		assert_same({ g:input({ type = "swap", from = { 1, 5 }, to = { 2, 5 } }) }, { true, "fail" })
		local ticks = {}
		for k, c in ipairs(g.s.cmds) do ticks[k] = c.tick end
		assert_same(ticks, { 1, 1, 1 })
		assert_eq(g.s.cmds[1].cmd.from[1], 5)
		assert_eq(g.s.cmds[3].cmd.from[1], 1)
	end)

	it("the counters follow the accepted swaps: act, moves_left, moves_made", function()
		local g = fresh(P1, nil, nil)
		g.s.moves_left = 2
		assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) }, { true, "ok" })
		assert_same({ g:input({ type = "swap", from = { 1, 5 }, to = { 2, 5 } }) }, { true, "fail" })
		assert_same({ g.s.act, g.s.moves_left, g.s.moves_made }, { 1, 1, 1 })
		assert_same({ g:input({ type = "swap", from = { 1, 2 }, to = { 1, 3 } }) }, { true, "ok" })
		assert_same({ g.s.act, g.s.moves_left, g.s.moves_made }, { 2, 0, 2 })
		assert_same({ g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) }, { false, "no_moves" })
		assert_same({ g:input({ type = "tap", at = { 1, 5 } }) }, { false, "no_moves" })
	end)
end)

describe("core input: swipe of a special and the cells of a swap (5.1.1, 5.1.5)", function()
	local SPECIAL_ROWS = { "Rbygby", "yXgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }

	-- Does a swap command run as a tap (the special is armed at once), as a swap (the pieces start to swap),
	-- as a failed swap, or is it refused (the reason)?
	local function outcome(g, cmd)
		local ok, res = g:input(cmd)
		if not ok then return res end
		if res == "fail" then return "fail" end
		if #g.s.swaps > 0 then return "swap" end
		return "tap"
	end

	it("a free special swiped over the edge, onto a void, an empty slot, a whole blocker or a wired piece is a tap", function()
		local rows = { "Rbygby", "SXgbyr", "rgbyrg", "gbyrgb", "byrgbR", "yrgbDy" }
		local cases = {
			{ { 1, 1 }, { 0, 1 }, "the left edge" },
			{ { 1, 2 }, { 0, 2 }, "the left edge of row 2 (no wrap to the row above)" },
			{ { 1, 1 }, { 1, 0 }, "the top edge" },
			{ { 6, 5 }, { 7, 5 }, "the right edge (no wrap to the row below)" },
			{ { 5, 6 }, { 5, 7 }, "the bottom edge" },
			{ { 1, 2 }, { 2, 2 }, "a whole blocker" },
			{ { 1, 1 }, { 2, 1 }, "an empty slot", function(g) g.s.slot[2] = 0 end },
			{ { 1, 2 }, { 1, 3 }, "a piece under wires", function(g) g.s.wires[13] = 1 end },
		}
		for _, c in ipairs(cases) do
			local g = fresh(rows)
			if c[4] then c[4](g) end
			assert_eq(g:can_swap(c[1], c[2]), "ok", c[3])
			assert_eq(outcome(g, { type = "swap", from = c[1], to = c[2] }), "tap", c[3])
			assert_eq(H.obj_at(g, c[1][1], c[1][2]).state, C.S_ARMED, c[3])
			assert_same({ g.s.act, g.s.moves_left, g.s.moves_made }, { 1, 19, 1 }, c[3])
			assert_same(g.s.eom, { { a = 1, noise_hit = false, merged = 0 } }, c[3])
			assert_same(g.s.cmds[1].cmd.to, c[2], "the replay keeps the swap command: " .. c[3])
		end
	end)

	it("a special swiped onto a void inside the field is a tap too", function()
		local g = H.game({ "######", "#.####", "######", "######", "######", "######" })
		H.board(g, { "byrgby", "S.gbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_eq(outcome(g, { type = "swap", from = { 1, 2 }, to = { 2, 2 } }), "tap")
		assert_eq(H.obj_at(g, 1, 2).state, C.S_ARMED)
	end)

	it("a special swapped with a piece, a mic or a special really swaps, also at the edges of the field", function()
		local rows = { "bRygby", "yrgbyr", "rgbMyr", "gbyrgb", "byrgbS", "yrgDby" }
		local cases = {
			{ { 2, 1 }, { 1, 1 }, "towards column 1" },
			{ { 2, 1 }, { 3, 1 }, "a piece to the right" },
			{ { 3, 3 }, { 4, 3 }, "a special and a mic" },
			{ { 6, 5 }, { 5, 5 }, "from the last column" },
			{ { 4, 6 }, { 5, 6 }, "in the last row" },
			{ { 6, 5 }, { 6, 6 }, "down to the last row" },
		}
		for _, c in ipairs(cases) do
			local g = fresh(rows)
			if c[3] == "a special and a mic" then g = fresh({ "bbygby", "yrgbyr", "rgSMyr", "gbyrgb", "byrgbS", "yrgDby" }) end
			assert_eq(outcome(g, { type = "swap", from = c[1], to = c[2] }), "swap", c[3])
			assert_eq(H.obj_at(g, c[1][1], c[1][2]).state, C.S_SWAP, c[3])
			assert_eq(#g.s.swaps, 1)
			assert_eq(g.s.swaps[1].kind, C.TM_SWAP)
		end
		-- two specials swap as well
		local g = fresh({ "bRSgby", "yrgbyr", "rgbMyr", "gbyrgb", "byrgbS", "yrgDby" })
		assert_eq(outcome(g, { type = "swap", from = { 2, 1 }, to = { 3, 1 } }), "swap")
	end)

	it("a blocker that is being destroyed is no empty slot and no piece: not_movable", function()
		local g = fresh({ "Rbygby", "SXgbyr", "rgbyrg", "gbyrgb", "byrgbR", "yrgbDy" })
		H.obj_at(g, 2, 2).state = C.S_CLEAR
		assert_eq(outcome(g, { type = "swap", from = { 1, 2 }, to = { 2, 2 } }), "not_movable")
	end)

	it("a failed swap keeps the zero label fields and action number in the swap list (the hash writes them)", function()
		local g = fresh()
		assert_same({ g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) }, { true, "fail" })
		local sw = g.s.swaps[1]
		assert_same({ sw.kind, sw.a, sw.from, sw.to, sw.m1, sw.w1, sw.m2, sw.w2, sw.due }, { C.TM_FAIL, 0, 29, 30, 0, 0, 0, 0, 15 })
	end)

	it("a special swapped with a piece, a mic, a special or a falling piece", function()
		local g = fresh({ "RbMgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_eq(g:can_swap({ 1, 1 }, { 2, 1 }), "ok")
		assert_eq(g:can_swap({ 2, 1 }, { 3, 1 }), "fail", "regular with a mic: no match")
		H.obj_at(g, 2, 1).state = C.S_FALL
		assert_eq(g:can_swap({ 1, 1 }, { 2, 1 }), "reject", "a falling piece is not movable")
	end)

	it("a pinned special neither swaps nor swipes: the cells are checked by 5.1.1.3 and 5.1.1.4", function()
		local g = fresh(SPECIAL_ROWS)
		local riff = H.obj_at(g, 1, 1)
		riff.pins = { 5 }
		g.s.sources[5] = { id = 5, nrec = 1 }
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 0, 1 } }) }, { false, "bad_cell" })
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "swap", from = { 2, 1 }, to = { 1, 1 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "tap", at = { 1, 1 } }) }, { false, "not_movable" })
		assert_eq(g.s.act, 0)
	end)

	it("tap: only a free special; a regular piece, a mic, an armed or a busy special are not movable", function()
		local g = fresh({ "RSMgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_same({ g:input({ type = "tap", at = { 3, 1 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "tap", at = { 4, 1 } }) }, { false, "not_movable" })
		H.obj_at(g, 2, 1).state = C.S_SWAP
		assert_same({ g:input({ type = "tap", at = { 2, 1 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "tap", at = { 1, 1 } }) }, { true, "ok" })
		assert_same({ g:input({ type = "tap", at = { 1, 1 } }) }, { false, "not_movable" }, "armed now")
		assert_same(g:drain_events(), { { t = 1, type = "moves", left = 19 } })
	end)
end)

describe("core input: continue, give up and the input lock (5.4, 5.0)", function()
	it("continue with a Riff draws once from the init stream and takes the candidate by index", function()
		local g = fresh()
		g.s.state, g.s.moves_left = C.G_OUT, 0
		local probe = H.stream_copy(g, 1)
		local before = g:hash()
		assert_true(before ~= nil)
		-- candidates: every regular idle piece without wires, by cell index (36 of them)
		local want = require("core.rng").int(probe, 36)
		assert_same({ g:input({ type = "continue", moves = 5, riff = true }) }, { true, "ok" })
		local ev = g:drain_events()
		assert_same({ ev[1].type, ev[2].type, ev[3].type }, { "moves", "continue_riff", "state" })
		assert_eq(ev[2].x + (ev[2].y - 1) * 6, want)
		assert_same(g.s.rng[1], probe, "exactly one output of the init stream")
		local riff = H.obj_at(g, ev[2].x, ev[2].y)
		assert_same({ riff.kind, riff.special, riff.axis, riff.color, riff.id, riff.state }, { C.K_SPECIAL, C.SP_RIFF, C.AX_H, 0, want, C.S_IDLE })
		assert_same({ riff.mv, riff.wv }, { 0, 0 }, "the label is kept")
	end)

	it("wired pieces are no candidates for the continue Riff; with none left it goes to unplaced", function()
		local g = fresh()
		g.s.state, g.s.moves_left = C.G_OUT, 0
		for i = 1, g.s.N do g.s.wires[i] = 1 end
		g.s.wires[7] = 0
		assert_same({ g:input({ type = "continue", moves = 3, riff = true }) }, { true, "ok" })
		assert_eq(H.obj_at(g, 1, 2).special, C.SP_RIFF, "the only candidate")
		g.s.state, g.s.moves_left = C.G_OUT, 0
		local probe = H.stream_copy(g, 1)
		g:drain_events()
		assert_same({ g:input({ type = "continue", moves = 3, riff = true }) }, { true, "ok" })
		assert_same(g.s.unplaced, { C.IT_CONT_RIFF })
		assert_same(g.s.rng[1], probe, "no candidates, no draw")
		local types = {}
		for k, e in ipairs(g:drain_events()) do types[k] = e.type end
		assert_same(types, { "moves", "state" })
	end)

	it("continue without a Riff only adds the moves and returns to playing", function()
		local g = fresh()
		g.s.state, g.s.moves_left = C.G_OUT, 0
		local probe = H.stream_copy(g, 1)
		assert_same({ g:input({ type = "continue", moves = 7 }) }, { true, "ok" })
		assert_same({ g:input({ type = "continue", moves = 7, riff = false }) }, { false, "bad_state" })
		assert_same(g.s.rng[1], probe)
		assert_eq(g.s.moves_left, 7)
		assert_eq(g.s.state, C.G_PLAYING)
		assert_eq(g.s.act, 0, "continue creates no action")
	end)

	it("give_up ends the level as lost, with one state event", function()
		local g = fresh()
		g.s.state = C.G_OUT
		assert_same({ g:input({ type = "give_up" }) }, { true, "ok" })
		assert_same(g:drain_events(), { { t = 1, type = "state", state = "lost" } })
		assert_eq(g.s.act, 0)
		assert_same({ g:input({ type = "give_up" }) }, { false, "bad_state" })
	end)

	it("input_lock: swap and tap only at rest, also the failed swap and the swipe", function()
		local g = fresh({ "Rbygby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }, nil, { input_lock = true })
		assert_true(g.s.rest_flag)
		assert_same({ g:input({ type = "tap", at = { 1, 1 } }) }, { true, "ok" })
		assert_false(g.s.rest_flag)
		assert_same({ g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) }, { false, "not_rest" })
		assert_same({ g:input({ type = "tap", at = { 1, 1 } }) }, { false, "not_rest" }, "not_rest comes before not_movable")
		assert_eq(g:can_swap({ 5, 5 }, { 6, 5 }), "reject")
		-- boosters are rest-gated in every mode
		local h = fresh(P1, nil, { input_lock = false })
		assert_same({ h:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) }, { true, "fail" })
		assert_same({ h:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) }, { true, "ok" }, "no lock: input while the board moves")
		assert_same({ h:input({ type = "booster", booster = "stick", at = { 1, 1 } }) }, { false, "not_rest" })
	end)
end)

describe("core input: edges of the commands (audit A)", function()
	it("a command that is not a table, or has no string type, is bad_cmd and never raises", function()
		local g = fresh()
		for _, cmd in ipairs({ 5, true, false, "swap", print, {}, { type = 5 }, { type = true }, { type = {} }, { swap = 1 } }) do
			assert_same({ g:input(cmd) }, { false, "bad_cmd" }, type(cmd))
		end
		assert_same({ g:input(nil) }, { false, "bad_cmd" })
		assert_same({ g:input() }, { false, "bad_cmd" })
	end)

	it("can_swap with a broken coordinate answers 'reject' instead of raising", function()
		local g = fresh()
		assert_eq(g:can_swap({ 1, 1 }, "x"), "reject")
		assert_eq(g:can_swap(nil, { 1, 2 }), "reject")
		assert_eq(g:can_swap({ 1, 1 }, { 1.5, 1 }), "reject")
		assert_eq(g:can_swap({ 1 }, { 2, 1 }), "reject")
		assert_eq(g:can_swap(), "reject")
	end)

	it("row_light and col_light take row 1..H and column 1..W, nothing outside", function()
		for _, row in ipairs({ 1, 6 }) do
			local g = fresh()
			assert_same({ g:input({ type = "booster", booster = "row_light", row = row }) }, { true, "ok" }, "row " .. row)
		end
		for _, col in ipairs({ 1, 6 }) do
			local g = fresh()
			assert_same({ g:input({ type = "booster", booster = "col_light", col = col }) }, { true, "ok" }, "col " .. col)
		end
		local g = fresh()
		for _, row in ipairs({ 0, 7, -1, 1.5 }) do
			assert_same({ g:input({ type = "booster", booster = "row_light", row = row }) }, { false, "bad_cmd" }, "row " .. row)
		end
		for _, col in ipairs({ 0, 7, -1, 2.5 }) do
			assert_same({ g:input({ type = "booster", booster = "col_light", col = col }) }, { false, "bad_cmd" }, "col " .. col)
		end
	end)

	it("an accepted booster clears rest_flag, takes the next action number and queues its record at now", function()
		local g = fresh()
		assert_true(g.s.rest_flag)
		assert_same({ g:input({ type = "booster", booster = "col_light", col = 3 }) }, { true, "ok" })
		assert_false(g.s.rest_flag)
		assert_same({ g.s.act, g.s.moves_left, g.s.moves_made, #g.s.eom }, { 1, 20, 0, 0 })
		assert_same({ g.s.queue[1].due, g.s.queue[1].kind, g.s.queue[1].d }, { 1, C.R_BOOSTER, { C.IT_COL, 3, 1, 1 } })
		local h = fresh()
		assert_same({ h:input({ type = "booster", booster = "remix" }) }, { true, "ok" })
		assert_same(h.s.queue[1].d, { C.IT_REMIX, 0, 1, 1 }, "the target of a Remix is 0")
		local r = fresh()
		assert_same({ r:input({ type = "booster", booster = "row_light", row = 4 }) }, { true, "ok" })
		assert_same(r.s.queue[1].d, { C.IT_ROW, 4, 1, 1 }, "a row light: its row number")
		local k = fresh()
		assert_same({ k:input({ type = "booster", booster = "stick", at = { 2, 3 } }) }, { true, "ok" })
		assert_same(k.s.queue[1].d, { C.IT_STICK, 14, 1, 1 }, "a stick: the cell index (2, 3)")
	end)

	it("Remix needs two candidates: two are enough, one is not", function()
		local rows = { "RSBDRS", "SBDRSB", "BDRSBD", "DRSBDR", "RSBDRS", "SBDRrr" }
		local g = fresh(rows)
		assert_same({ g:input({ type = "booster", booster = "remix" }) }, { true, "ok" })
		local rows1 = { "RSBDRS", "SBDRSB", "BDRSBD", "DRSBDR", "RSBDRS", "SBDRRr" }
		local h = fresh(rows1)
		assert_same({ h:input({ type = "booster", booster = "remix" }) }, { false, "no_candidates" })
	end)

	it("the switch to turbo reaches the object in cell 1 (id 1) and in the last cell", function()
		local g = fresh()
		for _, i in ipairs({ 1, 36 }) do
			local o = g.s.objs[g.s.slot[i]]
			o.state, o.tk, o.td = C.S_CLEAR, C.TM_CLEAR, 30
		end
		g.s.state = C.G_WON_WAIT
		assert_same({ g:input({ type = "skip" }) }, { true, "ok" })
		assert_eq(g.s.objs[g.s.slot[1]].td, 2)
		assert_eq(g.s.objs[g.s.slot[36]].td, 2)
		assert_eq(g.s.slot[1], 1, "the object in cell 1 has id 1")
	end)
end)
