-- The songbook: a song of each district, written one line per beaten level (pure Lua, deterministic).
--
-- The player "writes a song while playing": every level of a stretch (C.songbook.districts: levels 1-20, 21-40 ...)
-- adds one line to the song of its district; when all levels of the stretch are beaten the song is ready.
-- Nothing here is paid: the songbook is decoration, never coins, stars or boosters.
--
-- State (ONE new top-level field of the save, `songbook`, see the header of meta/save.lua):
--   songbook = {
--     lines = { ["cafe"] = {7, 21, 3, ...} },  -- the i-th number is the pool number (1..C.songbook.pool) of the
--                                              -- line the i-th level of the stretch wrote; numbers, not texts
--     seen  = { "cafe", ... },                 -- ready songs the player was already offered (or that were ready
--                                              -- before the songbook existed): no second offer
--   }
-- The texts are client/i18n_songbook.lua (`sb.<district>.<number>`), the same number in every language, so a
-- language change rewrites the song and a save needs no text.
--
-- Choosing a line: for level n of a district the free pool numbers (not in the song yet) are listed in ascending
-- order and one is taken by a hash of (salt, district, level). The same player and level always get the same
-- line, and a song never repeats a line. A chosen line is kept in the save, so adding lines to the pool later
-- never rewrites a song.
--
-- `sync` fills the lines of every beaten level that has none (a save from before the songbook, or progress that
-- arrived with a cloud save), silently: no result, no reward. It only appends, so progress never shrinks the book.

local C = require("meta.config")
local util = require("meta.util")

local M = {}

local MOD = 2147483647

-- A district entry of the config by id, and its position.
function M.district(id)
	for i, d in ipairs(C.songbook.districts) do
		if d.id == id then return d, i end
	end
	return nil
end

-- Number of levels (lines) of a district's song.
function M.total(id)
	local d = M.district(id)
	return d and (d.last - d.first + 1) or 0
end

-- The district a level belongs to: id, position of its line (1-based), or nil.
function M.of_level(level)
	for _, d in ipairs(C.songbook.districts) do
		if level >= d.first and level <= d.last then return d.id, level - d.first + 1 end
	end
	return nil
end

function M.fresh()
	return { lines = {}, seen = {} }
end

-- A state read from a save: every field checked, nothing invented. beaten = highest beaten level.
-- Lines are kept only as a prefix of valid, distinct pool numbers within the stretch.
function M.restore(raw)
	local out = M.fresh()
	if type(raw) ~= "table" then return out end
	if type(raw.lines) == "table" then
		for _, d in ipairs(C.songbook.districts) do
			local src, list, used = raw.lines[d.id], {}, {}
			if type(src) == "table" then
				for i = 1, math.min(#src, d.last - d.first + 1) do
					local v = src[i]
					if not util.is_int(v) or v < 1 or v > C.songbook.pool or used[v] then break end
					used[v] = true
					list[i] = v
				end
			end
			if #list > 0 then out.lines[d.id] = list end
		end
	end
	if type(raw.seen) == "table" then
		for _, d in ipairs(C.songbook.districts) do
			if util.index_of(raw.seen, d.id) then out.seen[#out.seen + 1] = d.id end
		end
	end
	return out
end

-- Two rounds of a multiplicative hash, every product below 2^53: the same number on Lua 5.1 and LuaJIT.
local function mix(salt, di, level)
	local x = (salt % MOD) + 1
	x = (x * 48271 + level * 1013 + di * 7919) % MOD
	x = (x * 16807 + 12345) % MOD
	x = (x * 48271 + di * 31 + level) % MOD
	return x
end

-- The pool number written by `level` of the district number `di`, given the numbers already used.
local function choose(salt, di, level, used)
	local free = {}
	for n = 1, C.songbook.pool do
		if not used[n] then free[#free + 1] = n end
	end
	if #free == 0 then return nil end
	return free[mix(salt, di, level) % #free + 1]
end

-- Writes the missing lines of every level up to `beaten`. Returns the list of what was added:
-- {{district, pos, line}} in level order (empty when nothing was missing).
function M.sync(state, salt, beaten)
	local added = {}
	for di, d in ipairs(C.songbook.districts) do
		local list = state.lines[d.id] or {}
		local upto = math.min(beaten, d.last)
		local used = {}
		for _, v in ipairs(list) do used[v] = true end
		for level = d.first + #list, upto do
			local n = choose(salt, di, level, used)
			if not n then break end
			used[n] = true
			list[#list + 1] = n
			added[#added + 1] = { district = d.id, pos = #list, line = n, level = level }
		end
		if #list > 0 then state.lines[d.id] = list end
	end
	return added
end

-- A state from a save, with the lines of the levels already beaten filled in (a save from before the songbook,
-- or progress that came with a cloud save). The songs this fill finished are marked seen: the player gets no
-- offer and no window for them, the notebook just has them.
function M.load(raw, salt, beaten)
	local state = M.restore(raw)
	for _, a in ipairs(M.sync(state, salt, beaten)) do
		M.mark_seen(state, a.district)
	end
	return state
end

function M.is_ready(state, id)
	local d = M.district(id)
	local list = state.lines[id]
	return d ~= nil and list ~= nil and #list >= d.last - d.first + 1
end

-- Groups of lines: verses of C.songbook.group lines, every third group a chorus: {{kind, from, to}}.
-- kind = "verse" | "chorus". `count` = lines to group (all of the song when ready).
function M.groups(count)
	local out, g = {}, C.songbook.group
	local i = 1
	while (i - 1) * g < count do
		local from, to = (i - 1) * g + 1, math.min(count, i * g)
		out[#out + 1] = { kind = (i % 3 == 0) and "chorus" or "verse", from = from, to = to }
		i = i + 1
	end
	return out
end

-- Title number of a ready song (1..C.songbook.titles), made from its lines.
function M.title_number(state, id)
	local list = state.lines[id] or {}
	local h = 17
	for i, v in ipairs(list) do h = (h * 31 + v * (i + 3)) % MOD end
	return h % C.songbook.titles + 1
end

-- What a district's song is now: {id, total, count, ready, seen, lines = {numbers}, groups, title = number | nil}.
function M.song(state, id)
	local d = M.district(id)
	if not d then return nil end
	local list = state.lines[id] or {}
	local total = d.last - d.first + 1
	local ready = #list >= total
	return {
		id = id, first = d.first, last = d.last, total = total, count = #list, ready = ready,
		seen = util.index_of(state.seen, id) ~= nil,
		lines = util.copy(list), groups = M.groups(#list),
		title = ready and M.title_number(state, id) or nil,
	}
end

-- Marks a ready song as offered. true when it changed.
function M.mark_seen(state, id)
	if not M.is_ready(state, id) or util.index_of(state.seen, id) then return false end
	state.seen[#state.seen + 1] = id
	return true
end

return M
