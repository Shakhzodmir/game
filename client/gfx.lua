-- Procedural RGBA pixel buffers for GUI textures (pure Lua).
-- client/ui.lua turns them into GUI textures with gui.new_texture, so the
-- bright rounded panels, buttons and the sky gradient look right even before
-- (or without) the generated art in assets/images.
--
-- Colors are {r, g, b, a} with components 0..1. Buffers are strings of
-- width * height * 4 bytes, first row = top of the image, with PREMULTIPLIED
-- alpha (rgb * a): Defold blends GUI textures as premultiplied
-- (ONE, ONE_MINUS_SRC_ALPHA), like the atlases it builds.

local M = {}

local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt
local char = string.char

-- "#RRGGBB" or "#RRGGBBAA" -> {r, g, b, a}
function M.hex(s, alpha)
	s = string.gsub(s, "^#", "")
	local r = tonumber(string.sub(s, 1, 2), 16) / 255
	local g = tonumber(string.sub(s, 3, 4), 16) / 255
	local b = tonumber(string.sub(s, 5, 6), 16) / 255
	local a = alpha
	if a == nil then a = #s >= 8 and tonumber(string.sub(s, 7, 8), 16) / 255 or 1 end
	return { r, g, b, a }
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

function M.mix(c1, c2, t)
	return { lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t), lerp(c1[3], c2[3], t), lerp(c1[4] or 1, c2[4] or 1, t) }
end

-- Color of a multi-stop gradient at t (0..1). stops = {{t, color}, ...} sorted.
function M.sample(stops, t)
	if t <= stops[1][1] then return stops[1][2] end
	for i = 2, #stops do
		local a, b = stops[i - 1], stops[i]
		if t <= b[1] then
			return M.mix(a[2], b[2], (t - a[1]) / (b[1] - a[1]))
		end
	end
	return stops[#stops][2]
end

local function byte(v)
	return floor(max(0, min(1, v)) * 255 + 0.5)
end

-- Premultiplied RGBA pixel.
local function px(c, alpha)
	local a = (c[4] or 1) * alpha
	return char(byte(c[1] * a), byte(c[2] * a), byte(c[3] * a), byte(a))
end

-- Vertical gradient, `height` px tall, `width` px wide. stops as in sample().
function M.vertical_gradient(width, height, stops)
	local rows = {}
	for y = 0, height - 1 do
		local c = M.sample(stops, height > 1 and y / (height - 1) or 0)
		rows[#rows + 1] = string.rep(px(c, 1), width)
	end
	return table.concat(rows)
end

-- Signed distance to a rounded rectangle of size w x h (pixel centres).
local function sd_round_rect(x, y, w, h, r)
	local qx = math.abs(x - w / 2) - (w / 2 - r)
	local qy = math.abs(y - h / 2) - (h / 2 - r)
	local ox, oy = max(qx, 0), max(qy, 0)
	return sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0) - r
end

-- Rounded rectangle, anti-aliased edge. opts:
--   top, bottom      fill colors (vertical gradient), default white
--   border, border_w optional inner border color and width (px)
--   gloss            0..1 strength of a white highlight on the upper part
--   shelf, shelf_h   darker "shelf" color along the bottom (3D button look)
function M.round_rect(w, h, r, opts)
	opts = opts or {}
	local white = { 1, 1, 1, 1 }
	local top = opts.top or white
	local bottom = opts.bottom or top
	local shelf_h = opts.shelf and (opts.shelf_h or floor(h * 0.12)) or 0
	local out = {}
	for y = 0, h - 1 do
		local cy = y + 0.5
		local face_t = (h - shelf_h) > 1 and min(1, cy / (h - shelf_h)) or 0
		local base = (shelf_h > 0 and cy > h - shelf_h) and opts.shelf or M.mix(top, bottom, face_t)
		local row = {}
		for x = 0, w - 1 do
			local d = sd_round_rect(x + 0.5, cy, w, h, r)
			local a = min(1, max(0, 0.5 - d))
			if a <= 0 then
				row[#row + 1] = "\0\0\0\0"
			else
				local c = base
				if opts.border and d > -(opts.border_w or 3) then
					c = opts.border
				elseif opts.gloss and opts.gloss > 0 and cy < (h - shelf_h) * 0.45 then
					-- soft white band on the upper face
					local g = opts.gloss * (1 - cy / ((h - shelf_h) * 0.45)) * 0.9
					c = M.mix(c, white, g)
				end
				row[#row + 1] = px(c, a)
			end
		end
		out[#out + 1] = table.concat(row)
	end
	return table.concat(out)
end

-- Filled disc with a soft edge (softness px), white by default.
function M.disc(size, softness, color)
	color = color or { 1, 1, 1, 1 }
	softness = softness or 1
	local r = size / 2
	local out = {}
	for y = 0, size - 1 do
		local row = {}
		for x = 0, size - 1 do
			local dx, dy = x + 0.5 - r, y + 0.5 - r
			local d = sqrt(dx * dx + dy * dy) - (r - softness)
			local a = min(1, max(0, 1 - d / softness))
			row[#row + 1] = px(color, a)
		end
		out[#out + 1] = table.concat(row)
	end
	return table.concat(out)
end

return M
