-- The jukebox songs as files and as registry entries: single looping mixes next to the layered themes
-- (tools/audio/songs.py makes them, tools/gen_defold.py registers them, assets/sounds/manifest.json measures them).

local assets = require("client.assets")
local json = require("tools.lib.json")

local function read(path)
	local f = assert(io.open(path, "rb"))
	local s = f:read("*a")
	f:close()
	return s
end

local districts = json.decode(read("content/districts.json")).districts
local audio_go = read("assets/gen/audio.go")
local manifest = json.decode(read("assets/sounds/manifest.json"))

describe("the registry of the jukebox songs", function()
	local index = assets.index

	it("has every song of the catalogue: a component of the audio object and a loop length", function()
		local n = 0
		for _, d in ipairs(districts) do
			for _, s in ipairs(d.songs) do
				n = n + 1
				local e = assets.song(s.id)
				assert_true(e ~= nil, s.id .. " is not in the registry")
				assert_eq(e.id, "song_" .. s.id)
				assert_true(string.find(audio_go, 'id: "' .. e.id .. '"', 1, true) ~= nil, e.id .. " is not a component of audio.go")
				assert_true(string.find(audio_go, "/assets/music/songs/" .. s.id .. ".ogg", 1, true) ~= nil, s.id)
				-- the loop is the exact length of bars x 4 beats at the tempo (the Ogg header counts samples at 22.05 kHz)
				assert_near(e.loop, s.bars * 4 * 60 / s.bpm, 0.0002, s.id)
				assert_true(e.loop >= 16 and e.loop <= 32, s.id .. " loops " .. e.loop .. " s")
			end
		end
		assert_true(n >= 15, "only " .. n .. " songs")
	end)

	it("has no song that the catalogue does not name, and no id of a district", function()
		local named = {}
		for _, d in ipairs(districts) do
			assert_eq(assets.song(d.id), nil, d.id .. " is a district, not a song")
			for _, s in ipairs(d.songs) do named[s.id] = true end
		end
		for id in pairs(index.sounds.songs) do assert_true(named[id], id .. " is not in content/districts.json") end
		assert_eq(assets.song("nope"), nil)
	end)

	it("plays songs as looping music components, like the stems", function()
		for id, e in pairs(index.sounds.songs) do
			local at = string.find(audio_go, 'id: "' .. e.id .. '"', 1, true)
			local chunk = string.sub(audio_go, at, at + 260)
			assert_true(string.find(chunk, "looping: 1", 1, true) ~= nil, id .. " does not loop")
			assert_true(string.find(chunk, 'group: \\"music\\"', 1, true) ~= nil, id .. " is not in the music group")
		end
	end)

	it("stays inside the sound limits of game.project", function()
		local gp = read("game.project")
		local function limit(key) return tonumber(string.match(gp, key .. " = (%d+)")) end
		local components = select(2, string.gsub(audio_go, "embedded_components {", ""))
		assert_true(components < limit("max_component_count"), components .. " sound components")
		assert_true(components < limit("max_sound_data"), components .. " sound resources")
	end)
end)

-- tools/audio/gen_audio.py measures every file it writes: what the checks promise, read back from the manifest
describe("the audio manifest of the jukebox songs", function()
	local songs = manifest.songs

	it("measures every song of the catalogue and nothing else", function()
		local count = 0
		for _, d in ipairs(districts) do
			for _, s in ipairs(d.songs) do
				count = count + 1
				local m = songs[s.id]
				assert_true(m ~= nil, s.id .. " is not in the manifest")
				assert_eq(m.genre, d.id)
				assert_eq(m.bpm, s.bpm)
				assert_eq(m.bars, s.bars)
				assert_eq(m.key, d.key, s.id .. " is not in the key of its genre")
				assert_eq(m.path, "assets/music/songs/" .. s.id .. ".ogg")
			end
		end
		local n = 0
		for _ in pairs(songs) do n = n + 1 end
		assert_eq(n, count)
		assert_eq(manifest.counts.songs, count)
	end)

	it("keeps every loop exact, seamless and in the length range of a loop", function()
		for id, m in pairs(songs) do
			assert_eq(m.samples, m.loop_samples, id)
			assert_eq(m.sample_rate, 22050)
			assert_eq(m.loop_samples, math.floor(m.bars * 4 * 60 / m.bpm * 22050 + 0.5), id .. " is not bars x 4 x 60 / bpm long")
			assert_true(m.loop_seconds >= 16 and m.loop_seconds <= 32, id)
			assert_true(m.seam.step_vs_beats <= 1.5 and m.seam.click_vs_beats <= 1.5 and m.seam.codec_edge <= 1.5, id .. " clicks at the loop point")
		end
	end)

	it("holds the loudness contract of the music", function()
		for id, m in pairs(songs) do
			assert_true(m.true_peak_dbtp <= -1.0 and m.peak_dbfs <= -1.0, id .. " peaks at " .. m.true_peak_dbtp .. " dBTP")
			assert_true(math.abs(m.lufs - m.lufs_target) <= 1.0, id .. " is " .. m.lufs .. " LUFS")
			assert_true(m.limiter_gr_db >= -5 and m.limiter_energy_gr_db >= -1, id .. " was squashed by the limiter")
		end
	end)

	it("stays in the key of its genre, so the notes and effects transposed to it stay consonant", function()
		for id, m in pairs(songs) do
			assert_true(m.harmony_in_scale_pct >= 85, id .. " has only " .. m.harmony_in_scale_pct .. " % of its pitched energy in key")
		end
	end)

	it("costs at most 6 MB, with the rest of the audio under its old budget", function()
		local bytes = 0
		for _, m in pairs(songs) do bytes = bytes + m.bytes end
		assert_true(bytes <= 6 * 1024 * 1024, "the songs weigh " .. bytes .. " bytes")
		assert_true(manifest.total_bytes - bytes <= 7 * 1024 * 1024, "the rest of the audio grew")
	end)

	it("passes every check the generator ran", function()
		assert_true(#manifest.checks > 0)
		for _, line in ipairs(manifest.checks) do
			assert_true(string.find(line, "FAIL", 1, true) == nil, line)
		end
		local songs_lines = 0
		for _, line in ipairs(manifest.checks) do
			if string.find(line, "^Songs `") then songs_lines = songs_lines + 1 end
		end
		assert_eq(songs_lines, #districts, "one check line per genre")
	end)

end)
