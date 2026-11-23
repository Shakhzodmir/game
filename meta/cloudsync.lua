-- Cloud sync rules (WP-10): what to do when the save on this device and the save in the player's account
-- meet. Pure and deterministic: no clock, no network, no UI. The conflict is settled by progress, never by
-- time: a save with less progress never replaces one with more without the player's explicit word, and
-- whatever loses is kept (the "previous" slot on the device, the "previous" field in the cloud).
--
--   local a = cloudsync.summarize(meta:serialize(), districts)    -- {beaten, coins, stars, earned, tasks, unknown_tasks, wins, salt, checksum}
--   local plan = cloudsync.plan(a, b, "same")                     -- b = cloud summary or nil
--   plan.action: "none" | "upload" | "offer_upload" | "offer_download" | "choose" | "foreign"
--
-- Progress order (same player = same salt): save x is ahead of y when it has at least as many levels beaten,
-- stars EARNED, town tasks done (and tasks of districts this build does not know, below) and wins, and more of one of
-- them. Mixed (more levels, fewer tasks) or different salts (two games started independently) are separate branches.
-- The stars of the wallet are NOT a measure of progress: they are spent on town tasks. A save that bought a task has
-- fewer stars than the copy from before it, and read by the wallet it looked "behind" and was rolled back (the
-- producer's screenshot of 2026-11-20: 54 levels, 46 stars against the account's 54 levels, 50 stars). `earned`
-- (the wallet plus what the done tasks cost) never goes down, `tasks` counts the done tasks.
-- Tasks of districts this build does not know (a newer build's: the site was rolled back to this build; meta/town.lua
-- restore keeps their entries in the save as they are) count in neither of those two numbers, this build cannot price
-- them: the stars they cost are missing from `earned`, so the same player's save from before those purchases would
-- read as level with the save that has them, or even ahead of it (a quiet upload over the purchases). They have a
-- number of their own, `unknown_tasks` (the ids in the done lists of the kept entries, meta/town.lua unknown_done):
-- a save is ahead only with at least as many of them, and where the levels are level the one with more of them is
-- the one advised (before `earned`). The levels still decide first: a save with more levels beaten is advised
-- whatever the other holds. A write of this build never drops the entries: the quiet upload that follows a change
-- (same progress, other checksum) is a save that still holds them, and what a save replaces stays in the "previous"
-- slot and field (tests/meta/town_keep_test.lua, tests/client/cloud_test.lua).

local save = require("meta.save")
local town = require("meta.town")

local M = {}

-- Save table -> {beaten, coins, stars (the wallet, for display), earned, tasks, unknown_tasks, wins, salt, checksum};
-- nil and a reason for a table that is no save.
function M.summarize(tbl, districts)
	if type(tbl) ~= "table" then return nil, "missing" end
	local data = town.validate(districts)
	local state, info = save.load(tbl, nil, data)
	if not state then return nil, (info.errors and info.errors.current) or "bad_save" end
	local spent, tasks = 0, 0
	for _, d in ipairs(data.list) do
		for _, task in ipairs(d.tasks) do
			if town.is_done(state.town, d, task) then
				spent = spent + task.cost
				tasks = tasks + 1
			end
		end
	end
	return {
		beaten = state.progress.beaten,
		coins = state.wallet.coins,
		stars = state.wallet.stars,
		earned = state.wallet.stars + spent,
		tasks = tasks,
		unknown_tasks = town.unknown_done(state.town, data),
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
	local ea, eb = a.earned or a.stars, b.earned or b.stars -- a summary without `earned` (written by hand) counts its stars
	local ta, tb = a.tasks or 0, b.tasks or 0
	local ua, ub = a.unknown_tasks or 0, b.unknown_tasks or 0
	local ge_a = a.beaten >= b.beaten and ea >= eb and ta >= tb and ua >= ub and a.wins >= b.wins
	local ge_b = b.beaten >= a.beaten and eb >= ea and tb >= ta and ub >= ua and b.wins >= a.wins
	if ge_a and ge_b then return "equal" end
	if ge_a then return "a" end
	if ge_b then return "b" end
	return "branch"
end

-- Which save the player is advised to keep when the branches differ: the one further along, or nil.
local function recommend(loc, cloud)
	local el, ec = loc.earned or loc.stars, cloud.earned or cloud.stars
	if loc.beaten ~= cloud.beaten then return loc.beaten > cloud.beaten and "local" or "cloud" end
	local ul, uc = loc.unknown_tasks or 0, cloud.unknown_tasks or 0 -- before `earned`: it misses what they cost
	if ul ~= uc then return ul > uc and "local" or "cloud" end
	if el ~= ec then return el > ec and "local" or "cloud" end
	if (loc.tasks or 0) ~= (cloud.tasks or 0) then return (loc.tasks or 0) > (cloud.tasks or 0) and "local" or "cloud" end
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
