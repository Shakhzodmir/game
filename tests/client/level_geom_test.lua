local geom = require("client.level_geom")
local layout = require("client.layout")

local function cells_from(rows)
	local out = {}
	for y, row in ipairs(rows) do
		for x = 1, #row do
			out[(y - 1) * #row + x] = { exists = row:sub(x, x) ~= ".", spawner = false, exit = row:sub(x, x) == "E" }
		end
	end
	return out
end

describe("client.level_geom", function()
	it("places core cells (y down) on the logical screen (y up)", function()
		local area = { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 }
		local g = geom.new(8, 8, cells_from({ "########", "########", "########", "########",
			"########", "########", "########", "########" }), area)
		local b = layout.board(8, 8, area)
		assert_eq(g.cell, b.cell)
		local lx, ly = g:center(1, 1)
		assert_near(lx, b.x0 + b.cell / 2, 1e-9)
		assert_near(ly, b.y1 - b.cell / 2, 1e-9) -- row 1 is the TOP row
		local lx8, ly8 = g:center(8, 8)
		assert_near(lx8, b.x1 - b.cell / 2, 1e-9)
		assert_near(ly8, b.y0 + b.cell / 2, 1e-9)
		-- same as layout.cell_center with 0-based col/row
		local cx, cy = layout.cell_center(b, 2, 4)
		local gx, gy = g:center(3, 5)
		assert_near(gx, cx, 1e-9)
		assert_near(gy, cy, 1e-9)
	end)

	it("turns core offsets into pixels (a falling piece is drawn above its cell)", function()
		local g = geom.new(6, 6, nil, { x0 = 0, y0 = 0, x1 = 600 + 36, y1 = 600 + 24 })
		assert_eq(g.cell, 100)
		local cx, cy = g:center(3, 4)
		local px, py = g:pos(3, 4, 0, 3600)
		assert_near(px, cx, 1e-9)
		assert_near(py, cy + 100, 1e-9) -- one cell of lag = one cell higher on screen
		px, py = g:pos(3, 4, 3600, 1800) -- a diagonal from the left: drawn left and up
		assert_near(px, cx - 100, 1e-9)
		assert_near(py, cy + 50, 1e-9)
		px = g:pos(3, 4, -3600, 0)
		assert_near(px, cx + 100, 1e-9)
	end)

	it("finds the cell under a point and continuous coordinates", function()
		local g = geom.new(6, 6, nil, { x0 = 0, y0 = 0, x1 = 636, y1 = 624 })
		local lx, ly = g:center(2, 5)
		local x, y = g:cell_at(lx + 40, ly - 40)
		assert_eq(x, 2)
		assert_eq(y, 5)
		local fx, fy = g:frac(lx, ly)
		assert_near(fx, 2, 1e-9)
		assert_near(fy, 5, 1e-9)
		fx, fy = g:frac(lx + 30, ly - 30) -- right and down: x and core y grow
		assert_near(fx, 2.3, 1e-9)
		assert_near(fy, 5.3, 1e-9)
		assert_eq(g:cell_at(g.x0 - 5, ly), nil)
		assert_eq(g:cell_at(lx, g.y1 + 5), nil)
	end)

	it("picks and turns the backing tiles like the art preview", function()
		-- a single cell: 4 outer corners
		local g = geom.new(1, 1, { { exists = true } }, { x0 = 0, y0 = 0, x1 = 136, y1 = 124 })
		local tiles = g:edge_tiles()
		assert_eq(#tiles, 4)
		local by = {}
		for _, t in ipairs(tiles) do
			assert_eq(t.kind, "outer")
			by[t.turns] = t
		end
		-- base (0 turns): the cell is bottom-right of the vertex = top-left corner of the board
		assert_near(by[0].lx, g.x0, 1e-9)
		assert_near(by[0].ly, g.y1, 1e-9)
		assert_near(by[1].lx, g.x0 + g.cell, 1e-9) -- cell bottom-left of the vertex: top-right corner
		assert_near(by[2].ly, g.y1 - g.cell, 1e-9) -- cell top-left: bottom-right corner
		assert_near(by[3].lx, g.x0, 1e-9)
	end)

	it("covers a shaped board with sides, inner corners and diagonals", function()
		local g = geom.new(3, 3, cells_from({ "##.", "###", ".##" }), { x0 = 0, y0 = 0, x1 = 336, y1 = 324 })
		local count = {}
		for _, t in ipairs(g:edge_tiles()) do count[t.kind] = (count[t.kind] or 0) + 1 end
		assert_eq(count.full, 2)
		assert_eq(count.inner, 2)
		assert_true((count.outer or 0) >= 4)
		assert_eq(count.diag, nil)
		local d = geom.new(2, 2, cells_from({ "#.", ".#" }), { x0 = 0, y0 = 0, x1 = 236, y1 = 224 })
		local kinds = {}
		for _, t in ipairs(d:edge_tiles()) do kinds[t.kind] = (kinds[t.kind] or 0) + 1 end
		assert_eq(kinds.diag, 1)
	end)

	it("clips entering pieces at the top of their segment", function()
		local g = geom.new(3, 4, cells_from({ ".##", "###", "#.#", "###" }), { x0 = 0, y0 = 0, x1 = 336, y1 = 424 })
		assert_eq(g:seg_top(1, 2), 2)
		assert_eq(g:seg_top(1, 4), 2)
		assert_eq(g:seg_top(2, 3), nil)
		assert_eq(g:seg_top(2, 4), 4)
		assert_eq(g:seg_top(3, 4), 1)
		assert_near(g:clip_top(1, 2), g.y1 - g.cell, 1e-9)
		assert_near(g:clip_top(3, 3), g.y1, 1e-9)
	end)

	it("lists exits and bolt directions", function()
		local g = geom.new(2, 2, cells_from({ "##", "#E" }), { x0 = 0, y0 = 0, x1 = 236, y1 = 224 })
		local ex = g:exits()
		assert_eq(#ex, 1)
		assert_eq(ex[1].x, 2)
		local _, cy = g:center(2, 2)
		assert_near(ex[1].ly, cy - g.cell / 2, 1e-9)
		local dx, dy = geom.dir("u")
		assert_eq(dx, 0)
		assert_eq(dy, 1) -- core "up" is +y on screen
		assert_eq(g:run_length(1, 1, "r"), 1)
		assert_eq(g:run_length(2, 2, "u"), 1)
		assert_eq(g:run_length(1, 2, "d"), 0)
	end)
end)
