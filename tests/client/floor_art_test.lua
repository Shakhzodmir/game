-- The dance-floor art itself (assets/images/blockers/floor_*.png, ui/icons/goal_floor.png): the pixel facts that
-- make the floor readable, checked by tools/art/floor_check.py (standard library only, so no numpy or Pillow is
-- needed where the suite runs). They are what the producer's report was about: unlit tiles that hardly differed
-- from the ordinary cells, a goal icon that showed the end state instead of the start.

local function run(args)
	local p = io.popen("python3 tools/art/floor_check.py " .. (args or "") .. " 2>&1")
	if not p then return nil end
	local out = p:read("*a")
	p:close()
	return out
end

describe("dance-floor art", function()
	it("keeps the unlit tiles clearly darker and more saturated than the cells, the lit ones gold, the half stage two-coloured and the goal icon violet on gold", function()
		local out = run()
		assert_true(out ~= nil, "python3 did not start")
		assert_true(string.find(out, "floor art ok", 1, true) ~= nil, out)
	end)

	it("fails on a floor that is pale again (the check is only worth something if it can fail)", function()
		-- a directory with the shipped cell and icon but a pale floor: the lit tile in every slot
		local dir = os.tmpname()
		os.remove(dir)
		os.execute("mkdir -p '" .. dir .. "/blockers' '" .. dir .. "/board' '" .. dir .. "/ui/icons'")
		local function copy(rel, from)
			os.execute("cp 'assets/images/" .. (from or rel) .. "' '" .. dir .. "/" .. rel .. "'")
		end
		copy("board/cell_b.png")
		copy("ui/icons/goal_floor.png")
		for _, k in ipairs({ "1", "2", "half", "lit" }) do copy("blockers/floor_" .. k .. ".png", "blockers/floor_lit.png") end
		local out = run("'" .. dir .. "'")
		os.execute("rm -rf '" .. dir .. "'")
		assert_true(out ~= nil)
		assert_true(string.find(out, "floor art ok", 1, true) == nil, out)
		assert_true(string.find(out, "must be violet", 1, true) ~= nil, out)
		assert_true(string.find(out, "look alike", 1, true) ~= nil, out)
	end)
end)
