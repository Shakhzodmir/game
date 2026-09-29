-- Start board (section 4).

local C = require("core.const")
local B = require("core.board")
local R = require("core.rng")
local M = require("core.match")
local MV = require("core.moves")
local SH = require("core.shuffle")

local ST = {}

-- Places the fixed slot elements of the level (4.1). Ids are provisional.
local function place_fixed(s)
	local presets = s.level.presets
	for k = 1, #presets do
		local p = presets[k]
		local o = B.new_obj(s, p.kind, {
			color = p.color, special = p.special, axis = p.axis, blocker = p.blocker, hp = p.hp,
		})
		B.place(s, o, p.cell)
	end
end

-- One fill of the free cells (4.2) from stream st.
local function fill(s, st, free)
	local weights = s.level.weights
	for k = 1, #free do
		local i = free[k]
		local color = R.weighted(st, SH.allowed_colors(s, i), weights)
		local o = B.new_obj(s, C.K_REGULAR, { color = color })
		B.place(s, o, i)
	end
end

local function unfill(s, free)
	for k = 1, #free do
		local o = B.get(s, free[k])
		if o then B.remove(s, o) end
	end
end

-- Renumbers all objects by ascending key (1.4.2).
local function assign_ids(s)
	local list = B.objects(s)
	local objs = {}
	for k = 1, #list do
		local o = list[k]
		o.id = k
		objs[k] = o
		local cells = B.cells_of(s, o)
		for j = 1, #cells do s.slot[cells[j]] = k end
	end
	s.objs = objs
	s.next_piece_id = #list + 1
end

-- Pre-level boosters (4.5): item codes in list order.
local function place_boosters(s, st, boosters)
	local riffs = 0
	for k = 1, #boosters do
		local item = boosters[k]
		local cands, any = {}, {}
		for i = 1, s.N do
			local o = B.get(s, i)
			if o and o.kind == C.K_REGULAR and s.wires[i] == 0 then
				any[#any + 1] = o
				if s.floor[i] == 0 and not B.goal_open(s, C.GOAL_COLLECT, o.color) then
					cands[#cands + 1] = o
				end
			end
		end
		if #cands == 0 then cands = any end
		local special, axis = 0, 0
		if item == C.IT_PRE_RIFF then
			riffs = riffs + 1
			special = C.SP_RIFF
			axis = (riffs % 2 == 1) and C.AX_H or C.AX_V
		elseif item == C.IT_PRE_SUB then
			special = C.SP_SUB
		else
			special = C.SP_DISCO
		end
		if #cands == 0 then
			s.unplaced[#s.unplaced + 1] = item
		else
			local o = cands[R.int(st, #cands)]
			o.kind = C.K_SPECIAL
			o.special = special
			o.axis = axis
			o.color = 0
		end
	end
end

-- Builds the start board into a fresh state. Returns the state and a report
-- {fills = n, shuffle = item reached by the start shuffle (0 = none),
--  dirty = bool}. `boosters`: pre-level item codes (4.5).
function ST.build(level, seed, boosters)
	local s = B.new_state(level)
	s.rng = R.streams(seed)
	local st = s.rng[R.INIT]
	place_fixed(s)
	local free = {}
	for i = 1, s.N do
		if s.exists[i] and s.slot[i] == 0 then free[#free + 1] = i end
	end
	local report = { fills = 0, shuffle = 0, dirty = false }
	local passed = false
	for n = 1, C.START_FILLS do
		if n > 1 then unfill(s, free) end
		fill(s, st, free)
		report.fills = n
		if not M.any_match(M.color_map(s), s.W, s.H) and #MV.pair_list(s) >= 3 then
			passed = true
			break
		end
	end
	if not passed then
		local res = SH.run(s, st)
		report.shuffle = res.item == 0 and 4 or res.item
		if M.any_match(M.color_map(s), s.W, s.H) then report.dirty = true end
	end
	assign_ids(s)
	-- microphones on the board at the start
	local mics = 0
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.kind == C.K_MIC then mics = mics + 1 end
	end
	s.released, s.on_board = mics, mics
	if level.mic then
		s.last_mic = mics > 0 and 0 or -level.mic.gap_moves
	end
	place_boosters(s, st, boosters or {})
	s.dirty = report.dirty
	s.rest_flag = not report.dirty
	return s, report
end

return ST
