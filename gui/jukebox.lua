-- Jukebox: the songs of the town. A finished district plays its full song
-- (every stem + the party layer), the district being built plays the stems
-- unlocked so far, a locked one is a dark silhouette with what opens it.
-- A "now playing" strip with a bouncing equalizer and Bit dancing to the
-- beat. Closing the window brings the district music of the town back.

local app = require("client.app")
local i18n = require("client.i18n")
local views = require("client.views")
local audio = require("client.audio")
local ui = require("client.ui")
local kit = require("gui.kit")
local analytics = require("client.services.analytics")

local M = {}

local W, H = 660, 1120

local function restore_music()
	audio.music(app.focus_district())
end

local function play(e, row)
	local st = e.state
	if not row.playable then
		kit.sfx("swap_fail")
		app.toast_key(row.state == "locked" and "jukebox.locked" or "jukebox.no_layers",
			{ name = row.prev_name or "" }, { color = "blue" })
		return
	end
	if st.playing == row.id then
		st.playing = nil
		restore_music()
		kit.sfx("tap")
	else
		st.playing = row.id
		audio.music(row.id, { all = row.state == "complete" })
		analytics.log("jukebox_play", { district = row.id })
		kit.sfx("button")
	end
	e:rebuild()
end

local function record(e, parent, x, y, row, spinning)
	local s = e.ui
	local disc = s:circle(parent, x, y, 112, row.state == "locked" and "#B9B3C9" or "#2B2345")
	s:circle(disc, 0, 0, 86, row.state == "locked" and "#CFC9DC" or "#3D3260")
	s:circle(disc, 0, 0, 62, row.state == "locked" and "#B9B3C9" or "#2B2345")
	local label = s:circle(disc, 0, 0, 40, row.state == "locked" and "#E4E0EC" or row.color)
	s:circle(label, 0, 0, 10, "#2B2345")
	-- a shine that shows the spin
	local shine = s:round(disc, 0, 30, 10, 34, "white", { alpha = row.state == "locked" and 0.2 or 0.35, radius = 4 })
	if spinning and not kit.reduced() then
		gui.animate(disc, "euler.z", -360, gui.EASING_LINEAR, 2.0, 0, nil, gui.PLAYBACK_LOOP_FORWARD)
	end
	return disc, shine
end

local function song_row(e, body, row, y)
	local s = e.ui
	local st = e.state
	local playing = st.playing == row.id
	local locked = row.state == "locked"
	local rw, rh = 600, 150
	local frame = s:round(body, 0, y, rw, rh, playing and "gold" or (locked and "#E4E0EC" or "#E3D9FF"), { radius = 34 })
	local inner = s:round(frame, 0, 0, rw - 10, rh - 10, locked and "#F6F3FB" or "white", { radius = 30 })
	record(e, inner, -220, 0, row, playing)
	if locked then kit.lock(e, inner, -220, 0, 56) end
	local name = locked and "? ? ?" or i18n.name(row.name)
	s:text(inner, name, -150, 30, { font = "button", size = 30, color = locked and "text_soft" or "text", pivot = gui.PIVOT_W, max_width = 280 })
	local line, color
	if row.state == "complete" then
		line, color = i18n.t("jukebox.full_song"), "green"
	elseif row.state == "current" then
		line, color = i18n.t("jukebox.layers", { done = row.stems, total = row.total }), "purple"
	else
		line, color = i18n.t("jukebox.locked", { name = row.prev_name and i18n.name(row.prev_name) or "" }), "text_soft"
	end
	s:text(inner, line, -150, -18, { font = "small", size = 22, color = color, pivot = gui.PIVOT_W, max_width = 280, width = 280 })
	if row.state == "current" then
		-- the layers built so far as little bars
		local n = math.max(1, row.total)
		local bw = math.min(26, 260 / n)
		for i = 1, n do
			s:round(inner, -150 + (i - 0.5) * (bw + 4), -52, bw, 10, i <= row.stems and "purple" or "#E3D9FF", { radius = 4 })
		end
	end
	if not locked then
		local b = s:button({ parent = inner, x = 212, y = 0, w = 124, h = 100, style = playing and "pink" or (row.playable and "green" or "white"),
			icon = playing and "ui/icons/pause" or "ui/icons/play", icon_size = 56, sfx = false,
			text = (playing and not require("client.assets").has_image("ui/icons/pause")) and "II" or nil,
			on_click = function() play(e, row) end })
		if not row.playable then gui.set_color(b.node, vmath.vector4(1, 1, 1, 0.6)) end
		e:target("play_" .. row.id, 212, y)
	else
		local b = s:button({ parent = inner, x = 212, y = 0, w = 124, h = 100, style = "white", sfx = false,
			on_click = function() play(e, row) end })
		gui.set_color(b.node, vmath.vector4(1, 1, 1, 0))
	end
	return frame
end

local function equalizer(e, parent, x, y, on)
	local s = e.ui
	local colors = { "#FF4D8D", "#FFB020", "#FFDB1A", "#2BE38F", "#3AA4FF", "#9B52FF" }
	e.bars = {}
	for i = 1, 6 do
		local b = s:round(parent, x + (i - 3.5) * 20, y - 30, 14, 20, colors[i], { radius = 6, pivot = gui.PIVOT_S })
		e.bars[i] = { node = b, t = i * 0.37, on = on }
	end
end

function M.build(e)
	local s = e.ui
	local st = e.state
	local rows = views.jukebox(app.meta, app.district_by_id)
	e.rows = rows
	local body, hh = kit.panel(e, W, H, { title = { key = "jukebox.title" } })

	-- now playing
	local ny = hh - 130
	local strip = s:round(body, 0, ny, W - 60, 120, st.playing and "#FFF1C2" or "#F4EEFF", { radius = 34 })
	local playing_row
	for _, r in ipairs(rows) do if r.id == st.playing then playing_row = r end end
	equalizer(e, strip, -(W - 60) / 2 + 90, 0, playing_row ~= nil)
	local text = playing_row and i18n.t("jukebox.now_playing", { name = i18n.name(playing_row.name) }) or i18n.t("jukebox.pick")
	s:text(strip, text, 10, 0, { font = "button", size = 28, color = playing_row and "text" or "text_soft", max_width = 330 })
	kit.bit(e, strip, (W - 60) / 2 - 66, -14, 104, "idle")
	if playing_row and e.bit then
		e.bit:dance(playing_row.bpm or 100)
	end

	local y = ny - 158
	for _, r in ipairs(rows) do
		song_row(e, body, r, y)
		y = y - 158
	end

	-- back to the town music
	local by = -hh + 70
	s:button({ parent = body, x = 0, y = by, w = 420, h = 92, style = "blue", icon = "ui/icons/city", icon_size = 50,
		text = i18n.t("jukebox.back_home"), text_size = 26,
		on_click = function()
			st.playing = nil
			restore_music()
			e:rebuild()
		end })
	e:target("back_home", 0, by)
end

function M.update(e, dt)
	kit.update_bit(e, dt)
	if kit.reduced() then return end
	for _, b in ipairs(e.bars or {}) do
		if b.on then
			b.t = b.t + dt * 7
			local h = 16 + 44 * math.abs(math.sin(b.t) * math.sin(b.t * 0.53 + 1.3))
			gui.set_size(b.node, vmath.vector3(14, h, 0))
		end
	end
end

function M.closed(e)
	restore_music()
end

return M
