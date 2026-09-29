-- Level loading, validation (section 2) and canonical form (2.2).
--
-- L.load(input) takes JSON text (checked token by token by
-- core/json_strict.lua) or an already decoded table, validates it by 2.0-2.1
-- and returns the normalized level or nil, errors. Errors are strings
-- "<rule> <what> [at x,y]" with the zero-based JSON coordinates of the file.
--
-- The normalized level is read-only and shared by all games and clones:
--   id, version, W, H, N, moves, difficulty (code), colors (codes,
--   ascending), weights[code], goals = {{type, param, count}} (param: colour
--   code of collect, blocker code of break, else 0), exists[i], spawner[i],
--   exit[i] (only with a deliver goal), floor[i], wires[i] (hp),
--   seg_top[i], seg_bot[i] (rows of the segment of cell i),
--   presets = {{cell, kind, color, special, axis, blocker, hp}} by cell,
--   mic = {total, on_board_max, gap_moves} or nil, canonical, hash.

local C = require("core.const")
local U = require("core.util")
local J = require("core.json_strict")

local L = {}

local is_int = U.is_int

-- helpers ---------------------------------------------------------------------

local function byte_lt(a, b)
	local n = math.min(#a, #b)
	for k = 1, n do
		local x, y = string.byte(a, k), string.byte(b, k)
		if x ~= y then return x < y end
	end
	return #a < #b
end

local function sorted_string_keys(t)
	local keys = {}
	for k in pairs(t) do -- order-independent (sorted below)
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		if type(a) ~= type(b) then return type(a) < type(b) end
		if type(a) == "string" then return byte_lt(a, b) end
		return a < b
	end)
	return keys
end

local function is_array(v)
	if type(v) ~= "table" then return false end
	local n = 0
	for _ in pairs(v) do n = n + 1 end -- order-independent (count)
	for k = 1, n do
		if v[k] == nil then return false end
	end
	return true
end

local function is_object(v)
	if type(v) ~= "table" then return false end
	-- an empty table is both an empty array and an empty object
	for k in pairs(v) do -- order-independent (type check)
		if type(k) ~= "string" then return false end
	end
	return true
end

-- Canonical form (2.2) ----------------------------------------------------------

local SHAPE = {
	size = "arr", colors = "arr", cells = "arr", at = "arr",
	goals = "arr_obj", floor = "arr_obj", overlay = "arr_obj", slots = "arr_obj",
	spawners = "arr_arr", exits = "arr_arr", mic = "obj", spawn_weights = "obj",
}

local function ser_scalar(v, out)
	local t = type(v)
	if t == "string" then
		out[#out + 1] = '"' .. string.gsub(v, '[\\"]', function(c) return "\\" .. c end) .. '"'
	elseif t == "number" then
		out[#out + 1] = string.format("%.0f", v)
	elseif t == "boolean" then
		out[#out + 1] = v and "true" or "false"
	else
		error("level: unexpected value in canonical form")
	end
end

local ser_value

local function ser_object(t, out)
	out[#out + 1] = "{"
	local keys = sorted_string_keys(t)
	for k = 1, #keys do
		if k > 1 then out[#out + 1] = "," end
		ser_scalar(keys[k], out)
		out[#out + 1] = ":"
		ser_value(t[keys[k]], SHAPE[keys[k]], out)
	end
	out[#out + 1] = "}"
end

local function ser_array(t, elem, out)
	out[#out + 1] = "["
	for k = 1, #t do
		if k > 1 then out[#out + 1] = "," end
		ser_value(t[k], elem, out)
	end
	out[#out + 1] = "]"
end

ser_value = function(v, shape, out)
	if type(v) ~= "table" then return ser_scalar(v, out) end
	if shape == "arr" then return ser_array(v, nil, out) end
	if shape == "arr_obj" then return ser_array(v, "obj", out) end
	if shape == "arr_arr" then return ser_array(v, "arr", out) end
	return ser_object(v, out)
end

function L.canonical(raw)
	local out = {}
	ser_object(raw, out)
	return table.concat(out)
end

-- Schema (2.0) -----------------------------------------------------------------

local ROOT = {
	id = true, version = true, size = true, moves = true, difficulty = true, colors = true,
	goals = true, cells = true, spawners = true, exits = true, floor = true, overlay = true,
	slots = true, mic = true, spawn_weights = true,
}

local GOAL_KEYS = {
	collect = { type = true, color = true, count = true },
	["break"] = { type = true, item = true, count = true },
	light = { type = true },
	deliver = { type = true, count = true },
}

-- slot type -> {fields = {name = checker}}
local function hp_range(lo, hi)
	return function(v) return is_int(v) and v >= lo and v <= hi end
end
local function is_color(v) return type(v) == "string" and C.COLOR[v] ~= nil end
local function is_axis(v) return v == "h" or v == "v" end

local SLOT_FIELDS = {
	record_box = { hp = hp_range(1, 3) },
	concrete = { hp = hp_range(1, 2) },
	noise = {},
	balloon = { color = is_color },
	column = { hp = hp_range(6, 12) },
	riff = { axis = is_axis },
	sub = {}, bird = {}, disco = {},
	piece = { color = is_color },
	mic = {},
}

local function is_at(v)
	return is_array(v) and #v == 2 and is_int(v[1]) and is_int(v[2])
end

local function check_keys(t, allowed, path, errs)
	local keys = sorted_string_keys(t)
	for k = 1, #keys do
		if not allowed[keys[k]] then
			errs[#errs + 1] = "2.1.1 " .. path .. ": unknown key '" .. tostring(keys[k]) .. "'"
		end
	end
end

local function schema(raw, errs)
	local function e(msg) errs[#errs + 1] = "2.1.1 " .. msg end
	if not is_object(raw) then
		e("level is not an object")
		return
	end
	check_keys(raw, ROOT, "level", errs)
	for _, k in ipairs({ "id", "version" }) do
		if not (is_int(raw[k]) and raw[k] >= 1) then e(k .. ": integer >= 1 required") end
	end
	local W, H
	if is_array(raw.size) and #raw.size == 2 and is_int(raw.size[1]) and is_int(raw.size[2]) then
		W, H = raw.size[1], raw.size[2]
		if W < 6 or W > 9 or H < 6 or H > 11 then e("size: 6..9 x 6..11 required") end
	else
		e("size: [W, H] required")
	end
	if not (is_int(raw.moves) and raw.moves >= 5 and raw.moves <= 60) then e("moves: 5..60 required") end
	if not (type(raw.difficulty) == "string" and C.DIFFICULTY[raw.difficulty]) then
		e("difficulty: easy|medium|hard|super_hard required")
	end
	if is_array(raw.colors) and #raw.colors >= 4 and #raw.colors <= 6 then
		local seen = {}
		for k = 1, #raw.colors do
			local c = raw.colors[k]
			if not is_color(c) then e("colors: unknown colour")
			elseif seen[c] then e("colors: repeated colour '" .. c .. "'")
			else seen[c] = true end
		end
	else
		e("colors: 4-6 colours required")
	end
	if is_array(raw.goals) and #raw.goals >= 1 and #raw.goals <= 3 then
		local seen = {}
		for k = 1, #raw.goals do
			local g = raw.goals[k]
			local path = "goals[" .. k .. "]"
			if not is_object(g) or type(g.type) ~= "string" or not GOAL_KEYS[g.type] then
				e(path .. ": goal type collect|break|light|deliver required")
			else
				check_keys(g, GOAL_KEYS[g.type], path, errs)
				if g.type == "collect" and not is_color(g.color) then e(path .. ": color required") end
				if g.type == "break" and type(g.item) ~= "string" then e(path .. ": item required") end
				if g.type ~= "light" and not (is_int(g.count) and g.count >= 1) then
					e(path .. ": count >= 1 required")
				end
				local key = g.type .. ":" .. tostring(g.color or g.item or "")
				if seen[key] then e(path .. ": repeated goal") end
				seen[key] = true
			end
		end
	else
		e("goals: 1-3 goals required")
	end
	if is_array(raw.cells) and H and #raw.cells == H then
		for y = 1, H do
			local row = raw.cells[y]
			if type(row) ~= "string" or #row ~= W or string.find(row, "[^#%.]") then
				e("cells[" .. (y - 1) .. "]: " .. tostring(W) .. " characters of '#' and '.' required")
			end
		end
	else
		e("cells: H rows required")
	end
	for _, k in ipairs({ "spawners", "exits" }) do
		local v = raw[k]
		local word = k == "spawners" and "top" or "bottom"
		if v ~= nil and v ~= word then
			if not is_array(v) then
				e(k .. ": '" .. word .. "' or a list of [x, y] required")
			else
				for j = 1, #v do
					if not is_at(v[j]) then e(k .. "[" .. j .. "]: [x, y] required") end
				end
			end
		end
	end
	local function list(k, fn)
		local v = raw[k]
		if v == nil then return end
		if not is_array(v) then
			e(k .. ": list required")
			return
		end
		for j = 1, #v do
			local item = v[j]
			local path = k .. "[" .. j .. "]"
			if not is_object(item) then e(path .. ": object required")
			elseif not is_at(item.at) then e(path .. ": at [x, y] required")
			else fn(item, path) end
		end
	end
	list("floor", function(item, path)
		check_keys(item, { at = true, hp = true }, path, errs)
		if not hp_range(1, 2)(item.hp) then e(path .. ": hp 1..2 required") end
	end)
	list("overlay", function(item, path)
		check_keys(item, { at = true, type = true, hp = true }, path, errs)
		if item.type ~= "wires" then e(path .. ": type 'wires' required") end
		if not hp_range(1, 2)(item.hp) then e(path .. ": hp 1..2 required") end
	end)
	list("slots", function(item, path)
		local fields = type(item.type) == "string" and SLOT_FIELDS[item.type]
		if not fields then
			e(path .. ": unknown slot type")
			return
		end
		local allowed = { at = true, type = true }
		for _, f in ipairs({ "hp", "color", "axis" }) do
			if fields[f] then
				allowed[f] = true
				if not fields[f](item[f]) then e(path .. ": bad or missing " .. f) end
			end
		end
		check_keys(item, allowed, path, errs)
	end)
	local deliver = nil
	if is_array(raw.goals) then
		for k = 1, #raw.goals do
			local g = raw.goals[k]
			if is_object(g) and g.type == "deliver" then deliver = g end
		end
	end
	if raw.mic ~= nil then
		local m = raw.mic
		if not is_object(m) then
			e("mic: object required")
		else
			check_keys(m, { total = true, on_board_max = true, gap_moves = true }, "mic", errs)
			if not (is_int(m.total) and m.total >= 1) then e("mic: total >= 1 required") end
			if not (is_int(m.on_board_max) and m.on_board_max >= 1) then e("mic: on_board_max >= 1 required") end
			if not (is_int(m.gap_moves) and m.gap_moves >= 0) then e("mic: gap_moves >= 0 required") end
			if deliver and is_int(deliver.count) and m.total ~= deliver.count then
				e("mic: total must equal the deliver count")
			end
		end
	elseif deliver then
		e("mic: block required with a deliver goal")
	end
	if raw.spawn_weights ~= nil then
		local w = raw.spawn_weights
		if not is_object(w) then
			e("spawn_weights: object required")
		elseif is_array(raw.colors) then
			local want = {}
			for k = 1, #raw.colors do want[raw.colors[k]] = true end
			local keys = sorted_string_keys(w)
			for k = 1, #keys do
				local c = keys[k]
				if not want[c] then e("spawn_weights: key '" .. tostring(c) .. "' is not a level colour") end
				if not hp_range(1, 1000)(w[c]) then e("spawn_weights: weight 1..1000 required") end
			end
			for k = 1, #raw.colors do
				if type(raw.colors[k]) == "string" and w[raw.colors[k]] == nil then
					e("spawn_weights: missing colour '" .. raw.colors[k] .. "'")
				end
			end
		end
	end
end

-- Normalization and static rules (2.1.2-2.1.6, 2.1.8, 2.1.9) --------------------

local function segments(lvl)
	local W, H = lvl.W, lvl.H
	for i = 1, W * H do lvl.seg_top[i], lvl.seg_bot[i] = 0, 0 end
	for x = 1, W do
		local top = 0
		for y = 1, H do
			local i = (y - 1) * W + x
			if lvl.exists[i] then
				if top == 0 then top = y end
				lvl.seg_top[i] = top
			else
				top = 0
			end
		end
		local bot = 0
		for y = H, 1, -1 do
			local i = (y - 1) * W + x
			if lvl.exists[i] then
				if bot == 0 then bot = y end
				lvl.seg_bot[i] = bot
			else
				bot = 0
			end
		end
	end
end

local function where(W, i)
	local x, y = U.xy(W, i)
	return " at " .. (x - 1) .. "," .. (y - 1)
end

local function normalize(raw, errs)
	local W, H = raw.size[1], raw.size[2]
	local N = W * H
	local lvl = {
		id = raw.id, version = raw.version, W = W, H = H, N = N, moves = raw.moves,
		difficulty = C.DIFFICULTY[raw.difficulty],
		colors = {}, weights = {}, goals = {},
		exists = {}, spawner = {}, exit = {}, floor = {}, wires = {},
		seg_top = {}, seg_bot = {}, presets = {}, mic = nil,
	}
	local function e(rule, msg, i)
		errs[#errs + 1] = rule .. " " .. msg .. (i and where(W, i) or "")
	end
	for y = 1, H do
		local row = raw.cells[y]
		for x = 1, W do
			local i = (y - 1) * W + x
			lvl.exists[i] = string.sub(row, x, x) == "#"
			lvl.spawner[i], lvl.exit[i] = false, false
			lvl.floor[i], lvl.wires[i] = 0, 0
		end
	end
	segments(lvl)
	for c = 1, C.NCOLORS do
		for k = 1, #raw.colors do
			if raw.colors[k] == C.COLOR_NAME[c] then lvl.colors[#lvl.colors + 1] = c end
		end
	end
	local in_colors = {}
	for k = 1, #lvl.colors do
		local c = lvl.colors[k]
		in_colors[c] = true
		lvl.weights[c] = raw.spawn_weights and raw.spawn_weights[C.COLOR_NAME[c]] or 1
	end
	local deliver = false
	for k = 1, #raw.goals do
		local g = raw.goals[k]
		local t = C.GOAL[g.type]
		local param = 0
		if t == C.GOAL_COLLECT then param = C.COLOR[g.color]
		elseif t == C.GOAL_BREAK then param = C.BLOCKER[g.item] or -1 end
		if t == C.GOAL_DELIVER then deliver = true end
		lvl.goals[k] = { type = t, param = param, count = g.count or 1 }
	end
	if raw.mic then
		lvl.mic = { total = raw.mic.total, on_board_max = raw.mic.on_board_max, gap_moves = raw.mic.gap_moves }
	end
	-- a cell index for [x, y], or nil if it is not an existing cell
	local function cell(at)
		local x, y = at[1] + 1, at[2] + 1
		if x < 1 or x > W or y < 1 or y > H then return nil end
		local i = (y - 1) * W + x
		if not lvl.exists[i] then return nil end
		return i
	end
	local function atstr(at) return " at " .. at[1] .. "," .. at[2] end
	-- spawners
	if raw.spawners == nil or raw.spawners == "top" then
		for x = 1, W do
			for y = 1, H do
				local i = (y - 1) * W + x
				if lvl.exists[i] then
					lvl.spawner[i] = true
					break
				end
			end
		end
	else
		for k = 1, #raw.spawners do
			local at = raw.spawners[k]
			local i = cell(at)
			if not i then errs[#errs + 1] = "2.1.2 spawner is not an existing cell" .. atstr(at)
			elseif lvl.spawner[i] then errs[#errs + 1] = "2.1.2 repeated spawner" .. atstr(at)
			else lvl.spawner[i] = true end
		end
	end
	for i = 1, N do
		if lvl.spawner[i] and lvl.seg_top[i] ~= (i - (i - 1) % W - 1) / W + 1 then
			e("2.1.2", "the cell above a spawner is not a void or the edge", i)
		end
	end
	-- exits
	local exits = {}
	if raw.exits == nil or raw.exits == "bottom" then
		for i = 1, N do
			if lvl.exists[i] and lvl.seg_bot[i] == (i - (i - 1) % W - 1) / W + 1 then exits[i] = true end
		end
	else
		for k = 1, #raw.exits do
			local at = raw.exits[k]
			local i = cell(at)
			if not i then errs[#errs + 1] = "2.1.2 exit is not an existing cell" .. atstr(at)
			elseif exits[i] then errs[#errs + 1] = "2.1.2 repeated exit" .. atstr(at)
			else exits[i] = true end
		end
	end
	local n_exits = 0
	for i = 1, N do
		if exits[i] then n_exits = n_exits + 1 end
		if deliver then lvl.exit[i] = exits[i] == true end
	end
	-- floor and wires
	local n_tiles = 0
	for _, layer in ipairs({ "floor", "overlay" }) do
		local list = raw[layer] or {}
		local dst = layer == "floor" and lvl.floor or lvl.wires
		for k = 1, #list do
			local at = list[k].at
			local i = cell(at)
			if not i then errs[#errs + 1] = "2.1.2 " .. layer .. " is not on an existing cell" .. atstr(at)
			elseif dst[i] > 0 then errs[#errs + 1] = "2.1.2 two " .. layer .. " elements in one cell" .. atstr(at)
			else
				dst[i] = list[k].hp
				if layer == "floor" then n_tiles = n_tiles + 1 end
			end
		end
	end
	-- slots
	local slot_at = {}
	local counts = { 0, 0, 0, 0, 0 }
	local n_mics = 0
	local slots = raw.slots or {}
	for k = 1, #slots do
		local item = slots[k]
		local at = item.at
		local i = cell(at)
		local ty = item.type
		local cells = { i }
		if i and ty == "column" then
			local x, y = at[1], at[2]
			cells = { i, cell({ x + 1, y }), cell({ x, y + 1 }), cell({ x + 1, y + 1 }) }
			if not (cells[2] and cells[3] and cells[4]) then
				errs[#errs + 1] = "2.1.2 column needs 4 existing cells" .. atstr(at)
				cells = nil
			end
		end
		if not i then
			errs[#errs + 1] = "2.1.2 slot is not on an existing cell" .. atstr(at)
		elseif cells then
			local clash = false
			for j = 1, #cells do
				if slot_at[cells[j]] then clash = true end
			end
			if clash then
				errs[#errs + 1] = "2.1.2 two slot elements in one cell" .. atstr(at)
			else
				local p = { cell = i, kind = 0, color = 0, special = 0, axis = 0, blocker = 0, hp = 0, type = ty }
				if C.BLOCKER[ty] then
					p.kind = C.K_BLOCKER
					p.blocker = C.BLOCKER[ty]
					p.hp = item.hp or 1
					counts[p.blocker] = counts[p.blocker] + 1
					if ty == "balloon" then p.color = C.COLOR[item.color] end
				elseif C.SPECIAL[ty] then
					p.kind = C.K_SPECIAL
					p.special = C.SPECIAL[ty]
					if ty == "riff" then p.axis = C.AXIS[item.axis] end
				elseif ty == "piece" then
					p.kind = C.K_REGULAR
					p.color = C.COLOR[item.color]
				else
					p.kind = C.K_MIC
					n_mics = n_mics + 1
					if deliver and exits[i] then e("2.1.8", "starting mic stands on an exit", i) end
				end
				if p.color ~= 0 and not in_colors[p.color] then
					e("2.1.4", "colour '" .. C.COLOR_NAME[p.color] .. "' is not a level colour", i)
				end
				for j = 1, #cells do slot_at[cells[j]] = p end
				lvl.presets[#lvl.presets + 1] = p
			end
		end
	end
	table.sort(lvl.presets, function(a, b) return a.cell < b.cell end)
	-- a light goal counts the tiles of the level
	for k = 1, #lvl.goals do
		if lvl.goals[k].type == C.GOAL_LIGHT then lvl.goals[k].count = n_tiles end
	end
	-- wires only over regular pieces (2.1.3)
	for i = 1, N do
		if lvl.wires[i] > 0 and slot_at[i] and slot_at[i].kind ~= C.K_REGULAR then
			e("2.1.3", "wires over a cell without a regular piece", i)
		end
	end
	-- goals (2.1.5)
	for k = 1, #lvl.goals do
		local g = lvl.goals[k]
		if g.type == C.GOAL_COLLECT and not in_colors[g.param] then
			errs[#errs + 1] = "2.1.5 collect colour is not a level colour"
		elseif g.type == C.GOAL_BREAK then
			if g.param < 1 then
				errs[#errs + 1] = "2.1.5 break item must be record_box, concrete, noise, balloon or column"
			elseif g.count > counts[g.param] then
				errs[#errs + 1] = "2.1.5 break count exceeds the " .. C.BLOCKER_NAME[g.param] .. " objects on the board"
			end
		elseif g.type == C.GOAL_LIGHT and n_tiles == 0 then
			errs[#errs + 1] = "2.1.5 light goal without floor tiles"
		elseif g.type == C.GOAL_DELIVER and (not lvl.mic or n_exits == 0) then
			errs[#errs + 1] = "2.1.5 deliver goal needs a mic block and an exit"
		end
	end
	-- distinct elements (2.1.6)
	local n_el = 0
	for b = 1, 5 do
		if counts[b] > 0 then n_el = n_el + 1 end
	end
	if n_tiles > 0 then n_el = n_el + 1 end
	local any_wires = false
	for i = 1, N do
		if lvl.wires[i] > 0 then any_wires = true end
	end
	if any_wires then n_el = n_el + 1 end
	if deliver or raw.mic ~= nil or n_mics > 0 then n_el = n_el + 1 end
	if n_el > 3 then errs[#errs + 1] = "2.1.6 more than three different elements" end
	-- microphones (2.1.8, static part)
	if not deliver then
		if raw.mic ~= nil then errs[#errs + 1] = "2.1.8 mic block without a deliver goal" end
		if n_mics > 0 then errs[#errs + 1] = "2.1.8 mic pieces without a deliver goal" end
	else
		for i = 1, N do
			if lvl.exit[i] and lvl.spawner[i] then e("2.1.8", "exit is also a spawner", i) end
		end
		if lvl.mic and n_mics > math.min(lvl.mic.on_board_max, lvl.mic.total) then
			errs[#errs + 1] = "2.1.8 more starting mics than min(on_board_max, total)"
		end
	end
	-- starting pieces form no match among themselves (2.1.9)
	local M = require("core.match")
	local col = {}
	for i = 1, N do
		local p = slot_at[i]
		col[i] = (p and p.kind == C.K_REGULAR) and p.color or 0
	end
	if M.any_match(col, W, H) then errs[#errs + 1] = "2.1.9 starting pieces form a line of 3 or a 2x2 square" end
	lvl.wired_fill = {}
	for i = 1, N do
		lvl.wired_fill[i] = lvl.wires[i] > 0
	end
	return lvl, slot_at
end

-- Fillability (2.1.7) -----------------------------------------------------------

-- Runs steps 4-6 in turbo with colourless pieces from an empty board with
-- the fixed content of B0 (keep_fixed) or B1. Returns the state or nil if
-- it does not settle within 1000 ticks.
local function settle(lvl, slot_at, keep_fixed)
	local B = require("core.board")
	local G = require("core.gravity")
	local s = B.new_state(lvl)
	s.colorless = true
	s.timing = C.TIMING_TURBO
	for i = 1, s.N do s.exit[i] = false end
	if keep_fixed then
		for i = 1, lvl.N do
			local p = slot_at[i]
			if p and p.cell == i and p.kind == C.K_BLOCKER then
				local o = B.new_obj(s, C.K_BLOCKER, { blocker = p.blocker, hp = p.hp, color = p.color })
				B.place(s, o, i)
			elseif lvl.exists[i] and lvl.wires[i] > 0 and s.slot[i] == 0 then
				local o = B.new_obj(s, C.K_REGULAR, {})
				B.place(s, o, i)
			end
		end
	end
	for t = 1, 1000 do
		s.tick, s.now = t, t
		G.assign(s)
		G.move(s)
		if s.last_assign == 0 then return s end
	end
	return nil
end

local function fill_checks(lvl, slot_at, errs)
	local W = lvl.W
	local b0 = settle(lvl, slot_at, true)
	if not b0 then
		errs[#errs + 1] = "2.1.7 board B0 does not settle within 1000 ticks"
	else
		for i = 1, lvl.N do
			if lvl.exists[i] and b0.slot[i] == 0 then
				errs[#errs + 1] = "2.1.7 cell stays empty on board B0" .. where(W, i)
			end
		end
	end
	local b1 = settle(lvl, slot_at, false)
	if not b1 then
		errs[#errs + 1] = "2.1.7 board B1 does not settle within 1000 ticks"
		return
	end
	local deliver = false
	for k = 1, #lvl.goals do
		if lvl.goals[k].type == C.GOAL_DELIVER then deliver = true end
	end
	for i = 1, lvl.N do
		if lvl.exists[i] then
			if b1.slot[i] == 0 then
				errs[#errs + 1] = "2.1.7 cell stays empty on board B1" .. where(W, i)
			elseif deliver and not lvl.exit[i] and lvl.seg_bot[i] == (i - (i - 1) % W - 1) / W + 1 then
				errs[#errs + 1] = "2.1.8 segment bottom is not an exit" .. where(W, i)
			end
		end
	end
end

-- Loader -----------------------------------------------------------------------

function L.load(input)
	local raw
	if type(input) == "string" then
		local v, why = J.decode(input)
		if v == nil then return nil, { why } end
		raw = v
	elseif type(input) == "table" then
		raw = input
	else
		return nil, { "2.2 level must be JSON text or a decoded table" }
	end
	local errs = {}
	schema(raw, errs)
	if #errs > 0 then return nil, errs end
	local lvl, slot_at = normalize(raw, errs)
	if #errs > 0 then return nil, errs end
	fill_checks(lvl, slot_at, errs)
	if #errs > 0 then return nil, errs end
	-- start boards for seeds 1..10 (2.1.10)
	local ST = require("core.start")
	for seed = 1, 10 do
		local _, report = ST.build(lvl, seed, {})
		if report.shuffle >= 3 then
			errs[#errs + 1] = "2.1.10 start board for seed " .. seed .. " reaches shuffle item 3"
		end
	end
	if #errs > 0 then return nil, errs end
	lvl.canonical = L.canonical(raw)
	lvl.hash = require("core.hash").fold_bytes(lvl.canonical)
	return lvl
end

return L
