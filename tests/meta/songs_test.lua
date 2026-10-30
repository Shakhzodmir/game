-- The jukebox in the meta: the catalogue (songs[] of every district), which songs are open, the pick the player
-- saves with the prefs, and how a save with a bad pick loads.

local town = require("meta.town")
local prefs = require("meta.prefs")
local save = require("meta.save")
local Meta = require("meta.meta")
local H = require("tests.meta.helper")

local T = H.T0

-- Builds `count` tasks of a district (all of them without count) through the meta.
local function build(m, did, count)
	local d = m:district(did)
	for i, t in ipairs(d.tasks) do
		if not t.done and (count == nil or i <= count) then
			H.give(m, "stars", t.cost)
			assert(m:complete_task(did, t.id))
		end
	end
end

local function resign(t)
	t.checksum = save.checksum(t)
	return t
end

-- a save of `m` whose prefs.song is replaced (and the checksum made valid again)
local function with_song(m, value)
	local t = H.json_round_trip(m:serialize())
	t.prefs.song = value
	return resign(t)
end

describe("jukebox catalogue (content/districts.json)", function()
	local list = H.districts().districts

	it("gives every district a genre name and at least three songs of its own", function()
		for _, d in ipairs(list) do
			assert_true(type(d.genre) == "table" and d.genre.en and d.genre.ru, d.id .. " has no genre name in both languages")
			assert_true(#d.songs >= 3, d.id .. " has " .. #d.songs .. " songs")
			for _, s in ipairs(d.songs) do
				assert_true(s.name.en and s.name.ru and s.bpm and s.bars, "song " .. s.id .. " is incomplete")
			end
		end
	end)

	it("has at least fifteen new songs, unique ids, and never an id of a district", function()
		local seen, n = {}, 0
		for _, d in ipairs(list) do seen[d.id] = true end
		for _, d in ipairs(list) do
			for _, s in ipairs(d.songs) do
				n = n + 1
				assert_false(seen[s.id], "id " .. s.id .. " is used twice")
				seen[s.id] = true
			end
		end
		assert_true(n >= 15, "only " .. n .. " songs")
	end)

	it("is validated when the meta starts", function()
		local m = H.new()
		assert_same(m:song_info("bossa_breeze"), { id = "bossa_breeze", district = "jazz", theme = false })
		assert_same(m:song_info("jazz"), { id = "jazz", district = "jazz", theme = true })
		assert_eq(m:song_info("nothing"), nil)
		assert_eq(m:song_info(7), nil)
		local function broken(edit)
			local d = H.districts_copy()
			edit(d)
			return function() town.validate(d) end
		end
		assert_error(broken(function(d) d.districts[1].songs = "all of them" end), "songs must be a list")
		assert_error(broken(function(d) d.districts[1].songs[1].id = "Rainy Window" end), "needs an id")
		assert_error(broken(function(d) d.districts[1].songs[1].id = nil end), "needs an id")
		assert_error(broken(function(d) d.districts[1].songs[2].id = d.districts[1].songs[1].id end), "repeats the id")
		assert_error(broken(function(d) d.districts[2].songs[1].id = d.districts[1].songs[1].id end), "repeats the id")
		assert_error(broken(function(d) d.districts[1].songs[1].id = "jazz" end), "repeats the id")
		assert_error(broken(function(d) d.districts[1].songs[1].id = string.rep("a", 41) end), "needs an id")
		-- a district without songs is fine (the theme is its only song)
		local d = H.districts_copy()
		d.districts[3].songs = nil
		assert_eq(#town.validate(d).list[3].songs, 0)
	end)
end)

describe("which songs are open", function()
	it("opens the genre of a district that is current or complete, a theme once it has a layer", function()
		local m = H.new()
		-- the first district is open from the start: its songs at once, its theme after the first task
		assert_true(m:set_song("rainy_window"))
		assert_true(m:set_song("sleepy_cat"))
		assert_same({ m:set_song("cafe") }, { false, "no_layers" })
		build(m, "cafe", 1)
		assert_true(m:set_song("cafe"))
		-- the next genre is locked until its district opens
		assert_same({ m:set_song("bossa_breeze") }, { false, "locked" })
		assert_same({ m:set_song("jazz") }, { false, "locked" })
		build(m, "cafe")
		assert_true(m:set_song("bossa_breeze"), "the jazz genre opens with the chest of the cafe")
		assert_same({ m:set_song("jazz") }, { false, "no_layers" }) -- its theme has no layer yet
		assert_same({ m:set_song("candy_rush") }, { false, "locked" })
	end)

	it("says why a pick is refused and never changes the pick then", function()
		local m = H.new()
		assert_true(m:set_song("pixel_cafe"))
		assert_same({ m:set_song("no_such_song") }, { false, "unknown_song" })
		assert_same({ m:set_song("surf_splash") }, { false, "locked" })
		assert_eq(m:song(), "pixel_cafe")
		assert_error(function() m:set_song(5) end, "song id")
		assert_error(function() m:set_song({}) end, "song id")
	end)
end)

describe("the pick of the jukebox", function()
	it("starts empty, is set, replaced and cleared", function()
		local m = H.new()
		assert_eq(m:song(), nil)
		assert_true(m:set_song("rainy_window"))
		assert_eq(m:song(), "rainy_window")
		assert_true(m:set_song("pixel_cafe"))
		assert_eq(m:song(), "pixel_cafe")
		assert_true(m:set_song(nil))
		assert_eq(m:song(), nil)
	end)

	it("changes the save only when the pick changes, and moves no coins", function()
		local m = H.new()
		m:serialize() -- saved
		m:drain_ledger()
		assert_false(m:dirty())
		local coins = m:coins()
		assert_true(m:set_song("rainy_window"))
		assert_true(m:dirty())
		m:serialize()
		assert_true(m:set_song("rainy_window"))
		assert_false(m:dirty(), "the same pick again is nothing to save")
		assert_true(m:set_song(nil))
		assert_true(m:dirty())
		m:serialize()
		assert_true(m:set_song(nil))
		assert_false(m:dirty())
		assert_eq(m:coins(), coins)
		assert_same(m:drain_ledger(), {}, "a pick is not a purchase")
	end)

	it("is saved with the other prefs and survives a JSON round trip", function()
		local m = H.new()
		build(m, "cafe")
		m:set_setting("music", 0.4)
		assert_true(m:set_song("bossa_breeze"))
		local t = H.json_round_trip(m:serialize())
		assert_eq(t.prefs.song, "bossa_breeze")
		local back = Meta.load(H.districts(), t, nil, 7, T)
		assert_eq(back:song(), "bossa_breeze")
		assert_eq(back:settings().music, 0.4)
		assert_same(back:song_info(back:song()), { id = "bossa_breeze", district = "jazz", theme = false })
	end)

	it("is not in the save when nothing was picked (the format of an old save is unchanged)", function()
		local m = H.new()
		local t = m:serialize()
		assert_eq(t.prefs.song, nil)
		assert_eq(t.version, 1)
		local back = Meta.load(H.districts(), H.json_round_trip(t), nil, 7, T)
		assert_eq(back:song(), nil)
		-- the pick is cleared again: the key leaves the save
		m:set_song("rainy_window")
		m:set_song(nil)
		assert_eq(m:serialize().prefs.song, nil)
	end)

	it("is forgotten by a new game", function()
		local m = H.new()
		m:set_song("rainy_window")
		assert_eq(H.new():song(), nil)
	end)
end)

describe("a save with a bad pick", function()
	local function loads_as_nothing(value, why)
		local m = H.new()
		build(m, "cafe", 2)
		local back, info = Meta.load(H.districts(), with_song(m, value), nil, 7, T)
		assert_eq(info.source, "current", why)
		assert_eq(back:song(), nil, why)
		assert_eq(back:district("cafe").done, 2, "the rest of the save is kept: " .. why)
		-- and the player can pick again at once
		assert_true(back:set_song("rainy_window"))
	end

	it("loads without a pick when the id is not an id", function()
		loads_as_nothing(5, "a number")
		loads_as_nothing(true, "a boolean")
		loads_as_nothing({ "rainy_window" }, "a table")
		loads_as_nothing("", "an empty string")
		loads_as_nothing("Rainy Window", "capitals and a space")
		loads_as_nothing("rainy-window", "a dash")
		loads_as_nothing("1st_song", "a digit first")
		loads_as_nothing(string.rep("a", 41), "an id that is too long")
	end)

	it("loads without a pick when the song is unknown (a song left the content)", function()
		loads_as_nothing("a_song_that_was_removed", "unknown")
	end)

	it("loads without a pick when the genre is locked, and plays it once the genre opens", function()
		local m = H.new()
		build(m, "cafe", 2)
		local back = Meta.load(H.districts(), with_song(m, "bossa_breeze"), nil, 7, T)
		assert_eq(back:song(), nil, "the jazz genre is locked")
		assert_same({ back:set_song("bossa_breeze") }, { false, "locked" })
		-- the theme of a district with no layer is no pick either
		assert_eq(Meta.load(H.districts(), with_song(H.new(), "cafe"), nil, 7, T):song(), nil)
		-- the same save is fine for a player who got that far
		local far = H.new()
		build(far, "cafe")
		assert_eq(Meta.load(H.districts(), with_song(far, "bossa_breeze"), nil, 7, T):song(), "bossa_breeze")
	end)

	it("keeps a good pick across a repair of the rest of the save", function()
		local m = H.new()
		build(m, "cafe", 3)
		local t = H.json_round_trip(m:serialize())
		t.prefs.song = "cafe"
		t.prefs.settings.music = 7
		t.wallet.coins = -5
		local back = Meta.load(H.districts(), resign(t), nil, 7, T)
		assert_eq(back:song(), "cafe")
		assert_eq(back:settings().music, 1)
	end)
end)

describe("prefs.restore", function()
	it("keeps the shape of an id and drops everything else", function()
		assert_eq(prefs.song("bossa_breeze"), "bossa_breeze")
		assert_eq(prefs.song("a1"), "a1")
		for _, bad in ipairs({ "", "A", "a b", "a-b", "_a", "1a", "é", 5, true, false, {} }) do
			assert_eq(prefs.song(bad), nil, tostring(bad))
		end
		assert_eq(prefs.song(string.rep("a", 40)), string.rep("a", 40))
		assert_eq(prefs.song(string.rep("a", 41)), nil)
		assert_eq(prefs.restore({ song = "rainy_window" }).song, "rainy_window")
		assert_eq(prefs.restore({ song = 5 }).song, nil)
		assert_eq(prefs.restore(nil).song, nil)
		assert_same(prefs.restore({ song = "x_y" }).tutorial, {})
	end)
end)
