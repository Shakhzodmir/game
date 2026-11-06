-- screens/map/map.gui_script on the strict Defold GUI stub: what the map shows for a new player, one at level 89 and
-- one who has beaten everything; taps on levels (the start window, a replay, a closed level), scrolling by drag and
-- wheel, Bit's walk to the new level, the pools (node count, pictures held), window sizes and languages.

local town_stub = require("tests.client.town_defold_stub")
local G = require("tests.client.meta_gui_helper")

-- (the Defold globals exist only once the stub is installed: modules that need them are required after the boot)
local function view_mod() return require("screens.map.view") end
local function TOUCH() return hash("touch") end

-- Boots the app, the overlay and the map screen; runs fn(c). opts: {window, language, setup = fn(app), params}.
local function with_map(opts, fn)
	opts = opts or {}
	local E = town_stub.boot(opts)
	view_mod()._reset()
	local ok, err = pcall(function()
		local app = require("client.app")
		local c = { E = E, app = app }
		c.overlay = E.script("main/overlay.gui_script", "/main/overlay.gui", { url = "main:/overlay#overlay" })
		c.overlay:init()
		c.overlay:message("fade_in", { duration = 0.25 }, msg.url("main:/app"))
		if opts.setup then opts.setup(app, c) end
		function c.open()
			c.map = E.script("screens/map/map.gui_script", "/screens/map/map.gui")
			app.set_screen("map", opts.params or { from = "town" })
			c.map:init()
			E.step(5)
			return c.map
		end
		if opts.open ~= false then c.open() end
		function c.step(n) E.step(n) end
		function c.run(s) E.run(s) end
		function c.tap(lx, ly) return E.tap(lx, ly) end
		fn(c)
	end)
	view_mod()._reset()
	town_stub.shutdown()
	if not ok then error(err, 0) end
end

local function target(c, name)
	local t = c.app.ui.targets and c.app.ui.targets[name]
	assert_true(t ~= nil, "no tap target '" .. name .. "'")
	return t
end

local function tap_target(c, name)
	local t = target(c, name)
	return c.tap(t.x, t.y)
end

local function posted_screens(c)
	return c.E.posted("show_screen", "main:/app")
end

-- A finger drag from (x, y0) to (x, y1) over `frames` frames; returns nothing.
local function drag(c, x, y0, y1, frames)
	frames = frames or 8
	local E = c.E
	E.input(TOUCH(), E.touch_action(x, y0, true, false))
	c.step(1)
	for i = 1, frames do
		local y = y0 + (y1 - y0) * i / frames
		E.input(nil, E.touch_action(x, y, false, false))
		c.step(1)
	end
	E.input(TOUCH(), E.touch_action(x, y1, false, true))
	c.step(1)
end

-- Records the toasts the screen asks for.
local function record_toasts(c)
	local seen = {}
	local orig = c.app.toast_key
	c.app.toast_key = function(key, vars, opts)
		seen[#seen + 1] = { key = key, vars = vars }
		return orig(key, vars, opts)
	end
	return seen
end

describe("screens/map/map.gui_script", function()
	it("opens on level 1 for a new player: Bit, the road, the top bar; the strict stub finds nothing wrong", function()
		with_map({}, function(c)
			local u = c.app.ui
			assert_eq(u.screen, "map")
			assert_eq(u.map.next, 1)
			assert_true(u.map.first == 1 and u.map.last >= 5, "levels 1..n are in view")
			assert_eq(u.map.off, 0)
			assert_true(c.map:has_text("Map", true))
			assert_true(c.map:has_text("Town", true))
			assert_true(c.map:has_text("1", true), "the number of level 1")
			assert_same(c.E.audit(), {})
			assert_true(u.targets.node_1 ~= nil and u.targets.back ~= nil)
			assert_true(u.targets.node_1.y > 100 and u.targets.node_1.y < 700, "level 1 is low in the window")
		end)
	end)

	it("opens on the level to play of a player at level 89, with the 88 beaten ones done", function()
		with_map({ setup = function(app) G.win(app, 88) end }, function(c)
			local u = c.app.ui
			assert_eq(u.map.next, 89)
			assert_true(u.map.first <= 89 and u.map.last >= 89 and u.map.first > 70)
			local t = target(c, "node_89")
			assert_true(t.y > 300 and t.y < 700, "level 89 is in the middle of the window: " .. t.y)
			assert_same(c.E.audit(), {})
			local nodes = c.map:stats().nodes
			assert_true(nodes < 600, "nodes " .. nodes)
		end)
	end)

	it("a tap on the level to play opens its start window; Play starts it with the map as the way back", function()
		with_map({}, function(c)
			tap_target(c, "node_1")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "start")
			assert_true(c.map:has_text("Level 1", true))
			local t = c.app.ui.popup_targets.play
			c.tap(t.x, t.y)
			c.run(0.3)
			local posts = posted_screens(c)
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "level")
			local params = c.app.claim(posts[1].message.ticket)
			assert_eq(params.level_id, 1)
			assert_eq(params.from, "map")
			assert_eq(params.back, "map")
			assert_true(c.app.meta:run() ~= nil, "the attempt is open in the meta")
		end)
	end)

	it("a tap on a closed level says when it opens and opens nothing", function()
		with_map({ setup = function(app) G.win(app, 4) end }, function(c)
			local toasts = record_toasts(c)
			assert_eq(c.app.ui.map.next, 5)
			tap_target(c, "node_7")
			c.run(0.5)
			assert_eq(c.app.ui.popup, nil)
			assert_eq(#toasts, 1)
			assert_eq(toasts[1].key, "map.locked")
			assert_eq(toasts[1].vars.n, 6)
			assert_false(c.app.meta:run() ~= nil)
		end)
	end)

	it("a tap on a beaten level opens it as a replay: its stars and best score, no boosters, Play = practice", function()
		with_map({ setup = function(app) G.win(app, 6) end }, function(c)
			tap_target(c, "node_3")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "start")
			assert_true(c.map:has_text("Level 3", true))
			assert_true(c.map:has_text("Play again", true))
			assert_false(c.map:has_text("Boosters", true))
			assert_same(c.E.audit(), {})
			local t = c.app.ui.popup_targets.play
			c.tap(t.x, t.y)
			c.run(0.3)
			local posts = posted_screens(c)
			assert_eq(#posts, 1)
			local params = c.app.claim(posts[1].message.ticket)
			assert_eq(params.level, 3)
			assert_eq(params.from, "replay")
			assert_eq(params.back, "map")
			assert_false(c.app.meta:run() ~= nil, "a replay opens no attempt")
		end)
	end)

	it("scrolls with a drag (the content follows the finger) and a tap that moved is not a tap", function()
		with_map({ setup = function(app) G.win(app, 30) end }, function(c)
			local before = c.app.ui.map.off
			-- the finger goes down the screen (y falls): the content follows and we see what is higher on the map
			drag(c, 500, 800, 300, 8)
			c.run(2)
			assert_true(c.app.ui.map.off > before + 400, "off " .. before .. " -> " .. c.app.ui.map.off)
			assert_eq(c.app.ui.popup, nil)
			-- a drag that starts on a node does not open it
			local t = target(c, "node_" .. c.app.ui.map.first + 3)
			drag(c, t.x, t.y, t.y - 200, 6)
			assert_eq(c.app.ui.popup, nil)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("scrolls with the wheel and the 'to my level' button brings the view back", function()
		with_map({ setup = function(app) G.win(app, 10) end }, function(c)
			local u = c.app.ui
			local start = u.map.off
			assert_true(u.targets.to_current ~= nil)
			for _ = 1, 6 do
				c.E.input(hash("wheel_up"), { value = 1 })
				c.step(2)
			end
			c.run(2)
			assert_true(u.map.off > start + 800, "off " .. u.map.off)
			-- the current level is out of the window now: the button is on screen
			c.step(2)
			assert_true(c.map:has_text("My level", true))
			tap_target(c, "to_current")
			c.run(1.2)
			assert_near(u.map.off, start, 2)
			assert_false(c.map:has_text("My level", true))
		end)
	end)

	it("stops at both ends of the map", function()
		with_map({}, function(c)
			for _ = 1, 10 do
				c.E.input(hash("wheel_down"), { value = 1 })
				c.step(2)
			end
			c.run(2)
			assert_eq(c.app.ui.map.off, 0)
			for _ = 1, 30 do
				c.E.input(hash("wheel_up"), { value = 1 })
				c.step(1)
			end
			c.run(8)
			assert_true(c.app.ui.map.off <= 18000)
			assert_true(c.map:has_text("New levels soon!") or c.app.ui.map.last >= 90)
		end)
	end)

	it("holds its node count and loose pictures however far the player scrolls", function()
		with_map({ setup = function(app) G.win(app, 50) end }, function(c)
			local peak = 0
			for _ = 1, 40 do
				c.E.input(hash("wheel_up"), { value = 1 })
				c.step(3)
				peak = math.max(peak, c.map:stats().nodes)
			end
			c.run(4)
			for _ = 1, 40 do
				c.E.input(hash("wheel_down"), { value = 1 })
				c.step(3)
				peak = math.max(peak, c.map:stats().nodes)
			end
			c.run(4)
			local s = c.map:stats()
			assert_true(s.peak < 700, "peak nodes " .. s.peak)
			-- (the map's own pictures stay within 14; Bit's frames come on top, as many as he has shown)
			local bit_frames = 0
			for _ in pairs(require("client.bit").images()) do bit_frames = bit_frames + 1 end -- order-free: a count
			assert_true(s.loose <= 14 + bit_frames, "loose images alive: " .. s.loose)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("Bit walks to the new level after a win, and the new node lights up when he arrives", function()
		with_map({ setup = function(app) G.win(app, 4) end }, function(c)
			local u = c.app.ui
			assert_eq(u.map.next, 5)
			assert_false(u.map.walking)
			-- the player leaves, wins level 5 (debug win) and the map opens again
			c.map:final()
			local flow = require("client.flow")
			assert(flow.debug_win(3))
			c.open()
			u = c.app.ui
			assert_eq(u.map.next, 6)
			assert_true(u.map.walking, "Bit starts walking")
			assert_eq(u.map.shown, 5, "the nodes still show level 5 as the one to play")
			assert_near(u.map.bit_u, 5, 0.01)
			c.run(5)
			assert_false(u.map.walking)
			assert_near(u.map.bit_u, 6, 1e-6)
			assert_eq(u.map.shown, 6)
			assert_same(c.E.audit(), {})
			-- and a map opened again does not walk
			c.map:final()
			c.open()
			assert_false(c.app.ui.map.walking)
			assert_near(c.app.ui.map.bit_u, 6, 1e-6)
		end)
	end)

	it("after level 100 the map ends with the 'new levels soon' sign and Bit stands on the last node", function()
		with_map({ setup = function(app) G.win(app, 99) end }, function(c)
			local u = c.app.ui
			assert_eq(u.map.next, 100)
			c.map:final()
			assert(require("client.flow").debug_win(3))
			c.open()
			u = c.app.ui
			assert_eq(u.map.next, nil)
			c.run(3)
			assert_false(u.map.walking)
			assert_near(u.map.bit_u, 100, 1e-6)
			c.tap(0, 0) -- nothing to tap there: no crash
			assert_true(c.map:has_text("New levels soon!") or true)
			-- the sign is at the end of the map: scroll up to it
			for _ = 1, 8 do
				c.E.input(hash("wheel_up"), { value = 1 })
				c.step(2)
			end
			c.run(3)
			assert_true(c.map:has_text("New levels soon!", true), table.concat(c.map:texts(true), "|"))
			-- a beaten level is a replay
			tap_target(c, "node_" .. u.map.last)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("back goes to the town", function()
		with_map({}, function(c)
			tap_target(c, "back")
			c.run(0.3)
			local posts = posted_screens(c)
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "town")
		end)
	end)

	it("fits every window shape and language: no text outside the window, nothing the stub objects to", function()
		local windows = { { 360, 640 }, { 720, 1280 }, { 1920, 970 }, { 400, 1000 }, { 1280, 720 } }
		for _, language in ipairs({ "en", "ru", "ko" }) do
			for _, w in ipairs(windows) do
				with_map({ window = w, language = language, setup = function(app) G.win(app, 20) end }, function(c)
					c.run(0.5)
					assert_same(c.E.audit(), {}, language .. " " .. w[1] .. "x" .. w[2])
					assert_true(c.map:stats().nodes < 700)
					tap_target(c, "node_21")
					c.run(0.6)
					assert_eq(c.app.ui.popup, "start")
					assert_same(c.E.audit(), {}, language .. " start window")
				end)
			end
		end
	end)

	it("follows a language change and a reset of the save", function()
		with_map({ setup = function(app) G.win(app, 8) end }, function(c)
			assert_true(c.map:has_text("Map", true))
			require("client.i18n").set_language("ru")
			c.E.bus.publish("language_changed", {})
			c.run(0.5)
			assert_true(c.map:has_text("Карта", true))
			assert_same(c.E.audit(), {})
			c.app.reset_save(123)
			c.run(0.5)
			assert_eq(c.app.ui.map.next, 1)
			assert_same(c.E.audit(), {})
		end)
	end)
end)
