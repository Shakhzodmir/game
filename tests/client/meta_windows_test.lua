-- The meta windows (gui/*.lua, hosted by client/popups.lua inside the town) executed on the strict
-- Defold GUI stub: what each one shows, what its buttons do, in both languages and in the window
-- sizes the game meets.

local G = require("tests.client.meta_gui_helper")
local iap = require("client.services.iap")
local ads = require("client.services.ads")
local analytics = require("client.services.analytics")
local flow = require("client.flow")

-- (hash() exists only while the stub is installed)
local function TOUCH() return hash("touch") end

local function wait_for(c, pred, seconds, what)
	for _ = 1, math.ceil((seconds or 5) * 60) do
		if pred() then return end
		c.step(1)
	end
	assert_true(pred(), "timed out waiting for " .. tostring(what))
end

-- Opens a window and lets it come in (0.32 s of scale-in).
local function open(c, name, params)
	c.app.open_popup(name, params)
	c.run(0.6)
	assert_eq(c.app.ui.popup, name)
end

local function wtap(c, name)
	local t = c.app.ui.popup_targets and c.app.ui.popup_targets[name]
	assert_true(t ~= nil, "no target '" .. name .. "' in " .. tostring(c.app.ui.popup))
	c.tap(t.x, t.y)
	c.step(2)
end

local function toast(c)
	c.run(0.7)
	return c.app.overlay.toast
end

local function close(c)
	c.app.close_popup()
	c.run(0.5)
end

local function has(c, text) return c.town:has_text(text, true) end

local function texts(c) return G.dump(c.town) end

-- the sizes of the logical screen the windows must work in
local WINDOWS = { { 720, 1280 }, { 1280, 720 }, { 390, 844 }, { 768, 1024 } }

describe("meta windows: layout in both languages and every window size", function()
	local cases = {
		{ "start", nil }, { "lives", nil }, { "shop", { tab = "boosters" } }, { "shop", { tab = "coins" } },
		{ "settings", nil }, { "jukebox", nil }, { "chest", { kind = "level", level_id = 10,
			chest = { coins = 60, boosters = { "stick", "riff" }, infinite_minutes = 15 } } },
		{ "gift", { id = "riff" } }, { "concert", { district = "cafe" } },
		{ "confirm", { title = { key = "settings.reset_title" }, text = { key = "settings.reset_text" } } },
	}

	it("builds every window without engine errors, missing glyphs or unreadable texts", function()
		for _, lang in ipairs({ "en", "ru" }) do
			for _, case in ipairs(cases) do
				G.with_town({ language = lang, setup = function(app) G.win(app, 13) end }, function(c)
					open(c, case[1], case[2])
					local label = case[1] .. (case[2] and case[2].tab and ("/" .. case[2].tab) or "") .. " " .. lang
					assert_same(c.E.audit(), {}, label)
					for _, s in ipairs(c.town:smallest_texts(3)) do
						-- 15 logical px is the floor of readable text on a phone (the badges are the smallest)
						assert_true(s.px >= 15, label .. ": '" .. s.text .. "' is only " .. string.format("%.1f", s.px) .. " px")
					end
					close(c)
				end)
			end
		end
	end)

	it("builds every window in every window size and with a notch", function()
		for _, w in ipairs(WINDOWS) do
			for _, case in ipairs({ { "start", nil }, { "shop", { tab = "coins" } }, { "settings", nil }, { "jukebox", nil } }) do
				G.with_town({ window = w, safe = { left = 0, top = 48, right = 0, bottom = 30 } }, function(c)
					open(c, case[1], case[2])
					assert_same(c.E.audit(), {}, case[1] .. " " .. w[1] .. "x" .. w[2])
					-- the close button works wherever the window puts the screen
					wtap(c, "close")
					c.run(0.5)
					assert_eq(c.app.ui.popup, nil, case[1] .. " " .. w[1] .. "x" .. w[2])
				end)
			end
		end
	end)

	it("keeps buttons big enough to hit", function()
		local ui = require("client.ui")
		local seen = {}
		local real = ui.scene
		-- watch the scene the town makes: its buttons are the touch targets
		ui.scene = function(opts)
			local s = real(opts)
			seen[#seen + 1] = s
			return s
		end
		local ok, err = pcall(function()
			for _, case in ipairs(cases) do
				G.with_town({ setup = function(app) G.win(app, 13) end }, function(c)
					open(c, case[1], case[2])
					local small = {}
					for _, s in ipairs(seen) do
						for _, b in ipairs(s.buttons or {}) do
							if b.enabled and b.spec.w and b.spec.h and (b.spec.w < 64 or b.spec.h < 64) then
								small[#small + 1] = string.format("%s %dx%d", tostring(b.spec.text or b.spec.icon or "?"), b.spec.w, b.spec.h)
							end
						end
					end
					assert_same(small, {}, case[1] .. ": buttons under 64 px")
					seen = {}
				end)
			end
		end)
		ui.scene = real
		if not ok then error(err, 0) end
	end)
end)

describe("meta windows: start", function()
	it("shows goals, the three pre-level boosters with locks, the streak and the play button", function()
		G.with_town({}, function(c)
			open(c, "start")
			assert_true(has(c, "Goals"), texts(c))
			assert_true(has(c, "Boosters"))
			for _, name in ipairs({ "Riff", "Subwoofer", "Disco ball" }) do assert_true(has(c, name), name) end
			assert_true(has(c, "Level 12")) -- the lock of the riff
			assert_true(has(c, "The hit streak starts at level 12"))
			assert_true(has(c, "A loss costs nothing here"))
			assert_true(has(c, "Play"))
			-- a locked booster says when it opens
			wtap(c, "booster_riff")
			assert_eq(toast(c), "Unlocks at level 12")
		end)
	end)

	it("takes the picked boosters along and pays them at the start", function()
		G.with_town({ setup = function(app)
			G.win(app, 11) -- level 12 is next: the Riff is open (3 as a gift), no hit streak yet
			app.meta:grant({ boosters = { riff = 2 } }, "test", app.now())
			app.commit("test")
		end }, function(c)
			open(c, "start")
			local before = c.app.meta:booster_count("riff")
			wtap(c, "booster_riff") -- the first tap picks it
			assert_true(has(c, "Taking Riff along!"), texts(c))
			wtap(c, "booster_riff") -- the second takes it back
			assert_true(has(c, "Tap a booster to take it along"))
			wtap(c, "booster_riff")
			wtap(c, "play")
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(#posts, 1)
			local params = c.app.claim(posts[1].message.ticket)
			assert_same(params.run.paid_boosters, { "riff" })
			assert_eq(c.app.meta:booster_count("riff"), before - 1)
		end)
	end)

	it("tells the level screen where the player comes from: the town, or the level screen that hosts the window", function()
		for _, case in ipairs({ { "town", "town" }, { "level", "level" } }) do
			G.with_town({}, function(c)
				c.app.set_screen(case[1], {}) -- the window is hosted by this screen (after a win: "Next level")
				open(c, "start")
				wtap(c, "play")
				local posts = c.E.posted("show_screen", "main:/app")
				assert_eq(#posts, 1)
				assert_eq(c.app.claim(posts[1].message.ticket).from, case[2])
			end)
		end
	end)

	it("marks the streak boosters free and lets them be tapped without choosing", function()
		G.with_town({ setup = function(app) G.win(app, 13) end }, function(c)
			assert_eq(c.app.meta:streak().count, 2)
			open(c, "start")
			assert_true(has(c, "FREE"), texts(c))
			assert_true(has(c, "Free from your hit streak!"))
			wtap(c, "booster_riff")
			assert_eq(toast(c), "Free from your hit streak!")
		end)
	end)

	it("opens the lives window on Play when no life is left and shows why", function()
		G.with_town({ setup = function(app, c)
			G.win(app, 20)
			c.E.clock = c.E.clock + 3 * 3600
			for _ = 1, 5 do assert(flow.debug_lose()) end
			app.commit("test")
		end }, function(c)
			assert_eq(c.app.meta:lives(c.E.clock).count, 0)
			open(c, "start")
			local i18n = require("client.i18n")
			local function next_in() return "Next life in " .. i18n.duration(c.app.meta:lives(c.E.clock).next_in_seconds) end
			assert_true(has(c, "You need a life to play"), texts(c))
			assert_true(has(c, "Next life in 20:00"), texts(c)) -- as built: nothing ticked yet
			c.E.clock = c.E.clock + 30
			c.app.tick(c.E.clock)
			c.step(3)
			assert_true(has(c, next_in()), texts(c))
			assert_false(has(c, "Next life in 20:00"))
			wtap(c, "play")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "lives")
			assert_eq(#c.E.posted("show_screen", "main:/app"), 0)
			assert_eq(c.app.ui.popups[1], "start")
			-- a refill brings the start window back
			wtap(c, "refill")
			c.run(2)
			assert_eq(c.app.ui.popup, "start")
			assert_true(c.app.meta:can_start(c.app.meta:level_to_play(), c.E.clock))
		end)
	end)
end)

describe("meta windows: lives", function()
	it("shows full lives with the rule, and no refill", function()
		G.with_town({}, function(c)
			open(c, "lives")
			assert_true(has(c, "All lives are here!"), texts(c))
			assert_true(has(c, "A new life every 20 minutes"))
			assert_true(has(c, "Levels 1–20 don't cost lives"))
			assert_false(c.app.ui.popup_targets.refill ~= nil)
		end)
	end)

	it("counts down to the next life, refills for coins and says when coins are short", function()
		local flow_ = flow
		G.with_town({ setup = function(app, c)
			G.win(app, 20)
			c.E.clock = c.E.clock + 3 * 3600
			assert(flow_.debug_lose())
			app.commit("test")
		end }, function(c)
			local i18n = require("client.i18n")
			local function next_in() return "Next life in " .. i18n.duration(c.app.meta:lives(c.E.clock).next_in_seconds) end
			open(c, "lives")
			assert_true(has(c, "Next life in 20:00"), texts(c))
			assert_true(has(c, "Refill for 600"))
			c.E.clock = c.E.clock + 61
			c.app.tick(c.E.clock)
			c.step(3)
			assert_true(has(c, next_in()), texts(c))
			assert_false(has(c, "Next life in 20:00"))
			local coins = c.app.meta:coins()
			wtap(c, "refill")
			c.run(2)
			assert_eq(c.app.meta:lives(c.E.clock).count, 5)
			assert_eq(c.app.meta:coins(), coins - 600)
			assert_eq(c.app.overlay.toast, "Lives refilled!")
		end)
		-- without the coins the button says so and offers the shop
		G.with_town({ setup = function(app, c)
			G.win(app, 20)
			c.E.clock = c.E.clock + 3 * 3600
			assert(flow_.debug_lose())
			app.meta:_change("test_spend", { { "coins", -(app.meta:coins() - 100) } })
			app.commit("test")
		end }, function(c)
			open(c, "lives")
			wtap(c, "refill")
			assert_eq(toast(c), "Not enough coins")
			assert_eq(c.app.meta:lives(c.E.clock).count, 4)
			wtap(c, "get_coins")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "shop")
		end)
	end)

	it("shows unlimited lives with the time left", function()
		G.with_town({ setup = function(app)
			app.meta:grant({ infinite_minutes = 30 }, "test", app.now())
			app.commit("test")
		end }, function(c)
			open(c, "lives")
			assert_true(has(c, "Unlimited lives: 30:00"), texts(c))
			assert_true(has(c, "Unlimited lives are on: play as much as you like!"))
		end)
	end)
end)

describe("meta windows: shop", function()
	it("sells booster packs for coins and says what is locked", function()
		G.with_town({ setup = function(app) G.win(app, 13) end }, function(c)
			open(c, "shop", { tab = "boosters" })
			assert_true(has(c, "Drumstick"), texts(c))
			assert_true(has(c, "You have: 3")) -- the unlock gift of the drumstick
			assert_true(has(c, "Refill lives"))
			local coins, owned = c.app.meta:coins(), c.app.meta:booster_count("stick")
			wtap(c, "pack_stick")
			assert_eq(c.app.meta:booster_count("stick"), owned + 3)
			assert_eq(c.app.meta:coins(), coins - 450)
			-- the Disco ball opens at level 22: its pack shows the lock and has no buy button
			assert_true(has(c, "Unlocks at level 22"))
			assert_eq(c.app.ui.popup_targets.pack_disco, nil)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("does not charge what the purse cannot pay and leads to the coins tab", function()
		G.with_town({ setup = function(app)
			G.win(app, 13)
			app.meta:_change("test_spend", { { "coins", -(app.meta:coins() - 100) } })
			app.commit("test")
		end }, function(c)
			local owned = c.app.meta:booster_count("stick")
			open(c, "shop", { tab = "boosters" })
			wtap(c, "pack_stick")
			assert_eq(c.app.meta:coins(), 100)
			assert_eq(c.app.meta:booster_count("stick"), owned)
			c.run(1)
			assert_eq(c.app.overlay.toast, "Not enough coins")
			assert_true(has(c, "Starter pack"), texts(c)) -- the shop switched to the coins tab
		end)
	end)

	it("shows the store products honestly as unavailable in the web demo", function()
		G.with_town({}, function(c)
			assert_false(iap.available())
			assert_false(ads.can_show("shop_gift"))
			open(c, "shop", { tab = "coins" })
			assert_true(has(c, "Web demo: store purchases are turned off"), texts(c))
			assert_true(has(c, "$1.99"))
			assert_true(has(c, "Starter pack"))
			assert_false(has(c, "Watch a video"), texts(c)) -- the video gift is not offered
			local coins = c.app.meta:coins()
			wtap(c, "product_coins_small")
			assert_eq(toast(c), "Purchases are not available in the web demo")
			assert_eq(c.app.meta:coins(), coins)
			wtap(c, "gift")
			assert_eq(c.app.meta:coins(), coins)
		end)
	end)

	it("grants a test purchase in a debug build and flies the coins into the purse", function()
		G.with_town({ stores = true }, function(c)
			open(c, "shop", { tab = "coins" })
			assert_true(has(c, "Test purchase (debug build)"))
			local coins = c.app.meta:coins()
			wtap(c, "product_coins_small")
			c.run(2)
			assert_eq(c.app.meta:coins(), coins + 500)
			assert_true(c.app.overlay.toast ~= nil, "a toast says what was bought")
			assert_eq(c.app.ui.disp.coins, coins + 500) -- the counter in the top bar caught up
		end)
	end)

	it("lets the coins of a purchase land when the window is closed while they fly", function()
		G.with_town({ stores = true }, function(c)
			open(c, "shop", { tab = "coins" })
			local coins = c.app.meta:coins()
			wtap(c, "product_coins_small")
			c.run(0.1) -- the coins are in the air
			c.app.close_popup()
			c.run(0.4) -- the window is gone (0.18 s), the coins are still flying
			assert_eq(c.app.ui.popup, nil)
			c.run(2) -- every landing: no node of the closed window is touched
			assert_eq(c.app.meta:coins(), coins + 500)
			assert_eq(c.app.ui.disp.coins, coins + 500)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("logs the video offer once per visit of the shop, not at every rebuild", function()
		G.with_town({ stores = true }, function(c)
			analytics.drain()
			open(c, "shop", { tab = "coins" })
			c.app.set_setting("language", "ru") -- every window rebuilds
			c.run(0.3)
			c.app.set_setting("language", "en")
			c.run(0.3)
			local offers = {}
			for _, ev in ipairs(analytics.drain()) do
				if ev.name == "ad_offer" then offers[#offers + 1] = ev.params end
			end
			assert_same(offers, { { placement = "shop_gift", available = true } })
		end)
		-- the web demo has no video: the offer is still on screen, and says it is not available
		G.with_town({}, function(c)
			analytics.drain()
			open(c, "shop", { tab = "coins" })
			local offers = {}
			for _, ev in ipairs(analytics.drain()) do
				if ev.name == "ad_offer" then offers[#offers + 1] = ev.params end
			end
			assert_same(offers, { { placement = "shop_gift", available = false } })
		end)
	end)

	it("gives the free video gift in a debug build, once a minute", function()
		G.with_town({ stores = true }, function(c)
			open(c, "shop", { tab = "coins" })
			assert_true(has(c, "Watch a video"), texts(c))
			local coins = c.app.meta:coins()
			wtap(c, "gift")
			c.run(2)
			assert_eq(c.app.meta:coins(), coins + 100)
			assert_eq(c.app.overlay.toast, "Gift: +100 coins!")
			c.run(3) -- the toast goes
			-- again at once: the cooldown speaks, the purse stays
			wtap(c, "gift")
			c.run(0.5)
			assert_eq(c.app.meta:coins(), coins + 100)
			assert_true(string.find(c.app.overlay.toast or "", "^Next gift in 0:5%d$") ~= nil, "cooldown toast: " .. tostring(c.app.overlay.toast))
			-- a minute later it pays again
			c.E.clock = c.E.clock + 61
			c.app.tick(c.E.clock)
			wtap(c, "gift")
			c.run(2)
			assert_eq(c.app.meta:coins(), coins + 200)
		end)
	end)

	it("keeps the video gift readable in both languages and on narrow screens (a debug build)", function()
		for _, lang in ipairs({ "en", "ru" }) do
			for _, w in ipairs({ { 720, 1280 }, { 390, 844 }, { 1280, 720 } }) do
				G.with_town({ stores = true, language = lang, window = w }, function(c)
					open(c, "shop", { tab = "coins" })
					local label = "shop/coins " .. lang .. " " .. w[1] .. "x" .. w[2]
					assert_same(c.E.audit(), {}, label)
					for _, t in ipairs(c.town:smallest_texts(3)) do
						assert_true(t.px >= 15, label .. ": '" .. t.text .. "' is only " .. string.format("%.1f", t.px) .. " px")
					end
				end)
			end
		end
	end)

	it("refills the lives for coins", function()
		local flow_ = flow
		G.with_town({ setup = function(app, c)
			G.win(app, 20)
			c.E.clock = c.E.clock + 3 * 3600
			assert(flow_.debug_lose())
			app.commit("test")
		end }, function(c)
			open(c, "shop", { tab = "boosters" })
			assert_true(has(c, "4/5"), texts(c))
			local coins = c.app.meta:coins()
			wtap(c, "refill")
			c.run(1)
			assert_eq(c.app.meta:lives(c.E.clock).count, 5)
			assert_eq(c.app.meta:coins(), coins - 600)
			assert_true(has(c, "Lives are full"), texts(c))
		end)
	end)

	it("switches tabs and keeps the language", function()
		G.with_town({ language = "ru" }, function(c)
			open(c, "shop", { tab = "boosters" })
			assert_true(has(c, "Магазин"))
			wtap(c, "tab_coins")
			c.run(0.4)
			assert_true(has(c, "Стартовый набор"), texts(c))
			assert_true(has(c, "Веб-демо: покупки в магазине отключены"))
			wtap(c, "tab_boosters")
			c.run(0.4)
			assert_true(has(c, "Пополнить жизни"))
		end)
	end)
end)

describe("meta windows: settings", function()
	it("sets the volumes with the sliders, heard live and saved on release", function()
		G.with_town({}, function(c)
			open(c, "settings")
			local t = c.app.ui.popup_targets.slider_music
			assert_true(t ~= nil)
			-- press on the knob (value 0.8 of a 300 px track), drag to the middle, release
			local track_x0 = 360 + 128 - 150
			local knob_x = track_x0 + 0.8 * 300
			c.E.input(TOUCH(), c.E.touch_action(knob_x, t.y, true, false))
			c.step(1)
			c.E.input(TOUCH(), c.E.touch_action(track_x0 + 150, t.y, false, false))
			c.step(1)
			local vol = c.E.posted("volumes", "main:/audio#audio")
			c.E.input(TOUCH(), c.E.touch_action(track_x0 + 150, t.y, false, true))
			c.step(3)
			assert_near(c.app.meta:settings().music, 0.5, 1e-9)
			assert_eq(#vol >= 1 or #c.E.posted("volumes", "main:/audio#audio") >= 1, true)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("ends a drag whose release never came (focus lost mid-drag) with the next press, and does not drag on", function()
		G.with_town({}, function(c)
			open(c, "settings")
			local before = c.app.meta:settings().music
			local t = c.app.ui.popup_targets.slider_music
			local track_x0 = 360 + 128 - 150
			-- the finger goes down on the knob and the app loses focus: no release ever comes
			c.E.input(TOUCH(), c.E.touch_action(track_x0 + before * 300, t.y, true, false))
			c.step(2)
			-- the next press is a new gesture: it hits Close, not the slider
			wtap(c, "close")
			c.run(0.6)
			assert_eq(c.app.ui.popup, nil, "the Close button was not eaten by a phantom drag")
			assert_near(c.app.meta:settings().music, before, 1e-9)
		end)
	end)

	it("toggles vibration and reduced motion, and switches the controls", function()
		G.with_town({}, function(c)
			open(c, "settings")
			assert_true(c.app.meta:settings().haptics)
			wtap(c, "haptics")
			assert_false(c.app.meta:settings().haptics)
			wtap(c, "reduced_motion")
			assert_true(c.app.meta:settings().reduced_motion)
			wtap(c, "input_taptap")
			assert_eq(c.app.meta:settings().input_mode, "taptap")
			wtap(c, "input_swipe")
			assert_eq(c.app.meta:settings().input_mode, "swipe")
			wtap(c, "haptics")
			wtap(c, "reduced_motion")
			assert_true(c.app.meta:settings().haptics)
			assert_false(c.app.meta:settings().reduced_motion)
		end)
	end)

	it("switches the language and rebuilds the window", function()
		G.with_town({}, function(c)
			open(c, "settings")
			assert_true(has(c, "Settings"))
			wtap(c, "lang_ru")
			c.run(0.5)
			assert_eq(c.app.meta:settings().language, "ru")
			assert_true(has(c, "Настройки"), texts(c))
			assert_true(has(c, "Музыка"))
			wtap(c, "lang_en")
			c.run(0.5)
			assert_true(has(c, "Music"))
		end)
	end)

	it("resets the progress only after a confirmation, then goes back to the splash", function()
		G.with_town({ setup = function(app) G.win(app, 3) end }, function(c)
			open(c, "settings")
			wtap(c, "reset")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "confirm")
			assert_true(has(c, "Reset progress?"))
			-- no: nothing happens
			wtap(c, "cancel")
			c.run(0.5)
			assert_eq(c.app.meta:level_to_play(), 4)
			assert_eq(c.app.ui.popup, "settings")
			wtap(c, "reset")
			c.run(0.6)
			wtap(c, "confirm")
			c.run(0.5)
			assert_eq(c.app.meta:level_to_play(), 1)
			assert_eq(c.app.meta:coins(), 500)
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "splash")
		end)
	end)
end)

describe("meta windows: jukebox", function()
	it("lists the districts: finished ones play the whole song, the next one its built layers", function()
		G.with_town({ setup = function(app) G.build_tasks(app, "cafe") end }, function(c)
			open(c, "jukebox")
			assert_true(has(c, "Lo-fi Café"), texts(c))
			assert_true(has(c, "Full song"))
			assert_true(has(c, "Jazz Bar"))
			assert_true(has(c, "Layers: 0/7"))
			assert_true(has(c, "Build Jazz Bar to unlock"), texts(c))
			-- the finished district plays every stem and the party layer
			wtap(c, "play_cafe")
			c.step(3)
			local m = c.E.posted("music", "main:/audio#audio")
			assert_eq(m[#m].message.district, "cafe")
			assert_eq(m[#m].message.all, true)
			assert_true(has(c, "Now playing: Lo-fi Café"))
			assert_eq(#c.E.posted("jukebox_play"), 0) -- analytics, not a message
			-- Jazz has no layer yet: it cannot play
			wtap(c, "play_jazz")
			assert_eq(toast(c), "Build a task to hear it")
			-- the way home: the town track comes back
			wtap(c, "back_home")
			c.step(3)
			m = c.E.posted("music", "main:/audio#audio")
			assert_eq(m[#m].message.district, "jazz")
			assert_true(m[#m].message.all ~= true)
		end)
	end)

	it("plays the layers built so far of the district being built", function()
		G.with_town({ setup = function(app) G.give_stars(app, 4); assert(app.meta:complete_task("cafe", "turntable")); assert(app.meta:complete_task("cafe", "lamps")); app.commit("t") end }, function(c)
			open(c, "jukebox")
			assert_true(has(c, "Layers: 2/6"), texts(c))
			wtap(c, "play_cafe")
			c.step(3)
			local m = c.E.posted("music", "main:/audio#audio")
			assert_eq(m[#m].message.district, "cafe")
			assert_true(m[#m].message.all ~= true)
			close(c)
			m = c.E.posted("music", "main:/audio#audio")
			assert_eq(m[#m].message.district, "cafe") -- the town track is back when the window closes
		end)
	end)
end)

describe("meta windows: chests and gifts", function()
	it("opens a level chest on a tap and flies what it holds into the town", function()
		G.with_town({ setup = function(app) G.win(app, 9) end }, function(c)
			local res = G.win(c.app, 1) -- level 10: the chest
			assert_true(res.chest ~= nil)
			c.app.push_reward(res)
			wait_for(c, function() return c.app.ui.popup == "chest" end, 8, "the level chest")
			assert_true(has(c, "Level 10 chest!"), texts(c))
			c.run(0.5)
			wtap(c, "chest")
			wait_for(c, function() return c.app.ui.popup_targets and c.app.ui.popup_targets.collect ~= nil end, 3, "the open chest")
			c.run(1.5)
			assert_true(has(c, "+60"), texts(c))
			assert_true(has(c, "+15 min"))
			wtap(c, "collect")
			wait_for(c, function() return not c.app.ui.busy end, 12, "the flights")
			assert_eq(c.app.ui.disp.coins, c.app.meta:coins())
			assert_same(c.E.audit(), {})
		end)
	end)

	it("keeps the lives pill as it was until the chest's unlimited lives have flown into it", function()
		G.with_town({ setup = function(app) G.win(app, 9) end }, function(c)
			local res = G.win(c.app, 1) -- level 10: the chest holds 15 minutes of unlimited lives
			assert_eq(res.chest.infinite_minutes, 15)
			c.app.push_reward(res)
			assert_true(c.app.meta:lives(c.app.now()).infinite_seconds > 0, "the meta has them from the win on")
			c.run(0.8)
			assert_true(has(c, "Full"), "the pill still shows the lives as they were: " .. texts(c))
			assert_false(has(c, "15:00"))
			assert_eq(c.app.ui.hold.infinite, 900)
			wait_for(c, function() return c.app.ui.popup == "chest" end, 8, "the level chest")
			assert_true(has(c, "Full") and not has(c, "15:00"), "not while the chest is closed: " .. texts(c))
			c.run(0.5)
			wtap(c, "chest")
			wait_for(c, function() return c.app.ui.popup_targets and c.app.ui.popup_targets.collect ~= nil end, 3, "the open chest")
			c.run(1.5)
			assert_true(has(c, "Full") and not has(c, "15:00"), "nor while it is open")
			wtap(c, "collect")
			c.run(0.2) -- the hearts and the coins are in the air
			assert_eq(c.app.ui.hold.infinite, 900)
			assert_true(has(c, "Full"))
			wait_for(c, function() return not c.app.ui.busy end, 12, "the flights")
			assert_eq(c.app.ui.hold.infinite, 0)
			assert_true(c.town:find("^14:%d%d$", true) ~= nil, "the unlimited lives landed in the pill (the clock runs): " .. texts(c))
			assert_false(has(c, "Full"))
			assert_same(c.E.audit(), {})
		end)
	end)

	it("keeps the title of a district chest readable on its ribbon in Russian (two lines, not a speck)", function()
		G.with_town({ language = "ru" }, function(c)
			open(c, "chest", { kind = "district", district = "square", district_name = c.app.district("square").name,
				chest = { coins = 600, boosters = { "disco" } } })
			local title = c.town:find("оркестра:", true) -- "Площадь уличного оркестра:\nсундук района!"
			assert_true(title ~= nil, texts(c))
			assert_true(c.E.text_px(title) >= 26, "title size " .. c.E.text_px(title))
			-- the short titles stay on one line at the full size
			close(c)
			open(c, "chest", { kind = "level", level_id = 10, chest = { coins = 60 } })
			local short = c.town:find("Сундук уровня 10!")
			assert_true(short ~= nil, texts(c))
			assert_near(c.E.text_px(short), 40, 0.01)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("hands over an unlock gift and flies the booster to the level button", function()
		G.with_town({ setup = function(app) G.win(app, 6) end }, function(c)
			local res = G.win(c.app, 1) -- the win of level 7 makes level 8 next: the drumstick opens
			assert_same(res.unlocked, { "stick" })
			c.app.push_reward(res)
			wait_for(c, function() return c.app.ui.popup == "gift" end, 8, "the gift")
			assert_true(has(c, "New booster!"))
			c.run(0.5)
			wtap(c, "gift")
			wait_for(c, function() return c.app.ui.popup_targets and c.app.ui.popup_targets.collect ~= nil end, 3, "the open gift")
			c.run(1)
			assert_true(has(c, "Drumstick"), texts(c))
			assert_true(has(c, "Breaks one piece"))
			wtap(c, "collect")
			wait_for(c, function() return not c.app.ui.busy end, 8, "the flight")
			assert_eq(c.app.ui.popup, nil)
		end)
	end)

	it("stays closed to taps outside while a window is open and closes on back", function()
		G.with_town({}, function(c)
			open(c, "settings")
			c.tap(100, 226) -- the level button lies under the window (not under one of its buttons)
			c.run(0.4)
			assert_eq(c.app.ui.popup, "settings")
			c.E.input(hash("back"), { released = true, pressed = false, x = 0, y = 0 })
			c.run(0.5)
			assert_eq(c.app.ui.popup, nil)
		end)
	end)

	it("plays the concert for its length and closes it, or on a tap", function()
		G.with_town({}, function(c)
			c.app.open_popup("concert", { district = "cafe", duration = 2 })
			c.run(1)
			assert_eq(c.app.ui.popup, "concert")
			assert_true(has(c, "Lo-fi Café: concert!"))
			c.run(2)
			assert_eq(c.app.ui.popup, nil)
			c.app.open_popup("concert", { district = "cafe" })
			c.run(1)
			c.tap(360, 640)
			c.run(0.5)
			assert_eq(c.app.ui.popup, nil)
			assert_same(c.E.audit(), {})
			assert_true(analytics.count() > 0)
		end)
	end)
end)
