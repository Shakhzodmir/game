-- tools/check_content.lua: the content files agree (WP-13). In-memory content, no files written.

local Check = require("tools.check_content")
local json = require("tools.lib.json")
local C = require("meta.config")
local town = require("meta.town")

-- Synthetic game content: sizes = levels of every district, in order. Returns an fs table for Check.run and
-- the pieces (files, sb, ko), which a test breaks on purpose.
local function world(sizes)
	local files, districts, sb, ko = {}, { version = 1, districts = {} }, {}, {}
	local first, n = 1, 0
	local segments = {}
	for i, size in ipairs(sizes) do
		local id = "d" .. i
		districts.districts[i] = {
			id = id, first = first, last = first + size - 1,
			name = { ru = "Р" .. i, en = "D" .. i, ko = "구" .. i }, genre = { ru = "Ж", en = "G", ko = "장" },
			bpm = 100, key = "C", semitones_from_c = 0, bars = 8, mood = "x", songs = {},
			chest = { coins = 100, boosters = { "stick" } },
			tasks = {
				{ id = id .. "t1", name = { ru = "а", en = "a", ko = "가" }, cost = 1, stem = "beat" },
				{ id = id .. "t2", name = { ru = "б", en = "b", ko = "나" }, cost = 2, stem = "bass" },
			},
		}
		segments[i] = { id = id, district = id, first = first, last = first + size - 1 }
		for k = 1, C.songbook.pool do
			sb["sb." .. id .. "." .. k] = { en = "line", ru = "строка" }
			ko["sb." .. id .. "." .. k] = "줄"
		end
		for k = 1, C.songbook.titles do
			sb["sbt." .. id .. "." .. k] = { en = "title", ru = "название" }
			ko["sbt." .. id .. "." .. k] = "제목"
		end
		first = first + size
		n = n + size
	end
	files["content/districts.json"] = json.encode(districts)
	local stars, nodes = {}, {}
	for id = 1, n do
		files[string.format("content/levels/level_%04d.json", id)] = json.encode({ id = id })
		stars[tostring(id)] = { kind = "normal", t = { 100, 200, 300 } }
		nodes[id] = { level = id, x = 360, y = id * 100 }
	end
	files["content/levels/stars.json"] = json.encode({ version = 1, levels = stars })
	files["content/map.json"] = json.encode({ version = 1, level_count = n, nodes = nodes, segments = segments })
	local w = { files = files, sb = sb, ko = ko, n = n }
	function w.fs()
		return {
			read = function(path) return w.files[path] end,
			texts = function() return w.sb, w.ko end,
		}
	end
	function w.rewrite(path, fn)
		local t = json.decode(w.files[path])
		fn(t)
		w.files[path] = json.encode(t)
	end
	return w
end

local function run(w)
	local errors, info = Check.run(w.fs())
	town.validate(require("tests.meta.helper").districts()) -- put the shipped binding back
	return errors, info
end

local function has(errors, needle)
	for _, e in ipairs(errors) do
		if e:find(needle, 1, true) then return true end
	end
	return false
end

local function expect_error(w, needle)
	local errors = run(w)
	assert_true(has(errors, needle), "expected '" .. needle .. "' in:\n  " .. table.concat(errors, "\n  "))
end

describe("tools/check_content", function()
	it("accepts the shipped content", function()
		local errors, info = Check.run(Check.real_fs("."))
		assert_same(errors, {})
		local list = require("tests.meta.helper").districts().districts
		assert_eq(info.levels, list[#list].last)
		assert_eq(info.districts, #list)
	end)

	it("accepts a batch of new levels and a new district (120 levels, 6 districts of different sizes)", function()
		local errors, info = run(world({ 20, 20, 20, 20, 20, 20 }))
		assert_same(errors, {})
		assert_eq(info.levels, 120)
		errors, info = run(world({ 7, 32, 1, 20, 20 }))
		assert_same(errors, {})
		assert_eq(info.levels, 80)
	end)

	it("accepts 1000 levels in 40 districts", function()
		local sizes = {}
		for i = 1, 40 do sizes[i] = 25 end
		local errors, info = run(world(sizes))
		assert_same(errors, {})
		assert_eq(info.levels, 1000)
	end)

	it("names a missing level file and a file with the wrong id", function()
		local w = world({ 20, 20 })
		w.files["content/levels/level_0017.json"] = nil
		expect_error(w, "content/levels/level_0017.json: level 17 has no file")
		w = world({ 20, 20 })
		w.files["content/levels/level_0005.json"] = json.encode({ id = 6 })
		expect_error(w, "level_0005.json: level 5 says id 6")
	end)

	it("names a level file beyond the last district", function()
		local w = world({ 20, 20 })
		w.files["content/levels/level_0041.json"] = json.encode({ id = 41 })
		expect_error(w, "level_0041.json: level 41 is after the last level of districts.json (40)")
	end)

	it("names a gap, an overlap and a district that is too long", function()
		local w = world({ 20, 20 })
		w.rewrite("content/districts.json", function(t) t.districts[2].first = 22 end)
		expect_error(w, "d2: first level is 22, expected 21 (a gap")
		w = world({ 20, 20 })
		w.rewrite("content/districts.json", function(t) t.districts[2].first = 20 end)
		expect_error(w, "overlap")
		w = world({ C.songbook.pool + 1 })
		expect_error(w, "a district song has only")
	end)

	it("names missing star thresholds, an unknown level and bad thresholds", function()
		local w = world({ 20 })
		w.rewrite("content/levels/stars.json", function(t) t.levels["3"] = nil end)
		expect_error(w, "stars.json: level 3 has no star thresholds")
		w = world({ 20 })
		w.rewrite("content/levels/stars.json", function(t) t.levels["21"] = { kind = "normal", t = { 1, 2, 3 } } end)
		expect_error(w, "stars.json: names level 21, which is not in 1..20")
		w = world({ 20 })
		w.rewrite("content/levels/stars.json", function(t) t.levels["4"].t = { 300, 200, 100 } end)
		expect_error(w, "level 4: t must be three growing score thresholds")
	end)

	it("names a map that does not match the districts", function()
		local w = world({ 20, 20 })
		w.rewrite("content/map.json", function(t) t.level_count = 39 end)
		expect_error(w, "level_count is 39, the districts have 40 levels")
		w = world({ 20, 20 })
		w.rewrite("content/map.json", function(t) table.remove(t.nodes, 7) end)
		expect_error(w, "39 nodes")
		w = world({ 20, 20 })
		w.rewrite("content/map.json", function(t) t.segments[2].last = 39 end)
		expect_error(w, "segment 2 is d2 21-39, districts.json says d2 21-40")
		w = world({ 20, 20 })
		w.rewrite("content/map.json", function(t) t.segments[3] = { id = "x", district = "x", first = 41, last = 60 } end)
		expect_error(w, "3 segments, the districts are 2")
	end)

	it("names missing songbook texts in each language and a district without a Korean name", function()
		local w = world({ 20 })
		w.sb["sb.d1.5"] = { en = "only English" }
		expect_error(w, "client/i18n_songbook.lua: sb.d1.5 has no 'ru' text")
		w = world({ 20 })
		w.ko["sbt.d1.3"] = nil
		expect_error(w, "client/i18n_ko.lua: sbt.d1.3 is missing")
		w = world({ 20 })
		w.sb["sb.d1." .. C.songbook.pool] = nil
		expect_error(w, "sb.d1." .. C.songbook.pool .. " has no 'en' text")
		w = world({ 20 })
		w.rewrite("content/districts.json", function(t) t.districts[1].name.ko = nil end)
		expect_error(w, "district 1 (d1) name: no 'ko' text")
		w = world({ 20 })
		w.rewrite("content/districts.json", function(t) t.districts[1].tasks[2].name = nil end)
		expect_error(w, "task 2: a name in ru, en and ko is missing")
	end)

	it("names a level file far beyond the last level, a malformed threshold list and a bad stars key", function()
		local w = world({ 20 })
		w.files["content/levels/level_0400.json"] = json.encode({ id = 400 })
		expect_error(w, "level_0400.json: level 400 is after the last level")
		w = world({ 20 })
		w.rewrite("content/levels/stars.json", function(t) t.levels["2"].t = { "a", 2, 3 } end)
		expect_error(w, "level 2: t must be three growing score thresholds")
		w = world({ 20 })
		w.rewrite("content/levels/stars.json", function(t) t.levels["03"] = { kind = "normal", t = { 1, 2, 3 } } end)
		expect_error(w, "names level 03")
		w = world({ 20 })
		w.rewrite("content/districts.json", function(t) t.districts[1].map_tint = "red" end)
		expect_error(w, "map_tint must look like #RRGGBB")
	end)

	it("names a district without tasks (the rules of meta/town.lua)", function()
		local w = world({ 20 })
		w.rewrite("content/districts.json", function(t) t.districts[1].tasks = {} end)
		expect_error(w, "d1 has no tasks")
	end)
end)

describe("tools/levels.lua knows the number of levels from the data", function()
	it("reads the last level of the last district, 100 when there is no districts.json", function()
		local Levels = require("tools.levels")
		assert_eq(Levels.content_count("content/levels"), 100)
		assert_eq(Levels.content_count("no/such/dir"), 100)
		assert_eq(Levels.count_from('{"districts":[{"id":"a","last":20},{"id":"b","last":130}]}'), 130)
		assert_eq(Levels.count_from('{"districts":[{"id":"a","last":7}]}'), 7)
		assert_eq(Levels.count_from('{"districts":[{"id":"a"}]}'), 100)
		assert_eq(Levels.count_from("not json"), 100)
		assert_eq(Levels.count_from(nil), 100)
	end)
end)
