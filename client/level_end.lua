-- How a level attempt ends, through the meta (pure Lua apart from the Defold
-- message that app.push_reward / app.commit may post). The level screen (screens/level/
-- level.gui_script) calls these; the rules are the meta's (meta-economy.md, 5, 6):
--
--   level_end.win(core_result, ctx)       -- meta:finish_level (won), the boosters the core could
--                                         -- not place come back, the result goes to the town
--   level_end.lose(core_result, ctx)      -- finish_level (lost): a life, the streak
--   level_end.quit(ctx)                   -- pause -> leave: dropped before the first move, a loss after it
--   level_end.continue(k, ctx)            -- "+5 moves" for coins (meta:buy_continue)
--   level_end.ad_moves(ctx, cb)           -- "+3 moves" for a rewarded video (cb(res | nil, why))
--   level_end.offer_shown(offer, ctx)     -- analytics only
--   level_end.first_move(ctx), level_end.booster_used(ctx, id)   -- analytics only
--   level_end.refunds(unplaced, paid)     -- the boosters that come back for the core's `unplaced` list
--
-- ctx = {level_id, t0 (app.now() at the start of the level)}. A level without a meta attempt (the
-- debug start) gets a stand-in result and touches nothing. Every function returns the meta's result
-- table (win: {coins, stars, chest, unlocked, streak, next_level} where chest is the chest that now WAITS in
-- the meta, not paid (the results window offers it, app.claim_level_chest pays it); loss: {life_lost,
-- streak_lost, fails, reason}) or nil and a reason; none of them raises: a bug here must not lose the
-- player's result.

local app = require("client.app")
local analytics = require("client.services.analytics")
local ads = require("client.services.ads")

local M = {}

-- core-rules.md 17.2: item codes of `unplaced` 1..7; 8 is the Riff that comes with a bought continue
M.ITEMS = { "stick", "row_light", "col_light", "remix", "riff", "sub", "disco" }
local PRE = { riff = true, sub = true, disco = true }

local function log(name, params)
	local ok, err = pcall(analytics.log, name, params)
	if not ok then print("WARNING: level_end: analytics " .. name .. ": " .. tostring(err)) end
end

local function seconds(ctx)
	local t0 = ctx and ctx.t0
	if not t0 then return 0 end
	return math.max(0, math.floor(app.now() - t0))
end

-- The boosters that come back for the core's `unplaced` codes: {[id] = count} or nil. In-level boosters
-- (the meta charged them when the core took them) always; pre-level ones only as many as were paid for
-- (free ones from the hit streak are not refunded: nothing was spent).
function M.refunds(unplaced, paid)
	local left = {}
	for _, id in ipairs(paid or {}) do left[id] = (left[id] or 0) + 1 end
	local out, any = {}, false
	for _, code in ipairs(unplaced or {}) do
		local id = M.ITEMS[code]
		if id and PRE[id] then
			if (left[id] or 0) > 0 then
				left[id] = left[id] - 1
			else
				id = nil
			end
		end
		if id then
			out[id] = (out[id] or 0) + 1
			any = true
		end
	end
	return any and out or nil
end

local function refund(meta, unplaced, run)
	local back = M.refunds(unplaced, run and run.boosters or nil)
	if not back then return nil end
	local ok, err = pcall(meta.grant, meta, { boosters = back }, "unplaced_refund", app.now())
	if not ok then
		print("WARNING: level_end: refund failed: " .. tostring(err))
		return nil
	end
	return back
end

-- the stand-in result of a level without a meta attempt
local function standalone(won, core_result, ctx)
	return {
		won = won, standalone = true, level_id = ctx and ctx.level_id or 0,
		coins = 0, stars = won and (core_result and core_result.stars or 0) or 0, streak = 0, unlocked = {},
		next_level = won and ((ctx and ctx.level_id or 0) + 1) or nil,
		life_lost = false, streak_lost = 0, fails = 0, reason = "out_of_moves",
	}
end

function M.win(core_result, ctx)
	core_result = core_result or {}
	local meta = app.meta
	local run = meta and meta:run() or nil
	if not run then return standalone(true, core_result, ctx) end
	local ok, res = pcall(meta.finish_level, meta, {
		won = true, level_id = run.level_id, moves_at_win = core_result.moves_at_win or 0,
	}, app.now())
	if not ok or not res then
		print("WARNING: level_end: finish_level (win) failed: " .. tostring(res))
		return nil, tostring(res)
	end
	local back = refund(meta, core_result.unplaced, run)
	if back then res.refund = back end
	app.commit("level_win")
	-- the town gets the result without the level chest: it is not paid (it waits in the meta until the player
	-- claims it in the results window or in the town), and its unlimited lives must not run before that
	local queued = {}
	for k, v in pairs(res) do queued[k] = v end -- order-free: a shallow copy
	queued.chest = nil
	app.push_reward(queued)
	log("level_win", {
		level = res.level_id, attempt = run.attempt, moves_left = core_result.moves_at_win or 0,
		stars = res.stars, coins = res.coins, streak = res.streak, seconds = seconds(ctx),
	})
	return res
end

function M.lose(core_result, ctx)
	core_result = core_result or {}
	local meta = app.meta
	local run = meta and meta:run() or nil
	if not run then return standalone(false, core_result, ctx) end
	-- the core only loses after moves were made; the meta needs to have been told
	if not run.moved then pcall(meta.note_move, meta) end
	local ok, res = pcall(meta.finish_level, meta, { won = false, level_id = run.level_id }, app.now())
	if not ok or not res then
		print("WARNING: level_end: finish_level (loss) failed: " .. tostring(res))
		return nil, tostring(res)
	end
	local back = refund(meta, core_result.unplaced, run)
	if back then res.refund = back end
	app.commit("level_lose")
	log("level_fail", {
		level = res.level_id, attempt = run.attempt, reason = res.reason, life_lost = res.life_lost,
		streak_lost = res.streak_lost, fails = res.fails, seconds = seconds(ctx),
	})
	return res
end

-- Pause -> leave. Before the first move the attempt is dropped (the boosters come back); after it, it
-- is a loss that the town shows. Returns {kind = "none" | "cancelled" | "loss", res}.
function M.quit(ctx)
	local meta = app.meta
	local run = meta and meta:run() or nil
	if not run then return { kind = "none" } end
	if not run.moved then
		local ok, why = pcall(meta.cancel_level, meta)
		app.commit("level_quit")
		if not ok then print("WARNING: level_end: cancel_level failed: " .. tostring(why)) end
		log("level_cancel", { level = run.level_id })
		return { kind = "cancelled" }
	end
	local ok, res = pcall(meta.finish_level, meta, { won = false, level_id = run.level_id, quit_after_first_move = true }, app.now())
	app.commit("level_quit")
	if not ok or not res then
		print("WARNING: level_end: finish_level (quit) failed: " .. tostring(res))
		return { kind = "none" }
	end
	app.push_reward(res)
	log("level_fail", {
		level = res.level_id, attempt = run.attempt, reason = res.reason, life_lost = res.life_lost,
		streak_lost = res.streak_lost, fails = res.fails, seconds = seconds(ctx),
	})
	return { kind = "loss", res = res }
end

-- "+5 moves" for coins, offer number k as the player saw it. Returns {k, price, moves, riff} for the
-- core's continue command, or nil and the meta's reason ("not_enough_coins", "stale_offer", ...).
function M.continue(k, ctx)
	local meta = app.meta
	if not meta or not meta:run() then return nil, "no_run" end
	local ok, res, why = pcall(meta.buy_continue, meta, k)
	app.commit("continue")
	if not ok then
		print("WARNING: level_end: buy_continue failed: " .. tostring(res))
		return nil, "error"
	end
	if not res then return nil, why end
	log("continue_buy", { level = ctx and ctx.level_id or 0, k = res.k, price = res.price })
	return res
end

-- "+3 moves" for a rewarded video: cb(res {moves} | nil, why).
function M.ad_moves(ctx, cb)
	local meta = app.meta
	if not meta or not meta:run() then return cb(nil, "no_run") end
	if not ads.can_show("continue") then return cb(nil, "unavailable") end
	ads.show_rewarded("continue", function(ok, reason)
		if not ok then return cb(nil, reason or "unavailable") end
		local res, why = meta:grant_ad_moves()
		app.commit("ad_moves")
		if not res then return cb(nil, why) end
		cb(res)
	end)
end

function M.offer_shown(offer, ctx)
	if not offer or offer.free then return end
	log("continue_offer", { level = ctx and ctx.level_id or 0, k = offer.k, price = offer.price, affordable = offer.affordable })
end

function M.first_move(ctx)
	log("first_move", { level = ctx and ctx.level_id or 0, seconds = seconds(ctx) })
end

function M.booster_used(ctx, id)
	log("booster_use", { level = ctx and ctx.level_id or 0, id = id, kind = "in" })
end

return M
