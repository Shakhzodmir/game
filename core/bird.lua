-- The Bird (8.3) and its targets (section 9).
--
-- A Bird hits its cross (own cell and 4 side neighbours, by index) at t0
-- inside the activation, then chooses a target on the board as it is after
-- the cross. The target is reserved (source.reserves) and an idle movable
-- piece in it is pinned until the impact, a `bird_impact` record at
-- t0 + T.bird_flight (run at once in turbo). The impact releases both, then
-- hits the target cell, or activates the cargo (Riff or Sabwoofer of a
-- combo) there with a new source carrying the Bird's label.

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local R = require("core.rng")
local H = require("core.hits")
local EF = require("core.effects")
local sched = require("core.sched")

local BD = {}

local K_REGULAR, K_SPECIAL, K_MIC, K_BLOCKER = C.K_REGULAR, C.K_SPECIAL, C.K_MIC, C.K_BLOCKER
local S_IDLE = C.S_IDLE
local BK_CONCRETE, BK_COLUMN = C.BK_CONCRETE, C.BK_COLUMN

BD.CARGO_NONE, BD.CARGO_RIFF, BD.CARGO_SUB = 0, 1, 2
local CARGO_SPECIAL = { C.SP_RIFF, C.SP_SUB }

-- Open goals that matter for the level table.
local function goal_ctx(s)
	local ctx = { brk = {}, col = {}, light = false, deliver = false }
	local goals, left = s.level.goals, s.goal_left
	for k = 1, #goals do
		if left[k] > 0 then
			local g = goals[k]
			if g.type == C.GOAL_BREAK then ctx.brk[g.param] = true
			elseif g.type == C.GOAL_COLLECT then ctx.col[g.param] = true
			elseif g.type == C.GOAL_LIGHT then ctx.light = true
			elseif g.type == C.GOAL_DELIVER then ctx.deliver = true end
		end
	end
	return ctx
end

-- Is a hit here going to destroy a single-cell blocker (hp 1)?
local function weak_blocker(o)
	return o.kind == K_BLOCKER and o.blocker ~= BK_COLUMN and o.hp == 1
end

-- Level of every cell (the table of section 9), array 1..N.
function BD.levels(s)
	local ctx = goal_ctx(s)
	local W = s.W
	local lv = {}
	for i = 1, s.N do
		local l = 0
		if s.exists[i] then
			local o = B.get(s, i)
			local idle = o ~= nil and o.state == S_IDLE
			if idle and o.pins[1] then
				l = 0 -- a pinned piece zeroes the whole cell
			elseif idle and o.blocker == BK_COLUMN then
				-- an intact column: blocker rows at its top-left cell only, no tiles
				if o.cell == i then l = ctx.brk[BK_COLUMN] and 4 or 2 end
			else
				if idle then
					local k = o.kind
					if k == K_BLOCKER then
						if o.blocker == BK_CONCRETE and ctx.brk[BK_CONCRETE] then l = 5
						elseif ctx.brk[o.blocker] then l = 4
						else l = 2 end
					elseif k == K_REGULAR then
						if s.wires[i] > 0 then l = 2
						elseif ctx.col[o.color] then l = 4
						else l = 1 end
					elseif k == K_SPECIAL then
						l = 2
					end
					-- K_MIC: 0
				end
				-- an unlit tile the hit will damage
				if l < 4 and ctx.light and s.floor[i] > 0 and s.wires[i] == 0
					and (not idle or o.kind == K_REGULAR or weak_blocker(o)) then
					l = 4
				end
				-- the cell right under an idle mic, if the hit frees it
				if l < 3 and ctx.deliver and idle and i > W then
					local m = B.get(s, i - W)
					if m and m.kind == K_MIC and m.state == S_IDLE
						and ((o.kind == K_REGULAR and s.wires[i] == 0) or weak_blocker(o)) then
						l = 3
					end
				end
			end
		end
		lv[i] = l
	end
	return lv
end

-- Keys reserved by any flying Bird.
local function reserved(s)
	local set = {}
	for _, src in pairs(s.sources) do -- order-independent (builds a set)
		local r = src.reserves
		for k = 1, #r do set[r[k]] = true end
	end
	return set
end

-- Candidate cells (level >= 1, not hit by src, not reserved), by index.
function BD.candidates(s, src, lv)
	local res = reserved(s)
	local out = {}
	for i = 1, s.N do
		if lv[i] >= 1 then
			local key = B.key(s, i)
			if not res[key] and not U.sorted_has(src.keys, key) then out[#out + 1] = i end
		end
	end
	return out
end

-- Density: existing cells with level >= 3 in the 3x3 square around i.
local function density(s, lv, i)
	local W, Hh = s.W, s.H
	local x, y = U.xy(W, i)
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

-- Single target (section 9): max level, then max density, then one draw of
-- the `effects` stream among the equal best. 0 = no target (no draw).
function BD.pick_single(s, src)
	local lv = BD.levels(s)
	local cands = BD.candidates(s, src, lv)
	local best, bl, bd = {}, -1, -1
	for k = 1, #cands do
		local i = cands[k]
		local l, d = lv[i], density(s, lv, i)
		if l > bl or (l == bl and d > bd) then
			best, bl, bd = { i }, l, d
		elseif l == bl and d == bd then
			best[#best + 1] = i
		end
	end
	if #best == 0 then return 0 end
	return best[R.int(s.rng[R.EFFECTS], #best)]
end

-- Object key for the cargo sums: an intact column counts once, at its
-- top-left cell; everything else by its own cell.
local function sum_key(s, j)
	local o = B.get(s, j)
	if o and o.blocker == BK_COLUMN and o.state == S_IDLE then return o.cell end
	return j
end

-- Tuple (A, B, C, D) of the objects in a list of cells: levels 4-5, 3, 2, 1.
local function tuple(s, lv, cells)
	local t = { 0, 0, 0, 0 }
	local seen = {}
	for k = 1, #cells do
		local key = sum_key(s, cells[k])
		if not seen[key] then
			seen[key] = true
			local l = lv[key]
			if l >= 4 then t[1] = t[1] + 1
			elseif l >= 1 then t[5 - l] = t[5 - l] + 1 end
		end
	end
	return t
end

-- Lexicographic comparison of tuples: 1 if a > b, -1 if a < b, 0 if equal.
local function cmp(a, b)
	for k = 1, 4 do
		if a[k] ~= b[k] then return a[k] > b[k] and 1 or -1 end
	end
	return 0
end

-- Existing cells of the cargo area around i.
local function area(s, i, cargo, axis)
	local W, Hh = s.W, s.H
	local x, y = U.xy(W, i)
	local out = {}
	if cargo == BD.CARGO_SUB then
		for yy = y - 2, y + 2 do
			for xx = x - 2, x + 2 do
				if xx >= 1 and xx <= W and yy >= 1 and yy <= Hh and s.exists[(yy - 1) * W + xx] then
					out[#out + 1] = (yy - 1) * W + xx
				end
			end
		end
	elseif axis == C.AX_H then
		for xx = 1, W do
			if s.exists[(y - 1) * W + xx] then out[#out + 1] = (y - 1) * W + xx end
		end
	else
		for yy = 1, Hh do
			if s.exists[(yy - 1) * W + x] then out[#out + 1] = (yy - 1) * W + x end
		end
	end
	return out
end

-- Target with cargo (section 9): the lexicographically largest tuple (for
-- a Riff the better axis first, h on a tie), then one draw among the equal
-- best. Returns cell, axis (0, 0 = no target, no draw).
function BD.pick_cargo(s, src, cargo)
	local lv = BD.levels(s)
	local cands = BD.candidates(s, src, lv)
	local best, bt = {}, nil
	for k = 1, #cands do
		local i = cands[k]
		local t, axis
		if cargo == BD.CARGO_SUB then
			t, axis = tuple(s, lv, area(s, i, cargo, 0)), 0
		else
			t, axis = tuple(s, lv, area(s, i, cargo, C.AX_H)), C.AX_H
			local tv = tuple(s, lv, area(s, i, cargo, C.AX_V))
			if cmp(tv, t) > 0 then t, axis = tv, C.AX_V end
		end
		local c = bt and cmp(t, bt) or 1
		if c > 0 then
			best, bt = { { i, axis } }, t
		elseif c == 0 then
			best[#best + 1] = { i, axis }
		end
	end
	if #best == 0 then return 0, 0 end
	local pick = best[R.int(s.rng[R.EFFECTS], #best)]
	return pick[1], pick[2]
end

-- The cross (8.3.1): own cell and 4 side neighbours by index, all at t0.
function BD.cross(s, src, cell)
	local W = s.W
	local x, y = U.xy(W, cell)
	local t0 = s.now
	local nb = { { x, y - 1 }, { x - 1, y }, { x, y }, { x + 1, y }, { x, y + 1 } }
	local acts = {}
	for k = 1, 5 do
		if B.exists_xy(s, nb[k][1], nb[k][2]) then
			acts[#acts + 1] = { t0, C.R_HIT, { src.id, (nb[k][2] - 1) * W + nb[k][1] } }
		end
	end
	EF.run(s, src, acts, false)
end

-- A chosen target (8.3.2): reservation, pin, `bird_fly`. Returns the
-- impact action (bird_impact at t0 + T.bird_flight).
function BD.fly(s, src, from_cell, target, cargo, axis)
	U.sorted_add(src.reserves, target)
	local o = B.get(s, target)
	if o and o.state == S_IDLE and B.is_movable(s, o) then B.pin(o, src.id) end
	local x, y = U.xy(s.W, from_cell)
	local tx, ty = U.xy(s.W, target)
	local ev = { x = x, y = y, tx = tx, ty = ty, duration = B.T(s).bird_flight }
	if cargo ~= 0 then ev.carry = C.SPECIAL_NAME[CARGO_SPECIAL[cargo]] end
	if axis ~= 0 then ev.axis = C.AXIS_NAME[axis] end
	E.emit(s, "bird_fly", ev)
	return BD.impact_action(s, src, target, cargo, axis)
end

function BD.impact_action(s, src, cell, cargo, axis)
	return { EF.at(s, s.now, EF.NT.bird_flight), C.R_BIRD, { src.id, cell, cargo, axis } }
end

-- Single Bird (8.3): cross, one target, impact.
function BD.single(s, src, cell)
	BD.cross(s, src, cell)
	local t = BD.pick_single(s, src)
	if t == 0 then return end
	EF.run(s, src, { BD.fly(s, src, cell, t, 0, 0) }, false)
end

-- Bird with cargo (8.5 bird+riff, bird+sub): cross, target "with cargo",
-- impact with the cargo; no target -> the cargo fires in the centre with
-- the partner Riff's own axis (8.3.4).
function BD.carry(s, src, cell, cargo, partner_axis)
	BD.cross(s, src, cell)
	local t, axis = BD.pick_cargo(s, src, cargo)
	local act
	if t == 0 then
		act = BD.impact_action(s, src, cell, cargo, cargo == BD.CARGO_RIFF and partner_axis or 0)
	else
		act = BD.fly(s, src, cell, t, cargo, axis)
	end
	EF.run(s, src, { act }, false)
end

-- Trio (8.5 bird+bird): cross, up to three targets chosen in turn (each
-- with the reservations of the previous ones), then the impacts in the
-- order of choice. A choice without candidates drops it and the rest.
function BD.trio(s, src, cell)
	BD.cross(s, src, cell)
	local acts = {}
	for _ = 1, 3 do
		local t = BD.pick_single(s, src)
		if t == 0 then break end
		acts[#acts + 1] = BD.fly(s, src, cell, t, 0, 0)
	end
	EF.run(s, src, acts, false)
end

-- Record kind 5: {source, cell, cargo, axis}.
function BD.impact(s, d)
	local src = s.sources[d[1]]
	local cell, cargo, axis = d[2], d[3], d[4]
	U.sorted_remove(src.reserves, cell)
	local o = B.get(s, cell)
	if o and o.pins[1] then B.unpin(o, src.id) end
	if cargo == BD.CARGO_NONE then
		H.hit(s, cell, src)
		return
	end
	local csrc = H.new_source(s, C.SRC_EFFECT, src.mv, src.wv, 0)
	local sp = CARGO_SPECIAL[cargo]
	EF.activate_event(s, nil, cell, sp, axis, nil)
	if sp == C.SP_RIFF then
		EF.riff(s, csrc, cell, axis)
	else
		EF.sub(s, csrc, cell, 2)
	end
	sched.retire_if_done(s, csrc)
end

return BD
