-- client/audio.lua tracks: a district id names a layered theme, a song id names ONE mix in the key of its genre.

local audio = require("client.audio")

describe("client.audio tracks: district themes and jukebox songs", function()
	-- a tiny registry: the cafe theme (two stems + the layers) and one song of the jazz genre
	local districts = {
		cafe = { id = "cafe", bpm = 90, semitones_from_c = 5 },
		jazz = { id = "jazz", bpm = 96, semitones_from_c = -2 },
	}
	local songs = { bossa_breeze = { id = "bossa_breeze", district = "jazz", bpm = 112 } }
	local deps = {
		district = function(id) return districts[id] end,
		song = function(id) return songs[id] end,
		stems = function(id) return id == "cafe" and { "bass", "beat", "party", "tension" } or {} end,
		stem_id = function(did, stem) return "music_" .. did .. "_" .. stem end,
		song_asset = function(id) return id == "bossa_breeze" and { id = "song_bossa_breeze", loop = 17.14 } or nil end,
		loop = function(id) return id == "cafe" and 21.33 or nil end,
	}

	it("resolves a district id to its layered theme", function()
		local t = audio.resolve_track("cafe", deps)
		assert_eq(t.id, "cafe")
		assert_eq(t.district, "cafe")
		assert_false(t.single)
		assert_eq(t.bpm, 90)
		assert_eq(t.semitones, 5)
		assert_eq(t.loop, 21.33)
		assert_same(t.stems, { "bass", "beat", "party", "tension" })
		assert_eq(t.ids.beat, "music_cafe_beat")
	end)

	it("resolves a song id to ONE mix in the key of its genre, at its own tempo", function()
		local t = audio.resolve_track("bossa_breeze", deps)
		assert_true(t.single)
		assert_eq(t.id, "bossa_breeze")
		assert_eq(t.district, "jazz")
		assert_eq(t.bpm, 112)
		assert_eq(t.semitones, -2, "the notes and effects follow the song that plays: Bb")
		assert_same(t.stems, { "mix" })
		assert_same(t.ids, { mix = "song_bossa_breeze" })
		assert_eq(t.loop, 17.14)
	end)

	it("resolves nothing for what is not there", function()
		assert_eq(audio.resolve_track("nowhere", deps), nil)
		assert_eq(audio.resolve_track(nil, deps), nil)
		assert_eq(audio.resolve_track("jazz", deps), nil, "a district without stems")
		songs.ghost = { id = "ghost", district = "jazz", bpm = 100 } -- in the catalogue, not in the registry
		assert_eq(audio.resolve_track("ghost", deps), nil)
		songs.ghost = nil
	end)

	it("starts a song as one stem at full gain, with no layers on", function()
		local mixer = audio.new_mixer()
		local t = audio.resolve_track("bossa_breeze", deps)
		local starts = mixer:start(t.id, t.bpm, t.stems, { mix = true }, 0, { loop = t.loop })
		assert_same(starts, { { stem = "mix", gain = 1 } })
		assert_eq(mixer.bpm, 112)
		assert_eq(mixer.loop, 17.14)
		assert_same(mixer.layers, { tension = false, party = false })
		-- the layers of a song are no stems: switching them is harmless
		assert_true(mixer:set_layer("tension", true))
		assert_eq(#mixer:update(1), 0)
		assert_eq(mixer:gain("mix"), 1)
		-- the loop is the clock of a resync
		assert_near(mixer:position(20), 20 % 17.14, 1e-9)
		assert_same(mixer:resync(20), { { stem = "mix", gain = 1, start_time = 20 % 17.14 } })
	end)

	it("lets a request turn the party layer of the full song off (a level) or on (the town)", function()
		local mixer = audio.new_mixer()
		local stems = { "beat", "bass", "tension", "party" }
		local function gains(starts)
			local g = {}
			for _, s in ipairs(starts) do g[s.stem] = s.gain end
			return g
		end
		assert_same(gains(mixer:start("cafe", 90, stems, {}, 0, { all = true })), { beat = 1, bass = 1, tension = 0, party = 1 })
		assert_same(gains(mixer:start("cafe", 90, stems, {}, 0, { all = true, party = false })), { beat = 1, bass = 1, tension = 0, party = 0 })
		assert_eq(mixer.layers.party, false)
		-- without the party layer the tension layer works again
		assert_true(mixer:set_layer("tension", true))
		assert_same(gains(mixer:start("cafe", 90, stems, { beat = true }, 0, { party = true })), { beat = 1, bass = 0, tension = 0, party = 1 })
	end)

	it("posts the request to the audio script with the song and the layer choice", function()
		local posted = {}
		local saved = rawget(_G, "msg")
		rawset(_G, "msg", { post = function(url, id, m) posted[#posted + 1] = { url = url, id = id, m = m } end })
		audio.music("bossa_breeze")
		audio.music("jazz", { all = true, party = false })
		audio.music("cafe", { all = true })
		rawset(_G, "msg", saved)
		assert_eq(#posted, 3)
		assert_eq(posted[1].id, "music")
		assert_eq(posted[1].url, audio.URL)
		assert_same(posted[1].m, { district = "bossa_breeze" })
		assert_same(posted[2].m, { district = "jazz", all = true, party = false })
		assert_same(posted[3].m, { district = "cafe", all = true })
	end)
end)
