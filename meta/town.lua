-- Districts of the town (content/districts.json) and the player's progress in them.
--
-- Districts open in file order. Tasks of a district are done in listed order;
-- each costs stars and unmutes one stem of the district track. When every
-- task is done the district is complete and its chest is paid, once.
--
-- The state records what the player did, not counts, so a content update
-- cannot pay a reward twice or take progress away:
--   [district_id] = {done = {task ids, in task order}, chest_claimed = bool,
--                    view = "day"|"concert"}
--   * done holds task ids, so reordering tasks keeps the right ones done.
--   * A task added to a complete district reopens it, but its chest stays
--     claimed and the next district stays open.
--   * A district is available when it is the first one, when the chest of the
--     previous one is claimed, or when the player already has progress in it.

local C = require("meta.config")
local inventory = require("meta.inventory")
local util = require("meta.util")

local M = {}

local function fail(msg)
	error("meta: districts: " .. msg, 3)
end

local CHEST_KEYS = { boosters = true, coins = true }

local function validate_chest(id, chest)
	if chest == nil then return { coins = 0, boosters = {} } end
	if type(chest) ~= "table" then fail(id .. " chest must be a table") end
	local unknown = {}
	for k in pairs(chest) do -- order-free: collected, then sorted
		if not CHEST_KEYS[k] then unknown[#unknown + 1] = tostring(k) end
	end
	if #unknown > 0 then
		table.sort(unknown, util.str_less)
		fail(id .. " chest has unknown field '" .. unknown[1] .. "' (a district chest holds coins and boosters)")
	end
	local coins = chest.coins or 0
	if not util.is_int(coins) or coins < 0 then fail(id .. " chest coins must be a non-negative integer") end
	if chest.boosters ~= nil and type(chest.boosters) ~= "table" then fail(id .. " chest boosters must be a list") end
	local boosters = {}
	for _, b in ipairs(chest.boosters or {}) do
		if not inventory.def(b) then fail(id .. " chest has unknown booster '" .. tostring(b) .. "'") end
		boosters[#boosters + 1] = b
	end
	return { coins = coins, boosters = boosters }
end

-- Checks the decoded districts.json and returns the data the meta works with:
-- {list = {district...}, by_id = {[id] = district}}; district.index is its position.
function M.validate(src)
	if type(src) ~= "table" or type(src.districts) ~= "table" or #src.districts == 0 then
		fail("expected a table with a non-empty 'districts' array")
	end
	local data = { list = {}, by_id = {} }
	for i, d in ipairs(src.districts) do
		if type(d) ~= "table" or type(d.id) ~= "string" or d.id == "" then fail("district " .. i .. " has no id") end
		if data.by_id[d.id] then fail("duplicate district id '" .. d.id .. "'") end
		if type(d.tasks) ~= "table" or #d.tasks == 0 then fail(d.id .. " has no tasks") end
		local tasks, seen = {}, {}
		for j, t in ipairs(d.tasks) do
			local where = d.id .. " task " .. j
			if type(t) ~= "table" or type(t.id) ~= "string" or t.id == "" then fail(where .. " has no id") end
			if seen[t.id] then fail(where .. " repeats id '" .. t.id .. "'") end
			seen[t.id] = true
			if not util.is_int(t.cost) or t.cost < 1 then fail(where .. " cost must be a positive integer") end
			if j == 1 and t.cost ~= 1 then fail(d.id .. ": the first task must cost 1 star") end
			if type(t.stem) ~= "string" or t.stem == "" then fail(where .. " has no stem") end
			tasks[j] = { id = t.id, name = util.copy(t.name), cost = t.cost, stem = t.stem }
		end
		local district = {
			id = d.id,
			index = i,
			name = util.copy(d.name),
			tasks = tasks,
			chest = validate_chest(d.id, d.chest),
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
		local list = type(saved.done) == "table" and saved.done or {}
		local done = {}
		for _, task in ipairs(d.tasks) do
			if util.index_of(list, task.id) then done[#done + 1] = task.id end
		end
		local claimed = saved.chest_claimed
		if type(claimed) ~= "boolean" then claimed = #done == #d.tasks end
		town[d.id] = {
			done = done,
			chest_claimed = claimed,
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

function M.is_done(town, d, task)
	return util.index_of(town[d.id].done, task.id) ~= nil
end

function M.is_complete(town, d)
	return #town[d.id].done == #d.tasks
end

function M.is_available(town, data, d)
	local prev = data.list[d.index - 1]
	local own = town[d.id]
	return prev == nil or town[prev.id].chest_claimed or #own.done > 0 or own.chest_claimed
end

-- The first district that is not complete, or nil when the town is complete.
-- It is always available: every complete district has its chest claimed.
function M.current(town, data)
	for _, d in ipairs(data.list) do
		if not M.is_complete(town, d) then return d end
	end
	return nil
end

-- The next task of district d in listed order, or nil if it is complete.
function M.next_task(town, d)
	for _, task in ipairs(d.tasks) do
		if not M.is_done(town, d, task) then return task end
	end
	return nil
end

-- Stems of the done tasks, in task order.
function M.unmuted(town, d)
	local out = {}
	for _, task in ipairs(d.tasks) do
		if M.is_done(town, d, task) then out[#out + 1] = task.stem end
	end
	return out
end

-- Checks that task_id can be done now. Returns the task or false, reason.
function M.check_task(town, data, d, task_id)
	local task
	for _, t in ipairs(d.tasks) do
		if t.id == task_id then task = t end
	end
	if not task then error("meta: district '" .. d.id .. "' has no task '" .. tostring(task_id) .. "'", 3) end
	if not M.is_available(town, data, d) then return false, "district_locked" end
	if M.is_done(town, d, task) then return false, "already_done" end
	if M.next_task(town, d) ~= task then return false, "wrong_order" end
	return task
end

-- Marks a task done. Returns true if the district is now complete.
function M.mark_done(town, d, task)
	local done = town[d.id].done
	local list = {}
	for _, t in ipairs(d.tasks) do
		if t == task or util.index_of(done, t.id) then list[#list + 1] = t.id end
	end
	town[d.id].done = list
	return M.is_complete(town, d)
end

-- Claims the chest of a complete district. Returns the chest (a copy) the
-- first time, nil if it was claimed before or the district is not complete.
function M.claim_chest(town, d)
	local t = town[d.id]
	if t.chest_claimed or not M.is_complete(town, d) then return nil end
	t.chest_claimed = true
	return util.copy(d.chest)
end

-- views ---------------------------------------------------------------------

-- {district, id, name, cost, stem, affordable}
function M.task_view(d, task, stars)
	return {
		district = d.id,
		id = task.id,
		name = util.copy(task.name),
		cost = task.cost,
		stem = task.stem,
		affordable = stars >= task.cost,
	}
end

-- {id, index, name, available, complete, done, total, chest_claimed, view,
--  unmuted = {stems}, tasks = [{id, name, cost, stem, done}], chest,
--  next_task = task_view|nil (nil while locked or complete)}
function M.district_view(town, data, d, stars)
	local available = M.is_available(town, data, d)
	local tasks = {}
	for j, task in ipairs(d.tasks) do
		tasks[j] = { id = task.id, name = util.copy(task.name), cost = task.cost, stem = task.stem,
			done = M.is_done(town, d, task) }
	end
	local next_task = available and M.next_task(town, d)
	return {
		id = d.id,
		index = d.index,
		name = util.copy(d.name),
		available = available,
		complete = M.is_complete(town, d),
		done = #town[d.id].done,
		total = #d.tasks,
		chest_claimed = town[d.id].chest_claimed,
		view = town[d.id].view,
		unmuted = M.unmuted(town, d),
		tasks = tasks,
		chest = util.copy(d.chest),
		next_task = next_task and M.task_view(d, next_task, stars) or nil,
	}
end

return M
