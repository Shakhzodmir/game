-- The chart and the bands (service interface, WP-11). The game never talks to a backend directly: it calls this
-- module, which forwards to the provider in use. Providers:
--   * the default one: "unavailable" (no server connected: the windows say so honestly);
--   * client/services/social_mock.lua: an in-memory server with the full rules, for tests and QA;
--   * the real backend (Firestore, same project as the cloud save, WP-10) goes here with the same functions:
--     docs/handoff/WP-11.md, "Что включить в провайдере".
-- A player is identified by the account of client/services/auth.lua (nobody signed in = no chart, no band).
-- Only a game name ({a, n, d} of fixed word lists), an avatar number, the district number and star counters ever
-- leave the device: meta/social.lua. A provider is a table of methods: provider:op(uid, args..., cb). Every callback gets (ok, reason, data).
--
--   social.available()      a provider is connected
--   social.state()          "unavailable" | "signin" | "ready"
--   social.profile_get(cb)  data = {name, avatar} | nil (no profile yet)
--   social.profile_set(name, avatar, cb)
--   social.report(claim, cb)            claim = {total, level, super, district}: the numbers of this device
--   social.chart(period, cb)            period "week" | "all" | "band"; data = {rows, me, count, pinned, week, week_end}
--                                       row = {uid, rank, name, avatar, district, stars, total, me, prev_rank?}
--   social.band_get(cb)     data = band | nil: {code, name, leader, members = {{uid, name, avatar, district, stars,
--                           role, help}}, goal, stars, week, week_end, max, you = role}
--   social.band_create(name, cb)  social.band_join(code, cb)  social.band_leave(cb)  social.band_kick(uid, cb)
--   social.help_request(cb)  social.help_send(uid, cb)  social.help_claim(cb)   -- data = {lives = n}
-- Reasons (texts in client/i18n.lua "social.err.*"): unavailable, signin, busy, offline, timeout, bad_name,
-- bad_avatar, bad_code, no_such_band, full, already_in_band, no_band, not_leader, bad_target, not_member,
-- no_profile, limit, not_requested, already_sent, denied, error.

local auth = require("client.services.auth")

local M = {}

local UNAVAILABLE = { name = "unavailable" }
function UNAVAILABLE.available() return false end

local state = { provider = UNAVAILABLE }

function M.set_provider(p) state.provider = p or UNAVAILABLE end
function M.provider() return state.provider end
function M.available() return state.provider:available() == true end

function M.state()
	if not M.available() then return "unavailable" end
	if not auth.user() then return "signin" end
	return "ready"
end

local function done(cb, ...)
	if cb then
		local ok, err = pcall(cb, ...)
		if not ok then print("WARNING: social: callback failed: " .. tostring(err)) end
	end
end

local function call(op, cb, ...)
	local st = M.state()
	if st ~= "ready" then return done(cb, false, st == "signin" and "signin" or "unavailable") end
	local p = state.provider
	if not p[op] then return done(cb, false, "unavailable") end
	local args, n = { ... }, select("#", ...)
	args[n + 1] = function(ok, reason, data) done(cb, ok, reason, data) end
	local fine, err = pcall(p[op], p, auth.user().uid, unpack(args, 1, n + 1))
	if not fine then
		print("WARNING: social: " .. op .. " failed: " .. tostring(err))
		return done(cb, false, "error")
	end
end

local social_rules = require("meta.social")

function M.profile_get(cb) return call("profile_get", cb) end

function M.profile_set(name, avatar, cb)
	if not social_rules.valid_name(name) then return done(cb, false, "bad_name") end
	if not social_rules.valid_avatar(avatar) then return done(cb, false, "bad_avatar") end
	return call("profile_set", cb, { a = name.a, n = name.n, d = name.d }, avatar)
end

function M.report(claim, cb) return call("report", cb, claim) end

function M.chart(period, cb)
	for _, p in ipairs(social_rules.PERIODS) do
		if p == period then return call("chart", cb, period) end
	end
	return done(cb, false, "error")
end

function M.band_get(cb) return call("band_get", cb) end

function M.band_create(name, cb)
	if not social_rules.valid_band_name(name) then return done(cb, false, "bad_name") end
	return call("band_create", cb, { a = name.a, n = name.n })
end

function M.band_join(code, cb)
	code = social_rules.normalize_code(code)
	if not social_rules.valid_code(code) then return done(cb, false, "bad_code") end
	return call("band_join", cb, code)
end

function M.band_leave(cb) return call("band_leave", cb) end
function M.band_kick(uid, cb) return call("band_kick", cb, uid) end
function M.help_request(cb) return call("help_request", cb) end
function M.help_send(uid, cb) return call("help_send", cb, uid) end
function M.help_claim(cb) return call("help_claim", cb) end

return M
