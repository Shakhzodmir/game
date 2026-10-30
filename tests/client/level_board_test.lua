-- screens/level/board.script and its Defold glue (client/level_view.lua,
-- client/level_vfx.lua), run headless on the strict Defold stub of
-- tests/client/level_defold_stub.lua: the real script, a real core game,
-- real touches through on_input. Guards typos in the Defold-only code, the
-- engine limits of game.project and the per-frame cost of the board.

local stub = require("tests.client.level_defold_stub")
local app = require("client.app")
local bus = require("client.bus")
local layout = require("client.layout")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local H = require("tests.meta.helper")
local core_helper = require("tests.core.helper")

local DT = 1 / 60

local function boot_app()
	analytics.init({ strict = true })
	app.init({
		districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
		now = H.T0, clock = function() return H.T0 end, sys_language = "en",
	})
end

-- Runs fn(env, script, self, drive) with a board on display; always restores the globals.
local function with_board(params, fn, opts)
	opts = opts or {}
	local E = stub.install({ window = opts.window })
	local ok, err = pcall(function()
		boot_app()
		app.params = params
		local sub = bus.subscribe("*", "board_test")
		local script = stub.load_script("screens/level/board.script")
		local self = {}
		script.init(self)
		assert_true(not self.failed, "the board failed to start")
		self.strict = true -- cosmetic errors are not swallowed in tests
		local d = { events = {}, topics = {} }
		function d.frame(n)
			for _ = 1, n or 1 do
				E.advance(DT)
				script.update(self, DT)
			end
			sub:drain(function(topic, payload)
				d.events[#d.events + 1] = { topic = topic, payload = payload }
				d.topics[topic] = (d.topics[topic] or 0) + 1
			end)
		end
		-- a touch at logical coordinates: "down", "move", "up"
		function d.touch(kind, lx, ly)
			local f = layout.fit(E.window.w, E.window.h)
			local sx, sy = layout.logical_to_screen(f, lx, ly)
			local action = { screen_x = sx, screen_y = sy, x = sx, y = sy, pressed = kind == "down", released = kind == "up" }
			return script.on_input(self, hash("touch"), action)
		end
		function d.cell_xy(x, y)
			return self.geom:center(x, y)
		end
		function d.tap(x, y)
			local lx, ly = self.geom:center(x, y)
			d.touch("down", lx, ly)
			d.frame(1)
			d.touch("up", lx, ly)
			d.frame(1)
		end
		-- a swipe from cell a to the neighbour b
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

local function first_level()
	return { level = 1 }
end

describe("screens/level/board.script (headless)", function()
	it("starts level 1: one sprite per object, the HUD is told, the music and the link are set", function()
		with_board(first_level(), function(E, script, self, d)
			d.frame(3)
			assert_eq(self.W, 7)
			local pieces = self.session.game:pieces()
			local drawn = 0
			for _, o in ipairs(E.by_factory("piece_factory")) do
				if E.visible(o) then drawn = drawn + 1 end
			end
			assert_eq(drawn, #pieces)
			assert_true(d.topics.level_ready == 1)
			local ready
			for _, e in ipairs(d.events) do if e.topic == "level_ready" then ready = e.payload end end
			assert_eq(ready.W, 7)
			assert_true(ready.rect and ready.rect.cell > 0)
			local link = require("client.level_link")
			assert_true(link.active())
		end)
		assert_false(require("client.level_link").active()) -- final() detached the board
	end)

	it("plays a swipe through on_input and lets the cascade settle without a single engine error", function()
		with_board(first_level(), function(E, script, self, d)
			d.frame(2)
			local cmd = self.session:hint_command()
			assert_eq(cmd.type, "swap")
			d.swipe(cmd.from[1], cmd.from[2], cmd.to[1], cmd.to[2])
			d.frame(1)
			assert_eq(self.session.game:status().moves_left, 19) -- level 1 has 20 moves
			assert_true(d.settle())
			assert_true(d.topics.level_moves >= 1)
			assert_true(d.topics.level_score >= 1)
		end)
	end)
end)

-- a 9x9 board with two Disco balls side by side: swapping them is the Grand finale
local function finale_level()
	return core_helper.level({
		"yrgbpyrgb",
		"rgbpyrgby",
		"gbpyrgbpy",
		"bpyrgbpyr",
		"pyrgDDpyr",
		"yrgbpyrgb",
		"rgbpyrgby",
		"gbpyrgbpy",
		"bpyrgbpyr",
	}, { moves = 10 })
end

describe("screens/level/board.script engine limits", function()
	it("survives a Grand finale on a 9x9 board inside the limits of game.project", function()
		with_board({ level = 1, level_text = finale_level() }, function(E, script, self, d)
			d.frame(3)
			assert_true(self.session.game:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }))
			assert_true(d.settle(1200))
			local lim = E.limits
			assert_true(E.peak.particlefx <= lim.particlefx, "particlefx components " .. E.peak.particlefx)
			assert_true(E.peak.sprites <= lim.sprites, "sprites " .. E.peak.sprites)
			assert_true(E.peak.objects <= lim.max_instances, "game objects " .. E.peak.objects)
			assert_true(E.peak_particles <= 300, "live particles " .. E.peak_particles)
			assert_true(self.vfx:stats().played > 20)
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("pools its sprites: a second finale-sized event creates no new objects", function()
		with_board({ level = 1, level_text = finale_level() }, function(E, script, self, d)
			d.frame(3)
			assert_true(self.session.game:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }))
			assert_true(d.settle(1200))
			local made = E.counts.factory_create
			-- the same board, the same effects again: the pools are warm
			for _ = 1, 30 do d.frame(1) end
			assert_eq(E.counts.factory_create, made)
		end)
	end)
end)

-- The producer's report: a Disco ball swapped with a Subwoofer (every piece of the commonest colour turns into a
-- Subwoofer and each fires a shock wave), as the move that wins the level: "after the burst such an effect
-- stays". The same screen, played through the real script, headless: nothing of the show may be left on the
-- board once the concert is over, whether the player watched it or tapped "tap to skip" on the way.
describe("screens/level/board.script after the Disco ball + Subwoofers combo", function()
	local function combo_level(id)
		local lvl = core_helper.level({
			"#######", "#######", "#######", "#######", "###SD##", "#######", "#######", "#######",
		}, { moves = 10, colors = { "yellow", "green", "blue", "purple" },
			goals = { { type = "collect", color = "yellow", count = 4 } } })
		lvl.id = id
		return lvl
	end

	-- what the effects draw on screen: the fx_ images (pieces, specials and blockers have their own)
	local function effects_on_screen(E)
		local list = {}
		for _, s in ipairs(E.snapshot().sprites) do
			if string.sub(s.image, 1, 3) == "fx_" then list[#list + 1] = string.format("%s a=%.2f", s.image, s.a) end
		end
		return list
	end

	-- skip_at: the frame (counted from the swap) from which the player taps the hint; nil = watches it all
	local function play(id, skip_at)
		with_board({ level = id, level_text = combo_level(id) }, function(E, script, self, d)
			local link = require("client.level_link")
			d.frame(3)
			local game = self.session.game
			game.s.moves_left = 1 -- the combo is the last move
			assert_true(game:input({ type = "swap", from = { 4, 5 }, to = { 5, 5 } }))
			local done_at, states = nil, {}
			for f = 1, 60 * 30 do
				d.frame(1)
				local st = game:status().state
				if states[#states] ~= st then states[#states + 1] = st end
				if skip_at and f >= skip_at and (st == "won_wait" or st == "concert") and game.s.timing ~= 2 and f % 4 == 0 then
					d.tap(1, 1) -- the first tap after the win is swallowed (SKIP_GUARD): the player taps again
				end
				if st == "complete" and not done_at then
					done_at = f
					link.pause(true) -- the result window opens at once and stops the session (screens/level/level.gui_script)
				end
				if done_at and f >= done_at + 60 * 4 then break end
			end
			assert_true(done_at ~= nil, "the level ended (" .. table.concat(states, ">") .. ")")
			assert_true(self.session.paused)
			local label = "skip " .. tostring(skip_at) .. ": "
			assert_eq(self.vfx:stats().active, 0, label .. "effects still running: " .. self.vfx:stats().active)
			assert_eq(self.vfx:stats().pending, 0, label .. "effects still waiting for their tick")
			local left = effects_on_screen(E)
			assert_eq(#left, 0, label .. "effect sprites left on the board: " .. table.concat(left, ", "))
			assert_eq(self.errors or 0, 0)
		end)
	end

	it("leaves nothing on the board after the concert", function()
		play(901, nil)
	end)

	for _, skip_at in ipairs({ 45, 70, 100, 140 }) do
		it("leaves nothing on the board when the player taps to skip " .. skip_at .. " frames into it", function()
			play(902, skip_at)
		end)
	end
end)

describe("screens/level/board.script session", function()
	it("stands still while the app is in the background and keeps a window pause", function()
		with_board(first_level(), function(E, script, self, d)
			local link = require("client.level_link")
			d.frame(2)
			bus.publish("app_focus", { focused = false })
			d.frame(1)
			assert_true(self.session.hold)
			local t0 = self.session.tick
			assert_true(self.session.game:input({ type = "swap", from = self.session:hint_command().from, to = self.session:hint_command().to }))
			d.frame(30)
			assert_eq(self.session.tick, t0) -- no ticks while away
			bus.publish("app_focus", { focused = true })
			d.frame(5)
			assert_false(self.session.hold)
			assert_true(self.session.tick > t0)
			-- a window opened the pause: regaining the focus must not undo it
			link.pause(true)
			bus.publish("app_focus", { focused = false })
			d.frame(1)
			bus.publish("app_focus", { focused = true })
			d.frame(1)
			assert_true(self.session.paused)
			local t1 = self.session.tick
			d.frame(10)
			assert_eq(self.session.tick, t1)
			link.pause(false)
			d.frame(10)
			assert_true(self.session.tick > t1)
		end)
	end)

	it("ignores touches while paused or held", function()
		with_board(first_level(), function(E, script, self, d)
			local link = require("client.level_link")
			d.frame(2)
			local cmd = self.session:hint_command()
			link.pause(true)
			d.swipe(cmd.from[1], cmd.from[2], cmd.to[1], cmd.to[2])
			d.frame(2)
			assert_eq(self.session.game:status().moves_left, 20)
			link.pause(false)
			d.swipe(cmd.from[1], cmd.from[2], cmd.to[1], cmd.to[2])
			d.frame(2)
			assert_eq(self.session.game:status().moves_left, 19)
		end)
	end)

	it("takes a level through the win, the final concert and the result with QA autoplay", function()
		with_board(first_level(), function(E, script, self, d)
			local qa = require("client.qa_bridge")
			d.frame(2)
			local r = qa.execute("win")
			assert_true(r.ok, tostring(r.error))
			local concert, done = false, false
			for _ = 1, 9000 do
				d.frame(1)
				local st = self.session.game:status().state
				if st == "concert" then concert = true end
				if st == "complete" or st == "lost" then done = true break end
			end
			assert_true(done, "the level ended")
			assert_true(concert or self.session.game:status().state == "lost")
			assert_eq(self.session.game:status().state, "complete")
			d.frame(2)
			assert_eq(d.topics.level_result, 1)
			assert_true(d.topics.level_state >= 3) -- won_wait, concert, complete
			assert_true(d.topics.level_goal >= 1)
			assert_eq(self.errors or 0, 0)
		end)
	end)

	it("lets a tap skip the final concert, but not the tap that made the last move", function()
		with_board(first_level(), function(E, script, self, d)
			local qa = require("client.qa_bridge")
			d.frame(2)
			qa.execute("win")
			local guard_seen = false
			for _ = 1, 9000 do
				d.frame(1)
				local st = self.session.game:status().state
				if st == "won_wait" or st == "concert" then
					-- the first tap right after the win is swallowed
					local lx, ly = self.geom:center(3, 3)
					d.touch("down", lx, ly)
					guard_seen = true
					break
				end
			end
			assert_true(guard_seen)
			d.touch("up", 0, 0)
			assert_false(self.session.game:status().state == "complete")
			for _ = 1, 40 do d.frame(1) end -- 0.67 s later
			local lx, ly = self.geom:center(3, 3)
			assert_eq(self.session.game:status().state, "concert") -- level 1's concert is long enough
			d.touch("down", lx, ly)
			d.touch("up", lx, ly)
			d.frame(5)
			assert_true(self.session.game.s.timing == 2, "turbo after the skip")
			for _ = 1, 600 do
				d.frame(1)
				if self.session.game:status().state == "complete" then break end
			end
			assert_eq(self.session.game:status().state, "complete")
		end)
	end)

	it("costs the engine nothing while the board is at rest", function()
		with_board(first_level(), function(E, script, self, d)
			d.frame(60) -- the pieces bloom in during the first 0.7 s
			E.reset_counts()
			d.frame(120) -- 2 s: no hint yet (5 s), no effects, nothing moves
			for name, n in pairs(E.counts) do -- order-independent
				assert_true(false, "an idle frame called the engine: " .. name .. " x" .. n)
			end
		end)
	end)

	it("builds the list of pieces only when the board can have changed, and it always equals the core's", function()
		local FIELDS = { "id", "x", "y", "kind", "state", "offx", "offy", "hidden", "pinned", "color", "special", "axis", "item", "hp" }
		local function same(a, b)
			if #a ~= #b then return false, "count " .. #a .. " vs " .. #b end
			for i = 1, #a do
				for _, k in ipairs(FIELDS) do
					if a[i][k] ~= b[i][k] then
						return false, "piece " .. b[i].id .. " " .. k .. ": " .. tostring(a[i][k]) .. " vs " .. tostring(b[i][k])
					end
				end
			end
			return true
		end
		-- levels with wires, microphones, noise, balloons: their pieces change by hits and growth, not only by motion
		for _, level in ipairs({ 1, 22, 30, 50, 65 }) do
			with_board({ level = level }, function(E, script, self, d)
				d.frame(60)
				local reused, built = 0, 0
				for round = 1, 5 do
					self.session:autoplay(1, {}) -- one move by itself, then the board rests for two seconds
					for i = 1, 60 * 6 do
						d.frame(1)
						local ok, why = same(self.pieces, self.session.game:pieces())
						assert_true(ok, "level " .. level .. " round " .. round .. " frame " .. i .. ": " .. tostring(why))
						if self.pieces_age > 0 then reused = reused + 1 else built = built + 1 end
					end
				end
				assert_true(reused > built * 2, "level " .. level .. ": the list is built " .. built .. " times, reused " .. reused)
				assert_eq(self.errors or 0, 0)
			end)
		end
	end)

	it("keeps up a full-length level with the same list as the core's through the win, the finale and the result", function()
		with_board(first_level(), function(E, script, self, d)
			local qa = require("client.qa_bridge")
			d.frame(2)
			assert_true(qa.execute("win").ok)
			for i = 1, 9000 do
				d.frame(1)
				local game = self.session.game
				local a, b = self.pieces, game:pieces()
				assert_eq(#a, #b, "frame " .. i)
				for k = 1, #a do
					assert_true(a[k].id == b[k].id and a[k].x == b[k].x and a[k].y == b[k].y and a[k].state == b[k].state
						and a[k].offx == b[k].offx and a[k].offy == b[k].offy and a[k].hidden == b[k].hidden
						and a[k].special == b[k].special and a[k].pinned == b[k].pinned, "frame " .. i .. " piece " .. b[k].id)
				end
				local st = game:status().state
				if st == "complete" or st == "lost" then break end
			end
			assert_eq(self.session.game:status().state, "complete")
		end)
	end)

	it("makes next to no garbage while the board is at rest: the list is built once a second at most", function()
		with_board(first_level(), function(E, script, self, d)
			d.frame(60)
			local game = self.session.game
			local builds = 0
			local pieces = game.pieces
			game.pieces = function(g) builds = builds + 1 return pieces(g) end
			collectgarbage()
			collectgarbage()
			-- the collector is stopped and the LuaJIT compiler off while measuring (its trace recorder allocates)
			local jit_was_on = jit and jit.status and jit.status()
			if jit_was_on then jit.off() end
			collectgarbage("stop")
			local before = collectgarbage("count")
			d.frame(240) -- 4 s: no hint yet (5 s), nothing moves
			local grown = collectgarbage("count") - before
			collectgarbage("restart")
			if jit_was_on then jit.on() end
			game.pieces = nil
			-- a build is 35-70 KB of tables; every frame it was 9 MB here (the rest is the stub's own bookkeeping)
			assert_true(builds <= 5, "the list was built " .. builds .. " times in 240 frames")
			assert_true(grown < 1500, "an idle board allocates " .. math.floor(grown) .. " KB in 240 frames")
		end)
	end)

	it("follows the window: another size rebuilds the layout and the pieces move with it", function()
		with_board(first_level(), function(E, script, self, d)
			d.frame(3)
			local old = self.geom.cell
			E.window.w, E.window.h = 540, 960
			d.frame(2)
			assert_eq(self.ww, 540)
			assert_eq(self.geom.cell, old) -- the logical layout does not change with the window
			E.window.w, E.window.h = 1280, 720
			d.frame(2)
			assert_eq(self.wh, 720)
			local sx, sy = self.geom:center(3, 3)
			local drawn = false
			for _, o in ipairs(E.by_factory("piece_factory")) do
				if math.abs(o.pos.x - sx) < 1 and math.abs(o.pos.y - sy) < 1 then drawn = true end
			end
			assert_true(drawn, "a piece sits on cell 3,3")
		end)
	end)
end)

-- a 7x7 board with a Riff in the middle (random fill around it)
local function riff_level()
	return core_helper.level({ "#######", "#######", "#######", "###R###", "#######", "#######", "#######" }, { moves = 10 })
end

describe("screens/level/board.script input", function()
	it("taps a special to fire it in swipe mode, selects and swaps neighbours", function()
		with_board({ level = 1, level_text = riff_level() }, function(E, script, self, d)
			d.frame(3)
			-- a tap on the Riff: it fires (a move is spent)
			d.tap(4, 4)
			d.frame(1)
			assert_eq(self.session.game:status().moves_left, 9)
			assert_true(d.settle(900))
			-- a tap on a piece selects it; a tap on its neighbour swaps them when that makes a match
			local cmd = self.session:hint_command()
			assert_eq(cmd.type, "swap")
			local moves = self.session.game:status().moves_left
			d.tap(cmd.from[1], cmd.from[2])
			assert_true(self.input.selected ~= nil)
			assert_eq(self.input.selected.x, cmd.from[1])
			d.tap(cmd.to[1], cmd.to[2])
			assert_eq(self.input.selected, nil)
			assert_eq(self.session.game:status().moves_left, moves - 1)
		end)
	end)

	it("needs two taps on a special in tap-tap mode", function()
		with_board({ level = 1, level_text = riff_level() }, function(E, script, self, d)
			app.set_setting("input_mode", "taptap")
			d.frame(3)
			assert_eq(self.input.mode, "taptap")
			d.tap(4, 4)
			assert_eq(self.session.game:status().moves_left, 10) -- selected, not fired
			assert_eq(self.input.selected.id ~= nil, true)
			d.tap(4, 4)
			d.frame(1)
			assert_eq(self.session.game:status().moves_left, 9)
			app.set_setting("input_mode", "swipe")
		end)
	end)

	it("tells the HUD what a booster target did", function()
		with_board(first_level(), function(E, script, self, d)
			local link = require("client.level_link")
			d.frame(3)
			assert_true(link.booster("stick"))
			d.frame(1)
			assert_eq(link.targeting(), "stick")
			d.tap(3, 3)
			d.frame(2)
			assert_eq(link.targeting(), nil)
			local used, targeted = 0, 0
			for _, e in ipairs(d.events) do
				if e.topic == "level_booster" and e.payload.phase == "used" then used = used + 1 end
				if e.topic == "level_booster" and e.payload.phase == "target" then targeted = targeted + 1 end
			end
			assert_eq(targeted, 1)
			assert_eq(used, 1)
			assert_true(d.settle(900))
			-- a spot the booster cannot use: refused, the target mode stays for another try
			assert_true(link.booster("stick"))
			assert_true(self.session:command(self.session:hint_command())) -- the board is moving: the core refuses (not_rest)
			d.frame(2)
			d.tap(4, 4)
			d.frame(1)
			local rejected
			for _, e in ipairs(d.events) do
				if e.topic == "level_booster" and e.payload.phase == "rejected" then rejected = e.payload end
			end
			assert_true(rejected ~= nil)
			assert_eq(rejected.reason, "not_rest")
			assert_eq(link.targeting(), "stick")
		end)
	end)

	it("nudges a piece it cannot swap and still lets the core decide failed swaps", function()
		with_board(first_level(), function(E, script, self, d)
			d.frame(3)
			-- swiping out of the board edge: nothing to swap with, no move spent, no command
			d.swipe(1, 1, 0, 1)
			d.frame(2)
			assert_eq(self.session.game:status().moves_left, 20)
			-- a swap that makes no match: the core plays the failed swap (no move spent)
			local fails = 0
			local g = self.session.game
			for y = 1, 7 do
				for x = 1, 6 do
					if g:can_swap({ x, y }, { x + 1, y }) == "fail" and fails == 0 then
						fails = 1
						d.swipe(x, y, x + 1, y)
						d.frame(2)
						local moves = g:status().moves_left
						assert_eq(moves, 20)
						assert_true(d.settle(300))
					end
				end
			end
			assert_eq(fails, 1)
		end)
	end)

	it("clears the selection when the game leaves \"playing\"", function()
		with_board(first_level(), function(E, script, self, d)
			d.frame(3)
			d.tap(3, 3)
			assert_true(self.input.selected ~= nil)
			self.session:qa("win")
			for _ = 1, 3000 do
				d.frame(1)
				if self.session.game:status().state ~= "playing" then break end
			end
			d.frame(2)
			assert_eq(self.input.selected, nil)
		end)
	end)
end)

describe("screens/level/board.script soak", function()
	-- levels with record boxes (10), the dance floor (15), wires (22), microphones (30), concrete (40)
	-- and noise (50): the whole level through the real script, no engine error, inside the limits
	local function play_through(params, frames)
		with_board(params, function(E, script, self, d)
			self.session:autoplay(nil, { free_moves = true })
			local state
			for _ = 1, frames or 3000 do
				d.frame(1)
				state = self.session.game:status().state
				if state == "complete" or state == "lost" then break end
			end
			assert_eq(state, "complete")
			d.frame(60)
			assert_eq(self.errors or 0, 0)
			assert_true(E.peak.sprites < 600, "sprites " .. E.peak.sprites)
			assert_true(E.peak.particlefx <= E.limits.particlefx)
			assert_true(E.peak_particles <= 300)
			assert_eq(d.topics.level_result, 1)
		end)
	end

	for _, n in ipairs({ 10, 15, 22, 30, 40, 50 }) do
		it("plays level " .. n .. " to its final concert", function()
			play_through({ level = n })
		end)
	end

	it("plays a level with balloons and a dusty column", function()
		local level = core_helper.level({
			"##A#####", "########", "########", "####E###", "########", "########", "########", "########",
		}, { moves = 20, goals = { { type = "break", item = "column", count = 1 } },
			slots = { { at = { 5, 4 }, type = "column", hp = 6 } } })
		play_through({ level = 1, level_text = level }, 4000)
	end)
end)

describe("screens/level/board.script bus contract", function()
	-- the shape of every payload the HUD and the fx GUI read (documented in the header of board.script)
	local function first(d, topic)
		for _, e in ipairs(d.events) do
			if e.topic == topic then return e.payload end
		end
	end

	it("publishes the topics of the HUD with their fields", function()
		with_board({ level = 15 }, function(E, script, self, d)
			self.session:autoplay(nil, { free_moves = true })
			for _ = 1, 3000 do
				d.frame(1)
				local st = self.session.game:status().state
				if st == "complete" or st == "lost" then break end
			end
			local ready = first(d, "level_ready")
			assert_eq(ready.level_id, 15)
			assert_true(ready.W >= 6 and ready.H >= 6 and ready.moves > 0 and #ready.goals >= 1)
			assert_true(ready.rect.cell > 0 and ready.rect.x1 > ready.rect.x0)
			assert_true(ready.standalone)
			local moves = first(d, "level_moves")
			assert_true(type(moves.left) == "number")
			local goal = first(d, "level_goal")
			assert_true(goal.index >= 1 and goal.left >= 0 and goal.kind ~= nil)
			assert_true(goal.lx ~= nil and goal.ly ~= nil, "where the collected thing was")
			local score = first(d, "level_score")
			assert_true(score.delta > 0 and score.total >= score.delta)
			local floor = first(d, "level_floor")
			assert_true(floor.x >= 1 and floor.y >= 1 and floor.lx > 0 and floor.ly > 0)
			local praise = first(d, "level_praise")
			assert_true(praise.index >= 1 and praise.index <= 5 and praise.wave >= 3)
			assert_true(first(d, "level_special").special ~= nil)
			local st = first(d, "level_state")
			assert_eq(st.state, "won_wait")
			local result = first(d, "level_result").result
			assert_true(result.won and result.score > 0 and result.stars >= 1 and result.unplaced ~= nil)
			assert_true(first(d, "level_flash").color ~= nil)
		end)
	end)

	it("tells the HUD when noise grows onto a piece", function()
		with_board({ level = 50 }, function(E, script, self, d)
			self.session:autoplay(nil, { free_moves = true })
			for _ = 1, 3000 do
				d.frame(1)
				local st = self.session.game:status().state
				if st == "complete" or st == "lost" then break end
			end
			local noise = first(d, "level_noise")
			assert_true(noise ~= nil, "the level has noise growth")
			assert_true(noise.x >= 1 and noise.y >= 1 and noise.lx > 0 and noise.ly > 0)
		end)
	end)

	it("hands the HUD the board geometry through the link", function()
		with_board(first_level(), function(E, script, self, d)
			local link = require("client.level_link")
			local r = link.board_rect()
			assert_true(r.x0 >= 0 and r.x1 <= 720 and r.y0 >= 0 and r.y1 <= 1280)
			local lx, ly = link.cell_center(1, 1)
			assert_true(lx > r.x0 and lx < r.x1 and ly > r.y0 and ly < r.y1)
			local v = link.view()
			assert_true(v.rev >= 1 and v.geom ~= nil and v.cells ~= nil and v.floor0 ~= nil)
			d.frame(2)
			E.window.w, E.window.h = 700, 900
			d.frame(2)
			assert_true(link.view().rev > v.rev or link.view().rev == v.rev) -- the layout rev never goes back
			assert_eq(link.info().level_id, 1)
		end)
	end)
end)
