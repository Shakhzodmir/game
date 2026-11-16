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

	-- The reduced form of what the random run found with twelve districts (theme, stop, song, the same song, the
	-- theme again within 14 frames): A, then B, then A again before the first crossfade is over. These are TWO
	-- crossfades, one per request, each of the documented length: A gives way to B, then B gives way to A (A is
	-- restarted, a component has one gain). The two NAMES are heard together longer than one crossfade (here 1.5),
	-- but no crossfade lasts longer than TRACK_CROSSFADE and one track is left that long after the last request.
	it("A, B, A within one crossfade is two crossfades: each of one length, counted from its own request", function()
		with_audio(function(E, a)
			local owner = component_owner()
			a:message("music", { district = "square" })
			a:step(2)
			a:message("music", { district = "caravan_bells" })
			local half = math.floor(XF / 2 / DT)
			for _ = 1, half do
				a:step(1)
				local _, n = live_tracks(E, owner)
				assert_eq(n, 2)
			end
			assert_near(audio.status.overlap, half * DT, 1e-6, "the first crossfade is half way")
			local played = #E.sounds.played
			a:message("music", { district = "square" })
			assert_true(#E.sounds.played > played, "the theme was started again: another crossfade began")
			local together = 0
			for _ = 1, math.floor(XF / DT) + 3 do
				a:step(1)
				local tr, n = live_tracks(E, owner)
				if n == 2 then
					together = together + DT
					assert_true(tr.square and tr.caravan_bells)
					assert_true(audio.status.overlap <= together + 1e-6, "the status counts this crossfade, not the one before")
				end
				assert_eq(audio.status.tracks, n)
			end
			assert_true(together > XF - 3 * DT and together <= XF + 3 * DT, "the second crossfade has its full length: " .. together)
			local tr, n = live_tracks(E, owner)
			assert_eq(n, 1, "one crossfade after the last request one track is left")
			assert_true(tr.square)
			assert_true(audio.status.max_overlap <= XF + 3 * DT, "no crossfade was longer than one crossfade")
		end)
	end)

	it("a track that gives way while it is still coming in goes out from the level it had (no jump)", function()
		with_audio(function(E, a)
			local id = assets.song("scat_parade").id
			local function gain()
				for url, l in pairs(E.sounds.live) do
					if string.find(url, "#" .. id, 1, true) then return l.gain end
				end
			end
			a:message("music", { district = "bossa_breeze" })
			a:step(2)
			a:message("music", { district = "scat_parade" })
			a:run(XF / 4)
			local before = gain()
			assert_true(before > 0.2 and before < 0.6, "the song is a quarter in: " .. tostring(before))
			a:message("music", { district = "pixel_cafe" })
			local prev = before
			for _ = 1, math.floor(XF / DT) - 1 do
				a:step(1)
				local g = gain()
				if not g then break end
				assert_true(g <= prev + 1e-9, "it only goes down: " .. g .. " after " .. prev)
				prev = g
			end
			a:run(0.1)
			assert_eq(gain(), nil, "and it is gone after one crossfade")
		end)
	end)

	-- A fixed pseudo-random sequence of `actions` requests, the invariants checked in every frame. The themes come from
	-- the district list, so a new district changes every sequence: several seeds are run, not one.
	local function random_switching(seed0, actions)
		with_audio(function(E, a, app)
			local owner = component_owner()
			local songs_ids, themes = {}, {}
			for id in pairs(assets.index.sounds.songs) do songs_ids[#songs_ids + 1] = id end
			table.sort(songs_ids)
			for _, d in ipairs(app.district_list) do themes[#themes + 1] = d.id end
			local seed = seed0
			local function rnd(n)
				seed = (seed * 1103515245 + 12345) % 2147483648
				return math.floor(seed / 65536) % n + 1
			end
			local tag = " (seed " .. seed0 .. ")"
			local frames, both = 0, 0
			local overlap_run, worst_run, pair = 0, 0, nil
			local seen_played = #E.sounds.played
			for _ = 1, actions do
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
					assert_true(count <= 2, "never more than two tracks sound together, frame " .. frames .. tag)
					assert_eq(audio.status.tracks, count, "the status tells the truth, frame " .. frames .. tag)
					-- A crossfade begins when a track is started (sound.play of one of its components, as the stub saw
					-- it: not what the script says about itself). Two tracks may sound together for one crossfade
					-- counted from that start. The names of the pair are not enough to tell crossfades apart: A giving
					-- way to B and then B giving way to the restarted A are two crossfades of the same two names.
					local started = false
					for i = seen_played + 1, #E.sounds.played do
						local c = string.match(E.sounds.played[i].url, "#([^%]]+)")
						if c and owner[c] then started = true end
					end
					seen_played = #E.sounds.played
					if count == 2 then
						both = both + 1
						local names = {}
						for name in pairs(tracks) do names[#names + 1] = name end
						table.sort(names)
						local key = table.concat(names, "+")
						assert_true(started or key == pair, "another pair needs a track to start, frame " .. frames .. tag)
						if started then overlap_run = 0 end
						pair = key
						overlap_run = overlap_run + DT
						if overlap_run > worst_run then worst_run = overlap_run end
						assert_true(overlap_run <= XF + 3 * DT,
							"two tracks together at most one crossfade after the last start: " .. overlap_run .. " " .. key .. ", frame " .. frames .. tag)
						assert_near(audio.status.overlap, overlap_run, 1e-6, "the status counts what was heard, frame " .. frames .. tag)
					else
						overlap_run, pair = 0, nil
					end
				end
			end
			assert_true(both > actions / 8, "the run really crossfaded: " .. both .. tag)
			assert_true(worst_run > XF - 3 * DT, "a whole crossfade was seen: " .. worst_run .. tag)
			assert_true(audio.status.max_overlap <= XF + 3 * DT)
			-- left alone, it settles on one track
			a:run(XF + 0.2)
			local _, n = live_tracks(E, owner)
			assert_true(n <= 1)
		end)
	end

	it("random switching: the invariant holds in every frame", function()
		random_switching(12345, 400)
	end)

	it("random switching, other seeds: a new district cannot leave a sequence untested by accident", function()
		for _, seed in ipairs({ 1, 777, 20240229, 99991, 31337, 4242 }) do random_switching(seed, 400) end
	end)
end)
