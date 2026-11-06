-- Accounts and the cloud save (service interface). The game never talks to a provider directly: it calls this
-- module, which forwards to the provider in use. Providers:
--   * the default one: "unavailable" (no configuration; the game is a guest game and says so honestly);
--   * client/services/auth_mock.lua: an in-memory server for tests (sign-in, accounts, per-account cloud save);
--   * client/services/auth_web.lua: the browser bridge to web/glow_auth.js (Firebase Auth + Firestore), used when
--     web/auth_config.js holds the public project identifiers.
-- Passwords never pass through Lua: the web provider shows the browser's own form (an <input type=password>)
-- and gives the password straight to the provider's SDK. The game stores no password and no token.
--
--   local auth = require("client.services.auth")
--   auth.available()                          -- a provider with a configured project is in use
--   auth.restore(function(ok, reason, user) end)           -- a session from an earlier run
--   auth.sign_in_google(cb)                   auth.password_form("login" | "register", labels, cb)
--   auth.link_google(cb)                      auth.link_email_form(labels, cb)
--   auth.refresh(cb)                          auth.sign_out(cb)        auth.delete_account(cb)
--   auth.cloud_get(function(ok, reason, doc) end)    -- doc = {code, previous} or nil: no cloud save yet
--   auth.cloud_put(code, previous_code, cb)          auth.cloud_delete(cb)
-- Every callback gets (ok, reason, data). Reasons (stable ids, texts are in client/i18n.lua "auth.err_*"):
--   unavailable, busy, offline, timeout, cancelled, popup_blocked, bad_credentials, id_taken, email_in_use,
--   weak_password, bad_id, bad_email, need_recent_login, already_linked, too_many, not_enabled, bad_domain,
--   denied, no_user, error.
-- user = {uid, kind = "google" | "password", id (login id of an ID account), email, email_verified,
--         google_linked, pending_email, name}
-- Bus: "auth_changed" {signed_in, uid} after the signed-in user changed.

local bus = require("client.bus")

local M = {}

M.ID_DOMAIN = "id.glow.invalid"
M.ID_MIN, M.ID_MAX = 3, 20
M.PASSWORD_MIN, M.PASSWORD_MAX = 8, 128

-- login ids -------------------------------------------------------------------------------------------

-- "  Anna_7 " -> "anna_7"
function M.normalize_id(s)
	if type(s) ~= "string" then return "" end
	local t = s:gsub("^%s+", "")
	t = t:gsub("%s+$", "")
	return t:lower()
end

-- 3-20 characters: a-z, 0-9, "_"; the first one is a letter.
function M.valid_id(id)
	if type(id) ~= "string" or #id < M.ID_MIN or #id > M.ID_MAX then return false end
	return id:match("^[a-z][a-z0-9_]*$") ~= nil
end

-- The e-mail address an ID account has inside the provider. ".invalid" is reserved (RFC 2606): it can never
-- receive mail, so no real person can be reached or spoofed through it.
function M.synthetic_email(id)
	return id .. "@" .. M.ID_DOMAIN
end

function M.is_synthetic(email)
	return type(email) == "string" and email:sub(-#M.ID_DOMAIN - 1) == "@" .. M.ID_DOMAIN
end

function M.valid_password(p)
	return type(p) == "string" and #p >= M.PASSWORD_MIN and #p <= M.PASSWORD_MAX
end

-- Short text for "who is signed in": the ID, the e-mail or the name.
function M.label(user)
	if not user then return nil end
	if user.id and user.id ~= "" then return user.id end
	if user.email and user.email ~= "" and not M.is_synthetic(user.email) then return user.email end
	return user.name or user.uid
end

-- True when the account can recover a forgotten password: it has a real, verified e-mail.
function M.can_recover(user)
	return user ~= nil and user.email ~= nil and not M.is_synthetic(user.email) and user.email_verified == true
end

-- provider --------------------------------------------------------------------------------------------

local UNAVAILABLE = { name = "unavailable" }
function UNAVAILABLE.available() return false end

local state = { provider = UNAVAILABLE, user = nil, busy = false }

function M.set_provider(p)
	state.provider = p or UNAVAILABLE
	state.user, state.busy = nil, false
end

function M.provider() return state.provider end
function M.available() return state.provider.available() == true end
function M.user() return state.user end
function M.busy() return state.busy end

local function set_user(user)
	local before = state.user and state.user.uid
	state.user = user
	local after = user and user.uid
	if before ~= after then bus.publish("auth_changed", { signed_in = user ~= nil, uid = after }) end
end

local function done(cb, ...)
	if cb then
		local ok, err = pcall(cb, ...)
		if not ok then print("WARNING: auth: callback failed: " .. tostring(err)) end
	end
end

-- Runs provider[op](args..., cb'). `kind`: "user" (the result is the signed-in user), "gone" (success signs
-- the user out), "quiet" (a data call: no busy guard, no user change). The interactive calls share one guard:
-- a second tap while a sign-in popup is open answers "busy".
local function call(op, kind, cb, ...)
	local p = state.provider
	if not p.available() or not p[op] then return done(cb, false, "unavailable") end
	local guard = kind ~= "quiet"
	if guard and state.busy then return done(cb, false, "busy") end
	if guard then state.busy = true end
	local args, n = { ... }, select("#", ...)
	args[n + 1] = function(ok, reason, data)
		if guard then state.busy = false end
		if ok then
			if kind == "user" then set_user(data) elseif kind == "gone" then set_user(nil) end
		end
		done(cb, ok, reason, data)
	end
	local fine, err = pcall(p[op], unpack(args, 1, n + 1))
	if not fine then
		if guard then state.busy = false end
		print("WARNING: auth: " .. op .. " failed: " .. tostring(err))
		return done(cb, false, "error")
	end
end

function M.restore(cb) return call("restore", "user", cb) end
function M.sign_in_google(cb) return call("sign_in_google", "user", cb) end
function M.password_form(mode, labels, cb) return call("password_form", "user", cb, mode, labels or {}) end
function M.link_google(cb) return call("link_google", "user", cb) end
function M.link_email_form(labels, cb) return call("link_email_form", "user", cb, labels or {}) end
function M.refresh(cb) return call("refresh", "user", cb) end
function M.sign_out(cb) return call("sign_out", "gone", cb) end
function M.delete_account(cb) return call("delete_account", "gone", cb) end

-- The cloud calls do not take the busy guard (a background sync must not block a sign-in form, nor the other
-- way round): the provider keeps its own queue.
function M.cloud_get(cb) return call("cloud_get", "quiet", cb) end
function M.cloud_put(code, previous, cb) return call("cloud_put", "quiet", cb, code, previous) end
function M.cloud_delete(cb) return call("cloud_delete", "quiet", cb) end

-- Called every second by main/app.script: providers with a pending reply (the browser bridge) poll here.
function M.tick(now)
	local p = state.provider
	if p.tick then p.tick(now) end
end

return M
