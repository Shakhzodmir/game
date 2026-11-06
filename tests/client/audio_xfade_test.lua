-- One song at a time (client/audio.lua, main/audio.script): every change of track is a crossfade, at most two
-- tracks sound at any moment and two only while the crossfade lasts. The script runs on the strict Defold stub;
-- the stub keeps the components that sound now (`E.sounds.live`) with their gain.

local town_stub = require("tests.client.town_defold_stub")
local assets = require("client.assets")
local audio = require("client.audio")

local XF = audio.TRACK_CROSSFADE
local DT = 1 / 60

local function with_audio(fn)
	local E = town_stub.boot({})
	local ok, err = pcall(function()
		local app = require("client.app")
		local a = E.object("main/audio.script", { url = "main:/audio#audio" })
		a:init()
		fn(E, a, app)
	end)
	town_stub.shutdown()
	if not ok then error(err, 0) end
end

-- component id -> the track it belongs to (a district theme or a song), for every track of the registry
local function component_owner()
	local owner = {}
	for _, d in ipairs(require("client.app").district_list) do
		for _, stem in ipairs(assets.music_stems(d.id)) do owner[assets.music_id(d.id, stem)] = d.id end
	end
	for id, _ in pairs(assets.index.sounds.songs) do owner[assets.song(id).id] = id end
	return owner
end

-- the tracks that sound now: {track = number of its components}, the count, and the gains seen
local function live_tracks(E, owner)
	local tracks, n = {}, 0
	for url, l in pairs(E.sounds.live) do
		local comp = string.match(url, "#([^%]]+)")
		local track = comp and owner[comp]
		if track then
			if not tracks[track] then n = n + 1 end
			tracks[track] = (tracks[track] or 0) + 1
			assert_true(l.gain >= -1e-9 and l.gain <= 1 + 1e-9, "gain in range: " .. tostring(l.gain))
		end
	end
	return tracks, n
end

describe("audio crossfade maths", function()
	it("is equal-power, exact at both ends and never leaves a gap", function()
		local i0, o0 = audio.xfade_gains(0, XF)
		assert_eq(i0, 0)
		assert_eq(o0, 1)
		local i1, o1 = audio.xfade_gains(XF, XF)
		assert_eq(i1, 1)
		assert_eq(o1, 0)
		assert_eq(audio.xfade_gains(XF * 3, XF), 1)
		local prev_i, prev_o = 0, 1
		for k = 1, 100 do
			local i, o = audio.xfade_gains(XF * k / 100, XF)
			assert_near(i * i + o * o, 1, 1e-9, "equal power")
			assert_true(i >= prev_i and o <= prev_o, "in rises, out falls")
			prev_i, prev_o = i, o
		end
		local i, o = audio.xfade_gains(1, 0)
		assert_eq(i, 1)
		assert_eq(o, 0)
	end)
end)

describe("main/audio.script: one song at a time", function()
	it("a theme and a song swap by a crossfade: two tracks only while it lasts", function()
		with_audio(function(E, a)
			local owner = component_owner()
			a:message("music", { district = "cafe" })
			a:step(2)
			local _, n = live_tracks(E, owner)
			assert_eq(n, 1)
			assert_eq(audio.status.tracks, 1)
			a:message("music", { district = "bossa_breeze" })
			a:step(1)
			local tr, n2 = live_tracks(E, owner)
			assert_eq(n2, 2, "both tracks sound during the crossfade")
			assert_eq(audio.status.tracks, 2)
			assert_true(tr.bossa_breeze and tr.cafe)
			a:run(XF / 2)
			local song_url = nil
			for url in pairs(E.sounds.live) do
				if string.find(url, "#" .. assets.song("bossa_breeze").id, 1, true) then song_url = url end
			end
			assert_true(E.sounds.live[song_url].gain > 0.5 and E.sounds.live[song_url].gain < 1, "the song is coming in")
			a:run(XF)
			local _, n3 = live_tracks(E, owner)
			assert_eq(n3, 1, "only the song is left")
			assert_eq(audio.status.tracks, 1)
			assert_near(E.sounds.live[song_url].gain, 1, 1e-9)
			assert_true(audio.status.max_overlap <= XF + 2 * DT, "the overlap was one crossfade: " .. audio.status.max_overlap)
		end)
	end)

	it("a third request cuts the outgoing track: never three tracks", function()
		with_audio(function(E, a)
			local owner = component_owner()
			a:message("music", { district = "cafe" })
			a:step(2)
			a:message("music", { district = "scat_parade" })
			a:run(XF / 3)
			a:message("music", { district = "pixel_cafe" })
			local tr, n = live_tracks(E, owner)
			assert_eq(n, 2)
			assert_true(tr.scat_parade and tr.pixel_cafe and not tr.cafe, "the oldest is gone")
			a:run(XF * 2)
			local tr2, n2 = live_tracks(E, owner)
			assert_eq(n2, 1)
			assert_true(tr2.pixel_cafe)
		end)
	end)

	it("going back to the track that fades out restarts it cleanly (a component has one gain)", function()
		with_audio(function(E, a)
			local owner = component_owner()
			a:message("music", { district = "rainy_window" })
			a:step(2)
			a:message("music", { district = "sleepy_cat" })
			a:run(XF / 2)
			a:message("music", { district = "rainy_window" })
			local tr, n = live_tracks(E, owner)
			assert_eq(n, 2)
			assert_true(tr.rainy_window and tr.sleepy_cat)
			a:run(XF * 2)
			local tr2, n2 = live_tracks(E, owner)
			assert_eq(n2, 1)
			assert_true(tr2.rainy_window)
		end)
	end)

	it("stop_music fades the track out and silences it", function()
		with_audio(function(E, a)
			local owner = component_owner()
			a:message("music", { district = "bossa_breeze" })
			a:step(2)
			a:message("stop_music", {})
			a:step(1)
			assert_false(audio.status.playing, "the mixer is silent at once (notes do not follow a dying track)")
			local _, n = live_tracks(E, owner)
			assert_eq(n, 1, "the track is still fading")
			a:run(XF + 0.1)
			local _, n2 = live_tracks(E, owner)
			assert_eq(n2, 0)
			-- a song after a stop comes in over the dying one
			a:message("music", { district = "cafe" })
			a:message("music", { district = "jazz" })
			a:message("stop_music", {})
			a:message("music", { district = "rainy_window" })
			local _, n3 = live_tracks(E, owner)
			assert_true(n3 <= 2)
		end)
	end)

	it("the same track again and the layers of a theme do not start another track", function()
		with_audio(function(E, a)
			local owner = component_owner()
			a:message("music", { district = "cafe" })
			a:step(2)
			local played = #E.sounds.played
			a:message("music", { district = "cafe" })
			a:message("music", { district = "cafe", all = true })
			a:message("music", { district = "cafe", all = true, party = false })
			a:message("music", { district = "cafe" })
			a:run(1)
			assert_eq(#E.sounds.played, played, "no stem restarted: only gains moved")
			assert_eq(#E.sounds.stopped, 0)
			local _, n = live_tracks(E, owner)
			assert_eq(n, 1)
			-- the finale: every task stem is up after the fade
			a:message("music", { district = "cafe", all = true })
			a:run(1)
			assert_eq(audio.status.stems_on, audio.status.stems - 1, "every stem but the tension layer is on")
		end)
	end)

	it("coming back after a stall ends the crossfade at once", function()
		with_audio(function(E, a)
			local owner = component_owner()
			a:message("music", { district = "cafe" })
			a:step(2)
			a:message("music", { district = "bossa_breeze" })
			a:step(1)
			E.clock = E.clock + 2 -- a hidden tab: no frames for two seconds
			a:step(1)
			local _, n = live_tracks(E, owner)
			assert_eq(n, 1)
		end)
	end)

	it("a song of a genre that is not a district plays in the key of its genre", function()
		with_audio(function(E, a)
			a:message("music", { district = "savanna_drums" }) -- folk, G
			a:step(2)
			assert_eq(audio.status.song, "savanna_drums")
			assert_eq(audio.status.district, "folk")
			assert_true(audio.status.single)
			assert_eq(audio.status.semitones, -5)
			a:message("music", { district = "trap_playground" }) -- hip-hop, Eb
			a:step(2)
			assert_eq(audio.status.district, "hiphop")
			assert_eq(audio.status.semitones, 3)
			a:message("sfx", { name = "tap" })
			assert_near(audio.status.last_sfx_speed, audio.transpose_speed(3), 1e-9, "the tap is in C, the genre in Eb")
		end)
	end)

	it("random switching: the invariant holds in every frame", function()
		with_audio(function(E, a, app)
			local owner = component_owner()
			local songs_ids, themes = {}, {}
			for id in pairs(assets.index.sounds.songs) do songs_ids[#songs_ids + 1] = id end
			table.sort(songs_ids)
			for _, d in ipairs(app.district_list) do themes[#themes + 1] = d.id end
			local seed = 12345
			local function rnd(n)
				seed = (seed * 1103515245 + 12345) % 2147483648
				return math.floor(seed / 65536) % n + 1
			end
			local frames, both = 0, 0
			local overlap_run, worst_run, pair = 0, 0, nil
			for _ = 1, 400 do
				local k = rnd(10)
				if k <= 3 then
					a:message("music", { district = songs_ids[rnd(#songs_ids)] })
				elseif k <= 6 then
					local all = rnd(2) == 1
					a:message("music", { district = themes[rnd(#themes)], all = all, party = rnd(3) == 1 and false or nil })
				elseif k == 7 then
					a:message("stop_music", {})
				elseif k == 8 then
					a:message("layer", { name = rnd(2) == 1 and "tension" or "party", on = rnd(2) == 1 })
				elseif k == 9 then
					a:message("unlock_stem", { district = themes[rnd(#themes)], stem = "beat" })
				else
					a:message("resync", {})
				end
				-- some frames until the next event: from none (a double tap) to several crossfades
				local n = ({ 0, 1, 3, 10, 25, 60, 120 })[rnd(7)]
				for _ = 1, n do
					a:step(1)
					frames = frames + 1
					local tracks, count = live_tracks(E, owner)
					assert_true(count <= 2, "never more than two tracks sound together, frame " .. frames)
					assert_eq(audio.status.tracks, count, "the status tells the truth, frame " .. frames)
					if count == 2 then
						both = both + 1
						-- the time ONE PAIR of tracks sounds together (a new pair starts the count again)
						local names = {}
						for name in pairs(tracks) do names[#names + 1] = name end
						table.sort(names)
						local key = table.concat(names, "+")
						if key ~= pair then overlap_run = 0 end
						pair = key
						overlap_run = overlap_run + DT
						if overlap_run > worst_run then worst_run = overlap_run end
					else
						overlap_run, pair = 0, nil
					end
				end
			end
			assert_true(both > 50, "the run really crossfaded: " .. both)
			assert_true(worst_run <= XF + 3 * DT, "the same two tracks together at most one crossfade: " .. worst_run)
			assert_true(audio.status.max_overlap <= XF + 3 * DT)
			-- left alone, it settles on one track
			a:run(XF + 0.2)
			local _, n = live_tracks(E, owner)
			assert_true(n <= 1)
		end)
	end)
end)
