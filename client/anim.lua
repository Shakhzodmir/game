-- Animations as data, played by a small state machine (pure Lua: no gui, no engine; content/animations.json).
--
--   local anim = require("client.anim")
--   local problems = anim.validate(data)            -- {} when the file is consistent
--   local p = anim.new(data.bit, { rng = math.random, on_sound = function(name, gain) end, reduced = false })
--   local changed = p:update(dt, clock)             -- every frame; true when the picture or the state changed
--   p:image()  p.state  p.pose                      -- what to draw: image key, state name, {dx, dy, sx, sy, rot}
--   p:trigger("task_done")                          -- a game event picks a state (data: events)
--   p:play("write", { hold = 3 })                   -- a state by name (opts: loops, hold, until_released)
--   p:set_dance(true, bpm)                          -- dance a/b on the beat; `clock` of update() (seconds of the
--                                                   -- playing track, client/audio.lua status.clock) locks the frames to it
--   p:touch()                                       -- the player did something: boredom restarts, a sleeper wakes
--   p:release()                                     -- ends a state started with until_released (the notebook)
--   p:set_reduced(true)                             -- reduced motion: still frames, no idle variants, no sway
--   anim.item_motion(spec)                          -- room items: the tweens the GUI loops (screens/town/life.lua)
--
-- The shape of a character (def = data.bit):
--   anims   name -> {prefix, frames | images, fps | beats, mode loop|pingpong|once, loop_from, rest, sway, events}
--   states  name -> {anim, loops, next, priority}; a state ends when its loops (or its single pass, or its `hold`)
--           are done and goes to `next` (default "idle"); a state without loops that never ends: dance, write, sleepy
--   idle    {base, gap = {min, max}, variants = {{state, weight}}, bored_after}: after a random gap a variant plays
--           once, after `bored_after` seconds without a touch Bit falls asleep ("sleepy")
--   events  name -> {pick = {{state, weight}}, hold, until_released}
-- Randomness is only the rng handed in; nothing allocates per frame.

local M = {}

local floor, sin, abs, pi, max, min = math.floor, math.sin, math.abs, math.pi, math.max, math.min

M.MODES = { loop = true, pingpong = true, once = true }
M.SWAY = { none = true, breathe = true, rock = true, bounce = true }
M.ITEM_KINDS = { bob = true, sway = true, swing = true, breathe = true, pulse = true, bounce = true }

-- validation --------------------------------------------------------------------------------------------------------

function M.validate(data)
	local bad = {}
	local function err(fmt, ...) bad[#bad + 1] = string.format(fmt, ...) end
	local def = type(data) == "table" and data.bit
	if type(def) ~= "table" then return { "no bit section" } end
	local anims, states = def.anims or {}, def.states or {}
	for name, a in pairs(anims) do
		if not M.MODES[a.mode or "loop"] then err("anim %s: bad mode %s", name, tostring(a.mode)) end
		if a.images then
			if type(a.images) ~= "table" or #a.images == 0 then err("anim %s: empty images", name) end
		elseif type(a.prefix) ~= "string" or type(a.frames) ~= "number" or a.frames < 1 then
			err("anim %s: needs prefix and frames or images", name)
		end
		local n = a.images and #a.images or a.frames or 0
		if not a.beats and not (type(a.fps) == "number" and a.fps > 0) and n > 1 then err("anim %s: needs fps or beats", name) end
		if a.loop_from and (a.loop_from < 1 or a.loop_from > n) then err("anim %s: bad loop_from", name) end
		if a.sway and not M.SWAY[a.sway.kind] then err("anim %s: bad sway kind", name) end
		for _, e in ipairs(a.events or {}) do
			if type(e.frame) ~= "number" or e.frame < 1 or e.frame > n then err("anim %s: event frame out of range", name) end
			if type(e.sfx) ~= "string" then err("anim %s: event without sfx", name) end
		end
	end
	for name, s in pairs(states) do
		if not anims[s.anim] then err("state %s: unknown anim %s", name, tostring(s.anim)) end
		if s.next and not states[s.next] then err("state %s: unknown next %s", name, tostring(s.next)) end
	end
	if not states.idle then err("no idle state") end
	local idle = def.idle or {}
	if not (idle.gap and idle.gap[1] and idle.gap[2] and idle.gap[1] > 0 and idle.gap[2] >= idle.gap[1]) then err("idle: bad gap") end
	for _, v in ipairs(idle.variants or {}) do
		if not states[v.state] or not (v.weight and v.weight > 0) then err("idle: bad variant %s", tostring(v.state)) end
	end
	if #(idle.variants or {}) < 2 then err("idle: needs at least two variants") end
	if not states[def.wake or ""] then err("wake: unknown state") end
	for _, st in ipairs(def.dance and def.dance.states or {}) do
		if not states[st] or not anims[states[st].anim].beats then err("dance: %s is not a beat animation", tostring(st)) end
	end
	for name, ev in pairs(def.events or {}) do
		if type(ev.pick) ~= "table" or #ev.pick == 0 then err("event %s: empty pick", name) end
		for _, c in ipairs(ev.pick or {}) do
			if not states[c.state] or not (c.weight and c.weight > 0) then err("event %s: bad choice %s", name, tostring(c.state)) end
		end
	end
	local items = data.items or {}
	local function kind_ok(spec, what)
		if not (M.ITEM_KINDS[spec.kind] and (spec.period or 0) > 0 and (spec.amp or 0) > 0) then err("items %s: bad spec", what) end
	end
	kind_ok(items.default or {}, "default")
	for id, spec in pairs(items.tasks or {}) do kind_ok(spec, id) end
	return bad
end

-- every image key a character can show (the scene keeps them from being released, the linter checks the files)
function M.images(def)
	local out = {}
	for _, a in pairs(def.anims) do -- order-free: a set
		if a.images then
			for _, k in ipairs(a.images) do out[k] = true end
		else
			for i = 1, a.frames do out[a.prefix .. i] = true end
		end
	end
	return out
end

-- the player --------------------------------------------------------------------------------------------------------

local Player = {}
Player.__index = Player

function M.new(def, opts)
	opts = opts or {}
	local self = setmetatable({
		def = def, rng = opts.rng or math.random, on_sound = opts.on_sound, reduced = opts.reduced and true or false,
		keys = {}, n = {}, pose = { dx = 0, dy = 0, sx = 1, sy = 1, rot = 0 },
		state = "idle", st = nil, anim = nil, aname = nil, frame = 1, step = -1, t = 0, loops_done = 0,
		loops = nil, hold = nil, released = true, forever = false, idle_t = 0, gap = 0, quiet = 0, last_variant = nil,
		dancing = false, bpm = 100, dance_t = 0, sway_t = 0, beat = 0, rest = 1, changed = false,
	}, Player)
	for name, a in pairs(def.anims) do -- order-free: fills tables
		local ks = {}
		if a.images then
			for i, k in ipairs(a.images) do ks[i] = k end
		else
			for i = 1, a.frames do ks[i] = a.prefix .. i end
		end
		self.keys[name], self.n[name] = ks, #ks
	end
	self:_enter("idle")
	return self
end

local function pick(self, list)
	local total = 0
	for i = 1, #list do total = total + list[i].weight end
	local r = self.rng() * total
	for i = 1, #list do
		r = r - list[i].weight
		if r < 0 then return list[i] end
	end
	return list[#list]
end

local function random_gap(self)
	local g = self.def.idle.gap
	return g[1] + (g[2] - g[1]) * self.rng()
end

-- the frame shown at integer step k (>= 0); wrap = a once animation that repeats (loops > 1) wraps like a loop
local function frame_at(a, n, k, wrap)
	local mode = a.mode or "loop"
	if n == 1 then return 1 end
	if mode == "once" and wrap then mode = "loop" end
	if mode == "loop" then return k % n + 1 end
	if mode == "pingpong" then
		local c = 2 * n - 2
		local q = k % c
		return q < n and q + 1 or 2 * n - 1 - q
	end
	if k < n then return k + 1 end -- once
	local lf = a.loop_from
	if lf and lf < n then -- a tail that goes back and forth between loop_from and the last frame
		local m = n - lf + 1
		local c = 2 * m - 2
		local q = (k - (n - 1)) % c
		return n - (q < m and q or c - q)
	end
	return n
end

-- steps of one pass: n frames of a loop / once, 2n-2 of a pingpong
local function pass_len(a, n)
	if (a.mode or "loop") == "pingpong" and n > 1 then return 2 * n - 2 end
	return n
end

local function rate(self, a, n)
	if a.beats then return n / (a.beats * 60 / self.bpm) end
	return a.fps or 1
end

function Player:_enter(state, o)
	o = o or {}
	local st = self.def.states[state]
	local a = self.def.anims[st.anim]
	local n = self.n[st.anim]
	self.state, self.st, self.aname, self.anim = state, st, st.anim, a
	self.t, self.step, self.frame = 0, -1, 1
	self.loops, self.hold = o.loops or st.loops, o.hold
	self.released = not o.until_released
	local mode = a.mode or "loop"
	local repeating = mode ~= "once" or a.loop_from ~= nil
	self.forever = state == "idle" or not self.released or (repeating and self.loops == nil and self.hold == nil)
	if state == "idle" then self.idle_t, self.gap = 0, random_gap(self) end
	self.rest = a.rest or floor((n + 1) / 2)
	if self.reduced then self.frame = self.rest end
	self.changed = true
end

-- Plays a state. opts: loops, hold (seconds the state lasts at least), until_released.
function Player:play(state, opts)
	if not self.def.states[state] then return false end
	self.quiet = 0
	self:_enter(state, opts)
	return true
end

-- A game event picks a state by the weights in the data. A running state of a higher priority (and a dance) is
-- not interrupted; the same state again restarts it (a second tap is felt).
function Player:trigger(name)
	local ev = self.def.events[name]
	if not ev then return nil end
	self.quiet = 0
	local c = pick(self, ev.pick)
	if self.dancing or (self.def.states[c.state].priority or 0) < (self.st.priority or 0) then return nil end
	self:_enter(c.state, { hold = ev.hold, until_released = ev.until_released })
	return c.state
end

-- The player did something: boredom restarts and a sleeper wakes up (the `wake` state).
function Player:touch()
	self.quiet = 0
	if self.state == "sleepy" then self:_enter(self.def.wake) end
end

-- Ends a state that was started with until_released.
function Player:release()
	if self.released then return end
	self.released, self.forever, self.hold, self.loops = true, false, 0, nil
end

function Player:set_reduced(on)
	on = on and true or false
	if on == self.reduced then return end
	self.reduced = on
	local p = self.pose
	p.dx, p.dy, p.sx, p.sy, p.rot = 0, 0, 1, 1, 0
	if on and self.state == "sleepy" then self:_enter("idle") end
	self.rest = self.anim.rest or floor((self.n[self.aname] + 1) / 2)
	self.changed = true
end

function Player:set_dance(on, bpm)
	if bpm then self.bpm = max(40, min(220, bpm)) end
	on = on and true or false
	if on == self.dancing then return end
	self.dancing, self.quiet, self.dance_t = on, 0, 0
	self:_enter(on and self.def.dance.states[1] or "idle")
	if on then self.forever = true end
end

local function sound_steps(self, a, from, to, n)
	local ev = a.events
	if not ev or not self.on_sound or self.reduced then return end
	for k = max(from + 1, to - 2 * n), to do
		local f = frame_at(a, n, k, self.loops ~= nil)
		for i = 1, #ev do
			if ev[i].frame == f then self.on_sound(ev[i].sfx, ev[i].gain) end
		end
	end
end

local function sway(self, dt)
	local p, sw = self.pose, self.anim.sway
	p.dx, p.dy, p.sx, p.sy, p.rot = 0, 0, 1, 1, 0
	if self.reduced or not sw or sw.kind == "none" then return end
	self.sway_t = self.sway_t + dt
	local kind, amp = sw.kind, sw.amp or 0.03
	if kind == "bounce" then -- on the beat: up and down once per beat, a squash at the bottom
		local s = abs(sin(pi * self.beat))
		p.dy = amp * s
		p.sy = 1 + amp * 0.6 * (s - 0.5)
		p.sx = 1 - amp * 0.4 * (s - 0.5)
		return
	end
	local s = sin(2 * pi * self.sway_t / (sw.period or 2))
	if kind == "breathe" then
		p.sy, p.sx = 1 - amp * s, 1 + amp * s
		p.dy = (p.sy - 1) * 0.5 -- the feet stay on the ground
	elseif kind == "rock" then
		p.rot = amp * s
	end
end

-- Has the running state played what it was asked to?
local function finished(self, a, n)
	local passes = self.loops or 1
	local pass_done = self.step >= passes * pass_len(a, n)
	if self.hold ~= nil then
		return self.released and self.t >= self.hold and (self.loops == nil or pass_done)
	end
	return self.released and pass_done
end

-- Advances by dt seconds. clock: seconds of the playing track (locks the dance to it) or nil. Returns true when
-- the image or the state changed since the last call.
function Player:update(dt, clock)
	local prev_frame, prev_aname = self.frame, self.aname
	if self.dancing then
		if clock and clock >= 0 then self.dance_t = clock else self.dance_t = self.dance_t + dt end
		local b = self.dance_t * self.bpm / 60
		self.beat = b - floor(b)
		local d = self.def.dance
		local want = d.states[floor(b / (d.beats_per_state or 4)) % #d.states + 1]
		if want ~= self.state then
			self:_enter(want)
			self.forever = true
		end
	else
		self.beat = 0
	end
	local a = self.anim
	local n = self.n[self.aname]
	if self.dancing and a.beats then
		-- the frames follow the beat clock: one pass is `beats` beats
		local cyc = a.beats * 60 / self.bpm
		self.step = floor((self.dance_t % cyc) / cyc * n)
		self.frame = self.reduced and self.rest or self.step + 1
	else
		self.t = self.t + dt
		local k = floor(self.t * rate(self, a, n))
		local from = self.step
		self.step = k
		self.frame = self.reduced and self.rest or frame_at(a, n, k, self.loops ~= nil)
		if k ~= from then sound_steps(self, a, from, k, n) end
	end
	sway(self, dt)
	self.quiet = self.quiet + dt -- time since the player last did anything (touch / event / play)
	if self.state == "idle" then
		if not self.reduced then
			local idle = self.def.idle
			self.idle_t = self.idle_t + dt
			if idle.bored_after and self.quiet >= idle.bored_after and self.def.states.sleepy then
				self:_enter("sleepy")
			elseif self.idle_t >= self.gap then
				local c = pick(self, idle.variants)
				if c.state == self.last_variant then c = pick(self, idle.variants) end
				self.last_variant = c.state
				self:_enter(c.state)
			end
		end
	elseif not self.forever and finished(self, a, n) then
		self:_enter(self.st.next or "idle")
	end
	local changed = self.changed or self.frame ~= prev_frame or self.aname ~= prev_aname
	self.changed = false
	return changed
end

function Player:image()
	return self.keys[self.aname][self.frame]
end

-- room items ------------------------------------------------------------------------------------------------------------

-- The tweens a GUI loops for an item (spec = items.default / items.tasks[id] of the data): a list of
-- {prop, from, to, easing ("inoutsine" | "outquad"), dur} in item-relative terms: prop is a GUI property path,
-- from/to are DELTAS added to the node's rest value (scale props: factors), applied by screens/town/life.lua.
-- Every tween is a ping-pong loop, so the whole cycle takes `dur * 2`; dur = period / 2.
function M.item_motion(spec)
	local k, amp, half = spec.kind, spec.amp, spec.period / 2
	if k == "bob" then
		return { { prop = "position.y", from = 0, to = amp, easing = "inoutsine", dur = spec.period } }
	elseif k == "bounce" then
		return { { prop = "position.y", from = 0, to = amp, easing = "outquad", dur = half } }
	elseif k == "sway" or k == "swing" then
		return { { prop = "euler.z", from = -amp, to = amp, easing = "inoutsine", dur = half, rest = false } }
	elseif k == "breathe" then
		return {
			{ prop = "scale.y", from = 1, to = 1 + amp, easing = "inoutsine", dur = half, factor = true },
			{ prop = "scale.x", from = 1, to = 1 - amp * 0.5, easing = "inoutsine", dur = half, factor = true },
		}
	end
	-- pulse
	return {
		{ prop = "scale.x", from = 1, to = 1 + amp, easing = "outquad", dur = half, factor = true },
		{ prop = "scale.y", from = 1, to = 1 + amp, easing = "outquad", dur = half, factor = true },
	}
end

return M
