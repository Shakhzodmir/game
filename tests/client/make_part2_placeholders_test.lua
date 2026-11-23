-- tools/art/make_part2_placeholders.py: the placeholder pictures of the districts of Part 2 (night versions of the
-- pictures of the parent district). Its default mode treated districts 19-22 as having no real pictures and made them
-- again: it wrote bg.png, bg_concert.png and level_bg.png next to the committed .jpg files (one image key twice:
-- gen_defold.py refuses to build) and repointed content/district_layouts.json at them. A district is made once now.
-- Its self test needs Pillow and numpy, which the CI has not: it runs here where those are installed and is skipped where
-- they are not, like the self tests of the neighbouring art tools in tests/client/map_tiles_test.lua. What is plain data
-- (installed.json) is checked everywhere.

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

local function exists(path)
	local f = io.open(path, "rb")
	if f then f:close() end
	return f ~= nil
end

local function have_pillow()
	local probe = run("python3 -I -c \"import PIL, numpy; print('pillow ok')\"")
	if probe and string.find(probe, "pillow ok", 1, true) then return true end
	print("  (skipped: Pillow or numpy is not installed)")
	return false
end

describe("tools/art/make_part2_placeholders.py (a district is made once)", function()
	it("makes a second run write nothing, --force give the same files, the backgrounds JPEG files and never a .png next to their .jpg", function()
		if not have_pillow() then return end
		local out = run("python3 -I tools/art/make_part2_placeholders.py selftest")
		assert_true(out ~= nil, "python3 did not start")
		assert_true(string.find(out, "make_part2_placeholders selftest: ok", 1, true) ~= nil, out)
	end)

	it("sees no picture missing in the project, a .jpg of a key counting as the picture (--status writes nothing)", function()
		if not have_pillow() then return end
		local out = run("python3 -I tools/art/make_part2_placeholders.py --status")
		assert_true(out ~= nil, "python3 did not start")
		local lines = 0
		for line in string.gmatch(out, "[^\r\n]+") do
			lines = lines + 1
			assert_true(string.find(line, "missing  0", 1, true) ~= nil, "something is missing: " .. line)
		end
		assert_true(lines >= 7, "districts 16-22 are reported: " .. out)
	end)

	it("leaves installed.json with every picture once: none under both extensions, none missing on disk (no Pillow needed)", function()
		local list = json.decode(read("assets/art_ready/installed.json")).files
		local seen = {}
		for _, f in ipairs(list) do seen[f] = (seen[f] or 0) + 1 end
		for _, f in ipairs(list) do
			assert_eq(seen[f], 1, f .. " is listed twice")
			local base, ext = string.match(f, "^(.*)(%.%a+)$")
			local other = (ext == ".png" and base .. ".jpg") or (ext == ".jpg" and base .. ".png") or nil
			assert_true(other == nil or not seen[other], f .. " and " .. tostring(other) .. " are one image key twice")
			assert_true(exists("assets/images/" .. f), f .. " is listed but is not in assets/images")
			assert_true(other == nil or not exists("assets/images/" .. other), other .. " lies next to " .. f)
		end
	end)
end)
