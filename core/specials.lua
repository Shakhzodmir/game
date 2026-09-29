-- Special activation (7.2, section 8): the effect framework and the single
-- effects. Bird targeting (section 9) lives in core/bird.lua.
--
-- An effect builds its full action list in natural order, sorts it stably
-- by tick, drops repeated objects, pins the path (7.2.7), runs the actions
-- due at t0 inside the activation record and queues the rest, one record
-- per action (7.2.6).

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local H = require("core.hits")
local sched = require("core.sched")

local SP = {}

local K_SPECIAL, S_ARMED, S_IDLE = C.K_SPECIAL, C.S_ARMED, C.S_IDLE

-- Actions: {tick, cell} hits (only `hit` actions are built here).

-- Runs a hit list for src: sort by tick (stable), dedup by object key (by
-- cell for all_layers), pin the path, execute t0 hits, queue the others.
function SP.run_hits(s, src, actions, t0)
	U.stable_sort(actions, function(a) return a[1] end)
	local seen, list = {}, {}
	for k = 1, #actions do
		local a = actions[k]
		local key = src.all_layers and a[2] or B.key(s, a[2])
		if not seen[key] then
			seen[key] = true
			list[#list + 1] = a
		end
	end
	for k = 1, #list do
		local a = list[k]
		if a[1] > t0 then
			local o = B.get(s, a[2])
			if o and o.state == S_IDLE and B.is_movable(s, o) then B.pin(o, src.id) end
		end
	end
	for k = 1, #list do
		local a = list[k]
		if a[1] <= t0 then
			H.hit(s, a[2], src)
		else
			sched.push(s, a[1], C.R_HIT, { src.id, a[2] })
		end
	end
end

local DIRS = { { -1, 0, "l" }, { 1, 0, "r" }, { 0, -1, "u" }, { 0, 1, "d" } }

-- Cells along a ray from (x, y) in direction (dx, dy), distance d = 1..,
-- existing cells only (voids are flown through, to the edge).
local function ray(s, x, y, dx, dy, fn)
	local d = 1
	local cx, cy = x + dx, y + dy
	while cx >= 1 and cx <= s.W and cy >= 1 and cy <= s.H do
		local i = (cy - 1) * s.W + cx
		if s.exists[i] then fn(d, i) end
		d = d + 1
		cx, cy = cx + dx, cy + dy
	end
end

local function activate_event(s, o, cell, extra)
	local x, y = U.xy(s.W, cell)
	local ev = { x = x, y = y, special = C.SPECIAL_NAME[o.special] }
	if o.id then ev.id = o.id end
	if o.axis ~= 0 then ev.axis = C.AXIS_NAME[o.axis] end
	if extra then
		for k, v in pairs(extra) do ev[k] = v end -- order-independent
	end
	E.emit(s, "activate", ev)
end

-- Riff (8.1) from `cell` along `axis`.
function SP.riff(s, src, cell, axis, t0)
	local x, y = U.xy(s.W, cell)
	local acts = { { t0, cell } }
	local dirs = axis == C.AX_H and { DIRS[1], DIRS[2] } or { DIRS[3], DIRS[4] }
	for k = 1, 2 do
		E.emit(s, "bolt", { x = x, y = y, dir = dirs[k][3], at = t0 })
	end
	-- natural order: own cell, then by d, equal d -> smaller index
	local byd = {}
	for k = 1, 2 do
		ray(s, x, y, dirs[k][1], dirs[k][2], function(d, i)
			byd[#byd + 1] = { d, i }
		end)
	end
	table.sort(byd, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
	for k = 1, #byd do
		acts[#acts + 1] = { t0 + C.R(byd[k][1], s.timing), byd[k][2] }
	end
	SP.run_hits(s, src, acts, t0)
end

-- Sabwoofer (8.2): rings r = 0..rmax (Chebyshev), from t0 + swell.
function SP.sub(s, src, cell, t0, rmax)
	local T = B.T(s)
	local x, y = U.xy(s.W, cell)
	for r = 0, rmax do
		E.emit(s, "ring", { x = x, y = y, r = r, at = t0 + T.sub_swell + T.ring * r })
	end
	local acts = {}
	for r = 0, rmax do
		for yy = y - r, y + r do
			for xx = x - r, x + r do
				if (math.abs(xx - x) == r or math.abs(yy - y) == r)
					and xx >= 1 and xx <= s.W and yy >= 1 and yy <= s.H then
					local i = (yy - 1) * s.W + xx
					if s.exists[i] then acts[#acts + 1] = { r, i } end
				end
			end
		end
	end
	table.sort(acts, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
	for k = 1, #acts do
		acts[k] = { t0 + T.sub_swell + T.ring * acts[k][1], acts[k][2] }
	end
	SP.run_hits(s, src, acts, t0)
end

-- Disco (8.4).
function SP.disco(s, src, o, cell, X, t0)
	local T = B.T(s)
	if X == 0 then X = B.most_frequent(s, false) end
	activate_event(s, o, cell, { color = X ~= 0 and C.COLOR_NAME[X] or nil })
	local x, y = U.xy(s.W, cell)
	local L = {}
	if X ~= 0 then
		for i = 1, s.N do
			local p = B.get(s, i)
			if p and p.state == S_IDLE and p.cell == i then
				local ok = false
				if p.kind == C.K_REGULAR and p.color == X and p.pins[1] == nil then ok = true end
				if p.kind == C.K_BLOCKER and p.blocker == C.BK_BALLOON and p.color == X then ok = true end
				if ok then
					local px, py = U.xy(s.W, i)
					local d = math.max(math.abs(px - x), math.abs(py - y))
					L[#L + 1] = { d, i, p }
				end
			end
		end
		table.sort(L, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
	end
	for k = 1, #L do
		local p = L[k][3]
		if p.kind == C.K_REGULAR then B.pin(p, src.id) end
	end
	-- natural order: steps by k, then own cell
	for k = 1, #L do
		local due = t0 + T.disco_step * (k - 1)
		local d = { src.id, k - 1, L[k][3].id }
		if due <= t0 then
			SP.disco_step(s, d)
		else
			sched.push(s, due, C.R_DISCO, d)
		end
	end
	local own_due = t0 + T.disco_step * #L
	if own_due <= t0 then
		H.hit(s, cell, src)
	else
		sched.push(s, own_due, C.R_HIT, { src.id, cell })
	end
end

-- Disco step k (record kind 3): data {source, k, object id}.
function SP.disco_step(s, d)
	local src = s.sources[d[1]]
	local p = s.objs[d[3]]
	if not p then return end
	local live
	if p.kind == C.K_BLOCKER then
		live = p.blocker == C.BK_BALLOON and p.state == S_IDLE
	else
		live = B.is_pinned_by(p, src.id)
	end
	if not live then return end
	local own = s.objs[src.own[1] or 0]
	local fx, fy
	if own then fx, fy = U.xy(s.W, own.cell) else fx, fy = U.xy(s.W, src.centre) end
	local tx, ty = U.xy(s.W, p.cell)
	E.emit(s, "disco_ray", { x = fx, y = fy, tx = tx, ty = ty })
	H.hit(s, p.cell, src)
end

-- Activation record (kind 1): data {id, cell, partner cell, mv, wv, X}.
function SP.activate(s, rec)
	local d = rec.d
	local o = s.objs[d[1]]
	if not o or o.kind ~= K_SPECIAL or o.state ~= S_ARMED then return end
	local t0 = s.now
	local cell = o.cell
	local src = H.new_source(s, C.SRC_EFFECT, d[4], d[5], 0)
	src.own = { o.id }
	src.centre = cell
	local partner = d[3]
	if partner ~= 0 then
		local po = B.get(s, partner)
		if po and po.kind == K_SPECIAL and po.state == S_ARMED then
			src.own[2] = po.id
			SP.combo(s, src, o, po, t0)
			sched.retire_if_done(s, src)
			return
		end
	end
	local sp = o.special
	if sp == C.SP_RIFF then
		activate_event(s, o, cell)
		SP.riff(s, src, cell, o.axis, t0)
	elseif sp == C.SP_SUB then
		activate_event(s, o, cell)
		SP.sub(s, src, cell, t0, 2)
	elseif sp == C.SP_DISCO then
		SP.disco(s, src, o, cell, d[6], t0)
	else
		activate_event(s, o, cell)
		SP.bird(s, src, o, cell, t0)
	end
	sched.retire_if_done(s, src)
end

-- Bird (8.3). STAGE B: target choice (section 9) and bird_impact are not
-- implemented yet; the bird performs its cross only (as with no target).
function SP.bird(s, src, o, cell, t0)
	local x, y = U.xy(s.W, cell)
	local acts = {}
	-- the cross by cell index: up, left, own, right, down
	local nb = { { x, y - 1 }, { x - 1, y }, { x, y }, { x + 1, y }, { x, y + 1 } }
	for k = 1, 5 do
		if B.exists_xy(s, nb[k][1], nb[k][2]) then
			acts[#acts + 1] = { t0, (nb[k][2] - 1) * s.W + nb[k][1] }
		end
	end
	SP.run_hits(s, src, acts, t0)
end

-- Combo (8.5). STAGE B: combo geometries are not implemented yet; the
-- combo only hits its centre (which removes both specials) and `from`.
function SP.combo(s, src, o, po, t0)
	activate_event(s, o, o.cell, { partner = po.id })
	SP.run_hits(s, src, { { t0, o.cell }, { t0, po.cell } }, t0)
end

return SP
