-- A monkey on the town: random taps, windows, languages, settings, rewards, level results, paging, resets,
-- resizes and time, on the strict Defold GUI stub. Nothing may raise, glyphs may not go missing, and the
-- scene must come to rest: no window, no running show, a bounded number of nodes and animations.

local G = require("tests.client.meta_gui_helper")
local flow = require("client.flow")
local bus = require("client.bus")

-- MINSTD: exact in doubles, the same on Lua 5.1 and LuaJIT
local function rng(seed)
	local s = seed
	return function(n)
		s = (s * 48271) % 2147483647
		return s % n + 1
	end
end

local POPUPS = { "start", "lives", "shop", "settings", "jukebox", "chest", "gift", "confirm", "concert" }
local WINDOWS = { { 720, 1280 }, { 1280, 720 }, { 390, 844 }, { 768, 1024 } }

local function run_monkey(seed, actions)
	local r = rng(seed)
	local log = {}
	local language = (r(2) == 1) and "en" or "ru"
	-- half of the seeds play a debug build: test purchases and the video gift answer in the shop
	G.with_town({ language = language, stores = r(2) == 1 }, function(c)
		local app = c.app
		local function target_points()
			local pts = {}
			for _, group in ipairs({ app.ui.targets or {}, app.ui.popup_targets or {} }) do
				for _, p in pairs(group) do pts[#pts + 1] = p end
			end
			return pts
		end
		local ACTIONS = {
			function() -- a tap anywhere
				c.tap(r(720), r(1280))
				return "tap"
			end,
			function() -- a tap on something that can be tapped
				local pts = target_points()
				if #pts == 0 then return "no targets" end
				local p = pts[r(#pts)]
				c.tap(p.x, p.y)
				return "tap target"
			end,
			function()
				local name = POPUPS[r(#POPUPS)]
				local params
				if name == "chest" then params = { kind = "level", level_id = 10, chest = { coins = 60, boosters = { "stick" }, infinite_minutes = 15 } } end
				if name == "gift" then params = { id = "riff" } end
				if name == "shop" then params = { tab = r(2) == 1 and "boosters" or "coins" } end
				if name == "confirm" then params = { title = { key = "settings.reset_title" }, text = { key = "settings.reset_text" } } end
				app.open_popup(name, params)
				return "open " .. name
			end,
			function() app.close_popup() return "close" end,
			function() app.set_setting("language", ({ "en", "ru", "auto" })[r(3)]) return "language" end,
			function()
				local key = ({ "haptics", "reduced_motion" })[r(2)]
				app.set_setting(key, r(2) == 1)
				return "setting " .. key
			end,
			function() app.set_setting("music", r(11) / 10) return "volume" end,
			function() -- a level result from the board
				local res = flow.debug_win(r(6))
				if res then app.push_reward(res) end
				return "win"
			end,
			function()
				app.push_reward({ won = false, life_lost = r(2) == 1, streak_lost = r(3) - 1, level_id = 22 })
				return "loss reward"
			end,
			function()
				app.push_reward({ won = true, stars = r(3), coins = r(80), chest = { coins = r(100), boosters = { "stick", "riff" }, infinite_minutes = r(2) * 15 },
					unlocked = { "stick" }, streak = r(4) - 1, level_id = 10 })
				return "big reward"
			end,
			function()
				bus.publish("meta_qa", { action = ({ "task", "skip", "browse", "view" })[r(4)], dir = r(2) == 1 and 1 or -1, view = r(2) == 1 and "day" or "concert" })
				return "qa action"
			end,
			function() -- a swipe on the scene
				local y = r(500) + 400
				local x0 = r(300) + 200
				local dx = (r(2) == 1 and 1 or -1) * (r(200) + 40)
				c.E.input(hash("touch"), c.E.touch_action(x0, y, true, false))
				c.step(2)
				c.E.input(hash("touch"), c.E.touch_action(x0 + dx, y, false, true))
				return "swipe"
			end,
			function() -- time passes: lives regenerate
				c.E.clock = c.E.clock + r(900)
				app.tick(c.E.clock)
				return "time"
			end,
			function()
				local w = WINDOWS[r(#WINDOWS)]
				c.E.set_window(w[1], w[2])
				return "resize"
			end,
			function() -- the player gets stars to spend
				G.give_stars(app, r(3))
				return "stars"
			end,
			function()
				if r(12) == 1 then
					app.reset_save(r(1000), c.E.clock)
					return "reset"
				end
				return "no reset"
			end,
			function()
				bus.publish("save_failed", { error = "disk", streak = r(3) })
				bus.publish("save_recovered", { after = 2 })
				return "save notices"
			end,
		}
		for i = 1, actions do
			local pick = r(#ACTIONS)
			local ok, what = pcall(ACTIONS[pick])
			if not ok then error("seed " .. seed .. " action " .. i .. " (#" .. pick .. "): " .. tostring(what) .. "\nlast: " .. table.concat(log, ", "), 0) end
			log[#log + 1] = what
			if #log > 12 then table.remove(log, 1) end
			local ok2, err = pcall(c.step, r(40))
			if not ok2 then error("seed " .. seed .. " frames after action " .. i .. " (" .. tostring(what) .. "): " .. tostring(err) .. "\nlast: " .. table.concat(log, ", "), 0) end
			if i % 25 == 0 then
				local problems = c.E.audit()
				assert_same(problems, {}, "seed " .. seed .. " after action " .. i)
			end
		end
		-- the scene comes to rest: close everything, let the show end
		app.close_popup()
		for _ = 1, 6 do
			app.close_popup()
			c.run(1)
		end
		c.E.set_window(720, 1280)
		for _ = 1, 400 do -- a long queue of rewards: every chest and gift needs closing
			if not app.ui.busy and not app.ui.popup then break end
			app.close_popup()
			c.tap(360, 640) -- a tap skips a skippable step, taps through a concert
			c.run(1.5)
		end
		c.run(6)
		if app.ui.popup or app.ui.busy then
			local t = c.town.self.t
			io.write("DEBUG seed ", seed, " popup=", tostring(app.ui.popup), " step=", tostring(app.ui.step), " queue=", tostring(#t.show.queue),
				" cur=", tostring(t.show.cur and t.show.cur.name), " rewards=", tostring(require("client.rewards").count()), " popups=", tostring(t.popups:count()), "\n")
		end
		assert_eq(app.ui.popup, nil, "seed " .. seed .. " window left open")
		assert_false(app.ui.busy, "seed " .. seed .. " the show never ended")
		local stats = c.town:stats()
		assert_true(stats.nodes < 800, "seed " .. seed .. " nodes " .. stats.nodes)
		assert_true(stats.anims < 400, "seed " .. seed .. " animations " .. stats.anims)
		assert_same(c.E.audit(), {}, "seed " .. seed .. " at rest")
		assert_eq(app.ui.disp.coins, app.meta:coins(), "seed " .. seed .. " the coin counter matches the purse")
		assert_eq(app.ui.disp.stars, app.meta:stars(), "seed " .. seed .. " the star counter matches the purse")
	end)
end

describe("the town under a monkey", function()
	it("survives random play: seed 1", function() run_monkey(1, 260) end)
	it("survives random play: seed 7", function() run_monkey(7, 260) end)
	it("survives random play: seed 42", function() run_monkey(42, 260) end)
	it("survives random play: seed 2026", function() run_monkey(2026, 260) end)
end)
