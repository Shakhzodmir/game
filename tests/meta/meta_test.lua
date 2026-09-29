local Meta = require("meta.meta")
local economy = require("meta.economy")
local H = require("tests.meta.helper")

local T = H.T0

describe("meta playthrough", function()
	-- Plays all 100 levels on the plan's difficulty sawtooth, spends every
	-- star on the town as soon as possible and checks the totals.
	local m, ledger, star_log
	before_each(function()
		m = H.new(2024)
		ledger = m:drain_ledger()
		star_log = {}
		local now = T
		for level = 1, 100 do
			local d = H.sawtooth(level)
			assert(m:start_level({ id = level, difficulty = d }, nil, now))
			m:note_move()
			local r = m:finish_level({ won = true, level_id = level, difficulty = d, moves_at_win = 3 }, now)
			assert(r.won)
			while true do
				local t = m:next_task()
				if not t or not t.affordable then break end
				local done = assert(m:complete_task(t.district, t.id))
				if done.district_complete then star_log[#star_log + 1] = { done.district, level } end
			end
			for _, e in ipairs(m:drain_ledger()) do ledger[#ledger + 1] = e end
			now = now + 900
		end
	end)

	it("earns 126 stars and finishes four districts by level 100", function()
		assert_true(m:all_done())
		assert_eq(H.ledger_sum(ledger, "stars", "level_win"), 126)
		assert_same(star_log, { { "cafe", 11 }, { "jazz", 30 }, { "square", 53 }, { "stadium", 77 } })
		assert_eq(m:current_district(), "garage")
		assert_eq(m:district("garage").done, 7)
		assert_eq(m:stars(), 3)
	end)

	it("keeps every wallet change in the ledger", function()
		for _, item in ipairs(economy.items) do
			assert_eq(H.ledger_sum(ledger, item), m.s.wallet[item], item)
		end
		local st = m:stats()
		assert_eq(m:coins(), st.coins_earned - st.coins_spent)
		assert_eq(st.wins, 100)
		for _, e in ipairs(ledger) do
			assert_true(type(e.reason) == "string" and e.reason ~= "", "reason")
			assert_eq(e.flow, e.delta > 0 and "source" or "sink")
		end
	end)

	it("pays the level chests and district chests", function()
		assert_eq(H.ledger_sum(ledger, "coins", "level_chest"), 1050)
		assert_eq(H.ledger_sum(ledger, "infinite_minutes", "level_chest"), 225)
		assert_eq(H.ledger_sum(ledger, "coins", "district_chest"), 300 + 450 + 600 + 800)
	end)

	it("pays wins as 25 x difficulty + 5 per move left", function()
		-- levels 1-20: 20 x 25; 21-50: 3 blocks x 300; 51-100: 5 blocks x 350; +15 per level
		assert_eq(H.ledger_sum(ledger, "coins", "level_win"), 500 + 900 + 1750 + 100 * 15)
	end)
end)

describe("meta grants", function()
	it("gives store and event rewards through the ledger", function()
		local m = H.new()
		m:drain_ledger()
		assert_true(m:grant({ coins = 2500, boosters = { disco = 2, stick = 2 }, infinite_minutes = 60 }, "iap_starter_pack", T))
		assert_eq(m:coins(), 3000)
		assert_eq(m:booster_count("stick"), 2)
		assert_eq(m:booster_count("disco"), 2)
		assert_eq(m:lives(T).infinite_seconds, 3600)
		assert_same(m:drain_ledger(), {
			{ item = "coins", delta = 2500, balance = 3000, reason = "iap_starter_pack", flow = "source" },
			{ item = "stick", delta = 2, balance = 2, reason = "iap_starter_pack", flow = "source" },
			{ item = "disco", delta = 2, balance = 2, reason = "iap_starter_pack", flow = "source" },
			{ item = "infinite_minutes", delta = 60, balance = 60, reason = "iap_starter_pack", flow = "source" },
		})
	end)

	it("never grants stars, unknown items or negative amounts", function()
		local m = H.new()
		assert_error(function() m:grant({ stars = 5 }, "x", T) end, "cannot give 'stars'")
		assert_error(function() m:grant({ boosters = { hammer = 1 } }, "x", T) end, "unknown booster")
		assert_error(function() m:grant({ coins = -1 }, "x", T) end, "non-negative")
		assert_error(function() m:grant({ coins = 1 }, "", T) end, "reason")
		assert_eq(m:coins(), 500)
	end)
end)

describe("meta settings and tutorials", function()
	it("have defaults and validate changes", function()
		local m = H.new()
		assert_same(m:settings(), { music = 0.8, sfx = 1.0, haptics = true, reduced_motion = false, input_mode = "swipe", language = "auto" })
		assert_true(m:set_setting("sfx", 0.25))
		assert_true(m:set_setting("music", 1.7))
		assert_true(m:set_setting("reduced_motion", true))
		assert_true(m:set_setting("language", "ru"))
		assert_true(m:set_setting("input_mode", "taptap"))
		assert_same(m:settings(), { music = 1, sfx = 0.25, haptics = true, reduced_motion = true, input_mode = "taptap", language = "ru" })
		local ok, why = m:set_setting("language", "ko")
		assert_false(ok)
		assert_eq(why, "invalid_value")
		assert_false(m:set_setting("haptics", 1))
		assert_false(m:set_setting("music", "loud"))
		assert_false(m:set_setting("input_mode", "tilt"))
		assert_error(function() m:set_setting("volume", 1) end, "unknown setting")
		local s = m:settings()
		s.music = 0
		assert_eq(m:settings().music, 1, "settings() returns a copy")
	end)

	it("remember seen tutorials as a set", function()
		local m = H.new()
		assert_false(m:tutorial_seen("first_swap"))
		assert_true(m:mark_tutorial_seen("first_swap"))
		assert_false(m:mark_tutorial_seen("first_swap"))
		assert_true(m:mark_tutorial_seen("booster_riff"))
		assert_true(m:tutorial_seen("first_swap"))
		assert_same(m:seen_tutorials(), { "booster_riff", "first_swap" })
		assert_error(function() m:mark_tutorial_seen("") end, "tutorial id")
	end)
end)

describe("meta determinism", function()
	it("produces identical saves for identical histories", function()
		local function history()
			local m = H.new(31337)
			for level = 1, 30 do
				local d = H.sawtooth(level)
				m:start_level({ id = level, difficulty = d }, nil, T + level * 60)
				m:note_move()
				if level % 7 == 0 then
					m:finish_level({ won = false, level_id = level }, T + level * 60)
					m:start_level({ id = level, difficulty = d }, nil, T + level * 60 + 30)
				end
				m:finish_level({ won = true, level_id = level, moves_at_win = level % 4 }, T + level * 60 + 30)
			end
			return m:serialize()
		end
		assert_same(history(), history())
		assert_eq(history().checksum, history().checksum)
	end)
end)
