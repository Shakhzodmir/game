-- The board model (section 1): cells, slot objects, ids, pins, labels, the
-- most frequent colour (3.2.3). Core module: core/board.lua.

local C = require("core.const")
local B = require("core.board")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }

local function fresh(extra)
	local lvl = H.load(FULL, extra)
	return B.new_state(lvl), lvl
end

local function put(s, i, kind, fields)
	local o = B.new_obj(s, kind, fields)
	B.place(s, o, i)
	return o
end

describe("core board: the state of a fresh game (section 1)", function()
	it("starts the counters of 1.3 and 1.4 and copies the cell layers", function()
		local s, lvl = fresh({ moves = 17, floor = { { at = { 1, 1 }, hp = 2 } }, overlay = { { at = { 2, 2 }, type = "wires", hp = 1 } } })
		assert_same({ s.W, s.H, s.N }, { 6, 6, 36 })
		assert_same({ s.tick, s.act, s.seq, s.next_piece_id, s.next_source_id }, { 0, 0, 0, 1, 1 })
		assert_same({ s.moves_left, s.moves_made, s.score }, { 17, 0, 0 })
		assert_eq(s.state, C.G_PLAYING)
		assert_eq(s.timing, C.TIMING_NORMAL)
		assert_eq(s.floor[8], 2)
		assert_eq(s.wires[15], 1)
		for i = 1, 36 do
			assert_eq(s.slot[i], 0, "no objects yet")
			assert_same({ s.vac_mv[i], s.vac_wv[i] }, { 0, 0 }, "vac starts at (0, 0)")
			assert_true(s.exists[i])
		end
		assert_true(s.floor ~= lvl.floor and s.exists ~= lvl.exists, "the state owns its arrays")
		s.floor[8] = 0
		assert_eq(lvl.floor[8], 2, "the level is read-only")
	end)

	it("goal remainders start at the goal counts", function()
		local s = fresh({ goals = { { type = "collect", color = "red", count = 7 }, { type = "collect", color = "blue", count = 3 } } })
		assert_same(s.goal_left, { 7, 3 })
	end)
end)

describe("core board: objects and ids (1.4.1)", function()
	it("an id is the counter value, then the counter grows by one", function()
		local s = fresh()
		local a = B.new_obj(s, C.K_REGULAR, { color = 3 })
		local b = B.new_obj(s, C.K_MIC)
		assert_same({ a.id, b.id, s.next_piece_id }, { 1, 2, 3 })
		assert_same({ a.kind, a.color, a.state, a.mv, a.wv, a.settle, a.offx, a.offy, a.vy, a.delay }, { C.K_REGULAR, 3, C.S_IDLE, 0, 0, 0, 0, 0, 0, 0 })
		assert_same(a.pins, {})
		assert_eq(s.objs[2], b)
	end)

	it("place writes the slot; a column is one object in four slots keyed by its top-left cell", function()
		local s = fresh()
		local p = put(s, 8, C.K_REGULAR, { color = 1 })
		assert_eq(s.slot[8], p.id)
		assert_eq(B.get(s, 8), p)
		assert_eq(B.get(s, 9), nil)
		local col = put(s, 14, C.K_BLOCKER, { blocker = C.BK_COLUMN, hp = 6 })
		for _, i in ipairs({ 14, 15, 20, 21 }) do
			assert_eq(s.slot[i], col.id)
			assert_eq(B.get(s, i), col)
			assert_eq(B.key(s, i), 14, "the key of every column cell")
		end
		assert_same(B.cells_of(s, col), { 14, 15, 20, 21 })
		assert_same(B.cells_of(s, p), { 8 })
		assert_eq(B.key(s, 8), 8)
		assert_eq(B.key(s, 9), 9, "an empty cell is its own key")
	end)

	it("objects() lists every object once, by ascending key cell", function()
		local s = fresh()
		put(s, 30, C.K_REGULAR, { color = 1 })
		local col = put(s, 8, C.K_BLOCKER, { blocker = C.BK_COLUMN, hp = 6 })
		put(s, 2, C.K_MIC)
		put(s, 14, C.K_REGULAR, { color = 2 })
		local keys = {}
		for k, o in ipairs(B.objects(s)) do keys[k] = o.cell end
		assert_same(keys, { 2, 8, 14, 30 })
		assert_eq(B.objects(s)[2], col)
	end)

	it("remove frees every slot of the object and forgets its id", function()
		local s = fresh()
		local col = put(s, 8, C.K_BLOCKER, { blocker = C.BK_COLUMN, hp = 6 })
		local p = put(s, 1, C.K_REGULAR, { color = 1 })
		B.remove(s, col)
		for _, i in ipairs({ 8, 9, 14, 15 }) do assert_eq(s.slot[i], 0) end
		assert_eq(s.objs[col.id], nil)
		assert_eq(B.get(s, 1), p)
	end)

	it("a fallen object stays keyed by its target cell", function()
		local s = fresh()
		local o = put(s, 20, C.K_REGULAR, { color = 4, state = C.S_FALL, offy = 7200 })
		assert_eq(B.objects(s)[1].cell, 20)
		assert_eq(B.get(s, 20), o)
	end)
end)

describe("core board: movable, free and open (0.1, 1.2)", function()
	it("is_movable: regular without wires, special, mic; never a blocker", function()
		local s = fresh({ overlay = { { at = { 0, 0 }, type = "wires", hp = 1 } } })
		local wired = put(s, 1, C.K_REGULAR, { color = 1 })
		local plain = put(s, 2, C.K_REGULAR, { color = 1 })
		local sp = put(s, 3, C.K_SPECIAL, { special = C.SP_SUB })
		local mic = put(s, 4, C.K_MIC)
		local box = put(s, 5, C.K_BLOCKER, { blocker = C.BK_BOX, hp = 1 })
		assert_false(B.is_movable(s, wired))
		assert_true(B.is_movable(s, plain))
		assert_true(B.is_movable(s, sp))
		assert_true(B.is_movable(s, mic))
		assert_false(B.is_movable(s, box))
	end)

	it("is_free adds: idle and not pinned", function()
		local s = fresh()
		local o = put(s, 8, C.K_REGULAR, { color = 2 })
		assert_true(B.is_free(s, o))
		B.pin(o, 4)
		assert_false(B.is_free(s, o))
		B.unpin(o, 4)
		assert_true(B.is_free(s, o))
		for _, st in ipairs({ C.S_FALL, C.S_SWAP, C.S_CLEAR, C.S_ARMED }) do
			o.state = st
			assert_false(B.is_free(s, o), "state " .. st)
		end
	end)

	it("an open slot is empty, or holds content that is not idle", function()
		local s = fresh()
		local o = put(s, 8, C.K_BLOCKER, { blocker = C.BK_NOISE, hp = 1 })
		assert_true(B.is_open(nil))
		assert_false(B.is_open(o))
		for _, st in ipairs({ C.S_FALL, C.S_SWAP, C.S_CLEAR, C.S_ARMED }) do
			o.state = st
			assert_true(B.is_open(o), "state " .. st)
		end
	end)

	it("exists_xy is false outside the field and over voids", function()
		local lvl = H.load({ "######", "#.####", "######", "######", "######", "######" })
		local s = B.new_state(lvl)
		assert_true(B.exists_xy(s, 1, 1))
		assert_false(B.exists_xy(s, 2, 2))
		assert_false(B.exists_xy(s, 0, 1))
		assert_false(B.exists_xy(s, 7, 1))
		assert_false(B.exists_xy(s, 1, 7))
		assert_true(B.exists_xy(s, 6, 6))
	end)
end)

describe("core board: pins (1.2)", function()
	it("pins are source ids kept ascending without repeats", function()
		local s = fresh()
		local o = put(s, 8, C.K_REGULAR, { color = 1 })
		B.pin(o, 9)
		B.pin(o, 3)
		B.pin(o, 9)
		B.pin(o, 5)
		assert_same(o.pins, { 3, 5, 9 })
		assert_true(B.is_pinned(o))
		assert_true(B.is_pinned_by(o, 5))
		assert_false(B.is_pinned_by(o, 4))
		B.unpin(o, 5)
		B.unpin(o, 77)
		assert_same(o.pins, { 3, 9 })
	end)

	it("leaving idle drops every pin; staying idle keeps them", function()
		local s = fresh()
		for _, st in ipairs({ C.S_FALL, C.S_SWAP, C.S_CLEAR, C.S_ARMED }) do
			local o = B.new_obj(s, C.K_REGULAR, { color = 1 })
			B.pin(o, 2)
			B.pin(o, 6)
			B.set_state(o, C.S_IDLE)
			assert_same(o.pins, { 2, 6 })
			B.set_state(o, st)
			assert_same(o.pins, {}, "state " .. st)
			assert_false(B.is_pinned(o))
		end
	end)
end)

describe("core board: labels and merged moves (1.3.5, 1.3.7, 1.3.10)", function()
	local function with_queue(s, ...)
		s.eom = {}
		for _, a in ipairs({ ... }) do s.eom[#s.eom + 1] = { a = a, noise_hit = false, merged = 0 } end
	end

	it("raises a label by the lexicographic maximum and never lowers it", function()
		local s = fresh()
		local o = put(s, 8, C.K_REGULAR, { color = 1, mv = 3, wv = 2 })
		B.raise_label(s, o, 3, 1)
		assert_same({ o.mv, o.wv }, { 3, 2 })
		B.raise_label(s, o, 3, 4)
		assert_same({ o.mv, o.wv }, { 3, 4 })
		B.raise_label(s, o, 2, 9)
		assert_same({ o.mv, o.wv }, { 3, 4 })
		B.raise_label(s, o, 5, 0)
		assert_same({ o.mv, o.wv }, { 5, 0 })
	end)

	it("a rise of mv from m to m' links the moves when both stand in the end-of-move queue", function()
		local s = fresh()
		local o = put(s, 8, C.K_REGULAR, { color = 1, mv = 2, wv = 1 })
		with_queue(s, 2, 4)
		B.raise_label(s, o, 4, 1)
		assert_eq(B.eom_entry(s, 2).merged, 4)
		assert_eq(B.eom_entry(s, 4).merged, 0)
	end)

	it("merged keeps the largest link", function()
		local s = fresh()
		local o = put(s, 8, C.K_REGULAR, { color = 1, mv = 2, wv = 1 })
		with_queue(s, 2, 4, 6)
		B.raise_label(s, o, 6, 1)
		assert_eq(B.eom_entry(s, 2).merged, 6)
		o.mv, o.wv = 2, 1
		B.raise_label(s, o, 4, 1)
		assert_eq(B.eom_entry(s, 2).merged, 6, "merged[2] = max(6, 4)")
	end)

	it("no link when either action is missing from the queue, or when only the wave rises", function()
		local s = fresh()
		local o = put(s, 8, C.K_REGULAR, { color = 1, mv = 2, wv = 1 })
		with_queue(s, 4) -- action 2 is not queued (it was refunded or already scored)
		B.raise_label(s, o, 4, 1)
		assert_eq(B.eom_entry(s, 4).merged, 0)
		o.mv, o.wv = 2, 1
		with_queue(s, 2) -- action 4 is not queued
		B.raise_label(s, o, 4, 1)
		assert_eq(B.eom_entry(s, 2).merged, 0)
		o.mv, o.wv = 2, 1
		with_queue(s, 2, 4)
		B.raise_label(s, o, 2, 7)
		assert_eq(B.eom_entry(s, 2).merged, 0, "same action, higher wave: no merge")
		assert_eq(B.eom_entry(s, 9), nil)
	end)

	it("set_vac stores the label of the cause in the cell", function()
		local s = fresh()
		B.set_vac(s, 8, 3, 2)
		assert_same({ s.vac_mv[8], s.vac_wv[8] }, { 3, 2 })
	end)
end)

describe("core board: the most frequent colour (3.2.3)", function()
	local function board(rows, extra)
		local g = H.game(FULL, extra)
		H.board(g, rows)
		return g.s
	end

	it("counts idle, unpinned regular pieces; the smaller code wins a tie", function()
		local s = board({ "rrbbyy", "rrbbyy", "yyyyyy", "ggggg_", "bbbbbb", "pppppp" })
		-- r 4, b 2 + 6 = 8, y 4 + 6 = 10, g 5, p 6
		assert_eq(B.most_frequent(s, false), C.COLOR.yellow)
		local t = board({ "rrbbyy", "rrbbyy", "______", "______", "______", "______" })
		assert_eq(B.most_frequent(t, false), C.COLOR.red, "4 = 4 = 4: the smallest code")
	end)

	it("returns 0 when there is no such piece", function()
		local s = board({ "SSSSSS", "DDDDDD", "______", "______", "______", "______" })
		assert_eq(B.most_frequent(s, false), 0)
	end)

	it("ignores pieces that are not idle or are pinned", function()
		local s = board({ "rrrbbb", "______", "______", "______", "______", "______" })
		for x = 1, 3 do
			local o = B.get(s, x)
			o.state = C.S_FALL
		end
		assert_eq(B.most_frequent(s, false), C.COLOR.blue)
		for x = 1, 3 do B.get(s, x).state = C.S_IDLE end
		B.pin(B.get(s, 1), 1)
		B.pin(B.get(s, 4), 1)
		B.pin(B.get(s, 5), 1)
		-- red 2, blue 1
		assert_eq(B.most_frequent(s, false), C.COLOR.red)
	end)

	it("unwired_only skips the pieces under wires; the default filter counts them", function()
		local s = board({ "rrrbb_", "______", "______", "______", "______", "______" })
		s.wires[1], s.wires[2] = 1, 1
		assert_eq(B.most_frequent(s, false), C.COLOR.red)
		assert_eq(B.most_frequent(s, true), C.COLOR.blue)
	end)
end)

describe("core board: goal lookup", function()
	it("finds a goal by type and parameter, and whether it is still open", function()
		local s = fresh({ goals = {
			{ type = "collect", color = "red", count = 4 }, { type = "collect", color = "blue", count = 2 },
			{ type = "light" },
		}, floor = { { at = { 0, 0 }, hp = 1 } } })
		assert_eq(B.goal_index(s, C.GOAL_COLLECT, C.COLOR.red), 1)
		assert_eq(B.goal_index(s, C.GOAL_COLLECT, C.COLOR.blue), 2)
		assert_eq(B.goal_index(s, C.GOAL_LIGHT), 3)
		assert_eq(B.goal_index(s, C.GOAL_COLLECT, C.COLOR.green), nil)
		assert_eq(B.goal_index(s, C.GOAL_DELIVER), nil)
		assert_true(B.goal_open(s, C.GOAL_COLLECT, C.COLOR.blue))
		s.goal_left[2] = 0
		assert_false(B.goal_open(s, C.GOAL_COLLECT, C.COLOR.blue))
		assert_false(B.goal_open(s, C.GOAL_BREAK, C.BK_BOX))
	end)
end)

describe("core board: boundaries (audit A)", function()
	it("one pin is enough to pin a piece, and one pin falls with the state", function()
		local s = fresh()
		local o = put(s, 8, C.K_REGULAR, { color = 1 })
		assert_false(B.is_pinned(o))
		B.pin(o, 4)
		assert_true(B.is_pinned(o))
		assert_false(B.is_free(s, o))
		B.set_state(o, C.S_FALL)
		assert_same(o.pins, {})
		assert_false(B.is_pinned(o))
	end)

	it("a goal with one left is still open, with none left it is closed", function()
		local s = fresh({ goals = { { type = "collect", color = "red", count = 3 } } })
		s.goal_left[1] = 1
		assert_true(B.goal_open(s, C.GOAL_COLLECT, C.COLOR.red))
		s.goal_left[1] = 0
		assert_false(B.goal_open(s, C.GOAL_COLLECT, C.COLOR.red))
	end)

	it("the most frequent colour of a single piece is its colour", function()
		local g = H.game(FULL)
		H.board(g, { "r_____", "______", "______", "______", "______", "______" })
		assert_eq(B.most_frequent(g.s, false), C.COLOR.red)
		H.board(g, { "_____p", "______", "______", "______", "______", "______" })
		assert_eq(B.most_frequent(g.s, false), C.COLOR.purple)
	end)

	it("the cells of the field: row ends do not wrap, the last row and column belong to it", function()
		local s = fresh()
		assert_true(B.exists_xy(s, 6, 1))
		assert_true(B.exists_xy(s, 1, 6))
		assert_true(B.exists_xy(s, 6, 6))
		assert_false(B.exists_xy(s, 7, 1), "x = W + 1 is not the first cell of the next row")
		assert_false(B.exists_xy(s, 0, 2), "x = 0 is not the last cell of the row above")
		assert_false(B.exists_xy(s, 1, 0))
		assert_false(B.exists_xy(s, 1, 7))
		assert_false(B.exists_xy(s, -3, 4))
	end)
end)
