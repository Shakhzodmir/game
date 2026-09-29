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

-- Average colour bands along one edge of a decoded image (image.load):
-- buf = raw pixels, rows top first, bpp 3 (RGB) or 4 (RGBA, straight alpha,
-- or premultiplied when premul is true). side = "left" | "right" | "top" |
-- "bottom"; `bands` colours along that edge (first = top / left), each the
-- average of the `depth` outermost pixels of its rows / columns.
-- Returns {{r, g, b, a}, ...} with straight alpha, components 0..1.
function M.edge_colors(buf, w, h, bpp, side, bands, depth, premul)
	bands = math.max(1, math.floor(bands or 16))
	depth = math.max(1, math.min(math.floor(depth or 4), (side == "left" or side == "right") and w or h))
	local vertical = side == "left" or side == "right"
	local along = vertical and h or w
	local acc = {}
	for b = 1, bands do acc[b] = { 0, 0, 0, 0, 0 } end
	local byte = string.byte
	for i = 0, along - 1 do
		local band = acc[math.min(bands, math.floor(i * bands / along) + 1)]
		for d = 0, depth - 1 do
			local x, y
			if side == "left" then x, y = d, i
			elseif side == "right" then x, y = w - 1 - d, i
			elseif side == "top" then x, y = i, d
			else x, y = i, h - 1 - d end
			local o = (y * w + x) * bpp + 1
			local r, g, bl, a = byte(buf, o, o + bpp - 1)
			a = bpp == 4 and a or 255
			if not premul then
				local k = a / 255
				r, g, bl = r * k, g * k, bl * k
			end
			band[1], band[2], band[3], band[4] = band[1] + r, band[2] + g, band[3] + bl, band[4] + a
			band[5] = band[5] + 1
		end
	end
	local out = {}
	for b = 1, bands do
		local t = acc[b]
		local n = math.max(1, t[5])
		local a = t[4] / n
		if a <= 0 then
			out[b] = { 1, 1, 1, 0 }
		else
			out[b] = { min(1, t[1] / n / a), min(1, t[2] / n / a), min(1, t[3] / n / a), a / 255 }
		end
	end
	return out
end

-- Texture that continues an image past one of its edges: the edge colours
-- (from edge_colors) stretched outwards and blended into `haze` (a colour)
-- by up to `amount` at the far end. side as in edge_colors; `steps` pixels
-- from the image edge outwards. Returns buf, width, height (premultiplied).
-- left/right: width = steps, height = #colors; top/bottom: the transpose.
function M.edge_fill(colors, side, steps, haze, amount)
	steps = math.max(2, math.floor(steps or 8))
	haze = haze or { 1, 1, 1, 1 }
	amount = amount or 0.4
	local n = #colors
	local vertical = side == "left" or side == "right"
	local w, h = vertical and steps or n, vertical and n or steps
	local rows = {}
	for y = 0, h - 1 do
		local row = {}
		for x = 0, w - 1 do
			local ci, s -- colour index and distance from the image edge (0..steps-1)
			if vertical then
				ci = y + 1
				s = side == "left" and (steps - 1 - x) or x
			else
				ci = x + 1
				s = side == "top" and (steps - 1 - y) or y
			end
			local t = s / (steps - 1)
			local c = M.mix(colors[ci], haze, amount * t * t)
			c[4] = 1
			row[#row + 1] = px(c, 1)
		end
		rows[#rows + 1] = table.concat(row)
	end
	return table.concat(rows), w, h
end

return M
