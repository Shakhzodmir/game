local level_audio = require("client.level_audio")

local function fake_audio()
	local calls = {}
	local a = {}
	function a.sfx(name, opts) calls[#calls + 1] = { "sfx", name, opts } end
	function a.play_note(color, wave, opts) calls[#calls + 1] = { "note", color, wave, opts } end
	function a.layer(name, on) calls[#calls + 1] = { "layer", name, on } end
	function a.combo(w) calls[#calls + 1] = { "combo", w } end
	return a, calls
end

local function names(calls, kind)
	local out = {}
	for _, c in ipairs(calls) do
		if c[1] == kind then out[#out + 1] = c[2] end
	end
	return out
end

describe("client.level_audio", function()
	it("plays a note per match: colour and wave, panned by column", function()
		local a, calls = fake_audio()
		local t = 0
		local la = level_audio.new({ audio = a, now = function() return t end, width = 7 })
		la:events({ { type = "match", color = "red", wave = 1, cells = { { 1, 3 }, { 2, 3 }, { 3, 3 } } } })
		la:events({ { type = "match", color = "blue", wave = 5, cells = { { 7, 1 }, { 7, 2 }, { 7, 3 } } } })
		local notes = {}
		for _, c in ipairs(calls) do if c[1] == "note" then notes[#notes + 1] = c end end
		assert_eq(#notes, 2)
		assert_eq(notes[1][2], "red")
		assert_eq(notes[1][3], 1)
		assert_true(notes[1][4].pan < 0)
		assert_eq(notes[2][3], 5)
		assert_true(notes[2][4].pan > 0)
		assert_same(names(calls, "combo"), { 5 }) -- a deep wave ducks the music
	end)

	it("rate-limits landing ticks and repeated effects", function()
		local a, calls = fake_audio()
		local t = 0
		local la = level_audio.new({ audio = a, now = function() return t end })
		for i = 1, 10 do
			la:event({ type = "land", id = i, x = i, y = 1 })
		end
		assert_eq(#names(calls, "sfx"), 1)
		t = 0.2
		la:event({ type = "land", id = 11, x = 1, y = 1 })
		assert_eq(#names(calls, "sfx"), 2)
		assert_true(calls[1][3].gain < 0.5) -- subtle
	end)

	it("maps specials, combos, blockers and praise to their effects", function()
		local a, calls = fake_audio()
		local t = 0
		local la = level_audio.new({ audio = a, now = function() t = t + 1; return t end })
		la:events({
			{ type = "activate", special = "sub" },
			{ type = "activate", special = "riff", combo = "cross" },
			{ type = "activate", special = "disco", combo = "finale" },
			{ type = "hit", layer = "blocker", item = "record_box", hp = 1 },
			{ type = "destroy", item = "concrete" },
			{ type = "floor_lit", x = 1, y = 1 },
			{ type = "freed", id = 3 },
			{ type = "mic_delivered", id = 4 },
			{ type = "praise", word = "drive", wave = 7 },
			{ type = "goal", index = 1, left = 0 },
			{ type = "goal", index = 1, left = 0 },
			{ type = "shuffle", moves = {} },
			{ type = "swap_fail" },
		})
		assert_same(names(calls, "sfx"), { "sub", "combo_drop", "finale", "box_hit", "concrete_break",
			"floor_light", "wires_snap", "mic_collect", "praise_3", "goal_done", "shuffle", "swap_fail" })
	end)

	it("plays the Disco arpeggio in its colour", function()
		local a, calls = fake_audio()
		local t = 0
		local la = level_audio.new({ audio = a, now = function() return t end })
		la:events({ { type = "activate", special = "disco", color = "green" },
			{ type = "disco_ray", x = 1, y = 1, tx = 2, ty = 2 }, { type = "disco_ray", x = 1, y = 1, tx = 3, ty = 3 } })
		local notes = {}
		for _, c in ipairs(calls) do if c[1] == "note" then notes[#notes + 1] = c end end
		assert_eq(#notes, 2)
		assert_eq(notes[1][2], "green")
		assert_eq(notes[2][3], notes[1][3] + 1)
	end)

	it("turns the tension layer on at 5 moves and party on in the concert", function()
		local a, calls = fake_audio()
		local t = 0
		local la = level_audio.new({ audio = a, now = function() t = t + 1; return t end })
		la:event({ type = "moves", left = 6 })
		assert_eq(#names(calls, "layer"), 0)
		la:event({ type = "moves", left = 5 })
		assert_same(names(calls, "sfx"), { "moves_low" })
		la:event({ type = "moves", left = 4 })
		assert_same(names(calls, "sfx"), { "moves_low" }) -- once
		la:event({ type = "moves", left = 9 }) -- +5 moves bought
		la:event({ type = "state", state = "won_wait" })
		la:event({ type = "state", state = "concert" })
		local layers = {}
		for _, c in ipairs(calls) do if c[1] == "layer" then layers[#layers + 1] = c[2] .. "=" .. tostring(c[3]) end end
		assert_same(layers, { "tension=true", "tension=false", "party=true" })
		la:event({ type = "moves", left = 2 }) -- concert Riffs spend the moves: no tension now
		la:finish()
		layers = {}
		for _, c in ipairs(calls) do if c[1] == "layer" then layers[#layers + 1] = c[2] .. "=" .. tostring(c[3]) end end
		assert_same(layers, { "tension=true", "tension=false", "party=true", "party=false" })
	end)

	it("clicks and buzzes on touch", function()
		local a, calls = fake_audio()
		local buzz = {}
		local la = level_audio.new({ audio = a, now = function() return 0 end, vibrate = function(ms) buzz[#buzz + 1] = ms end })
		la:touch()
		assert_same(names(calls, "sfx"), { "tap" })
		assert_eq(#buzz, 1)
	end)
end)
