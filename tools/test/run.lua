-- Minimal dependency-free test runner for Lua 5.1 and LuaJIT.
--
-- Usage (from the repository root):
--   lua5.1 tools/test/run.lua [--filter text] [files...]
--   luajit tools/test/run.lua
-- Without file arguments every tests/**/*_test.lua file is run.
--
-- Test files use the globals defined below:
--   describe(name, fn), it(name, fn), before_each(fn)
--   assert_eq(actual, expected, msg), assert_same(actual, expected, msg)
--   assert_true(v, msg), assert_false(v, msg), assert_error(fn, pattern)
--   assert_near(actual, expected, eps, msg)

package.path = "./?.lua;./?/init.lua;" .. package.path

local filter = nil
local files = {}
local i = 1
while i <= #arg do
	if arg[i] == "--filter" then
		filter = arg[i + 1]
		i = i + 2
	else
		files[#files + 1] = arg[i]
		i = i + 1
	end
end

if #files == 0 then
	local p = io.popen("find tests -name '*_test.lua' | sort")
	for line in p:lines() do
		files[#files + 1] = line
	end
	p:close()
end

-- deep comparison -----------------------------------------------------------

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		if ta == "number" or ta == "string" then return a < b end
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function dump(v, depth)
	depth = depth or 0
	if type(v) == "string" then return string.format("%q", v) end
	if type(v) ~= "table" then return tostring(v) end
	if depth > 4 then return "{...}" end
	local parts = {}
	for _, k in ipairs(sorted_keys(v)) do
		parts[#parts + 1] = tostring(k) .. "=" .. dump(v[k], depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_equal(a, b, path)
	if type(a) ~= type(b) then
		return false, path .. ": type " .. type(a) .. " ~= " .. type(b)
	end
	if type(a) ~= "table" then
		if a == b then return true end
		return false, path .. ": " .. dump(a) .. " ~= " .. dump(b)
	end
	for _, k in ipairs(sorted_keys(a)) do
		local ok, why = deep_equal(a[k], b[k], path .. "." .. tostring(k))
		if not ok then return false, why end
	end
	for _, k in ipairs(sorted_keys(b)) do
		if a[k] == nil then return false, path .. "." .. tostring(k) .. ": missing in actual" end
	end
	return true
end

-- assertions ----------------------------------------------------------------

local function fail(msg, level)
	error(msg, (level or 1) + 2)
end

function assert_eq(actual, expected, msg)
	if actual ~= expected then
		fail((msg and (msg .. ": ") or "") .. "expected " .. dump(expected) .. ", got " .. dump(actual))
	end
end

function assert_same(actual, expected, msg)
	local ok, why = deep_equal(actual, expected, "value")
	if not ok then fail((msg and (msg .. ": ") or "") .. why) end
end

function assert_true(v, msg)
	if not v then fail(msg or ("expected truthy, got " .. dump(v))) end
end

function assert_false(v, msg)
	if v then fail(msg or ("expected falsy, got " .. dump(v))) end
end

function assert_near(actual, expected, eps, msg)
	if math.abs(actual - expected) > eps then
		fail((msg and (msg .. ": ") or "") .. "expected " .. expected .. " +- " .. eps .. ", got " .. actual)
	end
end

function assert_error(fn, pattern)
	local ok, err = pcall(fn)
	if ok then fail("expected an error") end
	if pattern and not string.find(tostring(err), pattern, 1, true) then
		fail("error '" .. tostring(err) .. "' does not contain '" .. pattern .. "'")
	end
end

-- registry ------------------------------------------------------------------

local stack = {}      -- describe blocks: {name=, befores={}}
local tests = {}      -- {name=, fn=, befores={...}, file=}
local current_file = nil

function describe(name, fn)
	stack[#stack + 1] = { name = name, befores = {} }
	fn()
	stack[#stack] = nil
end

function before_each(fn)
	local top = stack[#stack]
	if not top then error("before_each outside describe") end
	top.befores[#top.befores + 1] = fn
end

function it(name, fn)
	local names, befores = {}, {}
	for _, s in ipairs(stack) do
		names[#names + 1] = s.name
		for _, b in ipairs(s.befores) do befores[#befores + 1] = b end
	end
	names[#names + 1] = name
	tests[#tests + 1] = { name = table.concat(names, " > "), fn = fn, befores = befores, file = current_file }
end

-- run -----------------------------------------------------------------------

local vm = (jit and jit.version) or _VERSION
local load_errors = 0
for _, f in ipairs(files) do
	current_file = f
	local chunk, err = loadfile(f)
	if not chunk then
		print("LOAD ERROR " .. f .. ": " .. tostring(err))
		load_errors = load_errors + 1
	else
		local ok, e = xpcall(chunk, debug.traceback)
		if not ok then
			print("LOAD ERROR " .. f .. ": " .. tostring(e))
			load_errors = load_errors + 1
		end
	end
end

local passed, failed = 0, 0
local failures = {}
local t0 = os.clock()
for _, t in ipairs(tests) do
	if not filter or string.find(t.name, filter, 1, true) then
		local ok, err = xpcall(function()
			for _, b in ipairs(t.befores) do b() end
			t.fn()
		end, debug.traceback)
		if ok then
			passed = passed + 1
		else
			failed = failed + 1
			failures[#failures + 1] = { t = t, err = err }
		end
	end
end

for _, f in ipairs(failures) do
	print("FAIL " .. f.t.file .. " :: " .. f.t.name)
	print("  " .. tostring(f.err):gsub("\n", "\n  "))
end
print(string.format("[%s] %d passed, %d failed, %d load errors (%.2fs)",
	vm, passed, failed, load_errors, os.clock() - t0))
if failed > 0 or load_errors > 0 then os.exit(1) end
