-- Screen geometry (pure Lua): the 720x1280 logical screen fitted into any
-- window, safe areas, and the board rectangle for a W x H level.
--
-- Logical coordinates: x to the right, y UP, (0, 0) = bottom-left corner of
-- the 720x1280 design area. The render script draws the world with the same
-- fit transform, and client/ui.lua scales GUI roots by it, so world and GUI
-- share these coordinates. On a window with another aspect ratio the visible
-- area extends past 0..720 or 0..1280 (see fit().x0 .. x1, y0 .. y1).
--
--   local layout = require("client.layout")
--   local f = layout.fit(window.get_size())       -- scale, offsets, visible rect
--   local lx, ly = layout.screen_to_logical(f, action.screen_x, action.screen_y)
--   local area = layout.play_area(f)              -- between HUD and booster bar
--   local b = layout.board(9, 9, area)            -- cell size and board rect
--   local x, y = layout.cell_center(b, col, row)  -- col/row from 0, row 0 = top
--   local col, row = layout.cell_at(b, lx, ly)    -- nil outside the board

local M = {}

M.W, M.H = 720, 1280
M.HUD_TOP = 230       -- logical px reserved for the HUD at the top
M.BOOSTER_BAR = 200   -- logical px reserved for the booster bar at the bottom
M.BOARD_MARGIN_X = 18 -- min free space left and right of the board
M.BOARD_MARGIN_Y = 12 -- min free space above and below the board
M.MAX_CELL = 100      -- cells never grow beyond this (small boards)
M.UNITS_PER_CELL = 3600 -- core units per cell (decisions.md, 2.8)

-- How the logical screen sits in a window of ww x wh pixels.
-- Returns {scale, ox, oy, ww, wh, x0, y0, x1, y1}: window pixel = o + logical * scale;
-- x0..x1, y0..y1 = logical rectangle visible in the window (contains 0..W, 0..H).
function M.fit(ww, wh)
	ww, wh = tonumber(ww) or M.W, tonumber(wh) or M.H
	if ww <= 0 or wh <= 0 then ww, wh = M.W, M.H end
	local s = math.min(ww / M.W, wh / M.H)
	local ox, oy = (ww - M.W * s) / 2, (wh - M.H * s) / 2
	return {
		scale = s, ox = ox, oy = oy, ww = ww, wh = wh,
		x0 = -ox / s, y0 = -oy / s, x1 = M.W + ox / s, y1 = M.H + oy / s,
	}
end

function M.screen_to_logical(f, sx, sy)
	return (sx - f.ox) / f.scale, (sy - f.oy) / f.scale
end

function M.logical_to_screen(f, lx, ly)
	return f.ox + lx * f.scale, f.oy + ly * f.scale
end

-- Visible logical rect minus the device insets (window pixels, e.g. from
-- window.get_safe_area(): inset_left/right/top/bottom). The result is never
-- smaller than the 720x1280 design area: design content always fits.
function M.safe_rect(f, insets)
	insets = insets or {}
	local s = f.scale
	local r = {
		x0 = f.x0 + (insets.inset_left or insets.left or 0) / s,
		x1 = f.x1 - (insets.inset_right or insets.right or 0) / s,
		y0 = f.y0 + (insets.inset_bottom or insets.bottom or 0) / s,
		y1 = f.y1 - (insets.inset_top or insets.top or 0) / s,
	}
	r.x0, r.y0 = math.min(r.x0, 0), math.min(r.y0, 0)
	r.x1, r.y1 = math.max(r.x1, M.W), math.max(r.y1, M.H)
	r.w, r.h = r.x1 - r.x0, r.y1 - r.y0
	return r
end

-- Area for the board: from the booster bar (anchored to the safe bottom) to
-- the HUD (anchored to the safe top), across the design width.
-- opts: {hud_top = M.HUD_TOP, booster_bar = M.BOOSTER_BAR, insets = {...}}
function M.play_area(f, opts)
	opts = opts or {}
	local safe = f and M.safe_rect(f, opts.insets) or { x0 = 0, y0 = 0, x1 = M.W, y1 = M.H }
	local top = math.max(safe.y1, M.H) - (opts.hud_top or M.HUD_TOP)
	local bottom = math.min(safe.y0, 0) + (opts.booster_bar or M.BOOSTER_BAR)
	-- tall phones: do not let the play area grow past 1.25x the design height
	local max_h = (M.H - M.HUD_TOP - M.BOOSTER_BAR) * 1.25
	if top - bottom > max_h then
		local mid = (top + bottom) / 2
		top, bottom = mid + max_h / 2, mid - max_h / 2
	end
	return { x0 = 0, y0 = bottom, x1 = M.W, y1 = top }
end

-- Board of cols x rows cells centred in area (default: the design play area).
-- opts: {margin_x, margin_y, max_cell, integer = true (whole-pixel cells)}.
-- Returns {cols, rows, cell, x0, y0, x1, y1, width, height, cx, cy}.
function M.board(cols, rows, area, opts)
	if type(cols) ~= "number" or type(rows) ~= "number" or cols < 1 or rows < 1 then
		error("layout.board needs positive cols and rows", 2)
	end
	opts = opts or {}
	area = area or M.play_area(nil)
	local mx = opts.margin_x or M.BOARD_MARGIN_X
	local my = opts.margin_y or M.BOARD_MARGIN_Y
	local aw = (area.x1 - area.x0) - 2 * mx
	local ah = (area.y1 - area.y0) - 2 * my
	local cell = math.min(aw / cols, ah / rows, opts.max_cell or M.MAX_CELL)
	if opts.integer ~= false then cell = math.floor(cell) end
	local w, h = cell * cols, cell * rows
	local cx, cy = (area.x0 + area.x1) / 2, (area.y0 + area.y1) / 2
	local x0, y0 = cx - w / 2, cy - h / 2
	if opts.integer ~= false then x0, y0 = math.floor(x0 + 0.5), math.floor(y0 + 0.5) end
	return {
		cols = cols, rows = rows, cell = cell,
		x0 = x0, y0 = y0, x1 = x0 + w, y1 = y0 + h,
		width = w, height = h, cx = x0 + w / 2, cy = y0 + h / 2,
	}
end

-- Centre of a cell; col 0 = left, row 0 = TOP row (level JSON convention).
function M.cell_center(b, col, row)
	return b.x0 + (col + 0.5) * b.cell, b.y1 - (row + 0.5) * b.cell
end

-- Cell under a logical point, or nil outside the board.
function M.cell_at(b, lx, ly)
	if lx < b.x0 or lx >= b.x1 or ly <= b.y0 or ly > b.y1 then return nil end
	local col = math.floor((lx - b.x0) / b.cell)
	local row = math.floor((b.y1 - ly) / b.cell)
	if col < 0 or col >= b.cols or row < 0 or row >= b.rows then return nil end
	return col, row
end

-- Core units (1 cell = 3600) to logical pixels for a cell size.
function M.units_to_px(units, cell)
	return units / M.UNITS_PER_CELL * cell
end

return M
