-- The scheduler queue (15.1, 15.2): records ordered by (due, seq), the due
-- clamp of steps 4-8, ownership by sources, the turbo renumbering.

local C = require("core.const")
local sched = require("core.sched")

local function state()
	return { queue = {}, sources = {}, seq = 0, phase = 0, now = 10 }
end

local function dues(s)
	local out = {}
	for k, r in ipairs(s.queue) do out[k] = r.due .. ":" .. r.seq end
	return out
end

describe("core sched: order and sequence numbers (15.1.4)", function()
	it("numbers the records by a counter that grows by one per push", function()
		local s = state()
		local a = sched.push(s, 12, C.R_CONCERT_B, {})
		local b = sched.push(s, 11, C.R_CONCERT_B, {})
		assert_same({ a.seq, b.seq, s.seq }, { 1, 2, 2 })
		assert_same({ a.due, a.kind }, { 12, C.R_CONCERT_B })
	end)

	it("keeps the queue ordered by (due, seq): equal dues leave in the order of pushing", function()
		local s = state()
		sched.push(s, 15, C.R_CONCERT_B, {})
		sched.push(s, 12, C.R_CONCERT_B, {})
		sched.push(s, 15, C.R_CONCERT_B, {})
		sched.push(s, 11, C.R_CONCERT_B, {})
		sched.push(s, 12, C.R_CONCERT_B, {})
		assert_same(dues(s), { "11:4", "12:2", "12:5", "15:1", "15:3" })
	end)

	it("a random mix of pushes and pops agrees with a plain sort by (due, seq)", function()
		local x = 12345
		local function rnd(n) x = (x * 1103515245 + 12345) % 2147483648; return math.floor(x / 65536) % n + 1 end
		local s = state()
		local model = {}
		for step = 1, 600 do
			if rnd(3) < 3 then
				local due = 10 + rnd(8)
				local r = sched.push(s, due, C.R_CONCERT_A, { step })
				model[#model + 1] = { due = due, seq = r.seq, step = step }
			else
				local now = 10 + rnd(8)
				local got = sched.pop_due(s, now)
				table.sort(model, function(a, b) return a.due < b.due or (a.due == b.due and a.seq < b.seq) end)
				if model[1] and model[1].due <= now then
					assert_true(got ~= nil, "a due record must come out")
					assert_eq(got.seq, model[1].seq)
					table.remove(model, 1)
				else
					assert_eq(got, nil)
				end
			end
		end
		assert_eq(#s.queue, #model)
	end)

	it("pop_due takes the first record with due <= now and leaves the later ones", function()
		local s = state()
		sched.push(s, 12, C.R_CONCERT_B, {})
		sched.push(s, 10, C.R_CONCERT_A, { 1 })
		assert_eq(sched.pop_due(s, 9), nil)
		local r = sched.pop_due(s, 10)
		assert_same({ r.due, r.kind }, { 10, C.R_CONCERT_A })
		assert_eq(sched.pop_due(s, 11), nil)
		assert_eq(sched.pop_due(s, 12).kind, C.R_CONCERT_B)
		assert_eq(sched.pop_due(s, 99), nil)
	end)

	it("a record pushed while the queue is being drained joins the current pass in (due, seq) order", function()
		local s = state()
		sched.push(s, 10, C.R_CONCERT_A, { 1 })
		sched.push(s, 10, C.R_CONCERT_A, { 2 })
		local order = {}
		local n = 0
		while true do
			local r = sched.pop_due(s, 10)
			if not r then break end
			order[#order + 1] = r.d[1]
			n = n + 1
			if n == 1 then sched.push(s, 10, C.R_CONCERT_A, { 3 }) end -- during the pass (step 3)
		end
		assert_same(order, { 1, 2, 3 })
	end)
end)

describe("core sched: the due of a record pushed in a step (15.1.5)", function()
	it("commands and steps 2-3 keep due <= now (the record runs in step 3 of this tick)", function()
		for _, phase in ipairs({ 0, 2, 3 }) do
			local s = state()
			s.phase = phase
			assert_eq(sched.push(s, 10, C.R_CONCERT_B, {}).due, 10, "phase " .. phase)
			assert_eq(sched.push(s, 7, C.R_CONCERT_B, {}).due, 7, "phase " .. phase)
			assert_eq(sched.push(s, 13, C.R_CONCERT_B, {}).due, 13, "phase " .. phase)
		end
	end)

	it("steps 4-8 move a record with due <= now to now + 1; later dues stay", function()
		for phase = 4, 8 do
			local s = state()
			s.phase = phase
			assert_eq(sched.push(s, 10, C.R_CONCERT_B, {}).due, 11, "phase " .. phase)
			assert_eq(sched.push(s, 3, C.R_CONCERT_B, {}).due, 11, "phase " .. phase)
			assert_eq(sched.push(s, 11, C.R_CONCERT_B, {}).due, 11, "phase " .. phase)
			assert_eq(sched.push(s, 12, C.R_CONCERT_B, {}).due, 12, "phase " .. phase)
		end
	end)
end)

describe("core sched: ownership by sources (1.4.7, 15.2)", function()
	it("records of kinds 2-5 count against the source named in their first field", function()
		local s = state()
		s.sources[7] = { id = 7, nrec = 0 }
		sched.push(s, 11, C.R_HIT, { 7, 5 })
		sched.push(s, 11, C.R_DISCO, { 7, 0, 3 })
		sched.push(s, 11, C.R_TRANSFORM, { 7, 0, 3 })
		sched.push(s, 11, C.R_BIRD, { 7, 5, 0, 0 })
		assert_eq(s.sources[7].nrec, 4)
		-- kinds 1, 6, 7, 8 belong to nobody
		sched.push(s, 11, C.R_ACTIVATE, { 1, 2, 0, 1, 1, 0 })
		sched.push(s, 11, C.R_CONCERT_A, { 1 })
		sched.push(s, 11, C.R_CONCERT_B, {})
		sched.push(s, 11, C.R_BOOSTER, { 1, 8, 1, 1 })
		assert_eq(s.sources[7].nrec, 4)
		for kind = 1, 8 do assert_eq(sched.owned(kind), kind >= 2 and kind <= 5, "kind " .. kind) end
	end)

	it("a source dies when its last record has run, and only then", function()
		local s = state()
		local src = { id = 3, nrec = 2 }
		s.sources[3] = src
		sched.retire_if_done(s, src)
		assert_eq(s.sources[3], src)
		src.nrec = 0
		sched.retire_if_done(s, src)
		assert_eq(s.sources[3], nil)
		sched.retire_if_done(s, nil) -- no source: nothing to do
	end)
end)

describe("core sched: the switch to turbo (15.1.8)", function()
	it("clamps every due to now, then renumbers seq 1..k in the previous (due, seq) order", function()
		local s = state()
		sched.push(s, 30, C.R_CONCERT_A, { 1 })
		sched.push(s, 12, C.R_CONCERT_A, { 2 })
		sched.push(s, 12, C.R_CONCERT_A, { 3 })
		sched.push(s, 11, C.R_CONCERT_A, { 4 })
		sched.push(s, 90, C.R_CONCERT_A, { 5 })
		-- previous order: 4 (11), 2 (12), 3 (12), 1 (30), 5 (90)
		sched.retime_turbo(s, 12)
		local out = {}
		for k, r in ipairs(s.queue) do out[k] = { r.d[1], r.due, r.seq } end
		assert_same(out, { { 4, 11, 1 }, { 2, 12, 2 }, { 3, 12, 3 }, { 1, 12, 4 }, { 5, 12, 5 } })
		assert_eq(s.seq, 5, "the counter equals k")
		local r = sched.push(s, 12, C.R_CONCERT_A, { 6 })
		assert_eq(r.seq, 6)
	end)

	it("an empty queue resets the counter to 0", function()
		local s = state()
		s.seq = 41
		sched.retime_turbo(s, 5)
		assert_eq(s.seq, 0)
	end)
end)
