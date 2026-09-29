-- Save slots on disk: "current" and "previous" (meta-economy.md, section 12).
--
--   local save_io = require("client.save_io")
--   local store = save_io.new(save_io.defold_backend())   -- in the game
--   local current, previous = store:load()                -- tables or nil
--   local meta, info = Meta.load(districts, current, previous, seed, now)
--   store:adopt(info.source)       -- the slot the meta accepted is the backup
--   store:save_meta(meta)          -- writes only when meta:dirty() (or a retry is due)
--   store:save_meta(meta, true)    -- app goes to the background: always write
--
-- Saving moves the last good "current" to "previous", then writes the new
-- "current". The meta itself validates both slots on load (checksum, version)
-- and falls back from current to previous to a fresh save; adopt() tells the
-- store which slot that was, so a corrupt "current" never becomes the backup.
--
-- A failed write is retried: meta:serialize() marks the meta clean before the
-- write, so after a failure the store treats the next save_meta() as forced
-- (app.tick calls it once a second) until a write succeeds. store.failing
-- counts the failures in a row (0 after a success).
--
-- A backend is {read = fn(slot) -> table|nil, write = fn(slot, table) -> true | nil, err,
-- clear = fn(slot)}.
-- defold_backend() uses sys.get_save_file + sys.save/sys.load (IndexedDB on
-- HTML5); memory_backend() is for tests.

local M = {}

M.APP_ID = "glow"
M.SLOTS = { "current", "previous" }
M.FILES = { current = "save_current.sav", previous = "save_previous.sav" }
M.FORMAT = 1 -- version of the file wrapper, not of the meta save

-- File content: {glow_save = FORMAT, data = <meta save table>}. sys.load
-- returns {} for a missing file; the wrapper tells "missing" from "empty".
local function wrap(tbl)
	return { glow_save = M.FORMAT, data = tbl }
end

local function unwrap(file)
	if type(file) ~= "table" or type(file.data) ~= "table" then return nil end
	return file.data
end

function M.defold_backend(app_id)
	app_id = app_id or M.APP_ID
	local function path(slot)
		return sys.get_save_file(app_id, M.FILES[slot])
	end
	return {
		read = function(slot)
			local ok, res = pcall(function() return sys.load(path(slot)) end)
			if not ok then return nil, tostring(res) end
			return unwrap(res)
		end,
		write = function(slot, tbl)
			local ok, res = pcall(function() return sys.save(path(slot), wrap(tbl)) end)
			if not ok then return nil, tostring(res) end
			if res == false then return nil, "sys.save returned false" end
			return true
		end,
		clear = function(slot)
			pcall(function() return sys.save(path(slot), {}) end)
		end,
	}
end

-- In-memory backend. `files` (optional) pre-fills slots with wrapped content.
function M.memory_backend(files)
	local b = { files = files or {}, writes = 0, fail = false }
	b.read = function(slot)
		return unwrap(b.files[slot])
	end
	b.write = function(slot, tbl)
		if b.fail then return nil, "disk full" end
		b.writes = b.writes + 1
		b.files[slot] = wrap(tbl)
		return true
	end
	b.clear = function(slot)
		b.files[slot] = nil
	end
	return b
end

local Store = {}
Store.__index = Store

function M.new(backend)
	if type(backend) ~= "table" or type(backend.read) ~= "function" or type(backend.write) ~= "function" then
		error("save_io.new needs a backend {read, write}", 2)
	end
	return setmetatable({
		backend = backend,
		last = nil,        -- the last good save: moved to "previous" by the next save
		loaded = {},       -- slot -> table read by load()
		saves = 0,
		errors = 0,
		failing = 0,       -- failed writes in a row
		retry = false,     -- the next save_meta() writes even when the meta is clean
		last_error = nil,
	}, Store)
end

-- Reads both slots. Returns current, previous (tables or nil). Until adopt()
-- is called the current slot counts as the last good save.
function Store:load()
	local cur = self.backend.read("current")
	local prev = self.backend.read("previous")
	self.loaded = { current = cur, previous = prev }
	self.last = cur
	return cur, prev
end

-- Tells the store which slot the meta accepted (Meta.load info.source:
-- "current" | "previous" | "fresh"). That slot becomes the backup the next
-- save moves to "previous"; after "fresh" nothing is moved, so a corrupt
-- slot never overwrites a good backup.
function Store:adopt(source)
	self.last = (self.loaded or {})[source]
end

local function failed(self, err)
	self.errors, self.last_error = self.errors + 1, err
	self.failing = self.failing + 1
	self.retry = true
	return false, err
end

-- Writes tbl as the new "current"; the old current becomes "previous".
-- Returns true, or false and the error (the slots stay as they were).
function Store:save(tbl)
	if type(tbl) ~= "table" then error("save_io: save needs a table", 2) end
	if self.last ~= nil and self.last ~= tbl then
		local ok, err = self.backend.write("previous", self.last)
		if not ok then return failed(self, err) end
	end
	local ok, err = self.backend.write("current", tbl)
	if not ok then return failed(self, err) end
	self.last = tbl
	self.saves = self.saves + 1
	self.failing, self.retry = 0, false
	return true
end

-- Saves the meta when it has unsaved changes, when a previous write failed,
-- or always with force. Returns "saved", "clean" or false, err.
function Store:save_meta(meta, force)
	if not force and not self.retry and not meta:dirty() then return "clean" end
	local ok, err = self:save(meta:serialize())
	if not ok then return false, err end
	return "saved"
end

-- Empties both slots (debug "reset save"): the next load starts fresh.
function Store:wipe()
	for _, slot in ipairs(M.SLOTS) do self.backend.clear(slot) end
	self.last, self.loaded = nil, {}
end

-- Wraps a backend with a switch that makes writes fail (debug / QA: "disk
-- full" without filling a disk). wrapped.fail = true | false.
function M.faulty(backend)
	local w = { fail = false, inner = backend }
	w.read = function(slot) return backend.read(slot) end
	w.write = function(slot, tbl)
		if w.fail then return nil, "simulated write failure" end
		return backend.write(slot, tbl)
	end
	w.clear = function(slot) return backend.clear(slot) end
	return w
end

return M
