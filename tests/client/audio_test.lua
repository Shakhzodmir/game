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

	it("toggles the tension and party layers and remembers them for the next track", function()
		mixer:start("cafe", 90, STEMS, {}, 0)
		assert_true(mixer:set_layer("tension", true))
		mixer:update(1)
		assert_eq(mixer:gain("tension"), 1)
		mixer:start("jazz", 96, STEMS, {}, 5)
		assert_eq(mixer:gain("tension"), 1)
		mixer:set_layer("tension", false)
		mixer:update(1)
		assert_eq(mixer:gain("tension"), 0)
		assert_false(mixer:set_layer("beat", true))
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

	it("applies the settings volumes", function()
		mixer:set_volumes(0.5, 2)
		assert_near(mixer:music_group_gain(), 0.5, 1e-12)
		assert_eq(mixer:sfx_group_gain(), 1)
	end)

	it("stops and reports the stems to stop", function()
		mixer:start("cafe", 90, STEMS, {}, 0)
		local stopped = mixer:stop()
		assert_eq(#stopped, 5)
		assert_false(mixer:playing())
		assert_eq(mixer:clock(10), nil)
	end)
end)
