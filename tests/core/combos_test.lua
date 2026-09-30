-- Combos (8.5): geometry and exact ticks of all ten, "Colour X" transforms
-- and fires, the Grand finale hitting all layers.
--
-- H.rows(6, 6) boards:  y odd: b r y g b r    y even: y g b r y g
-- H.arm launches between ticks, so t0 = 1 unless a real swap is used.

local C = require("core.const")
local H = require("tests.core.helper")

local FULL = H.full(6, 6)
local EMPTY = { "______", "______", "______", "______", "______", "______" }

local function R(d) return math.floor((15 * d + 6) / 7) end

local function types(ev)
	local out = {}
	for _, e in ipairs(ev) do out[#out + 1] = e.type end
	return out
end

-- Expected hit list {due, x, y} sorted by due, then index.
local function sorted_hits(list)
	table.sort(list, function(a, b)
		if a[1] ~= b[1] then return a[1] < b[1] end
		if a[3] ~= b[3] then return a[3] < b[3] end
		return a[2] < b[2]
	end)
	return list
end

local function combo_game(marks, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, H.rows(6, 6, marks))
	return g
end

describe("core combos: Cross, Triple cross, Bass drop (8.5)", function()
	it("Cross by a real swap: t0 = swap end, label (a, 1), both axes at t0 + R(d)", function()
		local g = combo_game({ ["3,3"] = "R", ["4,3"] = "V" })
		local R_, V_ = H.obj_at(g, 3, 3), H.obj_at(g, 4, 3)
		assert_true(g:input({ type = "swap", from = { 4, 3 }, to = { 3, 3 } }))
		H.steps(g, 10)
		g:step() -- tick 11: exchange in step 2, activation in step 3
		local ev = g:drain_events()
		assert_same(ev[1], { t = 11, type = "activate", id = V_.id, x = 3, y = 3, special = "riff", axis = "v",
			combo = "cross", partner = R_.id })
		local dirs = {}
		for _, e in ipairs(H.of_type(ev, "bolt")) do dirs[#dirs + 1] = e.dir .. e.at end
		assert_same(dirs, { "l11", "r11", "u11", "d11" })
		local cl = H.of_type(ev, "clear")
		assert_same({ cl[1].id, cl[1].cause, cl[2].id, cl[2].cause }, { V_.id, "fired", R_.id, "fired" },
			"the first centre hit removes both, `to` first")
		assert_eq(g.s.vac_mv[H.idx(g, 4, 3)], 1)
		local src = g.s.sources[H.sources(g)[1]]
		assert_same({ src.mv, src.wv, src.own, src.centre }, { 1, 1, {}, H.idx(g, 3, 3) })
		assert_same(H.hits(g), {
			{ 14, 3, 2 }, { 14, 2, 3 }, { 14, 4, 3 }, { 14, 3, 4 },
			{ 16, 3, 1 }, { 16, 1, 3 }, { 16, 5, 3 }, { 16, 3, 5 },
			{ 18, 6, 3 }, { 18, 3, 6 } })
		assert_same(H.obj_at(g, 3, 6).pins, { src.id }, "path pinned")
		assert_same(H.obj_at(g, 2, 2).pins, {}, "off the path")
	end)

	it("Triple cross: three rows and three columns from their exit points after the swell", function()
		local g = combo_game({ ["3,3"] = "R", ["4,3"] = "S" })
		H.arm(g, { 3, 3 }, { 4, 3 })
		g:step()
		local ev = g:drain_events()
		assert_eq(ev[1].combo, "triple_cross")
		local b = {}
		for _, e in ipairs(H.of_type(ev, "bolt")) do b[#b + 1] = e.x .. e.y .. e.dir .. e.at end
		assert_same(b, { "32l7", "32r7", "33l7", "33r7", "34l7", "34r7", "23u7", "23d7", "33u7", "33d7", "43u7", "43d7" })
		assert_eq(#H.of_type(ev, "clear"), 0, "both stay armed during the swell")
		local want = {}
		for y = 1, 6 do
			for x = 1, 6 do
				local best
				if math.abs(y - 3) <= 1 then best = 7 + R(math.abs(x - 3)) end
				if math.abs(x - 3) <= 1 then
					local t = 7 + R(math.abs(y - 3))
					if not best or t < best then best = t end
				end
				if best then want[#want + 1] = { best, x, y } end
			end
		end
		assert_same(H.hits(g), sorted_hits(want))
		H.steps(g, 5)
		g:step() -- tick 7: the exit points by index; the centre removes both
		local cl = {}
		for _, e in ipairs(H.of_type(g:drain_events(), "clear")) do cl[#cl + 1] = e.x .. e.y .. e.cause end
		assert_same(cl, { "32effect", "23effect", "33fired", "43fired", "34effect" })
	end)

	it("Triple cross on the edge: rows outside the field have no bolt", function()
		local g = combo_game({ ["1,1"] = "R", ["2,1"] = "S" })
		H.arm(g, { 1, 1 }, { 2, 1 })
		g:step()
		local b = {}
		for _, e in ipairs(H.of_type(g:drain_events(), "bolt")) do b[#b + 1] = e.x .. e.y .. e.dir end
		assert_same(b, { "11l", "11r", "12l", "12r", "11u", "11d", "21u", "21d" })
	end)

	it("Bass drop: rings 0..3 (7x7) at t0 + 6 + 2r", function()
		local g = combo_game({ ["3,3"] = "S", ["4,3"] = "S" })
		H.arm(g, { 3, 3 }, { 4, 3 })
		g:step()
		local ev = g:drain_events()
		assert_eq(ev[1].combo, "bass_drop")
		local rings = {}
		for _, e in ipairs(H.of_type(ev, "ring")) do rings[#rings + 1] = e.r .. ":" .. e.at end
		assert_same(rings, { "0:7", "1:9", "2:11", "3:13" })
		local want = {}
		for y = 1, 6 do
			for x = 1, 6 do
				want[#want + 1] = { 7 + 2 * math.max(math.abs(x - 3), math.abs(y - 3)), x, y }
			end
		end
		assert_same(H.hits(g), sorted_hits(want))
	end)
end)

describe("core combos: the Bird with cargo and the Trio (8.5)", function()
	it("bird+riff: cross in the centre at t0 removes both, then the flight with a Riff", function()
		local g = combo_game({ ["3,3"] = "R", ["4,3"] = "B" })
		local r, b = H.obj_at(g, 3, 3), H.obj_at(g, 4, 3)
		H.arm(g, { 4, 3 }, { 3, 3 })
		g:step()
		local ev = g:drain_events()
		assert_same(ev[1], { t = 1, type = "activate", id = b.id, x = 4, y = 3, special = "bird", combo = "bird_riff", partner = r.id })
		local cl = {}
		for _, e in ipairs(H.of_type(ev, "clear")) do cl[#cl + 1] = e.x .. e.y .. e.cause end
		-- the cross by index: (4,2), (3,3) = from (armed: an open slot), (4,3) = centre, (5,3), (4,4)
		assert_same(cl, { "42effect", "43fired", "33fired", "53effect", "44effect" })
		local fly = H.of_type(ev, "bird_fly")
		assert_eq(#fly, 1)
		assert_eq(fly[1].carry, "riff")
		assert_true(fly[1].axis == "h" or fly[1].axis == "v")
	end)
end)

describe("core combos: Grand finale (8.5)", function()
	local function finale_game()
		local g = H.game(FULL, {
			goals = { { type = "light" } },
			slots = { { at = { 3, 3 }, type = "column", hp = 6 } },
			floor = { { at = { 0, 0 }, hp = 1 }, { at = { 3, 3 }, hp = 1 }, { at = { 4, 3 }, hp = 1 },
				{ at = { 3, 4 }, hp = 1 }, { at = { 4, 4 }, hp = 1 } },
			overlay = { { at = { 0, 0 }, type = "wires", hp = 1 } } })
		H.board(g, H.rows(6, 6, { ["2,2"] = "D", ["3,2"] = "D", ["4,4"] = "L", ["5,4"] = "l", ["4,5"] = "l", ["5,5"] = "l" }))
		return g
	end

	it("pause, then every cell by ring; rings 0..the last ring with a cell; the whole board pinned", function()
		local g = finale_game()
		H.arm(g, { 2, 2 }, { 3, 2 })
		g:step()
		local ev = g:drain_events()
		assert_eq(ev[1].combo, "finale")
		local rings = {}
		for _, e in ipairs(H.of_type(ev, "ring")) do rings[#rings + 1] = e.r .. ":" .. e.at end
		assert_same(rings, { "0:25", "1:27", "2:29", "3:31", "4:33" })
		local src = g.s.sources[H.sources(g)[1]]
		assert_true(src.all_layers)
		local want = {}
		for y = 1, 6 do
			for x = 1, 6 do
				want[#want + 1] = { 25 + 2 * math.max(math.abs(x - 2), math.abs(y - 2)), x, y }
			end
		end
		assert_same(H.hits(g), sorted_hits(want), "one hit per cell, the column's four cells included")
		local pinned, free = 0, 0
		for _, o in ipairs(require("core.board").objects(g.s)) do
			if o.kind == C.K_REGULAR and g.s.wires[o.cell] == 0 then
				if o.pins[1] then pinned = pinned + 1 else free = free + 1 end
			end
		end
		assert_same({ pinned, free }, { 29, 0 })
		assert_same(H.obj_at(g, 1, 1).pins, {}, "a piece under wires is not movable")
	end)

	it("hits wires, slot and floor in one hit; the column once, each of its floors by its own hit", function()
		local g = finale_game()
		H.arm(g, { 2, 2 }, { 3, 2 })
		H.steps(g, 26)
		g:step() -- tick 27: ring 1, (1,1) first
		local ev = g:drain_events()
		local first = {}
		for k = 1, 7 do first[k] = ev[k].type .. (ev[k].layer or "") end
		assert_same(first, { "hitwires", "freed", "clear", "hitfloor", "floor_lit", "score", "goal" })
		assert_eq(ev[6].delta, 130, "wires 50 + piece 30 + floor 50")
		g:step()
		g:step() -- tick 29: (4,4), the column's top-left cell
		ev = g:drain_events()
		local col = {}
		for _, e in ipairs(ev) do
			if e.type == "hit" and e.x >= 4 and e.x <= 5 and e.y >= 4 and e.y <= 5 then col[#col + 1] = e.layer .. e.x .. e.y end
		end
		assert_same(col, { "blocker44", "floor44" })
		assert_eq(H.obj_at(g, 4, 4).hp, 5)
		g:step()
		g:step() -- tick 31: the other three cells: floors only
		ev = g:drain_events()
		col = {}
		for _, e in ipairs(ev) do
			if e.type == "hit" and e.x >= 4 and e.x <= 5 and e.y >= 4 and e.y <= 5 then col[#col + 1] = e.layer .. e.x .. e.y end
		end
		assert_same(col, { "floor54", "floor45", "floor55" })
		assert_eq(H.obj_at(g, 4, 4).hp, 5, "one hit per source on the column")
		assert_same(g.s.goal_left, { 0 })
		assert_eq(g.s.state, C.G_WON_WAIT)
	end)

	it("the first centre hit (after the pause) removes both balls", function()
		local g = finale_game()
		H.arm(g, { 2, 2 }, { 3, 2 })
		H.steps(g, 24)
		assert_eq(H.obj_at(g, 2, 2).state, C.S_ARMED)
		g:step() -- tick 25
		local cl = H.of_type(g:drain_events(), "clear")
		assert_same({ cl[1].x, cl[1].cause, cl[2].x, cl[2].cause }, { 2, "fired", 3, "fired" })
	end)
end)

describe("core combos: Colour X -> specials (8.5)", function()
	-- reds of the pattern by (Chebyshev distance from (3,3), index)
	local L = { { 4, 2 }, { 2, 3 }, { 4, 4 }, { 2, 1 }, { 2, 5 }, { 6, 1 }, { 6, 3 }, { 6, 5 }, { 4, 6 } }

	local function colour_game(partner)
		local g = combo_game({ ["3,3"] = "D", ["4,3"] = partner })
		H.arm(g, { 3, 3 }, { 4, 3 })
		return g
	end

	it("colour_riff: X = mf(no wires), L pinned, transforms by k, to/from at t_end, fires after t_last", function()
		local g = colour_game("R")
		local ids = {}
		for k = 1, 9 do ids[k] = H.obj_at(g, L[k][1], L[k][2]).id end
		local disco, riff = H.obj_at(g, 3, 3), H.obj_at(g, 4, 3)
		g:step() -- t0 = 1
		local ev = g:drain_events()
		assert_same(ev[1], { t = 1, type = "activate", id = disco.id, x = 3, y = 3, special = "disco",
			combo = "color_riff", partner = riff.id, color = "red" })
		assert_same(types(ev), { "activate", "transform", "score", "goal" })
		assert_same(ev[2], { t = 1, type = "transform", id = ids[1], x = 4, y = 2, special = "riff", axis = "h" })
		assert_same({ ev[3].delta, ev[3].x, ev[3].y, ev[4].left }, { 30, 4, 2, 998 })
		local sid = H.sources(g)[1]
		local want = {}
		for k = 1, 8 do want[#want + 1] = { 1 + 2 * k, C.R_TRANSFORM, sid, k, ids[k + 1] } end
		want[#want + 1] = { 19, C.R_HIT, sid, H.idx(g, 3, 3) }
		want[#want + 1] = { 19, C.R_HIT, sid, H.idx(g, 4, 3) }
		for k = 0, 8 do
			want[#want + 1] = { 17 + 3 * (k + 1), C.R_ACTIVATE, ids[k + 1], H.idx(g, L[k + 1][1], L[k + 1][2]), 0, 1, 1, 0 }
		end
		assert_same(H.queue(g), want)
		for k = 2, 9 do assert_same(H.obj_at(g, L[k][1], L[k][2]).pins, { sid }) end
		-- the transforms: axis h for even k, v for odd k
		local axes = {}
		for _, e in ipairs(H.of_type(H.steps(g, 16), "transform")) do axes[#axes + 1] = e.t .. e.axis end
		assert_same(axes, { "3v", "5h", "7v", "9h", "11v", "13h", "15v", "17h" })
		assert_eq(H.obj_at(g, 3, 3).state, C.S_ARMED)
		g:step()
		g:step() -- tick 19: both removed
		local cl = H.of_type(g:drain_events(), "clear")
		assert_same({ cl[1].id, cl[2].id, cl[1].cause }, { disco.id, riff.id, "fired" })
		-- fires by k: each transformed Riff activates once, on its own tick, with the combo's label
		local acts = {}
		for _, e in ipairs(H.of_type(H.steps(g, 25), "activate")) do acts[#acts + 1] = { e.t, e.id } end
		local wa = {}
		for k = 0, 8 do wa[#wa + 1] = { 20 + 3 * k, ids[k + 1] } end
		assert_same(acts, wa, "armed transformed specials are not launched by chains")
	end)

	it("colour_sub and colour_bird transform into the partner's kind, without axis", function()
		for _, spec in ipairs({ { "S", "sub", "color_sub" }, { "B", "bird", "color_bird" } }) do
			local g = colour_game(spec[1])
			g:step()
			local ev = g:drain_events()
			assert_eq(ev[1].combo, spec[3])
			assert_same(ev[2], { t = 1, type = "transform", id = H.obj_at(g, 4, 2).id, x = 4, y = 2, special = spec[2] })
			local o = H.obj_at(g, 4, 2)
			assert_same({ o.kind, o.special, o.axis, o.state, o.color }, { C.K_SPECIAL, C.SPECIAL[spec[2]], 0, C.S_ARMED, 0 })
			g:run_to_rest()
			assert_same(H.sources(g), {})
		end
	end)

	it("a transform whose piece is no longer pinned is skipped; its slot and its fire stay", function()
		local g = combo_game({ ["3,3"] = "D", ["4,3"] = "R", ["1,1"] = "B" })
		local gone = H.obj_at(g, 2, 1).id -- L[3] (k = 3), transform at tick 7
		H.arm(g, { 3, 3 }, { 4, 3 })
		g:step()
		g:drain_events()
		assert_true(g:input({ type = "tap", at = { 1, 1 } }))
		g:step() -- tick 2: the Bird's cross destroys (2,1)
		assert_eq(H.obj_at(g, 2, 1).state, C.S_CLEAR)
		local ev = H.steps(g, 17) -- to tick 19
		local tr = {}
		for _, e in ipairs(H.of_type(ev, "transform")) do tr[#tr + 1] = e.t end
		assert_same(tr, { 3, 5, 9, 11, 13, 15, 17 }, "no transform at tick 7, the others keep their ticks")
		for _, r in ipairs(g.s.queue) do
			if r.kind == C.R_ACTIVATE and r.d[1] == gone then assert_eq(r.due, 17 + 3 * 4) end
		end
		ev = H.steps(g, 12) -- to tick 31
		for _, e in ipairs(H.of_type(ev, "activate")) do assert_true(e.id ~= gone) end
	end)

	it("no colour X: L is empty, `to` and `from` are hit at t0", function()
		local g = H.game(FULL)
		H.board(g, { "______", "______", "__DS__", "______", "______", "______" })
		H.arm(g, { 3, 3 }, { 4, 3 })
		g:step()
		local ev = g:drain_events()
		assert_same(ev[1], { t = 1, type = "activate", id = 1, x = 3, y = 3, special = "disco", combo = "color_sub", partner = 2 })
		local ty = {}
		for _, e in ipairs(ev) do
			if e.type ~= "spawn" then ty[#ty + 1] = e.type end
		end
		assert_same(ty, { "activate", "clear", "clear" })
		assert_same(H.queue(g), {})
		assert_same(H.sources(g), {})
	end)
end)

describe("core combos: every pair", function()
	local LET = { "R", "S", "B", "D" }
	local NAME = {
		RR = "cross", RS = "triple_cross", BR = "bird_riff", DR = "color_riff", SS = "bass_drop",
		BS = "bird_sub", DS = "color_sub", BB = "trio", BD = "color_bird", DD = "finale",
	}
	for a = 1, 4 do
		for b = 1, 4 do
			local key = LET[a] < LET[b] and LET[a] .. LET[b] or LET[b] .. LET[a]
			it(LET[a] .. "+" .. LET[b] .. " (" .. NAME[key] .. "): turbo runs inside the activation; normal ends clean", function()
				for _, timing in ipairs({ "turbo", "normal" }) do
					local g = combo_game({ ["3,3"] = LET[a], ["4,3"] = LET[b] }, nil, { timing = timing })
					assert_true(g:input({ type = "swap", from = { 4, 3 }, to = { 3, 3 } }))
					local t_end = timing == "turbo" and 2 or 11 -- the swap ends at now + T.swap
					local ev = H.steps(g, t_end)
					local act = H.of_type(ev, "activate")[1]
					assert_eq(act.combo, NAME[key])
					assert_eq(act.special, C.SPECIAL_NAME[b], "the special now in `to`")
					if timing == "turbo" then
						assert_same(H.queue(g), {}, "chains too run in the same step 3")
						assert_same(H.sources(g), {})
					end
					g:run_to_rest()
					assert_same(H.sources(g), {})
					for _, o in ipairs(require("core.board").objects(g.s)) do assert_same(o.pins, {}) end
				end
			end)
		end
	end
end)

describe("core combos: determinism with effects in flight", function()
	it("a clone taken mid-effect continues identically (reservations, pins, records are plain data)", function()
		-- the picture is the level itself (every cell preset), so the replay rebuilds it
		local g = H.game(H.rows(6, 6, { ["3,3"] = "B", ["4,3"] = "B", ["1,6"] = "D", ["2,6"] = "R" }))
		g:input({ type = "swap", from = { 4, 3 }, to = { 3, 3 } })
		g:input({ type = "swap", from = { 2, 6 }, to = { 1, 6 } })
		H.steps(g, 14) -- Trio flying, Colour X transforming
		local sid = H.sources(g)
		assert_true(#sid >= 2)
		local c = g:clone()
		assert_eq(c:hash(), g:hash())
		for _ = 1, 60 do
			g:step()
			c:step()
			assert_eq(c:hash(), g:hash())
		end
		g:run_to_rest()
		local _, ok, why = require("core.game").playback(g.s.level, g:replay())
		assert_true(ok, why)
	end)

	it("switching to turbo mid-effect keeps the order and finishes clean", function()
		for _, pair in ipairs({ { "D", "B" }, { "B", "S" }, { "D", "D" }, { "R", "S" } }) do
			local g = combo_game({ ["3,3"] = pair[1], ["4,3"] = pair[2] })
			g:input({ type = "swap", from = { 4, 3 }, to = { 3, 3 } })
			H.steps(g, 16)
			local c = g:clone()
			c:set_timing("turbo")
			c:run_to_rest()
			assert_same(H.sources(c), {})
			for _, o in ipairs(require("core.board").objects(c.s)) do assert_same(o.pins, {}) end
		end
	end)
end)
