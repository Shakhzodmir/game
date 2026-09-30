-- Move tuner: picks each level's move limit from the bot's moves-to-win
-- distribution (levels-plan 1, plan p.26 "автоподбор ходов").
--
--   luajit tools/bot/tune.lua [--n 100] [--jobs 3] [--bot greedy|strong]
--         [--budget 120] [--levels 1-40] [--dir content/levels] [--write]
--         [--md docs/levels/tuning.md] [--json <path>] [--no-report] [--vm luajit]
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
--   invalid       -- the level does not load (or a game raised a core error)
--
-- --jobs K runs K worker processes (luajit by default) over disjoint level
-- subsets through io.popen; each prints its results as JSON and the parent
-- merges them. Without --write nothing in content/levels changes: the
-- report goes to docs/levels/tuning.md and the machine-readable results to
-- docs/levels/tuning.json. With --write the "moves" value of every level
-- file is replaced in place (the rest of the file stays byte-identical) and
-- the results go to content/levels/tuning.json.

local MAIN = (...) ~= "tools.bot.tune"
local ROOT = ""
if MAIN then
	ROOT = (arg and arg[0] or ""):match("^(.-)tools[/\\]bot[/\\]tune%.lua$") or ""
	package.path = ROOT .. "?.lua;" .. ROOT .. "?/init.lua;" .. package.path
end

local common = require("tools.bot.common")

local Tune = {}

Tune.MIN_M, Tune.MAX_M = 5, 60
Tune.BAND_LO, Tune.BAND_HI = 20, 35
Tune.NEAR_MISS = 0.2
Tune.DEFAULT_BUDGET = 120

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

-- Playing (worker side) --------------------------------------------------------

-- Plays N games of one level; returns a compact result for the merge:
--   {id, file, difficulty, moves, n, games = {{m, r, t, e, sp}}, secs, evals}
function Tune.run_level(entry, opts)
	local Run = require("tools.bot.run")
	local n = opts.n or 100
	local t0 = common.clock()
	local games, evals = {}, 0
	for seed = 1, n do
		local rec = Run.play(entry, {
			seed = seed, bot_seed = seed, bot = opts.bot or "greedy",
			budget = opts.budget or Tune.DEFAULT_BUDGET,
		})
		local r = {}
		for k = 1, math.min(#rec.remaining, Tune.MAX_M) do r[k] = rec.remaining[k] end
		local sp = 0
		for k = 1, math.min(rec.moves_to_win or #rec.specials, Tune.MAX_M) do sp = sp + (rec.specials[k] or 0) end
		games[seed] = { m = rec.moves_to_win, r = r, t = rec.ticks_to_win, e = rec.ending, sp = sp }
		evals = evals + rec.evals
	end
	local secs = common.clock() - t0
	return {
		id = entry.id, file = entry.path, difficulty = entry.difficulty, moves = entry.moves,
		n = n, games = games, secs = secs, evals = evals,
	}
end

-- Runs the levels of `files` in this process. `log` gets progress lines.
function Tune.run_files(files, opts, log)
	local out = {}
	for k = 1, #files do
		local entry, errs = common.load_entry(files[k])
		if not entry then
			out[#out + 1] = { file = files[k], error = table.concat(errs, "; ") }
			if log then log(string.format("%s: invalid: %s", files[k], out[#out].error)) end
		else
			local ok, res = pcall(Tune.run_level, entry, opts)
			if not ok then
				-- a core error in some game: report the level, keep going
				res = { id = entry.id, file = files[k], difficulty = entry.difficulty, moves = entry.moves,
					error = "game error: " .. tostring(res) }
				if log then log(string.format("%s: %s", files[k], res.error)) end
			end
			out[#out + 1] = res
			if ok and log then
				local mtw = {}
				for _, g in ipairs(res.games) do if g.m then mtw[#mtw + 1] = g.m end end
				log(string.format("level %3d %-10s %d games in %6.1f s (%.1f games/s), median moves_to_win %s",
					res.id, res.difficulty, res.n, res.secs, res.n / math.max(res.secs, 1e-9),
					tostring(common.median(mtw))))
			end
		end
	end
	return out
end

-- Splits levels into K disjoint subsets with similar estimated cost
-- (difficulty x board cells; longest first to the lightest subset).
local COST = { easy = 1, medium = 1.5, hard = 2, super_hard = 3 }
function Tune.partition(files, k)
	local items = {}
	for i = 1, #files do
		local cost = 1
		local text = common.read_file(files[i])
		local raw = text and common.decode(text)
		if raw and raw.size and raw.difficulty then
			cost = (COST[raw.difficulty] or 1) * raw.size[1] * raw.size[2]
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

local function shell_quote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function find_vm(pref)
	if pref then return pref end
	local p = io.popen("command -v luajit 2>/dev/null")
	local path = p and p:read("*l")
	if p then p:close() end
	if path and path ~= "" then return "luajit" end
	return (arg and arg[-1]) or "lua5.1"
end

-- Runs the files over `jobs` worker processes; returns the merged results.
function Tune.run_parallel(files, opts, jobs, vm)
	local parts = Tune.partition(files, jobs)
	local script = ROOT .. "tools/bot/tune.lua"
	local handles = {}
	for j = 1, jobs do
		if #parts[j] > 0 then
			local cmd = table.concat({
				vm, shell_quote(script), "--worker", "--wid", tostring(j),
				"--files", shell_quote(table.concat(parts[j], ",")),
				"--n", tostring(opts.n), "--budget", tostring(opts.budget), "--bot", opts.bot,
			}, " ")
			handles[#handles + 1] = { j = j, p = assert(io.popen(cmd, "r")) }
		end
	end
	local out = {}
	for _, h in ipairs(handles) do
		local text = h.p:read("*a")
		h.p:close()
		local data = common.decode(text or "")
		if not data or not data.levels then
			error("worker " .. h.j .. " returned no results: " .. tostring(text):sub(1, 400))
		end
		for _, lv in ipairs(data.levels) do out[#out + 1] = lv end
	end
	return out
end

-- Merge, choice, reports -------------------------------------------------------

-- JSON turns absent m into a missing key: nothing to fix. Sorts by id.
function Tune.evaluate(results)
	local rows = {}
	for _, lv in ipairs(results) do
		local row = { file = lv.file, id = lv.id, difficulty = lv.difficulty, moves = lv.moves }
		if lv.error then
			row.error = lv.error
			row.flags = { "invalid" }
		else
			local ch = Tune.choose(lv.games, lv.difficulty, lv.moves)
			for k, v in pairs(ch) do row[k] = v end -- order-independent (copy)
			row.n, row.secs, row.evals = lv.n, lv.secs, lv.evals
			local mtw, nowin, sp, dur = {}, 0, 0, {}
			for _, g in ipairs(lv.games) do
				if g.m then mtw[#mtw + 1] = g.m else nowin = nowin + 1 end
				if g.m and g.m <= ch.M and g.t then dur[#dur + 1] = g.t end
				sp = sp + (g.sp or 0)
			end
			table.sort(mtw) -- numbers
			row.mtw, row.no_win = mtw, nowin
			row.specials_per_game = sp / math.max(1, #lv.games)
			row.median_win_ticks = common.median(dur)
		end
		rows[#rows + 1] = row
	end
	table.sort(rows, function(a, b)
		if (a.id or 1e9) ~= (b.id or 1e9) then return (a.id or 1e9) < (b.id or 1e9) end
		return a.file < b.file
	end)
	return rows
end

local FLAG_RU = {
	too_hard = "недостижим: слишком сложно",
	too_easy = "недостижим: слишком легко",
	off_corridor = "мимо коридора",
	outside_band = "M вне 20–35",
	near_miss_low = "мало близких проигрышей",
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
		.. "бюджет %d ходов, %d процесс(а) `%s`, %.0f с, ядро %s. %s",
		meta.bot, meta.n, meta.n, meta.budget, meta.jobs, meta.vm, meta.wall, tostring(meta.core_version),
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
			L[#L + 1] = string.format("| %d | %s | %d → %d | %s | %s | %s | %s | %s | %.1f | %s |",
				r.id, r.difficulty, r.moves, r.M, pct(r.p), pct(r.p_before),
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
	for _, f in ipairs({ "too_hard", "too_easy", "off_corridor", "outside_band", "near_miss_low", "invalid" }) do
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

function Tune.report_json(rows, meta)
	local levels = {}
	for _, r in ipairs(rows) do
		local o = { id = r.id, file = r.file, difficulty = r.difficulty, moves_before = r.moves, flags = r.flags }
		o.flags.__array = true
		if r.error then
			o.error = r.error
		else
			o.moves_after = r.M
			o.win_rate = common.round(r.p, 4)
			o.win_rate_before = common.round(r.p_before, 4)
			o.attempts = r.attempts and common.round(r.attempts, 3) or nil
			o.near_miss = r.near_miss and common.round(r.near_miss, 4) or nil
			o.losses = r.losses
			o.median_moves = r.median
			o.corridor = { lo = r.corridor.lo, hi = r.corridor.hi, target = r.corridor.target }
			o.win_rate_at_5 = common.round(r.p5, 4)
			o.win_rate_at_60 = common.round(r.p60, 4)
			o.moves_to_win = r.mtw
			o.moves_to_win.__array = true
			o.no_win = r.no_win
			o.games = r.n
			o.specials_per_game = common.round(r.specials_per_game, 2)
			o.median_win_ticks = r.median_win_ticks
			o.secs = common.round(r.secs, 2)
		end
		levels[#levels + 1] = o
	end
	levels.__array = true
	return common.encode({
		tool = "tools/bot/tune.lua", bot = meta.bot, n = meta.n, budget = meta.budget, core_version = meta.core_version,
		applied = meta.applied, levels = levels,
	}, "  ") .. "\n"
end

-- --write: replaces only the moves value of each level file.
function Tune.write_moves(rows, log)
	local core = require("core.game")
	local changed = 0
	for _, r in ipairs(rows) do
		if not r.error and r.M then
			local text = assert(common.read_file(r.file))
			local cur = common.find_moves(text)
			if cur ~= r.M then
				local new = common.set_moves(text, r.M)
				local lvl, errs = core.load_level(new)
				if not lvl then
					if log then log(r.file .. ": not written: " .. table.concat(errs, "; ")) end
				else
					assert(common.write_file(r.file, new))
					changed = changed + 1
					if log then log(string.format("%s: moves %d -> %d", r.file, cur, r.M)) end
				end
			end
		end
	end
	return changed
end

-- CLI --------------------------------------------------------------------------

local function worker_main(opts)
	local files = {}
	for f in (opts.files or ""):gmatch("[^,]+") do files[#files + 1] = f end
	local wid = opts.wid or "1"
	local levels = Tune.run_files(files, {
		n = tonumber(opts.n or 100), budget = tonumber(opts.budget or Tune.DEFAULT_BUDGET), bot = opts.bot or "greedy",
	}, function(line) io.stderr:write("[w" .. wid .. "] " .. line .. "\n") end)
	for _, lv in ipairs(levels) do
		if lv.games then
			for _, g in ipairs(lv.games) do g.r.__array = true end
			lv.games.__array = true
		end
	end
	levels.__array = true
	io.write(common.encode({ levels = levels }), "\n")
	return 0
end

function Tune.main(argv)
	common.jit_opts()
	local opts = common.parse_args(argv, { write = true, worker = true, ["no-report"] = true, help = true, quiet = true })
	if opts.help then
		print("usage: luajit tools/bot/tune.lua [--n 100] [--jobs 3] [--bot greedy|strong] [--budget 120]"
			.. " [--levels 1-40] [--dir content/levels] [--write] [--md path] [--json path] [--no-report] [--vm luajit]")
		return 0
	end
	if opts.worker then return worker_main(opts) end
	local dir = opts.dir or (ROOT .. "content/levels")
	local files = {}
	if opts.levels then
		for _, id in ipairs(common.parse_ids(opts.levels)) do
			local p = string.format("%s/level_%04d.json", dir, id)
			if common.file_exists(p) then files[#files + 1] = p end
		end
	else
		files = common.level_files(dir)
	end
	if #files == 0 then
		io.stderr:write("tune: no level files\n")
		return 1
	end
	local run = {
		n = tonumber(opts.n or 100), budget = tonumber(opts.budget or Tune.DEFAULT_BUDGET), bot = opts.bot or "greedy",
	}
	if run.budget < Tune.MAX_M then
		io.stderr:write("tune: --budget must be at least " .. Tune.MAX_M .. "\n")
		return 1
	end
	local jobs = math.max(1, math.min(tonumber(opts.jobs or 1), #files))
	local log = function(line) if not opts.quiet then io.stderr:write(line .. "\n") end end
	local t0 = common.wall()
	local results, vm
	if jobs == 1 and not opts.vm then
		vm = common.vm_name()
		results = Tune.run_files(files, run, log)
	else
		vm = find_vm(opts.vm)
		results = Tune.run_parallel(files, run, jobs, vm)
	end
	local wall = common.wall() - t0
	local rows = Tune.evaluate(results)
	local proj = Tune.projection(rows, 100, 300, 3)
	local sh = true
	for _, r in ipairs(rows) do if r.difficulty == "super_hard" and r.secs then sh = false end end
	local meta = {
		bot = run.bot, n = run.n, budget = run.budget, jobs = jobs, vm = vm, wall = wall,
		applied = opts.write == true, projection = proj, sh_assumed = sh,
		core_version = require("core.game").VERSION,
	}
	-- console table
	print(string.format("%4s %-10s %9s %6s %6s %8s %6s %6s %7s  %s",
		"id", "difficulty", "moves", "p(M)", "p(was)", "attempts", "near", "median", "secs", "flags"))
	for _, r in ipairs(rows) do
		if r.error then
			print(string.format("%4s %-10s %9s  %s", tostring(r.id or "?"), tostring(r.difficulty or "?"), "-", "invalid: " .. r.error))
		else
			print(string.format("%4d %-10s %4d->%-3d %6s %6s %8s %6s %6s %7.1f  %s",
				r.id, r.difficulty, r.moves, r.M, pct(r.p), pct(r.p_before),
				r.attempts and string.format("%.2f", r.attempts) or "inf",
				r.near_miss and pct(r.near_miss) or "-", r.median and tostring(r.median) or "-", r.secs,
				table.concat(r.flags, ",")))
		end
	end
	print(string.format("%d levels, %d games/level, wall %.1f s with %d job(s) (%s)", #rows, run.n, wall, jobs, vm))
	if proj then
		print(string.format("projection: 100 levels x N=300 x 3 jobs ~ %.1f min wall (%.1f min CPU)", proj.wall / 60, proj.cpu / 60))
	end
	if opts.write then
		local n = Tune.write_moves(rows, log)
		print(string.format("--write: %d level file(s) changed", n))
	end
	if not opts["no-report"] then
		local md = opts.md or (ROOT .. "docs/levels/tuning.md")
		local js = opts.json or (opts.write and (dir .. "/tuning.json") or (ROOT .. "docs/levels/tuning.json"))
		os.execute("mkdir -p " .. shell_quote(md:match("^(.*)/") or "."))
		os.execute("mkdir -p " .. shell_quote(js:match("^(.*)/") or "."))
		assert(common.write_file(md, Tune.report_md(rows, meta)))
		assert(common.write_file(js, Tune.report_json(rows, meta)))
		print("report: " .. md .. ", " .. js)
	end
	return 0
end

if MAIN then os.exit(Tune.main(arg or {})) end

return Tune
