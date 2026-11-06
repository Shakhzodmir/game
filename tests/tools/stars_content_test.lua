-- The shipped star thresholds (content/levels/stars.json) against the level files, and the validator's checks.

local common = require("tools.bot.common")
local Stars = require("tools.stars")
local stars = require("meta.stars")

local DIR = "content/levels"

local function load()
	local data = common.decode(assert(common.read_file(DIR .. "/stars.json")))
	return data
end

local function copy(v)
	return common.decode(common.encode(v))
end

describe("star thresholds (content/levels/stars.json)", function()
	it("pass the validator for the 100 shipped levels", function()
		local data = load()
		local errs = Stars.check(data, DIR)
		assert_same(errs, {})
	end)

	it("have three growing thresholds for every level", function()
		local data = load()
		for id = 1, 100 do
			local e = data.levels[tostring(id)]
			assert_true(e ~= nil, "level " .. id)
			assert_same(stars.check_entry(e), {}, "level " .. id)
		end
	end)

	it("name the five super hard levels of 60, 70, 80, 90 and 100 as concerts, and only them", function()
		local data = load()
		for id = 1, 100 do
			local want = (id >= 60 and id % 10 == 0) and "concert" or "normal"
			assert_eq(data.levels[tostring(id)].kind, want, "level " .. id)
			assert_eq(stars.is_concert(data, id), want == "concert")
		end
	end)

	it("make 3 stars reachable but not easy: a bot got there, at most 30% of its wins do", function()
		local data = load()
		for id = 1, 100 do
			local e = data.levels[tostring(id)]
			assert_true(e.best >= e.t[3], "level " .. id .. ": best " .. e.best .. " under 3 stars " .. e.t[3])
			assert_true(e.share3 <= Stars.MAX_SHARE3, "level " .. id .. " share " .. e.share3)
			assert_true(e.share3 >= 1, "level " .. id .. ": a bot should reach 3 stars sometimes")
		end
	end)

	it("ask more of a concert than of a normal level of the same kind of play", function()
		-- same bot games, higher quantiles: the thresholds sit higher in the score spread of the level
		local sorted = {}
		for i = 1, 100 do sorted[i] = 10000 + i * 100 end
		local n = Stars.thresholds(sorted, "normal")
		local c = Stars.thresholds(sorted, "concert")
		for i = 1, 3 do assert_true(c[i] > n[i], "threshold " .. i) end
	end)

	it("are reproduced by the generator (a concert and a normal level, fixed seeds)", function()
		local data = load()
		for _, id in ipairs({ 7, 70 }) do
			local entry = assert(common.load_entry(common.level_path(tostring(id), DIR)))
			local e = assert(Stars.level(entry))
			local stored = data.levels[tostring(id)]
			assert_same(e.t, stored.t, "level " .. id)
			assert_eq(e.best, stored.best)
			assert_same(e.witness, stored.witness)
		end
	end)

	it("are refused by the validator when they are wrong", function()
		local data = load()
		local function problems(edit)
			local d = copy(data)
			edit(d.levels)
			return Stars.check(d, DIR)
		end
		assert_true(#problems(function(l) l["5"].t = { 300, 200, 100 } end) > 0, "descending")
		assert_true(#problems(function(l) l["5"].t[3] = l["5"].best + 100 end) > 0, "3 stars above the best bot score")
		assert_true(#problems(function(l) l["5"].share3 = 600 end) > 0, "3 stars too easy")
		assert_true(#problems(function(l) l["5"].sig = "0000000000000000" end) > 0, "the level changed")
		assert_true(#problems(function(l) l["5"] = nil end) > 0, "a level without thresholds")
		assert_true(#problems(function(l) l["101"] = copy(l["5"]) end) > 0, "a level without a file")
		assert_true(#problems(function(l) l["60"].kind = "normal" end) > 0, "a concert marked normal")
		assert_true(#problems(function(l) l["5"].kind = "concert" end) > 0, "a normal level marked concert")
		assert_true(#Stars.check({ version = 2, levels = {} }, DIR) > 0, "unknown version")
	end)

	it("replay: the witness game of a level scores its best again", function()
		local data = load()
		local only = { version = 1, seed_base = data.seed_base, levels = { ["3"] = data.levels["3"] } }
		-- check() wants every level of the directory: a one-level directory for the replay
		local errs = Stars.check(data, DIR, { replay = false })
		assert_same(errs, {})
		local entry = assert(common.load_entry(common.level_path("3", DIR)))
		local Run = require("tools.bot.run")
		local w = only.levels["3"].witness
		local r = Run.play(entry, { seed = w[2], bot = w[1], bot_seed = w[2], budget = entry.moves, finish = true })
		assert_true(r.won)
		assert_eq(r.score, only.levels["3"].best)
	end)

	it("keep the economy facts of the handoff true: 100 to 300 stars in the game, 124 for the town", function()
		local json = require("tools.lib.json")
		local f = assert(io.open("content/districts.json", "r"))
		local town = json.decode(f:read("*a"))
		f:close()
		local cost = 0
		for _, d in ipairs(town.districts) do
			for _, t in ipairs(d.tasks) do cost = cost + t.cost end
		end
		assert_eq(cost, 124)
		-- 1 star per win is not enough for the whole town (the last district needs better scores or replays),
		-- 3 stars per level is far more than enough: if the prices change, docs/handoff/WP-4.md must change with them
		assert_true(100 < cost and cost < 300)
	end)
end)
