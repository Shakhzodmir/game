-- tools/README.md stays in step with the tools: every option of the three
-- command lines is described, and the README names no option that does not
-- exist (the README once promised a report path and a --quiet that the code
-- did not keep).

local common = require("tools.bot.common")
local Run = require("tools.bot.run")
local Tune = require("tools.bot.tune")
local Levels = require("tools.levels")

local README = assert(common.read_file("tools/README.md"))

-- options of the worker processes that the tuner starts itself
local INTERNAL = { worker = true, wid = true, files = true, code = true }
-- named in the README but not options of these three tools: an example of a
-- typo that is refused, and the option of the test runner
local OTHER_OPTIONS = { level = true, filter = true }

local function known_options()
	local known = {}
	for _, mod in ipairs({ Run, Tune, Levels }) do
		for k in pairs(mod.OPTIONS.flags) do known[k] = true end -- order-independent (a set)
		for k in pairs(mod.OPTIONS.values) do known[k] = true end
	end
	return known
end

describe("tools README", function()
	it("describes every option a tool accepts", function()
		for name in pairs(known_options()) do -- order-independent (independent checks)
			if not INTERNAL[name] then
				assert_true(README:find("--" .. name, 1, true) ~= nil, "the README does not mention --" .. name)
			end
		end
	end)

	it("names no option that no tool accepts", function()
		local known = known_options()
		for name in README:gmatch("%-%-([%a][%w%-]*)") do
			assert_true(known[name] or OTHER_OPTIONS[name], "the README mentions --" .. name .. ", which no tool accepts")
		end
	end)

	it("describes every tuner flag, every plan corridor and the paths of the reports", function()
		for _, flag in ipairs(Tune.FLAG_ORDER) do
			assert_true(README:find("`" .. flag .. "`", 1, true) ~= nil, "no description of the flag " .. flag)
		end
		assert_true(README:find("docs/levels/tuning.md", 1, true) ~= nil)
		assert_true(README:find("docs/levels/tuning.json", 1, true) ~= nil)
		-- the corridors of the README are the code's
		for _, c in ipairs({ { "easy", 85, 95, 90 }, { "medium", 60, 75, 68 }, { "hard", 35, 50, 42 }, { "super_hard", 20, 30, 25 } }) do
			local cor = common.CORRIDOR[c[1]]
			assert_eq(cor.lo * 100, c[2])
			assert_eq(cor.hi * 100, c[3])
			assert_eq(cor.target * 100, c[4])
			local line = string.format("%s %d%% (%d–%d)", c[1], c[4], c[2], c[3])
			assert_true(README:find(line, 1, true) ~= nil, "the README should say: " .. line)
		end
		assert_true(README:find("--n` не меньше " .. Tune.MIN_N_WRITE, 1, true) ~= nil, "the minimum N for --write")
	end)

	it("every command line shown in a code block parses with its own tool", function()
		-- the README's examples must not use options the tools refuse
		local tools = { ["tools/bot/tune.lua"] = Tune, ["tools/bot/run.lua"] = Run, ["tools/levels.lua"] = Levels }
		local checked = 0
		for block in README:gmatch("```sh\n(.-)```") do
			for line in block:gmatch("[^\n]+") do
				for script, mod in pairs(tools) do -- order-independent (independent checks)
					local args = line:match("luajit " .. script:gsub("%p", "%%%0") .. " (.-)%s*#") or line:match("luajit " .. script:gsub("%p", "%%%0") .. " (.-)$")
					if args then
						local argv = {}
						for word in args:gmatch("%S+") do argv[#argv + 1] = word end
						local _, _, err = common.parse_args(argv, mod.OPTIONS.flags, mod.OPTIONS.values)
						assert_eq(err, nil, line)
						checked = checked + 1
					end
				end
			end
		end
		assert_true(checked >= 10, "found " .. checked .. " example lines")
	end)
end)
