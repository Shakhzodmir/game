-- The real level files (content/levels/level_0001.json ... the last level of content/districts.json) against the plan, and the table
-- of docs/levels/README.md against the files. Nothing is played: the files are read and validated, so
-- this runs in about a second. A failure names the level and what differs; the file wins, fix the README row
-- (or the level, if the plan is right).
--   * every file loads through the core (rules 2.1) and keeps the plan of levels-plan.md: the difficulty saw,
--     the colours of its stretch, 20-35 moves (the same as `luajit tools/levels.lua validate --strict`);
--   * the saw earns 126 stars in the first hundred, the files 390 in Part 1 (levels 1-300); Part 1 of the town costs 389
--     (meta-economy.md, section 9; district 6 by the price rule of docs/handoff/WP-15.md, districts 7, 8, 9, 10, 11, 12, 13,
--     14 and 15 cost what their saws earn, 26 each);
--   * every Part 2 district (16-30, docs/design/part2-districts.md) has 20 levels: 10 easy, 6 medium, 2 hard and 2 super
--     hard, the concert (its last level) among them; its saw earns the 26 stars it costs, so the spare stays 1 star.
--     PART2_SAW pins where the hard and super hard levels of each district stand (add a line for a new district);
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
local ITEM_WORD = { record_box = "короб", concrete = "бетон", noise = "помех", balloon = "шарик", column = "колон",
	boombox = "бумбокс", hay = "стог" }
local FOG_GOAL = "рассеять туман" -- the goal `fog` of the table (10.13): no count, every fogged cell
local LAST = Levels.content_count(DIR) -- the last level of the last district of content/districts.json
-- Part 2: where the hard and the super hard levels of a district stand (docs/design/part2-districts.md, "Кривая")
local PART2_SAW = {
	midnight_cafe = { hard = { 312, 315 }, super_hard = { 318, 320 } }, -- district 16: the first half without hard levels
	late_club = { hard = { 333, 336 }, super_hard = { 338, 340 } }, -- district 17: the hard levels later than in 16
	nations_fest = { hard = { 352, 355 }, super_hard = { 357, 360 } }, -- district 18: the parade of big fields
	fan_meeting = { hard = { 372, 376 }, super_hard = { 378, 380 } }, -- district 19: the concert is a dancefloor over the field
}
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

-- the level files, validated once for all the tests: {n = {raw =, res =}}
local loaded
local function files()
	if loaded then return loaded end
	loaded = {}
	for n = 1, LAST do
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

-- elements of the overlay layer of one type: "wires", "chain" (10.6) or "ice" (10.11)
local function count_overlay(raw, kind)
	local n = 0
	for _, o in ipairs(raw.overlay or {}) do
		if o.type == kind then n = n + 1 end
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
	it("has every level of the districts (300 in Part 1), each valid for the core and for the plan (saw, colours, 20-35 moves)", function()
		local problems = {}
		local districts = json.decode(read("content/districts.json")).districts
		assert_eq(districts[15].last, 300, "Part 1 ends with level 300")
		assert_eq(LAST, districts[#districts].last, "the last level of the last district")
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

	it("earns 390 stars on the saw of Part 1 (130 in the first hundred), one more than its 389; 26 more per Part 2 district", function()
		local stars, counts = 0, { easy = 0, medium = 0, hard = 0, super_hard = 0 }
		local stars100, counts100, stars120, counts120, stars140, counts140, stars160, counts160, stars180, counts180, stars200, counts200, stars220, counts220, stars240, counts240, stars260, counts260, stars280, counts280, stars300, counts300
		for n, f in ipairs(files()) do
			assert_true(f.raw ~= nil, "level " .. n .. " is missing")
			stars = stars + STARS[f.raw.difficulty]
			counts[f.raw.difficulty] = counts[f.raw.difficulty] + 1
			if n == 100 then
				stars100 = stars
				counts100 = { easy = counts.easy, medium = counts.medium, hard = counts.hard, super_hard = counts.super_hard }
			end
			if n == 120 then
				stars120 = stars
				counts120 = { easy = counts.easy, medium = counts.medium, hard = counts.hard, super_hard = counts.super_hard }
			end
			if n == 140 then
				stars140 = stars
				counts140 = { easy = counts.easy, medium = counts.medium, hard = counts.hard, super_hard = counts.super_hard }
			end
			if n == 160 then
				stars160 = stars
				counts160 = { easy = counts.easy, medium = counts.medium, hard = counts.hard, super_hard = counts.super_hard }
			end
			if n == 180 then
				stars180 = stars
				counts180 = { easy = counts.easy, medium = counts.medium, hard = counts.hard, super_hard = counts.super_hard }
			end
			if n == 200 then
				stars200 = stars
				counts200 = { easy = counts.easy, medium = counts.medium, hard = counts.hard, super_hard = counts.super_hard }
			end
			if n == 220 then
				stars220 = stars
				counts220 = { easy = counts.easy, medium = counts.medium, hard = counts.hard, super_hard = counts.super_hard }
			end
			if n == 240 then
				stars240 = stars
				counts240 = { easy = counts.easy, medium = counts.medium, hard = counts.hard, super_hard = counts.super_hard }
			end
			if n == 260 then
				stars260 = stars
				counts260 = { easy = counts.easy, medium = counts.medium, hard = counts.hard, super_hard = counts.super_hard }
			end
			if n == 280 then
				stars280 = stars
				counts280 = { easy = counts.easy, medium = counts.medium, hard = counts.hard, super_hard = counts.super_hard }
			end
			if n == 300 then
				stars300 = stars
				counts300 = { easy = counts.easy, medium = counts.medium, hard = counts.hard, super_hard = counts.super_hard }
			end
		end
		-- (WP-14: the concerts of districts 1 and 2, levels 20 and 40, are super hard now)
		assert_same(counts100, { easy = 51, medium = 26, hard = 16, super_hard = 7 })
		assert_eq(stars100, 130)
		-- district 6 (WP-17, levels 101-120): 10 easy, 6 medium, hard 107 and 113, super hard 117 and the concert 120
		assert_same(counts120, { easy = 61, medium = 32, hard = 18, super_hard = 9 })
		assert_eq(stars120, 156)
		-- district 7 (WP-17, levels 121-140) keeps the rhythm of district 6 (2 hard + 2 super hard, 26 stars) and
		-- costs 26 stars, so the spare stays 1 star: 8 easy, 8 medium, hard 127 and 133, super hard 137 and the
		-- concert 140 (it was released with 5 hard + 3 super hard for a price of 31; 124, 129, 131 and 135 were
		-- softened to medium)
		assert_same(counts140, { easy = 69, medium = 40, hard = 20, super_hard = 11 })
		assert_eq(stars140, 182)
		-- district 8 (WP-17, levels 141-160) has the saw of district 6: 10 easy, 6 medium, hard 147 and 153, super
		-- hard 157 and the concert 160: 26 stars for a price of 26, the spare stays 1 star
		assert_same(counts160, { easy = 79, medium = 46, hard = 22, super_hard = 13 })
		assert_eq(stars160, 208)
		-- district 9 (WP-17, levels 161-180) has the same saw: 10 easy, 6 medium, hard 167 and 173, super hard 177
		-- and the concert 180: 26 stars for a price of 26, the spare stays 1 star
		assert_same(counts180, { easy = 89, medium = 52, hard = 24, super_hard = 15 })
		assert_eq(stars180, 234)
		-- district 10 (WP-17, levels 181-200) has the same saw: 10 easy, 6 medium, hard 187 and 193, super hard 197
		-- and the concert 200: 26 stars for a price of 26, the spare stays 1 star
		assert_same(counts200, { easy = 99, medium = 58, hard = 26, super_hard = 17 })
		assert_eq(stars200, 260)
		-- district 11 (WP-17, levels 201-220) has the same saw: 10 easy, 6 medium, hard 207 and 213, super hard 217
		-- and the concert 220: 26 stars for a price of 26, the spare stays 1 star
		assert_same(counts220, { easy = 109, medium = 64, hard = 28, super_hard = 19 })
		assert_eq(stars220, 286)
		-- district 12 (WP-17, levels 221-240) has the same saw: 10 easy, 6 medium, hard 227 and 233, super hard 237
		-- and the concert 240: 26 stars for a price of 26, the spare stays 1 star
		assert_same(counts240, { easy = 119, medium = 70, hard = 30, super_hard = 21 })
		assert_eq(stars240, 312)
		-- district 13 (WP-17, levels 241-260) has the same saw: 10 easy, 6 medium, hard 247 and 253, super hard 257
		-- and the concert 260: 26 stars for a price of 26, the spare stays 1 star
		assert_same(counts260, { easy = 129, medium = 76, hard = 32, super_hard = 23 })
		assert_eq(stars260, 338)
		-- district 14 (WP-17, levels 261-280) has the same saw: 10 easy, 6 medium, hard 267 and 273, super hard 277
		-- and the concert 280: 26 stars for a price of 26, the spare stays 1 star
		assert_same(counts280, { easy = 139, medium = 82, hard = 34, super_hard = 25 })
		assert_eq(stars280, 364)
		-- district 15 (WP-17, levels 281-300), the last of the plan, has the same saw: 10 easy, 6 medium, hard 287 and 293,
		-- super hard 297 and the concert 300: 26 stars for a price of 26, the spare stays 1 star
		assert_same(counts300, { easy = 149, medium = 88, hard = 36, super_hard = 27 })
		assert_eq(stars300, 390)
		local town = json.decode(read("content/districts.json"))
		local cost, cost1 = 0, 0
		for i, d in ipairs(town.districts) do
			local price = 0
			for _, t in ipairs(d.tasks) do price = price + t.cost end
			cost = cost + price
			if i <= 15 then cost1 = cost1 + price end
			-- Part 2: a district of 20 levels, 10 easy, 6 medium, 2 hard, 2 super hard with the concert last; its saw
			-- earns what it costs, and the hard levels stand where PART2_SAW says
			if i > 15 then
				local saw, kinds = 0, { easy = 0, medium = 0, hard = 0, super_hard = 0 }
				local at = { hard = {}, super_hard = {} }
				assert_eq(d.last - d.first + 1, 20, d.id .. ": levels")
				for n = d.first, d.last do
					local raw = files()[n].raw
					saw = saw + STARS[raw.difficulty]
					kinds[raw.difficulty] = kinds[raw.difficulty] + 1
					if at[raw.difficulty] then at[raw.difficulty][#at[raw.difficulty] + 1] = n end
				end
				assert_same(kinds, { easy = 10, medium = 6, hard = 2, super_hard = 2 }, d.id .. ": the saw of a Part 2 district")
				assert_eq(files()[d.last].raw.difficulty, "super_hard", d.id .. ": the concert")
				assert_eq(saw, price, d.id .. ": the saw earns what the district costs")
				local pin = PART2_SAW[d.id]
				assert_true(pin ~= nil, d.id .. ": add its hard and super hard levels to PART2_SAW")
				assert_same(at, pin, d.id .. ": where the hard and the super hard levels stand")
			end
		end
		assert_eq(cost1, 389, "the stars Part 1 of the town costs (content/districts.json)")
		assert_eq(cost, 389 + 26 * (#town.districts - 15), "the stars the town costs (content/districts.json)")
		assert_eq(stars - cost, 1, "one spare star is left")
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
	expect("бумбоксы (%d+)", count_slots(raw, "boombox"), "бумбоксы") -- (10.10)
	expect("стог%S* (%d+)", count_slots(raw, "hay"), "стоги") -- (10.12: "стоги 4", "стога 2", "стогов 6")
	expect("танцпол (%d+)", #(raw.floor or {}), "танцпол")
	expect("провода (%d+)", count_overlay(raw, "wires"), "провода")
	expect("цепи (%d+)", count_overlay(raw, "chain"), "цепи")
	expect("лёд (%d+)", count_overlay(raw, "ice"), "лёд") -- (10.11)
	-- the fog (10.13): "туман N" exactly where the file has the list; N = the cells under the fog at the start
	expect("туман (%d+)", #(raw.fog or {}), "туман")
	-- the portals (10.14): "порталы N" exactly where the file has the list; N = the pairs of an entrance and an exit
	expect("порталы (%d+)", #(raw.portals or {}), "порталы")
	local columns = count_slots(raw, "column")
	if columns == 1 then
		if not elements:find("колонка (", 1, true) then bad("элементы", "one column must be named 'колонка (hpN)'") end
	else
		expect("колонки (%d+)", columns, "колонки")
	end
	if (elements:find("микрофоны (", 1, true) ~= nil) ~= (raw.mic ~= nil) then bad("элементы", "микрофоны exactly where the file has a mic block") end
	if (elements:find("кокосы (", 1, true) ~= nil) ~= (raw.coconut ~= nil) then bad("элементы", "кокосы exactly where the file has a coconut block") end
	-- the curtain (10.7): "занавес N (закрыт A, открыт B, с начала закрыт|открыт)" exactly where the file has the block
	if (elements:find("занавес ", 1, true) ~= nil) ~= (raw.curtain ~= nil) then bad("элементы", "занавес exactly where the file has a curtain block") end
	if raw.curtain then
		local n_cells, closed, open, start = elements:match("занавес (%d+) %(закрыт (%d+), открыт (%d+), с начала (%S-)%)")
		local want_start = raw.curtain.start == "closed" and "закрыт" or "открыт"
		if tonumber(n_cells) ~= #raw.curtain.covers or tonumber(closed) ~= raw.curtain.closed_moves
			or tonumber(open) ~= raw.curtain.open_moves or start ~= want_start then
			bad("элементы", "the numbers of 'занавес N (закрыт A, открыт B, с начала ...)' are not the file's")
		end
	end
	-- the carpet (10.8): "ковёр N (с начала)" exactly where the file has the list; N = the cells covered at the start
	if (elements:find("ковёр ", 1, true) ~= nil) ~= (raw.carpet ~= nil) then bad("элементы", "ковёр exactly where the file has a carpet list") end
	if raw.carpet and tonumber(elements:match("ковёр (%d+) %(с начала%)")) ~= #raw.carpet then
		bad("элементы", "the number of 'ковёр N (с начала)' is not the file's")
	end
	-- the conveyor (10.9): "конвейер N (K колец)" exactly where the file has the list of belts; N = the cells under
	-- the belts, K = the belts; the word is "кольцо/кольца/колец" when every belt is a closed ring (its last cell is a
	-- neighbour of its first), else "лент..."
	if (elements:find("конвейер ", 1, true) ~= nil) ~= (raw.conveyor ~= nil) then bad("элементы", "конвейер exactly where the file has a conveyor list") end
	if raw.conveyor then
		local n_cells, rings = 0, true
		for _, belt in ipairs(raw.conveyor) do
			local path = belt.path
			n_cells = n_cells + #path
			local a, b = path[1], path[#path]
			if #path < 4 or math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) ~= 1 then rings = false end
		end
		local got_cells, got_belts, word = elements:match("конвейер (%d+) %((%d+) ([^%s%)]+)%)")
		if tonumber(got_cells) ~= n_cells or tonumber(got_belts) ~= #raw.conveyor then
			bad("элементы", "the numbers of 'конвейер N (K колец|лент)' are not the file's: " .. n_cells .. " cells, " .. #raw.conveyor .. " belts")
		elseif (word:find("^кольц") ~= nil or word == "колец") ~= rings or (not rings and word:find("^лент") == nil) then
			bad("элементы", "'" .. word .. "': 'кольцо/кольца/колец' exactly when every belt is a ring, else 'лент...'")
		end
	end
	if raw.coconut then
		local total, max, gap, start = elements:match("кокосы %(всего (%d+), на поле ≤(%d+), пауза (%d+), с начала (%d+)")
		if tonumber(total) ~= raw.coconut.total or tonumber(max) ~= raw.coconut.on_board_max
			or tonumber(gap) ~= raw.coconut.gap_moves or tonumber(start) ~= count_slots(raw, "coconut") then
			bad("элементы", "the numbers of 'кокосы (всего N, на поле ≤N, пауза N, с начала N' are not the file's")
		end
		if (elements:find("входят в столбцы", 1, true) ~= nil) ~= (raw.coconut.columns ~= nil) then
			bad("элементы", "'входят в столбцы' exactly where the coconut block lists columns")
		end
	end
	local gift_words = 0
	for _ in elements:gmatch("готовый") do gift_words = gift_words + 1 end
	if gift_words ~= gifts(raw) then bad("элементы", gift_words .. " ready specials named, the file has " .. gifts(raw)) end
	local nothing = columns == 0 and #(raw.floor or {}) == 0 and #(raw.overlay or {}) == 0 and raw.mic == nil and gifts(raw) == 0
		and raw.coconut == nil and raw.curtain == nil and raw.carpet == nil and raw.conveyor == nil and raw.fog == nil
		and raw.portals == nil
	for _, kind in ipairs({ "record_box", "concrete", "noise", "balloon", "boombox", "hay" }) do
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
			elseif g.type == "drop" then
				ok = part:find("опустить " .. g.count .. " кокос", 1, true) ~= nil
			elseif g.type == "chains" then
				ok = part:find("разбить " .. g.count .. " цеп", 1, true) ~= nil
			elseif g.type == "ice" then -- (10.11)
				ok = part:find("растопить " .. g.count .. " ", 1, true) ~= nil and part:find("льд", 1, true) ~= nil
			elseif g.type == "carpet" then -- (10.8: no count, the whole board)
				ok = part == "застелить всё поле"
			elseif g.type == "fog" then -- (10.13: no count, every fogged cell)
				ok = part == FOG_GOAL
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
		for n = 1, LAST do want[n] = n end
		assert_same(order, want, "rows of the table in " .. README)
		for n = 1, LAST do assert_eq(#rows[n], 8, "cells of the row of level " .. n) end
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
		for n = 1, LAST do
			local marked = rows[n] and rows[n][7]:find("(обучение)", 1, true) ~= nil
			if marked and not lessons[n] then problems[#problems + 1] = "level " .. n .. " is marked as a lesson but content/tutorials.json has none" end
			if lessons[n] and not marked then problems[#problems + 1] = "level " .. n .. " has a lesson in content/tutorials.json but its row is not marked" end
		end
		assert_true(#problems == 0, table.concat(first_n(problems, 12), "\n"))
	end)
end)
