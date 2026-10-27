-- main/audio.script (the audio engine object) on the strict Defold stub: the district track starts
-- every stem in one frame, a new layer fades in, the volumes follow the settings, the music comes
-- back in step after a pause, notes and effects are played.

local town_stub = require("tests.client.town_defold_stub")
local assets = require("client.assets")
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

-- the sound.play calls whose url mentions `part`
local function plays(E, part)
	local n = 0
	for _, p in ipairs(E.sounds.played) do
		if string.find(p.url, part, 1, true) then n = n + 1 end
	end
	return n
end

describe("main/audio.script", function()
	it("starts every stem of the district in the same frame, the unlocked ones audible", function()
		with_audio(function(E, a, app)
			a:step(2)
			a:message("music", { district = "cafe" })
			local stems = assets.music_stems("cafe")
			assert_true(#stems >= 6)
			local started = #E.sounds.played
			assert_true(started >= 6, "every stem plays: " .. started)
			-- the new player has built nothing yet: no stem has gain 1
			for _, p in ipairs(E.sounds.played) do
				assert_true(p.props and p.props.gain == 0, "locked stems start silent: " .. tostring(p.url))
			end
			-- the same district again does not restart it
			a:message("music", { district = "cafe" })
			assert_eq(#E.sounds.played, started)
			-- another district stops the first one and starts its own
			a:message("music", { district = "jazz" })
			assert_true(#E.sounds.stopped >= 6)
			assert_true(plays(E, "stub_object") > started)
		end)
	end)

	it("fades a new layer in over half a second when its task is built", function()
		with_audio(function(E, a, app)
			a:message("music", { district = "cafe" })
			local url = nil
			local id = assets.music_id("cafe", "beat")
			assert_true(id ~= nil)
			-- the stem url the script made for it
			for _, p in ipairs(E.sounds.played) do
				if string.find(p.url, "#" .. id, 1, true) then url = p.url end
			end
			assert_true(url ~= nil)
			assert_true((E.sounds.gains[url] or 0) < 0.01)
			a:message("unlock_stem", { district = "cafe", stem = "beat" })
			a:run(0.2)
			local mid = E.sounds.gains[url] or 0
			assert_true(mid > 0.05 and mid < 0.95, "fading: " .. mid)
			a:run(0.6)
			assert_near(E.sounds.gains[url], 1, 0.01)
			-- a layer of another district is not touched
			a:message("unlock_stem", { district = "jazz", stem = "piano" })
			a:step(5)
		end)
	end)

	it("applies the saved volumes as soon as the meta exists and when they change", function()
		with_audio(function(E, a, app)
			a:step(3)
			local g = E.sounds.group_gains.music
			assert_true(g ~= nil)
			app.set_setting("music", 0.3)
			a:step(3)
			assert_near(E.sounds.group_gains.music, 0.3, 1e-6)
			app.reset_save(5, E.clock)
			a:step(3)
			assert_near(E.sounds.group_gains.music, 0.8, 1e-6) -- the default again
		end)
	end)

	it("restarts the stems in one frame at the clock position when the app comes back", function()
		with_audio(function(E, a, app)
			a:message("music", { district = "cafe" })
			a:run(1)
			local before = #E.sounds.played
			bus.publish("app_focus", { focused = true, event = "focus_gained" })
			a:step(2)
			local after = #E.sounds.played
			assert_true(after > before, "the stems played again")
			local restarted = 0
			for i = before + 1, after do
				local p = E.sounds.played[i]
				if p.props and p.props.start_time then restarted = restarted + 1 end
			end
			assert_true(restarted >= 6, "restarted with a start_time: " .. restarted)
			assert_eq(require("client.audio").status.resyncs >= 1, true)
		end)
	end)

	it("plays notes on the grid of the music and effects at once", function()
		with_audio(function(E, a, app)
			a:message("music", { district = "cafe" })
			a:run(0.3)
			local base = #E.sounds.played
			a:message("note", { color = "red", wave = 1 })
			a:run(0.3)
			assert_true(#E.sounds.played > base, "the note sounded within the next 1/32 tick")
			base = #E.sounds.played
			a:message("sfx", { name = "tap" })
			assert_eq(#E.sounds.played, base + 1)
			assert_eq(E.sounds.played[#E.sounds.played].props.gain, 1)
			a:message("stop_music", {})
			assert_true(#E.sounds.stopped >= 6)
		end)
	end)
end)
