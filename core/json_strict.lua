-- Strict JSON reader for level files (2.2).
--
-- Standard decoders lose information the level rules need, so this one
-- checks the token stream itself: `null` inside an array, a number with a
-- fraction or an exponent and a repeated key in an object are errors.
-- `null` as an object value is kept out of the result (it equals a missing
-- key). Objects and arrays both decode to Lua tables; the level schema
-- knows which is which.

local J = {}

local function err(pos, what)
	error({ json = true, msg = "2.2 json: " .. what .. " at byte " .. pos }, 0)
end

local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
local NULL = {}

local function skip(str, pos)
	local _, e = string.find(str, "^[ \t\r\n]*", pos)
	return e + 1
end

local parse_value

local function parse_string(str, pos)
	-- str:sub(pos, pos) == '"'
	local out = {}
	local i = pos + 1
	while true do
		local c = string.sub(str, i, i)
		if c == "" then err(i, "unterminated string") end
		if c == '"' then return table.concat(out), i + 1 end
		if c == "\\" then
			local e = string.sub(str, i + 1, i + 1)
			if ESC[e] then
				out[#out + 1] = ESC[e]
				i = i + 2
			elseif e == "u" then
				local hex = string.sub(str, i + 2, i + 5)
				if not string.find(hex, "^%x%x%x%x$") then err(i, "bad \\u escape") end
				local n = tonumber(hex, 16)
				if n >= 128 then err(i, "non-ASCII \\u escape") end
				out[#out + 1] = string.char(n)
				i = i + 6
			else
				err(i, "bad escape")
			end
		else
			if string.byte(c) < 32 then err(i, "control character in string") end
			out[#out + 1] = c
			i = i + 1
		end
	end
end

local function parse_number(str, pos)
	local s, e = string.find(str, "^-?%d+", pos)
	if not s then err(pos, "bad number") end
	local text = string.sub(str, s, e)
	local nxt = string.sub(str, e + 1, e + 1)
	if nxt == "." or nxt == "e" or nxt == "E" then err(pos, "number is not an integer") end
	if string.find(text, "^-?0%d") then err(pos, "leading zero") end
	local digits = #text - (string.sub(text, 1, 1) == "-" and 1 or 0)
	if digits > 15 then err(pos, "integer too large") end
	return tonumber(text), e + 1
end

local function parse_array(str, pos)
	local arr = {}
	local i = skip(str, pos + 1)
	if string.sub(str, i, i) == "]" then return arr, i + 1 end
	while true do
		local v
		v, i = parse_value(str, i)
		if v == NULL then err(i, "null inside an array") end
		arr[#arr + 1] = v
		i = skip(str, i)
		local c = string.sub(str, i, i)
		if c == "]" then return arr, i + 1 end
		if c ~= "," then err(i, "expected ',' or ']'") end
		i = skip(str, i + 1)
	end
end

local function parse_object(str, pos)
	local obj, seen = {}, {}
	local i = skip(str, pos + 1)
	if string.sub(str, i, i) == "}" then return obj, i + 1 end
	while true do
		if string.sub(str, i, i) ~= '"' then err(i, "expected a key") end
		local key
		key, i = parse_string(str, i)
		if seen[key] then err(i, "repeated key '" .. key .. "'") end
		seen[key] = true
		i = skip(str, i)
		if string.sub(str, i, i) ~= ":" then err(i, "expected ':'") end
		local v
		v, i = parse_value(str, skip(str, i + 1))
		if v ~= NULL then obj[key] = v end
		i = skip(str, i)
		local c = string.sub(str, i, i)
		if c == "}" then return obj, i + 1 end
		if c ~= "," then err(i, "expected ',' or '}'") end
		i = skip(str, i + 1)
	end
end

parse_value = function(str, pos)
	local c = string.sub(str, pos, pos)
	if c == "{" then return parse_object(str, pos) end
	if c == "[" then return parse_array(str, pos) end
	if c == '"' then return parse_string(str, pos) end
	if c == "-" or string.find(c, "^%d") then return parse_number(str, pos) end
	if string.sub(str, pos, pos + 3) == "true" then return true, pos + 4 end
	if string.sub(str, pos, pos + 4) == "false" then return false, pos + 5 end
	if string.sub(str, pos, pos + 3) == "null" then return NULL, pos + 4 end
	err(pos, "unexpected character")
end

-- Returns the decoded value, or nil and an error message.
function J.decode(str)
	if type(str) ~= "string" then return nil, "2.2 json: not a string" end
	local ok, res = pcall(function()
		local v, i = parse_value(str, skip(str, 1))
		i = skip(str, i)
		if i <= #str then err(i, "trailing characters") end
		if v == NULL then err(1, "null document") end
		return v
	end)
	if ok then return res end
	if type(res) == "table" and res.json then return nil, res.msg end
	error(res, 0)
end

return J
