-- Level CLI (tools/levels.lua): validation, plan checks, stats, preview.

local common = require("tools.bot.common")
local Levels = require("tools.levels")
local F = require("tests.tools.fixture")
local core = require("core.game")

describe("tools levels", function()
	it("validates a good level and reports core errors of a bad one", function()
		local dir = F.tmpdir()
		local good = dir .. "/level_0001.json"
		assert(common.write_file(good, F.level_text({ id = 1, moves = 25 })))
		local r = Levels.validate_file(good, core)
		assert_true(r.ok, table.concat(r.errors, "; "))
		assert_same(r.warnings, {})
		local bad = dir .. "/level_0002.json"
		assert(common.write_file(bad, F.level_text({ id = 2, moves = 3 })))
		local rb = Levels.validate_file(bad, core)
		assert_false(rb.ok)
		assert_true(rb.errors[1]:find("moves", 1, true) ~= nil, rb.errors[1])
		local wrong = dir .. "/level_0003.json"
		assert(common.write_file(wrong, F.level_text({ id = 4, moves = 25 })))
		local rw = Levels.validate_file(wrong, core)
		assert_false(rw.ok)
		assert_true(rw.errors[1]:find("file name says level 3", 1, true) ~= nil)
		F.rmdir(dir)
	end)

	it("warns about plan rules: difficulty saw, colours, moves band", function()
		local dir = F.tmpdir()
		local p = dir .. "/level_0024.json"
		-- level 24 is hard in the saw; 4 colours are fine up to 30; 40 moves is outside 20-35
		assert(common.write_file(p, F.level_text({ id = 24, moves = 40, difficulty = "easy" })))
		local r = Levels.validate_file(p, core)
		assert_true(r.ok)
		assert_eq(#r.warnings, 2)
		assert_true(r.warnings[1]:find("hard expected", 1, true) ~= nil)
		assert_true(r.warnings[2]:find("outside 20-35", 1, true) ~= nil)
		F.rmdir(dir)
	end)

	it("knows the plan's saw: 126 stars over 100 levels", function()
		local stars, counts = 0, {}
		for id = 1, 100 do
			local d = Levels.plan_difficulty(id)
			counts[d] = (counts[d] or 0) + 1
			stars = stars + common.STARS[d]
		end
		assert_eq(stars, 126)
		assert_same(counts, { easy = 52, medium = 27, hard = 16, super_hard = 5 })
		assert_eq(Levels.plan_difficulty(24), "hard")
		assert_eq(Levels.plan_difficulty(60), "super_hard")
		assert_eq(Levels.plan_difficulty(101), nil)
	end)

	it("counts difficulties, stars and elements", function()
		local raws = {
			F.level_table({ id = 1 }),
			F.level_table({ id = 2, difficulty = "hard", floor = { { at = { 1, 1 }, hp = 1 } },
				slots = { { at = { 2, 2 }, type = "record_box", hp = 1 }, { at = { 3, 3 }, type = "sub" } } }),
		}
		local st = Levels.stats(raws)
		assert_eq(st.counts.easy, 1)
		assert_eq(st.counts.hard, 1)
		assert_eq(st.stars, 3)
		assert_same(st.rows[2].elements, { "record_box", "dancefloor" })
		assert_eq(st.rows[2].specials, 1)
		assert_eq(st.first.record_box, 2)
	end)

	it("draws a level and a seeded start board", function()
		local raw = F.level_table({
			cells = { "..#####", "#######", "#######", "#######", "#######", "#######", "#######" },
			floor = { { at = { 3, 6 }, hp = 2 } },
			slots = { { at = { 3, 3 }, type = "riff", axis = "v" }, { at = { 0, 6 }, type = "record_box", hp = 2 } },
		})
		local out = Levels.preview_raw(raw)
		local lines = {}
		for l in out:gmatch("[^\n]+") do lines[#lines + 1] = l end
		assert_eq(#lines, 2 + 7) -- column numbers, spawners, 7 rows
		assert_true(lines[3]:find(" .    .   +   ", 1, true) ~= nil, lines[3])
		assert_true(lines[6]:find("R|", 1, true) ~= nil, lines[6])
		assert_true(lines[9]:find("X2", 1, true) ~= nil and lines[9]:find("+ =", 1, true) ~= nil, lines[9])
		local e = common.entry_from_text(common.encode(raw))
		local g = core.new(e.level, { seed = 3 })
		local board = Levels.preview_game(g, 7, 7)
		assert_true(board:find("R|", 1, true) ~= nil)
		assert_false(board:find("+", 1, true) ~= nil, "no random placeholders on a start board")
	end)

	it("validates the repository's levels through the CLI", function()
		local vm = (jit and "luajit") or "lua5.1"
		if not F.have(vm) then return end
		local out = F.capture(vm .. " tools/levels.lua validate 1 2>&1")
		assert_true(out:find("ok   level_0001.json", 1, true) ~= nil or out:find("FAIL level_0001.json", 1, true) ~= nil, out)
		assert_true(out:find("1 level(s):", 1, true) ~= nil, out)
	end)
end)
