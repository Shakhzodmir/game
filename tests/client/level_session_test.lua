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

	it("charges the Crossfader when the core takes it and not when it refuses it; the QA bridge drives it", function()
		local used = {}
		local s = assert(level_session.new({ params = { level_text = LEVEL, level = 3 },
			hooks = { booster_used = function(id) used[#used + 1] = id end } }))
		local first, other, alike
		for _, p in ipairs(s.game:pieces()) do
			if not first then
				first = p
			elseif p.color ~= first.color and not other then
				other = p
			elseif p.color == first.color and not alike then
				alike = p
			end
		end
		assert_true(first and other and alike, "a 6x6 board of four colours has all three")
		-- two alike: refused by the core, nothing is charged, no move, no action
		local r = s:qa("booster", { "swap", tostring(first.x), tostring(first.y), tostring(alike.x), tostring(alike.y) })
		assert_false(r.ok)
		assert_eq(r.result, "same_piece")
		assert_same(used, {})
		-- one cell only: the core wants the second one
		r = s:qa("booster", { "swap", "1", "1" })
		assert_false(r.ok)
		-- two that differ, far apart or not: taken
		r = s:qa("booster", { "swap", tostring(first.x), tostring(first.y), tostring(other.x), tostring(other.y) })
		assert_true(r.ok, tostring(r.result))
		assert_same(r.cmd, { type = "booster", booster = "swap", at = { first.x, first.y }, to = { other.x, other.y } })
		assert_same(used, { "swap" })
		assert_eq(r.state.moves, 12, "no move is spent")
		-- the exchange runs, the game settles, the same booster can be used again
		local evs = play_to_rest(s)
		local types = {}
		for _, e in ipairs(evs) do types[e.type] = (types[e.type] or 0) + 1 end
		assert_eq(types.exchange, 1, "the events of the command come out with the first tick")
		assert_eq(types.booster, 1)
		assert_true(s.game:is_stable())
		assert_eq(s.game:status().moves_left, 12)
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

describe("client.level_session focus and autoplay", function()
	it("stands still while the app is in the background and does not rush on its return", function()
		local s = assert(level_session.new({ params = { level_text = LEVEL, level = 3 } }))
		s:set_hold(true)
		assert_true(s:halted())
		assert_eq(s:advance(0.1), 0)
		assert_eq(s.tick, 0)
		s:set_paused(true) -- a window opened meanwhile
		s:set_hold(false)
		assert_true(s:halted()) -- still paused by the window
		assert_eq(s:advance(0.1), 0)
		s:set_paused(false)
		assert_false(s:halted())
		-- the time spent away is not played back: the accumulator starts again
		s:set_hold(true)
		s:advance(0.2)
		s:set_hold(false)
		assert_eq(s:advance(1 / 60), 1)
		assert_true(s:snapshot().hold == false)
	end)

	it("plays hint moves by itself for the QA win command and stops at the end", function()
		local s = assert(level_session.new({ params = { level_text = LEVEL, level = 3 } }))
		assert_eq(s:autoplay_step(), nil) -- not started
		local r = s:qa("autoplay", { "2" })
		assert_true(r.ok)
		local played = 0
		for _ = 1, 3000 do
			s:advance(1 / 60)
			if s:autoplay_step() then played = played + 1 end
			if not s.auto then break end
		end
		assert_eq(played, 2)
		assert_eq(s.auto, nil)
		-- win: free "+5 moves" when out of moves, until the level is won
		s:qa("win")
		for _ = 1, 20000 do
			s:advance(1 / 60)
			s:autoplay_step()
			local st = s.game:status().state
			if st == "complete" or st == "lost" then break end
		end
		assert_eq(s.game:status().state, "complete")
		assert_eq(s:qa("hold", { "1" }).state.hold, true)
		assert_eq(s:qa("hold", { "0" }).state.hold, false)
	end)

	it("takes the free moves of the win command even while the moves window has paused the session", function()
		-- a level the hint moves cannot finish in its five moves: the HUD opens the moves window (pauses the session)
		-- when the moves are out and closes it when the state is back, as screens/level/level.gui_script does
		local hard = string.gsub(LEVEL, '"moves": 12', '"moves": 5')
		hard = string.gsub(hard, '"count": 10', '"count": 40')
		local s = assert(level_session.new({ params = { level_text = hard, level = 3 } }))
		s:qa("win")
		local windows = 0
		for _ = 1, 30000 do
			s:advance(1 / 60)
			local state = s.game:status().state
			-- (the HUD runs after the board in the same frame, the autoplay step comes first in the next one)
			if state == "out_of_moves" and not s.paused then
				s:set_paused(true)
				windows = windows + 1
			elseif state ~= "out_of_moves" and s.paused then
				s:set_paused(false)
			end
			s:autoplay_step()
			if state == "complete" or state == "lost" then break end
		end
		assert_true(windows >= 1, "the moves ran out under the autoplay")
		assert_eq(s.game:status().state, "complete")
		-- a plain autoplay stops at the moves window: it does not play on behind the player's back
		local t = assert(level_session.new({ params = { level_text = hard, level = 3 } }))
		t:qa("autoplay", { "100" })
		for _ = 1, 6000 do
			t:advance(1 / 60)
			if t.game:status().state == "out_of_moves" then t:set_paused(true) end
			t:autoplay_step()
			if t.game:status().state == "out_of_moves" and not t.auto then break end
		end
		assert_eq(t.game:status().state, "out_of_moves")
		assert_eq(t.auto, nil, "the autoplay ended at the out-of-moves state")
	end)
end)
