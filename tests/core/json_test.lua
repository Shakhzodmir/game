-- The strict JSON reader of level files (2.2): token-level checks that a
-- standard decoder would lose, and robustness against hostile text.

local J = require("core.json_strict")

local function ok(text)
	local v, why = J.decode(text)
	assert_true(v ~= nil, "should decode: " .. text .. " (" .. tostring(why) .. ")")
	return v
end

local function bad(text, part)
	local v, why = J.decode(text)
	assert_eq(v, nil, "should be rejected: " .. text)
	assert_eq(string.sub(why, 1, 8), "2.2 json", why)
	if part then assert_true(string.find(why, part, 1, true) ~= nil, why .. " should mention '" .. part .. "'") end
end

describe("core json_strict: tokens (2.2)", function()
	it("reads objects, arrays, strings, integers and booleans, whitespace anywhere", function()
		local v = ok(' \n\t{ "a" : [ 1 , -2 , 30 ] , "b" : { "c" : "x" } , "t" : true , "f" : false }\r\n')
		assert_same(v, { a = { 1, -2, 30 }, b = { c = "x" }, t = true, f = false })
		assert_same(ok("[]"), {})
		assert_same(ok("{}"), {})
		assert_same(ok("[[1],[2,[3]]]"), { { 1 }, { 2, { 3 } } })
	end)

	it("treats a null object value as a missing key, a null in an array as an error", function()
		assert_same(ok('{"a": null, "b": 1}'), { b = 1 })
		bad("[1, null]", "null inside an array")
		bad("[null]", "null inside an array")
		bad("null", "null document")
	end)

	it("rejects repeated keys, also when the first value is null", function()
		bad('{"a": 1, "a": 2}', "repeated key 'a'")
		bad('{"a": null, "a": 2}', "repeated key")
		bad('{"x": {"k": 1, "k": 1}}', "repeated key 'k'")
		ok('{"a": {"k": 1}, "b": {"k": 1}}') -- the same key in different objects is fine
	end)

	it("rejects numbers with a fraction or an exponent, leading zeros and long integers", function()
		for _, text in ipairs({ "1.0", "1.5", "1e2", "1E2", "1e-2", "-0.5", "[1.]" }) do
			bad(text, "not an integer")
		end
		bad("01", "leading zero")
		bad("-01", "leading zero")
		bad("-", "bad number")
		bad("[+1]", "unexpected character")
		bad("1234567890123456", "integer too large")
		assert_eq(ok("123456789012345"), 123456789012345)
		assert_eq(ok("-123456789012345"), -123456789012345)
		assert_eq(ok("0"), 0)
	end)

	it("reads minus zero as the plain zero (so that 2.2 canonical forms agree)", function()
		local v = ok("[-0, 0]")
		assert_eq(string.format("%.0f", v[1]), "0")
		assert_eq(string.format("%.0f", v[2]), "0")
	end)

	it("reads the standard escapes and ASCII \\u escapes, rejects the rest", function()
		assert_eq(ok([["a\"b\\c\/d\b\f\n\r\t"]]), 'a"b\\c/d\b\f\n\r\t')
		assert_eq(ok('"\\u0041\\u007e"'), "A~")
		assert_eq(ok('"\\u00417"'), "A7")
		bad('"\\u00e9"', "non-ASCII")
		bad('"\\u0080"', "non-ASCII")
		bad('"\\u12"', "bad \\u escape")
		bad('"\\u12zz"', "bad \\u escape")
		bad([["\q"]], "bad escape")
		bad('"a\nb"', "control character")
		bad('"abc', "unterminated string")
		bad('"abc\\') -- a lone backslash at the end
	end)

	it("rejects structural mistakes", function()
		bad("", "unexpected character")
		bad("   ", "unexpected character")
		bad("{", "expected a key")
		bad('{"a"}', "expected ':'")
		bad('{"a": 1,}', "expected a key")
		bad('{"a": 1 "b": 2}', "expected ',' or '}'")
		bad("[1, 2", "expected ',' or ']'")
		bad("[1,]", "unexpected character")
		bad("[1 2]", "expected ',' or ']'")
		bad("{1: 2}", "expected a key")
		bad("{} {}", "trailing characters")
		bad("tru", "unexpected character")
		bad("nul", "unexpected character")
		bad("[truex]", "expected ',' or ']'")
	end)

	it("does not accept anything but a string as input", function()
		local v, why = J.decode(nil)
		assert_eq(v, nil)
		assert_eq(string.sub(why, 1, 8), "2.2 json")
		v = J.decode(12)
		assert_eq(v, nil)
	end)

	it("answers hostile nesting with an error instead of a Lua stack overflow", function()
		for _, depth in ipairs({ 50, 5000, 100000 }) do
			local text = string.rep("[", depth) .. string.rep("]", depth)
			local ok_, v, why = pcall(J.decode, text)
			assert_true(ok_, "depth " .. depth .. " must not raise: " .. tostring(v))
			assert_eq(v, nil, "depth " .. depth)
			assert_true(string.find(why, "nesting", 1, true) ~= nil, why)
		end
		local deep_obj = string.rep('{"a":', 3000) .. "1" .. string.rep("}", 3000)
		local ok_, v, why = pcall(J.decode, deep_obj)
		assert_true(ok_)
		assert_eq(v, nil)
		assert_true(string.find(why, "nesting", 1, true) ~= nil, why)
		-- the deepest document a level can need is a handful of levels deep
		ok(string.rep("[", 16) .. string.rep("]", 16))
	end)

	it("never raises on random JSON-like soup", function()
		local alphabet = { "{", "}", "[", "]", ",", ":", '"', "\\", "-", "0", "1", "9", ".", "e", "E", "t", "r", "u",
			"f", "a", "l", "s", "n", " ", "\n", "x", "\0", "\200", "/" }
		local x = 12345
		local function rnd(n)
			x = (x * 1103515245 + 12345) % 2147483648
			return math.floor(x / 65536) % n + 1
		end
		for _ = 1, 3000 do
			local parts = {}
			for k = 1, rnd(30) do parts[k] = alphabet[rnd(#alphabet)] end
			local text = table.concat(parts)
			local ok_, v, why = pcall(J.decode, text)
			assert_true(ok_, string.format("%q raised %s", text, tostring(v)))
			if v == nil then assert_eq(string.sub(why, 1, 8), "2.2 json") end
		end
	end)
end)

describe("core json_strict: edge cases found by differential testing against a Python reader", function()
	it("accepts exactly the JSON whitespace set (space, tab, CR, LF) around tokens", function()
		assert_same(ok(" \t\r\n[ \t1\r,\n2 ]\t"), { 1, 2 })
		bad("\v[1]", "unexpected character")
		bad("[1,\f2]", "unexpected character")
		bad("\239\187\191[1]", "unexpected character") -- a byte order mark is not JSON
	end)

	it("a key repeated after an escape is still a repeat; keys are compared decoded", function()
		bad('{"a": 1, "\\u0061": 2}', "repeated key 'a'")
		bad('{"a\\/b": 1, "a/b": 2}', "repeated key")
		ok('{"a": 1, "A": 2}')
	end)

	it("a scalar document decodes (the schema rejects it later); null as a document does not", function()
		assert_eq(ok("5"), 5)
		assert_eq(ok('"x"'), "x")
		assert_eq(ok("true"), true)
		assert_eq(ok("false"), false)
		bad("null", "null document")
		bad(" null ", "null document")
	end)

	it("nesting: 32 containers deep are fine, 33 are refused with a message, not a crash", function()
		ok(string.rep("[", 32) .. string.rep("]", 32))
		bad(string.rep("[", 33) .. string.rep("]", 33), "nesting too deep")
		ok(string.rep('{"k":', 32) .. "1" .. string.rep("}", 32))
		bad(string.rep('{"k":', 33) .. "1" .. string.rep("}", 33), "nesting too deep")
	end)

	it("integers: 15 digits exactly, any sign, no plus, no leading zero except 0 itself", function()
		assert_eq(ok("[-0]")[1], 0)
		assert_eq(ok("999999999999999"), 999999999999999)
		bad("1000000000000000", "integer too large")
		bad("-1000000000000000", "integer too large")
		bad("00", "leading zero")
		bad("-00", "leading zero")
		bad("1 2", "trailing characters")
		bad("[1.5e3]", "not an integer")
		bad("[1e]", "not an integer")
		bad("--1", "bad number")
	end)

	it("strings: control bytes below 32 must be escaped, DEL and high bytes pass through raw", function()
		bad('"a\1b"', "control character")
		bad('"a' .. string.char(9) .. 'b"', "control character")
		assert_eq(ok('"a' .. string.char(127) .. 'b"'), "a" .. string.char(127) .. "b")
		assert_eq(ok('"\195\169"'), "\195\169", "raw UTF-8 bytes are kept as they are")
		assert_eq(ok('"\\u0041\\u005A\\u007F"'), "AZ" .. string.char(127))
		assert_eq(ok('"\\u0000"'), "\0", "an escaped NUL is a valid ASCII character")
	end)

	it("objects: null values vanish, the same key with a value after a null is a repeat, empty key is fine", function()
		assert_same(ok('{"": 1}'), { [""] = 1 })
		assert_same(ok('{"a": null, "b": null}'), {})
		bad('{"a": 1, "a": null}', "repeated key")
	end)
end)

describe("core json_strict: positions and boundaries (audit A)", function()
	it("a space is a legal character inside a string, byte 31 is not", function()
		assert_eq(ok('"a b"'), "a b")
		assert_eq(ok('" "'), " ")
		bad('"a' .. string.char(31) .. 'b"', "control character")
		bad('"a' .. string.char(0) .. 'b"', "control character")
		assert_eq(ok('"a' .. string.char(32) .. 'b"'), "a b")
	end)

	it("tokens follow each other without any whitespace", function()
		assert_same(ok('{"a":1,"b":[2,3],"c":{"d":true,"e":false},"f":"x"}'), { a = 1, b = { 2, 3 }, c = { d = true, e = false }, f = "x" })
		assert_same(ok("[false,true,false]"), { false, true, false })
		assert_same(ok("[[],[],{}]"), { {}, {}, {} })
		assert_same(ok('{"a":{},"b":[],"c":1}'), { a = {}, b = {}, c = 1 })
		assert_same(ok('[{},1]'), { {}, 1 })
		assert_same(ok('{"a":{"b":{}},"c":2}'), { a = { b = {} }, c = 2 })
	end)

	it("any amount of whitespace sits between tokens", function()
		assert_same(ok('{  "a"  :   [  1  ,   2  ]   ,   "b"  :  {  }  }'), { a = { 1, 2 }, b = {} })
		assert_same(ok("[\n\n1,\n\n2\n\n]"), { 1, 2 })
	end)

	it("the reader names the byte of the mistake", function()
		local _, why = J.decode("null")
		assert_eq(why, "2.2 json: null document at byte 1")
		_, why = J.decode("  [1, null]")
		assert_eq(why, "2.2 json: null inside an array at byte 7", "the byte where the null starts")
		_, why = J.decode('{"a": 1, "a": 2}')
		assert_eq(why, "2.2 json: repeated key 'a' at byte 10", "the byte where the second key starts")
		_, why = J.decode("[1] x")
		assert_eq(why, "2.2 json: trailing characters at byte 5")
		_, why = J.decode("")
		assert_eq(why, "2.2 json: unexpected character at byte 1")
	end)
end)
