-- The portals (core-rules 10.14) in the client: the pictures, the mark of a pair, the texts, the sound, the dive
-- of a piece through a pair (client/level_anim.lua) and the background GUI (screens/level/level_bg.gui_script)
-- that draws the entrance and the exit of every pair under the pieces, on the strict Defold stub.

local stub = require("tests.client.level_defold_stub")
local app = require("client.app")
local assets = require("client.assets_index")
local i18n = require("client.i18n")
local link = require("client.level_link")
local level_anim = require("client.level_anim")
local level_audio = require("client.level_audio")
local level_portal = require("client.level_portal")
local level_geom = require("client.level_geom")
local level_session = require("client.level_session")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local core_helper = require("tests.core.helper")
local H = require("tests.meta.helper")

local DT = 1 / 60

-- a 6x6 board: a block of 3x3 on the left top, a block of 3x3 on the right bottom; the bottom row of the left
-- block are the entrances, the top row of the right block the exits: (1,3) -> (4,4), (2,3) -> (5,4), (3,3) -> (6,4)
local ROWS = { "###...", "###...", "###...", "...###", "...###", "...###" }
local function portal_level()
	return core_helper.level(ROWS, { moves = 30, portals = {
		{ ["in"] = { 0, 2 }, out = { 3, 3 } },
		{ ["in"] = { 1, 2 }, out = { 4, 3 } },
		{ ["in"] = { 2, 2 }, out = { 5, 3 } },
	} })
end

local function boot_app()
	analytics.init({ strict = true })
	app.init({
		districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
		now = H.T0, clock = function() return H.T0 end, sys_language = "en",
	})
	i18n.set_language("en")
end

-- the two-line bubble of a lesson (the model of tests/client/tutorial_content_test.lua)
local function bubble_lines(text, lang)
	local font = require("tests.client.font_advances")[lang == "ko" and "body_ko" or "body"]
	local codepoints = require("tests.client.town_defold_stub").utf8_codepoints
	local function width(s)
		local w = 0
		for _, cp in ipairs(codepoints(s)) do
			local advance = font.advances[cp]
			assert_true(advance ~= nil, string.format("the body font has no glyph U+%04X (%s)", cp, text))
			w = w + advance * 30 / font.size
		end
		return w
	end
	local lines, line = 1, nil
	for word in string.gmatch(text, "%S+") do
		local try = line and (line .. " " .. word) or word
		if line and width(try) > 620 - 230 - 6 then
			lines, line = lines + 1, word
		else
			line = try
		end
	end
	return lines
end

describe("the portal in the client", function()
	it("has its two pictures in the game atlas, the entrance with a copy for the start window", function()
		local a = assets.images[level_portal.IMAGE_IN]
		local b = assets.images[level_portal.IMAGE_OUT]
		assert_true(a ~= nil and b ~= nil, "blockers/portal_in and blockers/portal_out are in the index")
		assert_same({ a.atlas, a.anim, a.w, a.h }, { "game", "blockers_portal_in", 160, 160 })
		assert_same({ b.atlas, b.anim, b.w, b.h }, { "game", "blockers_portal_out", 160, 160 })
		assert_same(a.also, { "meta" })
		assert_true(assets.images[level_portal.MARK] ~= nil, "the mark of a pair is in the index")
	end)

	it("lists the portal cells of a board with their role, pair, picture and the colour of the pair", function()
		assert_false(level_portal.active({ { exists = true }, { exists = true } }))
		assert_false(level_portal.active(nil))
		local cells = { { exists = true, portal = { role = "in", pair = 2, x = 3, y = 1 } }, { exists = true },
			{ exists = true, portal = { role = "out", pair = 2, x = 1, y = 1 } } }
		assert_true(level_portal.active(cells))
		assert_same(level_portal.tiles(cells), {
			{ i = 1, role = "in", pair = 2, image = "blockers/portal_in", color = level_portal.COLORS[2] },
			{ i = 3, role = "out", pair = 2, image = "blockers/portal_out", color = level_portal.COLORS[2] },
		})
		assert_same(level_portal.tiles(nil), {})
	end)

	it("gives every pair a colour of its own, the same for its two ends; the colours repeat after the last", function()
		local n = #level_portal.COLORS
		assert_true(n >= 4)
		for a = 1, n do
			for b = a + 1, n do
				local ca, cb = level_portal.COLORS[a], level_portal.COLORS[b]
				local d = math.abs(ca[1] - cb[1]) + math.abs(ca[2] - cb[2]) + math.abs(ca[3] - cb[3])
				assert_true(d > 0.3, "colours " .. a .. " and " .. b .. " are too close")
			end
		end
		assert_same(level_portal.color(1), level_portal.COLORS[1])
		assert_same(level_portal.color(n + 1), level_portal.COLORS[1])
		assert_same(level_portal.color(nil), level_portal.COLORS[1])
	end)

	it("has its name, its description and its lesson line in three languages; the lesson fits the bubble", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			i18n.set_language(lang)
			for _, key in ipairs({ "blocker.portal", "blocker.portal_desc", "tutorial.portal" }) do
				local text = i18n.t(key)
				assert_true(type(text) == "string" and text ~= "" and text ~= key, lang .. " " .. key)
			end
			local lesson = i18n.t("tutorial.portal")
			assert_true(bubble_lines(lesson, lang) <= 2, lang .. ": the lesson takes more than two lines")
			assert_true(#require("tests.client.town_defold_stub").utf8_codepoints(lesson) <= 64, lang)
		end
		i18n.set_language("ru")
		assert_eq(i18n.t("blocker.portal"), "Портал")
		assert_eq(i18n.t("blocker.portal_desc"), "Фишки падают в один портал и выпадают из другого такого же цвета.")
		assert_eq(i18n.t("tutorial.portal"), "Фишки ныряют в портал и выпадают из второго!")
		i18n.set_language("en")
		assert_eq(i18n.t("blocker.portal"), "Portal")
	end)

	it("whooshes softly once for all the hops of a moment", function()
		local calls = {}
		local a = {}
		function a.sfx(name, opts) calls[#calls + 1] = { name, opts } end
		function a.play_note() end
		function a.layer() end
		function a.combo() end
		local t = 0
		local la = level_audio.new({ audio = a, now = function() return t end })
		la:events({ { type = "portal", id = 1, fx = 1, fy = 3, x = 4, y = 4, pair = 1 },
			{ type = "portal", id = 2, fx = 2, fy = 3, x = 5, y = 4, pair = 2 } })
		assert_eq(#calls, 1)
		assert_eq(calls[1][1], level_portal.SFX)
		assert_true(calls[1][2].gain < 1 and calls[1][2].speed > 1)
		t = 1
		la:events({ { type = "portal", id = 3, fx = 1, fy = 3, x = 4, y = 4, pair = 1 } })
		assert_eq(#calls, 2)
	end)
end)

describe("client/level_anim.lua: a piece dives through a portal (core-rules 10.14)", function()
	local cells = {}
	for i = 1, 36 do cells[i] = { exists = true } end
	local g = level_geom.new(6, 6, cells, { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })
	local HOP = { type = "portal", t = 100, id = 7, fx = 2, fy = 3, x = 5, y = 4, pair = 2 }

	-- the piece as the core gives it: in the exit cell (5,4), falling, `offy` units above it
	local function piece(offy, y)
		return { id = 7, x = 5, y = y or 4, kind = "regular", color = "red", state = "fall", offx = 0, offy = offy }
	end

	local function draw(anim, p, tick)
		local list = anim:frame({ p }, tick, tick / 60)
		return list[1]
	end

	it("the first half it shrinks in the entrance cell, the second half it grows in the exit cell", function()
		local anim = level_anim.new({ geom = g })
		anim:event(HOP, 0)
		local xi, yi = g:center(2, 3)
		local xo, yo = g:center(5, 4)
		local e = draw(anim, piece(3600), 100)
		assert_near(e.x, xi, 1e-6)
		assert_near(e.y, yi, 1e-6)
		assert_near(e.sx, 1, 1e-6)
		local e1 = draw(anim, piece(2820), 102)
		assert_near(e1.x, xi, 1e-6)
		assert_true(e1.sx < 1 and e1.sx > 0 and e1.sx == e1.sy, "shrinking in the entrance")
		-- past the middle: in the exit cell, small, and growing
		local e2 = draw(anim, piece(1800), 104)
		assert_near(e2.x, xo, 1e-6)
		assert_near(e2.y, yo, 1e-6)
		assert_true(e2.sx < 1 and e2.sx > 0)
		local grown = e2.sx
		local e3 = draw(anim, piece(540), 106)
		assert_near(e3.y, yo, 1e-6)
		assert_true(e3.sx > grown, "growing out of the exit")
		assert_eq(e3.clip, nil) -- not cut at the top of the run like a piece that enters at a spawner
	end)

	it("when it has landed it is an ordinary piece in its cell", function()
		local anim = level_anim.new({ geom = g })
		anim:event(HOP, 0)
		draw(anim, piece(540), 106)
		local p = piece(0)
		p.state = "idle"
		local e = draw(anim, p, 107)
		local xo, yo = g:center(5, 4)
		assert_near(e.x, xo, 1e-6)
		assert_near(e.y, yo, 1e-6)
		assert_near(e.sx, 1, 1e-6)
		assert_eq(e.alpha, 1)
	end)

	it("a piece that falls on down the run stays in the exit cell until the fall of the core has come level", function()
		local anim = level_anim.new({ geom = g })
		anim:event(HOP, 0)
		local _, yo = g:center(5, 4)
		-- the core moved its target two cells down the run (row 6): it is still above the exit cell
		local e = draw(anim, piece(2 * 3600 + 1200, 6), 105)
		assert_near(e.y, yo, 1e-6)
		-- the time of the hop is over, the core is still above the exit cell (a start delay): it waits there, whole
		e = draw(anim, piece(2 * 3600 + 300, 6), 108)
		assert_near(e.y, yo, 1e-6)
		assert_near(e.sx, 1, 1e-6)
		-- the fall has passed the exit cell: the piece follows the core from here on
		e = draw(anim, piece(2 * 3600 - 900, 6), 110)
		local _, y_core = g:pos(5, 6, 0, 2 * 3600 - 900)
		assert_near(e.y, y_core, 1e-6)
		assert_near(e.sx, 1, 1e-6)
	end)

	it("with reduced motion it fades out of the entrance and into the exit without changing size", function()
		local anim = level_anim.new({ geom = g, reduced = true })
		anim:event(HOP, 0)
		local xi = g:center(2, 3)
		local xo = g:center(5, 4)
		local e = draw(anim, piece(2820), 102)
		assert_near(e.x, xi, 1e-6)
		assert_near(e.sx, 1, 1e-6)
		assert_true(e.alpha < 1 and e.alpha > 0)
		e = draw(anim, piece(540), 106)
		assert_near(e.x, xo, 1e-6)
		assert_near(e.sx, 1, 1e-6)
		assert_true(e.alpha < 1 and e.alpha > 0)
	end)

	it("a piece without a hop falls as before", function()
		local anim = level_anim.new({ geom = g })
		local p = piece(1800)
		local e = draw(anim, p, 104)
		local x, y = g:pos(5, 4, 0, 1800)
		assert_near(e.x, x, 1e-6)
		assert_near(e.y, y, 1e-6)
	end)
end)

describe("screens/level/level_bg.gui_script with portals (core-rules 10.14)", function()
	local function with_portals(fn, plain)
		local stubE = stub.install({})
		local ok, err = pcall(function()
			boot_app()
			stubE.use_gui("/screens/level/level_bg.gui")
			local script = stub.load_script("screens/level/level_bg.gui_script")
			local self = {}
			script.init(self)
			local level = portal_level()
			if plain then
				level = core_helper.level({ "######", "######", "######", "######", "######", "######" }, { moves = 30 })
			end
			local s = assert(level_session.new({ params = { level = 7, level_text = level } }))
			local cells = s.game:cells()
			local floor0 = {}
			for i = 1, #cells do floor0[i] = cells[i].floor or 0 end
			local g = level_geom.new(s.W, s.H, cells, { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })
			local view = { rev = 1, floor_rev = 0, cells = cells, floor0 = floor0, lit = {}, deliver = false,
				carpet = false, shake_x = 0, shake_y = 0, W = s.W, H = s.H, geom = g }
			link.attach({ session = s, input = {}, geom = g, view = view })
			script.update(self, DT)
			local c = { E = stubE, view = view, cells = cells, geom = g }
			function c.nodes(anim)
				local out = {}
				for _, n in ipairs(stubE.gui.nodes) do
					if not n.dead and n.anim == anim then out[#out + 1] = n end
				end
				return out
			end
			function c.step(n)
				for _ = 1, n or 1 do
					stubE.advance(DT)
					script.update(self, DT)
				end
			end
			function c.resize()
				view.rev = view.rev + 1
				c.step(1)
			end
			local ok2, err2 = pcall(fn, c)
			pcall(script.final, self)
			if not ok2 then error(err2, 0) end
		end)
		link.board = nil
		stub.restore()
		if not ok then error(err, 0) end
	end

	local function at(list, lx, ly)
		for _, n in ipairs(list) do
			if math.abs(n.pos.x - lx) < 0.5 and math.abs(n.pos.y - ly) < 0.5 then return n end
		end
		return nil
	end

	local function rgb(n)
		return { n.color.x, n.color.y, n.color.z }
	end

	it("draws the entrance picture on every entrance and the exit picture on every exit, at cell size, over the cell tiles", function()
		with_portals(function(c)
			local ins, outs = c.nodes("blockers_portal_in"), c.nodes("blockers_portal_out")
			assert_eq(#ins, 3)
			assert_eq(#outs, 3)
			for k = 1, 3 do
				local a = at(ins, c.geom:center(k, 3))
				local b = at(outs, c.geom:center(3 + k, 4))
				assert_true(a ~= nil, "an entrance at " .. k .. ",3")
				assert_true(b ~= nil, "an exit at " .. (3 + k) .. ",4")
				assert_near(a.size.x, c.geom.cell, 1e-6)
				assert_near(b.size.y, c.geom.cell, 1e-6)
				-- the pictures keep their own colours (TINT is off)
				assert_same(rgb(a), { 1, 1, 1 })
				assert_same(rgb(b), { 1, 1, 1 })
			end
			local last_tile, first_portal = 0, nil
			for k, n in ipairs(c.E.gui.nodes) do
				if not n.dead and (n.anim == "board_cell_a" or n.anim == "board_cell_b") then last_tile = k end
				if not n.dead and (n.anim == "blockers_portal_in" or n.anim == "blockers_portal_out") and not first_portal then
					first_portal = k
				end
			end
			assert_true(first_portal > last_tile, "the portals are drawn after (over) the cell tiles")
		end)
	end)

	it("marks the two ends of a pair with the same colour and every pair with its own", function()
		with_portals(function(c)
			local marks = c.nodes("fx_glow_dot")
			assert_eq(#marks, 6)
			local cell = c.geom.cell
			local dx, dy = cell * level_portal.MARK_AT[1], cell * level_portal.MARK_AT[2]
			local seen = {}
			for k = 1, 3 do
				local ax, ay = c.geom:center(k, 3)
				local bx, by = c.geom:center(3 + k, 4)
				local a = at(marks, ax + dx, ay + dy)
				local b = at(marks, bx + dx, by + dy)
				assert_true(a ~= nil and b ~= nil, "both ends of pair " .. k .. " wear a mark")
				assert_same(rgb(a), rgb(b))
				assert_same(rgb(a), level_portal.color(k))
				assert_near(a.size.x, cell * level_portal.MARK_SIZE, 1e-6)
				local key = table.concat(rgb(a), ",")
				assert_true(not seen[key], "pair " .. k .. " has a colour of its own")
				seen[key] = true
			end
		end)
	end)

	it("keeps the portals through a rebuild (the window changed) and leaks nothing", function()
		with_portals(function(c)
			local nodes = c.E.gui_stats().nodes
			c.resize()
			c.step(3)
			assert_eq(c.E.gui_stats().nodes, nodes)
			assert_eq(#c.nodes("blockers_portal_in"), 3)
			assert_eq(#c.nodes("blockers_portal_out"), 3)
			assert_eq(#c.nodes("fx_glow_dot"), 6)
			assert_eq(c.E.gui_stats().anims, 0)
		end)
	end)

	it("a level without portals has no portal node at all", function()
		with_portals(function(c)
			assert_eq(#c.nodes("blockers_portal_in"), 0)
			assert_eq(#c.nodes("blockers_portal_out"), 0)
			assert_eq(#c.nodes("fx_glow_dot"), 0)
		end, true)
	end)
end)
