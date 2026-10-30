local level_anim = require("client.level_anim")
local geom = require("client.level_geom")
local level_session = require("client.level_session")

-- 6x6 board with 100 px cells: cell (x, y) centre = (x*100 - 50 + 18, 624 - 12 - (y*100 - 50))
local function G()
	local cells = {}
	for i = 1, 36 do cells[i] = { exists = true } end
	return geom.new(6, 6, cells, { x0 = 0, y0 = 0, x1 = 636, y1 = 624 })
end

local function piece(id, x, y, extra)
	local p = { id = id, x = x, y = y, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0,
		hidden = false, pinned = false }
	for k, v in pairs(extra or {}) do p[k] = v end
	return p
end

local function find(list, id)
	for _, e in ipairs(list) do
		if e.id == id then return e end
	end
end

describe("client.level_anim", function()
	it("names the atlas image of every kind of object", function()
		assert_eq(level_anim.image({ kind = "regular", color = "blue" }), "pieces_blue")
		assert_eq(level_anim.image({ kind = "special", special = "disco" }), "specials_disco")
		assert_eq(level_anim.image({ kind = "mic" }), "blockers_mic")
		assert_eq(level_anim.image({ kind = "blocker", item = "record_box", hp = 3 }), "blockers_record_box_3")
		assert_eq(level_anim.image({ kind = "blocker", item = "record_box", hp = 7 }), "blockers_record_box_3")
		assert_eq(level_anim.image({ kind = "blocker", item = "concrete", hp = 1 }), "blockers_concrete_1")
		assert_eq(level_anim.image({ kind = "blocker", item = "balloon", color = "green", hp = 1 }), "blockers_balloon_green")
		assert_eq(level_anim.image({ kind = "blocker", item = "noise", hp = 1 }), "blockers_noise")
		-- a column goes 3 -> 2 -> 1 as it is hit, and lights up when it breaks
		assert_eq(level_anim.image({ kind = "blocker", item = "column", hp = 9 }, 9), "blockers_column_3")
		assert_eq(level_anim.image({ kind = "blocker", item = "column", hp = 5 }, 9), "blockers_column_2")
		assert_eq(level_anim.image({ kind = "blocker", item = "column", hp = 2 }, 9), "blockers_column_1")
		assert_eq(level_anim.image({ kind = "blocker", item = "column", hp = 0, state = "clear" }, 9), "blockers_column_on")
	end)

	it("draws pieces at their cells with the core lag, riffs v rotated, columns over 2x2", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local list = A:frame({
			piece(1, 2, 3),
			piece(2, 4, 2, { state = "fall", offy = 1800 }),
			piece(3, 1, 1, { kind = "special", special = "riff", axis = "v", color = nil }),
			piece(4, 5, 5, { kind = "blocker", item = "column", hp = 8, color = nil }),
		}, 10, 1.0)
		assert_eq(#list, 4)
		local cx, cy = g:center(2, 3)
		assert_near(find(list, 1).x, cx, 1e-9)
		assert_near(find(list, 1).y, cy, 1e-9)
		assert_near(find(list, 1).scale, 100 / 160, 1e-9)
		local fx, fy = g:center(4, 2)
		assert_near(find(list, 2).y, fy + 50, 1e-9) -- half a cell of lag
		assert_near(find(list, 2).x, fx, 1e-9)
		assert_eq(find(list, 3).rot, 90)
		local kx, ky = g:center(5, 5)
		assert_near(find(list, 4).x, kx + 50, 1e-9)
		assert_near(find(list, 4).y, ky - 50, 1e-9)
		assert_eq(find(list, 4).image, "blockers_column_3")
		assert_true(find(list, 3).z > find(list, 4).z) -- specials over blockers
	end)

	it("hides pieces above their spawner and clips the ones entering", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local list = A:frame({
			piece(1, 3, 1, { state = "fall", offy = 7200, hidden = true }),
			piece(2, 3, 2, { state = "fall", offy = 5400 }),
			piece(3, 4, 4, { state = "fall", offy = 100 }),
		}, 5, 0)
		assert_eq(find(list, 1).alpha, 0)
		assert_eq(find(list, 2).alpha, 1)
		assert_near(find(list, 2).clip, g:clip_top(3, 2), 1e-9)
		assert_eq(find(list, 3).clip, nil) -- well inside the board
	end)

	it("does not cut a piece that slides in diagonally from a column that reaches higher than its target's", function()
		-- 6x6; columns 3 and 4 start at row 3 and row 2 (the cells above are gaps), the others at row 1
		local cells = {}
		for i = 1, 36 do cells[i] = { exists = true } end
		for y = 1, 2 do cells[(y - 1) * 6 + 3] = { exists = false } end
		cells[4] = { exists = false } -- (4, 1)
		local g = geom.new(6, 6, cells, { x0 = 0, y0 = 0, x1 = 636, y1 = 624 })
		local A = level_anim.new({ geom = g })
		local list = A:frame({
			-- from (2, 2) on the left into (3, 3), the top of its run: the donor's column reaches up to row 1
			piece(1, 3, 3, { state = "fall", offx = 3240, offy = 3240 }),
			-- the same from the right, still half a cell above its donor (4, 2), the top of its run: the target's
			-- run starts a row lower
			piece(2, 3, 3, { state = "fall", offx = -3600, offy = 5400 }),
			-- a straight fall into the top of the run still comes from beyond it: cut there
			piece(3, 3, 3, { state = "fall", offy = 3240 }),
		}, 5, 0)
		assert_eq(find(list, 1).clip, nil, "a piece from a cell inside the board is seen whole")
		assert_near(find(list, 2).clip, g:clip_top(4, 2), 1e-9) -- cut at the line of its donor's run, not the lower one
		assert_true(find(list, 2).clip > g:clip_top(3, 3))
		assert_near(find(list, 3).clip, g:clip_top(3, 3), 1e-9)
	end)

	it("moves swapped pieces over T.swap, the dragged one on top, and a failed swap comes back", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		A:event({ type = "swap", t = 100, a = { 2, 2 }, b = { 3, 2 }, ids = { 7, 8 }, duration = 10 }, 0)
		local ps = { piece(7, 2, 2, { state = "swap" }), piece(8, 3, 2, { state = "swap" }) }
		local ax, ay = g:center(2, 2)
		local bx = g:center(3, 2)
		local l0 = A:frame(ps, 100, 0)
		assert_near(find(l0, 7).x, ax, 1e-9)
		local l5 = A:frame(ps, 105, 0)
		assert_near(find(l5, 7).x, (ax + bx) / 2, 1e-9)
		assert_near(find(l5, 8).x, (ax + bx) / 2, 1e-9)
		assert_true(find(l5, 7).z > find(l5, 8).z)
		assert_near(find(l5, 7).y, ay, 1e-9)
		local l10 = A:frame(ps, 110, 0)
		assert_near(find(l10, 7).x, bx, 1e-9)
		-- failed swap: out (with an overshoot past FAIL_REACH) and back
		A:event({ type = "swap_fail", t = 200, a = { 2, 2 }, b = { 3, 2 }, ids = { 7, 8 }, duration = 14 }, 0)
		local best = 0
		for k = 0, 14 do
			local e = find(A:frame(ps, 200 + k, 0), 7)
			best = math.max(best, (e.x - ax) / 100)
		end
		assert_true(best > level_anim.FAIL_REACH)
		assert_true(best < level_anim.FAIL_REACH * 1.2)
		assert_near(find(A:frame(ps, 214, 0), 7).x, ax, 1e-6)
		assert_near(level_anim.fail_offset(1), 0, 1e-9)
	end)

	it("pops a cleared piece (x1.15 in 3 ticks) and shrinks it to 0 by the end of T.clear", function()
		assert_near(level_anim.clear_scale(0), 1, 1e-9)
		assert_near(level_anim.clear_scale(3), 1.15, 1e-9)
		assert_near(level_anim.clear_scale(9), 0, 1e-9)
		local A = level_anim.new({ geom = G() })
		A:event({ type = "clear", t = 50, id = 4, x = 2, y = 2, kind = "regular", color = "red", cause = "match" }, 0)
		local ps = { piece(4, 2, 2, { state = "clear" }) }
		assert_near(find(A:frame(ps, 53, 0), 4).sx, 1.15, 1e-9)
		assert_true(find(A:frame(ps, 56, 0), 4).sx < 1)
	end)

	it("flies the pieces of a group into the cell of its new special, which grows 0 -> 1.2 -> 1", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		A:event({ type = "match", t = 30, cells = { { 1, 3 }, { 2, 3 }, { 3, 3 }, { 4, 3 } }, color = "red", wave = 1, act = 1,
			special = "riff" }, 1.0)
		for id = 1, 3 do
			A:event({ type = "clear", t = 30, id = id, x = id, y = 3, kind = "regular", color = "red", cause = "match" }, 1.0)
		end
		A:event({ type = "clear", t = 30, id = 4, x = 4, y = 3, kind = "regular", color = "red", cause = "match" }, 1.0)
		A:event({ type = "special_new", t = 30, id = 9, x = 4, y = 3, special = "riff", axis = "h" }, 1.0)
		assert_same(A:record(1).clear.gather, { 4, 3 })
		local ps = { piece(1, 1, 3, { state = "clear" }), piece(9, 4, 3, { kind = "special", special = "riff", axis = "h" }) }
		local tx = g:center(4, 3)
		local x0 = g:center(1, 3)
		local e = find(A:frame(ps, 39, 1.0), 1)
		assert_near(e.x, tx, 1e-9) -- arrived by the end of T.clear
		local mid = find(A:frame(ps, 34.5, 1.0), 1)
		assert_true(mid.x > x0 and mid.x < tx)
		-- the special: 0 at birth, over 1 half way, 1 at the end, flashing white first
		assert_near(level_anim.appear_scale(0), 0, 1e-9)
		assert_near(level_anim.appear_scale(level_anim.APPEAR_TIME * 0.55), level_anim.APPEAR_PEAK, 1e-9)
		assert_near(level_anim.appear_scale(level_anim.APPEAR_TIME), 1, 1e-9)
		-- it blooms when the pieces arrive (APPEAR_DELAY after the event), not before
		assert_eq(find(A:frame(ps, 30, 1.0 + level_anim.APPEAR_DELAY / 2), 9).sx, 0)
		local s = find(A:frame(ps, 31, 1.0 + level_anim.APPEAR_DELAY + 0.05), 9)
		assert_true(s.sx > 0 and s.sx < 1.2)
		assert_true(s.flash > 0.5)
		assert_near(find(A:frame(ps, 60, 2.0), 9).sx, 1, 1e-9)
	end)

	it("squashes a landed piece 0.88 / 1.08 and springs back", function()
		local A = level_anim.new({ geom = G() })
		A:event({ type = "land", t = 5, id = 3, x = 2, y = 5 }, 10.0)
		local ps = { piece(3, 2, 5) }
		local e = find(A:frame(ps, 5, 10.0), 3)
		assert_near(e.sy, level_anim.SQUASH_Y, 1e-9)
		assert_near(e.sx, level_anim.SQUASH_X, 1e-9)
		e = find(A:frame(ps, 30, 10.0 + level_anim.SQUASH_TIME + 0.01), 3)
		assert_eq(e.sx, 1)
		assert_eq(e.sy, 1)
		-- reduced motion: no squash
		local R = level_anim.new({ geom = G(), reduced = true })
		R:event({ type = "land", t = 5, id = 3, x = 2, y = 5 }, 10.0)
		assert_eq(find(R:frame(ps, 5, 10.0), 3).sy, 1)
	end)

	it("grows a touched piece to x1.08 in 0.08 s and keeps the selected one big", function()
		local A = level_anim.new({ geom = G() })
		local ps = { piece(1, 1, 1), piece(2, 2, 1) }
		A:touch(1, 5.0)
		assert_near(find(A:frame(ps, 1, 5.08), 1).sx, 1.08, 1e-9)
		assert_near(find(A:frame(ps, 1, 5.5), 1).sx, 1, 1e-9)
		A:select(2)
		assert_true(find(A:frame(ps, 1, 6), 2).sx >= 1.06)
		assert_true(find(A:frame(ps, 1, 6), 2).z > find(A:frame(ps, 1, 6), 1).z)
	end)

	it("wobbles the hint pair towards each other", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local ps = { piece(1, 2, 2), piece(2, 2, 3), piece(3, 5, 5) }
		A:hint({ 2, 2 }, { 2, 3 }, 0.25)
		local l = A:frame(ps, 1, 0)
		local _, y1 = g:center(2, 2)
		local _, y2 = g:center(2, 3)
		assert_true(find(l, 1).y < y1) -- moves down towards (2, 3)
		assert_true(find(l, 2).y > y2)
		local _, y3 = g:center(5, 5)
		assert_near(find(l, 3).y, y3, 1e-9)
	end)

	it("swells an armed Sabwoofer over T.sub_swell and flies shuffled pieces", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		A:event({ type = "activate", t = 40, id = 5, x = 3, y = 3, special = "sub" }, 0)
		local ps = { piece(5, 3, 3, { kind = "special", special = "sub", state = "armed" }) }
		assert_near(find(A:frame(ps, 40, 0), 5).sx, 1, 1e-9)
		assert_near(find(A:frame(ps, 46, 0), 5).sx, level_anim.SWELL_SCALE, 1e-9)
		A:event({ type = "shuffle", t = 70, duration = 30, moves = { { id = 6, fx = 1, fy = 1, x = 4, y = 4 } }, recolors = {} }, 0)
		local sp = { piece(6, 4, 4, { state = "swap" }) }
		local x0, y0 = g:center(1, 1)
		local e = find(A:frame(sp, 70, 0), 6)
		assert_near(e.x, x0, 1e-9)
		assert_near(e.y, y0, 1e-9)
		local x1, y1 = g:center(4, 4)
		e = find(A:frame(sp, 100, 0), 6)
		assert_near(e.x, x1, 1e-6)
		assert_near(e.y, y1, 1e-6)
	end)

	it("forgets pieces that left the board", function()
		local A = level_anim.new({ geom = G() })
		A:frame({ piece(1, 1, 1), piece(2, 2, 2) }, 1, 0)
		A:frame({ piece(2, 2, 2) }, 2, 0)
		A:frame({ piece(2, 2, 2) }, 3, 0)
		assert_eq(A:record(1), nil)
		assert_true(A:record(2) ~= nil)
	end)

	it("follows a real game through every event without errors", function()
		local s = assert(level_session.new({ params = { level = 1 }, read_level = function()
			return [[{
  "id": 1, "version": 1, "size": [7, 8], "moves": 30, "difficulty": "easy",
  "colors": ["red", "yellow", "green", "blue"],
  "goals": [{"type": "collect", "color": "red", "count": 60}],
  "cells": [".#####.", "#######", "#######", "#######", "#######", "#######", "#######", ".#####."],
  "floor": [{"at": [3, 3], "hp": 2}],
  "slots": [{"at": [2, 4], "type": "record_box", "hp": 2}, {"at": [3, 0], "type": "riff", "axis": "v"}]
}]]
		end }))
		local g = geom.new(s.W, s.H, s.game:cells(), { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })
		local A = level_anim.new({ geom = g })
		local frames, drawn = 0, 0
		for move = 1, 12 do
			local cmd = s:hint_command()
			if not cmd then break end
			s:command(cmd)
			for _ = 1, 400 do
				s:advance(1 / 60, function(evs)
					for _, e in ipairs(evs) do A:event(e, frames / 60) end
				end)
				frames = frames + 1
				local list = A:frame(s.game:pieces(), s:display_tick(), frames / 60)
				for _, e in ipairs(list) do
					assert_true(e.x == e.x and e.y == e.y, "position is a number")
					assert_true(e.sx >= 0 and e.sy >= 0)
					drawn = drawn + 1
				end
				if s.game:is_stable() then break end
			end
		end
		assert_true(drawn > 0)
	end)
end)

describe("client.level_anim (finish)", function()
	it("fails a swap the whole way with an 8 % overshoot and comes back in 7 + 7 ticks", function()
		local peak, at_peak = 0, 0
		for i = 0, 100 do
			local v = level_anim.fail_offset(i / 100)
			if v > peak then peak, at_peak = v, i / 100 end
		end
		assert_near(peak, 1.08, 0.005)
		assert_true(at_peak < 0.5) -- it overshoots on the way out, not on the way back
		assert_near(level_anim.fail_offset(0), 0, 1e-9)
		assert_near(level_anim.fail_offset(0.5), 1, 1e-9) -- at the other cell after 7 of 14 ticks
		assert_near(level_anim.fail_offset(1), 0, 1e-9)
		-- continuous at the turn
		assert_near(level_anim.fail_offset(0.4999), level_anim.fail_offset(0.5001), 0.01)
	end)

	it("makes a piece an effect has pinned glow and breathe until it is hit", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local ps = { piece(1, 2, 2, { pinned = true }), piece(2, 3, 2) }
		local lo, hi = 1, 0
		local small, big = 2, 0
		for k = 0, 30 do
			local e = find(A:frame(ps, 1, k / 60), 1)
			lo, hi = math.min(lo, e.flash), math.max(hi, e.flash)
			small, big = math.min(small, e.sx), math.max(big, e.sx)
		end
		assert_true(lo > 0, "always glowing")
		assert_true(hi > lo, "pulsing")
		assert_true(big > 1 and big < 1.06)
		local calm = find(A:frame(ps, 1, 0), 2)
		assert_eq(calm.flash, 0)
		assert_eq(calm.sx, 1)
		-- reduced motion: a steady glow, no breathing
		local R = level_anim.new({ geom = g, reduced = true })
		local e = find(R:frame(ps, 1, 0.3), 1)
		assert_true(e.flash > 0)
		assert_eq(e.sx, 1)
	end)

	it("keeps a destroyed column lit instead of shrinking it, and lets the noise creep in first", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		A:event({ type = "destroy", t = 10, id = 8, x = 2, y = 2, item = "column" }, 0)
		local col = piece(8, 2, 2, { kind = "blocker", item = "column", hp = 0, state = "clear", color = nil })
		for u = 0, 8 do
			local e = find(A:frame({ col }, 10 + u, u / 60), 8)
			assert_eq(e.image, "blockers_column_on")
			assert_eq(e.alpha, 1)
			assert_true(e.sx >= 1, "no shrink at tick " .. u)
		end
		-- a piece turns into noise: the old look stays for NOISE_HOLD, then the grey noise
		local B = level_anim.new({ geom = g })
		local before = piece(5, 4, 4)
		B:frame({ before }, 1, 1.0)
		B:event({ type = "noise_spread", t = 20, fx = 4, fy = 3, x = 4, y = 4, id = 5 }, 1.0)
		local now = piece(5, 4, 4, { kind = "blocker", item = "noise", hp = 1, color = nil })
		assert_eq(find(B:frame({ now }, 20, 1.05), 5).image, "pieces_red")
		assert_eq(find(B:frame({ now }, 30, 1.0 + level_anim.NOISE_HOLD + 0.05), 5).image, "blockers_noise")
	end)

	it("lets a new special bloom after its group has flown in, so it is born hidden", function()
		local A = level_anim.new({ geom = G() })
		A:event({ type = "special_new", t = 40, id = 12, x = 3, y = 3, special = "sub" }, 5.0)
		local ps = { piece(12, 3, 3, { kind = "special", special = "sub", color = nil }) }
		assert_eq(find(A:frame(ps, 40, 5.0), 12).sx, 0)
		assert_true(find(A:frame(ps, 46, 5.0 + level_anim.APPEAR_DELAY + 0.1), 12).sx > 0.5)
	end)

	it("flies the Crossfader's two pieces across the board on arcs to opposite sides, lifted, and pops them on landing", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		A:event({ type = "exchange", t = 100, a = { 1, 1 }, b = { 6, 5 }, ids = { 7, 8 }, duration = 18 }, 5.0)
		local ps = { piece(7, 1, 1, { state = "swap" }), piece(8, 6, 5, { state = "swap" }) }
		local ax, ay = g:center(1, 1)
		local bx, by = g:center(6, 5)
		local l0 = A:frame(ps, 100, 5.0)
		assert_near(find(l0, 7).x, ax, 1e-9)
		assert_near(find(l0, 7).y, ay, 1e-9)
		assert_near(find(l0, 8).x, bx, 1e-9)
		-- half way: both are off the middle of the chord by the arc, the two on opposite sides of it
		local mid = { (ax + bx) / 2, (ay + by) / 2 }
		local l9 = A:frame(ps, 109, 5.0)
		local e7, e8 = find(l9, 7), find(l9, 8)
		local bulge = math.min(math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) * level_anim.EXCHANGE_BULGE, 100 * 2)
		local d7 = math.sqrt((e7.x - mid[1]) ^ 2 + (e7.y - mid[2]) ^ 2)
		local d8 = math.sqrt((e8.x - mid[1]) ^ 2 + (e8.y - mid[2]) ^ 2)
		assert_near(d7, bulge, 1e-6, "off the chord by the arc")
		assert_near(d8, bulge, 1e-6)
		assert_near(e7.x + e8.x, 2 * mid[1], 1e-6, "mirrored through the middle: they pass on opposite sides")
		assert_near(e7.y + e8.y, 2 * mid[2], 1e-6)
		assert_true(e7.sx > 1.1 and e8.sx > 1.1, "lifted")
		assert_eq(e7.z, level_anim.Z.fly)
		assert_eq(e8.z, level_anim.Z.fly, "both above the others")
		-- the end: each in the other's cell, no arc, no lift
		local l18 = A:frame(ps, 118, 5.0)
		assert_near(find(l18, 7).x, bx, 1e-6)
		assert_near(find(l18, 7).y, by, 1e-6)
		assert_near(find(l18, 8).x, ax, 1e-6)
		assert_near(find(l18, 7).sx, 1, 1e-9)
		-- the core has swapped the cells and the pieces are idle: they pop (a 0.3 s pulse that starts at the landing)
		local landed = { piece(7, 6, 5), piece(8, 1, 1) }
		assert_eq(find(A:frame(landed, 119, 5.0 + 0.1), 7).sx, 1, "not yet")
		local pop = find(A:frame(landed, 119, 5.0 + 0.3 + 0.15), 7)
		assert_true(pop.sx > 1.2, "popping at 0.15 s after the landing")
		assert_eq(find(A:frame(landed, 119, 5.0 + 0.3 + 0.4), 7).sx, 1, "and over")
	end)

	it("flies the Crossfader's pieces in a straight line, without lift or pop, under reduced motion", function()
		local g = G()
		local A = level_anim.new({ geom = g, reduced = true })
		A:event({ type = "exchange", t = 100, a = { 1, 1 }, b = { 6, 5 }, ids = { 7, 8 }, duration = 18 }, 5.0)
		local ps = { piece(7, 1, 1, { state = "swap" }), piece(8, 6, 5, { state = "swap" }) }
		local ax, ay = g:center(1, 1)
		local bx, by = g:center(6, 5)
		local e = find(A:frame(ps, 109, 5.0), 7)
		assert_near(e.x, (ax + bx) / 2, 1e-9)
		assert_near(e.y, (ay + by) / 2, 1e-9)
		assert_eq(e.sx, 1)
		local landed = { piece(7, 6, 5), piece(8, 1, 1) }
		assert_eq(find(A:frame(landed, 119, 5.0 + 0.45), 7).sx, 1)
	end)

	it("shakes a piece that cannot be moved sideways for a third of a second, with a blink under reduced motion", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local ps = { piece(3, 3, 3, { kind = "blocker", item = "concrete", hp = 2, color = nil }) }
		local cx = g:center(3, 3)
		assert_near(find(A:frame(ps, 1, 1.0), 3).x, cx, 1e-9)
		A:shake(3, 1.0)
		A:shake(nil, 1.0) -- no piece: nothing
		local moved = false
		for k = 1, 20 do
			local e = find(A:frame(ps, 1, 1.0 + k * 0.015), 3)
			if math.abs(e.x - cx) > 1 then moved = true end
			assert_true(math.abs(e.x - cx) <= 100 * level_anim.SHAKE_AMP + 1e-9, "never farther than the amplitude")
		end
		assert_true(moved, "it shook")
		assert_near(find(A:frame(ps, 1, 1.0 + level_anim.SHAKE_TIME + 0.05), 3).x, cx, 1e-9, "and is still after SHAKE_TIME")
		local R = level_anim.new({ geom = g, reduced = true })
		R:shake(3, 1.0)
		local e = find(R:frame(ps, 1, 1.05), 3)
		assert_near(e.x, cx, 1e-9)
		assert_true(e.flash > 0.1, "a blink instead")
	end)

	it("blooms the board in a wave from the bottom left at the start of a level", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local ps = { piece(1, 1, 6), piece(2, 6, 1) } -- bottom left, top right
		A:intro(ps, 2.0)
		assert_eq(find(A:frame(ps, 1, 2.0), 1).sx, 0) -- nothing yet
		assert_eq(find(A:frame(ps, 1, 2.0), 2).sx, 0)
		local early = find(A:frame(ps, 1, 2.0 + level_anim.INTRO_DELAY + 0.1), 1)
		assert_true(early.sx > 0.3)
		assert_eq(find(A:frame(ps, 1, 2.0 + level_anim.INTRO_DELAY + 0.1), 2).sx < early.sx, true) -- the far corner is later
		local done = find(A:frame(ps, 1, 3.5), 2)
		assert_eq(done.sx, 1)
		assert_eq(done.sy, 1)
		-- reduced motion: no intro at all
		local R = level_anim.new({ geom = g, reduced = true })
		R:intro(ps, 2.0)
		assert_eq(find(R:frame(ps, 1, 2.0), 1).sx, 1)
	end)
end)
