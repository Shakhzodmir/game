-- The real level files (content/levels/level_0001.json ... level_0100.json) against the plan, and the table
-- of docs/levels/README.md against the files. Nothing is played: the files are read and validated, so
-- this runs in about a second. A failure names the level and what differs; the file wins, fix the README row
-- (or the level, if the plan is right).
--   * every file loads through the core (rules 2.1) and keeps the plan of levels-plan.md: the difficulty saw,
--     the colours of its stretch, 20-35 moves (the same as `luajit tools/levels.lua validate --strict`);
--   * the saw earns 126 stars, the town costs 124 (meta-economy.md, section 9);
--   * every level of the README table agrees with its file: difficulty, size and cells, colours, elements,
--     goals, and the "(обучение)" mark with the lessons of content/tutorials.json. The moves column is only
--     checked to be a number in the range of the schema: the tuner rewrites the real value (tools/README.md)
--     and the README keeps the value of the day it was built.

local core = require("core.game")
local json = require("tools.lib.json")
local Levels = require("tools.levels")

local DIR = "content/levels"
local README = "docs/levels/README.md" -- not in /content: that folder is bundled into the game
local STARS = { easy = 1, medium = 1, hard = 2, super_hard = 3 }
local LETTER = { easy = "E", medium = "M", hard = "H", super_hard = "SH" }
local COLOR_OF_GENITIVE = {
	["красного"] = "red", ["оранжевого"] = "orange", ["жёлтого"] = "yellow",
	["зелёного"] = "green", ["синего"] = "blue", ["фиолетового"] = "purple",
}
local COLOR_OF_NOMINATIVE = {
	["красный"] = "red", ["оранжевый"] = "orange", ["жёлтый"] = "yellow",
	["зелёный"] = "green", ["синий"] = "blue", ["фиолетовый"] = "purple",
}
local COLOR_GENITIVE_PLURAL = {
	red = "красных", orange = "оранжевых", yellow = "жёлтых", green = "зелёных", blue = "синих", purple = "фиолетовых",
}
-- a word that a goal of the table must contain, by the item of a `break` goal
local ITEM_WORD = { record_box = "короб", concrete = "бетон", noise = "помех", balloon = "шарик", column = "колон" }
local TIMES = "\195\151" -- the multiplication sign of the "9×9" of the field column

local function read(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function first_n(list, n)
	local out = {}
	for i = 1, math.min(n, #list) do out[i] = list[i] end
	if #list > n then out[#out + 1] = "... and " .. (#list - n) .. " more" end
	return out
end

-- the 100 files, validated once for all the tests: {n = {raw =, res =}}
local loaded
local function files()
	if loaded then return loaded end
	loaded = {}
	for n = 1, 100 do
		local res = Levels.validate_file(string.format("%s/level_%04d.json", DIR, n), core)
		loaded[n] = { raw = res.raw, res = res }
	end
	return loaded
end

local function count_slots(raw, kind)
	local n = 0
	for _, s in ipairs(raw.slots or {}) do
		if s.type == kind then n = n + 1 end
	end
	return n
end

local function gifts(raw)
	local n = 0
	for _, s in ipairs(raw.slots or {}) do
		if s.type == "riff" or s.type == "sub" or s.type == "bird" or s.type == "disco" then n = n + 1 end
	end
	return n
end

local function cell_count(raw)
	local n = 0
	for _, row in ipairs(raw.cells) do
		for _ in row:gmatch("#") do n = n + 1 end
	end
	return n
end

describe("level content: the files", function()
	it("has all 100 levels, each valid for the core and for the plan (saw, colours, 20-35 moves)", function()
		local problems = {}
		for n, f in ipairs(files()) do
			for _, e in ipairs(f.res.errors) do problems[#problems + 1] = "level " .. n .. ": " .. e end
			for _, w in ipairs(f.res.warnings) do problems[#problems + 1] = "level " .. n .. ": " .. w end
			if f.raw then
				if f.raw.id ~= n then problems[#problems + 1] = "level " .. n .. ": the file says id " .. tostring(f.raw.id) end
				if f.raw.version ~= 1 then problems[#problems + 1] = "level " .. n .. ": version " .. tostring(f.raw.version) end
			end
		end
		assert_true(#problems == 0, table.concat(first_n(problems, 12), "\n"))
	end)

	it("earns 126 stars on the saw, more than the 124 of the town", function()
		local stars, counts = 0, { easy = 0, medium = 0, hard = 0, super_hard = 0 }
		for n, f in ipairs(files()) do
			assert_true(f.raw ~= nil, "level " .. n .. " is missing")
			stars = stars + STARS[f.raw.difficulty]
			counts[f.raw.difficulty] = counts[f.raw.difficulty] + 1
		end
		assert_same(counts, { easy = 52, medium = 27, hard = 16, super_hard = 5 })
		assert_eq(stars, 126)
		local town = json.decode(read("content/districts.json"))
		local cost = 0
		for _, d in ipairs(town.districts) do
			for _, t in ipairs(d.tasks) do cost = cost + t.cost end
		end
		assert_eq(cost, 124, "the stars the town costs (content/districts.json)")
		assert_true(stars >= cost, "the town cannot be finished: " .. stars .. " stars for " .. cost)
	end)
end)

-- The rows of the level table of the README: [n] = {cells...}; a row has 8 cells (a row of another table
-- starting with a number, like the lessons, has 3).
local function table_rows()
	local text = read(README)
	assert_true(text ~= nil, README .. " is missing")
	local rows, order = {}, {}
	for line in text:gmatch("[^\n]+") do
		if line:match("^| %d+ | ") then
			local cells = {}
			for cell in line:gmatch("|([^|]*)") do cells[#cells + 1] = trim(cell) end
			if cells[#cells] == "" then cells[#cells] = nil end -- the text after the closing bar
			if #cells == 8 then
				local n = tonumber(cells[1])
				if rows[n] then error("level " .. n .. " has two rows in " .. README) end
				rows[n] = cells
				order[#order + 1] = n
			end
		end
	end
	return rows, order, text
end

local function lesson_levels()
	local defs = json.decode(read("content/tutorials.json"))
	local set = {}
	for k in pairs(defs) do set[tonumber(k)] = true end
	return set
end

-- problems of one README row against its file
local function row_problems(n, cells, raw)
	local out = {}
	local function bad(column, why) out[#out + 1] = "level " .. n .. " (" .. column .. "): " .. why end
	local diff, field, colours, elements, goals, idea, moves = cells[2], cells[3], cells[4], cells[5], cells[6], cells[7], cells[8]

	if diff ~= LETTER[raw.difficulty] then bad("слож.", "'" .. diff .. "', the file says " .. LETTER[raw.difficulty]) end

	local w, h = field:match("^(%d+)" .. TIMES .. "(%d+),")
	if tonumber(w) ~= raw.size[1] or tonumber(h) ~= raw.size[2] then
		bad("поле", "size '" .. field:sub(1, 12) .. "', the file says " .. raw.size[1] .. "x" .. raw.size[2])
	end
	local cells_text = field:match("(%d+) кл%.")
	if tonumber(cells_text) ~= cell_count(raw) then bad("поле", "cells " .. tostring(cells_text) .. ", the file has " .. cell_count(raw)) end
	if (field:find("спавнеры внутри", 1, true) ~= nil) ~= (type(raw.spawners) == "table") then
		bad("поле", "'спавнеры внутри' must be there exactly when the file lists spawners")
	end

	-- colours: the count, then who is missing (5), who is there (4); a weight only where the file has weights
	local count = tonumber(colours:match("^(%d+)"))
	if count ~= #raw.colors then bad("цвета", "count " .. tostring(count) .. ", the file has " .. #raw.colors) end
	local have = {}
	for _, c in ipairs(raw.colors) do have[c] = true end
	if count == 5 then
		local word = colours:match("без (%S-)[;,]") or colours:match("без (%S+)$")
		local missing = word and COLOR_OF_GENITIVE[word]
		if not missing or have[missing] then bad("цвета", "'без " .. tostring(word) .. "' is not the missing colour") end
	elseif count == 4 then
		local list = colours:match("^4: ([^;]*)") or ""
		local named, n_named = {}, 0
		for word in list:gmatch("[^, ]+") do
			named[COLOR_OF_NOMINATIVE[word] or "?"] = true
			n_named = n_named + 1
		end
		for c in pairs(have) do
			if not named[c] then bad("цвета", c .. " is in the file, not in the cell") end
		end
		if n_named ~= 4 then bad("цвета", "four colours must be named") end
	end
	if (colours:find("вес", 1, true) ~= nil) ~= (raw.spawn_weights ~= nil) then
		bad("цвета", "a weight must be named exactly when the file has spawn_weights")
	end

	-- elements: counts of what the file has, nothing that it has not
	local function expect(pattern, want, name)
		local got = tonumber(elements:match(pattern))
		if want == 0 then
			if got ~= nil then bad("элементы", name .. " " .. got .. ", the file has none") end
		elseif got ~= want then
			bad("элементы", name .. " " .. tostring(got) .. ", the file has " .. want)
		end
	end
	expect("коробки (%d+)", count_slots(raw, "record_box"), "коробки")
	expect("бетон (%d+)", count_slots(raw, "concrete"), "бетон")
	expect("помехи (%d+)", count_slots(raw, "noise"), "помехи")
	expect("шарики (%d+)", count_slots(raw, "balloon"), "шарики")
	expect("танцпол (%d+)", #(raw.floor or {}), "танцпол")
	expect("провода (%d+)", #(raw.overlay or {}), "провода")
	local columns = count_slots(raw, "column")
	if columns == 1 then
		if not elements:find("колонка (", 1, true) then bad("элементы", "one column must be named 'колонка (hpN)'") end
	else
		expect("колонки (%d+)", columns, "колонки")
	end
	if (elements:find("микрофоны (", 1, true) ~= nil) ~= (raw.mic ~= nil) then bad("элементы", "микрофоны exactly where the file has a mic block") end
	local gift_words = 0
	for _ in elements:gmatch("готовый") do gift_words = gift_words + 1 end
	if gift_words ~= gifts(raw) then bad("элементы", gift_words .. " ready specials named, the file has " .. gifts(raw)) end
	local nothing = columns == 0 and #(raw.floor or {}) == 0 and #(raw.overlay or {}) == 0 and raw.mic == nil and gifts(raw) == 0
	for _, kind in ipairs({ "record_box", "concrete", "noise", "balloon" }) do
		if count_slots(raw, kind) > 0 then nothing = false end
	end
	if nothing ~= (elements == "—") then bad("элементы", "'—' exactly where the level has no element") end

	-- goals: as many as in the file, in the order of the file, each with its count and its word
	local parts = {}
	for part in (goals .. ";"):gmatch("([^;]*);") do parts[#parts + 1] = trim(part) end
	if #parts ~= #raw.goals then
		bad("цели", #parts .. " goals named, the file has " .. #raw.goals)
	else
		for i, g in ipairs(raw.goals) do
			local part = parts[i]
			local ok
			if g.type == "light" then
				ok = part:find("плитк", 1, true) ~= nil
			elseif g.type == "collect" then
				ok = part:find("собрать " .. g.count .. " " .. COLOR_GENITIVE_PLURAL[g.color], 1, true) ~= nil
			elseif g.type == "deliver" then
				ok = part:find("доставить " .. g.count .. " микрофон", 1, true) ~= nil
			else
				ok = part:find(" " .. g.count .. " ", 1, true) ~= nil or part:find(" " .. g.count .. "$") ~= nil
				ok = ok and part:find(ITEM_WORD[g.item], 1, true) ~= nil
				if g.item == "column" and g.count == 1 then ok = part:find("колонку", 1, true) ~= nil end
			end
			if not ok then bad("цели", "goal " .. i .. " is '" .. part .. "', the file says " .. g.type .. " " .. tostring(g.color or g.item or "") .. " " .. tostring(g.count or "")) end
		end
	end

	if #idea < 15 then bad("идея", "write what the level is about") end
	local m = tonumber(moves)
	if not m or m ~= math.floor(m) or m < 5 or m > 60 then bad("ходы", "'" .. moves .. "' is not a number of moves (5..60)") end
	return out
end

describe("level content: the README table", function()
	it("has one row for each level, in order", function()
		local rows, order = table_rows()
		local want = {}
		for n = 1, 100 do want[n] = n end
		assert_same(order, want, "rows of the table in " .. README)
		for n = 1, 100 do assert_eq(#rows[n], 8, "cells of the row of level " .. n) end
	end)

	it("agrees with the files: difficulty, field, colours, elements, goals", function()
		local rows = table_rows()
		local problems = {}
		for n, f in ipairs(files()) do
			if f.raw and rows[n] then
				for _, p in ipairs(row_problems(n, rows[n], f.raw)) do problems[#problems + 1] = p end
			end
		end
		assert_true(#problems == 0, table.concat(first_n(problems, 16), "\n"))
	end)

	it("marks with '(обучение)' exactly the levels that have a lesson", function()
		local rows = table_rows()
		local lessons = lesson_levels()
		local problems = {}
		for n = 1, 100 do
			local marked = rows[n] and rows[n][7]:find("(обучение)", 1, true) ~= nil
			if marked and not lessons[n] then problems[#problems + 1] = "level " .. n .. " is marked as a lesson but content/tutorials.json has none" end
			if lessons[n] and not marked then problems[#problems + 1] = "level " .. n .. " has a lesson in content/tutorials.json but its row is not marked" end
		end
		assert_true(#problems == 0, table.concat(first_n(problems, 12), "\n"))
	end)
end)
