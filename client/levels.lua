-- Level files for the meta screens (pure Lua; the file reader and the JSON
-- decoder are looked up lazily, so tests pass their own).
--
--   local levels = require("client.levels")
--   local info = levels.load(12)   --> {id, text, data, difficulty, goals} | nil
--   levels.difficulty(12)          --> "hard" | nil (file missing or broken)
--   levels.tag("super_hard")       --> "town.super_hard" (i18n key) | nil for easy/medium
--   levels.goals(data)             --> {{kind, image, count, label = {key}, color?}, ...}
--
-- The meta never reads files: the town reads the difficulty for the "Level N"
-- tag and the start window reads the goals from content/levels/level_%04d.json.
-- The raw text travels to the level screen with the start result
-- (client/flow.lua), so the level does not read the file again.

local M = {}

M.PATH = "/content/levels/level_%04d.json"
M.CACHE = 4 -- decoded files kept (the button, the start window, the level)

-- test hooks: fn(path) -> text | nil ; fn(text) -> table
M.read = nil
M.decode = nil

local cache, order = {}, {}

function M.path(n)
	return string.format(M.PATH, n)
end

local function read(path)
	if M.read then return M.read(path) end
	if sys and sys.load_resource then
		local ok, data = pcall(sys.load_resource, path)
		if ok then return data end
	end
	return nil
end

local function decode(text)
	local fn = M.decode or (json and json.decode)
	if not fn then return nil end
	local ok, t = pcall(fn, text)
	if ok and type(t) == "table" then return t end
	return nil
end

-- Goal icon by goal type / blocker item (images of the meta atlas; the
-- level GUI has them in the game atlas).
M.ITEM_IMAGE = {
	record_box = "blockers/record_box_1",
	concrete = "blockers/concrete_1",
	noise = "blockers/noise",
	balloon = "blockers/balloon_red",
	column = "blockers/column_1",
}

local function count_floor(data)
	local n = 0
	for _, f in ipairs(type(data.floor) == "table" and data.floor or {}) do
		if type(f) == "table" then n = n + 1 end
	end
	return n
end

-- Goals of a decoded level as things to draw, in file order:
-- {kind = "collect"|"break"|"light"|"deliver", image, count (nil for light
-- without tiles), label = {key = i18n key}, color = piece colour (collect)}.
function M.goals(data)
	local out = {}
	if type(data) ~= "table" or type(data.goals) ~= "table" then return out end
	for _, g in ipairs(data.goals) do
		if type(g) == "table" then
			local t = g.type
			if t == "collect" and type(g.color) == "string" then
				out[#out + 1] = { kind = t, image = "pieces/" .. g.color, count = g.count, color = g.color,
					label = { key = "piece." .. g.color } }
			elseif t == "break" and type(g.item) == "string" then
				out[#out + 1] = { kind = t, image = M.ITEM_IMAGE[g.item] or "blockers/record_box_1", count = g.count,
					item = g.item, label = { key = "blocker." .. g.item } }
			elseif t == "light" then
				local n = count_floor(data)
				out[#out + 1] = { kind = t, image = "blockers/floor_lit", count = n > 0 and n or nil,
					label = { key = "blocker.dancefloor" } }
			elseif t == "deliver" then
				out[#out + 1] = { kind = t, image = "blockers/mic", count = g.count, label = { key = "blocker.mic" } }
			end
		end
	end
	return out
end

local function remember(n, info)
	if cache[n] == nil then
		order[#order + 1] = n
		if #order > M.CACHE then
			cache[table.remove(order, 1)] = nil
		end
	end
	cache[n] = info
end

-- The level file n: {id, text (raw JSON), data (decoded), difficulty, goals},
-- or nil when it is missing or not valid JSON. Cached (a missing file too).
function M.load(n)
	n = tonumber(n)
	if not n then return nil end
	local c = cache[n]
	if c ~= nil then return c or nil end
	local text = read(M.path(n))
	local data = text and decode(text)
	local info = false
	if data then
		info = { id = n, text = text, data = data, difficulty = data.difficulty, goals = M.goals(data),
			moves = data.moves }
	end
	remember(n, info)
	return info or nil
end

function M.difficulty(n)
	local info = M.load(n)
	return info and info.difficulty or nil
end

-- i18n key of the difficulty tag shown on the level button / start window.
function M.tag(difficulty)
	if difficulty == "hard" then return "town.hard" end
	if difficulty == "super_hard" then return "town.super_hard" end
	return nil
end

-- Test hook.
function M._reset()
	cache, order = {}, {}
	M.read, M.decode = nil, nil
end

return M
