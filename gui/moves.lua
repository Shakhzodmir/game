-- "Out of moves" window of the level screen: +5 moves for coins (the price and the number of the
-- offer come from the meta; the second and third also put a Riff on the board), moves for a rewarded
-- video (the number comes from the meta too: view.ad_moves), a booster from the stock instead, or give up.
-- Honest about what giving up costs: the life and the hit streak that burn. A board with no move left
-- (stuck) sells no moves. The ad_offer analytics event belongs to the screen that opens the window
-- (screens/level/level.gui_script), not to this builder: a rebuild must not log it again.
-- params = {view = level_windows.out_of_moves(...), ctx = {level_id, t0}, refresh = fn() -> view}
-- Result: {action = "continue", moves, riff} | {action = "ad", moves} | {action = "booster", id} |
--   {action = "give_up"}. No back key: a choice is needed.

local app = require("client.app")
local i18n = require("client.i18n")
local level_end = require("client.level_end")
local kit = require("gui.kit")
local lkit = require("gui.level_kit")

local M = {}

M.dim_alpha = 0.7
M.no_back = true

local W = 640

local function refresh(e)
	if e.params.refresh then e.params.view = e.params.refresh() end
	e:rebuild()
end

local function pay(e, v)
	local o = v.offer
	if e.busy then return end
	if not o.affordable then
		kit.sfx("swap_fail")
		if e.offer_btn then e.fx:shake(e.offer_btn.node, 14, 0.4) end
		if e.bit then e.bit:worry() end
		app.toast_key("common.not_enough_coins", nil, { color = "pink" })
		return
	end
	if o.free then
		e.busy = true
		e:close({ action = "continue", moves = o.moves, riff = false })
		return
	end
	local res, why = level_end.continue(o.k, e.params.ctx)
	if not res then
		kit.sfx("swap_fail")
		app.toast_key(why == "not_enough_coins" and "common.not_enough_coins" or "common.error", nil, { color = "pink" })
		refresh(e) -- a stale offer: the one that is true now
		return
	end
	e.busy = true
	kit.sfx("coin")
	if e.offer_btn then e.fx:pop(e.offer_btn.node, 0.08, 0.25) end
	e:close({ action = "continue", moves = res.moves, riff = res.riff })
end

local function watch(e, v)
	if e.busy then return end
	e.busy = true
	level_end.ad_moves(e.params.ctx, function(res, why)
		if e.closing then return end
		e.busy = false
		if not res then
			kit.sfx("swap_fail")
			app.toast_key(why == "already_used" and "common.error" or "common.unavailable", nil, { color = "pink" })
			refresh(e)
			return
		end
		kit.sfx("win")
		e.busy = true
		e:close({ action = "ad", moves = res.moves })
	end)
end

-- the +5 moves button: the label and the Riff note on the left, the price on the right
local function offer_button(e, body, v, y)
	local s = e.ui
	local o = v.offer
	local w, h = 540, o.riff and 144 or 124
	local btn = s:button({ parent = body, x = 0, y = y, w = w, h = h, style = "gold", sfx = false,
		on_click = function() pay(e, v) end })
	s:text(btn.node, i18n.t("continue.offer", { n = o.moves }), -w / 2 + 40, o.riff and 22 or 8, {
		font = "button", size = 46, color = "white", outline = "#B35F00", shadow = "#B35F00", pivot = gui.PIVOT_W, max_width = 280,
	})
	if o.riff then
		kit.icon(e, btn.node, "specials/riff", -w / 2 + 62, -30, 44, "blue")
		s:text(btn.node, i18n.t("continue.riff"), -w / 2 + 92, -30, {
			font = "button", size = 22, color = "white", outline = "#B35F00", pivot = gui.PIVOT_W, max_width = 230,
		})
	end
	local pill = s:round(btn.node, w / 2 - 118, 4, 188, 72, o.free and "#EAF9EF" or "white", { radius = 34 })
	if o.free then
		s:text(pill, i18n.t("continue.free_debug"), 0, 1, { font = "button", size = 22, color = "green", max_width = 170 })
	else
		kit.icon(e, pill, "ui/icons/coin", -54, 1, 52, "coin")
		s:text(pill, i18n.number(o.price), -14, 2, {
			font = "number", size = 38, color = o.affordable and "text" or "pink", pivot = gui.PIVOT_W, max_width = 100,
		})
	end
	if not o.affordable then gui.set_color(btn.node, vmath.vector4(1, 1, 1, 0.78)) end
	e.offer_btn = btn
	e:target("continue", 0, y)
	if o.affordable then lkit.pulse(btn.node, 0.03, 0.8) end
	return btn
end

function M.build(e)
	local s = e.ui
	local v = e.params.view
	local o = v.offer
	local gap = 28
	local give_lines = #(v.lines or {})
	local boosters = v.boosters or {}

	-- heights of the blocks, top to bottom
	local h_head = 350
	local h_offer = 0
	if o then
		h_offer = (o.riff and 144 or 124) + gap + (o.affordable and 0 or 150)
	else
		h_offer = 120 + gap
	end
	local h_ad = v.ad and (92 + gap) or 0
	local h_boost = #boosters > 0 and (190 + gap) or 0
	local h_give = 34 + give_lines * 64 + 100
	local H = h_head + h_offer + h_ad + h_boost + h_give
	local body, hh = kit.panel(e, W, H, { title = { key = "continue.title" }, close = false })

	-- Bit is worried, and says what can still be done
	kit.bit(e, body, 0, hh - 160, 190, "worried")
	if e.bit then e.bit:mood_for(1e9, "worried") end
	s:text(body, i18n.t(v.stuck and "continue.stuck" or "continue.sub"), 0, hh - 306, {
		font = "button", size = 28, color = "text_soft", width = W - 100, height = 80,
	})

	local y = hh - h_head + 10
	-- the offer
	if o then
		local oh = o.riff and 144 or 124
		y = y - oh / 2
		offer_button(e, body, v, y)
		y = y - oh / 2
		if not o.affordable then
			s:text(body, i18n.t("continue.no_coins", { n = i18n.number(v.coins) }), 0, y - 34, {
				font = "button", size = 26, color = "pink", max_width = W - 80,
			})
			s:button({ parent = body, x = 0, y = y - 106, w = 330, h = 88, style = "blue", icon = "ui/icons/shop", icon_size = 52,
				text = i18n.t("lives.get_coins"), text_size = 30, on_click = function() e:open("shop", { tab = "coins" }) end })
			e:target("get_coins", 0, y - 106)
			y = y - 150
		end
		y = y - gap
	else
		local box = s:round(body, 0, y - 60, W - 80, 120, "#F4EEFF", { radius = 30 })
		s:text(box, i18n.t(v.stuck and "continue.stuck" or "continue.limit"), 0, 2, {
			font = "button", size = 26, color = "text", width = W - 140, height = 100,
		})
		y = y - 120 - gap
	end

	-- a video
	if v.ad then
		y = y - 46
		local ad = s:button({ parent = body, x = 0, y = y, w = 540, h = 92, style = "green", icon = "ui/icons/play",
			icon_size = 50, text = i18n.t("continue.ad"), text_size = 32, sfx = false, on_click = function() watch(e, v) end })
		local pill = s:round(ad.node, 540 / 2 - 90, 0, 120, 52, "white", { radius = 24 })
		s:text(pill, "+" .. i18n.number(v.ad_moves or 0), 0, 1, { font = "number", size = 32, color = "green", max_width = 100 })
		e:target("ad", 0, y)
		y = y - 46 - gap
	end

	-- a booster from the stock
	if #boosters > 0 then
		s:text(body, i18n.t("continue.use_booster"), 0, y - 20, { font = "button", size = 26, color = "text_soft", max_width = W - 80 })
		local by = y - 106
		for i, b in ipairs(boosters) do
			local bx = (i - (#boosters + 1) / 2) * 130
			lkit.booster_tile(e, body, { id = b.id, count = b.count, x = bx, y = by, size = 116,
				on_click = function()
					if e.busy then return end
					e.busy = true
					e:close({ action = "booster", id = b.id })
				end })
			e:target("booster_" .. b.id, bx, by)
		end
		y = y - 190 - gap + 0
	end

	-- giving up: what it costs, then the button
	local gy = y - 17 - give_lines * 32
	local specs = {}
	for i, l in ipairs(v.lines or {}) do
		local key = l.key
		specs[i] = {
			text = l, h = 56, size = 24,
			icon = key == "continue.life_warning" and "ui/icons/heart" or (key == "continue.streak_warning" and "ui/icons/streak" or "ui/icons/retry"),
			color = v.at_stake and "pink" or "text_soft", fill = v.at_stake and "#FFE9F1" or "#F4EEFF",
		}
	end
	if give_lines > 0 then lkit.notes(e, body, 0, gy + 8, W - 100, specs) end
	local by = -hh + 62
	s:button({ parent = body, x = 0, y = by, w = 360, h = 84, style = "pink", text = i18n.t("continue.give_up"), text_size = 34,
		on_click = function()
			if e.busy then return end
			e.busy = true
			e:close({ action = "give_up" })
		end })
	e:target("give_up", 0, by)
end

function M.update(e, dt)
	kit.update_bit(e, dt)
end

function M.on_event(e, topic)
	-- the coins may change under the window (a purchase in the shop on top of it): draw the true price
	if topic == "meta_changed" and e.params.refresh and not e.busy and not e.closing then
		local v = e.params.refresh()
		local a, b = e.params.view, v
		local changed = (a.offer and a.offer.affordable) ~= (b.offer and b.offer.affordable) or a.coins ~= b.coins
		e.params.view = v
		if changed then e:rebuild() end
	end
end

return M
