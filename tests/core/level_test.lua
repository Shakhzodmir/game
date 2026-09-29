local core = require("core.game")
local L = require("core.level")
local HS = require("core.hash")
local json = require("tools.lib.json")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }

local function errors_of(lvl)
	local ok, errs = core.load_level(lvl)
	assert_eq(ok, nil, "level should be rejected")
	return errs
end

local function has_error(errs, prefix)
	for _, e in ipairs(errs) do
		if string.sub(e, 1, #prefix) == prefix then return true end
	end
	return false
end

local function expect(lvl, prefix)
	local errs = errors_of(lvl)
	assert_true(has_error(errs, prefix), "expected '" .. prefix .. "' in: " .. table.concat(errs, " | "))
end

local VALID_TEXT = [[
{"id": 7, "version": 2, "size": [6, 6], "moves": 20, "difficulty": "medium",
 "colors": ["red", "green", "blue", "yellow"],
 "goals": [{"type": "collect", "color": "red", "count": 10}],
 "cells": ["######", "######", "######", "######", "######", "######"],
 "spawn_weights": null, "floor": []}
]]

describe("core level: loading", function()
	it("loads a valid level and normalizes it", function()
		local lvl = assert(core.load_level(VALID_TEXT))
		assert_eq(lvl.W, 6)
		assert_eq(lvl.H, 6)
		assert_same(lvl.colors, { 1, 3, 4, 5 }, "global colour order")
		assert_same(lvl.weights, { [1] = 1, [3] = 1, [4] = 1, [5] = 1 })
		assert_same(lvl.goals, { { type = 1, param = 1, count = 10 } })
		assert_eq(lvl.difficulty, 2)
		for x = 1, 6 do assert_true(lvl.spawner[x], "top row spawns") end
		assert_false(lvl.spawner[7])
		assert_false(lvl.exit[31], "exits only exist with a deliver goal")
	end)

	it("accepts an already decoded table with the same canonical form and hash", function()
		local a = assert(core.load_level(VALID_TEXT))
		local b = assert(core.load_level(json.decode(VALID_TEXT)))
		assert_eq(a.canonical, b.canonical)
		assert_eq(a.hash, b.hash)
	end)

	it("builds the canonical form of 2.2", function()
		local lvl = assert(core.load_level(VALID_TEXT))
		assert_eq(lvl.canonical, '{"cells":["######","######","######","######","######","######"],'
			.. '"colors":["red","green","blue","yellow"],"difficulty":"medium",'
			.. '"floor":[],"goals":[{"color":"red","count":10,"type":"collect"}],'
			.. '"id":7,"moves":20,"size":[6,6],"version":2}')
		assert_eq(lvl.hash, HS.fold_bytes(lvl.canonical))
	end)

	it("rejects null inside arrays, fractions, exponents and repeated keys (2.2)", function()
		local bad = {
			'{"id": 1, "size": [6, null]}',
			'{"id": 1.5}',
			'{"id": 1e2}',
			'{"id": 1, "id": 2}',
			'{"id": 1,}',
			'[1, 2]',
		}
		for _, text in ipairs(bad) do
			local lvl, errs = core.load_level(text)
			assert_eq(lvl, nil, text)
			assert_true(#errs >= 1)
		end
		local _, errs = core.load_level('{"id": 1, "id": 2}')
		assert_true(string.find(errs[1], "repeated key", 1, true) ~= nil, errs[1])
		_, errs = core.load_level('{"id": 1.5}')
		assert_eq(string.sub(errs[1], 1, 3), "2.2")
	end)

	it("treats a null value as a missing key", function()
		local text = string.gsub(VALID_TEXT, '"floor": %[%]', '"floor": null')
		local lvl = assert(core.load_level(text))
		assert_false(string.find(lvl.canonical, "floor", 1, true) ~= nil)
	end)
end)

describe("core level: schema (2.0, 2.1.1)", function()
	it("rejects unknown keys at every level", function()
		expect(H.level(FULL, { extra = 1 }), "2.1.1 level: unknown key 'extra'")
		expect(H.level(FULL, { goals = { { type = "light", count = 3 } }, floor = { { at = { 0, 0 }, hp = 1 } } }), "2.1.1 goals[1]: unknown key")
		expect(H.level(FULL, { slots = { { at = { 0, 0 }, type = "noise", hp = 1 } } }), "2.1.1 slots[1]: unknown key 'hp'")
	end)

	it("checks sizes and ranges", function()
		expect(H.level({ "#####", "#####", "#####", "#####", "#####", "#####" }), "2.1.1 size")
		expect(H.level(FULL, { moves = 4 }), "2.1.1 moves")
		expect(H.level(FULL, { moves = 61 }), "2.1.1 moves")
		expect(H.level(FULL, { difficulty = "extreme" }), "2.1.1 difficulty")
		expect(H.level(FULL, { id = 0 }), "2.1.1 id")
		expect(H.level(FULL, { colors = { "red", "green", "blue" } }), "2.1.1 colors")
		expect(H.level(FULL, { colors = { "red", "red", "blue", "green" } }), "2.1.1 colors: repeated")
		expect(H.level(FULL, { goals = {} }), "2.1.1 goals")
		expect(H.level(FULL, { cells = { "######" } }), "2.1.1 cells")
	end)

	it("requires every element field", function()
		expect(H.level(FULL, { floor = { { at = { 0, 0 } } } }), "2.1.1 floor[1]: hp")
		expect(H.level(FULL, { overlay = { { at = { 0, 0 }, hp = 1 } } }), "2.1.1 overlay[1]: type")
		expect(H.level(FULL, { slots = { { at = { 0, 0 }, type = "riff" } } }), "2.1.1 slots[1]: bad or missing axis")
		expect(H.level(FULL, { slots = { { at = { 0, 0 }, type = "record_box", hp = 4 } } }), "2.1.1 slots[1]: bad or missing hp")
		expect(H.level(FULL, { slots = { { type = "noise" } } }), "2.1.1 slots[1]: at")
	end)

	it("rejects two goals on the same pair", function()
		expect(H.level(FULL, { goals = {
			{ type = "collect", color = "red", count = 3 }, { type = "collect", color = "red", count = 4 },
		} }), "2.1.1 goals[2]: repeated goal")
	end)

	it("checks spawn_weights keys against the level colours", function()
		local colors = { "red", "green", "blue", "yellow" }
		expect(H.level(FULL, { colors = colors, spawn_weights = { red = 1, green = 1, blue = 1 } }), "2.1.1 spawn_weights: missing")
		expect(H.level(FULL, { colors = colors, spawn_weights = { red = 1, green = 1, blue = 1, yellow = 1, purple = 1 } }), "2.1.1 spawn_weights: key")
		expect(H.level(FULL, { colors = colors, spawn_weights = { red = 1, green = 1, blue = 1, yellow = 1001 } }), "2.1.1 spawn_weights: weight")
		local lvl = assert(core.load_level(H.level(FULL, { colors = colors, spawn_weights = { red = 5, green = 1, blue = 2, yellow = 1 } })))
		assert_same(lvl.weights, { [1] = 5, [3] = 1, [4] = 1, [5] = 2 })
	end)

	it("ties the mic block to the deliver goal", function()
		expect(H.level(FULL, { goals = { { type = "deliver", count = 2 } } }), "2.1.1 mic: block required")
		expect(H.level(FULL, { goals = { { type = "deliver", count = 2 } }, mic = { total = 3, on_board_max = 1, gap_moves = 0 } }),
			"2.1.1 mic: total must equal")
	end)
end)

describe("core level: validation (2.1)", function()
	it("2.1.2: positions must be existing cells without repeats", function()
		expect(H.level({ "######", "#.####", "######", "######", "######", "######" }, { floor = { { at = { 1, 1 }, hp = 1 } } }),
			"2.1.2 floor is not on an existing cell at 1,1")
		expect(H.level(FULL, { floor = { { at = { 6, 0 }, hp = 1 } } }), "2.1.2 floor is not on an existing cell at 6,0")
		expect(H.level(FULL, { floor = { { at = { 2, 2 }, hp = 1 }, { at = { 2, 2 }, hp = 2 } } }), "2.1.2 two floor elements")
		expect(H.level(FULL, { slots = { { at = { 2, 2 }, type = "noise" }, { at = { 2, 2 }, type = "mic" } } }), "2.1.2 two slot elements")
		expect(H.level(FULL, { spawners = { { 0, 0 }, { 0, 0 } } }), "2.1.2 repeated spawner")
	end)

	it("2.1.2: a column needs four free existing cells", function()
		expect(H.level(FULL, { slots = { { at = { 5, 2 }, type = "column", hp = 6 } } }), "2.1.2 column needs 4 existing cells")
		expect(H.level(FULL, { slots = { { at = { 2, 2 }, type = "column", hp = 6 }, { at = { 3, 3 }, type = "noise" } } }),
			"2.1.2 two slot elements")
	end)

	it("2.1.2: the cell above a spawner is a void or the edge", function()
		expect(H.level(FULL, { spawners = { { 0, 1 } } }), "2.1.2 the cell above a spawner")
	end)

	it("2.1.3: wires only over regular pieces", function()
		expect(H.level(FULL, { overlay = { { at = { 2, 2 }, type = "wires", hp = 1 } }, slots = { { at = { 2, 2 }, type = "noise" } } }),
			"2.1.3 wires over a cell without a regular piece at 2,2")
		assert_true(core.load_level(H.level(FULL, { overlay = { { at = { 2, 2 }, type = "wires", hp = 1 } } })) ~= nil)
	end)

	it("2.1.4: preset colours belong to the level", function()
		expect(H.level(FULL, { colors = { "red", "green", "blue", "yellow" }, slots = { { at = { 1, 1 }, type = "piece", color = "purple" } } }),
			"2.1.4 colour 'purple'")
	end)

	it("2.1.5: goals must be reachable", function()
		expect(H.level(FULL, { colors = { "red", "green", "blue", "yellow" }, goals = { { type = "collect", color = "purple", count = 1 } } }), "2.1.5 collect")
		expect(H.level(FULL, { goals = { { type = "break", item = "noise", count = 2 } }, slots = { { at = { 1, 1 }, type = "noise" } } }), "2.1.5 break count")
		expect(H.level(FULL, { goals = { { type = "break", item = "wires", count = 1 } } }), "2.1.5 break item")
		expect(H.level(FULL, { goals = { { type = "light" } } }), "2.1.5 light")
	end)

	it("2.1.6: at most three different elements", function()
		expect(H.level(FULL, {
			floor = { { at = { 0, 5 }, hp = 1 } },
			overlay = { { at = { 1, 5 }, type = "wires", hp = 1 } },
			slots = { { at = { 2, 3 }, type = "noise" }, { at = { 3, 3 }, type = "record_box", hp = 1 } },
		}), "2.1.6")
	end)

	it("2.1.7: every free cell of B0 fills (no pocket under a blocker)", function()
		expect(H.level({ "######", "#.####", "#.####", "#.####", "#.####", "#.####" },
			{ slots = { { at = { 0, 1 }, type = "concrete", hp = 1 } } }), "2.1.7 cell stays empty on board B0 at 0,2")
	end)

	it("2.1.7: every cell of B1 fills", function()
		expect(H.level({ "#.####", "#.####", "..####", "#.####", "#.####", "#.####" }), "2.1.7 cell stays empty on board B1 at 0,3")
	end)

	it("2.1.7: diagonals fill a cell under a blocker from its neighbours", function()
		assert_true(core.load_level(H.level(FULL, { slots = { { at = { 2, 1 }, type = "concrete", hp = 1 } } })) ~= nil)
	end)

	it("2.1.8: mics only with deliver, exits cover segment bottoms", function()
		expect(H.level(FULL, { slots = { { at = { 1, 1 }, type = "mic" } } }), "2.1.8 mic pieces without a deliver goal")
		local deliver = { goals = { { type = "deliver", count = 2 } }, mic = { total = 2, on_board_max = 1, gap_moves = 2 } }
		assert_true(core.load_level(H.level(FULL, deliver)) ~= nil)
		local d2 = { goals = deliver.goals, mic = deliver.mic, exits = { { 0, 5 }, { 1, 5 }, { 2, 5 } } }
		expect(H.level(FULL, d2), "2.1.8 segment bottom is not an exit at 3,5")
		local d3 = { goals = deliver.goals, mic = deliver.mic, slots = { { at = { 2, 5 }, type = "mic" } } }
		expect(H.level(FULL, d3), "2.1.8 starting mic stands on an exit at 2,5")
		local d4 = { goals = deliver.goals, mic = deliver.mic, slots = { { at = { 2, 2 }, type = "mic" }, { at = { 3, 2 }, type = "mic" } } }
		expect(H.level(FULL, d4), "2.1.8 more starting mics")
	end)

	it("2.1.8: an exit that is also a spawner is rejected", function()
		-- (1,5) is a one-cell segment under a void: its own top and bottom
		local lvl = H.level({ "######", "######", "######", "######", "#.####", "######" }, {
			goals = { { type = "deliver", count = 1 } }, mic = { total = 1, on_board_max = 1, gap_moves = 0 },
			spawners = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 }, { 4, 0 }, { 5, 0 }, { 1, 5 } },
		})
		expect(lvl, "2.1.8 exit is also a spawner at 1,5")
	end)

	it("2.1.9: starting pieces form no match", function()
		expect(H.level({ "rrr###", "######", "######", "######", "######", "######" }), "2.1.9")
		expect(H.level({ "bb####", "bb####", "######", "######", "######", "######" }), "2.1.9")
	end)

	it("2.1.10: the start board never needs the Riff fallback for seeds 1..10", function()
		expect(H.level({ "##KKKK", "KKKKKK", "KKKKKK", "KKKKKK", "KKKKKK", "KKKKKK" }), "2.1.10 start board for seed 1")
	end)

	it("reports errors with zero-based JSON coordinates", function()
		local errs = errors_of(H.level(FULL, { overlay = { { at = { 4, 3 }, type = "wires", hp = 1 } }, slots = { { at = { 4, 3 }, type = "mic" } } }))
		assert_true(has_error(errs, "2.1.3 wires over a cell without a regular piece at 4,3"), table.concat(errs, " | "))
	end)
end)
