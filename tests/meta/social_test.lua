-- meta/social.lua: the rules of the chart and the bands (names, codes, weeks, limits, ranking).
local S = require("meta.social")

local MON = 4 * 86400 + 3 * 604800 -- a Monday 00:00 UTC (week 3)

describe("social rules: weeks and codes", function()
	it("starts the week on Monday 00:00 UTC", function()
		assert_eq(S.week_id(MON), 3)
		assert_eq(S.week_id(MON - 1), 2)
		assert_eq(S.week_id(MON + 604800 - 1), 3)
		assert_eq(S.week_end(3), MON + 604800)
	end)

	it("makes valid, distinct, stable band codes", function()
		local seen = {}
		for n = 1, 2000 do
			local c = S.code_from(n)
			assert_true(S.valid_code(c), c)
			assert_eq(S.code_from(n), c)
			seen[c] = (seen[c] or 0) + 1
		end
		local dup = 0
		for _, k in pairs(seen) do if k > 1 then dup = dup + 1 end end -- count only
		assert_true(dup <= 2, "too many collisions: " .. dup)
		assert_eq(S.normalize_code(" ab-c d23 "), "ABCD23")
		assert_false(S.valid_code("AB0DEF"), "0 is not in the alphabet")
		assert_false(S.valid_code("ABC"))
	end)

	it("only accepts names built from the word lists", function()
		assert_true(S.valid_name({ a = 1, n = 16, d = 10 }))
		assert_false(S.valid_name({ a = 0, n = 1, d = 10 }))
		assert_false(S.valid_name({ a = 1, n = 1, d = 100 }))
		assert_false(S.valid_name("Anna anna@mail.com"))
		assert_false(S.valid_name({ a = 1.5, n = 1, d = 10 }))
		assert_true(S.valid_band_name({ a = 3, n = 4 }))
		assert_false(S.valid_avatar(#S.AVATARS + 1))
		for k = 0, 200 do
			assert_true(S.valid_name(S.suggest_name(k)))
			assert_true(S.valid_band_name(S.suggest_band_name(k)))
		end
	end)
end)

describe("social rules: reports", function()
	local NOW = MON + 3600

	it("takes honest growth and counts the week from the stars at its start", function()
		local rec, score, refused = S.report(nil, { total = 0, level = 0 }, NOW)
		assert_eq(score, 0)
		rec, score, refused = S.report(rec, { total = 9, level = 4 }, NOW + 60)
		assert_eq(rec.total, 9)
		assert_eq(score, 9)
		assert_eq(refused, nil)
		-- next week the score starts again, the total stays
		rec, score = S.report(rec, { total = 12, level = 5 }, NOW + 604800)
		assert_eq(rec.total, 12)
		assert_eq(score, 3)
	end)

	it("never lets stars go down", function()
		local rec = S.report(nil, { total = 30, level = 12 }, NOW)
		local rec2, _, refused = S.report(rec, { total = 5, level = 3 }, NOW + 10)
		assert_eq(rec2.total, 30)
		assert_eq(refused, "down")
		assert_eq(rec2.flags, 0, "a smaller number is a stale device, not cheating")
	end)

	it("refuses more stars than the level reached allows, and marks the player", function()
		local rec, _, refused = S.report(nil, { total = 90, level = 5 }, NOW)
		assert_eq(rec.total, 15)
		assert_eq(refused, "level")
		assert_eq(rec.flags, 1)
	end)

	it("caps the growth per day and starts a new day on the next one", function()
		local rec = S.report(nil, { total = 0, level = 0 }, NOW)
		local r1, _, why = S.report(rec, { total = 100, level = 100 }, NOW + 5)
		assert_eq(r1.total, S.DAY_CAP)
		assert_eq(why, "day")
		assert_eq(r1.flags, 1)
		local r2, _, why2 = S.report(r1, { total = 100, level = 100 }, NOW + 10)
		assert_eq(r2.total, S.DAY_CAP, "nothing more today")
		assert_eq(why2, "day")
		local r3 = S.report(r2, { total = 100, level = 100 }, NOW + 86400)
		assert_eq(r3.total, 2 * S.DAY_CAP)
	end)

	it("caps the weekly score and drops a player with too many marks from the public chart", function()
		local rec = { total = 0, level = 0, day = 0, day_gain = 0, week = 3, week_base = 0, flags = 0 }
		for i = 0, 6 do
			rec = S.report(rec, { total = 100 * (i + 1), level = 100 }, MON + i * 86400 + 5)
		end
		assert_eq(rec.total, 7 * S.DAY_CAP)
		assert_eq(S.week_score(rec), S.WEEK_CAP)
		assert_false(S.visible(rec), "7 refused days are marks enough")
		assert_true(S.visible({ flags = S.FLAG_LIMIT - 1 }))
	end)
end)

describe("social rules: ranking", function()
	it("sorts by stars, then total, then id, and numbers the rows", function()
		local rows = S.rank({
			{ uid = "c", stars = 5, total = 10 }, { uid = "a", stars = 5, total = 10 }, { uid = "b", stars = 9, total = 1 },
			{ uid = "d", stars = 5, total = 40 },
		})
		local ids = {}
		for i, r in ipairs(rows) do ids[i] = r.uid .. r.rank end
		assert_same(ids, { "b1", "d2", "a3", "c4" })
	end)

	it("pins my row when it is below the limit", function()
		local rows = {}
		for i = 1, 150 do rows[i] = { uid = "p" .. i, stars = 1000 - i, total = 0 } end
		S.rank(rows)
		local out = S.top_with_me(rows, "p120", 100)
		assert_eq(#out.rows, 100)
		assert_eq(out.me.rank, 120)
		assert_true(out.pinned)
		local inside = S.top_with_me(rows, "p7", 100)
		assert_false(inside.pinned)
		assert_eq(inside.me.rank, 7)
		assert_eq(S.top_with_me(rows, "nobody", 100).me, nil)
		assert_eq(S.rank_change(8, 3), 5)
		assert_eq(S.rank_change(nil, 3), 0)
	end)
end)
