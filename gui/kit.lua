-- Widgets shared by the meta windows (gui/*.lua, hosted by client/popups.lua):
-- the white panel with a ribbon title and a close button, price buttons,
-- a coin pill, badges, count bubbles, locks, streak notes, goal tiles,
-- toggles, segmented choices and sliders.
-- Coordinates are relative to the parent node (the window content has
-- 0, 0 at the centre of the screen). Touch targets are at least 88 px.

local ui = require("client.ui")
local i18n = require("client.i18n")
local app = require("client.app")
local audio = require("client.audio")
local views = require("client.views")
local assets = require("client.assets")
local bit = require("client.bit")

local M = {}

M.TOUCH = hash("touch")
M.CX, M.CY = 360, 640

function M.reduced()
	return app.reduced_motion()
end

-- Logical (absolute) position of a point given in window-centre coordinates.
function M.abs(x, y)
	return M.CX + x, M.CY + y
end

-- An image, or a soft disc of `fallback` colour when the image is missing.
function M.icon(e, parent, key, x, y, size, fallback)
	local s = e.ui
	local n = key and s:image(parent, key, x, y, { w = size, h = size }) or nil
	if not n then n = s:circle(parent, x, y, size * 0.8, fallback or "lavender") end
	return n
end

function M.booster_icon(e, parent, id, x, y, size)
	return M.icon(e, parent, views.booster_icon(id), x, y, size, "purple")
end

-- The standard window: white rounded panel with a pastel outline and a
-- soft shadow, a purple ribbon with the title, a close button.
-- opts = {y = 0, title = text, close = true, border, ribbon_w}. Returns the
-- body node (children relative to its centre) and its half height.
function M.panel(e, w, h, opts)
	opts = opts or {}
	local s = e.ui
	local y = opts.y or 0
	s:round(e.content, 0, y - 16, w + 8, h + 8, "#5A3FA0", { alpha = 0.22 })
	local border = s:round(e.content, 0, y, w, h, opts.border or "#E3D9FF")
	local body = s:round(border, 0, 0, w - 12, h - 12, "white")
	e.panel_w, e.panel_h = w, h
	if opts.title then
		local rw = math.min(w + 40, opts.ribbon_w or 480)
		local ribbon = s:image(body, "ui/ribbon", 0, h / 2 - 2, { w = rw, h = 104, slice9 = true })
			or s:round(body, 0, h / 2 - 2, rw - 60, 86, "purple")
		s:text(ribbon, i18n.tr(opts.title), 0, 8, {
			font = "button", size = 42, color = "white", outline = "#5220A6", shadow = "#5220A6", max_width = rw - 200,
		})
		e.ribbon = ribbon
	end
	if opts.close ~= false then
		local cx, cy = w / 2 - 40, h / 2 - 40
		local b = s:button({ parent = body, x = cx, y = cy, w = 92, h = 92, style = "pink", icon = "ui/icons/close",
			icon_size = 50, text = not assets.has_image("ui/icons/close") and "X" or nil,
			on_click = function() e:close("close") end })
		e:target("close", cx, y + cy)
		e.close_btn = b
	end
	return body, h / 2
end

-- A section caption with thin lines on both sides.
function M.section(e, parent, text, x, y, w)
	local s = e.ui
	w = w or 540
	local t, info = s:text(parent, text, x, y, { font = "button", size = 28, color = "purple", max_width = w - 160 })
	local ok, m = pcall(function()
		return resource.get_text_metrics(gui.get_font_resource(gui.get_font(t)), gui.get_text(t))
	end)
	local tw = (ok and m and m.width or 200) * gui.get_scale(t).x
	local line_w = math.max(20, (w - tw) / 2 - 22)
	s:round(parent, x - tw / 2 - 16 - line_w / 2, y, line_w, 6, "#E3D9FF", { radius = 3 })
	s:round(parent, x + tw / 2 + 16 + line_w / 2, y, line_w, 6, "#E3D9FF", { radius = 3 })
	return t, info
end

-- A pill with the coin balance. Returns {node, label, info, icon};
-- M.set_coins updates it.
function M.coins_pill(e, parent, x, y, value)
	local s = e.ui
	local pill = s:round(parent, x, y, 220, 76, "#FFF6D6", { radius = 36 })
	local ic = M.icon(e, pill, "ui/icons/coin", -74, 2, 64, "coin")
	local label, info = s:text(pill, i18n.number(value or app.meta:coins()), -34, 2, {
		font = "number", size = 36, color = "text", pivot = gui.PIVOT_W, max_width = 136,
	})
	return { node = pill, label = label, info = info, icon = ic, x = x, y = y }
end

function M.set_coins(e, pill, value)
	if pill and pill.label then e.ui:set_text(pill.label, i18n.number(value), pill.info) end
end

-- A gold purchase button: coin icon + price. spec = {parent, x, y, w, h,
-- price, text (instead of the price), on_click, enabled, icon, style}
function M.price_button(e, spec)
	local s = e.ui
	local b = s:button({
		parent = spec.parent, x = spec.x, y = spec.y, w = spec.w or 220, h = spec.h or 92, style = spec.style or "gold",
		icon = spec.icon == nil and "ui/icons/coin" or spec.icon or nil, icon_size = spec.icon_size or 54,
		text = spec.text or i18n.number(spec.price or 0), text_size = spec.text_size or 36,
		enabled = spec.enabled, on_click = spec.on_click, sfx = spec.sfx,
	})
	return b
end

-- A small rounded label.
function M.badge(e, parent, x, y, text, color, opts)
	opts = opts or {}
	local s = e.ui
	local w = opts.w or 110
	local h = opts.h or 38
	local n = s:round(parent, x, y, w, h, color or "pink", { radius = math.floor(h / 2) })
	s:text(n, text, 0, 1, { font = opts.font or "button", size = opts.size or 22, color = "white",
		outline = opts.outline or false, max_width = w - 12 })
	return n
end

-- A round count bubble (a booster stock): pink with a white rim.
function M.count_bubble(e, parent, x, y, n, color)
	local s = e.ui
	local rim = s:circle(parent, x, y, 52, "white")
	local c = s:circle(rim, 0, 0, 44, color or "pink")
	s:text(c, tostring(n), 0, 1, { font = "number", size = 26, color = "white", max_width = 40 })
	return rim
end

-- A padlock (the icon, or a drawn one).
function M.lock(e, parent, x, y, size)
	local s = e.ui
	local n = s:image(parent, "ui/icons/lock", x, y, { w = size, h = size })
	if n then return n end
	local body = s:round(parent, x, y - size * 0.12, size * 0.72, size * 0.56, "text_soft", { radius = 8 })
	s:circle(parent, x, y + size * 0.18, size * 0.5, "text_soft")
	return body
end

-- The three hit-streak notes. notes = {{lit}}; returns the nodes.
function M.notes(e, parent, x, y, notes, size, gap)
	local s = e.ui
	size, gap = size or 48, gap or 50
	local out = {}
	local n = #notes
	for i, note in ipairs(notes) do
		local nx = x + (i - (n + 1) / 2) * gap
		local node = s:image(parent, note.lit and "ui/icons/note_on" or "ui/icons/note_off", nx, y, { w = size, h = size })
			or s:circle(parent, nx, y, size * 0.7, note.lit and "yellow" or "lavender")
		if not note.lit then gui.set_color(node, vmath.vector4(1, 1, 1, 0.7)) end
		out[i] = node
	end
	return out
end

-- A goal tile of the start window: the icon on a lavender tile with the
-- count below. goal = client/levels.lua goals() entry.
function M.goal(e, parent, goal, x, y, size)
	local s = e.ui
	size = size or 120
	local tile = s:round(parent, x, y, size, size, "#F4EEFF", { radius = 28 })
	s:round(tile, 0, 0, size - 8, size - 8, "white", { radius = 24, alpha = 0.7 })
	M.icon(e, tile, goal.image, 0, 6, size * 0.72, goal.color or "lavender")
	if goal.count then
		local pill = s:round(tile, 0, -size / 2 + 4, 84, 40, "purple", { radius = 20 })
		s:text(pill, tostring(goal.count), 0, 1, { font = "number", size = 26, color = "white", max_width = 76 })
	else
		local pill = s:round(tile, 0, -size / 2 + 4, 84, 40, "purple", { radius = 20 })
		s:text(pill, i18n.t("start.all"), 0, 1, { font = "button", size = 20, color = "white", max_width = 76 })
	end
	return tile
end

-- A caption in the window's soft text colour.
function M.caption(e, parent, text, x, y, opts)
	opts = opts or {}
	return e.ui:text(parent, text, x, y, {
		font = opts.font or "button", size = opts.size or 30, color = opts.color or "text_soft",
		pivot = opts.pivot, max_width = opts.max_width or 560, width = opts.width,
	})
end

-- An on/off switch. on_change(new_value). Touch area 150 x 92.
function M.toggle(e, parent, x, y, on, on_change, target)
	local s = e.ui
	local track = s:round(parent, x, y, 118, 62, on and "green" or "#D9D0EE", { radius = 30 })
	local knob = s:circle(track, on and 28 or -28, 0, 52, "white")
	local hit = s:button({ parent = parent, x = x, y = y, w = 150, h = 92, style = "white", sfx = "tap",
		on_click = function()
			on = not on
			gui.set_color(track, ui.color(on and "green" or "#D9D0EE"))
			if M.reduced() then
				gui.set_position(knob, vmath.vector3(on and 28 or -28, 0, 0))
			else
				gui.animate(knob, "position.x", on and 28 or -28, gui.EASING_OUTBACK, 0.2)
			end
			on_change(on)
		end })
	gui.set_color(hit.node, vmath.vector4(1, 1, 1, 0))
	if target then e:target(target, (e.ox or 0) + x, (e.oy or 0) + y) end
	return track
end

-- A row of choices; the selected one is purple. options = {{id, text}}.
function M.segmented(e, parent, x, y, w, options, selected, on_select, opts)
	opts = opts or {}
	local s = e.ui
	local h = opts.h or 88
	s:round(parent, x, y, w, h + 12, "#EFE8FF", { radius = 30 })
	local n = #options
	local bw = (w - 12) / n
	local buttons = {}
	for i, o in ipairs(options) do
		local bx = x - w / 2 + 6 + bw * (i - 0.5)
		local on = o.id == selected
		buttons[i] = s:button({ parent = parent, x = bx, y = y, w = bw - 6, h = h, style = on and "purple" or "white",
			text = o.text, text_size = opts.text_size or 28, sfx = "tap",
			on_click = function() if o.id ~= selected then on_select(o.id) end end })
		if opts.targets then e:target(opts.targets .. "_" .. o.id, (opts.ox or 0) + bx, (opts.oy or 0) + y) end
	end
	return buttons
end

-- A horizontal slider 0..1. The window's on_input must call
-- M.slider_input(e, action_id, action) first. opts.ax, opts.ay: the
-- absolute logical centre of the track (for dragging).
-- on_change(v) while dragging, on_commit(v) on release.
function M.slider(e, parent, x, y, w, value, on_change, on_commit, opts)
	opts = opts or {}
	local s = e.ui
	local track = s:round(parent, x, y, w, 22, "#E3D9FF", { radius = 10 })
	local fill = s:round(parent, x - w / 2, y, math.max(22, w * value), 22, opts.color or "pink", { radius = 10, pivot = gui.PIVOT_W })
	local shade = s:circle(parent, x - w / 2 + w * value, y - 5, 66, "#5A3FA0", { soft = true, alpha = 0.25 })
	local knob = s:circle(parent, x - w / 2 + w * value, y, 60, "white")
	s:circle(knob, 0, 0, 28, opts.color or "pink")
	local hit = s:box(parent, x, y, w + 80, 100, { alpha = 0 })
	local sl = {
		track = track, fill = fill, knob = knob, shade = shade, hit = hit, x = x, y = y, w = w, value = value,
		ax = opts.ax or (M.CX + x), on_change = on_change, on_commit = on_commit,
	}
	e.sliders = e.sliders or {}
	e.sliders[#e.sliders + 1] = sl
	if opts.target then e:target(opts.target, (opts.ax or M.CX + x) - M.CX, (opts.ay or M.CY + y) - M.CY) end
	return sl
end

local function slider_set(sl, v)
	v = math.max(0, math.min(1, v))
	sl.value = v
	local kx = sl.x - sl.w / 2 + sl.w * v
	gui.set_position(sl.knob, vmath.vector3(kx, sl.y, 0))
	gui.set_position(sl.shade, vmath.vector3(kx, sl.y - 5, 0))
	gui.set_size(sl.fill, vmath.vector3(math.max(22, sl.w * v), 22, 0))
end

function M.slider_input(e, action_id, action)
	if action_id ~= M.TOUCH then return false end
	local drag = e.dragging
	if action.pressed then
		for _, sl in ipairs(e.sliders or {}) do
			if gui.pick_node(sl.hit, action.x, action.y) then
				e.dragging = sl
				drag = sl
				gui.animate(sl.knob, "scale", vmath.vector3(1.15, 1.15, 1), gui.EASING_OUTBACK, 0.15)
				break
			end
		end
		if not drag then return false end
	end
	if not drag then return false end
	local lx = e.ui:logical(action)
	local v = (lx - (drag.ax - drag.w / 2)) / drag.w
	slider_set(drag, v)
	if drag.on_change then drag.on_change(drag.value) end
	if action.released then
		e.dragging = nil
		gui.animate(drag.knob, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTQUAD, 0.12)
		if drag.on_commit then drag.on_commit(drag.value) end
	end
	return true
end

-- Bit inside a window (updated by the window's update through M.update_bit).
function M.bit(e, parent, x, y, size, mood)
	local b = bit.new(e.ui, parent, x, y, size, { mood = mood })
	e.bit = b
	return b
end

function M.update_bit(e, dt)
	if e.bit then e.bit:update(dt) end
end

-- A row of hearts: `count` full out of `max`.
function M.hearts(e, parent, x, y, count, max, size)
	local s = e.ui
	size = size or 64
	local gap = size + 10
	local nodes = {}
	for i = 1, max do
		local hx = x + (i - (max + 1) / 2) * gap
		local n = M.icon(e, parent, "ui/icons/heart", hx, y, size, "pink")
		if i > count then gui.set_color(n, vmath.vector4(0.62, 0.56, 0.78, 0.35)) end
		nodes[i] = n
	end
	return nodes
end

-- A soft glow disc behind something (breathing unless reduced motion).
function M.glow(e, parent, x, y, size, color, alpha)
	local g = e.ui:circle(parent, x, y, size, color or "glow", { soft = true, alpha = alpha or 0.8 })
	if not M.reduced() then ui.pulse(g, 0.08, 1.1) end
	return g
end

-- A gentle squash-and-bounce loop (a chest or a gift waiting for a tap).
function M.wiggle(node, amount, period)
	if M.reduced() then return end
	local s = gui.get_scale(node)
	gui.animate(node, "scale", vmath.vector3(s.x * (1 + (amount or 0.06)), s.y * (1 - (amount or 0.06) * 0.6), 1),
		gui.EASING_INOUTSINE, (period or 0.9) / 2, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
end

-- A node pops in from nothing (under reduced motion: at once).
function M.pop_in(node, delay, dur)
	local s = gui.get_scale(node)
	if M.reduced() then return end
	gui.set_scale(node, s * 0.01)
	gui.animate(node, "scale", s, gui.EASING_OUTBACK, dur or 0.35, delay or 0)
end

-- Fades a node (and, for images and text, nothing else) in from 0.
function M.fade_in(node, delay, dur)
	local c = gui.get_color(node)
	local a = c.w
	c.w = 0
	gui.set_color(node, c)
	gui.animate(node, "color.w", a, gui.EASING_OUTQUAD, dur or 0.3, delay or 0)
end

-- Plays a sound effect.
function M.sfx(name, opts)
	audio.sfx(name, opts)
end

return M
