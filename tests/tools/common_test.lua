-- Shared helpers of the level tools (tools/bot/common.lua): command line,
-- JSON, checksums, files, the bots' random stream.

local common = require("tools.bot.common")
local F = require("tests.tools.fixture")

describe("tools common: command line", function()
	local FLAGS = { write = true, quiet = true }
	local VALUES = { n = true, levels = true, dir = true }

	it("reads values, flags, positional words and --key=value", function()
		local o, pos, err = common.parse_args({ "validate", "--n", "30", "--write", "5", "--levels=1-4" }, FLAGS, VALUES)
		assert_eq(err, nil)
		assert_same(pos, { "validate", "5" })
		assert_eq(o.n, "30")
		assert_eq(o.write, true)
		assert_eq(o.levels, "1-4")
	end)

	it("rejects unknown options, a missing value and a value for a flag", function()
		local _, _, e1 = common.parse_args({ "--level", "5" }, FLAGS, VALUES)
		assert_true(e1 ~= nil and e1:find("unknown option --level", 1, true) ~= nil, tostring(e1))
		local _, _, e2 = common.parse_args({ "--n" }, FLAGS, VALUES)
		assert_true(e2 ~= nil and e2:find("needs a value", 1, true) ~= nil, tostring(e2))
		local _, _, e3 = common.parse_args({ "--n", "--write" }, FLAGS, VALUES)
		assert_true(e3 ~= nil and e3:find("needs a value", 1, true) ~= nil, tostring(e3))
		local _, _, e4 = common.parse_args({ "--write=1" }, FLAGS, VALUES)
		assert_true(e4 ~= nil and e4:find("takes no value", 1, true) ~= nil, tostring(e4))
		-- a negative number is a value, not an option
		local o, _, e5 = common.parse_args({ "--n", "-3" }, FLAGS, VALUES)
		assert_eq(e5, nil)
		assert_eq(o.n, "-3")
	end)

	it("without a list of values keeps the old permissive reading", function()
		local o, pos, err = common.parse_args({ "25", "--seed", "7", "--turbo", "--anything", "x" }, { turbo = true })
		assert_eq(err, nil)
		assert_same(pos, { "25" })
		assert_eq(o.seed, "7")
		assert_eq(o.turbo, true)
		assert_eq(o.anything, "x")
	end)

	it("checks integer options", function()
		assert_eq(common.int_option({}, "n", 100, 1, 10), 100)
		assert_eq(common.int_option({ n = "7" }, "n", 100, 1, 10), 7)
		for _, bad in ipairs({ "abc", "2.5", "0", "11", "inf", "nan", "" }) do
			local v, err = common.int_option({ n = bad }, "n", 100, 1, 10)
			assert_eq(v, nil, "value '" .. bad .. "'")
			assert_true(err:find("--n", 1, true) ~= nil, err)
		end
		assert_eq(common.int_option({ n = "-5" }, "n", 1, -10, 10), -5)
		assert_eq(common.int_option({ n = "5" }, "n", nil), 5)
	end)

	it("parses level lists and refuses malformed ones", function()
		assert_same(common.parse_ids("1-3,7,10-11"), { 1, 2, 3, 7, 10, 11 })
		assert_same(common.parse_ids("5"), { 5 })
		for _, bad in ipairs({ "", "abc", "1-", "-3", "5-3", "1,,x", "1;2" }) do
			local ids, err = common.parse_ids(bad)
			assert_eq(ids, nil, "'" .. bad .. "'")
			assert_true(type(err) == "string", "'" .. bad .. "' has a message")
		end
		-- an empty part between commas is skipped
		assert_same(common.parse_ids("1,,2"), { 1, 2 })
	end)

	it("maps ids, names and paths to level files", function()
		assert_eq(common.level_path("5", "d"), "d/level_0005.json")
		assert_eq(common.level_path("level_0012", "d"), "d/level_0012.json")
		assert_eq(common.level_path("some/where/x.json", "d"), "some/where/x.json")
	end)
end)

describe("tools common: JSON", function()
	it("writes sorted keys, escapes and integers; empty tables are arrays", function()
		assert_eq(common.encode({ b = 1, a = { 1, 2, { x = 'é\n\t"' } }, c = 0.5, d = true, e = {} }),
			'{"a":[1,2,{"x":"é\\n\\t\\""}],"b":1,"c":0.5,"d":true,"e":[]}')
		assert_eq(common.encode({ k = { 1, 2 } }, "  "), '{\n  "k": [1,2]\n}')
		assert_eq(common.encode({ 3, 4.25, -7 }), "[3,4.25,-7]")
		assert_eq(common.encode(1e15), "1000000000000000")
		assert_eq(common.encode(0 / 0), "null")
	end)

	it("round-trips what the tools store", function()
		local v = { id = 7, flags = { "a", "b" }, games = { { m = 12, r = { 0.5, 0.25, 0 }, e = "won" }, { r = {}, e = "budget" } },
			note = "ключ\"\\", x = { 1.5, 2 } }
		local back = common.decode(common.encode(v))
		assert_same(back, v)
		assert_same(common.decode(common.encode(v, "  ")), v)
	end)

	it("decode reports a bad text instead of raising", function()
		local v, err = common.decode("{")
		assert_eq(v, nil)
		assert_true(type(err) == "string")
		local ok = pcall(common.decode, "")
		assert_true(ok)
	end)

	it("an entry needs a JSON object", function()
		for _, text in ipairs({ "null", "5", '"x"', "[1]", "" }) do
			local e, errs = common.entry_from_text(text, "x.json")
			assert_eq(e, nil, text)
			assert_true(type(errs) == "table" and #errs >= 1, text)
		end
	end)
end)

describe("tools common: checksums and signatures", function()
	it("has the same checksum on every VM", function()
		assert_eq(common.checksum(""), "000015050000cde7")
		assert_eq(common.checksum("abc"), "0b885c8b0a0e3ad7")
		assert_eq(common.checksum(string.rep("The quick brown fox ", 100)), "477794c963528ae6")
		assert_true(common.checksum("abd") ~= common.checksum("abc"))
		assert_true(common.checksum("ab") ~= common.checksum("ba"))
	end)

	it("a level signature ignores the move limit and nothing else", function()
		local a = F.level_text({ moves = 20 })
		local b = F.level_text({ moves = 31 })
		local c = F.level_text({ moves = 20, difficulty = "hard" })
		assert_true(a ~= b)
		assert_eq(common.level_sig(a), common.level_sig(b))
		assert_true(common.level_sig(a) ~= common.level_sig(c))
		assert_eq(common.level_sig("no moves key here"), common.checksum("no moves key here"))
	end)

	it("checksums files by name and content", function()
		local dir = F.tmpdir()
		assert(common.write_file(dir .. "/a.lua", "return 1"))
		assert(common.write_file(dir .. "/b.lua", "return 2"))
		local h1 = common.checksum_files({ dir .. "/a.lua", dir .. "/b.lua" })
		assert_eq(common.checksum_files({ dir .. "/a.lua", dir .. "/b.lua" }), h1)
		assert(common.write_file(dir .. "/b.lua", "return 3"))
		assert_true(common.checksum_files({ dir .. "/a.lua", dir .. "/b.lua" }) ~= h1)
		local none, which = common.checksum_files({ dir .. "/a.lua", dir .. "/missing.lua" })
		assert_eq(none, nil)
		assert_eq(which, dir .. "/missing.lua")
		F.rmdir(dir)
	end)
end)

describe("tools common: files", function()
	it("writes atomically and leaves no temporary file", function()
		local dir = F.tmpdir()
		local path = dir .. "/x.json"
		assert(common.write_file_atomic(path, "one"))
		assert(common.write_file_atomic(path, "two"))
		assert_eq(common.read_file(path), "two")
		assert_same(common.list_dir(dir), { "x.json" })
		local ok, err = common.write_file_atomic(dir .. "/missing/y.json", "x")
		assert_eq(ok, nil)
		assert_true(err ~= nil)
		F.rmdir(dir)
	end)

	it("lists level files of a directory whose name needs quoting", function()
		local base = F.tmpdir()
		local dir = base .. "/it's a dir"
		os.execute("mkdir -p '" .. base .. "/it'\\''s a dir'")
		assert(common.write_file(dir .. "/level_0002.json", "{}"))
		assert(common.write_file(dir .. "/level_0001.json", "{}"))
		assert(common.write_file(dir .. "/notes.md", "x"))
		assert(common.write_file(dir .. "/tuning.json", "{}"))
		assert(common.write_file(dir .. "/level_0003.json.tmp", "{}"))
		local files = common.level_files(dir)
		assert_same(files, { dir .. "/level_0001.json", dir .. "/level_0002.json" })
		assert_same(common.level_files(base .. "/absent"), {})
		assert_eq(common.shell_quote("a'b"), "'a'\\''b'")
		F.rmdir(base)
	end)
end)

describe("tools common: statistics and the bots' stream", function()
	it("median and rounding", function()
		assert_eq(common.median({}), nil)
		assert_eq(common.median({ 5 }), 5)
		assert_eq(common.median({ 9, 1, 5 }), 5)
		assert_eq(common.median({ 4, 1, 3, 2 }), 2.5)
		assert_eq(common.round(0.12345, 2), 0.12)
		assert_eq(common.round(2.5), 3)
	end)

	it("the MINSTD stream is the same on every VM and independent of the game", function()
		local r = common.rng(7)
		local got = {}
		for i = 1, 5 do got[i] = common.rng_next(r) end
		assert_same(got, { 1810264742, 32281005, 1310748280, 1967015966, 985726328 })
		local r2 = common.rng(1)
		local ints = {}
		for i = 1, 8 do ints[i] = common.rng_int(r2, 10) end
		assert_same(ints, { 1, 6, 3, 9, 4, 2, 1, 8 })
		for _ = 1, 200 do
			local k = common.rng_int(r2, 3)
			assert_true(k >= 1 and k <= 3)
		end
	end)

	it("difficulty corridors are the plan's", function()
		assert_same(common.CORRIDOR.easy, { lo = 0.85, hi = 0.95, target = 0.90 })
		assert_same(common.CORRIDOR.medium, { lo = 0.60, hi = 0.75, target = 0.68 })
		assert_same(common.CORRIDOR.hard, { lo = 0.35, hi = 0.50, target = 0.42 })
		assert_same(common.CORRIDOR.super_hard, { lo = 0.20, hi = 0.30, target = 0.25 })
		-- the stars are the core's (easy, medium, hard, super_hard)
		local C = require("core.const")
		assert_eq(common.STARS.easy, C.STARS[1])
		assert_eq(common.STARS.medium, C.STARS[2])
		assert_eq(common.STARS.hard, C.STARS[3])
		assert_eq(common.STARS.super_hard, C.STARS[4])
	end)
end)
