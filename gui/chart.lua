-- The chart window (WP-11, "Чарт" in the bottom bar): the ranking of players by stars. Three views: this week
-- (stars won since Monday, capped), all time, and my band. Top 100, my row pinned at the bottom, the list scrolls
-- by rows (drag, wheel, arrows). When my rank rose since the last look the pinned row counts it up with a burst.
-- Without a server or without a signed-in account the window says so (a screen with a sign-in button), no error.
-- Actions: client/social.lua, service: client/services/social.lua, rules: meta/social.lua.
-- State for QA: app.ui.chart = {stage, period, rows, first, rank, climb}; targets: period_<id>, up, down, signin,
-- retry, rename, close, and the profile editor's reroll / avatar_<n> / save.

local app = require("client.app")
local i18n = require("client.i18n")
local audio = require("client.audio")
local rules = require("meta.social")
local service = require("client.services.social")
local social = require("client.social")
local kit = require("gui.kit")
local sk = require("gui.social_kit")

local M = {}

local W, H = 640, 1120
local ROW_H, VISIBLE = 90, 6
local LIST_TOP = 325 -- centre y of the first list row is LIST_TOP - ROW_H / 2 below the panel centre
local ROW_W = 520
local WHEEL_UP, WHEEL_DOWN = hash("wheel_up"), hash("wheel_down")

local PERIOD_KEYS = { week = "chart.week", all = "chart.all", band = "chart.band" }

local function publish(e)
	local st = e.state
	local sc = st.sc
	app.ui.chart = {
		stage = st.stage, period = st.period, rows = st.data and #st.data.rows or 0, first = sc and sc.first or 1,
		rank = st.data and st.data.me and st.data.me.rank or nil, climb = st.climb and st.climb.to or nil,
		count = st.data and st.data.count or 0,
	}
end

local fetch

local function failed(e, reason)
	local st = e.state
	st.requested = false
	if reason == "no_profile" then st.stage = "setup"
	elseif reason == "signin" or reason == "unavailable" then st.stage = reason
	elseif reason == "offline" or reason == "timeout" then st.stage = "offline"
	else st.stage, st.reason = "error", reason end
	e:rebuild()
end

local function load_chart(e)
	local st = e.state
	service.chart(st.period, function(ok, reason, data)
		if e.closing then return end
		if not ok then return failed(e, reason) end
		st.requested = false
		st.data = data
		st.stage = "ready"
		sk.scroll_set(st.sc, #data.rows)
		-- the rank rose since the player last looked: the climb plays once per data load
		local me = data.me
		st.climb = nil
		if me and me.rank and me.prev_rank and me.rank < me.prev_rank then
			st.climb = { from = me.prev_rank, to = me.rank, gained = me.prev_rank - me.rank }
		end
		e:rebuild()
	end)
end

fetch = function(e, full)
	local st = e.state
	st.requested = true
	if not full then return load_chart(e) end
	social.prepare(function(stage)
		if e.closing then return end
		if stage ~= "ready" then
			st.requested = false
			if stage == "setup" then st.stage = "setup" elseif stage == "offline" then st.stage = "offline"
			elseif stage == "error" then st.stage = "error" else st.stage = stage end
			return e:rebuild()
		end
		load_chart(e)
	end)
end

local function message(e, body, key, vars, button)
	local s = e.ui
	kit.glow(e, body, 0, 130, 300, "purple", 0.18)
	kit.icon(e, body, "ui/icons/chart", 0, 170, 150, "purple")
	sk.note(e, body, i18n.t(key, vars), 0, -20, 500, 32, "text", 220)
	if button then
		s:button({ parent = body, x = 0, y = -230, w = 420, h = 100, style = button.style or "green", text = button.text,
			text_size = 34, on_click = button.fn })
		e:target(button.id, 0, -230)
	end
end

local function draw_list(e, body)
	local s, st = e.ui, e.state
	local data = st.data
	local rows = data.rows
	local sc = st.sc
	if #rows == 0 then
		sk.note(e, body, i18n.t(data.no_band and "chart.no_band" or "chart.empty"), 0, 60, 500, 30, "text_soft", 200)
		return
	end
	for i = 0, VISIBLE - 1 do
		local r = rows[sc.first + i]
		if not r then break end
		sk.row(e, body, -35, LIST_TOP - ROW_H / 2 - i * ROW_H, r, { w = ROW_W, h = ROW_H })
	end
	local can_up, can_down = sc.first > 1, sc.first + VISIBLE <= #rows
	local function mover(d) return function() if sk.scroll_by(sc, d) then e:rebuild() end end end
	if can_up then sk.arrow(e, body, 270, LIST_TOP - 60, 1, mover(-VISIBLE + 1), "up") end
	if can_down then sk.arrow(e, body, 270, LIST_TOP - ROW_H * VISIBLE + 60, -1, mover(VISIBLE - 1), "down") end
end

local function draw_me(e, body, hh)
	local s, st = e.ui, e.state
	local me = st.data.me
	if not me then return end
	local y = -hh + 235
	if me.hidden then
		sk.note(e, body, i18n.t("chart.checking"), 0, y, 560, 24, "pink", 90)
		return
	end
	local _, rank_node, info = sk.row(e, body, 0, y, me, { w = 580, h = 100 })
	local cl = st.climb
	if cl then
		local ax, ay = 262, y + 50
		local chip = s:round(body, ax, ay, 150, 44, "green", { radius = 22 })
		local arrow = s:image(chip, "ui/icons/arrow", -42, 0, { w = 28, h = 28 })
		if arrow then gui.set_euler(arrow, vmath.vector3(0, 0, 90)) end
		s:text(chip, "+" .. cl.gained, 14, 2, { font = "number", size = 28, color = "white", outline = "#0F7A3B", max_width = 80 })
		if not cl.played then
			cl.played = true
			if rank_node and not kit.reduced() then
				s:set_text(rank_node, tostring(cl.from), info)
				e:later(0.5, function()
					e.fx:count(cl.from, cl.to, 1.1, function(v) s:set_text(rank_node, tostring(v), info) end)
					audio.sfx("unlock")
				end)
				e:later(1.65, function()
					local x, yy = 0, y
					e.fx:burst(x - 200, yy, { count = 16, radius = 120, size = 30, parent = body })
					e.fx:pop(rank_node, 0.3, 0.4)
					audio.sfx("star")
				end)
				kit.pop_in(chip, 0.5)
			end
		end
	end
end

function M.build(e)
	local s, st = e.ui, e.state
	if st.stage == nil then
		st.stage, st.period, st.sc = "loading", "week", sk.scroll_new(VISIBLE)
	end
	local body, hh = kit.panel(e, W, H, { title = { key = "chart.title" }, fit = true })
	if st.stage == "loading" then
		message(e, body, "chart.loading")
		if not st.requested then e:later(0.05, function() fetch(e, true) end) end
	elseif st.stage == "unavailable" then
		message(e, body, "chart.unavailable")
	elseif st.stage == "signin" then
		message(e, body, "chart.signin", nil, { id = "signin", text = i18n.t("chart.signin_button"),
			fn = function() e:open("account") end })
	elseif st.stage == "offline" or st.stage == "error" then
		message(e, body, st.stage == "offline" and "chart.offline" or "chart.error", nil, { id = "retry",
			text = i18n.t("common.retry"), style = "blue", fn = function() st.stage = "loading"; st.requested = false; e:rebuild() end })
	elseif st.stage == "setup" then
		sk.profile_editor(e, body, hh, st, function(name, avatar)
			social.save_profile(name, avatar, function(ok, reason)
				if e.closing then return end
				if not ok then app.toast_key("social.err." .. tostring(reason), nil, { color = "pink" }) end
				st.stage, st.requested = "loading", false
				e:rebuild()
			end)
		end)
	else
		local options = {}
		for _, p in ipairs(rules.PERIODS) do options[#options + 1] = { id = p, text = i18n.t(PERIOD_KEYS[p]) } end
		kit.segmented(e, body, 0, hh - 140, 560, options, st.period, function(id)
			st.period, st.stage, st.requested, st.climb = id, "loading", false, nil
			st.sc.first = 1
			e:rebuild()
		end, { targets = "period", text_size = 26, h = 76 })
		local info
		if st.period == "all" or not st.data.week_end then
			info = i18n.t("chart.players", { n = st.data.count })
		else
			info = i18n.t("chart.week_left", { time = social.left_text(st.data.week_end - app.now()) })
		end
		kit.caption(e, body, info, 0, hh - 215, { size = 24, max_width = 560 })
		e.list_parent = body
		e.list_layer = s:layer(body, "chart_list")
		draw_list(e, e.list_layer)
		draw_me(e, body, hh)
		s:button({ parent = body, x = 0, y = -hh + 90, w = 360, h = 84, style = "white", text = i18n.t("chart.rename"),
			text_size = 28, on_click = function() st.stage, st.requested = "setup", false; st.avatar = nil; e:rebuild() end })
		e:target("rename", 0, -hh + 90)
	end
	publish(e)
end

-- The list alone is drawn again while it scrolls (a full rebuild waits for the finger to lift).
local function redraw(e)
	if not e.list_layer then return end
	e.ui:clear(e.list_layer)
	e.list_layer = e.ui:layer(e.list_parent, "chart_list")
	draw_list(e, e.list_layer)
	publish(e)
end

-- scrolling: the wheel anywhere, a drag over the list
function M.on_input(e, action_id, action)
	local st = e.state
	if st.stage ~= "ready" then return false end
	local moved
	if action_id == WHEEL_UP then moved = sk.scroll_by(st.sc, -1)
	elseif action_id == WHEEL_DOWN then moved = sk.scroll_by(st.sc, 1)
	elseif action_id == kit.TOUCH or action_id == nil then
		local lx, ly = e.ui:logical(action)
		if action_id == kit.TOUCH and action.pressed then
			local ax, ay = e:abs(0, 0)
			local k = e.fit_k or 1
			st.drag = { y = ly, in_list = (lx - ax) / k > -295 and (lx - ax) / k < 225 and (ly - ay) / k < LIST_TOP
				and (ly - ay) / k > LIST_TOP - ROW_H * VISIBLE }
		elseif st.drag then
			if st.drag.in_list then moved = sk.scroll_drag(st.sc, (ly - st.drag.y) / (e.fit_k or 1), ROW_H) end
			st.drag.y = ly
			if action_id == kit.TOUCH and action.released then st.drag = nil end
		end
		if moved then redraw(e) end
		return false
	end
	if moved then redraw(e) end
	return moved and true or false
end

function M.on_event(e, topic)
	local st = e.state
	if topic == "auth_changed" and (st.stage == "signin" or st.stage == "ready" or st.stage == "setup") then
		st.stage, st.requested, st.data = "loading", false, nil
		e:rebuild()
	end
end

return M
