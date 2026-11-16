-- The portals (10.14): pairs of cells that link two columns for gravity. The exit cell of a pair is "the cell
-- below" its entrance cell: a piece standing idle in the entrance hops into the empty exit cell and falls on
-- from there. What moves travels (pieces, specials, chained pieces, mics, coconuts); what stands still blocks
-- the entrance like it blocks any column.

local core = require("core.game")
local C = require("core.const")
local M = require("core.match")
local SH = require("core.shuffle")
local H = require("tests.core.helper")

-- Board A: a block of 3x3 on the left top (spawners above it) and a block of 3x3 on the right bottom. The
-- bottom row of the left block are the entrances, the top row of the right block the exits:
-- pair 1 (1,3) -> (4,4), pair 2 (2,3) -> (5,4), pair 3 (3,3) -> (6,4).
local A = { "###...", "###...", "###...", "...###", "...###", "...###" }
local A_PAIRS = { { 1, 3, 4, 4 }, { 2, 3, 5, 4 }, { 3, 3, 6, 4 } }
-- a picture of board A without a match and without a move that matters
local PA = { "ryb...", "gbr...", "ybg...", "...ryb", "...gbr", "...ybg" }

-- Board CH, a chain: three blocks of 3x3 going down to the right; the first feeds the second, the second the third.
local CH = { "###......", "###......", "###......", "...###...", "...###...", "...###...", "......###", "......###", "......###" }
local CH_PAIRS = { { 1, 3, 4, 4 }, { 2, 3, 5, 4 }, { 3, 3, 6, 4 }, { 4, 6, 7, 7 }, { 5, 6, 8, 7 }, { 6, 6, 9, 7 } }
local PCH = { "ryb......", "gbr......", "ybg......", "...ryb...", "...gbr...", "...ybg...", "......ryb", "......gbr", "......ybg" }

-- Pairs of the level file from 1-based {in x, in y, out x, out y}.
local function pairs_of(list)
	local out = {}
	for k, p in ipairs(list) do out[k] = { ["in"] = { p[1] - 1, p[2] - 1 }, out = { p[3] - 1, p[4] - 1 } } end
	return out
end

local function level_a(extra)
	extra = extra or {}
	if extra.portals == nil then extra.portals = pairs_of(A_PAIRS) end
	return H.level(A, extra)
end

-- A live board A (or `rows` with `pairs`) set to a picture.
local function fresh(picture, extra, opts, rows, prs)
	extra = extra or {}
	extra.portals = pairs_of(prs or A_PAIRS)
	local g, lvl = H.game(rows or A, extra, opts)
	H.board(g, picture or PA)
	g:drain_events()
	return g, lvl
end

local function with(rows, x, y, ch)
	local out = {}
	for k = 1, #rows do out[k] = rows[k] end
	out[y] = string.sub(out[y], 1, x - 1) .. ch .. string.sub(out[y], x + #ch)
	return out
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

local function rest(g, max)
	local all = {}
	for _ = 1, max or 3000 do
		g:step()
		for _, e in ipairs(g:drain_events()) do all[#all + 1] = e end
		if g:is_stable() then break end
	end
	return all
end

local function id_at(g, x, y)
	local o = H.obj_at(g, x, y)
	return o and o.id or 0
end

local function hops(ev)
	return H.of_type(ev, "portal")
end

-- Every existing cell holds something.
local function full(g)
	local s = g.s
	for i = 1, s.N do
		if s.exists[i] and s.slot[i] == 0 then return false end
	end
	return true
end

describe("core portal: level schema and rules (2.0, 2.1)", function()
	it("accepts the pairs and keeps the cells, the roles and the two ends of each", function()
		local lvl = H.load(A, { portals = pairs_of(A_PAIRS) })
		local po = lvl.portal
		assert_eq(#po.pairs, 3)
		assert_same({ po.pairs[1].inn, po.pairs[1].out }, { 13, 22 })
		assert_same({ po.pairs[3].inn, po.pairs[3].out }, { 15, 24 })
		assert_same({ po.role[13], po.pair[13], po.exit_of[13], po.entry_of[13] }, { 1, 1, 22, 0 })
		assert_same({ po.role[23], po.pair[23], po.exit_of[23], po.entry_of[23] }, { 2, 2, 0, 14 })
		assert_same({ po.role[1], po.pair[1], po.exit_of[1], po.entry_of[1] }, { 0, 0, 0, 0 })
		assert_eq(H.load(H.full(6, 6)).portal, nil)
	end)

	it("checks the fields of the block", function()
		expect(level_a({ portals = 3 }), "2.1.1 portals: a non-empty list of pairs {in, out} required")
		expect(level_a({ portals = {} }), "2.1.1 portals: a non-empty list of pairs {in, out} required")
		expect(level_a({ portals = { 7 } }), "2.1.1 portals[1]: object {in, out} required")
		expect(level_a({ portals = { { ["in"] = { 0, 2 }, out = { 3, 3 }, color = 1 } } }), "2.1.1 portals[1]: unknown key 'color'")
		expect(level_a({ portals = { { ["in"] = { 0, 2 } } } }), "2.1.1 portals[1]: out: [x, y] required")
		expect(level_a({ portals = { { out = { 3, 3 } } } }), "2.1.1 portals[1]: in: [x, y] required")
		expect(level_a({ portals = { { ["in"] = { 0 }, out = { 3, 3 } } } }), "2.1.1 portals[1]: in: [x, y] required")
		expect(level_a({ portals = { { ["in"] = { 0, 2 }, out = "top" } } }), "2.1.1 portals[1]: out: [x, y] required")
	end)

	it("2.1.2: on existing cells; a cell is one end of one pair", function()
		expect(level_a({ portals = pairs_of({ { 4, 3, 4, 4 } }) }), "2.1.2 portal is not on an existing cell at 3,2")
		expect(level_a({ portals = pairs_of({ { 1, 3, 7, 4 } }) }), "2.1.2 portal is not on an existing cell at 6,3")
		expect(level_a({ portals = pairs_of({ { 1, 3, 4, 4 }, { 1, 3, 5, 4 } }) }), "2.1.2 two portals in one cell at 0,2")
		expect(level_a({ portals = pairs_of({ { 1, 3, 4, 4 }, { 2, 3, 4, 4 } }) }), "2.1.2 two portals in one cell at 3,3")
		expect(level_a({ portals = pairs_of({ { 1, 3, 1, 3 } }) }), "2.1.2 two portals in one cell at 0,2")
	end)

	it("2.1.16: the entrance ends its column segment and the exit starts its own", function()
		expect(level_a({ portals = pairs_of({ { 1, 2, 4, 4 } }) }), "2.1.16 the cell under a portal entrance is not a void or the edge at 0,1")
		expect(level_a({ portals = pairs_of({ { 1, 3, 4, 5 } }) }), "2.1.16 the cell above a portal exit is not a void or the edge at 3,4")
		-- the bottom edge and the top edge of the board are as good as a void
		local lvl = H.load({ "###.##", "###.##", "###.##", "###.##", "###...", "###..." },
			{ portals = pairs_of({ { 1, 6, 5, 1 }, { 2, 6, 6, 1 } }) })
		assert_eq(#lvl.portal.pairs, 2)
	end)

	it("a portal cell is neither a spawner nor an exit: `top` and `bottom` skip it, a list may not name it", function()
		local lvl = H.load(A, { portals = pairs_of(A_PAIRS), goals = { { type = "drop", count = 2 } },
			coconut = { total = 2, on_board_max = 1, gap_moves = 3 } })
		for x = 1, 3 do
			assert_true(lvl.spawner[x], "a spawner over the left block")
			assert_false(lvl.spawner[18 + 3 + x], "no spawner on an exit of a portal")
			assert_false(lvl.exit[12 + x], "the entrance is the bottom of its segment and not an exit")
			assert_true(lvl.exit[30 + 3 + x], "the real bottom is an exit")
		end
		expect(level_a({ spawners = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 3 } } }), "2.1.16 portal on a spawner at 3,3")
		expect(level_a({ exits = { { 0, 2 }, { 3, 5 }, { 4, 5 }, { 5, 5 } } }), "2.1.16 portal on an exit at 0,2")
		-- a run of one cell under an exit would have to be a stand (2.1.8) and cannot be one
		expect(H.level({ "###...", "###...", "###...", "...###", "...#.#", "...#.#" },
			{ portals = pairs_of(A_PAIRS), goals = { { type = "deliver", count = 1 } }, mic = { total = 1, on_board_max = 1, gap_moves = 0 } }),
			"2.1.8 segment bottom is not an exit at 4,3")
	end)

	it("2.1.16: nothing that stands still on a portal at the start; no curtain, no fog, no belt", function()
		expect(level_a({ slots = { { at = { 0, 2 }, type = "record_box", hp = 1 } } }), "2.1.16 blocker on a portal at 0,2")
		expect(level_a({ slots = { { at = { 3, 3 }, type = "noise" } } }), "2.1.16 blocker on a portal at 3,3")
		expect(level_a({ overlay = { { at = { 1, 2 }, type = "wires", hp = 1 } } }), "2.1.16 wires on a portal at 1,2")
		expect(level_a({ overlay = { { at = { 4, 3 }, type = "ice", hp = 2 } } }), "2.1.16 ice on a portal at 4,3")
		expect(level_a({ curtain = { covers = { { 2, 2 } }, closed_moves = 2, open_moves = 2, start = "open" } }),
			"2.1.16 curtain over a portal at 2,2")
		expect(level_a({ fog = { { 5, 3 } } }), "2.1.16 fog over a portal at 5,3")
		expect(level_a({ conveyor = { { path = { { 0, 2 }, { 1, 2 }, { 2, 2 } } } }, portals = pairs_of({ { 3, 3, 6, 4 } }) }),
			"2.1.16 portal on a conveyor at 2,2")
		-- a column of 2x2 covers four cells
		expect(H.level({ "####..", "####..", "####..", "...###", "...###", "...###" },
			{ portals = pairs_of({ { 1, 3, 4, 4 } }), slots = { { at = { 0, 1 }, type = "column", hp = 6 } } }),
			"2.1.16 blocker on a portal at 0,2")
	end)

	it("2.1.16: what may lie on a portal: a preset piece, a special, a chain, a floor tile, the carpet", function()
		local lvl = H.load(A, { portals = pairs_of(A_PAIRS),
			slots = { { at = { 0, 2 }, type = "piece", color = "red" }, { at = { 4, 3 }, type = "riff", axis = "h" } },
			overlay = { { at = { 2, 2 }, type = "chain", hp = 1 } }, floor = { { at = { 3, 3 }, hp = 2 } },
			goals = { { type = "light" } } })
		assert_eq(lvl.floor[22], 2)
		local rug = H.load(A, { portals = pairs_of(A_PAIRS), carpet = { { 0, 2 }, { 3, 3 } }, goals = { { type = "carpet" } } })
		local g = core.new(rug, { seed = 1 })
		local cells = g:cells()
		assert_true(cells[13].carpet and cells[13].portal.role == "in")
		assert_true(cells[22].carpet and cells[22].portal.role == "out")
	end)

	it("2.1.16: no cycles: the way down from an exit ends in a run with a real bottom", function()
		-- one pair whose exit run ends in its own entrance
		expect(H.level({ "####.#", "####.#", "####..", "####.#", "####.#", "####.#" }, { portals = pairs_of({ { 6, 2, 6, 1 } }),
			spawners = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 } } }), "2.1.16 portals form a cycle at 5,1")
		-- two pairs that feed each other
		expect(H.level({ "####.#", "####.#", "####..", "####.#", "####.#", "####.#" },
			{ portals = pairs_of({ { 6, 2, 6, 4 }, { 6, 6, 6, 1 } }), spawners = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 } } }),
			"2.1.16 portals form a cycle at 5,1")
		-- a chain is no cycle
		assert_eq(#H.load(CH, { portals = pairs_of(CH_PAIRS) }).portal.pairs, 6)
	end)

	it("2.1.16: a spawner feeds every entrance, straight or through a chain of portals", function()
		expect(level_a({ spawners = { { 0, 0 }, { 1, 0 } } }), "2.1.16 no spawner feeds the portal entrance at 2,2")
		expect(H.level(CH, { portals = pairs_of(CH_PAIRS), spawners = { { 1, 0 }, { 2, 0 } } }),
			"2.1.16 no spawner feeds the portal entrance at 0,2")
		expect(H.level(CH, { portals = pairs_of(CH_PAIRS), spawners = { { 1, 0 }, { 2, 0 } } }),
			"2.1.16 no spawner feeds the portal entrance at 3,5")
	end)

	it("2.1.7: a run under an exit that no pair feeds stays empty", function()
		-- the third column of the right block has no portal: nothing fills it
		expect(level_a({ portals = pairs_of({ { 1, 3, 4, 4 }, { 2, 3, 5, 4 } }), spawners = { { 0, 0 }, { 1, 0 }, { 2, 0 } } }),
			"2.1.7 cell stays empty on board B0 at 5,3")
	end)

	it("2.1.6: the portal is one of the three elements a level may have", function()
		local base = { portals = pairs_of(A_PAIRS), slots = { { at = { 1, 1 }, type = "noise" } },
			floor = { { at = { 4, 4 }, hp = 1 } }, goals = { { type = "light" } } }
		assert_true(core.load_level(H.level(A, base)) ~= nil)
		base.overlay = { { at = { 0, 0 }, type = "chain", hp = 1 } }
		expect(H.level(A, base), "2.1.6 more than three different elements")
	end)
end)

describe("core portal: gravity through a pair (10.14)", function()
	it("the piece in the entrance hops into the empty exit cell; the entrance column refills from its spawner", function()
		local g = fresh(with(PA, 5, 4, "_"))
		local id = id_at(g, 2, 3)
		local above = id_at(g, 2, 2)
		g:step()
		local ev = g:drain_events()
		assert_same(hops(ev), { { type = "portal", t = 1, id = id, fx = 2, fy = 3, x = 5, y = 4, pair = 2 } })
		local o = H.obj_at(g, 5, 4)
		assert_eq(o.id, id)
		-- a fall of one cell: the same timing as any piece that drops one cell
		assert_same({ o.state, o.offx }, { C.S_FALL, 0 })
		assert_true(o.offy > 0 and o.offy <= C.UNIT)
		-- the same pass brings the entrance column down and spawns at its top
		assert_eq(id_at(g, 2, 3), above)
		local sp = H.of_type(ev, "spawn")
		assert_eq(#sp, 1)
		assert_same({ sp[1].x, sp[1].y }, { 2, 1 })
		rest(g)
		assert_true(g:is_stable() and full(g))
	end)

	it("a hop takes as long as a fall of one cell", function()
		local g = fresh(with(PA, 5, 4, "_"))
		local plain = H.game(H.full(6, 6))
		H.board(plain, with(H.rows(6, 6), 3, 6, "_"))
		local function ticks_to_land(game, x, y)
			for t = 1, 60 do
				game:step()
				for _, e in ipairs(game:drain_events()) do
					if e.type == "land" and e.x == x and e.y == y then return t end
				end
			end
		end
		assert_eq(ticks_to_land(g, 5, 4), ticks_to_land(plain, 3, 6))
	end)

	it("only the exit cell takes a piece from the entrance: a cell lower in the run waits for it to come out", function()
		local pic = with(with(with(PA, 5, 4, "_"), 5, 5, "_"), 5, 6, "_")
		local g = fresh(pic)
		local id = id_at(g, 2, 3)
		g:step()
		local ev = g:drain_events()
		assert_eq(#hops(ev), 1)
		assert_eq(id_at(g, 5, 4), id) -- in the exit cell, not at the bottom of the run
		assert_eq(id_at(g, 5, 6), 0)
		g:step()
		assert_eq(id_at(g, 5, 6), id) -- now it falls on by the ordinary transfer, still in flight
		assert_eq(H.obj_at(g, 5, 6).state, C.S_FALL)
		local all = rest(g)
		assert_true(full(g))
		local n = 0
		for _, e in ipairs(all) do
			if e.type == "portal" then
				n = n + 1
				assert_same({ e.fx, e.fy, e.x, e.y, e.pair }, { 2, 3, 5, 4, 2 })
			end
		end
		assert_true(n >= 2, "the rest of the run came through the same pair")
	end)

	it("a piece lands in the entrance first and hops in a later tick; a falling piece never hops", function()
		local g = fresh(with(with(PA, 5, 4, "_"), 2, 3, "_"))
		local id = id_at(g, 2, 2)
		g:step()
		assert_eq(#hops(g:drain_events()), 0)
		assert_eq(id_at(g, 2, 3), id)
		assert_eq(H.obj_at(g, 2, 3).state, C.S_FALL)
		local landed, hopped
		for t = 2, 40 do
			g:step()
			for _, e in ipairs(g:drain_events()) do
				if e.type == "land" and e.id == id and not landed then landed = t end
				if e.type == "portal" and e.id == id then hopped = t end
			end
			if hopped then break end
		end
		assert_true(landed ~= nil and hopped == landed + 1, "landed in tick " .. tostring(landed) .. ", hopped in " .. tostring(hopped))
	end)

	it("everything that falls travels: a special, a chained piece, a mic, a coconut", function()
		for _, ch in ipairs({ "R", "S", "B", "D" }) do
			local g = fresh(with(with(PA, 5, 4, "_"), 2, 3, ch))
			local id = id_at(g, 2, 3)
			g:step()
			assert_eq(id_at(g, 5, 4), id, ch)
			assert_eq(H.obj_at(g, 5, 4).kind, C.K_SPECIAL)
		end
		-- the chain stays on its piece
		local g = fresh(with(PA, 5, 4, "_"))
		H.obj_at(g, 2, 3).chain = 2
		local id = id_at(g, 2, 3)
		g:step()
		assert_same({ id_at(g, 5, 4), H.obj_at(g, 5, 4).chain }, { id, 2 })
		for _, def in ipairs({ { "M", "deliver", "mic" }, { "C", "drop", "coconut" } }) do
			local extra = { goals = { { type = def[2], count = 2 } } }
			extra[def[3]] = { total = 2, on_board_max = 1, gap_moves = 9 }
			local m = fresh(with(with(PA, 5, 4, "_"), 2, 3, def[1]), extra)
			m.s.released, m.s.on_board = 1, 1
			local mid = id_at(m, 2, 3)
			m:step()
			assert_eq(id_at(m, 5, 4), mid, def[3])
		end
	end)

	it("the hop keeps the id and raises the label like a fall (1.3.5)", function()
		local g = fresh(with(PA, 5, 4, "_"))
		local s = g.s
		s.vac_mv[23], s.vac_wv[23] = 4, 2
		local id = id_at(g, 2, 3)
		g:step()
		local o = H.obj_at(g, 5, 4)
		assert_same({ o.id, o.mv, o.wv }, { id, 4, 2 })
		assert_same({ s.vac_mv[14], s.vac_wv[14] }, { 4, 2 }) -- the entrance was left by that piece
	end)

	it("several pairs hop in one tick, in the order of the pass (by cell index of the exit); one hop a piece a tick", function()
		local g = fresh(with(PA, 4, 4, "___"))
		local ids = { id_at(g, 1, 3), id_at(g, 2, 3), id_at(g, 3, 3) }
		g:step()
		local hp = hops(g:drain_events())
		assert_eq(#hp, 3)
		for k = 1, 3 do assert_same({ hp[k].id, hp[k].pair, hp[k].x }, { ids[k], k, 3 + k }) end
	end)
end)

describe("core portal: what blocks the entrance (10.14)", function()
	local function stuck(g)
		local ev = rest(g)
		assert_eq(#hops(ev), 0)
		assert_true(g:is_stable())
		assert_eq(id_at(g, 5, 4), 0) -- a hole, like under a blocker
		return ev
	end

	it("a blocker in the entrance: the exit run waits as a hole, and fills when the blocker is gone", function()
		local g = fresh(with(with(PA, 5, 4, "_"), 2, 3, "X"))
		stuck(g)
		local s = g.s
		s.objs[s.slot[14]] = nil
		s.slot[14] = 0
		local ev = rest(g)
		assert_true(#hops(ev) >= 1)
		assert_true(full(g))
	end)

	it("a piece under wires or in ice does not travel", function()
		local g = fresh(with(PA, 5, 4, "_"))
		g.s.wires[14] = 1
		stuck(g)
		g.s.wires[14] = 0
		assert_true(#hops(rest(g)) >= 1)
		local f = fresh(with(PA, 5, 4, "_"))
		H.obj_at(f, 2, 3).ice = 1
		stuck(f)
		H.obj_at(f, 2, 3).ice = 0
		assert_true(#hops(rest(f)) >= 1)
	end)

	it("a pinned, swapping or clearing piece makes the exit wait", function()
		local g = fresh(with(PA, 5, 4, "_"))
		local o = H.obj_at(g, 2, 3)
		o.pins = { 99 }
		assert_eq(#hops(H.steps(g, 5)), 0)
		o.pins = {}
		o.state, o.tk, o.td = C.S_SWAP, C.TM_LOCK, g.s.tick + 4
		local ev = H.steps(g, 3)
		assert_eq(#hops(ev), 0)
		ev = H.steps(g, 3)
		assert_eq(#hops(ev), 1) -- the lock ended, the piece is idle: it hops
	end)

	it("a blocked entrance: the cells lower in the run take diagonal donors by the ordinary rule", function()
		-- the exit cell and the cell under it are empty, a blocker stands in the entrance: the lower cell is
		-- `blocked`, its neighbours' exit cells give it a piece, and those exits refill through their own pairs
		local g = fresh(with(with(with(PA, 5, 4, "_"), 5, 5, "_"), 2, 3, "X"))
		local ev = rest(g)
		assert_true(H.obj_at(g, 5, 5) ~= nil, "the lower cell was filled from the side")
		local hp = hops(ev)
		assert_true(#hp >= 1)
		for _, e in ipairs(hp) do assert_true(e.pair ~= 2, "nothing came through the blocked pair") end
		assert_eq(id_at(g, 5, 4), 0)
		assert_true(g:is_stable())
	end)

	it("an empty entrance under a blocker of its own column: the exit is blocked too, not waiting for ever", function()
		local g = fresh(with(with(with(PA, 5, 4, "_"), 2, 3, "_"), 2, 2, "X"))
		local ev = rest(g)
		-- the entrance itself takes a diagonal donor (10.1), and that piece then travels
		assert_true(#hops(ev) >= 1)
		assert_true(g:is_stable())
		assert_true(full(g))
	end)

	it("a closed curtain in the entrance column blocks it like any column (10.7)", function()
		local g = fresh(with(with(PA, 5, 4, "_"), 2, 3, "_"),
			{ curtain = { covers = { { 1, 1 } }, closed_moves = 9, open_moves = 1, start = "closed" } })
		assert_true(g.s.cur_closed)
		local id = id_at(g, 2, 2)
		local ev = rest(g)
		assert_eq(id_at(g, 2, 2), id) -- frozen under the curtain
		assert_true(g:is_stable())
		for _, e in ipairs(hops(ev)) do assert_true(e.id ~= id) end
	end)

	it("a piece in an entrance is no diagonal donor while its exit is empty: it goes through its portal", function()
		-- (2,2) is an entrance, its exit (5,3) is empty; (3,3) is empty under a blocker and would take (2,2)
		local rows = { "###..#", "###..#", "..#.##", "..#.##", "..#.##", "..#.##" }
		local pic = { "ryb..g", "gbX..r", "..r._y", "..g.bg", "..y.rb", "..b.gy" }
		pic[3] = "..__" .. "_y" -- (3,3) and (5,3) empty
		pic[3] = ".._._y"
		local g = fresh(pic, nil, nil, rows, { { 2, 2, 5, 3 } })
		local id = id_at(g, 2, 2)
		g:step()
		local hp = hops(g:drain_events())
		assert_eq(#hp, 1)
		assert_eq(hp[1].id, id)
		assert_eq(id_at(g, 5, 3), id)
		assert_eq(id_at(g, 3, 3), 0)
		-- once the exit is full again, the entrance is an ordinary donor
		rest(g)
		assert_true(H.obj_at(g, 3, 3) ~= nil)
		assert_true(full(g))
	end)
end)

describe("core portal: chains of pairs (10.14)", function()
	it("a piece goes through one portal a tick and through the second only after it landed in its entrance", function()
		local pic = {}
		for y = 1, 9 do pic[y] = PCH[y] end
		pic[4], pic[5], pic[6] = "..._yb...", "..._br...", "..._bg..."
		pic[7], pic[8], pic[9] = "......_yb", "......_br", "......_bg"
		local g = fresh(pic, nil, nil, CH, CH_PAIRS)
		local when = {}
		for t = 1, 400 do
			g:step()
			local seen = {}
			for _, e in ipairs(g:drain_events()) do
				if e.type == "portal" then
					assert_true(not seen[e.id], "two hops of one piece in one tick")
					seen[e.id] = true
					when[e.id] = when[e.id] or {}
					table.insert(when[e.id], { t, e.pair })
				end
			end
			if g:is_stable() then break end
		end
		assert_true(g:is_stable() and full(g))
		local twice = 0
		for _, list in pairs(when) do -- order-independent
			if #list == 2 then
				twice = twice + 1
				assert_same({ list[1][2], list[2][2] }, { 1, 4 }) -- column 1 -> column 4 -> column 7
				assert_true(list[2][1] > list[1][1] + 1)
			end
		end
		assert_true(twice >= 1, "a piece of the first block reached the third")
	end)

	it("an empty middle block asks the pair above it: the third block waits, nothing is lost", function()
		local pic = {}
		for y = 1, 9 do pic[y] = PCH[y] end
		pic[4], pic[5], pic[6] = "..._yb...", "..._br...", "..._bg..."
		pic[7], pic[8], pic[9] = "......_yb", "......_br", "......_bg"
		local g = fresh(pic, nil, nil, CH, CH_PAIRS)
		rest(g)
		assert_true(g:is_stable() and full(g))
	end)
end)

describe("core portal: mics and coconuts travel on (10.14)", function()
	local function carrier(ch, goal, block)
		local extra = { goals = { { type = goal, count = 2 } } }
		extra[block] = { total = 2, on_board_max = 1, gap_moves = 30 }
		return function(picture)
			local g = fresh(picture, extra)
			g.s.released, g.s.on_board, g.s.last_mic = 1, 1, 0
			return g
		end
	end

	for _, def in ipairs({ { "M", "deliver", "mic", "mic_delivered" }, { "C", "drop", "coconut", "coconut_collected" } }) do
		local make = carrier(def[1], def[2], def[3])
		it("a " .. def[3] .. " in the entrance is not collected there: the entrance is no exit", function()
			local g = make(with(PA, 2, 3, def[1]))
			assert_false(g.s.exit[14])
			local ev = H.steps(g, 30)
			assert_eq(#H.of_type(ev, def[4]), 0)
			assert_eq(H.obj_at(g, 2, 3).kind, def[3] == "mic" and C.K_MIC or C.K_COCONUT)
			assert_eq(g:status().goals[1], 2)
		end)

		it("a " .. def[3] .. " goes through the portal, falls down the exit run and is collected on the real bottom", function()
			local g = make(with(with(with(with(PA, 2, 3, def[1]), 5, 4, "_"), 5, 5, "_"), 5, 6, "_"))
			local id = id_at(g, 2, 3)
			local ev = rest(g)
			local hop_t, got_t
			for _, e in ipairs(ev) do
				if e.type == "portal" and e.id == id then hop_t = e.t end
				if e.type == def[4] then
					got_t = e.t
					assert_same({ e.id, e.x, e.y }, { id, 5, 6 })
				end
			end
			assert_true(hop_t ~= nil and got_t ~= nil and got_t > hop_t)
			assert_eq(g:status().goals[1], 1)
			assert_eq(g.s.on_board, 0)
		end)
	end

	it("through a chain of portals a coconut is collected only at the end of the last run", function()
		local pic = with(PCH, 1, 3, "C")
		pic[4], pic[5], pic[6] = "..._yb...", "..._br...", "..._bg..."
		pic[7], pic[8], pic[9] = "......_yb", "......_br", "......_bg"
		local g = fresh(pic, { goals = { { type = "drop", count = 1 } }, coconut = { total = 1, on_board_max = 1, gap_moves = 30 } },
			nil, CH, CH_PAIRS)
		g.s.released, g.s.on_board, g.s.last_mic = 1, 1, 0
		local id = id_at(g, 1, 3)
		local ev = rest(g)
		local route = {}
		for _, e in ipairs(ev) do
			if e.type == "portal" and e.id == id then route[#route + 1] = e.pair end
			if e.type == "coconut_collected" then
				route[#route + 1] = "out"
				assert_same({ e.x, e.y }, { 7, 9 })
			end
		end
		assert_same(route, { 1, 4, "out" })
		assert_eq(g:status().goals[1], 0)
	end)
end)

describe("core portal: matches, effects and everything else see ordinary cells (10.14)", function()
	it("a piece that comes out of the exit and completes a line matches there; the cascade goes on through the portals", function()
		-- red, _, red in the exit row and a red in the middle entrance
		local pic = { "ryb...", "gbg...", "yry...", "...r_r", "...gbg", "...ybg" }
		local g = fresh(pic)
		local id = id_at(g, 2, 3)
		local ev = rest(g)
		local m = H.of_type(ev, "match")
		assert_true(#m >= 1)
		assert_same(m[1].cells, { { 4, 4 }, { 5, 4 }, { 6, 4 } })
		local cleared = false
		for _, e in ipairs(H.of_type(ev, "clear")) do
			if e.id == id then cleared = true end
		end
		assert_true(cleared, "the piece that travelled is part of the match")
		assert_true(#hops(ev) >= 4, "the three cleared exit cells were filled through their pairs")
		assert_true(g:is_stable() and full(g))
	end)

	it("a piece that lands in an entrance stands there for a tick and matches there like in any cell", function()
		-- a red falls into the empty entrance (2,3) between two reds, the exit (5,4) is empty: the line wins
		local pic = { "ryb...", "grg...", "r_r...", "...r_b", "...gbg", "...ybg" }
		local g = fresh(pic)
		local id = id_at(g, 2, 2)
		local ev = rest(g)
		local m = H.of_type(ev, "match")
		assert_same(m[1].cells, { { 1, 3 }, { 2, 3 }, { 3, 3 } })
		for _, e in ipairs(hops(ev)) do assert_true(e.id ~= id, "the matched piece never travelled") end
		assert_true(g:is_stable() and full(g))
	end)

	it("the cells of a pair are swapped, matched and hit like any others; the hint and the moves read them", function()
		-- the only move of the board: (1,2) down into the entrance (1,3) makes a red line in the entrance row
		local pic = { "ybg...", "rgb...", "yrr...", "...ybg", "...gyb", "...bgy" }
		local g = fresh(pic)
		assert_same(g:moves(), { { from = { 1, 2 }, to = { 1, 3 } } })
		assert_same(g:hint(), { from = { 1, 2 }, to = { 1, 3 } })
		assert_eq(g:can_swap({ 1, 2 }, { 1, 3 }), "ok")
		assert_true(g:input({ type = "swap", from = { 1, 2 }, to = { 1, 3 } }))
		local ev = rest(g)
		assert_same(H.of_type(ev, "match")[1].cells, { { 1, 3 }, { 2, 3 }, { 3, 3 } })
		assert_true(g:is_stable() and full(g))
	end)

	it("an effect hits a portal cell like any cell, and the run refills through the pair", function()
		local g = fresh(with(PA, 5, 5, "R"))
		assert_true(g:input({ type = "tap", at = { 5, 5 } }))
		local ev = rest(g)
		assert_true(#hops(ev) >= 3)
		assert_true(g:is_stable() and full(g))
	end)

	it("the shuffle and the Remix take portal cells like any other cells", function()
		local g = fresh(PA)
		assert_eq(#SH.candidates(g.s), 18)
		assert_true(g:input({ type = "booster", booster = "remix" }))
		local ev = rest(g)
		assert_eq(#H.of_type(ev, "shuffle"), 1)
		assert_true(g:is_stable() and full(g))
	end)

	it("a floor tile on a portal cell is lit by a match on it; the carpet rolls over portal cells", function()
		local pic = { "ybg...", "rgb...", "yrr...", "...ybg", "...gyb", "...bgy" }
		local g = fresh(pic, { floor = { { at = { 0, 2 }, hp = 1 }, { at = { 3, 3 }, hp = 1 } }, goals = { { type = "light" } } })
		assert_true(g:input({ type = "swap", from = { 1, 2 }, to = { 1, 3 } }))
		local ev = rest(g)
		local lit = H.of_type(ev, "floor_lit")
		assert_same({ lit[1].x, lit[1].y }, { 1, 3 })
		local c = fresh(pic, { carpet = { { 1, 2 }, { 3, 3 } }, goals = { { type = "carpet" } } })
		assert_true(c:input({ type = "swap", from = { 1, 2 }, to = { 1, 3 } }))
		rest(c)
		local cells = c:cells()
		assert_true(cells[13].carpet and cells[14].carpet and cells[15].carpet)
	end)

	it("the Songbird counts the exit cell as the cell under a mic that waits in the entrance (section 9)", function()
		local BD = require("core.bird")
		local extra = { goals = { { type = "deliver", count = 2 } }, mic = { total = 2, on_board_max = 1, gap_moves = 30 } }
		local g = fresh(with(PA, 2, 3, "M"), extra)
		g.s.released, g.s.on_board, g.s.last_mic = 1, 1, 0
		assert_eq(BD.levels(g.s)[23], 3) -- the exit of pair 2: the cell the mic falls into
		assert_eq(BD.levels(g.s)[22], 1)
		assert_eq(BD.levels(fresh(PA, extra).s)[23], 1)
	end)

	it("the hint counts a match through the exit cell under a waiting mic as goal progress (12.3)", function()
		-- two moves: (3,1)-(3,2), a red line in the left block, and (5,4)-(5,5), a blue line through the exit
		-- cell of the pair whose entrance holds the mic
		local pic = { "rry...", "gbr...", "yMg...", "...byb", "...gbr", "...ygy" }
		local extra = { goals = { { type = "deliver", count = 2 } }, mic = { total = 2, on_board_max = 1, gap_moves = 30 } }
		local g = fresh(pic, extra)
		g.s.released, g.s.on_board, g.s.last_mic = 1, 1, 0
		assert_same(g:hint(), { from = { 5, 4 }, to = { 5, 5 } })
		-- the same board with a piece instead of the mic: the first move of the board
		assert_same(fresh(with(pic, 2, 3, "p"), extra):hint(), { from = { 3, 1 }, to = { 3, 2 } })
	end)

	it("game:cells() tells the role, the pair and the other end of every portal cell", function()
		local g = fresh(PA)
		local cells = g:cells()
		assert_same(cells[13].portal, { role = "in", pair = 1, x = 4, y = 4 })
		assert_same(cells[24].portal, { role = "out", pair = 3, x = 3, y = 3 })
		assert_eq(cells[1].portal, nil)
		assert_false(cells[22].spawner)
		local plain = H.game(H.full(6, 6))
		for _, c in ipairs(plain:cells()) do assert_eq(c.portal, nil) end
	end)
end)

-- Random play --------------------------------------------------------------------------------------------------------

local function lcg(seed)
	local x = seed % 2147483647
	if x == 0 then x = 1 end
	return function(n)
		x = (x * 48271) % 2147483647
		return x % n + 1
	end
end

-- The invariants of a board: every slot holds a living object that knows its cell, every object stands in one
-- slot, the cell layers are the level's; at rest everything is idle with no timer, there is no match, and no
-- piece that could travel waits in an entrance over an empty exit.
local function check_board(g, lvl, tag)
	local s = g.s
	local seen = {}
	for i = 1, s.N do
		local id = s.slot[i]
		if id ~= 0 then
			local o = s.objs[id]
			assert_true(o ~= nil, tag .. ": slot " .. i .. " holds a dead id")
			assert_true(s.exists[i], tag .. ": an object in a void")
			assert_eq(o.cell, i, tag .. ": object " .. id .. " does not know its cell")
			assert_true(not seen[id], tag .. ": object " .. id .. " stands in two cells")
			seen[id] = true
		end
		assert_eq(s.exists[i], lvl.exists[i])
		assert_eq(s.spawner[i], lvl.spawner[i])
	end
	for id, o in pairs(s.objs) do -- order-independent
		assert_true(seen[id], tag .. ": object " .. id .. " is in no slot")
		assert_eq(o.id, id)
	end
	if g:is_stable() then
		local coconuts = 0
		for i = 1, s.N do
			local o = s.slot[i] ~= 0 and s.objs[s.slot[i]] or nil
			if o then
				assert_same({ o.state, o.tk, o.td, o.offx, o.offy }, { C.S_IDLE, 0, 0, 0, 0 }, tag .. ": cell " .. i)
				assert_eq(#o.pins, 0)
				if o.kind == C.K_COCONUT then
					coconuts = coconuts + 1
					assert_false(s.exit[i], tag .. ": a coconut rests on an exit")
				end
			end
		end
		if lvl.coconut then assert_eq(coconuts, s.on_board, tag .. ": coconuts on the board") end
		assert_false(M.any_match(M.color_map(s), s.W, s.H), tag .. ": a match on a board at rest")
		local po = lvl.portal
		for k = 1, po and #po.pairs or 0 do
			local n, e = po.pairs[k].inn, po.pairs[k].out
			if s.slot[e] == 0 and s.slot[n] ~= 0 then
				local o = s.objs[s.slot[n]]
				assert_true(o.kind == C.K_BLOCKER or s.wires[n] > 0 or o.ice > 0,
					tag .. ": pair " .. k .. " rests with a piece over an empty exit")
			end
		end
	end
end

local FUZZ = {
	-- a chain of three blocks with noise (it grows onto portal cells too) and chained pieces
	{
		rows = CH,
		extra = {
			moves = 30, goals = { { type = "collect", color = "red", count = 9999 } },
			colors = { "red", "yellow", "green", "blue", "purple" },
			portals = pairs_of(CH_PAIRS),
			slots = { { at = { 1, 1 }, type = "noise" }, { at = { 7, 8 }, type = "noise" } },
			overlay = { { at = { 0, 0 }, type = "chain", hp = 2 }, { at = { 4, 4 }, type = "chain", hp = 1 } },
		},
	},
	-- portals over a gap in three columns, coconuts that must go through them, a belt above the entrances
	{
		rows = { "####.###", "####.###", "####.###", "####.###", "####....", "####.###", ".....###", ".....###" },
		extra = {
			moves = 30, goals = { { type = "drop", count = 60 } },
			colors = { "red", "yellow", "green", "blue", "purple" },
			coconut = { total = 90, on_board_max = 3, gap_moves = 1 },
			portals = pairs_of({ { 6, 4, 6, 6 }, { 7, 4, 7, 6 }, { 8, 4, 8, 6 } }),
			conveyor = { { path = { { 5, 2 }, { 6, 2 }, { 7, 2 } } }, { path = { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 3, 1 } } } },
		},
	},
}

-- Plays `n` random moves (a swap of moves(), a tap of a special now and then); goes on after the moves run out and
-- starts the level again after it ends. Returns a log of hashes, the moves played, the hops seen.
local function random_play(lvl, seed, n, timing, each)
	local rnd = lcg(seed)
	local g = core.new(lvl, { seed = seed, timing = timing })
	local log = {}
	local steps, hop_n, got = 0, 0, 0
	local function run()
		for _ = 1, 20000 do
			if g:is_stable() then return end
			g:step()
			local seen = {}
			for _, e in ipairs(g:drain_events()) do
				if e.type == "portal" then
					hop_n = hop_n + 1
					assert_true(not seen[e.id], "two hops of one piece in one tick")
					seen[e.id] = true
				elseif e.type == "coconut_collected" then
					got = got + 1
					assert_true(lvl.exit[(e.y - 1) * lvl.W + e.x], "a coconut was collected off an exit")
				end
			end
			if each then each(g) end
		end
		error("the board did not come to rest")
	end
	for k = 1, n do
		run()
		local st = g:status().state
		if st == "out_of_moves" then
			if not g:input({ type = "continue", moves = 15 }) then
				g = core.new(lvl, { seed = seed + k, timing = timing })
			else
				g:step() -- (the clock goes on: step 8 looks for a move again)
				g:drain_events()
			end
		elseif st ~= "playing" then
			g = core.new(lvl, { seed = seed + k, timing = timing })
		else
			local mv = g:moves()
			local cmd
			if #mv > 0 and rnd(5) > 1 then
				local m = mv[rnd(#mv)]
				cmd = { type = "swap", from = m.from, to = m.to }
			else
				local h = g:hint()
				if h and h.at then cmd = { type = "tap", at = h.at }
				elseif #mv > 0 then cmd = { type = "swap", from = mv[1].from, to = mv[1].to } end
			end
			if cmd then
				assert_true(g:input(cmd))
				steps = steps + 1
			end
		end
		g:step()
		g:drain_events()
		run()
		if each then each(g) end
		log[#log + 1] = g:hash()
	end
	return log, steps, hop_n, got, g
end

describe("core portal: random play keeps the board whole", function()
	for li, def in ipairs(FUZZ) do
		for _, timing in ipairs({ "turbo", "normal" }) do
			it("level " .. li .. ", " .. timing .. ": a few hundred moves, the invariants hold in every tick", function()
				local lvl = H.load(def.rows, def.extra)
				local n = timing == "turbo" and 260 or 70
				local tick = 0
				local _, steps, hop_n, got = random_play(lvl, 200 + li, n, timing, function(g)
					tick = tick + 1
					-- every tick in turbo is cheap; in normal timing every fourth
					if timing == "turbo" or tick % 4 == 0 or g:is_stable() then check_board(g, lvl, "tick " .. tick) end
				end)
				assert_true(steps >= n * 0.8, "moves played: " .. steps)
				assert_true(hop_n >= (li == 1 and 20 or 5), "hops: " .. hop_n)
				if li == 2 then assert_true(got > 0, "coconuts came through the portals to the exits") end
			end)
		end
	end
end)

describe("core portal: determinism (17)", function()
	it("the same seed and commands give the same game; another seed another", function()
		local lvl = H.load(FUZZ[1].rows, FUZZ[1].extra)
		local a = random_play(lvl, 7, 40, "normal")
		local b = random_play(lvl, 7, 40, "normal")
		assert_same(a, b)
		local c = random_play(lvl, 8, 40, "normal")
		assert_true(c[#c] ~= a[#a])
	end)

	it("a replay of a portal level plays back to the same hash", function()
		local lvl = H.load(FUZZ[2].rows, FUZZ[2].extra)
		local g = core.new(lvl, { seed = 11 })
		for _ = 1, 12 do
			g:run_to_rest()
			if g:status().state ~= "playing" then break end
			local mv = g:moves()[1]
			if not mv then break end
			assert_true(g:input({ type = "swap", from = mv.from, to = mv.to }))
		end
		g:run_to_rest()
		local _, ok, why = core.playback(lvl, g:replay())
		assert_true(ok, why)
	end)

	it("a clone carries the portals with it; a turbo clone ends on the same board", function()
		local g = fresh(with(with(PA, 5, 4, "_"), 5, 5, "_"))
		local c = g:clone()
		assert_eq(c:hash(), g:hash())
		local t = g:clone()
		t:set_timing("turbo")
		rest(g)
		rest(c)
		rest(t)
		assert_eq(c:hash(), g:hash())
		assert_same(H.picture(t), H.picture(g))
	end)

	it("a level without portals has none of this: no field, no cell flag, no event", function()
		local lvl = H.load(H.full(7, 7), { colors = { "red", "yellow", "green", "blue", "purple" } })
		assert_eq(lvl.portal, nil)
		local _, steps, hop_n = random_play(lvl, 5, 25, "turbo")
		assert_true(steps > 0)
		assert_eq(hop_n, 0)
	end)
end)
