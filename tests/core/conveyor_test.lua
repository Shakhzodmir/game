-- The conveyor belts (10.9): paths of cells that carry their content one cell on for every move the player
-- spends. What rides is what moves (pieces, specials, mics, coconuts, chained pieces, empty slots); what belongs
-- to the cell stays; a belt with something fixed on it is jammed for that move.

local core = require("core.game")
local C = require("core.const")
local M = require("core.match")
local CV = require("core.conveyor")
local SH = require("core.shuffle")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- the swap (3,5) -> (3,6) makes a purple line of three in the bottom row: (1,6) (2,6) (3,6); no other move
local PA = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "bypgby", "ppgbyr" }
local MOVE = { type = "swap", from = { 3, 5 }, to = { 3, 6 } }
-- the row belt of most tests: (2,3) -> (3,3) -> (4,3) -> (5,3), then back to (2,3)
local ROW = { { 2, 3 }, { 3, 3 }, { 4, 3 }, { 5, 3 } }

-- A belt of the level file from 1-based cells {x, y}, in the order of travel.
local function belt(cells)
	local path = {}
	for k, c in ipairs(cells) do path[k] = { c[1] - 1, c[2] - 1 } end
	return { path = path }
end

-- A live board from a picture with the belts `belts` (each a list of 1-based cells).
local function fresh(rows, belts, extra, opts)
	extra = extra or {}
	extra.conveyor = {}
	for k, b in ipairs(belts) do extra.conveyor[k] = belt(b) end
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or PA)
	g:drain_events()
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

local function rest(g, max)
	local all = {}
	for _ = 1, max or 600 do
		g:step()
		for _, e in ipairs(g:drain_events()) do all[#all + 1] = e end
		if g:is_stable() then break end
	end
	return all
end

-- n moves are over at the next rest (white box: what an accepted swap or tap leaves in the end-of-move queue).
local function spend(g, n)
	local s = g.s
	for _ = 1, n or 1 do
		s.act = s.act + 1
		s.eom[#s.eom + 1] = { a = s.act, noise_hit = false, merged = 0 }
	end
	return rest(g)
end

local function id_at(g, x, y)
	local o = H.obj_at(g, x, y)
	return o and o.id or 0
end

local function ids_of(g, cells)
	local out = {}
	for k, c in ipairs(cells) do out[k] = id_at(g, c[1], c[2]) end
	return out
end

local function types_of(ev, set)
	local out = {}
	for _, e in ipairs(ev) do
		if set[e.type] then out[#out + 1] = e.type end
	end
	return out
end

describe("core conveyor: level schema and rules (2.0, 2.1)", function()
	it("accepts the belts and keeps the cells, the directions and the shape of each", function()
		local lvl = H.load(FULL, { conveyor = { belt(ROW), belt({ { 2, 5 }, { 2, 6 }, { 3, 6 }, { 3, 5 } }),
			belt({ { 6, 4 }, { 6, 3 }, { 6, 2 }, { 5, 2 } }) } })
		local cv = lvl.conveyor
		assert_eq(#cv.belts, 3)
		assert_same(cv.belts[1].cells, { 14, 15, 16, 17 })
		assert_same(cv.belts[1].dirs, { C.DIR_R, C.DIR_R, C.DIR_R, C.DIR_R }) -- the last cell of an open belt points on
		assert_false(cv.belts[1].ring)
		-- a ring: the last cell is a neighbour of the first and points at it
		assert_same(cv.belts[2].cells, { 26, 32, 33, 27 })
		assert_same(cv.belts[2].dirs, { C.DIR_D, C.DIR_R, C.DIR_U, C.DIR_L })
		assert_true(cv.belts[2].ring)
		-- a bent open path
		assert_same(cv.belts[3].dirs, { C.DIR_U, C.DIR_U, C.DIR_L, C.DIR_L })
		assert_false(cv.belts[3].ring)
		assert_same({ cv.at[14], cv.pos[14], cv.at[17], cv.pos[17], cv.at[33], cv.pos[33], cv.at[1], cv.pos[1] },
			{ 1, 1, 1, 4, 2, 3, 0, 0 })
		assert_eq(H.load(FULL).conveyor, nil)
	end)

	it("checks the fields of the block", function()
		expect(H.level(FULL, { conveyor = 3 }), "2.1.1 conveyor: a non-empty list of belts {path} required")
		expect(H.level(FULL, { conveyor = {} }), "2.1.1 conveyor: a non-empty list of belts {path} required")
		expect(H.level(FULL, { conveyor = { 7 } }), "2.1.1 conveyor[1]: object {path} required")
		expect(H.level(FULL, { conveyor = { belt(ROW), { cells = {} } } }), "2.1.1 conveyor[2]: unknown key 'cells'")
		expect(H.level(FULL, { conveyor = { { path = { { 1, 2 }, { 2, 2 } }, loop = true } } }), "2.1.1 conveyor[1]: unknown key 'loop'")
		expect(H.level(FULL, { conveyor = { { path = { { 1, 2 }, { 2, 2 } } } } }),
			"2.1.1 conveyor[1]: path must be a list of at least 3 cells [x, y]")
		expect(H.level(FULL, { conveyor = { { path = 5 } } }), "2.1.1 conveyor[1]: path must be a list of at least 3 cells [x, y]")
		expect(H.level(FULL, { conveyor = { { path = { { 1, 2 }, { 2 }, { 3, 2 } } } } }), "2.1.1 conveyor[1]: path[2]: [x, y] required")
	end)

	it("2.1.2: on existing cells; a cell stands in one belt and once", function()
		expect(H.level({ "######", "######", "###.##", "######", "######", "######" }, { conveyor = { belt(ROW) } }),
			"2.1.2 conveyor is not on an existing cell at 3,2")
		expect(H.level(FULL, { conveyor = { belt({ { 5, 3 }, { 6, 3 }, { 7, 3 } }) } }), "2.1.2 conveyor is not on an existing cell at 6,2")
		expect(H.level(FULL, { conveyor = { belt({ { 2, 3 }, { 3, 3 }, { 2, 3 } }) } }), "2.1.2 two conveyor cells in one cell at 1,2")
		expect(H.level(FULL, { conveyor = { belt(ROW), belt({ { 4, 2 }, { 4, 3 }, { 4, 4 } }) } }),
			"2.1.2 two conveyor cells in one cell at 3,2")
	end)

	it("2.1.14: the cells of a path are neighbours by a side", function()
		expect(H.level(FULL, { conveyor = { belt({ { 2, 3 }, { 4, 3 }, { 5, 3 } }) } }),
			"2.1.14 conveyor cells must be neighbours by a side at 3,2")
		expect(H.level(FULL, { conveyor = { belt({ { 2, 3 }, { 3, 4 }, { 4, 4 } }) } }),
			"2.1.14 conveyor cells must be neighbours by a side at 2,3")
		-- the end of a row and the start of the next one are not neighbours
		expect(H.level(FULL, { conveyor = { belt({ { 5, 3 }, { 6, 3 }, { 1, 4 } }) } }),
			"2.1.14 conveyor cells must be neighbours by a side at 0,3")
		expect(H.level(FULL, { conveyor = { belt({ { 2, 4 }, { 1, 4 }, { 6, 3 } }) } }),
			"2.1.14 conveyor cells must be neighbours by a side at 5,2")
	end)

	it("2.1.14: no blocker and no wires on a belt at the start; what moves and what belongs to the cell may be there", function()
		for _, ch in ipairs({ "X", "K", "N", "A" }) do
			expect(H.level(with(FULL, 3, 3, ch), { conveyor = { belt(ROW) } }), "2.1.14 blocker on a conveyor at 2,2")
		end
		expect(H.level(FULL, { conveyor = { belt(ROW) }, slots = { { at = { 4, 1 }, type = "column", hp = 6 } } }),
			"2.1.14 blocker on a conveyor at 4,2")
		expect(H.level(FULL, { conveyor = { belt(ROW) }, overlay = { { at = { 2, 2 }, type = "wires", hp = 1 } } }),
			"2.1.14 wires on a conveyor at 2,2")
		-- a preset piece, a special, a chained piece, a floor tile: all fine; so is a belt through a spawner
		assert_eq(errors_of(H.level(with(with(FULL, 3, 3, "r"), 4, 3, "S"), { conveyor = { belt(ROW) },
			overlay = { { at = { 4, 2 }, type = "chain", hp = 2 } }, floor = { { at = { 1, 2 }, hp = 2 } } })), "")
		assert_eq(errors_of(H.level(FULL, { conveyor = { belt({ { 2, 1 }, { 3, 1 }, { 4, 1 } }) } })), "")
		-- a mic and a coconut ride too
		assert_eq(errors_of(H.level(with(FULL, 3, 3, "M"), { conveyor = { belt(ROW) },
			goals = { { type = "deliver", count = 1 } }, mic = { total = 1, on_board_max = 1, gap_moves = 0 } })), "")
		assert_eq(errors_of(H.level(with(FULL, 3, 3, "C"), { conveyor = { belt(ROW) },
			goals = { { type = "drop", count = 1 } }, coconut = { total = 1, on_board_max = 1, gap_moves = 0 } })), "")
	end)

	it("2.1.6: the conveyor is one of the three elements a level may have", function()
		local three = { conveyor = { belt(ROW) }, floor = { { at = { 0, 5 }, hp = 1 } },
			slots = { { at = { 0, 3 }, type = "record_box", hp = 1 } } }
		assert_eq(errors_of(H.level(FULL, three)), "")
		three.slots[2] = { at = { 5, 3 }, type = "concrete", hp = 1 }
		expect(H.level(FULL, three), "2.1.6 more than three different elements")
	end)

	it("the belts are part of the canonical form, so of the level hash", function()
		local a = H.load(FULL, { conveyor = { belt(ROW) } })
		local rev = { { 5, 3 }, { 4, 3 }, { 3, 3 }, { 2, 3 } }
		local b = H.load(FULL, { conveyor = { belt(rev) } })
		assert_true(a.hash ~= b.hash and a.hash ~= H.load(FULL).hash)
		assert_true(string.find(a.canonical, '"conveyor":[{"path":[[1,2],[2,2],[3,2],[4,2]]}]', 1, true) ~= nil, a.canonical)
	end)

	it("the start board is the start board of the same level without belts", function()
		local with_belt = H.load(FULL, { conveyor = { belt(ROW) } })
		local plain = H.load(FULL)
		for seed = 1, 10 do
			local g, p = core.new(with_belt, { seed = seed }), core.new(plain, { seed = seed })
			assert_same(H.picture(g), H.picture(p), "seed " .. seed)
			-- the belts are level data: the state, and so its hash, has nothing of them
			assert_eq(g:hash(), p:hash(), "seed " .. seed)
		end
	end)

	it("cells() tells the belt, the place and the direction of every belt cell", function()
		local g = fresh(PA, { ROW, { { 2, 5 }, { 2, 6 }, { 3, 6 }, { 3, 5 } } })
		local cl = g:cells()
		assert_same(cl[14].conveyor, { belt = 1, pos = 1, dir = "r" })
		assert_same(cl[17].conveyor, { belt = 1, pos = 4, dir = "r", last = true })
		assert_same(cl[26].conveyor, { belt = 2, pos = 1, dir = "d" })
		assert_same(cl[32].conveyor, { belt = 2, pos = 2, dir = "r" })
		assert_same(cl[33].conveyor, { belt = 2, pos = 3, dir = "u" })
		assert_same(cl[27].conveyor, { belt = 2, pos = 4, dir = "l" }) -- a ring has no last cell
		assert_eq(cl[13].conveyor, nil)
		assert_eq(H.game(FULL):cells()[14].conveyor, nil)
	end)
end)

describe("core conveyor: one step for every move spent (10.9)", function()
	it("carries the content of every cell to the next one; the last goes to the first; ids are kept", function()
		local g = fresh(PA, { ROW })
		local before = ids_of(g, ROW)
		local ev = spend(g)
		assert_same(H.picture(g)[3], "rrgbyg") -- "rgbyrg": g b y r -> r g b y
		assert_same(ids_of(g, ROW), { before[4], before[1], before[2], before[3] })
		local ce = H.of_type(ev, "conveyor")
		assert_eq(#ce, 1)
		assert_same({ ce[1].belt, ce[1].duration, ce[1].jam, #ce[1].moves }, { 1, 12, nil, 4 })
		assert_same(ce[1].moves[1], { id = before[1], fx = 2, fy = 3, x = 3, y = 3 })
		assert_same(ce[1].moves[3], { id = before[3], fx = 4, fy = 3, x = 5, y = 3 })
		-- the jump: out past the end (6,3), in from before the start (1,3)
		assert_same(ce[1].moves[4], { id = before[4], fx = 5, fy = 3, x = 2, y = 3, wrap = true, ox = 6, oy = 3, ix = 1, iy = 3 })
		-- the rest of the board did not move
		for y = 1, 6 do
			if y ~= 3 then assert_eq(H.picture(g)[y], PA[y]) end
		end
	end)

	it("the riders are locked while they slide (T.conveyor = 12 ticks), then idle again", function()
		local g = fresh(PA, { ROW })
		local s = g.s
		s.act = 1
		s.eom[1] = { a = 1, noise_hit = false, merged = 0 }
		g:step() -- tick 1: step 8 moves the belt
		for _, c in ipairs(ROW) do
			local o = H.obj_at(g, c[1], c[2])
			assert_same({ o.state, o.tk, o.td }, { C.S_SWAP, C.TM_LOCK, 1 + 12 })
			assert_eq(o.cell, (c[2] - 1) * 6 + c[1])
		end
		assert_false(g:is_stable())
		assert_eq(g:can_swap({ 2, 3 }, { 2, 2 }), "reject") -- a rider cannot be taken while it slides
		assert_false(g:input({ type = "booster", booster = "stick", at = { 1, 1 } })) -- (not at rest)
		for _ = 2, 12 do g:step() end
		assert_eq(H.obj_at(g, 2, 3).state, C.S_SWAP)
		g:step() -- tick 13: the lock ends in step 2, the board is searched
		for _, c in ipairs(ROW) do
			local o = H.obj_at(g, c[1], c[2])
			assert_same({ o.state, o.tk, o.td, o.settle }, { C.S_IDLE, 0, 0, 13 })
		end
		assert_true(g:is_stable())
		-- turbo: one tick
		local t = fresh(PA, { ROW }, nil, { timing = "turbo" })
		t.s.act = 1
		t.s.eom[1] = { a = 1, noise_hit = false, merged = 0 }
		t:step()
		assert_eq(H.obj_at(t, 2, 3).td, 2)
		assert_eq(H.of_type(t:drain_events(), "conveyor")[1].duration, 1)
	end)

	it("does not move without a move: a board at rest, a failed swap, a booster", function()
		local g = fresh(PA, { ROW })
		local before = ids_of(g, ROW)
		g.s.dirty = true
		assert_eq(#H.of_type(rest(g), "conveyor"), 0)
		local ok, res = g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } })
		assert_same({ ok, res }, { true, "fail" })
		assert_eq(#H.of_type(rest(g), "conveyor"), 0)
		assert_true(g:input({ type = "booster", booster = "stick", at = { 6, 6 } }))
		local ev = rest(g, 2000)
		assert_eq(#H.of_type(ev, "conveyor"), 0)
		assert_same(ids_of(g, ROW), before)
	end)

	it("an accepted swap moves it once, after the cascade of the move; the move costs one move", function()
		local g = fresh(PA, { { { 2, 1 }, { 3, 1 }, { 4, 1 }, { 5, 1 } } })
		local left = g:status().moves_left
		assert_true(g:input(MOVE))
		local ev = rest(g, 3000)
		local ce = H.of_type(ev, "conveyor")
		assert_eq(#ce, 1)
		assert_eq(g:status().moves_left, left - 1)
		-- it came after the match of the move
		local first_match, at = nil, nil
		for k, e in ipairs(ev) do
			if e.type == "match" and not first_match then first_match = k end
			if e.type == "conveyor" then at = k end
		end
		assert_true(first_match ~= nil and at > first_match)
		-- and nothing moves again until the next move
		g.s.dirty = true
		assert_eq(#H.of_type(rest(g), "conveyor"), 0)
	end)

	it("a swap that is given back spends no move and moves no belt", function()
		-- (3,5) <-> (3,6) accepted at once, then the row is broken before it lands: the swap is returned
		local g = fresh(PA, { ROW })
		assert_true(g:input(MOVE))
		H.obj_at(g, 1, 6).color = 1
		local ev = rest(g, 2000)
		assert_eq(#H.of_type(ev, "swap_back"), 1)
		assert_eq(#H.of_type(ev, "conveyor"), 0)
	end)

	it("several moves that come to rest together: one step for each, in order", function()
		local g = fresh(PA, { ROW })
		local before = ids_of(g, ROW)
		local ev = spend(g, 2)
		local ce = H.of_type(ev, "conveyor")
		assert_eq(#ce, 2)
		assert_same(ids_of(g, ROW), { before[3], before[4], before[1], before[2] })
		assert_eq(ce[1].moves[1].x, 3)
		assert_same({ ce[2].moves[1].id, ce[2].moves[1].fx, ce[2].moves[1].x }, { before[4], 2, 3 })
		-- a full turn brings everything back
		spend(g, 2)
		assert_same(ids_of(g, ROW), before)
	end)

	it("the order of the list is the direction: a reversed list runs the other way, a column runs up or down", function()
		local g = fresh(PA, { { { 5, 3 }, { 4, 3 }, { 3, 3 }, { 2, 3 } } })
		spend(g)
		assert_eq(H.picture(g)[3], "rbyrgg") -- g b y r -> b y r g
		local up = { { 6, 4 }, { 6, 3 }, { 6, 2 } }
		local v = fresh(PA, { up })
		local before = ids_of(v, up)
		local ev = spend(v)
		assert_same(ids_of(v, up), { before[3], before[1], before[2] })
		local m = H.of_type(ev, "conveyor")[1].moves
		assert_same(m[3], { id = before[3], fx = 6, fy = 2, x = 6, y = 4, wrap = true, ox = 6, oy = 1, ix = 6, iy = 5 })
	end)

	it("a ring turns round: no jump, every rider goes to a neighbour cell", function()
		local ring = { { 2, 2 }, { 3, 2 }, { 3, 3 }, { 2, 3 } }
		local g = fresh(PA, { ring })
		local before = ids_of(g, ring)
		local ev = spend(g)
		assert_same(ids_of(g, ring), { before[4], before[1], before[2], before[3] })
		for _, m in ipairs(H.of_type(ev, "conveyor")[1].moves) do
			assert_eq(m.wrap, nil)
			assert_eq(math.abs(m.x - m.fx) + math.abs(m.y - m.fy), 1)
		end
		spend(g, 3)
		assert_same(ids_of(g, ring), before)
	end)

	it("every belt of the level makes its step, in the order of the level", function()
		local col = { { 6, 4 }, { 6, 3 }, { 6, 2 } }
		local g = fresh(PA, { ROW, col })
		local ev = spend(g)
		local ce = H.of_type(ev, "conveyor")
		assert_same({ #ce, ce[1].belt, ce[2].belt }, { 2, 1, 2 })
		assert_eq(ce[1].t, ce[2].t)
	end)
end)

describe("core conveyor: what rides and what stays (10.9)", function()
	it("specials, mics, coconuts and chained pieces ride like pieces; the chain goes with its piece", function()
		local rows = with(with(with(PA, 2, 3, "S"), 3, 3, "M"), 4, 3, "C")
		local g = fresh(rows, { ROW })
		H.obj_at(g, 5, 3).chain = 2
		local before = ids_of(g, ROW)
		local ev = spend(g)
		assert_same(ids_of(g, ROW), { before[4], before[1], before[2], before[3] })
		assert_same(H.picture(g)[3], "rrSMCg")
		assert_eq(H.obj_at(g, 2, 3).chain, 2)
		assert_eq(#H.of_type(ev, "conveyor")[1].moves, 4)
		-- the special did not fire, nothing was collected or hit
		assert_eq(#types_of(ev, { activate = true, clear = true, hit = true, mic_delivered = true, coconut_collected = true }), 0)
	end)

	it("an empty slot rides as an empty slot", function()
		local g = fresh(with(PA, 3, 3, "_"), { ROW })
		local s = g.s
		local before = ids_of(g, ROW)
		assert_eq(before[2], 0)
		assert_true(CV.advance(s, 1))
		assert_same(ids_of(g, ROW), { before[4], before[1], 0, before[3] })
		local ev = g:drain_events()
		assert_eq(#ev[1].moves, 3) -- an empty slot has no id: nothing to tell
		-- a belt with nothing on it carries nothing and says nothing
		for _, c in ipairs(ROW) do
			local o = H.obj_at(g, c[1], c[2])
			if o then
				s.slot[o.cell] = 0
				s.objs[o.id] = nil
			end
		end
		assert_false(CV.advance(s, 1))
		assert_eq(#g:drain_events(), 0)
	end)

	it("the hole the belt carried under a piece is filled by gravity; the board comes to rest whole", function()
		local g = fresh(with(PA, 3, 3, "_"), { ROW })
		g.s.dirty = false
		-- (white box: the hole stands still for this test only until the belt moves)
		local ev = {}
		g.s.act = 1
		g.s.eom[1] = { a = 1, noise_hit = false, merged = 0 }
		-- the first tick fills (3,3) from above before the belt moves: the column falls, then the belt steps
		ev = rest(g, 2000)
		assert_eq(#H.of_type(ev, "conveyor"), 1)
		for i = 1, 36 do assert_true(g.s.slot[i] ~= 0, "cell " .. i) end
		assert_true(g:is_stable())
	end)

	it("floor tiles and the carpet belong to the cell: they stay where they are", function()
		local g = fresh(PA, { ROW }, { floor = { { at = { 1, 2 }, hp = 2 }, { at = { 4, 2 }, hp = 1 } },
			goals = { { type = "light" } } })
		spend(g)
		local cl = g:cells()
		assert_same({ cl[14].floor, cl[15].floor, cl[16].floor, cl[17].floor }, { 2, 0, 0, 1 })
		local c = fresh(PA, { ROW }, { carpet = { { 1, 2 }, { 2, 2 } }, goals = { { type = "carpet" } } })
		local left = c:status().goals[1]
		spend(c)
		local cc = c:cells()
		assert_same({ cc[14].carpet, cc[15].carpet, cc[16].carpet, cc[17].carpet }, { true, true, nil, nil })
		assert_eq(c:status().goals[1], left)
		-- spawners and exits too
		local before = g:cells()
		spend(g)
		for i = 1, 36 do
			assert_same({ g:cells()[i].spawner, g:cells()[i].exit, g:cells()[i].exists }, { before[i].spawner, before[i].exit, before[i].exists })
		end
	end)

	it("a blocker on the belt jams it: nothing moves for that move, the event says so, the other belts go on", function()
		local col = { { 6, 4 }, { 6, 3 }, { 6, 2 } }
		local g = fresh(with(PA, 3, 3, "X"), { ROW, col })
		local before, cbefore = ids_of(g, ROW), ids_of(g, col)
		local ev = spend(g)
		assert_same(ids_of(g, ROW), before)
		assert_same(ids_of(g, col), { cbefore[3], cbefore[1], cbefore[2] })
		local ce = H.of_type(ev, "conveyor")
		assert_eq(#ce, 2)
		assert_same({ ce[1].belt, ce[1].jam, #ce[1].moves, ce[1].duration }, { 1, true, 0, 0 })
		assert_same({ ce[2].belt, ce[2].jam, #ce[2].moves }, { 2, nil, 3 })
		for _, c in ipairs(ROW) do assert_eq(H.obj_at(g, c[1], c[2]).state, C.S_IDLE) end
		-- once the blocker is gone the belt runs again
		local o = H.obj_at(g, 3, 3)
		o.kind, o.blocker, o.hp, o.color = C.K_REGULAR, 0, 0, 5
		ev = spend(g)
		assert_eq(H.of_type(ev, "conveyor")[1].jam, nil)
		assert_same(ids_of(g, ROW), { before[4], before[1], before[2], before[3] })
	end)

	it("a belt that is only jammed leaves the rest of the end of the move as it was: out of moves at once", function()
		local g = fresh(with(PA, 3, 3, "N"), { ROW })
		g.s.moves_left = 0
		g.s.act = 1
		g.s.eom[1] = { a = 1, noise_hit = true, merged = 0 }
		g:step()
		assert_eq(g:status().state, "out_of_moves")
	end)

	it("wires on a belt cell jam it as well (they cannot be there by the rules; the core does not rely on it)", function()
		local g = fresh(PA, { ROW })
		g.s.wires[15] = 1
		assert_true(CV.jammed(g.s, g.s.level.conveyor.belts[1]))
		local before = ids_of(g, ROW)
		assert_false(CV.advance(g.s, 1))
		assert_same(ids_of(g, ROW), before)
	end)
end)

describe("core conveyor: the cascade of a step (10.9)", function()
	-- (2,4) is red: after the step (2,3) is red too, under the red (2,2): a red column of three
	local LINE = with(PA, 2, 4, "r")

	it("the matches a step makes resolve as a cascade: no move is spent, the belt does not move again", function()
		local g = fresh(LINE, { ROW }, { goals = { { type = "collect", color = "red", count = 50 } } })
		local left, score = g:status().moves_left, g:status().score
		local ev = spend(g)
		local order = types_of(ev, { conveyor = true, match = true })
		assert_eq(order[1], "conveyor")
		assert_eq(order[2], "match")
		local ce, me = H.of_type(ev, "conveyor"), H.of_type(ev, "match")
		assert_eq(#ce, 1)
		-- the match comes when the riders stop, T.conveyor ticks after the step
		assert_eq(me[1].t, ce[1].t + 12)
		assert_same(me[1].cells, { { 2, 2 }, { 2, 3 }, { 2, 4 } })
		assert_same({ me[1].color, me[1].wave }, { "red", 1 })
		assert_eq(g:status().moves_left, left)
		assert_true(g:status().score > score)
		assert_true(g:status().goals[1] <= 47)
		assert_true(g:is_stable())
		assert_false(M.any_match(M.color_map(g.s), 6, 6))
	end)

	it("the last move: the step and its cascade come first, out_of_moves after them", function()
		local g = fresh(LINE, { ROW }, { goals = { { type = "collect", color = "red", count = 50 } } })
		g.s.moves_left = 0
		g.s.act = 1
		g.s.eom[1] = { a = 1, noise_hit = false, merged = 0 }
		g:step()
		assert_eq(g:status().state, "playing") -- the riders are sliding
		local ev = rest(g, 2000)
		assert_true(#H.of_type(ev, "match") >= 1)
		assert_eq(g:status().state, "out_of_moves")
		local st = H.of_type(ev, "state")
		assert_eq(st[#st].state, "out_of_moves")
	end)

	it("the cascade of the last step can win the level", function()
		local g = fresh(LINE, { ROW }, { goals = { { type = "collect", color = "red", count = 3 } } })
		g.s.moves_left = 0
		g.s.act = 1
		g.s.eom[1] = { a = 1, noise_hit = false, merged = 0 }
		local won = false
		for _ = 1, 3000 do
			g:step()
			local st = g:status().state
			assert_true(st ~= "out_of_moves")
			if st == "complete" then
				won = true
				break
			end
		end
		assert_true(won)
	end)

	it("the new special of a match made by the belt stands in a cell the belt brought a piece to", function()
		-- a red line of four in column 2 after the step: (2,2) (2,3) (2,4) (2,5)
		local rows = with(LINE, 2, 5, "r")
		rows = with(rows, 1, 5, "g") -- (keeps the start free of matches: b y -> g r in row 5)
		local g = fresh(rows, { ROW })
		local ev = spend(g)
		local sp = H.of_type(ev, "special_new")
		assert_true(#sp >= 1)
		assert_same({ sp[1].special, sp[1].x, sp[1].y }, { "riff", 2, 3 }) -- the rider settled last (6.2.3)
	end)
end)

describe("core conveyor: after the noise and after the curtain (section 11)", function()
	it("events of one end of move: noise_spread, then curtain, then conveyor", function()
		local g = fresh(with(PA, 1, 1, "N"), { ROW }, { curtain = { covers = { { 5, 5 } }, closed_moves = 3, open_moves = 2, start = "open" } })
		local ev = spend(g)
		assert_same(types_of(ev, { noise_spread = true, curtain = true, curtain_left = true, conveyor = true }),
			{ "noise_spread", "curtain_left", "conveyor" })
		local t = H.of_type(ev, "conveyor")[1].t
		assert_eq(H.of_type(ev, "noise_spread")[1].t, t)
		assert_eq(H.of_type(ev, "curtain_left")[1].t, t)
	end)

	it("the noise grows first: a noise that grew onto the belt in this very step jams it", function()
		-- the noise of (3,2) has four neighbours; whichever it takes, the test follows the event
		local g = fresh(with(PA, 3, 2, "N"), { ROW })
		local before = ids_of(g, ROW)
		local grew, jam
		for _ = 1, 12 do
			local ev = spend(g)
			local ns = H.of_type(ev, "noise_spread")
			local ce = H.of_type(ev, "conveyor")
			assert_eq(#ce, 1)
			local on_belt = false
			for _, c in ipairs(ROW) do
				local o = H.obj_at(g, c[1], c[2])
				if o and o.kind == C.K_BLOCKER then on_belt = true end
			end
			if on_belt then
				grew, jam = #ns, ce[1].jam
				break
			end
			before = ids_of(g, ROW)
		end
		assert_true(grew ~= nil, "the noise reached the belt")
		assert_eq(jam, true, "and jammed it in the step in which it grew")
		assert_same(ids_of(g, ROW), before)
	end)

	it("the curtain counts first: a curtain that closes with this move jams the belt under it at once", function()
		local g = fresh(PA, { ROW }, { curtain = { covers = { { 3, 2 } }, closed_moves = 2, open_moves = 1, start = "open" } })
		local before = ids_of(g, ROW)
		local ev = spend(g)
		assert_same(types_of(ev, { curtain = true, conveyor = true }), { "curtain", "conveyor" })
		assert_eq(H.of_type(ev, "curtain")[1].phase, "closed")
		assert_eq(H.of_type(ev, "conveyor")[1].jam, true)
		assert_same(ids_of(g, ROW), before)
		-- still closed after one more move: jammed again
		ev = spend(g)
		assert_eq(H.of_type(ev, "conveyor")[1].jam, true)
		-- the move that opens it sets the belt going in the same step
		ev = spend(g)
		assert_same(types_of(ev, { curtain = true, conveyor = true }), { "curtain", "conveyor" })
		assert_eq(H.of_type(ev, "curtain")[1].phase, "open")
		assert_eq(H.of_type(ev, "conveyor")[1].jam, nil)
		assert_same(ids_of(g, ROW), { before[4], before[1], before[2], before[3] })
		assert_true(g:is_stable())
	end)
end)

describe("core conveyor: exits (10.4, 10.5)", function()
	local DOWN = { { 3, 4 }, { 3, 5 }, { 3, 6 } }

	it("a coconut the belt brings to an exit is collected when it stops there", function()
		local g = fresh(with(PA, 3, 5, "C"), { DOWN }, { goals = { { type = "drop", count = 2 } },
			coconut = { total = 2, on_board_max = 1, gap_moves = 9 } })
		g.s.released, g.s.on_board, g.s.last_mic = 1, 1, 0
		local id = id_at(g, 3, 5)
		local ev = spend(g)
		local ce, cc = H.of_type(ev, "conveyor"), H.of_type(ev, "coconut_collected")
		assert_eq(#cc, 1)
		assert_same({ cc[1].id, cc[1].x, cc[1].y }, { id, 3, 6 })
		assert_eq(cc[1].t, ce[1].t + 12) -- not while it slides
		assert_eq(g:status().goals[1], 1)
		assert_eq(g.s.on_board, 0)
		assert_true(g:is_stable())
	end)

	it("a mic the belt brings to its stand is delivered", function()
		local g = fresh(with(PA, 3, 5, "M"), { DOWN }, { goals = { { type = "deliver", count = 2 } },
			mic = { total = 2, on_board_max = 1, gap_moves = 9 } })
		g.s.released, g.s.on_board = 1, 1
		local ev = spend(g)
		assert_eq(#H.of_type(ev, "mic_delivered"), 1)
		assert_eq(g:status().goals[1], 1)
	end)

	it("a belt that runs up takes a coconut away from the bottom it was about to reach", function()
		local up = { { 3, 5 }, { 3, 4 }, { 3, 3 } }
		local g = fresh(with(PA, 3, 5, "C"), { up }, { goals = { { type = "drop", count = 2 } },
			coconut = { total = 2, on_board_max = 1, gap_moves = 9 } })
		g.s.released, g.s.on_board = 1, 1
		local id = id_at(g, 3, 5)
		local ev = spend(g)
		assert_eq(#H.of_type(ev, "coconut_collected"), 0)
		assert_eq(id_at(g, 3, 4), id)
	end)
end)

describe("core conveyor: moves, hint, shuffle (section 12)", function()
	it("a piece on a belt at rest is swapped like any other; the hint reads the board as it stands", function()
		local on = { { 3, 5 }, { 3, 6 }, { 4, 6 } } -- the belt under the only move of the board
		local g = fresh(PA, { on })
		local plain = H.game(FULL)
		H.board(plain, PA)
		assert_same(g:moves(), plain:moves())
		assert_same(g:hint(), plain:hint())
		assert_same(g:hint(), { from = { 3, 5 }, to = { 3, 6 } })
		assert_eq(g:can_swap({ 3, 5 }, { 3, 6 }), "ok")
		assert_true(g:input(MOVE))
		local ev = rest(g, 3000)
		assert_eq(#H.of_type(ev, "conveyor"), 1)
		assert_true(g:is_stable())
	end)

	it("the shuffle and the Remix take belt cells like any other cells", function()
		local g = fresh(PA, { ROW })
		assert_eq(#SH.candidates(g.s), 36)
		assert_true(g:input({ type = "booster", booster = "remix" }))
		local ev = rest(g, 2000)
		assert_eq(#H.of_type(ev, "shuffle"), 1)
		assert_eq(#H.of_type(ev, "conveyor"), 0) -- (a booster spends no move)
	end)

	it("after a step and its cascade the board always has a move (the ordinary shuffle of 12.2 sees to it)", function()
		local g = fresh(PA, { { { 3, 5 }, { 4, 5 }, { 5, 5 } } }) -- the belt carries away the purple of the only move
		for _ = 1, 6 do
			spend(g)
			rest(g)
			assert_true(g:is_stable() and g:has_move())
		end
	end)
end)

-- Random play --------------------------------------------------------------------------------------------------------

local function lcg(seed)
	local x = seed % 2147483647
	if x == 0 then x = 1 end
	return function(n)
		x = (x * 48271) % 2147483647
		return x % n + 1
	end
end

-- The invariants of a board: every slot holds a living object that knows its cell, every object stands in one
-- slot, the cell layers are the level's; at rest everything is idle with no timer and there is no match.
local function check_board(g, lvl, tag)
	local s = g.s
	local seen, n_objs = {}, 0
	for i = 1, s.N do
		local id = s.slot[i]
		if id ~= 0 then
			local o = s.objs[id]
			assert_true(o ~= nil, tag .. ": slot " .. i .. " holds a dead id")
			assert_true(s.exists[i], tag .. ": an object in a void")
			assert_eq(o.cell, i, tag .. ": object " .. id .. " does not know its cell")
			assert_true(not seen[id], tag .. ": object " .. id .. " stands in two cells")
			seen[id] = true
		end
		assert_eq(s.exists[i], lvl.exists[i])
		assert_eq(s.spawner[i], lvl.spawner[i])
	end
	for id, o in pairs(s.objs) do -- order-independent
		n_objs = n_objs + 1
		assert_true(seen[id], tag .. ": object " .. id .. " is in no slot")
		assert_eq(o.id, id)
	end
	if g:is_stable() then
		local coconuts = 0
		for i = 1, s.N do
			local o = s.slot[i] ~= 0 and s.objs[s.slot[i]] or nil
			if o then
				assert_same({ o.state, o.tk, o.td, o.offx, o.offy }, { C.S_IDLE, 0, 0, 0, 0 }, tag .. ": cell " .. i)
				assert_eq(#o.pins, 0)
				if o.kind == C.K_COCONUT then
					coconuts = coconuts + 1
					assert_false(s.exit[i], tag .. ": a coconut rests on an exit")
				end
				if o.kind == C.K_BLOCKER then assert_eq(o.chain, 0) end
			end
		end
		if lvl.coconut then assert_eq(coconuts, s.on_board, tag .. ": coconuts on the board") end
		assert_false(M.any_match(M.color_map(s), s.W, s.H), tag .. ": a match on a board at rest")
	end
	return n_objs
end

local FUZZ = {
	-- belts with noise and a curtain: an open row, a ring, a column that runs up
	{
		rows = { "#######", "#######", "#######", "#######", "#######", "#######", "#######" },
		extra = {
			moves = 30, goals = { { type = "collect", color = "red", count = 9999 } },
			colors = { "red", "yellow", "green", "blue", "purple" },
			conveyor = { belt({ { 2, 2 }, { 3, 2 }, { 4, 2 }, { 5, 2 }, { 6, 2 } }),
				belt({ { 2, 4 }, { 3, 4 }, { 3, 5 }, { 2, 5 } }), belt({ { 7, 7 }, { 7, 6 }, { 7, 5 }, { 7, 4 } }) },
			curtain = { covers = { { 4, 1 }, { 4, 2 }, { 2, 4 } }, closed_moves = 2, open_moves = 3, start = "open" },
			slots = { { at = { 4, 5 }, type = "noise" }, { at = { 0, 6 }, type = "noise" } },
		},
	},
	-- belts with coconuts and chains: a bent path through the bottom row, a column that runs down to the exits
	{
		rows = { "#######", "#######", "#######", "###.###", "#######", "#######", "#######" },
		extra = {
			moves = 30, goals = { { type = "drop", count = 40 }, { type = "chains", count = 3 } },
			colors = { "red", "yellow", "green", "blue", "purple" },
			coconut = { total = 60, on_board_max = 3, gap_moves = 1 },
			conveyor = { belt({ { 1, 6 }, { 1, 7 }, { 2, 7 }, { 3, 7 } }), belt({ { 6, 3 }, { 6, 4 }, { 6, 5 }, { 6, 6 }, { 6, 7 } }),
				belt({ { 3, 1 }, { 4, 1 }, { 5, 1 } }) },
			overlay = { { at = { 5, 2 }, type = "chain", hp = 2 }, { at = { 0, 5 }, type = "chain", hp = 1 },
				{ at = { 2, 1 }, type = "chain", hp = 2 } },
		},
	},
}

-- Plays `n` random moves (a swap of moves(), a tap of a special now and then); goes on after the moves run out and
-- starts the level again after it ends. Returns a log of hashes.
local function random_play(lvl, seed, n, timing, each)
	local rnd = lcg(seed)
	local g = core.new(lvl, { seed = seed, timing = timing })
	local log = {}
	local steps, belt_steps, jams = 0, 0, 0
	local function run()
		for _ = 1, 20000 do
			if g:is_stable() then return end
			g:step()
			for _, e in ipairs(g:drain_events()) do
				if e.type == "conveyor" then
					if e.jam then jams = jams + 1 else belt_steps = belt_steps + 1 end
				end
			end
			if each then each(g) end
		end
		error("the board did not come to rest")
	end
	for k = 1, n do
		run()
		local st = g:status().state
		if st == "out_of_moves" then
			if not g:input({ type = "continue", moves = 15 }) then
				g = core.new(lvl, { seed = seed + k, timing = timing })
			end
		elseif st ~= "playing" then
			g = core.new(lvl, { seed = seed + k, timing = timing })
		else
			local mv = g:moves()
			local cmd
			if #mv > 0 and rnd(5) > 1 then
				local m = mv[rnd(#mv)]
				cmd = { type = "swap", from = m.from, to = m.to }
			else
				local h = g:hint()
				if h and h.at then cmd = { type = "tap", at = h.at }
				elseif #mv > 0 then cmd = { type = "swap", from = mv[1].from, to = mv[1].to } end
			end
			if cmd then
				assert_true(g:input(cmd))
				steps = steps + 1
			end
		end
		run()
		if each then each(g) end
		log[#log + 1] = g:hash()
	end
	return log, steps, belt_steps, jams, g
end

describe("core conveyor: random play keeps the board whole", function()
	for li, def in ipairs(FUZZ) do
		for _, timing in ipairs({ "turbo", "normal" }) do
			it("level " .. li .. ", " .. timing .. ": a few hundred moves, the invariants hold in every tick", function()
				local lvl = H.load(def.rows, def.extra)
				local n = timing == "turbo" and 260 or 70
				local tick = 0
				local _, steps, belt_steps, jams = random_play(lvl, 100 + li, n, timing, function(g)
					tick = tick + 1
					-- every tick in turbo is cheap; in normal timing every fourth
					if timing == "turbo" or tick % 4 == 0 or g:is_stable() then check_board(g, lvl, "tick " .. tick) end
				end)
				assert_true(steps >= n * 0.8, "moves played: " .. steps)
				assert_true(belt_steps >= steps, "belt steps: " .. belt_steps)
				if li == 1 then assert_true(jams > 0, "the curtain or the noise jammed a belt at least once") end
			end)
		end
	end
end)

describe("core conveyor: determinism (17)", function()
	it("the same seed and commands give the same game, tick for tick; the replay plays back", function()
		local lvl = H.load(FUZZ[1].rows, FUZZ[1].extra)
		local a = random_play(lvl, 7, 40, "normal")
		local b = random_play(lvl, 7, 40, "normal")
		assert_same(a, b)
		local c = random_play(lvl, 8, 40, "normal")
		assert_true(c[#c] ~= a[#a])
	end)

	it("a replay of a conveyor level plays back to the same hash", function()
		local lvl = H.load(FUZZ[2].rows, FUZZ[2].extra)
		local g = core.new(lvl, { seed = 11 })
		for _ = 1, 12 do
			g:run_to_rest()
			if g:status().state ~= "playing" then break end
			local mv = g:moves()[1]
			if not mv then break end
			assert_true(g:input({ type = "swap", from = mv.from, to = mv.to }))
		end
		g:run_to_rest()
		local _, ok, why = core.playback(lvl, g:replay())
		assert_true(ok, why)
	end)

	it("a clone carries the belts with it and plays the same step", function()
		local g = fresh(PA, { ROW })
		local c = g:clone()
		assert_eq(c:hash(), g:hash())
		spend(g)
		spend(c)
		assert_eq(c:hash(), g:hash())
		assert_same(H.picture(c), H.picture(g))
		-- a turbo clone ends on the same board (the look-ahead of the bots)
		local t = fresh(PA, { ROW })
		local tc = t:clone({ reseed = 1 })
		tc:set_timing("turbo")
		spend(tc)
		assert_same(H.picture(tc), H.picture(g))
	end)

	it("a level without belts never calls the conveyor: its end of move is the old one", function()
		local g = H.game(FULL)
		H.board(g, PA)
		g:drain_events()
		local ev = spend(g, 3)
		assert_eq(#H.of_type(ev, "conveyor"), 0)
		assert_same(H.picture(g), PA)
		assert_eq(g.s.level.conveyor, nil)
	end)
end)
