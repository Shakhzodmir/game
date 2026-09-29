local C = require("meta.config")
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
		assert_eq(C.levels.count, 100)
		assert_same(C.continues.prices, { 700, 1400, 2100 })
		assert_eq(C.continues.moves, 5)
		assert_eq(C.ad_moves, 3)
		assert_eq(C.streak.from_level, 12)
	end)

	it("has the booster table of the spec", function()
		local expected = {
			stick = { "in", 8, 3, 450 }, row_light = { "in", 14, 2, 600 },
			col_light = { "in", 18, 2, 600 }, remix = { "in", 25, 2, 450 },
			riff = { "pre", 12, 3, 600 }, sub = { "pre", 16, 3, 750 }, disco = { "pre", 22, 3, 900 },
		}
		assert_eq(#C.boosters, 7)
		for _, b in ipairs(C.boosters) do
			assert_same({ b.kind, b.unlock, b.gift, b.pack_price }, expected[b.id], b.id)
		end
		assert_eq(C.pack_size, 3)
	end)

	it("only refers to known boosters", function()
		for _, id in ipairs(C.level_chest.rotation) do assert_true(inventory.def(id) ~= nil, id) end
		assert_true(inventory.def(C.level_chest.fallback) ~= nil)
		for _, r in ipairs(C.streak.rewards) do
			assert_eq(inventory.def(r.booster).kind, "pre", r.booster)
		end
	end)

	it("accepts content/districts.json: 5 districts, 133 stars", function()
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
		assert_same(ids, { "cafe", "jazz", "square", "stadium", "garage" })
		assert_same(stars, { 11, 20, 28, 34, 40 })
		assert_eq(total, 133)
	end)
end)

describe("meta source rules", function()
	local files = {}
	local p = io.popen("ls meta/*.lua")
	for line in p:lines() do files[#files + 1] = line end
	p:close()

	local function each_line(fn)
		for _, path in ipairs(files) do
			local n = 0
			for line in io.lines(path) do
				n = n + 1
				fn(path .. ":" .. n, line)
			end
		end
	end

	it("finds the meta modules", function()
		assert_true(#files >= 9)
	end)

	it("uses no clock, randomness, IO or Defold API", function()
		local forbidden = { "%f[%w_]os%.", "%f[%w_]io%.", "math%.random", "%f[%w_]sys%.", "%f[%w_]msg%.",
			"%f[%w_]gui%.", "%f[%w_]go%.", "%f[%w_]vmath%.", "%f[%w_]json%.", "%f[%w_]socket%." }
		each_line(function(where, line)
			local code = line:gsub("%-%-.*$", "")
			for _, pat in ipairs(forbidden) do
				assert_false(code:find(pat), where .. " uses " .. pat .. ": " .. line)
			end
		end)
	end)

	it("marks every pairs() loop as order-free", function()
		each_line(function(where, line)
			local code = line:gsub("%-%-.*$", "")
			if code:find("%f[%w_]pairs%(") then
				assert_true(line:find("order%-free"), where .. " iterates with pairs() without an order-free note")
			end
		end)
	end)
end)
