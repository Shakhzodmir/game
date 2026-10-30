-- The look of the dance-floor tiles on the level board (pure Lua; screens/level/level_bg.gui_script draws it).
--
-- One colour language, so that the board, the goal icon and the start window agree: VIOLET is a tile that is
-- still to be lit, GOLD is a tile that is lit (the goal counts the violet ones down). A tile with two layers
-- (hp 2 in the level file) shows its progress: violet with a double outline, then violet with a gold core
-- ("half": one layer is gone, one more hit lights it), then gold. A tile with one layer goes violet, gold.
-- The art is tools/art/blockers.py (draw_floor); docs/design/art-direction.md, "Танцпол".
--
--   local level_floor = require("client.level_floor")
--   level_floor.stage(start, hp)    -- "two" | "one" | "half" | "lit"; start = hp in the level file, hp = what is left
--   level_floor.image(start, hp)    -- the atlas image of that stage ("blockers/floor_2", ...)
--   level_floor.pop(stage)          -- {scale, time} of the pop the tile makes when it changes into `stage`, or nil
--   level_floor.GOAL_ICON           -- the goal icon (HUD, start window): the unlit tile on the gold one it turns into

local M = {}

M.IMAGE = { two = "blockers/floor_2", one = "blockers/floor_1", half = "blockers/floor_half", lit = "blockers/floor_lit" }
M.GOAL_ICON = "ui/icons/goal_floor"
-- a tile that changes into this stage jumps to `scale` and settles (EASING_OUTBACK) in `time` seconds: the
-- last layer is the big moment, the first of two a smaller one
M.POP = { half = { scale = 1.12, time = 0.28 }, lit = { scale = 1.26, time = 0.4 } }

function M.stage(start, hp)
	if hp <= 0 then return "lit" end
	if hp >= 2 then return "two" end
	return start >= 2 and "half" or "one"
end

function M.image(start, hp)
	return M.IMAGE[M.stage(start, hp)]
end

function M.pop(stage)
	return M.POP[stage]
end

return M
