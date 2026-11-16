-- The hay bale (10.12): a blocker with the hit rules of a record box that hides a special piece. When the
-- bale is destroyed the special takes its cell, idle and free, once every effect in flight has ended.

local core = require("core.game")
local C = require("core.const")
local MT = require("core.match")
local R = require("core.rng")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- a ready purple line (1,6) (2,6) (3,6) next to the bale in (4,6)
local PA = { "pyrgpy", "yrgbyr", "rgpyrg", "gbyrgp", "bygoby", "pppHyr" }
-- one hay bale in the level file, so that the level "has hay" (the gifts are hashed) and a break goal is legal
local HAY_SLOT = { at = { 0, 0 }, type = "hay", hp = 1, gift = "none" }
local GIFTS = {
	{ code = C.GIFT_RIFF_H, name = "riff", axis = "h", special = C.SP_RIFF, ax = C.AX_H },
	{ code = C.GIFT_RIFF_V, name = "riff", axis = "v", special = C.SP_RIFF, ax = C.AX_V },
	{ code = C.GIFT_SUB, name = "sub", special = C.SP_SUB, ax = 0 },
	{ code = C.GIFT_BIRD, name = "bird", special = C.SP_BIRD, ax = 0 },
	{ code = C.GIFT_DISCO, name = "disco", special = C.SP_DISCO, ax = 0 },
}

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

-- A live board from a picture; every hay bale and record box of the picture gets `hp`, every bale `gift`.
local function fresh(rows, hp, gift, extra, opts)
	local ex = { slots = { HAY_SLOT } }
	for k, v in pairs(extra or {}) do ex[k] = v end -- order-independent
	local g = H.game(FULL, ex, opts)
	H.board(g, rows or PA)
	for i = 1, g.s.N do
		local o = g.s.objs[g.s.slot[i]]
		if o and o.kind == C.K_BLOCKER and (o.blocker == C.BK_HAY or o.blocker == C.BK_BOX) then
			o.hp = hp or 1
			if o.blocker == C.BK_HAY then o.gift = gift or 0 end
		end
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

local function join(a, b)
	local out = {}
	for _, e in ipairs(a) do out[#out + 1] = e end
	for _, e in ipairs(b) do out[#out + 1] = e end
	return out
end

-- The next three outputs of stream k of the game, without spending them.
local function peek(g, k)
	local c = g:clone()
	local st = c.s.rng[k]
	return { R.next_int(st), R.next_int(st), R.next_int(st) }
end

-- The object with this id and its cell (x, y), or nil.
local function find(g, id)
	local o = g.s.objs[id]
	if not o then return nil end
	local x = (o.cell - 1) % g.s.W + 1
	return o, x, (o.cell - x) / g.s.W + 1
end

local function hay(x, y, hp, gift, axis)
	return { at = { x, y }, type = "hay", hp = hp, gift = gift, axis = axis }
end

describe("core hay: level schema and rules (2.0, 2.1)", function()
	it("accepts hp 1..2 and every gift; a riff names its axis", function()
		local lvl = H.load(FULL, { slots = { hay(0, 1, 1, "none"), hay(2, 1, 2, "riff", "h"), hay(4, 1, 1, "riff", "v"),
			hay(1, 3, 2, "sub"), hay(3, 3, 1, "bird"), hay(5, 3, 2, "disco"), hay(2, 5, 1, "random") },
			goals = { { type = "break", item = "hay", count = 7 } } })
		assert_eq(lvl.goals[1].param, C.BK_HAY)
		assert_true(lvl.has_hay)
		local gifts = {}
		for k = 1, #lvl.presets do gifts[k] = lvl.presets[k].gift end
		assert_same(gifts, { C.GIFT_NONE, C.GIFT_RIFF_H, C.GIFT_RIFF_V, C.GIFT_SUB, C.GIFT_BIRD, C.GIFT_DISCO, C.GIFT_RANDOM })
		for k = 1, #lvl.presets do
			assert_eq(lvl.presets[k].kind, C.K_BLOCKER)
			assert_eq(lvl.presets[k].special, 0) -- the gift is not a special on the board yet
		end
		assert_false(H.load(FULL).has_hay)
	end)

	it("rejects a bad hp, an unknown or missing gift, a stray axis and a gift outside a bale", function()
		expect(H.level(FULL, { slots = { hay(2, 2, 0, "none") } }), "slots[1]: bad or missing hp")
		expect(H.level(FULL, { slots = { hay(2, 2, 3, "none") } }), "slots[1]: bad or missing hp")
		expect(H.level(FULL, { slots = { { at = { 2, 2 }, type = "hay", gift = "none" } } }), "slots[1]: bad or missing hp")
		expect(H.level(FULL, { slots = { hay(2, 2, 1, "gold") } }),
			"slots[1]: gift none|riff|sub|bird|disco|random required for a hay bale")
		expect(H.level(FULL, { slots = { { at = { 2, 2 }, type = "hay", hp = 1 } } }),
			"slots[1]: gift none|riff|sub|bird|disco|random required for a hay bale")
		expect(H.level(FULL, { slots = { { at = { 2, 2 }, type = "hay", hp = 1, gift = 3 } } }),
			"slots[1]: gift none|riff|sub|bird|disco|random required for a hay bale")
		expect(H.level(FULL, { slots = { hay(2, 2, 1, "riff") } }), "slots[1]: axis h|v required with gift riff")
		expect(H.level(FULL, { slots = { hay(2, 2, 1, "riff", "x") } }), "slots[1]: axis h|v required with gift riff")
		expect(H.level(FULL, { slots = { hay(2, 2, 1, "sub", "h") } }), "slots[1]: axis goes only with gift riff")
		expect(H.level(FULL, { slots = { { at = { 2, 2 }, type = "record_box", hp = 1, gift = "sub" } } }),
			"slots[1]: gift is only for a hay bale (type hay)")
		expect(H.level(FULL, { slots = { { at = { 2, 2 }, type = "sub", gift = "none" } } }),
			"slots[1]: gift is only for a hay bale (type hay)")
		expect(H.level(FULL, { slots = { { at = { 2, 2 }, type = "hay", hp = 1, gift = "none", color = "red" } } }),
			"unknown key 'color'")
		-- one message per mistake: the stray keys are not reported twice
		local got = errors_of(H.level(FULL, { slots = { { at = { 2, 2 }, type = "noise", gift = "sub" } } }))
		assert_eq(got, "2.1.1 slots[1]: gift is only for a hay bale (type hay)")
	end)

	it("joins the break goal family", function()
		expect(H.level(FULL, { slots = { hay(2, 2, 1, "sub") }, goals = { { type = "break", item = "hay", count = 2 } } }),
			"2.1.5 break count exceeds the hay objects on the board")
		expect(H.level(FULL, { goals = { { type = "break", item = "straw", count = 1 } } }),
			"2.1.5 break item must be record_box, concrete, noise, balloon, column, boombox or hay")
	end)

	it("2.1.6: the hay bale is one of the three element kinds of a level", function()
		local three = { hay(2, 2, 1, "random"), { at = { 0, 3 }, type = "record_box", hp = 1 }, { at = { 5, 3 }, type = "noise" } }
		assert_eq(errors_of(H.level(FULL, { slots = three })), "")
		three[4] = { at = { 3, 4 }, type = "concrete", hp = 1 }
		expect(H.level(FULL, { slots = three }), "2.1.6 more than three different elements")
	end)

	it("2.1.12-2.1.14: not under a curtain, not under the starting carpet, not on a belt", function()
		expect(H.level(FULL, { slots = { hay(2, 2, 1, "sub") },
			curtain = { covers = { { 2, 2 } }, closed_moves = 2, open_moves = 2, start = "closed" } }),
			"2.1.12 only a regular piece may stand under a curtain at 2,2")
		expect(H.level(FULL, { slots = { hay(2, 2, 1, "sub") }, carpet = { { 2, 2 } }, goals = { { type = "carpet" } } }), "2.1.13")
		expect(H.level(FULL, { slots = { hay(2, 2, 1, "sub") }, conveyor = { { path = { { 1, 2 }, { 2, 2 }, { 3, 2 } } } } }),
			"2.1.14 blocker on a conveyor at 2,2")
	end)

	it("the start board carries the gifts; pieces() does not tell them", function()
		local g = H.game(FULL, { slots = { hay(2, 2, 2, "sub"), hay(3, 3, 1, "none") } })
		assert_eq(H.obj_at(g, 3, 3).gift, C.GIFT_SUB)
		assert_eq(H.obj_at(g, 4, 4).gift, C.GIFT_NONE)
		local seen = 0
		for _, p in ipairs(g:pieces()) do
			if p.item == "hay" then
				seen = seen + 1
				assert_eq(p.kind, "blocker")
				assert_eq(p.gift, nil)
				assert_eq(p.special, nil)
			end
		end
		assert_eq(seen, 2)
	end)
end)

describe("core hay: damage (7.3), the same as a record box", function()
	-- the same scenario with a record box and with an empty bale: hp, blocker events and the goal must agree
	local function trail(ch, hp, act)
		local item = ch == "X" and "record_box" or "hay"
		local slot = { at = { 0, 0 }, type = item, hp = 1 }
		if ch == "H" then slot.gift = "none" end
		local g = fresh(with(PA, 4, 6, ch), hp, 0, { goals = { { type = "break", item = item, count = 1 },
			{ type = "collect", color = "red", count = 999 } }, slots = { slot } })
		local ev = act(g)
		local out = {}
		for _, e in ipairs(ev) do
			if (e.type == "hit" and e.layer == "blocker") or e.type == "destroy" then
				out[#out + 1] = { e.type, e.x, e.y, e.hp or -1, e.t }
			end
		end
		local o = H.obj_at(g, 4, 6)
		return out, (o and o.kind == C.K_BLOCKER and o.state == C.S_IDLE) and o.hp or 0, g:status().goals[1], g:status().score
	end
	local function same(hp, act)
		local a, ahp, agoal, ascore = trail("X", hp, act)
		local b, bhp, bgoal, bscore = trail("H", hp, act)
		assert_same(b, a)
		assert_eq(bhp, ahp)
		assert_eq(bgoal, agoal)
		assert_eq(bscore, ascore)
		return b, bhp
	end
	local function stick(g)
		assert_true(g:input({ type = "booster", booster = "stick", at = { 4, 6 } }))
		g:step()
		return g:drain_events()
	end

	it("an adjacent match takes one hp", function()
		local ev, hp = same(2, search)
		assert_same({ ev[1][1], ev[1][2], ev[1][3], ev[1][4] }, { "hit", 4, 6, 1 })
		assert_eq(hp, 1)
		ev, hp = same(1, search)
		assert_same({ ev[1][1], ev[1][2], ev[1][3] }, { "destroy", 4, 6 })
		assert_eq(hp, 0)
	end)

	it("a booster or a special takes one hp", function()
		local ev, hp = same(2, stick)
		assert_same({ ev[1][1], ev[1][4] }, { "hit", 1 })
		assert_eq(hp, 1)
		ev = same(1, stick)
		assert_eq(ev[1][1], "destroy")
		same(2, function(g)
			assert_true(g:input({ type = "booster", booster = "row_light", row = 6 }))
			return rest(g, 30)
		end)
		-- a Riff through the row
		same(2, function(g)
			local o = H.obj_at(g, 6, 6)
			o.kind, o.color, o.special, o.axis = C.K_SPECIAL, 0, C.SP_RIFF, C.AX_H
			assert_true(g:input({ type = "tap", at = { 6, 6 } }))
			return H.steps(g, 12)
		end)
	end)

	it("one hit per source: a group that touches it with two cells takes one hp", function()
		-- the bale in (2,5) touches the line (1,6) (2,6) (3,6) and nothing else of it; a square would touch twice
		local rows = { "pyrgpy", "yrgbyr", "rgpyrg", "gbyrgb", "ppHoby", "ppgryr" }
		for _, ch in ipairs({ "X", "H" }) do
			local g = fresh(with(rows, 3, 5, ch), 2)
			local ev = search(g)
			assert_eq(#H.of_type(ev, "match"), 1)
			assert_eq(H.obj_at(g, 3, 5).hp, 1)
		end
	end)

	it("a match that is not adjacent does nothing to it", function()
		local rows = { "pppgby", "yrgbyr", "rgbyrg", "gbyrgb", "bygoby", "oyrHyr" }
		for _, ch in ipairs({ "X", "H" }) do
			local g = fresh(with(rows, 4, 6, ch), 2, C.GIFT_SUB)
			local ev = search(g)
			assert_eq(#H.of_type(ev, "match"), 1)
			assert_eq(H.obj_at(g, 4, 6).hp, 2)
		end
	end)

	it("it is fixed: a blocker for gravity, for the swap and for the shuffle", function()
		local g = fresh(with(PA, 4, 6, "H"), 2, C.GIFT_SUB)
		local ok, why = g:input({ type = "swap", from = { 4, 6 }, to = { 5, 6 } })
		assert_false(ok)
		assert_eq(why, "not_movable")
		ok, why = g:input({ type = "tap", at = { 4, 6 } })
		assert_false(ok)
		assert_eq(why, "not_movable")
	end)

	it("an empty bale (gift none) leaves an empty cell, at the tick a record box does", function()
		local function vanish(ch)
			local g = fresh(with(PA, 4, 6, ch), 1, C.GIFT_NONE)
			local id = H.obj_at(g, 4, 6).id
			search(g)
			local n = 0
			local all = {}
			while g.s.objs[id] do
				for _, e in ipairs(H.steps(g, 1)) do all[#all + 1] = e end
				n = n + 1
				assert_true(n < 50)
			end
			return n, all
		end
		local nx = vanish("X")
		local nh, ev = vanish("H")
		assert_eq(nx, C.T[1].clear)
		assert_eq(nh, nx)
		assert_eq(#H.of_type(ev, "gift"), 0)
		-- to rest: the cell is refilled by an ordinary piece, there is no special anywhere
		local g = fresh(nil, 1, C.GIFT_NONE)
		local all = join(search(g), rest(g))
		assert_eq(#H.of_type(all, "gift"), 0)
		for i = 1, g.s.N do
			local o = g.s.objs[g.s.slot[i]]
			assert_true(o ~= nil and o.kind ~= C.K_BLOCKER)
		end
	end)
end)

describe("core hay: the gift (10.12)", function()
	it("every gift kind takes the cell of the bale: a new idle special with the label of the hit", function()
		for _, gf in ipairs(GIFTS) do
			local g = fresh(nil, 1, gf.code)
			local bale = H.obj_at(g, 4, 6)
			local next_id = g.s.next_piece_id
			local ev = search(g)
			-- the tick of the hit: the bale is destroyed and stays in `clear`; nothing is revealed yet
			assert_eq(#H.of_type(ev, "destroy"), 1)
			assert_eq(#H.of_type(ev, "gift"), 0)
			assert_eq(bale.state, C.S_CLEAR)
			assert_eq(bale.gift, gf.code)
			local t_hit = g.s.tick
			local all = rest(g)
			local gifts = H.of_type(all, "gift")
			assert_eq(#gifts, 1)
			local e = gifts[1]
			assert_same({ e.x, e.y, e.special, e.axis, e.from }, { 4, 6, C.SPECIAL_NAME[gf.special], gf.axis, bale.id })
			assert_eq(e.t, t_hit + C.T[1].clear) -- no effect in flight: the gift appears when the bale is gone
			for _, sn in ipairs(H.of_type(all, "special_new")) do assert_true(sn.id ~= e.id) end -- (not a `special_new`)
			local o = H.obj_at(g, 4, 6)
			assert_eq(o.id, e.id)
			assert_true(o.id >= next_id)
			assert_eq(g.s.objs[bale.id], nil)
			assert_same({ o.kind, o.special, o.axis, o.state, o.blocker, o.hp, o.gift, o.color },
				{ C.K_SPECIAL, gf.special, gf.ax, C.S_IDLE, 0, 0, 0, 0 })
			assert_same({ o.mv, o.wv, o.settle }, { 0, 1, e.t }) -- the label of the group that broke the bale
			assert_eq(#H.of_type(all, "activate"), 0)
			-- it is an ordinary special in pieces()
			local seen = false
			for _, p in ipairs(g:pieces()) do
				if p.id == o.id then
					seen = true
					assert_same({ p.kind, p.special, p.axis, p.state, p.item }, { "special", C.SPECIAL_NAME[gf.special], gf.axis, "idle", nil })
				end
			end
			assert_true(seen)
		end
	end)

	it("the revealed special is usable: a tap fires it", function()
		for _, gf in ipairs(GIFTS) do
			local g = fresh(nil, 1, gf.code)
			search(g)
			rest(g)
			local id = H.obj_at(g, 4, 6).id
			local moves = g:status().moves_left
			assert_true(g:has_move())
			assert_true(g:input({ type = "tap", at = { 4, 6 } }))
			local acts = H.of_type(rest(g), "activate")
			assert_true(#acts >= 1)
			assert_same({ acts[1].id, acts[1].special, acts[1].x, acts[1].y }, { id, C.SPECIAL_NAME[gf.special], 4, 6 })
			assert_eq(g:status().moves_left, moves - 1)
			assert_eq(g.s.objs[id], nil)
		end
	end)

	it("the revealed special is usable: a swap with a piece and a combo with another gift", function()
		-- a swap with the piece on its right
		local g = fresh(nil, 1, C.GIFT_BIRD)
		search(g)
		rest(g)
		local id = H.obj_at(g, 4, 6).id
		assert_eq(g:can_swap({ 4, 6 }, { 5, 6 }), "ok")
		assert_true(g:input({ type = "swap", from = { 4, 6 }, to = { 5, 6 } }))
		local acts = H.of_type(rest(g), "activate")
		assert_same({ acts[1].id, acts[1].special, acts[1].x, acts[1].y }, { id, "bird", 5, 6 })
		-- two bales next to one match: (3,5) above the line and (4,6) beside it; the gift of (3,5) falls to (3,6)
		g = fresh(with(PA, 3, 5, "H"), 1, C.GIFT_SUB)
		local ev = join(search(g), rest(g))
		local gifts = H.of_type(ev, "gift")
		assert_eq(#gifts, 2)
		assert_same({ gifts[1].x, gifts[1].y, gifts[2].x, gifts[2].y }, { 3, 5, 4, 6 })
		local a, b = H.obj_at(g, 3, 6), H.obj_at(g, 4, 6)
		assert_same({ a.id, b.id }, { gifts[1].id, gifts[2].id })
		assert_true(g:input({ type = "swap", from = { 3, 6 }, to = { 4, 6 } }))
		acts = H.of_type(rest(g), "activate")
		assert_eq(acts[1].combo, "bass_drop")
	end)

	it("the gift draws no score of its own and moves no goal counter twice", function()
		local g = fresh(nil, 1, C.GIFT_DISCO, { goals = { { type = "break", item = "hay", count = 1 },
			{ type = "collect", color = "red", count = 999 } } })
		local ev = search(g)
		local goals = H.of_type(ev, "goal")
		assert_eq(#goals, 1)
		assert_same({ goals[1].index, goals[1].left }, { 1, 0 })
		local score = g:status().score
		-- up to the tick of the reveal nothing else happens on the board (the line is still clearing)
		local all = H.steps(g, C.T[1].clear)
		assert_eq(#H.of_type(all, "gift"), 1)
		assert_eq(g:status().score, score)
		assert_eq(#H.of_type(all, "goal"), 0)
	end)

	it("a bale of hp 2 keeps its gift through the first hit", function()
		local g = fresh(nil, 2, C.GIFT_RIFF_V)
		local ev = join(search(g), rest(g))
		assert_eq(#H.of_type(ev, "gift"), 0)
		local o = H.obj_at(g, 4, 6)
		assert_same({ o.kind, o.blocker, o.hp, o.gift, o.state }, { C.K_BLOCKER, C.BK_HAY, 1, C.GIFT_RIFF_V, C.S_IDLE })
		assert_true(g:input({ type = "booster", booster = "stick", at = { 4, 6 } }))
		ev = rest(g)
		local gifts = H.of_type(ev, "gift")
		assert_eq(#gifts, 1)
		assert_same({ gifts[1].special, gifts[1].axis }, { "riff", "v" })
		-- the label of a booster hit: (act, 1)
		local n = H.obj_at(g, 4, 6)
		assert_same({ n.mv, n.wv }, { g.s.act, 1 })
	end)
end)

describe("core hay: the random gift (3.2, stream effects)", function()
	it("one draw at the destruction: riff h, riff v, sub or bird, never the disco ball", function()
		local seen = { 0, 0, 0, 0, 0, 0 }
		for seed = 1, 60 do
			local g = fresh(nil, 1, C.GIFT_RANDOM, nil, { seed = seed })
			local bale = H.obj_at(g, 4, 6)
			local r1, r2, r3, r4 = peek(g, 1), peek(g, 2), peek(g, 3), peek(g, 4)
			g.s.dirty = true
			MT.search(g.s)
			local want = r3[1] % 4 + 1
			assert_eq(bale.gift, want)
			assert_true(want >= C.GIFT_RIFF_H and want <= C.GIFT_BIRD)
			seen[want] = seen[want] + 1
			-- exactly one number of the effects stream, nothing of the others
			assert_eq(peek(g, 3)[1], r3[2])
			assert_same(peek(g, 1), r1)
			assert_same(peek(g, 2), r2)
			assert_same(peek(g, 4), r4)
			local gifts = H.of_type(rest(g), "gift")
			assert_same({ gifts[1].special, gifts[1].axis },
				{ C.SPECIAL_NAME[C.GIFT_SPECIAL[want]], C.AXIS_NAME[C.GIFT_AXIS[want]] })
		end
		for k = 1, 4 do assert_true(seen[k] >= 5, "gift " .. k .. " came " .. seen[k] .. " times in 60 seeds") end
		assert_eq(seen[C.GIFT_DISCO], 0)
	end)

	it("the same seed draws the same gift; a clone too", function()
		for seed = 1, 5 do
			local a = fresh(nil, 1, C.GIFT_RANDOM, nil, { seed = seed })
			local b = fresh(nil, 1, C.GIFT_RANDOM, nil, { seed = seed })
			local c = a:clone()
			local ea, eb, ec = join(search(a), rest(a)), join(search(b), rest(b)), join(search(c), rest(c))
			local ga, gb, gc = H.of_type(ea, "gift")[1], H.of_type(eb, "gift")[1], H.of_type(ec, "gift")[1]
			assert_same({ gb.special, gb.axis, gb.t, gb.id }, { ga.special, ga.axis, ga.t, ga.id })
			assert_same({ gc.special, gc.axis, gc.t, gc.id }, { ga.special, ga.axis, ga.t, ga.id })
			assert_eq(a:hash(), b:hash())
			assert_eq(a:hash(), c:hash())
		end
	end)

	it("no draw before the destruction, none for a fixed gift, none for an empty bale", function()
		-- hp 2: the first hit draws nothing and the gift stays unknown
		local g = fresh(nil, 2, C.GIFT_RANDOM)
		local r3 = peek(g, 3)
		g.s.dirty = true
		MT.search(g.s)
		assert_same(peek(g, 3), r3)
		assert_eq(H.obj_at(g, 4, 6).gift, C.GIFT_RANDOM)
		for _, gift in ipairs({ C.GIFT_NONE, C.GIFT_SUB, C.GIFT_DISCO }) do
			g = fresh(nil, 1, gift)
			r3 = peek(g, 3)
			g.s.dirty = true
			MT.search(g.s)
			assert_same(peek(g, 3), r3)
			H.steps(g, C.T[1].clear) -- (the reveal itself draws nothing either; no spawn uses this stream)
			assert_same(peek(g, 3), r3)
		end
	end)

	it("a level without hay never draws: a record box in the same place", function()
		local g = H.game(FULL)
		assert_false(g.s.level.has_hay)
		H.board(g, with(PA, 4, 6, "X"))
		local r1, r2, r3, r4 = peek(g, 1), peek(g, 2), peek(g, 3), peek(g, 4)
		g.s.dirty = true
		MT.search(g.s)
		assert_same(peek(g, 1), r1)
		assert_same(peek(g, 2), r2)
		assert_same(peek(g, 3), r3)
		assert_same(peek(g, 4), r4)
		local ev = join(g:drain_events(), H.steps(g, C.T[1].clear))
		assert_eq(#H.of_type(ev, "gift"), 0)
		assert_same(peek(g, 3), r3)
	end)
end)

describe("core hay: the hit that opens the bale never fires the gift", function()
	-- a match-free board; a Riff h in (1,6), the bale in (4,6)
	local function riff_row(gift, opts)
		return fresh(H.rows(6, 6, { ["1,6"] = "R", ["4,6"] = "H" }), 1, gift, nil, opts)
	end

	it("a special destroys the bale: the gift comes after the effect and stays idle", function()
		for _, timing in ipairs({ "normal", "turbo" }) do
			for _, gf in ipairs(GIFTS) do
				local g = riff_row(gf.code, { timing = timing })
				assert_true(g:input({ type = "tap", at = { 1, 6 } }))
				local ev = rest(g)
				local acts, gifts = H.of_type(ev, "activate"), H.of_type(ev, "gift")
				assert_eq(#acts, 1) -- the Riff of the player and nothing else
				assert_eq(acts[1].special, "riff")
				assert_eq(#gifts, 1)
				assert_same({ gifts[1].x, gifts[1].y, gifts[1].special }, { 4, 6, C.SPECIAL_NAME[gf.special] })
				local o = find(g, gifts[1].id)
				assert_true(o ~= nil, "the gift is gone")
				assert_same({ o.kind, o.special, o.state, o.cell }, { C.K_SPECIAL, gf.special, C.S_IDLE, 34 })
				assert_same({ o.mv, o.wv }, { 1, 1 }) -- the label of the Riff's activation
			end
		end
	end)

	it("a chain started by the same hit does not fire it either: the gift waits for the last effect", function()
		-- the Riff in (1,6) breaks the bale in (3,6) and launches the Sub in (4,6); the rings of the Sub cross
		-- the cell of the bale AFTER its clear timer has run out
		for _, timing in ipairs({ "normal", "turbo" }) do
			local g = fresh(H.rows(6, 6, { ["1,6"] = "R", ["3,6"] = "H", ["4,6"] = "S" }), 1, C.GIFT_BIRD, nil, { timing = timing })
			assert_true(g:input({ type = "tap", at = { 1, 6 } }))
			local ev, t_destroy, t_last_ring = {}, 0, 0
			local queue_at_gift = nil
			for _ = 1, 900 do
				g:step()
				for _, e in ipairs(g:drain_events()) do
					ev[#ev + 1] = e
					if e.type == "destroy" then t_destroy = e.t end
					if e.type == "ring" and e.at > t_last_ring then t_last_ring = e.at end
					if e.type == "gift" then queue_at_gift = #g.s.queue end
				end
				if g:is_stable() then break end
			end
			local acts, gifts = H.of_type(ev, "activate"), H.of_type(ev, "gift")
			assert_eq(#acts, 2)
			assert_same({ acts[1].special, acts[2].special }, { "riff", "sub" })
			assert_eq(#gifts, 1)
			assert_eq(gifts[1].special, "bird")
			assert_eq(queue_at_gift, 0)
			assert_true(gifts[1].t >= t_last_ring, "the gift came at " .. gifts[1].t .. ", the last ring at " .. t_last_ring)
			if timing == "normal" then
				-- the timer alone would have revealed it under the rings
				assert_true(t_last_ring > t_destroy + C.T[1].clear)
				assert_true(gifts[1].t > t_destroy + C.T[1].clear)
			end
			local o, x = find(g, gifts[1].id)
			assert_true(o ~= nil, "the gift is gone")
			assert_same({ o.kind, o.special, o.state, x }, { C.K_SPECIAL, C.SP_BIRD, C.S_IDLE, 3 })
		end
	end)

	it("while it waits the cell is an open slot: nothing falls into it and no hit finds a piece", function()
		local g = fresh(H.rows(6, 6, { ["1,6"] = "R", ["3,6"] = "H", ["4,6"] = "S" }), 1, C.GIFT_BIRD)
		local bale = H.obj_at(g, 3, 6)
		assert_true(g:input({ type = "tap", at = { 1, 6 } }))
		local waited = 0
		for _ = 1, 200 do
			g:step()
			if g.s.objs[bale.id] == nil then break end
			if bale.state == C.S_CLEAR then
				assert_eq(g.s.slot[bale.cell], bale.id)
				assert_false(g:is_stable())
				if bale.td <= g.s.tick then waited = waited + 1 end
			end
		end
		assert_true(waited >= 2, "the bale never waited past its timer")
	end)

	it("a later effect fires the gift like any special (a chain)", function()
		local g = riff_row(C.GIFT_SUB)
		assert_true(g:input({ type = "tap", at = { 1, 6 } }))
		local id = H.of_type(rest(g), "gift")[1].id
		-- a second Riff in the same row
		local o = H.obj_at(g, 6, 6)
		o.kind, o.color, o.special, o.axis = C.K_SPECIAL, 0, C.SP_RIFF, C.AX_H
		assert_true(g:input({ type = "tap", at = { 6, 6 } }))
		local acts = H.of_type(rest(g), "activate")
		assert_eq(#acts, 2)
		assert_same({ acts[2].id, acts[2].special }, { id, "sub" })
	end)

	it("the Grand finale (a hit of every layer) opens the bale and leaves the gift", function()
		local g = fresh(H.rows(6, 6, { ["1,6"] = "D", ["2,6"] = "D", ["4,4"] = "H" }), 1, C.GIFT_RIFF_H)
		assert_true(g:input({ type = "swap", from = { 1, 6 }, to = { 2, 6 } }))
		local ev = rest(g, 3000)
		local gifts = H.of_type(ev, "gift")
		assert_eq(#gifts, 1)
		local acts = H.of_type(ev, "activate")
		assert_eq(#acts, 1)
		assert_eq(acts[1].combo, "finale")
		local o = find(g, gifts[1].id)
		assert_same({ o.kind, o.special, o.state }, { C.K_SPECIAL, C.SP_RIFF, C.S_IDLE })
	end)
end)

describe("core hay: gravity after the reveal (10.1)", function()
	it("the gift is an ordinary special: it falls into the hole under the bale", function()
		-- a Riff v in (2,1) clears column 2: the pieces above and under the bale of (2,4), and the bale
		for _, timing in ipairs({ "normal", "turbo" }) do
			local g = fresh(H.rows(6, 6, { ["2,1"] = "V", ["2,4"] = "H" }), 1, C.GIFT_RIFF_H, nil, { timing = timing })
			assert_true(g:input({ type = "tap", at = { 2, 1 } }))
			local ev = rest(g)
			local gifts = H.of_type(ev, "gift")
			assert_eq(#gifts, 1)
			assert_same({ gifts[1].x, gifts[1].y }, { 2, 4 })
			local o, x, y = find(g, gifts[1].id)
			assert_same({ o.special, o.state, x, y }, { C.SP_RIFF, C.S_IDLE, 2, 6 })
			local lands = 0
			for _, e in ipairs(H.of_type(ev, "land")) do
				if e.id == gifts[1].id then
					lands = lands + 1
					assert_same({ e.x, e.y }, { 2, 6 })
				end
			end
			assert_eq(lands, 1)
			for i = 1, g.s.N do assert_true(g.s.slot[i] ~= 0) end
			assert_eq(#H.of_type(ev, "activate"), 1)
		end
	end)

	it("the cells under a destroyed bale wait for the gift (nothing slides in from the side)", function()
		local g = fresh(H.rows(6, 6, { ["2,1"] = "V", ["2,4"] = "H" }), 1, C.GIFT_SUB)
		local bale = H.obj_at(g, 2, 4)
		assert_true(g:input({ type = "tap", at = { 2, 1 } }))
		for _ = 1, 200 do
			g:step()
			if g.s.objs[bale.id] == nil then break end
			if bale.state == C.S_CLEAR and bale.td < g.s.tick then
				-- (2,5) and (2,6) were cleared with the bale: they stay empty until it is gone
				assert_eq(g.s.slot[26], 0)
				assert_eq(g.s.slot[32], 0)
			end
		end
		assert_eq(g.s.objs[bale.id], nil)
	end)
end)

describe("core hay: the break goal and the win (7.4, 13)", function()
	local EXTRA = { goals = { { type = "break", item = "hay", count = 2 } },
		slots = { hay(0, 2, 1, "none"), hay(3, 2, 1, "none") } }

	it("counts a bale when it is destroyed; the last one wins and the gifts play in the concert", function()
		local g = fresh(with(PA, 3, 5, "H"), 1, C.GIFT_RIFF_H, EXTRA)
		local ev = search(g)
		local goals = H.of_type(ev, "goal")
		assert_same({ goals[1].left, goals[2].left }, { 1, 0 })
		assert_eq(g:status().state, "won_wait")
		assert_eq(#H.of_type(ev, "gift"), 0)
		local all = rest(g, 5000)
		for _ = 1, 20 do
			if g:status().state == "complete" then break end
			for _, e in ipairs(rest(g, 5000)) do all[#all + 1] = e end
		end
		assert_eq(g:status().state, "complete")
		assert_true(g:result().won)
		local gifts = H.of_type(all, "gift")
		assert_eq(#gifts, 2)
		-- both gifts were revealed before the concert began and fired in it
		local t_concert = 0
		for _, e in ipairs(H.of_type(all, "state")) do
			if e.state == "concert" then t_concert = e.t end
		end
		assert_true(gifts[1].t <= t_concert and gifts[2].t <= t_concert)
		local fired = {}
		for _, e in ipairs(H.of_type(all, "activate")) do
			if e.id then fired[e.id] = true end
		end
		assert_true(fired[gifts[1].id] and fired[gifts[2].id])
	end)

	it("a hit that only thins the bale moves no counter; each hp is worth 50", function()
		local g = fresh(nil, 2, C.GIFT_SUB, EXTRA)
		local score = g:status().score
		local ev = search(g)
		assert_eq(#H.of_type(ev, "goal"), 0)
		assert_same(g:status().goals, { 2 })
		local hits = {}
		for _, e in ipairs(H.of_type(ev, "hit")) do
			if e.layer == "blocker" then hits[#hits + 1] = { e.item, e.hp } end
		end
		assert_same(hits, { { "hay", 1 } })
		assert_eq(g:status().score - score, 3 * C.SCORE_WAVE + C.SCORE_HP)
	end)
end)

describe("core hay: the other elements", function()
	it("carpet (10.8): the bale is a wall, the gift stands on a cell that is covered later", function()
		local extra = { carpet = { { 0, 5 } }, goals = { { type = "carpet" }, { type = "break", item = "hay", count = 1 } } }
		local g = fresh(H.rows(6, 6, { ["1,6"] = "R", ["4,6"] = "H" }), 1, C.GIFT_SUB, extra)
		assert_true(g.s.carpet[31])
		assert_true(g:input({ type = "tap", at = { 1, 6 } }))
		local ev = rest(g)
		-- the Riff stood on the carpet: its row is covered, except the cell of the bale it destroyed
		assert_true(g.s.carpet[32] and g.s.carpet[33] and g.s.carpet[35] and g.s.carpet[36])
		assert_false(g.s.carpet[34])
		local gift = H.of_type(ev, "gift")[1]
		local o = find(g, gift.id)
		assert_same({ o.cell, o.state }, { 34, C.S_IDLE })
		-- a second Riff on the carpet: its hit covers the cell and fires the gift, which now stands on the carpet
		local r = H.obj_at(g, 1, 6)
		r.kind, r.color, r.special, r.axis = C.K_SPECIAL, 0, C.SP_RIFF, C.AX_H
		assert_true(g:input({ type = "tap", at = { 1, 6 } }))
		rest(g)
		assert_true(g.s.carpet[34])
		assert_true(g.s.carpet[28] and g.s.carpet[22]) -- the Sub fired from the carpet: its square is covered
	end)

	it("conveyor (10.9): an intact bale never rides; its gift, once on a belt, rides like any special", function()
		local extra = { conveyor = { { path = { { 0, 5 }, { 1, 5 }, { 2, 5 } } } } }
		local g = fresh(H.rows(6, 6, { ["2,1"] = "V", ["2,4"] = "H" }), 1, C.GIFT_SUB, extra)
		assert_true(g:input({ type = "tap", at = { 2, 1 } }))
		local ev = rest(g)
		local gift = H.of_type(ev, "gift")[1]
		-- the gift fell to (2,6), a belt cell; the move of the tap then carried it to (3,6)
		local belts = H.of_type(ev, "conveyor")
		assert_eq(#belts, 1)
		assert_true(belts[1].t > gift.t)
		local rode = false
		for _, m in ipairs(belts[1].moves) do
			if m.id == gift.id then
				rode = true
				assert_same({ m.fx, m.fy, m.x, m.y }, { 2, 6, 3, 6 })
			end
		end
		assert_true(rode)
		local o, x, y = find(g, gift.id)
		assert_same({ o.kind, x, y }, { C.K_SPECIAL, 3, 6 })
	end)

	it("curtain (10.7): a gift that fell under an open curtain is frozen when it closes", function()
		local extra = { curtain = { covers = { { 1, 5 } }, closed_moves = 2, open_moves = 1, start = "open" } }
		local g = fresh(H.rows(6, 6, { ["2,1"] = "V", ["2,4"] = "H" }), 1, C.GIFT_SUB, extra)
		assert_true(g:input({ type = "tap", at = { 2, 1 } }))
		local ev = rest(g)
		local gift = H.of_type(ev, "gift")[1]
		local o, x, y = find(g, gift.id)
		assert_same({ x, y, o.state }, { 2, 6, C.S_IDLE })
		assert_eq(g:status().curtain.phase, "closed")
		local ok, why = g:input({ type = "tap", at = { 2, 6 } })
		assert_false(ok)
		assert_eq(why, "not_movable")
		ok, why = g:input({ type = "booster", booster = "stick", at = { 2, 6 } })
		assert_false(ok)
		assert_eq(why, "bad_cell")
		local veiled = false
		for _, p in ipairs(g:pieces()) do
			if p.id == gift.id then veiled = p.veiled == true end
		end
		assert_true(veiled)
	end)

	it("boombox (10.10): one match opens a bale and plays a boombox; the blast never takes the gift", function()
		-- the purple line of row 6: the bale of (2,5) stands above it, the boombox of (4,6) beside it
		local rows = with(with(PA, 4, 6, "Q"), 2, 5, "H")
		for seed = 1, 8 do
			local g = fresh(rows, 1, C.GIFT_RANDOM, nil, { seed = seed })
			local bale = H.obj_at(g, 2, 5)
			local r3 = peek(g, 3)
			local ev = search(g)
			-- the adjacent hits come first (the bale draws its gift), the blast of the boombox after them
			assert_eq(bale.gift, r3[1] % 4 + 1)
			local bb = H.of_type(ev, "boombox")
			assert_eq(#bb, 1)
			for _, c in ipairs(bb[1].cells) do
				assert_true(not (c[1] == 2 and c[2] == 5))
				assert_eq(H.obj_at(g, c[1], c[2]).kind, C.K_REGULAR)
			end
			local all = join(ev, rest(g))
			local gifts = H.of_type(all, "gift")
			assert_eq(#gifts, 1)
			assert_eq(#H.of_type(all, "activate"), 0)
			local o, x, y = find(g, gifts[1].id)
			assert_same({ o.kind, o.state, x, y }, { C.K_SPECIAL, C.S_IDLE, 2, 6 }) -- (it fell into the cleared line)
		end
	end)

	it("ice (10.11): the gift swiped onto a frozen piece fires in place and melts a layer", function()
		local g = fresh(nil, 1, C.GIFT_RIFF_H)
		local frozen = H.obj_at(g, 5, 6)
		frozen.ice = 2
		search(g)
		rest(g)
		assert_eq(frozen.ice, 2) -- the match was not next to it
		local gift = H.obj_at(g, 4, 6)
		assert_eq(gift.special, C.SP_RIFF)
		assert_eq(g:can_swap({ 4, 6 }, { 5, 6 }), "ok")
		assert_true(g:input({ type = "swap", from = { 4, 6 }, to = { 5, 6 } }))
		local ev = H.steps(g, 6)
		local acts = H.of_type(ev, "activate")
		assert_same({ acts[1].id, acts[1].x, acts[1].y }, { gift.id, 4, 6 })
		local melted = false
		for _, e in ipairs(H.of_type(ev, "hit")) do
			if e.layer == "ice" and e.x == 5 and e.y == 6 then melted = true end
		end
		assert_true(melted)
		assert_eq(frozen.ice, 1)
	end)

	it("ice and hay next to one match: the ice melts, the bale opens", function()
		local g = fresh(nil, 1, C.GIFT_BIRD)
		H.obj_at(g, 2, 5).ice = 1
		local ev = search(g)
		assert_eq(#H.of_type(ev, "thawed"), 1)
		assert_eq(#H.of_type(ev, "destroy"), 1)
		assert_eq(#H.of_type(join(ev, rest(g)), "gift"), 1)
	end)
end)

describe("core hay: hint and Bird (12.3, 9)", function()
	-- two moves of three: (3,1) right makes an orange line far from the bale, (3,5) down a purple one next to it
	local rows = { "oobogy", "yrgbyr", "rgbyrg", "gbyrgb", "bypgby", "ppgHyr" }

	it("a match next to a bale of an open break goal is goal progress", function()
		local g = fresh(rows, 2, C.GIFT_SUB)
		local hint = g:hint()
		assert_same({ hint.from, hint.to }, { { 3, 1 }, { 4, 1 } }) -- no goal for it: the smaller index wins
		g = fresh(rows, 2, C.GIFT_SUB, { goals = { { type = "break", item = "hay", count = 1 } } })
		hint = g:hint()
		assert_same({ hint.from, hint.to }, { { 3, 5 }, { 3, 6 } })
		-- an empty bale counts the same: the player cannot tell them apart
		g = fresh(rows, 1, C.GIFT_NONE, { goals = { { type = "break", item = "hay", count = 1 } } })
		hint = g:hint()
		assert_same({ hint.from, hint.to }, { { 3, 5 }, { 3, 6 } })
	end)

	it("the Bird sees a bale of an open break goal as a goal cell (level 4), else as a blocker (level 2)", function()
		local BD = require("core.bird")
		local g = fresh(nil, 2, C.GIFT_SUB, { goals = { { type = "break", item = "hay", count = 1 } } })
		assert_eq(BD.levels(g.s)[34], 4)
		g = fresh(nil, 2, C.GIFT_SUB)
		assert_eq(BD.levels(g.s)[34], 2)
		-- the same for a full and for an empty bale
		g = fresh(nil, 2, C.GIFT_NONE)
		assert_eq(BD.levels(g.s)[34], 2)
	end)
end)

describe("core hay: determinism and the hash (17)", function()
	local LVL = { slots = { hay(3, 3, 2, "random"), hay(1, 4, 1, "random"), hay(4, 1, 2, "sub"), hay(2, 2, 1, "none"),
		hay(5, 4, 1, "riff", "v") },
		colors = { "red", "yellow", "blue", "purple" }, moves = 30,
		goals = { { type = "break", item = "hay", count = 5 } } }

	-- plays the hinted move until the level ends; returns the hashes after every move, the gifts, the score
	local function run(seed, timing)
		local g, lvl = H.game(FULL, LVL, { seed = seed, timing = timing })
		local hashes, gifts = {}, {}
		for _ = 1, 30 do
			if g:status().state ~= "playing" then break end
			local hint = g:hint()
			if not hint then break end
			if hint.at then
				assert_true(g:input({ type = "tap", at = hint.at }))
			else
				assert_true(g:input({ type = "swap", from = hint.from, to = hint.to }))
			end
			g:run_to_rest()
			for _, e in ipairs(g:drain_events()) do
				if e.type == "gift" then gifts[#gifts + 1] = e.special .. (e.axis or "") .. "@" .. e.x .. "," .. e.y .. ":" .. e.t end
			end
			hashes[#hashes + 1] = g:hash()
		end
		return hashes, gifts, g, lvl
	end

	it("the same seed gives the same game; gifts do appear", function()
		local total = 0
		for seed = 1, 6 do
			local h1, g1 = run(seed, "turbo")
			local h2, g2 = run(seed, "turbo")
			assert_same(h1, h2)
			assert_same(g1, g2)
			total = total + #g1
		end
		assert_true(total > 0, "no gift appeared in six games")
	end)

	it("a replay of a game with hay plays back to the same hash", function()
		for _, timing in ipairs({ "normal", "turbo" }) do
			local _, gifts, g, lvl = run(3, timing)
			assert_true(#gifts > 0)
			local rep = g:replay()
			local g2, ok, why = core.playback(lvl, rep)
			assert_true(ok, why)
			assert_eq(g2:hash(), g:hash())
		end
	end)

	it("the gift of every bale is part of the hash on a level with hay", function()
		local a = H.game(FULL, { slots = { hay(2, 2, 1, "sub") } })
		local b = H.game(FULL, { slots = { hay(2, 2, 1, "bird") } })
		local c = H.game(FULL, { slots = { hay(2, 2, 1, "sub") } })
		assert_true(a:hash() ~= b:hash())
		assert_eq(a:hash(), c:hash())
		-- a drawn gift is hashed too (the bale waits in `clear` with its gift known)
		local g = fresh(nil, 1, C.GIFT_RANDOM)
		local c2 = g:clone()
		g.s.dirty = true
		MT.search(g.s)
		c2.s.dirty = true
		MT.search(c2.s)
		assert_eq(g:hash(), c2:hash())
		local bale = H.obj_at(c2, 4, 6)
		bale.gift = bale.gift % 4 + 1
		assert_true(g:hash() ~= c2:hash())
	end)

	it("a level without hay hashes as before: the field is not written", function()
		local g = H.game(FULL, { slots = { { at = { 2, 2 }, type = "record_box", hp = 1 } } })
		local h = g:hash()
		H.obj_at(g, 3, 3).gift = C.GIFT_SUB -- (cannot happen in a game: only the layout is checked)
		assert_eq(g:hash(), h)
	end)
end)
