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
end)
