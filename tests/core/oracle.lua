-- Independent oracles for sections 6 and 7 of core-rules.md (not a test file).
--
-- The oracles are written from the text of the specification, not from the
-- code: a brute-force group search (6), the classification and the cell of
-- the new special (6.1, 6.2), the labels and the events of a resolution
-- (6.3, 16), the whole hit procedure (7.1, 7.3, 7.4) and the action list
-- of the effect framework (7.2.6, 7.2.7).
--
--   local O = require("tests.core.oracle")
--   O.install()          -- wraps match.search, hits.hit and effects.run
--   ... play ...
--   O.uninstall()
--   assert_eq(#O.errors, 0)   -- one line per mismatch (at most 20)
--
-- Every wrapper takes a snapshot, lets the real function run and compares
-- the outcome (events with all their fields, queue, state, labels, vac).

local C = require("core.const")
local B = require("core.board")
local M = require("core.match")
local HT = require("core.hits")
local EF = require("core.effects")

local O = { errors = {}, stats = { search = 0, groups = 0, hits = 0, runs = 0 } }

local function copy(t)
	if type(t) ~= "table" then return t end
	local r = {}
	for k, v in pairs(t) do r[k] = copy(v) end -- order-independent
	return r
end

local function has(a, v)
	for i = 1, #a do
		if a[i] == v then return true end
	end
	return false
end

local function err(msg)
	if #O.errors < 20 then O.errors[#O.errors + 1] = msg end
end

local function dump(v)
	if type(v) ~= "table" then return tostring(v) end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end -- order-independent (sorted below)
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. dump(v[k]) end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function same(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do -- order-independent
		if not same(v, b[k]) then return false end
	end
	for k in pairs(b) do -- order-independent
		if a[k] == nil then return false end
	end
	return true
end

local function xy_of(W, c)
	return (c - 1) % W + 1, math.floor((c - 1) / W) + 1
end

-- Section 6 ------------------------------------------------------------------

-- Groups by brute force: every maximal line of 3 or more, every 2x2 square,
-- merged while two of them share a cell. Ordered by the smallest cell.
local function brute_groups(col, W, Hh)
	local sets = {}
	local function add(cells, axis)
		local t = {}
		for _, c in ipairs(cells) do t[c] = true end
		local g = { cells = t, lines = {}, squares = 0 }
		if axis then g.lines[1] = { axis = axis, len = #cells, cells = cells } else g.squares = 1 end
		sets[#sets + 1] = g
	end
	for y = 1, Hh do
		local x = 1
		while x <= W do
			local c = col[(y - 1) * W + x]
			local e = x
			if c ~= 0 then
				while e + 1 <= W and col[(y - 1) * W + e + 1] == c do e = e + 1 end
				if e - x + 1 >= 3 then
					local cells = {}
					for k = x, e do cells[#cells + 1] = (y - 1) * W + k end
					add(cells, "h")
				end
			end
			x = e + 1
		end
	end
	for x = 1, W do
		local y = 1
		while y <= Hh do
			local c = col[(y - 1) * W + x]
			local e = y
			if c ~= 0 then
				while e + 1 <= Hh and col[e * W + x] == c do e = e + 1 end
				if e - y + 1 >= 3 then
					local cells = {}
					for k = y, e do cells[#cells + 1] = (k - 1) * W + x end
					add(cells, "v")
				end
			end
			y = e + 1
		end
	end
	for y = 1, Hh - 1 do
		for x = 1, W - 1 do
			local i = (y - 1) * W + x
			local c = col[i]
			if c ~= 0 and col[i + 1] == c and col[i + W] == c and col[i + W + 1] == c then
				add({ i, i + 1, i + W, i + W + 1 }, nil)
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
					for k in pairs(sets[b].cells) do -- order-independent
						if sets[a].cells[k] then share = true end
					end
					if share then
						for k in pairs(sets[b].cells) do sets[a].cells[k] = true end -- order-independent
						for _, l in ipairs(sets[b].lines) do sets[a].lines[#sets[a].lines + 1] = l end
						sets[a].squares = sets[a].squares + sets[b].squares
						sets[b] = false
						merged = true
					end
				end
			end
		end
	end
	local out = {}
	for _, g in ipairs(sets) do
		if g then
			local cells = {}
			for k in pairs(g.cells) do cells[#cells + 1] = k end -- order-independent (sorted below)
			table.sort(cells) -- numbers
			out[#out + 1] = { cells = cells, lines = g.lines, squares = g.squares, color = col[cells[1]] }
		end
	end
	table.sort(out, function(a, b) return a.cells[1] < b.cells[1] end)
	return out
end
O.brute_groups = brute_groups

-- 6.1: kind of special and axis, by the first matching row.
local function classify(g)
	local five, hline, vline, four = false, false, false, nil
	for _, l in ipairs(g.lines) do
		if l.len >= 5 then five = true end
		if l.axis == "h" then hline = true else vline = true end
		if l.len == 4 then four = l.axis end
	end
	if five then return "disco", nil end
	if hline and vline then return "sub", nil end
	if four then return "riff", four end
	if g.squares > 0 then return "bird", nil end
	return nil, nil
end
O.classify = classify

local function snapshot_match(s, swaps)
	local snap = { col = {}, wires = {}, settle = {}, mv = {}, wv = {}, swaps = {}, W = s.W, H = s.H,
		next_id = s.next_piece_id, next_source = s.next_source_id, praise = copy(s.praise) }
	for i = 1, s.N do
		local o = B.get(s, i)
		local c = 0
		if o and o.kind == C.K_REGULAR and o.state == C.S_IDLE then c = o.color end
		snap.col[i] = c
		snap.wires[i] = s.wires[i]
		snap.settle[i] = o and o.settle or 0
		snap.mv[i] = o and o.mv or 0
		snap.wv[i] = o and o.wv or 0
	end
	for _, sw in ipairs(swaps or {}) do snap.swaps[#snap.swaps + 1] = { a = sw.a, from = sw.from, to = sw.to } end
	table.sort(snap.swaps, function(a, b) return a.a < b.a end)
	return snap
end

-- 6.2: the cell of the new special, nil if the group has no candidate.
local function special_cell(snap, g, kind)
	local cands, ing = {}, {}
	for _, c in ipairs(g.cells) do
		ing[c] = true
		if snap.wires[c] == 0 then cands[#cands + 1] = c end
	end
	if #cands == 0 then return nil end
	for _, sw in ipairs(snap.swaps) do
		if ing[sw.from] and snap.wires[sw.from] == 0 then return sw.from end
		if ing[sw.to] and snap.wires[sw.to] == 0 then return sw.to end
	end
	local pool = cands
	if kind == "sub" then
		local inh, inv = {}, {}
		for _, l in ipairs(g.lines) do
			for _, c in ipairs(l.cells) do
				if l.axis == "h" then inh[c] = true else inv[c] = true end
			end
		end
		local both = {}
		for _, c in ipairs(cands) do
			if inh[c] and inv[c] then both[#both + 1] = c end
		end
		if #both > 0 then pool = both end
	end
	local best
	for _, c in ipairs(pool) do
		if not best then
			best = c
		else
			local bx, by = xy_of(snap.W, best)
			local cx, cy = xy_of(snap.W, c)
			if snap.settle[c] > snap.settle[best]
				or (snap.settle[c] == snap.settle[best] and (cy > by or (cy == by and cx < bx))) then
				best = c
			end
		end
	end
	return best
end
O.special_cell = special_cell

local BONUS = { riff = 60, bird = 60, sub = 90, disco = 150 }
local PRAISE = { { 3, "juicy" }, { 5, "hit" }, { 7, "drive" }, { 9, "vibe" }, { 12, "legend" } }

local function check_search(s, snap, ev0, hitlog)
	O.stats.search = O.stats.search + 1
	local groups = brute_groups(snap.col, snap.W, snap.H)
	local where = "tick " .. s.tick .. " search"
	local segs = {}
	for k = ev0 + 1, #s.ev do
		local e = s.ev[k]
		if e.type == "match" then
			segs[#segs + 1] = { e }
		elseif #segs == 0 then
			err(where .. ": event " .. e.type .. " before the first match")
			return
		else
			local sg = segs[#segs]
			sg[#sg + 1] = e
		end
	end
	if #segs ~= #groups then
		err(where .. ": " .. #segs .. " match events, brute force finds " .. #groups .. " groups")
		return
	end
	local W = snap.W
	local next_id, praise, hl = snap.next_id, snap.praise, 1
	for gi, g in ipairs(groups) do
		O.stats.groups = O.stats.groups + 1
		local seg = segs[gi]
		local cells = {}
		for _, c in ipairs(g.cells) do
			local x, y = xy_of(W, c)
			cells[#cells + 1] = { x, y }
		end
		local kind, axis = classify(g)
		local sc = nil
		if kind then sc = special_cell(snap, g, kind) end
		if not sc then kind, axis = nil, nil end
		local free = false
		for _, c in ipairs(g.cells) do
			if snap.wires[c] == 0 then free = true end
		end
		-- 6.2 foresees a group without a candidate; in play a new group always holds a piece that just moved
		if not free then err(where .. " group " .. gi .. ": a group of wired pieces only") end
		local Mv, Wm = -1, -1
		for _, c in ipairs(g.cells) do
			if snap.mv[c] > Mv then
				Mv, Wm = snap.mv[c], snap.wv[c]
			elseif snap.mv[c] == Mv and snap.wv[c] > Wm then
				Wm = snap.wv[c]
			end
		end
		local Wv = Wm + 1
		local wc = where .. " group " .. gi
		local want = { t = s.now, type = "match", cells = cells, color = C.COLOR_NAME[g.color], wave = Wv, act = Mv, special = kind }
		if not same(seg[1], want) then err(wc .. ": match event " .. dump(seg[1]) .. " wanted " .. dump(want)) end
		-- the hits of the resolution: match hits by cell, then adjacent hits by cell
		local want_hits = {}
		for _, c in ipairs(g.cells) do want_hits[#want_hits + 1] = { c, C.SRC_MATCH } end
		local ing, adj, seen = {}, {}, {}
		for _, c in ipairs(g.cells) do ing[c] = true end
		for _, c in ipairs(g.cells) do
			local x, y = xy_of(W, c)
			local nb = { { x, y - 1 }, { x - 1, y }, { x + 1, y }, { x, y + 1 } }
			for _, p in ipairs(nb) do
				if p[1] >= 1 and p[1] <= W and p[2] >= 1 and p[2] <= snap.H then
					local n = (p[2] - 1) * W + p[1]
					if s.exists[n] and not ing[n] and not seen[n] then
						seen[n] = true
						adj[#adj + 1] = n
					end
				end
			end
		end
		table.sort(adj) -- numbers
		for _, c in ipairs(adj) do want_hits[#want_hits + 1] = { c, C.SRC_ADJ } end
		for k = 1, #want_hits do
			local h = hitlog[hl]
			hl = hl + 1
			if not h or h.cell ~= want_hits[k][1] or h.kind ~= want_hits[k][2] then
				err(wc .. ": hit " .. k .. " is " .. (h and (h.cell .. "/" .. h.kind) or "missing")
					.. " wanted " .. want_hits[k][1] .. "/" .. want_hits[k][2])
			elseif h.mv ~= Mv or h.wv ~= Wv or h.color ~= g.color then
				err(wc .. ": label or colour of the source of the hit on " .. h.cell)
			elseif h.instant ~= (want_hits[k][2] == C.SRC_MATCH and want_hits[k][1] == sc) then
				err(wc .. ": instant flag of the hit on " .. h.cell)
			end
		end
		local news, at = nil, nil
		for k, ev in ipairs(seg) do
			if ev.type == "special_new" then news, at = ev, k end
		end
		if kind then
			local x, y = xy_of(W, sc)
			local wn = { t = s.now, type = "special_new", id = next_id, x = x, y = y, special = kind, axis = axis }
			if not news then
				err(wc .. ": no special_new")
			else
				if not same(news, wn) then err(wc .. ": special_new " .. dump(news) .. " wanted " .. dump(wn)) end
				local sce = seg[at + 1]
				if not sce or sce.type ~= "score" or sce.delta ~= BONUS[kind] or sce.x ~= x or sce.y ~= y then
					err(wc .. ": bonus score after special_new: " .. dump(sce))
				end
			end
			next_id = next_id + 1
		elseif news then
			err(wc .. ": unexpected special_new")
		end
		local p, word = 0, nil
		for _, t in ipairs(PRAISE) do
			if t[1] <= Wv then p, word = t[1], t[2] end
		end
		local last = seg[#seg]
		if p > 0 and p > (praise[Mv] or 0) then
			praise[Mv] = p
			local wp = { t = s.now, type = "praise", act = Mv, wave = Wv, word = word }
			if not same(last, wp) then err(wc .. ": praise " .. dump(last) .. " wanted " .. dump(wp)) end
		elseif last.type == "praise" then
			err(wc .. ": unexpected praise " .. dump(last))
		end
	end
	if hitlog[hl] then err(where .. ": extra hits made during the search") end
	if s.next_piece_id ~= next_id then err(where .. ": next_piece_id " .. s.next_piece_id .. " wanted " .. next_id) end
	if s.next_source_id ~= snap.next_source + 2 * #groups then
		err(where .. ": next_source_id " .. s.next_source_id .. " wanted " .. (snap.next_source + 2 * #groups))
	end
	if s.dirty then err(where .. ": dirty after a search") end
	if s.in_group then err(where .. ": in_group left set") end
	for id, src in pairs(s.sources) do -- order-independent
		if src.kind ~= C.SRC_EFFECT and id >= snap.next_source then err(where .. ": source " .. id .. " outlived its group") end
	end
end

-- Section 7 ------------------------------------------------------------------

local function key_of(sn)
	if sn.o and sn.o.blocker == C.BK_COLUMN then return sn.o.cell end
	return sn.cell
end

local function snap_hit(s, cell, src, instant)
	local o = B.get(s, cell)
	local sn = {
		cell = cell, instant = instant, wires = s.wires[cell], floor = s.floor[cell],
		score = s.score, goal_left = copy(s.goal_left), queue = copy(s.queue),
		dirty = s.dirty, in_group = s.in_group, eom = copy(s.eom), vac = {}, W = s.W,
		now = s.now, timing = s.timing, ownobj = {}, nev = #s.ev,
		src = { id = src.id, kind = src.kind, color = src.color, all_layers = src.all_layers,
			own = copy(src.own), centre = src.centre, keys = copy(src.keys), mv = src.mv, wv = src.wv },
	}
	if o then
		sn.o = { id = o.id, kind = o.kind, state = o.state, special = o.special, blocker = o.blocker, hp = o.hp,
			color = o.color, cell = o.cell, mv = o.mv, wv = o.wv, pins = copy(o.pins) }
		if o.blocker == C.BK_COLUMN then
			sn.colfloor = {}
			for _, c in ipairs({ o.cell, o.cell + 1, o.cell + s.W, o.cell + s.W + 1 }) do sn.colfloor[c] = s.floor[c] end
		end
	end
	for _, id in ipairs(src.own) do
		local q = s.objs[id]
		if q then sn.ownobj[id] = { state = q.state, cell = q.cell, special = q.special, id = q.id } end
	end
	for i = 1, s.N do sn.vac[i] = { s.vac_mv[i], s.vac_wv[i] } end
	return sn
end

-- The hit by the text of 7.1, 7.3 and 7.4: returns the expectation and
-- whether the hit is skipped as a whole.
local function expect_hit(s, sn)
	local W = sn.W
	local exp = { evf = {}, vac = {}, wires = sn.wires, floor = sn.floor, score = 0, goals = {}, launch = false,
		dirty = sn.dirty, destroyed = false, obj_state = sn.o and sn.o.state, obj_hp = sn.o and sn.o.hp,
		colfloor = copy(sn.colfloor), label = nil, noise_flag = nil, own_states = {} }
	local src, evf, O_ = sn.src, exp.evf, sn.o
	local fired_here = false
	if src.centre == sn.cell and #src.own > 0 then
		for _, id in ipairs(src.own) do
			local q = sn.ownobj[id]
			if q and q.state == C.S_ARMED then
				local x, y = xy_of(W, q.cell)
				evf[#evf + 1] = { type = "clear", id = q.id, x = x, y = y, kind = "special",
					special = C.SPECIAL_NAME[q.special], cause = "fired" }
				exp.vac[q.cell] = { src.mv, src.wv }
				exp.own_states[id] = C.S_CLEAR
				if O_ and O_.id == id then
					fired_here = true
					exp.obj_state = C.S_CLEAR
				end
			end
		end
	end
	local dup = has(src.keys, key_of(sn))
	if dup and not src.all_layers then return exp, true end
	local slot_allowed = not dup
	local open = (O_ == nil) or (O_.state ~= C.S_IDLE) or fired_here
	local function dec_goal(gtype, param)
		local k = B.goal_index(s, gtype, param)
		if not k then return end
		local left = exp.goals[k] or sn.goal_left[k]
		if left > 0 then exp.goals[k] = left - 1 end
	end
	local hx, hy = xy_of(W, sn.cell)
	if sn.wires > 0 then
		if src.kind == C.SRC_ADJ then return exp, true end
		exp.wires = sn.wires - 1
		exp.score = exp.score + 50
		evf[#evf + 1] = { type = "hit", x = hx, y = hy, layer = "wires", hp = exp.wires }
		if exp.wires == 0 then
			if O_ then
				evf[#evf + 1] = { type = "freed", id = O_.id, x = hx, y = hy }
				exp.label = { src.mv, src.wv }
			end
			if not sn.in_group then exp.dirty = true end
		end
		if not src.all_layers then
			evf[#evf + 1] = { type = "score" }
			return exp, false
		end
		if exp.wires > 0 then slot_allowed = false end
	end
	local floors_done = false
	if slot_allowed and not open then
		if O_.kind == C.K_REGULAR then
			if src.kind ~= C.SRC_ADJ then
				exp.destroyed = true
				evf[#evf + 1] = { type = "clear", id = O_.id, x = hx, y = hy, kind = "regular",
					color = C.COLOR_NAME[O_.color], cause = (src.kind == C.SRC_MATCH) and "match" or "effect" }
				exp.vac[sn.cell] = { src.mv, src.wv }
				exp.score = exp.score + ((src.kind == C.SRC_MATCH) and (20 * src.wv) or 30)
				dec_goal(C.GOAL_COLLECT, O_.color)
				exp.obj_state = sn.instant and "removed" or C.S_CLEAR
			end
		elseif O_.kind == C.K_SPECIAL then
			if src.kind == C.SRC_EFFECT then
				exp.launch = true
				exp.obj_state = C.S_ARMED
			end
		elseif O_.kind == C.K_BLOCKER then
			local breaks
			if src.kind == C.SRC_EFFECT then
				breaks = true
			elseif src.kind == C.SRC_ADJ then
				if O_.blocker == C.BK_CONCRETE then breaks = false
				elseif O_.blocker == C.BK_BALLOON then breaks = (src.color == O_.color)
				else breaks = true end
			else
				breaks = false
			end
			if breaks then
				exp.score = exp.score + 50
				exp.obj_hp = O_.hp - 1
				if O_.blocker == C.BK_NOISE then exp.noise_flag = src.mv end
				local cells = { O_.cell }
				if O_.blocker == C.BK_COLUMN then cells = { O_.cell, O_.cell + 1, O_.cell + W, O_.cell + W + 1 } end
				local ox, oy = xy_of(W, O_.cell)
				if exp.obj_hp > 0 then
					evf[#evf + 1] = { type = "hit", x = ox, y = oy, layer = "blocker",
						item = C.BLOCKER_NAME[O_.blocker], hp = exp.obj_hp }
				else
					evf[#evf + 1] = { type = "destroy", id = O_.id, x = ox, y = oy, item = C.BLOCKER_NAME[O_.blocker] }
					exp.destroyed = true
					exp.obj_state = C.S_CLEAR
					for _, c in ipairs(cells) do exp.vac[c] = { src.mv, src.wv } end
					dec_goal(C.GOAL_BREAK, O_.blocker)
					if O_.blocker == C.BK_COLUMN and not src.all_layers then
						floors_done = true
						for _, c in ipairs(cells) do
							if sn.colfloor[c] > 0 then
								exp.colfloor[c] = sn.colfloor[c] - 1
								exp.score = exp.score + 50
								local cx, cy = xy_of(W, c)
								evf[#evf + 1] = { type = "hit", x = cx, y = cy, layer = "floor", hp = exp.colfloor[c] }
								if exp.colfloor[c] == 0 then
									evf[#evf + 1] = { type = "floor_lit", x = cx, y = cy }
									dec_goal(C.GOAL_LIGHT, 0)
								end
							end
						end
					end
				end
			end
		end
	end
	if not floors_done and sn.floor > 0 and (exp.destroyed or (src.kind == C.SRC_EFFECT and open) or src.all_layers) then
		exp.floor = sn.floor - 1
		if exp.colfloor then exp.colfloor[sn.cell] = exp.floor end
		exp.score = exp.score + 50
		evf[#evf + 1] = { type = "hit", x = hx, y = hy, layer = "floor", hp = exp.floor }
		if exp.floor == 0 then
			evf[#evf + 1] = { type = "floor_lit", x = hx, y = hy }
			dec_goal(C.GOAL_LIGHT, 0)
		end
	end
	if exp.score > 0 then evf[#evf + 1] = { type = "score" } end
	local ks = {}
	for k in pairs(exp.goals) do ks[#ks + 1] = k end -- order-independent (sorted below)
	table.sort(ks) -- numbers
	for _, k in ipairs(ks) do evf[#evf + 1] = { type = "goal", index = k, left = exp.goals[k] } end
	return exp, false
end

local function check_hit(s, sn)
	O.stats.hits = O.stats.hits + 1
	local exp, skipped = expect_hit(s, sn)
	local hx, hy = xy_of(s.W, sn.cell)
	local where = "tick " .. s.tick .. " hit at " .. hx .. "," .. hy .. " source " .. sn.src.id .. " kind " .. sn.src.kind
	local got = {}
	for k = sn.nev + 1, #s.ev do
		local e = s.ev[k]
		if e.type ~= "state" then
			local c = copy(e)
			c.t = nil
			got[#got + 1] = c
		end
	end
	local want = copy(exp.evf)
	for _, e in ipairs(want) do
		if e.type == "score" then
			e.delta, e.total, e.x, e.y = exp.score, sn.score + exp.score, hx, hy
		end
	end
	if not same(got, want) then err(where .. ": events " .. dump(got) .. " wanted " .. dump(want)) end
	if s.wires[sn.cell] ~= exp.wires then err(where .. ": wires " .. s.wires[sn.cell] .. " wanted " .. exp.wires) end
	if sn.colfloor then
		for c, v in pairs(exp.colfloor) do -- order-independent
			if s.floor[c] ~= v then err(where .. ": column floor " .. c .. " is " .. s.floor[c] .. " wanted " .. v) end
		end
	elseif s.floor[sn.cell] ~= exp.floor then
		err(where .. ": floor " .. s.floor[sn.cell] .. " wanted " .. exp.floor)
	end
	if s.score - sn.score ~= exp.score then err(where .. ": score +" .. (s.score - sn.score) .. " wanted +" .. exp.score) end
	for k = 1, #s.goal_left do
		local w = exp.goals[k] or sn.goal_left[k]
		if s.goal_left[k] ~= w then err(where .. ": goal " .. k .. " left " .. s.goal_left[k] .. " wanted " .. w) end
	end
	if sn.o and not skipped then
		local o = s.objs[sn.o.id]
		if exp.obj_state == "removed" then
			if o then err(where .. ": the object should be gone") end
		elseif o then
			if o.state ~= exp.obj_state then err(where .. ": object state " .. o.state .. " wanted " .. tostring(exp.obj_state)) end
			if o.blocker ~= 0 and o.hp ~= exp.obj_hp then err(where .. ": blocker hp " .. o.hp .. " wanted " .. tostring(exp.obj_hp)) end
			if exp.label and sn.o.kind == C.K_REGULAR then
				local nm, nw = sn.o.mv, sn.o.wv
				if exp.label[1] > nm or (exp.label[1] == nm and exp.label[2] > nw) then nm, nw = exp.label[1], exp.label[2] end
				if o.mv ~= nm or o.wv ~= nw then err(where .. ": label " .. o.mv .. "," .. o.wv .. " wanted " .. nm .. "," .. nw) end
			end
			if exp.obj_state == C.S_CLEAR and exp.destroyed and (o.tk ~= C.TM_CLEAR or o.td ~= sn.now + C.T[sn.timing].clear) then
				err(where .. ": clear timer " .. o.tk .. "/" .. o.td)
			end
			if o.state ~= C.S_IDLE and o.pins[1] then err(where .. ": pins left on a piece that is not idle") end
			if o.state == C.S_IDLE and has(o.pins, sn.src.id) then err(where .. ": own pin kept after the hit") end
		else
			err(where .. ": the object vanished")
		end
	end
	for id, st in pairs(exp.own_states) do -- order-independent
		local q = s.objs[id]
		if not q or q.state ~= st then err(where .. ": own special " .. id .. " not removed") end
		if s.sources[sn.src.id] and #s.sources[sn.src.id].own ~= 0 then err(where .. ": own not emptied") end
	end
	local qadd = #s.queue - #sn.queue
	if exp.launch then
		if qadd ~= 1 then
			err(where .. ": a launch queues one record")
		else
			local found
			for _, r in ipairs(s.queue) do
				if r.kind == C.R_ACTIVATE and r.d[1] == sn.o.id then found = r end
			end
			local T = C.T[sn.timing]
			if not found or found.due ~= sn.now + T.chain
				or not same(found.d, { sn.o.id, sn.o.cell, 0, sn.src.mv, sn.src.wv, 0 }) then
				err(where .. ": launch record " .. dump(found))
			end
		end
	elseif not skipped and qadd ~= 0 then
		err(where .. ": unexpected record")
	end
	for c, v in pairs(exp.vac) do -- order-independent
		if s.vac_mv[c] ~= v[1] or s.vac_wv[c] ~= v[2] then
			err(where .. ": vac of " .. c .. " is " .. s.vac_mv[c] .. "," .. s.vac_wv[c] .. " wanted " .. v[1] .. "," .. v[2])
		end
	end
	for i = 1, s.N do
		if exp.vac[i] == nil and (s.vac_mv[i] ~= sn.vac[i][1] or s.vac_wv[i] ~= sn.vac[i][2]) then
			err(where .. ": vac of " .. i .. " changed without a reason")
		end
	end
	if s.dirty ~= exp.dirty and not skipped then err(where .. ": dirty " .. tostring(s.dirty) .. " wanted " .. tostring(exp.dirty)) end
	local want_eom = copy(sn.eom)
	if exp.noise_flag then
		for _, e in ipairs(want_eom) do
			if e.a == exp.noise_flag then e.noise_hit = true end
		end
	end
	for k = 1, #want_eom do
		if s.eom[k] and s.eom[k].noise_hit ~= want_eom[k].noise_hit then err(where .. ": noise_hit of action " .. want_eom[k].a) end
	end
	local live = s.sources[sn.src.id]
	if live and not skipped and not has(live.keys, key_of(sn)) then err(where .. ": the key was not stored") end
end

-- Section 7.2.6, 7.2.7 -------------------------------------------------------

local function check_run(s, src, pin_path, pre)
	O.stats.runs = O.stats.runs + 1
	local where = "tick " .. s.tick .. " effect run of source " .. src.id
	local t0 = pre.now
	local list = {}
	for i, a in ipairs(pre.acts) do list[i] = { a[1], a[2], a[3], i } end
	table.sort(list, function(a, b)
		if a[1] ~= b[1] then return a[1] < b[1] end
		return a[4] < b[4]
	end)
	local seen, kept = {}, {}
	for _, a in ipairs(list) do
		if a[2] == C.R_HIT then
			local cell = a[3][2]
			local key = pre.all_layers and cell or pre.keys[cell]
			if not seen[key] then
				seen[key] = true
				kept[#kept + 1] = a
			end
		else
			kept[#kept + 1] = a
		end
	end
	local later = {}
	for _, a in ipairs(kept) do
		if a[1] > t0 then later[#later + 1] = a end
	end
	local pushed = {}
	for _, r in ipairs(s.queue) do
		if r.seq > pre.seq0 then pushed[#pushed + 1] = r end
	end
	table.sort(pushed, function(a, b) return a.seq < b.seq end)
	if #pushed < #later then
		err(where .. ": " .. #pushed .. " records queued for " .. #later .. " later actions")
	else
		local off = #pushed - #later
		for k = 1, #later do
			local r, a = pushed[off + k], later[k]
			if r.due ~= a[1] or r.kind ~= a[2] or not same(r.d, a[3]) then
				err(where .. ": queued record " .. k .. " is " .. dump({ r.due, r.kind, r.d }) .. " wanted " .. dump({ a[1], a[2], a[3] }))
			end
			if k > 1 and pushed[off + k].seq ~= pushed[off + k - 1].seq + 1 then
				err(where .. ": the queued records do not have consecutive seq")
			end
		end
	end
	local imm, only_hits = {}, true
	for _, a in ipairs(kept) do
		if a[1] <= t0 then
			if a[2] == C.R_HIT then imm[#imm + 1] = a[3][2] else only_hits = false end
		end
	end
	if only_hits then
		local got = {}
		for _, h in ipairs(pre.hits) do
			if h.src == src.id then got[#got + 1] = h.cell end
		end
		if not same(got, imm) then err(where .. ": immediate hits " .. dump(got) .. " wanted " .. dump(imm)) end
	end
	local expect_pinned = {}
	if pin_path then
		for _, a in ipairs(kept) do
			if a[2] == C.R_HIT and a[1] > t0 then
				local p = pre.cells[a[3][2]]
				if p and p.state == C.S_IDLE and p.movable then expect_pinned[p.id] = true end
			end
		end
	end
	for i = 1, s.N do
		local o = B.get(s, i)
		if o and o.cell == i then
			local now_pinned = has(o.pins, src.id)
			if expect_pinned[o.id] and not now_pinned then err(where .. ": the piece in cell " .. i .. " is not pinned") end
			if now_pinned and not pre.pinned_before[o.id] and not expect_pinned[o.id] and pin_path then
				err(where .. ": the piece in cell " .. i .. " is pinned without a later hit")
			end
		end
	end
end

-- Installation -----------------------------------------------------------------

local orig

function O.install()
	if orig then O.uninstall() end
	O.errors = {}
	O.stats = { search = 0, groups = 0, hits = 0, runs = 0 }
	orig = { search = M.search, hit = HT.hit, run = EF.run }
	local hitlog, runlog = nil, nil
	M.search = function(s, swaps)
		local snap = snapshot_match(s, swaps)
		local ev0 = #s.ev
		hitlog = {}
		local r = orig.search(s, swaps)
		local log = hitlog
		hitlog = nil
		check_search(s, snap, ev0, log)
		return r
	end
	HT.hit = function(s, cell, src, instant)
		local sn = snap_hit(s, cell, src, instant)
		if hitlog then
			hitlog[#hitlog + 1] = { cell = cell, kind = src.kind, mv = src.mv, wv = src.wv, color = src.color,
				instant = instant and true or false }
		end
		if runlog then runlog[#runlog + 1] = { src = src.id, cell = cell } end
		orig.hit(s, cell, src, instant)
		check_hit(s, sn)
	end
	EF.run = function(s, src, acts, pin_path)
		local pre = { acts = {}, seq0 = s.seq, all_layers = src.all_layers, keys = {}, cells = {}, hits = {},
			now = s.now, pinned_before = {} }
		for i, a in ipairs(acts) do pre.acts[i] = { a[1], a[2], copy(a[3]) } end
		for i = 1, s.N do
			pre.keys[i] = B.key(s, i)
			local o = B.get(s, i)
			if o then
				pre.cells[i] = { id = o.id, state = o.state, movable = B.is_movable(s, o) }
				if has(o.pins, src.id) then pre.pinned_before[o.id] = true end
			end
		end
		local saved = runlog
		runlog = pre.hits
		orig.run(s, src, acts, pin_path)
		runlog = saved
		check_run(s, src, pin_path, pre)
	end
end

function O.uninstall()
	if orig then
		M.search, HT.hit, EF.run = orig.search, orig.hit, orig.run
		orig = nil
	end
end

return O
