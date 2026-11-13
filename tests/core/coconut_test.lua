-- The coconut (10.5): a colourless piece that falls with the others, never
-- matches, survives every hit and is collected on an exit (goal `drop`).

local core = require("core.game")
local C = require("core.const")
local G = require("core.gravity")
local M = require("core.match")
local BD = require("core.bird")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- a board without a match and without a move
local P0 = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }

local function drop(count, total, max, gap, columns)
	return {
		goals = { { type = "drop", count = count } },
		coconut = { total = total or count, on_board_max = max or 2, gap_moves = gap or 0, columns = columns },
	}
end

-- A live board from a picture. The counters say "everything released", so
-- the spawns of the scene stay coloured unless a test sets them itself.
local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra or drop(2), opts)
	H.board(g, rows or P0)
	local n = 0
	for i = 1, g.s.N do
		local o = g.s.objs[g.s.slot[i]]
		if o and o.kind == C.K_COCONUT then n = n + 1 end
	end
	g.s.released, g.s.on_board, g.s.last_mic = g.s.level.coconut.total, n, 0
	return g
end

local function with(rows, x, y, ch)
	local out = {}
	for k = 1, #rows do out[k] = rows[k] end
	out[y] = string.sub(out[y], 1, x - 1) .. ch .. string.sub(out[y], x + #ch)
	return out
end

local function errors_of(raw)
	local lvl, errs = core.load_level(raw)
	if lvl then return "" end
	return table.concat(errs, "; ")
end

local function expect(raw, text)
	local got = errors_of(raw)
	assert_true(string.find(got, text, 1, true) ~= nil, "expected '" .. text .. "', got '" .. got .. "'")
end

describe("core coconut: level schema and rules (2.0, 2.1.11)", function()
	it("accepts a drop goal with a coconut block, with and without starting coconuts and columns", function()
		assert_eq(errors_of(H.level(FULL, drop(2))), "")
		assert_eq(errors_of(H.level(FULL, drop(2, 3, 1, 4, { 0, 5 }))), "")
		local lvl = H.load({ "######", "#C####", "######", "######", "######", "######" }, drop(1, 2, 1, 3, { 2 }))
		assert_same(lvl.coconut, { total = 2, on_board_max = 1, gap_moves = 3, cols = { false, false, true, false, false, false } })
		assert_true(lvl.exit[31] and lvl.exit[36], "the bottom row is the exit row")
		assert_false(lvl.exit[1])
		assert_same(H.load(FULL, drop(2)).coconut.cols, { true, true, true, true, true, true })
	end)

	it("ties the coconut block to the drop goal", function()
		expect(H.level(FULL, { goals = { { type = "drop", count = 2 } } }), "2.1.1 coconut: block required with a drop goal")
		expect(H.level(FULL, drop(3, 2)), "2.1.1 coconut: total must not be less than the drop count")
		expect(H.level(FULL, { coconut = { total = 1, on_board_max = 1, gap_moves = 0 } }), "2.1.11 coconut block without a drop goal")
		expect(H.level({ "######", "#C####", "######", "######", "######", "######" }), "2.1.11 coconut pieces without a drop goal")
		expect(H.level(FULL, { goals = { { type = "drop" } }, coconut = { total = 1, on_board_max = 1, gap_moves = 0 } }),
			"2.1.1 goals[1]: count >= 1 required")
	end)

	it("checks every field of the block", function()
		local function block(b) return { goals = { { type = "drop", count = 1 } }, coconut = b } end
		expect(H.level(FULL, block("x")), "2.1.1 coconut: object required")
		expect(H.level(FULL, block({ total = 0, on_board_max = 1, gap_moves = 0 })), "2.1.1 coconut: total >= 1 required")
		expect(H.level(FULL, block({ total = 1, on_board_max = 0, gap_moves = 0 })), "2.1.1 coconut: on_board_max >= 1 required")
		expect(H.level(FULL, block({ total = 1, on_board_max = 1, gap_moves = -1 })), "2.1.1 coconut: gap_moves >= 0 required")
		expect(H.level(FULL, block({ total = 1, on_board_max = 1 })), "2.1.1 coconut: gap_moves >= 0 required")
		expect(H.level(FULL, block({ total = 1, on_board_max = 1, gap_moves = 0, every = 2 })), "2.1.1 coconut: unknown key 'every'")
		expect(H.level(FULL, block({ total = 1, on_board_max = 1, gap_moves = 0, columns = {} })), "2.1.1 coconut: columns must be a non-empty list")
		expect(H.level(FULL, block({ total = 1, on_board_max = 1, gap_moves = 0, columns = { 6 } })), "2.1.1 coconut: columns[1] must be a column number 0..W-1")
		expect(H.level(FULL, block({ total = 1, on_board_max = 1, gap_moves = 0, columns = { 1, 1 } })), "2.1.1 coconut: columns[2] repeats a column")
	end)

	it("2.1.11: no mics beside coconuts, start positions, exits, columns with a spawner", function()
		local both = drop(1)
		both.goals[2] = { type = "deliver", count = 1 }
		both.mic = { total = 1, on_board_max = 1, gap_moves = 0 }
		expect(H.level(FULL, both), "2.1.11 drop and deliver goals in one level")
		expect(H.level({ "######", "######", "######", "######", "######", "##C###" }, drop(1)), "2.1.11 starting coconut stands on an exit at 2,5")
		expect(H.level({ "######", "#CC###", "######", "######", "######", "######" }, drop(2, 2, 1)), "2.1.11 more starting coconuts than min(on_board_max, total)")
		local e = drop(1)
		e.exits = { { 0, 5 }, { 1, 5 } }
		expect(H.level(FULL, e), "2.1.11 segment bottom is not an exit at 2,5")
		local sp = drop(1, 1, 1, 0, { 3 })
		sp.spawners = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 4, 0 }, { 5, 0 } }
		expect(H.level(FULL, sp), "2.1.11 coconut column 3 has no spawner")
	end)

	it("2.1.6: the coconut is one of the (at most three) elements of a level", function()
		local l = drop(1)
		l.slots = { { at = { 1, 1 }, type = "record_box", hp = 1 }, { at = { 2, 1 }, type = "noise" } }
		assert_eq(errors_of(H.level(FULL, l)), "")
		l.slots[3] = { at = { 3, 1 }, type = "concrete", hp = 1 }
		expect(H.level(FULL, l), "2.1.6 more than three different elements")
	end)

	it("the canonical form keeps the block and the list of columns", function()
		local LS = require("core.level_schema")
		assert_eq(LS.canonical({ coconut = { total = 2, columns = { 3, 0 }, gap_moves = 1, on_board_max = 1 } }),
			'{"coconut":{"columns":[3,0],"gap_moves":1,"on_board_max":1,"total":2}}')
	end)

	it("a level without coconuts has no block and no exits", function()
		local lvl = H.load(FULL)
		assert_eq(lvl.coconut, nil)
		assert_false(lvl.exit[36])
	end)
end)

describe("core coconut: a piece that falls (10.1, 10.2)", function()
	it("is reported by pieces() as kind coconut, movable, without a colour", function()
		local g = fresh(with(P0, 3, 3, "C"))
		local o = H.obj_at(g, 3, 3)
		local found
		for _, p in ipairs(g:pieces()) do
			if p.id == o.id then found = p end
		end
		assert_same({ found.kind, found.color, found.x, found.y, found.state }, { "coconut", nil, 3, 3, "idle" })
	end)

	it("falls one cell in 7 ticks, exactly like a piece", function()
		local g = fresh({ "byrgby", "Crgbyr", "_gbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local co = H.obj_at(g, 1, 2)
		local want = { 3240, 2820, 2340, 1800, 1200, 540 }
		for t = 1, 6 do
			g:step()
			assert_eq(H.obj_at(g, 1, 3), co)
			assert_eq(co.state, C.S_FALL, "tick " .. t)
			assert_eq(co.offy, want[t], "tick " .. t)
		end
		g:step()
		assert_eq(co.state, C.S_IDLE)
		assert_eq(co.offy, 0)
		assert_eq(H.of_type(g:drain_events(), "land")[1].id, co.id)
	end)

	it("falls together with the column above a cleared piece and lets the pieces above follow", function()
		local g = fresh({ "byrgby", "yCgbyr", "rgbyrg", "g_yrgb", "byrgby", "yrggbg" })
		local co, above = H.obj_at(g, 2, 2), H.obj_at(g, 2, 1)
		H.steps(g, 20)
		assert_eq(co.cell, H.idx(g, 2, 3))
		assert_eq(above.cell, H.idx(g, 2, 2))
		assert_eq(H.obj_at(g, 2, 1).kind, C.K_REGULAR, "a new piece from the spawner")
	end)
end)

describe("core coconut: collection on an exit (10.5)", function()
	it("an idle coconut on an exit is collected in step 7: event, 50 points, the goal", function()
		local g = fresh(with(P0, 1, 6, "C"))
		local co = H.obj_at(g, 1, 6)
		local up = H.obj_at(g, 1, 5)
		g:step()
		assert_same(g:drain_events(), {
			{ t = 1, type = "coconut_collected", id = co.id, x = 1, y = 6 },
			{ t = 1, type = "score", delta = 50, total = 50, x = 1, y = 6 },
			{ t = 1, type = "goal", index = 1, left = 1 },
		})
		assert_eq(co.state, C.S_CLEAR)
		assert_eq(co.td, 1 + 9)
		assert_eq(g.s.on_board, 0)
		assert_same({ g.s.vac_mv[31], g.s.vac_wv[31] }, { co.mv, co.wv })
		for _ = 1, 9 do g:step() end
		assert_eq(g.s.objs[co.id], nil, "it left the board")
		assert_eq(up.cell, 31, "the column above falls into its cell")
		assert_eq(up.state, C.S_FALL)
	end)

	it("is collected only once it has landed, not while it falls into the exit", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "Cyrgby", "_rgbyr" })
		local co = H.obj_at(g, 1, 5)
		local ev = H.steps(g, 6)
		assert_eq(#H.of_type(ev, "coconut_collected"), 0)
		assert_eq(co.state, C.S_FALL)
		ev = H.steps(g, 1)
		assert_eq(#H.of_type(ev, "coconut_collected"), 1)
		assert_eq(co.state, C.S_CLEAR)
	end)

	it("a coconut that is not on an exit stays", function()
		local g = fresh(with(P0, 1, 5, "C"))
		local ev = H.steps(g, 40)
		assert_eq(#H.of_type(ev, "coconut_collected"), 0)
		assert_eq(H.obj_at(g, 1, 5).kind, C.K_COCONUT)
	end)

	it("the last coconut wins the level; the game runs on to complete", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "Cyrgby", "_rgbyr" }, drop(1))
		local ev = H.steps(g, 7)
		local types = {}
		for _, e in ipairs(ev) do
			if e.type == "coconut_collected" or e.type == "score" or e.type == "goal" or e.type == "state" then
				types[#types + 1] = e.type
			end
		end
		assert_same(types, { "coconut_collected", "score", "goal", "state" })
		assert_eq(g:status().state, "won_wait")
		assert_same(g:status().goals, { 0 })
		for _ = 1, 3000 do
			if g:status().state == "complete" then break end
			g:step()
		end
		local res = g:result()
		assert_true(res.won)
		assert_true(res.score >= 50)
	end)

	it("a goal of fewer coconuts than the level holds is met by the first ones", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "Cyrgby", "_rgbyC" }, drop(1, 2))
		H.steps(g, 1)
		assert_eq(g:status().state, "won_wait")
		local ev = H.steps(g, 8)
		assert_eq(#H.of_type(ev, "coconut_collected"), 1, "the second one still leaves on its exit")
		assert_eq(#H.of_type(ev, "goal"), 0, "a met goal sends no more events")
	end)
end)

describe("core coconut: never matches, never breaks (6, 7.1)", function()
	-- "" if no event destroys the coconut `co`, else what did
	local function untouched(ev, co)
		for _, e in ipairs(ev) do
			if e.id == co.id and (e.type == "clear" or e.type == "destroy" or e.type == "hit" or e.type == "transform") then
				return e.type
			end
		end
		return ""
	end

	it("three coconuts in a line are no match, and a coconut splits a line of one colour", function()
		local rows = with(with(P0, 1, 1, "CCC"), 1, 4, "gCg")
		local g = fresh(rows, drop(4, 4, 4))
		assert_false(M.any_match(M.color_map(g.s), 6, 6))
		local ev = H.steps(g, 5)
		assert_eq(#H.of_type(ev, "match"), 0)
		assert_eq(H.picture(g)[1], "CCCgby")
	end)

	it("a Riff, a Sabwoofer and a Disco ball pass over it", function()
		for _, sp in ipairs({ "R", "S", "D" }) do
			local g = fresh(with(with(P0, 2, 4, "C"), 3, 4, sp))
			local co = H.obj_at(g, 2, 4)
			assert_same({ g:input({ type = "tap", at = { 3, 4 } }) }, { true, "ok" })
			local ev = H.steps(g, 12)
			assert_true(#H.of_type(ev, "clear") > 1, sp .. ": the special fired")
			assert_eq(untouched(ev, co), "", sp)
			assert_eq(g.s.objs[co.id], co, sp .. ": the coconut is still there")
			assert_same({ co.kind, co.state }, { C.K_COCONUT, C.S_IDLE }, sp)
		end
	end)

	it("a group next to it and the Grand finale leave it alone", function()
		local g = fresh(with(with(P0, 2, 4, "C"), 3, 4, "DD"))
		local co = H.obj_at(g, 2, 4)
		assert_same({ g:input({ type = "swap", from = { 3, 4 }, to = { 4, 4 } }) }, { true, "ok" })
		local ev = H.steps(g, 40)
		assert_true(#H.of_type(ev, "clear") > 20, "the finale swept the board")
		assert_eq(untouched(ev, co), "")
		assert_eq(co.kind, C.K_COCONUT)
		assert_eq(g.s.objs[co.id], co, "it is still on the board (it only falls)")
	end)

	it("the stick has no effect on it and is refused; a spotlight passes over it", function()
		local g = fresh(with({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }, 2, 4, "C"))
		local co = H.obj_at(g, 2, 4)
		g:step()
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 2, 4 } }) }, { false, "bad_cell" })
		assert_same({ g:input({ type = "booster", booster = "row_light", row = 4 }) }, { true, "ok" })
		local ev = H.steps(g, 8)
		assert_true(#H.of_type(ev, "clear") >= 5, "the spotlight cleared the row")
		assert_eq(untouched(ev, co), "")
		assert_eq(g.s.objs[co.id], co)
		assert_eq(co.cell, H.idx(g, 2, 4))
	end)

	it("the Bird never aims at a coconut, but at the cell under it while the goal is open", function()
		local g = fresh(with(P0, 2, 4, "C"))
		local lv = BD.levels(g.s)
		assert_eq(lv[H.idx(g, 2, 4)], 0)
		assert_eq(lv[H.idx(g, 2, 5)], 3)
		assert_eq(lv[H.idx(g, 3, 5)], 1)
		g.s.goal_left[1] = 0
		assert_eq(BD.levels(g.s)[H.idx(g, 2, 5)], 1, "a met goal: an ordinary piece")
	end)
end)

describe("core coconut: swaps (5.1.2)", function()
	local SW = { "rrCrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }

	it("swaps with a neighbour when the piece makes a match, from either side", function()
		local g = fresh(SW)
		assert_eq(g:can_swap({ 3, 1 }, { 4, 1 }), "ok")
		assert_eq(g:can_swap({ 4, 1 }, { 3, 1 }), "ok")
		local co = H.obj_at(g, 3, 1)
		assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) }, { true, "ok" })
		assert_eq(g.s.moves_left, 19)
		local ev = H.steps(g, 11)
		assert_eq(co.cell, 4, "the coconut took the place of the piece")
		local m = H.of_type(ev, "match")
		assert_eq(#m, 1)
		assert_same(m[1].cells, { { 1, 1 }, { 2, 1 }, { 3, 1 } })
		g:run_to_rest()
		assert_eq(g.s.moves_left, 19, "no refund")
		assert_eq(co.kind, C.K_COCONUT)
	end)

	it("a swap that makes no match bounces and costs no move", function()
		local g = fresh(SW)
		assert_eq(g:can_swap({ 3, 1 }, { 3, 2 }), "fail")
		assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 3, 2 } }) }, { true, "fail" })
		assert_eq(g.s.moves_left, 20)
		H.steps(g, 14)
		assert_eq(H.obj_at(g, 3, 1).kind, C.K_COCONUT)
	end)

	it("two coconuts bounce; a special next to a coconut fires", function()
		local g = fresh(with(P0, 3, 3, "CC"))
		assert_eq(g:can_swap({ 3, 3 }, { 4, 3 }), "fail")
		g = fresh(with(P0, 3, 3, "CR"))
		assert_eq(g:can_swap({ 3, 3 }, { 4, 3 }), "ok")
	end)

	it("the list of moves counts the coconut swaps, and only those that match", function()
		local g = fresh(SW)
		local list = g:moves()
		local found = false
		for _, mv in ipairs(list) do
			if mv.from[1] == 3 and mv.from[2] == 1 and mv.to[1] == 4 and mv.to[2] == 1 then found = true end
			local a, b = H.obj_at(g, mv.from[1], mv.from[2]), H.obj_at(g, mv.to[1], mv.to[2])
			assert_false(a.kind == C.K_COCONUT and b.kind == C.K_COCONUT)
		end
		assert_true(found)
		assert_true(g:has_move())
	end)
end)

describe("core coconut: release from the spawners (10.5)", function()
	local TOP_OPEN = { "______", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }

	local function release(block, counters)
		local g = fresh(TOP_OPEN, { goals = { { type = "drop", count = 3 } }, coconut = block })
		local s = g.s
		s.released, s.on_board, s.last_mic, s.moves_made = counters[1], counters[2], counters[3], counters[4]
		s.now, s.phase = s.tick + 1, 5
		G.assign(s)
		local at = {}
		for x = 1, 6 do
			if H.obj_at(g, x, 1).kind == C.K_COCONUT then at[#at + 1] = x end
		end
		return at, g
	end

	it("releases at most one coconut per pass, in the first spawn of the pass, without a random number", function()
		local R = require("core.rng")
		local g0 = fresh(TOP_OPEN, drop(3, 3, 2, 0))
		local copy = { unpack(g0.s.rng[R.SPAWN]) }
		local at, g = release({ total = 3, on_board_max = 2, gap_moves = 0 }, { 0, 0, 0, 0 })
		assert_same(at, { 1 })
		assert_same({ g.s.released, g.s.on_board, g.s.last_mic }, { 1, 1, 0 })
		local ev = H.of_type(g:drain_events(), "spawn")
		assert_same({ ev[1].kind, ev[1].color }, { "coconut", nil })
		assert_eq(ev[2].kind, "regular")
		for _ = 1, 5 do R.next_int(copy) end
		assert_same(g.s.rng[R.SPAWN], copy, "6 spawns, 1 coconut, 5 colour draws")
	end)

	it("respects total, on_board_max and the gap in moves since the last release", function()
		local L = { total = 3, on_board_max = 2, gap_moves = 2 }
		assert_same((release(L, { 3, 0, 0, 9 })), {}, "everything released")
		assert_same((release(L, { 1, 2, 0, 9 })), {}, "two on the board")
		assert_same((release(L, { 1, 1, 0, 1 })), {}, "moves_made - last = 1 < 2")
		assert_same((release(L, { 1, 1, 0, 2 })), { 1 }, "= 2: released")
		local _, g = release(L, { 1, 1, 3, 5 })
		assert_eq(g.s.last_mic, 5, "the last release follows moves_made")
	end)

	it("enters only in the columns of the list", function()
		local at = release({ total = 3, on_board_max = 2, gap_moves = 0, columns = { 4, 2 } }, { 0, 0, 0, 0 })
		assert_same(at, { 3 }, "the first listed column of the pass")
		local g = fresh({ "_rgb_y", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" },
			{ goals = { { type = "drop", count = 3 } }, coconut = { total = 3, on_board_max = 2, gap_moves = 0, columns = { 4 } } })
		g.s.released, g.s.on_board = 0, 0
		g.s.now, g.s.phase = g.s.tick + 1, 5
		G.assign(g.s)
		assert_eq(H.obj_at(g, 1, 1).kind, C.K_REGULAR)
		assert_eq(H.obj_at(g, 5, 1).kind, C.K_COCONUT)
	end)

	it("the start counts the starting coconuts as released and sets the gap clock", function()
		local g = H.game({ "######", "#C####", "######", "######", "######", "######" }, drop(2, 3, 2, 4))
		assert_same({ g.s.released, g.s.on_board, g.s.last_mic }, { 1, 1, 0 })
		g = H.game(FULL, drop(2, 3, 2, 4))
		assert_same({ g.s.released, g.s.on_board, g.s.last_mic }, { 0, 0, -4 }, "the first one may enter at once")
	end)
end)

describe("core coconut: shuffle and hint (12.2, 12.3)", function()
	it("a board without a move shuffles the pieces only; the coconuts stay where they are", function()
		local g = fresh(with(with(P0, 3, 3, "C"), 5, 2, "C"))
		local a, b = H.obj_at(g, 3, 3), H.obj_at(g, 5, 2)
		assert_false(g:has_move())
		g:step()
		local ev = g:drain_events()
		assert_eq(ev[1].type, "shuffle")
		for _, mv in ipairs(ev[1].moves) do
			assert_true(mv.id ~= a.id and mv.id ~= b.id, "a coconut is no shuffle candidate")
		end
		assert_eq(ev[1].riff, nil)
		H.steps(g, 30)
		assert_same({ a.cell, b.cell }, { H.idx(g, 3, 3), H.idx(g, 5, 2) })
		assert_same({ a.kind, a.state }, { C.K_COCONUT, C.S_IDLE })
		assert_true(g:has_move())
		assert_false(M.any_match(M.color_map(g.s), 6, 6))
	end)

	it("Remix leaves the coconuts in place", function()
		local g = fresh(with({ "rrCrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }, 4, 4, "C"))
		local a, b = H.obj_at(g, 3, 1), H.obj_at(g, 4, 4)
		g:step()
		assert_same({ g:input({ type = "booster", booster = "remix" }) }, { true, "ok" })
		H.steps(g, 40)
		assert_same({ a.cell, b.cell }, { 3, H.idx(g, 4, 4) })
	end)

	it("the hint prefers the move that clears the cell under a coconut", function()
		-- a plain move in row 1 (smaller index) and one in row 6 under the coconut of (1,5)
		local rows = { "ooyoby", "yrgbyr", "rgbyrg", "gbyrgb", "Cyrgby", "ppgpyr" }
		local g = fresh(rows)
		local h = g:hint()
		assert_same(h, { from = { 3, 6 }, to = { 4, 6 } })
		g.s.goal_left[1] = 0
		h = g:hint()
		assert_same(h.from[2], 1, "without the goal the first plain move wins")
	end)

	it("every hinted move is accepted while coconuts are around", function()
		local g = H.game(FULL, drop(3, 4, 2, 1), { seed = 5 })
		for _ = 1, 15 do
			g:run_to_rest()
			if g:status().state ~= "playing" then break end
			local h = g:hint()
			assert_true(h ~= nil, "a board at rest in play always has a move")
			local ok, res
			if h.at then ok, res = g:input({ type = "tap", at = h.at })
			else ok, res = g:input({ type = "swap", from = h.from, to = h.to }) end
			assert_same({ ok, res }, { true, "ok" })
		end
	end)
end)

describe("core coconut: determinism (17)", function()
	local function play(seed)
		local lvl = H.load({ "######", "##C###", "######", "######", "######", "######", "######" },
			{ goals = { { type = "drop", count = 4 } }, coconut = { total = 4, on_board_max = 2, gap_moves = 1 }, moves = 40 })
		local g = core.new(lvl, { seed = seed })
		local nev, k = 0, 0
		for _ = 1, 40 do
			g:run_to_rest()
			nev = nev + #g:drain_events()
			if g:status().state ~= "playing" then break end
			local list = g:moves()
			if #list == 0 then break end
			k = k + 1
			local mv = list[(k * 7) % #list + 1]
			g:input({ type = "swap", from = mv.from, to = mv.to })
		end
		g:run_to_rest()
		return g, lvl, nev
	end

	it("the same seed and the same commands give the same game; the replay plays back", function()
		for seed = 1, 6 do
			local g1, lvl, n1 = play(seed)
			local g2, _, n2 = play(seed)
			assert_eq(g1:hash(), g2:hash(), "seed " .. seed)
			assert_eq(n1, n2)
			assert_eq(g1:clone():hash(), g1:hash())
			local _, ok, why = core.playback(lvl, g1:replay())
			assert_true(ok, tostring(why))
		end
	end)

	it("coconuts enter and leave during such a game", function()
		local released, collected = 0, 0
		for seed = 1, 6 do
			local g = play(seed)
			released = released + g.s.released
			collected = collected + (4 - g:status().goals[1])
		end
		assert_true(released >= 12, "released " .. released)
		assert_true(collected >= 6, "collected " .. collected)
	end)
end)
