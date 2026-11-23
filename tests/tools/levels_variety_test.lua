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
