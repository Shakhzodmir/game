local C = require("meta.config")
local util = require("meta.util")
local town = require("meta.town")
local inventory = require("meta.inventory")
local H = require("tests.meta.helper")

describe("meta config", function()
	it("matches the economy numbers of the spec", function()
		assert_eq(C.coins.start, 500)
		assert_same(C.stars, { easy = 1, medium = 1, hard = 2, super_hard = 3 })
		assert_same(C.coins.win_mult, { easy = 1, medium = 1, hard = 2, super_hard = 3 })
		assert_eq(C.coins.win_base, 25)
		assert_eq(C.coins.per_move_left, 5)
		assert_eq(C.lives.max, 5)
		assert_eq(C.lives.regen_seconds, 1200)
		assert_eq(C.lives.refill_price, 600)
		assert_eq(C.levels.free_up_to, 20)
		-- the number of levels is the last level of the last district of content/districts.json (WP-13)
		town.validate(H.districts())
		local list = H.districts().districts
		assert_eq(C.levels.count, list[#list].last)
		assert_same(C.continues.prices, { 700, 1400, 2100 })
		assert_eq(C.continues.moves, 5)
		assert_eq(C.ad_moves, 3)
		assert_eq(C.streak.from_level, 12)
	end)

	it("has the booster table of the spec", function()
		local expected = {
			stick = { "in", 8, 3, 450 }, row_light = { "in", 14, 2, 600 },
			col_light = { "in", 18, 2, 600 }, remix = { "in", 25, 2, 450 }, swap = { "in", 21, 2, 450 },
			riff = { "pre", 12, 3, 600 }, sub = { "pre", 16, 3, 750 }, disco = { "pre", 22, 3, 900 },
		}
		assert_eq(#C.boosters, 8)
		for _, b in ipairs(C.boosters) do
			assert_same({ b.kind, b.unlock, b.gift, b.pack_price }, expected[b.id], b.id)
		end
		assert_eq(C.pack_size, 3)
	end)

	it("keys every difficulty table by exactly the listed difficulties", function()
		assert_same(C.difficulties, { "easy", "medium", "hard", "super_hard" })
		for _, tbl in ipairs({ C.stars, C.coins.win_mult }) do
			local n = 0
			for _ in pairs(tbl) do n = n + 1 end -- order-free: counting
			assert_eq(n, #C.difficulties)
			for _, d in ipairs(C.difficulties) do assert_true(util.is_int(tbl[d]) and tbl[d] > 0, d) end
		end
	end)

	it("only refers to known boosters", function()
		for _, id in ipairs(C.level_chest.rotation) do assert_true(inventory.def(id) ~= nil, id) end
		assert_true(inventory.def(C.level_chest.fallback) ~= nil)
		for _, r in ipairs(C.streak.rewards) do
			assert_eq(inventory.def(r.booster).kind, "pre", r.booster)
		end
	end)

	-- Part 1 (districts 1-15) is pinned: 389 stars. Every district after it belongs to Part 2 ("part": 2, districts
	-- 16-30, docs/design/part2-districts.md) and costs 26 stars (1, 4, 5, 5, 5, 6), so a new Part 2 district needs no
	-- edit here; district 16 midnight_cafe is the first one (415 stars with it).
	it("accepts content/districts.json: Part 1 of 15 districts for 389 stars, then Part 2 districts of 26 stars", function()
		local data = town.validate(H.districts())
		local ids, stars = {}, {}
		local total = 0
		for i, d in ipairs(data.list) do
			ids[i] = d.id
			local sum = 0
			for _, t in ipairs(d.tasks) do sum = sum + t.cost end
			stars[i] = sum
			total = total + sum
		end
		local raw = H.districts().districts
		local part1 = { "cafe", "jazz", "square", "stadium", "garage", "beach", "carnival", "cinema", "bazaar",
			"skyclub", "block", "island", "ranch", "bluesclub", "arcade" }
		local prices = { 11, 20, 28, 34, 31, 31, 26, 26, 26, 26, 26, 26, 26, 26, 26 }
		assert_true(#ids >= 16, "district 16 (Part 2) is in the data: " .. #ids)
		assert_eq(ids[16], "midnight_cafe")
		for i = 1, 15 do
			assert_eq(ids[i], part1[i])
			assert_eq(stars[i], prices[i], ids[i])
			assert_eq(raw[i].part, nil, ids[i] .. " is Part 1")
		end
		for i = 16, #ids do
			assert_eq(raw[i].part, 2, ids[i] .. " is Part 2")
			assert_eq(stars[i], 26, ids[i])
			assert_same((function()
				local c = {}
				for j, t in ipairs(raw[i].tasks) do c[j] = t.cost end
				return c
			end)(), { 1, 4, 5, 5, 5, 6 })
		end
		assert_eq(total, 389 + 26 * (#ids - 15))
	end)
end)

describe("meta source rules", function()
	local files = {}
	local p = io.popen("ls meta/*.lua")
	for line in p:lines() do files[#files + 1] = line end
	p:close()

	-- Globals a meta module may read. Everything else (os, io, _G, next,
	-- debug, load*, Defold modules, ...) is out, and no module sets a global.
	local ALLOWED = {}
	for _, name in ipairs({ "error", "ipairs", "math", "pairs", "pcall", "require", "setmetatable",
		"string", "table", "tonumber", "tostring", "type" }) do ALLOWED[name] = true end

	-- Global reads and writes of a file, from the bytecode listing of the VM
	-- that runs the tests: {{op = "get"|"set", name}}; nil if no listing.
	local function globals_of(path)
		local cmd = (jit and "luajit -bl " or "luac5.1 -p -l ") .. path .. " 2>&1"
		local pipe = io.popen(cmd)
		local out, listed = {}, false
		for line in pipe:lines() do
			local op, name = line:match("([GS]ETGLOBAL)%s.-; (.+)$")
			if not op then op, name = line:match("(G[GS]ET)%s.-; \"(.-)\"") end
			if line:match("^%s*%d+%s") or line:match("^%d%d%d%d ") or line:match("^main <") or line:match("^%-%- BYTECODE") then
				listed = true
			end
			if op then out[#out + 1] = { op = (op == "GETGLOBAL" or op == "GGET") and "get" or "set", name = name } end
		end
		pipe:close()
		return listed and out or nil
	end

	-- Every rule a meta source must follow; returns a list of violations.
	local function violations(path)
		local found = {}
		local globals = globals_of(path)
		if not globals then return { path .. ": no bytecode listing (is luac5.1 / luajit on PATH?)" } end
		for _, g in ipairs(globals) do
			if g.op == "set" then
				found[#found + 1] = path .. " sets the global " .. g.name
			elseif not ALLOWED[g.name] then
				found[#found + 1] = path .. " reads the global " .. g.name
			end
		end
		local n = 0
		for line in io.lines(path) do
			n = n + 1
			local where = path .. ":" .. n
			if line:find("%[=*%[") then found[#found + 1] = where .. " uses a long bracket; keep sources line-checkable" end
			local code = line:gsub("%-%-.*$", "")
			local at = 1
			while true do
				local i = code:find("%f[%w_]require%f[^%w_]", at)
				if not i then break end
				if not code:find('^require%("meta%.[%w_]+"%)', i) then
					found[#found + 1] = where .. " requires something other than a meta module"
				end
				at = i + 1
			end
			if code:find("%f[%w_]random") then found[#found + 1] = where .. " uses randomness" end
			if code:find("%f[%w_]pairs%(") and not line:find("order%-free") then
				found[#found + 1] = where .. " iterates with pairs() without an order-free note"
			end
		end
		return found
	end

	it("finds the meta modules", function()
		assert_true(#files >= 10)
	end)

	it("catch clocks, IO, globals and unordered iteration in a probe", function()
		local probe = os.tmpname()
		local f = assert(io.open(probe, "w"))
		f:write(table.concat({
			'local a = _G.os',
			'local b = os["time"]',
			'local c = require("os")',
			'local r = require',
			'for k in next, {} do end',
			'for k in pairs({}) do end',
			'local x = math.random(3)',
			'counter = 1',
			'local s = [[text]]',
		}, "\n"))
		f:close()
		local found = table.concat(violations(probe), "\n")
		os.remove(probe)
		for _, what in ipairs({ "reads the global _G", "reads the global os", "reads the global next",
			"sets the global counter", "requires something other", "without an order-free note",
			"uses randomness", "long bracket" }) do
			assert_true(found:find(what, 1, true) ~= nil, "the probe must trigger: " .. what .. "\n" .. found)
		end
		assert_true(select(2, found:gsub("requires something other", "")) == 2, "require(\"os\") and the alias")
	end)

	it("hold for every meta module: pure Lua, no clock, IO, randomness or Defold API", function()
		for _, path in ipairs(files) do
			local found = violations(path)
			assert_eq(#found, 0, table.concat(found, "\n"))
		end
	end)
end)
