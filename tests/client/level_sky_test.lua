-- The sky of the level screen (client/level_sky.lua): which district a level belongs to, the clouds that drift and
-- the stars that twinkle, and the background picture of the district (assets.level_bg_key).

local sky = require("client.level_sky")
local assets = require("client.assets")
local json = require("tools.lib.json")

local function read(path)
	local f = assert(io.open(path, "rb"))
	local s = f:read("*a")
	f:close()
	return s
end

local districts = json.decode(read("content/districts.json")).districts

describe("the district of a level", function()
	it("is the district whose levels hold it: 1..20 the first, 21 the second, the last level of the last one", function()
		assert_eq(sky.district_of(districts, 1), districts[1].id)
		assert_eq(sky.district_of(districts, 20), districts[1].id)
		assert_eq(sky.district_of(districts, 21), districts[2].id)
		assert_eq(sky.district_of(districts, 161), "bazaar")
		assert_eq(sky.district_of(districts, 300), "arcade")
		assert_eq(sky.district_of(districts, districts[#districts].last), districts[#districts].id)
	end)

	it("every level of the game has one, and nothing outside does", function()
		for n = 1, districts[#districts].last do
			assert_true(sky.district_of(districts, n) ~= nil, "level " .. n)
		end
		assert_eq(sky.district_of(districts, 0), nil)
		assert_eq(sky.district_of(districts, districts[#districts].last + 1), nil)
		assert_eq(sky.district_of(districts, "7"), nil)
		assert_eq(sky.district_of(nil, 7), nil)
	end)

	it("only known districts are evening districts (a typo would silently give a day sky)", function()
		local ids = {}
		for _, d in ipairs(districts) do ids[d.id] = true end
		for id in pairs(sky.NIGHT) do assert_true(ids[id], id .. " is not a district") end
	end)
end)

-- Which districts get the night sky (stars over the district's own evening picture) and which the day sky (clouds).
-- Pinned here on purpose: NIGHT is a plain list of ids, a district that is missing from it silently gets clouds over a
-- night picture (or the other way round). Part 2 is the second round of the genres: its pictures are the night versions
-- of the pictures of the parent district (tools/art/make_part2_placeholders.py LOOK), except the two sunny ones.
local NIGHT_PART1 = { cinema = true, skyclub = true, bluesclub = true, arcade = true }
local NIGHT_PART2 = {
	midnight_cafe = true,    -- 16 a rainy night
	late_club = true,        -- 17 after midnight
	nations_fest = false,    -- 18 a sunny parade: clouds
	fan_meeting = true,      -- 19 an evening, lightsticks
	punk_garage = true,      -- 20 a garage at night
	sunset_bossa = false,    -- 21 golden hour on the beach: clouds
	night_carnival = true,   -- 22 fireworks
}

describe("which districts have the night sky", function()
	it("every district of Part 2 is decided in this table (a new district must be added here and to client/level_sky.lua)", function()
		local seen = 0
		for _, d in ipairs(districts) do
			if (d.part or 1) >= 2 then
				seen = seen + 1
				assert_true(NIGHT_PART2[d.id] ~= nil, d.id .. " is a Part 2 district: decide its sky (stars or clouds), write it in NIGHT_PART2 and sky.NIGHT")
			end
		end
		assert_true(seen >= 7, "districts 16-22 are Part 2: " .. seen)
		local parts = {}
		for _, d in ipairs(districts) do parts[d.id] = d.part or 1 end
		for id in pairs(NIGHT_PART2) do -- order-free
			assert_true(parts[id] ~= nil and parts[id] >= 2, id .. " is not a district of Part 2")
		end
	end)

	it("the stars are over districts 16, 17, 19, 20 and 22, the clouds over 18 and 21", function()
		for id, night in pairs(NIGHT_PART2) do -- order-free
			assert_eq(sky.NIGHT[id] == true, night, id .. ": " .. (night and "stars" or "clouds") .. " expected")
			assert_eq(sky.kind(id, true), night and "stars" or "clouds", id .. " over its own picture")
			assert_eq(sky.kind(id, false), "clouds", id .. " over the common backdrop (a day sky)")
		end
		assert_eq(sky.kind("midnight_cafe", true), "stars")
		assert_eq(sky.kind("nations_fest", true), "clouds")
		assert_eq(sky.kind("sunset_bossa", true), "clouds")
	end)

	it("the whole night set is the four evening districts of Part 1 and the five of Part 2, nothing else", function()
		local want = {}
		for id in pairs(NIGHT_PART1) do want[#want + 1] = id end -- order-free: sorted below
		for id, night in pairs(NIGHT_PART2) do if night then want[#want + 1] = id end end -- order-free: sorted below
		table.sort(want)
		local got = {}
		for id, on in pairs(sky.NIGHT) do if on then got[#got + 1] = id end end -- order-free: sorted below
		table.sort(got)
		assert_same(got, want)
	end)
end)

describe("the picture behind the board", function()
	it("is the common one for a district without a picture of its own (and for no district)", function()
		local key, own = assets.level_bg_key("zz_no_picture")
		assert_eq(key, "backgrounds/level_bg")
		assert_false(own)
		key, own = assets.level_bg_key(nil)
		assert_eq(key, "backgrounds/level_bg")
		assert_false(own)
		assert_true(assets.has_image("backgrounds/level_bg"))
	end)

	it("is the district's own as soon as its picture is in the registry", function()
		local images = assets.index.images
		images["districts/zz_test/level_bg"] = { file = "/assets/images/districts/zz_test/level_bg.png", w = 720, h = 1280 }
		local ok, err = pcall(function()
			local key, own = assets.level_bg_key("zz_test")
			assert_eq(key, "districts/zz_test/level_bg")
			assert_true(own)
		end)
		images["districts/zz_test/level_bg"] = nil
		if not ok then error(err, 0) end
	end)

	it("has a picture of its own for every district of the game", function()
		for _, d in ipairs(districts) do
			local key, own = assets.level_bg_key(d.id)
			assert_eq(key, "districts/" .. d.id .. "/level_bg", d.id)
			assert_true(own, d.id)
			local e = assets.image(key)
			assert_true(e ~= nil and e.w == 720 and e.h == 1280, d.id .. " is 720x1280")
		end
	end)

	it("has the sprites the sky draws", function()
		for _, key in ipairs({ "fx/cloud", "fx/spark" }) do assert_true(assets.has_image(key), key) end
	end)
end)

describe("the opaque backgrounds are JPEG files (the archive the browser downloads must stay small)", function()
	it("room, concert and level backgrounds of every district are .jpg, 720x1280", function()
		local images = assets.index.images
		for _, d in ipairs(districts) do
			for _, name in ipairs({ "bg", "bg_concert", "level_bg" }) do
				local e = images["districts/" .. d.id .. "/" .. name]
				if e then -- a district without a concert picture falls back to the day one
					assert_true(e.file:sub(-4) == ".jpg", d.id .. "/" .. name .. " is " .. e.file .. ": run tools/art/to_jpeg_backgrounds.py")
					assert_true(e.w == 720 and e.h == 1280, d.id .. "/" .. name)
				end
			end
		end
	end)
end)

describe("the clouds", function()
	it("are drawn by day, over the common picture and over a district's own day picture", function()
		assert_eq(sky.kind("bazaar", true), "clouds")
		assert_eq(sky.kind("bazaar", false), "clouds")
		assert_eq(sky.kind("cinema", false), "clouds", "no picture of its own: the day sky of the common backdrop")
		assert_eq(sky.kind(nil, false), "clouds")
	end)

	it("are six, different in size and speed, and the first ones are the nearest", function()
		local items = sky.items("clouds", "bazaar")
		assert_eq(#items, #sky.CLOUDS)
		local widths, speeds = {}, {}
		for _, it in ipairs(items) do
			assert_eq(it.key, "fx/cloud")
			assert_eq(it.h * 2, it.w, "the sprite is 2:1")
			widths[it.w], speeds[it.speed] = true, true
			assert_true(it.alpha > 0 and it.alpha <= 1)
		end
		local nw, ns = 0, 0
		for _ in pairs(widths) do nw = nw + 1 end
		for _ in pairs(speeds) do ns = ns + 1 end
		assert_true(nw >= 4 and ns >= 4, "not a row of copies")
	end)

	it("drift to the right and come back from the left, always inside their lane", function()
		for _, it in ipairs(sky.items("clouds", "cafe")) do
			local pad = it.w + sky.MARGIN
			local x0, y0 = sky.pose(it, 0, false)
			assert_eq(x0, it.x)
			assert_eq(y0, it.y)
			local x1 = sky.pose(it, 1, false)
			assert_true(math.abs(x1 - (x0 + it.speed)) < 1e-9, "it moves right by its speed")
			for t = 0, 4000, 37 do
				local x = sky.pose(it, t, false)
				assert_true(x >= -pad - 1e-9 and x < sky.W + pad + 1e-9, "x " .. x .. " at t=" .. t)
			end
			-- a lap takes (W + 2 pad) / speed seconds and brings it back to the same place
			local lap = (sky.W + 2 * pad) / it.speed
			local a, b = sky.pose(it, 100, false), sky.pose(it, 100 + lap, false)
			assert_true(math.abs(a - b) < 1e-6, "a lap returns it")
		end
	end)

	it("enter and leave out of sight: the lane starts and ends beyond the screen even on a wide one", function()
		for _, it in ipairs(sky.items("clouds", "cafe")) do
			-- the cloud is centred on x; at the start of its lane (x = -(w + MARGIN)) its right edge is still
			-- MARGIN + w / 2 left of the design area, and at the end of the lane its left edge is as far right
			local pad = it.w + sky.MARGIN
			assert_true(-pad + it.w / 2 <= -sky.MARGIN)
			assert_true(sky.W + pad - it.w / 2 >= sky.W + sky.MARGIN)
			assert_true(sky.MARGIN >= 120, "a 3:4 screen shows 120 px more on each side of the design area")
		end
	end)

	it("stand still with reduced motion, whatever the time", function()
		for _, it in ipairs(sky.items("clouds", "jazz")) do
			local x0, y0, a0 = sky.pose(it, 0, true)
			local x1, y1, a1 = sky.pose(it, 1234, true)
			assert_same({ x0, y0, a0 }, { x1, y1, a1 })
			assert_eq(x0, it.x)
		end
	end)
end)

describe("the stars", function()
	it("are drawn only over a district's own evening picture", function()
		for id in pairs(sky.NIGHT) do
			assert_eq(sky.kind(id, true), "stars", id)
			assert_eq(sky.kind(id, false), "clouds", id)
		end
		assert_eq(sky.kind("beach", true), "clouds")
	end)

	it("stand in the same places every time, at the top, and differ between districts", function()
		local a, b, c = sky.items("stars", "skyclub"), sky.items("stars", "skyclub"), sky.items("stars", "arcade")
		assert_eq(#a, sky.STARS)
		assert_same(a, b)
		local same = true
		for i = 1, #a do
			local s = a[i]
			assert_eq(s.key, "fx/spark")
			assert_true(s.x >= 30 and s.x <= sky.W - 30 and s.y >= 880 and s.y <= sky.H, "star " .. i)
			assert_true(s.w >= 20 and s.w <= 42)
			if s.x ~= c[i].x or s.y ~= c[i].y then same = false end
		end
		assert_false(same, "another district, another sky")
	end)

	it("twinkle: the brightness changes with time and stays visible, a still sky shows them half lit", function()
		for _, s in ipairs(sky.items("stars", "cinema")) do
			local lo, hi = 1, 0
			for t = 0, 20, 0.25 do
				local _, _, alpha, scale = sky.pose(s, t, false)
				assert_true(alpha > 0 and alpha <= 1, "alpha " .. alpha)
				assert_true(scale >= 0.8 - 1e-9 and scale <= 1.2 + 1e-9, "scale " .. scale)
				lo, hi = math.min(lo, alpha), math.max(hi, alpha)
			end
			assert_true(hi - lo > 0.1, "it twinkles")
			local x, y, a, sc = sky.pose(s, 99, true)
			assert_eq(x, s.x)
			assert_eq(y, s.y)
			assert_true(math.abs(sc - 1) < 1e-9 and a > 0)
		end
	end)
end)
