-- Part 2 (districts 16-30, levels 301-600; docs/design/part2-districts.md): the game is data, so the whole of Part 2
-- must work before its districts exist. The shipped districts.json (district 16 is the first of Part 2) is extended by
-- fictitious Part 2 districts of 20 levels up to district 30 and level 600, and played through the meta: the end of the
-- content, the level chests, the songbook, the town, a save that moves between builds in both directions (progress
-- never shrinks). The "Part 2" tag of the map gate and the town ribbon (client/app.lua part_opens) is checked here too.

local Meta = require("meta.meta")
local C = require("meta.config")
local town = require("meta.town")
local util = require("meta.util")
local H = require("tests.meta.helper")

local SHIPPED = H.districts().districts
local LAST = 600 -- district 30

-- The shipped districts plus Part 2 districts of 20 levels up to level 600 (district 30).
local function to_thirty()
	local d = util.copy(H.districts())
	local n = #d.districts
	while d.districts[n].last < LAST do
		local first = d.districts[n].last + 1
		n = n + 1
		local id = "p2_" .. n
		d.districts[n] = {
			id = id, part = 2, first = first, last = first + 19, name = { en = id, ru = id, ko = id },
			chest = { coins = 3200 + (n - 16) * 200, boosters = { "disco" } },
			tasks = {
				{ id = id .. "_1", cost = 1, stem = "beat" }, { id = id .. "_2", cost = 4, stem = "bass" },
				{ id = id .. "_3", cost = 5, stem = "keys" }, { id = id .. "_4", cost = 5, stem = "lead" },
				{ id = id .. "_5", cost = 5, stem = "pad" }, { id = id .. "_6", cost = 6, stem = "fx" },
			},
		}
	end
	return d
end

local function guarded(fn)
	local ok, err = pcall(fn)
	town.validate(H.districts())
	if not ok then error(err, 0) end
end

local function play_to(m, last, now)
	while m:level_to_play() and m:level_to_play() <= last do
		H.win(m, now, m:level_to_play() % 20 == 0 and "super_hard" or "easy", 3)
		H.claim_chests(m, now)
	end
end

describe("Part 2 at full size: 30 districts, 600 levels, by data only", function()
	it("district 16 is the first Part 2 district of the shipped data and ends at level 320 or later", function()
		assert_true(#SHIPPED >= 16)
		assert_eq(SHIPPED[16].id, "midnight_cafe")
		assert_eq(SHIPPED[16].part, 2)
		assert_eq(SHIPPED[16].first, 301)
		assert_eq(SHIPPED[16].last, 320)
		for i = 1, 15 do assert_eq(SHIPPED[i].part, nil, SHIPPED[i].id) end
	end)

	it("binds 600 levels in 30 stretches and plays 1..600 through the meta to the end of the content", function()
		guarded(function()
			local data = to_thirty()
			assert_eq(#data.districts, 30)
			local m = Meta.new(data, 7)
			assert_eq(C.levels.count, LAST)
			assert_eq(#C.songbook.districts, 30)
			play_to(m, 320, H.T0)
			assert_false(m:all_done(), "level 320 is not the end of a 600-level build")
			assert_eq(m:level_to_play(), 321)
			play_to(m, LAST - 1, H.T0)
			assert_eq(m:level_to_play(), LAST)
			local r = H.win(m, H.T0, "super_hard", 3)
			assert_eq(r.next_level, nil)
			assert_true(m:all_done())
			assert_eq(m:serialize().progress.beaten, LAST)
			-- every district has its whole song, Part 2 included
			for _, d in ipairs(data.districts) do
				local song = m:song_of(d.id)
				assert_eq(song.total, 20, d.id)
				assert_true(song.ready, d.id .. " song is ready")
			end
		end)
	end)

	it("pays every level chest of Part 2 once (every tenth level up to 600)", function()
		guarded(function()
			local m = Meta.new(to_thirty(), 7)
			play_to(m, 589, H.T0)
			H.win(m, H.T0, "easy", 3) -- level 590
			local waiting = {}
			for _, w in ipairs(m:pending_chests()) do waiting[w.level_id] = true end
			assert_true(waiting[590], "the chest of level 590 waits")
			local before = m:coins()
			H.claim_chests(m, H.T0)
			assert_true(m:coins() > before)
			assert_false(m:claim_level_chest(590, H.T0), "paid once")
		end)
	end)

	it("the town of 30 districts is built to the end: 30 district chests, 389 + 15 x 26 stars", function()
		guarded(function()
			local data = to_thirty()
			local cost = 0
			for _, d in ipairs(data.districts) do
				for _, t in ipairs(d.tasks) do cost = cost + t.cost end
			end
			assert_eq(cost, 389 + 15 * 26)
			local m = Meta.new(data, 7)
			play_to(m, LAST, H.T0)
			H.give(m, "stars", cost)
			local chests = 0
			while m:current_district() do
				local nt = m:next_task()
				local res = assert(m:complete_task(nt.district, nt.id))
				if res.chest then chests = chests + 1 end
			end
			assert_eq(chests, 30)
		end)
	end)

	it("a save of the 320-level build continues at 321 in the 600-level build, and the other way nothing is lost", function()
		guarded(function()
			local now = Meta.new(H.districts(), 7)
			play_to(now, SHIPPED[#SHIPPED].last, H.T0)
			assert_true(now:all_done())
			local saved = H.json_round_trip(now:serialize())
			local coins, stars = now:coins(), now:stars()
			local big = Meta.load(to_thirty(), saved, nil, 7, H.T0)
			assert_false(big:all_done())
			assert_eq(big:level_to_play(), SHIPPED[#SHIPPED].last + 1)
			assert_true(big:coins() >= coins, "coins never shrink")
			assert_true(big:stars() >= stars, "stars never shrink")
			play_to(big, LAST, H.T0)
			local back = Meta.load(H.districts(), H.json_round_trip(big:serialize()), nil, 7, H.T0)
			assert_eq(back:serialize().progress.beaten, LAST, "beaten is not cut to the levels of the smaller build")
			assert_true(back:all_done())
			assert_true(back:coins() >= big:coins())
		end)
	end)
end)

describe("the Part 2 tag (client/app.lua)", function()
	local app = require("client.app")

	local function with_districts(list, fn)
		local by_id, saved_by, saved_list = {}, app.district_by_id, app.district_list
		for _, d in ipairs(list) do by_id[d.id] = d end
		app.district_by_id, app.district_list = by_id, list
		local ok, err = pcall(fn)
		app.district_by_id, app.district_list = saved_by, saved_list
		if not ok then error(err, 0) end
	end

	it("district 16 opens Part 2; Part 1 districts and the later Part 2 districts do not", function()
		local list = to_thirty().districts
		local last = list[#list].id -- district 30: made up by to_thirty() while the shipped data ends earlier, real after
		with_districts(list, function()
			-- every id asked about is a district of the list: an id that is not there answers nil and proves nothing
			for _, id in ipairs({ "cafe", "arcade", "midnight_cafe", "late_club", "nations_fest", "night_carnival", last }) do
				assert_true(app.district(id) ~= nil, id .. " is a district of the list")
			end
			assert_eq(app.district_part("cafe"), 1)
			assert_eq(app.district_part("arcade"), 1)
			assert_eq(app.district_part("midnight_cafe"), 2)
			assert_eq(app.district_part("late_club"), 2)
			assert_eq(app.district_part("night_carnival"), 2)
			assert_eq(app.district_part(last), 2)
			assert_eq(app.district_part("nowhere"), 1)
			assert_eq(app.part_opens("midnight_cafe"), 2)
			assert_eq(app.part_opens("cafe"), nil)
			assert_eq(app.part_opens("arcade"), nil)
			assert_eq(app.part_opens("late_club"), nil)      -- district 17: Part 2 goes on, it does not open again
			assert_eq(app.part_opens("nations_fest"), nil)
			assert_eq(app.part_opens("night_carnival"), nil) -- district 22
			assert_eq(app.part_opens(last), nil)
			assert_eq(app.part_opens("nowhere"), nil)
			-- over the whole list: exactly one district opens Part 2, the first one of it
			local opening = {}
			for _, d in ipairs(list) do
				if app.part_opens(d.id) then opening[#opening + 1] = d.id .. "=" .. app.part_opens(d.id) end
			end
			assert_same(opening, { "midnight_cafe=2" })
		end)
	end)

	it("the tag needs the text of all three languages and it fits its gold plate", function()
		local i18n = require("client.i18n")
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			local s = i18n.t("part2.title", nil, lang)
			assert_true(type(s) == "string" and s ~= "" and s ~= "part2.title", lang)
			assert_true(#s <= 24, lang .. ": " .. s) -- a short word: 156-172 px of plate at 22-26 px
		end
	end)
end)
