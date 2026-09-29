-- Lint rules of section 0 for the core sources.

local function core_files()
	local files = {}
	local p = io.popen("ls core/*.lua")
	for line in p:lines() do files[#files + 1] = line end
	p:close()
	return files
end

local function lines(path)
	local out = {}
	local f = assert(io.open(path, "r"))
	for line in f:lines() do out[#out + 1] = line end
	f:close()
	return out
end

-- The line without its trailing comment and without string literals.
local function code_of(line)
	local s = string.gsub(line, '"[^"]*"', '""')
	s = string.gsub(s, "'[^']*'", "''")
	local c = string.find(s, "--", 1, true)
	if c then s = string.sub(s, 1, c - 1) end
	return " " .. s
end

describe("core lint (section 0)", function()
	it("finds the core sources", function()
		assert_true(#core_files() >= 15)
	end)

	it("every pairs/next is marked order-independent", function()
		for _, path in ipairs(core_files()) do
			for n, line in ipairs(lines(path)) do
				local code = code_of(line)
				if string.find(code, "[^%w_%.:]pairs%s*%(") or string.find(code, "[^%w_%.:]next%s*%(") then
					assert_true(string.find(line, "-- order-independent", 1, true) ~= nil,
						path .. ":" .. n .. " uses pairs/next without '-- order-independent'")
				end
			end
		end
	end)

	it("uses no math.random, os.*, io.* or tools modules", function()
		for _, path in ipairs(core_files()) do
			for n, line in ipairs(lines(path)) do
				local code = code_of(line)
				local where = path .. ":" .. n
				assert_false(string.find(code, "math%.random"), where .. " math.random")
				assert_false(string.find(code, "[^%w_]os%."), where .. " os.*")
				assert_false(string.find(code, "[^%w_]io%."), where .. " io.*")
				assert_false(string.find(line, 'require%("tools'), where .. " requires a tools module")
			end
		end
	end)

	it("every table.sort has a comparator or sorts plain numbers", function()
		for _, path in ipairs(core_files()) do
			for n, line in ipairs(lines(path)) do
				if string.find(code_of(line), "table%.sort%([%w_%.]+%)") then
					assert_true(string.find(line, "-- numbers", 1, true) ~= nil, path .. ":" .. n .. " sort without comparator")
				end
			end
		end
	end)
end)
