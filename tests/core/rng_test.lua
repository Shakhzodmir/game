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

	-- Known answers computed with exact Python integers from the text of 3.1
	-- (an independent implementation: stream state after the 8 discarded
	-- outputs, then the next four outputs).
	local KNOWN = {
		{ 5, 1, { 2079080022, 190734982, 3036605397, 2390605574, 306590290, 1673119323 }, { 3423108961, 862449560, 1777914196, 1365704678 } },
		{ 5, 2, { 3057464668, 874137980, 416544867, 4087117299, 3785976316, 1512244728 }, { 1499085390, 634944090, 1177376496, 2007747294 } },
		{ 5, 3, { 572537021, 3093521477, 1027836653, 593895073, 315858831, 285695884 }, { 174054257, 1431709223, 1732545972, 3343364609 } },
		{ 5, 4, { 1689102031, 3167714592, 3605279170, 2290406798, 3795244857, 124821289 }, { 3081218518, 3034330866, 2181782802, 407656966 } },
		{ 123456789, 1, { 1705428679, 1164728800, 441633547, 149084806, 1338896407, 1358813881 }, { 2854486462, 3988095260, 923331812, 1205100359 } },
		{ 123456789, 2, { 2683813325, 1848131798, 2116540104, 1845596531, 523337990, 1197939286 }, { 930462891, 3760567146, 322794112, 1847142975 } },
		{ 123456789, 3, { 3662197971, 2531534796, 3791446661, 2647318748, 1348164948, 4266334885 }, { 130543586, 3663334404, 2071503982, 325210018 } },
		{ 123456789, 4, { 1315450688, 4141708410, 1010307320, 48886030, 532606531, 4105460290 }, { 2512596019, 1865009479, 1327200418, 247052647 } },
		{ 2147483646, 1, { 4190037604, 4249448562, 1121456811, 19098297, 751492636, 2598653596 }, { 3008632643, 3801257488, 3167115563, 4033776105 } },
		{ 2147483646, 2, { 873455163, 637884473, 2796363368, 820820514, 1576319594, 1372104752 }, { 2208713338, 3704024746, 620858346, 2511843148 } },
		{ 2147483646, 3, { 2821674967, 2248058087, 15224027, 2517332239, 760761177, 1211230157 }, { 295798684, 1905677177, 4171521869, 2433685777 } },
		{ 2147483646, 4, { 3800059613, 2931461085, 1690130584, 3319054456, 1585588135, 4279625756 }, { 3790846466, 1808467079, 1625264652, 911752820 } },
	}

	it("matches an independent implementation for the extreme seeds, all four streams", function()
		for _, row in ipairs(KNOWN) do
			local seed, k = row[1], row[2]
			local s = R.stream(seed, k)
			assert_same(s, row[3], "state of stream " .. k .. " at seed " .. seed)
			local got = {}
			for j = 1, 4 do got[j] = R.next_int(s) end
			assert_same(got, row[4], "outputs of stream " .. k .. " at seed " .. seed)
		end
	end)

	it("streams(seed) is the four streams 1..4 (init, spawn, effects, shuffle)", function()
		assert_same({ R.INIT, R.SPAWN, R.EFFECTS, R.SHUFFLE }, { 1, 2, 3, 4 })
		local all = R.streams(5)
		assert_eq(#all, 4)
		for k = 1, 4 do assert_same(all[k], R.stream(5, k), "stream " .. k) end
		assert_true(all[1] ~= all[2] and all[2] ~= all[3], "independent tables")
	end)

	it("a stream never starts at the all-zero or an out-of-range state", function()
		for seed = 1, 300 do
			for k = 1, 4 do
				local s = R.stream(seed, k)
				local nonzero1 = s[1] ~= 0 or s[2] ~= 0 or s[3] ~= 0
				local nonzero2 = s[4] ~= 0 or s[5] ~= 0 or s[6] ~= 0
				assert_true(nonzero1 and nonzero2, "seed " .. seed .. " stream " .. k)
				for j = 1, 3 do assert_true(s[j] >= 0 and s[j] < 4294967087) end
				for j = 4, 6 do assert_true(s[j] >= 0 and s[j] < 4294944443) end
			end
		end
	end)

	it("int(1) still spends one output (3.2.1: a choice among n >= 1 options costs one draw)", function()
		local a, b = R.stream(3, 2), R.stream(3, 2)
		assert_eq(R.int(a, 1), 1)
		R.next_int(b)
		assert_same(a, b)
	end)

	it("the weighted choice spends exactly one output, also with one colour", function()
		local a, b = R.stream(8, 3), R.stream(8, 3)
		assert_eq(R.weighted(a, { 4 }, { [4] = 5 }), 4)
		R.next_int(b)
		assert_same(a, b)
	end)

	it("weighted: a weight of 1000 next to weight 1 colours still walks the cumulative sum", function()
		local a, b = R.stream(21, 2), R.stream(21, 2)
		local colors = { 2, 3, 5, 6 }
		local weights = { [2] = 1, [3] = 1000, [5] = 1, [6] = 3 }
		for _ = 1, 200 do
			local r = R.next_int(b) % 1005
			local want = r < 1 and 2 or (r < 1001 and 3 or (r < 1002 and 5 or 6))
			assert_eq(R.weighted(a, colors, weights), want)
		end
	end)

	it("attempt seeds: known answers, in range, one fold per value in the order (level, attempt, salt)", function()
		assert_eq(R.attempt_seed(7, 12, 99999), 1461573876)
		assert_eq(R.attempt_seed(1, 1, 0), 365308132)
		assert_eq(R.attempt_seed(1000, 20, 2147483646), 253303491)
		assert_true(R.attempt_seed(1, 2, 3) ~= R.attempt_seed(3, 2, 1), "the order of the values matters")
		for k = 0, 400 do
			local v = R.attempt_seed(k + 1, k % 7 + 1, k * 5003)
			assert_true(v >= 1 and v <= 2147483646 and v == math.floor(v))
		end
		assert_eq(R.fold_seed(5, 6, 7), R.attempt_seed(5, 6, 7), "clone reseeding uses the same formula")
	end)

	it("the seed fold stays exact for arguments up to 2^53 (no rounding of h*48271 + v + 1)", function()
		-- exact values from Python integers
		assert_eq(R.fold_seed(9007199254740991, 9007199254740991, 9007199254740991), 478507403)
		assert_eq(R.fold_seed(1, 9007199254740991, 2147483646), 964997155)
		assert_eq(R.attempt_seed(999999999999999, 1, 0), 363555808)
		assert_eq(R.attempt_seed(1, 999999999999999, 2147483646), 577783119)
	end)

	it("the seed range edges: h = 0 and h = 2^31 - 2 give seed 1, h = 2^31 - 3 gives 2^31 - 2", function()
		local M = 2147483647
		-- level 1, attempt 1 give h2 = 96544; pick the salt that ends the fold at the wanted h
		local h2 = ((2 * 48271 + 2) % M)
		local function salt_for(target) return (target - 1 - h2 * 48271) % M end
		assert_eq(R.attempt_seed(1, 1, salt_for(M - 1)), 1, "h = 2^31 - 2")
		assert_eq(R.attempt_seed(1, 1, salt_for(0)), 1, "h = 0")
		assert_eq(R.attempt_seed(1, 1, salt_for(M - 2)), M - 1, "h = 2^31 - 3: the largest seed")
		assert_eq(R.attempt_seed(1, 1, salt_for(1)), 2)
	end)
end)
