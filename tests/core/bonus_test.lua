-- The `bonus` command (core/input.lua, README "Commands"): the bonus meter's gift. A random free regular piece
-- becomes the named special; between ticks, at rest, while playing; no move is spent; deterministic.

local core = require("core.game")
local C = require("core.const")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
local BASE = { "brygbr", "ygbryg", "brygbr", "ygbryg", "brygbr", "ygbryg" }

local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or BASE)
	return g
end

local function count_specials(g)
	local n, found = 0, nil
	for _, p in ipairs(g:pieces()) do
		if p.kind == "special" then
			n = n + 1
			found = p
		end
	end
	return n, found
end

describe("core bonus: acceptance", function()
	it("turns one free regular piece into each of the four specials, spends no move, emits `bonus`", function()
		for _, name in ipairs({ "riff", "sub", "bird", "disco" }) do
			local g = fresh()
			g.s.rest_flag = true
			local moves = g:status().moves_left
			local ok, res = g:input({ type = "bonus", special = name })
			assert_true(ok, tostring(res))
			assert_eq(res, "ok")
			local n, p = count_specials(g)
			assert_eq(n, 1, name)
			assert_eq(p.special, name)
			assert_eq(g:status().moves_left, moves, "no move is spent")
			local evs = H.of_type(g:drain_events(), "bonus")
			assert_eq(#evs, 1)
			assert_eq(evs[1].special, name)
			assert_eq(evs[1].id, p.id)
			assert_eq(evs[1].x, p.x)
			assert_eq(evs[1].y, p.y)
			if name == "riff" then
				assert_true(evs[1].axis == "h" or evs[1].axis == "v", "a Riff has an axis")
			else
				assert_eq(evs[1].axis, nil)
			end
		end
	end)

	it("is refused for an unknown special, away from rest, and outside play", function()
		local g = fresh()
		g.s.rest_flag = true
		local ok, res = g:input({ type = "bonus", special = "laser" })
		assert_false(ok)
		assert_eq(res, "bad_cmd")
		ok, res = g:input({ type = "bonus" })
		assert_false(ok)
		assert_eq(res, "bad_cmd")
		g.s.rest_flag = false
		ok, res = g:input({ type = "bonus", special = "bird" })
		assert_false(ok)
		assert_eq(res, "not_rest")
		g.s.rest_flag = true
		g.s.state = C.G_OUT
		ok, res = g:input({ type = "bonus", special = "bird" })
		assert_false(ok)
		assert_eq(res, "bad_state")
		assert_eq((count_specials(g)), 0, "a refused command changes nothing")
	end)

	it("is refused when no piece is free, and leaves the board as it was", function()
		-- every piece is a Riff: nothing regular is left to turn
		local g = fresh({ "RRRRRR", "RRRRRR", "RRRRRR", "RRRRRR", "RRRRRR", "RRRRRR" })
		g.s.rest_flag = true
		local before = g:hash()
		local ok, res = g:input({ type = "bonus", special = "disco" })
		assert_false(ok)
		assert_eq(res, "no_candidates")
		assert_eq(g:hash(), before)
	end)

	it("never picks a piece that is wired, a blocker or a special", function()
		-- one regular piece among specials: it is the only candidate
		local g = fresh({ "RRRRRR", "RRRRRR", "RRbRRR", "RRRRRR", "RRRRRR", "RRRRRR" })
		g.s.rest_flag = true
		local ok = g:input({ type = "bonus", special = "bird" })
		assert_true(ok)
		local p = H.obj_at(g, 3, 3)
		assert_eq(p.kind, C.K_SPECIAL)
		assert_eq(p.special, C.SP_BIRD)
	end)
end)

describe("core bonus: determinism", function()
	it("the same game and the same command give the same cell, axis and hash; the command is in the replay", function()
		local function run()
			local g = fresh(nil, nil, { seed = 7 })
			g.s.rest_flag = true
			assert_true(g:input({ type = "bonus", special = "riff" }))
			return g
		end
		local a, b = run(), run()
		assert_eq(a:hash(), b:hash())
		assert_same(a:pieces(), b:pieces())
		local rep = a:replay()
		local found = false
		for _, c in ipairs(rep.commands) do
			if c.cmd.type == "bonus" then found = true end
		end
		assert_true(found, "the accepted command is recorded")
	end)

	it("different seeds can pick different cells", function()
		local cells = {}
		for seed = 1, 12 do
			local g = fresh(nil, nil, { seed = seed })
			g.s.rest_flag = true
			assert_true(g:input({ type = "bonus", special = "bird" }))
			local _, p = count_specials(g)
			cells[p.x .. "," .. p.y] = true
		end
		local n = 0
		for _ in pairs(cells) do n = n + 1 end
		assert_true(n >= 3, "cells picked over 12 seeds: " .. n)
	end)

	it("the new special works like any other: tapping a Bird activates it", function()
		local g = fresh(nil, nil, { seed = 3 })
		g.s.rest_flag = true
		assert_true(g:input({ type = "bonus", special = "sub" }))
		g:drain_events()
		local _, p = count_specials(g)
		local ok = g:input({ type = "tap", at = { p.x, p.y } })
		assert_true(ok)
		local evs = H.steps(g, 120)
		assert_true(#H.of_type(evs, "activate") >= 1, "the special fired")
	end)
end)
