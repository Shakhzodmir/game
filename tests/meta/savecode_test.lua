local savecode = require("meta.savecode")
local save = require("meta.save")
local util = require("meta.util")
local H = require("tests.meta.helper")

local function busy()
	local m = H.new(31)
	H.advance_to(m, 12)
	H.give(m, "coins", 777)
	m:set_setting("music", 0.35)
	m:complete_task("cafe", "turntable")
	return m
end

local function same(a, b, path)
	path = path or "save"
	if type(a) ~= type(b) then error(path .. " type", 0) end
	if type(a) ~= "table" then
		if a ~= b then error(path .. ": " .. tostring(a) .. " vs " .. tostring(b), 0) end
		return
	end
	for k, v in pairs(a) do same(v, b[k], path .. "." .. tostring(k)) end
	for k in pairs(b) do if a[k] == nil then error(path .. "." .. tostring(k), 0) end end
end

describe("save code", function()
	local tbl = busy():serialize()
	local code = savecode.encode(tbl)

	it("has the version prefix and only url-safe characters", function()
		assert_eq(code:sub(1, 6), "GLOW1-")
		assert_true(code:match("^[%w_%-]+$") ~= nil)
	end)

	it("round-trips the save without losses", function()
		local back, sum = savecode.read(code, H.districts())
		assert_true(back ~= nil, tostring(sum))
		same(tbl, back)
		assert_eq(sum.beaten, 11)
		assert_eq(save.checksum(back), back.checksum)
	end)

	it("is deterministic", function()
		assert_eq(savecode.encode(tbl), code)
	end)

	it("holds nothing but the save: no address, no key", function()
		local data = savecode.b64_decode(code:sub(7, #code - 16))
		assert_true(data ~= nil)
		for _, bad in ipairs({ "http", "key", "token", "shakhzodmir" }) do
			assert_true(not data:lower():find(bad, 1, true), bad)
		end
	end)

	it("compresses and decompresses text", function()
		local s = string.rep("abcabcabc-glow ", 200)
		local z = savecode.compress(s)
		assert_true(#z < #s)
		assert_eq(savecode.decompress(z), s)
	end)

	it("ignores spaces and line breaks", function()
		local cut = code:sub(1, 20) .. " \n" .. code:sub(21, 60) .. "\r\n" .. code:sub(61)
		assert_true(savecode.read(cut, H.districts()) ~= nil)
	end)

	it("refuses an empty string and a non-string", function()
		local _, why = savecode.read("", H.districts())
		assert_eq(why, "empty")
		_, why = savecode.read("   \n", H.districts())
		assert_eq(why, "empty")
		_, why = savecode.read(nil, H.districts())
		assert_eq(why, "empty")
	end)

	it("refuses a foreign prefix and a foreign version", function()
		local _, why = savecode.read("hello world", H.districts())
		assert_eq(why, "prefix")
		_, why = savecode.read("GLOW2-" .. code:sub(7), H.districts())
		assert_eq(why, "version")
		_, why = savecode.read("GLOW-" .. code:sub(7), H.districts())
		assert_eq(why, "prefix")
	end)

	it("refuses a cut code", function()
		for _, n in ipairs({ 6, 10, 40, math.floor(#code / 2), #code - 1, #code - 17 }) do
			local back = savecode.read(code:sub(1, n), H.districts())
			assert_eq(back, nil, "cut to " .. n)
		end
	end)

	it("refuses a code with one changed character, anywhere", function()
		local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
		local step = math.max(1, math.floor(#code / 150))
		for i = 7, #code, step do
			local c = code:sub(i, i)
			local r = alphabet:sub(alphabet:find(c, 1, true) % #alphabet + 1)
			r = r:sub(1, 1)
			local bad = code:sub(1, i - 1) .. r .. code:sub(i + 1)
			assert_eq(savecode.read(bad, H.districts()), nil, "changed at " .. i)
		end
	end)

	it("refuses a valid code whose save was edited (the save's own checksum)", function()
		local t = util.copy(tbl)
		t.wallet.coins = t.wallet.coins + 5000 -- checksum of the save now wrong
		local forged = savecode.encode(t)
		local back, why = savecode.read(forged, H.districts())
		assert_eq(back, nil)
		assert_eq(why, "bad_save")
	end)

	it("refuses an absurdly long code", function()
		local _, why = savecode.read("GLOW1-" .. string.rep("A", savecode.MAX_CODE + 1), H.districts())
		assert_eq(why, "too_long")
	end)

	it("tells a code with less progress from the current one", function()
		local low = H.new(31)
		H.advance_to(low, 5)
		local a = savecode.summary(low:serialize(), H.districts())
		local b = savecode.summary(tbl, H.districts())
		assert_true(savecode.behind(a, b))
		assert_false(savecode.behind(b, a))
		assert_false(savecode.behind(b, b))
	end)
end)
