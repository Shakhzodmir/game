local busmod = require("client.bus")

describe("client.bus", function()
	local bus
	before_each(function() bus = busmod.new({ max_queue = 4 }) end)

	it("queues events per subscriber and drains them in publish order", function()
		local a = bus:subscribe(nil, "a")
		local b = bus:subscribe({ "x" }, "b")
		assert_eq(bus:publish("x", { n = 1 }), 2)
		assert_eq(bus:publish("y", { n = 2 }), 1)
		assert_eq(a:pending(), 2)
		assert_eq(b:pending(), 1)
		local seen = {}
		a:drain(function(topic, p) seen[#seen + 1] = topic .. p.n end)
		assert_same(seen, { "x1", "y2" })
		assert_eq(a:pending(), 0)
		seen = {}
		b:drain(function(topic, p) seen[#seen + 1] = topic .. p.n end)
		assert_same(seen, { "x1" })
	end)

	it("never calls subscriber code from publish", function()
		local called = false
		local s = bus:subscribe("x")
		bus:publish("x", {})
		assert_false(called)
		s:drain(function() called = true end)
		assert_true(called)
	end)

	it("delivers events published while draining on the next drain", function()
		local s = bus:subscribe(nil)
		bus:publish("ping", 1)
		local n = s:drain(function(topic, p)
			if p < 3 then bus:publish("ping", p + 1) end
		end)
		assert_eq(n, 1)
		assert_eq(s:pending(), 1)
		s:drain(function() end)
		s:drain(function() end)
		assert_eq(s:pending(), 0)
	end)

	it("drops the oldest events past max_queue", function()
		local s = bus:subscribe("x")
		for i = 1, 6 do bus:publish("x", i) end
		assert_eq(s:pending(), 4)
		assert_eq(s.dropped, 2)
		local got = {}
		s:drain(function(_, p) got[#got + 1] = p end)
		assert_same(got, { 3, 4, 5, 6 })
	end)

	it("stops delivering after close", function()
		local s = bus:subscribe(nil)
		assert_eq(bus:count(), 1)
		s:close()
		assert_eq(bus:count(), 0)
		assert_eq(bus:publish("x", 1), 0)
		assert_eq(s:pending(), 0)
		s:close() -- twice is fine
	end)

	it("keeps the rest of the batch when a handler fails", function()
		local s = bus:subscribe(nil)
		bus:publish("a", 1)
		bus:publish("b", 2)
		assert_error(function() s:drain(function() error("boom") end) end, "boom")
		assert_eq(s:pending(), 1)
	end)

	it("rejects bad topics", function()
		assert_error(function() bus:publish(42) end, "topic must be a string")
		assert_error(function() bus:subscribe(42) end, "topics must be")
	end)

	it("has a shared default bus", function()
		local s = busmod.subscribe("shared_test_topic")
		busmod.publish("shared_test_topic", "hi")
		local got
		s:drain(function(_, p) got = p end)
		assert_eq(got, "hi")
		s:close()
	end)
end)
