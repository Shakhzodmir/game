-- Small helpers shared by the core modules. No state lives here.

local U = {}

local floor = math.floor

function U.is_int(v)
	return type(v) == "number" and v == floor(v) and v - v == 0
end

-- Cell index <-> 1-based coordinates.
function U.idx(W, x, y)
	return (y - 1) * W + x
end

function U.xy(W, i)
	local x = (i - 1) % W + 1
	return x, (i - x) / W + 1
end

-- Lexicographic comparison of labels (mv, wv).
function U.label_lt(m1, w1, m2, w2)
	return m1 < m2 or (m1 == m2 and w1 < w2)
end

function U.label_max(m1, w1, m2, w2)
	if m1 < m2 or (m1 == m2 and w1 < w2) then return m2, w2 end
	return m1, w1
end

-- Deep copy of plain data. The state has no shared sub-tables (except the
-- immutable level, passed in `keep`), so a plain recursive copy is exact.
local function deepcopy(v, keep)
	if type(v) ~= "table" or v == keep then return v end
	local t = {}
	for k, x in pairs(v) do -- order-independent
		t[k] = deepcopy(x, keep)
	end
	return t
end
U.deepcopy = deepcopy

function U.copy_array(a)
	local t = {}
	for i = 1, #a do t[i] = a[i] end
	return t
end

-- Sorted array of numbers used as a set.
function U.sorted_has(a, v)
	local lo, hi = 1, #a
	while lo <= hi do
		local mid = floor((lo + hi) / 2)
		local m = a[mid]
		if m == v then return true, mid end
		if m < v then lo = mid + 1 else hi = mid - 1 end
	end
	return false, lo
end

-- Inserts v keeping the array sorted; returns false if it was already there.
function U.sorted_add(a, v)
	local has, pos = U.sorted_has(a, v)
	if has then return false end
	table.insert(a, pos, v)
	return true
end

function U.sorted_remove(a, v)
	local has, pos = U.sorted_has(a, v)
	if has then table.remove(a, pos) end
	return has
end

-- Stable insertion sort by an integer key function (lists here are short).
function U.stable_sort(a, key)
	for i = 2, #a do
		local v = a[i]
		local kv = key(v)
		local j = i - 1
		while j >= 1 and key(a[j]) > kv do
			a[j + 1] = a[j]
			j = j - 1
		end
		a[j + 1] = v
	end
	return a
end

-- Sorted list of the keys of a table with integer keys.
function U.sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end -- order-independent (sorted below)
	table.sort(keys) -- numbers
	return keys
end

return U
