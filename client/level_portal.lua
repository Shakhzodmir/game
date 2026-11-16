-- The portals of the level board (core-rules 10.14; pure Lua, screens/level/level_bg.gui_script draws them).
--
-- A portal pair links two columns: a piece that stands in the ENTRANCE cell while the EXIT cell is empty
-- dives into the entrance and comes out of the exit. The core says which cells are portals
-- (game:cells()[i].portal = {role = "in"|"out", pair, x, y}: the role, the number of the pair and the cell
-- of the other end) and tells every hop with a `portal` event {id, fx, fy, x, y, pair}
-- (client/level_anim.lua shrinks the piece into the entrance and grows it out of the exit). This module
-- holds the look:
--
--   picture ... blockers/portal_in on the entrance, blockers/portal_out on the exit, drawn at cell size over
--               the cell tile (and over a floor tile or a carpet of that cell) and UNDER the piece; the
--               middle of the picture is see-through, so the piece on it reads
--   pair ...... the two cells of a pair wear the same MARK: a small glowing gem (fx/glow_dot) in the top
--               left corner of the cell, tinted with the colour of the pair (COLORS, by the number of the
--               pair, repeating after the last). With TINT = true the picture itself is tinted with that
--               colour as well (for a real picture that is drawn in neutral white)
--   hop ....... HOP_TICKS display ticks: the first half the piece shrinks in the entrance cell, the second
--               half it grows in the exit cell (a one-cell fall of the core takes the same 7 ticks)
--   sound ..... the whoosh of a swap, soft and high (client/level_audio.lua)
--
--   local level_portal = require("client.level_portal")
--   level_portal.active(cells)    -- does the board (game:cells()) have a portal at all
--   level_portal.tiles(cells)     -- {{i, role, pair, image, color = {r, g, b}}, ...} by cell index
--   level_portal.color(pair)      -- {r, g, b} of a pair

local M = {}

M.IMAGE_IN = "blockers/portal_in"
M.IMAGE_OUT = "blockers/portal_out"
M.MARK = "fx/glow_dot"
M.MARK_SIZE = 0.3     -- of a cell
M.MARK_AT = { -0.33, 0.33 } -- its centre from the centre of the cell, in cells (x right, y up): the top left corner
M.TINT = false        -- tint the picture itself with the colour of the pair
-- colours of the pairs, far apart from one another
M.COLORS = {
	{ 0.20, 0.85, 1.00 }, -- cyan
	{ 1.00, 0.35, 0.75 }, -- pink
	{ 0.55, 1.00, 0.30 }, -- lime
	{ 1.00, 0.80, 0.15 }, -- amber
	{ 0.70, 0.45, 1.00 }, -- violet
	{ 1.00, 1.00, 1.00 }, -- white
}
M.HOP_TICKS = 7
M.SFX, M.SFX_GAIN, M.SFX_SPEED = "swap", 0.4, 1.5

function M.active(cells)
	for i = 1, #(cells or {}) do
		if cells[i].portal then return true end
	end
	return false
end

function M.color(pair)
	return M.COLORS[((pair or 1) - 1) % #M.COLORS + 1]
end

function M.image(role)
	return role == "in" and M.IMAGE_IN or M.IMAGE_OUT
end

function M.tiles(cells)
	local out = {}
	for i = 1, #(cells or {}) do
		local p = cells[i].portal
		if p then out[#out + 1] = { i = i, role = p.role, pair = p.pair, image = M.image(p.role), color = M.color(p.pair) } end
	end
	return out
end

return M
