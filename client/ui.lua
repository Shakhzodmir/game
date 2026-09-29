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
--       self.ui = ui.scene()                         -- root + procedural textures
--       self.ui:sky()                                -- gradient covering the window
--       local t = self.ui:text(nil, "Hello", 360, 900, {font = "title", size = 64})
--       self.ui:button({x = 360, y = 200, w = 440, h = 120, style = "green",
--                       text = "Play", on_click = function() ... end})
--   end
--   function update(self, dt) self.ui:update(dt) end
--   function on_input(self, action_id, action) return self.ui:on_input(action_id, action) end
--   function final(self) self.ui:final() end
--
-- Images come from the generated atlases through client/assets.lua; when an
-- image is missing the kit draws a tinted procedural shape instead.

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

local TOUCH = hash("touch")

local cache = {} -- pixel buffers, computed once per app (shared Lua state)

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

local TEXTURES = {
	px_sky = { 4, 256, function() return gfx.vertical_gradient(4, 256, SKY_STOPS) end },
	px_round = { 64, 64, function() return gfx.round_rect(64, 64, 24) end },
	px_disc = { 64, 64, function() return gfx.disc(64, 1.5) end },
	px_soft = { 64, 64, function() return gfx.disc(64, 24) end },
}
local ROUND_SLICE = 26

local function button_texture_spec(style)
	local s = M.STYLES[style] or M.STYLES.green
	return 64, 80, function()
		return gfx.round_rect(64, 80, 24, {
			top = gfx.hex(s[1]), bottom = gfx.hex(s[2]), shelf = gfx.hex(s[3]), shelf_h = 10, gloss = 0.35,
		})
	end
end

-- Scene -------------------------------------------------------------------------------------

local Scene = {}
Scene.__index = Scene

-- opts: {gui = "/screens/town/town.gui" (to check texture availability)}
function M.scene(opts)
	opts = opts or {}
	local self = setmetatable({
		gui_path = opts.gui,
		textures = {},
		buttons = {},
		covers = {},     -- nodes that must cover the whole visible area
		anchored = {},   -- {node, edge, base_y}
		pressed = nil,
		on_resize = opts.on_resize,
	}, Scene)
	self.root = gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(0, 0, 0))
	gui.set_id(self.root, "ui_root")
	gui.set_pivot(self.root, gui.PIVOT_SW)
	self:refit(true)
	return self
end

function Scene:texture(id)
	if self.textures[id] then return id end
	local spec = TEXTURES[id]
	local w, h, fn
	if spec then
		w, h, fn = spec[1], spec[2], spec[3]
	elseif string.sub(id, 1, 7) == "px_btn_" then
		w, h, fn = button_texture_spec(string.sub(id, 8))
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
	self.safe = layout.safe_rect(f, ok and type(sa) == "table" and sa or nil)
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
	if self.on_resize then self.on_resize(f) end
	return true
end

function Scene:update(dt)
	self:refit(false)
end

function Scene:final()
	for id in pairs(self.textures) do
		pcall(gui.delete_texture, id)
	end
	self.textures = {}
end

-- node helpers ------------------------------------------------------------------------------------

local function v3(x, y) return vmath.vector3(x or 0, y or 0, 0) end

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
function Scene:round(parent, x, y, w, h, color, opts)
	opts = opts or {}
	opts.color = color or opts.color or "white"
	opts.texture = "px_round"
	local r = opts.radius or ROUND_SLICE
	opts.slice9 = { r, r, r, r }
	return self:box(parent, x, y, w, h, opts)
end

function Scene:circle(parent, x, y, d, color, opts)
	opts = opts or {}
	opts.color = color or "white"
	opts.texture = opts.soft and "px_soft" or "px_disc"
	return self:box(parent, x, y, d, d, opts)
end

-- Image from assets/images by key ("ui/icons/coin"). opts: {w, h, scale, color,
-- alpha, pivot, slice9 = true (use the manifest's nine-slice)}. nil when the
-- image (or its atlas in this GUI) is missing.
function Scene:image(parent, key, x, y, opts)
	opts = opts or {}
	local e = assets.image(key)
	if not e then return nil end
	if self.gui_path and not assets.gui_has_texture(self.gui_path, e.atlas) then return nil end
	local s = opts.scale or 1
	local w, h = opts.w or e.w * s, opts.h or e.h * s
	local n = gui.new_box_node(v3(x, y), v3(w, h))
	gui.set_parent(n, parent or self.root)
	if opts.pivot then gui.set_pivot(n, opts.pivot) end
	local ok = pcall(gui.set_texture, n, e.atlas)
	if not ok then
		gui.delete_node(n)
		return nil
	end
	gui.play_flipbook(n, e.anim)
	local c = opts.color
	if type(c) == "string" then c = M.color(c, opts.alpha) end
	gui.set_color(n, c or vmath.vector4(1, 1, 1, opts.alpha or 1))
	if opts.slice9 and e.slice9 then
		local sl = e.slice9
		gui.set_slice9(n, vmath.vector4(sl[1], sl[2], sl[3], sl[4]))
	end
	return n, e
end

-- Text. opts: {font = "body"|"title"|"button"|"number"|"small", size (px),
-- color, outline (color or false), shadow (color or false), pivot, width
-- (line-break width in logical px), max_width (shrink to fit), alpha}.
-- Returns node, info (pass info to Scene:set_text).
function Scene:text(parent, str, x, y, opts)
	opts = opts or {}
	local font = opts.font or "body"
	local n = gui.new_text_node(v3(x, y), str or "")
	gui.set_parent(n, parent or self.root)
	gui.set_font(n, font)
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
	local bg = self:box(self.root, 360, 640, 720, 1280, { texture = "px_sky" })
	self:cover(bg, "stretch")
	if opts.clouds ~= false then
		local puffs = {
			{ 110, 1130, 150 }, { 190, 1150, 110 }, { 60, 1120, 90 },
			{ 560, 1010, 170 }, { 650, 1030, 120 }, { 480, 995, 100 },
			{ 300, 860, 110 }, { 370, 870, 80 },
		}
		for _, p in ipairs(puffs) do
			self:circle(self.root, p[1], p[2], p[3], "white", { alpha = 0.55, soft = true })
		end
	end
	return bg
end

-- buttons -------------------------------------------------------------------------------------------

-- spec: {x, y, w, h, style = "green"|"blue"|"gold"|"pink"|"purple"|"white",
--        image = image key used as the whole button face (e.g. an icon),
--        text, font = "button", text_size, icon = image key, icon_size,
--        parent, on_click = fn(button), enabled = true, sfx = "button"}
-- Returns the button {node, label, icon, spec, enabled}.
function Scene:button(spec)
	local parent = spec.parent or self.root
	local w, h = spec.w or 300, spec.h or 110
	local style = spec.style or "green"
	local node
	if spec.image then
		node = self:image(parent, spec.image, spec.x, spec.y, { w = w, h = h })
	end
	local atlas_key = "ui/button_" .. style
	local e = assets.image(atlas_key)
	if not node and e and (not self.gui_path or assets.gui_has_texture(self.gui_path, e.atlas)) then
		node = self:image(parent, atlas_key, spec.x, spec.y, { w = w, h = h, slice9 = true })
	end
	if not node then
		node = self:box(parent, spec.x, spec.y, w, h, {
			texture = "px_btn_" .. (M.STYLES[style] and style or "green"),
			slice9 = { 26, 26, 26, 30 },
		})
	end
	local btn = { node = node, spec = spec, enabled = spec.enabled ~= false, style = style }
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
		btn.label = self:text(node, spec.text, label_dx, 6, {
			font = spec.font or "button",
			size = spec.text_size or math.min(46, h * 0.42),
			color = dark and "text" or "white",
			outline = dark and false or st[4],
			shadow = not dark and st[4] or false,
			max_width = w - 40 - (label_dx * 2),
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
	for i = #self.buttons, 1, -1 do
		if self.buttons[i] == btn then table.remove(self.buttons, i) end
	end
	gui.delete_node(btn.node)
end

local function visible(node)
	local n = node
	while n do
		if not gui.is_enabled(n) then return false end
		n = gui.get_parent(n)
	end
	return true
end

function Scene:hit(action)
	for i = #self.buttons, 1, -1 do
		local b = self.buttons[i]
		if b.enabled and visible(b.node) and gui.pick_node(b.node, action.x, action.y) then return b end
	end
	return nil
end

local function press_anim(node, down)
	local s = down and 0.93 or 1.0
	gui.animate(node, "scale", vmath.vector3(s, s, 1), gui.EASING_OUTQUAD, down and 0.06 or 0.12)
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
			press_anim(b.node, true)
			used = true
		end
	end
	if action.released then
		local b = self.pressed
		self.pressed = nil
		if b then
			press_anim(b.node, false)
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

-- small animations ------------------------------------------------------------------------------------

function M.pop_in(node, delay, from)
	local s = gui.get_scale(node)
	gui.set_scale(node, s * (from or 0.6))
	gui.animate(node, "scale", s, gui.EASING_OUTBACK, 0.35, delay or 0)
end

function M.pulse(node, amount, period)
	local s = gui.get_scale(node)
	local k = 1 + (amount or 0.05)
	gui.animate(node, "scale", vmath.vector3(s.x * k, s.y * k, 1), gui.EASING_INOUTSINE, period or 0.8, 0, nil,
		gui.PLAYBACK_LOOP_PINGPONG)
end

function M.stop_pulse(node, scale)
	gui.cancel_animations(node, "scale")
	gui.set_scale(node, scale or vmath.vector3(1, 1, 1))
end

return M
