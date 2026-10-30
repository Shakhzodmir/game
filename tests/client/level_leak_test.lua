-- The visual-leak oracle and a bounded run of the leak fuzzer (tests/client/level_leak.lua) on the real
-- screens/level/board.script, headless on the strict Defold stub (tests/client/level_defold_stub.lua).
--
-- The producer's report (decisions.md 8.3, item 8): "after the animations of the boosters a trace of the animation stays
-- on the board like a drawing". These tests are the tool that looks for such traces:
--   * the oracle must SEE each kind of leak (a sprite nobody owns, a pooled sprite on the screen, a lost effect sprite, an
--     effect that still runs at rest, a displaced piece, marks nothing explains, ...): every kind is made on purpose
--     below and the oracle must name it, and the historical failure (finish() of level_vfx taken out) must be caught;
--   * the board must be clean after about forty random scenarios: a board or one of the 100 levels, a frame rhythm
--     (1/60 s ... one frame of 3 s), random swaps, taps on specials, the five in-level boosters, tap-to-skip, the app losing
--     the focus, windows pausing the session, the end of the level (won on the last move, lost, given up, restarted),
--     and the overlay (praise, banners, confetti) is replayed in its own script afterwards;
--   * KNOWN OPEN: a tick effect that starts in the tick the moves window opens stays frozen on the board behind it.
-- Unbounded: lua5.1 tests/client/level_leak_fuzz.lua FIRST COUNT [options]  (its header lists them).

local L = require("tests.client.level_leak")
local core_helper = require("tests.core.helper")
local bus = require("client.bus")

local function pieces_of(B) return B.game():pieces() end

-- a visible sprite that the board knows nothing about
local function stray(B, image, x, y)
	local level_view = require("client.level_view")
	local o = level_view.create("#piece_factory")
	level_view.apply(o, image or "fx_ring", x or 360, y or 640, 0.4, 1, 1, 0, 0, nil, 0.8)
	return o, level_view
end

local function kinds_of(R)
	local set = {}
	for _, l in ipairs(R.leaks) do set[l.kind] = (set[l.kind] or 0) + 1 end
	return set
end

local function frames(B, n, dt)
	for _ = 1, n do B.step(dt or 1 / 60) end
end

describe("the stub's view of the screen", function()
	it("lists the visible sprites of a board at rest: one per piece, each with its image, place, size and alpha", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 90)
			local vis = B.E.visible_sprites()
			assert_eq(#vis, #pieces_of(B))
			local s = vis[1]
			assert_true(s.image:match("^pieces_") ~= nil and s.px > 50 and s.alpha == 1 and s.x > 0 and s.y > 0)
			assert_eq(#B.E.running_particles(), 0)
		end)
	end)

	it("does not list what the board hides: parked, transparent, tiny, cut by the clip line, disabled", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 90)
			local E = B.E
			local n = #E.visible_sprites()
			local o, lv = stray(B)
			assert_eq(#E.visible_sprites(), n + 1)
			lv.hide(o) -- parked at (-10000, -10000)
			assert_eq(#E.visible_sprites(), n)
			lv.apply(o, "fx_ring", 360, 640, 0.4, 1, 1, 0, 0, nil, 0) -- alpha 0
			assert_eq(#E.visible_sprites(), n)
			lv.apply(o, "fx_ring", 360, 640, 0.4, 0.001, 0.001, 0, 0, nil, 1) -- the hide threshold of the scale
			assert_eq(#E.visible_sprites(), n)
			lv.apply(o, "fx_ring", 360, 640, 0.4, 1, 1, 0, 0, 300, 1) -- cut below its lowest edge by the clip line
			assert_eq(#E.visible_sprites(), n)
			lv.apply(o, "fx_ring", 360, 640, 0.4, 1, 1, 0, 0, nil, 1)
			assert_eq(#E.visible_sprites(), n + 1)
			msg.post(msg.url(nil, o.go, "sprite"), "disable") -- a disabled game object draws nothing
			assert_eq(#E.visible_sprites(), n)
			msg.post(o.go, "enable")
			assert_eq(#E.visible_sprites(), n + 1)
		end)
	end)

	it("lists the GUI nodes that draw something and leaves out the ones that do not", function()
		local stub = require("tests.client.level_defold_stub")
		local E = stub.install({})
		local ok, err = pcall(function()
			E.use_gui("/screens/level/level_fx.gui")
			local parent = gui.new_box_node(vmath.vector3(360, 640, 0), vmath.vector3(200, 100, 0))
			local label = gui.new_text_node(vmath.vector3(0, 0, 0), "Hit!")
			gui.set_parent(label, parent)
			gui.new_text_node(vmath.vector3(0, 0, 0), "") -- no text
			gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(0, 0, 0)) -- no size
			assert_eq(#E.visible_gui_nodes(), 2) -- the box and the text
			gui.set_color(label, vmath.vector4(1, 1, 1, 0))
			assert_eq(#E.visible_gui_nodes(), 1, "a transparent text draws nothing")
			gui.set_color(label, vmath.vector4(1, 1, 1, 1))
			gui.set_color(parent, vmath.vector4(1, 1, 1, 0))
			assert_eq(#E.visible_gui_nodes(), 1, "a child takes no alpha from its parent unless it inherits it")
			gui.set_inherit_alpha(label, true)
			assert_eq(#E.visible_gui_nodes(), 0, "with inheritance it goes with the parent")
			gui.set_color(parent, vmath.vector4(1, 1, 1, 1))
			gui.set_enabled(parent, false)
			assert_eq(#E.visible_gui_nodes(), 0, "a disabled parent hides its children")
			gui.set_enabled(parent, true)
			gui.set_scale(label, vmath.vector3(0, 0, 1))
			assert_eq(#E.visible_gui_nodes(), 1, "a text scaled to nothing draws nothing")
		end)
		stub.restore()
		if not ok then error(err, 0) end
	end)

	it("unloads a screen: every object and every particle effect of it is gone", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 30)
			B.self.vfx:play({ { kind = "burst", fx = "pop", x = 200, y = 500, color = "#FF4468", count = 10, at = 0 } })
			frames(B, 2)
			assert_true(#B.E.running_particles() > 0 and #B.E.visible_sprites() > 0)
			B.E.unload()
			assert_eq(#B.E.running_particles(), 0)
			assert_eq(#B.E.visible_sprites(), 0)
			assert_eq(B.E.n_objects, 0)
		end)
	end)
end)

describe("the leak oracle", function()
	it("finds a board at rest clean: every piece drawn once, where it is and as a fresh render draws it", function()
		for _, level in ipairs({ 1, 22, 50 }) do -- plain, wires, noise
			L.with_board({ level = level }, function(B)
				frames(B, 120)
				local R = L.leak_report(B, { rest = true })
				assert_eq(#R.leaks, 0, "level " .. level .. ": " .. L.format(R))
				assert_eq(R.visible, #pieces_of(B) + (level == 22 and B.self.view:stats().wires or 0) + B.self.plates:count())
			end)
		end
	end)

	it("names a sprite that no structure of the board owns (orphan_sprite)", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 90)
			stray(B)
			assert_eq(kinds_of(L.leak_report(B)).orphan_sprite, 1)
		end)
	end)

	it("names a pooled effect sprite that is on the screen (pooled_visible), in the frame it happens", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 90)
			local vfx = B.self.vfx
			local o = vfx:_sprite("glow")
			vfx:_release(o)
			local level_view = require("client.level_view")
			level_view.apply(o, "fx_flash", 300, 600, 0.4, 1, 1, 0, 0, nil, 0.8)
			assert_eq(kinds_of(L.leak_report(B)).pooled_visible, 1)
			local f = L.frame_check(B)
			assert_true(f ~= nil and f[1].kind == "pooled_visible", "the cheap check of every frame sees it too")
		end)
	end)

	it("names an effect sprite that no effect holds and the pool does not either (lost_sprite)", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 90)
			local vfx = B.self.vfx
			local o = vfx:_sprite("piece") -- taken, never attached: what the recount every 30 frames takes back
			local level_view = require("client.level_view")
			level_view.apply(o, "fx_shock", 300, 600, 0.38, 1, 1, 0, 0, nil, 0.8)
			assert_eq(kinds_of(L.leak_report(B)).lost_sprite, 1)
			assert_eq(L.frame_check(B)[1].kind, "lost_sprite")
			-- the recount does take it back, and the report is clean again
			frames(B, 31)
			assert_eq(#L.leak_report(B).leaks, 0)
			assert_true(B.self.vfx:stats().repaired >= 1, "the recount counted it")
		end)
	end)

	it("names an effect that still runs, draws or waits long after the board rested (rest_vfx, rest_particles)", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 90)
			local vfx = B.self.vfx
			vfx:play({
				{ kind = "ring", x = 360, y = 640, size = 300, at = 0, dur = 0.4, color = "#FF4FC8", image = "fx_shock" },
				{ kind = "burst", fx = "pop", x = 200, y = 500, color = "#FF4468", count = 10, at = 0 },
				{ kind = "burst", fx = "pop", x = 300, y = 500, color = "#FF4468", count = 10, at = 1e9 }, -- never due
			})
			frames(B, 2)
			local k = kinds_of(L.leak_report(B, { rest = true }))
			assert_true(k.rest_vfx and k.rest_vfx >= 2, "the ring draws, a command waits")
			assert_eq(k.rest_particles, 1)
			-- without the rest verdict only the structure is asked: an effect that runs is fine while the board moves
			assert_eq(#L.leak_report(B, { rest = false }).leaks, 0)
		end)
	end)

	it("names a piece that is drawn away from its cell or not as a fresh render draws it (piece_displaced, piece_look)", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 120)
			local p = pieces_of(B)[3]
			local o = B.self.view.by_id[p.id]
			local x, y = B.self.geom:center(p.x, p.y)
			local level_view = require("client.level_view")
			level_view.apply(o, "pieces_" .. p.color, x + 9, y, 0.1, 0.6, 0.6, 0, 0, nil, 1) -- 9 px off
			assert_eq(kinds_of(L.leak_report(B)).piece_displaced, 1)
			level_view.apply(o, "pieces_" .. p.color, x, y, 0.1, 0.9, 0.9, 0, 0, nil, 1) -- bigger than it is
			assert_eq(kinds_of(L.leak_report(B)).piece_look, 1)
			level_view.apply(o, "pieces_" .. p.color, x, y, 0.1, B.self.geom.cell / 160, B.self.geom.cell / 160, 0, 0, nil, 1)
			assert_eq(#L.leak_report(B).leaks, 0)
		end)
	end)

	it("names a sprite of a piece the core no longer has, and a piece the board forgot to draw", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 120)
			local view = B.self.view
			local o = stray(B)
			view.by_id[99999] = o
			assert_eq(kinds_of(L.leak_report(B)).stale_piece_sprite, 1)
			view.by_id[99999] = nil
			local p = pieces_of(B)[1]
			require("client.level_view").hide(view.by_id[p.id])
			assert_eq(kinds_of(L.leak_report(B)).missing_piece_sprite, 1)
		end)
	end)

	it("names marks that no selection, hint, target or plate explains (mark_unexplained)", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 120)
			local p = pieces_of(B)[1]
			B.self.input.selected = { id = p.id, x = p.x, y = p.y } -- selected, but the board has not drawn it
			assert_eq(kinds_of(L.leak_report(B)).mark_unexplained, 1)
			frames(B, 2) -- the next frame draws the glow and the ring: explained
			assert_eq(#L.leak_report(B).leaks, 0)
			B.self.input.selected = nil -- let go, but the next frame has not run: the count and the sprites both say so
			assert_true(kinds_of(L.leak_report(B)).mark_unexplained >= 1)
			frames(B, 2)
			assert_eq(#L.leak_report(B).leaks, 0)
		end)
	end)

	it("names a wires overlay that is not the core's (wire_mismatch)", function()
		L.with_board({ level = 22 }, function(B)
			frames(B, 120)
			assert_true(B.self.view:stats().wires > 0, "level 22 has wires")
			require("client.level_view").hide(B.self.view.wires[1].o)
			assert_eq(kinds_of(L.leak_report(B)).wire_mismatch, 1)
		end)
	end)

	it("names the cached list of pieces going stale (stale_piece_list)", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 120)
			B.self.pieces[1] = setmetatable({ x = 99 }, { __index = B.self.pieces[1] })
			assert_eq(kinds_of(L.leak_report(B)).stale_piece_list, 1)
		end)
	end)
end)

-- The failure of the first report, made again on purpose: the effects that follow the ticks of the core freeze when
-- the window of the results stops the session, unless level_vfx lets them run out by themselves (finish()).
describe("the leak oracle against the first failure of the producer's report", function()
	-- scenarios (random boards, the level won, the player taps to skip the concert) that leave commands waiting for a tick
	-- of a session that the results window has stopped, when level_vfx does not run its effects out by itself
	local SEEDS = { 4, 12, 24, 30 }

	local function play_wins(finish_works)
		local leaking = 0
		for _, seed in ipairs(SEEDS) do
			local sc = L.scenario(seed, { end_mode = "win", skippy = 1 })
			local res = L.play(sc, { gui = false, setup = function(B)
				if not finish_works then B.self.vfx.finish = function() end end
			end })
			assert_true(res.error == nil, tostring(res.error))
			if #res.leaks > 0 then leaking = leaking + 1 end
		end
		return leaking
	end

	it("finds nothing after a won level with the results window, and finds the frozen effects without finish()", function()
		assert_eq(play_wins(true), 0, "the board runs its effects out after the win")
		local broken = play_wins(false)
		assert_true(broken >= 2, "with finish() taken out the oracle sees the leftovers in " .. broken .. " of " .. #SEEDS .. " scenarios")
	end)
end)

describe("pausing and resuming", function()
	-- a window (the pause menu, the shop) stops the session: the effects that follow the ticks wait with it and go on
	-- when it closes; nothing of them may be left once it has
	it("freezes the bolts of a Riff behind a window and runs them out after it closes", function()
		local lvl = core_helper.level({ "#######", "#######", "#######", "###R###", "#######", "#######", "#######" }, { moves = 10 })
		for _, dt in ipairs({ 1 / 60, 1 / 10, 3 }) do
			L.with_board({ level = 1, level_text = lvl }, function(B)
				frames(B, 5)
				assert_true(B.self.session:qa("tap", { 4, 4 }).ok)
				B.step(dt)
				B.hud.pause = true
				B.apply_pause()
				for _ = 1, 40 do B.step(dt) end
				assert_true(B.self.session.paused)
				B.hud.pause = false
				B.apply_pause()
				for _ = 1, math.ceil(40 / dt) do B.step(dt) end
				local R
				for _ = 1, 400 do
					if B.game():is_stable() then break end
					B.step(dt)
				end
				for _ = 1, math.ceil(4 / math.min(dt, 0.25)) do B.step(dt) end
				R = L.leak_report(B, { rest = true })
				assert_eq(#R.leaks, 0, "dt " .. dt .. ": " .. L.format(R))
			end)
		end
	end)

	it("freezes everything while the app is away and runs it out when it is back", function()
		local lvl = core_helper.level({ "#######", "#######", "#######", "###S###", "#######", "#######", "#######" }, { moves = 10 })
		L.with_board({ level = 1, level_text = lvl }, function(B)
			frames(B, 5)
			assert_true(B.self.session:qa("tap", { 4, 4 }).ok)
			frames(B, 8)
			bus.publish("app_focus", { focused = false })
			frames(B, 120)
			assert_true(B.self.session.hold)
			bus.publish("app_focus", { focused = true })
			for _ = 1, 600 do
				if B.game():is_stable() then break end
				B.step(1 / 60)
			end
			frames(B, 240)
			local R = L.leak_report(B, { rest = true })
			assert_eq(#R.leaks, 0, L.format(R))
		end)
	end)
end)

-- KNOWN OPEN. The core opens "out of moves" in the very tick the noise grows onto a piece after the last move
-- (noise_spread and state out_of_moves have the same tick); the moves window opens at once and stops the session, so
-- the grey cloud that creeps to the piece (a tick effect, 12 ticks) and the dust waiting for tick +6 stop with it: the
-- cloud sits on the piece, as a picture, for as long as the window is open. When "give up" ends the level, finish() lets
-- them run out; when "+5 moves" is taken, they go on. Set FIXED to true when level_vfx lets such effects run out
-- behind a window (or the window waits for them); then the first test must go and the second one stays.
local FIXED = false

local function noise_board()
	return core_helper.level(core_helper.rows(7, 7, { ["4,4"] = "N" }), { moves = 5,
		colors = { "red", "yellow", "green", "blue" }, goals = { { type = "collect", color = "red", count = 99 } } })
end

local function last_move_with_noise(B)
	frames(B, 3)
	B.game().s.moves_left = 1 -- the move is the last one
	assert_true(B.self.session:command(B.self.session:hint_command()))
	local n = 0
	while B.state() ~= "out_of_moves" and n < 3000 do
		B.step(1 / 60)
		n = n + 1
	end
	assert_eq(B.state(), "out_of_moves")
	assert_eq(B.topics.level_noise, 1, "the noise grew onto a piece with the last move")
	assert_true(B.self.session.paused, "the moves window is open")
end

describe("KNOWN OPEN: the moves window and the effects of its own tick", function()
	if not FIXED then
		it("leaves the noise cloud frozen on the board behind the moves window (delete this test when it is fixed)", function()
			L.with_board({ level = 1, level_text = noise_board() }, function(B)
				last_move_with_noise(B)
				frames(B, 300) -- five seconds of the open window
				local k = kinds_of(L.leak_report(B, { rest = true }))
				assert_true(k.rest_vfx ~= nil, "the cloud and the dust are still there; if not, the bug is fixed: set FIXED")
				local vfx = B.self.vfx
				local kind = vfx.active[1] and vfx.active[1].c.kind
				assert_eq(kind, "creep")
				-- the player gives up: the level is over, finish() lets them run out
				B.hud.moves = false
				B.apply_pause()
				B.link.give_up()
				frames(B, 120)
				assert_eq(#L.leak_report(B, { rest = true }).leaks, 0)
			end)
		end)
	end

	it("leaves nothing of the last move on the board behind the moves window", function()
		if not FIXED then return end
		L.with_board({ level = 1, level_text = noise_board() }, function(B)
			last_move_with_noise(B)
			frames(B, 300)
			local R = L.leak_report(B, { rest = true })
			assert_eq(#R.leaks, 0, L.format(R))
		end)
	end)
end)

-- the scenarios ----------------------------------------------------------------------------------------------------
describe("the leak fuzzer, bounded", function()
	it("plays a scenario as a pure function of its seed", function()
		local a = L.scenario(7, {})
		local b = L.scenario(7, {})
		assert_eq(a.source, b.source)
		assert_eq(a.dt_mode, b.dt_mode)
		assert_eq(a.end_mode, b.end_mode)
		local r1 = L.play(L.scenario(7, {}), { gui = false })
		local r2 = L.play(L.scenario(7, {}), { gui = false })
		assert_eq(#r1.story, #r2.story)
		assert_eq(r1.frames, r2.frames)
		assert_eq(r1.final_state, r2.final_state)
		for i = 1, #r1.story do assert_eq(L.op_text(r1.story[i]), L.op_text(r2.story[i])) end
		assert_eq(L.scenario(7, { source = "combo" }).source, "combo")
		assert_eq(L.scenario(7, { dt_mode = "3000" }).dt_mode, "3000")
		assert_eq(L.scenario(7, { dt_mode = "3000" }).end_mode, a.end_mode, "an option does not change the other choices")
	end)

	it("shrinks a scenario to the ops that matter", function()
		local sc = L.scenario(3, { ops = 10, source = "board", dt_mode = "60" })
		sc.end_mode = "settle"
		L.play(sc, { gui = false }) -- (the ops are drawn when a scenario is played the first time)
		-- the "leak" is a swap on the board: the shrunk story must be that one op
		local small, ok = L.shrink(sc, function(res)
			for _, op in ipairs(res.story) do if op.op == "swap" or op.op == "hint" then return true end end
			return false
		end, { gui = false })
		assert_true(ok)
		assert_true(#small.ops <= 2, "ops left: " .. #small.ops)
	end)

	-- every rhythm of the frames x every kind of board, and the ends of a level
	local function bounded(list)
		for _, c in ipairs(list) do
			it(string.format("leaves nothing behind: seed %d, %s, rhythm %s%s", c.seed, c.source or "any", c.dt_mode or "random",
				c.end_mode and (", " .. c.end_mode) or ""), function()
				local sc = L.scenario(c.seed, c)
				-- (the overlay replay doubles the cost: asked for where a concert plays; the whole screen is asked every 12th frame)
				local res = L.play(sc, { gui = c.gui, board = { deep = 12 } })
				assert_true(res.error == nil, tostring(res.error))
				local text = {}
				for _, l in ipairs(res.leaks) do text[#text + 1] = l.kind .. ": " .. l.text end
				for _, f in ipairs(res.findings) do text[#text + 1] = "frame " .. f.kind .. ": " .. tostring(f.text) end
				assert_eq(#text, 0, "scenario " .. c.seed .. " (" .. sc.source .. ", " .. sc.dt_mode .. ", " .. sc.end_mode .. ") leaks:\n"
					.. table.concat(text, "\n"))
				assert_eq(res.vfx.repaired, 0, "the recount had to take sprites back")
				assert_eq(res.vfx.errors, 0)
			end)
		end
	end

	local list = {}
	local seed = 100
	local LEVELS = { 3, 8, 14, 21, 27, 33, 38 } -- (small, cheap ones: the grid is about the rhythm, not about the content)
	for k, dt in ipairs(L.DT_MODES) do
		for _, source in ipairs({ "board", "level", "combo" }) do
			seed = seed + 1
			list[#list + 1] = { seed = seed, dt_mode = dt, source = source, gui = false, ops = 12, end_mode = "settle",
				rest_checks = k % 3 == 0 and 1 or 0, level = source == "level" and LEVELS[k] or nil }
		end
	end
	-- the concert and its skip, a loss, a given-up level, a continued one, at several rhythms
	for i, end_mode in ipairs({ "win", "win", "win", "win", "give_up", "give_up", "continue", "continue" }) do
		list[#list + 1] = { seed = 200 + i, source = i % 2 == 0 and "combo" or "board", end_mode = end_mode,
			dt_mode = ({ "60", "30", "10", "spike" })[(i - 1) % 4 + 1], skippy = i % 4 == 0 and 0 or 1, blinky = i % 2 == 0 and 1 or 0,
			gui = i <= 4 }
	end
	-- the levels with the things the others do not have: wires, microphones, noise, balloons, the column
	for i, level in ipairs({ 22, 30, 50, 65, 90 }) do
		list[#list + 1] = { seed = 300 + i, source = "level", level = level, end_mode = "win", dt_mode = i == 4 and "spike" or "30",
			gui = i == 3 }
	end
	-- a moves window answered with a Crossfader whose picks the core rejects: the offer comes back (level.gui_script); the
	-- runner once waited for ever for a window that was not there
	list[#list + 1] = { seed = 14173, gui = false }
	bounded(list)
end)

describe("the overlay replay", function()
	it("plays the bus events of a level into the fx script and finds the overlay empty when the level is over", function()
		local events = {
			{ t = 0.0, topic = "level_praise", payload = { word = "hit", index = 2, wave = 5 } },
			{ t = 0.2, topic = "level_special", payload = { special = "sub", combo = "bass_drop", lx = 360, ly = 640 } },
			{ t = 0.5, topic = "level_banner", payload = { key = "hud.shuffle" } },
			{ t = 0.6, topic = "level_flash", payload = { color = "#FFFFFF", alpha = 0.9, dur = 0.5 } },
			{ t = 1.0, topic = "level_state", payload = { state = "won_wait" } },
			{ t = 2.0, topic = "level_state", payload = { state = "concert" } },
			{ t = 6.0, topic = "level_state", payload = { state = "complete" } },
		}
		local g = L.replay_gui(events, {})
		assert_true(g.error == nil, tostring(g.error))
		assert_eq(#g.leaks, 0, g.leaks[1] and g.leaks[1].text or "")
		assert_true(g.frames > 300)
	end)

	it("names a word that is still on the overlay when the level is over and nobody takes it away", function()
		local events = { { t = 0.0, topic = "level_praise", payload = { word = "hit", index = 2, wave = 5 } },
			{ t = 0.1, topic = "level_state", payload = { state = "complete" } } }
		local g = L.replay_gui(events, { tail = 0.2 })
		assert_true(#g.leaks >= 1 and g.leaks[1].kind == "gui_leftover", "a word is on the screen at 0.3 s")
	end)

	it("lets the confetti run until the concert ends, and no longer", function()
		local events = { { t = 0.0, topic = "level_state", payload = { state = "concert" } } }
		assert_eq(#L.replay_gui(events, {}).leaks, 0, "no verdict in the middle of the concert")
		events[2] = { t = 3.0, topic = "level_state", payload = { state = "complete" } }
		assert_eq(#L.replay_gui(events, {}).leaks, 0, "gone a few seconds after complete")
	end)
end)
