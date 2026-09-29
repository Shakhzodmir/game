-- Gravity, spawn and falling (10.1-10.4).

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local R = require("core.rng")

local G = {}

local UNIT = C.UNIT
local K_REGULAR, K_MIC, K_BLOCKER = C.K_REGULAR, C.K_MIC, C.K_BLOCKER
local S_IDLE, S_FALL, S_SWAP, S_CLEAR, S_ARMED = C.S_IDLE, C.S_FALL, C.S_SWAP, C.S_CLEAR, C.S_ARMED

local WAIT, BLOCKED, SPAWN, PIECE = 1, 2, 3, 4

-- scan(c) of 10.1: result code and, for PIECE, the object.
local function scan(s, c)
	local W = s.W
	local x = (c - 1) % W + 1
	local y = (c - x) / W + 1
	local top = s.seg_top[c]
	local k = y
	while k > top do
		k = k - 1
		local e = B.get(s, (k - 1) * W + x)
		if e then
			local st = e.state
			if st == S_CLEAR or st == S_SWAP or st == S_ARMED then return WAIT end
			if e.pins[1] then return WAIT end
			if e.kind == K_BLOCKER or (e.kind == K_REGULAR and s.wires[e.cell] > 0) then
				return BLOCKED
			end
			return PIECE, e -- movable piece in idle or fall
		end
	end
	if s.spawner[(top - 1) * W + x] then return SPAWN end
	return BLOCKED
end

-- Forced colour of the help (10.3).
local function forced_color(s)
	local goals, left = s.level.goals, s.goal_left
	local best, bl = 0, 0
	for k = 1, #goals do
		local g = goals[k]
		if g.type == C.GOAL_COLLECT and left[k] > 0 then
			if left[k] > bl or (left[k] == bl and g.param < best) then best, bl = g.param, left[k] end
		end
	end
	if best ~= 0 then return best end
	if B.goal_open(s, C.GOAL_BREAK, C.BK_BALLOON) then
		local count = { 0, 0, 0, 0, 0, 0 }
		for i = 1, s.N do
			local o = B.get(s, i)
			if o and o.blocker == C.BK_BALLOON and o.state == S_IDLE then
				count[o.color] = count[o.color] + 1
			end
		end
		local bc = 0
		for c = 1, C.NCOLORS do
			if count[c] > bc then best, bc = c, count[c] end
		end
		if best ~= 0 then return best end
	end
	best = B.most_frequent(s, false)
	if best ~= 0 then return best end
	return s.level.colors[1]
end

-- Mic release test of 10.4.
local function release_mic(s, pass)
	local mic = s.level.mic
	if not mic or s.colorless or pass.mic then return false end
	if s.released >= mic.total then return false end
	if s.on_board >= mic.on_board_max then return false end
	if s.moves_made - s.last_mic < mic.gap_moves then return false end
	pass.mic = true
	s.released = s.released + 1
	s.on_board = s.on_board + 1
	s.last_mic = s.moves_made
	return true
end

-- Kind and colour of a new piece (10.3).
local function new_piece_kind(s, pass)
	if release_mic(s, pass) then return K_MIC, 0 end
	if s.colorless then return K_REGULAR, 0 end
	local lvl = s.level
	local st = s.rng[R.SPAWN]
	if s.help > 0 then
		local p = R.int(st, 100)
		if p <= (s.help == 1 and 5 or 10) then return K_REGULAR, forced_color(s) end
	end
	return K_REGULAR, R.weighted(st, lvl.colors, lvl.weights)
end

-- Refill rule of 10.1 (diagonal donor cell taken again in the same pass).
local function refill(pass, c, o)
	local vy = pass.refill_vy[c]
	if vy then
		if vy < o.vy then o.vy = vy end
		local d = pass.refill_delay[c] + 1
		if d > o.delay then o.delay = d end
	end
end

local function start_fall(s, o, pass, x)
	local T = B.T(s)
	B.set_state(o, S_FALL)
	o.vy = T.fall_v0
	if s.timing == C.TIMING_TURBO then
		o.delay = 0
	else
		o.delay = pass.counter[x]
	end
	pass.counter[x] = pass.counter[x] + 1
end

-- Vertical transfer of q from its cell into c (labels by 1.3.5).
local function transfer(s, q, c, pass)
	local W = s.W
	local S = q.cell
	local x = (c - 1) % W + 1
	local yc = (c - x) / W + 1
	local ys = (S - x) / W + 1
	q.offy = q.offy + (yc - ys) * UNIT
	local mv, wv = s.vac_mv[c], s.vac_wv[c]
	for yy = ys + 1, yc - 1 do
		local j = (yy - 1) * W + x
		mv, wv = U.label_max(mv, wv, s.vac_mv[j], s.vac_wv[j])
	end
	B.raise_label(s, q, mv, wv)
	s.slot[S] = 0
	B.place(s, q, c)
	B.set_vac(s, S, q.mv, q.wv)
	if q.state == S_IDLE then start_fall(s, q, pass, x) end
	refill(pass, c, q)
end

local function spawn(s, c, pass)
	local W = s.W
	local x = (c - 1) % W + 1
	local yc = (c - x) / W + 1
	local ys = s.seg_top[c]
	local kind, color = new_piece_kind(s, pass)
	-- label: max over c and the segment above it
	local mv, wv = s.vac_mv[c], s.vac_wv[c]
	for yy = ys, yc - 1 do
		local j = (yy - 1) * W + x
		mv, wv = U.label_max(mv, wv, s.vac_mv[j], s.vac_wv[j])
	end
	-- offy: one cell above the spawner, not closer than a cell to the
	-- highest falling piece of the segment
	local offy = (yc - ys + 1) * UNIT
	local top = nil
	for yy = ys, s.seg_bot[c] do
		local o = B.get(s, (yy - 1) * W + x)
		if o and o.state == S_FALL then
			local vis = yy * UNIT - o.offy
			if top == nil or vis < top then top = vis end
		end
	end
	if top then
		local o2 = yc * UNIT - top + UNIT
		if o2 > offy then offy = o2 end
	end
	local o = B.new_obj(s, kind, { color = color, mv = mv, wv = wv, offy = offy })
	B.place(s, o, c)
	start_fall(s, o, pass, x)
	refill(pass, c, o)
	local ev = { id = o.id, x = x, y = yc, kind = C.KIND_NAME[kind] }
	if color ~= 0 then ev.color = C.COLOR_NAME[color] end
	E.emit(s, "spawn", ev)
end

-- Diagonal for a blocked cell c; returns true if a donor moved in.
local function diagonal(s, c, pass)
	local W = s.W
	local x = (c - 1) % W + 1
	local y = (c - x) / W + 1
	local yc = y * UNIT
	for yy = y + 1, s.seg_bot[c] do
		local o = B.get(s, (yy - 1) * W + x)
		if o and o.state == S_FALL and yy * UNIT - o.offy < yc then return false end
	end
	if y == 1 then return false end
	local first, second = -1, 1
	if s.now % 2 == 1 then first, second = 1, -1 end
	for pass_no = 1, 2 do
		local dx = pass_no == 1 and first or second
		local dxx = x + dx
		if dxx >= 1 and dxx <= W then
			local D = c - W + dx
			local o = B.get(s, D)
			if o and o.state == S_IDLE and o.pins[1] == nil and B.is_movable(s, o) then
				local below = c + dx -- (x+dx, y)
				if not s.exists[below] or s.slot[below] ~= 0 then
					o.offx = -dx * UNIT
					o.offy = UNIT
					B.raise_label(s, o, s.vac_mv[c], s.vac_wv[c])
					s.slot[D] = 0
					B.place(s, o, c)
					B.set_vac(s, D, o.mv, o.wv)
					start_fall(s, o, pass, x)
					refill(pass, c, o)
					pass.refill_vy[D] = o.vy
					pass.refill_delay[D] = o.delay
					return true
				end
			end
		end
	end
	return false
end

-- Step 5: assignment pass of 10.1. Stores the number of assignments.
function G.assign(s)
	local W, H = s.W, s.H
	local pass = { counter = {}, refill_vy = {}, refill_delay = {}, mic = false }
	for x = 1, W do pass.counter[x] = 0 end
	local n = 0
	local exists, slot = s.exists, s.slot
	for y = H, 1, -1 do
		for x = 1, W do
			local c = (y - 1) * W + x
			if exists[c] and slot[c] == 0 then
				local r, q = scan(s, c)
				if r == PIECE then
					transfer(s, q, c, pass)
					n = n + 1
				elseif r == SPAWN then
					spawn(s, c, pass)
					n = n + 1
				elseif r == BLOCKED then
					if diagonal(s, c, pass) then n = n + 1 end
				end
			end
		end
	end
	s.last_assign = n
	return n
end

local function land(s, o, x, y)
	o.offy, o.offx, o.vy, o.delay = 0, 0, 0, 0
	B.set_state(o, S_IDLE)
	o.settle = s.now
	s.dirty = true
	E.emit(s, "land", { id = o.id, x = x, y = y })
end

-- Step 6: movement of falling pieces (10.2).
function G.move(s)
	local W, H = s.W, s.H
	local objs, slot = s.objs, s.slot
	if s.timing == C.TIMING_TURBO then
		for x = 1, W do
			for y = H, 1, -1 do
				local id = slot[(y - 1) * W + x]
				if id ~= 0 then
					local o = objs[id]
					if o.state == S_FALL then land(s, o, x, y) end
				end
			end
		end
		return
	end
	local T = B.T(s)
	local acc, vmax = T.fall_acc, T.fall_vmax
	for x = 1, W do
		for y = H, 1, -1 do
			local c = (y - 1) * W + x
			local id = slot[c]
			if id ~= 0 then
				local P = objs[id]
				if P.state == S_FALL then
					if P.delay > 0 then
						P.delay = P.delay - 1
					else
						local vy = P.vy + acc
						if vy > vmax then vy = vmax end
						local offy = P.offy
						local new = offy - vy
						local bot = s.seg_bot[c]
						for yy = y + 1, bot do
							local bid = slot[(yy - 1) * W + x]
							if bid ~= 0 then
								local Bo = objs[bid]
								if Bo.state == S_FALL then
									local lim = y * UNIT - (yy * UNIT - Bo.offy) + UNIT
									if lim > new then
										new = lim < offy and lim or offy
										if Bo.vy < vy then vy = Bo.vy end
									end
								end
								break
							end
						end
						local d = offy - new
						P.offy = new
						P.vy = vy
						if P.offx ~= 0 then
							if P.offx > 0 then
								P.offx = P.offx - d
								if P.offx < 0 then P.offx = 0 end
							else
								P.offx = P.offx + d
								if P.offx > 0 then P.offx = 0 end
							end
						end
						if new <= 0 then land(s, P, x, y) end
					end
				end
			end
		end
	end
end

-- Visual y of an object (units): y*3600 - offy.
function G.vis_y(s, o)
	local x = (o.cell - 1) % s.W + 1
	return ((o.cell - x) / s.W + 1) * UNIT - o.offy
end

-- hidden flag of 10.1: a falling piece entirely above the top edge of the
-- spawner of its segment.
function G.hidden(s, o)
	if o.state ~= S_FALL then return false end
	local W = s.W
	local c = o.cell
	local x = (c - 1) % W + 1
	local top = s.seg_top[c]
	if not s.spawner[(top - 1) * W + x] then return false end
	return G.vis_y(s, o) <= (top - 1) * UNIT
end

return G
