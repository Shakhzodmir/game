-- Commands (section 5): validation, acceptance, the turbo switch.
--
-- A command runs between ticks with now = tick + 1. It never hits: it
-- checks, changes states and counters and queues records due now.

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local R = require("core.rng")
local MV = require("core.moves")
local SH = require("core.shuffle")
local BO = require("core.boosters")
local sched = require("core.sched")

local I = {}

local K_REGULAR, K_SPECIAL, K_BLOCKER = C.K_REGULAR, C.K_SPECIAL, C.K_BLOCKER
local S_IDLE, S_SWAP, S_ARMED = C.S_IDLE, C.S_SWAP, C.S_ARMED

-- {x, y} or {x = , y = } with integer values -> x, y; else nil.
local function coord(v)
	if type(v) ~= "table" then return nil end
	local x, y = v[1], v[2]
	if x == nil and y == nil then x, y = v.x, v.y end
	if not U.is_int(x) or not U.is_int(y) then return nil end
	return x, y
end

local function in_field(s, x, y)
	return x >= 1 and x <= s.W and y >= 1 and y <= s.H
end

-- Cell checks of 5.1.1 after the common checks. Returns
--   "tap", from | "swap", from, to, "ok"/"fail" | nil, reason
function I.swap_target(s, fx, fy, tx, ty)
	local W = s.W
	local dx, dy = tx - fx, ty - fy
	if not B.exists_xy(s, fx, fy) or (dx * dx + dy * dy) ~= 1 then return nil, "bad_cell" end
	local from = (fy - 1) * W + fx
	local of = B.get(s, from)
	if of and of.kind == K_SPECIAL and B.is_free(s, of) then
		local swipe = false
		if not in_field(s, tx, ty) or not s.exists[(ty - 1) * W + tx] then
			swipe = true
		else
			local ot = B.get(s, (ty - 1) * W + tx)
			if ot == nil or (ot.kind == K_BLOCKER and ot.state == S_IDLE)
				or (ot.kind == K_REGULAR and s.wires[ot.cell] > 0) then
				swipe = true
			end
		end
		if swipe then return "tap", from end
	end
	if not B.exists_xy(s, tx, ty) then return nil, "bad_cell" end
	local to = (ty - 1) * W + tx
	local ot = B.get(s, to)
	if not (of and B.is_free(s, of)) or not (ot and B.is_free(s, ot)) then return nil, "not_movable" end
	return "swap", from, to, MV.eval_pair(s, MV.expected_colors(s), from, to)
end

-- Common checks of swap/tap (5.0): state, moves, input_lock.
local function play_checks(s)
	if s.state ~= C.G_PLAYING then return "bad_state" end
	if s.moves_left == 0 then return "no_moves" end
	if s.input_lock and not s.rest_flag then return "not_rest" end
	return nil
end

local function spend_move(s)
	s.act = s.act + 1
	s.moves_left = s.moves_left - 1
	s.moves_made = s.moves_made + 1
	s.eom[#s.eom + 1] = { a = s.act, noise_hit = false, merged = 0 }
	s.rest_flag = false
	return s.act
end

local function accept_tap(s, cell)
	local a = spend_move(s)
	E.emit(s, "moves", { left = s.moves_left })
	local o = B.get(s, cell)
	B.set_state(o, S_ARMED)
	sched.push(s, s.now, C.R_ACTIVATE, { o.id, cell, 0, a, 1, 0 })
end

local function start_swap(s, kind, a, from, to, dur, oa, ob)
	local due = s.now + dur
	local sw = { kind = kind, a = a, from = from, to = to, m1 = 0, w1 = 0, m2 = 0, w2 = 0, due = due }
	if kind ~= C.TM_FAIL then
		sw.m1, sw.w1, sw.m2, sw.w2 = oa.mv, oa.wv, ob.mv, ob.wv
		sw.special = oa.kind == K_SPECIAL or ob.kind == K_SPECIAL
	end
	s.swaps[#s.swaps + 1] = sw
	for _, o in ipairs({ oa, ob }) do
		B.set_state(o, S_SWAP)
		o.tk, o.td = kind, due
	end
	return sw
end
I.start_swap = start_swap

local function swap_event(s, ty, from, to, oa, ob, dur)
	local ax, ay = U.xy(s.W, from)
	local bx, by = U.xy(s.W, to)
	E.emit(s, ty, { a = { ax, ay }, b = { bx, by }, ids = { oa.id, ob.id }, duration = dur })
end
I.swap_event = swap_event

local function do_swap(s, cmd)
	local fx, fy = coord(cmd.from)
	local tx, ty = coord(cmd.to)
	if not fx or not tx then return false, "bad_cmd" end
	local why = play_checks(s)
	if why then return false, why end
	local what, from, to, res = I.swap_target(s, fx, fy, tx, ty)
	if not what then return false, from end
	if what == "tap" then
		accept_tap(s, from)
		return true, "ok"
	end
	local T = B.T(s)
	local oa, ob = B.get(s, from), B.get(s, to)
	if res == "fail" then
		s.rest_flag = false
		start_swap(s, C.TM_FAIL, 0, from, to, T.swap_fail, oa, ob)
		swap_event(s, "swap_fail", from, to, oa, ob, T.swap_fail)
		return true, "fail"
	end
	local a = spend_move(s)
	start_swap(s, C.TM_SWAP, a, from, to, T.swap, oa, ob)
	swap_event(s, "swap", from, to, oa, ob, T.swap)
	E.emit(s, "moves", { left = s.moves_left })
	return true, "ok"
end

local function do_tap(s, cmd)
	local x, y = coord(cmd.at)
	if not x then return false, "bad_cmd" end
	local why = play_checks(s)
	if why then return false, why end
	if not B.exists_xy(s, x, y) then return false, "bad_cell" end
	local cell = (y - 1) * s.W + x
	local o = B.get(s, cell)
	if not (o and o.kind == K_SPECIAL and o.state == S_IDLE and o.pins[1] == nil) then
		return false, "not_movable"
	end
	accept_tap(s, cell)
	return true, "ok"
end

local function do_booster(s, cmd)
	local code = type(cmd.booster) == "string" and C.BOOSTER[cmd.booster] or nil
	if not code then return false, "bad_cmd" end
	local target, x, y = 0, nil, nil
	if code == C.IT_STICK then
		x, y = coord(cmd.at)
		if not x then return false, "bad_cmd" end
	elseif code == C.IT_ROW then
		if not U.is_int(cmd.row) or cmd.row < 1 or cmd.row > s.H then return false, "bad_cmd" end
		target = cmd.row
	elseif code == C.IT_COL then
		if not U.is_int(cmd.col) or cmd.col < 1 or cmd.col > s.W then return false, "bad_cmd" end
		target = cmd.col
	end
	if s.state ~= C.G_PLAYING and s.state ~= C.G_OUT then return false, "bad_state" end
	if not s.rest_flag then return false, "not_rest" end
	if code == C.IT_STICK then
		if not B.exists_xy(s, x, y) then return false, "bad_cell" end
		target = (y - 1) * s.W + x
		if not BO.has_effect(s, target) then return false, "bad_cell" end
	elseif code == C.IT_ROW or code == C.IT_COL then
		if not BO.line_has_effect(s, code, target) then return false, "bad_cell" end
	else
		if #SH.candidates(s) < 2 then return false, "no_candidates" end
	end
	if s.state == C.G_OUT then E.set_state(s, C.G_PLAYING) end
	s.act = s.act + 1
	s.rest_flag = false
	sched.push(s, s.now, C.R_BOOSTER, { code, target, s.act, 1 })
	return true, "ok"
end

local function do_continue(s, cmd)
	local n = cmd.moves
	if not U.is_int(n) or n < 1 or n > 60 then return false, "bad_cmd" end
	if cmd.riff ~= nil and type(cmd.riff) ~= "boolean" then return false, "bad_cmd" end
	if s.state ~= C.G_OUT then return false, "bad_state" end
	if s.stuck then return false, "no_candidates" end
	s.moves_left = s.moves_left + n
	E.emit(s, "moves", { left = s.moves_left })
	if cmd.riff then
		local cands = {}
		for i = 1, s.N do
			local o = B.get(s, i)
			if o and o.kind == K_REGULAR and o.state == S_IDLE and s.wires[i] == 0 then cands[#cands + 1] = o end
		end
		if #cands == 0 then
			s.unplaced[#s.unplaced + 1] = C.IT_CONT_RIFF
		else
			local o = cands[R.int(s.rng[R.INIT], #cands)]
			SH.make_riff(o, C.AX_H)
			local x, y = U.xy(s.W, o.cell)
			E.emit(s, "continue_riff", { id = o.id, x = x, y = y })
		end
	end
	E.set_state(s, C.G_PLAYING)
	return true, "ok"
end

-- Switch to turbo between ticks (15.1.8).
function I.switch_turbo(s)
	local now = s.tick + 1
	s.timing = C.TIMING_TURBO
	local slot, objs = s.slot, s.objs
	for i = 1, s.N do
		local id = slot[i]
		if id ~= 0 then
			local o = objs[id]
			if o.cell == i then
				if o.tk ~= 0 then
					local lim = now + C.TURBO_TIMER[o.tk]
					if o.td > lim then o.td = lim end
				end
				if o.state == C.S_FALL then o.delay = 0 end
			end
		end
	end
	for k = 1, #s.swaps do
		local sw = s.swaps[k]
		local lim = now + C.TURBO_TIMER[sw.kind]
		if sw.due > lim then sw.due = lim end
	end
	sched.retime_turbo(s, now)
end

local HANDLERS = {
	swap = do_swap,
	tap = do_tap,
	booster = do_booster,
	["continue"] = do_continue,
	give_up = function(s)
		if s.state ~= C.G_OUT then return false, "bad_state" end
		E.set_state(s, C.G_LOST)
		return true, "ok"
	end,
	skip = function(s)
		if s.state ~= C.G_WON_WAIT and s.state ~= C.G_CONCERT then return false, "bad_state" end
		I.switch_turbo(s)
		return true, "ok"
	end,
}

-- game:input(cmd) (5.0). Accepted commands are appended to the replay.
function I.input(s, cmd)
	if type(cmd) ~= "table" or type(cmd.type) ~= "string" then return false, "bad_cmd" end
	local h = HANDLERS[cmd.type]
	if not h then return false, "bad_cmd" end
	s.now = s.tick + 1
	s.phase = 0
	local ok, res = h(s, cmd)
	if ok then
		s.cmds[#s.cmds + 1] = { tick = s.now, cmd = U.deepcopy(cmd) }
	end
	return ok, res
end

-- can_swap (17.3): 'ok' | 'fail' | 'reject', without changing anything.
function I.can_swap(s, from, to)
	local fx, fy = coord(from)
	local tx, ty = coord(to)
	if not fx or not tx then return "reject" end
	if play_checks(s) then return "reject" end
	local what, _, _, res = I.swap_target(s, fx, fy, tx, ty)
	if not what then return "reject" end
	if what == "tap" then return "ok" end
	return res
end

return I
