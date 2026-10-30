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
		assert_eq(b.color, level_effects.LIGHT_BEAM)
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

	it("explains the automatic shuffle with a banner, not the player's own Remix", function()
		local E = level_effects.new({ geom = G() })
		-- Remix: the core emits `booster` and then `shuffle` in the same tick
		E:event({ type = "booster", t = 40, booster = "remix", ok = true })
		E:event({ type = "shuffle", t = 40, moves = {}, recolors = {}, duration = 30 })
		assert_eq(#by_kind(E:drain(), "banner"), 0)
		-- the next automatic shuffle is explained again
		E:event({ type = "shuffle", t = 200, moves = {}, recolors = {}, duration = 30 })
		assert_eq(by_kind(E:drain(), "banner")[1].key, "hud.shuffle")
		-- a Remix that found nothing to shuffle (ok = false) is followed by no shuffle: it must not eat the next banner
		E:event({ type = "booster", t = 300, booster = "remix", ok = false })
		E:event({ type = "shuffle", t = 400, moves = {}, recolors = {}, duration = 30 })
		assert_eq(by_kind(E:drain(), "banner")[1].key, "hud.shuffle")
		-- another booster's tick does not mark the shuffle as the player's
		E:event({ type = "booster", t = 500, booster = "stick", ok = true, at = { 2, 2 } })
		E:event({ type = "shuffle", t = 500, moves = {}, recolors = {}, duration = 30 })
		assert_eq(#by_kind(E:drain(), "banner"), 1)
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

-- The ten combos ----------------------------------------------------------------------------------

local core_helper = require("tests.core.helper")

-- Swaps the specials a and b (picture letters of tests/core/helper.lua) in the middle of a random
-- 7x7 board and plays the real game to rest. Returns the effect commands and the core events.
local function combo_run(a, b)
	local rows = { "#######", "#######", "#######", "###" .. a .. b .. "##", "#######", "#######", "#######" }
	local level = core_helper.level(rows, { moves = 10 })
	local s = assert(level_session.new({ params = { level = 1, level_text = level } }))
	local g = geom.new(s.W, s.H, s.game:cells(), { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })
	local cellmap = {}
	local E = level_effects.new({ geom = g, lookup = function(id) return nil end })
	E:set_cell_lookup(function(x, y) return cellmap[y * 100 + x] end)
	local ok, res = s:command({ type = "swap", from = { 4, 4 }, to = { 5, 4 } })
	assert_true(ok, tostring(res))
	local cmds, events = {}, {}
	for _ = 1, 900 do
		s:advance(1 / 60, function(evs)
			for _, e in ipairs(evs) do
				events[#events + 1] = e
				E:event(e)
			end
		end)
		for _, c in ipairs(E:drain()) do cmds[#cmds + 1] = c end
		if s.game:is_stable() then break end
	end
	return cmds, events, g
end

local COMBO_PAIRS = {
	cross = { "R", "R" }, triple_cross = { "R", "S" }, bass_drop = { "S", "S" }, bird_riff = { "B", "R" },
	bird_sub = { "B", "S" }, trio = { "B", "B" }, finale = { "D", "D" }, color_riff = { "D", "R" },
	color_sub = { "D", "S" }, color_bird = { "D", "B" },
}

-- what a player sees of a combo, as a sorted list of strings
local function look(cmds)
	local seen = {}
	for _, c in ipairs(cmds) do
		local k = c.kind
		if k == "beam" then k = k .. ":" .. c.color .. ":" .. c.width
		elseif k == "ring" then k = k .. ":" .. tostring(c.color) .. ":" .. tostring(c.image)
		elseif k == "fly" then k = k .. ":" .. tostring(c.carry)
		elseif k == "burst" then k = k .. ":" .. c.fx
		elseif k == "flash" or k == "charge" or k == "ray" or k == "reticle" or k == "screen_flash" then k = k .. ":" .. tostring(c.color)
		elseif k == "shake" then k = k .. ":" .. c.amp
		end
		seen[k] = true
	end
	local list = {}
	for k in pairs(seen) do list[#list + 1] = k end -- order-independent
	table.sort(list)
	return table.concat(list, "|")
end

local function count(cmds, kind)
	local n = 0
	for _, c in ipairs(cmds) do
		if c.kind == kind then n = n + 1 end
	end
	return n
end

local function first_activate(events)
	for _, e in ipairs(events) do
		if e.type == "activate" and e.combo then return e end
	end
end

describe("client.level_effects combos", function()
	local runs = {}
	local function run(name)
		if not runs[name] then
			local p = COMBO_PAIRS[name]
			local cmds, events, g = combo_run(p[1], p[2])
			runs[name] = { cmds = cmds, events = events, g = g, look = look(cmds) }
		end
		return runs[name]
	end

	it("fires each of the ten combos from the pairs the tests use", function()
		for name in pairs(COMBO_PAIRS) do -- order-independent
			local r = run(name)
			local a = first_activate(r.events)
			assert_true(a ~= nil, name .. ": no activation")
			assert_eq(a.combo, name)
		end
	end)

	it("gives every combo its own picture: no two look alike", function()
		local by_look = {}
		for _, name in ipairs(level_effects.COMBOS) do
			local l = run(name).look
			assert_true(#l > 0, name .. " draws nothing")
			assert_eq(by_look[l], nil, name .. " looks like " .. tostring(by_look[l]))
			by_look[l] = name
		end
	end)

	it("draws a Cross as four fat cyan bolts and a Triple cross as a grid of twelve in two colours", function()
		local cross = run("cross").cmds
		assert_eq(count(cross, "beam"), 4)
		for _, c in ipairs(cross) do
			if c.kind == "beam" then
				assert_eq(c.color, level_effects.COMBO_LOOK.cross.beam)
				assert_true(c.width > 0.9 * run("cross").g.cell * 0.9)
			end
		end
		local triple = run("triple_cross").cmds
		assert_eq(count(triple, "beam"), 12)
		local colors = {}
		for _, c in ipairs(triple) do
			if c.kind == "beam" then colors[c.color] = (colors[c.color] or 0) + 1 end
		end
		assert_eq(colors[level_effects.COMBO_LOOK.triple_cross.beam_h], 6)
		assert_eq(colors[level_effects.COMBO_LOOK.triple_cross.beam_v], 6)
		-- both specials swell first: the bolts leave 6 ticks (T.sub_swell) after the activation
		local act = first_activate(run("triple_cross").events)
		for _, c in ipairs(triple) do
			if c.kind == "beam" then assert_eq(c.at, act.t + level_effects.SUB_SWELL) end
		end
	end)

	it("draws the Bass drop as four violet shock rings, a charge and a screen pulse", function()
		local r = run("bass_drop").cmds
		local rings = 0
		for _, c in ipairs(r) do
			if c.kind == "ring" then rings = rings + 1 end
		end
		assert_eq(rings, 4) -- r = 0..3 (7x7)
		assert_eq(count(r, "charge"), 1)
		assert_eq(count(r, "screen_flash"), 1)
		assert_eq(count(r, "beam"), 0)
	end)

	it("lets a Bird carry the icon of its cargo and fan three birds in a Trio", function()
		local br = run("bird_riff").cmds
		local fly
		for _, c in ipairs(br) do
			if c.kind == "fly" then fly = c end
		end
		assert_true(fly ~= nil, "the bird flies")
		assert_eq(fly.carry, "specials_riff")
		assert_eq(count(br, "reticle") >= 1, true)
		local bs = run("bird_sub").cmds
		for _, c in ipairs(bs) do
			if c.kind == "fly" then assert_eq(c.carry, "specials_sub") end
		end
		-- the cargo goes off where the bird lands: bolts of the Riff
		assert_true(count(br, "beam") >= 2)
		local trio = run("trio").cmds
		local fans = {}
		for _, c in ipairs(trio) do
			if c.kind == "fly" then fans[#fans + 1] = c.fan end
		end
		table.sort(fans)
		assert_same(fans, { -1, 0, 1 })
	end)

	it("sends a ray of colour X to every piece that \"Colour X\" turns into a special", function()
		for _, name in ipairs({ "color_riff", "color_sub", "color_bird" }) do
			local r = run(name)
			local transforms = 0
			for _, e in ipairs(r.events) do
				if e.type == "transform" then transforms = transforms + 1 end
			end
			assert_true(transforms >= 3, name .. ": " .. transforms .. " transforms")
			assert_eq(count(r.cmds, "ray"), transforms, name)
			local x = first_activate(r.events).color
			for _, c in ipairs(r.cmds) do
				if c.kind == "ray" then assert_eq(c.color, level_effects.color_of(x)) end
			end
		end
	end)

	it("charges the Grand finale white for 0.4 s, then flashes, slows down, shakes and rains confetti", function()
		local r = run("finale")
		local act = first_activate(r.events)
		local charge, flash, slow, shake
		local confetti = 0
		for _, c in ipairs(r.cmds) do
			if c.kind == "charge" then charge = c end
			if c.kind == "screen_flash" and c.color == "#FFFFFF" then flash = c end
			if c.kind == "slowmo" then slow = c end
			if c.kind == "shake" and c.amp == 10 then shake = c end
			if c.kind == "burst" and c.fx == "confetti" then confetti = confetti + 1 end
		end
		assert_true(charge and flash and slow and shake)
		assert_eq(charge.at, act.t)
		assert_eq(charge.dur, level_effects.FINALE_PAUSE) -- 24 ticks = 0.4 s
		assert_eq(flash.at, act.t + level_effects.FINALE_PAUSE)
		assert_eq(slow.at, flash.at)
		assert_eq(slow.dur, 0.4)
		assert_eq(slow.scale, 0.5)
		assert_true(confetti >= 5)
		-- the rings run through the colours of the pieces
		local colors = {}
		for _, c in ipairs(r.cmds) do
			if c.kind == "ring" then colors[c.color] = true end
		end
		local n = 0
		for _ in pairs(colors) do n = n + 1 end -- order-independent
		assert_true(n >= 3, "rainbow rings: " .. n)
	end)

	it("keeps the combos readable under reduced motion: no shake, slow motion, flash or charge", function()
		local p = COMBO_PAIRS.finale
		local rows = { "#######", "#######", "#######", "###" .. p[1] .. p[2] .. "##", "#######", "#######", "#######" }
		local s = assert(level_session.new({ params = { level = 1, level_text = core_helper.level(rows, { moves = 10 }) } }))
		local g = geom.new(s.W, s.H, s.game:cells(), { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })
		local E = level_effects.new({ geom = g, reduced = true })
		assert_true(s:command({ type = "swap", from = { 4, 4 }, to = { 5, 4 } }))
		local cmds = {}
		for _ = 1, 600 do
			s:advance(1 / 60, function(evs) for _, e in ipairs(evs) do E:event(e) end end)
			for _, c in ipairs(E:drain()) do cmds[#cmds + 1] = c end
			if s.game:is_stable() then break end
		end
		for _, k in ipairs({ "shake", "slowmo", "screen_flash", "charge" }) do
			assert_eq(count(cmds, k), 0, k)
		end
		assert_true(count(cmds, "flash") >= 1)
	end)
end)
