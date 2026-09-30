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
		local s = find(A:frame(ps, 31, 1.05), 9)
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
