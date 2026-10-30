-- In-level boosters (5.3): acceptance, rest flag, the booster record (15.2
-- kind 8) and the three effects: stick, row/column light, Remix.

local core = require("core.game")
local C = require("core.const")
local R = require("core.rng")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
local P1 = { "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }
local GAP = { "######", "######", "#.####", "######", "######", "######" }

local function fresh(rows, extra, opts, pic)
	local g = H.game(pic or FULL, extra, opts)
	H.board(g, rows or P1)
	return g
end

local function types(ev)
	local out = {}
	for _, e in ipairs(ev) do out[#out + 1] = e.type end
	return out
end

describe("core boosters: the rest flag (5.3)", function()
	it("is false after a swap, a failed swap, a tap or a booster, true again at rest", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgSyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g:step()
		assert_true(g.s.rest_flag)
		assert_same({ g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) }, { true, "fail" })
		assert_false(g.s.rest_flag, "a failed swap counts")
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 2, 2 } }) }, { false, "not_rest" })
		g:run_to_rest()
		assert_true(g.s.rest_flag)
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 2, 2 } }) }, { true, "ok" })
		assert_false(g.s.rest_flag, "a booster counts")
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 3, 2 } }) }, { false, "not_rest" }, "one per window")
		g:run_to_rest()
		assert_same({ g:input({ type = "tap", at = { 3, 3 } }) }, { true, "ok" })
		assert_false(g.s.rest_flag, "a tap counts")
	end)

	it("a rejected command leaves the flag alone, and so do continue and give_up", function()
		local g = fresh()
		g:step()
		assert_true(g.s.rest_flag)
		g:input({ type = "swap", from = { 1, 1 }, to = { 3, 1 } })
		g:input({ type = "booster", booster = "hammer" })
		assert_true(g.s.rest_flag)
		g.s.state, g.s.moves_left = C.G_OUT, 0
		assert_same({ g:input({ type = "continue", moves = 3 }) }, { true, "ok" })
		assert_true(g.s.rest_flag)
		g.s.state = C.G_OUT
		assert_same({ g:input({ type = "give_up" }) }, { true, "ok" })
		assert_true(g.s.rest_flag)
	end)

	it("is true at tick 0: the start board is at rest", function()
		local g = fresh()
		assert_true(g.s.rest_flag)
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 2, 2 } }) }, { true, "ok" })
	end)
end)

describe("core boosters: refusal reasons come in the order of 5.0", function()
	it("bad_cmd, bad_state, not_rest, bad_cell, no_candidates", function()
		local g = fresh()
		-- bad_cmd beats everything
		g.s.state = C.G_WON_WAIT
		g.s.rest_flag = false
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 1.5, 2 } }) }, { false, "bad_cmd" })
		assert_same({ g:input({ type = "booster", booster = "stick" }) }, { false, "bad_cmd" })
		assert_same({ g:input({ type = "booster", booster = "row_light", row = 0 }) }, { false, "bad_cmd" })
		assert_same({ g:input({ type = "booster", booster = "col_light", col = "3" }) }, { false, "bad_cmd" })
		assert_same({ g:input({ type = "booster", booster = 3 }) }, { false, "bad_cmd" })
		-- then bad_state
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 9, 9 } }) }, { false, "bad_state" })
		for _, st in ipairs({ C.G_CONCERT, C.G_LOST, C.G_COMPLETE }) do
			g.s.state = st
			assert_same({ g:input({ type = "booster", booster = "remix" }) }, { false, "bad_state" })
		end
		-- then not_rest
		g.s.state = C.G_PLAYING
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 9, 9 } }) }, { false, "not_rest" })
		-- then bad_cell (a cell outside the field, a cell without an effect)
		g.s.rest_flag = true
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 9, 9 } }) }, { false, "bad_cell" })
		-- then no_candidates for the Remix
		H.board(g, { "RSBDRS", "SBDRSB", "BDRSBD", "DRSBDR", "RSBDRS", "SBDRrS" })
		assert_same({ g:input({ type = "booster", booster = "remix" }) }, { false, "no_candidates" })
		assert_same(g.s.cmds, {}, "refused commands are not recorded")
	end)

	it("a cell has an effect when it holds wires, a blocker, a piece, a special, or is an empty slot over an unlit tile", function()
		local g = fresh({ "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM" })
		local function stick(x, y) return { g:input({ type = "booster", booster = "stick", at = { x, y } }) } end
		assert_same(stick(1, 1), { false, "bad_cell" }, "a mic has no effect")
		g.s.wires[1] = 1
		assert_same(stick(1, 1), { true, "ok" }, "wires")
		g:run_to_rest()
		H.board(g, { "XMMMMM", "MSMMMM", "MMrMMM", "M_MMMM", "MMMMMM", "MMMMMM" })
		g.s.floor[2] = 0
		assert_same(stick(1, 1), { true, "ok" }, "a blocker")
		g:run_to_rest()
		H.board(g, { "XMMMMM", "MSMMMM", "MMrMMM", "M_MMMM", "MMMMMM", "MMMMMM" })
		assert_same(stick(2, 2), { true, "ok" }, "a special")
		g:run_to_rest()
		H.board(g, { "XMMMMM", "MSMMMM", "MMrMMM", "M_MMMM", "MMMMMM", "MMMMMM" })
		assert_same(stick(3, 3), { true, "ok" }, "a regular piece")
		g:run_to_rest()
		H.board(g, { "XMMMMM", "MSMMMM", "MMrMMM", "M_MMMM", "MMMMMM", "MMMMMM" })
		assert_same(stick(2, 4), { false, "bad_cell" }, "an empty slot without a tile")
		g.s.floor[20] = 1
		assert_same(stick(2, 4), { true, "ok" }, "an empty slot over an unlit tile")
	end)
end)

describe("core boosters: the action (5.3, 15.2 kind 8)", function()
	it("creates an action for the labels but spends no move and joins no end-of-move queue", function()
		local g = fresh()
		g:step()
		g:drain_events()
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 1, 3 } }) }, { true, "ok" })
		local s = g.s
		assert_eq(s.act, 1)
		assert_same({ s.moves_left, s.moves_made, #s.eom }, { 20, 0, 0 })
		assert_same(H.queue(g), { { 2, C.R_BOOSTER, C.BOOSTER.stick, 13, 1, 1 } })
		g:step()
		local ev = g:drain_events()
		assert_same(types(ev), { "booster", "clear", "score", "goal" })
		assert_same(ev[1], { t = 2, type = "booster", booster = "stick", at = { 1, 3 }, ok = true })
		-- the label of the source is (act, 1): the vac of the cleared cell
		assert_same({ s.vac_mv[13], s.vac_wv[13] }, { 1, 1 })
		assert_eq(s.next_source_id, 2, "one source was made at the start of the record")
		assert_eq(next(s.sources), nil, "and it ended with its last action")
		-- the next booster gets the next act
		g:run_to_rest()
		g:input({ type = "booster", booster = "stick", at = { 4, 4 } })
		assert_eq(s.act, 2)
	end)

	it("stick on a special launches it with the label (act, 1) after T.chain", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgSyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g:input({ type = "booster", booster = "stick", at = { 3, 3 } })
		g:step()
		local sub = H.obj_at(g, 3, 3)
		assert_eq(sub.state, C.S_ARMED)
		assert_same(H.queue(g), { { 4, C.R_ACTIVATE, sub.id, 15, 0, 1, 1, 0 } }, "tick 1 + T.chain")
	end)

	it("row light hits (x, row) at now + (x - 1) and counts voids; paths are pinned", function()
		local g = fresh({ "byrgby", "yrgbyr", "r.byrg", "gbyrgb", "byrgby", "yrggbg" }, nil, nil, GAP)
		g:step()
		g:drain_events()
		assert_same({ g:input({ type = "booster", booster = "row_light", row = 3 }) }, { true, "ok" })
		g:step() -- the record runs in tick 2 = t0
		local ev = g:drain_events()
		assert_same(ev[1], { t = 2, type = "booster", booster = "row_light", row = 3, ok = true })
		assert_same(ev[2], { t = 2, type = "bolt", x = 1, y = 3, dir = "r", at = 2 })
		assert_eq(H.obj_at(g, 1, 3).state, C.S_CLEAR, "x = 1 is hit at t0, inside the record")
		assert_same(H.hits(g), { { 4, 3, 3 }, { 5, 4, 3 }, { 6, 5, 3 }, { 7, 6, 3 } }, "x = 2 is a void and still counts")
		local src = next(g.s.sources)
		for x = 3, 6 do
			assert_same(H.obj_at(g, x, 3).pins, { src }, "pinned at x = " .. x)
		end
		assert_eq(#H.obj_at(g, 1, 2).pins, 0)
		-- hitting a cell removes the mark of the source
		for _ = 1, 2 do g:step() end
		assert_eq(#H.obj_at(g, 3, 3).pins, 0)
		assert_eq(H.obj_at(g, 4, 3).pins[1], src)
	end)

	it("column light hits (col, y) at now + (y - 1)", function()
		local g = fresh()
		g:input({ type = "booster", booster = "col_light", col = 4 })
		g:step()
		local ev = g:drain_events()
		assert_same(ev[1], { t = 1, type = "booster", booster = "col_light", col = 4, ok = true })
		assert_same(ev[2], { t = 1, type = "bolt", x = 4, y = 1, dir = "d", at = 1 })
		assert_same(H.hits(g), { { 2, 4, 2 }, { 3, 4, 3 }, { 4, 4, 4 }, { 5, 4, 5 }, { 6, 4, 6 } })
	end)

	it("in turbo every cell of the light is hit inside the record", function()
		local g = fresh(nil, nil, { timing = "turbo" })
		g:input({ type = "booster", booster = "row_light", row = 2 })
		g:step()
		assert_same(H.hits(g), {})
		for x = 1, 6 do assert_eq(H.obj_at(g, x, 2).state, C.S_CLEAR, "x = " .. x) end
	end)

	it("an effect hit by a light on a special chains it", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "ySrgbr" })
		g:input({ type = "booster", booster = "row_light", row = 6 })
		g:step()
		-- x = 1 is hit at t0; the Sabwoofer in (2,6) one tick later
		g:step()
		assert_eq(H.obj_at(g, 2, 6).state, C.S_ARMED)
	end)
end)

describe("core boosters: out of moves (5.3)", function()
	it("an accepted booster returns the game to playing; at rest it goes back to out_of_moves", function()
		local g = fresh()
		g.s.moves_left = 0
		g.s.state = C.G_OUT
		g:step()
		g:drain_events()
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 3, 3 } }) }, { true, "ok" })
		assert_same(g:drain_events(), { { t = 2, type = "state", state = "playing" } })
		g:run_to_rest()
		assert_eq(g:status().state, "out_of_moves")
		local ev = g:drain_events()
		assert_same(ev[#ev], { t = g.s.tick, type = "state", state = "out_of_moves" })
	end)

	it("a booster that meets the last goal ends in won_wait, not in out_of_moves", function()
		local g = fresh(nil, { goals = { { type = "collect", color = "green", count = 1 } } })
		g.s.moves_left = 0
		g.s.state = C.G_OUT
		g:input({ type = "booster", booster = "stick", at = { 3, 1 } }) -- (3,1) is green
		g:step()
		assert_eq(g:status().state, "won_wait")
		while g:status().state == "won_wait" do g:step() end
		assert_eq(g:status().state, "concert", "the concert starts at the first rest")
	end)

	it("works on a stuck board and lifts the flag", function()
		local g = fresh()
		g.s.state, g.s.stuck = C.G_OUT, true
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 3, 3 } }) }, { true, "ok" })
		assert_false(g:status().stuck)
	end)
end)

describe("core boosters: Remix (5.3, 12.2 items 1-3)", function()
	it("shuffles with the shuffle stream and locks the changed pieces for T.shuffle", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local init, spawn, effects = H.stream_copy(g, R.INIT), H.stream_copy(g, R.SPAWN), H.stream_copy(g, R.EFFECTS)
		local shuffle = H.stream_copy(g, R.SHUFFLE)
		g:input({ type = "booster", booster = "remix" })
		g:step()
		local ev = g:drain_events()
		assert_same(ev[1], { t = 1, type = "booster", booster = "remix", ok = true })
		assert_eq(ev[2].type, "shuffle")
		assert_eq(ev[2].duration, 30)
		assert_true(#ev[2].moves > 0)
		assert_same(g.s.rng[R.INIT], init)
		assert_same(g.s.rng[R.SPAWN], spawn)
		assert_same(g.s.rng[R.EFFECTS], effects)
		assert_true(table.concat(g.s.rng[R.SHUFFLE], ",") ~= table.concat(shuffle, ","))
		local o = g.s.objs[ev[2].moves[1].id]
		assert_same({ o.state, o.tk, o.td }, { C.S_SWAP, C.TM_LOCK, 31 })
		assert_false(g.s.rest_flag)
		assert_same(g.s.unplaced, {})
	end)

	it("does nothing when the window's swap took the candidates: ok = false, unplaced, the source id is used", function()
		local g = fresh()
		g:input({ type = "booster", booster = "remix" })
		H.board(g, { "MMMMMM", "MMMMMM", "MMMrMM", "MMMMMM", "MMMMMM", "MMMMMM" })
		local before = g.s.next_source_id
		g:step()
		local ev = g:drain_events()
		assert_same(ev[1], { t = 1, type = "booster", booster = "remix", ok = false })
		assert_same(g.s.unplaced, { C.IT_REMIX })
		assert_eq(g.s.next_source_id, before + 1)
		assert_eq(g.s.tick, 1)
	end)

	it("has no effect on the move counters and is no action of the end-of-move queue", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g:input({ type = "booster", booster = "remix" })
		assert_same({ g.s.moves_left, g.s.moves_made, #g.s.eom, g.s.act }, { 20, 0, 0, 1 })
	end)
end)

describe("core boosters: replay", function()
	it("boosters are recorded as accepted commands and play back identically", function()
		local lvl = H.load(FULL)
		local g = core.new(lvl, { seed = 5 })
		g:run_to_rest()
		g:input({ type = "booster", booster = "col_light", col = 2 })
		for _ = 1, 40 do g:step() end
		g:run_to_rest()
		g:input({ type = "booster", booster = "remix" })
		g:run_to_rest()
		local rep = g:replay()
		assert_eq(#rep.commands, 2)
		assert_same(rep.commands[1], { tick = 1, cmd = { type = "booster", booster = "col_light", col = 2 } })
		local _, ok, why = core.playback(lvl, rep)
		assert_true(ok, why)
	end)
end)
