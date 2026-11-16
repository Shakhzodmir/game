-- The ice of the level board (core-rules 10.11; pure Lua).
--
-- A frozen piece is a regular piece inside an ice cube: it keeps its colour but does not move, does not fall
-- and takes no part in matches. The ice melts from OUTSIDE: every match next to it and every hit of a special
-- or a booster takes one layer off (hp 2 -> 1 -> gone); the piece then is an ordinary free piece again, where
-- it stood. The core tells it with `hit` {layer = "ice", id, x, y, hp} and, on the last layer, `thawed`
-- {id, x, y}; game:pieces() carries `ice` (the hp left) while the piece is frozen. This module holds the look:
--
--   pictures .. blockers/ice_2 (solid) and blockers/ice_1 (cracked): the number is the hp LEFT. The cube is
--               drawn OVER its piece (a second entry of the draw list of client/level_anim.lua, id
--               level_anim.ICE_ID + piece id), see-through (M.ALPHA) so the colour shows
--   a crack ... the cube jolts and flashes (client/level_anim.lua), icy sparks fly (client/level_effects.lua),
--               a short glassy tick (client/level_audio.lua)
--   the melt .. the cube swells and fades away over the piece, which pops; a soft pop
--   a drag .... a frozen piece is fixed (client/level_plates.lua kind "frozen", no plate: the cube says it):
--               the bounce of a failed swap, a shake and, once a session, a line that says how to free it
--
--   local level_ice = require("client.level_ice")
--   level_ice.image(hp)   -- image key "blockers/ice_N"
--   level_ice.anim(hp)    -- animation id "blockers_ice_N"

local M = {}

M.MAX_HP = 2
M.GOAL_ICON = "blockers/ice_2"       -- the solid cube: the icon of the `ice` goal
M.ALPHA = 0.85                       -- the cube over the piece (the picture itself is see-through as well)
M.COLOR = "#BFE9FF"                  -- icy sparks of a crack and of the melt
M.HIT_TIME = 0.3                     -- seconds the cube jolts after a crack
M.HIT_ROT = 5                        -- ... by this many degrees at first
M.HIT_FLASH = 0.6                    -- ... with a white flash of this strength
M.MELT_TIME = 0.32                   -- seconds the cube takes to swell and fade away
M.MELT_SCALE = 1.3
-- the crack: the hit of the record box, high and short (a glassy tick); the melt: a soft balloon pop
M.CRACK_SFX, M.CRACK_GAIN, M.CRACK_SPEED = "box_hit", 0.55, 1.7
M.MELT_SFX, M.MELT_GAIN, M.MELT_SPEED = "balloon_pop", 0.6, 1.25

local function stage(hp)
	hp = math.floor(tonumber(hp) or 1)
	if hp < 1 then return 1 end
	if hp > M.MAX_HP then return M.MAX_HP end
	return hp
end

function M.image(hp)
	return "blockers/ice_" .. stage(hp)
end

function M.anim(hp)
	return "blockers_ice_" .. stage(hp)
end

return M
