-- Plays the effect commands of client/level_effects.lua on the board
-- (Defold, board.script context): pooled sprites for flashes, comet bolts,
-- shock rings, the Bird's flight with its trail and target reticle, Disco
-- rays, charging glows, ghosts of destroyed things, noise creep and the
-- microphone stinger; pooled particle bursts (assets/fx_defold/*.particlefx,
-- tinted with particlefx.set_constant) under a budget of live particles; the
-- board shake; slow motion; and, through callbacks, what the GUI scripts draw
-- (praise words, banners, screen flashes, floor pops).
--
--   local level_vfx = require("client.level_vfx")
--   local X = level_vfx.new({piece = "#piece_factory", glow = "#glow_factory",
--                            bursts = {pop = "#pop_factory", ...}, geom = g, reduced = false,
--                            on_gui = fn(cmd), on_slowmo = fn(dur, scale)})
--   X:play(commands)                       -- level_effects:drain()
--   local sx, sy = X:update(dt, tick_f, t) -- every frame; returns the shake offset
--   X:stats()                              -- {sprites, bursts, particles, pending, ...}
--   X:clear()                              -- skip: everything gone at once
--   X:set_lite(true)                       -- a slow device: half the particles, no trail dots
--
-- Pools and limits (game.project): sprite objects are created on demand up
-- to MAX_SPRITES and reused; particle bursts live in one pool per kind (one
-- particlefx component per game object, CAP objects at most, so that
-- particle_fx.max_count of game.project is never reached) and are reused
-- once their particles are gone (LIFE); live particles never exceed
-- MAX_PARTICLES (half of it in lite mode): a burst that does not fit is
-- skipped. Nothing is allocated per frame while no event arrives: effects
-- are records with a static step function, queues are compacted in place.
--
-- The board is bright (white and lavender cells), so every sprite and particle is alpha
-- blended in a saturated colour: additive light would vanish on it.
--
-- Clocks: "tick" effects follow the display tick of the session (the core's
-- timings: bolts, rings, flights; they slow down with the Grand finale's
-- slow motion), "time" effects run on real seconds (flashes, ghosts, dots).

local view = require("client.level_view")

local M = {}

M.MAX_PARTICLES = 300    -- live particles at most (weak devices)
M.MAX_PARTICLES_LITE = 150
M.MAX_SPRITES = 160      -- effect sprites at most
-- particles of one burst (assets/fx_defold/gen_particles.py)
M.PARTICLES = { pop = 10, sparkle = 8, debris = 12, dust = 8, confetti = 12, spark = 5 }
-- seconds a burst object stays busy: the longest particle life of its effect + a margin
M.LIFE = { pop = 0.65, sparkle = 0.95, debris = 0.8, dust = 0.75, confetti = 1.0, spark = 0.45 }
-- burst objects per kind: 6 kinds, one particlefx component each (66 components,
-- 90 emitters at most; game.project allows 128 / 256)
M.CAP = { pop = 24, sparkle = 10, debris = 8, dust = 8, confetti = 6, spark = 10 }
M.KINDS = { "pop", "sparkle", "debris", "dust", "confetti", "spark" }
M.EMITTERS = {
	pop = { "dots", "sparks" }, sparkle = { "stars" }, debris = { "chunks" }, dust = { "puffs" },
	confetti = { "bits" }, spark = { "sparks" },
}
M.GUI_KINDS = { praise = true, banner = true, screen_flash = true, floor = true }
M.IMG = { -- native sizes of the fx images (assets/images/fx)
	fx_flash = { 256, 256 }, fx_bolt = { 256, 48 }, fx_glow_dot = { 64, 64 }, fx_shock = { 256, 256 },
	fx_ring = { 128, 128 }, fx_ray = { 256, 16 }, fx_cloud = { 256, 128 }, fx_note = { 48, 48 },
	fx_star_particle = { 48, 48 }, specials_bird = { 192, 192 }, specials_riff = { 192, 192 },
	specials_sub = { 192, 192 }, specials_disco = { 192, 192 },
}
M.COMET = 3.4            -- cells: the long dim tail of a Riff bolt
M.COMET_BRIGHT = 1.3     -- cells: its bright head part
M.Z = { flash = 0.40, ring = 0.38, beam = 0.42, dot = 0.41, head = 0.435, fly = 0.45, ray = 0.42, creep = 0.39,
	ghost = 0.30, stinger = 0.46, reticle = 0.37, charge = 0.36 }

local apply = view.apply

local Vfx = {}
Vfx.__index = Vfx

function M.new(opts)
	opts = opts or {}
	local bursts, urls = {}, {}
	for _, kind in ipairs(M.KINDS) do
		bursts[kind] = {}
		urls[kind] = (opts.bursts and opts.bursts[kind]) or ("#" .. kind .. "_factory")
	end
	return setmetatable({
		factory = { piece = opts.piece or "#piece_factory", glow = opts.glow or "#glow_factory" },
		burst_urls = urls,
		geom = opts.geom,
		reduced = opts.reduced and true or false,
		lite = false,
		on_gui = opts.on_gui or function() end,
		on_slowmo = opts.on_slowmo or function() end,
		heap = {},       -- commands waiting for their tick: binary heap by (at, seq)
		seq = 0,
		active = {},     -- running effects (records with a static step function)
		fx_pool = {},    -- spare effect records
		pool = { piece = {}, glow = {} },
		sprites = 0,
		bursts = bursts, -- kind -> {{go, url, busy_until, n, pos, tint}}
		bursts_n = 0,
		live = 0,        -- live particles (reservations)
		shakes = {},
		sx = 0, sy = 0,
		t = 0,
		skipped = 0,
		played = 0,
		toggle = false,
	}, Vfx)
end

function Vfx:set_geom(g)
	self.geom = g
end

function Vfx:set_reduced(on)
	self.reduced = on and true or false
end

function Vfx:set_lite(on)
	self.lite = on and true or false
end

-- sprites ----------------------------------------------------------------------

function Vfx:_sprite(kind)
	local list = self.pool[kind]
	local n = #list
	if n > 0 then
		local o = list[n]
		list[n] = nil
		return o
	end
	if self.sprites >= M.MAX_SPRITES then return nil end
	self.sprites = self.sprites + 1
	local o = view.create(self.factory[kind])
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

-- an effect record (reused); step(self, fx, k, age, after_k)
function Vfx:_new_fx(step, c, clock, t0, dur, after)
	local pool = self.fx_pool
	local n = #pool
	local fx
	if n > 0 then
		fx = pool[n]
		pool[n] = nil
	else
		fx = {}
	end
	fx.step, fx.c, fx.clock, fx.t0, fx.dur, fx.after = step, c, clock, t0, dur, after
	fx.after_t0, fx.ended, fx.n = nil, false, 0
	fx.cr, fx.cg, fx.cb, fx.n_trail = 1, 1, 1, 0
	return fx
end

function Vfx:_attach(fx, ...)
	local n = select("#", ...)
	for i = 1, n do fx[i] = select(i, ...) end
	fx.n = n
	local act = self.active
	act[#act + 1] = fx
	return fx
end

function Vfx:_free_fx(fx)
	for i = 1, fx.n do
		self:_release(fx[i])
		fx[i] = nil
	end
	fx.n, fx.c, fx.step = 0, nil, nil
	local pool = self.fx_pool
	pool[#pool + 1] = fx
end

-- command heap (by at, then arrival order) ----------------------------------------

local function before(a, b)
	if a.at ~= b.at then return a.at < b.at end
	return a.seq < b.seq
end

function Vfx:_push(c)
	local h = self.heap
	self.seq = self.seq + 1
	c.seq = self.seq
	local i = #h + 1
	h[i] = c
	while i > 1 do
		local p = math.floor(i / 2)
		if before(h[i], h[p]) then
			h[i], h[p] = h[p], h[i]
			i = p
		else
			break
		end
	end
end

function Vfx:_pop()
	local h = self.heap
	local n = #h
	if n == 0 then return nil end
	local top = h[1]
	h[1] = h[n]
	h[n] = nil
	n = n - 1
	local i = 1
	while true do
		local l, r = i * 2, i * 2 + 1
		local m = i
		if l <= n and before(h[l], h[m]) then m = l end
		if r <= n and before(h[r], h[m]) then m = r end
		if m == i then break end
		h[i], h[m] = h[m], h[i]
		i = m
	end
	return top
end

function Vfx:play(cmds)
	for i = 1, #cmds do self:_push(cmds[i]) end
end

-- commands ---------------------------------------------------------------------------

local START = {}

function Vfx:_start(c)
	self.played = self.played + 1
	local kind = c.kind
	local fn = START[kind]
	if fn then fn(self, c) end
	if M.GUI_KINDS[kind] then self.on_gui(c) end
end

-- particles ------------------------------------------------------------------------

function START.burst(self, c)
	local kind = c.fx
	local pool = self.bursts[kind]
	if not pool then return end
	local n = M.PARTICLES[kind] or 10
	if (self.reduced or self.lite) and kind == "pop" then
		self.toggle = not self.toggle
		if self.toggle then return end
	end
	local budget = self.lite and M.MAX_PARTICLES_LITE or M.MAX_PARTICLES
	if self.live + n > budget then
		self.skipped = self.skipped + 1
		return
	end
	local t = self.t
	local b
	for i = 1, #pool do
		if pool[i].busy_until <= t then
			b = pool[i]
			break
		end
	end
	if not b then
		if #pool >= (M.CAP[kind] or 8) then
			self.skipped = self.skipped + 1
			return
		end
		local id = factory.create(self.burst_urls[kind], view.OFF, nil, nil, 1)
		b = { go = id, url = msg.url(nil, id, "fx"), busy_until = 0, n = n,
			pos = vmath.vector3(0, 0, 0.5), tint = vmath.vector4(1, 1, 1, 1) }
		pool[#pool + 1] = b
		self.bursts_n = self.bursts_n + 1
	end
	b.busy_until = t + (M.LIFE[kind] or 1)
	b.n = n
	local cell = self.geom and self.geom.cell or 80
	b.pos.x, b.pos.y = c.x, c.y
	go.set_position(b.pos, b.go)
	go.set_scale(cell / 80, b.go)
	-- play FIRST: the engine keeps a constant only on a particle instance that exists, and play creates
	-- it (a set_constant before it is dropped with a "could not be found" warning and the burst stays
	-- white). Both calls are messages handled in order within this frame, before the first particle
	-- update and draw. The instance of the previous burst of this object is long pruned (LIFE).
	particlefx.play(b.url)
	local r, g, bl = view.rgb(c.color or "#FFFFFF")
	local tint = b.tint
	local ems = M.EMITTERS[kind]
	tint.x, tint.y, tint.z, tint.w = r, g, bl, 1
	for i = 1, #ems do particlefx.set_constant(b.url, ems[i], "tint", tint) end
	self.live = self.live + n
end

-- a soft light (flash) ---------------------------------------------------------------

local function step_flash(self, fx, k)
	local c, o = fx.c, fx[1]
	local base = c.size / 256
	local s = base * (0.55 + 0.85 * (1 - (1 - k) * (1 - k)))
	apply(o, "fx_flash", c.x + self.sx, c.y + self.sy, M.Z.flash, s, s, 0, 0, nil, 0.85 * (1 - k), fx.cr, fx.cg, fx.cb)
end

function START.flash(self, c)
	local o = self:_sprite("glow")
	if not o then return end
	local fx = self:_new_fx(step_flash, c, "time", self.t, c.dur or 0.35)
	fx.cr, fx.cg, fx.cb = view.rgb(c.color)
	self:_attach(fx, o)
end

-- a glow that swells until the end of its duration, then fades (charging) ---------------

local function step_charge(self, fx, k, age, after_k)
	local c, o = fx.c, fx[1]
	local grow = k * k
	local s = c.size / 256 * (0.3 + 0.7 * grow)
	local alpha = (0.15 + 0.5 * grow) * (after_k and (1 - after_k) or 1)
	apply(o, "fx_flash", c.x + self.sx, c.y + self.sy, M.Z.charge, s, s, 0, 0, nil, alpha, fx.cr, fx.cg, fx.cb)
end

function START.charge(self, c)
	local o = self:_sprite("glow")
	if not o then return end
	local fx = self:_new_fx(step_charge, c, "tick", c.at, math.max(c.dur or 12, 1), 0.2)
	fx.cr, fx.cg, fx.cb = view.rgb(c.color)
	self:_attach(fx, o)
end

-- a comet bolt: a bright head with a dim tail along (dx, dy), or a band that fills ----------

local function step_beam(self, fx, k, age, after_k)
	local c = fx.c
	local body, bolt, head, core = fx[1], fx[2], fx[3], fx[4]
	local cell = fx.cell
	local rot = (c.dy ~= 0) and 90 or 0
	local fade = after_k and (1 - after_k) or 1
	local flick = 1 + (self.reduced and 0 or 0.14 * math.sin(age * 2.3))
	local r, g, b = fx.cr, fx.cg, fx.cb
	local reach = c.len * k                              -- head position along the line
	local w = c.width
	if c.mode == "band" then
		-- row / column light: a soft band that fills up behind the head, then fades
		if after_k then reach = c.len end
		local len = math.max(reach, 1)
		local cx, cy = c.x + c.dx * len / 2, c.y + c.dy * len / 2
		apply(body, "fx_glow_dot", cx + self.sx, cy + self.sy, M.Z.beam, len / 64, w * flick / 64, rot, 0, nil, 0.75 * fade,
			r, g, b)
		apply(bolt, "fx_bolt", cx + self.sx, cy + self.sy, M.Z.beam + 0.005, len / 256, w * 0.5 / 48, rot, 0, nil,
			0.9 * fade, r, g, b)
		if core then
			apply(core, "fx_bolt", cx + self.sx, cy + self.sy, M.Z.beam + 0.01, len / 256, w * 0.2 / 48, rot, 0, nil, fade,
				1, 1, 1)
		end
	else
		-- a comet: a soft body of colour with a lightning bolt in it, brightest at the head;
		-- at the edge the tail catches up with the head and the bolt goes out
		local tl, bl
		if after_k then
			reach = c.len
			tl = math.min(c.len, M.COMET * cell) * fade
			bl = math.min(c.len, M.COMET_BRIGHT * cell) * fade
		else
			tl = math.min(reach, M.COMET * cell)
			bl = math.min(reach, M.COMET_BRIGHT * cell)
		end
		local hx, hy = c.x + c.dx * reach, c.y + c.dy * reach
		tl, bl = math.max(tl, 1), math.max(bl, 1)
		apply(body, "fx_glow_dot", hx - c.dx * tl / 2 + self.sx, hy - c.dy * tl / 2 + self.sy, M.Z.beam, tl / 64,
			w * flick / 64, rot, 0, nil, 0.7 * fade, r, g, b)
		local bx, by = hx - c.dx * bl / 2 + self.sx, hy - c.dy * bl / 2 + self.sy
		apply(bolt, "fx_bolt", bx, by, M.Z.beam + 0.005, bl / 256, w * 1.1 * flick / 48, rot, 0, nil, fade, r, g, b)
		if core then
			apply(core, "fx_bolt", bx, by, M.Z.beam + 0.01, bl / 256, w * 0.45 * flick / 48, rot, 0, nil, fade, 1, 1, 1)
		end
	end
	local hs = w * 1.5 / 64
	apply(head, "fx_glow_dot", c.x + c.dx * reach + self.sx, c.y + c.dy * reach + self.sy, M.Z.head, hs, hs, 0, 0.6, nil,
		fade, r, g, b)
end

function START.beam(self, c)
	local dim, bright, head = self:_sprite("glow"), self:_sprite("glow"), self:_sprite("glow")
	local core = (c.core and not self.lite) and self:_sprite("glow") or nil
	if not (dim and bright and head) then
		if dim then self:_release(dim) end
		if bright then self:_release(bright) end
		if head then self:_release(head) end
		if core then self:_release(core) end
		return
	end
	local travel = math.max(c.len / c.speed, 1)
	local fx = self:_new_fx(step_beam, c, "tick", c.at, travel, 0.24)
	fx.cr, fx.cg, fx.cb = view.rgb(c.color)
	fx.cell = self.geom and self.geom.cell or 80
	if core then self:_attach(fx, dim, bright, head, core) else self:_attach(fx, dim, bright, head) end
end

-- an expanding shock ring ------------------------------------------------------------------

local function step_ring(self, fx, k)
	local c, o = fx.c, fx[1]
	local img = c.image or "fx_shock"
	local w = size_of(img)
	local s = c.size / w * (0.35 + 0.65 * (1 - (1 - k) ^ 2))
	apply(o, img, c.x + self.sx, c.y + self.sy, M.Z.ring, s, s, 0, 0, nil, 0.85 * (1 - k), fx.cr, fx.cg, fx.cb)
end

function START.ring(self, c)
	local o = self:_sprite("piece")
	if not o then return end
	local fx = self:_new_fx(step_ring, c, "time", self.t, c.dur or 0.32)
	fx.cr, fx.cg, fx.cb = view.rgb(c.color)
	self:_attach(fx, o)
end

-- the Bird: a Bezier arc with a trail and, if it carries one, the cargo special -----------------

local function step_dot(self, fx, k)
	local o = fx[1]
	local s = fx.size * (1 - 0.7 * k)
	apply(o, "fx_glow_dot", fx.x + self.sx, fx.y + self.sy, M.Z.dot, s, s, 0, 0, nil, 0.8 * (1 - k), fx.cr, fx.cg, fx.cb)
end

-- a fading dot of a trail
function Vfx:_dot(x, y, size, r, g, b)
	local o = self:_sprite("glow")
	if not o then return end
	local fx = self:_new_fx(step_dot, nil, "time", self.t, 0.32)
	fx.x, fx.y, fx.cr, fx.cg, fx.cb, fx.size = x, y, r, g, b, size / 64
	self:_attach(fx, o)
end

local function step_fly(self, fx, k, age)
	local c = fx.c
	local bird, carry = fx[1], fx[2]
	local cell = fx.cell
	local e = k < 0.5 and 2 * k * k or 1 - (-2 * k + 2) ^ 2 / 2
	local u = 1 - e
	local x = u * u * c.x0 + 2 * u * e * fx.cx + e * e * c.x1
	local y = u * u * c.y0 + 2 * u * e * fx.cy + e * e * c.y1
	local k0 = cell / 160
	local s = k0 * (1.15 + 0.25 * math.sin(k * math.pi))
	local tilt = self.reduced and 0 or 12 * math.sin(age * 0.9)
	apply(bird, "specials_bird", x + self.sx, y + self.sy, M.Z.fly, s, s, tilt, 0, nil, 1)
	if carry then
		-- the cargo hangs from the bird's feet, in front of it
		local cs = k0 * 0.62
		apply(carry, c.carry, x + self.sx, y - cell * 0.62 + self.sy, M.Z.fly + 0.005, cs, cs,
			c.axis == "v" and 90 or 0, 0, nil, 1)
	end
	if not (self.reduced or self.lite) then
		fx.n_trail = fx.n_trail + 1
		if fx.n_trail % 3 == 0 then self:_dot(x, y, cell * 0.5, fx.cr, fx.cg, fx.cb) end
	end
end

function START.fly(self, c)
	local bird = self:_sprite("piece")
	if not bird then return end
	local carry = c.carry and self:_sprite("piece") or nil
	local cell = self.geom and self.geom.cell or 80
	local dx, dy = c.x1 - c.x0, c.y1 - c.y0
	local len = math.sqrt(dx * dx + dy * dy)
	-- control point: the middle lifted up and pushed sideways; a Trio fans its three arcs out
	local fan = c.fan or 0
	local lift = math.max(cell * 1.2, len * 0.35)
	local fx = self:_new_fx(step_fly, c, "tick", c.at, math.max(c.dur or 33, 1))
	local cx = (c.x0 + c.x1) / 2 - (len > 0 and dy / len or 0) * lift * 0.4
	local cy = (c.y0 + c.y1) / 2 + lift
	if fan ~= 0 and len > 0 then
		cx = cx - dy / len * fan * cell * 1.8
		cy = cy + dx / len * fan * cell * 1.8
	end
	fx.cx, fx.cy = cx, cy
	fx.cell = cell
	fx.cr, fx.cg, fx.cb = view.rgb(c.trail or "#7EF0FF")
	if dx < 0 then
		bird.flipped = true
		sprite.set_hflip(bird.url, true)
	end
	if carry then self:_attach(fx, bird, carry) else self:_attach(fx, bird) end
end

-- the Bird's target: a ring that closes in while the bird flies ---------------------------------

local function step_reticle(self, fx, k, age, after_k)
	local c, o = fx.c, fx[1]
	local grow = 1.7 - 0.75 * k
	local pulse = self.reduced and 0 or 0.06 * math.sin(age * 0.7)
	local s = c.size / 128 * (grow + pulse)
	local alpha = (0.45 + 0.4 * k) * (after_k and (1 - after_k) or 1)
	apply(o, "fx_ring", c.x + self.sx, c.y + self.sy, M.Z.reticle, s, s, k * 90, 0, nil, alpha, fx.cr, fx.cg, fx.cb)
end

function START.reticle(self, c)
	local o = self:_sprite("glow")
	if not o then return end
	local fx = self:_new_fx(step_reticle, c, "tick", c.at, math.max(c.dur or 33, 1), 0.18)
	fx.cr, fx.cg, fx.cb = view.rgb(c.color)
	self:_attach(fx, o)
end

-- a Disco ray -------------------------------------------------------------------------------------

local function step_ray(self, fx, k)
	local c, o = fx.c, fx[1]
	local grow = k / 0.25
	if grow > 1 then grow = 1 end
	local l = fx.len * grow
	local x, y = c.x0 + fx.dx / fx.len * l / 2, c.y0 + fx.dy / fx.len * l / 2
	local alpha = k < 0.35 and 1 or (1 - (k - 0.35) / 0.65)
	apply(o, "fx_ray", x + self.sx, y + self.sy, M.Z.ray, l / 256, fx.thick / 16, fx.rot, 0, nil, alpha, fx.cr, fx.cg, fx.cb)
end

function START.ray(self, c)
	local o = self:_sprite("glow")
	if not o then return end
	local dx, dy = c.x1 - c.x0, c.y1 - c.y0
	local fx = self:_new_fx(step_ray, c, "time", self.t, c.dur or 0.34)
	fx.dx, fx.dy = dx, dy
	fx.len = math.max(math.sqrt(dx * dx + dy * dy), 1)
	fx.rot = math.deg(math.atan2(dy, dx))
	local cell = self.geom and self.geom.cell or 80
	fx.thick = cell * (c.width or 0.28)
	fx.cr, fx.cg, fx.cb = view.rgb(c.color)
	self:_attach(fx, o)
end

-- noise creeping over to a piece ------------------------------------------------------------------

local function step_creep(self, fx, k)
	local c, o = fx.c, fx[1]
	local x, y = c.x0 + (c.x1 - c.x0) * k, c.y0 + (c.y1 - c.y0) * k
	local s = fx.cell * (0.9 - 0.4 * k) / 256
	apply(o, "fx_cloud", x + self.sx, y + self.sy, M.Z.creep, s, s, 0, 0, nil, 0.9 * (1 - k * 0.6), fx.cr, fx.cg, fx.cb)
end

function START.creep(self, c)
	local o = self:_sprite("piece")
	if not o then return end
	local fx = self:_new_fx(step_creep, c, "tick", c.at, 12)
	fx.cell = self.geom and self.geom.cell or 80
	fx.cr, fx.cg, fx.cb = view.rgb("#8A8FA3")
	self:_attach(fx, o)
end

-- a lingering copy of something that was destroyed ------------------------------------------------------

local function step_ghost(self, fx, k)
	local c, o = fx.c, fx[1]
	local e = 1 - (1 - k) * (1 - k)
	local s0, s1 = c.s0 or 1, c.s1 or 1
	local s = fx.base * (s0 + (s1 - s0) * e)
	local rot = (c.rot0 or 0) + ((c.rot1 or 0) - (c.rot0 or 0)) * e
	local alpha = (c.a0 or 1) + ((c.a1 or 0) - (c.a0 or 1)) * k
	local y = c.y + (c.dy or 0) * e
	apply(o, c.image, c.x + self.sx, y + self.sy, M.Z.ghost, s, s, self.reduced and 0 or rot, c.flash or 0, nil, alpha)
end

function START.ghost(self, c)
	local o = self:_sprite("piece")
	if not o then return end
	local fx = self:_new_fx(step_ghost, c, "time", self.t, c.dur or 0.4)
	fx.base = (self.geom and self.geom.cell or 80) / 160
	self:_attach(fx, o)
end

-- the microphone stinger: a note rises, a ring closes it -----------------------------------------------------

local function step_note(self, fx, k)
	local c, o = fx.c, fx[1]
	local s = fx.cell * 0.6 / 48 * (k < 0.2 and k / 0.2 * 1.2 or 1.2 - 0.2 * k)
	apply(o, "fx_note", c.x + self.sx, c.y + fx.cell * 1.4 * k + self.sy, M.Z.stinger, s, s,
		self.reduced and 0 or 15 * math.sin(k * 9), 0, nil, 1 - k * k, fx.cr, fx.cg, fx.cb)
end

function START.stinger(self, c)
	local note = self:_sprite("piece")
	if not note then return end
	local cell = self.geom and self.geom.cell or 80
	local fx = self:_new_fx(step_note, c, "time", self.t, 0.8)
	fx.cell = cell
	fx.cr, fx.cg, fx.cb = view.rgb("#FFB020")
	self:_attach(fx, note)
	START.ring(self, { x = c.x, y = c.y, size = cell * 1.8, dur = 0.4, color = "#FFD84D", image = "fx_ring" })
end

function START.shake(self, c)
	if self.reduced then return end
	local list = self.shakes
	list[#list + 1] = { amp = c.amp, dur = c.dur, t0 = self.t }
end

function START.slowmo(self, c)
	if not self.reduced then self.on_slowmo(c.dur, c.scale) end
end

-- frame ---------------------------------------------------------------------------------------------------

function Vfx:_shake_offset()
	local x, y = 0, 0
	local list = self.shakes
	local n, w = #list, 0
	for i = 1, n do
		local s = list[i]
		local age = self.t - s.t0
		if age < s.dur then
			w = w + 1
			list[w] = s
			local d = 1 - age / s.dur
			d = d * d
			x = x + s.amp * d * math.sin(age * 71)
			y = y + s.amp * d * 0.7 * math.cos(age * 57)
		end
	end
	for i = n, w + 1, -1 do list[i] = nil end
	return x, y
end

-- Advances every effect. Returns the board shake offset (logical px).
function Vfx:update(dt, tick_f, t)
	self.t = t
	self.sx, self.sy = self:_shake_offset()
	-- live particles now
	local live = 0
	for _, kind in ipairs(M.KINDS) do
		local pool = self.bursts[kind]
		for i = 1, #pool do
			local b = pool[i]
			if b.busy_until > t then live = live + b.n end
		end
	end
	self.live = live
	-- start what is due
	local h = self.heap
	while h[1] and h[1].at <= tick_f + 1e-6 do
		self:_start(self:_pop())
	end
	-- run effects
	local act = self.active
	local n, w = #act, 0
	for i = 1, n do
		local fx = act[i]
		local age, k
		if fx.clock == "tick" then age = tick_f - fx.t0 else age = t - fx.t0 end
		k = age / fx.dur
		local done = false
		if k < 0 then
			for j = 1, fx.n do view.hide(fx[j]) end
		elseif k <= 1 then
			fx.step(self, fx, k, age)
		elseif fx.after then
			fx.after_t0 = fx.after_t0 or t
			local ak = (t - fx.after_t0) / fx.after
			if ak >= 1 then done = true else fx.step(self, fx, 1, age, ak) end
		else
			if not fx.ended then
				fx.ended = true
				fx.step(self, fx, 1, age)
			end
			done = true
		end
		if done then
			self:_free_fx(fx)
		else
			w = w + 1
			act[w] = fx
		end
	end
	-- effects started by a running one (the Bird's trail dots) were appended behind the old ones
	local m = #act
	for i = n + 1, m do
		w = w + 1
		act[w] = act[i]
	end
	for i = m, w + 1, -1 do act[i] = nil end
	return self.sx, self.sy
end

-- Skip / leaving: every running effect and pending command is dropped.
function Vfx:clear()
	local act = self.active
	for i = #act, 1, -1 do
		self:_free_fx(act[i])
		act[i] = nil
	end
	local h = self.heap
	for i = #h, 1, -1 do h[i] = nil end
	local sh = self.shakes
	for i = #sh, 1, -1 do sh[i] = nil end
	for _, kind in ipairs(M.KINDS) do
		local pool = self.bursts[kind]
		for i = 1, #pool do
			local b = pool[i]
			pcall(particlefx.stop, b.url, { clear = true })
			b.busy_until = 0
		end
	end
	self.live = 0
end

function Vfx:stats()
	return { sprites = self.sprites, active = #self.active, pending = #self.heap, bursts = self.bursts_n,
		particles = self.live, skipped = self.skipped, played = self.played, lite = self.lite }
end

-- Quality controller (pure): feed it the frame time, it says when the device is
-- too slow for the full effects (lite mode) and when it has recovered.
--   local q = level_vfx.quality(); lite = q:frame(dt)
function M.quality(opts)
	opts = opts or {}
	local Q = { avg = 1 / 60, lite = false, slow_for = 0, fast_for = 0,
		slow_dt = opts.slow_dt or (1 / 36), fast_dt = opts.fast_dt or (1 / 50),
		slow_after = opts.slow_after or 2.0, fast_after = opts.fast_after or 6.0 }
	function Q:frame(dt)
		dt = math.min(tonumber(dt) or 0, 0.25)
		self.avg = self.avg + (dt - self.avg) * 0.08
		if self.avg > self.slow_dt then
			self.slow_for, self.fast_for = self.slow_for + dt, 0
			if not self.lite and self.slow_for >= self.slow_after then self.lite = true end
		elseif self.avg < self.fast_dt then
			self.fast_for, self.slow_for = self.fast_for + dt, 0
			if self.lite and self.fast_for >= self.fast_after then self.lite = false end
		else
			self.slow_for, self.fast_for = 0, 0
		end
		return self.lite
	end
	return Q
end

return M
