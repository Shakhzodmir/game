-- Property tests for sections 6 and 7: the independent oracles of
-- tests/core/oracle.lua watch random play (every group search, every hit,
-- every action list of the effect framework) and random hits on random
-- boards, and compare each outcome with the text of the specification.

local core = require("core.game")
local C = require("core.const")
local B = require("core.board")
local HT = require("core.hits")
local M = require("core.match")
local O = require("tests.core.oracle")
local H = require("tests.core.helper")

local function lcg(seed)
	local x = seed
	return function(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return math.floor(x / 65536) % n + 1
	end
end

-- Runs fn with the oracles installed; the errors of the oracles fail the test.
local function watched(fn)
	O.install()
	local ok, e = pcall(fn)
	O.uninstall()
	if not ok then error(e, 0) end
	if #O.errors > 0 then error(#O.errors .. " oracle errors, the first ones:\n  " .. table.concat(O.errors, "\n  "), 0) end
	return O.stats
end

-- Levels with wires, floors, blockers, columns and specials: every layer of 7.1 is reached.
local LEVELS = {
	{ rows = { "#######", "#######", "###.###", "#######", "#######", "#######", "#######" },
		extra = { moves = 25, floor = { { at = { 0, 6 }, hp = 2 }, { at = { 5, 5 }, hp = 1 } },
			overlay = { { at = { 1, 1 }, type = "wires", hp = 2 }, { at = { 4, 4 }, type = "wires", hp = 1 } },
			goals = { { type = "collect", color = "red", count = 60 }, { type = "light" } } } },
	{ rows = { "######", "######", "######", "######", "######", "######", "######" },
		extra = { moves = 20, colors = { "red", "green", "blue", "yellow" },
			slots = { { at = { 1, 3 }, type = "record_box", hp = 2 }, { at = { 3, 2 }, type = "noise" },
				{ at = { 2, 4 }, type = "column", hp = 6 } },
			goals = { { type = "break", item = "record_box", count = 1 }, { type = "collect", color = "blue", count = 80 } } } },
	{ rows = { "..####..", ".######.", "########", "########", "########", "########" },
		extra = { moves = 20, goals = { { type = "deliver", count = 3 } },
			mic = { total = 3, on_board_max = 2, gap_moves = 1 }, slots = { { at = { 3, 2 }, type = "mic" } } } },
	{ rows = { "#######", "#R#S#V#", "##D#B##", "#B#S#R#", "##V#D##", "#S#B#V#", "#######" },
		extra = { moves = 30, colors = { "red", "green", "blue", "yellow" },
			goals = { { type = "collect", color = "green", count = 300 } } } },
	{ rows = { "########", "#K##K#B#", "##A##E##", "#B#DD#S#", "##K##A##", "#SB##BR#", "########" },
		extra = { moves = 30, colors = { "red", "orange", "blue", "purple", "yellow" },
			floor = { { at = { 0, 6 }, hp = 2 }, { at = { 3, 6 }, hp = 1 }, { at = { 7, 0 }, hp = 1 }, { at = { 5, 3 }, hp = 1 } },
			goals = { { type = "break", item = "concrete", count = 3 }, { type = "light" } } } },
	{ rows = { "#######", "#######", "#######", "#######", "#######", "#######", "#######" },
		extra = { moves = 30, colors = { "red", "green", "blue", "yellow" },
			floor = { { at = { 0, 0 }, hp = 2 }, { at = { 1, 1 }, hp = 1 }, { at = { 2, 2 }, hp = 2 }, { at = { 3, 3 }, hp = 1 },
				{ at = { 4, 4 }, hp = 2 }, { at = { 5, 5 }, hp = 1 }, { at = { 6, 6 }, hp = 2 }, { at = { 4, 2 }, hp = 1 },
				{ at = { 3, 5 }, hp = 1 }, { at = { 5, 1 }, hp = 2 }, { at = { 4, 3 }, hp = 1 }, { at = { 5, 4 }, hp = 2 } },
			overlay = { { at = { 0, 1 }, type = "wires", hp = 2 }, { at = { 2, 1 }, type = "wires", hp = 1 },
				{ at = { 5, 2 }, type = "wires", hp = 2 }, { at = { 1, 4 }, type = "wires", hp = 1 },
				{ at = { 6, 5 }, type = "wires", hp = 1 }, { at = { 3, 6 }, type = "wires", hp = 2 } },
			slots = { { at = { 4, 3 }, type = "column", hp = 8 }, { at = { 1, 2 }, type = "riff", axis = "h" }, { at = { 5, 0 }, type = "sub" } },
			goals = { { type = "light" }, { type = "break", item = "column", count = 1 }, { type = "collect", color = "red", count = 200 } } } },
	{ rows = { "#######", "#######", "#######", "#######", "#######", "#######" },
		extra = { moves = 30, colors = { "red", "green", "blue", "yellow", "purple" },
			floor = { { at = { 0, 0 }, hp = 2 }, { at = { 2, 2 }, hp = 1 }, { at = { 4, 3 }, hp = 2 }, { at = { 6, 5 }, hp = 1 } },
			overlay = { { at = { 1, 0 }, type = "wires", hp = 2 }, { at = { 3, 2 }, type = "wires", hp = 1 },
				{ at = { 5, 4 }, type = "wires", hp = 2 }, { at = { 0, 4 }, type = "wires", hp = 1 } },
			slots = { { at = { 3, 3 }, type = "concrete", hp = 2 }, { at = { 5, 1 }, type = "concrete", hp = 1 },
				{ at = { 2, 4 }, type = "disco" }, { at = { 4, 0 }, type = "bird" } },
			goals = { { type = "break", item = "concrete", count = 2 }, { type = "light" } } } },
	{ rows = { "#######", "#######", "#######", "#######", "#######", "#######" },
		extra = { moves = 30, colors = { "red", "green", "blue", "yellow" },
			slots = { { at = { 1, 1 }, type = "balloon", color = "red" }, { at = { 5, 2 }, type = "balloon", color = "blue" },
				{ at = { 3, 3 }, type = "noise" }, { at = { 0, 4 }, type = "noise" }, { at = { 6, 0 }, type = "record_box", hp = 3 },
				{ at = { 2, 5 }, type = "record_box", hp = 2 }, { at = { 4, 4 }, type = "riff", axis = "v" }, { at = { 2, 2 }, type = "bird" } },
			goals = { { type = "break", item = "balloon", count = 2 }, { type = "break", item = "noise", count = 2 },
				{ type = "break", item = "record_box", count = 2 } } } },
}

local function play(lvl, seed, timing, rnd)
	local g = core.new(lvl, { seed = seed, timing = timing, boosters = { "riff" }, help = seed % 3 })
	local ticks = 0
	while g.s.state ~= C.G_COMPLETE and g.s.state ~= C.G_LOST and ticks < 1500 do
		if g.s.state == C.G_OUT then
			if rnd(3) == 1 and not g.s.stuck then
				g:input({ type = "continue", moves = 2, riff = rnd(2) == 1 })
			else
				g:input({ type = "give_up" })
			end
		elseif rnd(3) == 1 then
			local mv = g:moves()
			local r = rnd(10)
			if r <= 6 and #mv > 0 then
				local m = mv[rnd(#mv)]
				g:input({ type = "swap", from = m.from, to = m.to })
			elseif r == 7 then
				g:input({ type = "booster", booster = "stick", at = { rnd(g.s.W), rnd(g.s.H) } })
			elseif r == 8 then
				g:input({ type = "booster", booster = "row_light", row = rnd(g.s.H) })
			elseif r == 9 then
				g:input({ type = "tap", at = { rnd(g.s.W), rnd(g.s.H) } })
			else
				g:input({ type = "booster", booster = "remix" })
			end
		end
		g:step()
		ticks = ticks + 1
		g:drain_events()
	end
end

describe("core property: oracles of sections 6 and 7 watch random play", function()
	it("every group search, hit and action list matches the specification", function()
		local stats = watched(function()
			for li, spec in ipairs(LEVELS) do
				local lvl = H.load(spec.rows, spec.extra)
				for _, timing in ipairs({ "normal", "turbo" }) do
					play(lvl, li * 100 + #timing, timing, lcg(li * 31 + #timing))
				end
			end
		end)
		assert_true(stats.search > 500 and stats.groups > 100, "searches " .. stats.search .. " groups " .. stats.groups)
		assert_true(stats.hits > 3000 and stats.runs > 50, "hits " .. stats.hits .. " runs " .. stats.runs)
	end)
end)

-- A random board built by hand: every kind of content in every state, wires,
-- floors, columns, an end-of-move queue and three open goals.
local FULL7 = { "######", "######", "######", "######", "######", "######", "######" }

local function random_board(lvl, rnd)
	local g = core.new(lvl, { seed = 1 })
	local s = g.s
	local W, Hh = s.W, s.H
	s.objs = {}
	for i = 1, s.N do
		s.slot[i], s.wires[i], s.floor[i] = 0, 0, 0
	end
	local id = 0
	local function add(i, fields)
		id = id + 1
		local o = { id = id, kind = 1, color = 0, special = 0, axis = 0, blocker = 0, hp = 0, state = C.S_IDLE, cell = i,
			mv = rnd(4) - 1, wv = rnd(3) - 1, offx = 0, offy = 0, vy = 0, delay = 0, settle = 0, tk = 0, td = 0, pins = {} }
		for k, v in pairs(fields) do o[k] = v end -- order-independent
		s.objs[id] = o
		if o.blocker == C.BK_COLUMN then
			s.slot[i], s.slot[i + 1], s.slot[i + W], s.slot[i + W + 1] = id, id, id, id
		else
			s.slot[i] = id
		end
		return o
	end
	local taken = {}
	for _ = 1, rnd(2) - 1 do
		local x, y = rnd(W - 1), rnd(Hh - 1)
		local i = (y - 1) * W + x
		if not (taken[i] or taken[i + 1] or taken[i + W] or taken[i + W + 1]) then
			taken[i], taken[i + 1], taken[i + W], taken[i + W + 1] = true, true, true, true
			local st = (rnd(4) == 1) and C.S_CLEAR or C.S_IDLE
			local o = add(i, { kind = C.K_BLOCKER, blocker = C.BK_COLUMN, hp = rnd(3), state = st })
			if st == C.S_CLEAR then o.tk, o.td = C.TM_CLEAR, 9 end
		end
	end
	for i = 1, s.N do
		if not taken[i] then
			local r = rnd(20)
			if r <= 8 then
				local st, q = C.S_IDLE, rnd(10)
				if q == 1 then st = C.S_FALL elseif q == 2 then st = C.S_SWAP elseif q == 3 then st = C.S_CLEAR end
				local o = add(i, { kind = C.K_REGULAR, color = rnd(3), state = st })
				if st == C.S_FALL then o.offy, o.vy = 1800, 300 end
				if st == C.S_CLEAR then o.tk, o.td = C.TM_CLEAR, 9 end
				if st == C.S_SWAP then o.tk, o.td = C.TM_SWAP, 9 end
				if st == C.S_IDLE and rnd(4) == 1 then s.wires[i] = rnd(2) end
			elseif r == 9 then
				add(i, { kind = C.K_SPECIAL, special = rnd(4), axis = C.AX_H, state = (rnd(3) == 1) and C.S_ARMED or C.S_IDLE })
			elseif r == 10 then
				add(i, { kind = C.K_MIC })
			elseif r == 11 then
				add(i, { kind = C.K_BLOCKER, blocker = C.BK_BOX, hp = rnd(3) })
			elseif r == 12 then
				add(i, { kind = C.K_BLOCKER, blocker = C.BK_CONCRETE, hp = rnd(2) })
			elseif r == 13 then
				add(i, { kind = C.K_BLOCKER, blocker = C.BK_NOISE, hp = 1, state = (rnd(4) == 1) and C.S_CLEAR or C.S_IDLE })
			elseif r == 14 then
				add(i, { kind = C.K_BLOCKER, blocker = C.BK_BALLOON, hp = 1, color = rnd(3) })
			end
			if rnd(4) == 1 then s.floor[i] = rnd(2) end
		end
	end
	s.next_piece_id = id + 1
	-- goals of the fuzz only: the level table is shared, so the game gets a proxy
	s.level = setmetatable({}, { __index = lvl })
	s.level.goals = {
		{ type = C.GOAL_COLLECT, param = 1, count = 4 }, { type = C.GOAL_BREAK, param = C.BK_BOX, count = 2 },
		{ type = C.GOAL_LIGHT, param = 0, count = 5 },
	}
	s.goal_left = { 4, 2, 5 }
	s.eom = {}
	for a = 1, 3 do s.eom[#s.eom + 1] = { a = a, noise_hit = false, merged = 0 } end
	s.act = 3
	return g
end

describe("core property: hits on random boards (7.1, 7.3, 7.4)", function()
	it("each hit of every source kind matches the oracle", function()
		local lvl = H.load(FULL7, { moves = 30 })
		local rnd = lcg(12345)
		local stats = watched(function()
			for _ = 1, 500 do
				local g = random_board(lvl, rnd)
				local s = g.s
				s.tick, s.now, s.phase = 9, 10, 3
				local srcs = {}
				for k = 1, 3 do
					local kind = rnd(3)
					local src = HT.new_source(s, kind, rnd(3), rnd(3), kind ~= C.SRC_EFFECT and rnd(3) or 0)
					if kind == C.SRC_EFFECT and rnd(3) == 1 then src.all_layers = true end
					if kind == C.SRC_EFFECT and rnd(3) == 1 then
						for i = 1, s.N do
							local o = B.get(s, i)
							if o and o.kind == C.K_SPECIAL and o.state == C.S_ARMED then
								src.own, src.centre = { o.id }, i
								break
							end
						end
					end
					srcs[k] = src
				end
				for _ = 1, 25 do
					local src = srcs[rnd(3)]
					local cell = rnd(s.N)
					if rnd(6) == 1 and src.centre ~= 0 then cell = src.centre end
					s.in_group = src.kind ~= C.SRC_EFFECT and rnd(2) == 1
					HT.hit(s, cell, src, src.kind == C.SRC_MATCH and rnd(10) == 1)
					s.in_group = false
					s.state = C.G_PLAYING
					if rnd(3) == 1 then s.dirty = false end
				end
			end
		end)
		assert_true(stats.hits >= 12000)
	end)
end)

describe("core property: match_at agrees with the group search", function()
	it("a cell is in a match exactly when it is in a group", function()
		local rnd = lcg(99)
		for _ = 1, 300 do
			local W, Hh = 5 + rnd(4), 5 + rnd(5)
			local col = {}
			for i = 1, W * Hh do col[i] = rnd(4) == 1 and 0 or rnd(3) end
			local ingroup = {}
			for _, g in ipairs(O.brute_groups(col, W, Hh)) do
				for _, c in ipairs(g.cells) do ingroup[c] = true end
			end
			for p = 1, W * Hh do
				assert_eq(M.match_at(col, W, Hh, p), ingroup[p] == true, "cell " .. p)
			end
		end
	end)
end)
