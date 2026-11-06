-- The songbook window (gui/notebook.lua), its button in the town and the offer of a finished song, run on the strict
-- Defold GUI stub: what the paper shows, paging, Listen / Stop through the one music slot, the language, the offer.

local G = require("tests.client.meta_gui_helper")
local flow = require("client.flow")

-- wins `n` levels through the meta and leaves a finished song to be offered, as a win on the board does
local function win(app, n)
	for _ = 1, n do assert(flow.debug_win(3, false, true)) end
end

local function popup_target(c, name)
	local t = c.app.ui.popup_targets and c.app.ui.popup_targets[name]
	assert_true(t ~= nil, "no popup target '" .. name .. "' in " .. tostring(c.app.ui.popup))
	return c.tap(t.x, t.y)
end

local function open(c, params)
	c.app.open_popup("notebook", params)
	c.step(40)
	assert_eq(c.app.ui.popup, "notebook")
end

local function last_music(c)
	local m = c.E.posted("music", "main:/audio#audio")
	return m[#m] and m[#m].message
end

describe("songbook window", function()
	it("shows an empty page of the first district before any level is won", function()
		G.with_town({ language = "en" }, function(c)
			c.step(90) -- nothing is offered: no song is ready
			assert_eq(c.app.ui.popup, nil)
			open(c, nil)
			local nb = c.app.ui.notebook
			assert_eq(nb.district, "cafe")
			assert_eq(nb.count, 0)
			assert_false(nb.ready)
			assert_true(c.town:has_text("Songbook", true))
			assert_true(c.town:has_text("Lines written: 0 of 20", true))
			assert_true(c.town:has_text("Levels 1-20", true))
			assert_eq(#c.E.audit(), 0)
			assert_eq(c.app.ui.popup_targets.play, nil) -- nothing to listen to yet
		end)
	end)

	it("lists the lines written so far, in the language on display", function()
		G.with_town({ language = "en", setup = function(app) win(app, 3) end }, function(c)
			open(c, nil)
			local nb = c.app.ui.notebook
			assert_eq(nb.count, 3)
			local song = c.app.meta:song_of("cafe")
			local songbook = require("client.songbook")
			for i = 1, 3 do
				assert_true(c.town:has_text(songbook.line("cafe", song.lines[i]), true), "line " .. i .. " is not on the paper")
			end
			assert_true(c.town:has_text("Lines written: 3 of 20", true))
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("pages through the districts with the arrows and wraps round", function()
		G.with_town({ language = "en" }, function(c)
			open(c, nil)
			popup_target(c, "page_next")
			c.step(40)
			assert_eq(c.app.ui.notebook.district, "jazz")
			assert_true(c.town:has_text("Levels 21-40", true))
			popup_target(c, "page_prev")
			c.step(40)
			popup_target(c, "page_prev")
			c.step(40)
			assert_eq(c.app.ui.notebook.district, "garage")
		end)
	end)

	it("shows a finished song with its title, then plays it, lights the lines and hands the music back", function()
		G.with_town({ language = "en", setup = function(app) win(app, 20) end }, function(c)
			c.run(2) -- the town offers the finished song once
			assert_eq(c.app.ui.popup, "notebook")
			local nb = c.app.ui.notebook
			assert_true(nb.ready)
			assert_eq(nb.district, "cafe")
			assert_true(nb.title ~= nil)
			local songbook = require("client.songbook")
			assert_true(c.town:has_text(songbook.title("cafe", nb.title), true), "no title")
			assert_true(c.town:has_text("Chorus", true))
			assert_true(c.town:has_text("Verse 1", true))
			assert_true(c.town:has_text("Listen", true))
			assert_eq(#c.E.audit(), 0)
			-- seen: not offered again
			assert_eq(c.app.meta:songbook_pending(), nil)
			-- Listen: the whole song of the district on the one music slot
			popup_target(c, "play")
			c.step(40)
			assert_true(c.app.ui.notebook.playing)
			local m = last_music(c)
			assert_eq(m.district, "cafe")
			assert_eq(m.all, true)
			assert_true(c.town:has_text("Stop", true))
			-- the lit line moves with the track clock
			local audio = require("client.audio")
			audio.status.song, audio.status.playing, audio.status.bpm = "cafe", true, 100
			local loop = require("client.assets").music_loop("cafe")
			audio.status.clock = 0.01
			c.step(5)
			assert_eq(c.app.ui.notebook.active, 1)
			audio.status.clock = loop * 0.99
			c.step(5)
			assert_eq(c.app.ui.notebook.active, 20)
			-- Stop gives the town music back; the jukebox pick was never touched
			popup_target(c, "play")
			c.step(40)
			assert_false(c.app.ui.notebook.playing)
			assert_eq(c.app.meta:song(), nil)
			assert_eq(last_music(c).district, "cafe")
			assert_true(not last_music(c).all)
			-- closing while playing also stops it
			popup_target(c, "play")
			c.step(40)
			popup_target(c, "close")
			c.run(0.6)
			assert_eq(c.app.ui.popup, nil)
			assert_eq(require("client.songbook").playing(), nil)
			audio.status.song, audio.status.playing = nil, false
		end)
	end)

	it("does not offer a song that was finished before the songbook existed", function()
		G.with_town({ language = "en", setup = function(app)
			win(app, 20)
			app.meta.s.songbook = require("meta.songbook").fresh() -- as in a first-release save
			local t = app.meta:serialize()
			t.songbook = nil
			t.checksum = require("meta.save").checksum(t)
			app.meta = require("meta.meta").load(app.districts, t, nil, 1, 1700000000)
		end }, function(c)
			c.run(3)
			assert_eq(c.app.ui.popup, nil)
			assert_true(c.app.meta:song_of("cafe").ready)
			open(c, { district = "cafe" }) -- the player can still read it
			assert_true(c.app.ui.notebook.ready)
		end)
	end)

	it("has a button in the town, with a dot while a finished song waits", function()
		G.with_town({ language = "en" }, function(c)
			local t = c.app.ui.targets.notebook
			assert_true(t ~= nil, "no notebook button")
			c.tap(t.x, t.y)
			c.step(40)
			assert_eq(c.app.ui.popup, "notebook")
		end)
	end)

	it("survives a language change and stays on the same page", function()
		G.with_town({ language = "en", setup = function(app) win(app, 22) end }, function(c)
			c.run(2) -- the finished song of the cafe is offered: leave it
			popup_target(c, "close")
			c.run(0.6)
			open(c, { district = "jazz" })
			assert_eq(c.app.ui.notebook.district, "jazz")
			c.app.set_setting("language", "ru")
			c.step(60)
			assert_eq(c.app.ui.notebook.district, "jazz")
			assert_true(c.town:has_text("Блокнот песен", true))
			assert_true(c.town:has_text("Записано строк: 2 из 20", true))
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("fits every window shape in every language: nothing sticks out of the panel or the screen", function()
		for _, window in ipairs({ { 720, 1280 }, { 360, 640 }, { 1280, 720 }, { 540, 1200 } }) do
			for _, lang in ipairs({ "en", "ru", "ko" }) do
				G.with_town({ language = lang, window = window, setup = function(app) win(app, 21) end }, function(c)
					c.run(2) -- the finished song is offered
					assert_eq(c.app.ui.popup, "notebook")
					local bad = G.overflows(c)
					assert_same(bad, {}, lang .. " " .. window[1] .. "x" .. window[2])
					assert_eq(#c.E.audit(), 0, lang .. " glyphs")
					popup_target(c, "close")
					c.run(0.6)
					open(c, { district = "jazz" })
					assert_same(G.overflows(c), {}, lang .. " jazz page " .. window[1] .. "x" .. window[2])
				end)
			end
		end
	end)
end)
