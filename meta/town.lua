-- Districts of the town (content/districts.json) and the player's progress in them.
--
-- Districts open in file order: a district is available when the previous
-- one is complete. Its tasks are done in listed order; each costs stars and
-- unmutes one stem of the district track. The last task completes the
-- district and opens its chest.
--
-- State: [district_id] = {done = number of tasks done, view = "day"|"concert"}

local C = require("meta.config")
local inventory = require("meta.inventory")
local util = require("meta.util")

local M = {}

local function fail(msg)
	error("meta: districts: " .. msg, 3)
end

-- Checks the decoded districts.json and returns the data the meta works with:
-- {list = {district...}, by_id = {[id] = district}}; district.index is its position.
function M.validate(src)
	if type(src) ~= "table" or type(src.districts) ~= "table" or #src.districts == 0 then
		fail("expected a table with a non-empty 'districts' array")
	end
	local data = { list = {}, by_id = {} }
	for i, d in ipairs(src.districts) do
		if type(d.id) ~= "string" or d.id == "" then fail("district " .. i .. " has no id") end
		if data.by_id[d.id] then fail("duplicate district id '" .. d.id .. "'") end
		if type(d.tasks) ~= "table" or #d.tasks == 0 then fail(d.id .. " has no tasks") end
		local tasks, seen = {}, {}
		for j, t in ipairs(d.tasks) do
			local where = d.id .. " task " .. j
			if type(t.id) ~= "string" or t.id == "" then fail(where .. " has no id") end
			if seen[t.id] then fail(where .. " repeats id '" .. t.id .. "'") end
			seen[t.id] = true
			if not util.is_int(t.cost) or t.cost < 1 then fail(where .. " cost must be a positive integer") end
			if j == 1 and t.cost ~= 1 then fail(d.id .. ": the first task must cost 1 star") end
			if type(t.stem) ~= "string" or t.stem == "" then fail(where .. " has no stem") end
			tasks[j] = { id = t.id, name = util.copy(t.name), cost = t.cost, stem = t.stem }
		end
		local chest = d.chest or {}
		if not util.is_int(chest.coins or 0) or (chest.coins or 0) < 0 then fail(d.id .. " chest coins") end
		local boosters = {}
		for _, b in ipairs(chest.boosters or {}) do
			if not inventory.def(b) then fail(d.id .. " chest has unknown booster '" .. tostring(b) .. "'") end
			boosters[#boosters + 1] = b
		end
		local district = {
			id = d.id,
			index = i,
			name = util.copy(d.name),
			tasks = tasks,
			chest = { coins = chest.coins or 0, boosters = boosters },
		}
		data.list[i] = district
		data.by_id[d.id] = district
	end
	return data
end

function M.restore(t, data)
	t = type(t) == "table" and t or {}
	local town = {}
	for _, d in ipairs(data.list) do
		local saved = type(t[d.id]) == "table" and t[d.id] or {}
		town[d.id] = {
			done = util.int(saved.done, 0, 0, #d.tasks),
			view = util.index_of(C.views, saved.view) and saved.view or C.views[1],
		}
	end
	return town
end

function M.need(data, id)
	local d = data.by_id[id]
	if not d then error("meta: unknown district '" .. tostring(id) .. "'", 3) end
	return d
end

function M.is_complete(town, d)
	return town[d.id].done >= #d.tasks
end

function M.is_available(town, data, d)
	local prev = data.list[d.index - 1]
	return prev == nil or M.is_complete(town, prev)
end

-- The first district that is not complete (always available), or nil.
function M.current(town, data)
	for _, d in ipairs(data.list) do
		if not M.is_complete(town, d) then return d end
	end
	return nil
end

-- Stems of the done tasks, in task order.
function M.unmuted(town, d)
	local out = {}
	for j = 1, town[d.id].done do out[j] = d.tasks[j].stem end
	return out
end

-- The next task of district d, or nil if it is complete.
function M.next_task(town, d)
	return d.tasks[town[d.id].done + 1]
end

-- Checks that task_id can be done now. Returns the task or false, reason.
function M.check_task(town, data, d, task_id)
	if not M.is_available(town, data, d) then return false, "district_locked" end
	local done = town[d.id].done
	for j, t in ipairs(d.tasks) do
		if t.id == task_id then
			if j <= done then return false, "already_done" end
			if j > done + 1 then return false, "wrong_order" end
			return t
		end
	end
	error("meta: district '" .. d.id .. "' has no task '" .. tostring(task_id) .. "'", 3)
end

function M.mark_done(town, d)
	town[d.id].done = town[d.id].done + 1
	return M.is_complete(town, d)
end

return M
