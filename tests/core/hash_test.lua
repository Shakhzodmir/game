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
