-- The timed curtain (10.7): cells that close and open by the count of the moves spent. Closed, a cell is frozen
-- and protected (no swap, no match, no hit, no fall); open, it is an ordinary cell.

local core = require("core.game")
local C = require("core.const")
local M = require("core.match")
local BD = require("core.bird")
local HS = require("core.hash")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- a board without a match and without a move (no purple in it)
local P0 = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }
-- the swap (3,5) -> (3,6) makes a purple line of three in the bottom row: (1,6) (2,6) (3,6); no other move
local PA = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "bypgby", "ppgbyr" }
local MOVE = { type = "swap", from = { 3, 5 }, to = { 3, 6 } }

-- The level block: cells as 1-based {x, y}.
local function curtain(cells, closed, open, start)
	local covers = {}
	for k, c in ipairs(cells) do covers[k] = { c[1] - 1, c[2] - 1 } end
	return { covers = covers, closed_moves = closed or 3, open_moves = open or 2, start = start or "closed" }
end

-- A live board from a picture with a curtain over `cells`.
local function fresh(rows, cells, closed, open, start, extra, opts)
	extra = extra or {}
	extra.curtain = curtain(cells, closed, open, start)
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

-- Adds a move in the top row that has nothing to do with the rest: (4,1) -> (3,1) makes an orange line.
local function top_move(rows)
	return with(with(with(rows, 1, 1, "o"), 2, 1, "o"), 4, 1, "o")
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

local function phase(g)
	local c = g:status().curtain
	return c.phase, c.left
end

local function id_at(g, x, y)
	local o = H.obj_at(g, x, y)
	return o and o.id or 0
end

describe("core curtain: level schema and rules (2.0, 2.1)", function()
	it("accepts the block and keeps the cells and the rhythm", function()
		local lvl = H.load(FULL, { curtain = curtain({ { 3, 4 }, { 2, 4 }, { 2, 5 } }, 2, 4, "open") })
		assert_same(lvl.curtain.cells, { 20, 21, 26 })
		assert_same({ lvl.curtain.closed_moves, lvl.curtain.open_moves, lvl.curtain.start_closed }, { 2, 4, false })
		assert_true(lvl.curtain.at[21] and not lvl.curtain.at[22])
		assert_eq(H.load(FULL).curtain, nil)
		-- a `piece` and a floor tile may stand under it
		assert_eq(errors_of(H.level({ "######", "######", "##r###", "######", "######", "######" },
			{ curtain = curtain({ { 3, 3 } }), floor = { { at = { 2, 2 }, hp = 2 } } })), "")
	end)

	it("checks the fields of the block", function()
		local function bad(change, text)
			local cu = curtain({ { 3, 4 } })
			for k, v in pairs(change) do
				if v == "nil" then cu[k] = nil else cu[k] = v end
			end
			expect(H.level(FULL, { curtain = cu }), text)
		end
		bad({ covers = "nil" }, "2.1.1 curtain: covers must be a non-empty list of [x, y]")
		bad({ covers = {} }, "2.1.1 curtain: covers must be a non-empty list of [x, y]")
		bad({ covers = { { 1 } } }, "2.1.1 curtain: covers[1]: [x, y] required")
		bad({ closed_moves = 0 }, "2.1.1 curtain: closed_moves 1..9 required")
		bad({ closed_moves = 10 }, "2.1.1 curtain: closed_moves 1..9 required")
		bad({ open_moves = "nil" }, "2.1.1 curtain: open_moves 1..9 required")
		bad({ start = "ajar" }, "2.1.1 curtain: start 'closed' or 'open' required")
		bad({ start = "nil" }, "2.1.1 curtain: start 'closed' or 'open' required")
		bad({ cells = {} }, "2.1.1 curtain: unknown key 'cells'")
		expect(H.level(FULL, { curtain = 3 }), "2.1.1 curtain: object required")
	end)

	it("2.1.2: on existing cells, one curtain a cell", function()
		expect(H.level({ "######", "######", "##.###", "######", "######", "######" }, { curtain = curtain({ { 3, 3 } }) }),
			"2.1.2 curtain is not on an existing cell at 2,2")
		expect(H.level(FULL, { curtain = curtain({ { 9, 3 } }) }), "2.1.2 curtain is not on an existing cell at 8,2")
		expect(H.level(FULL, { curtain = curtain({ { 3, 3 }, { 3, 3 } }) }), "2.1.2 two curtains in one cell at 2,2")
	end)

	it("2.1.12: only a regular piece and a floor tile under it; no spawner, no exit", function()
		for _, ch in ipairs({ "X", "K", "N", "A", "R", "S", "B", "D" }) do
			expect(H.level(with(FULL, 3, 3, ch), { curtain = curtain({ { 3, 3 } }) }),
				"2.1.12 only a regular piece may stand under a curtain at 2,2")
		end
		expect(H.level(FULL, { curtain = curtain({ { 3, 3 } }), slots = { { at = { 2, 2 }, type = "column", hp = 6 } } }),
			"2.1.12 only a regular piece may stand under a curtain at 2,2")
		expect(H.level(FULL, { curtain = curtain({ { 4, 4 } }), slots = { { at = { 2, 2 }, type = "column", hp = 6 } } }),
			"2.1.12 only a regular piece may stand under a curtain at 3,3")
		expect(H.level(FULL, { curtain = curtain({ { 3, 3 } }), overlay = { { at = { 2, 2 }, type = "wires", hp = 1 } } }),
			"2.1.12 wires or a chain under a curtain at 2,2")
		expect(H.level(FULL, { curtain = curtain({ { 3, 3 } }), overlay = { { at = { 2, 2 }, type = "chain", hp = 1 } },
			goals = { { type = "chains", count = 1 } } }), "2.1.12 wires or a chain under a curtain at 2,2")
		expect(H.level(FULL, { curtain = curtain({ { 3, 1 } }) }), "2.1.12 curtain over a spawner at 2,0")
		local drop = { goals = { { type = "drop", count = 1 } }, coconut = { total = 1, on_board_max = 1, gap_moves = 0 } }
		drop.curtain = curtain({ { 3, 6 } })
		expect(H.level(FULL, drop), "2.1.12 curtain over an exit at 2,5")
		drop.curtain = curtain({ { 3, 5 } })
		assert_eq(errors_of(H.level(FULL, drop)), "")
		-- without mics or coconuts the bottom row is an ordinary row
		assert_eq(errors_of(H.level(FULL, { curtain = curtain({ { 3, 6 } }) })), "")
	end)

	it("2.1.6: the curtain is one of the three elements a level may have", function()
		local three = { curtain = curtain({ { 3, 3 } }), floor = { { at = { 0, 5 }, hp = 1 } },
			slots = { { at = { 0, 3 }, type = "record_box", hp = 1 } } }
		assert_eq(errors_of(H.level(FULL, three)), "")
		three.slots[2] = { at = { 5, 3 }, type = "concrete", hp = 1 }
		expect(H.level(FULL, three), "2.1.6 more than three different elements")
	end)

	it("the curtain block is part of the canonical form, so of the level hash", function()
		local a = H.load(FULL, { curtain = curtain({ { 3, 3 } }, 2, 2) })
		local b = H.load(FULL, { curtain = curtain({ { 3, 3 } }, 2, 3) })
		assert_true(a.hash ~= b.hash and a.hash ~= H.load(FULL).hash)
		assert_true(string.find(a.canonical, '"curtain":{"closed_moves":2,"covers":[[2,2]],"open_moves":2,"start":"closed"}', 1, true) ~= nil)
	end)

	it("a start board never hides a ready-made match under a closed curtain, and has three moves outside it", function()
		local lvl = H.load(FULL, { curtain = curtain({ { 2, 3 }, { 3, 3 }, { 4, 3 }, { 5, 3 }, { 3, 4 }, { 4, 4 } }) })
		for seed = 1, 25 do
			local g = core.new(lvl, { seed = seed })
			assert_true(#g:moves() >= 3, "seed " .. seed)
			g.s.cur_closed = false
			assert_false(M.any_match(M.color_map(g.s), 6, 6), "seed " .. seed)
		end
	end)
end)

describe("core curtain: the phase counts the moves spent (10.7)", function()
	it("starts in the phase of the level and tells it in status(), cells() and pieces()", function()
		local g = fresh(PA, { { 5, 3 }, { 5, 4 } }, 3, 2)
		assert_same({ phase(g) }, { "closed", 3 })
		local cells = g:cells()
		assert_true(cells[17].curtain == true and cells[23].curtain == true and cells[16].curtain == nil)
		local veiled = {}
		for _, p in ipairs(g:pieces()) do
			if p.veiled then veiled[#veiled + 1] = p.x .. "," .. p.y end
		end
		assert_same(veiled, { "5,3", "5,4" })
		local o = fresh(PA, { { 5, 3 } }, 3, 2, "open")
		assert_same({ phase(o) }, { "open", 2 })
		for _, p in ipairs(o:pieces()) do assert_eq(p.veiled, nil) end
		-- a level without curtains says nothing
		local plain = H.game(FULL)
		assert_eq(plain:status().curtain, nil)
		assert_eq(plain:cells()[17].curtain, nil)
	end)

	it("one move takes one off; at 0 the phase changes and the count starts again; events say so", function()
		local g = fresh(PA, { { 5, 3 }, { 5, 4 } }, 2, 3)
		local ev = spend(g)
		assert_same({ phase(g) }, { "closed", 1 })
		local left = H.of_type(ev, "curtain_left")
		assert_eq(#left, 1)
		assert_same({ left[1].phase, left[1].left }, { "closed", 1 })
		assert_eq(#H.of_type(ev, "curtain"), 0)
		ev = spend(g)
		assert_same({ phase(g) }, { "open", 3 })
		local ch = H.of_type(ev, "curtain")
		assert_eq(#ch, 1)
		assert_same({ ch[1].phase, ch[1].left, ch[1].reason }, { "open", 3, "move" })
		assert_same(ch[1].cells, { { 5, 3 }, { 5, 4 } })
		spend(g)
		spend(g)
		assert_same({ phase(g) }, { "open", 1 })
		ev = spend(g)
		ch = H.of_type(ev, "curtain")
		assert_same({ ch[1].phase, ch[1].left, ch[1].reason }, { "closed", 2, "move" })
		assert_same({ phase(g) }, { "closed", 2 })
	end)

	it("two moves that settle together are two counts (it may even open and close in one step)", function()
		local g = fresh(PA, { { 5, 3 } }, 2, 1)
		local ev = spend(g, 3)
		local ch = H.of_type(ev, "curtain")
		assert_eq(#ch, 2)
		assert_same({ ch[1].phase, ch[2].phase }, { "open", "closed" })
		assert_same({ phase(g) }, { "closed", 2 })
	end)

	it("a real swap counts once, however long its cascade; a failed swap and a booster do not count", function()
		local g = fresh(PA, { { 5, 3 } }, 3, 2)
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }) }, { true, "fail" })
		local ev = rest(g)
		assert_same({ phase(g) }, { "closed", 3 })
		assert_true(g:input({ type = "booster", booster = "stick", at = { 1, 1 } }))
		for _, e in ipairs(rest(g)) do ev[#ev + 1] = e end
		assert_eq(#H.of_type(ev, "curtain_left") + #H.of_type(ev, "curtain"), 0)
		assert_same({ g:input(MOVE) }, { true, "ok" })
		ev = rest(g)
		assert_true(#H.of_type(ev, "match") >= 1)
		local n = 0
		for _, e in ipairs(ev) do
			if e.type == "curtain_left" or (e.type == "curtain" and e.reason == "move") then n = n + 1 end
		end
		assert_eq(n, 1, "one count for one move")
	end)

	it("a refunded swap does not count", function()
		-- two swaps in flight: the second one loses its match to the first and is given back
		local g = fresh(with(with(PA, 4, 5, "p"), 4, 6, "g"), { { 5, 2 } }, 3, 2)
		-- row 5 "byppby", row 6 "ppggyr": (3,5)->(3,6) and (4,5)->(4,6) both complete the purple line (1,6)(2,6)
		assert_same({ g:input(MOVE) }, { true, "ok" })
		local ok, res = g:input({ type = "swap", from = { 4, 5 }, to = { 4, 6 } })
		local ev = rest(g)
		local counts = 0
		for _, e in ipairs(ev) do
			if e.type == "curtain_left" or (e.type == "curtain" and e.reason == "move") then counts = counts + 1 end
		end
		local backs = #H.of_type(ev, "swap_back")
		local accepted = (ok and res == "ok") and 2 or 1
		assert_eq(counts, accepted - backs)
	end)
end)

describe("core curtain: a closed cell is protected (10.7)", function()
	it("is not swapped, from either side, and a special swiped onto it is a tap", function()
		local g = fresh(with(PA, 5, 2, "R"), { { 5, 3 } })
		assert_same({ g:input({ type = "swap", from = { 5, 3 }, to = { 4, 3 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "swap", from = { 4, 3 }, to = { 5, 3 } }) }, { false, "not_movable" })
		assert_eq(g:can_swap({ 5, 3 }, { 5, 4 }), "reject")
		assert_same({ g:input({ type = "swap", from = { 5, 2 }, to = { 5, 3 } }) }, { true, "ok" })
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "swap"), 0, "the Riff fired where it stood")
		assert_eq(H.of_type(ev, "activate")[1].y, 2)
	end)

	it("a special under it cannot be tapped", function()
		local g = fresh(with(PA, 5, 3, "R"), { { 5, 3 } })
		assert_same({ g:input({ type = "tap", at = { 5, 3 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "swap", from = { 5, 3 }, to = { 4, 3 } }) }, { false, "not_movable" })
		assert_true(g:has_move(), "the purple move is still there")
		local h = g:hint()
		assert_same({ h.from, h.to }, { { 3, 5 }, { 3, 6 } })
	end)

	it("takes no part in a match: the line through it is no line", function()
		local g = fresh(PA, { { 2, 6 } })
		assert_eq(g:can_swap(MOVE.from, MOVE.to), "fail")
		assert_same(g:moves(), {})
		local open = fresh(PA, { { 2, 6 } }, 3, 2, "open")
		assert_eq(open:can_swap(MOVE.from, MOVE.to), "ok")
	end)

	it("a match next to it does not touch what is under it (a box, a tile)", function()
		local g = fresh(with(PA, 2, 5, "X"), { { 2, 5 } }, 3, 2, "closed",
			{ floor = { { at = { 1, 4 }, hp = 1 } }, goals = { { type = "light" } } })
		local box = id_at(g, 2, 5)
		assert_true(g:input(MOVE))
		rest(g)
		assert_eq(id_at(g, 2, 5), box)
		assert_eq(H.obj_at(g, 2, 5).hp, 1)
		-- the same board with the curtain open: the box breaks
		local o = fresh(with(PA, 2, 5, "X"), { { 2, 5 } }, 3, 2, "open")
		box = id_at(o, 2, 5)
		assert_true(o:input(MOVE))
		rest(o)
		assert_true(id_at(o, 2, 5) ~= box)
	end)

	it("a Riff, a row light and the stick pass over it: the piece, the tile and the label stay", function()
		local g = fresh(with(PA, 1, 3, "R"), { { 5, 3 } }, 3, 2, "closed",
			{ floor = { { at = { 4, 2 }, hp = 2 }, { at = { 3, 2 }, hp = 1 } }, goals = { { type = "light" } } })
		local piece = id_at(g, 5, 3)
		local neighbour = id_at(g, 4, 3)
		H.arm(g, { 1, 3 })
		local ev = rest(g)
		assert_eq(id_at(g, 5, 3), piece)
		assert_true(id_at(g, 4, 3) ~= neighbour, "the cell next to it was hit")
		assert_eq(g.s.floor[17], 2, "the tile under the curtain is whole")
		assert_eq(g.s.floor[16], 0, "the tile next to it is lit")
		for _, e in ipairs(ev) do
			assert_false((e.type == "hit" or e.type == "clear") and e.x == 5 and e.y == 3)
		end
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 5, 3 } }) }, { false, "bad_cell" })
		assert_true(g:input({ type = "booster", booster = "row_light", row = 3 }))
		rest(g)
		assert_eq(id_at(g, 5, 3), piece)
		assert_eq(g.s.floor[17], 2)
		assert_eq(#H.obj_at(g, 5, 3).pins, 0, "no pin is left on it")
	end)

	it("a row light is refused when the curtain is all there is to hit", function()
		local g = fresh(PA, { { 1, 3 }, { 2, 3 }, { 3, 3 }, { 4, 3 }, { 5, 3 }, { 6, 3 } })
		assert_same({ g:input({ type = "booster", booster = "row_light", row = 3 }) }, { false, "bad_cell" })
		assert_true(g:input({ type = "booster", booster = "col_light", col = 2 }))
		local id = id_at(g, 2, 3)
		rest(g)
		assert_eq(id_at(g, 2, 3), id)
	end)

	it("the Grand finale hits every layer of every cell, but not a closed one", function()
		local rows = with(with(PA, 1, 2, "D"), 2, 2, "D")
		local g = fresh(rows, { { 5, 3 }, { 5, 4 } }, 3, 2, "closed",
			{ floor = { { at = { 4, 2 }, hp = 2 }, { at = { 0, 5 }, hp = 2 } }, goals = { { type = "light" } } })
		local a, b = id_at(g, 5, 3), id_at(g, 5, 4)
		H.arm(g, { 2, 2 }, { 1, 2 })
		rest(g)
		assert_same({ id_at(g, 5, 3), id_at(g, 5, 4) }, { a, b })
		assert_eq(g.s.floor[17], 2)
		assert_true(g.s.floor[31] < 2, "an open tile was hit")
	end)

	it("a Disco ball does not take the colour under it, and does not count it", function()
		-- (5,3) is red; the ball takes red: every red piece goes but the one under the curtain
		local g = fresh(with(PA, 1, 1, "D"), { { 5, 3 } })
		local id = id_at(g, 5, 3)
		assert_eq(H.obj_at(g, 5, 3).color, 1)
		H.arm(g, { 1, 1 }, nil, 1, 1, 1)
		local ev = rest(g)
		assert_eq(id_at(g, 5, 3), id)
		assert_true(#H.of_type(ev, "disco_ray") >= 5)
		for _, e in ipairs(H.of_type(ev, "disco_ray")) do assert_false(e.tx == 5 and e.ty == 3) end
		-- mf(): a board whose only purple pieces are under the curtain has no purple to choose
		local B = require("core.board")
		local m = fresh({ "______", "pppbyr", "______", "______", "______", "______" }, { { 1, 2 }, { 2, 2 }, { 3, 2 } }, 3, 2, "open")
		assert_eq(B.most_frequent(m.s, false), 6)
		m.s.cur_closed = true
		assert_true(B.most_frequent(m.s, false) ~= 6)
	end)

	it("the Bird never flies to it", function()
		local g = fresh(PA, { { 5, 3 }, { 5, 4 } }, 3, 2, "closed",
			{ floor = { { at = { 4, 2 }, hp = 1 } }, goals = { { type = "light" } } })
		local lv = BD.levels(g.s)
		assert_same({ lv[17], lv[23] }, { 0, 0 })
		assert_true(lv[16] >= 1)
		g.s.cur_closed = false
		lv = BD.levels(g.s)
		assert_same({ lv[17], lv[23] }, { 4, 1 }, "open: the unlit tile is a goal target again")
	end)

	it("the Crossfader refuses it, the Remix leaves it where it is", function()
		local g = fresh(PA, { { 5, 3 }, { 5, 4 } })
		assert_same({ g:input({ type = "booster", booster = "swap", at = { 5, 3 }, to = { 1, 1 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "booster", booster = "swap", at = { 1, 1 }, to = { 5, 4 } }) }, { false, "not_movable" })
		local a, b = id_at(g, 5, 3), id_at(g, 5, 4)
		local ca, cb = H.obj_at(g, 5, 3).color, H.obj_at(g, 5, 4).color
		assert_true(g:input({ type = "booster", booster = "remix" }))
		local ev = rest(g)
		local sh = H.of_type(ev, "shuffle")[1]
		assert_true(sh ~= nil and #sh.moves + #sh.recolors > 0)
		for _, mv in ipairs(sh.moves) do assert_true(mv.id ~= a and mv.id ~= b) end
		for _, rc in ipairs(sh.recolors) do assert_true(rc.id ~= a and rc.id ~= b) end
		assert_same({ id_at(g, 5, 3), id_at(g, 5, 4) }, { a, b })
		assert_same({ H.obj_at(g, 5, 3).color, H.obj_at(g, 5, 4).color }, { ca, cb })
	end)

	it("noise neither grows under it nor out of it; `continue` puts no Riff under it", function()
		local F = require("core.flow")
		-- a noise in the open with one neighbour under the curtain and the others no regular pieces
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrMb", "byrMNM", "ppgbMr" }, { { 5, 4 } })
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		F.noise_growth(g.s)
		assert_eq(#H.of_type(g:drain_events(), "noise_spread"), 0)
		-- a noise under the curtain does not creep out
		g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgNy", "ppgbyr" }, { { 5, 5 } })
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		F.noise_growth(g.s)
		assert_eq(#H.of_type(g:drain_events(), "noise_spread"), 0)
		g.s.cur_closed = false
		F.noise_growth(g.s)
		assert_eq(#H.of_type(g:drain_events(), "noise_spread"), 1)
		-- continue: the only regular pieces are under the curtain
		g = fresh({ "MMMMMM", "MrrMMM", "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM" }, { { 2, 2 }, { 3, 2 } })
		g.s.state = C.G_OUT
		assert_true(g:input({ type = "continue", moves = 5, riff = true }))
		assert_eq(#H.of_type(g:drain_events(), "continue_riff"), 0)
		assert_same(g.s.unplaced, { C.IT_CONT_RIFF })
	end)
end)

describe("core curtain: gravity around a closed cell (10.7)", function()
	it("the piece under it stays, the pieces above rest on it, the cells below refill from the sides", function()
		local g = fresh(with(with(PA, 5, 4, "_"), 5, 5, "_"), { { 5, 3 } }, 9, 2)
		local under, above = id_at(g, 5, 3), id_at(g, 5, 2)
		local ev = {}
		for _ = 1, 12 do
			g:step()
			for _, e in ipairs(g:drain_events()) do ev[#ev + 1] = e end
		end
		assert_same({ id_at(g, 5, 3), id_at(g, 5, 2) }, { under, above }, "nothing fell through")
		for _, e in ipairs(rest(g)) do ev[#ev + 1] = e end
		assert_eq(#H.of_type(ev, "curtain"), 0)
		assert_eq(id_at(g, 5, 3), under)
		assert_eq(H.obj_at(g, 5, 3).state, C.S_IDLE)
		assert_true(id_at(g, 5, 4) ~= 0 and id_at(g, 5, 5) ~= 0, "the cells below were filled by the diagonal rule")
		for _, e in ipairs(H.of_type(ev, "spawn")) do assert_true(e.x ~= 5 or e.y < 3, "no spawn comes through the curtain") end
	end)

	it("an empty cell under it stays empty until it opens", function()
		local g = fresh(with(PA, 5, 3, "_"), { { 5, 3 } }, 1, 2)
		local above = id_at(g, 5, 2)
		H.steps(g, 30)
		assert_eq(id_at(g, 5, 3), 0)
		assert_eq(id_at(g, 5, 2), above)
		assert_true(g:is_stable(), "a hole under a closed curtain is rest")
		spend(g)
		assert_same({ phase(g) }, { "open", 2 })
		assert_true(id_at(g, 5, 3) ~= 0, "open: the column falls in")
	end)

	it("a full drape row holds the board above it; below it the cells stay holes until it opens", function()
		local rows = top_move({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "______", "ppgbyr" })
		local g = fresh(rows, { { 1, 4 }, { 2, 4 }, { 3, 4 }, { 4, 4 }, { 5, 4 }, { 6, 4 } }, 1, 2)
		local ev = H.steps(g, 40)
		assert_eq(#H.of_type(ev, "curtain"), 0)
		for x = 1, 6 do assert_eq(id_at(g, x, 5), 0) end
		assert_same(H.picture(g)[4], "gbyrgb")
		assert_true(g:is_stable())
		spend(g)
		for x = 1, 6 do assert_true(id_at(g, x, 5) ~= 0) end
	end)
end)

describe("core curtain: an open cell is an ordinary cell (10.7)", function()
	it("swaps, matches, is hit and falls like any other", function()
		local g = fresh(PA, { { 1, 6 }, { 2, 6 }, { 3, 6 }, { 3, 5 } }, 3, 4, "open")
		assert_same({ g:input(MOVE) }, { true, "ok" })
		local ev = rest(g)
		local m = H.of_type(ev, "match")[1]
		assert_same(m.cells, { { 1, 6 }, { 2, 6 }, { 3, 6 } })
		assert_same({ phase(g) }, { "open", 3 })
		assert_true(g:input({ type = "booster", booster = "stick", at = { 2, 6 } }))
	end)

	it("matches that stand ready under it resolve when it opens: `curtain`, then the cascade one tick later", function()
		-- purple (1,6) (2,6) (3,6) with a closed curtain over (2,6): no match while it is closed
		local rows = with(with(PA, 3, 6, "p"), 3, 5, "g")
		local g = fresh(rows, { { 2, 6 } }, 1, 2, "closed", { goals = { { type = "collect", color = "purple", count = 99 } } })
		-- a move elsewhere keeps the deadlock rule out of it
		H.board(g, top_move(rows))
		g.s.dirty = true
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "match"), 0)
		assert_same({ phase(g) }, { "closed", 1 })
		local left = g:status().goals[1]
		ev = spend(g)
		local opened, matched
		for k, e in ipairs(ev) do
			if e.type == "curtain" and not opened then opened = k end
			if e.type == "match" and not matched then matched = k end
		end
		assert_true(opened ~= nil and matched ~= nil and opened < matched)
		assert_eq(ev[opened].phase, "open")
		assert_eq(ev[matched].t, ev[opened].t + 1)
		assert_same(ev[matched].cells, { { 1, 6 }, { 2, 6 }, { 3, 6 } })
		assert_eq(g:status().goals[1], left - 3)
		assert_same({ phase(g) }, { "open", 2 }, "the cascade of the opening is no move")
	end)
end)

describe("core curtain: no soft lock (10.7)", function()
	it("no move only because the curtains are closed: they open at once, with a whole open phase, no shuffle", function()
		local g = fresh(PA, { { 2, 6 } }, 9, 3)
		assert_false(g:has_move())
		g.s.dirty = true
		local ev = rest(g)
		local ch = H.of_type(ev, "curtain")
		assert_eq(#ch, 1)
		assert_same({ ch[1].phase, ch[1].left, ch[1].reason }, { "open", 3, "deadlock" })
		assert_eq(#H.of_type(ev, "shuffle"), 0)
		assert_true(g:has_move())
		assert_eq(g:status().state, "playing")
		assert_same({ g:input(MOVE) }, { true, "ok" })
	end)

	it("every piece under a closed drape: it opens too", function()
		local cells = {}
		for y = 2, 6 do
			for x = 1, 6 do cells[#cells + 1] = { x, y } end
		end
		local g = fresh(PA, cells, 9, 2)
		g.s.dirty = true
		local ev = rest(g)
		assert_eq(H.of_type(ev, "curtain")[1].reason, "deadlock")
		assert_same({ phase(g) }, { "open", 2 })
	end)

	it("still no move with the curtains open: the ordinary shuffle of 12.2 follows", function()
		local g = fresh(P0, { { 5, 3 } }, 9, 2)
		g.s.dirty = true
		local ev = rest(g)
		local kinds = {}
		for _, e in ipairs(ev) do
			if e.type == "curtain" or e.type == "shuffle" then kinds[#kinds + 1] = e.type end
		end
		assert_same(kinds, { "curtain", "shuffle" })
		assert_true(g:has_move())
	end)

	it("the last move is spent while it is closed: out_of_moves as usual, and `continue` goes on", function()
		local g = fresh(PA, { { 5, 3 } }, 9, 2)
		g.s.moves_left = 1
		assert_true(g:input(MOVE))
		rest(g)
		assert_eq(g:status().state, "out_of_moves")
		assert_same({ phase(g) }, { "closed", 8 })
		assert_true(g:input({ type = "continue", moves = 5 }))
		assert_eq(g:status().state, "playing")
	end)

	it("the curtains open for the final concert", function()
		local g = fresh(PA, { { 5, 3 } }, 9, 2, "closed", { goals = { { type = "collect", color = "purple", count = 3 } } })
		assert_true(g:input(MOVE))
		local ev = {}
		for _ = 1, 3000 do
			g:step()
			for _, e in ipairs(g:drain_events()) do ev[#ev + 1] = e end
			if g:status().state == "complete" then break end
		end
		assert_eq(g:status().state, "complete")
		local ch = H.of_type(ev, "curtain")
		assert_same({ ch[#ch].phase, ch[#ch].reason }, { "open", "concert" })
		assert_eq(g:status().curtain.phase, "open")
	end)
end)

describe("core curtain: determinism and the hash (17.2)", function()
	local function level()
		return H.load(FULL, { moves = 40, curtain = curtain({ { 2, 3 }, { 3, 3 }, { 4, 3 }, { 3, 4 } }, 2, 2),
			floor = { { at = { 2, 2 }, hp = 2 }, { at = { 2, 3 }, hp = 1 } },
			goals = { { type = "light" }, { type = "collect", color = "red", count = 200 } } })
	end

	-- plays the first move of moves() (or the hint's tap) until the moves are out; returns the log
	local function play(g, n)
		local log = {}
		for _ = 1, n do
			g:run_to_rest()
			if g:status().state ~= "playing" then break end
			local st = g:status().curtain
			log[#log + 1] = st.phase .. st.left
			local mv = g:moves()[1]
			local cmd
			if mv then cmd = { type = "swap", from = mv.from, to = mv.to } else
				local h = g:hint()
				cmd = h and h.at and { type = "tap", at = h.at } or nil
			end
			if not cmd then break end
			-- never into a closed cell
			if st.phase == "closed" and cmd.type == "swap" then
				local cells = g:cells()
				assert_true(not cells[(cmd.from[2] - 1) * 6 + cmd.from[1]].curtain)
				assert_true(not cells[(cmd.to[2] - 1) * 6 + cmd.to[1]].curtain)
			end
			assert_true(g:input(cmd))
		end
		g:run_to_rest()
		return log
	end

	it("the same seed and commands give the same game; the replay plays back", function()
		local lvl = level()
		local a = core.new(lvl, { seed = 7 })
		local b = core.new(lvl, { seed = 7 })
		local la, lb = play(a, 25), play(b, 25)
		assert_same(la, lb)
		assert_true(#la >= 10)
		assert_eq(a:hash(), b:hash())
		local seen = {}
		for _, v in ipairs(la) do seen[string.sub(v, 1, 4)] = true end
		assert_true(seen.clos and seen.open, "both phases were played")
		local _, ok, why = core.playback(lvl, a:replay())
		assert_true(ok, why)
		-- in turbo the phases follow the same moves
		local t = core.new(lvl, { seed = 7, timing = "turbo" })
		assert_true(#play(t, 25) >= 10)
	end)

	it("a clone carries the phase and goes its own way", function()
		local g = core.new(level(), { seed = 3 })
		play(g, 3)
		local c = g:clone()
		assert_eq(c:hash(), g:hash())
		assert_same(c:status().curtain, g:status().curtain)
		play(c, 4)
		assert_true(c:hash() ~= g:hash())
		assert_eq(g:clone():hash(), g:hash())
	end)

	it("the phase and the count are in the hash of a level with curtains, and only there", function()
		local g = core.new(level(), { seed = 3 })
		local h = g:hash()
		g.s.cur_left = g.s.cur_left + 1
		assert_true(g:hash() ~= h)
		g.s.cur_left = g.s.cur_left - 1
		g.s.cur_closed = not g.s.cur_closed
		assert_true(g:hash() ~= h)
		g.s.cur_closed = not g.s.cur_closed
		assert_eq(g:hash(), h)
		-- a level without curtains: the layout of 17.2 is the old one (its last values are the four generators)
		local plain = H.game(FULL, nil, { seed = 5 })
		assert_same({ plain.s.cur_closed, plain.s.cur_left }, { false, 0 })
		local s = plain.s
		local before = plain:hash()
		s.cur_left = 4
		assert_eq(plain:hash(), before)
		s.cur_left = 0
		-- and that hash is the fold of the old layout continued by nothing: one more value would change it
		assert_true(HS.fold(before, 0) ~= before)
	end)
end)
