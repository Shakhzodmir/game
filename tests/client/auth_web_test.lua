-- The browser bridge (client/services/auth_web.lua) against a fake window.glowAuth: the call string it sends,
-- the poll lines it reads, timeouts, and that passwords are never part of what Lua sends or receives.

local auth = require("client.services.auth")
local web = require("client.services.auth_web")

local function fake_page(configured)
	local page = { calls = {}, queue = {}, configured = configured ~= false, clock = 0 }
	page.run = function(js)
		if js:find("glowAuth.configured", 1, true) then return page.configured and "1" or "0" end
		if js == web.POLL_JS then
			local out = table.concat(page.queue, "\n")
			page.queue = {}
			return out
		end
		local id, op, args = js:match("glowAuth%.call%((%d+),\"([%w_]+)\",%[(.*)%]%)")
		assert(id, js)
		page.calls[#page.calls + 1] = { id = tonumber(id), op = op, args = args }
		return "ok"
	end
	return page
end

describe("client.services.auth_web", function()
	it("is available only when the page has a configured project", function()
		assert_true(web.new({ run = fake_page(true).run }).available())
		assert_false(web.new({ run = fake_page(false).run }).available())
		assert_false(web.new({ run = function() return nil end }).available(), "no page: not available")
	end)

	it("parses poll lines with percent-encoded values", function()
		local id, ok, reason, f = web.parse_line("12|1||uid=u1&name=An%20na%20%D0%AF&id=anna_7")
		assert_eq(id, 12); assert_true(ok); assert_eq(reason, nil)
		assert_eq(f.name, "An na \208\175")
		local _, ok2, reason2 = web.parse_line("13|0|offline|")
		assert_false(ok2); assert_eq(reason2, "offline")
		assert_eq(web.parse_line("garbage"), nil)
	end)

	it("signs in through the bridge and gets a user without any password", function()
		local page = fake_page()
		local p = web.new({ run = page.run, now = function() return page.clock end })
		auth.set_provider(p)
		local res
		auth.password_form("login", { title = "Sign in", submit = "OK" }, function(ok, why, u) res = { ok, why, u } end)
		local call = page.calls[1]
		assert_eq(call.op, "password_form")
		assert_true(call.args:find('"login"', 1, true) ~= nil)
		assert_true(call.args:find('"Sign in"', 1, true) ~= nil)
		page.queue[1] = call.id .. "|1||email=anna_7%40id.glow.invalid&google=0&id=anna_7&kind=password&uid=u1&verified=0"
		auth.tick(1)
		assert_true(res[1])
		assert_eq(res[3].id, "anna_7")
		assert_eq(res[3].kind, "password")
		assert_false(res[3].email_verified)
		assert_eq(auth.user().uid, "u1")
		assert_eq(auth.label(auth.user()), "anna_7")
	end)

	it("reads a cloud document, a missing one and a failure", function()
		local page = fake_page()
		local p = web.new({ run = page.run, now = function() return page.clock end })
		auth.set_provider(p)
		local got = {}
		auth.cloud_get(function(ok, why, doc) got[1] = { ok, why, doc } end)
		page.queue[1] = page.calls[1].id .. "|1||code=GLOW1-abc&found=1&previous="
		auth.tick(1)
		assert_eq(got[1][3].code, "GLOW1-abc")
		assert_eq(got[1][3].previous, nil)
		auth.cloud_get(function(ok, why, doc) got[2] = { ok, why, doc } end)
		page.queue[1] = page.calls[2].id .. "|1||found=0"
		auth.tick(2)
		assert_true(got[2][1]); assert_eq(got[2][3], nil)
		auth.cloud_put("GLOW1-x", nil, function(ok, why) got[3] = { ok, why } end)
		assert_true(page.calls[3].args:find('"GLOW1-x",""', 1, true) ~= nil)
		page.queue[1] = page.calls[3].id .. "|0|denied|"
		auth.tick(3)
		assert_false(got[3][1]); assert_eq(got[3][2], "denied")
	end)

	it("gives up on an operation the browser never answers, and ignores a late answer", function()
		local page = fake_page()
		local p = web.new({ run = page.run, now = function() return page.clock end })
		auth.set_provider(p)
		local res
		auth.cloud_get(function(ok, why) res = { ok, why } end)
		auth.tick(10)
		assert_eq(res, nil)
		page.clock = web.DATA_TIMEOUT + 1
		auth.tick(page.clock)
		assert_eq(res[2], "timeout")
		page.queue[1] = page.calls[1].id .. "|1||found=0"
		auth.tick(page.clock + 1) -- nothing pending: no poll, no crash
		assert_eq(p.pending_count(), 0)
	end)

	it("answers unavailable when the page has no bridge", function()
		auth.set_provider(web.new({ run = function(js) if js:find("configured", 1, true) then return "1" end return "unavailable" end }))
		local res
		auth.sign_in_google(function(ok, why) res = { ok, why } end)
		assert_eq(res[2], "unavailable")
		assert_false(auth.busy())
	end)
end)

describe("auth_web cleanup", function()
	it("leaves no provider and no cloud state behind for the next test file", function()
		require("client.cloud").reset()
		require("client.services.auth").set_provider(nil)
	end)
end)
