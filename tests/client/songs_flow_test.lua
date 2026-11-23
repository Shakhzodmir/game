-- The song picked in the jukebox STAYS: every place that starts music (entering the town, paging the districts,
-- the next district, a level start, the next launch of the game) plays it instead of the track of the district.
-- One thing ends it: building a layer of the town. A stem joins only the layered theme of its own district, so a
-- song (or the theme of another district) would swallow the new layer, the best moment of the game: the pick gives
-- way and the town's own track comes back with the layer in it (client/songs.lua yield_to_layer).
-- Run on the strict GUI stubs: the real town script and the real board script, with the messages they send to the
-- audio script recorded (tests/client/meta_audio_script_test.lua runs that script); the last block runs the real
-- audio script next to the town and listens to what it plays.

local G = require("tests.client.meta_gui_helper")
local stub = require("tests.client.level_defold_stub")
local save_io = require("client.save_io")
local songs = require("client.songs")
local meta_qa = require("client.meta_qa")
local H = require("tests.meta.helper")

local AUDIO = "main:/audio#audio"

local function music(c)
	local out = {}
	for _, m in ipairs(c.E.posted("music", AUDIO)) do out[#out + 1] = m.message end
	return out
end

local function last(c)
	local list = music(c)
	return list[#list]
end

local function tap_target(c, name)
	local t = c.app.ui.targets and c.app.ui.targets[name]
	assert_true(t ~= nil, "no target " .. name)
	c.tap(t.x, t.y)
end

local function wait_for(c, pred, seconds, what)
	for _ = 1, math.ceil((seconds or 5) * 60) do
		if pred() then return end
		c.step(1)
	end
	assert_true(pred(), "timed out waiting for " .. tostring(what))
end

local function cafe_done(app) G.build_tasks(app, "cafe") end

describe("the picked song stays in the town", function()
	it("is what the town asks for when it opens, and again on the next launch of the game", function()
		local backend = save_io.memory_backend()
		G.with_town({ backend = backend, setup = function(app) cafe_done(app); assert(app.set_song("bossa_breeze")) end }, function(c)
			assert_same(last(c), { district = "bossa_breeze" })
		end)
		-- the game starts again: the save holds the pick, the town plays it (not the district)
		G.with_town({ backend = backend }, function(c)
			assert_eq(c.app.meta:song(), "bossa_breeze")
			assert_eq(c.app.snapshot().song, "bossa_breeze")
			assert_same(last(c), { district = "bossa_breeze" })
			for _, m in ipairs(music(c)) do assert_eq(m.district, "bossa_breeze") end
		end)
	end)

	it("plays the district again when nothing is picked", function()
		G.with_town({ setup = cafe_done }, function(c)
			assert_eq(c.app.snapshot().song, nil)
			assert_same(last(c), { district = "jazz" })
		end)
	end)

	it("keeps playing while the player pages through the districts", function()
		G.with_town({ setup = function(app) cafe_done(app); assert(app.set_song("scat_parade")) end }, function(c)
			assert_eq(c.app.ui.district, "jazz")
			tap_target(c, "nav_prev")
			wait_for(c, function() return c.app.ui.district == "cafe" and not c.app.ui.sliding end, 3, "paging back")
			c.run(0.5)
			assert_eq(c.app.ui.district, "cafe", "the cafe is on display")
			for _, m in ipairs(music(c)) do assert_eq(m.district, "scat_parade", "the song never gives way to the track of a district") end
			tap_target(c, "nav_next")
			wait_for(c, function() return c.app.ui.district == "jazz" and not c.app.ui.sliding end, 3, "paging forward")
			assert_same(last(c), { district = "scat_parade" })
		end)
	end)

	it("hears the district it pages to when nothing is picked", function()
		G.with_town({ setup = cafe_done }, function(c)
			tap_target(c, "nav_prev")
			wait_for(c, function() return c.app.ui.district == "cafe" and not c.app.ui.sliding end, 3, "paging back")
			assert_same(last(c), { district = "cafe" })
		end)
	end)

	it("gives way to the town's own track when a layer is built: a song has no such stem, the layer must be heard", function()
		G.with_town({ setup = function(app) G.give_stars(app, 4); assert(app.set_song("rainy_window")) end }, function(c)
			assert_same(last(c), { district = "rainy_window" })
			local n = #music(c)
			tap_target(c, "task")
			wait_for(c, function() return not c.app.ui.busy end, 6, "the task animation")
			assert_eq(c.app.meta:district("cafe").done, 1)
			assert_eq(c.app.meta:song(), nil, "the pick is cleared by the purchase")
			assert_eq(c.app.snapshot().song, nil)
			assert_eq(#music(c), n + 1, "the town's track was asked for, once")
			assert_same(last(c), { district = "cafe" })
			local stems = c.E.posted("unlock_stem", AUDIO)
			assert_eq(#stems, 1, "the stem is announced as well")
			assert_eq(stems[1].message.stem, "beat")
			-- and the player is told why his song stopped
			wait_for(c, function() return c.app.overlay.toast == "The town music is back" end, 3, "the toast")
		end)
	end)

	it("does the same when a tap skips the show: the stem is announced, the pick is cleared", function()
		G.with_town({ setup = function(app) G.give_stars(app, 4); assert(app.set_song("rainy_window")) end }, function(c)
			local n = #music(c)
			tap_target(c, "task")
			c.run(0.25) -- the stars are still flying: the light has not reached the item
			assert_true(c.app.ui.busy)
			assert_eq(c.app.meta:song(), "rainy_window", "not yet: the layer has not joined")
			c.tap(360, 800) -- anywhere
			c.step(3)
			assert_false(c.app.ui.busy)
			assert_eq(c.app.meta:district("cafe").done, 1)
			assert_eq(c.app.meta:song(), nil)
			assert_eq(#music(c), n + 1)
			assert_same(last(c), { district = "cafe" })
			assert_eq(#c.E.posted("unlock_stem", AUDIO), 1)
			c.run(0.7)
			assert_eq(c.app.overlay.toast, "The town music is back")
			-- a second layer, with no song picked any more: nothing to say, nothing to restart
			G.give_stars(c.app, 1)
			c.app.meta:mark_tutorial_seen("town_first_task")
			local m = #music(c)
			c.step(5)
			tap_target(c, "task")
			wait_for(c, function() return not c.app.ui.busy end, 6, "the second task")
			assert_eq(#music(c), m, "no pick: the track plays on")
			assert_eq(#c.E.posted("unlock_stem", AUDIO), 2)
		end)
	end)

	it("lets the stem of the picked theme join it, without a restart or a word: that pick has the layer", function()
		G.with_town({ setup = function(app) G.give_stars(app, 4); assert(app.meta:complete_task("cafe", "turntable")); app.commit("t"); assert(app.set_song("cafe")) end }, function(c)
			assert_same(last(c), { district = "cafe" })
			local n = #music(c)
			tap_target(c, "task")
			wait_for(c, function() return not c.app.ui.busy end, 6, "the task animation")
			local stems = c.E.posted("unlock_stem", AUDIO)
			assert_eq(#stems, 1)
			assert_eq(stems[1].message.district, "cafe")
			assert_eq(#music(c), n)
			assert_eq(c.app.meta:song(), "cafe", "the pick stays")
			c.run(0.7)
			assert_eq(c.app.overlay.toast, nil, "nothing to tell: the music is the same")
		end)
	end)

	it("goes on into the next district after the concert of a finished one, with a pick that took the last layer", function()
		G.with_town({ setup = function(app)
			G.win(app, 1)
			G.build_tasks(app, "cafe", 5)
			G.give_stars(app, 3)
			assert(app.set_song("cafe")) -- the theme of the district being finished: the last layer joins it
		end }, function(c)
			tap_target(c, "task")
			wait_for(c, function() return c.app.ui.popup == "concert" end, 8, "the concert")
			-- the concert is its own full song; the pick comes back as soon as it is over
			assert_same(last(c), { district = "cafe", all = true })
			c.run(0.8)
			c.tap(360, 640) -- a tap skips the concert
			wait_for(c, function() return c.app.ui.popup == "chest" end, 4, "the district chest")
			c.run(0.5)
			local t = c.app.ui.popup_targets.chest
			c.tap(t.x, t.y)
			wait_for(c, function() return c.app.ui.popup_targets and c.app.ui.popup_targets.collect ~= nil end, 4, "the open chest")
			c.run(1.2)
			t = c.app.ui.popup_targets.collect
			c.tap(t.x, t.y)
			wait_for(c, function() return not c.app.ui.busy end, 12, "the flights and the next district")
			assert_eq(c.app.ui.district, "jazz")
			assert_same(last(c), { district = "cafe", all = true }, "the finished theme goes on, not the track of the jazz bar")
			assert_eq(c.app.meta:song(), "cafe")
		end)
	end)

	it("clears a song that was picked before the LAST layer too: the jazz bar then plays its own track", function()
		G.with_town({ setup = function(app)
			G.win(app, 1)
			G.build_tasks(app, "cafe", 5)
			G.give_stars(app, 3)
			assert(app.set_song("rainy_window"))
		end }, function(c)
			tap_target(c, "task")
			wait_for(c, function() return c.app.ui.popup == "concert" end, 8, "the concert")
			assert_eq(c.app.meta:song(), nil, "the last layer was heard: the song gave way")
			c.run(0.8)
			c.tap(360, 640)
			wait_for(c, function() return c.app.ui.popup == "chest" end, 4, "the district chest")
			c.run(0.5)
			local t = c.app.ui.popup_targets.chest
			c.tap(t.x, t.y)
			wait_for(c, function() return c.app.ui.popup_targets and c.app.ui.popup_targets.collect ~= nil end, 4, "the open chest")
			c.run(1.2)
			t = c.app.ui.popup_targets.collect
			c.tap(t.x, t.y)
			wait_for(c, function() return not c.app.ui.busy end, 12, "the flights and the next district")
			assert_eq(c.app.ui.district, "jazz")
			assert_same(last(c), { district = "jazz" })
		end)
	end)
end)

-- the rule on its own: which pick a new layer would drown
describe("songs.yield_to_layer", function()
	local function with_meta(setup, fn)
		G.with_town({ town = false, setup = setup }, function(c) fn(c, c.app.meta) end)
	end

	it("leaves the music alone when nothing is picked", function()
		with_meta(function() end, function(c, m)
			local n = #music(c)
			assert_false(songs.yield_to_layer("cafe"))
			assert_eq(#music(c), n)
			assert_eq(m:song(), nil)
		end)
	end)

	it("clears a picked song, and the town's track of the district on display plays", function()
		with_meta(function(app) assert(app.set_song("rainy_window")) end, function(c, m)
			assert_eq(m:song(), "rainy_window")
			assert_true(songs.yield_to_layer("cafe"))
			assert_eq(m:song(), nil)
			assert_same(last(c), { district = "cafe" })
			assert_false(songs.yield_to_layer("cafe"), "nothing left to clear")
		end)
	end)

	it("keeps the theme of the district the layer belongs to, and clears the theme of another one", function()
		with_meta(function(app) G.build_tasks(app, "cafe", 1); assert(app.set_song("cafe")) end, function(c, m)
			local n = #music(c)
			assert_false(songs.yield_to_layer("cafe"), "the layer joins that theme")
			assert_eq(m:song(), "cafe")
			assert_eq(#music(c), n)
			assert_true(songs.yield_to_layer("jazz"), "the cafe theme has no jazz stem")
			assert_eq(m:song(), nil)
		end)
	end)

	it("tells why the song stopped in one readable line, in every language", function()
		local want = { en = "The town music is back", ru = "Музыка города вернулась", ko = "마을 음악이 돌아왔어요" }
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			G.with_town({ town = false, language = lang }, function(c)
				c.app.toast_key("town.music_back", nil, { color = "blue", duration = 1 })
				c.overlay:run(0.8)
				assert_eq(c.app.overlay.toast, want[lang])
				local list = c.overlay:smallest_texts(1)
				assert_true(list[1] ~= nil, lang .. ": the toast is on screen")
				-- the toast is ONE line scaled to the canvas width: a long text becomes tiny (15 px is the project's floor)
				assert_true(list[1].px >= 18, lang .. ": only " .. string.format("%.1f", list[1].px) .. " px")
				assert_eq(#c.E.audit(), 0, lang .. ": every glyph is in the font")
			end)
		end
	end)

	it("ignores a pick that is not valid any more: it plays nothing, so it drowns nothing", function()
		local save = require("meta.save")
		with_meta(function(app)
			local t = H.json_round_trip(app.meta:serialize())
			t.prefs.song = "bossa_breeze" -- a jazz song, and the jazz bar is locked
			t.checksum = save.checksum(t)
			assert(app.replace_save(t))
		end, function(c, m)
			assert_eq(m:song(), nil)
			assert_false(songs.yield_to_layer("cafe"))
		end)
	end)
end)

describe("songs.resolve: what plays where", function()
	local function done(m, did, count)
		local d = m:district(did)
		for i, t in ipairs(d.tasks) do
			if not t.done and (count == nil or i <= count) then
				H.give(m, "stars", t.cost)
				assert(m:complete_task(did, t.id))
			end
		end
	end

	it("plays the track of the district when nothing is picked, the same in the town and in a level", function()
		local m = H.new()
		for _, ctx in ipairs({ "town", "level" }) do
			assert_same(songs.resolve(m, "cafe", ctx), { id = "cafe", all = false, chosen = false, kind = "theme", district = "cafe" })
		end
	end)

	it("plays a song of a genre as that one mix, in the town and in a level", function()
		local m = H.new()
		assert_true(m:set_song("pixel_cafe"))
		for _, ctx in ipairs({ "town", "level" }) do
			local r = songs.resolve(m, "jazz", ctx)
			assert_same(r, { id = "pixel_cafe", all = false, chosen = true, kind = "song", district = "cafe" })
		end
	end)

	it("plays the theme of a district being built with the layers built so far", function()
		local m = H.new()
		done(m, "cafe", 2)
		assert_true(m:set_song("cafe"))
		for _, ctx in ipairs({ "town", "level" }) do
			local r = songs.resolve(m, "cafe", ctx)
			assert_eq(r.id, "cafe")
			assert_false(r.all)
			assert_eq(r.party, nil)
			assert_eq(r.kind, "theme")
		end
	end)

	it("plays the theme of a finished district in full in the town and without the party layer in a level", function()
		local m = H.new()
		done(m, "cafe")
		assert_true(m:set_song("cafe"))
		local town = songs.resolve(m, "jazz", "town")
		assert_same({ town.id, town.all, town.party, town.district }, { "cafe", true, nil, "cafe" })
		local level = songs.resolve(m, "jazz", "level")
		assert_same({ level.id, level.all, level.party }, { "cafe", true, false })
	end)

	it("ignores a pick that is not valid any more and plays the district", function()
		local m = H.new()
		local back = require("meta.meta").load(H.districts(), (function()
			local t = H.json_round_trip(m:serialize())
			t.prefs.song = "bossa_breeze" -- locked
			t.checksum = require("meta.save").checksum(t)
			return t
		end)(), nil, 7, H.T0)
		assert_same(songs.resolve(back, "cafe", "town"), { id = "cafe", all = false, chosen = false, kind = "theme", district = "cafe" })
		assert_eq(songs.resolve(nil, "cafe", "town").id, "cafe")
	end)
end)

describe("the QA commands of the jukebox", function()
	it("picks a song like a tap on its row and follows the town again with none", function()
		G.with_town({ setup = cafe_done }, function(c)
			local h = meta_qa.handlers()
			local r = h.song({ "scat_parade" })
			assert_true(r.ok)
			assert_eq(r.song, "scat_parade")
			assert_eq(c.app.snapshot().song, "scat_parade")
			assert_same(last(c), { district = "scat_parade" })
			r = h.song({ "square" })
			assert_false(r.ok)
			assert_eq(r.error, "locked")
			assert_eq(r.song, "scat_parade", "a refused pick changes nothing")
			assert_eq(h.song({ "no_such_song" }).error, "unknown_song")
			r = h.song({ "none" })
			assert_true(r.ok)
			assert_eq(r.song, nil)
			assert_same(last(c), { district = "jazz" })
			assert_true(h.song({ "jazz" }).ok == false, "the theme of a district without a layer cannot be picked")
			assert_true(h.song({}).ok, "no argument follows the town")
		end)
	end)
end)

-- the board script of a level: its music
describe("the level screen starts the picked song too", function()
	local function level_music(prepare)
		local E = stub.install({})
		local result
		local ok, err = pcall(function()
			local app = require("client.app")
			require("client.services.analytics").init({ strict = true })
			app.init({
				districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
				now = H.T0, clock = function() return H.T0 end, sys_language = "en",
			})
			if prepare then prepare(app) end
			app.params = { level = 1 }
			local script = stub.load_script("screens/level/board.script")
			local self = {}
			script.init(self)
			assert_true(not self.failed, "the board failed to start")
			result = {}
			for _, m in ipairs(E.msgs) do
				if m.id == "music" then result[#result + 1] = m.message end
			end
			pcall(script.final, self)
		end)
		stub.restore()
		if not ok then error(err, 0) end
		return result
	end

	local function build(app, did, count)
		local d = app.meta:district(did)
		for i, t in ipairs(d.tasks) do
			if not t.done and (count == nil or i <= count) then
				H.give(app.meta, "stars", t.cost)
				assert(app.meta:complete_task(did, t.id))
			end
		end
	end

	it("plays the district when nothing is picked", function()
		assert_same(level_music(), { { district = "cafe" } })
	end)

	it("plays the picked song instead of the district", function()
		assert_same(level_music(function(app) assert(app.set_song("sleepy_cat")) end), { { district = "sleepy_cat" } })
	end)

	it("plays the picked theme of a finished district without the party layer (it belongs to the final concert)", function()
		local list = level_music(function(app)
			build(app, "cafe")
			assert(app.set_song("cafe"))
		end)
		assert_same(list, { { district = "cafe", all = true, party = false } })
	end)

	it("plays the layers built so far of a picked theme", function()
		local list = level_music(function(app)
			build(app, "cafe", 3)
			assert(app.set_song("cafe"))
		end)
		assert_same(list, { { district = "cafe" } }, "`all` is left out of the message when the district is not finished")
	end)
end)

-- the whole game: the real app script, the town, the level screen and the audio object in one session
describe("a whole session with the audio object", function()
	local S = require("tests.client.session_harness")
	local flow = require("client.flow")
	local audio = require("client.audio")

	local function in_town(s)
		s:step_until(function() return s.app.screen == "town" and not s.app.transitioning end, 10, "the town")
		s:run(1)
	end

	-- the tracks the game asks the audio object for while fn runs (client/audio.lua music())
	local function asked_for(fn)
		local list = {}
		local real = audio.music
		audio.music = function(id, opts)
			list[#list + 1] = id
			return real(id, opts)
		end
		local ok, err = pcall(fn)
		audio.music = real
		if not ok then error(err, 0) end
		return list
	end

	it("keeps the picked song in the town, in a level and on the way back; the way home brings the district back", function()
		S.run({ audio = true, setup = function(app) assert(flow.debug_win(3)) end }, function(s)
			in_town(s)
			local theme = s.app.ui.district
			assert_eq(audio.status.song, theme, "no pick: the track of the district on display")
			assert_false(audio.status.single)
			-- the QA command picks like a tap on a row
			local res = s:qa("song sleepy_cat")
			assert_true(res.ok, tostring(res.error))
			s:run(0.5)
			assert_eq(s.app.snapshot().song, "sleepy_cat")
			assert_eq(audio.status.song, "sleepy_cat")
			assert_true(audio.status.single)
			assert_eq(audio.status.district, "cafe")
			-- a level starts with the song: it asks for it (never for the track of its district) and it keeps playing
			local asked = asked_for(function()
				assert_true(s:qa("goto level 5").ok)
				s:step_until(function() return s.app.screen == "level" and not s.app.transitioning end, 10, "the level")
				s:run(1)
			end)
			assert_true(#asked >= 1, "the level asked for its music")
			for _, id in ipairs(asked) do assert_eq(id, "sleepy_cat", "the level asks for the song of the player") end
			assert_eq(audio.status.song, "sleepy_cat")
			assert_true(audio.status.playing)
			-- and back in the town it is still the song
			assert_true(s:qa("goto town").ok)
			in_town(s)
			assert_eq(audio.status.song, "sleepy_cat")
			-- the way home: the track of the district on display plays again
			assert_true(s:qa("song none").ok)
			s:run(0.5)
			assert_eq(s.app.snapshot().song, nil)
			assert_eq(audio.status.song, s.app.ui.district)
			assert_false(audio.status.single)
		end)
	end)

	-- A new layer joins only the layered theme of its own district; a picked song is one mix. Without the rule the
	-- first purchase of a player who tapped any song in the jukebox was silent ('+ Beat!' and nothing new to hear).
	for _, skip in ipairs({ false, true }) do
		it("hears the layer that is built while a song is picked: the town's track comes back with it" .. (skip and " (a tap skips the show)" or ""), function()
			S.run({ audio = true, setup = function(app)
				assert(flow.debug_win(3))
				assert(app.set_song("rainy_window"))
			end }, function(s)
				in_town(s)
				assert_eq(audio.status.song, "rainy_window")
				assert_true(audio.status.single)
				assert_eq(audio.status.stems_on, 1, "the song is the only thing to hear")
				s:tap_target("task")
				if skip then
					s:run(0.25)
					assert_true(s.app.ui.busy)
					s:tap(360, 800)
					s:step(3)
				end
				s:step_until(function() return not s.app.ui.busy end, 30, "the task animation")
				s:run(1.5) -- the tracks have crossfaded
				assert_eq(s.app.meta:district("cafe").done, 1)
				assert_eq(s.app.snapshot().song, nil, "the pick gave way")
				assert_eq(audio.status.song, "cafe", "the town's own track is back")
				assert_false(audio.status.single)
				assert_true(audio.status.playing)
				assert_eq(audio.status.stems_on, 1, "and its one layer on is the one just built")
				assert_eq(audio.status.tracks, 1, "one track at a time")
			end)
		end)
	end

	it("plays a song or a district with the QA `music` command and refuses what is no track", function()
		S.run({ audio = true, setup = function(app) assert(flow.debug_win(3)) end }, function(s)
			in_town(s)
			local res = s:qa("music bossa_breeze")
			assert_true(res.ok, tostring(res.error))
			assert_eq(res.track, "bossa_breeze")
			s:run(0.3)
			assert_eq(audio.status.song, "bossa_breeze")
			assert_eq(audio.status.district, "jazz")
			assert_eq(audio.status.semitones, -2, "the key of the song that plays")
			assert_eq(s.app.snapshot().song, nil, "a raw track is not a pick")
			res = s:qa("music cafe all")
			assert_true(res.ok)
			s:run(0.3)
			assert_eq(audio.status.song, "cafe")
			res = s:qa("music no_such_track")
			assert_false(res.ok)
			assert_eq(res.error, "unknown_track")
			s:run(0.3)
			assert_eq(audio.status.song, "cafe", "a refused request changes nothing")
		end)
	end)
end)
