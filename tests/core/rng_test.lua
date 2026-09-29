local R = require("core.rng")

describe("core rng: MRG32k3a", function()
	it("matches L'Ecuyer's reference generator from the seed 12345 x 6", function()
		-- canonical outputs 0.12701112204657714, 0.3185275653967945, ...
		-- times (m1 + 1); computed independently with exact integers
		local s = { 12345, 12345, 12345, 12345, 12345, 12345 }
		assert_eq(R.next_int(s), 545508589)
		assert_eq(R.next_int(s), 1368065410)
		assert_eq(R.next_int(s), 1327943761)
	end)

	it("golden: first 5 outputs of every stream at seed = 1 (17.1)", function()
		local want = {
			{ 223457433, 576438160, 1623013424, 3274766834, 92483361 },
			{ 4033157654, 2715280548, 3902377367, 1388833721, 4234356859 },
			{ 2708149165, 3512045681, 162602400, 2724428392, 3620756976 },
			{ 784125594, 3284517567, 3857009143, 3366493652, 1651846368 },
		}
		for k = 1, 4 do
			local s = R.stream(1, k)
			local got = {}
			for j = 1, 5 do got[j] = R.next_int(s) end
			assert_same(got, want[k], "stream " .. k)
		end
	end)

	it("initialises a stream by 3.1 (six MINSTD steps, eight discarded outputs)", function()
		assert_same(R.stream(1, 2), { 4187425864, 3265927354, 3630296948, 17730881, 3339572737, 2299171507 })
	end)

	it("maps x = 0 to 1 when seeding", function()
		-- 1840683544*7 + 104729 + 12345 is a multiple of 2^31 - 1
		local want = { 3334291366, 1106267188, 2469751444, 1764236063, 2388833552, 2175428116 }
		assert_same(R.stream(1840683544, 1), want)
	end)

	it("stays exact near the modulus: outputs are integers in [0, m1 - 1]", function()
		local s = R.stream(123456789, 3)
		for _ = 1, 2000 do
			local v = R.next_int(s)
			assert_true(v >= 0 and v < 4294967087 and v == math.floor(v))
		end
	end)

	it("int(n) spends one output and returns 1..n", function()
		local a, b = R.stream(5, 1), R.stream(5, 1)
		for _ = 1, 100 do
			local v = R.int(a, 7)
			assert_eq(v, R.next_int(b) % 7 + 1)
			assert_true(v >= 1 and v <= 7)
		end
	end)

	it("weighted choice walks colours in global order with r = next % total", function()
		local a, b = R.stream(9, 2), R.stream(9, 2)
		local colors = { 1, 3, 5 }
		local weights = { [1] = 2, [3] = 1, [5] = 7 }
		for _ = 1, 50 do
			local r = R.next_int(b) % 10
			local want = r < 2 and 1 or (r < 3 and 3 or 5)
			assert_eq(R.weighted(a, colors, weights), want)
		end
	end)

	it("folds attempt seeds by 3.1", function()
		assert_eq(R.attempt_seed(42, 1, 0), 1409694745)
		assert_eq(R.attempt_seed(1, 1, 1), 365308133)
		assert_eq(R.attempt_seed(100, 3, 2147483645), 1263509102)
	end)
end)
