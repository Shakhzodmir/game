-- The conveyor belts (10.9): the first element that moves pieces.
--
-- A belt is a path of cells of the level (level.conveyor.belts[b].cells, in
-- the order of travel); it is static level data, so the state holds nothing
-- of its own and the hash has nothing new. For every move spent each belt
-- carries the content of its cells one cell on; the content of the last
-- cell goes to the first. The belts move only in step 8, on a board at rest
-- (flow.lua): every object is idle, nothing is pinned, queued or in flight.
--
-- A belt is jammed, and stays as it is for this move, while one of its
-- cells is under a closed curtain or holds something that does not move: a
-- blocker (a noise that grew onto it) or wires. So the content that rides
-- is always a movable piece or an empty slot, and what belongs to the cell
-- (floor, carpet, spawner, exit, curtain) never moves.
--
-- The riders stand in their new cell at once and are locked (state swap,
-- timer lock, like the pieces of a shuffle) for T.conveyor ticks while the
-- client slides them; when the lock ends in step 2 they are idle again and
-- the board is searched, so the matches the belt made resolve as a cascade.

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")

local CV = {}

-- the step of one cell in a direction of travel: dx, dy by C.DIR_*
local DX = { 1, 0, -1, 0 }
local DY = { 0, 1, 0, -1 }

-- Is the belt jammed now: a cell under a closed curtain, a blocker or wires on it.
function CV.jammed(s, belt)
	local cells = belt.cells
	for k = 1, #cells do
		local i = cells[k]
		if B.veiled(s, i) or s.wires[i] > 0 then return true end
		local o = B.get(s, i)
		if o and o.kind == C.K_BLOCKER then return true end
	end
	return false
end

-- One step of belt number b; the objects it carried are added to `riders`.
local function step(s, b, belt, dur, riders)
	local cells = belt.cells
	local n = #cells
	if CV.jammed(s, belt) then
		E.emit(s, "conveyor", { belt = b, jam = true, moves = {}, duration = 0 })
		return
	end
	local ids = {}
	for k = 1, n do ids[k] = s.slot[cells[k]] end
	local W = s.W
	local moves = {}
	for k = 1, n do
		local id = ids[k]
		local to = cells[k % n + 1]
		s.slot[to] = id
		if id ~= 0 then
			local o = s.objs[id]
			o.cell = to
			local fx, fy = U.xy(W, cells[k])
			local x, y = U.xy(W, to)
			local m = { id = id, fx = fx, fy = fy, x = x, y = y }
			if k == n and not belt.ring then
				-- the jump of an open belt: the rider leaves past the last cell (towards ox, oy) and comes in
				-- from before the first one (from ix, iy); these two places may lie off the board
				m.wrap = true
				m.ox, m.oy = fx + DX[belt.dirs[n]], fy + DY[belt.dirs[n]]
				m.ix, m.iy = x - DX[belt.dirs[1]], y - DY[belt.dirs[1]]
			end
			moves[#moves + 1] = m
			riders[#riders + 1] = o
		end
	end
	if #moves > 0 then
		E.emit(s, "conveyor", { belt = b, moves = moves, duration = dur })
	end
end

-- n moves were spent (the end-of-move queue of step 8): every belt, in the order of the level, makes
-- one step for each of them. Returns true if anything was carried; the riders are then locked for
-- T.conveyor ticks, and step 2 of the tick in which the lock ends searches the board.
function CV.advance(s, n)
	local belts = s.level.conveyor.belts
	local dur = B.T(s).conveyor
	local riders = {}
	for _ = 1, n do
		for b = 1, #belts do step(s, b, belts[b], dur, riders) end
	end
	for k = 1, #riders do
		local o = riders[k]
		B.set_state(o, C.S_SWAP)
		o.tk = C.TM_LOCK
		o.td = s.now + dur
	end
	return #riders > 0
end

return CV
