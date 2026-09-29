-- Matches (section 6): group search with union-find, classification (6.1),
-- the cell of the new special (6.2) and group resolution (6.3).

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local H = require("core.hits")

local M = {}

local K_REGULAR, S_IDLE = C.K_REGULAR, C.S_IDLE

-- Colour of every regular idle piece (wired and pinned too), else 0.
function M.color_map(s)
	local col = {}
	local slot, objs = s.slot, s.objs
	for i = 1, s.N do
		local id = slot[i]
		local c = 0
		if id ~= 0 then
			local o = objs[id]
			if o.kind == K_REGULAR and o.state == S_IDLE then c = o.color end
		end
		col[i] = c
	end
	return col
end

-- Is there a line >= 3 or a 2x2 square of one colour through cell p?
function M.match_at(col, W, H, p)
	local c = col[p]
	if c == 0 then return false end
	local x = (p - 1) % W + 1
	local y = (p - x) / W + 1
	local n = 1
	local k = x - 1
	while k >= 1 and col[p - (x - k)] == c do n = n + 1; k = k - 1 end
	k = x + 1
	while k <= W and col[p + (k - x)] == c do n = n + 1; k = k + 1 end
	if n >= 3 then return true end
	n = 1
	k = y - 1
	while k >= 1 and col[p - (y - k) * W] == c do n = n + 1; k = k - 1 end
	k = y + 1
	while k <= H and col[p + (k - y) * W] == c do n = n + 1; k = k + 1 end
	if n >= 3 then return true end
	-- squares with p as one of the four corners
	for dy = -1, 0 do
		for dx = -1, 0 do
			local tx, ty = x + dx, y + dy
			if tx >= 1 and ty >= 1 and tx < W and ty < H then
				local t = (ty - 1) * W + tx
				if col[t] == c and col[t + 1] == c and col[t + W] == c and col[t + W + 1] == c then
					return true
				end
			end
		end
	end
	return false
end

-- Any match on the colour map?
function M.any_match(col, W, H)
	for y = 1, H do
		local run, prev = 0, 0
		for x = 1, W do
			local c = col[(y - 1) * W + x]
			if c ~= 0 and c == prev then run = run + 1 else run = 1 end
			prev = c
			if c ~= 0 and run >= 3 then return true end
		end
	end
	for x = 1, W do
		local run, prev = 0, 0
		for y = 1, H do
			local c = col[(y - 1) * W + x]
			if c ~= 0 and c == prev then run = run + 1 else run = 1 end
			prev = c
			if c ~= 0 and run >= 3 then return true end
		end
	end
	for y = 1, H - 1 do
		for x = 1, W - 1 do
			local t = (y - 1) * W + x
			local c = col[t]
			if c ~= 0 and col[t + 1] == c and col[t + W] == c and col[t + W + 1] == c then
				return true
			end
		end
	end
	return false
end

-- Groups on a colour map: array ordered by smallest cell; each group is
-- {cells (ascending), color, lines = {{axis, len, cells}}, squares = {tl}}.
function M.find_groups(col, W, H)
	local N = W * H
	local parent = {}
	local lines, squares = {}, {}
	local function find(i)
		local r = i
		while parent[r] ~= r do r = parent[r] end
		while parent[i] ~= r do
			local nx = parent[i]
			parent[i] = r
			i = nx
		end
		return r
	end
	local function union(a, b)
		if parent[a] == nil then parent[a] = a end
		if parent[b] == nil then parent[b] = b end
		local ra, rb = find(a), find(b)
		if ra ~= rb then
			if ra < rb then parent[rb] = ra else parent[ra] = rb end
		end
	end
	-- horizontal runs
	for y = 1, H do
		local x = 1
		while x <= W do
			local i = (y - 1) * W + x
			local c = col[i]
			local e = x
			if c ~= 0 then
				while e + 1 <= W and col[i + (e + 1 - x)] == c do e = e + 1 end
				local len = e - x + 1
				if len >= 3 then
					local cells = {}
					for k = x, e do
						local j = (y - 1) * W + k
						cells[#cells + 1] = j
						union(i, j)
					end
					lines[#lines + 1] = { axis = C.AX_H, len = len, cells = cells }
				end
			end
			x = e + 1
		end
	end
	-- vertical runs
	for x = 1, W do
		local y = 1
		while y <= H do
			local i = (y - 1) * W + x
			local c = col[i]
			local e = y
			if c ~= 0 then
				while e + 1 <= H and col[i + (e + 1 - y) * W] == c do e = e + 1 end
				local len = e - y + 1
				if len >= 3 then
					local cells = {}
					for k = y, e do
						local j = (k - 1) * W + x
						cells[#cells + 1] = j
						union(i, j)
					end
					lines[#lines + 1] = { axis = C.AX_V, len = len, cells = cells }
				end
			end
			y = e + 1
		end
	end
	-- squares
	for y = 1, H - 1 do
		for x = 1, W - 1 do
			local t = (y - 1) * W + x
			local c = col[t]
			if c ~= 0 and col[t + 1] == c and col[t + W] == c and col[t + W + 1] == c then
				union(t, t + 1); union(t, t + W); union(t, t + W + 1)
				squares[#squares + 1] = t
			end
		end
	end
	local groups, by_root = {}, {}
	for i = 1, N do
		if parent[i] ~= nil then
			local r = find(i)
			local g = by_root[r]
			if not g then
				g = { cells = {}, color = col[i], lines = {}, squares = {} }
				by_root[r] = g
				groups[#groups + 1] = g
			end
			g.cells[#g.cells + 1] = i
		end
	end
	for k = 1, #lines do
		local l = lines[k]
		local g = by_root[find(l.cells[1])]
		g.lines[#g.lines + 1] = l
	end
	for k = 1, #squares do
		local g = by_root[find(squares[k])]
		g.squares[#g.squares + 1] = squares[k]
	end
	return groups
end

-- Classification 6.1: special code (0 = none) and axis.
function M.classify(g)
	local has5, hasH, hasV, four = false, false, false, 0
	for k = 1, #g.lines do
		local l = g.lines[k]
		if l.len >= 5 then has5 = true end
		if l.axis == C.AX_H then hasH = true else hasV = true end
		if l.len == 4 then four = l.axis end
	end
	if has5 then return C.SP_DISCO, 0 end
	if hasH and hasV then return C.SP_SUB, 0 end
	if four ~= 0 then return C.SP_RIFF, four end
	if #g.squares > 0 then return C.SP_BIRD, 0 end
	return 0, 0
end

-- Rule 3 of 6.2 among `list`: highest settle_tick, then lower, then left.
local function best_settled(s, list)
	local W = s.W
	local best, bs, by, bx = 0, -1, 0, 0
	for k = 1, #list do
		local i = list[k]
		local o = B.get(s, i)
		local st = o.settle
		local x, y = U.xy(W, i)
		if st > bs or (st == bs and (y > by or (y == by and x < bx))) then
			best, bs, by, bx = i, st, y, x
		end
	end
	return best
end

-- Cell of the new special (6.2), 0 if no candidate. `swaps`: swaps finished
-- in this step 2 (timer swap), ascending a; nil outside step 2.
function M.special_cell(s, g, special, swaps)
	local cands, in_group = {}, {}
	for k = 1, #g.cells do
		local i = g.cells[k]
		in_group[i] = true
		if s.wires[i] == 0 then cands[#cands + 1] = i end
	end
	if #cands == 0 then return 0 end
	if swaps then
		for k = 1, #swaps do
			local sw = swaps[k]
			if in_group[sw.from] and s.wires[sw.from] == 0 then return sw.from end
			if in_group[sw.to] and s.wires[sw.to] == 0 then return sw.to end
		end
	end
	if special == C.SP_SUB then
		local inh, inv = {}, {}
		for k = 1, #g.lines do
			local l = g.lines[k]
			local t = l.axis == C.AX_H and inh or inv
			for j = 1, #l.cells do t[l.cells[j]] = true end
		end
		local both = {}
		for k = 1, #cands do
			local i = cands[k]
			if inh[i] and inv[i] then both[#both + 1] = i end
		end
		if #both > 0 then return best_settled(s, both) end
	end
	return best_settled(s, cands)
end

local function cells_xy(s, cells)
	local out = {}
	for k = 1, #cells do
		local x, y = U.xy(s.W, cells[k])
		out[k] = { x, y }
	end
	return out
end

local function praise(s, M_, W_)
	local p, word = 0, nil
	for k = 1, #C.PRAISE do
		if C.PRAISE[k][1] <= W_ then p, word = C.PRAISE[k][1], C.PRAISE[k][2] end
	end
	if p > 0 and p > (s.praise[M_] or 0) then
		s.praise[M_] = p
		E.emit(s, "praise", { act = M_, wave = W_, word = word })
	end
end

-- Resolves one group (6.3).
function M.resolve(s, g, swaps)
	local special, axis = M.classify(g)
	local scell = 0
	if special ~= 0 then scell = M.special_cell(s, g, special, swaps) end
	if scell == 0 then special, axis = 0, 0 end
	-- label (M, W)
	local Mv, Wmax = -1, -1
	for k = 1, #g.cells do
		local o = B.get(s, g.cells[k])
		if o.mv > Mv then Mv, Wmax = o.mv, o.wv
		elseif o.mv == Mv and o.wv > Wmax then Wmax = o.wv end
	end
	local Wv = Wmax + 1
	local src_m = H.new_source(s, C.SRC_MATCH, Mv, Wv, g.color)
	local src_a = H.new_source(s, C.SRC_ADJ, Mv, Wv, g.color)
	local ev = { cells = cells_xy(s, g.cells), color = C.COLOR_NAME[g.color], wave = Wv, act = Mv }
	if special ~= 0 then ev.special = C.SPECIAL_NAME[special] end
	E.emit(s, "match", ev)
	s.in_group = true
	for k = 1, #g.cells do
		local i = g.cells[k]
		H.hit(s, i, src_m, i == scell)
	end
	if special ~= 0 then
		local o = B.new_obj(s, C.K_SPECIAL, { special = special, axis = axis, mv = Mv, wv = Wv, settle = s.now })
		B.place(s, o, scell)
		local x, y = U.xy(s.W, scell)
		local sev = { id = o.id, x = x, y = y, special = C.SPECIAL_NAME[special] }
		if axis ~= 0 then sev.axis = C.AXIS_NAME[axis] end
		E.emit(s, "special_new", sev)
		local acc = H.acc()
		acc.score = C.SCORE_BONUS[special]
		H.flush(s, acc, scell)
	end
	-- adjacent hits
	local W, Hh = s.W, s.H
	local in_group = {}
	for k = 1, #g.cells do in_group[g.cells[k]] = true end
	local adj, seen = {}, {}
	for k = 1, #g.cells do
		local i = g.cells[k]
		local x, y = U.xy(W, i)
		local nb = { y > 1 and i - W or 0, x > 1 and i - 1 or 0, x < W and i + 1 or 0, y < Hh and i + W or 0 }
		for j = 1, 4 do
			local n = nb[j]
			if n ~= 0 and s.exists[n] and not in_group[n] and not seen[n] then
				seen[n] = true
				adj[#adj + 1] = n
			end
		end
	end
	table.sort(adj)
	for k = 1, #adj do H.hit(s, adj[k], src_a) end
	s.in_group = false
	praise(s, Mv, Wv)
	s.sources[src_m.id] = nil
	s.sources[src_a.id] = nil
	return scell
end

-- Full search and resolution (steps 2 and 7). Returns the set of cells of
-- the resolved groups. Clears the dirty flag.
function M.search(s, swaps)
	local col = M.color_map(s)
	local groups = M.find_groups(col, s.W, s.H)
	local resolved = {}
	for k = 1, #groups do
		local g = groups[k]
		for j = 1, #g.cells do resolved[g.cells[j]] = true end
		M.resolve(s, g, swaps)
	end
	s.dirty = false
	return resolved
end

return M
