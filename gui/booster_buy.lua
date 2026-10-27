-- Buying an in-level booster when the stock is empty (the "+" on its button): the pack of three
-- for coins at the meta's price (meta:buy_booster_pack). After the purchase the window closes and
-- the booster starts at once, so the next tap is the target. Not enough coins: the price shakes
-- and the way to the shop is one tap away.
-- params = {id = booster id}
-- Result: {action = "bought", id} | "close"

local app = require("client.app")
local i18n = require("client.i18n")
local views = require("client.views")
local analytics = require("client.services.analytics")
local kit = require("gui.kit")
local lkit = require("gui.level_kit")

local M = {}

M.dim_alpha = 0.6
M.rebuild_on_meta = true

local W, H = 580, 700

local function info(id)
	for _, b in ipairs(app.meta:inventory()) do
		if b.id == id then return b end
	end
	return nil
end

local function buy(e, b)
	if e.busy then return end
	if app.meta:coins() < b.pack_price then
		kit.sfx("swap_fail")
		if e.price_btn then e.fx:shake(e.price_btn.node, 14, 0.4) end
		if e.bit then e.bit:worry() end
		app.toast_key("common.not_enough_coins", nil, { color = "pink" })
		return
	end
	local res, why = app.meta:buy_booster_pack(b.id)
	app.commit("booster_pack")
	if not res then
		kit.sfx("swap_fail")
		app.toast_key(why == "not_enough_coins" and "common.not_enough_coins" or "common.error", nil, { color = "pink" })
		return
	end
	pcall(analytics.log, "booster_buy", { id = res.id, count = res.count, price = res.price })
	e.busy = true
	kit.sfx("booster")
	if e.bit then e.bit:cheer(1.2, 1) end
	app.toast_key("buy.done", { n = res.count, name = { key = "booster." .. res.id } }, { color = "green" })
	e:close({ action = "bought", id = res.id })
end

function M.build(e)
	local s = e.ui
	local id = e.params.id
	local b = info(id)
	if not b then
		e:close("close")
		return
	end
	local body, hh = kit.panel(e, W, H, { title = { key = "booster." .. id }, ribbon_w = 520 })
	kit.bit(e, body, -W / 2 + 60, hh + 34, 120, "idle")

	kit.glow(e, body, 0, hh - 200, 300, "#E3D0FF", 0.7)
	local icon = kit.booster_icon(e, body, id, 0, hh - 200, 190)
	if e.first and not kit.reduced() then kit.pop_in(icon, 0.05, 0.4) end
	s:text(body, i18n.t("booster." .. id .. "_desc"), 0, hh - 340, {
		font = "button", size = 28, color = "text", width = W - 100, height = 70,
	})

	if not b.unlocked then
		kit.lock(e, body, 0, hh - 450, 80)
		s:text(body, i18n.t("buy.locked", { n = b.unlock_level }), 0, hh - 530, { font = "button", size = 30, color = "text_soft", max_width = W - 80 })
		return
	end

	s:text(body, i18n.t("buy.text", { n = b.pack_size }), 0, hh - 420, {
		font = "body", size = 28, color = "text_soft", width = W - 100, height = 80,
	})
	local y = hh - 530
	local affordable = app.meta:coins() >= b.pack_price
	-- the pack on the left, its price on the right (as the offer of the out-of-moves window)
	local bw = 500
	local btn = s:button({ parent = body, x = 0, y = y, w = bw, h = 120, style = "gold", sfx = false, on_click = function() buy(e, b) end })
	s:text(btn.node, i18n.t("buy.pack", { n = b.pack_size }), -bw / 2 + 36, 6, {
		font = "button", size = 42, color = "white", outline = "#B35F00", shadow = "#B35F00", pivot = gui.PIVOT_W, max_width = 250,
	})
	local pill = s:round(btn.node, bw / 2 - 112, 4, 176, 72, "white", { radius = 34 })
	kit.icon(e, pill, "ui/icons/coin", -50, 1, 52, "coin")
	s:text(pill, i18n.number(b.pack_price), -10, 2, {
		font = "number", size = 36, color = affordable and "text" or "pink", pivot = gui.PIVOT_W, max_width = 90,
	})
	e.price_btn = btn
	e:target("buy", 0, y)
	if affordable then lkit.pulse(btn.node, 0.03, 0.8) else gui.set_color(btn.node, vmath.vector4(1, 1, 1, 0.78)) end
	local coins = kit.coins_pill(e, body, 0, y - 100, app.meta:coins())
	e.coins_pill = coins
	if not affordable then
		s:button({ parent = body, x = 0, y = y - 190, w = 330, h = 80, style = "blue", icon = "ui/icons/shop", icon_size = 46,
			text = i18n.t("lives.get_coins"), text_size = 28, on_click = function() e:open("shop", { tab = "coins" }) end })
		e:target("get_coins", 0, y - 190)
	end
end

function M.update(e, dt)
	kit.update_bit(e, dt)
end

return M
