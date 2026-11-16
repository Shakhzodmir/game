-- The boombox (10.10): a blocker with the hit rules of a record box that answers an adjacent match by
-- clearing free pieces of the colour of that match elsewhere on the board.

local core = require("core.game")
local C = require("core.const")
local BX = require("core.boombox")
local MT = require("core.match")
local R = require("core.rng")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- a ready purple line (1,6) (2,6) (3,6) next to the boombox in (4,6); four more purples: cells 1, 5, 15, 24
local PA = { "pyrgpy", "yrgbyr", "rgpyrg", "gbyrgp", "bygoby", "pppQyr" }
local PURPLES = { { 1, 1 }, { 5, 1 }, { 3, 3 }, { 6, 4 } }
local LINE = { [31] = true, [32] = true, [33] = true }

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

-- A live board from a picture; every boombox and record box of the picture gets `hp`.
local function fresh(rows, hp, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or PA)
	for i = 1, g.s.N do
		local o = g.s.objs[g.s.slot[i]]
		if o and o.kind == C.K_BLOCKER and (o.blocker == C.BK_BOOMBOX or o.blocker == C.BK_BOX) then o.hp = hp or 1 end
	end
	g:drain_events()
	return g
end

-- One tick with a search of the whole board (step 7); the events of the tick.
local function search(g)
	g.s.dirty = true
	g:step()
	return g:drain_events()
end

local function rest(g, max)
	local all = {}
	for _ = 1, max or 900 do
		g:step()
		for _, e in ipairs(g:drain_events()) do all[#all + 1] = e end
		if g:is_stable() then break end
	end
	return all
end

-- The next three outputs of stream k of the game, without spending them.
local function peek(g, k)
	local c = g:clone()
	local st = c.s.rng[k]
	return { R.next_int(st), R.next_int(st), R.next_int(st) }
end

local function effect_clears(ev)
	local out = {}
	for _, e in ipairs(H.of_type(ev, "clear")) do
		if e.cause == "effect" then out[#out + 1] = { e.x, e.y } end
	end
	return out
end

local function types_of(ev, set)
	local out = {}
	for _, e in ipairs(ev) do
		if set[e.type] then out[#out + 1] = e.type end
	end
	return out
end

local function no_sources(g)
	local n = 0
	for id = 1, g.s.next_source_id do
		if g.s.sources[id] then n = n + 1 end
	end
	return n == 0
end

describe("core boombox: level schema and rules (2.0, 2.1)", function()
	local function box(x, y, hp) return { at = { x, y }, type = "boombox", hp = hp } end

	it("accepts hp 1..3 and counts the objects for the break goal", function()
		for hp = 1, 3 do
			local lvl = H.load(FULL, { slots = { box(2, 2, hp), box(3, 4, 1) },
				goals = { { type = "break", item = "boombox", count = 2 } } })
			assert_eq(lvl.goals[1].param, C.BK_BOOMBOX)
		end
		expect(H.level(FULL, { slots = { box(2, 2, 0) } }), "slots[1]: bad or missing hp")
		expect(H.level(FULL, { slots = { box(2, 2, 4) } }), "slots[1]: bad or missing hp")
		expect(H.level(FULL, { slots = { { at = { 2, 2 }, type = "boombox" } } }), "slots[1]: bad or missing hp")
		expect(H.level(FULL, { slots = { { at = { 2, 2 }, type = "boombox", hp = 1, color = "red" } } }), "unknown key 'color'")
		expect(H.level(FULL, { slots = { box(2, 2, 1) }, goals = { { type = "break", item = "boombox", count = 2 } } }),
			"2.1.5 break count exceeds the boombox objects on the board")
		expect(H.level(FULL, { goals = { { type = "break", item = "jukebox", count = 1 } } }),
			"2.1.5 break item must be record_box, concrete, noise, balloon, column, boombox or hay")
	end)

	it("2.1.6: the boombox is one of the three element kinds of a level", function()
		local three = { box(2, 2, 1), { at = { 0, 3 }, type = "record_box", hp = 1 }, { at = { 5, 3 }, type = "noise" } }
		assert_eq(errors_of(H.level(FULL, { slots = three })), "")
		three[4] = { at = { 3, 4 }, type = "concrete", hp = 1 }
		expect(H.level(FULL, { slots = three }), "2.1.6 more than three different elements")
	end)

	it("2.1.12-2.1.14: not under a curtain, not under the starting carpet, not on a belt", function()
		expect(H.level(FULL, { slots = { box(2, 2, 1) },
			curtain = { covers = { { 2, 2 } }, closed_moves = 2, open_moves = 2, start = "closed" } }),
			"2.1.12 only a regular piece may stand under a curtain at 2,2")
		expect(H.level(FULL, { slots = { box(2, 2, 1) }, carpet = { { 2, 2 } }, goals = { { type = "carpet" } } }), "2.1.13")
		expect(H.level(FULL, { slots = { box(2, 2, 1) }, conveyor = { { path = { { 1, 2 }, { 2, 2 }, { 3, 2 } } } } }),
			"2.1.14 blocker on a conveyor at 2,2")
	end)
end)

describe("core boombox: damage (7.3), the same as a record box", function()
	-- the same scenario with a record box and with a boombox: hp, blocker events and the goal must agree
	local function trail(ch, hp, act)
		local item = ch == "X" and "record_box" or "boombox"
		local g = fresh(with(PA, 4, 6, ch), hp, { goals = { { type = "break", item = item, count = 1 },
			{ type = "collect", color = "red", count = 999 } }, slots = { { at = { 3, 5 }, type = item, hp = 1 } } })
		local ev = act(g)
		local out = {}
		for _, e in ipairs(ev) do
			if (e.type == "hit" and e.layer == "blocker") or e.type == "destroy" then
				out[#out + 1] = { e.type, e.x, e.y, e.hp or -1 }
			end
		end
		local o = H.obj_at(g, 4, 6)
		return out, (o and o.kind == C.K_BLOCKER and o.state == C.S_IDLE) and o.hp or 0, g:status().goals[1]
	end
	local function same(hp, act)
		local a, ahp, agoal = trail("X", hp, act)
		local b, bhp, bgoal = trail("Q", hp, act)
		assert_same(b, a)
		assert_eq(bhp, ahp)
		assert_eq(bgoal, agoal)
		return b, bhp
	end
	local function stick(g)
		assert_true(g:input({ type = "booster", booster = "stick", at = { 4, 6 } }))
		g:step()
		return g:drain_events()
	end

	it("an adjacent match takes one hp", function()
		local ev, hp = same(3, search)
		assert_same(ev, { { "hit", 4, 6, 2 } })
		assert_eq(hp, 2)
		ev, hp = same(1, search)
		assert_same(ev, { { "destroy", 4, 6, -1 } })
		assert_eq(hp, 0)
	end)

	it("a booster or a special takes one hp", function()
		local ev, hp = same(2, stick)
		assert_same(ev, { { "hit", 4, 6, 1 } })
		assert_eq(hp, 1)
		ev = same(1, stick)
		assert_same(ev, { { "destroy", 4, 6, -1 } })
		same(3, function(g)
			assert_true(g:input({ type = "booster", booster = "row_light", row = 6 }))
			return rest(g, 30)
		end)
	end)

	it("a match that is not adjacent does nothing to it", function()
		-- the line stands in row 1: (1,1) (2,1) (3,1)
		local rows = { "pppgby", "yrgbyr", "rgbyrg", "gbyrgb", "bygoby", "oyrQyr" }
		for _, ch in ipairs({ "X", "Q" }) do
			local g = fresh(with(rows, 4, 6, ch), 2)
			local ev = search(g)
			assert_eq(#H.of_type(ev, "match"), 1)
			assert_eq(H.obj_at(g, 4, 6).hp, 2)
			assert_eq(#H.of_type(ev, "boombox"), 0)
		end
	end)
end)

describe("core boombox: the blast (10.10)", function()
	it("a hit of an adjacent match clears BLAST pieces of the colour, as effect hits, after the adjacent hits", function()
		local g = fresh(PA, 2, { goals = { { type = "collect", color = "purple", count = 50 } } })
		local src0 = g.s.next_source_id
		local ev = search(g)
		local bb = H.of_type(ev, "boombox")
		assert_eq(#bb, 1)
		assert_same({ bb[1].x, bb[1].y, bb[1].color }, { 4, 6, "purple" })
		assert_eq(bb[1].last, nil)
		assert_eq(#bb[1].cells, C.BLAST)
		assert_same(effect_clears(ev), bb[1].cells)
		-- every target is one of the four free purples, ascending by cell
		local ok = {}
		for _, c in ipairs(PURPLES) do ok[c[1] .. "," .. c[2]] = true end
		local prev = 0
		for _, c in ipairs(bb[1].cells) do
			assert_true(ok[c[1] .. "," .. c[2]])
			local i = (c[2] - 1) * 6 + c[1]
			assert_true(i > prev)
			prev = i
			assert_eq(H.obj_at(g, c[1], c[2]).state, C.S_CLEAR)
		end
		-- order of the events: the match, the hit of the boombox, the play, then its clears
		assert_same(types_of(ev, { match = true, boombox = true, hit = true }), { "match", "hit", "boombox" })
		local seen_bb, after = false, 0
		for _, e in ipairs(ev) do
			if e.type == "boombox" then seen_bb = true
			elseif seen_bb and e.type == "clear" then after = after + 1 end
		end
		assert_eq(after, C.BLAST)
		-- score: 3 group cells x 20, 50 for the hp, 30 per blasted piece; the collect goal counts 3 + 3
		assert_eq(g:status().score, 3 * 20 + 50 + C.BLAST * 30)
		assert_eq(g:status().goals[1], 50 - 3 - C.BLAST)
		-- sources: match, adjacent and the one of the play; none is left alive
		assert_eq(g.s.next_source_id, src0 + 3)
		assert_true(no_sources(g))
	end)

	it("the hit that destroys the boombox plays the bigger last blast", function()
		local g = fresh(with(PA, 2, 2, "p"), 1, { goals = { { type = "break", item = "boombox", count = 1 },
			{ type = "collect", color = "purple", count = 50 } }, slots = { { at = { 0, 0 }, type = "boombox", hp = 1 } } })
		local ev = search(g)
		local bb = H.of_type(ev, "boombox")
		assert_eq(#bb, 1)
		assert_true(bb[1].last)
		assert_eq(#bb[1].cells, C.BLAST_LAST) -- five free purples now
		assert_eq(#H.of_type(ev, "destroy"), 1)
		assert_eq(g:status().goals[1], 0)
		assert_eq(g:status().goals[2], 50 - 3 - 5)
		assert_same(types_of(ev, { destroy = true, boombox = true }), { "destroy", "boombox" })
	end)

	it("fewer candidates, fewer cleared; none, nothing drawn", function()
		local g = fresh(PA, 1)
		local ev = search(g)
		assert_eq(#H.of_type(ev, "boombox")[1].cells, 4)
		assert_same(effect_clears(ev), PURPLES)
		-- no purple outside the group: the play happens, clears nothing and draws nothing
		g = fresh({ "oyrgoy", "yrgbyr", "rgoyrg", "gbyrgo", "bygoby", "pppQyr" }, 2)
		local before = peek(g, 3)
		g.s.dirty = true
		MT.search(g.s)
		ev = g:drain_events()
		assert_eq(#H.of_type(ev, "boombox"), 1)
		assert_eq(#H.of_type(ev, "boombox")[1].cells, 0)
		assert_eq(#effect_clears(ev), 0)
		assert_same(peek(g, 3), before)
	end)

	it("one draw of the effects stream per target and no other stream", function()
		local g = fresh(PA, 2)
		local twin = g:clone()
		for _ = 1, C.BLAST do R.next_int(twin.s.rng[3]) end
		local b1, b2, b4 = peek(g, 1), peek(g, 2), peek(g, 4)
		g.s.dirty = true
		MT.search(g.s) -- only the search: steps 5-6 of a tick would spend the spawn stream
		assert_same(peek(g, 3), peek(twin, 3))
		assert_same(peek(g, 1), b1)
		assert_same(peek(g, 2), b2)
		assert_same(peek(g, 4), b4)
	end)

	it("a special or a booster has no colour: nothing is played, nothing is drawn", function()
		local g = fresh(with(PA, 1, 6, "o"), 2) -- no ready match
		local before = peek(g, 3)
		assert_true(g:input({ type = "booster", booster = "stick", at = { 4, 6 } }))
		g:step()
		local ev = g:drain_events()
		assert_eq(H.obj_at(g, 4, 6).hp, 1)
		assert_eq(#H.of_type(ev, "boombox"), 0)
		assert_eq(#H.of_type(ev, "clear"), 0)
		assert_same(peek(g, 3), before)
		-- a Riff next to it: its bolt breaks the last hp, still nothing is played
		g = fresh(with(with(PA, 1, 6, "o"), 5, 6, "R"), 1)
		before = peek(g, 3)
		assert_true(g:input({ type = "tap", at = { 5, 6 } }))
		ev = rest(g, 8)
		assert_eq(#H.of_type(ev, "destroy"), 1)
		assert_eq(#H.of_type(ev, "boombox"), 0)
		assert_same(peek(g, 3), before)
	end)

	it("several boomboxes hit by one match each play, in the order of their cells", function()
		-- boomboxes in (2,5), above the line, and in (4,6)
		local g = fresh(with(PA, 2, 5, "Q"), 2)
		local ev = search(g)
		local bb = H.of_type(ev, "boombox")
		assert_eq(#bb, 2)
		assert_same({ bb[1].x, bb[1].y, bb[2].x, bb[2].y }, { 2, 5, 4, 6 })
		assert_eq(#bb[1].cells, 3)
		assert_eq(#bb[2].cells, 1) -- four free purples in all: the second one gets what is left
		assert_eq(#effect_clears(ev), 4)
		-- both took their hits before the first one played
		assert_same(types_of(ev, { boombox = true, hit = true }), { "hit", "hit", "boombox", "boombox" })
	end)

	it("one boombox between two groups of different colours plays once per hp lost", function()
		local rows = { "pyrgpy", "yrgbyr", "rgpyrg", "gbyryp", "bygoyy", "pppQyr" }
		local g = fresh(rows, 3)
		local ev = search(g)
		local bb = H.of_type(ev, "boombox")
		assert_eq(#bb, 2)
		-- the yellow column (5,4)-(5,6) has the smaller first cell: it resolves first
		assert_same({ bb[1].color, bb[2].color }, { "yellow", "purple" })
		assert_eq(H.obj_at(g, 4, 6).hp, 1)
		for _, c in ipairs(bb[1].cells) do assert_eq(H.obj_at(g, c[1], c[2]).color, C.COLOR.yellow) end
		for _, c in ipairs(bb[2].cells) do assert_eq(H.obj_at(g, c[1], c[2]).color, C.COLOR.purple) end
		assert_same(types_of(ev, { match = true, boombox = true }), { "match", "boombox", "match", "boombox" })
		-- hp 2: the second group destroys it and plays the last blast
		g = fresh(rows, 2)
		bb = H.of_type(search(g), "boombox")
		assert_eq(bb[1].last, nil)
		assert_true(bb[2].last)
		-- hp 1: the first group destroys it; the second group finds an open slot and nothing plays
		g = fresh(rows, 1)
		bb = H.of_type(search(g), "boombox")
		assert_eq(#bb, 1)
		assert_eq(bb[1].color, "yellow")
		assert_true(bb[1].last)
	end)

	it("never blasts a piece of another match of the same search", function()
		-- the group next to the boombox is in row 1 and resolves first; a second purple line waits in row 6
		local rows = { "pppQby", "yrgbyr", "rgbyrg", "gbyrgb", "bygoby", "oyrppp" }
		local g = fresh(rows, 1)
		local ev = search(g)
		local bb = H.of_type(ev, "boombox")
		assert_eq(#bb, 1)
		assert_eq(#bb[1].cells, 0)
		assert_eq(#effect_clears(ev), 0)
		assert_eq(#H.of_type(ev, "match"), 2)
		assert_eq(#H.of_type(ev, "clear"), 6)
	end)

	it("candidates: free idle pieces of the colour only", function()
		local g = fresh(PA, 2, { curtain = { covers = { { 2, 2 } }, closed_moves = 5, open_moves = 2, start = "closed" } })
		H.obj_at(g, 5, 1).chain = 1 -- chained
		g.s.wires[1] = 1 -- (1,1) under wires
		assert_true(g.s.cur_closed) -- (3,3) under a closed curtain
		assert_same(BX.candidates(g.s, C.COLOR.purple, {}), { 24, 31, 32, 33 })
		assert_same(BX.candidates(g.s, C.COLOR.purple, LINE), { 24 })
		H.obj_at(g, 6, 4).pins = { 7 } -- pinned by a running effect
		assert_same(BX.candidates(g.s, C.COLOR.purple, LINE), {})
		H.obj_at(g, 6, 4).pins = {}
		H.obj_at(g, 6, 4).state = C.S_FALL
		assert_same(BX.candidates(g.s, C.COLOR.purple, LINE), {})
		H.obj_at(g, 6, 4).state = C.S_IDLE
		g.s.dirty = true
		MT.search(g.s)
		local ev = g:drain_events()
		assert_same(H.of_type(ev, "boombox")[1].cells, { { 6, 4 } })
		assert_eq(H.obj_at(g, 5, 1).chain, 1)
		assert_eq(H.obj_at(g, 5, 1).state, C.S_IDLE)
		assert_eq(g.s.wires[1], 1)
		assert_eq(H.obj_at(g, 3, 3).state, C.S_IDLE)
		-- the curtain opens: the piece under it is a candidate again
		g.s.cur_closed = false
		assert_same(BX.candidates(g.s, C.COLOR.purple, {}), { 15 })
	end)

	it("lights the floor tile under a blasted piece and never carries the carpet", function()
		local g = fresh(PA, 1, { floor = { { at = { 0, 0 }, hp = 1 }, { at = { 4, 0 }, hp = 2 } },
			goals = { { type = "light" } } })
		local ev = search(g)
		assert_eq(g.s.floor[1], 0)
		assert_eq(g.s.floor[5], 1)
		assert_eq(#H.of_type(ev, "floor_lit"), 1)
		-- carpet: the group stands on it and spreads it under itself; the blasted cells and the boombox cell stay bare
		g = fresh(PA, 1, { carpet = { { 0, 5 } }, goals = { { type = "carpet" } } })
		ev = search(g)
		assert_eq(#effect_clears(ev), 4)
		local laid = {}
		for _, e in ipairs(H.of_type(ev, "carpet")) do laid[#laid + 1] = { e.x, e.y } end
		assert_same(laid, { { 2, 6 }, { 3, 6 } })
		for _, c in ipairs(PURPLES) do assert_false(g.s.carpet[(c[2] - 1) * 6 + c[1]]) end
		assert_false(g.s.carpet[34])
	end)

	it("a blasted piece on a conveyor belt is cleared like any other", function()
		local g = fresh(PA, 2, { conveyor = { { path = { { 4, 0 }, { 5, 0 }, { 5, 1 }, { 4, 1 } } } } })
		-- the only free purple left rides the belt
		H.obj_at(g, 1, 1).color, H.obj_at(g, 3, 3).color, H.obj_at(g, 6, 4).color = 2, 2, 2
		local ev = search(g)
		assert_same(H.of_type(ev, "boombox")[1].cells, { { 5, 1 } })
		assert_eq(H.obj_at(g, 5, 1).state, C.S_CLEAR)
	end)

	it("the cascade after a blast runs to rest: the holes fill", function()
		local g = fresh(PA, 1)
		local ev = search(g)
		for _, e in ipairs(rest(g)) do ev[#ev + 1] = e end
		assert_true(g:is_stable())
		assert_true(#H.of_type(ev, "spawn") >= 3 + 4 + 1) -- the group, the blasted pieces, the boombox cell
		for i = 1, g.s.N do assert_true(g.s.slot[i] ~= 0) end
		assert_true(no_sources(g))
	end)

	it("the last goal met by the destroyed boombox wins; the last blast still plays", function()
		local g = fresh(PA, 1, { goals = { { type = "break", item = "boombox", count = 1 } },
			slots = { { at = { 0, 0 }, type = "boombox", hp = 1 } } })
		g.s.dirty = true
		MT.search(g.s)
		local ev = g:drain_events()
		assert_eq(g:status().state, "won_wait")
		assert_eq(#H.of_type(ev, "boombox")[1].cells, 4)
		assert_same(types_of(ev, { destroy = true, state = true, boombox = true }), { "destroy", "state", "boombox" })
	end)
end)

describe("core boombox: determinism", function()
	local LVL = { slots = { { at = { 3, 3 }, type = "boombox", hp = 3 }, { at = { 1, 4 }, type = "boombox", hp = 2 },
		{ at = { 4, 1 }, type = "boombox", hp = 3 } },
		colors = { "red", "yellow", "blue", "purple" }, moves = 30,
		goals = { { type = "break", item = "boombox", count = 3 } } }

	-- plays the first move of moves() until the level ends; returns the hash, the number of plays, the score
	local function run(seed)
		local g = H.game(FULL, LVL, { seed = seed, timing = "turbo" })
		local plays = 0
		for _ = 1, 30 do
			if g:status().state ~= "playing" then break end
			local mv = g:moves()[1]
			if not mv then break end
			g:input({ type = "swap", from = mv.from, to = mv.to })
			g:run_to_rest()
			for _, e in ipairs(g:drain_events()) do
				if e.type == "boombox" then plays = plays + 1 end
			end
		end
		return g:hash(), plays, g:status().score
	end

	it("the same seed gives the same game; the plays do happen", function()
		local total = 0
		for seed = 1, 6 do
			local h1, p1, s1 = run(seed)
			local h2, p2, s2 = run(seed)
			assert_eq(h1, h2)
			assert_eq(p1, p2)
			assert_eq(s1, s2)
			total = total + p1
		end
		assert_true(total > 0, "no boombox played in six games")
	end)

	it("a clone plays the same blast; another effects stream picks other targets", function()
		local g = fresh(PA, 2)
		local c = g:clone()
		local a, b = search(g), search(c)
		assert_same(H.of_type(a, "boombox")[1].cells, H.of_type(b, "boombox")[1].cells)
		assert_eq(g:hash(), c:hash())
		local seen, n = {}, 0
		for seed = 1, 12 do
			local cells = H.of_type(search(fresh(PA, 2, nil, { seed = seed })), "boombox")[1].cells
			local key = ""
			for _, cc in ipairs(cells) do key = key .. cc[1] .. cc[2] .. ";" end
			if not seen[key] then
				seen[key] = true
				n = n + 1
			end
		end
		assert_true(n >= 2, "twelve seeds chose the same three of four targets")
	end)
end)

describe("core boombox: levels without boomboxes", function()
	it("a record box in the same place spends no random number and creates no extra source", function()
		local g = fresh(with(PA, 4, 6, "X"), 2)
		local src0 = g.s.next_source_id
		local r1, r2, r3, r4 = peek(g, 1), peek(g, 2), peek(g, 3), peek(g, 4)
		g.s.dirty = true
		MT.search(g.s)
		local ev = g:drain_events()
		assert_eq(#H.of_type(ev, "boombox"), 0)
		assert_eq(#effect_clears(ev), 0)
		assert_same(peek(g, 1), r1)
		assert_same(peek(g, 2), r2)
		assert_same(peek(g, 3), r3)
		assert_same(peek(g, 4), r4)
		assert_eq(g.s.next_source_id, src0 + 2)
	end)
end)

describe("core boombox: hint and Bird (12.3, 9)", function()
	-- two moves of three: (3,1) right makes an orange line far from the boombox, (3,5) down a purple one next to it
	local rows = { "oobogy", "yrgbyr", "rgbyrg", "gbyrgb", "bypgby", "ppgQyr" }

	it("a match next to a boombox of an open break goal is goal progress", function()
		local g = fresh(rows, 2)
		local hint = g:hint()
		assert_same({ hint.from, hint.to }, { { 3, 1 }, { 4, 1 } }) -- no goal for it: the smaller index wins
		g = fresh(rows, 2, { goals = { { type = "break", item = "boombox", count = 1 } },
			slots = { { at = { 0, 0 }, type = "boombox", hp = 1 } } })
		hint = g:hint()
		assert_same({ hint.from, hint.to }, { { 3, 5 }, { 3, 6 } })
	end)

	it("the Bird sees a boombox of an open break goal as a goal cell (level 4), else as a blocker (level 2)", function()
		local BD = require("core.bird")
		local g = fresh(PA, 2, { goals = { { type = "break", item = "boombox", count = 1 } },
			slots = { { at = { 0, 0 }, type = "boombox", hp = 1 } } })
		assert_eq(BD.levels(g.s)[34], 4)
		g = fresh(PA, 2)
		assert_eq(BD.levels(g.s)[34], 2)
	end)
end)
