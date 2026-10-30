-- The start board of section 4 against an oracle written from the text of the
-- specification (tests/core/oracle_a.lua): the fills, the checks, the start shuffle,
-- the ids, the pre-level boosters and the counters, on random levels. Audit A.

local core = require("core.game")
local C = require("core.const")
local ST = require("core.start")
local O = require("tests.core.oracle_a")

local lcg, copy = O.lcg, O.copy

local function compare(label, lvl, raw, seed, names)
	local items = {}
	for k, name in ipairs(names) do items[k] = C.PRE_BOOSTER[name] end
	local s, report = ST.build(lvl, seed, items)
	local want = O.start(raw, seed, names)
	label = label .. " seed " .. seed .. " boosters {" .. table.concat(names, ",") .. "}"
	for i = 1, s.N do
		local got
		if s.slot[i] ~= 0 then
			local o = s.objs[s.slot[i]]
			got = { o.kind, o.color, o.special, o.axis, o.blocker, o.hp, o.id }
		end
		local w = want.cells[i]
		assert_same(got or { "empty" }, w or { "empty" }, label .. " cell " .. i)
		if got then
			local o = s.objs[s.slot[i]]
			assert_same({ o.state, o.mv, o.wv, o.settle }, { C.S_IDLE, 0, 0, 0 }, label .. " cell " .. i .. " state")
		end
	end
	assert_same(s.rng[1], want.rng, label .. ": the init stream after the start")
	assert_same({ report.fills, report.shuffle, report.dirty }, { want.fills, want.shuffle, want.dirty }, label)
	assert_same(s.unplaced, want.unplaced, label .. ": unplaced")
	assert_same({ s.rest_flag, s.dirty }, { want.rest, want.dirty }, label .. ": rest_flag")
	assert_eq(s.next_piece_id, want.next_id, label .. ": next_piece_id")
	assert_same({ s.released, s.on_board }, { want.released, want.on_board }, label .. ": mic counters")
	if raw.mic then assert_eq(s.last_mic, want.last_mic, label .. ": last_mic") end
	return report
end

local BOOSTERS = { {}, { "riff" }, { "sub", "riff" }, { "riff", "riff", "disco" } }

describe("core start oracle: section 4 on random levels (audit A)", function()
	it("matches the oracle on 45 valid random levels, three seeds and boosters each", function()
		local rnd = lcg(2026)
		local compared = 0
		for n = 1, 400 do
			local raw = O.random_level(rnd)
			local lvl = core.load_level(copy(raw))
			if lvl then
				compared = compared + 1
				for k = 1, 3 do
					compare("level " .. n, lvl, raw, rnd(100000), BOOSTERS[rnd(#BOOSTERS)])
				end
			end
			if compared >= 45 then break end
		end
		assert_true(compared >= 40, "valid levels compared: " .. compared)
	end)

	it("matches the oracle where the start fills fail, shuffle and keep the fixed pieces (dense levels)", function()
		local rnd = lcg(99)
		local compared, many_fills, shuffled, unplaced = 0, 0, 0, 0
		for n = 1, 600 do
			local raw = O.dense_level(rnd)
			local lvl = core.load_level(copy(raw))
			if lvl then
				compared = compared + 1
				for k = 1, 3 do
					local report = compare("dense " .. n, lvl, raw, k * 7 + n, BOOSTERS[rnd(#BOOSTERS)])
					if report.fills > 1 then many_fills = many_fills + 1 end
					if report.shuffle > 0 then shuffled = shuffled + 1 end
				end
			end
			if compared >= 35 then break end
		end
		assert_true(compared >= 30, "dense levels compared: " .. compared)
		assert_true(many_fills >= 5, "boards that needed more than one fill: " .. many_fills)
	end)

	-- The start shuffle and its fallbacks only run on boards that rule 2.1.10 would refuse for the seeds
	-- 1..10, so these levels are normalized by hand from a plain valid level of the same size.
	local function forced(raw)
		local base = assert(core.load_level({
			id = 1, version = 1, size = raw.size, moves = 20, difficulty = "easy", colors = raw.colors,
			spawn_weights = raw.spawn_weights, goals = { { type = "collect", color = raw.colors[1], count = 5 } }, cells = raw.cells,
		}))
		local lvl = copy(base)
		lvl.goals = { { type = C.GOAL_COLLECT, param = C.COLOR[raw.goals[1].color], count = 5 } }
		lvl.presets = {}
		local W = lvl.W
		for _, s in ipairs(raw.slots or {}) do
			local cell = s.at[2] * W + s.at[1] + 1
			local p = { cell = cell, kind = 0, color = 0, special = 0, axis = 0, blocker = 0, hp = 0 }
			if s.type == "piece" then p.kind, p.color = C.K_REGULAR, C.COLOR[s.color]
			elseif C.SPECIAL[s.type] then
				p.kind, p.special = C.K_SPECIAL, C.SPECIAL[s.type]
				if s.type == "riff" then p.axis = C.AXIS[s.axis] end
			else
				p.kind, p.blocker, p.hp = C.K_BLOCKER, C.BLOCKER[s.type], s.hp
			end
			lvl.presets[#lvl.presets + 1] = p
		end
		table.sort(lvl.presets, function(a, b) return a.cell < b.cell end)
		for _, o in ipairs(raw.overlay or {}) do lvl.wires[o.at[2] * W + o.at[1] + 1] = o.hp end
		return lvl
	end

	-- A board almost filled with walls: a handful of free cells and pieces, so that fills fail and shuffles run.
	local function walled(rnd)
		local W, H = 6, 6
		local cells = {}
		for y = 1, H do cells[y] = string.rep("#", W) end
		local cols = { "red", "yellow", "green", "blue" }
		local slots, overlay = {}, {}
		local wall = ({ 88, 93, 97, 100 })[rnd(4)]
		for y = 1, H do
			for x = 1, W do
				local at = { x - 1, y - 1 }
				local r = rnd(100)
				if r <= wall then
					local k = rnd(6)
					if k <= 3 then slots[#slots + 1] = { at = at, type = "concrete", hp = 1 }
					elseif k == 4 then slots[#slots + 1] = { at = at, type = "record_box", hp = 2 }
					elseif k == 5 then
						slots[#slots + 1] = { at = at, type = "piece", color = cols[rnd(#cols)] }
						overlay[#overlay + 1] = { at = at, type = "wires", hp = 1 }
					else slots[#slots + 1] = { at = at, type = "piece", color = cols[rnd(#cols)] } end
				end
			end
		end
		return {
			id = 1, version = 1, size = { W, H }, moves = 20, difficulty = "easy", colors = cols,
			goals = { { type = "collect", color = "green", count = 5 } }, cells = cells, slots = slots, overlay = overlay,
		}
	end

	it("matches the oracle through the start shuffle: permutation, recolour, the Riff fallback, a dirty start", function()
		local rnd = lcg(404)
		local dist = {}
		for n = 1, 90 do
			local raw = (n % 2 == 0) and walled(rnd) or O.dense_level(rnd, { 70, 85, 92, 97 })
			local lvl = forced(raw)
			for k = 1, 3 do
				local report = compare("forced " .. n, lvl, raw, rnd(100000), BOOSTERS[rnd(#BOOSTERS)])
				local key = "shuffle" .. report.shuffle
				dist[key] = (dist[key] or 0) + 1
				if report.dirty then dist.dirty = (dist.dirty or 0) + 1 end
			end
		end
		assert_true((dist.shuffle1 or 0) >= 10, "permutations: " .. tostring(dist.shuffle1))
		assert_true((dist.shuffle2 or 0) >= 2, "recolours: " .. tostring(dist.shuffle2))
		assert_true((dist.shuffle3 or 0) >= 5, "Riff fallbacks: " .. tostring(dist.shuffle3))
	end)
end)
