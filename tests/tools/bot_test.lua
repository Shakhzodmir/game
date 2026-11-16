-- Bots and the game runner (tools/bot/bot.lua, tools/bot/run.lua).

local common = require("tools.bot.common")
local Bot = require("tools.bot.bot")
local Run = require("tools.bot.run")
local F = require("tests.tools.fixture")
local core = require("core.game")
local CH = require("tests.core.helper")

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

	it("wins a small coconut level: both bots bring every coconut down within the level's moves", function()
		local e = F.entry({
			size = { 7, 7 }, moves = 30,
			goals = { { type = "drop", count = 3 } },
			coconut = { total = 3, on_board_max = 2, gap_moves = 2, columns = { 1, 3, 5 } },
			slots = { { at = { 3, 1 }, type = "coconut" } },
		})
		for _, kind in ipairs({ "greedy", "strong" }) do
			local wins = 0
			for seed = 1, 6 do
				local r = Run.play(e, { seed = seed, bot = kind, budget = 60, turbo = true })
				assert_eq(r.ending, "won", kind .. " seed " .. seed)
				if r.won then wins = wins + 1 end
			end
			assert_true(wins >= 5, kind .. " won " .. wins .. " of 6 within 30 moves")
		end
	end)

	it("counts the rows a coconut comes down, and only on a level with a drop goal", function()
		local e = F.entry({
			goals = { { type = "drop", count = 2 } },
			coconut = { total = 2, on_board_max = 2, gap_moves = 0 },
			slots = { { at = { 3, 1 }, type = "coconut" }, { at = { 5, 5 }, type = "coconut" } },
		})
		local g = core.new(e.level, { seed = 3 })
		local bot = Bot.new("greedy", { seed = 1, goals = e.goals, width = 7 })
		local before = Bot.coconuts(bot, g)
		assert_same(before, { { before[1][1], 2 }, { before[2][1], 6 } })
		assert_eq(Bot.lowered(bot, before, g), 0)
		-- white box: the first coconut two rows lower, the second one gone from the board
		local c = g:clone()
		local s = c.s
		local a, b = s.objs[before[1][1]], s.objs[before[2][1]]
		local other = s.objs[s.slot[a.cell + 14]]
		s.slot[a.cell], s.slot[a.cell + 14] = other.id, a.id
		a.cell, other.cell = a.cell + 14, a.cell
		s.slot[b.cell] = 0
		s.objs[b.id] = nil
		assert_eq(Bot.lowered(bot, before, c), 2 + 2, "two rows, and 7 + 1 - 6 for the collected one")
		local plain = Bot.new("greedy", { seed = 1, goals = { { type = "collect", color = "red", count = 5 } }, width = 7 })
		assert_eq(Bot.coconuts(plain, g), nil)
		assert_eq(Bot.lowered(plain, nil, g), 0)
	end)

	-- the portals (core-rules 10.14): a block of 3x4 on the right top with the spawners, a block of 3x7 on the left
	-- that only the portals feed; a coconut enters on the right, dives through a pair at the bottom of the right
	-- block and comes out at the top of the left one, then goes down to the real bottom
	local function portal_level(extra)
		local t = {
			size = { 7, 7 }, moves = 30,
			cells = { "###.###", "###.###", "###.###", "###.###", "###....", "###....", "###...." },
			goals = { { type = "drop", count = 3 } },
			coconut = { total = 3, on_board_max = 2, gap_moves = 2, columns = { 4, 5, 6 } },
			portals = { { ["in"] = { 4, 3 }, out = { 0, 0 } }, { ["in"] = { 5, 3 }, out = { 1, 0 } }, { ["in"] = { 6, 3 }, out = { 2, 0 } } },
		}
		for k, v in pairs(extra or {}) do t[k] = v end
		return F.entry(t)
	end

	it("wins a small portal level with a drop goal: both bots bring the coconuts through the portals to the bottom", function()
		local e = portal_level()
		for _, kind in ipairs({ "greedy", "strong" }) do
			local wins = 0
			for seed = 1, 6 do
				local r = Run.play(e, { seed = seed, bot = kind, budget = 60, turbo = true })
				assert_eq(r.ending, "won", kind .. " seed " .. seed)
				if r.won then wins = wins + 1 end
			end
			assert_true(wins >= 5, kind .. " won " .. wins .. " of 6 within 30 moves")
		end
		local a = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		local b = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		assert_same({ a.won, a.moves_used, a.score }, { b.won, b.moves_used, b.score })
	end)

	it("measures the way of a coconut along its route through the portals, not by its row", function()
		local e = portal_level({ slots = { { at = { 4, 3 }, type = "coconut" } } })
		local g = core.new(e.level, { seed = 3 })
		local bot = Bot.new("greedy", { seed = 1, goals = e.goals, width = 7 })
		local route = Bot.route(bot, g)
		-- cells left to the real bottom: the entrance (5,4) is 1 hop + 6 cells away, the exit (1,1) 6 cells, the
		-- top of the right block 3 + 7, the bottom of the left block 0
		assert_same({ route[3 * 7 + 5], route[1], route[5], route[6 * 7 + 1] }, { 7, 6, 10, 0 })
		local before = Bot.coconuts(bot, g)
		assert_same(before, { { before[1][1], -7 } })
		assert_eq(Bot.lowered(bot, before, g), 0)
		-- white box: the coconut came out of the exit (1,1): higher on the screen, one step further on its way
		local c = g:clone()
		local s = c.s
		local a = s.objs[before[1][1]]
		local other = s.objs[s.slot[1]]
		s.slot[a.cell], s.slot[1] = other.id, a.id
		other.cell, a.cell = a.cell, 1
		assert_eq(Bot.lowered(bot, before, c), 1)
		-- ... and gone from the board: the whole route and one more
		s.slot[1] = 0
		s.objs[a.id] = nil
		assert_eq(Bot.lowered(bot, before, c), 8)
		-- a level without portals looks once and measures rows
		local plain = F.entry({ goals = { { type = "drop", count = 1 } }, coconut = { total = 1, on_board_max = 1, gap_moves = 0 } })
		local pb = Bot.new("greedy", { seed = 1, goals = plain.goals, width = 7 })
		assert_eq(Bot.route(pb, core.new(plain.level, { seed = 3 })), false)
		assert_eq(pb.ways, false)
	end)

	local function chain_overlay(list)
		local o = {}
		for k, c in ipairs(list) do o[k] = { at = { c[1], c[2] }, type = "chain", hp = c[3] } end
		return o
	end

	it("wins a small chain level: both bots break every chain within the level's moves", function()
		local e = F.entry({
			size = { 7, 7 }, moves = 30,
			goals = { { type = "chains", count = 8 } },
			overlay = chain_overlay({ { 1, 1, 2 }, { 5, 1, 2 }, { 3, 3, 1 }, { 1, 5, 1 }, { 5, 5, 1 }, { 3, 5, 1 }, { 0, 3, 1 }, { 6, 3, 2 } }),
		})
		for _, kind in ipairs({ "greedy", "strong" }) do
			local wins = 0
			for seed = 1, 6 do
				local r = Run.play(e, { seed = seed, bot = kind, budget = 60, turbo = true })
				assert_eq(r.ending, "won", kind .. " seed " .. seed)
				if r.won then wins = wins + 1 end
			end
			assert_true(wins >= 5, kind .. " won " .. wins .. " of 6 within 30 moves")
		end
	end)

	it("counts the links a move takes off the chains, only with a chains goal, and never moves a chained piece", function()
		local e = F.entry({
			goals = { { type = "chains", count = 3 } },
			overlay = chain_overlay({ { 1, 1, 2 }, { 5, 1, 1 }, { 3, 3, 2 } }),
		})
		local g = core.new(e.level, { seed = 3 })
		local bot = Bot.new("greedy", { seed = 1, goals = e.goals, width = 7 })
		assert_eq(Bot.chain_hp(bot, g), 5)
		local c = g:clone()
		c.s.objs[c.s.slot[7 + 2]].chain = 1 -- white box: a link of the chain in (2, 2) is gone
		assert_eq(Bot.chain_hp(bot, c), 4)
		local plain = Bot.new("greedy", { seed = 1, goals = { { type = "collect", color = "red", count = 5 } }, width = 7 })
		assert_eq(Bot.chain_hp(plain, g), nil)
		local chained = { ["2,2"] = true, ["6,2"] = true, ["4,4"] = true }
		local cands = Bot.candidates(g)
		assert_true(#cands >= 3)
		for _, cd in ipairs(cands) do
			if cd.cmd.type == "swap" then
				assert_true(not chained[cd.cmd.from[1] .. "," .. cd.cmd.from[2]] and not chained[cd.cmd.to[1] .. "," .. cd.cmd.to[2]])
			end
		end
	end)

	it("a move that takes a link off a chain of hp 2 is worth Bot.W.link, though no goal counter moves", function()
		local e = F.entry({
			goals = { { type = "chains", count = 1 } },
			overlay = chain_overlay({ { 0, 6, 2 } }),
			slots = {
				{ at = { 0, 6 }, type = "piece", color = "red" }, { at = { 1, 6 }, type = "piece", color = "red" },
				{ at = { 2, 5 }, type = "piece", color = "red" }, { at = { 2, 6 }, type = "piece", color = "blue" },
			},
		})
		local g = core.new(e.level, { seed = 1 })
		local bot = Bot.new("strong", { seed = 1, goals = e.goals, width = 7 })
		local plain = Bot.new("strong", { seed = 1, goals = { { type = "collect", color = "green", count = 99 } }, width = 7 })
		local cand
		for _, cd in ipairs(Bot.candidates(g)) do
			local f, t = cd.cmd.from, cd.cmd.to
			if cd.cmd.type == "swap" and f[1] == 3 and t[1] == 3 and f[2] + t[2] == 13 then cand = cd end
		end
		assert_true(cand ~= nil, "the move that completes the red line with the chained piece")
		local clone = Bot.simulate(bot, g, cand)
		assert_same(clone:status().goals, { 1 }, "the chain is only cracked")
		assert_true(Bot.chain_hp(bot, g) - Bot.chain_hp(bot, clone) >= 1)
		assert_eq(Bot.chain_hp(plain, clone), nil)
	end)

	-- a drape of 2x2 in the middle with a tile under each of its cells (core-rules 10.7)
	local function curtain_level(extra)
		local t = {
			size = { 7, 7 }, moves = 30,
			goals = { { type = "light" } },
			floor = { { at = { 2, 3 }, hp = 1 }, { at = { 3, 3 }, hp = 1 }, { at = { 2, 4 }, hp = 1 }, { at = { 3, 4 }, hp = 1 } },
			curtain = { covers = { { 2, 3 }, { 3, 3 }, { 2, 4 }, { 3, 4 } }, closed_moves = 2, open_moves = 3, start = "closed" },
		}
		for k, v in pairs(extra or {}) do t[k] = v end
		return F.entry(t)
	end

	it("wins a small curtain level: the tiles under the drape are lit while it is open", function()
		local e = curtain_level()
		for _, kind in ipairs({ "greedy", "strong" }) do
			local wins = 0
			for seed = 1, 6 do
				local r = Run.play(e, { seed = seed, bot = kind, budget = 60, turbo = true })
				if r.won then wins = wins + 1 end
			end
			assert_true(wins >= 5, kind .. " won " .. wins .. " of 6 within 30 moves")
		end
	end)

	it("never plans a swap or a tap into a closed cell, and plays the same game twice", function()
		local e = curtain_level({ moves = 40, goals = { { type = "collect", color = "red", count = 300 } } })
		local function run(seed)
			local g = core.new(e.level, { seed = seed, timing = "turbo" })
			local bot = Bot.new("greedy", { seed = seed, goals = e.goals, width = 7 })
			local log, closed_turns = {}, 0
			for _ = 1, 40 do
				g:run_to_rest()
				g:drain_events()
				if g:status().state ~= "playing" then break end
				local closed = g:status().curtain.phase == "closed"
				local cells = g:cells()
				for _, cd in ipairs(Bot.candidates(g)) do
					local list = cd.cmd.type == "swap" and { cd.cmd.from, cd.cmd.to } or { cd.cmd.at }
					for _, c in ipairs(list) do
						assert_false(closed and cells[(c[2] - 1) * 7 + c[1]].curtain == true, "a candidate in a closed cell")
					end
				end
				if closed then closed_turns = closed_turns + 1 end
				local cmd = bot:choose(g)
				if not cmd then break end
				assert_true(g:input(cmd))
				log[#log + 1] = cmd.type .. (cmd.from and (cmd.from[1] .. cmd.from[2] .. cmd.to[1] .. cmd.to[2]) or (cmd.at[1] .. cmd.at[2]))
			end
			return log, closed_turns, g:hash()
		end
		local la, closed, ha = run(4)
		local lb, _, hb = run(4)
		assert_true(#la >= 20 and closed >= 5)
		assert_same(la, lb)
		assert_eq(ha, hb)
	end)

	it("counts the goal work left under the curtains, only on a level that has them, and pays Bot.W.drape for it", function()
		local e = curtain_level()
		local g = core.new(e.level, { seed = 2 })
		local bot = Bot.new("strong", { seed = 1, goals = e.goals, width = 7 })
		assert_eq(Bot.curtain_work(bot, g), 4)
		local c = g:clone()
		c.s.floor[3 * 7 + 3] = 0 -- white box: the tile under the curtain cell (3, 4) is lit
		assert_eq(Bot.curtain_work(bot, c), 3)
		c.s.floor[1] = 0
		assert_eq(Bot.curtain_work(bot, c), 3, "a tile in the open is not curtain work")
		-- a level without curtains: nil, and the bot's choice does not look at it
		local plain = F.entry({ goals = { { type = "light" } }, floor = { { at = { 2, 3 }, hp = 1 } } })
		local pg = core.new(plain.level, { seed = 2 })
		local pbot = Bot.new("strong", { seed = 1, goals = plain.goals, width = 7 })
		assert_eq(Bot.curtain_work(pbot, pg), nil)
		assert_eq(pbot.drape, false)
		-- blockers of a break goal and chains under a curtain would count too; a collect goal has nothing there
		local col = curtain_level({ goals = { { type = "collect", color = "red", count = 9 } } })
		local cbot = Bot.new("greedy", { seed = 1, goals = col.goals, width = 7 })
		assert_eq(Bot.curtain_work(cbot, core.new(col.level, { seed = 2 })), 0)
		assert_true(Bot.W.drape > 0)
	end)

	-- the conveyor (core-rules 10.9): a belt across the middle row and a ring in the corner of a 7x7 board
	local function conveyor_level(extra)
		local t = {
			size = { 7, 7 }, moves = 30,
			goals = { { type = "light" } },
			floor = { { at = { 1, 3 }, hp = 1 }, { at = { 3, 3 }, hp = 2 }, { at = { 5, 3 }, hp = 1 }, { at = { 5, 5 }, hp = 1 } },
			conveyor = { { path = { { 1, 3 }, { 2, 3 }, { 3, 3 }, { 4, 3 }, { 5, 3 } } },
				{ path = { { 5, 5 }, { 6, 5 }, { 6, 6 }, { 5, 6 } } } },
		}
		for k, v in pairs(extra or {}) do t[k] = v end
		return F.entry(t)
	end

	it("wins a small conveyor level and plays the same game twice", function()
		local e = conveyor_level()
		for _, kind in ipairs({ "greedy", "strong" }) do
			local wins = 0
			for seed = 1, 6 do
				local r = Run.play(e, { seed = seed, bot = kind, budget = 60, turbo = true })
				if r.won then wins = wins + 1 end
			end
			assert_true(wins >= 5, kind .. " won " .. wins .. " of 6 within 30 moves")
		end
		local a = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		local b = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		assert_same({ a.won, a.moves_used, a.score }, { b.won, b.moves_used, b.score })
	end)

	it("looks one belt step ahead: the clone of a move is scored after the belts moved and their cascade ended", function()
		local e = conveyor_level({ goals = { { type = "collect", color = "red", count = 300 } }, floor = {} })
		local g = core.new(e.level, { seed = 2 })
		local bot = Bot.new("greedy", { seed = 1, goals = e.goals, width = 7 })
		local cands = Bot.candidates(g)
		assert_true(#cands > 0)
		local seen = 0
		for k = 1, math.min(4, #cands) do
			local cmd = cands[k].cmd
			local clone = Bot.simulate(bot, g, cands[k])
			if clone and cmd.type == "swap" then
				-- the same move on a plain turbo clone, stepped by hand: the belts make their step before the rest
				local c = g:clone({ reseed = bot.reseed })
				c:set_timing("turbo")
				assert_true(c:input(cmd))
				local steps = 0
				for _ = 1, 5000 do
					if c:is_stable() then break end
					c:step()
					for _, ev in ipairs(c:drain_events()) do
						if ev.type == "conveyor" and not ev.jam then steps = steps + 1 end
					end
				end
				assert_eq(steps, 2, "both belts stepped once inside the look-ahead")
				assert_eq(clone:hash(), c:hash())
				assert_true(clone:is_stable())
				seen = seen + 1
			end
		end
		assert_true(seen > 0)
	end)

	-- the boombox (core-rules 10.10): three boomboxes on a 7x7 board
	local function boombox_level(extra)
		local t = {
			size = { 7, 7 }, moves = 30,
			goals = { { type = "break", item = "boombox", count = 3 } },
			slots = { { at = { 1, 4 }, type = "boombox", hp = 2 }, { at = { 3, 2 }, type = "boombox", hp = 3 },
				{ at = { 5, 4 }, type = "boombox", hp = 2 } },
		}
		for k, v in pairs(extra or {}) do t[k] = v end
		return F.entry(t)
	end

	it("wins a small boombox level and plays the same game twice", function()
		local e = boombox_level()
		for _, kind in ipairs({ "greedy", "strong" }) do
			local wins = 0
			for seed = 1, 6 do
				local r = Run.play(e, { seed = seed, bot = kind, budget = 60, turbo = true })
				if r.won then wins = wins + 1 end
			end
			assert_true(wins >= 5, kind .. " won " .. wins .. " of 6 within 30 moves")
		end
		local a = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		local b = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		assert_same({ a.won, a.moves_used, a.score }, { b.won, b.moves_used, b.score })
	end)

	it("pays Bot.W.boom for every hp a move takes off a boombox, only with a break goal for it", function()
		local e = boombox_level()
		local g = core.new(e.level, { seed = 2 })
		local bot = Bot.new("greedy", { seed = 1, goals = e.goals, width = 7 })
		assert_eq(Bot.boombox_hp(bot, g), 7)
		assert_true(Bot.W.boom > 0)
		-- the same board with a collect goal: the bot has no boombox term (the blast is goal progress in the clone)
		local col = boombox_level({ goals = { { type = "collect", color = "red", count = 40 } } })
		local cbot = Bot.new("greedy", { seed = 1, goals = col.goals, width = 7 })
		assert_eq(Bot.boombox_hp(cbot, core.new(col.level, { seed = 2 })), nil)
		-- a level without boomboxes: nothing either
		local plain = F.entry()
		assert_eq(Bot.boombox_hp(Bot.new("greedy", { seed = 1, goals = plain.goals, width = 7 }), core.new(plain.level, { seed = 2 })), nil)
		-- the bot does choose a move that hits a boombox when one is on offer
		local hit = 0
		for seed = 1, 4 do
			local gg = core.new(e.level, { seed = seed, timing = "turbo" })
			local bb = Bot.new("strong", { seed = 1, goals = e.goals, width = 7 })
			for _ = 1, 4 do
				local cmd = bb:choose(gg)
				if not cmd or gg:status().state ~= "playing" then break end
				gg:input(cmd)
				gg:run_to_rest()
			end
			if Bot.boombox_hp(bb, gg) < 7 then hit = hit + 1 end
		end
		assert_true(hit >= 3, "boomboxes were hit in " .. hit .. " of 4 games within four moves")
	end)

	it("on a collect level the blast is goal progress inside the look-ahead", function()
		local e = boombox_level({ goals = { { type = "collect", color = "red", count = 60 } } })
		local seen = 0
		for seed = 1, 8 do
			local g = core.new(e.level, { seed = seed })
			local bot = Bot.new("greedy", { seed = 1, goals = e.goals, width = 7 })
			local cands = Bot.candidates(g)
			for k = 1, #cands do
				local c = g:clone({ reseed = bot.reseed })
				c:set_timing("turbo")
				if c:input(cands[k].cmd) then
					local blasted, red = 0, false
					for _ = 1, 5000 do
						if c:is_stable() then break end
						c:step()
						for _, ev in ipairs(c:drain_events()) do
							if ev.type == "boombox" and ev.color == "red" then blasted, red = blasted + #ev.cells, true end
						end
					end
					if red and blasted > 0 then
						local clone = Bot.simulate(bot, g, cands[k])
						assert_eq(clone:hash(), c:hash())
						assert_true(60 - clone:status().goals[1] >= 3 + blasted)
						seen = seen + 1
					end
				end
			end
		end
		assert_true(seen > 0, "no red match next to a boombox in eight boards")
	end)

	-- the hay bale (core-rules 10.12): six bales on a 7x7 board, five of them with a special inside
	local function hay_level(extra)
		local t = {
			size = { 7, 7 }, moves = 30,
			goals = { { type = "break", item = "hay", count = 6 } },
			slots = { { at = { 1, 4 }, type = "hay", hp = 2, gift = "random" }, { at = { 3, 2 }, type = "hay", hp = 2, gift = "sub" },
				{ at = { 5, 4 }, type = "hay", hp = 2, gift = "riff", axis = "h" }, { at = { 3, 5 }, type = "hay", hp = 1, gift = "none" },
				{ at = { 1, 1 }, type = "hay", hp = 1, gift = "random" }, { at = { 5, 1 }, type = "hay", hp = 2, gift = "bird" } },
		}
		for k, v in pairs(extra or {}) do t[k] = v end
		return F.entry(t)
	end

	it("wins a small hay level and plays the same game twice", function()
		local e = hay_level()
		for _, kind in ipairs({ "greedy", "strong" }) do
			local wins = 0
			for seed = 1, 6 do
				local r = Run.play(e, { seed = seed, bot = kind, budget = 60, turbo = true })
				if r.won then wins = wins + 1 end
			end
			assert_true(wins >= 5, kind .. " won " .. wins .. " of 6 within 30 moves")
		end
		local a = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		local b = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		assert_same({ a.won, a.moves_used, a.score }, { b.won, b.moves_used, b.score })
	end)

	it("pays Bot.W.hay for every hp a move takes off a bale, only with a break goal for it", function()
		local e = hay_level()
		local g = core.new(e.level, { seed = 2 })
		local bot = Bot.new("greedy", { seed = 1, goals = e.goals, width = 7 })
		assert_eq(Bot.hay_hp(bot, g), 10)
		assert_true(Bot.W.hay > 0)
		-- the same board with a collect goal: the bot has no hay term
		local col = hay_level({ goals = { { type = "collect", color = "red", count = 40 } } })
		local cbot = Bot.new("greedy", { seed = 1, goals = col.goals, width = 7 })
		assert_eq(Bot.hay_hp(cbot, core.new(col.level, { seed = 2 })), nil)
		-- a level without hay: nothing either
		local plain = F.entry()
		assert_eq(Bot.hay_hp(Bot.new("greedy", { seed = 1, goals = plain.goals, width = 7 }), core.new(plain.level, { seed = 2 })), nil)
		-- the bot does choose a move that hits a bale when one is on offer
		local hit = 0
		for seed = 1, 4 do
			local gg = core.new(e.level, { seed = seed, timing = "turbo" })
			local bb = Bot.new("strong", { seed = 1, goals = e.goals, width = 7 })
			for _ = 1, 4 do
				local cmd = bb:choose(gg)
				if not cmd or gg:status().state ~= "playing" then break end
				gg:input(cmd)
				gg:run_to_rest()
			end
			if Bot.hay_hp(bb, gg) < 10 then hit = hit + 1 end
		end
		assert_true(hit >= 3, "bales were hit in " .. hit .. " of 4 games within four moves")
	end)

	it("counts a revealed gift like a special made by the move, and then plays it", function()
		local e = hay_level()
		-- the look-ahead: a move whose clone reveals a gift carries it in acc.specials
		local counted = 0
		-- the game: the bot's own commands that tap or swap a revealed special while the level is still on
		local used = 0
		for seed = 1, 6 do
			local g = core.new(e.level, { seed = seed, timing = "turbo" })
			local bot = Bot.new("strong", { seed = 1, goals = e.goals, width = 7 })
			local gift_ids = {}
			for _ = 1, 30 do
				if g:status().state ~= "playing" then break end
				local cmd = bot:choose(g)
				if not cmd then break end
				local at = {}
				for _, p in ipairs(g:pieces()) do at[p.y * 64 + p.x] = p.id end
				local cells = cmd.type == "tap" and { cmd.at } or { cmd.from, cmd.to }
				for _, c in ipairs(cells) do
					if gift_ids[at[c[2] * 64 + c[1]] or 0] then used = used + 1 end
				end
				-- the same move in the bot's clone
				local cands = Bot.candidates(g)
				for k = 1, #cands do
					if common.encode(cands[k].cmd) == common.encode(cmd) then
						local clone, acc = Bot.simulate(bot, g, cands[k])
						local made, revealed = 0, 0
						local c2 = g:clone({ reseed = bot.reseed })
						c2:set_timing("turbo")
						c2:input(cmd)
						local over = false -- (the look-ahead stops in the tick the level is won, Bot.settle)
						for _ = 1, 5000 do
							if over or c2:is_stable() then break end
							c2:step()
							for _, ev in ipairs(c2:drain_events()) do
								if ev.type == "special_new" then made = made + 1 end
								if ev.type == "gift" then revealed = revealed + 1 end
								if ev.type == "state" and ev.state ~= "playing" then over = true end
							end
						end
						assert_eq(clone:hash(), c2:hash())
						assert_eq(#acc.specials, made + revealed)
						counted = counted + revealed
					end
				end
				g:input(cmd)
				g:run_to_rest()
				for _, ev in ipairs(g:drain_events()) do
					if ev.type == "gift" then gift_ids[ev.id] = true end
				end
			end
		end
		assert_true(counted > 0, "no look-ahead revealed a gift in six games")
		assert_true(used > 0, "the bot never played a revealed special in six games")
	end)

	it("a level without hay sees no gift event", function()
		local e = F.entry({ goals = { { type = "collect", color = "red", count = 30 } } })
		local g = core.new(e.level, { seed = 3, timing = "turbo" })
		local bot = Bot.new("strong", { seed = 1, goals = e.goals, width = 7 })
		assert_false(bot.hay)
		for _ = 1, 6 do
			local cmd = bot:choose(g)
			if not cmd then break end
			g:input(cmd)
			g:run_to_rest()
			for _, ev in ipairs(g:drain_events()) do assert_true(ev.type ~= "gift") end
		end
	end)

	-- the carpet (core-rules 10.8): three covered cells in the middle of a 7x7 board, two boxes as walls
	local function carpet_level(extra)
		local t = {
			size = { 7, 7 }, moves = 30,
			goals = { { type = "carpet" } },
			carpet = { { 2, 3 }, { 3, 3 }, { 4, 3 } },
			slots = { { at = { 1, 1 }, type = "record_box", hp = 2 }, { at = { 5, 5 }, type = "record_box", hp = 1 } },
		}
		for k, v in pairs(extra or {}) do t[k] = v end
		return F.entry(t)
	end

	it("wins a small carpet level: it covers the whole board, the cells behind the boxes too", function()
		local e = carpet_level()
		for _, kind in ipairs({ "greedy", "strong" }) do
			local wins = 0
			for seed = 1, 6 do
				local r = Run.play(e, { seed = seed, bot = kind, budget = 60, turbo = true })
				if r.won then wins = wins + 1 end
			end
			assert_true(wins >= 5, kind .. " won " .. wins .. " of 6 within 30 moves")
		end
	end)

	it("counts the swaps that would roll the carpet out, only on a level with that goal, and plays the same game twice", function()
		local e = carpet_level({ slots = {} })
		local g = core.new(e.level, { seed = 2 })
		local bot = Bot.new("greedy", { seed = 1, goals = e.goals, width = 7 })
		assert_true(bot.rug)
		-- white box: a board without a match where one swap only, (4,5) -> (4,4), makes a line: the purple
		-- (3..5, 4) on the carpet row (purple is no colour of the level, so nothing else can match)
		local s = g.s
		local COL = { r = 1, y = 3, g = 4, b = 5, p = 6 }
		local rows = { "byrgbyr", "yrgbyrg", "rgbyrgb", "gbprpby", "byrpbyr", "yrgbyrg", "rgbyrgb" }
		for y = 1, 7 do
			for x = 1, 7 do
				s.objs[s.slot[(y - 1) * 7 + x]].color = COL[string.sub(rows[y], x, x)]
			end
		end
		assert_eq(#g:moves(), 1)
		assert_eq(Bot.carpet_moves(bot, g), 0, "the level's carpet (3..5, 4) is under the whole line")
		for i = 1, 49 do s.carpet[i] = false end
		s.carpet[3 * 7 + 3] = true
		assert_eq(Bot.carpet_moves(bot, g), 1, "one cell of the line on the carpet: the match rolls it out")
		s.carpet[3 * 7 + 4], s.carpet[3 * 7 + 5] = true, true
		assert_eq(Bot.carpet_moves(bot, g), 0, "a match wholly on the carpet spreads nothing")
		for i = 1, 49 do s.carpet[i] = false end
		s.carpet[1] = true
		assert_eq(Bot.carpet_moves(bot, g), 0, "a match off the carpet spreads nothing")
		assert_true(Bot.W.rug > 0 and Bot.RUG_CAP >= 1)
		-- a level without the goal: nil, and the bot's choice does not look at it
		local plain = F.entry()
		local pbot = Bot.new("greedy", { seed = 1, goals = plain.goals, width = 7 })
		assert_false(pbot.rug)
		assert_eq(Bot.carpet_moves(pbot, core.new(plain.level, { seed = 2 })), nil)
		-- the same seeds, the same game
		local function run(seed)
			local lvl = carpet_level().level
			local game = core.new(lvl, { seed = seed, timing = "turbo" })
			local b = Bot.new("greedy", { seed = seed, goals = e.goals, width = 7 })
			local log = {}
			for _ = 1, 30 do
				game:run_to_rest()
				game:drain_events()
				if game:status().state ~= "playing" then break end
				local cmd = b:choose(game)
				if not cmd then break end
				assert_true(game:input(cmd))
				log[#log + 1] = cmd.type .. (cmd.from and (cmd.from[1] .. cmd.from[2] .. cmd.to[1] .. cmd.to[2]) or (cmd.at[1] .. cmd.at[2]))
			end
			return log, game:hash()
		end
		local la, ha = run(4)
		local lb, hb = run(4)
		assert_true(#la >= 3)
		assert_same(la, lb)
		assert_eq(ha, hb)
	end)

	-- the ice (core-rules 10.11): eight frozen pieces on a 7x7 board, some with two layers
	local function ice_level(extra)
		local t = {
			size = { 7, 7 }, moves = 30,
			goals = { { type = "ice", count = 8 } },
			overlay = {
				{ at = { 1, 3 }, type = "ice", hp = 2 }, { at = { 2, 3 }, type = "ice", hp = 1 },
				{ at = { 4, 3 }, type = "ice", hp = 1 }, { at = { 5, 3 }, type = "ice", hp = 2 },
				{ at = { 0, 6 }, type = "ice", hp = 1 }, { at = { 6, 6 }, type = "ice", hp = 1 },
				{ at = { 3, 5 }, type = "ice", hp = 2 }, { at = { 3, 1 }, type = "ice", hp = 1 },
			},
		}
		for k, v in pairs(extra or {}) do t[k] = v end
		return F.entry(t)
	end

	it("wins a small ice level and plays the same game twice", function()
		local e = ice_level()
		for _, kind in ipairs({ "greedy", "strong" }) do
			local wins = 0
			for seed = 1, 6 do
				local r = Run.play(e, { seed = seed, bot = kind, budget = 60, turbo = true })
				if r.won then wins = wins + 1 end
			end
			assert_true(wins >= 5, kind .. " won " .. wins .. " of 6 within 30 moves")
		end
		local a = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		local b = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		assert_same({ a.won, a.moves_used, a.score }, { b.won, b.moves_used, b.score })
	end)

	it("pays Bot.W.melt for every hp a move melts, only with an `ice` goal; never proposes a frozen piece", function()
		local e = ice_level()
		local g = core.new(e.level, { seed = 2 })
		local bot = Bot.new("greedy", { seed = 1, goals = e.goals, width = 7 })
		assert_eq(Bot.ice_hp(bot, g), 11)
		assert_true(Bot.W.melt > 0)
		-- the same board with a collect goal: no ice term
		local col = ice_level({ goals = { { type = "collect", color = "red", count = 40 } } })
		local cbot = Bot.new("greedy", { seed = 1, goals = col.goals, width = 7 })
		assert_eq(Bot.ice_hp(cbot, core.new(col.level, { seed = 2 })), nil)
		-- a level without ice: nothing either
		local plain = F.entry()
		assert_eq(Bot.ice_hp(Bot.new("greedy", { seed = 1, goals = plain.goals, width = 7 }), core.new(plain.level, { seed = 2 })), nil)
		-- no candidate moves a frozen piece
		local frozen = {}
		for _, p in ipairs(g:pieces()) do
			if p.ice then frozen[p.y * 64 + p.x] = true end
		end
		for _, cd in ipairs(Bot.candidates(g)) do
			if cd.cmd.type == "swap" then
				assert_true(not frozen[cd.cmd.from[2] * 64 + cd.cmd.from[1]] and not frozen[cd.cmd.to[2] * 64 + cd.cmd.to[1]])
			end
		end
		-- the bot does choose a move that melts ice when one is on offer
		local hit = 0
		for seed = 1, 4 do
			local gg = core.new(e.level, { seed = seed, timing = "turbo" })
			local bb = Bot.new("strong", { seed = 1, goals = e.goals, width = 7 })
			for _ = 1, 4 do
				local cmd = bb:choose(gg)
				if not cmd or gg:status().state ~= "playing" then break end
				gg:input(cmd)
				gg:run_to_rest()
			end
			if Bot.ice_hp(bb, gg) < 11 then hit = hit + 1 end
		end
		assert_true(hit >= 3, "ice was melted in " .. hit .. " of 4 games within four moves")
	end)

	-- the stage fog (core-rules 10.13): the bot plays like a person who cannot see under it
	local FOG_SIX = { "red", "orange", "yellow", "green", "blue", "purple" }
	local FOG_CELLS = { "######", "######", "######", "######", "######", "######" }
	-- two moves for the core: (5,2) -> (5,3) makes an orange three in row 3; (3,5) -> (3,6) makes a purple FOUR in
	-- the bottom row, (1,6) (2,6) (3,6) (4,6): a Riff and four pieces of the collect goal. ((3,6) -> (4,6) makes the
	-- purple three (1,6) (2,6) (3,6).) With (2,6) under the fog both purple moves need a colour nobody sees.
	local FOG_BOARD = { "byrgby", "yrgboy", "rgbopo", "gbyrgb", "bypgby", "ppgpyr" }
	-- the same without the orange move
	local FOG_ONLY = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "bypgby", "ppgpyr" }
	local PURPLE, ORANGE = { type = "swap", from = { 3, 5 }, to = { 3, 6 } }, { type = "swap", from = { 5, 2 }, to = { 5, 3 } }

	local function fog_board(rows, fog)
		local e = F.entry({ size = { 6, 6 }, cells = FOG_CELLS, colors = FOG_SIX, fog = fog,
			goals = { { type = "collect", color = "purple", count = 30 } } })
		local g = core.new(e.level, { seed = 1, timing = "turbo" })
		CH.board(g, rows)
		g:drain_events()
		return g, e
	end

	local function with_cell(rows, x, y, ch)
		local out = {}
		for k = 1, #rows do out[k] = rows[k] end
		out[y] = out[y]:sub(1, x - 1) .. ch .. out[y]:sub(x + 1)
		return out
	end

	local function fog_level(extra)
		local fog = {}
		for y = 2, 4 do
			for x = 1, 5 do fog[#fog + 1] = { x, y } end
		end
		local t = { moves = 20, goals = { { type = "fog" } }, fog = fog }
		for k, v in pairs(extra or {}) do t[k] = v end
		return F.entry(t)
	end

	it("wins a small fog level and plays the same game twice", function()
		local e = fog_level()
		for _, kind in ipairs({ "greedy", "strong" }) do
			local wins = 0
			for seed = 1, 6 do
				local r = Run.play(e, { seed = seed, bot = kind, budget = 60, turbo = true })
				if r.won then wins = wins + 1 end
			end
			assert_true(wins >= 5, kind .. " won " .. wins .. " of 6 within 20 moves")
		end
		local a = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		local b = Run.play(e, { seed = 4, bot = "strong", budget = 60, turbo = true })
		assert_same({ a.won, a.moves_used, a.score }, { b.won, b.moves_used, b.score })
	end)

	it("never chooses a move that needs what the fog hides while a visible move exists", function()
		for _, kind in ipairs({ "greedy", "strong" }) do
			-- seen, the purple four is by far the best move ...
			local open, eo = fog_board(FOG_BOARD, nil)
			assert_same((Bot.new(kind, { seed = 1, goals = eo.goals, width = 6 }):choose(open)), PURPLE, kind)
			-- ... with (2,6) under the fog it is still the best move of the true board, and no candidate of the bot
			local g, e = fog_board(FOG_BOARD, { { 1, 5 } })
			assert_eq(#g:moves(), 3)
			for bot_seed = 1, 6 do -- (the greedy bot draws among its top three: every draw is the visible move)
				local bot = Bot.new(kind, { seed = bot_seed, goals = e.goals, width = 6 })
				local cmd, info = bot:choose(g)
				assert_same(cmd, ORANGE, kind)
				assert_eq(info.n, 1)
				assert_eq(info.blind, nil)
			end
		end
	end)

	it("offers no candidate that starts or ends in the fog, and looks ahead on the blind view only", function()
		-- the purple move ends in the fogged (3,6): for a player it is a guess, for the bot no candidate
		local g, e = fog_board(FOG_BOARD, { { 2, 5 } })
		local bot = Bot.new("strong", { seed = 1, goals = e.goals, width = 6 })
		local fog = Bot.fog_cells(bot, g)
		local cands = Bot.candidates(g:clone({ blind = true }), fog)
		assert_eq(#cands, 1)
		assert_same(cands[1].cmd, ORANGE)
		assert_same((bot:choose(g)), ORANGE)
		-- the choice and its score do not depend on what stands under the fog: other colours, specials
		local cells = { { 1, 5 }, { 1, 2 }, { 3, 3 } }
		local g2, e2 = fog_board(FOG_BOARD, cells)
		local cmd, info = Bot.new("strong", { seed = 1, goals = e2.goals, width = 6 }):choose(g2)
		assert_same(cmd, ORANGE)
		for _, alt in ipairs({ { "b", "y", "g" }, { "D", "S", "R" }, { "o", "o", "o" } }) do
			local rows = with_cell(with_cell(with_cell(FOG_BOARD, 2, 6, alt[1]), 2, 3, alt[2]), 4, 4, alt[3])
			local h = fog_board(rows, cells)
			local c2, i2 = Bot.new("strong", { seed = 1, goals = e2.goals, width = 6 }):choose(h)
			assert_same(c2, cmd)
			assert_same({ i2.score, i2.n, i2.best }, { info.score, info.n, info.best })
		end
		-- a special in the open is a candidate (a tap), the same special under the fog is not, nor are its swaps
		local sp = with_cell(FOG_BOARD, 2, 4, "R")
		local seen, hidden = 0, 0
		for _, cd in ipairs(Bot.candidates((fog_board(sp, { { 4, 4 } })), nil)) do
			if cd.cmd.type == "tap" then seen = seen + 1 end
		end
		local hg = fog_board(sp, { { 1, 3 } })
		local hfog = Bot.fog_cells(Bot.new("strong", { seed = 1, width = 6 }), hg)
		for _, cd in ipairs(Bot.candidates(hg:clone({ blind = true }), hfog)) do
			local c = cd.cmd
			if c.type == "tap" or (c.from[1] == 2 and c.from[2] == 4) or (c.to[1] == 2 and c.to[2] == 4) then hidden = hidden + 1 end
		end
		assert_same({ seen, hidden }, { 1, 0 })
	end)

	it("with nothing visible to play it makes the blind move of the fixed rule, and says so", function()
		local g, e = fog_board(FOG_ONLY, { { 1, 5 } })
		assert_same(g:clone({ blind = true }):moves(), {})
		local cmd, info = Bot.new("strong", { seed = 1, goals = e.goals, width = 6 }):choose(g)
		-- the first swap of game:moves(): what trying the swaps in reading order finds, a refused swap being free
		assert_same(cmd, PURPLE)
		assert_true(info.blind)
		assert_same(Bot.blind_move(g), PURPLE)
		-- no ranking: the rule takes the first of the true moves, not the best (the purple four comes second here)
		local two = fog_board(FOG_BOARD, { { 1, 5 }, { 4, 1 }, { 4, 2 } })
		assert_same(two:clone({ blind = true }):moves(), {})
		local c2, i2 = Bot.new("strong", { seed = 1, goals = e.goals, width = 6 }):choose(two)
		assert_same(c2, ORANGE)
		assert_true(i2.blind)
	end)

	it("over whole games: every chosen move is a move of the blind view with both ends in the open", function()
		local e = fog_level({ moves = 30, goals = { { type = "collect", color = "red", count = 200 } },
			slots = { { at = { 3, 0 }, type = "riff", axis = "v" }, { at = { 2, 5 }, type = "sub" } } })
		local checked = 0
		for seed = 1, 3 do
			local g = core.new(e.level, { seed = seed, timing = "turbo" })
			local bot = Bot.new("strong", { seed = 1, goals = e.goals, width = 7 })
			for _ = 1, 30 do
				g:run_to_rest()
				if g:status().state ~= "playing" then break end
				local cells = g:cells()
				local cmd, info = bot:choose(g)
				if not cmd then break end
				if not info.blind then
					local view = g:clone({ blind = true })
					if cmd.type == "swap" then
						assert_eq(cells[(cmd.from[2] - 1) * 7 + cmd.from[1]].fog, nil)
						assert_eq(cells[(cmd.to[2] - 1) * 7 + cmd.to[1]].fog, nil)
						local found = false
						for _, m in ipairs(view:moves()) do
							if m.from[1] == cmd.from[1] and m.from[2] == cmd.from[2] and m.to[1] == cmd.to[1] and m.to[2] == cmd.to[2] then
								found = true
							end
						end
						assert_true(found, "the swap is a move for someone who sees no fogged piece")
					else
						assert_eq(cells[(cmd.at[2] - 1) * 7 + cmd.at[1]].fog, nil)
					end
					checked = checked + 1
				end
				assert_true(g:input(cmd))
			end
		end
		assert_true(checked >= 20, "moves checked: " .. checked)
	end)

	it("a level without fog never builds a view: the candidates and the choice are as before", function()
		local e = F.entry({ goals = { { type = "collect", color = "red", count = 30 } } })
		local g = core.new(e.level, { seed = 3, timing = "turbo" })
		local bot = Bot.new("strong", { seed = 1, goals = e.goals, width = 7 })
		assert_eq(Bot.fog_cells(bot, g), nil)
		assert_eq(bot.fog, false)
		local cmd, info = bot:choose(g)
		assert_true(cmd ~= nil and info.blind == nil)
		assert_eq(#Bot.candidates(g), info.n)
	end)

	it("refuses an unknown bot kind and a budget below the schema's minimum", function()
		assert_error(function() Bot.new("clever", {}) end, "unknown kind")
		local e = F.entry()
		assert_error(function() Run.play(e, { budget = 4 }) end, "at least 5")
	end)
end)
