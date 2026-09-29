-- MRG32k3a (L'Ecuyer) exactly as in core-rules.md 3.1.
--
-- A stream is a plain array of six integers: s[1..3] component 1 (oldest to
-- newest), s[4..6] component 2. All intermediate values stay below 2^53, so
-- the arithmetic is exact on doubles (Lua 5.1 and LuaJIT alike).

local R = {}

local M1, M2 = 4294967087, 4294944443
local A12, A13, A21, A23 = 1403580, 810728, 527612, 1370589
local MINSTD = 2147483647

R.INIT, R.SPAWN, R.EFFECTS, R.SHUFFLE = 1, 2, 3, 4

-- Next integer in [0, m1 - 1].
function R.next_int(s)
	local p1 = (A12 * s[2] - A13 * s[1]) % M1
	local p2 = (A21 * s[6] - A23 * s[4]) % M2
	s[1], s[2], s[3] = s[2], s[3], p1
	s[4], s[5], s[6] = s[5], s[6], p2
	return (p1 - p2) % M1
end

-- Integer in [1, n], n >= 1.
function R.int(s, n)
	return R.next_int(s) % n + 1
end

-- Stream k (init = 1, spawn = 2, effects = 3, shuffle = 4) for a seed.
function R.stream(seed, k)
	local x = (seed * 7 + k * 104729 + 12345) % MINSTD
	if x == 0 then x = 1 end
	local s = {}
	for i = 1, 6 do
		x = x * 48271 % MINSTD
		s[i] = x
	end
	for _ = 1, 8 do R.next_int(s) end
	return s
end

-- The four streams of a game, indexed by stream number.
function R.streams(seed)
	return { R.stream(seed, 1), R.stream(seed, 2), R.stream(seed, 3), R.stream(seed, 4) }
end

-- Seed fold of 3.1: h = (h*48271 + v + 1) % (2^31 - 1) over the values,
-- result h % (2^31 - 2) + 1. Used for attempt seeds and clone reseeding.
function R.fold_seed(a, b, c)
	local h = 0
	h = (h * 48271 + a + 1) % MINSTD
	h = (h * 48271 + b + 1) % MINSTD
	h = (h * 48271 + c + 1) % MINSTD
	return h % (MINSTD - 1) + 1
end

function R.attempt_seed(level_id, attempt, salt)
	return R.fold_seed(level_id, attempt, salt)
end

-- Weighted colour choice (3.2.2) among `colors` (ascending codes) with
-- weights[code]. Spends exactly one next_int.
function R.weighted(s, colors, weights)
	local total = 0
	for i = 1, #colors do total = total + weights[colors[i]] end
	local r = R.next_int(s) % total
	local acc = 0
	for i = 1, #colors do
		local c = colors[i]
		acc = acc + weights[c]
		if acc > r then return c end
	end
	return colors[#colors] -- unreachable: acc reaches total > r
end

return R
