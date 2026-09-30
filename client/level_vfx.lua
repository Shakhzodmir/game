-- Plays the effect commands of client/level_effects.lua on the board
-- (Defold, board.script context): pooled sprites for flashes, bolts, shock
-- rings, the Bird's flight with its trail, Disco rays, noise creep and the
-- microphone stinger; pooled particle bursts (assets/fx_defold/*.particlefx,
-- tinted with particlefx.set_constant) under a budget of MAX_PARTICLES live
-- particles; the board shake; slow motion; and, through callbacks, what the
-- GUI scripts draw (praise words, banners, screen flashes, floor pops).
--
--   local level_vfx = require("client.level_vfx")
--   local X = level_vfx.new({piece = "#piece_factory", glow = "#glow_factory", burst = "#burst_factory",
--                            geom = g, reduced = false, on_gui = fn(cmd), on_slowmo = fn(dur, scale)})
--   X:play(commands)                       -- level_effects:drain()
--   local sx, sy = X:update(dt, tick_f, t) -- every frame; returns the shake offset
--   X:stats()                              -- {sprites, bursts, particles, pending}
--   X:clear()                              -- skip: everything gone at once

local view = require("client.level_view")

local M = {}

M.MAX_PARTICLES = 300    -- live particles at most (weak devices)
M.MAX_SPRITES = 160      -- effect sprites at most
M.BURST_LIFE = 1.0       -- seconds a burst object stays busy
-- particles emitted per burst kind (assets/fx_defold/gen_particles.py)
M.PARTICLES = { pop = 10, sparkle = 8, debris = 12, dust = 8, confetti = 12, spark = 5 }
M.EMITTERS = {
	pop = { "dots", "sparks" }, sparkle = { "stars" }, debris = { "chunks" }, dust = { "puffs" },
	confetti = { "bits" }, spark = { "sparks" },
}
M.WHITE_EMITTERS = { sparks = true } -- keep white inside a tinted burst
M.GUI_KINDS = { praise = true, banner = true, screen_flash = true, floor = true, stinger = false }
M.IMG = { -- native sizes of the fx images (assets/images/fx)
	fx_flash = { 256, 256 }, fx_bolt = { 256, 48 }, fx_glow_dot = { 64, 64 }, fx_shock = { 256, 256 },
	fx_ring = { 128, 128 }, fx_ray = { 256, 16 }, fx_cloud = { 256, 128 }, fx_note = { 48, 48 },
	fx_star_particle = { 48, 48 }, specials_bird = { 192, 192 }, specials_riff = { 192, 192 },
	specials_sub = { 192, 192 },
}

local Vfx = {}
Vfx.__index = Vfx

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		factory = { piece = opts.piece or "#piece_factory", glow = opts.glow or "#glow_factory" },
		burst_factory = opts.burst or "#burst_factory",
		geom = opts.geom,
		reduced = opts.reduced and true or false,
		on_gui = opts.on_gui or function() end,
		on_slowmo = opts.on_slowmo or function() end,
		pending = {},    -- commands waiting for their tick
		active = {},     -- running sprite effects
		pool = { piece = {}, glow = {} },
		sprites = 0,
		bursts = {},     -- {go, busy_until, particles}
		particles = {},  -- {until, n} live particle reservations
		live = 0,
		shakes = {},
		t = 0,
		skipped = 0,
		played = 0,
	}, Vfx)
end

function Vfx:set_geom(g)
	self.geom = g
end

function Vfx:set_reduced(on)
	self.reduced = on and true or false
end

-- sprites ----------------------------------------------------------------------

function Vfx:_sprite(kind)
	local list = self.pool[kind]
	local o = table.remove(list)
	if o then return o end
	if self.sprites >= M.MAX_SPRITES then return nil end
	self.sprites = self.sprites + 1
	o = view.create(self.factory[kind])
	o.kind = kind
	return o
end

function Vfx:_release(o)
	view.hide(o)
	if o.flipped then
		o.flipped = false
		sprite.set_hflip(o.url, false)
	end
	local list = self.pool[o.kind]
	list[#list + 1] = o
end

local function size_of(image)
	local s = M.IMG[image]
	if s then return s[1], s[2] end
	return 64, 64
end

-- An effect running every frame: step(fx, k, age) with k = 0..1 over dur.
-- clock = "tick" (display ticks, dur in ticks) or "time" (seconds).
function Vfx:_run(fx)
	fx.objs = fx.objs or {}
	self.active[#self.active + 1] = fx
	return fx
end

-- commands -----------------------------------------------------------------------

function Vfx:play(cmds)
	local p = self.pending
	for i = 1, #cmds do p[#p + 1] = cmds[i] end
	if #cmds > 0 then
		table.sort(p, function(a, b)
			if a.at ~= b.at then return a.at < b.at end
			return (a.seq or 0) < (b.seq or 0)
		end)
	end
end

local function lerp(a, b, k) return a + (b - a) * k end

function Vfx:_start(c, tick_f)
	local kind = c.kind
	self.played = self.played + 1
	if kind == "burst" then
		self:_burst(c)
	elseif kind == "shake" then
		if not self.reduced then self.shakes[#self.shakes + 1] = { amp = c.amp, dur = c.dur, t0 = self.t } end
	elseif kind == "slowmo" then
		if not self.reduced then self.on_slowmo(c.dur, c.scale) end
	elseif kind == "flash" then
		self:_flash(c)
	elseif kind == "beam" then
		self:_beam(c)
	elseif kind == "ring" then
		self:_ring(c)
	elseif kind == "fly" then
		self:_fly(c)
	elseif kind == "ray" then
		self:_ray(c)
	elseif kind == "creep" then
		self:_creep(c)
	elseif kind == "stinger" then
		self:_stinger(c)
	end
	if M.GUI_KINDS[kind] then self.on_gui(c) end
end

-- particles ------------------------------------------------------------------------

function Vfx:_burst(c)
	local n = M.PARTICLES[c.fx] or 10
	-- live particles now
	local live = 0
	local keep = {}
	for _, r in ipairs(self.particles) do
		if r.untilt > self.t then
			live = live + r.n
			keep[#keep + 1] = r
		end
	end
	self.particles = keep
	if self.reduced and c.fx == "pop" then
		self.pop_toggle = not self.pop_toggle
		if self.pop_toggle then return end
	end
	if live + n > M.MAX_PARTICLES then
		self.skipped = self.skipped + 1
		return
	end
	local b
	for _, x in ipairs(self.bursts) do
		if x.busy_until <= self.t then
			b = x
			break
		end
	end
	if not b then
		if #self.bursts >= 40 then
			self.skipped = self.skipped + 1
			return
		end
		local id = factory.create(self.burst_factory, view.OFF, nil, nil, 1)
		b = { go = id, urls = {} }
		self.bursts[#self.bursts + 1] = b
	end
	b.busy_until = self.t + M.BURST_LIFE
	local url = b.urls[c.fx]
	if not url then
		url = msg.url(nil, b.go, c.fx)
		b.urls[c.fx] = url
	end
	local cell = self.geom and self.geom.cell or 80
	go.set_position(vmath.vector3(c.x, c.y, 0.5), b.go)
	go.set_scale(cell / 80, b.go)
	local r, g, bl = view.rgb(c.color or "#FFFFFF")
	local tint = vmath.vector4(r, g, bl, 1)
	local white = vmath.vector4(1, 1, 1, 1)
	for _, em in ipairs(M.EMITTERS[c.fx] or {}) do
		particlefx.set_constant(url, em, "tint", M.WHITE_EMITTERS[em] and c.fx == "pop" and white or tint)
	end
	particlefx.play(url)
	self.particles[#self.particles + 1] = { untilt = self.t + 0.9, n = n }
end

-- sprite effects ---------------------------------------------------------------------

function Vfx:_flash(c)
	local o = self:_sprite("glow")
	if not o then return end
	local w = size_of("fx_flash")
	local r, g, b = view.rgb(c.color)
	local base = c.size / w
	local dur = c.dur or 0.35
	self:_run({ objs = { o }, clock = "time", t0 = self.t, dur = dur, step = function(fx, k)
		local s = base * (0.55 + 0.85 * (1 - (1 - k) * (1 - k)))
		view.apply(o, "fx_flash", c.x + self.sx, c.y + self.sy, 0.4, s, s, 0, 0, nil, 0.9 * (1 - k), r, g, b)
	end })
end

function Vfx:_beam(c)
	local beam = self:_sprite("glow")
	local head = self:_sprite("glow")
	if not beam or not head then
		if beam then self:_release(beam) end
		if head then self:_release(head) end
		return
	end
	local bw, bh = size_of("fx_bolt")
	local r, g, b = view.rgb(c.color)
	local rot = (c.dy ~= 0) and 90 or 0
	local travel_ticks = c.len / c.speed
	local fade = 0.22
	local fx = { objs = { beam, head }, clock = "tick", t0 = c.at, dur = travel_ticks, after = fade }
	fx.step = function(_, k, age, after_k)
		local len = c.len * k
		local alpha = after_k and (1 - after_k) or 1
		local flick = 1 + (self.reduced and 0 or 0.18 * math.sin(age * 2.3))
		local cx, cy = c.x + c.dx * len / 2, c.y + c.dy * len / 2
		view.apply(beam, "fx_bolt", cx + self.sx, cy + self.sy, 0.42, math.max(len, 1) / bw,
			c.width * flick / bh, rot, 0.3, nil, alpha, r, g, b)
		local hx, hy = c.x + c.dx * len, c.y + c.dy * len
		local hs = c.width * 1.9 / 64
		view.apply(head, "fx_glow_dot", hx + self.sx, hy + self.sy, 0.43, hs, hs, 0, 0.6, nil,
			after_k and 0 or 1, 1, 1, 1)
	end
	self:_run(fx)
end

function Vfx:_ring(c)
	local o = self:_sprite("piece")
	if not o then return end
	local w = size_of(c.image or "fx_shock")
	local r, g, b = view.rgb(c.color)
	local dur = c.dur or 0.32
	self:_run({ objs = { o }, clock = "time", t0 = self.t, dur = dur, step = function(_, k)
		local s = c.size / w * (0.35 + 0.65 * (1 - (1 - k) ^ 2))
		view.apply(o, c.image or "fx_shock", c.x + self.sx, c.y + self.sy, 0.38, s, s, 0, 0.2, nil, 0.85 * (1 - k), r, g, b)
	end })
end

function Vfx:_fly(c)
	local bird = self:_sprite("piece")
	if not bird then return end
	local carry = c.carry and self:_sprite("piece") or nil
	local cell = self.geom and self.geom.cell or 80
	local k0 = cell / 160
	local dx, dy = c.x1 - c.x0, c.y1 - c.y0
	local len = math.sqrt(dx * dx + dy * dy)
	-- control point: the middle lifted up and pushed sideways
	local lift = math.max(cell * 1.2, len * 0.35)
	local cx, cy = (c.x0 + c.x1) / 2 - (len > 0 and dy / len or 0) * lift * 0.4, (c.y0 + c.y1) / 2 + lift
	local trail_t = 0
	local tr, tg, tb = view.rgb(c.trail or "#7EF0FF")
	local flip = dx < 0
	local objs = { bird }
	if carry then objs[2] = carry end
	if flip then
		bird.flipped = true
		sprite.set_hflip(bird.url, true)
	end
	self:_run({ objs = objs, clock = "tick", t0 = c.at, dur = c.dur, step = function(_, k, age)
		local e = k < 0.5 and 2 * k * k or 1 - (-2 * k + 2) ^ 2 / 2
		local u = 1 - e
		local x = u * u * c.x0 + 2 * u * e * cx + e * e * c.x1
		local y = u * u * c.y0 + 2 * u * e * cy + e * e * c.y1
		local s = k0 * (1.15 + 0.25 * math.sin(k * math.pi))
		local tilt = self.reduced and 0 or 12 * math.sin(age * 0.9)
		view.apply(bird, "specials_bird", x + self.sx, y + self.sy, 0.45, s, s, tilt, 0, nil, 1)
		if carry then
			local cs = k0 * 0.7
			view.apply(carry, c.carry, x + self.sx, y - cell * 0.45 + self.sy, 0.44, cs, cs,
				c.axis == "v" and 90 or 0, 0.2, nil, 1)
		end
		if not self.reduced then
			trail_t = trail_t + 1
			if trail_t % 3 == 0 then self:_dot(x, y, cell * 0.5, tr, tg, tb) end
		end
	end })
end

-- a fading dot of a trail
function Vfx:_dot(x, y, size, r, g, b)
	local o = self:_sprite("glow")
	if not o then return end
	local s0 = size / 64
	self:_run({ objs = { o }, clock = "time", t0 = self.t, dur = 0.32, step = function(_, k)
		local s = s0 * (1 - 0.7 * k)
		view.apply(o, "fx_glow_dot", x + self.sx, y + self.sy, 0.41, s, s, 0, 0, nil, 0.8 * (1 - k), r, g, b)
	end })
end

function Vfx:_ray(c)
	local o = self:_sprite("glow")
	if not o then return end
	local w, h = size_of("fx_ray")
	local r, g, b = view.rgb(c.color)
	local dx, dy = c.x1 - c.x0, c.y1 - c.y0
	local len = math.max(math.sqrt(dx * dx + dy * dy), 1)
	local rot = math.deg(math.atan2(dy, dx))
	local cell = self.geom and self.geom.cell or 80
	self:_run({ objs = { o }, clock = "time", t0 = self.t, dur = 0.34, step = function(_, k)
		local grow = math.min(1, k / 0.25)
		local l = len * grow
		local x, y = c.x0 + dx / len * l / 2, c.y0 + dy / len * l / 2
		local alpha = k < 0.35 and 1 or (1 - (k - 0.35) / 0.65)
		view.apply(o, "fx_ray", x + self.sx, y + self.sy, 0.42, l / w, cell * 0.28 / h, rot, 0.3, nil, alpha, r, g, b)
	end })
end

function Vfx:_creep(c)
	local o = self:_sprite("piece")
	if not o then return end
	local w = size_of("fx_cloud")
	local cell = self.geom and self.geom.cell or 80
	local r, g, b = view.rgb("#8A8FA3")
	self:_run({ objs = { o }, clock = "tick", t0 = c.at, dur = 12, step = function(_, k)
		local x, y = lerp(c.x0, c.x1, k), lerp(c.y0, c.y1, k)
		local s = cell * (0.9 - 0.4 * k) / w
		view.apply(o, "fx_cloud", x + self.sx, y + self.sy, 0.39, s, s, 0, 0, nil, 0.9 * (1 - k * 0.6), r, g, b)
	end })
end

function Vfx:_stinger(c)
	local note = self:_sprite("piece")
	if not note then return end
	local cell = self.geom and self.geom.cell or 80
	local r, g, b = view.rgb("#FFB020")
	self:_run({ objs = { note }, clock = "time", t0 = self.t, dur = 0.8, step = function(_, k)
		local s = cell * 0.6 / 48 * (k < 0.2 and k / 0.2 * 1.2 or 1.2 - 0.2 * k)
		view.apply(note, "fx_note", c.x + self.sx, c.y + cell * 1.4 * k + self.sy, 0.46, s, s,
			self.reduced and 0 or 15 * math.sin(k * 9), 0, nil, 1 - k * k, r, g, b)
	end })
	self:_ring({ x = c.x, y = c.y, size = cell * 1.8, dur = 0.4, color = "#FFD84D", image = "fx_ring" })
end

-- frame ---------------------------------------------------------------------------------

function Vfx:_shake_offset()
	local x, y = 0, 0
	local keep = {}
	for _, s in ipairs(self.shakes) do
		local age = self.t - s.t0
		if age < s.dur then
			keep[#keep + 1] = s
			local d = 1 - age / s.dur
			d = d * d
			x = x + s.amp * d * math.sin(age * 71)
			y = y + s.amp * d * 0.7 * math.cos(age * 57)
		end
	end
	self.shakes = keep
	return x, y
end

-- Advances every effect. Returns the board shake offset (logical px).
function Vfx:update(dt, tick_f, t)
	self.t = t
	self.sx, self.sy = self:_shake_offset()
	-- start what is due
	local p = self.pending
	local n = 0
	for i = 1, #p do
		if p[i].at <= tick_f + 1e-6 then n = i else break end
	end
	if n > 0 then
		local due = {}
		for i = 1, n do due[i] = p[i] end
		local rest = {}
		for i = n + 1, #p do rest[#rest + 1] = p[i] end
		self.pending = rest
		for i = 1, n do self:_start(due[i], tick_f) end
	end
	-- run effects
	local keep = {}
	for _, fx in ipairs(self.active) do
		local age, k
		if fx.clock == "tick" then
			age = tick_f - fx.t0
			k = age / fx.dur
		else
			age = t - fx.t0
			k = age / fx.dur
		end
		local done = false
		if k < 0 then
			for _, o in ipairs(fx.objs) do view.hide(o) end
		elseif k <= 1 then
			fx.step(fx, k, age)
		elseif fx.after then
			fx.after_t0 = fx.after_t0 or t
			local ak = (t - fx.after_t0) / fx.after
			if ak >= 1 then done = true else fx.step(fx, 1, age, ak) end
		else
			if not fx.ended then
				fx.ended = true
				fx.step(fx, 1, age)
			end
			done = true
		end
		if done then
			for _, o in ipairs(fx.objs) do self:_release(o) end
		else
			keep[#keep + 1] = fx
		end
	end
	self.active = keep
	return self.sx, self.sy
end

-- Skip / leaving: every running effect and pending command is dropped.
function Vfx:clear()
	for _, fx in ipairs(self.active) do
		for _, o in ipairs(fx.objs) do self:_release(o) end
	end
	self.active, self.pending, self.shakes = {}, {}, {}
	for _, b in ipairs(self.bursts) do
		for _, url in pairs(b.urls) do pcall(particlefx.stop, url, { clear = true }) end -- order-independent
		b.busy_until = 0
	end
	self.particles = {}
end

function Vfx:stats()
	local live = 0
	for _, r in ipairs(self.particles) do
		if r.untilt > self.t then live = live + r.n end
	end
	return { sprites = self.sprites, active = #self.active, pending = #self.pending, bursts = #self.bursts,
		particles = live, skipped = self.skipped, played = self.played }
end

return M
