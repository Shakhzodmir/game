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
