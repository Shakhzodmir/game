local analytics = require("client.services.analytics")
local iap = require("client.services.iap")
local ads = require("client.services.ads")

describe("client.services.analytics", function()
	before_each(function() analytics.init({ strict = true, clock = function() return 5 end }) end)

	it("queues valid events with time and sequence", function()
		analytics.log("level_start", { level = 3, attempt = 1 })
		analytics.log("screen_view", { name = "town" })
		local evs = analytics.drain()
		assert_eq(#evs, 2)
		assert_eq(evs[1].name, "level_start")
		assert_eq(evs[1].t, 5)
		assert_eq(evs[2].seq, 2)
		assert_eq(#analytics.drain(), 0)
	end)

	it("rejects unknown events and params in strict mode, drops them otherwise", function()
		assert_error(function() analytics.log("lvl_start", {}) end, "unknown analytics event")
		assert_error(function() analytics.log("level_start", { lvl = 1 }) end, "has no param 'lvl'")
		analytics.init({ strict = false, quiet = true })
		local ev, why = analytics.log("nope")
		assert_eq(ev, nil)
		assert_true(why ~= nil)
	end)

	it("turns ledger entries into economy events and feeds a sink", function()
		local got = {}
		analytics.set_sink(function(ev) got[#got + 1] = ev.name end)
		analytics.log_ledger({ { item = "coins", delta = 25, balance = 525, reason = "level_win", flow = "source" } })
		assert_same(got, { "economy" })
		assert_eq(analytics.recent(1)[1].params.reason, "level_win")
	end)

	it("keeps the queue bounded", function()
		for i = 1, analytics.MAX_QUEUE + 10 do analytics.log("lives_out", { level = i }) end
		assert_eq(#analytics.drain(), analytics.MAX_QUEUE)
		assert_eq(analytics.count(), analytics.MAX_QUEUE + 10)
	end)
end)

describe("client.services.iap and ads", function()
	before_each(function() analytics.init({ strict = true }) end)

	it("answers unavailable in release", function()
		iap.init({ debug = false, grant = function() error("must not grant") end })
		assert_false(iap.available())
		local res
		iap.buy("coins_small", function(ok, why) res = { ok, why } end)
		assert_same(res, { false, "unavailable" })
		ads.init({ debug = false })
		assert_false(ads.can_show("continue"))
		ads.show_rewarded("continue", function(ok, why) res = { ok, why } end)
		assert_same(res, { false, "unavailable" })
	end)

	it("grants instantly in debug", function()
		local granted
		iap.init({ debug = true, grant = function(reward, tag) granted = { reward, tag } return true end })
		local res
		iap.buy("coins_small", function(ok) res = ok end)
		assert_true(res)
		assert_eq(granted[2], "iap_coins_small")
		assert_eq(granted[1].coins, 500)
		iap.buy("nope", function(ok, why) res = why end)
		assert_eq(res, "unknown_product")
		ads.init({ debug = true })
		assert_true(ads.can_show("continue"))
		assert_false(ads.can_show("banner"))
		ads.show_rewarded("continue", function(ok) res = ok end)
		assert_true(res)
	end)

	it("never sells stars", function()
		for _, p in ipairs(iap.PRODUCTS) do
			assert_eq(p.reward.stars, nil, p.id)
		end
	end)
end)
