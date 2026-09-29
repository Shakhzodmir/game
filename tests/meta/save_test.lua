local save = require("meta.save")
local Meta = require("meta.meta")
local H = require("tests.meta.helper")

local T = H.T0

-- A meta with some of everything: progress, a run in progress, records,
-- boosters, infinite lives, town progress, a view, settings and tutorials.
local function busy_meta()
	local m = H.new(99)
	H.advance_to(m, 23)
	H.lose(m, T + 10000)
	H.give(m, "coins", 1234)
	m:complete_task("cafe", "turntable")
	m:complete_task("cafe", "lamps")
	m:set_view("cafe", "concert")
	m:set_setting("music", 0.35)
	m:set_setting("input_mode", "taptap")
	m:set_setting("haptics", false)
	m:mark_tutorial_seen("first_swap")
	m:mark_tutorial_seen("booster_stick")
	m:start_level({ id = 23, difficulty = "hard" }, { "riff" }, T + 10000)
	m:note_move()
	m:buy_continue(1)
	return m
end

-- Re-signs a save table after a test edited it on purpose.
local function resign(t)
	t.checksum = save.checksum(t)
	return t
end

describe("save canonical form", function()
	it("is independent of key insertion order", function()
		local a, b = {}, {}
		a.x, a.y, a.z = 1, { p = true, q = "s" }, { 3, 2, 1 }
		b.z, b.y, b.x = { 3, 2, 1 }, { q = "s", p = true }, 1
		assert_eq(save.canonical(a), save.canonical(b))
	end)

	it("is the same on every VM", function()
		local t = { version = 1, b = { 1, 2.5, "x" }, a = { z = true, y = false }, n = 0, checksum = "ignored" }
		assert_eq(save.canonical(t), "{s1:a{s1:yFs1:zT}s1:b[n1;n2.5;s1:x]s1:nn0;s7:versionn1;}")
		assert_eq(save.checksum(t), "40723dcb5728ba36")
	end)

	it("rejects values a save cannot hold", function()
		assert_error(function() save.canonical({ f = print }) end, "unsupported value")
		assert_error(function() save.canonical({ x = 0 / 0 }) end, "non-finite")
		assert_error(function() save.canonical({ x = math.huge }) end, "non-finite")
		assert_error(function() save.canonical({ [1] = 1, a = 2 }) end, "mixes")
		assert_error(function() save.canonical({ [true] = 1 }) end, "unsupported key")
	end)

	it("changes the checksum when any value changes", function()
		local t = H.new():serialize()
		local sum = t.checksum
		t.wallet.coins = t.wallet.coins + 1
		assert_true(save.checksum(t) ~= sum)
		t.wallet.coins = t.wallet.coins - 1
		assert_eq(save.checksum(t), sum)
		t.prefs.tutorial[1] = "x"
		assert_true(save.checksum(t) ~= sum)
	end)
end)

describe("save round trip", function()
	it("writes only plain data with version and checksum", function()
		local t = busy_meta():serialize()
		assert_eq(t.version, 1)
		assert_eq(type(t.checksum), "string")
		assert_eq(#t.checksum, 16)
		local function plain(v, path)
			local tv = type(v)
			assert_true(tv == "number" or tv == "string" or tv == "boolean" or tv == "table", path)
			if tv == "table" then
				for k, x in pairs(v) do
					assert_true(type(k) == "string" or type(k) == "number", path)
					plain(x, path .. "." .. tostring(k))
				end
			end
		end
		plain(t, "save")
	end)

	it("settles an open attempt the same way on every load", function()
		local m = busy_meta()
		local t = m:serialize()
		local m2, info = Meta.load(H.districts(), t, nil, 1, T + 10000)
		assert_eq(info.source, "current")
		assert_eq(info.version, 1)
		assert_false(info.migrated)
		assert_eq(info.interrupted, "loss", "the open attempt had a move")
		-- compare with the original after the same settlement
		local m3 = Meta.load(H.districts(), m:serialize(), nil, 1, T + 10000)
		assert_same(m2:serialize(), m3:serialize())
	end)

	it("restores the same state without an open attempt", function()
		local m = busy_meta()
		m:finish_level({ won = true, level_id = 23, moves_at_win = 1 }, T + 10000)
		local t = m:serialize()
		local m2, info = Meta.load(H.districts(), t, nil, 1, T + 10000)
		assert_eq(info.interrupted, nil)
		assert_same(m2:serialize(), t)
		assert_eq(m2:coins(), m:coins())
		assert_same(m2:settings(), m:settings())
		assert_same(m2:seen_tutorials(), { "booster_stick", "first_swap" })
		assert_same(m2:districts(), m:districts())
		assert_same(m2:inventory(), m:inventory())
		assert_same(m2:lives(T + 10000), m:lives(T + 10000))
		assert_same(m2:attempts(23), { attempts = 2, fails = 0 })
	end)

	it("survives a JSON round trip", function()
		local m = busy_meta()
		local t = m:serialize()
		local back = H.json_round_trip(t)
		assert_eq(save.checksum(back), t.checksum)
		local m2, info = Meta.load(H.districts(), back, nil, 1, T + 10000)
		assert_eq(info.source, "current")
		assert_eq(m2:settings().music, 0.35)
	end)

	it("does not share tables with the live state", function()
		local m = busy_meta()
		local t = m:serialize()
		t.wallet.coins = 0
		assert_true(m:coins() > 0)
	end)
end)

describe("save fallback", function()
	local good, older
	before_each(function()
		local m = H.new(5)
		H.advance_to(m, 4)
		older = m:serialize()
		H.win(m, T)
		good = m:serialize()
	end)

	it("uses the previous slot when the current one is corrupted", function()
		local bad = H.json_round_trip(good)
		bad.wallet.coins = 999999
		local m, info = Meta.load(H.districts(), bad, older, 1, T)
		assert_eq(info.source, "previous")
		assert_eq(info.errors.current, "bad_checksum")
		assert_eq(m:level_to_play(), 4)
	end)

	it("uses the previous slot when the current one is missing or not a save", function()
		local m, info = Meta.load(H.districts(), nil, older, 1, T)
		assert_eq(info.source, "previous")
		assert_eq(info.errors.current, "missing")
		assert_eq(m:level_to_play(), 4)
		m, info = Meta.load(H.districts(), "garbage", older, 1, T)
		assert_eq(info.source, "previous")
	end)

	it("starts fresh when both slots are unusable", function()
		local a = H.json_round_trip(good)
		a.checksum = nil
		local b = H.json_round_trip(older)
		b.progress.beaten = 99
		local m, info = Meta.load(H.districts(), a, b, 1000, T)
		assert_eq(info.source, "fresh")
		assert_same(info.errors, { current = "bad_checksum", previous = "bad_checksum" })
		assert_eq(m:level_to_play(), 1)
		assert_eq(m:coins(), 500)
		assert_eq(m:salt(), 1001)
		m, info = Meta.load(H.districts(), nil, nil, 7, T)
		assert_eq(info.source, "fresh")
		assert_eq(m:salt(), 8)
	end)

	it("reads a save of a newer app version as far as it understands it", function()
		local t = H.json_round_trip(good)
		t.version = 2
		t.feature_from_the_future = { level = 3 }
		t.wallet.gems = 40
		local m, info = Meta.load(H.districts(), resign(t), older, 1, T)
		assert_eq(info.source, "current")
		assert_eq(info.version, 2)
		assert_true(info.newer)
		assert_false(info.migrated)
		assert_eq(m:level_to_play(), 5)
		local s = m:serialize()
		assert_eq(s.version, 1)
		assert_eq(s.feature_from_the_future, nil)
		assert_eq(s.wallet.gems, nil)
	end)

	it("rejects a bad version and a bad salt", function()
		local t = H.json_round_trip(good)
		t.version = nil
		assert_same({ save.decode(t) }, { nil, "bad_version" })
		t.version = 0
		assert_same({ save.decode(resign(t)) }, { nil, "bad_version" })
		t = H.json_round_trip(good)
		t.salt = 0
		local _, info = Meta.load(H.districts(), resign(t), older, 1, T)
		assert_eq(info.source, "previous")
		assert_eq(info.errors.current, "bad_salt")
	end)

	it("rejects data a save cannot hold", function()
		local t = H.json_round_trip(good)
		t.extra = { f = print }
		assert_same({ save.decode(t) }, { nil, "bad_data" })
	end)

	it("repairs out-of-range fields of a save with a valid checksum", function()
		local t = H.json_round_trip(good)
		t.wallet.coins = -50
		t.wallet.stick = "many"
		t.lives.count = 42
		t.progress.levels = { ["3"] = { attempts = 2, fails = -1 }, bogus = { attempts = 1 }, ["0"] = {} }
		t.progress.run = { level_id = 77, difficulty = "easy" }
		t.town = { cafe = { done = 99, view = "night" }, atlantis = { done = 3 } }
		t.prefs = { settings = { music = 7, language = "fr", haptics = "yes" }, tutorial = { "b", "a", "b", 5 } }
		t.stats = nil
		local m, info = Meta.load(H.districts(), resign(t), nil, 1, T)
		assert_eq(info.source, "current")
		assert_eq(m:coins(), 0)
		assert_eq(m:booster_count("stick"), 0)
		assert_eq(m:lives(T).count, 5)
		assert_same(m:attempts(3), { attempts = 2, fails = 0 })
		assert_eq(m:run(), nil, "a run for a level that is not next is dropped")
		assert_eq(m:district("cafe").done, 6)
		assert_eq(m:view("cafe"), "day")
		assert_same(m:settings(), { music = 1, sfx = 1.0, haptics = true, reduced_motion = false, input_mode = "swipe", language = "auto" })
		assert_same(m:seen_tutorials(), { "a", "b" })
		assert_same(m:stats(), { wins = 0, losses = 0, coins_earned = 0, coins_spent = 0 })
		local s = m:serialize()
		assert_eq(s.town.atlantis, nil)
		assert_eq(s.progress.levels.bogus, nil)
	end)
end)

describe("save migration", function()
	-- A pretend history: version 2 renamed wallet -> purse, version 3 added a field.
	local migrations = {
		[1] = function(t)
			t.purse, t.wallet = t.wallet, nil
			return t
		end,
		[2] = function(t)
			t.added_in_v3 = "yes"
			return t
		end,
	}

	it("upgrades an old save step by step after checking its checksum", function()
		local v1 = H.new(3):serialize()
		local data, version = save.decode(v1, { version = 3, migrations = migrations })
		assert_eq(version, 1)
		assert_eq(data.wallet, nil)
		assert_eq(data.purse.coins, 500)
		assert_eq(data.added_in_v3, "yes")
		assert_eq(data.version, nil)
		assert_eq(data.checksum, nil)
		local state, info = save.load(v1, nil, require("meta.town").validate(H.districts()), { version = 3, migrations = migrations })
		assert_true(state ~= nil)
		assert_eq(info.version, 1)
		assert_true(info.migrated)
	end)

	it("refuses a tampered old save", function()
		local v1 = H.new(3):serialize()
		v1.wallet.coins = 10 ^ 6
		assert_same({ save.decode(v1, { version = 3, migrations = migrations }) }, { nil, "bad_checksum" })
	end)

	it("refuses a save with a missing or failing migration step", function()
		local v1 = H.new(3):serialize()
		assert_same({ save.decode(v1, { version = 3, migrations = { [1] = migrations[1] } }) }, { nil, "no_migration_from_2" })
		local broken = { [1] = function() error("boom") end }
		assert_same({ save.decode(v1, { version = 2, migrations = broken }) }, { nil, "migration_failed_from_1" })
	end)

	it("leaves the input table untouched", function()
		local v1 = H.new(3):serialize()
		local copy = H.json_round_trip(v1)
		save.decode(v1, { version = 3, migrations = migrations })
		assert_same(v1, copy)
	end)

	it("ships no migrations for the current version", function()
		assert_eq(require("meta.config").save_version, 1)
		assert_eq(next(save.migrations), nil)
	end)
end)

describe("player salt", function()
	it("maps any integer seed into [1, 2147483646]", function()
		assert_eq(Meta.new(H.districts(), 0):salt(), 1)
		assert_eq(Meta.new(H.districts(), 2147483645):salt(), 2147483646)
		assert_eq(Meta.new(H.districts(), 2147483646):salt(), 1)
		assert_eq(Meta.new(H.districts(), -1):salt(), 2147483646)
		assert_error(function() Meta.new(H.districts(), 0.5) end, "seed")
		assert_error(function() Meta.new(H.districts(), nil) end, "seed")
	end)

	it("is kept by saves", function()
		local m = Meta.new(H.districts(), 123456)
		local m2 = Meta.load(H.districts(), m:serialize(), nil, 1, T)
		assert_eq(m2:salt(), 123457)
	end)
end)
