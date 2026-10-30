-- main/audio.script with the jukebox songs on the strict Defold stub: a song is ONE looping mix (one decoder), it
-- plays in the key of its genre, it takes no layers, and the full song of a finished district follows the request
-- of the screen (party layer on in the town, off in a level) without a restart.

local town_stub = require("tests.client.town_defold_stub")
local assets = require("client.assets")
local audio = require("client.audio")
local bus = require("client.bus")

local function with_audio(fn, opts)
	local E = town_stub.boot(opts or {})
	local ok, err = pcall(function()
		local app = require("client.app")
		local a = E.object("main/audio.script", { url = "main:/audio#audio" })
		a:init()
		fn(E, a, app)
	end)
	town_stub.shutdown()
	if not ok then error(err, 0) end
end

-- the url the script made for the component `id` (it must have played)
local function url_of(E, id)
	for _, p in ipairs(E.sounds.played) do
		if string.find(p.url, "#" .. id, 1, true) then return p.url end
	end
	return nil
end

local function stopped(E, url)
	local n = 0
	for _, u in ipairs(E.sounds.stopped) do
		if u == url then n = n + 1 end
	end
	return n
end

describe("main/audio.script plays the jukebox songs", function()
	it("starts a song as ONE stem at full gain and reports what plays", function()
		with_audio(function(E, a)
			a:step(2)
			a:message("music", { district = "bossa_breeze" })
			assert_eq(#E.sounds.played, 1, "one decoder for the whole song")
			local song = assets.song("bossa_breeze")
			assert_true(song ~= nil)
			local url = url_of(E, song.id)
			assert_true(url ~= nil, "the component of the song")
			assert_eq(E.sounds.played[1].props.gain, 1)
			a:step(2)
			local st = audio.status
			assert_eq(st.song, "bossa_breeze")
			assert_eq(st.district, "jazz", "the genre")
			assert_true(st.single)
			assert_true(st.playing)
			assert_eq(st.stems, 1)
			assert_eq(st.stems_on, 1)
			assert_near(st.loop, song.loop, 1e-6)
			-- the same song again does not restart it
			a:message("music", { district = "bossa_breeze" })
			assert_eq(#E.sounds.played, 1)
			assert_eq(#E.sounds.stopped, 0)
		end)
	end)

	it("plays in the key of its genre: notes and effects follow the song that actually plays", function()
		with_audio(function(E, a)
			a:message("music", { district = "cafe" }) -- F
			a:message("sfx", { name = "tap" })
			assert_near(audio.status.last_sfx_speed, audio.transpose_speed(5), 1e-9)
			a:message("music", { district = "bossa_breeze" }) -- a song of the jazz genre: Bb
			a:step(2)
			assert_eq(audio.status.semitones, -2)
			a:message("sfx", { name = "tap" })
			assert_near(audio.status.last_sfx_speed, audio.transpose_speed(-2), 1e-9)
			a:run(0.3)
			a:message("note", { color = "red", wave = 1 })
			local before = #E.sounds.played
			a:run(0.5)
			assert_true(#E.sounds.played > before, "the note sounded")
			assert_near(E.sounds.played[#E.sounds.played].props.speed, audio.transpose_speed(-2), 1e-9)
			-- a song of the stadium genre (A): the key changes with it
			a:message("music", { district = "neon_heartbeat" })
			a:message("sfx", { name = "tap" })
			assert_near(audio.status.last_sfx_speed, audio.transpose_speed(-3), 1e-9)
			-- and the district theme brings its own key back
			a:message("music", { district = "jazz" })
			a:message("sfx", { name = "tap" })
			assert_near(audio.status.last_sfx_speed, audio.transpose_speed(-2), 1e-9)
		end)
	end)

	it("replaces the track that plays: a song stops a theme, a theme stops a song", function()
		with_audio(function(E, a)
			a:message("music", { district = "cafe" })
			local stems = #assets.music_stems("cafe")
			assert_eq(#E.sounds.played, stems)
			a:message("music", { district = "scat_parade" })
			assert_eq(#E.sounds.stopped, stems, "every stem of the theme stops")
			assert_eq(#E.sounds.played, stems + 1, "the song is one more sound")
			local url = url_of(E, assets.song("scat_parade").id)
			a:message("music", { district = "rainy_window" }) -- another song
			assert_eq(stopped(E, url), 1)
			a:message("music", { district = "cafe" })
			assert_eq(stopped(E, url_of(E, assets.song("rainy_window").id)), 1)
			assert_eq(#E.sounds.played, stems + 1 + 1 + stems)
			a:message("stop_music", {})
			a:step(2)
			assert_false(audio.status.playing)
			assert_eq(audio.status.song, nil)
			assert_false(audio.status.single)
		end)
	end)

	it("has no layers: tension, party and a stem of its genre change nothing", function()
		with_audio(function(E, a)
			a:message("music", { district = "bossa_breeze" })
			local url = url_of(E, assets.song("bossa_breeze").id)
			a:step(2)
			a:message("layer", { name = "tension", on = true })
			a:message("layer", { name = "party", on = true })
			a:message("unlock_stem", { district = "jazz", stem = "piano" })
			a:message("unlock_stem", { district = "bossa_breeze", stem = "mix" })
			a:run(1)
			assert_same(audio.status.layers, { tension = false, party = false })
			assert_true(E.sounds.gains[url] == nil, "no gain was touched")
			assert_eq(next(E.sounds.gains), nil, "no stem of any track was touched")
			assert_eq(#E.sounds.played, 1)
			assert_true(audio.status.playing)
		end)
	end)

	it("is ducked in a level like any music", function()
		with_audio(function(E, a)
			a:message("music", { district = "bossa_breeze" })
			a:run(0.5)
			local plain = E.sounds.group_gains.music
			assert_true(plain ~= nil and plain > 0)
			a:message("duck", { on = true })
			a:run(1)
			assert_true(E.sounds.group_gains.music < plain, "the music group is lower under a level")
			a:message("duck", { on = false })
			a:run(1.5)
			assert_near(E.sounds.group_gains.music, plain, 1e-6)
		end)
	end)

	it("lets the stem of a picked theme join it, and ignores the stems of other tracks", function()
		with_audio(function(E, a)
			a:message("music", { district = "cafe" })
			local url = url_of(E, assets.music_id("cafe", "beat"))
			assert_true((E.sounds.gains[url] or 0) < 0.01)
			a:message("unlock_stem", { district = "jazz", stem = "piano" })
			a:message("unlock_stem", { district = "cafe", stem = "beat" })
			a:run(0.8)
			assert_near(E.sounds.gains[url], 1, 0.01)
			assert_eq(E.sounds.gains[url_of(E, assets.music_id("cafe", "pad"))], nil, "the other layers stay as they were")
		end)
	end)

	it("keeps the full song of a finished district going when the party layer is switched, without a restart", function()
		with_audio(function(E, a)
			-- the town: the full song with the party layer
			a:message("music", { district = "cafe", all = true })
			local n = #E.sounds.played
			assert_eq(n, #assets.music_stems("cafe"))
			local party = url_of(E, assets.music_id("cafe", "party"))
			a:run(0.5)
			assert_true(audio.status.layers.party)
			-- a level: the same stems, no party layer (it belongs to the concert)
			a:message("music", { district = "cafe", all = true, party = false })
			assert_eq(#E.sounds.played, n, "the music was not restarted")
			assert_eq(#E.sounds.stopped, 0)
			a:run(1)
			assert_false(audio.status.layers.party)
			assert_near(E.sounds.gains[party], 0, 0.01)
			assert_eq(audio.status.song, "cafe")
			-- back in the town: the layer comes in again
			a:message("music", { district = "cafe", all = true })
			a:run(1)
			assert_true(audio.status.layers.party)
			assert_near(E.sounds.gains[party], 1, 0.01)
			assert_eq(#E.sounds.played, n)
			assert_eq(#E.sounds.stopped, 0)
		end)
	end)

	it("restarts a song at the clock position when the app comes back", function()
		with_audio(function(E, a)
			a:message("music", { district = "bossa_breeze" })
			local url = url_of(E, assets.song("bossa_breeze").id)
			a:run(3)
			local before = #E.sounds.played
			bus.publish("app_focus", { focused = true, event = "focus_gained" })
			a:step(2)
			assert_eq(#E.sounds.played, before + 1, "the one stem played again")
			local p = E.sounds.played[#E.sounds.played]
			assert_eq(p.url, url)
			assert_true(p.props.start_time ~= nil, "at the position of the clock")
			assert_true(p.props.start_time > 2 and p.props.start_time < 4, "about 3 s into the loop: " .. tostring(p.props.start_time))
			assert_eq(p.props.gain, 1)
			assert_true(stopped(E, url) >= 1)
			assert_true(audio.status.resyncs >= 1)
		end)
	end)

	it("plays nothing for a track that is not there, and the old music stops", function()
		with_audio(function(E, a)
			a:message("music", { district = "cafe" })
			a:message("music", { district = "no_such_song" })
			a:step(2)
			assert_false(audio.status.playing)
			assert_eq(audio.status.song, nil)
		end)
	end)
end)
