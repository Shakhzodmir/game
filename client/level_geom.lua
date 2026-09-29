-- Board geometry of the level screen (pure Lua).
--
-- Core cells are 1-based {x, y} with y growing DOWN (core-rules.md, 0);
-- the screen uses logical 720x1280 coordinates with y UP (client/layout.lua).
-- This module converts between the two, turns core offsets (units, 3600 per
-- cell) into pixels, picks the backing edge tiles of shaped boards and finds
-- the segment tops where new pieces enter (their sprites are clipped there).
--
--   local geom = require("client.level_geom")
--   local g = geom.new(W, H, game:cells(), layout.play_area(fit, {insets = ...}))
--   g.cell                                  -- cell size in logical px
--   local lx, ly = g:center(x, y)           -- centre of core cell (x, y)
--   lx, ly = g:pos(p.x, p.y, p.offx, p.offy) -- where a piece of game:pieces() is drawn
--   local x, y = g:cell_at(lx, ly)          -- core cell under a point (nil off the grid)
--   local fx, fy = g:frac(lx, ly)           -- continuous cell coords (centres on integers)
--   g:edge_tiles()                          -- {{kind, turns, lx, ly}, ...} backing tiles
--   g:clip_top(x, y)                        -- logical y of the top edge of the segment of (x, y)

local layout = require("client.layout")

local M = {}

M.UNITS = 3600

-- Backing tile of a grid vertex from the 4 cells around it, (TL, TR, BL, BR)
-- -> {tile, clockwise quarter turns}. Same table as tools/art/gen_art.py
-- (EDGE_TILES) and the manifest note of board/edge_*.png: the base images
-- hold the cells bottom-right (outer), the 2 lower (side), top-left +
-- bottom-right (diag), all but top-left (inner), all (full).
M.EDGE_TILES = {
	["0001"] = { "outer", 0 }, ["0010"] = { "outer", 1 }, ["1000"] = { "outer", 2 }, ["0100"] = { "outer", 3 },
	["0011"] = { "side", 0 }, ["1010"] = { "side", 1 }, ["1100"] = { "side", 2 }, ["0101"] = { "side", 3 },
	["1001"] = { "diag", 0 }, ["0110"] = { "diag", 1 },
	["0111"] = { "inner", 0 }, ["1011"] = { "inner", 1 }, ["1110"] = { "inner", 2 }, ["1101"] = { "inner", 3 },
	["1111"] = { "full", 0 },
}

local G = {}
G.__index = G

local function exists_of(c)
	if type(c) == "table" then return c.exists and true or false end
	return c and true or false
end

-- cells: array 1..W*H of game:cells() entries (or booleans: the cell exists).
-- area: {x0, y0, x1, y1} logical rect for the board (layout.play_area);
-- opts are passed to layout.board (margin_x, margin_y, max_cell).
function M.new(W, H, cells, area, opts)
	if type(W) ~= "number" or type(H) ~= "number" or W < 1 or H < 1 then
		error("level_geom.new needs the board size", 2)
	end
	local rect = layout.board(W, H, area, opts)
	local self = setmetatable({
		W = W, H = H, rect = rect, cell = rect.cell,
		x0 = rect.x0, y1 = rect.y1,
		ex = {}, spawner = {}, exit = {}, top = {},
	}, G)
	for i = 1, W * H do
		local c = cells and cells[i]
		self.ex[i] = exists_of(c)
		self.spawner[i] = type(c) == "table" and c.spawner and true or false
		self.exit[i] = type(c) == "table" and c.exit and true or false
	end
	-- segment tops: the first existing cell of each vertical run
	for x = 1, W do
		local top = nil
		for y = 1, H do
			local i = (y - 1) * W + x
			if self.ex[i] then
				top = top or y
				self.top[i] = top
			else
				top = nil
				self.top[i] = false
			end
		end
	end
	return self
end

function G:index(x, y)
	return (y - 1) * self.W + x
end

function G:inside(x, y)
	return x >= 1 and x <= self.W and y >= 1 and y <= self.H
end

function G:exists(x, y)
	return self:inside(x, y) and self.ex[(y - 1) * self.W + x] or false
end

-- Centre of core cell (x, y) in logical coordinates.
function G:center(x, y)
	local c = self.cell
	return self.x0 + (x - 0.5) * c, self.y1 - (y - 0.5) * c
end

-- Where a piece of game:pieces() is drawn: the centre of its (target) cell
-- minus the core lag (vis = cell * 3600 - off, core-rules.md 1.2).
function G:pos(x, y, offx, offy)
	local c = self.cell
	local k = c / M.UNITS
	return self.x0 + (x - 0.5) * c - (offx or 0) * k, self.y1 - (y - 0.5) * c + (offy or 0) * k
end

-- Continuous cell coordinates of a logical point: cell centres on integers,
-- so the cell under the point is (floor(fx + 0.5), floor(fy + 0.5)).
function G:frac(lx, ly)
	local c = self.cell
	return (lx - self.x0) / c + 0.5, (self.y1 - ly) / c + 0.5
end

-- Core cell under a logical point, or nil outside the grid (the cell may be
-- a gap: check exists()).
function G:cell_at(lx, ly)
	local fx, fy = self:frac(lx, ly)
	local x, y = math.floor(fx + 0.5), math.floor(fy + 0.5)
	if not self:inside(x, y) then return nil end
	return x, y
end

-- Top row of the vertical run of existing cells that holds (x, y), or nil.
function G:seg_top(x, y)
	if not self:inside(x, y) then return nil end
	return self.top[(y - 1) * self.W + x] or nil
end

-- Logical y of the upper edge of that run: pieces entering at a spawner are
-- drawn only below it. nil for a gap.
function G:clip_top(x, y)
	local t = self:seg_top(x, y)
	if not t then return nil end
	return self.y1 - (t - 1) * self.cell
end

-- One backing tile per grid vertex (tools/art/gen_art.py board_backing):
-- {kind = "outer"|"side"|"diag"|"inner"|"full", turns = clockwise quarter
-- turns, lx, ly = the vertex}. Drawn cell-sized, centred on the vertex,
-- under the cells.
function G:edge_tiles()
	local out = {}
	local function has(x, y) return self:exists(x, y) and "1" or "0" end
	for j = 0, self.H do
		for i = 0, self.W do
			-- vertex between columns i, i+1 and rows j, j+1 (1-based cells)
			local key = has(i, j) .. has(i + 1, j) .. has(i, j + 1) .. has(i + 1, j + 1)
			local t = M.EDGE_TILES[key]
			if t then
				out[#out + 1] = {
					kind = t[1], turns = t[2],
					lx = self.x0 + i * self.cell, ly = self.y1 - j * self.cell,
				}
			end
		end
	end
	return out
end

-- Exits (microphone stands): {{x, y, lx, ly}, ...} with (lx, ly) the middle
-- of the lower edge of the exit cell.
function G:exits()
	local out = {}
	for y = 1, self.H do
		for x = 1, self.W do
			if self.exit[(y - 1) * self.W + x] then
				local lx, ly = self:center(x, y)
				out[#out + 1] = { x = x, y = y, lx = lx, ly = ly - self.cell / 2 }
			end
		end
	end
	return out
end

-- Unit direction of a bolt ("l" | "r" | "u" | "d") in logical coordinates.
local DIRS = { l = { -1, 0 }, r = { 1, 0 }, u = { 0, 1 }, d = { 0, -1 } }
function M.dir(d)
	local v = DIRS[d]
	if not v then return 0, 0 end
	return v[1], v[2]
end

-- Cells from (x, y) to the edge of the grid in direction d (core cells,
-- the start excluded): the length of a bolt in cells.
function G:run_length(x, y, d)
	if d == "l" then return x - 1 end
	if d == "r" then return self.W - x end
	if d == "u" then return y - 1 end
	if d == "d" then return self.H - y end
	return 0
end

return M
