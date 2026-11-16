-- The ice (10.11): a regular piece frozen in its cell. It does not fall, is never swapped and takes no part
-- in matches; an adjacent match or an effect hit takes one hp off the ice (1..2), and at 0 the piece is an
-- ordinary free piece again, in place (goal `ice`).

local core = require("core.game")
local C = require("core.const")
local M = require("core.match")
local BD = require("core.bird")
local BX = require("core.boombox")
local SH = require("core.shuffle")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- a board without a match and without a move (no purple in it)
local P0 = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }
-- the swap (3,5) -> (3,6) makes a purple line of three in the bottom row: (1,6) (2,6) (3,6);
-- its side neighbours are (1,5) (2,5) (3,5) and (4,6)
local PA = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "bypgby", "ppgbyr" }
local MOVE = { type = "swap", from = { 3, 5 }, to = { 3, 6 } }

local function ices(count, list)
	local overlay = {}
	for k, c in ipairs(list or { { 0, 5, 1 }, { 1, 5, 1 }, { 2, 5, 1 }, { 3, 5, 1 } }) do
		overlay[k] = { at = { c[1], c[2] }, type = "ice", hp = c[3] }
	end
	return { goals = { { type = "ice", count = count or 4 } }, overlay = overlay }
end

-- A live board from a picture; `frozen` = {{x, y, hp}, ...} freezes the pieces of those cells.
local function fresh(rows, frozen, extra, opts)
	local g = H.game(FULL, extra or ices(), opts)
	H.board(g, rows or P0)
	for _, l in ipairs(frozen or {}) do H.obj_at(g, l[1], l[2]).ice = l[3] or 1 end
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
	for _ = 1, max or 400 do
		g:step()
		for _, e in ipairs(g:drain_events()) do all[#all + 1] = e end
		if g:is_stable() then break end
	end
	return all
end

-- "" if no event says that object o was cleared, moved or recoloured
local function untouched(ev, o)
	for _, e in ipairs(ev) do
		if (e.type == "clear" or e.type == "land" or e.type == "transform") and e.id == o.id then return e.type end
		if e.type == "shuffle" then
			for _, m in ipairs(e.moves) do if m.id == o.id then return "shuffle move" end end
			for _, r in ipairs(e.recolors) do if r.id == o.id then return "shuffle recolor" end end
		end
	end
	return ""
end

describe("core ice: level schema and rules (2.0, 2.1)", function()
	it("accepts ice of hp 1 or 2 over a random cell or a `piece`, and the `ice` goal", function()
		assert_eq(errors_of(H.level(FULL, ices(2))), "")
		local lvl = H.load({ "######", "#r####", "######", "######", "######", "######" },
			ices(2, { { 1, 1, 2 }, { 4, 3, 1 } }))
		assert_same({ lvl.ice[8], lvl.ice[23], lvl.ice[1], lvl.wires[8], lvl.chain[8] }, { 2, 1, 0, 0, 0 })
		assert_same(lvl.goals, { { type = C.GOAL_ICE, param = 0, count = 2 } })
		assert_true(lvl.has_ice)
	end)

	it("checks the fields of the overlay and of the goal", function()
		expect(H.level(FULL, { overlay = { { at = { 0, 0 }, type = "ice", hp = 3 } } }), "2.1.1 overlay[1]: hp 1..2 required")
		expect(H.level(FULL, { overlay = { { at = { 0, 0 }, type = "ice" } } }), "2.1.1 overlay[1]: hp 1..2 required")
		expect(H.level(FULL, { overlay = { { at = { 0, 0 }, type = "frost", hp = 1 } } }),
			"2.1.1 overlay[1]: type 'wires', 'chain' or 'ice' required")
		expect(H.level(FULL, { goals = { { type = "ice" } } }), "2.1.1 goals[1]: count >= 1 required")
		expect(H.level(FULL, { goals = { { type = "ice", count = 1, item = "ice" } } }), "2.1.1 goals[1]: unknown key 'item'")
		expect(H.level(FULL, { goals = { { type = "thaw", count = 1 } } }), "collect|break|light|deliver|drop|chains|carpet|ice|fog required")
	end)

	it("2.1.2 / 2.1.3: one overlay a cell, and only over a regular piece", function()
		expect(H.level(FULL, { overlay = { { at = { 1, 1 }, type = "ice", hp = 1 }, { at = { 1, 1 }, type = "wires", hp = 1 } } }),
			"2.1.2 two overlay elements in one cell at 1,1")
		expect(H.level(FULL, { overlay = { { at = { 1, 1 }, type = "chain", hp = 1 }, { at = { 1, 1 }, type = "ice", hp = 2 } } }),
			"2.1.2 two overlay elements in one cell at 1,1")
		expect(H.level(FULL, { overlay = { { at = { 1, 1 }, type = "ice", hp = 1 }, { at = { 1, 1 }, type = "ice", hp = 2 } } }),
			"2.1.2 two overlay elements in one cell at 1,1")
		expect(H.level(FULL, { overlay = { { at = { 9, 1 }, type = "ice", hp = 1 } } }), "2.1.2 overlay is not on an existing cell")
		for _, ch in ipairs({ "R", "S", "B", "D", "X", "K", "N", "A", "Q" }) do
			expect(H.level(with(FULL, 2, 2, ch), { overlay = { { at = { 1, 1 }, type = "ice", hp = 1 } } }),
				"2.1.3 ice over a cell without a regular piece at 1,1")
		end
		local mic = { goals = { { type = "deliver", count = 1 } }, mic = { total = 1, on_board_max = 1, gap_moves = 0 },
			overlay = { { at = { 1, 1 }, type = "ice", hp = 1 } } }
		expect(H.level(with(FULL, 2, 2, "M"), mic), "2.1.3 ice over a cell without a regular piece at 1,1")
		local co = { goals = { { type = "drop", count = 1 } }, coconut = { total = 1, on_board_max = 1, gap_moves = 0 },
			overlay = { { at = { 1, 1 }, type = "ice", hp = 1 } } }
		expect(H.level(with(FULL, 2, 2, "C"), co), "2.1.3 ice over a cell without a regular piece at 1,1")
	end)

	it("2.1.5: the goal cannot ask for more pieces than are frozen", function()
		expect(H.level(FULL, ices(5)), "2.1.5 ice count exceeds the frozen pieces on the board")
		expect(H.level(FULL, { goals = { { type = "ice", count = 1 } } }), "2.1.5 ice count exceeds the frozen pieces on the board")
		assert_eq(errors_of(H.level(FULL, ices(4))), "")
	end)

	it("2.1.6: the ice is one of the (at most three) elements of a level", function()
		local l = ices(1)
		l.slots = { { at = { 1, 1 }, type = "record_box", hp = 1 }, { at = { 2, 1 }, type = "noise" } }
		assert_eq(errors_of(H.level(FULL, l)), "")
		l.slots[3] = { at = { 3, 1 }, type = "concrete", hp = 1 }
		expect(H.level(FULL, l), "2.1.6 more than three different elements")
	end)

	it("2.1.12 / 2.1.14: no ice under a curtain and none on a conveyor", function()
		local l = ices(1, { { 2, 2, 1 } })
		l.curtain = { covers = { { 2, 2 }, { 3, 2 } }, closed_moves = 2, open_moves = 2, start = "closed" }
		expect(H.level(FULL, l), "2.1.12 ice under a curtain at 2,2")
		l = ices(1, { { 2, 2, 1 } })
		l.conveyor = { { path = { { 1, 2 }, { 2, 2 }, { 3, 2 } } } }
		expect(H.level(FULL, l), "2.1.14 ice on a conveyor at 2,2")
	end)

	it("2.1.7: a frozen piece is fixed content of board B0, like a wired one", function()
		-- the frozen piece plugs the only way into the cell under it: nothing can ever fill that cell
		local rows = { "######", "######", "######", ".#.###", ".#.###", "######" }
		expect(H.level(rows, ices(1, { { 1, 3, 1 } })), "2.1.7 cell stays empty on board B0 at 1,4")
	end)

	it("a level without ice has an all-zero ice layer and no ice flag", function()
		local lvl = H.load(FULL)
		for i = 1, 36 do assert_eq(lvl.ice[i], 0) end
		assert_false(lvl.has_ice)
	end)
end)

describe("core ice: the start board (4)", function()
	it("freezes the starting pieces of the ice cells, pieces() reports it, the moves never use them", function()
		for seed = 1, 8 do
			local g = H.game({ "######", "#r####", "######", "######", "######", "######" },
				ices(2, { { 1, 1, 2 }, { 4, 3, 1 } }), { seed = seed })
			local got = {}
			for _, p in ipairs(g:pieces()) do
				if p.ice then got[#got + 1] = { p.x, p.y, p.kind, p.ice } end
			end
			assert_same(got, { { 2, 2, "regular", 2 }, { 5, 4, "regular", 1 } })
			assert_eq(H.obj_at(g, 2, 2).color, C.COLOR.red)
			assert_false(M.any_match(M.color_map(g.s), 6, 6))
			local mv = g:moves()
			assert_true(#mv >= 3, "a start board has three moves")
			for _, m in ipairs(mv) do
				for _, c in ipairs({ m.from, m.to }) do
					assert_false((c[1] == 2 and c[2] == 2) or (c[1] == 5 and c[2] == 4), "a frozen piece in a move")
				end
			end
		end
	end)

	it("the pre-level boosters never take a frozen piece", function()
		local list = {}
		for y = 0, 5 do
			for x = 0, 5 do
				if y >= 3 then list[#list + 1] = { x, y, 1 } end
			end
		end
		for seed = 1, 6 do
			local g = H.game(FULL, ices(1, list), { seed = seed, boosters = { "riff", "sub", "disco" } })
			local frozen = 0
			for _, p in ipairs(g:pieces()) do
				if p.ice then
					frozen = frozen + 1
					assert_eq(p.kind, "regular")
				end
			end
			assert_eq(frozen, 18)
		end
	end)
end)

describe("core ice: fixed in place (5, 10.1, 12.1)", function()
	it("is not swapped: from it, onto it, by the Crossfader; can_swap rejects, moves() skip it", function()
		-- without the ice the swap (3,5) -> (3,6) is a move; freeze either of its two pieces
		for _, cell in ipairs({ { 3, 5 }, { 3, 6 } }) do
			local g = fresh(PA, { { cell[1], cell[2] } })
			assert_same({ g:input(MOVE) }, { false, "not_movable" })
			assert_same({ g:input({ type = "swap", from = { 3, 6 }, to = { 3, 5 } }) }, { false, "not_movable" })
			assert_eq(g:can_swap({ 3, 5 }, { 3, 6 }), "reject")
			assert_same(g:moves(), {})
			assert_false(g:has_move())
			assert_eq(g:hint(), nil)
			assert_same({ g:input({ type = "booster", booster = "swap", at = cell, to = { 6, 1 } }) }, { false, "not_movable" })
			assert_same({ g:input({ type = "booster", booster = "swap", at = { 6, 1 }, to = cell }) }, { false, "not_movable" })
		end
		local free = fresh(PA)
		assert_eq(free:can_swap({ 3, 5 }, { 3, 6 }), "ok")
	end)

	it("a special swiped onto a frozen piece is a tap", function()
		local g = fresh(with(P0, 3, 3, "R"), { { 4, 3 } })
		local o = H.obj_at(g, 4, 3)
		assert_same({ g:input({ type = "swap", from = { 3, 3 }, to = { 4, 3 } }) }, { true, "ok" })
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "swap"), 0, "no swap: the Riff fired where it stood")
		assert_eq(H.of_type(ev, "activate")[1].x, 3)
		assert_same({ o.ice, o.cell, o.state }, { 0, H.idx(g, 4, 3), C.S_IDLE }, "the row bolt melted the ice, the piece stays")
		assert_eq(g.s.objs[o.id], o)
	end)

	it("does not fall and holds the pieces above it; the hole under it fills from the side", function()
		-- (2,5) is frozen with two layers right above the purple line of the bottom row
		local g = fresh(PA, { { 2, 5, 2 }, { 2, 3, 2 } })
		local a, b = H.obj_at(g, 2, 5), H.obj_at(g, 2, 3)
		local above = H.obj_at(g, 2, 4)
		assert_same({ g:input(MOVE) }, { true, "ok" })
		local ev = rest(g)
		assert_eq(untouched(ev, a), "")
		assert_eq(untouched(ev, b), "")
		assert_same({ a.cell, a.ice, a.state }, { H.idx(g, 2, 5), 1, C.S_IDLE })
		assert_same({ b.cell, b.ice }, { H.idx(g, 2, 3), 2 })
		assert_eq(H.obj_at(g, 2, 4), above, "the piece between two frozen ones did not move")
		for i = 1, g.s.N do assert_true(g.s.slot[i] ~= 0, "cell " .. i .. " is filled") end
	end)

	it("a column with a frozen piece at its spawner waits: the cells under it stay closed to the spawn", function()
		local g = fresh(PA, { { 1, 1, 2 } })
		-- empty the cell (1,6) by hand: nothing may come down column 1 past (1,1) except from the side
		local s = g.s
		local o = H.obj_at(g, 1, 1)
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 1, 4 } }) }, { true, "ok" })
		local ev = rest(g)
		assert_eq(untouched(ev, o), "")
		assert_eq(o.cell, 1)
		for _, e in ipairs(H.of_type(ev, "spawn")) do assert_true(e.x ~= 1, "nothing spawns through the ice") end
		for i = 1, s.N do assert_true(s.slot[i] ~= 0) end
	end)
end)

describe("core ice: a frozen piece is not matchable (6, 5.1.2)", function()
	it("three in a row through a frozen piece is not a match", function()
		for x = 1, 3 do
			local g = fresh(with(P0, 1, 6, "ppp"), { { x, 6 } })
			g.s.dirty = true
			g.s.rest_flag = false
			local o = H.obj_at(g, x, 6)
			local ev = H.steps(g, 3)
			assert_eq(#H.of_type(ev, "match"), 0)
			assert_eq(#H.of_type(ev, "clear"), 0)
			assert_same({ o.cell, o.ice, o.color }, { H.idx(g, x, 6), 1, C.COLOR.purple })
		end
		-- the same board without ice does match
		local g = fresh(with(P0, 1, 6, "ppp"))
		g.s.dirty = true
		assert_eq(#H.of_type(H.steps(g, 1), "match"), 1)
	end)

	it("neither a 2x2 square with a frozen corner", function()
		local g = fresh(with(with(P0, 1, 5, "pp"), 1, 6, "pp"), { { 2, 6 } })
		g.s.dirty = true
		assert_eq(#H.of_type(H.steps(g, 3), "match"), 0)
	end)

	it("a swap that would line up with a frozen piece fails (no move spent)", function()
		local g = fresh(PA, { { 1, 6 } })
		assert_eq(g:can_swap({ 3, 5 }, { 3, 6 }), "fail")
		assert_false(g:has_move())
		assert_same({ g:input(MOVE) }, { true, "fail" })
		local ev = H.steps(g, 14)
		assert_eq(#H.of_type(ev, "swap_fail"), 1)
		assert_eq(#H.of_type(ev, "match"), 0)
		assert_eq(g:status().moves_left, 20)
	end)

	it("the colour map and the expected board give it no colour", function()
		local g = fresh(PA, { { 1, 6 }, { 4, 4, 2 } })
		local MV = require("core.moves")
		assert_same({ M.color_map(g.s)[31], M.color_map(g.s)[22], M.color_map(g.s)[32] }, { 0, 0, C.COLOR.purple })
		assert_same({ MV.expected_colors(g.s)[31], MV.expected_colors(g.s)[22] }, { 0, 0 })
	end)
end)

describe("core ice: thawed from outside (7.1, 10.11)", function()
	it("hp 1: an adjacent match melts it; the piece stays, free, in place", function()
		local g = fresh(PA, { { 4, 6 } })
		local o = H.obj_at(g, 4, 6)
		assert_same({ g:input(MOVE) }, { true, "ok" })
		local ev = H.steps(g, 11)
		assert_same(H.of_type(ev, "hit"), { { t = 11, type = "hit", x = 4, y = 6, layer = "ice", id = o.id, hp = 0 } })
		assert_same(H.of_type(ev, "thawed"), { { t = 11, type = "thawed", id = o.id, x = 4, y = 6 } })
		assert_eq(#H.of_type(ev, "clear"), 3)
		assert_same(H.of_type(ev, "goal"), { { t = 11, type = "goal", index = 1, left = 3 } })
		assert_eq(g:status().score, 3 * 20 + 50)
		assert_same({ o.cell, o.ice, o.kind, o.color, o.state }, { 34, 0, C.K_REGULAR, C.COLOR.blue, C.S_IDLE })
		assert_same({ o.mv, o.wv }, { 1, 1 }, "the label of the group that freed it (1.3.7)")
		assert_eq(g.s.objs[o.id], o)
		rest(g)
		H.board(g, PA)
		assert_true(g:can_swap({ 4, 6 }, { 4, 5 }) ~= "reject", "free now: the player may swap it")
	end)

	it("hp 2: the first adjacent match cracks it (hit hp 1, no goal), the second melts it", function()
		local g = fresh(PA, { { 4, 6, 2 } })
		local o = H.obj_at(g, 4, 6)
		g:input(MOVE)
		local ev = H.steps(g, 11)
		assert_same(H.of_type(ev, "hit"), { { t = 11, type = "hit", x = 4, y = 6, layer = "ice", id = o.id, hp = 1 } })
		assert_eq(#H.of_type(ev, "thawed"), 0)
		assert_eq(#H.of_type(ev, "goal"), 0)
		assert_eq(o.ice, 1)
		assert_eq(g:status().score, 3 * 20 + 50)
		rest(g)
		H.board(g, PA)
		H.obj_at(g, 4, 6).ice = 1
		g:input(MOVE)
		ev = rest(g)
		assert_eq(#H.of_type(ev, "thawed"), 1)
		assert_same(g:status().goals, { 3 })
		assert_eq(H.obj_at(g, 4, 6).ice, 0)
	end)

	it("one group touching it with two cells hits it once; every neighbour of the group is hit", function()
		-- frozen (1,5) (2,5) (3,5)?  (3,5) is the swapped piece, so freeze the other three neighbours
		local g = fresh(PA, { { 1, 5, 2 }, { 2, 5, 2 }, { 4, 6, 2 } })
		g:input(MOVE)
		local ev = H.steps(g, 11)
		local hits = H.of_type(ev, "hit")
		assert_eq(#hits, 3)
		for _, h in ipairs(hits) do assert_same({ h.layer, h.hp }, { "ice", 1 }) end
		assert_eq(g:status().score, 3 * 20 + 3 * 50)
	end)

	it("the match itself never hits it: a frozen piece of the colour next to the line only loses a layer", function()
		-- four purple in the bottom row, the fourth frozen: the group is the first three
		local g = fresh(with(PA, 4, 6, "p"), { { 4, 6, 2 } })
		local o = H.obj_at(g, 4, 6)
		g:input(MOVE)
		local ev = H.steps(g, 11)
		assert_eq(#H.of_type(ev, "match")[1].cells, 3)
		assert_eq(#H.of_type(ev, "special_new"), 0, "three in a row, not four")
		assert_eq(o.ice, 1)
		assert_eq(untouched(ev, o), "")
	end)

	it("effect hits melt a layer and leave the piece: Stick, lights, Riff, Sabwoofer", function()
		local g = fresh(P0, { { 2, 4, 2 }, { 5, 4 } })
		local a, b = H.obj_at(g, 2, 4), H.obj_at(g, 5, 4)
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 2, 4 } }) }, { true, "ok" })
		local ev = rest(g)
		assert_same(H.of_type(ev, "hit"), { { t = 1, type = "hit", x = 2, y = 4, layer = "ice", id = a.id, hp = 1 } })
		assert_eq(#H.of_type(ev, "clear"), 0)
		assert_eq(g:status().score, 50)
		assert_same({ g:input({ type = "booster", booster = "row_light", row = 4 }) }, { true, "ok" })
		ev = rest(g)
		assert_eq(#H.of_type(ev, "thawed"), 2)
		assert_eq(untouched(ev, a), "")
		assert_eq(untouched(ev, b), "")
		assert_same({ a.ice, b.ice, a.cell, b.cell }, { 0, 0, H.idx(g, 2, 4), H.idx(g, 5, 4) })
		assert_same(g:status().goals, { 2 })
		-- a Riff and a Sabwoofer
		local g2 = fresh(with(with(P0, 1, 2, "R"), 4, 5, "S"), { { 5, 2, 2 }, { 5, 6 }, { 2, 3, 2 } })
		local c, d, e = H.obj_at(g2, 5, 2), H.obj_at(g2, 5, 6), H.obj_at(g2, 2, 3)
		assert_same({ g2:input({ type = "tap", at = { 1, 2 } }) }, { true, "ok" })
		ev = rest(g2)
		assert_eq(untouched(ev, c), "")
		assert_same({ c.ice, c.cell }, { 1, H.idx(g2, 5, 2) })
		assert_eq(e.ice, 2, "outside the row: untouched")
		H.board(g2, with(P0, 4, 5, "S"))
		H.obj_at(g2, 5, 6).ice = 1
		d = H.obj_at(g2, 5, 6)
		assert_same({ g2:input({ type = "tap", at = { 4, 5 } }) }, { true, "ok" })
		ev = rest(g2)
		assert_eq(untouched(ev, d), "")
		assert_same({ d.ice, d.cell }, { 0, H.idx(g2, 5, 6) })
		assert_eq(#H.of_type(ev, "thawed"), 1)
	end)

	it("an effect never lights the tile under the ice; the Grand finale (all layers) does, and takes one layer", function()
		local extra = ices(4)
		extra.floor = { { at = { 1, 1 }, hp = 1 }, { at = { 4, 4 }, hp = 1 } }
		local g = fresh(P0, { { 2, 2, 2 }, { 5, 5, 2 } }, extra)
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 2, 2 } }) }, { true, "ok" })
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "floor_lit"), 0)
		assert_eq(H.obj_at(g, 2, 2).ice, 1)
		local g2 = fresh(with(with(P0, 3, 4, "D"), 4, 4, "D"), { { 2, 2, 2 }, { 5, 5, 2 } }, extra)
		local a, b = H.obj_at(g2, 2, 2), H.obj_at(g2, 5, 5)
		assert_same({ g2:input({ type = "swap", from = { 3, 4 }, to = { 4, 4 } }) }, { true, "ok" })
		ev = rest(g2, 600)
		-- (the cascade that follows may melt more; the finale itself takes exactly one layer of each)
		local first, lit = {}, {}
		for _, e in ipairs(ev) do
			if e.type == "hit" and e.layer == "ice" and not first[e.id] then first[e.id] = e.hp end
			if e.type == "floor_lit" then lit[#lit + 1] = e.x * 10 + e.y end
			if e.type == "land" then break end
		end
		assert_same({ first[a.id], first[b.id] }, { 1, 1 })
		table.sort(lit)
		assert_same(lit, { 22, 55 })
	end)

	it("a `match` source cannot reach it and the adjacent hit of a wired neighbour is not passed on", function()
		local g = fresh(PA, { { 4, 6 } })
		local Hi = require("core.hits")
		local src = Hi.new_source(g.s, C.SRC_MATCH, 1, 1, 6)
		Hi.hit(g.s, 34, src)
		assert_eq(H.obj_at(g, 4, 6).ice, 1)
		assert_eq(#g:drain_events(), 0)
	end)
end)

describe("core ice: the freed piece is a normal piece at once (6, 10.11)", function()
	-- PB: column 4 holds green in rows 4, 5 and (frozen) 6; the purple line of row 6 touches (4,6)
	local PB = with(with(PA, 4, 4, "g"), 4, 6, "g")

	it("a ready-made line through it resolves in the next search, as the next wave of the same move", function()
		local g = fresh(PB, { { 4, 6 } })
		local o = H.obj_at(g, 4, 6)
		assert_true(g:is_stable(), "frozen, the green column is no match")
		assert_same({ g:input(MOVE) }, { true, "ok" })
		local ev = H.steps(g, 11)
		local ms = H.of_type(ev, "match")
		assert_eq(#ms, 2)
		assert_same({ ms[1].t, ms[1].color, ms[1].wave, ms[1].act, #ms[1].cells }, { 11, "purple", 1, 1, 3 })
		assert_same({ ms[2].t, ms[2].color, ms[2].wave, ms[2].act }, { 11, "green", 2, 1 })
		assert_same(ms[2].cells, { { 4, 4 }, { 4, 5 }, { 4, 6 } })
		-- the order: the whole first group (its thaw included), then the second search
		local order = {}
		for _, e in ipairs(ev) do
			if e.type == "match" or e.type == "thawed" then order[#order + 1] = e.type end
		end
		assert_same(order, { "match", "thawed", "match" })
		-- cleared once, by the second match, with the score of wave 2
		local clears = 0
		for _, e in ipairs(H.of_type(ev, "clear")) do
			if e.id == o.id then clears = clears + 1 end
		end
		assert_eq(clears, 1)
		assert_eq(g:status().score, 3 * 20 + 50 + 3 * 40)
		assert_eq(g:status().moves_left, 19)
		rest(g)
		assert_eq(g:status().state, "playing")
	end)

	it("with two layers it only cracks, and the column waits", function()
		local g = fresh(PB, { { 4, 6, 2 } })
		g:input(MOVE)
		local ev = H.steps(g, 11)
		assert_eq(#H.of_type(ev, "match"), 1)
		assert_eq(H.obj_at(g, 4, 6).ice, 1)
	end)

	it("a piece freed by an effect hit matches at step 7 of the same tick", function()
		local g = fresh(with(PB, 3, 5, "y"), { { 4, 6 } })
		local o = H.obj_at(g, 4, 6)
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 4, 6 } }) }, { true, "ok" })
		local ev = H.steps(g, 1)
		assert_eq(#H.of_type(ev, "thawed"), 1)
		local ms = H.of_type(ev, "match")
		assert_eq(#ms, 1)
		assert_same(ms[1].cells, { { 4, 4 }, { 4, 5 }, { 4, 6 } })
		assert_eq(o.state, C.S_CLEAR)
	end)

	it("the cascades end: a board of nothing but ready lines under ice melts wave by wave", function()
		-- every piece of rows 4..6 is frozen and stands in a ready-made line
		local rows = { "byrgby", "yrgbyr", "pprgbg", "rrryyy", "gggbbb", "yyyrrr" }
		local frozen = {}
		for y = 4, 6 do
			for x = 1, 6 do frozen[#frozen + 1] = { x, y } end
		end
		local g = fresh(rows, frozen)
		assert_true(g:is_stable())
		-- (3,2) green <-> (3,3) red: three red in row 3?  no: the move is the purple line p p . of row 3
		assert_same({ g:input({ type = "booster", booster = "row_light", row = 4 }) }, { true, "ok" })
		local ev = rest(g, 3000)
		assert_true(g:is_stable(), "the board came to rest")
		assert_true(#H.of_type(ev, "thawed") >= 3)
	end)
end)

describe("core ice: the goal and the win (7.4, 13)", function()
	it("counts a piece when its ice reaches 0, 50 points a layer, and wins on the last one", function()
		local g = fresh(PA, { { 4, 6, 2 }, { 1, 5 } }, ices(2))
		g:input(MOVE)
		local ev = H.steps(g, 11)
		assert_same(H.of_type(ev, "goal"), { { t = 11, type = "goal", index = 1, left = 1 } })
		assert_eq(g:status().state, "playing")
		rest(g)
		H.board(g, PA)
		H.obj_at(g, 4, 6).ice = 1
		g:input(MOVE)
		ev = rest(g, 3000)
		assert_same(H.of_type(ev, "goal"), { { t = H.of_type(ev, "goal")[1].t, type = "goal", index = 1, left = 0 } })
		local st = g:status().state
		assert_true(st == "complete" or st == "concert" or st == "won_wait", st)
		for _ = 1, 5000 do
			if g:status().state == "complete" then break end
			g:step()
		end
		assert_eq(g:status().state, "complete")
	end)

	it("more ice than the goal asks: the rest still melts and scores, without goal events", function()
		local g = fresh(PA, { { 4, 6 }, { 1, 5 }, { 2, 5 } }, ices(1))
		g:input(MOVE)
		local ev = H.steps(g, 11)
		assert_eq(#H.of_type(ev, "thawed"), 3)
		assert_eq(#H.of_type(ev, "goal"), 1)
		assert_eq(g:status().score, 3 * 20 + 3 * 50)
	end)
end)

describe("core ice: nobody picks a frozen piece (3.2.3, 8.4, 8.5, 10.10, 11, 13)", function()
	it("the Disco ball: not in its list, not in the most frequent colour", function()
		-- every red piece but one is frozen: the ball swapped with the free red one takes only that colour's free pieces
		local g = fresh(with(P0, 3, 4, "D"))
		local reds = {}
		for i = 1, g.s.N do
			local o = g.s.objs[g.s.slot[i]]
			if o.kind == C.K_REGULAR and o.color == C.COLOR.red and i ~= H.idx(g, 4, 4) then
				o.ice = 2
				reds[#reds + 1] = o
			end
		end
		assert_true(#reds >= 5)
		assert_eq(H.obj_at(g, 4, 4).color, C.COLOR.red)
		assert_same({ g:input({ type = "swap", from = { 3, 4 }, to = { 4, 4 } }) }, { true, "ok" })
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "disco_ray"), 1, "one free red piece")
		for _, o in ipairs(reds) do
			assert_eq(untouched(ev, o), "")
			assert_eq(o.ice, 2)
		end
		-- mf(): the frozen colour does not count
		local g2 = fresh(P0)
		local B = require("core.board")
		local before = B.most_frequent(g2.s, false)
		for i = 1, g2.s.N do
			local o = g2.s.objs[g2.s.slot[i]]
			if o.color == before then o.ice = 1 end
		end
		assert_true(B.most_frequent(g2.s, false) ~= before)
	end)

	it("the boombox blast, the shuffle, the bonus gift and the concert leave it alone", function()
		local g = fresh(P0, { { 1, 1 }, { 5, 1 }, { 3, 3, 2 } })
		local busy = {}
		local blue = BX.candidates(g.s, C.COLOR.blue, busy)
		for _, i in ipairs(blue) do assert_true(i ~= 1 and i ~= 5 and i ~= H.idx(g, 3, 3)) end
		assert_true(#blue >= 3)
		for _, i in ipairs(SH.candidates(g.s)) do assert_eq(g.s.objs[g.s.slot[i]].ice, 0) end
		assert_eq(#SH.candidates(g.s), 33)
		local all = fresh(P0)
		for i = 1, all.s.N do all.s.objs[all.s.slot[i]].ice = 1 end
		assert_same({ all:input({ type = "bonus", special = "riff" }) }, { false, "no_candidates" })
		assert_eq(#SH.candidates(all.s), 0)
		require("core.flow").concert_a(all.s, 1)
		assert_eq(#H.of_type(all:drain_events(), "concert_riff"), 0)
	end)

	it("noise does not grow onto a frozen piece", function()
		local g = fresh(with(P0, 3, 4, "N"), { { 2, 4 }, { 4, 4 }, { 3, 3 }, { 3, 5 } })
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		require("core.flow").noise_growth(g.s)
		assert_eq(#H.of_type(g:drain_events(), "noise_spread"), 0)
		local g2 = fresh(with(P0, 3, 4, "N"), { { 2, 4 }, { 4, 4 }, { 3, 3 } })
		g2.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		require("core.flow").noise_growth(g2.s)
		local sp = H.of_type(g2:drain_events(), "noise_spread")
		assert_same({ #sp, sp[1].x, sp[1].y }, { 1, 3, 5 })
	end)

	it("the Bird: a frozen piece is a goal cell with an open `ice` goal, else like a wired piece", function()
		local extra = ices(4)
		extra.goals[2] = { type = "light" }
		extra.floor = { { at = { 1, 3 }, hp = 1 }, { at = { 4, 4 }, hp = 1 } }
		local g = fresh(P0, { { 2, 4 }, { 3, 2, 2 } }, extra)
		local lv = BD.levels(g.s)
		assert_eq(lv[H.idx(g, 2, 4)], 4)
		assert_eq(lv[H.idx(g, 3, 2)], 4)
		assert_eq(lv[H.idx(g, 5, 5)], 4, "a free piece on a tile")
		assert_eq(lv[H.idx(g, 1, 1)], 1, "a free piece")
		-- no `ice` goal: level 2, and the tile under the ice does not make it a goal cell
		local e2 = { goals = { { type = "light" } }, floor = extra.floor, overlay = ices(4).overlay }
		local g2 = fresh(P0, { { 2, 4 }, { 3, 2, 2 } }, e2)
		lv = BD.levels(g2.s)
		assert_eq(lv[H.idx(g2, 2, 4)], 2, "frozen on a tile: the hit would not light it")
		assert_eq(lv[H.idx(g2, 3, 2)], 2)
		assert_eq(lv[H.idx(g2, 5, 5)], 4)
	end)

	it("a Bird flies to the ice when the goal is open and takes one layer", function()
		local g = fresh(with(P0, 3, 3, "B"), { { 6, 6, 2 } })
		local o = H.obj_at(g, 6, 6)
		assert_same({ g:input({ type = "tap", at = { 3, 3 } }) }, { true, "ok" })
		local ev = rest(g)
		local fly = H.of_type(ev, "bird_fly")
		assert_same({ #fly, fly[1].tx, fly[1].ty }, { 1, 6, 6 })
		assert_eq(o.ice, 1)
		assert_eq(untouched(ev, o), "")
	end)
end)

describe("core ice: the carpet (10.8)", function()
	local function rug()
		return { goals = { { type = "carpet" } }, carpet = { { 0, 3 } }, overlay = ices(4).overlay }
	end

	it("a carrying effect hit covers the frozen cell (the ice is no blocker) and takes a layer", function()
		local g = fresh(P0, { { 3, 4, 2 } }, rug())
		local o = H.obj_at(g, 3, 4)
		assert_same({ g:input({ type = "booster", booster = "row_light", row = 4 }) }, { true, "ok" })
		local ev = rest(g)
		assert_true(g:cells()[H.idx(g, 3, 4)].carpet)
		assert_eq(o.ice, 1)
		assert_eq(untouched(ev, o), "")
	end)

	it("the adjacent hit that melts the ice lays no carpet", function()
		local e = rug()
		e.carpet = { { 0, 5 } }
		local g = fresh(PA, { { 4, 6 } }, e)
		g:input(MOVE)
		rest(g)
		assert_true(g:cells()[H.idx(g, 3, 6)].carpet, "the group stood on the carpet")
		assert_eq(g:cells()[H.idx(g, 4, 6)].carpet, nil)
	end)
end)

describe("core ice: shuffle, Remix, hint and the dead board (12)", function()
	it("a shuffle keeps every frozen piece in its cell with its colour and its ice", function()
		local frozen = { { 1, 1 }, { 3, 3, 2 }, { 6, 6 }, { 2, 5 } }
		local g = fresh(P0, frozen)
		local before = {}
		for k, l in ipairs(frozen) do
			local o = H.obj_at(g, l[1], l[2])
			before[k] = { o.id, o.cell, o.color, o.ice }
		end
		assert_false(g:has_move())
		g.s.rest_flag = false
		local ev = rest(g)
		local sh = H.of_type(ev, "shuffle")
		assert_eq(#sh, 1, "a board without a move is shuffled")
		for k, l in ipairs(frozen) do
			local o = H.obj_at(g, l[1], l[2])
			assert_same({ o.id, o.cell, o.color, o.ice }, before[k])
			assert_eq(untouched(ev, o), "")
		end
		assert_true(g:has_move())
	end)

	it("the Remix booster does the same", function()
		local g = fresh(PA, { { 1, 6, 2 }, { 4, 2 } })
		local a, b = H.obj_at(g, 1, 6), H.obj_at(g, 4, 2)
		assert_same({ g:input({ type = "booster", booster = "remix" }) }, { true, "ok" })
		rest(g)
		assert_same({ a.cell, a.color, a.ice }, { 31, C.COLOR.purple, 2 })
		assert_same({ b.cell, b.ice }, { H.idx(g, 4, 2), 1 })
	end)

	it("a few free pieces among the ice: the dead board still gets a move (a Riff at worst)", function()
		local g = fresh(P0)
		for i = 1, g.s.N do
			if i ~= 1 and i ~= 20 then g.s.objs[g.s.slot[i]].ice = 2 end
		end
		assert_false(g:has_move())
		g.s.rest_flag = false
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "shuffle"), 1)
		assert_eq(#H.of_type(ev, "thawed"), 0)
		assert_true(g:has_move())
		assert_eq(g:status().state, "playing")
	end)

	it("12.2.4b: a board frozen solid gives up one piece for a Riff, and the goal counts it", function()
		local g = fresh(P0)
		for i = 1, g.s.N do g.s.objs[g.s.slot[i]].ice = 2 end
		assert_false(g:has_move())
		g.s.rest_flag = false
		local ev = H.steps(g, 1)
		local th = H.of_type(ev, "thawed")
		assert_eq(#th, 1)
		local sh = H.of_type(ev, "shuffle")[1]
		assert_same({ sh.riff.id, sh.riff.from }, { th[1].id, "ice" })
		local o = g.s.objs[th[1].id]
		assert_same({ o.kind, o.special, o.ice }, { C.K_SPECIAL, C.SP_RIFF, 0 })
		assert_same(g:status().goals, { 3 })
		assert_eq(#H.of_type(ev, "score"), 0)
		assert_eq(g:status().state, "playing")
		rest(g)
		assert_true(g:has_move(), "the Riff can be tapped")
		-- and the game goes on: tap after tap the board never locks
		for _ = 1, 12 do
			if g:status().state ~= "playing" then break end
			local h = g:hint()
			assert_true(h ~= nil, "a move exists")
			if h.at then g:input({ type = "tap", at = h.at }) else g:input({ type = "swap", from = h.from, to = h.to }) end
			rest(g, 3000)
			assert_true(g:is_stable())
		end
	end)

	it("the hint: a match beside the ice is goal progress while the `ice` goal is open", function()
		-- two equal moves: the top one comes first by index, the bottom one touches the frozen (4,6)
		local rows = with(with(PA, 5, 1, "pp"), 4, 2, "p")
		local top = { from = { 4, 1 }, to = { 4, 2 } }
		local bottom = { from = { 3, 5 }, to = { 3, 6 } }
		assert_same(fresh(rows):hint(), top)
		assert_same(fresh(rows, { { 4, 6 } }):hint(), bottom)
		assert_same(fresh(rows, { { 4, 6, 2 } }):hint(), bottom)
		-- no `ice` goal: no progress
		local other = { goals = { { type = "collect", color = "red", count = 99 } }, overlay = ices(4).overlay }
		assert_same(fresh(rows, { { 4, 6 } }, other):hint(), top)
		-- goal already met: no progress either
		local g = fresh(rows, { { 4, 6 } })
		g.s.goal_left[1] = 0
		assert_same(g:hint(), top)
	end)
end)

describe("core ice: hash and determinism (17)", function()
	it("the ice is part of the state hash on a level with ice", function()
		local g = fresh(PA, { { 1, 6, 1 } })
		local h1 = g:hash()
		H.obj_at(g, 1, 6).ice = 2
		local h2 = g:hash()
		H.obj_at(g, 1, 6).ice = 0
		assert_true(h1 ~= h2 and h1 ~= g:hash() and h2 ~= g:hash())
	end)

	it("a level without ice hashes with the old layout (nothing is appended)", function()
		local HS = require("core.hash")
		local g = H.game(FULL)
		assert_false(g.s.level.has_ice)
		local h = g:hash()
		g.s.level.has_ice = true
		local longer = HS.state(g.s)
		g.s.level.has_ice = false
		assert_true(h ~= longer)
		-- the appended part is exactly 36 zeros folded after the old hash
		local x = h
		for _ = 1, 36 do x = HS.fold(x, 0) end
		assert_eq(x, longer)
	end)

	local function level()
		return H.load({ "######", "######", "#r##g#", "######", "######", "######" }, {
			moves = 30,
			goals = { { type = "ice", count = 8 } },
			overlay = {
				{ at = { 1, 2 }, type = "ice", hp = 2 }, { at = { 4, 2 }, type = "ice", hp = 1 },
				{ at = { 0, 5 }, type = "ice", hp = 1 }, { at = { 5, 5 }, type = "ice", hp = 2 },
				{ at = { 2, 0 }, type = "ice", hp = 1 }, { at = { 3, 4 }, type = "ice", hp = 2 },
				{ at = { 2, 3 }, type = "ice", hp = 1 }, { at = { 3, 3 }, type = "ice", hp = 1 },
			},
		})
	end

	local function play(lvl, seed)
		local g = core.new(lvl, { seed = seed })
		local trace = {}
		for _ = 1, 30 do
			if g:status().state ~= "playing" then break end
			local h = g:hint()
			if not h then break end
			if h.at then g:input({ type = "tap", at = h.at }) else g:input({ type = "swap", from = h.from, to = h.to }) end
			for _ = 1, 3000 do
				g:step()
				if g:is_stable() then break end
			end
			trace[#trace + 1] = g:hash()
		end
		return g, trace
	end

	it("the same seed gives the same game, a clone goes the same way, and the replay plays back", function()
		local lvl = level()
		for seed = 1, 4 do
			local g1, t1 = play(lvl, seed)
			local g2, t2 = play(lvl, seed)
			assert_same(t1, t2)
			assert_true(#t1 >= 5)
			assert_eq(g1:hash(), g2:hash())
			local c = g1:clone()
			assert_eq(c:hash(), g1:hash())
			local _, ok, why = core.playback(lvl, g1:replay())
			assert_true(ok, tostring(why))
		end
	end)

	it("normal and turbo timing melt the same ice", function()
		local lvl = level()
		for seed = 1, 3 do
			local a = core.new(lvl, { seed = seed })
			local b = core.new(lvl, { seed = seed, timing = "turbo" })
			for _, g in ipairs({ a, b }) do
				local h = g:hint()
				g:input({ type = "swap", from = h.from, to = h.to })
				for _ = 1, 3000 do
					g:step()
					if g:is_stable() then break end
				end
			end
			assert_same(a:status().goals, b:status().goals)
			assert_eq(a:status().score, b:status().score)
		end
	end)

	it("the hint-following player thaws pieces on the way (the element is playable)", function()
		local lvl = level()
		local thawed = 0
		for seed = 1, 6 do
			local g = play(lvl, seed)
			thawed = thawed + (8 - g:status().goals[1])
		end
		assert_true(thawed >= 24, "thawed " .. thawed .. " pieces in 6 games")
	end)
end)
