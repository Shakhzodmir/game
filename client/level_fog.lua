-- The stage fog of the level board (core-rules 10.13), as marks of client/level_view.lua.
--
-- Fog is the first element that only HIDES. Whatever stands in a fogged cell behaves in the core exactly as
-- it would without the fog: it falls, it can be swapped, it matches, it is hit. The player just does not see
-- it. A match in the cell or next to it, or any effect that reaches the cell, blows the fog off for good
-- (the core's `fog` event {x, y}); fog never comes back and never spreads. This module holds the look and
-- what the board needs to keep the secret:
--
--   cloud ..... blockers_fog over the cell, above the pieces, the wires and everything that flies; the
--               clouds are a little wider than a cell, so neighbours close into one bank. The cloud never
--               moves by itself: a board at rest writes nothing to the engine
--   hidden .... F:on(x, y): the board hides the sprite of every piece whose centre is under a cloud
--               (client/level_anim.lua, fog_at), so nothing shows through the soft edge of the picture
--   puff ...... the `fog` event: the cloud swells and fades in PUFF_TIME (with reduced motion it just
--               fades); client/level_effects.lua adds a few dust puffs, client/level_audio.lua a soft whoosh
--   input ..... F:unknown(x, y): what the input is told about a fogged cell, the same for every content (a
--               piece, a special, a blocker, nothing): an idle thing that may be picked and swiped. The core
--               judges the move; a refusal is shown like a failed swap (screens/level/board.script), so
--               trying a move tells the player only whether it worked
--   hint ...... F:hint(a, b, phase): the cloud of a hinted cell swells with the wobble (the piece under it
--               is not drawn, so it cannot wobble itself)
--   refusal ... F:nope(x, y, t): the cloud shakes
--
--   local level_fog = require("client.level_fog")
--   local F = level_fog.new({cells = game:cells(), W = W, reduced = bool})
--   F:active()                           -- is any cell still fogged (or puffing)
--   F:on(x, y)                           -- is that cell fogged now
--   F:event(e, t)                        -- every core event (t = real seconds)
--   n = F:fill(list, n, geom, t, sx, sy) -- appends this frame's marks to list[n + 1 ..]; returns the new n
--   F:unknown(x, y), F:find(id)          -- the stand-in of a fogged cell for client/level_input.lua
--   F:sync(game:cells())                 -- the janitor: the number of cells that were not the core's
--   F:set_reduced(bool)
--
-- Nothing is allocated per frame: the mark and the stand-in of a cell are made once.

local M = {}

M.IMAGE = "blockers/fog"   -- image key (the icon of the `fog` goal)
M.ANIM = "blockers_fog"    -- animation id of the game atlas, 160 art px per cell
M.ART = 160
M.Z = 0.215            -- over the pieces (up to 0.14), the wires (0.2) and the curtains (0.21)
M.SIZE = 1.12          -- of a cell: neighbouring clouds overlap into one bank
M.PUFF_TIME = 0.32     -- seconds a cloud takes to blow away
M.PUFF_SCALE = 1.45    -- ... swelling to this size
M.HINT_SCALE = 0.1     -- the cloud of a hinted cell swells by this share with the wobble
M.NOPE_TIME = 0.3      -- a refused touch: the cloud shakes this long ...
M.NOPE_AMP = 0.06      -- ... by this share of a cell ...
M.NOPE_FREQ = 55       -- ... three swings (radians per second)
M.COLOR = "#CFC6E6"    -- its wisps: the dust of a puff (client/level_effects.lua)
M.PUFF_FX = "dust"     -- the existing dust particles
M.PUFF_COUNT = 5
-- the puff: the whoosh of a swap, soft and high (client/level_audio.lua)
M.PUFF_SFX, M.PUFF_GAIN, M.PUFF_SPEED = "swap", 0.4, 1.35
M.FOG_ID = 3000000     -- the id of the stand-in of cell i is FOG_ID + i (piece ids and their chains are far below)

local Fog = {}
Fog.__index = Fog

-- opts.cells = game:cells() (the `fog` flag), opts.W.
function M.new(opts)
	opts = opts or {}
	local W = opts.W or 1
	local self = setmetatable({
		W = W, cells = {}, at = {}, left = 0, reduced = opts.reduced and true or false,
		nope_cell = nil, nope_at = nil, hint_a = nil, hint_b = nil, hint_phase = nil, n = 0,
	}, Fog)
	local cells = opts.cells or {}
	for i = 1, #cells do
		if cells[i].fog then
			local x = (i - 1) % W + 1
			local y = (i - x) / W + 1
			local c = {
				i = i, x = x, y = y, on = true, gone_at = nil,
				mark = { image = M.ANIM, iw = M.ART, ih = M.ART, glow = false, color = "#FFFFFF", z = M.Z, rot = 0,
					x = 0, y = 0, w = 1, h = 1, alpha = 1 },
				-- what the input sees in this cell, whatever the core has there
				unknown = { id = M.FOG_ID + i, kind = "regular", state = "idle", pinned = false, wired = false,
					chained = false, frozen = false, veiled = false, fogged = true, x = x, y = y },
			}
			self.cells[#self.cells + 1] = c
			self.at[i] = c
			self.left = self.left + 1
		end
	end
	return self
end

-- Was there fog on this level at all (the board skips the module on the other levels).
function Fog:any()
	return #self.cells > 0
end

function Fog:active()
	if self.left > 0 then return true end
	for k = 1, #self.cells do
		if self.cells[k].gone_at then return true end
	end
	return false
end

function Fog:set_reduced(v)
	self.reduced = v and true or false
end

function Fog:on(x, y)
	local c = self.at[(y - 1) * self.W + x]
	return c ~= nil and c.on
end

-- The stand-in of a fogged cell for the input (nil: the cell is not fogged).
function Fog:unknown(x, y)
	local c = self.at[(y - 1) * self.W + x]
	if c and c.on then return c.unknown end
	return nil
end

-- The stand-in by its id, while its cell is fogged (the input keeps a selection by id).
function Fog:find(id)
	local c = self.at[id - M.FOG_ID]
	if c and c.on then return c.unknown end
	return nil
end

-- Core events: `fog` {x, y}: the cell is clear from now on, its cloud blows away.
function Fog:event(e, t)
	if e.type ~= "fog" then return end
	local c = self.at[(e.y - 1) * self.W + e.x]
	if c and c.on then
		c.on, c.gone_at = false, t
		self.left = self.left - 1
	end
end

-- The player tried something in the fog and the core refused: the cloud shakes. Returns true if there is one.
function Fog:nope(x, y, t)
	local c = self.at[(y - 1) * self.W + x]
	if not c or not c.on then return false end
	self.nope_cell, self.nope_at = c, t
	return true
end

-- The hint of this frame (cells {x, y} or nil, phase 0..1 or nil): a fogged end swells with the wobble.
function Fog:hint(a, b, phase)
	self.hint_a, self.hint_b, self.hint_phase = a, b, phase
end

-- What the core says now (the janitor's look). Returns the number of cells this side showed differently.
function Fog:sync(cells)
	local fixed = 0
	for k = 1, #self.cells do
		local c = self.cells[k]
		local on = cells[c.i] ~= nil and cells[c.i].fog == true
		if on ~= c.on then
			self.left = self.left + (on and 1 or -1)
			c.on, c.gone_at = on, nil
			fixed = fixed + 1
		end
	end
	return fixed
end

-- Appends the marks of this frame: the cloud of every fogged cell and of every cell whose cloud is blowing away.
function Fog:fill(list, n, geom, t, sx, sy)
	local start = n
	local cells = self.cells
	if #cells == 0 or not geom then
		self.n = 0
		return n
	end
	sx, sy = sx or 0, sy or 0
	local cell = geom.cell
	local size = cell * M.SIZE
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
	local ha, hb, hp = self.hint_a, self.hint_b, self.hint_phase
	local swell = 0
	if hp and not self.reduced then swell = M.HINT_SCALE * math.sin(hp * math.pi) end
	for k = 1, #cells do
		local c = cells[k]
		local m = c.mark
		if c.on then
			local lx, ly = geom:center(c.x, c.y)
			local s = size
			if swell ~= 0 and ((ha and ha[1] == c.x and ha[2] == c.y) or (hb and hb[1] == c.x and hb[2] == c.y)) then
				s = size * (1 + swell)
			end
			m.x, m.y = lx + sx + (c == shake_cell and shake or 0), ly + sy
			m.w, m.h, m.alpha = s, s, 1
			n = n + 1
			list[n] = m
		elseif c.gone_at then
			local u = (t - c.gone_at) / M.PUFF_TIME
			if u >= 1 or u < 0 then
				c.gone_at = nil
			else
				local lx, ly = geom:center(c.x, c.y)
				local s = size * (self.reduced and 1 or (1 + (M.PUFF_SCALE - 1) * u))
				m.x, m.y, m.w, m.h, m.alpha = lx + sx, ly + sy, s, s, 1 - u
				n = n + 1
				list[n] = m
			end
		end
	end
	self.n = n - start
	return n
end

-- marks in the last list
function Fog:count()
	return self.n
end

-- The number of fogged cells of a decoded level (the counter of the `fog` goal).
function M.count(data)
	local n = 0
	for _, at in ipairs(type(data) == "table" and type(data.fog) == "table" and data.fog or {}) do
		if type(at) == "table" then n = n + 1 end
	end
	return n
end

return M
