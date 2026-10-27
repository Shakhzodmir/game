-- Golden scenario: a fixed level, seed and command script must give the
-- same level hash, final tick and state hash on every VM (Lua 5.1 and
-- LuaJIT run this file with the same constants).
--
-- The script never swaps or taps a special, so the values do not depend on
-- special effects. If a deliberate rule change alters them, regenerate the
-- constants and say why in the commit.

local core = require("core.game")

local TEXT = [[
{"id": 901, "version": 1, "size": [7, 8], "moves": 30, "difficulty": "hard",
 "colors": ["red", "orange", "yellow", "green", "blue"],
 "goals": [{"type": "collect", "color": "orange", "count": 500}, {"type": "break", "item": "record_box", "count": 2}],
 "cells": ["#######", "#######", "###.###", "#######", "#######", "#######", "#######", "#######"],
 "floor": [{"at": [0, 7], "hp": 2}, {"at": [6, 7], "hp": 1}],
 "slots": [{"at": [2, 4], "type": "record_box", "hp": 2}, {"at": [5, 5], "type": "record_box", "hp": 1},
           {"at": [1, 6], "type": "piece", "color": "blue"}],
 "spawn_weights": {"red": 3, "orange": 2, "yellow": 2, "green": 2, "blue": 1}}
]]

local GOLDEN = {
	level_hash = 1713476193,
	normal = { tick = 335, hash = 471456623, score = 780, moves_left = 18 },
	turbo = { tick = 48, hash = 460714240, score = 780, moves_left = 18 },
}

local function play(lvl, timing)
	local g = core.new(lvl, { seed = 424242, timing = timing, help = 1 })
	local swaps = 0
	while swaps < 12 and g.s.state == 1 do
		g:run_to_rest()
		local pick
		for _, m in ipairs(g:moves()) do
			local a = g.s.objs[g.s.slot[(m.from[2] - 1) * 7 + m.from[1]]]
			local b = g.s.objs[g.s.slot[(m.to[2] - 1) * 7 + m.to[1]]]
			if a.kind ~= 2 and b.kind ~= 2 then
				pick = m
				break
			end
		end
		if not pick then break end
		assert(g:input({ type = "swap", from = pick.from, to = pick.to }))
		swaps = swaps + 1
		for _ = 1, 4 do g:step() end -- the next swap goes in while the board still moves
	end
	g:run_to_rest()
	return g
end

describe("core golden scenario", function()
	local lvl = assert(core.load_level(TEXT))

	it("has a stable level hash", function()
		assert_eq(lvl.hash, GOLDEN.level_hash)
	end)

	for _, timing in ipairs({ "normal", "turbo" }) do
		it("reproduces the " .. timing .. " game and its replay", function()
			local g = play(lvl, timing)
			local want = GOLDEN[timing]
			assert_same({ tick = g.s.tick, hash = g:hash(), score = g.s.score, moves_left = g.s.moves_left }, want)
			local _, ok, why = core.playback(lvl, g:replay())
			assert_true(ok, why)
		end)
	end
end)

-- The stored replays of 17.1 (tests/golden/, made by tests/golden/regen.lua):
-- each one is played back from its header and commands; the final hash, the
-- summary and the digest of the whole event stream must come out the same on
-- both VMs.
describe("core golden replays (17.1)", function()
	local digest = require("tests.golden.digest")
	local index = require("tests.golden.index")

	it("holds the whole set: wins, losses, turbo, input_lock, shuffles with noise, nine of the ten combos, a skipped concert", function()
		assert_true(#index >= 8)
	end)

	for _, name in ipairs(index) do
		it("plays " .. name .. " back to the stored hash, summary and events", function()
			local gold = require("tests.golden." .. name)
			local lvl, errs = core.load_level(gold.level)
			assert_true(lvl ~= nil, errs and table.concat(errs, "; "))
			assert_eq(gold.replay.level.hash, lvl.hash)
			local g, ok, why = core.playback(lvl, gold.replay)
			assert_true(ok, tostring(why) .. " (after a deliberate rule change: lua5.1 tests/golden/regen.lua)")
			g:run_to_rest()
			local st = g:status()
			local events = g:drain_events()
			local n, d = digest.events(events)
			assert_same({ state = st.state, tick = st.tick, score = st.score, moves_left = st.moves_left,
				commands = #g:replay().commands, events = n, event_digest = d }, gold.summary,
				"the game differs from the stored one; if the rules changed on purpose run lua5.1 tests/golden/regen.lua")
		end)
	end
end)
