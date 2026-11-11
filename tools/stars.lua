-- Star thresholds of the levels, from reference games of the bots (reproducible: fixed seeds).
--
--   luajit tools/stars.lua gen [--jobs 4] [--out content/levels/stars.json] [--dir content/levels] [ids...]
--   luajit tools/stars.lua check [--dir content/levels] [--stars content/levels/stars.json] [--replay]
--
-- gen: for every level plays games with the level's own move limit, alternating the greedy and the strong
-- bot (game g: bot greedy for odd g, strong for even; game seed and bot seed = SEED_BASE + g), up to
-- MAX_GAMES games until MIN_WINS wins are in. A win's score is the score of the finished game (the final
-- concert included: moves left pay). From the sorted winning scores:
--   normal level   t1 = P15, t2 = P50, t3 = P90
--   concert level  t1 = P25, t2 = P65, t3 = P95   (a concert asks more of the same level)
-- rounded to 100 (t3 rounded down, so the best game always reaches it) and forced to grow by >= 100.
-- Entries also keep `best` (max score), `witness` = {bot, seed} of that game, `wins`/`games`, `share3`
-- (the part of the won games at or above t3, per mille) and `sig` (checksum of the level file).
-- check: the file against the level files (see Stars.check); --replay plays every witness again.

local MAIN = (...) ~= "tools.stars"
local ROOT = ""
if MAIN then
	ROOT = (arg and arg[0] or ""):match("^(.-)tools[/\\]stars%.lua$")
	if not ROOT then ROOT = ((arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or ".") .. "/../" end
	package.path = ROOT .. "?.lua;" .. ROOT .. "?/init.lua;" .. package.path
end

local common = require("tools.bot.common")
local stars = require("meta.stars")

local Stars = {}

Stars.SEED_BASE = 4100
Stars.MIN_GAMES = 40
Stars.MIN_WINS = 14
Stars.MAX_GAMES = 200
Stars.QUANTILES = {
	normal = { 0.15, 0.50, 0.90 },
	concert = { 0.25, 0.65, 0.95 },
}
-- The concert levels: the super hard ones that close each block of ten from 60 on (levels-plan.md, 1).
Stars.CONCERT = { [60] = true, [70] = true, [80] = true, [90] = true, [100] = true }
Stars.MAX_SHARE3 = 300 -- per mille of the won games that may reach t3 ("not trivial")
Stars.MIN_REPLAYS = 1

local function play(entry, g)
	local Run = require("tools.bot.run")
	local seed = Stars.SEED_BASE + g
	local bot = g % 2 == 1 and "greedy" or "strong"
	local r = Run.play(entry, { seed = seed, bot = bot, bot_seed = seed, budget = entry.moves, finish = true })
	return r, bot, seed
end

local function quantile(sorted, q)
	local n = #sorted
	local pos = math.floor(q * (n - 1) + 0.5) + 1
	return sorted[math.max(1, math.min(n, pos))]
end

local function round100(v, down)
	if down then return math.floor(v / 100) * 100 end
	return math.floor(v / 100 + 0.5) * 100
end

-- The score of the first game of `bot` with seed g that wins the level, or nil.
local function Run_play_first_win(entry, g, bot)
	local Run = require("tools.bot.run")
	local seed = Stars.SEED_BASE + 1000 + g
	local r = Run.play(entry, { seed = seed, bot = bot, bot_seed = seed, budget = entry.moves, finish = true })
	return r.won and r.score or nil
end

-- The thresholds of sorted winning scores for a kind: {t1, t2, t3}.
function Stars.thresholds(sorted, kind)
	local q = Stars.QUANTILES[kind]
	local t1 = math.max(100, round100(quantile(sorted, q[1])))
	local t2 = math.max(t1 + 100, round100(quantile(sorted, q[2])))
	local t3 = math.max(t2 + 100, round100(quantile(sorted, q[3]), true))
	return { t1, t2, t3 }
end

-- The entry of one level.
function Stars.level(entry)
	local scores, best, witness = {}, -1, nil
	local games = 0
	while games < Stars.MAX_GAMES and (games < Stars.MIN_GAMES or #scores < Stars.MIN_WINS) do
		games = games + 1
		local r, bot, seed = play(entry, games)
		if r.won and r.score then
			scores[#scores + 1] = r.score
			if r.score > best then best, witness = r.score, { bot, seed } end
		end
	end
	if #scores < 3 then return nil, "level " .. entry.id .. ": only " .. #scores .. " wins in " .. games .. " games" end
	table.sort(scores)
	local kind = Stars.CONCERT[entry.id] and "concert" or "normal"
	local t = Stars.thresholds(scores, kind)
	if t[3] > best then t[3] = round100(best, true) end
	local above = 0
	for _, v in ipairs(scores) do if v >= t[3] then above = above + 1 end end
	return {
		kind = kind, t = t, best = best, witness = witness, wins = #scores, games = games,
		share3 = math.floor(above * 1000 / #scores + 0.5), sig = common.checksum(entry.text),
	}
end

-- Output ----------------------------------------------------------------------

local function line(id, e)
	return string.format('"%d":{"kind":"%s","t":[%d,%d,%d],"best":%d,"witness":["%s",%d],"wins":%d,"games":%d,"share3":%d,"sig":"%s"}',
		id, e.kind, e.t[1], e.t[2], e.t[3], e.best, e.witness[1], e.witness[2], e.wins, e.games, e.share3, e.sig)
end

function Stars.encode(levels)
	local ids = {}
	for id in pairs(levels) do ids[#ids + 1] = id end -- order-free: sorted below
	table.sort(ids)
	local rows = {}
	for _, id in ipairs(ids) do rows[#rows + 1] = "  " .. line(id, levels[id]) end
	return string.format('{"version":1,"seed_base":%d,"levels":{\n%s\n}}\n', Stars.SEED_BASE, table.concat(rows, ",\n"))
end

local function load_levels(dir, ids)
	local files = common.level_files(dir)
	local want
	if ids and #ids > 0 then
		want = {}
		for _, id in ipairs(ids) do want[id] = true end
	end
	local out = {}
	for _, f in ipairs(files) do
		local n = tonumber(f:match("level_(%d+)%.json$"))
		if n and (not want or want[n]) then
			local entry, errs = common.load_entry(f)
			if not entry then error(f .. ": " .. table.concat(errs, "; ")) end
			out[#out + 1] = entry
		end
	end
	return out
end

-- Check ---------------------------------------------------------------------

-- Problems of the stars file against the level files: array of strings. opts.replay plays each
-- witness again and compares its score with `best` (and with t3).
function Stars.check(data, dir, opts)
	opts = opts or {}
	local errs = {}
	if type(data) ~= "table" or data.version ~= 1 or type(data.levels) ~= "table" then
		return { "stars.json: version 1 and a levels table expected" }
	end
	local entries = load_levels(dir)
	local seen = {}
	for _, entry in ipairs(entries) do
		local id = entry.id
		seen[tostring(id)] = true
		local e = data.levels[tostring(id)]
		local function bad(msg) errs[#errs + 1] = "level " .. id .. ": " .. msg end
		if not e then
			bad("no star thresholds")
		else
			for _, m in ipairs(stars.check_entry(e)) do bad(m) end
			if #stars.check_entry(e) == 0 then
				if e.sig ~= common.checksum(entry.text) then bad("the level file changed: regenerate the thresholds (tools/stars.lua gen)") end
				-- the plan (Stars.CONCERT) covers the first 100 levels; the kind of a later level is data (WP-14 moves the
				-- concerts to the end of every district)
				local want = Stars.CONCERT[id] and "concert" or (id <= 100 and "normal" or e.kind)
				if e.kind ~= want then bad("kind " .. tostring(e.kind) .. ", the plan says " .. want) end
				if e.kind == "concert" and entry.difficulty ~= "super_hard" then bad("a concert level must be super_hard") end
				if type(e.best) ~= "number" or e.t[3] > e.best then bad("3 stars (" .. e.t[3] .. ") are above the best bot score " .. tostring(e.best)) end
				if type(e.share3) ~= "number" or e.share3 > Stars.MAX_SHARE3 then
					bad("3 stars are too easy: " .. tostring(e.share3) .. " per mille of the won games reach them")
				end
				if type(e.wins) ~= "number" or e.wins < 3 then bad("too few won reference games") end
				if opts.replay and type(e.witness) == "table" then
					local g = e.witness[2] - (data.seed_base or Stars.SEED_BASE)
					local Run = require("tools.bot.run")
					local r = Run.play(entry, { seed = e.witness[2], bot = e.witness[1], bot_seed = e.witness[2],
						budget = entry.moves, finish = true })
					if not r.won or r.score ~= e.best then
						bad("the witness game (" .. tostring(e.witness[1]) .. " " .. tostring(e.witness[2]) .. ") scored "
							.. tostring(r.score) .. ", not " .. tostring(e.best) .. " (g " .. g .. ")")
					end
				end
			end
		end
	end
	for key in pairs(data.levels) do -- order-free: only collects messages, sorted below
		if not seen[key] then errs[#errs + 1] = "stars.json names level " .. key .. ", which has no file" end
	end
	table.sort(errs)
	return errs
end

-- CLI -------------------------------------------------------------------------

local USAGE = "usage: luajit tools/stars.lua gen [--jobs 4] [--out file] [--dir content/levels] [ids...] | check [--replay]"

local function worker(dir, ids, out)
	local rows = {}
	for _, entry in ipairs(load_levels(dir, ids)) do
		local e, err = Stars.level(entry)
		if not e then error(err) end
		rows[entry.id] = e
	end
	local f = assert(io.open(out, "wb"))
	for id, e in pairs(rows) do f:write(line(id, e), "\n") end -- order-free: parts are merged by id
	f:close()
end

local function parse_row(l)
	local id = tonumber(l:match('^"(%d+)"'))
	return id, common.decode("{" .. l .. "}")["" .. id]
end

function Stars.main(argv)
	local flags = { replay = true, worker = true }
	local values = { n = true, bot = true, jobs = true, out = true, dir = true, stars = true, ids = true }
	local opts, pos, perr = common.parse_args(argv, flags, values)
	if perr or #pos == 0 then
		io.stderr:write((perr or "") .. "\n" .. USAGE .. "\n")
		return 2
	end
	local dir = opts.dir or (ROOT .. "content/levels")
	local cmd = table.remove(pos, 1)
	common.jit_opts()
	if opts.worker then
		local ids = {}
		for id in (opts.ids or ""):gmatch("%d+") do ids[#ids + 1] = tonumber(id) end
		worker(dir, ids, opts.out)
		return 0
	end
	if cmd == "check" then
		local path = opts.stars or (dir .. "/stars.json")
		local text = common.read_file(path)
		local data = text and common.decode(text)
		local errs = Stars.check(data, dir, { replay = opts.replay })
		for _, m in ipairs(errs) do print("FAIL " .. m) end
		print(#errs == 0 and "stars: ok" or ("stars: " .. #errs .. " problem(s)"))
		return #errs == 0 and 0 or 1
	end
	if cmd == "economy" then
		-- stars a bot collects level by level (first win of each level, N greedy games per level) against
		-- the cumulative price of the districts
		local data = common.decode(common.read_file(dir .. "/stars.json"))
		local n = tonumber(opts.n) or 6
		local bot = opts.bot or "greedy"
		local mean, total = {}, 0
		for _, entry in ipairs(load_levels(dir, {})) do
			local sum, wins = 0, 0
			for g = 1, n do
				local r = Run_play_first_win(entry, g, bot)
				if r then
					sum = sum + stars.rate(data.levels[tostring(entry.id)].t, r)
					wins = wins + 1
				end
			end
			mean[entry.id] = wins > 0 and sum / wins or 1
			total = total + mean[entry.id]
		end
		local d = common.decode(common.read_file(ROOT .. "content/districts.json"))
		local count = 0 -- levels in the model: the highest id with a mean (every level of the directory)
		for id in pairs(mean) do count = math.max(count, id) end -- order-free: a maximum
		local cost, cum, at, floor_at = 0, 0, {}, {}
		local c1, c2 = 0, 0
		local k = 1
		for _, dist in ipairs(d.districts or d) do
			for _, task in ipairs(dist.tasks) do cost = cost + task.cost end
			-- first level where the cumulative stars reach the price so far
			local level
			cum = 0
			for id = 1, count do
				cum = cum + (mean[id] or 0)
				if cum >= cost then level = id break end
			end
			at[k] = level or "never"
			floor_at[k] = cost <= count and cost or "never"
			k = k + 1
		end
		print(string.format("bot %s, %d games per level: mean stars per level %.2f, total %.1f (the town costs %d)", bot, n, total / math.max(1, count), total, cost))
		print("district closed at level (mean bot): " .. table.concat(at, ", "))
		print("district closed at level (1 star per win, no replay): " .. table.concat(floor_at, ", "))
		return 0
	end
	if cmd ~= "gen" then
		io.stderr:write(USAGE .. "\n")
		return 2
	end
	local jobs = tonumber(opts.jobs) or 4
	local ids = {}
	for _, a in ipairs(pos) do ids[#ids + 1] = tonumber(a) end
	local entries = load_levels(dir, ids)
	local parts, tmp = {}, os.tmpname()
	for j = 1, jobs do parts[j] = {} end
	for i, entry in ipairs(entries) do parts[(i - 1) % jobs + 1][#parts[(i - 1) % jobs + 1] + 1] = entry.id end
	local handles = {}
	local vm = (arg and arg[-1]) or "luajit"
	for j = 1, jobs do
		if #parts[j] > 0 then
			local file = tmp .. "." .. j
			local cmdline = string.format("%s %s gen --worker --dir %s --out %s --ids %s 2>&1", vm,
				common.shell_quote(ROOT .. "tools/stars.lua"), common.shell_quote(dir), common.shell_quote(file),
				common.shell_quote(table.concat(parts[j], ",")))
			handles[#handles + 1] = { file = file, p = io.popen(cmdline, "r") }
		end
	end
	local levels, failed = {}, false
	for _, h in ipairs(handles) do
		local text = h.p:read("*a") or ""
		h.p:close()
		if text ~= "" then print(text) end
		local f = io.open(h.file, "rb")
		if not f then
			failed = true
		else
			for l in f:lines() do
				l = l:gsub(",$", "")
				local id, e = parse_row(l)
				if id then levels[id] = e end
			end
			f:close()
			os.remove(h.file)
		end
	end
	os.remove(tmp)
	if failed then
		io.stderr:write("stars: a worker failed\n")
		return 1
	end
	-- a partial run (ids given) merges into the existing file
	local out = opts.out or (dir .. "/stars.json")
	if #ids > 0 then
		local old = common.read_file(out)
		local data = old and common.decode(old)
		if data and data.levels then
			for key, e in pairs(data.levels) do -- order-free: keyed by id
				local id = tonumber(key)
				if not levels[id] then levels[id] = e end
			end
		end
	end
	assert(common.write_file_atomic(out, Stars.encode(levels)))
	print("stars: wrote " .. out)
	return 0
end

if MAIN then os.exit(Stars.main(arg or {})) end

return Stars
