local audio = require("client.audio")

describe("client.audio maths", function()
	it("maps cascade waves to pentatonic steps and note files", function()
		assert_eq(audio.note_step(1), 0)
		assert_eq(audio.note_step(2), 1)
		assert_eq(audio.note_step(11), 10)
		assert_eq(audio.note_step(40), 10)
		assert_eq(audio.note_step(0), 0)
		local id, step = audio.note_id("red", 3)
		assert_eq(id, "note_red_3")
		assert_eq(step, 2)
		assert_eq((audio.note_id("blue", 99)), "note_blue_11")
	end)

	it("transposes by equal-tempered speed, clamped to +-7 semitones", function()
		assert_near(audio.transpose_speed(0), 1, 1e-12)
		assert_near(audio.transpose_speed(12 - 12), 1, 1e-12)
		assert_near(audio.transpose_speed(5), 2 ^ (5 / 12), 1e-12) -- F
		assert_near(audio.transpose_speed(-2), 2 ^ (-2 / 12), 1e-12) -- Bb
		assert_near(audio.transpose_speed(9), 2 ^ (7 / 12), 1e-12)
		assert_near(audio.transpose_speed(-12), 2 ^ (-7 / 12), 1e-12)
	end)

	it("quantizes to the next 1/32 note of the track clock", function()
		assert_near(audio.grid_step(100), 0.075, 1e-12) -- the 75 ms of the spec
		assert_near(audio.grid_step(120), 0.0625, 1e-12)
		assert_eq(audio.quantize_delay(nil, 100), 0)
		assert_eq(audio.quantize_delay(0, 100), 0)
		assert_near(audio.quantize_delay(0.01, 100), 0.065, 1e-9)
		assert_near(audio.quantize_delay(0.074, 100), 0.001, 1e-9)
		assert_eq(audio.quantize_delay(0.15, 100), 0)
		for i = 0, 200 do
			local clock = i * 0.0137
			local d = audio.quantize_delay(clock, 90)
			assert_true(d >= 0 and d < audio.grid_step(90), "delay in [0, step)")
			local pos = (clock + d) / audio.grid_step(90)
			assert_near(pos, math.floor(pos + 0.5), 1e-6)
		end
	end)

	it("converts decibels", function()
		assert_near(audio.db_to_gain(0), 1, 1e-12)
		assert_near(audio.db_to_gain(-6), 0.501187, 1e-6)
		assert_near(audio.gain_to_db(0.5), -6.0206, 1e-4)
		assert_eq(audio.gain_to_db(0), -math.huge)
	end)
end)

describe("client.audio mixer", function()
	local mixer
	local STEMS = { "beat", "vinyl", "keys", "tension", "party" }
	before_each(function() mixer = audio.new_mixer() end)

	it("starts every stem at once, locked ones at gain 0", function()
		local starts = mixer:start("cafe", 90, STEMS, { beat = true, vinyl = true }, 100)
		assert_eq(#starts, 5)
		local g = {}
		for _, s in ipairs(starts) do g[s.stem] = s.gain end
		assert_same(g, { beat = 1, vinyl = 1, keys = 0, tension = 0, party = 0 })
		assert_true(mixer:playing())
		assert_near(mixer:clock(101.5), 1.5, 1e-12)
	end)

	it("crossfades an unlocked stem over 0.5 s", function()
		mixer:start("cafe", 90, STEMS, { beat = true }, 0)
		assert_true(mixer:unlock("keys"))
		local ch = mixer:update(0.25)
		assert_eq(#ch, 1)
		assert_near(mixer:gain("keys"), 0.5, 1e-9)
		mixer:update(0.3)
		assert_eq(mixer:gain("keys"), 1)
		assert_eq(#mixer:update(0.1), 0)
		assert_false(mixer:unlock("nope"))
	end)

	it("toggles the tension and party layers, reset by a new track", function()
		mixer:start("cafe", 90, STEMS, {}, 0)
		assert_true(mixer:set_layer("tension", true))
		mixer:update(1)
		assert_eq(mixer:gain("tension"), 1)
		mixer:start("jazz", 96, STEMS, {}, 5)
		assert_eq(mixer:gain("tension"), 0)
		assert_false(mixer:set_layer("beat", true))
	end)

	it("never plays tension together with party", function()
		mixer:start("cafe", 90, STEMS, { beat = true }, 0)
		mixer:set_layer("tension", true)
		mixer:update(1)
		assert_true(mixer:set_layer("party", true)) -- the finale: party wins
		mixer:update(1)
		assert_eq(mixer:gain("party"), 1)
		assert_eq(mixer:gain("tension"), 0)
		local ok, why = mixer:set_layer("tension", true)
		assert_false(ok)
		assert_eq(why, "party_on")
		mixer:update(1)
		assert_eq(mixer:gain("tension"), 0)
		mixer:set_layer("party", false)
		assert_true(mixer:set_layer("tension", true))
	end)

	it("plays every task stem and party (not tension) in jukebox mode", function()
		local starts = mixer:start("cafe", 90, STEMS, {}, 0, { all = true })
		local g = {}
		for _, s in ipairs(starts) do g[s.stem] = s.gain end
		assert_same(g, { beat = 1, vinyl = 1, keys = 1, tension = 0, party = 1 })
		assert_false(mixer:set_layer("tension", true))
	end)

	it("applies instant fades at once, without NaN on a zero-length frame", function()
		mixer:start("cafe", 90, { "beat", "bass" }, { beat = true }, 0)
		mixer:fade("bass", 1, 0)
		local ch = mixer:update(0)
		assert_eq(mixer:gain("bass"), 1)
		assert_eq(#ch, 1)
		assert_eq(ch[1].stem, "bass")
		mixer:fade("beat", 0, 0)
		mixer:update(0)
		assert_eq(mixer:gain("beat"), 0)
		mixer:fade("beat", 1, 0.5)
		mixer:update(0)
		mixer:update(-1)
		mixer:update(0 / 0)
		assert_eq(mixer:gain("beat"), 0)
		mixer:update(0.25)
		assert_near(mixer:gain("beat"), 0.5, 1e-9)
		assert_eq(#mixer:update(0), 0)
	end)

	it("reuses its change list between frames", function()
		mixer:start("cafe", 90, { "beat", "bass" }, {}, 0)
		mixer:unlock("beat")
		local a = mixer:update(0.1)
		local b = mixer:update(0.1)
		assert_true(a == b)
		assert_eq(#b, 1)
	end)

	it("restarts every stem at the loop position to resync", function()
		mixer:start("cafe", 90, { "beat", "bass" }, { beat = true }, 100, { loop = 21.333333 })
		local r = mixer:resync(100 + 50)
		assert_eq(#r, 2)
		assert_near(r[1].start_time, 50 - 21.333333 * 2, 1e-6)
		assert_eq(r[1].gain, 1)
		assert_eq(r[2].gain, 0)
		mixer:stop()
		assert_eq(#mixer:resync(200), 0)
	end)

	it("ducks music -6 dB in levels and -3 dB more on big combos, then restores", function()
		mixer:set_volumes(1, 1)
		assert_near(mixer:music_group_gain(), 1, 1e-12)
		mixer:set_level_duck(true)
		for _ = 1, 30 do mixer:update(1 / 60) end
		assert_near(mixer:music_group_gain(), audio.db_to_gain(-6), 1e-9)
		assert_false(mixer:combo(2))
		assert_true(mixer:combo(5))
		for _ = 1, 30 do mixer:update(1 / 60) end
		assert_near(mixer:music_group_gain(), audio.db_to_gain(-9), 1e-9)
		for _ = 1, 120 do mixer:update(1 / 60) end
		assert_near(mixer:music_group_gain(), audio.db_to_gain(-6), 1e-9)
		mixer:set_level_duck(false)
		for _ = 1, 30 do mixer:update(1 / 60) end
		assert_near(mixer:music_group_gain(), 1, 1e-9)
	end)

	it("applies the settings volumes and the group gains of the manifest", function()
		mixer:set_volumes(0.5, 2)
		assert_near(mixer:music_group_gain(), 0.5, 1e-12)
		assert_eq(mixer:sfx_group_gain(), 1)
		assert_eq(mixer:notes_group_gain(), 1)
		mixer:set_volumes(0.8, 0.5)
		mixer:set_group_db({ music = 0, sfx = -6, notes = 0 })
		assert_near(mixer:sfx_group_gain(), 0.5 * audio.db_to_gain(-6), 1e-9)
		assert_near(mixer:notes_group_gain(), 0.5, 1e-9)
		mixer:set_level_duck(true)
		for _ = 1, 30 do mixer:update(1 / 60) end
		assert_near(mixer:music_group_gain(), 0.8 * audio.db_to_gain(-6), 1e-9) -- 0.4 at volume 0.8
	end)

	it("takes the ducking levels of the manifest", function()
		mixer:configure({ music_in_level_db = -6, music_big_combo_db = -9, group_gain_db = { music = -1, sfx = 0, notes = -2 } })
		mixer:set_volumes(1, 1)
		mixer:set_level_duck(true)
		mixer:combo(6)
		for _ = 1, 60 do mixer:update(1 / 60) end
		assert_near(mixer:music_group_gain(), audio.db_to_gain(-10), 1e-9)
		assert_near(mixer:notes_group_gain(), audio.db_to_gain(-2), 1e-9)
		mixer:configure(nil)
	end)

	it("stops and reports the stems to stop", function()
		mixer:start("cafe", 90, STEMS, {}, 0)
		local stopped = mixer:stop()
		assert_eq(#stopped, 5)
		assert_false(mixer:playing())
		assert_eq(mixer:clock(10), nil)
	end)
end)

describe("client.audio notes contract", function()
	local C = audio.contract({
		dedupe_same_file = true, max_voices = 3,
		stagger_s = { 0.01, 0.022, 0.034 }, gain_db_by_count = { 0.0, -4.5, -6.5 },
	})

	it("reads the contract of the manifest, with defaults", function()
		assert_eq(C.max_voices, 3)
		assert_same(C.stagger, { 0.01, 0.022, 0.034 })
		local d = audio.contract(nil)
		assert_same(d.gain_db_by_count, audio.NOTE_CONTRACT.gain_db_by_count)
		local bad = audio.contract({ max_voices = 3, stagger_s = { 0.01 } })
		assert_same(bad.stagger, audio.NOTE_CONTRACT.stagger)
	end)

	it("plays each file once, at most 3 voices (lowest steps), staggered, at the count gain", function()
		local notes = {
			{ id = "note_red_5", step = 4 }, { id = "note_blue_2", step = 1 }, { id = "note_red_5", step = 4 },
			{ id = "note_green_9", step = 8 }, { id = "note_yellow_1", step = 0 },
		}
		local v, st = audio.voices(notes, C)
		assert_eq(#v, 3)
		assert_eq(st.deduped, 1)
		assert_eq(st.capped, 1)
		assert_same({ v[1].id, v[2].id, v[3].id }, { "note_yellow_1", "note_blue_2", "note_red_5" })
		assert_same({ v[1].offset, v[2].offset, v[3].offset }, { 0.01, 0.022, 0.034 })
		for i = 1, 3 do assert_near(v[i].gain, audio.db_to_gain(-6.5), 1e-9) end
		local one = audio.voices({ { id = "a", step = 0, gain = 0.5 } }, C)
		assert_near(one[1].gain, 0.5, 1e-12)
		assert_eq(one[1].offset, 0.01)
		local two = audio.voices({ { id = "a", step = 3 }, { id = "b", step = 3 } }, C)
		assert_near(two[1].gain, audio.db_to_gain(-4.5), 1e-9)
		assert_eq(two[1].id, "a") -- equal steps keep the arrival order
	end)

	it("groups notes by tick and plays a tick once it is close", function()
		local s = audio.new_note_scheduler(C)
		local step = audio.grid_step(90)
		local k, at = audio.tick_of(0.01, 90)
		assert_eq(k, 1)
		assert_near(at, step, 1e-12)
		assert_true(s:add(k, at, { id = "a", step = 0 }))
		assert_true(s:add(k, at, { id = "b", step = 1 }))
		assert_eq(#s:take_due(0.01, audio.NOTE_HORIZON), 0) -- 73 ms away: later notes may join
		assert_true(s:add(k, at, { id = "c", step = 2 }))
		local due = s:take_due(at - 0.02, audio.NOTE_HORIZON)
		assert_eq(#due, 1)
		assert_eq(#due[1].voices, 3)
		-- that tick is gone: a late note goes to the next one
		assert_false(s:add(k, at, { id = "d", step = 0 }))
		assert_true(s:add(k + 1, at + step, { id = "d", step = 0 }))
		assert_eq(s:pending(), 1)
		local all = s:take_due(nil)
		assert_eq(#all, 1)
		s:reset()
		assert_true(s:add(0, 0, { id = "x", step = 0 }))
	end)

	it("quantizes every note of a tick to the same grid line", function()
		for i = 0, 50 do
			local clock = 3 + i * 0.0011
			local k, at = audio.tick_of(clock, 100)
			assert_true(at >= clock - 1e-9 and at - clock < audio.grid_step(100))
			assert_near(at, k * audio.grid_step(100), 1e-9)
		end
	end)

	it("transposes tonal effects to the district key and leaves the others", function()
		assert_eq(audio.sfx_semitones(nil, 5), nil)
		assert_eq(audio.sfx_semitones("C", 5), 5)   -- cafe, F
		assert_eq(audio.sfx_semitones("C", -2), -2) -- jazz, Bb
		assert_eq(audio.sfx_semitones("G", -2), 3)
		assert_eq(audio.sfx_semitones("H#", 3), nil)
		assert_eq(audio.key_semitones("Bb"), 10)
	end)
end)
