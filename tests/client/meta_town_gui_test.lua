-- The town screen (screens/town) executed on the strict Defold GUI stub (tests/client/town_defold_stub.lua):
-- what it shows, what a tap does, the animated steps, district paging, hints, language, window sizes.

local G = require("tests.client.meta_gui_helper")
local analytics = require("client.services.analytics")
local layout = require("client.layout")
local bus = require("client.bus")
local meta_qa = require("client.meta_qa")

local function count_events(name)
	local n = 0
	for _, ev in ipairs(analytics.recent(500)) do
		if ev.name == name then n = n + 1 end
	end
	return n
end

-- Steps frames until pred() holds (at most `seconds`); fails with a message otherwise.
local function wait_for(c, pred, seconds, what)
	local frames = math.ceil((seconds or 5) * 60)
	for _ = 1, frames do
		if pred() then return end
		c.step(1)
	end
	assert_true(pred(), "timed out waiting for " .. tostring(what))
end

local function tap_target(c, name)
	local t = c.app.ui.targets and c.app.ui.targets[name]
	assert_true(t ~= nil, "no tap target '" .. name .. "'")
	return c.tap(t.x, t.y)
end

local function popup_target(c, name)
	local t = c.app.ui.popup_targets and c.app.ui.popup_targets[name]
	assert_true(t ~= nil, "no popup target '" .. name .. "' in " .. tostring(c.app.ui.popup))
	return c.tap(t.x, t.y)
end

describe("screens/town/town.gui_script", function()
	it("builds the first town: top bar, task card, level button, navigation", function()
		G.with_town({}, function(c)
			local t = c.town
			for _, text in ipairs({ "Full", "500", "0", "Lo-fi Café", "Track layers: 0/6", "Concert", "Turntable",
				"Adds Beat to the track", "Need 1 more star", "Level 1", "Shop", "Band", "Town", "Chart", "Jukebox" }) do
				assert_true(t:has_text(text, true), "no '" .. text .. "' in: " .. G.dump(t))
			end
			assert_eq(#c.E.audit(), 0)
			assert_true(t:stats().nodes < 400, "node count " .. t:stats().nodes)
			assert_eq(c.app.ui.screen, "town")
			assert_eq(c.app.ui.district, "cafe")
			assert_eq(c.app.ui.card, "task")
			assert_eq(c.app.ui.nav.count, 1)
			-- the district music of the focus district was asked for
			local music = c.E.posted("music", "main:/audio#audio")
			assert_eq(music[#music].message.district, "cafe")
		end)
	end)

	it("shows the Hard tag of a level from its file and the streak notes", function()
		G.with_town({ setup = function(app) G.win(app, 13) end }, function(c)
			assert_eq(c.app.meta:level_to_play(), 14)
			assert_true(c.town:has_text("Level 14", true))
			-- level 14 is hard or super hard in the shipped levels: a tag is shown (or not) from the file, never invented
			local levels = require("client.levels")
			local tag = levels.tag(levels.difficulty(14))
			local i18n = require("client.i18n")
			assert_eq(c.town:has_text(tag and i18n.t(tag) or "Hard", true), tag ~= nil)
		end)
	end)

	it("opens the start window from the level button and starts the level through the meta", function()
		G.with_town({}, function(c)
			c.town:tap_text("Level 1")
			c.step(30)
			assert_eq(c.app.ui.popup, "start")
			assert_true(c.town:has_text("Goals", true))
			assert_true(c.town:has_text("Play", true))
			assert_eq(#c.E.audit(), 0)
			c.town:tap_text("Play")
			c.step(5)
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(#posts, 1)
			local params = c.app.claim(posts[1].message.ticket)
			assert_eq(posts[1].message.name, "level")
			assert_eq(params.level_id, 1)
			assert_eq(params.from, "town")
			assert_true(c.app.meta:run() ~= nil, "the attempt is open in the meta")
			-- a second tap does not start a second attempt
			c.town:tap_text("Play")
			c.step(5)
			assert_eq(#c.E.posted("show_screen", "main:/app"), 1)
		end)
	end)

	it("answers a task without enough stars with a toast and builds nothing", function()
		G.with_town({}, function(c)
			tap_target(c, "task")
			c.run(0.7)
			assert_eq(c.app.overlay.toast, "Need 1 more star")
			assert_eq(c.app.meta:district("cafe").done, 0)
			assert_false(c.app.ui.busy)
		end)
	end)

	it("shows the stars and coins of a won level as they land in the top bar", function()
		G.with_town({}, function(c)
			local res = G.win(c.app, 1)
			c.app.push_reward(res)
			c.step(5)
			-- the balances still show what was there before the reward
			assert_eq(c.app.ui.disp.coins, 500)
			assert_eq(c.app.ui.disp.stars, 0)
			wait_for(c, function() return not c.app.ui.busy end, 8, "the reward show")
			assert_eq(c.app.ui.disp.coins, c.app.meta:coins())
			assert_eq(c.app.ui.disp.stars, 1)
			assert_true(c.town:has_text(c.app.meta:coins() .. "", true), G.dump(c.town))
			assert_eq(c.app.ui.hold.coins, 0)
			assert_eq(c.app.ui.hold.stars, 0)
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("builds a task: the stars fly, the item lights up and its stem joins the track (2-3 s)", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			assert_true(c.town:has_text("Tap to build!", true))
			local base = c.town:stats().nodes
			tap_target(c, "task")
			c.run(0.3)
			assert_true(c.app.ui.busy)
			assert_eq(c.app.ui.step, "task")
			local t0 = c.E.clock
			wait_for(c, function() return not c.app.ui.busy end, 6, "the task animation")
			local took = c.E.clock - t0
			assert_true(took >= 1.5 and took <= 3.6, "the task took " .. took .. " s")
			assert_eq(c.app.meta:district("cafe").done, 1)
			local stems = c.E.posted("unlock_stem", "main:/audio#audio")
			assert_eq(#stems, 1)
			assert_eq(stems[1].message.stem, "beat")
			assert_eq(stems[1].message.district, "cafe")
			assert_eq(count_events("task_complete"), 1)
			assert_true(c.town:has_text("Warm lamps", true), G.dump(c.town))
			assert_true(c.app.meta:tutorial_seen("town_first_task"))
			c.run(2)
			assert_true(c.town:stats().nodes <= base + 12, "no leaked nodes: " .. c.town:stats().nodes .. " vs " .. base)
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("lets a tap skip the task animation to its end state, logging the task once", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			tap_target(c, "task")
			c.run(0.25)
			assert_true(c.app.ui.busy)
			c.tap(360, 800) -- anywhere
			c.step(3)
			assert_false(c.app.ui.busy)
			assert_eq(c.app.meta:district("cafe").done, 1)
			assert_eq(#c.E.posted("unlock_stem", "main:/audio#audio"), 1)
			assert_eq(count_events("task_complete"), 1)
			assert_eq(c.app.ui.disp.stars, c.app.meta:stars())
			assert_true(c.town:has_text("Warm lamps", true))
		end)
	end)

	it("plays a note when a restored item is tapped and says so when a task is still waiting", function()
		G.with_town({ setup = function(app) G.win(app, 1); G.build_tasks(app, "cafe", 1) end }, function(c)
			local scene_items = c.app.ui.district
			assert_eq(scene_items, "cafe")
			-- the turntable (restored) is at 370, 1280 - 712
			c.tap(370, 1280 - 712)
			c.step(3)
			assert_true(#c.E.posted("note", "main:/audio#audio") >= 1)
			-- the piano is still waiting: a toast names it
			c.tap(160, 1280 - 690)
			c.run(0.7)
			assert_eq(c.app.overlay.toast, "Upright piano: coming soon to the track")
		end)
	end)

	it("plays the district concert, the chest and the next district after the last task", function()
		G.with_town({ setup = function(app)
			G.win(app, 1)
			G.build_tasks(app, "cafe", 5)
			G.give_stars(app, 3)
		end }, function(c)
			assert_eq(c.app.meta:next_task().id, "sign")
			tap_target(c, "task")
			wait_for(c, function() return c.app.ui.popup == "concert" end, 8, "the concert")
			assert_true(c.town:has_text("Lo-fi Café: concert!", true))
			assert_eq(#c.E.posted("music", "main:/audio#audio") > 0 and 1 or 0, 1)
			c.run(0.8)
			c.tap(360, 640) -- a tap skips the concert
			wait_for(c, function() return c.app.ui.popup == "chest" end, 4, "the district chest")
			assert_true(c.town:has_text("Tap the chest!", true))
			c.run(0.5)
			popup_target(c, "chest")
			wait_for(c, function() return c.app.ui.popup_targets and c.app.ui.popup_targets.collect ~= nil end, 4, "the open chest")
			c.run(1.2)
			popup_target(c, "collect")
			wait_for(c, function() return not c.app.ui.busy end, 12, "the flights and the next district")
			assert_eq(c.app.ui.district, "jazz")
			assert_eq(c.app.ui.focus, "jazz")
			assert_true(c.town:has_text("Jazz Bar", true), G.dump(c.town))
			assert_eq(c.app.ui.disp.coins, c.app.meta:coins())
			assert_eq(c.app.ui.nav.count, 2)
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("pages through the open districts with the arrows and a swipe, and offers the way back", function()
		G.with_town({ setup = function(app) G.build_tasks(app, "cafe") end }, function(c)
			assert_eq(c.app.ui.district, "jazz")
			assert_eq(c.app.ui.nav.prev, "cafe")
			assert_eq(c.app.ui.nav.next, nil)
			assert_true(c.town:has_text("Jazz Bar", true))
			tap_target(c, "nav_prev")
			wait_for(c, function() return c.app.ui.district == "cafe" and not c.app.ui.sliding end, 3, "paging back")
			c.run(1)
			assert_true(c.town:has_text("Lo-fi Café", true), G.dump(c.town))
			assert_eq(c.app.ui.card, "back")
			assert_eq(c.app.ui.focus, "jazz")
			assert_true(c.town:has_text("Back to Jazz Bar", true), G.dump(c.town))
			-- the cafe plays its own track while it is on display
			local music = c.E.posted("music", "main:/audio#audio")
			assert_eq(music[#music].message.district, "cafe")
			-- the day / concert look belongs to the district on display
			tap_target(c, "view")
			c.run(1)
			assert_eq(c.app.meta:view("cafe"), "concert")
			assert_eq(c.app.meta:view("jazz"), "day")
			tap_target(c, "view")
			c.run(1)
			-- back to the district being built
			tap_target(c, "back")
			c.run(1.2)
			assert_eq(c.app.ui.district, "jazz")
			assert_eq(c.app.ui.card, "task")
			-- a swipe to the right shows the previous district, a swipe left at the end of the street does nothing
			c.E.input(hash("touch"), c.E.touch_action(500, 700, true, false))
			c.step(2)
			c.E.input(hash("touch"), c.E.touch_action(260, 700, false, true))
			c.step(2)
			assert_eq(c.app.ui.district, "jazz") -- left = next: there is none
			c.E.input(hash("touch"), c.E.touch_action(260, 700, true, false))
			c.step(2)
			c.E.input(hash("touch"), c.E.touch_action(500, 700, false, true))
			wait_for(c, function() return c.app.ui.district == "cafe" end, 3, "a swipe")
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("keeps paging out of the way of windows and animations", function()
		G.with_town({ setup = function(app) G.build_tasks(app, "cafe") end }, function(c)
			c.app.open_popup("shop")
			c.step(30)
			-- the arrows lie under the window: a tap there is the window's, not the town's
			tap_target(c, "nav_prev")
			c.step(2)
			assert_eq(c.app.ui.district, "jazz")
			c.app.close_popup()
			c.run(0.6)
			tap_target(c, "nav_prev")
			c.step(2)
			-- a second tap while the district slides does nothing
			local first = c.app.ui.district
			tap_target(c, "nav_next")
			c.step(2)
			assert_eq(c.app.ui.district, first)
		end)
	end)

	it("shows a pointing hand over the first task until it is built", function()
		G.with_town({}, function(c)
			assert_eq(c.app.ui.hint, nil) -- no star yet: nothing to point at
		end)
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			assert_eq(c.app.ui.hint, "town_first_task")
			assert_true(c.town:has_text("Spend stars to bring the town back to life", true), G.dump(c.town))
			c.app.set_setting("language", "ru") -- rebuilds the bars: the hint is still one analytics event
			c.step(5)
			assert_eq(count_events("tutorial_step"), 1)
			c.app.set_setting("language", "en")
			c.step(5)
			tap_target(c, "task")
			wait_for(c, function() return not c.app.ui.busy end, 6, "the task")
			assert_eq(c.app.ui.hint, nil)
			assert_true(c.app.meta:tutorial_seen("town_first_task"))
			assert_false(c.town:has_text("Spend stars to bring the town back to life", true))
		end)
		-- the hint is remembered: a new visit does not show it again
		G.with_town({ setup = function(app)
			G.win(app, 3)
			app.meta:mark_tutorial_seen("town_first_task")
			app.commit("test")
		end }, function(c)
			assert_eq(c.app.ui.hint, nil)
		end)
	end)

	it("rebuilds the town and its windows when the language changes", function()
		G.with_town({}, function(c)
			c.app.open_popup("shop")
			c.step(30)
			assert_true(c.town:has_text("Shop", true))
			c.app.set_setting("language", "ru")
			c.step(10)
			assert_true(c.town:has_text("Уровень 1", true), G.dump(c.town))
			assert_true(c.town:has_text("Магазин", true))
			assert_true(c.town:has_text("Проигрыватель", true))
			assert_false(c.town:has_text("Level 1", true))
			assert_eq(#c.E.audit(), 0)
			c.app.set_setting("language", "en")
			c.step(10)
			assert_true(c.town:has_text("Level 1", true))
			assert_true(c.town:has_text("Shop", true))
		end)
	end)

	it("shows lives and their timer, and counts down", function()
		local flow = require("client.flow")
		G.with_town({ setup = function(app, c)
			G.win(app, 20)
			c.E.clock = c.E.clock + 3 * 3600 -- the unlimited lives of the chests are over
			assert(flow.debug_lose())
			app.commit("test")
		end }, function(c)
			assert_eq(c.app.meta:lives(c.E.clock).count, 4)
			assert_true(c.town:has_text("20:00", true), G.dump(c.town))
			c.E.clock = c.E.clock + 65
			c.app.tick(c.E.clock)
			c.step(3)
			assert_true(c.town:has_text("18:55", true), G.dump(c.town))
		end)
	end)

	it("lays the bars out against the safe area of every window", function()
		for _, w in ipairs({ { 720, 1280 }, { 1280, 720 }, { 390, 844 }, { 768, 1024 } }) do
			local safe = { left = 0, top = 48, right = 0, bottom = 30 }
			G.with_town({ window = w, safe = safe }, function(c)
				local f = layout.fit(w[1], w[2])
				local sr = layout.safe_rect(f, { inset_top = safe.top, inset_bottom = safe.bottom, inset_left = 0, inset_right = 0 })
				local tg = c.app.ui.targets
				assert_near(tg.lives.y, 1214 + (sr.y1 - 1280), 0.01, "top bar " .. w[1] .. "x" .. w[2])
				assert_near(tg.nav_shop.y, 40 + 32 + sr.y0, 0.01, "navigation " .. w[1] .. "x" .. w[2])
				assert_true(tg.lives.y <= f.y1 and tg.nav_shop.y >= f.y0)
				assert_eq(#c.E.audit(), 0)
				-- a tap on the level button lands wherever the window puts it
				c.tap(tg.level.x, tg.level.y)
				c.step(30)
				assert_eq(c.app.ui.popup, "start", w[1] .. "x" .. w[2])
			end)
		end
	end)

	it("follows a window resize without leaking nodes", function()
		G.with_town({}, function(c)
			local base = c.town:stats().nodes
			c.E.set_window(1280, 720)
			c.step(3)
			c.E.set_window(390, 844)
			c.step(3)
			c.E.set_window(720, 1280)
			c.step(3)
			assert_eq(c.town:stats().nodes, base)
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("closes its windows and its show when the save is reset or the screen goes away", function()
		G.with_town({}, function(c)
			c.app.open_popup("settings")
			c.step(30)
			assert_eq(c.app.ui.popup, "settings")
			c.app.reset_save(7, c.E.clock)
			c.step(5)
			assert_eq(c.app.ui.popup, nil)
			c.app.open_popup("shop")
			c.step(30)
			bus.publish("screen_leaving", { from = "town", to = "level" })
			c.step(5)
			assert_eq(c.app.ui.popup, nil)
		end)
	end)

	it("answers popup requests, and says so when all levels are done", function()
		G.with_town({}, function(c)
			c.app.open_popup("lives")
			c.step(30)
			assert_eq(c.app.ui.popup, "lives")
			c.app.close_popup()
			c.run(0.6)
			assert_eq(c.app.ui.popup, nil)
			c.app.open_popup("jukebox")
			c.step(30)
			assert_eq(c.app.ui.popup, "jukebox")
			c.app.close_popup()
			c.run(0.6)
		end)
	end)

	it("opens the window a QA command asked for from another screen", function()
		local h = meta_qa.handlers()
		G.with_town({ town = false }, function(c)
			c.app.screen = "level"
			local json = require("tools.lib.json")
			meta_qa.decode = json.decode
			local r = h.open({ "shop", '{"tab":' }, 'open shop {"tab": "coins"}')
			assert_true(r.ok)
			assert_eq(r.via, "town_screen")
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(#posts, 1)
			local params = c.app.claim(posts[1].message.ticket)
			assert_eq(params.open, "shop")
			assert_eq(params.open_params.tab, "coins")
			-- the town that loads with these params shows the window once it is on display
			c.app.params = params
			c.town = c.E.script("screens/town/town.gui_script", "/screens/town/town.gui")
			c.town:init()
			c.app.set_screen("town", params)
			c.run(1.5)
			assert_eq(c.app.ui.popup, "shop")
			assert_true(c.town:has_text("Coins", true))
			meta_qa.decode = nil
		end)
	end)

	it("continues the district background past the design area on other window shapes", function()
		local function strips(c)
			local n = 0
			for _, node in ipairs(c.E.alive_nodes(c.E.scene("/screens/town/town.gui"))) do
				if node.texture and string.sub(node.texture, 1, 4) == "ext:" and c.E.visible(node) then n = n + 1 end
			end
			return n
		end
		G.with_town({ window = { 720, 1280 } }, function(c)
			assert_eq(strips(c), 0) -- exactly the design shape: nothing to continue
		end)
		G.with_town({ window = { 1280, 720 } }, function(c)
			assert_eq(strips(c), 2) -- left and right
		end)
		G.with_town({ window = { 390, 844 } }, function(c)
			assert_eq(strips(c), 2) -- a tall phone: top and bottom
		end)
	end)

	it("pulses the task card only when the stars suffice", function()
		local ui = require("client.ui")
		G.with_town({}, function(c)
			local t = c.town.self.t
			assert_false(ui.is_pulsing(t.hud.card))
		end)
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local t = c.town.self.t
			assert_true(ui.is_pulsing(t.hud.card))
			assert_true(t.hud.card_kind == "task")
		end)
	end)

	it("shows the difficulty tag from the level file and lights as many streak notes as there are wins in a row", function()
		local levels = require("client.levels")
		local i18n = require("client.i18n")
		-- the first hard and the first super hard level of the shipped content (the files are read through the
		-- stub's sys.load_resource, like the game does)
		local hard, super
		G.with_town({ town = false }, function()
			for n = 1, 100 do
				local d = levels.difficulty(n)
				if d == "hard" and not hard then hard = n end
				if d == "super_hard" and not super then super = n end
			end
		end)
		assert_true(hard ~= nil and super ~= nil, "the content has hard and super hard levels")
		for _, case in ipairs({ { hard, "Hard" }, { super, "Super Hard" } }) do
			G.with_town({ setup = function(app) G.win(app, case[1] - 1) end }, function(c)
				assert_eq(c.app.meta:level_to_play(), case[1])
				assert_true(c.town:has_text(case[2], true), case[2] .. " at level " .. case[1] .. ": " .. G.dump(c.town))
			end)
		end
		-- the streak counts from level 12: wins of levels 12 and 13 light two notes, the third waits
		G.with_town({ setup = function(app) G.win(app, 13) end }, function(c)
			local v = c.town.self.t.hud.level_view
			assert_eq(#v.notes, 3)
			assert_true(v.notes[1].lit and v.notes[2].lit)
			assert_false(v.notes[3].lit)
			assert_eq(i18n.t("town.level", { n = 14 }), "Level 14")
		end)
	end)

	it("says 'coming soon' for the band and chart tabs and opens the shop and the jukebox", function()
		G.with_town({}, function(c)
			tap_target(c, "nav_band")
			c.run(0.7)
			assert_eq(c.app.overlay.toast, "Coming soon!")
			assert_eq(c.app.ui.popup, nil)
			tap_target(c, "nav_chart")
			c.run(0.2)
			tap_target(c, "nav_shop")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "shop")
			c.app.close_popup()
			c.run(0.6)
			tap_target(c, "nav_jukebox")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "jukebox")
			c.app.close_popup()
			c.run(0.6)
			-- the coins "+" opens the shop on the coins tab, the lives pill the lives window, the gear the settings
			tap_target(c, "coins_plus")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "shop")
			assert_true(c.town:has_text("Starter pack", true))
			c.app.close_popup()
			c.run(0.6)
			tap_target(c, "lives")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "lives")
			c.app.close_popup()
			c.run(0.6)
			tap_target(c, "settings")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "settings")
		end)
	end)

	it("plays the district concert for 10 to 15 seconds unless a tap skips it", function()
		G.with_town({}, function(c)
			c.app.open_popup("concert", { district = "cafe" })
			c.run(9.5)
			assert_eq(c.app.ui.popup, "concert")
			c.run(5.8)
			assert_eq(c.app.ui.popup, nil)
			local music = c.E.posted("music", "main:/audio#audio")
			local concert_music
			for _, m in ipairs(music) do
				if m.message.all == true then concert_music = m end
			end
			assert_true(concert_music ~= nil, "the full song (every stem and the party layer) played")
		end)
	end)

	it("says the whole town shines when every district is built", function()
		G.with_town({ setup = function(app)
			for _, d in ipairs(app.meta:districts()) do G.build_tasks(app, d.id) end
		end }, function(c)
			assert_eq(c.app.ui.card, "done")
			assert_true(c.town:has_text("The whole town is shining!", true))
			assert_eq(c.app.ui.nav.count, 5)
			assert_eq(c.app.ui.district, "garage")
			-- paging all the way back works through every district
			for _ = 1, 4 do
				tap_target(c, "nav_prev")
				c.run(1)
			end
			assert_eq(c.app.ui.district, "cafe")
			assert_eq(c.app.ui.nav.prev, nil)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("plays the task, the rewards, the chest and the gift under reduced motion too", function()
		G.with_town({ setup = function(app)
			app.set_setting("reduced_motion", true)
			G.win(app, 9)
		end }, function(c)
			local res = G.win(c.app, 1) -- level 10: a chest, a star for the first task
			c.app.push_reward(res)
			wait_for(c, function() return c.app.ui.popup == "chest" end, 8, "the chest")
			popup_target(c, "chest")
			wait_for(c, function() return c.app.ui.popup_targets and c.app.ui.popup_targets.collect ~= nil end, 3, "the open chest")
			popup_target(c, "collect")
			wait_for(c, function() return not c.app.ui.busy end, 8, "the flights")
			assert_eq(c.app.ui.disp.coins, c.app.meta:coins())
			-- a task with the stars of the wins
			assert_true(c.app.meta:next_task().affordable)
			tap_target(c, "task")
			wait_for(c, function() return not c.app.ui.busy end, 8, "the task")
			assert_eq(c.app.meta:district("cafe").done, 1)
			assert_eq(#c.E.posted("unlock_stem", "main:/audio#audio"), 1)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("does not lose a tap when the bars change between the press and the release", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local tg = c.app.ui.targets.task
			local used = c.E.input(hash("touch"), c.E.touch_action(tg.x, tg.y, true, false))
			assert_true(used ~= nil)
			-- the meta changes under the finger: the bars want a rebuild, but wait for the release
			c.app.meta:grant({ coins = 5 }, "test_gift", c.app.now())
			c.app.commit("test")
			c.step(4)
			c.E.input(hash("touch"), c.E.touch_action(tg.x, tg.y, false, true))
			c.step(2)
			assert_eq(c.app.meta:district("cafe").done, 1)
			wait_for(c, function() return not c.app.ui.busy end, 6, "the task")
			-- and the bars did get rebuilt afterwards
			assert_true(c.town:has_text("Warm lamps", true))
		end)
	end)

	it("does not lose a tap on a window button when the window is rebuilt under the finger", function()
		G.with_town({}, function(c)
			c.app.open_popup("settings")
			c.run(0.6)
			local t = c.app.ui.popup_targets.haptics
			c.E.input(hash("touch"), c.E.touch_action(t.x, t.y, true, false))
			c.step(2)
			c.app.set_setting("language", "ru") -- every window rebuilds (the bus event reaches it next frame)
			c.step(4)
			c.E.input(hash("touch"), c.E.touch_action(t.x, t.y, false, true))
			c.step(3)
			assert_false(c.app.meta:settings().haptics)
			c.run(0.3)
			assert_true(c.town:has_text("Настройки", true), G.dump(c.town)) -- rebuilt in Russian after the release
		end)
	end)

	it("keeps only the pictures of the district on display in memory", function()
		G.with_town({ setup = function(app) G.build_tasks(app, "cafe") end }, function(c)
			-- the loose district pictures alive now (Bit's frames are shared by every district and kept)
			local function district_pictures()
				local out = {}
				for _, key in ipairs(c.town:loose_images()) do
					if string.sub(key, 1, 10) == "districts/" then out[#out + 1] = key end
				end
				return out
			end
			local function only_of(list, did)
				for _, key in ipairs(list) do
					assert_true(string.find(key, "^districts/" .. did .. "/") ~= nil, "'" .. key .. "' is not a picture of " .. did)
				end
			end
			local jazz = district_pictures() -- its background, its items (restored and ghost looks)
			assert_true(#jazz >= 6, "jazz pictures: " .. #jazz)
			only_of(jazz, "jazz")
			tap_target(c, "nav_prev")
			wait_for(c, function() return c.app.ui.district == "cafe" and not c.app.ui.sliding end, 3, "paging back")
			c.run(0.5)
			local cafe = district_pictures()
			assert_true(#cafe >= 6, "cafe pictures: " .. #cafe)
			only_of(cafe, "cafe") -- everything of jazz is gone
			-- and back: a visit costs no memory
			tap_target(c, "back")
			wait_for(c, function() return c.app.ui.district == "jazz" and not c.app.ui.sliding end, 3, "paging forward")
			c.run(0.5)
			assert_same(district_pictures(), jazz)
			-- the day / concert look swaps the background instead of adding one
			tap_target(c, "view")
			c.run(1)
			local concert = district_pictures()
			assert_eq(#concert, #jazz)
			only_of(concert, "jazz")
			-- Bit has one picture per mood, at most
			local bits = 0
			for _, key in ipairs(c.town:loose_images()) do
				if string.sub(key, 1, 4) == "bit/" then bits = bits + 1 end
			end
			assert_true(bits >= 1 and bits <= #require("client.bit").MOODS, "Bit pictures: " .. bits)
		end)
	end)
end)

-- How many visible nodes of the town scene play each of these ui atlas flipbooks ("note_on" = ui_icons_note_on).
local function flipbooks(c, ...)
	local want, out = {}, {}
	for _, id in ipairs({ ... }) do
		want["ui_icons_" .. id] = id
		out[id] = 0
	end
	for _, n in ipairs(c.E.alive_nodes(c.E.scene("/screens/town/town.gui"))) do
		local id = want[n.anim]
		if id and c.E.visible(n) then out[id] = out[id] + 1 end
	end
	return out
end

describe("screens/town: hit-streak notes of locked boosters (decisions.md item 11)", function()
	it("draws them closed (a faded note with a padlock), not lit, in the town and in the start window", function()
		-- level 14 after wins on 12 and 13: the streak is 2, but the Subwoofer opens at level 16 and the Disco ball at 22
		G.with_town({ setup = function(app) G.win(app, 13) end }, function(c)
			assert_eq(c.app.meta:level_to_play(), 14)
			local v = c.town.self.t.hud.level_view
			assert_true(v.notes[1].unlocked and v.notes[2].lit and not v.notes[2].unlocked and not v.notes[3].unlocked)
			local hud = flipbooks(c, "note_on", "note_off", "lock")
			assert_same(hud, { note_on = 1, note_off = 2, lock = 2 })
			c.town:tap_text("Level 14")
			c.step(30)
			assert_eq(c.app.ui.popup, "start")
			local win = flipbooks(c, "note_on", "note_off")
			assert_eq(win.note_on - hud.note_on, 1, "the strip of the window lights the Riff note only")
			assert_eq(win.note_off - hud.note_off, 2)
			assert_eq(#c.E.audit(), 0)
		end)
		-- level 16: the Subwoofer is open, the Disco ball still closed although three wins are counted
		G.with_town({ setup = function(app) G.win(app, 15) end }, function(c)
			assert_eq(c.app.meta:level_to_play(), 16)
			assert_same(flipbooks(c, "note_on", "note_off", "lock"), { note_on = 2, note_off = 1, lock = 1 })
		end)
		-- before level 12 no streak runs: plain empty notes, no padlocks (the whole widget is not there yet)
		G.with_town({}, function(c)
			assert_same(flipbooks(c, "note_on", "note_off", "lock"), { note_on = 0, note_off = 3, lock = 0 })
		end)
		-- level 12: the streak starts, only the Riff slot is open
		G.with_town({ setup = function(app) G.win(app, 11) end }, function(c)
			assert_eq(c.app.meta:level_to_play(), 12)
			assert_same(flipbooks(c, "note_on", "note_off", "lock"), { note_on = 0, note_off = 3, lock = 2 })
		end)
		-- level 22 on: everything is open and the notes follow the streak alone
		G.with_town({ setup = function(app) G.win(app, 21) end }, function(c)
			assert_eq(c.app.meta:level_to_play(), 22)
			assert_same(flipbooks(c, "note_on", "note_off", "lock"), { note_on = 3, note_off = 0, lock = 0 })
		end)
	end)

	it("lets only the open notes pop when the streak is shown, and keeps the closed ones closed", function()
		G.with_town({ setup = function(app) G.win(app, 13) end }, function(c)
			local t = c.town.self.t
			c.town:ctx(function()
				assert_true(t.hud:note_open(1))
				assert_false(t.hud:note_open(2))
				assert_true(t.hud:streak_pop(1))
				assert_false(t.hud:streak_pop(2), "a closed note does not light up")
			end)
			-- the reward step of a win that made the streak 2: one pop (the Riff note), no more
			local steps = require("screens.town.steps")
			local pops = 0
			local real = t.hud.streak_pop
			t.hud.streak_pop = function(self, i)
				local ok = real(self, i)
				if ok then pops = pops + 1 end
				return ok
			end
			c.app.push_reward({ won = true, streak = 2, level_id = 13 })
			c.run(3)
			assert_eq(pops, 1)
			assert_false(c.app.ui.busy)
			assert_eq(steps ~= nil, true)
		end)
	end)
end)

describe("client/fx.lua on the strict stub: pop, shake and loops", function()
	local function scale_of(c, node) return c.town:ctx(function() return gui.get_scale(node) end) end
	local function pos_of(c, node) return c.town:ctx(function() return gui.get_position(node) end) end

	it("settles a popped button back to its rest scale, not to the pressed one (a pop from its on_click)", function()
		G.with_town({}, function(c)
			local node = c.town.self.t.hud.nav.town
			local tg = c.app.ui.targets.nav_town
			-- a finger held for six frames: the press has shrunk the button when the release pops it
			c.E.input(hash("touch"), c.E.touch_action(tg.x, tg.y, true, false))
			c.step(6)
			assert_true(scale_of(c, node).x < 0.95, "pressed: " .. scale_of(c, node).x)
			c.E.input(hash("touch"), c.E.touch_action(tg.x, tg.y, false, true))
			c.run(1)
			assert_near(scale_of(c, node).x, 1, 1e-6)
			-- and a quick tap, again
			tap_target(c, "nav_town")
			c.run(1)
			assert_near(scale_of(c, node).x, 1, 1e-6)
			assert_near(scale_of(c, node).y, 1, 1e-6)
		end)
	end)

	it("shakes a node in place after the window changed shape (the y of an anchored node follows the window)", function()
		local hud_mod = require("screens.town.hud")
		G.with_town({}, function(c)
			local t = c.town.self.t
			local card = t.hud.card
			local x0 = pos_of(c, card).x
			c.town:ctx(function() t:on_task(nil) end) -- not enough stars: a refusal, the card shakes
			c.run(0.7)
			assert_near(pos_of(c, card).x, x0, 1e-6)
			c.E.set_window(720, 1600) -- taller: the bottom edge anchor moves
			c.step(3)
			local want = t.ui:anchored_y(hud_mod.TASK_Y, "bottom")
			assert_near(pos_of(c, card).y, want, 1e-6, "anchored after the resize")
			c.town:ctx(function() t:on_task(nil) end)
			c.step(10)
			assert_near(pos_of(c, card).y, want, 1e-6, "the y is not touched while it shakes")
			c.run(0.7)
			assert_near(pos_of(c, card).x, x0, 1e-6)
			assert_near(pos_of(c, card).y, want, 1e-6, "and not put back to the old anchor")
		end)
	end)

	it("lets a run of quick shakes return the node to where it rested", function()
		G.with_town({}, function(c)
			local t = c.town.self.t
			local card = t.hud.card
			local x0 = pos_of(c, card).x
			for _ = 1, 6 do
				c.town:ctx(function() t.fx:shake(card, 14, 0.4) end)
				c.step(5) -- the next one starts while this one is still away from home
			end
			c.run(1)
			assert_near(pos_of(c, card).x, x0, 1e-6)
		end)
	end)

	it("plays a PINGPONG loop through a whole cycle per period: the bob and the wiggle", function()
		local fxm = require("client.fx")
		local kit = require("gui.kit")
		G.with_town({}, function(c)
			local bob, wig
			c.town:ctx(function()
				bob = gui.new_box_node(vmath.vector3(0, 100, 0), vmath.vector3(10, 10, 0))
				wig = gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(10, 10, 0))
				fxm.bob(bob, 10, 2.0)
				kit.wiggle(wig, 0.1, 2.0)
			end)
			local y0 = 100
			-- INOUTSINE: halfway up at a quarter of the period, at the top at a half, back home at the full period
			local function at(seconds)
				c.town:step(math.floor(seconds * 60 + 0.5))
			end
			at(0.5)
			assert_near(pos_of(c, bob).y - y0, 5, 0.3, "a quarter")
			at(0.5)
			assert_near(pos_of(c, bob).y - y0, 10, 0.05, "the top at half the period")
			assert_near(scale_of(c, wig).x, 1.1, 0.002)
			at(1.0)
			assert_near(pos_of(c, bob).y - y0, 0, 0.05, "home after one period")
			assert_near(scale_of(c, wig).x, 1, 0.002)
		end)
	end)
end)

describe("client/ui.lua buttons on the strict stub", function()
	it("fades the icon and the label of a disabled or dimmed button with its face", function()
		G.with_town({ setup = function(app) G.build_tasks(app, "cafe") end }, function(c)
			local t = c.town.self.t
			-- the end of the street: Jazz is the last open district, its "next" arrow is disabled
			local dim, lit
			for _, b in ipairs(t.ui.buttons) do
				if b.spec.icon == "ui/icons/arrow" and b.spec.sfx == "button" then
					if b.enabled then lit = b else dim = b end
				end
			end
			assert_true(dim ~= nil and lit ~= nil, "a disabled and an enabled arrow")
			assert_near(c.E.opacity(dim.node), 0.55, 1e-6)
			assert_near(c.E.opacity(dim.icon), 0.55, 1e-6, "the arrow on a faded face")
			assert_near(c.E.opacity(lit.icon), 1, 1e-6)
		end)
		-- the web demo cannot sell: the price buttons of the shop are dimmed, their prices with them
		G.with_town({}, function(c)
			c.app.open_popup("shop", { tab = "coins" })
			c.run(0.7)
			local price = c.town:find("$0.99")
			assert_true(price ~= nil, G.dump(c.town))
			assert_near(c.E.opacity(price), 0.8, 1e-6)
		end)
	end)
end)

describe("the strict stub's audit of texts", function()
	it("flags an outline or a shadow on a font that bakes none (it would not show on the device)", function()
		G.with_town({}, function(c)
			local t = c.town.self.t
			assert_same(c.E.audit(), {})
			c.town:ctx(function()
				t.ui:text(t.c_ui, "Visible", 100, 100, { font = "button", size = 30, color = "white", outline = "#B35F00", shadow = "#B35F00" })
				t.ui:text(t.c_ui, "Lost outline", 100, 140, { font = "small", size = 24, color = "white", outline = "#B35F00" })
				t.ui:text(t.c_ui, "Lost shadow", 100, 180, { font = "body", size = 24, color = "white", shadow = "#B35F00" })
			end)
			local problems = c.E.audit()
			assert_eq(#problems, 2, table.concat(problems, " | "))
			assert_true(string.find(problems[1], "an outline on the font 'small'", 1, true) ~= nil or string.find(problems[2], "an outline on the font 'small'", 1, true) ~= nil)
			assert_true(string.find(table.concat(problems), "a shadow on the font 'body'", 1, true) ~= nil)
		end)
	end)
end)
