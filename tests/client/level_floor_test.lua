-- The look of the dance floor (client/level_floor.lua): violet = still to light, gold = lit, a stage in between
-- for a tile with two layers; the goal icon, the HUD and the start window show the same tile as the board.

local level_floor = require("client.level_floor")
local levels = require("client.levels")
local assets = require("client.assets")

describe("client.level_floor", function()
	it("names the stage of a tile from its hp in the level file and what is left of it", function()
		assert_eq(level_floor.stage(2, 2), "two")
		assert_eq(level_floor.stage(2, 1), "half") -- a two-layer tile after its first hit
		assert_eq(level_floor.stage(1, 1), "one")
		assert_eq(level_floor.stage(1, 0), "lit")
		assert_eq(level_floor.stage(2, 0), "lit")
		-- a one-layer tile never shows the half stage, a two-layer tile always passes through it
		local saw_half = false
		for hp = 2, 0, -1 do saw_half = saw_half or level_floor.stage(2, hp) == "half" end
		assert_true(saw_half)
		for hp = 1, 0, -1 do assert_true(level_floor.stage(1, hp) ~= "half") end
	end)

	it("draws every stage with a picture of its own and the pictures exist in the game atlas", function()
		local seen = {}
		for _, stage in ipairs({ "two", "one", "half", "lit" }) do
			local key = level_floor.IMAGE[stage]
			assert_true(key ~= nil, stage)
			local e = assets.image(key)
			assert_true(e ~= nil, key .. " is not in the registry")
			assert_eq(e.atlas, "game", key) -- the background GUI has the game atlas
			assert_eq(seen[key], nil, key .. " is used by two stages")
			seen[key] = true
		end
		assert_eq(level_floor.image(2, 2), "blockers/floor_2")
		assert_eq(level_floor.image(2, 1), "blockers/floor_half")
		assert_eq(level_floor.image(1, 1), "blockers/floor_1")
		assert_eq(level_floor.image(1, 0), "blockers/floor_lit")
	end)

	it("pops a tile only when it changes into the half or the lit stage, the last layer with the bigger pop", function()
		assert_eq(level_floor.pop("two"), nil)
		assert_eq(level_floor.pop("one"), nil)
		local half, lit = level_floor.pop("half"), level_floor.pop("lit")
		assert_true(half.scale > 1 and lit.scale > half.scale)
		assert_true(half.time > 0 and lit.time >= half.time)
	end)

	it("has a goal icon that exists in the UI atlas and is not the lit tile", function()
		local e = assets.image(level_floor.GOAL_ICON)
		assert_true(e ~= nil, "no goal icon in the registry")
		assert_eq(e.atlas, "ui") -- the town's start window has it too (it draws the ui and meta atlases)
		assert_true(level_floor.GOAL_ICON ~= level_floor.IMAGE.lit, "the goal icon must show the unlit tile (the start of the level)")
	end)

	it("gives the goal of a dance-floor level the same icon in the HUD and the start window", function()
		local goals = levels.goals({
			goals = { { type = "light" } },
			floor = { { at = { 0, 0 }, hp = 1 }, { at = { 1, 0 }, hp = 2 }, { at = { 2, 0 }, hp = 2 } },
		})
		assert_eq(#goals, 1)
		assert_eq(goals[1].kind, "light")
		assert_eq(goals[1].image, level_floor.GOAL_ICON)
		assert_eq(goals[1].count, 3)
	end)

	it("asks for the icon, not for the lit tile, on the shipped dance-floor levels", function()
		levels._reset()
		levels.read = function(path)
			local f = io.open((string.gsub(path, "^/", "")), "rb")
			if not f then return nil end
			local text = f:read("*a")
			f:close()
			return text
		end
		levels.decode = require("tools.lib.json").decode
		local ok, err = pcall(function()
			for _, n in ipairs({ 15, 16, 17, 20, 36 }) do
				local info = assert(levels.load(n), "level " .. n)
				local found = false
				for _, g in ipairs(info.goals) do
					if g.kind == "light" then
						found = true
						assert_eq(g.image, level_floor.GOAL_ICON, "level " .. n)
						assert_true(g.count > 0, "level " .. n .. " counts its tiles")
					end
				end
				assert_true(found, "level " .. n .. " has no light goal")
			end
		end)
		levels._reset()
		if not ok then error(err, 0) end
	end)
end)
