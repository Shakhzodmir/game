-- Hits (section 7): layers, blockers, deduplication, scores and goals.

local C = require("core.const")
local HT = require("core.hits")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
local BASE = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }

local function fresh(rows, extra)
	local g = H.game(FULL, extra)
	H.board(g, rows or BASE)
	g.s.now = 5
	g.s.phase = 3
	return g
end

local function effect(g, mv, wv)
	return HT.new_source(g.s, C.SRC_EFFECT, mv or 4, wv or 1, 0)
end

local function types(ev)
	local out = {}
	for _, e in ipairs(ev) do out[#out + 1] = e.type end
	return out
end

describe("core hits: layers (7.1)", function()
	it("an effect destroys a regular piece and damages the floor: events in causal order", function()
		local g = fresh(nil, {
			floor = { { at = { 2, 2 }, hp = 1 } },
			goals = { { type = "collect", color = "blue", count = 5 }, { type = "light" } },
		})
		local s = g.s
		HT.hit(s, 15, effect(g, 4, 2)) -- (3,3) is blue
		local ev = g:drain_events()
		assert_same(types(ev), { "clear", "hit", "floor_lit", "score", "goal", "goal" })
		assert_same(ev[1], { t = 5, type = "clear", id = 15, x = 3, y = 3, kind = "regular", color = "blue", cause = "effect" })
		assert_same(ev[2], { t = 5, type = "hit", x = 3, y = 3, layer = "floor", hp = 0 })
		assert_same(ev[4], { t = 5, type = "score", delta = 80, total = 80, x = 3, y = 3 })
		assert_same(ev[5], { t = 5, type = "goal", index = 1, left = 4 })
		assert_same(ev[6], { t = 5, type = "goal", index = 2, left = 0 })
		local o = s.objs[15]
		assert_same({ o.state, o.tk, o.td }, { C.S_CLEAR, C.TM_CLEAR, 14 })
		assert_same({ s.vac_mv[15], s.vac_wv[15] }, { 4, 2 })
	end)

	it("an effect on an open slot damages the floor; a falling piece is not touched", function()
		local g = fresh(nil, { floor = { { at = { 2, 2 }, hp = 2 } } })
		local o = g.s.objs[15]
		o.state, o.offy = C.S_FALL, 1000
		HT.hit(g.s, 15, effect(g))
		assert_eq(o.state, C.S_FALL)
		assert_eq(g.s.floor[15], 1)
		assert_same(types(g:drain_events()), { "hit", "score" })
	end)

	it("match and adjacent hits do not touch the floor of an open slot", function()
		local g = fresh(nil, { floor = { { at = { 2, 2 }, hp = 2 } } })
		g.s.objs[15].state = C.S_FALL
		HT.hit(g.s, 15, HT.new_source(g.s, C.SRC_ADJ, 0, 1, 1))
		HT.hit(g.s, 15, HT.new_source(g.s, C.SRC_MATCH, 0, 1, 1))
		assert_eq(g.s.floor[15], 2)
	end)

	it("wires protect the piece and the floor; adjacent hits pass them by", function()
		local g = fresh(nil, { floor = { { at = { 2, 2 }, hp = 1 } } })
		local s = g.s
		s.wires[15] = 2
		HT.hit(s, 15, HT.new_source(s, C.SRC_ADJ, 0, 1, 5))
		assert_eq(s.wires[15], 2)
		assert_same(g:drain_events(), {})
		HT.hit(s, 15, effect(g, 2, 1))
		assert_eq(s.wires[15], 1)
		assert_same(types(g:drain_events()), { "hit", "score" })
		assert_false(s.dirty)
		HT.hit(s, 15, effect(g, 3, 4))
		assert_eq(s.wires[15], 0)
		local ev = g:drain_events()
		assert_same(types(ev), { "hit", "freed", "score" })
		assert_same(ev[2], { t = 5, type = "freed", id = 15, x = 3, y = 3 })
		assert_true(s.dirty, "freeing dirties the board outside a group")
		local o = s.objs[15]
		assert_same({ o.state, o.mv, o.wv }, { C.S_IDLE, 3, 4 }, "label raised by 1.3.7")
		assert_eq(s.floor[15], 1)
	end)

	it("deduplicates by (source, object key)", function()
		local g = fresh(nil, { floor = { { at = { 2, 2 }, hp = 2 } } })
		local src = effect(g)
		HT.hit(g.s, 15, src)
		g:drain_events()
		HT.hit(g.s, 15, src)
		assert_same(g:drain_events(), {})
		assert_eq(g.s.floor[15], 1)
		assert_same(src.keys, { 15 })
	end)

	it("a mic takes nothing and shields its floor", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgMyrg", "gbyrgb", "byrgby", "yrggbg" }, { floor = { { at = { 2, 2 }, hp = 2 } } })
		HT.hit(g.s, 15, effect(g))
		assert_eq(g.s.floor[15], 2)
		assert_eq(g.s.objs[15].state, C.S_IDLE)
		assert_same(g:drain_events(), {})
	end)
end)

describe("core hits: specials (7.2)", function()
	it("an effect launches an idle special after T.chain with its label; no floor damage", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgSyrg", "gbyrgb", "byrgby", "yrggbg" }, { floor = { { at = { 2, 2 }, hp = 2 } } })
		local s = g.s
		HT.hit(s, 15, effect(g, 6, 3))
		local sub = s.objs[15]
		assert_eq(sub.state, C.S_ARMED)
		assert_eq(s.floor[15], 2)
		assert_same({ s.queue[1].due, s.queue[1].kind, s.queue[1].d }, { 8, C.R_ACTIVATE, { 15, 15, 0, 6, 3, 0 } })
		-- a second effect finds an armed special: an open slot
		HT.hit(s, 15, effect(g))
		assert_eq(#s.queue, 1)
		assert_eq(s.floor[15], 1)
	end)

	it("the first hit of a source on its centre removes its own specials (step 0)", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgSyrg", "gbyrgb", "byrgby", "yrggbg" }, { floor = { { at = { 2, 2 }, hp = 2 } } })
		local s = g.s
		local sub = s.objs[15]
		sub.state = C.S_ARMED
		local src = effect(g, 7, 1)
		src.own, src.centre = { 15 }, 15
		HT.hit(s, 15, src)
		local ev = g:drain_events()
		assert_same(ev[1], { t = 5, type = "clear", id = 15, x = 3, y = 3, kind = "special", special = "sub", cause = "fired" })
		assert_same(types(ev), { "clear", "hit", "score" }, "then the open slot: floor -1 (50)")
		assert_eq(sub.state, C.S_CLEAR)
		assert_same(src.own, {})
		assert_same({ s.vac_mv[15], s.vac_wv[15] }, { 7, 1 })
		assert_eq(s.score, 50)
	end)
end)

describe("core hits: blockers (7.3)", function()
	it("record box loses 1 hp per adjacent or effect hit, then breaks", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgXyrg", "gbyrgb", "byrgby", "yrggbg" }, {
			goals = { { type = "break", item = "record_box", count = 1 } },
			slots = { { at = { 0, 0 }, type = "record_box", hp = 3 } },
		})
		local s = g.s
		local box = s.objs[15]
		box.hp = 3
		HT.hit(s, 15, HT.new_source(s, C.SRC_ADJ, 0, 1, 2))
		HT.hit(s, 15, effect(g))
		assert_eq(box.hp, 1)
		local ev = g:drain_events()
		assert_same(ev[1], { t = 5, type = "hit", x = 3, y = 3, layer = "blocker", item = "record_box", hp = 2 })
		HT.hit(s, 15, effect(g, 9, 2))
		ev = g:drain_events()
		assert_same(types(ev), { "destroy", "score", "goal", "state" })
		assert_same(ev[1], { t = 5, type = "destroy", id = 15, x = 3, y = 3, item = "record_box" })
		assert_same(ev[4], { t = 5, type = "state", state = "won_wait" })
		assert_eq(box.state, C.S_CLEAR)
		assert_same({ s.vac_mv[15], s.vac_wv[15] }, { 9, 2 })
		assert_eq(s.score, 150)
	end)

	it("concrete breaks from effects only; a balloon from adjacent hits of its colour", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgKArg", "gbyrgb", "byrgby", "yrggbg" })
		local s = g.s
		HT.hit(s, 15, HT.new_source(s, C.SRC_ADJ, 0, 1, 1))
		assert_eq(s.objs[15].hp, 1)
		HT.hit(s, 16, HT.new_source(s, C.SRC_ADJ, 0, 1, 5))
		assert_eq(s.objs[16].state, C.S_IDLE, "blue source, red balloon")
		HT.hit(s, 16, HT.new_source(s, C.SRC_ADJ, 0, 1, 1))
		assert_eq(s.objs[16].state, C.S_CLEAR)
		HT.hit(s, 15, effect(g))
		assert_eq(s.objs[15].state, C.S_CLEAR)
	end)

	it("a column takes one hit per source; broken, all 4 cells clear and each floor loses 1", function()
		local g = fresh({ "byrgby", "yLlbyr", "rllyrg", "gbyrgb", "byrgby", "yrggbg" }, {
			floor = { { at = { 1, 1 }, hp = 2 }, { at = { 2, 2 }, hp = 1 } },
		})
		local s = g.s
		local col = s.objs[8]
		col.hp = 1
		local src = effect(g, 3, 3)
		HT.hit(s, 15, src) -- bottom-right cell
		HT.hit(s, 8, src)  -- same object: skipped
		local ev = g:drain_events()
		assert_same(types(ev), { "destroy", "hit", "hit", "floor_lit", "score" })
		assert_same(ev[1], { t = 5, type = "destroy", id = 8, x = 2, y = 2, item = "column" })
		assert_same({ ev[2].x, ev[2].y, ev[2].hp, ev[3].x, ev[3].y, ev[3].hp }, { 2, 2, 1, 3, 3, 0 })
		assert_same(ev[5], { t = 5, type = "score", delta = 150, total = 150, x = 3, y = 3 })
		for _, i in ipairs({ 8, 9, 14, 15 }) do
			assert_same({ s.vac_mv[i], s.vac_wv[i] }, { 3, 3 })
		end
		assert_eq(col.state, C.S_CLEAR)
		s.tick = 5
		for _ = 1, 8 do g:step() end
		assert_eq(s.slot[8], col.id, "tick 13: still clearing")
		g:step()
		assert_true(s.slot[8] ~= col.id and s.slot[15] ~= col.id, "tick 14 = 5 + T.clear: gone")
		assert_eq(s.objs[col.id], nil)
	end)

	it("the all_layers source hits wires, slot and floor of every cell", function()
		local g = fresh(nil, { floor = { { at = { 2, 2 }, hp = 2 } } })
		local s = g.s
		s.wires[15] = 2
		local src = effect(g)
		src.all_layers = true
		HT.hit(s, 15, src)
		assert_eq(s.wires[15], 1)
		assert_eq(s.objs[15].state, C.S_IDLE, "wires still on: slot protected")
		assert_eq(s.floor[15], 1, "floor always")
		HT.hit(s, 15, src)
		assert_eq(s.wires[15], 0)
		assert_eq(s.objs[15].state, C.S_IDLE, "slot key already used by this source")
		assert_eq(s.floor[15], 0)
	end)
end)
