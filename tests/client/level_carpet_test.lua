-- The carpet (core-rules 10.8) in the client: its picture, the goal, the texts, the sound, and the background
-- GUI (screens/level/level_bg.gui_script) that lays a tile over every covered cell, on the strict Defold stub.
-- The board script itself plays a carpet level in tests/client/level_board_test.lua.

local stub = require("tests.client.level_defold_stub")
local app = require("client.app")
local assets = require("client.assets_index")
local i18n = require("client.i18n")
local levels = require("client.levels")
local link = require("client.level_link")
local level_audio = require("client.level_audio")
local level_carpet = require("client.level_carpet")
local level_geom = require("client.level_geom")
local level_session = require("client.level_session")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local core_helper = require("tests.core.helper")
local H = require("tests.meta.helper")

local DT = 1 / 60

-- a 6x6 board, the carpet under (3,3) (4,3) (3,4): 1-based core cells 15, 16, 21
local function carpet_level()
	return core_helper.level({ "######", "######", "######", "######", "######", "######" },
		{ moves = 30, goals = { { type = "carpet" } }, carpet = { { 2, 2 }, { 3, 2 }, { 2, 3 } } })
end

local function boot_app()
	analytics.init({ strict = true })
	app.init({
		districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
		now = H.T0, clock = function() return H.T0 end, sys_language = "en",
	})
	i18n.set_language("en")
end

describe("the carpet in the client", function()
	it("has its picture in the game atlas, with a copy for the start window", function()
		local img = assets.images[level_carpet.IMAGE]
		assert_true(img ~= nil, "blockers/carpet is in the index")
		assert_same({ img.atlas, img.anim, img.w, img.h }, { "game", "blockers_carpet", 160, 160 })
		assert_same(img.also, { "meta" })
		-- a square tile a little smaller than the cell
		assert_true(level_carpet.INSET > 0.8 and level_carpet.INSET < 1)
		assert_near(level_carpet.size(100), 100 * level_carpet.INSET, 1e-9)
		assert_true(level_carpet.POP.from > 0 and level_carpet.POP.from < 1 and level_carpet.POP.time > 0)
	end)

	it("has its name, its description and its lesson line in three languages", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			i18n.set_language(lang)
			for _, key in ipairs({ "blocker.carpet", "blocker.carpet_desc", "tutorial.carpet" }) do
				local text = i18n.t(key)
				assert_true(type(text) == "string" and text ~= "" and text ~= key, lang .. " " .. key)
			end
		end
		i18n.set_language("ru")
		assert_eq(i18n.t("blocker.carpet"), "Ковёр")
		assert_eq(i18n.t("blocker.carpet_desc"), "Собери ряд на ковре, и ковёр расстелется под всем рядом.")
		assert_eq(i18n.t("tutorial.carpet"), "Собери ряд на ковре: он расстелется дальше!")
		i18n.set_language("en")
		assert_eq(i18n.t("blocker.carpet"), "Carpet")
	end)

	it("is a goal with the carpet as its icon and the bare cells as its number", function()
		local goals = levels.goals(carpet_level())
		assert_eq(#goals, 1)
		assert_same({ goals[1].kind, goals[1].image, goals[1].count, goals[1].label.key }, { "carpet", "blockers/carpet", 33, "blocker.carpet" })
		-- the number is what the core counts
		local lvl = assert(require("core.game").load_level(carpet_level()))
		assert_eq(lvl.goals[1].count, 33)
		-- voids are not cells; a cell listed twice or off the board does not count twice
		assert_eq(level_carpet.count({ cells = { "##.", "###" }, carpet = { { 0, 0 }, { 0, 0 }, { 2, 0 }, { 9, 9 } } }), 4)
		assert_eq(level_carpet.count({ cells = { "##" }, carpet = { { 0, 0 }, { 1, 0 } } }), nil)
		assert_eq(level_carpet.count({ cells = { "##" } }), nil)
		assert_eq(level_carpet.count(nil), nil)
	end)

	it("knows a carpet board by its cells", function()
		assert_false(level_carpet.active({ { exists = true }, { exists = true } }))
		assert_true(level_carpet.active({ { exists = true }, { exists = true, carpet = true } }))
		assert_false(level_carpet.active(nil))
	end)

	it("sounds like a lit floor tile, softer and lower, and not once a cell when a whole row is covered", function()
		local calls = {}
		local a = {}
		function a.sfx(name, opts) calls[#calls + 1] = { name, opts } end
		function a.play_note() end
		function a.layer() end
		function a.combo() end
		local t = 0
		local la = level_audio.new({ audio = a, now = function() return t end })
		la:events({ { type = "carpet", x = 1, y = 1 }, { type = "carpet", x = 2, y = 1 }, { type = "carpet", x = 3, y = 1 } })
		assert_eq(#calls, 1)
		assert_eq(calls[1][1], "floor_light")
		assert_true(calls[1][2].gain < 1 and calls[1][2].speed < 1)
		t = 1
		la:events({ { type = "carpet", x = 4, y = 1 } })
		assert_eq(#calls, 2)
	end)
end)

describe("screens/level/level_bg.gui_script with the carpet (core-rules 10.8)", function()
	-- fn(c): c.rugs() = the carpet nodes, c.shown() = those that are drawn, c.cover(x, y) = the core covers that
	-- cell (the board's floor_rev goes up and the script runs one frame), c.resize(), c.step(n).
	local function with_carpet(fn, plain)
		local stubE = stub.install({})
		local ok, err = pcall(function()
			boot_app()
			stubE.use_gui("/screens/level/level_bg.gui")
			local script = stub.load_script("screens/level/level_bg.gui_script")
			local self = {}
			script.init(self)
			local level = carpet_level()
			if plain then
				level.carpet = nil
				level.goals = { { type = "collect", color = "red", count = 99 } }
			end
			local s = assert(level_session.new({ params = { level = 7, level_text = level } }))
			local cells = s.game:cells()
			local floor0 = {}
			for i = 1, #cells do floor0[i] = cells[i].floor or 0 end
			local g = level_geom.new(s.W, s.H, cells, { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })
			local view = { rev = 1, floor_rev = 0, cells = cells, floor0 = floor0, lit = {}, deliver = false,
				carpet = level_carpet.active(cells), shake_x = 0, shake_y = 0, W = s.W, H = s.H, geom = g }
			link.attach({ session = s, input = {}, geom = g, view = view })
			script.update(self, DT)
			local c = { E = stubE, view = view, cells = cells, geom = g }
			function c.rugs()
				local out = {}
				for _, n in ipairs(stubE.gui.nodes) do
					if not n.dead and n.anim == "blockers_carpet" then out[#out + 1] = n end
				end
				return out
			end
			function c.shown()
				local out = {}
				for _, n in ipairs(c.rugs()) do
					if n.enabled ~= false then out[#out + 1] = n end
				end
				return out
			end
			function c.step(n)
				for _ = 1, n or 1 do
					stubE.advance(DT)
					script.update(self, DT)
				end
			end
			function c.cover(x, y)
				cells[(y - 1) * s.W + x].carpet = true
				view.floor_rev = view.floor_rev + 1
				c.step(1)
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
		for _, n in ipairs(c.shown()) do
			if math.abs(n.pos.x - lx) < 0.5 and math.abs(n.pos.y - ly) < 0.5 then return n end
		end
		return nil
	end

	it("draws the carpet over the covered cells only, a square a little smaller than the cell, over the cell tiles", function()
		with_carpet(function(c)
			assert_eq(#c.rugs(), 36) -- one for every cell, made once
			assert_eq(#c.shown(), 3)
			for _, xy in ipairs({ { 3, 3 }, { 4, 3 }, { 3, 4 } }) do
				local n = at(c, xy[1], xy[2])
				assert_true(n ~= nil, "a carpet at " .. xy[1] .. "," .. xy[2])
				assert_near(n.size.x, c.geom.cell * level_carpet.INSET, 1e-6)
				assert_near(n.size.y, n.size.x, 1e-6)
			end
			assert_eq(at(c, 5, 3), nil)
			-- the cell tiles are all there, under it: a carpet node comes after every cell tile
			local last_tile, first_rug = 0, nil
			for k, n in ipairs(c.E.gui.nodes) do
				if not n.dead and (n.anim == "board_cell_a" or n.anim == "board_cell_b") then last_tile = k end
				if not n.dead and n.anim == "blockers_carpet" and not first_rug then first_rug = k end
			end
			assert_true(first_rug > last_tile, "the carpet is drawn after (over) the cell tiles")
		end)
	end)

	it("unrolls a newly covered cell with a pop that settles, without adding a node", function()
		with_carpet(function(c)
			local nodes = c.E.gui_stats().nodes
			c.cover(5, 3)
			assert_eq(#c.shown(), 4)
			local n = at(c, 5, 3)
			assert_true(n ~= nil)
			assert_true(n.scale.x < 0.9, "it starts small: " .. n.scale.x)
			c.step(40)
			assert_eq(n.scale.x, 1)
			assert_eq(c.E.gui_stats().nodes, nodes)
			assert_eq(c.E.gui_stats().anims, 0)
			-- the others did not move
			assert_eq(at(c, 3, 3).scale.x, 1)
		end)
	end)

	it("with reduced motion the carpet is just there", function()
		with_carpet(function(c)
			app.set_setting("reduced_motion", true)
			c.cover(5, 3)
			local n = at(c, 5, 3)
			assert_true(n ~= nil)
			assert_eq(n.scale.x, 1)
			assert_eq(c.E.gui_stats().anims, 0)
			app.set_setting("reduced_motion", false)
		end)
	end)

	it("keeps what is covered through a rebuild (the window changed) and leaks nothing", function()
		with_carpet(function(c)
			c.cover(5, 3)
			c.step(40)
			local nodes = c.E.gui_stats().nodes
			c.resize()
			assert_eq(c.E.gui_stats().nodes, nodes)
			assert_eq(#c.shown(), 4)
			assert_true(at(c, 5, 3) ~= nil)
			assert_eq(at(c, 5, 3).scale.x, 1) -- a rebuild does not unroll it again
		end)
	end)

	it("a level without the carpet has no carpet node at all", function()
		with_carpet(function(c)
			assert_eq(#c.rugs(), 0)
		end, true)
	end)
end)
