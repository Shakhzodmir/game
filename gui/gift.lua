-- Unlock gift: a new booster is open and its first pieces are free (the
-- meta paid them with the win). A wrapped gift bounces and waits for a
-- tap; it shakes, bursts in a flash and the booster pops out with its name,
-- what it does and how many the player got. "Collect" closes it; the town
-- flies the booster to the level button.
-- params = {id = booster id}
-- Result: {action = "collect", id, x, y} (x, y logical).

local i18n = require("client.i18n")
local views = require("client.views")
local ui = require("client.ui")
local fx = require("client.fx")
local config = require("meta.config")
local kit = require("gui.kit")

local M = {}

M.dim_alpha = 0.75
M.no_back = true

local BOX_Y = 90

local function collect(e)
	if e.state.phase ~= "open" then return end
	e.state.phase = "done"
	kit.sfx("button")
	local x, y = kit.abs(0, BOX_Y)
	e:close({ action = "collect", id = e.params.id, x = x, y = y })
end

local function open_gift(e)
	local st = e.state
	if st.phase ~= "closed" then return end
	st.phase = "opening"
	kit.sfx("tap")
	local box = e.box
	local function burst_open()
		if e.closing then return end
		st.phase = "open"
		kit.sfx("unlock")
		fx.buzz(40)
		local x, y = kit.abs(0, BOX_Y)
		e.fx:flash(x, y, { size = 620, dur = 0.5 })
		e.fx:ring(x, y, { size = 200, scale = 4, color = "#C9A7FF" })
		e.fx:burst(x, y, { count = 22, radius = 260, size = 40, colors = { "#FFFFFF", "#E3D0FF", "#C18CFF", "#FFD84D" } })
		e:rebuild()
	end
	if kit.reduced() then
		burst_open()
		return
	end
	gui.cancel_animations(box, "scale")
	local k = 0
	local function wobble()
		k = k + 1
		if k > 5 then
			gui.animate(box, "scale", vmath.vector3(0.01, 0.01, 1), gui.EASING_INBACK, 0.18, 0, burst_open)
			return
		end
		gui.animate(box, "euler.z", (k % 2 == 0 and 1 or -1) * (5 + k * 2), gui.EASING_INOUTSINE, 0.07, 0, wobble)
	end
	wobble()
end

function M.build(e)
	local s = e.ui
	local st = e.state
	st.phase = st.phase or "closed"
	local g = views.gift(e.params.id, config)
	local opened = st.phase == "open" or st.phase == "done"

	local ribbon = s:image(e.content, "ui/ribbon", 0, 420, { w = 600, h = 116, slice9 = true })
		or s:round(e.content, 0, 420, 540, 96, "purple")
	s:text(ribbon, i18n.t("gift.title"), 0, 8, { font = "button", size = 42, color = "white", outline = "#5220A6", shadow = "#5220A6", max_width = 400 })
	if e.first and not kit.reduced() then kit.pop_in(ribbon, 0.05, 0.4) end

	if not opened then
		kit.glow(e, e.content, 0, BOX_Y, 380, "#D9C2FF", 0.6)
		local box = kit.icon(e, e.content, "ui/icons/gift", 0, BOX_Y, 290, "purple")
		e.box = box
		kit.wiggle(box, 0.07, 0.7)
		local hit = s:button({ parent = e.content, x = 0, y = BOX_Y, w = 360, h = 360, style = "white", sfx = false,
			on_click = function() open_gift(e) end })
		gui.set_color(hit.node, vmath.vector4(1, 1, 1, 0))
		e:target("gift", 0, BOX_Y)
		local hint = s:text(e.content, i18n.t("gift.tap"), 0, -150, {
			font = "button", size = 38, color = "white", outline = "#6A2BD1", shadow = "#3A2470", max_width = 600,
		})
		if not kit.reduced() then ui.pulse(hint, 0.06, 0.6) end
		return
	end

	e.fx:rays(e.content, 0, BOX_Y, { count = 12, length = 760, width = 90, alpha = 0.4, color = "#E3D0FF", period = 12 })
	kit.glow(e, e.content, 0, BOX_Y, 480, "#FFE680", 0.85)
	local icon = kit.icon(e, e.content, g.icon, 0, BOX_Y, 230, "purple")
	if st.phase == "open" and not st.shown then kit.pop_in(icon, 0, 0.5) end
	local badge = s:circle(e.content, 96, BOX_Y - 80, 96, "white")
	local inner = s:circle(badge, 0, 0, 84, "pink")
	s:text(inner, "×" .. g.count, 0, 2, { font = "number", size = 36, color = "white", max_width = 76 })
	if st.phase == "open" and not st.shown then kit.pop_in(badge, 0.25, 0.35) end
	s:text(e.content, i18n.t("booster." .. g.id), 0, -110, {
		font = "title", size = 60, color = "white", outline = "#6A2BD1", shadow = "#3A2470", max_width = 620,
	})
	s:text(e.content, i18n.t("booster." .. g.id .. "_desc"), 0, -178, {
		font = "button", size = 30, color = "#FFF3A6", outline = "#3A2470", max_width = 620,
	})
	st.shown = true
	local by = -330
	local b = s:button({ parent = e.content, x = 0, y = by, w = 380, h = 116, style = "green", text = i18n.t("common.collect"),
		text_size = 46, on_click = function() collect(e) end })
	e:target("collect", 0, by)
	if not kit.reduced() then ui.pulse(b.node, 0.04, 0.8) end
end

return M
