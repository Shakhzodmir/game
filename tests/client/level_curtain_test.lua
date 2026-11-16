-- The timed curtain (core-rules 10.7) in the client: its pictures, the marks over the cells and the counter
-- (client/level_curtain.lua), the touch rules, the sounds, the texts. The board script itself plays a curtain
-- level in tests/client/level_board_test.lua.

local assets = require("client.assets_index")
local i18n = require("client.i18n")
local levels = require("client.levels")
local level_audio = require("client.level_audio")
local level_curtain = require("client.level_curtain")
local level_input = require("client.level_input")
local level_plates = require("client.level_plates")
local level_session = require("client.level_session")
local geom = require("client.level_geom")
local core_helper = require("tests.core.helper")

-- a drape of three cells, (3,3) (4,3) (3,4), and a lone curtain at (6,5): 1-based core cells
local function curtain_level(start, closed, open)
	return core_helper.level({
		"######", "######", "######", "######", "######", "######",
	}, { moves = 30, goals = { { type = "collect", color = "red", count = 200 } },
		curtain = { covers = { { 2, 2 }, { 3, 2 }, { 2, 3 }, { 5, 4 } }, closed_moves = closed or 3, open_moves = open or 2,
			start = start or "closed" } })
end

local function board_geom()
	local cells = {}
	for i = 1, 36 do cells[i] = { exists = true } end
	return geom.new(6, 6, cells, { x0 = 0, y0 = 0, x1 = 636, y1 = 624 })
end

local function board_cells()
	local cells = {}
	for i = 1, 36 do cells[i] = { exists = true } end
	for _, i in ipairs({ 15, 16, 21, 30 }) do cells[i].curtain = true end
	return cells
end

local function new(status, reduced)
	return level_curtain.new({ cells = board_cells(), W = 6, status = status or { phase = "closed", left = 3 }, reduced = reduced })
end

-- the marks of a frame, counted by image
local function frame(C, t, g)
	local list = {}
	local n = C:fill(list, 0, g or board_geom(), t, 0, 0)
	local by = {}
	for k = 1, n do by[list[k].image] = (by[list[k].image] or 0) + 1 end
	return list, n, by
end

describe("the curtain in the client", function()
	it("has two pictures in the game atlas", function()
		for _, name in ipairs({ "closed", "open" }) do
			local img = assets.images["blockers/curtain_" .. name]
			assert_true(img ~= nil, "blockers/curtain_" .. name .. " is in the index")
			assert_same({ img.atlas, img.anim, img.w, img.h }, { "game", "blockers_curtain_" .. name, 160, 160 })
		end
		assert_same({ level_curtain.CLOSED, level_curtain.OPEN }, { "blockers_curtain_closed", "blockers_curtain_open" })
	end)

	it("has its name, its description, its lesson line and its refusal in three languages", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			i18n.set_language(lang)
			for _, key in ipairs({ "blocker.curtain", "blocker.curtain_desc", "tutorial.curtain", "level.fixed_veiled" }) do
				local text = i18n.t(key)
				assert_true(type(text) == "string" and text ~= "" and text ~= key, lang .. " " .. key)
			end
		end
		i18n.set_language("ru")
		assert_eq(i18n.t("blocker.curtain"), "Занавес")
		assert_eq(i18n.t("blocker.curtain_desc"), "Пока занавес закрыт, фишки под ним не трогаются. Дождись, когда он откроется.")
		assert_eq(i18n.t("tutorial.curtain"), "Занавес закрыт: подожди. Открылся: действуй!")
		i18n.set_language("en")
		assert_eq(i18n.t("blocker.curtain"), "Curtain")
	end)

	it("is no goal: a curtain level shows the goals it has", function()
		local goals = levels.goals(curtain_level())
		assert_eq(#goals, 1)
		assert_eq(goals[1].kind, "collect")
	end)

	it("closed: one closed curtain over every cell, above the pieces, and the count as pips on each drape", function()
		local C = new()
		assert_true(C:active())
		local list, n, by = frame(C, 0)
		assert_eq(by.blockers_curtain_closed, 4)
		assert_eq(by.blockers_curtain_open, nil)
		assert_eq(by.fx_glow_dot, 6, "two drapes, three moves left on each")
		assert_eq(C:count(), n)
		local g = board_geom()
		local lx, ly = g:center(3, 3)
		local m = list[1]
		assert_same({ m.x, m.y, m.w, m.h, m.alpha, m.glow }, { lx, ly, g.cell, g.cell, 1, false })
		assert_same({ m.iw, m.ih }, { 160, 160 })
		assert_true(m.z > 0.2, "over the pieces and the wires")
		-- the pips sit on the rail of the top-left cell of the drape, side by side, gold while it waits to open
		local pips = {}
		for k = 1, n do
			if list[k].image == "fx_glow_dot" then pips[#pips + 1] = list[k] end
		end
		assert_true(pips[1].y > ly and pips[1].y < ly + g.cell / 2)
		assert_near((pips[1].x + pips[3].x) / 2, lx, 1e-6)
		assert_true(pips[2].x > pips[1].x and pips[1].z > m.z and pips[1].glow == true)
		assert_eq(pips[1].color, level_curtain.PIP_COLOR.closed)
		local hx = g:center(6, 5)
		assert_near(pips[5].x, hx, 1e-6, "the lone curtain has its own counter")
		-- where a finger meets a closed curtain
		assert_true(C:closed_at(3, 3) and C:closed_at(6, 5))
		assert_false(C:closed_at(2, 3))
	end)

	it("a move takes a pip off; the change crosses the two pictures over and ends on the open frame", function()
		local C = new()
		C:event({ type = "curtain_left", phase = "closed", left = 2 }, 1)
		local _, _, by = frame(C, 1)
		assert_eq(by.fx_glow_dot, 4)
		C:event({ type = "curtain", phase = "open", left = 2, reason = "move", cells = {} }, 2)
		assert_false(C:closed_at(3, 3))
		local list, n
		list, n, by = frame(C, 2 + level_curtain.MOVE_TIME / 2)
		assert_same({ by.blockers_curtain_closed, by.blockers_curtain_open }, { 4, 4 }, "both while it moves")
		for k = 1, n do
			if list[k].image == "blockers_curtain_closed" then
				assert_true(list[k].alpha > 0 and list[k].alpha < 1)
				assert_true(list[k].w > board_geom().cell, "it sways")
			end
		end
		list, n, by = frame(C, 2 + level_curtain.MOVE_TIME + 0.01)
		assert_same({ by.blockers_curtain_closed, by.blockers_curtain_open, by.fx_glow_dot }, { nil, 4, 4 })
		for k = 1, n do
			if list[k].image == "fx_glow_dot" then assert_eq(list[k].color, level_curtain.PIP_COLOR.open) end
		end
		-- a frame at rest hands out the same tables with the same numbers: nothing is sent to the engine twice
		local again = frame(C, 9)
		for k = 1, n do
			assert_true(again[k] == list[k])
		end
		-- and it closes again
		C:event({ type = "curtain", phase = "closed", left = 3, reason = "move", cells = {} }, 10)
		list, n, by = frame(C, 10.6)
		assert_same({ by.blockers_curtain_closed, by.blockers_curtain_open, by.fx_glow_dot }, { 4, nil, 6 })
	end)

	it("with reduced motion the pictures just change places", function()
		local C = new(nil, true)
		C:event({ type = "curtain", phase = "open", left = 2, reason = "deadlock", cells = {} }, 2)
		local _, _, by = frame(C, 2.01)
		assert_same({ by.blockers_curtain_closed, by.blockers_curtain_open }, { nil, 4 })
		assert_true(C:nope(3, 3, 3))
		local list = frame(C, 3.05)
		local lx = board_geom():center(3, 3)
		assert_eq(list[1].x, lx, "no shake either")
	end)

	it("a refused touch shakes the closed curtain of that cell, and only that one, for a moment", function()
		local C = new()
		local g = board_geom()
		assert_false(C:nope(1, 1, 1), "no curtain there")
		assert_true(C:nope(4, 3, 1))
		local list = frame(C, 1.04)
		local x3, x4 = g:center(3, 3), g:center(4, 3)
		assert_eq(list[1].x, x3)
		assert_true(list[2].x ~= x4 and math.abs(list[2].x - x4) < g.cell * 0.1)
		list = frame(C, 1 + level_curtain.NOPE_TIME + 0.01)
		assert_eq(list[2].x, x4)
	end)

	it("follows the core when it is asked to: the janitor's look", function()
		local C = new()
		assert_eq(C:sync({ phase = "closed", left = 3 }), 0)
		assert_eq(C:sync({ phase = "open", left = 1 }), 1)
		local _, _, by = frame(C, 5)
		assert_same({ by.blockers_curtain_open, by.fx_glow_dot }, { 4, 2 })
		assert_eq(C:sync(nil), 0)
	end)

	it("a level without curtains draws nothing and costs nothing", function()
		local cells = {}
		for i = 1, 36 do cells[i] = { exists = true } end
		local C = level_curtain.new({ cells = cells, W = 6, status = nil })
		assert_false(C:active())
		local list = {}
		assert_eq(C:fill(list, 3, board_geom(), 1, 0, 0), 3)
		C:event({ type = "match" }, 1)
		assert_false(C:closed_at(3, 3))
		assert_false(C:nope(3, 3, 1))
		assert_eq(C:sync(nil), 0)
	end)

	it("what is under a closed curtain cannot be picked, swiped or launched; the swipe goes to the core", function()
		local objs = { ["2,2"] = { id = 1, kind = "regular", state = "idle", veiled = true },
			["3,2"] = { id = 2, kind = "regular", state = "idle" },
			["2,3"] = { id = 3, kind = "special", state = "idle", veiled = true } }
		local inp = level_input.new({ query = function(x, y) return objs[x .. "," .. y] end })
		inp:press(2, 2)
		assert_same(inp:move(2.45, 2.05), { type = "swap", from = { 2, 2 }, to = { 3, 2 } })
		inp:release(2.45, 2.05)
		inp:press(2, 2)
		inp:release(2, 2)
		assert_eq(inp.selected, nil, "a tap does not select it")
		inp:press(2, 3)
		-- a tap on it goes to the core like a tap on any fixed thing: the core says not_movable (a special
		-- under the curtain is not launched) and the board answers with the shake of the curtain
		assert_same(inp:release(2, 3), { type = "tap", at = { 2, 3 } })
		assert_true(inp:target("swap"))
		local cmd, note = inp:pick_pair(2, 2)
		assert_eq(cmd, nil)
		assert_same({ note.kind, note.why }, { "refuse", "not_movable" })
	end)

	it("is a kind of fixed thing of its own, before the others, with its own first-refusal text and no plate", function()
		assert_eq(level_plates.kind({ kind = "regular", veiled = true }, false), "veiled")
		assert_eq(level_plates.kind({ kind = "blocker", veiled = true }, false), "veiled")
		assert_eq(level_plates.kind({ kind = "regular" }, false), nil)
		assert_eq(level_plates.TOAST.veiled, "level.fixed_veiled")
		local P = level_plates.new()
		local list = {}
		local n = P:fill(list, 0, { { id = 1, x = 2, y = 2, kind = "blocker", item = "noise", state = "idle", veiled = true } },
			nil, board_geom(), nil, 1, 0, 0)
		assert_eq(n, 0)
	end)

	it("closes and opens with a soft whoosh (lower when it closes); a swipe into it sounds like a failed swap", function()
		local calls = {}
		local a = {}
		function a.sfx(name, opts) calls[#calls + 1] = { name, opts and opts.gain, opts and opts.speed } end
		function a.play_note() end
		function a.layer() end
		function a.combo() end
		local clock = 0
		local la = level_audio.new({ audio = a, now = function() return clock end })
		la:events({ { type = "curtain", phase = "closed", left = 3 } })
		clock = 1
		la:events({ { type = "curtain", phase = "open", left = 2 }, { type = "curtain_left", phase = "open", left = 1 } })
		clock = 2
		la:blocked()
		assert_same(calls, {
			{ "swap", level_audio.CURTAIN_GAIN, level_audio.CURTAIN_CLOSE },
			{ "swap", level_audio.CURTAIN_GAIN, level_audio.CURTAIN_OPEN },
			{ "swap_fail" },
		})
		assert_true(level_audio.CURTAIN_CLOSE < level_audio.CURTAIN_OPEN and level_audio.CURTAIN_GAIN < 0.8)
	end)

	it("a session plays a curtain level: status, cells and pieces carry it, the hint never points into a closed cell", function()
		local s = assert(level_session.new({ params = { level = 141, level_text = curtain_level("closed", 2, 2) } }))
		local game = s.game
		local C = level_curtain.new({ cells = game:cells(), W = s.W, status = game:status().curtain })
		assert_true(C:active())
		assert_same(game:status().curtain, { phase = "closed", left = 2 })
		local phases, t = {}, 0
		for _ = 1, 12 do
			game:run_to_rest()
			for _, e in ipairs(game:drain_events()) do
				t = t + 1
				C:event(e, t)
				if e.type == "curtain" then phases[#phases + 1] = e.phase end
			end
			local st = game:status()
			if st.state ~= "playing" or st.moves_left == 0 then break end
			assert_eq(C.phase, st.curtain.phase)
			assert_eq(C.left, st.curtain.left)
			local veiled = 0
			for _, p in ipairs(game:pieces()) do
				if p.veiled then
					veiled = veiled + 1
					assert_true(C:closed_at(p.x, p.y))
				end
			end
			assert_eq(veiled, st.curtain.phase == "closed" and 4 or 0)
			local cmd = s:hint_command()
			if not cmd then break end
			for _, c in ipairs({ cmd.from, cmd.to, cmd.at }) do
				assert_false(C:closed_at(c[1], c[2]), "the hint points into a closed cell")
			end
			assert_true(game:input(cmd))
		end
		assert_true(#phases >= 4, "it opened and closed a few times")
		assert_eq(phases[1], "open")
	end)
end)
