-- The tick (section 15): step() and the record dispatcher.
--
--   1. commands of window `now` were applied by input() (5.0)
--   2. swap timers (start order), then shuffle locks (by cell); if any
--      expired: match search with rule 6.2.1, refunds (5.1.3)
--   3. queue: every record with due <= now in (due, seq) order, including
--      the ones queued during this step
--   4. objects in clear whose timer expired vanish
--   5. gravity assignment and spawn (10.1)
--   6. movement (10.2)
--   7. match search if the board is dirty; microphone delivery (10.4)
--   8. rest: end of move, noise, shuffle, concert (11, 13); rest_flag

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local H = require("core.hits")
local M = require("core.match")
local G = require("core.gravity")
local F = require("core.flow")
local SP = require("core.specials")
local BO = require("core.boosters")
local I = require("core.input")
local sched = require("core.sched")

local TK = {}

local S_IDLE, S_SWAP, S_CLEAR = C.S_IDLE, C.S_SWAP, C.S_CLEAR

local function to_idle(s, o)
	B.set_state(o, S_IDLE)
	o.tk, o.td = 0, 0
	o.settle = s.now
	s.dirty = true
end

local function exchange(s, from, to)
	local a, b = B.get(s, from), B.get(s, to)
	B.place(s, a, to)
	B.place(s, b, from)
	return b, a -- pieces now in from, to
end

-- Refund of a swap whose cells joined no group (5.1.3).
local function refund(s, sw)
	local T = B.T(s)
	local pf, pt = B.get(s, sw.from), B.get(s, sw.to)
	-- pt came from `from`, pf came from `to`
	pt.mv, pt.wv = sw.m1, sw.w1
	pf.mv, pf.wv = sw.m2, sw.w2
	local back = I.start_swap(s, C.TM_BACK, sw.a, sw.from, sw.to, T.swap, pf, pt)
	back.m1, back.w1, back.m2, back.w2 = sw.m1, sw.w1, sw.m2, sw.w2
	back.special = false
	s.moves_left = s.moves_left + 1
	s.moves_made = s.moves_made - 1
	local q = s.eom
	for k = 1, #q do
		if q[k].a == sw.a then
			table.remove(q, k)
			break
		end
	end
	I.swap_event(s, "swap_back", sw.from, sw.to, pf, pt, T.swap)
	E.emit(s, "moves", { left = s.moves_left })
end

-- Launch after a swap with a special (5.1.4).
local function launch_after_swap(s, sw)
	local pf, pt = B.get(s, sw.from), B.get(s, sw.to)
	local a = sw.a
	if pf.kind == C.K_SPECIAL and pt.kind == C.K_SPECIAL then
		B.set_state(pt, C.S_ARMED)
		B.set_state(pf, C.S_ARMED)
		sched.push(s, s.now, C.R_ACTIVATE, { pt.id, sw.to, sw.from, a, 1, 0 })
		return
	end
	local sp, other = pt, pf
	if pf.kind == C.K_SPECIAL then sp, other = pf, pt end
	B.set_state(sp, C.S_ARMED)
	local X = 0
	if sp.special == C.SP_DISCO and other.kind == C.K_REGULAR then X = other.color end
	sched.push(s, s.now, C.R_ACTIVATE, { sp.id, sp.cell, 0, a, 1, X })
end

local function step2(s)
	local now = s.now
	local fired = false
	local expiring, keep = {}, {}
	for k = 1, #s.swaps do
		local sw = s.swaps[k]
		if sw.due <= now then expiring[#expiring + 1] = sw else keep[#keep + 1] = sw end
	end
	s.swaps = keep
	local finished = {}
	for k = 1, #expiring do
		local sw = expiring[k]
		fired = true
		if sw.kind == C.TM_SWAP then
			local pf, pt = exchange(s, sw.from, sw.to)
			pf.mv, pf.wv, pt.mv, pt.wv = sw.a, 0, sw.a, 0
			to_idle(s, pf)
			to_idle(s, pt)
			if sw.special then launch_after_swap(s, sw) end
			finished[#finished + 1] = sw
		elseif sw.kind == C.TM_FAIL then
			to_idle(s, B.get(s, sw.from))
			to_idle(s, B.get(s, sw.to))
		else -- swap_back
			local pf, pt = exchange(s, sw.from, sw.to)
			to_idle(s, pf)
			to_idle(s, pt)
		end
	end
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.cell == i and o.tk == C.TM_LOCK and o.td <= now then
			to_idle(s, o)
			fired = true
		end
	end
	if not fired then return end
	table.sort(finished, function(a, b) return a.a < b.a end)
	local resolved = M.search(s, finished)
	for k = 1, #finished do
		local sw = finished[k]
		if not sw.special and not resolved[sw.from] and not resolved[sw.to] then
			refund(s, sw)
		end
	end
end

local function owner(s, rec)
	local src = s.sources[rec.d[1]]
	src.nrec = src.nrec - 1
	return src
end

local function exec(s, rec)
	local k = rec.kind
	if k == C.R_ACTIVATE then
		SP.activate(s, rec)
	elseif k == C.R_HIT then
		local src = owner(s, rec)
		H.hit(s, rec.d[2], src)
		sched.retire_if_done(s, src)
	elseif k == C.R_DISCO then
		local src = owner(s, rec)
		SP.disco_step(s, rec.d)
		sched.retire_if_done(s, src)
	elseif k == C.R_TRANSFORM then
		local src = owner(s, rec)
		SP.transform(s, rec.d)
		sched.retire_if_done(s, src)
	elseif k == C.R_BIRD then
		local src = owner(s, rec)
		SP.bird_impact(s, rec.d)
		sched.retire_if_done(s, src)
	elseif k == C.R_CONCERT_A then
		F.concert_a(s, rec.d[1])
	elseif k == C.R_CONCERT_B then
		F.concert_b(s)
	elseif k == C.R_BOOSTER then
		BO.run(s, rec)
	end
end

local function step3(s)
	local now = s.now
	local n = 0
	while true do
		local rec = sched.pop_due(s, now)
		if not rec then break end
		n = n + 1
		if n > C.MAX_RECORDS_PER_TICK then
			error("core: more than " .. C.MAX_RECORDS_PER_TICK .. " records in one tick (bug)")
		end
		exec(s, rec)
	end
end

local function step4(s)
	local now = s.now
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.cell == i and o.state == S_CLEAR and o.td <= now then
			B.remove(s, o)
		end
	end
end

local function deliver_mics(s)
	if not s.level.mic then return end
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.kind == C.K_MIC and o.state == S_IDLE and s.exit[i] then
			H.start_clear(s, o)
			B.set_vac(s, i, o.mv, o.wv)
			s.on_board = s.on_board - 1
			local x, y = U.xy(s.W, i)
			E.emit(s, "mic_delivered", { id = o.id, x = x, y = y })
			local acc = H.acc()
			H.goal(s, acc, C.GOAL_DELIVER, 0, 1)
			H.flush(s, acc, i)
		end
	end
end

function TK.step(s)
	s.tick = s.tick + 1
	s.now = s.tick
	s.phase = 2
	step2(s)
	s.phase = 3
	step3(s)
	s.phase = 4
	step4(s)
	s.phase = 5
	G.assign(s)
	s.phase = 6
	G.move(s)
	s.phase = 7
	if s.dirty then M.search(s, nil) end
	deliver_mics(s)
	s.phase = 8
	F.step8(s)
	s.phase = 0
end

return TK
