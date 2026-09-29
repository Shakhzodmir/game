-- Level schema (2.0, rule 2.1.1) and canonical form (2.2).
--
-- Works on the decoded level table: objects and arrays are both Lua tables,
-- the schema knows which is which.

local C = require("core.const")
local U = require("core.util")

local LS = {}

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

function LS.canonical(raw)
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

function LS.check(raw, errs)
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

LS.is_object = is_object
LS.is_array = is_array

return LS
