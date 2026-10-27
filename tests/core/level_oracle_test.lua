-- The level rules of section 2 against an oracle written from the text of the
-- specification (tests/core/oracle_a.lua): the verdict and the rule of core.load_level
-- on random and on mutated levels, and the fillability of rule 2.1.7 on random boards.
-- Audit A.

local core = require("core.game")
local O = require("tests.core.oracle_a")
local lcg, copy, random_level, mutate, fixed_level = O.lcg, O.copy, O.random_level, O.mutate, O.fixed_level

local function describe_set(set)
	local list = {}
	for k in pairs(set) do list[#list + 1] = k end
	table.sort(list)
	return table.concat(list, ",")
end

describe("core level oracle: rules 2.0-2.1.9 on random levels (audit A)", function()
	it("core.load_level and the oracle agree on the stage and the rules of 250 random and mutated levels", function()
		local rnd = lcg(31337)
		local stages = { [0] = 0, 0, 0, 0 }
		for n = 1, 250 do
			local lvl = random_level(rnd)
			if rnd(100) <= 55 then lvl = mutate(rnd, lvl) end
			local stage, rules = O.validate(copy(lvl))
			local level, errs = core.load_level(copy(lvl))
			stages[stage] = stages[stage] + 1
			local label = "level " .. n
			if stage == 0 then
				-- past 2.1.9 the oracle cannot judge 2.1.10 (the start shuffle); the core may only fail there
				if level == nil then
					local got_stage = O.stage_of(errs)
					assert_eq(got_stage, 4, label .. ": " .. table.concat(errs, " | "))
				end
			else
				assert_eq(level, nil, label .. ": the oracle rejects at stage " .. stage .. " (" .. describe_set(rules) .. ")")
				local got_stage, got_rules = O.stage_of(errs)
				assert_eq(got_stage, stage, label .. ": " .. table.concat(errs, " | "))
				assert_eq(describe_set(got_rules), describe_set(rules), label .. ": " .. table.concat(errs, " | "))
			end
		end
		-- the corpus must exercise every stage
		assert_true(stages[0] > 30, "valid levels: " .. stages[0])
		assert_true(stages[1] > 25, "schema errors: " .. stages[1])
		assert_true(stages[2] > 8, "geometry and element errors: " .. stages[2])
		assert_true(stages[3] > 3, "fillability errors: " .. stages[3])
	end)
end)

describe("core level oracle: fillability 2.1.7 (audit A)", function()
	it("the empty cells that core.load_level reports on B0 and B1 are those of the oracle (300 levels)", function()
		local rnd = lcg(5)
		local rejected, b1_only = 0, 0
		for n = 1, 300 do
			local lvl = fixed_level(rnd)
			local level, errs = core.load_level(copy(lvl))
			local e0, e1 = O.empties(lvl, true), O.empties(lvl, false)
			assert_true(e0 ~= nil and e1 ~= nil, "level " .. n .. " must settle")
			local got0, got1, other = {}, {}, {}
			if level == nil then
				for _, e in ipairs(errs) do
					local x, y = string.match(e, "^2%.1%.7 cell stays empty on board B0 at (%d+),(%d+)$")
					if x then got0[x .. "," .. y] = true
					else
						x, y = string.match(e, "^2%.1%.7 cell stays empty on board B1 at (%d+),(%d+)$")
						if x then got1[x .. "," .. y] = true else other[#other + 1] = e end
					end
				end
			end
			local early = false
			for _, e in ipairs(other) do
				if not string.find(e, "^2%.1%.8 segment bottom") and not string.find(e, "^2%.1%.10") then early = true end
			end
			if not early then
				assert_eq(describe_set(got0), describe_set(e0), "B0 of level " .. n)
				assert_eq(describe_set(got1), describe_set(e1), "B1 of level " .. n)
				if level == nil then rejected = rejected + 1 end
				if next(e0) == nil and next(e1) ~= nil then b1_only = b1_only + 1 end
			end
		end
		assert_true(rejected > 25, "fillability must reject some levels: " .. rejected)
	end)
end)
