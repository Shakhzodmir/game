-- The authored tutorials (content/tutorials.json, the one file the game reads) played on the real
-- boards with the real runtime (client/tutorial.lua) behind the guard of client/level_link.lua, in both input
-- modes: every step must be possible on the board the player has when it comes (no repair from the core's hint,
-- no step given up), the guided move must complete it, and the lesson must end as "completed". A failure names
-- the level: the step of the author is wrong for the board (or the board changed under it). The file must
-- exist and be what the runtime loads through sys.load_resource, and every level that brings a new element
-- (levels-plan.md, section 2) must have its lesson: the build fails otherwise, so the game cannot ship without
-- tutorials unnoticed. Every text must fit the two lines of the bubble in English and in Russian (a third line runs
-- under the bubble's Skip tab), and the first record box must say that it does not move.

local tutorial = require("client.tutorial")
local link = require("client.level_link")
local i18n = require("client.i18n")
local json = require("tools.lib.json")
local fake_board = require("tests.client.level_fake_board")

local function read(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function authored()
	local text = read("content/tutorials.json")
	assert_true(text ~= nil, "content/tutorials.json is missing: the game would ship without tutorials")
	return json.decode(text)
end

local function levels_of(defs)
	local ids = {}
	for k in pairs(defs) do ids[#ids + 1] = tonumber(k) end
	table.sort(ids)
	return ids
end

-- Plays the lesson of `level` the way a player who does what the hand shows would. Returns the runtime
-- and what it did (steps done, in order).
local function play(level, defs, mode)
	local text = assert(read(string.format("content/levels/level_%04d.json", level)), "level file " .. level)
	local fb = fake_board.new({ level = level, text = text, input_mode = mode })
	local sess = fb.session
	local done = {}
	local t = tutorial.start(level, {
		defs = defs, seen = function() return false end, mark = function() end,
		on_step = function(_, st) done[#done + 1] = st.kind end,
		env = {
			state = function() return sess.game:status().state end,
			stable = link.stable, can_swap = link.can_swap, piece = link.piece, specials = link.specials,
			hint = link.core_hint, targeting = link.targeting,
			moves_left = function() return sess.game:status().moves_left end,
			booster_ready = function() return true end, mode = function() return mode end,
		},
	})
	assert_true(t ~= nil, "level " .. level .. " has a tutorial")
	link.set_guard(t:guard())
	local acted = {}
	for _ = 1, 60 * 90 do
		fb:advance(1 / 60)
		t:update(1 / 60)
		if t:finished() then break end
		local v = t:view()
		if v and t.age and t.age > 0.5 and not acted[t.rev] then
			if v.kind == "swap" then
				acted[t.rev] = true
				local a, b = v.cells[1], v.cells[2]
				if mode == "taptap" then
					fb:tap(a[1], a[2])
					fb:tap(b[1], b[2])
				else
					fb:swipe(a, b)
				end
			elseif v.kind == "tap" then
				acted[t.rev] = true
				fb:tap(v.cells[1][1], v.cells[1][2])
				if mode == "taptap" then fb:tap(v.cells[1][1], v.cells[1][2]) end -- the first tap selects
			elseif v.kind == "tip" then
				acted[t.rev] = true
				t:tap()
			elseif v.kind == "booster" then
				if v.sub == "pick" then
					acted[t.rev] = true
					link.booster(v.button)
				elseif v.sub == "target" then
					acted[t.rev] = true
					fb:tap(v.cells[1][1], v.cells[1][2])
				end
			end
		end
	end
	link.clear_guard()
	fb:detach()
	return t, done
end

-- The first level that has each of the elements of the plan (slots, floor tiles, overlay): the level that brings it.
local ELEMENTS = { "record_box", "dancefloor", "wires", "mic", "concrete", "noise", "balloon", "column" }

local function first_levels()
	local want, first = {}, {}
	for _, k in ipairs(ELEMENTS) do want[k] = true end
	for n = 1, 100 do
		local text = read(string.format("content/levels/level_%04d.json", n))
		if text then
			local level = json.decode(text)
			local kinds = {}
			for _, slot in ipairs(level.slots or {}) do kinds[slot.type] = true end
			for _, o in ipairs(level.overlay or {}) do kinds[o.type] = true end
			if level.floor and #level.floor > 0 then kinds.dancefloor = true end
			for _, k in ipairs(ELEMENTS) do
				if kinds[k] and not first[k] then first[k] = n end
			end
		end
	end
	return first
end

-- The bubble of a step (screens/level/tutorial_view.lua) sets its text in the body font at 30 px and breaks it at the
-- width of the bubble less Bit's face (620 - 230). Its Skip tab covers the top right corner, so a third line runs under
-- the tab: a text takes two lines at most. The break is modelled word by word with the real advances of the font (as the
-- GUI stub measures text); the margin keeps out the texts that fit by a hair, because the model is not exact to the pixel.
-- A test below pins these numbers to tutorial_view.lua, so the model cannot drift away from the screen unnoticed.
local BUBBLE_W, BUBBLE_FACE, BUBBLE_FONT_SIZE, BUBBLE_LINES, BUBBLE_MARGIN = 620, 230, 30, 2, 6
local BUBBLE_WIDTH = BUBBLE_W - BUBBLE_FACE

local function bubble_lines(text)
	local font = require("tests.client.font_advances").body
	local codepoints = require("tests.client.town_defold_stub").utf8_codepoints
	local function width(s)
		local w = 0
		for _, cp in ipairs(codepoints(s)) do
			local advance = font.advances[cp]
			assert_true(advance ~= nil, string.format("the body font has no glyph U+%04X (%s)", cp, text))
			w = w + advance * BUBBLE_FONT_SIZE / font.size
		end
		return w
	end
	local lines, line = 1, nil
	for word in string.gmatch(text, "%S+") do
		local try = line and (line .. " " .. word) or word
		if line and width(try) > BUBBLE_WIDTH - BUBBLE_MARGIN then
			lines, line = lines + 1, word
		else
			line = try
		end
	end
	return lines
end

describe("the authored tutorials on the real boards", function()
	it("are in the file the game loads: /content/tutorials.json through sys.load_resource", function()
		local town_stub = require("tests.client.town_defold_stub")
		town_stub.install({})
		local ok, err = pcall(function()
			tutorial._reset()
			local warnings = {}
			tutorial.warn = function(text) warnings[#warnings + 1] = text end
			local loaded = tutorial.load() -- the runtime's own path, the project's custom resources
			assert_same(warnings, {}, "the game cannot read " .. tutorial.PATH)
			local defs = authored()
			local ids = levels_of(defs)
			assert_true(#ids >= 15, "lessons in the file: " .. #ids)
			for _, n in ipairs(ids) do
				assert_true(tutorial.steps(loaded, n) ~= nil, "level " .. n .. " has no lesson in what the game loads")
			end
		end)
		tutorial._reset()
		town_stub.shutdown()
		if not ok then error(err, 0) end
	end)

	it("have a lesson for the level that brings each new element", function()
		local defs = authored()
		local first = first_levels()
		assert_true(first.record_box ~= nil and first.mic ~= nil and first.noise ~= nil, "the level files were found")
		for _, k in ipairs(ELEMENTS) do
			if first[k] then
				assert_true(defs[tostring(first[k])] ~= nil,
					"level " .. first[k] .. " brings " .. k .. " and has no lesson in content/tutorials.json")
			end
		end
	end)

	it("are well formed: known kinds, cells on the board, texts in both languages", function()
		local defs = authored()
		local ids = levels_of(defs)
		assert_true(#ids > 0, "no lessons")
		local missing = {}
		for _, n in ipairs(ids) do
			local steps, errors = tutorial.steps(defs, n)
			assert_true(steps ~= nil, "level " .. n .. ": " .. table.concat(errors or {}, "; "))
			assert_eq(#(errors or {}), 0, "level " .. n)
			for i, st in ipairs(steps) do
				if st.text and not i18n.has(st.text) then missing[#missing + 1] = "level " .. n .. " step " .. i .. ": " .. st.text end
			end
		end
		assert_same(missing, {})
	end)

	it("complete in swipe mode with no repair and no step given up", function()
		local defs = authored()
		for _, n in ipairs(levels_of(defs)) do
			local t = play(n, defs, "swipe")
			assert_eq(t.reason, "completed", "level " .. n)
			assert_eq(t.fallbacks, 0, "level " .. n .. " needed the core's hint instead of the author's cells")
		end
	end)

	it("complete in tap-and-tap mode with no repair and no step given up", function()
		local defs = authored()
		for _, n in ipairs(levels_of(defs)) do
			local t = play(n, defs, "taptap")
			assert_eq(t.reason, "completed", "level " .. n)
			assert_eq(t.fallbacks, 0, "level " .. n .. " needed the core's hint instead of the author's cells")
		end
	end)

	it("do every step they have, in order", function()
		local defs = authored()
		for _, n in ipairs(levels_of(defs)) do
			local steps = tutorial.steps(defs, n)
			local _, done = play(n, defs, "swipe")
			local kinds = {}
			for i, st in ipairs(steps) do kinds[i] = st.kind end
			assert_same(done, kinds, "level " .. n)
		end
	end)

	it("are measured the way tutorial_view.lua sets its text (the numbers of the model are the screen's)", function()
		local src = assert(read("screens/level/tutorial_view.lua"), "screens/level/tutorial_view.lua")
		assert_true(string.find(src, "M.BUBBLE_W = " .. BUBBLE_W, 1, true) ~= nil,
			"the bubble is no longer " .. BUBBLE_W .. " px wide: update BUBBLE_W of this test")
		local text = string.format('size = %d, color = "text", width = br.w - %d,', BUBBLE_FONT_SIZE, BUBBLE_FACE)
		assert_true(string.find(src, text, 1, true) ~= nil,
			"the text of the bubble is no longer set as [" .. text .. "]: update the model of this test")
	end)

	it("keep every text within the two lines the bubble has room for, in both languages", function()
		local defs = authored()
		local long = {}
		for _, n in ipairs(levels_of(defs)) do
			for i, st in ipairs(tutorial.steps(defs, n)) do
				if st.text then
					for _, lang in ipairs(i18n.LANGUAGES) do
						local text = i18n.t(st.text, nil, lang)
						local lines = bubble_lines(text)
						if lines > BUBBLE_LINES then
							long[#long + 1] = string.format("level %d step %d %s [%s] takes %d lines: %s", n, i, st.text, lang, lines, text)
						end
					end
				end
			end
		end
		assert_true(#long == 0, "these texts run under the Skip tab of the bubble:\n  " .. table.concat(long, "\n  "))
	end)

	it("say at the first record box that it does not move (the plate under it says the same)", function()
		local level = first_levels().record_box
		local said = { en = false, ru = false }
		for _, st in ipairs(tutorial.steps(authored(), level)) do
			if st.text then
				said.en = said.en or string.find(i18n.t(st.text, nil, "en"), "don't move", 1, true) ~= nil
				said.ru = said.ru or string.find(i18n.t(st.text, nil, "ru"), "не двигаются", 1, true) ~= nil
			end
		end
		assert_true(said.en, "no text of the lesson of level " .. level .. " says in English that record boxes do not move")
		assert_true(said.ru, "no text of the lesson of level " .. level .. " says in Russian that record boxes do not move")
	end)
end)
