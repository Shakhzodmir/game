-- Performance smoke test of the bot runner: prints games per second of the
-- tuner's workload (greedy bot, normal timing, unlimited budget) on this VM.
-- The bound is loose on purpose: it catches hangs and 10x regressions, not
-- noise. Real numbers: `luajit tools/bot/run.lua 25 --games 20`.

local common = require("tools.bot.common")
local Run = require("tools.bot.run")
local F = require("tests.tools.fixture")

describe("tools perf", function()
	it("plays tuner games fast enough and reports games/sec", function()
		common.jit_opts()
		local e = F.entry({ goals = { { type = "collect", color = "red", count = 24 } } })
		Run.play(e, { seed = 99, budget = 60 }) -- warm-up (JIT)
		local t0 = common.clock()
		local games, moves, evals = 0, 0, 0
		for seed = 1, 6 do
			local r = Run.play(e, { seed = seed, budget = 60 })
			games = games + 1
			moves = moves + #r.remaining
			evals = evals + r.evals
		end
		local dt = math.max(common.clock() - t0, 1e-6)
		print(string.format("  perf [%s]: %.1f games/s, %.0f moves/s, %.0f clone evaluations/s (%d games, %.2f s)",
			common.vm_name(), games / dt, moves / dt, evals / dt, games, dt))
		assert_true(games / dt > 0.5, "at least 0.5 games/s")
	end)

	it("prints the cost of a game on a large board (9x11, 5 colours, two goals)", function()
		-- the numbers of tools/README.md's estimate come from such runs on the real levels;
		-- the tuner runs on LuaJIT, so Lua 5.1 skips this (it would take seconds)
		if not jit then return end
		common.jit_opts()
		local cells = {}
		for y = 1, 11 do cells[y] = string.rep("#", 9) end
		local e = F.entry({
			size = { 9, 11 }, cells = cells, difficulty = "hard", moves = 30,
			colors = { "red", "orange", "yellow", "green", "blue" },
			goals = { { type = "collect", color = "red", count = 50 }, { type = "collect", color = "blue", count = 50 } },
		})
		Run.play(e, { seed = 99, budget = 60 }) -- warm-up (JIT)
		local t0 = common.clock()
		local games, moves, evals = 0, 0, 0
		for seed = 1, 4 do
			local r = Run.play(e, { seed = seed, budget = 60 })
			games = games + 1
			moves = moves + #r.remaining
			evals = evals + r.evals
		end
		local dt = math.max(common.clock() - t0, 1e-6)
		print(string.format("  perf large [%s]: %.1f games/s, %.1f moves/game, %.0f clone evaluations/s (%d games, %.2f s)",
			common.vm_name(), games / dt, moves / games, evals / dt, games, dt))
		assert_true(games / dt > 0.2, "at least 0.2 games/s")
	end)
end)
