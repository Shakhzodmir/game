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
			assert_true(#MV.pair_list(s) >= 3, "seed " .. seed)
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

-- Boards computed by an independent implementation of section 4 (Python, written
-- from the text of 4.1-4.6, 3.2, 12.1 and 12.2): the picture, the ids by
-- ascending key (1.4.2) and the state of the init stream after the start.
describe("core start board: pinned boards from an independent implementation", function()
	local C = require("core.const")
	local DEFS = {
		A = { rows = { "#rr###", "##X###", "#g##K#", "###S##", "######", "#b####" },
			extra = { colors = { "red", "yellow", "green", "blue", "purple" }, goals = { { type = "collect", color = "green", count = 6 } },
				floor = { { at = { 1, 1 }, hp = 1 }, { at = { 4, 4 }, hp = 2 } } } },
		B = { rows = { "#######", "#######", "###.###", "#######", "#######", "#######", "#######" },
			extra = { colors = { "red", "orange", "blue", "purple" }, goals = { { type = "collect", color = "red", count = 9 } },
				overlay = { { at = { 1, 1 }, type = "wires", hp = 1 }, { at = { 5, 4 }, type = "wires", hp = 2 }, { at = { 3, 6 }, type = "wires", hp = 1 } },
				spawn_weights = { red = 1, orange = 5, blue = 2, purple = 1000 } } },
		-- not a loadable level (the pieces are walled in, 2.1.7): the presets are written by hand
		C = { rows = { "KKKKKK", "KKrrKK", "KKKKKK", "KKKKKK", "KKyyKK", "KKKKKK" },
			extra = { colors = { "red", "yellow", "green", "blue" }, goals = { { type = "collect", color = "green", count = 6 } } },
			by_hand = true },
		D = { rows = { "######", "######", "##MM##", "######", "######", "######" },
			extra = { colors = { "red", "yellow", "green", "blue", "orange" }, goals = { { type = "deliver", count = 3 }, { type = "collect", color = "red", count = 5 } },
				mic = { total = 3, on_board_max = 2, gap_moves = 4 } } },
	}
	local CASES = {
		{ "A", 7, {}, 1, 0, false, {}, { 2768690395, 2562586647, 4280806555, 1042595832, 2456455148, 1850513539 },
			{ "prrbpg", "yy*bpy", "pgbr*b", "ybgSbr", "ppbgyr", "rbrbpy" } },
		{ "A", 12, { "riff", "sub" }, 1, 0, false, {}, { 1233698292, 1860237178, 2693924776, 2362775381, 1038844094, 535731173 },
			{ "grrygb", "br*Spr", "ggbg*g", "ppgSrb", "grrygy", "yRpryb" } },
		{ "B", 3, {}, 1, 0, false, {}, { 1011976084, 3843935527, 3249752538, 1468821746, 1870757676, 1114817716 },
			{ "ppoppop", "popprpp", "rpp.ppb", "ppoppop", "poppopp", "rppoppo", "ppoppop" } },
		{ "B", 40, { "riff", "riff", "disco" }, 1, 0, false, {}, { 2721201464, 2512626965, 3655243043, 1746083095, 987881183, 169546813 },
			{ "Rpoppop", "pbppDpp", "opp.Rpo", "pprppbp", "poppopp", "oppoppo", "ppopprp" } },
		{ "C", 1, {}, 100, 3, false, {}, { 2090414332, 1526426909, 3266670167, 3516108754, 1544742923, 3060568886 },
			{ "******", "**rR**", "******", "******", "**yy**", "******" } },
		{ "C", 9, { "riff" }, 100, 3, false, {}, { 1915841061, 3985103148, 1452813733, 2512032824, 86374045, 3816039867 },
			{ "******", "**Rr**", "******", "******", "**yR**", "******" } },
		{ "D", 5, {}, 1, 0, false, {}, { 2246737864, 1607289378, 2098401651, 3280844291, 1922926956, 582921087 },
			{ "oroggo", "bbrgbo", "rrMMyg", "ygyoyb", "googoy", "bgbrbb" } },
	}

	for k, case in ipairs(CASES) do
		local name, seed, boosters, fills, shuffle, dirty, unplaced, rng, picture = (table.unpack or unpack)(case)
		it("level " .. name .. ", seed " .. seed .. ", boosters {" .. table.concat(boosters, ",") .. "}", function()
			local def = DEFS[name]
			local lvl
			if def.by_hand then
				lvl = U.deepcopy(H.load(FULL, def.extra))
				lvl.presets = {}
				for i = 1, 36 do
					local ch = string.sub(def.rows[math.floor((i - 1) / 6) + 1], (i - 1) % 6 + 1, (i - 1) % 6 + 1)
					local colors = { r = 1, y = 3 }
					lvl.presets[i] = ch == "K"
						and { cell = i, kind = C.K_BLOCKER, color = 0, special = 0, axis = 0, blocker = C.BK_CONCRETE, hp = 1 }
						or { cell = i, kind = C.K_REGULAR, color = colors[ch], special = 0, axis = 0, blocker = 0, hp = 0 }
				end
			else
				lvl = H.load(def.rows, def.extra)
			end
			local items = {}
			for j, b in ipairs(boosters) do items[j] = C.PRE_BOOSTER[b] end
			local s, report = ST.build(lvl, seed, items)
			assert_same({ report.fills, report.shuffle, report.dirty }, { fills, shuffle, dirty })
			assert_same(s.unplaced, unplaced)
			assert_same(s.rng[1], rng, "the init stream continues after the start")
			local g = setmetatable({ s = s }, getmetatable(core.new(H.load(FULL), { seed = 1 })))
			assert_same(H.picture(g), picture)
			-- 1.4.2: ids 1.. by ascending key; a gap in the picture takes none
			local want_id = 0
			for i = 1, g.s.N do
				if g.s.slot[i] ~= 0 and g.s.objs[g.s.slot[i]].cell == i then
					want_id = want_id + 1
					assert_eq(g.s.slot[i], want_id, "cell " .. i)
				end
			end
			assert_eq(g.s.next_piece_id, want_id + 1)
		end)
	end

	it("level D: two starting microphones count as released and on the board (10.4)", function()
		local lvl = H.load(DEFS.D.rows, DEFS.D.extra)
		local s = ST.build(lvl, 5, {})
		assert_same({ s.released, s.on_board, s.last_mic }, { 2, 2, 0 })
	end)
end)

describe("core start board: corners of 4.3 - 4.6 (audit A)", function()
	local C = require("core.const")
	local R = require("core.rng")

	it("a booster still finds a piece when every regular piece stands on a tile (the fallback list)", function()
		local floor = {}
		for y = 0, 5 do
			for x = 0, 5 do floor[#floor + 1] = { at = { x, y }, hp = 1 } end
		end
		local lvl = H.load(FULL, { floor = floor, goals = { { type = "light" } } })
		local g = core.new(lvl, { seed = 4, boosters = { "riff", "sub" } })
		assert_same(g.s.unplaced, {})
		local specials = {}
		for _, p in ipairs(g:pieces()) do
			if p.kind == "special" then specials[#specials + 1] = p.special .. (p.axis or "") end
		end
		table.sort(specials) -- strings
		assert_same(specials, { "riffh", "sub" })
	end)

	it("a booster avoids the colour of an open collect goal while other colours exist, then falls back to it", function()
		local lvl = H.load(FULL, {
			colors = { "red", "green", "blue", "yellow" },
			goals = { { type = "collect", color = "red", count = 3 }, { type = "collect", color = "green", count = 3 }, { type = "collect", color = "blue", count = 3 } },
		})
		for seed = 1, 12 do
			local g = core.new(lvl, { seed = seed, boosters = { "disco" } })
			for _, p in ipairs(g:pieces()) do
				if p.kind == "special" then
					local plain = core.new(lvl, { seed = seed })
					local was = plain.s.objs[p.id]
					assert_eq(was.color, C.COLOR.yellow, "seed " .. seed .. ": only yellow is not a collect colour")
				end
			end
		end
	end)

	it("a microphone in the very first cell is counted, and the gap counter starts at 0 (10.4)", function()
		local deliver = { goals = { { type = "deliver", count = 3 } }, mic = { total = 3, on_board_max = 2, gap_moves = 5 } }
		local g = H.game({ "M#####", "######", "######", "######", "######", "######" }, deliver)
		assert_same({ g.s.released, g.s.on_board, g.s.last_mic }, { 1, 1, 0 })
	end)

	it("a start without a single candidate: 100 fills fail, the shuffle finds nothing and draws nothing", function()
		local base = H.load(FULL)
		local lvl = U.deepcopy(base)
		lvl.presets = {}
		for i = 1, 36 do
			lvl.presets[i] = { cell = i, kind = C.K_BLOCKER, color = 0, special = 0, axis = 0, blocker = C.BK_CONCRETE, hp = 1 }
		end
		local s, report = ST.build(lvl, 7, {})
		assert_same({ report.fills, report.shuffle, report.dirty }, { 100, 4, false })
		assert_same(s.rng[1], R.stream(7, 1), "no free cell, no candidate: the init stream is untouched")
		assert_true(s.rest_flag)
	end)

	it("the Riff fallback of the start shuffle keeps id and label of the piece (4.3, 1.4.4)", function()
		local base = H.load(FULL)
		local lvl = U.deepcopy(base)
		lvl.presets = {}
		for i = 1, 36 do
			lvl.presets[i] = { cell = i, kind = C.K_BLOCKER, color = 0, special = 0, axis = 0, blocker = C.BK_CONCRETE, hp = 1 }
		end
		lvl.presets[1] = { cell = 1, kind = C.K_REGULAR, color = 1, special = 0, axis = 0, blocker = 0, hp = 0 }
		local s, report = ST.build(lvl, 3, {})
		assert_same({ report.fills, report.shuffle }, { 100, 3 })
		local o = s.objs[s.slot[1]]
		assert_same({ o.kind, o.special, o.axis, o.color, o.id, o.mv, o.wv, o.settle }, { C.K_SPECIAL, C.SP_RIFF, C.AX_H, 0, 1, 0, 0, 0 })
	end)
end)
