local layout = require("client.layout")

describe("client.layout", function()
	it("fits the design area into windows of any aspect", function()
		local f = layout.fit(720, 1280)
		assert_near(f.scale, 1, 1e-9)
		assert_near(f.x0, 0, 1e-9)
		assert_near(f.y1, 1280, 1e-9)

		f = layout.fit(1080, 1920) -- same aspect, bigger
		assert_near(f.scale, 1.5, 1e-9)
		assert_near(f.ox, 0, 1e-9)

		f = layout.fit(1920, 1080) -- landscape: pillars left and right
		assert_near(f.scale, 1080 / 1280, 1e-9)
		assert_near(f.oy, 0, 1e-9)
		assert_true(f.x0 < 0 and f.x1 > 720)
		assert_near(f.x1 - f.x0, 1920 / f.scale, 1e-6)

		f = layout.fit(1170, 2532) -- tall phone: extra height
		assert_near(f.scale, 1170 / 720, 1e-9)
		assert_true(f.y0 < 0 and f.y1 > 1280)
		assert_near((f.y1 - f.y0) * f.scale, 2532, 1e-6)
	end)

	it("maps between window pixels and logical coordinates", function()
		local f = layout.fit(1920, 1080)
		local sx, sy = layout.logical_to_screen(f, 360, 640)
		assert_near(sx, 960, 1e-9)
		assert_near(sy, 540, 1e-9)
		local lx, ly = layout.screen_to_logical(f, sx, sy)
		assert_near(lx, 360, 1e-9)
		assert_near(ly, 640, 1e-9)
		lx, ly = layout.screen_to_logical(f, 0, 0)
		assert_near(lx, f.x0, 1e-9)
		assert_near(ly, 0, 1e-9)
	end)

	it("computes safe rects that always contain the design area", function()
		local f = layout.fit(1170, 2532)
		local r = layout.safe_rect(f, { inset_top = 141, inset_bottom = 102 })
		assert_near(r.y1, f.y1 - 141 / f.scale, 1e-9)
		assert_near(r.y0, f.y0 + 102 / f.scale, 1e-9)
		local huge = layout.safe_rect(layout.fit(720, 1280), { top = 300 })
		assert_eq(huge.y1, 1280)
	end)

	it("puts the board between the HUD and the booster bar", function()
		local area = layout.play_area(nil)
		assert_eq(area.y1, 1280 - layout.HUD_TOP)
		assert_eq(area.y0, layout.BOOSTER_BAR)
		local b = layout.board(9, 9, area)
		assert_eq(b.cell, math.floor((720 - 2 * layout.BOARD_MARGIN_X) / 9))
		assert_true(b.x0 >= 0 and b.x1 <= 720)
		assert_true(b.y0 >= area.y0 and b.y1 <= area.y1)
		assert_eq(b.width, b.cell * 9)
		assert_near(b.cx, 360, 1)
	end)

	it("limits cell size by height for tall boards and by max_cell for small ones", function()
		local area = layout.play_area(nil)
		local tall = layout.board(7, 11, area)
		assert_eq(tall.cell, math.floor((area.y1 - area.y0 - 2 * layout.BOARD_MARGIN_Y) / 11))
		local small = layout.board(5, 5, area)
		assert_eq(small.cell, layout.MAX_CELL)
		local custom = layout.board(5, 5, area, { max_cell = 80 })
		assert_eq(custom.cell, 80)
	end)

	it("uses the extra height of tall phones, within limits", function()
		local f = layout.fit(1170, 2532)
		local area = layout.play_area(f)
		assert_true(area.y1 - area.y0 > 1280 - layout.HUD_TOP - layout.BOOSTER_BAR)
		assert_true(area.y1 - area.y0 <= (1280 - layout.HUD_TOP - layout.BOOSTER_BAR) * 1.25 + 1e-6)
	end)

	it("maps cells to points and back (row 0 = top)", function()
		local b = layout.board(8, 10)
		local x, y = layout.cell_center(b, 0, 0)
		assert_near(x, b.x0 + b.cell / 2, 1e-9)
		assert_near(y, b.y1 - b.cell / 2, 1e-9)
		for col = 0, 7 do
			for row = 0, 9 do
				local cx, cy = layout.cell_center(b, col, row)
				local c, r = layout.cell_at(b, cx, cy)
				assert_eq(c, col)
				assert_eq(r, row)
			end
		end
		assert_eq(layout.cell_at(b, b.x0 - 1, b.cy), nil)
		assert_eq(layout.cell_at(b, b.cx, b.y1 + 1), nil)
		assert_eq(layout.cell_at(b, b.x1, b.cy), nil)
	end)

	it("converts core units to pixels", function()
		assert_eq(layout.units_to_px(3600, 80), 80)
		assert_eq(layout.units_to_px(1800, 80), 40)
	end)

	it("rejects bad board sizes", function()
		assert_error(function() layout.board(0, 5) end, "positive")
	end)

	it("puts a window with a ribbon and a mascot on the design area: it slides down, then shrinks", function()
		local up, down, margin = 100, 20, 16
		local function edges(h, k, dy) -- top and bottom of the whole window, logical px
			return layout.H / 2 + dy + k * (h / 2 + up), layout.H / 2 + dy - k * (h / 2 + down)
		end
		local room = layout.window_room(up, down, margin)
		assert_eq(room, 1248 - 120)
		-- a window that fits is left alone
		for _, h in ipairs({ 300, 900, 1040 }) do
			local k, dy = layout.fit_window(h, up, down, margin)
			assert_eq(k, 1, "h " .. h)
			assert_eq(dy, 0, "no move for h " .. h)
		end
		-- the tallest window that fits unscaled has the screen to itself
		local k, dy = layout.fit_window(room, up, down, margin)
		assert_near(k, 1, 1e-9)
		local top, bottom = edges(room, k, dy)
		assert_near(top, layout.H - margin, 1e-6)
		assert_near(bottom, margin, 1e-6)
		-- a little taller: it slides down first (the mascot is above, the shadow below is small), then it shrinks
		k, dy = layout.fit_window(1080, up, down, margin)
		assert_eq(k, 1)
		assert_true(dy < 0, "slid down: " .. dy)
		k = layout.fit_window(room + 100, up, down, margin)
		assert_true(k < 1, "and shrank")
		-- nothing leaves the margin at any height, and the bigger the window the smaller its content
		local last = 1
		for h = 400, 2400, 8 do
			k, dy = layout.fit_window(h, up, down, margin)
			top, bottom = edges(h, k, dy)
			assert_true(top <= layout.H - margin + 1e-6, "top at h " .. h .. ": " .. top)
			assert_true(bottom >= margin - 1e-6, "bottom at h " .. h .. ": " .. bottom)
			assert_true(k <= last + 1e-12 and k > 0, "k never grows with h")
			last = k
		end
		-- no margin given: the design area itself
		k, dy = layout.fit_window(layout.H, 0, 0)
		assert_eq(k, 1)
		assert_eq(dy, 0)
	end)

	it("keeps the play area clear of notches (safe-area insets)", function()
		local f = layout.fit(1170, 2532)
		local plain = layout.play_area(f)
		local insets = { inset_top = 141, inset_bottom = 102 }
		local notched = layout.play_area(f, { insets = insets })
		local safe = layout.safe_rect(f, insets)
		-- below the HUD anchored to the safe top, above the safe booster bar
		assert_true(notched.y1 <= safe.y1 - layout.HUD_TOP + 1e-6)
		assert_true(notched.y0 >= safe.y0 + layout.BOOSTER_BAR - 1e-6)
		-- without the insets the board would reach under the HUD
		assert_true(plain.y1 > safe.y1 - layout.HUD_TOP + 1)
		local b = layout.board(9, 9, notched)
		assert_true(b.y1 <= notched.y1 and b.y0 >= notched.y0)
	end)
end)
