local core = require("core.game")
local U = require("core.util")
local ST = require("core.start")
local M = require("core.match")
local MV = require("core.moves")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }

describe("core start board (section 4)", function()
	it("is deterministic for a seed and differs between seeds", function()
		local lvl = H.load(FULL)
		local a = core.new(lvl, { seed = 5 })
		local b = core.new(lvl, { seed = 5 })
		local c = core.new(lvl, { seed = 6 })
		assert_same(H.picture(a), H.picture(b))
		assert_eq(a:hash(), b:hash())
		assert_true(table.concat(H.picture(a)) ~= table.concat(H.picture(c)))
	end)

	it("has no match and at least three moves; everything idle with labels (0, 0)", function()
		local lvl = H.load(FULL, { colors = { "red", "green", "blue", "yellow" } })
		for seed = 1, 30 do
			local g = core.new(lvl, { seed = seed })
			local s = g.s
			assert_false(M.any_match(M.color_map(s), s.W, s.H), "seed " .. seed)
			assert_true(#MV.pairs(s) >= 3, "seed " .. seed)
			for _, p in ipairs(g:pieces()) do
				assert_eq(p.state, "idle")
				local o = s.objs[p.id]
				assert_eq(o.mv + o.wv + o.settle, 0)
			end
			for i = 1, s.N do assert_eq(s.vac_mv[i] + s.vac_wv[i], 0) end
			assert_true(s.rest_flag)
			assert_false(s.dirty)
			assert_true(g:is_stable())
		end
	end)

	it("fills by 4.2: no colour completes a line with the two left or upper neighbours", function()
		local lvl = H.load(FULL, { colors = { "red", "green", "blue", "yellow" } })
		for seed = 1, 20 do
			local s = core.new(lvl, { seed = seed }).s
			local function col(x, y) return s.objs[s.slot[(y - 1) * 6 + x]].color end
			for y = 1, 6 do
				for x = 1, 6 do
					local c = col(x, y)
					if x > 2 then assert_false(col(x - 1, y) == c and col(x - 2, y) == c) end
					if y > 2 then assert_false(col(x, y - 1) == c and col(x, y - 2) == c) end
					if x > 1 and y > 1 then
						assert_false(col(x - 1, y) == c and col(x, y - 1) == c and col(x - 1, y - 1) == c)
					end
				end
			end
		end
	end)

	it("keeps preset elements and numbers objects by ascending key (1.4.2)", function()
		local g = H.game({
			"#r####",
			"##X###",
			"######",
			"###S##",
			"######",
			"######",
		}, { slots = { { at = { 0, 4 }, type = "column", hp = 6 } } })
		local pieces = g:pieces()
		for k, p in ipairs(pieces) do assert_eq(p.id, k) end
		assert_eq(#pieces, 33, "36 cells, the column takes 4")
		assert_eq(g.s.next_piece_id, 34)
		local p = H.obj_at(g, 2, 1)
		assert_eq(p.id, 2)
		assert_eq(p.color, 1)
		assert_eq(H.obj_at(g, 3, 2).blocker, 1)
		assert_eq(H.obj_at(g, 4, 4).special, 2)
		local col = H.obj_at(g, 1, 5)
		assert_eq(col.blocker, 5)
		assert_eq(H.obj_at(g, 2, 6), col, "all four cells hold the column")
		assert_eq(col.hp, 6)
	end)

	it("counts starting microphones (10.4)", function()
		local deliver = { goals = { { type = "deliver", count = 3 } }, mic = { total = 3, on_board_max = 2, gap_moves = 4 } }
		local g = H.game({ "######", "##M###", "######", "######", "######", "######" }, deliver)
		assert_eq(g.s.released, 1)
		assert_eq(g.s.on_board, 1)
		assert_eq(g.s.last_mic, 0)
		local g2 = H.game(FULL, deliver)
		assert_eq(g2.s.released, 0)
		assert_eq(g2.s.last_mic, -4)
	end)
end)

describe("core start board: pre-level boosters (4.5)", function()
	it("turns regular pieces into specials, Riffs alternating h, v, h", function()
		local lvl = H.load(FULL)
		local g = core.new(lvl, { seed = 3, boosters = { "riff", "sub", "riff", "disco", "riff" } })
		local riffs, subs, discos = {}, 0, 0
		for _, p in ipairs(g:pieces()) do
			if p.special == "riff" then riffs[#riffs + 1] = p end
			if p.special == "sub" then subs = subs + 1 end
			if p.special == "disco" then discos = discos + 1 end
		end
		assert_eq(#riffs, 3)
		assert_eq(subs, 1)
		assert_eq(discos, 1)
		local axes = { h = 0, v = 0 }
		for _, p in ipairs(riffs) do axes[p.axis] = axes[p.axis] + 1 end
		assert_same(axes, { h = 2, v = 1 })
		assert_same(g.s.unplaced, {})
	end)

	it("keeps ids and labels, avoids tiles and collect colours, spends the init stream", function()
		local lvl = H.load({ "rgbyrg", "gbyrgb", "######", "######", "######", "######" }, {
			floor = { { at = { 0, 0 }, hp = 1 }, { at = { 1, 0 }, hp = 1 }, { at = { 2, 0 }, hp = 1 },
				{ at = { 3, 0 }, hp = 1 }, { at = { 4, 0 }, hp = 1 } },
			goals = { { type = "collect", color = "green", count = 5 } },
		})
		local plain = core.new(lvl, { seed = 11 })
		local g = core.new(lvl, { seed = 11, boosters = { "sub" } })
		local sub
		for _, p in ipairs(g:pieces()) do
			if p.special == "sub" then sub = p end
		end
		assert_true(sub ~= nil)
		assert_true(sub.y > 1 or sub.x == 6, "not on a tile")
		local was = plain.s.objs[sub.id]
		assert_eq(was.cell, g.s.objs[sub.id].cell, "same id, same cell")
		assert_true(was.color ~= 4, "not a collect colour")
	end)

	it("puts boosters with no candidate into unplaced", function()
		-- every regular piece is wired; four specials give the start its moves
		local overlay = {}
		for y = 0, 5 do
			for x = 0, 5 do
				if x > 1 or y > 1 then overlay[#overlay + 1] = { at = { x, y }, type = "wires", hp = 1 } end
			end
		end
		local lvl = H.load({ "SB####", "RD####", "######", "######", "######", "######" }, { overlay = overlay })
		local g = core.new(lvl, { seed = 1, boosters = { "riff", "disco" } })
		assert_same(g.s.unplaced, { 5, 7 })
	end)
end)

describe("core start board: fallback (4.3)", function()
	it("shuffles the 100th fill and may start dirty; the match resolves in tick 1 with wave 1", function()
		local base = H.load(FULL)
		local lvl = U.deepcopy(base)
		-- two isolated lines, everything else concrete: no fill can pass and
		-- no shuffle attempt can find a pair
		lvl.presets = {}
		for i = 1, 36 do
			local p = { cell = i, kind = 4, color = 0, special = 0, axis = 0, blocker = 2, hp = 1 }
			if i <= 3 then p = { cell = i, kind = 1, color = 1, special = 0, axis = 0, blocker = 0, hp = 0 } end
			if i >= 13 and i <= 15 then p = { cell = i, kind = 1, color = 4, special = 0, axis = 0, blocker = 0, hp = 0 } end
			lvl.presets[i] = p
		end
		local s, report = ST.build(lvl, 1, {})
		assert_eq(report.fills, 100)
		assert_eq(report.shuffle, 3)
		assert_true(report.dirty)
		assert_true(s.dirty)
		assert_false(s.rest_flag)
		local riffs = 0
		for i = 1, 36 do
			local o = s.objs[s.slot[i]]
			if o.special == 1 then
				riffs = riffs + 1
				assert_eq(o.axis, 1)
			end
		end
		assert_eq(riffs, 1)
		local g = setmetatable({ s = s }, getmetatable(core.new(base, { seed = 1 })))
		s.header = { seed = 1, attempt = 0, salt = 0, boosters = {}, help = 0, timing = "normal", input_lock = false }
		g:step()
		local ev = g:drain_events()
		local m = H.of_type(ev, "match")
		assert_eq(#m, 1)
		assert_eq(m[1].wave, 1)
		assert_eq(m[1].act, 0)
	end)
end)
