-- Bots over the public core API (decisions #5, core-rules 17.3).
--
--   local Bot = require("tools.bot.bot")
--   local bot = Bot.new("greedy", { seed = 7, goals = raw.goals, width = raw.size[1] })
--   local cmd, info = bot:choose(game)     -- game at rest in `playing`
--   game:input(cmd)
--
-- A decision enumerates the candidate actions (every pair of game:moves(),
-- including swaps with specials and special+special combos, then a tap on
-- every free special) and scores each on its own clone:
--   game:clone{reseed = k} -> set_timing("turbo") -> input -> run to rest.
-- Clones are reseeded, so the lookahead does not know the real game's future
-- colours (17.3). The real game keeps its own timing.
--
-- Score (plan p.26): goal progress x10 + specials created x3 + cascade waves
-- (+ a bonus for a combo swap).
--   greedy -- the best action with probability 0.7, otherwise a uniformly
--             random one of the top 3 (the bot's own MINSTD stream);
--   strong -- always the best; a win is worth +1000, combos weigh more,
--             specials created near goal targets and big specials weigh more,
--             and the top 3 first moves get a second ply limited to the swaps
--             that statically create a special or a combo (cheap: at most 3
--             extra clones per branch).
-- Ties go to the earlier candidate (moves() order, then taps by cell), so a
-- bot is deterministic given (level, game seed, bot seed). Scores are
-- integers (x Bot.SCALE): the same choice on every VM and CPU.

local common = require("tools.bot.common")

local Bot = {}
Bot.__index = Bot

Bot.KINDS = { greedy = true, strong = true }

local SPECIAL_RANK = { bird = 1, riff = 2, sub = 3, disco = 4 }

-- Weights of the score. The first three come from the plan. The second ply
-- adds best2 * second_ply_num / second_ply_den.
Bot.SCALE = 1000
Bot.W = {
	progress = 10, special = 3, wave = 1,
	combo_greedy = 5, combo_strong = 15, combo_disco_strong = 25,
	win_strong = 1000, near_goal = 3, rank_strong = 1, second_ply_num = 1, second_ply_den = 2,
}

-- Max clone ticks per evaluated action (a guard; turbo needs ~10-60).
Bot.MAX_EVAL_TICKS = 5000

function Bot.new(kind, opts)
	opts = opts or {}
	if not Bot.KINDS[kind] then error("bot: unknown kind " .. tostring(kind)) end
	local seed = opts.seed or 1
	local self = setmetatable({
		kind = kind,
		seed = seed,
		reseed = seed % 2147483646,
		rng = common.rng(seed),
		goals = opts.goals or {},   -- goals of the level JSON (for goal targets)
		width = opts.width or 9,    -- board width (cells() is indexed (y-1)*W+x)
		totals = nil,               -- initial goal counts (first decision)
		decisions = 0,
		evals = 0,                  -- clones simulated
	}, Bot)
	return self
end

-- Candidates ------------------------------------------------------------------

local function key(x, y) return y * 64 + x end

-- Board snapshot from pieces(): by cell key -> piece.
local function board_map(game)
	local map = {}
	local list = game:pieces()
	for k = 1, #list do
		local p = list[k]
		map[key(p.x, p.y)] = p
	end
	return map, list
end

-- Candidate commands in a canonical order: moves() then taps by cell.
function Bot.candidates(game)
	local map, list = board_map(game)
	local out = {}
	local mv = game:moves()
	for k = 1, #mv do
		local m = mv[k]
		local a = map[key(m.from[1], m.from[2])]
		local b = map[key(m.to[1], m.to[2])]
		local combo = a and b and a.kind == "special" and b.kind == "special" or false
		local disco = combo and (a.special == "disco" or b.special == "disco") or false
		out[#out + 1] = {
			cmd = { type = "swap", from = { m.from[1], m.from[2] }, to = { m.to[1], m.to[2] } },
			combo = combo, disco = disco,
		}
	end
	for k = 1, #list do
		local p = list[k]
		if p.kind == "special" and p.state == "idle" and not p.pinned then
			out[#out + 1] = { cmd = { type = "tap", at = { p.x, p.y } }, combo = false, disco = false }
		end
	end
	for k = 1, #out do out[k].index = k end
	return out, map
end

-- Simulation of one action on a clone ---------------------------------------

-- Steps a game until rest or until it leaves `playing` (won_wait: the goals
-- are met; out_of_moves happens only at rest). Events are drained each tick
-- and summarised into `acc`: specials (list of {x, y, special}), waves (max
-- wave), combos (activations with a partner), won, state. Returns ticks run,
-- or nil when max_ticks is exceeded.
function Bot.settle(game, acc, max_ticks)
	local n = 0
	max_ticks = max_ticks or 20000
	while not game:is_stable() do
		if n >= max_ticks then return nil end
		game:step()
		n = n + 1
		local ev = game:drain_events()
		for k = 1, #ev do
			local e = ev[k]
			local ty = e.type
			if ty == "match" then
				if e.wave > acc.waves then acc.waves = e.wave end
			elseif ty == "special_new" then
				acc.specials[#acc.specials + 1] = { x = e.x, y = e.y, special = e.special }
			elseif ty == "activate" then
				if e.partner or e.combo then acc.combos = acc.combos + 1 end
			elseif ty == "state" then
				acc.state = e.state
				if e.state == "won_wait" then acc.won = true end
			end
		end
		if acc.state ~= "playing" then break end
	end
	return n
end

function Bot.new_acc()
	return { waves = 0, specials = {}, combos = 0, won = false, state = "playing" }
end

-- Goal targets of the strong bot: cells of open goals (unlit tiles, blockers
-- of open `break` goals, mics). Collect goals have no cells.
local function goal_targets(self, game, map, left)
	local want_item, want_mic, want_floor = {}, false, false
	for k = 1, #self.goals do
		local g = self.goals[k]
		if (left[k] or 0) > 0 then
			if g.type == "break" then want_item[g.item] = true
			elseif g.type == "deliver" then want_mic = true
			elseif g.type == "light" then want_floor = true end
		end
	end
	local cells = {}
	for _, p in pairs(map) do -- order-independent (a set of cells)
		if (p.item and want_item[p.item]) or (want_mic and p.kind == "mic") then
			cells[#cells + 1] = { p.x, p.y }
		end
	end
	if want_floor then
		local cl = game:cells()
		local W = self.width
		for i = 1, #cl do
			if cl[i].floor and cl[i].floor > 0 then
				cells[#cells + 1] = { (i - 1) % W + 1, math.floor((i - 1) / W) + 1 }
			end
		end
	end
	return cells
end

local function near(cells, x, y, d)
	for k = 1, #cells do
		local c = cells[k]
		if math.abs(c[1] - x) + math.abs(c[2] - y) <= d then return true end
	end
	return false
end

-- Weighted goal progress between two goal-left arrays, x SCALE. Every goal
-- counts in its own units scaled so that the average unit weighs 1 (a level
-- with one goal scores the raw progress).
function Bot.progress(self, before, after)
	local p = 0
	for k = 1, #before do
		local d = before[k] - (after[k] or 0)
		if d > 0 then p = p + d * self.gw[k] end
	end
	return p
end

local function init_goal_weights(self, game)
	local totals = game:status().goals
	self.totals = totals
	local sum, n = 0, #totals
	for k = 1, n do sum = sum + math.max(1, totals[k]) end
	local mean = n > 0 and sum / n or 1
	self.gw = {}
	for k = 1, n do self.gw[k] = math.floor(Bot.SCALE * mean / math.max(1, totals[k]) + 0.5) end
end

-- Static special finder (used as the cheap filter of the second ply): for
-- each pair of moves() where both cells hold regular pieces, swaps their
-- colours virtually and classifies the line/square through each cell
-- (core-rules 6.1: line >= 5 disco, h+v lines sub, line of 4 riff, 2x2
-- bird). Returns a list of {cand, rank} with rank > 0, best first.
function Bot.static_specials(game, map, cands)
	local color = {}
	for k, p in pairs(map) do -- order-independent (a map copy)
		if p.kind == "regular" and (p.state == "idle") then color[k] = p.color end
	end
	local function c(x, y) return color[key(x, y)] end
	local function classify(x, y, col)
		local h = 1
		local i = x - 1
		while c(i, y) == col do h = h + 1 i = i - 1 end
		i = x + 1
		while c(i, y) == col do h = h + 1 i = i + 1 end
		local v = 1
		i = y - 1
		while c(x, i) == col do v = v + 1 i = i - 1 end
		i = y + 1
		while c(x, i) == col do v = v + 1 i = i + 1 end
		if h >= 5 or v >= 5 then return 4 end
		if h >= 3 and v >= 3 then return 3 end
		if h == 4 or v == 4 then return 2 end
		for dx = -1, 0 do
			for dy = -1, 0 do
				if c(x + dx, y + dy) == col and c(x + dx + 1, y + dy) == col
					and c(x + dx, y + dy + 1) == col and c(x + dx + 1, y + dy + 1) == col then
					return 1
				end
			end
		end
		return 0
	end
	local out = {}
	for k = 1, #cands do
		local cd = cands[k]
		if cd.combo then
			out[#out + 1] = { cand = cd, rank = cd.disco and 6 or 5 }
		elseif cd.cmd.type == "swap" then
			local f, t = cd.cmd.from, cd.cmd.to
			local kf, kt = key(f[1], f[2]), key(t[1], t[2])
			local cf, ct = color[kf], color[kt]
			if cf and ct then
				color[kf], color[kt] = ct, cf
				local r = math.max(classify(f[1], f[2], ct), classify(t[1], t[2], cf))
				color[kf], color[kt] = cf, ct
				if r > 0 then out[#out + 1] = { cand = cd, rank = r } end
			end
		end
	end
	table.sort(out, function(a, b)
		if a.rank ~= b.rank then return a.rank > b.rank end
		return a.cand.index < b.cand.index
	end)
	return out
end

-- Simulates `cand` on a reseeded turbo clone of `game`. Returns the clone
-- (at rest or just won) and its summary, or nil if the command was refused
-- or the clone did not settle.
function Bot.simulate(self, game, cand)
	local c = game:clone({ reseed = self.reseed })
	c:set_timing("turbo")
	self.evals = self.evals + 1
	local ok = c:input(cand.cmd)
	if not ok then return nil end
	local acc = Bot.new_acc()
	local n = Bot.settle(c, acc, Bot.MAX_EVAL_TICKS)
	if not n then return nil end
	return c, acc
end

-- Base score of a simulated action (both bots).
function Bot.base_score(self, cand, acc, before, after)
	local W = Bot.W
	local s = W.special * #acc.specials + W.wave * acc.waves
	if cand.combo then
		s = s + (self.kind == "strong" and (cand.disco and W.combo_disco_strong or W.combo_strong) or W.combo_greedy)
	end
	return W.progress * Bot.progress(self, before, after) + Bot.SCALE * s
end

-- Chooses an action for `game` (at rest, state `playing`). Returns the
-- command and an info table {score, rank, n, scores}.
function Bot:choose(game)
	if not self.gw then init_goal_weights(self, game) end
	self.decisions = self.decisions + 1
	local cands, map = Bot.candidates(game)
	if #cands == 0 then return nil, { n = 0 } end
	local before = game:status().goals
	local strong = self.kind == "strong"
	local targets = strong and goal_targets(self, game, map, before) or nil
	local W = Bot.W
	local scored = {}
	for k = 1, #cands do
		local cd = cands[k]
		local clone, acc = Bot.simulate(self, game, cd)
		local sc = -1e15
		if clone then
			local after = clone:status().goals
			sc = Bot.base_score(self, cd, acc, before, after)
			if strong then
				local extra = acc.won and W.win_strong or 0
				for j = 1, #acc.specials do
					local sp = acc.specials[j]
					extra = extra + W.rank_strong * ((SPECIAL_RANK[sp.special] or 1) - 1)
					if #targets > 0 and near(targets, sp.x, sp.y, 2) then extra = extra + W.near_goal end
				end
				sc = sc + Bot.SCALE * extra
			end
		end
		scored[k] = { cand = cd, score = sc, clone = strong and clone or nil, acc = acc }
	end
	local function order(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.cand.index < b.cand.index
	end
	table.sort(scored, order)
	if strong then
		-- Second ply for the top 3: the best special-creating follow-up.
		for k = 1, math.min(3, #scored) do
			local e = scored[k]
			if e.clone and not e.acc.won and e.acc.state == "playing" and e.clone:is_stable() then
				local c2, map2 = Bot.candidates(e.clone)
				local hits = Bot.static_specials(e.clone, map2, c2)
				local best2 = 0
				local before2 = e.clone:status().goals
				for j = 1, math.min(3, #hits) do
					local cl2, acc2 = Bot.simulate(self, e.clone, hits[j].cand)
					if cl2 then
						local s2 = Bot.base_score(self, hits[j].cand, acc2, before2, cl2:status().goals)
						if acc2.won then s2 = s2 + Bot.SCALE * W.win_strong / 10 end
						if s2 > best2 then best2 = s2 end
					end
				end
				e.score = e.score + math.floor(best2 * W.second_ply_num / W.second_ply_den)
			end
		end
		table.sort(scored, order)
	end
	local pick = 1
	if not strong then
		local r = common.rng_next(self.rng) % 10
		local j = common.rng_int(self.rng, math.min(3, #scored))
		if r >= 7 then pick = j end
	end
	local chosen = scored[pick]
	local info = { score = chosen.score / Bot.SCALE, rank = pick, n = #scored, best = scored[1].score / Bot.SCALE }
	for k = 1, #scored do scored[k].clone = nil end
	return chosen.cand.cmd, info
end

return Bot
