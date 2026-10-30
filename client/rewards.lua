-- Queue of level results the town still has to show (pure Lua).
--
-- The meta pays the stars and coins of a result at once (meta:finish_level); the town shows them
-- later, when the player is back: they fly into the top bar, the streak lights up, unlock gifts appear.
-- Until then the top bar shows the balances without what is still queued (held()), so nothing is counted
-- twice and nothing jumps. The level chest is NOT in a queued result: a won chest waits in the meta until the
-- player takes it (the results window, or the town at its entry: meta:claim_level_chest), and the town offers
-- it itself. Only a chest the meta has paid already can be queued (the QA `reward` command, old queues): the
-- town just shows that one.
--
--   local rewards = require("client.rewards")
--   rewards.push(result)   -- a finish_level result (app.push_reward does this + a bus event)
--   rewards.held()         --> {coins, stars} of the queued results
--   rewards.pop()          --> the oldest normalized result, or nil
--   rewards.steps(r)       --> what to animate, in order (see below)
--
-- A result: {won, stars, coins, chest = {coins, boosters = {ids}, infinite_minutes} (paid already: QA and old
-- queues only), unlocked = {booster ids}, streak, level_id} for a win;
-- {won = false, life_lost, streak_lost, level_id} for a loss. Missing fields
-- count as none; wrong types are dropped (a bad QA payload cannot break the
-- town).

local M = {}

-- The result window chains levels (Next level -> Play) without visiting the town, so a session can queue
-- every win it makes; each carries a ceremony the meta has already paid for (a new booster, the stars) that a
-- dropped result would lose. A level is won once and the game ships 100, so no real session gets near this
-- cap: it only stops a runaway producer from growing the queue without bound (the oldest is dropped). The
-- level chests do not depend on it: they wait in the meta.
M.MAX = 128

local queue = {}

local function int(v)
	v = tonumber(v)
	if not v or v ~= v or v < 0 then return 0 end
	return math.floor(v)
end

local function ids(list)
	local out = {}
	if type(list) ~= "table" then return out end
	for _, id in ipairs(list) do
		if type(id) == "string" and id ~= "" then out[#out + 1] = id end
	end
	return out
end

-- A clean copy of a result (numbers >= 0, id lists of strings).
function M.normalize(r)
	if type(r) ~= "table" then return nil end
	local out = {
		won = r.won ~= false,
		level_id = tonumber(r.level_id),
		stars = int(r.stars),
		coins = int(r.coins),
		streak = int(r.streak),
		unlocked = ids(r.unlocked),
		life_lost = r.life_lost == true,
		streak_lost = int(r.streak_lost),
	}
	if not out.won then out.stars, out.coins = 0, 0 end
	if type(r.chest) == "table" then
		local c = r.chest
		out.chest = { coins = int(c.coins), boosters = ids(c.boosters), infinite_minutes = int(c.infinite_minutes) }
	end
	return out
end

-- Adds a result; returns the queue length, or nil for a non-table.
function M.push(r)
	local n = M.normalize(r)
	if not n then return nil end
	queue[#queue + 1] = n
	while #queue > M.MAX do table.remove(queue, 1) end
	return #queue
end

function M.pop()
	return table.remove(queue, 1)
end

function M.peek()
	return queue[1]
end

function M.count()
	return #queue
end

function M.clear()
	queue = {}
end

-- What one result puts into the top bar when it lands: coins, stars and the seconds of unlimited lives
-- (a level chest's infinite_minutes).
function M.amounts(r)
	local coins = r.coins + (r.chest and r.chest.coins or 0)
	return { coins = coins, stars = r.stars, infinite = (r.chest and r.chest.infinite_minutes or 0) * 60 }
end

-- Totals of everything still queued.
function M.held()
	local c, s, inf = 0, 0, 0
	for _, r in ipairs(queue) do
		local a = M.amounts(r)
		c, s, inf = c + a.coins, s + a.stars, inf + a.infinite
	end
	return { coins = c, stars = s, infinite = inf }
end

-- What the town animates for a result, in order:
--   {kind = "win", stars, coins}      stars and coins fly into the top bar
--   {kind = "streak", count}          the hit streak notes light up
--   {kind = "chest", chest}           a chest the meta paid already opens (its coins fly after it); a waiting
--                                     level chest is offered by the town itself (Town:queue_pending_chests)
--   {kind = "unlock", ids}            new boosters are handed over
--   {kind = "loss", life_lost, streak_lost}
function M.steps(r)
	local out = {}
	if not r then return out end
	if r.won then
		if r.stars > 0 or r.coins > 0 then out[#out + 1] = { kind = "win", stars = r.stars, coins = r.coins } end
		if r.streak > 0 then out[#out + 1] = { kind = "streak", count = r.streak } end
		if r.chest then out[#out + 1] = { kind = "chest", chest = r.chest } end
		if #r.unlocked > 0 then out[#out + 1] = { kind = "unlock", ids = r.unlocked } end
	elseif r.life_lost or r.streak_lost > 0 then
		out[#out + 1] = { kind = "loss", life_lost = r.life_lost, streak_lost = r.streak_lost }
	end
	return out
end

-- How many icons fly for an amount: 1 per star (at most 5), coins by size.
function M.flyers(kind, amount)
	amount = int(amount)
	if amount <= 0 then return 0 end
	if kind == "stars" then return math.min(amount, 5) end
	return math.max(3, math.min(10, math.ceil(amount / 15)))
end

-- Splits `amount` into n integer chunks that add up exactly (the counter
-- grows as each icon lands).
function M.chunks(amount, n)
	amount, n = int(amount), math.max(1, int(n))
	local out, left = {}, amount
	for i = 1, n do
		local c = math.floor(amount / n)
		if i <= amount % n then c = c + 1 end
		out[i] = c
		left = left - c
	end
	return out
end

return M
