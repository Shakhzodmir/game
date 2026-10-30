-- Widgets shared by the level windows (gui/pause.lua, gui/moves.lua, gui/defeat.lua,
-- gui/result.lua, gui/booster_buy.lua), on top of gui/kit.lua. Coordinates are relative to
-- the parent node, like in the kit.

local i18n = require("client.i18n")
local ui = require("client.ui")
local kit = require("gui.kit")

local M = {}

-- A line of what a window says: a lavender rounded row with an icon and a text.
-- spec = {text = string | i18n spec, icon = image key, fallback = disc colour, color = text colour,
--         fill = row colour, h = 56, size = 26, wrap = false}. Returns the row node and the text node.
-- A long text is wrapped into the row (wrap = true, give it a taller h) instead of being shrunk to a line.
function M.note(e, parent, x, y, w, spec)
	local s = e.ui
	local h = spec.h or 56
	local row = s:round(parent, x, y, w, h, spec.fill or "#F4EEFF", { radius = math.floor(h / 2) })
	local label, info
	if spec.icon then
		kit.icon(e, row, spec.icon, -w / 2 + h / 2 + 6, 0, h - 14, spec.fallback or "lavender")
		if spec.wrap then
			label, info = s:text(row, i18n.tr(spec.text), h / 2 - 2, 1, {
				font = "button", size = spec.size or 26, color = spec.color or "text", width = w - h - 36, height = h - 12,
			})
		else
			label, info = s:text(row, i18n.tr(spec.text), h / 2 - 2, 1, {
				font = "button", size = spec.size or 26, color = spec.color or "text", max_width = w - h - 36,
			})
		end
	else
		label, info = s:text(row, i18n.tr(spec.text), 0, 1, {
			font = "button", size = spec.size or 26, color = spec.color or "text", max_width = w - 40,
		})
	end
	return row, label, info
end

-- Several lines, one under another, centred on y; returns the height they take.
-- lines = list of note specs.
function M.notes(e, parent, x, y, w, lines, gap)
	gap = gap or 8
	local total = 0
	for i, spec in ipairs(lines) do total = total + (spec.h or 56) + (i > 1 and gap or 0) end
	local top = y + total / 2
	for _, spec in ipairs(lines) do
		local h = spec.h or 56
		M.note(e, parent, x, top - h / 2, w, spec)
		top = top - h - gap
	end
	return total
end

-- The row of stars of a result: `earned` of `total`, the middle one a little bigger.
-- Returns the star nodes.
function M.stars(e, parent, x, y, earned, total, size)
	local out = {}
	for i = 1, total do
		local mid = total == 3 and i == 2
		local on = i <= earned
		-- the art of an empty star has more air around it: draw it a little smaller than a full one
		local sz = size * (mid and 1.2 or 1) * (on and 1.1 or 0.92)
		local sx = x + (i - (total + 1) / 2) * size * 1.08
		local sy = y + (mid and size * 0.14 or 0)
		out[i] = kit.icon(e, parent, on and "ui/icons/star" or "ui/icons/star_empty", sx, sy, sz, "yellow")
	end
	return out
end

-- A small round tile with a booster icon and its count (or a free mark). Returns the button.
-- spec = {id, count (nil: free), x, y, size, on_click}
function M.booster_tile(e, parent, spec)
	local s = e.ui
	local size = spec.size or 112
	local btn = s:button({ parent = parent, x = spec.x, y = spec.y, w = size, h = size - 8, style = spec.style or "white",
		icon = require("client.views").booster_icon(spec.id), icon_size = size - 36, sfx = "booster", on_click = spec.on_click })
	if spec.count ~= nil then
		local badge = s:image(btn.node, "ui/badge_count", size / 2 - 14, size / 2 - 18, { w = 44, h = 44 })
			or s:circle(btn.node, size / 2 - 14, size / 2 - 18, 44, "green")
		s:text(badge, tostring(spec.count), 0, 1, { font = "number", size = 26, color = "white", outline = "#0F7A3B", max_width = 38 })
	end
	return btn
end

-- The width of a text node on the screen, in logical px (the font's own metrics, the node's scale;
-- `fallback` when the engine cannot say), to put something right after a text.
function M.width(node, fallback)
	local ok, w = pcall(function()
		local m = resource.get_text_metrics(gui.get_font_resource(gui.get_font(node)), gui.get_text(node))
		return m and m.width and m.width * gui.get_scale(node).x or nil
	end)
	if ok and w then return w end
	return fallback or 100
end

-- A token that tells whether a callback scheduled by a build still belongs to the window as it
-- is drawn now (a rebuild or the closing of the window makes it stale).
--   local alive = M.token(e)
--   e.fx:after(1, function() if alive() then ... end end)
function M.token(e)
	local gen = (e.state.gen or 0) + 1
	e.state.gen = gen
	return function() return not e.closing and e.state.gen == gen end
end

-- Dims a button together with what is drawn on it. A node made by script takes no alpha from its parent in the
-- engine (gui.set_inherit_alpha is off), so a dimmed face alone would leave its label and price at full
-- strength: `parts` are the nodes drawn on the face (a label, a price pill and the pill's icon and number...),
-- each one is told to follow its parent, and the face carries the alpha.
function M.dim(btn, alpha, parts)
	for _, n in ipairs(parts) do gui.set_inherit_alpha(n, true) end
	gui.set_color(btn.node, vmath.vector4(1, 1, 1, alpha))
end

-- Pulses a button that wants a tap (not under reduced motion).
function M.pulse(node, amount, period)
	if not kit.reduced() then ui.pulse(node, amount or 0.035, period or 0.8) end
end

return M
