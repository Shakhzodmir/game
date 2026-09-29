-- Property and soak tests: random play checked against invariants of the
-- rules after every tick, on both timings.

local core = require("core.game")
local C = require("core.const")
local M = require("core.match")
local H = require("tests.core.helper")

-- A small deterministic generator for the tests themselves.
local function lcg(seed)
	local x = seed
	return function(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return math.floor(x / 65536) % n + 1
	end
end

-- Naive grouping: every line >= 3 and every 2x2 is a cell set; sets that
-- share a cell merge until nothing changes.
local function naive_groups(col, W, Hh)
	local sets = {}
	local function add(cells)
		local t = {}
		for _, c in ipairs(cells) do t[c] = true end
		sets[#sets + 1] = t
	end
	for y = 1, Hh do
		for x = 1, W do
			local i = (y - 1) * W + x
			local c = col[i]
			if c ~= 0 then
				if x + 2 <= W and col[i + 1] == c and col[i + 2] == c then add({ i, i + 1, i + 2 }) end
				if y + 2 <= Hh and col[i + W] == c and col[i + 2 * W] == c then add({ i, i + W, i + 2 * W }) end
				if x < W and y < Hh and col[i + 1] == c and col[i + W] == c and col[i + W + 1] == c then
					add({ i, i + 1, i + W, i + W + 1 })
				end
			end
		end
	end
	local merged = true
	while merged do
		merged = false
		for a = 1, #sets do
			for b = a + 1, #sets do
				if sets[a] and sets[b] then
					local share = false
					for k in pairs(sets[b]) do
						if sets[a][k] then share = true end
					end
					if share then
						for k in pairs(sets[b]) do sets[a][k] = true end
						sets[b] = false
						merged = true
					end
				end
			end
		end
	end
	local out = {}
	for _, t in ipairs(sets) do
		if t then
			local cells = {}
			for k in pairs(t) do cells[#cells + 1] = k end
			table.sort(cells)
			out[#out + 1] = cells
		end
	end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	return out
end

local function check_invariants(g, where)
	local s = g.s
	local function fail(msg) error(where .. ": " .. msg, 2) end
	-- 6: no match among idle pieces after a tick (the dirty start aside)
	if s.tick > 0 and M.any_match(M.color_map(s), s.W, s.H) then fail("match left on the board") end
	local owned = {}
	for id, src in pairs(s.sources) do owned[id] = 0 end
	for k, r in ipairs(s.queue) do
		if r.due <= s.tick then fail("record due in the past") end
		if k > 1 then
			local p = s.queue[k - 1]
			if not (p.due < r.due or (p.due == r.due and p.seq < r.seq)) then fail("queue order") end
		end
		if r.kind >= 2 and r.kind <= 5 then
			if not owned[r.d[1]] then fail("record of a dead source") end
			owned[r.d[1]] = owned[r.d[1]] + 1
		end
	end
	for id, src in pairs(s.sources) do
		if src.nrec ~= owned[id] then fail("nrec of source " .. id) end
		if src.nrec == 0 then fail("source without records") end
	end
	local on_board, seen = 0, {}
	for i = 1, s.N do
		local id = s.slot[i]
		if s.wires[i] > 0 and (id == 0 or s.objs[id].kind ~= C.K_REGULAR) then fail("wires without a piece") end
		if id ~= 0 then
			local o = s.objs[id]
			if not o then fail("slot holds a missing object") end
			if not s.exists[i] then fail("object in a void") end
			if o.cell == i and not seen[id] then
				seen[id] = true
				if o.kind == C.K_MIC and o.state ~= C.S_CLEAR then on_board = on_board + 1 end
				if o.state == C.S_IDLE then
					if o.offx ~= 0 or o.offy ~= 0 or o.vy ~= 0 or o.delay ~= 0 or o.tk ~= 0 then fail("idle object in motion") end
				else
					if o.pins[1] then fail("pins on a non-idle object") end
				end
				if o.state == C.S_FALL and o.offy <= 0 then fail("faller without offset") end
				for _, pid in ipairs(o.pins) do
					if not s.sources[pid] then fail("pin of a dead source") end
				end
			end
		end
	end
	for id, o in pairs(s.objs) do
		if s.slot[o.cell] ~= id then fail("object " .. id .. " off the board") end
	end
	for _, sw in ipairs(s.swaps) do
		local a, b = s.objs[s.slot[sw.from]], s.objs[s.slot[sw.to]]
		if a.tk ~= sw.kind or b.tk ~= sw.kind or a.td ~= sw.due then fail("swap timer mismatch") end
	end
	if s.level.mic and on_board ~= s.on_board then fail("on_board " .. s.on_board .. " vs " .. on_board) end
	if s.moves_left < 0 then fail("negative moves") end
	for _, left in ipairs(s.goal_left) do
		if left < 0 then fail("negative goal") end
	end
	if s.queue[1] == nil and next(s.sources) ~= nil then fail("sources without a queue") end
end

local LEVELS = {
	{ rows = { "#######", "#######", "###.###", "#######", "#######", "#######", "#######" },
		extra = { moves = 25, floor = { { at = { 0, 6 }, hp = 2 }, { at = { 5, 5 }, hp = 1 } },
			overlay = { { at = { 1, 1 }, type = "wires", hp = 2 }, { at = { 4, 4 }, type = "wires", hp = 1 } },
			goals = { { type = "collect", color = "red", count = 60 }, { type = "light" } } } },
	{ rows = { "######", "######", "######", "######", "######", "######", "######" },
		extra = { moves = 20, colors = { "red", "green", "blue", "yellow" },
			slots = { { at = { 1, 3 }, type = "record_box", hp = 2 }, { at = { 3, 2 }, type = "noise" },
				{ at = { 4, 4 }, type = "column", hp = 6 } },
			goals = { { type = "break", item = "record_box", count = 1 }, { type = "collect", color = "blue", count = 80 } } } },
	{ rows = { "..####..", ".######.", "########", "########", "########", "########" },
		extra = { moves = 20, goals = { { type = "deliver", count = 3 } },
			mic = { total = 3, on_board_max = 2, gap_moves = 1 }, slots = { { at = { 3, 2 }, type = "mic" } } } },
}

describe("core property: group search", function()
	it("union-find groups equal the naive merge of lines and squares", function()
		local rnd = lcg(7)
		for _ = 1, 300 do
			local W, Hh = 6 + rnd(3) - 1, 6 + rnd(5) - 1
			local col = {}
			for i = 1, W * Hh do col[i] = rnd(4) == 1 and 0 or rnd(3) end
			local got = {}
			for _, g in ipairs(M.find_groups(col, W, Hh)) do got[#got + 1] = g.cells end
			assert_same(got, naive_groups(col, W, Hh))
			assert_eq(M.any_match(col, W, Hh), #got > 0)
		end
	end)
end)

describe("core soak: random play keeps the invariants", function()
	for li, spec in ipairs(LEVELS) do
		for _, timing in ipairs({ "normal", "turbo" }) do
			it("level " .. li .. " (" .. timing .. ")", function()
				local lvl = H.load(spec.rows, spec.extra)
				local rnd = lcg(li * 31 + #timing)
				for game_no = 1, 2 do
					local g = core.new(lvl, { seed = li * 100 + game_no, timing = timing, boosters = { "riff" }, help = game_no - 1 })
					local ticks = 0
					while g.s.state ~= C.G_COMPLETE and g.s.state ~= C.G_LOST and ticks < 3000 do
						local st = g.s.state
						if st == C.G_OUT then
							if rnd(3) == 1 and not g.s.stuck then
								g:input({ type = "continue", moves = 2, riff = rnd(2) == 1 })
							else
								g:input({ type = "give_up" })
							end
						elseif rnd(3) == 1 then
							local mv = g:moves()
							local r = rnd(10)
							if r <= 6 and #mv > 0 then
								local m = mv[rnd(#mv)]
								g:input({ type = "swap", from = m.from, to = m.to })
							elseif r == 7 then
								g:input({ type = "booster", booster = "stick", at = { rnd(g.s.W), rnd(g.s.H) } })
							elseif r == 8 then
								g:input({ type = "booster", booster = "row_light", row = rnd(g.s.H) })
							elseif r == 9 then
								g:input({ type = "tap", at = { rnd(g.s.W), rnd(g.s.H) } })
							else
								g:input({ type = "booster", booster = "remix" })
							end
						end
						g:step()
						ticks = ticks + 1
						g:drain_events()
						check_invariants(g, "level " .. li .. " game " .. game_no .. " tick " .. g.s.tick)
					end
					local _, ok, why = core.playback(lvl, g:replay())
					assert_true(ok, why)
				end
			end)
		end
	end
end)
