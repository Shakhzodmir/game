-- In-memory auth + cloud provider for tests and QA (the model of what the real backend does).
--
--   local mock = require("client.services.auth_mock").new()
--   auth.set_provider(mock)
--   mock.google_next = {sub = "g1", email = "a@gmail.com", name = "Anna"}     -- who the Google popup picks
--   mock.form_next = {id = "anna_7", password = "secret123"}                  -- what the sign-in form returns
--   mock.online = false                                                       -- every call answers "offline"
--   mock.manual = true; ...; mock.flush()                                     -- hold the replies, release them later
--
-- Rules it keeps (the same the Firebase rules and the web provider keep):
--   * a cloud save belongs to one account: a call can only reach the document of the signed-in user;
--   * e-mail and ID accounts need a unique address; ID accounts live under <id>@id.glow.invalid;
--   * passwords are compared and kept only inside this fake "server" (the game never sees them);
--   * deleting an account deletes its cloud save.

local auth = require("client.services.auth")

local M = {}

function M.new(opts)
	opts = opts or {}
	local m = {
		name = "mock",
		configured = opts.configured ~= false,
		online = true,
		manual = false,       -- hold replies until flush()
		accounts = {},        -- uid -> {uid, kind, id, email, verified, google, password, google_sub, name}
		docs = {},            -- uid -> {code, previous, puts}
		session = nil,        -- uid signed in on this "browser"
		google_next = nil,
		form_next = nil,      -- {id, password} | {email} | "cancel"
		recent = true,        -- the last sign-in is recent enough to delete the account
		mails = {},           -- verification mails "sent": {to, uid}
		calls = {},           -- op names in order
		puts = 0, gets = 0,
		pending = {},
		next_uid = 1,
	}

	local function reply(cb, ...)
		local args, n = { ... }, select("#", ...)
		if m.manual then
			m.pending[#m.pending + 1] = function() cb(unpack(args, 1, n)) end
		else
			cb(unpack(args, 1, n))
		end
	end
	function m.flush()
		local q = m.pending
		m.pending = {}
		for _, f in ipairs(q) do f() end
		return #q
	end

	local function user_of(a)
		if not a then return nil end
		return {
			uid = a.uid, kind = a.kind, id = a.id, email = a.email, email_verified = a.verified and true or false,
			google_linked = a.google_sub ~= nil, pending_email = a.pending_email, name = a.name,
		}
	end
	local function find(pred)
		local uids = {}
		for uid in pairs(m.accounts) do uids[#uids + 1] = uid end -- order-free: sorted next
		table.sort(uids)
		for _, uid in ipairs(uids) do if pred(m.accounts[uid]) then return m.accounts[uid] end end
	end
	local function new_account(fields)
		local uid = string.format("u%03d", m.next_uid)
		m.next_uid = m.next_uid + 1
		fields.uid = uid
		m.accounts[uid] = fields
		return fields
	end
	local function begin(op, cb)
		m.calls[#m.calls + 1] = op
		if not m.online then reply(cb, false, "offline"); return false end
		return true
	end
	local function me() return m.session and m.accounts[m.session] end

	function m.available() return m.configured end

	function m.restore(cb)
		m.calls[#m.calls + 1] = "restore"
		reply(cb, true, nil, user_of(me())) -- a stored session needs no network to be recognised
	end

	function m.sign_in_google(cb)
		if not begin("sign_in_google", cb) then return end
		local g = m.google_next
		m.google_next = nil
		if not g then return reply(cb, false, "cancelled") end
		local a = find(function(x) return x.google_sub == g.sub end)
		if not a then
			a = new_account({ kind = "google", google_sub = g.sub, email = g.email, verified = true, name = g.name })
		end
		m.session = a.uid
		reply(cb, true, nil, user_of(a))
	end

	function m.password_form(mode, labels, cb)
		if not begin("password_form", cb) then return end
		local f = m.form_next
		m.form_next = nil
		if f == nil or f == "cancel" then return reply(cb, false, "cancelled") end
		local id = auth.normalize_id(f.id)
		if not auth.valid_id(id) then return reply(cb, false, "bad_id") end
		if not auth.valid_password(f.password) then return reply(cb, false, "weak_password") end
		local email = auth.synthetic_email(id)
		if mode == "register" then
			if find(function(x) return x.email == email end) then return reply(cb, false, "id_taken") end
			local a = new_account({ kind = "password", id = id, email = email, verified = false, password = f.password })
			m.session = a.uid
			return reply(cb, true, nil, user_of(a))
		end
		local a = find(function(x) return x.kind == "password" and (x.email == email or x.email == f.id) and x.password == f.password end)
		if not a then return reply(cb, false, "bad_credentials") end
		m.session = a.uid
		reply(cb, true, nil, user_of(a))
	end

	function m.link_google(cb)
		if not begin("link_google", cb) then return end
		local a = me()
		if not a then return reply(cb, false, "no_user") end
		local g = m.google_next
		m.google_next = nil
		if not g then return reply(cb, false, "cancelled") end
		if a.google_sub then return reply(cb, false, "already_linked") end
		if find(function(x) return x.google_sub == g.sub end) then return reply(cb, false, "already_linked") end
		a.google_sub = g.sub
		a.name = a.name or g.name
		a.google_email = g.email
		reply(cb, true, nil, user_of(a))
	end

	-- Sends a verification mail to the address; the address replaces the synthetic one once it is confirmed
	-- (mock.confirm_mail(n) plays the click on the link).
	function m.link_email_form(labels, cb)
		if not begin("link_email_form", cb) then return end
		local a = me()
		if not a then return reply(cb, false, "no_user") end
		local f = m.form_next
		m.form_next = nil
		if f == nil or f == "cancel" then return reply(cb, false, "cancelled") end
		local email = tostring(f.email or ""):lower()
		if not email:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then return reply(cb, false, "bad_email") end
		if find(function(x) return x.email == email and x.uid ~= a.uid end) then return reply(cb, false, "email_in_use") end
		a.pending_email = email
		m.mails[#m.mails + 1] = { to = email, uid = a.uid }
		reply(cb, true, nil, user_of(a))
	end
	function m.confirm_mail(n)
		local mail = m.mails[n]
		local a = mail and m.accounts[mail.uid]
		if not a or a.pending_email ~= mail.to then return false end
		a.email, a.verified, a.pending_email = mail.to, true, nil
		return true
	end

	function m.refresh(cb)
		if not begin("refresh", cb) then return end
		local a = me()
		if not a then return reply(cb, false, "no_user") end
		reply(cb, true, nil, user_of(a))
	end

	function m.sign_out(cb)
		m.calls[#m.calls + 1] = "sign_out"
		m.session = nil
		reply(cb, true)
	end

	function m.delete_account(cb)
		if not begin("delete_account", cb) then return end
		local a = me()
		if not a then return reply(cb, false, "no_user") end
		if not m.recent then return reply(cb, false, "need_recent_login") end
		m.docs[a.uid] = nil
		m.accounts[a.uid] = nil
		m.session = nil
		reply(cb, true)
	end

	-- The rules: a document is reachable only by its owner. `raw_get` models a request for any uid.
	function m.raw_get(requester_uid, doc_uid)
		if requester_uid == nil or requester_uid ~= doc_uid then return nil, "denied" end
		return m.docs[doc_uid]
	end

	function m.cloud_get(cb)
		if not begin("cloud_get", cb) then return end
		if not m.session then return reply(cb, false, "no_user") end
		m.gets = m.gets + 1
		local d = m.raw_get(m.session, m.session)
		reply(cb, true, nil, d and { code = d.code, previous = d.previous } or nil)
	end

	function m.cloud_put(code, previous, cb)
		if not begin("cloud_put", cb) then return end
		if not m.session then return reply(cb, false, "no_user") end
		if type(code) ~= "string" or code == "" then return reply(cb, false, "error") end
		m.puts = m.puts + 1
		m.docs[m.session] = { code = code, previous = previous, puts = m.puts }
		reply(cb, true)
	end

	function m.cloud_delete(cb)
		if not begin("cloud_delete", cb) then return end
		if not m.session then return reply(cb, false, "no_user") end
		m.docs[m.session] = nil
		reply(cb, true)
	end

	return m
end

return M
