-- client/notebook_layout.lua: where the title and the verses stand on the page of the songbook window. Pure Lua, measured
-- with the advance tables of the generated fonts (tests/client/font_advances.lua), like the strict GUI stub does. Every
-- title of every district in en, ru and ko is planned: the rules are checked, not a list of results, so a new district or a
-- reworded title is checked the same way. The window itself, with the real nodes, is in notebook_title_gui_test.lua.

local layout = require("client.notebook_layout")
local advances = require("tests.client.font_advances")
local i18n = require("client.i18n")
local config = require("meta.config")
local songbook_model = require("meta.songbook")
local json = require("tools.lib.json")

local function read(path)
	local f = assert(io.open(path, "rb"))
	local s = f:read("*a")
	f:close()
	return s
end

local districts = json.decode(read("content/districts.json")).districts

local HANGUL = "[\234-\237][\128-\191][\128-\191]" -- as client/ui.lua: the Korean twin of a font draws Hangul

-- the width in px of str at size px in the font that draws it (the title font, its Korean twin for Korean text)
local function measure(str, size)
	local font = (string.find(str, HANGUL) and "title_ko") or "title"
	local f = advances[font]
	local width, i = 0, 1
	while i <= #str do
		local b = string.byte(str, i)
		local cp, n
		if b < 0x80 then cp, n = b, 1
		elseif b < 0xE0 then cp, n = (b - 0xC0) * 64 + (string.byte(str, i + 1) - 0x80), 2
		elseif b < 0xF0 then cp, n = ((b - 0xE0) * 64 + (string.byte(str, i + 1) - 0x80)) * 64 + (string.byte(str, i + 2) - 0x80), 3
		else cp, n = 0xFFFD, 4 end
		assert_true(f.advances[cp] ~= nil, "'" .. str .. "': the glyph U+" .. string.format("%04X", cp) .. " is not in the font " .. font)
		width = width + f.advances[cp]
		i = i + n
	end
	return width * size / f.size
end

local function all_titles()
	local out = {}
	for _, lang in ipairs({ "en", "ru", "ko" }) do
		for _, d in ipairs(districts) do
			for k = 1, config.songbook.titles do
				local key = "sbt." .. d.id .. "." .. k
				local text = i18n.t(key, nil, lang)
				assert_true(text ~= key and text ~= "", key .. " has no text in " .. lang)
				out[#out + 1] = { text = text, key = lang .. " " .. key }
			end
		end
	end
	return out
end

local function widest_page()
	local rows = 0
	for _, d in ipairs(districts) do rows = math.max(rows, d.last - d.first + 1) end
	return rows, #songbook_model.groups(rows)
end

describe("the title of a song page", function()
	it("is planned for every title of every district in en, ru and ko: all lines fit the box, nothing is shrunk below the minimum", function()
		local titles = all_titles()
		assert_true(#titles >= 15 * 16 * 3, "titles: " .. #titles) -- the 15 districts of Part 1 alone give 720
		local one, two = 0, 0
		for _, t in ipairs(titles) do
			local plan = layout.title(t.text, measure)
			assert_true(#plan.lines == 1 or #plan.lines == 2, t.key .. ": lines")
			assert_eq(table.concat(plan.lines, " "), t.text, t.key .. ": the lines are the title")
			assert_eq(#plan.ys, #plan.lines, t.key .. ": a place for every line")
			for _, line in ipairs(plan.lines) do
				assert_true(line ~= "" and string.sub(line, 1, 1) ~= " " and string.sub(line, -1) ~= " ", t.key .. ": a line starts and ends with a letter")
				assert_true(measure(line, plan.size) <= layout.TITLE_W + 0.01,
					string.format("%s: '%s' is %.1f px wide at %.1f px, the box is %d", t.key, line, measure(line, plan.size), plan.size, layout.TITLE_W))
			end
			assert_true(plan.size >= layout.TITLE_MIN - 1e-9 and plan.size <= layout.TITLE_SIZE + 1e-9,
				string.format("%s: %.1f px is outside %d..%d", t.key, plan.size, layout.TITLE_MIN, layout.TITLE_SIZE))
			-- one line as long as the title can be shrunk to the minimum: the rule, not a count
			local fits_small = measure(t.text, layout.TITLE_MIN) <= layout.TITLE_W + 1e-9
			assert_eq(#plan.lines == 1, fits_small, t.key .. ": one line exactly when it fits at " .. layout.TITLE_MIN .. " px")
			if #plan.lines == 1 then one = one + 1 else two = two + 1 end
		end
		assert_true(one > 0 and two > 0, "both kinds of title exist in the game: " .. one .. " one-line, " .. two .. " two-line")
	end)

	it("keeps a title that fits at full size exactly where it was: 40 px, centred on the title row, the first verse 54 px below", function()
		local n = 0
		for _, t in ipairs(all_titles()) do
			if measure(t.text, layout.TITLE_SIZE) <= layout.TITLE_W then
				n = n + 1
				local plan = layout.title(t.text, measure)
				assert_eq(plan.size, layout.TITLE_SIZE, t.key)
				assert_same(plan.ys, { layout.TOP }, t.key)
				assert_eq(plan.first_row, layout.TOP - 54, t.key .. ": the verses start where they always did")
			end
		end
		assert_true(n > 100, "titles that fit: " .. n)
	end)

	it("leaves room: the title block ends above the first verse row with the gap, stays on the sheet, the last row stays on the parchment", function()
		local rows, groups = widest_page()
		assert_eq(rows, 20, "every song of the game has 20 lines")
		for _, t in ipairs(all_titles()) do
			local plan = layout.title(t.text, measure)
			assert_true(plan.top <= layout.PAPER_H / 2, string.format("%s: the title starts at %.1f, above the sheet (%d)", t.key, plan.top, layout.PAPER_H / 2))
			assert_true(plan.bottom - layout.TITLE_GAP >= plan.first_row + layout.ROW_HALF - 1e-9,
				string.format("%s: the title ends at %.1f, the first row starts at %.1f", t.key, plan.bottom, plan.first_row + layout.ROW_HALF))
			if #plan.lines == 2 then
				-- the second line is under the first, the verses moved down for it and by no more than it needs
				assert_true(plan.ys[2] < plan.ys[1] - plan.size, t.key .. ": the lines do not touch")
				assert_true(plan.first_row < layout.ONE_LINE_FIRST_ROW, t.key .. ": the verses moved down")
				assert_near(plan.first_row, plan.bottom - layout.TITLE_GAP - layout.ROW_HALF, 1e-9, t.key)
				assert_true(plan.ys[1] == layout.TOP, t.key .. ": the first line stands on the title row")
			end
			local last = layout.last_row(plan.first_row, rows, groups) - layout.ROW_HALF
			assert_true(last >= layout.PARCHMENT_BOTTOM + 16,
				string.format("%s: the last row ends at %.1f, %.1f px above the edge of the parchment (%d); it needs 16", t.key, last,
					last - layout.PARCHMENT_BOTTOM, layout.PARCHMENT_BOTTOM))
		end
	end)

	it("the box of the title ends before the seal and starts inside the paper", function()
		local seal_left = layout.PAPER_W / 2 - 78 - 52 -- gui/notebook.lua: the seal is 104 px wide, 78 px from the right edge
		assert_true(layout.TITLE_X + layout.TITLE_W / 2 <= seal_left, "the right end of the box is " .. (layout.TITLE_X + layout.TITLE_W / 2) .. ", the seal starts at " .. seal_left)
		assert_true(layout.TITLE_X - layout.TITLE_W / 2 >= -layout.PAPER_W / 2 + 24, "the left end of the box is inside the paper")
	end)

	it("splits a title that is too long for one line at the space that makes the wider line the narrowest", function()
		local function chars(str, size) return #str * size / 2 end -- every character is half a size wide
		-- box 352 at 40 px takes 17.6 characters on one line; at 30 px 23.4: this one has 26
		local plan = layout.title("aaaa bbbbbbbbbb cccc dddd", chars)
		assert_eq(#plan.lines, 2)
		assert_same(plan.lines, { "aaaa bbbbbbbbbb", "cccc dddd" })
		assert_eq(plan.size, layout.TITLE_TWO)
		-- a title that fits at 30 but not at 40 stays on one line, at the size that just fits
		plan = layout.title("aaaa bbbbbbbbbb cccc", chars)
		assert_eq(#plan.lines, 1)
		assert_near(chars(plan.lines[1], plan.size), layout.TITLE_W, 1e-6)
		-- two lines of 23 characters: 368 px at 32 px (too wide), 345 px at 30 px: two lines at the smallest size
		plan = layout.title(string.rep("a", 23) .. " " .. string.rep("b", 23), chars)
		assert_eq(#plan.lines, 2)
		assert_eq(plan.size, layout.TITLE_MIN)
		-- two lines that fit at neither size: shrunk to fit
		plan = layout.title(string.rep("a", 24) .. " " .. string.rep("b", 24), chars)
		assert_eq(#plan.lines, 2)
		assert_true(plan.size < layout.TITLE_MIN and plan.size >= layout.TITLE_FLOOR)
		assert_true(chars(plan.lines[1], plan.size) <= layout.TITLE_W + 1e-6)
		-- one very long word cannot be split: shrunk to fit, never below the floor
		plan = layout.title("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", chars)
		assert_eq(#plan.lines, 1)
		assert_true(plan.size >= layout.TITLE_FLOOR - 1e-9 and plan.size < layout.TITLE_MIN)
		plan = layout.title(string.rep("a", 200), chars)
		assert_eq(plan.size, layout.TITLE_FLOOR, "the floor")
		-- a very long word next to a short one: two lines, shrunk as far as the floor (the text node shrinks the rest to its box)
		plan = layout.title("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa b", chars)
		assert_eq(#plan.lines, 2)
		assert_eq(plan.size, layout.TITLE_FLOOR)
		-- a long word that still fits when the size is shrunk a little
		plan = layout.title("aaaaaaaaaaaaaaaaaaaaaaaaa b", chars) -- 25 characters: 375 px at 30, 352 at 28.2
		assert_eq(#plan.lines, 2)
		assert_true(plan.size < layout.TITLE_MIN and chars(plan.lines[1], plan.size) <= layout.TITLE_W + 1e-6)
	end)

	it("puts the rows in the paper: where the last of a page of 20 lines in 5 groups ends", function()
		assert_eq(layout.last_row(layout.ONE_LINE_FIRST_ROW, 20, 5), 293 - 19 * 28 - 4 * 12)
		assert_eq(layout.last_row(layout.TOP, 1, 1), layout.TOP)
		assert_eq(layout.last_row(layout.TOP, 3, 0), layout.TOP - 2 * layout.STEP, "no groups: no gaps")
	end)
end)
