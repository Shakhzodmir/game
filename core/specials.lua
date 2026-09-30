-- Special activation (7.2, section 8): the `activate` record, the single
-- specials and the Disco ball. Registers the record handlers of the effect
-- framework (core/effects.lua); the Bird lives in core/bird.lua, the combos
-- in core/combos.lua.
--
-- Lifecycle (7.2): a launched special is `armed` at once and waits in its
-- cell (gravity: wait; hits: open slot) until the activation record runs.
-- Its source is created at the start of that record (label of the launch,
-- own = the special, centre = its cell); the first hit of the source on
-- its centre removes it (`clear`, cause `fired`).

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local H = require("core.hits")
local EF = require("core.effects")
local BD = require("core.bird")
local CB = require("core.combos")
local sched = require("core.sched")

local SP = {}

local K_REGULAR, K_SPECIAL, K_BLOCKER = C.K_REGULAR, C.K_SPECIAL, C.K_BLOCKER
local S_IDLE, S_ARMED = C.S_IDLE, C.S_ARMED

-- Disco (8.4) in `cell` with colour X (0 = choose mf() now).
function SP.disco(s, src, o, cell, X)
	local t0 = s.now
	local NT = EF.NT
	if X == 0 then X = B.most_frequent(s, false) end
	EF.activate_event(s, o.id, cell, C.SP_DISCO, 0, { color = X ~= 0 and C.COLOR_NAME[X] or nil })
	local x, y = U.xy(s.W, cell)
	local L = {}
	if X ~= 0 then
		for i = 1, s.N do
			local p = B.get(s, i)
			if p and p.cell == i and p.state == S_IDLE and p.color == X
				and ((p.kind == K_REGULAR and p.pins[1] == nil)
					or (p.kind == K_BLOCKER and p.blocker == C.BK_BALLOON)) then
				local px, py = U.xy(s.W, i)
				L[#L + 1] = { math.max(math.abs(px - x), math.abs(py - y)), p }
			end
		end
		U.stable_sort(L, function(e) return e[1] end)
	end
	for k = 1, #L do
		local p = L[k][2]
		if p.kind == K_REGULAR then B.pin(p, src.id) end
	end
	-- natural order: steps by k, then own cell
	local acts = {}
	for k = 1, #L do
		acts[k] = { EF.at(s, t0, NT.disco_step * (k - 1)), C.R_DISCO, { src.id, k - 1, L[k][2].id } }
	end
	acts[#acts + 1] = { EF.at(s, t0, NT.disco_step * #L), C.R_HIT, { src.id, cell } }
	EF.run(s, src, acts, false)
end

-- Record kind 3: Disco step k, {source, k, object id}.
function SP.disco_step(s, d)
	local src = s.sources[d[1]]
	local p = s.objs[d[3]]
	if not p then return end
	local live
	if p.kind == K_BLOCKER then
		live = p.blocker == C.BK_BALLOON and p.state == S_IDLE
	else
		live = B.is_pinned_by(p, src.id)
	end
	if not live then return end
	local fx, fy = U.xy(s.W, src.centre)
	local tx, ty = U.xy(s.W, p.cell)
	E.emit(s, "disco_ray", { x = fx, y = fy, tx = tx, ty = ty })
	H.hit(s, p.cell, src)
end

-- Record kind 1: {id, cell, partner cell, mv, wv, X}. Nothing unless the
-- object is an armed special.
function SP.activate(s, d)
	local o = s.objs[d[1]]
	if not o or o.kind ~= K_SPECIAL or o.state ~= S_ARMED then return end
	local cell = o.cell
	local src = H.new_source(s, C.SRC_EFFECT, d[4], d[5], 0)
	src.own = { o.id }
	src.centre = cell
	local partner = d[3]
	if partner ~= 0 then
		local po = B.get(s, partner)
		if po and po ~= o and po.kind == K_SPECIAL and po.state == S_ARMED then
			src.own[2] = po.id
			CB.run(s, src, o, po)
			sched.retire_if_done(s, src)
			return
		end
	end
	local sp = o.special
	if sp == C.SP_RIFF then
		EF.activate_event(s, o.id, cell, sp, o.axis, nil)
		EF.riff(s, src, cell, o.axis)
	elseif sp == C.SP_SUB then
		EF.activate_event(s, o.id, cell, sp, 0, nil)
		EF.sub(s, src, cell, 2)
	elseif sp == C.SP_DISCO then
		SP.disco(s, src, o, cell, d[6])
	else
		EF.activate_event(s, o.id, cell, sp, 0, nil)
		BD.single(s, src, cell)
	end
	sched.retire_if_done(s, src)
end

-- Record handlers (kinds 1-5), used by the tick and by EF.run.
EF.handlers[C.R_ACTIVATE] = SP.activate
EF.handlers[C.R_HIT] = function(s, d) H.hit(s, d[2], s.sources[d[1]]) end
EF.handlers[C.R_DISCO] = SP.disco_step
EF.handlers[C.R_TRANSFORM] = CB.transform
EF.handlers[C.R_BIRD] = BD.impact

return SP
