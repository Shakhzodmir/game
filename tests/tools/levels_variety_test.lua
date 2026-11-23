-- The variety of the boards of every Part 2 district (content/districts.json, "part": 2) and the clock of its coconut and
-- mic levels. Nothing is played: the level files are read, so this runs in about a second.
--
-- Why it exists: the independent review of the Part 2 candidate (2026-11-23) found that districts 17-22 repeat
-- themselves: 6-14 distinct boards out of 20, 9-13 plain rectangles per district, near-copies such as 424/431/439,
-- and level 417 whose last coconut falls at the move 21-22 of 24. The thresholds below are read off the live
-- districts 1-16 (every one of them has 20 different board masks; at most 7 plain rectangles; at least 12 empty
-- cells at the median from district 2 on; 16-20 different element + goal signatures from district 3 on; at most 6
-- levels with three goals, at most 2 of them easy; the clock of a coconut or mic level (total - 1) * gap_moves / moves
-- is 0.71 at the most) and keep a little room, so a district that plays like the live ones passes.
--
--   * masks: every board of a district has its own mask (its rows of `cells`), no copies;
--   * plain: at most MAX_PLAIN boards are a full rectangle or a rectangle with only its four corners cut;
--   * holes: the median board has at least MIN_MEDIAN_HOLES empty cells ('.');
--   * signature: the set of elements (slot types except plain pieces, overlay types, curtain, fog, floor, carpet,
--     conveyor, portals, spawners, coconut, mic) together with the goal types and items; at least MIN_SIGNATURES
--     different ones per district, no more than MAX_SAME_SIGNATURE levels with the same one;
--   * goals: at most MAX_THREE_GOALS levels with three goals, at most MAX_EASY_THREE_GOALS of them easy;
--   * clock: (total - 1) * gap_moves / moves of a coconut or mic level at most MAX_CLOCK: the last one must not
--     come out so late that the level is only a wait for a timer.

local json = require("tools.lib.json")

local DIR = "content/levels"
local MAX_PLAIN = 5
local MIN_MEDIAN_HOLES = 10
local MIN_SIGNATURES = 15
local MAX_SAME_SIGNATURE = 3
local MAX_THREE_GOALS = 6
local MAX_EASY_THREE_GOALS = 2
local MAX_CLOCK = 0.75
local FIRST_CLOCK_LEVEL = 301 -- the levels of Part 1 keep what they have

local TOP_ELEMENTS = { "floor", "curtain", "carpet", "conveyor", "fog", "portals", "spawners", "coconut", "mic" }

local function read(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function level(n)
	local text = read(string.format("%s/level_%04d.json", DIR, n))
	assert_true(text ~= nil, "level " .. n .. " has no file")
	return json.decode(text)
end

-- a board of which only the four corners are cut away (or nothing): plain, the same as every other rectangle
local function plain(cells)
	local h, w = #cells, #cells[1]
	for y, row in ipairs(cells) do
		for x = 1, #row do
			if row:sub(x, x) ~= "#" and not ((y == 1 or y == h) and (x == 1 or x == w)) then return false end
		end
	end
	return true
end

local function holes(cells)
	local n = 0
	for _, row in ipairs(cells) do
		for _ in row:gmatch("%.") do n = n + 1 end
	end
	return n
end

local function signature(raw)
	local elements, seen = {}, {}
	local function add(name)
		if not seen[name] then
			seen[name] = true
			elements[#elements + 1] = name
		end
	end
	for _, s in ipairs(raw.slots or {}) do
		if s.type ~= "piece" then add("slot:" .. s.type) end
	end
	for _, o in ipairs(raw.overlay or {}) do add("overlay:" .. o.type) end
	for _, key in ipairs(TOP_ELEMENTS) do
		if raw[key] ~= nil then add(key) end
	end
	table.sort(elements)
	local goals = {}
	for _, g in ipairs(raw.goals) do goals[#goals + 1] = g.type .. (g.item and (":" .. g.item) or "") end
	table.sort(goals)
	return table.concat(elements, ",") .. "|" .. table.concat(goals, ",")
end

local function median(list)
	local copy = {}
	for i, v in ipairs(list) do copy[i] = v end
	table.sort(copy)
	return copy[math.floor(#copy / 2) + 1]
end

local function part2_districts()
	local out = {}
	for _, d in ipairs(json.decode(read("content/districts.json")).districts) do
		if (d.part or 1) >= 2 then out[#out + 1] = d end
	end
	return out
end

describe("level variety: every Part 2 district", function()
	local districts = part2_districts()

	it("has Part 2 districts to look at", function()
		assert_true(#districts >= 7, "the districts 16-22 carry \"part\": 2")
	end)

	for _, d in ipairs(districts) do
		it("district " .. d.id .. " (levels " .. d.first .. "-" .. d.last .. ") has boards and element mixes as varied as the live districts", function()
			local problems = {}
			local masks, mask_of, rects, hole_counts = {}, {}, 0, {}
			local signatures, same_sig_levels = {}, {}
			local three, easy_three = 0, 0
			local distinct_masks, distinct_signatures, worst_same = 0, 0, 0
			for n = d.first, d.last do
				local raw = level(n)
				local key = table.concat(raw.cells, "\n")
				if not masks[key] then
					masks[key] = {}
					distinct_masks = distinct_masks + 1
				end
				masks[key][#masks[key] + 1] = n
				if plain(raw.cells) then rects = rects + 1 end
				hole_counts[#hole_counts + 1] = holes(raw.cells)
				local sig = signature(raw)
				if not signatures[sig] then
					signatures[sig] = {}
					distinct_signatures = distinct_signatures + 1
				end
				signatures[sig][#signatures[sig] + 1] = n
				if #raw.goals >= 3 then
					three = three + 1
					if raw.difficulty == "easy" then easy_three = easy_three + 1 end
				end
			end
			local size = d.last - d.first + 1
			if distinct_masks ~= size then
				local groups = {}
				for _, list in pairs(masks) do
					if #list > 1 then groups[#groups + 1] = "[" .. table.concat(list, ",") .. "]" end
				end
				table.sort(groups)
				problems[#problems + 1] = string.format("only %d different boards out of %d, the same board in %s", distinct_masks, size, table.concat(groups, " "))
			end
			if rects > MAX_PLAIN then
				problems[#problems + 1] = string.format("%d boards are plain rectangles (full, or with only the four corners cut), at most %d", rects, MAX_PLAIN)
			end
			local med = median(hole_counts)
			if med < MIN_MEDIAN_HOLES then
				problems[#problems + 1] = string.format("the median board has %d empty cells, at least %d", med, MIN_MEDIAN_HOLES)
			end
			for _, list in pairs(signatures) do
				if #list > worst_same then worst_same = #list end
				if #list > MAX_SAME_SIGNATURE then
					same_sig_levels[#same_sig_levels + 1] = "[" .. table.concat(list, ",") .. "]"
				end
			end
			table.sort(same_sig_levels)
			if distinct_signatures < MIN_SIGNATURES then
				problems[#problems + 1] = string.format("only %d different element + goal mixes, at least %d", distinct_signatures, MIN_SIGNATURES)
			end
			if worst_same > MAX_SAME_SIGNATURE then
				problems[#problems + 1] = string.format("the same element + goal mix on more than %d levels: %s", MAX_SAME_SIGNATURE, table.concat(same_sig_levels, " "))
			end
			if three > MAX_THREE_GOALS then
				problems[#problems + 1] = string.format("%d levels with three goals, at most %d", three, MAX_THREE_GOALS)
			end
			if easy_three > MAX_EASY_THREE_GOALS then
				problems[#problems + 1] = string.format("%d easy levels with three goals, at most %d", easy_three, MAX_EASY_THREE_GOALS)
			end
			assert_true(#problems == 0, "district " .. d.id .. ":\n  " .. table.concat(problems, "\n  "))
		end)
	end
end)

describe("level variety: the clock of the coconut and mic levels", function()
	it("lets the last coconut or mic out by the end of the moves, not in the last ones (levels 301 and up)", function()
		local last = json.decode(read("content/districts.json")).districts
		last = last[#last].last
		local problems = {}
		for n = FIRST_CLOCK_LEVEL, last do
			local raw = level(n)
			for _, key in ipairs({ "coconut", "mic" }) do
				local c = raw[key]
				if c and c.gap_moves then
					local ratio = (c.total - 1) * c.gap_moves / raw.moves
					if ratio > MAX_CLOCK then
						problems[#problems + 1] = string.format("level %d: %s (total %d - 1) * gap %d / %d moves = %.2f, at most %.2f",
							n, key, c.total, c.gap_moves, raw.moves, ratio, MAX_CLOCK)
					end
				end
			end
		end
		assert_true(#problems == 0, table.concat(problems, "\n"))
	end)
end)

-- Near copies of boards (WP-23). The distance of two boards is the number of cells in the symmetric difference of their
-- masks after centring both on a canvas of 11 x 11, over the shifts -1..1 in both directions and the left-right mirror
-- of the second board (the smallest value). It is computed on bit masks of rows (plain arithmetic: Lua 5.1 has no bit
-- operators), and a pair whose cell counts differ by more than the limit is skipped, so the whole check takes seconds.
--
--   * no board of a level from 301 up equals (distance 0) or differs by one cell from a board of any earlier level;
--   * no two boards of one Part 2 district are closer than MIN_BOARD_DISTANCE cells;
--   * a Part 2 district has at most MAX_PURE pure levels (one element, rule 2.1.6 as in core/level.lua).

local CANVAS = 11
local MIN_BOARD_DISTANCE = 5
local MAX_PURE = 2
local FIRST_PART2_LEVEL = 301

-- AND_LO[a * 128 + b + 1]: number of common bits of the 7-bit numbers a, b; AND_HI the same for 6 bits
local function and_table(bits)
	local size = 2 ^ bits
	local t = {}
	for a = 0, size - 1 do
		for b = 0, size - 1 do
			local n, x, y = 0, a, b
			for _ = 1, bits do
				if x % 2 == 1 and y % 2 == 1 then n = n + 1 end
				x = math.floor(x / 2)
				y = math.floor(y / 2)
			end
			t[a * size + b + 1] = n
		end
	end
	return t
end
local AND_LO, AND_HI = and_table(7), and_table(6)

-- rows[i] (i = 1..13, the canvas row y is i - 2, so that the shifts of -1..1 stay inside) as numbers: bit x + 1 is the cell x
local function board_rows(cells)
	local h, w = #cells, #cells[1]
	assert_true(h <= CANVAS and w <= CANVAS, "a board larger than the canvas of " .. CANVAS)
	local ox, oy = math.floor((CANVAS - w) / 2), math.floor((CANVAS - h) / 2)
	local plain_rows, mirror_rows, count = {}, {}, 0
	for i = 1, CANVAS + 2 do
		plain_rows[i], mirror_rows[i] = 0, 0
	end
	for y, row in ipairs(cells) do
		for x = 1, #row do
			if row:sub(x, x) == "#" then
				local cx, cy = x - 1 + ox, y - 1 + oy
				plain_rows[cy + 2] = plain_rows[cy + 2] + 2 ^ (cx + 1)
				mirror_rows[cy + 2] = mirror_rows[cy + 2] + 2 ^ (CANVAS - 1 - cx + 1)
				count = count + 1
			end
		end
	end
	return plain_rows, mirror_rows, count
end

local function split(rows)
	local lo, hi = {}, {}
	for i = 1, CANVAS + 2 do
		lo[i] = rows[i] % 128
		hi[i] = math.floor(rows[i] / 128)
	end
	return lo, hi
end

-- a board with its 18 shifted and mirrored versions as split rows
local function board_variants(cells)
	local plain_rows, mirror_rows, count = board_rows(cells)
	local out = {}
	for _, base in ipairs({ plain_rows, mirror_rows }) do
		for dy = -1, 1 do
			for dx = -1, 1 do
				local rows = {}
				for i = 1, CANVAS + 2 do
					local v = base[i - dy] or 0
					if dx == 1 then
						v = v * 2
					elseif dx == -1 then
						v = math.floor(v / 2)
					end
					rows[i] = v
				end
				local lo, hi = split(rows)
				out[#out + 1] = { lo = lo, hi = hi }
			end
		end
	end
	local lo, hi = split(plain_rows)
	return { count = count, lo = lo, hi = hi, variants = out }
end

-- the distance of two boards, or `limit + 1` when their cell counts already differ by more than `limit`
local function board_distance(a, b, limit)
	if math.abs(a.count - b.count) > limit then return limit + 1 end
	local best = a.count + b.count
	local alo, ahi = a.lo, a.hi
	for _, v in ipairs(b.variants) do
		local vlo, vhi = v.lo, v.hi
		local common = 0
		for i = 1, CANVAS + 2 do
			common = common + AND_LO[alo[i] * 128 + vlo[i] + 1] + AND_HI[ahi[i] * 64 + vhi[i] + 1]
		end
		local d = a.count + b.count - 2 * common
		if d < best then best = d end
	end
	return best
end

local function last_level()
	local districts = json.decode(read("content/districts.json")).districts
	return districts[#districts].last
end

local boards_cache
local function all_boards()
	if not boards_cache then
		boards_cache = {}
		for n = 1, last_level() do boards_cache[n] = board_variants(level(n).cells) end
	end
	return boards_cache
end

local BLOCKER_TYPES = { record_box = true, concrete = true, noise = true, balloon = true, column = true, boombox = true, hay = true }

-- the number of different elements of rule 2.1.6 (core/level.lua) read from the level file
local function element_count(raw)
	local seen, n = {}, 0
	local function add(name)
		if not seen[name] then
			seen[name] = true
			n = n + 1
		end
	end
	local function goal(t)
		for _, g in ipairs(raw.goals) do
			if g.type == t then return true end
		end
		return false
	end
	for _, s in ipairs(raw.slots or {}) do
		if BLOCKER_TYPES[s.type] then add(s.type) end
		if s.type == "mic" then add("mic") end
		if s.type == "coconut" then add("coconut") end
	end
	if raw.floor and #raw.floor > 0 then add("dancefloor") end
	for _, o in ipairs(raw.overlay or {}) do add(o.type) end
	if goal("ice") then add("ice") end
	if raw.curtain then add("curtain") end
	if raw.carpet or goal("carpet") then add("carpet") end
	if raw.conveyor then add("conveyor") end
	if raw.fog or goal("fog") then add("fog") end
	if raw.portals ~= nil then add("portal") end
	if goal("deliver") or raw.mic ~= nil then add("mic") end
	if goal("drop") or raw.coconut ~= nil then add("coconut") end
	return n
end

describe("level variety: near copies of boards", function()
	it("measures the distance of boards (shift, mirror, symmetric difference)", function()
		local function b(rows) return board_variants(rows) end
		assert_eq(board_distance(b({ "###", "###" }), b({ "###", "###" }), 5), 0)
		assert_eq(board_distance(b({ "###", "###" }), b({ "###", "##." }), 5), 1)
		-- a shifted and mirrored copy is a copy
		assert_eq(board_distance(b({ "##.", "###" }), b({ ".##", "###" }), 5), 0)
		assert_eq(board_distance(b({ "#..", "###" }), b({ "###", ".#." }), 5), 2)
		assert_eq(board_distance(b({ "###", "###" }), b({ "#" }), 1), 2)
	end)

	it("gives every board of a level from 301 up its own shape, not even a copy with one cell more or less", function()
		local boards = all_boards()
		local problems = {}
		for n = FIRST_PART2_LEVEL, last_level() do
			for m = 1, n - 1 do
				local d = board_distance(boards[n], boards[m], 1)
				if d <= 1 then
					problems[#problems + 1] = string.format("level %d is %s level %d", n, d == 0 and "a copy of" or "one cell away from", m)
				end
			end
		end
		assert_true(#problems == 0, table.concat(problems, "\n"))
	end)

	it("keeps the boards of one Part 2 district at least " .. MIN_BOARD_DISTANCE .. " cells apart", function()
		local boards = all_boards()
		local problems = {}
		for _, d in ipairs(part2_districts()) do
			for n = d.first, d.last do
				for m = d.first, n - 1 do
					local dist = board_distance(boards[n], boards[m], MIN_BOARD_DISTANCE)
					if dist < MIN_BOARD_DISTANCE then
						problems[#problems + 1] = string.format("district %s: levels %d and %d are %d cells apart", d.id, m, n, dist)
					end
				end
			end
		end
		assert_true(#problems == 0, table.concat(problems, "\n"))
	end)
end)

describe("level variety: pure levels", function()
	it("counts the elements of rule 2.1.6", function()
		assert_eq(element_count(level(381)), 1, "381: a column")
		assert_eq(element_count(level(390)), 2, "390: chains and a column")
		assert_eq(element_count(level(420)), 3, "420: carpet, ice and coconuts")
	end)

	for _, d in ipairs(part2_districts()) do
		it("district " .. d.id .. " has at most " .. MAX_PURE .. " pure (one-element) levels", function()
			local pure = {}
			for n = d.first, d.last do
				if element_count(level(n)) <= 1 then pure[#pure + 1] = n end
			end
			assert_true(#pure <= MAX_PURE, string.format("district %s: %d pure levels (%s), at most %d", d.id, #pure, table.concat(pure, ", "), MAX_PURE))
		end)
	end
end)
