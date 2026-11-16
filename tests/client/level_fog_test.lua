-- The stage fog (core-rules 10.13) in the client: the cloud over a fogged cell, the pieces under it that are
-- not drawn at all (at rest, falling in, swapped in or out), the puff when the fog blows off, the goal icon and
-- the texts, what the input is told about a fogged cell, and the board script (screens/level/board.script) on
-- the strict Defold stub.

local stub = require("tests.client.level_defold_stub")
local app = require("client.app")
local assets = require("client.assets_index")
local bus = require("client.bus")
local i18n = require("client.i18n")
local layout = require("client.layout")
local levels = require("client.levels")
local level_anim = require("client.level_anim")
local level_audio = require("client.level_audio")
local level_effects = require("client.level_effects")
local level_fog = require("client.level_fog")
local level_input = require("client.level_input")
local level_session = require("client.level_session")
local geom = require("client.level_geom")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local core_helper = require("tests.core.helper")
local H = require("tests.meta.helper")

local DT = 1 / 60
local FULL = { "######", "######", "######", "######", "######", "######" }

-- the fogged cells of the test level, 1-based: a bank of 3 x 3 in the middle and one cell apart
local FOG = { { 2, 3 }, { 3, 3 }, { 4, 3 }, { 2, 4 }, { 3, 4 }, { 4, 4 }, { 2, 5 }, { 3, 5 }, { 4, 5 }, { 6, 6 } }

local function fog_level(goals, extra)
	local fog = {}
	for k, c in ipairs(FOG) do fog[k] = { c[1] - 1, c[2] - 1 } end
	local t = { moves = 30, colors = { "red", "yellow", "blue", "purple" },
		goals = goals or { { type = "fog" }, { type = "collect", color = "red", count = 200 } }, fog = fog }
	for k, v in pairs(extra or {}) do t[k] = v end
	return core_helper.level(FULL, t)
end

local function board_geom()
	local cells = {}
	for i = 1, 36 do cells[i] = { exists = true } end
	return geom.new(6, 6, cells, { x0 = 0, y0 = 0, x1 = 636, y1 = 624 })
end

-- game:cells() of a 6x6 board with the fog over `list` (1-based {x, y})
local function cells_with(list)
	local cells = {}
	for i = 1, 36 do cells[i] = { exists = true } end
	for _, c in ipairs(list) do cells[(c[2] - 1) * 6 + c[1]].fog = true end
	return cells
end

local function boot_app()
	analytics.init({ strict = true })
	app.init({
		districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
		now = H.T0, clock = function() return H.T0 end, sys_language = "en",
	})
	i18n.set_language("en")
end

-- the two-line bubble of a lesson (the model of tests/client/tutorial_content_test.lua)
local function bubble_lines(text, lang)
	local font = require("tests.client.font_advances")[lang == "ko" and "body_ko" or "body"]
	local codepoints = require("tests.client.town_defold_stub").utf8_codepoints
	local function width(s)
		local w = 0
		for _, cp in ipairs(codepoints(s)) do
			local advance = font.advances[cp]
			assert_true(advance ~= nil, string.format("the body font has no glyph U+%04X (%s)", cp, text))
			w = w + advance * 30 / font.size
		end
		return w
	end
	local lines, line = 1, nil
	for word in string.gmatch(text, "%S+") do
		local try = line and (line .. " " .. word) or word
		if line and width(try) > 620 - 230 - 6 then
			lines, line = lines + 1, word
		else
			line = try
		end
	end
	return lines
end

local function fake_audio()
	local calls = {}
	local a = {}
	function a.sfx(name, opts) calls[#calls + 1] = { name, opts } end
	function a.play_note() end
	function a.layer() end
	function a.combo() end
	return a, calls
end

describe("the stage fog in the client", function()
	it("has its picture in the game atlas and in the meta atlas (the goal icon); it is a marked placeholder", function()
		local img = assets.images["blockers/fog"]
		assert_true(img ~= nil, "blockers/fog is in the index")
		assert_same({ img.atlas, img.anim, img.w, img.h }, { "game", "blockers_fog", 160, 160 })
		assert_same(img.also, { "meta" })
		assert_same({ level_fog.IMAGE, level_fog.ANIM }, { "blockers/fog", "blockers_fog" })
	end)

	it("the goal `fog` is drawn like the others: an icon, the number of fogged cells and a name", function()
		assert_same(levels.goals(fog_level({ { type = "fog" } })),
			{ { kind = "fog", image = "blockers/fog", count = #FOG, label = { key = "blocker.fog" } } })
		assert_eq(level_fog.count({}), 0)
		assert_eq(level_fog.count(nil), 0)
	end)

	it("has its name, its description and its lesson line in three languages; the lesson fits the bubble", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			i18n.set_language(lang)
			for _, key in ipairs({ "blocker.fog", "blocker.fog_desc", "tutorial.fog" }) do
				local text = i18n.t(key)
				assert_true(type(text) == "string" and text ~= "" and text ~= key, lang .. " " .. key)
			end
			local lesson = i18n.t("tutorial.fog")
			assert_true(bubble_lines(lesson, lang) <= 2, lang .. ": the lesson takes more than two lines")
			assert_true(#require("tests.client.town_defold_stub").utf8_codepoints(lesson) <= 64, lang)
		end
		i18n.set_language("ru")
		assert_eq(i18n.t("blocker.fog"), "Туман")
		assert_eq(i18n.t("blocker.fog_desc"), "Под туманом фишек не видно. Собери ряд рядом, и туман рассеется.")
		assert_eq(i18n.t("tutorial.fog"), "Туман прячет фишки. Собери ряд рядом!")
		i18n.set_language("en")
		assert_eq(i18n.t("blocker.fog"), "Fog")
	end)
end)

describe("client/level_fog.lua: the clouds", function()
	local function new(list, reduced)
		return level_fog.new({ cells = cells_with(list or { { 3, 3 }, { 4, 3 } }), W = 6, reduced = reduced })
	end

	local function frame(F, t)
		local list = {}
		local n = F:fill(list, 0, board_geom(), t, 0, 0)
		return list, n
	end

	it("one cloud over every fogged cell, above the pieces, a little wider than the cell", function()
		local F = new()
		local g = board_geom()
		assert_true(F:any() and F:active())
		assert_true(F:on(3, 3) and F:on(4, 3))
		assert_false(F:on(5, 3))
		local list, n = frame(F, 0)
		assert_eq(n, 2)
		assert_eq(F:count(), 2)
		local x, y = g:center(3, 3)
		assert_same({ list[1].image, list[1].x, list[1].y, list[1].alpha }, { "blockers_fog", x, y, 1 })
		assert_true(list[1].w > g.cell and list[1].w < g.cell * 1.3, "neighbouring clouds overlap")
		assert_true(list[1].z > level_anim.Z.special and list[1].z > level_anim.Z.fly and list[1].z > level_anim.Z.blocker,
			"above everything that stands or flies")
		-- a board at rest gives the same marks again (nothing is allocated, nothing moves)
		local again = frame(F, 7)
		assert_true(again[1] == list[1] and again[1].x == x and again[1].w == list[1].w)
	end)

	it("the `fog` event blows the cloud off: it swells and fades in PUFF_TIME, then nothing is left", function()
		local F = new()
		local before = frame(F, 1)[1].w
		F:event({ type = "match" }, 1)
		assert_true(F:on(3, 3))
		F:event({ type = "fog", x = 3, y = 3 }, 1)
		assert_false(F:on(3, 3))
		assert_true(F:on(4, 3))
		local list, n = frame(F, 1 + level_fog.PUFF_TIME / 2)
		assert_eq(n, 2)
		assert_true(list[1].alpha < 1 and list[1].alpha > 0 and list[1].w > before, "the puff")
		assert_eq(list[2].alpha, 1)
		list, n = frame(F, 1 + level_fog.PUFF_TIME + 0.01)
		assert_eq(n, 1)
		-- a second event for the same cell changes nothing; the fog never comes back
		F:event({ type = "fog", x = 3, y = 3 }, 2)
		assert_eq(select(2, frame(F, 2.01)), 1)
		F:event({ type = "fog", x = 4, y = 3 }, 3)
		frame(F, 4)
		assert_false(F:active())
		assert_true(F:any(), "it was a fog level")
	end)

	it("with reduced motion the cloud only fades", function()
		local F = new(nil, true)
		local before = frame(F, 1)[1].w
		F:event({ type = "fog", x = 3, y = 3 }, 1)
		local list = frame(F, 1 + level_fog.PUFF_TIME / 2)
		assert_eq(list[1].w, before)
		assert_true(list[1].alpha < 1)
	end)

	it("the hint swells the cloud of a hinted cell; a refused touch shakes it", function()
		local F = new()
		local g = board_geom()
		local base = frame(F, 0)[1].w
		F:hint({ 3, 3 }, { 3, 2 }, 0.5)
		local list = frame(F, 0)
		assert_true(list[1].w > base, "the hinted cloud swells")
		assert_eq(list[2].w, base)
		F:hint(nil)
		assert_eq(frame(F, 0)[1].w, base)
		assert_false(F:nope(1, 1, 1), "no cloud there")
		assert_true(F:nope(4, 3, 1))
		list = frame(F, 1.04)
		local x3, x4 = g:center(3, 3), g:center(4, 3)
		assert_eq(list[1].x, x3)
		assert_true(list[2].x ~= x4 and math.abs(list[2].x - x4) < g.cell * 0.1)
		list = frame(F, 1 + level_fog.NOPE_TIME + 0.01)
		assert_eq(list[2].x, x4)
	end)

	it("tells the input the same about every fogged cell, whatever the core has there", function()
		local F = new()
		local a, b = F:unknown(3, 3), F:unknown(4, 3)
		assert_eq(F:unknown(5, 3), nil)
		for _, u in ipairs({ a, b }) do
			assert_same({ u.kind, u.state, u.pinned, u.wired, u.chained, u.frozen, u.veiled, u.fogged },
				{ "regular", "idle", false, false, false, false, false, true })
			assert_eq(u.color, nil)
			assert_eq(u.special, nil)
			assert_true(u.id >= level_fog.FOG_ID)
			assert_true(F:find(u.id) == u)
		end
		assert_true(a.id ~= b.id)
		F:event({ type = "fog", x = 3, y = 3 }, 1)
		assert_eq(F:unknown(3, 3), nil)
		assert_eq(F:find(a.id), nil)
	end)

	it("follows the core when it is asked to: the janitor's look", function()
		local F = new()
		assert_eq(F:sync(cells_with({ { 3, 3 }, { 4, 3 } })), 0)
		assert_eq(F:sync(cells_with({ { 4, 3 } })), 1)
		assert_false(F:on(3, 3))
		assert_eq(select(2, frame(F, 5)), 1)
	end)

	it("a level without fog draws nothing and costs nothing", function()
		local F = level_fog.new({ cells = cells_with({}), W = 6 })
		assert_false(F:any())
		assert_false(F:active())
		local list = {}
		assert_eq(F:fill(list, 3, board_geom(), 1, 0, 0), 3)
		F:event({ type = "fog", x = 3, y = 3 }, 1)
		assert_false(F:on(3, 3))
		assert_false(F:nope(3, 3, 1))
		assert_eq(F:sync(cells_with({})), 0)
	end)
end)

describe("the pieces under the fog are not drawn (client/level_anim.lua)", function()
	local function anim(fogged)
		local set = {}
		for _, c in ipairs(fogged) do set[c[1] .. "," .. c[2]] = true end
		return level_anim.new({ geom = board_geom(), fog_at = function(x, y) return set[x .. "," .. y] == true end }), set
	end

	local function by_id(list)
		local out = {}
		for _, e in ipairs(list) do out[e.id] = e end
		return out
	end

	it("a piece at rest in a fogged cell has no alpha, with its chain and its ice; its neighbour is drawn", function()
		local A = anim({ { 2, 2 }, { 4, 2 }, { 5, 2 } })
		local pieces = {
			{ id = 1, x = 2, y = 2, kind = "regular", color = "blue", state = "idle", offx = 0, offy = 0 },
			{ id = 2, x = 3, y = 2, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0 },
			{ id = 3, x = 4, y = 2, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0, chain = 1 },
			{ id = 4, x = 5, y = 2, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0, ice = 2 },
			{ id = 5, x = 2, y = 3, kind = "special", special = "sub", state = "idle", offx = 0, offy = 0 },
		}
		local e = by_id(A:frame(pieces, 0, 0))
		assert_eq(e[1].alpha, 0)
		assert_eq(e[2].alpha, 1)
		assert_eq(e[3].alpha, 0)
		assert_eq(e[level_anim.CHAIN_ID + 3].alpha, 0)
		assert_eq(e[4].alpha, 0)
		assert_eq(e[level_anim.ICE_ID + 4].alpha, 0)
		assert_eq(e[5].alpha, 1)
		-- a hint or a selection does not bring it back
		A:hint({ 2, 2 }, { 3, 2 }, 0.5)
		A:select(1)
		e = by_id(A:frame(pieces, 1, 0.1))
		assert_eq(e[1].alpha, 0)
	end)

	it("a piece that falls into a fogged cell goes out as its centre enters the cloud, and shows again below it", function()
		local A = anim({ { 2, 3 } })
		local p = { id = 1, x = 2, y = 3, kind = "regular", color = "blue", state = "fall", offx = 0, offy = 3600 } -- (the lag is in 1/3600 of a cell)
		-- still over the cell above (its centre is in (2,2)): drawn
		assert_eq(A:frame({ p }, 0, 0)[1].alpha, 1)
		p.offy = 1080
		assert_eq(A:frame({ p }, 1, 0.02)[1].alpha, 0)
		p.offy, p.state = 0, "idle"
		assert_eq(A:frame({ p }, 2, 0.04)[1].alpha, 0)
		-- it falls on, out of the fog: its target cell is (2,4), its centre still in the cloud, then below it
		p.y, p.state, p.offy = 4, "fall", 2880
		assert_eq(A:frame({ p }, 3, 0.06)[1].alpha, 0)
		p.offy = 720
		assert_eq(A:frame({ p }, 4, 0.08)[1].alpha, 1)
	end)

	it("a failed blind swap shows nothing of the hidden piece, on its way out and back", function()
		local A = anim({ { 2, 2 } })
		local hidden = { id = 1, x = 2, y = 2, kind = "regular", color = "blue", state = "idle", offx = 0, offy = 0 }
		local seen = { id = 2, x = 3, y = 2, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0 }
		A:frame({ hidden, seen }, 0, 0)
		A:event({ type = "swap_fail", a = { 3, 2 }, b = { 2, 2 }, ids = { 2, 1 }, t = 1, duration = 14 }, 0.02)
		hidden.state, seen.state = "swap", "swap"
		for tick = 1, 15 do
			local e = by_id(A:frame({ hidden, seen }, tick, tick / 60))
			assert_eq(e[1].alpha, 0, "tick " .. tick)
			assert_eq(e[2].alpha, 1)
		end
		hidden.state, seen.state = "idle", "idle"
		local e = by_id(A:frame({ hidden, seen }, 16, 16 / 60))
		assert_same({ e[1].alpha, e[2].alpha }, { 0, 1 })
	end)

	it("a piece swapped into the fog disappears when it arrives; one dragged out shows only when the fog is gone", function()
		local A, set = anim({ { 2, 2 } })
		local hidden = { id = 1, x = 2, y = 2, kind = "regular", color = "blue", state = "idle", offx = 0, offy = 0 }
		local seen = { id = 2, x = 3, y = 2, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0 }
		A:frame({ hidden, seen }, 0, 0)
		A:event({ type = "swap", a = { 3, 2 }, b = { 2, 2 }, ids = { 2, 1 }, t = 1, duration = 10 }, 0.02)
		hidden.state, seen.state = "swap", "swap"
		for tick = 1, 10 do
			local e = by_id(A:frame({ hidden, seen }, tick, tick / 60))
			assert_eq(e[1].alpha, 0, "the piece dragged out stays hidden during the swap")
			assert_eq(e[2].alpha, 1, "the visible piece is seen until it arrives")
		end
		-- the swap ends: the pieces stand in each other's cells
		hidden.x, seen.x = 3, 2
		hidden.state, seen.state = "idle", "idle"
		-- the match blew the fog off (2,2) in the same tick (the core's `fog` event): both are in the open now
		set["2,2"] = nil
		local e = by_id(A:frame({ hidden, seen }, 11, 11 / 60))
		assert_same({ e[1].alpha, e[2].alpha }, { 1, 1 })
		-- had the fog stayed (a swap back), the piece that went in would be hidden and the other one seen
		local B = anim({ { 2, 2 } })
		B:frame({ hidden, seen }, 0, 0)
		e = by_id(B:frame({ hidden, seen }, 1, 0.02))
		assert_same({ e[1].alpha, e[2].alpha }, { 1, 0 })
	end)

	it("a shuffle: a piece that flies from fog to fog is hidden all the way; into the open it shows as it leaves", function()
		local A = anim({ { 2, 2 }, { 5, 2 } })
		-- piece 1 flies from the fogged (2,2) to the fogged (5,2) over the open (3,2) and (4,2); piece 2 from the
		-- fogged (5,2) to the open (2,4); piece 3 from the open (2,4) to the fogged (2,2)
		local p1 = { id = 1, x = 2, y = 2, kind = "regular", color = "blue", state = "idle", offx = 0, offy = 0 }
		local p2 = { id = 2, x = 5, y = 2, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0 }
		local p3 = { id = 3, x = 2, y = 4, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0 }
		local e = by_id(A:frame({ p1, p2, p3 }, 0, 0))
		assert_same({ e[1].alpha, e[2].alpha, e[3].alpha }, { 0, 0, 1 })
		A:event({ type = "shuffle", t = 1, duration = 30, moves = { { id = 1, fx = 2, fy = 2, x = 5, y = 2 },
			{ id = 2, fx = 5, fy = 2, x = 2, y = 4 }, { id = 3, fx = 2, fy = 4, x = 2, y = 2 } } }, 0.02)
		p1.x, p1.y, p2.x, p2.y, p3.x, p3.y = 5, 2, 2, 4, 2, 2
		p1.state, p2.state, p3.state = "swap", "swap", "swap"
		local shown2, hidden3 = false, false
		for tick = 1, 34 do
			e = by_id(A:frame({ p1, p2, p3 }, tick, tick / 60))
			assert_eq(e[1].alpha, 0, "fog to fog, tick " .. tick)
			if e[2].alpha == 1 then shown2 = true end
			if tick > 31 then
				assert_eq(e[2].alpha, 1)
				assert_eq(e[3].alpha, 0)
			end
			if e[3].alpha == 0 then hidden3 = true end
		end
		assert_true(shown2 and hidden3)
		p1.state, p2.state, p3.state = "idle", "idle", "idle"
		e = by_id(A:frame({ p1, p2, p3 }, 40, 40 / 60))
		assert_same({ e[1].alpha, e[2].alpha, e[3].alpha }, { 0, 1, 0 })
	end)

	it("without the option nothing is hidden: a level without fog draws as before", function()
		local A = level_anim.new({ geom = board_geom() })
		local p = { id = 1, x = 2, y = 2, kind = "regular", color = "blue", state = "idle", offx = 0, offy = 0 }
		assert_eq(A:frame({ p }, 0, 0)[1].alpha, 1)
	end)
end)

describe("the fog blows off: effects, sound, input", function()
	it("a few wisps of dust in the colour of the fog", function()
		local E = level_effects.new({ geom = board_geom() })
		E:event({ type = "fog", t = 3, x = 2, y = 2 })
		local q = E:drain()
		assert_eq(#q, 1)
		assert_same({ q[1].kind, q[1].fx, q[1].color, q[1].count }, { "burst", level_fog.PUFF_FX, level_fog.COLOR, level_fog.PUFF_COUNT })
	end)

	it("a soft whoosh, a sound that exists; a row that clears at once does not play it for every cell", function()
		local a, calls = fake_audio()
		local t = 0
		local la = level_audio.new({ audio = a, now = function() return t end })
		la:events({ { type = "fog", x = 2, y = 2 }, { type = "fog", x = 3, y = 2 }, { type = "fog", x = 4, y = 2 } })
		assert_eq(#calls, 1)
		assert_eq(calls[1][1], level_fog.PUFF_SFX)
		assert_true(calls[1][2].gain < 1, "soft")
		assert_true(assets.sounds.sfx[level_fog.PUFF_SFX] ~= nil)
		t = 1
		la:events({ { type = "fog", x = 2, y = 3 } })
		assert_eq(#calls, 2)
	end)

	it("a fogged cell can be picked and swiped like a piece, whatever hides there; the Crossfader refuses it", function()
		local F = level_fog.new({ cells = cells_with({ { 2, 2 }, { 2, 3 } }), W = 6 })
		-- the core has a blocker in (2,2) and a special in (2,3): the input never hears of them
		local objs = { ["2,2"] = { id = 1, kind = "blocker", state = "idle" }, ["3,2"] = { id = 2, kind = "regular", state = "idle" },
			["2,3"] = { id = 3, kind = "special", state = "idle" } }
		local inp = level_input.new({ query = function(x, y) return F:unknown(x, y) or objs[x .. "," .. y] end })
		inp:press(2, 2)
		assert_same(inp:move(2.45, 2.05), { type = "swap", from = { 2, 2 }, to = { 3, 2 } })
		inp:release(2.45, 2.05)
		inp:press(3, 2)
		assert_same(inp:move(2.55, 2.05), { type = "swap", from = { 3, 2 }, to = { 2, 2 } })
		inp:release(2.55, 2.05)
		-- a tap on the fogged special does not launch it at once (that would tell a special from a piece):
		-- the first tap picks the cell, the second one is the blind tap the core judges
		inp:press(2, 3)
		assert_eq(inp:release(2, 3), nil)
		assert_true(inp.selected ~= nil and inp.selected.id >= level_fog.FOG_ID)
		inp:press(2, 3)
		assert_same(inp:release(2, 3), { type = "tap", at = { 2, 3 } })
		assert_true(inp:target("swap"))
		local cmd, note = inp:pick_pair(2, 2)
		assert_eq(cmd, nil)
		assert_same({ note.kind, note.why }, { "refuse", "not_movable" })
	end)

	it("a session plays a fog level by the hints: the fog clears and the goal is reached", function()
		local s = assert(level_session.new({ params = { level = 261, level_text = fog_level({ { type = "fog" } }) } }))
		local game = s.game
		local cleared = 0
		for _ = 1, 60 do
			game:run_to_rest()
			for _, e in ipairs(game:drain_events()) do
				if e.type == "fog" then cleared = cleared + 1 end
			end
			if game:status().state ~= "playing" or game:status().moves_left == 0 then break end
			local cmd = s:hint_command()
			if not cmd then break end
			assert_true(game:input(cmd))
		end
		assert_eq(cleared, #FOG)
		assert_true(game:status().state ~= "playing", "the level ended: " .. game:status().state)
	end)
end)

describe("screens/level/board.script with fog (core-rules 10.13)", function()
	-- Runs fn(env, script, self, drive) with a board on display; always restores the globals.
	local function with_board(params, fn)
		local E = stub.install({})
		local ok, err = pcall(function()
			boot_app()
			app.params = params
			local sub = bus.subscribe("*", "fog_test")
			local script = stub.load_script("screens/level/board.script")
			local self = {}
			script.init(self)
			assert_true(not self.failed, "the board failed to start")
			self.strict = true -- cosmetic errors are not swallowed in tests
			local d = {}
			function d.frame(n, each)
				for _ = 1, n or 1 do
					E.advance(DT)
					script.update(self, DT)
					if each then each() end
				end
				sub:drain(function() end)
			end
			function d.touch(kind, lx, ly)
				local f = layout.fit(E.window.w, E.window.h)
				local sx, sy = layout.logical_to_screen(f, lx, ly)
				local action = { screen_x = sx, screen_y = sy, x = sx, y = sy, pressed = kind == "down", released = kind == "up" }
				return script.on_input(self, hash("touch"), action)
			end
			function d.swipe(ax, ay, bx, by)
				local lx, ly = self.geom:center(ax, ay)
				local c = self.geom.cell
				d.touch("down", lx, ly)
				d.frame(1)
				d.touch("move", lx + (bx - ax) * c * 0.45, ly - (by - ay) * c * 0.45)
				d.frame(1)
				d.touch("up", lx + (bx - ax) * c * 0.45, ly - (by - ay) * c * 0.45)
			end
			function d.settle(max_frames)
				for _ = 1, max_frames or 900 do
					d.frame(1)
					if self.session.game:is_stable() then return true end
				end
				return false
			end
			local ok2, err2 = pcall(fn, E, script, self, d)
			pcall(script.final, self)
			sub:close()
			if not ok2 then error(err2, 0) end
		end)
		stub.restore()
		if not ok then error(err, 0) end
	end

	-- the sprites the player can see now, split: the clouds, and the pieces (regular, special) with their cell
	local function seen(E, self)
		local clouds, pieces = 0, {}
		for _, sp in ipairs(E.visible_sprites()) do
			if sp.factory == "piece_factory" then
				if sp.image == "blockers_fog" then
					clouds = clouds + 1
				elseif sp.image:find("^pieces_") or sp.image:find("^specials_") then
					local x, y = self.geom:cell_at(sp.x, sp.y)
					pieces[#pieces + 1] = { image = sp.image, x = x, y = y, alpha = sp.alpha }
				end
			end
		end
		return clouds, pieces
	end

	local function fogged(self)
		local set, n = {}, 0
		local cells = self.session.game:cells()
		for i = 1, #cells do
			if cells[i].fog then
				set[i] = true
				n = n + 1
			end
		end
		return set, n
	end

	-- at rest: one cloud a fogged cell, no piece drawn in a fogged cell, a piece drawn in every other cell
	local function check_rest(E, self, why)
		local set, n = fogged(self)
		local clouds, pieces = seen(E, self)
		assert_eq(clouds, n, why .. ": one cloud a fogged cell")
		local at = {}
		for _, p in ipairs(pieces) do
			assert_true(p.x ~= nil, why .. ": a piece off the grid")
			local i = (p.y - 1) * 6 + p.x
			assert_false(set[i] == true, why .. ": a piece is drawn under the fog at " .. p.x .. "," .. p.y .. " (" .. p.image .. ")")
			at[i] = true
		end
		for i = 1, 36 do
			if not set[i] then assert_true(at[i] == true, why .. ": the piece of the open cell " .. i .. " is drawn") end
		end
		return n
	end

	it("draws a cloud over every fogged cell and no piece under it; the HUD goal counts the cells", function()
		with_board({ level = 1, level_text = fog_level() }, function(E, script, self, d)
			d.frame(90)
			assert_true(self.fog ~= nil)
			assert_eq(check_rest(E, self, "start"), #FOG)
			-- the truth is there for the core: every fogged cell holds a piece
			local hidden = 0
			for _, p in ipairs(self.session.game:pieces()) do
				if p.fogged then hidden = hidden + 1 end
			end
			assert_eq(hidden, #FOG)
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("a level without fog has no fog module on the board", function()
		local text = core_helper.level(FULL, { moves = 30, colors = { "red", "yellow", "blue", "purple" } })
		with_board({ level = 1, level_text = text }, function(E, script, self, d)
			d.frame(60)
			assert_eq(self.fog, nil)
			local clouds, pieces = seen(E, self)
			assert_eq(clouds, 0)
			assert_eq(#pieces, 36)
		end)
	end)

	it("a hit on a fogged cell: the cloud puffs away and what stands there now is drawn", function()
		with_board({ level = 1, level_text = fog_level() }, function(E, script, self, d)
			d.frame(90)
			local game = self.session.game
			local whoosh = 0
			for _, m in ipairs(E.msgs) do
				if m.id == "sfx" and m.message.name == level_fog.PUFF_SFX then whoosh = whoosh + 1 end
			end
			-- the core takes the booster directly (the tray and the wallet are another test's business)
			assert_true(game:input({ type = "booster", booster = "stick", at = { 3, 4 } }))
			d.frame(4)
			assert_false(game:cells()[(4 - 1) * 6 + 3].fog == true, "the fog is off the cell")
			-- the puff: the cloud of the cell is still on the screen for a moment, fading
			local fading = false
			for _, sp in ipairs(E.visible_sprites()) do
				if sp.image == "blockers_fog" and sp.alpha < 0.99 then fading = true end
			end
			assert_true(fading, "the cloud fades out")
			assert_true(d.settle(), "the board came to rest")
			d.frame(40)
			local n = check_rest(E, self, "after the stick")
			assert_true(n < #FOG)
			local after = 0
			for _, m in ipairs(E.msgs) do
				if m.id == "sfx" and m.message.name == level_fog.PUFF_SFX then after = after + 1 end
			end
			assert_true(after > whoosh, "the whoosh of the fog")
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("a played level: at every rest the clouds are the core's and nothing shows under them", function()
		with_board({ level = 1, level_text = fog_level() }, function(E, script, self, d)
			d.frame(90)
			local game = self.session.game
			local left = #FOG
			for _ = 1, 12 do
				if game:status().state ~= "playing" then break end
				local cmd = self.session:hint_command()
				if not cmd or cmd.type ~= "swap" then break end
				d.swipe(cmd.from[1], cmd.from[2], cmd.to[1], cmd.to[2])
				assert_true(d.settle(), "the board came to rest")
				d.frame(40)
				if game:status().state == "playing" then left = check_rest(E, self, "a hint move") end
				if left == 0 then break end
			end
			assert_true(left < #FOG, "the hint moves cleared fog: " .. left .. " of " .. #FOG .. " left")
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("a blind swap that fails: the hidden piece is never drawn, no move is spent, the fog stays", function()
		with_board({ level = 1, level_text = fog_level() }, function(E, script, self, d)
			d.frame(90)
			local game = self.session.game
			-- a visible piece next to the bank whose swap into it gives no match (asked of a clone of the core)
			local from, to
			for _, c in ipairs({ { 1, 3, 2, 3 }, { 1, 4, 2, 4 }, { 1, 5, 2, 5 }, { 5, 3, 4, 3 }, { 5, 4, 4, 4 }, { 5, 5, 4, 5 },
				{ 2, 2, 2, 3 }, { 3, 2, 3, 3 }, { 4, 2, 4, 3 }, { 2, 6, 2, 5 }, { 3, 6, 3, 5 }, { 4, 6, 4, 5 } }) do
				local probe = game:clone()
				probe:input({ type = "swap", from = { c[1], c[2] }, to = { c[3], c[4] } })
				local failed = false
				for _ = 1, 30 do
					probe:step()
					for _, e in ipairs(probe:drain_events()) do
						if e.type == "swap_fail" then failed = true end
					end
				end
				if failed then
					from, to = { c[1], c[2] }, { c[3], c[4] }
					break
				end
			end
			assert_true(from ~= nil, "a failing blind swap exists on this board")
			local moves = game:status().moves_left
			local _, visible0 = seen(E, self)
			d.swipe(from[1], from[2], to[1], to[2])
			local max_seen = 0
			d.frame(40, function()
				local _, pieces = seen(E, self)
				if #pieces > max_seen then max_seen = #pieces end
			end)
			assert_eq(max_seen, #visible0, "never one piece more on the screen than before the swap")
			assert_true(d.settle())
			assert_eq(game:status().moves_left, moves)
			assert_eq(check_rest(E, self, "after the failed swap"), #FOG)
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("a swap into a fogged cell the core refuses (something fixed hides there) looks like a failed swap, no toast", function()
		with_board({ level = 1, level_text = fog_level() }, function(E, script, self, d)
			d.frame(90)
			local game = self.session.game
			-- white box: the hidden piece of (2,4) becomes a concrete block (in a real level noise may spread there)
			local o = core_helper.obj_at(game, 2, 4)
			o.kind, o.blocker, o.hp, o.color = 4, 2, 1, 0
			d.frame(200) -- (the janitor takes the new look of the core)
			local toasts = 0
			local sub = bus.subscribe("level_toast", "fog_refusal")
			local _, visible0 = seen(E, self)
			local mover = self.cellmap[(4 - 1) * 6 + 1]
			d.swipe(1, 4, 2, 4)
			d.frame(2)
			local rec = self.anim:record(mover.id)
			assert_true(rec.feint ~= nil, "the visible piece makes the move of a failed swap")
			local max_seen = 0
			d.frame(40, function()
				local _, pieces = seen(E, self)
				if #pieces > max_seen then max_seen = #pieces end
				for _, sp in ipairs(E.visible_sprites()) do
					assert_true(sp.image ~= "blockers_concrete_1", "the hidden block is never drawn")
				end
			end)
			sub:drain(function() toasts = toasts + 1 end)
			sub:close()
			assert_eq(toasts, 0, "no text tells what hides there")
			assert_eq(max_seen, #visible0)
			assert_eq(game:status().moves_left, 30)
			assert_eq(self.errors or 0, 0)
		end)
	end)
end)
