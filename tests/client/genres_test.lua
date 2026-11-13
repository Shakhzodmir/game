-- The jukebox genres that are not districts (content/genres.json): the catalogue, the unlock switch
-- (meta/config.lua genres_unlock), the song of every room, and the window that pages through its genres (six districts + 15 more).

local G = require("tests.client.meta_gui_helper")
local json = require("tools.lib.json")
local Meta = require("meta.meta")
local C = require("meta.config")
local H = require("tests.meta.helper")
local songs = require("client.songs")
local views = require("client.views")

local function read(path)
	local f = assert(io.open(path, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

local genres_src = json.decode(read("content/genres.json")).genres

local function new_meta()
	local src = json.decode(read("content/districts.json"))
	src.genres = genres_src
	return Meta.new(src, 42), src
end

local function with_mode(mode, fn)
	local old = C.genres_unlock
	C.genres_unlock = mode
	local ok, err = pcall(fn)
	C.genres_unlock = old
	if not ok then error(err, 0) end
end

local function open(c, name)
	c.app.open_popup(name)
	c.run(0.6)
end

local function wtap(c, name)
	local t = c.app.ui.popup_targets and c.app.ui.popup_targets[name]
	assert_true(t ~= nil, "no target '" .. name .. "'")
	c.tap(t.x, t.y)
	c.step(2)
end

describe("content/genres.json", function()
	it("has 15 genres of three groups and 3-4 songs each, named in en, ru and ko", function()
		assert_eq(#genres_src, 15)
		local groups, total, ids = { classic = 0, traditional = 0, modern = 0 }, 0, {}
		for _, g in ipairs(genres_src) do
			groups[g.group] = (groups[g.group] or 0) + 1
			assert_true(g.name.en and g.name.ru and g.name.ko, g.id .. " name")
			assert_true(#g.songs >= 3 and #g.songs <= 5, g.id .. " has " .. #g.songs .. " songs")
			assert_true(g.semitones_from_c >= -6 and g.semitones_from_c <= 6, g.id .. " key")
			for _, s in ipairs(g.songs) do
				assert_true(s.name.en and s.name.ru and s.name.ko, s.id .. " name")
				local len = s.bars * 4 * 60 / s.bpm
				assert_true(len >= 16 and len <= 32, s.id .. " length " .. len)
				assert_true(not ids[s.id], "duplicate " .. s.id)
				ids[s.id] = true
				total = total + 1
			end
		end
		assert_eq(groups.classic, 1)
		assert_eq(groups.traditional, 3)
		assert_eq(groups.modern, 11)
		assert_eq(total, 49)
	end)

	it("is validated: a song id that is a district id, an unknown district or a repeated id fail", function()
		local _, src = new_meta()
		src.genres = json.decode(read("content/genres.json")).genres
		src.genres[1].songs[1].id = "cafe"
		assert_error(function() Meta.new(src, 1) end, "repeats the id")
		src.genres = json.decode(read("content/genres.json")).genres
		src.genres[2].district = "nowhere"
		assert_error(function() Meta.new(src, 1) end, "unknown district")
		src.genres = json.decode(read("content/genres.json")).genres
		src.genres[3].id = "jazz"
		assert_error(function() Meta.new(src, 1) end, "repeats the id")
	end)
end)

describe("genres open with their district (the default) or all at once (config)", function()
	it("by districts: only the genres of the first district are open at the start", function()
		with_mode("districts", function()
			local m = new_meta()
			local open_ids = {}
			for _, g in ipairs(m:genres()) do
				if g.open then open_ids[#open_ids + 1] = g.id end
			end
			assert_same(open_ids, { "classical", "folk", "ambient" })
			local ok, why = m:set_song("trap_playground")
			assert_false(ok)
			assert_eq(why, "locked")
			assert_true(m:set_song("salon_morning"))
			assert_eq(m:song(), "salon_morning")
			assert_eq(m:song_info("salon_morning").district, "classical")
			assert_eq(m:song_info("salon_morning").unlock, nil, "the catalogue entry keeps its old shape")
		end)
	end)

	it("all: every genre is open, a district theme still needs a built layer", function()
		with_mode("all", function()
			local m = new_meta()
			for _, g in ipairs(m:genres()) do assert_true(g.open, g.id) end
			assert_true(m:set_song("trap_playground"))
			assert_true(m:set_song("carnival_samba"))
			local ok, why = m:set_song("jazz")
			assert_false(ok)
			assert_eq(why, "no_layers")
			assert_true(m:set_song("trap_playground"))
			-- the pick is saved; back to "districts" it reads as nothing but is not erased
			local saved = m:serialize()
			assert_eq(saved.prefs.song, "trap_playground")
			C.genres_unlock = "districts"
			assert_eq(m:song(), nil)
			assert_eq(m:serialize().prefs.song, "trap_playground", "progress and prefs never shrink")
			C.genres_unlock = "all"
			assert_eq(m:song(), "trap_playground")
		end)
	end)

	it("the jukebox view lists the district genres first, then the others by group, with their state", function()
		with_mode("districts", function()
			local m = new_meta()
			local vm = views.jukebox(m, nil, nil)
			assert_eq(#vm.tabs, 21)
			assert_eq(vm.tabs[5].id, "garage")
			assert_eq(vm.tabs[6].id, "beach")
			assert_eq(vm.tabs[6].state, "locked")
			assert_eq(vm.tabs[7].id, "classical")
			assert_eq(vm.tabs[7].state, "open")
			assert_eq(vm.tabs[7].group, "classic")
			assert_eq(vm.tabs[7].icon, "ui/genres/classical")
			assert_eq(vm.tabs[9].id, "latin")
			assert_eq(vm.tabs[9].state, "locked")
			assert_eq(#vm.songs.classical, 4)
			assert_true(vm.songs.classical[1].playable)
			assert_false(vm.songs.latin[1].playable)
		end)
	end)
end)

describe("every room has its own song", function()
	it("with nothing picked a district plays its own theme, in the town and in a level", function()
		local m = new_meta()
		local seen = {}
		for _, d in ipairs(m:districts()) do
			for _, ctx in ipairs({ "town", "level" }) do
				local r = songs.resolve(m, d.id, ctx)
				assert_eq(r.id, d.id)
				assert_false(r.chosen)
				assert_eq(r.kind, "theme")
			end
			assert_true(not seen[d.id], "one theme per room")
			seen[d.id] = true
		end
		assert_eq(#m:districts(), 6)
	end)

	it("a pick wins over the room until the way home is taken", function()
		with_mode("all", function()
			local m = new_meta()
			assert_true(m:set_song("savanna_drums"))
			for _, d in ipairs(m:districts()) do
				local r = songs.resolve(m, d.id, "town")
				assert_eq(r.id, "savanna_drums")
				assert_true(r.chosen)
				assert_eq(r.district, "folk")
			end
			assert_true(m:set_song(nil))
			assert_eq(songs.resolve(m, "jazz", "town").id, "jazz")
		end)
	end)
end)

describe("the jukebox window with twenty-one genres", function()
	it("shows three tabs a page, pages with two arrows and plays a song of a new genre", function()
		G.with_town({ setup = function(app) G.build_tasks(app, "cafe") end }, function(c)
			open(c, "jukebox")
			local ui = c.app.ui.jukebox
			assert_eq(ui.tab_pages, 7)
			assert_eq(ui.tab_page, 1)
			for _, name in ipairs({ "tabs_prev", "tabs_next", "tab_cafe", "tab_jazz", "tab_square" }) do
				assert_true(c.app.ui.popup_targets[name] ~= nil, "no target " .. name)
			end
			assert_true(c.app.ui.popup_targets.tab_garage == nil, "the fifth genre is on the next page")
			wtap(c, "tabs_next")
			assert_eq(c.app.ui.jukebox.tab_page, 2)
			assert_true(c.app.ui.popup_targets.tab_garage ~= nil)
			assert_true(c.app.ui.popup_targets.tab_beach ~= nil, "the sixth district closes the second page")
			assert_true(c.app.ui.popup_targets.tab_classical == nil)
			wtap(c, "tabs_next")
			assert_eq(c.app.ui.jukebox.tab_page, 3)
			assert_true(c.app.ui.popup_targets.tab_classical ~= nil)
			assert_eq(c.app.ui.jukebox.tab, "jazz", "turning the page does not change the genre")
			wtap(c, "tab_classical")
			assert_eq(c.app.ui.jukebox.tab, "classical")
			assert_true(c.town:has_text("Morning Salon", true), G.dump(c.town))
			assert_true(c.town:has_text("Classical", true))
			wtap(c, "play_salon_morning")
			assert_eq(c.app.meta:song(), "salon_morning")
			assert_eq(c.app.ui.jukebox.chosen, "salon_morning")
			-- the last page is reachable and wraps round
			for _ = 1, 5 do wtap(c, "tabs_next") end
			assert_eq(c.app.ui.jukebox.tab_page, 1)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("fits every window size in both languages on every page (nothing cut)", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			G.with_town({ language = lang, setup = function(app) G.build_tasks(app, "cafe") end }, function(c)
				open(c, "jukebox")
				for page = 1, 7 do
					assert_same(G.overflows(c, 2), {}, lang .. " page " .. page)
					wtap(c, "tabs_next")
				end
			end)
		end
	end)
end)
