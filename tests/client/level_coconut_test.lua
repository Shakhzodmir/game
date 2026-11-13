-- The coconut (core-rules 10.5) in the client: its picture, its goal in the HUD data, the touch rules,
-- the collect effect and sound, the texts. The board script itself plays a coconut level in
-- tests/client/level_board_test.lua.

local assets = require("client.assets_index")
local i18n = require("client.i18n")
local levels = require("client.levels")
local level_anim = require("client.level_anim")
local level_audio = require("client.level_audio")
local level_effects = require("client.level_effects")
local level_input = require("client.level_input")
local level_session = require("client.level_session")
local geom = require("client.level_geom")
local core_helper = require("tests.core.helper")

local function coconut_level()
	return core_helper.level({
		"######", "##C###", "######", "######", "######", "######",
	}, { moves = 20, goals = { { type = "drop", count = 2 } }, coconut = { total = 2, on_board_max = 2, gap_moves = 1 } })
end

describe("the coconut in the client", function()
	it("has a picture in the game atlas (the board) and in the meta atlas (the windows before a level)", function()
		assert_eq(level_anim.image({ kind = "coconut" }), "blockers_coconut")
		local img = assets.images["blockers/coconut"]
		assert_true(img ~= nil, "blockers/coconut is in the index")
		assert_same({ img.atlas, img.anim, img.w, img.h }, { "game", "blockers_coconut", 160, 160 })
		assert_same(img.also, { "meta" })
		for _, name in ipairs({ "game", "meta" }) do
			local found = false
			for _, a in ipairs(assets.atlases[name].anims) do
				if a == "blockers_coconut" then found = true end
			end
			assert_true(found, name .. " atlas")
		end
	end)

	it("the goal `drop` is drawn like the others: an icon, a counter and a name", function()
		local goals = levels.goals(coconut_level())
		assert_same(goals, { { kind = "drop", image = "blockers/coconut", count = 2, label = { key = "blocker.coconut" } } })
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			i18n.set_language(lang)
			local name = i18n.tr(goals[1].label)
			assert_true(type(name) == "string" and name ~= "" and name ~= "blocker.coconut", lang)
		end
		i18n.set_language("en")
		assert_eq(i18n.t("blocker.coconut"), "Coconut")
	end)

	it("can be picked and swiped like a piece", function()
		local objs = { ["2,2"] = { id = 1, kind = "coconut", state = "idle" }, ["3,2"] = { id = 2, kind = "regular", state = "idle" } }
		local inp = level_input.new({ query = function(x, y) return objs[x .. "," .. y] end })
		inp:press(2, 2)
		assert_same(inp:move(2.45, 2.05), { type = "swap", from = { 2, 2 }, to = { 3, 2 } })
		inp:release(2.45, 2.05)
		inp:press(2, 2)
		assert_eq(inp:release(2, 2), nil)
		assert_same(inp.selected, { id = 1, x = 2, y = 2 }, "a tap selects it")
	end)

	it("a collected coconut flashes and sparkles where it left, with the collect sound", function()
		local cells = {}
		for i = 1, 36 do cells[i] = { exists = true } end
		local E = level_effects.new({ geom = geom.new(6, 6, cells, { x0 = 0, y0 = 0, x1 = 636, y1 = 624 }) })
		E:event({ type = "coconut_collected", t = 3, id = 1, x = 2, y = 6 })
		local kinds = {}
		for _, c in ipairs(E:drain()) do kinds[c.kind] = (kinds[c.kind] or 0) + 1 end
		assert_true((kinds.burst or 0) >= 1, "a burst")
		assert_eq(kinds.stinger, nil, "the note stinger is the microphone's")
		local calls = {}
		local a = {}
		function a.sfx(name) calls[#calls + 1] = name end
		function a.play_note() end
		function a.layer() end
		function a.combo() end
		local la = level_audio.new({ audio = a, now = function() return 0 end })
		la:events({ { type = "coconut_collected", id = 4, x = 2, y = 6 } })
		assert_same(calls, { "mic_collect" })
	end)

	it("a session plays a coconut level: the picture names it, the hint moves win it", function()
		local s = assert(level_session.new({ params = { level = 101, level_text = coconut_level() } }))
		assert_eq(string.sub(s:picture()[2], 3, 3), "C")
		local game = s.game
		local collected = 0
		for _ = 1, 60 do
			game:run_to_rest()
			for _, e in ipairs(game:drain_events()) do
				if e.type == "coconut_collected" then collected = collected + 1 end
			end
			if game:status().state ~= "playing" then break end
			local cmd = s:hint_command()
			if not cmd then break end
			if game:status().moves_left == 0 then break end
			assert_true(game:input(cmd))
		end
		assert_true(collected >= 1, "the hint brings coconuts down")
	end)
end)

describe("the coconut goal in the level HUD", function()
	local G = require("tests.client.level_gui_helper")
	local json = require("tools.lib.json")

	local function showing(c, anim)
		local n = 0
		for _, node in ipairs(c.E.alive_nodes(c.E.scene("/screens/level/level.gui"))) do
			if node.anim == anim then n = n + 1 end
		end
		return n
	end

	it("shows the coconut icon with its counter and counts a collected coconut down", function()
		local level = core_helper.level({
			"yrgbpyrgb", "rgbpyrgby", "gbpyrgbpy", "bpyrgbpyr", "pyrgbypyr", "yrgbpyrgb", "rgbpyrgby", "gbpyCgbpy", "bpyggbpyr",
		}, { moves = 10, goals = { { type = "drop", count = 7 } }, coconut = { total = 7, on_board_max = 1, gap_moves = 5 } })
		G.with_level({ level = 1, level_text = json.encode(level) }, function(c)
			assert_eq(showing(c, "blockers_coconut"), 1, "the goal icon")
			assert_true(c.has("7"), "the goal counter")
			local ok = c.fb:swipe({ 6, 8 }, { 6, 9 })
			assert_true(ok)
			c.fb:settle()
			c.run(2)
			assert_same(c.fb.session.game:status().goals, { 6 })
			assert_true(c.has("6"), "one coconut down")
			assert_false(c.has("7"))
		end)
	end)
end)
