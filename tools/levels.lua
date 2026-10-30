-- Level CLI: validation, statistics, ASCII preview.
--
--   luajit tools/levels.lua validate [ids|files...] [--dir content/levels] [--strict]
--   luajit tools/levels.lua stats [ids|files...] [--dir content/levels] [--json]
--   luajit tools/levels.lua preview <id|file> [--seed n] [--dir content/levels]
--
-- `validate` loads every level through core.load_level (the full rule set of
-- core-rules 2.1) and prints its errors; it also checks that the id matches
-- the file name. Plan checks (levels-plan.md: difficulty saw, colour counts,
-- moves 20-35, and for a whole directory the missing files among 1..100) are
-- warnings; --strict turns them into errors. Exit code 1 when any level
-- fails, 2 for a bad command line.
-- `preview` draws the level from its JSON (coordinates as in the JSON, from
-- zero); with --seed it draws the start board the core builds for that seed.

local MAIN = (...) ~= "tools.levels"
local ROOT = ""
if MAIN then
	-- the repository root from the script path (also when started from another directory)
	ROOT = (arg and arg[0] or ""):match("^(.-)tools[/\\]levels%.lua$")
	if not ROOT then ROOT = ((arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or ".") .. "/../" end
	package.path = ROOT .. "?.lua;" .. ROOT .. "?/init.lua;" .. package.path
end

local common = require("tools.bot.common")

local Levels = {}

-- Plan (levels-plan.md) -------------------------------------------------------

local SAW_21_50 = { "easy", "medium", "easy", "hard", "medium", "easy", "medium", "hard", "easy", "medium" }
local SAW_51_100 = { "easy", "medium", "easy", "hard", "medium", "easy", "medium", "hard", "easy", "super_hard" }

-- Planned difficulty of a level id (section 1), nil beyond 100.
function Levels.plan_difficulty(id)
	if id < 1 or id > 100 then return nil end
	if id <= 20 then return "easy" end
	local pos = (id - 1) % 10 + 1
	if id <= 50 then return SAW_21_50[pos] end
	return SAW_51_100[pos]
end

-- Allowed colour counts (section 3, rule 6).
function Levels.plan_colors(id, difficulty)
	if id <= 10 then return 4, 4 end
	if id <= 30 then return 4, 5 end
	if id <= 70 then return 5, (difficulty == "hard" or difficulty == "super_hard") and 6 or 5 end
	return 5, 6
end

-- Elements counted by rule 2.1.6, present in a raw level.
Levels.ELEMENTS = { "record_box", "dancefloor", "wires", "mic", "concrete", "noise", "balloon", "column" }

-- Like the core's rule 2.1.6: a `mic` counts when there is a deliver goal, a
-- mic block or a starting mic piece.
function Levels.elements(raw)
	local has = {}
	for _, f in ipairs(raw.floor or {}) do if f then has.dancefloor = true end end
	for _, o in ipairs(raw.overlay or {}) do if o.type == "wires" then has.wires = true end end
	for _, g in ipairs(raw.goals or {}) do if g.type == "deliver" then has.mic = true end end
	if raw.mic ~= nil then has.mic = true end
	local specials = 0
	for _, s in ipairs(raw.slots or {}) do
		if s.type == "riff" or s.type == "sub" or s.type == "bird" or s.type == "disco" then
			specials = specials + 1
		elseif s.type ~= "piece" then
			has[s.type] = true
		end
	end
	local list = {}
	for _, e in ipairs(Levels.ELEMENTS) do if has[e] then list[#list + 1] = e end end
	return list, specials
end

function Levels.goals_text(raw)
	local parts = {}
	for _, g in ipairs(raw.goals or {}) do
		if g.type == "collect" then parts[#parts + 1] = string.format("collect %s %d", g.color, g.count)
		elseif g.type == "break" then parts[#parts + 1] = string.format("break %s %d", g.item, g.count)
		elseif g.type == "deliver" then parts[#parts + 1] = string.format("deliver %d", g.count)
		else parts[#parts + 1] = tostring(g.type) end
	end
	return table.concat(parts, ", ")
end

-- Validation --------------------------------------------------------------------

-- Returns {file, ok, errors = {}, warnings = {}, raw}.
function Levels.validate_file(path, core)
	core = core or require("core.game")
	local res = { file = path, errors = {}, warnings = {} }
	local text, err = common.read_file(path)
	if not text then
		res.errors[1] = "cannot read: " .. tostring(err)
		return res
	end
	local lvl, errs = core.load_level(text)
	if not lvl then
		for _, e in ipairs(errs) do res.errors[#res.errors + 1] = e end
	end
	local raw = common.decode(text)
	res.raw = raw
	if raw and type(raw.id) == "number" then
		local num = path:match("level_(%d+)%.json$")
		if num and tonumber(num) ~= raw.id then
			res.errors[#res.errors + 1] = string.format("file name says level %d, id is %d", tonumber(num), raw.id)
		end
		local want = Levels.plan_difficulty(raw.id)
		if want and raw.difficulty ~= want then
			res.warnings[#res.warnings + 1] = string.format("plan: difficulty %s expected (saw), got %s", want, tostring(raw.difficulty))
		end
		if type(raw.colors) == "table" then
			local lo, hi = Levels.plan_colors(raw.id, raw.difficulty)
			if #raw.colors < lo or #raw.colors > hi then
				res.warnings[#res.warnings + 1] = string.format("plan: %d-%d colours expected, got %d", lo, hi, #raw.colors)
			end
		end
		if type(raw.moves) == "number" and (raw.moves < 20 or raw.moves > 35) then
			res.warnings[#res.warnings + 1] = string.format("plan: moves %d outside 20-35", raw.moves)
		end
	end
	res.ok = #res.errors == 0
	return res
end

-- Preview ---------------------------------------------------------------------

local LETTER = { red = "r", orange = "o", yellow = "y", green = "g", blue = "b", purple = "p" }
local ITEM = { record_box = "X", concrete = "K", noise = "N", balloon = "A", column = "C" }
local SPEC = { riff = "R", sub = "S", bird = "B", disco = "D" }

-- One character for an hp: 1-9, then a b c for 10-12 (a column has up to 12).
local function hp_char(hp)
	if type(hp) ~= "number" then return " " end
	if hp >= 1 and hp <= 9 then return string.format("%d", hp) end
	if hp >= 10 and hp <= 35 then return string.char(87 + hp) end -- 10 -> a
	return "?"
end
Levels.hp_char = hp_char

-- A grid of 4-character cells: content, detail, floor, wires.
local function new_grid(W, H)
	local g = {}
	for y = 1, H do
		g[y] = {}
		for x = 1, W do g[y][x] = { " ", " ", " ", " ", void = true } end
	end
	return g
end

local function draw_grid(g, W, H, marks)
	local out = {}
	local head = { "    " }
	for x = 0, W - 1 do head[#head + 1] = string.format("%-4d", x) end
	out[#out + 1] = table.concat(head, " ")
	if marks and marks.top then
		local row = { "    " }
		for x = 1, W do row[#row + 1] = marks.top[x] and " v  " or "    " end
		out[#out + 1] = table.concat(row, " ")
	end
	for y = 1, H do
		local row = { string.format("%3d ", y - 1) }
		for x = 1, W do
			local c = g[y][x]
			row[#row + 1] = c.void and " .  " or table.concat(c, "", 1, 4)
		end
		out[#out + 1] = table.concat(row, " ")
	end
	return table.concat(out, "\n")
end

Levels.LEGEND = "legend: r o y g b p piece colour, + random piece, R/S/B/D riff/sub/bird/disco (riff axis - or |),"
	.. " M mic, X box, K concrete, N noise, A balloon (+colour), C column (+hp, a-c = 10-12), 3rd char floor (_ hp1, = hp2),"
	.. " 4th char wires (w hp1, W hp2), v spawner, e exit (2nd char), . void"

-- Static preview from the JSON.
function Levels.preview_raw(raw)
	local W, H = raw.size[1], raw.size[2]
	local g = new_grid(W, H)
	for y = 1, H do
		local line = raw.cells[y]
		for x = 1, W do
			if line:sub(x, x) == "#" then
				local c = g[y][x]
				c.void = false
				c[1] = "+"
			end
		end
	end
	local function cell(at) return g[at[2] + 1] and g[at[2] + 1][at[1] + 1] end
	for _, f in ipairs(raw.floor or {}) do
		local c = cell(f.at)
		if c then c[3] = f.hp == 2 and "=" or "_" end
	end
	for _, o in ipairs(raw.overlay or {}) do
		local c = cell(o.at)
		if c then c[4] = o.hp == 2 and "W" or "w" end
	end
	for _, s in ipairs(raw.slots or {}) do
		local c = cell(s.at)
		if c then
			if s.type == "piece" then c[1] = LETTER[s.color] or "?"
			elseif SPEC[s.type] then
				c[1] = SPEC[s.type]
				if s.type == "riff" then c[2] = s.axis == "v" and "|" or "-" end
			elseif s.type == "mic" then c[1] = "M"
			elseif s.type == "balloon" then c[1], c[2] = "A", LETTER[s.color] or "?"
			elseif ITEM[s.type] then
				c[1] = ITEM[s.type]
				c[2] = hp_char(s.hp)
				if s.type == "column" then
					for dy = 0, 1 do
						for dx = 0, 1 do
							local c2 = cell({ s.at[1] + dx, s.at[2] + dy })
							if c2 and c2 ~= c then c2[1], c2[2] = "C", " " end
						end
					end
				end
			end
		end
	end
	local top = {}
	if raw.spawners == nil or raw.spawners == "top" then
		for x = 1, W do
			for y = 1, H do
				if not g[y][x].void then top[x] = true break end
			end
		end
	else
		for _, at in ipairs(raw.spawners) do
			local c = cell(at)
			if c then c[2] = c[2] == " " and "v" or c[2] end
		end
	end
	if type(raw.exits) == "table" then
		for _, at in ipairs(raw.exits) do
			local c = cell(at)
			if c then c[2] = "e" end
		end
	end
	return draw_grid(g, W, H, { top = top })
end

-- Start board of a seed through the core (pieces() and cells()).
function Levels.preview_game(game, W, H)
	local g = new_grid(W, H)
	local cl = game:cells()
	local top = {}
	for i = 1, #cl do
		local x, y = (i - 1) % W + 1, math.floor((i - 1) / W) + 1
		local c = g[y][x]
		local ce = cl[i]
		if ce.exists then
			c.void = false
			if ce.floor and ce.floor > 0 then c[3] = ce.floor == 2 and "=" or "_" end
			if ce.wires and ce.wires > 0 then c[4] = ce.wires == 2 and "W" or "w" end
			if ce.spawner then top[x] = true end
			if ce.exit then c[2] = "e" end
		end
	end
	for _, p in ipairs(game:pieces()) do
		local c = g[p.y] and g[p.y][p.x]
		if c then
			if p.kind == "regular" then c[1] = LETTER[p.color] or "?"
			elseif p.kind == "special" then
				c[1] = SPEC[p.special] or "?"
				if p.special == "riff" then c[2] = p.axis == "v" and "|" or "-" end
			elseif p.kind == "mic" then c[1] = "M"
			elseif p.kind == "blocker" then
				c[1] = ITEM[p.item] or "?"
				if p.item == "balloon" then c[2] = LETTER[p.color] or "?"
				elseif p.hp and p.item ~= "noise" then c[2] = hp_char(p.hp) end
				if p.item == "column" then
					for dy = 0, 1 do
						for dx = 0, 1 do
							local c2 = g[p.y + dy] and g[p.y + dy][p.x + dx]
							if c2 and c2 ~= c then c2[1], c2[2] = "C", " " end
						end
					end
				end
			end
		end
	end
	return draw_grid(g, W, H, { top = top })
end

-- CLI ---------------------------------------------------------------------------

-- Level files named by the positional arguments (ids, ranges "12-15",
-- lists "1,3,5", names or paths), or every level file of the directory.
-- Returns the list, or nil and a message for a malformed range.
local function files_from(pos, dir)
	if #pos == 0 then return common.level_files(dir) end
	local out = {}
	for _, p in ipairs(pos) do
		if p:match("^[%d,%-]+$") and p:find("[,%-]") then
			local ids, err = common.parse_ids(p)
			if not ids then return nil, err end
			for _, id in ipairs(ids) do out[#out + 1] = common.level_path(tostring(id), dir) end
		else
			out[#out + 1] = common.level_path(p, dir)
		end
	end
	return out
end

-- Ids in 1..upto without a file, as ranges ("71-100", "5", "8-9").
function Levels.missing_ranges(ids, upto)
	local have = {}
	for _, id in ipairs(ids) do have[id] = true end
	local out, start = {}, nil
	for id = 1, upto + 1 do
		if id <= upto and not have[id] then
			start = start or id
		elseif start then
			out[#out + 1] = (start == id - 1) and tostring(start) or (start .. "-" .. (id - 1))
			start = nil
		end
	end
	return out
end

local function cmd_validate(opts, pos, dir)
	local files, ferr = files_from(pos, dir)
	if not files then
		io.stderr:write("levels: " .. ferr .. "\n")
		return 2
	end
	if #files == 0 then
		print("no level files in " .. dir)
		return 1
	end
	local core = require("core.game")
	local bad, warned = 0, 0
	local present = {}
	for _, f in ipairs(files) do
		local r = Levels.validate_file(f, core)
		local name = f:match("[^/\\]+$")
		if opts.strict then
			for _, w in ipairs(r.warnings) do r.errors[#r.errors + 1] = w end
			r.warnings = {}
			r.ok = #r.errors == 0
		end
		if r.ok then
			local raw = r.raw
			print(string.format("ok   %s (id %d, %s, %dx%d, %d moves, %s)", name, raw.id, raw.difficulty,
				raw.size[1], raw.size[2], raw.moves, Levels.goals_text(raw)))
		else
			bad = bad + 1
			print("FAIL " .. name)
			for _, e in ipairs(r.errors) do print("       " .. e) end
		end
		for _, w in ipairs(r.warnings) do print("       warning: " .. w) end
		if #r.warnings > 0 then warned = warned + 1 end
		local num = f:match("level_(%d+)%.json$")
		if num then present[#present + 1] = tonumber(num) end
	end
	-- a whole directory is the 100-level game: say which files are missing
	local gaps = 0
	if #pos == 0 then
		local missing = Levels.missing_ranges(present, 100)
		if #missing > 0 then
			gaps = 1
			print((opts.strict and "FAIL " or "warning: ") .. "plan: level files missing: " .. table.concat(missing, ", "))
		end
	end
	print(string.format("%d level(s): %d ok, %d failed, %d with plan warnings", #files, #files - bad, bad, warned))
	return (bad > 0 or (opts.strict and gaps > 0)) and 1 or 0
end

-- Statistics of raw levels: {counts, stars, rows, first}.
function Levels.stats(raws)
	local counts, stars, rows, first = { easy = 0, medium = 0, hard = 0, super_hard = 0 }, 0, {}, {}
	for _, raw in ipairs(raws) do
		counts[raw.difficulty] = (counts[raw.difficulty] or 0) + 1
		stars = stars + (common.STARS[raw.difficulty] or 0)
		local el, specials = Levels.elements(raw)
		for _, e in ipairs(el) do
			if not first[e] or raw.id < first[e] then first[e] = raw.id end
		end
		rows[#rows + 1] = {
			id = raw.id, difficulty = raw.difficulty, size = raw.size[1] .. "x" .. raw.size[2],
			colors = #raw.colors, moves = raw.moves, goals = Levels.goals_text(raw),
			elements = el, specials = specials,
		}
	end
	table.sort(rows, function(a, b) return a.id < b.id end)
	return { counts = counts, stars = stars, rows = rows, first = first }
end

local function cmd_stats(opts, pos, dir)
	local raws = {}
	local files, ferr = files_from(pos, dir)
	if not files then
		io.stderr:write("levels: " .. ferr .. "\n")
		return 2
	end
	for _, f in ipairs(files) do
		local text = common.read_file(f)
		local raw = text and common.decode(text)
		if type(raw) == "table" and type(raw.id) == "number" and type(raw.size) == "table" and type(raw.colors) == "table"
			and type(raw.difficulty) == "string" then
			raws[#raws + 1] = raw
		else
			print("skipped (unreadable): " .. f)
		end
	end
	local st = Levels.stats(raws)
	if opts.json then
		print(common.encode(st, "  "))
		return 0
	end
	print(string.format("%-4s %-10s %-5s %-3s %-5s %-32s %s", "id", "difficulty", "size", "col", "moves", "goals", "elements"))
	for _, r in ipairs(st.rows) do
		local el = table.concat(r.elements, ",")
		if r.specials > 0 then el = el .. (el ~= "" and " " or "") .. "+" .. r.specials .. " specials" end
		print(string.format("%-4d %-10s %-5s %-3d %-5d %-32s %s", r.id, r.difficulty, r.size, r.colors, r.moves, r.goals, el))
	end
	print(string.format("levels: %d (easy %d, medium %d, hard %d, super_hard %d); stars: %d",
		#st.rows, st.counts.easy, st.counts.medium, st.counts.hard, st.counts.super_hard, st.stars))
	local fl = {}
	for _, e in ipairs(Levels.ELEMENTS) do
		if st.first[e] then fl[#fl + 1] = e .. " " .. st.first[e] end
	end
	print("first appearance: " .. (#fl > 0 and table.concat(fl, ", ") or "-"))
	return 0
end

-- True when the level JSON has what the drawing needs: size, cells, slots.
local function drawable(raw)
	if type(raw) ~= "table" then return false, "the file is not a JSON object" end
	if type(raw.size) ~= "table" or type(raw.size[1]) ~= "number" or type(raw.size[2]) ~= "number" then
		return false, "no usable size"
	end
	if type(raw.cells) ~= "table" or #raw.cells < raw.size[2] then return false, "no usable cells" end
	for y = 1, raw.size[2] do
		if type(raw.cells[y]) ~= "string" then return false, "no usable cells" end
	end
	return true
end

local function cmd_preview(opts, pos, dir)
	if #pos == 0 then
		print("usage: luajit tools/levels.lua preview <id|file> [--seed n]")
		return 1
	end
	local seed, serr = common.int_option(opts, "seed", nil, 1, 2147483646)
	if serr then
		io.stderr:write("levels: " .. serr .. "\n")
		return 2
	end
	local path = common.level_path(pos[1], dir)
	local text, err = common.read_file(path)
	if not text then
		print(path .. ": " .. tostring(err))
		return 1
	end
	local raw, jerr = common.decode(text)
	local ok, why = drawable(raw)
	if not ok then
		print(path .. ": " .. (jerr or why))
		return 1
	end
	print(string.format("level %s: %s, %dx%d, %d moves, colours %s; goals: %s", tostring(raw.id), tostring(raw.difficulty),
		raw.size[1], raw.size[2], tonumber(raw.moves) or 0, type(raw.colors) == "table" and table.concat(raw.colors, " ") or "?",
		Levels.goals_text(raw)))
	if seed then
		local core = require("core.game")
		local lvl, errs = core.load_level(text)
		if not lvl then
			print("invalid: " .. table.concat(errs, "; "))
			return 1
		end
		local game = core.new(lvl, { seed = seed })
		print("start board, seed " .. seed .. ":")
		print(Levels.preview_game(game, raw.size[1], raw.size[2]))
	else
		local drawn, board = pcall(Levels.preview_raw, raw)
		if not drawn then
			print(path .. ": cannot draw: " .. tostring(board))
			return 1
		end
		print(board)
	end
	print(Levels.LEGEND)
	return 0
end

local USAGE = "usage: luajit tools/levels.lua validate [ids|files...] [--strict] | stats [ids|files...] [--json]"
	.. " | preview <id|file> [--seed n]   (--dir content/levels)"
local FLAGS = { strict = true, json = true, help = true }
local VALUES = { dir = true, seed = true }
Levels.OPTIONS = { flags = FLAGS, values = VALUES }

function Levels.main(argv)
	local opts, pos, perr = common.parse_args(argv, FLAGS, VALUES)
	if perr then
		io.stderr:write("levels: " .. perr .. "\n" .. USAGE .. "\n")
		return 2
	end
	local cmd = table.remove(pos, 1)
	local dir = opts.dir or (ROOT .. "content/levels")
	if cmd == "validate" then return cmd_validate(opts, pos, dir) end
	if cmd == "stats" then return cmd_stats(opts, pos, dir) end
	if cmd == "preview" then return cmd_preview(opts, pos, dir) end
	print(USAGE)
	return (cmd == nil or opts.help) and 0 or 1
end

if MAIN then os.exit(Levels.main(arg or {})) end

return Levels
