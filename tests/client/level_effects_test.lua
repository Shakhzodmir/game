local level_effects = require("client.level_effects")
local geom = require("client.level_geom")
local level_session = require("client.level_session")

local function G(W, H)
	W, H = W or 6, H or 6
	local cells = {}
	for i = 1, W * H do cells[i] = { exists = true } end
	return geom.new(W, H, cells, { x0 = 0, y0 = 0, x1 = W * 100 + 36, y1 = H * 100 + 24 })
end

local function by_kind(list, kind)
	local out = {}
	for _, c in ipairs(list) do
		if c.kind == kind then out[#out + 1] = c end
	end
	return out
end

describe("client.level_effects", function()
	it("pops 8-12 particles in the piece colour after the pop of a cleared piece", function()
		local E = level_effects.new({ geom = G() })
		E:event({ type = "clear", t = 20, id = 1, x = 2, y = 3, kind = "regular", color = "green", cause = "match" })
		local c = E:drain()
		assert_eq(#c, 1)
		assert_eq(c[1].kind, "burst")
		assert_eq(c[1].fx, "pop")
		assert_eq(c[1].color, "#2BE38F")
		assert_true(c[1].count >= 8 and c[1].count <= 12)
		assert_eq(c[1].at, 23)
		local x, y = G():center(2, 3)
		assert_eq(c[1].x, x)
		assert_eq(c[1].y, y)
		assert_eq(#E:drain(), 0)
	end)

	it("sends a bolt from its exit cell to the edge at 28 cells per second", function()
		local E = level_effects.new({ geom = G() })
		E:event({ type = "activate", t = 10, id = 3, x = 2, y = 4, special = "riff", axis = "h" })
		E:event({ type = "bolt", t = 10, x = 2, y = 4, dir = "l", at = 10 })
		E:event({ type = "bolt", t = 10, x = 2, y = 4, dir = "u", at = 10 })
		local beams = by_kind(E:drain(), "beam")
		assert_eq(#beams, 2)
		assert_eq(beams[1].dx, -1)
		assert_eq(beams[1].dy, 0)
		assert_near(beams[1].len, 1.6 * 100, 1e-9) -- one cell to the edge + a little past it
		assert_near(beams[1].speed, 100 * 7 / 15, 1e-9)
		assert_eq(beams[2].dy, 1) -- "u" is up on the screen
		assert_near(beams[2].len, 3.6 * 100, 1e-9)
	end)

	it("makes row and column lights faster gold beams", function()
		local E = level_effects.new({ geom = G() })
		E:event({ type = "booster", t = 5, booster = "row_light", row = 3, ok = true })
		E:event({ type = "bolt", t = 5, x = 1, y = 3, dir = "r", at = 5 })
		local b = by_kind(E:drain(), "beam")[1]
		assert_eq(b.color, "#FFE66D")
		assert_near(b.speed, 100, 1e-9)
		E:event({ type = "bolt", t = 9, x = 1, y = 3, dir = "r", at = 9 })
		assert_near(by_kind(E:drain(), "beam")[1].speed, 100 * 7 / 15, 1e-9)
	end)

	it("swells and shakes the board 6 px for a Sabwoofer, with shock rings", function()
		local E = level_effects.new({ geom = G() })
		E:event({ type = "activate", t = 10, id = 3, x = 3, y = 3, special = "sub" })
		for r = 0, 2 do E:event({ type = "ring", t = 10, x = 3, y = 3, r = r, at = 16 + 2 * r }) end
		local c = E:drain()
		local shake = by_kind(c, "shake")
		assert_eq(#shake, 1)
		assert_eq(shake[1].amp, 6)
		assert_eq(shake[1].at, 16)
		local rings = by_kind(c, "ring")
		assert_eq(#rings, 2)
		assert_eq(rings[2].at, 20)
		assert_true(rings[2].size > rings[1].size)
	end)

	it("gives the Grand finale a white flash, a 10 px shake and a x0.5 slow motion for 0.4 s", function()
		local E = level_effects.new({ geom = G() })
		E:event({ type = "activate", t = 100, id = 3, x = 3, y = 3, special = "disco", combo = "finale", partner = 4 })
		local c = E:drain()
		local sf = by_kind(c, "screen_flash")
		assert_eq(#sf, 1)
		assert_eq(sf[1].at, 124)
		assert_eq(by_kind(c, "shake")[1].amp, 10)
		local sm = by_kind(c, "slowmo")[1]
		assert_eq(sm.scale, 0.5)
		assert_near(sm.dur, 0.4, 1e-9)
		-- reduced motion: no shake, no slow motion, no screen flash
		local R = level_effects.new({ geom = G(), reduced = true })
		R:event({ type = "activate", t = 100, id = 3, x = 3, y = 3, special = "disco", combo = "finale", partner = 4 })
		local r = R:drain()
		assert_eq(#by_kind(r, "shake"), 0)
		assert_eq(#by_kind(r, "slowmo"), 0)
		assert_eq(#by_kind(r, "screen_flash"), 0)
	end)

	it("flies the Bird on the core's flight time and colours Disco rays with X", function()
		local E = level_effects.new({ geom = G() })
		E:event({ type = "bird_fly", t = 12, x = 1, y = 1, tx = 5, ty = 6, carry = "riff", axis = "v", duration = 33 })
		local f = by_kind(E:drain(), "fly")[1]
		assert_eq(f.dur, 33)
		assert_eq(f.carry, "specials_riff")
		local x1, y1 = G():center(5, 6)
		assert_eq(f.x1, x1)
		assert_eq(f.y1, y1)
		E:event({ type = "activate", t = 20, id = 9, x = 3, y = 3, special = "disco", color = "blue" })
		E:event({ type = "disco_ray", t = 20, x = 3, y = 3, tx = 1, ty = 2 })
		assert_eq(by_kind(E:drain(), "ray")[1].color, "#3AA4FF")
	end)

	it("breaks blockers into their own debris and marks lit floor tiles", function()
		local E = level_effects.new({ geom = G(), lookup = function(id) return id == 5 and { color = "purple" } or nil end })
		E:event({ type = "destroy", t = 3, id = 4, x = 1, y = 1, item = "record_box" })
		E:event({ type = "destroy", t = 3, id = 5, x = 2, y = 1, item = "balloon" })
		E:event({ type = "destroy", t = 3, id = 6, x = 3, y = 1, item = "concrete" })
		E:event({ type = "floor_lit", t = 3, x = 4, y = 4 })
		local c = E:drain()
		local bursts = by_kind(c, "burst")
		assert_eq(bursts[1].fx, "debris")
		assert_eq(bursts[2].fx, "confetti")
		assert_eq(bursts[2].color, "#9B52FF")
		assert_eq(bursts[3].fx, "dust")
		assert_eq(by_kind(c, "floor")[1].x, 4)
	end)

	it("shows praise words, the shuffle banner and the microphone stinger", function()
		local E = level_effects.new({ geom = G() })
		E:event({ type = "praise", t = 1, act = 2, wave = 5, word = "hit" })
		E:event({ type = "shuffle", t = 2, moves = {}, recolors = {}, duration = 30 })
		E:event({ type = "mic_delivered", t = 3, id = 1, x = 2, y = 6 })
		local c = E:drain()
		assert_eq(by_kind(c, "praise")[1].index, 2)
		assert_eq(by_kind(c, "banner")[1].key, "hud.shuffle")
		assert_eq(#by_kind(c, "stinger"), 1)
	end)

	it("plans effects for every event of a real game", function()
		local s = assert(level_session.new({ params = { level = 2 }, read_level = function()
			return [[{
  "id": 2, "version": 1, "size": [7, 7], "moves": 25, "difficulty": "easy",
  "colors": ["red", "yellow", "green", "blue"],
  "goals": [{"type": "collect", "color": "blue", "count": 50}],
  "cells": ["#######", "#######", "#######", "#######", "#######", "#######", "#######"],
  "slots": [{"at": [3, 3], "type": "sub"}, {"at": [1, 5], "type": "riff", "axis": "h"}, {"at": [5, 1], "type": "disco"}]
}]]
		end }))
		local g = geom.new(s.W, s.H, s.game:cells(), { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })
		local E = level_effects.new({ geom = g })
		local kinds = {}
		for _ = 1, 10 do
			local cmd = s:hint_command()
			if not cmd then break end
			s:command(cmd)
			for _ = 1, 600 do
				s:advance(1 / 60, function(evs)
					for _, e in ipairs(evs) do E:event(e) end
				end)
				for _, c in ipairs(E:drain()) do
					kinds[c.kind] = true
					assert_true(type(c.at) == "number")
				end
				if s.game:is_stable() then break end
			end
		end
		assert_true(kinds.burst)
	end)
end)
