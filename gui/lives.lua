-- Lives window: the hearts, the timer to the next life (or the unlimited
-- lives left), the refill for coins (meta:refill_lives), a way to the shop
-- when the coins are short, and the rule that the first levels are free.
-- Bit is happy with full lives and sad with none.
-- params = {from = "start" | "hud" | ...}: opened from the start window, a
-- refill closes it and the start window is back on top.

local app = require("client.app")
local i18n = require("client.i18n")
local views = require("client.views")
local ui = require("client.ui")
local kit = require("gui.kit")

local M = {}

M.rebuild_on_meta = true

local W, H = 600, 760

local function status_text(v)
	if v.state == "infinite" then
		return i18n.t("lives.infinite", { time = i18n.duration(v.seconds) }), "purple"
	elseif v.state == "full" then
		return i18n.t("lives.full"), "green"
	elseif v.state == "empty" then
		return i18n.t("lives.next_in", { time = i18n.duration(v.seconds) }), "pink"
	end
	return i18n.t("lives.next_in", { time = i18n.duration(v.seconds) }), "text"
end

local function refill(e)
	local o = views.refill(app.meta, app.now())
	if not o.available then return end
	if not o.affordable then
		kit.sfx("swap_fail")
		if e.refill_btn then e.fx:shake(e.refill_btn.node, 12, 0.4) end
		if e.bit then e.bit:worry() end
		app.toast_key("common.not_enough_coins", nil, { color = "pink" })
		return
	end
	local before = app.meta:lives(app.now()).count
	local ok = app.meta:refill_lives(app.now())
	app.commit("refill_lives")
	if not ok then return end
	e.busy = true -- no rebuild while the hearts fill
	kit.sfx("unlock")
	if e.bit then e.bit:cheer(2, 2) end
	local hearts = e.hearts or {}
	for i = before + 1, #hearts do
		local node = hearts[i]
		local delay = (i - before - 1) * 0.12
		e.fx:after(delay, function()
			gui.set_color(node, vmath.vector4(1, 1, 1, 1))
			e.fx:pop(node, 0.4, 0.3)
			local x, y = kit.abs(e.hearts_x[i], e.hearts_y)
			e.fx:burst(x, y, { count = 8, radius = 70, size = 24, colors = { "#FFFFFF", "#FFB3C7", "#FF4D8D" } })
			e.fx:sfx("star", nil, 0.05)
		end)
	end
	app.toast_key("lives.refilled", nil, { color = "green" })
	e.fx:after(0.25 + 0.12 * (#hearts - before), function()
		e.busy = false
		if e.params.from == "start" then
			e:close("refilled")
		else
			e:rebuild()
		end
	end)
end

function M.build(e)
	local s = e.ui
	local v = views.lives(app.meta:lives(app.now()))
	e.v = v
	local body, hh = kit.panel(e, W, H, { title = { key = "lives.title" } })

	-- hearts, or the big unlimited heart
	local hy = hh - 150
	e.hearts, e.hearts_x, e.hearts_y = nil, {}, hy
	if v.state == "infinite" then
		kit.glow(e, body, 0, hy, 260, "#FFB3E1", 0.8)
		local big = kit.icon(e, body, "ui/icons/heart_infinite", 0, hy, 170, "pink")
		if not kit.reduced() then ui.pulse(big, 0.07, 0.7) end
	else
		e.hearts = kit.hearts(e, body, 0, hy, v.count, v.max, 88)
		for i = 1, v.max do e.hearts_x[i] = (i - (v.max + 1) / 2) * 98 end
		if e.first and not kit.reduced() then
			for i = 1, v.count do kit.pop_in(e.hearts[i], 0.06 * i, 0.3) end
		end
		local count = s:round(body, 0, hy - 80, 120, 46, v.count == 0 and "pink" or "purple", { radius = 22 })
		s:text(count, v.count .. "/" .. v.max, 0, 1, { font = "number", size = 28, color = "white" })
	end

	-- status and the timer
	local text, color = status_text(v)
	e.status, e.status_info = s:text(body, text, 0, hh - 290, {
		font = "button", size = 34, color = color, max_width = W - 80,
	})

	-- refill / shop
	local ry = hh - 400
	local o = views.refill(app.meta, app.now())
	if v.state == "infinite" then
		kit.caption(e, body, i18n.t("lives.play_free"), 0, ry, { size = 26, color = "purple", width = W - 100 })
	elseif o.available then
		local b = kit.price_button(e, { parent = body, x = 0, y = ry, w = 400, h = 116, price = o.price,
			text = i18n.t("lives.refill", { price = i18n.number(o.price) }), text_size = 34, sfx = false,
			on_click = function() refill(e) end })
		e.refill_btn = b
		e:target("refill", 0, ry)
		if not o.affordable then
			local g = s:button({ parent = body, x = 0, y = ry - 120, w = 320, h = 96, style = "blue", icon = "ui/icons/shop",
				icon_size = 56, text = i18n.t("lives.get_coins"), text_size = 30,
				on_click = function() e:open("shop", { tab = "coins" }) end })
			e:target("get_coins", 0, ry - 120)
			gui.set_scale(g.node, vmath.vector3(1, 1, 1))
		else
			kit.caption(e, body, i18n.t("lives.wait"), 0, ry - 100, { size = 24 })
		end
		if v.state == "empty" and o.affordable and not kit.reduced() then ui.pulse(b.node, 0.04, 0.7) end
	else
		kit.caption(e, body, i18n.t("lives.full"), 0, ry, { size = 28, color = "green" })
	end

	-- first levels are free
	s:round(body, 0, -hh + 70, W - 80, 74, "#F4EEFF", { radius = 30 })
	kit.icon(e, body, "ui/icons/star", -W / 2 + 90, -hh + 70, 48, "yellow")
	s:text(body, i18n.t("lives.free_levels", { n = app.free_levels() }), 20, -hh + 70, {
		font = "button", size = 24, color = "text_soft", max_width = W - 190,
	})

	-- Bit
	local mood = (v.state == "empty") and "sad" or ((v.state == "full" or v.state == "infinite") and "happy" or "idle")
	kit.bit(e, body, W / 2 - 40, -hh + 150, 120, mood)
	if mood == "sad" and e.bit then e.bit:mood_for(1e9, "sad") end
end

function M.update(e, dt)
	kit.update_bit(e, dt)
end

-- The timer ticks once a second (a rebuild when the state changed).
function M.on_event(e, topic)
	if topic ~= "lives_tick" or e.busy or not e.status then return end
	local v = views.lives(app.meta:lives(app.now()))
	if v.state ~= e.v.state or v.count ~= e.v.count then
		e:rebuild()
		return
	end
	e.ui:set_text(e.status, (status_text(v)), e.status_info)
end

return M
