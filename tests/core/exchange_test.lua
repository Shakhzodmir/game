-- The Crossfader booster (core-rules.md 5.3 `swap`, 5.1.2, 5.1.3, 6.2.1, 14, 16, 17.2): an exchange of two
-- pieces anywhere on the board. Written from the text of the specification, with a brute-force match
-- oracle of its own, the oracles of tests/core/oracle.lua watching the resolution and an oracle of the
-- acceptance rules for random boards.

local core = require("core.game")
local C = require("core.const")
local O = require("tests.core.oracle")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- a board without a match (the pattern of H.rows): odd rows brygbr, even rows ygbryg
local BASE = { "brygbr", "ygbryg", "brygbr", "ygbryg", "brygbr", "ygbryg" }
-- two greens at (1,1) (2,1): the exchange (3,1) <-> (6,6) puts the green of (6,6) into the row, four in a line
local FOUR = { "ggygbr", "ygbryg", "brygbr", "ygbryg", "brygbr", "ygbryg" }
-- FOUR with a green at (5,2) too: a swap that brings a green into (5,1) is a move only once the exchange is done
local FIVE = { "ggygbr", "ygbrgg", "brygbr", "ygbryg", "brygbr", "ygbryg" }
-- the same with a yellow at (4,1): the same exchange makes exactly three greens
local THREE = { "ggyybr", "ygbryg", "brygbr", "ygbryg", "brygbr", "ygbryg" }

local function fresh(rows, extra, opts, pic)
	local g = H.game(pic or FULL, extra, opts)
	H.board(g, rows or BASE)
	return g
end

local function cmd(ax, ay, bx, by)
	return { type = "booster", booster = "swap", at = { ax, ay }, to = { bx, by } }
end

local function exchange(g, ax, ay, bx, by)
	return { g:input(cmd(ax, ay, bx, by)) }
end

local function cell(g, x, y)
	return (y - 1) * g.s.W + x
end

local function types(events)
	local out = {}
	for _, e in ipairs(events) do out[#out + 1] = e.type end
	return out
end

-- Brute-force oracle of a match on a picture: a line of three or a 2x2 square of one colour letter.
local function has_match(rows)
	local Hh, W = #rows, #rows[1]
	local function at(x, y)
		if x < 1 or y < 1 or x > W or y > Hh then return nil end
		local ch = rows[y]:sub(x, x)
		if ch:match("[rogybp]") then return ch end
		return nil
	end
	for y = 1, Hh do
		for x = 1, W do
			local c = at(x, y)
			if c then
				if at(x + 1, y) == c and at(x + 2, y) == c then return true end
				if at(x, y + 1) == c and at(x, y + 2) == c then return true end
				if at(x + 1, y) == c and at(x, y + 1) == c and at(x + 1, y + 1) == c then return true end
			end
		end
	end
	return false
end

-- A match through cell (x, y): a line of three or a 2x2 square of its colour (5.1.2).
local function match_through(rows, x, y)
	local Hh, W = #rows, #rows[1]
	local function at(px, py)
		if px < 1 or py < 1 or px > W or py > Hh then return nil end
		local ch = rows[py]:sub(px, px)
		if ch:match("[rogybp]") then return ch end
		return nil
	end
	local c = at(x, y)
	if not c then return false end
	local function run(dx, dy)
		local n, k = 1, 1
		while at(x + k * dx, y + k * dy) == c do n, k = n + 1, k + 1 end
		k = 1
		while at(x - k * dx, y - k * dy) == c do n, k = n + 1, k + 1 end
		return n
	end
	if run(1, 0) >= 3 or run(0, 1) >= 3 then return true end
	for dx = -1, 0 do
		for dy = -1, 0 do
			if at(x + dx, y + dy) == c and at(x + dx + 1, y + dy) == c and at(x + dx, y + dy + 1) == c
				and at(x + dx + 1, y + dy + 1) == c then
				return true
			end
		end
	end
	return false
end

-- A picture with the pieces of two cells exchanged.
local function exchanged(rows, ax, ay, bx, by)
	local out = {}
	for y, r in ipairs(rows) do out[y] = r end
	local ca, cb = rows[ay]:sub(ax, ax), rows[by]:sub(bx, bx)
	local function put(x, y, ch) out[y] = out[y]:sub(1, x - 1) .. ch .. out[y]:sub(x + 1) end
	put(ax, ay, cb)
	put(bx, by, ca)
	return out
end

local function lcg(seed)
	local x = seed
	return function(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return math.floor(x / 65536) % n + 1
	end
end

describe("core exchange: the test boards themselves", function()
	it("BASE and FOUR have no match; the exchange of FOUR and THREE makes one, that of BASE does not", function()
		assert_false(has_match(BASE))
		assert_false(has_match(FOUR))
		assert_false(has_match(FIVE))
		assert_false(has_match(THREE))
		assert_true(has_match(exchanged(FOUR, 3, 1, 6, 6)))
		assert_true(has_match(exchanged(THREE, 3, 1, 6, 6)))
		assert_false(has_match(exchanged(BASE, 1, 1, 4, 4)))
	end)
end)

describe("core exchange: acceptance (5.3 swap, 5.0)", function()
	it("takes two free pieces anywhere on the board, spends no move and makes the action of the booster", function()
		local g = fresh()
		local a, b = H.obj_at(g, 1, 1), H.obj_at(g, 4, 4)
		assert_same(exchange(g, 1, 1, 4, 4), { true, "ok" })
		local s = g.s
		assert_eq(s.act, 1, "an action for the labels")
		assert_same({ s.moves_left, s.moves_made, #s.eom, #s.queue, s.next_source_id }, { 20, 0, 0, 0, 1 },
			"no move, no end-of-move entry, no record, no source")
		assert_false(s.rest_flag)
		assert_same(s.cmds, { { tick = 1, cmd = cmd(1, 1, 4, 4) } }, "an accepted command is recorded")
		for _, o in ipairs({ a, b }) do
			assert_same({ o.state, o.tk, o.td }, { C.S_SWAP, C.TM_XCHG, 1 + 18 }, "on swap for T.exchange = 18 ticks")
		end
		assert_eq(#s.swaps, 1)
		local sw = s.swaps[1]
		assert_same({ sw.kind, sw.a, sw.from, sw.to, sw.m1, sw.w1, sw.m2, sw.w2, sw.due },
			{ C.TM_XCHG, 1, cell(g, 1, 1), cell(g, 4, 4), 0, 0, 0, 0, 19 })
		assert_same(g:drain_events(), {
			{ t = 1, type = "booster", booster = "swap", at = { 1, 1 }, to = { 4, 4 }, ok = true },
			{ t = 1, type = "exchange", a = { 1, 1 }, b = { 4, 4 }, ids = { a.id, b.id }, duration = 18 },
		})
	end)

	it("takes neighbours as well, in either order, and cells given as {x =, y =}", function()
		assert_same(exchange(fresh(), 2, 3, 3, 3), { true, "ok" })
		local h = fresh()
		assert_same(exchange(h, 6, 6, 1, 1), { true, "ok" })
		assert_same(h:drain_events()[2].a, { 6, 6 })
		local g = fresh()
		assert_same({ g:input({ type = "booster", booster = "swap", at = { x = 1, y = 1 }, to = { x = 3, y = 3 } }) }, { true, "ok" })
	end)

	it("refuses with the reasons of 5.0, each one only when the ones before it do not apply", function()
		local g = fresh()
		-- 1. bad_cmd beats everything: a missing, fractional or misshapen cell
		g.s.state, g.s.rest_flag = C.G_WON_WAIT, false
		for _, c in ipairs({
			{ type = "booster", booster = "swap" },
			{ type = "booster", booster = "swap", at = { 1, 1 } },
			{ type = "booster", booster = "swap", to = { 1, 1 } },
			{ type = "booster", booster = "swap", at = { 1.5, 1 }, to = { 2, 2 } },
			{ type = "booster", booster = "swap", at = { 1, 1 }, to = "2,2" },
			{ type = "booster", booster = "swap", row = 2 },
		}) do
			assert_same({ g:input(c) }, { false, "bad_cmd" })
		end
		-- 2. bad_state
		for _, st in ipairs({ C.G_WON_WAIT, C.G_CONCERT, C.G_LOST, C.G_COMPLETE }) do
			g.s.state = st
			assert_same(exchange(g, 99, 99, 1, 1), { false, "bad_state" }, "state " .. st)
		end
		-- 4. not_rest (3, no_moves, is for swaps and taps only)
		g.s.state = C.G_PLAYING
		g.s.moves_left = 0
		assert_same(exchange(g, 99, 99, 1, 1), { false, "not_rest" })
		-- 5. bad_cell: outside the field, a void, one cell twice; before not_movable
		g.s.rest_flag = true
		assert_same(exchange(g, 99, 99, 1, 1), { false, "bad_cell" })
		assert_same(exchange(g, 1, 1, 0, 3), { false, "bad_cell" })
		assert_same(exchange(g, 1, 1, 1, 7), { false, "bad_cell" })
		assert_same(exchange(g, 3, 3, 3, 3), { false, "bad_cell" }, "one cell twice")
		local gap = fresh({ "brygbr", "yg.ryg", "brygbr", "ygbryg", "brygbr", "ygbryg" }, nil, nil,
			{ "######", "##.###", "######", "######", "######", "######" })
		assert_same(exchange(gap, 3, 2, 1, 1), { false, "bad_cell" }, "a void")
		assert_same(exchange(gap, 1, 1, 3, 2), { false, "bad_cell" }, "a void as the second cell")
		local blocked = fresh({ "XKygbr", "ygbryg", "brygbr", "ygbryg", "brygbr", "ygbryg" })
		assert_same(exchange(blocked, 1, 1, 9, 9), { false, "bad_cell" }, "bad_cell before not_movable")
		-- 6. not_movable before 8. same_piece: two blockers are not 'alike', they are fixed
		assert_same(exchange(blocked, 1, 1, 2, 1), { false, "not_movable" })
		-- 8. same_piece; the exchange needs the moves of a swap no more (moves_left is 0 here)
		assert_same(exchange(g, 1, 1, 5, 1), { false, "same_piece" }, "(1,1) and (5,1) are both blue")
		assert_same(exchange(g, 1, 1, 3, 1), { true, "ok" }, "and it takes a move-less board: it costs none")
	end)

	it("a refusal changes nothing: no action, no command in the replay, no event, no timer, the flag stays", function()
		local g = fresh()
		local before = g:hash()
		assert_same(exchange(g, 1, 1, 7, 7), { false, "bad_cell" })
		assert_same(exchange(g, 1, 1, 5, 1), { false, "same_piece" })
		assert_same({ g:input({ type = "booster", booster = "swap", at = { 1, 1 } }) }, { false, "bad_cmd" })
		assert_eq(g:hash(), before)
		assert_same(g.s.cmds, {})
		assert_same(g:drain_events(), {})
		assert_true(g.s.rest_flag)
		assert_eq(g.s.act, 0)
		assert_same(g.s.swaps, {})
	end)

	it("moves what a swap may move: pieces, every special and microphones", function()
		local g = fresh({ "rRSBDM", "ygbryg", "brygbr", "ygbryg", "brygbr", "ygbryg" })
		for x = 2, 6 do
			assert_same({ g:clone():input(cmd(1, 1, x, 1)) }, { true, "ok" }, "the piece and x = " .. x)
			assert_same({ g:clone():input(cmd(x, 1, 3, 4)) }, { true, "ok" }, "x = " .. x .. " and a plain piece")
		end
		assert_same({ g:clone():input(cmd(2, 1, 6, 1)) }, { true, "ok" }, "a Riff and a microphone")
		assert_same({ g:clone():input(cmd(3, 1, 5, 1)) }, { true, "ok" }, "a Sabwoofer and a Disco ball")
	end)

	it("refuses what a swap may not move: every blocker, a wired piece, an empty slot, a piece on the move", function()
		local g = fresh({ "rXKNAg", "yLlbrg", "bllrbg", "g_rygb", "brygbr", "ygbryg" })
		g.s.wires[cell(g, 6, 6)] = 1
		-- the blockers (2,1) (3,1) (4,1) (5,1), the column over (2,2) (3,2) (2,3) (3,3), the empty slot (2,4), the wired (6,6)
		for _, c in ipairs({ { 2, 1 }, { 3, 1 }, { 4, 1 }, { 5, 1 }, { 2, 2 }, { 3, 2 }, { 2, 3 }, { 3, 3 }, { 2, 4 }, { 6, 6 } }) do
			assert_same(exchange(g, 1, 1, c[1], c[2]), { false, "not_movable" }, "second cell " .. c[1] .. "," .. c[2])
			assert_same(exchange(g, c[1], c[2], 1, 1), { false, "not_movable" }, "first cell " .. c[1] .. "," .. c[2])
		end
		local o = H.obj_at(g, 4, 4) -- a yellow one
		o.state = C.S_FALL
		assert_same(exchange(g, 1, 1, 4, 4), { false, "not_movable" }, "falling")
		o.state = C.S_ARMED
		assert_same(exchange(g, 1, 1, 4, 4), { false, "not_movable" }, "armed")
		o.state = C.S_SWAP
		assert_same(exchange(g, 1, 1, 4, 4), { false, "not_movable" }, "on a swap")
		o.state = C.S_CLEAR
		assert_same(exchange(g, 1, 1, 4, 4), { false, "not_movable" }, "clearing")
		o.state = C.S_IDLE
		o.pins = { 5 }
		assert_same(exchange(g, 1, 1, 4, 4), { false, "not_movable" }, "pinned")
		o.pins = {}
		assert_same(exchange(g, 1, 1, 4, 4), { true, "ok" }, "free again")
	end)

	it("refuses two pieces that look alike with same_piece, and moves two that differ in the least", function()
		local g = fresh({ "rrRRVS", "SMMyrr", "brygbr", "ygbryg", "brygbr", "ygbryg" })
		local function ans(ax, ay, bx, by) return { g:clone():input(cmd(ax, ay, bx, by)) } end
		assert_same(ans(1, 1, 2, 1), { false, "same_piece" }, "two red pieces")
		assert_same(ans(3, 1, 4, 1), { false, "same_piece" }, "two Riffs on one axis")
		assert_same(ans(4, 1, 5, 1), { true, "ok" }, "a Riff h and a Riff v differ")
		assert_same(ans(2, 2, 3, 2), { false, "same_piece" }, "two microphones")
		assert_same(ans(1, 2, 2, 2), { true, "ok" }, "a Sabwoofer and a microphone")
		assert_same(ans(1, 1, 3, 1), { true, "ok" }, "a piece and a Riff")
		assert_same(ans(1, 1, 4, 2), { true, "ok" }, "red and yellow")
		assert_same(ans(6, 1, 1, 2), { false, "same_piece" }, "two Sabwoofers")
		local h = fresh({ "BBDDbr", "ygbryg", "brygbr", "ygbryg", "brygbr", "ygbryg" })
		assert_same({ h:clone():input(cmd(1, 1, 2, 1)) }, { false, "same_piece" }, "two Birds")
		assert_same({ h:clone():input(cmd(3, 1, 4, 1)) }, { false, "same_piece" }, "two Disco balls")
		assert_same({ h:clone():input(cmd(2, 1, 3, 1)) }, { true, "ok" }, "a Bird and a Disco ball")
	end)

	it("takes one exchange per window: not_rest until the board settles, then the next one", function()
		local g = fresh()
		assert_same(exchange(g, 1, 1, 4, 4), { true, "ok" })
		assert_same(exchange(g, 2, 2, 5, 5), { false, "not_rest" })
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 1, 1 } }) }, { false, "not_rest" })
		g:run_to_rest()
		assert_true(g.s.rest_flag)
		assert_same(exchange(g, 2, 2, 5, 5), { true, "ok" })
		assert_eq(g.s.act, 2)
	end)

	it("another accepted command of the window shuts the exchange out", function()
		local g = fresh()
		assert_same({ g:input({ type = "booster", booster = "stick", at = { 1, 1 } }) }, { true, "ok" })
		assert_same(exchange(g, 2, 2, 5, 5), { false, "not_rest" })
	end)

	it("is allowed out of moves and returns the game to playing, like the other boosters", function()
		local g = fresh()
		g.s.moves_left, g.s.state = 0, C.G_OUT
		assert_same(exchange(g, 1, 1, 4, 4), { true, "ok" })
		assert_same(types(g:drain_events()), { "state", "booster", "exchange" })
		assert_eq(g:status().state, "playing")
		g:run_to_rest()
		assert_eq(g:status().state, "out_of_moves", "no goal met: the moves are still out")
	end)

	it("a stuck board takes it too and lifts the flag", function()
		local g = fresh()
		g.s.state, g.s.stuck = C.G_OUT, true
		assert_same(exchange(g, 1, 1, 4, 4), { true, "ok" })
		assert_false(g:status().stuck)
	end)
end)

describe("core exchange: the exchange itself (5.1.3 exchange, 6.2.1)", function()
	it("waits T.exchange ticks, then the pieces trade cells with the label (a, 0); an exchange with no match stays", function()
		local g = fresh()
		local a, b = H.obj_at(g, 1, 1), H.obj_at(g, 4, 4)
		exchange(g, 1, 1, 4, 4)
		g:drain_events()
		for tick = 1, 18 do
			g:step()
			assert_eq(H.obj_at(g, 1, 1), a, "still in its cell at tick " .. tick)
			assert_eq(a.state, C.S_SWAP)
		end
		assert_same(g:drain_events(), {}, "nothing is announced while they fly")
		g:step() -- tick 19: the timer ends in step 2
		assert_eq(H.obj_at(g, 1, 1), b)
		assert_eq(H.obj_at(g, 4, 4), a)
		for _, o in ipairs({ a, b }) do
			assert_same({ o.state, o.tk, o.td, o.mv, o.wv, o.settle }, { C.S_IDLE, 0, 0, 1, 0, 19 })
		end
		assert_same(g:drain_events(), {}, "no match and no refund: not a single event")
		assert_same(g.s.swaps, {})
		assert_same({ g.s.moves_left, g.s.moves_made, g.s.act }, { 20, 0, 1 })
		assert_true(g.s.rest_flag, "at rest again in the same tick")
		assert_eq(g:status().state, "playing")
		assert_same(H.picture(g), exchanged(BASE, 1, 1, 4, 4))
		-- the pieces carry the label (1, 0) now; the record of a second exchange of them still keeps no marks
		-- to give back (17.2: zeros for an exchange, where a swap remembers the marks it may restore)
		exchange(g, 1, 1, 4, 4)
		local sw = g.s.swaps[1]
		assert_same({ sw.kind, sw.a, sw.m1, sw.w1, sw.m2, sw.w2 }, { C.TM_XCHG, 2, 0, 0, 0, 0 })
	end)

	it("resolves the match the exchange makes: wave 1, the new special in the cell of the exchange, never given back", function()
		local g = fresh(FOUR)
		-- a member of the group that settled later than the exchange: rule 3 of 6.2 would take it, rule 6.2.1 does not
		H.obj_at(g, 1, 1).settle = 999
		local yellow, green = H.obj_at(g, 3, 1), H.obj_at(g, 6, 6)
		exchange(g, 3, 1, 6, 6)
		g:drain_events()
		assert_same(types(H.steps(g, 18)), {}, "quiet until the end of the timer")
		local ev = H.steps(g, 1)
		assert_same(H.of_type(ev, "match"), { { t = 19, type = "match", cells = { { 1, 1 }, { 2, 1 }, { 3, 1 }, { 4, 1 } },
			color = "green", wave = 1, act = 1, special = "riff" } })
		local sp = H.of_type(ev, "special_new")[1]
		assert_same({ sp.x, sp.y, sp.special, sp.axis }, { 3, 1, "riff", "h" }, "in the cell of the exchange")
		local o = H.obj_at(g, 3, 1)
		assert_same({ o.kind, o.special, o.axis, o.mv, o.wv }, { C.K_SPECIAL, C.SP_RIFF, C.AX_H, 1, 1 })
		assert_eq(g.s.objs[green.id], nil, "the green that came into the cell left at once, for the special")
		assert_eq(H.obj_at(g, 6, 6), yellow, "and the yellow is in the corner")
		assert_eq(#H.of_type(ev, "clear"), 4, "all four greens, the one of the special's cell too (7.4)")
		assert_same(H.of_type(ev, "swap_back"), {})
		assert_eq(g.s.moves_left, 20)
	end)

	it("also when the group holds the second cell of the command", function()
		local g = fresh(FOUR)
		H.obj_at(g, 1, 1).settle = 999
		exchange(g, 6, 6, 3, 1)
		local ev = H.steps(g, 19)
		local sp = H.of_type(ev, "special_new")[1]
		assert_same({ sp.x, sp.y }, { 3, 1 })
	end)

	it("a match of three scores 20 per piece and counts for the goal; the second cell is the lone piece", function()
		local g = fresh(THREE, { goals = { { type = "collect", color = "green", count = 5 } } })
		exchange(g, 3, 1, 6, 6)
		g:drain_events()
		local ev = H.steps(g, 19)
		assert_same(H.of_type(ev, "match")[1].cells, { { 1, 1 }, { 2, 1 }, { 3, 1 } })
		assert_eq(H.of_type(ev, "match")[1].special, nil, "three make no special")
		assert_eq(g.s.score, 60)
		assert_same(g:status().goals, { 2 })
		assert_eq(H.obj_at(g, 6, 6).color, C.COLOR.yellow, "the yellow that left the row is in the corner now")
	end)

	it("never launches a special: a Riff, a Disco ball or two specials only change cells, no combo", function()
		local rows = { "brygbr", "ygbrDg", "brRgbr", "ygbryg", "bSygbr", "ygBryg" }
		for _, spec in ipairs({
			{ 3, 3, 1, 4, "a Riff and a piece" },
			{ 5, 2, 6, 5, "a Disco ball and a piece" },
			{ 3, 3, 2, 5, "a Riff and a Sabwoofer" },
			{ 5, 2, 3, 6, "a Disco ball and a Bird" },
			{ 2, 5, 3, 6, "a Sabwoofer and a Bird" },
		}) do
			local g = fresh(rows)
			local ax, ay, bx, by = spec[1], spec[2], spec[3], spec[4]
			assert_false(has_match(exchanged(rows, ax, ay, bx, by)), spec[5] .. ": a quiet exchange")
			local a, b = H.obj_at(g, ax, ay), H.obj_at(g, bx, by)
			assert_same(exchange(g, ax, ay, bx, by), { true, "ok" }, spec[5])
			g:drain_events()
			local ev = H.steps(g, 19)
			assert_eq(H.obj_at(g, bx, by), a, spec[5])
			assert_eq(H.obj_at(g, ax, ay), b, spec[5])
			assert_same({ a.state, b.state }, { C.S_IDLE, C.S_IDLE }, spec[5] .. ": nothing is armed")
			for _, ty in ipairs({ "activate", "bolt", "ring", "bird_fly", "disco_ray", "transform" }) do
				assert_same(H.of_type(ev, ty), {}, spec[5] .. ": no " .. ty)
			end
			assert_same(g.s.queue, {}, spec[5])
			assert_eq(g.s.moves_left, 20)
		end
	end)

	it("a special that is exchanged next to a match stays untouched: adjacent hits do nothing to it", function()
		-- the Riff goes to (4,1) next to the line (1,1)-(3,1) that the exchange makes
		local g = fresh({ "ggyRbr", "ygbryg", "brygbr", "ygbryg", "brygbr", "ygbryg" })
		local riff = H.obj_at(g, 4, 1)
		exchange(g, 3, 1, 6, 6)
		H.steps(g, 19)
		assert_eq(riff.state, C.S_IDLE)
		assert_eq(H.obj_at(g, 4, 1), riff)
	end)

	it("a microphone taken to a stand is delivered in the same tick", function()
		local pic = { "######", "##M###", "######", "######", "######", "######" }
		local extra = { goals = { { type = "deliver", count = 1 } }, mic = { total = 1, on_board_max = 1, gap_moves = 0 } }
		local g = fresh({ "brygbr", "ygMryg", "brygbr", "ygbryg", "brygbr", "ygbryg" }, extra, nil, pic)
		assert_same(exchange(g, 3, 2, 3, 6), { true, "ok" })
		g:drain_events()
		local ev = H.steps(g, 19)
		local d = H.of_type(ev, "mic_delivered")[1]
		assert_same({ d.x, d.y }, { 3, 6 })
		assert_same(g:status().goals, { 0 })
		assert_eq(g:status().state, "won_wait")
	end)

	it("gives no move and grows no noise, where the same change by a swap spends a move and grows the noise", function()
		local rows = { "ggygNr", "ygbryg", "brygbr", "ygbryg", "brygbr", "ygbryg" }
		local function noise(g)
			local n = 0
			for _, p in ipairs(g:pieces()) do
				if p.item == "noise" then n = n + 1 end
			end
			return n
		end
		local a = fresh(rows)
		assert_same({ a:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) }, { true, "ok" })
		a:run_to_rest()
		assert_eq(a.s.moves_left, 19)
		assert_eq(noise(a), 2, "a move that missed the noise: it grows")
		local b = fresh(rows)
		assert_same(exchange(b, 3, 1, 4, 1), { true, "ok" })
		b:run_to_rest()
		assert_eq(b.s.moves_left, 20)
		assert_eq(noise(b), 1, "the exchange is no move: the noise does not grow")
		assert_same(types(H.of_type(b:drain_events(), "noise_spread")), {})
	end)

	it("the exchange that meets the last goal wins, out of moves as well", function()
		local g = fresh(THREE, { goals = { { type = "collect", color = "green", count = 3 } } })
		g.s.moves_left, g.s.state = 0, C.G_OUT
		exchange(g, 3, 1, 6, 6)
		H.steps(g, 19)
		assert_eq(g:status().state, "won_wait")
		for _ = 1, 200 do
			if g:status().state == "concert" then break end
			g:step()
		end
		assert_eq(g:status().state, "concert", "the concert starts at the first rest")
	end)

	it("never ends in `unplaced`", function()
		local g = fresh(THREE, { goals = { { type = "collect", color = "green", count = 3 } } })
		exchange(g, 3, 1, 6, 6)
		g:run_to_rest()
		for _ = 1, 400 do
			if g:status().state == "complete" then break end
			g:step()
		end
		assert_same(g.s.unplaced, {})
	end)
end)

describe("core exchange: while it flies (5.1.2, 15.1.8)", function()
	it("a swap of an exchanged piece is refused, a swap elsewhere is taken, a second booster waits", function()
		local g = fresh(BASE)
		exchange(g, 1, 1, 4, 4)
		g:step()
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }) }, { false, "not_movable" })
		assert_same({ g:input({ type = "tap", at = { 1, 1 } }) }, { false, "not_movable" })
		assert_eq(g:can_swap({ 4, 4 }, { 4, 5 }), "reject")
	end)

	it("answers like a brute-force oracle on the board as it will be, for every neighbour pair", function()
		-- the exchange (3,1) <-> (6,6) will put a green into row 1 and a yellow into the corner; until then the
		-- board still shows the old pieces, and a swap is judged on the board as it will be
		local g = fresh(FIVE)
		exchange(g, 3, 1, 6, 6)
		g:step()
		local expected = exchanged(FIVE, 3, 1, 6, 6)
		local function oracle(rows, x, y, x2, y2)
			if rows[y]:sub(x, x) == rows[y2]:sub(x2, x2) then return "fail" end
			local after = exchanged(rows, x, y, x2, y2)
			return (match_through(after, x, y) or match_through(after, x2, y2)) and "ok" or "fail"
		end
		local seen_ok, differs = 0, 0
		for y = 1, 6 do
			for x = 1, 6 do
				for _, d in ipairs({ { 1, 0 }, { 0, 1 } }) do
					local x2, y2 = x + d[1], y + d[2]
					if x2 <= 6 and y2 <= 6 then
						local busy = (x == 3 and y == 1) or (x == 6 and y == 6) or (x2 == 3 and y2 == 1) or (x2 == 6 and y2 == 6)
						local label = x .. "," .. y .. " -> " .. x2 .. "," .. y2
						if busy then
							assert_eq(g:can_swap({ x, y }, { x2, y2 }), "reject", label .. ": a piece of the exchange")
						else
							local want = oracle(expected, x, y, x2, y2)
							assert_eq(g:can_swap({ x, y }, { x2, y2 }), want, label)
							if want == "ok" then seen_ok = seen_ok + 1 end
							if want ~= oracle(FIVE, x, y, x2, y2) then differs = differs + 1 end
						end
					end
				end
			end
		end
		assert_true(seen_ok > 0, "some pair is a move on the board as it will be")
		assert_true(differs > 0, "and some answer differs from the one on the board as it is now: " .. differs)
	end)

	it("the moves() list sees it too", function()
		local g = fresh(FIVE)
		exchange(g, 3, 1, 6, 6)
		g:step()
		local found = false
		for _, m in ipairs(g:moves()) do
			if m.from[1] == 5 and m.from[2] == 1 and m.to[1] == 5 and m.to[2] == 2 then found = true end
		end
		assert_true(found, "the swap (5,1) <-> (5,2) is a move on the board as it will be")
	end)

	it("the skip of the concert and set_timing('turbo') shorten the timer to one tick (15.1.8)", function()
		local g = fresh()
		exchange(g, 1, 1, 4, 4)
		for _ = 1, 3 do g:step() end
		g:set_timing("turbo")
		local a = H.obj_at(g, 1, 1)
		assert_eq(a.td, 5, "between ticks 3 and 4: now = 4, turbo one tick: due 5")
		assert_eq(g.s.swaps[1].due, 5)
		g:step() -- tick 4
		assert_eq(a.state, C.S_SWAP)
		g:step() -- tick 5
		assert_eq(a.state, C.S_IDLE)
	end)

	it("in turbo from the start the exchange lasts one tick", function()
		local g = fresh(BASE, nil, { timing = "turbo" })
		exchange(g, 1, 1, 4, 4)
		assert_eq(g:drain_events()[2].duration, 1)
		g:step()
		g:step()
		assert_eq(H.obj_at(g, 4, 4).color, C.COLOR.blue)
	end)
end)

describe("core exchange: replay, hash, clone, determinism", function()
	it("a game with exchanges plays back from its replay to the same hash, with the command as given", function()
		local lvl = H.load(FULL)
		local g = core.new(lvl, { seed = 5 })
		g:run_to_rest()
		g:input(cmd(1, 1, 6, 6))
		g:run_to_rest()
		g:input({ type = "swap", from = { 3, 3 }, to = { 4, 3 } }) -- may be refused: only accepted ones are recorded
		for _ = 1, 30 do g:step() end
		g:run_to_rest()
		g:input(cmd(2, 5, 5, 2))
		g:run_to_rest()
		local rep = g:replay()
		local n = 0
		for _, c in ipairs(rep.commands) do
			if c.cmd.booster == "swap" then n = n + 1 end
		end
		assert_true(n >= 1, "the replay holds the exchanges")
		assert_same(rep.commands[1].cmd, cmd(1, 1, 6, 6))
		local back, ok, why = core.playback(lvl, rep)
		assert_true(ok, why)
		assert_eq(back:hash(), g:hash())
	end)

	it("the hash tells an exchange in flight from none, and from a swap in flight", function()
		local a, b, c = fresh(), fresh(), fresh()
		exchange(b, 1, 1, 4, 4)
		c:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } })
		assert_true(a:hash() ~= b:hash())
		assert_true(b:hash() ~= c:hash())
		local d = fresh()
		exchange(d, 1, 1, 4, 4)
		assert_eq(b:hash(), d:hash(), "the same command, the same state")
		local e = fresh()
		exchange(e, 4, 4, 1, 1)
		assert_true(b:hash() ~= e:hash(), "the order of the cells is part of the state")
	end)

	it("a clone made in flight goes on exactly like the game", function()
		local g = fresh(FOUR)
		exchange(g, 3, 1, 6, 6)
		for _ = 1, 7 do g:step() end
		local c = g:clone()
		for tick = 1, 60 do
			g:step()
			c:step()
			assert_eq(c:hash(), g:hash(), "tick " .. tick)
		end
	end)

	it("never draws a random number itself", function()
		local g = fresh(BASE)
		local before = {}
		for k = 1, 4 do before[k] = table.concat(g.s.rng[k], ",") end
		exchange(g, 1, 1, 4, 4)
		for _ = 1, 25 do g:step() end
		for k = 1, 4 do assert_eq(table.concat(g.s.rng[k], ","), before[k], "stream " .. k) end
	end)
end)

-- Random play: exchanges at any time on levels with every kind of content, with the oracles of match
-- search, hits and effects watching, the invariants checked each tick, and an oracle of the acceptance
-- rules answering every command first.

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
}

-- The acceptance rules of 5.0 / 5.3 as the specification words them, from the public queries and the flags.
local function oracle_answer(g, c)
	local s = g.s
	local function xy(v)
		if type(v) ~= "table" then return nil end
		local x, y = v[1], v[2]
		if type(x) ~= "number" or type(y) ~= "number" or x ~= math.floor(x) or y ~= math.floor(y) then return nil end
		return x, y
	end
	local ax, ay = xy(c.at)
	local bx, by = xy(c.to)
	if not ax or not bx then return false, "bad_cmd" end
	local st = g:status().state
	if st ~= "playing" and st ~= "out_of_moves" then return false, "bad_state" end
	if not s.rest_flag then return false, "not_rest" end
	local cells, pieces = g:cells(), g:pieces()
	local function exists(x, y) return x >= 1 and x <= s.W and y >= 1 and y <= s.H and cells[(y - 1) * s.W + x].exists end
	if not exists(ax, ay) or not exists(bx, by) or (ax == bx and ay == by) then return false, "bad_cell" end
	local function piece_at(x, y)
		for _, p in ipairs(pieces) do
			if p.x == x and p.y == y then return p end
			if p.item == "column" and x >= p.x and x <= p.x + 1 and y >= p.y and y <= p.y + 1 then return p end
		end
		return nil
	end
	local function free(p, x, y)
		return p ~= nil and p.kind ~= "blocker" and p.state == "idle" and not p.pinned and (cells[(y - 1) * s.W + x].wires or 0) == 0
	end
	local pa, pb = piece_at(ax, ay), piece_at(bx, by)
	if not free(pa, ax, ay) or not free(pb, bx, by) then return false, "not_movable" end
	if pa.kind == pb.kind and pa.color == pb.color and pa.special == pb.special and pa.axis == pb.axis then
		return false, "same_piece"
	end
	return true, "ok"
end

local function tiny_invariants(g, where)
	local s = g.s
	for _, sw in ipairs(s.swaps) do
		local a, b = s.objs[s.slot[sw.from]], s.objs[s.slot[sw.to]]
		if a.tk ~= sw.kind or b.tk ~= sw.kind or a.td ~= sw.due or a.state ~= C.S_SWAP or b.state ~= C.S_SWAP then
			error(where .. ": swap timer mismatch", 0)
		end
	end
	if s.tick > 0 and require("core.match").any_match(require("core.match").color_map(s), s.W, s.H) then
		error(where .. ": a match is left on the board", 0)
	end
	assert_true(s.moves_left >= 0, where)
	for _, o in pairs(s.objs) do -- order-independent
		if o.state == C.S_IDLE and (o.tk ~= 0) then error(where .. ": idle object with a timer", 0) end
	end
end

describe("core exchange: random play with the oracles watching", function()
	for li, spec in ipairs(LEVELS) do
		for _, timing in ipairs({ "normal", "turbo" }) do
			it("level " .. li .. " (" .. timing .. ")", function()
				local lvl = H.load(spec.rows, spec.extra)
				local rnd = lcg(li * 17 + #timing)
				local accepted, refused, reasons = 0, 0, {}
				O.install()
				local ok, err = pcall(function()
					for game_no = 1, 2 do
						local g = core.new(lvl, { seed = li * 100 + game_no, timing = timing, help = game_no - 1 })
						local ticks = 0
						while g.s.state ~= C.G_COMPLETE and g.s.state ~= C.G_LOST and ticks < 2500 do
							if g.s.state == C.G_OUT then
								if rnd(3) == 1 and not g.s.stuck then
									g:input({ type = "continue", moves = 3, riff = rnd(2) == 1 })
								else
									g:input({ type = "give_up" })
								end
							else
								local rest = g.s.rest_flag
								local r = rnd(10)
								if (rest and r <= 5) or (not rest and r == 1) then
									local W, Hh = g.s.W, g.s.H
									local c = cmd(rnd(W), rnd(Hh), rnd(W), rnd(Hh))
									local want_ok, want_why = oracle_answer(g, c)
									local before_act, before_moves = g.s.act, g.s.moves_left
									local got_ok, got_why = g:input(c)
									assert_eq(got_ok, want_ok, "the oracle says " .. tostring(want_why) .. " at tick " .. g.s.tick)
									assert_eq(got_why, want_why, "tick " .. g.s.tick)
									if got_ok then
										accepted = accepted + 1
										assert_eq(g.s.act, before_act + 1)
										assert_eq(g.s.moves_left, before_moves, "no move")
									else
										refused = refused + 1
										reasons[got_why] = (reasons[got_why] or 0) + 1
										assert_eq(g.s.act, before_act)
									end
								elseif rest and r <= 8 then
									local mv = g:moves()
									if #mv > 0 then
										local m = mv[rnd(#mv)]
										g:input({ type = "swap", from = m.from, to = m.to })
									end
								elseif rest and r == 9 then
									g:input({ type = "tap", at = { rnd(g.s.W), rnd(g.s.H) } })
								elseif rest and r == 10 then
									g:input({ type = "booster", booster = "stick", at = { rnd(g.s.W), rnd(g.s.H) } })
								elseif not rest and r == 2 then
									-- a swap while something moves (non-blocking input) now and then
									local mv = g:moves()
									if #mv > 0 and rnd(6) == 1 then
										local m = mv[rnd(#mv)]
										g:input({ type = "swap", from = m.from, to = m.to })
									end
								end
							end
							g:step()
							ticks = ticks + 1
							g:drain_events()
							tiny_invariants(g, "level " .. li .. " game " .. game_no .. " tick " .. g.s.tick)
						end
						local _, pb_ok, why = core.playback(lvl, g:replay())
						assert_true(pb_ok, why)
					end
				end)
				O.uninstall()
				if not ok then error(err, 0) end
				if #O.errors > 0 then error(#O.errors .. " oracle errors, the first ones:\n  " .. table.concat(O.errors, "\n  "), 0) end
				assert_true(accepted >= 15, "exchanges taken: " .. accepted)
				assert_true(refused >= 15, "exchanges refused: " .. refused)
				assert_true((reasons.same_piece or 0) + (reasons.not_movable or 0) + (reasons.not_rest or 0) > 0,
					"refusals of every sort are met")
			end)
		end
	end
end)

describe("core exchange: the golden replay", function()
	it("holds exchanges that were taken and refused, and plays back to its stored hash", function()
		local gold = require("tests.golden.exchange")
		local n = 0
		for _, c in ipairs(gold.replay.commands) do
			if c.cmd.type == "booster" and c.cmd.booster == "swap" then n = n + 1 end
		end
		assert_true(n >= 5, "exchanges in the stored game: " .. n)
		local lvl = assert(core.load_level(gold.level))
		local _, ok, why = core.playback(lvl, gold.replay)
		assert_true(ok, why)
	end)
end)
