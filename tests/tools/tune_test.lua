-- Move tuner math, corridor choice, reports (tools/bot/tune.lua).

local common = require("tools.bot.common")
local Tune = require("tools.bot.tune")

-- Games from a list of moves_to_win (false = never won). Winners' remaining
-- goals fall linearly to 0; losers keep `rem_at_end` after every move.
local function games_of(list, rem_at_end, len)
	local out = {}
	for i, m in ipairs(list) do
		local r = {}
		if m then
			for k = 1, m do r[k] = 1 - k / m end
		else
			for k = 1, len or 60 do r[k] = rem_at_end or 0.5 end
		end
		out[i] = { m = m or nil, r = r }
	end
	return out
end

-- n games whose moves_to_win are base + (i - 1) * step.
local function ladder(n, base, step)
	local l = {}
	for i = 1, n do l[i] = base + (i - 1) * step end
	return l
end

describe("tools tune: win-rate math", function()
	it("win rate for limit M is the share of games with moves_to_win <= M", function()
		local g = games_of({ 10, 12, 12, 20, false })
		assert_eq(Tune.win_rate(g, 9), 0)
		assert_eq(Tune.win_rate(g, 10), 0.2)
		assert_eq(Tune.win_rate(g, 12), 0.6)
		assert_eq(Tune.win_rate(g, 19), 0.6)
		assert_eq(Tune.win_rate(g, 20), 0.8)
		assert_eq(Tune.win_rate(g, 200), 0.8, "a game that never won is a loss for every M")
		assert_eq(Tune.win_rate({}, 10), 0)
	end)

	it("near-miss share counts losses with <= 20% of the goals left after M moves", function()
		local g = {
			{ m = 8, r = { 0.5, 0 } },                    -- winner at M = 10
			{ m = 30, r = { 0.9, 0.5, 0.3, 0.15 } },     -- loss: 4 moves recorded, last 0.15 -> near
			{ r = { 0.9, 0.8, 0.5 } },                  -- loss: last 0.5 -> not near
			{ m = 12, r = { 0.6, 0.4, 0.3, 0.25, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.1, 0 } }, -- loss at 10: r[10] = 0.2 -> near
		}
		local share, losses = Tune.near_miss(g, 10)
		assert_eq(losses, 3)
		assert_near(share, 2 / 3, 1e-9)
		local s2, l2 = Tune.near_miss(g, 30)
		assert_eq(l2, 1)
		assert_eq(s2, 0)
		local s3, l3 = Tune.near_miss({ { m = 3, r = { 0.1, 0.05, 0 } } }, 10)
		assert_eq(s3, nil)
		assert_eq(l3, 0)
	end)

	it("median moves of the winners at M", function()
		local g = games_of({ 10, 14, 12, 30, false })
		assert_eq(Tune.median_winners(g, 20), 12)
		assert_eq(Tune.median_winners(g, 30), 13)
		assert_eq(Tune.median_winners(g, 5), nil)
	end)
end)

describe("tools tune: corridor choice", function()
	it("hits the centre of each difficulty's corridor", function()
		-- 100 games winning at 10.5, 11, 11.5, ... -> p(M) = (2M - 20) / 100 for 11..60
		local g = games_of(ladder(100, 10.5, 0.5))
		local expect = { easy = 0.90, medium = 0.68, hard = 0.42, super_hard = 0.25 }
		for d, target in pairs(expect) do -- order-independent (independent cases)
			local c = Tune.choose(g, d)
			assert_near(c.p, target, 0.011, d)
			assert_true(c.p >= common.CORRIDOR[d].lo and c.p <= common.CORRIDOR[d].hi, d .. " inside the corridor")
			assert_near(c.attempts, 1 / c.p, 1e-9)
		end
		assert_eq(Tune.choose(g, "easy").M, 55)
		assert_eq(Tune.choose(g, "medium").M, 44)
		assert_eq(Tune.choose(g, "hard").M, 31)
		-- 25% lies between p(22) = 24% and p(23) = 26%: a tie goes to the side above
		assert_eq(Tune.choose(g, "super_hard").M, 23)
	end)

	it("takes the low end of a plateau above the target and the high end below it", function()
		-- medium (68%): p = 0.5 for M in 10..19, 0.9 from 20 -> |0.5-0.68| = 0.18 < 0.22 -> below plateau, M = 19
		local list = {}
		for i = 1, 50 do list[i] = 10 end
		for i = 51, 90 do list[i] = 20 end
		for i = 91, 100 do list[i] = false end
		local c = Tune.choose(games_of(list, 0.1), "medium")
		assert_eq(c.M, 19)
		assert_eq(c.p, 0.5)
		assert_true(#c.flags >= 1)
		assert_eq(c.flags[1], "off_corridor")
		-- easy (90%): p = 0.9 from M = 20 on -> the first M of the plateau
		local c2 = Tune.choose(games_of(list, 0.1), "easy")
		assert_eq(c2.M, 20)
		assert_eq(c2.p, 0.9)
		assert_same(c2.flags, {})
		-- a tie between the two sides goes to the side at or above the target
		local tie = {}
		for i = 1, 60 do tie[i] = 25 end
		for i = 61, 76 do tie[i] = 30 end
		for i = 77, 100 do tie[i] = false end -- p = 0.60 (M 25..29), 0.76 (M >= 30); target 0.68
		assert_eq(Tune.choose(games_of(tie), "medium").M, 30)
		-- a plateau below the target that runs to 60: extra moves never helped
		local flat = {}
		for i = 1, 40 do flat[i] = 25 end
		for i = 41, 100 do flat[i] = false end
		assert_eq(Tune.choose(games_of(flat, 0.1), "hard").M, 25)
	end)

	it("clamps to 5..60 and flags unreachable corridors", function()
		local hard = Tune.choose(games_of(ladder(100, 40, 1)), "easy") -- p(60) = 0.21
		assert_eq(hard.M, 60)
		assert_eq(hard.flags[1], "too_hard")
		assert_near(hard.p60, 0.21, 1e-9)
		local easy = Tune.choose(games_of(ladder(100, 2, 0)), "hard")  -- everyone wins in 2 moves
		assert_eq(easy.M, 5)
		assert_eq(easy.p, 1)
		assert_eq(easy.flags[1], "too_easy")
		assert_eq(easy.flags[2], "outside_band")
		local never = Tune.choose(games_of({ false, false, false }), "medium")
		assert_eq(never.M, 60)
		assert_eq(never.p, 0)
		assert_eq(never.attempts, nil)
		assert_eq(never.flags[1], "too_hard")
	end)

	it("flags M outside the plan's 20-35 band and few near misses", function()
		local c = Tune.choose(games_of(ladder(100, 10.5, 0.5)), "super_hard")
		assert_eq(c.M, 23)
		for _, f in ipairs(c.flags) do assert_true(f ~= "outside_band" and f ~= "off_corridor", f) end
		local e = Tune.choose(games_of(ladder(100, 10.5, 0.5)), "easy")
		assert_eq(e.flags[1], "outside_band")
		-- losers with half the goals left -> near-miss 0%
		local list = {}
		for i = 1, 40 do list[i] = 25 end
		for i = 41, 100 do list[i] = false end
		local h = Tune.choose(games_of(list, 0.5), "hard")
		assert_eq(h.M, 25)
		assert_eq(h.near_miss, 0)
		assert_eq(h.flags[#h.flags], "near_miss_low")
		-- the same losers ending at 10% left -> all near misses, no flag
		local h2 = Tune.choose(games_of(list, 0.1), "hard")
		assert_eq(h2.near_miss, 1)
		assert_same(h2.flags, {})
	end)

	it("reports the win rate of the current move limit", function()
		local c = Tune.choose(games_of(ladder(100, 10.5, 0.5)), "medium", 30)
		assert_near(c.p_before, 0.40, 1e-9)
	end)
end)

describe("tools tune: jobs and reports", function()
	it("splits levels into disjoint, complete subsets", function()
		local files = common.level_files("content/levels")
		if #files < 3 then return end
		local parts = Tune.partition(files, 3)
		local seen, n = {}, 0
		for _, p in ipairs(parts) do
			assert_true(#p >= 1)
			for _, f in ipairs(p) do
				assert_false(seen[f], "each level once")
				seen[f] = true
				n = n + 1
			end
		end
		assert_eq(n, #files)
	end)

	it("writes a Russian table and a machine-readable JSON", function()
		local list = {}
		for i = 1, 100 do list[i] = (i <= 70) and (15 + i % 10) or false end
		local lv = { id = 7, file = "content/levels/level_0007.json", difficulty = "medium", moves = 26,
			n = 100, secs = 12.5, evals = 1000, games = games_of(list, 0.1) }
		local rows = Tune.evaluate({ lv, { file = "content/levels/level_0099.json", error = "2.1.1 moves: 5..60 required" } })
		assert_eq(#rows, 2)
		assert_eq(rows[1].id, 7)
		local meta = { bot = "greedy", n = 100, budget = 120, jobs = 3, vm = "luajit", wall = 10, applied = false,
			projection = Tune.projection(rows, 100, 300, 3), sh_assumed = true }
		local md = Tune.report_md(rows, meta)
		assert_true(md:find("| id | сложность | ходы было → стало |", 1, true) ~= nil)
		assert_true(md:find("| 7 | medium | 26 → " .. rows[1].M .. " |", 1, true) ~= nil)
		assert_true(md:find("ошибка уровня", 1, true) ~= nil)
		assert_true(md:find("Пробный прогон", 1, true) ~= nil)
		local data = common.decode(Tune.report_json(rows, meta))
		assert_eq(data.levels[1].moves_after, rows[1].M)
		assert_eq(data.levels[1].moves_before, 26)
		assert_eq(#data.levels[1].moves_to_win, 70)
		assert_eq(data.levels[1].no_win, 30)
		assert_eq(data.levels[2].flags[1], "invalid")
		assert_eq(data.applied, false)
	end)

	it("projects the time of a full run from seconds per game", function()
		local rows = {
			{ difficulty = "easy", secs = 10, n = 100 },   -- 0.1 s/game
			{ difficulty = "hard", secs = 40, n = 100 },   -- 0.4 s/game
		}
		local p = Tune.projection(rows, 100, 300, 3)
		assert_near(p.spg.medium, 0.1, 1e-9)
		assert_near(p.spg.super_hard, 0.6, 1e-9)
		-- 52*0.1 + 27*0.1 + 16*0.4 + 5*0.6 = 17.3 s per game-set, x300
		assert_near(p.cpu, 17.3 * 300, 1e-6)
		assert_near(p.wall, 17.3 * 100, 1e-6)
	end)

	it("plays a level end to end in one process", function()
		local F = require("tests.tools.fixture")
		local e = F.entry({ goals = { { type = "collect", color = "red", count = 15 } } })
		local res = Tune.run_level(e, { n = 3, budget = 60 })
		assert_eq(#res.games, 3)
		local rows = Tune.evaluate({ res })
		assert_true(rows[1].M >= 5 and rows[1].M <= 60)
		assert_eq(rows[1].n, 3)
	end)
end)

-- Result cache, extension by seeds, safe --write, endings ------------------------------

local F = require("tests.tools.fixture")

local function quick_goal()
	return { goals = { { type = "collect", color = "red", count = 6 } } }
end

-- Games of a result without the timing fields (those differ between runs).
local function games_of_result(res)
	return common.decode(common.encode(res.games))
end

describe("tools tune: the result cache", function()
	it("keys results by the level text without moves, the bot, the budget and the code", function()
		local text = F.level_text({ moves = 20 })
		local run = { bot = "greedy", budget = 120, n = 300, code = "abc" }
		local key = Tune.run_key(text, run)
		assert_eq(Tune.run_key(F.level_text({ moves = 31 }), run), key, "the move limit is not part of the key")
		assert_eq(Tune.run_key(text, { bot = "greedy", budget = 120, n = 50, code = "abc" }), key, "N is not part of the key")
		assert_true(Tune.run_key(text, { bot = "strong", budget = 120, code = "abc" }) ~= key)
		assert_true(Tune.run_key(text, { bot = "greedy", budget = 100, code = "abc" }) ~= key)
		assert_true(Tune.run_key(text, { bot = "greedy", budget = 120, code = "abd" }) ~= key)
		assert_true(Tune.run_key(F.level_text({ moves = 20, difficulty = "hard" }), run) ~= key)
		assert_eq(Tune.run_key(text, {}), Tune.run_key(text, { bot = "greedy", budget = Tune.DEFAULT_BUDGET }), "defaults")
	end)

	it("fingerprints the sources the games depend on", function()
		local a = Tune.code_fingerprint()
		assert_true(type(a) == "string" and #a == 16, tostring(a))
		assert_eq(Tune.code_fingerprint(), a)
	end)

	it("saves and loads a result, and ignores other keys and damaged files", function()
		local work = F.tmpdir()
		local res = { id = 1, file = "x/level_0001.json", n = 2, secs = 1.5, evals = 10,
			games = { { m = 3, r = { 0.5, 0 }, e = "won", t = 120, sp = 1 }, { r = {}, e = "budget", sp = 0 } } }
		assert(Tune.save_result(work, "x/level_0001.json", "k1", res))
		assert_same(Tune.load_result(work, "y/level_0001.json", "k1"), res)
		assert_eq(Tune.load_result(work, "x/level_0001.json", "k2"), nil)
		assert_eq(Tune.load_result(work, "x/level_0002.json", "k1"), nil)
		-- a failure is a result too
		assert(Tune.save_result(work, "x/level_0003.json", "k1", { file = "x/level_0003.json", error = "boom", n = 5 }))
		assert_eq(Tune.load_result(work, "x/level_0003.json", "k1").error, "boom")
		-- damaged or foreign content is not a result
		assert(common.write_file(Tune.slot_path(work, "x/level_0004.json"), "{ not json"))
		assert_eq(Tune.load_result(work, "x/level_0004.json", "k1"), nil)
		assert(common.write_file(Tune.slot_path(work, "x/level_0005.json"), common.encode({ key = "k1", level = { id = 5 } })))
		assert_eq(Tune.load_result(work, "x/level_0005.json", "k1"), nil)
		F.rmdir(work)
	end)

	it("cuts a saved result to its first games and reuses failures only when they still apply", function()
		local res = { n = 4, games = { { m = 1 }, { m = 2 }, { m = 3 }, { m = 4 } }, secs = 8, evals = 100 }
		assert_true(Tune.fit(res, 4) == res)
		local cut = Tune.fit(res, 2)
		assert_eq(#cut.games, 2)
		assert_eq(cut.n, 2)
		assert_eq(cut.secs, 4)
		assert_eq(cut.evals, 50)
		assert_eq(#res.games, 4, "the saved result is not changed")
		assert_eq(Tune.fit(res, 5), nil)
		assert_eq(Tune.reuse(nil, 3), nil)
		assert_true(Tune.reuse(res, 3) ~= nil)
		assert_eq(Tune.reuse(res, 9), nil)
		local failed = { error = "game error: seed 17", n = 100 }
		assert_true(Tune.reuse(failed, 100) == failed)
		assert_true(Tune.reuse(failed, 300) == failed)
		assert_eq(Tune.reuse(failed, 50), nil, "seed 17 may not be among the first 50")
		local invalid = { error = "2.1.1 moves" }
		assert_true(Tune.reuse(invalid, 5) == invalid)
	end)

	it("extending a result by seeds gives the games of a run from scratch", function()
		local e = F.entry(quick_goal())
		local three = Tune.run_level(e, { n = 3, budget = 60 })
		local five = Tune.run_level(e, { n = 5, budget = 60, base = three })
		local scratch = Tune.run_level(e, { n = 5, budget = 60 })
		assert_eq(#five.games, 5)
		assert_same(games_of_result(five), games_of_result(scratch))
		assert_same(games_of_result({ games = { unpack(five.games, 1, 3) } }), games_of_result(three))
		assert_true(five.secs >= three.secs, "the seconds of the base are kept")
		assert_eq(five.evals, scratch.evals)
	end)

	it("run_files reuses, extends and cuts the work directory's results", function()
		local dir, work = F.tmpdir(), F.tmpdir()
		local files = F.write_levels(dir, { 901, 902 }, { [902] = quick_goal() })
		local function run(n, extra)
			local r = { n = n, budget = 60, bot = "greedy", work = work, code = "t" }
			for k, v in pairs(extra or {}) do r[k] = v end
			return Tune.run_files(files, r)
		end
		local first = run(2)
		assert_eq(#first, 2)
		assert_eq(first[1].cached, nil)
		assert_eq(#first[1].games, 2)
		assert_eq(#common.list_dir(work, "%.result%.json$"), 2)
		local again = run(2)
		assert_true(again[1].cached and again[2].cached)
		assert_same(games_of_result(again[1]), games_of_result(first[1]))
		local more = run(4)
		assert_eq(more[1].cached, nil)
		assert_eq(#more[1].games, 4)
		assert_same(games_of_result({ games = { unpack(more[1].games, 1, 2) } }), games_of_result(first[1]))
		local fewer = run(1)
		assert_true(fewer[1].cached)
		assert_eq(#fewer[1].games, 1)
		assert_eq(#run(4)[1].games, 4)
		assert_true(run(4)[1].cached, "the larger result is still saved after a smaller request")
		assert_eq(run(4, { fresh = true })[1].cached, nil)
		-- another bot is another key: nothing is reused
		assert_eq(run(2, { bot = "strong" })[1].cached, nil)
		F.rmdir(dir)
		F.rmdir(work)
	end)

	it("collect keeps the order, reports unreadable and invalid files and counts the cache", function()
		local dir, work = F.tmpdir(), F.tmpdir()
		local files = F.write_levels(dir, { 901, 902 }, { [901] = quick_goal(), [902] = quick_goal() })
		assert(common.write_file(dir .. "/level_0903.json", "{ not a level"))
		local list = { files[2], dir .. "/level_0903.json", dir .. "/level_0904.json", files[1] }
		local run = { n = 2, budget = 60, bot = "greedy", work = work, code = "t", jobs = 1 }
		local res, counts = Tune.collect(list, run)
		assert_eq(#res, 4)
		assert_eq(res[1].id, 902)
		assert_eq(#res[1].games, 2)
		assert_true(res[2].error:find("json", 1, true) ~= nil, res[2].error)
		assert_true(res[3].error:find("cannot read", 1, true) ~= nil, res[3].error)
		assert_eq(res[4].id, 901)
		assert_eq(counts.cached, 0)
		local res2, counts2 = Tune.collect(list, run)
		assert_eq(counts2.cached, 3, "two levels and the failure of the third")
		assert_true(res2[1].cached and res2[4].cached)
		assert_eq(res2[2].error, res[2].error)
		-- the move limit changed since: the cache serves the games, the row shows the new limit
		assert(common.write_file(files[1], F.level_text({ id = 901, moves = 41, goals = quick_goal().goals })))
		local res3 = Tune.collect({ files[1] }, run)
		assert_true(res3[1].cached)
		assert_eq(res3[1].moves, 41)
		F.rmdir(dir)
		F.rmdir(work)
	end)
end)

describe("tools tune: rows, flags and reports", function()
	local function lv(list_of_endings)
		local games = {}
		for i, e in ipairs(list_of_endings) do
			if e == "won" then
				games[i] = { m = 10 + i, r = { 0.5, 0 }, e = "won", t = 100, sp = 2 }
			else
				games[i] = { r = { 0.5 }, e = e, sp = 0 }
			end
		end
		return { id = 5, file = "content/levels/level_0005.json", difficulty = "easy", moves = 20, n = #games,
			secs = 2, evals = 10, games = games, sig = "abc" }
	end

	it("counts how the games ended and flags dead ends and hangs", function()
		local ok = Tune.evaluate({ lv({ "won", "won", "budget" }) })[1]
		assert_same(ok.endings, { won = 2, budget = 1, stuck = 0, timeout = 0 })
		assert_eq(ok.no_win, 1)
		assert_eq(ok.sig, "abc")
		for _, f in ipairs(ok.flags) do assert_true(f ~= "stuck_games", f) end
		local stuck = Tune.evaluate({ lv({ "won", "stuck", "won" }) })[1]
		assert_eq(stuck.endings.stuck, 1)
		assert_eq(stuck.flags[#stuck.flags], "stuck_games")
		local hung = Tune.evaluate({ lv({ "won", "timeout" }) })[1]
		assert_eq(hung.flags[#hung.flags], "stuck_games")
	end)

	it("an empty or failed level becomes an invalid row", function()
		local rows = Tune.evaluate({
			{ id = 6, file = "b.json", difficulty = "easy", moves = 20, games = {} },
			{ id = 7, file = "a.json", error = "game error: seed 3" },
		})
		assert_eq(rows[1].id, 6)
		assert_eq(rows[1].flags[1], "invalid")
		assert_eq(rows[1].error, "no games were played")
		assert_eq(rows[2].error, "game error: seed 3")
	end)

	it("the JSON report leaves the rows alone and copes with a missing previous win rate", function()
		local rows = Tune.evaluate({ lv({ "won", "won", "budget", "won" }) })
		rows[1].p_before = nil
		local meta = { bot = "greedy", n = 4, budget = 120, jobs = 1, vm = "luajit", wall = 1, applied = false, dir = "/tmp/copy" }
		local data = common.decode(Tune.report_json(rows, meta))
		assert_eq(data.levels[1].win_rate_before, nil)
		assert_eq(data.levels[1].endings.won, 3)
		assert_eq(data.dir, "/tmp/copy")
		assert_eq(rows[1].flags.__array, nil)
		assert_eq(rows[1].mtw.__array, nil)
		local md = Tune.report_md(rows, meta)
		assert_true(md:find("каталог `/tmp/copy`", 1, true) ~= nil)
	end)

	it("the Russian report names the dead-end flag", function()
		local rows = Tune.evaluate({ lv({ "won", "stuck", "won", "won" }) })
		local md = Tune.report_md(rows, { bot = "greedy", n = 4, budget = 120, jobs = 1, vm = "luajit", wall = 1, applied = true })
		assert_true(md:find("партии в тупике или зависли", 1, true) ~= nil)
		assert_true(md:find("Ходы записаны в файлы уровней", 1, true) ~= nil)
	end)

	it("splits a mixed set so that no heavy level shares a part with another heavy one", function()
		local dir = F.tmpdir()
		local specs = { { 901, "super_hard", 9, 11 }, { 902, "super_hard", 9, 11 }, { 903, "easy", 7, 7 }, { 904, "easy", 7, 7 },
			{ 905, "hard", 9, 10 }, { 906, "easy", 8, 8 } }
		local files = {}
		for _, s in ipairs(specs) do
			local cells = {}
			for y = 1, s[4] do cells[y] = string.rep("#", s[3]) end
			local path = string.format("%s/level_%04d.json", dir, s[1])
			assert(common.write_file(path, F.level_text({ id = s[1], difficulty = s[2], size = { s[3], s[4] }, cells = cells })))
			files[#files + 1] = path
		end
		local parts = Tune.partition(files, 2)
		local function load(part)
			local sum = 0
			for _, f in ipairs(part) do
				for _, s in ipairs(specs) do
					if f:find(string.format("level_%04d", s[1]), 1, true) then
						sum = sum + ({ easy = 1, medium = 1.5, hard = 2, super_hard = 3 })[s[2]] * s[3] * s[4]
					end
				end
			end
			return sum
		end
		local a, b = load(parts[1]), load(parts[2])
		assert_true(math.max(a, b) / math.min(a, b) < 1.2, a .. " vs " .. b)
		-- three parts for three heavy levels: one each
		local parts3 = Tune.partition({ files[1], files[2], files[5] }, 3)
		assert_eq(#parts3[1] + #parts3[2] + #parts3[3], 3)
		assert_eq(#parts3[1], 1)
		assert_eq(#parts3[2], 1)
		F.rmdir(dir)
	end)
end)

describe("tools tune --write: stale files", function()
	it("skips a file edited after the games were played, but not a changed move limit", function()
		local dir = F.tmpdir()
		local path = dir .. "/level_0901.json"
		local original = F.level_text({ moves = 20 })
		local sig = common.level_sig(original)
		assert(common.write_file(path, F.level_text({ moves = 20, difficulty = "medium" })))
		local before = common.read_file(path)
		local changed, skipped = Tune.write_moves({ { file = path, M = 31, sig = sig } })
		assert_eq(changed, 0)
		assert_eq(skipped, 1)
		assert_eq(common.read_file(path), before)
		-- somebody else tuned the limit meanwhile: still the same level
		assert(common.write_file(path, F.level_text({ moves = 22 })))
		changed, skipped = Tune.write_moves({ { file = path, M = 31, sig = sig } })
		assert_eq(changed, 1)
		assert_eq(skipped, 0)
		assert_eq(common.find_moves(common.read_file(path)), 31)
		F.rmdir(dir)
	end)

	it("never writes a limit the schema refuses or into a file without one moves key", function()
		local dir = F.tmpdir()
		local path = dir .. "/level_0901.json"
		assert(common.write_file(path, F.level_text({ moves = 20 })))
		local before = common.read_file(path)
		local changed, skipped = Tune.write_moves({ { file = path, M = 3 } })
		assert_eq(changed, 0)
		assert_eq(skipped, 1)
		assert_eq(common.read_file(path), before)
		local odd = dir .. "/level_0902.json"
		assert(common.write_file(odd, "{}"))
		changed, skipped = Tune.write_moves({ { file = odd, M = 30 }, { file = dir .. "/absent.json", M = 30 } })
		assert_eq(changed, 0)
		assert_eq(skipped, 2)
		assert_eq(common.read_file(odd), "{}")
		assert_same(common.list_dir(dir), { "level_0901.json", "level_0902.json" })
		F.rmdir(dir)
	end)
end)

describe("tools tune: the choice of M on random distributions", function()
	-- Properties that hold for any set of games (README, "Как считается", 3-4):
	-- M is a minimiser of |p - target|, a plateau at or above the target gives
	-- its smallest M, and the flags follow from the curve.
	it("picks a nearest limit, the low end of a plateau above the target, and consistent flags", function()
		local r = common.rng(2024)
		local checked = 0
		for _ = 1, 60 do
			local n = 20 + common.rng_int(r, 281)
			local spread = 5 + common.rng_int(r, 80)
			local shift = common.rng_int(r, 40)
			local list = {}
			for i = 1, n do
				if common.rng_int(r, 12) == 1 then
					list[i] = false
				else
					list[i] = shift + common.rng_int(r, spread)
				end
			end
			local games = games_of(list, 0.1)
			for _, d in ipairs({ "easy", "medium", "hard", "super_hard" }) do
				local c = Tune.choose(games, d, 25)
				local cor = common.CORRIDOR[d]
				local best = math.abs(c.p - cor.target)
				assert_eq(c.p, Tune.win_rate(games, c.M))
				assert_true(c.M >= 5 and c.M <= 60)
				for M = 5, 60 do
					assert_true(math.abs(Tune.win_rate(games, M) - cor.target) >= best - 1e-12, d .. " M " .. M .. " is nearer than " .. c.M)
				end
				if c.p >= cor.target - 1e-12 and c.M > 5 then
					assert_true(Tune.win_rate(games, c.M - 1) ~= c.p, d .. ": the plateau above the target starts at M")
				end
				if c.p < cor.target - 1e-12 and c.M < 60 then
					local runs_to_60 = Tune.win_rate(games, 60) == c.p and c.p >= cor.lo - 1e-12
					if not runs_to_60 then
						assert_true(Tune.win_rate(games, c.M + 1) ~= c.p, d .. ": the plateau below the target ends at M")
					end
				end
				local has = {}
				for _, f in ipairs(c.flags) do has[f] = true end
				assert_eq(has.too_hard == true, c.p60 < cor.lo - 1e-12)
				assert_eq(has.too_easy == true, (not has.too_hard) and c.p5 > cor.hi + 1e-12)
				assert_eq(has.outside_band == true, c.M < 20 or c.M > 35)
				assert_eq(c.p_before, Tune.win_rate(games, 25))
				assert_eq(c.attempts ~= nil, c.p > 0)
				checked = checked + 1
			end
		end
		assert_eq(checked, 240)
	end)
end)
