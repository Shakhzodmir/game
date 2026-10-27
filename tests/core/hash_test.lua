-- Hash (17.2), clones (17.3) and replays (17.1).

local core = require("core.game")
local C = require("core.const")
local R = require("core.rng")
local HS = require("core.hash")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }

local function game(opts)
	local lvl = H.load(FULL, { floor = { { at = { 1, 4 }, hp = 2 } }, goals = { { type = "collect", color = "red", count = 30 } } })
	return core.new(lvl, opts or { seed = 77 }), lvl
end

local function drain_all(g, n)
	local all = {}
	for _ = 1, n do
		g:step()
		for _, e in ipairs(g:drain_events()) do all[#all + 1] = e end
	end
	return all
end

describe("core hash (17.2)", function()
	it("folds integers by h = (h*65599 + v%2^32 + 1) % 2147483629", function()
		assert_eq(HS.fold(0, 0), 1)
		assert_eq(HS.fold(1, 5), 65605)
		assert_eq(HS.fold(0, -1), (4294967295 + 1) % 2147483629)
		assert_eq(HS.fold(0, true), 2)
		assert_eq(HS.fold_bytes("ab"), (98 * 1 + 0 + (97 + 1) * 65599 + 1) % 2147483629)
	end)

	it("is equal for equal games and sensitive to every part of the state", function()
		local a, b = game(), game()
		assert_eq(a:hash(), b:hash())
		local h = a:hash()
		local s = a.s
		local probes = {
			function() s.floor[3] = s.floor[3] + 1 end,
			function() s.vac_wv[4] = 1 end,
			function() s.objs[s.slot[5]].settle = 3 end,
			function() s.objs[s.slot[6]].pins = { 1 } end,
			function() s.score = 1 end,
			function() s.goal_left[1] = 2 end,
			function() s.rest_flag = not s.rest_flag end,
			function() s.unplaced = { 5 } end,
			function() s.praise[3] = 5 end,
			function() s.eom = { { a = 1, noise_hit = false, merged = 0 } } end,
			function() s.rng[4][6] = s.rng[4][6] + 1 end,
		}
		for k, poke in ipairs(probes) do
			local c = a:clone()
			s = c.s
			poke()
			assert_true(c:hash() ~= h, "probe " .. k)
		end
	end)

	it("queries are pure: no state change, no randomness, no events", function()
		local g = game()
		g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } })
		g:step()
		g:drain_events()
		local h = g:hash()
		local rng = { unpack(g.s.rng[R.SHUFFLE]) }
		g:can_swap({ 1, 2 }, { 2, 2 })
		g:has_move()
		g:moves()
		g:hint()
		g:is_stable()
		g:pieces()
		g:cells()
		g:status()
		g:result()
		g:replay()
		assert_eq(g:hash(), h)
		assert_same(g.s.rng[R.SHUFFLE], rng)
		assert_same(g:drain_events(), {})
	end)
end)

describe("core clones (17.3)", function()
	it("clone is an independent deep copy with an empty event buffer", function()
		local g = game()
		local m = g:moves()[1]
		g:input({ type = "swap", from = m.from, to = m.to })
		g:step()
		local c = g:clone()
		assert_eq(c:hash(), g:hash())
		assert_same(c:drain_events(), {})
		assert_true(c.s.level == g.s.level, "the level is shared read-only")
		local h = g:hash()
		for _ = 1, 30 do c:step() end
		assert_eq(g:hash(), h)
		for _ = 1, 30 do g:step() end
		assert_eq(g:hash(), c:hash(), "same future without reseed")
	end)

	it("reseed reinitialises spawn, effects and shuffle from (seed, act, k)", function()
		local g = game()
		local c1, c2, c3 = g:clone({ reseed = 1 }), g:clone({ reseed = 1 }), g:clone({ reseed = 2 })
		assert_eq(c1:hash(), c2:hash())
		assert_true(c1:hash() ~= c3:hash())
		assert_same(c1.s.rng[R.INIT], g.s.rng[R.INIT])
		local seed = R.fold_seed(77, 0, 1)
		assert_same(c1.s.rng[R.SPAWN], R.stream(seed, R.SPAWN))
		assert_same(c1.s.rng[R.EFFECTS], R.stream(seed, R.EFFECTS))
		assert_same(c1.s.rng[R.SHUFFLE], R.stream(seed, R.SHUFFLE))
	end)

	it("set_timing('turbo') clamps timers and moves records by 15.1.8", function()
		local g = game()
		local m = g:moves()[1]
		g:input({ type = "swap", from = m.from, to = m.to })
		g:step()
		local c = g:clone()
		c:set_timing("turbo")
		assert_eq(c.s.timing, C.TIMING_TURBO)
		assert_eq(c.s.swaps[1].due, 3, "now = 2, turbo swap = 1")
		c:run_to_rest()
		assert_true(c.s.tick < 30)
	end)

	it("run_to_rest returns 0 at rest and fails past its limit", function()
		local g = game()
		assert_eq(g:run_to_rest(), 0)
		local m = g:moves()[1]
		g:input({ type = "swap", from = m.from, to = m.to })
		assert_error(function() g:run_to_rest(5) end, "run_to_rest")
	end)
end)

describe("core replay (17.1)", function()
	it("records accepted commands and plays them back to the same hash and events", function()
		local g, lvl = game({ seed = 1234, attempt = 2, salt = 99, boosters = { "riff" } })
		local events = drain_all(g, 3)
		local m = g:moves()[1]
		assert_true(g:input({ type = "swap", from = m.from, to = m.to }))
		assert_false(g:input({ type = "swap", from = { 1, 1 }, to = { 3, 1 } }), "rejected: not recorded")
		for _, e in ipairs(g:drain_events()) do events[#events + 1] = e end
		for _, e in ipairs(drain_all(g, 40)) do events[#events + 1] = e end
		g:run_to_rest()
		for _, e in ipairs(g:drain_events()) do events[#events + 1] = e end
		assert_true(g:input({ type = "booster", booster = "stick", at = { 3, 3 } }))
		for _, e in ipairs(drain_all(g, 60)) do events[#events + 1] = e end
		local rep = g:replay()
		assert_eq(rep.core_version, C.CORE_VERSION)
		assert_same(rep.level, { id = 1, version = 1, hash = lvl.hash })
		assert_same({ rep.seed, rep.attempt, rep.salt, rep.help, rep.timing, rep.input_lock },
			{ 1234, 2, 99, 0, "normal", false })
		assert_same(rep.boosters, { "riff" })
		assert_eq(#rep.commands, 2)
		assert_eq(rep.commands[1].tick, 4)
		assert_eq(rep.final_tick, g.s.tick)
		assert_eq(rep.final_hash, g:hash())
		local p, ok, why = core.playback(lvl, rep)
		assert_true(ok, why)
		assert_same(p:drain_events(), events)
	end)

	it("detects a tampered replay", function()
		local g, lvl = game()
		local m = g:moves()[1]
		g:input({ type = "swap", from = m.from, to = m.to })
		for _ = 1, 30 do g:step() end
		local rep = g:replay()
		rep.final_hash = rep.final_hash + 1
		local _, ok, why = core.playback(lvl, rep)
		assert_false(ok)
		assert_eq(why, "final hash differs")
		rep = g:replay()
		rep.seed = 78
		_, ok = core.playback(lvl, rep)
		assert_false(ok)
	end)
end)

-- Audit C additions ----------------------------------------------------------

local B = require("core.board")
local HS2 = require("core.hash")

-- The hash of 17.2 written out once more, straight from the list of the
-- section, without looking at core/hash.lua: a flat list of integers, then
-- the fold.
local function reference_hash(s)
	local vals = {}
	local function put(v)
		if v == true then v = 1 elseif v == false or v == nil then v = 0 end
		vals[#vals + 1] = v
	end
	for i = 1, s.N do
		put(s.exists[i]); put(s.spawner[i]); put(s.exit[i]); put(s.floor[i]); put(s.wires[i])
		put(s.vac_mv[i]); put(s.vac_wv[i])
		local o = s.slot[i] ~= 0 and s.objs[s.slot[i]] or nil
		if o then
			put(o.kind); put(o.color); put(o.special); put(o.axis); put(o.blocker); put(o.hp); put(o.state)
			put(o.id); put(o.mv); put(o.wv); put(o.offx); put(o.offy); put(o.vy); put(o.delay); put(o.settle)
			put(o.tk); put(o.td)
			put(#o.pins)
			for k = 1, #o.pins do put(o.pins[k]) end
		else
			for _ = 1, 17 do put(0) end
			put(0)
		end
	end
	put(s.tick); put(s.act); put(s.seq); put(s.next_piece_id); put(s.next_source_id)
	put(s.moves_left); put(s.moves_made); put(s.score)
	put(#s.goal_left)
	for k = 1, #s.goal_left do put(s.goal_left[k]) end
	put(s.released); put(s.on_board); put(s.last_mic)
	put(s.state); put(s.stuck); put(s.timing); put(s.input_lock); put(s.rest_flag); put(s.dirty)
	put(s.last_assign); put(s.tc); put(s.rounds); put(s.moves_at_win)
	put(#s.swaps)
	for k = 1, #s.swaps do
		local w = s.swaps[k]
		put(w.kind); put(w.a); put(w.from); put(w.to); put(w.m1); put(w.w1); put(w.m2); put(w.w2); put(w.due)
	end
	put(#s.queue)
	for k = 1, #s.queue do
		local r = s.queue[k]
		put(r.due); put(r.seq); put(r.kind)
		local n = ({ 6, 2, 3, 3, 4, 1, 0, 4 })[r.kind]
		for j = 1, n do put(r.d[j] or 0) end
	end
	local ids = {}
	for id in pairs(s.sources) do ids[#ids + 1] = id end -- order-independent (sorted next)
	table.sort(ids) -- numbers
	put(#ids)
	for _, id in ipairs(ids) do
		local src = s.sources[id]
		put(src.id); put(src.kind); put(src.mv); put(src.wv); put(src.color); put(src.all_layers)
		put(#src.own)
		for k = 1, #src.own do put(src.own[k]) end
		put(src.centre)
		put(#src.keys)
		for k = 1, #src.keys do put(src.keys[k]) end
		put(#src.reserves)
		for k = 1, #src.reserves do put(src.reserves[k]) end
	end
	put(#s.eom)
	for k = 1, #s.eom do put(s.eom[k].a); put(s.eom[k].noise_hit); put(s.eom[k].merged) end
	local ms = {}
	for m, p in pairs(s.praise) do -- order-independent (sorted next)
		if p ~= 0 then ms[#ms + 1] = m end
	end
	table.sort(ms) -- numbers
	put(#ms)
	for _, m in ipairs(ms) do put(m); put(s.praise[m]) end
	put(#s.unplaced)
	for k = 1, #s.unplaced do put(s.unplaced[k]) end
	for k = 1, 4 do
		for j = 1, 6 do put(s.rng[k][j]) end
	end
	local h = 0
	for _, v in ipairs(vals) do
		v = v % 4294967296
		h = (h * 65599 + v + 1) % 2147483629
	end
	return h
end

describe("core hash: layout of 17.2", function()
	it("equals a second transcription of the list on every tick of games with specials, columns, mics and a concert", function()
		local LV = {
			{ rows = { "#######", "#R#S#V#", "##D#B##", "#B#S#R#", "##V#D##", "#S#B#V#", "#######" },
				extra = { moves = 12, colors = { "red", "green", "blue", "yellow" },
					goals = { { type = "collect", color = "green", count = 12 } } } },
			{ rows = { "######", "######", "######", "######", "######", "######", "######" },
				extra = { moves = 10, colors = { "red", "green", "blue", "yellow" },
					slots = { { at = { 1, 3 }, type = "record_box", hp = 2 }, { at = { 3, 2 }, type = "noise" },
						{ at = { 2, 4 }, type = "column", hp = 6 } },
					goals = { { type = "break", item = "record_box", count = 1 }, { type = "collect", color = "blue", count = 20 } } } },
			{ rows = { "######", "######", "######", "######", "######", "######" },
				extra = { moves = 10, colors = { "red", "green", "blue", "yellow" },
					overlay = { { at = { 0, 0 }, type = "wires", hp = 2 }, { at = { 3, 3 }, type = "wires", hp = 1 } },
					floor = { { at = { 4, 4 }, hp = 2 }, { at = { 1, 5 }, hp = 1 } },
					goals = { { type = "light" }, { type = "collect", color = "blue", count = 20 } } } },
			{ rows = { "..####..", ".######.", "########", "########", "########", "########" },
				extra = { moves = 8, goals = { { type = "deliver", count = 2 } },
					mic = { total = 2, on_board_max = 2, gap_moves = 1 }, slots = { { at = { 3, 2 }, type = "mic" } } } },
		}
		local checked = 0
		for li, spec in ipairs(LV) do
			local lvl = H.load(spec.rows, spec.extra)
			local x = li * 7919
			local function rnd(n)
				x = (x * 1103515245 + 12345) % 2147483648
				return math.floor(x / 65536) % n + 1
			end
			for _, timing in ipairs({ "normal", "turbo" }) do
				local g = core.new(lvl, { seed = 40 + li, timing = timing, boosters = { "riff", "sub", "disco" }, help = 1 })
				local ticks = 0
				while g.s.state ~= C.G_COMPLETE and g.s.state ~= C.G_LOST and ticks < 1500 do
					if g.s.state == C.G_OUT then
						g:input({ type = "give_up" })
					elseif rnd(3) == 1 then
						local mv = g:moves()
						local r = rnd(10)
						if r <= 6 and #mv > 0 then
							local m = mv[rnd(#mv)]
							g:input({ type = "swap", from = m.from, to = m.to })
						elseif r == 7 then
							g:input({ type = "tap", at = { rnd(g.s.W), rnd(g.s.H) } })
						elseif r == 8 then
							g:input({ type = "booster", booster = "col_light", col = rnd(g.s.W) })
						end
					end
					g:step()
					ticks = ticks + 1
					assert_eq(g:hash(), reference_hash(g.s), "level " .. li .. " " .. timing .. " tick " .. g.s.tick)
					checked = checked + 1
				end
			end
		end
		assert_true(checked > 500)
	end)

	it("hashes a column in each of its four cells", function()
		local g = game()
		H.board(g, { "rrgrby", "yrgbyr", "rgLlrg", "gbllrg", "byrgby", "yrgbyr" })
		g.s.dirty = false
		local h = g:hash()
		assert_eq(h, reference_hash(g.s))
		g.s.objs[H.obj_at(g, 3, 3).id].hp = 5
		assert_true(g:hash() ~= h)
	end)
end)

describe("core hash: every field of 17.2 counts", function()
	local function probes()
		return {
			-- cells
			function(s) s.exists[3] = not s.exists[3] end,
			function(s) s.spawner[9] = not s.spawner[9] end,
			function(s) s.exit[30] = not s.exit[30] end,
			function(s) s.floor[3] = s.floor[3] + 1 end,
			function(s) s.wires[3] = s.wires[3] + 1 end,
			function(s) s.vac_mv[4] = 1 end,
			function(s) s.vac_wv[4] = 1 end,
			-- the slot content, field by field
			function(s) s.objs[s.slot[5]].kind = C.K_MIC end,
			function(s) local o = s.objs[s.slot[5]]; o.color = o.color % 6 + 1 end,
			function(s) s.objs[s.slot[5]].special = 2 end,
			function(s) s.objs[s.slot[5]].axis = 2 end,
			function(s) s.objs[s.slot[5]].blocker = 3 end,
			function(s) s.objs[s.slot[5]].hp = 2 end,
			function(s) s.objs[s.slot[5]].state = C.S_FALL end,
			function(s) s.objs[s.slot[5]].id = 999 end,
			function(s) s.objs[s.slot[5]].mv = 3 end,
			function(s) s.objs[s.slot[5]].wv = 3 end,
			function(s) s.objs[s.slot[5]].offx = 360 end,
			function(s) s.objs[s.slot[5]].offy = 360 end,
			function(s) s.objs[s.slot[5]].vy = 300 end,
			function(s) s.objs[s.slot[5]].delay = 2 end,
			function(s) s.objs[s.slot[5]].settle = 8 end,
			function(s) s.objs[s.slot[5]].tk = C.TM_SWAP end,
			function(s) s.objs[s.slot[5]].td = 12 end,
			function(s) s.objs[s.slot[5]].pins = { 4 } end,
			function(s) s.objs[s.slot[5]].pins = { 4, 6 } end,
			-- counters, in the order of the section
			function(s) s.tick = s.tick + 1 end,
			function(s) s.act = s.act + 1 end,
			function(s) s.seq = s.seq + 1 end,
			function(s) s.next_piece_id = s.next_piece_id + 1 end,
			function(s) s.next_source_id = s.next_source_id + 1 end,
			function(s) s.moves_left = s.moves_left - 1 end,
			function(s) s.moves_made = s.moves_made + 1 end,
			function(s) s.score = s.score + 20 end,
			function(s) s.goal_left[1] = s.goal_left[1] - 1 end,
			function(s) s.goal_left[2] = 4 end,
			function(s) s.released = 1 end,
			function(s) s.on_board = 1 end,
			function(s) s.last_mic = -3 end,
			function(s) s.state = C.G_OUT end,
			function(s) s.stuck = true end,
			function(s) s.timing = C.TIMING_TURBO end,
			function(s) s.input_lock = true end,
			function(s) s.rest_flag = not s.rest_flag end,
			function(s) s.dirty = true end,
			function(s) s.last_assign = 3 end,
			function(s) s.tc = 5 end,
			function(s) s.rounds = 2 end,
			function(s) s.moves_at_win = 4 end,
			-- swaps in flight
			function(s) s.swaps = { { kind = 1, a = 1, from = 3, to = 4, m1 = 0, w1 = 0, m2 = 0, w2 = 0, due = 10 } } end,
			function(s) s.swaps = { { kind = 2, a = 0, from = 3, to = 4, m1 = 0, w1 = 0, m2 = 0, w2 = 0, due = 10 } } end,
			function(s) s.swaps = { { kind = 1, a = 1, from = 3, to = 4, m1 = 0, w1 = 0, m2 = 0, w2 = 0, due = 11 } } end,
			function(s) s.swaps = { { kind = 1, a = 1, from = 3, to = 4, m1 = 1, w1 = 0, m2 = 0, w2 = 0, due = 10 } } end,
			function(s) s.swaps = { { kind = 1, a = 1, from = 3, to = 4, m1 = 0, w1 = 0, m2 = 0, w2 = 2, due = 10 } } end,
			-- the queue: due, seq, kind and the data fields
			function(s) s.queue = { { due = 5, seq = 1, kind = C.R_HIT, d = { 1, 4 } } } end,
			function(s) s.queue = { { due = 6, seq = 1, kind = C.R_HIT, d = { 1, 4 } } } end,
			function(s) s.queue = { { due = 5, seq = 2, kind = C.R_HIT, d = { 1, 4 } } } end,
			function(s) s.queue = { { due = 5, seq = 1, kind = C.R_HIT, d = { 1, 5 } } } end,
			function(s) s.queue = { { due = 5, seq = 1, kind = C.R_CONCERT_A, d = { 1 } } } end,
			function(s) s.queue = { { due = 5, seq = 1, kind = C.R_ACTIVATE, d = { 1, 4, 0, 1, 1, 3 } } } end,
			-- sources
			function(s) s.sources[1] = { id = 1, kind = 3, mv = 1, wv = 1, color = 0, all_layers = false, own = {}, centre = 0, keys = {}, reserves = {}, nrec = 0 } end,
			function(s) s.sources[1] = { id = 1, kind = 3, mv = 1, wv = 1, color = 0, all_layers = true, own = {}, centre = 0, keys = {}, reserves = {}, nrec = 0 } end,
			function(s) s.sources[1] = { id = 1, kind = 3, mv = 1, wv = 1, color = 0, all_layers = false, own = { 4 }, centre = 7, keys = {}, reserves = {}, nrec = 0 } end,
			function(s) s.sources[1] = { id = 1, kind = 3, mv = 1, wv = 1, color = 0, all_layers = false, own = {}, centre = 0, keys = { 2, 9 }, reserves = {}, nrec = 0 } end,
			function(s) s.sources[1] = { id = 1, kind = 3, mv = 1, wv = 1, color = 0, all_layers = false, own = {}, centre = 0, keys = {}, reserves = { 12 }, nrec = 0 } end,
			-- end-of-move queue, praise, unplaced, generators
			function(s) s.eom = { { a = 1, noise_hit = false, merged = 0 } } end,
			function(s) s.eom = { { a = 1, noise_hit = true, merged = 0 } } end,
			function(s) s.eom = { { a = 1, noise_hit = false, merged = 2 } } end,
			function(s) s.praise[2] = 3 end,
			function(s) s.unplaced = { C.IT_REMIX } end,
			function(s) s.rng[1][1] = s.rng[1][1] + 1 end,
			function(s) s.rng[2][3] = s.rng[2][3] + 1 end,
			function(s) s.rng[3][6] = s.rng[3][6] + 1 end,
			function(s) s.rng[4][4] = s.rng[4][4] + 1 end,
		}
	end

	it("changing any single field changes the hash; all the probes give different hashes", function()
		local lvl = H.load(FULL, { goals = { { type = "collect", color = "red", count = 30 }, { type = "light" } },
			floor = { { at = { 1, 4 }, hp = 2 } } })
		local base = core.new(lvl, { seed = 5 })
		local h0 = base:hash()
		local seen = { [h0] = true }
		for k, poke in ipairs(probes()) do
			local c = base:clone()
			poke(c.s)
			local h = c:hash()
			assert_true(h ~= h0, "probe " .. k .. " left the hash alone")
			assert_true(not seen[h], "probe " .. k .. " collides with another probe")
			seen[h] = true
		end
	end)

	it("a zero entry and an absent one are the same, true is 1, a list is preceded by its length", function()
		assert_eq(HS2.fold(5, nil), HS2.fold(5, false))
		assert_eq(HS2.fold(5, false), HS2.fold(5, 0))
		assert_eq(HS2.fold(5, true), HS2.fold(5, 1))
		-- 2^32 + 3 folds like 3 ("v = v % 4294967296")
		assert_eq(HS2.fold(7, 4294967296 + 3), HS2.fold(7, 3))
		assert_eq(HS2.fold(7, -1), HS2.fold(7, 4294967295))
	end)

	it("things outside the state do not enter the hash: events, the replay log, the header", function()
		local g = game()
		local h = g:hash()
		g.s.ev[#g.s.ev + 1] = { type = "land", t = 1 }
		g.s.cmds[#g.s.cmds + 1] = { tick = 1, cmd = { type = "give_up" } }
		g.s.header.attempt = 99
		g.s.now, g.s.phase = 77, 3
		assert_eq(g:hash(), h)
	end)
end)

describe("core replay: all kinds of command and the failure modes (17.1)", function()
	local function scripted(opts)
		local lvl = H.load({ "#######", "#######", "###.###", "#######", "#######", "#######", "#######" },
			{ moves = 6, goals = { { type = "collect", color = "red", count = 400 } }, difficulty = "hard" })
		local g = core.new(lvl, opts)
		local rec = {}
		local function try(cmd)
			local ok, why = g:input(cmd)
			rec[#rec + 1] = { cmd.type, ok, why }
			return ok, why
		end
		g:run_to_rest()
		local m = g:moves()[1]
		try({ type = "swap", from = m.from, to = m.to })
		for _ = 1, 3 do g:step() end
		try({ type = "swap", from = { 1, 1 }, to = { 1, 3 } }) -- bad_cell: rejected, not recorded
		g:run_to_rest()
		try({ type = "booster", booster = "stick", at = { 4, 4 } })
		g:run_to_rest()
		try({ type = "booster", booster = "row_light", row = 6 })
		g:run_to_rest()
		for _ = 1, 6 do
			local mv = g:moves()
			if g.s.state ~= C.G_PLAYING or #mv == 0 then break end
			try({ type = "swap", from = mv[#mv].from, to = mv[#mv].to })
			g:run_to_rest()
		end
		if g.s.state == C.G_OUT then
			try({ type = "continue", moves = 2, riff = true })
			g:run_to_rest()
			local mv = g:moves()
			if #mv > 0 then try({ type = "swap", from = mv[1].from, to = mv[1].to }) end
		end
		return g, lvl, rec
	end

	it("round trip with every accepted command, in both timings, with help, boosters and input_lock", function()
		for _, timing in ipairs({ "normal", "turbo" }) do
			local g, lvl = scripted({ seed = 321, attempt = 3, salt = 12345, help = 2, boosters = { "riff", "sub", "disco" }, timing = timing, input_lock = false })
			local events = {}
			local rep = g:replay()
			assert_true(#rep.commands >= 5)
			for k = 2, #rep.commands do assert_true(rep.commands[k].tick >= rep.commands[k - 1].tick) end
			assert_same({ rep.seed, rep.attempt, rep.salt, rep.help, rep.timing, rep.input_lock, rep.boosters },
				{ 321, 3, 12345, 2, timing, false, { "riff", "sub", "disco" } })
			local p, ok, why = core.playback(lvl, rep)
			assert_true(ok, why)
			assert_eq(p:hash(), g:hash())
			assert_eq(p.s.tick, g.s.tick)
			events = nil
		end
	end)

	it("records the original swap command for a swipe of a special, and a failed swap too", function()
		local lvl = H.load(FULL)
		local g = core.new(lvl, { seed = 9 })
		H.board(g, { "rrSrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_same({ g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) }, { true, "fail" })
		g:run_to_rest()
		assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 3, 0 } }) }, { true, "ok" }, "swipe out of the field")
		local rep = g:replay()
		assert_same(rep.commands[1].cmd, { type = "swap", from = { 5, 5 }, to = { 6, 5 } })
		assert_same(rep.commands[2].cmd, { type = "swap", from = { 3, 1 }, to = { 3, 0 } })
		assert_eq(rep.commands[2].tick, g.s.tick + 1)
	end)

	it("the replay holds copies: changing the command afterwards changes nothing", function()
		local lvl = H.load(FULL)
		local g = core.new(lvl, { seed = 9 })
		local cmd = { type = "booster", booster = "stick", at = { 2, 2 } }
		g:input(cmd)
		cmd.at[1] = 5
		local rep = g:replay()
		assert_same(rep.commands[1].cmd.at, { 2, 2 })
		rep.commands[1].cmd.at[1] = 6
		assert_same(g:replay().commands[1].cmd.at, { 2, 2 })
	end)

	it("playback refuses a different level, a rejected command and an out-of-order command", function()
		local g, lvl = scripted({ seed = 5 })
		local rep = g:replay()
		local other = H.load(FULL, { moves = 9 })
		local _, ok, why = core.playback(other, rep)
		assert_false(ok)
		assert_eq(why, "level hash differs")
		local bad = g:replay()
		bad.commands[1].cmd = { type = "swap", from = { 1, 1 }, to = { 1, 3 } }
		_, ok, why = core.playback(lvl, bad)
		assert_false(ok)
		assert_true(string.find(why, "rejected", 1, true) ~= nil, why)
		local late = g:replay()
		late.commands[2].tick = late.commands[1].tick - 1
		_, ok, why = core.playback(lvl, late)
		assert_false(ok)
		assert_true(string.find(why, "out of order", 1, true) ~= nil, why)
	end)

	it("a tampered command, seed, booster list or timing ends in another hash", function()
		local g, lvl = scripted({ seed = 5, boosters = { "riff" } })
		local function tamper(f)
			local rep = g:replay()
			f(rep)
			local _, ok = core.playback(lvl, rep)
			return ok
		end
		assert_true(tamper(function() end))
		assert_false(tamper(function(r) r.seed = r.seed + 1 end))
		assert_false(tamper(function(r) r.boosters = {} end))
		assert_false(tamper(function(r) r.help = 2 end))
		assert_false(tamper(function(r) r.timing = "turbo" end))
		assert_false(tamper(function(r) r.final_tick = r.final_tick + 1 end))
	end)
end)
