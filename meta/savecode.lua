-- Save code: the whole save as one line of text a player can copy to another
-- computer or browser (a stop-gap until accounts exist).
--
--   local savecode = require("meta.savecode")
--   local code = savecode.encode(meta:serialize())          -- "GLOW1-...."
--   local tbl, sum = savecode.read(code, districts)         -- save table + summary, or nil, reason
--
-- Layout: "GLOW1-" .. base64url(flag .. data) .. check
--   flag   "0" = data as is, "1" = data compressed (LZSS, kept only when the code gets shorter)
--   data   the save table in a compact text form (numbers with 17 digits: exact round trip)
--   check  16 hex digits over flag .. data: a cut or mistyped code is refused before it is parsed
-- The save table keeps its own version and checksum (meta/save.lua), verified again on import,
-- so a code carries nothing but the save: no keys, no addresses, no names.
--
-- Pure Lua 5.1 without bit operations; deterministic (no pairs order, no time, no random).
-- Reasons returned by read(): "empty", "prefix", "version", "format", "checksum", "corrupt",
-- "bad_save" (the save inside is not valid), "too_long".

local save = require("meta.save")
local util = require("meta.util")
local town = require("meta.town")

local M = {}

M.PREFIX = "GLOW"
M.VERSION = 1
M.HEAD = M.PREFIX .. M.VERSION .. "-"
M.MAX_CODE = 200000     -- characters accepted by read()
M.MAX_DATA = 1000000    -- bytes a code may unpack to
local MAX_DEPTH = 16

local floor, char, byte = math.floor, string.char, string.byte

-- value <-> text -----------------------------------------------------------------------------

local function enc(v, out, depth)
	local tv = type(v)
	if tv == "number" then
		if v ~= v or v == math.huge or v == -math.huge then error("savecode: non-finite number", 0) end
		if v == 0 then v = 0 end
		out[#out + 1] = "n" .. string.format("%.17g", v) .. ";"
	elseif tv == "string" then
		out[#out + 1] = "s" .. #v .. ":" .. v
	elseif tv == "boolean" then
		out[#out + 1] = v and "T" or "F"
	elseif tv == "table" then
		if depth > MAX_DEPTH then error("savecode: too deep", 0) end
		local n, count, keys = #v, 0, {}
		for k in pairs(v) do -- order-free: keys are sorted below
			count = count + 1
			if type(k) == "string" then keys[#keys + 1] = k end
		end
		if #keys == 0 and count == n then
			out[#out + 1] = "["
			for i = 1, n do enc(v[i], out, depth + 1) end
			out[#out + 1] = "]"
		elseif #keys == count then
			table.sort(keys, util.str_less)
			out[#out + 1] = "{"
			for _, k in ipairs(keys) do
				out[#out + 1] = "s" .. #k .. ":" .. k
				enc(v[k], out, depth + 1)
			end
			out[#out + 1] = "}"
		else
			error("savecode: a table mixes array and map keys", 0)
		end
	else
		error("savecode: unsupported value of type " .. tv, 0)
	end
end

-- Parses one value at position i. Returns value, next position; or nil, reason.
local dec
local function dec_string(s, i)
	local lenstr, colon = s:match("^(%d+):()", i + 1)
	if not lenstr or #lenstr > 7 then return nil, "string" end
	local len = tonumber(lenstr)
	if colon + len - 1 > #s then return nil, "string" end
	return s:sub(colon, colon + len - 1), colon + len
end

dec = function(s, i, depth)
	local c = s:sub(i, i)
	if c == "n" then
		local text, nxt = s:match("^n([^;]*);()", i)
		if not text or not text:match("^-?%d+%.?%d*[eE]?[+-]?%d*$") then return nil, "number" end
		local v = tonumber(text)
		if not v or v ~= v or v == math.huge or v == -math.huge then return nil, "number" end
		return v, nxt
	elseif c == "s" then
		return dec_string(s, i)
	elseif c == "T" then
		return true, i + 1
	elseif c == "F" then
		return false, i + 1
	elseif c == "[" or c == "{" then
		if depth > MAX_DEPTH then return nil, "deep" end
		local t, pos = {}, i + 1
		local close = c == "[" and "]" or "}"
		if c == "[" then
			local n = 0
			while s:sub(pos, pos) ~= close do
				if pos > #s then return nil, "open" end
				local v, nxt = dec(s, pos, depth + 1)
				if v == nil then return nil, nxt end
				n = n + 1
				t[n] = v
				pos = nxt
			end
		else
			while s:sub(pos, pos) ~= close do
				if pos > #s then return nil, "open" end
				if s:sub(pos, pos) ~= "s" then return nil, "key" end
				local k, after = dec_string(s, pos)
				if k == nil then return nil, after end
				if t[k] ~= nil then return nil, "duplicate" end
				local v, nxt = dec(s, after, depth + 1)
				if v == nil then return nil, nxt end
				t[k] = v
				pos = nxt
			end
		end
		return t, pos + 1
	end
	return nil, "token"
end

-- Table -> compact text.
function M.pack(tbl)
	local out = {}
	enc(tbl, out, 0)
	return table.concat(out)
end

-- Compact text -> table, or nil and a reason.
function M.unpack(text)
	if type(text) ~= "string" or text == "" then return nil, "empty" end
	local ok, v, nxt = pcall(dec, text, 1, 0)
	if not ok or v == nil then return nil, "corrupt" end
	if nxt ~= #text + 1 or type(v) ~= "table" then return nil, "corrupt" end
	return v
end

-- compression (LZSS) --------------------------------------------------------------------------
-- Groups of 8 items behind a flag byte (bit i set = literal byte). A match is two bytes:
-- offset 1..4095 (12 bits) and length 3..18 (4 bits).

local WINDOW, MIN_LEN, MAX_LEN, CHAIN = 4095, 3, 18, 24

function M.compress(s)
	local n = #s
	local out, group, items, flags, bit = {}, {}, 0, 0, 1
	local heads = {} -- 3-byte string -> list of positions
	local function flush()
		out[#out + 1] = char(flags) .. table.concat(group)
		group, items, flags, bit = {}, 0, 0, 1
	end
	local function index(p)
		if p + 2 <= n then
			local key = s:sub(p, p + 2)
			local list = heads[key]
			if not list then
				list = {}
				heads[key] = list
			end
			list[#list + 1] = p
		end
	end
	local i = 1
	while i <= n do
		local best_len, best_off = 0, 0
		if i + 2 <= n then
			local list = heads[s:sub(i, i + 2)]
			if list then
				local tried = 0
				for k = #list, 1, -1 do
					local p = list[k]
					local off = i - p
					if off > WINDOW or tried >= CHAIN then break end
					tried = tried + 1
					local len = 3
					while len < MAX_LEN and i + len <= n and byte(s, p + len) == byte(s, i + len) do len = len + 1 end
					if len > best_len then best_len, best_off = len, off end
					if len == MAX_LEN then break end
				end
			end
		end
		if best_len >= MIN_LEN then
			group[#group + 1] = char(best_off % 256, floor(best_off / 256) * 16 + (best_len - MIN_LEN))
			for p = i, i + best_len - 1 do index(p) end
			i = i + best_len
		else
			flags = flags + bit
			group[#group + 1] = s:sub(i, i)
			index(i)
			i = i + 1
		end
		items = items + 1
		bit = bit * 2
		if items == 8 then flush() end
	end
	if items > 0 then flush() end
	return table.concat(out)
end

-- Returns the text, or nil and a reason.
function M.decompress(z, max)
	max = max or M.MAX_DATA
	local out, n, i, len = {}, 0, 1, #z
	-- out holds single characters; matches copy from earlier characters
	while i <= len do
		local flags = byte(z, i)
		i = i + 1
		for b = 0, 7 do
			if i > len then break end
			if floor(flags / 2 ^ b) % 2 == 1 then
				n = n + 1
				out[n] = z:sub(i, i)
				i = i + 1
			else
				if i + 1 > len then return nil, "truncated" end
				local b1, b2 = byte(z, i), byte(z, i + 1)
				i = i + 2
				local off = b1 + floor(b2 / 16) * 256
				local l = b2 % 16 + MIN_LEN
				if off < 1 or off > n then return nil, "offset" end
				if n + l > max then return nil, "too_long" end
				for _ = 1, l do
					n = n + 1
					out[n] = out[n - off]
				end
			end
			if n > max then return nil, "too_long" end
		end
	end
	return table.concat(out)
end

-- base64url (no padding) ---------------------------------------------------------------------

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local DIGIT = {}
for k = 1, #ALPHABET do DIGIT[byte(ALPHABET, k)] = k - 1 end

function M.b64_encode(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = byte(s, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local d1, d2, d3, d4 = floor(n / 262144), floor(n / 4096) % 64, floor(n / 64) % 64, n % 64
		local chunk = ALPHABET:sub(d1 + 1, d1 + 1) .. ALPHABET:sub(d2 + 1, d2 + 1)
		if b then chunk = chunk .. ALPHABET:sub(d3 + 1, d3 + 1) end
		if c then chunk = chunk .. ALPHABET:sub(d4 + 1, d4 + 1) end
		out[#out + 1] = chunk
	end
	return table.concat(out)
end

function M.b64_decode(s)
	if #s % 4 == 1 then return nil end
	local out = {}
	for i = 1, #s, 4 do
		local n, cnt = 0, 0
		for k = i, math.min(i + 3, #s) do
			local d = DIGIT[byte(s, k)]
			if not d then return nil end
			n = n * 64 + d
			cnt = cnt + 1
		end
		for _ = cnt + 1, 4 do n = n * 64 end
		local b1, b2, b3 = floor(n / 65536), floor(n / 256) % 256, n % 256
		if cnt == 4 then out[#out + 1] = char(b1, b2, b3)
		elseif cnt == 3 then out[#out + 1] = char(b1, b2)
		else out[#out + 1] = char(b1) end
	end
	return table.concat(out)
end

-- check sum ------------------------------------------------------------------------------------

-- Two polynomial hashes modulo primes near 2^31 (every product stays below 2^53).
local function check_of(s)
	local a, b = 7919, 40009
	local text = "GLOW-code|" .. s
	for i = 1, #text do
		local c = byte(text, i)
		a = (a * 37 + c) % 2147483647
		b = (b * 101 + c + 3) % 2147483629
	end
	return string.format("%08x%08x", a, b)
end

-- code ------------------------------------------------------------------------------------------

-- Save table (meta:serialize()) -> code. Raises on a table that cannot be a save.
function M.encode(tbl)
	local data = M.pack(tbl)
	local flag, body = "0", data
	local z = M.compress(data)
	if #z + 1 < #data then flag, body = "1", z end
	local payload = flag .. body
	return M.HEAD .. M.b64_encode(payload) .. check_of(payload)
end

-- Code text -> save table, or nil and a reason (see the top). Spaces and line breaks are ignored.
-- The table is the save as written (checksum and version intact); it is not yet known to be a usable
-- save: read() also checks that.
function M.decode(code)
	if type(code) ~= "string" then return nil, "empty" end
	code = code:gsub("%s+", "")
	if code == "" then return nil, "empty" end
	if #code > M.MAX_CODE then return nil, "too_long" end
	if code:sub(1, #M.PREFIX) ~= M.PREFIX then return nil, "prefix" end
	local ver, rest = code:match("^" .. M.PREFIX .. "(%d+)%-(.*)$")
	if not ver then return nil, "prefix" end
	if tonumber(ver) ~= M.VERSION then return nil, "version" end
	if #rest < 17 + 16 or not rest:match("^[%w_%-]+$") then return nil, "format" end
	local body, check = rest:sub(1, #rest - 16), rest:sub(#rest - 15)
	local payload = M.b64_decode(body)
	if not payload or payload == "" then return nil, "format" end
	if check_of(payload) ~= check then return nil, "checksum" end
	local flag, data = payload:sub(1, 1), payload:sub(2)
	if flag == "1" then
		local why
		data, why = M.decompress(data)
		if not data then return nil, why == "too_long" and "too_long" or "corrupt" end
	elseif flag ~= "0" then
		return nil, "format"
	end
	local tbl, why = M.unpack(data)
	if not tbl then return nil, why end
	return tbl
end

-- What a save holds, for the player to see: {beaten = levels beaten, coins, stars, wins}.
-- Nil and a reason when the save cannot be loaded.
function M.summary(tbl, districts)
	local state, info = save.load(tbl, nil, town.validate(districts))
	if not state then return nil, (info.errors and info.errors.current) or "bad_save" end
	return {
		beaten = state.progress.beaten,
		coins = state.wallet.coins,
		stars = state.wallet.stars,
		wins = state.stats.wins,
	}
end

-- Code -> the save table and its summary, or nil and a reason. Checks the code (prefix, version,
-- check sum), then the save inside (its own version and checksum, then a full restore).
function M.read(code, districts)
	local tbl, why = M.decode(code)
	if not tbl then return nil, why end
	local sum, err = M.summary(tbl, districts)
	if not sum then return nil, "bad_save", err end
	return tbl, sum
end

-- True when save a (summary) is behind save b: fewer levels beaten, or the same levels and fewer stars.
function M.behind(a, b)
	if a.beaten ~= b.beaten then return a.beaten < b.beaten end
	return a.stars < b.stars
end

return M
