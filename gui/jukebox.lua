-- Jukebox: the songs of the town, by genre. A row of genre tabs (one per district: its colour, a note,
-- a lock while the district is not open), under it the songs of the tab on display: the layered theme of the
-- district first (a finished district plays its full song, the one being built the layers built so far), then
-- the songs of the genre, all playable at once in an open genre. A locked genre is a dark silhouette with what
-- opens it. A "now playing" strip with a bouncing equalizer and Bit dancing to the beat of the song.
--
-- A pick is KEPT: it is saved with the prefs (meta:song) and every place that starts music plays it
-- (client/songs.lua), so closing the window does not bring the district track back. It is cleared by tapping
-- the playing row again or by the "Return the town music" button, which is always on screen (it looks
-- disabled while the town's own music plays).
-- The tab and the page on display live in e.state (they survive a rebuild: a language change); the pick lives
-- in the meta. A genre with more songs than a page holds pages with two arrows.
-- QA targets: tab_<district>, play_<song id> (the theme: play_<district id>), back_home, page_prev, page_next.
-- QA status (app.ui.jukebox): {tab, page, pages, chosen = the pick, rows = in the tab, ids = the rows on the page}.

local app = require("client.app")
local i18n = require("client.i18n")
local views = require("client.views")
local songs = require("client.songs")
local ui = require("client.ui")
local assets = require("client.assets")
local kit = require("gui.kit")

local M = {}

local W, H = 660, 1120
local LIST_W = 600          -- width of the tab row and of a song row
local ROW_H, ROW_STEP = 118, 128
local PAGE_ROWS = 5         -- rows on a page; a genre with more songs pages by PAGE_ROWS_PAGED
local PAGE_ROWS_PAGED = 4
local TAB_H, TAB_GAP = 100, 10
-- the button style of each genre tab (the colour of its district: pink, lavender, gold, blue, green)
local TAB_STYLE = { "pink", "purple", "gold", "blue", "green" }

local function rows_per_page(count)
	return count <= PAGE_ROWS and PAGE_ROWS or PAGE_ROWS_PAGED
end

local function page_count(count)
	return math.max(1, math.ceil(count / rows_per_page(count)))
end

-- The tab to show first: the genre of the picked song, else the district on display.
local function first_tab(vm)
	for _, tab in ipairs(vm.tabs) do
		if tab.playing then return tab.id end
	end
	local shown = app.ui.district or app.focus_district()
	for _, tab in ipairs(vm.tabs) do
		if tab.id == shown then return tab.id end
	end
	return vm.tabs[1] and vm.tabs[1].id or nil
end

local function tab_by_id(vm, id)
	for _, tab in ipairs(vm.tabs) do
		if tab.id == id then return tab end
	end
	return nil
end

local function find_row(vm, id)
	for _, tab in ipairs(vm.tabs) do
		for _, r in ipairs(vm.songs[tab.id]) do
			if r.id == id then return r end
		end
	end
	return nil
end

-- the tap on a row: a locked row says what opens it, the playing row hands the music back to the town, any
-- other row becomes the pick (and plays at once)
local function tap_row(e, row)
	if not row.playable then
		kit.sfx("swap_fail")
		app.toast_key(row.state == "locked" and "jukebox.locked" or "jukebox.no_layers",
			{ name = row.prev_name or "" }, { color = "blue" })
		return
	end
	if row.playing then
		songs.clear()
		kit.sfx("tap")
	else
		songs.pick(row.id)
		kit.sfx("button")
	end
	e:rebuild()
end

local function record(e, parent, x, y, row, spinning)
	local s = e.ui
	local locked = row.state == "locked"
	local disc = s:circle(parent, x, y, 96, locked and "#B9B3C9" or "#2B2345")
	s:circle(disc, 0, 0, 74, locked and "#CFC9DC" or "#3D3260")
	s:circle(disc, 0, 0, 54, locked and "#B9B3C9" or "#2B2345")
	local label = s:circle(disc, 0, 0, 34, locked and "#E4E0EC" or row.color)
	s:circle(label, 0, 0, 9, "#2B2345")
	-- a shine that shows the spin
	local shine = s:round(disc, 0, 26, 9, 30, "white", { alpha = locked and 0.2 or 0.35, radius = 4 })
	if spinning and not kit.reduced() then
		gui.animate(disc, "euler.z", -360, gui.EASING_LINEAR, 2.0, 0, nil, gui.PLAYBACK_LOOP_FORWARD)
	end
	return disc, shine
end

-- The name of a song on one or two lines (long Russian names wrap before they shrink). y1 / y2: where the text
-- sits (its centre) with one / two lines. Returns the number of lines.
local function name_text(e, parent, str, x, y1, y2, color, max_w)
	local size = 28
	if kit.text_width("button", str, size) <= max_w then
		e.ui:text(parent, str, x, y1, { font = "button", size = size, color = color, pivot = gui.PIVOT_W, max_width = max_w })
		return 1
	end
	e.ui:text(parent, str, x, y2, { font = "button", size = size, color = color, pivot = gui.PIVOT_W, width = max_w,
		height = size * 1.3 * 2, max_width = max_w })
	return 2
end

local function song_row(e, body, row, y, hint)
	local s = e.ui
	local playing = row.playing
	local locked = row.state == "locked"
	local frame = s:round(body, 0, y, LIST_W, ROW_H, playing and "gold" or (locked and "#D9D3E6" or "#E3D9FF"), { radius = 34 })
	local inner = s:round(frame, 0, 0, LIST_W - 10, ROW_H - 10, locked and "#F1EEF8" or "white", { radius = 30 })
	record(e, inner, -232, 0, row, playing)
	if locked then kit.lock(e, inner, -232, 0, 50) end
	local tx, max_w = -170, 300
	local str = locked and "? ? ?" or i18n.name(row.name)
	local lines
	if locked then
		lines = name_text(e, inner, str, tx, hint and 26 or 0, hint and 26 or 0, "text_soft", max_w)
	else
		lines = name_text(e, inner, str, tx, 20, 12, "text", max_w)
	end
	local line, color
	if locked then
		if hint then line, color = i18n.t("jukebox.locked", { name = row.prev_name and i18n.name(row.prev_name) or "" }), "text_soft" end
	elseif row.theme and row.state == "complete" then
		line, color = i18n.t("jukebox.full_song"), "green"
	elseif row.theme then
		line, color = i18n.t("jukebox.layers", { done = row.stems, total = row.total }), "purple"
	else
		line, color = i18n.t("jukebox.bpm", { bpm = row.bpm or 0 }), "text_soft"
	end
	if line then
		if locked then
			-- "Build <district> to unlock": two lines, left aligned, never shrunk to a smudge
			s:text(inner, line, tx, -20, { font = "small", size = 21, color = color, pivot = gui.PIVOT_W, width = 300, height = 56 })
		else
			s:text(inner, line, tx, lines == 2 and -34 or -14, { font = "small", size = 22, color = color, pivot = gui.PIVOT_W, max_width = max_w })
		end
	end
	if row.theme and row.state == "current" and lines == 1 then
		-- the layers built so far as little bars
		local n = math.max(1, row.total)
		local bw = math.min(26, 280 / n)
		for i = 1, n do
			s:round(inner, tx + (i - 0.5) * (bw + 4), -38, bw, 9, i <= row.stems and "purple" or "#E3D9FF", { radius = 4 })
		end
	end
	if not locked then
		local b = s:button({ parent = inner, x = 222, y = 0, w = 124, h = 88, style = playing and "pink" or (row.playable and "green" or "white"),
			icon = playing and "ui/icons/pause" or "ui/icons/play", icon_size = 54, sfx = false,
			text = (playing and not assets.has_image("ui/icons/pause")) and "II" or nil,
			on_click = function() tap_row(e, row) end })
		if not row.playable then gui.set_color(b.node, vmath.vector4(1, 1, 1, 0.6)) end
	else
		-- a dark silhouette answers a tap with what opens it
		local b = s:button({ parent = inner, x = 222, y = 0, w = 124, h = 88, style = "white", sfx = false,
			on_click = function() tap_row(e, row) end })
		gui.set_color(b.node, vmath.vector4(1, 1, 1, 0))
	end
	e:target("play_" .. row.id, 222, y)
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

-- One genre tab: the district's colour, a note, its name; a lock and a dark face while the district is not open.
-- The tab on display is bigger and white-rimmed.
local function tab_button(e, body, tab, x, y, w, active)
	local s = e.ui
	local locked = tab.state == "locked"
	local style = locked and "white" or (active and (TAB_STYLE[(tab.index - 1) % #TAB_STYLE + 1]) or "white")
	local bw, bh = active and w + 8 or w, active and TAB_H + 12 or TAB_H
	local b = s:button({ parent = body, x = x, y = y + (active and 6 or 0), w = bw, h = bh, style = style, sfx = false,
		on_click = function()
			if e.state.tab ~= tab.id then
				e.state.tab = tab.id
				kit.sfx("tap")
				e:rebuild()
			end
		end })
	if locked then
		gui.set_color(b.node, ui.color("#8F88A8"))
	elseif not active then
		gui.set_color(b.node, ui.color(tab.color))
	end
	local label = i18n.name(tab.genre)
	if locked then
		kit.lock(e, b.node, 0, 14, 46)
		s:text(b.node, "???", 0, -26, { font = "button", size = 22, color = "white", outline = "#5A5470", max_width = w - 12 })
	else
		local note = s:image(b.node, "ui/icons/note_on", 0, 16, { w = 44, h = 44 })
		if note then gui.set_inherit_alpha(note, true) end
		s:text(b.node, label, 0, -26, { font = "button", size = 23, color = active and "white" or "text",
			outline = active and "#5220A6" or false, shadow = active and "#5220A6" or false, max_width = w - 10 })
	end
	e:target("tab_" .. tab.id, x, y)
	return b
end

function M.build(e)
	local s = e.ui
	local st = e.state
	local vm = views.jukebox(app.meta, app.district_by_id)
	if not st.tab or not tab_by_id(vm, st.tab) then st.tab = first_tab(vm) end
	local tab = tab_by_id(vm, st.tab)
	local rows = tab and vm.songs[tab.id] or {}
	local per = rows_per_page(#rows)
	local pages = page_count(#rows)
	st.pages = st.pages or {}
	local page = math.max(1, math.min(st.pages[st.tab] or 1, pages))
	st.pages[st.tab] = page

	local body, hh = kit.panel(e, W, H, { title = { key = "jukebox.title" } })

	-- now playing (the pick: it survives the window)
	local ny = hh - 130
	local picked = vm.chosen and find_row(vm, vm.chosen) or nil
	local strip = s:round(body, 0, ny, W - 60, 116, picked and "#FFF1C2" or "#F4EEFF", { radius = 34 })
	equalizer(e, strip, -(W - 60) / 2 + 90, 0, picked ~= nil)
	local text = picked and i18n.t("jukebox.now_playing", { name = i18n.name(picked.name) }) or i18n.t("jukebox.pick")
	s:text(strip, text, 14, 0, { font = "button", size = 28, color = picked and "text" or "text_soft", max_width = 308 })
	kit.bit(e, strip, (W - 60) / 2 - 66, -14, 104, "idle")
	if picked and e.bit then e.bit:dance(picked.bpm or 100) end

	-- the genre tabs
	local n = #vm.tabs
	local tw = math.floor((LIST_W - (n - 1) * TAB_GAP) / math.max(1, n))
	local ty = ny - 58 - 14 - TAB_H / 2 + 6
	for i, t in ipairs(vm.tabs) do
		local tx = (i - (n + 1) / 2) * (tw + TAB_GAP)
		tab_button(e, body, t, tx, ty, tw, t.id == st.tab)
	end

	-- the songs of the tab: a pastel card of the genre's colour behind the rows
	local top = ty - TAB_H / 2 - 12
	local bottom = -hh + 70 + 46 + 14
	local card_h = top - bottom
	if tab then
		local tint = tab.state == "locked" and "#D9D3E6" or tab.color
		s:round(body, 0, (top + bottom) / 2, LIST_W + 22, card_h, tint, { alpha = 0.3, radius = 30 })
	end
	local first = (page - 1) * per + 1
	local y = top - 8 - ROW_H / 2
	local ids = {}
	for i = first, math.min(#rows, first + per - 1) do
		song_row(e, body, rows[i], y, tab.state == "locked" and i == first)
		ids[#ids + 1] = rows[i].id
		y = y - ROW_STEP
	end

	-- a long genre pages: two arrows and the page number
	if pages > 1 then
		local py = bottom + 40
		local function arrow(x, label, target, delta)
			local b = s:button({ parent = body, x = x, y = py, w = 96, h = 80, style = "white", text = label, text_size = 40, sfx = "tap",
				on_click = function()
					st.pages[st.tab] = (page - 1 + delta) % pages + 1
					e:rebuild()
				end })
			e:target(target, x, py)
			return b
		end
		arrow(-150, "<", "page_prev", -1)
		s:text(body, i18n.t("jukebox.page", { page = page, pages = pages }), 0, py, { font = "button", size = 30, color = "text_soft", max_width = 160 })
		arrow(150, ">", "page_next", 1)
	end

	-- back to the town music: always on screen, dull while the town's own music plays
	local by = -hh + 70
	local home = s:button({ parent = body, x = 0, y = by, w = 440, h = 92, style = vm.chosen and "blue" or "white",
		icon = "ui/icons/city", icon_size = 50, text = i18n.t("jukebox.back_home"), text_size = 26, sfx = false,
		on_click = function()
			if not vm.chosen then
				kit.sfx("swap_fail")
				app.toast_key("jukebox.already_home", nil, { color = "blue" })
				return
			end
			songs.clear()
			kit.sfx("button")
			e:rebuild()
		end })
	if not vm.chosen then gui.set_color(home.node, vmath.vector4(1, 1, 1, 0.6)) end
	e:target("back_home", 0, by)

	app.ui.jukebox = { tab = st.tab, page = page, pages = pages, chosen = vm.chosen, rows = #rows, ids = ids }
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

-- The pick stays when the window closes (the music is already right: songs.pick / songs.clear started it).
function M.closed(e)
	app.ui.jukebox = nil
end

return M
