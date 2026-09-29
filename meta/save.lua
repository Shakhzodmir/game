-- Save format: the whole meta state as a plain table, with a format version
-- and a checksum.
--
-- A save holds only numbers, strings, booleans, arrays and string-keyed
-- tables, so it survives sys.save and JSON alike. The checksum is computed
-- over a canonical serialization (map keys in byte order, numbers as %.14g),
-- which gives the same string on every VM and after a JSON round trip.
--
-- The caller keeps two slots: the current save and the previous one. On
-- load the current slot is tried first, then the previous one; if both are
-- missing or invalid the facade starts a fresh save.
--
-- Versions: C.save_version is the format written now. When the format
-- changes, bump it and add migrations[n] that turns a version-n table into a
-- version n+1 table; older saves are upgraded step by step. The checksum is
-- always verified before migrating, so the checksum algorithm must not change.
--
-- Rollbacks: a save from a newer version (the web build was rolled back) is
-- read as far as this version understands it. Top-level fields it does not
-- know are kept as they are (state.extra) and written back, so updating the
-- app again finds them. Two rules follow for format changes:
--   * add new data as new top-level fields; do not rename or reshape old
--     ones (unknown fields inside known ones are dropped);
--   * a migration must keep a field that already exists: a save that went
--     through a rollback carries the newer version's fields already.

local C = require("meta.config")
local util = require("meta.util")
local economy = require("meta.economy")
local inventory = require("meta.inventory")
local lives = require("meta.lives")
local progress = require("meta.progress")
local town = require("meta.town")
local prefs = require("meta.prefs")

local M = {}

-- [n] = function(t) -> t : upgrades a version-n save table to version n + 1.
M.migrations = {}

local function canon(v, out)
	local tv = type(v)
	if tv == "number" then
		if v ~= v or v == math.huge or v == -math.huge then error("save: non-finite number") end
		if v == 0 then v = 0 end -- no "-0"
		out[#out + 1] = "n" .. string.format("%.14g", v) .. ";"
	elseif tv == "string" then
		out[#out + 1] = "s" .. #v .. ":" .. v
	elseif tv == "boolean" then
		out[#out + 1] = v and "T" or "F"
	elseif tv == "table" then
		local n, count, keys = #v, 0, {}
		for k in pairs(v) do -- order-free: keys are sorted below
			count = count + 1
			if type(k) == "string" then
				keys[#keys + 1] = k
			elseif not (util.is_int(k) and k >= 1 and k <= n) then
				error("save: unsupported key " .. tostring(k))
			end
		end
		if #keys == 0 and count == n then
			out[#out + 1] = "["
			for i = 1, n do canon(v[i], out) end
			out[#out + 1] = "]"
		elseif #keys == count then
			table.sort(keys, util.str_less)
			out[#out + 1] = "{"
			for _, k in ipairs(keys) do
				out[#out + 1] = "s" .. #k .. ":" .. k
				canon(v[k], out)
			end
			out[#out + 1] = "}"
		else
			error("save: a table mixes array and map keys")
		end
	else
		error("save: unsupported value of type " .. tv)
	end
end

-- Canonical string of a save table, without its checksum field.
function M.canonical(t)
	local body = {}
	for k, v in pairs(t) do -- order-free: copies a map
		if k ~= "checksum" then body[k] = v end
	end
	local out = {}
	canon(body, out)
	return table.concat(out)
end

-- Two polynomial hashes modulo primes near 2^31. Every product stays below
-- 2^53, so doubles compute them exactly on Lua 5.1 and LuaJIT.
local function hash(s)
	local a, b = 5381, 52711
	for i = 1, #s do
		local c = s:byte(i)
		a = (a * 33 + c) % 2147483647
		b = (b * 131 + c + 7) % 2147483629
	end
	return string.format("%08x%08x", a, b)
end

function M.checksum(t)
	return hash("GLOW-save|" .. M.canonical(t))
end

-- Top-level fields of the state, i.e. of a save of this version.
M.fields = { "salt", "wallet", "stats", "lives", "progress", "unlock_gifts", "town", "prefs" }

local function is_known(k)
	return k == "version" or k == "checksum" or util.index_of(M.fields, k) ~= nil
end

-- State -> save table. The result shares nothing with the state.
function M.serialize(state)
	local t = {}
	for k, v in pairs(state.extra) do t[k] = util.copy(v) end -- order-free: fills a map
	for _, k in ipairs(M.fields) do t[k] = util.copy(state[k]) end
	t.version = C.save_version
	t.checksum = M.checksum(t)
	return t
end

-- Checks and upgrades one save table. Returns the raw state (no version, no
-- checksum) and the version it was written with, or nil and a reason.
-- opts.version / opts.migrations override the module values (for tests).
function M.decode(t, opts)
	opts = opts or {}
	local target = opts.version or C.save_version
	local migrations = opts.migrations or M.migrations
	if type(t) ~= "table" then return nil, "missing" end
	local v = t.version
	if not util.is_int(v) or v < 1 then return nil, "bad_version" end
	local ok, sum = pcall(M.checksum, t)
	if not ok then return nil, "bad_data" end
	if t.checksum ~= sum then return nil, "bad_checksum" end
	local data = util.copy(t)
	data.checksum = nil
	for from = v, target - 1 do
		local step = migrations[from]
		if not step then return nil, "no_migration_from_" .. from end
		local fine, upgraded = pcall(step, data)
		if not fine or type(upgraded) ~= "table" then return nil, "migration_failed_from_" .. from end
		data = upgraded
		data.version = from + 1
	end
	data.version = nil
	return data, v
end

-- Raw state -> state with every field checked and missing fields filled with
-- defaults. Only a bad salt makes a save unusable.
function M.restore(raw, districts)
	if type(raw) ~= "table" then return nil, "missing" end
	local salt = raw.salt
	if not util.is_int(salt) or salt < C.salt.min or salt > C.salt.max then return nil, "bad_salt" end
	local extra = {}
	for k, v in pairs(raw) do -- order-free: fills a map
		if not is_known(k) then extra[k] = util.copy(v) end
	end
	local p = progress.restore(raw.progress)
	return {
		salt = salt,
		wallet = economy.restore_wallet(raw.wallet),
		stats = economy.restore_stats(raw.stats),
		lives = lives.restore(raw.lives),
		progress = p,
		unlock_gifts = inventory.restore_gifts(raw.unlock_gifts, progress.reached(p)),
		town = town.restore(raw.town, districts),
		prefs = prefs.restore(raw.prefs),
		extra = extra,
	}
end

-- A new state with every field at its default. The facade adds the starting
-- coins and the gifts of boosters open from the start through the ledger.
function M.fresh(salt, districts)
	return (M.restore({ salt = salt, unlock_gifts = {} }, districts))
end

-- Tries the current slot, then the previous one. Returns state, info or
-- nil, info when both are unusable. info = {source = "current"|"previous"|
-- "fresh", version = written version, migrated = bool, newer = bool (written
-- by a newer app version), errors = {slot = reason}}.
function M.load(current, previous, districts, opts)
	local target = (opts and opts.version) or C.save_version
	local errors = {}
	local slots = { { "current", current }, { "previous", previous } }
	for _, slot in ipairs(slots) do
		local raw, version = M.decode(slot[2], opts)
		local state, err = nil, version
		if raw then state, err = M.restore(raw, districts) end
		if state then
			return state, {
				source = slot[1],
				version = version,
				migrated = version < target,
				newer = version > target,
				errors = errors,
			}
		end
		errors[slot[1]] = err
	end
	return nil, { source = "fresh", errors = errors }
end

return M
