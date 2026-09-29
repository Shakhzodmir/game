-- Meta layer facade: the one object the client talks to.
--
--   local Meta = require("meta.meta")
--   local meta = Meta.new(districts_json_table, seed)                     -- first launch
--   local meta, info = Meta.load(districts, current, previous, seed, now) -- later launches
--
-- Conventions
--   * `now` (seconds, e.g. socket.gettime() or os.time() in the client) is
--     always the last argument of a time-aware method; the meta never reads a
--     clock itself. lives.lua explains what a clock turned back does.
--   * A request the rules refuse returns false, "<reason>" and changes nothing
--     (not enough coins, no lives, locked booster, ...). Wrong arguments
--     (unknown ids, missing fields, a bad `now`) raise an error that points at
--     the calling line: they are client bugs.
--   * Every change of coins, stars, boosters and infinite lives lands in the
--     ledger with a reason tag; read it with drain_ledger().
--   * Saving: after handling an event, if dirty() is true, move the current
--     slot to "previous" and write serialize() to "current". Also save when
--     the app goes to the background, so the time marks of the lives are
--     fresh; moving those marks alone does not make the meta dirty, because
--     everything they drive is recomputed from the stored timestamps.
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

-- Seeds must be exact in a double; larger magnitudes would collapse into a
-- few salts.
local SEED_LIMIT = 2 ^ 53

local function make_salt(seed)
	if not util.is_int(seed) or math.abs(seed) >= SEED_LIMIT then
		error("meta: seed must be an integer with |seed| < 2^53, got " .. tostring(seed), 3)
	end
	return seed % (C.salt.max - C.salt.min + 1) + C.salt.min
end

local function check_level_id(id)
	if not util.is_int(id) then error("meta: level id must be an integer, got " .. tostring(id), 3) end
end

local function wrap(state, data)
	return setmetatable({ s = state, data = data, ledger = {}, rev = 0, saved_rev = 0 }, Meta)
end

local function fresh(data, salt)
	local self = wrap(save.fresh(salt, data), data)
	self:_touch()
	self:_change("start", { { "coins", C.coins.start } })
	self:_give_unlock_gifts()
	return self
end

-- A fresh save. `seed` is an integer from a random source with |seed| < 2^53;
-- it becomes the player's salt in [1, 2147483646].
function Meta.new(districts, seed)
	local salt = make_salt(seed)
	local self = fresh(town.validate(districts), salt)
	return self
end

-- Restores the meta from the two save slots (tables from serialize(), or nil).
-- Falls back from current to previous to a fresh save built from `seed`.
-- Then it settles what the stored state still owes:
--   * an attempt left open by a killed app: after the first move it is a
--     loss, before it the attempt is cancelled;
--   * unlock gifts and district chests that became due through an update of
--     the config or the districts.
-- info = {source = "current"|"previous"|"fresh", version, migrated, newer,
--         errors = {[slot] = reason}, interrupted = nil|"loss"|"cancelled",
--         loss = the finish_level loss result when interrupted == "loss",
--         unlock_gifts = {booster ids}, district_chests = {district ids}}
function Meta.load(districts, current, previous, seed, now)
	util.check_now(now, 2)
	local salt = make_salt(seed)
	local data = town.validate(districts)
	local state, info = save.load(current, previous, data)
	local self
	if state then
		self = wrap(state, data)
		if info.source ~= "current" or info.migrated then self:_touch() end
	else
		self = fresh(data, salt)
	end
	self:_tick(now)
	local run = self.s.progress.run
	if run and run.moved then
		info.interrupted, info.loss = "loss", self:_lose("interrupted")
	elseif run then
		self:cancel_level()
		info.interrupted = "cancelled"
	end
	info.unlock_gifts = self:_give_unlock_gifts()
	info.district_chests = self:_claim_district_chests()
	return self, info
end

-- The save table. Marks the meta as saved (dirty() becomes false).
function Meta:serialize()
	self.saved_rev = self.rev
	return save.serialize(self.s)
end

-- A counter that grows with every change of the saved state (not with the
-- time marks of the lives). Handy to refresh the UI.
function Meta:revision()
	return self.rev
end

-- True when the state changed since the last serialize() (always after new(),
-- and after a load that fell back, migrated or settled something).
function Meta:dirty()
	return self.rev ~= self.saved_rev
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

function Meta:_touch()
	self.rev = self.rev + 1
end

-- Checks `now` for the public method that received it (errors point at that
-- method's caller) and moves the lives to it. Every time-aware method calls
-- this first; lives.* then work at this time.
function Meta:_tick(now)
	local t = util.check_now(now, 3)
	if lives.update(self.s.lives, t) then self:_touch() end
	return t
end

function Meta:_change(reason, changes)
	local n = #self.ledger
	local ok, why = economy.apply(self.s, self.ledger, reason, changes)
	if #self.ledger > n then self:_touch() end
	return ok, why
end

-- Gives the unlock gift of every unlocked booster that did not get it yet.
-- Returns their ids in catalogue order.
function Meta:_give_unlock_gifts()
	local ids = inventory.due_gifts(self.s.unlock_gifts, progress.reached(self.s.progress))
	if #ids == 0 then return ids end
	local changes, all = {}, util.copy(self.s.unlock_gifts)
	for i, id in ipairs(ids) do
		changes[i] = { id, inventory.def(id).gift }
		all[#all + 1] = id
	end
	self:_change("unlock_gift", changes)
	self.s.unlock_gifts = inventory.sort(all)
	self:_touch()
	return ids
end

function Meta:_add_infinite(minutes, reason)
	if minutes == 0 then return end
	local left = lives.add_infinite(self.s.lives, minutes)
	economy.record(self.ledger, "infinite_minutes", minutes, math.ceil(left / 60), reason)
	self:_touch()
end

-- chest = {coins, boosters = {ids}, infinite_minutes?}
function Meta:_give_chest(chest, reason)
	self:_change(reason, economy.booster_changes(chest.boosters, 1, { { "coins", chest.coins } }))
	if chest.infinite_minutes then self:_add_infinite(chest.infinite_minutes, reason) end
end

-- Pays the chest of every complete district that has not paid it. Returns
-- the district ids.
function Meta:_claim_district_chests()
	local ids = {}
	for _, d in ipairs(self.data.list) do
		local chest = town.claim_chest(self.s.town, d)
		if chest then
			self:_touch()
			self:_give_chest(chest, "district_chest")
			ids[#ids + 1] = d.id
		end
	end
	return ids
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
	check_level_id(level_id)
	local rec = progress.record(self.s.progress, level_id)
	return { attempts = rec.attempts, fails = rec.fails }
end

-- The attempt in progress (a copy) or nil.
function Meta:run()
	return util.copy(self.s.progress.run)
end

function Meta:_can_start(level_id)
	local p = self.s.progress
	local next_level = progress.level_to_play(p)
	if not next_level then return false, "all_done" end
	if p.run then return false, "run_active" end
	if level_id ~= next_level then return false, "not_next_level" end
	if level_id > C.levels.free_up_to and not lives.can_play(self.s.lives) then
		return false, "no_lives"
	end
	return true
end

-- Can the level be started now? true, or false and one of
-- "all_done", "run_active", "not_next_level", "no_lives".
function Meta:can_start(level_id, now)
	check_level_id(level_id)
	self:_tick(now)
	local ok, why = self:_can_start(level_id)
	return ok, why
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
	local seen = {}
	for _, id in ipairs(boosters or {}) do
		inventory.need(id, "pre")
		if seen[id] then error("meta: pre-level booster '" .. id .. "' picked twice", 2) end
		seen[id] = true
	end
	self:_tick(now)
	local ok, why = self:_can_start(level.id)
	if not ok then return false, why end
	local paid = inventory.sort(boosters or {})
	for _, id in ipairs(paid) do
		if not inventory.is_unlocked(id, level.id) then return false, "locked" end
	end
	ok, why = self:_change("pre_booster", economy.booster_changes(paid, -1))
	if not ok then return false, why end

	local p = self.s.progress
	local free = inventory.streak_boosters(p.streak, level.id)
	local lives_free = level.id <= C.levels.free_up_to or lives.infinite_active(self.s.lives)
	local run = progress.begin(p, level, lives_free, paid)
	self:_touch()
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

-- Call at the first move of the attempt (swap or tap). From then on leaving
-- the level is a loss, and so is an app kill.
function Meta:note_move()
	local run = self.s.progress.run
	if not run then return false, "no_run" end
	if not run.moved then
		run.moved = true
		self:_touch()
	end
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
	self:_touch()
	self:_change("cancel_refund", economy.booster_changes(run.boosters, 1))
	return true
end

-- Ends the attempt. result = {won = true|false, level_id, difficulty? (must
-- match the start), moves_at_win (a win only), quit_after_first_move =
-- nil|true|false (a loss only)}.
-- A loss needs a move: call note_move() at the first move, or cancel_level()
-- to leave before it. quit_after_first_move = true counts as that move.
-- Win:  {won = true, level_id, coins, stars, chest|nil, unlocked = {ids},
--        streak, next_level|nil}
-- Loss: {won = false, level_id, reason = "out_of_moves"|"quit", life_lost,
--        streak_lost = streak before the loss, fails}
-- or false, "no_run".
function Meta:finish_level(result, now)
	if type(result) ~= "table" then error("meta: finish_level needs a result table", 2) end
	if type(result.won) ~= "boolean" then
		error("meta: result.won must be true or false, got " .. tostring(result.won), 2)
	end
	local quit = result.quit_after_first_move
	if quit ~= nil and type(quit) ~= "boolean" then
		error("meta: result.quit_after_first_move must be nil or a boolean", 2)
	end
	if result.won then
		if quit then error("meta: quit_after_first_move = true contradicts won = true", 2) end
		if not util.is_int(result.moves_at_win) or result.moves_at_win < 0 then
			error("meta: result.moves_at_win must be a non-negative integer for a win", 2)
		end
	end
	self:_tick(now)
	local run = self.s.progress.run
	if not run then return false, "no_run" end
	if result.level_id ~= run.level_id then
		error("meta: finish_level result must be for the running level " .. run.level_id, 2)
	end
	if result.difficulty ~= nil and result.difficulty ~= run.difficulty then
		error("meta: finish_level difficulty differs from the one the level started with", 2)
	end
	if result.won then
		local r = self:_win(result.moves_at_win)
		return r
	end
	if quit then run.moved = true end
	if not run.moved then
		error("meta: a loss needs a move: call note_move() at the first move, or cancel_level() to leave before it", 2)
	end
	local r = self:_lose(quit and "quit" or "out_of_moves")
	return r
end

function Meta:_win(moves_at_win)
	local p = self.s.progress
	local coins, stars = economy.win_reward(p.run.difficulty, moves_at_win)
	local run = progress.finish(p, true)
	self.s.stats.wins = self.s.stats.wins + 1
	self:_touch()
	self:_change("level_win", { { "coins", coins }, { "stars", stars } })
	local unlocked = self:_give_unlock_gifts()
	local chest = economy.level_chest(run.level_id)
	if chest then self:_give_chest(chest, "level_chest") end
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

function Meta:_lose(reason)
	local p = self.s.progress
	local streak_before = p.streak
	local run, rec = progress.finish(p, false)
	self.s.stats.losses = self.s.stats.losses + 1
	self:_touch()
	local life_lost = false
	if not run.free and not lives.infinite_active(self.s.lives) then
		life_lost = lives.consume(self.s.lives)
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
	self:_touch()
	return { k = k, price = offer.price, moves = offer.moves, riff = offer.riff }
end

-- Rewarded ad watched (the caller checks the ad service): {moves = 3} once
-- per attempt, else false, "no_run" | "already_used".
function Meta:grant_ad_moves()
	local run = self.s.progress.run
	if not run then return false, "no_run" end
	if run.ad_used then return false, "already_used" end
	run.ad_used, run.moved = true, true
	self:_touch()
	return { moves = C.ad_moves }
end

-- boosters ----------------------------------------------------------------------

-- [{id, kind, count, unlocked, unlock_level, pack_price, pack_size}] in catalogue order.
function Meta:inventory()
	return inventory.view(self.s.wallet, progress.reached(self.s.progress))
end

function Meta:booster_count(id)
	inventory.need(id)
	return self.s.wallet[id]
end

-- Spends one in-level booster during the attempt. true, or false and
-- "no_run", "locked", "not_enough_<id>". Counts as the first move.
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
	return inventory.streak_view(p.streak, progress.reached(p), progress.level_to_play(p))
end

-- Free pre-level boosters the next start will place (locked ones are left out).
function Meta:streak_boosters_for_next_start()
	local p = self.s.progress
	local level = progress.level_to_play(p)
	if not level then return {} end
	return inventory.streak_boosters(p.streak, level)
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
	self:_tick(now)
	return lives.status(self.s.lives)
end

function Meta:_refill_check()
	local ls = self.s.lives
	if ls.count >= C.lives.max then return false, "full" end
	if lives.infinite_active(ls) then return false, "infinite_active" end
	return true
end

-- The refill button: {price, available, affordable, reason = nil | "full" |
-- "infinite_active"}.
function Meta:refill_offer(now)
	self:_tick(now)
	local available, reason = self:_refill_check()
	return {
		price = C.lives.refill_price,
		available = available,
		affordable = self.s.wallet.coins >= C.lives.refill_price,
		reason = reason,
	}
end

-- Refills lives to the maximum for coins. true, or false and "full" |
-- "infinite_active" | "not_enough_coins".
function Meta:refill_lives(now)
	self:_tick(now)
	local ok, why = self:_refill_check()
	if not ok then return false, why end
	ok, why = self:_change("refill_lives", { { "coins", -C.lives.refill_price } })
	if not ok then return false, why end
	lives.refill(self.s.lives)
	return true
end

-- Gives a reward from outside the meta rules (store purchase, event, gift).
-- reward = {coins?, boosters? = {[id] = count}, infinite_minutes?}; reason is
-- the ledger tag, e.g. "iap_starter_pack". Stars cannot be granted: they come
-- only from wins.
local REWARD_KEYS = { coins = true, boosters = true, infinite_minutes = true }

function Meta:grant(reward, reason, now)
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
	self:_tick(now)
	self:_change(reason, changes)
	self:_add_infinite(minutes, reason)
	return true
end

-- town ----------------------------------------------------------------------------

-- All districts in order, as views: {id, index, name, available, complete,
-- done, total, chest_claimed, view, unmuted = {stems}, tasks = [{id, name,
-- cost, stem, done}], chest, next_task = {district, id, name, cost, stem,
-- affordable}|nil}.
function Meta:districts()
	local out = {}
	for i, d in ipairs(self.data.list) do
		out[i] = town.district_view(self.s.town, self.data, d, self.s.wallet.stars)
	end
	return out
end

function Meta:district(id)
	local d = town.need(self.data, id)
	return town.district_view(self.s.town, self.data, d, self.s.wallet.stars)
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
	return town.task_view(d, town.next_task(self.s.town, d), self.s.wallet.stars)
end

-- Stems of the district track that play now, in task order.
function Meta:unmuted_stems(district_id)
	local d = town.need(self.data, district_id)
	return town.unmuted(self.s.town, d)
end

-- Does a task for stars. Returns {district, task, stem, district_complete,
-- chest|nil (paid the first time the district is complete), next_district|nil
-- (the district that chest opens)} or false and "district_locked",
-- "already_done", "wrong_order", "not_enough_stars".
function Meta:complete_task(district_id, task_id)
	local d = town.need(self.data, district_id)
	local task, why = town.check_task(self.s.town, self.data, d, task_id)
	if not task then return false, why end
	local ok, why2 = self:_change("district_task", { { "stars", -task.cost } })
	if not ok then return false, why2 end
	local complete = town.mark_done(self.s.town, d, task)
	self:_touch()
	local chest = town.claim_chest(self.s.town, d)
	if chest then self:_give_chest(chest, "district_chest") end
	local nxt = chest and self.data.list[d.index + 1]
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
	if self.s.town[d.id].view ~= view then
		self.s.town[d.id].view = view
		self:_touch()
	end
	return true
end

function Meta:view(district_id)
	local d = town.need(self.data, district_id)
	return self.s.town[d.id].view
end

-- settings, tutorials, stats -----------------------------------------------------------

function Meta:settings()
	return util.copy(self.s.prefs.settings)
end

-- key: music|sfx (0..1, clamped), haptics|reduced_motion (boolean),
-- input_mode ("swipe"|"taptap"), language ("auto"|"en"|"ru").
-- true, or false, "invalid_value".
function Meta:set_setting(key, value)
	local before = self.s.prefs.settings[key]
	local ok, why = prefs.set(self.s.prefs, key, value)
	if ok and self.s.prefs.settings[key] ~= before then self:_touch() end
	return ok, why
end

function Meta:tutorial_seen(id)
	local seen = prefs.seen(self.s.prefs, id)
	return seen
end

-- Returns true the first time an id is marked.
function Meta:mark_tutorial_seen(id)
	local new = prefs.mark(self.s.prefs, id)
	if new then self:_touch() end
	return new
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
