-- State hash (17.2) and the byte fold used for the level hash (17.1).

local C = require("core.const")
local U = require("core.util")

local HS = {}

local MOD, BASE = 2147483629, 65599
local TWO32 = 4294967296

-- Folds a list of integers (or booleans) into h.
local function fold(h, v)
	if v == true then v = 1 elseif v == false or v == nil then v = 0 end
	v = v % TWO32
	return (h * BASE + v + 1) % MOD
end
HS.fold = fold

function HS.fold_bytes(str)
	local h = 0
	for k = 1, #str do h = fold(h, string.byte(str, k)) end
	return h
end

function HS.state(s)
	local h = 0
	local N = s.N
	local slot, objs = s.slot, s.objs
	for i = 1, N do
		h = fold(h, s.exists[i])
		h = fold(h, s.spawner[i])
		h = fold(h, s.exit[i])
		h = fold(h, s.floor[i])
		h = fold(h, s.wires[i])
		h = fold(h, s.vac_mv[i])
		h = fold(h, s.vac_wv[i])
		local id = slot[i]
		if id == 0 then
			for _ = 1, 17 do h = fold(h, 0) end
			h = fold(h, 0)
		else
			local o = objs[id]
			h = fold(h, o.kind)
			h = fold(h, o.color)
			h = fold(h, o.special)
			h = fold(h, o.axis)
			h = fold(h, o.blocker)
			h = fold(h, o.hp)
			h = fold(h, o.state)
			h = fold(h, o.id)
			h = fold(h, o.mv)
			h = fold(h, o.wv)
			h = fold(h, o.offx)
			h = fold(h, o.offy)
			h = fold(h, o.vy)
			h = fold(h, o.delay)
			h = fold(h, o.settle)
			h = fold(h, o.tk)
			h = fold(h, o.td)
			local pins = o.pins
			h = fold(h, #pins)
			for k = 1, #pins do h = fold(h, pins[k]) end
		end
	end
	-- counters
	h = fold(h, s.tick)
	h = fold(h, s.act)
	h = fold(h, s.seq)
	h = fold(h, s.next_piece_id)
	h = fold(h, s.next_source_id)
	h = fold(h, s.moves_left)
	h = fold(h, s.moves_made)
	h = fold(h, s.score)
	h = fold(h, #s.goal_left)
	for k = 1, #s.goal_left do h = fold(h, s.goal_left[k]) end
	h = fold(h, s.released)
	h = fold(h, s.on_board)
	h = fold(h, s.last_mic)
	h = fold(h, s.state)
	h = fold(h, s.stuck)
	h = fold(h, s.timing)
	h = fold(h, s.input_lock)
	h = fold(h, s.rest_flag)
	h = fold(h, s.dirty)
	h = fold(h, s.last_assign)
	h = fold(h, s.tc)
	h = fold(h, s.rounds)
	h = fold(h, s.moves_at_win)
	-- swaps in flight
	h = fold(h, #s.swaps)
	for k = 1, #s.swaps do
		local sw = s.swaps[k]
		h = fold(h, sw.kind)
		h = fold(h, sw.a)
		h = fold(h, sw.from)
		h = fold(h, sw.to)
		h = fold(h, sw.m1)
		h = fold(h, sw.w1)
		h = fold(h, sw.m2)
		h = fold(h, sw.w2)
		h = fold(h, sw.due)
	end
	-- queue
	local q = s.queue
	h = fold(h, #q)
	for k = 1, #q do
		local r = q[k]
		h = fold(h, r.due)
		h = fold(h, r.seq)
		h = fold(h, r.kind)
		local n = C.RECORD_FIELDS[r.kind]
		for j = 1, n do h = fold(h, r.d[j] or 0) end
	end
	-- active sources
	local ids = U.sorted_keys(s.sources)
	h = fold(h, #ids)
	for k = 1, #ids do
		local src = s.sources[ids[k]]
		h = fold(h, src.id)
		h = fold(h, src.kind)
		h = fold(h, src.mv)
		h = fold(h, src.wv)
		h = fold(h, src.color)
		h = fold(h, src.all_layers)
		h = fold(h, #src.own)
		for j = 1, #src.own do h = fold(h, src.own[j]) end
		h = fold(h, src.centre)
		h = fold(h, #src.keys)
		for j = 1, #src.keys do h = fold(h, src.keys[j]) end
		h = fold(h, #src.reserves)
		for j = 1, #src.reserves do h = fold(h, src.reserves[j]) end
	end
	-- end-of-move queue
	h = fold(h, #s.eom)
	for k = 1, #s.eom do
		local e = s.eom[k]
		h = fold(h, e.a)
		h = fold(h, e.noise_hit)
		h = fold(h, e.merged)
	end
	-- praise
	local ms = U.sorted_keys(s.praise)
	local n = 0
	for k = 1, #ms do
		if s.praise[ms[k]] ~= 0 then n = n + 1 end
	end
	h = fold(h, n)
	for k = 1, #ms do
		local p = s.praise[ms[k]]
		if p ~= 0 then
			h = fold(h, ms[k])
			h = fold(h, p)
		end
	end
	-- unplaced
	h = fold(h, #s.unplaced)
	for k = 1, #s.unplaced do h = fold(h, s.unplaced[k]) end
	-- generators
	for st = 1, 4 do
		local r = s.rng[st]
		for j = 1, 6 do h = fold(h, r[j]) end
	end
	return h
end

return HS
