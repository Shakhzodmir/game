-- Oracles for sections 2, 4 and 5.1 of core-rules.md (audit A), written from the
-- text of the specification and independent of core/level.lua, core/level_schema.lua,
-- core/start.lua, core/moves.lua and core/gravity.lua. Only core/rng.lua is shared
-- (it has its own known-answer tests against a Python implementation).
--
--   O.validate(raw)                  -> stage, rules   stage 0 = passes 2.0-2.1.9, 1 = schema (2.1.1),
--                                                      2 = 2.1.2-2.1.6, 2.1.8 (static), 2.1.9, 3 = 2.1.7 and
--                                                      2.1.8 (segment bottoms); rules = {["2.1.x"] = true}
--   O.empties(raw, keep_fixed)       -> { ["x,y"] = true } zero-based cells left empty on B0 (keep_fixed)
--                                       or B1; nil if the board does not settle within 1000 ticks
--   O.start(raw, seed, boosters)     -> the start board of section 4 for a level table (no validation)
--   O.swap(g, fx, fy, tx, ty)        -> "ok" | "fail" | "reject": what a swap does now (5.0, 5.1.1, 5.1.2)
--
-- `raw` is the level table as it is read from the JSON file (zero-based coordinates).
-- The oracles read the state of a live game (g.s) for the swap only.

local R = require("core.rng")

local O = {}

local COLORS = { "red", "orange", "yellow", "green", "blue", "purple" }
local CODE = { red = 1, orange = 2, yellow = 3, green = 4, blue = 5, purple = 6 }
local UNIT = 3600

-- tables ---------------------------------------------------------------------------

local function isint(v)
	return type(v) == "number" and v == math.floor(v) and v >= -9007199254740992 and v <= 9007199254740992
end

-- A table is a list if its keys are exactly 1..n; an object if all keys are strings.
-- The empty table is both.
local function as_list(v)
	if type(v) ~= "table" then return nil end
	local n = 0
	for _ in pairs(v) do n = n + 1 end
	for i = 1, n do
		if v[i] == nil then return nil end
	end
	return v, n
end

local function as_obj(v)
	if type(v) ~= "table" then return nil end
	for k in pairs(v) do
		if type(k) ~= "string" then return nil end
	end
	return v
end

local function is_at(v)
	local l, n = as_list(v)
	return l ~= nil and n == 2 and isint(l[1]) and isint(l[2])
end

local function in_set(v, set)
	for i = 1, #set do
		if set[i] == v then return true end
	end
	return false
end

-- 2.0 / 2.1.1 ----------------------------------------------------------------------

local ROOT = { "id", "version", "size", "moves", "difficulty", "colors", "goals", "cells", "spawners", "exits",
	"floor", "overlay", "slots", "mic", "spawn_weights" }
local GOALKEYS = {
	collect = { "type", "color", "count" }, ["break"] = { "type", "item", "count" },
	light = { "type" }, deliver = { "type", "count" },
}
-- slot type -> {field, lo, hi} | {field} | false (no field)
local SLOTF = {
	record_box = { "hp", 1, 3 }, concrete = { "hp", 1, 2 }, noise = false, balloon = { "color" }, column = { "hp", 6, 12 },
	riff = { "axis" }, sub = false, bird = false, disco = false, piece = { "color" }, mic = false,
}
local BLOCKERS = { "record_box", "concrete", "noise", "balloon", "column" }

local function only_keys(t, allowed)
	for k in pairs(t) do
		if not in_set(k, allowed) then return false end
	end
	return true
end

local function is_color(v) return type(v) == "string" and CODE[v] ~= nil end

local function stage1(L)
	local o = as_obj(L)
	if o == nil then return false end
	local ok = true
	if not only_keys(o, ROOT) then ok = false end
	for _, k in ipairs({ "id", "version" }) do
		if not (isint(o[k]) and o[k] >= 1) then ok = false end
	end
	local W, H
	local sz, n = as_list(o.size)
	if sz and n == 2 and isint(sz[1]) and isint(sz[2]) then
		W, H = sz[1], sz[2]
		if W < 6 or W > 9 or H < 6 or H > 11 then ok = false end
	else
		ok = false
	end
	if not (isint(o.moves) and o.moves >= 5 and o.moves <= 60) then ok = false end
	if not (type(o.difficulty) == "string" and in_set(o.difficulty, { "easy", "medium", "hard", "super_hard" })) then ok = false end
	local cl, cn = as_list(o.colors)
	if cl and cn >= 4 and cn <= 6 then
		local seen = {}
		for i = 1, cn do
			local c = cl[i]
			if not is_color(c) then ok = false
			elseif seen[c] then ok = false
			else seen[c] = true end
		end
	else
		ok = false
	end
	local gl, gn = as_list(o.goals)
	local deliver
	if gl and gn >= 1 and gn <= 3 then
		local seen = {}
		for i = 1, gn do
			local go = as_obj(gl[i])
			if go == nil or type(go.type) ~= "string" or GOALKEYS[go.type] == nil then
				ok = false
			else
				local t = go.type
				if not only_keys(go, GOALKEYS[t]) then ok = false end
				if t == "collect" and not is_color(go.color) then ok = false end
				if t == "break" and type(go.item) ~= "string" then ok = false end
				if t ~= "light" and not (isint(go.count) and go.count >= 1) then ok = false end
				local key = t .. ":" .. tostring(go.color or go.item or "")
				if seen[key] then ok = false end
				seen[key] = true
				if t == "deliver" then deliver = go end
			end
		end
	else
		ok = false
	end
	local cells, cn2 = as_list(o.cells)
	if cells and H and cn2 == H then
		for y = 1, H do
			local row = cells[y]
			if not (type(row) == "string" and #row == W and not string.find(row, "[^#%.]")) then ok = false end
		end
	else
		ok = false
	end
	for _, pair in ipairs({ { "spawners", "top" }, { "exits", "bottom" } }) do
		local v = o[pair[1]]
		if v ~= nil and v ~= pair[2] then
			local l, n = as_list(v)
			if l == nil then
				ok = false
			else
				for i = 1, n do
					if not is_at(l[i]) then ok = false end
				end
			end
		end
	end
	for _, k in ipairs({ "floor", "overlay", "slots" }) do
		local v = o[k]
		if v ~= nil then
			local l, n = as_list(v)
			if l == nil then
				ok = false
			else
				for i = 1, n do
					local io = as_obj(l[i])
					if io == nil or not is_at(io.at) then
						ok = false
					elseif k == "floor" then
						if not only_keys(io, { "at", "hp" }) then ok = false end
						if not (isint(io.hp) and io.hp >= 1 and io.hp <= 2) then ok = false end
					elseif k == "overlay" then
						if not only_keys(io, { "at", "type", "hp" }) then ok = false end
						if io.type ~= "wires" then ok = false end
						if not (isint(io.hp) and io.hp >= 1 and io.hp <= 2) then ok = false end
					else
						local t = io.type
						if not (type(t) == "string" and SLOTF[t] ~= nil) then
							ok = false
						else
							local allowed = { "at", "type" }
							local f = SLOTF[t]
							if f then
								allowed[#allowed + 1] = f[1]
								if f[1] == "hp" then
									if not (isint(io.hp) and io.hp >= f[2] and io.hp <= f[3]) then ok = false end
								elseif f[1] == "color" then
									if not is_color(io.color) then ok = false end
								else
									if io.axis ~= "h" and io.axis ~= "v" then ok = false end
								end
							end
							if not only_keys(io, allowed) then ok = false end
						end
					end
				end
			end
		end
	end
	if o.mic ~= nil then
		local m = as_obj(o.mic)
		if m == nil then
			ok = false
		else
			if not only_keys(m, { "total", "on_board_max", "gap_moves" }) then ok = false end
			if not (isint(m.total) and m.total >= 1) then ok = false end
			if not (isint(m.on_board_max) and m.on_board_max >= 1) then ok = false end
			if not (isint(m.gap_moves) and m.gap_moves >= 0) then ok = false end
			if deliver and isint(deliver.count) and m.total ~= deliver.count then ok = false end
		end
	elseif deliver then
		ok = false
	end
	if o.spawn_weights ~= nil then
		local w = as_obj(o.spawn_weights)
		if w == nil then
			ok = false
		elseif cl then
			for k, v in pairs(w) do
				if not in_set(k, cl) then ok = false end
				if not (isint(v) and v >= 1 and v <= 1000) then ok = false end
			end
			for i = 1, cn do
				if type(cl[i]) == "string" and w[cl[i]] == nil then ok = false end
			end
		end
	end
	return ok
end

-- 2.1.2 - 2.1.6, 2.1.8 (static), 2.1.9 -------------------------------------------------

local function stage2(L)
	local W, H = L.size[1], L.size[2]
	local cells = L.cells
	local function exists(x, y) return x >= 0 and x < W and y >= 0 and y < H and string.sub(cells[y + 1], x + 1, x + 1) == "#" end
	local function key(x, y) return x .. "," .. y end
	local rules = {}
	local colors = {}
	for i = 1, #L.colors do colors[L.colors[i]] = true end
	local deliver = false
	for i = 1, #L.goals do
		if L.goals[i].type == "deliver" then deliver = true end
	end
	-- spawners
	local spawn = {}
	local sp = L.spawners
	if sp == nil or sp == "top" then
		for x = 0, W - 1 do
			for y = 0, H - 1 do
				if exists(x, y) then spawn[key(x, y)] = { x, y }; break end
			end
		end
	else
		for i = 1, #sp do
			local x, y = sp[i][1], sp[i][2]
			if not exists(x, y) then rules["2.1.2"] = true
			elseif spawn[key(x, y)] then rules["2.1.2"] = true
			else spawn[key(x, y)] = { x, y } end
		end
	end
	for _, p in pairs(spawn) do
		if exists(p[1], p[2] - 1) then rules["2.1.2"] = true end
	end
	-- exits
	local exits, n_exits = {}, 0
	local ex = L.exits
	if ex == nil or ex == "bottom" then
		for x = 0, W - 1 do
			for y = 0, H - 1 do
				if exists(x, y) and not exists(x, y + 1) then exits[key(x, y)] = true; n_exits = n_exits + 1 end
			end
		end
	else
		for i = 1, #ex do
			local x, y = ex[i][1], ex[i][2]
			if not exists(x, y) then rules["2.1.2"] = true
			elseif exits[key(x, y)] then rules["2.1.2"] = true
			else exits[key(x, y)] = true; n_exits = n_exits + 1 end
		end
	end
	-- floor and overlay
	local tiles, n_tiles, wires, n_wires = {}, 0, {}, 0
	for _, f in ipairs(L.floor or {}) do
		local x, y = f.at[1], f.at[2]
		if not exists(x, y) then rules["2.1.2"] = true
		elseif tiles[key(x, y)] then rules["2.1.2"] = true
		else tiles[key(x, y)] = true; n_tiles = n_tiles + 1 end
	end
	for _, f in ipairs(L.overlay or {}) do
		local x, y = f.at[1], f.at[2]
		if not exists(x, y) then rules["2.1.2"] = true
		elseif wires[key(x, y)] then rules["2.1.2"] = true
		else wires[key(x, y)] = true; n_wires = n_wires + 1 end
	end
	-- slots
	local occupied, presets = {}, {}
	for _, s in ipairs(L.slots or {}) do
		local x, y = s.at[1], s.at[2]
		local cl = { { x, y } }
		if s.type == "column" then cl = { { x, y }, { x + 1, y }, { x, y + 1 }, { x + 1, y + 1 } } end
		local good = exists(x, y)
		if good then
			for _, c in ipairs(cl) do
				if not exists(c[1], c[2]) then good = false end
			end
		end
		if good then
			for _, c in ipairs(cl) do
				if occupied[key(c[1], c[2])] then good = false end
			end
		end
		if not good then
			rules["2.1.2"] = true
		else
			for _, c in ipairs(cl) do occupied[key(c[1], c[2])] = s end
			presets[#presets + 1] = s
			if (s.type == "balloon" or s.type == "piece") and not colors[s.color] then rules["2.1.4"] = true end
			if s.type == "mic" and deliver and exits[key(x, y)] then rules["2.1.8"] = true end
		end
	end
	-- 2.1.3
	for k in pairs(wires) do
		local s = occupied[k]
		if s ~= nil and s.type ~= "piece" then rules["2.1.3"] = true end
	end
	-- 2.1.5
	local counts = { record_box = 0, concrete = 0, noise = 0, balloon = 0, column = 0 }
	local n_mics = 0
	for _, s in ipairs(presets) do
		if counts[s.type] then counts[s.type] = counts[s.type] + 1 end
		if s.type == "mic" then n_mics = n_mics + 1 end
	end
	local has_mic_block = L.mic ~= nil
	for _, g in ipairs(L.goals) do
		if g.type == "collect" and not colors[g.color] then rules["2.1.5"] = true
		elseif g.type == "break" then
			if counts[g.item] == nil then rules["2.1.5"] = true
			elseif g.count > counts[g.item] then rules["2.1.5"] = true end
		elseif g.type == "light" and n_tiles == 0 then rules["2.1.5"] = true
		elseif g.type == "deliver" and (not has_mic_block or n_exits == 0) then rules["2.1.5"] = true end
	end
	-- 2.1.6
	local el = 0
	for _, b in ipairs(BLOCKERS) do
		if counts[b] > 0 then el = el + 1 end
	end
	if n_tiles > 0 then el = el + 1 end
	if n_wires > 0 then el = el + 1 end
	if deliver or has_mic_block or n_mics > 0 then el = el + 1 end
	if el > 3 then rules["2.1.6"] = true end
	-- 2.1.8, static part
	if not deliver then
		if has_mic_block then rules["2.1.8"] = true end
		if n_mics > 0 then rules["2.1.8"] = true end
	else
		for k in pairs(exits) do
			if spawn[k] then rules["2.1.8"] = true end
		end
		local m = L.mic
		if m ~= nil and n_mics > math.min(m.on_board_max, m.total) then rules["2.1.8"] = true end
	end
	-- 2.1.9
	local grid = {}
	for _, s in ipairs(presets) do
		if s.type == "piece" then grid[key(s.at[1], s.at[2])] = s.color end
	end
	for k, c in pairs(grid) do
		local x, y = string.match(k, "^(-?%d+),(-?%d+)$")
		x, y = tonumber(x), tonumber(y)
		local function g(a, b) return grid[key(a, b)] end
		if g(x + 1, y) == c and g(x + 2, y) == c then rules["2.1.9"] = true end
		if g(x, y + 1) == c and g(x, y + 2) == c then rules["2.1.9"] = true end
		if g(x + 1, y) == c and g(x, y + 1) == c and g(x + 1, y + 1) == c then rules["2.1.9"] = true end
	end
	return rules, exits
end

-- 2.1.7: B0 and B1 -------------------------------------------------------------------

-- Steps 4-6 of the tick in turbo mode with colourless pieces (10.1, 10.2), from tick 1.
function O.empties(L, keep_fixed)
	local W, H = L.size[1], L.size[2]
	local ex = {}
	for y = 1, H do
		ex[y] = {}
		for x = 1, W do ex[y][x] = string.sub(L.cells[y], x, x) == "#" end
	end
	local slot = {}
	for y = 1, H do slot[y] = {} end -- nil | "I" immovable | "P" piece at rest | "F" falling
	local offy = {}
	local function ok_cell(x, y) return x >= 1 and x <= W and y >= 1 and y <= H and ex[y][x] end
	if keep_fixed then
		for _, s in ipairs(L.slots or {}) do
			local x, y = s.at[1] + 1, s.at[2] + 1
			if s.type == "record_box" or s.type == "concrete" or s.type == "noise" or s.type == "balloon" then
				slot[y][x] = "I"
			elseif s.type == "column" then
				for dx = 0, 1 do
					for dy = 0, 1 do slot[y + dy][x + dx] = "I" end
				end
			end
		end
		for _, o in ipairs(L.overlay or {}) do slot[o.at[2] + 1][o.at[1] + 1] = "I" end
	end
	local spawner = {}
	for y = 1, H do spawner[y] = {} end
	if L.spawners ~= nil and L.spawners ~= "top" then
		for _, a in ipairs(L.spawners) do spawner[a[2] + 1][a[1] + 1] = true end
	else
		for x = 1, W do
			for y = 1, H do
				if ex[y][x] then spawner[y][x] = true; break end
			end
		end
	end
	local function seg_top(x, y)
		while y > 1 and ex[y - 1][x] do y = y - 1 end
		return y
	end
	local function seg_bot(x, y)
		while y < H and ex[y + 1][x] do y = y + 1 end
		return y
	end
	local function settled()
		local out = {}
		for y = 1, H do
			for x = 1, W do
				if ex[y][x] and slot[y][x] == nil then out[(x - 1) .. "," .. (y - 1)] = true end
			end
		end
		return out
	end
	for t = 1, 1000 do
		local n = 0
		for y = H, 1, -1 do
			for x = 1, W do
				if ex[y][x] and slot[y][x] == nil then
					local top = seg_top(x, y)
					local res, from = nil, nil
					local k = y
					while k > top do
						k = k - 1
						local e = slot[k][x]
						if e ~= nil then
							if e == "I" then res = "blocked" else res = "piece"; from = k end
							break
						end
					end
					if res == nil then res = spawner[top][x] and "spawn" or "blocked" end
					if res == "piece" then
						slot[from][x] = nil
						slot[y][x] = "F"
						local base = offy[from * 100 + x] or 0
						offy[from * 100 + x] = nil
						offy[y * 100 + x] = base + (y - from) * UNIT
						n = n + 1
					elseif res == "spawn" then
						local o = (y - top + 1) * UNIT
						local tv
						for yy = top, seg_bot(x, y) do
							if slot[yy][x] == "F" then
								local vis = yy * UNIT - offy[yy * 100 + x]
								if tv == nil or vis < tv then tv = vis end
							end
						end
						if tv ~= nil then
							local o2 = y * UNIT - tv + UNIT
							if o2 > o then o = o2 end
						end
						slot[y][x] = "F"
						offy[y * 100 + x] = o
						n = n + 1
					else
						local wait = false
						for yy = y + 1, seg_bot(x, y) do
							if slot[yy][x] == "F" and yy * UNIT - offy[yy * 100 + x] < y * UNIT then wait = true; break end
						end
						if not wait and y > 1 then
							local order = (t % 2 == 0) and { -1, 1 } or { 1, -1 }
							for _, dx in ipairs(order) do
								local xx = x + dx
								if ok_cell(xx, y - 1) and slot[y - 1][xx] == "P" then
									-- the cell under the donor must not exist or must be occupied
									if not (ex[y][xx] and slot[y][xx] == nil) then
										slot[y - 1][xx] = nil
										offy[(y - 1) * 100 + xx] = nil
										slot[y][x] = "F"
										offy[y * 100 + x] = UNIT
										n = n + 1
										break
									end
								end
							end
						end
					end
				end
			end
		end
		for y = 1, H do
			for x = 1, W do
				if slot[y][x] == "F" then slot[y][x] = "P" end
			end
		end
		offy = {}
		if n == 0 then return settled() end
	end
	return nil
end

local function stage3(L, exits)
	local W, H = L.size[1], L.size[2]
	local rules = {}
	local e0, e1 = O.empties(L, true), O.empties(L, false)
	if e0 == nil or e1 == nil then return { ["2.1.7"] = true } end
	if next(e0) ~= nil or next(e1) ~= nil then rules["2.1.7"] = true end
	local deliver = false
	for _, g in ipairs(L.goals) do
		if g.type == "deliver" then deliver = true end
	end
	if deliver then
		for x = 0, W - 1 do
			for y = 0, H - 1 do
				local here = string.sub(L.cells[y + 1], x + 1, x + 1) == "#"
				local below = y + 1 < H and string.sub(L.cells[y + 2], x + 1, x + 1) == "#"
				if here and not below and not exits[x .. "," .. y] and not e1[x .. "," .. y] then rules["2.1.8"] = true end
			end
		end
	end
	return rules
end

function O.validate(L)
	if not stage1(L) then return 1, { ["2.1.1"] = true } end
	local r2, exits = stage2(L)
	if next(r2) ~= nil then return 2, r2 end
	local r3 = stage3(L, exits)
	if next(r3) ~= nil then return 3, r3 end
	return 0, {}
end

-- The rule codes and the stage of a list of error strings of core.load_level.
function O.stage_of(errors)
	local rules, first = {}, nil
	local function stage(e)
		local code = string.match(e, "^(%S+)")
		if code == "2.2" then code = "2.1.1" end
		local st
		if code == "2.1.1" then st = 1
		elseif code == "2.1.7" or (code == "2.1.8" and string.find(e, "segment bottom", 1, true)) then st = 3
		elseif code == "2.1.10" then st = 4
		else st = 2 end
		return st, code
	end
	for _, e in ipairs(errors) do
		local st = stage(e)
		if first == nil or st < first then first = st end
	end
	for _, e in ipairs(errors) do
		local st, code = stage(e)
		if st == first then rules[code] = true end
	end
	return first or 0, rules
end

-- Section 4 ---------------------------------------------------------------------------

local K_REG, K_SPE, K_MIC, K_BLK = 1, 2, 3, 4
local SPECIAL = { riff = 1, sub = 2, bird = 3, disco = 4 }
local BLOCKER = { record_box = 1, concrete = 2, noise = 3, balloon = 4, column = 5 }

local function weighted(st, colors, weights)
	local total = 0
	for i = 1, #colors do total = total + weights[colors[i]] end
	local r = R.next_int(st) % total
	local acc = 0
	for i = 1, #colors do
		acc = acc + weights[colors[i]]
		if acc > r then return colors[i] end
	end
	error("unreachable")
end

-- The start board (4.1-4.6) of a level table. Returns
--   { cells = {i -> nil | {kind, color, special, axis, blocker, hp, id}}, rng = {6 words}, fills, shuffle, dirty,
--     unplaced, rest, next_id, released, on_board, last_mic }
function O.start(L, seed, boosters)
	local W, H = L.size[1], L.size[2]
	local N = W * H
	local colors = {}
	for i = 1, #L.colors do colors[#colors + 1] = CODE[L.colors[i]] end
	table.sort(colors) -- numbers
	local weights = {}
	for i = 1, #L.colors do
		weights[CODE[L.colors[i]]] = L.spawn_weights and L.spawn_weights[L.colors[i]] or 1
	end
	local function ci(at) return at[2] * W + at[1] + 1 end
	local ex = {}
	for i = 1, N do ex[i] = string.sub(L.cells[math.floor((i - 1) / W) + 1], (i - 1) % W + 1, (i - 1) % W + 1) == "#" end
	local content, wires, floor = {}, {}, {}
	for i = 1, N do wires[i], floor[i] = 0, 0 end
	for _, f in ipairs(L.floor or {}) do floor[ci(f.at)] = f.hp end
	for _, o in ipairs(L.overlay or {}) do wires[ci(o.at)] = o.hp end
	for _, s in ipairs(L.slots or {}) do
		local t, i = s.type, ci(s.at)
		local ob
		if t == "piece" then ob = { kind = K_REG, color = CODE[s.color], special = 0, axis = 0, blocker = 0, hp = 0 }
		elseif SPECIAL[t] then
			ob = { kind = K_SPE, color = 0, special = SPECIAL[t], axis = (t == "riff") and (s.axis == "h" and 1 or 2) or 0, blocker = 0, hp = 0 }
		elseif t == "mic" then ob = { kind = K_MIC, color = 0, special = 0, axis = 0, blocker = 0, hp = 0 }
		else
			ob = { kind = K_BLK, color = (t == "balloon") and CODE[s.color] or 0, special = 0, axis = 0, blocker = BLOCKER[t], hp = s.hp or 1 }
		end
		content[i] = ob
		if t == "column" then
			content[i + 1], content[i + W], content[i + W + 1] = ob, ob, ob
		end
	end
	local st = R.stream(seed, 1)
	local free = {}
	for i = 1, N do
		if ex[i] and content[i] == nil then free[#free + 1] = i end
	end

	local function colmap()
		local col = {}
		for i = 1, N do
			col[i] = (content[i] ~= nil and content[i].kind == K_REG) and content[i].color or 0
		end
		return col
	end
	local function match_through(col, p)
		local c = col[p]
		if c == 0 then return false end
		local x = (p - 1) % W + 1
		local y = math.floor((p - 1) / W) + 1
		local n, k = 1, x - 1
		while k >= 1 and col[(y - 1) * W + k] == c do n = n + 1; k = k - 1 end
		k = x + 1
		while k <= W and col[(y - 1) * W + k] == c do n = n + 1; k = k + 1 end
		if n >= 3 then return true end
		n, k = 1, y - 1
		while k >= 1 and col[(k - 1) * W + x] == c do n = n + 1; k = k - 1 end
		k = y + 1
		while k <= H and col[(k - 1) * W + x] == c do n = n + 1; k = k + 1 end
		if n >= 3 then return true end
		for dy = -1, 0 do
			for dx = -1, 0 do
				local tx, ty = x + dx, y + dy
				if tx >= 1 and tx < W and ty >= 1 and ty < H then
					local t = (ty - 1) * W + tx
					if col[t] == c and col[t + 1] == c and col[t + W] == c and col[t + W + 1] == c then return true end
				end
			end
		end
		return false
	end
	local function any_match(col)
		for p = 1, N do
			if match_through(col, p) then return true end
		end
		return false
	end
	local function movable(i)
		local o = content[i]
		if o == nil then return false end
		if o.kind == K_REG then return wires[i] == 0 end
		return o.kind == K_SPE or o.kind == K_MIC
	end
	local function pair_count()
		local col = colmap()
		local count = 0
		for i = 1, N do
			local x = (i - 1) % W + 1
			local y = math.floor((i - 1) / W) + 1
			for d = 1, 2 do
				local j
				if d == 1 then
					if x < W then j = i + 1 end
				else
					if y < H then j = i + W end
				end
				if j and movable(i) and movable(j) then
					local a, b = content[i], content[j]
					local good
					if a.kind == K_SPE or b.kind == K_SPE then good = true
					elseif a.kind == K_MIC and b.kind == K_MIC then good = false
					elseif a.kind == K_REG and b.kind == K_REG and a.color == b.color then good = false
					else
						local ca, cb = col[i], col[j]
						col[i], col[j] = cb, ca
						good = match_through(col, i) or match_through(col, j)
						col[i], col[j] = ca, cb
					end
					if good then count = count + 1 end
				end
			end
		end
		return count
	end
	local function reg_color(x, y)
		if x < 1 or y < 1 then return 0 end
		local o = content[(y - 1) * W + x]
		return (o ~= nil and o.kind == K_REG) and o.color or 0
	end
	local function allowed(i)
		local x = (i - 1) % W + 1
		local y = math.floor((i - 1) / W) + 1
		local l1, l2 = reg_color(x - 1, y), reg_color(x - 2, y)
		local u1, u2 = reg_color(x, y - 1), reg_color(x, y - 2)
		local ul = reg_color(x - 1, y - 1)
		local out = {}
		for _, c in ipairs(colors) do
			if not ((l1 == c and l2 == c) or (u1 == c and u2 == c) or (l1 == c and u1 == c and ul == c)) then out[#out + 1] = c end
		end
		if #out == 0 then return colors end
		return out
	end

	local fills, passed = 0, false
	for n = 1, 100 do
		for _, i in ipairs(free) do content[i] = nil end
		for _, i in ipairs(free) do
			content[i] = { kind = K_REG, color = weighted(st, allowed(i), weights), special = 0, axis = 0, blocker = 0, hp = 0 }
		end
		fills = n
		if not any_match(colmap()) and pair_count() >= 3 then passed = true; break end
	end
	local shuffle_item, dirty = 0, false
	if not passed then
		local cells = {}
		for i = 1, N do
			if content[i] ~= nil and content[i].kind == K_REG and wires[i] == 0 then cells[#cells + 1] = i end
		end
		local n = #cells
		local orig = {}
		for k = 1, n do orig[k] = content[cells[k]] end
		local function attempt_ok() return (not any_match(colmap())) and pair_count() > 0 end
		local done = false
		for _ = 1, 50 do
			local a = {}
			for k = 1, n do a[k] = orig[k] end
			for i = n, 2, -1 do
				local j = R.next_int(st) % i + 1
				a[i], a[j] = a[j], a[i]
			end
			for k = 1, n do content[cells[k]] = a[k] end
			if attempt_ok() then shuffle_item = 1; done = true; break end
			for k = 1, n do content[cells[k]] = orig[k] end
		end
		if not done then
			local ocol = {}
			for k = 1, n do ocol[k] = orig[k].color end
			for _ = 1, 50 do
				for k = 1, n do orig[k].color = weighted(st, allowed(cells[k]), weights) end
				if attempt_ok() then shuffle_item = 2; done = true; break end
				for k = 1, n do orig[k].color = ocol[k] end
			end
		end
		if not done then
			if n >= 1 then
				local o = orig[R.next_int(st) % n + 1]
				o.kind, o.special, o.axis, o.color = K_SPE, 1, 1, 0
				shuffle_item = 3
			else
				shuffle_item = 4
			end
		end
		dirty = any_match(colmap())
	end
	-- 4.4: ids by ascending key cell (a column is keyed by its top-left cell)
	local nid, seen = 0, {}
	for i = 1, N do
		local o = content[i]
		if o ~= nil and not seen[o] then
			seen[o] = true
			nid = nid + 1
			o.id = nid
		end
	end
	local mics = 0
	for i = 1, N do
		if content[i] ~= nil and content[i].kind == K_MIC then mics = mics + 1 end
	end
	local last_mic
	if L.mic then last_mic = (mics > 0) and 0 or -L.mic.gap_moves end
	-- 4.5: pre-level boosters
	local unplaced, riffs = {}, 0
	local collect = {}
	for _, g in ipairs(L.goals) do
		if g.type == "collect" then collect[CODE[g.color]] = true end
	end
	for _, name in ipairs(boosters) do
		local c1, c2 = {}, {}
		for i = 1, N do
			local o = content[i]
			if o ~= nil and o.kind == K_REG and wires[i] == 0 then
				c2[#c2 + 1] = o
				if floor[i] == 0 and not collect[o.color] then c1[#c1 + 1] = o end
			end
		end
		local cands = (#c1 > 0) and c1 or c2
		local sp, ax
		if name == "riff" then riffs = riffs + 1; sp = 1; ax = (riffs % 2 == 1) and 1 or 2
		elseif name == "sub" then sp, ax = 2, 0
		else sp, ax = 4, 0 end
		if #cands == 0 then
			unplaced[#unplaced + 1] = ({ riff = 5, sub = 6, disco = 7 })[name]
		else
			local o = cands[R.next_int(st) % #cands + 1]
			o.kind, o.special, o.axis, o.color = K_SPE, sp, ax, 0
		end
	end
	local out = {}
	for i = 1, N do
		local o = content[i]
		if o ~= nil then out[i] = { o.kind, o.color, o.special, o.axis, o.blocker, o.hp, o.id } end
	end
	return {
		cells = out, rng = st, fills = fills, shuffle = shuffle_item, dirty = dirty, unplaced = unplaced,
		rest = not dirty, next_id = nid + 1, released = mics, on_board = mics, last_mic = last_mic,
	}
end

-- Section 5.0 / 5.1.1 / 5.1.2 ----------------------------------------------------------------

-- What a swap does now: "ok" (accepted or run as a tap), "fail" (bounces), "reject" (a refusal).
-- Reads the state of the live game g (g.s).
function O.swap(g, fx, fy, tx, ty)
	local s = g.s
	local W, H = s.W, s.H
	local function idx(x, y) return (y - 1) * W + x end
	local function inside(x, y) return x >= 1 and x <= W and y >= 1 and y <= H end
	local function exists(x, y) return inside(x, y) and s.exists[idx(x, y)] end
	local function obj(x, y)
		if not exists(x, y) then return nil end
		local id = s.slot[idx(x, y)]
		if id == 0 then return nil end
		return s.objs[id]
	end
	-- the common checks of 5.0 that a swap meets before its cells are looked at
	if s.state ~= 1 or s.moves_left == 0 then return "reject" end
	if s.input_lock and not s.rest_flag then return "reject" end
	if not exists(fx, fy) or math.abs(tx - fx) + math.abs(ty - fy) ~= 1 then return "reject" end
	local function free(x, y)
		local o = obj(x, y)
		if o == nil or o.state ~= 1 or #o.pins > 0 then return false end
		if o.kind == K_SPE or o.kind == K_MIC then return true end
		return o.kind == K_REG and s.wires[idx(x, y)] == 0
	end
	local of = obj(fx, fy)
	if of ~= nil and of.kind == K_SPE and free(fx, fy) then
		if not exists(tx, ty) then return "ok" end
		local ot = obj(tx, ty)
		if ot == nil then return "ok" end
		if ot.kind == K_BLK and ot.state == 1 then return "ok" end
		if ot.kind == K_REG and s.wires[idx(tx, ty)] > 0 then return "ok" end
	end
	if not exists(tx, ty) then return "reject" end
	if not free(fx, fy) or not free(tx, ty) then return "reject" end
	local a, b = obj(fx, fy), obj(tx, ty)
	if a.kind == K_SPE or b.kind == K_SPE then return "ok" end
	-- the expected board
	local col = {}
	for y = 1, H do
		for x = 1, W do
			local o = obj(x, y)
			local v = 0
			if o ~= nil and o.kind == K_REG then
				if o.state == 1 or o.state == 2 then v = o.color
				elseif o.state == 3 and (o.tk == 2 or o.tk == 4) then v = o.color end
			end
			col[idx(x, y)] = v
		end
	end
	for _, sw in ipairs(s.swaps) do
		if sw.kind == 1 or sw.kind == 3 then
			local ca, cb = s.objs[s.slot[sw.from]], s.objs[s.slot[sw.to]]
			col[sw.to] = (ca and ca.kind == K_REG) and ca.color or 0
			col[sw.from] = (cb and cb.kind == K_REG) and cb.color or 0
		end
	end
	if a.kind == K_MIC and b.kind == K_MIC then return "fail" end
	if a.kind == K_REG and b.kind == K_REG and a.color == b.color then return "fail" end
	local pa, pb = idx(fx, fy), idx(tx, ty)
	col[pa], col[pb] = col[pb], col[pa]
	local function through(x, y)
		local c = col[idx(x, y)]
		if c == 0 then return false end
		local n, k = 1, x - 1
		while k >= 1 and col[idx(k, y)] == c do n = n + 1; k = k - 1 end
		k = x + 1
		while k <= W and col[idx(k, y)] == c do n = n + 1; k = k + 1 end
		if n >= 3 then return true end
		n, k = 1, y - 1
		while k >= 1 and col[idx(x, k)] == c do n = n + 1; k = k - 1 end
		k = y + 1
		while k <= H and col[idx(x, k)] == c do n = n + 1; k = k + 1 end
		if n >= 3 then return true end
		for dy = -1, 0 do
			for dx = -1, 0 do
				local x0, y0 = x + dx, y + dy
				if x0 >= 1 and x0 < W and y0 >= 1 and y0 < H then
					local p = idx(x0, y0)
					if col[p] == c and col[p + 1] == c and col[p + W] == c and col[p + W + 1] == c then return true end
				end
			end
		end
		return false
	end
	if through(fx, fy) or through(tx, ty) then return "ok" end
	return "fail"
end

-- Random levels ------------------------------------------------------------------------


function O.lcg(seed)
	local x = seed
	return function(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return math.floor(x / 65536) % n + 1
	end
end

local function copy(v)
	if type(v) ~= "table" then return v end
	local t = {}
	for k, x in pairs(v) do t[k] = copy(x) end
	return t
end
O.copy = copy

-- A random level that is valid more often than not; `rnd` is an lcg.
function O.random_level(rnd)
	local W, H = 5 + rnd(4), 5 + rnd(6)
	local void_p = ({ 0, 0, 3, 8 })[rnd(4)]
	local ex = {}
	for y = 1, H do
		ex[y] = {}
		for x = 1, W do ex[y][x] = rnd(100) > void_p end
	end
	local cells = {}
	for y = 1, H do
		local r = {}
		for x = 1, W do r[x] = ex[y][x] and "#" or "." end
		cells[y] = table.concat(r)
	end
	local pool, cols = { 1, 2, 3, 4, 5, 6 }, {}
	for k = 1, 3 + rnd(4) do
		local j = rnd(#pool)
		cols[k] = COLORS[pool[j]]
		table.remove(pool, j)
	end
	local kinds = { "record_box", "dancefloor", "wires", "mic", "concrete", "noise", "balloon", "column" }
	local chosen = {}
	for _ = 1, rnd(3) do chosen[kinds[rnd(#kinds)]] = true end
	local used = {}
	local function free(x, y) return x >= 1 and y >= 1 and x <= W and y <= H and ex[y][x] and not used[x .. "," .. y] end
	local slots, overlay, floor, counts, mics = {}, {}, {}, {}, 0
	local density = ({ 2, 5, 9, 14 })[rnd(4)]
	for y = 1, H do
		for x = 1, W do
			if free(x, y) and rnd(100) <= density then
				local at = { x - 1, y - 1 }
				local pick = {}
				for _, k in ipairs(kinds) do
					if chosen[k] then pick[#pick + 1] = k end
				end
				pick[#pick + 1] = "piece"
				pick[#pick + 1] = "special"
				local k = pick[rnd(#pick)]
				if k == "piece" then
					used[x .. "," .. y] = true
					slots[#slots + 1] = { at = at, type = "piece", color = cols[rnd(#cols)] }
					if chosen.wires and rnd(3) == 1 then overlay[#overlay + 1] = { at = at, type = "wires", hp = rnd(2) } end
				elseif k == "special" then
					used[x .. "," .. y] = true
					local t = ({ "riff", "sub", "bird", "disco" })[rnd(4)]
					local sl = { at = at, type = t }
					if t == "riff" then sl.axis = rnd(2) == 1 and "h" or "v" end
					slots[#slots + 1] = sl
				elseif k == "record_box" or k == "concrete" or k == "noise" or k == "balloon" then
					used[x .. "," .. y] = true
					local sl = { at = at, type = k }
					if k == "record_box" then sl.hp = rnd(3) elseif k == "concrete" then sl.hp = rnd(2) end
					if k == "balloon" then sl.color = cols[rnd(#cols)] end
					slots[#slots + 1] = sl
					counts[k] = (counts[k] or 0) + 1
				elseif k == "column" then
					if free(x + 1, y) and free(x, y + 1) and free(x + 1, y + 1) then
						for dx = 0, 1 do
							for dy = 0, 1 do used[(x + dx) .. "," .. (y + dy)] = true end
						end
						slots[#slots + 1] = { at = at, type = "column", hp = 5 + rnd(7) }
						counts.column = (counts.column or 0) + 1
					end
				elseif k == "mic" then
					if mics < 2 then
						used[x .. "," .. y] = true
						mics = mics + 1
						slots[#slots + 1] = { at = at, type = "mic" }
					end
				elseif k == "dancefloor" then
					floor[#floor + 1] = { at = at, hp = rnd(2) }
				elseif k == "wires" then
					used[x .. "," .. y] = true
					overlay[#overlay + 1] = { at = at, type = "wires", hp = rnd(2) }
				end
			end
		end
	end
	local goals = { { type = "collect", color = cols[rnd(#cols)], count = rnd(40) } }
	for _, item in ipairs({ "record_box", "concrete", "noise", "balloon", "column" }) do
		if counts[item] and #goals < 3 and rnd(2) == 1 then
			goals[#goals + 1] = { type = "break", item = item, count = 1 + math.floor(rnd(counts[item]) / 2) }
		end
	end
	if #floor > 0 and #goals < 3 and rnd(2) == 1 then goals[#goals + 1] = { type = "light" } end
	local lvl = {
		id = rnd(500), version = rnd(3), size = { W, H }, moves = 4 + rnd(56),
		difficulty = ({ "easy", "medium", "hard", "super_hard" })[rnd(4)], colors = cols, goals = goals, cells = cells,
	}
	if #slots > 0 then lvl.slots = slots end
	if #overlay > 0 then lvl.overlay = overlay end
	if #floor > 0 then lvl.floor = floor end
	if chosen.mic and #goals < 3 then
		local cnt = math.max(mics, rnd(3))
		goals[#goals + 1] = { type = "deliver", count = cnt }
		lvl.mic = { total = cnt, on_board_max = rnd(3), gap_moves = rnd(4) - 1 }
	end
	if rnd(4) == 1 then
		local w = {}
		for _, c in ipairs(cols) do w[c] = rnd(1000) end
		lvl.spawn_weights = w
	end
	if rnd(3) == 1 then
		local sp, exl = {}, {}
		for x = 1, W do
			for y = 1, H do
				if ex[y][x] and (y == 1 or not ex[y - 1][x]) then sp[#sp + 1] = { x - 1, y - 1 } end
				if ex[y][x] and (y == H or not ex[y + 1][x]) then exl[#exl + 1] = { x - 1, y - 1 } end
			end
		end
		if rnd(4) == 1 and #sp > 1 then table.remove(sp, rnd(#sp)) end
		if rnd(4) == 1 and #exl > 1 then table.remove(exl, rnd(#exl)) end
		lvl.spawners = sp
		if rnd(2) == 1 then lvl.exits = exl end
	end
	return lvl
end

local JUNK = { 0, 1, -1, 2, 3, 5, 6, 7, 9, 12, 13, 61, 1000, 1001, 1.5, "x", "", "top", "bottom", "red", "purple", "riff",
	"noise", "wires", "h", "v", "#", ".", true, false }

function O.mutate(rnd, lvl)
	local function nodes(root)
		local list = {}
		local function walk(t)
			list[#list + 1] = t
			local keys = {}
			for k in pairs(t) do keys[#keys + 1] = k end
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			for _, k in ipairs(keys) do if type(t[k]) == "table" then walk(t[k]) end end
		end
		walk(root)
		return list
	end
	for _ = 1, rnd(2) do
		local list = nodes(lvl)
		local t = list[rnd(#list)]
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		if #keys > 0 then
			local op = rnd(7)
			local k = keys[rnd(#keys)]
			if op == 1 then t[k] = nil
			elseif op == 2 then t[k] = copy(JUNK[rnd(#JUNK)])
			elseif op == 3 then t.extra = 1
			elseif op == 4 then t[k] = copy(t[keys[rnd(#keys)]])
			elseif op == 5 then
				if type(t[k]) == "number" then t[k] = t[k] + ({ -1, 1, -2, 2 })[rnd(4)] end
			elseif op == 6 then
				if type(t[k]) == "table" and #t[k] > 0 then t[k][#t[k] + 1] = copy(t[k][rnd(#t[k])]) end
			else
				if type(t[k]) == "string" and #t[k] > 1 then
					local p = rnd(#t[k])
					t[k] = string.sub(t[k], 1, p - 1) .. ({ "#", ".", "x" })[rnd(3)] .. string.sub(t[k], p + 1)
				end
			end
		end
	end
	return lvl
end


-- Levels made only of fixed content: voids, blockers, columns, wires, explicit spawner lists.
function O.fixed_level(rnd)
	local W, H = 5 + rnd(4), 5 + rnd(6)
	local void_p = ({ 0, 0, 4, 10, 18 })[rnd(5)]
	local ex = {}
	for y = 1, H do
		ex[y] = {}
		for x = 1, W do ex[y][x] = rnd(100) > void_p end
	end
	local cells = {}
	for y = 1, H do
		local r = {}
		for x = 1, W do r[x] = ex[y][x] and "#" or "." end
		cells[y] = table.concat(r)
	end
	local kinds = { "record_box", "concrete", "noise", "balloon", "column", "wires" }
	local chosen = {}
	for _ = 1, rnd(3) do chosen[kinds[rnd(#kinds)]] = true end
	local pick = {}
	for _, k in ipairs(kinds) do
		if chosen[k] then pick[#pick + 1] = k end
	end
	local used, slots, overlay = {}, {}, {}
	local function free(x, y) return x >= 1 and y >= 1 and x <= W and y <= H and ex[y][x] and not used[x .. "," .. y] end
	local density = ({ 2, 4, 8, 14, 22 })[rnd(5)]
	for y = 1, H do
		for x = 1, W do
			if free(x, y) and rnd(100) <= density then
				local k = pick[rnd(#pick)]
				if k == "column" then
					if free(x + 1, y) and free(x, y + 1) and free(x + 1, y + 1) then
						for dx = 0, 1 do
							for dy = 0, 1 do used[(x + dx) .. "," .. (y + dy)] = true end
						end
						slots[#slots + 1] = { at = { x - 1, y - 1 }, type = "column", hp = 6 }
					end
				elseif k == "wires" then
					used[x .. "," .. y] = true
					overlay[#overlay + 1] = { at = { x - 1, y - 1 }, type = "wires", hp = 1 }
				else
					used[x .. "," .. y] = true
					local sl = { at = { x - 1, y - 1 }, type = k }
					if k == "record_box" or k == "concrete" then sl.hp = 1 end
					if k == "balloon" then sl.color = "red" end
					slots[#slots + 1] = sl
				end
			end
		end
	end
	local lvl = {
		id = 1, version = 1, size = { W, H }, moves = 20, difficulty = "easy", colors = { "red", "green", "blue", "yellow" },
		goals = { { type = "collect", color = "red", count = 5 } }, cells = cells, slots = slots, overlay = overlay,
	}
	if rnd(2) == 1 then
		local sp = {}
		for x = 1, W do
			for y = 1, H do
				if ex[y][x] and (y == 1 or not ex[y - 1][x]) then sp[#sp + 1] = { x - 1, y - 1 } end
			end
		end
		local keep = {}
		for _, s in ipairs(sp) do
			if rnd(5) > 1 then keep[#keep + 1] = s end
		end
		if #keep == 0 then keep = { sp[1] } end
		lvl.spawners = keep
	end
	return lvl
end

-- Dense fixed content on a full board: many start fills fail and the start shuffle runs.
function O.dense_level(rnd, densities)
	local W, H = 5 + rnd(3), 5 + rnd(3)
	local cells = {}
	for y = 1, H do cells[y] = string.rep("#", W) end
	local pool, cols = { 1, 2, 3, 4, 5, 6 }, {}
	for k = 1, 3 + rnd(2) do
		local j = rnd(#pool)
		cols[k] = COLORS[pool[j]]
		table.remove(pool, j)
	end
	densities = densities or { 25, 40, 55, 70 }
	local density = densities[rnd(#densities)]
	local slots, overlay = {}, {}
	for y = 1, H do
		for x = 1, W do
			if rnd(100) <= density then
				local at = { x - 1, y - 1 }
				local k = rnd(8)
				if k <= 2 then
					slots[#slots + 1] = { at = at, type = "piece", color = cols[rnd(#cols)] }
					if rnd(3) == 1 then overlay[#overlay + 1] = { at = at, type = "wires", hp = 1 } end
				elseif k <= 4 then slots[#slots + 1] = { at = at, type = "record_box", hp = rnd(3) }
				elseif k == 5 then slots[#slots + 1] = { at = at, type = "concrete", hp = rnd(2) }
				elseif k == 6 then overlay[#overlay + 1] = { at = at, type = "wires", hp = 1 }
				elseif k == 7 then
					local t = ({ "riff", "sub", "bird", "disco" })[rnd(4)]
					slots[#slots + 1] = { at = at, type = t, axis = (t == "riff") and "h" or nil }
				end
			end
		end
	end
	local lvl = {
		id = 1 + rnd(50), version = 1, size = { W, H }, moves = 20, difficulty = "easy", colors = cols,
		goals = { { type = "collect", color = cols[rnd(#cols)], count = 5 } }, cells = cells,
	}
	if #slots > 0 then lvl.slots = slots end
	if #overlay > 0 then lvl.overlay = overlay end
	if rnd(3) == 1 then
		local w = {}
		for _, c in ipairs(cols) do w[c] = rnd(6) end
		lvl.spawn_weights = w
	end
	return lvl
end

return O
