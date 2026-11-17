-- "Forgot the password" (WP-18): the service call against the mock and against the browser bridge, the page-opening
-- helper of client/platform.lua, and the strings of the new buttons in all three languages.

local auth = require("client.services.auth")
local mock_mod = require("client.services.auth_mock")
local web = require("client.services.auth_web")
local platform = require("client.platform")
local i18n = require("client.i18n")

local LABELS = { title = "Forgot password?", submit = "Send" }

local function reset(cb, lang) auth.reset_password(LABELS, lang or "en", cb) end

describe("auth.reset_password with the mock provider", function()
	local m
	before_each(function()
		m = mock_mod.new()
		auth.set_provider(m)
		m.accounts.u001 = { uid = "u001", kind = "password", id = "anna_7", email = "anna@gmail.com", verified = true, password = "secret123" }
	end)

	it("needs no sign-in and leaves the player a guest", function()
		local res
		m.form_next = { email = "anna@gmail.com" }
		reset(function(ok, why) res = { ok, why } end, "ko")
		assert_true(res[1])
		assert_eq(auth.user(), nil)
		assert_eq(#m.resets, 1)
		assert_eq(m.resets[1].lang, "ko")
		assert_true(m.resets[1].sent)
		assert_false(auth.busy())
	end)

	it("answers success for an unknown address exactly as for a known one", function()
		local a, b
		m.form_next = { email = "anna@gmail.com" }
		reset(function(...) a = { select("#", ...), ... } end)
		m.form_next = { email = "nobody@example.com" }
		reset(function(...) b = { select("#", ...), ... } end)
		assert_same(a, b)
		assert_true(m.resets[1].sent)
		assert_false(m.resets[2].sent, "no letter goes to an address without an account")
	end)

	it("refuses a malformed address and an ID account's inner address", function()
		local res = {}
		m.form_next = { email = "not an address" }
		reset(function(ok, why) res[1] = why end)
		m.form_next = { email = "anna_7@id.glow.invalid" }
		reset(function(ok, why) res[2] = why end)
		assert_eq(res[1], "bad_email")
		assert_eq(res[2], "bad_email")
		assert_eq(#m.resets, 0)
	end)

	it("reports no connection, too many attempts and a cancelled form", function()
		local res = {}
		m.online = false
		m.form_next = { email = "anna@gmail.com" }
		reset(function(ok, why) res[1] = why end)
		m.online, m.too_many = true, true
		m.form_next = { email = "anna@gmail.com" }
		reset(function(ok, why) res[2] = why end)
		m.too_many = false
		reset(function(ok, why) res[3] = why end)
		assert_eq(res[1], "offline")
		assert_eq(res[2], "too_many")
		assert_eq(res[3], "cancelled")
		assert_eq(#m.resets, 0)
	end)

	it("takes the busy guard while the form is open", function()
		local res = {}
		m.manual = true
		m.form_next = { email = "anna@gmail.com" }
		reset(function(ok, why) res[1] = { ok, why } end)
		assert_true(auth.busy())
		reset(function(ok, why) res[2] = { ok, why } end)
		assert_eq(res[2][2], "busy")
		m.flush()
		assert_true(res[1][1])
		assert_false(auth.busy())
	end)

	it("says unavailable without a provider", function()
		auth.set_provider(nil)
		local res
		reset(function(ok, why) res = { ok, why } end)
		assert_false(res[1])
		assert_eq(res[2], "unavailable")
	end)
end)

describe("auth.reset_password through the browser bridge", function()
	local function fake_page()
		local page = { calls = {}, queue = {}, clock = 0 }
		page.run = function(js)
			if js:find("glowAuth.configured", 1, true) then return "1" end
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

	it("sends the language first, then the labels, and takes a bare success", function()
		local page = fake_page()
		auth.set_provider(web.new({ run = page.run, now = function() return page.clock end }))
		local res
		auth.reset_password(LABELS, "ru", function(ok, why, data) res = { ok, why, data } end)
		local call = page.calls[1]
		assert_eq(call.op, "reset_password")
		assert_true(call.args:find('^"ru","submit","Send","title","Forgot password%?"') ~= nil, call.args)
		page.queue[1] = call.id .. "|1||"
		auth.tick(1)
		assert_true(res[1])
		assert_eq(res[3], nil)
		assert_eq(auth.user(), nil)
	end)

	it("reads the two failures the player is told about", function()
		local page = fake_page()
		auth.set_provider(web.new({ run = page.run, now = function() return page.clock end }))
		local res = {}
		reset(function(ok, why) res[1] = why end)
		page.queue[1] = page.calls[1].id .. "|0|offline|"
		auth.tick(1)
		reset(function(ok, why) res[2] = why end)
		page.queue[1] = page.calls[2].id .. "|0|too_many|"
		auth.tick(2)
		assert_eq(res[1], "offline")
		assert_eq(res[2], "too_many")
		assert_false(auth.busy())
	end)

	it("lets the form stay open as long as an interactive call may", function()
		local page = fake_page()
		auth.set_provider(web.new({ run = page.run, now = function() return page.clock end }))
		local res
		reset(function(ok, why) res = { ok, why } end)
		page.clock = web.DATA_TIMEOUT + 5
		auth.tick(page.clock)
		assert_eq(res, nil, "a form is not a data call: no timeout after 40 seconds")
		page.clock = web.INTERACTIVE_TIMEOUT + 5
		auth.tick(page.clock)
		assert_eq(res[2], "timeout")
	end)
end)

describe("platform.open_url", function()
	local saved_html5
	before_each(function() saved_html5 = rawget(_G, "html5") end)

	local function with_html5(run, fn)
		local restore = platform.stub({ is_html5 = function() return true end })
		rawset(_G, "html5", { run = run })
		local ok, err = pcall(fn)
		rawset(_G, "html5", saved_html5)
		restore()
		if not ok then error(err, 0) end
	end

	it("opens a page of the site in a new tab on the web", function()
		local sent
		with_html5(function(js) sent = js; return "1" end, function()
			assert_true(platform.open_url("privacy.html"))
		end)
		assert_true(sent:find("window.open", 1, true) ~= nil, sent)
		assert_true(sent:find('"privacy.html"', 1, true) ~= nil, sent)
		assert_true(sent:find("_blank", 1, true) ~= nil, sent)
	end)

	it("answers false when the browser blocks the tab or the bridge fails", function()
		with_html5(function() return "0" end, function() assert_false(platform.open_url("privacy.html")) end)
		with_html5(function() error("no bridge") end, function() assert_false(platform.open_url("privacy.html")) end)
	end)

	it("does nothing outside the browser", function()
		local touched = false
		rawset(_G, "html5", { run = function() touched = true; return "1" end })
		local restore = platform.stub({ is_html5 = function() return false end })
		assert_false(platform.open_url("privacy.html"))
		restore()
		rawset(_G, "html5", saved_html5)
		assert_false(touched)
	end)

	it("takes only a plain relative path", function()
		local calls = 0
		with_html5(function() calls = calls + 1; return "1" end, function()
			for _, bad in ipairs({ "", "https://example.com/", "//example.com", "/privacy.html", "../secret", "a/../b", "a b", "x';alert(1)//", 5 }) do
				assert_false(platform.open_url(bad), tostring(bad))
			end
			assert_true(platform.open_url("docs/privacy-ru.html"))
		end)
		assert_eq(calls, 1)
	end)
end)

describe("strings of the password reset and the privacy link", function()
	local KEYS = { "account.forgot", "account.find_id", "account.no_mail_hint", "account.form_reset_note", "account.reset_send",
		"account.reset_sent", "account.reset_offline", "account.reset_too_many", "account.privacy_link", "account.privacy_blocked" }

	it("exist in ru, en and ko, and none is empty", function()
		for _, key in ipairs(KEYS) do
			local entry = i18n.STRINGS[key]
			assert_true(entry ~= nil, key)
			for _, lang in ipairs({ "ru", "en", "ko" }) do
				assert_eq(type(entry[lang]), "string", key .. "/" .. lang)
				assert_true(#entry[lang] > 3, key .. "/" .. lang .. " is empty")
			end
			assert_true(entry.ko:find("[\234-\237]") ~= nil, key .. " ko has no Hangul")
			assert_true(entry.ru:find("[\208\209]") ~= nil, key .. " ru has no Cyrillic")
		end
	end)

	it("say what the producer asked for about a forgotten ID and the 'sent' answer", function()
		local find = i18n.STRINGS["account.find_id"]
		assert_true(find.ru:find("Если почта привязана, входите по почте: ваш ID теперь почта.", 1, true) ~= nil)
		assert_true(find.ru:find("Если почта не привязана, ID виден в Настройках, пока вы вошли.", 1, true) ~= nil)
		assert_true(i18n.STRINGS["account.reset_sent"].ru:find("Если такая почта есть, письмо отправлено", 1, true) ~= nil)
	end)

	it("read back as non-empty text in every language", function()
		for _, lang in ipairs({ "ru", "en", "ko" }) do
			i18n.set_language(lang)
			for _, key in ipairs(KEYS) do assert_true(#i18n.t(key) > 3, key .. "/" .. lang) end
		end
		i18n.set_language("en")
	end)
end)

describe("auth_reset cleanup", function()
	it("leaves no provider behind for the next test file", function()
		auth.set_provider(nil)
		require("client.cloud").reset()
	end)
end)
