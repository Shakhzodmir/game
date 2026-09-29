-- Scheduler queue (15.1, 15.2).
--
-- s.queue is an array of records {due, seq, kind, d} kept sorted by
-- (due, seq); `d` holds the data fields of 15.2 in their fixed order.
-- Records of kinds 2-5 belong to the source in d[1]; the source counts them
-- in `nrec` and dies when the last one has run (1.4.7).

local C = require("core.const")

local S = {}

local function before(a, b)
	return a.due < b.due or (a.due == b.due and a.seq < b.seq)
end

local function insert(q, rec)
	local lo, hi = 1, #q
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		if before(q[mid], rec) then lo = mid + 1 else hi = mid - 1 end
	end
	table.insert(q, lo, rec)
end

local function owned(kind)
	return kind >= C.R_HIT and kind <= C.R_BIRD
end
S.owned = owned

-- Puts a record on the queue. In steps 4-8 a record due <= now is moved to
-- now + 1 (15.1.5); commands and steps 2-3 keep it at due.
function S.push(s, due, kind, d)
	if s.phase >= 4 and due <= s.now then due = s.now + 1 end
	local seq = s.seq + 1
	s.seq = seq
	local rec = { due = due, seq = seq, kind = kind, d = d }
	insert(s.queue, rec)
	if owned(kind) then
		local src = s.sources[d[1]]
		src.nrec = src.nrec + 1
	end
	return rec
end

-- Removes and returns the first record due at or before `now`, or nil.
function S.pop_due(s, now)
	local q = s.queue
	local r = q[1]
	if r and r.due <= now then
		table.remove(q, 1)
		return r
	end
	return nil
end

-- A source without records is retired (1.4.7).
function S.retire_if_done(s, src)
	if src and src.nrec == 0 and s.sources[src.id] == src then
		s.sources[src.id] = nil
	end
end

-- Switch to turbo between ticks (15.1.8): records move to min(due, now) and
-- are renumbered 1..k in their previous order.
function S.retime_turbo(s, now)
	local q = s.queue
	for k = 1, #q do
		local r = q[k]
		if r.due > now then r.due = now end
		r.seq = k
	end
	s.seq = #q
end

return S
