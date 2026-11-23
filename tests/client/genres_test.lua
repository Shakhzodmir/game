-- The jukebox genres that are not districts (content/genres.json): the catalogue, the unlock switch
-- (meta/config.lua genres_unlock), the song of every room, and the window that pages through its genres (fifteen districts + 15 more):
-- the open tabs stand first in the row, the dark ones after them (a new player has four open tabs, a player who finished three
-- districts sixteen).

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

-- The order of the town: the fifteen districts, then the other genres in the order the districts open them (three
-- a district; inside a district the order of content/genres.json). The jukebox puts the open tabs first and keeps
-- this order inside the open ones and inside the dark ones.
local TOWN_DISTRICTS = { "cafe", "jazz", "square", "stadium", "garage", "beach", "carnival", "cinema", "bazaar", "skyclub",
	"block", "island", "ranch", "bluesclub", "arcade" }
local TOWN_GENRES = { "classical", "folk", "ambient", "rnb", "blues", "bossa", "latin", "eastern", "reggae", "pop", "edm",
	"chiptune", "hiphop", "country", "cinematic" }

local function ids(vm)
	local out = {}
	for i, tab in ipairs(vm.tabs) do out[i] = tab.id end
	return out
end

-- the lists joined into one
local function cat(...)
	local out = {}
	for _, list in ipairs({ ... }) do
		for _, v in ipairs(list) do out[#out + 1] = v end
	end
	return out
end

-- the items a..b of a list
local function span(list, a, b)
	local out = {}
	for i = a, b do out[#out + 1] = list[i] end
	return out
end

-- Every task of a district, built through the meta (the stars are test setup); the next district opens with the last one.
local function finish(m, id)
	for _, task in ipairs(m:district(id).tasks) do
		H.give(m, "stars", task.cost)
		assert_true(m:complete_task(id, task.id), id .. "/" .. task.id)
	end
end

-- The open tabs stand first, the dark ones after them, and inside each group the order of the town stays: tab.index is
-- the place of a tab in that order, so it grows along each group.
local function assert_open_first(vm, label)
	local dark, last = false, { [false] = 0, [true] = 0 }
	for _, tab in ipairs(vm.tabs) do
		local locked = tab.state == "locked"
		assert_true(locked or not dark, label .. ": " .. tab.id .. " is open but stands behind a dark tab")
		dark = dark or locked
		assert_true(tab.index > last[locked], label .. ": " .. tab.id .. " is out of the order of the town")
		last[locked] = tab.index
	end
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

	it("the jukebox view puts the open tabs first: a new player has four, the dark districts and the dark genres follow", function()
		with_mode("districts", function()
			local m = new_meta()
			local vm = views.jukebox(m, nil, nil)
			assert_eq(#vm.tabs, 30)
			-- Lo-fi and the three genres of the first district are the only tabs that play on the first day: they lead; the
			-- fourteen dark districts follow in the order of the town, then the twelve dark genres in the order the districts open them
			assert_same(ids(vm), { "cafe", "classical", "folk", "ambient",
				"jazz", "square", "stadium", "garage", "beach", "carnival", "cinema", "bazaar", "skyclub", "block", "island", "ranch",
				"bluesclub", "arcade",
				"rnb", "blues", "bossa", "latin", "eastern", "reggae", "pop", "edm", "chiptune", "hiphop", "country", "cinematic" })
			assert_eq(vm.tabs[1].state, "current")
			for i = 2, 4 do assert_eq(vm.tabs[i].state, "open", vm.tabs[i].id) end
			for i = 5, 30 do assert_eq(vm.tabs[i].state, "locked", vm.tabs[i].id) end
			assert_open_first(vm, "new player")
			-- the row shows three tabs a page: page 1 holds three open tabs, the fourth open one heads page 2 and no dark tab
			-- stands in front of an open one
			assert_eq(vm.tabs[4].id, "ambient")
			assert_eq(vm.tabs[5].id, "jazz")
			-- tab.index is the place in the order of the town, not in the row: a district keeps the number that picks its colour
			local by_tab = {}
			for _, tab in ipairs(vm.tabs) do by_tab[tab.id] = tab end
			assert_eq(by_tab.cafe.index, 1)
			assert_eq(by_tab.jazz.index, 2)
			assert_eq(by_tab.arcade.index, 15)
			assert_eq(by_tab.classical.index, 16)
			assert_eq(by_tab.cinematic.index, 30)
			for i, id in ipairs(TOWN_DISTRICTS) do assert_eq(by_tab[id].color, views.district_color(i), id) end
		end)
	end)

	it("a player who finished three districts: sixteen open tabs lead (the districts, then their genres), fourteen dark ones follow", function()
		with_mode("districts", function()
			local m = new_meta()
			for _, id in ipairs({ "cafe", "jazz", "square" }) do finish(m, id) end
			local vm = views.jukebox(m, nil, nil)
			-- the K-pop stadium is being built: it and the three genres of each of the four districts are open
			assert_same(ids(vm), { "cafe", "jazz", "square", "stadium",
				"classical", "folk", "ambient", "rnb", "blues", "bossa", "latin", "eastern", "reggae", "pop", "edm", "chiptune",
				"garage", "beach", "carnival", "cinema", "bazaar", "skyclub", "block", "island", "ranch", "bluesclub", "arcade",
				"hiphop", "country", "cinematic" })
			for i = 1, 3 do assert_eq(vm.tabs[i].state, "complete", vm.tabs[i].id) end
			assert_eq(vm.tabs[4].state, "current")
			for i = 5, 16 do assert_eq(vm.tabs[i].state, "open", vm.tabs[i].id) end
			for i = 17, 30 do assert_eq(vm.tabs[i].state, "locked", vm.tabs[i].id) end
			assert_open_first(vm, "three districts")
			-- the next district opens: its tab and its three genres move into the open ones, in their places
			finish(m, "stadium")
			vm = views.jukebox(m, nil, nil)
			assert_same(ids(vm), cat(span(TOWN_DISTRICTS, 1, 5), TOWN_GENRES, span(TOWN_DISTRICTS, 6, 15)))
			assert_eq(vm.tabs[5].state, "current")
			assert_eq(vm.tabs[20].state, "open")
			assert_eq(vm.tabs[21].state, "locked")
			assert_open_first(vm, "four districts")
		end)
	end)

	it("with nothing dark the order is the order of the town: the districts, then the genres", function()
		with_mode("districts", function()
			local m = new_meta()
			for _, id in ipairs(TOWN_DISTRICTS) do finish(m, id) end
			local vm = views.jukebox(m, nil, nil)
			assert_same(ids(vm), cat(TOWN_DISTRICTS, TOWN_GENRES))
			for _, tab in ipairs(vm.tabs) do assert_true(tab.state ~= "locked", tab.id) end
			assert_open_first(vm, "finished town")
		end)
	end)

	it("with every genre open from the start (genres_unlock = all) they still lead the dark districts", function()
		with_mode("all", function()
			local m = new_meta()
			local vm = views.jukebox(m, nil, nil)
			assert_same(ids(vm), cat({ "cafe" }, TOWN_GENRES, span(TOWN_DISTRICTS, 2, 15)))
			assert_eq(vm.tabs[1].state, "current")
			for i = 2, 16 do assert_eq(vm.tabs[i].state, "open", vm.tabs[i].id) end
			for i = 17, 30 do assert_eq(vm.tabs[i].state, "locked", vm.tabs[i].id) end
			assert_open_first(vm, "all genres open")
		end)
	end)

	it("the jukebox view lists the genres that are not districts with their group, icon and state, and each has songs of its own", function()
		with_mode("districts", function()
			local m = new_meta()
			local vm = views.jukebox(m, nil, nil)
			assert_eq(#vm.tabs, 30)
			local by_tab = {}
			for _, tab in ipairs(vm.tabs) do by_tab[tab.id] = tab end
			assert_eq(by_tab.classical.state, "open")
			assert_eq(by_tab.classical.group, "classic")
			assert_eq(by_tab.classical.icon, "ui/genres/classical")
			assert_eq(by_tab.ambient.state, "open")
			assert_eq(by_tab.rnb.state, "locked")
			assert_eq(by_tab.latin.state, "locked")
			for _, id in ipairs({ "jazz", "square", "stadium", "garage", "beach", "carnival", "cinema", "bazaar", "skyclub", "block",
				"island", "ranch", "bluesclub", "arcade" }) do
				assert_eq(by_tab[id].state, "locked", id)
			end
			assert_eq(#vm.songs.classical, 4)
			assert_true(vm.songs.classical[1].playable)
			assert_false(vm.songs.latin[1].playable)
			-- the district "carnival" (genre name Latin) and the extra genre "latin" are two tabs with their own songs
			assert_eq(#vm.songs.latin, 4)
			local by_id = {}
			for _, d in ipairs(H.districts().districts) do by_id[d.id] = d end
			local full = views.jukebox(m, by_id, nil)
			assert_eq(#full.songs.carnival, 5, "the theme and four songs")
			local seen = {}
			for _, id in ipairs({ "carnival", "latin" }) do
				for _, row in ipairs(full.songs[id]) do
					assert_true(seen[row.id] == nil, row.id .. " is in two genres")
					seen[row.id] = id
				end
			end
			-- the same for the district "cinema" (genre name Soundtrack) and the extra genre "cinematic"
			assert_eq(#full.songs.cinema, 5, "the theme and four songs")
			assert_eq(#full.songs.cinematic, 3)
			for _, id in ipairs({ "cinema", "cinematic" }) do
				for _, row in ipairs(full.songs[id]) do
					assert_true(seen[row.id] == nil, row.id .. " is in two genres")
					seen[row.id] = id
				end
			end
			-- and for the district "bazaar" (genre name Eastern Tales) and the extra genre "eastern"
			assert_eq(#full.songs.bazaar, 5, "the theme and four songs")
			assert_eq(#full.songs.eastern, 4)
			for _, id in ipairs({ "bazaar", "eastern" }) do
				for _, row in ipairs(full.songs[id]) do
					assert_true(seen[row.id] == nil, row.id .. " is in two genres")
					seen[row.id] = id
				end
			end
			-- and for the district "skyclub" (genre name Club Night) and the extra genre "edm", both in Ab
			assert_eq(#full.songs.skyclub, 5, "the theme and four songs")
			assert_eq(#full.songs.edm, 3)
			for _, id in ipairs({ "skyclub", "edm" }) do
				for _, row in ipairs(full.songs[id]) do
					assert_true(seen[row.id] == nil, row.id .. " is in two genres")
					seen[row.id] = id
				end
			end
			-- and for the district "block" (genre name Boom Bap, in Bb) and the extra genre "hiphop" (in Eb)
			assert_eq(#full.songs.block, 5, "the theme and four songs")
			assert_eq(#full.songs.hiphop, 3)
			for _, id in ipairs({ "block", "hiphop" }) do
				for _, row in ipairs(full.songs[id]) do
					assert_true(seen[row.id] == nil, row.id .. " is in two genres")
					seen[row.id] = id
				end
			end
			-- and for the district "island" (genre name Island Riddim, in A) and the extra genre "reggae" (in Bb)
			assert_eq(#full.songs.island, 5, "the theme and four songs")
			assert_eq(#full.songs.reggae, 3)
			for _, id in ipairs({ "island", "reggae" }) do
				for _, row in ipairs(full.songs[id]) do
					assert_true(seen[row.id] == nil, row.id .. " is in two genres")
					seen[row.id] = id
				end
			end
			-- and for the district "ranch" (genre name Hoedown, in G) and the extra genre "country" (in D)
			assert_eq(#full.songs.ranch, 5, "the theme and four songs")
			assert_eq(#full.songs.country, 3)
			for _, id in ipairs({ "ranch", "country" }) do
				for _, row in ipairs(full.songs[id]) do
					assert_true(seen[row.id] == nil, row.id .. " is in two genres")
					seen[row.id] = id
				end
			end
			-- and for the district "bluesclub" (genre name Evening Blues) and the extra genre "blues", both in E
			assert_eq(#full.songs.bluesclub, 5, "the theme and four songs")
			assert_eq(#full.songs.blues, 3)
			for _, id in ipairs({ "bluesclub", "blues" }) do
				for _, row in ipairs(full.songs[id]) do
					assert_true(seen[row.id] == nil, row.id .. " is in two genres")
					seen[row.id] = id
				end
			end
			-- and for the district "arcade" (genre name 8-Bit) and the extra genre "chiptune", both in C
			assert_eq(#full.songs.arcade, 5, "the theme and four songs")
			assert_eq(#full.songs.chiptune, 3)
			for _, id in ipairs({ "arcade", "chiptune" }) do
				for _, row in ipairs(full.songs[id]) do
					assert_true(seen[row.id] == nil, row.id .. " is in two genres")
					seen[row.id] = id
				end
			end
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
		assert_eq(#m:districts(), #H.districts().districts)
		assert_true(seen.beach, "district 6 has its own theme")
		assert_true(seen.carnival, "district 7 has its own theme")
		assert_true(seen.cinema, "district 8 has its own theme")
		assert_true(seen.bazaar, "district 9 has its own theme")
		assert_true(seen.skyclub, "district 10 has its own theme")
		assert_true(seen.block, "district 11 has its own theme")
		assert_true(seen.island, "district 12 has its own theme")
		assert_true(seen.ranch, "district 13 has its own theme")
		assert_true(seen.bluesclub, "district 14 has its own theme")
		assert_true(seen.arcade, "district 15 has its own theme")
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

-- The tab targets on the page of the row on display, left to right.
local function row_ids(c)
	local found = {}
	for name, t in pairs(c.app.ui.popup_targets) do
		local id = string.match(name, "^tab_(.+)$")
		if id then found[#found + 1] = { id = id, x = t.x } end
	end
	table.sort(found, function(a, b) return a.x < b.x end)
	local out = {}
	for i, f in ipairs(found) do out[i] = f.id end
	return out
end

-- How many tabs of the page on display are dark (a lock and "???").
local function dark_tabs(c)
	local n = 0
	for _, text in ipairs(c.town:texts(true)) do
		if text == "???" then n = n + 1 end
	end
	return n
end

local function close(c)
	c.app.close_popup()
	c.run(0.5)
end

-- cafe, jazz and square are built: the K-pop stadium is the district being built
local function three_districts(app)
	for _, id in ipairs({ "cafe", "jazz", "square" }) do G.build_tasks(app, id) end
end

describe("the jukebox window with thirty genres", function()
	it("a new player finds the tabs that play first: three open ones on page 1, the fourth heads page 2, the dark ones follow", function()
		G.with_town({}, function(c)
			open(c, "jukebox")
			local ui = c.app.ui.jukebox
			assert_eq(ui.tab_pages, 10)
			assert_eq(ui.tab, "cafe")
			assert_eq(ui.tab_page, 1)
			-- page 1: Lo-fi, Classical, Folk: a note and a name on each, no lock
			assert_same(row_ids(c), { "cafe", "classical", "folk" })
			assert_eq(dark_tabs(c), 0, "no dark tab on the first page")
			for _, text in ipairs({ "Lo-fi", "Classical", "Folk" }) do
				assert_true(c.town:has_text(text, true), "no tab '" .. text .. "' in: " .. G.dump(c.town))
			end
			-- page 2: the fourth open tab, then two dark ones
			wtap(c, "tabs_next")
			assert_eq(c.app.ui.jukebox.tab_page, 2)
			assert_same(row_ids(c), { "ambient", "jazz", "square" })
			assert_true(c.town:has_text("Ambient", true), G.dump(c.town))
			assert_eq(c.app.ui.jukebox.tab, "cafe", "turning the page does not change the genre")
			assert_eq(dark_tabs(c), 2)
			-- every page after it is dark: nothing a new player can play is hidden behind them
			for page = 3, 10 do
				wtap(c, "tabs_next")
				assert_eq(c.app.ui.jukebox.tab_page, page)
				assert_eq(dark_tabs(c), 3, "page " .. page)
			end
			-- the arrows go round to the first page, and the genres on it play at once
			wtap(c, "tabs_next")
			assert_eq(c.app.ui.jukebox.tab_page, 1)
			wtap(c, "tab_folk")
			assert_eq(c.app.ui.jukebox.tab, "folk")
			assert_true(c.town:has_text("Green Hill Jig", true), G.dump(c.town))
			wtap(c, "play_green_hill_jig")
			assert_eq(c.app.meta:song(), "green_hill_jig")
			assert_same(c.E.audit(), {})
		end)
	end)

	it("pages the open tabs first and the dark ones after them, three a page, and plays a song of a new genre", function()
		G.with_town({ setup = function(app) G.build_tasks(app, "cafe") end }, function(c)
			open(c, "jukebox")
			local ui = c.app.ui.jukebox
			assert_eq(ui.tab_pages, 10)
			assert_eq(ui.tab, "jazz", "the district being built is on display")
			assert_eq(ui.tab_page, 1)
			for _, name in ipairs({ "tabs_prev", "tabs_next" }) do
				assert_true(c.app.ui.popup_targets[name] ~= nil, "no target " .. name)
			end
			-- the whole row, page by page: eight open tabs (the two districts, then their six genres) and 22 dark ones
			local pages = {
				{ "cafe", "jazz", "classical" }, { "folk", "ambient", "rnb" }, { "blues", "bossa", "square" },
				{ "stadium", "garage", "beach" }, { "carnival", "cinema", "bazaar" }, { "skyclub", "block", "island" },
				{ "ranch", "bluesclub", "arcade" }, { "latin", "eastern", "reggae" }, { "pop", "edm", "chiptune" },
				{ "hiphop", "country", "cinematic" },
			}
			local dark = { 0, 0, 1, 3, 3, 3, 3, 3, 3, 3 }
			for page, want in ipairs(pages) do
				assert_eq(c.app.ui.jukebox.tab_page, page)
				assert_same(row_ids(c), want, "page " .. page)
				assert_eq(dark_tabs(c), dark[page], "dark tabs on page " .. page)
				assert_eq(c.app.ui.jukebox.tab, "jazz", "turning the page does not change the genre")
				wtap(c, "tabs_next")
			end
			assert_eq(c.app.ui.jukebox.tab_page, 1, "the arrows go round")
			wtap(c, "tabs_prev")
			assert_eq(c.app.ui.jukebox.tab_page, 10)
			assert_true(c.app.ui.popup_targets.tab_cinematic ~= nil)
			wtap(c, "tabs_next")
			assert_eq(c.app.ui.jukebox.tab_page, 1)
			-- the third tab of the first page is a genre that plays
			wtap(c, "tab_classical")
			assert_eq(c.app.ui.jukebox.tab, "classical")
			assert_true(c.town:has_text("Morning Salon", true), G.dump(c.town))
			assert_true(c.town:has_text("Classical", true))
			wtap(c, "play_salon_morning")
			assert_eq(c.app.meta:song(), "salon_morning")
			assert_eq(c.app.ui.jukebox.chosen, "salon_morning")
			assert_same(c.E.audit(), {})
		end)
	end)

	it("opens a player who finished three districts on the page of the district being built; the open tabs fill the pages before the dark ones", function()
		G.with_town({ setup = three_districts }, function(c)
			open(c, "jukebox")
			local ui = c.app.ui.jukebox
			assert_eq(ui.tab_pages, 10)
			assert_eq(ui.tab, "stadium", "the district being built")
			assert_eq(ui.tab_page, 2, "the fourth tab of the row sits on the second page")
			assert_same(row_ids(c), { "stadium", "classical", "folk" })
			-- sixteen open tabs: pages 1 to 5 and the first place of page 6; the dark ones follow
			wtap(c, "tabs_prev")
			local pages = {
				{ "cafe", "jazz", "square" }, { "stadium", "classical", "folk" }, { "ambient", "rnb", "blues" },
				{ "bossa", "latin", "eastern" }, { "reggae", "pop", "edm" }, { "chiptune", "garage", "beach" },
			}
			local dark = { 0, 0, 0, 0, 0, 2 }
			for page, want in ipairs(pages) do
				assert_eq(c.app.ui.jukebox.tab_page, page)
				assert_same(row_ids(c), want, "page " .. page)
				assert_eq(dark_tabs(c), dark[page], "dark tabs on page " .. page)
				assert_eq(c.app.ui.jukebox.tab, "stadium", "turning the page does not change the genre")
				wtap(c, "tabs_next")
			end
			assert_same(c.E.audit(), {})
		end)
	end)

	it("opens on the page that holds the genre of the pick, not on the page of the district on display", function()
		G.with_town({ setup = three_districts }, function(c)
			open(c, "jukebox")
			assert_eq(c.app.ui.jukebox.tab_page, 2)
			wtap(c, "tabs_next")
			assert_eq(c.app.ui.jukebox.tab_page, 3)
			wtap(c, "tab_ambient")
			wtap(c, "play_floating_clouds")
			assert_eq(c.app.meta:song(), "floating_clouds")
			close(c)
			-- a window that comes back forgets the page it was left on: the genre of the pick holds it
			open(c, "jukebox")
			local ui = c.app.ui.jukebox
			assert_eq(ui.tab, "ambient")
			assert_eq(ui.tab_page, 3)
			assert_same(row_ids(c), { "ambient", "rnb", "blues" })
			assert_eq(ui.chosen, "floating_clouds")
			-- the way home: the district on display holds it again
			wtap(c, "back_home")
			assert_eq(c.app.meta:song(), nil)
			close(c)
			open(c, "jukebox")
			assert_eq(c.app.ui.jukebox.tab, "stadium")
			assert_eq(c.app.ui.jukebox.tab_page, 2)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("fits every window size in both languages on every page (nothing cut)", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			G.with_town({ language = lang, setup = function(app) G.build_tasks(app, "cafe") end }, function(c)
				open(c, "jukebox")
				-- every page of the row: the open tabs, then the dark ones
				for page = 1, c.app.ui.jukebox.tab_pages do
					assert_same(G.overflows(c, 2), {}, lang .. " page " .. page)
					wtap(c, "tabs_next")
				end
			end)
		end
	end)
end)
