-- Gravity, spawn and falling (10.1-10.3), tick by tick.

local C = require("core.const")
local B = require("core.board")
local G = require("core.gravity")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
local BASE = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }

local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or BASE)
	return g
end

local function column_offsets(g, x)
	local out = {}
	for y = 1, 6 do
		local o = H.obj_at(g, x, y)
		out[y] = o and o.offy or -1
	end
	return out
end

describe("core gravity: falling (10.2)", function()
	it("a piece falls one cell in 7 ticks: v0 300, +60 per tick", function()
		local g = fresh({ "byrgby", "_rgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
		local red = H.obj_at(g, 1, 1)
		local want = { 3240, 2820, 2340, 1800, 1200, 540 }
		for t = 1, 6 do
			g:step()
			assert_eq(H.obj_at(g, 1, 2), red)
			assert_eq(red.state, C.S_FALL, "tick " .. t)
			assert_eq(red.offy, want[t], "tick " .. t)
		end
		g:step()
		assert_eq(red.state, C.S_IDLE)
		assert_eq(red.offy, 0)
		assert_eq(red.vy, 0)
		assert_eq(red.settle, 7)
		local land = H.of_type(g:drain_events(), "land")
		assert_same(land[1], { t = 7, type = "land", id = red.id, x = 1, y = 2 })
	end)

	it("spawns one cell above the spawner with the next start delay; hidden until it shows", function()
		local g = fresh({ "byrgby", "_rgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
		g:step()
		local sp = H.obj_at(g, 1, 1)
		assert_eq(sp.state, C.S_FALL)
		assert_eq(sp.offy, 3600)
		assert_eq(sp.delay, 0, "counted down in step 6 of tick 1")
		assert_eq(sp.id, 36, "35 objects on the board, the spawn takes the next id")
		local p = g:pieces()[1]
		assert_true(p.hidden)
		assert_eq(g.s.last_assign, 2)
		local ev = H.of_type(g:drain_events(), "spawn")
		assert_eq(#ev, 1)
		assert_same({ ev[1].id, ev[1].x, ev[1].y, ev[1].kind }, { 36, 1, 1, "regular" })
		g:step()
		assert_eq(sp.offy, 3240)
		assert_false(g:pieces()[1].hidden)
		for _ = 1, 6 do g:step() end -- tick 8
		assert_eq(sp.state, C.S_IDLE)
		assert_eq(sp.settle, 8)
		-- the landing dirtied the board; the step-7 search of the same tick cleaned it
		assert_false(g.s.dirty)
		assert_true(g:is_stable())
	end)

	it("never gets closer than a cell to a falling piece below; the stop never lifts", function()
		local g = fresh()
		local P, Bo = H.obj_at(g, 1, 2), H.obj_at(g, 1, 3)
		P.state, P.offy, P.vy = C.S_FALL, 1000, 1000
		Bo.state, Bo.offy, Bo.vy, Bo.delay = C.S_FALL, 3000, 300, 5
		g:step()
		assert_eq(P.offy, 1000, "lim 3000 > new -60: new = min(lim, offy)")
		assert_eq(P.vy, 300, "vy = min(vy, B.vy)")
		assert_eq(Bo.delay, 4)
	end)

	it("clamps exactly when lim > new (strict)", function()
		local g = fresh()
		local P, Bo = H.obj_at(g, 1, 2), H.obj_at(g, 1, 3)
		P.state, P.offy, P.vy = C.S_FALL, 3360, 300
		Bo.state, Bo.offy, Bo.vy, Bo.delay = C.S_FALL, 3000, 300, 9
		g:step() -- new = 3360 - 360 = 3000 = lim: not stuck
		assert_eq(P.offy, 3000)
		assert_eq(P.vy, 360)
		g:step() -- new = 3000 - 420 = 2580 < lim 3000: stuck at 3000
		assert_eq(P.offy, 3000)
		assert_eq(P.vy, 300)
	end)

	it("turbo lands every falling piece in the same tick", function()
		local g = fresh({ "byrgby", "_rgbyr", "_gbyrg", "gbyrgb", "byrgby", "yrggbg" }, nil, { timing = "turbo" })
		g:step()
		for y = 1, 3 do
			local o = H.obj_at(g, 1, y)
			assert_eq(o.state, C.S_IDLE)
			assert_same({ o.offy, o.offx, o.vy, o.delay, o.settle }, { 0, 0, 0, 0, 1 })
		end
		local land = H.of_type(g:drain_events(), "land")
		assert_same({ land[1].y, land[2].y, land[3].y }, { 3, 2, 1 }, "bottom to top")
	end)
end)

describe("core gravity: assignment (10.1)", function()
	it("counts start delays per target column and moves labels through vac", function()
		local g = fresh({ "byrgby", "yrgbyr", "_gbyrg", "_byrgb", "byrgby", "yrggbg" })
		local s = g.s
		s.vac_mv[13], s.vac_wv[13] = 5, 2 -- (1,3)
		s.vac_mv[19], s.vac_wv[19] = 3, 9 -- (1,4)
		local low, high = H.obj_at(g, 1, 2), H.obj_at(g, 1, 1)
		g:step()
		assert_eq(H.obj_at(g, 1, 4), low)
		assert_eq(H.obj_at(g, 1, 3), high)
		assert_same({ low.mv, low.wv }, { 5, 2 }, "max of T.vac and the cells passed")
		assert_same({ high.mv, high.wv }, { 5, 2 }, "took the vac left by `low`")
		assert_eq(low.delay, 0)
		assert_eq(high.delay, 0, "delay 1 counted down in step 6")
		assert_eq(high.offy, 7200)
		assert_eq(low.offy, 7200 - 360)
		-- two spawns follow: labels from the segment above
		local s1, s2 = H.obj_at(g, 1, 2), H.obj_at(g, 1, 1)
		assert_same({ s1.mv, s1.wv, s2.mv, s2.wv }, { 5, 2, 5, 2 })
		assert_eq(s1.delay, 1)
		assert_eq(s2.delay, 2)
		-- spawn offy: one cell above the spawner, and not within a cell of `high`
		assert_eq(s1.offy, 7200)
		assert_eq(s2.offy, 7200)
		assert_eq(g.s.last_assign, 4)
	end)

	it("records a merge when gravity raises a label between two queued actions (1.3.10)", function()
		local g = fresh({ "byrgby", "_rgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
		local s = g.s
		s.eom = { { a = 1, noise_hit = false, merged = 0 }, { a = 2, noise_hit = false, merged = 0 } }
		H.obj_at(g, 1, 1).mv = 1
		s.vac_mv[7], s.vac_wv[7] = 2, 3
		g:step()
		assert_eq(s.eom[1].merged, 2)
		assert_eq(s.eom[2].merged, 0)
	end)

	it("waits under an armed, swapping or clearing piece and under a pinned one", function()
		local g = fresh({ "Sbyrgb", "_rgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
		H.obj_at(g, 1, 1).state = C.S_ARMED
		g:step()
		assert_eq(H.obj_at(g, 1, 2), nil)
		assert_eq(g.s.last_assign, 0)
		H.obj_at(g, 1, 1).state = C.S_IDLE
		H.obj_at(g, 1, 1).pins = { 3 }
		g:step()
		assert_eq(H.obj_at(g, 1, 2), nil)
		H.obj_at(g, 1, 1).pins = {}
		g:step()
		assert_true(H.obj_at(g, 1, 2) ~= nil)
	end)

	it("slides a donor diagonally under a blocker: right first in odd ticks", function()
		local g = fresh({ "byrgby", "yXgbyr", "r_byrg", "gbyrgb", "byrgby", "yrggbg" })
		local right, left = H.obj_at(g, 3, 2), H.obj_at(g, 1, 2)
		g:step() -- tick 1
		assert_eq(H.obj_at(g, 2, 3), right)
		assert_eq(right.offx, -3600 + 360)
		assert_eq(right.offy, 3600 - 360)
		-- the donor cell is refilled at once, one delay behind the slider
		local refill = H.obj_at(g, 3, 2)
		assert_eq(refill.state, C.S_FALL)
		assert_eq(refill.delay, 0, "max(0, 0 + 1) counted down")
		assert_eq(refill.offy, 3600)
		assert_eq(left.state, C.S_IDLE)
	end)

	it("takes the left donor first in even ticks", function()
		local g = fresh()
		g:step() -- tick 1, nothing to do
		H.board(g, { "byrgby", "yXgbyr", "r_byrg", "gbyrgb", "byrgby", "yrggbg" })
		local left = H.obj_at(g, 1, 2)
		g:step() -- tick 2
		assert_eq(H.obj_at(g, 2, 3), left)
		assert_eq(left.offx, 3600 - 360)
	end)

	it("does not slide while a faller below is still visually above the cell", function()
		local g = fresh({ "byrgby", "yXgbyr", "r_byrg", "gbyrgb", "byrgby", "yrggbg" })
		local below = H.obj_at(g, 2, 4)
		below.state, below.offy, below.vy, below.delay = C.S_FALL, 4000, 300, 3
		g:step()
		assert_eq(H.obj_at(g, 2, 3), nil, "wait")
	end)

	it("a donor needs support: the cell under it exists and is not empty", function()
		local g = fresh({ "byrgby", "yXgbyr", "r__yrg", "gbyrgb", "byrgby", "yrggbg" })
		-- tick 1 tries the right donor (3,2) first, but (3,3) under it is empty
		local right, left = H.obj_at(g, 3, 2), H.obj_at(g, 1, 2)
		g:step()
		assert_eq(H.obj_at(g, 2, 3), left)
		assert_eq(left.offx, 3600 - 360)
		assert_eq(H.obj_at(g, 3, 3), right, "the right one falls straight down")
		assert_eq(right.offx, 0)
	end)

	it("leaves a hole when no donor fits; holes are legal at rest", function()
		local g = fresh({ "rrgrby", "XXXbyr", "r_byrg", "gbyrgb", "byrgby", "yrggbg" })
		g:step()
		-- (1,2) and (3,2) are blockers: no donor
		assert_eq(H.obj_at(g, 2, 3), nil)
		g:step()
		assert_true(g:is_stable())
	end)

	it("hidden: a falling piece above its spawner's top edge", function()
		local g = fresh()
		local o = H.obj_at(g, 2, 1)
		o.state, o.offy = C.S_FALL, 3600
		assert_true(G.hidden(g.s, o))
		o.offy = 3599
		assert_false(G.hidden(g.s, o))
	end)
end)

describe("core gravity: spawn colours and microphones (10.3, 10.4)", function()
	it("spends one spawn draw per piece; help adds one int(100) first", function()
		local R = require("core.rng")
		local g = fresh({ "_yrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
		local copy = { unpack(g.s.rng[R.SPAWN]) }
		g:step()
		R.next_int(copy)
		assert_same(g.s.rng[R.SPAWN], copy)
		local g2 = fresh({ "_yrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }, nil, { help = 2 })
		local c2 = { unpack(g2.s.rng[R.SPAWN]) }
		local p = R.int(c2, 100)
		g2:step()
		if p > 10 then R.next_int(c2) end
		assert_same(g2.s.rng[R.SPAWN], c2)
	end)

	it("releases a microphone instead of a piece when the counters allow", function()
		local deliver = { goals = { { type = "deliver", count = 2 } }, mic = { total = 2, on_board_max = 1, gap_moves = 0 } }
		local g = fresh({ "__rgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }, deliver)
		g.s.released, g.s.on_board, g.s.last_mic = 0, 0, 0
		g:step()
		local kinds = { H.obj_at(g, 1, 1).kind, H.obj_at(g, 2, 1).kind }
		assert_same(kinds, { C.K_MIC, C.K_REGULAR }, "one mic per pass")
		assert_eq(g.s.released, 1)
		assert_eq(g.s.on_board, 1)
	end)
end)
