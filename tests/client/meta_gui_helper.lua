-- Fixtures for the tests that run the meta GUI scripts on the strict stub (not a test file itself).
--
--   local G = require("tests.client.meta_gui_helper")
--   G.with_town({language = "en", window = {720, 1280}, setup = function(app) G.win(app, 3) end},
--     function(c)               -- c = {E, app, overlay, town, step(n), run(seconds), tap(lx, ly)}
--       c.town:tap_text("Level 4")
--     end)

local town_stub = require("tests.client.town_defold_stub")

local G = {}

-- Wins `n` levels through the meta (no board): stars, coins, chests as in the game.
function G.win(app, n)
	local flow = require("client.flow")
	local res
	for _ = 1, n or 1 do res = assert(flow.debug_win(3)) end
	return res
end

-- A star balance for tasks (the meta only pays stars for wins: this is test setup).
function G.give_stars(app, n)
	app.meta:_change("test_stars", { { "stars", n } })
	app.commit("test")
end

-- Builds the first `count` tasks of a district straight through the meta (all of them without count).
function G.build_tasks(app, district, count)
	local d = app.meta:district(district)
	local need = 0
	for i, t in ipairs(d.tasks) do
		if not t.done and (count == nil or i <= count) then need = need + t.cost end
	end
	G.give_stars(app, need)
	for i, t in ipairs(d.tasks) do
		if not t.done and (count == nil or i <= count) then assert(app.meta:complete_task(district, t.id)) end
	end
	app.commit("test")
end

-- Boots the stub and the app on the real content, creates the overlay (faded in) and the town, and
-- runs fn(c). opts: {window, safe, language, setup = fn(app) before the town exists, town = false
-- (no town script)}. Always shuts the stub down.
function G.with_town(opts, fn)
	opts = opts or {}
	local E = town_stub.boot(opts)
	local ok, err = pcall(function()
		local app = require("client.app")
		local c = { E = E, app = app }
		c.overlay = E.script("main/overlay.gui_script", "/main/overlay.gui", { url = "main:/overlay#overlay" })
		c.overlay:init()
		c.overlay:message("fade_in", { duration = 0.25 }, msg.url("main:/app"))
		if opts.setup then opts.setup(app, c) end
		if opts.town ~= false then
			c.town = E.script("screens/town/town.gui_script", "/screens/town/town.gui")
			c.town:init()
			app.set_screen("town", {})
		end
		E.step(30)
		function c.step(n) E.step(n) end
		function c.run(seconds) E.run(seconds) end
		function c.tap(lx, ly) return E.tap(lx, ly) end
		fn(c)
	end)
	town_stub.shutdown()
	if not ok then error(err, 0) end
end

-- The texts of a script's scene as one string (for readable failures).
function G.dump(script)
	return table.concat(script:texts(true), " | ")
end

return G
