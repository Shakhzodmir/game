-- The windows of the level screen (pause, out of moves, defeat, the booster purchase, the shop opened from the
-- level) in their worst case: every node stays inside the panel and inside the screen, in both languages and in
-- the window shapes the game meets (the town windows are in meta_windows_test.lua).

local G = require("tests.client.level_gui_helper")
local H = require("tests.client.meta_gui_helper")
local config = require("meta.config")

local SIZES = { { 720, 1280 }, { 1920, 970 }, { 1280, 720 }, { 390, 844 }, { 360, 640 } }

local function open_case(c, name)
	local l = c.hud.self.l
	local meta = c.app.meta
	if name == "pause" then
		return l:open("pause", { level_id = 99, view = { at_stake = true, leave = "loss", lines = {
			{ key = "pause.warn_loss" }, { key = "continue.life_warning" }, { key = "continue.streak_warning", vars = { n = 12 } } } } })
	elseif name == "moves" then
		local boosters = {}
		for i = 1, 3 do boosters[i] = { id = config.boosters[i].id, count = 9 } end
		return l:open("moves", { ctx = l.ctx, view = { stuck = false, run = {}, coins = 0, at_stake = true, ad = true, ad_moves = 5,
			lines = { { key = "continue.life_warning" }, { key = "continue.streak_warning", vars = { n = 12 } } },
			offer = { k = 3, price = 999, moves = 5, riff = true, affordable = false }, boosters = boosters } })
	elseif name == "defeat" then
		local goals, totals = {}, {}
		for i = 1, 3 do goals[i] = l.hud.goal_defs[1]; totals[i] = 30 end
		local lw = require("client.level_windows")
		local view = lw.defeat(meta, { life_lost = true, streak_lost = 7, fails = 3 }, { goals = { 20, 20, 20 } }, goals, totals, c.app.now())
		view.no_lives = true
		return l:open("defeat", { view = view, level_id = 99 })
	elseif name == "booster_buy" then
		return l:open("booster_buy", { id = config.boosters[#config.boosters].id })
	end
	return l:open(name, { tab = "boosters" })
end

describe("level windows: nodes inside the panel and the screen", function()
	it("pause, out of moves, defeat, booster purchase, shop", function()
		local bad = {}
		for _, lang in ipairs({ "en", "ru" }) do
			for _, w in ipairs(SIZES) do
				for _, name in ipairs({ "pause", "moves", "defeat", "booster_buy", "shop" }) do
					G.with_level({ level = 13, language = lang, window = w }, function(c)
						assert_true(c.hud:ctx(open_case, c, name) ~= nil, name)
						c.run(0.6)
						local label = name .. " " .. lang .. " " .. w[1] .. "x" .. w[2]
						for _, m in ipairs((H.overflows(c, 1.5, 110))) do bad[#bad + 1] = label .. ": " .. m end
					end)
				end
			end
		end
		assert_eq(#bad == 0 and "" or ("\n" .. table.concat(bad, "\n")), "", "nodes out of the panel or the screen")
	end)
end)
