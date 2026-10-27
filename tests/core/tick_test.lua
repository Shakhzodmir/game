-- The tick (section 15): step order, durations by timer kind in both timing
-- modes, the queue inside a tick, the guard against runaway records, the
-- switch to turbo. Core module: core/tick.lua (+ sched.lua).

local C = require("core.const")
local B = require("core.board")
local EF = require("core.effects")
local G = require("core.gravity")
local F = require("core.flow")
local M = require("core.match")
local sched = require("core.sched")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- no match; (3,1)<->(4,1) makes red 1..3 in row 1; (5,5)<->(6,5) is a failed swap
local P1 = { "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }

local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or P1)
	return g
end

-- Runs fn with a spy on `tbl[name]` (calls `before` first), restoring it afterwards.
local function with_spy(tbl, name, before, fn)
	local orig = tbl[name]
	tbl[name] = function(...)
		before(...)
		return orig(...)
	end
	local ok, err = pcall(fn)
	tbl[name] = orig
	if not ok then error(err, 0) end
end

describe("core tick: a duration D started at now ends in tick now + D (15.1.3)", function()
	local DUR = {
		normal = { swap = 10, fail = 14, back = 10, clear = 9, lock = 30 },
		turbo = { swap = 1, fail = 1, back = 1, clear = 1, lock = 1 },
	}

	for _, mode in ipairs({ "normal", "turbo" }) do
		it("swap, failed swap and swap_back in " .. mode .. " mode", function()
			local D = DUR[mode]
			-- swap accepted in the window before tick 4 (now = 4)
			local g = fresh(P1, nil, { timing = mode })
			for _ = 1, 3 do g:step() end
			assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) }, { true, "ok" })
			local a = H.obj_at(g, 3, 1)
			assert_eq(a.td, 4 + D.swap)
			for _ = 1, D.swap do g:step() end -- ticks 4 .. 3 + D.swap
			assert_eq(g.s.tick, 3 + D.swap)
			assert_eq(a.state, C.S_SWAP, "still swapping in tick " .. g.s.tick)
			g:step() -- tick 4 + D.swap: step 2 owns the timer
			assert_eq(g.s.tick, 4 + D.swap)
			assert_eq(H.obj_at(g, 4, 1), a, "exchanged in step 2 of tick now + D")
			assert_eq(a.settle, 4 + D.swap)
			-- failed swap
			local f = fresh(P1, nil, { timing = mode })
			f:step()
			assert_same({ f:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) }, { true, "fail" })
			local p = H.obj_at(f, 5, 5)
			assert_eq(p.td, 2 + D.fail)
			for _ = 1, D.fail do f:step() end
			assert_eq(f.s.tick, 1 + D.fail)
			assert_eq(p.state, C.S_SWAP)
			f:step()
			assert_eq(f.s.tick, 2 + D.fail)
			assert_eq(p.state, C.S_IDLE)
			assert_eq(p.settle, 2 + D.fail)
			-- swap_back: a swap whose match vanished before the end
			local r = fresh(P1, nil, { timing = mode })
			local red = H.obj_at(r, 4, 1)
			r:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
			H.obj_at(r, 1, 1).color = C.COLOR.blue
			for _ = 1, D.swap + 1 do r:step() end
			local t_end = 1 + D.swap
			assert_eq(r.s.tick, t_end)
			assert_eq(red.tk, C.TM_BACK, "refund: swap_back started in the tick the swap ended")
			assert_eq(red.td, t_end + D.back)
			for _ = 1, D.back do r:step() end
			assert_eq(r.s.tick, t_end + D.back - 0)
			assert_eq(red.state, C.S_IDLE, "swap_back ends in step 2 of tick t_end + T.swap")
			assert_eq(red.settle, t_end + D.back)
		end)
	end

	it("a piece cleared in tick t leaves in step 4 of tick t + T.clear (9 normal, 1 turbo)", function()
		for _, mode in ipairs({ "normal", "turbo" }) do
			local D = DUR[mode]
			local g = fresh({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }, nil, { timing = mode })
			g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
			for _ = 1, D.swap + 1 do g:step() end -- the swap ends in tick 1 + D.swap, the match clears there
			local t = g.s.tick
			assert_eq(t, 1 + D.swap)
			local gone = H.obj_at(g, 1, 1)
			assert_eq(gone.state, C.S_CLEAR)
			assert_eq(gone.td, t + D.clear)
			for _ = 1, D.clear - 1 do g:step() end
			assert_eq(g.s.objs[gone.id], gone, "still on the board in tick t + D - 1 (" .. mode .. ")")
			g:step()
			assert_eq(g.s.tick, t + D.clear)
			assert_eq(g.s.objs[gone.id] == nil or g.s.objs[gone.id].state ~= C.S_CLEAR, true, "gone in step 4 of tick t + D")
		end
	end)

	it("the shuffle lock lasts T.shuffle ticks (30 normal, 1 turbo) and ends in step 2", function()
		-- a 6 x 6 board without a match and without a move: step 8 of tick 1 shuffles
		local DEAD = { "ygbpro", "gbproy", "bproyg", "proygb", "roygbp", "oygbpr" }
		for _, mode in ipairs({ "normal", "turbo" }) do
			local g = fresh(DEAD, nil, { timing = mode })
			assert_false(g:has_move())
			g:step()
			local locked = {}
			for _, o in ipairs(B.objects(g.s)) do
				if o.tk == C.TM_LOCK then locked[#locked + 1] = o end
			end
			assert_true(#locked > 0, "the shuffle must have locked pieces")
			local due = 1 + DUR[mode].lock
			for _, o in ipairs(locked) do
				assert_eq(o.td, due, mode)
				assert_eq(o.state, C.S_SWAP)
			end
			while g.s.tick < due - 1 do g:step() end
			assert_eq(locked[1].state, C.S_SWAP, "still locked in tick due - 1")
			g:step()
			assert_eq(g.s.tick, due)
			for _, o in ipairs(locked) do
				assert_eq(o.state, C.S_IDLE, "free in step 2 of tick 1 + T.shuffle")
				assert_eq(o.settle, due)
			end
		end
	end)
end)

describe("core tick: the steps of one tick, in order (15)", function()
	it("steps 2, 5, 6, 7 and 8 run in this order with the phase counter set; phase is 0 between ticks", function()
		local g = fresh()
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		local log = {}
		local function spy(tbl, name, label)
			local orig = tbl[name]
			tbl[name] = function(s, ...)
				log[#log + 1] = label .. "@" .. s.phase
				return orig(s, ...)
			end
			return function() tbl[name] = orig end
		end
		local undo = { spy(M, "search", "search"), spy(G, "assign", "assign"), spy(G, "move", "move"), spy(F, "step8", "step8") }
		local ok, err = pcall(function()
			for _ = 1, 11 do g:step() end
		end)
		for _, u in ipairs(undo) do u() end
		assert_true(ok, err)
		-- ticks 1..10: assign@5 move@6 step8@8; tick 11 adds the step 2 search first
		local want = {}
		for _ = 1, 10 do
			want[#want + 1] = "assign@5"
			want[#want + 1] = "move@6"
			want[#want + 1] = "step8@8"
		end
		want[#want + 1] = "search@2"
		want[#want + 1] = "assign@5"
		want[#want + 1] = "move@6"
		want[#want + 1] = "step8@8"
		assert_same(log, want)
		assert_eq(g.s.phase, 0)
		g:input({ type = "swap", from = { 1, 2 }, to = { 2, 2 } })
		assert_eq(g.s.phase, 0)
	end)

	it("a dirty board is searched in step 7, after the movement and before the end-of-tick step", function()
		local g = fresh()
		g.s.dirty = true
		local log = {}
		local undo = {}
		for _, t in ipairs({ { M, "search" }, { G, "move" }, { F, "step8" } }) do
			local tbl, name = t[1], t[2]
			local orig = tbl[name]
			tbl[name] = function(s, ...)
				log[#log + 1] = name .. "@" .. s.phase
				return orig(s, ...)
			end
			undo[#undo + 1] = function() tbl[name] = orig end
		end
		local ok, err = pcall(function() g:step() end)
		for _, u in ipairs(undo) do u() end
		assert_true(ok, err)
		assert_same(log, { "move@6", "search@7", "step8@8" })
		assert_false(g.s.dirty)
	end)

	it("records run in step 3 in (due, seq) order, a record queued while step 3 runs joins the pass", function()
		local g = fresh()
		local log = {}
		local orig = EF.handlers[C.R_ACTIVATE]
		EF.handlers[C.R_ACTIVATE] = function(s, d)
			log[#log + 1] = d[1] .. "@" .. s.phase
			if d[1] == 1 then sched.push(s, s.now, C.R_ACTIVATE, { 50, 0, 0, 0, 0, 0 }) end
			if d[1] == 2 then sched.push(s, s.now + 5, C.R_ACTIVATE, { 60, 0, 0, 0, 0, 0 }) end
		end
		local ok, err = pcall(function()
			sched.push(g.s, 2, C.R_ACTIVATE, { 4, 0, 0, 0, 0, 0 }) -- tick 2
			sched.push(g.s, 1, C.R_ACTIVATE, { 1, 0, 0, 0, 0, 0 }) -- tick 1, seq 2
			sched.push(g.s, 1, C.R_ACTIVATE, { 2, 0, 0, 0, 0, 0 }) -- tick 1, seq 3
			sched.push(g.s, 0, C.R_ACTIVATE, { 3, 0, 0, 0, 0, 0 }) -- overdue: first
			g:step()
			assert_same(log, { "3@3", "1@3", "2@3", "50@3" }, "(due, seq); 50 was queued during the pass, 60 is for later")
			assert_eq(#g.s.queue, 2)
			g:step()
			assert_same(log[#log], "4@3")
			assert_eq(#g.s.queue, 1)
			assert_eq(g.s.queue[1].d[1], 60)
		end)
		EF.handlers[C.R_ACTIVATE] = orig
		assert_true(ok, err)
	end)

	it("a record queued in steps 4-8 for now runs in step 3 of the next tick (15.1.5)", function()
		for _, phase in ipairs({ 5, 6, 8 }) do
			local g = fresh()
			local log = {}
			local orig = EF.handlers[C.R_ACTIVATE]
			EF.handlers[C.R_ACTIVATE] = function(s, d) log[#log + 1] = d[1] .. "@" .. s.tick end
			local target = ({ [5] = { G, "assign" }, [6] = { G, "move" }, [8] = { F, "step8" } })[phase]
			local tbl, name = target[1], target[2]
			local real = tbl[name]
			local pushed = false
			tbl[name] = function(s, ...)
				local r = real(s, ...)
				if not pushed then
					pushed = true
					local rec = sched.push(s, s.now, C.R_ACTIVATE, { 7, 0, 0, 0, 0, 0 })
					log[#log + 1] = "due" .. rec.due
				end
				return r
			end
			local ok, err = pcall(function()
				g:step()
				g:step()
			end)
			tbl[name] = real
			EF.handlers[C.R_ACTIVATE] = orig
			assert_true(ok, err)
			assert_same(log, { "due2", "7@2" }, "phase " .. phase)
		end
	end)

	it("more than MAX_RECORDS_PER_TICK records in one tick is an error, never a silent cut (15.1.7)", function()
		local g = fresh()
		local saved = C.MAX_RECORDS_PER_TICK
		local orig = EF.handlers[C.R_ACTIVATE]
		EF.handlers[C.R_ACTIVATE] = function() end
		C.MAX_RECORDS_PER_TICK = 5
		local ok, err = pcall(function()
			for k = 1, 5 do sched.push(g.s, 1, C.R_ACTIVATE, { k, 0, 0, 0, 0, 0 }) end
			g:step() -- exactly the limit: fine
			for k = 1, 6 do sched.push(g.s, 2, C.R_ACTIVATE, { k, 0, 0, 0, 0, 0 }) end
			g:step()
		end)
		C.MAX_RECORDS_PER_TICK = saved
		EF.handlers[C.R_ACTIVATE] = orig
		assert_false(ok)
		assert_true(string.find(tostring(err), "more than 5 records", 1, true) ~= nil, tostring(err))
	end)

	it("a record that keeps queueing itself for now is caught by the guard", function()
		local g = fresh()
		local saved = C.MAX_RECORDS_PER_TICK
		local orig = EF.handlers[C.R_ACTIVATE]
		EF.handlers[C.R_ACTIVATE] = function(s) sched.push(s, s.now, C.R_ACTIVATE, { 1, 0, 0, 0, 0, 0 }) end
		C.MAX_RECORDS_PER_TICK = 50
		sched.push(g.s, 1, C.R_ACTIVATE, { 1, 0, 0, 0, 0, 0 })
		local ok, err = pcall(function() g:step() end)
		C.MAX_RECORDS_PER_TICK = saved
		EF.handlers[C.R_ACTIVATE] = orig
		assert_false(ok)
		assert_true(string.find(tostring(err), "bug", 1, true) ~= nil, tostring(err))
	end)
end)

describe("core tick: timers expiring together (5.1.3)", function()
	it("swaps end in the order they were started; two special swaps queue their activations in that order", function()
		-- the later swap has the lower cell index
		local rows = { "Rbygby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgSy", "yrgbyr" }
		local g = fresh(rows)
		assert_same({ g:input({ type = "swap", from = { 5, 5 }, to = { 4, 5 } }) }, { true, "ok" }) -- Sub, started first
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }) }, { true, "ok" }) -- Riff, started second
		local sub, riff = H.obj_at(g, 5, 5), H.obj_at(g, 1, 1)
		local order = {}
		local orig = EF.handlers[C.R_ACTIVATE]
		EF.handlers[C.R_ACTIVATE] = function(s, d) order[#order + 1] = d[1] end
		local ok, err = pcall(function() for _ = 1, 11 do g:step() end end)
		EF.handlers[C.R_ACTIVATE] = orig
		assert_true(ok, err)
		assert_same(order, { sub.id, riff.id }, "start order, not cell order")
		assert_eq(riff.state, C.S_ARMED)
		assert_eq(sub.state, C.S_ARMED)
	end)

	it("refunds go in ascending action number; each swap_back keeps its remembered labels", function()
		local g = fresh()
		local r1, r2 = H.obj_at(g, 4, 1), H.obj_at(g, 2, 3)
		r1.mv, r1.wv = 0, 3
		r2.mv, r2.wv = 0, 5
		-- swap 1: (3,1)<->(4,1) (needs (1,1),(2,1)); swap 2: (1,3)<->(2,3) (needs the (1,2),(1,1) red column)
		assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) }, { true, "ok" })
		assert_same({ g:input({ type = "swap", from = { 1, 3 }, to = { 2, 3 } }) }, { true, "ok" })
		g:drain_events()
		-- a cascade takes both matches away before the swaps end
		H.obj_at(g, 1, 1).color = C.COLOR.blue
		H.obj_at(g, 2, 2).color = C.COLOR.blue
		for _ = 1, 11 do g:step() end
		local ev = g:drain_events()
		local back = H.of_type(ev, "swap_back")
		assert_eq(#back, 2)
		assert_same(back[1].a, { 3, 1 })
		assert_same(back[2].a, { 1, 3 })
		assert_same(H.of_type(ev, "moves"), { { t = 11, type = "moves", left = 19 }, { t = 11, type = "moves", left = 20 } })
		assert_same({ g.s.swaps[1].a, g.s.swaps[2].a }, { 1, 2 })
		assert_same({ g.s.moves_left, g.s.moves_made }, { 20, 0 })
		assert_same(g.s.eom, {})
		assert_same({ r1.mv, r1.wv, r2.mv, r2.wv }, { 0, 3, 0, 5 }, "labels are back before the swap_back timer runs")
	end)

	it("the locks of the shuffle end after the swaps, and a search follows every expiry", function()
		local g = fresh()
		-- a lock on a piece alone: its expiry still triggers the search of step 2
		local o = H.obj_at(g, 3, 3)
		o.state, o.tk, o.td = C.S_SWAP, C.TM_LOCK, 3
		g.s.dirty = false
		local searches = 0
		with_spy(M, "search", function(s) if s.phase == 2 then searches = searches + 1 end end, function()
			g:step()
			g:step()
			assert_eq(searches, 0, "nothing expired yet")
			assert_eq(o.state, C.S_SWAP)
			g:step()
			assert_eq(searches, 1)
			assert_same({ o.state, o.settle, o.tk }, { C.S_IDLE, 3, 0 })
		end)
	end)

	it("a failed swap ends in step 2 too: the search runs, no refund, no swap_back", function()
		local g = fresh()
		g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } })
		g:drain_events()
		for _ = 1, 15 do g:step() end
		local ev = g:drain_events()
		assert_eq(#H.of_type(ev, "swap_back"), 0)
		assert_eq(#H.of_type(ev, "match"), 0)
		assert_eq(g.s.moves_left, 20)
	end)
end)

describe("core tick: microphone delivery is checked in every tick (10.4, step 7)", function()
	local MIC = { goals = { { type = "deliver", count = 1 } }, mic = { total = 1, on_board_max = 1, gap_moves = 0 } }

	it("a mic at rest on an exit leaves in the first tick; the search of the same step runs before it", function()
		local g = fresh({ "rygbyr", "ygbryg", "gbrygb", "brygbr", "rygbrg", "ygMbyr" }, MIC)
		g.s.released, g.s.on_board = 1, 1
		g.s.dirty = true
		g:step()
		local ev = g:drain_events()
		local d = H.of_type(ev, "mic_delivered")
		assert_eq(#d, 1)
		assert_same({ d[1].t, d[1].x, d[1].y }, { 1, 3, 6 })
		assert_eq(g.s.on_board, 0, "a delivered mic leaves the count at once")
		assert_eq(g.s.goal_left[1], 0)
		local mic = H.obj_at(g, 3, 6)
		assert_eq(mic.state, C.S_CLEAR)
		assert_eq(mic.td, 1 + 9)
		assert_same({ g.s.vac_mv[33], g.s.vac_wv[33] }, { mic.mv, mic.wv }, "vac = the label of the mic")
	end)

	it("the delivery of the next mic is not postponed to rest", function()
		local g = fresh({ "rygbyr", "ygbryg", "gbrygb", "brygbr", "rygbrg", "ygMbyr" }, MIC)
		g:step()
		assert_eq(#H.of_type(g:drain_events(), "mic_delivered"), 1)
		assert_eq(g.s.state, C.G_WON_WAIT)
	end)
end)

describe("core tick: the switch to turbo between ticks (15.1.8)", function()
	it("timers are clamped to now + 1, records move to now, falling pieces lose their delay", function()
		local g = fresh()
		for _ = 1, 4 do g:step() end -- tick 4 done: the next window has now = 5
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) -- due 15
		g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) -- due 19
		local lock = H.obj_at(g, 1, 6)
		lock.state, lock.tk, lock.td = C.S_SWAP, C.TM_LOCK, 33
		local clear = H.obj_at(g, 2, 6)
		clear.state, clear.tk, clear.td = C.S_CLEAR, C.TM_CLEAR, 14
		local fall = H.obj_at(g, 3, 6)
		fall.state, fall.delay, fall.offy = C.S_FALL, 7, 3600
		sched.push(g.s, 40, C.R_CONCERT_B, {})
		sched.push(g.s, 6, C.R_CONCERT_A, { 1 })
		g.s.state = C.G_WON_WAIT
		assert_same({ g:input({ type = "skip" }) }, { true, "ok" })
		assert_eq(g.s.timing, C.TIMING_TURBO)
		assert_same({ g.s.swaps[1].due, g.s.swaps[2].due }, { 6, 6 }, "min(due, now + 1) with now = 5")
		assert_same({ H.obj_at(g, 3, 1).td, H.obj_at(g, 5, 5).td }, { 6, 6 })
		assert_eq(lock.td, 6)
		assert_eq(clear.td, 6)
		assert_eq(fall.delay, 0)
		assert_same({ g.s.queue[1].due, g.s.queue[1].seq, g.s.queue[2].due, g.s.queue[2].seq }, { 5, 1, 5, 2 })
		assert_eq(g.s.seq, 2)
	end)

	it("a timer that is shorter already stays; new durations are the turbo ones", function()
		local g = fresh()
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) -- due 11
		for _ = 1, 9 do g:step() end -- tick 9 done, the next window has now = 10
		g.s.state = C.G_CONCERT
		g:input({ type = "skip" })
		assert_eq(g.s.swaps[1].due, 11, "min(11, 10 + 1)")
		g:step() -- tick 10
		g:step() -- tick 11: the swap ends and its match is cleared
		local victim = H.obj_at(g, 1, 1)
		assert_eq(victim.state, C.S_CLEAR)
		assert_eq(victim.td, 11 + C.T[C.TIMING_TURBO].clear, "a clear started after the switch lasts one tick")
		g:step() -- tick 12: step 4 removes it
		assert_eq(g.s.objs[victim.id], nil)
	end)

	it("the same switch on a clone (set_timing) changes only the clone", function()
		local g = fresh()
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		local c = g:clone()
		c:set_timing("turbo")
		assert_eq(c.s.swaps[1].due, 2)
		assert_eq(g.s.swaps[1].due, 11)
		assert_eq(g.s.timing, C.TIMING_NORMAL)
		c:run_to_rest()
		g:run_to_rest()
		assert_true(c.s.tick < g.s.tick)
	end)
end)
