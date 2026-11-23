-- The title of a finished song on the songbook page (gui/notebook.lua), run on the strict Defold GUI stub with every
-- title of every district in every language.
--
-- The page is a parchment with the title at its top edge, the golden seal on its right and the verses below. A title
-- that did not fit on one line used to wrap onto a second line that sat ON TOP of the first verse (English "Shared
-- Heartbeat", Russian "Последнее фото", the Korean title of a district): 168 of 352 English and 238 of 352 Russian
-- titles are wider than the 336 px box at the 40 px of a title, in Part 1 as much as in Part 2. A title now stays on
-- one line as long as it can be shrunk to a readable size, else it takes two lines and the verses start lower.
--
-- Checked on the real GUI script, with the texts and the font metrics of the game (tests/client/font_advances.lua), not on
-- a model of it: the text nodes of the title never touch a verse row or a verse label, stay on the sheet and clear of
-- the seal, are not smaller than a readable size, and the last verse row is still on the parchment. Positions are
-- paper coordinates: the centre of the sheet is 0, 0 and y goes up.

local G = require("tests.client.meta_gui_helper")
local flow = require("client.flow")
local bus = require("client.bus")
local i18n = require("client.i18n")
local songbook = require("client.songbook")
local config = require("meta.config")
local json = require("tools.lib.json")

local function read(path)
	local f = assert(io.open(path, "rb"))
	local s = f:read("*a")
	f:close()
	return s
end

local districts = json.decode(read("content/districts.json")).districts

local PAPER_W, PAPER_H = 556, 790 -- the sheet of gui/notebook.lua
-- the visible edges of the parchment on the sheet (paper_sheet.png is 640x900 with 36 transparent rows above and below,
-- drawn at 556x790): 363 px above and 362 px below the centre of the sheet
local PARCHMENT_BOTTOM = -362
local MIN_TITLE_PX = 30 -- the smallest a title may be: the verses are 23 px, the verse labels 18 px
local FIRST_ROW, TITLE_ROW = 293, 347 -- where the first verse and the title of a one-line title stand (paper coordinates)

-- all different titles of a language, and which keys carry each
local function titles_of(lang)
	local keys, list = {}, {}
	for _, d in ipairs(districts) do
		for k = 1, config.songbook.titles do
			local key = "sbt." .. d.id .. "." .. k
			local text = i18n.t(key, nil, lang)
			assert_true(text ~= key and text ~= "", key .. " has no text in " .. lang)
			if not keys[text] then
				keys[text] = {}
				list[#list + 1] = text
			end
			table.insert(keys[text], d.id .. "." .. k)
		end
	end
	return list, keys
end

-- What is on the sheet now, in paper coordinates: the title pieces (the texts above the first verse), the other texts of
-- the sheet (verses and labels), the seal.
local function read_page(c, first_line)
	local E = c.E
	local function window_rect(n)
		local x0, y0, x1, y1 = E.rect(n)
		local ax, ay = E.to_logical(x0, y0)
		local bx, by = E.to_logical(x1, y1)
		return math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by)
	end
	local nodes = E.alive_nodes(c.town.scene)
	local first
	for _, n in ipairs(nodes) do
		if n.kind == "text" and E.visible(n) and n.text == first_line then first = n break end
	end
	assert_true(first ~= nil, "the first verse is not on the page: " .. G.dump(c.town))
	local paper = first.parent
	local px0, py0, px1, py1 = window_rect(paper)
	local k, cx, cy = (px1 - px0) / PAPER_W, (px0 + px1) / 2, (py0 + py1) / 2
	local function rect(n)
		local x0, y0, x1, y1 = window_rect(n)
		return { x0 = (x0 - cx) / k, y0 = (y0 - cy) / k, x1 = (x1 - cx) / k, y1 = (y1 - cy) / k, text = n.text }
	end
	local f = rect(first)
	local page = { first = f, pieces = {}, others = {}, stamp = nil, sheet = rect(paper) }
	for _, n in ipairs(nodes) do
		if n.parent == paper and E.visible(n) then
			if n.kind == "text" and (n.text or "") ~= "" then
				local r = rect(n)
				-- the verses start at the first row: whatever stands above it is the title
				if (r.y0 + r.y1) / 2 > (f.y0 + f.y1) / 2 + 1 then
					table.insert(page.pieces, r)
				else
					table.insert(page.others, r)
				end
			elseif n.kind == "box" and math.abs(n.size.x - 104) < 1 and math.abs(n.size.y - 104) < 1 then
				page.stamp = rect(n)
			end
		end
	end
	table.sort(page.pieces, function(a, b) return a.y1 > b.y1 end) -- the top line first
	return page
end

local function overlap(a, b)
	return a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1
end

-- The complaints about the title on the page now (an empty list: nothing wrong).
local function complaints(c, title, song)
	local out = {}
	local page = read_page(c, songbook.line(song.id, song.lines[1]))
	local parts = {}
	for _, p in ipairs(page.pieces) do parts[#parts + 1] = p.text end
	if table.concat(parts, " ") ~= title then
		out[#out + 1] = "the texts above the first verse ('" .. table.concat(parts, "' + '") .. "') are not the title"
		return out
	end
	local lowest = math.huge
	for _, p in ipairs(page.pieces) do
		lowest = math.min(lowest, p.y0)
		for _, o in ipairs(page.others) do
			if overlap(p, o) then out[#out + 1] = "'" .. p.text .. "' sits on '" .. o.text .. "'" end
		end
		if p.y1 - p.y0 < MIN_TITLE_PX - 0.5 then
			out[#out + 1] = string.format("'%s' is only %.1f px high (the smallest is %d)", p.text, p.y1 - p.y0, MIN_TITLE_PX)
		end
		if p.x0 < -PAPER_W / 2 + 24 or p.x1 > PAPER_W / 2 - 24 then
			out[#out + 1] = string.format("'%s' is out of the sheet (%.0f..%.0f)", p.text, p.x0, p.x1)
		end
		if page.stamp and p.x1 > page.stamp.x0 then
			out[#out + 1] = string.format("'%s' reaches the seal (%.0f > %.0f)", p.text, p.x1, page.stamp.x0)
		end
		if p.y1 > PAPER_H / 2 then out[#out + 1] = "'" .. p.text .. "' is above the sheet" end
	end
	if lowest < page.first.y1 then
		out[#out + 1] = string.format("the title reaches down to %.0f, the first verse starts at %.0f", lowest, page.first.y1)
	end
	-- the last verse row is still on the parchment, which is drawn with a margin on the sheet
	local last_bottom = math.huge
	for _, o in ipairs(page.others) do last_bottom = math.min(last_bottom, o.y0) end
	if last_bottom < PARCHMENT_BOTTOM + 16 then
		out[#out + 1] = string.format("the last row ends %.0f px above the edge of the parchment (it needs 16)", last_bottom - PARCHMENT_BOTTOM)
	end
	return out
end

-- A finished song of the first district on display, the window open; fn(c, song, set_title). set_title(text) puts that
-- title on the page (songbook.title is looked up at every build) and has the window built again; it is put back at the end.
local function with_page(lang, fn)
	local real_title = songbook.title
	local ok, err = pcall(function()
		G.with_town({ language = lang, setup = function()
			for _ = 1, 21 do assert(flow.debug_win(3, false, true)) end
		end }, function(c)
			c.run(2) -- the finished song is offered: the window opens
			assert_eq(c.app.ui.popup, "notebook")
			local song = c.app.meta:song_of("cafe")
			assert_true(song.ready and song.lines[1] ~= nil)
			local function set_title(text)
				songbook.title = function() return text end
				bus.publish("language_changed", { language = lang }) -- every window is built again
				c.step(3)
			end
			fn(c, song, set_title)
		end)
	end)
	songbook.title = real_title
	if not ok then error(err, 0) end
end

describe("the title of a finished song on the songbook page", function()
	for _, lang in ipairs({ "en", "ru", "ko" }) do
		it("stays clear of the verses, the seal and the edges of the sheet, not smaller than " .. MIN_TITLE_PX .. " px: every title of every district in " .. lang, function()
			local list, keys = titles_of(lang)
			assert_true(#list >= 300, "titles in " .. lang .. ": " .. #list)
			local bad = {}
			with_page(lang, function(c, song, set_title)
				for _, text in ipairs(list) do
					set_title(text)
					for _, why in ipairs(complaints(c, text, song)) do
						bad[#bad + 1] = string.format("%s [%s]: %s", text, keys[text][1], why)
					end
					if #bad >= 12 then break end
				end
			end)
			assert_true(#bad == 0, lang .. ": " .. #bad .. " problem(s), the first ones:\n  " .. table.concat(bad, "\n  "))
		end)
	end

	it("keeps a short title where it was: one line on the title row, the verses where they were", function()
		with_page("en", function(c, song, set_title)
			set_title("Last Photo")
			local page = read_page(c, songbook.line(song.id, song.lines[1]))
			assert_eq(#page.pieces, 1, "one line")
			assert_near((page.pieces[1].y0 + page.pieces[1].y1) / 2, TITLE_ROW, 1)
			assert_near((page.first.y0 + page.first.y1) / 2, FIRST_ROW, 1)
			assert_same(complaints(c, "Last Photo", song), {})
		end)
	end)

	it("takes two lines of room for a title that cannot stay on one line, and the verses start below them", function()
		with_page("ru", function(c, song, set_title)
			local long = "Маленький оркестр, большой звук" -- the longest Russian title
			set_title(long)
			local page = read_page(c, songbook.line(song.id, song.lines[1]))
			assert_eq(#page.pieces, 2, "two lines")
			assert_true(page.pieces[1].y0 >= page.pieces[2].y1 - 0.5, "the lines do not touch each other")
			assert_true(page.pieces[2].y0 > page.first.y1, "the second line ends above the first verse")
			assert_true((page.first.y0 + page.first.y1) / 2 < FIRST_ROW, "the verses moved down to make room")
			assert_same(complaints(c, long, song), {})
		end)
	end)
end)
