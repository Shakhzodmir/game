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

-- Audit B1: statements of 1.2, 7.1-7.4 that the tests above leave open.
local B = require("core.board")

describe("core hits: pins, sources and keys (1.2, 1.4, 7.1)", function()
	it("new_source hands out ids in order with an empty state", function()
		local g = fresh()
		local a = HT.new_source(g.s, C.SRC_EFFECT, 3, 2, 0)
		local b = HT.new_source(g.s, C.SRC_MATCH, 1, 1, 4)
		assert_same({ a.id, b.id, g.s.next_source_id }, { 1, 2, 3 })
		assert_same({ a.kind, a.mv, a.wv, a.color, a.all_layers, a.own, a.centre, a.keys, a.reserves, a.nrec },
			{ C.SRC_EFFECT, 3, 2, 0, false, {}, 0, {}, {}, 0 })
		assert_eq(g.s.sources[a.id], a)
	end)

	it("a hit removes the pin of its own source only, even when the hit is a duplicate", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
		local s = g.s
		s.wires[15] = 2
		local a, b = effect(g), effect(g)
		local o = s.objs[15]
		B.pin(o, a.id)
		B.pin(o, b.id)
		HT.hit(s, 15, a) -- wires 2 -> 1, the piece stays idle
		assert_same(o.pins, { b.id })
		B.pin(o, a.id)
		HT.hit(s, 15, a) -- same key: skipped as a hit, but the mark goes
		assert_same(o.pins, { b.id })
		assert_eq(s.wires[15], 1, "no second wire layer")
	end)

	it("a destroyed or launched piece loses every mark", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgSyrg", "gbyrgb", "byrgby", "yrggbg" })
		local s = g.s
		local a, b = effect(g), effect(g)
		for _, id in ipairs({ 14, 15 }) do
			B.pin(s.objs[id], a.id)
			B.pin(s.objs[id], b.id)
		end
		HT.hit(s, 14, effect(g)) -- a piece: destroyed
		assert_same(s.objs[14].pins, {})
		HT.hit(s, 15, effect(g)) -- the Sabwoofer: launched, armed
		assert_eq(s.objs[15].state, C.S_ARMED)
		assert_same(s.objs[15].pins, {})
	end)

	it("a pinned piece is hit like any other (1.2.4)", function()
		local g = fresh()
		local a = effect(g)
		B.pin(g.s.objs[15], 99)
		HT.hit(g.s, 15, a)
		assert_eq(g.s.objs[15].state, C.S_CLEAR)
	end)

	it("a match source leaves blockers, specials and mics alone", function()
		local g = fresh({ "byrgby", "yrgbyr", "rXSMrg", "gbyrgb", "byrgby", "yrggbg" })
		local s = g.s
		local src = HT.new_source(s, C.SRC_MATCH, 1, 1, 1)
		for i = 14, 16 do HT.hit(s, i, src) end
		assert_same(g:drain_events(), {})
		assert_eq(s.objs[14].hp, 1)
		assert_eq(s.objs[15].state, C.S_IDLE)
		assert_eq(#s.queue, 0)
	end)

	it("every open state is an open slot for an effect: the floor takes the hit, the object none", function()
		for _, st in ipairs({ C.S_FALL, C.S_SWAP, C.S_CLEAR, C.S_ARMED }) do
			local g = fresh(nil, { floor = { { at = { 2, 2 }, hp = 2 } } })
			local o = g.s.objs[15]
			o.state = st
			HT.hit(g.s, 15, effect(g))
			assert_eq(o.state, st, "state " .. st)
			assert_eq(g.s.floor[15], 1, "state " .. st)
			assert_eq(g.s.score, 50)
		end
	end)
end)

describe("core hits: removal of the own specials of a combo (7.1.0, 7.2.4)", function()
	it("the first hit on the centre removes both specials, the one in `to` first, with the label of the combo", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgSRrg", "gbyrgb", "byrgby", "yrggbg" }, { floor = { { at = { 3, 2 }, hp = 1 } } })
		local s = g.s
		local to, from = s.objs[15], s.objs[16]
		to.state, from.state = C.S_ARMED, C.S_ARMED
		local src = effect(g, 8, 1)
		src.own, src.centre = { to.id, from.id }, 15
		HT.hit(s, 15, src)
		local ev = g:drain_events()
		assert_same({ ev[1].type, ev[1].id, ev[1].cause, ev[2].type, ev[2].id, ev[2].cause }, { "clear", 15, "fired", "clear", 16, "fired" })
		assert_same({ to.state, from.state }, { C.S_CLEAR, C.S_CLEAR })
		assert_same({ s.vac_mv[15], s.vac_wv[15], s.vac_mv[16], s.vac_wv[16] }, { 8, 1, 8, 1 })
		assert_same(src.own, {})
		assert_eq(s.floor[15], 0, "the centre is an open slot now: the floor takes the hit")
		-- `from` is hit when the geometry reaches it: an open slot, no second removal
		HT.hit(s, 16, src)
		assert_same(H.of_type(g:drain_events(), "clear"), {})
	end)

	it("a fired special gives no score, no goal and no floor damage of its own", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgRyrg", "gbyrgb", "byrgby", "yrggbg" })
		local s = g.s
		s.objs[15].state = C.S_ARMED
		local src = effect(g)
		src.own, src.centre = { 15 }, 15
		HT.hit(s, 15, src)
		assert_eq(s.score, 0)
		assert_same(H.of_type(g:drain_events(), "score"), {})
	end)

	it("a hit on the centre by another source removes nothing", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgRyrg", "gbyrgb", "byrgby", "yrggbg" })
		local s = g.s
		s.objs[15].state = C.S_ARMED
		local owner, other = effect(g), effect(g)
		owner.own, owner.centre = { 15 }, 15
		HT.hit(s, 15, other)
		assert_eq(s.objs[15].state, C.S_ARMED)
		assert_same(owner.own, { 15 })
	end)
end)

describe("core hits: the all_layers source (7.1, 8.5 Grand finale)", function()
	it("a wired piece with one layer is freed and destroyed by the same hit; with two layers the slot is spared", function()
		local g = fresh(nil, { floor = { { at = { 2, 2 }, hp = 1 } } })
		local s = g.s
		s.wires[15] = 1
		local src = effect(g, 6, 2)
		src.all_layers = true
		HT.hit(s, 15, src)
		local ev = g:drain_events()
		assert_same(types(ev), { "hit", "freed", "clear", "hit", "floor_lit", "score" })
		assert_same({ s.wires[15], s.objs[15].state, s.floor[15], s.score }, { 0, C.S_CLEAR, 0, 50 + 30 + 50 })
		assert_same({ s.objs[15].mv, s.objs[15].wv }, { 6, 2 }, "the freed piece takes the label of the source")
		s.wires[16] = 2
		HT.hit(s, 16, src)
		assert_eq(s.objs[16].state, C.S_IDLE)
		assert_eq(s.wires[16], 1)
	end)

	it("a column takes its slot hit once and each of its cells its own floor hit", function()
		local g = fresh({ "byrgby", "yLlbyr", "rllyrg", "gbyrgb", "byrgby", "yrggbg" }, {
			floor = { { at = { 1, 1 }, hp = 1 }, { at = { 2, 1 }, hp = 2 }, { at = { 1, 2 }, hp = 1 }, { at = { 2, 2 }, hp = 1 } },
		})
		local s = g.s
		local col = s.objs[8]
		col.hp = 3
		local src = effect(g, 2, 1)
		src.all_layers = true
		for _, i in ipairs({ 8, 9, 14, 15 }) do HT.hit(s, i, src) end
		assert_eq(col.hp, 2, "one slot hit for the source")
		assert_same({ s.floor[8], s.floor[9], s.floor[14], s.floor[15] }, { 0, 1, 0, 0 })
		assert_eq(s.score, 50 + 4 * 50)
		local hits = {}
		for _, e in ipairs(H.of_type(g:drain_events(), "hit")) do hits[#hits + 1] = e.layer .. ":" .. e.x .. "," .. e.y end
		assert_same(hits, { "blocker:2,2", "floor:2,2", "floor:3,2", "floor:2,3", "floor:3,3" })
	end)
end)

describe("core hits: columns, noise and goals (7.3, 7.4)", function()
	it("a destroyed column damages the four floors by ascending cell and skips the lit ones", function()
		local g = fresh({ "byrgby", "yLlbyr", "rllyrg", "gbyrgb", "byrgby", "yrggbg" }, {
			floor = { { at = { 1, 1 }, hp = 2 }, { at = { 2, 1 }, hp = 1 }, { at = { 2, 2 }, hp = 1 } },
			slots = { { at = { 1, 1 }, type = "column", hp = 6 } },
			goals = { { type = "light" }, { type = "break", item = "column", count = 1 } },
		})
		local s = g.s
		s.objs[8].hp = 1
		HT.hit(s, 14, effect(g, 3, 1))
		local ev = g:drain_events()
		assert_same(types(ev), { "destroy", "hit", "hit", "floor_lit", "hit", "floor_lit", "score", "goal", "goal" })
		assert_same({ ev[2].x, ev[2].y, ev[2].hp, ev[3].x, ev[3].y, ev[3].hp, ev[5].x, ev[5].y }, { 2, 2, 1, 3, 2, 0, 3, 3 })
		assert_same({ s.floor[8], s.floor[9], s.floor[14], s.floor[15] }, { 1, 0, 0, 0 })
		assert_same({ s.goal_left[1], s.goal_left[2] }, { 1, 0 })
		assert_eq(s.score, 50 + 3 * 50, "the last hp of the column and three floor hp; a lit tile gives nothing")
		assert_same(ev[7], { t = 5, type = "score", delta = 200, total = 200, x = 2, y = 3 }, "at the cell of the hit")
		assert_same(ev[8], { t = 5, type = "goal", index = 1, left = 1 }, "two tiles lit by one hit: one event with the final left")
	end)

	it("only a hit that removes hp from an intact noise marks the action of its label", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgNyrg", "gbyrgb", "byrgby", "yrggbg" })
		local s = g.s
		s.eom = { { a = 4, noise_hit = false, merged = 0 } }
		s.objs[15].state = C.S_CLEAR -- already destroyed: an open slot
		HT.hit(s, 15, effect(g, 4, 1))
		assert_false(s.eom[1].noise_hit)
		s.objs[15].state = C.S_IDLE
		HT.hit(s, 15, effect(g, 7, 1)) -- no queue entry for action 7: nowhere to write
		assert_false(s.eom[1].noise_hit)
		g = fresh({ "byrgby", "yrgbyr", "rgNyrg", "gbyrgb", "byrgby", "yrggbg" })
		g.s.eom = { { a = 4, noise_hit = false, merged = 0 } }
		HT.hit(g.s, 15, effect(g, 4, 1))
		assert_true(g.s.eom[1].noise_hit)
	end)

	it("a goal never goes below 0 and says nothing once it is 0; won_wait follows the last goal once", function()
		local g = fresh(nil, { goals = { { type = "collect", color = "blue", count = 1 } } })
		local s = g.s
		HT.hit(s, 15, effect(g)) -- (3,3) is blue
		local ev = g:drain_events()
		assert_same(types(ev), { "clear", "score", "goal", "state" })
		HT.hit(s, 16, effect(g, 4, 1)) -- (4,3) is yellow: nothing counts
		HT.hit(s, 3, effect(g, 4, 1)) -- (3,1) is yellow
		HT.hit(s, 5, effect(g, 4, 1)) -- (5,1) is blue: the goal is 0 already
		ev = g:drain_events()
		assert_same(H.of_type(ev, "goal"), {})
		assert_same(H.of_type(ev, "state"), {})
		assert_eq(s.goal_left[1], 0)
	end)

	it("floor with hp 2: the first hit says hp 1 and no floor_lit, the second lights it", function()
		local g = fresh(nil, { floor = { { at = { 2, 2 }, hp = 2 } }, goals = { { type = "light" } } })
		local s = g.s
		HT.hit(s, 15, effect(g, 1, 1))
		assert_same(types(g:drain_events()), { "clear", "hit", "score" })
		HT.hit(s, 15, effect(g, 2, 1)) -- the slot is open now (the piece is in clear)
		assert_same(types(g:drain_events()), { "hit", "floor_lit", "score", "goal", "state" })
	end)
end)

describe("core hits: labels of freed pieces (1.3.7, 1.3.10)", function()
	it("freeing the last wire layer raises the label to the source's and records the merge of the two actions", function()
		local g = fresh()
		local s = g.s
		s.wires[15] = 1
		s.objs[15].mv, s.objs[15].wv = 3, 2
		s.eom = { { a = 3, noise_hit = false, merged = 0 }, { a = 5, noise_hit = false, merged = 0 } }
		HT.hit(s, 15, effect(g, 5, 1))
		assert_same({ s.objs[15].mv, s.objs[15].wv }, { 5, 1 })
		assert_same({ s.eom[1].merged, s.eom[2].merged }, { 5, 0 })
	end)

	it("a source of an older action never lowers the label; no queue entry, no merge", function()
		local g = fresh()
		local s = g.s
		s.wires[15] = 1
		s.objs[15].mv, s.objs[15].wv = 7, 1
		s.eom = { { a = 3, noise_hit = false, merged = 0 } }
		HT.hit(s, 15, effect(g, 5, 9))
		assert_same({ s.objs[15].mv, s.objs[15].wv }, { 7, 1 })
		s.wires[16] = 1
		s.objs[16].mv, s.objs[16].wv = 3, 0
		HT.hit(s, 16, effect(g, 6, 1)) -- action 6 is not in the queue
		assert_same({ s.objs[16].mv, s.objs[16].wv }, { 6, 1 })
		assert_eq(s.eom[1].merged, 0)
	end)

	it("a wire layer that stays leaves the label alone", function()
		local g = fresh()
		local s = g.s
		s.wires[15] = 2
		HT.hit(s, 15, effect(g, 5, 1))
		assert_same({ s.objs[15].mv, s.objs[15].wv }, { 0, 0 })
	end)
end)

describe("core hits: a blocker that survives leaves its tile alone (7.1.4)", function()
	local ROWS = { "byrgby", "yrgbyr", "rXKAEN", "gbyrgb", "byrgby", "yrggbg" }
	-- (2,3) record box hp 3, (3,3) concrete, (4,3) red balloon, (5,3) blue balloon, (6,3) noise
	local function board()
		local g = fresh(ROWS, {
			floor = { { at = { 1, 2 }, hp = 2 }, { at = { 2, 2 }, hp = 2 }, { at = { 3, 2 }, hp = 2 }, { at = { 4, 2 }, hp = 2 } },
		})
		g.s.objs[14].hp = 3
		return g
	end

	it("damage that does not destroy: no floor hit", function()
		local g = board()
		HT.hit(g.s, 14, effect(g)) -- the box keeps 2 hp
		assert_same({ g.s.objs[14].hp, g.s.floor[14] }, { 2, 2 })
	end)

	it("a source that cannot break the blocker: no floor hit", function()
		local g = board()
		local s = g.s
		HT.hit(s, 15, HT.new_source(s, C.SRC_ADJ, 0, 1, 1)) -- concrete, adjacent
		HT.hit(s, 17, HT.new_source(s, C.SRC_ADJ, 0, 1, 1)) -- blue balloon, red group
		assert_same({ s.objs[15].hp, s.objs[17].state, s.floor[15], s.floor[17] }, { 1, C.S_IDLE, 2, 2 })
		assert_same(g:drain_events(), {})
	end)

	it("destroyed: the tile takes the hit of the same source (control)", function()
		local g = board()
		local s = g.s
		HT.hit(s, 16, HT.new_source(s, C.SRC_ADJ, 0, 1, 1)) -- red balloon, red group
		assert_same({ s.objs[16].state, s.floor[16] }, { C.S_CLEAR, 1 })
		assert_eq(s.score, 100, "one hp of the balloon and one of the tile")
	end)
end)
