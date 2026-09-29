local level_hint = require("client.level_hint")

local function run(h, seconds, allowed, step)
	step = step or 0.125 -- exact in binary: no drift in the sums
	local starts = 0
	local t = 0
	while t < seconds - 1e-9 do
		if h:update(step, allowed) then starts = starts + 1 end
		t = t + step
	end
	return starts
end

describe("client.level_hint", function()
	it("starts after 5 s idle and repeats every 3 s", function()
		local h = level_hint.new()
		assert_eq(run(h, 4.875, true), 0)
		assert_eq(run(h, 0.125, true), 1) -- at 5 s
		assert_true(h:phase() ~= nil)
		assert_eq(run(h, 0.75, true), 0)
		assert_eq(h:phase(), nil) -- the wobble lasts 0.6 s
		assert_eq(run(h, 2.125, true), 0)
		assert_eq(run(h, 0.125, true), 1) -- 3 s after the first
		assert_eq(run(h, 6.0, true), 2)
	end)

	it("starts over on a touch and waits while the board is busy", function()
		local h = level_hint.new()
		run(h, 4.0, true)
		h:touch()
		assert_eq(run(h, 4.0, true), 0)
		assert_eq(run(h, 10.0, false), 0) -- a cascade or a window: no hint, no idle time
		assert_eq(run(h, 1.0, true), 1)
		h:update(0.1, true)
		assert_true(h:phase() ~= nil)
		h:update(0.1, false)
		assert_eq(h:phase(), nil) -- the board moved: the wobble stops
	end)

	it("wobbles there and back", function()
		assert_eq(level_hint.wobble_offset(nil), 0)
		assert_near(level_hint.wobble_offset(0), 0, 1e-9)
		assert_near(level_hint.wobble_offset(1), 0, 1e-9)
		assert_true(level_hint.wobble_offset(0.25, 0.2) > 0)
		assert_true(level_hint.wobble_offset(0.25, 0.2) <= 0.2)
	end)
end)
