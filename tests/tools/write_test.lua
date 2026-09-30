-- tune.lua --write: only the "moves" value of a level file changes.

local common = require("tools.bot.common")
local Tune = require("tools.bot.tune")
local F = require("tests.tools.fixture")
local core = require("core.game")

-- Byte-compares a and b except for one differing run: returns the common
-- prefix and suffix lengths.
local function diff_span(a, b)
	local p = 0
	while p < #a and p < #b and a:byte(p + 1) == b:byte(p + 1) do p = p + 1 end
	local s = 0
	while s < #a - p and s < #b - p and a:byte(#a - s) == b:byte(#b - s) do s = s + 1 end
	return p, s
end

describe("tools tune --write", function()
	it("replaces only the digits of the moves value in every level file", function()
		local files = common.level_files("content/levels")
		assert_true(#files >= 1, "level files present")
		for _, f in ipairs(files) do
			local text = assert(common.read_file(f))
			local old, a, b = common.find_moves(text)
			if old then -- files being edited by another team may be mid-change
				local want = old == 33 and 34 or 33
				local new = common.set_moves(text, want)
				assert_eq(common.find_moves(new), want, f)
				assert_eq(new:sub(1, a - 1), text:sub(1, a - 1), f .. " prefix")
				assert_eq(new:sub(a + #tostring(want)), text:sub(b + 1), f .. " suffix")
				local p, s = diff_span(text, new)
				assert_true(p >= a - 1 and #new - s <= a - 1 + #tostring(want), f .. " one changed run")
				assert_eq(common.set_moves(new, old), text, f .. " round trip")
			end
		end
	end)

	it("keeps gap_moves and other keys, and refuses ambiguous files", function()
		local text = '{"id": 1, "moves": 9, "mic": {"total": 2, "on_board_max": 1, "gap_moves": 3}}\n'
		assert_eq(common.set_moves(text, 27), '{"id": 1, "moves": 27, "mic": {"total": 2, "on_board_max": 1, "gap_moves": 3}}\n')
		local spaced = '{\n  "moves"  :\t 26,\n  "x": 1\n}'
		assert_eq(common.set_moves(spaced, 5), '{\n  "moves"  :\t 5,\n  "x": 1\n}')
		local v, why = common.find_moves('{"moves": 3, "a": {"moves": 4}}')
		assert_eq(v, nil)
		assert_true(why:find("found 2", 1, true) ~= nil)
		assert_error(function() common.set_moves('{"id": 1}', 5) end, "found 0")
	end)

	it("writes level files through Tune.write_moves and leaves the rest identical", function()
		local dir = F.tmpdir()
		local src = F.level_text({ moves = 20 })
		local path = dir .. "/level_0901.json"
		assert(common.write_file(path, src))
		local same = dir .. "/level_0902.json"
		assert(common.write_file(same, F.level_text({ id = 902, moves = 31 })))
		local before_same = common.read_file(same)
		local n = Tune.write_moves({
			{ file = path, M = 31 },
			{ file = same, M = 31 },            -- unchanged value: file untouched
			{ file = dir .. "/bad.json", error = "x", flags = { "invalid" } },
		})
		assert_eq(n, 1)
		local after = common.read_file(path)
		assert_eq(after, src:gsub('"moves": 20', '"moves": 31'))
		assert_eq(common.read_file(same), before_same)
		local lvl = core.load_level(after)
		assert_true(lvl ~= nil)
		assert_eq(lvl.moves, 31)
		F.rmdir(dir)
	end)

	it("loads a level with a larger budget through the same replacement", function()
		local e = F.entry({ moves = 20 })
		local lvl = common.level_with_moves(e, 60)
		assert_eq(lvl.moves, 60)
		assert_true(common.level_with_moves(e, 60) == lvl, "cached")
		assert_true(common.level_with_moves(e, 20) == e.level, "own moves: the loaded level")
		assert_true(lvl.hash ~= e.level.hash, "a different level text")
	end)
end)
