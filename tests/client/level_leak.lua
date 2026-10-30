-- The visual-leak oracle and the harness of the leak fuzzer for the level board (not a test file itself).
--
-- The producer's report: "after the animations of the boosters a trace of the animation stays on the board like a
-- drawing" (decisions.md 8.3, item 8). This module is the tool that looks for such traces headless: it runs the real
-- screens/level/board.script on the strict Defold stub (tests/client/level_defold_stub.lua) and asks, with an oracle
-- that does not trust the board's own bookkeeping, what the player would SEE.
--
--   local L = require("tests.client.level_leak")
--   L.with_board(params, function(B) ... end, opts)   -- B: the board on display (see new_context)
--   local R = L.leak_report(B, opts)                  -- what is visible that nothing explains
--   print(L.format(R))
--   local f = L.frame_check(B)                        -- cheap invariants of the pools, for every frame
--   local sc = L.scenario(seed, opts)                 -- a random scenario: a board, a dt pattern, a list of ops
--   local res = L.play(sc, opts)                      -- plays it; res.leaks / res.errors / res.story
--   local small = L.shrink(sc, function(res) return ... end)   -- drops ops while the predicate holds
--
-- THE ORACLE (leak_report). At rest the only things visible on the board must be: one sprite per live core piece at
-- its cell (looking as a fresh render of the same state looks), the wires overlay of the cells that have wires, and
-- the "marks" the state explains (the selection glow and ring, the hint glows, the booster target highlight, the
-- plates under the things that never move). Everything else is a leak. The report lists, for the engine's own
-- idea of what is visible (E.visible_sprites of the stub: enabled, scale, alpha, clip, on the screen), every sprite
-- that no live piece / wire / mark explains, with its image, position, scale, alpha, and which pool or owner made it.
-- "At rest" means the core is stable, the session runs, and the board has been quiet for M.QUIET seconds of board time.
--
--   orphan_sprite       visible, and no structure of the board (view, vfx) knows the object
--   pooled_visible      a pooled sprite (effect pool or piece pool) is on the screen
--   lost_sprite         an effect sprite that is not pooled and that no running effect holds (what the periodic
--                       sprite recount of level_vfx exists to take back: it does so every 30 FRAMES)
--   double_held         one sprite held by two effects, or both held and pooled
--   dangling            the board holds an object the engine has deleted
--   vfx_count           the count of effect sprites is not the count of those made
--   overlong_fx         (every frame) an effect lives much longer than its duration while the session runs: only the
--                       life limit of level_vfx would take it away
--   halted_fx_visible   (every frame) an effect that follows the ticks of the core is drawn although the session was stopped
--                       (a window, a lost focus) during the last frame: it would stand still on the board for as long as
--                       the window is open (the leftovers of the producer's report, decisions.md 8.3 item 8, the addendum
--                       on the tick effects that now wait out of sight)
--   piece_overflow      (every frame) a piece found no sprite in the pool of the view (client/level_view.lua View:sync)
--   janitor_repair      (every frame) the janitor of the board (screens/level/board.script) had to put a sprite right: it
--                       is the net under everything above, so in a test it is a leak that got through
--   stale_piece_sprite  a sprite of a piece that the core no longer has
--   hidden_piece_visible / missing_piece_sprite / piece_displaced / piece_look   the pieces vs a fresh render
--   stale_piece_list    the list of pieces the board caches is not the core's
--   wire_mismatch       the wires overlay is not the core's wires
--   mark_unexplained    marks drawn that the selection / hint / target / plates do not explain
--   rest_vfx            an effect sprite is visible, or an effect still runs / waits, long after the board rested
--   rest_particles      a particle effect is still alive at rest
--   rest_shake          the board is shaken at rest
--   late_cleanup        (the runner) the effects needed longer than LATE seconds after the board rested to go
--   engine_error        an error the board caught (it counts and logs them; in strict mode they raise)
--   gui_leftover        (the runner) a node of the overlay scene is still drawn when the level is over
-- opts.rest = false asks only for the structural kinds (no wait for the effects to be over). frame_check(B) asks the
-- cheap ones of the list after every frame; B.deep (every 5th frame) asks the structural kinds of the whole screen.
--
-- THE FUZZER (scenario / play). A scenario is a pure function of its seed: a board (a random one with specials and
-- blockers, one of the 100 level files, or two specials side by side that the first move swaps), a frame rhythm (1/60 s,
-- 1/30 s, 1/10 s, 0.5 s, 3 s, 1/60 s with spikes, a rhythm changing every 50 frames), a list of random ops (the five
-- in-level boosters through the QA session API and through the target mode of the link, swaps and taps, swipes and
-- taps through on_input, tap-to-skip, the app losing the focus by the bus and by the QA command, a tab that sleeps, a
-- single long frame, windows pausing the session, the moves window answered by "+5 moves", a booster or "give up",
-- settings, a restart of the level), and an end (rest / won to the end of the concert with taps that skip it / given up /
-- continued). The HUD is modelled: a window open pauses the session as screens/level/level.gui_script does.

local stub = require("tests.client.level_defold_stub")
local app = require("client.app")
local bus = require("client.bus")
local layout = require("client.layout")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local H = require("tests.meta.helper")
local core_helper = require("tests.core.helper")
local rng = require("core.rng")

local M = {}

M.LATE = 2.0        -- seconds the effects may need to go after the board has rested (the longest burst lives 1 s)
M.QUIET = 3.5       -- seconds of board time the runner waits at rest before it asks the oracle
M.EPS_POS = 2.5     -- logical px a resting piece may be off its cell
M.DT_MODES = { "60", "30", "10", "500", "3000", "spike", "mixed" }
M.MAX_FRAMES = 60000 -- frames of one scenario at most (a long level played to its end at 1/60 s is about 5000)

-- booting -----------------------------------------------------------------------------------------------------

local function boot_app()
	analytics.init({ strict = true })
	app.init({
		districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
		now = H.T0, clock = function() return H.T0 end, sys_language = "en",
	})
end

local PAUSABLE = { playing = true, out_of_moves = true } -- screens/level/level.gui_script: when the pause window opens

-- The context of a board on display. B.step(dt) is one frame (the engine clock, the board's update, the bus, the HUD
-- model); B.hud models what screens/level/level.gui_script does to the session: a window open = the session paused.
local function new_context(E, script, self, sub, opts)
	local link = require("client.level_link")
	local B = {
		E = E, script = script, self = self, sub = sub, link = link, frames = 0, engine_time = 0, restarts = 0,
		events = {},          -- every bus event {t, topic, payload}: the replay for the GUI scripts
		topics = {},
		findings = {},        -- structural findings met while stepping {kind, text, frame, op}
		finding_keys = {},
		hud = { pause = false, moves = false, ended = false, state = "playing", applied = false, target = nil },
		clock = 0,            -- board time of the boards before a restart
		op = 0,               -- the op being played (for the findings)
		slow = opts.slow,     -- frames longer than 0.25 s: the effects that follow the ticks take 2.5 times as long
		check = opts.check ~= false,
		deep = opts.deep == nil and 5 or opts.deep, -- every 5th frame the oracle looks at the whole screen (false: never)
		dt_log = {},
	}
	local function apply_pause()
		local h = B.hud
		local want = h.pause or h.moves or h.ended
		if want ~= h.applied then
			h.applied = want
			link.pause(want)
		end
	end
	B.apply_pause = apply_pause
	function B.pump()
		local before = #B.events
		sub:drain(function(topic, payload)
			B.events[#B.events + 1] = { t = B.clock + B.self.t, topic = topic, payload = payload }
			B.topics[topic] = (B.topics[topic] or 0) + 1
			local h = B.hud
			if topic == "level_state" then
				h.state = payload.state
				if payload.state == "out_of_moves" and not h.ended then
					h.moves = true
				elseif h.moves then
					h.moves = false -- "auto": the moves came back
				end
			elseif topic == "level_result" then
				h.ended, h.moves, h.pause = true, false, false
			elseif topic == "level_booster" then
				if payload.phase == "target" then h.target = payload.booster
				elseif payload.phase == "cancel" or payload.phase == "used" then
					h.target = nil
					-- aimed at nothing while the moves are out: the offer is back (level.gui_script on_booster_event)
					if payload.phase == "cancel" and h.state == "out_of_moves" and not h.ended then h.moves = true end
				end
			end
		end)
		-- the HUD's queue holds 256 events at most (client/bus.lua): how many came in one frame?
		local burst = #B.events - before
		if burst > (B.max_burst or 0) then B.max_burst = burst end
		apply_pause()
	end
	function B.step(dt)
		-- a scenario that never ends (a loop that waits for a rest that does not come) is a finding of its own
		if B.frames >= (opts.max_frames or M.MAX_FRAMES) then
			error("frame budget of " .. (opts.max_frames or M.MAX_FRAMES) .. " frames used up: the scenario does not end", 0)
		end
		E.advance(dt)
		script.update(B.self, dt)
		-- (what the effects of that update saw: a window opens after it, in B.pump)
		B.halted_seen = B.self.session:halted()
		B.frames = B.frames + 1
		B.engine_time = B.engine_time + dt
		B.pump()
		if B.check then
			local list = M.frame_check(B)
			-- every few frames the whole screen is asked too (the structural kinds, whatever the board is doing)
			if B.deep and B.frames % B.deep == 0 then
				local R = M.leak_report(B, { rest = false, look = false })
				for _, l in ipairs(R.leaks) do
					list = list or {}
					list[#list + 1] = { kind = l.kind, text = l.text }
				end
			end
			if list then
				for _, f in ipairs(list) do
					local key = f.kind .. ":" .. (f.text or "")
					if not B.finding_keys[key] then
						B.finding_keys[key] = true
						f.frame, f.op, f.dt = B.frames, B.op, dt
						B.findings[#B.findings + 1] = f
					end
				end
			end
		end
	end
	-- a touch at logical coordinates: "down", "move", "up"
	function B.touch(kind, lx, ly)
		local f = layout.fit(E.window.w, E.window.h)
		local sx, sy = layout.logical_to_screen(f, lx, ly)
		local action = { screen_x = sx, screen_y = sy, x = sx, y = sy, pressed = kind == "down", released = kind == "up" }
		return script.on_input(B.self, hash("touch"), action)
	end
	function B.state()
		return B.self.session.game:status().state
	end
	function B.game()
		return B.self.session.game
	end
	-- The player leaves the level and starts it again (or another): the old board is finalised, its collection is
	-- unloaded (every object of it is gone), a new board is initialised on the same app state.
	function B.restart(params)
		pcall(script.final, B.self)
		E.unload()
		sub:drain(function() end)
		if params then app.params = params end
		local fresh = {}
		script.init(fresh)
		if fresh.failed then error("the board failed to start again") end
		fresh.strict = B.self.strict
		B.clock = B.clock + B.self.t -- the board time of the old board is behind us
		B.self = fresh
		B.restarts = B.restarts + 1
		local h = B.hud
		h.pause, h.moves, h.ended, h.applied, h.target, h.state = false, false, false, false, nil, "playing"
	end
	return B
end

-- Runs fn(B) with a board on display (params as app.params: {level = n} or {level = 1, level_text = table}); always
-- restores the globals. opts: {window = {w, h}, strict = true (errors of the cosmetic code raise), check = true
-- (cheap invariants of the pools after every frame)}.
function M.with_board(params, fn, opts)
	opts = opts or {}
	-- (opts.float32 = true: the vectors keep float32 like the engine's, see the stub; a little slower, so only where it
	-- matters: what the board sends to the engine at rest, and so when it is calm enough for the janitor to look)
	local E = stub.install({ window = opts.window, float32 = opts.float32 == true })
	-- what the board prints (a warning of a booster the meta did not charge, an error it caught) is collected in B.log,
	-- not written to the output of the test run
	local real_print, log = print, {}
	if not opts.print then
		print = function(...)
			local parts = {}
			for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
			log[#log + 1] = table.concat(parts, " ")
		end
	end
	local ok, err = xpcall(function()
		boot_app()
		if type(params) == "function" then params = params(app) end -- (a meta run is started on the app just booted)
		app.params = params
		local sub = bus.subscribe("*", "leak_board")
		local script = stub.load_script("screens/level/board.script")
		local self = {}
		script.init(self)
		if self.failed then error("the board failed to start") end
		self.strict = opts.strict ~= false
		local B = new_context(E, script, self, sub, opts)
		B.log = log
		local ok2, err2 = xpcall(function() return fn(B) end, debug.traceback) -- (Lua 5.1's xpcall passes no arguments)
		pcall(script.final, B.self)
		sub:close()
		if not ok2 then error(err2, 0) end
	end, debug.traceback)
	print = real_print
	stub.restore()
	if not ok then error(err, 0) end
end

-- the oracle ------------------------------------------------------------------------------------------------------

local function fx_kind(fx)
	return fx.c and fx.c.kind or "dot"
end

-- sprite object -> number of effect slots that hold it
local function held_map(vfx)
	local held = {}
	for _, fx in ipairs(vfx.active) do
		for j = 1, fx.n do
			local o = fx[j]
			if o then held[o] = (held[o] or 0) + 1 end
		end
	end
	return held
end

local function fmt_sprite(s)
	return string.format("%s at %.0f,%.0f px %.0f a=%.2f", s.image, s.x, s.y, s.px, s.alpha)
end

-- Cheap invariants of the pools, after every frame (no scan of the engine): the structure must be sound whatever
-- the effects were doing. Returns a list of {kind, text} or nil.
function M.frame_check(B)
	local E, self = B.E, B.self
	local vfx, view = self.vfx, self.view
	if not vfx or not view then return nil end
	local out
	local function add(kind, text)
		out = out or {}
		out[#out + 1] = { kind = kind, text = text }
	end
	local held = held_map(vfx)
	local sprites = 0
	for _, o in ipairs(vfx.all) do
		sprites = sprites + 1
		local eng = E.objects[o.go.s]
		local vis = eng and E.visible(eng)
		local n = held[o] or 0
		if o.pooled then
			if vis then add("pooled_visible", "effect sprite " .. o.kind .. " of the pool is on the screen") end
			if n > 0 then add("double_held", "pooled and held by an effect") end
		elseif n == 0 then
			add("lost_sprite", "effect sprite " .. o.kind .. (vis and " (on the screen)" or " (parked)") .. " is held by no effect and not pooled")
		elseif n > 1 then
			add("double_held", "effect sprite " .. o.kind .. " held by " .. n .. " slots")
		end
	end
	if sprites ~= vfx.sprites then add("vfx_count", "vfx.sprites " .. vfx.sprites .. " but " .. sprites .. " made") end
	-- an effect that lives much longer than it should while the session runs is stuck: only the life limit of
	-- level_vfx (6 x its duration + 2 s) would take it off the board
	if not self.session:halted() or vfx.finished then
		local slack = B.slow and 3.2 or 2
		for _, fx in ipairs(vfx.active) do
			local nominal = (fx.clock == "tick" and fx.dur / 60 or fx.dur) + (fx.after or 0)
			if fx.life > nominal * slack + 1 then
				add("overlong_fx", string.format("%s effect alive for %.1f s (nominal %.2f s)", fx_kind(fx), fx.life, nominal))
			end
		end
	end
	for _, o in ipairs(view.free) do
		local eng = E.objects[o.go.s]
		if eng and E.visible(eng) then add("pooled_visible", "a pooled piece sprite is on the screen") end
	end
	-- the effects that follow the ticks of the core wait out of sight while the session is stopped (an effect that has
	-- passed its end and only fades out is on the real clock: that one is drawn, for a fraction of a second)
	if B.halted_seen and not vfx.finished then
		for _, fx in ipairs(vfx.active) do
			if fx.clock == "tick" and fx.after_t0 == nil then
				for j = 1, fx.n do
					local o = fx[j]
					local eng = o and E.objects[o.go.s]
					if eng and E.visible(eng) then
						add("halted_fx_visible", "a " .. fx_kind(fx) .. " effect is drawn although the session is stopped")
						break
					end
				end
			end
		end
	end
	if view.overflow > 0 then
		add("piece_overflow", view.overflow .. " pieces found no sprite in the pool of the view (" .. view.count .. " made)")
	end
	if (view.repaired or 0) > 0 or vfx.repaired > 0 or (self.janitor_repairs or 0) > 0 then
		add("janitor_repair", "the janitor put right " .. (view.repaired or 0) .. " view and " .. vfx.repaired .. " effect sprites")
	end
	return out
end

local function xy_of(self, p)
	local x, y = self.geom:pos(p.x, p.y, p.offx, p.offy)
	if p.item == "column" then x, y = x + self.geom.cell / 2, y - self.geom.cell / 2 end
	return x, y
end

-- Same-state check of two piece lists (the board caches its list while the board rests).
local PIECE_FIELDS = { "id", "x", "y", "kind", "state", "offx", "offy", "hidden", "pinned", "color", "special", "axis",
	"item", "hp" }
local function same_pieces(a, b)
	if #a ~= #b then return false, "count " .. #a .. " vs " .. #b end
	for i = 1, #a do
		for _, k in ipairs(PIECE_FIELDS) do
			if a[i][k] ~= b[i][k] then
				return false, "piece " .. b[i].id .. " " .. k .. ": " .. tostring(a[i][k]) .. " vs " .. tostring(b[i][k])
			end
		end
	end
	return true
end

-- True while a window (the pause, the moves window) or the app's absence holds the ticks of a session whose level goes
-- on afterwards: the effects that follow the ticks wait with it, so how long they take says nothing, and that they exist
-- is not a leak (what they DRAW is, sprite by sprite). A level that is over (complete, lost) waits for nothing: the board
-- lets the effects run out by themselves then (level_vfx finish()), and ones that do not are the failure of the first
-- report.
local function held_by_window(B)
	local self = B.self
	if not self.session:halted() or self.vfx.finished then return false end
	local st = B.state()
	return st ~= "complete" and st ~= "lost"
end

-- What is visible on the board that nothing explains. opts: {rest = true (default: the board has been at rest for
-- M.QUIET seconds), look = true (default at rest: compare the pieces with a fresh render), visible = {min_px, ...}
-- (E.visible_sprites options)}. Returns R = {leaks = {{kind, text, sprite}}, visible = n, vfx = stats, ...}.
function M.leak_report(B, opts)
	opts = opts or {}
	local E, self = B.E, B.self
	local rest = opts.rest ~= false
	local R = { leaks = {}, visible = 0, rest = rest }
	local function leak(kind, text, sprite)
		R.leaks[#R.leaks + 1] = { kind = kind, text = text, sprite = sprite }
	end
	if not self.view or not self.vfx or not self.geom then
		leak("no_board", "the board is not up")
		return R
	end
	local view, vfx, game = self.view, self.vfx, self.session.game
	local held = held_map(vfx)
	local pieces = game:pieces()
	local by_id = {}
	for _, p in ipairs(pieces) do by_id[p.id] = p end

	-- who made each engine object ------------------------------------------------------------------------------
	local owner = {}
	for id, o in pairs(view.by_id) do owner[o] = { kind = "piece", id = id } end -- order-independent
	for _, o in ipairs(view.free) do owner[o] = { kind = "piece_pool" } end
	for i, w in ipairs(view.wires) do owner[w.o] = { kind = "wire", i = i } end
	for i, o in ipairs(view.mark_objs.glow) do owner[o] = { kind = "mark_glow", i = i } end
	for i, o in ipairs(view.mark_objs.piece) do owner[o] = { kind = "mark_piece", i = i } end
	for _, o in ipairs(vfx.all) do
		if o.pooled then owner[o] = { kind = "vfx_pool", o = o }
		elseif (held[o] or 0) > 0 then owner[o] = { kind = "vfx_active", o = o }
		else owner[o] = { kind = "vfx_lost", o = o } end
	end
	local by_go = {}
	for o, ow in pairs(owner) do by_go[o.go] = { o = o, owner = ow } end -- order-independent
	local fx_of = {}
	for _, fx in ipairs(vfx.active) do
		for j = 1, fx.n do if fx[j] then fx_of[fx[j]] = fx end end
	end

	-- the sprites on the screen -----------------------------------------------------------------------------------
	local vis = E.visible_sprites(opts.visible)
	R.visible = #vis
	local wires_seen, glow_seen, piece_marks_seen = 0, 0, 0
	local wire_pos = {}
	for _, s in ipairs(vis) do
		local k = by_go[s.go]
		s.owner = k and k.owner.kind or "unknown"
		if not k then
			leak("orphan_sprite", "no structure of the board knows " .. s.factory .. " " .. fmt_sprite(s), s)
		else
			local ow = k.owner
			if ow.kind == "piece_pool" then
				leak("pooled_visible", "a pooled piece sprite is on the screen: " .. fmt_sprite(s), s)
			elseif ow.kind == "vfx_pool" then
				leak("pooled_visible", "a pooled " .. ow.o.kind .. " sprite is on the screen: " .. fmt_sprite(s), s)
			elseif ow.kind == "vfx_lost" then
				leak("lost_sprite", "an effect sprite (" .. ow.o.kind .. ") is held by no effect: " .. fmt_sprite(s), s)
			elseif ow.kind == "vfx_active" then
				local fx = fx_of[k.o]
				s.fx = fx and fx_kind(fx) or "?"
				if rest then
					leak("rest_vfx", "a running " .. s.fx .. " effect is still drawn at rest (" .. fmt_sprite(s) .. ")", s)
				end
			elseif ow.kind == "piece" then
				local p = by_id[ow.id]
				if not p then
					leak("stale_piece_sprite", "a sprite of piece " .. ow.id .. " that the core no longer has: " .. fmt_sprite(s), s)
				elseif rest and p.hidden then
					leak("hidden_piece_visible", "piece " .. p.id .. " is hidden by the core but drawn: " .. fmt_sprite(s), s)
				end
			elseif ow.kind == "wire" then
				wires_seen = wires_seen + 1
				wire_pos[#wire_pos + 1] = s
			elseif ow.kind == "mark_glow" then
				glow_seen = glow_seen + 1
			elseif ow.kind == "mark_piece" then
				piece_marks_seen = piece_marks_seen + 1
			end
		end
	end
	-- sprites the structure holds but the engine no longer has (deleted objects)
	for o, ow in pairs(owner) do -- order-independent
		if not E.objects[o.go.s] then leak("dangling", "the board holds a deleted object: " .. ow.kind) end
	end

	-- the list of pieces the board caches while it rests is the core's at the end of every frame (screens/level/board.script)
	if self.pieces then
		local ok, why = same_pieces(self.pieces, pieces)
		if not ok then leak("stale_piece_list", why) end
	end

	-- the pools' arithmetic ------------------------------------------------------------------------------------------
	for o, n in pairs(held) do -- order-independent
		if n > 1 then leak("double_held", "an effect sprite is held " .. n .. " times") end
		if o.pooled then leak("double_held", "an effect sprite is held and pooled") end
	end

	if rest then
		-- the effects ---------------------------------------------------------------------------------------------
		local st = vfx:stats()
		R.vfx = st
		-- while a window or the app's absence holds the session, the effects that follow its ticks wait with it: what
		-- they DRAW is a leak (checked above, sprite by sprite), that they exist is not
		local waiting = held_by_window(B)
		if st.active > 0 and not waiting then
			local kinds = {}
			for _, fx in ipairs(vfx.active) do kinds[#kinds + 1] = fx_kind(fx) end
			leak("rest_vfx", st.active .. " effects still run at rest: " .. table.concat(kinds, ","))
		end
		if st.pending > 0 and not waiting then
			local kinds = {}
			for i = 1, #vfx.heap do kinds[#kinds + 1] = vfx.heap[i].kind end
			leak("rest_vfx", st.pending .. " commands still wait for their tick at rest: " .. table.concat(kinds, ","))
		end
		local parts = E.running_particles()
		R.particles = #parts
		if #parts > 0 then leak("rest_particles", #parts .. " particle emitters alive at rest (" .. tostring(parts[1].file) .. ")") end
		if self.shake_x ~= 0 or self.shake_y ~= 0 then leak("rest_shake", "the board is shaken at rest") end
		-- every live piece is drawn, once, where it is, and looks as a fresh render of the same state -----------------
		local fresh
		if opts.look ~= false and self.geom then
			local level_anim = require("client.level_anim")
			local A = level_anim.new({ reduced = self.anim.reduced }) -- (self.reduced is the setting at init)
			A:set_geom(self.geom)
			A.max_hp = self.anim.max_hp -- (the picture of a column depends on the hp it started with: history)
			A:select(self.anim.selected)
			A:hint(self.anim.hint_a, self.anim.hint_b, self.anim.hint_phase)
			-- the list is built from the pieces; the display tick and the time are far past every timer
			local list = A:frame(pieces, self.session:display_tick(), self.t + 1000)
			fresh = {}
			for _, e in ipairs(list) do fresh[e.id] = e end
		end
		local engine_of = {}
		for _, s in ipairs(vis) do engine_of[s.go] = s end
		for _, p in ipairs(pieces) do
			local o = view.by_id[p.id]
			local s = o and engine_of[o.go]
			if not p.hidden and not s then
				leak("missing_piece_sprite", "piece " .. p.id .. " " .. tostring(p.color or p.special or p.item or p.kind) .. " at " .. p.x .. "," .. p.y .. " has no visible sprite")
			elseif s and p.state == "idle" then
				local e = fresh and fresh[p.id]
				if e and not p.pinned then
					-- the rest of what a sprite carries: the image, the depth, the turn, the mirror, the cut, the tint
					local rot_d = ((s.rot - e.rot + 180) % 360) - 180
					if s.image ~= e.image or math.abs(s.z - e.z) > 1e-6 or math.abs(rot_d) > 0.5 or s.hflip
						or s.clip < 99999 or math.abs(s.r - 1) > 1e-6 or math.abs(s.g - 1) > 1e-6 or math.abs(s.b - 1) > 1e-6 then
						leak("piece_look", string.format("piece %d (%s): image %s z %.3f rot %.1f hflip %s clip %.0f tint %.2f/%.2f/%.2f; a fresh render: %s z %.3f rot %.1f",
							p.id, tostring(p.color or p.special or p.item), s.image, s.z, s.rot, tostring(s.hflip), s.clip, s.r, s.g, s.b,
							e.image, e.z, e.rot), s)
					end
				end
				-- where a fresh render puts it (the hint wobble included), else the centre of its cell
				local x, y = xy_of(self, p)
				if e then x, y = e.x, e.y end
				if math.abs(s.x - x) > M.EPS_POS or math.abs(s.y - y) > M.EPS_POS then
					leak("piece_displaced", string.format("piece %d (%s) at %d,%d is drawn at %.0f,%.0f instead of %.0f,%.0f",
						p.id, tostring(p.color or p.special or p.item), p.x, p.y, s.x, s.y, x, y), s)
				end
				if e and not p.pinned then
					local want = e.scale * e.sx
					if math.abs(s.sx - want) > 0.02 * want + 1e-4 or math.abs(s.alpha - e.alpha) > 0.02
						or math.abs(s.flash - e.flash) > 0.05 then
						leak("piece_look", string.format("piece %d (%s) looks scale %.3f flash %.2f alpha %.2f, a fresh render: %.3f %.2f %.2f",
							p.id, tostring(p.color or p.special or p.item), s.sx, s.flash, s.alpha, want, e.flash, e.alpha), s)
					end
				end
			end
		end
		-- the wires overlay --------------------------------------------------------------------------------------------
		local cells = game:cells()
		local want_wires = {}
		for i = 1, #cells do
			local c = cells[i]
			if c.exists and (c.wires or 0) > 0 then
				local x = (i - 1) % self.W + 1
				local y = math.floor((i - 1) / self.W) + 1
				local lx, ly = self.geom:center(x, y)
				want_wires[#want_wires + 1] = { x = lx, y = ly }
			end
		end
		if #want_wires ~= wires_seen then
			leak("wire_mismatch", "the core has wires on " .. #want_wires .. " cells, " .. wires_seen .. " wire sprites are drawn")
		else
			for _, w in ipairs(wire_pos) do
				local found = false
				for _, q in ipairs(want_wires) do
					if math.abs(q.x - w.x) <= M.EPS_POS and math.abs(q.y - w.y) <= M.EPS_POS then found = true end
				end
				if not found then leak("wire_mismatch", "a wire sprite sits on no cell with wires: " .. fmt_sprite(w), w) end
			end
		end
		-- the marks --------------------------------------------------------------------------------------------------------
		local n_glow, n_piece = 0, 0
		for _, m in ipairs(self.mark_list or {}) do
			if m.glow then n_glow = n_glow + 1 else n_piece = n_piece + 1 end
		end
		local sel = self.input.selected or self.input.pair
		local want_glow = sel and 2 or 0
		local h = self.hint_cmd
		local phase = self.hint:phase()
		if h and phase then want_glow = want_glow + ((h.at and 1) or 2) end
		local tg, hv = self.input.targeting, self.input.hover
		local want_piece = self.plates:count()
		if tg and hv and self.geom:inside(hv.x, hv.y) then want_piece = want_piece + 1 end
		if n_glow ~= want_glow or n_piece ~= want_piece then
			leak("mark_unexplained", "the board draws " .. n_glow .. " glow and " .. n_piece .. " plate/target marks, the state explains "
				.. want_glow .. " and " .. want_piece)
		end
		if glow_seen > want_glow or piece_marks_seen > want_piece then
			leak("mark_unexplained", "visible marks: " .. glow_seen .. " glow, " .. piece_marks_seen .. " plate/target; explained: "
				.. want_glow .. " and " .. want_piece)
		end
		if self.input.selected and not by_id[self.input.selected.id] then
			leak("mark_unexplained", "the selection belongs to a piece that is gone")
		end
	end
	if self.errors and self.errors > 0 then leak("engine_error", "the board caught " .. self.errors .. " errors") end
	table.sort(R.leaks, function(a, b)
		if a.kind ~= b.kind then return a.kind < b.kind end
		return a.text < b.text
	end)
	local st = self.vfx:stats()
	R.vfx = R.vfx or st
	if st.errors > 0 then leak("engine_error", "the vfx caught " .. st.errors .. " errors: " .. tostring(self.vfx.last_error)) end
	if st.repaired > 0 then
		-- the periodic recount took sprites back: something lost them (see lost_sprite / pooled_visible)
		R.repaired = st.repaired
	end
	return R
end

function M.format(R)
	local lines = {}
	for _, l in ipairs(R.leaks) do lines[#lines + 1] = l.kind .. ": " .. l.text end
	return table.concat(lines, "\n")
end

-- the scenarios -----------------------------------------------------------------------------------------------------

-- A seeded stream of numbers (the same on Lua 5.1 and LuaJIT).
local function stream(seed, k)
	local r = rng.stream(seed, k or 1)
	local S = {}
	function S.int(n) return rng.int(r, n) end            -- 1..n
	function S.chance(p) return rng.int(r, 1000) <= p * 1000 end
	function S.pick(list) return list[rng.int(r, #list)] end
	function S.range(a, b) return a + rng.int(r, b - a + 1) - 1 end
	return S
end
M.stream = stream

-- a board with specials (and sometimes blockers) in it, as a level table (tests/core/helper.lua pictures)
local SPECIAL_LETTERS = { "R", "V", "S", "B", "D" }
local BLOCK_LETTERS = { "X", "K", "N", "A", "E" }

local function gen_board(r, opts, mode)
	for _ = 1, 50 do
		local W, Hh = r.range(6, 9), r.range(6, 9)
		local rows = {}
		for y = 1, Hh do rows[y] = {} end
		for y = 1, Hh do for x = 1, W do rows[y][x] = "#" end end
		local n_special = opts.specials or r.range(1, 4)
		local placed = {}
		for _ = 1, n_special do
			local x, y = r.range(1, W), r.range(1, Hh)
			rows[y][x] = r.pick(SPECIAL_LETTERS)
			placed[#placed + 1] = { x, y }
		end
		-- "combo": two specials side by side, the first move swaps them (one of the ten combos)
		local first_swap
		if mode == "combo" then
			local x, y = r.range(1, W - 1), r.range(1, Hh - 1)
			local vertical = r.chance(0.4)
			local nx, ny = vertical and x or x + 1, vertical and y + 1 or y
			rows[y][x] = opts.a or r.pick(SPECIAL_LETTERS)
			rows[ny][nx] = opts.b or r.pick(SPECIAL_LETTERS)
			first_swap = { x1 = x, y1 = y, x2 = nx, y2 = ny }
		end
		if r.chance(0.3) then
			for _ = 1, r.range(1, 3) do
				local x, y = r.range(1, W), r.range(1, Hh)
				if rows[y][x] == "#" then rows[y][x] = r.pick(BLOCK_LETTERS) end
			end
		end
		local lines = {}
		for y = 1, Hh do lines[y] = table.concat(rows[y]) end
		local colors = { "red", "orange", "yellow", "green", "blue", "purple" }
		local nc = r.range(4, 6)
		local palette = {}
		for i = 1, nc do palette[i] = colors[i] end
		local goal_color = r.pick(palette)
		-- (the loader wants 5..60 moves; a scenario that wants fewer sets moves_left after the start)
		local moves, goal = opts.moves or r.range(5, 12), opts.goal or r.range(3, 40)
		if mode == "combo" then
			goal = opts.goal or r.range(3, 14) -- a combo clears that many of a colour, or does not: both end in a rest
		end
		local lvl = core_helper.level(lines, {
			moves = moves, colors = palette,
			goals = { { type = "collect", color = goal_color, count = goal } },
		})
		lvl.id = 900 + r.int(99)
		local core = require("core.game")
		local ok = core.load_level(lvl)
		if ok then
			local left = nil
			if mode == "combo" then left = opts.left or r.range(1, 4) elseif r.chance(0.3) then left = r.range(1, 4) end
			return lvl, lines, first_swap, left
		end
	end
	error("could not generate a board")
end

-- The ops of a scenario are plain data: {op = "name", ...}. Where an op names a cell it names it on purpose; where it
-- picks ("a special") it picks by number among what is there when it runs, so that a list of ops stays replayable
-- when some of them are dropped.
local OPS = {}

local function board_dims(B)
	return B.self.W, B.self.H
end

local function cell_center(B, x, y)
	return B.self.geom:center(x, y)
end

local function specials_of(B)
	local list = {}
	for _, p in ipairs(B.game():pieces()) do
		if p.kind == "special" and p.state == "idle" and not p.pinned then list[#list + 1] = p end
	end
	return list
end

function OPS.frames(S, op)
	S.run_time(op.sec)
end

function OPS.settle(S, op)
	S.settle(op.sec or 30)
end

function OPS.hint(S)
	S.B.self.session:qa("hint_move", {})
end

function OPS.swap(S, op)
	S.B.self.session:qa("swap", { op.x1, op.y1, op.x2, op.y2 })
end

function OPS.tap(S, op)
	S.B.self.session:qa("tap", { op.x, op.y })
end

function OPS.tap_special(S, op)
	local list = specials_of(S.B)
	if #list == 0 then return end
	local p = list[(op.k - 1) % #list + 1]
	S.B.self.session:qa("tap", { p.x, p.y })
end

function OPS.booster(S, op)
	local a = op.args or {}
	S.B.self.session:qa("booster", { op.id, a[1], a[2], a[3], a[4] })
end

-- a real swipe through on_input (down, move 0.45 cells, up)
function OPS.swipe(S, op)
	local B = S.B
	local lx, ly = cell_center(B, op.x, op.y)
	local c = B.self.geom.cell
	local dx = ({ l = -1, r = 1, u = 0, d = 0 })[op.dir]
	local dy = ({ l = 0, r = 0, u = -1, d = 1 })[op.dir]
	B.touch("down", lx, ly)
	S.step()
	B.touch("move", lx + dx * c * 0.45, ly - dy * c * 0.45)
	S.step()
	B.touch("up", lx + dx * c * 0.45, ly - dy * c * 0.45)
	S.step()
end

function OPS.touch_tap(S, op)
	local B = S.B
	local lx, ly = cell_center(B, op.x, op.y)
	B.touch("down", lx, ly)
	S.step()
	B.touch("up", lx, ly)
	S.step()
end

-- a tap on a special through on_input
function OPS.touch_special(S, op)
	local list = specials_of(S.B)
	if #list == 0 then return end
	local p = list[(op.k - 1) % #list + 1]
	OPS.touch_tap(S, { x = p.x, y = p.y })
end

-- a tap off the board (the tap-to-skip of the final concert)
function OPS.touch_skip(S)
	local B = S.B
	B.touch("down", 360, 80)
	S.step()
	B.touch("up", 360, 80)
	S.step()
end

function OPS.skip(S)
	S.B.self.session:qa("skip", {})
	S.B.self.clear_vfx = true -- the QA bridge's hook (screens/level/board.script on_qa)
end

function OPS.hold(S, op)
	if op.bus then
		bus.publish("app_focus", { focused = not op.on })
	else
		S.B.self.session:qa("hold", { op.on and "1" or "0" })
	end
end

-- one long frame (a GC pause, a busy tab): the engine's dt is the whole stall, the board takes 0.25 s of it
function OPS.stall(S, op)
	S.step(op.sec)
end

-- A tab that goes to sleep: the app loses the focus, nothing runs for `sec` seconds, the app is back and its first
-- frame is as long as the sleep (the board clamps it).
function OPS.tab_sleep(S, op)
	bus.publish("app_focus", { focused = false })
	S.step(1 / 60)
	bus.publish("app_focus", { focused = true })
	S.step(op.sec)
end

-- settings the board follows (client/app.lua): reduced motion, the input mode
function OPS.setting(S, op)
	app.set_setting(op.key, op.value)
	local B = S.B
	B.events[#B.events + 1] = { t = B.clock + B.self.t, topic = "@setting", payload = { key = op.key, value = op.value } }
end

-- The player leaves the level and plays it (or another) again, at any moment of it.
function OPS.restart(S)
	S.B.restart()
end

-- The window changes its size (a phone turned, a browser window dragged): the board lays itself out again.
local WINDOWS = { { 720, 1280 }, { 540, 960 }, { 1280, 720 }, { 390, 844 }, { 1080, 1920 }, { 700, 900 } }
function OPS.resize(S, op)
	local w = WINDOWS[(op.k - 1) % #WINDOWS + 1]
	S.B.E.window.w, S.B.E.window.h = w[1], w[2]
end

function OPS.pause(S, op)
	local h = S.B.hud
	if op.on then
		if PAUSABLE[h.state] and not h.ended then h.pause = true end
	else
		h.pause = false
	end
	S.B.apply_pause()
end

function OPS.win(S)
	S.B.self.session:qa("win", {})
end

function OPS.autoplay(S, op)
	S.B.self.session:qa("autoplay", { op.n or 1 })
end

-- the booster bar: target mode through the link (what the HUD does), then a real tap on the board or a cancel.
-- Returns whether the booster is going on (level.gui_script on_booster).
function OPS.target(S, op)
	local B = S.B
	local ok = B.link.booster(op.id)
	if not ok then return false end
	if op.id == "remix" then return true end
	if op.cancel then
		S.run_time(0.1)
		B.link.cancel_booster()
		return false
	end
	local x, y = op.x, op.y
	OPS.touch_tap(S, { x = x, y = y })
	if op.id == "swap" then OPS.touch_tap(S, { x = op.x2 or x, y = op.y2 or y }) end
	return true
end

-- the moves window's answers (level.gui_script on_moves_close): the window closes, the session runs again, then the
-- answer is carried out
function OPS.answer(S, op)
	local B = S.B
	local h = B.hud
	if not h.moves then return end
	h.moves = false
	B.apply_pause()
	if op.action == "continue" then
		B.link.continue(5, op.riff)
	elseif op.action == "give_up" then
		B.link.give_up()
	elseif op.action == "booster" then
		-- the window is gone: a booster that could not start brings the offer back (level.gui_script on_moves_close)
		local going = OPS.target(S, { id = op.id, x = op.x, y = op.y, x2 = op.x2, y2 = op.y2, cancel = op.cancel })
		if not going and not h.target and B.state() == "out_of_moves" and not h.ended then
			h.moves = true
			B.apply_pause()
		end
	end
end

-- What a player cannot do with the board while a window is open or the app is away: the board takes no touch.
for _, name in ipairs({ "hint", "swap", "tap", "tap_special", "booster", "swipe", "touch_tap", "touch_special",
	"touch_skip", "skip", "win", "autoplay", "target" }) do
	local f = OPS[name]
	OPS[name] = function(S, op)
		if S.B.self.session:halted() then return end
		return f(S, op)
	end
end

-- Which dt a frame has (a pure function of the frame number and the scenario seed, so that dropping ops does not
-- change the rhythm of the rest)
local function dt_of(sc, frame, mode_override)
	local mode = mode_override or sc.dt_mode
	if mode == "60" then return 1 / 60
	elseif mode == "30" then return 1 / 30
	elseif mode == "10" then return 1 / 10
	elseif mode == "500" then return 0.5
	elseif mode == "3000" then return 3
	end
	local h = rng.fold_seed(sc.seed, frame, 7) % 1000
	if mode == "spike" then
		if h < 12 then return 0.5 elseif h < 18 then return 3 end
		return 1 / 60
	end
	-- mixed: the rhythm changes every 50 frames
	local g = rng.fold_seed(sc.seed, math.floor(frame / 50), 11) % 100
	if g < 35 then return 1 / 60 elseif g < 55 then return 1 / 30 elseif g < 75 then return 1 / 10
	elseif g < 90 then return 0.5 end
	return 3
end

-- A random scenario: {seed, params, source, dt_mode, ops, desc}. opts: {source = "board" | "level" | "any",
-- level = n, ops = n, dt_mode = "..."}.
function M.scenario(seed, opts)
	opts = opts or {}
	local r = stream(seed, 1)
	local sc = { seed = seed, ops = {} }
	local source = opts.source or "any"
	if source == "any" then
		local k = r.int(100)
		source = k <= 30 and "board" or (k <= 60 and "level" or "combo")
	end
	sc.source = source
	local W, Hh
	if source == "board" or source == "combo" then
		local lvl, lines, first, left = gen_board(r, opts, source)
		sc.params = { level = 1, level_text = lvl }
		sc.picture = lines
		sc.first_swap = first
		sc.moves_left = left
		W, Hh = #lines[1], #lines
	else
		local n = r.range(1, 100)
		if opts.level then n = opts.level end
		sc.params = { level = n }
		sc.level = n
	end
	-- (every choice is drawn before an option overrides it: a seed means the same thing with or without options)
	local dt_mode, n_ops = r.pick(M.DT_MODES), r.range(6, 22)
	local end_mode = r.pick({ "settle", "settle", "win", "win", "give_up", "continue" })
	local rest_checks, run = r.chance(0.5), r.chance(0.25)
	local skippy, blinky = r.chance(0.5), r.chance(0.3)
	sc.dt_mode = opts.dt_mode or dt_mode
	sc.n_ops = opts.ops or n_ops
	sc.W, sc.Hh = W, Hh
	sc.end_mode = opts.end_mode or end_mode
	if opts.rest_checks ~= nil then rest_checks = opts.rest_checks ~= 0 end
	sc.rest_checks = rest_checks
	sc.run = source == "level" and run -- a meta attempt behind the level (the start window's params)
	if opts.skippy ~= nil then skippy = opts.skippy ~= 0 end
	if opts.blinky ~= nil then blinky = opts.blinky ~= 0 end
	sc.skippy, sc.blinky = skippy, blinky
	return sc, r
end

-- Fills sc.ops (needs the board size, which a level file only tells once it is loaded).
function M.fill_ops(sc, B, r)
	if #sc.ops > 0 or sc.fixed_ops then return end
	local W, Hh = board_dims(B)
	local function cx() return r.range(1, W) end
	local function cy() return r.range(1, Hh) end
	local function cell() return cx(), cy() end
	local function wait()
		return { op = "frames", sec = r.pick({ 0, 0.02, 0.1, 0.3, 0.6, 1.0, 2.0 }) }
	end
	if sc.first_swap then
		local f = sc.first_swap
		sc.ops[#sc.ops + 1] = { op = "frames", sec = r.pick({ 0.1, 0.5, 1.0 }) }
		sc.ops[#sc.ops + 1] = { op = "swap", x1 = f.x1, y1 = f.y1, x2 = f.x2, y2 = f.y2 }
		sc.ops[#sc.ops + 1] = wait()
	end
	for _ = 1, sc.n_ops do
		local k = r.int(100)
		local ops = sc.ops
		if k <= 14 then
			ops[#ops + 1] = { op = "hint" }
		elseif k <= 24 then
			local x, y = cell()
			local dir = r.pick({ "l", "r", "u", "d" })
			ops[#ops + 1] = { op = "swipe", x = x, y = y, dir = dir }
		elseif k <= 32 then
			local x, y = cell()
			local nx, ny = x, y
			local d = r.int(4)
			if d == 1 then nx = x + 1 elseif d == 2 then nx = x - 1 elseif d == 3 then ny = y + 1 else ny = y - 1 end
			ops[#ops + 1] = { op = "swap", x1 = x, y1 = y, x2 = nx, y2 = ny }
		elseif k <= 42 then
			ops[#ops + 1] = { op = "tap_special", k = r.int(8) }
		elseif k <= 46 then
			ops[#ops + 1] = { op = "touch_special", k = r.int(8) }
		elseif k <= 50 then
			local x, y = cell()
			ops[#ops + 1] = { op = "tap", x = x, y = y }
		elseif k <= 66 then
			local id = r.pick({ "stick", "row_light", "col_light", "remix", "swap" })
			local op = { op = "booster", id = id, args = {} }
			local x, y = cell()
			if id == "stick" then op.args = { x, y }
			elseif id == "row_light" then op.args = { y }
			elseif id == "col_light" then op.args = { x }
			elseif id == "swap" then
				local x2, y2 = cell()
				op.args = { x, y, x2, y2 }
			end
			if r.chance(0.7) then ops[#ops + 1] = { op = "settle", sec = 20 } end
			ops[#ops + 1] = op
		elseif k <= 70 then
			local id = r.pick({ "stick", "row_light", "col_light", "swap" })
			local x, y = cell()
			local x2, y2 = cell()
			if r.chance(0.7) then ops[#ops + 1] = { op = "settle", sec = 20 } end
			ops[#ops + 1] = { op = "target", id = id, x = x, y = y, x2 = x2, y2 = y2, cancel = r.chance(0.2) }
		elseif k <= 76 then
			ops[#ops + 1] = { op = "touch_skip" }
		elseif k <= 79 then
			ops[#ops + 1] = { op = "skip" }
		elseif k <= 84 then
			ops[#ops + 1] = { op = "hold", on = true, bus = r.chance(0.5) }
			ops[#ops + 1] = wait()
			ops[#ops + 1] = { op = "hold", on = false, bus = r.chance(0.5) }
		elseif k <= 90 then
			ops[#ops + 1] = { op = "pause", on = true }
			ops[#ops + 1] = wait()
			ops[#ops + 1] = { op = "pause", on = false }
		elseif k <= 92 then
			ops[#ops + 1] = { op = "win" }
		elseif k <= 94 then
			local x, y = cell()
			local x2, y2 = cell()
			ops[#ops + 1] = { op = "answer", action = r.pick({ "continue", "give_up", "booster", "booster" }), riff = r.chance(0.5),
				id = r.pick({ "stick", "row_light", "col_light", "remix", "swap" }), x = x, y = y, x2 = x2, y2 = y2 }
		elseif k <= 96 then
			ops[#ops + 1] = { op = "autoplay", n = r.range(1, 3) }
		elseif k <= 98 then
			ops[#ops + 1] = r.chance(0.5) and { op = "stall", sec = r.pick({ 0.5, 3 }) } or { op = "tab_sleep", sec = r.pick({ 0.5, 3, 10 }) }
		elseif k <= 99 then
			local pick = r.int(10)
			if pick <= 3 then
				ops[#ops + 1] = { op = "restart" }
			elseif pick <= 6 then
				ops[#ops + 1] = { op = "resize", k = r.int(6) }
			else
				ops[#ops + 1] = { op = "setting", key = "reduced_motion", value = r.chance(0.5) }
			end
		else
			ops[#ops + 1] = { op = "setting", key = "input_mode", value = r.pick({ "swipe", "taptap" }) }
		end
		ops[#ops + 1] = wait()
	end
end

-- Plays a scenario. Returns {leaks, findings, errors, story, state, frames, tail, sim}:
--   leaks     the oracle's list at the end (and at the rest checks in between)
--   findings  structural findings met while stepping (frame_check)
--   error     the message of an error that stopped the run (strict: any error of the board's cosmetic code)
function M.play(sc, opts)
	opts = opts or {}
	local res = { leaks = {}, findings = {}, story = {}, sc = sc, rests = {} }
	local params = sc.params
	if sc.run then
		-- what the start window hands the level screen (client/flow.lua): a run of the meta, the level text
		params = function(a)
			local flow = require("client.flow")
			local n = sc.level
			H.advance_to(a.meta, n)
			local ref, info = flow.level_ref(n)
			local run = a.meta:start_level(ref, {}, a.now())
			return { level_id = n, level = n, run = run, level_text = info and info.text or nil, from = "town" }
		end
	end
	local ok, err = xpcall(function()
		M.with_board(params, function(B)
			B.slow = sc.dt_mode == "500" or sc.dt_mode == "3000" or sc.dt_mode == "mixed" or sc.dt_mode == "spike"
			if opts.setup then opts.setup(B) end -- (tests: break something on purpose and see the oracle say so)
			local S = { B = B, sc = sc }
			local frame_no = 0
			function S.dt() frame_no = frame_no + 1 return dt_of(sc, frame_no, S.dt_override) end
			function S.step(dt)
				dt = dt or S.dt()
				B.step(dt)
				return dt
			end
			-- let `sec` seconds of dt-time pass (at least one frame when sec > 0)
			function S.run_time(sec)
				if sec <= 0 then return end
				local acc = 0
				local n = 0
				while acc < sec and n < 2000 do
					acc = acc + S.step()
					n = n + 1
				end
			end
			-- steps until the core rests (or max_sec of dt-time pass)
			function S.settle(max_sec)
				local acc = 0
				local game = B.game()
				while acc < max_sec do
					if game:is_stable() then return true end
					acc = acc + S.step()
				end
				return game:is_stable()
			end
			-- stepping at rest: board time of `secs` (the board clamps a frame to 0.25 s)
			function S.quiet(secs)
				local t0 = B.self.t
				local n = 0
				while B.self.t - t0 < secs and n < 4000 do
					S.step()
					n = n + 1
				end
			end
			-- The level plays on for `sec` of dt-time; a scenario that is "skippy" taps the board now and then (the tap that
			-- skips the final concert), one that is "blinky" loses and regains the focus now and then
			function S.play_on(sec)
				local acc = 0
				local n = 0
				while acc < sec and n < 2000 do
					acc = acc + S.step()
					n = n + 1
					local h = rng.fold_seed(sc.seed, B.frames, 13) % 1000
					local st = B.state()
					if sc.skippy and (st == "won_wait" or st == "concert") and h < 40 then
						OPS.touch_skip(S)
					end
					if sc.blinky and h >= 40 and h < 60 then
						if B.self.session.hold then
							bus.publish("app_focus", { focused = true })
						else
							bus.publish("app_focus", { focused = false })
						end
					end
				end
				if B.self.session.hold then bus.publish("app_focus", { focused = true }) end
			end
			-- Rest check: the board is stable, the session runs, wait M.QUIET s of board time, ask the oracle. The time
			-- the effects need after the board is stable is measured: that is `tail`.
			function S.rest_check(label, final)
				local game = B.game()
				local h = B.hud
				local st0 = B.state()
				if st0 == "won_wait" or st0 == "concert" then return nil end -- the concert is not a rest
				if not final and (h.pause or h.moves or h.ended or B.self.session.hold) then return nil end
				B.self.session:autoplay(false) -- the autoplay (a QA helper) would go on moving during the wait
				if not S.settle(40) then return nil end
				local t_stable = B.self.t
				local tail = nil
				local n = 0
				-- a frame is "busy" while an effect runs, waits, draws or burns (a session held by a window stops the ticks the
				-- effects follow: how long they need says nothing then, what they still DRAW is the business of rest_vfx)
				local function busy()
					local vfx = B.self.vfx
					if held_by_window(B) then return false end
					if #vfx.active > 0 or #vfx.heap > 0 or #vfx.shakes > 0 then return true end
					if #B.E.running_particles() > 0 then return true end
					return false
				end
				while B.self.t - t_stable < M.QUIET and n < 4000 do
					S.step()
					n = n + 1
					if busy() then tail = B.self.t - t_stable end
				end
				local R = M.leak_report(B, { rest = true })
				R.label, R.tail, R.state = label, tail, B.state()
				res.rests[#res.rests + 1] = { label = label, tail = tail, n = #R.leaks, state = R.state }
				-- a frame longer than 0.25 s moves the game by 6 ticks at most (client/level_session.lua): the effects that
				-- follow the ticks then take 2.5 times as long in board time, which is slowness, not a trace
				local limit = M.LATE * ((sc.dt_mode == "500" or sc.dt_mode == "3000" or sc.dt_mode == "mixed" or sc.dt_mode == "spike") and 2.5 or 1)
				if tail and tail > limit then
					R.leaks[#R.leaks + 1] = { kind = "late_cleanup", text = string.format("the effects needed %.2f s after the board rested (limit %.1f s)", tail, limit) }
				end
				res.tail_max = math.max(res.tail_max or 0, tail or 0)
				return R
			end
			res.S = S

			if sc.moves_left then B.game().s.moves_left = sc.moves_left end -- (the last move: the test of the existing suite does it too)
			local r = stream(sc.seed, 2)
			M.fill_ops(sc, B, r)
			local rests = {}
			for i, op in ipairs(sc.ops) do
				B.op = i
				res.story[#res.story + 1] = op
				local f = OPS[op.op]
				if f then f(S, op) end
				-- an occasional rest check between ops (it changes the timeline: it is part of the scenario)
				if sc.rest_checks and op.op == "frames" and i % 7 == 0 then
					local R = S.rest_check("op " .. i, false)
					if R and #R.leaks > 0 then rests[#rests + 1] = R end
				end
			end
			B.op = #sc.ops + 1
			-- the end: the pause window closed, the app in front, then the level is taken where the end mode says
			B.hud.pause = false
			if B.self.session.hold then
				bus.publish("app_focus", { focused = true })
				B.self.session:set_hold(false)
			end
			B.apply_pause()
			S.step()
			local em = sc.end_mode
			if em == "win" then B.self.session:qa("win", {}) end
			if em == "give_up" then
				if B.hud.moves then OPS.answer(S, { action = "give_up" }) else B.self.session:qa("give_up", {}) end
			end
			local continues, spins = 0, 0
			local tick0, frame0 = B.self.session.tick, B.frames
			while B.self.session.tick - tick0 < 7200 and B.frames - frame0 < 4000 and spins < 400 do
				spins = spins + 1 -- (a round that moves nothing must not go on for ever)
				S.settle(40)
				local st = B.state()
				if st == "complete" or st == "lost" then break end
				if st == "won_wait" or st == "concert" then
					S.play_on(1.0) -- the concert plays out (the board is "stable" between its rounds)
				elseif st == "out_of_moves" then
					if em == "settle" then break end -- the moves window stays open: a legitimate place to rest
					if not B.hud.moves then
						-- no window: a booster is still aimed. The player cancels it and the offer is back (level.gui_script)
						B.link.cancel_booster()
						S.step()
						if not B.hud.moves and B.state() == "out_of_moves" then
							B.hud.moves = true
							B.apply_pause()
						end
					end
					if em == "continue" and continues < 2 then
						continues = continues + 1
						OPS.answer(S, { action = "continue", riff = true })
						B.self.session:qa("autoplay", { 3 })
					else
						OPS.answer(S, { action = "give_up" })
					end
				elseif B.self.session.auto then
					S.play_on(2.0)
				else
					break
				end
			end
			local R = S.rest_check("end", true)
			res.final_state = B.state()
			res.final = R
			if R then
				for _, l in ipairs(R.leaks) do res.leaks[#res.leaks + 1] = l end
			end
			for _, R2 in ipairs(rests) do
				for _, l in ipairs(R2.leaks) do
					l.text = "[" .. R2.label .. " " .. tostring(R2.state) .. "] " .. l.text
					res.leaks[#res.leaks + 1] = l
				end
			end
			res.findings = B.findings
			res.events = B.events
			res.final_hud = { moves = B.hud.moves, ended = B.hud.ended, state = B.hud.state }
			res.restarts = B.restarts
			res.max_burst = B.max_burst
			res.log = B.log
			res.frames = B.frames
			res.vfx = B.self.vfx:stats()
			res.view = B.self.view:stats()
			res.janitor = { passes = B.self.janitor_passes or 0, repairs = B.self.janitor_repairs or 0 }
			res.board = B
		end, opts.board)
	end, debug.traceback)
	if not ok then res.error = err end
	if ok and opts.gui ~= false and res.events then
		local g = M.replay_gui(res.events, {})
		res.gui = g
		if g.error then
			res.leaks[#res.leaks + 1] = { kind = "gui_error", text = tostring(g.error):sub(1, 300) }
		end
		for _, l in ipairs(g.leaks) do res.leaks[#res.leaks + 1] = l end
	end
	return res
end

-- THE GUI OVERLAY. The overlay of the level (screens/level/level_fx.gui_script: praise words, combo titles, banners,
-- screen flashes, the "tap to skip" hint, the confetti of the concert) is a GUI scene, and the strict stub shows one scene
-- at a time. So the bus events the board published (B.events, with the board time they were published at) are played into
-- the real script afterwards, on the engine-like GUI stub of tests/client/town_defold_stub.lua (it keeps real animation
-- semantics: one animation per property, a script node takes no alpha from its parent). What is left on the scene a few
-- seconds after the last event, when the level is not in its concert, is a leak. opts: {tail = 8 (seconds to wait)}.
-- Returns {leaks = {{kind = "gui_leftover", text}}, nodes = n, frames = n}.
function M.replay_gui(events, opts)
	opts = opts or {}
	local town = require("tests.client.town_defold_stub")
	local res = { leaks = {}, frames = 0 }
	local PATH, GUI = "screens/level/level_fx.gui_script", "/screens/level/level_fx.gui"
	local TOPICS = { level_praise = true, level_banner = true, level_flash = true, level_state = true, level_special = true }
	local E = town.boot({ language = "en" })
	local ok, err = xpcall(function()
		local script = E.script(PATH, GUI)
		script:init()
		local baseline = {}
		for _, n in ipairs(E.alive_nodes(E.scene(GUI))) do baseline[n] = true end
		local clock, last_state = 0, nil
		for _, ev in ipairs(events) do
			if TOPICS[ev.topic] or ev.topic == "@setting" then
				local gap = ev.t - clock
				if gap > 0 then
					local frames = math.min(math.floor(gap * 60 + 0.5), 900)
					script:step(frames)
					res.frames = res.frames + frames
					clock = ev.t
				end
				if ev.topic == "@setting" then
					if ev.payload.key == "reduced_motion" then app.set_setting("reduced_motion", ev.payload.value) end
				else
					bus.publish(ev.topic, ev.payload)
					if ev.topic == "level_state" then last_state = ev.payload.state end
				end
			end
		end
		script:step(1)
		if last_state ~= "concert" and last_state ~= "won_wait" then
			script:step(math.floor((opts.tail or 8) * 60))
			res.frames = res.frames + math.floor((opts.tail or 8) * 60)
			for _, n in ipairs(E.alive_nodes(E.scene(GUI))) do
				if not baseline[n] and E.visible(n) and E.opacity(n) > 0.02 then
					local drawn = (n.kind == "text" and n.text ~= nil and n.text ~= "") or (n.kind == "box" and n.size.x > 0 and n.size.y > 0)
					if drawn then
						res.leaks[#res.leaks + 1] = { kind = "gui_leftover", text = string.format("%s node %s alpha %.2f at %.0f,%.0f is still on the overlay %d s after the last event (state %s)",
							n.kind, tostring(n.text or n.id or "?"), E.opacity(n), n.pos.x, n.pos.y, opts.tail or 8, tostring(last_state)) }
					end
				end
			end
		end
		res.nodes = #E.alive_nodes(E.scene(GUI))
		pcall(function() script:final() end)
	end, debug.traceback)
	town.shutdown()
	if not ok then res.error = err end
	return res
end

-- Drops ops (in chunks, then one by one) while pred(res) stays true. Returns a smaller scenario and true, or the
-- scenario itself and false when it does not satisfy pred to begin with. The frame rhythm is a function of the frame
-- number, so a shorter list of ops keeps the rhythm of the frames that are left; the ops that are left are replayed, not
-- drawn again (sc.fixed_ops).
function M.shrink(sc, pred, opts)
	opts = opts or {}
	if #sc.ops == 0 then M.play(sc, opts) end -- (the ops are drawn when a scenario is played the first time)
	local cur = {}
	for k, v in pairs(sc) do cur[k] = v end -- order-independent
	cur.ops = {}
	for i, op in ipairs(sc.ops) do cur.ops[i] = op end
	cur.rest_checks = false
	cur.fixed_ops = true
	local function holds(list)
		local t = {}
		for k, v in pairs(cur) do t[k] = v end -- order-independent
		t.ops = list
		return pred(M.play(t, opts))
	end
	if not holds(cur.ops) then return sc, false end
	local n = 2
	while #cur.ops >= 2 do
		local size = math.max(1, math.ceil(#cur.ops / n))
		local reduced = false
		local i = 1
		while i <= #cur.ops do
			local trial = {}
			for j, op in ipairs(cur.ops) do
				if j < i or j >= i + size then trial[#trial + 1] = op end
			end
			if #trial > 0 and #trial < #cur.ops and holds(trial) then
				cur.ops = trial -- (i stays: the next chunk has moved into place)
				reduced = true
			else
				i = i + size
			end
		end
		if not reduced then
			if size == 1 then break end
			n = math.min(#cur.ops, n * 2)
		end
	end
	return cur, true
end

-- A line for a story
function M.op_text(op)
	local parts = { op.op }
	local keys = {}
	for k in pairs(op) do if k ~= "op" then keys[#keys + 1] = k end end -- order-independent
	table.sort(keys)
	for _, k in ipairs(keys) do
		local v = op[k]
		if type(v) == "table" then
			local items = {}
			for _, x in ipairs(v) do items[#items + 1] = tostring(x) end
			v = "{" .. table.concat(items, ",") .. "}"
		end
		parts[#parts + 1] = k .. "=" .. tostring(v)
	end
	return table.concat(parts, " ")
end

return M
