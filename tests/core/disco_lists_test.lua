-- The Disco ball (8.4) and "Colour X" (8.5) against an independent oracle:
-- the colour X (a given one, or the most frequent one with its filter), the
-- list L (who is in, in which order), the pins, the ticks of the steps, the
-- transforms and the fires, in both timings, on random boards with wires,
-- balloons, pins of other sources and pieces in odd states.
--
-- The oracle is written from the text of the specification.

local C = require("core.const")
local B = require("core.board")
local H = require("tests.core.helper")

local K_REG, K_BLK = C.K_REGULAR, C.K_BLOCKER
local IDLE = C.S_IDLE

-- Park-Miller "minimal standard" generator: x * 16807 stays below 2^46, so the
-- boards are the same on every VM and platform.
local function lcg(seed)
	local x = seed % 2147483647
	if x == 0 then x = 1 end
	return function(n)
		x = (x * 16807) % 2147483647
		return x % n + 1
	end
end

local function obj_at(s, i)
	local id = s.slot[i]
	if id == 0 then return nil end
	return s.objs[id]
end

local BASE = { "r", "o", "y", "g", "b", "p" }
local bases = {}

local function base_game(W, Hh)
	local key = W .. "x" .. Hh
	if not bases[key] then bases[key] = H.game(H.full(W, Hh)) end
	return bases[key]:clone()
end

-- A random board with the given specials: the first at a random cell, the
-- partner (if any) on a neighbouring cell. Returns the game and the cells.
local function random_game(rnd, specials)
	local W, Hh = 6 + rnd(2) - 1, 6 + rnd(2) - 1
	local g = base_game(W, Hh)
	local s = g.s
	local picture = {}
	for y = 1, Hh do
		local line = {}
		for x = 1, W do
			local r = rnd(100)
			local ch
			if r <= 70 then ch = BASE[rnd(3)] -- few colours: long lists
			elseif r <= 80 then ch = BASE[rnd(6)]
			elseif r <= 85 then ch = "A"
			elseif r <= 88 then ch = "E"
			elseif r <= 90 then ch = "X"
			elseif r <= 92 then ch = "M"
			elseif r <= 94 then ch = "R"
			else ch = BASE[rnd(6)] end
			line[x] = ch
		end
		picture[y] = line
	end
	local cx, cy = rnd(W), rnd(Hh)
	local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
	local px, py
	for _ = 1, 8 do
		local d = dirs[rnd(4)]
		px, py = cx + d[1], cy + d[2]
		if px >= 1 and px <= W and py >= 1 and py <= Hh then break end
		px, py = nil, nil
	end
	if not px then px, py = (cx % W) + 1, cy end
	picture[cy][cx] = specials[1]
	if specials[2] then picture[py][px] = specials[2] end
	local rows = {}
	for y = 1, Hh do rows[y] = table.concat(picture[y]) end
	H.board(g, rows)
	local dc = (cy - 1) * W + cx
	local pc = (py - 1) * W + px
	for i = 1, s.N do
		local o = obj_at(s, i)
		if o and o.cell == i and o.kind == K_REG and i ~= dc and i ~= pc then
			if rnd(8) == 1 then s.wires[i] = rnd(2) end
			local r = rnd(100)
			if r <= 6 then B.pin(o, 99) -- pinned by some other source
			elseif r <= 9 then B.set_state(o, C.S_CLEAR)
			elseif r <= 11 then B.set_state(o, C.S_FALL); o.offy = 100 end
		end
	end
	return g, dc, specials[2] and pc or nil
end

-- mf(): the most frequent colour of idle, unpinned regular pieces (0 = none).
local function oracle_mf(s, unwired)
	local cnt = { 0, 0, 0, 0, 0, 0 }
	for i = 1, s.N do
		local o = obj_at(s, i)
		if o and o.kind == K_REG and o.state == IDLE and #o.pins == 0 and not (unwired and s.wires[i] > 0) then
			cnt[o.color] = cnt[o.color] + 1
		end
	end
	local best, bc = 0, 0
	for c = 1, 6 do
		if cnt[c] > bc then best, bc = c, cnt[c] end
	end
	return best
end

local function cheb(W, a, b)
	local ax, ay = (a - 1) % W + 1, math.floor((a - 1) / W) + 1
	local bx, by = (b - 1) % W + 1, math.floor((b - 1) / W) + 1
	return math.max(math.abs(ax - bx), math.abs(ay - by))
end

-- The list L: {distance, cell, object}, by distance then index. `balloons`:
-- intact balloons of colour X are in (the single Disco); `unwired`: only
-- pieces without wires ("Colour X").
local function oracle_list(s, centre, X, balloons, unwired)
	local L = {}
	for i = 1, s.N do
		local o = obj_at(s, i)
		if o and o.cell == i and o.state == IDLE then
			local take = false
			if o.kind == K_REG and o.color == X and #o.pins == 0 and not (unwired and s.wires[i] > 0) then take = true end
			if balloons and o.kind == K_BLK and o.blocker == C.BK_BALLOON and o.color == X then take = true end
			if take then L[#L + 1] = { cheb(s.W, centre, i), i, o } end
		end
	end
	table.sort(L, function(a, b)
		if a[1] ~= b[1] then return a[1] < b[1] end
		return a[2] < b[2]
	end)
	return L
end

local VARIANTS = {
	disco = { "D" }, disco_x = { "D" }, color_riff = { "D", "R" }, color_sub = { "D", "S" }, color_bird = { "D", "B" },
}
local ORDER = { "disco", "disco_x", "color_riff", "color_sub", "color_bird" }

local function check_run(gno, variant, timing)
	local rnd = lcg(gno * 7907 + #variant)
	local what = string.format("game %d %s %s", gno, variant, timing)
	local g, dc, pc = random_game(rnd, VARIANTS[variant])
	local s = g.s
	local W = s.W
	if timing == "turbo" then g:set_timing("turbo") end
	local at = { (dc - 1) % W + 1, math.floor((dc - 1) / W) + 1 }
	local partner = pc and { (pc - 1) % W + 1, math.floor((pc - 1) / W) + 1 } or nil
	local single = variant == "disco" or variant == "disco_x"
	local Xarg = variant == "disco_x" and rnd(6) or 0
	local X, L
	if single then
		X = Xarg ~= 0 and Xarg or oracle_mf(s, false)
		L = X ~= 0 and oracle_list(s, dc, X, true, false) or {}
	else
		X = oracle_mf(s, true)
		L = X ~= 0 and oracle_list(s, dc, X, false, true) or {}
	end
	local sid = s.next_source_id
	H.arm(g, at, partner, 1, 1, Xarg)
	g:step() -- t0 = 1
	local ev = g:drain_events()
	local act = ev[1]
	assert_eq(act.type, "activate", what .. ": the first event")
	assert_eq(act.color, X ~= 0 and C.COLOR_NAME[X] or nil, what .. ": colour X")
	-- pins of the source (a pinned piece may match like any other: only
	-- extra pins and pins missing on pieces that are still there count)
	local pinned = {}
	for i = 1, s.N do
		local o = obj_at(s, i)
		if o and o.cell == i and B.is_pinned_by(o, sid) then pinned[i] = true end
	end
	if timing == "turbo" then
		assert_same(next(pinned), nil, what .. ": nothing stays pinned in turbo")
	else
		local want = {}
		for k = 2, #L do -- step 0 ran inside the activation
			if L[k][3].kind == K_REG then want[L[k][2]] = L[k][3] end
		end
		for i in pairs(pinned) do -- order-independent
			assert_true(want[i] ~= nil, what .. ": extra pin at " .. i)
		end
		for i, o in pairs(want) do -- order-independent
			if not pinned[i] then
				assert_true(obj_at(s, i) ~= o or o.state ~= IDLE, what .. ": missing pin at " .. i)
			end
		end
	end
	local function queued(kind)
		local out = {}
		for _, r in ipairs(s.queue) do
			if r.kind == kind and r.d[1] == sid then out[#out + 1] = r end
		end
		return out
	end
	if single then
		local rays = H.of_type(ev, "disco_ray")
		if timing == "normal" then
			local steps = queued(C.R_DISCO)
			assert_eq(#steps, math.max(#L - 1, 0), what .. ": steps queued")
			for k = 1, #steps do
				assert_same({ steps[k].due, steps[k].d[2], steps[k].d[3] }, { 1 + 2 * k, k, L[k + 1][3].id }, what .. ": step " .. k)
			end
			local own
			for _, r in ipairs(queued(C.R_HIT)) do
				if r.d[2] == dc then own = r.due end
			end
			if #L > 0 then
				assert_eq(own, 1 + 2 * #L, what .. ": own cell after the list")
				assert_eq(#rays, 1, what .. ": one ray at t0")
				assert_eq((rays[1].ty - 1) * W + rays[1].tx, L[1][2], what .. ": first ray")
			else
				assert_eq(own, nil, what .. ": an empty list hits the own cell at t0")
				assert_eq(#rays, 0, what .. ": no rays")
			end
		else
			assert_eq(#rays, #L, what .. ": rays in turbo")
			for k = 1, #L do
				assert_eq((rays[k].ty - 1) * W + rays[k].tx, L[k][2], what .. ": ray " .. k)
			end
			-- natural order (8.4.5): the steps first, the ball leaves with the last hit
			local last_ray, fired = 0, nil
			for k, e in ipairs(ev) do
				if e.type == "disco_ray" then last_ray = k end
				if e.type == "clear" and e.cause == "fired" then fired = k end
			end
			assert_true(fired ~= nil and fired > last_ray, what .. ": the ball is removed after its last step")
		end
	else
		local tr = H.of_type(ev, "transform")
		if timing == "normal" then
			assert_eq(#tr, #L >= 1 and 1 or 0, what .. ": transforms at t0")
			if #L >= 1 then assert_eq(tr[1].id, L[1][3].id, what .. ": transform 0") end
			local q = queued(C.R_TRANSFORM)
			assert_eq(#q, math.max(#L - 1, 0), what .. ": transforms queued")
			for k = 1, #q do
				assert_same({ q[k].due, q[k].d[2], q[k].d[3] }, { 1 + 2 * k, k, L[k + 1][3].id }, what .. ": transform " .. k)
			end
			local hits = queued(C.R_HIT)
			if #L >= 1 then
				assert_eq(#hits, 2, what .. ": hits on to and from")
				assert_same({ hits[1].due, hits[1].d[2], hits[2].due, hits[2].d[2] },
					{ 1 + 2 * #L, dc, 1 + 2 * #L, pc }, what .. ": to, then from, at t_end")
			end
			local fires = {}
			for _, r in ipairs(s.queue) do
				if r.kind == C.R_ACTIVATE then fires[#fires + 1] = r end
			end
			assert_eq(#fires, #L, what .. ": fires queued")
			for k = 1, #fires do
				assert_same({ fires[k].due, fires[k].d[1] }, { 1 + 2 * (#L - 1) + 3 * k, L[k][3].id }, what .. ": fire " .. k)
			end
		else
			assert_eq(#tr, #L, what .. ": transforms in turbo")
			for k = 1, #L do assert_eq(tr[k].id, L[k][3].id, what .. ": transform order") end
		end
	end
end

describe("core Disco and Colour X lists against an independent oracle (8.4, 8.5)", function()
	for _, timing in ipairs({ "normal", "turbo" }) do
		for _, variant in ipairs(ORDER) do
			it(variant .. ", " .. timing, function()
				for gno = 1, 60 do check_run(gno, variant, timing) end
			end)
		end
	end
end)
