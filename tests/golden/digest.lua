-- A fold of an event stream (core-rules.md 16) into one integer, so that the
-- golden replays pin not only the final state hash but every event, field
-- and order of a whole game. Shared by tests/golden/regen.lua and
-- tests/core/golden_test.lua.

local D = {}

local MOD = 2147483629

local function fold(h, v)
	return (h * 65599 + v % 4294967296 + 1) % MOD
end

local function put_string(h, s)
	h = fold(h, #s)
	for i = 1, #s do h = fold(h, string.byte(s, i)) end
	return h
end

local function put(h, v)
	local t = type(v)
	if t == "number" then
		return fold(fold(h, 1), v)
	elseif t == "boolean" then
		return fold(fold(h, 2), v and 1 or 0)
	elseif t == "string" then
		return put_string(fold(h, 3), v)
	end
	local n = #v
	if n > 0 then
		h = fold(fold(h, 4), n)
		for i = 1, n do h = put(h, v[i]) end
		return h
	end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end -- order-independent (sorted next)
	table.sort(keys)
	h = fold(fold(h, 5), #keys)
	for _, k in ipairs(keys) do
		h = put(put_string(h, k), v[k])
	end
	return h
end

-- events: an array of event tables; returns (count, digest)
function D.events(events)
	local h = 0
	for i = 1, #events do h = put(h, events[i]) end
	return #events, h
end

return D
