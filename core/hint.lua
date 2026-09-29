-- Hint (12.3): a pure ranking of moves() and taps.

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local M = require("core.match")
local MV = require("core.moves")

local HI = {}

local K_REGULAR, K_SPECIAL, K_MIC = C.K_REGULAR, C.K_SPECIAL, C.K_MIC

-- Combo ranks of tier 4 by (smaller special code, larger code); 10 is best.
local COMBO_RANK = {}
do
	local order = {
		{ 4, 4 }, { 2, 4 }, { 1, 4 }, { 3, 4 }, { 2, 2 }, { 1, 2 }, { 2, 3 }, { 1, 3 }, { 1, 1 }, { 3, 3 },
	}
	for k = 1, #order do
		COMBO_RANK[order[k][1] * 10 + order[k][2]] = 11 - k
	end
end

-- Special ranks: tier 3 (disco > sub > riff > bird) and tier 2 (sub > riff > bird > disco).
local RANK3 = { [C.SP_DISCO] = 4, [C.SP_SUB] = 3, [C.SP_RIFF] = 2, [C.SP_BIRD] = 1 }
local RANK2 = { [C.SP_SUB] = 4, [C.SP_RIFF] = 3, [C.SP_BIRD] = 2, [C.SP_DISCO] = 1 }

local function better(a, b)
	for k = 1, #a do
		if a[k] ~= b[k] then return a[k] > b[k] end
	end
	return false
end

local function progress(s, g)
	local W, H = s.W, s.H
	if B.goal_open(s, C.GOAL_COLLECT, g.color) then return true end
	local light = B.goal_open(s, C.GOAL_LIGHT, 0)
	local deliver = B.goal_open(s, C.GOAL_DELIVER, 0)
	for k = 1, #g.cells do
		local i = g.cells[k]
		if light and s.floor[i] > 0 then return true end
		local x, y = U.xy(W, i)
		if deliver and y > 1 then
			local above = B.get(s, i - W)
			if above and above.kind == K_MIC then return true end
		end
		local nb = { y > 1 and i - W or 0, x > 1 and i - 1 or 0, x < W and i + 1 or 0, y < H and i + W or 0 }
		for j = 1, 4 do
			local o = nb[j] ~= 0 and B.get(s, nb[j]) or nil
			if o and o.kind == C.K_BLOCKER and o.state == C.S_IDLE and o.blocker ~= C.BK_CONCRETE
				and B.goal_open(s, C.GOAL_BREAK, o.blocker)
				and (o.blocker ~= C.BK_BALLOON or o.color == g.color) then
				return true
			end
		end
	end
	return false
end

local function count_color(s, color)
	local n = 0
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.kind == K_REGULAR and o.state == C.S_IDLE and o.color == color then n = n + 1 end
	end
	return n
end

local function pair_key(s, col, a, b)
	local oa, ob = B.get(s, a), B.get(s, b)
	if oa.kind == K_SPECIAL and ob.kind == K_SPECIAL then
		local lo, hi = oa.special, ob.special
		if lo > hi then lo, hi = hi, lo end
		return { 4, COMBO_RANK[lo * 10 + hi], 0, 0, 0, -a }
	end
	-- virtual groups through a or b
	local ca, cb = col[a], col[b]
	col[a], col[b] = cb, ca
	local groups = M.find_groups(col, s.W, s.H)
	col[a], col[b] = ca, cb
	local rank, size, prog = 0, 0, false
	for k = 1, #groups do
		local g = groups[k]
		local touches = false
		for j = 1, #g.cells do
			if g.cells[j] == a or g.cells[j] == b then touches = true end
		end
		if touches then
			size = size + #g.cells
			local sp = M.classify(g)
			if sp ~= 0 and RANK3[sp] > rank then rank = RANK3[sp] end
			if progress(s, g) then prog = true end
		end
	end
	local sp, other = nil, nil
	if oa.kind == K_SPECIAL then sp, other = oa, ob elseif ob.kind == K_SPECIAL then sp, other = ob, oa end
	if sp and sp.special == C.SP_DISCO and other.kind == K_REGULAR then
		return { 3, RANK3[C.SP_DISCO], count_color(s, other.color), 0, 0, -a }
	end
	if rank > 0 then return { 3, rank, size, 0, 0, -a } end
	if prog then return { 2, 1, size, 0, 0, -a } end
	if sp then return { 2, 0, 0, RANK2[sp.special], 1, -a } end
	return { 1, size, 0, 0, 0, -a }
end

-- Returns {from = {x, y}, to = {x, y}}, {at = {x, y}} or nil.
function HI.hint(s)
	local W = s.W
	local col = MV.expected_colors(s)
	local best, bkey = nil, nil
	local list = MV.pair_list(s)
	for k = 1, #list do
		local a, b = list[k][1], list[k][2]
		local key = pair_key(s, col, a, b)
		if not bkey or better(key, bkey) then
			local ax, ay = U.xy(W, a)
			local bx, by = U.xy(W, b)
			best, bkey = { from = { ax, ay }, to = { bx, by } }, key
		end
	end
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.kind == K_SPECIAL and o.state == C.S_IDLE and o.pins[1] == nil then
			local key = { 2, 0, 0, RANK2[o.special], 0, -i }
			if not bkey or better(key, bkey) then
				local x, y = U.xy(W, i)
				best, bkey = { at = { x, y } }, key
			end
		end
	end
	return best
end

return HI
