-- Browser provider: talks to window.glowAuth (web/glow_auth.js: Firebase Auth + Firestore) through html5.run.
-- No JsToDef extension is needed: Lua starts an operation with glowAuth.call(id, op, args) and collects the
-- finished ones with glowAuth.poll() (auth.tick, a few times a second while something is pending).
--
-- Wire format of a finished operation, one per line of the poll answer (values percent-encoded):
--   <id>|<1 ok | 0 failed>|<reason>|key=value&key=value
-- A user is sent as uid, kind, id, email, verified (1/0), google (1/0), pending, name; a cloud document as
-- found (1/0), code, previous. Nothing secret crosses the bridge: passwords are typed into the browser's own form
-- and go straight to the provider's SDK; the bridge sees a "done" and the account's public fields.
--
-- The provider is "available" only when web/auth_config.js was filled in (glowAuth.configured). Without it the
-- game is a guest game: auth.available() is false and the UI says "sign-in is not available yet".

local platform = require("client.platform")

local M = {}

M.POLL_JS = "(window.glowAuth ? glowAuth.poll() : '')"
M.INTERACTIVE_TIMEOUT = 600 -- a sign-in popup or form may stay open for ten minutes
M.DATA_TIMEOUT = 40         -- a cloud call that takes longer is given up (the sync retries later)

local INTERACTIVE = { restore = false, sign_in_google = true, password_form = true, link_google = true,
	link_email_form = true, refresh = false, sign_out = false, delete_account = false,
	cloud_get = false, cloud_put = false, cloud_delete = false }

local function decode(s)
	s = s:gsub("%+", " ")
	return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function parse_fields(s)
	local t = {}
	for k, v in s:gmatch("([^&=]+)=([^&]*)") do t[k] = decode(v) end
	return t
end

-- "id|1|reason|k=v&k=v" -> id, ok, reason, fields
function M.parse_line(line)
	local id, ok, reason, rest = line:match("^(%d+)|([01])|([^|]*)|?(.*)$")
	if not id then return nil end
	return tonumber(id), ok == "1", reason ~= "" and reason or nil, parse_fields(rest)
end

local function user_from(f)
	if not f.uid or f.uid == "" then return nil end
	local function opt(v) if v == nil or v == "" then return nil end return v end
	return {
		uid = f.uid, kind = f.kind == "google" and "google" or "password", id = opt(f.id), email = opt(f.email),
		email_verified = f.verified == "1", google_linked = f.google == "1", pending_email = opt(f.pending), name = opt(f.name),
	}
end

-- opts: {run = fn(js) -> string | nil (default: html5.run behind pcall), now = fn() -> seconds}
function M.new(opts)
	opts = opts or {}
	local run = opts.run or function(js)
		if not platform.is_html5() then return nil end
		local ok, res = pcall(html5.run, js)
		if ok then return res end
		return nil
	end
	local now = opts.now or platform.now
	local p = { name = "web", pending = {}, count = 0, next_id = 1, configured = nil }

	function p.available()
		if p.configured == nil then
			local res = run("(window.glowAuth && glowAuth.configured) ? '1' : '0'")
			if res == nil then return false end -- the page did not answer (yet): ask again next time
			p.configured = res == "1"
		end
		return p.configured
	end

	local function start(op, args, cb)
		local id = p.next_id
		p.next_id = id + 1
		local list = {}
		for i, a in ipairs(args) do list[i] = platform.js_string(a) end
		local js = "(window.glowAuth ? glowAuth.call(" .. id .. "," .. platform.js_string(op) .. ",["
			.. table.concat(list, ",") .. "]) : 'unavailable')"
		local res = run(js)
		if res ~= "ok" then return cb(false, "unavailable") end
		local limit = INTERACTIVE[op] and M.INTERACTIVE_TIMEOUT or M.DATA_TIMEOUT
		p.pending[id] = { cb = cb, op = op, deadline = now() + limit }
		p.count = p.count + 1
	end

	local function finish(id, ok, reason, fields)
		local e = p.pending[id]
		if not e then return end -- timed out or unknown: ignore
		p.pending[id] = nil
		p.count = p.count - 1
		if not ok then return e.cb(false, reason or "error") end
		if e.op == "cloud_get" then
			if fields.found == "1" and fields.code and fields.code ~= "" then
				return e.cb(true, nil, { code = fields.code, previous = fields.previous ~= "" and fields.previous or nil })
			end
			return e.cb(true, nil, nil)
		elseif e.op == "sign_out" or e.op == "delete_account" or e.op == "cloud_put" or e.op == "cloud_delete" then
			return e.cb(true)
		end
		return e.cb(true, nil, user_from(fields)) -- restore may answer "no user": nil
	end

	function p.pending_count() return p.count end

	-- Collects what the browser finished and gives up what took too long.
	function p.tick(t)
		if p.count == 0 then return end
		local text = run(M.POLL_JS)
		if type(text) == "string" and text ~= "" then
			for line in text:gmatch("[^\n]+") do
				local id, ok, reason, fields = M.parse_line(line)
				if id then finish(id, ok, reason, fields) end
			end
		end
		t = t or now()
		local late = {}
		for id, e in pairs(p.pending) do -- order-free: collected, then sorted
			if t > e.deadline then late[#late + 1] = id end
		end
		table.sort(late)
		for _, id in ipairs(late) do
			local e = p.pending[id]
			p.pending[id] = nil
			p.count = p.count - 1
			e.cb(false, "timeout")
		end
	end

	local function labels_list(labels)
		local keys = {}
		for k in pairs(labels or {}) do keys[#keys + 1] = k end -- order-free: sorted next
		table.sort(keys)
		local out = {}
		for _, k in ipairs(keys) do
			out[#out + 1] = k
			out[#out + 1] = tostring(labels[k])
		end
		return out
	end

	function p.restore(cb) start("restore", {}, cb) end
	function p.sign_in_google(cb) start("sign_in_google", {}, cb) end
	function p.password_form(mode, labels, cb)
		local args = labels_list(labels)
		table.insert(args, 1, mode)
		start("password_form", args, cb)
	end
	function p.link_google(cb) start("link_google", {}, cb) end
	function p.link_email_form(labels, cb) start("link_email_form", labels_list(labels), cb) end
	function p.refresh(cb) start("refresh", {}, cb) end
	function p.sign_out(cb) start("sign_out", {}, cb) end
	function p.delete_account(cb) start("delete_account", {}, cb) end
	function p.cloud_get(cb) start("cloud_get", {}, cb) end
	function p.cloud_put(code, previous, cb) start("cloud_put", { code, previous or "" }, cb) end
	function p.cloud_delete(cb) start("cloud_delete", {}, cb) end

	return p
end

return M
