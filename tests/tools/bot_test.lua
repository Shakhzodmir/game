-- Bots and the game runner (tools/bot/bot.lua, tools/bot/run.lua).

local common = require("tools.bot.common")
local Bot = require("tools.bot.bot")
local Run = require("tools.bot.run")
local F = require("tests.tools.fixture")
local core = require("core.game")

local function fingerprint(r)
	return common.encode(r)
end

describe("tools bot", function()
	it("plays the same game for the same (level, seed, bot seed)", function()
		local e = F.entry({ goals = { { type = "collect", color = "red", count = 30 } } })
		for _, kind in ipairs({ "greedy", "strong" }) do
			local a = Run.play(e, { seed = 4, bot = kind, budget = 15 })
			local b = Run.play(e, { seed = 4, bot = kind, budget = 15 })
			assert_same(a, b, kind)
			assert_true(#a.remaining >= 1, kind .. " made moves")
		end
	end)

	it("keeps its own random stream: the bot seed changes choices, not the board", function()
		local e = F.entry({ goals = { { type = "collect", color = "red", count = 60 } } })
		local differ = false
		local base = Run.play(e, { seed = 2, bot_seed = 1, budget = 12 })
		for bs = 2, 6 do
			local r = Run.play(e, { seed = 2, bot_seed = bs, budget = 12 })
			if fingerprint(r.remaining) ~= fingerprint(base.remaining) then differ = true end
		end
		assert_true(differ, "some bot seed makes a different choice")
		-- the start board depends on the game seed only
		local g1 = core.new(e.level, { seed = 2 })
		local g2 = core.new(e.level, { seed = 2 })
		assert_eq(g1:hash(), g2:hash())
	end)

	it("gives the same results on Lua 5.1 and LuaJIT", function()
		local vms = {}
		for _, vm in ipairs({ "lua5.1", "luajit" }) do
			if F.have(vm) then vms[#vms + 1] = vm end
		end
		if #vms < 2 then return end -- one VM only: nothing to compare
		local dir = F.tmpdir()
		local path = dir .. "/level_0901.json"
		assert(common.write_file(path, F.level_text({ goals = { { type = "collect", color = "red", count = 25 } } })))
		local outs = {}
		for _, vm in ipairs(vms) do
			for _, kind in ipairs({ "greedy", "strong" }) do
				outs[#outs + 1] = { vm = vm, kind = kind, text = F.capture(vm .. " tools/bot/run.lua " .. path
					.. " --seed 3 --bot-seed 5 --budget 14 --json --bot " .. kind) }
			end
		end
		F.rmdir(dir)
		for k = 1, 2 do
			assert_true(outs[k].text:find('"moves_to_win"', 1, true) ~= nil or outs[k].text:find('"ending"', 1, true) ~= nil,
				"json output: " .. outs[k].text:sub(1, 200))
			assert_eq(outs[k + 2].text, outs[k].text, outs[k].kind .. " on " .. vms[1] .. " vs " .. vms[2])
		end
	end)

	it("records moves_to_win and the first-attempt view of the level's limit", function()
		local e = F.entry({ moves = 5, goals = { { type = "collect", color = "red", count = 30 } } })
		local r = Run.play(e, { seed = 1, budget = 40 })
		assert_eq(r.limit, 5)
		assert_eq(r.ending, "won")
		assert_true(r.moves_to_win >= 1 and r.moves_to_win <= 40)
		assert_eq(#r.remaining, r.moves_to_win)
		assert_eq(r.remaining[#r.remaining], 0)
		assert_eq(r.won, r.moves_to_win <= 5)
		assert_eq(r.moves_used, r.won and r.moves_to_win or 5)
		for k = 2, #r.remaining do
			assert_true(r.remaining[k] <= r.remaining[k - 1] + 1e-9, "goals never grow back")
			assert_true(r.ticks[k] > r.ticks[k - 1], "ticks increase")
		end
		assert_eq(r.timing, "normal")
	end)

	it("reaches past 60 moves with `continue` and stops at the budget", function()
		-- a goal the bot cannot finish in 62 moves
		local e = F.entry({ moves = 10, goals = { { type = "collect", color = "red", count = 900 } } })
		local r = Run.play(e, { seed = 1, budget = 62, turbo = true })
		assert_eq(r.ending, "budget")
		assert_eq(#r.remaining, 62)
		assert_eq(r.moves_to_win, nil)
		assert_false(r.won)
		assert_eq(r.moves_used, 10)
		assert_eq(r.duration, r.ticks[10])
	end)

	it("lists swaps, special swaps and taps as candidates", function()
		local e = F.entry({ slots = { { at = { 3, 3 }, type = "riff", axis = "h" } } })
		local g = core.new(e.level, { seed = 1 })
		local cands = Bot.candidates(g)
		local taps, special_swaps = 0, 0
		for _, c in ipairs(cands) do
			if c.cmd.type == "tap" then
				taps = taps + 1
				assert_same(c.cmd.at, { 4, 4 })
			elseif (c.cmd.from[1] == 4 and c.cmd.from[2] == 4) or (c.cmd.to[1] == 4 and c.cmd.to[2] == 4) then
				special_swaps = special_swaps + 1
			end
		end
		assert_eq(taps, 1)
		assert_true(special_swaps >= 2, "swaps of the riff with its neighbours")
		assert_eq(#cands, #g:moves() + 1)
	end)

	it("strong bot takes a winning move and scores combos", function()
		local e = F.entry({ goals = { { type = "collect", color = "red", count = 3 } } })
		local g = core.new(e.level, { seed = 7 })
		local bot = Bot.new("strong", { seed = 1, goals = e.goals, width = 7 })
		local cmd = bot:choose(g)
		assert_true(g:input(cmd))
		local acc = Bot.new_acc()
		Bot.settle(g, acc)
		assert_true(acc.won, "a 3-red goal is met by the chosen move")
	end)

	it("never lets the lookahead touch the real game", function()
		local e = F.entry()
		local g = core.new(e.level, { seed = 5 })
		local h = g:hash()
		local bot = Bot.new("greedy", { seed = 3, goals = e.goals, width = 7 })
		bot:choose(g)
		assert_eq(g:hash(), h)
		assert_eq(#g:drain_events(), 0)
		assert_true(bot.evals >= #Bot.candidates(g))
	end)

	it("finds special-creating swaps statically", function()
		-- r r . r in a row with a red below the gap -> swap up makes 4 in a row
		local e = F.entry({
			slots = {
				{ at = { 0, 0 }, type = "piece", color = "red" }, { at = { 1, 0 }, type = "piece", color = "red" },
				{ at = { 2, 0 }, type = "piece", color = "blue" }, { at = { 3, 0 }, type = "piece", color = "red" },
				{ at = { 2, 1 }, type = "piece", color = "red" }, { at = { 1, 1 }, type = "piece", color = "green" },
				{ at = { 3, 1 }, type = "piece", color = "green" },
			},
		})
		local g = core.new(e.level, { seed = 1 })
		local cands, map = Bot.candidates(g)
		local hits = Bot.static_specials(g, map, cands)
		local found = false
		for _, h in ipairs(hits) do
			local c = h.cand.cmd
			if c.type == "swap" and h.rank >= 2 and ((c.from[1] == 3 and c.from[2] == 1 and c.to[1] == 3 and c.to[2] == 2)
				or (c.to[1] == 3 and c.to[2] == 1 and c.from[1] == 3 and c.from[2] == 2)) then
				found = true
			end
		end
		assert_true(found, "the swap making r r r r is ranked as a riff")
	end)
end)

describe("tools bot: the documented behaviour", function()
	it("a game with the real limit M is the first M moves of the unlimited game", function()
		-- README: nothing in the core reads moves_left but the out-of-moves check and the
		-- concert, so "won at limit M" is exactly "moves_to_win <= M". Guards the tuner's idea.
		local e = F.entry({ goals = { { type = "collect", color = "red", count = 40 } } })
		for seed = 1, 2 do
			local full = Run.play(e, { seed = seed, budget = 60 })
			assert_eq(full.ending, "won")
			for _, M in ipairs({ 5, 8 }) do
				local lim = Run.play(e, { seed = seed, budget = M })
				assert_eq(lim.moves_to_win ~= nil, full.moves_to_win <= M, "seed " .. seed .. " limit " .. M)
				for k = 1, math.min(M, #lim.remaining) do
					assert_eq(lim.remaining[k], full.remaining[k], "seed " .. seed .. " move " .. k)
					assert_eq(lim.ticks[k], full.ticks[k], "seed " .. seed .. " tick of move " .. k)
				end
			end
		end
	end)

	it("evaluates every candidate once (greedy) and at most three more per branch (strong)", function()
		local e = F.entry({ goals = { { type = "collect", color = "red", count = 40 } } })
		local g = core.new(e.level, { seed = 11 })
		local n = #Bot.candidates(g)
		assert_true(n >= 3)
		local greedy = Bot.new("greedy", { seed = 1, goals = e.goals, width = 7 })
		greedy:choose(g)
		assert_eq(greedy.evals, n)
		local strong = Bot.new("strong", { seed = 1, goals = e.goals, width = 7 })
		local _, info = strong:choose(g)
		assert_true(strong.evals >= n and strong.evals <= n + 9, strong.evals .. " clones for " .. n .. " candidates")
		assert_eq(info.rank, 1, "the strong bot takes its best")
		assert_eq(info.n, n)
	end)

	it("greedy takes its best move about four times in five and sometimes one of the next two", function()
		local e = F.entry({ goals = { { type = "collect", color = "red", count = 40 } } })
		local g = core.new(e.level, { seed = 11 })
		local first, other = 0, 0
		for bot_seed = 1, 40 do
			local bot = Bot.new("greedy", { seed = bot_seed, goals = e.goals, width = 7 })
			local _, info = bot:choose(g)
			assert_true(info.rank >= 1 and info.rank <= 3, "rank " .. info.rank)
			if info.rank == 1 then first = first + 1 else other = other + 1 end
		end
		assert_true(first >= 20, "best move in " .. first .. " of 40")
		assert_true(other >= 1, "never the second or third best")
	end)

	it("weights goals by their share: a goal with fewer units counts more per unit", function()
		local e = F.entry({ goals = { { type = "collect", color = "red", count = 10 }, { type = "collect", color = "blue", count = 30 } } })
		local g = core.new(e.level, { seed = 3 })
		local bot = Bot.new("greedy", { seed = 1, goals = e.goals, width = 7 })
		bot:choose(g) -- sets the weights from the initial goal counts
		-- weight of a unit = SCALE x (mean goal count) / (count of that goal), rounded
		local small = Bot.progress(bot, { 10, 30 }, { 9, 30 })
		local large = Bot.progress(bot, { 10, 30 }, { 10, 29 })
		assert_eq(small, 2000)
		assert_eq(large, 667)
		-- finishing both goals is worth about the same for each (10 x 2000 and 30 x 667)
		assert_eq(Bot.progress(bot, { 10, 30 }, { 0, 0 }), 40010)
		assert_eq(Bot.progress(bot, { 10, 30 }, { 10, 30 }), 0)
	end)

	it("lists swaps first, in the order of game:moves(), then taps; each has its index", function()
		local e = F.entry({ slots = { { at = { 3, 3 }, type = "riff", axis = "h" }, { at = { 0, 0 }, type = "sub" } } })
		local g = core.new(e.level, { seed = 1 })
		local cands = Bot.candidates(g)
		local mv = g:moves()
		for k = 1, #mv do
			assert_eq(cands[k].cmd.type, "swap")
			assert_same(cands[k].cmd.from, mv[k].from)
			assert_same(cands[k].cmd.to, mv[k].to)
		end
		assert_eq(#cands, #mv + 2)
		assert_eq(cands[#mv + 1].cmd.type, "tap")
		assert_eq(cands[#mv + 2].cmd.type, "tap")
		for k = 1, #cands do assert_eq(cands[k].index, k) end
	end)

	it("settle stops at the tick limit and reports it", function()
		local e = F.entry()
		local g = core.new(e.level, { seed = 2 })
		local cands = Bot.candidates(g)
		assert_true(g:input(cands[1].cmd))
		local acc = Bot.new_acc()
		assert_eq(Bot.settle(g, acc, 1), nil, "one tick is not enough to come to rest")
		assert_true(Bot.settle(g, Bot.new_acc(), 5000) ~= nil)
		assert_true(g:is_stable())
	end)

	it("refuses an unknown bot kind and a budget below the schema's minimum", function()
		assert_error(function() Bot.new("clever", {}) end, "unknown kind")
		local e = F.entry()
		assert_error(function() Run.play(e, { budget = 4 }) end, "at least 5")
	end)
end)
