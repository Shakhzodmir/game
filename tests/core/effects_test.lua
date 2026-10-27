-- The effect framework (7.2.6, 7.2.7): action lists, stable order, first
-- occurrence per object, actions at t0 inside the activation record, one
-- queued record per later action, path pins. Audit B1.

local C = require("core.const")
local B = require("core.board")
local HT = require("core.hits")
local EF = require("core.effects")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
local BASE = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }

local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or BASE)
	g.s.now = 5
	g.s.phase = 3
	return g
end

local function source(g, mv, wv)
	return HT.new_source(g.s, C.SRC_EFFECT, mv or 4, wv or 1, 0)
end

local function hit(src, tick, cell)
	return { tick, C.R_HIT, { src.id, cell } }
end

-- queue summary: {due, cell} of the hit records
local function queued(g)
	local out = {}
	for _, r in ipairs(g.s.queue) do out[#out + 1] = { r.due, r.d[2] } end
	return out
end

describe("core effects: the action list (7.2.6)", function()
	it("sorts by tick, keeping the natural order of equal ticks", function()
		local g = fresh()
		local src = source(g)
		EF.run(g.s, src, { hit(src, 9, 20), hit(src, 7, 14), hit(src, 7, 3), hit(src, 8, 21), hit(src, 7, 9) }, false)
		assert_same(queued(g), { { 7, 14 }, { 7, 3 }, { 7, 9 }, { 8, 21 }, { 9, 20 } })
	end)

	it("queues one record per later action with consecutive seq; nrec counts them", function()
		local g = fresh()
		local src = source(g)
		g.s.seq = 40
		EF.run(g.s, src, { hit(src, 7, 14), hit(src, 8, 3), hit(src, 9, 9) }, false)
		local seqs = {}
		for _, r in ipairs(g.s.queue) do seqs[#seqs + 1] = r.seq end
		assert_same(seqs, { 41, 42, 43 })
		assert_eq(g.s.seq, 43)
		assert_eq(src.nrec, 3)
	end)

	it("runs the actions of tick t0 at once, in order, and queues nothing for them", function()
		local g = fresh()
		local src = source(g)
		EF.run(g.s, src, { hit(src, 6, 14), hit(src, 5, 21), hit(src, 5, 3), hit(src, 5, 15) }, false)
		local order = {}
		for _, e in ipairs(H.of_type(g:drain_events(), "clear")) do order[#order + 1] = e.id end
		assert_same(order, { 21, 3, 15 }, "list order among equal ticks")
		assert_same(queued(g), { { 6, 14 } })
		assert_eq(src.nrec, 1)
	end)

	it("the actions of tick t0 run before the later ones are queued: a chain they launch comes first at equal due", function()
		local g = fresh({ "byrgby", "yrgbyr", "rSbyrg", "gbyrgb", "byrgby", "yrggbg" })
		local src = source(g)
		EF.run(g.s, src, { hit(src, 5, 14), hit(src, 8, 3) }, false)
		local q = H.queue(g)
		assert_same({ q[1][1], q[1][2], q[2][1], q[2][2] }, { 8, C.R_ACTIVATE, 8, C.R_HIT })
		assert_true(g.s.queue[1].seq < g.s.queue[2].seq)
	end)

	it("keeps the first occurrence per object after sorting", function()
		local g = fresh()
		local src = source(g)
		EF.run(g.s, src, { hit(src, 9, 14), hit(src, 7, 14), hit(src, 8, 14), hit(src, 8, 3) }, false)
		assert_same(queued(g), { { 7, 14 }, { 8, 3 } })
	end)

	it("an object is a column as a whole: its second cell is dropped, unless the source hits all layers", function()
		local rows = { "byrgby", "yLlbyr", "rllyrg", "gbyrgb", "byrgby", "yrggbg" }
		local g = fresh(rows)
		local src = source(g)
		EF.run(g.s, src, { hit(src, 7, 15), hit(src, 8, 8), hit(src, 9, 9) }, false)
		assert_same(queued(g), { { 7, 15 } }, "the earliest cell of the column wins")
		local g2 = fresh(rows)
		local src2 = source(g2)
		src2.all_layers = true
		EF.run(g2.s, src2, { hit(src2, 7, 15), hit(src2, 8, 8), hit(src2, 9, 9), hit(src2, 9, 15) }, false)
		assert_same(queued(g2), { { 7, 15 }, { 8, 8 }, { 9, 9 } }, "all_layers: one cell is one object")
	end)

	it("keeps every action that is not a hit", function()
		local g = fresh()
		local src = source(g)
		local p = g.s.objs[14]
		EF.run(g.s, src, {
			{ 7, C.R_DISCO, { src.id, 0, p.id } }, { 7, C.R_DISCO, { src.id, 1, p.id } }, hit(src, 8, 14),
		}, false)
		assert_same(H.queue(g), { { 7, C.R_DISCO, src.id, 0, p.id }, { 7, C.R_DISCO, src.id, 1, p.id }, { 8, C.R_HIT, src.id, 14 } })
	end)

	it("in turbo every action is due at once and the queue stays empty", function()
		local g = fresh(nil, nil, { timing = "turbo" })
		local src = source(g)
		EF.run(g.s, src, { hit(src, EF.at(g.s, 5, 9), 14), hit(src, EF.at(g.s, 5, 3), 3) }, true)
		assert_same(g.s.queue, {})
		assert_eq(#H.of_type(g:drain_events(), "clear"), 2)
		assert_eq(EF.at(g.s, 5, 9), 5)
		assert_eq(EF.at(fresh().s, 5, 9), 14, "normal timing: t0 plus the offset")
	end)

	it("the record handlers are installed for the kinds 1 to 5", function()
		for k = C.R_ACTIVATE, C.R_BIRD do assert_eq(type(EF.handlers[k]), "function", "kind " .. k) end
		assert_eq(EF.handlers[C.R_HIT], EF.handlers[2])
	end)

	it("the hit record hits the cell with its source", function()
		local g = fresh()
		local src = source(g)
		EF.handlers[C.R_HIT](g.s, { src.id, 14 })
		assert_eq(g.s.objs[14].state, C.S_CLEAR)
		assert_same(src.keys, { 14 })
	end)
end)

describe("core effects: path pins (7.2.7)", function()
	it("pins the idle movable pieces of the cells hit later than t0, and only those", function()
		local g = fresh({ "byrgby", "yrgbyr", "rMSyrg", "gbyrgb", "byrgby", "yrggbg" })
		local s = g.s
		s.wires[16] = 1 -- (4,3) wired: not movable
		s.objs[17].state = C.S_FALL -- (5,3) falling
		s.objs[17].offy = 900
		local src = source(g)
		EF.run(s, src, { hit(src, 5, 13), hit(src, 6, 14), hit(src, 7, 15), hit(src, 8, 16), hit(src, 9, 17), hit(src, 10, 18) }, true)
		assert_same(s.objs[13].pins, {}, "hit at t0: no pin")
		assert_same(s.objs[14].pins, { src.id }, "a mic is movable")
		assert_same(s.objs[15].pins, { src.id }, "a special too")
		assert_same(s.objs[16].pins, {}, "wires")
		assert_same(s.objs[17].pins, {}, "not idle")
		assert_same(s.objs[18].pins, { src.id })
		assert_same(s.objs[19].pins, {}, "no hit there")
	end)

	it("pin_path false pins nothing; marks of other sources are kept and joined", function()
		local g = fresh()
		local s = g.s
		local a, b = source(g), source(g)
		B.pin(s.objs[14], a.id)
		EF.run(s, b, { hit(b, 7, 14), hit(b, 8, 15) }, false)
		assert_same(s.objs[14].pins, { a.id })
		assert_same(s.objs[15].pins, {})
		EF.run(s, b, { hit(b, 9, 16) }, true)
		B.pin(s.objs[14], b.id)
		assert_same(s.objs[14].pins, { a.id, b.id })
	end)

	it("a later hit removes the mark and the source dies with its last record", function()
		local g = fresh()
		local s = g.s
		local src = source(g)
		EF.run(s, src, { hit(src, 6, 14), hit(src, 7, 15) }, true)
		assert_same(s.objs[15].pins, { src.id })
		s.tick = 5
		g:step() -- tick 6: the first record
		assert_eq(s.sources[src.id], src)
		assert_same(s.objs[15].pins, { src.id }, "the mark stays until its own hit")
		g:step() -- tick 7
		assert_eq(s.sources[src.id], nil)
		assert_true(s.objs[15] == nil or s.objs[15].pins[1] == nil)
	end)

	it("a pinned piece neither falls nor swaps while its mark is on", function()
		local g = fresh()
		local s = g.s
		local src = source(g)
		EF.run(s, src, { hit(src, 20, 14) }, true)
		assert_same({ g:input({ type = "swap", from = { 2, 3 }, to = { 3, 3 } }) }, { false, "not_movable" })
	end)
end)
