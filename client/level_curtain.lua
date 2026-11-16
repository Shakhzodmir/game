-- The timed curtain of the level board (core-rules 10.7), as marks of client/level_view.lua.
--
-- The core closes and opens the curtain cells of a level by the count of the moves spent: closed, a cell is
-- hidden and frozen; open, it is an ordinary cell. This module only shows it:
--
--   closed .... blockers_curtain_closed over the cell, above the piece (which it hides)
--   open ...... blockers_curtain_open: the same curtain tied to the sides, the piece shows through the middle
--   change .... the core's `curtain` event: the two pictures cross over in MOVE_TIME with a small sway
--               (eases of client/level_anim.lua); with reduced motion they just change places
--   counter ... the moves left until the next change, as a row of pips on the rail of the top-left cell of
--               every drape (cells joined by a side): gold while it waits to open, pink while it waits to
--               close. A pip goes with each move (`curtain_left`), so the player can plan
--   refusal ... a finger on a closed cell: its curtain shakes (C:nope)
--
--   local level_curtain = require("client.level_curtain")
--   local C = level_curtain.new({cells = game:cells(), W = W, status = game:status().curtain, reduced = bool})
--   C:active()                         -- does the level have curtains at all
--   C:event(e, t)                      -- every core event (t = real seconds)
--   n = C:fill(list, n, geom, t, sx, sy) -- appends this frame's marks to list[n + 1 ..]; returns the new n
--   C:closed_at(x, y)                  -- is that cell under a closed curtain now
--   C:nope(x, y, t)
--   C:sync(game:status().curtain)      -- the janitor: 1 if what is shown was not the core's phase, else 0
--   C:set_reduced(bool)
--
-- Nothing is allocated per frame: the mark tables are made once per cell and pip.

local level_anim = require("client.level_anim")

local M = {}

M.CLOSED = "blockers_curtain_closed"  -- animation ids of the game atlas, 160 art px per cell
M.OPEN = "blockers_curtain_open"
M.ART = 160
M.Z = 0.21             -- over the pieces (up to 0.14) and the wires (0.2)
M.Z_PIP = 0.22
M.MOVE_TIME = 0.28     -- seconds a curtain takes to close or open
M.SWAY = 0.06          -- how much wider the moving curtain gets on its way (share of its width)
M.NOPE_TIME = 0.3      -- a refused touch: the curtain shakes this long ...
M.NOPE_AMP = 0.06      -- ... by this share of a cell ...
M.NOPE_FREQ = 55       -- ... three swings (radians per second)
M.MAX_PIPS = 9         -- (closed_moves and open_moves are 1..9)
M.PIP_SIZE = 0.2       -- of a cell
M.PIP_STEP = 0.105     -- of a cell, centre to centre
M.PIP_Y = 0.4          -- of a cell above the centre: on the rail
M.PIP_COLOR = { closed = "#FFD84D", open = "#FF7EB6" }

local Curtain = {}
Curtain.__index = Curtain

local function new_mark(image, z, glow)
	return { image = image, iw = glow and 64 or M.ART, ih = glow and 64 or M.ART, glow = glow, color = "#FFFFFF", z = z,
		rot = 0, x = 0, y = 0, w = 1, h = 1, alpha = 1 }
end

-- opts.cells = game:cells() (the `curtain` flag), opts.W, opts.status = game:status().curtain or nil.
function M.new(opts)
	opts = opts or {}
	local W = opts.W or 1
	local self = setmetatable({
		W = W, cells = {}, heads = {}, at = {},
		phase = "open", left = 0, changed_at = nil, reduced = opts.reduced and true or false,
		nope_cell = nil, nope_at = nil, n = 0,
	}, Curtain)
	local cells = opts.cells or {}
	for i = 1, #cells do
		if cells[i].curtain then
			local x = (i - 1) % W + 1
			local c = { i = i, x = x, y = (i - x) / W + 1, closed = new_mark(M.CLOSED, M.Z, false),
				open = new_mark(M.OPEN, M.Z, false) }
			self.cells[#self.cells + 1] = c
			self.at[i] = c
		end
	end
	-- the first cell (top-left: the lowest index) of every drape carries the counter
	local seen = {}
	for k = 1, #self.cells do
		local c = self.cells[k]
		if not seen[c.i] then
			local pips = {}
			for j = 1, M.MAX_PIPS do pips[j] = new_mark("fx_glow_dot", M.Z_PIP, true) end
			self.heads[#self.heads + 1] = { cell = c, pips = pips }
			local stack = { c.i }
			seen[c.i] = true
			while #stack > 0 do
				local i = table.remove(stack)
				local x = (i - 1) % W + 1
				local nb = { i - W, i + W, x > 1 and i - 1 or 0, x < W and i + 1 or 0 }
				for j = 1, 4 do
					local n = nb[j]
					if n > 0 and self.at[n] and not seen[n] then
						seen[n] = true
						stack[#stack + 1] = n
					end
				end
			end
		end
	end
	if opts.status then self.phase, self.left = opts.status.phase, opts.status.left end
	return self
end

function Curtain:active()
	return #self.cells > 0
end

function Curtain:set_reduced(v)
	self.reduced = v and true or false
end

-- Core events: `curtain` (the phase changed) and `curtain_left` (a move went by).
function Curtain:event(e, t)
	local ty = e.type
	if ty == "curtain" then
		if e.phase ~= self.phase then self.changed_at = t end
		self.phase, self.left = e.phase, e.left
	elseif ty == "curtain_left" then
		self.phase, self.left = e.phase, e.left
	end
end

function Curtain:closed_at(x, y)
	return self.phase == "closed" and self.at[(y - 1) * self.W + x] ~= nil
end

-- The player tried to move what is under the closed curtain of (x, y): it shakes. Returns true if there is one.
function Curtain:nope(x, y, t)
	local c = self.at[(y - 1) * self.W + x]
	if not c then return false end
	self.nope_cell, self.nope_at = c, t
	return true
end

-- What the core says now (the janitor's look). Returns 1 if this side showed something else.
function Curtain:sync(status)
	if not status or #self.cells == 0 then return 0 end
	if status.phase == self.phase and status.left == self.left then return 0 end
	self.phase, self.left, self.changed_at = status.phase, status.left, nil
	return 1
end

-- How closed the curtains are drawn at time t: 0 open .. 1 closed, and the sway of the move (0 at rest).
function Curtain:closedness(t)
	local target = self.phase == "closed" and 1 or 0
	local at = self.changed_at
	if not at then return target, 0 end
	local u = (t - at) / M.MOVE_TIME
	if u >= 1 or self.reduced then
		if u >= 1 then self.changed_at = nil end
		return target, 0
	end
	if u < 0 then u = 0 end
	local k = level_anim.ease_in_out(u)
	local c = target == 1 and k or 1 - k
	return c, math.sin(u * math.pi)
end

-- Appends the marks of this frame: per cell the open frame (unless the closed curtain covers it all) and the
-- closed curtain (while it is at least partly drawn), then the pips of every drape.
function Curtain:fill(list, n, geom, t, sx, sy)
	local start = n
	local cells = self.cells
	if #cells == 0 or not geom then
		self.n = 0
		return n
	end
	sx, sy = sx or 0, sy or 0
	local cell = geom.cell
	local c, sway = self:closedness(t)
	local shake_cell, shake = nil, 0
	if self.nope_at then
		local dt = t - self.nope_at
		if dt >= M.NOPE_TIME or dt < 0 then
			self.nope_cell, self.nope_at = nil, nil
		elseif not self.reduced then
			shake_cell = self.nope_cell
			shake = cell * M.NOPE_AMP * (1 - dt / M.NOPE_TIME) * math.sin(dt * M.NOPE_FREQ)
		end
	end
	for k = 1, #cells do
		local e = cells[k]
		local lx, ly = geom:center(e.x, e.y)
		lx, ly = lx + sx, ly + sy
		if c < 1 then
			local m = e.open
			m.x, m.y, m.w, m.h, m.alpha = lx, ly, cell, cell, 1
			n = n + 1
			list[n] = m
		end
		if c > 0 then
			local m = e.closed
			m.x, m.y = lx + (e == shake_cell and shake or 0), ly
			m.w, m.h, m.alpha = cell * (1 + M.SWAY * sway), cell, c
			n = n + 1
			list[n] = m
		end
	end
	local left = self.left
	if left > M.MAX_PIPS then left = M.MAX_PIPS end
	if left > 0 then
		local color = M.PIP_COLOR[self.phase] or "#FFFFFF"
		local size, step = cell * M.PIP_SIZE, cell * M.PIP_STEP
		for h = 1, #self.heads do
			local head = self.heads[h]
			local lx, ly = geom:center(head.cell.x, head.cell.y)
			local x0 = lx + sx - step * (left - 1) / 2
			local y = ly + sy + cell * M.PIP_Y
			for j = 1, left do
				local m = head.pips[j]
				m.x, m.y, m.w, m.h, m.color, m.alpha = x0 + step * (j - 1), y, size, size, color, 1
				n = n + 1
				list[n] = m
			end
		end
	end
	self.n = n - start
	return n
end

-- marks in the last list
function Curtain:count()
	return self.n
end

return M
