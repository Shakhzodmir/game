-- Booster catalogue rules: which boosters exist, when they unlock and which
-- free boosters the win streak gives. Counts live in the wallet (economy.lua).
--
-- "reached" is the level the player is about to play: beaten + 1 (it stays
-- above the last level once everything is beaten). A booster is unlocked when
-- its unlock level <= reached.

local C = require("meta.config")

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

-- Boosters that unlock when "reached" moves from `from` to `to`, in catalogue order.
function M.newly_unlocked(from, to)
	local out = {}
	for _, def in ipairs(C.boosters) do
		if def.unlock > from and def.unlock <= to then out[#out + 1] = def.id end
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

-- Sorts a list of booster ids into catalogue order (stable for duplicates).
function M.sort(list)
	local out = {}
	for _, id in ipairs(M.ids) do
		for _, x in ipairs(list) do
			if x == id then out[#out + 1] = x end
		end
	end
	return out
end

return M
