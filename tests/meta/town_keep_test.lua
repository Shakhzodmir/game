-- The town entries of districts this build does not know.
--
-- A newer build (the next part of the game) adds districts. If the live site is rolled back to an older build, that
-- build loads a save with entries for districts it has never heard of, and its first re-save used to drop them: the
-- purchases were gone for good (the stars spent on them stayed spent) and, signed in, the account's copy was replaced
-- by the degraded one. meta/town.lua restore keeps such entries as they are, within the bounds of C.town_keep, so
-- the save written back carries them and the newer build finds every task again (header of meta/save.lua,
-- "Rollbacks").

local save = require("meta.save")
local savecode = require("meta.savecode")
local cloudsync = require("meta.cloudsync")
local town = require("meta.town")
local util = require("meta.util")
local C = require("meta.config")
local Meta = require("meta.meta")
local H = require("tests.meta.helper")

local T = H.T0
local KEEP = C.town_keep

local function resign(t)
	t.checksum = save.checksum(t)
	return t
end

-- Two districts without levels (a fixture: the config of this build stays bound while it is validated).
local function fixture(n)
	local list = {
		{ id = "a", name = { en = "A" }, chest = { coins = 100, boosters = {} },
			tasks = { { id = "a1", cost = 1, stem = "beat" }, { id = "a2", cost = 2, stem = "bass" } } },
		{ id = "b", name = { en = "B" }, chest = { coins = 200, boosters = {} },
			tasks = { { id = "b1", cost = 1, stem = "drums" }, { id = "b2", cost = 3, stem = "keys" } } },
	}
	local out = {}
	for i = 1, n do out[i] = list[i] end
	return { districts = out }
end

-- Runs fn(data) with the districts of `src` validated, and binds the content of this build again afterwards.
local function with_data(src, fn)
	local data = town.validate(src)
	local ok, err = pcall(fn, data)
	town.validate(H.districts())
	if not ok then error(err, 0) end
end

-- A table nested `levels` deep: the table itself is level 1.
local function nested(levels)
	local v = { leaf = 1 }
	for _ = 2, levels do v = { inner = v } end
	return v
end

describe("town.restore: districts this build does not know", function()
	it("keeps the entry as it is: a copy that shares nothing with the save", function()
		with_data(fixture(1), function(data)
			local raw = {
				a = { done = { "a1" }, chest_claimed = false, view = "day" },
				z = { done = { "z1", "z2", "z3" }, chest_claimed = true, view = "concert", gift = { n = 2, tags = { "x" } } },
			}
			local t = town.restore(raw, data)
			assert_same(t.z, { done = { "z1", "z2", "z3" }, chest_claimed = true, view = "concert", gift = { n = 2, tags = { "x" } } })
			assert_true(t.z ~= raw.z and t.z.done ~= raw.z.done and t.z.gift ~= raw.z.gift, "a copy")
			assert_same(t.a, { done = { "a1" }, chest_claimed = false, view = "day" })
		end)
	end)

	it("does not repair it: what is right for the newer build is not this build's to judge", function()
		with_data(fixture(1), function(data)
			local weird = { done = 99, view = "night", chest_claimed = 1, later = { 1, 2, 3 } }
			assert_same(town.restore({ z = weird }, data).z, weird)
			-- while a district of this build is repaired as always
			assert_same(town.restore({ a = weird }, data).a, { done = {}, chest_claimed = false, view = "day" })
		end)
	end)

	it("drops what is not a bounded entry of plain data, and keeps the rest", function()
		assert_true(KEEP ~= nil, "meta/config.lua has the bounds (town_keep)")
		with_data(fixture(1), function(data)
			local raw = {
				good = { done = { "g1" } },
				at_the_depth_cap = nested(KEEP.depth),
				number = 5, text = "x", flag = true,
				huge = { blob = string.rep("x", KEEP.bytes) },
				too_deep = nested(KEEP.depth + 1),
				holes = { [1] = "x", [2] = "y", [4] = "z" },
				mixed = { 1, 2, x = 3 },
				not_a_number = { v = 0 / 0 }, infinite = { v = math.huge },
				a_function = { f = print },
				[""] = { done = {} },
				[string.rep("k", KEEP.id_bytes + 1)] = { done = {} },
				[7] = { done = {} },
			}
			local t = town.restore(raw, data)
			local kept = {}
			for id in pairs(t) do kept[#kept + 1] = id end -- order-free: sorted below
			table.sort(kept, function(x, y) return tostring(x) < tostring(y) end)
			assert_same(kept, { "a", "at_the_depth_cap", "good" })
			assert_same(t.good, { done = { "g1" } })
			assert_same(t.at_the_depth_cap, nested(KEEP.depth))
		end)
	end)

	it("measures an entry as its length in the text form of a save code: the cap is that many bytes", function()
		assert_true(KEEP ~= nil, "meta/config.lua has the bounds (town_keep)")
		with_data(fixture(1), function(data)
			-- { pad = { true, true, ... } } is 10 bytes and one more for every true
			local function entry(k)
				local pad = {}
				for i = 1, k do pad[i] = true end
				return { pad = pad }
			end
			assert_eq(#savecode.pack(entry(KEEP.bytes - 10)), KEEP.bytes)
			assert_true(town.restore({ z = entry(KEEP.bytes - 10) }, data).z ~= nil, "exactly the cap")
			assert_eq(town.restore({ z = entry(KEEP.bytes - 9) }, data).z, nil, "one byte over")
			-- strings, numbers and keys are measured the same way: a long one does not slip through
			assert_eq(town.restore({ z = { blob = string.rep("x", KEEP.bytes) } }, data).z, nil)
			assert_eq(town.restore({ z = { [string.rep("k", KEEP.bytes)] = 1 } }, data).z, nil)
			local numbers = {}
			for i = 1, KEEP.bytes / 4 do numbers[i] = 1 / (i + 2) end -- about 20 bytes each in the code
			assert_eq(town.restore({ z = { numbers = numbers } }, data).z, nil)
		end)
	end)

	it("keeps at most the cap, the first ones in id order, whatever order the save listed them in", function()
		assert_true(KEEP ~= nil, "meta/config.lua has the bounds (town_keep)")
		with_data(fixture(1), function(data)
			local n = KEEP.districts + 10
			local forward, backward = {}, {}
			for i = 1, n do forward[string.format("zz%03d", i)] = { done = { "t" } } end
			for i = n, 1, -1 do backward[string.format("zz%03d", i)] = { done = { "t" } } end
			for _, raw in ipairs({ forward, backward }) do
				local t, count = town.restore(raw, data), 0
				for id in pairs(t) do -- order-free: a count
					if id ~= "a" then count = count + 1 end
				end
				assert_eq(count, KEEP.districts)
				assert_true(t[string.format("zz%03d", KEEP.districts)] ~= nil, "the last one that fits")
				assert_eq(t[string.format("zz%03d", KEEP.districts + 1)], nil, "the first one over the cap")
			end
		end)
	end)

	it("lets a bad entry go without using up the cap", function()
		assert_true(KEEP ~= nil, "meta/config.lua has the bounds (town_keep)")
		with_data(fixture(1), function(data)
			local raw = {}
			for i = 1, KEEP.districts do raw[string.format("bad%03d", i)] = 5 end -- sorts before the good ones
			for i = 1, KEEP.districts do raw[string.format("zz%03d", i)] = { done = {} } end
			local t, count = town.restore(raw, data), 0
			for id in pairs(t) do -- order-free: a count
				if id ~= "a" then count = count + 1 end
			end
			assert_eq(count, KEEP.districts)
		end)
	end)

	it("picks the ones that stay without sorting them all: the work grows with the number of ids", function()
		assert_true(KEEP ~= nil, "meta/config.lua has the bounds (town_keep)")
		with_data(fixture(1), function(data)
			-- a forged save may hold tens of thousands of small entries (a save code takes 200,000 characters)
			local n = 20000
			local raw = {}
			for i = 1, n do raw[string.format("z%05d", i)] = {} end
			local calls, real = 0, util.str_less
			util.str_less = function(x, y) calls = calls + 1; return real(x, y) end
			local ok, t = pcall(town.restore, raw, data)
			util.str_less = real
			assert_true(ok, tostring(t))
			-- about one comparison per id; sorting them all took about fifteen
			assert_true(calls < 3 * n, calls .. " comparisons for " .. n .. " ids")
			for i = 1, KEEP.districts do assert_true(t[string.format("z%05d", i)] ~= nil, "z" .. i) end
			assert_eq(t[string.format("z%05d", KEEP.districts + 1)], nil, "the first one over the cap")
		end)
	end)

	it("is live again when a build learns the district: the kept entry is read like any other", function()
		local kept
		with_data(fixture(1), function(data)
			kept = town.restore({
				a = { done = { "a1", "a2" }, chest_claimed = true, view = "day" },
				b = { done = { "b2", "gone", "b1" }, chest_claimed = false, view = "concert" },
			}, data)
			assert_same(kept.b, { done = { "b2", "gone", "b1" }, chest_claimed = false, view = "concert" }, "kept as it is")
		end)
		with_data(fixture(2), function(data)
			local t = town.restore(kept, data)
			assert_same(t.b, { done = { "b1", "b2" }, chest_claimed = false, view = "concert" },
				"read in task order, an unknown task id gone")
		end)
	end)
end)

describe("save: a save with districts this build does not know", function()
	-- a save of this build with one entry added by a newer build
	local function with_entry(entry)
		local m = H.new(5)
		H.advance_to(m, 4)
		local t = H.json_round_trip(m:serialize())
		t.town.unknown_district = entry
		return resign(t)
	end
	local ENTRY = { done = { "task_a", "task_b" }, chest_claimed = false, view = "concert" }

	it("loads clean and writes the very same save back", function()
		local t = with_entry(ENTRY)
		local m, info = Meta.load(H.districts(), t, nil, 1, T)
		assert_eq(info.source, "current")
		assert_false(m:dirty(), "nothing to rewrite")
		assert_same(m:serialize(), t)
	end)

	it("keeps the entry through later changes", function()
		local m = Meta.load(H.districts(), with_entry(ENTRY), nil, 1, T)
		H.win(m, T)
		m:set_setting("music", 0.5)
		local s = m:serialize()
		assert_same(s.town.unknown_district, ENTRY)
		assert_eq(save.checksum(s), s.checksum, "and the checksum covers it")
		assert_true(save.decode(H.json_round_trip(s)) ~= nil)
	end)

	it("keeps it when the previous slot is the one that loads", function()
		local older = with_entry(ENTRY)
		local broken = H.json_round_trip(older)
		broken.wallet.coins = 999999 -- the checksum no longer fits
		local m, info = Meta.load(H.districts(), broken, older, 1, T)
		assert_eq(info.source, "previous")
		assert_same(m:serialize().town.unknown_district, ENTRY)
	end)

	it("does not show it anywhere: the districts of the meta are this build's own", function()
		local with = Meta.load(H.districts(), with_entry(ENTRY), nil, 1, T)
		local bare = with_entry(ENTRY)
		bare.town.unknown_district = nil
		local without = Meta.load(H.districts(), resign(bare), nil, 1, T)
		assert_eq(#with:districts(), #H.districts().districts)
		assert_same(with:districts(), without:districts())
		assert_eq(with:current_district(), without:current_district())
		assert_error(function() with:district("unknown_district") end, "unknown district")
		assert_error(function() with:complete_task("unknown_district", "task_a") end, "unknown district")
	end)

	it("drops an entry that is garbage and loads the rest as always", function()
		local t = with_entry({ blob = string.rep("x", 100000) })
		local m, info = Meta.load(H.districts(), t, nil, 1, T)
		assert_eq(info.source, "current")
		assert_eq(m:level_to_play(), 4)
		assert_eq(m:serialize().town.unknown_district, nil)
	end)

	it("loads at once whatever many and huge entries a forged save holds", function()
		assert_true(KEEP ~= nil, "meta/config.lua has the bounds (town_keep)")
		local t = H.json_round_trip(H.new(5):serialize())
		for i = 1, 1000 do t.town["z" .. i] = { done = { "a", "b" }, view = "day" } end
		local giant = {}
		for i = 1, 10000 do giant[i] = i end
		t.town.giant = { list = giant }
		resign(t)
		-- about 3e6 on Lua 5.1, most of it the checksum and the copy of the forged input itself
		local finished, res = H.within_budget(8000000, Meta.load, H.districts(), t, nil, 1, T)
		assert_true(finished, "Meta.load did not finish within the budget")
		assert_true(res[1], tostring(res[2]))
		local s = res[2]:serialize()
		local known = {}
		for _, d in ipairs(H.districts().districts) do known[d.id] = true end
		local count = 0
		for id in pairs(s.town) do -- order-free: a count
			if not known[id] then count = count + 1 end
		end
		assert_eq(s.town.giant, nil, "the giant entry is dropped")
		assert_eq(count, KEEP.districts, "and only the cap of the small ones stays")
	end)
end)

describe("a rollback: the older build meets the save of a newer one", function()
	-- Four districts more than this build has, whatever number that is (the branches that add districts merge into
	-- this one: nothing here counts from 15 or from 300).
	local BASE = #H.districts().districts
	local LAST_LEVEL = H.districts().districts[BASE].last
	local newer = H.newer_districts(4)
	local NEW_IDS = H.newer_ids(4)

	-- A player of the newer build who bought every task of every district: its save, after a JSON round trip, and
	-- the meta that wrote it.
	local function newer_save(levels)
		return H.as_build(newer, function()
			local m = Meta.new(newer, 7)
			H.advance_to(m, levels)
			H.build_everything(m)
			return H.json_round_trip(m:serialize()), m
		end)
	end

	it("loads the save, plays on and writes it back: the newer build finds every task done", function()
		local saved, was = newer_save(8)
		for _, id in ipairs(NEW_IDS) do assert_true(saved.town[id] ~= nil, id) end
		local old = Meta.load(H.districts(), saved, nil, 1, T)
		assert_eq(#old:districts(), BASE, "it shows only its own districts")
		H.win(old, T)
		old:set_setting("music", 0.5)
		local back = H.json_round_trip(old:serialize())
		assert_true(save.decode(back) ~= nil, "the checksum holds")
		H.as_build(newer, function()
			local again, info = Meta.load(newer, back, nil, 1, T)
			assert_eq(info.source, "current")
			assert_same(info.district_chests, {}, "no chest is paid a second time")
			for _, id in ipairs(NEW_IDS) do
				local view = again:district(id)
				assert_eq(view.done, view.total, id)
				assert_true(view.chest_claimed, id)
				assert_same(view, was:district(id), id)
			end
			assert_eq(again:coins(), old:coins(), "nothing was paid or taken")
			assert_eq(again:stars(), old:stars())
			assert_eq(again:current_district(), nil, "the town is complete")
		end)
	end)

	it("does the same with a player who is far into the newer levels (the old build is past its last level)", function()
		local saved, was = newer_save(LAST_LEVEL + 45)
		assert_true(saved.progress.beaten > LAST_LEVEL)
		local old = Meta.load(H.districts(), saved, nil, 1, T)
		assert_true(old:all_done(), "the older build has no level left to give")
		old:set_setting("music", 0.5)
		local back = H.json_round_trip(old:serialize())
		H.as_build(newer, function()
			local again = Meta.load(newer, back, nil, 1, T)
			assert_eq(again:level_to_play(), saved.progress.beaten + 1, "the levels are kept too")
			for _, id in ipairs(NEW_IDS) do assert_same(again:district(id), was:district(id), id) end
			assert_eq(again:coins(), was:coins())
			assert_eq(again:stars(), was:stars())
		end)
	end)

	it("keeps them through two rollbacks and a new update in between", function()
		local saved = newer_save(8)
		local first = H.json_round_trip(Meta.load(H.districts(), saved, nil, 1, T):serialize())
		local updated = H.as_build(newer, function()
			local m = Meta.load(newer, first, nil, 1, T)
			m:set_setting("sfx", 0.5)
			return H.json_round_trip(m:serialize())
		end)
		local second = Meta.load(H.districts(), updated, nil, 1, T)
		second:set_setting("music", 0.25)
		local back = H.json_round_trip(second:serialize())
		for _, id in ipairs(NEW_IDS) do assert_same(back.town[id], saved.town[id], id) end
	end)

	it("goes through the save code both ways", function()
		local saved = newer_save(8)
		local tbl, sum = savecode.read(savecode.encode(saved), H.districts())
		assert_true(tbl ~= nil, tostring(sum))
		local old = Meta.load(H.districts(), tbl, nil, 1, T)
		old:set_setting("music", 0.5)
		local code = savecode.encode(old:serialize())
		assert_true(#code < savecode.MAX_CODE / 4, "a small code: " .. #code)
		local back = savecode.read(code, H.districts())
		assert_true(back ~= nil)
		for _, id in ipairs(NEW_IDS) do assert_same(back.town[id], saved.town[id], id) end
	end)

	it("still fits the save code when every kept entry is as heavy as it may be", function()
		assert_true(KEEP ~= nil, "meta/config.lua has the bounds (town_keep)")
		-- The worst case of the bounds: the most entries, each of exactly the most bytes, under the longest ids, of
		-- data that does not compress, on top of the save of a player far into the levels: about 103,000 characters
		-- here, 106,000 on the save of the release candidate (docs/design/meta-economy.md). The filler text of the
		-- first version of this test compressed, and the figure in the document came from it: a fifth too low.
		local t = H.as_build(newer, function()
			local m = Meta.new(newer, 7)
			H.advance_to(m, LAST_LEVEL + 50)
			return H.json_round_trip(m:serialize())
		end)
		local x = 12345
		local function noise(n) -- text that does not compress (every product stays below 2^53: the same on every VM)
			local out = {}
			for i = 1, n do
				x = (x * 16807) % 2147483647
				out[i] = string.char(33 + x % 90)
			end
			return table.concat(out)
		end
		local blob_bytes = KEEP.bytes -- the longest blob of an entry { blob = ... } that fits the cap
		while #savecode.pack({ blob = string.rep("x", blob_bytes) }) > KEEP.bytes do blob_bytes = blob_bytes - 1 end
		local ids = {}
		for i = 1, KEEP.districts do
			ids[i] = string.rep("d", KEEP.id_bytes - 3) .. string.format("%03d", i)
			t.town[ids[i]] = { blob = noise(blob_bytes) }
		end
		assert_eq(#savecode.pack(t.town[ids[1]]), KEEP.bytes, "every entry weighs the most it may")
		resign(t)
		local m = Meta.load(H.districts(), t, nil, 1, T)
		local s = m:serialize()
		for _, id in ipairs(ids) do assert_true(s.town[id] ~= nil, "kept: " .. id) end
		local code = savecode.encode(s)
		assert_true(#code > 90000, "the worst case is a big one: " .. #code)
		assert_true(#code < savecode.MAX_CODE * 0.6, "the code is " .. #code .. " of " .. savecode.MAX_CODE)
		assert_true(savecode.read(code, H.districts()) ~= nil)
	end)

	it("never counts in the progress numbers of the cloud sync", function()
		local saved = newer_save(10)
		local read = cloudsync.summarize(saved, H.districts())
		local bare = H.json_round_trip(saved)
		for _, id in ipairs(NEW_IDS) do bare.town[id] = nil end
		local without = cloudsync.summarize(resign(bare), H.districts())
		for _, k in ipairs({ "beaten", "coins", "stars", "earned", "tasks", "wins", "salt" }) do
			assert_eq(read[k], without[k], k)
		end
		assert_true(read.checksum ~= without.checksum)
		assert_eq(cloudsync.compare(read, without), "equal")
	end)

	it("is level with the account's copy when the older build writes it back: a quiet upload that carries the tasks", function()
		local saved = newer_save(10)
		local in_account = cloudsync.summarize(saved, H.districts())
		-- untouched, the older build writes the same save: nothing to send
		local old = Meta.load(H.districts(), saved, nil, 1, T)
		local same = H.json_round_trip(old:serialize())
		assert_eq(cloudsync.plan(cloudsync.summarize(same, H.districts()), in_account, "same").action, "none")
		-- after a change it differs only in details: the "equal progress, other checksum" answer of the sync
		old:set_setting("music", 0.5)
		local back = H.json_round_trip(old:serialize())
		local loc = cloudsync.summarize(back, H.districts())
		assert_eq(cloudsync.compare(loc, in_account), "equal")
		local plan = cloudsync.plan(loc, in_account, "same")
		assert_eq(plan.action, "upload")
		assert_true(plan.quiet)
		assert_eq(cloudsync.background(loc, in_account), "upload")
		-- what goes up holds every entry of the newer build
		local uploaded = savecode.read(savecode.encode(back), H.districts())
		for _, id in ipairs(NEW_IDS) do assert_same(uploaded.town[id], saved.town[id], id) end
	end)
end)
