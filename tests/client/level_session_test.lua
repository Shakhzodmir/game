local level_session = require("client.level_session")
local core = require("core.game")

local LEVEL = [[{
  "id": 3, "version": 1, "size": [6, 6], "moves": 12, "difficulty": "easy",
  "colors": ["red", "yellow", "green", "blue"],
  "goals": [{"type": "collect", "color": "red", "count": 10}],
  "cells": ["######", "######", "######", "######", "######", "######"]
}]]

local function reader(calls)
	return function(n)
		calls[#calls + 1] = n
		return LEVEL
	end
end

local function play_to_rest(s, limit)
	local all = {}
	for _ = 1, limit or 600 do
		s:advance(1 / 60, function(evs) for _, e in ipairs(evs) do all[#all + 1] = e end end)
		if s.game:is_stable() then break end
	end
	return all
end

describe("client.level_session", function()
	it("maps losses in a row to the level of help", function()
		assert_eq(level_session.help_level(nil), 0)
		assert_eq(level_session.help_level(2), 0)
		assert_eq(level_session.help_level(3), 1)
		assert_eq(level_session.help_level(4), 1)
		assert_eq(level_session.help_level(5), 2)
		assert_eq(level_session.help_level(9), 2)
	end)

	it("resolves the start-window params and the standalone debug params", function()
		local calls = {}
		local run = { level_id = 3, attempt = 4, salt = 777, assist = 3, boosters = { "riff", "stick", "disco" } }
		local r = level_session.resolve({ level_id = 3, run = run, level_text = LEVEL }, reader(calls))
		assert_eq(#calls, 0) -- the text came with the params
		assert_eq(r.level_id, 3)
		assert_eq(r.attempt, 4)
		assert_eq(r.salt, 777)
		assert_eq(r.help, 1)
		assert_same(r.boosters, { "riff", "disco" }) -- only pre-level boosters go to the core
		assert_false(r.standalone)
		r = level_session.resolve({ level = 5 }, reader(calls))
		assert_same(calls, { 5 })
		assert_eq(r.level_id, 5)
		assert_eq(r.attempt, 1)
		assert_eq(r.salt, 0)
		assert_same(r.boosters, {})
		assert_true(r.standalone)
		r = level_session.resolve(nil, reader(calls))
		assert_eq(r.level_id, 1)
	end)

	it("builds the core game with the attempt seed", function()
		local s = assert(level_session.new({ params = { level_id = 3, run = { attempt = 2, salt = 99, assist = 0, boosters = {} },
			level_text = LEVEL } }))
		assert_eq(s.seed, core.attempt_seed(3, 2, 99))
		assert_eq(s.W, 6)
		assert_eq(s.H, 6)
		assert_eq(s.game:status().moves_left, 12)
		local nope, err = level_session.new({ params = { level = 9 }, read_level = function() return nil end })
		assert_eq(nope, nil)
		assert_true(string.find(err, "no level file", 1, true) ~= nil)
		nope, err = level_session.new({ params = { level = 9, level_text = "{}" } })
		assert_eq(nope, nil)
		assert_true(string.find(err, "level 9", 1, true) ~= nil)
	end)

	it("runs fixed 1/60 s ticks, at most 6 per frame", function()
		local s = assert(level_session.new({ params = { level_text = LEVEL, level = 3 } }))
		assert_eq(s:advance(1 / 120), 0)
		assert_near(s:display_tick(), 0.5, 1e-6)
		assert_eq(s:advance(1 / 120), 1)
		assert_eq(s.tick, 1)
		assert_eq(s:advance(0.05), 3)
		assert_eq(s:advance(0.2), 6) -- 12 ticks worth: 6 run, the rest dropped
		assert_eq(s.tick, 10)
		assert_true(s:display_tick() < 11)
		s:set_paused(true)
		assert_eq(s:advance(0.1), 0)
		s:set_paused(false)
		local ticks = {}
		s:advance(2 / 60, function(evs, t) ticks[#ticks + 1] = t end)
		assert_same(ticks, { 11, 12 })
	end)

	it("slows the logic down in slow motion (visual only)", function()
		local s = assert(level_session.new({ params = { level_text = LEVEL, level = 3 } }))
		s:slowmo(0.4, 0.5)
		local n = 0
		for _ = 1, 24 do n = n + s:advance(1 / 60) end -- 0.4 s of real time
		assert_true(n >= 11 and n <= 13, "about half the ticks: " .. n)
		n = 0
		for _ = 1, 12 do n = n + s:advance(1 / 60) end
		assert_eq(n, 12)
	end)

	it("sends commands with the first-move and booster hooks", function()
		local moved, used = 0, {}
		local s = assert(level_session.new({ params = { level_text = LEVEL, level = 3 },
			hooks = { first_move = function() moved = moved + 1 end, booster_used = function(id) used[#used + 1] = id end } }))
		local cmd = s:hint_command()
		assert_true(cmd ~= nil)
		local ok, res = s:command(cmd)
		assert_true(ok)
		assert_eq(res, "ok")
		assert_eq(moved, 1)
		local evs = play_to_rest(s)
		local types = {}
		for _, e in ipairs(evs) do types[e.type] = true end
		assert_true(types.swap and types.match and types.clear and types.moves)
		assert_eq(s.game:status().moves_left, 11)
		ok = s:command(s:hint_command())
		assert_true(ok)
		assert_eq(moved, 1) -- once per attempt
		play_to_rest(s)
		ok, res = s:command({ type = "booster", booster = "stick", at = { 1, 1 } })
		assert_true(ok, tostring(res))
		assert_same(used, { "stick" })
		ok = s:command({ type = "swap", from = { 1, 1 }, to = { 3, 3 } })
		assert_false(ok)
	end)

	it("answers the QA bridge commands", function()
		local s = assert(level_session.new({ params = { level_text = LEVEL, level = 3 } }))
		local st = s:qa("state")
		assert_true(st.ok)
		assert_eq(st.state.moves, 12)
		assert_eq(st.state.state, "playing")
		assert_same(st.state.goals, { 10 })
		assert_true(st.state.stable)
		local r = s:qa("hint_move")
		assert_true(r.ok, r.result)
		assert_eq(r.state.moves, 11)
		play_to_rest(s)
		r = s:qa("swap", { "1", "1", "1" })
		assert_false(r.ok)
		r = s:qa("tap", { "1", "1" }) -- no special there
		assert_false(r.ok)
		assert_eq(r.result, "not_movable")
		r = s:qa("skip")
		assert_false(r.ok)
		assert_eq(r.result, "bad_state")
		r = s:qa("fly")
		assert_false(r.ok)
	end)
end)
