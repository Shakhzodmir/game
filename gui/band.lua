-- The band window (WP-11, "Группа" in the bottom bar): a team of up to 20 players with a weekly goal in stars.
-- No chat. Roles: leader (can remove a member; leadership passes to the member who joined first when the leader
-- leaves) and member. Join with the 6-letter code (read from the clipboard / a prompt), create a band with a
-- suggested name (lists of words, no typing), invite = copy the code, leave with a confirmation.
-- Help with lives: ask for a life; a mate who sees the heart sends one; the lives arrive when the window opens.
-- The member list scrolls with the wheel and the arrows (the rows are buttons for the leader: a drag must not tap them).
-- Rules and limits: meta/social.lua (the server applies them), actions: client/social.lua.
-- State for QA: app.ui.band = {stage, count, stars, goal, code, you, first}; targets: create, join, create_ok,
-- reroll_band, back, invite, leave, ask_life, help_<n>, kick_<n>, up, down, signin, retry, close.

local app = require("client.app")
local i18n = require("client.i18n")
local platform = require("client.platform")
local rules = require("meta.social")
local service = require("client.services.social")
local social = require("client.social")
local kit = require("gui.kit")
local sk = require("gui.social_kit")

local M = {}

local W, H = 640, 1120
local ROW_H, VISIBLE = 90, 5
local WHEEL_UP, WHEEL_DOWN = hash("wheel_up"), hash("wheel_down")

local function list_top(hh) return hh - 345 end

local function publish(e)
	local st = e.state
	local b = st.band
	app.ui.band = {
		stage = st.stage, count = b and b.count or 0, stars = b and b.stars or 0, goal = b and b.goal or 0,
		code = b and b.code or nil, you = b and b.you or nil, first = st.sc and st.sc.first or 1,
	}
end

local function toast_err(reason)
	local key = "social.err." .. tostring(reason)
	app.toast_key(i18n.has(key) and key or "social.err.error", nil, { color = "pink" })
end

local function failed(e, reason)
	local st = e.state
	st.requested = false
	if reason == "no_profile" then st.stage = "setup"
	elseif reason == "signin" or reason == "unavailable" then st.stage = reason
	elseif reason == "offline" or reason == "timeout" then st.stage = "offline"
	else st.stage, st.reason = "error", reason end
	e:rebuild()
end

local function show(e, band)
	local st = e.state
	st.requested = false
	st.band = band
	st.stage = band and "ready" or "none"
	if band then sk.scroll_set(st.sc, #band.members) end
	e:rebuild()
end

local function load_band(e)
	service.band_get(function(ok, reason, band)
		if e.closing then return end
		if not ok then return failed(e, reason) end
		show(e, band)
		if band then
			social.claim_help(function() end) -- lives band mates sent while the player was away
		end
	end)
end

local function fetch(e)
	local st = e.state
	st.requested = true
	social.prepare(function(stage)
		if e.closing then return end
		if stage == "ready" then return load_band(e) end
		st.requested = false
		st.stage = stage
		e:rebuild()
	end)
end

-- An action that answers with the band (or nothing): errors are toasts, the window shows the result.
local function act(e, op, ...)
	local args, n = { ... }, select("#", ...)
	args[n + 1] = function(ok, reason, data)
		if e.closing then return end
		if not ok then
			toast_err(reason)
			if reason == "offline" or reason == "signin" then return failed(e, reason) end
			return load_band(e) -- the server's state wins (someone else changed the band meanwhile)
		end
		if op == "band_leave" then return show(e, nil) end
		if op == "band_create" or op == "band_join" or op == "band_kick" then return show(e, data) end
		load_band(e)
	end
	service[op](unpack(args, 1, n + 1))
end

local function message(e, body, key, button)
	local s = e.ui
	kit.glow(e, body, 0, 130, 300, "purple", 0.18)
	kit.icon(e, body, "ui/icons/team", 0, 170, 150, "purple")
	sk.note(e, body, i18n.t(key), 0, -20, 500, 32, "text", 220)
	if button then
		s:button({ parent = body, x = 0, y = -230, w = 420, h = 100, style = button.style or "green", text = button.text,
			text_size = 34, on_click = button.fn })
		e:target(button.id, 0, -230)
	end
end

local function invite(e, band)
	local text = i18n.t("band.invite_text", { code = band.code })
	local how = platform.copy_text(text, i18n.t("band.prompt_copy"))
	if how == "clipboard" then app.toast_key("band.copied", nil, { color = "gold" })
	elseif how == "prompt" then app.toast_key("band.shown", nil, { color = "blue" })
	else app.toast_key("band.copy_failed", nil, { color = "pink" }) end
end

local function join(e)
	local text = platform.paste_text(i18n.t("band.prompt_code"))
	if not text or text == "" then return app.toast_key("social.err.bad_code", nil, { color = "pink" }) end
	local code = rules.normalize_code(text)
	-- an invitation text holds the code among words: take the last six-letter word that is a valid code
	if not rules.valid_code(code) then
		for word in tostring(text):gmatch("%w+") do
			local w = rules.normalize_code(word)
			if rules.valid_code(w) then code = w end
		end
	end
	act(e, "band_join", code)
end

local function draw_members(e, body, hh)
	local s, st = e.ui, e.state
	local band, sc = st.band, st.sc
	local top = list_top(hh)
	for i = 0, VISIBLE - 1 do
		local idx = sc.first + i
		local m = band.members[idx]
		if not m then break end
		local y = top - ROW_H / 2 - i * ROW_H
		local help = m.help and not m.me
		local extra = i18n.t(m.role == "leader" and "band.leader" or "band.member")
		if m.help then extra = i18n.t("band.needs_life") end
		sk.row(e, body, -35, y, m, { w = 520, h = ROW_H, rank = false, extra = extra, no_district = false,
			help_fn = help and function() act(e, "help_send", m.uid) end or nil, help_target = help and ("help_" .. idx) or nil })
		if band.you == "leader" and not m.me and not help then
			local hit = s:button({ parent = body, x = -35, y = y, w = 520, h = ROW_H - 8, style = "white", sfx = "tap",
				on_click = function()
					e:open("confirm", { title = { key = "band.kick_title" }, text = { key = "band.kick_text" },
						icon = "ui/icons/team", h = 700, confirm = { text = { key = "band.kick_do" }, style = "pink" },
						on_confirm = function() act(e, "band_kick", m.uid) end })
				end })
			gui.set_color(hit.node, vmath.vector4(1, 1, 1, 0))
			e:target("kick_" .. idx, -35, y)
		end
	end
	local function mover(d) return function() if sk.scroll_by(sc, d) then e:rebuild() end end end
	if sc.first > 1 then sk.arrow(e, body, 270, top - 60, 1, mover(-VISIBLE + 1), "up") end
	if sc.first + VISIBLE <= #band.members then
		sk.arrow(e, body, 270, top - ROW_H * VISIBLE + 60, -1, mover(VISIBLE - 1), "down")
	end
end

local function draw_band(e, body, hh)
	local s, st = e.ui, e.state
	local b = st.band
	s:text(body, social.name_text(b.name), 0, hh - 140, { font = "button", size = 40, color = "purple", max_width = 500 })
	kit.caption(e, body, i18n.t("band.code", { code = b.code }) .. "  -  " .. i18n.t("band.members", { n = b.count, max = b.max }),
		0, hh - 190, { size = 24, max_width = 580 })
	-- the weekly goal bar
	local frac = math.max(0, math.min(1, b.goal > 0 and b.stars / b.goal or 0))
	s:round(body, 0, hh - 240, 520, 40, "#E3D9FF", { radius = 20 })
	if frac > 0 then
		local w = math.max(40, 520 * frac)
		s:round(body, -260 + w / 2, hh - 240, w, 40, b.stars >= b.goal and "gold" or "green", { radius = 20 })
	end
	kit.caption(e, body, i18n.t(b.stars >= b.goal and "band.goal_done" or "band.goal", { n = b.stars, goal = b.goal }),
		-260, hh - 285, { size = 24, pivot = gui.PIVOT_W, max_width = 330 })
	kit.caption(e, body, social.left_text(b.week_end - app.now()), 260, hh - 285, { size = 22, pivot = gui.PIVOT_E, max_width = 190 })
	if b.stars >= b.goal and not st.cheered and not kit.reduced() then
		st.cheered = true
		e:later(0.4, function() e.fx:burst(0, hh - 240, { count = 18, radius = 200, size = 34, parent = body }) end)
	end
	draw_members(e, body, hh)
	local me
	for _, m in ipairs(b.members) do if m.me then me = m end end
	if me and me.help then
		kit.caption(e, body, i18n.t("band.waiting_help"), 0, -hh + 190, { size = 24, max_width = 560 })
	elseif me then
		s:button({ parent = body, x = 0, y = -hh + 190, w = 440, h = 80, style = "pink", icon = "ui/icons/heart", icon_size = 44,
			text = i18n.t("band.ask_life"), text_size = 28, on_click = function() act(e, "help_request") end })
		e:target("ask_life", 0, -hh + 190)
	end
	s:button({ parent = body, x = -150, y = -hh + 90, w = 270, h = 84, style = "blue", text = i18n.t("band.invite"), text_size = 30,
		on_click = function() invite(e, b) end })
	e:target("invite", -150, -hh + 90)
	s:button({ parent = body, x = 150, y = -hh + 90, w = 270, h = 84, style = "pink", text = i18n.t("band.leave"), text_size = 30,
		on_click = function()
			e:open("confirm", { title = { key = "band.leave_title" },
				text = { key = b.you == "leader" and "band.leave_leader" or "band.leave_text" },
				icon = "ui/icons/team", h = 700, confirm = { text = { key = "band.leave" }, style = "pink" },
				on_confirm = function() act(e, "band_leave") end })
		end })
	e:target("leave", 150, -hh + 90)
end

function M.build(e)
	local s, st = e.ui, e.state
	if st.stage == nil then st.stage, st.sc = "loading", sk.scroll_new(VISIBLE) end
	local body, hh = kit.panel(e, W, H, { title = { key = "band.title" }, fit = true })
	local stage = st.stage
	if stage == "loading" then
		message(e, body, "band.loading")
		if not st.requested then e:later(0.05, function() fetch(e) end) end
	elseif stage == "unavailable" then
		message(e, body, "band.unavailable")
	elseif stage == "signin" then
		message(e, body, "band.signin", { id = "signin", text = i18n.t("chart.signin_button"), fn = function() e:open("account") end })
	elseif stage == "offline" or stage == "error" then
		message(e, body, stage == "offline" and "chart.offline" or "chart.error", { id = "retry", text = i18n.t("common.retry"),
			style = "blue", fn = function() st.stage, st.requested = "loading", false; e:rebuild() end })
	elseif stage == "setup" then
		sk.profile_editor(e, body, hh, st, function(name, avatar)
			social.save_profile(name, avatar, function(ok, reason)
				if e.closing then return end
				if not ok then toast_err(reason) end
				st.stage, st.requested = "loading", false
				e:rebuild()
			end)
		end)
	elseif stage == "none" then
		kit.glow(e, body, 0, 250, 300, "purple", 0.18)
		kit.icon(e, body, "ui/icons/team", 0, 280, 150, "purple")
		sk.note(e, body, i18n.t("band.none"), 0, 80, 520, 30, "text", 220)
		s:button({ parent = body, x = 0, y = -120, w = 460, h = 100, style = "green", text = i18n.t("band.create"), text_size = 34,
			on_click = function() st.stage, st.bk = "create", st.bk or 0; e:rebuild() end })
		e:target("create", 0, -120)
		s:button({ parent = body, x = 0, y = -250, w = 460, h = 100, style = "blue", text = i18n.t("band.join"), text_size = 34,
			on_click = function() join(e) end })
		e:target("join", 0, -250)
		sk.note(e, body, i18n.t("band.join_hint"), 0, -380, 520, 22, "text_soft", 100)
	elseif stage == "create" then
		local name = rules.suggest_band_name(st.bk)
		sk.note(e, body, i18n.t("band.create_text"), 0, 330, 540, 28, "text", 160)
		local pill = s:round(body, 0, 170, 540, 120, "#F6F2FF", { radius = 40 })
		s:text(pill, social.name_text(name), 0, 2, { font = "button", size = 42, color = "purple", max_width = 480 })
		s:button({ parent = body, x = 0, y = 40, w = 400, h = 88, style = "blue", text = i18n.t("band.other_name"), text_size = 30,
			sfx = "tap", on_click = function() st.bk = st.bk + 1; e:rebuild() end })
		e:target("reroll_band", 0, 40)
		s:button({ parent = body, x = 0, y = -110, w = 420, h = 100, style = "green", text = i18n.t("band.create_do"), text_size = 34,
			on_click = function() act(e, "band_create", name) end })
		e:target("create_ok", 0, -110)
		s:button({ parent = body, x = 0, y = -230, w = 300, h = 84, style = "white", text = i18n.t("common.back"), text_size = 28,
			on_click = function() st.stage = "none"; e:rebuild() end })
		e:target("back", 0, -230)
	else
		draw_band(e, body, hh)
	end
	publish(e)
end

function M.on_input(e, action_id, action)
	local st = e.state
	if st.stage ~= "ready" then return false end
	local moved
	if action_id == WHEEL_UP then moved = sk.scroll_by(st.sc, -1)
	elseif action_id == WHEEL_DOWN then moved = sk.scroll_by(st.sc, 1)
	end
	if moved then e:rebuild() end
	return false
end

function M.on_event(e, topic)
	local st = e.state
	if topic == "auth_changed" and st.stage ~= "unavailable" then
		st.stage, st.requested, st.band = "loading", false, nil
		e:rebuild()
	end
end

return M
