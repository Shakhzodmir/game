-- screens/splash/splash.gui_script on the strict Defold GUI stub: the logo for at most three seconds,
-- the first launch straight into level 1, the notices of the load, taps, languages and window sizes.

local G = require("tests.client.meta_gui_helper")
local town_stub = require("tests.client.town_defold_stub")

-- Boots the app, creates the overlay and the splash, runs fn(c) with c.splash.
local function with_splash(opts, fn)
	opts = opts or {}
	local E = town_stub.boot(opts)
	local ok, err = pcall(function()
		local app = require("client.app")
		local c = { E = E, app = app }
		c.overlay = E.script("main/overlay.gui_script", "/main/overlay.gui", { url = "main:/overlay#overlay" })
		c.overlay:init()
		c.overlay:message("fade_in", { duration = 0.25 }, msg.url("main:/app"))
		if opts.setup then opts.setup(app, c) end
		c.splash = E.script("screens/splash/splash.gui_script", "/screens/splash/splash.gui")
		c.splash:init()
		app.set_screen("splash", {})
		function c.step(n) E.step(n) end
		function c.run(s) E.run(s) end
		fn(c)
	end)
	town_stub.shutdown()
	if not ok then error(err, 0) end
end

local function screen_posts(c)
	return c.E.posted("show_screen", "main:/app")
end

describe("screens/splash/splash.gui_script", function()
	it("shows the logo, the tagline and the loading text", function()
		with_splash({}, function(c)
			c.step(30)
			assert_true(c.splash:has_text("Match. Play. Light up the town!", true), G.dump(c.splash))
			assert_true(c.splash:has_text("Tuning up…", true))
			assert_same(c.E.audit(), {})
			assert_eq(c.app.ui.screen, "splash")
		end)
		with_splash({ language = "ru" }, function(c)
			c.step(30)
			assert_true(c.splash:has_text("Собирай. Играй. Зажигай город!", true))
			assert_true(c.splash:has_text("Настраиваем инструменты…", true))
			assert_same(c.E.audit(), {})
		end)
	end)

	it("goes straight into level 1 on the first launch, in under three seconds", function()
		with_splash({}, function(c)
			assert_true(c.app.first_launch())
			c.run(1.9)
			assert_eq(#screen_posts(c), 0)
			c.run(1.2) -- 3.1 s after the screen came up
			local posts = screen_posts(c)
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "level")
			local params = c.app.claim(posts[1].message.ticket)
			assert_eq(params.level_id, 1)
			assert_eq(params.from, "splash")
			assert_true(c.app.meta:run() ~= nil, "the attempt is open in the meta")
			-- it asks once
			c.run(2)
			assert_eq(#screen_posts(c), 1)
		end)
	end)

	it("opens the town for a player who has played", function()
		with_splash({ setup = function(app) G.win(app, 1) end }, function(c)
			assert_false(c.app.first_launch())
			c.run(2.6)
			local posts = screen_posts(c)
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "town")
			assert_eq(c.app.claim(posts[1].message.ticket).from, "splash")
		end)
	end)

	it("lets a tap skip the wait, but not in the very first moment", function()
		with_splash({ setup = function(app) G.win(app, 1) end }, function(c)
			c.run(0.4)
			c.E.tap(360, 640)
			c.step(2)
			assert_eq(#screen_posts(c), 0)
			c.run(0.8)
			c.E.tap(360, 640)
			c.step(2)
			assert_eq(#screen_posts(c), 1)
		end)
	end)

	it("tells the player what the load did: a lost save, an interrupted level, gifts, chests", function()
		with_splash({ setup = function(app)
			G.win(app, 1)
			app.load_info = { source = "fresh", errors = { current = "bad_checksum", previous = "missing" },
				unlock_gifts = { "stick" }, district_chests = { "cafe" }, interrupted = "loss" }
		end }, function(c)
			local seen, last = {}, nil
			for _ = 1, 60 * 20 do
				c.step(1)
				local t = c.app.overlay.toast
				if t and t ~= last then seen[#seen + 1] = t end
				last = t
			end
			assert_same(seen, {
				"Your saved progress could not be read, so the game starts over",
				"The last level was interrupted and counted as a loss",
				"Gift: Drumstick boosters!",
				"Lo-fi Café: the district chest is yours!",
			})
		end)
	end)

	it("works in every window size and without motion", function()
		for _, w in ipairs({ { 720, 1280 }, { 1280, 720 }, { 390, 844 }, { 768, 1024 } }) do
			with_splash({ window = w, safe = { left = 0, top = 40, right = 0, bottom = 24 }, setup = function(app)
				app.set_setting("reduced_motion", true)
			end }, function(c)
				c.step(40)
				assert_same(c.E.audit(), {}, w[1] .. "x" .. w[2])
				local nodes = c.splash:stats().nodes
				c.E.set_window(w[2], w[1])
				c.step(3)
				assert_eq(c.splash:stats().nodes, nodes)
			end)
		end
	end)

	it("deletes its textures when it goes away", function()
		with_splash({}, function(c)
			c.step(30)
			local scene = c.E.scene("/screens/splash/splash.gui")
			assert_true(next(scene.dyn) ~= nil, "the splash made textures")
			c.splash:final()
			assert_eq(next(scene.dyn), nil)
		end)
	end)
end)
