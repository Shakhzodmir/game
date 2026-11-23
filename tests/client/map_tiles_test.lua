-- The map tiles (assets/images/mapbg/bg_<district>): the map lays the tiles of a district 740 px apart and blends the
-- faded bottom 110 rows of one into the next (content/map.json tile_step, tile_feather; client/map_model.lua). An OPAQUE
-- tile (a JPEG, an RGB PNG, an RGBA PNG without the fade) shows a hard horizontal seam every 740 px and next to every
-- gate: districts 16 and 17 had it for a week. tools/art/tile_check.py (standard library only: CI has no Pillow) reads
-- the alpha of every tile; the tools that make and install tiles have self tests of their own (Pillow and numpy, run
-- here where they are installed and skipped where they are not).

local assets = require("client.assets")
local json = require("tools.lib.json")

local function run(cmd)
	local p = io.popen(cmd .. " 2>&1")
	if not p then return nil end
	local out = p:read("*a")
	p:close()
	return out
end

local function read(path)
	local f = assert(io.open(path, "rb"))
	local s = f:read("*a")
	f:close()
	return s
end

describe("map tiles", function()
	it("are all 720x1080 RGBA PNGs with the bottom 110 rows faded out and nothing else transparent", function()
		local out = run("python3 -I tools/art/tile_check.py")
		assert_true(out ~= nil, "python3 did not start")
		assert_true(string.find(out, "map tiles ok", 1, true) ~= nil, out)
	end)

	it("are checked by a check that can fail (an opaque tile, a JPEG, no fade, a hole, a broken installed.json)", function()
		local out = run("python3 -I tools/art/tile_check.py selftest")
		assert_true(out ~= nil, "python3 did not start")
		assert_true(string.find(out, "tile_check selftest: ok", 1, true) ~= nil, out)
	end)

	it("are PNG files in the asset index, one per segment of the map (a JPEG has no alpha)", function()
		local map = json.decode(read("content/map.json"))
		local images, n = assets.index.images, 0
		for key, e in pairs(images) do -- order-free
			if string.match(key, "^mapbg/bg_") then
				n = n + 1
				assert_eq(e.file, "/assets/images/" .. key .. ".png", key .. ": run tools/art/feather_mapbg.py")
				assert_true(e.w == map.width and e.h == map.tile_h, key .. " is " .. e.w .. "x" .. e.h)
			end
		end
		assert_eq(n, #map.segments, "one tile per district of content/map.json")
		for _, s in ipairs(map.segments) do
			assert_true(images[s.bg] ~= nil, s.id .. " has no tile " .. tostring(s.bg))
		end
	end)

	it("have one feather in the tools and in the map (110 rows, 740 px apart in a 1080 px tile)", function()
		local map = json.decode(read("content/map.json"))
		local gen = read("tools/gen_map.py")
		local feather = read("tools/art/feather_mapbg.py")
		assert_eq(tonumber(string.match(gen, "TILE_FEATHER = (%d+)")), map.tile_feather, "gen_map.py")
		assert_eq(tonumber(string.match(feather, "\nFEATHER = (%d+)")), map.tile_feather, "feather_mapbg.py")
		assert_eq(tonumber(string.match(feather, "\nW, H = (%d+), %d+")), map.width, "feather_mapbg.py width")
		assert_eq(tonumber(string.match(feather, "\nW, H = %d+, (%d+)")), map.tile_h, "feather_mapbg.py height")
		assert_eq(map.tile_step, 740)
		assert_eq(map.tile_h - map.tile_step - map.tile_feather, 230, "the sky of a tile that the next one covers")
	end)
end)

describe("the art tools that make and install tiles", function()
	local function have_pillow()
		local probe = run("python3 -I -c \"import PIL, numpy; print('pillow ok')\"")
		if probe and string.find(probe, "pillow ok", 1, true) then return true end
		print("  (skipped: Pillow or numpy is not installed)")
		return false
	end

	it("make a tile feathered whatever the file was (PNG, JPEG, opaque RGBA, any size), leave a feathered one alone, never turn one into a JPEG", function()
		if not have_pillow() then return end
		local out = run("python3 -I tools/art/feather_mapbg.py selftest")
		assert_true(out ~= nil, "python3 did not start")
		assert_true(string.find(out, "feather_mapbg selftest: ok", 1, true) ~= nil, out)
	end)

	it("install a whole district with a JPEG map picture: the tile comes out feathered, a placeholder is replaced for good", function()
		if not have_pillow() then return end
		local out = run("python3 -I tools/art/install_district.py selftest")
		assert_true(out ~= nil, "python3 did not start")
		assert_true(string.find(out, "install_district selftest: ok", 1, true) ~= nil, out)
	end)

	it("keep the notes of installed.json (every installer saves with its sources and unmarks what it writes)", function()
		for _, name in ipairs({ "install_district", "install_icon_sheet", "install_items_sheet", "install_level_bg" }) do
			local src = read("tools/art/" .. name .. ".py")
			assert_true(string.find(src, "inst.load_sources()", 1, true) ~= nil, name .. " loads the sources")
			assert_true(string.find(src, "inst.save(files, sources)", 1, true) ~= nil, name .. " saves the sources again")
			assert_true(string.find(src, "inst.record(files, sources,", 1, true) ~= nil, name .. " unmarks the pictures it writes")
			assert_true(string.find(src, "inst.save(files)", 1, true) == nil, name .. " must not save the list without its sources")
		end
	end)

	it("refuse a map picture that is not 2:3 (a square is stretched 1.5x otherwise) before a file of the district is written", function()
		local district = read("tools/art/install_district.py")
		local made = string.find(district, "tile = fm.feather(picture)", 1, true)
		assert_true(made ~= nil, "install_district.py makes the tile with feather_mapbg.feather")
		assert_true(string.find(district, 'save(tile, "mapbg/bg_%s.png" % did)', 1, true) ~= nil, "install_district.py installs that tile")
		local first_save = string.find(district, 'save(Image.open(src("room_', 1, true)
		assert_true(first_save ~= nil and made < first_save,
			"the tile is made before the first picture is saved: a refused map picture must not leave a half-installed district")
		-- the shape is checked in one place, the function every installer calls
		assert_eq(tonumber(string.match(read("tools/art/feather_mapbg.py"), "\nRATIO_TOLERANCE = ([%d.]+)")), 0.02, "feather_mapbg.py RATIO_TOLERANCE")
	end)

	it("feather every map tile an installer writes, and never turn one into a JPEG", function()
		local jpeg = read("tools/art/to_jpeg_backgrounds.py")
		assert_true(string.find(jpeg, 'LOOSE = ("districts", "backgrounds")', 1, true) ~= nil, "to_jpeg_backgrounds.py leaves mapbg alone")
	end)
end)
