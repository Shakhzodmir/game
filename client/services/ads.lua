-- Rewarded ads (mock provider). Release: never available. Debug: the "video"
-- completes instantly, so the "+3 moves for an ad" flow can be tested.
-- Placements: "continue" (+3 moves, once per attempt; the meta enforces it),
-- "shop_gift" (the free gift of the shop: M.REWARDS.shop_gift through
-- meta:grant, at most once per M.GIFT_COOLDOWN seconds of this session).
--
--   local ads = require("client.services.ads")
--   ads.init({debug = platform.is_debug()})
--   if ads.can_show("continue") then ads.show_rewarded("continue", function(ok, reason) ... end) end

local analytics = require("client.services.analytics")

local M = {}

M.PLACEMENTS = { continue = true, shop_gift = true }

-- Rewards of placements that pay outside the level rules (meta:grant).
M.REWARDS = { shop_gift = { coins = 100 } }
M.GIFT_COOLDOWN = 60

local state = { debug = false, rewarded = {} } -- rewarded: placement -> app time of its last reward

function M.init(opts)
	opts = opts or {}
	state.debug = opts.debug and true or false
	state.rewarded = {} -- a new session: every cooldown starts fresh
end

-- Pure check, safe to call every frame.
function M.can_show(placement)
	return state.debug and M.PLACEMENTS[placement] == true
end

-- The shop gift can be taken once per M.GIFT_COOLDOWN seconds of the session: mark_rewarded(placement, now)
-- when it paid, cooldown_left(placement, now) = seconds until it pays again (0: now).
function M.mark_rewarded(placement, now)
	state.rewarded[placement] = now
end

function M.cooldown_left(placement, now)
	local at = state.rewarded[placement]
	if placement ~= "shop_gift" or not at then return 0 end
	return math.max(0, M.GIFT_COOLDOWN - (now - at))
end

-- Call once when the offer is actually shown to the player (analytics).
function M.offer_shown(placement)
	analytics.log("ad_offer", { placement = placement, available = M.can_show(placement) })
end

-- cb(ok, reason): ok = true when the player watched to the end and earned the
-- reward. Reasons: "unavailable", "unknown_placement".
function M.show_rewarded(placement, cb)
	cb = cb or function() end
	if not M.PLACEMENTS[placement] then
		analytics.log("ad_watch", { placement = placement, ok = false, reason = "unknown_placement" })
		return cb(false, "unknown_placement")
	end
	if not state.debug then
		analytics.log("ad_watch", { placement = placement, ok = false, reason = "unavailable" })
		return cb(false, "unavailable")
	end
	analytics.log("ad_watch", { placement = placement, ok = true })
	return cb(true)
end

return M
