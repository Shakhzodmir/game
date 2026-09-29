local town = require("meta.town")
local Meta = require("meta.meta")
local H = require("tests.meta.helper")

local function small()
	return {
		districts = {
			{ id = "a", name = { en = "A" }, chest = { coins = 100, boosters = { "stick", "riff" } },
				tasks = { { id = "a1", cost = 1, stem = "beat" }, { id = "a2", cost = 2, stem = "bass" } } },
			{ id = "b", name = { en = "B" }, chest = { coins = 200, boosters = {} },
				tasks = { { id = "b1", cost = 1, stem = "drums" }, { id = "b2", cost = 3, stem = "keys" } } },
		},
	}
end

describe("districts data", function()
	it("rejects broken content", function()
		assert_error(function() town.validate(nil) end, "districts")
		assert_error(function() town.validate({ districts = {} }) end, "non-empty")
		local d = small()
		d.districts[2].id = "a"
		assert_error(function() town.validate(d) end, "duplicate district")
		d = small()
		d.districts[1].tasks[1].cost = 2
		assert_error(function() town.validate(d) end, "first task must cost 1")
		d = small()
		d.districts[1].tasks[2].cost = 0
		assert_error(function() town.validate(d) end, "positive integer")
		d = small()
		d.districts[1].tasks[2].id = "a1"
		assert_error(function() town.validate(d) end, "repeats id")
		d = small()
		d.districts[1].tasks[2].stem = nil
		assert_error(function() town.validate(d) end, "no stem")
		d = small()
		d.districts[1].chest.boosters = { "hammer" }
		assert_error(function() town.validate(d) end, "unknown booster")
	end)
end)

describe("town", function()
	local m
	before_each(function()
		m = Meta.new(small(), 1)
	end)

	it("starts in the first district with its 1-star task", function()
		assert_eq(m:current_district(), "a")
		assert_same(m:next_task(), { district = "a", id = "a1", name = nil, cost = 1, stem = "beat", affordable = false })
		assert_same(m:unmuted_stems("a"), {})
		local views = m:districts()
		assert_true(views[1].available)
		assert_false(views[2].available)
		assert_eq(views[2].next_task, nil)
	end)

	it("spends stars and unmutes stems in task order", function()
		local ok, why = m:complete_task("a", "a1")
		assert_false(ok)
		assert_eq(why, "not_enough_stars")
		H.give(m, "stars", 2)
		assert_true(m:next_task().affordable)
		ok, why = m:complete_task("a", "a2")
		assert_false(ok)
		assert_eq(why, "wrong_order")
		m:drain_ledger()
		local r = m:complete_task("a", "a1")
		assert_same(r, { district = "a", task = "a1", stem = "beat", district_complete = false, chest = nil, next_district = nil })
		assert_eq(m:stars(), 1)
		assert_same(m:drain_ledger(), { { item = "stars", delta = -1, balance = 1, reason = "district_task", flow = "sink" } })
		ok, why = m:complete_task("a", "a1")
		assert_false(ok)
		assert_eq(why, "already_done")
		assert_same(m:unmuted_stems("a"), { "beat" })
		ok, why = m:complete_task("a", "a2")
		assert_false(ok)
		assert_eq(why, "not_enough_stars")
		assert_same(m:unmuted_stems("a"), { "beat" }, "nothing changes on a refusal")
		assert_error(function() m:complete_task("a", "zz") end, "no task")
		assert_error(function() m:complete_task("zz", "a1") end, "unknown district")
	end)

	it("opens districts in order and pays the district chest", function()
		H.give(m, "stars", 10)
		local ok, why = m:complete_task("b", "b1")
		assert_false(ok)
		assert_eq(why, "district_locked")
		m:complete_task("a", "a1")
		local coins, stick, riff = m:coins(), m:booster_count("stick"), m:booster_count("riff")
		m:drain_ledger()
		local r = m:complete_task("a", "a2")
		assert_true(r.district_complete)
		assert_same(r.chest, { coins = 100, boosters = { "stick", "riff" } })
		assert_eq(r.next_district, "b")
		assert_eq(m:coins(), coins + 100)
		assert_eq(m:booster_count("stick"), stick + 1)
		assert_eq(m:booster_count("riff"), riff + 1, "a chest booster waits in the inventory until it unlocks")
		local ledger = m:drain_ledger()
		assert_eq(H.ledger_sum(ledger, "coins", "district_chest"), 100)
		assert_eq(H.ledger_sum(ledger, "riff", "district_chest"), 1)
		assert_eq(m:current_district(), "b")
		assert_true(m:district("b").available)
		assert_true(m:district("a").complete)
		assert_same(m:unmuted_stems("a"), { "beat", "bass" })
		assert_same(m:next_task(), { district = "b", id = "b1", name = nil, cost = 1, stem = "drums", affordable = true })
	end)

	it("is complete when the last district is", function()
		H.give(m, "stars", 7)
		m:complete_task("a", "a1")
		m:complete_task("a", "a2")
		m:complete_task("b", "b1")
		local r = m:complete_task("b", "b2")
		assert_true(r.district_complete)
		assert_eq(r.next_district, nil)
		assert_eq(m:current_district(), nil)
		assert_eq(m:next_task(), nil)
		assert_eq(m:stars(), 0)
	end)

	it("switches day and concert views of open districts", function()
		assert_eq(m:view("a"), "day")
		assert_true(m:set_view("a", "concert"))
		assert_eq(m:view("a"), "concert")
		local ok, why = m:set_view("b", "concert")
		assert_false(ok)
		assert_eq(why, "district_locked")
		assert_error(function() m:set_view("a", "night") end, "unknown view")
		local m2 = Meta.load(small(), m:serialize(), nil, 1, H.T0)
		assert_eq(m2:view("a"), "concert")
	end)

	it("returns copies, not internal tables", function()
		local v = m:district("a")
		v.tasks[1].cost = 99
		v.unmuted[1] = "x"
		assert_eq(m:district("a").tasks[1].cost, 1)
		assert_same(m:unmuted_stems("a"), {})
	end)
end)

describe("town with the real districts", function()
	it("gives the lo-fi café chest and opens the jazz bar", function()
		local m = H.new()
		H.advance_to(m, 12)
		assert_eq(m:stars(), 11)
		local stems = {}
		while m:current_district() == "cafe" do
			local t = m:next_task()
			local r = assert(m:complete_task(t.district, t.id))
			stems[#stems + 1] = r.stem
			if r.district_complete then
				assert_same(r.chest, { coins = 300, boosters = { "riff", "stick" } })
				assert_eq(r.next_district, "jazz")
			end
		end
		assert_same(stems, { "beat", "vinyl", "keys", "bass", "lead", "pad" })
		assert_same(m:unmuted_stems("cafe"), stems)
		assert_eq(m:stars(), 0)
		assert_same(m:next_task(), { district = "jazz", id = "stage_light", name = { ru = "Свет на сцене", en = "Stage light" },
			cost = 1, stem = "brushes", affordable = false })
	end)
end)
