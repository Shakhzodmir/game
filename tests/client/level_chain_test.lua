-- The chain (core-rules 10.6) in the client: its pictures, the overlay in the draw list, its goal in the HUD
-- data, the touch rules, the break effect and sound, the texts. The board script itself plays a chain level in
-- tests/client/level_board_test.lua.

local assets = require("client.assets_index")
local i18n = require("client.i18n")
local levels = require("client.levels")
local level_anim = require("client.level_anim")
local level_audio = require("client.level_audio")
local level_effects = require("client.level_effects")
local level_input = require("client.level_input")
local level_plates = require("client.level_plates")
local level_session = require("client.level_session")
local geom = require("client.level_geom")
local core_helper = require("tests.core.helper")

local function chain_level(count)
	return core_helper.level({
		"######", "######", "######", "######", "######", "######",
	}, { moves = 20, goals = { { type = "chains", count = count or 3 } },
		overlay = { { at = { 1, 1 }, type = "chain", hp = 2 }, { at = { 4, 1 }, type = "chain", hp = 1 },
			{ at = { 2, 4 }, type = "chain", hp = 1 } } })
end

local function board_geom()
	local cells = {}
	for i = 1, 36 do cells[i] = { exists = true } end
	return geom.new(6, 6, cells, { x0 = 0, y0 = 0, x1 = 636, y1 = 624 })
end

describe("the chain in the client", function()
	it("has two pictures in the game atlas, and the first one in the meta atlas (the goal icon of the windows)", function()
		for hp = 1, 2 do
			local img = assets.images["blockers/chain_" .. hp]
			assert_true(img ~= nil, "blockers/chain_" .. hp .. " is in the index")
			assert_same({ img.atlas, img.anim, img.w, img.h }, { "game", "blockers_chain_" .. hp, 160, 160 })
		end
		assert_same(assets.images["blockers/chain_1"].also, { "meta" })
		local found = false
		for _, a in ipairs(assets.atlases.meta.anims) do
			if a == "blockers_chain_1" then found = true end
		end
		assert_true(found, "meta atlas")
	end)

	it("the goal `chains` is drawn like the others: an icon, a counter and a name", function()
		local goals = levels.goals(chain_level())
		assert_same(goals, { { kind = "chains", image = "blockers/chain_1", count = 3, label = { key = "blocker.chain" } } })
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			i18n.set_language(lang)
			for _, key in ipairs({ "blocker.chain", "blocker.chain_desc", "tutorial.chain", "level.fixed_chained" }) do
				local text = i18n.t(key)
				assert_true(type(text) == "string" and text ~= "" and text ~= key, lang .. " " .. key)
			end
		end
		i18n.set_language("ru")
		assert_eq(i18n.t("blocker.chain"), "Цепь")
		assert_eq(i18n.t("blocker.chain_desc"), "Фишка на цепи не двигается сама. Собери с ней ряд — цепь лопнет.")
		assert_eq(i18n.t("tutorial.chain"), "Цепь держит фишку. Собери с ней ряд!")
		i18n.set_language("en")
		assert_eq(i18n.t("blocker.chain"), "Chain")
	end)

	it("the draw list has the chain right after its piece: same place, same squash, a hair above, image by hp", function()
		local A = level_anim.new({ geom = board_geom() })
		local pieces = {
			{ id = 1, x = 2, y = 2, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0, chain = 2 },
			{ id = 2, x = 3, y = 2, kind = "regular", color = "blue", state = "idle", offx = 0, offy = 0 },
			{ id = 3, x = 4, y = 2, kind = "regular", color = "green", state = "fall", offx = 0, offy = 1800, chain = 1 },
		}
		local list = A:frame(pieces, 0, 0)
		assert_eq(#list, 5)
		local p, c = list[1], list[2]
		assert_same({ c.id, c.image }, { level_anim.CHAIN_ID + 1, "blockers_chain_2" })
		assert_same({ c.x, c.y, c.sx, c.sy, c.scale, c.alpha }, { p.x, p.y, p.sx, p.sy, p.scale, p.alpha })
		assert_near(c.z - p.z, level_anim.Z_CHAIN, 1e-9)
		assert_eq(list[3].id, 2)
		local f, fc = list[4], list[5]
		assert_same({ fc.id, fc.image }, { level_anim.CHAIN_ID + 3, "blockers_chain_1" })
		assert_same({ fc.x, fc.y, fc.clip }, { f.x, f.y, f.clip }, "the chain falls with its piece")
		-- a hit makes the chain rattle (the piece does not), then it calms down
		A:event({ type = "hit", layer = "chain", id = 1, x = 2, y = 2, hp = 1, t = 1 }, 1)
		pieces[1].chain = 1
		list = A:frame(pieces, 1, 1.05)
		assert_eq(list[2].image, "blockers_chain_1")
		assert_true(list[2].sx > list[1].sx and list[2].flash > list[1].flash)
		list = A:frame(pieces, 1, 2)
		assert_same({ list[2].sx, list[2].rot, list[2].flash }, { list[1].sx, 0, list[1].flash })
		-- the chain is gone: so is its entry; the piece pops
		A:event({ type = "unchained", id = 1, x = 2, y = 2, t = 2 }, 2)
		pieces[1].chain = nil
		list = A:frame(pieces, 2, 2.1)
		assert_eq(#list, 4)
		assert_true(list[1].sx > 1, "the freed piece pops")
	end)

	it("cannot be picked or swiped; the swipe goes to the core, which refuses it", function()
		local objs = { ["2,2"] = { id = 1, kind = "regular", state = "idle", chained = true },
			["3,2"] = { id = 2, kind = "regular", state = "idle" } }
		local inp = level_input.new({ query = function(x, y) return objs[x .. "," .. y] end })
		inp:press(2, 2)
		assert_same(inp:move(2.45, 2.05), { type = "swap", from = { 2, 2 }, to = { 3, 2 } })
		inp:release(2.45, 2.05)
		inp:press(2, 2)
		inp:release(2, 2)
		assert_eq(inp.selected, nil, "a tap does not select it")
		-- the Crossfader does not take it either
		assert_true(inp:target("swap"))
		local cmd, note = inp:pick_pair(2, 2)
		assert_eq(cmd, nil)
		assert_same({ note.kind, note.why }, { "refuse", "not_movable" })
	end)

	it("is a kind of fixed thing of its own, with its own first-refusal text and no plate", function()
		assert_eq(level_plates.kind({ kind = "regular", chain = 1 }, false), "chained")
		assert_eq(level_plates.kind({ kind = "regular" }, false), nil)
		assert_eq(level_plates.kind({ kind = "regular", chain = 1 }, true), "wired")
		assert_eq(level_plates.TOAST.chained, "level.fixed_chained")
		local P = level_plates.new()
		local list = {}
		local n = P:fill(list, 0, { { id = 1, x = 2, y = 2, kind = "regular", state = "idle", chain = 2 } }, nil, board_geom(), nil, 1, 0, 0)
		assert_eq(n, 0)
	end)

	it("a link taken off sparks, a broken chain flies off its piece, both with the snap of the wires", function()
		local E = level_effects.new({ geom = board_geom() })
		E:event({ type = "hit", t = 3, layer = "chain", id = 1, x = 2, y = 6, hp = 1 })
		local kinds = {}
		for _, c in ipairs(E:drain()) do kinds[c.kind] = (kinds[c.kind] or 0) + 1 end
		assert_true((kinds.burst or 0) >= 1, "sparks")
		assert_eq(kinds.ghost, nil)
		E:event({ type = "unchained", t = 3, id = 1, x = 2, y = 6 })
		local ghost
		for _, c in ipairs(E:drain()) do
			if c.kind == "ghost" then ghost = c end
		end
		assert_true(ghost ~= nil and ghost.image == "blockers_chain_1", "the chain itself flies away")
		local calls = {}
		local a = {}
		function a.sfx(name) calls[#calls + 1] = name end
		function a.play_note() end
		function a.layer() end
		function a.combo() end
		local clock = 0
		local la = level_audio.new({ audio = a, now = function() return clock end })
		la:events({ { type = "hit", layer = "chain", id = 4, x = 2, y = 6, hp = 1 } })
		clock = 1 -- (the same sound is not played twice at once)
		la:events({ { type = "unchained", id = 4, x = 2, y = 6 } })
		assert_same(calls, { "wires_snap", "wires_snap" })
	end)

	it("a session plays a chain level: pieces() carries the chains, the hint moves break them", function()
		local s = assert(level_session.new({ params = { level = 121, level_text = chain_level() } }))
		local game = s.game
		local n = 0
		for _, p in ipairs(game:pieces()) do
			if p.chain then n = n + 1 end
		end
		assert_eq(n, 3)
		local broken = 0
		for _ = 1, 60 do
			game:run_to_rest()
			for _, e in ipairs(game:drain_events()) do
				if e.type == "unchained" then broken = broken + 1 end
			end
			if game:status().state ~= "playing" then break end
			local cmd = s:hint_command()
			if not cmd then break end
			if game:status().moves_left == 0 then break end
			assert_true(game:input(cmd))
		end
		assert_true(broken >= 1, "the hint breaks chains")
	end)
end)

describe("the chains goal in the level HUD", function()
	local G = require("tests.client.level_gui_helper")
	local json = require("tools.lib.json")

	local function showing(c, anim)
		local n = 0
		for _, node in ipairs(c.E.alive_nodes(c.E.scene("/screens/level/level.gui"))) do
			if node.anim == anim then n = n + 1 end
		end
		return n
	end

	it("shows the chain icon with its counter and counts a broken chain down", function()
		local level = core_helper.level({
			"yrgbpyrgb", "rgbpyrgby", "gbpyrgbpy", "bpyrgbpyr", "pyrgbypyr", "yrgbpyrgb", "rgbpyrgby", "gbpyrgbpy", "bpyggbpyr",
		}, { moves = 10, goals = { { type = "chains", count = 7 } },
			overlay = { { at = { 3, 8 }, type = "chain", hp = 1 }, { at = { 0, 0 }, type = "chain", hp = 2 },
				{ at = { 2, 0 }, type = "chain", hp = 2 }, { at = { 4, 0 }, type = "chain", hp = 2 },
				{ at = { 6, 0 }, type = "chain", hp = 2 }, { at = { 8, 0 }, type = "chain", hp = 2 },
				{ at = { 0, 2 }, type = "chain", hp = 2 } } })
		G.with_level({ level = 1, level_text = json.encode(level) }, function(c)
			assert_eq(showing(c, "blockers_chain_1"), 1, "the goal icon")
			assert_true(c.has("7"), "the goal counter")
			local ok = c.fb:swipe({ 6, 8 }, { 6, 9 })
			assert_true(ok)
			c.fb:settle()
			c.run(2)
			local left = c.fb.session.game:status().goals[1]
			assert_true(left <= 6, "the chain of the swipe is broken")
			assert_true(c.has(tostring(left)), "the counter follows")
			assert_false(c.has("7"))
		end)
	end)
end)
