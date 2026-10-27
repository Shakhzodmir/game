-- Gravity, spawn and falling (10.1-10.3), tick by tick.

local core = require("core.game")
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

-- Audit C additions: the rest of the scan table, transfers of fallers, the
-- refill rule, help colours (10.3) and microphones (10.4).

-- Step 5 alone (the assignment pass), as the tick would run it.
local function assign(g)
	g.s.now = g.s.tick + 1
	g.s.phase = 5
	return G.assign(g.s)
end

describe("core gravity: scan table and transfers (10.1)", function()
	it("waits under a swapping piece and under a clearing one", function()
		local g = fresh({ "byrgby", "_rgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
		local top = H.obj_at(g, 1, 1)
		top.state, top.tk, top.td = C.S_SWAP, C.TM_LOCK, 99
		assert_eq(assign(g), 0)
		assert_eq(H.obj_at(g, 1, 2), nil)
		top.state, top.tk, top.td = C.S_CLEAR, C.TM_CLEAR, 99
		assert_eq(assign(g), 0)
		assert_eq(H.obj_at(g, 1, 2), nil)
	end)

	it("a wired piece above blocks the column: the cell below is a diagonal case", function()
		local g = fresh({ "byrgby", "_rgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
		g.s.wires[1] = 1
		local donor = H.obj_at(g, 2, 1)
		-- tick 1 is odd: the right donor goes first; (2,1) has support (2,2)
		assert_eq(assign(g), 2, "the slide and the refill of the donor cell")
		assert_eq(H.obj_at(g, 1, 2), donor)
		assert_eq(donor.offx, -3600, "a right donor starts a cell to the right")
		assert_eq(donor.offy, 3600)
		assert_eq(donor.state, C.S_FALL)
		assert_eq(H.obj_at(g, 1, 1).state, C.S_IDLE, "the wired piece stays")
		assert_eq(H.obj_at(g, 1, 1).wv, 0)
	end)

	it("spawns only below a spawner: the top of a segment without one is filled diagonally", function()
		local rows = { "##.###", "##.###", "######", "######", "######", "######" }
		local lvl = H.load(rows, { spawners = { { 0, 0 }, { 1, 0 }, { 3, 0 }, { 4, 0 }, { 5, 0 } } })
		local g = core.new(lvl, { seed = 1 })
		H.board(g, { "by.gby", "yr.byr", "rg_yrg", "gbyrgb", "byrgby", "yrggbg" })
		g:step()
		-- column 3 has no spawner: its top cell (3,3) is filled by a slider from the right (odd tick)
		local o = H.obj_at(g, 3, 3)
		assert_true(o ~= nil and o.state == C.S_FALL and o.offx ~= 0)
		for _, e in ipairs(g:drain_events()) do
			if e.type == "spawn" then assert_true(e.x ~= 3, "no spawn in column 3") end
		end
		for _, p in ipairs(g:pieces()) do
			if p.x == 3 and p.y == 3 then assert_false(p.hidden, "no spawner above: nothing to hide behind") end
		end
	end)

	it("a faller that moves on keeps vy and delay and does not advance the start counter", function()
		local g = fresh({ "byrgby", "yrgbyr", "__gbyr", "__yrgb", "byrgby", "yrggbg" })
		local top, f = H.obj_at(g, 1, 1), H.obj_at(g, 1, 2)
		f.state, f.offy, f.vy, f.delay = C.S_FALL, 500, 700, 3
		assign(g)
		assert_eq(H.obj_at(g, 1, 4), f)
		assert_same({ f.offy, f.vy, f.delay }, { 500 + 2 * 3600, 700, 3 }, "offy grows by the rows passed")
		assert_eq(H.obj_at(g, 1, 3), top)
		assert_same({ top.state, top.vy, top.delay, top.offy }, { C.S_FALL, 300, 0, 7200 }, "counter still 0")
		assert_eq(H.obj_at(g, 1, 2).delay, 1)
		assert_eq(H.obj_at(g, 1, 1).delay, 2)
	end)

	it("a piece entering a cell its donor left takes vy = min(vy, vy_D) and delay + 1 (refill)", function()
		-- (1,3) is blocked by the box (1,2): the right donor (2,2) slides in (tick 1 is odd);
		-- the faller of (2,1) then drops into the cell the donor left
		local g = fresh({ "byrgby", "Xrgbyr", "_gbyrg", "gbyrgb", "byrgby", "yrggbg" })
		local donor, faller = H.obj_at(g, 2, 2), H.obj_at(g, 2, 1)
		faller.state, faller.offy, faller.vy, faller.delay = C.S_FALL, 800, 900, 0
		assert_eq(assign(g), 3, "slide, faller moves down, spawn into the freed top cell")
		assert_eq(H.obj_at(g, 1, 3), donor)
		assert_same({ donor.vy, donor.delay }, { 300, 0 })
		assert_eq(H.obj_at(g, 2, 2), faller)
		assert_same({ faller.offy, faller.vy, faller.delay }, { 800 + 3600, 300, 1 })
	end)
end)

-- A seed whose first spawn-stream draw int(100) is p.
local function seed_with_first_draw(p)
	local R = require("core.rng")
	for seed = 1, 20000 do
		if R.int(R.stream(seed, R.SPAWN), 100) == p then return seed end
	end
	error("no seed for " .. p)
end

-- One spawn at (1,1) on an otherwise full board; returns the new piece and
-- the number of draws the spawn stream made.
local function spawn_one(rows, extra, opts, tweak)
	local R = require("core.rng")
	local g = fresh(rows, extra, opts)
	if tweak then tweak(g) end
	local copy = { unpack(g.s.rng[R.SPAWN]) }
	assign(g)
	local draws = 0
	while table.concat(copy, ",") ~= table.concat(g.s.rng[R.SPAWN], ",") do
		R.next_int(copy)
		draws = draws + 1
		assert_true(draws < 10, "stream moved away from its start")
	end
	return H.obj_at(g, 1, 1), draws
end

local HOLE = { "_yrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }

describe("core gravity: help colours (10.3)", function()
	it("level 1 forces the colour for p <= 5, level 2 for p <= 10; a forced pick makes no second draw", function()
		local COLLECT = { goals = { { type = "collect", color = "green", count = 7 }, { type = "collect", color = "blue", count = 9 } } }
		local o, n = spawn_one(HOLE, COLLECT, { help = 1, seed = seed_with_first_draw(5) })
		assert_eq(o.color, C.COLOR.blue)
		assert_eq(n, 1)
		o, n = spawn_one(HOLE, COLLECT, { help = 1, seed = seed_with_first_draw(6) })
		assert_eq(n, 2, "p = 6 is not forced on level 1: the colour draw follows")
		o, n = spawn_one(HOLE, COLLECT, { help = 2, seed = seed_with_first_draw(6) })
		assert_eq(o.color, C.COLOR.blue)
		assert_eq(n, 1)
		o, n = spawn_one(HOLE, COLLECT, { help = 2, seed = seed_with_first_draw(10) })
		assert_eq(o.color, C.COLOR.blue)
		assert_eq(n, 1)
		o, n = spawn_one(HOLE, COLLECT, { help = 2, seed = seed_with_first_draw(11) })
		assert_eq(n, 2)
		o, n = spawn_one(HOLE, COLLECT, { help = 0, seed = seed_with_first_draw(1) })
		assert_eq(n, 1, "no help: no int(100)")
	end)

	it("forced colour: the open collect goal with the largest remainder, a tie goes to the smaller colour", function()
		local seed = seed_with_first_draw(1)
		local o = spawn_one(HOLE, { goals = { { type = "collect", color = "green", count = 7 }, { type = "collect", color = "blue", count = 9 } } },
			{ help = 2, seed = seed })
		assert_eq(o.color, C.COLOR.blue)
		o = spawn_one(HOLE, { goals = { { type = "collect", color = "blue", count = 7 }, { type = "collect", color = "green", count = 7 } } },
			{ help = 2, seed = seed })
		assert_eq(o.color, C.COLOR.green, "tie: green (4) before blue (5)")
		-- a met goal does not count
		o = spawn_one(HOLE, { goals = { { type = "collect", color = "green", count = 7 }, { type = "collect", color = "blue", count = 9 } } },
			{ help = 2, seed = seed }, function(g) g.s.goal_left = { 7, 0 } end)
		assert_eq(o.color, C.COLOR.green)
	end)

	it("forced colour: without a collect goal the colour with most intact balloons, then mf(), then the lowest colour", function()
		local seed = seed_with_first_draw(1)
		local PIC = { "######", "#A#E#E", "######", "######", "######", "######" }
		local function game_with(goals, tweak)
			local g = H.game(PIC, { goals = goals, colors = { "orange", "red", "blue", "purple" } }, { help = 2, seed = seed })
			H.board(g, { "_yrgby", "yAyEyE", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
			if tweak then tweak(g) end
			assign(g)
			return H.obj_at(g, 1, 1)
		end
		local BALLOONS = { { type = "break", item = "balloon", count = 3 } }
		assert_eq(game_with(BALLOONS).color, C.COLOR.blue, "two blue balloons against one red")
		-- one red, one blue: a tie goes to red
		assert_eq(game_with(BALLOONS, function(g) H.obj_at(g, 6, 2).color = 1 end).color, C.COLOR.red)
		-- a met balloon goal falls through to mf()
		local o = game_with(BALLOONS, function(g) g.s.goal_left = { 0 } end)
		assert_eq(o.color, C.COLOR.yellow)
		-- every regular piece pinned or gone: the smallest colour of the level (red = 1 before orange = 2)
		o = game_with(BALLOONS, function(g)
			g.s.goal_left = { 0 }
			for i = 1, g.s.N do
				local p = B.get(g.s, i)
				if p and p.kind == C.K_REGULAR then p.pins = { 99 } end
			end
		end)
		assert_eq(o.color, C.COLOR.red, "level.colors[1] in the global order, not the list order")
	end)

	it("mf() counts pieces under wires but not pinned ones", function()
		local seed = seed_with_first_draw(1)
		local rows = { "_gbgby", "gbgbyr", "gbgbgb", "gbgbgb", "byrgby", "yrggbg" }
		local goals = { goals = { { type = "collect", color = "red", count = 999 } } }
		local o = spawn_one(rows, goals, { help = 2, seed = seed }, function(g) g.s.goal_left = { 0 } end)
		assert_eq(o.color, C.COLOR.green, "green and blue tie high; green is smaller")
		-- wired green pieces still count (14 green against 13 blue, two of the green under wires)
		o = spawn_one(rows, goals, { help = 2, seed = seed }, function(g)
			g.s.goal_left = { 0 }
			g.s.wires[7] = 1
			g.s.wires[9] = 1
		end)
		assert_eq(o.color, C.COLOR.green)
		-- pinning the green pieces hands the colour to blue
		o = spawn_one(rows, goals, { help = 2, seed = seed }, function(g)
			g.s.goal_left = { 0 }
			for i = 1, g.s.N do
				local p = B.get(g.s, i)
				if p and p.color == C.COLOR.green then p.pins = { 99 } end
			end
		end)
		assert_eq(o.color, C.COLOR.blue)
	end)
end)

describe("core gravity: microphones (10.4)", function()
	local function mic_level(mic)
		return { goals = { { type = "deliver", count = 3 } }, mic = mic }
	end
	local TOP_OPEN = { "______", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }

	local function release(mic, counters)
		local g = fresh(TOP_OPEN, mic_level(mic))
		local s = g.s
		s.released, s.on_board, s.last_mic, s.moves_made = counters[1], counters[2], counters[3], counters[4]
		assign(g)
		local mics = 0
		for x = 1, 6 do
			local o = H.obj_at(g, x, 1)
			if o.kind == C.K_MIC then mics = mics + 1 end
		end
		return mics, g
	end

	it("releases at most one microphone per pass and updates the counters", function()
		local mics, g = release({ total = 3, on_board_max = 2, gap_moves = 0 }, { 0, 0, 0, 0 })
		assert_eq(mics, 1)
		assert_eq(H.obj_at(g, 1, 1).kind, C.K_MIC, "the first spawn of the pass")
		assert_same({ g.s.released, g.s.on_board, g.s.last_mic }, { 1, 1, 0 })
		local ev = H.of_type(g:drain_events(), "spawn")
		assert_same({ ev[1].kind, ev[1].color }, { "mic", nil })
		assert_eq(ev[2].kind, "regular")
	end)

	it("a microphone costs no random number", function()
		local R = require("core.rng")
		local g = fresh(TOP_OPEN, mic_level({ total = 3, on_board_max = 2, gap_moves = 0 }))
		local copy = { unpack(g.s.rng[R.SPAWN]) }
		assign(g)
		for _ = 1, 5 do R.next_int(copy) end
		assert_same(g.s.rng[R.SPAWN], copy, "6 spawns, 1 mic, 5 colour draws")
	end)

	it("respects total, on_board_max and the gap in moves since the last release", function()
		local L = { total = 3, on_board_max = 2, gap_moves = 2 }
		assert_eq((release(L, { 3, 0, 0, 9 })), 0, "everything released")
		assert_eq((release(L, { 1, 2, 0, 9 })), 0, "two on the board")
		assert_eq((release(L, { 1, 1, 0, 1 })), 0, "moves_made - last_mic = 1 < 2")
		assert_eq((release(L, { 1, 1, 0, 2 })), 1, "= 2: released")
		local _, g = release(L, { 1, 1, 3, 5 })
		assert_eq(g.s.last_mic, 5, "last_mic follows moves_made")
	end)

	it("moves_made counts accepted swaps and taps; a failed swap and a refund take nothing / the move back", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } })
		assert_eq(g.s.moves_made, 0, "a failed swap is no move")
		g:run_to_rest()
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		assert_eq(g.s.moves_made, 1)
		H.obj_at(g, 1, 1).color = C.COLOR.blue -- the match disappears before the swap ends
		for _ = 1, 11 do g:step() end
		assert_eq(g.s.moves_made, 0, "the refund gives the move back")
		g:input({ type = "booster", booster = "stick", at = { 2, 2 } })
		assert_eq(g.s.moves_made, 0, "boosters are no moves")
	end)

	it("delivers the microphones that stand idle on an exit, by index, in the tick they settle", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "Mbyrgb", "_rggbg" }, mic_level({ total = 3, on_board_max = 3, gap_moves = 99 }))
		g.s.released, g.s.on_board, g.s.last_mic = 1, 1, 0 -- the gap keeps the spawns free of microphones
		local mic = H.obj_at(g, 1, 5)
		assert_true(g.s.exit[31] and not g.s.exit[25])
		-- the mic falls from (1,5) into the exit (1,6): delivered only once it has landed
		for t = 1, 6 do
			g:step()
			assert_eq(mic.state, C.S_FALL, "tick " .. t)
			assert_eq(#H.of_type(g:drain_events(), "mic_delivered"), 0)
		end
		g:step()
		local ev = g:drain_events()
		local at = {}
		for k, e in ipairs(ev) do at[e.type] = k end
		assert_true(at.land < at.mic_delivered and at.mic_delivered < at.goal, "land, mic_delivered, goal")
		assert_eq(mic.state, C.S_CLEAR)
		assert_eq(g.s.on_board, 0)
	end)

	it("two microphones on exits go out in index order in one tick", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "MrgbgM" }, mic_level({ total = 3, on_board_max = 3, gap_moves = 0 }))
		g.s.released, g.s.on_board = 2, 2
		g:step()
		local ev = H.of_type(g:drain_events(), "mic_delivered")
		assert_same({ ev[1].x, ev[2].x }, { 1, 6 })
		assert_eq(g.s.goal_left[1], 1)
	end)
end)

describe("core gravity: diagonal details (10.1)", function()
	it("the faller below must be strictly higher than the cell: equal centres still slide", function()
		-- c = (2,3) under the box (2,2); a faller in (2,4) whose centre sits exactly on c
		local rows = { "byrgby", "yXgbyr", "r_byrg", "gbyrgb", "byrgby", "yrggbg" }
		local g = fresh(rows)
		local below = H.obj_at(g, 2, 4)
		below.state, below.offy, below.vy, below.delay = C.S_FALL, 3600, 300, 3
		local right = H.obj_at(g, 3, 2)
		assign(g)
		assert_eq(H.obj_at(g, 2, 3), right, "vis_y = y_c * 3600: not higher, so the slide goes ahead")
		local g2 = fresh(rows)
		local b2 = H.obj_at(g2, 2, 4)
		b2.state, b2.offy, b2.vy, b2.delay = C.S_FALL, 3601, 300, 3
		assign(g2)
		assert_eq(H.obj_at(g2, 2, 3), nil, "one unit higher: wait")
	end)

	it("a pinned piece is no donor", function()
		local g = fresh({ "byrgby", "yXgbyr", "r_byrg", "gbyrgb", "byrgby", "yrggbg" })
		H.obj_at(g, 3, 2).pins = { 9 } -- the right donor, first in tick 1
		local left = H.obj_at(g, 1, 2)
		assign(g)
		assert_eq(H.obj_at(g, 2, 3), left, "the left donor takes over")
		local g2 = fresh({ "byrgby", "yXgbyr", "r_byrg", "gbyrgb", "byrgby", "yrggbg" })
		H.obj_at(g2, 3, 2).pins = { 9 }
		H.obj_at(g2, 1, 2).pins = { 9 }
		assign(g2)
		assert_eq(H.obj_at(g2, 2, 3), nil, "no donor: a hole")
	end)

	it("a piece with wires is no donor", function()
		local g = fresh({ "byrgby", "yXgbyr", "r_byrg", "gbyrgb", "byrgby", "yrggbg" })
		g.s.wires[9] = 1 -- (3,2)
		local left = H.obj_at(g, 1, 2)
		assign(g)
		assert_eq(H.obj_at(g, 2, 3), left)
	end)

	it("a donor above a void is supported: the cell under it does not exist", function()
		local lvl = H.load({ "######", "######", "##.###", "######", "######", "######" })
		local g = core.new(lvl, { seed = 1 })
		H.board(g, { "byrgby", "XXrbyr", "r_.yrg", "gbyrgb", "byrgby", "yrggbg" })
		local donor = H.obj_at(g, 3, 2)
		assign(g)
		assert_eq(H.obj_at(g, 2, 3), donor)
	end)
end)
