-- Geometry and tick offsets of the static effects (8.1, 8.2, 8.5) against an
-- oracle written from the text of the specification: the Riff (both axes),
-- the Sabwoofer, the Cross, the Triple cross, the Bass drop and the Grand
-- finale, on boards with voids and edges, in both timings.
--
-- Every hit of the effect's source is traced as (tick, cell) in the order the
-- core executes it and compared with the expected list "by normal-mode
-- offset, then by cell index" (the natural order of section 8; in turbo all
-- ticks collapse to t0 and the same order stays). The bolt and ring events,
-- the tick of the removal of the specials (the first centre hit, 7.2.4) and
-- the path pins (7.2.7) are checked as well.

local core = require("core.game")
local C = require("core.const")
local HT = require("core.hits")
local H = require("tests.core.helper")

-- R(d) of section 8 (normal mode).
local function R(d) return math.floor((15 * d + 6) / 7) end

local function cheb(x, y, xx, yy) return math.max(math.abs(xx - x), math.abs(yy - y)) end

-- Expected offsets (cell -> offset in normal mode) of the geometry `kind`
-- around (x, y), and the offset of the first hit on the centre.
local function oracle(kind, W, Hh, exists, x, y)
	local g = {}
	local function add(xx, yy, n)
		if xx >= 1 and xx <= W and yy >= 1 and yy <= Hh and exists[(yy - 1) * W + xx] then
			local i = (yy - 1) * W + xx
			if g[i] == nil or n < g[i] then g[i] = n end
		end
	end
	local first = 0
	if kind == "riff_h" or kind == "cross" then
		for xx = 1, W do add(xx, y, R(math.abs(xx - x))) end
	end
	if kind == "riff_v" or kind == "cross" then
		for yy = 1, Hh do add(x, yy, R(math.abs(yy - y))) end
	end
	if kind == "sub" or kind == "bass" then
		local rmax = kind == "sub" and 2 or 3
		for yy = y - rmax, y + rmax do
			for xx = x - rmax, x + rmax do add(xx, yy, 6 + 2 * cheb(x, y, xx, yy)) end
		end
		first = 6
	end
	if kind == "triple" then
		-- three rows leaving (x, y+k) and three columns leaving (x+k, y)
		for k = -1, 1 do
			if y + k >= 1 and y + k <= Hh then
				for xx = 1, W do add(xx, y + k, 6 + R(math.abs(xx - x))) end
			end
			if x + k >= 1 and x + k <= W then
				for yy = 1, Hh do add(x + k, yy, 6 + R(math.abs(yy - y))) end
			end
		end
		first = 6
	end
	if kind == "finale" then
		for yy = 1, Hh do
			for xx = 1, W do add(xx, yy, 24 + 2 * cheb(x, y, xx, yy)) end
		end
		first = 24
	end
	return g, first
end

-- Expected bolts {x, y, dir, offset} and rings {r, offset} (as sorted strings).
local function expected_events(kind, W, Hh, x, y)
	local bolts, rings = {}, {}
	local function bolt(bx, by, dir, off) bolts[#bolts + 1] = bx .. "," .. by .. dir .. off end
	if kind == "riff_h" then bolt(x, y, "l", 0); bolt(x, y, "r", 0) end
	if kind == "riff_v" then bolt(x, y, "u", 0); bolt(x, y, "d", 0) end
	if kind == "cross" then
		bolt(x, y, "l", 0); bolt(x, y, "r", 0); bolt(x, y, "u", 0); bolt(x, y, "d", 0)
	end
	if kind == "triple" then
		for k = -1, 1 do
			if y + k >= 1 and y + k <= Hh then bolt(x, y + k, "l", 6); bolt(x, y + k, "r", 6) end
			if x + k >= 1 and x + k <= W then bolt(x + k, y, "u", 6); bolt(x + k, y, "d", 6) end
		end
	end
	if kind == "sub" then for r = 0, 2 do rings[#rings + 1] = r .. ":" .. (6 + 2 * r) end end
	if kind == "bass" then for r = 0, 3 do rings[#rings + 1] = r .. ":" .. (6 + 2 * r) end end
	if kind == "finale" then
		local rmax = 0
		for yy = 1, Hh do
			for xx = 1, W do rmax = math.max(rmax, cheb(x, y, xx, yy)) end
		end
		for r = 0, rmax do rings[#rings + 1] = r .. ":" .. (24 + 2 * r) end
	end
	table.sort(bolts) -- strings
	return bolts, rings
end

-- Specials of the pair, the one in the centre last.
local PAIR = {
	riff_h = { "R" }, riff_v = { "V" }, sub = { "S" },
	cross = { "R", "V" }, triple = { "R", "S" }, bass = { "S", "S" }, finale = { "D", "D" },
}
local KINDS = { "riff_h", "riff_v", "sub", "cross", "triple", "bass", "finale" }

local SHAPES = {
	{ "######", "######", "######", "######", "######", "######" },
	{ "..####..", ".######.", "########", "########", "########", "########" },
	{ "######", "######", "#.####", "######", "######", "######" },
	{ "######", "##..##", "######", "######", "######", "######" },
}

-- A handful of centres per shape: first, last and four spread cells.
local function centres(shape)
	local W = #shape[1]
	local list = {}
	for i = 1, W * #shape do
		local x = (i - 1) % W + 1
		local y = (i - x) / W + 1
		if string.sub(shape[y], x, x) ~= "." then list[#list + 1] = i end
	end
	local n = #list
	local pick, seen = {}, {}
	for _, k in ipairs({ 1, n, math.floor(n / 2), math.floor(n / 3), math.floor(2 * n / 3), math.floor(n / 5) }) do
		if not seen[k] and list[k] then
			seen[k] = true
			pick[#pick + 1] = list[k]
		end
	end
	return pick
end

-- A neighbour of (x, y) that exists: right, left, down, up.
local function neighbour(shape, x, y)
	local W, Hh = #shape[1], #shape
	for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
		local ax, ay = x + d[1], y + d[2]
		if ax >= 1 and ax <= W and ay >= 1 and ay <= Hh and string.sub(shape[ay], ax, ax) ~= "." then
			return ax, ay
		end
	end
end

-- Traces the hits of the sources created while fn runs: {tick, cell, source id}.
local function with_trace(fn)
	local log = {}
	local orig = HT.hit
	HT.hit = function(s, cell, src, instant)
		log[#log + 1] = { s.now, cell, src.id }
		return orig(s, cell, src, instant)
	end
	local ok, err = pcall(fn, log)
	HT.hit = orig
	if not ok then error(err, 0) end
end

local function check_case(base, shape, kind, timing, cell)
	local W, Hh = #shape[1], #shape
	local x = (cell - 1) % W + 1
	local y = (cell - x) / W + 1
	local pair = PAIR[kind]
	local marks = { [x .. "," .. y] = pair[#pair] }
	local nx, ny
	if #pair == 2 then
		nx, ny = neighbour(shape, x, y)
		marks[nx .. "," .. ny] = pair[1]
	end
	local pic = H.rows(W, Hh, marks)
	for yy = 1, Hh do
		local line = {}
		for xx = 1, W do
			line[xx] = string.sub(shape[yy], xx, xx) == "." and "." or string.sub(pic[yy], xx, xx)
		end
		pic[yy] = table.concat(line)
	end
	local g = base:clone()
	H.board(g, pic)
	local s = g.s
	local what = string.format("%s %s centre (%d,%d)", kind, timing, x, y)
	local sid = s.next_source_id
	local exp, first = oracle(kind, W, Hh, s.exists, x, y)
	local list = {}
	for i = 1, s.N do
		if exp[i] then list[#list + 1] = { exp[i], i } end
	end
	table.sort(list, function(a, b)
		if a[1] ~= b[1] then return a[1] < b[1] end
		return a[2] < b[2]
	end)
	with_trace(function(log)
		H.arm(g, { x, y }, nx and { nx, ny } or nil)
		g:step() -- t0 = 1
		local ev = g:drain_events()
		-- path pins right after the activation (normal mode only)
		local pinned, want_pinned = {}, {}
		for i = 1, s.N do
			local o = s.objs[s.slot[i]]
			if o and o.pins[1] ~= nil then pinned[#pinned + 1] = i end
			if exp[i] and exp[i] > 0 and timing == "normal" and o and o.kind == C.K_REGULAR then want_pinned[#want_pinned + 1] = i end
		end
		assert_same(pinned, want_pinned, what .. ": path pins")
		for _ = 1, 45 do
			g:step()
			for _, e in ipairs(g:drain_events()) do ev[#ev + 1] = e end
		end
		-- the hits of the effect's source
		local got = {}
		for _, h in ipairs(log) do
			if h[3] == sid then got[#got + 1] = h end
		end
		assert_eq(#got, #list, what .. ": number of hits")
		for k = 1, #list do
			local tick = timing == "turbo" and 1 or 1 + list[k][1]
			assert_same({ got[k][1], got[k][2] }, { tick, list[k][2] }, what .. ": hit " .. k)
		end
		-- bolts and rings (in turbo every delay is 0: they carry t0)
		local bolts, rings = expected_events(kind, W, Hh, x, y)
		local gb, gr = {}, {}
		for _, e in ipairs(ev) do
			if e.type == "bolt" then gb[#gb + 1] = e.x .. "," .. e.y .. e.dir .. (e.at - 1) end
			if e.type == "ring" then gr[#gr + 1] = e.r .. ":" .. (e.at - 1) end
		end
		table.sort(gb) -- strings
		if timing == "turbo" then
			local zero = {}
			for k = 1, #bolts do zero[k] = (string.gsub(bolts[k], "%d+$", "0")) end
			table.sort(zero) -- strings
			assert_same(gb, zero, what .. ": bolts")
			local rz = {}
			for k = 1, #rings do rz[k] = (string.gsub(rings[k], ":%d+$", ":0")) end
			assert_same(gr, rz, what .. ": rings")
		else
			assert_same(gb, bolts, what .. ": bolts")
			assert_same(gr, rings, what .. ": rings")
		end
		-- the specials leave at the first hit on the centre (7.2.4)
		local fired = {}
		for _, e in ipairs(H.of_type(ev, "clear")) do
			if e.cause == "fired" then fired[#fired + 1] = e.t end
		end
		local t_first = timing == "turbo" and 1 or 1 + first
		local want_fired = {}
		for k = 1, #pair do want_fired[k] = t_first end
		assert_same(fired, want_fired, what .. ": removal of the specials")
		-- the activation opens with `activate`, then its bolts or rings, before any hit event (section 16)
		assert_eq(ev[1].type, "activate", what .. ": the first event")
		assert_eq(ev[1].x, x, what .. ": activate event")
		local lead = 2
		while ev[lead] and (ev[lead].type == "bolt" or ev[lead].type == "ring") do lead = lead + 1 end
		for k = lead, #ev do
			assert_true(ev[k].type ~= "bolt" and ev[k].type ~= "ring", what .. ": bolts and rings follow the activation at once")
		end
	end)
	assert_same(H.sources(g), {}, what .. ": sources retired")
	for i = 1, s.N do
		local o = s.objs[s.slot[i]]
		if o then assert_same(o.pins, {}, what .. ": no pins left") end
	end
end

describe("core geometry: static effects against an oracle (8.1, 8.2, 8.5)", function()
	for si, shape in ipairs(SHAPES) do
		for _, timing in ipairs({ "normal", "turbo" }) do
			it("shape " .. si .. ", " .. timing, function()
				local lvl = H.load(shape)
				local base = assert(core.new(lvl, { seed = 1, timing = timing }))
				local cs = centres(shape)
				assert_true(#cs >= 4)
				for _, kind in ipairs(KINDS) do
					for _, cell in ipairs(cs) do
						check_case(base, shape, kind, timing, cell)
					end
				end
			end)
		end
	end
end)
