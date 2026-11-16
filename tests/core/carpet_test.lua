-- The carpet (10.8): a covering of the cells that the PLAYER spreads. A match that stands on the carpet with at
-- least one cell rolls it out under all its cells; an effect that starts on the carpet carries it to every cell
-- it hits; an intact blocker is a wall. The goal `carpet` is to cover the whole board.

local core = require("core.game")
local C = require("core.const")
local BD = require("core.bird")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- a board without a match and without a move (no purple and no orange in it)
local P0 = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }
-- the swap (3,5) -> (3,6) makes a purple line of three in the bottom row: (1,6) (2,6) (3,6); no other move
local PA = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "bypgby", "ppgbyr" }
local MOVE = { type = "swap", from = { 3, 5 }, to = { 3, 6 } }
local GOAL = { { type = "carpet" } }

local function with(rows, x, y, ch)
	local out = {}
	for k = 1, #rows do out[k] = rows[k] end
	out[y] = string.sub(out[y], 1, x - 1) .. ch .. string.sub(out[y], x + #ch)
	return out
end

-- The level field: cells as 1-based {x, y}.
local function carpet(cells)
	local out = {}
	for k, c in ipairs(cells) do out[k] = { c[1] - 1, c[2] - 1 } end
	return out
end

-- every cell of the 6x6 board except the listed ones (1-based {x, y})
local function all_but(cells)
	local skip = {}
	for _, c in ipairs(cells) do skip[c[1] .. "," .. c[2]] = true end
	local out = {}
	for y = 1, 6 do
		for x = 1, 6 do
			if not skip[x .. "," .. y] then out[#out + 1] = { x, y } end
		end
	end
	return out
end

-- A live board from a picture with the carpet under `cells`.
local function fresh(rows, cells, extra, opts)
	extra = extra or {}
	extra.carpet = carpet(cells)
	extra.goals = extra.goals or GOAL
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

local function on(g, x, y) return g.s.carpet[idx(x, y)] end

-- the covered cells as a sorted list of "x,y"
local function covered(g)
	local out = {}
	for i = 1, g.s.N do
		if g.s.carpet[i] then out[#out + 1] = ((i - 1) % 6 + 1) .. "," .. math.floor((i - 1) / 6 + 1) end
	end
	return out
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
	for _ = 1, 2000 do
		g:step()
		for _, e in ipairs(g:drain_events()) do all[#all + 1] = e end
		if g:is_stable() then break end
	end
	return all
end

describe("core carpet: level schema and rules (2.0, 2.1.13)", function()
	it("accepts the field with the goal; the goal counts the cells still to cover", function()
		local lvl = H.load(FULL, { carpet = carpet({ { 3, 4 }, { 2, 4 } }), goals = GOAL })
		assert_same(lvl.carpet.cells, { 20, 21 })
		assert_true(lvl.carpet.at[21] and not lvl.carpet.at[22])
		assert_same(lvl.goals, { { type = C.GOAL_CARPET, param = 0, count = 34 } })
		assert_eq(H.load(FULL).carpet, nil)
		-- voids are not counted: nothing to cover there
		local holed = H.load({ "######", "######", "##..##", "######", "######", "######" }, { carpet = carpet({ { 1, 1 } }), goals = GOAL })
		assert_eq(holed.goals[1].count, 33)
	end)

	it("checks the shape of the field and of the goal", function()
		expect(H.level(FULL, { carpet = {}, goals = GOAL }), "2.1.1 carpet: a non-empty list of [x, y] required")
		expect(H.level(FULL, { carpet = { cells = {} }, goals = GOAL }), "2.1.1 carpet: a non-empty list of [x, y] required")
		expect(H.level(FULL, { carpet = { { 1 } }, goals = GOAL }), "2.1.1 carpet[1]: [x, y] required")
		expect(H.level(FULL, { carpet = { { 1, 1 } }, goals = { { type = "carpet", count = 5 } } }), "2.1.1 goals[1]: unknown key 'count'")
		expect(H.level(FULL, { carpet = { { 1, 1 } }, goals = { { type = "carpet" }, { type = "carpet" } } }), "2.1.1 goals[2]: repeated goal")
	end)

	it("2.1.2: on existing cells, one carpet a cell", function()
		expect(H.level({ "######", "######", "##.###", "######", "######", "######" }, { carpet = carpet({ { 3, 3 } }), goals = GOAL }),
			"2.1.2 carpet is not on an existing cell at 2,2")
		expect(H.level(FULL, { carpet = carpet({ { 9, 3 } }), goals = GOAL }), "2.1.2 carpet is not on an existing cell at 8,2")
		expect(H.level(FULL, { carpet = carpet({ { 3, 3 }, { 3, 3 } }), goals = GOAL }), "2.1.2 two carpets in one cell at 2,2")
	end)

	it("2.1.13: the goal and the cells come together; no dance floor; no carpet under a starting blocker", function()
		expect(H.level(FULL, { goals = GOAL }), "2.1.13 carpet goal without starting carpet cells")
		expect(H.level(FULL, { carpet = carpet({ { 3, 3 } }) }), "2.1.13 carpet cells without a carpet goal")
		expect(H.level(FULL, { carpet = carpet({ { 3, 3 } }), goals = GOAL, floor = { { at = { 0, 5 }, hp = 1 } } }),
			"2.1.13 floor tiles on a carpet level")
		for _, ch in ipairs({ "X", "K", "N", "A" }) do
			expect(H.level(with(FULL, 3, 3, ch), { carpet = carpet({ { 3, 3 } }), goals = GOAL }), "2.1.13 starting carpet under a blocker at 2,2")
		end
		expect(H.level(FULL, { carpet = carpet({ { 4, 4 } }), goals = GOAL, slots = { { at = { 2, 2 }, type = "column", hp = 6 } } }),
			"2.1.13 starting carpet under a blocker at 3,3")
		-- a blocker elsewhere, a special or a `piece` on the carpet are fine
		assert_eq(errors_of(H.level(with(with(FULL, 3, 3, "S"), 5, 5, "X"), { carpet = carpet({ { 3, 3 }, { 1, 1 } }), goals = GOAL })), "")
		expect(H.level(FULL, { carpet = carpet(all_but({})), goals = GOAL }), "2.1.13 the carpet already covers the whole board")
	end)

	it("2.1.13: every cell must be coverable by matches alone, starting from the carpet", function()
		-- (1,1) has no line of three and no square through it: no match can ever stand on it
		local nub = { "##.###", ".#####", "######", "######", "######", "######" }
		expect(H.level(nub, { carpet = carpet({ { 3, 3 } }), goals = GOAL }), "2.1.13 the carpet cannot reach the cell at 0,0")
		-- ... and a carpet that starts only there can go nowhere
		local got = errors_of(H.level(nub, { carpet = carpet({ { 1, 1 } }), goals = GOAL }))
		assert_true(string.find(got, "2.1.13 the carpet cannot reach the cell at 1,0", 1, true) ~= nil, got)
		-- two halves joined by nothing: the far half is out of reach
		local split = { "###.###", "###.###", "###.###", "###.###", "###.###", "###.###" }
		local raw = H.level(split, { carpet = carpet({ { 1, 1 } }), goals = GOAL })
		expect(raw, "2.1.13 the carpet cannot reach the cell at 4,0")
		raw.carpet = carpet({ { 1, 1 }, { 7, 6 } })
		assert_eq(errors_of(raw), "")
	end)

	it("2.1.6: the carpet is one of the three elements a level may have", function()
		local three = { carpet = carpet({ { 1, 1 } }), goals = GOAL,
			slots = { { at = { 0, 3 }, type = "record_box", hp = 1 }, { at = { 5, 3 }, type = "concrete", hp = 1 } } }
		assert_eq(errors_of(H.level(FULL, three)), "")
		three.slots[3] = { at = { 3, 3 }, type = "noise" }
		expect(H.level(FULL, three), "2.1.6 more than three different elements")
	end)

	it("the field is part of the canonical form, so of the level hash", function()
		local a = H.load(FULL, { carpet = carpet({ { 3, 3 } }), goals = GOAL })
		local b = H.load(FULL, { carpet = carpet({ { 3, 4 } }), goals = GOAL })
		assert_true(a.hash ~= b.hash)
		assert_true(string.find(a.canonical, '"carpet":[[2,2]]', 1, true) ~= nil)
	end)
end)

describe("core carpet: a match that stands on the carpet rolls it out (10.8)", function()
	it("starts with the cells of the level; cells() and the goal say so; other levels say nothing", function()
		local g = fresh(PA, { { 1, 6 }, { 4, 2 } })
		assert_same(covered(g), { "4,2", "1,6" })
		local cells = g:cells()
		assert_true(cells[31].carpet == true and cells[10].carpet == true and cells[32].carpet == nil)
		assert_same(g:status().goals, { 34 })
		local plain = H.game(FULL)
		assert_eq(plain.s.carpet, false)
		assert_eq(plain:cells()[31].carpet, nil)
	end)

	it("one cell of the group on the carpet: the carpet goes under the whole group, 50 points a new cell", function()
		local g = fresh(PA, { { 1, 6 } })
		local ev = first_wave(g, MOVE)
		assert_same(xy_list(H.of_type(ev, "carpet")), { "2,6", "3,6" })
		assert_true(on(g, 1, 6) and on(g, 2, 6) and on(g, 3, 6))
		assert_same(g:status().goals, { 33 })
		-- one score event a hit: 20 x wave for the piece, +50 where the carpet is new
		local deltas = {}
		for _, e in ipairs(H.of_type(ev, "score")) do deltas[#deltas + 1] = e.x .. "," .. e.y .. "=" .. e.delta end
		assert_same(deltas, { "1,6=20", "2,6=70", "3,6=70" })
		-- causal order of one hit: carpet -> clear -> score -> goal
		local order = {}
		for _, e in ipairs(ev) do
			if (e.x == 2 and e.y == 6) or e.type == "goal" then order[#order + 1] = e.type end
		end
		assert_same(order, { "carpet", "clear", "score", "goal", "goal" })
		local goals = H.of_type(ev, "goal")
		assert_same({ goals[1].index, goals[1].left, goals[2].left }, { 1, 34, 33 })
	end)

	it("the carpet may be under any cell of the group, also the far end", function()
		local g = fresh(PA, { { 3, 6 } })
		local ev = first_wave(g, MOVE)
		assert_same(xy_list(H.of_type(ev, "carpet")), { "1,6", "2,6" })
	end)

	it("a group that does not touch the carpet spreads nothing, even right next to it", function()
		local g = fresh(PA, { { 4, 6 }, { 1, 5 }, { 2, 5 } })
		local ev = first_wave(g, MOVE)
		assert_eq(#H.of_type(ev, "carpet"), 0)
		assert_same(covered(g), { "1,5", "2,5", "4,6" })
		assert_same(g:status().goals, { 33 })
	end)

	it("a group wholly on the carpet changes nothing and scores no carpet points", function()
		local g = fresh(PA, { { 1, 6 }, { 2, 6 }, { 3, 6 } })
		local ev = first_wave(g, MOVE)
		assert_eq(#H.of_type(ev, "carpet"), 0)
		assert_eq(#H.of_type(ev, "goal"), 0)
		assert_eq(H.of_type(ev, "score")[2].delta, 20)
	end)

	it("the adjacent hits of the group lay nothing: a neighbour stays bare", function()
		local g = fresh(PA, { { 1, 6 } })
		first_wave(g, MOVE)
		assert_false(on(g, 4, 6))
		assert_false(on(g, 1, 5))
	end)

	it("a wired piece and a chained piece are cells of the group like any other", function()
		local g = fresh(PA, { { 3, 6 } }, { overlay = { { at = { 1, 5 }, type = "wires", hp = 1 } } })
		H.obj_at(g, 1, 6).chain = 1
		local ev = first_wave(g, MOVE)
		assert_same(xy_list(H.of_type(ev, "carpet")), { "1,6", "2,6" })
		-- both pieces are still there: the match took the chain and the wires, the carpet went under them
		assert_eq(H.obj_at(g, 1, 6).chain, 0)
		assert_eq(H.obj_at(g, 1, 6).state, C.S_IDLE)
		assert_eq(g.s.wires[idx(2, 6)], 0)
		assert_eq(H.obj_at(g, 2, 6).state, C.S_IDLE)
	end)
end)

describe("core carpet: effects carry it from the cell they start on (10.8)", function()
	it("a Riff on the carpet rolls it along its whole row; a Riff off the carpet lays nothing", function()
		local g = fresh(with(P0, 3, 3, "R"), { { 3, 3 } })
		assert_true(g:input({ type = "tap", at = { 3, 3 } }))
		local ev = H.steps(g, 9)
		assert_same(xy_list(H.of_type(ev, "carpet")), { "2,3", "4,3", "1,3", "5,3", "6,3" })
		assert_same(covered(g), { "1,3", "2,3", "3,3", "4,3", "5,3", "6,3" })
		local bare = fresh(with(P0, 3, 3, "R"), { { 3, 4 }, { 1, 6 } })
		assert_true(bare:input({ type = "tap", at = { 3, 3 } }))
		assert_eq(#H.of_type(H.steps(bare, 9), "carpet"), 0)
	end)

	it("a special swapped onto the carpet fires from there", function()
		-- the Riff h stands off the carpet; the player swaps it down onto the covered cell
		local g = fresh(with(P0, 3, 3, "R"), { { 3, 4 } })
		assert_true(g:input({ type = "swap", from = { 3, 3 }, to = { 3, 4 } }))
		H.steps(g, 19)
		for x = 1, 6 do assert_true(on(g, x, 4), "x " .. x) end
		assert_false(on(g, 1, 3))
	end)

	it("an intact blocker is a wall: the hit that breaks it does not cover its cell, a later one does", function()
		local g = fresh(with(with(P0, 3, 3, "R"), 5, 3, "X"), { { 3, 3 } })
		assert_true(g:input({ type = "tap", at = { 3, 3 } }))
		H.steps(g, 9)
		assert_same(covered(g), { "1,3", "2,3", "3,3", "4,3", "6,3" })
		assert_eq(H.obj_at(g, 5, 3).state, C.S_CLEAR) -- the box is broken by this very hit
		rest(g)
		assert_false(on(g, 5, 3))
		-- the spotlight over a row that has the carpet rolls it out along the row: now the cell is free
		assert_true(g:input({ type = "booster", booster = "row_light", row = 3 }))
		H.steps(g, 8)
		assert_true(on(g, 5, 3))
	end)

	it("a blocker that survives the hit keeps its cell bare, and so does every cell of a column", function()
		local rows = with(with(with(P0, 3, 3, "R"), 5, 3, "K"), 1, 3, "L")
		rows = with(with(with(rows, 2, 3, "l"), 1, 4, "l"), 2, 4, "l")
		local g = fresh(rows, { { 3, 3 } })
		H.obj_at(g, 5, 3).hp = 2
		assert_true(g:input({ type = "tap", at = { 3, 3 } }))
		H.steps(g, 9)
		assert_same(covered(g), { "3,3", "4,3", "6,3" })
	end)

	it("a chain reaction: the hit covers the cell of the next special, so that one carries the carpet too", function()
		local g = fresh(with(with(P0, 3, 3, "R"), 5, 3, "V"), { { 3, 3 } })
		assert_true(g:input({ type = "tap", at = { 3, 3 } }))
		H.steps(g, 16)
		for y = 1, 6 do assert_true(on(g, 5, y), "y " .. y) end
		-- ... while a special that fires a covered special from a bare cell spreads nothing itself
		local b = fresh(with(with(P0, 3, 3, "R"), 5, 3, "V"), { { 5, 3 } })
		assert_true(b:input({ type = "tap", at = { 3, 3 } }))
		H.steps(b, 16)
		assert_false(on(b, 1, 3))
		for y = 1, 6 do assert_true(on(b, 5, y), "y " .. y) end
	end)

	it("a combo carries the carpet if either of its two specials stood on it", function()
		local g = fresh(with(P0, 3, 3, "RR"), { { 3, 3 } })
		assert_true(g:input({ type = "swap", from = { 3, 3 }, to = { 4, 3 } }))
		H.steps(g, 18)
		for x = 1, 6 do assert_true(on(g, x, 3), "x " .. x) end
		for y = 1, 6 do assert_true(on(g, 4, y), "y " .. y) end
		local bare = fresh(with(P0, 3, 3, "RR"), { { 1, 6 } })
		assert_true(bare:input({ type = "swap", from = { 3, 3 }, to = { 4, 3 } }))
		assert_eq(#H.of_type(H.steps(bare, 18), "carpet"), 0)
	end)

	it("a Disco ball on the carpet covers every piece of its colour", function()
		local g = fresh(with(P0, 3, 3, "D"), { { 3, 3 } })
		assert_true(g:input({ type = "tap", at = { 3, 3 } }))
		local ev = rest(g)
		local rays = H.of_type(ev, "disco_ray")
		assert_true(#rays >= 5)
		for _, r in ipairs(rays) do assert_true(on(g, r.tx, r.ty), r.tx .. "," .. r.ty) end
	end)

	it("a Bird that carries the carpet flies to a bare cell and covers it", function()
		local g = fresh(with(P0, 3, 3, "B"), all_but({ { 6, 6 }, { 5, 6 } }))
		assert_true(g:input({ type = "tap", at = { 3, 3 } }))
		local ev = H.steps(g, 1)
		local fly = H.of_type(ev, "bird_fly")[1]
		assert_true(fly.ty == 6 and (fly.tx == 5 or fly.tx == 6))
		H.steps(g, 40)
		assert_true(on(g, fly.tx, fly.ty))
		-- the table of section 9: for a carrying source a bare cell is a goal cell, for any other it is not
		local s = fresh(P0, all_but({ { 6, 6 } })).s
		assert_eq(BD.levels(s, { carpet = true })[36], 4)
		assert_eq(BD.levels(s, { carpet = false })[36], 1)
		assert_eq(BD.levels(s)[36], 1)
		assert_eq(BD.levels(s, { carpet = true })[35], 1)
	end)

	it("a Bird off the carpet lays nothing with its cross", function()
		local g = fresh(with(P0, 3, 3, "B"), { { 1, 6 } })
		assert_true(g:input({ type = "tap", at = { 3, 3 } }))
		assert_eq(#H.of_type(H.steps(g, 1), "carpet"), 0)
	end)

	it("a closed curtain keeps the carpet out like every other hit", function()
		local g = fresh(with(P0, 3, 3, "R"), { { 3, 3 } },
			{ curtain = { covers = { { 4, 2 } }, closed_moves = 3, open_moves = 2, start = "closed" } })
		assert_true(g:input({ type = "tap", at = { 3, 3 } }))
		H.steps(g, 9)
		assert_same(covered(g), { "1,3", "2,3", "3,3", "4,3", "6,3" })
	end)
end)

describe("core carpet: boosters (10.8)", function()
	it("the stick never spreads; a spotlight does when its row or column has the carpet", function()
		local g = fresh(P0, { { 2, 3 } })
		assert_true(g:input({ type = "booster", booster = "stick", at = { 3, 3 } }))
		assert_eq(#H.of_type(H.steps(g, 3), "carpet"), 0)
		assert_same(covered(g), { "2,3" })
		local r = fresh(P0, { { 2, 3 } })
		assert_true(r:input({ type = "booster", booster = "row_light", row = 3 }))
		H.steps(r, 8)
		for x = 1, 6 do assert_true(on(r, x, 3), "x " .. x) end
		local c = fresh(P0, { { 2, 3 } })
		assert_true(c:input({ type = "booster", booster = "col_light", col = 2 }))
		H.steps(c, 8)
		for y = 1, 6 do assert_true(on(c, 2, y), "y " .. y) end
		local bare = fresh(P0, { { 2, 3 } })
		assert_true(bare:input({ type = "booster", booster = "col_light", col = 5 }))
		assert_eq(#H.of_type(H.steps(bare, 8), "carpet"), 0)
	end)
end)

describe("core carpet: the goal (10.8)", function()
	it("the last cell wins the level", function()
		local g = fresh(PA, all_but({ { 2, 6 }, { 3, 6 } }))
		assert_same(g:status().goals, { 2 })
		local ev = first_wave(g, MOVE)
		local goals = H.of_type(ev, "goal")
		assert_same({ goals[1].left, goals[2].left }, { 1, 0 })
		assert_eq(g:status().state, "won_wait")
		assert_eq(H.of_type(ev, "state")[1].state, "won_wait")
		for _ = 1, 5000 do
			if g:status().state == "complete" then break end
			g:step()
		end
		assert_eq(g:status().state, "complete")
		assert_same(g:status().goals, { 0 })
		assert_eq(#covered(g), 36)
	end)

	it("never shrinks, and the goal is always the number of bare cells", function()
		local lvl = H.load(with(with(FULL, 2, 2, "X"), 5, 4, "N"), { carpet = carpet({ { 3, 3 }, { 4, 3 }, { 3, 4 } }), goals = GOAL, moves = 40 })
		for seed = 1, 4 do
			local g = core.new(lvl, { seed = seed })
			local was = {}
			for _ = 1, 40 do
				if g:status().state ~= "playing" then break end
				local h = g:hint()
				if not h then break end
				if h.at then g:input({ type = "tap", at = h.at }) else g:input({ type = "swap", from = h.from, to = h.to }) end
				g:run_to_rest()
				local bare = 0
				for i = 1, g.s.N do
					if was[i] then assert_true(g.s.carpet[i], "cell " .. i .. " lost its carpet") end
					was[i] = g.s.carpet[i]
					if not g.s.carpet[i] then bare = bare + 1 end
				end
				assert_eq(g:status().goals[1], bare)
			end
			assert_true(g:status().goals[1] < 33, "seed " .. seed .. ": the hint spreads the carpet")
		end
	end)
end)

describe("core carpet: the hint (12.3)", function()
	-- a second move in the top row: (4,1) -> (3,1) makes an orange line (1,1) (2,1) (3,1)
	local TWO = with(with(with(PA, 1, 1, "o"), 2, 1, "o"), 4, 1, "o")

	it("prefers the move that rolls the carpet out", function()
		-- without a reason the hint takes the first pair: the top one
		assert_same(fresh(TWO, { { 6, 3 } }):hint(), { from = { 3, 1 }, to = { 4, 1 } })
		assert_same(fresh(TWO, { { 1, 6 } }):hint(), { from = { 3, 5 }, to = { 3, 6 } })
		assert_same(fresh(TWO, { { 2, 1 }, { 6, 3 } }):hint(), { from = { 3, 1 }, to = { 4, 1 } })
	end)

	it("a group wholly on the carpet is no progress", function()
		assert_same(fresh(TWO, { { 1, 1 }, { 2, 1 }, { 3, 1 }, { 2, 6 } }):hint(), { from = { 3, 5 }, to = { 3, 6 } })
	end)
end)

describe("core carpet: determinism and the hash (17.2)", function()
	local function level()
		return H.load(with(FULL, 2, 2, "X"), { carpet = carpet({ { 3, 3 }, { 4, 3 }, { 3, 4 } }), goals = GOAL, moves = 30 })
	end

	local function play(g, n)
		local log = {}
		for _ = 1, n do
			if g:status().state ~= "playing" then break end
			local h = g:hint()
			if not h then break end
			if h.at then g:input({ type = "tap", at = h.at }) else g:input({ type = "swap", from = h.from, to = h.to }) end
			g:run_to_rest()
			log[#log + 1] = g:hash() .. ":" .. g:status().goals[1]
		end
		return log
	end

	it("the same seed and commands give the same game; a clone goes the same way; the replay plays back", function()
		local lvl = level()
		local a = core.new(lvl, { seed = 7 })
		local b = core.new(lvl, { seed = 7 })
		local la = play(a, 6)
		local c = a:clone()
		assert_eq(c:hash(), a:hash())
		assert_same(play(b, 6), la)
		assert_same(play(a, 10), play(c, 10))
		assert_eq(a:hash(), c:hash())
		local _, ok, why = core.playback(lvl, a:replay())
		assert_true(ok, why)
		local t = core.new(lvl, { seed = 7, timing = "turbo" })
		assert_true(#play(t, 12) >= 5)
	end)

	it("the hash sees the carpet, and the flag of a source that carries it", function()
		local g = fresh(with(P0, 3, 3, "R"), { { 3, 3 } })
		local c = g:clone()
		c.s.carpet[1] = true
		assert_true(g:hash() ~= c:hash())
		-- mid-flight: the Riff's source is alive and carries the carpet
		assert_true(g:input({ type = "tap", at = { 3, 3 } }))
		H.steps(g, 2)
		local d = g:clone()
		local any = false
		for _, src in pairs(d.s.sources) do
			if src.carpet then
				src.carpet = false
				any = true
			end
		end
		assert_true(any)
		assert_true(g:hash() ~= d:hash())
	end)

	it("a level without the carpet hashes as before: nothing of it is in the state", function()
		local g = H.game(FULL)
		local h = g:hash()
		assert_eq(g.s.carpet, false)
		-- the flag of a source alone does not reach the hash there
		g.s.sources[99] = { id = 99, kind = 3, mv = 0, wv = 0, color = 0, all_layers = false, own = {}, centre = 0,
			keys = {}, reserves = {}, nrec = 0, carpet = false }
		local h1 = g:hash()
		g.s.sources[99].carpet = true
		assert_eq(g:hash(), h1)
		g.s.sources[99] = nil
		assert_eq(g:hash(), h)
	end)
end)
