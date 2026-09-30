-- In-level boosters (5.3): execution of the `booster` record (kind 8).

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local H = require("core.hits")
local R = require("core.rng")
local SH = require("core.shuffle")
local EF = require("core.effects")
local sched = require("core.sched")

local BO = {}

-- "Cell with an effect" of 5.3.
function BO.has_effect(s, i)
	if not s.exists[i] then return false end
	if s.wires[i] > 0 then return true end
	local o = B.get(s, i)
	if o then
		local k = o.kind
		return k == C.K_BLOCKER or k == C.K_REGULAR or k == C.K_SPECIAL
	end
	return s.floor[i] > 0
end

function BO.line_has_effect(s, code, n)
	if code == C.IT_ROW then
		for x = 1, s.W do
			if BO.has_effect(s, (n - 1) * s.W + x) then return true end
		end
	else
		for y = 1, s.H do
			if BO.has_effect(s, (y - 1) * s.W + n) then return true end
		end
	end
	return false
end

-- Record data: {booster code, target (cell, row or column; 0 for Remix), mv, wv}.
function BO.run(s, rec)
	local code, target, mv, wv = rec.d[1], rec.d[2], rec.d[3], rec.d[4]
	local now = s.now
	local T = B.T(s)
	local src = H.new_source(s, C.SRC_EFFECT, mv, wv, 0)
	local ev = { booster = C.BOOSTER_NAME[code], ok = true }
	if code == C.IT_STICK then
		local x, y = U.xy(s.W, target)
		ev.at = { x, y }
		E.emit(s, "booster", ev)
		H.hit(s, target, src)
	elseif code == C.IT_ROW or code == C.IT_COL then
		local acts = {}
		if code == C.IT_ROW then
			ev.row = target
			E.emit(s, "booster", ev)
			E.emit(s, "bolt", { x = 1, y = target, dir = "r", at = now })
			for x = 1, s.W do
				local i = (target - 1) * s.W + x
				if s.exists[i] then acts[#acts + 1] = { now + T.light_step * (x - 1), C.R_HIT, { src.id, i } } end
			end
		else
			ev.col = target
			E.emit(s, "booster", ev)
			E.emit(s, "bolt", { x = target, y = 1, dir = "d", at = now })
			for y = 1, s.H do
				local i = (y - 1) * s.W + target
				if s.exists[i] then acts[#acts + 1] = { now + T.light_step * (y - 1), C.R_HIT, { src.id, i } } end
			end
		end
		EF.run(s, src, acts, true)
	else -- remix
		if #SH.candidates(s) < 2 then
			ev.ok = false
			E.emit(s, "booster", ev)
			s.unplaced[#s.unplaced + 1] = C.IT_REMIX
		else
			E.emit(s, "booster", ev)
			local res = SH.run(s, s.rng[R.SHUFFLE])
			SH.apply_result(s, res)
		end
	end
	sched.retire_if_done(s, src)
end

return BO
