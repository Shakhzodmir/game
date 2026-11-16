-- The conveyor belt (core-rules 10.9) in the client: its picture, the texts, the sound, the slide of the riders
-- (client/level_anim.lua) and the background GUI (screens/level/level_bg.gui_script) that lays a tile on every
-- belt cell, turned the way the belt moves, on the strict Defold stub.

local stub = require("tests.client.level_defold_stub")
local app = require("client.app")
local assets = require("client.assets_index")
local i18n = require("client.i18n")
local link = require("client.level_link")
local level_anim = require("client.level_anim")
local level_audio = require("client.level_audio")
local level_conveyor = require("client.level_conveyor")
local level_geom = require("client.level_geom")
local level_session = require("client.level_session")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local core_helper = require("tests.core.helper")
local H = require("tests.meta.helper")

local DT = 1 / 60
local FULL = { "######", "######", "######", "######", "######", "######" }

-- a 6x6 board: an open belt to the right along row 3, cells (2..5, 3), and a ring (2,5) (2,6) (3,6) (3,5)
local function conveyor_level()
	return core_helper.level(FULL, { moves = 30, conveyor = {
		{ path = { { 1, 2 }, { 2, 2 }, { 3, 2 }, { 4, 2 } } },
		{ path = { { 1, 4 }, { 1, 5 }, { 2, 5 }, { 2, 4 } } },
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

describe("the conveyor in the client", function()
	it("has its picture in the game atlas, with a copy for the start window", function()
		local img = assets.images[level_conveyor.IMAGE]
		assert_true(img ~= nil, "blockers/conveyor is in the index")
		assert_same({ img.atlas, img.anim, img.w, img.h }, { "game", "blockers_conveyor", 160, 160 })
		assert_same(img.also, { "meta" })
	end)

	it("turns the picture (arrows to the right) by the direction of travel", function()
		assert_same({ level_conveyor.turn("r"), level_conveyor.turn("u"), level_conveyor.turn("l"), level_conveyor.turn("d") },
			{ 0, 90, 180, 270 })
		assert_eq(level_conveyor.turn(nil), 0)
		assert_false(level_conveyor.active({ { exists = true }, { exists = true } }))
		assert_true(level_conveyor.active({ { exists = true }, { exists = true, conveyor = { belt = 1, pos = 1, dir = "u" } } }))
		assert_false(level_conveyor.active(nil))
		assert_same(level_conveyor.tiles({ { exists = true }, { exists = true, conveyor = { belt = 1, pos = 1, dir = "u" } } }),
			{ { i = 2, dir = "u", turn = 90 } })
	end)

	it("has its name, its description and its lesson line in three languages; the lesson fits the bubble", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			i18n.set_language(lang)
			for _, key in ipairs({ "blocker.conveyor", "blocker.conveyor_desc", "tutorial.conveyor" }) do
				local text = i18n.t(key)
				assert_true(type(text) == "string" and text ~= "" and text ~= key, lang .. " " .. key)
			end
			local lesson = i18n.t("tutorial.conveyor")
			assert_true(bubble_lines(lesson, lang) <= 2, lang .. ": the lesson takes more than two lines")
			assert_true(#require("tests.client.town_defold_stub").utf8_codepoints(lesson) <= 64, lang)
		end
		i18n.set_language("ru")
		assert_eq(i18n.t("blocker.conveyor"), "Конвейер")
		assert_eq(i18n.t("blocker.conveyor_desc"), "После каждого хода лента сдвигает фишки на одну клетку.")
		assert_eq(i18n.t("tutorial.conveyor"), "Лента едет после хода. Думай на шаг вперёд!")
		i18n.set_language("en")
		assert_eq(i18n.t("blocker.conveyor"), "Conveyor")
	end)

	it("ticks softly once a step, however many belts move; a jammed belt clunks lower", function()
		local calls = {}
		local a = {}
		function a.sfx(name, opts) calls[#calls + 1] = { name, opts } end
		function a.play_note() end
		function a.layer() end
		function a.combo() end
		local t = 0
		local la = level_audio.new({ audio = a, now = function() return t end })
		la:events({ { type = "conveyor", belt = 1, moves = {} }, { type = "conveyor", belt = 2, moves = {} } })
		assert_eq(#calls, 1)
		assert_eq(calls[1][1], level_audio.CONVEYOR_SFX)
		assert_true(calls[1][2].gain < 1 and calls[1][2].speed < 1)
		t = 1
		la:events({ { type = "conveyor", belt = 1, jam = true, moves = {} } })
		assert_eq(#calls, 2)
		assert_true(calls[2][2].speed < calls[1][2].speed and calls[2][2].gain < calls[1][2].gain)
	end)
end)

describe("client/level_anim.lua: the riders of a belt slide (core-rules 10.9)", function()
	local cells = {}
	for i = 1, 36 do cells[i] = { exists = true } end
	local g = level_geom.new(6, 6, cells, { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })

	local function rider(x, y)
		return { id = 7, x = x, y = y, kind = "regular", color = "red", state = "swap", offx = 0, offy = 0 }
	end

	local function draw(anim, p, tick)
		local list = anim:frame({ p }, tick, tick / 60)
		return list[1]
	end

	it("a step: straight from the old cell to the new one in `duration` ticks", function()
		local anim = level_anim.new({ geom = g })
		anim:event({ type = "conveyor", t = 100, belt = 1, duration = 12, moves = { { id = 7, fx = 2, fy = 3, x = 3, y = 3 } } }, 0)
		local x0, y0 = g:center(2, 3)
		local x1, y1 = g:center(3, 3)
		local e = draw(anim, rider(3, 3), 100)
		assert_near(e.x, x0, 1e-6)
		assert_near(e.y, y0, 1e-6)
		e = draw(anim, rider(3, 3), 106)
		assert_near(e.x, (x0 + x1) / 2, 1e-6)
		assert_near(e.y, y0, 1e-6)
		assert_eq(e.alpha, 1)
		e = draw(anim, rider(3, 3), 112)
		assert_near(e.x, x1, 1e-6)
		-- at rest again it stands in its cell
		local p = rider(3, 3)
		p.state = "idle"
		e = draw(anim, p, 114)
		assert_near(e.x, x1, 1e-6)
		assert_near(e.y, y1, 1e-6)
	end)

	it("the jump of an open belt: out past the end, fading, then in from before the start", function()
		local anim = level_anim.new({ geom = g })
		anim:event({ type = "conveyor", t = 100, belt = 1, duration = 12,
			moves = { { id = 7, fx = 5, fy = 3, x = 2, y = 3, wrap = true, ox = 6, oy = 3, ix = 1, iy = 3 } } }, 0)
		local xe = g:center(5, 3)
		local xo = g:center(6, 3)
		local xi = g:center(1, 3)
		local xs = g:center(2, 3)
		local e = draw(anim, rider(2, 3), 103) -- a quarter: half way out, half faded
		assert_near(e.x, (xe + xo) / 2, 1e-6)
		assert_near(e.alpha, 0.5, 1e-6)
		e = draw(anim, rider(2, 3), 109) -- three quarters: half way in
		assert_near(e.x, (xi + xs) / 2, 1e-6)
		assert_near(e.alpha, 0.5, 1e-6)
		e = draw(anim, rider(2, 3), 112)
		assert_near(e.x, xs, 1e-6)
		assert_near(e.alpha, 1, 1e-6)
		-- reduced motion: it fades in where it will stand
		local calm = level_anim.new({ geom = g, reduced = true })
		calm:event({ type = "conveyor", t = 100, belt = 1, duration = 12,
			moves = { { id = 7, fx = 5, fy = 3, x = 2, y = 3, wrap = true, ox = 6, oy = 3, ix = 1, iy = 3 } } }, 0)
		e = draw(calm, rider(2, 3), 106)
		assert_near(e.x, xs, 1e-6)
		assert_near(e.alpha, 0.5, 1e-6)
	end)

	it("a jammed belt moves nothing", function()
		local anim = level_anim.new({ geom = g })
		anim:event({ type = "conveyor", t = 100, belt = 1, jam = true, moves = {}, duration = 0 }, 0)
		local p = rider(3, 3)
		p.state = "idle"
		local x1 = g:center(3, 3)
		assert_near(draw(anim, p, 101).x, x1, 1e-6)
	end)
end)

describe("screens/level/level_bg.gui_script with the conveyor (core-rules 10.9)", function()
	local function with_belts(fn, plain)
		local stubE = stub.install({})
		local ok, err = pcall(function()
			boot_app()
			stubE.use_gui("/screens/level/level_bg.gui")
			local script = stub.load_script("screens/level/level_bg.gui_script")
			local self = {}
			script.init(self)
			local level = conveyor_level()
			if plain then level.conveyor = nil end
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
			function c.belts()
				local out = {}
				for _, n in ipairs(stubE.gui.nodes) do
					if not n.dead and n.anim == "blockers_conveyor" then out[#out + 1] = n end
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

	local function at(c, x, y)
		local lx, ly = c.geom:center(x, y)
		for _, n in ipairs(c.belts()) do
			if math.abs(n.pos.x - lx) < 0.5 and math.abs(n.pos.y - ly) < 0.5 then return n end
		end
		return nil
	end

	local function turn(n)
		return n.euler and n.euler.z or 0
	end

	it("lays one tile of cell size on every belt cell, over the cell tiles, turned the way the belt moves", function()
		with_belts(function(c)
			assert_eq(#c.belts(), 8)
			for x = 2, 5 do
				local n = at(c, x, 3)
				assert_true(n ~= nil, "a belt tile at " .. x .. ",3")
				assert_near(n.size.x, c.geom.cell, 1e-6)
				assert_near(n.size.y, c.geom.cell, 1e-6)
				assert_eq(turn(n), 0) -- to the right: the picture as it is
			end
			-- the ring (2,5) -> (2,6) -> (3,6) -> (3,5) -> (2,5): down, right, up, left
			assert_eq(turn(at(c, 2, 5)), 270)
			assert_eq(turn(at(c, 2, 6)), 0)
			assert_eq(turn(at(c, 3, 6)), 90)
			assert_eq(turn(at(c, 3, 5)), 180)
			assert_eq(at(c, 1, 3), nil)
			local last_tile, first_belt = 0, nil
			for k, n in ipairs(c.E.gui.nodes) do
				if not n.dead and (n.anim == "board_cell_a" or n.anim == "board_cell_b") then last_tile = k end
				if not n.dead and n.anim == "blockers_conveyor" and not first_belt then first_belt = k end
			end
			assert_true(first_belt > last_tile, "the belt is drawn after (over) the cell tiles")
		end)
	end)

	it("keeps the belts through a rebuild (the window changed) and leaks nothing", function()
		with_belts(function(c)
			local nodes = c.E.gui_stats().nodes
			c.resize()
			c.step(3)
			assert_eq(c.E.gui_stats().nodes, nodes)
			assert_eq(#c.belts(), 8)
			assert_eq(turn(at(c, 3, 6)), 90)
			assert_eq(c.E.gui_stats().anims, 0)
		end)
	end)

	it("a level without belts has no belt node at all", function()
		with_belts(function(c)
			assert_eq(#c.belts(), 0)
		end, true)
	end)
end)
