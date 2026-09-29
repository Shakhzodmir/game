local gfx = require("client.gfx")

local function pixel(buf, w, x, y)
	local i = (y * w + x) * 4 + 1
	return { string.byte(buf, i, i + 3) }
end

describe("client.gfx", function()
	it("parses hex colors", function()
		assert_same(gfx.hex("#FF0000"), { 1, 0, 0, 1 })
		local c = gfx.hex("#86DDFF", 0.5)
		assert_near(c[2], 0xDD / 255, 1e-9)
		assert_eq(c[4], 0.5)
		assert_near(gfx.hex("#00000080")[4], 128 / 255, 1e-9)
	end)

	it("builds a vertical gradient top to bottom", function()
		local buf = gfx.vertical_gradient(2, 3, { { 0, { 1, 0, 0, 1 } }, { 1, { 0, 0, 1, 1 } } })
		assert_eq(#buf, 2 * 3 * 4)
		assert_same(pixel(buf, 2, 0, 0), { 255, 0, 0, 255 })
		assert_same(pixel(buf, 2, 1, 2), { 0, 0, 255, 255 })
		assert_same(pixel(buf, 2, 0, 1), { 128, 0, 128, 255 })
	end)

	it("draws rounded rects with transparent corners and an opaque middle", function()
		local w, h = 32, 32
		local buf = gfx.round_rect(w, h, 10, { top = gfx.hex("#6CF08E"), bottom = gfx.hex("#22C55E") })
		assert_eq(#buf, w * h * 4)
		assert_eq(pixel(buf, w, 0, 0)[4], 0)
		assert_eq(pixel(buf, w, 16, 16)[4], 255)
		local top, bottom = pixel(buf, w, 16, 2), pixel(buf, w, 16, 29)
		assert_true(top[1] > bottom[1], "lighter at the top")
	end)

	it("draws a shelf and a soft disc", function()
		local buf = gfx.round_rect(20, 20, 4, { shelf = { 0, 0, 0, 1 }, shelf_h = 4 })
		assert_same(pixel(buf, 20, 10, 18), { 0, 0, 0, 255 })
		local d = gfx.disc(16, 2)
		assert_eq(#d, 16 * 16 * 4)
		assert_eq(pixel(d, 16, 8, 8)[4], 255)
		assert_eq(pixel(d, 16, 0, 0)[4], 0)
	end)
end)
