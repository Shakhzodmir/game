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

	it("2.1.7: board B1 has no wires: a wired cell is an ordinary donor there", function()
		-- Column 7 below the void (7,4) has no spawner: (7,5) is filled only by a
		-- diagonal move from (6,4). In B1 ("only voids remain") (6,4) is an
		-- ordinary piece, so the level is fillable; wires there must not block it.
		local cells = {}
		for y = 1, 11 do cells[y] = y == 5 and "#######." or "########" end
		local lvl = {
			id = 1, version = 1, size = { 8, 11 }, moves = 20, difficulty = "easy",
			colors = { "red", "green", "blue", "yellow" },
			goals = { { type = "collect", color = "red", count = 5 } },
			cells = cells,
			overlay = { { at = { 6, 4 }, type = "wires", hp = 1 }, { at = { 7, 5 }, type = "wires", hp = 1 } },
		}
		local loaded, errs = core.load_level(lvl)
		assert_true(loaded ~= nil, errs and table.concat(errs, " | "))
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

	it("prints large coordinates in full, not in exponent form (0.7 rule 6)", function()
		local errs = errors_of(H.level(FULL, { floor = { { at = { 123456789012345, -7 }, hp = 1 } } }))
		assert_true(has_error(errs, "2.1.2 floor is not on an existing cell at 123456789012345,-7"), table.concat(errs, " | "))
	end)

	it("reports errors with zero-based JSON coordinates", function()
		local errs = errors_of(H.level(FULL, { overlay = { { at = { 4, 3 }, type = "wires", hp = 1 } }, slots = { { at = { 4, 3 }, type = "mic" } } }))
		assert_true(has_error(errs, "2.1.3 wires over a cell without a regular piece at 4,3"), table.concat(errs, " | "))
	end)
end)

-- The canonical form (2.2) and the level hash (17.1), against an independent
-- implementation (Python: sorted keys, no spaces, null keys dropped, folded
-- over the bytes with the integer fold of 17.2).
describe("core level: canonical form and hash (2.2, 17.1)", function()
	local LS = require("core.level_schema")

	local RICH = [==[
	{ "version": 3, "id": 42, "moves": 28, "difficulty": "hard",
	  "size": [7, 8], "colors": ["purple", "red", "blue", "yellow", "orange"],
	  "goals": [ {"count": 30, "type": "collect", "color": "red"},
	             {"type": "break", "item": "record_box", "count": 2}, {"type": "light"} ],
	  "cells": ["#######", "#######", "###.###", "#######", "#######", "#######", "#######", "#######"],
	  "spawners": [[0, 0], [1, 0], [2, 0], [3, 0], [4, 0], [5, 0], [6, 0]], "exits": null,
	  "floor": [{"at": [3, 4], "hp": 2}, {"hp": 1, "at": [0, 7]}],
	  "overlay": [{"at": [2, 6], "type": "wires", "hp": 1}],
	  "slots": [{"at": [4, 4], "type": "record_box", "hp": 3}, {"at": [1, 1], "type": "record_box", "hp": 1},
	            {"at": [4, 0], "type": "riff", "axis": "h"}, {"at": [5, 1], "type": "piece", "color": "blue"},
	            {"at": [0, 6], "type": "disco"}, {"at": [6, 6], "type": "bird"}, {"at": [3, 6], "type": "sub"}],
	  "mic": null,
	  "spawn_weights": {"purple": 3, "red": 1, "blue": 1000, "yellow": 2, "orange": 7} }
	]==]
	local RICH_CANON = '{"cells":["#######","#######","###.###","#######","#######","#######","#######","#######"],'
		.. '"colors":["purple","red","blue","yellow","orange"],"difficulty":"hard",'
		.. '"floor":[{"at":[3,4],"hp":2},{"at":[0,7],"hp":1}],'
		.. '"goals":[{"color":"red","count":30,"type":"collect"},{"count":2,"item":"record_box","type":"break"},{"type":"light"}],'
		.. '"id":42,"moves":28,"overlay":[{"at":[2,6],"hp":1,"type":"wires"}],"size":[7,8],'
		.. '"slots":[{"at":[4,4],"hp":3,"type":"record_box"},{"at":[1,1],"hp":1,"type":"record_box"},'
		.. '{"at":[4,0],"axis":"h","type":"riff"},{"at":[5,1],"color":"blue","type":"piece"},'
		.. '{"at":[0,6],"type":"disco"},{"at":[6,6],"type":"bird"},{"at":[3,6],"type":"sub"}],'
		.. '"spawn_weights":{"blue":1000,"orange":7,"purple":3,"red":1,"yellow":2},'
		.. '"spawners":[[0,0],[1,0],[2,0],[3,0],[4,0],[5,0],[6,0]],"version":3}'

	local DELIVER = [==[
	{"id": 9, "version": 1, "size": [6, 6], "moves": 12, "difficulty": "easy", "colors": ["red", "green", "blue", "yellow"],
	 "goals": [{"type": "deliver", "count": 3}, {"type": "collect", "color": "green", "count": 5}],
	 "cells": ["######", "######", "######", "######", "######", "######"],
	 "exits": [[0, 5], [1, 5], [2, 5], [3, 5], [4, 5], [5, 5]],
	 "mic": {"total": 3, "on_board_max": 2, "gap_moves": 0},
	 "slots": [{"at": [2, 2], "type": "mic"}]}
	]==]
	local DELIVER_CANON = '{"cells":["######","######","######","######","######","######"],'
		.. '"colors":["red","green","blue","yellow"],"difficulty":"easy","exits":[[0,5],[1,5],[2,5],[3,5],[4,5],[5,5]],'
		.. '"goals":[{"count":3,"type":"deliver"},{"color":"green","count":5,"type":"collect"}],'
		.. '"id":9,"mic":{"gap_moves":0,"on_board_max":2,"total":3},"moves":12,"size":[6,6],'
		.. '"slots":[{"at":[2,2],"type":"mic"}],"version":1}'

	it("sorts keys by bytes, drops null keys, adds no defaults, keeps array order (pinned strings)", function()
		local lvl = assert(core.load_level(RICH))
		assert_eq(lvl.canonical, RICH_CANON)
		assert_eq(lvl.hash, 469747379)
		local d = assert(core.load_level(DELIVER))
		assert_eq(d.canonical, DELIVER_CANON)
		assert_eq(d.hash, 484183498)
	end)

	it("does not depend on key order, spacing or null keys of the source text", function()
		local a = assert(core.load_level(RICH))
		local compact = string.gsub(RICH, "%s+", " ")
		local b = assert(core.load_level(compact))
		local c = assert(core.load_level(json.decode(RICH)))
		assert_eq(b.canonical, a.canonical)
		assert_eq(c.canonical, a.canonical)
		assert_eq(c.hash, a.hash)
		-- the same level without the explicit nulls
		local plain = string.gsub(string.gsub(RICH, ',%s*"exits": null', ""), ',%s*"mic": null', "")
		assert_eq(assert(core.load_level(plain)).hash, a.hash)
	end)

	it("a changed value changes the hash; the hash is the 17.2 fold over the canonical bytes", function()
		local a = assert(core.load_level(RICH))
		local other = string.gsub(RICH, '"moves": 28', '"moves": 29')
		local b = assert(core.load_level(other))
		assert_true(a.hash ~= b.hash)
		assert_eq(a.hash, HS.fold_bytes(a.canonical))
	end)

	it("escapes only the quote and the backslash; integers go through %.0f", function()
		assert_eq(LS.canonical({ s = 'a"b\\c\td', n = 2 ^ 40, big = 1e15, z = 0 }),
			'{"big":1000000000000000,"n":1099511627776,"s":"a\\"b\\\\c\td","z":0}')
		assert_eq(LS.canonical({ floor = {}, size = { 6, 7 }, mic = { gap_moves = 0, total = 2 } }),
			'{"floor":[],"mic":{"gap_moves":0,"total":2},"size":[6,7]}')
	end)

	it("prints minus zero as 0, so decoded tables and text give one canonical form", function()
		local zero = 0
		local nz = -zero
		assert_eq(LS.canonical({ id = nz, size = { nz, 1 } }), '{"id":0,"size":[0,1]}')
		local text = string.gsub(VALID_TEXT, '"moves": 20', '"moves": 20, "spawners": [[-0, -0], [1, 0], [2, 0], [3, 0], [4, 0], [5, 0]]')
		local lvl = assert(core.load_level(text))
		assert_true(string.find(lvl.canonical, '"spawners":[[0,0],[1,0],[2,0],[3,0],[4,0],[5,0]]', 1, true) ~= nil, lvl.canonical)
	end)
end)

-- Robustness: a bad level file must come back as errors, never as a Lua error.
describe("core level: hostile input", function()
	local function rng_from(seed)
		local x = seed
		return function(n)
			x = (x * 1103515245 + 12345) % 2147483648
			return math.floor(x / 65536) % n + 1
		end
	end
	local JUNK = { 0, 1, -1, 2, 6, 7, 12, 13, 61, 1000, 1001, 1.5, 1e300, -1e300, 2 ^ 53, 2 ^ 60, 1 / 0, -1 / 0, 0 / 0,
		"", "x", "top", "bottom", "red", "riff", "wires", true, false, {}, { 1 }, { "a" }, { x = 1 }, { 1, 2 }, { 1, 2, 3 } }

	local function copy(v)
		if type(v) ~= "table" then return v end
		local t = {}
		for k, x in pairs(v) do t[k] = copy(x) end
		return t
	end

	local function containers(root)
		local list = {}
		local function walk(t)
			list[#list + 1] = t
			local keys = {}
			for k in pairs(t) do keys[#keys + 1] = k end
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			for _, k in ipairs(keys) do if type(t[k]) == "table" then walk(t[k]) end end
		end
		walk(root)
		return list
	end

	it("structurally mutated tables never raise: the answer is a level or a list of strings", function()
		local rnd = rng_from(2026)
		local base = H.level({ "######", "#r####", "##X###", "######", "####R#", "######" }, {
			floor = { { at = { 0, 5 }, hp = 1 } }, overlay = { { at = { 3, 3 }, type = "wires", hp = 1 } },
			goals = { { type = "collect", color = "red", count = 3 }, { type = "break", item = "record_box", count = 1 }, { type = "light" } },
			spawn_weights = { red = 1, orange = 2, yellow = 3, green = 4, blue = 5, purple = 6 },
		})
		assert_true(core.load_level(copy(base)) ~= nil, "the base level must be valid")
		local rejected = 0
		for _ = 1, 500 do
			local lvl = copy(base)
			for _ = 1, rnd(3) do
				local nodes = containers(lvl)
				local t = nodes[rnd(#nodes)]
				local keys = {}
				for k in pairs(t) do keys[#keys + 1] = k end
				table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
				if #keys > 0 then
					local k = keys[rnd(#keys)]
					local op = rnd(4)
					if op == 1 then t[k] = nil
					elseif op == 2 then t[k] = copy(JUNK[rnd(#JUNK)])
					elseif op == 3 then t["extra"] = 1
					else t[k] = copy(t[keys[rnd(#keys)]]) end
				end
			end
			local ok, res, errs = pcall(core.load_level, lvl)
			assert_true(ok, "raised: " .. tostring(res))
			if res == nil then
				rejected = rejected + 1
				assert_eq(type(errs), "table")
				assert_true(#errs >= 1)
				for _, e in ipairs(errs) do
					assert_eq(type(e), "string")
					assert_true(string.find(e, "^2%.%d") ~= nil, "an error starts with its rule: " .. e)
				end
			else
				assert_true(res.hash ~= nil and res.canonical ~= nil)
			end
		end
		assert_true(rejected > 100, "the mutations must actually break levels")
	end)

	it("mutated JSON text never raises either", function()
		local rnd = rng_from(77)
		local text = VALID_TEXT
		local pieces = { "{", "}", "[", "]", ",", ":", '"', "-", "0", "9", ".", "e", "null", "true", " ", "\\" }
		for _ = 1, 600 do
			local t = text
			for _ = 1, rnd(3) do
				local pos = rnd(#t)
				local op = rnd(3)
				if op == 1 then t = string.sub(t, 1, pos - 1) .. string.sub(t, pos + 1)
				elseif op == 2 then t = string.sub(t, 1, pos - 1) .. pieces[rnd(#pieces)] .. string.sub(t, pos)
				else t = string.sub(t, 1, pos - 1) .. pieces[rnd(#pieces)] .. string.sub(t, pos + 1) end
			end
			local ok, res, errs = pcall(core.load_level, t)
			assert_true(ok, "raised: " .. tostring(res))
			if res == nil then
				assert_eq(type(errs), "table")
				assert_eq(type(errs[1]), "string")
			end
		end
	end)

	it("things that are not levels are refused with a message", function()
		for _, v in ipairs({ 5, true, {}, { 1, 2 }, "[]", "5", '"x"', "null", "" }) do
			local lvl, errs = core.load_level(v)
			assert_eq(lvl, nil, tostring(v))
			assert_eq(type(errs[1]), "string")
		end
		local lvl, errs = core.load_level(nil)
		assert_eq(lvl, nil)
		assert_true(string.find(errs[1], "2.2", 1, true) ~= nil)
	end)
end)

-- Every range of 2.0 is inclusive at both ends, and each goal, list entry and row is checked (audit A).
describe("core level: ranges and entries of the schema", function()
	local function rect(W, Hh)
		local rows = {}
		for y = 1, Hh do rows[y] = string.rep("#", W) end
		return rows
	end
	local function loads(rows, extra)
		return core.load_level(H.level(rows, extra)) ~= nil
	end
	local function check(rows, extra, want, label)
		local lvl, errs = core.load_level(H.level(rows, extra))
		assert_eq(lvl ~= nil, want, label .. (errs and (": " .. table.concat(errs, " | ")) or ""))
	end

	it("size 6..9 x 6..11", function()
		for _, c in ipairs({ { 5, 6, false }, { 6, 5, false }, { 6, 6, true }, { 9, 11, true }, { 10, 6, false }, { 9, 12, false },
			{ 6, 11, true }, { 9, 6, true }, { 7, 8, true } }) do
			check(rect(c[1], c[2]), nil, c[3], c[1] .. "x" .. c[2])
		end
	end)

	it("id, version >= 1, moves 5..60", function()
		check(FULL, { id = 0 }, false, "id 0")
		check(FULL, { id = 1 }, true, "id 1")
		check(FULL, { id = 999999999999999 }, true, "id of 15 digits")
		check(FULL, { version = 0 }, false, "version 0")
		check(FULL, { version = 1 }, true, "version 1")
		check(FULL, { moves = 4 }, false, "moves 4")
		check(FULL, { moves = 5 }, true, "moves 5")
		check(FULL, { moves = 60 }, true, "moves 60")
		check(FULL, { moves = 61 }, false, "moves 61")
		check(FULL, { moves = 5.5 }, false, "moves 5.5")
	end)

	it("4..6 different colours", function()
		local six = { "red", "orange", "yellow", "green", "blue", "purple" }
		check(FULL, { colors = { "red", "green", "blue" } }, false, "3 colours")
		check(FULL, { colors = { "red", "green", "blue", "yellow" } }, true, "4 colours")
		check(FULL, { colors = six }, true, "6 colours")
		check(FULL, { colors = { "red", "green", "blue", "yellow", "orange", "purple", "red" } }, false, "7 entries")
		check(FULL, { colors = { "red", "green", "blue", "gold" } }, false, "unknown colour")
	end)

	it("1..3 goals, a count of at least 1, one goal per (type, colour or item)", function()
		local box = { { at = { 0, 0 }, type = "record_box", hp = 1 }, { at = { 2, 0 }, type = "record_box", hp = 1 } }
		local noise = { { at = { 4, 4 }, type = "noise" } }
		check(FULL, { goals = {} }, false, "no goal")
		check(FULL, { goals = { { type = "collect", color = "red", count = 0 } } }, false, "collect 0")
		check(FULL, { goals = { { type = "collect", color = "red", count = 1 } } }, true, "collect 1")
		check(FULL, { goals = { { type = "break", item = "record_box", count = 0 } }, slots = box }, false, "break 0")
		check(FULL, { goals = { { type = "break", item = "record_box", count = 2 } }, slots = box }, true, "break 2")
		check(FULL, { goals = { { type = "break", item = "record_box", count = 3 } }, slots = box }, false, "break 3 of 2")
		check(FULL, { goals = { { type = "deliver", count = 0 } }, mic = { total = 0, on_board_max = 1, gap_moves = 0 } }, false, "deliver 0")
		-- two collect goals of different colours, collect and break, two breaks of different items
		check(FULL, { goals = { { type = "collect", color = "red", count = 3 }, { type = "collect", color = "green", count = 3 } } }, true, "two collects")
		check(FULL, { goals = { { type = "collect", color = "red", count = 3 }, { type = "collect", color = "green", count = 3 },
			{ type = "collect", color = "blue", count = 3 } } }, true, "three collects")
		check(FULL, { goals = { { type = "collect", color = "red", count = 3 }, { type = "collect", color = "green", count = 3 },
			{ type = "collect", color = "blue", count = 3 }, { type = "collect", color = "yellow", count = 3 } } }, false, "four goals")
		check(FULL, { goals = { { type = "collect", color = "red", count = 3 }, { type = "break", item = "record_box", count = 1 } }, slots = box }, true, "collect and break")
		check(FULL, { goals = { { type = "break", item = "noise", count = 1 }, { type = "break", item = "record_box", count = 1 } },
			slots = { box[1], noise[1] } }, true, "two breaks of different items")
		check(FULL, { goals = { { type = "break", item = "noise", count = 1 }, { type = "break", item = "noise", count = 1 } },
			slots = noise }, false, "the same break twice")
		check(FULL, { goals = { { type = "collect", color = "red", count = 3 }, { type = "collect", color = "red", count = 2 } } }, false, "the same collect twice")
		check(FULL, { goals = { { type = "light" }, { type = "light" } }, floor = { { at = { 0, 0 }, hp = 1 } } }, false, "light twice")
	end)

	it("element hp: record_box 1..3, concrete 1..2, column 6..12, floor and wires 1..2", function()
		for hp = 0, 4 do
			check(FULL, { slots = { { at = { 1, 1 }, type = "record_box", hp = hp } } }, hp >= 1 and hp <= 3, "record_box " .. hp)
		end
		for hp = 0, 3 do
			check(FULL, { slots = { { at = { 1, 1 }, type = "concrete", hp = hp } } }, hp >= 1 and hp <= 2, "concrete " .. hp)
		end
		for _, hp in ipairs({ 5, 6, 12, 13 }) do
			check(FULL, { slots = { { at = { 1, 1 }, type = "column", hp = hp } } }, hp >= 6 and hp <= 12, "column " .. hp)
		end
		for hp = 0, 3 do
			check(FULL, { floor = { { at = { 1, 1 }, hp = hp } } }, hp >= 1 and hp <= 2, "floor " .. hp)
			check(FULL, { overlay = { { at = { 1, 1 }, type = "wires", hp = hp } } }, hp >= 1 and hp <= 2, "wires " .. hp)
		end
	end)

	it("the mic block: total >= 1, on_board_max >= 1, gap_moves >= 0, total = the deliver count", function()
		local function mic(total, max, gap, count)
			return { goals = { { type = "deliver", count = count or total } }, mic = { total = total, on_board_max = max, gap_moves = gap } }
		end
		check(FULL, mic(0, 1, 0), false, "total 0")
		check(FULL, mic(1, 1, 0), true, "1, 1, 0")
		check(FULL, mic(1, 0, 0), false, "on_board_max 0")
		check(FULL, mic(1, 1, -1), false, "gap_moves -1")
		check(FULL, mic(3, 5, 9), true, "3, 5, 9")
		check(FULL, mic(2, 1, 0, 3), false, "total <> deliver count")
		local m = mic(2, 1, 0)
		m.mic.total = 2.5
		check(FULL, m, false, "fractional total")
		m = mic(2, 1, 0)
		m.mic.on_board_max = "1"
		check(FULL, m, false, "text on_board_max")
		m = mic(2, 1, 0)
		m.mic.gap_moves = true
		check(FULL, m, false, "boolean gap_moves")
	end)

	it("spawn_weights 1..1000 for every colour of the level", function()
		local colors = { "red", "green", "blue", "yellow" }
		local function w(a, b, c, d) return { red = a, green = b, blue = c, yellow = d } end
		check(FULL, { colors = colors, spawn_weights = w(1, 1, 1, 1) }, true, "all 1")
		check(FULL, { colors = colors, spawn_weights = w(1000, 1000, 1000, 1000) }, true, "all 1000")
		check(FULL, { colors = colors, spawn_weights = w(0, 1, 1, 1) }, false, "a zero")
		check(FULL, { colors = colors, spawn_weights = w(1, 1, 1, 1001) }, false, "1001")
		check(FULL, { colors = colors, spawn_weights = w(1, 1, 1.5, 1) }, false, "a fraction")
		check(FULL, { colors = colors, spawn_weights = { red = 1, green = 1, blue = 1, yellow = 1, purple = 1 } }, false, "a colour not in the level")
		check(FULL, { colors = colors, spawn_weights = { red = 1, green = 1, blue = 1 } }, false, "a colour missing")
		check(FULL, { colors = colors, spawn_weights = { 1, 1, 1, 1 } }, false, "a list")
	end)

	it("spawners and exits: the words, and every entry of a list is looked at", function()
		check(FULL, { spawners = "top" }, true, "top")
		check(FULL, { spawners = "bottom" }, false, "spawners 'bottom'")
		check(FULL, { exits = "top" }, false, "exits 'top'")
		check(FULL, { exits = "bottom" }, true, "exits 'bottom'")
		check(FULL, { spawners = 5 }, false, "spawners 5")
		local all = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 }, { 4, 0 }, { 5, 0 } }
		check(FULL, { spawners = all }, true, "all columns")
		local bad_first = { { 1 }, { 1, 0 }, { 2, 0 }, { 3, 0 }, { 4, 0 }, { 5, 0 } }
		check(FULL, { spawners = bad_first }, false, "a bad first entry")
		local bad_last = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 }, { 4, 0 }, { 5, "0" } }
		check(FULL, { spawners = bad_last }, false, "a bad last entry")
		local deliver = { goals = { { type = "deliver", count = 1 } }, mic = { total = 1, on_board_max = 1, gap_moves = 0 } }
		local exits_bad = { goals = deliver.goals, mic = deliver.mic, exits = { { 0, 5 }, { 1, 5 }, { 2, 5 }, { 3, 5 }, { 4, 5 }, { 5, 5.5 } } }
		check(FULL, exits_bad, false, "a bad exit entry")
	end)

	it("cells: H rows of W characters '#' or '.', each row looked at", function()
		local function cells_of(edit)
			local rows = { "######", "######", "######", "######", "######", "######" }
			edit(rows)
			return rows
		end
		check(FULL, nil, true, "plain")
		check(FULL, { cells = cells_of(function(r) r[1] = "#####" end) }, false, "a short first row")
		check(FULL, { cells = cells_of(function(r) r[6] = "#####x" end) }, false, "a bad character in the last row")
		check(FULL, { cells = cells_of(function(r) r[3] = "#######" end) }, false, "a long row")
		check(FULL, { cells = cells_of(function(r) r[4] = 7 end) }, false, "a row that is no string")
		check(FULL, { cells = cells_of(function(r) r[2] = "#.##.#" end) }, true, "voids inside the board are fine when the fill reaches every cell")
		check(FULL, { cells = { "######" } }, false, "one row")
		check(FULL, { cells = { "######", "######", "######", "######", "######", "######", "######" } }, false, "seven rows")
	end)
end)
