-- Chest reveal: a level chest (every 10th level) or a district chest (the
-- last task of a district). The closed chest bounces and waits for a tap;
-- then it shakes, bursts open in a flash with rays behind it, and what it
-- holds pops out one by one (coins, boosters, unlimited lives). "Collect"
-- closes it; the town flies the coins into the top bar from where they lie.
-- The meta has already paid the chest; this window only shows it.
-- params = {kind = "level" | "district", chest = {coins, boosters, infinite_minutes},
--           level_id, district_name = {en, ru}}
-- Result: {action = "collect", items = {{kind, id, amount, x, y}}} (x, y logical).

local i18n = require("client.i18n")
local views = require("client.views")
local ui = require("client.ui")
local fx = require("client.fx")
local kit = require("gui.kit")

local M = {}

M.dim_alpha = 0.75
M.no_back = true

local CHEST_Y = 90
local ITEMS_Y = -150

local function item_x(i, n)
	return (i - (n + 1) / 2) * 176
end

local function amount_text(it)
	if it.kind == "coins" then return "+" .. i18n.number(it.amount) end
	if it.kind == "infinite" then return i18n.t("shop.minutes", { n = it.amount }) end
	return "×" .. it.amount
end

local function draw_item(e, it, i, n, animate)
	local s = e.ui
	local x = item_x(i, n)
	local holder = s:layer(e.content)
	gui.set_position(holder, vmath.vector3(x, ITEMS_Y, 0))
	kit.glow(e, holder, 0, 10, 170, it.kind == "infinite" and "#FFB3E1" or "#FFE680", 0.7)
	local icon = kit.icon(e, holder, it.image, 0, 10, 112, it.kind == "coins" and "coin" or "purple")
	s:text(holder, amount_text(it), 0, -72, {
		font = "number", size = 38, color = "white", outline = it.kind == "infinite" and "#A8204F" or "#6A2BD1",
		shadow = "#3A2470", max_width = 170,
	})
	if it.kind == "booster" then
		s:text(holder, i18n.t("booster." .. it.id), 0, -112, { font = "button", size = 22, color = "white", outline = "#3A2470", max_width = 170 })
	end
	if animate and not kit.reduced() then
		-- flies out of the chest and lands with a pop
		gui.set_position(holder, vmath.vector3(0, CHEST_Y, 0))
		gui.set_scale(holder, vmath.vector3(0.2, 0.2, 1))
	end
	e.state.items[i] = { kind = it.kind, id = it.id, amount = it.amount, x = kit.CX + x, y = kit.CY + ITEMS_Y + 10 }
	return holder, icon
end

local function collect(e)
	if e.state.phase ~= "open" then return end
	e.state.phase = "done"
	kit.sfx("button")
	e:close({ action = "collect", items = e.state.items })
end

local function open_chest(e)
	local st = e.state
	if st.phase ~= "closed" then return end
	st.phase = "opening"
	kit.sfx("tap")
	local chest = e.chest_node
	local function burst_open()
		if e.closing then return end
		st.phase = "open"
		kit.sfx("chest_open")
		fx.buzz(40)
		local x, y = kit.abs(0, CHEST_Y)
		e.fx:flash(x, y, { size = 620, dur = 0.5 })
		e.fx:ring(x, y, { size = 200, scale = 4, color = "#FFE66D" })
		e.fx:burst(x, y, { count = 22, radius = 260, size = 40 })
		e:rebuild() -- the open chest, the rays, the items popping out
	end
	if kit.reduced() then
		burst_open()
		return
	end
	gui.cancel_animations(chest, "scale")
	local k = 0
	local function wobble()
		k = k + 1
		if k > 5 then
			gui.animate(chest, "scale", vmath.vector3(1.25, 0.8, 1), gui.EASING_OUTQUAD, 0.1, 0, function()
				burst_open()
			end)
			return
		end
		gui.animate(chest, "euler.z", (k % 2 == 0 and 1 or -1) * (4 + k * 2), gui.EASING_INOUTSINE, 0.07, 0, wobble)
	end
	wobble()
end

function M.build(e)
	local s = e.ui
	local st = e.state
	local p = e.params
	st.phase = st.phase or "closed"
	st.items = {}
	local items = views.chest_items(p.chest)
	local opened = st.phase == "open" or st.phase == "done"

	-- title ribbon
	local title
	if p.kind == "district" then
		title = i18n.t("reward.chest_district", { name = i18n.name(p.district_name or {}) })
	else
		title = p.level_id and i18n.t("reward.chest_level", { n = p.level_id }) or i18n.t("chest.level")
	end
	local ribbon = s:image(e.content, "ui/ribbon", 0, 420, { w = 620, h = 116, slice9 = true })
		or s:round(e.content, 0, 420, 560, 96, "purple")
	s:text(ribbon, title, 0, 8, { font = "button", size = 40, color = "white", outline = "#5220A6", shadow = "#5220A6", max_width = 420 })
	if e.first and not kit.reduced() then kit.pop_in(ribbon, 0.05, 0.4) end

	-- rays and glow behind the chest
	if opened then
		e.fx:rays(e.content, 0, CHEST_Y, { count = 12, length = 760, width = 90, alpha = 0.4, period = 12 })
	end
	kit.glow(e, e.content, 0, CHEST_Y, opened and 520 or 380, "#FFE680", opened and 0.9 or 0.6)

	local key = opened and "ui/icons/chest_open" or "ui/icons/chest_closed"
	local chest = kit.icon(e, e.content, key, 0, CHEST_Y, 300, "gold")
	e.chest_node = chest
	if not opened then
		kit.wiggle(chest, 0.06, 0.8)
		local hit = s:button({ parent = e.content, x = 0, y = CHEST_Y, w = 360, h = 360, style = "white", sfx = false,
			on_click = function() open_chest(e) end })
		gui.set_color(hit.node, vmath.vector4(1, 1, 1, 0))
		e:target("chest", 0, CHEST_Y)
		local hint = s:text(e.content, i18n.t("chest.tap"), 0, -150, {
			font = "button", size = 38, color = "white", outline = "#6A2BD1", shadow = "#3A2470", max_width = 600,
		})
		if not kit.reduced() then ui.pulse(hint, 0.06, 0.6) end
		if e.first and not kit.reduced() then
			local sc = gui.get_scale(chest)
			gui.set_position(chest, vmath.vector3(0, CHEST_Y + 700, 0))
			gui.animate(chest, "position.y", CHEST_Y, gui.EASING_OUTBOUNCE, 0.7)
			gui.set_scale(chest, sc)
		end
		return
	end

	local animate = st.phase == "open" and not st.shown
	for i, it in ipairs(items) do
		local holder = draw_item(e, it, i, #items, animate)
		if animate and not kit.reduced() then
			gui.set_enabled(holder, false)
			e.fx:after(0.15 + (i - 1) * 0.22, function()
				if e.closing then return end
				gui.set_enabled(holder, true)
				e.fx:sfx(it.kind == "coins" and "coin" or "star", nil, 0.05)
				gui.animate(holder, "position", vmath.vector3(item_x(i, #items), ITEMS_Y, 0), gui.EASING_OUTBACK, 0.45)
				gui.animate(holder, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, 0.45)
			end)
		end
	end
	st.shown = true
	local by = -370
	local b = s:button({ parent = e.content, x = 0, y = by, w = 380, h = 116, style = "green", text = i18n.t("common.collect"),
		text_size = 46, on_click = function() collect(e) end })
	e:target("collect", 0, by)
	if animate and not kit.reduced() then
		gui.set_scale(b.node, vmath.vector3(0.01, 0.01, 1))
		gui.animate(b.node, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, 0.35, 0.2 + #items * 0.22, function()
			if not e.closing then ui.pulse(b.node, 0.04, 0.8) end
		end)
	elseif not kit.reduced() then
		ui.pulse(b.node, 0.04, 0.8)
	end
end

return M
