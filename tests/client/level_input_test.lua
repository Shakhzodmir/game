local level_input = require("client.level_input")

-- board: map "x,y" -> piece
local function board(t)
	return function(x, y) return t[x .. "," .. y] end
end

local function piece(id, kind, extra)
	local p = { id = id, kind = kind, state = "idle", pinned = false, wired = false }
	for k, v in pairs(extra or {}) do p[k] = v end
	return p
end

local function tap(inp, x, y)
	inp:press(x, y)
	return inp:release(x, y)
end

describe("client.level_input", function()
	it("swipes 30% of a cell along the major axis", function()
		local inp = level_input.new({ query = board({ ["3,3"] = piece(1, "regular") }) })
		inp:press(3.0, 3.0)
		assert_eq(inp:move(3.2, 3.1), nil)
		local cmd = inp:move(3.25, 3.35) -- down (core y grows) wins
		assert_same(cmd, { type = "swap", from = { 3, 3 }, to = { 3, 4 } })
		assert_eq(inp:move(3.9, 3.9), nil) -- one swipe per touch
		assert_eq(inp:release(3.9, 3.9), nil) -- no tap after a swipe
		inp:press(3.1, 2.9)
		assert_same(inp:move(2.75, 2.95), { type = "swap", from = { 3, 3 }, to = { 2, 3 } })
		inp:release(2.7, 2.9)
		inp:press(3, 3)
		assert_same(inp:move(3, 2.6), { type = "swap", from = { 3, 3 }, to = { 3, 2 } })
	end)

	it("selects in swipe mode and swaps with a tapped neighbour", function()
		local q = board({ ["2,2"] = piece(1, "regular"), ["3,2"] = piece(2, "regular"), ["5,5"] = piece(3, "mic") })
		local inp = level_input.new({ query = q })
		assert_eq(tap(inp, 2, 2), nil)
		assert_same(inp.selected, { id = 1, x = 2, y = 2 })
		assert_eq(tap(inp, 2, 2), nil) -- tap on the selected piece clears it
		assert_eq(inp.selected, nil)
		tap(inp, 2, 2)
		assert_same(tap(inp, 3, 2), { type = "swap", from = { 2, 2 }, to = { 3, 2 } })
		assert_eq(inp.selected, nil)
		tap(inp, 2, 2)
		tap(inp, 5, 5) -- a microphone far away: the selection moves
		assert_same(inp.selected, { id = 3, x = 5, y = 5 })
		-- a neighbour of the selection gets the swap whatever it is (a gap here)
		assert_same(tap(inp, 5, 6), { type = "swap", from = { 5, 5 }, to = { 5, 6 } })
	end)

	it("taps specials in swipe mode", function()
		local q = board({ ["1,1"] = piece(1, "regular"), ["4,4"] = piece(2, "special"),
			["2,1"] = piece(3, "special") })
		local inp = level_input.new({ query = q })
		assert_same(tap(inp, 4, 4), { type = "tap", at = { 4, 4 } })
		tap(inp, 1, 1)
		-- selection not adjacent: the special fires and the selection goes
		assert_same(tap(inp, 4, 4), { type = "tap", at = { 4, 4 } })
		assert_eq(inp.selected, nil)
		tap(inp, 1, 1)
		-- adjacent special: rule 2 first, it is a swap
		assert_same(tap(inp, 2, 1), { type = "swap", from = { 1, 1 }, to = { 2, 1 } })
	end)

	it("selects first and fires on the second tap in tap-tap mode", function()
		local q = board({ ["4,4"] = piece(2, "special"), ["1,1"] = piece(1, "regular") })
		local inp = level_input.new({ mode = "taptap", query = q })
		assert_eq(tap(inp, 4, 4), nil)
		assert_same(inp.selected, { id = 2, x = 4, y = 4 })
		assert_same(tap(inp, 4, 4), { type = "tap", at = { 4, 4 } })
		assert_eq(inp.selected, nil)
		tap(inp, 1, 1)
		assert_eq(tap(inp, 1, 1), nil) -- a regular piece tapped twice: deselect
		assert_eq(inp.selected, nil)
		tap(inp, 1, 1)
		tap(inp, 4, 4) -- not adjacent: the selection moves
		assert_same(inp.selected, { id = 2, x = 4, y = 4 })
	end)

	it("does not select what cannot move and clears on blockers and off the board", function()
		local q = board({ ["1,1"] = piece(1, "regular", { wired = true }), ["2,2"] = piece(2, "blocker"),
			["3,3"] = piece(3, "regular", { state = "fall" }), ["4,4"] = piece(4, "regular", { pinned = true }),
			["5,5"] = piece(5, "regular") })
		local inp = level_input.new({ query = q })
		for _, c in ipairs({ { 1, 1 }, { 2, 2 }, { 3, 3 }, { 4, 4 } }) do
			tap(inp, 5, 5)
			assert_true(inp.selected ~= nil)
			tap(inp, c[1], c[2])
			assert_eq(inp.selected, nil)
		end
		tap(inp, 5, 5)
		inp:press(nil, nil) -- off the board
		assert_eq(inp.selected, nil)
	end)

	it("drops a stale selection (rule 1)", function()
		local inp = level_input.new({ query = board({ ["2,2"] = piece(7, "regular") }) })
		tap(inp, 2, 2)
		local where = { [7] = { x = 2, y = 2, state = "idle" } }
		local function find(id) return where[id] end
		inp:validate(find, true)
		assert_true(inp.selected ~= nil)
		where[7].state = "fall"
		inp:validate(find, true)
		assert_eq(inp.selected, nil)
		tap(inp, 2, 2)
		where[7] = { x = 2, y = 3, state = "idle" }
		inp:validate(find, true)
		assert_eq(inp.selected, nil)
		tap(inp, 2, 2)
		where[7] = { x = 2, y = 2, state = "idle" }
		inp:validate(find, false) -- the game left "playing"
		assert_eq(inp.selected, nil)
	end)

	it("picks booster targets", function()
		local inp = level_input.new({ query = board({ ["2,2"] = piece(1, "regular") }) })
		assert_false(inp:target("remix"))
		assert_true(inp:target("stick"))
		inp:press(2, 2)
		assert_same(inp.hover, { x = 2, y = 2 })
		inp:move(3.4, 2.1) -- no swipe in target mode, the hover follows
		assert_same(inp.hover, { x = 3, y = 2 })
		assert_same(inp:release(3.4, 2.1), { type = "booster", booster = "stick", at = { 3, 2 } })
		assert_eq(inp.targeting, "stick") -- stays until the board says it was used
		inp:target("row_light")
		assert_same(tap(inp, 4, 5), { type = "booster", booster = "row_light", row = 5 })
		inp:target("col_light")
		assert_same(tap(inp, 4, 5), { type = "booster", booster = "col_light", col = 4 })
		inp:cancel_target()
		assert_eq(inp.targeting, nil)
		assert_eq(tap(inp, 2, 2), nil)
		assert_true(inp.selected ~= nil)
	end)
end)
