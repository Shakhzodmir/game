-- View models of the meta screens (pure Lua): plain tables built from the
-- meta API for the town, the start window, the shop, the lives window, the
-- jukebox, chests and the settings. No rule is decided here; every number
-- comes from the meta (or, for store products, from client/services/iap).
--
--   local views = require("client.views")
--   views.booster_icon("riff")               --> "specials/riff"
--   views.lives(meta:lives(now))             --> {state, count, max, seconds, icon}
--   views.task(meta)                         --> the next-task card | nil
--   views.level_button(meta, levels)         --> {level, tag, notes, all_done}
--   views.start(meta, n, info, now, levels, free_up_to) --> the start window of level n
--   views.start_boosters(meta, level)        --> the three pre-level slots
--   views.shop_boosters(meta)                --> every booster pack
--   views.shop_products(products, available) --> coin packs of the store
--   views.refill(meta, now)                  --> the refill button
--   views.jukebox(meta)                      --> one row per district
--   views.chest_items(chest)                 --> what a chest holds, in reveal order
--   views.gift(id, config)                   --> an unlock gift
--   views.settings(meta)                     --> the settings window

local M = {}

M.PRE = { "riff", "sub", "disco" } -- pre-level boosters, start window order

-- Booster art: in-level boosters have UI icons, pre-level ones are the
-- special pieces they put on the board.
M.BOOSTER_ICON = {
	stick = "ui/icons/stick",
	row_light = "ui/icons/row_light",
	col_light = "ui/icons/col_light",
	remix = "ui/icons/remix",
	riff = "specials/riff",
	sub = "specials/sub",
	disco = "specials/disco",
}

-- Accent colours of the districts (the pastel walls of the art direction).
M.DISTRICT_COLORS = { "#FF9EC7", "#C9A7FF", "#FFD36E", "#7FC8FF", "#8BE39A" }

-- Store products shown in the shop's coins tab, in display order, with
-- their i18n name keys and card colours.
M.PRODUCTS = {
	{ id = "starter_pack", name = "shop.starter_pack", color = "pink", best = true },
	{ id = "coins_small", name = "shop.coins_small", color = "gold" },
	{ id = "coins_medium", name = "shop.coins_medium", color = "gold" },
	{ id = "coins_large", name = "shop.coins_large", color = "gold" },
	{ id = "piggy_bank", name = "shop.piggy_bank", color = "purple" },
}

function M.booster_icon(id)
	return M.BOOSTER_ICON[id] or "ui/icons/gift"
end

function M.district_color(index)
	local c = M.DISTRICT_COLORS
	return c[((tonumber(index) or 1) - 1) % #c + 1]
end

-- Lives for the top bar and the lives window.
-- state: "infinite" (seconds = infinite time left), "full", "regen"
-- (seconds = time to the next life), "empty" (regen with no life left).
function M.lives(l)
	local out = { count = l.count, max = l.max, icon = "ui/icons/heart" }
	if (l.infinite_seconds or 0) > 0 then
		out.state, out.seconds, out.icon = "infinite", l.infinite_seconds, "ui/icons/heart_infinite"
	elseif l.count >= l.max then
		out.state, out.seconds = "full", 0
	else
		out.state, out.seconds = l.count == 0 and "empty" or "regen", l.next_in_seconds or 0
	end
	return out
end

-- The next task card: {district, id, name, cost, stem, affordable, need,
-- image} or nil when the town is complete.
function M.task(meta)
	local t = meta:next_task()
	if not t then return nil end
	local need = math.max(0, t.cost - meta:stars())
	return {
		district = t.district, id = t.id, name = t.name, cost = t.cost, stem = t.stem,
		affordable = t.affordable, need = need,
		image = "districts/" .. t.district .. "/" .. t.id,
	}
end

-- The green "Level N" button: {level, difficulty, tag (i18n key or nil),
-- notes = {{lit, booster, unlocked}} (the hit streak), streak_active,
-- all_done}. levels = client/levels.lua (or anything with difficulty(n)
-- and tag(difficulty)).
function M.level_button(meta, levels)
	local n = meta:level_to_play()
	local streak = meta:streak()
	local notes = {}
	for i, s in ipairs(streak.slots or {}) do
		notes[i] = { lit = s.lit and true or false, booster = s.booster, unlocked = s.unlocked and true or false }
	end
	if not n then
		return { all_done = true, notes = notes, streak_active = streak.active }
	end
	local diff = levels and levels.difficulty(n) or nil
	return {
		level = n, difficulty = diff, tag = levels and levels.tag(diff) or nil,
		notes = notes, streak = streak.count, streak_active = streak.active, all_done = false,
	}
end

local function inventory_by_id(meta)
	local out = {}
	for _, b in ipairs(meta:inventory()) do out[b.id] = b end
	return out
end

-- The pre-level booster slots of the start window for `level`:
-- {id, icon, count, unlocked, unlock_level, free (the hit streak puts one
-- on the board for free), selectable (unlocked with at least one in stock)}.
function M.start_boosters(meta, level)
	local inv = inventory_by_id(meta)
	local free = {}
	local streak = meta:streak()
	if level == meta:level_to_play() then
		for _, id in ipairs(streak.boosters or {}) do free[id] = true end
	end
	local out = {}
	for i, id in ipairs(M.PRE) do
		local b = inv[id] or { count = 0, unlocked = false, unlock_level = 0 }
		out[i] = {
			id = id, icon = M.booster_icon(id), count = b.count or 0,
			unlocked = b.unlocked and true or false, unlock_level = b.unlock_level,
			free = free[id] or false,
			selectable = (b.unlocked and (b.count or 0) > 0 and not free[id]) and true or false,
		}
	end
	return out
end

-- The ids picked in the start window that the meta will accept: selectable
-- ones, each once, in slot order.
function M.picked(slots, selected)
	local out = {}
	for _, s in ipairs(slots) do
		if selected[s.id] and s.selectable then out[#out + 1] = s.id end
	end
	return out
end

-- The start window of level n. info = client/levels.lua load(n) (nil when
-- the file is missing); free_up_to = app.free_levels(). {level, difficulty,
-- tag, goals, moves, boosters, streak = {count, active, notes}, infinite,
-- lives, life_cost (a loss would cost a life), can_start, why (the meta's
-- refusal: "no_lives", "run_active", ...)}.
function M.start(meta, n, info, now, levels, free_up_to)
	local ok, why = meta:can_start(n, now)
	local l = meta:lives(now)
	local diff = info and info.difficulty or nil
	local streak = meta:streak()
	local notes = {}
	for i, s in ipairs(streak.slots or {}) do
		notes[i] = { lit = s.lit and true or false, booster = s.booster, unlocked = s.unlocked and true or false }
	end
	return {
		level = n,
		difficulty = diff,
		tag = levels and levels.tag(diff) or nil,
		goals = info and info.goals or {},
		moves = info and info.moves or nil,
		boosters = M.start_boosters(meta, n),
		streak = { count = streak.count, active = streak.active, notes = notes },
		infinite = (l.infinite_seconds or 0) > 0,
		lives = l.count,
		life_cost = (free_up_to == nil or n > free_up_to) and (l.infinite_seconds or 0) <= 0,
		can_start = ok and true or false,
		why = why,
	}
end

-- Every booster pack of the shop: {id, icon, kind, count, unlocked,
-- unlock_level, price, size, affordable}.
function M.shop_boosters(meta)
	local coins = meta:coins()
	local out = {}
	for i, b in ipairs(meta:inventory()) do
		out[i] = {
			id = b.id, icon = M.booster_icon(b.id), kind = b.kind, count = b.count,
			unlocked = b.unlocked, unlock_level = b.unlock_level,
			price = b.pack_price, size = b.pack_size, affordable = coins >= b.pack_price,
		}
	end
	return out
end

-- Coin packs of the store for the shop: {id, name (i18n key), price (store
-- text), coins, boosters = {{id, count}}, infinite_minutes, color, best,
-- available}. products = client/services/iap.lua PRODUCTS; available = can
-- the store sell now (false in the web demo).
function M.shop_products(products, available)
	local by_id = {}
	for _, p in ipairs(products or {}) do by_id[p.id] = p end
	local out = {}
	for _, d in ipairs(M.PRODUCTS) do
		local p = by_id[d.id]
		if p then
			local r = p.reward or {}
			local boosters = {}
			for _, id in ipairs({ "stick", "row_light", "col_light", "remix", "riff", "sub", "disco" }) do
				local c = r.boosters and r.boosters[id]
				if c and c > 0 then boosters[#boosters + 1] = { id = id, count = c, icon = M.booster_icon(id) } end
			end
			out[#out + 1] = {
				id = p.id, name = d.name, price = p.price, coins = r.coins or 0, boosters = boosters,
				infinite_minutes = r.infinite_minutes or 0, color = d.color, best = d.best or false,
				available = available and true or false,
			}
		end
	end
	return out
end

-- The refill button (lives window, shop): {price, available, affordable,
-- reason, state} straight from meta:refill_offer.
function M.refill(meta, now)
	local o = meta:refill_offer(now)
	return { price = o.price, available = o.available, affordable = o.affordable, reason = o.reason }
end

-- The jukebox list: {id, index, name, color, state, done, total, stems,
-- prev_name, bpm}. state: "complete" (the full song: every stem + party),
-- "current" (the stems built so far), "locked" (not open yet).
function M.jukebox(meta, districts_by_id)
	local out = {}
	local list = meta:districts()
	for i, d in ipairs(list) do
		local state
		if d.complete then
			state = "complete"
		elseif d.available then
			state = "current"
		else
			state = "locked"
		end
		local data = districts_by_id and districts_by_id[d.id] or nil
		out[i] = {
			id = d.id, index = d.index, name = d.name, color = M.district_color(d.index),
			state = state, done = d.done, total = d.total, stems = #d.unmuted,
			prev_name = list[i - 1] and list[i - 1].name or nil,
			bpm = data and data.bpm or nil,
			playable = state == "complete" or (state == "current" and #d.unmuted > 0),
		}
	end
	return out
end

-- "k/n layers" of the district being built (or the last one).
function M.progress(meta, district_id)
	local d = meta:district(district_id)
	return { done = d.done, total = d.total, complete = d.complete, name = d.name, index = d.index }
end

-- What a chest holds, in reveal order: {{kind = "coins"|"booster"|"infinite",
-- image, amount, id?}}. chest = {coins, boosters = {ids}, infinite_minutes}
-- (a level chest from finish_level, a district chest from complete_task).
-- Boosters of the same id are counted together.
function M.chest_items(chest)
	local out = {}
	if type(chest) ~= "table" then return out end
	if (chest.coins or 0) > 0 then
		out[#out + 1] = { kind = "coins", image = "ui/icons/coin", amount = chest.coins }
	end
	local seen = {}
	for _, id in ipairs(chest.boosters or {}) do
		if seen[id] then
			seen[id].amount = seen[id].amount + 1
		else
			local e = { kind = "booster", id = id, image = M.booster_icon(id), amount = 1 }
			seen[id] = e
			out[#out + 1] = e
		end
	end
	if (chest.infinite_minutes or 0) > 0 then
		out[#out + 1] = { kind = "infinite", image = "ui/icons/heart_infinite", amount = chest.infinite_minutes }
	end
	return out
end

-- An unlock gift: {id, icon, count (the gift size from the config), kind}.
-- config = meta/config.lua (read for display only).
function M.gift(id, config)
	local count, kind = 0, nil
	for _, b in ipairs(config and config.boosters or {}) do
		if b.id == id then count, kind = b.gift, b.kind end
	end
	return { id = id, icon = M.booster_icon(id), count = count, kind = kind }
end

-- The settings window: the meta settings plus the choices to show.
function M.settings(meta)
	local s = meta:settings()
	return {
		music = s.music, sfx = s.sfx, haptics = s.haptics and true or false,
		reduced_motion = s.reduced_motion and true or false,
		input_mode = s.input_mode, language = s.language,
		input_modes = { "swipe", "taptap" }, languages = { "auto", "en", "ru" },
	}
end

return M
