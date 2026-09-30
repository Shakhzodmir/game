-- Plays one game of a level with a bot (module and CLI).
--
--   luajit tools/bot/run.lua <level id|file> [--seed 1] [--bot greedy|strong]
--         [--bot-seed <seed>] [--budget 200] [--turbo] [--json] [--games 1]
--
-- The real game runs in NORMAL timing (decisions #5; turbo only inside the
-- bots' lookahead) unless --turbo. The move budget is effectively unlimited
-- (default 200 moves) so one game gives `moves_to_win`, the number of moves
-- the bot needed; the first-attempt result for the level's own limit L is
-- then exactly "moves_to_win <= L":
--   * the level is loaded with moves = min(budget, 60) through its own JSON
--     text (only the moves value differs; the schema allows 5..60), and
--   * at out_of_moves the runner sends the public `continue {moves = n}`
--     until the budget is spent.
-- Nothing in the core reads moves_left except the out_of_moves check and the
-- final concert, so the first 60 moves are identical to a game with any
-- limit M <= 60, and moves_to_win <= M exactly when that game is won.
--
-- Record of a game (Run.play):
--   level, seed, bot, bot_seed, budget, limit (level moves), timing
--   won          -- first attempt with the level's limit (moves_to_win <= limit)
--   moves_used   -- moves spent in that first attempt
--   moves_to_win -- moves needed with the unlimited budget, or nil
--   ending       -- "won" | "stuck" (no move, no continue) | "budget" | "timeout"
--   remaining[k] -- goal-remaining fraction after move k (mean over goals of
--                   left/total; 0 = all goals met)
--   specials[k], waves[k] -- specials created / max cascade wave of move k
--   ticks[k]     -- game tick when move k came to rest (or won)
--   ticks_to_win -- tick of the win (won_wait) or nil
--   duration     -- ticks of the first attempt (to the win or to move `limit`)
--   specials_total, cascades (moves with a wave >= 2) within the first attempt
--   evals        -- clones the bot simulated

local MAIN = (...) ~= "tools.bot.run"
local ROOT = ""
if MAIN then
	ROOT = (arg and arg[0] or ""):match("^(.-)tools[/\\]bot[/\\]run%.lua$") or ""
	package.path = ROOT .. "?.lua;" .. ROOT .. "?/init.lua;" .. package.path
end

local common = require("tools.bot.common")
local Bot = require("tools.bot.bot")

local Run = {}

Run.MAX_SETTLE_TICKS = 20000
Run.TICKS_PER_MOVE_GUARD = 3000 -- a game longer than budget x this is a timeout

local function remaining_fraction(left, totals)
	local n = #totals
	if n == 0 then return 0 end
	local s = 0
	for k = 1, n do
		local t = totals[k]
		if t > 0 then s = s + (left[k] or 0) / t end
	end
	return s / n
end
Run.remaining_fraction = remaining_fraction

-- opts: seed (1), bot ("greedy"), bot_seed (= seed), budget (200),
-- turbo (false), limit (level moves).
function Run.play(entry, opts)
	local core = require("core.game")
	opts = opts or {}
	local seed = opts.seed or 1
	local budget = opts.budget or 200
	local limit = opts.limit or entry.moves
	local first = math.min(budget, 60)
	local level = common.level_with_moves(entry, first, core)
	local timing = opts.turbo and "turbo" or "normal"
	local game, errs = core.new(level, { seed = seed, timing = timing })
	if not game then error("core.new: " .. table.concat(errs, "; ")) end
	local bot_seed = opts.bot_seed or seed
	local bot = Bot.new(opts.bot or "greedy", { seed = bot_seed, goals = entry.goals, width = entry.raw.size[1] })
	local totals = game:status().goals
	local rec = {
		level = entry.id, seed = seed, bot = bot.kind, bot_seed = bot_seed, budget = budget,
		limit = limit, timing = timing,
		remaining = {}, specials = {}, waves = {}, ticks = {},
	}
	local given = first
	local acc = Bot.new_acc()
	-- the start board may be "dirty" (4.3): let it settle first
	if not Bot.settle(game, acc, Run.MAX_SETTLE_TICKS) then
		rec.ending = "timeout"
	end
	local made = 0
	local max_ticks = (budget + 1) * Run.TICKS_PER_MOVE_GUARD
	while not rec.ending do
		local st = game:status()
		if st.tick > max_ticks then
			rec.ending = "timeout"
		elseif st.state == "won_wait" or st.state == "concert" or st.state == "complete" then
			rec.ending = "won"
			rec.moves_to_win = given - st.moves_left
			rec.ticks_to_win = rec.ticks[#rec.ticks] or st.tick
			break
		elseif st.state == "out_of_moves" then
			if given >= budget then
				rec.ending = "budget"
			else
				local n = math.min(60, budget - given)
				local ok, why = game:input({ type = "continue", moves = n })
				if ok then
					given = given + n
				elseif why == "no_candidates" then
					rec.ending = "stuck"
				else
					error("continue refused: " .. tostring(why))
				end
			end
			if rec.ending then game:input({ type = "give_up" }) end
		elseif st.state == "playing" then
			if game:is_stable() and not game:has_move() then
				-- at rest without a move (after `continue`): step 8 shuffles
				game:step()
				game:drain_events()
			elseif game:is_stable() then
				local cmd = bot:choose(game)
				if not cmd then
					rec.ending = "stuck"
					break
				end
				local ok, why = game:input(cmd)
				if not ok then error("bot command refused: " .. tostring(why)) end
				acc = Bot.new_acc()
				if not Bot.settle(game, acc, Run.MAX_SETTLE_TICKS) then
					rec.ending = "timeout"
				end
				local st2 = game:status()
				made = given - st2.moves_left
				if made >= 1 then
					rec.remaining[made] = common.round(remaining_fraction(st2.goals, totals), 4)
					rec.specials[made] = (rec.specials[made] or 0) + #acc.specials
					rec.waves[made] = math.max(rec.waves[made] or 0, acc.waves)
					rec.ticks[made] = st2.tick
				end
			else
				-- not at rest (e.g. a shuffle lock after the last move's rest)
				if not Bot.settle(game, acc, Run.MAX_SETTLE_TICKS) then rec.ending = "timeout" end
			end
		else
			rec.ending = st.state
		end
	end
	-- first-attempt view with the level's limit
	local mtw = rec.moves_to_win
	rec.won = mtw ~= nil and mtw <= limit
	local last = #rec.remaining
	rec.moves_used = rec.won and mtw or math.min(limit, last)
	if rec.won then
		rec.duration = rec.ticks_to_win
	else
		rec.duration = rec.ticks[math.min(limit, last)] or game:status().tick
	end
	local sp, cas = 0, 0
	for k = 1, rec.moves_used do
		sp = sp + (rec.specials[k] or 0)
		if (rec.waves[k] or 0) >= 2 then cas = cas + 1 end
	end
	rec.specials_total, rec.cascades = sp, cas
	rec.evals = bot.evals
	rec.final_tick = game:status().tick
	return rec
end

-- CLI -------------------------------------------------------------------------

local function fmt_record(r)
	local lines = {}
	lines[#lines + 1] = string.format(
		"level %s seed %d bot %s/%d timing %s: %s at limit %d (moves used %d); moves_to_win %s; ending %s",
		tostring(r.level), r.seed, r.bot, r.bot_seed, r.timing, r.won and "WIN" or "LOSS", r.limit,
		r.moves_used, r.moves_to_win and tostring(r.moves_to_win) or "-", r.ending)
	lines[#lines + 1] = string.format("  duration %d ticks (%.1f s), specials %d, cascades %d, clones %d",
		r.duration or 0, (r.duration or 0) / 60, r.specials_total, r.cascades, r.evals)
	local parts = {}
	for k = 1, #r.remaining do parts[#parts + 1] = string.format("%.2f", r.remaining[k]) end
	lines[#lines + 1] = "  remaining: " .. table.concat(parts, " ")
	return table.concat(lines, "\n")
end
Run.format = fmt_record

function Run.main(argv)
	local opts, pos = common.parse_args(argv, { turbo = true, json = true, help = true })
	if opts.help or #pos == 0 then
		print("usage: luajit tools/bot/run.lua <level id|file> [--seed 1] [--bot greedy|strong]"
			.. " [--bot-seed n] [--budget 200] [--turbo] [--json] [--games 1]")
		return 0
	end
	local path = common.level_path(pos[1], ROOT .. "content/levels")
	local entry, errs = common.load_entry(path)
	if not entry then
		io.stderr:write(path .. ": " .. table.concat(errs, "; ") .. "\n")
		return 1
	end
	common.jit_opts()
	local seed = tonumber(opts.seed or 1)
	local games = tonumber(opts.games or 1)
	local t0 = common.clock()
	local recs = {}
	for g = 0, games - 1 do
		local r = Run.play(entry, {
			seed = seed + g, bot = opts.bot or "greedy",
			bot_seed = opts["bot-seed"] and tonumber(opts["bot-seed"]) + g or nil,
			budget = tonumber(opts.budget or 200), turbo = opts.turbo,
		})
		recs[#recs + 1] = r
		if not opts.json then print(fmt_record(r)) end
	end
	local dt = common.clock() - t0
	if opts.json then
		print(common.encode(games == 1 and recs[1] or recs))
	else
		local wins = 0
		for _, r in ipairs(recs) do if r.won then wins = wins + 1 end end
		print(string.format("%d game(s), %d won at limit %d; %.2f s CPU, %.2f games/s (%s)",
			games, wins, entry.moves, dt, games / math.max(dt, 1e-9), common.vm_name()))
	end
	return 0
end

if MAIN then os.exit(Run.main(arg or {})) end

return Run
