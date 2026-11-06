-- The songbook on the client side: the texts of a song (the model is meta/songbook.lua, the texts are the
-- `sb.*` / `sbt.*` keys of client/i18n_songbook.lua), the playing of a finished song and its karaoke highlight.
--
--   local songbook = require("client.songbook")
--   songbook.line("cafe", 7)                   -- the text of line 7 of the pool, in the language on display
--   songbook.title("cafe", song.title)         -- the title of a ready song
--   songbook.play("cafe") / songbook.stop()    -- the district song through the one music slot (WP-6): the previous
--                                              -- track fades out, the one pick of the jukebox comes back on stop
--   songbook.playing()                         -- the district whose song plays now, or nil
--   songbook.active_line(count, clock, loop, bpm) -- the line to highlight (pure)
--   songbook.highlight()                       -- active_line for what plays now, or nil
--
-- A song plays through ONE track at a time like every music of the game (client/audio.lua crossfades), and never
-- changes the pick of the jukebox: stop() hands the music back to client/songs.lua.

local app = require("client.app")
local i18n = require("client.i18n")
local audio = require("client.audio")
local assets = require("client.assets")
local songs = require("client.songs")

local M = {}

local current -- the district whose song is playing

function M.line(district, n)
	return i18n.t("sb." .. district .. "." .. n)
end

function M.title(district, n)
	return i18n.t("sbt." .. district .. "." .. n)
end

-- The line (1..count) lit at `clock` seconds of the track. The loop (seconds) is split evenly among the lines; when
-- the tempo is known the borders sit on beats, so the highlight moves with the pulse of the song. Pure.
function M.active_line(count, clock, loop, bpm)
	if not count or count < 1 then return nil end
	if not clock or not loop or loop <= 0 then return 1 end
	local pos = clock % loop
	if bpm and bpm > 0 then
		local beat = 60 / bpm
		local beats = math.floor(loop / beat + 0.5)
		if beats >= count then
			local at = math.floor(pos / beat)
			if at >= beats then at = beats - 1 end
			return math.min(count, math.floor(at * count / beats) + 1)
		end
	end
	return math.min(count, math.floor(pos / loop * count) + 1)
end

-- The first n characters of a UTF-8 text (Cyrillic and Hangul take 2-3 bytes each): the writing effect reveals a line
-- letter by letter. Pure.
function M.prefix(str, n)
	if n <= 0 then return "" end
	local i, count, len = 1, 0, #str
	while i <= len do
		local b = str:byte(i)
		local size = (b >= 240 and 4) or (b >= 224 and 3) or (b >= 192 and 2) or 1
		count = count + 1
		if count > n then return str:sub(1, i - 1) end
		i = i + size
	end
	return str
end

-- Number of characters of a UTF-8 text. Pure.
function M.length(str)
	local count = 0
	for i = 1, #str do
		local b = str:byte(i)
		if b < 128 or b >= 192 then count = count + 1 end
	end
	return count
end

-- Starts the song of a district (every stem and the party layer). false when there is nothing to play.
function M.play(district)
	if not district or not assets.music_loop(district) then return false end
	audio.music(district, { all = true, party = true })
	current = district
	return true
end

-- Hands the music back to where the player is: the town (the pick of the jukebox, else the theme of the district on
-- display) or, when the window was opened from the results of a level, the music of the level.
function M.stop(district_on_display)
	if not current then return end
	current = nil
	local ctx = (app.ui and app.ui.screen == "level") and songs.LEVEL or songs.TOWN
	songs.play(ctx, district_on_display or songs.shown_district())
end

function M.playing()
	return current
end

-- The line to light for the song that plays now (count = lines of the song), or nil when none plays.
function M.highlight(count)
	if not current then return nil end
	local st = audio.status
	if not st or st.song ~= current or not st.playing then return 1 end
	return M.active_line(count, st.clock, assets.music_loop(current), st.bpm)
end

return M
