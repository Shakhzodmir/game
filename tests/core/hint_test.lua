-- Hint (12.3).

local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
local THREE_ONLY = { "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrggbg" }

local function fresh(rows, extra)
	local g = H.game(FULL, extra)
	H.board(g, rows)
	return g
end

describe("core hint (12.3)", function()
	it("prefers a swap of two specials, by combo rank", function()
		local g = fresh({ "RRrgby", "yrgbyr", "rgbyrg", "gbDSgb", "byrgby", "yrggbg" })
		assert_same(g:hint(), { from = { 3, 4 }, to = { 4, 4 } }, "disco+sub beats riff+riff")
	end)

	it("tier 3: the best special created, sub over riff", function()
		local g = fresh({ "byrgby", "yrgbyr", "rrgryg", "gbrrgb", "byrgby", "yrgbyr" })
		assert_same(g:hint(), { from = { 3, 3 }, to = { 4, 3 } }, "L of red: a sub")
	end)

	it("tier 2: a swap with goal progress beats plain swaps", function()
		local plain = fresh(THREE_ONLY, { goals = { { type = "collect", color = "purple", count = 5 } } })
		assert_same(plain:hint(), { from = { 4, 4 }, to = { 5, 4 } }, "tier 1: equal sizes, smaller index")
		-- (5,4)-(6,4) makes the only blue line
		local blue = fresh(THREE_ONLY, { goals = { { type = "collect", color = "blue", count = 5 } } })
		assert_same(blue:hint(), { from = { 5, 4 }, to = { 6, 4 } })
	end)

	it("returns a tap when only a special can move, and nil without moves", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyS" })
		H.obj_at(g, 5, 6).pins = { 1 }
		H.obj_at(g, 6, 5).pins = { 1 }
		assert_same(g:hint(), { at = { 6, 6 } })
		local none = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_eq(none:hint(), nil)
	end)

	it("ranks a special's swap above a tap of the same special", function()
		local g = fresh({ "byrgby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyS" })
		assert_same(g:hint(), { from = { 6, 5 }, to = { 6, 6 } })
	end)
end)

-- Audit C additions: every tier and tie-break of 12.3 on boards made of
-- blockers with a few isolated structures, so that only the designed moves
-- exist.

local C = require("core.const")

local W, HH = 9, 11
local PIC = {}
for y = 1, HH do PIC[y] = string.rep("#", W) end

local function blank(fill)
	local rows = {}
	for y = 1, HH do rows[y] = string.rep(fill or "X", W) end
	return rows
end

local function put(rows, x, y, ch)
	rows[y] = rows[y]:sub(1, x - 1) .. ch .. rows[y]:sub(x + 1)
end

local function stamp(rows, list)
	for _, c in ipairs(list) do put(rows, c[1], c[2], c[3]) end
end

-- Structures: (ox, oy) is the top-left corner; each returns the swap that
-- makes its effect, as {from, to}.
local STRUCT = {}

-- 3-line: r r y / r above the gap; the y that moves up may add a line of y.
function STRUCT.plain(rows, ox, oy, col, extra_y)
	stamp(rows, { { ox, oy + 1, col }, { ox + 1, oy + 1, col }, { ox + 2, oy + 1, "g" }, { ox + 2, oy, col } })
	if extra_y then stamp(rows, { { ox, oy, "g" }, { ox + 1, oy, "g" } }) end
	return { { ox + 2, oy }, { ox + 2, oy + 1 } }
end

-- 4-line: a Riff.
function STRUCT.riff(rows, ox, oy, extra_y)
	stamp(rows, { { ox, oy + 1, "r" }, { ox + 1, oy + 1, "r" }, { ox + 2, oy + 1, "y" }, { ox + 3, oy + 1, "r" }, { ox + 2, oy, "r" } })
	if extra_y then stamp(rows, { { ox, oy, "y" }, { ox + 1, oy, "y" } }) end
	return { { ox + 2, oy }, { ox + 2, oy + 1 } }
end

-- 2x2: a Bird.
function STRUCT.bird(rows, ox, oy)
	stamp(rows, { { ox, oy, "r" }, { ox + 1, oy, "r" }, { ox, oy + 1, "r" }, { ox + 1, oy + 1, "g" }, { ox + 2, oy + 1, "r" } })
	return { { ox + 1, oy + 1 }, { ox + 2, oy + 1 } }
end

-- L: a Sabwoofer.
function STRUCT.sub(rows, ox, oy)
	stamp(rows, { { ox + 2, oy, "r" }, { ox, oy + 1, "r" }, { ox + 1, oy + 1, "r" }, { ox + 2, oy + 1, "y" },
		{ ox + 2, oy + 2, "r" }, { ox + 2, oy + 3, "r" } })
	return { { ox + 2, oy }, { ox + 2, oy + 1 } }
end

-- 5-line: a Disco ball.
function STRUCT.disco(rows, ox, oy)
	stamp(rows, { { ox, oy + 1, "r" }, { ox + 1, oy + 1, "r" }, { ox + 2, oy + 1, "y" }, { ox + 3, oy + 1, "r" },
		{ ox + 4, oy + 1, "r" }, { ox + 2, oy, "r" } })
	return { { ox + 2, oy }, { ox + 2, oy + 1 } }
end

-- A special next to a plain piece that makes no line, surrounded by blockers.
local function special_swap(rows, ox, oy, letter, partner)
	stamp(rows, { { ox, oy, letter }, { ox + 1, oy, partner or "r" } })
	return { { ox, oy }, { ox + 1, oy } }
end

local function scene(rows, extra, opts)
	local g = H.game(PIC, extra, opts)
	H.board(g, rows)
	return g
end

local function same_move(hint, swap)
	assert_true(hint ~= nil and hint.from ~= nil, "a swap was expected")
	assert_same({ hint.from, hint.to }, swap)
end

describe("core hint: tier 4, combos in rank order (12.3)", function()
	local ORDER = { "DD", "DS", "DR", "DB", "SS", "RS", "BS", "BR", "RR", "BB" }
	local SPECIAL_LETTER = { D = "D", S = "S", R = "R", B = "B" }

	it("ranks disco+disco > disco+sub > disco+riff > disco+bird > sub+sub > riff+sub > bird+sub > bird+riff > riff+riff > bird+bird", function()
		for k = 1, #ORDER - 1 do
			local high, low = ORDER[k], ORDER[k + 1]
			local rows = blank()
			-- the lower rank first (smaller index), the higher one later
			local lo = special_swap(rows, 1, 1, SPECIAL_LETTER[low:sub(1, 1)], SPECIAL_LETTER[low:sub(2, 2)])
			local hi = special_swap(rows, 1, 8, SPECIAL_LETTER[high:sub(1, 1)], SPECIAL_LETTER[high:sub(2, 2)])
			local g = scene(rows)
			same_move(g:hint(), hi)
			assert_true(lo ~= nil)
		end
	end)

	it("any special pair beats a swap that makes a Disco ball", function()
		local rows = blank()
		STRUCT.disco(rows, 1, 1)
		local pair = special_swap(rows, 1, 8, "B", "B")
		same_move(scene(rows):hint(), pair)
	end)

	it("equal combos: the smaller index wins", function()
		local rows = blank()
		local first = special_swap(rows, 1, 1, "R", "S")
		special_swap(rows, 1, 8, "R", "S")
		same_move(scene(rows):hint(), first)
	end)
end)

describe("core hint: tier 3, the best special made (12.3)", function()
	it("ranks disco > sub > riff > bird whatever the index", function()
		local chain = { { "disco", "sub" }, { "sub", "riff" }, { "riff", "bird" } }
		for _, pair in ipairs(chain) do
			local rows = blank()
			STRUCT[pair[2]](rows, 1, 1)
			local hi = STRUCT[pair[1]](rows, 1, 6)
			same_move(scene(rows):hint(), hi)
		end
	end)

	it("a made special beats a plain line even later in the board", function()
		local rows = blank()
		STRUCT.plain(rows, 1, 1, "r")
		local bird = STRUCT.bird(rows, 1, 6)
		same_move(scene(rows):hint(), bird)
	end)

	it("with equal specials the bigger sum of groups wins, then the smaller index", function()
		local rows = blank()
		STRUCT.riff(rows, 1, 1)
		local big = STRUCT.riff(rows, 1, 6, true) -- a Riff and a line of three: 4 + 3
		same_move(scene(rows):hint(), big)
		local rows2 = blank()
		local first = STRUCT.riff(rows2, 1, 1)
		STRUCT.riff(rows2, 1, 6)
		same_move(scene(rows2):hint(), first)
	end)

	it("a swap of a Disco ball with a plain piece is tier 3: disco rank, most plain pieces of its colour", function()
		-- a Sub made by a swap against a Disco ball swap: the ball wins
		local rows = blank()
		STRUCT.sub(rows, 1, 1)
		local ball = special_swap(rows, 1, 8, "D", "b")
		stamp(rows, { { 6, 9, "b" }, { 7, 9, "b" } })
		local g = scene(rows)
		same_move(g:hint(), ball)
		-- two Disco swaps: the one whose colour is more frequent wins
		local rows2 = blank()
		local few = special_swap(rows2, 1, 1, "D", "b")
		local many = special_swap(rows2, 1, 8, "D", "y")
		stamp(rows2, { { 6, 3, "y" }, { 7, 3, "y" }, { 8, 3, "y" }, { 6, 4, "b" } })
		same_move(scene(rows2):hint(), many)
		assert_true(few ~= nil)
	end)
end)

describe("core hint: tier 2, progress and moves of specials (12.3)", function()
	it("a swap with progress towards a collect goal beats plain swaps and special moves", function()
		local rows = blank()
		STRUCT.plain(rows, 1, 1, "r")
		special_swap(rows, 1, 6, "S")
		local prog = STRUCT.plain(rows, 1, 8, "b")
		local g = scene(rows, { goals = { { type = "collect", color = "blue", count = 5 } } })
		same_move(g:hint(), prog)
	end)

	it("progress: a group cell on an unlit tile with the light goal open", function()
		local rows = blank()
		STRUCT.plain(rows, 1, 1, "r")
		local prog = STRUCT.plain(rows, 1, 8, "r")
		local g = scene(rows, { goals = { { type = "light" }, { type = "collect", color = "blue", count = 5 } }, floor = { { at = { 0, 0 }, hp = 1 } } })
		g.s.floor[(9 - 1) * W + 1] = 1 -- (1,9) is a cell of the group the second structure makes
		same_move(g:hint(), prog)
		g.s.goal_left[1] = 0 -- the goal is met: no progress, the first structure wins by index
		same_move(g:hint(), { { 3, 1 }, { 3, 2 } })
	end)

	it("progress: a group cell next to a record box when break record_box is open, not next to concrete", function()
		local rows = blank("K")
		STRUCT.plain(rows, 1, 1, "r")
		local prog = STRUCT.plain(rows, 1, 8, "r")
		put(rows, 1, 8, "X") -- a record box above the group cell (1,9)
		local extra = { goals = { { type = "break", item = "record_box", count = 1 } }, slots = { { at = { 8, 10 }, type = "record_box", hp = 1 } } }
		local g = scene(rows, extra)
		same_move(g:hint(), prog)
		-- a record box that is not open as a goal gives no progress
		local g2 = scene(rows, { goals = { { type = "break", item = "concrete", count = 1 } }, slots = { { at = { 8, 10 }, type = "concrete", hp = 1 } } })
		same_move(g2:hint(), { { 3, 1 }, { 3, 2 } })
	end)

	it("progress: a balloon counts only for a group of its own colour", function()
		local rows = blank("K")
		STRUCT.plain(rows, 1, 1, "b")
		local prog = STRUCT.plain(rows, 1, 8, "r")
		put(rows, 1, 8, "A") -- a red balloon above the red group (1,9): progress
		put(rows, 1, 3, "A") -- a red balloon under the blue group (1,2): no progress
		local extra = { goals = { { type = "break", item = "balloon", count = 1 } },
			slots = { { at = { 8, 10 }, type = "balloon", color = "red" } } }
		local g = scene(rows, extra)
		same_move(g:hint(), prog)
	end)

	it("progress: a group cell right under an idle mic when deliver is open", function()
		local rows = blank("K")
		STRUCT.plain(rows, 1, 1, "r")
		local prog = STRUCT.plain(rows, 1, 8, "r")
		put(rows, 1, 8, "M") -- directly above the group cell (1,9)
		local extra = { goals = { { type = "deliver", count = 1 } }, mic = { total = 1, on_board_max = 1, gap_moves = 0 } }
		local g = scene(rows, extra)
		same_move(g:hint(), prog)
	end)

	it("moves of specials come after progress, by rank sub > riff > bird; a swap before a tap of the same special", function()
		local rows = blank()
		special_swap(rows, 1, 1, "B")
		special_swap(rows, 1, 3, "R")
		local sub = special_swap(rows, 1, 8, "S")
		same_move(scene(rows):hint(), sub)
		-- without the Sabwoofer the Riff
		local rows2 = blank()
		special_swap(rows2, 1, 1, "B")
		local riff = special_swap(rows2, 1, 8, "R")
		same_move(scene(rows2):hint(), riff)
		-- a swap before a tap of the same kind: the Riff on the left has a partner, the one below stands alone
		local rows3 = blank()
		put(rows3, 5, 5, "R") -- alone: only a tap
		local with_partner = special_swap(rows3, 1, 8, "R")
		same_move(scene(rows3):hint(), with_partner)
	end)

	it("a tap of a higher-ranked special beats a swap of a lower-ranked one (rank first)", function()
		local rows = blank()
		special_swap(rows, 1, 1, "B")
		put(rows, 5, 8, "S") -- a Sabwoofer with no partner: a tap
		local g = scene(rows)
		assert_same(g:hint(), { at = { 5, 8 } })
	end)

	it("a Disco ball swapped with a microphone is the lowest special move", function()
		local rows = blank()
		stamp(rows, { { 1, 1, "D" }, { 2, 1, "M" } })
		special_swap(rows, 1, 8, "B")
		local g = scene(rows)
		same_move(g:hint(), { { 1, 8 }, { 2, 8 } })
	end)
end)

describe("core hint: tier 1 and the end (12.3)", function()
	it("a bigger sum of groups first, then the smaller index of the first cell", function()
		local rows = blank()
		STRUCT.plain(rows, 1, 1, "r")
		local big = STRUCT.plain(rows, 1, 6, "r", true)
		same_move(scene(rows):hint(), big)
		local rows2 = blank()
		local first = STRUCT.plain(rows2, 1, 1, "r")
		STRUCT.plain(rows2, 1, 6, "r")
		same_move(scene(rows2):hint(), first)
	end)

	it("returns {from, to} with from the smaller cell, a tap as {at}, nil without moves", function()
		local rows = blank()
		STRUCT.plain(rows, 1, 1, "r")
		local h = scene(rows):hint()
		assert_true(h.from[2] < h.to[2] or (h.from[2] == h.to[2] and h.from[1] < h.to[1]))
		assert_eq(scene(blank()):hint(), nil)
		local tap = blank()
		put(tap, 4, 4, "B")
		assert_same(scene(tap):hint(), { at = { 4, 4 } })
	end)

	it("ignores pinned and busy pieces and uses the expected board of falling ones", function()
		local rows = blank()
		local swap = STRUCT.plain(rows, 1, 1, "r")
		local g = scene(rows)
		local o = H.obj_at(g, swap[1][1], swap[1][2])
		o.pins = { 5 }
		assert_eq(g:hint(), nil, "its partner is pinned: no swap")
		o.pins = {}
		same_move(g:hint(), swap)
		o.state = C.S_SWAP
		assert_eq(g:hint(), nil)
	end)
end)
