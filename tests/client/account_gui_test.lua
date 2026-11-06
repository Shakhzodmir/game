-- The account windows, the settings row and the town's prompts on the strict Defold GUI stub, against the mock
-- provider: what the player sees and taps, in en and ru.

local G = require("tests.client.meta_gui_helper")
local auth = require("client.services.auth")
local cloud = require("client.cloud")
local savecode = require("meta.savecode")
local mock_mod = require("client.services.auth_mock")

local function open(c, name, params)
	c.app.open_popup(name, params)
	c.run(0.6)
	assert_eq(c.app.ui.popup, name)
end

local function wtap(c, name)
	local t = c.app.ui.popup_targets and c.app.ui.popup_targets[name]
	assert_true(t ~= nil, "no target '" .. name .. "' in " .. tostring(c.app.ui.popup))
	c.tap(t.x, t.y)
	c.step(2)
end

local function has(c, text) return G.dump(c.town):find(text, 1, true) ~= nil end
local function toast_has(c, text)
	c.run(0.7)
	return type(c.app.overlay.toast) == "string" and c.app.overlay.toast:find(text, 1, true) ~= nil
end

-- Boots the town with the mock provider (available unless `unavailable`), a fresh binding file.
local function with_account(opts, fn)
	opts = opts or {}
	local m = mock_mod.new({ configured = not opts.unavailable })
	local bfile = {}
	G.with_town({
		language = opts.language or "en", window = opts.window,
		setup = function(app, c)
			auth.set_provider(m)
			cloud.init({ app = app, auth = auth, now = function() return app.now() end, seed = function() return 5 end,
				binding = { read = function() return bfile.data end, write = function(t) bfile.data = t; return true end } })
			if opts.welcomed then cloud.set_welcomed() end
			if opts.setup then opts.setup(app, c, m) end
		end,
	}, function(c) fn(c, m, bfile) end)
	auth.set_provider(nil)
	cloud.reset()
end

describe("account windows", function()
	it("says sign-in is not available when there is no provider, and the player stays a guest", function()
		with_account({ unavailable = true }, function(c)
			open(c, "settings")
			assert_true(has(c, "Guest"), G.dump(c.town))
			wtap(c, "account")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "account")
			assert_true(has(c, "not available yet"))
			assert_true(c.app.ui.popup_targets.google == nil)
			c.run(3)
			assert_eq(c.app.ui.popup, "account", "no first-launch window without a provider")
		end)
	end)

	it("asks once on the first launch: guest closes it for good", function()
		with_account({}, function(c, m, bfile)
			c.run(3)
			assert_eq(c.app.ui.popup, "account")
			assert_true(c.app.ui.popup_targets.google ~= nil)
			assert_true(c.app.ui.popup_targets.id_login ~= nil)
			assert_true(c.app.ui.popup_targets.create ~= nil)
			wtap(c, "guest")
			c.run(0.6)
			assert_eq(c.app.ui.popup, nil)
			assert_true(cloud.welcomed())
			assert_true(bfile.data.welcomed)
		end)
	end)

	it("signs in with Google from the first window, uploads the progress and shows who is in", function()
		with_account({ welcomed = false, setup = function(app) G.win(app, 4) end }, function(c, m)
			c.run(3)
			m.google_next = { sub = "g1", email = "anna@gmail.com", name = "Anna" }
			wtap(c, "google")
			c.run(0.6)
			assert_eq(auth.user().uid, "u001")
			assert_eq(m.puts, 1)
			assert_true(cloud.welcomed())
			assert_eq(c.app.ui.popup, nil, "the window closed after the sign-in")
			open(c, "account")
			assert_true(has(c, "Signed in: anna@gmail.com"), G.dump(c.town))
			assert_true(has(c, "Saved in the cloud"))
		end)
	end)

	it("creates an ID account, warns that there is no e-mail, links one and signs out after a confirmation", function()
		with_account({ welcomed = true }, function(c, m)
			open(c, "account")
			m.form_next = { id = "Anna_7", password = "secret123" }
			wtap(c, "create")
			c.run(0.6)
			assert_eq(auth.user().id, "anna_7")
			assert_true(has(c, "forgotten password cannot be restored"), G.dump(c.town))
			m.form_next = { email = "anna@gmail.com" }
			wtap(c, "link_email")
			c.run(0.6)
			assert_true(has(c, "Waiting for confirmation: anna@gmail.com"))
			assert_true(c.app.ui.popup_targets.check_mail ~= nil)
			wtap(c, "check_mail")
			c.run(0.6)
			assert_eq(#m.mails, 1)
			m.confirm_mail(1)
			wtap(c, "check_mail")
			c.run(0.6)
			assert_true(auth.can_recover(auth.user()))
			assert_true(c.app.ui.popup_targets.link_email == nil)
			wtap(c, "sign_out")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "confirm")
			wtap(c, "confirm")
			c.run(0.8)
			assert_eq(auth.user(), nil)
		end)
	end)

	it("shows the error when the password is wrong and keeps the player a guest", function()
		with_account({ welcomed = true }, function(c, m)
			open(c, "account")
			m.form_next = { id = "nobody", password = "secret123" }
			wtap(c, "id_login")
			c.run(0.6)
			assert_eq(auth.user(), nil)
			assert_true(toast_has(c, "Wrong ID or password"), tostring(c.app.overlay.toast))
		end)
	end)

	it("deletes the account after a confirmation; an old sign-in is asked to repeat first", function()
		with_account({ welcomed = true, setup = function(app) G.win(app, 2) end }, function(c, m)
			open(c, "account")
			m.google_next = { sub = "g1", email = "a@gmail.com" }
			wtap(c, "google")
			c.run(0.6)
			open(c, "account")
			m.recent = false
			wtap(c, "delete")
			c.run(0.6)
			wtap(c, "confirm")
			c.run(0.8)
			assert_true(toast_has(c, "sign in again first"), tostring(c.app.overlay.toast))
			assert_true(auth.user() ~= nil)
			open(c, "account")
			m.recent = true
			wtap(c, "delete")
			c.run(0.6)
			wtap(c, "confirm")
			c.run(0.8)
			assert_eq(auth.user(), nil)
			assert_eq(next(m.docs), nil)
			assert_eq(c.app.meta:level_to_play(), 3, "progress stays on the device")
		end)
	end)
end)

describe("cloud choice window", function()
	local function other_branch(app, _, m)
		G.win(app, 3)
		local tbl3 = app.meta:serialize()
		m.accounts.u001 = { uid = "u001", kind = "google", google_sub = "g1", verified = true, email = "a@gmail.com" }
		m.docs.u001 = { code = savecode.encode(tbl3) }
		app.reset_save(7, app.now())
		G.win(app, 1)
	end

	it("shows both saves, recommends the one further along and takes the cloud save into the town", function()
		with_account({ welcomed = true, setup = other_branch, language = "ru" }, function(c, m)
			m.google_next = { sub = "g1", email = "a@gmail.com" }
			auth.sign_in_google(function() end)
			cloud.on_signed_in()
			c.run(3)
			assert_eq(c.app.ui.popup, "cloud_choice")
			assert_true(has(c, "Уровней 3"), G.dump(c.town))
			assert_true(has(c, "Уровней 1"))
			assert_true(has(c, "Прогресс больше"))
			wtap(c, "download")
			c.run(0.5)
			assert_eq(c.app.meta:level_to_play(), 4)
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(posts[#posts].message.name, "splash")
		end)
	end)

	it("'not now' keeps playing and pauses the upload", function()
		with_account({ welcomed = true, setup = other_branch }, function(c, m)
			m.google_next = { sub = "g1", email = "a@gmail.com" }
			auth.sign_in_google(function() end)
			cloud.on_signed_in()
			c.run(3)
			assert_eq(c.app.ui.popup, "cloud_choice")
			wtap(c, "cancel")
			c.run(0.6)
			assert_eq(c.app.ui.popup, nil)
			assert_eq(cloud.status().status, "paused")
			assert_eq(c.app.meta:level_to_play(), 2)
			assert_eq(m.puts, 0)
		end)
	end)

	it("closing with the corner button is the same as 'not now'", function()
		with_account({ welcomed = true, setup = other_branch }, function(c, m)
			m.google_next = { sub = "g1", email = "a@gmail.com" }
			auth.sign_in_google(function() end)
			cloud.on_signed_in()
			c.run(3)
			wtap(c, "close")
			c.run(0.6)
			assert_eq(cloud.status().status, "paused")
		end)
	end)
end)

describe("guest reminder", function()
	it("shows a soft reminder after ten levels, once", function()
		with_account({ welcomed = true, setup = function(app) G.win(app, 10) end }, function(c)
			c.run(3)
			assert_true(toast_has(c, "Playing as a guest"), tostring(c.app.overlay.toast))
			assert_eq(cloud.binding().reminded, 10)
		end)
	end)
end)

describe("account_gui cleanup", function()
	it("leaves no provider and no cloud state behind for the next test file", function()
		require("client.cloud").reset()
		require("client.services.auth").set_provider(nil)
	end)
end)
