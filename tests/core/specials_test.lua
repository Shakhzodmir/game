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
