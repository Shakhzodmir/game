-- Small procedural GUI kit for GLOW screens (GUI script context only).
--
-- A scene owns one root node that maps logical 720x1280 coordinates (y up,
-- (0,0) bottom-left, see client/layout.lua) onto the window with the same fit
-- transform the render script uses for the world. GUI files of the project
-- set adjust_reference: ADJUST_REFERENCE_DISABLED, so the engine does not
-- rescale nodes itself; gui.pick_node() still works with action.x/y.
--
--   local ui = require("client.ui")
--   function init(self)
--       self.ui = ui.scene({gui = "/screens/town/town.gui", on_resize = fn(fit)})
--       self.ui:sky()                                -- gradient covering the window
--       local layer = self.ui:layer()                -- container, rebuilt on its own
--       local t = self.ui:text(layer, "Hello", 360, 900, {font = "title", size = 64})
--       self.ui:button({parent = layer, x = 360, y = 200, w = 440, h = 120, style = "green",
--                       text = "Play", on_click = function() ... end})
--       self.ui:clear(layer)                         -- delete a subtree (and forget it)
--   end
--   function update(self, dt) self.ui:update(dt) end
--   function on_input(self, action_id, action) return self.ui:on_input(action_id, action) end
--   function final(self) self.ui:final() end
--
-- Images come from client/assets.lua: atlas images need their atlas in the
-- GUI file; loose images (districts/*, backgrounds/*) are loaded on first use
-- with image.load + gui.new_texture and released with release_images() or
-- final(). When an image is missing the kit draws a procedural shape instead.
--
-- Always delete nodes made by the kit with scene:clear(node): the scene keeps
-- lists of anchored / covering nodes and buttons, and a deleted node left in
-- them would break the next window resize.

local layout = require("client.layout")
local gfx = require("client.gfx")
local assets = require("client.assets")

local M = {}

M.PALETTE = {
	text = "#2B2345",
	text_soft = "#6B5E8F",
	white = "#FFFFFF",
	sky_top = "#43BFFF",
	sky = "#86DDFF",
	sky_low = "#C9F2FF",
	sun = "#FFF4C9",
	lavender = "#EFE8FF",
	panel_line = "#E3D9FF",
	shadow = "#5A3FA0",
	pink = "#FF4D8D",
	yellow = "#FFDB1A",
	coin = "#FFB020",
	gold = "#FFB020",
	green = "#22C55E",
	blue = "#2F80ED",
	purple = "#8B45FF",
	glow = "#FFD84D",
}

-- button styles: face top, face bottom, shelf, label outline
M.STYLES = {
	green = { "#6CF08E", "#22C55E", "#15964A", "#0F7A3B" },
	blue = { "#5CD6FF", "#2F80ED", "#1C5FC0", "#174E9E" },
	gold = { "#FFD84D", "#FFA41B", "#E07F00", "#B35F00" },
	pink = { "#FF7EB6", "#FF4D8D", "#D12F6B", "#A8204F" },
	purple = { "#C18CFF", "#8B45FF", "#6A2BD1", "#5220A6" },
	white = { "#FFFFFF", "#F3EEFF", "#D9CCF5", "#8B7BB8" },
}

M.FONT_FALLBACK = "body"
M.EDGE_BANDS = 48      -- colour bands along a background edge (backdrop)
M.EDGE_STEPS = 16      -- texels from the image edge outwards
M.EDGE_HAZE = "#FFFFFF"
M.EDGE_HAZE_AMOUNT = 0.35

local TOUCH = hash("touch")

local cache = {}       -- pixel buffers, computed once per app (shared Lua state)
local edge_cache = {}  -- loose image key -> {left, right, top, bottom} colour lists
local pulses = setmetatable({}, { __mode = "k" }) -- node -> {amount, period, base}

function M.color(hex, alpha)
	local c = gfx.hex(M.PALETTE[hex] or hex, alpha)
	return vmath.vector4(c[1], c[2], c[3], c[4])
end

local function cached(key, fn)
	local v = cache[key]
	if not v then
		v = fn()
		cache[key] = v
	end
	return v
end

-- procedural textures ------------------------------------------------------------------

local SKY_STOPS = {
	{ 0.0, gfx.hex("#43BFFF") }, { 0.4, gfx.hex("#86DDFF") }, { 0.75, gfx.hex("#C9F2FF") }, { 1.0, gfx.hex("#FFF4C9") },
}

local ROUND_SLICE = 26 -- border of px_round (radius 24 in a 64 px texture)

local TEXTURES = {
	px_sky = { 4, 256, function() return gfx.vertical_gradient(4, 256, SKY_STOPS) end },
	px_round = { 64, 64, function() return gfx.round_rect(64, 64, 24) end },
	px_disc = { 64, 64, function() return gfx.disc(64, 1.5) end },
	px_soft = { 64, 64, function() return gfx.disc(64, 24) end },
}

local function button_texture_spec(style)
	local s = M.STYLES[style] or M.STYLES.green
	return 64, 80, function()
		return gfx.round_rect(64, 80, 24, {
			top = gfx.hex(s[1]), bottom = gfx.hex(s[2]), shelf = gfx.hex(s[3]), shelf_h = 10, gloss = 0.35,
		})
	end
end

-- a compact round button face (no nine-slice) for small buttons
local function small_button_texture_spec(style)
	local s = M.STYLES[style] or M.STYLES.green
	return 48, 52, function()
		return gfx.round_rect(48, 52, 22, {
			top = gfx.hex(s[1]), bottom = gfx.hex(s[2]), shelf = gfx.hex(s[3]), shelf_h = 5, gloss = 0.35,
		})
	end
end

-- rounded rect with a small radius r: (2r + 6) px square, slice r + 2
local function small_round_texture_spec(r)
	local size = 2 * r + 6
	return size, size, function() return gfx.round_rect(size, size, r) end
end

-- Scene -------------------------------------------------------------------------------------

local Scene = {}
Scene.__index = Scene

-- opts: {gui = "/screens/town/town.gui" (to check texture availability),
--        on_resize = fn(fit) called after the window size changed}
function M.scene(opts)
	opts = opts or {}
	local self = setmetatable({
		gui_path = opts.gui,
		textures = {},   -- dynamic texture id -> true
		images = {},     -- loose image key -> {id, w, h}
		buttons = {},
		covers = {},     -- nodes that must cover the whole visible area
		anchored = {},   -- {node, edge, base_y}
		backdrops = {},  -- extension strips of backgrounds
		pressed = nil,
		on_resize = opts.on_resize,
		insets = nil,    -- raw safe-area insets (window pixels) for layout.play_area
	}, Scene)
	self.root = gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(0, 0, 0))
	gui.set_id(self.root, "ui_root")
	gui.set_pivot(self.root, gui.PIVOT_SW)
	self:refit(true)
	return self
end

function Scene:texture(id)
	if self.textures[id] then return id end
	local w, h, fn
	local spec = TEXTURES[id]
	if spec then
		w, h, fn = spec[1], spec[2], spec[3]
	elseif string.sub(id, 1, 9) == "px_btn_s_" then
		w, h, fn = small_button_texture_spec(string.sub(id, 10))
	elseif string.sub(id, 1, 7) == "px_btn_" then
		w, h, fn = button_texture_spec(string.sub(id, 8))
	elseif string.sub(id, 1, 9) == "px_round_" then
		w, h, fn = small_round_texture_spec(tonumber(string.sub(id, 10)) or 4)
	else
		return nil
	end
	local buf = cached(id, fn)
	local ok = gui.new_texture(id, w, h, "rgba", buf, false)
	if not ok then return nil end
	self.textures[id] = true
	return id
end

-- Re-applies the fit transform when the window size changed.
function Scene:refit(force)
	local ww, wh = window.get_size()
	if not force and ww == self.ww and wh == self.wh then return false end
	self.ww, self.wh = ww, wh
	local f = layout.fit(ww, wh)
	self.fit = f
	local ok, sa = pcall(window.get_safe_area) -- notches; full window on the web
	self.insets = ok and type(sa) == "table" and sa or nil
	self.safe = layout.safe_rect(f, self.insets)
	gui.set_position(self.root, vmath.vector3(f.ox, f.oy, 0))
	gui.set_scale(self.root, vmath.vector3(f.scale, f.scale, 1))
	for _, n in ipairs(self.covers) do
		self:_cover(n.node, n.mode, n.w, n.h)
	end
	for _, a in ipairs(self.anchored) do
		local p = gui.get_position(a.node)
		if a.edge == "top" then
			p.y = a.base_y + (self.safe.y1 - layout.H)
		else
			p.y = a.base_y + self.safe.y0
		end
		gui.set_position(a.node, p)
	end
	for _, b in ipairs(self.backdrops) do self:_fit_backdrop(b) end
	if self.on_resize and not force then self.on_resize(f) end
	return true
end

function Scene:update(dt)
	self:refit(false)
end

function Scene:final()
	for id in pairs(self.textures) do
		pcall(gui.delete_texture, id)
	end
	self.textures, self.images = {}, {}
	self.buttons, self.covers, self.anchored, self.backdrops = {}, {}, {}, {}
end

-- node helpers ------------------------------------------------------------------------------------

local function v3(x, y) return vmath.vector3(x or 0, y or 0, 0) end

-- true when n is root or inside root's subtree
local function within(n, root)
	while n do
		if n == root then return true end
		n = gui.get_parent(n)
	end
	return false
end

-- Deletes a node and its children and forgets them (anchors, covers,
-- buttons, backdrops). Use it for every node made through the scene.
function Scene:clear(node)
	if not node then return end
	local function prune(list, field)
		for i = #list, 1, -1 do
			local n = field and list[i][field] or list[i]
			if within(n, node) then table.remove(list, i) end
		end
	end
	prune(self.buttons, "node")
	prune(self.covers, "node")
	prune(self.anchored, "node")
	prune(self.backdrops, "image")
	if self.pressed and within(self.pressed.node, node) then self.pressed = nil end
	if self.input_root and within(self.input_root, node) then self.input_root = nil end
	gui.delete_node(node)
end

-- An empty container node at the origin (children use logical coordinates).
function Scene:layer(parent, id)
	local n = gui.new_box_node(v3(0, 0), v3(0, 0))
	gui.set_parent(n, parent or self.root)
	gui.set_pivot(n, gui.PIVOT_SW)
	if id then gui.set_id(n, id) end
	return n
end

-- Box at (x, y) (logical, relative to parent), size w x h.
-- opts: {color, alpha, pivot, texture ("px_round" | atlas name), anim, slice9 = {l,t,r,b}, id}
function Scene:box(parent, x, y, w, h, opts)
	opts = opts or {}
	local n = gui.new_box_node(v3(x, y), v3(w, h))
	gui.set_parent(n, parent or self.root)
	if opts.pivot then gui.set_pivot(n, opts.pivot) end
	local c = opts.color
	if type(c) == "string" then c = M.color(c, opts.alpha) end
	gui.set_color(n, c or vmath.vector4(1, 1, 1, opts.alpha or 1))
	if opts.texture then
		local tex = opts.texture
		if string.sub(tex, 1, 3) == "px_" then tex = self:texture(tex) end
		if tex then
			gui.set_texture(n, tex)
			if opts.anim then gui.play_flipbook(n, opts.anim) end
		end
	end
	if opts.slice9 then
		local s = opts.slice9
		gui.set_slice9(n, vmath.vector4(s[1], s[2], s[3], s[4]))
	end
	if opts.id then gui.set_id(n, opts.id) end
	return n
end

-- Rounded rectangle (procedural texture, 9-sliced), tinted with color.
-- opts.radius (default 24). The radius shrinks to fit narrow boxes, with a
-- texture drawn for that radius, so a thin bar stays a clean pill.
function Scene:round(parent, x, y, w, h, color, opts)
	opts = opts or {}
	opts.color = color or opts.color or "white"
	local fit_r = math.floor(math.min(w, h) / 2) - 2
	local r = math.min(opts.radius or 24, fit_r)
	if r >= 24 then
		opts.texture = "px_round"
		opts.slice9 = { ROUND_SLICE, ROUND_SLICE, ROUND_SLICE, ROUND_SLICE }
	else
		r = math.max(1, r)
		opts.texture = "px_round_" .. r
		opts.slice9 = { r + 2, r + 2, r + 2, r + 2 }
	end
	return self:box(parent, x, y, w, h, opts)
end

function Scene:circle(parent, x, y, d, color, opts)
	opts = opts or {}
	opts.color = color or "white"
	opts.texture = opts.soft and "px_soft" or "px_disc"
	return self:box(parent, x, y, d, d, opts)
end

-- loose images ------------------------------------------------------------------------------------

local IMAGE_TYPES = nil
local function image_type(t)
	if not IMAGE_TYPES then
		IMAGE_TYPES = {}
		if image then
			if image.TYPE_RGB then IMAGE_TYPES[image.TYPE_RGB] = { "rgb", 3 } end
			if image.TYPE_RGBA then IMAGE_TYPES[image.TYPE_RGBA] = { "rgba", 4 } end
			if image.TYPE_LUMINANCE then IMAGE_TYPES[image.TYPE_LUMINANCE] = { "l", 1 } end
		end
	end
	return IMAGE_TYPES[t]
end

-- Texture id of a loose image (districts/*, backgrounds/*), loaded on first
-- use from the custom resources. nil when the file is missing or unreadable.
function Scene:loose_texture(key, e)
	local img = self.images[key]
	if img then return img.id, img end
	e = e or assets.image(key)
	if not e or not e.file then return nil end
	local ok, data = pcall(sys.load_resource, e.file)
	if not ok or not data then return nil end
	local ok2, im = pcall(image.load, data, { premultiply_alpha = true })
	if not ok2 or not im then
		print("WARNING: ui: cannot decode " .. e.file)
		return nil
	end
	local tt = image_type(im.type)
	if not tt then return nil end
	local id = "img:" .. key
	if not gui.new_texture(id, im.width, im.height, tt[1], im.buffer, false) then return nil end
	self.textures[id] = true
	img = { id = id, w = im.width, h = im.height }
	self.images[key] = img
	if not edge_cache[key] and tt[2] >= 3 then
		-- colours along the edges, for backdrop() (a few thousand pixels)
		local E = {}
		for _, side in ipairs({ "left", "right", "top", "bottom" }) do
			E[side] = gfx.edge_colors(im.buffer, im.width, im.height, tt[2], side, M.EDGE_BANDS, 3, true)
		end
		edge_cache[key] = E
	end
	return id, img
end

-- Deletes the textures of loose images not listed in keep ({[key] = true}):
-- e.g. the previous district when the town switches districts.
function Scene:release_images(keep)
	keep = keep or {}
	for key, img in pairs(self.images) do
		if not keep[key] then
			pcall(gui.delete_texture, img.id)
			self.textures[img.id] = nil
			self.images[key] = nil
			for _, side in ipairs({ "left", "right", "top", "bottom" }) do
				local ext = "ext:" .. key .. ":" .. side
				if self.textures[ext] then
					pcall(gui.delete_texture, ext)
					self.textures[ext] = nil
				end
			end
		end
	end
end

-- Image from assets/images by key ("ui/icons/coin"). opts: {w, h, scale, color,
-- alpha, pivot, slice9 = true (use the manifest's nine-slice)}. nil when the
-- image (or its atlas in this GUI) is missing.
function Scene:image(parent, key, x, y, opts)
	opts = opts or {}
	local e = assets.for_gui(key, self.gui_path) -- a copy in another atlas of this GUI
	if not e then return nil end
	local tex
	if e.file then
		tex = self:loose_texture(key, e)
		if not tex then return nil end
	end
	local s = opts.scale or 1
	local w, h = opts.w or e.w * s, opts.h or e.h * s
	local n = gui.new_box_node(v3(x, y), v3(w, h))
	gui.set_parent(n, parent or self.root)
	if opts.pivot then gui.set_pivot(n, opts.pivot) end
	if tex then
		gui.set_texture(n, tex)
	else
		local ok = pcall(gui.set_texture, n, e.atlas)
		if not ok then
			gui.delete_node(n)
			return nil
		end
		gui.play_flipbook(n, e.anim)
	end
	local c = opts.color
	if type(c) == "string" then c = M.color(c, opts.alpha) end
	gui.set_color(n, c or vmath.vector4(1, 1, 1, opts.alpha or 1))
	if opts.slice9 and e.slice9 then
		local sl = e.slice9
		gui.set_slice9(n, vmath.vector4(sl[1], sl[2], sl[3], sl[4]))
	end
	return n, e
end

-- backdrop: a background image that fills the window ------------------------------------------

local SIDES = { "left", "right", "top", "bottom" }

function Scene:_fit_backdrop(b)
	local f = self.fit
	local W, H = layout.W, layout.H
	local geom = {
		left = { x = 0, y = H / 2, w = -f.x0 + 1, h = H, pivot = gui.PIVOT_E },
		right = { x = W, y = H / 2, w = f.x1 - W + 1, h = H, pivot = gui.PIVOT_W },
		top = { x = W / 2, y = H, w = W, h = f.y1 - H + 1, pivot = gui.PIVOT_S },
		bottom = { x = W / 2, y = 0, w = W, h = -f.y0 + 1, pivot = gui.PIVOT_N },
	}
	for _, side in ipairs(SIDES) do
		local n, g = b.strips[side], geom[side]
		if n then
			local visible = g.w > 1.5 and g.h > 1.5
			gui.set_enabled(n, visible)
			if visible then
				gui.set_pivot(n, g.pivot)
				gui.set_position(n, v3(g.x, g.y))
				gui.set_size(n, v3(g.w, g.h))
			end
		end
	end
end

-- Draws a background image over the 720x1280 design area and continues it
-- past the design area on other aspect ratios: each edge's colours are
-- stretched outwards and fade into a light haze (no enlarged ghost copy of
-- the scene). Needs a loose image (the edges are read when it is decoded);
-- for atlas images only the design area is drawn and the sky shows around it.
-- Returns the image node or nil.
function Scene:backdrop(parent, key, opts)
	opts = opts or {}
	parent = parent or self.root
	local e = assets.image(key)
	if not e then return nil end
	if e.file then self:loose_texture(key, e) end -- decodes it and reads its edges
	local E = edge_cache[key]
	local b = { strips = {} }
	if E then
		-- strips first: the picture is drawn over their 1 px overlap
		local haze = gfx.hex(opts.haze or M.EDGE_HAZE)
		local amount = opts.haze_amount or M.EDGE_HAZE_AMOUNT
		for _, side in ipairs(SIDES) do
			local id = "ext:" .. key .. ":" .. side
			if not self.textures[id] then
				local buf, w, h = gfx.edge_fill(E[side], side, M.EDGE_STEPS, haze, amount)
				if gui.new_texture(id, w, h, "rgba", buf, false) then self.textures[id] = true end
			end
			if self.textures[id] then
				local st = gui.new_box_node(v3(0, 0), v3(1, 1))
				gui.set_parent(st, parent)
				gui.set_texture(st, id)
				gui.set_color(st, vmath.vector4(1, 1, 1, 1))
				b.strips[side] = st
			end
		end
	end
	local n = self:image(parent, key, layout.W / 2, layout.H / 2, { w = layout.W, h = layout.H, color = opts.color })
	if not n then
		for _, st in pairs(b.strips) do gui.delete_node(st) end
		return nil
	end
	b.image = n
	if E then
		self.backdrops[#self.backdrops + 1] = b
		self:_fit_backdrop(b)
	end
	return n
end

-- text ----------------------------------------------------------------------------------------

-- Text. opts: {font = "body"|"title"|"button"|"number"|"small", size (px),
-- color, outline (color or false), shadow (color or false), pivot, width
-- (line-break width in logical px), max_width (shrink to fit), alpha}.
-- Returns node, info (pass info to Scene:set_text).
function Scene:text(parent, str, x, y, opts)
	opts = opts or {}
	local font = opts.font or "body"
	local n = gui.new_text_node(v3(x, y), str or "")
	gui.set_parent(n, parent or self.root)
	if not pcall(gui.set_font, n, font) then
		font = M.FONT_FALLBACK
		pcall(gui.set_font, n, font)
	end
	local c = opts.color or "text"
	if type(c) == "string" then c = M.color(c, opts.alpha) end
	gui.set_color(n, c)
	local oc = opts.outline
	if type(oc) == "string" then oc = M.color(oc) end
	gui.set_outline(n, oc or vmath.vector4(0, 0, 0, 0))
	local sc = opts.shadow
	if type(sc) == "string" then sc = M.color(sc, 0.35) end
	gui.set_shadow(n, sc or vmath.vector4(0, 0, 0, 0))
	if opts.pivot then gui.set_pivot(n, opts.pivot) end
	local base = assets.font_size(font)
	local scale = (opts.size or base) / base
	if opts.width then
		gui.set_line_break(n, true)
		gui.set_size(n, v3(opts.width / scale, (opts.height or 400) / scale))
	end
	gui.set_scale(n, vmath.vector3(scale, scale, 1))
	local info = { scale = scale, max_width = opts.max_width, font = font }
	self:_fit_text(n, info)
	return n, info
end

-- Shrinks a text node so it is at most max_width logical px wide.
function Scene:_fit_text(n, info)
	if not info.max_width then return end
	local ok, m = pcall(function()
		return resource.get_text_metrics(gui.get_font_resource(gui.get_font(n)), gui.get_text(n))
	end)
	local width = ok and m and m.width or (#gui.get_text(n) * assets.font_size(info.font) * 0.55)
	local w = width * info.scale
	local s = info.scale
	if w > info.max_width and w > 0 then s = info.scale * info.max_width / w end
	gui.set_scale(n, vmath.vector3(s, s, 1))
end

-- Changes the text of a node made by Scene:text; pass the info it returned
-- to keep the shrink-to-fit behaviour.
function Scene:set_text(n, str, info)
	gui.set_text(n, str)
	if info and info.max_width then self:_fit_text(n, info) end
end

-- A node that always covers the visible window area. mode "stretch" | "cover"
-- (keep the aspect of w x h and crop).
function Scene:_cover(n, mode, w, h)
	local f = self.fit
	local vw, vh = f.x1 - f.x0, f.y1 - f.y0
	gui.set_position(n, v3((f.x0 + f.x1) / 2, (f.y0 + f.y1) / 2))
	if mode == "cover" then
		local k = math.max(vw / w, vh / h)
		gui.set_size(n, v3(w * k, h * k))
	else
		gui.set_size(n, v3(vw + 2, vh + 2))
	end
end

function Scene:cover(n, mode, w, h)
	self.covers[#self.covers + 1] = { node = n, mode = mode or "stretch", w = w or layout.W, h = h or layout.H }
	self:_cover(n, mode or "stretch", w or layout.W, h or layout.H)
	return n
end

-- Keeps node at the same distance from the top/bottom edge of the visible
-- area (minus the device safe-area insets).
function Scene:anchor(n, edge)
	local p = gui.get_position(n)
	local a = { node = n, edge = edge, base_y = p.y }
	self.anchored[#self.anchored + 1] = a
	local sr = self.safe
	p.y = a.base_y + (edge == "top" and (sr.y1 - layout.H) or sr.y0)
	gui.set_position(n, p)
	return n
end

-- Bright sky gradient over the whole window; soft clouds when clouds ~= false.
function Scene:sky(opts)
	opts = opts or {}
	local bg = self:box(opts.parent or self.root, 360, 640, 720, 1280, { texture = "px_sky" })
	self:cover(bg, "stretch")
	if opts.clouds ~= false then
		local puffs = {
			{ 110, 1130, 150 }, { 190, 1150, 110 }, { 60, 1120, 90 },
			{ 560, 1010, 170 }, { 650, 1030, 120 }, { 480, 995, 100 },
			{ 300, 860, 110 }, { 370, 870, 80 },
		}
		for _, p in ipairs(puffs) do
			self:circle(opts.parent or self.root, p[1], p[2], p[3], "white", { alpha = 0.55, soft = true })
		end
	end
	return bg
end

-- buttons -------------------------------------------------------------------------------------------

-- spec: {x, y, w, h, style = "green"|"blue"|"gold"|"pink"|"purple"|"white",
--        image = image key used as the whole button face (e.g. an icon),
--        text, font = "button", text_size, icon = image key, icon_size,
--        parent, on_click = fn(button), enabled = true, sfx = "button"}
-- Small buttons (smaller than the art's nine-slice borders) use a compact
-- round face (ui/button_small_<style> or a procedural one) instead.
-- Returns the button {node, label, icon, spec, enabled}.
function Scene:button(spec)
	local parent = spec.parent or self.root
	local w, h = spec.w or 300, spec.h or 110
	local style = spec.style or "green"
	local node
	if spec.image then
		node = self:image(parent, spec.image, spec.x, spec.y, { w = w, h = h })
	end
	local function atlas_ok(e)
		return e and not e.file and (not self.gui_path or assets.gui_has_texture(self.gui_path, e.atlas))
	end
	local atlas_key = "ui/button_" .. style
	local e = assets.image(atlas_key)
	local fits = e and (not e.slice9 or (e.slice9[1] + e.slice9[3] < w and e.slice9[2] + e.slice9[4] < h))
	if not node and atlas_ok(e) and fits then
		node = self:image(parent, atlas_key, spec.x, spec.y, { w = w, h = h, slice9 = true })
	end
	if not node and e and not fits then
		local small = assets.image("ui/button_small_" .. style)
		if atlas_ok(small) then node = self:image(parent, "ui/button_small_" .. style, spec.x, spec.y, { w = w, h = h }) end
	end
	if not node then
		local st = M.STYLES[style] and style or "green"
		if w < 64 or h < 64 then
			node = self:box(parent, spec.x, spec.y, w, h, { texture = "px_btn_s_" .. st })
		else
			node = self:box(parent, spec.x, spec.y, w, h, {
				texture = "px_btn_" .. st,
				slice9 = { 26, 26, 26, 30 },
			})
		end
	end
	local btn = { node = node, spec = spec, enabled = spec.enabled ~= false, style = style, base_scale = gui.get_scale(node) }
	local label_dx = 0
	if spec.icon then
		local isz = spec.icon_size or math.min(h * 0.62, 72)
		local ix = spec.text and (-w / 2 + isz / 2 + 22) or 0
		btn.icon = self:image(node, spec.icon, ix, 4, { w = isz, h = isz })
		if btn.icon and spec.text then label_dx = isz / 2 + 6 end
	end
	if spec.text then
		local st = M.STYLES[style] or M.STYLES.green
		local dark = style == "white"
		btn.label, btn.label_info = self:text(node, spec.text, label_dx, 6, {
			font = spec.font or "button",
			size = spec.text_size or math.min(46, h * 0.42),
			color = dark and "text" or "white",
			outline = dark and false or st[4],
			shadow = not dark and st[4] or false,
			max_width = math.max(10, w - (w >= 120 and 40 or 12) - (label_dx * 2)),
		})
	end
	self.buttons[#self.buttons + 1] = btn
	self:set_enabled(btn, btn.enabled)
	return btn
end

function Scene:set_enabled(btn, on)
	btn.enabled = on and true or false
	local a = btn.enabled and 1 or 0.55
	local c = gui.get_color(btn.node)
	c.w = a
	gui.set_color(btn.node, c)
end

function Scene:remove_button(btn)
	self:clear(btn.node)
end

local function visible(node)
	local n = node
	while n do
		if not gui.is_enabled(n) then return false end
		n = gui.get_parent(n)
	end
	return true
end

-- Only buttons inside `node` take taps (nil: every button). A popup sets it
-- to its own layer, so the screen under it cannot be tapped through.
function Scene:set_input_root(node)
	self.input_root = node
	if self.pressed and node and not within(self.pressed.node, node) then self.pressed = nil end
end

function Scene:hit(action)
	local root = self.input_root
	for i = #self.buttons, 1, -1 do
		local b = self.buttons[i]
		if b.enabled and visible(b.node) and (not root or within(b.node, root))
			and gui.pick_node(b.node, action.x, action.y) then
			return b
		end
	end
	return nil
end

-- Logical (720x1280, y up) coordinates of an input action.
function Scene:logical(action)
	return layout.screen_to_logical(self.fit, action.screen_x or action.x, action.screen_y or action.y)
end

-- Where a logical point anchored to an edge ("top" | "bottom") is now.
function Scene:anchored_y(y, edge)
	local sr = self.safe
	if edge == "top" then return y + (sr.y1 - layout.H) end
	if edge == "bottom" then return y + sr.y0 end
	return y
end

-- small animations ------------------------------------------------------------------------------------

local function start_pulse(node, p)
	gui.set_scale(node, p.base)
	local k = 1 + p.amount
	gui.animate(node, "scale", vmath.vector3(p.base.x * k, p.base.y * k, 1), gui.EASING_INOUTSINE, p.period, 0, nil,
		gui.PLAYBACK_LOOP_PINGPONG)
end

-- Press feedback. A pulsing button gets its pulse back after the release.
local function press_anim(btn, down)
	local node = btn.node
	local p = pulses[node]
	local base = p and p.base or btn.base_scale or vmath.vector3(1, 1, 1)
	gui.cancel_animations(node, "scale")
	if down then
		gui.animate(node, "scale", vmath.vector3(base.x * 0.93, base.y * 0.93, 1), gui.EASING_OUTQUAD, 0.06)
	else
		gui.animate(node, "scale", vmath.vector3(base.x, base.y, 1), gui.EASING_OUTQUAD, 0.12, 0, function()
			local again = pulses[node]
			if again then start_pulse(node, again) end
		end)
	end
end

-- Handles taps on buttons. Returns true when the input was used. A press
-- and a release in the same frame (a very quick tap) count as a click.
function Scene:on_input(action_id, action)
	if action_id ~= TOUCH then return false end
	local used = false
	if action.pressed then
		local b = self:hit(action)
		if b then
			self.pressed = b
			press_anim(b, true)
			used = true
		end
	end
	if action.released then
		local b = self.pressed
		self.pressed = nil
		if b then
			press_anim(b, false)
			if self:hit(action) == b and b.spec.on_click then
				if b.spec.sfx ~= false then
					local ok, audio = pcall(require, "client.audio")
					if ok then audio.sfx(b.spec.sfx or "button") end
				end
				b.spec.on_click(b)
			end
			used = true
		end
	elseif not action.pressed and self.pressed then
		used = true
	end
	return used
end

function M.pop_in(node, delay, from)
	local s = gui.get_scale(node)
	gui.set_scale(node, s * (from or 0.6))
	gui.animate(node, "scale", s, gui.EASING_OUTBACK, 0.35, delay or 0)
end

-- A slow breathing scale (a button that wants a tap). It survives presses:
-- the press animation hands the scale back to the pulse on release.
function M.pulse(node, amount, period)
	local p = { amount = amount or 0.05, period = period or 0.8, base = gui.get_scale(node) }
	pulses[node] = p
	start_pulse(node, p)
end

function M.stop_pulse(node, scale)
	local p = pulses[node]
	pulses[node] = nil
	gui.cancel_animations(node, "scale")
	gui.set_scale(node, scale or (p and p.base) or vmath.vector3(1, 1, 1))
end

function M.is_pulsing(node)
	return pulses[node] ~= nil
end

return M
