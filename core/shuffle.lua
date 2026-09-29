-- Shuffle (12.2): permutations, recolours, Riff fallbacks.
--
-- Used by the start board (4.3, stream init, no lock, no event), by the
-- in-game shuffle at rest (step 8, stream shuffle, items 1-6) and by the
-- Remix booster (stream shuffle, items 1-3).

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local R = require("core.rng")
local M = require("core.match")
local MV = require("core.moves")

local SH = {}

local K_REGULAR, S_IDLE = C.K_REGULAR, C.S_IDLE

-- Candidates: regular idle pieces without wires, not pinned, by index.
function SH.candidates(s)
	local cells = {}
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.kind == K_REGULAR and o.state == S_IDLE and o.pins[1] == nil and s.wires[i] == 0 then
			cells[#cells + 1] = i
		end
	end
	return cells
end

local function reg_color(s, x, y)
	if x < 1 or y < 1 then return 0 end
	local o = B.get(s, (y - 1) * s.W + x)
	if o and o.kind == K_REGULAR then return o.color end
	return 0
end

-- Allowed colours of 4.2 for cell i: level colours that make no line of 3
-- with the two left or the two upper neighbours and no 2x2 with the left,
-- upper and upper-left neighbours. All level colours if none is allowed.
function SH.allowed_colors(s, i)
	local W = s.W
	local x = (i - 1) % W + 1
	local y = (i - x) / W + 1
	local l1, l2 = reg_color(s, x - 1, y), reg_color(s, x - 2, y)
	local u1, u2 = reg_color(s, x, y - 1), reg_color(s, x, y - 2)
	local ul = reg_color(s, x - 1, y - 1)
	local colors = s.level.colors
	local out = {}
	for k = 1, #colors do
		local c = colors[k]
		local bad = (l1 == c and l2 == c) or (u1 == c and u2 == c) or (l1 == c and u1 == c and ul == c)
		if not bad then out[#out + 1] = c end
	end
	if #out == 0 then return colors end
	return out
end

local function attempt_ok(s)
	return not M.any_match(M.color_map(s), s.W, s.H) and MV.has_pair(s)
end

-- Items 1-3 of 12.2 with random stream `st`. Returns a result:
--   item: 1 permutation, 2 recolour, 3 Riff from a candidate, 0 nothing
--         (no candidates); moved: {obj, from_cell}, recolored: objs, riff: obj.
function SH.run(s, st)
	local cells = SH.candidates(s)
	local n = #cells
	local orig, ocol = {}, {}
	for k = 1, n do
		orig[k] = B.get(s, cells[k])
		ocol[k] = orig[k].color
	end
	local function put(list)
		for k = 1, n do B.place(s, list[k], cells[k]) end
	end
	-- 1. permutations
	for _ = 1, C.SHUFFLE_ATTEMPTS do
		local a = U.copy_array(orig)
		for i = n, 2, -1 do
			local j = R.int(st, i)
			a[i], a[j] = a[j], a[i]
		end
		put(a)
		if attempt_ok(s) then
			local moved = {}
			for k = 1, n do
				if a[k] ~= orig[k] then
					-- a[k] came from the cell where it stood in the original order
					local from = 0
					for j = 1, n do
						if orig[j] == a[k] then from = cells[j] end
					end
					moved[#moved + 1] = { a[k], from }
				end
			end
			return { item = 1, moved = moved, recolored = {} }
		end
		put(orig)
	end
	-- 2. recolours
	for _ = 1, C.SHUFFLE_ATTEMPTS do
		for k = 1, n do
			local allowed = SH.allowed_colors(s, cells[k])
			orig[k].color = R.weighted(st, allowed, s.level.weights)
		end
		if attempt_ok(s) then
			local rec = {}
			for k = 1, n do
				if orig[k].color ~= ocol[k] then rec[#rec + 1] = orig[k] end
			end
			return { item = 2, moved = {}, recolored = rec }
		end
		for k = 1, n do orig[k].color = ocol[k] end
	end
	-- 3. Riff from a candidate
	if n >= 1 then
		local o = orig[R.int(st, n)]
		SH.make_riff(o)
		return { item = 3, moved = {}, recolored = {}, riff = o, riff_from = "piece" }
	end
	return { item = 0, moved = {}, recolored = {} }
end

-- In-place conversion into a Riff with axis h (id and label kept).
function SH.make_riff(o, axis)
	o.kind = C.K_SPECIAL
	o.special = C.SP_RIFF
	o.axis = axis or C.AX_H
	o.color = 0
	o.blocker = 0
	o.hp = 0
end

local function lock(s, o, dur)
	B.set_state(o, C.S_SWAP)
	o.tk = C.TM_LOCK
	o.td = s.now + dur
end

-- Locks the changed pieces and emits `shuffle` (in game and Remix).
function SH.apply_result(s, res)
	local dur = B.T(s).shuffle
	local W = s.W
	local ev = { moves = {}, recolors = {}, duration = dur }
	for k = 1, #res.moved do
		local o, from = res.moved[k][1], res.moved[k][2]
		local fx, fy = U.xy(W, from)
		local x, y = U.xy(W, o.cell)
		ev.moves[#ev.moves + 1] = { id = o.id, fx = fx, fy = fy, x = x, y = y }
		lock(s, o, dur)
	end
	for k = 1, #res.recolored do
		local o = res.recolored[k]
		ev.recolors[#ev.recolors + 1] = { id = o.id, color = C.COLOR_NAME[o.color] }
		lock(s, o, dur)
	end
	if res.riff then
		local o = res.riff
		local x, y = U.xy(W, o.cell)
		ev.riff = { id = o.id, x = x, y = y, from = res.riff_from }
		lock(s, o, dur)
	end
	E.emit(s, "shuffle", ev)
end

-- In-game shuffle at rest (12.2, items 1-6).
function SH.in_game(s)
	local st = s.rng[R.SHUFFLE]
	local res = SH.run(s, st)
	if res.item == 0 then
		-- 4. a wired regular piece loses its wires and becomes a Riff
		local wired = {}
		for i = 1, s.N do
			local o = B.get(s, i)
			if o and o.kind == K_REGULAR and s.wires[i] > 0 then wired[#wired + 1] = o end
		end
		if #wired > 0 then
			local o = wired[R.int(st, #wired)]
			s.wires[o.cell] = 0
			local x, y = U.xy(s.W, o.cell)
			E.emit(s, "freed", { id = o.id, x = x, y = y })
			SH.make_riff(o)
			res.riff, res.riff_from = o, "wires"
		else
			-- 5. a noise becomes a Riff
			local noise = {}
			for i = 1, s.N do
				local o = B.get(s, i)
				if o and o.kind == C.K_BLOCKER and o.blocker == C.BK_NOISE and o.state == S_IDLE then
					noise[#noise + 1] = o
				end
			end
			if #noise > 0 then
				local o = noise[R.int(st, #noise)]
				local x, y = U.xy(s.W, o.cell)
				E.emit(s, "destroy", { id = o.id, x = x, y = y, item = "noise" })
				if #noise == 1 then
					local H = require("core.hits")
					local acc = H.acc()
					H.goal(s, acc, C.GOAL_BREAK, C.BK_NOISE, 1)
					H.flush(s, acc, o.cell)
				end
				SH.make_riff(o)
				res.riff, res.riff_from = o, "noise"
			else
				-- 6. stuck
				s.stuck = true
				E.set_state(s, C.G_OUT, "stuck")
				s.stuck = true
				return res
			end
		end
	end
	SH.apply_result(s, res)
	return res
end

return SH
