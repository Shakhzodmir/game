-- Rest, end of move, noise, shuffle (11, 12.2) and the end of the level (13).

local C = require("core.const")
local R = require("core.rng")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
local P1 = { "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }

local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or P1)
	return g
end

local function types(ev)
	local out = {}
	for _, e in ipairs(ev) do out[#out + 1] = e.type end
	return out
end

describe("core flow: rest (11)", function()
	it("rest_flag follows the board: cleared by commands, set again at rest", function()
		local g = fresh()
		g:step()
		assert_true(g.s.rest_flag)
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		assert_false(g.s.rest_flag)
		g:step()
		assert_false(g.s.rest_flag)
		local n = g:run_to_rest()
		assert_true(n > 20)
		assert_true(g.s.rest_flag)
		assert_true(g:is_stable())
		assert_eq(g:run_to_rest(), 0)
	end)

	it("clears the end-of-move queue at rest and goes out of moves at 0", function()
		local g = fresh(nil, { moves = 5 })
		g.s.moves_left = 1
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		g:run_to_rest()
		assert_same(g.s.eom, {})
		assert_eq(g:status().state, "out_of_moves")
		assert_false(g:status().stuck)
		local st = H.of_type(g:drain_events(), "state")
		assert_same(st[#st], { t = g.s.tick, type = "state", state = "out_of_moves" })
		assert_true(g.s.rest_flag, "boosters stay possible")
	end)
end)

describe("core flow: microphones (10.4)", function()
	it("delivers an idle mic on an exit in step 7 of every tick", function()
		local deliver = { goals = { { type = "deliver", count = 2 } }, mic = { total = 2, on_board_max = 2, gap_moves = 0 },
			slots = { { at = { 0, 3 }, type = "mic" } } }
		local g = fresh({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "Mrggbg" }, deliver)
		g.s.on_board, g.s.released = 1, 1
		local mic = H.obj_at(g, 1, 6)
		assert_true(g.s.exit[31])
		g:step()
		local ev = g:drain_events()
		assert_same(ev, {
			{ t = 1, type = "mic_delivered", id = mic.id, x = 1, y = 6 },
			{ t = 1, type = "goal", index = 1, left = 1 },
		})
		assert_eq(mic.state, C.S_CLEAR)
		assert_eq(g.s.on_board, 0)
		assert_same({ g.s.vac_mv[31], g.s.vac_wv[31] }, { mic.mv, mic.wv })
		for _ = 1, 9 do g:step() end
		assert_eq(g.s.objs[mic.id], nil)
	end)
end)

describe("core flow: queries (17.3)", function()
	it("cells() and status() describe the board and the game", function()
		local g = fresh(nil, { floor = { { at = { 1, 0 }, hp = 2 } }, overlay = { { at = { 2, 2 }, type = "wires", hp = 1 } } })
		local cells = g:cells()
		assert_eq(#cells, 36)
		assert_same(cells[2], { exists = true, spawner = true, exit = false, floor = 2, wires = 0 })
		assert_same(cells[15], { exists = true, spawner = false, exit = false, floor = 0, wires = 1 })
		assert_same(g:status(), { state = "playing", stuck = false, tick = 0, moves_left = 20, score = 0, goals = { 999 } })
		assert_eq(g:result(), nil)
		local p = g:pieces()[1]
		assert_same(p, { id = 1, x = 1, y = 1, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0,
			hidden = false, pinned = false })
	end)
end)

describe("core flow: noise growth (11)", function()
	local ROWS = { "rrgrby", "yrgbyr", "rgNyrg", "gbyrgb", "byrgby", "yrggbg" }

	it("grows one noise per queued action that did not hit noise", function()
		local g = fresh(ROWS)
		local copy = { unpack(g.s.rng[R.EFFECTS]) }
		g:input({ type = "swap", from = { 5, 6 }, to = { 6, 6 } })
		g:run_to_rest()
		local ev = H.of_type(g:drain_events(), "noise_spread")
		assert_eq(#ev, 1)
		-- pairs: noise (3,3) with (3,2) up, (2,3) left, (4,3) right, (3,4) down
		local n = R.int(copy, 4)
		local want = ({ { 3, 2 }, { 2, 3 }, { 4, 3 }, { 3, 4 } })[n]
		assert_same({ ev[1].fx, ev[1].fy, ev[1].x, ev[1].y }, { 3, 3, want[1], want[2] })
		local p = g.s.objs[ev[1].id]
		assert_same({ p.kind, p.blocker, p.hp }, { C.K_BLOCKER, C.BK_NOISE, 1 })
	end)

	it("does not grow after an action whose cascade hit noise", function()
		local g = fresh({ "rrgrby", "Nrgbyr", "rgbyrg", "gbyrgN", "byrgby", "yrggbg" })
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		g:run_to_rest()
		local ev = g:drain_events()
		assert_eq(#H.of_type(ev, "noise_spread"), 0)
		assert_eq(#H.of_type(ev, "destroy"), 1)
	end)

	it("credits an action merged into a credited one (1.3.10)", function()
		local g = fresh(ROWS)
		g.s.eom = { { a = 1, noise_hit = false, merged = 2 }, { a = 2, noise_hit = true, merged = 0 },
			{ a = 3, noise_hit = false, merged = 0 } }
		g:step()
		assert_eq(#H.of_type(g:drain_events(), "noise_spread"), 1, "only action 3 grows noise")
		assert_same(g.s.eom, {})
	end)

	it("never grows onto spawner cells or wired pieces", function()
		local g = fresh({ "rrNrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" })
		g.s.wires[9] = 1 -- (3,2) under the noise
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		g:step()
		assert_same(H.of_type(g:drain_events(), "noise_spread"), {})
	end)
end)

describe("core flow: shuffle (12.2)", function()
	it("shuffles a board without moves at rest and locks the moved pieces", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_false(g:has_move())
		g:step()
		local ev = g:drain_events()
		assert_same(types(ev), { "shuffle" })
		assert_eq(ev[1].duration, 30)
		assert_true(#ev[1].moves > 0)
		local o = g.s.objs[ev[1].moves[1].id]
		assert_same({ o.state, o.tk, o.td }, { C.S_SWAP, C.TM_LOCK, 31 })
		assert_false(g.s.rest_flag)
		assert_eq(g.s.moves_left, 20, "no move spent")
		for _ = 1, 30 do g:step() end
		assert_eq(o.state, C.S_IDLE)
		assert_eq(o.settle, 31)
		assert_true(g:has_move())
	end)

	it("falls back to a Riff from a wired piece, then from noise, then gets stuck", function()
		local g = fresh({ "MMMMMM", "MMMMMM", "MMMrMM", "MMMMMM", "MMMMMM", "MMMMMM" })
		g.s.wires[16] = 1
		g:step()
		local ev = g:drain_events()
		assert_same(types(ev), { "freed", "shuffle" })
		assert_same(ev[2].riff, { id = 16, x = 4, y = 3, from = "wires" })
		assert_eq(g.s.wires[16], 0)
		assert_eq(g.s.objs[16].special, C.SP_RIFF)

		local g2 = fresh({ "MMMMMM", "MMMMMM", "MMMNMM", "MMMMMM", "MMMMMM", "MMMMMN" }, {
			goals = { { type = "break", item = "noise", count = 1 } },
			slots = { { at = { 0, 0 }, type = "noise" } },
		})
		g2:step()
		ev = g2:drain_events()
		assert_same(types(ev), { "destroy", "shuffle" }, "not the last noise: no goal")

		local g3 = fresh({ "MMMMMM", "MMMMMM", "MMMNMM", "MMMMMM", "MMMMMM", "MMMMMM" }, {
			goals = { { type = "break", item = "noise", count = 1 } },
			slots = { { at = { 0, 0 }, type = "noise" } },
		})
		g3:step()
		ev = g3:drain_events()
		assert_same(types(ev), { "destroy", "goal", "state", "shuffle" }, "the last noise counts")

		local g4 = fresh({ "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM" })
		g4:step()
		ev = g4:drain_events()
		assert_same(ev, { { t = 1, type = "state", state = "out_of_moves", reason = "stuck" } })
		assert_true(g4:status().stuck)
		assert_same({ g4:input({ type = "continue", moves = 5 }) }, { false, "no_candidates" })
	end)

	it("remix shuffles at execution and reports ok = false with fewer than two candidates", function()
		local g = fresh()
		g:step()
		assert_same({ g:input({ type = "booster", booster = "remix" }) }, { true, "ok" })
		g:step()
		local ev = g:drain_events()
		assert_eq(ev[1].type, "booster")
		assert_true(ev[1].ok)
		assert_eq(ev[2].type, "shuffle")
		local g2 = fresh()
		g2:step()
		g2:input({ type = "booster", booster = "remix" })
		H.board(g2, { "MMMMMM", "MMMMMM", "MMMrMM", "MMMMMM", "MMMMMM", "MMMMMM" })
		g2:step()
		assert_same(g2:drain_events()[1], { t = 2, type = "booster", booster = "remix", ok = false })
		assert_same(g2.s.unplaced, { C.IT_REMIX })
	end)
end)

describe("core flow: win and final concert (13)", function()
	local function winning_game(moves_left, timing)
		local g = fresh(nil, { goals = { { type = "collect", color = "red", count = 3 } } }, { timing = timing })
		g.s.moves_left = moves_left
		g.s.goal_left = { 3 }
		return g
	end

	it("goes to won_wait at the last goal, then to concert at rest with phase records", function()
		local g = winning_game(4)
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		for _ = 1, 11 do g:step() end
		local ev = g:drain_events()
		local k = 0
		for i, e in ipairs(ev) do
			if e.type == "state" then k = i end
		end
		assert_same(ev[k], { t = 11, type = "state", state = "won_wait" })
		assert_same({ ev[k - 1].type, ev[k - 1].left }, { "goal", 0 })
		assert_same({ g:input({ type = "swap", from = { 5, 6 }, to = { 6, 6 } }) }, { false, "bad_state" })
		-- run until the concert starts
		while g.s.state == C.G_WON_WAIT do g:step() end
		g:drain_events()
		local s = g.s
		local tc = s.tick
		assert_eq(s.tc, tc)
		assert_eq(s.moves_at_win, 3)
		assert_eq(s.concert_A, 1)
		local q = {}
		for _, r in ipairs(s.queue) do q[#q + 1] = { r.due, r.kind, r.d[1] or 0 } end
		assert_same(q, {
			{ tc + 2, C.R_CONCERT_A, 1 }, { tc + 4, C.R_CONCERT_A, 2 }, { tc + 6, C.R_CONCERT_A, 3 },
			{ tc + 9, C.R_CONCERT_B, 0 },
		})
		g:step()
		g:step()
		ev = g:drain_events()
		assert_same(types(ev), { "moves", "concert_riff", "score" })
		local riff = s.objs[ev[2].id]
		assert_same({ riff.special, riff.axis, riff.mv, riff.wv }, { C.SP_RIFF, C.AX_H, 2, 0 })
		assert_eq(ev[3].delta, 300)
	end)

	it("plays the concert to complete and reports the result", function()
		local g = winning_game(2)
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		local n = 0
		while g.s.state ~= C.G_COMPLETE do
			g:step()
			n = n + 1
			assert_true(n < 5000, "concert must end")
		end
		assert_eq(g.s.moves_left, 0)
		local r = g:result()
		assert_eq(r.moves_at_win, 1, "2 - the winning swap")
		assert_eq(r.stars, 1)
		assert_true(r.won)
		assert_true(r.score >= 60 + 300, "match + one concert Riff")
		assert_same(r.unplaced, {})
		assert_eq(g.s.rounds >= 1, true)
	end)

	it("skip switches the concert to turbo", function()
		local g = winning_game(3)
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		while g.s.state ~= C.G_CONCERT do g:step() end
		assert_same({ g:input({ type = "skip" }) }, { true, "ok" })
		assert_eq(g.s.queue[1].due, g.s.tick + 1)
		local n = 0
		while g.s.state ~= C.G_COMPLETE do
			g:step()
			n = n + 1
		end
		assert_true(n < 60, "turbo concert is quick: " .. n)
	end)
end)

-- Audit C additions ----------------------------------------------------------

local M = require("core.match")
local SH = require("core.shuffle")

describe("core flow: what rest means (11)", function()
	it("each of the four conditions alone breaks it", function()
		local g = fresh()
		g:step()
		assert_true(g:is_stable())
		-- an object that is not idle
		for _, st in ipairs({ C.S_FALL, C.S_SWAP, C.S_CLEAR, C.S_ARMED }) do
			local g2 = fresh()
			g2:step()
			H.obj_at(g2, 2, 2).state = st
			assert_false(g2:is_stable(), "state " .. st)
		end
		-- a record in the queue
		local g3 = fresh()
		g3:step()
		g3.s.queue[1] = { due = 9, seq = 1, kind = C.R_CONCERT_B, d = {} }
		assert_false(g3:is_stable())
		-- the dirty flag
		local g4 = fresh()
		g4:step()
		g4.s.dirty = true
		assert_false(g4:is_stable())
		-- an assignment in the last pass
		local g5 = fresh()
		g5:step()
		g5.s.last_assign = 1
		assert_false(g5:is_stable())
	end)

	it("a board with a hole that only a blocker keeps open is at rest", function()
		local g = fresh({ "rrgrby", "XXXbyr", "r_byrg", "gbyrgb", "byrgby", "yrggbg" })
		g:step()
		g:step()
		assert_true(g:is_stable(), "holes are legal at rest")
	end)
end)

describe("core flow: noise growth, order and randomness (11)", function()
	-- The rule written out for a picture: noise 'n', plain piece 'p', blocker 'x';
	-- row 1 holds the spawners of the 6x6 level.
	local function grow(kinds, actions, stream)
		local out = {}
		for _ = 1, actions do
			local pairs_ = {}
			for y = 1, 6 do
				for x = 1, 6 do
					if kinds[y][x] == "n" then
						for _, d in ipairs({ { 0, -1 }, { -1, 0 }, { 1, 0 }, { 0, 1 } }) do
							local nx, ny = x + d[1], y + d[2]
							if nx >= 1 and nx <= 6 and ny >= 2 and ny <= 6 and kinds[ny][nx] == "p" then
								pairs_[#pairs_ + 1] = { x, y, nx, ny }
							end
						end
					end
				end
			end
			if #pairs_ > 0 then
				local p = pairs_[R.int(stream, #pairs_)]
				kinds[p[4]][p[3]] = "n"
				out[#out + 1] = { fx = p[1], fy = p[2], x = p[3], y = p[4] }
			end
		end
		return out
	end

	it("rebuilds the pair list per action; one effects draw per growth; none without a pair", function()
		local rows = { "rrgrby", "yrgbyr", "rgbyrg", "gbNrgb", "byrgNy", "yrggbg" }
		local g = fresh(rows)
		local kinds = {}
		for y = 1, 6 do
			kinds[y] = {}
			for x = 1, 6 do kinds[y][x] = rows[y]:sub(x, x) == "N" and "n" or "p" end
		end
		local copy = H.stream_copy(g, R.EFFECTS)
		local want = grow(kinds, 4, copy)
		g.s.eom = {
			{ a = 1, noise_hit = false, merged = 0 }, { a = 2, noise_hit = false, merged = 0 },
			{ a = 3, noise_hit = true, merged = 0 }, { a = 4, noise_hit = false, merged = 0 },
			{ a = 5, noise_hit = false, merged = 0 },
		}
		-- action 3 hit noise; the other four grow one noise each
		g:step()
		local ev = H.of_type(g:drain_events(), "noise_spread")
		assert_eq(#ev, 4)
		for k = 1, 4 do
			assert_same({ ev[k].fx, ev[k].fy, ev[k].x, ev[k].y }, { want[k].fx, want[k].fy, want[k].x, want[k].y }, "growth " .. k)
			local p = g.s.objs[ev[k].id]
			assert_same({ p.kind, p.blocker, p.hp, p.color }, { C.K_BLOCKER, C.BK_NOISE, 1, 0 })
			assert_eq(p.state, C.S_IDLE)
		end
		assert_same(g.s.rng[R.EFFECTS], copy, "exactly the draws of the growths")
		assert_same(g.s.eom, {})
	end)

	it("a merge into an action that is not credited credits nothing; a chain of merges follows the last link", function()
		local rows = { "rrgrby", "yrgbyr", "rgNyrg", "gbyrgb", "byrgby", "yrggbg" }
		local g = fresh(rows)
		g.s.eom = { { a = 1, noise_hit = false, merged = 2 }, { a = 2, noise_hit = false, merged = 0 },
			{ a = 3, noise_hit = true, merged = 0 } }
		g:step()
		assert_eq(#H.of_type(g:drain_events(), "noise_spread"), 2, "actions 1 and 2 grow, 3 hit noise")
		local g2 = fresh(rows)
		g2.s.eom = { { a = 1, noise_hit = false, merged = 2 }, { a = 2, noise_hit = false, merged = 3 },
			{ a = 3, noise_hit = true, merged = 0 } }
		g2:step()
		assert_eq(#H.of_type(g2:drain_events(), "noise_spread"), 0, "1 -> 2 -> 3, and 3 hit noise")
		-- a merge into an action that is no longer in the queue (taken back) credits nothing
		local g3 = fresh(rows)
		g3.s.eom = { { a = 1, noise_hit = false, merged = 2 }, { a = 3, noise_hit = false, merged = 0 } }
		g3:step()
		assert_eq(#H.of_type(g3:drain_events(), "noise_spread"), 2)
	end)

	it("keeps id and label of the piece that turns into noise", function()
		local g = fresh({ "XXXXXX", "XXXXXX", "XXXXXX", "XXNrXX", "XXXXXX", "XXXXXX" })
		local victim = H.obj_at(g, 4, 4)
		victim.mv, victim.wv, victim.settle = 4, 2, 7
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		g:step()
		local ev = H.of_type(g:drain_events(), "noise_spread")
		assert_same(ev, { { t = 1, type = "noise_spread", fx = 3, fy = 4, x = 4, y = 4, id = victim.id } })
		assert_eq(g.s.objs[victim.id], victim, "converted in place")
		assert_same({ victim.mv, victim.wv, victim.kind, victim.blocker }, { 4, 2, C.K_BLOCKER, C.BK_NOISE })
	end)

	it("without noise on the board the queue is dropped and no number is spent", function()
		local g = fresh()
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 }, { a = 2, noise_hit = false, merged = 0 } }
		local copy = H.stream_copy(g, R.EFFECTS)
		g:step()
		assert_same(g.s.rng[R.EFFECTS], copy)
		assert_same(g.s.eom, {})
		assert_same(H.of_type(g:drain_events(), "noise_spread"), {})
	end)

	it("noise with no free neighbour spends nothing", function()
		local g = fresh({ "rrgrby", "yrgbyr", "xxxyrg", "xNxbyr", "xxxgby", "yrggbg" })
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		local copy = H.stream_copy(g, R.EFFECTS)
		g:step()
		assert_same(g.s.rng[R.EFFECTS], copy)
	end)

	it("is not applied while the field moves, and waits for the rest", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgNyrg", "gbyrgb", "byrgby", "yrggbg" })
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		H.obj_at(g, 1, 4).state = C.S_FALL
		H.obj_at(g, 1, 4).offy = 100
		g:step()
		assert_eq(#g.s.eom, 1, "the queue stays until the rest")
		assert_same(H.of_type(g:drain_events(), "noise_spread"), {})
	end)

	it("is applied before the moves check: growth, then out of moves, then shuffle", function()
		-- one legal move, (4,4)-(4,5), and the noise next to the only other piece of its line
		local rows = { "XXXXXX", "XXXXXX", "XXNXXX", "XXrgrX", "XXXrXX", "XXXXXX" }
		local g = fresh(rows)
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		assert_true(g:has_move())
		g:step()
		local ev = g:drain_events()
		assert_same(types(ev), { "noise_spread", "shuffle" })
		assert_eq(ev[2].riff.from, "piece")
		-- with no moves left, out_of_moves wins over the shuffle
		local g2 = fresh(rows)
		g2.s.moves_left = 0
		g2.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		g2:step()
		ev = g2:drain_events()
		assert_same(types(ev), { "noise_spread", "state" })
		assert_eq(g2:status().state, "out_of_moves")
	end)

	it("is not done in out_of_moves, lost or complete", function()
		for _, st in ipairs({ C.G_OUT, C.G_LOST, C.G_COMPLETE }) do
			local g = fresh({ "rrgrby", "yrgbyr", "rgNyrg", "gbyrgb", "byrgby", "yrggbg" })
			g.s.state = st
			g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
			g:step()
			assert_same(H.of_type(g:drain_events(), "noise_spread"), {}, "state " .. st)
		end
	end)
end)

describe("core flow: shuffle (12.2) written out", function()
	local PIC = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }

	local function flat(rows)
		local out = {}
		for y = 1, #rows do
			for x = 1, #rows[1] do out[#out + 1] = rows[y]:sub(x, x) end
		end
		return out
	end

	local function unflat(f, W)
		local rows = {}
		for y = 1, #f / W do rows[y] = table.concat(f, "", (y - 1) * W + 1, y * W) end
		return rows
	end

	-- the attempt test of 12.2: no match and a legal pair
	local function good(rows)
		local g = fresh(rows)
		return not M.any_match(M.color_map(g.s), 6, 6) and g:has_move()
	end

	it("item 1: Fisher-Yates from n down to 2 with int(i), up to 50 attempts, ids move with the pieces", function()
		local g = fresh(PIC)
		local st = H.stream_copy(g, R.SHUFFLE)
		local ids = {}
		for i = 1, 36 do ids[i] = g.s.slot[i] end
		local f = flat(PIC)
		local want
		for _ = 1, 50 do
			local a = {}
			for i = 1, 36 do a[i] = i end
			for i = 36, 2, -1 do
				local j = R.int(st, i)
				a[i], a[j] = a[j], a[i]
			end
			local rows = {}
			local lay = {}
			for k = 1, 36 do lay[k] = f[a[k]] end
			rows = unflat(lay, 6)
			if good(rows) then
				want = { rows = rows, a = a }
				break
			end
		end
		assert_true(want ~= nil)
		g:step()
		local ev = g:drain_events()
		assert_eq(#ev, 1)
		assert_same(H.picture(g), want.rows)
		assert_same(g.s.rng[R.SHUFFLE], st, "no other draws")
		-- piece at cell k is the piece that stood at a[k]
		for k = 1, 36 do assert_eq(g.s.slot[k], ids[want.a[k]], "cell " .. k) end
		-- the event lists exactly the pieces that changed cell
		local moved = {}
		for k = 1, 36 do if want.a[k] ~= k then moved[ids[want.a[k]]] = true end end
		local n = 0
		for _, m in ipairs(ev[1].moves) do
			assert_true(moved[m.id], "moved piece " .. m.id)
			n = n + 1
		end
		local count = 0
		for _ in pairs(moved) do count = count + 1 end
		assert_eq(n, count)
		assert_same(ev[1].recolors, {})
		assert_eq(ev[1].riff, nil)
	end)

	it("item 3: when no arrangement works the original board stays and candidate int(n) becomes a Riff h", function()
		-- two plain pieces far apart on a board of blockers: no swap can ever exist
		local rows = { "XXXXXX", "XrXXXX", "XXXXXX", "XXXXXX", "XXXXgX", "XXXXXX" }
		local g = fresh(rows)
		local st = H.stream_copy(g, R.SHUFFLE)
		for _ = 1, 50 do R.int(st, 2) end -- permutation attempts: one int(2) each
		for _ = 1, 50 do R.next_int(st); R.next_int(st) end -- recolour attempts: one weighted pick per cell
		local pick = R.int(st, 2)
		g:step()
		local ev = g:drain_events()
		assert_eq(#ev, 1)
		local cell = ({ 8, 29 })[pick]
		local o = g.s.objs[g.s.slot[cell]]
		assert_same({ o.kind, o.special, o.axis, o.color }, { C.K_SPECIAL, C.SP_RIFF, C.AX_H, 0 })
		assert_same(ev[1].riff, { id = o.id, x = (cell - 1) % 6 + 1, y = math.floor((cell - 1) / 6) + 1, from = "piece" })
		assert_same(ev[1].moves, {})
		assert_same(ev[1].recolors, {})
		assert_same(g.s.rng[R.SHUFFLE], st)
		-- the other piece keeps its colour
		local other = g.s.objs[g.s.slot[({ 29, 8 })[pick]]]
		assert_eq(other.kind, C.K_REGULAR)
	end)

	it("item 2: recolours by the rule of 4.2 when no permutation works (50 attempts of n - 1 draws first)", function()
		local ALL_RED = { "rrrrrr", "rrrrrr", "rrrrrr", "rrrrrr", "rrrrrr", "rrrrrr" }
		local g = fresh(ALL_RED)
		local st = H.stream_copy(g, R.SHUFFLE)
		for _ = 1, 50 do
			for i = 36, 2, -1 do R.int(st, i) end
		end
		-- the first recolouring attempt, cell by cell
		local col = {}
		local function at(x, y) return (x >= 1 and y >= 1) and col[(y - 1) * 6 + x] or 0 end
		for i = 1, 36 do
			local x, y = (i - 1) % 6 + 1, math.floor((i - 1) / 6) + 1
			local l1, l2, u1, u2, ul = at(x - 1, y), at(x - 2, y), at(x, y - 1), at(x, y - 2), at(x - 1, y - 1)
			local allowed = {}
			for c = 1, 6 do
				local bad = (l1 == c and l2 == c) or (u1 == c and u2 == c) or (l1 == c and u1 == c and ul == c)
				if not bad then allowed[#allowed + 1] = c end
			end
			if #allowed == 0 then allowed = { 1, 2, 3, 4, 5, 6 } end
			col[i] = allowed[R.next_int(st) % #allowed + 1]
		end
		local rows, LET = {}, { "r", "o", "y", "g", "b", "p" }
		for y = 1, 6 do
			local line = {}
			for x = 1, 6 do line[x] = LET[col[(y - 1) * 6 + x]] end
			rows[y] = table.concat(line)
		end
		assert_true(good(rows), "a recolouring this simple is accepted (otherwise the test needs another board)")
		g:step()
		local ev = g:drain_events()
		assert_eq(#ev, 1)
		assert_same(H.picture(g), rows)
		assert_same(g.s.rng[R.SHUFFLE], st)
		assert_same(ev[1].moves, {})
		local want = 0
		for i = 1, 36 do if col[i] ~= 1 then want = want + 1 end end
		assert_eq(#ev[1].recolors, want, "only pieces whose colour changed")
		assert_eq(ev[1].riff, nil)
		local first = ev[1].recolors[1]
		assert_eq(first.color, C.COLOR_NAME[col[first.id]], "ids follow the cells, colours are names")
	end)

	it("failed attempts restore the original board before the Riff fallback", function()
		-- two plain pieces on a board of blockers: no arrangement has a swap
		local g = fresh({ "XXXXXX", "XrrXXX", "XXXXXX", "XXXXXX", "XXXXXX", "XXXXXX" })
		local st = H.stream_copy(g, R.SHUFFLE)
		for _ = 1, 50 do R.int(st, 2) end -- 50 permutation attempts of n = 2: one int(2) each
		for _ = 1, 50 do R.next_int(st); R.next_int(st) end -- 50 recolour attempts: one pick per cell
		local pick = R.int(st, 2)
		g:step()
		local ev = g:drain_events()
		assert_eq(ev[1].riff.from, "piece")
		assert_same(g.s.rng[R.SHUFFLE], st)
		local o = g.s.objs[g.s.slot[({ 8, 9 })[pick]]]
		assert_eq(o.special, C.SP_RIFF)
		assert_eq(o.axis, C.AX_H)
		assert_same({ o.state, o.tk, o.td }, { C.S_SWAP, C.TM_LOCK, 31 }, "the new Riff is locked like a moved piece")
		assert_eq(g.s.objs[g.s.slot[({ 9, 8 })[pick]]].color, C.COLOR.red, "colours are restored when an attempt fails")
	end)

	it("locks the changed pieces for T.shuffle: 30 ticks, 1 in turbo; they become idle and settled, the board dirty", function()
		for _, spec in ipairs({ { "normal", 30 }, { "turbo", 1 } }) do
			local g = fresh(PIC, nil, { timing = spec[1] })
			g:step()
			local ev = g:drain_events()
			assert_eq(ev[1].duration, spec[2])
			local m = g.s.objs[ev[1].moves[1].id]
			assert_same({ m.state, m.tk, m.td }, { C.S_SWAP, C.TM_LOCK, 1 + spec[2] })
			for _ = 1, spec[2] do g:step() end
			assert_same({ m.state, m.tk, m.settle }, { C.S_IDLE, 0, 1 + spec[2] })
		end
	end)

	it("an in-game shuffle is no move: moves_left and the end-of-move queue stay", function()
		local g = fresh(PIC)
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		g:step()
		assert_eq(g.s.moves_left, 20)
	end)
end)

describe("core flow: the final concert, phase by phase (13)", function()
	local ALL_X = { "XXXXXX", "XXXXXX", "XXXXXX", "XXXXXX", "XXXXXX", "XXXXXX" }

	-- A game in won_wait at rest with `moves_left` moves and `act` = 3.
	local function ready(rows, moves_left, opts)
		local g = fresh(rows, nil, opts)
		g.s.state = C.G_WON_WAIT
		g.s.moves_left = moves_left
		g.s.act = 3
		return g
	end

	local function queue(g)
		local out = {}
		for _, r in ipairs(g.s.queue) do
			local e = { r.due, r.seq, r.kind }
			for _, v in ipairs(r.d) do e[#e + 1] = v end
			out[#out + 1] = e
		end
		return out
	end

	it("starts at the first tick of rest in won_wait: tc, moves_at_win, A, rounds, a clean queue", function()
		local g = ready(nil, 5)
		g.s.eom = { { a = 1, noise_hit = false, merged = 0 } }
		g.s.rounds = 7
		g:step()
		local s = g.s
		assert_same({ s.state, s.tc, s.moves_at_win, s.concert_A, s.rounds, #s.eom }, { C.G_CONCERT, 1, 5, 3, 0, 0 })
		assert_same(g:drain_events(), { { t = 1, type = "state", state = "concert" } })
		-- A1..A5 at tc + 2k, the start of phase B at tc + 2n + 3
		local want = {}
		for k = 1, 5 do want[k] = { 1 + 2 * k, k, C.R_CONCERT_A, k } end
		want[6] = { 1 + 10 + 3, 6, C.R_CONCERT_B }
		assert_same(queue(g), want)
	end)

	it("waits for the rest: a falling piece keeps the game in won_wait", function()
		local g = ready(nil, 5)
		H.obj_at(g, 2, 2).state, H.obj_at(g, 2, 2).offy = C.S_FALL, 3600
		g:step()
		assert_eq(g.s.state, C.G_WON_WAIT)
		assert_same(g.s.queue, {})
	end)

	it("with no moves left phase B comes T.fire_step after the start; in turbo all records go to the next tick in order", function()
		local g = ready(nil, 0)
		g:step()
		assert_same(queue(g), { { 4, 1, C.R_CONCERT_B } })
		local t = ready(nil, 3, { timing = "turbo" })
		t:step()
		assert_same(queue(t), { { 2, 1, C.R_CONCERT_A, 1 }, { 2, 2, C.R_CONCERT_A, 2 }, { 2, 3, C.R_CONCERT_A, 3 }, { 2, 4, C.R_CONCERT_B } })
	end)

	it("phase A: a move per step, a Riff on a free regular piece, axes h v h, label (A+1, 0), 300 points", function()
		local g = ready(nil, 3)
		g:step()
		g:drain_events()
		local tc = g.s.tick
		local streams = H.stream_copy(g, R.EFFECTS)
		local got = {}
		for k = 1, 3 do
			while g.s.tick < tc + 2 * k do g:step() end
			local ev = g:drain_events()
			assert_eq(ev[1].type, "moves")
			assert_eq(ev[1].left, 3 - k)
			assert_eq(ev[2].type, "concert_riff")
			assert_eq(ev[3].type, "score")
			assert_eq(ev[3].delta, 300)
			assert_eq(ev[3].t, tc + 2 * k)
			local o = g.s.objs[ev[2].id]
			assert_same({ o.kind, o.special, o.axis, o.mv, o.wv, o.state }, { C.K_SPECIAL, C.SP_RIFF, k % 2 == 1 and C.AX_H or C.AX_V, 4, 0, C.S_IDLE })
			assert_eq(ev[2].axis, k % 2 == 1 and "h" or "v")
			got[k] = o
		end
		assert_eq(g.s.moves_left, 0)
		assert_eq(g.s.score, 900)
		-- one effects draw per Riff
		for _ = 1, 3 do R.next_int(streams) end
		assert_same(g.s.rng[R.EFFECTS], streams)
	end)

	it("phase A spends the move even without a candidate and makes no Riff, no points, no draw", function()
		local g = ready(ALL_X, 2)
		g:step()
		g:drain_events()
		local streams = H.stream_copy(g, R.EFFECTS)
		for _ = 1, 4 do g:step() end
		local ev = g:drain_events()
		assert_same(ev, { { t = 3, type = "moves", left = 1 }, { t = 5, type = "moves", left = 0 } })
		assert_eq(g.s.score, 0)
		assert_same(g.s.rng[R.EFFECTS], streams)
	end)

	it("phase A never picks a wired, pinned or busy piece", function()
		local g = ready({ "XXXXXX", "XrXXXX", "XXXXXX", "XXXXgX", "XXXXXX", "XXXXXX" }, 2)
		g.s.wires[8] = 1
		g:step()
		H.obj_at(g, 5, 4).pins = { 77 }
		for _ = 1, 4 do g:step() end
		assert_eq(#H.of_type(g:drain_events(), "concert_riff"), 0)
	end)

	it("phase B arms every free special at once, by index, and fires them T.fire_step apart with (A+1, 1)", function()
		local g = ready({ "XXXXXX", "XSXXSX", "XXXXXX", "XXXXXX", "XXSXXX", "XXXXXX" }, 0)
		g:step() -- tick 1: the concert starts, phase B due at tick 4
		local a, b, c = H.obj_at(g, 2, 2), H.obj_at(g, 5, 2), H.obj_at(g, 3, 5)
		for _ = 1, 3 do g:step() end -- tick 4
		assert_eq(g.s.rounds, 1)
		assert_eq(a.state ~= C.S_IDLE, true, "the first fires in the tick of phase B")
		assert_eq(b.state, C.S_ARMED)
		assert_eq(c.state, C.S_ARMED)
		local acts = {}
		for _, r in ipairs(g.s.queue) do
			if r.kind == C.R_ACTIVATE then acts[#acts + 1] = { r.due, unpack(r.d) } end
		end
		assert_same(acts, { { 7, b.id, 11, 0, 4, 1, 0 }, { 10, c.id, 27, 0, 4, 1, 0 } })
	end)

	it("phase B leaves a pinned special alone", function()
		local g = ready({ "XXXXXX", "XSXXSX", "XXXXXX", "XXXXXX", "XXSXXX", "XXXXXX" }, 0)
		g:step() -- tick 1: the concert starts, phase B due at tick 4
		local a, b, c = H.obj_at(g, 2, 2), H.obj_at(g, 5, 2), H.obj_at(g, 3, 5)
		b.pins = { 99 }
		for _ = 1, 3 do g:step() end
		assert_eq(g.s.rounds, 1)
		assert_true(a.state ~= C.S_IDLE, "the free special at the lower index goes first")
		assert_eq(b.state, C.S_IDLE, "pinned: not armed")
		assert_eq(c.state, C.S_ARMED)
		local acts = 0
		for _, r in ipairs(g.s.queue) do
			if r.kind == C.R_ACTIVATE then acts = acts + 1 end
		end
		assert_eq(acts, 1, "only the free third special is waiting for its turn")
	end)

	it("phase C: another round while a free special is left and rounds < 20, else complete", function()
		local rows = { "XXXXXX", "XXXXXX", "XXXXXX", "XXXXXX", "XXSXXX", "XXXXXX" }
		local g = fresh(rows)
		g.s.state, g.s.rounds = C.G_CONCERT, 19
		g:step()
		assert_eq(g.s.state, C.G_CONCERT)
		assert_same(queue(g), { { 4, 1, C.R_CONCERT_B } }, "now + T.fire_step")
		local g2 = fresh(rows)
		g2.s.state, g2.s.rounds = C.G_CONCERT, 20
		g2:step()
		assert_eq(g2.s.state, C.G_COMPLETE)
		assert_same(g2:drain_events(), { { t = 1, type = "state", state = "complete" } })
		local g3 = fresh(rows, nil, { timing = "turbo" })
		g3.s.state, g3.s.rounds = C.G_CONCERT, 3
		g3:step()
		assert_same(queue(g3), { { 2, 1, C.R_CONCERT_B } }, "turbo: T.fire_step = 0 moves it to the next tick")
		-- no special at all: complete at once
		local g4 = fresh(ALL_X)
		g4.s.state = C.G_CONCERT
		g4:step()
		assert_eq(g4.s.state, C.G_COMPLETE)
	end)

	it("a whole concert on a board of specials ends in complete with every special used", function()
		local g = ready({ "XXXXXX", "XSXXRX", "XXXXXX", "XXXXXX", "XVSXXX", "XXXXXX" }, 1)
		local n = 0
		while g.s.state ~= C.G_COMPLETE and n < 2000 do
			g:step()
			n = n + 1
		end
		assert_eq(g.s.state, C.G_COMPLETE)
		assert_true(g.s.rounds >= 1 and g.s.rounds <= 20)
		for i = 1, g.s.N do
			local o = require("core.board").get(g.s, i)
			assert_true(not (o and o.kind == C.K_SPECIAL and o.state == C.S_IDLE), "an unused special in cell " .. i)
		end
	end)

	it("closes the input: only skip is accepted in won_wait and in the concert", function()
		local g = ready(nil, 5)
		g:step()
		for _, st in ipairs({ C.G_WON_WAIT, C.G_CONCERT }) do
			g.s.state = st
			for _, cmd in ipairs({
				{ type = "swap", from = { 3, 1 }, to = { 4, 1 } }, { type = "tap", at = { 1, 1 } },
				{ type = "booster", booster = "stick", at = { 1, 1 } }, { type = "continue", moves = 5 }, { type = "give_up" },
			}) do
				assert_same({ g:input(cmd) }, { false, "bad_state" }, cmd.type .. " in " .. st)
			end
			assert_eq(g:can_swap({ 3, 1 }, { 4, 1 }), "reject")
		end
		g.s.state = C.G_WON_WAIT
		assert_same({ g:input({ type = "skip" }) }, { true, "ok" })
		assert_eq(g.s.timing, C.TIMING_TURBO)
		assert_same({ g:input({ type = "skip" }) }, { true, "ok" }, "a second skip is harmless")
		g.s.state = C.G_PLAYING
		assert_same({ g:input({ type = "skip" }) }, { false, "bad_state" })
	end)

	it("moves_at_win is read after the refunds of swaps still in flight", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		assert_eq(g.s.moves_left, 19)
		g.s.state = C.G_WON_WAIT -- the last goal fell to another cascade
		H.obj_at(g, 1, 1).color = C.COLOR.blue -- ... which also took the match of the swap away
		for _ = 1, 11 do g:step() end
		assert_eq(g.s.moves_left, 20, "the refund gives the move back")
		assert_eq(g.s.state, C.G_WON_WAIT, "swap_back still in flight")
		while g.s.state == C.G_WON_WAIT do g:step() end
		assert_eq(g.s.moves_at_win, 20)
	end)
end)

describe("core flow: the result (13, 17.3)", function()
	it("stars by difficulty: easy and medium 1, hard 2, super_hard 3; nil before the end", function()
		local want = { easy = 1, medium = 1, hard = 2, super_hard = 3 }
		for name, stars in pairs(want) do -- order-independent
			local g = fresh(nil, { difficulty = name })
			assert_eq(g:result(), nil)
			g.s.state, g.s.moves_at_win, g.s.score = C.G_COMPLETE, 4, 1234
			g.s.unplaced = { C.IT_PRE_RIFF, C.IT_REMIX }
			assert_same(g:result(), { won = true, score = 1234, moves_at_win = 4, stars = stars, unplaced = { 5, 4 } }, name)
		end
	end)

	it("a lost game reports its score and the items to return, no stars", function()
		local g = fresh()
		g.s.state, g.s.score = C.G_OUT, 55
		g.s.unplaced = { C.IT_CONT_RIFF }
		g:input({ type = "give_up" })
		assert_same(g:result(), { won = false, score = 55, moves_at_win = 0, stars = 0, unplaced = { 8 } })
		assert_same(g:drain_events(), { { t = 1, type = "state", state = "lost" } })
	end)
end)

describe("core flow: what a shuffle leaves behind (12.2)", function()
	local COLORS = { "b", "y", "r", "g" }
	-- the dead pattern with its four colours renamed and the rows or columns mirrored
	local function dead(perm, flip_x, flip_y)
		local base = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }
		local rows = {}
		for y = 1, 6 do
			local src = flip_y and base[7 - y] or base[y]
			if flip_x then src = string.reverse(src) end
			local line = {}
			for x = 1, 6 do
				local ch = src:sub(x, x)
				for k = 1, 4 do
					if COLORS[k] == ch then
						ch = COLORS[perm[k]]
						break
					end
				end
				line[x] = ch
			end
			rows[y] = table.concat(line)
		end
		return rows
	end

	local perms = { { 1, 2, 3, 4 }, { 2, 1, 4, 3 }, { 4, 3, 2, 1 }, { 3, 4, 1, 2 }, { 2, 3, 4, 1 }, { 1, 3, 2, 4 }, { 4, 1, 3, 2 }, { 3, 1, 4, 2 } }

	it("leaves no match, at least one legal swap, the same ids and the same colours per id", function()
		local count = 0
		for pi, perm in ipairs(perms) do
			for _, flips in ipairs({ { false, false }, { true, false }, { false, true } }) do
				local rows = dead(perm, flips[1], flips[2])
				local g = fresh(rows, nil, { seed = pi * 11 })
				assert_false(g:has_move())
				local before = {}
				for i = 1, 36 do local o = g.s.objs[g.s.slot[i]]; before[o.id] = o.color end
				g:step()
				local ev = g:drain_events()
				assert_eq(ev[1].type, "shuffle")
				for _ = 1, 30 do g:step() end
				assert_false(M.any_match(M.color_map(g.s), 6, 6))
				assert_true(g:has_move())
				assert_true(g:is_stable())
				local ids = 0
				for i = 1, 36 do
					local o = g.s.objs[g.s.slot[i]]
					ids = ids + 1
					assert_eq(o.color, before[o.id], "a permutation keeps the colour of every piece (id " .. o.id .. ")")
					assert_true(o.settle == 0 or o.settle == 31, "only the pieces that moved were locked and settled at tick 31")
				end
				assert_eq(ids, 36)
				count = count + 1
			end
		end
		assert_eq(count, 24)
	end)

	it("the Remix does the same on a board with moves", function()
		for seed = 1, 6 do
			local g = fresh({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }, nil, { seed = seed })
			g:input({ type = "booster", booster = "remix" })
			g:run_to_rest()
			assert_false(M.any_match(M.color_map(g.s), 6, 6))
			assert_true(g:has_move())
		end
	end)
end)

describe("core flow: the fallbacks of 12.2 choose with int(n) of the shuffle stream", function()
	local R = require("core.rng")
	local ALL_MIC = { "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM" }

	local function seed_with_pick(n, want)
		for seed = 1, 5000 do
			if R.int(R.stream(seed, R.SHUFFLE), n) == want then return seed end
		end
		error("no seed")
	end

	local function picture(marks)
		local rows = {}
		for y = 1, 6 do rows[y] = ALL_MIC[y] end
		for _, m in ipairs(marks) do
			rows[m[2]] = rows[m[2]]:sub(1, m[1] - 1) .. m[3] .. rows[m[2]]:sub(m[1] + 1)
		end
		return rows
	end

	it("item 4: the wired piece is the one numbered int(#wired) in index order", function()
		for want = 2, 3 do
			local g = fresh(picture({ { 2, 2, "r" }, { 5, 3, "g" }, { 3, 5, "b" } }), nil, { seed = seed_with_pick(3, want) })
			for _, c in ipairs({ 8, 17, 27 }) do g.s.wires[c] = 1 end
			local order = { 8, 17, 27 }
			local victim = g.s.objs[g.s.slot[order[want]]]
			g:step()
			local ev = g:drain_events()
			assert_eq(ev[1].type, "freed")
			assert_eq(ev[1].id, victim.id)
			assert_eq(ev[2].riff.id, victim.id)
			assert_eq(ev[2].riff.from, "wires")
			assert_eq(g.s.wires[order[want]], 0)
			for k = 1, 3 do
				if k ~= want then assert_eq(g.s.wires[order[k]], 1, "the other wires stay") end
			end
		end
	end)

	it("item 5: the noise is the one numbered int(#noise) in index order", function()
		for want = 2, 3 do
			local g = fresh(picture({ { 2, 2, "N" }, { 5, 3, "N" }, { 3, 5, "N" } }), nil, { seed = seed_with_pick(3, want) })
			local order = { 8, 17, 27 }
			local victim = g.s.objs[g.s.slot[order[want]]]
			g:step()
			local ev = g:drain_events()
			assert_eq(ev[1].type, "destroy")
			assert_eq(ev[1].id, victim.id)
			assert_eq(ev[2].riff.from, "noise")
			assert_eq(victim.special, C.SP_RIFF)
			assert_eq(victim.blocker, 0)
		end
	end)

	it("pinned pieces are no shuffle candidates", function()
		local g = fresh(picture({ { 2, 2, "r" }, { 5, 3, "g" } }))
		assert_same(SH.candidates(g.s), { 8, 17 })
		H.obj_at(g, 5, 3).pins = { 4 }
		assert_same(SH.candidates(g.s), { 8 })
		g.s.rest_flag = true
		assert_same({ g:input({ type = "booster", booster = "remix" }) }, { false, "no_candidates" })
	end)
end)
