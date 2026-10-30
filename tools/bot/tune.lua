-- Move tuner: picks each level's move limit from the bot's moves-to-win
-- distribution (levels-plan 1, plan p.26 "автоподбор ходов").
--
--   luajit tools/bot/tune.lua [--n 100] [--jobs 3] [--bot greedy|strong]
--         [--budget 120] [--levels 1-40] [--dir content/levels] [--write]
--         [--work <dir>] [--fresh] [--force] [--md docs/levels/tuning.md]
--         [--json docs/levels/tuning.json] [--no-report] [--vm luajit] [--quiet]
--
-- For every level N games are played (game seed = bot seed = 1..N: common
-- random numbers, so two runs of the same level compare game by game) with
-- an effectively unlimited move budget (tools/bot/run.lua). The first-attempt
-- win rate for a limit M is the share of games with moves_to_win <= M; M
-- is chosen so that it hits the centre of the level's difficulty corridor:
--   easy 90% (85-95), medium 68% (60-75), hard 42% (35-50), super_hard 25% (20-30)
-- within 5..60 (the schema's range; ties: see Tune.choose). For the chosen M the tuner reports the
-- expected attempts (1/p), the near-miss share (losses with <= 20% of the
-- goals left after M moves), the median moves of the winners, and flags:
--   too_hard      -- even 60 moves stay below the corridor
--   too_easy      -- even 5 moves stay above the corridor
--   off_corridor  -- the win rate jumps over the corridor (few games / flat curve)
--   outside_band  -- M outside the plan's 20-35 moves
--   near_miss_low -- fewer than half of the losses are near misses (plan rule 4)
--   stuck_games   -- some game ended in a dead end (no move, no shuffle) or hung
--   invalid       -- the level does not load, a game raised a core error, or
--                    a worker died before finishing the level
--
-- --jobs K runs K worker processes (luajit by default) over disjoint level
-- subsets through io.popen. Each worker writes the result of every finished
-- level to the work directory (one file per level, written atomically); the
-- parent reads them when the workers end. A dead worker therefore loses at
-- most the level it was playing. With --work <dir> the directory is kept and
-- is a cache: a result is reused when the level text (without the move
-- limit), the budget, the bot and the sources of core/ and tools/bot/ are
-- the same, so re-running the same command after an interruption only plays
-- what is missing (--fresh ignores the cache). Game k depends on seed k only,
-- so a result saved for N0 games serves any N <= N0 (its first N games) and
-- a larger N plays just the missing seeds: a first pass with --n 100 makes
-- the final --n 300 a third cheaper. Without --work a temporary directory is
-- used and removed.
--
-- Without --write nothing in the levels directory changes. With --write the
-- "moves" value of every tuned level file is replaced in place (the rest of
-- the file stays byte-identical); a file that changed since it was played is
-- skipped, and --write needs N >= 100 unless --force (a small N gives noisy
-- limits). The report goes to docs/levels/tuning.md and
-- docs/levels/tuning.json; for a --dir other than content/levels no report is
-- written unless --md / --json name the files (a rehearsal on a copy must not
-- overwrite the real report). Exit code: 0 ok, 1 some level is invalid or
-- has no result, 2 bad command line.

local MAIN = (...) ~= "tools.bot.tune"
local ROOT = ""
if MAIN then
	-- the repository root from the script path (also when started from another directory)
	ROOT = (arg and arg[0] or ""):match("^(.-)tools[/\\]bot[/\\]tune%.lua$")
	if not ROOT then ROOT = ((arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or ".") .. "/../../" end
	package.path = ROOT .. "?.lua;" .. ROOT .. "?/init.lua;" .. package.path
end

local common = require("tools.bot.common")

local Tune = {}

Tune.MIN_M, Tune.MAX_M = 5, 60
Tune.BAND_LO, Tune.BAND_HI = 20, 35
Tune.NEAR_MISS = 0.2
Tune.DEFAULT_BUDGET = 120
Tune.MIN_N_WRITE = 100
Tune.RESULT_VERSION = 1
Tune.DEFAULT_DIR = "content/levels"

-- Win-rate math (pure) ---------------------------------------------------------
-- `games` is an array of {m = moves_to_win or nil, r = {remaining after
-- move k}}; `n` = #games.

function Tune.win_rate(games, M)
	local n = #games
	if n == 0 then return 0 end
	local w = 0
	for k = 1, n do
		local m = games[k].m
		if m and m <= M then w = w + 1 end
	end
	return w / n
end

-- Losses at limit M whose goal-remaining fraction after M moves (or after
-- their last move, if they ended earlier) is <= threshold: share among the
-- losses, or nil without losses.
function Tune.near_miss(games, M, threshold)
	threshold = threshold or Tune.NEAR_MISS
	local losses, near = 0, 0
	for k = 1, #games do
		local g = games[k]
		if not (g.m and g.m <= M) then
			losses = losses + 1
			local r = g.r or {}
			local v = r[math.min(M, #r)]
			if v and v <= threshold + 1e-9 then near = near + 1 end
		end
	end
	if losses == 0 then return nil, 0 end
	return near / losses, losses
end

function Tune.median_winners(games, M)
	local list = {}
	for k = 1, #games do
		local m = games[k].m
		if m and m <= M then list[#list + 1] = m end
	end
	return common.median(list)
end

-- Chooses M for a difficulty (see the header). Returns a table:
--   M, p (win rate at M), attempts (1/p or nil), near_miss, losses,
--   median (moves of the winners), flags (array of codes), p5, p60.
function Tune.choose(games, difficulty, current)
	local cor = common.CORRIDOR[difficulty]
	if not cor then error("tune: unknown difficulty " .. tostring(difficulty)) end
	local c = cor.target
	local bestd = nil
	for M = Tune.MIN_M, Tune.MAX_M do
		local d = math.abs(Tune.win_rate(games, M) - c)
		if not bestd or d < bestd - 1e-12 then bestd = d end
	end
	-- Among the limits at that distance: a plateau at or above the target
	-- -> its smallest M; below the target -> its largest M (the true curve
	-- rises across a plateau, so these are the ends nearest the target),
	-- unless the plateau runs to 60 inside the corridor: then no extra move
	-- ever helped and the smallest M of the plateau is taken. (Below the
	-- corridor at 60 the level is too hard and keeps the most moves, 60.)
	-- A tie between a plateau above and one below the target goes to the
	-- one above (the easier limit).
	local above, below, below_first = nil, nil, nil
	for M = Tune.MIN_M, Tune.MAX_M do
		local p = Tune.win_rate(games, M)
		if math.abs(math.abs(p - c) - bestd) <= 1e-12 then
			if p >= c - 1e-12 then
				if not above then above = M end
			else
				below = M
				below_first = below_first or M
			end
		end
	end
	if below == Tune.MAX_M and Tune.win_rate(games, below) >= cor.lo - 1e-12 then below = below_first end
	local M = above or below
	local p = Tune.win_rate(games, M)
	local res = {
		M = M, p = p, attempts = p > 0 and 1 / p or nil,
		median = Tune.median_winners(games, M),
		p5 = Tune.win_rate(games, Tune.MIN_M), p60 = Tune.win_rate(games, Tune.MAX_M),
		corridor = cor, flags = {},
	}
	res.near_miss, res.losses = Tune.near_miss(games, M)
	if current then res.p_before = Tune.win_rate(games, current) end
	local f = res.flags
	if res.p60 < cor.lo - 1e-12 then
		f[#f + 1] = "too_hard"
	elseif res.p5 > cor.hi + 1e-12 then
		f[#f + 1] = "too_easy"
	elseif p < cor.lo - 1e-12 or p > cor.hi + 1e-12 then
		f[#f + 1] = "off_corridor"
	end
	if M < Tune.BAND_LO or M > Tune.BAND_HI then f[#f + 1] = "outside_band" end
	if res.near_miss and res.near_miss < 0.5 then f[#f + 1] = "near_miss_low" end
	return res
end

-- Results on disk (the work directory) -------------------------------------------

local function basename(path)
	return path:match("[^/\\]+$") or path
end

function Tune.slot_path(work, file)
	return work .. "/" .. basename(file) .. ".result.json"
end

-- Everything the games of a level depend on: the level text without the move
-- limit, the budget, the bot and the code that plays them (`run.code`, see
-- Tune.code_fingerprint). Neither the move limit (the games play with
-- min(budget, 60) moves whatever the file says) nor N is part of it: game k
-- depends on seed k only, so a saved result of N0 games holds the first N0
-- games of every longer run too.
function Tune.run_key(text, run)
	return table.concat({
		"r" .. Tune.RESULT_VERSION, run.bot or "greedy", tostring(run.budget or Tune.DEFAULT_BUDGET),
		common.level_sig(text), tostring(run.code or "-"),
	}, "|")
end

-- Checksum of the sources the games depend on: core/*.lua and tools/bot/*.lua.
function Tune.code_fingerprint()
	local paths = {}
	for _, dir in ipairs({ "core", "tools/bot" }) do
		for _, name in ipairs(common.list_dir(ROOT .. dir, "%.lua$")) do
			paths[#paths + 1] = ROOT .. dir .. "/" .. name
		end
	end
	return common.checksum_files(paths)
end

function Tune.save_result(work, file, key, res)
	return common.write_file_atomic(Tune.slot_path(work, file), common.encode({ key = key, level = res }))
end

-- The result saved for `file` under `key`, or nil (absent, damaged, other key).
function Tune.load_result(work, file, key)
	local text = common.read_file(Tune.slot_path(work, file))
	if not text then return nil end
	local data = common.decode(text)
	if type(data) ~= "table" or data.key ~= key or type(data.level) ~= "table" then return nil end
	local lv = data.level
	if type(lv.games) ~= "table" and type(lv.error) ~= "string" then return nil end
	return lv
end

-- Playing (worker side) --------------------------------------------------------

-- Plays N games of one level; returns a compact result for the merge:
--   {id, file, difficulty, moves, n, games = {{m, r, t, e, sp}}, secs, evals}
-- `opts.base` (an earlier result of the same level and settings with fewer
-- games) is extended: only the seeds after its last game are played.
-- A game that raises an error stops the level with an error naming the seed.
function Tune.run_level(entry, opts)
	local Run = require("tools.bot.run")
	local n = opts.n or 100
	local bot = opts.bot or "greedy"
	local budget = opts.budget or Tune.DEFAULT_BUDGET
	local base = opts.base
	local t0 = common.clock()
	local games, evals, spent = {}, 0, 0
	if base then
		for i = 1, #base.games do games[i] = base.games[i] end
		evals, spent = base.evals or 0, base.secs or 0
	end
	for seed = #games + 1, n do
		local ok, rec = pcall(Run.play, entry, { seed = seed, bot_seed = seed, bot = bot, budget = budget })
		if not ok then
			error(string.format("seed %d (luajit tools/bot/run.lua %s --seed %d --bot %s --budget %d): %s",
				seed, tostring(entry.id), seed, bot, budget, tostring(rec)), 0)
		end
		local r = {}
		for k = 1, math.min(#rec.remaining, Tune.MAX_M) do r[k] = rec.remaining[k] end
		local sp = 0
		for k = 1, math.min(rec.moves_to_win or #rec.specials, Tune.MAX_M) do sp = sp + (rec.specials[k] or 0) end
		games[seed] = { m = rec.moves_to_win, r = r, t = rec.ticks_to_win, e = rec.ending, sp = sp }
		evals = evals + rec.evals
	end
	local secs = spent + common.clock() - t0
	return {
		id = entry.id, file = entry.path, difficulty = entry.difficulty, moves = entry.moves,
		n = n, games = games, secs = secs, evals = evals,
	}
end

-- A saved result cut to its first n games (seconds and clones scaled alike),
-- or nil when it has fewer than n games. Does not change `res`.
function Tune.fit(res, n)
	if type(res.games) ~= "table" or #res.games < n then return nil end
	if #res.games == n then return res end
	local out = {}
	for k, v in pairs(res) do out[k] = v end -- order-independent (copy)
	local games = {}
	for i = 1, n do games[i] = res.games[i] end
	local ratio = n / #res.games
	out.games, out.n = games, n
	out.secs = (res.secs or 0) * ratio
	out.evals = math.floor((res.evals or 0) * ratio + 0.5)
	return out
end

-- A saved result as the answer for n games, or nil when games must be
-- played. A saved failure holds for any n at least as large as the one it
-- was found with (the failing seed is among those games); for a smaller n
-- the failing seed may not be played, so it is tried again.
function Tune.reuse(saved, n)
	if not saved then return nil end
	if saved.error then
		if saved.n == nil or n >= saved.n then return saved end
		return nil
	end
	return Tune.fit(saved, n)
end

-- Runs the levels of `files` in this process. `log` gets progress lines. With
-- opts.work every result (also an error) is saved there under its key.
function Tune.run_files(files, opts, log)
	local out = {}
	opts.n = opts.n or 100
	opts.bot = opts.bot or "greedy"
	opts.budget = opts.budget or Tune.DEFAULT_BUDGET
	for k = 1, #files do
		local file = files[k]
		local text, rerr = common.read_file(file)
		local res, entry
		if not text then
			res = { file = file, error = "cannot read " .. file .. ": " .. tostring(rerr) }
		else
			local errs
			entry, errs = common.entry_from_text(text, file)
			if not entry then res = { file = file, error = table.concat(errs, "; ") } end
		end
		local key = text and opts.work and Tune.run_key(text, opts) or nil
		if entry then
			local saved = key and not opts.fresh and Tune.load_result(opts.work, file, key) or nil
			local full = Tune.reuse(saved, opts.n)
			if full then
				res = full
				res.cached = true
				res.file, res.id, res.difficulty, res.moves = file, entry.id, entry.difficulty, entry.moves
			else
				local ok, played = pcall(Tune.run_level, entry, {
					n = opts.n, budget = opts.budget, bot = opts.bot,
					base = saved and saved.games and saved or nil,
				})
				if ok then
					res = played
				else
					res = { id = entry.id, file = file, difficulty = entry.difficulty, moves = entry.moves,
						n = opts.n, error = "game error: " .. tostring(played) }
				end
			end
		end
		if text then
			res.sig = common.level_sig(text)
			if key and not res.cached then
				local saved, serr = Tune.save_result(opts.work, file, key, res)
				if not saved and log then log("cannot save the result of " .. file .. ": " .. tostring(serr)) end
			end
		end
		out[#out + 1] = res
		if log then
			if res.error then
				log(string.format("%d/%d %s: %s", k, #files, file, res.error))
			else
				local mtw = {}
				for _, g in ipairs(res.games) do if g.m then mtw[#mtw + 1] = g.m end end
				log(string.format("%d/%d level %3d %-10s %d games in %6.1f s (%.1f games/s), median moves_to_win %s%s",
					k, #files, res.id, res.difficulty, res.n, res.secs, res.n / math.max(res.secs, 1e-9),
					tostring(common.median(mtw)), res.cached and " (cached)" or ""))
			end
		end
	end
	return out
end

-- Splits levels into K disjoint subsets with similar estimated cost
-- (difficulty x board cells; longest first to the lightest subset). Measured
-- on levels 1-70: within 5% of the best split.
local COST = { easy = 1, medium = 1.5, hard = 2, super_hard = 3 }
function Tune.partition(files, k)
	local items = {}
	for i = 1, #files do
		local cost = 1
		local text = common.read_file(files[i])
		local raw = text and common.decode(text)
		if type(raw) == "table" and type(raw.size) == "table" and raw.difficulty then
			cost = (COST[raw.difficulty] or 1) * (tonumber(raw.size[1]) or 1) * (tonumber(raw.size[2]) or 1)
		end
		items[i] = { file = files[i], cost = cost, i = i }
	end
	table.sort(items, function(a, b)
		if a.cost ~= b.cost then return a.cost > b.cost end
		return a.i < b.i
	end)
	local parts, load = {}, {}
	for j = 1, k do parts[j], load[j] = {}, 0 end
	for _, it in ipairs(items) do
		local best = 1
		for j = 2, k do if load[j] < load[best] then best = j end end
		parts[best][#parts[best] + 1] = it.file
		load[best] = load[best] + it.cost
	end
	for j = 1, k do table.sort(parts[j]) end
	return parts
end

local shell_quote = common.shell_quote

local function find_vm(pref)
	if pref then return pref end
	local p = io.popen("command -v luajit 2>/dev/null")
	local path = p and p:read("*l")
	if p then p:close() end
	if path and path ~= "" then return "luajit" end
	return (arg and arg[-1]) or "lua5.1"
end

-- Runs the files over `jobs` worker processes and waits for all of them.
-- The results are in the work directory afterwards (run.work). Returns the
-- number of workers that did not report a clean finish.
function Tune.run_workers(files, run, jobs, vm, log)
	local parts = Tune.partition(files, jobs)
	local script = ROOT .. "tools/bot/tune.lua"
	local handles = {}
	for j = 1, jobs do
		if #parts[j] > 0 then
			local args = {
				vm, shell_quote(script), "--worker", "--wid", tostring(j),
				"--files", shell_quote(table.concat(parts[j], ",")),
				"--n", tostring(run.n), "--budget", tostring(run.budget), "--bot", run.bot,
				"--work", shell_quote(run.work), "--code", shell_quote(run.code or "-"),
			}
			if run.quiet then args[#args + 1] = "--quiet" end
			local p, err = io.popen(table.concat(args, " "), "r")
			if p then
				handles[#handles + 1] = { j = j, p = p }
			elseif log then
				log("worker " .. j .. " could not be started: " .. tostring(err))
			end
		end
	end
	local failed = 0
	for _, h in ipairs(handles) do
		local text = h.p:read("*a") or ""
		h.p:close()
		if not text:find("done %d+%s*$") then
			failed = failed + 1
			if log then log("worker " .. h.j .. " did not finish cleanly" .. (text ~= "" and (": " .. text:sub(1, 300)) or "")) end
		end
	end
	return failed
end

-- The results of all `files` in their order: from the work-directory cache,
-- played in this process, or played by workers. Anything that did not come
-- back is a row with an `error`. `run`: n, budget, bot, work, code, jobs, vm,
-- quiet, fresh. Returns results, counts {cached, played, missing}.
function Tune.collect(files, run, log)
	local results, keys, todo = {}, {}, {}
	local counts = { cached = 0, played = 0, missing = 0 }
	for i, f in ipairs(files) do
		local text, rerr = common.read_file(f)
		if not text then
			results[f] = { file = f, error = "cannot read " .. f .. ": " .. tostring(rerr) }
		else
			keys[f] = Tune.run_key(text, run)
			local saved = run.work and not run.fresh and Tune.load_result(run.work, f, keys[f]) or nil
			local cached = Tune.reuse(saved, run.n)
			if cached then
				local raw = common.decode(text)
				cached.file = f
				cached.sig = common.level_sig(text)
				if type(raw) == "table" then
					cached.id, cached.difficulty, cached.moves = raw.id, raw.difficulty, raw.moves
				end
				cached.cached = true
				results[f] = cached
				counts.cached = counts.cached + 1
			else
				todo[#todo + 1] = f
			end
		end
	end
	if #todo > 0 then
		local jobs = math.max(1, math.min(run.jobs or 1, #todo))
		if jobs == 1 and not run.vm then
			for _, r in ipairs(Tune.run_files(todo, run, log)) do
				results[r.file] = r
				counts.played = counts.played + 1
			end
		else
			assert(run.work, "tune: worker processes need a work directory")
			Tune.run_workers(todo, run, jobs, find_vm(run.vm), log)
			for _, f in ipairs(todo) do
				local r = Tune.load_result(run.work, f, keys[f])
				r = Tune.reuse(r, run.n)
				if r then
					r.file = f
					results[f] = r
					counts.played = counts.played + 1
				else
					results[f] = { file = f, error = "no result: the worker died or did not reach this level" }
					counts.missing = counts.missing + 1
				end
			end
		end
	end
	local out = {}
	for i, f in ipairs(files) do out[i] = results[f] end
	return out, counts
end

-- Merge, choice, reports -------------------------------------------------------

-- Rows (one per level, sorted by id) from the results of Tune.collect.
-- Fields added to the result of Tune.choose: file, id, difficulty, moves, n,
-- secs, evals, sig, mtw (sorted moves_to_win of the winners), no_win,
-- endings {won, budget, stuck, timeout}, specials_per_game, median_win_ticks.
function Tune.evaluate(results)
	local rows = {}
	for _, lv in ipairs(results) do
		local row = { file = lv.file, id = lv.id, difficulty = lv.difficulty, moves = lv.moves, sig = lv.sig }
		if lv.error then
			row.error = lv.error
			row.flags = { "invalid" }
		elseif type(lv.games) ~= "table" or #lv.games == 0 then
			row.error = "no games were played"
			row.flags = { "invalid" }
		else
			local ch = Tune.choose(lv.games, lv.difficulty, lv.moves)
			for k, v in pairs(ch) do row[k] = v end -- order-independent (copy)
			row.n, row.secs, row.evals = lv.n, lv.secs, lv.evals
			local mtw, nowin, sp, dur = {}, 0, 0, {}
			local endings = { won = 0, budget = 0, stuck = 0, timeout = 0 }
			for _, g in ipairs(lv.games) do
				if g.m then mtw[#mtw + 1] = g.m else nowin = nowin + 1 end
				if g.m and g.m <= ch.M and g.t then dur[#dur + 1] = g.t end
				sp = sp + (g.sp or 0)
				if g.e then endings[g.e] = (endings[g.e] or 0) + 1 end
			end
			table.sort(mtw) -- numbers
			row.mtw, row.no_win, row.endings = mtw, nowin, endings
			row.specials_per_game = sp / math.max(1, #lv.games)
			row.median_win_ticks = common.median(dur)
			if endings.stuck + endings.timeout > 0 then row.flags[#row.flags + 1] = "stuck_games" end
		end
		rows[#rows + 1] = row
	end
	table.sort(rows, function(a, b)
		if (a.id or 1e9) ~= (b.id or 1e9) then return (a.id or 1e9) < (b.id or 1e9) end
		return a.file < b.file
	end)
	return rows
end

Tune.FLAG_ORDER = { "too_hard", "too_easy", "off_corridor", "outside_band", "near_miss_low", "stuck_games", "invalid" }

local FLAG_RU = {
	too_hard = "недостижим: слишком сложно",
	too_easy = "недостижим: слишком легко",
	off_corridor = "мимо коридора",
	outside_band = "M вне 20–35",
	near_miss_low = "мало близких проигрышей",
	stuck_games = "партии в тупике или зависли",
	invalid = "ошибка уровня",
}

local function pct(v)
	if v == nil then return "—" end
	return string.format("%d%%", math.floor(v * 100 + 0.5))
end

-- Plan counts of difficulties for 100 levels (levels-plan 1).
Tune.PLAN_100 = { easy = 52, medium = 27, hard = 16, super_hard = 5 }

-- Seconds per game by difficulty; super_hard without data = hard x 1.5.
function Tune.projection(rows, levels, n, jobs)
	local sum, cnt, all_s, all_n = {}, {}, 0, 0
	for _, r in ipairs(rows) do
		if r.secs and r.n and r.n > 0 then
			sum[r.difficulty] = (sum[r.difficulty] or 0) + r.secs
			cnt[r.difficulty] = (cnt[r.difficulty] or 0) + r.n
			all_s, all_n = all_s + r.secs, all_n + r.n
		end
	end
	if all_n == 0 then return nil end
	local spg = {}
	for d in pairs(Tune.PLAN_100) do -- order-independent (a map)
		spg[d] = cnt[d] and sum[d] / cnt[d] or nil
	end
	spg.easy = spg.easy or all_s / all_n
	spg.medium = spg.medium or spg.easy
	spg.hard = spg.hard or spg.medium
	spg.super_hard = spg.super_hard or spg.hard * 1.5
	local total = 0
	for d, c in pairs(Tune.PLAN_100) do -- order-independent (a sum)
		total = total + c * (levels / 100) * n * spg[d]
	end
	return { cpu = total, wall = total / jobs, spg = spg }
end

function Tune.report_md(rows, meta)
	local L = {}
	L[#L + 1] = "# Подбор ходов ботом"
	L[#L + 1] = ""
	L[#L + 1] = string.format("Прогон: бот `%s`, %d партий на уровень (сиды игры и бота 1..%d, общие для всех уровней), "
		.. "бюджет %d ходов, %d процесс(а) `%s`, %.0f с, ядро %s%s. %s",
		meta.bot, meta.n, meta.n, meta.budget, meta.jobs, meta.vm, meta.wall, tostring(meta.core_version),
		meta.dir and (", каталог `" .. meta.dir .. "`") or "",
		meta.applied and "Ходы записаны в файлы уровней (`--write`)." or "**Пробный прогон:** файлы уровней не изменены.")
	L[#L + 1] = ""
	L[#L + 1] = "Коридоры доли побед с первой попытки (`levels-plan.md`): easy 85–95% (цель 90%), medium 60–75% (68%), "
		.. "hard 35–50% (42%), super_hard 20–30% (25%). M выбирается в 5..60 так, чтобы доля партий с `moves_to_win ≤ M` "
		.. "была ближе всего к цели. «Близкие проигрыши» — доля проигрышей при M, у которых после M ходов осталось ≤ 20% целей "
		.. "(среднее по целям). «Медиана» — ходы победителей при M."
	L[#L + 1] = ""
	L[#L + 1] = "| id | сложность | ходы было → стало | побед при M | побед было | попыток | близкие проигрыши | медиана | время, с | флаги |"
	L[#L + 1] = "|---:|---|---|---:|---:|---:|---:|---:|---:|---|"
	for _, r in ipairs(rows) do
		if r.error then
			L[#L + 1] = string.format("| %s | %s | %s | — | — | — | — | — | — | %s: %s |",
				tostring(r.id or "?"), tostring(r.difficulty or "?"), tostring(r.moves or "?"),
				FLAG_RU.invalid, (r.error:gsub("[|\n]", " ")))
		else
			local flags = {}
			for _, f in ipairs(r.flags) do flags[#flags + 1] = FLAG_RU[f] or f end
			L[#L + 1] = string.format("| %d | %s | %s → %d | %s | %s | %s | %s | %s | %.1f | %s |",
				r.id, r.difficulty, tostring(r.moves or "?"), r.M, pct(r.p), pct(r.p_before),
				r.attempts and string.format("%.2f", r.attempts) or "∞",
				r.near_miss and pct(r.near_miss) or "—",
				r.median and tostring(r.median) or "—", r.secs, table.concat(flags, "; "))
		end
	end
	local counts, total_secs, games = {}, 0, 0
	for _, r in ipairs(rows) do
		for _, f in ipairs(r.flags or {}) do counts[f] = (counts[f] or 0) + 1 end
		total_secs, games = total_secs + (r.secs or 0), games + (r.n or 0)
	end
	L[#L + 1] = ""
	L[#L + 1] = "## Итог"
	L[#L + 1] = ""
	L[#L + 1] = string.format("- Уровней: %d, партий: %d, процессорное время %.0f с (%.2f партии/с на процесс).",
		#rows, games, total_secs, games / math.max(total_secs, 1e-9))
	local fl = {}
	for _, f in ipairs(Tune.FLAG_ORDER) do
		if counts[f] then fl[#fl + 1] = string.format("%s — %d", FLAG_RU[f], counts[f]) end
	end
	L[#L + 1] = "- Флаги: " .. (#fl > 0 and table.concat(fl, ", ") or "нет") .. "."
	if meta.projection then
		local p = meta.projection
		L[#L + 1] = string.format("- Прогноз для 100 уровней, N = 300, 3 процесса: ~%.0f мин (процессорное время ~%.0f мин; "
			.. "с/партию: easy %.2f, medium %.2f, hard %.2f, super_hard %.2f%s).",
			p.wall / 60, p.cpu / 60, p.spg.easy, p.spg.medium, p.spg.hard, p.spg.super_hard,
			meta.sh_assumed and " — оценка: hard × 1,5" or "")
	end
	L[#L + 1] = ""
	return table.concat(L, "\n")
end

local function copy_array(a)
	local t = {}
	for i = 1, #a do t[i] = a[i] end
	return t
end

function Tune.report_json(rows, meta)
	local levels = {}
	for _, r in ipairs(rows) do
		local o = { id = r.id, file = r.file, difficulty = r.difficulty, moves_before = r.moves, flags = copy_array(r.flags) }
		if r.error then
			o.error = r.error
		else
			o.moves_after = r.M
			o.win_rate = common.round(r.p, 4)
			o.win_rate_before = r.p_before and common.round(r.p_before, 4) or nil
			o.attempts = r.attempts and common.round(r.attempts, 3) or nil
			o.near_miss = r.near_miss and common.round(r.near_miss, 4) or nil
			o.losses = r.losses
			o.median_moves = r.median
			o.corridor = { lo = r.corridor.lo, hi = r.corridor.hi, target = r.corridor.target }
			o.win_rate_at_5 = common.round(r.p5, 4)
			o.win_rate_at_60 = common.round(r.p60, 4)
			o.moves_to_win = copy_array(r.mtw)
			o.no_win = r.no_win
			o.endings = r.endings
			o.games = r.n
			o.specials_per_game = common.round(r.specials_per_game, 2)
			o.median_win_ticks = r.median_win_ticks
			o.secs = common.round(r.secs, 2)
		end
		levels[#levels + 1] = o
	end
	return common.encode({
		tool = "tools/bot/tune.lua", bot = meta.bot, n = meta.n, budget = meta.budget, core_version = meta.core_version,
		applied = meta.applied, dir = meta.dir, levels = levels,
	}, "  ") .. "\n"
end

-- --write: replaces only the moves value of each tuned level file. A file
-- that changed since it was played (signature of the text without the move
-- limit), has no single "moves" key, or would not load with the new value is
-- skipped. Returns the number of files changed and the number skipped.
function Tune.write_moves(rows, log)
	local core = require("core.game")
	local changed, skipped = 0, 0
	local function skip(file, why)
		skipped = skipped + 1
		if log then log(file .. ": not written: " .. why) end
	end
	for _, r in ipairs(rows) do
		if not r.error and r.M then
			local text, rerr = common.read_file(r.file)
			if not text then
				skip(r.file, "cannot read: " .. tostring(rerr))
			elseif r.sig and common.level_sig(text) ~= r.sig then
				skip(r.file, "the file changed since the games were played")
			else
				local cur, why = common.find_moves(text)
				if not cur then
					skip(r.file, why)
				elseif cur ~= r.M then
					local new = common.set_moves(text, r.M)
					local lvl, errs = core.load_level(new)
					if not lvl then
						skip(r.file, table.concat(errs, "; "))
					else
						local ok, werr = common.write_file_atomic(r.file, new)
						if not ok then
							skip(r.file, "write failed: " .. tostring(werr))
						else
							changed = changed + 1
							if log then log(string.format("%s: moves %d -> %d", r.file, cur, r.M)) end
						end
					end
				end
			end
		end
	end
	return changed, skipped
end

-- CLI --------------------------------------------------------------------------

local USAGE = "usage: luajit tools/bot/tune.lua [--n 100] [--jobs 3] [--bot greedy|strong] [--budget 120]"
	.. " [--levels 1-40] [--dir content/levels] [--write] [--work dir] [--fresh] [--force]"
	.. " [--md path] [--json path] [--no-report] [--vm luajit] [--quiet]"

local FLAGS = {
	write = true, worker = true, ["no-report"] = true, help = true, quiet = true, force = true, fresh = true,
}
local VALUES = {
	n = true, jobs = true, bot = true, budget = true, levels = true, dir = true, md = true, json = true,
	vm = true, work = true, wid = true, files = true, code = true,
}

Tune.OPTIONS = { flags = FLAGS, values = VALUES }

local function worker_main(opts)
	local files = {}
	for f in (opts.files or ""):gmatch("[^,]+") do files[#files + 1] = f end
	local wid = opts.wid or "1"
	if not opts.work then
		io.stderr:write("[w" .. wid .. "] failed: --work is required for a worker\n")
		return 2
	end
	local log = nil
	if not opts.quiet then log = function(line) io.stderr:write("[w" .. wid .. "] " .. line .. "\n") end end
	local ok, err = pcall(Tune.run_files, files, {
		n = tonumber(opts.n or 100), budget = tonumber(opts.budget or Tune.DEFAULT_BUDGET), bot = opts.bot or "greedy",
		work = opts.work, code = opts.code,
	}, log)
	if not ok then
		io.stderr:write("[w" .. wid .. "] failed: " .. tostring(err) .. "\n")
		return 1
	end
	io.write("done ", #files, "\n")
	return 0
end

local function normalize_dir(d)
	d = d:gsub("/+$", ""):gsub("^%./", "")
	return d
end

local function temp_dir()
	local p = io.popen("mktemp -d 2>/dev/null")
	local d = p and p:read("*l")
	if p then p:close() end
	if d and d:match("^/.+") then return d end
	return nil
end

-- Level files to play: from --levels (ids; ids without a file are reported)
-- or every level file of the directory.
local function select_files(opts, dir, log)
	if not opts.levels then return common.level_files(dir) end
	local ids, perr = common.parse_ids(opts.levels)
	if not ids then return nil, "--levels: " .. perr end
	local files, missing, seen = {}, {}, {}
	for _, id in ipairs(ids) do
		local p = string.format("%s/level_%04d.json", dir, id)
		if seen[p] then
			-- a level named twice is played once
		elseif common.file_exists(p) then
			seen[p] = true
			files[#files + 1] = p
		else
			missing[#missing + 1] = tostring(id)
		end
	end
	if #missing > 0 and log then log("tune: no file for level(s) " .. table.concat(missing, ", ") .. " (skipped)") end
	return files
end

function Tune.main(argv)
	common.jit_opts()
	local opts, pos, perr = common.parse_args(argv, FLAGS, VALUES)
	local function usage_error(msg)
		io.stderr:write("tune: " .. msg .. "\n" .. USAGE .. "\n")
		return 2
	end
	if perr then return usage_error(perr) end
	if opts.help then
		print(USAGE)
		return 0
	end
	if #pos > 0 then return usage_error("unexpected argument '" .. pos[1] .. "'") end
	if opts.worker then return worker_main(opts) end

	local n, e1 = common.int_option(opts, "n", 100, 1, 100000)
	local jobs, e2 = common.int_option(opts, "jobs", 1, 1, 64)
	local budget, e3 = common.int_option(opts, "budget", Tune.DEFAULT_BUDGET, Tune.MAX_M, 100000)
	local bad = e1 or e2 or e3
	local bot = opts.bot or "greedy"
	if not bad and not require("tools.bot.bot").KINDS[bot] then bad = "--bot: greedy or strong expected, got '" .. bot .. "'" end
	if not bad and opts.write and n < Tune.MIN_N_WRITE and not opts.force then
		bad = string.format("--write with --n %d: a small N gives noisy limits (use --n %d or more, or --force)", n, Tune.MIN_N_WRITE)
	end
	if bad then return usage_error(bad) end

	local quiet = opts.quiet == true
	local log = function(line) if not quiet then io.stderr:write(line .. "\n") end end
	local dir = opts.dir or (ROOT .. Tune.DEFAULT_DIR)
	local files, serr = select_files(opts, dir, log)
	if not files then return usage_error(serr) end
	if #files == 0 then
		io.stderr:write("tune: no level files in " .. dir .. "\n")
		return 1
	end
	jobs = math.min(jobs, #files)

	-- work directory: kept when named, temporary (and removed) when workers need one
	local work, temp = opts.work, false
	if work then
		os.execute("mkdir -p " .. shell_quote(work))
	elseif jobs > 1 or opts.vm then
		work, temp = temp_dir(), true
		if not work then
			io.stderr:write("tune: cannot create a temporary directory\n")
			return 1
		end
	end
	if work then
		local probe = work .. "/.probe"
		if not common.write_file(probe, "x") then
			io.stderr:write("tune: the work directory " .. work .. " is not writable\n")
			return 1
		end
		os.remove(probe)
	end

	local code, cerr = Tune.code_fingerprint()
	if not code then
		io.stderr:write("tune: cannot read the sources to fingerprint: " .. tostring(cerr) .. "\n")
		return 1
	end
	local run = {
		n = n, budget = budget, bot = bot, work = work, code = code, jobs = jobs, vm = opts.vm,
		quiet = quiet, fresh = opts.fresh == true,
	}
	local t0 = common.wall()
	local results, counts = Tune.collect(files, run, log)
	local wall = common.wall() - t0
	if temp then os.execute("rm -rf " .. shell_quote(work)) end

	local vm = (jobs == 1 and not opts.vm) and common.vm_name() or find_vm(opts.vm)
	local rows = Tune.evaluate(results)
	local proj = Tune.projection(rows, 100, 300, 3)
	local sh = true
	for _, r in ipairs(rows) do if r.difficulty == "super_hard" and r.secs then sh = false end end
	local custom_dir = opts.dir ~= nil and normalize_dir(opts.dir) ~= Tune.DEFAULT_DIR
		and normalize_dir(opts.dir) ~= normalize_dir(ROOT .. Tune.DEFAULT_DIR)
	local meta = {
		bot = bot, n = n, budget = budget, jobs = jobs, vm = vm, wall = wall,
		applied = opts.write == true, projection = proj, sh_assumed = sh,
		core_version = require("core.game").VERSION, dir = custom_dir and dir or nil,
	}

	-- console table
	print(string.format("%4s %-10s %9s %6s %6s %8s %6s %6s %7s  %s",
		"id", "difficulty", "moves", "p(M)", "p(was)", "attempts", "near", "median", "secs", "flags"))
	local attention, invalid = {}, 0
	for _, r in ipairs(rows) do
		if r.error then
			invalid = invalid + 1
			print(string.format("%4s %-10s %9s  %s", tostring(r.id or "?"), tostring(r.difficulty or "?"), "-", "invalid: " .. r.error))
		else
			print(string.format("%4d %-10s %4d->%-3d %6s %6s %8s %6s %6s %7.1f  %s",
				r.id, r.difficulty, r.moves, r.M, pct(r.p), pct(r.p_before),
				r.attempts and string.format("%.2f", r.attempts) or "inf",
				r.near_miss and pct(r.near_miss) or "-", r.median and tostring(r.median) or "-", r.secs,
				table.concat(r.flags, ",")))
		end
		for _, f in ipairs(r.flags or {}) do
			attention[f] = attention[f] or {}
			attention[f][#attention[f] + 1] = tostring(r.id or basename(r.file))
		end
	end
	print(string.format("%d levels, %d games/level, wall %.1f s with %d job(s) (%s); %d played, %d from the cache, %d missing",
		#rows, n, wall, jobs, vm, counts.played, counts.cached, counts.missing))
	for _, f in ipairs(Tune.FLAG_ORDER) do
		if attention[f] then print(string.format("%-14s %d: %s", f, #attention[f], table.concat(attention[f], " "))) end
	end
	if proj then
		print(string.format("projection: 100 levels x N=300 x 3 jobs ~ %.1f min wall (%.1f min CPU)", proj.wall / 60, proj.cpu / 60))
	end

	if opts.write then
		local changed, skipped = Tune.write_moves(rows, log)
		print(string.format("--write: %d level file(s) changed, %d skipped", changed, skipped))
	end
	if not opts["no-report"] then
		local md = opts.md or (not custom_dir and (ROOT .. "docs/levels/tuning.md") or nil)
		local js = opts.json or (not custom_dir and (ROOT .. "docs/levels/tuning.json") or nil)
		if not md and not js then
			print("report: skipped (--dir is not " .. Tune.DEFAULT_DIR .. "; --md / --json name the files)")
		else
			local written = {}
			for _, item in ipairs({ { md, Tune.report_md }, { js, Tune.report_json } }) do
				local path, make = item[1], item[2]
				if path then
					os.execute("mkdir -p " .. shell_quote(path:match("^(.*)/") or "."))
					local ok, werr = common.write_file(path, make(rows, meta))
					if not ok then
						io.stderr:write("tune: cannot write " .. path .. ": " .. tostring(werr) .. "\n")
						return 1
					end
					written[#written + 1] = path
				end
			end
			print("report: " .. table.concat(written, ", "))
		end
	end
	return (invalid > 0 or counts.missing > 0) and 1 or 0
end

if MAIN then os.exit(Tune.main(arg or {})) end

return Tune
