-- Matches (section 6): groups, classification, special cell, resolution.

local C = require("core.const")
local M = require("core.match")
local HT = require("core.hits")
local sched = require("core.sched")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }

-- colour map from a picture: letters -> codes, anything else 0
local CODE = { r = 1, o = 2, y = 3, g = 4, b = 5, p = 6 }
local function cmap(rows)
	local col = {}
	for y = 1, #rows do
		for x = 1, #rows[1] do
			col[(y - 1) * #rows[1] + x] = CODE[string.sub(rows[y], x, x)] or 0
		end
	end
	return col, #rows[1], #rows
end

local function groups(rows)
	local col, W, H_ = cmap(rows)
	return M.find_groups(col, W, H_)
end

local function classify(rows)
	local gs = groups(rows)
	assert_eq(#gs, 1, "one group expected")
	local sp, ax = M.classify(gs[1])
	return sp, ax, gs[1]
end

local function fresh(rows, extra)
	local g = H.game(FULL, extra)
	H.board(g, rows)
	g.s.now = 1
	return g
end

describe("core match: groups and classification (6, 6.1)", function()
	it("classifies by the first matching row of 6.1", function()
		assert_eq(classify({ "rrr...", "......" }), 0)
		assert_same({ classify({ "rrrr..", "......" }) }, { C.SP_RIFF, C.AX_H, groups({ "rrrr..", "......" })[1] })
		local sp, ax = classify({ "r.....", "r.....", "r.....", "r....." })
		assert_same({ sp, ax }, { C.SP_RIFF, C.AX_V })
		assert_eq(classify({ "rrrrr.", "......" }), C.SP_DISCO)
		assert_eq(classify({ "rrrrrr", "......" }), C.SP_DISCO)
		assert_eq(classify({ "rrr...", ".r....", ".r...." }), C.SP_SUB, "T")
		assert_eq(classify({ "r.....", "r.....", "rrr..." }), C.SP_SUB, "L")
		assert_eq(classify({ "rr....", "rr....", "......" }), C.SP_BIRD)
		assert_eq(classify({ "rrr...", "rr....", "......" }), C.SP_BIRD, "square + line of 3")
		assert_eq(classify({ "rrrrr.", "r.....", "r....." }), C.SP_DISCO, "5 beats sub")
		assert_eq(classify({ "rrrr..", "rr....", "......" }), C.SP_RIFF, "4 beats bird")
	end)

	it("merges lines and squares with common cells; orders groups by smallest cell", function()
		local gs = groups({ "..ggg.", "rr....", "rr....", "..bbbb" })
		assert_eq(#gs, 3)
		assert_same(gs[1].cells, { 3, 4, 5 })
		assert_eq(gs[1].color, 4)
		assert_same(gs[2].cells, { 7, 8, 13, 14 })
		assert_same(gs[3].cells, { 21, 22, 23, 24 })
		local sq = groups({ "rrr...", "rrr...", "......" })
		assert_eq(#sq, 1)
		assert_eq(#sq[1].squares, 2)
		assert_eq(#sq[1].lines, 2)
	end)

	it("any_match and match_at agree with the group search", function()
		local col, W, H_ = cmap({ "rgrg..", "grgr..", "rrg...", "......" })
		assert_false(M.any_match(col, W, H_))
		col = cmap({ "rgrg..", "grgr..", "rrr...", "......" })
		assert_true(M.any_match(col, W, H_))
		assert_true(M.match_at(col, W, H_, 14))
		assert_false(M.match_at(col, W, H_, 1))
	end)
end)

describe("core match: cell of the new special (6.2)", function()
	it("rule 3: highest settle_tick, then lower, then left", function()
		local g = fresh({ "rrrrby", "yggbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local gs = M.find_groups(M.color_map(g.s), 6, 6)
		assert_eq(M.special_cell(g.s, gs[1], C.SP_RIFF, nil), 1, "all equal: leftmost of the row")
		H.obj_at(g, 3, 1).settle = 5
		assert_eq(M.special_cell(g.s, gs[1], C.SP_RIFF, nil), 3)
	end)

	it("rule 2: a sub goes where its lines cross; wired cells are no candidates", function()
		local g = fresh({ "rrrgby", "yrgbyr", "grbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local gs = M.find_groups(M.color_map(g.s), 6, 6)
		assert_eq(M.classify(gs[1]), C.SP_SUB)
		H.obj_at(g, 1, 1).settle = 9
		assert_eq(M.special_cell(g.s, gs[1], C.SP_SUB, nil), 2, "the crossing, not the newest")
		g.s.wires[2] = 1
		assert_eq(M.special_cell(g.s, gs[1], C.SP_SUB, nil), 1, "no unwired crossing: rule 3 among all")
		for _, i in ipairs(gs[1].cells) do g.s.wires[i] = 1 end
		assert_eq(M.special_cell(g.s, gs[1], C.SP_SUB, nil), 0)
	end)
end)

describe("core match: resolution (6.3)", function()
	it("takes label (M, W): M = max mv, W = 1 + max wv among mv == M", function()
		local g = fresh({ "rrrgby", "yggbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local a, b, c = H.obj_at(g, 1, 1), H.obj_at(g, 2, 1), H.obj_at(g, 3, 1)
		a.mv, a.wv = 2, 3
		b.mv, b.wv = 2, 5
		c.mv, c.wv = 1, 9
		M.search(g.s, nil)
		local ev = g:drain_events()
		assert_same({ ev[1].type, ev[1].act, ev[1].wave }, { "match", 2, 6 })
		assert_same(H.of_type(ev, "score")[1].delta, 120, "20 x W")
		assert_same({ g.s.vac_mv[1], g.s.vac_wv[1] }, { 2, 6 })
		assert_same(H.of_type(ev, "praise"), { { t = 1, type = "praise", act = 2, wave = 6, word = "hit" } })
		assert_eq(g.s.praise[2], 5)
	end)

	it("praises each action once per word, only the highest threshold", function()
		local g = fresh({ "rrrgby", "yggbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local s = g.s
		local function group_with_wave(w)
			H.board(g, { "rrrgby", "yggbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
			H.obj_at(g, 1, 1).mv, H.obj_at(g, 1, 1).wv = 4, w - 1
			M.search(s, nil)
			return H.of_type(g:drain_events(), "praise")
		end
		assert_same(group_with_wave(2), {})
		assert_eq(group_with_wave(8)[1].word, "drive")
		assert_same(group_with_wave(7), {}, "drive already said")
		assert_same(group_with_wave(5), {}, "lower than the best")
		assert_eq(group_with_wave(9)[1].word, "vibe")
		assert_eq(group_with_wave(15)[1].word, "legend")
		assert_same(group_with_wave(12), {})
	end)

	it("orders events: match, hits, special_new, bonus, adjacent hits, praise", function()
		local g = fresh({ "rrrrXy", "yggbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }, {
			goals = { { type = "break", item = "record_box", count = 1 }, { type = "collect", color = "red", count = 50 } },
			slots = { { at = { 4, 0 }, type = "record_box", hp = 1 } },
		})
		g.s.goal_left = { 1, 50 }
		local a = H.obj_at(g, 1, 1)
		a.mv, a.wv = 3, 2 -- W = 3: juicy
		M.search(g.s, nil)
		local types = {}
		for _, e in ipairs(g:drain_events()) do types[#types + 1] = e.type end
		assert_same(types, {
			"match",
			"clear", "score", "goal", -- (1,1): the special cell, destroyed without clear state
			"clear", "score", "goal",
			"clear", "score", "goal",
			"clear", "score", "goal",
			"special_new", "score",
			"destroy", "score", "goal", -- the record box beside (4,1); collect is still open
			"praise",
		})
	end)

	it("destroys the piece in the special cell at once and places the special", function()
		local g = fresh({ "rrrrby", "yggbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		M.search(g.s, nil)
		local sp = H.obj_at(g, 1, 1)
		assert_eq(sp.kind, C.K_SPECIAL)
		assert_same({ sp.special, sp.axis, sp.state, sp.settle }, { C.SP_RIFF, C.AX_H, C.S_IDLE, 1 })
		assert_eq(H.obj_at(g, 2, 1).state, C.S_CLEAR)
		assert_eq(g.s.score, 4 * 20 + 60)
	end)

	it("wired pieces in a group lose one layer and stay; the resolution does not dirty", function()
		local g = fresh({ "rrrgby", "yggbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g.s.wires[2] = 1
		g.s.wires[3] = 2
		local mid = H.obj_at(g, 2, 1)
		M.search(g.s, nil)
		assert_eq(mid.state, C.S_IDLE)
		assert_eq(g.s.wires[2], 0)
		assert_eq(g.s.wires[3], 1)
		assert_same({ mid.mv, mid.wv }, { 0, 1 }, "freed: label raised to the source's")
		assert_false(g.s.dirty)
		local ev = g:drain_events()
		assert_eq(#H.of_type(ev, "freed"), 1)
		assert_eq(#H.of_type(ev, "clear"), 1)
		assert_eq(g.s.score, 20 + 50 + 50)
	end)

	it("adjacent hits: boxes and noise break, concrete and wires do not, a column once", function()
		local g = fresh({ "rrrKNy", "XAEbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		M.search(g.s, nil)
		assert_eq(H.obj_at(g, 4, 1).hp, 1, "concrete: effect only")
		assert_eq(H.obj_at(g, 1, 2).state, C.S_CLEAR, "record box")
		assert_eq(H.obj_at(g, 2, 2).state, C.S_CLEAR, "red balloon, red group")
		assert_eq(H.obj_at(g, 3, 2).state, C.S_IDLE, "blue balloon")
		assert_eq(H.obj_at(g, 5, 1).state, C.S_IDLE, "noise not adjacent")
	end)

	it("a column beside two cells of a group takes one hit; wired neighbours take none", function()
		local g = fresh({ "Llgbyr", "llbyrg", "rrrgby", "yggbyr", "byrgby", "yrgbyr" })
		g.s.wires[20] = 1 -- (2,4) under the group
		M.search(g.s, nil)
		local col = H.obj_at(g, 1, 1)
		assert_eq(col.hp, 5)
		assert_eq(g.s.wires[20], 1)
		local hits = H.of_type(g:drain_events(), "hit")
		assert_same(hits, { { t = 1, type = "hit", x = 1, y = 1, layer = "blocker", item = "column", hp = 5 } })
	end)

	it("an adjacent hit on noise flags the action of its label", function()
		local g = fresh({ "rrrNgy", "yggbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g.s.eom = { { a = 3, noise_hit = false, merged = 0 } }
		H.obj_at(g, 1, 1).mv = 3
		M.search(g.s, nil)
		assert_true(g.s.eom[1].noise_hit)
		assert_eq(H.obj_at(g, 4, 1).state, C.S_CLEAR)
	end)
end)

-- Audit B1: statements of 6.2, 6.3 and 7.4 that the tests above leave open.
-- Match-free boards come from H.rows (colours r y g b); the group under test
-- is purple ("p") or orange ("o"), colours the filler never uses.
local function pic(letter, cells, more)
	local marks = {}
	for _, xy in ipairs(cells) do marks[xy] = letter end
	for k, v in pairs(more or {}) do marks[k] = v end
	return H.rows(6, 6, marks)
end

describe("core match: the new special by group shape (6.1, 6.3.3, 7.4)", function()
	-- name, group cells, special, axis, cell of the special, bonus
	local CASES = {
		{ "riff on a horizontal 4", { "1,1", "2,1", "3,1", "4,1" }, "riff", "h", 1, 1, 60 },
		{ "riff on a vertical 4", { "2,1", "2,2", "2,3", "2,4" }, "riff", "v", 2, 4, 60 },
		{ "bird on a square", { "3,3", "4,3", "3,4", "4,4" }, "bird", nil, 3, 4, 60 },
		{ "sub on a T (the crossing, rule 2)", { "2,2", "3,2", "4,2", "3,3", "3,4" }, "sub", nil, 3, 2, 90 },
		{ "disco on a 5", { "1,1", "2,1", "3,1", "4,1", "5,1" }, "disco", nil, 1, 1, 150 },
	}
	for _, c in ipairs(CASES) do
		it(c[1] .. ": special_new, then the bonus score; label (M, W), settle_tick and a fresh id", function()
			local g = fresh(pic("p", c[2]))
			local id0 = g.s.next_piece_id
			M.search(g.s, nil)
			local ev = g:drain_events()
			assert_same(H.of_type(ev, "special_new"),
				{ { t = 1, type = "special_new", id = id0, x = c[5], y = c[6], special = c[3], axis = c[4] } })
			local at
			for k, e in ipairs(ev) do
				if e.type == "special_new" then at = k end
			end
			local n = #c[2]
			assert_same(ev[at + 1], { t = 1, type = "score", delta = c[7], total = 20 * n + c[7], x = c[5], y = c[6] })
			assert_eq(g.s.next_piece_id, id0 + 1)
			local sp = H.obj_at(g, c[5], c[6])
			assert_same({ sp.id, sp.kind, sp.state, sp.mv, sp.wv, sp.settle }, { id0, C.K_SPECIAL, C.S_IDLE, 0, 1, 1 })
			assert_eq(H.of_type(ev, "match")[1].special, c[3])
			local cell = H.idx(g, c[5], c[6])
			assert_same({ g.s.vac_mv[cell], g.s.vac_wv[cell] }, { 0, 1 }, "the piece destroyed there left its mark (1.3.4) before the special came")
			local cleared = 0
			for _, e in ipairs(H.of_type(ev, "clear")) do
				if e.cause == "match" then cleared = cleared + 1 end
			end
			assert_eq(cleared, n, "every piece of the group is destroyed, the one in the special cell included")
		end)
	end

	it("a group that makes no special gives no special_new and no bonus", function()
		local g = fresh(pic("p", { "1,1", "2,1", "3,1" }))
		M.search(g.s, nil)
		local ev = g:drain_events()
		assert_same(H.of_type(ev, "special_new"), {})
		assert_eq(H.of_type(ev, "match")[1].special, nil)
		assert_eq(g.s.score, 60)
	end)

	it("a group without a candidate (every cell wired) makes neither special nor bonus (6.2)", function()
		-- not reachable in play (a new group always holds a piece that just moved); the rule is still pinned
		local g = fresh(pic("p", { "1,1", "2,1", "3,1", "4,1" }))
		for x = 1, 4 do g.s.wires[x] = 1 end
		local id0 = g.s.next_piece_id
		M.search(g.s, nil)
		local ev = g:drain_events()
		assert_same(H.of_type(ev, "special_new"), {})
		assert_eq(H.of_type(ev, "match")[1].special, nil, "the match event names no special")
		assert_eq(g.s.next_piece_id, id0)
		assert_eq(#H.of_type(ev, "freed"), 4)
		assert_eq(g.s.score, 4 * 50, "only the wire layers score")
		for x = 1, 4 do assert_eq(H.obj_at(g, x, 1).state, C.S_IDLE) end
	end)
end)

describe("core match: several groups and the adjacent source (6, 6.3.4)", function()
	it("groups are resolved by their smallest cell, each with its own pair of sources", function()
		-- purple (4..6,1) has the smaller first cell (4) than orange (1..3,3) (13) although it lies to the right
		local g = fresh(pic("o", { "1,3", "2,3", "3,3" }, { ["4,1"] = "p", ["5,1"] = "p", ["6,1"] = "p" }))
		local s = g.s
		local src0 = s.next_source_id
		H.obj_at(g, 1, 3).mv, H.obj_at(g, 1, 3).wv = 5, 2
		M.search(s, nil)
		local ev = g:drain_events()
		local m = H.of_type(ev, "match")
		assert_same({ m[1].color, m[1].act, m[1].wave, m[2].color, m[2].act, m[2].wave },
			{ "purple", 0, 1, "orange", 5, 3 }, "each group takes the label of its own pieces")
		assert_eq(s.next_source_id, src0 + 4, "match and adjacent per group")
		assert_same(s.sources, {}, "they live only during the resolution")
		-- the whole of the first group comes before the second match event
		local first_orange
		for k, e in ipairs(ev) do
			if e.type == "match" and e.color == "orange" then first_orange = k end
		end
		for k = 1, first_orange - 1 do
			if ev[k].type == "clear" then assert_eq(ev[k].y, 1) end
		end
	end)

	it("adjacent hits go by ascending cell; a neighbour of two group cells is hit once; voids are skipped", function()
		-- L of purple: (2,3) (3,3) (4,3) and (2,4) (2,5); (3,4) touches (3,3) and (2,4)
		local g = H.game({ "######", "######", "######", "######", "######", "######" }, {
			goals = { { type = "break", item = "record_box", count = 1 } },
			slots = { { at = { 0, 0 }, type = "record_box", hp = 3 } },
		})
		H.board(g, pic("p", { "2,3", "3,3", "4,3", "2,4", "2,5" }, { ["3,4"] = "X", ["5,3"] = "X", ["1,3"] = "X", ["3,2"] = "X" }))
		g.s.now = 1
		for _, xy in ipairs({ { 3, 4 }, { 5, 3 }, { 1, 3 }, { 3, 2 } }) do H.obj_at(g, xy[1], xy[2]).hp = 3 end
		M.search(g.s, nil)
		local hits = {}
		for _, e in ipairs(H.of_type(g:drain_events(), "hit")) do hits[#hits + 1] = { e.x, e.y, e.hp } end
		assert_same(hits, { { 3, 2, 2 }, { 1, 3, 2 }, { 5, 3, 2 }, { 3, 4, 2 } }, "ascending cell index, one hit each")
	end)

	it("the piece in the special cell takes the floor damage and counts for its goal", function()
		local g = fresh(pic("p", { "1,1", "2,1", "3,1", "4,1" }), {
			floor = { { at = { 0, 0 }, hp = 1 } },
			goals = { { type = "collect", color = "purple", count = 10 }, { type = "light" } },
		})
		M.search(g.s, nil)
		local ev = g:drain_events()
		local types = {}
		for k = 2, 8 do types[#types + 1] = ev[k].type end
		assert_same(types, { "clear", "hit", "floor_lit", "score", "goal", "goal", "clear" })
		assert_same(ev[2], { t = 1, type = "clear", id = 1, x = 1, y = 1, kind = "regular", color = "purple", cause = "match" })
		assert_same(ev[3], { t = 1, type = "hit", x = 1, y = 1, layer = "floor", hp = 0 })
		assert_same(ev[5], { t = 1, type = "score", delta = 70, total = 70, x = 1, y = 1 })
		assert_same({ ev[6].index, ev[6].left, ev[7].index, ev[7].left }, { 1, 9, 2, 0 })
		assert_eq(g.s.objs[1], nil, "removed at once: no clear state")
	end)
end)

describe("core match: when the search runs (6, 15 steps 2 and 7)", function()
	-- A latent match (placed by hand: the fixture leaves the board clean) and a queued effect hit due in the
	-- tick `due`. A search in step 2 resolves the group before the record of step 3 runs; one in step 7
	-- would come after it.
	local function setup(timer)
		local g = fresh(pic("p", { "1,1", "2,1", "3,1" }))
		local s = g.s
		local src = HT.new_source(s, C.SRC_EFFECT, 9, 1, 0)
		local due = 15
		s.now, s.phase = 0, 0
		sched.push(s, due, C.R_HIT, { src.id, H.idx(g, 6, 6) })
		if timer == "swap_fail" then
			local from, to
			-- a swap that does not make a match: two neighbours of the bottom rows
			for _, pair in ipairs({ { { 5, 5 }, { 6, 5 } }, { { 4, 5 }, { 5, 5 } }, { { 3, 5 }, { 4, 5 } }, { { 4, 6 }, { 5, 6 } } }) do
				if g:can_swap(pair[1], pair[2]) == "fail" then from, to = pair[1], pair[2] break end
			end
			assert_true(from ~= nil, "a failing pair")
			assert_same({ g:input({ type = "swap", from = from, to = to }) }, { true, "fail" })
		else
			local o = H.obj_at(g, 5, 5)
			o.state, o.tk, o.td = C.S_SWAP, C.TM_LOCK, due
		end
		return g
	end

	for _, timer in ipairs({ "swap_fail", "lock" }) do
		it("the end of a " .. timer .. " runs the full search in step 2, before the records of step 3", function()
			local g = setup(timer)
			for _ = 1, 14 do g:step() end
			assert_same(H.of_type(g:drain_events(), "match"), {}, "the latent match waits: no timer has expired and the board is clean")
			g:step() -- tick 15
			local order = {}
			for _, e in ipairs(g:drain_events()) do
				if e.type == "match" or (e.type == "clear" and e.cause == "effect") then order[#order + 1] = e.type end
			end
			assert_same(order, { "match", "clear" })
		end)
	end

	it("the search of step 7 runs when the board is dirty, and clears the flag", function()
		local g = fresh(pic("p", { "1,1", "2,1", "3,1" }))
		g.s.now = 0
		g.s.dirty = true
		g:step()
		assert_eq(#H.of_type(g:drain_events(), "match"), 1)
		assert_false(g.s.dirty)
		-- clean board: nothing is searched, the latent match stays unseen
		local g2 = fresh(pic("p", { "1,1", "2,1", "3,1" }))
		g2.s.now = 0
		g2:step()
		assert_eq(#H.of_type(g2:drain_events(), "match"), 0)
	end)
end)

describe("core match: groups that touch, and swaps that do not count (6, 6.2.1)", function()
	it("lines of one colour that share no cell are separate groups, even when they touch", function()
		-- (1..3,1) and (3..5,2): (3,1) and (3,2) touch, but a vertical pair is no line
		local g = fresh(pic("p", { "1,1", "2,1", "3,1", "3,2", "4,2", "5,2" }))
		M.search(g.s, nil)
		local m = H.of_type(g:drain_events(), "match")
		assert_eq(#m, 2)
		assert_same({ #m[1].cells, m[1].cells[1][2], #m[2].cells, m[2].cells[1][2] }, { 3, 1, 3, 2 })
	end)

	it("a swap_back that ends in the step does not take part in rule 6.2.1 (rule 3 decides)", function()
		-- a horizontal 4 of purple (1..4,1); the piece at (4,1) comes back from (4,2) this tick and the piece at (1,1)
		-- ends a shuffle lock this tick: both settle now, rule 3 takes the left one; rule 1 would take (4,1)
		local g = fresh(pic("p", { "1,1", "2,1", "3,1", "4,2" }))
		local s = g.s
		local I = require("core.input")
		s.now = 0
		local a, b = H.obj_at(g, 4, 1), H.obj_at(g, 4, 2) -- b is the purple piece
		I.start_swap(s, C.TM_BACK, 7, H.idx(g, 4, 1), H.idx(g, 4, 2), 5, a, b)
		local lock = H.obj_at(g, 1, 1)
		lock.state, lock.tk, lock.td = C.S_SWAP, C.TM_LOCK, 5
		for _ = 1, 5 do g:step() end
		local ev = g:drain_events()
		assert_same(H.of_type(ev, "special_new"), { { t = 5, type = "special_new", id = s.next_piece_id - 1, x = 1, y = 1, special = "riff", axis = "h" } })
		assert_eq(#H.of_type(ev, "match"), 1)
	end)
end)
