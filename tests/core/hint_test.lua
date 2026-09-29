-- Hint (12.3).

local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
local THREE_ONLY = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }

local function fresh(rows, extra)
	local g = H.game(FULL, extra)
	H.board(g, rows)
	return g
end

describe("core hint (12.3)", function()
	it("prefers a swap of two specials, by combo rank", function()
		local g = fresh({ "RRrgby", "yrgbyr", "rgbyrg", "gbDSgb", "byrgby", "yrggbg" })
		assert_same(g:hint(), { from = { 3, 4 }, to = { 4, 4 } }, "disco+sub beats riff+riff")
	end)

	it("tier 3: the best special created, sub over riff", function()
		local g = fresh({ "byrgby", "yrgbyr", "rrgryg", "gbrrgb", "byrgby", "yrgbyr" })
		assert_same(g:hint(), { from = { 3, 3 }, to = { 4, 3 } }, "L of red: a sub")
	end)

	it("tier 2: a swap with goal progress beats plain swaps", function()
		local plain = fresh(THREE_ONLY, { goals = { { type = "collect", color = "purple", count = 5 } } })
		assert_same(plain:hint(), { from = { 4, 4 }, to = { 5, 4 } }, "tier 1: equal sizes, smaller index")
		-- (5,4)-(6,4) makes the only blue line
		local blue = fresh(THREE_ONLY, { goals = { { type = "collect", color = "blue", count = 5 } } })
		assert_same(blue:hint(), { from = { 5, 4 }, to = { 6, 4 } })
	end)

	it("returns a tap when only a special can move, and nil without moves", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyS" })
		H.obj_at(g, 5, 6).pins = { 1 }
		H.obj_at(g, 6, 5).pins = { 1 }
		assert_same(g:hint(), { at = { 6, 6 } })
		local none = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_eq(none:hint(), nil)
	end)

	it("ranks a special's swap above a tap of the same special", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyS" })
		assert_same(g:hint(), { from = { 6, 5 }, to = { 6, 6 } })
	end)
end)
