-- In-app purchases (mock provider). In release every purchase answers
-- "unavailable" (the web demo honestly has no store); in debug a purchase is
-- granted instantly through the meta, so the shop flow can be tested.
-- A store SDK replaces buy()/available() without touching the callers.
--
--   local iap = require("client.services.iap")
--   iap.init({debug = platform.is_debug(), grant = function(reward, tag) ... end})
--   iap.buy("coins_small", function(ok, reason, product) ... end)

local analytics = require("client.services.analytics")

local M = {}

-- Store catalogue from the plan (starter pack, coin packs, piggy bank).
-- `reward` goes to meta:grant(); stars can never be sold.
M.PRODUCTS = {
	{ id = "starter_pack", price = "$1.99", reward = { coins = 1000, boosters = { stick = 2, riff = 2, sub = 1 }, infinite_minutes = 60 } },
	{ id = "coins_small", price = "$0.99", reward = { coins = 500 } },
	{ id = "coins_medium", price = "$4.99", reward = { coins = 3000 } },
	{ id = "coins_large", price = "$9.99", reward = { coins = 7000 } },
	{ id = "piggy_bank", price = "$2.99", reward = { coins = 2500 } },
}

local by_id = {}
for _, p in ipairs(M.PRODUCTS) do by_id[p.id] = p end

local state = { debug = false, grant = nil }

-- opts: {debug = bool, grant = fn(reward, tag) -> true | false, why}
function M.init(opts)
	opts = opts or {}
	state.debug = opts.debug and true or false
	state.grant = opts.grant
end

function M.available()
	return state.debug
end

function M.product(id)
	return by_id[id]
end

-- cb(ok, reason, product). Reasons: "unavailable", "unknown_product", "grant_failed".
function M.buy(id, cb)
	cb = cb or function() end
	local p = by_id[id]
	analytics.log("iap_attempt", { product = id })
	if not p then
		analytics.log("iap_result", { product = id, ok = false, reason = "unknown_product" })
		return cb(false, "unknown_product")
	end
	if not state.debug or not state.grant then
		analytics.log("iap_result", { product = id, ok = false, reason = "unavailable" })
		return cb(false, "unavailable", p)
	end
	local ok, why = state.grant(p.reward, "iap_" .. id)
	if not ok then
		analytics.log("iap_result", { product = id, ok = false, reason = why or "grant_failed" })
		return cb(false, why or "grant_failed", p)
	end
	analytics.log("iap_result", { product = id, ok = true })
	return cb(true, nil, p)
end

return M
