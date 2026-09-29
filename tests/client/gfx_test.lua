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

describe("client.gfx image edges", function()
	-- 4x2 RGB image: left column red, right column blue, top row of the
	-- middle green, bottom row of the middle white
	local function img()
		local R, G, B, W = "\255\0\0", "\0\255\0", "\0\0\255", "\255\255\255"
		return R .. G .. G .. B .. R .. W .. W .. B
	end

	it("averages the outermost pixels of each band", function()
		local left = gfx.edge_colors(img(), 4, 2, 3, "left", 2, 1)
		assert_same(left, { { 1, 0, 0, 1 }, { 1, 0, 0, 1 } })
		local right = gfx.edge_colors(img(), 4, 2, 3, "right", 1, 1)
		assert_same(right, { { 0, 0, 1, 1 } })
		local top = gfx.edge_colors(img(), 4, 2, 3, "top", 4, 1)
		assert_same(top[2], { 0, 1, 0, 1 })
		local bottom = gfx.edge_colors(img(), 4, 2, 3, "bottom", 4, 1)
		assert_same(bottom[3], { 1, 1, 1, 1 })
		local deep = gfx.edge_colors(img(), 4, 2, 3, "left", 1, 2)
		assert_near(deep[1][1], 0.75, 1e-9) -- R, G, R, W averaged
	end)

	it("reads straight and premultiplied RGBA", function()
		local buf = "\255\0\0\128" -- half-transparent red, straight
		local c = gfx.edge_colors(buf, 1, 1, 4, "left", 1, 1)
		assert_near(c[1][1], 1, 1e-9)
		assert_near(c[1][4], 128 / 255, 1e-9)
		local pm = gfx.edge_colors("\128\0\0\128", 1, 1, 4, "left", 1, 1, true)
		assert_near(pm[1][1], 1, 1e-9)
		local clear = gfx.edge_colors("\0\0\0\0", 1, 1, 4, "left", 1, 1)
		assert_eq(clear[1][4], 0)
	end)

	it("stretches edge colours outwards into the haze", function()
		local cols = { { 1, 0, 0, 1 }, { 0, 0, 1, 1 } }
		local buf, w, h = gfx.edge_fill(cols, "left", 4, { 1, 1, 1, 1 }, 1)
		assert_eq(w, 4)
		assert_eq(h, 2)
		assert_eq(#buf, 4 * 2 * 4)
		assert_same(pixel(buf, 4, 3, 0), { 255, 0, 0, 255 })   -- at the image edge
		assert_same(pixel(buf, 4, 0, 0), { 255, 255, 255, 255 }) -- far end: haze
		assert_same(pixel(buf, 4, 3, 1), { 0, 0, 255, 255 })
		local b2, w2, h2 = gfx.edge_fill(cols, "top", 3, nil, 0)
		assert_eq(w2, 2)
		assert_eq(h2, 3)
		assert_same(pixel(b2, 2, 1, 2), { 0, 0, 255, 255 })
		local b3 = gfx.edge_fill(cols, "right", 4, { 1, 1, 1, 1 }, 1)
		assert_same(pixel(b3, 4, 0, 0), { 255, 0, 0, 255 })
	end)
end)
