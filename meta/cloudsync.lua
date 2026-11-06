-- Cloud sync rules (WP-10): what to do when the save on this device and the save in the player's account
-- meet. Pure and deterministic: no clock, no network, no UI. The conflict is settled by progress, never by
-- time: a save with less progress never replaces one with more without the player's explicit word, and
-- whatever loses is kept (the "previous" slot on the device, the "previous" field in the cloud).
--
--   local a = cloudsync.summarize(meta:serialize(), districts)    -- {beaten, coins, stars, wins, salt, checksum}
--   local plan = cloudsync.plan(a, b, "same")                     -- b = cloud summary or nil
--   plan.action: "none" | "upload" | "offer_upload" | "offer_download" | "choose" | "foreign"
--
-- Progress order (same player = same salt): save x is ahead of y when it has at least as many levels beaten,
-- stars and wins and more of one of them. Mixed (more levels, fewer stars) or different salts (two games
-- started independently) are separate branches: the player chooses and sees both summaries.

local save = require("meta.save")
local town = require("meta.town")

local M = {}

-- Save table -> {beaten, coins, stars, wins, salt, checksum}; nil and a reason for a table that is no save.
function M.summarize(tbl, districts)
	if type(tbl) ~= "table" then return nil, "missing" end
	local state, info = save.load(tbl, nil, town.validate(districts))
	if not state then return nil, (info.errors and info.errors.current) or "bad_save" end
	return {
		beaten = state.progress.beaten,
		coins = state.wallet.coins,
		stars = state.wallet.stars,
		wins = state.stats.wins,
		salt = state.salt,
		checksum = tbl.checksum,
	}
end

local function empty(s)
	return s.beaten == 0 and s.wins == 0
end

-- Progress of save a against save b: "equal" | "a" (a is ahead) | "b" | "branch" (neither is ahead).
function M.compare(a, b)
	if a.salt ~= b.salt then
		if empty(a) and empty(b) then return "equal" end
		if empty(a) then return "b" end -- a fresh game is no branch: it has nothing to lose
		if empty(b) then return "a" end
		return "branch"
	end
	local ge_a = a.beaten >= b.beaten and a.stars >= b.stars and a.wins >= b.wins
	local ge_b = b.beaten >= a.beaten and b.stars >= a.stars and b.wins >= a.wins
	if ge_a and ge_b then return "equal" end
	if ge_a then return "a" end
	if ge_b then return "b" end
	return "branch"
end

-- Which save the player is advised to keep when the branches differ: the one further along, or nil.
local function recommend(loc, cloud)
	if loc.beaten ~= cloud.beaten then return loc.beaten > cloud.beaten and "local" or "cloud" end
	if loc.stars ~= cloud.stars then return loc.stars > cloud.stars and "local" or "cloud" end
	if loc.wins ~= cloud.wins then return loc.wins > cloud.wins and "local" or "cloud" end
	return nil
end
M.recommend = recommend

-- loc: summary of the save on this device; cloud: summary of the account's save, or nil (nothing there);
-- bound: how the device save relates to the account signing in:
--   "same"  it was synced with this account before        "none"  it was never tied to an account (guest play)
--   "other" it belongs to another account (signed out of it on this device)
-- Returns {action, recommend?}. An "other" device save is never uploaded to this account without the
-- player's choice and never mixed with the account's own.
function M.plan(loc, cloud, bound)
	bound = bound or "none"
	if bound == "other" then return { action = "foreign", has_cloud = cloud ~= nil } end
	if not cloud then
		if empty(loc) and bound == "none" then return { action = "none" } end -- nothing worth a copy yet
		return { action = "upload" }
	end
	local c = M.compare(loc, cloud)
	if c == "equal" then
		if loc.checksum ~= cloud.checksum then return { action = "upload", quiet = true } end -- same progress, other details
		return { action = "none" }
	end
	if c == "a" then return { action = "offer_upload" } end
	if c == "b" then return { action = "offer_download" } end
	return { action = "choose", recommend = recommend(loc, cloud) }
end

-- The same check for a background upload of a device save that was in sync before: only an upload that
-- cannot lose the cloud's progress goes through silently. Returns "upload" | "none" | "conflict".
function M.background(loc, cloud)
	if not cloud then return "upload" end
	local c = M.compare(loc, cloud)
	if c == "equal" then return loc.checksum ~= cloud.checksum and "upload" or "none" end
	if c == "a" then return "upload" end
	return "conflict"
end

return M
