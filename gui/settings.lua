-- Settings: music and sound volumes (sliders: heard live while dragging,
-- saved on release), vibration, reduced motion, controls (swipe / tap-tap),
-- language (auto / English / Russian), reset progress (with a confirmation)
-- and the version. Every value goes through app.set_setting (the meta
-- validates it, the save follows).

local app = require("client.app")
local i18n = require("client.i18n")
local views = require("client.views")
local audio = require("client.audio")
local platform = require("client.platform")
local kit = require("gui.kit")

local M = {}

local W, H = 640, 1100

local function row_label(e, body, icon, text, y)
	local s = e.ui
	kit.icon(e, body, icon, -W / 2 + 76, y, 60, "lavender")
	s:text(body, text, -W / 2 + 118, y, { font = "button", size = 28, color = "text", pivot = gui.PIVOT_W, max_width = 230 })
end

local function volume_row(e, body, key, icon_on, icon_off, y, value)
	local s = e.ui
	local icon = kit.icon(e, body, value > 0 and icon_on or icon_off, -W / 2 + 76, y, 60, "lavender")
	s:text(body, i18n.t("settings." .. key), -W / 2 + 118, y, { font = "button", size = 28, color = "text", pivot = gui.PIVOT_W, max_width = 150 })
	local sx, sw = 128, 300
	kit.slider(e, body, sx, y, sw, value, function(v)
		local st = views.settings(app.meta)
		if key == "music" then audio.set_volumes(v, st.sfx) else audio.set_volumes(st.music, v) end
	end, function(v)
		v = math.floor(v * 20 + 0.5) / 20
		app.set_setting(key, v)
		if key == "sfx" then kit.sfx("tap") end
		local ic = s:image(body, v > 0 and icon_on or icon_off, -W / 2 + 76, y, { w = 60, h = 60 })
		if ic then
			e.ui:clear(icon)
			icon = ic
		end
	end, { color = key == "music" and "purple" or "pink", target = "slider_" .. key })
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

function M.build(e)
	local s = e.ui
	local v = views.settings(app.meta)
	local body, hh = kit.panel(e, W, H, { title = { key = "settings.title" } })
	local y = hh - 110
	kit.section(e, body, i18n.t("settings.sound"), 0, y, W - 80)
	volume_row(e, body, "music", "ui/icons/music_on", "ui/icons/music_off", y - 86, v.music)
	volume_row(e, body, "sfx", "ui/icons/sound_on", "ui/icons/sound_off", y - 186, v.sfx)

	y = y - 270
	kit.section(e, body, i18n.t("settings.game"), 0, y, W - 80)
	row_label(e, body, "ui/icons/haptics", i18n.t("settings.haptics"), y - 84)
	kit.toggle(e, body, W / 2 - 100, y - 84, v.haptics, function(on)
		e.self_key = "haptics"
		app.set_setting("haptics", on)
		if on then pcall(platform.vibrate, 30) end
	end, "haptics")
	row_label(e, body, "ui/icons/city", i18n.t("settings.reduced_motion"), y - 180)
	kit.toggle(e, body, W / 2 - 100, y - 180, v.reduced_motion, function(on)
		e.self_key = "reduced_motion"
		app.set_setting("reduced_motion", on)
	end, "reduced_motion")

	-- controls
	y = y - 270
	s:text(body, i18n.t("settings.input_mode"), -W / 2 + 46, y + 4, { font = "button", size = 28, color = "text", pivot = gui.PIVOT_W, max_width = 186 })
	kit.segmented(e, body, 110, y, 380, {
		{ id = "swipe", text = i18n.t("settings.input_swipe") },
		{ id = "taptap", text = i18n.t("settings.input_taptap") },
	}, v.input_mode, function(id)
		app.set_setting("input_mode", id)
		e:rebuild()
	end, { h = 84, text_size = 26, targets = "input" })

	-- language
	y = y - 130
	s:text(body, i18n.t("settings.language"), 0, y + 4, { font = "button", size = 28, color = "text", max_width = 400 })
	kit.segmented(e, body, 0, y - 84, W - 70, {
		{ id = "auto", text = i18n.t("settings.lang_auto") },
		{ id = "en", text = i18n.t("settings.lang_en") },
		{ id = "ru", text = i18n.t("settings.lang_ru") },
	}, v.language, function(id)
		app.set_setting("language", id) -- the host rebuilds every window on language_changed
		e:rebuild()
	end, { h = 84, text_size = 26, targets = "lang" })

	-- reset + version
	local ry = -hh + 110
	s:button({ parent = body, x = 0, y = ry, w = 400, h = 96, style = "pink", icon = "ui/icons/retry", icon_size = 50,
		text = i18n.t("settings.reset"), text_size = 30, on_click = function() reset(e) end })
	e:target("reset", 0, ry)
	s:text(body, i18n.t("settings.version", { v = app.VERSION }), 0, -hh + 36, { font = "small", size = 20, color = "text_soft" })
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
