-- Meta layer facade: the one object the client talks to.
--
--   local Meta = require("meta.meta")
--   local meta = Meta.new(districts_json_table, random_seed)            -- first launch
--   local meta, info = Meta.load(districts, current, previous, seed, now) -- later launches
--
-- Conventions
--   * `now` (seconds, e.g. socket.gettime() or os.time() in the client) is
--     always the last argument of a time-aware method. The meta never reads a
--     clock itself and treats a clock that went back as standing still.
--   * A request the rules refuse returns false, "<reason>" and changes nothing
--     (not enough coins, no lives, locked booster, ...). Wrong arguments
--     (unknown ids, missing fields) raise an error: they are client bugs.
--   * Every change of coins, stars and boosters goes through economy.apply()
--     with a reason tag and lands in the ledger; read it with drain_ledger().
--   * Persist meta:serialize() after every state change: move the old
--     current slot to "previous" and write the new table to "current".
--
-- The facade never reads files: the caller decodes content/districts.json and
-- passes the table in.

local C = require("meta.config")
local util = require("meta.util")
local economy = require("meta.economy")
local inventory = require("meta.inventory")
local lives = require("meta.lives")
local progress = require("meta.progress")
local town = require("meta.town")
local prefs = require("meta.prefs")
local save = require("meta.save")

local Meta = {}
Meta.__index = Meta

local function make_salt(seed)
	if not util.is_int(seed) then error("meta: seed must be an integer", 3) end
	return seed % (C.salt.max - C.salt.min + 1) + C.salt.min
end

local function wrap(state, data)
	return setmetatable({ s = state, data = data, ledger = {} }, Meta)
end

local function fresh(data, salt)
	local self = wrap(save.fresh(salt, data), data)
	self:_change("start", { { "coins", C.coins.start } })
	self:_unlock(0, progress.reached(self.s.progress))
	return self
end

-- A fresh save. `seed` is any integer from a random source; it becomes the
-- player's salt in [1, 2147483646].
function Meta.new(districts, seed)
	return fresh(town.validate(districts), make_salt(seed))
end

-- Restores the meta from the two save slots (tables from serialize(), or nil).
-- Falls back from current to previous to a fresh save built from `seed`.
-- An attempt left open by a killed app is settled here: after the first move
-- it counts as a loss, before it the attempt is cancelled.
-- info = {source, version, migrated, errors, interrupted = nil|"loss"|"cancelled"}
function Meta.load(districts, current, previous, seed, now)
	util.check_now(now)
	local salt = make_salt(seed)
	local data = town.validate(districts)
	local state, info = save.load(current, previous, data)
	local self = state and wrap(state, data) or fresh(data, salt)
	local run = self.s.progress.run
	if run and run.moved then
		self:_lose(now, "interrupted")
		info.interrupted = "loss"
	elseif run then
		self:cancel_level()
		info.interrupted = "cancelled"
	end
	return self, info
end

function Meta:serialize()
	return save.serialize(self.s)
end

-- Ledger entries since the last call: {item, delta, balance, reason, flow}.
-- flow is "source" or "sink"; item is "coins", "stars", a booster id or
-- "infinite_minutes" (balance = minutes left, rounded up).
function Meta:drain_ledger()
	local out = self.ledger
	self.ledger = {}
	return out
end

-- internal -------------------------------------------------------------------

function Meta:_change(reason, changes)
	return economy.apply(self.s, self.ledger, reason, changes)
end

-- Gives the unlock gift of every booster that unlocks between the two levels.
function Meta:_unlock(from, to)
	local ids = inventory.newly_unlocked(from, to)
	local changes = {}
	for _, id in ipairs(ids) do changes[#changes + 1] = { id, inventory.def(id).gift } end
	self:_change("unlock_gift", changes)
	return ids
end

function Meta:_add_infinite(minutes, reason, now)
	if minutes == 0 then return end
	local left = lives.add_infinite(self.s.lives, minutes, now)
	economy.record(self.ledger, "infinite_minutes", minutes, math.ceil(left / 60), reason)
end

-- Chest = {coins, boosters = {ids}, infinite_minutes?}
function Meta:_give_chest(chest, reason, now)
	self:_change(reason, economy.booster_changes(chest.boosters, 1, { { "coins", chest.coins } }))
	if chest.infinite_minutes then self:_add_infinite(chest.infinite_minutes, reason, now) end
end

-- levels -----------------------------------------------------------------------

-- The next unbeaten level ("Level N" button), or nil when all levels are beaten.
function Meta:level_to_play()
	return progress.level_to_play(self.s.progress)
end

-- True after the last shipped level is beaten ("more levels coming").
function Meta:all_done()
	return progress.level_to_play(self.s.progress) == nil
end

-- {attempts = finished attempts, fails = losses in a row} of a level.
function Meta:attempts(level_id)
	local rec = progress.record(self.s.progress, level_id)
	return { attempts = rec.attempts, fails = rec.fails }
end

-- The attempt in progress (copy) or nil.
function Meta:run()
	return util.copy(self.s.progress.run)
end

-- Can the level be started now? true, or false and one of
-- "all_done", "run_active", "not_next_level", "no_lives".
function Meta:can_start(level_id, now)
	if not util.is_int(level_id) then error("meta: level id must be an integer", 2) end
	util.check_now(now)
	local p = self.s.progress
	local next_level = progress.level_to_play(p)
	if not next_level then return false, "all_done" end
	if p.run then return false, "run_active" end
	if level_id ~= next_level then return false, "not_next_level" end
	if level_id > C.levels.free_up_to and not lives.can_play(self.s.lives, now) then
		return false, "no_lives"
	end
	return true
end

-- Starts an attempt. level = {id, difficulty} from the level file; boosters =
-- pre-level boosters the player picked (each at most once), paid from the
-- inventory. Returns what the core needs:
--   {level_id, difficulty, attempt, assist, salt,
--    boosters (all to place: streak ones first, then paid ones),
--    streak_boosters, paid_boosters, life_at_stake}
-- or false and a reason from can_start(), "locked" or "not_enough_<booster>".
function Meta:start_level(level, boosters, now)
	if type(level) ~= "table" or not util.is_int(level.id) then
		error("meta: start_level needs level = {id = <integer>, difficulty = ...}", 2)
	end
	economy.check_difficulty(level.difficulty)
	if boosters ~= nil and type(boosters) ~= "table" then error("meta: boosters must be a list of ids", 2) end
	local ok, why = self:can_start(level.id, now)
	if not ok then return false, why end
	local p = self.s.progress
	local paid, seen = {}, {}
	for _, id in ipairs(boosters or {}) do
		inventory.need(id, "pre")
		if seen[id] then error("meta: pre-level booster '" .. id .. "' picked twice", 2) end
		seen[id] = true
		if not inventory.is_unlocked(id, level.id) then return false, "locked" end
		paid[#paid + 1] = id
	end
	paid = inventory.sort(paid)
	ok, why = self:_change("pre_booster", economy.booster_changes(paid, -1))
	if not ok then return false, why end

	local free = inventory.streak_boosters(p.streak, level.id)
	local lives_free = level.id <= C.levels.free_up_to or lives.infinite_active(self.s.lives, now)
	local run = progress.begin(p, level, lives_free, paid)
	local all = {}
	for _, id in ipairs(free) do all[#all + 1] = id end
	for _, id in ipairs(paid) do all[#all + 1] = id end
	return {
		level_id = run.level_id,
		difficulty = run.difficulty,
		attempt = run.attempt,
		assist = progress.record(p, level.id).fails,
		salt = self.s.salt,
		boosters = all,
		streak_boosters = free,
		paid_boosters = util.copy(paid),
		life_at_stake = not lives_free,
	}
end

-- Call once the player made the first move of the attempt. From then on
-- leaving the level is a loss, and so is an app kill.
function Meta:note_move()
	local run = self.s.progress.run
	if not run then return false, "no_run" end
	run.moved = true
	return true
end

-- Leaves the level before the first move: the attempt does not count, the
-- streak stays, paid pre-level boosters come back. false, "moved" after the
-- first move (use finish_level with a loss instead).
function Meta:cancel_level()
	local run = self.s.progress.run
	if not run then return false, "no_run" end
	if run.moved then return false, "moved" end
	progress.cancel(self.s.progress)
	self:_change("cancel_refund", economy.booster_changes(run.boosters, 1))
	return true
end

-- Ends the attempt. result = {won, level_id, difficulty?, moves_at_win (when
-- won), quit_after_first_move}. A result with won = false is a loss: out of
-- moves and gave up, or quit after the first move.
-- Win:  {won = true, level_id, coins, stars, chest|nil, unlocked = {ids},
--        streak, next_level|nil}
-- Loss: {won = false, level_id, reason = "out_of_moves"|"quit", life_lost,
--        streak_lost = streak before the loss, fails}
function Meta:finish_level(result, now)
	util.check_now(now)
	local run = self.s.progress.run
	if not run then return false, "no_run" end
	if type(result) ~= "table" or result.level_id ~= run.level_id then
		error("meta: finish_level result must be for the running level " .. run.level_id, 2)
	end
	if result.difficulty ~= nil and result.difficulty ~= run.difficulty then
		error("meta: finish_level difficulty differs from the one the level started with", 2)
	end
	if result.won then return self:_win(result.moves_at_win, now) end
	return self:_lose(now, result.quit_after_first_move and "quit" or "out_of_moves")
end

function Meta:_win(moves_at_win, now)
	local p = self.s.progress
	local coins, stars = economy.win_reward(p.run.difficulty, moves_at_win)
	local from = progress.reached(p)
	local run = progress.finish(p, true)
	local reached = progress.reached(p)
	self.s.stats.wins = self.s.stats.wins + 1
	self:_change("level_win", { { "coins", coins }, { "stars", stars } })
	local unlocked = self:_unlock(from, reached)
	local chest = economy.level_chest(run.level_id, reached)
	if chest then self:_give_chest(chest, "level_chest", now) end
	return {
		won = true,
		level_id = run.level_id,
		coins = coins,
		stars = stars,
		chest = chest,
		unlocked = unlocked,
		streak = p.streak,
		next_level = progress.level_to_play(p),
	}
end

function Meta:_lose(now, reason)
	local p = self.s.progress
	local streak_before = p.streak
	local run, rec = progress.finish(p, false)
	self.s.stats.losses = self.s.stats.losses + 1
	local life_lost = false
	if not run.free and not lives.infinite_active(self.s.lives, now) then
		life_lost = lives.consume(self.s.lives, now)
	end
	return {
		won = false,
		level_id = run.level_id,
		reason = reason,
		life_lost = life_lost,
		streak_lost = streak_before,
		fails = rec.fails,
	}
end

-- The next "+5 moves" offer of the attempt:
-- {k, price, moves, riff, affordable}, or nil (no attempt / limit reached).
function Meta:continue_offer()
	local run = self.s.progress.run
	if not run then return nil end
	local k = run.continues + 1
	local price = economy.continue_price(k)
	if not price then return nil end
	return {
		k = k,
		price = price,
		moves = C.continues.moves,
		riff = k >= C.continues.riff_from,
		affordable = self.s.wallet.coins >= price,
	}
end

-- Buys offer k (the k shown to the player, so a double tap cannot buy the
-- next, pricier one). Returns {k, price, moves, riff} for the core's
-- continue command, or false and "no_run", "limit_reached", "stale_offer",
-- "not_enough_coins".
function Meta:buy_continue(k)
	if not util.is_int(k) then error("meta: buy_continue(k) needs the offer number k", 2) end
	local run = self.s.progress.run
	if not run then return false, "no_run" end
	local offer = self:continue_offer()
	if not offer then return false, "limit_reached" end
	if k ~= offer.k then return false, "stale_offer" end
	local ok, why = self:_change("continue", { { "coins", -offer.price } })
	if not ok then return false, why end
	run.continues, run.moved = k, true
	return { k = k, price = offer.price, moves = offer.moves, riff = offer.riff }
end

-- Rewarded ad watched (the caller checks the ad service): {moves = 3} once
-- per attempt, else false, "no_run" | "already_used".
function Meta:grant_ad_moves()
	local run = self.s.progress.run
	if not run then return false, "no_run" end
	if run.ad_used then return false, "already_used" end
	run.ad_used, run.moved = true, true
	return { moves = C.ad_moves }
end

-- boosters ----------------------------------------------------------------------

-- [{id, kind, count, unlocked, unlock_level, pack_price, pack_size}] in catalogue order.
function Meta:inventory()
	local reached = progress.reached(self.s.progress)
	local out = {}
	for _, def in ipairs(C.boosters) do
		out[#out + 1] = {
			id = def.id,
			kind = def.kind,
			count = self.s.wallet[def.id],
			unlocked = def.unlock <= reached,
			unlock_level = def.unlock,
			pack_price = def.pack_price,
			pack_size = C.pack_size,
		}
	end
	return out
end

function Meta:booster_count(id)
	inventory.need(id)
	return self.s.wallet[id]
end

-- Spends one in-level booster during the attempt. true, or false and
-- "no_run", "locked", "not_enough_<id>".
function Meta:use_booster(id)
	inventory.need(id, "in")
	local run = self.s.progress.run
	if not run then return false, "no_run" end
	if not inventory.is_unlocked(id, run.level_id) then return false, "locked" end
	local ok, why = self:_change("in_level_booster", { { id, -1 } })
	if not ok then return false, why end
	run.moved = true
	return true
end

-- Buys a pack of C.pack_size boosters for coins: {id, count, price}, or
-- false and "locked" | "not_enough_coins".
function Meta:buy_booster_pack(id)
	local def = inventory.need(id)
	if not inventory.is_unlocked(id, progress.reached(self.s.progress)) then return false, "locked" end
	local ok, why = self:_change("booster_pack", { { "coins", -def.pack_price }, { id, C.pack_size } })
	if not ok then return false, why end
	return { id = id, count = C.pack_size, price = def.pack_price }
end

-- Win streak for the level button: {count, active, slots = [{booster, wins,
-- lit, unlocked}], boosters = free boosters of the next start}.
function Meta:streak()
	local p = self.s.progress
	local level = progress.reached(p)
	local slots = {}
	for i, r in ipairs(C.streak.rewards) do
		slots[i] = {
			booster = r.booster,
			wins = r.wins,
			lit = p.streak >= r.wins,
			unlocked = inventory.is_unlocked(r.booster, level),
		}
	end
	return {
		count = p.streak,
		active = level >= C.streak.from_level,
		slots = slots,
		boosters = self:streak_boosters_for_next_start(),
	}
end

-- Free pre-level boosters the next start will place (locked ones are left out).
function Meta:streak_boosters_for_next_start()
	local level = progress.level_to_play(self.s.progress)
	if not level then return {} end
	return inventory.streak_boosters(self.s.progress.streak, level)
end

-- wallet and lives --------------------------------------------------------------

function Meta:coins()
	return self.s.wallet.coins
end

function Meta:stars()
	return self.s.wallet.stars
end

-- {count, max, next_in_seconds (0 when full), infinite_seconds}
function Meta:lives(now)
	return lives.status(self.s.lives, now)
end

-- Refills lives to the maximum for coins. true, or false and "full" |
-- "not_enough_coins".
function Meta:refill_lives(now)
	local ls = self.s.lives
	lives.update(ls, now)
	if ls.count >= C.lives.max then return false, "full" end
	local ok, why = self:_change("refill_lives", { { "coins", -C.lives.refill_price } })
	if not ok then return false, why end
	lives.refill(ls, now)
	return true
end

-- Gives a reward from outside the meta rules (store purchase, event, gift).
-- reward = {coins?, boosters? = {[id] = count}, infinite_minutes?}; reason is
-- the ledger tag, e.g. "iap_starter_pack". Stars cannot be granted: they come
-- only from wins.
local REWARD_KEYS = { coins = true, boosters = true, infinite_minutes = true }

function Meta:grant(reward, reason, now)
	util.check_now(now)
	if type(reward) ~= "table" then error("meta: grant needs a reward table", 2) end
	if type(reason) ~= "string" or reason == "" then error("meta: grant needs a reason tag", 2) end
	for k in pairs(reward) do -- order-free: validation only
		if not REWARD_KEYS[k] then error("meta: grant cannot give '" .. tostring(k) .. "'", 2) end
	end
	local function amount(v, what)
		if v == nil then return 0 end
		if not util.is_int(v) or v < 0 then error("meta: grant " .. what .. " must be a non-negative integer", 3) end
		return v
	end
	local changes = { { "coins", amount(reward.coins, "coins") } }
	local boosters = reward.boosters or {}
	if type(boosters) ~= "table" then error("meta: grant boosters must be a table {[id] = count}", 2) end
	for id in pairs(boosters) do inventory.need(id) end -- order-free: validation only
	for _, id in ipairs(inventory.ids) do
		changes[#changes + 1] = { id, amount(boosters[id], id) }
	end
	local minutes = amount(reward.infinite_minutes, "infinite_minutes")
	self:_change(reason, changes)
	self:_add_infinite(minutes, reason, now)
	return true
end

-- town ----------------------------------------------------------------------------

function Meta:_task_view(d, task)
	return {
		district = d.id,
		id = task.id,
		name = util.copy(task.name),
		cost = task.cost,
		stem = task.stem,
		affordable = self.s.wallet.stars >= task.cost,
	}
end

function Meta:_district_view(d)
	local t = self.s.town[d.id]
	local available = town.is_available(self.s.town, self.data, d)
	local tasks = {}
	for j, task in ipairs(d.tasks) do
		tasks[j] = { id = task.id, name = util.copy(task.name), cost = task.cost, stem = task.stem, done = j <= t.done }
	end
	local next_task = available and town.next_task(self.s.town, d)
	return {
		id = d.id,
		index = d.index,
		name = util.copy(d.name),
		available = available,
		complete = town.is_complete(self.s.town, d),
		done = t.done,
		total = #d.tasks,
		view = t.view,
		unmuted = town.unmuted(self.s.town, d),
		tasks = tasks,
		chest = util.copy(d.chest),
		next_task = next_task and self:_task_view(d, next_task) or nil,
	}
end

-- All districts in order, as views: {id, index, name, available, complete,
-- done, total, view, unmuted = {stems}, tasks = [{id, name, cost, stem, done}],
-- chest, next_task = {district, id, name, cost, stem, affordable}|nil}.
function Meta:districts()
	local out = {}
	for i, d in ipairs(self.data.list) do out[i] = self:_district_view(d) end
	return out
end

function Meta:district(id)
	return self:_district_view(town.need(self.data, id))
end

-- Id of the district the player is building now, or nil when the town is complete.
function Meta:current_district()
	local d = town.current(self.s.town, self.data)
	return d and d.id or nil
end

-- The task to show above the level button, or nil when the town is complete.
function Meta:next_task()
	local d = town.current(self.s.town, self.data)
	if not d then return nil end
	return self:_task_view(d, town.next_task(self.s.town, d))
end

-- Stems of the district track that play now, in task order.
function Meta:unmuted_stems(district_id)
	return town.unmuted(self.s.town, town.need(self.data, district_id))
end

-- Does a task for stars. Returns {district, task, stem, district_complete,
-- chest|nil, next_district|nil} or false and "district_locked",
-- "already_done", "wrong_order", "not_enough_stars".
function Meta:complete_task(district_id, task_id)
	local d = town.need(self.data, district_id)
	local task, why = town.check_task(self.s.town, self.data, d, task_id)
	if not task then return false, why end
	local ok, why2 = self:_change("district_task", { { "stars", -task.cost } })
	if not ok then return false, why2 end
	local complete = town.mark_done(self.s.town, d)
	local chest
	if complete then
		chest = util.copy(d.chest)
		self:_give_chest(chest, "district_chest")
	end
	local nxt = complete and self.data.list[d.index + 1]
	return {
		district = d.id,
		task = task.id,
		stem = task.stem,
		district_complete = complete,
		chest = chest,
		next_district = nxt and nxt.id or nil,
	}
end

-- Day / concert look of an available district (cosmetic).
function Meta:set_view(district_id, view)
	local d = town.need(self.data, district_id)
	if not util.index_of(C.views, view) then error("meta: unknown view '" .. tostring(view) .. "'", 2) end
	if not town.is_available(self.s.town, self.data, d) then return false, "district_locked" end
	self.s.town[d.id].view = view
	return true
end

function Meta:view(district_id)
	return self.s.town[town.need(self.data, district_id).id].view
end

-- settings, tutorials, stats -----------------------------------------------------------

function Meta:settings()
	return util.copy(self.s.prefs.settings)
end

-- key: music|sfx (0..1, clamped), haptics|reduced_motion (boolean),
-- input_mode ("swipe"|"taptap"), language ("auto"|"en"|"ru").
-- true, or false, "invalid_value".
function Meta:set_setting(key, value)
	return prefs.set(self.s.prefs, key, value)
end

function Meta:tutorial_seen(id)
	return prefs.seen(self.s.prefs, id)
end

-- Returns true the first time an id is marked.
function Meta:mark_tutorial_seen(id)
	return prefs.mark(self.s.prefs, id)
end

function Meta:seen_tutorials()
	return util.copy(self.s.prefs.tutorial)
end

-- {wins, losses, coins_earned, coins_spent}; coins = earned - spent.
function Meta:stats()
	return util.copy(self.s.stats)
end

function Meta:salt()
	return self.s.salt
end

return Meta
