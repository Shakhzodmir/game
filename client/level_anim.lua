-- How each object of the board looks this frame (pure Lua): position,
-- squash, rotation, image, white flash, alpha and the clip line of pieces
-- entering at a spawner. The core owns where things are and when they
-- change (core-rules.md 16, 17.3); this module only adds the visual extras
-- on top (client-architecture.md, 4.1):
--
--   touch x1.08 in 0.08 s; swap / failed swap (there with an 8 % overshoot and
--   back) / swap back, the dragged piece on top; landing squash 0.88 / 1.08 with
--   a spring; clear: pop x1.15 in 3 ticks, then shrink to 0 by the end of
--   T.clear (9 ticks); pieces of a group that makes a special fly into its
--   cell; a new special grows 0 -> 1.2 -> 1.0 with a white flash; transforms
--   flash and pop; armed specials pulse (the Sabwoofer swells); blockers
--   wobble when hit; shuffled pieces fly to their new cells; the selected
--   piece stays big; the hint pair wobbles towards each other.
--
--   local level_anim = require("client.level_anim")
--   local A = level_anim.new({geom = g, reduced = false})
--   A:event(e, t)                 -- every core event (t = real seconds)
--   A:touch(id, t)                -- a finger went down on a piece
--   A:select(id)                  -- the selection (nil = none)
--   A:hint(a, b, phase)           -- hint cells {x, y} and wobble phase 0..1 (nil = none)
--   local list = A:frame(game:pieces(), tick_f, t)
--   -- list[k] = {id, image, x, y, z, sx, sy, rot, scale, flash, alpha, clip}
--   --   x, y: logical centre; scale: art px -> logical px (cell / 160);
--   --   sx, sy: extra squash; rot: degrees; clip: logical y above which the
--   --   sprite is cut (nil = none); alpha 0 = do not draw.
--
-- Times: core-synced effects (swaps, clears, flights) run on the display
-- tick (tick + fraction, session:display_tick()); client-only extras
-- (touch, squash, appear, flashes) on real seconds.

local level_hint = require("client.level_hint")

local M = {}

M.ART = 160             -- art px of one cell (pieces, blockers; specials are 192 incl. glow)
M.TOUCH_SCALE = 1.08
M.TOUCH_UP = 0.08       -- seconds to grow on touch
M.TOUCH_DOWN = 0.14     -- seconds back
M.SELECT_SCALE = 1.08
M.SQUASH_Y, M.SQUASH_X = 0.88, 1.08
M.SQUASH_TIME = 0.32    -- seconds of the landing spring
M.POP_TICKS = 3         -- clear: x1.15 in 3 ticks (0.05 s) ...
M.CLEAR_TICKS = 9       -- ... then down to 0 by T.clear (normal timing)
M.POP_SCALE = 1.15
M.APPEAR_TIME = 0.30    -- new special: 0 -> 1.2 -> 1.0
M.APPEAR_PEAK = 1.2
M.FLASH_TIME = 0.28     -- white flash fading out
M.HIT_TIME = 0.24       -- blocker wobble
M.FAIL_REACH = 0.35     -- share of a cell a failed swap travels
M.FAIL_OVERSHOOT = 0.08
M.SWELL_TICKS = 6       -- T.sub_swell
M.SWELL_SCALE = 1.35

M.Z = {
	blocker = 0.08, piece = 0.10, special = 0.11, mic = 0.10,
	selected = 0.12, swap_top = 0.13, swap_under = 0.115, fly = 0.14, gather = 0.14,
}

-- anim id in the game atlas for a piece of game:pieces(); max_hp: the
-- column's starting hp (its image follows the share left).
function M.image(p, max_hp)
	local k = p.kind
	if k == "regular" then return "pieces_" .. (p.color or "red") end
	if k == "special" then return "specials_" .. (p.special or "riff") end
	if k == "mic" then return "blockers_mic" end
	local item = p.item
	local hp = p.hp or 1
	if item == "record_box" then
		return "blockers_record_box_" .. math.max(1, math.min(3, hp))
	elseif item == "concrete" then
		return "blockers_concrete_" .. math.max(1, math.min(2, hp))
	elseif item == "balloon" then
		return "blockers_balloon_" .. (p.color or "red")
	elseif item == "column" then
		if p.state == "clear" or hp <= 0 then return "blockers_column_on" end
		local m = math.max(max_hp or hp, 1)
		local stage = math.ceil(hp / m * 3 - 1e-9)
		return "blockers_column_" .. math.max(1, math.min(3, stage))
	elseif item == "noise" then
		return "blockers_noise"
	end
	return "blockers_" .. tostring(item or "noise")
end

local function clamp01(v)
	if v < 0 then return 0 end
	if v > 1 then return 1 end
	return v
end
M.clamp01 = clamp01

local function ease_in_out(k)
	return k < 0.5 and 2 * k * k or 1 - (-2 * k + 2) ^ 2 / 2
end

local function ease_out(k)
	return 1 - (1 - k) * (1 - k)
end

local function ease_out_back(k, s)
	s = s or 1.70158
	local c3 = s + 1
	return 1 + c3 * (k - 1) ^ 3 + s * (k - 1) ^ 2
end
M.ease_in_out, M.ease_out, M.ease_out_back = ease_in_out, ease_out, ease_out_back

-- Landing spring: 1 at impact, decaying oscillation to 0.
function M.spring(t, total)
	total = total or M.SQUASH_TIME
	if t < 0 or t >= total then return 0 end
	local decay = math.exp(-t / (total * 0.28))
	return decay * math.cos(t / total * math.pi * 3)
end

-- Scale of a new special after `t` seconds: 0 -> PEAK at 55 %, -> 1.
function M.appear_scale(t)
	if t <= 0 then return 0 end
	local T = M.APPEAR_TIME
	if t >= T then return 1 end
	local k = t / T
	if k < 0.55 then return M.APPEAR_PEAK * ease_out(k / 0.55) end
	return M.APPEAR_PEAK + (1 - M.APPEAR_PEAK) * ease_in_out((k - 0.55) / 0.45)
end

-- Scale of a cleared piece `u` ticks into T.clear: pop then shrink.
function M.clear_scale(u, pop_ticks, clear_ticks)
	pop_ticks, clear_ticks = pop_ticks or M.POP_TICKS, clear_ticks or M.CLEAR_TICKS
	if u <= 0 then return 1 end
	if u < pop_ticks then return 1 + (M.POP_SCALE - 1) * (u / pop_ticks) end
	local rest = clear_ticks - pop_ticks
	if rest <= 0 then return 0 end
	return math.max(0, M.POP_SCALE * (1 - (u - pop_ticks) / rest))
end

-- Share of the way a failed swap has travelled at progress u (0..1):
-- out with a small overshoot, then back.
function M.fail_offset(u)
	u = clamp01(u)
	if u < 0.5 then
		return M.FAIL_REACH * ease_out_back(u / 0.5, M.FAIL_OVERSHOOT * 20)
	end
	return M.FAIL_REACH * (1 - ease_in_out((u - 0.5) / 0.5))
end

local Anim = {}
Anim.__index = Anim

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		geom = opts.geom,
		reduced = opts.reduced and true or false,
		vis = {},        -- id -> visual record
		out = {},        -- draw list (entries reused per id)
		selected = nil,
		hint_a = nil, hint_b = nil, hint_phase = nil,
		frame_n = 0,
		group = nil,     -- the last match: {t, cells = set, ids = {}, special}
		max_hp = {},     -- column id -> starting hp
	}, Anim)
end

function Anim:set_geom(g)
	self.geom = g
end

function Anim:set_reduced(on)
	self.reduced = on and true or false
end

local function rec(self, id)
	local v = self.vis[id]
	if not v then
		v = { born = self.frame_n, seen = self.frame_n }
		self.vis[id] = v
	end
	return v
end

function Anim:touch(id, t)
	if id then rec(self, id).touch = t end
end

function Anim:select(id)
	self.selected = id
end

function Anim:hint(a, b, phase)
	self.hint_a, self.hint_b, self.hint_phase = a, b, phase
end

local function cell_key(x, y)
	return x * 1000 + y
end

-- Core events that change how pieces look. t = real seconds now.
function Anim:event(e, t)
	local ty = e.type
	if ty == "swap" or ty == "swap_fail" or ty == "swap_back" then
		local a, b, ids = e.a, e.b, e.ids or {}
		local kind = ty == "swap_fail" and "fail" or (ty == "swap_back" and "back" or "swap")
		for k = 1, 2 do
			local id = ids[k]
			if id then
				local from, to = (k == 1) and a or b, (k == 1) and b or a
				rec(self, id).swap = {
					ax = from[1], ay = from[2], bx = to[1], by = to[2],
					t0 = e.t or 0, dur = math.max(e.duration or 10, 1), kind = kind, top = (k == 1),
				}
			end
		end
	elseif ty == "land" then
		local v = rec(self, e.id)
		v.land = t
	elseif ty == "match" then
		local set = {}
		for _, c in ipairs(e.cells or {}) do set[cell_key(c[1], c[2])] = true end
		self.group = { t = e.t, cells = set, ids = {}, special = e.special }
	elseif ty == "clear" then
		local v = rec(self, e.id)
		v.clear = { t0 = e.t or 0, cause = e.cause, kind = e.kind }
		local g = self.group
		if g and g.special and e.cause == "match" and g.t == e.t and g.cells[cell_key(e.x, e.y)] then
			g.ids[#g.ids + 1] = e.id
		end
	elseif ty == "special_new" then
		local v = rec(self, e.id)
		v.appear, v.flash = t, t
		local g = self.group
		if g and g.special and g.t == e.t then
			for _, id in ipairs(g.ids) do
				local c = rec(self, id).clear
				if c then c.gather = { e.x, e.y } end
			end
			self.group = nil
		end
	elseif ty == "transform" or ty == "concert_riff" or ty == "continue_riff" then
		local v = rec(self, e.id)
		v.pop, v.flash = t, t
	elseif ty == "activate" then
		if e.id then rec(self, e.id).armed_t = e.t end
		if e.partner then rec(self, e.partner).armed_t = e.t end
	elseif ty == "hit" then
		if e.layer == "blocker" then
			-- the blocker of that cell wobbles (looked up by cell in frame())
			self.hits = self.hits or {}
			self.hits[cell_key(e.x, e.y)] = t
		end
	elseif ty == "noise_spread" then
		local v = rec(self, e.id)
		v.pop, v.flash = t, t
		v.flash_dark = true
	elseif ty == "freed" then
		rec(self, e.id).pop = t
	elseif ty == "shuffle" then
		for _, m in ipairs(e.moves or {}) do
			if m.fx ~= m.x or m.fy ~= m.y then
				rec(self, m.id).fly = { fx = m.fx, fy = m.fy, t0 = e.t or 0, dur = math.max(e.duration or 30, 1) }
			end
		end
		for _, r in ipairs(e.recolors or {}) do
			local v = rec(self, r.id)
			v.flash, v.spin = t, t
		end
		if e.riff and e.riff.id then
			local v = rec(self, e.riff.id)
			v.appear, v.flash = t, t
		end
	end
end

-- Draw list for this frame. pieces = game:pieces(); tick_f = display tick;
-- t = real seconds.
function Anim:frame(pieces, tick_f, t)
	local g = self.geom
	local out = self.out
	for k = #out, 1, -1 do out[k] = nil end
	self.frame_n = self.frame_n + 1
	local fn = self.frame_n
	if not g then return out end
	local cell = g.cell
	local base = cell / M.ART
	local reduced = self.reduced
	local hints = nil
	if self.hint_a and self.hint_b and self.hint_phase then
		hints = { [cell_key(self.hint_a[1], self.hint_a[2])] = self.hint_b,
			[cell_key(self.hint_b[1], self.hint_b[2])] = self.hint_a }
	end
	for i = 1, #pieces do
		local p = pieces[i]
		local v = rec(self, p.id)
		v.seen = fn
		local e = v.out
		if not e then
			e = { id = p.id }
			v.out = e
		end
		local kind, state = p.kind, p.state
		if p.item == "column" and not self.max_hp[p.id] then self.max_hp[p.id] = p.hp or 1 end
		e.image = M.image(p, self.max_hp[p.id])
		local x, y = g:pos(p.x, p.y, p.offx, p.offy)
		if p.item == "column" then x, y = x + cell / 2, y - cell / 2 end
		local sx, sy, rot, flash, alpha = 1, 1, 0, 0, 1
		local z = M.Z.piece
		if kind == "special" then z = M.Z.special elseif kind == "blocker" then z = M.Z.blocker end
		if kind == "special" and p.special == "riff" and p.axis == "v" then rot = 90 end
		e.clip = nil

		if p.hidden then
			alpha = 0
		elseif state == "swap" and v.fly and tick_f < v.fly.t0 + v.fly.dur + 1 then
			-- shuffle: fly from the old cell to the new one on an arc
			local f = v.fly
			local u = clamp01((tick_f - f.t0) / f.dur)
			local k = ease_in_out(u)
			local x0, y0 = g:center(f.fx, f.fy)
			local x1, y1 = g:center(p.x, p.y)
			local dx, dy = x1 - x0, y1 - y0
			local bulge = reduced and 0 or math.sin(u * math.pi) * cell * 0.35
			local len = math.sqrt(dx * dx + dy * dy)
			if len > 0 then
				x = x0 + dx * k - dy / len * bulge
				y = y0 + dy * k + dx / len * bulge
			end
			local s = 1 + (reduced and 0 or 0.12 * math.sin(u * math.pi))
			sx, sy = s, s
			z = M.Z.fly
		elseif state == "swap" and v.swap and tick_f <= v.swap.t0 + v.swap.dur + 1 then
			local w = v.swap
			local u = clamp01((tick_f - w.t0) / w.dur)
			local x0, y0 = g:center(w.ax, w.ay)
			local x1, y1 = g:center(w.bx, w.by)
			-- the core may have exchanged the cells already: start where the piece was
			if p.x == w.bx and p.y == w.by and w.kind ~= "fail" then
				x0, y0, x1, y1 = x1, y1, x0, y0
				u = 1 - u
			end
			local k
			if w.kind == "fail" then k = M.fail_offset(u) else k = ease_in_out(u) end
			x, y = x0 + (x1 - x0) * k, y0 + (y1 - y0) * k
			if not reduced and w.kind ~= "fail" then
				local s = math.sin(u * math.pi) * 0.07
				if w.top then sx, sy = 1 + s, 1 + s else sx, sy = 1 - s, 1 - s end
			end
			z = w.top and M.Z.swap_top or M.Z.swap_under
		elseif state == "clear" then
			local c = v.clear
			if not c then
				c = { t0 = tick_f, cause = "effect" }
				v.clear = c
			end
			local u = tick_f - c.t0
			if c.gather then
				local k = clamp01(u / M.CLEAR_TICKS)
				local tx, ty = g:center(c.gather[1], c.gather[2])
				local e2 = k * k
				x, y = x + (tx - x) * e2, y + (ty - y) * e2
				local s = 1 - 0.55 * k
				sx, sy = s, s
				alpha = 1 - 0.4 * k
				z = M.Z.gather
			elseif c.cause == "fired" then
				local k = clamp01(u / M.CLEAR_TICKS)
				local s = 1.1 + 0.4 * k
				sx, sy = s, s
				alpha = 1 - k
				flash = 1 - k
			elseif kind == "mic" then
				local k = clamp01(u / M.CLEAR_TICKS)
				y = y - cell * 0.6 * k
				local s = 1 - 0.5 * k
				sx, sy = s, s
				alpha = 1 - k
			else
				local s = M.clear_scale(u)
				sx, sy = s, s
				flash = u < M.POP_TICKS and 0.35 or 0
			end
		elseif state == "armed" then
			local t0 = v.armed_t or tick_f
			v.armed_t = t0
			local u = tick_f - t0
			if p.special == "sub" then
				local s = 1 + (M.SWELL_SCALE - 1) * clamp01(u / M.SWELL_TICKS)
				sx, sy = s, s
			else
				local s = 1.1 + (reduced and 0 or 0.05 * math.sin(u * 0.9))
				sx, sy = s, s
			end
			if p.special == "disco" and not reduced then rot = u * 12 end
			flash = 0.3 + 0.25 * math.sin(u * 0.8)
			z = M.Z.swap_top
		else
			-- idle / fall
			if v.touch then
				local dt = t - v.touch
				local s
				if dt < M.TOUCH_UP then
					s = 1 + (M.TOUCH_SCALE - 1) * (dt / M.TOUCH_UP)
				else
					s = 1 + (M.TOUCH_SCALE - 1) * (1 - clamp01((dt - M.TOUCH_UP) / M.TOUCH_DOWN))
				end
				if dt > M.TOUCH_UP + M.TOUCH_DOWN then v.touch = nil end
				sx, sy = sx * s, sy * s
			end
			if self.selected == p.id then
				local s = M.SELECT_SCALE + (reduced and 0 or 0.02 * math.sin(t * 6))
				if s > sx then sx, sy = s, s end
				z = M.Z.selected
			end
			if v.land and not reduced then
				local dt = t - v.land
				local k = M.spring(dt)
				if dt >= M.SQUASH_TIME then v.land = nil end
				if k ~= 0 then
					local ky = 1 - (1 - M.SQUASH_Y) * k
					local kx = 1 + (M.SQUASH_X - 1) * k
					sx, sy = sx * kx, sy * ky
					y = y - (1 - ky) * cell * 0.42 -- the bottom stays on the floor
				end
			end
			if v.appear then
				local dt = t - v.appear
				local s = M.appear_scale(dt)
				if dt >= M.APPEAR_TIME then v.appear = nil end
				sx, sy = sx * s, sy * s
			end
			if v.pop then
				local dt = t - v.pop
				if dt >= 0.3 then
					v.pop = nil
				else
					local s = 1 + 0.25 * math.sin(clamp01(dt / 0.3) * math.pi)
					sx, sy = sx * s, sy * s
				end
			end
			if v.spin and not reduced then
				local dt = t - v.spin
				if dt >= 0.35 then v.spin = nil else rot = rot + 360 * ease_out(dt / 0.35) end
			end
			if kind == "blocker" and self.hits then
				local ht = self.hits[cell_key(p.x, p.y)]
				if ht then
					local dt = t - ht
					if dt >= M.HIT_TIME then
						self.hits[cell_key(p.x, p.y)] = nil
					else
						local k = 1 - dt / M.HIT_TIME
						if not reduced then rot = rot + 7 * k * math.sin(dt * 55) end
						local s = 1 + 0.06 * k
						sx, sy = sx * s, sy * s
						flash = math.max(flash, 0.45 * k)
					end
				end
			end
			if hints and state == "idle" then
				local other = hints[cell_key(p.x, p.y)]
				if other then
					local ox, oy = g:center(other[1], other[2])
					local cx, cy = g:center(p.x, p.y)
					local w = level_hint.wobble_offset(self.hint_phase, reduced and 0.06 or 0.14)
					x, y = x + (ox - cx) * w, y + (oy - cy) * w
					flash = math.max(flash, 0.25 * math.sin(self.hint_phase * math.pi))
				end
			end
			if state == "fall" then
				-- entering at a spawner: cut the sprite at the top of its column run
				local top = g:clip_top(p.x, p.y)
				if top and y + cell * 0.6 > top then e.clip = top end
			end
		end
		if v.flash then
			local dt = t - v.flash
			if dt >= M.FLASH_TIME then
				v.flash, v.flash_dark = nil, nil
			elseif not v.flash_dark then
				flash = math.max(flash, 1 - dt / M.FLASH_TIME)
			end
		end
		e.x, e.y, e.z = x, y, z
		e.sx, e.sy, e.rot = sx, sy, rot
		e.scale = base
		e.flash, e.alpha = flash, alpha
		out[#out + 1] = e
	end
	-- forget pieces that left the board (kept one frame for late events)
	for id, v in pairs(self.vis) do -- order-independent
		if v.seen < fn - 1 and v.born < fn - 1 then
			self.vis[id] = nil
			self.max_hp[id] = nil
		end
	end
	return out
end

-- Visual record of a piece (tests, debug).
function Anim:record(id)
	return self.vis[id]
end

M.cell_key = cell_key

return M
