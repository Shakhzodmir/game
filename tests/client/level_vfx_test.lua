-- client/level_vfx.lua and client/level_view.lua on the strict Defold stub:
-- the pools of sprites and particle bursts, the limits of game.project, the
-- order of the effect commands and the cost of an idle frame.

local stub = require("tests.client.level_defold_stub")
local level_effects = require("client.level_effects")
local level_anim = require("client.level_anim")
local geom = require("client.level_geom")

-- these modules need the Defold globals when they load (vmath.vector3...)
local level_vfx, level_view
local function load_modules()
	level_vfx = require("client.level_vfx")
	level_view = require("client.level_view")
end

local function G()
	local cells = {}
	for i = 1, 81 do cells[i] = { exists = true } end
	return geom.new(9, 9, cells, { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })
end

-- runs fn(E, vfx, g) with the stub installed; always restores the globals
local function with_vfx(fn, opts)
	local E = stub.install({})
	local ok, err = pcall(function()
		load_modules()
		local g = G()
		local gui_calls = {}
		local slow = {}
		local vfx = level_vfx.new({
			geom = g, reduced = opts and opts.reduced,
			on_gui = function(c) gui_calls[#gui_calls + 1] = c end,
			on_slowmo = function(d, s) slow[#slow + 1] = { d, s } end,
		})
		fn(E, vfx, g, gui_calls, slow)
	end)
	stub.restore()
	if not ok then error(err, 0) end
end

local function pops(n, at, x)
	local list = {}
	for i = 1, n do list[i] = { kind = "burst", fx = "pop", x = (x or 100) + i, y = 500, color = "#FF4468", count = 10, at = at or 0 } end
	return list
end

describe("client.level_vfx", function()
	it("starts the commands in the order of their ticks, ties in arrival order", function()
		with_vfx(function(E, vfx, g, gui)
			vfx:play({ { kind = "praise", word = "hit", index = 2, at = 30 }, { kind = "banner", key = "hud.shuffle", at = 10 },
				{ kind = "praise", word = "juicy", index = 1, at = 10 }, { kind = "floor", x = 1, y = 1, at = 20 } })
			vfx:update(1 / 60, 9, 0.1)
			assert_eq(#gui, 0)
			vfx:update(1 / 60, 10, 0.2)
			assert_eq(#gui, 2)
			assert_eq(gui[1].key, "hud.shuffle") -- arrived first
			assert_eq(gui[2].word, "juicy")
			vfx:update(1 / 60, 25, 0.3)
			assert_eq(gui[3].kind, "floor")
			vfx:update(1 / 60, 100, 0.4)
			assert_eq(gui[4].word, "hit")
		end)
	end)

	it("keeps every kind of burst inside its pool and never passes the particle budget", function()
		with_vfx(function(E, vfx)
			vfx:play(pops(60))
			vfx:update(1 / 60, 1, 0.0)
			local st = vfx:stats()
			assert_true(st.particles <= level_vfx.MAX_PARTICLES, "live particles " .. st.particles)
			assert_eq(st.particles, level_vfx.CAP.pop * level_vfx.PARTICLES.pop) -- 24 bursts of 10
			assert_eq(st.skipped, 60 - level_vfx.CAP.pop)
			-- one particlefx component per game object, never past game.project
			assert_true(E.n_particlefx <= level_vfx.CAP.pop)
			-- every kind has its own pool
			local kinds = { "sparkle", "debris", "dust", "confetti", "spark" }
			vfx:update(1 / 60, 2, 5.0) -- the pops are over
			for _, k in ipairs(kinds) do
				vfx:play({ { kind = "burst", fx = k, x = 100, y = 500, color = "#FFFFFF", count = 4, at = 0 } })
			end
			vfx:update(1 / 60, 3, 5.0)
			assert_true(E.n_particlefx <= level_vfx.CAP.pop + #kinds)
			-- the sum of every pool at its cap fits the engine
			local comps, emitters = 0, 0
			for _, k in ipairs(level_vfx.KINDS) do
				comps = comps + level_vfx.CAP[k]
				emitters = emitters + level_vfx.CAP[k] * #level_vfx.EMITTERS[k]
			end
			assert_true(comps <= E.limits.particlefx, "components " .. comps)
			assert_true(emitters <= E.limits.emitters, "emitters " .. emitters)
		end)
	end)

	it("budgets each burst with exactly the particles and the lifetime its effect has", function()
		with_vfx(function(E, vfx)
			local t = 0
			for _, k in ipairs(level_vfx.KINDS) do
				E.counts.particles_total = 0
				E.batches = {}
				vfx:play({ { kind = "burst", fx = k, x = 100, y = 500, color = "#FFFFFF", count = 4, at = 0 } })
				t = t + 5
				vfx:update(1 / 60, 1, t)
				assert_eq(E.counts.particles_total, level_vfx.PARTICLES[k], k .. ": particles in assets/fx_defold")
				-- the object is busy for LIFE: longer than the longest particle of the effect
				local longest = 0
				for _, b in ipairs(E.batches) do
					if b.untilt - b.from > longest then longest = b.untilt - b.from end
				end
				assert_true(level_vfx.LIFE[k] >= longest, k .. ": LIFE " .. level_vfx.LIFE[k] .. " < " .. longest)
			end
		end)
	end)

	it("reuses a burst object once its particles are gone", function()
		with_vfx(function(E, vfx)
			vfx:play(pops(5, 0))
			vfx:update(1 / 60, 1, 0.0)
			local made = E.counts.factory_create
			assert_eq(made, 5)
			vfx:play(pops(5, 2))
			vfx:update(1 / 60, 3, 0.2) -- the first five are still busy
			assert_eq(E.counts.factory_create, 10)
			vfx:update(1 / 60, 4, 2.0)
			vfx:play(pops(5, 5))
			vfx:update(1 / 60, 6, 2.1) -- both groups are over: no new objects
			assert_eq(E.counts.factory_create, 10)
		end)
	end)

	it("tints every emitter of every kind of burst with the colour it was asked for, after the play", function()
		with_vfx(function(E, vfx)
			local colors = { pop = "#FF4468", sparkle = "#FFD84D", debris = "#B07A45", dust = "#C9C2D6",
				confetti = "#3AA4FF", spark = "#2BE38F" }
			for _, k in ipairs(level_vfx.KINDS) do
				vfx:play({ { kind = "burst", fx = k, x = 100, y = 500, color = colors[k], count = 4, at = 0 } })
			end
			vfx:update(1 / 60, 1, 0.0)
			-- the strict stub raises when a constant is set on an effect that is not playing (the engine drops it)
			assert_eq(E.counts.particlefx_set_constant_lost, nil)
			for _, k in ipairs(level_vfx.KINDS) do
				local list = E.by_factory(k .. "_factory")
				assert_eq(#list, 1, k)
				local comp = list[1].proto.comps.fx
				local r, g, b = level_view.rgb(colors[k])
				for _, em in ipairs(level_vfx.EMITTERS[k]) do
					local t = comp.tints[em]
					assert_true(t ~= nil, k .. "/" .. em .. ": no tint reached the playing effect")
					assert_true(math.abs(t.x - r) < 1e-6 and math.abs(t.y - g) < 1e-6 and math.abs(t.z - b) < 1e-6,
						k .. "/" .. em .. ": wrong tint")
					assert_eq(t.w, 1)
				end
			end
			-- what the offline renderer would draw is the asked colour, not the white of the image
			local snap = E.snapshot()
			assert_eq(#snap.particles, 7) -- pop has two emitters, the other five kinds one
			for _, p in ipairs(snap.particles) do
				assert_true(not (p.r == 1 and p.g == 1 and p.b == 1), p.kind .. "/" .. p.emitter .. " is still white")
			end
		end)
	end)

	it("tints a reused burst object again, although its previous instance was pruned by the engine", function()
		with_vfx(function(E, vfx)
			vfx:play({ { kind = "burst", fx = "pop", x = 100, y = 500, color = "#FF4468", count = 4, at = 0 } })
			vfx:update(1 / 60, 1, 0.0)
			assert_eq(E.counts.factory_create, 1)
			E.advance(level_vfx.LIFE.pop + 0.05) -- the engine prunes the sleeping instance
			vfx:play({ { kind = "burst", fx = "pop", x = 200, y = 500, color = "#3AA4FF", count = 4, at = 0 } })
			vfx:update(1 / 60, 2, level_vfx.LIFE.pop + 0.05)
			assert_eq(E.counts.factory_create, 1, "the object is reused")
			assert_eq(E.counts.particlefx_play_overlap, nil, "the pool reused an object whose instance was still alive")
			local comp = E.by_factory("pop_factory")[1].proto.comps.fx
			local r, g, b = level_view.rgb("#3AA4FF")
			for _, em in ipairs(level_vfx.EMITTERS.pop) do
				local t = comp.tints[em]
				assert_true(t and math.abs(t.x - r) < 1e-6 and math.abs(t.z - b) < 1e-6, em .. ": the new colour is lost")
			end
		end)
	end)

	it("keeps a burst object busy longer than the engine keeps its particle instance", function()
		with_vfx(function(E, vfx)
			for _, k in ipairs(level_vfx.KINDS) do
				vfx:play({ { kind = "burst", fx = k, x = 100, y = 500, color = "#FFFFFF", count = 4, at = 0 } })
			end
			vfx:update(1 / 60, 1, 0.0)
			for _, k in ipairs(level_vfx.KINDS) do
				local comp = E.by_factory(k .. "_factory")[1].proto.comps.fx
				local inst = comp.instances[#comp.instances]
				-- start delay + emission + the longest particle life: when the engine drops the instance
				assert_true(level_vfx.LIFE[k] >= inst.alive_until - E.time,
					k .. ": LIFE " .. level_vfx.LIFE[k] .. " < the instance's " .. (inst.alive_until - E.time))
			end
		end)
	end)

	it("halves the particles of a slow device (lite) and under reduced motion", function()
		with_vfx(function(E, vfx)
			vfx:set_lite(true)
			vfx:play(pops(40))
			vfx:update(1 / 60, 1, 0.0)
			assert_true(vfx:stats().particles <= level_vfx.MAX_PARTICLES_LITE)
			assert_true(vfx:stats().lite)
		end)
		with_vfx(function(E, vfx)
			vfx:play(pops(20))
			vfx:update(1 / 60, 1, 0.0)
			assert_eq(vfx:stats().particles, 100) -- every other pop is skipped
		end, { reduced = true })
	end)

	it("pools its effect sprites: a thousand flashes never create more than MAX_SPRITES", function()
		with_vfx(function(E, vfx)
			local t = 0
			for i = 1, 1000 do
				vfx:play({ { kind = "flash", x = 200, y = 600, size = 100, color = "#FFFFFF", at = 0, dur = 0.3 } })
				t = t + 0.01
				vfx:update(0.01, i, t)
			end
			assert_true(vfx:stats().sprites <= level_vfx.MAX_SPRITES)
			assert_true(E.n_sprites <= level_vfx.MAX_SPRITES)
			-- and they all come back when the effects are over
			vfx:update(0.5, 2000, t + 5)
			assert_eq(vfx:stats().active, 0)
		end)
	end)

	it("plays every kind of command of the effects without an engine error", function()
		with_vfx(function(E, vfx, g, gui, slow)
			local fx = level_effects.new({ geom = g })
			local cmds = {}
			local function ev(e) fx:event(e) end
			ev({ type = "activate", t = 1, id = 1, x = 5, y = 5, special = "disco", combo = "finale", partner = 2 })
			for r = 0, 4 do ev({ type = "ring", t = 1, x = 5, y = 5, r = r, at = 25 + 2 * r }) end
			ev({ type = "activate", t = 1, id = 3, x = 3, y = 3, special = "sub" })
			ev({ type = "bolt", t = 1, x = 3, y = 3, dir = "r", at = 1 })
			ev({ type = "bolt", t = 1, x = 3, y = 3, dir = "u", at = 1 })
			ev({ type = "bird_fly", t = 1, x = 2, y = 2, tx = 8, ty = 7, carry = "sub", duration = 33 })
			ev({ type = "disco_ray", t = 1, x = 5, y = 5, tx = 1, ty = 1 })
			ev({ type = "transform", t = 1, id = 9, x = 4, y = 4, special = "riff", axis = "h" })
			ev({ type = "destroy", t = 1, id = 4, x = 2, y = 2, item = "column" })
			ev({ type = "freed", t = 1, id = 5, x = 6, y = 6 })
			ev({ type = "floor_lit", t = 1, x = 7, y = 7 })
			ev({ type = "mic_delivered", t = 1, id = 6, x = 8, y = 9 })
			ev({ type = "noise_spread", t = 1, fx = 1, fy = 1, x = 1, y = 2, id = 7 })
			ev({ type = "praise", t = 1, act = 1, wave = 5, word = "hit" })
			ev({ type = "state", t = 1, state = "won_wait" })
			vfx:play(fx:drain())
			local seen = {}
			for tick = 0, 90 do
				vfx:update(1 / 60, tick, tick / 60)
			end
			for _, c in ipairs(gui) do seen[c.kind] = true end
			assert_true(seen.praise and seen.screen_flash and seen.floor)
			assert_eq(#slow, 1) -- the finale slows the session down once
			assert_eq(slow[1][1], 0.4)
			assert_eq(slow[1][2], 0.5)
			vfx:update(1 / 60, 500, 20) -- everything is over
			assert_eq(vfx:stats().active, 0)
			assert_eq(vfx:stats().pending, 0)
		end)
	end)

	it("shakes the board and lets the shake die down", function()
		with_vfx(function(E, vfx)
			vfx:play({ { kind = "shake", amp = 10, dur = 0.5, at = 0 } })
			local sx, sy = vfx:update(1 / 60, 1, 0.0)
			local moved = false
			local t = 0
			for i = 1, 20 do
				t = t + 0.02
				sx, sy = vfx:update(0.02, 1 + i, t)
				if math.abs(sx) > 0.5 or math.abs(sy) > 0.5 then moved = true end
				assert_true(math.abs(sx) <= 10 and math.abs(sy) <= 10)
			end
			assert_true(moved)
			sx, sy = vfx:update(0.02, 40, 1.0)
			assert_eq(sx, 0)
			assert_eq(sy, 0)
			-- reduced motion: no shake at all
		end)
		with_vfx(function(E, vfx)
			vfx:play({ { kind = "shake", amp = 10, dur = 0.5, at = 0 } })
			local sx = vfx:update(1 / 60, 1, 0.0)
			sx = vfx:update(1 / 60, 2, 0.1)
			assert_eq(sx, 0)
		end, { reduced = true })
	end)

	it("clears everything on skip", function()
		with_vfx(function(E, vfx)
			vfx:play({ { kind = "flash", x = 1, y = 1, size = 100, color = "#FFFFFF", at = 0, dur = 2 },
				{ kind = "burst", fx = "pop", x = 5, y = 5, color = "#FF0000", count = 10, at = 0 },
				{ kind = "praise", word = "hit", index = 2, at = 500 } })
			vfx:update(1 / 60, 1, 0.0)
			assert_true(vfx:stats().active > 0)
			vfx:clear()
			assert_eq(vfx:stats().active, 0)
			assert_eq(vfx:stats().pending, 0)
			assert_eq(vfx:stats().particles, 0)
		end)
	end)

	it("judges the frame rate: lite after 2 s of slow frames, full again after 6 s of fast ones", function()
		local E = stub.install({})
		load_modules()
		stub.restore()
		local q = level_vfx.quality()
		for _ = 1, 120 do assert_false(q:frame(1 / 60)) end
		local lite = false
		for _ = 1, 30 do lite = q:frame(1 / 25) end -- 1.2 s of 25 fps: not yet
		assert_false(lite)
		for _ = 1, 90 do lite = q:frame(1 / 25) end
		assert_true(lite)
		for _ = 1, 120 do lite = q:frame(1 / 60) end -- 2 s of 60 fps: still lite (no flapping)
		assert_true(lite)
		for _ = 1, 480 do lite = q:frame(1 / 60) end
		assert_false(lite)
		-- one long frame (a screen load) is not a slow device
		local r = level_vfx.quality()
		r:frame(0.5)
		for _ = 1, 30 do r:frame(1 / 60) end
		assert_false(r.lite)
	end)
end)

-- The effects must never stay on the board: whatever goes wrong inside one of them (the engine refuses a
-- call, a record is lost, the session stops ticking for good), it ends, its sprites go back to the pool
-- hidden and the others carry on. The producer's report: after a Disco ball + Subwoofers combo shock rings
-- stayed on the finished board.
describe("client.level_vfx never leaves an effect behind", function()
	-- effect sprites on screen (the pieces of the board are made by client/level_view.lua, not here)
	local function on_screen(E)
		local n = 0
		for _, name in ipairs({ "piece_factory", "glow_factory" }) do
			for _, o in ipairs(E.by_factory(name)) do
				if E.visible(o) then n = n + 1 end
			end
		end
		return n
	end

	-- advances `seconds` of frames: the clock of the board, and the tick clock too unless `tick` is false
	local function run(vfx, state, seconds, tick, halted)
		for _ = 1, math.floor(seconds * 60) do
			state.t = state.t + 1 / 60
			if tick then state.tick = state.tick + 1 end
			vfx:update(1 / 60, state.tick, state.t, halted)
		end
	end

	local function rings(n, at)
		local list = {}
		for i = 1, n do
			list[i] = { kind = "ring", x = 60 * i, y = 500, size = 200, color = "#FF4FC8", image = "fx_shock", at = at or 0, dur = 0.32 }
		end
		return list
	end

	it("frees an effect whose step fails and keeps the others running", function()
		with_vfx(function(E, vfx)
			local logged = {}
			vfx.log = function(text) logged[#logged + 1] = text end
			vfx:play(rings(4))
			local state = { t = 0, tick = 1 }
			vfx:update(1 / 60, state.tick, state.t)
			assert_eq(vfx:stats().active, 4)
			-- the engine refuses to scale the sprite of the second ring, once
			local victim = E.by_factory("piece_factory")[2]
			local real, refused = go.set_scale, 0
			go.set_scale = function(scale, id)
				if id == victim.id and refused == 0 then
					refused = 1
					error("the engine refused the scale")
				end
				return real(scale, id)
			end
			run(vfx, state, 1 / 60, true)
			go.set_scale = real
			assert_eq(refused, 1)
			assert_eq(vfx:stats().errors, 1)
			assert_eq(#logged, 1)
			assert_true(string.find(logged[1], "the engine refused the scale", 1, true) ~= nil, logged[1])
			assert_eq(vfx:stats().active, 3) -- the failing one is gone, the others were stepped
			assert_false(E.visible(victim), "the sprite of the failed ring is hidden")
			-- they run out; nothing stays on the screen
			run(vfx, state, 1, true)
			assert_eq(vfx:stats().active, 0)
			assert_eq(on_screen(E), 0)
			-- the pool still works: a second wave takes the same four sprites, no sprite is lost or shared
			vfx:play(rings(4, state.tick))
			run(vfx, state, 1 / 60, true)
			assert_eq(vfx:stats().active, 4)
			assert_eq(vfx:stats().sprites, 4)
			assert_eq(on_screen(E), 4)
			run(vfx, state, 1, true)
			assert_eq(vfx:stats().active, 0)
			assert_eq(on_screen(E), 0)
		end)
	end)

	it("leaves no sprite on the screen after an error, however the later effects overlap (the board's guard around update)", function()
		-- the producer's rings: one failed step used to cut the compaction of the list of effects short, a finished record
		-- stayed in it and went back to the pool twice, and a later effect took the record of one that was on the screen
		with_vfx(function(E, vfx)
			vfx.log = function() end
			local state = { t = 0, tick = 1 }
			local function guarded_frame()
				state.t = state.t + 1 / 60
				state.tick = state.tick + 1
				pcall(vfx.update, vfx, 1 / 60, state.tick, state.t) -- screens/level/board.script: guard(self, "vfx update", ...)
			end
			local list = rings(4)
			list[1].dur = 0.01 -- ends after one frame: a finished record in front of the failing one
			vfx:play(list)
			guarded_frame()
			local victim = E.by_factory("piece_factory")[3]
			local real, refused = go.set_scale, 0
			go.set_scale = function(scale, id)
				if id == victim.id and refused == 0 then
					refused = 1
					error("the engine refused the scale")
				end
				return real(scale, id)
			end
			guarded_frame()
			go.set_scale = real
			assert_eq(refused, 1)
			for _ = 1, 120 do guarded_frame() end
			assert_eq(vfx:stats().active, 0)
			-- a second wave, a ring a frame, so that they overlap
			for i = 1, 8 do
				vfx:play({ { kind = "ring", x = 60 * i, y = 700, size = 200, color = "#FF4FC8", image = "fx_shock", at = state.tick, dur = 0.32 } })
				guarded_frame()
			end
			for _ = 1, 180 do guarded_frame() end
			assert_eq(vfx:stats().active, 0)
			assert_eq(on_screen(E), 0, "a sprite stays on the screen with no effect behind it")
			local seen = {}
			for _, r in ipairs(vfx.fx_pool) do
				assert_true(not seen[r], "a record of an effect is in the pool twice")
				seen[r] = true
			end
		end)
	end)

	it("loses only the command whose start fails (the engine refuses a new object)", function()
		with_vfx(function(E, vfx)
			vfx.log = function() end
			local real, refused = factory.create, 0
			factory.create = function(...)
				if refused == 0 then
					refused = 1
					error("max_instances exceeded")
				end
				return real(...)
			end
			vfx:play(rings(3))
			local state = { t = 0, tick = 1 }
			vfx:update(1 / 60, state.tick, state.t)
			factory.create = real
			assert_eq(vfx:stats().errors, 1)
			assert_eq(vfx:stats().active, 2) -- the first ring has no sprite, the other two play
			run(vfx, state, 1, true)
			assert_eq(vfx:stats().active, 0)
			assert_eq(on_screen(E), 0)
		end)
	end)

	it("takes back a sprite that was lost and hides a spare one that was left on the screen", function()
		with_vfx(function(E, vfx)
			local level = require("client.level_view")
			local state = { t = 0, tick = 1 }
			-- an effect lost its sprite (taken from the pool, shown, never given back) ...
			local lost = vfx:_sprite("glow")
			level.apply(lost, "fx_flash", 300, 500, 0.4, 1, 1, 0, 0, nil, 0.8)
			-- ... and a pooled one was left visible (a hide that never reached the engine)
			local spare = vfx:_sprite("piece")
			level.apply(spare, "fx_shock", 200, 500, 0.4, 1, 1, 0, 0, nil, 0.8)
			vfx:_release(spare)
			spare.hidden = false
			local engine = E.by_factory("piece_factory")[1]
			engine.pos.x, engine.pos.y = 200, 500
			assert_eq(on_screen(E), 2)
			run(vfx, state, 1, true) -- a second is plenty
			assert_eq(on_screen(E), 0)
			assert_eq(#vfx.pool.glow, 1) -- the lost one is back in its pool, once
			assert_eq(#vfx.pool.piece, 1)
			assert_true(vfx:stats().repaired >= 2)
			-- and it is used again
			vfx:play({ { kind = "flash", x = 10, y = 10, size = 100, color = "#FFFFFF", at = 0, dur = 0.3 } })
			vfx:update(1 / 60, state.tick, state.t)
			assert_eq(vfx:stats().sprites, 2)
		end)
	end)

	it("never pools a sprite twice", function()
		with_vfx(function(E, vfx)
			local o = vfx:_sprite("glow")
			vfx:_release(o)
			vfx:_release(o)
			assert_eq(#vfx.pool.glow, 1)
			assert_true(vfx:_sprite("glow") == o)
			assert_true(vfx:_sprite("glow") ~= o)
		end)
	end)

	it("hides a sprite for real: a hide the engine refuses is tried again", function()
		with_vfx(function(E, vfx)
			local level = require("client.level_view")
			local o = level.create("#glow_factory")
			level.apply(o, "fx_flash", 300, 500, 0.4, 1, 1, 0, 0, nil, 0.8)
			local inst = E.by_factory("glow_factory")[1]
			assert_true(E.visible(inst))
			local real, refused = go.set_position, 0
			go.set_position = function(p, id)
				if refused == 0 then
					refused = 1
					error("the engine refused the move")
				end
				return real(p, id)
			end
			assert_error(function() level.hide(o) end, "the engine refused")
			go.set_position = real
			assert_false(o.hidden, "a hide that did not happen must not be remembered")
			assert_true(E.visible(inst))
			level.hide(o)
			assert_true(o.hidden)
			assert_false(E.visible(inst))
		end)
	end)

	it("lets the tick effects run out on their own once the game is over (the result window stops the ticks)", function()
		with_vfx(function(E, vfx)
			vfx:play({
				{ kind = "beam", x = 100, y = 500, dx = 1, dy = 0, len = 400, speed = 40, at = 0, color = "#1FD1FF", width = 40,
					core = true, mode = "comet" },
				{ kind = "charge", x = 300, y = 500, size = 200, color = "#FF4FC8", at = 0, dur = 6 },
				{ kind = "reticle", x = 500, y = 500, size = 100, color = "#FF4FC8", at = 0, dur = 33 },
				{ kind = "flash", x = 300, y = 300, size = 100, color = "#FFFFFF", at = 12, dur = 0.3 }, -- due in 8 ticks: the ticks stop first
			})
			local state = { t = 0, tick = 1 }
			vfx:update(1 / 60, state.tick, state.t)
			run(vfx, state, 3 / 60, true)
			assert_eq(vfx:stats().active, 3)
			-- a window pauses the session: the tick stops, the effects wait (that is what a pause is)
			run(vfx, state, 2, false, true)
			assert_eq(vfx:stats().active, 3)
			assert_eq(vfx:stats().pending, 1)
			assert_true(on_screen(E) > 0)
			-- the level is complete: nothing will tick again, so they run out on the real clock
			vfx:finish()
			run(vfx, state, 3, false, true)
			assert_eq(vfx:stats().active, 0)
			assert_eq(vfx:stats().pending, 0)
			assert_eq(on_screen(E), 0)
		end)
	end)

	it("ends an effect whose tick clock never moves, unless the session is held on purpose", function()
		with_vfx(function(E, vfx)
			local state = { t = 0, tick = 1 }
			vfx:play({ { kind = "reticle", x = 500, y = 500, size = 100, color = "#FF4FC8", at = 0, dur = 33 } })
			vfx:update(1 / 60, state.tick, state.t)
			-- a window is open (the game is paused on purpose): it waits as long as it takes
			run(vfx, state, 40, false, true)
			assert_eq(vfx:stats().active, 1)
			assert_true(on_screen(E) > 0)
			-- the tick clock is stuck without a reason: the effect still ends (a few seconds)
			run(vfx, state, 20, false, false)
			assert_eq(vfx:stats().active, 0)
			assert_eq(on_screen(E), 0)
		end)
	end)

	it("plays nothing but words after a skip, and clears what was playing", function()
		with_vfx(function(E, vfx, g, gui, slow)
			local state = { t = 0, tick = 1 }
			vfx:play(rings(3))
			vfx:update(1 / 60, state.tick, state.t)
			assert_eq(vfx:stats().active, 3)
			vfx:skip()
			assert_eq(vfx:stats().active, 0)
			assert_eq(on_screen(E), 0)
			local made = E.counts.factory_create
			vfx:play({
				{ kind = "ring", x = 100, y = 500, size = 200, color = "#FF4FC8", image = "fx_shock", at = 0, dur = 0.32 },
				{ kind = "flash", x = 100, y = 500, size = 100, color = "#FFFFFF", at = 0, dur = 0.3 },
				{ kind = "burst", fx = "pop", x = 5, y = 5, color = "#FF0000", count = 10, at = 0 },
				{ kind = "beam", x = 100, y = 500, dx = 1, dy = 0, len = 400, speed = 40, at = 0, color = "#1FD1FF", width = 40, mode = "comet" },
				{ kind = "shake", amp = 10, dur = 0.5, at = 0 },
				{ kind = "slowmo", dur = 0.4, scale = 0.5, at = 0 },
				{ kind = "screen_flash", color = "#FFFFFF", alpha = 0.9, dur = 0.5, at = 0 },
				{ kind = "praise", word = "hit", index = 2, wave = 5, at = 0 },
				{ kind = "banner", key = "hud.shuffle", at = 0 },
			})
			local sx = vfx:update(1 / 60, state.tick + 1, state.t + 1 / 60)
			assert_eq(vfx:stats().active, 0)
			assert_eq(vfx:stats().pending, 0)
			assert_eq(E.counts.factory_create, made, "no new object for a skipped show")
			assert_eq(sx, 0)
			assert_eq(#slow, 0)
			local kinds = {}
			for _, c in ipairs(gui) do kinds[c.kind] = true end
			assert_true(kinds.praise and kinds.banner, "the words still come")
			assert_true(kinds.screen_flash == nil, "no flash of the whole screen")
			assert_true(vfx:stats().muted >= 6)
		end)
	end)
end)

describe("client.level_view and level_anim in the hot loop", function()
	it("sprites follow the draw list and a frame at rest calls the engine not at all", function()
		local E = stub.install({})
		local ok, err = pcall(function()
			load_modules()
			local g = G()
			local A = level_anim.new({ geom = g })
			local V = level_view.new({})
			local pieces = {}
			for i = 1, 40 do
				pieces[i] = { id = i, x = (i - 1) % 9 + 1, y = math.floor((i - 1) / 9) + 1, kind = "regular",
					color = ({ "red", "orange", "yellow", "green", "blue", "purple" })[i % 6 + 1], state = "idle", offx = 0,
					offy = 0, hidden = false, pinned = false }
			end
			V:sync(A:frame(pieces, 1, 0), 0, 0)
			assert_eq(V:stats().pieces, 40)
			assert_eq(#E.by_factory("piece_factory"), 40)
			E.reset_counts()
			collectgarbage()
			collectgarbage()
			-- The collector is stopped and the LuaJIT compiler is off while measuring: the trace
			-- recorder allocates on its own (it grew this number to 165 KB on a CI runner) and is
			-- not what the test guards; the interpreter-level allocation of a frame at rest is.
			local jit_was_on = jit and jit.status and jit.status()
			if jit_was_on then jit.off() end
			collectgarbage("stop")
			local before = collectgarbage("count")
			for k = 1, 600 do V:sync(A:frame(pieces, 1 + k, k / 60), 0, 0) end
			local grown = collectgarbage("count") - before
			collectgarbage("restart")
			if jit_was_on then jit.on() end
			for name, n in pairs(E.counts) do -- order-independent
				assert_true(false, "a frame at rest called " .. name .. " x" .. n)
			end
			assert_true(grown < 64, "an idle frame allocates: " .. grown .. " KB in 600 frames")
			-- pieces that leave go back to the pool; the pool is reused
			local made = E.counts.factory_create
			V:sync(A:frame({ pieces[1] }, 700, 11), 0, 0)
			assert_eq(V:stats().pieces, 1)
			assert_eq(V:stats().pooled, 39)
			V:sync(A:frame(pieces, 701, 11.1), 0, 0)
			assert_eq(E.counts.factory_create, made)
			V:final()
		end)
		stub.restore()
		if not ok then error(err, 0) end
	end)

	it("a piece that shrank to nothing keeps a hair of scale (go.set_scale refuses zero)", function()
		local E = stub.install({})
		local ok, err = pcall(function()
			load_modules()
			local V = level_view.new({})
			-- found by the first live browser run: the end of a clear animation has scale 0
			V:sync({ { id = 1, image = "pieces_red", x = 100, y = 100, z = 0.5, sx = 1, sy = 1, scale = 0, rot = 0,
				flash = 0, alpha = 1 } }, 0, 0)
			assert_eq(V:stats().pieces, 1)
			local scl = E.by_factory("piece_factory")[1].scale
			assert_true(scl.x > 0 and scl.y > 0, "the scale stays positive")
			V:final()
		end)
		stub.restore()
		if not ok then error(err, 0) end
	end)

	it("draws the marks of selection and hint from a pool", function()
		local E = stub.install({})
		local ok, err = pcall(function()
			load_modules()
			local V = level_view.new({})
			local list = { { image = "fx_glow_dot", x = 100, y = 200, w = 100, h = 100, color = "#FFD84D", alpha = 0.8, glow = true },
				{ image = "white", iw = 8, ih = 8, x = 300, y = 200, w = 90, h = 90, color = "#FFD84D", alpha = 0.4, glow = false } }
			V:marks(list)
			local made = E.counts.factory_create
			assert_eq(made, 2)
			V:marks({})
			V:marks(list)
			assert_eq(E.counts.factory_create, made)
		end)
		stub.restore()
		if not ok then error(err, 0) end
	end)
end)
