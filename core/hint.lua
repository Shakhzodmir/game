-- Hint (12.3): a pure ranking of moves() and taps.
--
-- On a level with the stage fog (10.13) the hint is fair: it sees what the player sees. A fogged piece has
-- no colour for it, a fogged cell is never an end of a suggested swap or tap, and what stands in a fogged
-- cell next to a group gives no goal progress. Only when the visible board offers nothing does it fall back
-- to the first move of the true board that starts or ends in the fog, marked `blind` (the client swells
-- the cloud and shows nothing of what is under it); failing that it is silent.

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
	local drop = B.goal_open(s, C.GOAL_DROP, 0)
	local chains = B.goal_open(s, C.GOAL_CHAINS, 0)
	local ice = B.goal_open(s, C.GOAL_ICE, 0)
	local fog = s.fog
	local mist = fog and B.goal_open(s, C.GOAL_FOG, 0)
	-- the carpet (10.8): a group that stands on the carpet and reaches beyond it rolls the carpet out
	if s.carpet and B.goal_open(s, C.GOAL_CARPET, 0) then
		local on, off = false, false
		for k = 1, #g.cells do
			if s.carpet[g.cells[k]] then on = true else off = true end
		end
		if on and off then return true end
	end
	for k = 1, #g.cells do
		local i = g.cells[k]
		if light and s.floor[i] > 0 then return true end
		if chains and B.get(s, i).chain > 0 then return true end
		local x, y = U.xy(W, i)
		-- (the cell "above" a portal exit is the entrance of its pair, 10.14)
		local up = y > 1 and i - W or 0
		if s.level.portal and s.level.portal.entry_of[i] ~= 0 then up = s.level.portal.entry_of[i] end
		if deliver and up ~= 0 then
			local above = B.get(s, up)
			if above and above.kind == K_MIC and not (fog and fog[up]) then return true end
		end
		if drop and up ~= 0 then
			local above = B.get(s, up)
			if above and above.kind == C.K_COCONUT and not (fog and fog[up]) then return true end
		end
		local nb = { y > 1 and i - W or 0, x > 1 and i - 1 or 0, x < W and i + 1 or 0, y < H and i + W or 0 }
		for j = 1, 4 do
			local o = nb[j] ~= 0 and B.get(s, nb[j]) or nil
			if fog and nb[j] ~= 0 and fog[nb[j]] then
				-- a fogged neighbour: the match blows its fog off (10.13); what hides in it is not looked at
				if mist then return true end
				o = nil
			end
			-- a frozen piece next to the group thaws by one layer (10.11)
			if ice and o and o.ice > 0 and o.state == C.S_IDLE and not B.veiled(s, nb[j]) then return true end
			if o and o.kind == C.K_BLOCKER and o.state == C.S_IDLE and o.blocker ~= C.BK_CONCRETE
				and not B.veiled(s, nb[j])
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
		if o and o.kind == K_REGULAR and o.state == C.S_IDLE and o.color == color and o.ice == 0
			and not (s.fog and s.fog[i]) then
			n = n + 1
		end
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
	local fog = s.fog
	if fog then
		for i = 1, s.N do
			if fog[i] then col[i] = 0 end -- (the colour of a fogged piece is not known to the player)
		end
	end
	local best, bkey = nil, nil
	local list = MV.pair_list(s)
	for k = 1, #list do
		local a, b = list[k][1], list[k][2]
		local key = nil
		-- under the fog (10.13): both ends are visible, and the match shows without the fogged colours
		if not fog or (not fog[a] and not fog[b] and MV.eval_pair(s, col, a, b) == "ok") then
			key = pair_key(s, col, a, b)
		end
		if key and (not bkey or better(key, bkey)) then
			local ax, ay = U.xy(W, a)
			local bx, by = U.xy(W, b)
			best, bkey = { from = { ax, ay }, to = { bx, by } }, key
		end
	end
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.kind == K_SPECIAL and o.state == C.S_IDLE and o.pins[1] == nil and not B.veiled(s, i)
			and not (fog and fog[i]) then
			local key = { 2, 0, 0, RANK2[o.special], 0, -i }
			if not bkey or better(key, bkey) then
				local x, y = U.xy(W, i)
				best, bkey = { at = { x, y } }, key
			end
		end
	end
	if not best and fog then
		-- nothing the player can see: the first move of the true board (12.1 order) that has an end in the
		-- fog, then the first tap on a fogged special by cell, chosen without ranking (a ranking would tell
		-- what hides in the fog). `blind` tells the client to point at the cells without showing their content.
		-- A swap of two visible pieces that works only thanks to a fogged colour is never shown (two visible
		-- pieces wobbling would give that colour away): if nothing else is left, the hint stays silent
		for k = 1, #list do
			local a, b = list[k][1], list[k][2]
			if fog[a] or fog[b] then
				local ax, ay = U.xy(W, a)
				local bx, by = U.xy(W, b)
				return { from = { ax, ay }, to = { bx, by }, blind = true }
			end
		end
		for i = 1, s.N do
			local o = B.get(s, i)
			if fog[i] and o and o.kind == K_SPECIAL and o.state == C.S_IDLE and o.pins[1] == nil and not B.veiled(s, i) then
				local x, y = U.xy(W, i)
				return { at = { x, y }, blind = true }
			end
		end
	end
	return best
end

return HI
