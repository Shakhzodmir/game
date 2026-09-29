-- Booster catalogue rules: which boosters exist, when they unlock, their
-- unlock gifts and the free boosters of the win streak. Counts live in the
-- wallet (economy.lua).
--
-- "reached" is the level the player is about to play: beaten + 1 (it stays
-- above the last level once everything is beaten). A booster is unlocked when
-- its unlock level <= reached.
--
-- State `unlock_gifts`: ids of the boosters whose unlock gift was given, in
-- catalogue order. The gift is due for every unlocked booster missing from
-- this list, so it is paid exactly once even if an update moves an unlock
-- level: lowered, the gift comes at once; raised, it is not paid again.

local C = require("meta.config")
local util = require("meta.util")

local M = {}

M.ids = {}
local by_id = {}
for i, def in ipairs(C.boosters) do
	M.ids[i] = def.id
	by_id[def.id] = def
end

function M.def(id)
	return by_id[id]
end

-- The definition, or an error for an unknown id (a programming mistake).
function M.need(id, kind)
	local def = by_id[id]
	if not def then error("meta: unknown booster '" .. tostring(id) .. "'", 3) end
	if kind and def.kind ~= kind then
		error("meta: '" .. id .. "' is not " .. (kind == "in" and "an in-level" or "a pre-level") .. " booster", 3)
	end
	return def
end

function M.is_unlocked(id, reached)
	return M.need(id).unlock <= reached
end

-- Sorts a list of booster ids into catalogue order (duplicates are kept).
function M.sort(list)
	local out = {}
	for _, id in ipairs(M.ids) do
		for _, x in ipairs(list) do
			if x == id then out[#out + 1] = x end
		end
	end
	return out
end

-- Boosters unlocked at `reached`, in catalogue order.
function M.unlocked(reached)
	local out = {}
	for _, def in ipairs(C.boosters) do
		if def.unlock <= reached then out[#out + 1] = def.id end
	end
	return out
end

-- The stored gift list: known ids once each, in catalogue order. A save
-- without the list counts every booster unlocked so far as gifted.
function M.restore_gifts(t, reached)
	if type(t) ~= "table" then return M.unlocked(reached) end
	local out = {}
	for _, id in ipairs(M.ids) do
		if util.index_of(t, id) then out[#out + 1] = id end
	end
	return out
end

-- Unlocked boosters whose gift is still due, in catalogue order.
function M.due_gifts(gifted, reached)
	local out = {}
	for _, id in ipairs(M.unlocked(reached)) do
		if not util.index_of(gifted, id) then out[#out + 1] = id end
	end
	return out
end

-- Free pre-level boosters of the win streak for a start of level `level`.
function M.streak_boosters(streak, level)
	local out = {}
	if level < C.streak.from_level then return out end
	for _, r in ipairs(C.streak.rewards) do
		if streak >= r.wins and M.is_unlocked(r.booster, level) then out[#out + 1] = r.booster end
	end
	return out
end

-- Inventory screen: [{id, kind, count, unlocked, unlock_level, pack_price,
-- pack_size}] in catalogue order.
function M.view(wallet, reached)
	local out = {}
	for i, def in ipairs(C.boosters) do
		out[i] = {
			id = def.id,
			kind = def.kind,
			count = wallet[def.id],
			unlocked = def.unlock <= reached,
			unlock_level = def.unlock,
			pack_price = def.pack_price,
			pack_size = C.pack_size,
		}
	end
	return out
end

-- Win streak widget: {count, active, slots = [{booster, wins, lit, unlocked}],
-- boosters = free boosters of the next start}. next_level is nil when every
-- level is beaten.
function M.streak_view(streak, reached, next_level)
	local slots = {}
	for i, r in ipairs(C.streak.rewards) do
		slots[i] = {
			booster = r.booster,
			wins = r.wins,
			lit = streak >= r.wins,
			unlocked = M.is_unlocked(r.booster, reached),
		}
	end
	return {
		count = streak,
		active = reached >= C.streak.from_level,
		slots = slots,
		boosters = next_level and M.streak_boosters(streak, next_level) or {},
	}
end

return M
