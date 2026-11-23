-- The town screen (screens/town) executed on the strict Defold GUI stub (tests/client/town_defold_stub.lua):
-- what it shows, what a tap does, the animated steps, district paging, hints, language, window sizes.

local G = require("tests.client.meta_gui_helper")
local A = require("tests.client.layout_audit")
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

-- Runs fn(c) on a town with a (mock) server connected: the navigation then has Band and Chart. The provider is
-- global state: it is taken away again whatever happens, or the next test would meet five tabs.
local function with_server(fn, setup)
	local social = require("client.services.social")
	local social_engine = require("client.social")
	local ok, err = pcall(function()
		G.with_town({ setup = function(app, c)
			social_engine.reset()
			social.set_provider(require("client.services.social_mock").new())
			if setup then setup(app, c) end
		end }, fn)
	end)
	social.set_provider(nil)
	social_engine.reset()
	if not ok then error(err, 0) end
end

describe("screens/town/town.gui_script", function()
	it("builds the first town: top bar, task card, level button, navigation", function()
		G.with_town({}, function(c)
			local t = c.town
			for _, text in ipairs({ "Full", "500", "0", "Lo-fi Café", "Track layers: 0/6", "Concert", "Turntable",
				"Adds Beat to the track", "Level 1", "Shop", "Town", "Songbook", "Jukebox" }) do
				assert_true(t:has_text(text, true), "no '" .. text .. "' in: " .. G.dump(t))
			end
			-- no server is connected: Band and Chart would only say so, they are not on the navigation at all
			for _, text in ipairs({ "Band", "Chart" }) do
				assert_false(t:has_text(text, true), "'" .. text .. "' is shown without a server")
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

	it("prints the track-layers caption of the ribbon in white on a dark capsule that covers it", function()
		-- the ribbon face is up to #AA74F7 under the glyphs (3.2:1 for white, 2.7 for the old #F1E6FF) and the font "small" has
		-- no shadow: the capsule is what brings the thin caption to 4.5:1
		local lightest = { 0xAA / 255, 0x74 / 255, 0xF7 / 255 }
		for _, case in ipairs({ { "en", "Track layers: 0/6" }, { "ru", "Слоёв трека: 0 из 6" }, { "ko", "트랙 레이어: 0/6" } }) do
			local lang, text = case[1], case[2]
			G.with_town({ language = lang }, function(c)
				local E = c.E
				local caption = c.town:find(text)
				assert_true(caption ~= nil, lang .. ": " .. G.dump(c.town))
				local col = caption.color
				assert_true(col.x > 0.99 and col.y > 0.99 and col.z > 0.99, lang .. ": the caption is white")
				-- the capsule: a box of the ribbon drawn before the caption, in the colour of the segments below
				local capsule, order
				for i, n in ipairs(caption.parent.children) do
					if n == caption then order = i end
				end
				for i, n in ipairs(caption.parent.children) do
					if n.kind == "box" and n.size.y == 22 and math.abs(n.color.x - 0x6C / 255) < 0.01 and math.abs(n.color.y - 0x32 / 255) < 0.01
						and math.abs(n.color.z - 0xCF / 255) < 0.01 then
						capsule = n
						assert_true(i < order, lang .. ": the capsule is drawn under the caption")
					end
				end
				assert_true(capsule ~= nil, lang .. ": no capsule under the caption")
				local a = capsule.color.w
				local r, g, b = lightest[1] + (capsule.color.x - lightest[1]) * a, lightest[2] + (capsule.color.y - lightest[2]) * a,
					lightest[3] + (capsule.color.z - lightest[3]) * a
				local ratio = A.contrast(1, 1, 1, r, g, b)
				assert_true(ratio >= A.SOFT_NORM, string.format("%s: white on the capsule over the lightest ribbon pixel is %.2f:1", lang, ratio))
				-- it covers the caption with a margin on both sides and sits on its middle line
				local x0, y0, x1, y1 = E.rect(capsule)
				local ax, ay = E.to_logical(x0, y0)
				local bx, by = E.to_logical(x1, y1)
				local cx0, cx1, cy0, cy1 = math.min(ax, bx), math.max(ax, bx), math.min(ay, by), math.max(ay, by)
				for _, row in ipairs(A.texts(c)) do
					if row.node == caption then
						assert_true(cx0 <= row.rect[1] - 12 and cx1 >= row.rect[3] + 12, string.format("%s: the capsule %.0f-%.0f covers the text %.0f-%.0f", lang, cx0, cx1, row.rect[1], row.rect[3]))
						-- (the stub places a text by a line-box model: within 3 px of the capsule's middle is what the engine shows centred)
						local dy = math.abs((cy0 + cy1) / 2 - (row.rect[2] + row.rect[4]) / 2)
						assert_true(dy <= 3 and cy1 - cy0 >= 20, string.format("%s: the capsule %.0f-%.0f sits on the text %.0f-%.0f", lang, cy0, cy1, row.rect[2], row.rect[4]))
					end
				end
			end)
		end
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

	it("never shows a minus: a reward spent before its flight (boosters bought in the next level) leaves zero", function()
		G.with_town({}, function(c)
			local res = G.win(c.app, 1)
			-- the player spent almost everything, the reward of the win included, before coming back to the town
			assert_true(c.app.meta:_change("test_spend", { { "coins", -(c.app.meta:coins() - 10) } }))
			c.app.push_reward(res)
			c.step(5)
			assert_eq(c.app.meta:coins(), 10)
			assert_eq(c.app.ui.disp.coins, 0, "not 10 minus the reward")
			assert_true(c.app.ui.disp.stars >= 0)
			wait_for(c, function() return not c.app.ui.busy end, 8, "the reward show")
			assert_eq(c.app.ui.disp.coins, 10)
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
			assert_false(c.town:has_text("Tap to build!", true), "the card has no hint line (producer, 12.11.2026)")
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
			assert_true(c.town:has_text("Buy the first layer: the town will play music!", true), G.dump(c.town))
			c.app.set_setting("language", "ru") -- rebuilds the bars: the hint is still one analytics event
			c.step(5)
			assert_eq(count_events("tutorial_step"), 1)
			c.app.set_setting("language", "en")
			c.step(5)
			tap_target(c, "task")
			wait_for(c, function() return not c.app.ui.busy end, 6, "the task")
			assert_eq(c.app.ui.hint, nil)
			assert_true(c.app.meta:tutorial_seen("town_first_task"))
			assert_false(c.town:has_text("Buy the first layer: the town will play music!", true))
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

	-- The first purchase is the first music a new player hears (nothing plays before it): the bubble over the very first
	-- task says so. It sits in a bubble of two lines.
	it("promises music in the hint over the first task, in every language, within the bubble", function()
		local want = {
			en = "Buy the first layer: the town will play music!",
			ru = "Купи первый слой: в городе зазвучит музыка!",
			ko = "첫 레이어를 추가하면 마을에 음악이 울려 퍼져요!",
		}
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			G.with_town({ language = lang, setup = function(app) G.win(app, 1) end }, function(c)
				assert_eq(c.app.ui.hint, "town_first_task", lang)
				local node = c.town:find(want[lang])
				assert_true(node ~= nil, lang .. ": the hint is on the screen: " .. G.dump(c.town))
				-- no shrinking to a whisper: the bubble holds two lines of 28 px
				local px = c.E.text_px(node)
				assert_true(px >= 24, lang .. ": the hint is only " .. string.format("%.1f", px) .. " px")
				-- ...and the words wrap into two lines at most in the width of the bubble (490 logical px), in the font the
				-- text really uses
				local lines = c.town:ctx(function()
					local font = gui.get_font_resource(gui.get_font(node))
					local one = resource.get_text_metrics(font, "Ag").height
					local m = resource.get_text_metrics(font, want[lang], { width = 490, line_break = true })
					return math.floor(m.height / one + 0.5)
				end)
				assert_true(lines <= 2, lang .. ": the hint takes " .. lines .. " lines")
				assert_eq(#c.E.audit(), 0, lang .. ": every glyph of the hint is in the font")
			end)
		end
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
				assert_near(tg.nav_shop.y, 82 + sr.y0, 0.01, "navigation " .. w[1] .. "x" .. w[2])
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

	it("has four tabs without a server (Shop, Town, Songbook, Jukebox), spread over the plate, and each opens its window", function()
		G.with_town({}, function(c)
			local tg = c.app.ui.targets
			local hud = c.town.self.t.hud
			assert_false(hud.online)
			-- Band and Chart are not there: nothing drawn, nothing to tap
			assert_eq(tg.nav_band, nil)
			assert_eq(tg.nav_chart, nil)
			assert_eq(hud.nav.band, nil)
			assert_eq(hud.nav.chart, nil)
			-- the four tabs share the plate (centre x = 360) 172 px apart, the town one second from the left
			for i, id in ipairs({ "shop", "town", "notebook", "jukebox" }) do
				assert_true(tg["nav_" .. id] ~= nil, "no tab '" .. id .. "'")
				assert_near(tg["nav_" .. id].x, 360 + (i - 2.5) * 172, 0.01, id)
				assert_near(tg["nav_" .. id].y, tg.nav_shop.y, 0.01, id)
			end
			-- the small songbook button under the concert toggle is gone: its tab is the one place (and the QA name `notebook`)
			assert_eq(hud.notebook_btn, nil)
			assert_near(tg.notebook.x, tg.nav_notebook.x, 0.01)
			assert_near(tg.notebook.y, tg.nav_notebook.y, 0.01)
			tap_target(c, "nav_notebook")
			c.run(0.7)
			assert_eq(c.app.ui.popup, "notebook")
			assert_eq(c.app.ui.notebook.district, "cafe")
			c.app.close_popup()
			c.run(0.6)
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
			-- the town tab is the one we are on: no window
			tap_target(c, "nav_town")
			c.run(0.6)
			assert_eq(c.app.ui.popup, nil)
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

	it("shows the five tabs again when a server is connected: Band and Chart work, the songbook keeps its small button", function()
		with_server(function(c)
			local tg = c.app.ui.targets
			local hud = c.town.self.t.hud
			assert_true(hud.online)
			-- Shop | Band | Town | Chart | Jukebox, 138 px apart around the centre of the plate: as the bar always had them
			for i, id in ipairs({ "shop", "band", "town", "chart", "jukebox" }) do
				assert_true(tg["nav_" .. id] ~= nil, "no tab '" .. id .. "'")
				assert_near(tg["nav_" .. id].x, 360 + (i - 3) * 138, 0.01, id)
			end
			assert_near(tg.nav_shop.x, 84, 0.01)
			assert_near(tg.nav_jukebox.x, 636, 0.01)
			for _, text in ipairs({ "Shop", "Band", "Town", "Chart", "Jukebox" }) do
				assert_true(c.town:has_text(text, true), "no '" .. text .. "'")
			end
			-- the songbook has no tab here: its small button under the concert toggle stays, so it is never out of reach
			assert_eq(tg.nav_notebook, nil)
			assert_false(c.town:has_text("Songbook", true))
			assert_true(hud.notebook_btn ~= nil)
			assert_near(tg.notebook.x, 652, 0.01)
			tap_target(c, "nav_band")
			c.run(0.7)
			assert_eq(c.app.ui.popup, "band")
			assert_eq(c.app.ui.band.stage, "signin") -- a server, but nobody signed in
			c.app.close_popup()
			c.run(0.6)
			tap_target(c, "nav_chart")
			c.run(0.7)
			assert_eq(c.app.ui.popup, "chart")
			assert_eq(c.app.ui.chart.stage, "signin")
			c.app.close_popup()
			c.run(0.6)
			tap_target(c, "notebook")
			c.run(0.7)
			assert_eq(c.app.ui.popup, "notebook")
			c.app.close_popup()
			c.run(0.6)
			tap_target(c, "nav_shop")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "shop")
			c.app.close_popup()
			c.run(0.6)
			tap_target(c, "nav_jukebox")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "jukebox")
		end)
	end)

	it("builds the navigation by the server flag: four tabs, then five, then four again", function()
		local hud_mod = require("screens.town.hud")
		local function ids(list)
			local out = {}
			for i, item in ipairs(list) do out[i] = item.id end
			return out
		end
		assert_same(ids(hud_mod.nav_items(false)), { "shop", "town", "notebook", "jukebox" })
		assert_same(ids(hud_mod.nav_items(true)), { "shop", "band", "town", "chart", "jukebox" })
		-- Town is the lit tab, the songbook one is an ordinary tab with its own icon and label
		local notebook
		for _, item in ipairs(hud_mod.nav_items(false)) do
			if item.id == "town" then assert_true(item.active) end
			if item.id == "notebook" then notebook = item end
		end
		assert_eq(notebook.icon, "ui/icons/notebook")
		assert_eq(notebook.label, "nav.notebook")
		-- the five tabs sit where the bar always put them; four are spread over the same plate
		for i = 1, 5 do assert_eq(hud_mod.nav_x(i, 5), -276 + (i - 1) * 138) end
		for i = 1, 4 do assert_eq(hud_mod.nav_x(i, 4), -258 + (i - 1) * 172) end
		-- the same town, a server connecting while it is open: the next drawing has Band and Chart
		G.with_town({}, function(c)
			local social = require("client.services.social")
			local social_engine = require("client.social")
			local hud = c.town.self.t.hud
			assert_eq(c.app.ui.targets.nav_band, nil)
			local ok, err = pcall(function()
				social.set_provider(require("client.services.social_mock").new())
				c.town.self.t.dirty_ui = true
				c.step(3)
				assert_true(hud.online)
				assert_true(c.app.ui.targets.nav_band ~= nil and c.app.ui.targets.nav_chart ~= nil)
				assert_eq(c.app.ui.targets.nav_notebook, nil)
			end)
			social.set_provider(nil)
			social_engine.reset()
			if not ok then error(err, 0) end
			c.town.self.t.dirty_ui = true
			c.step(3)
			assert_false(hud.online)
			assert_eq(c.app.ui.targets.nav_band, nil)
			assert_true(c.app.ui.targets.nav_notebook ~= nil)
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("keeps the 'Soon' mechanism for a tab that is not ready: dimmed, a badge, a toast, no window", function()
		local hud_mod = require("screens.town.hud")
		local real = hud_mod.nav_items
		hud_mod.nav_items = function(online)
			local list = real(online)
			for _, item in ipairs(list) do
				if item.id == "notebook" then item.soon = true end
			end
			return list
		end
		local ok, err = pcall(function()
			G.with_town({}, function(c)
				assert_true(c.town:has_text("Soon", true), "the badge of a tab that is not ready")
				tap_target(c, "nav_notebook")
				c.run(0.7)
				assert_eq(c.app.ui.popup, nil)
				assert_eq(c.app.overlay.toast, "Coming soon!")
			end)
		end)
		hud_mod.nav_items = real
		if not ok then error(err, 0) end
	end)

	it("keeps the dot of a finished song on the small songbook button while the five tabs are shown", function()
		local flow = require("client.flow")
		with_server(function(c)
			local hud = c.town.self.t.hud
			assert_true(hud.online)
			assert_true(c.app.meta:songbook_pending() ~= nil)
			assert_true(hud.notebook_btn ~= nil)
			assert_true(hud.notebook_dot ~= nil, "no dot on the small button")
			assert_eq(c.app.ui.targets.nav_notebook, nil)
		end, function(app)
			for _ = 1, 20 do assert(flow.debug_win(3, false, true)) end
		end)
	end)

	it("puts the dot of a finished song on the songbook tab, and takes it away when the song was looked at", function()
		local flow = require("client.flow")
		G.with_town({ setup = function(app)
			for _ = 1, 20 do assert(flow.debug_win(3, false, true)) end -- the song of the cafe is finished and not offered yet
		end }, function(c)
			local hud = c.town.self.t.hud
			assert_true(c.app.meta:songbook_pending() ~= nil)
			-- the songbook tab carries the dot (a pink disc at the corner of its icon), the small button is not there to carry it
			assert_true(hud.notebook_dot ~= nil, "no dot on the tab")
			assert_eq(hud.notebook_btn, nil)
			c.run(2.5) -- the finished song is offered: the notebook opens on it and marks it as seen
			assert_eq(c.app.ui.popup, "notebook")
			assert_eq(c.app.meta:songbook_pending(), nil)
			assert_eq(hud.notebook_dot, nil, "the dot is gone once the song was seen")
			assert_eq(#c.E.audit(), 0)
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
			local list = c.app.meta:districts()
			assert_eq(#list, 15)
			assert_eq(c.app.ui.nav.count, #list)
			assert_eq(c.app.ui.district, list[#list].id)
			assert_eq(c.app.ui.district, "arcade")
			-- paging all the way back works through every district
			for _ = 1, #list - 1 do
				tap_target(c, "nav_prev")
				c.run(1)
			end
			assert_eq(c.app.ui.district, "cafe")
			assert_eq(c.app.ui.nav.prev, nil)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("plays the task, the rewards, a queued paid chest (QA reward) and the gift under reduced motion too", function()
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
			-- Bit has the pictures of its animations (loaded when first shown), at most
			local bits = 0
			for _, key in ipairs(c.town:loose_images()) do
				if string.sub(key, 1, 4) == "bit/" then bits = bits + 1 end
			end
			local all = 0
			for _ in pairs(require("client.bit").images()) do all = all + 1 end -- order-free: a count
			assert_true(bits >= 1 and bits <= all, "Bit pictures: " .. bits .. " of " .. all)
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

-- the web build downloads the pictures of every district but the first one (client/packs.lua)
describe("screens/town: the room while its pictures download (the web build)", function()
	it("shows a note with the progress, then draws the room once when the pictures came", function()
		local calls = {}
		G.with_town({ setup = function(app)
			G.build_tasks(app, "cafe") -- the player is in the second district now
			local assets = require("client.assets")
			require("client.packs").init({
				base = "https://host/game/", clock = function() return 0 end,
				images = assets.index.images, groups = assets.index.packs,
				request = function(url, done) calls[#calls + 1] = { url = url, done = done } end,
			})
		end }, function(c)
			local packs = require("client.packs")
			local assets = require("client.assets")
			local scene_mod = require("screens.town.scene")
			local t = c.town.self.t
			local did = t.district
			assert_true(did ~= "cafe" and assets.index.packs[did] ~= nil, "a district the web build downloads: " .. tostring(did))
			local view = c.app.meta:view(did)
			c.run(1)
			assert_true(c.town:find("Loading the district", true) ~= nil, "the note says the room is loading")
			assert_true((scene_mod.waiting(did, view)) > 0)
			local room = t.scene.room
			assert_true(room.waiting > 0)
			-- the downloads answer, a few at a time (at most PARALLEL requests run)
			local size = {}
			for _, e in pairs(assets.index.images) do -- order-free: a lookup
				if e.remote then size["https://host/game/" .. e.remote] = e.bytes end
			end
			local answered = 0
			for _ = 1, 200 do
				packs.update()
				local more = false
				for i = answered + 1, #calls do
					calls[i].done(200, string.rep("x", size[calls[i].url]))
					answered = i
					more = true
				end
				if not more then break end
			end
			c.run(2)
			assert_eq((scene_mod.waiting(did, view)), 0, "every picture of the room is here")
			assert_true(t.scene.room ~= room, "the room was drawn again")
			assert_eq(t.scene.room.waiting, 0)
			assert_eq(c.town:find("Loading the district", true), nil, "the note is gone")
			assert_same(c.E.audit(), {})
		end)
		require("client.packs")._reset()
	end)

	it("says 'no connection' when the downloads keep failing, and the town keeps working", function()
		local calls = {}
		G.with_town({ setup = function(app)
			G.build_tasks(app, "cafe")
			local assets = require("client.assets")
			require("client.packs").init({
				base = "https://host/game/", clock = function() return 0 end,
				images = assets.index.images, groups = assets.index.packs,
				request = function(url, done) calls[#calls + 1] = { url = url, done = done } end,
			})
		end }, function(c)
			local packs = require("client.packs")
			for _ = 1, 20 do
				packs.update()
				for i = 1, #calls do
					if not calls[i].seen then
						calls[i].seen = true
						calls[i].done(0, nil)
					end
				end
			end
			c.run(1)
			assert_true(packs.offline())
			assert_true(c.town:find("No connection", true) ~= nil, "the note says the pictures come later")
			assert_true(c.app.ui.targets and c.app.ui.targets.level ~= nil, "the level button is still there")
			assert_same(c.E.audit(), {})
		end)
		require("client.packs")._reset()
	end)
end)

-- When a layer enters the track Bit jumps with joy and then LISTENS to it (hands at the headphones, assets/images/bit/
-- listen_*). Bit:event("headphones") would be refused while the cheer runs (priority 2 against 0), so steps.lua asks
-- for the pose by name; a skip drops the show's timers, so it starts the pose itself.
describe("screens/town: Bit listens to the layer that enters", function()
	-- (the town's steps need the engine globals of the stub: required inside the tests, not when the file loads)
	local function steps() return require("screens.town.steps") end

	-- steps the frames of `seconds`; the poses Bit goes through: {{mood, at}}, the first is the pose it is in now
	local function watch(c, seconds)
		local bit = c.town.self.t.bit
		local out = { { mood = bit.mood, at = c.E.clock } }
		for _ = 1, math.ceil(seconds * 60) do
			c.step(1)
			if bit.mood ~= out[#out].mood then out[#out + 1] = { mood = bit.mood, at = c.E.clock } end
		end
		return out
	end

	local function moods(list)
		local out = {}
		for _, m in ipairs(list) do out[#out + 1] = m.mood end
		return out
	end

	local function when(list, mood)
		for _, m in ipairs(list) do
			if m.mood == mood then return m.at end
		end
		return nil
	end

	it("jumps with joy as the layer lights up, listens to it for 3.5 s after the jump, then rests", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			tap_target(c, "task")
			local list = watch(c, 7)
			assert_same(moods(list), { "happy", "cheer", "listen", "idle" })
			assert_near(when(list, "listen") - when(list, "cheer"), steps().LISTEN_AFTER, 0.1, "the pose follows the jump")
			assert_near(when(list, "idle") - when(list, "listen"), steps().LISTEN_FOR, 0.1, "it lasts 3.5 s")
			assert_false(c.app.ui.busy)
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("plays the listening animation of the headphones while it listens: the frames move", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local bit = c.town.self.t.bit
			tap_target(c, "task")
			local seen = {}
			for _ = 1, 60 * 5 do
				c.step(1)
				if bit.mood == "listen" then seen[bit.player:image()] = true end
			end
			local n = 0
			for key in pairs(seen) do -- order-free: a count and a check
				n = n + 1
				assert_true(string.find(key, "^bit/listen_[1-4]$") ~= nil, "a frame of the listen animation: " .. key)
			end
			assert_true(n >= 2, "the frames move while it listens")
		end)
	end)

	it("listens at once when a tap skips the show, for the same 3.5 s, and a late timer cannot start it again", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local bit = c.town.self.t.bit
			tap_target(c, "task")
			c.run(0.25) -- the stars still fly
			assert_true(c.app.ui.busy)
			assert_true(bit.mood ~= "listen")
			c.tap(360, 800) -- anywhere
			c.step(3)
			local t0 = c.E.clock
			assert_false(c.app.ui.busy)
			assert_eq(bit.mood, "listen")
			assert_eq(#c.E.posted("unlock_stem", "main:/audio#audio"), 1)
			c.run(3.2)
			assert_eq(bit.mood, "listen", "still at 3.2 s")
			c.run(0.5)
			assert_eq(bit.mood, "idle", "done at 3.7 s: " .. string.format("%.2f", c.E.clock - t0))
			-- nothing fires later: the show's timers were dropped with its effects
			c.run(1)
			assert_eq(bit.mood, "idle")
			assert_false(c.app.ui.busy)
		end)
	end)

	it("does not start the pose over when the tap comes while it already runs", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local bit = c.town.self.t.bit
			tap_target(c, "task")
			local t_listen
			for _ = 1, 60 * 4 do
				c.step(1)
				if bit.mood == "listen" then t_listen = c.E.clock break end
			end
			assert_true(t_listen ~= nil, "Bit listens")
			-- the pose starts 0.3 s before the show ends (1.2 s after the light-up, the show lasts 1.5 s): a tap now skips the
			-- last moments of it
			c.run(0.2)
			assert_true(c.app.ui.busy, "the show is still on")
			c.tap(360, 800)
			c.step(3)
			assert_false(c.app.ui.busy)
			assert_eq(bit.mood, "listen")
			-- 3.5 s after the START of the pose it is over: a restart at the tap would have kept it 0.25 s longer
			c.run(math.max(0, t_listen + steps().LISTEN_FOR + 0.1 - c.E.clock))
			assert_eq(bit.mood, "idle")
		end)
	end)

	it("keeps the pose as a still frame with reduced motion, with the same timing", function()
		G.with_town({ setup = function(app) G.win(app, 1); app.set_setting("reduced_motion", true) end }, function(c)
			local bit = c.town.self.t.bit
			assert_true(c.app.reduced_motion())
			tap_target(c, "task")
			local frames, list = {}, { { mood = bit.mood, at = c.E.clock } }
			for _ = 1, 60 * 8 do
				c.step(1)
				if bit.mood ~= list[#list].mood then list[#list + 1] = { mood = bit.mood, at = c.E.clock } end
				if bit.mood == "listen" then frames[bit.player:image()] = true end
			end
			assert_same(moods(list), { "happy", "cheer", "listen", "idle" })
			assert_near(when(list, "idle") - when(list, "listen"), steps().LISTEN_FOR, 0.1)
			assert_same(frames, { ["bit/listen_2"] = true }) -- the rest frame, hands at the headphones, no animation
		end)
	end)
end)

-- The soft glow of the item the next star buys (the grey instruments looked like closed decoration: ChatGPT review,
-- section 1, row 1). The rule is client/views.lua item_glow (unit tests: tests/client/meta_views_test.lua); here the nodes:
-- screens/town/scene.lua draws them, screens/town/town.gui_script asks every frame.
describe("screens/town: the glow of the item the next star buys", function()
	local SCENE = "/screens/town/town.gui"

	-- the glow nodes of the town (a halo with its light inside it), all rooms
	local function auras(c)
		local out = {}
		for _, n in ipairs(c.E.alive_nodes(c.E.scene(SCENE))) do
			if n.id == "aura" then out[#out + 1] = n end
		end
		return out
	end

	-- the live animations of a node and of the nodes under it
	local function anims_of(c, node)
		local count = 0
		for _, a in ipairs(c.E.scene(SCENE).anims) do
			local p = a.node
			while p do
				if p == node then
					count = count + 1
					break
				end
				p = p.parent
			end
		end
		return count
	end

	-- the animated properties of a node and of the nodes under it (the stub keeps one animation per component: a scale
	-- is three), as a sorted list without repeats
	local function anim_fields(c, node)
		local seen, out = {}, {}
		for _, a in ipairs(c.E.scene(SCENE).anims) do
			local p = a.node
			while p do
				if p == node then
					if not seen[a.field] then
						seen[a.field] = true
						out[#out + 1] = a.field
					end
					break
				end
				p = p.parent
			end
		end
		table.sort(out)
		return out
	end

	local function item_of(c, id) return c.town.self.t.scene.items[id] end

	-- the scene asked directly (its calls need the GUI context of the town script)
	local function set_glow(c, spec)
		c.town:ctx(function() c.town.self.t.scene:set_glow(spec) end)
	end

	-- the room (the child of the scene container) a node is in
	local function room_of(c, node)
		local scene_root = c.town.self.t.c_scene
		local p = node
		while p and p.parent ~= scene_root do p = p.parent end
		return p
	end

	-- the grey silhouette (picture `<district>/<item>_ghost`) in the same room as a glow
	local function silhouette_of(c, halo, key)
		local room = room_of(c, halo)
		for _, n in ipairs(c.E.alive_nodes(c.E.scene(SCENE))) do
			if n.texture == "img:districts/" .. key .. "_ghost" and room_of(c, n) == room then return n end
		end
	end

	local function is_inside(node, root)
		local p = node
		while p do
			if p == root then return true end
			p = p.parent
		end
		return false
	end

	it("glows the first silhouette once the first star is in the purse: under it, warm, soft, and the hint stays", function()
		G.with_town({}, function(c)
			assert_eq(#auras(c), 0, "no star yet: only grey silhouettes")
			assert_eq(c.app.ui.glow, nil)
		end)
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local t = c.town.self.t
			local halos = auras(c)
			assert_eq(#halos, 1)
			assert_eq(c.app.ui.glow, "turntable")
			assert_eq(t.scene:glowing(), "turntable")
			local halo, e = halos[1], item_of(c, "turntable")
			assert_eq(e.aura, halo)
			-- on the centre of the item, in the glow layer: the first child of the items layer, so under EVERY item of the room
			assert_eq(halo.parent, t.scene.glow_layer)
			assert_eq(t.scene.glow_layer.parent, t.scene.items_layer)
			assert_eq(t.scene.items_layer.children[1], t.scene.glow_layer)
			assert_near(halo.pos.x, e.x, 0.01)
			assert_near(halo.pos.y, e.y, 0.01)
			for id, item in pairs(t.scene.items) do -- order-free: every item is checked
				assert_true(item.holder.parent == t.scene.items_layer and item.holder ~= t.scene.glow_layer, id)
			end
			assert_eq(#t.scene.items_layer.children, 1 + 6, "the glow layer and one holder for each of the six items")
			assert_true(c.E.visible(e.node))
			assert_near(e.node.color.w, 1, 0.01, "the silhouette is as it was")
			-- a soft disc (no edge), warm, not opaque, bigger than the item but not the room
			assert_eq(halo.texture, "px_soft")
			assert_true(halo.color.x >= halo.color.y and halo.color.y > halo.color.z, "warm: red >= green > blue")
			assert_true(halo.color.w > 0.2 and halo.color.w < 0.9, "soft: alpha " .. halo.color.w)
			assert_true(halo.size.x > e.w and halo.size.y > e.h and halo.size.x < 500 and halo.size.y < 500)
			-- it belongs to the scene (it leaves with it), not to the bars: the hint and the card are untouched
			assert_true(is_inside(halo, t.c_scene))
			assert_false(is_inside(halo, t.c_ui))
			assert_eq(c.app.ui.hint, "town_first_task")
			assert_true(c.town:has_text("Buy the first layer: the town will play music!", true), G.dump(c.town))
			assert_true(t.hud.hint ~= nil and t.hud.card ~= nil)
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("glows later items too, from the moment their stars are in the purse, and not before", function()
		G.with_town({ setup = function(app) G.win(app, 1); G.build_tasks(app, "cafe", 2) end }, function(c)
			assert_eq(c.app.meta:next_task().id, "piano") -- costs 2, one star is left
			assert_eq(c.app.meta:stars(), 1)
			assert_eq(#auras(c), 0)
			assert_eq(c.app.ui.glow, nil)
			assert_eq(c.app.ui.hint, nil, "no hint any more: the glow is not the hint")
			G.give_stars(c.app, 1)
			c.step(3)
			assert_eq(#auras(c), 1)
			assert_eq(c.app.ui.glow, "piano")
			local t = c.town.self.t
			local halo = auras(c)[1]
			assert_eq(halo.parent, t.scene.glow_layer)
			assert_near(halo.pos.x, 160, 0.01)
			assert_near(halo.pos.y, 1280 - 690, 0.01)
			-- the restored items have their own gold glow and none of this one; the glow layer is under their holders, so
			-- the halo never washes the coloured neighbours of the piano
			assert_eq(item_of(c, "turntable").aura, nil)
			assert_eq(item_of(c, "lamps").aura, nil)
			assert_true(item_of(c, "turntable").glow ~= nil)
			assert_eq(t.scene.items_layer.children[1], t.scene.glow_layer)
			for _, id in ipairs({ "turntable", "lamps" }) do
				assert_true(item_of(c, id).holder.parent == t.scene.items_layer, id)
			end
		end)
	end)

	it("breathes: the halo swells a little and the light inside it brightens, 1.6 s a breath", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local ui = require("client.ui")
			local AURA = require("screens.town.scene").AURA
			local halo = auras(c)[1]
			assert_true(halo ~= nil)
			local light = halo.children[1]
			assert_true(light ~= nil and light.blend == c.E.gui.BLEND_ADD, "the light inside the halo adds its colour to the room")
			c.run(1) -- it has grown in by now
			assert_true(ui.is_pulsing(halo))
			local series, bright = {}, {}
			for i = 1, 60 * 5 do
				c.step(1)
				series[i], bright[i] = halo.scale.x, light.color.w
			end
			local lo, hi, i_lo, i_hi = math.huge, 0, 1, 1
			for i, s in ipairs(series) do
				if s < lo then lo, i_lo = s, i end
				if s > hi then hi, i_hi = s, i end
			end
			assert_true(hi - lo >= 0.03 and hi - lo <= 0.1, "a small amplitude: " .. string.format("%.3f", hi - lo))
			assert_near(lo, 1, 0.005)
			local peaks = {}
			for i = 2, #series - 1 do
				if series[i] >= series[i - 1] and series[i] > series[i + 1] and series[i] > (lo + hi) / 2 then peaks[#peaks + 1] = i end
			end
			assert_true(#peaks >= 2, "peaks " .. #peaks)
			local period = (peaks[#peaks] - peaks[1]) / (#peaks - 1) / 60
			assert_near(period, 1.6, 0.05, "one breath")
			-- the light follows the halo: brightest when the halo is biggest, at a share of it when it is smallest
			assert_near(bright[i_hi], AURA.light.alpha, 0.01)
			assert_near(bright[i_lo], AURA.light.alpha * AURA.dim, 0.01)
			assert_true(AURA.dim >= 0.5 and AURA.dim < 1, "a gentle change of brightness")
			assert_same(anim_fields(c, halo), { "color", "scale" }, "the breath and nothing else runs")
			assert_near(halo.color.w, AURA.halo.alpha, 1e-6, "the halo itself keeps its strength")
		end)
	end)

	it("stands still with reduced motion: the same glow at full strength at once, no pulse, no animation", function()
		local strength
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			c.run(1.2)
			strength = auras(c)[1].color.w
		end)
		G.with_town({ setup = function(app) G.win(app, 1); app.set_setting("reduced_motion", true) end }, function(c)
			local ui = require("client.ui")
			local halo = auras(c)[1]
			assert_true(halo ~= nil)
			assert_true(c.app.reduced_motion())
			assert_false(ui.is_pulsing(halo))
			assert_eq(anims_of(c, halo), 0)
			assert_near(halo.color.w, strength, 1e-6, "as strong as the one that breathes")
			assert_near(halo.scale.x, 1, 1e-6)
			local light = halo.children[1]
			assert_near(light.color.w, require("screens.town.scene").AURA.light.alpha, 1e-6, "the light at its full strength")
			c.run(3)
			assert_near(halo.scale.x, 1, 1e-6)
			assert_near(halo.color.w, strength, 1e-6)
			assert_near(light.color.w, require("screens.town.scene").AURA.light.alpha, 1e-6)
			assert_eq(anims_of(c, halo), 0)
			assert_eq(c.app.ui.glow, "turntable")
		end)
	end)

	it("changes to a standing glow when the player asks for less motion in the middle of a visit", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local ui = require("client.ui")
			c.run(1)
			assert_true(ui.is_pulsing(auras(c)[1]))
			c.app.set_setting("reduced_motion", true) -- the room is drawn again
			c.run(0.5)
			assert_eq(#auras(c), 1, "one glow, not two")
			local halo = auras(c)[1]
			assert_false(ui.is_pulsing(halo))
			assert_eq(anims_of(c, halo), 0)
			c.app.set_setting("reduced_motion", false)
			c.run(0.5)
			assert_eq(#auras(c), 1)
			assert_true(ui.is_pulsing(auras(c)[1]))
		end)
	end)

	it("goes out when the purchase starts, stays out while the show runs, and comes back on the next item", function()
		G.with_town({ setup = function(app) G.win(app, 1); G.give_stars(app, 1) end }, function(c)
			assert_eq(c.app.ui.glow, "turntable") -- two stars: the turntable and the lamps are both within reach
			tap_target(c, "task")
			c.step(2)
			assert_true(c.app.ui.busy)
			assert_eq(#auras(c), 0, "no glow while the stars fly and the item lights up")
			assert_eq(c.app.ui.glow, nil)
			for _ = 1, 60 * 4 do
				c.step(1)
				if not c.app.ui.busy then break end
				assert_eq(#auras(c), 0, "still none at " .. string.format("%.2f", c.E.clock))
			end
			assert_false(c.app.ui.busy)
			c.step(3)
			assert_eq(c.app.meta:next_task().id, "lamps")
			assert_eq(#auras(c), 1)
			assert_eq(c.app.ui.glow, "lamps")
			assert_eq(item_of(c, "turntable").aura, nil, "the item that was just built has its own gold glow")
			assert_true(item_of(c, "turntable").glow ~= nil)
			-- the item the show has just drawn again is over the halo of the next one, like every other item
			local t = c.town.self.t
			assert_eq(t.scene.items_layer.children[1], t.scene.glow_layer)
			assert_eq(auras(c)[1].parent, t.scene.glow_layer)
		end)
		-- one star only: the turntable is built and the lamps (1 star) are out of reach: nothing glows at the end
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			tap_target(c, "task")
			wait_for(c, function() return not c.app.ui.busy end, 6, "the task animation")
			c.run(1)
			assert_eq(c.app.meta:stars(), 0)
			assert_eq(#auras(c), 0)
			assert_eq(c.app.ui.glow, nil)
		end)
	end)

	it("lights a tap on it: the glowing silhouette is bought like the card", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			assert_eq(c.app.ui.glow, "turntable")
			c.tap(370, 1280 - 712) -- the silhouette of the turntable
			c.step(3)
			assert_true(c.app.ui.busy)
			assert_eq(c.app.ui.step, "task")
			assert_eq(c.app.meta:district("cafe").done, 1)
		end)
	end)

	it("takes its nodes and its animation away with it", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local t = c.town.self.t
			c.run(1)
			local halo = auras(c)[1]
			local with = c.town:stats()
			local pulse = anims_of(c, halo)
			assert_true(pulse > 0)
			set_glow(c, nil)
			local without = c.town:stats()
			assert_eq(#auras(c), 0)
			assert_eq(without.nodes, with.nodes - 2, "the halo and the light inside it")
			assert_eq(without.anims, with.anims - pulse, "the pulse")
			assert_eq(t.scene:glowing(), nil)
			assert_eq(item_of(c, "turntable").aura, nil)
			-- lit again, and again taken away: the same counts, nothing piles up
			for _ = 1, 3 do
				set_glow(c, { district = "cafe", id = "turntable" })
				c.run(1)
				assert_eq(#auras(c), 1)
				set_glow(c, nil)
			end
			local again = c.town:stats()
			assert_eq(again.nodes, without.nodes)
			assert_eq(again.anims, without.anims)
		end)
	end)

	it("is not lit twice for one item, and a glow asked for a grey item that is not there or is built does nothing", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			set_glow(c, { district = "cafe", id = "turntable" })
			set_glow(c, { district = "cafe", id = "turntable" })
			assert_eq(#auras(c), 1)
			set_glow(c, { district = "cafe", id = "no_such_item" })
			assert_eq(#auras(c), 0)
			set_glow(c, { district = "jazz", id = "stage_light" }) -- a room that is not on display
			assert_eq(#auras(c), 0)
			set_glow(c, { district = "cafe", id = "turntable" })
			assert_eq(#auras(c), 1)
		end)
		-- an item that is built (restored) never takes one
		G.with_town({ setup = function(app) G.win(app, 1); G.build_tasks(app, "cafe", 1) end }, function(c)
			set_glow(c, { district = "cafe", id = "turntable" })
			assert_eq(#auras(c), 0)
			assert_eq(item_of(c, "turntable").aura, nil)
		end)
	end)

	-- The size of the glow follows the size of the item, but only so far: a halo of 1.8 times the item and 90 px more made a
	-- band 911 px wide (the room is 720) of the square's garlands, and the whole window above it turned yellow.
	it("reaches out of an item by AURA.reach at most on each side: a wide item gets a halo that hugs it", function()
		G.with_town({ town = false }, function(c)
			local scene_mod = require("screens.town.scene")
			local A = scene_mod.AURA
			assert_true(A.reach >= 100 and A.reach <= 160, "a margin of one item's size or less: " .. tostring(A.reach))
			-- the rule on its own: a small item is as it was, a wide one is held at the reach, each side on its own
			local w, h = scene_mod.aura_size(147, 116, A.halo)
			assert_near(w, 147 * A.halo.mul + A.halo.pad, 1e-6, "a small item: size * mul + pad")
			assert_near(h, 116 * A.halo.mul + A.halo.pad, 1e-6)
			w, h = scene_mod.aura_size(456, 182, A.halo)
			assert_near(w, 456 + 2 * A.reach, 1e-6, "a wide item: the reach is the limit")
			assert_near(h, 182 * A.halo.mul + A.halo.pad, 1e-6, "its height is under the limit: as it was")
			w, h = scene_mod.aura_size(0, 0, A.halo)
			assert_true(w >= 0 and h >= 0 and w <= 2 * A.reach and h <= 2 * A.reach, "no item at all: a spot, not a hole")
			-- every item of every district, both discs of the glow
			local items, capped = 0, 0
			for did, lay in pairs(scene_mod.layouts()) do -- order-free: every item is looked at on its own
				for id, it in pairs(lay.items) do
					local iw, ih = it.w * it.scale, it.h * it.scale
					local name = did .. "/" .. id
					for _, p in ipairs({ A.halo, A.light }) do
						local dw, dh = scene_mod.aura_size(iw, ih, p)
						assert_true(dw >= iw and dh >= ih, name .. ": the disc covers the item")
						assert_true(dw - iw <= 2 * A.reach + 1e-6 and dh - ih <= 2 * A.reach + 1e-6, name .. ": reach")
						local ow, oh = iw * p.mul + p.pad, ih * p.mul + p.pad -- (the sizes before the limit)
						if ow - iw <= 2 * A.reach and oh - ih <= 2 * A.reach then
							assert_near(dw, ow, 1e-6, name .. ": within the reach, as it was")
							assert_near(dh, oh, 1e-6, name .. ": within the reach, as it was")
						else
							capped = capped + 1
						end
					end
					assert_true(select(1, scene_mod.aura_size(iw, ih, A.halo)) <= 720, name .. ": the halo is not wider than the room")
					items = items + 1
				end
			end
			assert_true(items >= 90, "the whole town: " .. items .. " items")
			assert_true(capped >= 2 and capped <= 6, "only the wide ones feel the limit: " .. capped)
		end)
	end)

	it("draws the glow of the square's garlands, the widest item of the town, inside the width of the room", function()
		G.with_town({ setup = function(app)
			G.build_tasks(app, "cafe")
			G.build_tasks(app, "jazz")
			G.build_tasks(app, "square", 1) -- the fountain
			G.give_stars(app, 3)
		end }, function(c)
			local A = require("screens.town.scene").AURA
			assert_eq(c.app.ui.district, "square")
			assert_eq(c.app.meta:next_task().id, "garlands")
			assert_eq(c.app.ui.glow, "garlands")
			local halo = auras(c)[1]
			local e = item_of(c, "garlands")
			assert_true(e.w > 400, "the widest item of the town: " .. e.w)
			assert_true(halo.size.x <= 720, "the glow is not a band wider than the room: " .. halo.size.x)
			assert_near(halo.size.x, e.w + 2 * A.reach, 0.01)
			assert_near(halo.size.y, e.h * A.halo.mul + A.halo.pad, 0.01, "the height is as it was")
			local light = halo.children[1]
			assert_true(light.size.x < halo.size.x and light.size.y < halo.size.y, "the light is inside the halo")
		end)
		-- the first silhouette of the game keeps the size it was shown with
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local A = require("screens.town.scene").AURA
			local e, halo = item_of(c, "turntable"), auras(c)[1]
			assert_near(halo.size.x, e.w * A.halo.mul + A.halo.pad, 0.01)
			assert_near(halo.size.y, e.h * A.halo.mul + A.halo.pad, 0.01)
		end)
	end)

	it("keeps the same glow through a change of language and counts no extra nodes", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local halo = auras(c)[1]
			local base = c.town:stats().nodes
			c.app.set_setting("language", "ru")
			c.step(10)
			assert_true(c.town:has_text("Проигрыватель", true), G.dump(c.town))
			assert_eq(#auras(c), 1)
			assert_eq(auras(c)[1], halo, "the room is not drawn again for a change of words")
			assert_eq(c.app.ui.glow, "turntable")
			c.app.set_setting("language", "ko")
			c.step(10)
			assert_eq(#auras(c), 1)
			assert_eq(auras(c)[1], halo)
			c.app.set_setting("language", "en")
			c.step(10)
			assert_eq(auras(c)[1], halo)
			assert_true(c.town:stats().nodes <= base + 4, "nodes " .. c.town:stats().nodes .. " vs " .. base)
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("is covered by a window and shines again when it closes", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			assert_eq(#auras(c), 1)
			c.app.open_popup("shop")
			c.step(30)
			assert_eq(c.app.ui.popup, "shop")
			assert_eq(#auras(c), 0, "no glow behind a window")
			assert_eq(c.app.ui.glow, nil)
			c.app.close_popup()
			c.run(0.8)
			assert_eq(c.app.ui.popup, nil)
			assert_eq(#auras(c), 1)
			assert_eq(c.app.ui.glow, "turntable")
			-- and the windows the town opens itself
			c.app.open_popup("settings")
			c.step(30)
			assert_eq(#auras(c), 0)
			c.app.close_popup()
			c.run(0.8)
			assert_eq(#auras(c), 1)
		end)
	end)

	it("is not in the concert look and comes back with the day look", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			assert_eq(#auras(c), 1)
			tap_target(c, "view")
			c.run(1.5)
			assert_eq(c.app.meta:view("cafe"), "concert")
			assert_eq(#auras(c), 0, "the concert has its own light")
			assert_eq(c.app.ui.glow, nil)
			tap_target(c, "view")
			c.run(1.5)
			assert_eq(c.app.meta:view("cafe"), "day")
			assert_eq(#auras(c), 1)
			assert_eq(c.app.ui.glow, "turntable")
			-- and under reduced motion, where the look changes at once
			c.app.set_setting("reduced_motion", true)
			c.run(0.5)
			tap_target(c, "view")
			c.run(0.3)
			assert_eq(#auras(c), 0)
			tap_target(c, "view")
			c.run(0.3)
			assert_eq(#auras(c), 1)
		end)
	end)

	it("has nothing to light in a complete town, whatever the purse holds", function()
		G.with_town({ setup = function(app)
			for _, d in ipairs(app.meta:districts()) do G.build_tasks(app, d.id) end
			G.give_stars(app, 50)
		end }, function(c)
			assert_eq(c.app.ui.card, "done")
			assert_eq(#auras(c), 0)
			assert_eq(c.app.ui.glow, nil)
		end)
	end)

	it("glows only in the district the item stands in: paging away takes it along, paging back brings it", function()
		G.with_town({ setup = function(app) G.build_tasks(app, "cafe"); G.give_stars(app, 1) end }, function(c)
			local t = c.town.self.t
			assert_eq(c.app.ui.district, "jazz")
			assert_eq(c.app.meta:next_task().id, "stage_light")
			assert_eq(c.app.ui.glow, "stage_light")
			assert_eq(#auras(c), 1)
			-- every glow stays on its own item, however the rooms slide
			local function on_their_items()
				for _, halo in ipairs(auras(c)) do
					local sil = silhouette_of(c, halo, "jazz/stage_light")
					assert_true(sil ~= nil, "a glow with no silhouette in its room")
					local ax, ay = c.E.centre(halo)
					local sx, sy = c.E.centre(sil)
					assert_near(ax, sx, 0.5, "the glow follows its item")
					assert_near(ay, sy, 0.5, "the glow follows its item")
				end
			end
			-- to the finished cafe: no item of it is the next one, the jazz room leaves with its own glow
			tap_target(c, "nav_prev")
			local left_with_it = 0
			for _ = 1, 60 * 2 do
				c.step(1)
				on_their_items()
				if #auras(c) > 0 and c.app.ui.sliding then left_with_it = left_with_it + 1 end
				if c.app.ui.district == "cafe" and not c.app.ui.sliding then break end
			end
			assert_eq(c.app.ui.district, "cafe")
			assert_true(left_with_it > 5, "the old room carried its glow out: " .. left_with_it)
			c.run(0.5)
			assert_eq(#auras(c), 0, "the cafe has no item to light")
			assert_eq(c.app.ui.glow, nil)
			assert_eq(c.app.ui.card, "back")
			-- and back to the district being built: the glow is there, on the item, while the room slides in
			tap_target(c, "back")
			local came_with_it = 0
			for _ = 1, 60 * 2 do
				c.step(1)
				on_their_items()
				if #auras(c) > 0 and c.app.ui.sliding then came_with_it = came_with_it + 1 end
				if c.app.ui.district == "jazz" and not c.app.ui.sliding then break end
			end
			assert_eq(c.app.ui.district, "jazz")
			assert_true(came_with_it > 5, "the room slid in with the glow on it: " .. came_with_it)
			c.run(0.5)
			assert_eq(#auras(c), 1)
			assert_eq(c.app.ui.glow, "stage_light")
			assert_eq(auras(c)[1].parent, t.scene.glow_layer)
			assert_eq(t.scene.items_layer.children[1], t.scene.glow_layer)
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("does not glow in the finished district when the next task of another one is affordable", function()
		-- the player is on the finished cafe page while the jazz bar is being built and its first item is in reach
		G.with_town({ setup = function(app) G.build_tasks(app, "cafe"); G.give_stars(app, 3) end }, function(c)
			assert_true(c.app.meta:next_task().affordable)
			tap_target(c, "nav_prev")
			wait_for(c, function() return c.app.ui.district == "cafe" and not c.app.ui.sliding end, 3, "paging back")
			c.run(1)
			assert_eq(c.app.ui.card, "back")
			assert_eq(#auras(c), 0)
			assert_eq(c.app.ui.glow, nil)
			for _, d in ipairs(c.app.meta:district("cafe").tasks) do
				assert_eq(item_of(c, d.id).aura, nil, d.id)
			end
		end)
	end)

	it("waits for the rewards of the win it came back with: lit once, after their show, not before and out again", function()
		-- the real way to the first purchase: the level pushes its reward, the town loads with the star already in the meta,
		-- and the stars fly in 0.45 s later. The glow must not light on the first frame only to go out when the show starts.
		G.with_town({ town = false, setup = function(app)
			app.push_reward(G.win(app, 1))
		end }, function(c)
			local t
			c.town = c.E.script("screens/town/town.gui_script", "/screens/town/town.gui")
			c.town:init()
			c.app.set_screen("town", {})
			t = c.town.self.t
			assert_true(c.app.meta:next_task().affordable, "the star is in the meta from the start")
			local on, was_on, shows, first_glow = 0, false, 0, nil
			for frame = 1, 60 * 9 do
				c.step(1)
				local now = #auras(c) > 0
				if now and not was_on then
					on = on + 1
					first_glow = first_glow or frame
				end
				if was_on and not now then shows = shows + 1 end
				was_on = now
				if now then
					assert_false(c.app.ui.busy, "no glow while the show runs (frame " .. frame .. ")")
					assert_true(t.rewards_started, "no glow before the rewards are queued (frame " .. frame .. ")")
				end
			end
			assert_false(c.app.ui.busy)
			assert_eq(on, 1, "the glow lit up once")
			assert_eq(shows, 0, "and never went out again")
			assert_true(first_glow > 60 * 1, "after the stars have landed: frame " .. tostring(first_glow))
			assert_eq(c.app.ui.glow, "turntable")
			assert_eq(c.app.ui.disp.stars, 1)
		end)
	end)

	it("does not blink for a level chest that is waiting to be opened either", function()
		G.with_town({ town = false, setup = function(app)
			G.win(app, 9)
			assert(require("client.flow").debug_win(3, true)) -- level 10's chest stays in the meta, as after a win on the board
			app.commit("test")
		end }, function(c)
			c.town = c.E.script("screens/town/town.gui_script", "/screens/town/town.gui")
			c.town:init()
			c.app.set_screen("town", {})
			assert_true(#c.app.meta:pending_chests() > 0)
			assert_true(c.app.meta:next_task().affordable)
			for frame = 1, 60 * 0.44 do
				c.step(1)
				assert_eq(#auras(c), 0, "no glow before the chest is offered (frame " .. frame .. ")")
			end
		end)
	end)

	it("is not asked to wait for anything when the town has no rewards to bring: the glow is there from the first frame", function()
		G.with_town({ town = false, setup = function(app) G.win(app, 1) end }, function(c)
			c.town = c.E.script("screens/town/town.gui_script", "/screens/town/town.gui")
			c.town:init()
			c.app.set_screen("town", {})
			c.step(2)
			assert_eq(#auras(c), 1)
			assert_eq(c.app.ui.glow, "turntable")
		end)
	end)

	it("is gone, with its animations, when the screen is left", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			c.run(1)
			assert_eq(#auras(c), 1)
			local halo = auras(c)[1]
			assert_true(anims_of(c, halo) > 0)
			bus.publish("screen_leaving", { from = "town", to = "level" })
			c.step(3)
			assert_eq(#auras(c), 0, "no glow node")
			assert_eq(c.town.self.t.scene:glowing(), nil)
			assert_eq(c.app.ui.glow, nil)
			assert_true(halo.dead == true, "the old halo is deleted, not just hidden")
			for _, a in ipairs(c.E.scene(SCENE).anims) do
				assert_true(a.node.id ~= "aura" and not (a.node.parent and a.node.parent.id == "aura"), "an animation of the glow is still running")
			end
			-- and the screen goes away for good: nothing of the glow is left to run in its own right
			c.town:final()
			for _, a in ipairs(c.E.scene(SCENE).anims) do
				assert_true(a.node.id ~= "aura" and not (a.node.parent and a.node.parent.id == "aura"))
			end
		end)
	end)

	it("is lit again for a new save and put out for a reset", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			assert_eq(#auras(c), 1)
			c.app.reset_save(7, c.E.clock) -- a new save: no star
			c.run(0.5)
			assert_eq(#auras(c), 0)
			assert_eq(c.app.ui.glow, nil)
			G.give_stars(c.app, 1)
			c.step(3)
			assert_eq(#auras(c), 1)
			assert_eq(c.app.ui.glow, "turntable")
		end)
	end)

	it("is not drawn for a silhouette that has no picture yet (the web build downloads the rooms)", function()
		G.with_town({ setup = function(app) G.win(app, 1) end }, function(c)
			local e = item_of(c, "turntable")
			-- an entry without a picture: nothing to glow behind
			set_glow(c, nil)
			assert_eq(#auras(c), 0)
			e.node = nil
			set_glow(c, { district = "cafe", id = "turntable" })
			assert_eq(#auras(c), 0, "no glow without its item")
		end)
	end)
end)
