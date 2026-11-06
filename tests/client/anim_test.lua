-- client/anim.lua (pure Lua) on the real content/animations.json: the data is consistent, every state of Bit
-- plays and ends, idle variants come by chance, boredom puts Bit to sleep and a touch wakes it, events pick
-- states by priority, the dance follows the beat clock, reduced motion stands still, nothing depends on the clock.

local json = require("tools.lib.json")
local anim = require("client.anim")

local function data()
	local f = assert(io.open("content/animations.json", "rb"))
	local t = f:read("*a")
	f:close()
	return json.decode(t)
end

-- a deterministic rng (an LCG): the same numbers on both VMs
local function lcg(seed)
	local s = seed
	return function()
		s = (s * 1103515245 + 12345) % 2147483648
		return s / 2147483648
	end
end

local function player(seed, extra)
	local o = { rng = lcg(seed or 7), sounds = {} }
	o.on_sound = function(name, gain) o.sounds[#o.sounds + 1] = name end
	for k, v in pairs(extra or {}) do o[k] = v end -- order-free
	return anim.new(data().bit, o), o
end

local function run(p, seconds, dt, clock0)
	dt = dt or 1 / 60
	local seen, t, order = {}, 0, {}
	while t < seconds do
		p:update(dt, clock0 and (clock0 + t) or nil)
		t = t + dt
		if not seen[p.state] then seen[p.state] = t; order[#order + 1] = p.state end
	end
	return seen, order
end

describe("content/animations.json", function()
	it("is consistent", function()
		assert_same(anim.validate(data()), {})
	end)

	it("gives Bit the states the producer asked for, each with its own frames", function()
		local d = data().bit
		for _, name in ipairs({ "idle", "look", "wave", "listen", "cheer", "surprised", "sleepy", "write", "dance_a", "dance_b" }) do
			assert_true(d.states[name] ~= nil, "state " .. name)
		end
		local imgs = anim.images(d)
		for _, k in ipairs({ "bit/idle_breathe_1", "bit/idle_look_4", "bit/dance_a_6", "bit/dance_b_6", "bit/cheer_6",
			"bit/surprised_4", "bit/sleepy_4", "bit/write_6", "bit/listen_4", "bit/wave_4", "bit/idle", "bit/worried" }) do
			assert_true(imgs[k], k)
		end
		for k in pairs(imgs) do -- order-free
			assert_true(require("client.assets").image(k) ~= nil, "not in the image index: " .. k)
			local f = io.open("assets/images/" .. k .. ".png", "rb")
			assert_true(f ~= nil, "no picture for " .. k)
			if f then f:close() end
		end
	end)

	it("lists a sway for at least five task items per kind of room", function()
		local d = data()
		local n = 0
		for _ in pairs(d.items.tasks) do n = n + 1 end
		assert_true(n >= 10, "items " .. n)
		for _, spec in pairs(d.items.tasks) do -- order-free
			local m = anim.item_motion(spec)
			assert_true(#m >= 1)
			for _, tw in ipairs(m) do assert_true(tw.dur > 0 and tw.to ~= tw.from) end
		end
	end)
end)

describe("anim.validate", function()
	it("reports what is wrong", function()
		local d = data()
		d.bit.states.look.anim = "nope"
		d.bit.anims.wave.mode = "spin"
		d.bit.idle.variants = { { state = "look", weight = 1 } }
		local bad = table.concat(anim.validate(d), "\n")
		assert_true(bad:find("unknown anim nope", 1, true))
		assert_true(bad:find("bad mode spin", 1, true))
		assert_true(bad:find("at least two variants", 1, true))
	end)
end)

describe("anim player", function()
	it("breathes at first, then plays idle variants by chance, never the same twice in a row", function()
		local p = player(3)
		assert_eq(p.state, "idle")
		assert_eq(p:image(), "bit/idle_breathe_1")
		local seen, order = run(p, 120)
		assert_true(seen.look and seen.wave and seen.listen, "variants seen")
		for i = 2, #order do assert_true(order[i] ~= order[i - 1] or order[i] == "idle") end
		local a = select(2, run(player(11), 60))
		local b = select(2, run(player(11), 60))
		assert_same(a, b) -- the same seed, the same story
	end)

	it("a different seed gives a different order of variants", function()
		local a = select(2, run(player(1), 90))
		local b = select(2, run(player(2), 90))
		assert_true(table.concat(a, ",") ~= table.concat(b, ","))
	end)

	it("every state of the data plays and ends (or is forever on purpose)", function()
		local d = data().bit
		local FOREVER = { sleepy = true, write = true, dance_a = true, dance_b = true, sad = true,
			worried = true, scratch = true }
		for name in pairs(d.states) do -- order-free
			local p = player(5)
			assert_true(p:play(name), name)
			run(p, 30)
			if name == "idle" then
				assert_true(p.state == "idle" or p.state == "look" or p.state == "wave" or p.state == "listen")
			elseif FOREVER[name] then
				assert_eq(p.state, name, name .. " should stay")
			else
				assert_true(p.state == "idle" or p.state == "look" or p.state == "wave" or p.state == "listen",
					name .. " should end, now " .. p.state)
			end
		end
	end)

	it("an event picks a state; a state of a higher priority is not interrupted", function()
		local p = player(9)
		assert_eq(p:trigger("task_done"), "cheer")
		run(p, 0.2)
		assert_eq(p.state, "cheer")
		assert_eq(p:trigger("hello"), nil) -- wave (priority 0) does not cut the cheer
		assert_eq(p.state, "cheer")
		run(p, 4)
		assert_eq(p.state ~= "cheer", true)
		assert_eq(p:trigger("tap") ~= nil, true)
		assert_eq(p:trigger("no_such_event"), nil)
	end)

	it("level_lost holds the sad picture for its hold time and then goes back to idle", function()
		local p = player(1)
		assert_eq(p:trigger("level_lost"), "sad")
		run(p, 1.5)
		assert_eq(p.state, "sad")
		run(p, 1)
		assert_true(p.state ~= "sad")
	end)

	it("the notebook animation lasts until it is released", function()
		local p = player(1)
		assert_eq(p:trigger("notebook"), "write")
		run(p, 20)
		assert_eq(p.state, "write")
		local f = {}
		for _ = 1, 120 do p:update(1 / 60); f[p.frame] = true end
		assert_true(f[1] and f[6], "all six frames of writing are shown")
		p:release()
		run(p, 0.1)
		assert_true(p.state ~= "write")
	end)

	it("boredom: sleepy after the quiet time, a touch wakes Bit with a start", function()
		local d = data()
		d.bit.idle.bored_after = 20
		local p = anim.new(d.bit, { rng = lcg(2) })
		local seen = run(p, 24)
		assert_true(seen.sleepy, "fell asleep")
		-- no touches meanwhile: still asleep; the sleeper breathes slowly and shows the last frames
		assert_eq(p.state, "sleepy")
		run(p, 8)
		assert_eq(p.state, "sleepy")
		assert_true(p.frame >= 3)
		p:touch()
		assert_eq(p.state, "surprised")
		run(p, 3)
		assert_true(p.state ~= "sleepy" and p.state ~= "surprised")
	end)

	it("a touch keeps Bit awake (the quiet time restarts)", function()
		local d = data()
		d.bit.idle.bored_after = 10
		local p = anim.new(d.bit, { rng = lcg(2) })
		for _ = 1, 8 do
			run(p, 6)
			p:touch()
		end
		local seen = run(p, 6)
		assert_true(not seen.sleepy)
	end)

	it("plays the sounds of a frame once when the frame is reached", function()
		local p, o = player(4)
		p:play("cheer")
		run(p, 2)
		local land = 0
		for _, s in ipairs(o.sounds) do if s == "land" then land = land + 1 end end
		assert_eq(land, 2) -- the cheer lands once per pass, and it plays two passes
		p:play("surprised")
		run(p, 2)
		assert_true(#o.sounds >= 2)
	end)

	it("dances on the beat: the frames follow the clock of the track and the poses alternate", function()
		local p = player(1)
		p:set_dance(true, 120) -- 2 beats per pass = 1 s per pass, 6 frames
		local frames = {}
		for i = 0, 59 do
			p:update(1 / 60, 10 + i / 60)
			frames[#frames + 1] = p.frame
		end
		assert_eq(frames[1], 1)
		assert_eq(frames[31], 4) -- half a second in: frame 4
		assert_eq(frames[60], 6)
		-- a different clock offset gives a different frame: it is locked to the clock, not to when it started
		local q = player(1)
		q:set_dance(true, 120)
		q:update(1 / 60, 10.5)
		assert_eq(q.frame, 4)
		-- dance_a for 4 beats (2 s), then dance_b
		local r = player(1)
		r:set_dance(true, 120)
		local states = {}
		for i = 0, 5 * 60 do
			r:update(1 / 60, i / 60)
			if states[#states] ~= r.state then states[#states + 1] = r.state end
		end
		assert_same(states, { "dance_a", "dance_b", "dance_a" })
		-- the bounce peaks on the beat
		local lo, hi = 9, -9
		for i = 0, 119 do
			r:update(1 / 60, i / 60)
			lo, hi = math.min(lo, r.pose.dy), math.max(hi, r.pose.dy)
		end
		assert_true(hi > 0.05 and lo >= 0)
		r:set_dance(false)
		assert_eq(r.state, "idle")
	end)

	it("a dance cannot be cut by an event, a stop leaves it", function()
		local p = player(1)
		p:set_dance(true, 100)
		assert_eq(p:trigger("task_done"), nil)
		assert_true(p.state == "dance_a")
		p:set_dance(false)
		assert_eq(p:trigger("task_done"), "cheer")
	end)

	it("reduced motion: still frames, no variants, no sleep, no sway, states still end", function()
		local d = data()
		d.bit.idle.bored_after = 5
		local p = anim.new(d.bit, { rng = lcg(1), reduced = true })
		local seen = run(p, 60)
		assert_same(seen, { idle = seen.idle })
		assert_eq(p:image(), "bit/idle_breathe_1")
		assert_eq(p.pose.sx, 1)
		assert_eq(p.pose.rot, 0)
		p:trigger("task_done")
		local f = {}
		for _ = 1, 30 do
			p:update(1 / 60)
			if p.state == "cheer" then f[p.frame] = true end
		end
		local count = 0
		for _ in pairs(f) do count = count + 1 end
		assert_eq(count, 1)
		run(p, 4)
		assert_true(p.state ~= "cheer", "the cheer still ended")
		p:set_reduced(false)
		local seen2 = run(p, 60)
		assert_true(seen2.look or seen2.wave or seen2.listen or seen2.sleepy)
	end)

	it("the breathing pose keeps the feet on the ground and stays small", function()
		local p = player(1)
		local lo, hi = 9, -9
		for _ = 1, 300 do
			p:update(1 / 60)
			if p.state == "idle" then
				lo, hi = math.min(lo, p.pose.sy), math.max(hi, p.pose.sy)
				assert_near(p.pose.dy, (p.pose.sy - 1) * 0.5, 1e-9)
			end
		end
		assert_true(lo < 1 and hi > 1 and hi - lo < 0.08)
	end)

	it("does not create tables while it runs", function()
		local p = player(1)
		run(p, 3)
		collectgarbage(); collectgarbage()
		collectgarbage("stop")
		local before = collectgarbage("count")
		for _ = 1, 600 do p:update(1 / 60, nil) end
		local grew = collectgarbage("count") - before
		collectgarbage("restart")
		assert_true(grew < 40, "grew by " .. grew .. " KB in 600 frames")
	end)
end)

describe("anim.item_motion", function()
	it("turns a spec into looped tweens", function()
		local m = anim.item_motion({ kind = "swing", amp = 3, period = 3 })
		assert_eq(m[1].prop, "euler.z")
		assert_eq(m[1].from, -3)
		assert_eq(m[1].to, 3)
		assert_near(m[1].dur, 1.5, 1e-9)
		local b = anim.item_motion({ kind = "breathe", amp = 0.04, period = 2 })
		assert_eq(#b, 2)
		assert_true(b[1].factor)
		assert_eq(anim.item_motion({ kind = "bob", amp = 5, period = 2.4 })[1].prop, "position.y")
	end)
end)
