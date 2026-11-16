-- The ice (core-rules 10.11) in the client: its two pictures by the hp left, the see-through cube in the draw
-- list, the goal icon and the texts, the crack (jolt, icy sparks, a glassy tick), the melt (the cube swells
-- away, a soft pop), the touch rules, and the board script (screens/level/board.script) on the strict Defold stub.

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
local level_ice = require("client.level_ice")
local level_input = require("client.level_input")
local level_plates = require("client.level_plates")
local level_session = require("client.level_session")
local geom = require("client.level_geom")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local core_helper = require("tests.core.helper")
local H = require("tests.meta.helper")

local DT = 1 / 60
local FULL = { "######", "######", "######", "######", "######", "######" }

-- a 6x6 board with three frozen pieces: solid (2,3), cracked (5,3), cracked (3,5)
local function ice_level(count)
	return core_helper.level(FULL, { moves = 20, goals = { { type = "ice", count = count or 3 } },
		overlay = { { at = { 1, 2 }, type = "ice", hp = 2 }, { at = { 4, 2 }, type = "ice", hp = 1 },
			{ at = { 2, 4 }, type = "ice", hp = 1 } } })
end

-- a fixed 9x9 board: the swipe (6,8) -> (6,9) makes the green line (4,9) (5,9) (6,9); its neighbours (3,9)
-- (cracked ice) and (7,9) (solid ice) are frozen, and so is (1,1), far away
local function fixed_level()
	return core_helper.level({
		"yrgbpyrgb", "rgbpyrgby", "gbpyrgbpy", "bpyrgbpyr", "pyrgbypyr", "yrgbpyrgb", "rgbpyrgby", "gbpyrgbpy", "bpyggbpyr",
	}, { moves = 10, goals = { { type = "ice", count = 3 } },
		overlay = { { at = { 2, 8 }, type = "ice", hp = 1 }, { at = { 6, 8 }, type = "ice", hp = 2 },
			{ at = { 0, 0 }, type = "ice", hp = 2 } } })
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

describe("the ice in the client", function()
	it("has two pictures in the game atlas, by the hp left, and the solid one in the meta atlas (the goal icon)", function()
		for hp = 1, 2 do
			local img = assets.images["blockers/ice_" .. hp]
			assert_true(img ~= nil, "blockers/ice_" .. hp .. " is in the index")
			assert_same({ img.atlas, img.anim, img.w, img.h }, { "game", "blockers_ice_" .. hp, 160, 160 })
		end
		assert_same(assets.images["blockers/ice_2"].also, { "meta" })
		assert_eq(assets.images["blockers/ice_1"].also, nil)
		assert_same({ level_ice.image(2), level_ice.image(1) }, { "blockers/ice_2", "blockers/ice_1" })
		-- out of range: the nearest picture, never a missing one
		assert_same({ level_ice.anim(0), level_ice.anim(7), level_ice.anim(nil) },
			{ "blockers_ice_1", "blockers_ice_2", "blockers_ice_1" })
		assert_eq(level_ice.GOAL_ICON, "blockers/ice_2")
		assert_true(level_ice.ALPHA > 0.5 and level_ice.ALPHA < 1, "see-through, but there")
	end)

	it("the goal `ice` is drawn like the others: an icon, a counter and a name", function()
		assert_same(levels.goals(ice_level()), { { kind = "ice", image = "blockers/ice_2", count = 3, label = { key = "blocker.ice" } } })
	end)

	it("has its name, its description, its lesson and its refusal line in three languages; the lesson fits the bubble", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			i18n.set_language(lang)
			for _, key in ipairs({ "blocker.ice", "blocker.ice_desc", "tutorial.ice", "level.fixed_frozen" }) do
				local text = i18n.t(key)
				assert_true(type(text) == "string" and text ~= "" and text ~= key, lang .. " " .. key)
			end
			local lesson = i18n.t("tutorial.ice")
			assert_true(bubble_lines(lesson, lang) <= 2, lang .. ": the lesson takes more than two lines")
			assert_true(#require("tests.client.town_defold_stub").utf8_codepoints(lesson) <= 64, lang)
		end
		i18n.set_language("ru")
		assert_eq(i18n.t("blocker.ice"), "Лёд")
		assert_eq(i18n.t("blocker.ice_desc"), "Фишка во льду не двигается и не собирается в ряд. Собери ряд рядом, и лёд растает.")
		assert_eq(i18n.t("tutorial.ice"), "Лёд тает от рядов по соседству!")
		i18n.set_language("en")
		assert_eq(i18n.t("blocker.ice"), "Ice")
	end)

	it("the draw list has the cube right after its piece: same place, a hair above, see-through, image by hp", function()
		local A = level_anim.new({ geom = board_geom() })
		local pieces = {
			{ id = 1, x = 2, y = 2, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0, ice = 2 },
			{ id = 2, x = 3, y = 2, kind = "regular", color = "blue", state = "idle", offx = 0, offy = 0 },
			{ id = 3, x = 4, y = 2, kind = "regular", color = "green", state = "idle", offx = 0, offy = 0, ice = 1 },
		}
		local list = A:frame(pieces, 0, 0)
		assert_eq(#list, 5)
		local p, c = list[1], list[2]
		assert_same({ p.id, p.image }, { 1, "pieces_red" }, "the piece keeps its own picture: the colour shows")
		assert_same({ c.id, c.image }, { level_anim.ICE_ID + 1, "blockers_ice_2" })
		assert_same({ c.x, c.y, c.sx, c.sy, c.scale }, { p.x, p.y, p.sx, p.sy, p.scale })
		assert_near(c.alpha, p.alpha * level_ice.ALPHA, 1e-9)
		assert_near(c.z - p.z, level_anim.Z_ICE, 1e-9)
		assert_eq(list[3].id, 2)
		assert_same({ list[5].id, list[5].image }, { level_anim.ICE_ID + 3, "blockers_ice_1" })
		assert_true(level_anim.ICE_ID ~= level_anim.CHAIN_ID)
		-- a crack: the cube jolts and flashes (the piece does not), shows the cracked picture, then calms down
		A:event({ type = "hit", layer = "ice", id = 1, x = 2, y = 2, hp = 1, t = 1 }, 1)
		pieces[1].ice = 1
		list = A:frame(pieces, 1, 1.05)
		assert_eq(list[2].image, "blockers_ice_1")
		assert_true(list[2].sx > list[1].sx and list[2].flash > list[1].flash and list[2].rot ~= 0)
		list = A:frame(pieces, 1, 2)
		assert_same({ list[2].sx, list[2].rot, list[2].flash }, { list[1].sx, 0, list[1].flash })
		-- reduced motion: no rotation
		local R = level_anim.new({ geom = board_geom(), reduced = true })
		R:frame(pieces, 0, 0)
		R:event({ type = "hit", layer = "ice", id = 1, x = 2, y = 2, hp = 1, t = 1 }, 1)
		assert_eq(R:frame(pieces, 1, 1.05)[2].rot, 0)
		-- the ice is gone: so is its entry; the piece pops
		A:event({ type = "thawed", id = 1, x = 2, y = 2, t = 2 }, 2)
		pieces[1].ice = nil
		list = A:frame(pieces, 2, 2.1)
		assert_eq(#list, 4)
		assert_true(list[1].sx > 1, "the freed piece pops")
	end)

	it("cannot be picked or swiped; the swipe goes to the core, which refuses it", function()
		local objs = { ["2,2"] = { id = 1, kind = "regular", state = "idle", frozen = true },
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
		assert_eq(level_plates.kind({ kind = "regular", ice = 1 }, false), "frozen")
		assert_eq(level_plates.kind({ kind = "regular" }, false), nil)
		assert_eq(level_plates.kind({ kind = "regular", ice = 2, veiled = true }, false), "veiled")
		assert_eq(level_plates.TOAST.frozen, "level.fixed_frozen")
		local P = level_plates.new()
		local list = {}
		local n = P:fill(list, 0, { { id = 1, x = 2, y = 2, kind = "regular", state = "idle", ice = 2 } }, nil, board_geom(), nil, 1, 0, 0)
		assert_eq(n, 0)
	end)

	it("a crack throws icy sparks and ticks; the melt lets the cube swell away with a soft pop", function()
		local E = level_effects.new({ geom = board_geom() })
		E:event({ type = "hit", t = 3, layer = "ice", id = 1, x = 2, y = 6, hp = 1 })
		local q = E:drain()
		assert_eq(#q, 1)
		assert_same({ q[1].kind, q[1].color }, { "burst", level_ice.COLOR })
		E:event({ type = "thawed", t = 3, id = 1, x = 2, y = 6 })
		local ghost
		for _, c in ipairs(E:drain()) do
			if c.kind == "ghost" then ghost = c end
		end
		assert_true(ghost ~= nil, "the cube itself fades away")
		assert_same({ ghost.image, ghost.a1, ghost.s1, ghost.dur }, { "blockers_ice_1", 0, level_ice.MELT_SCALE, level_ice.MELT_TIME })
		local a, calls = fake_audio()
		local clock = 0
		local la = level_audio.new({ audio = a, now = function() return clock end })
		la:events({ { type = "hit", layer = "ice", id = 4, x = 2, y = 6, hp = 1 } })
		clock = 1
		la:events({ { type = "thawed", id = 4, x = 2, y = 6 } })
		assert_same({ calls[1][1], calls[2][1] }, { level_ice.CRACK_SFX, level_ice.MELT_SFX })
		assert_true(calls[1][2].speed > 1, "a high, glassy tick")
		-- both are sounds the game already has (no new audio for the ice)
		assert_eq(level_ice.CRACK_SFX, level_audio.BLOCKER_HIT.record_box)
		assert_eq(level_ice.MELT_SFX, level_audio.BLOCKER_BREAK.balloon)
	end)

	it("a session plays an ice level: pieces() carries the ice, the hint moves melt it", function()
		local s = assert(level_session.new({ params = { level = 221, level_text = ice_level() } }))
		local game = s.game
		local hp = 0
		for _, p in ipairs(game:pieces()) do hp = hp + (p.ice or 0) end
		assert_eq(hp, 4)
		local thawed = 0
		for _ = 1, 60 do
			game:run_to_rest()
			for _, e in ipairs(game:drain_events()) do
				if e.type == "thawed" then thawed = thawed + 1 end
			end
			if game:status().state ~= "playing" then break end
			local cmd = s:hint_command()
			if not cmd then break end
			if game:status().moves_left == 0 then break end
			assert_true(game:input(cmd))
		end
		assert_true(thawed >= 1, "the hint melts ice")
	end)
end)

describe("screens/level/board.script with ice (core-rules 10.11)", function()
	-- Runs fn(env, script, self, drive) with a board on display; always restores the globals.
	local function with_board(params, fn)
		local E = stub.install({})
		local ok, err = pcall(function()
			boot_app()
			level_plates.reset()
			app.params = params
			local sub = bus.subscribe("*", "ice_test")
			local script = stub.load_script("screens/level/board.script")
			local self = {}
			script.init(self)
			assert_true(not self.failed, "the board failed to start")
			self.strict = true -- cosmetic errors are not swallowed in tests
			local d = { events = {} }
			function d.frame(n)
				for _ = 1, n or 1 do
					E.advance(DT)
					script.update(self, DT)
				end
				sub:drain(function(topic, payload) d.events[#d.events + 1] = { topic = topic, payload = payload } end)
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

	local function sfx_count(E, name)
		local n = 0
		for _, m in ipairs(E.msgs) do
			if m.id == "sfx" and m.message.name == name then n = n + 1 end
		end
		return n
	end

	local function toast_keys(E)
		local list = {}
		for _, m in ipairs(E.msgs) do
			if m.id == "toast" then
				local t = app.claim(m.message.ticket)
				list[#list + 1] = t and t.key or "?"
			end
		end
		return list
	end

	it("draws a cube over each frozen piece, by its strength, where the piece is, and no plate", function()
		with_board({ level = 1, level_text = fixed_level() }, function(E, script, self, d)
			d.frame(90)
			assert_eq(count_anim(E, "blockers_ice_2"), 2)
			assert_eq(count_anim(E, "blockers_ice_1"), 1)
			assert_eq(count_anim(E, "board_plate"), 0, "the cube says it: no plate")
			for _, at in ipairs({ { 1, 1 }, { 3, 9 }, { 7, 9 } }) do
				local p = self.cellmap[(at[2] - 1) * self.W + at[1]]
				assert_true(p.ice ~= nil)
				local piece, cube = self.view.by_id[p.id], self.view.by_id[level_anim.ICE_ID + p.id]
				assert_true(piece ~= nil and cube ~= nil, "a sprite for the piece and one for its ice")
				assert_same({ cube.x, cube.y }, { piece.x, piece.y })
				assert_true(cube.z > piece.z, "the ice lies over its piece")
			end
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("a drag of a frozen piece, or onto it, is refused like a failed swap: it shakes, bounces and says why once", function()
		with_board({ level = 1, level_text = fixed_level() }, function(E, script, self, d)
			d.frame(90)
			d.swipe(1, 1, 2, 1)
			d.frame(5)
			assert_eq(self.session.game:status().moves_left, 10)
			assert_eq(sfx_count(E, "swap_fail"), 1)
			assert_same(toast_keys(E), { "level.fixed_frozen" })
			d.frame(30)
			d.swipe(2, 1, 1, 1)
			d.frame(5)
			assert_eq(self.session.game:status().moves_left, 10)
			assert_eq(sfx_count(E, "swap_fail"), 2)
			assert_eq(#toast_keys(E), 1, "the hint of a kind comes once: no second toast")
			assert_true(d.settle())
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("a match beside the ice melts it: the piece stays, the cube goes, the HUD is told, the sounds play", function()
		with_board({ level = 1, level_text = fixed_level() }, function(E, script, self, d)
			d.frame(90)
			local thin = self.cellmap[(9 - 1) * self.W + 3].id
			local thick = self.cellmap[(9 - 1) * self.W + 7].id
			d.swipe(6, 8, 6, 9)
			d.frame(1)
			assert_eq(self.session.game:status().moves_left, 9)
			assert_true(d.settle())
			d.frame(60)
			local goal
			for _, e in ipairs(d.events) do
				if e.topic == "level_goal" then goal = goal or e.payload end
			end
			assert_true(goal ~= nil, "the HUD is told")
			assert_same({ goal.index, goal.kind, goal.x, goal.y }, { 1, "ice", 3, 9 })
			assert_true(goal.left <= 2)
			assert_true(goal.lx ~= nil and goal.ly ~= nil, "where to fly the icon from")
			assert_eq(self.view.by_id[level_anim.ICE_ID + thin], nil, "the sprite of the melted cube went back to the pool")
			assert_true(sfx_count(E, level_ice.MELT_SFX) >= 1, "the melt pops")
			assert_true(sfx_count(E, level_ice.CRACK_SFX) >= 1, "the crack ticks")
			-- the thick cube lost a layer at least; if it is still frozen it shows the cracked picture
			for _, p in ipairs(self.session.game:pieces()) do
				if p.id == thick and p.ice then
					assert_eq(p.ice, 1)
					assert_true(self.view.by_id[level_anim.ICE_ID + thick] ~= nil, "its cube is still drawn")
					assert_true(count_anim(E, "blockers_ice_1") >= 1, "with the cracked picture")
				end
			end
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("a played level: the hint moves melt the ice to the win, nothing fails", function()
		with_board({ level = 1, level_text = ice_level() }, function(E, script, self, d)
			d.frame(90)
			local function frozen()
				local n = 0
				for _, p in ipairs(self.session.game:pieces()) do
					if p.ice then n = n + 1 end
				end
				return n
			end
			assert_eq(frozen(), 3)
			for _ = 1, 20 do
				if self.session.game:status().state ~= "playing" then break end
				local cmd = self.session:hint_command()
				if not cmd or cmd.type ~= "swap" then break end
				d.swipe(cmd.from[1], cmd.from[2], cmd.to[1], cmd.to[2])
				assert_true(d.settle(), "the board came to rest")
				d.frame(30)
				if self.session.game:status().state == "playing" then
					assert_eq(count_anim(E, "blockers_ice_1") + count_anim(E, "blockers_ice_2"), frozen())
				end
				if frozen() == 0 then break end
			end
			assert_true(frozen() <= 1, "the hint moves melted the ice: " .. frozen() .. " of 3 left")
			assert_eq(self.errors or 0, 0)
		end)
	end)
end)
