-- What the level windows say (pure Lua): the view models of the pause window,
-- the "out of moves" offer, the defeat and the results, built from the meta and
-- the core. No rule is decided here: every number comes from the meta API
-- (meta/meta.lua) or the core's own result; the windows (gui/pause.lua,
-- gui/moves.lua, gui/defeat.lua, gui/result.lua) only draw them. Texts are i18n
-- specs ({key, vars}) so they follow a language change.
--
--   local lw = require("client.level_windows")
--   lw.pause(meta, now)                       --> {moved, at_stake, leave, lines, run}
--   lw.out_of_moves(meta, status, now, opts)  --> {stuck, offer, lines, boosters, ad, coins, ...}
--   lw.defeat(meta, res, status, goals, now)  --> {life_lost, streak_lost, goals, close, lives, ...}
--   lw.result(meta, res, core_result, now)    --> {stars, coins, score, moves_left, streak, chest, progress, ...}
--   lw.stake(meta, now)                       --> what leaving or giving up would cost right now
--
-- A meta without an attempt (a debug level) has nothing at stake.

local config = require("meta.config")

local M = {}

-- What the player would lose by leaving the attempt now: {run, moved, life (a life), streak (wins in a
-- row that burn), boosters (paid pre-level boosters that come back when nothing was played)}.
function M.stake(meta, now)
	local run = meta:run()
	if not run then return { run = nil, moved = false, life = false, streak = 0, boosters = 0 } end
	local l = meta:lives(now)
	return {
		run = run,
		moved = run.moved and true or false,
		life = (not run.free) and (l.infinite_seconds or 0) <= 0,
		streak = meta:streak().count,
		boosters = #(run.boosters or {}),
	}
end

-- The honest lines for quitting after the first move / giving up: what it costs, in order.
-- `none` = the key said when it costs neither a life nor a streak.
local function loss_lines(s, none)
	local lines = {}
	if s.life then lines[#lines + 1] = { key = "continue.life_warning" } end
	if s.streak > 0 then lines[#lines + 1] = { key = "continue.streak_warning", vars = { n = s.streak } } end
	if #lines == 0 then lines[1] = { key = none } end
	return lines
end

-- The pause window. leave = "cancel" (nothing was played: the attempt is dropped and the boosters come
-- back) | "loss" (the attempt counts as a loss); at_stake = a life or a streak is lost by leaving.
function M.pause(meta, now)
	local s = M.stake(meta, now)
	local out = { run = s.run, moved = s.moved }
	if not s.run then
		out.leave, out.at_stake = "cancel", false
		out.lines = { { key = "pause.quit_free" } }
	elseif not s.moved then
		out.leave, out.at_stake = "cancel", false
		out.lines = { { key = "pause.quit_free" } }
		if s.boosters > 0 then out.lines[2] = { key = "pause.boosters_back" } end
	else
		out.leave = "loss"
		out.at_stake = s.life or s.streak > 0
		out.lines = loss_lines(s, "pause.warn_loss")
	end
	return out
end

-- Boosters that cannot help once the moves are out. A Remix only rearranges the pieces: it gives no move, so
-- the level would fall straight back to this window with the booster spent; and on a stuck board it has
-- nothing to shuffle (the core refuses it: no candidates). The wand, the two lights and the Crossfader (it lines up
-- a match and costs no move) can still finish a goal.
M.NO_HELP_OUT_OF_MOVES = { remix = true }

-- In-level boosters the player can still use: {{id, count}} (unlocked, in stock). In a debug level
-- (no attempt) all of them are free: count nil.
function M.usable_boosters(meta, ids)
	local out = {}
	local have = {}
	for _, b in ipairs(meta:inventory()) do have[b.id] = b end
	local free = meta:run() == nil
	for _, id in ipairs(ids) do
		local b = have[id]
		if free then
			out[#out + 1] = { id = id }
		elseif b and b.unlocked and b.count > 0 then
			out[#out + 1] = { id = id, count = b.count }
		end
	end
	return out
end

-- The "out of moves" window. status = core status (state, stuck, goals); opts = {ads = bool (a rewarded
-- video can be shown now), boosters = list of in-level booster ids (the ones that can still help are listed)}.
-- offer = meta:continue_offer() {k, price, moves, riff, affordable} or nil (limit reached / stuck / no attempt).
-- ad_moves = what the rewarded video gives (the meta's number, the window only prints it).
function M.out_of_moves(meta, status, now, opts)
	opts = opts or {}
	local s = M.stake(meta, now)
	local out = {
		stuck = status and status.stuck and true or false,
		run = s.run,
		coins = meta:coins(),
		lines = loss_lines(s, "continue.warn_loss"), -- what giving up costs
		at_stake = s.life or s.streak > 0,
	}
	if not s.run then
		out.lines, out.at_stake = {}, false
		-- a debug level: the moves of a purchase for nothing
		out.offer = not out.stuck and { k = 0, price = 0, moves = config.continues.moves, riff = false, affordable = true,
			free = true } or nil
	elseif not out.stuck then
		out.offer = meta:continue_offer()
	end
	local ids = {}
	for _, id in ipairs(opts.boosters or {}) do
		if not M.NO_HELP_OUT_OF_MOVES[id] then ids[#ids + 1] = id end
	end
	out.boosters = M.usable_boosters(meta, ids)
	out.ad = (opts.ads and s.run and not s.run.ad_used and not out.stuck) and true or false
	out.ad_moves = config.ad_moves
	return out
end

-- The goals that are not done, for the defeat: {{kind, image, left, total}}; goals = client/levels.lua
-- goals() entries in file order, status = core status at the end.
function M.goals_left(goals, status, totals)
	local out = {}
	local left = status and status.goals or {}
	for i, g in ipairs(goals or {}) do
		local l = left[i]
		if l and l > 0 then
			out[#out + 1] = { kind = g.kind, image = g.image, color = g.color, label = g.label, left = l,
				total = (totals and totals[i]) or g.count or l }
		end
	end
	return out
end

-- 0..1: how much of the goals the player had done
local function done_share(goals_left, totals)
	local total, left = 0, 0
	for _, g in ipairs(goals_left) do left = left + g.left end
	for _, t in ipairs(totals or {}) do total = total + t end
	if total <= 0 then return 0 end
	return math.max(0, math.min(1, 1 - left / total))
end

M.CLOSE = 0.7 -- "So close!" from this much of the goals done

-- The defeat window. res = the meta's finish_level loss result {life_lost, streak_lost, fails, reason};
-- goals = client/levels.lua goals() of the level; totals = what each goal asked at the start.
function M.defeat(meta, res, status, goals, totals, now)
	res = res or {}
	local lives = meta:lives(now)
	local left = M.goals_left(goals, status, totals)
	local share = done_share(left, totals)
	return {
		life_lost = res.life_lost and true or false,
		streak_lost = res.streak_lost or 0,
		fails = res.fails or 0,
		goals = left,
		close = #left > 0 and share >= M.CLOSE,
		share = share,
		lives = { count = lives.count, max = lives.max, next_in = lives.next_in_seconds or 0,
			infinite = (lives.infinite_seconds or 0) > 0 },
		no_lives = (lives.infinite_seconds or 0) <= 0 and lives.count <= 0,
		quit = res.reason == "quit",
	}
end

-- Progress to the next level chest after beating `level_id`: {done, total, left, opened}.
function M.chest_progress(level_id)
	local every = config.level_chest.every
	local done = level_id % every
	if done == 0 and level_id > 0 then return { done = every, total = every, left = 0, opened = true } end
	return { done = done, total = every, left = every - done, opened = false }
end

-- The level chest the player can take now, or nil: {level_id, k, coins, boosters = {ids}, infinite_minutes}.
-- A won level's chest waits in the meta until it is claimed (meta:claim_level_chest), so the oldest waiting
-- one is offered: the one this win brought, or an older one that was left unclaimed.
function M.chest(meta)
	local waiting = meta:pending_chests()[1]
	if not waiting then return nil end
	local c = waiting.chest
	return { level_id = waiting.level_id, k = c.k, coins = c.coins, boosters = c.boosters or {},
		infinite_minutes = c.infinite_minutes or 0 }
end

-- The results window. res = the meta's finish_level win result {coins, stars, chest, unlocked, streak,
-- next_level}; core_result = the core's game:result() {score, moves_at_win, stars}.
function M.result(meta, res, core_result, now)
	core_result = core_result or {}
	local sv = meta:streak()
	local notes = {}
	for i, slot in ipairs(sv.slots or {}) do
		notes[i] = { lit = slot.lit and true or false, booster = slot.booster, unlocked = slot.unlocked and true or false }
	end
	local chest = (not res.standalone) and M.chest(meta) or nil
	return {
		level_id = res.level_id,
		stars = res.stars or core_result.stars or 0,
		coins = res.coins or 0,
		score = core_result.score or 0,
		moves_left = core_result.moves_at_win or 0,
		streak = { count = res.streak or 0, active = sv.active and true or false, notes = notes,
			free = meta:streak_boosters_for_next_start() },
		chest = chest,
		progress = M.chest_progress(res.level_id or 0),
		unlocked = res.unlocked or {},
		next_level = res.next_level,
		all_done = res.next_level == nil,
		standalone = res.standalone and true or false,
	}
end

return M
