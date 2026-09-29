-- Effect framework (7.2.6, 7.2.7) and the geometry shared by the single
-- specials and the combos (section 8).
--
-- An effect builds the full list of its actions in natural order. An
-- action is {tick, kind, data}: `kind` is a record kind of 15.2 (hit,
-- disco_step, transform, bird_impact, activate) and `data` its record data.
-- EF.run() sorts the list stably by tick, keeps the first hit on every
-- object (on every cell for an `all_layers` source), pins the path, runs
-- the actions due at t0 = now at once, in order, inside the activation
-- record, and queues the others, one record per action, in order.
--
-- Natural order. Every effect orders its actions by their offset in normal
-- timing, then by cell index (or the explicit order of section 8). In
-- normal mode the offset is the real delay, so this is "by tick, then by
-- index"; every effect delay of section 14 is 0 in turbo, where the same
-- natural order is kept (turbo changes time only, not the rules).

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local sched = require("core.sched")

local EF = {}

local S_IDLE, R_HIT = C.S_IDLE, C.R_HIT

-- Timings of the natural order (normal mode).
EF.NT = C.T[C.TIMING_NORMAL]

-- Record handlers (s, data) by record kind, registered by core/specials.lua.
-- The tick runs queued records through them, EF.run the actions due now.
EF.handlers = {}

-- Real tick of an action with normal-mode offset n: t0 + n, or t0 in turbo
-- (every effect delay of section 14 is 0 there).
function EF.at(s, t0, n)
	if s.timing == C.TIMING_TURBO then return t0 end
	return t0 + n
end

-- Runs an action list of source src (see the header). `pin_path`: rule
-- 7.2.7 (every idle movable piece in a cell hit later than now is pinned).
function EF.run(s, src, acts, pin_path)
	local t0 = s.now
	U.stable_sort(acts, function(a) return a[1] end)
	local seen, list = {}, {}
	for k = 1, #acts do
		local a = acts[k]
		if a[2] == R_HIT then
			local cell = a[3][2]
			local key = src.all_layers and cell or B.key(s, cell)
			if not seen[key] then
				seen[key] = true
				list[#list + 1] = a
			end
		else
			list[#list + 1] = a
		end
	end
	if pin_path then
		for k = 1, #list do
			local a = list[k]
			if a[2] == R_HIT and a[1] > t0 then
				local o = B.get(s, a[3][2])
				if o and o.state == S_IDLE and B.is_movable(s, o) then B.pin(o, src.id) end
			end
		end
	end
	local handlers = EF.handlers
	for k = 1, #list do
		local a = list[k]
		if a[1] <= t0 then handlers[a[2]](s, a[3]) end
	end
	for k = 1, #list do
		local a = list[k]
		if a[1] > t0 then sched.push(s, a[1], a[2], a[3]) end
	end
end

-- Geometry -----------------------------------------------------------------
-- A geometry is a table cell -> smallest normal-mode offset (the earliest
-- hit on a cell wins, 7.2.6); EF.geo_hits turns it into hit actions in
-- natural order (offset, then cell index).

function EF.geo_add(g, cell, n)
	local old = g[cell]
	if old == nil or n < old then g[cell] = n end
end

function EF.geo_hits(s, src, g, t0, acts)
	local list = {}
	for i = 1, s.N do
		local n = g[i]
		if n then list[#list + 1] = { n, i } end
	end
	U.stable_sort(list, function(e) return e[1] end)
	acts = acts or {}
	for k = 1, #list do
		acts[#acts + 1] = { EF.at(s, t0, list[k][1]), R_HIT, { src.id, list[k][2] } }
	end
	return acts
end

-- Directions of bolts: dx, dy, event name.
EF.DIRS = { { -1, 0, "l" }, { 1, 0, "r" }, { 0, -1, "u" }, { 0, 1, "d" } }
local DIRS = EF.DIRS

-- Existing cells along a ray from (x, y) in direction dir (1..4), distance
-- d = 1.. to the edge of the field (voids are flown through): adds them to
-- geometry g with offset base + R(d).
function EF.ray(s, g, x, y, dir, base)
	local dx, dy = DIRS[dir][1], DIRS[dir][2]
	local W, H = s.W, s.H
	local d = 1
	local cx, cy = x + dx, y + dy
	while cx >= 1 and cx <= W and cy >= 1 and cy <= H do
		local i = (cy - 1) * W + cx
		if s.exists[i] then EF.geo_add(g, i, base + C.R(d, C.TIMING_NORMAL)) end
		d = d + 1
		cx, cy = cx + dx, cy + dy
	end
end

-- Existing cells within Chebyshev distance rmax of cell: offset base + ring*r.
function EF.square(s, g, cell, rmax, base)
	local W, H = s.W, s.H
	local x, y = U.xy(W, cell)
	for yy = y - rmax, y + rmax do
		for xx = x - rmax, x + rmax do
			if xx >= 1 and xx <= W and yy >= 1 and yy <= H then
				local i = (yy - 1) * W + xx
				if s.exists[i] then
					local r = math.max(math.abs(xx - x), math.abs(yy - y))
					EF.geo_add(g, i, base + EF.NT.ring * r)
				end
			end
		end
	end
end

function EF.bolt(s, x, y, dir, at)
	E.emit(s, "bolt", { x = x, y = y, dir = DIRS[dir][3], at = at })
end

-- The `activate` event (first event of an activation). id = nil for cargo.
function EF.activate_event(s, id, cell, special, axis, extra)
	local x, y = U.xy(s.W, cell)
	local ev = { x = x, y = y, special = C.SPECIAL_NAME[special] }
	if id then ev.id = id end
	if axis ~= 0 then ev.axis = C.AXIS_NAME[axis] end
	if extra then
		for k, v in pairs(extra) do ev[k] = v end -- order-independent
	end
	E.emit(s, "activate", ev)
end

-- Single effects shared with cargo and combos ---------------------------------

-- Riff (8.1) from `cell` along `axis`, t0 = now: bolts, own cell at t0,
-- distance d at t0 + R(d); natural order own cell, then d, then index.
function EF.riff(s, src, cell, axis)
	local t0 = s.now
	local x, y = U.xy(s.W, cell)
	local d1, d2 = 1, 2
	if axis == C.AX_V then d1, d2 = 3, 4 end
	EF.bolt(s, x, y, d1, t0)
	EF.bolt(s, x, y, d2, t0)
	local g = {}
	EF.geo_add(g, cell, 0)
	EF.ray(s, g, x, y, d1, 0)
	EF.ray(s, g, x, y, d2, 0)
	EF.run(s, src, EF.geo_hits(s, src, g, t0), true)
end

-- Sabwoofer (8.2) and Bass drop (8.5, rmax 3): swell, then ring r at
-- t0 + sub_swell + ring*r; natural order r, then index.
function EF.sub(s, src, cell, rmax)
	local t0 = s.now
	local NT = EF.NT
	local x, y = U.xy(s.W, cell)
	for r = 0, rmax do
		E.emit(s, "ring", { x = x, y = y, r = r, at = EF.at(s, t0, NT.sub_swell + NT.ring * r) })
	end
	local g = {}
	EF.square(s, g, cell, rmax, NT.sub_swell)
	EF.run(s, src, EF.geo_hits(s, src, g, t0), true)
end

return EF
