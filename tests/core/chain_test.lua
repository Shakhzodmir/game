-- The chain (10.6): a lock on a regular piece. The piece falls like any other, is never swapped, matches
-- where it lands; only a match takes a link off (hp 1..2), every effect passes over it (goal `chains`).

local core = require("core.game")
local C = require("core.const")
local M = require("core.match")
local BD = require("core.bird")
local SH = require("core.shuffle")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- a board without a match and without a move (no purple in it)
local P0 = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }
-- the swap (3,5) -> (3,6) makes a purple line of three in the bottom row: (1,6) (2,6) (3,6)
local PA = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "bypgby", "ppgbyr" }
local MOVE = { type = "swap", from = { 3, 5 }, to = { 3, 6 } }

local function chains(count, list)
	local overlay = {}
	for k, c in ipairs(list or { { 0, 0, 1 }, { 1, 0, 1 }, { 2, 0, 1 }, { 3, 0, 1 } }) do
		overlay[k] = { at = { c[1], c[2] }, type = "chain", hp = c[3] }
	end
	return { goals = { { type = "chains", count = count or 4 } }, overlay = overlay }
end

-- A live board from a picture; `locks` = {{x, y, hp}, ...} chains the pieces of those cells.
local function fresh(rows, locks, extra, opts)
	local g = H.game(FULL, extra or chains(), opts)
	H.board(g, rows or P0)
	for _, l in ipairs(locks or {}) do H.obj_at(g, l[1], l[2]).chain = l[3] or 1 end
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

local function count_chained(g)
	local n = 0
	for _, p in ipairs(g:pieces()) do
		if p.chain then n = n + 1 end
	end
	return n
end

describe("core chain: level schema and rules (2.0, 2.1)", function()
	it("accepts a chain of hp 1 or 2 over a random cell or a `piece`, and the `chains` goal", function()
		assert_eq(errors_of(H.level(FULL, chains(2))), "")
		local lvl = H.load({ "######", "#r####", "######", "######", "######", "######" },
			chains(2, { { 1, 1, 2 }, { 4, 3, 1 } }))
		assert_same({ lvl.chain[8], lvl.chain[23], lvl.chain[1], lvl.wires[8] }, { 2, 1, 0, 0 })
		assert_same(lvl.goals, { { type = C.GOAL_CHAINS, param = 0, count = 2 } })
	end)

	it("checks the fields of the overlay and of the goal", function()
		expect(H.level(FULL, { overlay = { { at = { 0, 0 }, type = "chain", hp = 3 } } }), "2.1.1 overlay[1]: hp 1..2 required")
		expect(H.level(FULL, { overlay = { { at = { 0, 0 }, type = "chain" } } }), "2.1.1 overlay[1]: hp 1..2 required")
		expect(H.level(FULL, { overlay = { { at = { 0, 0 }, type = "rope", hp = 1 } } }), "2.1.1 overlay[1]: type 'wires' or 'chain' required")
		expect(H.level(FULL, { goals = { { type = "chains" } } }), "2.1.1 goals[1]: count >= 1 required")
		expect(H.level(FULL, { goals = { { type = "chains", count = 1, item = "chain" } } }), "2.1.1 goals[1]: unknown key 'item'")
		expect(H.level(FULL, { goals = { { type = "chain", count = 1 } } }), "collect|break|light|deliver|drop|chains required")
	end)

	it("2.1.2 / 2.1.3: one overlay a cell, and only over a regular piece", function()
		expect(H.level(FULL, { overlay = { { at = { 1, 1 }, type = "chain", hp = 1 }, { at = { 1, 1 }, type = "wires", hp = 1 } } }),
			"2.1.2 two overlay elements in one cell at 1,1")
		expect(H.level(FULL, { overlay = { { at = { 1, 1 }, type = "chain", hp = 1 }, { at = { 1, 1 }, type = "chain", hp = 2 } } }),
			"2.1.2 two overlay elements in one cell at 1,1")
		expect(H.level(FULL, { overlay = { { at = { 9, 1 }, type = "chain", hp = 1 } } }), "2.1.2 overlay is not on an existing cell")
		for _, ch in ipairs({ "R", "S", "B", "D", "X", "K", "N", "A" }) do
			expect(H.level(with(FULL, 2, 2, ch), { overlay = { { at = { 1, 1 }, type = "chain", hp = 1 } } }),
				"2.1.3 chain over a cell without a regular piece at 1,1")
		end
		local mic = { goals = { { type = "deliver", count = 1 } }, mic = { total = 1, on_board_max = 1, gap_moves = 0 },
			overlay = { { at = { 1, 1 }, type = "chain", hp = 1 } } }
		expect(H.level(with(FULL, 2, 2, "M"), mic), "2.1.3 chain over a cell without a regular piece at 1,1")
		local co = { goals = { { type = "drop", count = 1 } }, coconut = { total = 1, on_board_max = 1, gap_moves = 0 },
			overlay = { { at = { 1, 1 }, type = "chain", hp = 1 } } }
		expect(H.level(with(FULL, 2, 2, "C"), co), "2.1.3 chain over a cell without a regular piece at 1,1")
	end)

	it("2.1.5: the goal cannot ask for more chains than the level has", function()
		expect(H.level(FULL, chains(5)), "2.1.5 chains count exceeds the chains on the board")
		expect(H.level(FULL, { goals = { { type = "chains", count = 1 } } }), "2.1.5 chains count exceeds the chains on the board")
		assert_eq(errors_of(H.level(FULL, chains(4))), "")
	end)

	it("2.1.6: the chain is one of the (at most three) elements of a level", function()
		local l = chains(1)
		l.slots = { { at = { 1, 1 }, type = "record_box", hp = 1 }, { at = { 2, 1 }, type = "noise" } }
		assert_eq(errors_of(H.level(FULL, l)), "")
		l.slots[3] = { at = { 3, 1 }, type = "concrete", hp = 1 }
		expect(H.level(FULL, l), "2.1.6 more than three different elements")
	end)

	it("a level without chains has an all-zero chain layer", function()
		local lvl = H.load(FULL)
		for i = 1, 36 do assert_eq(lvl.chain[i], 0) end
	end)
end)

describe("core chain: the start board (4)", function()
	it("gives the starting pieces of the chained cells their chain, and pieces() reports it", function()
		for seed = 1, 8 do
			local g = H.game({ "######", "#r####", "######", "######", "######", "######" },
				chains(2, { { 1, 1, 2 }, { 4, 3, 1 } }), { seed = seed })
			local got = {}
			for _, p in ipairs(g:pieces()) do
				if p.chain then got[#got + 1] = { p.x, p.y, p.kind, p.chain } end
			end
			assert_same(got, { { 2, 2, "regular", 2 }, { 5, 4, "regular", 1 } })
			assert_eq(H.obj_at(g, 2, 2).color, C.COLOR.red)
			assert_false(M.any_match(M.color_map(g.s), 6, 6))
			local mv = g:moves()
			assert_true(#mv >= 3, "a start board has three moves")
			for _, m in ipairs(mv) do
				for _, c in ipairs({ m.from, m.to }) do
					assert_false((c[1] == 2 and c[2] == 2) or (c[1] == 5 and c[2] == 4), "no move takes a chained piece")
				end
			end
		end
	end)

	it("a pre-level booster never lands on a chained piece", function()
		local list = {}
		for y = 0, 5 do
			for x = 0, 5 do
				if not (x == 0 and y == 0) then list[#list + 1] = { x, y, 1 } end
			end
		end
		local lvl = core.load_level(H.level(FULL, chains(1, list)))
		if lvl then -- (only if such a start board is playable at all)
			local g = core.new(lvl, { seed = 1, boosters = { "riff" } })
			assert_eq(H.obj_at(g, 1, 1).kind, C.K_SPECIAL)
			assert_eq(count_chained(g), 35)
		end
	end)
end)

describe("core chain: the player cannot move it (5.1)", function()
	it("refuses a swap from it and a swap onto it with not_movable, and can_swap says reject", function()
		local g = fresh(PA, { { 3, 5 } })
		local h = g:hash()
		assert_same({ g:input({ type = "swap", from = { 3, 5 }, to = { 3, 6 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "swap", from = { 3, 6 }, to = { 3, 5 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "swap", from = { 3, 5 }, to = { 2, 5 } }) }, { false, "not_movable" })
		assert_eq(g:can_swap({ 3, 5 }, { 3, 6 }), "reject")
		assert_eq(g:can_swap({ 3, 6 }, { 3, 5 }), "reject")
		assert_eq(g:hash(), h, "a refused command changes nothing")
		assert_eq(g:status().moves_left, 20)
	end)

	it("a special swiped onto a chained piece is tapped, as onto a blocker", function()
		local g = fresh(with(P0, 3, 4, "R"), { { 3, 5 } })
		assert_same({ g:input({ type = "swap", from = { 3, 4 }, to = { 3, 5 } }) }, { true, "ok" })
		local ev = H.steps(g, 3)
		assert_eq(#H.of_type(ev, "activate"), 1)
		assert_eq(H.obj_at(g, 3, 5).chain, 1)
	end)

	it("moves() and has_move() leave it out, but count a move that matches it", function()
		local g = fresh(PA, { { 1, 6 } })
		assert_same(g:moves(), { { from = { 3, 5 }, to = { 3, 6 } } })
		assert_same(g:hint(), { from = { 3, 5 }, to = { 3, 6 } })
		-- the only move of the board needs the chained piece itself: no move at all
		local g2 = fresh(PA, { { 3, 5 } })
		assert_same(g2:moves(), {})
		assert_false(g2:has_move())
	end)

	it("the hint prefers the move that hits a chain while the goal is open", function()
		-- two moves of three: (3,5)->(3,6) purple with the chained (1,6), and (6,2)->(6,1)... built by hand below
		local rows = { "ppgoby", "yrpbyr", "rgbyrg", "gbyrgb", "byogby", "oogbyr" }
		local g = fresh(rows, { { 1, 6 } })
		assert_same(g:hint(), { from = { 3, 5 }, to = { 3, 6 } }, "the orange line holds the chain")
		local g2 = fresh(rows, { { 1, 6 } }, { goals = { { type = "collect", color = "red", count = 9 } } })
		assert_same(g2:hint(), { from = { 3, 1 }, to = { 3, 2 } }, "without the goal the first move of the list wins")
	end)
end)

describe("core chain: it falls like a free piece (10)", function()
	it("falls into the cell freed under it and keeps its chain; the pieces above follow", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gb_rgb", "byrgby", "yrgbyr" }, { { 3, 3, 2 } })
		local o, above = H.obj_at(g, 3, 3), H.obj_at(g, 3, 2)
		g:step()
		assert_eq(o.state, C.S_FALL)
		rest(g)
		assert_eq(o.cell, H.idx(g, 3, 4))
		assert_eq(o.chain, 2)
		assert_eq(above.cell, H.idx(g, 3, 3))
		assert_true(H.obj_at(g, 3, 1) ~= nil, "the spawner refilled the column: the chain blocks nothing")
	end)

	it("a column refills through a chained piece that sits in the spawner cell's column", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "b_rgby", "y_gbyr" }, { { 2, 1 }, { 2, 3 } })
		local a, b = H.obj_at(g, 2, 1), H.obj_at(g, 2, 3)
		rest(g)
		assert_same({ a.cell, b.cell }, { H.idx(g, 2, 3), H.idx(g, 2, 5) })
		for y = 1, 6 do assert_true(H.obj_at(g, 2, y) ~= nil, "row " .. y) end
	end)
end)

describe("core chain: a match takes the chain, not the piece (6, 7.1)", function()
	it("hp 1: the chain breaks, the piece stays free, the other pieces of the group are cleared", function()
		local g = fresh(PA, { { 1, 6 } })
		local o = H.obj_at(g, 1, 6)
		assert_same({ g:input(MOVE) }, { true, "ok" })
		local ev = H.steps(g, 11)
		assert_same(H.of_type(ev, "hit"), { { t = 11, type = "hit", x = 1, y = 6, layer = "chain", id = o.id, hp = 0 } })
		assert_same(H.of_type(ev, "unchained"), { { t = 11, type = "unchained", id = o.id, x = 1, y = 6 } })
		assert_eq(#H.of_type(ev, "clear"), 2)
		assert_same({ H.of_type(ev, "score")[1].delta, H.of_type(ev, "score")[2].delta }, { 50, 20 })
		assert_same(H.of_type(ev, "goal"), { { t = 11, type = "goal", index = 1, left = 3 } })
		assert_eq(g:status().score, 50 + 2 * 20)
		H.board(g, with(PA, 2, 6, "yg")) -- (the cascade of the refill is not this test's)
		o = H.obj_at(g, 1, 6)
		assert_same({ o.cell, o.chain, o.kind, o.color, o.state }, { 31, 0, C.K_REGULAR, C.COLOR.purple, C.S_IDLE })
		-- free now: the player may swap it
		assert_true(g:can_swap({ 1, 6 }, { 1, 5 }) ~= "reject")
	end)

	it("hp 2: the first match only takes a link (hit hp 1, no goal), the second breaks the chain", function()
		local g = fresh(PA, { { 1, 6, 2 } })
		local o = H.obj_at(g, 1, 6)
		g:input(MOVE)
		local ev = H.steps(g, 11)
		assert_same(H.of_type(ev, "hit"), { { t = 11, type = "hit", x = 1, y = 6, layer = "chain", id = o.id, hp = 1 } })
		assert_eq(#H.of_type(ev, "unchained"), 0)
		assert_eq(#H.of_type(ev, "goal"), 0)
		assert_eq(o.chain, 1)
		assert_eq(g.s.objs[o.id], o)
		assert_eq(g:status().score, 50 + 2 * 20)
		-- a second purple line through it, set by hand
		local s = g.s
		H.board(g, PA)
		H.obj_at(g, 1, 6).chain = 1
		g:input(MOVE)
		ev = H.steps(g, 11)
		assert_eq(#H.of_type(ev, "unchained"), 1)
		assert_eq(#H.of_type(ev, "goal"), 1)
		assert_same(g:status().goals, { 3 })
		assert_eq(H.obj_at(g, 1, 6).chain, 0)
		assert_eq(s.score, 2 * (50 + 40))
	end)

	it("the swap that makes such a match is kept (no swap back), and costs its move", function()
		local g = fresh(PA, { { 1, 6 }, { 2, 6 } })
		g:input(MOVE)
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "swap_back"), 0)
		assert_eq(g:status().moves_left, 19)
		assert_same(g:status().goals, { 2 })
	end)

	it("a chained cell is never the cell of the new special; with no other cell no special is made", function()
		-- four in a row: the Riff goes to the swapped cell, the chained piece stays
		local g = fresh(with(PA, 4, 6, "p"), { { 1, 6 } })
		local o = H.obj_at(g, 1, 6)
		g:input(MOVE)
		local ev = H.steps(g, 11)
		assert_same({ H.of_type(ev, "special_new")[1].x, H.of_type(ev, "special_new")[1].y }, { 3, 6 })
		assert_eq(g.s.objs[o.id], o)
		assert_eq(H.obj_at(g, 1, 6), o)
		-- five chained in a row, all of them: no Disco ball
		local g2 = fresh(with(P0, 1, 6, "ppppp"), { { 1, 6, 2 }, { 2, 6, 2 }, { 3, 6, 2 }, { 4, 6, 2 }, { 5, 6, 2 } },
			chains(5, { { 0, 0, 1 }, { 1, 0, 1 }, { 2, 0, 1 }, { 3, 0, 1 }, { 4, 0, 1 } }))
		g2.s.dirty = true
		g2.s.rest_flag = false
		ev = H.steps(g2, 1)
		assert_eq(#H.of_type(ev, "special_new"), 0)
		assert_eq(#H.of_type(ev, "hit"), 5)
	end)

	it("a line of chained pieces alone: one hit a search, then the freed pieces match as usual; it ends", function()
		local g = fresh(with(P0, 1, 6, "ppp"), { { 1, 6, 2 }, { 2, 6, 2 }, { 3, 6, 1 } })
		local a, b, c = H.obj_at(g, 1, 6), H.obj_at(g, 2, 6), H.obj_at(g, 3, 6)
		g.s.dirty = true
		g.s.rest_flag = false
		local ev = H.steps(g, 1)
		assert_same({ a.chain, b.chain, c.chain }, { 1, 1, 0 })
		assert_eq(#H.of_type(ev, "match"), 1)
		assert_eq(#H.of_type(ev, "clear"), 0, "nothing is cleared in the step that hit the chains")
		assert_true(g.s.dirty, "the survivors are searched again")
		ev = H.steps(g, 1)
		assert_same({ a.chain, b.chain, c.chain }, { 0, 0, 0 })
		assert_same(H.of_type(ev, "clear"), { { t = 2, type = "clear", id = c.id, x = 3, y = 6, kind = "regular", cause = "match", color = "purple" } })
		assert_same(H.of_type(ev, "match")[1].wave, 2, "each search is a new wave")
		ev = rest(g)
		assert_true(g:is_stable(), "the cascade ends")
		assert_same(g:status().goals, { 1 })
		assert_eq(g.s.objs[c.id], nil)
	end)

	it("the last chain of the goal wins the level", function()
		local g = fresh(PA, { { 1, 6 } }, chains(1))
		g:input(MOVE)
		H.steps(g, 11)
		assert_eq(g:status().state, "won_wait")
		for _ = 1, 3000 do
			if g:status().state == "complete" then break end
			g:step()
		end
		assert_true(g:result().won)
	end)
end)

describe("core chain: every effect passes over it (7, 8, 5.3)", function()
	-- "" if nothing touched the chained piece `o` before the first match (a cascade of the refill may match it
	-- by the rules, and that is not what these tests are about), else what did
	local function untouched(ev, o)
		for _, e in ipairs(ev) do
			if e.type == "match" then break end
			if e.id == o.id and (e.type == "clear" or e.type == "hit" or e.type == "unchained" or e.type == "transform") then
				return e.type
			end
		end
		return ""
	end

	it("a Riff, a Sabwoofer, a Bird and a Disco ball leave the chain and the piece alone", function()
		for _, sp in ipairs({ "R", "S", "B", "D" }) do
			local g = fresh(with(P0, 3, 4, sp), { { 2, 4 }, { 4, 4, 2 }, { 3, 3 } })
			local a, b, c = H.obj_at(g, 2, 4), H.obj_at(g, 4, 4), H.obj_at(g, 3, 3)
			assert_same({ g:input({ type = "tap", at = { 3, 4 } }) }, { true, "ok" })
			local ev = rest(g)
			assert_true(#H.of_type(ev, "activate") >= 1, sp)
			assert_true(#H.of_type(ev, "clear") >= 3, sp .. ": it fired")
			for _, o in ipairs({ a, b, c }) do assert_eq(untouched(ev, o), "", sp) end
		end
	end)

	it("a Disco ball does not choose or list chained pieces", function()
		-- the most frequent colour of the board is chained through and through: the ball takes another one
		local g = fresh(with(P0, 3, 4, "D"))
		local s = g.s
		local n, top = { 0, 0, 0, 0, 0, 0 }, 1
		for i = 1, s.N do
			local o = s.objs[s.slot[i]]
			if o.kind == C.K_REGULAR then n[o.color] = n[o.color] + 1 end
		end
		for c = 2, 6 do
			if n[c] > n[top] then top = c end
		end
		for i = 1, s.N do
			local o = s.objs[s.slot[i]]
			if o.kind == C.K_REGULAR and o.color == top then o.chain = 1 end
		end
		g:input({ type = "tap", at = { 3, 4 } })
		local ev = rest(g)
		local got = H.of_type(ev, "activate")[1].color
		assert_true(got ~= nil and got ~= C.COLOR_NAME[top], "the colour of the ball is not the chained one")
		for _, e in ipairs(ev) do
			if e.type == "match" then break end
			assert_true(e.type ~= "unchained" and not (e.type == "hit" and e.layer == "chain"))
		end
	end)

	it("the Grand finale clears the board around them and lights the tile under them, the chains stay", function()
		local extra = chains(4)
		extra.floor = { { at = { 1, 1 }, hp = 1 } }
		local g = fresh(with(with(P0, 3, 4, "D"), 4, 4, "D"), { { 2, 2 }, { 5, 5, 2 } }, extra)
		local a, b = H.obj_at(g, 2, 2), H.obj_at(g, 5, 5)
		assert_same({ g:input({ type = "swap", from = { 3, 4 }, to = { 4, 4 } }) }, { true, "ok" })
		local ev = rest(g, 600)
		assert_eq(untouched(ev, a), "")
		assert_eq(untouched(ev, b), "")
		assert_eq(#H.of_type(ev, "floor_lit"), 1, "all_layers reaches the floor under a chained piece")
	end)

	it("an adjacent match does nothing to it", function()
		-- the orange (2,6) is chained and stands beside the purple line of row 6 (3..5)
		local rows = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgpy", "yoppgr" }
		local g = fresh(rows, { { 2, 6 } })
		local o = H.obj_at(g, 2, 6)
		assert_same({ g:input({ type = "swap", from = { 5, 5 }, to = { 5, 6 } }) }, { true, "ok" })
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "match") >= 1, true)
		assert_eq(untouched(ev, o), "")
		assert_eq(o.chain, 1)
	end)

	it("boosters: the Stick refuses it, the lights pass over it, the Crossfader cannot take it", function()
		local g = fresh(P0, { { 2, 4 }, { 5, 4, 2 } })
		local a, b = H.obj_at(g, 2, 4), H.obj_at(g, 5, 4)
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 2, 4 } }) }, { false, "bad_cell" })
		assert_same({ g:input({ type = "booster", booster = "swap", at = { 2, 4 }, to = { 6, 6 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "booster", booster = "swap", at = { 6, 6 }, to = { 5, 4 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "booster", booster = "row_light", row = 4 }) }, { true, "ok" })
		local ev = rest(g)
		assert_true(#H.of_type(ev, "clear") >= 4)
		assert_eq(untouched(ev, a), "")
		assert_eq(untouched(ev, b), "")
		assert_same({ a.chain, b.chain, a.cell, b.cell }, { 1, 2, H.idx(g, 2, 4), H.idx(g, 5, 4) })
		assert_same({ g:input({ type = "booster", booster = "col_light", col = 2 }) }, { true, "ok" })
		ev = rest(g)
		assert_eq(untouched(ev, a), "")
		assert_eq(a.chain, 1)
		assert_eq(a.cell, H.idx(g, 2, 6), "the column under it was cleared: it fell to the bottom")
	end)

	it("a row of nothing but chained pieces has no effect for the lights either", function()
		local g = fresh(P0, { { 1, 6 }, { 2, 6 }, { 3, 6 }, { 4, 6 }, { 5, 6 }, { 6, 6 } })
		assert_same({ g:input({ type = "booster", booster = "row_light", row = 6 }) }, { false, "bad_cell" })
	end)

	it("the Bird never targets a chained piece, nor the tile under one", function()
		local extra = chains(4)
		extra.goals[2] = { type = "light" }
		extra.floor = { { at = { 1, 3 }, hp = 1 }, { at = { 4, 4 }, hp = 1 } }
		local g = fresh(P0, { { 2, 4 }, { 3, 2, 2 } }, extra)
		local lv = BD.levels(g.s)
		assert_eq(lv[H.idx(g, 2, 4)], 0, "a chained piece on a tile")
		assert_eq(lv[H.idx(g, 3, 2)], 0)
		assert_eq(lv[H.idx(g, 5, 5)], 4, "a free piece on a tile")
		assert_eq(lv[H.idx(g, 1, 1)], 1, "a free piece")
	end)

	it("noise does not creep onto it, the bonus gift and the continue Riff do not take it", function()
		local g = fresh(with(P0, 3, 4, "N"), { { 2, 4 }, { 4, 4 }, { 3, 3 }, { 3, 5 } })
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		require("core.flow").noise_growth(g.s)
		assert_eq(#H.of_type(g:drain_events(), "noise_spread"), 0)
		local all = fresh(P0)
		for i = 1, all.s.N do all.s.objs[all.s.slot[i]].chain = 1 end
		assert_same({ all:input({ type = "bonus", special = "riff" }) }, { false, "no_candidates" })
		assert_eq(#SH.candidates(all.s), 0)
	end)
end)

describe("core chain: shuffle, Remix and the dead board (12)", function()
	it("a shuffle keeps every chained piece in its cell with its colour and its chain", function()
		local locks = { { 1, 1 }, { 3, 3, 2 }, { 6, 6 }, { 2, 5 } }
		local g = fresh(P0, locks)
		local before = {}
		for k, l in ipairs(locks) do
			local o = H.obj_at(g, l[1], l[2])
			before[k] = { o.id, o.cell, o.color, o.chain }
		end
		assert_false(g:has_move())
		g.s.rest_flag = false
		local ev = rest(g)
		local sh = H.of_type(ev, "shuffle")
		assert_eq(#sh, 1, "a board without a move is shuffled")
		for k, l in ipairs(locks) do
			local o = H.obj_at(g, l[1], l[2])
			assert_same({ o.id, o.cell, o.color, o.chain }, before[k])
			for _, m in ipairs(sh[1].moves) do assert_true(m.id ~= o.id) end
			for _, r in ipairs(sh[1].recolors) do assert_true(r.id ~= o.id) end
		end
		assert_true(g:has_move())
	end)

	it("the Remix booster does the same", function()
		local g = fresh(PA, { { 1, 6, 2 }, { 4, 2 } })
		local a, b = H.obj_at(g, 1, 6), H.obj_at(g, 4, 2)
		assert_same({ g:input({ type = "booster", booster = "remix" }) }, { true, "ok" })
		rest(g)
		assert_same({ a.cell, a.color, a.chain }, { 31, C.COLOR.purple, 2 })
		assert_same({ b.cell, b.chain }, { H.idx(g, 4, 2), 1 })
	end)

	it("12.2.4a: with nothing left to shuffle a chained piece gives up its chain for a Riff, and the goal counts it", function()
		local g = fresh(P0)
		for i = 1, g.s.N do g.s.objs[g.s.slot[i]].chain = 1 end
		g.s.rest_flag = false
		local ev = H.steps(g, 1)
		local un = H.of_type(ev, "unchained")
		assert_eq(#un, 1)
		local sh = H.of_type(ev, "shuffle")[1]
		assert_same({ sh.riff.id, sh.riff.from }, { un[1].id, "chain" })
		local o = g.s.objs[un[1].id]
		assert_same({ o.kind, o.special, o.chain }, { C.K_SPECIAL, C.SP_RIFF, 0 })
		assert_same(g:status().goals, { 3 })
		assert_eq(#H.of_type(ev, "score"), 0)
		assert_eq(g:status().state, "playing")
		rest(g)
		assert_true(g:has_move(), "the Riff can be tapped")
	end)
end)

describe("core chain: hash and determinism (17)", function()
	it("the chain is part of the state hash", function()
		local g = fresh(PA, { { 1, 6, 1 } })
		local h1 = g:hash()
		H.obj_at(g, 1, 6).chain = 2
		local h2 = g:hash()
		H.obj_at(g, 1, 6).chain = 0
		assert_true(h1 ~= h2 and h1 ~= g:hash() and h2 ~= g:hash())
	end)

	local function level()
		return H.load({ "######", "######", "#r##g#", "######", "######", "######" }, {
			moves = 30,
			goals = { { type = "chains", count = 6 } },
			overlay = {
				{ at = { 1, 2 }, type = "chain", hp = 2 }, { at = { 4, 2 }, type = "chain", hp = 1 },
				{ at = { 0, 5 }, type = "chain", hp = 1 }, { at = { 5, 5 }, type = "chain", hp = 2 },
				{ at = { 2, 0 }, type = "chain", hp = 1 }, { at = { 3, 4 }, type = "chain", hp = 2 },
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

	it("the hint-following player breaks chains on the way (the element is playable)", function()
		local lvl = level()
		local broken = 0
		for seed = 1, 6 do
			local g = play(lvl, seed)
			broken = broken + (6 - g:status().goals[1])
		end
		assert_true(broken >= 12, "broke " .. broken .. " chains in 6 games")
	end)
end)
