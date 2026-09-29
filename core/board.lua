-- The board: cell layers, slot objects, ids, labels and pins (section 1).
--
-- Cells are arrays of size W*H indexed by i = (y-1)*W + x. s.slot[i] holds
-- the id of the object in the slot (0 = empty); objects live in s.objs[id].
-- A column 2x2 is one object whose key cell is its top-left cell; all four
-- slots hold its id.
--
-- Object fields (all numbers except `pins`):
--   id, kind (K_*), color (regular piece or balloon, else 0), special (SP_*),
--   axis (AX_*), blocker (BK_*), hp (blocker hp), state (S_*), cell (key /
--   target cell), mv, wv (label), offx, offy, vy, delay, settle (settle_tick),
--   tk, td (timer kind and due tick), pins (source ids, ascending).

local C = require("core.const")
local U = require("core.util")

local B = {}

local K_REGULAR, K_SPECIAL, K_MIC, K_BLOCKER = C.K_REGULAR, C.K_SPECIAL, C.K_MIC, C.K_BLOCKER
local S_IDLE = C.S_IDLE

-- A fresh state with the static cell layers of the level and no objects.
function B.new_state(level)
	local W, H = level.W, level.H
	local N = W * H
	local s = {
		W = W, H = H, N = N, level = level,
		exists = {}, spawner = {}, exit = {}, floor = {}, wires = {},
		vac_mv = {}, vac_wv = {}, slot = {}, seg_top = {}, seg_bot = {},
		objs = {},
		tick = 0, now = 0, phase = 0,
		act = 0, seq = 0, next_piece_id = 1, next_source_id = 1,
		moves_left = level.moves, moves_made = 0, score = 0,
		goal_left = {},
		released = 0, on_board = 0, last_mic = 0,
		state = C.G_PLAYING, stuck = false, timing = C.TIMING_NORMAL,
		input_lock = false, rest_flag = false, dirty = false, last_assign = 0,
		tc = 0, rounds = 0, moves_at_win = 0, concert_A = 0,
		swaps = {}, queue = {}, sources = {}, eom = {}, praise = {}, unplaced = {},
		rng = nil, help = 0, colorless = false, in_group = false,
		ev = {}, cmds = {},
	}
	for i = 1, N do
		s.exists[i] = level.exists[i]
		s.spawner[i] = level.spawner[i]
		s.exit[i] = level.exit[i]
		s.floor[i] = level.floor[i]
		s.wires[i] = level.wires[i]
		s.vac_mv[i], s.vac_wv[i] = 0, 0
		s.slot[i] = 0
		s.seg_top[i] = level.seg_top[i]
		s.seg_bot[i] = level.seg_bot[i]
	end
	for k = 1, #level.goals do s.goal_left[k] = level.goals[k].count end
	return s
end

function B.T(s)
	return C.T[s.timing]
end

-- Object in cell i, or nil.
function B.get(s, i)
	local id = s.slot[i]
	if id == 0 then return nil end
	return s.objs[id]
end

function B.new_obj(s, kind, fields)
	local id = s.next_piece_id
	s.next_piece_id = id + 1
	local o = {
		id = id, kind = kind, color = 0, special = 0, axis = 0, blocker = 0, hp = 0,
		state = S_IDLE, cell = 0, mv = 0, wv = 0, offx = 0, offy = 0, vy = 0, delay = 0,
		settle = 0, tk = 0, td = 0, pins = {},
	}
	if fields then
		for k, v in pairs(fields) do o[k] = v end -- order-independent
	end
	s.objs[id] = o
	return o
end

-- Cells covered by an object (a column covers four).
function B.cells_of(s, o)
	local i = o.cell
	if o.blocker == C.BK_COLUMN then
		local W = s.W
		return { i, i + 1, i + W, i + W + 1 }
	end
	return { i }
end

function B.place(s, o, i)
	o.cell = i
	if o.blocker == C.BK_COLUMN then
		local W = s.W
		s.slot[i], s.slot[i + 1], s.slot[i + W], s.slot[i + W + 1] = o.id, o.id, o.id, o.id
	else
		s.slot[i] = o.id
	end
end

-- Removes an object from the board and from the object table.
function B.remove(s, o)
	local cells = B.cells_of(s, o)
	for k = 1, #cells do
		if s.slot[cells[k]] == o.id then s.slot[cells[k]] = 0 end
	end
	s.objs[o.id] = nil
end

-- Object key of cell i: the column's top-left cell, else i itself.
function B.key(s, i)
	local o = B.get(s, i)
	if o and o.blocker == C.BK_COLUMN then return o.cell end
	return i
end

-- A movable piece: regular, special or mic without wires (0.1).
function B.is_movable(s, o)
	local k = o.kind
	if k == K_SPECIAL or k == K_MIC then return true end
	return k == K_REGULAR and s.wires[o.cell] == 0
end

function B.is_pinned(o)
	return o.pins[1] ~= nil
end

-- Movable, idle and not pinned: may swap, be tapped, fall, be a donor.
function B.is_free(s, o)
	return o.state == S_IDLE and o.pins[1] == nil and B.is_movable(s, o)
end

-- Open slot (0.1): empty, or content in fall, swap, clear or armed.
function B.is_open(o)
	return o == nil or o.state ~= S_IDLE
end

-- Every change of state goes through here: leaving idle drops all pins.
function B.set_state(o, st)
	o.state = st
	if st ~= S_IDLE and o.pins[1] then o.pins = {} end
end

function B.pin(o, src_id)
	U.sorted_add(o.pins, src_id)
end

function B.unpin(o, src_id)
	U.sorted_remove(o.pins, src_id)
end

function B.is_pinned_by(o, src_id)
	return (U.sorted_has(o.pins, src_id))
end

-- End-of-move queue entry of action a, or nil.
function B.eom_entry(s, a)
	local q = s.eom
	for k = 1, #q do
		if q[k].a == a then return q[k] end
	end
	return nil
end

-- Raises the label of o to at least (mv, wv) by rules 1.3.5 / 1.3.7 and
-- records the merge of rule 1.3.10.
function B.raise_label(s, o, mv, wv)
	local m = o.mv
	local nm, nw = U.label_max(m, o.wv, mv, wv)
	if nm > m then
		local e1 = B.eom_entry(s, m)
		if e1 and B.eom_entry(s, nm) and nm > e1.merged then e1.merged = nm end
	end
	o.mv, o.wv = nm, nw
end

function B.set_vac(s, i, mv, wv)
	s.vac_mv[i], s.vac_wv[i] = mv, wv
end

-- Iterates the objects on the board once each, by ascending key cell.
-- Returns an array (callers loop over it by index).
function B.objects(s)
	local list = {}
	local slot, objs = s.slot, s.objs
	for i = 1, s.N do
		local id = slot[i]
		if id ~= 0 then
			local o = objs[id]
			if o.cell == i then list[#list + 1] = o end
		end
	end
	return list
end

function B.goal_index(s, gtype, param)
	local goals = s.level.goals
	for k = 1, #goals do
		local g = goals[k]
		if g.type == gtype and (g.param or 0) == (param or 0) then return k end
	end
	return nil
end

function B.goal_open(s, gtype, param)
	local k = B.goal_index(s, gtype, param)
	return k ~= nil and s.goal_left[k] > 0
end

-- Most frequent colour mf(filter) of 3.2.3: regular idle unpinned pieces;
-- `unwired_only` restricts to pieces without wires. 0 = no colour.
function B.most_frequent(s, unwired_only)
	local count = { 0, 0, 0, 0, 0, 0 }
	local slot, objs, wires = s.slot, s.objs, s.wires
	for i = 1, s.N do
		local id = slot[i]
		if id ~= 0 then
			local o = objs[id]
			if o.kind == K_REGULAR and o.state == S_IDLE and o.pins[1] == nil
				and (not unwired_only or wires[i] == 0) then
				count[o.color] = count[o.color] + 1
			end
		end
	end
	local best, bc = 0, 0
	for c = 1, C.NCOLORS do
		if count[c] > bc then best, bc = c, count[c] end
	end
	return best
end

-- True if cell (x, y) is inside the field and exists.
function B.exists_xy(s, x, y)
	if x < 1 or x > s.W or y < 1 or y > s.H then return false end
	return s.exists[(y - 1) * s.W + x]
end

return B
