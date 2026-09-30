-- Special activation framework (7.2) with the Riff, the Sabwoofer and the
-- Disco ball (8.1, 8.2, 8.4), chains (8.6).

local C = require("core.const")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }

local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows)
	return g
end

local function types(ev)
	local out = {}
	for _, e in ipairs(ev) do out[#out + 1] = e.type end
	return out
end

describe("core specials: Riff (8.1)", function()
	local ROWS = { "byrgby", "yrgbyr", "rgRyrg", "gbyrgb", "byrgby", "yrggbg" }

	it("tap -> activation in step 3 of the next tick; bolts at t0 + R(d)", function()
		local g = fresh(ROWS)
		assert_true(g:input({ type = "tap", at = { 3, 3 } }))
		g:drain_events()
		g:step() -- t0 = 1
		local ev = g:drain_events()
		assert_same(types(ev), { "activate", "bolt", "bolt", "clear" }, "own cell: removed, open slot without a tile")
		assert_same(ev[1], { t = 1, type = "activate", id = 15, x = 3, y = 3, special = "riff", axis = "h" })
		assert_same(ev[2], { t = 1, type = "bolt", x = 3, y = 3, dir = "l", at = 1 })
		assert_same(ev[3], { t = 1, type = "bolt", x = 3, y = 3, dir = "r", at = 1 })
		assert_eq(ev[4].cause, "fired")
		local s = g.s
		-- queued hits: d=1 at t0+3, d=2 at t0+5, d=3 at t0+7 (natural order, by index at equal d)
		local q = {}
		for _, r in ipairs(s.queue) do q[#q + 1] = { r.due, r.d[2] } end
		assert_same(q, { { 4, 14 }, { 4, 16 }, { 6, 13 }, { 6, 17 }, { 8, 18 } })
		-- path pins
		for _, x in ipairs({ 1, 2, 4, 5, 6 }) do
			assert_true(H.obj_at(g, x, 3).pins[1] ~= nil, "pinned " .. x)
		end
		assert_eq(#g:moves() >= 0, true)
		local src = s.sources[s.queue[1].d[1]]
		assert_eq(src.nrec, 5)
		assert_same({ src.mv, src.wv }, { 1, 1 })
		g:step()
		g:step()
		g:step() -- tick 4
		ev = g:drain_events()
		local clears = H.of_type(ev, "clear")
		assert_same({ #clears, clears[1].x, clears[2].x }, { 2, 2, 4 })
		assert_eq(clears[1].cause, "effect")
		assert_same(H.obj_at(g, 1, 3).pins, { src.id }, "still pinned until its bolt")
		for _ = 1, 4 do g:step() end -- tick 8
		assert_eq(s.sources[src.id], nil, "retired with its last record")
		for x = 1, 6 do
			local o = H.obj_at(g, x, 3)
			assert_true(o == nil or o.pins[1] == nil)
		end
	end)

	it("a pinned column above the Riff does not fall into its cell", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgVyrg", "gbyrgb", "byrgby", "yrggbg" })
		g:input({ type = "tap", at = { 3, 3 } })
		g:step()
		local above = H.obj_at(g, 3, 2)
		assert_true(above.pins[1] ~= nil)
		g:step()
		g:step()
		assert_eq(H.obj_at(g, 3, 2), above, "pinned: wait")
	end)

	it("a bolt hitting a special launches a chain after T.chain with the bolt's label", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgRySg", "gbyrgb", "byrgby", "yrggbg" })
		g:input({ type = "tap", at = { 3, 3 } })
		for _ = 1, 6 do g:step() end -- the d=2 bolt reaches (5,3) at tick 6
		local sub = H.obj_at(g, 5, 3)
		assert_eq(sub.state, C.S_ARMED)
		local found = false
		for _, r in ipairs(g.s.queue) do
			if r.kind == C.R_ACTIVATE then
				assert_same({ r.due, r.d[1], r.d[4], r.d[5] }, { 9, sub.id, 1, 1 })
				found = true
			end
		end
		assert_true(found)
	end)

	it("turbo: every bolt runs inside the activation", function()
		local g = fresh(ROWS, nil, { timing = "turbo" })
		g:input({ type = "tap", at = { 3, 3 } })
		g:step()
		local ev = g:drain_events()
		assert_eq(#H.of_type(ev, "clear"), 6)
		assert_same(g.s.queue, {})
		assert_same(g.s.sources, {})
	end)
end)

describe("core specials: Sabwoofer (8.2)", function()
	it("swells, then hits rings 0..2 at t0 + 6 + 2r; stays armed until ring 0", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgSyrg", "gbyrgb", "byrgby", "yrggbg" })
		g:input({ type = "tap", at = { 3, 3 } })
		g:drain_events()
		g:step()
		local ev = g:drain_events()
		assert_same(types(ev), { "activate", "ring", "ring", "ring" })
		assert_same({ ev[2].r, ev[2].at, ev[3].at, ev[4].at }, { 0, 7, 9, 11 })
		local sub = H.obj_at(g, 3, 3)
		assert_eq(sub.state, C.S_ARMED)
		local dues = {}
		for _, r in ipairs(g.s.queue) do dues[r.due] = (dues[r.due] or 0) + 1 end
		assert_same(dues, { [7] = 1, [9] = 8, [11] = 16 })
		for _ = 1, 6 do g:step() end -- tick 7
		assert_eq(sub.state, C.S_CLEAR)
	end)
end)

describe("core specials: Disco (8.4)", function()
	it("takes X from a swapped piece, pins its list, steps by distance, then its own cell", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgDyrg", "gbyrgb", "byrgby", "yrggbg" })
		g:input({ type = "swap", from = { 3, 3 }, to = { 4, 3 } }) -- yellow partner
		for _ = 1, 10 do g:step() end
		g:drain_events()
		g:step() -- tick 11: exchange, t0
		local ev = g:drain_events()
		local act = H.of_type(ev, "activate")[1]
		assert_same({ act.x, act.y, act.color }, { 4, 3, "yellow" })
		local s = g.s
		local src_id
		for id in pairs(s.sources) do src_id = id end -- order-independent (single source)
		local rays = H.of_type(ev, "disco_ray")
		assert_eq(#rays, 1, "step 0 at t0")
		assert_eq(math.max(math.abs(rays[1].tx - 4), math.abs(rays[1].ty - 3)), 1)
		local n = 0
		for _, r in ipairs(s.queue) do
			if r.kind == C.R_DISCO then
				n = n + 1
				assert_eq(r.due, 11 + 2 * r.d[2])
			end
		end
		assert_true(n >= 1)
		local last = s.queue[#s.queue]
		assert_same({ last.kind, last.d[2], last.due }, { C.R_HIT, 16, 11 + 2 * (n + 1) }, "own cell after the list")
		assert_true(src_id ~= nil)
	end)
end)

-- Stage B: single specials in detail, chains, taps and swipes, scores,
-- pins and the non-blocking scenarios of 7.2.7, 8.3, 8.4 and 12.1.
--
-- H.rows(6, 6) boards:  y odd: b r y g b r    y even: y g b r y g

local R = require("core.rng")

local function pattern(marks, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, H.rows(6, 6, marks))
	return g
end

local function clears_of(ev)
	local out = {}
	for _, e in ipairs(H.of_type(ev, "clear")) do out[#out + 1] = { e.t, e.x, e.y, e.cause } end
	return out
end

describe("core specials: Riff and Sabwoofer details (8.1, 8.2)", function()
	it("a Riff on the edge still emits both bolts; voids are flown through", function()
		local g = H.game({ "######", "######", "#.####", "######", "######", "######" })
		H.board(g, { "brygbr", "ygbryg", "V.ygbr", "ygbryg", "brygbr", "ygbryg" })
		local ok = g:input({ type = "tap", at = { 1, 3 } })
		assert_true(ok)
		g:step()
		local b = {}
		for _, e in ipairs(H.of_type(g:drain_events(), "bolt")) do b[#b + 1] = e.dir end
		assert_same(b, { "u", "d" })
		local g2 = H.game({ "######", "######", "#.####", "######", "######", "######" })
		H.board(g2, { "brygbr", "ygbryg", "R.ygbr", "ygbryg", "brygbr", "ygbryg" })
		g2:input({ type = "tap", at = { 1, 3 } })
		g2:step()
		local b2 = {}
		for _, e in ipairs(H.of_type(g2:drain_events(), "bolt")) do b2[#b2 + 1] = e.dir end
		assert_same(b2, { "l", "r" }, "a bolt toward the edge is emitted even with no cells")
		-- the void (2,3) is skipped but counted in d: (3,3) is at d = 2
		assert_same(H.hits(g2), { { 6, 3, 3 }, { 8, 4, 3 }, { 10, 5, 3 }, { 12, 6, 3 } })
	end)

	it("scores of effect hits: 30 per piece, 50 per hp of floor, blocker and wires; one score event per hit", function()
		local g = H.game({ "###X##", "######", "######", "######", "######", "######" }, {
			floor = { { at = { 2, 0 }, hp = 2 } }, overlay = { { at = { 4, 0 }, type = "wires", hp = 1 } } })
		H.board(g, H.rows(6, 6, { ["1,1"] = "R", ["4,1"] = "X" }))
		H.obj_at(g, 4, 1).hp = 2
		g:input({ type = "tap", at = { 1, 1 } })
		local sc = {}
		for _, e in ipairs(H.of_type(H.steps(g, 12), "score")) do sc[#sc + 1] = { e.t, e.x, e.delta } end
		assert_same(sc, { { 4, 2, 30 }, { 6, 3, 80 }, { 8, 4, 50 }, { 10, 5, 50 }, { 12, 6, 30 } })
		assert_eq(g.s.score, 240)
		assert_eq(H.obj_at(g, 5, 1).state, C.S_IDLE, "wires protect the piece")
	end)

	it("the Sabwoofer pins its 5x5 path; its own cell is not refilled during the swell", function()
		local g = pattern({ ["3,4"] = "S" })
		local above = H.obj_at(g, 3, 3)
		g:input({ type = "tap", at = { 3, 4 } })
		g:step()
		local sid = H.sources(g)[1]
		local n = 0
		for y = 2, 6 do
			for x = 1, 5 do
				local o = H.obj_at(g, x, y)
				if not (x == 3 and y == 4) then
					assert_same(o.pins, { sid })
					n = n + 1
				end
			end
		end
		assert_eq(n, 24)
		assert_same(H.obj_at(g, 3, 1).pins, {}, "outside the 5x5")
		H.steps(g, 5) -- tick 6
		assert_eq(H.obj_at(g, 3, 4).state, C.S_ARMED)
		assert_eq(H.obj_at(g, 3, 3), above)
	end)
end)

describe("core specials: Disco details (8.4)", function()
	it("list by distance, pinned pieces do not fall, a step whose piece left is skipped, own cell last", function()
		-- Disco at (6,6), X = red (9 reds, ties go to the smaller code); a Riff on row 2
		-- tapped second destroys (4,2) (k = 4) before its step and empties (2,2) under (2,1).
		local g = pattern({ ["6,6"] = "D", ["1,2"] = "R" })
		local red21 = H.obj_at(g, 2, 1)
		g:input({ type = "tap", at = { 6, 6 } })
		g:input({ type = "tap", at = { 1, 2 } })
		g:step() -- t0 = 1
		local ev = g:drain_events()
		assert_eq(H.of_type(ev, "activate")[1].color, "red")
		local sid = H.sources(g)[1]
		local want = {}
		local L = { { 6, 5 }, { 4, 4 }, { 4, 6 }, { 6, 3 }, { 4, 2 }, { 2, 3 }, { 2, 5 }, { 2, 1 }, { 6, 1 } }
		for k = 2, 9 do
			local o = H.obj_at(g, L[k][1], L[k][2])
			assert_true(o.pins[1] == sid, "pinned by the Disco")
			want[#want + 1] = { 1 + 2 * (k - 1), C.R_DISCO, sid, k - 1, o.id }
		end
		want[#want + 1] = { 19, C.R_HIT, sid, H.idx(g, 6, 6) }
		local q = {}
		for _, r in ipairs(H.queue(g)) do
			if r[3] == sid then q[#q + 1] = r end
		end
		assert_same(q, want)
		assert_same(H.of_type(ev, "disco_ray")[1], { t = 1, type = "disco_ray", x = 6, y = 6, tx = 6, ty = 5 })
		ev = H.steps(g, 13) -- to tick 14; (2,2) is empty from tick 13
		assert_eq(g.s.slot[H.idx(g, 2, 2)], 0)
		assert_eq(H.obj_at(g, 2, 1), red21, "pinned: it waits for its step")
		local rays = {}
		for _, e in ipairs(H.of_type(ev, "disco_ray")) do rays[#rays + 1] = e.t end
		assert_same(rays, { 3, 5, 7, 11, 13 }, "no ray at tick 9: (4,2) went to the Riff")
		ev = H.steps(g, 5) -- to tick 19
		rays = {}
		for _, e in ipairs(H.of_type(ev, "disco_ray")) do rays[#rays + 1] = e.t .. ":" .. e.tx .. e.ty end
		assert_same(rays, { "15:21", "17:61" })
		local fired = {}
		for _, c in ipairs(clears_of(ev)) do
			if c[4] == "fired" then fired[#fired + 1] = c end
		end
		assert_same(fired, { { 19, 6, 6, "fired" } })
	end)

	it("intact balloons of colour X are in the list (not pinned); other colours are not", function()
		local g = H.game({ "######", "##A###", "######", "######", "######", "#####E" },
			{ goals = { { type = "break", item = "balloon", count = 2 } } })
		H.board(g, H.rows(6, 6, { ["3,2"] = "A", ["6,6"] = "E", ["3,3"] = "D" }))
		local balloon = H.obj_at(g, 3, 2)
		g:input({ type = "swap", from = { 3, 3 }, to = { 2, 3 } }) -- red partner: the Disco lands in (2,3)
		local ev = H.steps(g, 11)
		assert_eq(H.of_type(ev, "activate")[1].color, "red")
		assert_same(balloon.pins, {}, "balloons are not pinned")
		-- distance 1 from (2,3): the balloon (3,2) comes before the red piece (3,3) by index
		assert_same(H.of_type(ev, "disco_ray")[1], { t = 11, type = "disco_ray", x = 2, y = 3, tx = 3, ty = 2 })
		assert_same(H.of_type(ev, "destroy")[1], { t = 11, type = "destroy", id = balloon.id, x = 3, y = 2, item = "balloon" })
		for _, r in ipairs(g.s.queue) do
			if r.kind == C.R_DISCO then assert_true(r.d[3] ~= H.obj_at(g, 6, 6).id, "blue balloon") end
		end
		g:run_to_rest()
		assert_eq(g.s.goal_left[1], 1, "the red balloon broke, the blue one did not")
	end)

	it("a Disco swapped with a mic or chained picks X = mf() at activation", function()
		local g = H.game(FULL, { goals = { { type = "deliver", count = 1 } }, mic = { total = 1, on_board_max = 1, gap_moves = 0 },
			slots = { { at = { 3, 2 }, type = "mic" } } })
		H.board(g, H.rows(6, 6, { ["3,3"] = "D", ["4,3"] = "M" }))
		g:input({ type = "swap", from = { 3, 3 }, to = { 4, 3 } })
		H.steps(g, 10)
		g:step()
		local act = H.of_type(g:drain_events(), "activate")[1]
		assert_same({ act.x, act.color }, { 4, "red" })
		-- chain
		local g2 = pattern({ ["1,3"] = "R", ["3,3"] = "D" })
		g2:input({ type = "tap", at = { 1, 3 } })
		H.steps(g2, 6)
		local rec
		for _, r in ipairs(g2.s.queue) do
			if r.kind == C.R_ACTIVATE then rec = r end
		end
		assert_same({ rec.due, rec.d[3], rec.d[6] }, { 9, 0, 0 }, "X chosen at activation")
		H.steps(g2, 2) -- tick 8
		local X = require("core.board").most_frequent(g2.s, false)
		local ev = H.steps(g2, 1)
		assert_eq(H.of_type(ev, "activate")[1].color, C.COLOR_NAME[X])
	end)
end)

describe("core specials: chains (8.6)", function()
	it("an armed special hit again is an open slot: one activation, label of the first hit", function()
		local g = pattern({ ["1,3"] = "R", ["3,4"] = "V", ["3,3"] = "S" })
		local sub = H.obj_at(g, 3, 3)
		g:input({ type = "tap", at = { 1, 3 } }) -- a = 1: reaches (3,3) at tick 6
		g:input({ type = "tap", at = { 3, 4 } }) -- a = 2: reaches (3,3) at tick 4
		g:step()
		assert_eq(#sub.pins, 2, "on both paths")
		H.steps(g, 3) -- tick 4
		assert_eq(sub.state, C.S_ARMED)
		local recs = {}
		for _, r in ipairs(g.s.queue) do
			if r.kind == C.R_ACTIVATE then recs[#recs + 1] = { r.due, r.d[1], r.d[4], r.d[5] } end
		end
		assert_same(recs, { { 7, sub.id, 2, 1 } })
		g:step()
		g:step() -- tick 6: the first Riff's bolt finds an open slot
		local n = 0
		for _, r in ipairs(g.s.queue) do
			if r.kind == C.R_ACTIVATE then n = n + 1 end
		end
		assert_eq(n, 1, "no second launch")
		local ev = g:drain_events()
		assert_eq(#H.of_type(ev, "activate"), 0)
		ev = H.steps(g, 1) -- tick 7
		local act = H.of_type(ev, "activate")
		assert_same({ #act, act[1].id }, { 1, sub.id })
	end)

	it("a chained Riff keeps its axis", function()
		local g = pattern({ ["1,3"] = "R", ["3,3"] = "V" })
		g:input({ type = "tap", at = { 1, 3 } })
		local ev = H.steps(g, 9) -- hit at 6, activation at 9
		local act = H.of_type(ev, "activate")
		assert_same({ act[2].t, act[2].axis }, { 9, "v" })
		local b = {}
		for _, e in ipairs(H.of_type(ev, "bolt")) do
			if e.t == 9 then b[#b + 1] = e.dir end
		end
		assert_same(b, { "u", "d" })
	end)
end)

describe("core specials: taps and swaps (5.1.4, 5.1.5, 5.2)", function()
	it("tap: rejections", function()
		local g = pattern({ ["3,3"] = "S", ["4,4"] = "R" })
		assert_same({ g:input({ type = "tap", at = { 1, 1 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "tap", at = { 7, 1 } }) }, { false, "bad_cell" })
		assert_true(g:input({ type = "tap", at = { 3, 3 } }))
		assert_same({ g:input({ type = "tap", at = { 3, 3 } }) }, { false, "not_movable" }, "armed")
		g:step()
		assert_true(H.obj_at(g, 4, 4).pins[1] ~= nil, "in the rings")
		assert_same({ g:input({ type = "tap", at = { 4, 4 } }) }, { false, "not_movable" }, "pinned")
		assert_same({ g:input({ type = "swap", from = { 4, 4 }, to = { 5, 4 } }) }, { false, "not_movable" })
	end)

	it("a swipe to the edge, a void, an empty slot, a blocker or wires is a tap", function()
		local targets = { { 0, 1 }, { 2, 1 }, { 1, 2 } }
		local g = H.game({ "#.####", "######", "######", "######", "######", "######" })
		H.board(g, { "R.ygbr", "_gbryg", "brygbr", "ygbryg", "brygbr", "ygbryg" })
		for k, to in ipairs(targets) do
			local g2 = g:clone()
			local ok, res = g2:input({ type = "swap", from = { 1, 1 }, to = to })
			assert_same({ ok, res }, { true, "ok" }, "target " .. k)
			assert_same({ g2.s.act, g2.s.moves_left, #g2.s.swaps }, { 1, 19, 0 })
			local q = H.queue(g2)
			assert_same(q, { { 1, C.R_ACTIVATE, H.obj_at(g2, 1, 1).id, 1, 0, 1, 1, 0 } })
			assert_same(g2:replay().commands[1].cmd.type, "swap")
			assert_eq(g2:can_swap({ 1, 1 }, to), "reject", "the Riff is armed now")
			assert_eq(g:can_swap({ 1, 1 }, to), "ok")
		end
		local g3 = H.game({ "######", "#X####", "######", "######", "######", "######" },
			{ overlay = { { at = { 2, 2 }, type = "wires", hp = 1 } } })
		H.board(g3, H.rows(6, 6, { ["2,1"] = "R", ["2,2"] = "X", ["3,2"] = "R" }))
		assert_same({ g3:input({ type = "swap", from = { 2, 1 }, to = { 2, 2 } }) }, { true, "ok" }, "into a blocker")
		assert_same({ g3:input({ type = "swap", from = { 3, 2 }, to = { 3, 3 } }) }, { true, "ok" }, "into wires")
		assert_eq(#g3.s.swaps, 0)
		assert_eq(g3.s.act, 2)
	end)

	it("a special swapped with a piece moves, is armed and fires in its new cell; the piece matches", function()
		local g = pattern({ ["3,3"] = "R", ["4,3"] = "b" })
		local riff = H.obj_at(g, 3, 3)
		g:input({ type = "swap", from = { 4, 3 }, to = { 3, 3 } })
		H.steps(g, 10)
		g:step() -- tick 11
		local ev = g:drain_events()
		assert_same(types(ev), { "match", "clear", "score", "clear", "score", "clear", "score", "activate", "bolt", "bolt", "clear" })
		assert_same({ ev[1].act, ev[1].wave, #ev[1].cells }, { 1, 1, 3 })
		assert_same({ ev[8].id, ev[8].x, ev[8].y }, { riff.id, 4, 3 })
		assert_eq(ev[11].cause, "fired")
		assert_eq(#g.s.swaps, 0, "never refunded")
	end)
end)

describe("core specials: non-blocking play (7.2.7, 8.3, 8.4)", function()
	it("pieces on a bolt's path do not fall into the holes under them before the bolt", function()
		local g = H.game(FULL)
		H.board(g, { "brygbr", "ygbryg", "Rrygbr", "______", "brygbr", "ygbryg" })
		local row = {}
		for x = 2, 6 do row[x] = H.obj_at(g, x, 3).id end
		g:input({ type = "tap", at = { 1, 3 } })
		local ev = H.steps(g, 12)
		local got = {}
		for _, e in ipairs(H.of_type(ev, "clear")) do
			if e.cause == "effect" then got[#got + 1] = { e.t, e.id } end
		end
		assert_same(got, { { 4, row[2] }, { 6, row[3] }, { 8, row[4] }, { 10, row[5] }, { 12, row[6] } })
	end)

	it("input stays open during effects: a swap elsewhere is accepted and resolves with its own action", function()
		local g = pattern({ ["1,1"] = "R", ["2,6"] = "b" })
		g:input({ type = "tap", at = { 1, 1 } })
		H.steps(g, 2)
		assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 3, 2 } }) }, { false, "not_movable" }, "pinned by the bolt")
		assert_same({ g:input({ type = "swap", from = { 1, 5 }, to = { 1, 6 } }) }, { true, "ok" })
		assert_same({ g.s.eom[1].a, g.s.eom[2].a }, { 1, 2 })
		local ev = H.steps(g, 11) -- accepted with now = 3: the swap ends at tick 13
		local m = H.of_type(ev, "match")[1]
		assert_same({ m.t, m.act, m.wave, m.color }, { 13, 2, 1, "blue" })
	end)
end)
