-- The Bird (8.3) and its targets (section 9): the level table, density,
-- draws of the `effects` stream, reservation and pin of the target, the
-- impact, cargo choice (Riff axis, Sabwoofer area), the Trio.
--
-- Boards come from H.rows (match-free colour pattern, 6x6):
--   y odd:  b r y g b r      y even: y g b r y g

local C = require("core.const")
local R = require("core.rng")
local B = require("core.board")
local BD = require("core.bird")
local H = require("tests.core.helper")

local FULL = H.full(6, 6)
local EMPTY = { "______", "______", "______", "______", "______", "______" }

local function with(rows, marks)
	local out = {}
	for y = 1, #rows do
		local line = {}
		for x = 1, #rows[y] do line[x] = marks[x .. "," .. y] or string.sub(rows[y], x, x) end
		out[y] = table.concat(line)
	end
	return out
end

local function lv(g, x, y)
	return BD.levels(g.s)[H.idx(g, x, y)]
end

local function same_stream(a, b)
	for k = 1, 6 do
		if a[k] ~= b[k] then return false end
	end
	return true
end

describe("core bird: level table (section 9)", function()
	it("blockers of open break goals, collect colours, other blockers, plain pieces", function()
		local g = H.game({ "######", "#K#X##", "##A###", "######", "######", "######" }, {
			goals = { { type = "break", item = "concrete", count = 1 }, { type = "break", item = "record_box", count = 1 },
				{ type = "collect", color = "green", count = 20 } } })
		H.board(g, H.rows(6, 6, { ["2,2"] = "K", ["4,2"] = "X", ["3,3"] = "A", ["5,5"] = "S", ["6,6"] = "M" }))
		assert_eq(lv(g, 2, 2), 5, "concrete with an open break concrete")
		assert_eq(lv(g, 4, 2), 4, "record box of an open break goal")
		assert_eq(lv(g, 3, 3), 2, "a balloon without a goal: another blocker")
		assert_eq(lv(g, 4, 1), 4, "green piece of the collect goal")
		assert_eq(lv(g, 1, 1), 1, "any other regular piece")
		assert_eq(lv(g, 5, 5), 2, "special")
		assert_eq(lv(g, 6, 6), 0, "mic")
		g.s.goal_left[1] = 0
		assert_eq(lv(g, 2, 2), 2, "concrete once its goal is done")
		-- a pinned piece zeroes the cell; a piece in another state is an open slot
		B.pin(H.obj_at(g, 4, 1), 99)
		assert_eq(lv(g, 4, 1), 0)
		H.obj_at(g, 1, 1).state = C.S_FALL
		assert_eq(lv(g, 1, 1), 0)
		H.obj_at(g, 5, 5).state = C.S_ARMED
		assert_eq(lv(g, 5, 5), 0, "an armed special is an open slot")
	end)

	it("unlit tiles the hit will damage (light goal)", function()
		local g = H.game({ "####X#", "######", "######", "######", "######", "######" }, {
			goals = { { type = "light" } },
			floor = { { at = { 0, 0 }, hp = 1 }, { at = { 1, 0 }, hp = 1 }, { at = { 2, 0 }, hp = 1 }, { at = { 3, 0 }, hp = 1 },
				{ at = { 4, 0 }, hp = 1 }, { at = { 5, 0 }, hp = 2 }, { at = { 0, 1 }, hp = 1 } },
			overlay = { { at = { 1, 0 }, type = "wires", hp = 1 } } })
		H.board(g, H.rows(6, 6, { ["3,1"] = "_", ["4,1"] = "S", ["5,1"] = "X", ["6,1"] = "X" }))
		H.obj_at(g, 6, 1).hp = 2
		assert_eq(lv(g, 1, 1), 4, "regular piece on a tile")
		assert_eq(lv(g, 2, 1), 2, "wires protect the tile: the piece under wires counts")
		assert_eq(lv(g, 3, 1), 4, "empty slot on a tile")
		assert_eq(lv(g, 4, 1), 2, "a special is launched, the tile is not hit")
		assert_eq(lv(g, 5, 1), 4, "single-cell blocker hp 1 on a tile")
		assert_eq(lv(g, 6, 1), 2, "blocker hp 2: the tile survives this hit")
		assert_eq(lv(g, 2, 2), 1, "no tile")
		H.obj_at(g, 1, 2).state = C.S_FALL
		assert_eq(lv(g, 1, 2), 4, "open slot (a falling piece) on a tile")
		B.pin(H.obj_at(g, 1, 1), 99)
		assert_eq(lv(g, 1, 1), 0, "a pinned piece zeroes the whole cell, tile included")
		g.s.floor[H.idx(g, 3, 1)] = 0
		assert_eq(lv(g, 3, 1), 0, "a lit tile")
	end)

	it("cells right under an idle mic that the hit frees (deliver goal)", function()
		local g = H.game({ "######", "#M#M#M", "###X##", "######", "######", "######" }, {
			goals = { { type = "deliver", count = 3 } }, mic = { total = 3, on_board_max = 3, gap_moves = 0 },
			overlay = { { at = { 5, 2 }, type = "wires", hp = 1 } } })
		H.board(g, H.rows(6, 6, { ["2,2"] = "M", ["4,2"] = "M", ["6,2"] = "M", ["4,3"] = "X" }))
		assert_eq(lv(g, 2, 3), 3, "regular piece under a mic")
		assert_eq(lv(g, 4, 3), 3, "blocker hp 1 under a mic")
		assert_eq(lv(g, 6, 3), 2, "wired piece: the hit does not free the cell")
		assert_eq(lv(g, 2, 2), 0, "the mic itself")
		H.obj_at(g, 2, 2).state = C.S_FALL
		assert_eq(lv(g, 2, 3), 1, "the mic must be idle")
		g.s.goal_left[1] = 0
		assert_eq(lv(g, 4, 3), 2, "no open deliver goal")
	end)

	it("a column counts at its top-left cell only, never through its tiles", function()
		local floor = {}
		for x = 0, 5 do floor[#floor + 1] = { at = { x, 1 }, hp = 1 }; floor[#floor + 1] = { at = { x, 2 }, hp = 1 } end
		local g = H.game(FULL, { goals = { { type = "break", item = "column", count = 1 }, { type = "light" } },
			slots = { { at = { 1, 1 }, type = "column", hp = 6 } }, floor = floor })
		H.board(g, H.rows(6, 6, { ["2,2"] = "L", ["3,2"] = "l", ["2,3"] = "l", ["3,3"] = "l" }))
		assert_eq(lv(g, 2, 2), 4)
		assert_eq(lv(g, 3, 2), 0)
		assert_eq(lv(g, 2, 3), 0)
		assert_eq(lv(g, 3, 3), 0)
		assert_eq(lv(g, 4, 2), 4, "next to it: a piece on a tile")
		g.s.goal_left[1] = 0
		assert_eq(lv(g, 2, 2), 2)
	end)
end)

describe("core bird: single Bird (8.3)", function()
	local GOAL_K1 = { goals = { { type = "break", item = "concrete", count = 1 } } }

	it("cross at t0, one draw, bird_fly, reserved target, impact at t0 + 33", function()
		local g = H.game({ "######", "#B####", "######", "######", "####K#", "######" }, GOAL_K1)
		H.board(g, H.rows(6, 6, { ["2,2"] = "B", ["5,5"] = "K" }))
		local bird = H.obj_at(g, 2, 2)
		local rng = H.stream_copy(g, R.EFFECTS)
		assert_true(g:input({ type = "tap", at = { 2, 2 } }))
		g:drain_events()
		g:step() -- t0 = 1
		local ev = g:drain_events()
		assert_same(ev[1], { t = 1, type = "activate", id = bird.id, x = 2, y = 2, special = "bird" })
		local clears = H.of_type(ev, "clear")
		local cl = {}
		for _, e in ipairs(clears) do cl[#cl + 1] = { e.x, e.y, e.cause } end
		assert_same(cl, { { 2, 1, "effect" }, { 1, 2, "effect" }, { 2, 2, "fired" }, { 3, 2, "effect" }, { 2, 3, "effect" } },
			"the cross by index; the own cell removes the Bird")
		local fly = H.of_type(ev, "bird_fly")
		assert_same(fly, { { t = 1, type = "bird_fly", x = 2, y = 2, tx = 5, ty = 5, duration = 33 } })
		assert_eq(ev[#ev].type, "bird_fly", "bird_fly closes the activation")
		R.next_int(rng)
		assert_true(same_stream(rng, g.s.rng[R.EFFECTS]), "one draw even with a single best")
		local sid = H.sources(g)[1]
		assert_same(H.queue(g), { { 34, C.R_BIRD, sid, H.idx(g, 5, 5), 0, 0 } })
		assert_same(g.s.sources[sid].reserves, { H.idx(g, 5, 5) })
		H.steps(g, 32) -- tick 33
		assert_eq(H.obj_at(g, 5, 5).state, C.S_IDLE)
		g:step() -- tick 34
		ev = g:drain_events()
		assert_same(H.of_type(ev, "destroy")[1], { t = 34, type = "destroy", id = H.obj_at(g, 5, 5).id, x = 5, y = 5, item = "concrete" })
		assert_same(H.of_type(ev, "goal"), { { t = 34, type = "goal", index = 1, left = 0 } })
		assert_same(H.sources(g), {}, "retired with its last record")
	end)

	it("the target piece is pinned: it does not fall into the emptied cell below", function()
		local g = H.game(FULL, { goals = { { type = "collect", color = "purple", count = 1 } } })
		H.board(g, H.rows(6, 6, { ["3,4"] = "B", ["3,2"] = "p" }))
		local purple = H.obj_at(g, 3, 2)
		local above = H.obj_at(g, 3, 1)
		g:input({ type = "tap", at = { 3, 4 } })
		g:step()
		local fly = H.of_type(g:drain_events(), "bird_fly")[1]
		assert_same({ fly.tx, fly.ty }, { 3, 2 })
		local sid = H.sources(g)[1]
		assert_same(purple.pins, { sid })
		H.steps(g, 19) -- tick 20: the crossed cell (3,3) is long empty
		assert_eq(g.s.slot[H.idx(g, 3, 3)], 0)
		assert_eq(H.obj_at(g, 3, 2), purple)
		assert_eq(H.obj_at(g, 3, 1), above, "the column above waits too")
		local p
		for _, q in ipairs(g:pieces()) do
			if q.id == purple.id then p = q end
		end
		assert_true(p.pinned)
		local ok, why = g:input({ type = "swap", from = { 3, 2 }, to = { 4, 2 } })
		assert_same({ ok, why }, { false, "not_movable" })
		H.steps(g, 13) -- tick 33
		assert_eq(purple.state, C.S_IDLE)
		g:step() -- tick 34
		local ev = g:drain_events()
		assert_eq(purple.state, C.S_CLEAR)
		assert_same(purple.pins, {})
		assert_same(H.of_type(ev, "goal"), { { t = 34, type = "goal", index = 1, left = 0 } })
	end)

	it("density breaks a tie of levels", function()
		local g = H.game({ "######", "###KX#", "######", "######", "######", "K#####" }, {
			goals = { { type = "break", item = "concrete", count = 2 }, { type = "break", item = "record_box", count = 1 } } })
		H.board(g, H.rows(6, 6, { ["1,6"] = "K", ["4,2"] = "K", ["5,2"] = "X", ["2,4"] = "B" }))
		g:input({ type = "tap", at = { 2, 4 } })
		g:step()
		local fly = H.of_type(g:drain_events(), "bird_fly")[1]
		assert_same({ fly.tx, fly.ty }, { 4, 2 }, "the concrete next to the box (density 2)")
	end)

	it("equal best: one draw from `effects` among them, by cell index", function()
		for seed = 1, 4 do
			local g = H.game({ "K#####", "######", "######", "######", "######", "#####K" },
				{ goals = { { type = "break", item = "concrete", count = 2 } } }, { seed = seed })
			H.board(g, H.rows(6, 6, { ["1,1"] = "K", ["6,6"] = "K", ["3,4"] = "B" }))
			local copy = H.stream_copy(g, R.EFFECTS)
			local want = ({ { 1, 1 }, { 6, 6 } })[R.int(copy, 2)]
			g:input({ type = "tap", at = { 3, 4 } })
			g:step()
			local fly = H.of_type(g:drain_events(), "bird_fly")[1]
			assert_same({ fly.tx, fly.ty }, want)
			assert_true(same_stream(copy, g.s.rng[R.EFFECTS]))
		end
	end)

	it("no candidates: only the cross, no bird_fly, no draw, no impact", function()
		local g = H.game(FULL)
		H.board(g, with(EMPTY, { ["3,3"] = "B" }))
		local copy = H.stream_copy(g, R.EFFECTS)
		g:input({ type = "tap", at = { 3, 3 } })
		g:step()
		local ev = g:drain_events()
		assert_eq(#H.of_type(ev, "bird_fly"), 0)
		assert_true(same_stream(copy, g.s.rng[R.EFFECTS]))
		assert_same(H.queue(g), {})
		assert_same(H.sources(g), {})
	end)

	it("cells reserved by a flying Bird are not candidates of another", function()
		local g = H.game({ "######", "######", "######", "######", "######", "#####K" }, GOAL_K1)
		H.board(g, H.rows(6, 6, { ["1,1"] = "B", ["1,4"] = "B", ["6,6"] = "K" }))
		g:input({ type = "tap", at = { 1, 1 } })
		g:step()
		local f1 = H.of_type(g:drain_events(), "bird_fly")[1]
		assert_same({ f1.tx, f1.ty }, { 6, 6 })
		g:input({ type = "tap", at = { 1, 4 } })
		g:step()
		local f2 = H.of_type(g:drain_events(), "bird_fly")[1]
		assert_true(f2 ~= nil)
		assert_false(f2.tx == 6 and f2.ty == 6)
		assert_eq(#g.s.sources[H.sources(g)[2]].reserves, 1)
	end)

	it("turbo: the impact runs right after the choice, inside the activation", function()
		local g = H.game({ "######", "#B####", "######", "######", "####K#", "######" }, GOAL_K1, { timing = "turbo" })
		H.board(g, H.rows(6, 6, { ["2,2"] = "B", ["5,5"] = "K" }))
		g:input({ type = "tap", at = { 2, 2 } })
		g:step()
		local ev = g:drain_events()
		local order = {}
		for _, e in ipairs(ev) do
			if e.type == "bird_fly" or e.type == "destroy" then order[#order + 1] = e.type end
		end
		assert_same(order, { "bird_fly", "destroy" })
		assert_eq(H.of_type(ev, "bird_fly")[1].duration, 0)
		assert_same(H.queue(g), {})
		assert_same(H.sources(g), {})
	end)

	it("a Bird's cross launches an adjacent special as a chain", function()
		local g = H.game(FULL)
		H.board(g, H.rows(6, 6, { ["3,3"] = "B", ["4,3"] = "S" }))
		g:input({ type = "tap", at = { 3, 3 } })
		g:step()
		local sub = H.obj_at(g, 4, 3)
		assert_eq(sub.state, C.S_ARMED)
		local act
		for _, r in ipairs(g.s.queue) do
			if r.kind == C.R_ACTIVATE then act = r end
		end
		assert_same({ act.due, act.d[1], act.d[4], act.d[5] }, { 4, sub.id, 1, 1 })
	end)
end)

describe("core bird: cargo and Trio (8.5, section 9)", function()
	it("Sabwoofer cargo: the 5x5 area with the most goal objects wins", function()
		local g = H.game(FULL, { goals = { { type = "collect", color = "purple", count = 2 } } })
		-- the cross at (6,1) leaves both purples in place
		H.board(g, H.rows(6, 6, { ["1,1"] = "p", ["5,5"] = "p", ["6,1"] = "B", ["6,2"] = "S" }))
		local copy = H.stream_copy(g, R.EFFECTS)
		local sub = H.obj_at(g, 6, 2)
		H.arm(g, { 6, 1 }, { 6, 2 })
		g:step() -- t0 = 1
		local ev = g:drain_events()
		local act = H.of_type(ev, "activate")[1]
		assert_same({ act.combo, act.special, act.partner }, { "bird_sub", "bird", sub.id })
		assert_same(H.of_type(ev, "bird_fly"), { { t = 1, type = "bird_fly", x = 6, y = 1, tx = 3, ty = 3, carry = "sub", duration = 33 } })
		R.next_int(copy)
		assert_true(same_stream(copy, g.s.rng[R.EFFECTS]))
		local sid = H.sources(g)[1]
		assert_same(H.queue(g), { { 34, C.R_BIRD, sid, H.idx(g, 3, 3), 2, 0 } })
		assert_same(H.obj_at(g, 3, 3).pins, { sid })
		H.steps(g, 32)
		g:step() -- tick 34: the cargo fires in (3,3) with the Bird's label
		ev = g:drain_events()
		assert_same(ev[1], { t = 34, type = "activate", x = 3, y = 3, special = "sub" })
		assert_same({ ev[2].type, ev[2].at, ev[4].at }, { "ring", 40, 44 })
		local csrc = g.s.sources[H.sources(g)[1]]
		assert_same({ csrc.mv, csrc.wv, csrc.own, csrc.centre }, { 1, 1, {}, 0 })
		H.steps(g, 10) -- tick 44: ring 2 reaches both purples
		assert_eq(g.s.goal_left[1], 0)
	end)

	it("Riff cargo: the better axis (h on a tie), one draw among the equal best", function()
		local g = H.game(FULL, { goals = { { type = "collect", color = "purple", count = 2 } } })
		H.board(g, H.rows(6, 6, { ["2,1"] = "p", ["2,4"] = "p", ["6,6"] = "B", ["5,6"] = "R" }))
		local copy = H.stream_copy(g, R.EFFECTS)
		local best = { { 2, 1 }, { 2, 2 }, { 2, 3 }, { 2, 4 }, { 2, 5 }, { 2, 6 } }
		local want = best[R.int(copy, #best)]
		H.arm(g, { 6, 6 }, { 5, 6 })
		g:step()
		local fly = H.of_type(g:drain_events(), "bird_fly")[1]
		assert_same({ fly.tx, fly.ty, fly.carry, fly.axis }, { want[1], want[2], "riff", "v" })
		assert_true(same_stream(copy, g.s.rng[R.EFFECTS]))
		local ev = H.of_type(H.steps(g, 33), "activate") -- tick 34
		assert_same(ev[1], { t = 34, type = "activate", x = want[1], y = want[2], special = "riff", axis = "v" })
	end)

	it("cargo without a target fires in the centre `to`, a Riff with the partner's own axis", function()
		local g = H.game(FULL)
		H.board(g, with(EMPTY, { ["1,6"] = "B", ["2,6"] = "V" }))
		local copy = H.stream_copy(g, R.EFFECTS)
		H.arm(g, { 1, 6 }, { 2, 6 })
		g:step()
		assert_eq(#H.of_type(g:drain_events(), "bird_fly"), 0)
		assert_true(same_stream(copy, g.s.rng[R.EFFECTS]), "no candidates, no draw")
		local sid = H.sources(g)[1]
		assert_same(H.queue(g), { { 34, C.R_BIRD, sid, H.idx(g, 1, 6), 1, C.AX_V } })
		assert_same(g.s.sources[sid].reserves, {})
		H.steps(g, 32)
		g:step() -- tick 34
		local ev = g:drain_events()
		assert_same(ev[1], { t = 34, type = "activate", x = 1, y = 6, special = "riff", axis = "v" })
		assert_same({ ev[2].type, ev[2].dir, ev[3].dir }, { "bolt", "u", "d" })
	end)

	it("Trio: three targets chosen in turn with the reservations of the previous ones", function()
		local g = H.game({ "K####K", "######", "######", "######", "######", "K#####" },
			{ goals = { { type = "break", item = "concrete", count = 3 } } })
		H.board(g, H.rows(6, 6, { ["1,1"] = "K", ["6,1"] = "K", ["1,6"] = "K", ["5,6"] = "B", ["6,6"] = "B" }))
		local copy = H.stream_copy(g, R.EFFECTS)
		local left = { { 1, 1 }, { 6, 1 }, { 1, 6 } }
		local want = {}
		for n = 3, 1, -1 do
			local k = R.int(copy, n)
			want[#want + 1] = left[k]
			table.remove(left, k)
		end
		H.arm(g, { 5, 6 }, { 6, 6 })
		g:step()
		local ev = g:drain_events()
		assert_eq(H.of_type(ev, "activate")[1].combo, "trio")
		local fly = H.of_type(ev, "bird_fly")
		assert_eq(#fly, 3)
		local sid = H.sources(g)[1]
		local q = {}
		for k = 1, 3 do
			assert_same({ fly[k].tx, fly[k].ty }, want[k])
			q[k] = { 34, C.R_BIRD, sid, H.idx(g, want[k][1], want[k][2]), 0, 0 }
		end
		assert_true(same_stream(copy, g.s.rng[R.EFFECTS]))
		assert_same(H.queue(g), q, "impacts in the order of choice")
		assert_eq(#g.s.sources[sid].reserves, 3)
		local d = H.of_type(H.steps(g, 33), "destroy")
		assert_same({ d[1].x, d[1].y, d[2].x, d[2].y, d[3].x, d[3].y },
			{ want[1][1], want[1][2], want[2][1], want[2][2], want[3][1], want[3][2] })
	end)

	it("Trio with two candidates: the third choice is dropped without a draw", function()
		local g = H.game(FULL)
		H.board(g, with(EMPTY, { ["1,1"] = "r", ["6,1"] = "y", ["3,6"] = "B", ["4,6"] = "B" }))
		local copy = H.stream_copy(g, R.EFFECTS)
		R.next_int(copy)
		R.next_int(copy)
		H.arm(g, { 3, 6 }, { 4, 6 })
		g:step()
		assert_eq(#H.of_type(g:drain_events(), "bird_fly"), 2)
		assert_true(same_stream(copy, g.s.rng[R.EFFECTS]), "two draws")
		assert_eq(#H.queue(g), 2)
		assert_true(H.obj_at(g, 1, 1).pins[1] ~= nil and H.obj_at(g, 6, 1).pins[1] ~= nil)
	end)

	it("Trio in turbo: the three choices first, then the three impacts", function()
		local g = H.game({ "K####K", "######", "######", "######", "######", "K#####" },
			{ goals = { { type = "break", item = "concrete", count = 3 } } }, { timing = "turbo" })
		H.board(g, H.rows(6, 6, { ["1,1"] = "K", ["6,1"] = "K", ["1,6"] = "K", ["5,6"] = "B", ["6,6"] = "B" }))
		H.arm(g, { 5, 6 }, { 6, 6 })
		g:step()
		local order = {}
		for _, e in ipairs(g:drain_events()) do
			if e.type == "bird_fly" or e.type == "destroy" then order[#order + 1] = e.type end
		end
		assert_same(order, { "bird_fly", "bird_fly", "bird_fly", "destroy", "destroy", "destroy" })
		assert_same(H.queue(g), {})
	end)
end)

