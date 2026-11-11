-- The actions of the chart and band windows (WP-11): they call the social service (client/services/social.lua),
-- read the player's numbers from the meta and tell the result. No GUI calls here: the windows only draw.
--
--   social.prepare(cb)       cb(stage, profile): "unavailable" | "signin" | "offline" | "error" | "setup" (the player has
--                            no game name yet) | "ready"; on "ready" the numbers of this device were reported
--   social.save_profile(name, avatar, cb)
--   social.claim_help(cb)    lives sent by band mates go into the meta
--   social.name_text(name)   the game name in the current language ("Bright Beat 42")

local app = require("client.app")
local i18n = require("client.i18n")
local config = require("meta.config")
local rules = require("meta.social")
local service = require("client.services.social")

local M = {}

M.REPORT_EVERY = 60 -- seconds between two reports of the same device (a window opened again does not repeat it)

local S = { profile = nil, reported_at = nil, uid = nil }

function M.reset() S = { profile = nil, reported_at = nil, uid = nil } end

function M.profile() return S.profile end

-- names -----------------------------------------------------------------------------------------------

function M.name_text(name)
	if type(name) ~= "table" or not name.a then return "?" end
	local s = i18n.t("social.adj." .. name.a) .. " " .. i18n.t("social.noun." .. name.n)
	if name.d then s = s .. " " .. name.d end
	return s
end

-- the numbers of this device ----------------------------------------------------------------------------

-- Stars the player has won (best of every level), the level reached, super stars, the district being built.
function M.claim()
	local meta = app.meta
	local flow = require("client.flow")
	local ltp = meta:level_to_play()
	local reached = (ltp or config.levels.count + 1) - 1
	local total = 0
	for n = 1, reached do
		total = total + meta:level_stars(n, flow.level_ref(n).difficulty)
	end
	local district = 1
	local cur = meta:current_district()
	for i, d in ipairs(app.district_list or {}) do
		if d.id == (cur or (app.focus_district and app.focus_district())) then district = i end
	end
	-- the badge shows the position of the district in the town: 1..number of districts (a build with more districts
	-- has a longer range; the server accepts any whole number from 1)
	local districts = #(app.district_list or {})
	return { total = total, level = reached, super = meta:super_stars().earned,
		district = math.max(1, math.min(districts > 0 and districts or 5, district)) }
end

-- flow -------------------------------------------------------------------------------------------------

local function stage_of(reason)
	if reason == "signin" or reason == "unavailable" then return reason end
	if reason == "offline" or reason == "timeout" then return "offline" end
	return "error"
end

local function report(cb)
	local now = app.now()
	if S.reported_at and now - S.reported_at < M.REPORT_EVERY and now >= S.reported_at then return cb("ready", S.profile) end
	service.report(M.claim(), function(ok, reason)
		if not ok then return cb(stage_of(reason), S.profile, reason) end
		S.reported_at = now
		cb("ready", S.profile)
	end)
end

function M.prepare(cb)
	local st = service.state()
	if st ~= "ready" then return cb(st) end
	local uid = require("client.services.auth").user().uid
	if S.uid ~= uid then M.reset(); S.uid = uid end
	if S.profile then return report(cb) end
	service.profile_get(function(ok, reason, data)
		if not ok then return cb(stage_of(reason), nil, reason) end
		if not data then return cb("setup") end
		S.profile = data
		report(cb)
	end)
end

function M.save_profile(name, avatar, cb)
	service.profile_set(name, avatar, function(ok, reason, data)
		if ok then
			S.profile = { name = data and data.name or name, avatar = avatar }
			S.reported_at = nil
		end
		cb(ok, reason)
	end)
end

-- Lives band mates sent: up to the maximum, the rest waits on the server. cb(ok, added).
function M.claim_help(cb)
	service.help_claim(function(ok, reason, data)
		if not ok then return cb(false, reason) end
		local added = 0
		if data and data.lives > 0 then
			added = app.meta:gift_lives(data.lives, app.now())
			app.commit("band_lives")
			if added > 0 then app.toast_key("band.lives_got", { n = added }, { color = "gold" }) end
		end
		cb(true, added, data)
	end)
end

-- Seconds to the end of the week -> "3d 4h" / "5h 20m" in the current language.
function M.left_text(seconds)
	seconds = math.max(0, math.floor(seconds))
	local d, h, m = math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600), math.floor(seconds % 3600 / 60)
	if d > 0 then return i18n.t("social.left_dh", { d = d, h = h }) end
	return i18n.t("social.left_hm", { h = h, m = m })
end

return M
