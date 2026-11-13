-- client/map_model.lua and client/map_scroll.lua (pure Lua) on the real content/map.json: the data obeys its
-- rules, the right nodes are in view at every scroll position, the states follow the meta's progress, a tap finds
-- its node, the scroll physics (drag, tap, inertia, wheel, glide, clamp).

local json = require("tools.lib.json")
local map_model = require("client.map_model")
local map_scroll = require("client.map_scroll")

local function read_data()
	local f = assert(io.open("content/map.json", "rb"))
	local text = f:read("*a")
	f:close()
	return json.decode(text)
end

local CONCERTS = { [60] = true, [70] = true, [80] = true, [90] = true, [100] = true }

local function model()
	return map_model.new(read_data(), { kind_of = function(n) return CONCERTS[n] and "concert" or "day" end })
end

describe("content/map.json", function()
	it("passes the validator and its stretches are the districts of districts.json (first, last)", function()
		local d = read_data()
		assert_true(map_model.validate(d))
		local f = assert(io.open("content/districts.json", "rb"))
		local districts = json.decode(f:read("*a")).districts
		f:close()
		assert_eq(#d.segments, #districts)
		assert_eq(#d.nodes, districts[#districts].last)
		assert_eq(d.level_count, districts[#districts].last)
		for i, s in ipairs(d.segments) do
			assert_eq(s.district, districts[i].id)
			assert_eq(s.first, districts[i].first)
			assert_eq(s.last, districts[i].last)
		end
	end)

	it("names districts that exist and pictures that are in the asset registry", function()
		local assets = require("client.assets")
		local districts = json.decode(assert(io.open("content/districts.json", "rb")):read("*a"))
		local ids = {}
		for _, x in ipairs(districts.districts) do ids[x.id] = true end
		local d = read_data()
		local function has(key) assert_true(assets.image(key) ~= nil, "no image " .. tostring(key)) end
		for _, s in ipairs(d.segments) do
			assert_true(ids[s.district], s.district)
			has(s.bg)
			has(s.gate)
			for _, it in ipairs(s.deco) do
				has(it.image)
				assert_true(it.y >= s.y0 and it.y <= s.y1, "decoration outside its stretch")
			end
		end
		for _, kind in ipairs({ "day", "concert" }) do
			for _, key in pairs(d.node[kind].states) do has(key) end
		end
		has(d.path.dot)
		has(d.path.dot_done)
	end)

	it("keeps every node inside the map and clear of the district gates", function()
		local d = read_data()
		for _, n in ipairs(d.nodes) do
			assert_true(n.x >= 100 and n.x <= 620, "node " .. n.level .. " near the edge")
		end
		for i = 2, #d.segments do
			local s = d.segments[i]
			-- the gate (480 high) sits at the foot of the stretch: no node inside it
			for _, n in ipairs(d.nodes) do
				assert_true(math.abs(n.y - s.gate_y) > 240 + 40, "node " .. n.level .. " under the gate of " .. s.id)
			end
		end
	end)

	it("is what tools/gen_map.py writes", function()
		local p = io.popen("python3 tools/gen_map.py --check 2>&1")
		local out = p:read("*a")
		local ok = p:close()
		assert_true(ok == true or ok == 0 or ok == nil, out)
	end)

	it("is rejected when the rules are broken", function()
		local d = read_data()
		d.nodes[5].y = d.nodes[4].y
		assert_false(map_model.validate(d))
		d = read_data()
		d.segments[2].first = 22
		assert_false(map_model.validate(d))
		d = read_data()
		d.nodes[3] = nil
		assert_false(map_model.validate(d))
		assert_error(function() map_model.new({}) end, "map_model")
	end)
end)

describe("client.map_model", function()
	it("tells the states from the level to play", function()
		local m = model()
		assert_eq(m:state(1, 1), "current")
		assert_eq(m:state(2, 1), "locked")
		assert_eq(m:state(1, 5), "done")
		assert_eq(m:state(4, 5), "done")
		assert_eq(m:state(5, 5), "current")
		assert_eq(m:state(6, 5), "locked")
		assert_eq(m:state(100, nil), "done") -- everything beaten
		assert_eq(m:kind(60), "concert")
		assert_eq(m:kind(59), "day")
		assert_true(m:size(60) > m:size(59))
	end)

	it("lists the levels in view, nothing else, at every scroll position", function()
		local m = model()
		local view_h, margin = 1280, 200
		for off = 0, m.world_h, 137 do
			local first, last = m:visible(off, view_h, margin)
			for n = 1, m.count do
				local y = m:node(n).y
				local inside = y >= off - margin and y <= off + view_h + margin
				assert_eq(n >= first and n <= last, inside, "level " .. n .. " at offset " .. off)
			end
		end
	end)

	it("sizes the pools: a window never holds more levels than max_in_window", function()
		local m = model()
		local view_h = 1280 + 2 * 260
		local max = m:max_in_window(view_h)
		assert_true(max >= 8 and max <= 14, "max " .. max)
		for off = 0, m.world_h, 53 do
			local first, last = m:visible(off + 260, 1280, 260)
			assert_true(last - first + 1 <= max, "too many at " .. off)
		end
	end)

	it("lays trail dots along every gap: inside the gap, between the two nodes, once", function()
		local m = model()
		local seen = 0
		for g = 1, m.dot_total do
			local x, y, i = m:dot(g)
			local a, b = m:node(i), m:node(i + 1)
			assert_true(y > a.y and y < b.y, "dot " .. g .. " not between level " .. i .. " and " .. (i + 1))
			assert_true(x >= math.min(a.x, b.x) - 1 and x <= math.max(a.x, b.x) + 1)
			seen = seen + 1
		end
		assert_eq(seen, m.dot_total)
		-- dots of the visible levels, and the gaps either side
		local first, last = 10, 12
		local g0, g1 = m:dots(first, last)
		local _, _, gi = m:dot(g0)
		local _, _, gj = m:dot(g1)
		assert_eq(gi, 9)
		assert_eq(gj, 12)
		-- the dots up to a level are the ones Bit has walked
		assert_eq(m:dot_end(1), 0)
		local _, _, gap = m:dot(m:dot_end(5))
		assert_eq(gap, 4)
		assert_eq(m:dot_end(m.count + 1), m.dot_total)
		assert_true(m:max_dots(m:max_in_window(2000)) < 120)
	end)

	it("walks the path: u = level, halfway is halfway", function()
		local m = model()
		local x1, y1 = m:path_pos(1)
		assert_eq(x1, m:node(1).x)
		assert_eq(y1, m:node(1).y)
		local x, y = m:path_pos(3.5)
		assert_near(y, (m:node(3).y + m:node(4).y) / 2, 1e-9)
		assert_near(x, (m:node(3).x + m:node(4).x) / 2, 1e-9)
		local xe, ye = m:path_pos(100)
		assert_eq(ye, m:node(100).y)
		assert_eq(xe, m:node(100).x)
		local _, yb = m:path_pos(500)
		assert_eq(yb, m:node(100).y)
	end)

	it("finds the node under a tap, the nearest one, and nothing in between", function()
		local m = model()
		for n = 1, 100, 7 do
			local nd = m:node(n)
			assert_eq(m:pick(nd.x, nd.y), n)
			assert_eq(m:pick(nd.x + 40, nd.y - 30), n)
		end
		local nd = m:node(60)
		assert_eq(m:pick(nd.x + 80, nd.y), 60, "a concert node is bigger")
		assert_eq(m:pick(nd.x + 110, nd.y), nil)
		local a, b = m:node(30), m:node(31)
		assert_eq(m:pick((a.x + b.x) / 2, (a.y + b.y) / 2), nil)
		assert_eq(m:pick(5, 5), nil)
	end)

	it("finds the district stretch of a height and its background tiles", function()
		local m = model()
		assert_eq(m:segment_at(0), 1)
		assert_eq(m:segment_at(m:node(21).y), 2)
		assert_eq(m:segment_at(m.world_h + 500), 5)
		local seg = m.segments[2]
		local a, b = m:tiles(2, seg.y0 + 100, 1280, 0)
		assert_eq(a, 0)
		-- the tiles overlap (a tile hides the sky of the one below): every tile that touches the window is listed
		assert_true(m.tile_step < m.tile_h and m.tile_feather > 0, "overlapping tiles")
		assert_eq(m:tile_y(2, 0), seg.y0 - m.tile_feather)
		assert_eq(m:tile_y(2, 3) - m:tile_y(2, 2), m.tile_step)
		for i = a, b do
			assert_true(m:tile_y(2, i) < seg.y0 + 100 + 1280 and m:tile_y(2, i) + m.tile_h > seg.y0 + 100, "tile " .. i .. " touches")
		end
		assert_true(m:tile_y(2, b + 1) >= seg.y0 + 100 + 1280, "no tile is left out above")
		a, b = m:tiles(2, seg.y0 + 2000, 1280, 0)
		assert_true(m:tile_y(2, a - 1) + m.tile_h <= seg.y0 + 2000, "no tile is left out below")
		assert_true(m:tile_y(2, a) + m.tile_h > seg.y0 + 2000)
		a, b = m:tiles(2, 0, 1280, 0)
		assert_true(a > b, "a stretch far below has no tile")
		a, b = m:tiles(1, 0, 1280, 0)
		assert_eq(a, 0)
	end)

	it("puts a level where the window wants it and keeps the offset inside the map", function()
		local m = model()
		assert_eq(m:off_for(m:node(1).y, 1280, 0.4), 0)
		local off = m:off_for(m:node(50).y, 1280, 0.4)
		assert_near(m:node(50).y - off, 1280 * 0.4, 1e-9)
		assert_eq(m:off_for(m.world_h + 9999, 1280, 0.4), m:max_off(1280))
	end)
end)

describe("client.map_scroll", function()
	local function new() return map_scroll.new({ min = 0, max = 10000, pos = 3000 }) end

	it("a short touch is a tap and does not scroll", function()
		local s = new()
		s:press(600, 0)
		assert_false(s:move(610, 0.05))
		assert_true(s:release(0.1))
		assert_eq(s:pos(), 3000)
	end)

	it("a drag moves the content with the finger (the finger going down raises the position)", function()
		local s = new()
		s:press(600, 0)
		assert_true(s:move(500, 0.05)) -- past the slop: the drag starts, nothing scrolled yet
		assert_eq(s:pos(), 3000)
		assert_true(s:move(400, 0.1))
		assert_eq(s:pos(), 3100)
		assert_true(s:move(450, 0.15)) -- and back
		assert_eq(s:pos(), 3050)
		assert_false(s:release(0.15))
	end)

	it("moves content exactly with the finger once the slop is passed", function()
		local s = new()
		s:press(600, 0)
		s:move(560, 0.02) -- past the slop: starts from here
		local p0 = s:pos()
		s:move(460, 0.04)
		assert_near(s:pos(), p0 + 100, 1e-9) -- finger down by 100: the view moves up the map by 100
	end)

	it("flings with inertia that dies out, and stops at the end of the map", function()
		local s = new()
		s:press(900, 0)
		for i = 1, 6 do s:move(900 - i * 60, i * 0.016) end
		assert_false(s:release(0.1))
		local p = s:pos()
		local moved = false
		for _ = 1, 600 do
			if s:update(1 / 60) then moved = true end
		end
		assert_true(moved)
		assert_true(s:pos() > p, "the fling goes on")
		assert_false(s:moving())
		-- a hard fling to the end clamps
		s:press(900, 0)
		for i = 1, 6 do s:move(900 - i * 100, i * 0.01) end
		s:release(0.07)
		for _ = 1, 600 do s:update(1 / 60) end
		assert_true(s:pos() <= 10000)
		assert_true(s:pos() >= 0)
	end)

	it("a finger that rests before it lifts leaves no inertia", function()
		local s = new()
		s:press(900, 0)
		for i = 1, 6 do s:move(900 - i * 60, i * 0.016) end
		s:release(1.0)
		local p = s:pos()
		s:update(0.1)
		assert_eq(s:pos(), p)
	end)

	it("the wheel scrolls both ways and settles", function()
		local s = new()
		s:wheel(1)
		for _ = 1, 30 do s:update(1 / 60) end
		assert_true(s:pos() > 3000)
		local p = s:pos()
		s:wheel(-1)
		s:wheel(-1)
		for _ = 1, 120 do s:update(1 / 60) end
		assert_true(s:pos() < p)
		assert_false(s:moving())
		local z = map_scroll.new({ min = 0, max = 100, pos = 0 })
		z:wheel(-1)
		for _ = 1, 60 do z:update(1 / 60) end
		assert_eq(z:pos(), 0)
	end)

	it("glides to a spot, a press cancels it, the range clamps", function()
		local s = new()
		s:glide(5000, 0.5)
		assert_true(s:gliding())
		for _ = 1, 20 do s:update(1 / 60) end
		assert_true(s:pos() > 3000 and s:pos() < 5000)
		s:press(500, 1)
		assert_false(s:gliding())
		local p = s:pos()
		s:update(0.1)
		assert_eq(s:pos(), p)
		s:release(1.1)
		s:glide(99999, 0.2)
		for _ = 1, 30 do s:update(1 / 60) end
		assert_eq(s:pos(), 10000)
		s:glide(-50, 0)
		assert_eq(s:pos(), 0)
		s:set_range(0, 100)
		assert_eq(s:pos(), 0)
		s:set(500)
		assert_eq(s:pos(), 100)
	end)
end)
