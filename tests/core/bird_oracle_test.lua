-- Section 9 (the Bird's targets) against an independent oracle.
--
-- The oracle below is written from the text of the specification, not from
-- core/bird.lua: the level of every cell (the table of rows 5..0 with the
-- pinned, open-slot and column notes), the candidates (cells hit by the
-- source or reserved by a flying Bird are out), the density, the single
-- strike and the cargo tuples (A, B, C, D) with the Riff axis. Random
-- boards mix every kind of content, state, goal, wires, tiles and pins;
-- the core's choices must equal the oracle's, with exactly one draw of the
-- `effects` stream when there is a candidate and none otherwise.

local C = require("core.const")
local B = require("core.board")
local BD = require("core.bird")
local R = require("core.rng")
local HT = require("core.hits")
local U = require("core.util")
local H = require("tests.core.helper")

local K_REG, K_SPE, K_MIC, K_BLK = C.K_REGULAR, C.K_SPECIAL, C.K_MIC, C.K_BLOCKER
local IDLE = C.S_IDLE

-- Park-Miller "minimal standard" generator: x * 16807 stays below 2^46, so the
-- boards are the same on every VM and platform.
local function lcg(seed)
	local x = seed % 2147483647
	if x == 0 then x = 1 end
	return function(n)
		x = (x * 16807) % 2147483647
		return x % n + 1
	end
end

local function obj_at(s, i)
	local id = s.slot[i]
	if id == 0 then return nil end
	return s.objs[id]
end

-- Open goals: break (by blocker code), collect (by colour code), light, deliver.
local function open_goals(s)
	local brk, col, light, deliver = {}, {}, false, false
	for k, g in ipairs(s.level.goals) do
		if s.goal_left[k] > 0 then
			if g.type == C.GOAL_BREAK then brk[g.param] = true
			elseif g.type == C.GOAL_COLLECT then col[g.param] = true
			elseif g.type == C.GOAL_LIGHT then light = true
			elseif g.type == C.GOAL_DELIVER then deliver = true end
		end
	end
	return brk, col, light, deliver
end

-- The level of every cell (section 9).
local function oracle_levels(s)
	local brk, col, light, deliver = open_goals(s)
	local W = s.W
	local out = {}
	for i = 1, s.N do
		local lvl = 0
		if s.exists[i] then
			local o = obj_at(s, i)
			local idle = o ~= nil and o.state == IDLE
			local open = not idle
			local wired = s.wires[i] > 0
			local done = false
			-- a pinned piece zeroes the whole cell
			if idle and #o.pins > 0 then done = true end
			-- a column counts at its top-left cell only, never through its tiles
			if not done and idle and o.kind == K_BLK and o.blocker == C.BK_COLUMN then
				if o.cell == i then lvl = brk[C.BK_COLUMN] and 4 or 2 end
				done = true
			end
			if not done then
				local function bump(l) if l > lvl then lvl = l end end
				if idle then
					if o.kind == K_BLK then
						if o.blocker == C.BK_CONCRETE and brk[C.BK_CONCRETE] then bump(5)
						elseif brk[o.blocker] then bump(4)
						else bump(2) end
					elseif o.kind == K_REG then
						if wired then bump(2)
						elseif col[o.color] then bump(4)
						else bump(1) end
					elseif o.kind == K_SPE then
						bump(2)
					end
				end
				-- an unlit tile that the hit will damage
				if light and s.floor[i] > 0 and not wired then
					local dmg = open
					if idle and o.kind == K_REG then dmg = true end
					if idle and o.kind == K_BLK and o.blocker ~= C.BK_COLUMN and o.hp == 1 then dmg = true end
					if dmg then bump(4) end
				end
				-- the cell right under an idle mic, if the hit frees it
				if deliver and i > W and idle then
					local m = obj_at(s, i - W)
					if m and m.kind == K_MIC and m.state == IDLE then
						local frees = false
						if o.kind == K_REG and not wired then frees = true end
						if o.kind == K_BLK and o.blocker ~= C.BK_COLUMN and o.hp == 1 then frees = true end
						if frees then bump(3) end
					end
				end
			end
		end
		out[i] = lvl
	end
	return out
end

-- Object key of a cell: a column is keyed by its top-left cell.
local function key_of(s, i)
	local o = obj_at(s, i)
	if o and o.blocker == C.BK_COLUMN then return o.cell end
	return i
end

local function oracle_candidates(s, lv, hit_keys, reserved_keys)
	local out = {}
	for i = 1, s.N do
		if s.exists[i] and lv[i] >= 1 then
			local k = key_of(s, i)
			if not hit_keys[k] and not reserved_keys[k] then out[#out + 1] = i end
		end
	end
	return out
end

-- Existing cells with a level of at least 3 in the 3x3 square around i (i included).
local function density(s, lv, i)
	local W, Hh = s.W, s.H
	local x = (i - 1) % W + 1
	local y = (i - x) / W + 1
	local n = 0
	for yy = y - 1, y + 1 do
		for xx = x - 1, x + 1 do
			if xx >= 1 and xx <= W and yy >= 1 and yy <= Hh then
				local j = (yy - 1) * W + xx
				if s.exists[j] and lv[j] >= 3 then n = n + 1 end
			end
		end
	end
	return n
end

local function oracle_single(s, lv, cands)
	local best, bl, bd = {}, -1, -1
	for _, i in ipairs(cands) do
		local l, d = lv[i], density(s, lv, i)
		if l > bl or (l == bl and d > bd) then
			best, bl, bd = { i }, l, d
		elseif l == bl and d == bd then
			best[#best + 1] = i
		end
	end
	return best
end

-- Existing cells of the cargo area around i: "sub" = 5x5, "h" = the row, "v" = the column.
local function area_cells(s, i, kind)
	local W, Hh = s.W, s.H
	local x = (i - 1) % W + 1
	local y = (i - x) / W + 1
	local out = {}
	for yy = 1, Hh do
		for xx = 1, W do
			local inside
			if kind == "sub" then inside = math.abs(xx - x) <= 2 and math.abs(yy - y) <= 2
			elseif kind == "h" then inside = yy == y
			else inside = xx == x end
			local j = (yy - 1) * W + xx
			if inside and s.exists[j] then out[#out + 1] = j end
		end
	end
	return out
end

-- (A, B, C, D): objects of the area with level 4-5, 3, 2 and 1; a whole
-- column counts once, with the level of its top-left cell.
local function tuple_of(s, lv, cells)
	local seen, t = {}, { 0, 0, 0, 0 }
	for _, j in ipairs(cells) do
		local o = obj_at(s, j)
		local key = j
		if o and o.blocker == C.BK_COLUMN and o.state == IDLE then key = o.cell end
		if not seen[key] then
			seen[key] = true
			local l = lv[key]
			if l >= 4 then t[1] = t[1] + 1
			elseif l == 3 then t[2] = t[2] + 1
			elseif l == 2 then t[3] = t[3] + 1
			elseif l == 1 then t[4] = t[4] + 1 end
		end
	end
	return t
end

local function tuple_cmp(a, b)
	for k = 1, 4 do
		if a[k] ~= b[k] then return a[k] > b[k] and 1 or -1 end
	end
	return 0
end

-- Best candidates of a cargo: list of {cell, axis} (axis 0 for the Sabwoofer).
local function oracle_cargo(s, lv, cands, cargo)
	local best, bt = {}, nil
	for _, i in ipairs(cands) do
		local t, axis
		if cargo == "sub" then
			t, axis = tuple_of(s, lv, area_cells(s, i, "sub")), 0
		else
			local th = tuple_of(s, lv, area_cells(s, i, "h"))
			local tv = tuple_of(s, lv, area_cells(s, i, "v"))
			if tuple_cmp(tv, th) > 0 then t, axis = tv, C.AX_V else t, axis = th, C.AX_H end
		end
		local c = bt and tuple_cmp(t, bt) or 1
		if c > 0 then
			best, bt = { { i, axis } }, t
		elseif c == 0 then
			best[#best + 1] = { i, axis }
		end
	end
	return best
end

-- Random boards ---------------------------------------------------------------

local BASE = { "r", "o", "y", "g", "b", "p" }
local bases = {}

local function base_game(W, Hh)
	local key = W .. "x" .. Hh
	if not bases[key] then bases[key] = H.game(H.full(W, Hh)) end
	return bases[key]:clone()
end

-- `sparse`: a board of empty slots and mics only (no cell has a level).
local function random_game(rnd, sparse)
	local W, Hh = 6 + rnd(2) - 1, 6 + rnd(2) - 1
	local g = base_game(W, Hh)
	local s = g.s
	local picture = {}
	for y = 1, Hh do
		local line = {}
		for x = 1, W do
			local r = rnd(100)
			local ch
			if r <= 45 then ch = BASE[rnd(6)]
			elseif r <= 52 then ch = "R"
			elseif r <= 56 then ch = "S"
			elseif r <= 59 then ch = "B"
			elseif r <= 61 then ch = "D"
			elseif r <= 66 then ch = "M"
			elseif r <= 71 then ch = "X"
			elseif r <= 75 then ch = "K"
			elseif r <= 79 then ch = "N"
			elseif r <= 83 then ch = "A"
			elseif r <= 86 then ch = "E"
			elseif r <= 92 then ch = "_"
			else ch = BASE[rnd(6)] end
			if sparse then ch = rnd(10) == 1 and "M" or "_" end
			line[x] = ch
		end
		picture[y] = line
	end
	for _ = 1, sparse and 0 or rnd(3) - 1 do
		local x, y = rnd(W - 1), rnd(Hh - 1)
		picture[y][x], picture[y][x + 1], picture[y + 1][x], picture[y + 1][x + 1] = "L", "l", "l", "l"
	end
	local rows = {}
	for y = 1, Hh do rows[y] = table.concat(picture[y]) end
	H.board(g, rows)
	for i = 1, s.N do
		local o = obj_at(s, i)
		if o and o.cell == i then
			if o.kind == K_BLK and (o.blocker == C.BK_BOX or o.blocker == C.BK_CONCRETE) then o.hp = rnd(3) end
			if o.kind == K_BLK and o.blocker == C.BK_COLUMN then o.hp = 5 + rnd(3) end
			if o.kind == K_REG and rnd(10) == 1 then s.wires[i] = rnd(2) end
		end
		s.floor[i] = rnd(5) == 1 and rnd(2) or 0
	end
	-- odd states and pins
	for i = 1, s.N do
		local o = obj_at(s, i)
		if o and o.cell == i then
			local r = rnd(100)
			if r <= 4 then B.set_state(o, C.S_FALL); o.offy = 100
			elseif r <= 7 then B.set_state(o, C.S_CLEAR)
			elseif r <= 9 and o.kind == K_SPE then B.set_state(o, C.S_ARMED)
			elseif r <= 12 and B.is_movable(s, o) then B.pin(o, 99)
			elseif r <= 14 then B.set_state(o, C.S_SWAP) end
		end
	end
	-- goals: 1-3 of collect / break / light / deliver, some already done
	local pool = {}
	for c = 1, 6 do pool[#pool + 1] = { C.GOAL_COLLECT, c } end
	for b = 1, 5 do pool[#pool + 1] = { C.GOAL_BREAK, b } end
	pool[#pool + 1] = { C.GOAL_LIGHT, 0 }
	pool[#pool + 1] = { C.GOAL_DELIVER, 0 }
	local goals, used = {}, {}
	for _ = 1, rnd(3) do
		local k = rnd(#pool)
		if not used[k] then
			used[k] = true
			goals[#goals + 1] = { type = pool[k][1], param = pool[k][2], count = 5 }
		end
	end
	local lvl = {}
	for k, v in pairs(s.level) do lvl[k] = v end
	lvl.goals = goals
	s.level = lvl
	s.goal_left = {}
	for k = 1, #goals do s.goal_left[k] = rnd(5) == 1 and 0 or 5 end
	return g
end

local function stream_copy(st)
	return { st[1], st[2], st[3], st[4], st[5], st[6] }
end

local function same_stream(a, b)
	for k = 1, 6 do
		if a[k] ~= b[k] then return false end
	end
	return true
end

describe("core bird: section 9 against an independent oracle", function()
	it("levels, candidates, single strike and cargo choices equal the oracle on random boards", function()
		local stats = { boards = 0, ties = 0, cargo_ties = 0, none = 0, tiles = 0 }
		for gno = 1, 400 do
			local rnd = lcg(gno * 104729)
			local g = random_game(rnd, gno % 10 == 0)
			local s = g.s
			local what = "board " .. gno
			stats.boards = stats.boards + 1
			local lv_o, lv_c = oracle_levels(s), BD.levels(s)
			for i = 1, s.N do
				assert_eq(lv_c[i], lv_o[i], what .. ": level of cell " .. i)
				if s.floor[i] > 0 then stats.tiles = stats.tiles + 1 end
			end
			-- a source that has hit some cells and Birds in flight that hold others
			local src = HT.new_source(s, C.SRC_EFFECT, 1, 1, 0)
			local hit_keys, reserved_keys = {}, {}
			for _ = 1, rnd(6) - 1 do
				local k = key_of(s, rnd(s.N))
				hit_keys[k] = true
				U.sorted_add(src.keys, k)
			end
			local other = HT.new_source(s, C.SRC_EFFECT, 1, 1, 0)
			for _ = 1, rnd(4) - 1 do
				local k = key_of(s, rnd(s.N))
				reserved_keys[k] = true
				U.sorted_add(other.reserves, k)
			end
			local cands_o = oracle_candidates(s, lv_o, hit_keys, reserved_keys)
			assert_same(BD.candidates(s, src, lv_c), cands_o, what .. ": candidates")
			-- single strike: one draw among the equal best, or no draw at all
			local rng = s.rng[R.EFFECTS]
			local before = stream_copy(rng)
			local best = oracle_single(s, lv_o, cands_o)
			local pick = BD.pick_single(s, src)
			if #best == 0 then
				stats.none = stats.none + 1
				assert_eq(pick, 0, what .. ": no target")
				assert_true(same_stream(before, rng), what .. ": no draw without a target")
			else
				if #best > 1 then stats.ties = stats.ties + 1 end
				local copy = stream_copy(before)
				assert_eq(pick, best[R.int(copy, #best)], what .. ": single strike")
				assert_true(same_stream(copy, rng), what .. ": exactly one draw")
			end
			-- cargo: the Sabwoofer and the Riff (the stream is rewound for each)
			for _, cargo in ipairs({ "sub", "riff" }) do
				for k = 1, 6 do rng[k] = before[k] end
				local bestc = oracle_cargo(s, lv_o, cands_o, cargo)
				local cell, axis = BD.pick_cargo(s, src, cargo == "sub" and BD.CARGO_SUB or BD.CARGO_RIFF)
				if #bestc == 0 then
					assert_same({ cell, axis }, { 0, 0 }, what .. ": no cargo target")
					assert_true(same_stream(before, rng), what .. ": no draw without a cargo target")
				else
					if #bestc > 1 then stats.cargo_ties = stats.cargo_ties + 1 end
					local copy = stream_copy(before)
					local want = bestc[R.int(copy, #bestc)]
					assert_same({ cell, axis }, want, what .. ": " .. cargo .. " cargo")
					assert_true(same_stream(copy, rng), what .. ": exactly one draw")
				end
			end
		end
		-- the generator keeps hitting the interesting cases
		assert_true(stats.ties >= 5, "single-strike ties: " .. stats.ties)
		assert_true(stats.cargo_ties >= 5, "cargo ties: " .. stats.cargo_ties)
		assert_true(stats.none >= 1, "boards without a target: " .. stats.none)
		assert_true(stats.tiles >= 100, "cells with tiles: " .. stats.tiles)
	end)
end)
