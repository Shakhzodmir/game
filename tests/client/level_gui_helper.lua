-- Fixtures for the tests of the level HUD on the strict GUI stub (not a test file itself):
--
--   local G = require("tests.client.level_gui_helper")
--   G.with_level({level = 3, window = {720, 1280}, language = "en", setup = function(app) ... end}, function(c)
--       -- c = {E, app, fb (the fake board), hud (the level.gui_script), overlay, step(n), run(seconds),
--       --      tap(lx, ly) (logical coordinates), tap_target(name) (of the top window), texts(), has(text),
--       --      popup() (name of the top window)}
--   end)
-- The attempt is open in the meta when the level has a number and opts.attempt ~= false, like after the
-- start window (client/flow.lua): the level screen then closes it through the meta.

local town_stub = require("tests.client.town_defold_stub")
local fake_board = require("tests.client.level_fake_board")

local G = {}

-- Wins `n` levels through the meta without a board.
function G.win(app, n)
	local flow = require("client.flow")
	for _ = 1, n or 1 do assert(flow.debug_win(3)) end
end

-- opts: {level = n, window, safe, language, setup = fn(app) (before the attempt starts), ready = fn(app, c) (after it),
--        attempt = true, hours = hours to wait after the levels before it (the unlimited lives of the chests),
--        level_text = a level JSON for the board instead of the file,
--        boosters = {pre-level boosters}, input_mode, overlay = true, tutorials = defs (inline fixture)}
function G.with_level(opts, fn)
	opts = opts or {}
	local E = town_stub.boot(opts)
	local fb
	local ok, err = pcall(function()
		local app = require("client.app")
		local flow = require("client.flow")
		local tutorial = require("client.tutorial")
		local c = { E = E, app = app }
		tutorial._reset()
		tutorial.read = function() return opts.tutorials and require("tools.lib.json").encode(opts.tutorials) or nil end
		tutorial.decode = require("tools.lib.json").decode
		if opts.setup then opts.setup(app, c) end
		if opts.input_mode then app.set_setting("input_mode", opts.input_mode) end
		local level = opts.level or 1
		local run
		if opts.attempt ~= false then
			local ref = flow.level_ref(level)
			-- the meta refuses a level that is not the next one: play on until it is
			while app.meta:level_to_play() and app.meta:level_to_play() < level do G.win(app, 1) end
			if opts.hours then E.clock = E.clock + opts.hours * 3600 end
			run = assert(app.meta:start_level(ref, opts.boosters or {}, app.now()))
			app.commit("level_start")
		end
		if opts.ready then opts.ready(app, c) end -- the attempt is open: the stock, the coins
		E.window_size = { w = E.window.w, h = E.window.h }
		if opts.overlay ~= false then
			c.overlay = E.script("main/overlay.gui_script", "/main/overlay.gui", { url = "main:/overlay#overlay" })
			c.overlay:init()
			c.overlay:message("fade_in", { duration = 0.25 }, msg.url("main:/app"))
		end
		fb = fake_board.new({ level = level, text = opts.level_text, window = { E.window.w, E.window.h }, insets = opts.insets,
			run = run })
		c.fb = fb
		app.params = { level_id = level, level = level, run = run, from = "town" }
		c.hud = E.script("screens/level/level.gui_script", "/screens/level/level.gui")
		c.hud:init()
		app.set_screen("level", app.params)
		function c.step(n)
			for _ = 1, n or 1 do
				fb:advance(1 / 60)
				E.step(1)
			end
		end
		function c.run(seconds) c.step(math.ceil(seconds * 60)) end
		function c.tap(lx, ly) return E.tap(lx, ly) end
		function c.texts() return c.hud:texts(true) end
		function c.has(text) return c.hud:has_text(text, true) end
		function c.popup() return app.ui.popup end
		function c.cell(x, y) return fb.geom:center(x, y) end
		-- a tap on a named target of the top window (client/popups.lua e:target)
		function c.tap_target(name)
			local t = app.ui.popup_targets and app.ui.popup_targets[name]
			assert(t, "no popup target '" .. name .. "' in " .. tostring(app.ui.popup))
			return E.tap(t.x, t.y)
		end
		fb:ready()
		c.step(5)
		local ok2, err2 = pcall(fn, c)
		if not ok2 then error(err2, 0) end
	end)
	if fb then fb:detach() end
	require("client.level_link").clear_guard()
	town_stub.shutdown()
	if not ok then error(err, 0) end
end

return G
