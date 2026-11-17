-- Settings: music and sound volumes (sliders: heard live while dragging,
-- saved on release), vibration, reduced motion, controls (swipe / tap-tap),
-- language (auto / English / Russian / Korean), the account (a guest sees a green "Sign in / Create account"
-- button, a signed-in player a row with the account; both open gui/account.lua), the save code rows (copy it, or enter
-- one and replace the progress after a confirmation: hidden since the cloud save, shown by five taps on the version or by
-- params.codes), reset progress (with a confirmation)
-- and the version. Every value goes through app.set_setting (the meta
-- validates it, the save follows).

local app = require("client.app")
local i18n = require("client.i18n")
local views = require("client.views")
local audio = require("client.audio")
local platform = require("client.platform")
local kit = require("gui.kit")
local account = require("client.account")
local auth = require("client.services.auth")

local M = {}

local W = 640
local H_BASE = 1264            -- without the save code rows
local H_CODES = H_BASE + 232   -- with them (a caption and two rows)

-- The choices come from the meta's config (views.settings); these are their labels. A choice the meta
-- offers that has no label yet (a new language needs its strings first) is left out.
local INPUT_LABELS = { swipe = "settings.input_swipe", taptap = "settings.input_taptap" }
local LANGUAGE_LABELS = { auto = "settings.lang_auto", en = "settings.lang_en", ru = "settings.lang_ru", ko = "settings.lang_ko" }

local function options(ids, labels)
	local out = {}
	for _, id in ipairs(ids) do
		if labels[id] then out[#out + 1] = { id = id, text = i18n.t(labels[id]) } end
	end
	return out
end

-- Layout (window coordinates, 0 at the centre): the cards of the UI pack hold the rows, the inner edge of a card is +-CARD_W / 2.
local CARD_W = 584
local LEFT = -CARD_W / 2

local function card(e, body, y_top, h)
	local s = e.ui
	local cy = y_top - h / 2
	s:round(body, 0, cy, CARD_W + 4, h + 4, "#E7DDF2", { radius = 38 })
	s:round(body, 0, cy, CARD_W, h, "#F5EEFF", { radius = 36 })
end

-- a small purple caption at the left edge of a card or a block
local function caption(e, body, text, y)
	e.ui:text(body, text, LEFT + 34, y, { font = "button", size = 24, color = "purple", pivot = gui.PIVOT_W, max_width = 420 })
end

local function row_label(e, body, icon, text, y)
	local s = e.ui
	kit.icon(e, body, icon, LEFT + 62, y, 56, "lavender")
	s:text(body, text, LEFT + 104, y, { font = "button", size = 28, color = "text", pivot = gui.PIVOT_W, max_width = 280 })
end

local function volume_row(e, body, key, text_key, icon_on, icon_off, y, value)
	local s = e.ui
	local icon = kit.icon(e, body, value > 0 and icon_on or icon_off, LEFT + 62, y, 56, "lavender")
	s:text(body, i18n.t(text_key), LEFT + 104, y, { font = "button", size = 28, color = "text", pivot = gui.PIVOT_W, max_width = 140 })
	local sx, sw = 96, 270
	kit.slider(e, body, sx, y, sw, value, function(v)
		local st = views.settings(app.meta)
		if key == "music" then audio.set_volumes(v, st.sfx) else audio.set_volumes(st.music, v) end
	end, function(v)
		v = math.floor(v * 20 + 0.5) / 20
		app.set_setting(key, v)
		if key == "sfx" then kit.sfx("tap") end
		local ic = s:image(body, v > 0 and icon_on or icon_off, LEFT + 62, y, { w = 56, h = 56 })
		if ic then
			e.ui:clear(icon)
			icon = ic
		end
	end, { color = "purple", target = "slider_" .. key })
end

-- a wide row button: the icon and the text on the left, a chevron on the right (the pack's "Guest" / "Copy the save code" rows)
local function row_button(e, body, y, icon, text, on_click, target)
	local s = e.ui
	local b = s:button({ parent = body, x = 0, y = y, w = CARD_W, h = 84, style = "white", on_click = on_click })
	local ic = icon and s:image(b.node, icon, LEFT + 54, 4, { w = 50, h = 50 })
	s:text(b.node, text, LEFT + (ic and 98 or 36), 5, {
		font = "button", size = 28, color = "text", pivot = gui.PIVOT_W, max_width = CARD_W - 190,
	})
	s:image(b.node, "ui/icons/chevron", -LEFT - 44, 4, { w = 30, h = 30 })
	if target then e:target(target, 0, y) end
	return b
end

local function reset(e)
	e:open("confirm", {
		title = { key = "settings.reset_title" },
		text = { key = "settings.reset_text" },
		confirm = { text = { key = "settings.reset_do" }, style = "pink" },
		on_confirm = function()
			app.reset_save(platform.random_seed(), app.now())
			app.toast_key("settings.reset_done", nil, { color = "pink" })
			app.show_screen("splash", { from = "reset" })
		end,
	})
end

-- save code ---------------------------------------------------------------------------------

local CODE_ERRORS = {
	empty = "code.empty", prefix = "code.err_prefix", version = "code.err_version", format = "code.err_damaged",
	checksum = "code.err_damaged", corrupt = "code.err_damaged", too_long = "code.err_damaged", bad_save = "code.err_bad_save",
}
M.CODE_ERRORS = CODE_ERRORS

function M.copy_code()
	local code = app.export_code()
	if not code then
		app.toast_key("code.copy_failed", nil, { color = "pink" })
		return false
	end
	local how = platform.copy_text(code, i18n.t("code.prompt_copy"))
	if how == "clipboard" then
		app.toast_key("code.copied", nil, { color = "gold" })
	elseif how == "prompt" then
		app.toast_key("code.shown", nil, { color = "blue" })
	else
		app.toast_key("code.copy_failed", nil, { color = "pink" })
		return false
	end
	return true
end

-- What the confirmation says about a code: its levels, coins and stars, a warning when it holds less.
function M.code_text(sum, behind, now)
	local lines = {
		{ key = "code.confirm_levels", vars = { n = sum.beaten } },
		{ key = "code.confirm_coins", vars = { n = i18n.number(sum.coins) } },
		{ key = "code.confirm_stars", vars = { n = sum.stars } },
	}
	if behind then lines[#lines + 1] = { key = "code.confirm_behind", vars = { n = now and now.beaten or 0 } } end
	lines[#lines + 1] = { key = "code.confirm_keep" }
	return { lines = lines }
end

function M.enter_code(e)
	local text = platform.paste_text(i18n.t("code.prompt_paste"))
	if not text then
		app.toast_key("code.empty", nil, { color = "pink" })
		return false
	end
	local tbl, sum, behind, now = app.read_code(text)
	if not tbl then
		app.toast_key(CODE_ERRORS[sum] or "code.err_bad_save", nil, { color = "pink" })
		return false
	end
	e:open("confirm", {
		title = { key = "code.confirm_title" },
		text = M.code_text(sum, behind, now),
		icon = "ui/icons/city",
		h = 760,
		confirm = { text = { key = "code.confirm_do" }, style = behind and "pink" or "green" },
		on_confirm = function()
			local ok = app.replace_save(tbl, platform.random_seed(), app.now())
			if not ok then
				app.toast_key("code.write_failed", nil, { color = "pink" })
				return
			end
			app.toast_key("code.done", nil, { color = "gold" })
			app.show_screen("splash", { from = "import" })
		end,
	})
	return true
end

function M.build(e)
	local s = e.ui
	local v = views.settings(app.meta)
	local codes = (e.params and e.params.codes) or e.state.codes
	local body, hh = kit.panel(e, W, codes and H_CODES or H_BASE,
		{ title = { key = "settings.title" }, title_icon = "ui/icons/settings", inline_title = true, fit = true })
	local y = hh - 130

	-- sound
	card(e, body, y, 236)
	caption(e, body, i18n.t("settings.sound"), y - 30)
	volume_row(e, body, "music", "settings.music", "ui/icons/music_on", "ui/icons/music_off", y - 104, v.music)
	volume_row(e, body, "sfx", "settings.sfx", "ui/icons/sound_on", "ui/icons/sound_off", y - 188, v.sfx)

	-- game
	y = y - 236 - 16
	card(e, body, y, 322)
	caption(e, body, i18n.t("settings.game"), y - 30)
	row_label(e, body, "ui/icons/haptics", i18n.t("settings.haptics"), y - 102)
	kit.toggle(e, body, 206, y - 102, v.haptics, function(on)
		e.self_key = "haptics"
		app.set_setting("haptics", on)
		if on then pcall(platform.vibrate, 30) end
	end, "haptics")
	row_label(e, body, "ui/icons/city", i18n.t("settings.reduced_motion"), y - 186)
	kit.toggle(e, body, 206, y - 186, v.reduced_motion, function(on)
		e.self_key = "reduced_motion"
		app.set_setting("reduced_motion", on)
	end, "reduced_motion")
	s:text(body, i18n.t("settings.input_mode"), LEFT + 34, y - 272, { font = "button", size = 28, color = "text", pivot = gui.PIVOT_W, max_width = 200 })
	kit.segmented(e, body, 112, y - 272, 300, options(v.input_modes, INPUT_LABELS), v.input_mode, function(id)
		app.set_setting("input_mode", id)
		e:rebuild()
	end, { h = 66, text_size = 26, targets = "input", track = "#E9DDFB" })

	-- language
	y = y - 322 - 14
	caption(e, body, i18n.t("settings.language"), y - 16)
	kit.segmented(e, body, 0, y - 76, CARD_W, options(v.languages, LANGUAGE_LABELS), v.language, function(id)
		app.set_setting("language", id) -- the host rebuilds every window on language_changed
		e:rebuild()
	end, { h = 72, text_size = 26, targets = "lang" })

	-- account and cloud save (WP-10): a guest gets one clear green button, a signed-in player a row with the
	-- account; the window it opens has sign out, link Google / e-mail and the rest
	y = y - 130
	if auth.user() then
		row_button(e, body, y - 42, "ui/icons/team", i18n.tr(account.who_spec()), function() e:open("account") end, "account")
		y = y - 84
	else
		s:button({ parent = body, x = 0, y = y - 48, w = CARD_W, h = 96, style = "green", icon = "ui/icons/team", icon_size = 54,
			text = i18n.t("settings.login"), text_size = 28, on_click = function() e:open("account") end })
		e:target("account", 0, y - 48)
		s:text(body, i18n.t("settings.guest_note"), 0, y - 96 - 32, { font = "small", size = 22, color = "text_soft",
			width = CARD_W - 40, height = 56 })
		y = y - 96 - 60
	end

	-- the privacy policy: a page of the site, opened in a new tab (web only; elsewhere nothing happens)
	row_button(e, body, y - 52, "ui/icons/lock", i18n.t("privacy.link"), function() account.open_privacy() end, "privacy")
	y = y - 94

	-- save code: the progress lives in the cloud now, so the two rows are hidden (five taps on the version show them)
	if codes then
		y = y - 18
		caption(e, body, i18n.t("settings.code_section"), y - 12)
		row_button(e, body, y - 82, "ui/icons/copy", i18n.t("settings.code_copy"), function() M.copy_code() end, "code_copy")
		row_button(e, body, y - 82 - 94, "ui/icons/import", i18n.t("settings.code_enter"), function() M.enter_code(e) end, "code_enter")
	end

	-- reset + version: a pale pink row, not a loud button
	local ry = -hh + 92
	s:round(body, 0, ry, CARD_W + 4, 84, "#F7C9D8", { radius = 40 })
	local rb = s:button({ parent = body, x = 0, y = ry, w = CARD_W, h = 80, style = "flat", flat_color = "#FFF0F5",
		on_click = function() reset(e) end })
	local label = i18n.t("settings.reset")
	local tw = math.min(kit.text_width("button", label, 28), 380)
	s:image(rb.node, "ui/icons/reset", -tw / 2 - 30, 3, { w = 44, h = 44 })
	s:text(rb.node, label, 22, 4, { font = "button", size = 28, color = "#E4527D", max_width = 400 })
	e:target("reset", 0, ry)
	s:text(body, i18n.t("settings.version", { v = app.VERSION }), 0, -hh + 30, { font = "small", size = 20, color = "text_soft" })
	-- five taps on the version show / hide the save code rows (for the producer's QA codes and for support)
	local vb = s:button({ parent = body, x = 0, y = -hh + 34, w = 260, h = 66, style = "white", sfx = false, on_click = function()
		e.state.taps = (e.state.taps or 0) + 1
		if e.state.taps >= 5 then
			e.state.taps = 0
			e.state.codes = not e.state.codes
			e:rebuild()
		end
	end })
	gui.set_color(vb.node, vmath.vector4(1, 1, 1, 0))
	e:target("version", 0, -hh + 34)
end

function M.on_input(e, action_id, action)
	return kit.slider_input(e, action_id, action)
end

-- The settings may change from elsewhere (a debug key): redraw.
function M.on_event(e, topic, p)
	if topic ~= "settings_changed" or e.dragging or not p then return end
	if p.key == e.self_key then
		e.self_key = nil
		return
	end
	if p.key ~= "music" and p.key ~= "sfx" and p.key ~= "language" then e:rebuild() end
end

return M
