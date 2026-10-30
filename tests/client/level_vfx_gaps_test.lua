-- What level_vfx_test.lua leaves open about the effects behind a window (Vfx:_run) and about when the effects are idle
-- (Vfx:idle, which the janitor of the board waits for): a window or a lost focus halts the session, so the effects that
-- follow the ticks of the core stand still. They wait HIDDEN (a frozen bolt on the board was the "drawing" of the
-- producer's report); a finished level's effects and the ones on the real clock run out in sight.

local stub = require("tests.client.level_defold_stub")
local geom = require("client.level_geom")

local function with_vfx(fn)
	local E = stub.install({})
	local ok, err = pcall(function()
		local level_vfx = require("client.level_vfx")
		local cells = {}
		for i = 1, 81 do cells[i] = { exists = true } end
		local g = geom.new(9, 9, cells, { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 })
		fn(E, level_vfx.new({ geom = g }), g)
	end)
	stub.restore()
	if not ok then error(err, 0) end
end

local function on_screen(E)
	local n = 0
	for _, name in ipairs({ "piece_factory", "glow_factory" }) do
		for _, o in ipairs(E.by_factory(name)) do
			if E.visible(o) then n = n + 1 end
		end
	end
	return n
end

-- seconds of 1/60 s frames; tick = the core's tick advances every frame; halted = the session is held by a window
local function run(vfx, state, seconds, tick, halted)
	for _ = 1, math.floor(seconds * 60) do
		state.t = state.t + 1 / 60
		if tick then state.tick = state.tick + 1 end
		vfx:update(1 / 60, state.tick, state.t, halted)
	end
end

describe("the effects behind a window", function()
	it("draws the tick effects of a finished level while they run out behind the results window", function()
		with_vfx(function(E, vfx)
			local state = { t = 0, tick = 1 }
			vfx:play({ { kind = "reticle", x = 500, y = 500, size = 100, color = "#FF4FC8", at = 0, dur = 33 } })
			vfx:update(1 / 60, state.tick, state.t)
			run(vfx, state, 3 / 60, true)
			assert_true(on_screen(E) > 0, "it is on its way")
			vfx:finish()
			run(vfx, state, 0.2, false, true) -- the result window stops the session for good
			assert_eq(vfx:stats().active, 1, "it is still playing")
			assert_true(on_screen(E) > 0, "and it is drawn, on its own clock")
			run(vfx, state, 3, false, true)
			assert_eq(vfx:stats().active, 0)
			assert_eq(on_screen(E), 0)
		end)
	end)

	it("keeps a bolt visible while it runs out on the real clock behind the results window", function()
		with_vfx(function(E, vfx)
			local state = { t = 0, tick = 1 }
			vfx:play({ { kind = "beam", x = 100, y = 500, dx = 1, dy = 0, len = 500, speed = 8, at = 0, color = "#1FD1FF",
				width = 40, core = true, mode = "comet" } })
			vfx:update(1 / 60, state.tick, state.t)
			run(vfx, state, 2 / 60, true)
			assert_true(on_screen(E) > 0, "the bolt is on its way")
			vfx:finish() -- the level is complete: the result window opens and stops the session
			run(vfx, state, 3 / 60, false, true)
			assert_true(on_screen(E) > 0, "a finished level's bolt runs out in sight on the real clock, window or not")
			run(vfx, state, 3, false, true)
			assert_eq(vfx:stats().active, 0)
			assert_eq(on_screen(E), 0)
		end)
	end)

	it("keeps drawing a ring (real clock) behind a window until it ends by itself", function()
		with_vfx(function(E, vfx)
			local state = { t = 0, tick = 1 }
			vfx:play({ { kind = "ring", x = 300, y = 500, size = 200, color = "#FF4FC8", image = "fx_shock", at = 0, dur = 0.5 } })
			vfx:update(1 / 60, state.tick, state.t)
			run(vfx, state, 2 / 60, true)
			assert_true(on_screen(E) > 0, "the ring is out")
			run(vfx, state, 0.1, false, true) -- a window opens: the real clock runs on
			assert_eq(vfx:stats().active, 1)
			assert_true(on_screen(E) > 0, "a ring on the real clock is not hidden by a window")
			run(vfx, state, 1, false, true)
			assert_eq(vfx:stats().active, 0)
			assert_eq(on_screen(E), 0)
		end)
	end)

	it("hides a tick effect while a window holds the session and shows it again where it stopped", function()
		with_vfx(function(E, vfx)
			local state = { t = 0, tick = 1 }
			vfx:play({ { kind = "reticle", x = 500, y = 500, size = 100, color = "#FF4FC8", at = 0, dur = 33 } })
			vfx:update(1 / 60, state.tick, state.t)
			run(vfx, state, 3 / 60, true)
			assert_true(on_screen(E) > 0, "drawn while the ticks run")
			run(vfx, state, 1, false, true) -- the ticks stand still: nothing is drawn, nothing ends
			assert_eq(on_screen(E), 0, "hidden while the window holds the session")
			assert_eq(vfx:stats().active, 1)
			run(vfx, state, 3 / 60, true) -- the window is closed
			assert_true(on_screen(E) > 0, "and it goes on")
		end)
	end)
end)

describe("the effects: when they are idle", function()
	it("is idle only when nothing runs, waits, burns or shakes", function()
		with_vfx(function(E, vfx)
			local state = { t = 0, tick = 1 }
			assert_true(vfx:idle())
			-- a command that waits for its tick
			vfx:play({ { kind = "ring", x = 300, y = 500, size = 200, color = "#FF4FC8", image = "fx_shock", at = 500, dur = 0.5 } })
			assert_false(vfx:idle(), "a waiting command")
			vfx:clear()
			assert_true(vfx:idle())
			-- a running effect
			vfx:play({ { kind = "ring", x = 300, y = 500, size = 200, color = "#FF4FC8", image = "fx_shock", at = 0, dur = 0.5 } })
			vfx:update(1 / 60, state.tick, state.t)
			assert_false(vfx:idle(), "a running effect")
			run(vfx, state, 2, true)
			assert_true(vfx:idle())
			-- live particles
			vfx:play({ { kind = "burst", fx = "pop", x = 100, y = 500, color = "#FF4468", count = 10, at = 0 } })
			vfx:update(1 / 60, state.tick, state.t)
			assert_eq(vfx:stats().active, 0, "a burst is no effect record")
			assert_false(vfx:idle(), "live particles")
			run(vfx, state, 3, true)
			assert_true(vfx:idle())
			-- a shake
			vfx:play({ { kind = "shake", amp = 6, dur = 0.5, at = 0 } })
			vfx:update(1 / 60, state.tick, state.t)
			assert_false(vfx:idle(), "a shake")
			run(vfx, state, 1, true)
			assert_true(vfx:idle())
		end)
	end)
end)
