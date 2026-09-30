-- Shared helpers of the level tools (bots, runner, tuner, levels CLI).
--
-- Pure Lua 5.1 / LuaJIT. Uses only the public core API (core/game.lua):
-- `core.load_level`, `core.new` and the game methods. Everything else
-- (level metadata, goals, difficulty) is read from the level's JSON text.

local json = require("tools.lib.json")

local M = {}

-- Files ----------------------------------------------------------------------

function M.read_file(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, err end
	local text = f:read("*a")
	f:close()
	return text
end

function M.write_file(path, text)
	local f, err = io.open(path, "wb")
	if not f then return nil, err end
	f:write(text)
	f:close()
	return true
end

function M.file_exists(path)
	local f = io.open(path, "rb")
	if f then f:close() return true end
	return false
end

-- Sorted list of level files `level_NNNN.json` in a directory.
function M.level_files(dir)
	local out = {}
	local p = io.popen('ls "' .. dir .. '" 2>/dev/null')
	if not p then return out end
	for name in p:lines() do
		if name:match("^level_%d+%.json$") then out[#out + 1] = dir .. "/" .. name end
	end
	p:close()
	table.sort(out)
	return out
end

-- `5`, `level_0005`, `level_0005.json` or a path -> a path.
function M.level_path(spec, dir)
	dir = dir or "content/levels"
	if spec:match("^%d+$") then return string.format("%s/level_%04d.json", dir, tonumber(spec)) end
	if spec:match("^level_%d+$") then return dir .. "/" .. spec .. ".json" end
	if spec:match("^level_%d+%.json$") and not M.file_exists(spec) then return dir .. "/" .. spec end
	return spec
end

-- JSON -----------------------------------------------------------------------

function M.decode(text)
	local ok, v = pcall(json.decode, text)
	if not ok then return nil, tostring(v) end
	return v
end

local function is_array(t)
	if t.__array then return true end
	if t.__object then return false end
	local n = #t
	if n == 0 then return next(t) == nil end
	local count = 0
	for _ in pairs(t) do count = count + 1 end -- order-independent (a count)
	return count == n
end

local function enc_string(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		if c == '"' then return '\\"' end
		if c == "\\" then return "\\\\" end
		if c == "\n" then return "\\n" end
		if c == "\t" then return "\\t" end
		return string.format("\\u%04x", c:byte())
	end) .. '"'
end

local function enc_number(v)
	if v ~= v or v == math.huge or v == -math.huge then return "null" end
	if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
	return string.format("%.6g", v)
end

-- Deterministic JSON: object keys sorted, arrays in order. `indent` (string)
-- pretty-prints objects; arrays of scalars stay on one line.
function M.encode(v, indent, depth)
	depth = depth or 0
	local t = type(v)
	if t == "nil" then return "null" end
	if t == "boolean" then return tostring(v) end
	if t == "number" then return enc_number(v) end
	if t == "string" then return enc_string(v) end
	if t ~= "table" then error("encode: unsupported type " .. t) end
	local nl, pad, pad2 = "", "", ""
	if indent then
		nl = "\n"
		pad = string.rep(indent, depth)
		pad2 = string.rep(indent, depth + 1)
	end
	if is_array(v) then
		local parts, scalars = {}, true
		for i = 1, #v do
			if type(v[i]) == "table" then scalars = false end
			parts[i] = M.encode(v[i], indent, depth + 1)
		end
		if #parts == 0 then return "[]" end
		if scalars or not indent then return "[" .. table.concat(parts, ",") .. "]" end
		return "[" .. nl .. pad2 .. table.concat(parts, "," .. nl .. pad2) .. nl .. pad .. "]"
	end
	local keys = {}
	for k in pairs(v) do -- order-independent (sorted below)
		if k ~= "__array" and k ~= "__object" then keys[#keys + 1] = tostring(k) end
	end
	table.sort(keys)
	local parts = {}
	for i = 1, #keys do
		local k = keys[i]
		local val = v[k]
		if val == nil then val = v[tonumber(k)] end
		parts[i] = enc_string(k) .. ":" .. (indent and " " or "") .. M.encode(val, indent, depth + 1)
	end
	if #parts == 0 then return "{}" end
	return "{" .. nl .. pad2 .. table.concat(parts, "," .. nl .. pad2) .. nl .. pad .. "}"
end

-- Levels ---------------------------------------------------------------------

-- The top-level "moves" value of a level's JSON text: value, start, stop of
-- the digits. Errors unless there is exactly one `"moves": <int>`.
function M.find_moves(text)
	local found, a, b, val = 0, nil, nil, nil
	local init = 1
	while true do
		local s, e, digits = text:find('"moves"%s*:%s*(%-?%d+)', init)
		if not s then break end
		found = found + 1
		b = e
		a = e - #digits + 1
		val = tonumber(digits)
		init = e + 1
	end
	if found ~= 1 then return nil, "expected exactly one \"moves\" key, found " .. found end
	return val, a, b
end

-- The same text with only the digits of the "moves" value replaced.
function M.set_moves(text, moves)
	local v, a, b = M.find_moves(text)
	if not v then error(a, 2) end
	return text:sub(1, a - 1) .. string.format("%d", moves) .. text:sub(b + 1)
end

-- A level entry from JSON text: {path, text, raw, id, difficulty, moves,
-- goals, level} or nil, errors (array of strings).
function M.entry_from_text(text, path, core)
	core = core or require("core.game")
	local raw, jerr = M.decode(text)
	if not raw then return nil, { "json: " .. jerr } end
	local level, errs = core.load_level(text)
	if not level then return nil, errs end
	return {
		path = path or "?", text = text, raw = raw, level = level,
		id = raw.id, difficulty = raw.difficulty, moves = raw.moves, goals = raw.goals,
	}
end

-- Loads a level file (see entry_from_text).
function M.load_entry(path, core)
	local text, err = M.read_file(path)
	if not text then return nil, { "cannot read " .. path .. ": " .. tostring(err) } end
	return M.entry_from_text(text, path, core)
end

-- Same level with a different move budget: loaded from the text where only
-- the moves value differs (the schema allows 5..60). Cached per entry.
function M.level_with_moves(entry, moves, core)
	core = core or require("core.game")
	entry.by_moves = entry.by_moves or {}
	local lvl = entry.by_moves[moves]
	if lvl then return lvl end
	if moves == entry.moves then
		lvl = entry.level
	else
		local errs
		lvl, errs = core.load_level(M.set_moves(entry.text, moves))
		if not lvl then error("level " .. tostring(entry.id) .. " with moves=" .. moves .. ": " .. table.concat(errs, "; ")) end
	end
	entry.by_moves[moves] = lvl
	return lvl
end

-- Stars per difficulty (core-rules 13).
M.STARS = { easy = 1, medium = 1, hard = 2, super_hard = 3 }

-- Difficulty corridors of the first-attempt win rate (levels-plan 1).
M.CORRIDOR = {
	easy = { lo = 0.85, hi = 0.95, target = 0.90 },
	medium = { lo = 0.60, hi = 0.75, target = 0.68 },
	hard = { lo = 0.35, hi = 0.50, target = 0.42 },
	super_hard = { lo = 0.20, hi = 0.30, target = 0.25 },
}

-- Random numbers of the tools ------------------------------------------------
-- MINSTD (Park-Miller, multiplier 48271): exact in doubles on both VMs and
-- independent of the game's four streams.

local MOD = 2147483647

function M.rng(seed)
	local x = (seed * 7 + 12345) % MOD
	if x == 0 then x = 1 end
	local r = { x = x }
	for _ = 1, 4 do r.x = r.x * 48271 % MOD end
	return r
end

function M.rng_next(r)
	r.x = r.x * 48271 % MOD
	return r.x
end

-- Integer in [1, n].
function M.rng_int(r, n)
	return M.rng_next(r) % n + 1
end

-- Statistics -----------------------------------------------------------------

function M.median(list)
	local n = #list
	if n == 0 then return nil end
	local a = {}
	for i = 1, n do a[i] = list[i] end
	table.sort(a) -- numbers
	if n % 2 == 1 then return a[(n + 1) / 2] end
	return (a[n / 2] + a[n / 2 + 1]) / 2
end

function M.round(v, digits)
	local m = 10 ^ (digits or 0)
	return math.floor(v * m + 0.5) / m
end

-- Command line ---------------------------------------------------------------

-- Parses `--key value`, `--flag` and positional arguments. `flags` lists
-- the options that take no value.
function M.parse_args(argv, flags)
	flags = flags or {}
	local opts, pos = {}, {}
	local i = 1
	while i <= #argv do
		local a = argv[i]
		local key = a:match("^%-%-([%w%-_]+)$")
		if key then
			if flags[key] then
				opts[key] = true
				i = i + 1
			else
				opts[key] = argv[i + 1]
				i = i + 2
			end
		else
			pos[#pos + 1] = a
			i = i + 1
		end
	end
	return opts, pos
end

-- "1-5,8,10" -> {1,2,3,4,5,8,10}
function M.parse_ids(spec)
	local out = {}
	for part in spec:gmatch("[^,]+") do
		local a, b = part:match("^(%d+)%-(%d+)$")
		if a then
			for k = tonumber(a), tonumber(b) do out[#out + 1] = k end
		elseif part:match("^%d+$") then
			out[#out + 1] = tonumber(part)
		end
	end
	return out
end

function M.clock()
	return os.clock()
end

-- Wall-clock seconds (sub-second through `date` when available).
function M.wall()
	local p = io.popen("date +%s.%N 2>/dev/null")
	if p then
		local v = tonumber(p:read("*l") or "")
		p:close()
		if v then return v end
	end
	return os.time()
end

-- LuaJIT: the core's clone/step code needs more trace and machine-code room
-- than the defaults (512 KB); without it the JIT keeps flushing and runs
-- slower than the interpreter. No-op on PUC Lua.
function M.jit_opts()
	if jit and jit.opt and jit.opt.start then
		pcall(jit.opt.start, "maxtrace=8000", "maxmcode=32768", "hotexit=20")
	end
end

-- Name of the running VM.
function M.vm_name()
	return (jit and jit.version) or _VERSION
end

return M
