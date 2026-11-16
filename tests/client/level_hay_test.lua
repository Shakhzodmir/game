-- The hay bale (core-rules 10.12) in the client: its two pictures by the hp left, the goal icon and the texts,
-- the hit (wobble, straw bits, a soft thud), the gift that pops out (the bloom and the sound of a special made
-- by a match) and the board script (screens/level/board.script) on the strict Defold stub.

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
local level_hay = require("client.level_hay")
local level_session = require("client.level_session")
local geom = require("client.level_geom")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local core_helper = require("tests.core.helper")
local H = require("tests.meta.helper")

local DT = 1 / 60
local FULL = { "######", "######", "######", "######", "######", "######" }

-- a 6x6 board with four bales: two full ones (hp 2) and two thinned ones (hp 1); three hide a special
local function hay_level(goals)
	return core_helper.level(FULL, { moves = 30, colors = { "red", "yellow", "blue", "purple" },
		goals = goals or { { type = "break", item = "hay", count = 4 } },
		slots = { { at = { 1, 1 }, type = "hay", hp = 2, gift = "sub" }, { at = { 4, 2 }, type = "hay", hp = 2, gift = "random" },
			{ at = { 2, 4 }, type = "hay", hp = 1, gift = "riff", axis = "v" }, { at = { 4, 4 }, type = "hay", hp = 1, gift = "none" } } })
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

describe("the hay bale in the client", function()
	it("has two pictures in the game atlas, by the hp left, and the full one in the meta atlas (the goal icon)", function()
		for hp = 1, 2 do
			local img = assets.images["blockers/hay_" .. hp]
			assert_true(img ~= nil, "blockers/hay_" .. hp .. " is in the index")
			assert_same({ img.atlas, img.anim, img.w, img.h }, { "game", "blockers_hay_" .. hp, 160, 160 })
		end
		assert_same(assets.images["blockers/hay_2"].also, { "meta" })
		assert_eq(assets.images["blockers/hay_1"].also, nil)
		assert_same({ level_hay.image(2), level_hay.image(1) }, { "blockers/hay_2", "blockers/hay_1" })
		-- out of range: the nearest picture, never a missing one
		assert_same({ level_hay.anim(0), level_hay.anim(7), level_hay.anim(nil) },
			{ "blockers_hay_1", "blockers_hay_2", "blockers_hay_1" })
		assert_eq(level_hay.GOAL_ICON, "blockers/hay_2")
	end)

	it("the goal `break hay` is drawn like the others: an icon, a counter and a name", function()
		local goals = levels.goals(hay_level())
		assert_same(goals, { { kind = "break", image = "blockers/hay_2", count = 4, item = "hay",
			label = { key = "blocker.hay" } } })
		assert_eq(levels.ITEM_IMAGE.hay, level_hay.GOAL_ICON)
	end)

	it("has its name, its description and its lesson line in three languages; the lesson fits the bubble", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			i18n.set_language(lang)
			for _, key in ipairs({ "blocker.hay", "blocker.hay_desc", "tutorial.hay" }) do
				local text = i18n.t(key)
				assert_true(type(text) == "string" and text ~= "" and text ~= key, lang .. " " .. key)
			end
			local lesson = i18n.t("tutorial.hay")
			assert_true(bubble_lines(lesson, lang) <= 2, lang .. ": the lesson takes more than two lines")
			assert_true(#require("tests.client.town_defold_stub").utf8_codepoints(lesson) <= 64, lang)
		end
		i18n.set_language("ru")
		assert_eq(i18n.t("blocker.hay"), "Стог сена")
		assert_eq(i18n.t("blocker.hay_desc"), "Разбери стог рядами по соседству: внутри может прятаться бонус.")
		assert_eq(i18n.t("tutorial.hay"), "В стоге сена спрятан бонус. Разбери его!")
		i18n.set_language("en")
		assert_eq(i18n.t("blocker.hay"), "Hay bale")
	end)

	it("the draw list shows the picture of the hp left; a hit wobbles the bale", function()
		local A = level_anim.new({ geom = board_geom() })
		local pieces = {
			{ id = 1, x = 2, y = 2, kind = "blocker", item = "hay", hp = 2, state = "idle", offx = 0, offy = 0 },
			{ id = 2, x = 3, y = 2, kind = "regular", color = "blue", state = "idle", offx = 0, offy = 0 },
		}
		for hp = 1, 2 do
			assert_eq(level_anim.image({ kind = "blocker", item = "hay", hp = hp }), "blockers_hay_" .. hp)
		end
		local list = A:frame(pieces, 0, 0)
		assert_eq(list[1].image, "blockers_hay_2")
		-- the hit of a match next to it: one hp less, the wobble of every blocker
		A:event({ type = "hit", layer = "blocker", item = "hay", x = 2, y = 2, hp = 1, t = 1 }, 1)
		pieces[1].hp = 1
		list = A:frame(pieces, 1, 1.05)
		assert_eq(list[1].image, "blockers_hay_1")
		assert_true(list[1].sx > 1 and list[1].rot ~= 0 and list[1].flash > 0, "it wobbles")
		list = A:frame(pieces, 1, 3)
		assert_same({ list[1].sx, list[1].rot }, { 1, 0 })
	end)

	it("the gift blooms in the cell of the bale like a special made by a match", function()
		local A = level_anim.new({ geom = board_geom() })
		-- the bale is gone; the special with a new id stands in its cell
		local pieces = { { id = 9, x = 2, y = 2, kind = "special", special = "sub", state = "idle", offx = 0, offy = 0 } }
		A:event({ type = "gift", id = 9, from = 1, x = 2, y = 2, special = "sub", t = 60 }, 1)
		local first = A:frame(pieces, 60, 1.001)
		assert_eq(first[1].image, "specials_sub")
		assert_true(first[1].sx < 0.5, "it starts small: " .. first[1].sx)
		assert_true(first[1].flash > 0, "with a flash")
		local small = first[1].sx -- (the entries of the draw list are reused by the next frame)
		local grown = A:frame(pieces, 90, 1 + level_anim.APPEAR_TIME + 0.5)
		assert_near(grown[1].sx, 1, 1e-9)
		assert_eq(grown[1].flash, 0)
		-- the same picture logic as a special made by a match (which waits for its pieces to fly in)
		local B = level_anim.new({ geom = board_geom() })
		B:event({ type = "special_new", id = 9, x = 2, y = 2, special = "sub", t = 60 }, 1)
		local late = B:frame(pieces, 60, 1 + level_anim.APPEAR_DELAY + 0.001)
		assert_near(late[1].sx, small, 1e-6)
	end)

	it("a hit throws straw bits; the end a bigger puff; the gift pops out with the bloom of a new special", function()
		local g = board_geom()
		local E = level_effects.new({ geom = g })
		E:event({ type = "hit", t = 3, layer = "blocker", item = "hay", x = 2, y = 2, hp = 1 })
		local q = E:drain()
		assert_eq(#q, 1)
		assert_same({ q[1].kind, q[1].fx, q[1].color }, { "burst", level_hay.STRAW_FX, level_hay.COLOR })
		local hit_count = q[1].count
		E:event({ type = "destroy", t = 3, id = 1, item = "hay", x = 2, y = 2 })
		q = E:drain()
		assert_same({ q[1].kind, q[1].fx, q[1].color }, { "burst", level_hay.STRAW_FX, level_hay.COLOR })
		assert_true(q[1].count > hit_count)
		assert_eq(level_effects.DEBRIS.hay.color, level_hay.COLOR)
		-- the gift: straw, then exactly what a special made by a match gets, five ticks earlier (nothing flies in)
		local function shape(list)
			local out = {}
			for _, c in ipairs(list) do out[#out + 1] = { c.kind, c.fx or c.image or "", c.color or "", c.size or 0 } end
			return out
		end
		for _, special in ipairs({ "riff", "sub", "bird", "disco" }) do
			E:event({ type = "gift", t = 20, id = 9, from = 1, x = 2, y = 2, special = special })
			local gift = E:drain()
			assert_same({ gift[1].kind, gift[1].fx, gift[1].color, gift[1].at }, { "burst", level_hay.STRAW_FX, level_hay.COLOR, 20 })
			table.remove(gift, 1)
			E:event({ type = "special_new", t = 20, id = 9, x = 2, y = 2, special = special })
			local made = E:drain()
			assert_same(shape(gift), shape(made))
			for k = 1, #gift do assert_eq(gift[k].at, made[k].at - 5) end
			local flash
			for _, c in ipairs(gift) do
				if c.kind == "flash" then flash = c end
			end
			assert_true(flash ~= nil and flash.at == 20, "a flash at the tick of the gift")
		end
	end)

	it("a hit is a soft thud, the end sounds like the record box, the gift like a new special", function()
		local a, calls = fake_audio()
		local t = 0
		local la = level_audio.new({ audio = a, now = function() return t end })
		assert_eq(level_audio.BLOCKER_BREAK.hay, level_audio.BLOCKER_BREAK.record_box)
		la:events({ { type = "hit", layer = "blocker", item = "hay", x = 2, y = 2, hp = 1 } })
		assert_eq(calls[1][1], level_hay.HIT_SFX)
		assert_true(calls[1][2].gain < 1 and calls[1][2].speed < 1, "softer and lower than the box")
		t = 1
		la:events({ { type = "destroy", id = 1, item = "hay", x = 2, y = 2 } })
		assert_eq(calls[2][1], "box_break")
		t = 2
		la:events({ { type = "gift", id = 9, from = 1, x = 2, y = 2, special = "bird" } })
		assert_eq(calls[3][1], "special_create")
		t = 3
		la:events({ { type = "special_new", id = 10, x = 3, y = 3, special = "bird" } })
		assert_eq(calls[4][1], calls[3][1])
		-- the sounds exist
		for _, name in ipairs({ level_hay.HIT_SFX, level_hay.BREAK_SFX, level_hay.GIFT_SFX }) do
			assert_true(assets.sounds.sfx[name] ~= nil, name)
		end
	end)

	it("a session plays a hay level: pieces() carries the bales but not their gifts, the gifts pop out", function()
		local s = assert(level_session.new({ params = { level = 241, level_text = hay_level() } }))
		local game = s.game
		local hp = 0
		for _, p in ipairs(game:pieces()) do
			if p.item == "hay" then
				hp = hp + p.hp
				assert_eq(p.gift, nil)
			end
		end
		assert_eq(hp, 6)
		local n = 0
		for _, row in ipairs(s:picture()) do
			for _ in string.gmatch(row, "H") do n = n + 1 end
		end
		assert_eq(n, 4)
		local gifts, destroyed = 0, 0
		for _ = 1, 60 do
			game:run_to_rest()
			for _, e in ipairs(game:drain_events()) do
				if e.type == "destroy" and e.item == "hay" then destroyed = destroyed + 1 end
				if e.type == "gift" then
					gifts = gifts + 1
					assert_true(e.id ~= nil and e.special ~= nil and e.from ~= nil)
				end
			end
			if game:status().state ~= "playing" then break end
			local cmd = s:hint_command()
			if not cmd then break end
			if game:status().moves_left == 0 then break end
			assert_true(game:input(cmd))
		end
		assert_true(destroyed >= 2, "the hint takes the bales apart: " .. destroyed)
		assert_true(gifts >= 1, "and a gift pops out")
	end)
end)

describe("screens/level/board.script with hay bales (core-rules 10.12)", function()
	-- Runs fn(env, script, self, drive) with a board on display; always restores the globals.
	local function with_board(params, fn)
		local E = stub.install({})
		local ok, err = pcall(function()
			boot_app()
			app.params = params
			local sub = bus.subscribe("*", "hay_test")
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
			function d.tap(x, y)
				local lx, ly = self.geom:center(x, y)
				d.touch("down", lx, ly)
				d.frame(1)
				d.touch("up", lx, ly)
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

	-- the bales of the game by the hp left: {n1, n2}, and their total hp
	local function by_hp(self)
		local n, total = { 0, 0 }, 0
		for _, p in ipairs(self.session.game:pieces()) do
			if p.item == "hay" and p.state == "idle" then
				n[p.hp] = n[p.hp] + 1
				total = total + p.hp
			end
		end
		return n, total
	end

	local function specials_on_board(self)
		local n = 0
		for _, p in ipairs(self.session.game:pieces()) do
			if p.kind == "special" and p.state == "idle" then n = n + 1 end
		end
		return n
	end

	local function sfx_count(E, name)
		local n = 0
		for _, m in ipairs(E.msgs) do
			if m.id == "sfx" and m.message.name == name then n = n + 1 end
		end
		return n
	end

	it("draws every bale with the picture of its hp", function()
		with_board({ level = 1, level_text = hay_level() }, function(E, script, self, d)
			d.frame(90)
			assert_same({ count_anim(E, "blockers_hay_1"), count_anim(E, "blockers_hay_2") }, { 2, 2 })
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("a played level: the pictures follow the hp, the bales thud and break, nothing fails", function()
		with_board({ level = 1, level_text = hay_level() }, function(E, script, self, d)
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
					assert_same({ count_anim(E, "blockers_hay_1"), count_anim(E, "blockers_hay_2") }, n)
				end
				if left <= start - 2 then break end
			end
			assert_true(left <= start - 2, "the hint moves took hp off the bales: " .. left .. " of " .. start .. " left")
			assert_true(sfx_count(E, "box_hit") + sfx_count(E, "box_break") >= 1, "the bale sounds")
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("a stick on a full bale: the gift pops out in its cell, is drawn as a special and can be tapped", function()
		-- one bale with a Sub inside and plenty of moves; the stick is free in a test session
		local text = core_helper.level(FULL, { moves = 30, colors = { "red", "yellow", "blue", "purple" },
			goals = { { type = "collect", color = "red", count = 200 } },
			slots = { { at = { 2, 5 }, type = "hay", hp = 1, gift = "sub" } } })
		with_board({ level = 1, level_text = text }, function(E, script, self, d)
			d.frame(90)
			local game = self.session.game
			assert_eq(count_anim(E, "blockers_hay_1"), 1)
			assert_eq(specials_on_board(self), 0)
			local created = sfx_count(E, "special_create")
			-- the core takes the booster directly (the tray and the wallet are another test's business)
			assert_true(game:input({ type = "booster", booster = "stick", at = { 3, 6 } }))
			assert_true(d.settle(), "the board came to rest")
			d.frame(40)
			assert_eq(count_anim(E, "blockers_hay_1"), 0)
			local sub_piece
			for _, p in ipairs(game:pieces()) do
				if p.kind == "special" then sub_piece = p end
			end
			assert_true(sub_piece ~= nil, "the gift is on the board")
			assert_same({ sub_piece.special, sub_piece.x, sub_piece.y, sub_piece.state }, { "sub", 3, 6, "idle" })
			assert_eq(count_anim(E, "specials_sub"), 1)
			assert_true(sfx_count(E, "special_create") > created, "the sound of a new special")
			-- the player taps it: it fires
			local moves = game:status().moves_left
			d.tap(3, 6)
			d.frame(3)
			assert_eq(game:status().moves_left, moves - 1)
			assert_true(d.settle(), "the board came to rest again")
			d.frame(30)
			assert_eq(count_anim(E, "specials_sub"), specials_on_board(self))
			assert_eq(self.errors or 0, 0)
		end)
	end)
end)
