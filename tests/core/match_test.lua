-- Matches (section 6): groups, classification, special cell, resolution.

local C = require("core.const")
local M = require("core.match")
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
