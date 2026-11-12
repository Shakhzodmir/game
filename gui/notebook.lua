-- The songbook window: a sheet of music paper with the lines of the song of one district, written by Bit one per
-- beaten level (meta/songbook.lua, texts client/songbook.lua). The pages are the districts (arrows at the top).
-- A page that is not finished shows the lines so far, empty rows for the levels still to play and a pencil on the
-- next one. A finished page is the whole song: its title in big letters, the verses and choruses, a golden seal,
-- confetti and Bit cheering; "Listen" plays the song of the district (the one music slot of the game; stopping or
-- closing hands the music back to the town) and lights the line that is being sung, on the beats of the track.
-- Nothing here pays anything: the songbook is decoration.
--
-- params = {district = id of the page to open (default: the stretch of the next level), celebrate = true (the song
-- was just finished: seal and confetti at once)}. The page and the playing state live in e.state (they survive a
-- rebuild: a language change).
-- QA targets: page_prev, page_next, play (Listen / Stop), close.
-- QA status (app.ui.notebook): {page, district, count, total, ready, playing, active (the line that is lit), title}.

local app = require("client.app")
local i18n = require("client.i18n")
local songbook = require("client.songbook")
local songbook_model = require("meta.songbook")
local config = require("meta.config")
local audio = require("client.audio")
local kit = require("gui.kit")

local M = {}

local W, H = 660, 1120
local PAPER_W, PAPER_H = 556, 790
local STEP = 28                -- px between two lines of the song
local GROUP_GAP = 12           -- extra space between the verses
local TEXT_X = -PAPER_W / 2 + 104
local TEXT_W = PAPER_W - 104 - 64
local INK, INK_CHORUS = "#3B3355", "#6A2BD1"
local DOODLES = 9

-- Loose images of the window (kept in memory while it is open: the screens' release callbacks ask).
local IMAGES = { "notebook/paper_sheet", "notebook/stamp_ready", "notebook/stationery_1", "notebook/stationery_6" }
function M.images(keep)
	keep = keep or {}
	for _, k in ipairs(IMAGES) do keep[k] = true end
	for i = 1, DOODLES do keep["notebook/doodle_" .. i] = true end
	for i = 1, 6 do keep["notebook/sparkle_" .. i] = true end
	return keep
end

local function songs_of_meta()
	return app.meta:songbook()
end

-- The page to open first: the given district, else the stretch of the next level to play, else the last page.
local function first_page(list, want)
	for i, song in ipairs(list) do
		if song.id == want then return i end
	end
	local lvl = app.meta:level_to_play()
	if lvl then
		local id = songbook_model.of_level(lvl)
		for i, song in ipairs(list) do
			if song.id == id then return i end
		end
	end
	return #list
end

local function group_label(g, verse_n)
	if g.kind == "chorus" then return i18n.t("notebook.chorus") end
	return i18n.t("notebook.verse", { n = verse_n })
end

-- A margin doodle for the line number n of the song: deterministic, a few lines only.
local function doodle_for(pos, line)
	if pos % 4 ~= 2 then return nil end
	return (line * 5 + pos) % DOODLES + 1
end

local function play_toggle(e, song)
	if songbook.playing() == song.id then
		songbook.stop()
		if e.bit then e.bit:stop() end
		e.state.hl = nil
	else
		if not songbook.play(song.id) then
			kit.sfx("swap_fail")
			return
		end
		e.state.hl = 0
	end
	e:rebuild()
end

function M.build(e)
	local s = e.ui
	local st = e.state
	local list = songs_of_meta()
	if not st.page then st.page = first_page(list, e.params.district) end
	st.page = math.max(1, math.min(#list, st.page))
	local song = list[st.page]
	local district = app.district_by_id and app.district_by_id[song.id]
	local playing = songbook.playing() == song.id
	local animate = e.first and not st.played
	st.played = true

	local body, hh = kit.panel(e, W, H, { title = { key = "notebook.title" }, fit = true })

	-- the page strip: arrows and the name of the district with the levels of the song
	local py = hh - 118
	local function turn(x, label, target, delta)
		s:button({ parent = body, x = x, y = py, w = 92, h = 84, style = "white", text = label, text_size = 40, sfx = "tap",
			on_click = function()
				if songbook.playing() then songbook.stop() end
				st.page = (st.page - 1 + delta) % #list + 1
				st.hl = nil
				e:rebuild()
			end })
		e:target(target, x, py)
	end
	turn(-W / 2 + 80, "<", "page_prev", -1)
	turn(W / 2 - 80, ">", "page_next", 1)
	local name = district and i18n.name(district.name) or song.id
	s:text(body, name, 0, py + 14, { font = "button", size = 34, color = "purple", max_width = W - 280 })
	s:text(body, i18n.t("notebook.levels", { first = song.first, last = song.last }), 0, py - 22,
		{ font = "small", size = 22, color = "text_soft", max_width = W - 280 })

	-- the paper
	local cy = py - 56 - PAPER_H / 2 - 4
	local paper = s:image(body, "notebook/paper_sheet", 0, cy, { w = PAPER_W, h = PAPER_H })
		or s:round(body, 0, cy, PAPER_W - 24, PAPER_H - 24, "#FFF6DD", { radius = 16 })
	local top = PAPER_H / 2 - 48 -- y of the first row inside the paper
	local y = top
	st.rows = {}
	local nodes = st.rows
	if song.ready then
		kit.label(e, paper, songbook.title(song.id, song.title), -26, y, {
			font = "title", size = 40, color = INK_CHORUS, max_width = PAPER_W - 220, lines = 2,
		})
		y = y - 54
		local stamp = s:image(paper, "notebook/stamp_ready", PAPER_W / 2 - 78, top + 4, { w = 104, h = 104 })
		if stamp then
			gui.set_euler(stamp, vmath.vector3(0, 0, -12))
			if animate and not kit.reduced() then
				local base = gui.get_scale(stamp)
				gui.set_scale(stamp, base * 0.01)
				e:later(0.3, function()
					gui.animate(stamp, "scale", base, gui.EASING_OUTBACK, 0.5)
					kit.sfx("unlock")
				end)
			end
		end
	end
	-- the rows: the lines written, then the empty ones
	local verse_n = 0
	local gi = 1
	local groups = song.ready and song.groups or nil
	local last_hl_y
	for pos = 1, song.total do
		if groups and groups[gi] and pos == groups[gi].from then
			if groups[gi].kind == "verse" then verse_n = verse_n + 1 end
			s:text(paper, group_label(groups[gi], verse_n), -PAPER_W / 2 + 62, y - STEP * 0.12, {
				font = "small", size = 18, color = INK_CHORUS, max_width = 86,
			})
			if gi > 1 then y = y - GROUP_GAP end
			gi = gi + 1
		end
		local n = song.lines[pos]
		local chorus = groups and groups[gi - 1] and groups[gi - 1].kind == "chorus"
		if n then
			local color = chorus and INK_CHORUS or INK
			local hl = s:round(paper, -8, y, PAPER_W - 80, STEP - 2, "#FFD84D", { radius = 10, alpha = 0 })
			local node = s:text(paper, songbook.line(song.id, n), TEXT_X, y, {
				font = "body", size = 23, color = color, pivot = gui.PIVOT_W, max_width = TEXT_W,
			})
			if not song.ready then
				s:text(paper, tostring(pos), -PAPER_W / 2 + 70, y, { font = "small", size = 18, color = "text_soft", max_width = 40 })
			end
			local d = doodle_for(pos, n)
			if d and not chorus then
				kit.icon(e, paper, "notebook/doodle_" .. d, PAPER_W / 2 - 52, y, 34, "lavender")
			elseif chorus and pos % 4 == 1 then
				kit.icon(e, paper, "ui/icons/note_on", PAPER_W / 2 - 52, y, 34, "purple")
			end
			nodes[pos] = { hl = hl, y = y }
			if pos == song.count and not song.ready then last_hl_y = y end
		else
			-- an empty row: a faint bar, and the pencil rests on the next one
			s:round(paper, TEXT_X + 150, y, 300, 5, "#E8DDB8", { radius = 2 })
			s:text(paper, tostring(pos), -PAPER_W / 2 + 70, y, { font = "small", size = 18, color = "#CDBF95", max_width = 40 })
			if pos == song.count + 1 then
				kit.icon(e, paper, "notebook/stationery_1", TEXT_X + 14, y + 4, 44, "yellow")
			end
		end
		y = y - STEP
	end
	-- the line written last is marked with a yellow marker stripe
	if last_hl_y and nodes[song.count] then
		local c = gui.get_color(nodes[song.count].hl)
		gui.set_color(nodes[song.count].hl, vmath.vector4(c.x, c.y, c.z, 0.35))
	end

	-- the bottom: progress or the listening button, Bit
	local by = -hh + 86
	if song.ready then
		local b = s:button({ parent = body, x = -40, y = by, w = 380, h = 112, style = playing and "pink" or "green",
			icon = playing and "ui/icons/pause" or "ui/icons/play", icon_size = 58,
			text = i18n.t(playing and "notebook.stop" or "notebook.play"), text_size = 38,
			on_click = function() play_toggle(e, song) end })
		e:target("play", -40, by)
		if not playing and not kit.reduced() then kit.wiggle(b.node, 0.03, 1.1) end
	else
		local w, seg = 380, 380 / song.total
		for i = 1, song.total do
			s:round(body, -40 - w / 2 + (i - 0.5) * seg, by + 20, seg - 3, 14, i <= song.count and "#FFB020" or "#DDD2F3", { radius = 6 })
		end
		s:text(body, i18n.t("notebook.progress", { n = song.count, total = song.total }), -40, by - 12,
			{ font = "button", size = 26, color = "text", max_width = 400 })
	end
	kit.bit(e, body, W / 2 - 90, by + 8, 130, song.ready and "happy" or "idle")
	if e.bit then
		if song.ready then
			if playing then e.bit:dance(audio.status.bpm or 100) else e.bit:cheer(3, 3) end
		else
			e.bit:event("notebook")
		end
	end

	if song.ready then
		if animate and not kit.reduced() then
			e.fx:confetti({ rate = 22, burst = 20, duration = 2.6 })
		end
		if animate then kit.sfx("win") end
		if app.meta:songbook_seen(song.id) then app.commit("songbook") end
	end

	app.ui.notebook = { page = st.page, district = song.id, count = song.count, total = song.total, ready = song.ready,
		playing = playing, active = st.hl, title = song.title, rows = #nodes }
end

-- every frame: Bit, and the line that is being sung lights up (a move only when it changes)
function M.update(e, dt)
	kit.update_bit(e, dt)
	local st = e.state
	local song_id = songbook.playing()
	if not song_id then return end
	M.HL_ON = M.HL_ON or vmath.vector4(1, 0.847, 0.3, 0.75)
	M.HL_OFF = M.HL_OFF or vmath.vector4(1, 0.847, 0.3, 0)
	local rows = st.rows
	local n = rows and #rows or 0
	if n < 1 then return end
	local i = songbook.highlight(n)
	if i ~= st.hl then
		local old = rows[st.hl or 0]
		if old then gui.set_color(old.hl, M.HL_OFF) end
		local new = rows[i]
		if new then gui.set_color(new.hl, M.HL_ON) end
		st.hl = i
		if app.ui.notebook then app.ui.notebook.active = i end
	end
end

-- Closing the window stops the song and hands the music back to the town.
function M.closed(e)
	if songbook.playing() then songbook.stop() end
	app.ui.notebook = nil
end

return M
