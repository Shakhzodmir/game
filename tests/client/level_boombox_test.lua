-- The boombox (core-rules 10.10) in the client: its three pictures by the hp left, the goal icon and the texts,
-- the hit (wobble, debris, the sound of the record box), the play (the shake, the sound waves on the blasted
-- pieces, the thump) and the board script (screens/level/board.script) on the strict Defold stub.

local stub = require("tests.client.level_defold_stub")
local app = require("client.app")
local assets = require("client.assets_index")
local bus = require("client.bus")
local i18n = require("client.i18n")
local layout = require("client.layout")
local levels = require("client.levels")
local level_anim = require("client.level_anim")
local level_audio = require("client.level_audio")
local level_boombox = require("client.level_boombox")
local level_effects = require("client.level_effects")
local level_session = require("client.level_session")
local geom = require("client.level_geom")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local core_helper = require("tests.core.helper")
local H = require("tests.meta.helper")

local DT = 1 / 60
local FULL = { "######", "######", "######", "######", "######", "######" }

-- a 6x6 board with three boomboxes: new (2,2), cracked (5,3), broken (3,5)
local function boombox_level(goals)
	return core_helper.level(FULL, { moves = 30, colors = { "red", "yellow", "blue", "purple" },
		goals = goals or { { type = "break", item = "boombox", count = 3 } },
		slots = { { at = { 1, 1 }, type = "boombox", hp = 3 }, { at = { 4, 2 }, type = "boombox", hp = 2 },
			{ at = { 2, 4 }, type = "boombox", hp = 1 } } })
end

local function board_geom()
	local cells = {}
	for i = 1, 36 do cells[i] = { exists = true } end
	return geom.new(6, 6, cells, { x0 = 0, y0 = 0, x1 = 636, y1 = 624 })
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

describe("the boombox in the client", function()
	it("has three pictures in the game atlas, by the hp left, and the new one in the meta atlas (the goal icon)", function()
		for hp = 1, 3 do
			local img = assets.images["blockers/boombox_" .. hp]
			assert_true(img ~= nil, "blockers/boombox_" .. hp .. " is in the index")
			assert_same({ img.atlas, img.anim, img.w, img.h }, { "game", "blockers_boombox_" .. hp, 160, 160 })
		end
		assert_same(assets.images["blockers/boombox_3"].also, { "meta" })
		assert_eq(assets.images["blockers/boombox_1"].also, nil)
		assert_same({ level_boombox.image(3), level_boombox.image(2), level_boombox.image(1) },
			{ "blockers/boombox_3", "blockers/boombox_2", "blockers/boombox_1" })
		-- out of range: the nearest picture, never a missing one
		assert_same({ level_boombox.anim(0), level_boombox.anim(7), level_boombox.anim(nil) },
			{ "blockers_boombox_1", "blockers_boombox_3", "blockers_boombox_1" })
		assert_eq(level_boombox.GOAL_ICON, "blockers/boombox_3")
	end)

	it("the goal `break boombox` is drawn like the others: an icon, a counter and a name", function()
		local goals = levels.goals(boombox_level())
		assert_same(goals, { { kind = "break", image = "blockers/boombox_3", count = 3, item = "boombox",
			label = { key = "blocker.boombox" } } })
	end)

	it("has its name, its description and its lesson line in three languages; the lesson fits the bubble", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			i18n.set_language(lang)
			for _, key in ipairs({ "blocker.boombox", "blocker.boombox_desc", "tutorial.boombox" }) do
				local text = i18n.t(key)
				assert_true(type(text) == "string" and text ~= "" and text ~= key, lang .. " " .. key)
			end
			local lesson = i18n.t("tutorial.boombox")
			assert_true(bubble_lines(lesson, lang) <= 2, lang .. ": the lesson takes more than two lines")
			assert_true(#require("tests.client.town_defold_stub").utf8_codepoints(lesson) <= 64, lang)
		end
		i18n.set_language("ru")
		assert_eq(i18n.t("blocker.boombox"), "Бумбокс")
		assert_eq(i18n.t("blocker.boombox_desc"), "Собери ряд рядом с бумбоксом: он лопнет ещё три фишки такого же цвета.")
		assert_eq(i18n.t("tutorial.boombox"), "Ряд рядом с бумбоксом лопает ещё три таких же!")
		i18n.set_language("en")
		assert_eq(i18n.t("blocker.boombox"), "Boombox")
	end)

	it("the draw list shows the picture of the hp left; a hit wobbles it, a play shakes it sideways", function()
		local A = level_anim.new({ geom = board_geom() })
		local pieces = {
			{ id = 1, x = 2, y = 2, kind = "blocker", item = "boombox", hp = 3, state = "idle", offx = 0, offy = 0 },
			{ id = 2, x = 3, y = 2, kind = "regular", color = "blue", state = "idle", offx = 0, offy = 0 },
		}
		for hp = 1, 3 do
			assert_eq(level_anim.image({ kind = "blocker", item = "boombox", hp = hp }), "blockers_boombox_" .. hp)
		end
		local list = A:frame(pieces, 0, 0)
		assert_eq(list[1].image, "blockers_boombox_3")
		local x0 = list[1].x
		-- the hit of a match next to it: one hp less, the wobble of every blocker
		A:event({ type = "hit", layer = "blocker", item = "boombox", x = 2, y = 2, hp = 2, t = 1 }, 1)
		pieces[1].hp = 2
		list = A:frame(pieces, 1, 1.05)
		assert_eq(list[1].image, "blockers_boombox_2")
		assert_true(list[1].sx > 1 and list[1].rot ~= 0 and list[1].flash > 0, "it wobbles")
		-- the play: it shakes from side to side for a moment, then stands still
		A:event({ type = "boombox", id = 1, x = 2, y = 2, color = "red", cells = { { 5, 5 } }, t = 1 }, 1)
		local lo, hi = 0, 0
		for k = 1, 30 do
			local l = A:frame(pieces, 1, 1 + k * DT)
			lo, hi = math.min(lo, l[1].x - x0), math.max(hi, l[1].x - x0)
		end
		assert_true(lo < 0 and hi > 0, "it swings both ways: " .. lo .. " .. " .. hi)
		list = A:frame(pieces, 1, 3)
		assert_near(list[1].x, x0, 1e-9)
		assert_same({ list[1].sx, list[1].rot }, { 1, 0 })
		assert_eq(list[2].x ~= nil, true)
	end)

	it("a hit throws teal debris; a play sends a sound wave of the match colour to every blasted piece", function()
		local g = board_geom()
		local E = level_effects.new({ geom = g })
		E:event({ type = "hit", t = 3, layer = "blocker", item = "boombox", x = 2, y = 2, hp = 2 })
		local q = E:drain()
		assert_eq(#q, 1)
		assert_same({ q[1].kind, q[1].color }, { "burst", level_boombox.COLOR })
		E:event({ type = "destroy", t = 3, id = 1, item = "boombox", x = 2, y = 2 })
		q = E:drain()
		assert_same({ q[1].kind, q[1].color }, { "burst", level_boombox.COLOR })
		-- the play: a flash and a ring on the boombox, then a flash and a ring on each of the three targets
		local cells = { { 5, 1 }, { 3, 4 }, { 6, 6 } }
		E:event({ type = "boombox", t = 4, id = 1, x = 2, y = 2, color = "purple", cells = cells })
		q = E:drain()
		local purple = level_effects.color_of("purple")
		local rings, flashes = {}, {}
		for _, c in ipairs(q) do
			assert_eq(c.color, purple)
			assert_eq(c.at, 4)
			if c.kind == "ring" then rings[#rings + 1] = c elseif c.kind == "flash" then flashes[#flashes + 1] = c end
		end
		assert_eq(#rings, 4)
		assert_eq(#flashes, 4)
		local bx, by = g:center(2, 2)
		assert_same({ rings[1].x, rings[1].y, rings[1].image }, { bx, by, level_boombox.WAVE_FX })
		for k, at in ipairs(cells) do
			local lx, ly = g:center(at[1], at[2])
			assert_same({ rings[k + 1].x, rings[k + 1].y, rings[k + 1].image }, { lx, ly, level_boombox.WAVE_FX })
			assert_near(rings[k + 1].size, g.cell * level_boombox.WAVE_SIZE, 1e-9)
		end
		-- the last play: a bigger ring of another picture
		E:event({ type = "boombox", t = 5, id = 1, x = 2, y = 2, color = "red", cells = {}, last = true })
		q = E:drain()
		local last_ring
		for _, c in ipairs(q) do
			if c.kind == "ring" then last_ring = c end
		end
		assert_eq(last_ring.image, level_boombox.LAST_FX)
		assert_true(last_ring.size > rings[1].size)
		-- reduced motion: the flashes only
		local R = level_effects.new({ geom = g, reduced = true })
		R:event({ type = "boombox", t = 4, id = 1, x = 2, y = 2, color = "purple", cells = cells })
		for _, c in ipairs(R:drain()) do assert_eq(c.kind, "flash") end
		-- the fx pictures exist
		assert_true(assets.images["fx/ring"] ~= nil and assets.images["fx/shock"] ~= nil)
	end)

	it("sounds like the record box when hit and broken; a play is one low thump, however many boomboxes play", function()
		local a, calls = fake_audio()
		local t = 0
		local la = level_audio.new({ audio = a, now = function() return t end })
		assert_eq(level_audio.BLOCKER_HIT.boombox, level_audio.BLOCKER_HIT.record_box)
		assert_eq(level_audio.BLOCKER_BREAK.boombox, level_audio.BLOCKER_BREAK.record_box)
		la:events({ { type = "hit", layer = "blocker", item = "boombox", x = 2, y = 2, hp = 2 } })
		assert_eq(calls[1][1], "box_hit")
		t = 1
		la:events({ { type = "boombox", id = 1, x = 2, y = 2, color = "red", cells = {} },
			{ type = "boombox", id = 2, x = 5, y = 3, color = "red", cells = {} } })
		assert_eq(#calls, 2)
		assert_eq(calls[2][1], level_boombox.PLAY_SFX)
		assert_true(calls[2][2].speed < 1, "lower than the hit")
		t = 2
		la:events({ { type = "destroy", id = 1, item = "boombox", x = 2, y = 2 } })
		assert_eq(calls[3][1], "box_break")
	end)

	it("a session plays a boombox level: pieces() carries the boomboxes, the hint moves hit them, they play", function()
		local s = assert(level_session.new({ params = { level = 201, level_text = boombox_level() } }))
		local game = s.game
		local hp = 0
		for _, p in ipairs(game:pieces()) do
			if p.item == "boombox" then hp = hp + p.hp end
		end
		assert_eq(hp, 6)
		local q = 0
		for _, row in ipairs(s:picture()) do
			for _ in string.gmatch(row, "Q") do q = q + 1 end
		end
		assert_eq(q, 3)
		local plays, blasted = 0, 0
		for _ = 1, 60 do
			game:run_to_rest()
			for _, e in ipairs(game:drain_events()) do
				if e.type == "boombox" then
					plays, blasted = plays + 1, blasted + #e.cells
					assert_true(e.id ~= nil and e.color ~= nil)
				end
			end
			if game:status().state ~= "playing" then break end
			local cmd = s:hint_command()
			if not cmd then break end
			if game:status().moves_left == 0 then break end
			assert_true(game:input(cmd))
		end
		assert_true(plays >= 1, "the hint hits boomboxes")
		assert_true(blasted >= 1, "and they blast pieces")
	end)
end)

describe("screens/level/board.script with boomboxes (core-rules 10.10)", function()
	-- Runs fn(env, script, self, drive) with a board on display; always restores the globals.
	local function with_board(params, fn)
		local E = stub.install({})
		local ok, err = pcall(function()
			boot_app()
			app.params = params
			local sub = bus.subscribe("*", "boombox_test")
			local script = stub.load_script("screens/level/board.script")
			local self = {}
			script.init(self)
			assert_true(not self.failed, "the board failed to start")
			self.strict = true -- cosmetic errors are not swallowed in tests
			local d = {}
			function d.frame(n)
				for _ = 1, n or 1 do
					E.advance(DT)
					script.update(self, DT)
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

	local function count_anim(E, anim)
		local n = 0
		for _, o in ipairs(E.by_factory("piece_factory")) do
			if E.visible(o) and E.sprite_of(o).anim == anim then n = n + 1 end
		end
		return n
	end

	-- the boomboxes of the game by the hp left: {n1, n2, n3}, and their total hp
	local function by_hp(self)
		local n, total = { 0, 0, 0 }, 0
		for _, p in ipairs(self.session.game:pieces()) do
			if p.item == "boombox" and p.state == "idle" then
				n[p.hp] = n[p.hp] + 1
				total = total + p.hp
			end
		end
		return n, total
	end

	local function sfx_count(E, name)
		local n = 0
		for _, m in ipairs(E.msgs) do
			if m.id == "sfx" and m.message.name == name then n = n + 1 end
		end
		return n
	end

	it("draws every boombox with the picture of its hp", function()
		with_board({ level = 1, level_text = boombox_level() }, function(E, script, self, d)
			d.frame(90)
			assert_same({ count_anim(E, "blockers_boombox_1"), count_anim(E, "blockers_boombox_2"), count_anim(E, "blockers_boombox_3") },
				{ 1, 1, 1 })
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("a played level: the pictures follow the hp, a hit sounds like the record box, nothing fails", function()
		with_board({ level = 1, level_text = boombox_level() }, function(E, script, self, d)
			d.frame(90)
			local _, start = by_hp(self)
			assert_eq(start, 6)
			local left = start
			for _ = 1, 25 do
				if self.session.game:status().state ~= "playing" then break end
				local cmd = self.session:hint_command()
				if not cmd or cmd.type ~= "swap" then break end
				d.swipe(cmd.from[1], cmd.from[2], cmd.to[1], cmd.to[2])
				assert_true(d.settle(), "the board came to rest")
				d.frame(30)
				local n
				n, left = by_hp(self)
				if self.session.game:status().state == "playing" then
					assert_same({ count_anim(E, "blockers_boombox_1"), count_anim(E, "blockers_boombox_2"), count_anim(E, "blockers_boombox_3") }, n)
				end
				if left <= start - 2 then break end
			end
			assert_true(left <= start - 2, "the hint moves took hp off the boomboxes: " .. left .. " of " .. start .. " left")
			assert_true(sfx_count(E, "box_hit") + sfx_count(E, "box_break") >= 1, "the record box sounds")
			assert_eq(self.errors or 0, 0)
		end)
	end)
end)
