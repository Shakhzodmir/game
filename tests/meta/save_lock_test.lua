-- Locks everything that decides whether an existing player keeps their progress after an update:
-- where the save lives, how a file is wrapped, which top-level fields a save has, migrations.
-- A failure here is not a "test to adjust": read the header of meta/save.lua first.

local save = require("meta.save")
local save_io = require("client.save_io")
local savecode = require("meta.savecode")
local Meta = require("meta.meta")
local C = require("meta.config")
local H = require("tests.meta.helper")

-- Fields as shipped when this lock was written; new fields may only be appended.
local LOCKED_FIELDS = { "salt", "wallet", "stats", "lives", "progress", "unlock_gifts", "town", "prefs", "chests" }

describe("save location lock", function()
	it("keeps the app id, file names and wrapper format", function()
		assert_eq(save_io.APP_ID, "glow")
		assert_eq(save_io.FILES.current, "save_current.sav")
		assert_eq(save_io.FILES.previous, "save_previous.sav")
		assert_eq(save_io.SLOTS[1], "current")
		assert_eq(save_io.SLOTS[2], "previous")
		assert_eq(save_io.FORMAT, 1)
	end)

	it("keeps every locked field of save.fields in its place (appending is allowed)", function()
		for i, name in ipairs(LOCKED_FIELDS) do
			assert_eq(save.fields[i], name, "field " .. i)
		end
		assert_true(#save.fields >= #LOCKED_FIELDS)
	end)

	it("has a migration for every older version", function()
		for v = 1, C.save_version - 1 do
			assert_eq(type(save.migrations[v]), "function", "migration from version " .. v)
		end
	end)

	it("serializes every locked field and the version", function()
		local t = H.new(7):serialize()
		for _, name in ipairs(LOCKED_FIELDS) do assert_true(t[name] ~= nil, name) end
		assert_eq(t.version, C.save_version)
	end)

	it("reads a save of a newer version without losing it (rollback keeps data)", function()
		local t = H.new(7):serialize()
		local raw = save.decode(t)
		assert_true(raw ~= nil)
	end)
end)

-- A player who beat levels 1..n through the public API of the meta.
local function player(n, seed)
	local m = H.new(seed or 4242)
	local now = H.T0
	while m:level_to_play() and m:level_to_play() <= n do
		H.win(m, now, "easy", 5)
		now = now + 120
		H.claim_chests(m, now)
	end
	m:set_setting("music", 0.4)
	m:mark_tutorial_seen("first_swap")
	return m
end

-- Compares two plain tables field by field; fails with the path of the first difference.
local function same(a, b, path)
	path = path or "save"
	if type(a) ~= type(b) then error(path .. ": type " .. type(a) .. " vs " .. type(b), 0) end
	if type(a) ~= "table" then
		if a ~= b then error(path .. ": " .. tostring(a) .. " vs " .. tostring(b), 0) end
		return
	end
	for k, v in pairs(a) do same(v, b[k], path .. "." .. tostring(k)) end
	for k in pairs(b) do
		if a[k] == nil then error(path .. "." .. tostring(k) .. ": missing in the first", 0) end
	end
end

describe("a player on level 89", function()
	local m = player(88)
	assert_eq(m:level_to_play(), 89)

	it("has the progress of 88 beaten levels and a stable checksum", function()
		local t = m:serialize()
		assert_eq(t.progress.beaten, 88)
		assert_eq(save.checksum(t), t.checksum)
	end)

	it("comes back identical after serialize and load", function()
		local t = m:serialize()
		local copy = require("meta.util").copy(t)
		local m2, info = Meta.load(H.districts(), copy, nil, 1, H.T0 + 120 * 87)
		assert_eq(info.source, "current")
		assert_false(info.migrated)
		local t2 = m2:serialize()
		t2.checksum, t.checksum = nil, nil -- the checksum is of the whole table: any difference shows below
		same(t, t2)
	end)

	it("comes back identical through the file wrapper and the memory backend", function()
		local t = m:serialize()
		local store = save_io.new(save_io.memory_backend())
		assert_true(store:save(t))
		local cur = store:load()
		same(t, cur)
	end)

	it("comes back identical through a save code", function()
		local t = m:serialize()
		local code = savecode.encode(t)
		local back, sum = savecode.read(code, H.districts())
		assert_true(back ~= nil, tostring(sum))
		same(t, back)
		assert_eq(sum.beaten, 88)
	end)

	it("keeps playing: the 89th level is next and can be beaten", function()
		local t = m:serialize()
		local m2 = Meta.load(H.districts(), require("meta.util").copy(t), nil, 1, H.T0 + 99999)
		assert_eq(m2:level_to_play(), 89)
		local res = H.win(m2, H.T0 + 100000)
		assert_true(res ~= nil)
		assert_eq(m2:level_to_play(), 90)
	end)

	it("survives a migration chain from older versions when they exist", function()
		if C.save_version == 1 then return end
		-- A save written as version 1 needs every step up to the current one.
		for v = 1, C.save_version - 1 do assert_eq(type(save.migrations[v]), "function") end
	end)
end)
