-- The shared helpers of the core (core/util.lua).

local U = require("core.util")

describe("core util: integers and indexes (section 0)", function()
	it("is_int accepts exact integers only", function()
		for _, v in ipairs({ 0, 1, -1, 6, 2147483647, -2147483648, 4294967296, 9007199254740992, -9007199254740992 }) do
			assert_true(U.is_int(v), tostring(v))
		end
		local nz = -0
		assert_true(U.is_int(nz), "minus zero is the integer zero")
		for _, v in ipairs({ 0.5, -0.5, 1e-9, 1 / 0, -1 / 0, 0 / 0, 9007199254740994, 1e300, -1e300, 2 ^ 60 }) do
			assert_false(U.is_int(v), tostring(v))
		end
		for _, v in ipairs({ "1", true, false, {}, print }) do
			assert_false(U.is_int(v), type(v))
		end
		assert_false(U.is_int(nil))
	end)

	it("cell index and 1-based coordinates convert both ways (i = (y-1)*W + x)", function()
		for _, W in ipairs({ 6, 7, 9 }) do
			for y = 1, 11 do
				for x = 1, W do
					local i = U.idx(W, x, y)
					assert_eq(i, (y - 1) * W + x)
					local xx, yy = U.xy(W, i)
					assert_eq(xx, x)
					assert_eq(yy, y)
				end
			end
		end
		assert_eq(U.idx(9, 1, 1), 1)
		assert_eq(U.idx(9, 9, 2), 18)
	end)
end)

describe("core util: labels and copies", function()
	it("compares labels lexicographically: act first, wave second (1.3)", function()
		assert_true(U.label_lt(0, 5, 1, 0))
		assert_true(U.label_lt(2, 1, 2, 2))
		assert_false(U.label_lt(2, 2, 2, 2))
		assert_false(U.label_lt(3, 0, 2, 9))
		assert_same({ U.label_max(1, 9, 2, 0) }, { 2, 0 })
		assert_same({ U.label_max(2, 3, 2, 1) }, { 2, 3 })
		assert_same({ U.label_max(2, 3, 2, 3) }, { 2, 3 })
		assert_same({ U.label_max(0, 0, 0, 1) }, { 0, 1 })
	end)

	it("deepcopy copies plain data and keeps the one table named in `keep` shared", function()
		local level = { big = { 1, 2, 3 } }
		local src = { a = { b = { 1, 2, { c = true } } }, n = 5, level = level, list = { 3, 2, 1 } }
		local dst = U.deepcopy(src, level)
		assert_same(dst, src)
		assert_true(dst.level == level, "the read-only level is shared")
		assert_true(dst.a ~= src.a and dst.a.b ~= src.a.b and dst.a.b[3] ~= src.a.b[3])
		dst.a.b[3].c = false
		assert_true(src.a.b[3].c, "the copy is independent")
		local flat = U.copy_array(src.list)
		flat[1] = 99
		assert_eq(src.list[1], 3)
	end)
end)

describe("core util: sorted arrays and sorts", function()
	it("keeps a sorted array as a set", function()
		local a = {}
		for _, v in ipairs({ 5, 1, 9, 3, 5, 1, 7 }) do U.sorted_add(a, v) end
		assert_same(a, { 1, 3, 5, 7, 9 })
		assert_false(U.sorted_add(a, 5), "a repeat is refused")
		assert_true(U.sorted_add(a, 4))
		assert_same(a, { 1, 3, 4, 5, 7, 9 })
		local has, pos = U.sorted_has(a, 7)
		assert_true(has)
		assert_eq(pos, 5)
		has, pos = U.sorted_has(a, 6)
		assert_false(has)
		assert_eq(pos, 5, "the insertion point")
		assert_true(U.sorted_remove(a, 1))
		assert_false(U.sorted_remove(a, 1))
		assert_same(a, { 3, 4, 5, 7, 9 })
		assert_false(U.sorted_has({}, 1))
	end)

	it("stable_sort orders by an integer key and keeps the order of equal keys", function()
		local items = {}
		for k = 1, 30 do items[k] = { key = (k * 7) % 4, order = k } end
		U.stable_sort(items, function(e) return e.key end)
		for k = 2, 30 do
			local p, q = items[k - 1], items[k]
			assert_true(p.key < q.key or (p.key == q.key and p.order < q.order), "position " .. k)
		end
	end)

	it("sorted_keys lists the integer keys of a table in ascending order", function()
		assert_same(U.sorted_keys({ [9] = true, [2] = true, [40] = 1, [7] = false }), { 2, 7, 9, 40 })
		assert_same(U.sorted_keys({}), {})
	end)
end)
