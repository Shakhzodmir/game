-- Small helpers shared by the meta modules. Pure Lua 5.1.

local M = {}

local floor, huge = math.floor, math.huge

-- A finite whole number.
function M.is_int(v)
	return type(v) == "number" and v == floor(v) and v > -huge and v < huge
end

-- Reads a stored integer: anything that is not a finite number becomes
-- `default`, fractions are floored, the result is clamped to [lo, hi].
function M.int(v, default, lo, hi)
	if type(v) ~= "number" or v ~= v or v == huge or v == -huge then return default end
	v = floor(v)
	if lo and v < lo then v = lo end
	if hi and v > hi then v = hi end
	return v
end

function M.index_of(list, value)
	for i = 1, #list do
		if list[i] == value then return i end
	end
	return nil
end

-- Byte-wise string order. Lua 5.1 compares strings with strcoll, which
-- depends on the C locale; this does not.
function M.str_less(a, b)
	local n = math.min(#a, #b)
	for i = 1, n do
		local x, y = a:byte(i), b:byte(i)
		if x ~= y then return x < y end
	end
	return #a < #b
end

-- Deep copy of plain data (numbers, strings, booleans, tables).
function M.copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = M.copy(x) end -- order-free: builds a table
	return out
end

-- Every time-aware call takes the current time in seconds as its last
-- argument; the fraction is ignored. `level` works like error()'s level as
-- seen from the function that calls check_now: 1 blames that function, 2 its
-- caller, and so on (default 2).
function M.check_now(now, level)
	if type(now) ~= "number" or now ~= now or now < 0 or now == huge then
		error("meta: 'now' must be a non-negative number of seconds, got " .. tostring(now), (level or 2) + 1)
	end
	return floor(now)
end

return M
