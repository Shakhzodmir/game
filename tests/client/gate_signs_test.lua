-- tools/art/gate_signs.py: where the district name goes on a gate picture (content/map_gates.json). It dropped the entry
-- of district 21 when it ran again (the board of the gate, copied from the beach, is not found in the warmer "day"
-- recolour), so the name fell back to the default place, wider than the 201 px board. Its self test needs Pillow and
-- numpy, which the CI has not: it runs here where those are installed and is skipped where they are not, like the
-- self tests of the neighbouring art tools in tests/client/map_tiles_test.lua. The keep rule itself (standard library
-- only) and the data of content/map_gates.json are checked everywhere.

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

local function have_pillow()
	local probe = run("python3 -I -c \"import PIL, numpy; print('pillow ok')\"")
	if probe and string.find(probe, "pillow ok", 1, true) then return true end
	print("  (skipped: Pillow or numpy is not installed)")
	return false
end

describe("tools/art/gate_signs.py (the place of the district name on a gate)", function()
	it("keeps the entry of a district whose board it does not find, drops the entry of a district without a gate (no Pillow needed)", function()
		local out = run("python3 -I tools/art/gate_signs.py selftest")
		assert_true(out ~= nil, "python3 did not start")
		assert_true(string.find(out, "gate_signs selftest (the keep rule): ok", 1, true) ~= nil, out)
		assert_true(string.find(out, "FAIL", 1, true) == nil, out)
	end)

	it("finds a white and a tinted board on synthetic gates, keeps the entry of a board that is too warm, gives the same file twice", function()
		if not have_pillow() then return end
		local out = run("python3 -I tools/art/gate_signs.py selftest")
		assert_true(out ~= nil, "python3 did not start")
		assert_true(string.find(out, "gate_signs selftest (pictures): ok", 1, true) ~= nil, out)
	end)

	it("gives the committed content/map_gates.json on the committed gate pictures (the entry of sunset_bossa survives a run)", function()
		if not have_pillow() then return end
		local out = run("python3 -I tools/art/gate_signs.py --check")
		assert_true(out ~= nil, "python3 did not start")
		assert_true(string.find(out, "map gates ok", 1, true) ~= nil, out)
	end)

	it("has a place for the name on every gate that is drawn: dx, dy, w and h, as wide as a gate picture at most", function()
		local gates = json.decode(read("content/map_gates.json"))
		local drawn = 0
		for _, d in ipairs(json.decode(read("content/districts.json")).districts) do
			local f = io.open("assets/images/mapbg/gate_" .. d.id .. ".png", "rb")
			if f then -- a district whose gate is not drawn yet writes its name on the plain default sign of the map
				f:close()
				drawn = drawn + 1
				local g = gates[d.id]
				assert_true(type(g) == "table", d.id .. " has a gate picture but no entry in content/map_gates.json (python3 tools/art/gate_signs.py; by hand when it finds no board)")
				for _, key in ipairs({ "dx", "dy", "w", "h" }) do
					assert_true(type(g[key]) == "number", d.id .. "." .. key .. " is not a number")
				end
				assert_true(g.w > 0 and g.w <= 720 and g.h > 0 and g.h <= 480, d.id .. ": the board is " .. g.w .. "x" .. g.h)
			end
		end
		assert_true(drawn >= 22, "the gates of districts 1-22 are drawn: " .. drawn)
	end)
end)
