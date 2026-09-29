-- Juice for GUI scenes: flights along arcs, bursts of sparkles, rings,
-- flashes, floating texts, confetti, pops, shakes, counters and timers.
-- GUI script context only (client/ui.lua scene).
--
--   local fx = require("client.fx")
--   self.fx = fx.new(self.ui, parent)      -- a layer on top of `parent`
--   self.fx:fly({image = "ui/icons/star", from = {x, y}, to = {x2, y2}, on_land = fn})
--   self.fx:burst(x, y, {count = 12})
--   self.fx:after(0.4, fn)
--   function update(self, dt) self.fx:update(dt) end
--   self.fx:clear()                        -- skip: every effect gone at once
--
-- Everything the module creates lives in its own layer, so clear() is safe
-- whatever the screen rebuilds meanwhile. Positions are logical (720x1280,
-- y up) relative to the layer's parent.
--
-- Reduced motion (settings): flights become short straight moves, bursts a
-- single soft glow, no confetti, no shakes, no idle bobbing.

local ui = require("client.ui")
local app = require("client.app")
local audio = require("client.audio")
local platform = require("client.platform")

local M = {}

local Fx = {}
Fx.__index = Fx

local random = math.random
local sin, cos, pi = math.sin, math.cos, math.pi

M.CONFETTI_COLORS = { "#FF4D8D", "#FFDB1A", "#3AA4FF", "#2BE38F", "#9B52FF", "#FF9A1F" }
M.SPARK_COLORS = { "#FFFFFF", "#FFF3A6", "#FFD84D", "#FFB020" }

local base_scale = setmetatable({}, { __mode = "k" })
local base_pos = setmetatable({}, { __mode = "k" })

function M.reduced()
	return app.reduced_motion()
end

function M.rand(a, b)
	return a + (b - a) * random()
end

-- A haptic tick (off in the settings = nothing).
function M.buzz(ms)
	pcall(platform.vibrate, ms or 15)
end

function M.new(scene, parent)
	local self = setmetatable({ ui = scene, parent = parent or scene.root, tweens = {}, sfx_at = {}, clock = 0 }, Fx)
	self.layer = scene:layer(self.parent, "fx")
	return self
end

-- Deletes every effect node and forgets every tween and timer.
function Fx:clear()
	self.ui:clear(self.layer)
	self.layer = self.ui:layer(self.parent, "fx")
	self.tweens = {}
end

function Fx:busy()
	return #self.tweens > 0
end

function Fx:update(dt)
	self.clock = self.clock + dt
	local list = self.tweens
	if #list == 0 then return end
	local keep, finished = {}, nil
	for i = 1, #list do
		local tw = list[i]
		if not tw.dead then
			if tw.delay > 0 then
				tw.delay = tw.delay - dt
				if tw.delay <= 0 and tw.start then tw.start(tw) end
			else
				tw.t = tw.t + dt
				local k = tw.t / tw.dur
				if k > 1 then k = 1 end
				if tw.step then tw.step(tw, k, dt) end
				if k >= 1 then
					tw.dead = true
					finished = finished or {}
					finished[#finished + 1] = tw
				end
			end
			if not tw.dead then keep[#keep + 1] = tw end
		end
	end
	self.tweens = keep
	if finished then
		for i = 1, #finished do
			local tw = finished[i]
			if tw.finish then tw.finish(tw) end
		end
	end
end

-- A generic tween: step(tw, k 0..1, dt) every frame for `dur` seconds after
-- `delay`, then finish(tw). Returns the tween (tw.dead = true cancels it).
function Fx:tween(dur, step, finish, delay, start)
	local tw = { t = 0, dur = math.max(dur or 0, 1e-6), delay = delay or 0, step = step, finish = finish, start = start }
	if tw.delay <= 0 and start then start(tw) end
	self.tweens[#self.tweens + 1] = tw
	return tw
end

function Fx:after(delay, fn)
	return self:tween(0, nil, fn, delay)
end

-- Counts a number from `from` to `to` in `dur` seconds: fn(value) with
-- whole numbers.
function Fx:count(from, to, dur, fn, delay)
	local last
	return self:tween(dur, function(_, k)
		local v = math.floor(from + (to - from) * k + 0.5)
		if v ~= last then
			last = v
			fn(v)
		end
	end, function() if last ~= to then fn(to) end end, delay)
end

-- A sound effect, at most once per `gap` seconds per name (a shower of
-- coins does not clip).
function Fx:sfx(name, opts, gap)
	local at = self.sfx_at[name]
	if at and self.clock - at < (gap or 0.05) then return end
	self.sfx_at[name] = self.clock
	audio.sfx(name, opts)
end

local function ease_in_out(k)
	return k < 0.5 and 2 * k * k or 1 - (-2 * k + 2) ^ 2 / 2
end

local function ease_out_back(k)
	local c1, c3 = 1.70158, 2.70158
	return 1 + c3 * (k - 1) ^ 3 + c1 * (k - 1) ^ 2
end
M.ease_in_out, M.ease_out_back = ease_in_out, ease_out_back

-- An image (or a soft disc) in the fx layer.
function Fx:sprite(image, x, y, size, color, parent)
	local s = self.ui
	parent = parent or self.layer
	local n
	if image then n = s:image(parent, image, x, y, { w = size, h = size, color = color }) end
	if not n then n = s:circle(parent, x, y, size, color or "white", { soft = true }) end
	return n
end

local function resolve(p)
	if type(p) == "function" then return p() end
	return p[1] or p.x, p[2] or p.y
end

-- Flies an icon along an arc. o = {image, size = 56, color, from = {x, y},
-- to = {x, y} or fn() -> x, y (read at take-off and on landing, so a moving
-- target is still hit), dur = 0.55, delay, arc = 140 (bulge of the curve,
-- px; negative bends the other way), spin = degrees, scale_to = 0.7,
-- trail = colour | nil, on_land = fn(), on_start = fn()}.
function Fx:fly(o)
	local reduced = M.reduced()
	local x0, y0 = resolve(o.from)
	local size = o.size or 56
	local node = self:sprite(o.image, x0, y0, size, o.color)
	gui.set_scale(node, vmath.vector3(0.001, 0.001, 1))
	local dur = reduced and 0.22 or (o.dur or 0.55)
	local arc = reduced and 0 or (o.arc or 140)
	local spin = reduced and 0 or (o.spin or 0)
	local scale_to = o.scale_to or 0.7
	local x2, y2, cx, cy
	local trail_t = 0
	local function aim()
		x2, y2 = resolve(o.to)
		local dx, dy = x2 - x0, y2 - y0
		local len = math.sqrt(dx * dx + dy * dy)
		if len < 1 then len = 1 end
		-- control point: the middle pushed sideways (left normal) by `arc`
		cx, cy = (x0 + x2) / 2 - dy / len * arc, (y0 + y2) / 2 + dx / len * arc
	end
	aim()
	local pos = vmath.vector3(x0, y0, 0)
	local sc = vmath.vector3(1, 1, 1)
	local rot = vmath.vector3(0, 0, 0)
	return self:tween(dur, function(tw, k, dt)
		local e = ease_in_out(k)
		local u = 1 - e
		pos.x = u * u * x0 + 2 * u * e * cx + e * e * x2
		pos.y = u * u * y0 + 2 * u * e * cy + e * e * y2
		gui.set_position(node, pos)
		local s
		if k < 0.25 then s = 0.4 + (1.2 - 0.4) * (k / 0.25) else s = 1.2 + (scale_to - 1.2) * ((k - 0.25) / 0.75) end
		sc.x, sc.y = s, s
		gui.set_scale(node, sc)
		if spin ~= 0 then
			rot.z = spin * k
			gui.set_euler(node, rot)
		end
		if o.trail and not reduced then
			trail_t = trail_t + dt
			if trail_t >= 0.035 then
				trail_t = 0
				local t = self.ui:circle(self.layer, pos.x, pos.y, size * 0.55, o.trail, { soft = true, alpha = 0.75 })
				gui.move_below(t, node)
				gui.animate(t, "scale", vmath.vector3(0.2, 0.2, 1), gui.EASING_INQUAD, 0.32)
				gui.animate(t, "color.w", 0, gui.EASING_INQUAD, 0.32, 0, function() gui.delete_node(t) end)
			end
		end
	end, function()
		aim()
		gui.delete_node(node)
		if o.on_land then o.on_land(x2, y2) end
	end, o.delay, function()
		gui.set_scale(node, vmath.vector3(0.4, 0.4, 1))
		if o.on_start then o.on_start() end
	end)
end

-- Sparkles shooting out of (x, y). o = {count = 12, radius = 130, dur = 0.6,
-- size = 34, image = "fx/star_particle", colors = M.SPARK_COLORS, parent}.
function Fx:burst(x, y, o)
	o = o or {}
	local parent = o.parent or self.layer
	if M.reduced() then
		local g = self.ui:circle(parent, x, y, (o.radius or 130) * 1.2, "#FFF3A6", { soft = true, alpha = 0.8 })
		gui.animate(g, "color.w", 0, gui.EASING_OUTQUAD, 0.5, 0, function() gui.delete_node(g) end)
		return
	end
	local count = o.count or 12
	local colors = o.colors or M.SPARK_COLORS
	local dur = o.dur or 0.6
	for i = 1, count do
		local a = (i / count) * 2 * pi + M.rand(-0.25, 0.25)
		local r = (o.radius or 130) * M.rand(0.55, 1.1)
		local size = (o.size or 34) * M.rand(0.7, 1.2)
		local n = self:sprite(o.image or "fx/star_particle", x, y, size, colors[(i - 1) % #colors + 1], parent)
		gui.set_blend_mode(n, gui.BLEND_ADD)
		local d = dur * M.rand(0.8, 1.2)
		gui.animate(n, "position", vmath.vector3(x + cos(a) * r, y + sin(a) * r, 0), gui.EASING_OUTQUAD, d)
		gui.animate(n, "euler.z", M.rand(-240, 240), gui.EASING_OUTQUAD, d)
		gui.animate(n, "scale", vmath.vector3(0.2, 0.2, 1), gui.EASING_INQUAD, d)
		gui.animate(n, "color.w", 0, gui.EASING_INQUAD, d, 0, function() gui.delete_node(n) end)
	end
end

-- An expanding ring. o = {size = 120, scale = 3, dur = 0.5, color, parent}
function Fx:ring(x, y, o)
	o = o or {}
	local n = self:sprite("fx/ring", x, y, o.size or 120, o.color or "#FFF3A6", o.parent)
	gui.set_blend_mode(n, gui.BLEND_ADD)
	local k = M.reduced() and 1.4 or (o.scale or 3)
	gui.set_scale(n, vmath.vector3(0.3, 0.3, 1))
	gui.animate(n, "scale", vmath.vector3(k, k, 1), gui.EASING_OUTQUAD, o.dur or 0.5)
	gui.animate(n, "color.w", 0, gui.EASING_INQUAD, o.dur or 0.5, 0, function() gui.delete_node(n) end)
	return n
end

-- A soft flash of light. o = {size = 300, color = "#FFFFFF", dur = 0.4, parent}
function Fx:flash(x, y, o)
	o = o or {}
	local n = self.ui:circle(o.parent or self.layer, x, y, o.size or 300, o.color or "#FFFFFF", { soft = true, alpha = 0.95 })
	gui.set_blend_mode(n, gui.BLEND_ADD)
	gui.set_scale(n, vmath.vector3(0.5, 0.5, 1))
	gui.animate(n, "scale", vmath.vector3(1.4, 1.4, 1), gui.EASING_OUTQUAD, o.dur or 0.4)
	gui.animate(n, "color.w", 0, gui.EASING_INQUAD, o.dur or 0.4, 0, function() gui.delete_node(n) end)
	return n
end

-- A text that pops up at (x, y), rises and fades. o = {size = 44, color =
-- "white", outline = "#FF4D8D", rise = 90, dur = 1.1, font = "button", parent}
function Fx:float_text(text, x, y, o)
	o = o or {}
	local n = self.ui:text(o.parent or self.layer, text, x, y, {
		font = o.font or "button", size = o.size or 44, color = o.color or "white",
		outline = o.outline or "#FF4D8D", shadow = o.shadow or o.outline or "#FF4D8D", max_width = o.max_width or 600,
	})
	local dur = o.dur or 1.1
	local s = gui.get_scale(n)
	gui.set_scale(n, s * 0.4)
	gui.animate(n, "scale", s, gui.EASING_OUTBACK, 0.3)
	if not M.reduced() then
		gui.animate(n, "position.y", y + (o.rise or 90), gui.EASING_OUTQUAD, dur)
	end
	gui.animate(n, "color.w", 0, gui.EASING_INQUAD, dur * 0.45, dur * 0.55, function() gui.delete_node(n) end)
	return n
end

-- Confetti falling over the area. o = {rate = 40 per second, duration (s,
-- nil = until stop()), x0 = -20, x1 = 740, top = 1320, bottom = -60, parent,
-- colors}. Returns a handle with :stop(). Nothing under reduced motion.
function Fx:confetti(o)
	o = o or {}
	local handle = { stopped = false }
	function handle.stop() handle.stopped = true end
	if M.reduced() then return handle end
	local parent = o.parent or self.layer
	local colors = o.colors or M.CONFETTI_COLORS
	local rate = o.rate or 40
	local acc = 0
	local x0, x1 = o.x0 or -20, o.x1 or 740
	local top, bottom = o.top or 1320, o.bottom or -60
	local s = self.ui
	local function piece()
		local x = M.rand(x0, x1)
		local c = colors[random(#colors)]
		local w, h = M.rand(12, 18), M.rand(20, 30)
		local n = s:image(parent, "fx/confetti", x, top + M.rand(0, 80), { w = w, h = h, color = c })
			or s:round(parent, x, top + M.rand(0, 80), w, h, c, { radius = 4 })
		local d = M.rand(2.2, 3.6)
		gui.set_euler(n, vmath.vector3(0, 0, M.rand(0, 360)))
		gui.animate(n, "position", vmath.vector3(x + M.rand(-120, 120), bottom, 0), gui.EASING_INSINE, d, 0,
			function() gui.delete_node(n) end)
		gui.animate(n, "euler.z", M.rand(-900, 900), gui.EASING_LINEAR, d)
		gui.animate(n, "scale.x", 0.15, gui.EASING_INOUTSINE, M.rand(0.2, 0.45), 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
	end
	self:tween(o.duration or 1e9, function(tw, k, dt)
		if handle.stopped then
			tw.dead = true
			return
		end
		acc = acc + rate * dt
		while acc >= 1 do
			acc = acc - 1
			piece()
		end
	end)
	-- a first handful at once, spread over the height
	for _ = 1, math.floor((o.burst or 0)) do piece() end
	return handle
end

-- A quick scale punch. Pulsing nodes (ui.pulse) keep their pulse instead.
function Fx:pop(node, amount, dur)
	if not node or ui.is_pulsing(node) then return end
	local b = base_scale[node]
	if not b then
		b = gui.get_scale(node)
		base_scale[node] = b
	end
	local k = 1 + (amount or 0.25)
	gui.cancel_animations(node, "scale")
	gui.set_scale(node, vmath.vector3(b.x * k, b.y * k, b.z))
	gui.animate(node, "scale", b, gui.EASING_OUTBACK, dur or 0.3)
end

local SHAKE = vmath.vector({ 0, 1, -1, 0.75, -0.55, 0.35, -0.15, 0 })

-- A sideways shake (a refusal). Nothing under reduced motion.
function Fx:shake(node, amp, dur)
	if not node or M.reduced() then return end
	local p = base_pos[node]
	if not p then
		p = gui.get_position(node)
		base_pos[node] = p
	end
	gui.cancel_animations(node, "position.x")
	gui.set_position(node, p)
	gui.animate(node, "position.x", p.x + (amp or 14), SHAKE, dur or 0.4, 0, function() gui.set_position(node, p) end)
end

-- Slow rays turning behind a reward (a chest, a new booster). Returns the node.
function Fx:rays(parent, x, y, o)
	o = o or {}
	local holder = self.ui:layer(parent)
	gui.set_position(holder, vmath.vector3(x, y, 0))
	local count = o.count or 10
	local len = o.length or 520
	for i = 1, count do
		local r = self.ui:circle(holder, 0, 0, 10, o.color or "#FFE66D", { soft = true, alpha = o.alpha or 0.45 })
		gui.set_size(r, vmath.vector3(o.width or 70, len, 0))
		gui.set_blend_mode(r, gui.BLEND_ADD)
		gui.set_euler(r, vmath.vector3(0, 0, (i - 1) * 180 / count))
	end
	if not M.reduced() then
		gui.animate(holder, "euler.z", 360, gui.EASING_LINEAR, o.period or 14, 0, nil, gui.PLAYBACK_LOOP_FORWARD)
	end
	return holder
end

-- Gentle idle bob (restored items, Bit). Nothing under reduced motion.
function M.bob(node, amp, period, delay)
	if M.reduced() then return end
	local p = gui.get_position(node)
	gui.animate(node, "position.y", p.y + (amp or 5), gui.EASING_INOUTSINE, (period or 2.4) / 2, delay or 0, nil,
		gui.PLAYBACK_LOOP_PINGPONG)
end

return M
