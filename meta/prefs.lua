-- Player settings and the set of tutorials already shown.
--
-- State: {settings = {music, sfx, haptics, reduced_motion, input_mode, language},
--         tutorial = sorted array of seen tutorial ids}

local C = require("meta.config")
local util = require("meta.util")

local M = {}

local function volume(v)
	if type(v) ~= "number" or v ~= v then return nil end
	return math.max(0, math.min(1, v))
end

local function flag(v)
	if type(v) == "boolean" then return v end
	return nil
end

local function one_of(list)
	return function(v)
		if util.index_of(list, v) then return v end
		return nil
	end
end

-- Each checker returns the value to store, or nil if the value is invalid.
local CHECK = {
	music = volume,
	sfx = volume,
	haptics = flag,
	reduced_motion = flag,
	input_mode = one_of(C.input_modes),
	language = one_of(C.languages),
}
local KEYS = { "music", "sfx", "haptics", "reduced_motion", "input_mode", "language" }

function M.restore(t)
	t = type(t) == "table" and t or {}
	local saved = type(t.settings) == "table" and t.settings or {}
	local settings = {}
	for _, k in ipairs(KEYS) do
		local v = CHECK[k](saved[k])
		if v == nil then v = C.settings[k] end
		settings[k] = v
	end
	local tutorial = {}
	if type(t.tutorial) == "table" then
		for _, id in ipairs(t.tutorial) do
			if type(id) == "string" and id ~= "" then tutorial[#tutorial + 1] = id end
		end
	end
	table.sort(tutorial, util.str_less)
	local unique = {}
	for _, id in ipairs(tutorial) do
		if unique[#unique] ~= id then unique[#unique + 1] = id end
	end
	return { settings = settings, tutorial = unique }
end

-- Changes one setting. Volumes are clamped to 0..1. Returns true, or false,
-- "invalid_value". An unknown key is a programming error.
function M.set(prefs, key, value)
	local check = CHECK[key]
	if not check then error("meta: unknown setting '" .. tostring(key) .. "'", 3) end
	local v = check(value)
	if v == nil then return false, "invalid_value" end
	prefs.settings[key] = v
	return true
end

local function check_id(id)
	if type(id) ~= "string" or id == "" then error("meta: tutorial id must be a non-empty string", 4) end
end

function M.seen(prefs, id)
	check_id(id)
	return util.index_of(prefs.tutorial, id) ~= nil
end

-- Marks a tutorial as seen. Returns true if it was not seen before.
function M.mark(prefs, id)
	check_id(id)
	local list = prefs.tutorial
	local pos = #list + 1
	for i, x in ipairs(list) do
		if x == id then return false end
		if util.str_less(id, x) then
			pos = i
			break
		end
	end
	table.insert(list, pos, id)
	return true
end

return M
