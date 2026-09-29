-- Swap evaluation on the expected board (5.1.2) and the move list (12.1).

local C = require("core.const")
local B = require("core.board")
local M = require("core.match")

local MV = {}

local K_REGULAR, K_SPECIAL, K_MIC = C.K_REGULAR, C.K_SPECIAL, C.K_MIC
local S_IDLE, S_FALL, S_SWAP = C.S_IDLE, C.S_FALL, C.S_SWAP

-- Expected board (5.1.2): colour of every regular piece where it will be
-- once its current motion ends. Idle and falling pieces stand in their
-- (target) cell; swapping pieces in the cell of their partner (swap and
-- swap_back) or in their own (swap_fail and shuffle lock). Pieces in clear
-- or armed, specials, mics and blockers have no colour.
function MV.expected_colors(s)
	local col = {}
	local slot, objs = s.slot, s.objs
	for i = 1, s.N do
		local c = 0
		local id = slot[i]
		if id ~= 0 then
			local o = objs[id]
			if o.kind == K_REGULAR then
				local st = o.state
				if st == S_IDLE or st == S_FALL
					or (st == S_SWAP and (o.tk == C.TM_FAIL or o.tk == C.TM_LOCK)) then
					c = o.color
				end
			end
		end
		col[i] = c
	end
	local swaps = s.swaps
	for k = 1, #swaps do
		local sw = swaps[k]
		if sw.kind == C.TM_SWAP or sw.kind == C.TM_BACK then
			local a, b = B.get(s, sw.from), B.get(s, sw.to)
			col[sw.to] = (a and a.kind == K_REGULAR) and a.color or 0
			col[sw.from] = (b and b.kind == K_REGULAR) and b.color or 0
		end
	end
	return col
end

-- 'ok' or 'fail' for a swap of the free pieces in cells a and b.
-- A special always makes it 'ok'. Two regular pieces of one colour and two
-- mics are a failed swap (5.1.2). Otherwise the virtual exchange must give
-- a match through a or b.
function MV.eval_pair(s, col, a, b)
	local oa, ob = B.get(s, a), B.get(s, b)
	if oa.kind == K_SPECIAL or ob.kind == K_SPECIAL then return "ok" end
	if oa.kind == K_MIC and ob.kind == K_MIC then return "fail" end
	if oa.kind == K_REGULAR and ob.kind == K_REGULAR and oa.color == ob.color then return "fail" end
	local ca, cb = col[a], col[b]
	col[a], col[b] = cb, ca
	local W, H = s.W, s.H
	local ok = M.match_at(col, W, H, a) or M.match_at(col, W, H, b)
	col[a], col[b] = ca, cb
	return ok and "ok" or "fail"
end

local function free_at(s, i)
	local o = B.get(s, i)
	return o ~= nil and B.is_free(s, o)
end

-- The list of 12.1: {a, b} cell pairs (right neighbour, then bottom).
-- With `first_only` it stops at the first pair.
function MV.pairs(s, first_only)
	local W, Hh = s.W, s.H
	local col = MV.expected_colors(s)
	local list = {}
	for i = 1, s.N do
		if free_at(s, i) then
			local x = (i - 1) % W + 1
			local y = (i - x) / W + 1
			if x < W and free_at(s, i + 1) and MV.eval_pair(s, col, i, i + 1) == "ok" then
				list[#list + 1] = { i, i + 1 }
				if first_only then return list end
			end
			if y < Hh and free_at(s, i + W) and MV.eval_pair(s, col, i, i + W) == "ok" then
				list[#list + 1] = { i, i + W }
				if first_only then return list end
			end
		end
	end
	return list
end

function MV.has_pair(s)
	return #MV.pairs(s, true) > 0
end

function MV.has_free_special(s)
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.kind == K_SPECIAL and o.state == S_IDLE and o.pins[1] == nil then return true end
	end
	return false
end

-- has_move of 12.1: a tappable special or a pair.
function MV.has_move(s)
	return MV.has_free_special(s) or MV.has_pair(s)
end

return MV
