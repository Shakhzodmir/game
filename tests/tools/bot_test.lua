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
