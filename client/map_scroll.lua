-- Scrolling of the game map (pure Lua): drag with a finger or the mouse, the mouse wheel, inertia, a
-- smooth glide to a spot (the map opens on the current level), a clamp at both ends of the map.
-- It decides nothing about drawing: the screen asks s:pos() each frame and moves the world by it.
--
--   local scroll = require("client.map_scroll").new({min = 0, max = 15000, pos = 0})
--   scroll:set_range(0, max)             -- the window changed
--   scroll:press(y, t)                   -- y: logical screen y of the pointer, t: seconds (the clock of the script)
--   scroll:move(y, t)                    -- the finger moved; returns true while it counts as a drag
--   local tap = scroll:release(t)        -- true when the press never became a drag (a tap on the map)
--   scroll:wheel(dir)                    -- dir > 0: wheel up (shows what is higher on the map), < 0: wheel down
--   scroll:glide(pos, seconds)           -- smooth move to a position (cancelled by a press)
--   scroll:update(dt)                    -- returns true when the position changed
--   scroll:pos(), scroll:moving()
--
-- Position = the world y at the bottom edge of the window (client/map_model.lua): dragging the finger up
-- moves the content up, so the position falls.

local M = {}

M.TAP_SLOP = 22        -- logical px of finger travel that still counts as a tap
M.FRICTION = 3.2       -- inertia: velocity falls by e^-FRICTION per second
M.STOP_SPEED = 14      -- px per second below which the inertia stops
M.MAX_SPEED = 6000     -- px per second
M.WHEEL_SPEED = 1500   -- px per second added by one notch of the wheel
M.FLICK_WINDOW = 0.12  -- seconds of finger history that make the release speed

local S = {}
S.__index = S

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		min = opts.min or 0, max = opts.max or 0, p = opts.pos or 0, v = 0,
		down = false, drag = false, y0 = 0, last_y = 0, last_t = 0, glide_t = nil,
	}, S)
end

local function clamp(self, p)
	if p < self.min then return self.min, true end
	if p > self.max then return self.max, true end
	return p, false
end

function S:pos()
	return self.p
end

function S:set_range(min, max)
	self.min, self.max = min, math.max(min, max)
	self.p = clamp(self, self.p)
end

-- Jumps to a position at once (no animation).
function S:set(pos)
	self.p = clamp(self, pos)
	self.v, self.glide_t = 0, nil
end

function S:moving()
	return self.drag or self.glide_t ~= nil or math.abs(self.v) > M.STOP_SPEED
end

function S:dragging()
	return self.drag
end

function S:press(y, t)
	self.down, self.drag = true, false
	self.y0, self.last_y, self.last_t = y, y, t
	self.v, self.glide_t = 0, nil
	self.vs = 0 -- velocity estimate of the finger (smoothed over the last FLICK_WINDOW)
end

-- A finger that moved: returns true while the press counts as a drag.
function S:move(y, t)
	if not self.down then return false end
	if not self.drag then
		if math.abs(y - self.y0) < M.TAP_SLOP then return false end
		self.drag = true
		self.last_y = y -- the slop itself is not scrolled: the content starts from the finger
	end
	local dy = y - self.last_y
	local dt = t - self.last_t
	local p, hit = clamp(self, self.p - dy)
	self.p = p
	if dt > 0 then
		-- exponential average with a time constant of the flick window
		local k = math.min(1, dt / M.FLICK_WINDOW)
		self.vs = self.vs + ((-dy / dt) - self.vs) * k
	end
	if hit then self.vs = 0 end
	self.last_y, self.last_t = y, t
	return true
end

-- The finger lifted. Returns true when it was a tap (never a drag). A drag leaves its speed as inertia,
-- unless the finger rested before it lifted.
function S:release(t)
	local was_down, was_drag = self.down, self.drag
	self.down, self.drag = false, false
	if not was_down then return false end
	if not was_drag then return true end
	local idle = t - self.last_t
	local v = idle > M.FLICK_WINDOW and 0 or self.vs
	if v > M.MAX_SPEED then v = M.MAX_SPEED elseif v < -M.MAX_SPEED then v = -M.MAX_SPEED end
	self.v = v
	return false
end

function S:wheel(dir)
	self.glide_t = nil
	local v = self.v + dir * M.WHEEL_SPEED
	if v > M.MAX_SPEED then v = M.MAX_SPEED elseif v < -M.MAX_SPEED then v = -M.MAX_SPEED end
	self.v = v
end

-- Glides to `pos` in `seconds` (ease in and out). seconds <= 0 jumps.
function S:glide(pos, seconds)
	pos = clamp(self, pos)
	if not seconds or seconds <= 0 then
		self:set(pos)
		return
	end
	self.v = 0
	self.glide_t = { from = self.p, to = pos, t = 0, dur = seconds }
end

function S:gliding()
	return self.glide_t ~= nil
end

-- Returns true when the position changed.
function S:update(dt)
	local before = self.p
	local g = self.glide_t
	if g then
		g.t = g.t + dt
		local k = g.t / g.dur
		if k >= 1 then
			self.p, self.glide_t = g.to, nil
		else
			self.p = g.from + (g.to - g.from) * (k * k * (3 - 2 * k))
		end
	elseif not self.down and self.v ~= 0 then
		local p, hit = clamp(self, self.p + self.v * dt)
		self.p = p
		self.v = self.v * math.exp(-M.FRICTION * dt)
		if hit or math.abs(self.v) < M.STOP_SPEED then self.v = 0 end
	end
	return self.p ~= before
end

return M
