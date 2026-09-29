-- Rewarded ads (mock provider). Release: never available. Debug: the "video"
-- completes instantly, so the "+3 moves for an ad" flow can be tested.
-- Placements: "continue" (+3 moves, once per attempt; the meta enforces it).
--
--   local ads = require("client.services.ads")
--   ads.init({debug = platform.is_debug()})
--   if ads.can_show("continue") then ads.show_rewarded("continue", function(ok, reason) ... end) end

local analytics = require("client.services.analytics")

local M = {}

M.PLACEMENTS = { continue = true }

local state = { debug = false }

function M.init(opts)
	opts = opts or {}
	state.debug = opts.debug and true or false
end

-- Pure check, safe to call every frame.
function M.can_show(placement)
	return state.debug and M.PLACEMENTS[placement] == true
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
