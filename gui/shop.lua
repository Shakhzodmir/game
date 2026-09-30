-- Shop: booster packs and the lives refill for coins (meta rules), coin
-- packs through the store service (client/services/iap.lua: the web demo
-- honestly says "not available", a debug build grants them at once) and a
-- free gift for watching a video (client/services/ads.lua, placement
-- "shop_gift": debug only).
-- params = {tab = "boosters" | "coins", focus = booster id to highlight}

local app = require("client.app")
local i18n = require("client.i18n")
local views = require("client.views")
local ui = require("client.ui")
local iap = require("client.services.iap")
local ads = require("client.services.ads")
local kit = require("gui.kit")

local M = {}

M.rebuild_on_meta = true

local W, H = 680, 1150

local gift_at = nil -- app time of the last shop gift (this session)

local function coins_fly(e, n, x, y)
	if not e.pill then return end
	local px, py = kit.abs(e.pill.x - 74, e.pill.y)
	local flyers = math.max(3, math.min(8, math.ceil(n / 150)))
	local shown = e.shown_coins or app.meta:coins()
	local from = shown
	e.busy = true
	local target = app.meta:coins()
	local step = (target - from) / flyers
	for i = 1, flyers do
		e.fx:fly({ image = "ui/icons/coin", size = 60, from = { x + (i - 1) * 6, y }, to = { px, py },
			delay = (i - 1) * 0.07, arc = 120 + i * 12, trail = "#FFE066",
			on_land = function()
				shown = math.floor(from + step * i + 0.5)
				if i == flyers then shown = target end
				e.shown_coins = shown
				kit.set_coins(e, e.pill, shown)
				e.fx:pop(e.pill.icon, 0.3, 0.25)
				e.fx:sfx("coin", nil, 0.06)
				if i == flyers then
					e.busy = false
					e.shown_coins = nil
					e:rebuild()
				end
			end })
	end
end

local function buy_pack(e, b, x, y, node)
	local res, why = app.meta:buy_booster_pack(b.id)
	if not res then
		kit.sfx("swap_fail")
		if node then e.fx:shake(node, 12, 0.4) end
		app.toast_key(why == "locked" and "start.locked" or "common.not_enough_coins",
			{ n = b.unlock_level }, { color = "pink" })
		if why == "not_enough_coins" and e.state.tab ~= "coins" then
			e.fx:after(0.5, function()
				if not e.closing then
					e.state.tab = "coins"
					e:rebuild()
				end
			end)
		end
		return
	end
	app.commit("booster_pack")
	kit.sfx("booster")
	e.fx:burst(kit.abs(x, y), { count = 12, radius = 120 })
	e.fx:float_text(i18n.t("shop.pack_got", { n = res.count, name = i18n.t("booster." .. b.id) }), kit.abs(x, y + 60),
		{ size = 34, outline = "#8B45FF" })
	e.fx:pop(node, 0.18, 0.3)
	-- the spent coins leave the pill
	if e.pill then
		local px, py = kit.abs(e.pill.x - 74, e.pill.y)
		e.fx:fly({ image = "ui/icons/coin", size = 48, from = { px, py }, to = { kit.abs(x, y) }, arc = -80, dur = 0.4 })
	end
end

local function refill(e, x, y, node)
	local ok, why = app.meta:refill_lives(app.now())
	if not ok then
		kit.sfx("swap_fail")
		if node then e.fx:shake(node, 12, 0.4) end
		local key = why == "full" and "shop.lives_full" or (why == "infinite_active" and "shop.infinite_on" or "common.not_enough_coins")
		app.toast_key(key, nil, { color = "pink" })
		return
	end
	app.commit("refill_lives")
	kit.sfx("unlock")
	e.fx:burst(kit.abs(x, y), { count = 12, radius = 120, colors = { "#FFFFFF", "#FFB3C7", "#FF4D8D" } })
	app.toast_key("lives.refilled", nil, { color = "green" })
end

local function buy_product(e, p, x, y, node)
	if not p.available then
		kit.sfx("swap_fail")
		e.fx:shake(node, 10, 0.35)
		app.toast_key("shop.iap_unavailable", nil, { color = "blue", duration = 2.5 })
		return
	end
	local before = app.meta:coins()
	e.shown_coins = before
	iap.buy(p.id, function(ok, reason)
		if not ok then
			e.shown_coins = nil
			app.toast_key(reason == "unavailable" and "shop.iap_unavailable" or "common.error", nil, { color = "pink" })
			return
		end
		kit.sfx("win")
		app.toast_key("shop.bought", nil, { color = "gold" })
		e.fx:burst(kit.abs(x, y), { count = 16, radius = 150 })
		coins_fly(e, app.meta:coins() - before, kit.abs(x, y))
	end)
end

local function gift(e, x, y, node)
	if not ads.can_show("shop_gift") then
		kit.sfx("swap_fail")
		e.fx:shake(node, 10, 0.35)
		app.toast_key("shop.gift_unavailable", nil, { color = "blue" })
		return
	end
	local now = app.now()
	if gift_at and now - gift_at < ads.GIFT_COOLDOWN then
		kit.sfx("swap_fail")
		app.toast_key("shop.gift_wait", { time = i18n.duration(ads.GIFT_COOLDOWN - (now - gift_at)) }, { color = "blue" })
		return
	end
	ads.show_rewarded("shop_gift", function(ok)
		if not ok then return end
		gift_at = app.now()
		local r = ads.REWARDS.shop_gift
		local before = app.meta:coins()
		e.shown_coins = before
		app.meta:grant(r, "ad_shop_gift", app.now())
		app.commit("ad_gift")
		kit.sfx("chest_open")
		app.toast_key("shop.gift_got", { n = r.coins or 0 }, { color = "gold" })
		coins_fly(e, app.meta:coins() - before, kit.abs(x, y))
	end)
end

-- boosters tab ------------------------------------------------------------------------------

local function booster_card(e, body, b, x, y, focus)
	local s = e.ui
	local cw, ch = 300, 196
	local hl = focus == b.id
	local card = s:round(body, x, y, cw, ch, hl and "gold" or "#E3D9FF", { radius = 30 })
	local inner = s:round(card, 0, 0, cw - 10, ch - 10, b.unlocked and "white" or "#F6F3FB", { radius = 26 })
	local icon = kit.booster_icon(e, inner, b.id, -84, 22, 104)
	s:text(inner, i18n.t("booster." .. b.id), 40, 60, {
		font = "button", size = 22, color = b.unlocked and "text" or "text_soft", max_width = 170,
	})
	s:text(inner, "×" .. b.size, 40, 18, { font = "number", size = 40, color = "purple", max_width = 160 })
	if not b.unlocked then
		gui.set_color(icon, vmath.vector4(0.75, 0.72, 0.85, 0.45))
		kit.lock(e, inner, -84, 20, 56)
		kit.badge(e, inner, 0, -58, i18n.t("start.locked", { n = b.unlock_level }), "text_soft", { w = 260, h = 50, size = 20 })
		return card
	end
	s:text(inner, i18n.t("shop.owned", { n = b.count }), 40, -18, { font = "small", size = 20, color = "text_soft", max_width = 170 })
	local btn = kit.price_button(e, { parent = inner, x = 0, y = -58, w = 250, h = 88, price = b.price, sfx = false,
		on_click = function() buy_pack(e, b, x, y, card) end })
	if not b.affordable then gui.set_color(btn.node, vmath.vector4(1, 1, 1, 0.7)) end
	e:target("pack_" .. b.id, x, y - 58)
	if hl and e.first then
		e.fx:after(0.3, function() if not e.closing then e.fx:pop(card, 0.12, 0.35) end end)
	end
	return card
end

local function refill_card(e, body, x, y)
	local s = e.ui
	local cw, ch = 300, 196
	local o = views.refill(app.meta, app.now())
	local card = s:round(body, x, y, cw, ch, "#FFC2D6", { radius = 30 })
	local inner = s:round(card, 0, 0, cw - 10, ch - 10, "white", { radius = 26 })
	kit.icon(e, inner, "ui/icons/heart", -84, 22, 100, "pink")
	s:text(inner, i18n.t("shop.refill"), 40, 50, { font = "button", size = 22, color = "text", max_width = 170, width = 170 })
	local l = app.meta:lives(app.now())
	s:text(inner, l.count .. "/" .. l.max, 40, 4, { font = "number", size = 34, color = "pink" })
	if o.available then
		kit.price_button(e, { parent = inner, x = 0, y = -58, w = 250, h = 88, price = o.price, sfx = false,
			on_click = function() refill(e, x, y, card) end })
		e:target("refill", x, y - 58)
	else
		kit.badge(e, inner, 0, -58, i18n.t(o.reason == "infinite_active" and "shop.infinite_on" or "shop.lives_full"), "green",
			{ w = 250, h = 60, size = 22 })
	end
end

local function build_boosters(e, body, top)
	local list = views.shop_boosters(app.meta)
	local focus = e.params.focus
	local i = 0
	for _, b in ipairs(list) do
		local col = i % 2
		local row = math.floor(i / 2)
		booster_card(e, body, b, col == 0 and -160 or 160, top - 110 - row * 212, focus)
		i = i + 1
	end
	refill_card(e, body, i % 2 == 0 and -160 or 160, top - 110 - math.floor(i / 2) * 212)
end

-- coins tab -------------------------------------------------------------------------------------

local PRODUCT_ICON = {
	starter_pack = "ui/icons/gift",
	coins_small = "ui/icons/coin",
	coins_medium = "ui/icons/coin",
	coins_large = "ui/icons/chest_open",
	piggy_bank = "ui/icons/chest_closed",
}

local function product_row(e, body, p, y)
	local s = e.ui
	local rw, rh = 600, 132
	local color = p.color == "pink" and "#FFC2D6" or (p.color == "purple" and "#DCC8FF" or "#FFE3A3")
	local row = s:round(body, 0, y, rw, rh, color, { radius = 30 })
	local inner = s:round(row, 0, 0, rw - 10, rh - 10, "white", { radius = 26 })
	local icon = kit.icon(e, inner, PRODUCT_ICON[p.id] or "ui/icons/coin", -236, 4, p.id == "coins_medium" and 92 or 100, "coin")
	if p.id == "coins_medium" then
		kit.icon(e, inner, "ui/icons/coin", -210, -14, 70, "coin")
	end
	local two = #p.boosters > 0
	s:text(inner, i18n.t(p.name), -170, two and 36 or 24, { font = "button", size = 26, color = "text", pivot = gui.PIVOT_W, max_width = 250 })
	-- contents: coins (+ unlimited lives), then the boosters on a second line
	local ly = two and -2 or -20
	kit.icon(e, inner, "ui/icons/coin", -154, ly, 34, "coin")
	s:text(inner, i18n.number(p.coins), -132, ly + 1, { font = "number", size = 26, color = "gold", pivot = gui.PIVOT_W, max_width = 96 })
	if p.infinite_minutes > 0 then
		kit.icon(e, inner, "ui/icons/heart_infinite", -16, ly, 36, "pink")
		s:text(inner, i18n.t("shop.minutes", { n = p.infinite_minutes }), 4, ly, {
			font = "number", size = 20, color = "pink", pivot = gui.PIVOT_W, max_width = 96,
		})
	end
	local cx = -170
	for _, b in ipairs(p.boosters) do
		kit.booster_icon(e, inner, b.id, cx + 16, -40, 36)
		s:text(inner, "×" .. b.count, cx + 36, -40, { font = "number", size = 20, color = "purple", pivot = gui.PIVOT_W })
		cx = cx + 76
	end
	if p.best then
		local badge = kit.badge(e, row, -rw / 2 + 60, rh / 2 - 4, i18n.t("shop.best"), "pink", { w = 96, h = 38, size = 20 })
		gui.set_euler(badge, vmath.vector3(0, 0, 8))
	end
	local btn = s:button({ parent = inner, x = 196, y = 0, w = 176, h = 92, style = p.available and "gold" or "white",
		text = p.price, text_size = 32, sfx = false, on_click = function() buy_product(e, p, 196, y, row) end })
	if not p.available then gui.set_color(btn.node, vmath.vector4(1, 1, 1, 0.75)) end
	e:target("product_" .. p.id, 196, y)
	return row
end

local function gift_row(e, body, y)
	local s = e.ui
	local rw, rh = 600, 132
	local avail = ads.can_show("shop_gift")
	local row = s:round(body, 0, y, rw, rh, "#BDF5CF", { radius = 30 })
	local inner = s:round(row, 0, 0, rw - 10, rh - 10, "white", { radius = 26 })
	local g = kit.icon(e, inner, "ui/icons/gift", -236, 4, 100, "green")
	if avail then kit.wiggle(g, 0.06, 1.0) end
	s:text(inner, i18n.t("shop.gift"), -170, 26, { font = "button", size = 26, color = "text", pivot = gui.PIVOT_W, max_width = 250 })
	local r = ads.REWARDS.shop_gift or {}
	kit.icon(e, inner, "ui/icons/coin", -154, -18, 34, "coin")
	s:text(inner, "+" .. i18n.number(r.coins or 0), -132, -17, { font = "number", size = 26, color = "gold", pivot = gui.PIVOT_W })
	local btn = s:button({ parent = inner, x = 196, y = 0, w = 176, h = 92, style = avail and "green" or "white",
		icon = "ui/icons/play", icon_size = 44, text = i18n.t(avail and "shop.gift_desc" or "common.soon"), text_size = 22,
		sfx = false, on_click = function() gift(e, 196, y, row) end })
	if not avail then gui.set_color(btn.node, vmath.vector4(1, 1, 1, 0.75)) end
	e:target("gift", 196, y)
end

local function build_coins(e, body, top)
	local s = e.ui
	local avail = iap.available()
	local list = views.shop_products(iap.PRODUCTS, avail)
	local y = top - 86
	for _, p in ipairs(list) do
		product_row(e, body, p, y)
		y = y - 146
	end
	gift_row(e, body, y)
	y = y - 104
	local note = avail and i18n.t("shop.debug_grant") or i18n.t("shop.demo")
	s:text(body, note, 0, y, { font = "small", size = 22, color = avail and "purple" or "text_soft", max_width = W - 80 })
end

function M.build(e)
	local s = e.ui
	local st = e.state
	st.tab = st.tab or e.params.tab or "boosters"
	local body, hh = kit.panel(e, W, H, { title = { key = "shop.title" } })
	e.pill = kit.coins_pill(e, body, -W / 2 + 150, hh - 96, e.shown_coins or app.meta:coins())
	local tabs_y = hh - 96
	kit.segmented(e, body, 80, tabs_y, 320, {
		{ id = "boosters", text = i18n.t("shop.tab_boosters") },
		{ id = "coins", text = i18n.t("shop.tab_coins") },
	}, st.tab, function(id)
		st.tab = id
		e:rebuild()
	end, { h = 84, text_size = 26, targets = "tab" })
	local top = tabs_y - 60
	if st.tab == "coins" then
		build_coins(e, body, top)
	else
		build_boosters(e, body, top)
	end
end

function M.update(e, dt)
	kit.update_bit(e, dt)
end

return M
