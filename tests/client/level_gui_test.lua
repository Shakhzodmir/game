-- The GUI scripts of the level board (screens/level/level_bg.gui_script and
-- level_fx.gui_script) on the strict Defold stub: bus events in, nodes out.

local stub = require("tests.client.level_defold_stub")
local app = require("client.app")
local bus = require("client.bus")
local i18n = require("client.i18n")
local link = require("client.level_link")
local level_geom = require("client.level_geom")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local H = require("tests.meta.helper")

local DT = 1 / 60

local function boot_app()
	analytics.init({ strict = true })
	app.init({
		districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
		now = H.T0, clock = function() return H.T0 end, sys_language = "en",
	})
	i18n.set_language("en")
end

-- Runs fn(E, script, self, step) with the GUI script `path` initialised on scene `gui_path`.
local function with_gui(script_path, gui_path, fn)
	local E = stub.install({})
	local ok, err = pcall(function()
		boot_app()
		E.use_gui(gui_path)
		local script = stub.load_script(script_path)
		local self = {}
		script.init(self)
		local function step(n)
			for _ = 1, n or 1 do
				E.advance(DT)
				script.update(self, DT)
			end
		end
		local ok2, err2 = pcall(fn, E, script, self, step)
		pcall(script.final, self)
		if not ok2 then error(err2, 0) end
	end)
	link.board = nil
	stub.restore()
	if not ok then error(err, 0) end
end

local function has_text(E, text)
	for _, t in ipairs(E.gui_texts()) do
		if t == text then return true end
	end
	return false
end

describe("screens/level/level_fx.gui_script", function()
	it("shows the title of a combo over its cell and takes it away again", function()
		with_gui("screens/level/level_fx.gui_script", "/screens/level/level_fx.gui", function(E, script, self, step)
			local base = E.gui_stats().nodes
			bus.publish("level_special", { special = "sub", lx = 360, ly = 640 }) -- a single special: no title
			step(2)
			assert_eq(E.gui_stats().nodes, base)
			bus.publish("level_special", { special = "sub", combo = "bass_drop", lx = 360, ly = 640 })
			step(2)
			assert_true(has_text(E, "Bass drop!"))
			step(120) -- 2 s: the word floated away
			assert_false(has_text(E, "Bass drop!"))
			assert_eq(E.gui_stats().nodes, base)
			i18n.set_language("ru")
			bus.publish("level_special", { special = "disco", combo = "finale", lx = 100, ly = 100 })
			step(2)
			assert_true(has_text(E, "Гранд-финал!"))
			i18n.set_language("en")
		end)
	end)

	it("has a title for each of the ten combos in both languages", function()
		local level_effects = require("client.level_effects")
		for _, name in ipairs(level_effects.COMBOS) do
			for _, lang in ipairs({ "en", "ru" }) do
				i18n.set_language(lang)
				assert_true(i18n.has("combo." .. name), name .. " has no title")
				assert_true(#i18n.t("combo." .. name) > 2)
			end
		end
		i18n.set_language("en")
	end)

	it("praises, banners and flashes come and go without leaking nodes", function()
		with_gui("screens/level/level_fx.gui_script", "/screens/level/level_fx.gui", function(E, script, self, step)
			local base = E.gui_stats().nodes
			bus.publish("level_praise", { word = "hit", index = 2, wave = 5 })
			bus.publish("level_banner", { key = "hud.shuffle" })
			bus.publish("level_flash", { color = "#FFFFFF", alpha = 0.9, dur = 0.5 })
			step(3)
			assert_true(has_text(E, "Hit!"))
			assert_true(has_text(E, "No moves — shuffling!"))
			assert_true(E.gui_stats().nodes > base)
			step(180)
			assert_eq(E.gui_stats().nodes, base)
		end)
	end)

	it("rains confetti through the final concert and stops with it", function()
		with_gui("screens/level/level_fx.gui_script", "/screens/level/level_fx.gui", function(E, script, self, step)
			local base = E.gui_stats().nodes
			bus.publish("level_state", { state = "won_wait" })
			step(2)
			assert_true(has_text(E, "Tap to skip"))
			bus.publish("level_state", { state = "concert" })
			step(2)
			assert_true(has_text(E, "Final concert!"))
			step(240) -- 4 s of concert
			local during = E.gui_stats().nodes
			assert_true(during > base + 20, "a shower of confetti: " .. during)
			assert_true(E.gui_stats().peak < 512, "under max_nodes of level_fx.gui")
			bus.publish("level_state", { state = "complete" })
			step(360) -- the last pieces fall off
			assert_false(has_text(E, "Tap to skip"))
			assert_true(E.gui_stats().nodes <= base + 2, "confetti is gone: " .. E.gui_stats().nodes)
		end)
	end)
end)

describe("screens/level/level_bg.gui_script", function()
	it("draws the board backing, the cells and the floor tiles of the level", function()
		local level_session = require("client.level_session")
		local stubE = stub.install({})
		local ok, err = pcall(function()
			boot_app()
			stubE.use_gui("/screens/level/level_bg.gui")
			local script = stub.load_script("screens/level/level_bg.gui_script")
			local self = {}
			script.init(self)
			assert_eq(link.view(), nil) -- no board yet: nothing to draw
			script.update(self, DT)
			local s = assert(level_session.new({ params = { level = 7, level_text = [[{
  "id": 7, "version": 1, "size": [6, 6], "moves": 12, "difficulty": "easy",
  "colors": ["red", "yellow", "green", "blue"],
  "goals": [{"type": "light"}],
  "cells": ["######", "######", "######", "######", "######", "######"],
  "floor": [{"at": [2, 2], "hp": 2}, {"at": [3, 2], "hp": 1}]
}]] } }))
			local cells = s.game:cells()
			local floor0 = {}
			for i = 1, #cells do floor0[i] = cells[i].floor or 0 end
			local g = level_geom.new(s.W, s.H, cells, { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })
			local view = { rev = 1, floor_rev = 0, cells = cells, floor0 = floor0, lit = {}, deliver = false,
				shake_x = 0, shake_y = 0, W = s.W, H = s.H, geom = g }
			link.attach({ session = s, input = {}, geom = g, view = view })
			script.update(self, DT)
			local after_build = stubE.gui_stats().nodes
			assert_true(after_build > 36, "36 cells and a frame: " .. after_build)
			-- a floor tile is hit: the same node set, no growth
			cells[(2 - 1) * 6 + 2].floor = 1
			view.floor_rev = view.floor_rev + 1
			script.update(self, DT)
			assert_eq(stubE.gui_stats().nodes, after_build)
			-- the shake moves the board layer
			view.shake_x, view.shake_y = 4, -3
			script.update(self, DT)
			-- a new layout (window resized) rebuilds without leaking
			view.rev = view.rev + 1
			script.update(self, DT)
			assert_eq(stubE.gui_stats().nodes, after_build)
			pcall(script.final, self)
		end)
		link.board = nil
		stub.restore()
		if not ok then error(err, 0) end
	end)

	-- The dance floor on a small level: a two-layer tile (core cell 3, 3) and a one-layer tile (cell 4, 3) among
	-- 34 ordinary cells. fn(c): c.count(anim) = how many cells show that picture, c.find(anim) = the first node
	-- showing it, c.hit(x, y, hp) = the core says that cell has `hp` left (the board's floor_rev goes up and
	-- the script runs one frame), c.resize() = the window changed (a rebuild), c.step(n).
	local function with_floor(fn)
		local level_session = require("client.level_session")
		local stubE = stub.install({})
		local ok, err = pcall(function()
			boot_app()
			stubE.use_gui("/screens/level/level_bg.gui")
			local script = stub.load_script("screens/level/level_bg.gui_script")
			local self = {}
			script.init(self)
			local s = assert(level_session.new({ params = { level = 7, level_text = [[{
  "id": 7, "version": 1, "size": [6, 6], "moves": 12, "difficulty": "easy",
  "colors": ["red", "yellow", "green", "blue"],
  "goals": [{"type": "light"}],
  "cells": ["######", "######", "######", "######", "######", "######"],
  "floor": [{"at": [2, 2], "hp": 2}, {"at": [3, 2], "hp": 1}]
}]] } }))
			local cells = s.game:cells()
			local floor0 = {}
			for i = 1, #cells do floor0[i] = cells[i].floor or 0 end
			local g = level_geom.new(s.W, s.H, cells, { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })
			local view = { rev = 1, floor_rev = 0, cells = cells, floor0 = floor0, lit = {}, deliver = false,
				shake_x = 0, shake_y = 0, W = s.W, H = s.H, geom = g }
			link.attach({ session = s, input = {}, geom = g, view = view })
			script.update(self, DT)
			local c = { E = stubE, view = view, cells = cells }
			function c.find(anim)
				for _, n in ipairs(stubE.gui.nodes) do
					if not n.dead and n.anim == anim then return n end
				end
				return nil
			end
			function c.count(anim)
				local k = 0
				for _, n in ipairs(stubE.gui.nodes) do
					if not n.dead and n.anim == anim then k = k + 1 end
				end
				return k
			end
			function c.step(n)
				for _ = 1, n or 1 do
					stubE.advance(DT)
					script.update(self, DT)
				end
			end
			function c.hit(x, y, hp)
				cells[(y - 1) * s.W + x].floor = hp
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

	it("draws the unlit floor violet, a two-layer tile apart from a one-layer tile, the rest as plain cells", function()
		with_floor(function(c)
			assert_eq(c.count("blockers_floor_2"), 1) -- two layers
			assert_eq(c.count("blockers_floor_1"), 1) -- one layer
			assert_eq(c.count("blockers_floor_half"), 0)
			assert_eq(c.count("blockers_floor_lit"), 0) -- nothing is lit yet: no gold anywhere at the start
			assert_eq(c.count("board_cell_a") + c.count("board_cell_b"), 34)
		end)
	end)

	it("takes a two-layer tile violet -> violet with a gold core -> gold, a one-layer tile violet -> gold", function()
		with_floor(function(c)
			c.hit(3, 3, 1) -- the first hit of the two-layer tile
			assert_eq(c.count("blockers_floor_2"), 0)
			assert_eq(c.count("blockers_floor_half"), 1)
			assert_eq(c.count("blockers_floor_lit"), 0) -- one more hit is needed: not lit yet
			c.hit(4, 3, 0) -- the one-layer tile: its only hit lights it, no half stage
			assert_eq(c.count("blockers_floor_1"), 0)
			assert_eq(c.count("blockers_floor_half"), 1)
			assert_eq(c.count("blockers_floor_lit"), 1)
			c.hit(3, 3, 0) -- the second hit of the two-layer tile
			assert_eq(c.count("blockers_floor_half"), 0)
			assert_eq(c.count("blockers_floor_lit"), 2)
			assert_eq(c.count("board_cell_a") + c.count("board_cell_b"), 34) -- the plain cells never change
		end)
	end)

	it("pops a tile that changes its look and lets it settle, the lit pop bigger than the half-lit one", function()
		with_floor(function(c)
			local before = c.E.gui_stats().nodes
			c.hit(3, 3, 1)
			local half = c.find("blockers_floor_half")
			assert_true(half.scale.x > 1.05, "the half-lit tile pops: " .. half.scale.x)
			c.hit(4, 3, 0)
			local lit = c.find("blockers_floor_lit")
			assert_true(lit.scale.x > half.scale.x, "the lit pop is the bigger one: " .. lit.scale.x)
			c.step(40) -- 0.67 s: both have settled
			assert_eq(half.scale.x, 1)
			assert_eq(lit.scale.x, 1)
			assert_eq(c.E.gui_stats().nodes, before) -- no node was added for the pops
			assert_eq(c.E.gui_stats().anims, 0)
		end)
	end)

	it("does not pop a tile with reduced motion, the picture changes all the same", function()
		with_floor(function(c)
			app.set_setting("reduced_motion", true)
			c.hit(4, 3, 0)
			local lit = c.find("blockers_floor_lit")
			assert_true(lit ~= nil)
			assert_eq(lit.scale.x, 1)
			assert_eq(c.E.gui_stats().anims, 0)
		end)
	end)

	it("keeps the stage of every tile when the board is laid out again", function()
		with_floor(function(c)
			c.hit(3, 3, 1)
			c.hit(4, 3, 0)
			c.resize() -- a new window size rebuilds the nodes from what the core says now
			assert_eq(c.count("blockers_floor_half"), 1)
			assert_eq(c.count("blockers_floor_lit"), 1)
			assert_eq(c.count("blockers_floor_2"), 0)
			assert_eq(c.count("blockers_floor_1"), 0)
			assert_eq(c.count("board_cell_a") + c.count("board_cell_b"), 34)
		end)
	end)
end)
