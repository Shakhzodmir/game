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

	it("accepts only coins and boosters in a district chest", function()
		local d = small()
		d.districts[1].chest.infinite_minutes = 30
		assert_error(function() town.validate(d) end, "chest has unknown field 'infinite_minutes'")
		d = small()
		d.districts[1].chest = 300
		assert_error(function() town.validate(d) end, "chest must be a table")
		d = small()
		d.districts[1].chest.boosters = "stick"
		assert_error(function() town.validate(d) end, "boosters must be a list")
		d = small()
		d.districts[1].chest.coins = -1
		assert_error(function() town.validate(d) end, "chest coins")
		d = small()
		d.districts[2].chest = nil
		assert_same(town.validate(d).list[2].chest, { coins = 0, boosters = {} })
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

	it("reports an unknown task as an error even in a locked district", function()
		assert_error(function() m:complete_task("b", "zz") end, "no task")
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

describe("town after a content update", function()
	local function finish_a(m)
		H.give(m, "stars", 3)
		assert(m:complete_task("a", "a1"))
		return assert(m:complete_task("a", "a2"))
	end

	it("reopens a complete district that got a new task without paying its chest again", function()
		local m = Meta.new(small(), 1)
		assert_true(finish_a(m).chest ~= nil)
		local d = small()
		table.insert(d.districts[1].tasks, { id = "a3", cost = 2, stem = "lead" })
		local m2, info = Meta.load(d, m:serialize(), nil, 1, H.T0)
		assert_same(info.district_chests, {})
		local a = m2:district("a")
		assert_false(a.complete)
		assert_true(a.chest_claimed)
		assert_true(m2:district("b").available, "the next district stays open")
		assert_eq(m2:current_district(), "a")
		assert_eq(m2:next_task().id, "a3")
		H.give(m2, "stars", 2)
		m2:drain_ledger()
		local coins = m2:coins()
		local r = m2:complete_task("a", "a3")
		assert_same(r, { district = "a", task = "a3", stem = "lead", district_complete = true, chest = nil, next_district = nil })
		assert_eq(m2:coins(), coins)
		assert_eq(H.ledger_sum(m2:drain_ledger(), "coins", "district_chest"), 0)
		assert_eq(m2:current_district(), "b")
	end)

	it("keeps the done tasks by id when tasks are reordered", function()
		local d = small()
		table.insert(d.districts[1].tasks, { id = "a3", cost = 1, stem = "lead" })
		local m = Meta.new(d, 1)
		H.give(m, "stars", 3)
		assert(m:complete_task("a", "a1"))
		assert(m:complete_task("a", "a2"))
		local d2 = small()
		d2.districts[1].tasks = {
			{ id = "a3", cost = 1, stem = "lead" },
			{ id = "a1", cost = 1, stem = "beat" },
			{ id = "a2", cost = 2, stem = "bass" },
		}
		local m2 = Meta.load(d2, m:serialize(), nil, 1, H.T0)
		assert_same(m2:unmuted_stems("a"), { "beat", "bass" })
		assert_same(m2:serialize().town.a.done, { "a1", "a2" })
		assert_eq(m2:next_task().id, "a3")
		local ok, why = m2:complete_task("a", "a1")
		assert_false(ok)
		assert_eq(why, "already_done")
	end)

	it("pays the chest on load when an update removed the last open task", function()
		local m = Meta.new(small(), 1)
		H.give(m, "stars", 1)
		m:complete_task("a", "a1")
		local d = small()
		table.remove(d.districts[1].tasks, 2)
		local coins = m:coins()
		local m2, info = Meta.load(d, m:serialize(), nil, 1, H.T0)
		assert_same(info.district_chests, { "a" })
		assert_eq(m2:coins(), coins + 100)
		assert_true(m2:district("a").chest_claimed)
		assert_eq(m2:current_district(), "b")
		assert_true(m2:dirty())
		local _, again = Meta.load(d, m2:serialize(), nil, 1, H.T0)
		assert_same(again.district_chests, {}, "only once")
	end)

	it("keeps a district with progress open when a district is inserted before it", function()
		local m = Meta.new(small(), 1)
		finish_a(m)
		H.give(m, "stars", 1)
		m:complete_task("b", "b1")
		local d = small()
		table.insert(d.districts, 2, { id = "n", chest = { coins = 50 }, tasks = { { id = "n1", cost = 1, stem = "pad" } } })
		local m2 = Meta.load(d, m:serialize(), nil, 1, H.T0)
		assert_true(m2:district("n").available)
		assert_true(m2:district("b").available, "b has progress")
		assert_eq(m2:current_district(), "n")
		assert_same(m2:unmuted_stems("b"), { "drums" })
	end)

	it("restores the town from a partial or broken save", function()
		local data = town.validate(small())
		local t = town.restore({
			a = { done = { "a2", "zz", "a1", "a1" }, view = "concert" },
			b = { done = 3, chest_claimed = "yes" },
		}, data)
		assert_same(t.a, { done = { "a1", "a2" }, chest_claimed = true, view = "concert" },
			"a complete district without the flag counts as claimed")
		assert_same(t.b, { done = {}, chest_claimed = false, view = "day" })
		t = town.restore({ a = { done = { "a1", "a2" }, chest_claimed = false } }, data)
		assert_false(t.a.chest_claimed, "an explicit flag is kept")
	end)
end)
