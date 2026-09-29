-- When to show the hint (pure Lua): after 5 s without touches the board
-- asks game:hint() and wobbles the two pieces towards each other for 0.6 s,
-- again every 3 s, until the next touch (client-architecture.md, 4.1).
-- Idle time only counts while a hint makes sense (the game is playing, the
-- board is at rest, no selection or booster target is pending).
--
--   local level_hint = require("client.level_hint")
--   local h = level_hint.new()
--   h:touch()                          -- any touch: start over
--   if h:update(dt, allowed) then      -- true when a wobble starts now
--       local cmd = session:hint_command() ...
--   end
--   h:phase()                          -- 0..1 of the running wobble, or nil

local M = {}

M.IDLE = 5.0    -- seconds without touches before the first hint
M.EVERY = 3.0   -- seconds between wobbles
M.WOBBLE = 0.6  -- seconds a wobble lasts

local Hint = {}
Hint.__index = Hint

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		idle = opts.idle or M.IDLE,
		every = opts.every or M.EVERY,
		wobble = opts.wobble or M.WOBBLE,
		t = 0,          -- idle time counted so far
		next_at = nil,  -- idle time of the next wobble
		shown = 0,      -- wobbles since the last touch
		running = nil,  -- seconds into the running wobble
	}, Hint)
end

function Hint:touch()
	self.t = 0
	self.next_at = nil
	self.shown = 0
	self.running = nil
end

-- Advances by dt. allowed = a hint makes sense now. Returns true when a new
-- wobble starts (the caller picks the move with game:hint()).
function Hint:update(dt, allowed)
	dt = tonumber(dt) or 0
	if self.running then
		self.running = self.running + dt
		if self.running >= self.wobble then self.running = nil end
	end
	if not allowed then
		-- the board moved or the game is not playing: the wobble stops, the
		-- idle time keeps what it had (a cascade is not a touch)
		self.running = nil
		return false
	end
	self.t = self.t + dt
	local due = self.next_at or self.idle
	if self.t >= due then
		self.shown = self.shown + 1
		self.next_at = self.t + self.every
		self.running = 0
		return true
	end
	return false
end

-- Progress of the running wobble in 0..1, or nil.
function Hint:phase()
	if not self.running then return nil end
	return math.min(1, self.running / self.wobble)
end

-- Offset of a wobbling piece towards its partner, in cells: a smooth
-- there-and-back (0 at both ends) of amplitude `amp` at phase p.
function M.wobble_offset(p, amp)
	if not p then return 0 end
	amp = amp or 0.14
	local s = math.sin(p * math.pi)
	-- two small pulls inside one wobble reads as "these two want to swap"
	return amp * s * math.abs(math.sin(p * math.pi * 2))
end

return M
