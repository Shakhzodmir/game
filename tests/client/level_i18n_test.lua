-- The strings of the level screen (HUD, pause, out of moves, defeat, results, booster purchase, tutorial bubble):
-- every key its code uses exists in both languages, no visible text is typed into the code, every key of
-- its blocks of client/i18n.lua is used by something, and what the screen shows differs between English and
-- Russian.

local G = require("tests.client.level_gui_helper")
local layout = require("client.layout")
local level_hud = require("client.level_hud")
local i18n = require("client.i18n")

local FILES = {
	"gui/pause.lua", "gui/moves.lua", "gui/defeat.lua", "gui/result.lua", "gui/booster_buy.lua", "gui/level_kit.lua",
	"screens/level/hud.lua", "screens/level/tutorial_view.lua", "screens/level/level.gui_script",
	"client/level_windows.lua", "client/level_end.lua", "client/level_hud.lua", "client/level_bit.lua",
	"client/tutorial.lua", "client/level_link.lua",
}

-- namespaces of strings these files may use (they are owned by the level screen or shared and fixed)
local KNOWN = { hud = true, pause = true, continue = true, lose = true, buy = true, win = true, tutorial = true,
	common = true, booster = true, time = true, praise = true, lives = true }

-- namespaces that only the level screen uses: a key here that nothing uses is a dead string
local OWNED = { pause = true, continue = true, lose = true, buy = true, win = true }

local function read(path)
	local f = assert(io.open(path, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

local function list(cmd)
	local out = {}
	local p = io.popen(cmd)
	for line in p:lines() do out[#out + 1] = line end
	p:close()
	return out
end

describe("the level screen strings", function()
	it("has every key the level screen uses, in both languages", function()
		local missing, seen = {}, 0
		for _, f in ipairs(FILES) do
			for key in string.gmatch(read(f), '"([%a_]+%.[%w_%.]+)"') do
				local ns = string.match(key, "^([%a_]+)%.")
				if KNOWN[ns] and string.sub(key, -1) ~= "." then
					seen = seen + 1
					if not i18n.has(key) then missing[#missing + 1] = f .. ": " .. key end
				end
			end
		end
		assert_true(seen > 40, "found the keys: " .. seen)
		assert_same(missing, {})
	end)

	it("has no dead string in the blocks only the level screen uses", function()
		local src = read("client/i18n.lua")
		local owned = {}
		for key in string.gmatch(src, '\n\t%["([^"]+)"%] =') do
			if OWNED[string.match(key, "^([%a_]+)%.")] then owned[#owned + 1] = key end
		end
		assert_true(#owned > 40, "found the strings")
		local code = {}
		for _, f in ipairs(list("find client gui screens main content -type f ! -name i18n.lua")) do code[#code + 1] = read(f) end
		local joined = table.concat(code, "\n")
		local dead = {}
		for _, key in ipairs(owned) do
			if not string.find(joined, key, 1, true) then dead[#dead + 1] = key end
		end
		assert_same(dead, {})
	end)

	it("types no visible text into the code of the level screen: every text literal is a symbol", function()
		local bad = {}
		for _, f in ipairs(FILES) do
			local n = 0
			for line in string.gmatch(read(f), "[^\n]+") do
				n = n + 1
				local code = string.gsub(line, "%-%-.*$", "")
				for _, pat in ipairs({ 'text%s*=%s*"([^"]*)"', ':text%([^,]+,%s*"([^"]*)"', 'toast%("([^"]*)"',
					'badge%([^,]+,[^,]+,[^,]+,[^,]+,%s*"([^"]*)"', 'caption%([^,]+,[^,]+,%s*"([^"]*)"' }) do
					for lit in string.gmatch(code, pat) do
						if string.find(lit, "%a%a") or string.find(lit, "[\208\209][\128-\191]") then
							bad[#bad + 1] = f .. ":" .. n .. ": '" .. lit .. "'"
						end
					end
				end
			end
		end
		assert_same(bad, {})
	end)

	it("has plurals the Russian way for what counts things on the level screen", function()
		i18n.set_language("ru")
		assert_eq(i18n.t("win.moves_left", { n = 1 }), "Остался 1 ход")
		assert_eq(i18n.t("win.moves_left", { n = 4 }), "Осталось 4 хода")
		assert_eq(i18n.t("win.moves_left", { n = 11 }), "Осталось 11 ходов")
		assert_eq(i18n.t("win.chest_in", { n = 2 }), "Сундук через 2 уровня")
		assert_eq(i18n.t("win.chest_in", { n = 21 }), "Сундук через 21 уровень")
		assert_eq(i18n.t("continue.offer", { n = 5 }), "+5 ходов")
		i18n.set_language("en")
		assert_eq(i18n.t("win.moves_left", { n = 1 }), "1 move left")
		assert_eq(i18n.t("continue.offer", { n = 5 }), "+5 moves")
	end)

	it("shows different words in English and Russian on the HUD and on every window", function()
		local PAUSE = { level_hud.layout(layout.fit(720, 1280), nil, nil).pause.cx, level_hud.layout(layout.fit(720, 1280), nil, nil).pause.cy }
		local LOSER = [[{"id": 21, "version": 1, "size": [7, 7], "moves": 7, "difficulty": "easy",
		  "colors": ["red", "yellow", "green", "blue", "purple"],
		  "goals": [{"type": "collect", "color": "red", "count": 60}, {"type": "collect", "color": "blue", "count": 40}],
		  "cells": ["#######", "#######", "#######", "#######", "#######", "#######", "#######"]}]]

		local function run_out(c)
			for _ = 1, 400 do
				local st = c.fb.session.game:status()
				if st.moves_left <= 0 or st.state ~= "playing" then break end
				local cmd = c.fb.session:hint_command()
				if not cmd then break end
				c.fb:send(cmd)
				for _ = 1, 40 * 60 do
					c.step(1)
					if c.fb:stable() then break end
				end
			end
			c.step(60)
		end
		local function win(c)
			c.fb.session:autoplay(nil, { free_moves = true })
			for _ = 1, 60 * 120 do
				c.step(1)
				if c.popup() == "result" then break end
			end
			c.run(3)
		end
		local function hint_step()
			local cmd
			G.with_level({ level = 1 }, function(c) cmd = c.fb.session:hint_command() end)
			return { kind = "swap", from = { cmd.from[1] - 1, cmd.from[2] - 1 }, to = { cmd.to[1] - 1, cmd.to[2] - 1 }, text = "tutorial.swap" }
		end
		local step = hint_step()

		local scenes = {
			{ { level = 24 }, function(c) end },
			{ { level = 60 }, function(c) end },
			{ { level = 9 }, function(c) c.tap(110, 72); c.step(10) end }, -- target mode
			{ { level = 21, hours = 4 }, function(c) c.tap(PAUSE[1], PAUSE[2]); c.run(0.6) end },
			{ { level = 21, hours = 4, level_text = LOSER }, function(c) run_out(c) end },
			{ { level = 21, hours = 4, level_text = LOSER }, function(c)
				run_out(c)
				c.tap_target("give_up")
				c.run(1.5)
			end },
			{ { level = 10 }, win },
			{ { level = 14 }, win },
			{ { level = 26, ready = function(app)
				for _, id in ipairs(level_hud.BOOSTERS) do
					local n = app.meta:booster_count(id)
					if n > 0 then app.meta:_change("test", { { id, -n } }) end
				end
			end }, function(c) c.tap(110, 72); c.run(0.8) end },
			{ { level = 1, tutorials = { ["1"] = { steps = { step } } } }, function(c) c.run(1.5) end },
			{ { level = 1, tutorials = { ["1"] = { steps = { { kind = "tip", text = "tutorial.record_box" } } } } }, function(c) c.run(1.5) end },
		}
		-- words that read the same in both languages
		local SAME = {}
		local function collect(lang, opts, fn)
			local set = {}
			local o = {}
			for k, v in pairs(opts) do o[k] = v end
			o.language = lang
			G.with_level(o, function(c)
				fn(c)
				for _, t in ipairs(c.texts()) do set[t] = true end
				for _, t in ipairs(c.overlay:texts(true)) do set[t] = true end
			end)
			return set
		end
		local same, total = {}, 0
		for i, scene in ipairs(scenes) do
			local en, ru = collect("en", scene[1], scene[2]), collect("ru", scene[1], scene[2])
			for t in pairs(en) do
				if string.find(t, "%a%a") and not SAME[t] then
					total = total + 1
					if ru[t] then same[#same + 1] = "scene " .. i .. ": " .. t end
				end
			end
		end
		table.sort(same)
		assert_true(total > 60, "looked at many texts: " .. total)
		assert_same(same, {})
	end)
end)
