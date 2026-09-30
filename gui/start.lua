-- Start window (modal over the town): "Level N" with its difficulty tag,
-- the goals from the level file, the pre-level boosters (Riff, Subwoofer,
-- Disco ball) with their stock, lock state, a toggle each and the "free
-- from your hit streak" badge, the hit-streak notes, what a loss costs and
-- the big Play button.
-- Play -> client/flow.lua start(n, picked, "town") -> meta:start_level ->
-- the level screen (contract: client/flow.lua). "no_lives" opens the lives
-- window on top.
-- params = {level = n (default: the next level)}

local app = require("client.app")
local i18n = require("client.i18n")
local views = require("client.views")
local levels = require("client.levels")
local flow = require("client.flow")
local kit = require("gui.kit")
local config = require("meta.config")

local M = {}

M.rebuild_on_meta = true

local W, H = 640, 1000

local REFUSALS = {
	run_active = "start.run_active",
	not_next_level = "start.not_next",
	all_done = "town.all_done",
	locked = "start.locked",
}

local function booster_slot(e, body, slot, x, y, view)
	local s = e.ui
	local st = e.state
	local on = slot.free or (st.selected[slot.id] and slot.selectable)
	local size = 156
	local holder = s:layer(body)
	if on then
		local g = s:circle(holder, x, y, size * 1.5, "glow", { soft = true, alpha = 0.9 })
		if not kit.reduced() then require("client.ui").pulse(g, 0.06, 0.9) end
	end
	local face = s:round(holder, x, y, size, size, on and "#FFE9A8" or "#F4EEFF", { radius = 34 })
	s:round(face, 0, 0, size - 12, size - 12, on and "#FFF6D6" or "white", { radius = 30 })
	local icon = kit.booster_icon(e, face, slot.id, 0, 6, 112)
	if not slot.unlocked then
		gui.set_color(icon, vmath.vector4(0.75, 0.72, 0.85, 0.45))
		kit.lock(e, face, 0, 4, 64)
		kit.badge(e, face, 0, -size / 2 + 4, i18n.t("common.level_n", { n = slot.unlock_level }), "text_soft",
			{ w = 128, h = 38, size = 20 })
	elseif slot.free then
		kit.badge(e, face, 0, size / 2 - 6, i18n.t("start.free"), "green", { w = 118, h = 40, size = 22, outline = "#0F7A3B" })
	elseif slot.count > 0 then
		kit.count_bubble(e, face, size / 2 - 14, size / 2 - 14, slot.count, on and "green" or "pink")
	else
		local plus = s:circle(face, size / 2 - 14, size / 2 - 14, 52, "white")
		local g = s:circle(plus, 0, 0, 44, "green")
		s:text(g, "+", 0, 3, { font = "button", size = 34, color = "white" })
	end
	if on then
		local chk = s:image(face, "ui/icons/check", -size / 2 + 20, -size / 2 + 20, { w = 56, h = 56 })
			or s:circle(face, -size / 2 + 20, -size / 2 + 20, 44, "green")
		if st.just == slot.id then kit.pop_in(chk, 0, 0.3) end
	end
	s:text(holder, i18n.t("booster." .. slot.id), x, y - size / 2 - 26, {
		font = "button", size = 22, color = slot.unlocked and "text" or "text_soft", max_width = 180,
	})
	-- the tap area covers the tile and its name (>= 88 px)
	local b = s:button({ parent = holder, x = x, y = y - 10, w = size + 20, h = size + 40, style = "white", sfx = false,
		on_click = function() M.tap_slot(e, slot, face) end })
	gui.set_color(b.node, vmath.vector4(1, 1, 1, 0))
	e:target("booster_" .. slot.id, x, y)
	if st.just == slot.id and not kit.reduced() then
		e.fx:burst(kit.abs(x, y), { count = 10, radius = 110, size = 30 })
	end
	return face
end

function M.tap_slot(e, slot, face)
	local st = e.state
	if not slot.unlocked then
		kit.sfx("swap_fail")
		e.fx:shake(face, 12, 0.4)
		app.toast_key("start.locked", { n = slot.unlock_level }, { color = "blue" })
		return
	end
	if slot.free then
		kit.sfx("star")
		e.fx:pop(face, 0.15)
		app.toast_key("start.free_hint", nil, { color = "gold" })
		return
	end
	if slot.count <= 0 then
		kit.sfx("button")
		e:open("shop", { tab = "boosters", focus = slot.id })
		return
	end
	st.selected[slot.id] = not st.selected[slot.id]
	st.just = st.selected[slot.id] and slot.id or nil
	kit.sfx(st.selected[slot.id] and "booster" or "tap")
	if st.selected[slot.id] and e.bit then e.bit:cheer(1.0, 1) end
	e:rebuild()
	st.just = nil
end

local function play(e, v)
	if e.busy then return end
	local picked = views.picked(v.boosters, e.state.selected)
	local ok, why = flow.start(v.level, picked, "town")
	if ok then
		e.busy = true
		kit.sfx("win")
		if e.bit then e.bit:cheer(2, 2) end
		if e.play_btn then e.fx:pop(e.play_btn.node, 0.12) end
		e.fx:burst(kit.abs(0, -400), { count = 14, radius = 180 })
		return
	end
	if why == "no_lives" then
		kit.sfx("swap_fail")
		if e.bit then e.bit:worry() end
		e:open("lives", { from = "start" })
	else
		app.toast_key(REFUSALS[why] or "common.error", nil, { color = "pink" })
	end
end

function M.build(e)
	local s = e.ui
	local st = e.state
	st.selected = st.selected or {}
	local n = tonumber(e.params.level) or app.meta:level_to_play()
	if not n then
		e:close("all_done")
		return
	end
	local info = levels.load(n)
	local v = views.start(app.meta, n, info, app.now(), levels, app.free_levels())
	e.view = v
	local body, hh = kit.panel(e, W, H, { title = { key = "start.title", vars = { n = n } } })

	-- Bit peeks over the left end of the ribbon
	kit.bit(e, body, -W / 2 + 70, hh + 34, 128, e.busy and "happy" or "idle")

	local y = hh - 92
	if v.tag then
		local hard = v.tag == "town.hard"
		local tag = kit.badge(e, body, 0, y, i18n.t(v.tag), hard and "pink" or "purple",
			{ w = 230, h = 50, size = 26, outline = hard and "#A8204F" or "#5220A6" })
		if not kit.reduced() and e.first then kit.pop_in(tag, 0.25, 0.35) end
	end

	-- goals
	y = hh - 160
	kit.section(e, body, i18n.t("start.goals"), 0, y, W - 80)
	local goals = v.goals
	local gy = y - 104
	if #goals == 0 then
		kit.caption(e, body, i18n.t("start.no_goals"), 0, gy, { size = 26 })
	else
		local count = math.min(4, #goals)
		local gap = 150
		for i = 1, count do
			local gx = (i - (count + 1) / 2) * gap
			local tile = kit.goal(e, body, goals[i], gx, gy, 124)
			if e.first then kit.pop_in(tile, 0.12 + i * 0.07, 0.35) end
		end
	end
	if v.moves then
		kit.caption(e, body, i18n.t("common.moves", { n = v.moves }), 0, gy - 94, { size = 24, color = "text_soft" })
	end

	-- boosters
	y = gy - 150
	kit.section(e, body, i18n.t("start.boosters"), 0, y, W - 80)
	local by = y - 118
	for i, slot in ipairs(v.boosters) do
		booster_slot(e, body, slot, (i - 2) * 186, by, v)
	end
	local any_free, any_on = false, false
	for _, slot in ipairs(v.boosters) do
		if slot.free then any_free = true end
		if st.selected[slot.id] and slot.selectable then any_on = true end
	end
	local hint
	if any_free then
		hint = i18n.t("start.free_hint")
	elseif any_on then
		local names = {}
		for _, slot in ipairs(v.boosters) do
			if st.selected[slot.id] and slot.selectable then names[#names + 1] = i18n.t("booster." .. slot.id) end
		end
		hint = i18n.t("start.selected", { name = table.concat(names, ", ") })
	else
		hint = i18n.t("start.pick_hint")
	end
	kit.caption(e, body, hint, 0, by - 132, { size = 24, color = any_free and "green" or "text_soft", max_width = W - 80 })

	-- hit streak
	local sy = by - 212
	local strip = s:round(body, 0, sy, W - 70, 96, "#F4EEFF", { radius = 30 })
	s:image(strip, "ui/icons/streak", -(W - 70) / 2 + 52, 2, { w = 70, h = 70 })
	if v.streak.active then
		s:text(strip, i18n.t("start.streak"), -(W - 70) / 2 + 100, 14, {
			font = "button", size = 26, color = "text", pivot = gui.PIVOT_W, max_width = 250,
		})
		s:text(strip, i18n.t("win.streak", { n = v.streak.count }), -(W - 70) / 2 + 100, -20, {
			font = "small", size = 20, color = "text_soft", pivot = gui.PIVOT_W, max_width = 250,
		})
		kit.notes(e, strip, 176, 2, v.streak.notes, 54, 60)
	else
		s:text(strip, i18n.t("start.streak_from", { n = config.streak.from_level }), 30, 2, {
			font = "button", size = 24, color = "text_soft", max_width = W - 220,
		})
	end

	-- what a loss costs
	local ly = sy - 84
	if v.life_cost then
		local heart = kit.icon(e, body, "ui/icons/heart", -150, ly, 40, "pink")
		s:text(body, i18n.t("start.life_cost"), -122, ly, { font = "button", size = 24, color = "pink", pivot = gui.PIVOT_W, max_width = 330 })
		if not kit.reduced() then require("client.ui").pulse(heart, 0.1, 0.6) end
	else
		s:text(body, i18n.t("start.safe"), 0, ly, { font = "button", size = 24, color = "green", max_width = W - 80 })
	end

	-- Play
	local py = -hh + 88
	local pb = s:button({ parent = body, x = 0, y = py, w = 420, h = 124, style = "green", text = i18n.t("start.play"),
		text_size = 54, enabled = not e.busy, on_click = function() play(e, v) end })
	e.play_btn = pb
	e:target("play", 0, py)
	if not kit.reduced() and not e.busy then require("client.ui").pulse(pb.node, 0.035, 0.8) end
end

function M.update(e, dt)
	kit.update_bit(e, dt)
end

function M.on_event(e, topic)
	if topic == "lives_tick" and e.view and not e.view.can_start and e.view.why == "no_lives" then
		if app.meta:can_start(e.view.level, app.now()) then e:rebuild() end
	end
end

return M
