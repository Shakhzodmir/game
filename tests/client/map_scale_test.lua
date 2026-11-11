-- The map holds at 120, 300 and 1000 levels (WP-13): what is in the pools depends on the window, not on the
-- number of levels; the data of a long game passes the validator; every scroll position finds the right nodes.

local map_model = require("client.map_model")
local synth = require("tests.client.map_synth")

local WINDOW = 1280 + 400   -- a tall window (logical px) plus the margin the screen keeps

local function build(n)
	local data = synth.make(n)
	local ok, why = map_model.validate(data)
	assert_true(ok, tostring(why))
	return map_model.new(data, { kind_of = function(level) return level % 20 == 0 and "concert" or "day" end }), data
end

describe("the map at many levels", function()
	local base = build(100)
	local base_nodes = base:max_in_window(WINDOW)
	local base_dots = base:max_dots(base_nodes + 2)

	for _, n in ipairs({ 120, 300, 1000 }) do
		it("holds " .. n .. " levels: the pools are the size of the 100-level map", function()
			local m = build(n)
			assert_eq(m.count, n)
			assert_eq(#m.segments, n / 20 + (n % 20 > 0 and 1 or 0))
			-- the same window holds the same number of nodes and dots wherever it is
			assert_eq(m:max_in_window(WINDOW), base_nodes)
			assert_eq(m:max_dots(base_nodes + 2), base_dots)
			-- a window sees at most that many tiles of a background, however long the segment
			local peak_tiles = 0
			for seg = 1, #m.segments do
				local s = m.segments[seg]
				for off = s.y0, s.y1, 777 do
					local a, b = m:tiles(seg, off, WINDOW - 400, 200)
					peak_tiles = math.max(peak_tiles, b - a + 1)
				end
			end
			assert_true(peak_tiles <= 3, "tiles in a window: " .. peak_tiles)
		end)

		it("finds the visible nodes, the path and the tap target at every height of a " .. n .. "-level map", function()
			local m = build(n)
			local top = m.world_h - 1300
			for off = 0, top, math.max(1, math.floor(top / 400)) do
				local first, last = m:visible(off, 1280, 100)
				assert_true(last - first + 1 <= base_nodes, "nodes in view: " .. (last - first + 1))
				if last >= first then
					assert_true(m:node(first).y >= off - 100 and m:node(last).y <= off + 1380)
					if first > 1 then assert_true(m:node(first - 1).y < off - 100) end
					if last < n then assert_true(m:node(last + 1).y > off + 1380) end
				end
			end
			-- tapping a node finds that level
			for _, level in ipairs({ 1, 2, math.floor(n / 2), n - 1, n }) do
				local nd = m:node(level)
				assert_eq(m:pick(nd.x, nd.y), level)
			end
			-- the trail: every dot belongs to a gap, dot_end grows with the level, the last point is the last node
			assert_true(m.dot_total >= n - 1)
			assert_eq(m:dot_end(n + 5), m.dot_total)
			local x, y = m:path_pos(n)
			assert_eq(y, m:node(n).y)
			assert_eq(m:state(n, nil), "done")
			assert_eq(m:state(n, n), "current")
			assert_eq(m:state(n, 1), n == 1 and "current" or "locked")
		end)
	end

	it("builds a 1000-level model in a blink and a 5000-level model without trouble", function()
		local t0 = os.clock()
		build(1000)
		assert_true(os.clock() - t0 < 2, "1000 levels took " .. (os.clock() - t0) .. " s")
		local m = build(5000)
		assert_eq(m.count, 5000)
		assert_eq(m:max_in_window(WINDOW), base_nodes)
	end)
end)
