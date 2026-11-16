-- The carpet of the level board (core-rules 10.8; pure Lua, screens/level/level_bg.gui_script draws it).
--
-- The carpet is a covering of the cells that the player spreads: a match that stands on it rolls it out under
-- all its cells, and the goal is to cover the whole board. The core says which cells are covered
-- (game:cells()[i].carpet) and tells every newly covered cell with a `carpet` event. This module holds the look:
--
--   picture ... blockers/carpet, a square tile drawn over the cell tile and UNDER the piece (the background
--               GUI is below the board sprites), slightly inset in the cell (INSET) so that the checker of
--               the board shows between two carpets and the tassels of the real picture have room
--   unroll .... a cell that gets covered: its carpet grows from POP.from of its size and settles with a small
--               overshoot (EASING_OUTBACK) in POP.time seconds; with reduced motion it is just there
--   goal ...... the same picture as the goal icon (HUD, start window), with the number of bare cells
--
--   local level_carpet = require("client.level_carpet")
--   level_carpet.active(cells)      -- does the board (game:cells()) have a carpet at all
--   level_carpet.count(data)        -- bare cells at the start of a decoded level (the goal's number), or nil
--   level_carpet.size(cell)         -- the side of the carpet tile for a cell of `cell` pixels

local M = {}

M.IMAGE = "blockers/carpet"
M.INSET = 0.92
M.POP = { from = 0.35, time = 0.32 }

function M.active(cells)
	for i = 1, #(cells or {}) do
		if cells[i].carpet then return true end
	end
	return false
end

function M.size(cell)
	return cell * M.INSET
end

-- Bare cells of a decoded level file: every cell of `cells` ('#') that is not in the `carpet` list. nil if the
-- level has no such list or no board (the HUD then shows the goal without a number until the core counts).
function M.count(data)
	if type(data) ~= "table" or type(data.cells) ~= "table" or type(data.carpet) ~= "table" then return nil end
	local n = 0
	local exists = {}
	for y, row in ipairs(data.cells) do
		if type(row) == "string" then
			for x = 1, #row do
				if string.sub(row, x, x) == "#" then
					exists[(x - 1) .. "," .. (y - 1)] = true
					n = n + 1
				end
			end
		end
	end
	for _, at in ipairs(data.carpet) do
		if type(at) == "table" then
			local k = tostring(at[1]) .. "," .. tostring(at[2])
			if exists[k] then
				exists[k] = nil -- (a cell listed twice is counted once)
				n = n - 1
			end
		end
	end
	return n > 0 and n or nil
end

return M
