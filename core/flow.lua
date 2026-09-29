-- Rest, end of move, noise growth (section 11), final concert (section 13).

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local R = require("core.rng")
local H = require("core.hits")
local MV = require("core.moves")
local SH = require("core.shuffle")
local sched = require("core.sched")

local F = {}

local S_IDLE = C.S_IDLE

-- Board at rest (section 11).
function F.is_stable(s)
	if s.dirty or s.last_assign > 0 or s.queue[1] ~= nil then return false end
	local slot, objs = s.slot, s.objs
	for i = 1, s.N do
		local id = slot[i]
		if id ~= 0 and objs[id].state ~= S_IDLE then return false end
	end
	return true
end

-- Noise growth (11, step 8 in playing).
local function noise_growth(s)
	local q = s.eom
	if #q == 0 then return end
	local credited, inq = {}, {}
	for k = 1, #q do inq[q[k].a] = true end
	for k = #q, 1, -1 do
		local e = q[k]
		credited[e.a] = e.noise_hit or (e.merged ~= 0 and inq[e.merged] == true and credited[e.merged] == true)
	end
	local W, Hh = s.W, s.H
	for k = 1, #q do
		if not credited[q[k].a] then
			local pairs_ = {}
			for i = 1, s.N do
				local o = B.get(s, i)
				if o and o.kind == C.K_BLOCKER and o.blocker == C.BK_NOISE and o.state == S_IDLE then
					local x, y = U.xy(W, i)
					local nb = { y > 1 and i - W or 0, x > 1 and i - 1 or 0, x < W and i + 1 or 0, y < Hh and i + W or 0 }
					for j = 1, 4 do
						local n = nb[j]
						if n ~= 0 and not s.spawner[n] and s.wires[n] == 0 then
							local p = B.get(s, n)
							if p and p.kind == C.K_REGULAR and p.state == S_IDLE then
								pairs_[#pairs_ + 1] = { i, n }
							end
						end
					end
				end
			end
			if #pairs_ > 0 then
				local pr = pairs_[R.int(s.rng[R.EFFECTS], #pairs_)]
				local p = B.get(s, pr[2])
				p.kind = C.K_BLOCKER
				p.blocker = C.BK_NOISE
				p.hp = 1
				p.color = 0
				p.pins = {}
				local fx, fy = U.xy(W, pr[1])
				local x, y = U.xy(W, pr[2])
				E.emit(s, "noise_spread", { fx = fx, fy = fy, x = x, y = y, id = p.id })
			end
		end
	end
end
F.noise_growth = noise_growth

-- won_wait -> concert (13.2).
local function start_concert(s)
	local T = B.T(s)
	local now = s.now
	s.moves_at_win = s.moves_left
	local n = s.moves_left
	s.concert_A = s.act
	s.rounds = 0
	s.eom = {}
	s.tc = now
	E.set_state(s, C.G_CONCERT)
	for k = 1, n do
		sched.push(s, now + T.concert_step * k, C.R_CONCERT_A, { k })
	end
	sched.push(s, now + T.concert_step * n + T.fire_step, C.R_CONCERT_B, {})
end

-- Phase A, step k (13.3).
function F.concert_a(s, k)
	s.moves_left = s.moves_left - 1
	E.emit(s, "moves", { left = s.moves_left })
	local cands = {}
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.kind == C.K_REGULAR and o.state == S_IDLE and o.pins[1] == nil and s.wires[i] == 0 then
			cands[#cands + 1] = o
		end
	end
	if #cands == 0 then return end
	local o = cands[R.int(s.rng[R.EFFECTS], #cands)]
	local axis = (k % 2 == 1) and C.AX_H or C.AX_V
	SH.make_riff(o, axis)
	o.mv, o.wv = s.concert_A + 1, 0
	local x, y = U.xy(s.W, o.cell)
	E.emit(s, "concert_riff", { id = o.id, x = x, y = y, axis = C.AXIS_NAME[axis] })
	local acc = H.acc()
	acc.score = C.SCORE_CONCERT
	H.flush(s, acc, o.cell)
end

-- Phase B (13.4).
function F.concert_b(s)
	local T = B.T(s)
	s.rounds = s.rounds + 1
	local list = {}
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.kind == C.K_SPECIAL and o.state == S_IDLE and o.pins[1] == nil then
			list[#list + 1] = o
		end
	end
	for k = 1, #list do B.set_state(list[k], C.S_ARMED) end
	local mv = s.concert_A + 1
	for k = 1, #list do
		local o = list[k]
		sched.push(s, s.now + T.fire_step * (k - 1), C.R_ACTIVATE, { o.id, o.cell, 0, mv, 1, 0 })
	end
end

-- Step 8 (section 11 and 13).
function F.step8(s)
	if not F.is_stable(s) then
		s.rest_flag = false
		return
	end
	local st = s.state
	if st == C.G_PLAYING then
		noise_growth(s)
		s.eom = {}
		if s.moves_left == 0 then
			E.set_state(s, C.G_OUT)
		elseif not MV.has_move(s) then
			SH.in_game(s)
		end
	elseif st == C.G_WON_WAIT then
		start_concert(s)
	elseif st == C.G_CONCERT then
		if s.rounds < C.CONCERT_MAX_ROUNDS and MV.has_free_special(s) then
			sched.push(s, s.now + B.T(s).fire_step, C.R_CONCERT_B, {})
		else
			E.set_state(s, C.G_COMPLETE)
		end
	end
	s.rest_flag = F.is_stable(s)
end

return F
