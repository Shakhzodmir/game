-- The conveyor belt of the level board (core-rules 10.9; pure Lua, screens/level/level_bg.gui_script draws it).
--
-- A belt is a path of cells; after every move the player spends it carries what stands on its cells one cell
-- on, and the content of its last cell comes back to the first. The core says which cells belong to a belt and
-- which way each of them moves (game:cells()[i].conveyor = {belt, pos, dir, last}) and tells every step with a
-- `conveyor` event (the moves of the riders; client/level_anim.lua slides them). This module holds the look:
--
--   picture ... blockers/conveyor, ONE tile whose arrows point RIGHT, drawn at cell size over the cell tile
--               (and over a floor tile or a carpet of that cell) and UNDER the piece, turned by the direction
--               of travel of its cell: TURN[dir] degrees, counter-clockwise (the GUI's z rotation)
--   sound ..... a soft mechanical tick a step (client/level_audio.lua), lower when the belt is jammed
--
--   local level_conveyor = require("client.level_conveyor")
--   level_conveyor.active(cells)    -- does the board (game:cells()) have a belt at all
--   level_conveyor.tiles(cells)     -- {{i = cell index, dir = "r"|"u"|"l"|"d", turn = degrees}, ...} by cell

local M = {}

M.IMAGE = "blockers/conveyor"
-- the picture points right; the GUI turns counter-clockwise
M.TURN = { r = 0, u = 90, l = 180, d = 270 }

function M.active(cells)
	for i = 1, #(cells or {}) do
		if cells[i].conveyor then return true end
	end
	return false
end

function M.turn(dir)
	return M.TURN[dir] or 0
end

function M.tiles(cells)
	local out = {}
	for i = 1, #(cells or {}) do
		local c = cells[i].conveyor
		if c then out[#out + 1] = { i = i, dir = c.dir, turn = M.turn(c.dir) } end
	end
	return out
end

return M
