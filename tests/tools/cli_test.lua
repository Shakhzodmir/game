-- Command-line tests of the level tools (tools/levels.lua, tools/bot/run.lua,
-- tools/bot/tune.lua). They run the real scripts as subprocesses on copies of
-- small fixture levels in a temporary directory: nothing under content/ is
-- touched, and every tuner test uses --dir (or --no-report) so no report can
-- overwrite docs/levels.

local common = require("tools.bot.common")
local F = require("tests.tools.fixture")

local VM = F.vm()

local function tune(args)
	return F.sh(VM .. " tools/bot/tune.lua " .. args)
end

-- Fixture levels that a game wins in a few moves (fast to play).
local function quick_levels(dir, ids)
	local extras = {}
	for i, id in ipairs(ids) do
		extras[id] = { goals = { { type = "collect", color = "red", count = 4 + 2 * i } } }
	end
	return F.write_levels(dir, ids, extras)
end

-- "id:limit" pairs from the tuner's console table.
local function limits(out)
	local t = {}
	for id, m in out:gmatch("(%d+) easy%s+33%->(%d+)") do t[#t + 1] = id .. ":" .. m end
	return table.concat(t, " ")
end

describe("tools tune CLI: a copy of the levels directory", function()
	it("--levels with --write changes only the moves digits of the chosen files", function()
		local dir = F.tmpdir()
		local files = quick_levels(dir, { 901, 902, 903 })
		local before = {}
		for i, f in ipairs(files) do before[i] = common.read_file(f) end
		local repo_before = common.read_file("content/levels/level_0001.json")
		local out, code = tune("--dir " .. dir .. " --levels 902-903 --n 4 --force --write --no-report --quiet")
		assert_eq(code, 0, out)
		assert_eq(common.read_file(files[1]), before[1], "level 901 was not chosen")
		for i = 2, 3 do
			local after = common.read_file(files[i])
			local old = common.find_moves(before[i])
			local new = common.find_moves(after)
			assert_eq(old, 33)
			assert_true(new >= 5 and new <= 60, "limit " .. tostring(new))
			assert_true(new ~= old, "a quick level does not need 33 moves")
			assert_eq(common.set_moves(after, old), before[i], "everything but the digits is the same")
			assert_eq(out:match(string.format("90%d easy%%s+33%%->(%%d+)", i)), tostring(new), "the table says the same limit")
		end
		assert_true(out:find("--write: 2 level file(s) changed, 0 skipped", 1, true) ~= nil, out)
		assert_eq(common.read_file("content/levels/level_0001.json"), repo_before, "the real levels are untouched")
		assert_same(common.list_dir(dir), { "level_0901.json", "level_0902.json", "level_0903.json" })
		F.rmdir(dir)
	end)

	it("without --write no level file changes, and the table lists every level", function()
		local dir = F.tmpdir()
		local files = quick_levels(dir, { 901, 902 })
		local before = { common.read_file(files[1]), common.read_file(files[2]) }
		local out, code = tune("--dir " .. dir .. " --n 3 --no-report --quiet")
		assert_eq(code, 0, out)
		assert_true(out:find("2 levels, 3 games/level", 1, true) ~= nil, out)
		local rows = 0
		for _ in limits(out):gmatch("%d+:%d+") do rows = rows + 1 end
		assert_eq(rows, 2, "two rows: " .. limits(out))
		assert_eq(common.read_file(files[1]), before[1])
		assert_eq(common.read_file(files[2]), before[2])
		F.rmdir(dir)
	end)

	it("refuses --write with a small N unless --force, and writes nothing", function()
		local dir = F.tmpdir()
		local files = quick_levels(dir, { 901 })
		local before = common.read_file(files[1])
		local out, code = tune("--dir " .. dir .. " --levels 901 --n 5 --write --no-report")
		assert_eq(code, 2, out)
		assert_true(out:find("--force", 1, true) ~= nil, out)
		assert_eq(common.read_file(files[1]), before)
		F.rmdir(dir)
	end)

	it("rejects typos and bad numbers with exit code 2 before playing anything", function()
		local dir = F.tmpdir()
		quick_levels(dir, { 901 })
		local cases = {
			{ "--levle 1", "unknown option --levle" },
			{ "--n abc", "--n" },
			{ "--n 0", "--n" },
			{ "--jobs 0", "--jobs" },
			{ "--jobs abc", "--jobs" },
			{ "--budget 10", "--budget" },
			{ "--levels 5-3", "backwards" },
			{ "--levels x", "cannot read" },
			{ "--bot foo", "--bot" },
			{ "stray", "unexpected argument" },
			{ "--n", "needs a value" },
		}
		for _, c in ipairs(cases) do
			local out, code = tune("--dir " .. dir .. " " .. c[1])
			assert_eq(code, 2, c[1] .. ": " .. out)
			assert_true(out:find(c[2], 1, true) ~= nil, c[1] .. ": " .. out)
			assert_true(out:find("stack traceback", 1, true) == nil, c[1] .. ": " .. out)
		end
		local out, code = tune("--help")
		assert_eq(code, 0)
		assert_true(out:find("usage: luajit tools/bot/tune.lua", 1, true) ~= nil)
		F.rmdir(dir)
	end)

	it("reports levels that do not exist or do not load", function()
		local dir = F.tmpdir()
		quick_levels(dir, { 901 })
		assert(common.write_file(dir .. "/level_0902.json", "{ not json"))
		local out, code = tune("--dir " .. dir .. " --levels 999 --n 2 --no-report")
		assert_eq(code, 1, out)
		assert_true(out:find("no level files", 1, true) ~= nil, out)
		out, code = tune("--dir " .. dir .. " --n 2 --no-report --quiet")
		assert_eq(code, 1, "an invalid level makes the exit code 1")
		assert_true(out:find("invalid:", 1, true) ~= nil, out)
		assert_true(out:find("901 easy", 1, true) ~= nil, "the good level is still tuned")
		F.rmdir(dir)
	end)

	it("writes the reports where --md and --json say and skips them for a copy by default", function()
		local dir = F.tmpdir()
		quick_levels(dir, { 901, 902 })
		local out, code = tune("--dir " .. dir .. " --n 3 --quiet --md " .. dir .. "/r.md --json " .. dir .. "/r.json")
		assert_eq(code, 0, out)
		assert_true(out:find("report: " .. dir .. "/r.md, " .. dir .. "/r.json", 1, true) ~= nil, out)
		local md = common.read_file(dir .. "/r.md")
		assert_true(md:find("# Подбор ходов ботом", 1, true) ~= nil)
		assert_true(md:find("**Пробный прогон:**", 1, true) ~= nil)
		local data = common.decode(common.read_file(dir .. "/r.json"))
		assert_eq(data.applied, false)
		assert_eq(data.dir, dir)
		assert_eq(#data.levels, 2)
		assert_eq(data.levels[1].id, 901)
		assert_true(#data.levels[1].moves_to_win >= 1 and #data.levels[1].moves_to_win <= 3)
		out = tune("--dir " .. dir .. " --n 3 --quiet")
		assert_true(out:find("report: skipped", 1, true) ~= nil, out)
		out = tune("--dir " .. dir .. " --n 3 --quiet --no-report")
		assert_true(out:find("report:", 1, true) == nil, out)
		-- --write no longer puts a tuning.json next to the levels (all of /content is bundled into the game)
		os.remove(dir .. "/r.md")
		os.remove(dir .. "/r.json")
		out, code = tune("--dir " .. dir .. " --n 3 --force --write --quiet")
		assert_eq(code, 0, out)
		assert_true(out:find("report: skipped", 1, true) ~= nil, out)
		assert_same(common.list_dir(dir), { "level_0901.json", "level_0902.json" })
		F.rmdir(dir)
	end)
end)

describe("tools tune CLI: worker processes and the work directory", function()
	it("--jobs gives the same limits as one process; the work directory is a cache that can grow", function()
		local dir, work = F.tmpdir(), F.tmpdir()
		quick_levels(dir, { 901, 902, 903 })
		local one, c1 = tune("--dir " .. dir .. " --n 4 --no-report --quiet")
		assert_eq(c1, 0, one)
		local two, c2 = tune("--dir " .. dir .. " --n 4 --jobs 2 --work " .. work .. " --no-report --quiet")
		assert_eq(c2, 0, two)
		assert_true(limits(one) ~= "", one)
		assert_eq(limits(two), limits(one))
		assert_eq(#common.list_dir(work, "%.result%.json$"), 3)
		local again = tune("--dir " .. dir .. " --n 4 --jobs 2 --work " .. work .. " --no-report --quiet")
		assert_true(again:find("0 played, 3 from the cache, 0 missing", 1, true) ~= nil, again)
		assert_eq(limits(again), limits(one))
		-- more games: the saved ones are kept, and the answer equals a run from scratch
		local more = tune("--dir " .. dir .. " --n 7 --jobs 2 --work " .. work .. " --no-report --quiet")
		local fresh = tune("--dir " .. dir .. " --n 7 --no-report --quiet")
		assert_true(more:find("3 played, 0 from the cache, 0 missing", 1, true) ~= nil, more)
		assert_eq(limits(more), limits(fresh))
		-- fewer games: served by the first games of the saved result
		local few = tune("--dir " .. dir .. " --n 2 --work " .. work .. " --no-report --quiet")
		assert_true(few:find("0 played, 3 from the cache, 0 missing", 1, true) ~= nil, few)
		F.rmdir(dir)
		F.rmdir(work)
	end)

	it("a worker that dies loses only its own level and the exit code says so", function()
		local dir = F.tmpdir()
		quick_levels(dir, { 901, 902, 903 })
		local fake = dir .. "/fake_vm.sh"
		assert(common.write_file(fake, "#!/bin/sh\ncase \"$*\" in *level_0902*) echo \"worker boom\" >&2; exit 3;; esac\nexec " .. VM .. " \"$@\"\n"))
		os.execute("chmod +x '" .. fake .. "'")
		local out, code = tune("--dir " .. dir .. " --n 3 --jobs 3 --vm " .. fake .. " --no-report")
		assert_eq(code, 1, out)
		assert_true(out:find("did not finish cleanly", 1, true) ~= nil, out)
		assert_true(out:find("no result", 1, true) ~= nil, out)
		assert_true(out:find("901 easy", 1, true) ~= nil and out:find("903 easy", 1, true) ~= nil, out)
		assert_true(out:find("2 played, 0 from the cache, 1 missing", 1, true) ~= nil, out)
		F.rmdir(dir)
	end)

	it("an unknown interpreter for the workers is an error row, not a crash", function()
		local dir = F.tmpdir()
		quick_levels(dir, { 901 })
		local out, code = tune("--dir " .. dir .. " --n 2 --jobs 1 --vm /nonexistent/vm --no-report")
		assert_eq(code, 1, out)
		assert_true(out:find("no result", 1, true) ~= nil, out)
		assert_true(out:find("stack traceback", 1, true) == nil, out)
		F.rmdir(dir)
	end)

	it("limits and games are the same on Lua 5.1 and LuaJIT", function()
		if not (F.have("lua5.1") and F.have("luajit")) then return end
		local dir = F.tmpdir()
		quick_levels(dir, { 901, 902, 903 })
		local data = {}
		for _, vm in ipairs({ "lua5.1", "luajit" }) do
			local out, code = F.sh(vm .. " tools/bot/tune.lua --dir " .. dir .. " --n 4 --quiet --md " .. dir .. "/" .. vm .. ".md --json "
				.. dir .. "/" .. vm .. ".json")
			assert_eq(code, 0, out)
			data[vm] = common.decode(common.read_file(dir .. "/" .. vm .. ".json"))
			for _, lv in ipairs(data[vm].levels) do lv.secs = nil end -- timings differ
		end
		assert_eq(#data["lua5.1"].levels, 3)
		assert_same(data["lua5.1"].levels, data["luajit"].levels)
		F.rmdir(dir)
	end)
end)

describe("tools run CLI", function()
	it("plays several games and prints them as a JSON array", function()
		local dir = F.tmpdir()
		quick_levels(dir, { 901 })
		local out, code = F.sh(VM .. " tools/bot/run.lua 901 --dir " .. dir .. " --games 3 --seed 5 --json --budget 30")
		assert_eq(code, 0, out)
		local recs = common.decode(out)
		assert_eq(#recs, 3)
		assert_eq(recs[1].seed, 5)
		assert_eq(recs[3].seed, 7)
		assert_eq(recs[1].bot_seed, 5)
		assert_eq(recs[1].ending, "won")
		local text = F.sh(VM .. " tools/bot/run.lua 901 --dir " .. dir .. " --seed 5 --bot strong --bot-seed 9")
		assert_true(text:find("bot strong/9", 1, true) ~= nil, text)
		assert_true(text:find("1 game(s)", 1, true) ~= nil, text)
		F.rmdir(dir)
	end)

	it("rejects bad options with exit code 2 and a missing level with 1", function()
		local dir = F.tmpdir()
		quick_levels(dir, { 901 })
		local cases = {
			{ "--budget 3", "--budget" }, { "--budget abc", "--budget" }, { "--seed 0", "--seed" },
			{ "--seed abc", "--seed" }, { "--games 0", "--games" }, { "--bot foo", "--bot" },
			{ "--nonsense 1", "unknown option" }, { "--seed 2147483646 --games 2", "--seed + --games" },
		}
		for _, c in ipairs(cases) do
			local out, code = F.sh(VM .. " tools/bot/run.lua 901 --dir " .. dir .. " " .. c[1])
			assert_eq(code, 2, c[1] .. ": " .. out)
			assert_true(out:find(c[2], 1, true) ~= nil, c[1] .. ": " .. out)
			assert_true(out:find("stack traceback", 1, true) == nil, c[1] .. ": " .. out)
		end
		local out, code = F.sh(VM .. " tools/bot/run.lua 777 --dir " .. dir)
		assert_eq(code, 1, out)
		assert_true(out:find("cannot read", 1, true) ~= nil, out)
		out, code = F.sh(VM .. " tools/bot/run.lua")
		assert_eq(code, 0)
		assert_true(out:find("usage:", 1, true) ~= nil)
		F.rmdir(dir)
	end)
end)

describe("tools CLI: where the repository is", function()
	it("finds core/ and content/levels from the script path, whatever the working directory", function()
		local root = F.capture("pwd"):gsub("%s+$", "")
		local out, code = F.sh("cd /tmp && " .. VM .. " " .. root .. "/tools/levels.lua validate 1")
		assert_eq(code, 0, out)
		assert_true(out:find("1 level(s): 1 ok", 1, true) ~= nil, out)
		out, code = F.sh("cd tools && " .. VM .. " levels.lua validate 1")
		assert_eq(code, 0, out)
		out, code = F.sh("cd tools/bot && " .. VM .. " run.lua 1 --seed 2")
		assert_eq(code, 0, out)
		assert_true(out:find("level 1 seed 2", 1, true) ~= nil, out)
		out, code = F.sh("cd /tmp && " .. VM .. " " .. root .. "/tools/bot/tune.lua --levels 1 --n 2 --no-report --quiet")
		assert_eq(code, 0, out)
		assert_true(out:find("1 levels, 2 games/level", 1, true) ~= nil, out)
	end)
end)

describe("tools levels CLI", function()
	local function levels(args)
		return F.sh(VM .. " tools/levels.lua " .. args)
	end

	local function sample_dir()
		local dir = F.tmpdir()
		F.write_levels(dir, { 1 }, { [1] = { moves = 25 } })
		-- the file name says 2, the level says 3
		assert(common.write_file(dir .. "/level_0002.json", F.level_text({ id = 3, moves = 25 })))
		-- level 3 is fine but has 40 moves (plan: 20-35) and is easy where the saw says easy
		assert(common.write_file(dir .. "/level_0003.json", F.level_text({ id = 3, moves = 40 })))
		return dir
	end

	it("validate: exit codes, plan warnings, --strict and the missing files of a whole directory", function()
		local dir = sample_dir()
		local out, code = levels("validate 1 --dir " .. dir)
		assert_eq(code, 0, out)
		assert_true(out:find("ok   level_0001.json", 1, true) ~= nil, out)
		out, code = levels("validate 2 --dir " .. dir)
		assert_eq(code, 1, out)
		assert_true(out:find("file name says level 2", 1, true) ~= nil, out)
		out, code = levels("validate 3 --dir " .. dir)
		assert_eq(code, 0, out)
		assert_true(out:find("warning: plan: moves 40 outside 20-35", 1, true) ~= nil, out)
		out, code = levels("validate 3 --strict --dir " .. dir)
		assert_eq(code, 1, out)
		out, code = levels("validate 1 3 --strict --dir " .. dir)
		assert_eq(code, 1, out)
		out, code = levels("validate --dir " .. dir)
		assert_true(out:find("warning: plan: level files missing: 4-100", 1, true) ~= nil, out)
		assert_eq(code, 1, "level 2 fails")
		os.remove(dir .. "/level_0002.json")
		out, code = levels("validate --dir " .. dir)
		assert_eq(code, 0, out)
		assert_true(out:find("level files missing: 2, 4-100", 1, true) ~= nil, out)
		out, code = levels("validate --strict --dir " .. dir)
		assert_eq(code, 1, out)
		assert_true(out:find("FAIL plan: level files missing", 1, true) ~= nil, out)
		F.rmdir(dir)
	end)

	it("validate: damaged files fail cleanly, bad arguments are exit code 2", function()
		local dir = F.tmpdir()
		for i, text in ipairs({ "", "{", "[1]", "null", "\"x\"" }) do
			assert(common.write_file(string.format("%s/level_%04d.json", dir, i), text))
		end
		local out, code = levels("validate 1-5 --dir " .. dir)
		assert_eq(code, 1, out)
		assert_true(out:find("5 level(s): 0 ok, 5 failed", 1, true) ~= nil, out)
		assert_true(out:find("stack traceback", 1, true) == nil, out)
		out, code = levels("validate 5-1 --dir " .. dir)
		assert_eq(code, 2, out)
		out, code = levels("validate --bogus")
		assert_eq(code, 2, out)
		out, code = levels("validate --dir " .. dir .. "/absent")
		assert_eq(code, 1, out)
		F.rmdir(dir)
	end)

	it("stats counts the levels and prints JSON that decodes", function()
		local dir = sample_dir()
		local out, code = levels("stats --dir " .. dir)
		assert_eq(code, 0, out)
		assert_true(out:find("levels: 3 (easy 3, medium 0, hard 0, super_hard 0); stars: 3", 1, true) ~= nil, out)
		out, code = levels("stats --json 1 --dir " .. dir)
		assert_eq(code, 0, out)
		local st = common.decode(out)
		assert_eq(st.counts.easy, 1)
		assert_eq(st.stars, 1)
		assert_eq(#st.rows, 1)
		assert(common.write_file(dir .. "/level_0004.json", "{ broken"))
		out, code = levels("stats --dir " .. dir)
		assert_eq(code, 0, out)
		assert_true(out:find("skipped (unreadable)", 1, true) ~= nil, out)
		F.rmdir(dir)
	end)

	it("preview draws the level or the seeded start board and never shows a traceback", function()
		local dir = sample_dir()
		local out, code = levels("preview 1 --dir " .. dir)
		assert_eq(code, 0, out)
		assert_true(out:find("level 1: easy, 7x7, 25 moves", 1, true) ~= nil, out)
		assert_true(out:find("legend:", 1, true) ~= nil, out)
		out, code = levels("preview 1 --seed 3 --dir " .. dir)
		assert_eq(code, 0, out)
		assert_true(out:find("start board, seed 3:", 1, true) ~= nil, out)
		out, code = levels("preview 1 --seed x --dir " .. dir)
		assert_eq(code, 2, out)
		for i, text in ipairs({ "null", "[1]", "{\"id\": 9}", "{\"size\": [7, 7], \"cells\": [1]}", "{ broken" }) do
			assert(common.write_file(string.format("%s/level_%04d.json", dir, 10 + i), text))
			out, code = levels("preview " .. (10 + i) .. " --dir " .. dir)
			assert_eq(code, 1, text .. ": " .. out)
			assert_true(out:find("stack traceback", 1, true) == nil, text .. ": " .. out)
		end
		out, code = levels("preview 99 --dir " .. dir)
		assert_eq(code, 1, out)
		out, code = levels("preview")
		assert_eq(code, 1, out)
		F.rmdir(dir)
	end)
end)
