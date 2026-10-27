-- The move list, has_move and the expected board (5.1.2, 12.1).

local core = require("core.game")
local C = require("core.const")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
-- No legal swap anywhere: a pattern with three colours repeated along diagonals.
local DEAD = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }

local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows)
	return g
end

local function xy(m) return { m.from[1], m.from[2], m.to[1], m.to[2] } end

describe("core moves: the pair list (12.1)", function()
	it("lists the pairs by cell index, each cell with its right neighbour first, then the one below", function()
		-- three swaps: (3,1)-(4,1) makes rrr, (1,4)-(1,5) makes ggg... built on a dead pattern
		local g = fresh({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local list = g:moves()
		assert_true(#list >= 1)
		assert_same(xy(list[1]), { 3, 1, 4, 1 })
		-- the order is strictly by the index of the first cell, right before down
		local prev_i, prev_down = 0, false
		for _, m in ipairs(list) do
			local i = (m.from[2] - 1) * 6 + m.from[1]
			local down = m.to[2] > m.from[2]
			assert_true(i > prev_i or (i == prev_i and down and not prev_down), "order at " .. i)
			assert_true(m.to[1] >= m.from[1] and m.to[2] >= m.from[2], "from is the smaller cell")
			assert_eq(math.abs(m.to[1] - m.from[1]) + math.abs(m.to[2] - m.from[2]), 1)
			prev_i, prev_down = i, down
		end
	end)

	it("an empty list and has_move = false on a dead board", function()
		local g = fresh(DEAD)
		assert_same(g:moves(), {})
		assert_false(g:has_move())
	end)

	it("a pair needs two free pieces: not wired, pinned, falling, swapping, clearing or armed", function()
		local base = { "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }
		local function count(tweak)
			local g = fresh(base)
			tweak(g)
			for _, m in ipairs(g:moves()) do
				if m.from[1] == 3 and m.from[2] == 1 and m.to[1] == 4 and m.to[2] == 1 then return 1 end
			end
			return 0
		end
		assert_eq(count(function() end), 1)
		assert_eq(count(function(g) g.s.wires[3] = 1 end), 0, "wired")
		assert_eq(count(function(g) H.obj_at(g, 4, 1).pins = { 9 } end), 0, "pinned")
		for _, st in ipairs({ C.S_FALL, C.S_SWAP, C.S_CLEAR, C.S_ARMED }) do
			assert_eq(count(function(g)
				local o = H.obj_at(g, 4, 1)
				o.state = st
				if st == C.S_FALL then o.offy = 100 end
			end), 0, "state " .. st)
		end
	end)

	it("pairs with a special are always listed (also with a mic); two mics and two like pieces are not", function()
		local g = fresh({ "SMbyrg", "ybrgyb", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local set = {}
		for _, m in ipairs(g:moves()) do set[table.concat(xy(m), ",")] = true end
		assert_true(set["1,1,2,1"], "special + mic")
		assert_true(set["1,1,1,2"], "special + plain piece")
		local g2 = fresh({ "MMbyrg", "ybrgyb", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		for _, m in ipairs(g2:moves()) do
			assert_true(not (m.from[1] == 1 and m.from[2] == 1 and m.to[1] == 2 and m.to[2] == 1), "two mics")
		end
		local g3 = fresh({ "bbyrgy", "rygrbg", "gbyrgb", "ygbyrg", "rgbygr", "gbryby" })
		for _, m in ipairs(g3:moves()) do
			assert_true(not (m.from[1] == 1 and m.from[2] == 1 and m.to[1] == 2 and m.to[2] == 1), "two like pieces")
		end
	end)

	it("lists the pairs on the right edge and on the bottom edge too", function()
		local g = fresh({ "byrgby", "yyrryr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		-- (5,2) y and (6,2) r swap into r r r with (3,2) (4,2)
		local set = {}
		for _, m in ipairs(g:moves()) do set[table.concat(xy(m), ",")] = true end
		assert_true(set["5,2,6,2"], "right edge")
		local g2 = fresh({ "byrgby", "ygrbyr", "rgbyrg", "gbyrgb", "bgrgby", "ygbbyr" })
		-- column 2 reads g (row 4: b), g (row 5), y (row 6)... build the line g g g with the swap (2,5)-(2,6)
		H.obj_at(g2, 2, 3).color = C.COLOR.green
		H.obj_at(g2, 2, 4).color = C.COLOR.green
		H.obj_at(g2, 2, 5).color = C.COLOR.yellow
		H.obj_at(g2, 2, 6).color = C.COLOR.green
		local set2 = {}
		for _, m in ipairs(g2:moves()) do set2[table.concat(xy(m), ",")] = true end
		assert_true(set2["2,5,2,6"], "bottom edge")
	end)

	it("a virtual swap counts a 2x2 square as a match", function()
		local g = fresh({ "rrbygb", "rbrgyb", "gbyrgb", "ygbyrg", "rgbygr", "gbryby" })
		-- swapping (2,2) b <-> (3,2) r gives rr / rr in the corner
		local set = {}
		for _, m in ipairs(g:moves()) do set[table.concat(xy(m), ",")] = true end
		assert_true(set["2,2,3,2"])
	end)
end)

describe("core moves: has_move (12.1)", function()
	it("a free special is a move by itself; pinned, armed or swapping specials are not", function()
		local rows = { "byrgby", "yrgbyr", "rgSyrg", "gbyrgb", "byrgby", "yrgbyr" }
		-- the Sabwoofer can be swapped with every neighbour, so pin the neighbours as well
		local function with(tweak)
			local g = fresh(rows)
			tweak(g)
			return g:has_move()
		end
		assert_true(with(function() end))
		local function freeze_around(g)
			for _, d in ipairs({ { 2, 3 }, { 4, 3 }, { 3, 2 }, { 3, 4 } }) do H.obj_at(g, d[1], d[2]).pins = { 9 } end
		end
		assert_true(with(freeze_around), "the tap")
		assert_false(with(function(g) freeze_around(g); H.obj_at(g, 3, 3).pins = { 9 } end))
		assert_false(with(function(g) freeze_around(g); H.obj_at(g, 3, 3).state = C.S_ARMED end))
		assert_false(with(function(g) freeze_around(g); H.obj_at(g, 3, 3).state = C.S_SWAP end))
	end)
end)

describe("core moves: the expected board (5.1.2)", function()
	it("a falling piece counts in its target cell, a swapping pair in the cells they move to", function()
		-- (3,3) is a red piece still falling into place: the swap (2,2)-(2,3) completes r r r in row 3
		local g = fresh({ "byrgby", "yrgbyr", "ryrgyr", "gbyrgb", "byrgby", "yrgbyr" })
		g:step()
		H.board(g, { "byrgby", "yrgbyr", "ryrgyr", "gbyrgb", "byrgby", "yrgbyr" })
		-- r at (2,2)?  the picture has y at (2,2); put a red there, a red falling at (3,3), a y at (2,3)
		H.obj_at(g, 2, 2).color = C.COLOR.red
		H.obj_at(g, 3, 3).color = C.COLOR.red
		H.obj_at(g, 3, 3).state, H.obj_at(g, 3, 3).offy = C.S_FALL, 1000
		H.obj_at(g, 2, 3).color = C.COLOR.yellow
		local found = false
		for _, m in ipairs(g:moves()) do
			if m.from[1] == 2 and m.from[2] == 2 and m.to[1] == 2 and m.to[2] == 3 then found = true end
		end
		assert_true(found, "the pair counts on the expected board")
		assert_eq(g:can_swap({ 2, 2 }, { 2, 3 }), "ok")
		-- on the board of idle pieces only the swap would be a failure
		H.obj_at(g, 3, 3).state, H.obj_at(g, 3, 3).offy = C.S_IDLE, 0
		H.obj_at(g, 3, 3).color = C.COLOR.blue
		assert_eq(g:can_swap({ 2, 2 }, { 2, 3 }), "fail")
	end)

	it("pieces in a swap stand where they will be; failed swaps and locks stand where they are", function()
		local g = fresh({ "byrgby", "yrgbyr", "ryrgyr", "gbyrgb", "byrgby", "yrgbyr" })
		-- row 3: (1,3) r and (2,3) y are swapping, so the row will read y r r ...
		local a, b = H.obj_at(g, 1, 3), H.obj_at(g, 2, 3)
		a.color, b.color = C.COLOR.red, C.COLOR.yellow
		H.obj_at(g, 3, 3).color = C.COLOR.red
		H.obj_at(g, 4, 3).color = C.COLOR.yellow
		H.obj_at(g, 4, 2).color = C.COLOR.red
		a.state, a.tk, a.td = C.S_SWAP, C.TM_SWAP, 9
		b.state, b.tk, b.td = C.S_SWAP, C.TM_SWAP, 9
		g.s.swaps = { { kind = C.TM_SWAP, a = 1, from = 13, to = 14, m1 = 0, w1 = 0, m2 = 0, w2 = 0, due = 9 } }
		-- (4,2)-(4,3): r into row 3 gives r r r through the pair that is still swapping
		assert_eq(g:can_swap({ 4, 2 }, { 4, 3 }), "ok")
		-- the same pieces in a failed swap or a lock do not move: no match
		for _, tk in ipairs({ C.TM_FAIL, C.TM_LOCK }) do
			a.tk, b.tk = tk, tk
			g.s.swaps = {}
			assert_eq(g:can_swap({ 4, 2 }, { 4, 3 }), "fail", "timer " .. tk)
		end
	end)

	it("a swap that is being taken back stands where it will end, like a swap", function()
		local g = fresh({ "byrgby", "yrgbyr", "ryrgyr", "gbyrgb", "byrgby", "yrgbyr" })
		local a, b = H.obj_at(g, 1, 3), H.obj_at(g, 2, 3)
		a.color, b.color = C.COLOR.red, C.COLOR.yellow
		H.obj_at(g, 3, 3).color = C.COLOR.red
		H.obj_at(g, 4, 3).color = C.COLOR.yellow
		H.obj_at(g, 4, 2).color = C.COLOR.red
		a.state, a.tk, a.td = C.S_SWAP, C.TM_BACK, 9
		b.state, b.tk, b.td = C.S_SWAP, C.TM_BACK, 9
		g.s.swaps = { { kind = C.TM_BACK, a = 1, from = 13, to = 14, m1 = 0, w1 = 0, m2 = 0, w2 = 0, due = 9 } }
		assert_eq(g:can_swap({ 4, 2 }, { 4, 3 }), "ok", "r moves to (2,3): y r r then the r from above")
	end)

	it("pieces in clear or armed, specials, mics and blockers have no colour", function()
		local g = fresh({ "byrgby", "yrgbyr", "rrXrbg", "gbyrgb", "byrgby", "yrgbyr" })
		-- a blocker between two reds breaks the row
		H.obj_at(g, 4, 2).color = C.COLOR.red
		H.obj_at(g, 3, 2).color = C.COLOR.yellow
		assert_eq(g:can_swap({ 4, 2 }, { 4, 3 }), "fail")
	end)
end)

describe("core moves: can_swap answers like input (17.3)", function()
	it("ok and fail follow the move list on a board in motion too", function()
		local lvl = H.load(FULL)
		local g = core.new(lvl, { seed = 3 })
		g:run_to_rest()
		local m = g:moves()[1]
		g:input({ type = "swap", from = m.from, to = m.to })
		for _ = 1, 25 do
			g:step()
			local set = {}
			for _, p in ipairs(g:moves()) do set[table.concat(xy(p), ",")] = true end
			for y = 1, 6 do
				for x = 1, 6 do
					for _, d in ipairs({ { 1, 0 }, { 0, 1 } }) do
						local x2, y2 = x + d[1], y + d[2]
						local a, b = H.obj_at(g, x, y), x2 <= 6 and y2 <= 6 and H.obj_at(g, x2, y2) or nil
						if a and b and a.state == C.S_IDLE and b.state == C.S_IDLE and #a.pins == 0 and #b.pins == 0
							and g.s.wires[(y - 1) * 6 + x] == 0 and g.s.wires[(y2 - 1) * 6 + x2] == 0 then
							local key = table.concat({ x, y, x2, y2 }, ",")
							assert_eq(g:can_swap({ x, y }, { x2, y2 }) == "ok", set[key] == true, "pair " .. key)
						end
					end
				end
			end
		end
	end)
end)
