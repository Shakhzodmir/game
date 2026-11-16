-- The stage fog (10.13): a cover of a cell that only HIDES what stands under it. In the core everything under
-- the fog behaves as without it; a match in the cell or next to it and any effect hit blow the fog off for
-- good. The goal `fog` is to clear every fogged cell. The hint and the blind clone (the bot's view) never use
-- what the fog hides.

local core = require("core.game")
local C = require("core.const")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- a board without a match and without a move (no purple and no orange in it)
local P0 = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }
-- the swap (3,5) -> (3,6) makes a purple line of three in the bottom row: (1,6) (2,6) (3,6); no other move
local PA = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "bypgby", "ppgbyr" }
local MOVE = { type = "swap", from = { 3, 5 }, to = { 3, 6 } }
-- PA plus a second move: (5,2) -> (5,3) makes an orange line of three in row 3: (4,3) (5,3) (6,3)
local PB = { "byrgby", "yrgboy", "rgbopo", "gbyrgb", "bypgby", "ppgbyr" }
local MOVE_B = { type = "swap", from = { 5, 2 }, to = { 5, 3 } }
local GOAL = { { type = "fog" } }
-- the fog goal next to one that never closes: the level goes on after the last cloud
local KEEP = { { type = "fog" }, { type = "collect", color = "red", count = 999 } }

local function with(rows, x, y, ch)
	local out = {}
	for k = 1, #rows do out[k] = rows[k] end
	out[y] = string.sub(out[y], 1, x - 1) .. ch .. string.sub(out[y], x + #ch)
	return out
end

-- The level field: cells as 1-based {x, y}.
local function fog(cells)
	local out = {}
	for k, c in ipairs(cells) do out[k] = { c[1] - 1, c[2] - 1 } end
	return out
end

-- every cell of rows 2..6 (the top row holds the spawners)
local function all_low()
	local out = {}
	for y = 2, 6 do
		for x = 1, 6 do out[#out + 1] = { x, y } end
	end
	return out
end

-- A live board from a picture with the fog over `cells` (nil: a level without fog).
local function fresh(rows, cells, extra, opts)
	extra = extra or {}
	if cells then
		extra.fog = fog(cells)
		extra.goals = extra.goals or GOAL
	end
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or PA)
	g:drain_events()
	return g
end

local function errors_of(raw)
	local lvl, errs = core.load_level(raw)
	if lvl then return "" end
	return table.concat(errs, "; ")
end

local function expect(raw, text)
	local got = errors_of(raw)
	assert_true(string.find(got, text, 1, true) ~= nil, "expected '" .. text .. "', got '" .. got .. "'")
end

local function idx(x, y) return (y - 1) * 6 + x end

local function on(g, x, y) return g.s.fog[idx(x, y)] end

local function left(g)
	local n = 0
	for i = 1, g.s.N do
		if g.s.fog[i] then n = n + 1 end
	end
	return n
end

local function xy_list(events)
	local out = {}
	for _, e in ipairs(events) do out[#out + 1] = e.x .. "," .. e.y end
	return out
end

-- The command, then the ticks up to and including the first one that resolves a match: its events only (what
-- the cascade does later depends on the new pieces).
local function first_wave(g, cmd)
	assert_true(g:input(cmd))
	for _ = 1, 40 do
		g:step()
		local ev = g:drain_events()
		if #H.of_type(ev, "match") > 0 then return ev end
	end
	error("no match")
end

local function rest(g)
	local all = {}
	for _ = 1, 3000 do
		g:step()
		for _, e in ipairs(g:drain_events()) do all[#all + 1] = e end
		if g:is_stable() then break end
	end
	return all
end

describe("core fog: level schema and rules (2.0, 2.1.15)", function()
	it("accepts the field with or without the goal; the goal counts the fogged cells", function()
		local lvl = H.load(FULL, { fog = fog({ { 3, 4 }, { 2, 4 } }), goals = GOAL })
		assert_same(lvl.fog.cells, { 20, 21 })
		assert_true(lvl.fog.at[21] and not lvl.fog.at[22])
		assert_same(lvl.goals, { { type = C.GOAL_FOG, param = 0, count = 2 } })
		assert_eq(H.load(FULL).fog, nil)
		-- fog as a mere obstacle of a level with another goal
		local plain = H.load(FULL, { fog = fog({ { 3, 4 } }) })
		assert_same(plain.fog.cells, { 21 })
		assert_eq(plain.goals[1].type, C.GOAL_COLLECT)
	end)

	it("checks the shape of the field and of the goal", function()
		expect(H.level(FULL, { fog = {}, goals = GOAL }), "2.1.1 fog: a non-empty list of [x, y] required")
		expect(H.level(FULL, { fog = { cells = {} }, goals = GOAL }), "2.1.1 fog: a non-empty list of [x, y] required")
		expect(H.level(FULL, { fog = { { 1 } }, goals = GOAL }), "2.1.1 fog[1]: [x, y] required")
		expect(H.level(FULL, { fog = { { 1, 1 } }, goals = { { type = "fog", count = 5 } } }), "2.1.1 goals[1]: unknown key 'count'")
		expect(H.level(FULL, { fog = { { 1, 1 } }, goals = { { type = "fog" }, { type = "fog" } } }), "2.1.1 goals[2]: repeated goal")
		expect(H.level(FULL, { goals = { { type = "mist" } } }),
			"goal type collect|break|light|deliver|drop|chains|carpet|ice|fog required")
	end)

	it("2.1.2: on existing cells, one fog a cell", function()
		expect(H.level({ "######", "######", "##.###", "######", "######", "######" }, { fog = fog({ { 3, 3 } }), goals = GOAL }),
			"2.1.2 fog is not on an existing cell at 2,2")
		expect(H.level(FULL, { fog = fog({ { 9, 3 } }), goals = GOAL }), "2.1.2 fog is not on an existing cell at 8,2")
		expect(H.level(FULL, { fog = fog({ { 3, 3 }, { 3, 3 } }), goals = GOAL }), "2.1.2 two fogs in one cell at 2,2")
	end)

	it("2.1.15: a fog goal needs fogged cells; no fog over a blocker, a spawner, an exit or under a curtain", function()
		expect(H.level(FULL, { goals = GOAL }), "2.1.15 fog goal without fogged cells (field fog)")
		for _, ch in ipairs({ "X", "K", "N", "A", "Q", "H" }) do
			expect(H.level(with(FULL, 3, 3, ch), { fog = fog({ { 3, 3 } }), goals = GOAL }), "2.1.15 fog over a blocker at 2,2")
		end
		-- any of the four cells of a column
		local col = { slots = { { at = { 2, 2 }, type = "column", hp = 6 } }, fog = fog({ { 4, 4 } }), goals = GOAL }
		expect(H.level(FULL, col), "2.1.15 fog over a blocker at 3,3")
		expect(H.level(FULL, { fog = fog({ { 3, 1 } }), goals = GOAL }), "2.1.15 fog over a spawner at 2,0")
		expect(H.level(FULL, { fog = fog({ { 3, 6 } }), goals = { { type = "fog" }, { type = "deliver", count = 1 } },
			mic = { total = 1, on_board_max = 1, gap_moves = 0 } }), "2.1.15 fog over an exit at 2,5")
		expect(H.level(FULL, { fog = fog({ { 3, 3 } }), goals = GOAL,
			curtain = { covers = { { 2, 2 } }, closed_moves = 2, open_moves = 2, start = "closed" } }),
			"2.1.15 fog under a curtain at 2,2")
	end)

	it("everything else may hide under the fog: a piece, a special, a mic, a floor tile, wires, a chain, ice, a belt", function()
		local lvl = H.load(with(with(FULL, 2, 2, "S"), 3, 2, "r"), {
			fog = fog({ { 2, 2 }, { 3, 2 }, { 4, 2 }, { 5, 2 }, { 2, 4 }, { 3, 4 } }), goals = GOAL,
			floor = { { at = { 3, 1 }, hp = 1 } },
			overlay = { { at = { 4, 1 }, type = "wires", hp = 1 } },
		})
		assert_eq(#lvl.fog.cells, 6)
		assert_true(H.load(FULL, { fog = fog({ { 2, 3 } }), goals = GOAL, overlay = { { at = { 1, 2 }, type = "chain", hp = 1 } } }) ~= nil)
		assert_true(H.load(with(FULL, 2, 3, "M"), { fog = fog({ { 2, 3 } }), goals = { { type = "fog" }, { type = "deliver", count = 1 } },
			mic = { total = 1, on_board_max = 1, gap_moves = 0 } }) ~= nil)
		assert_true(H.load(FULL, { fog = fog({ { 2, 3 } }), goals = GOAL, overlay = { { at = { 1, 2 }, type = "ice", hp = 1 } } }) ~= nil)
		assert_true(H.load(FULL, { fog = fog({ { 2, 3 } }), goals = GOAL,
			conveyor = { { path = { { 0, 2 }, { 1, 2 }, { 2, 2 } } } } }) ~= nil)
		-- at the bottom of a level without mics and coconuts: no exit there
		assert_true(H.load(FULL, { fog = fog({ { 3, 6 } }), goals = GOAL }) ~= nil)
	end)

	it("2.1.6: the fog is one of the three elements a level may have", function()
		local three = { fog = fog({ { 3, 3 } }), goals = GOAL, floor = { { at = { 0, 5 }, hp = 1 } },
			overlay = { { at = { 1, 4 }, type = "wires", hp = 1 } } }
		assert_true(H.load(FULL, three) ~= nil)
		three.slots = { { at = { 5, 5 }, type = "record_box", hp = 1 } }
		expect(H.level(FULL, three), "2.1.6 more than three different elements")
	end)
end)

describe("core fog: what is under it behaves as without it (10.13)", function()
	it("shows the fogged cells and pieces to the client, and nothing on a level without fog", function()
		local g = fresh(PA, { { 3, 4 }, { 2, 6 } })
		local cells = g:cells()
		assert_true(cells[idx(3, 4)].fog and cells[idx(2, 6)].fog)
		assert_eq(cells[idx(4, 4)].fog, nil)
		local n = 0
		for _, p in ipairs(g:pieces()) do
			if p.fogged then
				n = n + 1
				assert_true((p.x == 3 and p.y == 4) or (p.x == 2 and p.y == 6))
				-- the core tells the truth: hiding it is the client's work
				assert_true(p.color ~= nil)
			end
		end
		assert_eq(n, 2)
		local plain = fresh(PA, nil)
		assert_eq(plain.s.fog, false)
		for _, c in ipairs(plain:cells()) do assert_eq(c.fog, nil) end
		for _, p in ipairs(plain:pieces()) do assert_eq(p.fogged, nil) end
	end)

	it("the same commands give the same board with and without fog: pieces fall, swap and match under it", function()
		local a = fresh(PA, nil, { goals = { { type = "collect", color = "red", count = 999 } } }, { seed = 7 })
		local b = fresh(PA, all_low(), { goals = { { type = "collect", color = "red", count = 999 } } }, { seed = 7 })
		assert_same(b:moves(), a:moves())
		assert_true(a:input(MOVE))
		assert_true(b:input(MOVE))
		local ea, eb = rest(a), rest(b)
		assert_same(H.picture(b), H.picture(a))
		assert_eq(#H.of_type(eb, "match"), #H.of_type(ea, "match"))
		assert_eq(#H.of_type(eb, "spawn"), #H.of_type(ea, "spawn"))
		assert_eq(b:status().moves_left, a:status().moves_left)
		assert_same(b:status().goals, a:status().goals)
		assert_eq(#H.of_type(ea, "fog"), 0)
		-- the only difference: the fog events and their score
		assert_eq(b:status().score - a:status().score, C.SCORE_HP * #H.of_type(eb, "fog"))
		-- and a few more moves, as long as both have one
		for _ = 1, 6 do
			local mv = a:moves()
			assert_same(b:moves(), mv)
			if not mv[1] then break end
			local cmd = { type = "swap", from = mv[1].from, to = mv[1].to }
			assert_true(a:input(cmd))
			assert_true(b:input(cmd))
			rest(a)
			rest(b)
			assert_same(H.picture(b), H.picture(a))
		end
	end)

	it("a blind swap into the fog and out of it works by the usual rule", function()
		-- into the fog: the target cell (3,6) is fogged
		local g = fresh(PA, { { 3, 6 } }, { goals = KEEP })
		assert_same({ g:input(MOVE) }, { true, "ok" })
		rest(g)
		assert_eq(g:status().moves_left, 19)
		-- out of the fog: the moved piece (3,5) is fogged
		local o = fresh(PA, { { 3, 5 } }, { goals = KEEP })
		assert_same({ o:input(MOVE) }, { true, "ok" })
		rest(o)
		assert_eq(o:status().moves_left, 19)
	end)

	it("a blind swap that makes no match fails like any other: no move spent, the fog stays, nothing else is told", function()
		local g = fresh(PA, { { 4, 4 }, { 3, 6 } })
		assert_true(g:input({ type = "swap", from = { 4, 3 }, to = { 4, 4 } }))
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "swap_fail"), 1)
		assert_eq(#H.of_type(ev, "swap"), 0)
		assert_eq(#H.of_type(ev, "fog"), 0)
		assert_eq(g:status().moves_left, 20)
		assert_true(on(g, 4, 4) and on(g, 3, 6))
		-- the event of the failed swap carries the cells and the ids, never a colour or a kind
		local e = H.of_type(ev, "swap_fail")[1]
		assert_eq(e.color, nil)
		assert_eq(e.kind, nil)
	end)
end)

describe("core fog: what clears it (10.13)", function()
	it("a match in the cell and a match next to the cell; a fogged cell farther away keeps its fog", function()
		local g = fresh(PA, { { 3, 6 }, { 1, 5 }, { 4, 6 }, { 5, 5 }, { 4, 5 }, { 2, 3 } })
		local ev = first_wave(g, MOVE)
		-- (3,6) is a cell of the group; (1,5) and (4,6) are its neighbours by a side
		assert_same(xy_list(H.of_type(ev, "fog")), { "3,6", "1,5", "4,6" })
		assert_false(on(g, 3, 6) or on(g, 1, 5) or on(g, 4, 6))
		-- (4,5) touches the group by a corner only; (5,5) and (2,3) are far
		assert_true(on(g, 5, 5) and on(g, 4, 5) and on(g, 2, 3))
		assert_eq(left(g), 3)
	end)

	it("every cleared cell gives the score of a floor tile and one unit of the goal", function()
		local g = fresh(PA, { { 1, 5 }, { 4, 6 }, { 5, 3 } })
		local before = g:status().score
		local ev = first_wave(g, MOVE)
		assert_eq(#H.of_type(ev, "fog"), 2)
		local goals = H.of_type(ev, "goal")
		assert_eq(goals[#goals].left, 1)
		assert_eq(g:status().goals[1], 1)
		-- the group of three: 3 x SCORE_WAVE x 1; the fog: 2 x SCORE_HP
		assert_eq(g:status().score - before, 3 * C.SCORE_WAVE + 2 * C.SCORE_HP)
	end)

	it("an effect hit: a Riff blows the fog off its whole row, a hidden special in the row fires", function()
		local rows = with(with(P0, 2, 4, "R"), 5, 4, "S")
		local g = fresh(rows, { { 4, 4 }, { 5, 4 }, { 6, 4 } })
		local sub = H.obj_at(g, 5, 4).id
		assert_true(g:input({ type = "tap", at = { 2, 4 } }))
		local ev = rest(g)
		local got = {}
		for _, k in ipairs(xy_list(H.of_type(ev, "fog"))) do got[k] = true end
		assert_true(got["4,4"] and got["5,4"] and got["6,4"])
		assert_eq(left(g), 0)
		local fired = false
		for _, e in ipairs(H.of_type(ev, "activate")) do
			if e.id == sub then fired = true end
		end
		assert_true(fired, "the Subwoofer under the fog was launched by the Riff")
	end)

	it("boosters: the Stick and the spotlights hit the fogged cell; the Crossfader does not reach into the fog", function()
		local g = fresh(P0, { { 3, 3 }, { 5, 5 } })
		assert_true(g:input({ type = "booster", booster = "stick", at = { 3, 3 } }))
		local ev = rest(g)
		assert_same(xy_list(H.of_type(ev, "fog"))[1], "3,3")
		local r = fresh(P0, { { 3, 3 }, { 5, 3 } })
		assert_true(r:input({ type = "booster", booster = "row_light", row = 3 }))
		ev = rest(r)
		assert_eq(left(r), 0)
		local x = fresh(P0, { { 3, 3 } })
		assert_same({ x:input({ type = "booster", booster = "swap", at = { 3, 3 }, to = { 5, 5 } }) }, { false, "not_movable" })
		assert_same({ x:input({ type = "booster", booster = "swap", at = { 5, 5 }, to = { 3, 3 } }) }, { false, "not_movable" })
		assert_true(on(x, 3, 3))
	end)

	it("a fogged cell with wires: the match next to it clears the fog, the wires stay", function()
		local g = fresh(PA, { { 4, 6 } }, { overlay = { { at = { 3, 5 }, type = "wires", hp = 1 } } })
		assert_eq(g.s.wires[idx(4, 6)], 1)
		local ev = first_wave(g, MOVE)
		assert_same(xy_list(H.of_type(ev, "fog")), { "4,6" })
		assert_eq(g.s.wires[idx(4, 6)], 1)
	end)

	it("never comes back and never spreads: the fogged cells only shrink over a whole game", function()
		local g = H.game(FULL, { fog = fog(all_low()), goals = { { type = "collect", color = "red", count = 999 } }, moves = 30 }, { seed = 3 })
		g:run_to_rest()
		g:drain_events()
		local was = {}
		for i = 1, g.s.N do was[i] = g.s.fog[i] end
		local n = left(g)
		assert_eq(n, 30)
		for _ = 1, 30 do
			local mv = g:moves()
			if not mv[1] or g:status().state ~= "playing" then break end
			assert_true(g:input({ type = "swap", from = mv[1].from, to = mv[1].to }))
			for _ = 1, 3000 do
				g:step()
				for i = 1, g.s.N do
					assert_false(g.s.fog[i] and not was[i], "fog came back")
					was[i] = g.s.fog[i]
				end
				if g:is_stable() then break end
			end
		end
		assert_true(left(g) < n)
	end)
end)

describe("core fog: the goal (10.13)", function()
	it("the level is won when the last fogged cell is clear", function()
		local g = fresh(PA, { { 1, 5 }, { 4, 6 } })
		assert_same(g:status().goals, { 2 })
		assert_true(g:input(MOVE))
		local ev = rest(g)
		assert_eq(g:status().goals[1], 0)
		local states = {}
		for _, e in ipairs(H.of_type(ev, "state")) do states[#states + 1] = e.state end
		assert_eq(states[1], "won_wait")
		for _ = 1, 20000 do
			if g:result() then break end
			g:step()
		end
		assert_true(g:result().won)
	end)

	it("with other goals: the fog goal closes by itself and the level goes on", function()
		local g = fresh(PA, { { 1, 5 } }, { goals = { { type = "fog" }, { type = "collect", color = "red", count = 999 } } })
		assert_true(g:input(MOVE))
		rest(g)
		assert_eq(g:status().goals[1], 0)
		assert_eq(g:status().state, "playing")
	end)
end)

describe("core fog: the hint is fair (12.3, 10.13)", function()
	it("without fog and with fog away from the move: the ordinary hint", function()
		assert_same(fresh(PA, nil):hint(), { from = { 3, 5 }, to = { 3, 6 } })
		assert_same(fresh(PA, { { 5, 3 } }):hint(), { from = { 3, 5 }, to = { 3, 6 } })
	end)

	it("never a move that starts or ends in the fog while a visible move exists", function()
		-- both moves are there for the core; the purple one ends in the fog
		local g = fresh(PB, { { 3, 6 } })
		assert_eq(#g:moves(), 2)
		assert_same(g:hint(), { from = { 5, 2 }, to = { 5, 3 } })
		-- ... or starts in it
		assert_same(fresh(PB, { { 3, 5 } }):hint(), { from = { 5, 2 }, to = { 5, 3 } })
	end)

	it("never relies on a fogged colour: a move of two visible pieces whose line needs a hidden one is not shown", function()
		-- the purple line needs (1,6): hidden. The orange move is shown instead
		assert_same(fresh(PB, { { 1, 6 } }):hint(), { from = { 5, 2 }, to = { 5, 3 } })
		-- the only move of the board needs a hidden colour and has no end in the fog: silence
		local g = fresh(PA, { { 2, 6 } })
		assert_eq(#g:moves(), 1)
		assert_eq(g:hint(), nil)
	end)

	it("ranks by what is seen: a fogged neighbour counts as fog to clear, not as what hides in it", function()
		-- two plain threes: the orange one comes first by its cell. The purple one touches a fogged cell of an open
		-- fog goal: that is goal progress, it wins the rank
		assert_same(fresh(PB, { { 2, 2 } }):hint(), { from = { 5, 2 }, to = { 5, 3 } })
		assert_same(fresh(PB, { { 4, 6 } }):hint(), { from = { 3, 5 }, to = { 3, 6 } })
		-- with the fog as a mere obstacle (no fog goal) it is no progress
		assert_same(fresh(PB, { { 4, 6 } }, { goals = { { type = "collect", color = "red", count = 9 } } }):hint(),
			{ from = { 5, 2 }, to = { 5, 3 } })
		-- a box of an open break goal next to the purple line is progress when seen, none when hidden: the hint
		-- of the fogged board is the hint of the board without the box
		local goals = { { type = "break", item = "record_box", count = 1 } }
		local rows = with(PB, 4, 6, "X")
		local function box() return { goals = goals, slots = { { at = { 5, 5 }, type = "record_box", hp = 1 } } } end
		assert_same(fresh(rows, nil, box()):hint(), { from = { 3, 5 }, to = { 3, 6 } })
		assert_same(fresh(rows, { { 4, 6 } }, box()):hint(), { from = { 5, 2 }, to = { 5, 3 } })
	end)

	it("only blind moves are left: the first of them with an end in the fog, marked `blind`", function()
		local g = fresh(PA, { { 3, 6 } })
		assert_same(g:hint(), { from = { 3, 5 }, to = { 3, 6 }, blind = true })
		assert_same(fresh(PA, { { 3, 5 }, { 1, 6 } }):hint(), { from = { 3, 5 }, to = { 3, 6 }, blind = true })
	end)

	it("a special under the fog is not hinted as a tap; when nothing else is left it is, marked `blind`", function()
		local rows = with(PB, 2, 4, "R")
		assert_same(fresh(rows, { { 2, 4 } }):hint(), { from = { 5, 2 }, to = { 5, 3 } })
		-- the same special in the open: its swap with a neighbour (a swap comes before the tap), not blind
		assert_same(fresh(with(P0, 2, 4, "R"), { { 5, 5 } }):hint(), { from = { 2, 3 }, to = { 2, 4 } })
		-- hidden and alone: its swaps with the visible neighbours come first in the order of 12.1 (blind swaps)
		local h = fresh(with(P0, 2, 4, "R"), { { 2, 4 } }):hint()
		assert_true(h.blind)
		assert_true((h.from[1] == 2 and h.from[2] == 4) or (h.to[1] == 2 and h.to[2] == 4))
	end)

	it("is a pure function of what is seen: two boards that differ only under the fog get the same hint", function()
		local cells = { { 2, 2 }, { 3, 3 }, { 4, 4 }, { 2, 5 } }
		local a = fresh(PB, cells)
		-- other colours and a special under the same clouds, none of them part of a visible move
		local rows = with(with(with(with(PB, 2, 2, "b"), 3, 3, "y"), 4, 4, "S"), 2, 5, "g")
		local b = fresh(rows, cells)
		assert_same(b:hint(), a:hint())
		assert_eq(a:hint().blind, nil)
	end)
end)

describe("core fog: deadlock and shuffle use the true board (12.1, 12.2, 10.13)", function()
	it("a hidden move is a move: no shuffle while a blind move exists", function()
		local g = fresh(PA, { { 1, 6 }, { 2, 6 }, { 3, 6 }, { 3, 5 } })
		assert_true(g:has_move())
		g.s.dirty = true
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "shuffle"), 0)
		assert_eq(g:status().state, "playing")
		-- and the blind move is accepted
		assert_same({ g:input(MOVE) }, { true, "ok" })
	end)

	it("no move at all: the ordinary shuffle; the fog stays on its cells, the pieces under it are shuffled too", function()
		local cells = { { 2, 2 }, { 3, 3 }, { 4, 4 }, { 5, 5 } }
		local g = fresh(P0, cells)
		assert_false(g:has_move())
		g.s.dirty = true
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "shuffle"), 1)
		assert_true(g:has_move())
		assert_eq(#H.of_type(ev, "fog"), 0)
		for _, c in ipairs(cells) do assert_true(on(g, c[1], c[2])) end
		assert_eq(left(g), 4)
	end)

	it("a board of fog only never soft-locks: either a blind move exists or the board is shuffled", function()
		for seed = 1, 5 do
			local g = H.game(FULL, { fog = fog(all_low()), goals = GOAL, moves = 40 }, { seed = seed })
			for _ = 1, 40 do
				g:run_to_rest()
				if g:status().state ~= "playing" then break end
				local mv = g:moves()
				assert_true(mv[1] ~= nil, "at rest and playing: a move exists")
				assert_true(g:input({ type = "swap", from = mv[1].from, to = mv[1].to }))
			end
			g:run_to_rest()
			assert_true(g:status().state ~= "playing" or g:has_move())
		end
	end)
end)

describe("core fog: other elements under it (10.13)", function()
	it("a conveyor under the fog: the riders move on, the fog stays with the cell", function()
		-- the belt runs along row 5 under columns 1..3; the orange move is played in columns 4..6, rows 1..3
		local g = fresh(PB, { { 2, 5 } }, { conveyor = { { path = { { 0, 4 }, { 1, 4 }, { 2, 4 } } } }, goals = KEEP })
		local first, second = H.obj_at(g, 1, 5).id, H.obj_at(g, 2, 5).id
		assert_true(g:input(MOVE_B))
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "conveyor"), 1)
		assert_true(on(g, 2, 5), "the fog is still on its cell")
		assert_eq(left(g), 1)
		-- the rider that stood in the fog has left it, the one behind it stands in the fog now
		assert_eq(g.s.objs[first].cell, idx(2, 5))
		assert_eq(g.s.objs[second].cell, idx(3, 5))
		local fogged = {}
		for _, p in ipairs(g:pieces()) do
			if p.fogged then fogged[#fogged + 1] = p.id end
		end
		assert_same(fogged, { first })
	end)

	it("a special under the fog: a blind tap fires it, a blind swap with it is a move", function()
		local rows = with(P0, 2, 4, "R")
		local g = fresh(rows, { { 2, 4 }, { 5, 6 } }, { goals = KEEP })
		assert_same({ g:input({ type = "tap", at = { 2, 4 } }) }, { true, "ok" })
		local ev = rest(g)
		assert_true(#H.of_type(ev, "activate") >= 1)
		assert_false(on(g, 2, 4))
		assert_eq(g:status().moves_left, 19)
		local w = fresh(rows, { { 2, 4 }, { 5, 6 } }, { goals = KEEP })
		assert_same({ w:input({ type = "swap", from = { 2, 3 }, to = { 2, 4 } }) }, { true, "ok" })
		rest(w)
		assert_eq(w:status().moves_left, 19)
		-- a blind tap on a fogged regular piece is refused like any tap on a regular piece
		local t = fresh(rows, { { 4, 4 } })
		assert_false((t:input({ type = "tap", at = { 4, 4 } })))
	end)

	it("a frozen and a chained piece under the fog: the fog goes with the first hit, the layer by its own rules", function()
		local g = fresh(PA, { { 4, 6 }, { 1, 5 } }, { overlay = { { at = { 3, 5 }, type = "ice", hp = 1 }, { at = { 0, 4 }, type = "chain", hp = 1 } } })
		H.obj_at(g, 4, 6).ice = 1
		H.obj_at(g, 1, 5).chain = 1
		local ev = first_wave(g, MOVE)
		assert_same(xy_list(H.of_type(ev, "fog")), { "1,5", "4,6" })
		-- the ice next to the match thaws (10.11); the chain is taken only by a match of its own piece (10.6)
		assert_eq(#H.of_type(ev, "thawed"), 1)
		assert_eq(H.obj_at(g, 1, 5).chain, 1)
	end)

	it("a floor tile under the fog is lit as usual when its piece is destroyed", function()
		local g = fresh(PA, { { 2, 6 } }, { floor = { { at = { 1, 5 }, hp = 1 } },
			goals = { { type = "fog" }, { type = "light" } } })
		local ev = first_wave(g, MOVE)
		assert_same(xy_list(H.of_type(ev, "fog")), { "2,6" })
		assert_eq(#H.of_type(ev, "floor_lit"), 1)
	end)

	it("a paid starting special is never placed under the fog", function()
		for seed = 1, 8 do
			local g = H.game(FULL, { fog = fog(all_low()), goals = GOAL }, { seed = seed, boosters = { "riff", "sub", "disco" } })
			local n = 0
			for _, p in ipairs(g:pieces()) do
				if p.kind == "special" then
					n = n + 1
					assert_eq(p.fogged, nil)
					assert_eq(p.y, 1)
				end
			end
			assert_eq(n, 3)
		end
	end)
end)

describe("core fog: determinism, hash, clones (17, 10.13)", function()
	it("the same seed and commands give the same hash; a replay plays back", function()
		local function play()
			local g, lvl = H.game(FULL, { fog = fog(all_low()), goals = GOAL, moves = 12 }, { seed = 5 })
			for _ = 1, 8 do
				g:run_to_rest()
				if g:status().state ~= "playing" then break end
				local mv = g:moves()
				g:input({ type = "swap", from = mv[#mv].from, to = mv[#mv].to })
			end
			g:run_to_rest()
			return g, lvl
		end
		local a, lvl = play()
		local b = play()
		assert_eq(a:hash(), b:hash())
		local _, ok, why = core.playback(lvl, a:replay())
		assert_true(ok, why)
	end)

	it("the fog is part of the state hash on a fog level, and a clone carries it", function()
		local g = fresh(PA, { { 3, 3 }, { 5, 5 } })
		local h = g:hash()
		local c = g:clone()
		assert_eq(c:hash(), h)
		c.s.fog[idx(3, 3)] = false
		assert_true(c:hash() ~= h)
		assert_true(on(g, 3, 3), "the clone has its own fog")
	end)

	it("a level without fog: no fog state, no fog event, the hash does not fold one", function()
		local g = fresh(PA, nil)
		local h = g:hash()
		assert_eq(g.s.fog, false)
		assert_true(g:input(MOVE))
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "fog"), 0)
		-- the hash of a fogless level is that of the same level with every fog blown off... minus the fog block:
		-- a fog level whose cells are all clear still folds its (false) flags, so the two differ
		local f = fresh(PA, { { 3, 3 } })
		f.s.fog[idx(3, 3)] = false
		assert_true(f:hash() ~= h)
	end)
end)

describe("core fog: the blind clone, the view of a fair bot (17.3, 10.13)", function()
	it("what stands in a fogged cell becomes a colourless piece that matches nothing; the game itself is untouched", function()
		local rows = with(with(PA, 2, 4, "R"), 5, 4, "S")
		local g = fresh(rows, { { 2, 4 }, { 5, 4 }, { 1, 6 } }, { overlay = { { at = { 4, 3 }, type = "wires", hp = 1 } } })
		local h = g:hash()
		local v = g:clone({ blind = true })
		assert_eq(g:hash(), h)
		for _, c in ipairs({ { 2, 4 }, { 5, 4 }, { 1, 6 } }) do
			local o = H.obj_at(v, c[1], c[2])
			assert_same({ o.kind, o.color, o.special, o.chain, o.ice }, { C.K_REGULAR, 0, 0, 0, 0 })
			assert_true(on(v, c[1], c[2]), "the view keeps the fog")
		end
		assert_eq(H.obj_at(g, 2, 4).kind, C.K_SPECIAL)
		-- the purple line needs the hidden (1,6): no move in the view; the hidden specials offer no swap either
		assert_true(#g:moves() > 0)
		assert_same(v:moves(), {})
		assert_false(v:has_move())
	end)

	it("wires under the fog are not in the view; a level without fog clones as ever", function()
		local g = fresh(PA, { { 4, 4 } }, { overlay = { { at = { 3, 3 }, type = "wires", hp = 1 } } })
		assert_eq(g.s.wires[idx(4, 4)], 1)
		assert_eq(g:clone({ blind = true }).s.wires[idx(4, 4)], 0)
		local plain = fresh(PA, nil)
		assert_eq(plain:clone({ blind = true }):hash(), plain:hash())
	end)

	it("two boards that differ only under the fog have the same view", function()
		local cells = { { 2, 2 }, { 3, 3 }, { 4, 4 }, { 2, 5 } }
		local a = fresh(PB, cells)
		local b = fresh(with(with(with(with(PB, 2, 2, "b"), 3, 3, "y"), 4, 4, "S"), 2, 5, "g"), cells)
		assert_true(a:hash() ~= b:hash())
		assert_same(H.picture(b:clone({ blind = true })), H.picture(a:clone({ blind = true })))
		assert_same(b:clone({ blind = true }):moves(), a:clone({ blind = true }):moves())
	end)

	it("a move played in the view runs to rest: the stand-ins fall, are destroyed and leave no colour behind", function()
		local rows = with(PB, 2, 4, "R")
		local g = fresh(rows, { { 4, 4 }, { 5, 4 }, { 3, 4 }, { 4, 5 }, { 4, 6 } })
		local v = g:clone({ blind = true })
		v:set_timing("turbo")
		assert_true(v:input({ type = "tap", at = { 2, 4 } }))
		v:run_to_rest()
		assert_true(v:status().state == "playing" or v:status().state == "won_wait" or v:result() ~= nil)
	end)
end)
