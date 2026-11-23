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

local function wait_for(c, pred, seconds, what)
	for _ = 1, math.ceil((seconds or 5) * 60) do
		if pred() then return end
		c.step(1)
	end
	assert_true(pred(), "timed out waiting for " .. tostring(what))
end

-- a tap on the card of the next task of the town
local function tap_card(c)
	local t = c.app.ui.targets and c.app.ui.targets.task
	assert_true(t ~= nil, "no task card on the town")
	c.tap(t.x, t.y)
end

-- a save with the first layer built: the first-launch window is due from the start of the visit (the window waits
-- for a purchase, so a test that wants it on the screen starts from here)
local function built_first(app) G.build_tasks(app, "cafe", 1) end

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

	-- The first-launch window is not for the first star: it waits until the player has built a layer (producer, 23.11.2026).
	it("waits for the first purchase, lets the first layer be heard, then asks once: guest closes it for good", function()
		local steps = require("screens.town.steps")
		with_account({ setup = function(app) G.win(app, 1) end }, function(c, m, bfile)
			c.run(6) -- the town, the reward of level 1 landing, the hint over the card
			assert_eq(c.app.ui.hint, "town_first_task")
			assert_eq(c.app.ui.popup, nil, "not over the first star")
			assert_false(cloud.welcomed())
			tap_card(c)
			wait_for(c, function() return c.app.ui.busy end, 1, "the purchase")
			wait_for(c, function() return not c.app.ui.busy end, 6, "the purchase to end")
			local t_end = c.E.clock
			assert_eq(c.app.meta:district("cafe").done, 1)
			c.run(1)
			assert_eq(c.app.ui.popup, nil, "not over the first music: Bit is listening to the new layer")
			wait_for(c, function() return c.app.ui.popup == "account" end, 8, "the first-launch window")
			local waited = c.E.clock - t_end
			assert_true(waited >= steps.LISTEN_FOR and waited <= steps.LISTEN_FOR + 1.5, "it came " .. string.format("%.1f", waited) .. " s after the show")
			c.run(0.6) -- the window has come in
			assert_true(c.app.ui.popup_targets.google ~= nil)
			assert_true(c.app.ui.popup_targets.id_login ~= nil)
			assert_true(c.app.ui.popup_targets.create ~= nil)
			wtap(c, "guest")
			c.run(0.6)
			assert_eq(c.app.ui.popup, nil)
			assert_true(cloud.welcomed())
			assert_true(bfile.data.welcomed)
			-- never twice: not again in this visit, not with the next layer
			c.run(8)
			assert_eq(c.app.ui.popup, nil)
			G.give_stars(c.app, 1)
			c.step(5)
			tap_card(c)
			wait_for(c, function() return c.app.ui.busy end, 1, "the second purchase")
			wait_for(c, function() return not c.app.ui.busy end, 6, "the second purchase to end")
			assert_eq(c.app.meta:district("cafe").done, 2)
			c.run(10)
			assert_eq(c.app.ui.popup, nil, "asked once")
		end)
	end)

	it("asks as soon as the town opens when a layer was built before (a return visit): the first visit had no window", function()
		with_account({ setup = built_first }, function(c)
			local t = c.town.self.t
			assert_eq(c.app.ui.popup, nil, "the town has just opened") -- (the helper has run half a second of it)
			wait_for(c, function() return c.app.ui.popup == "account" end, 2, "the first-launch window")
			assert_true(t.enter_t <= 1.2, "no wait for a layer built in an earlier visit: it came " .. string.format("%.2f", t.enter_t) .. " s in")
			c.run(0.6)
			assert_true(c.app.ui.popup_targets.guest ~= nil)
		end)
	end)

	it("a window closed with the corner button counts as 'guest' too, and a skipped purchase waits like the others", function()
		local steps = require("screens.town.steps")
		with_account({ setup = function(app) G.win(app, 1) end }, function(c)
			tap_card(c)
			c.run(0.25)
			assert_true(c.app.ui.busy)
			c.tap(360, 800) -- a tap skips the show: Bit listens from this moment
			c.step(3)
			assert_false(c.app.ui.busy)
			local t0 = c.E.clock
			c.run(steps.LISTEN_FOR - 0.2)
			assert_eq(c.app.ui.popup, nil, "Bit is still listening")
			wait_for(c, function() return c.app.ui.popup == "account" end, 3, "the window")
			c.run(0.6)
			wtap(c, "close")
			c.run(0.6)
			assert_eq(c.app.ui.popup, nil)
			assert_true(cloud.welcomed())
			c.run(5)
			assert_eq(c.app.ui.popup, nil)
			assert_true(c.E.clock - t0 > steps.LISTEN_FOR)
		end)
	end)

	it("does not hold the soft guest reminder back: ten levels without a purchase still hear about the account", function()
		with_account({ setup = function(app) G.win(app, 10) end }, function(c)
			c.run(5)
			assert_eq(c.app.ui.popup, nil, "no window: nothing was built")
			assert_true(toast_has(c, "Playing as a guest"), tostring(c.app.overlay.toast))
			assert_eq(cloud.binding().reminded, 10)
			assert_false(cloud.welcomed())
			-- the window is still to come with the first layer
			tap_card(c)
			wait_for(c, function() return c.app.ui.busy end, 1, "the purchase")
			wait_for(c, function() return not c.app.ui.busy end, 6, "the purchase to end")
			wait_for(c, function() return c.app.ui.popup == "account" end, 8, "the first-launch window")
		end)
	end)

	it("is not asked at all without a provider, however much is built", function()
		with_account({ unavailable = true, setup = built_first }, function(c)
			c.run(6)
			assert_eq(c.app.ui.popup, nil)
		end)
	end)

	it("signs in with Google from the first window, uploads the progress and shows who is in", function()
		with_account({ welcomed = false, setup = function(app) G.win(app, 4); built_first(app) end }, function(c, m)
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

	it("creates an ID account, asks to link Google (no e-mail linking), links it and signs out after a confirmation", function()
		with_account({ welcomed = true }, function(c, m)
			open(c, "account")
			m.form_next = { id = "Anna_7", password = "secret123" }
			wtap(c, "create")
			c.run(0.6)
			assert_eq(auth.user().id, "anna_7")
			assert_true(has(c, "Link Google so you don't lose the account"), G.dump(c.town))
			assert_true(c.app.ui.popup_targets.link_email == nil and c.app.ui.popup_targets.check_mail == nil, "Google only")
			assert_true(c.app.ui.popup_targets.forgot == nil)
			m.google_next = { sub = "g7", email = "anna@gmail.com" }
			wtap(c, "link_google")
			c.run(0.6)
			assert_true(auth.user().google_linked)
			assert_true(has(c, "Google linked: anna@gmail.com"), G.dump(c.town))
			assert_true(c.app.ui.popup_targets.sync == nil, "saving is automatic: no button")
			assert_false(has(c, "Link Google so you don't lose the account"))
			assert_true(c.app.ui.popup_targets.link_google == nil, "nothing left to link")
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

-- What the player is told when Google's window ends without a sign-in (a phone has no console: silence looks like a bug)
describe("google sign-in feedback", function()
	local function toast_now(c) return type(c.app.overlay.toast) == "string" and c.app.overlay.toast or "" end

	it("stays silent when the player said no himself (the Cancel of the Google card)", function()
		with_account({ welcomed = true }, function(c, m)
			open(c, "account")
			wtap(c, "google") -- the mock answers "cancelled"
			c.run(3)
			assert_eq(c.app.overlay.toast, nil, "a 'no' is silent")
			assert_eq(auth.user(), nil)
		end)
	end)

	it("explains a Google window that closed or never answered, in the game's language", function()
		for _, case in ipairs({
			{ "en", "popup_closed", "The Google window closed" },
			{ "ru", "popup_closed", "Окно Google закрылось" },
			{ "en", "popup_timeout", "Google did not answer" },
			{ "en", "home_app", "Google does not answer here" },
			{ "ru", "home_app", "Здесь Google не отвечает" },
			{ "en", "popup_blocked", "Window blocked" },
		}) do
			with_account({ welcomed = true, language = case[1] }, function(c, m)
				open(c, "account")
				m.google_error = case[2]
				wtap(c, "google")
				c.run(0.7)
				assert_true(toast_now(c):find(case[3], 1, true) ~= nil, case[2] .. ": " .. toast_now(c))
				assert_eq(auth.user(), nil)
				assert_eq(c.app.ui.popup, "account", "the window stays: ID and password are one tap away")
			end)
		end
	end)

	it("shows a closed window as a soft blue 4 s toast and the other failures in pink", function()
		for _, case in ipairs({ { "popup_closed", "blue" }, { "popup_timeout", "pink" }, { "home_app", "pink" }, { "popup_blocked", "pink" } }) do
			with_account({ welcomed = true }, function(c, m)
				local seen
				local real = c.app.toast_key
				c.app.toast_key = function(key, vars, opts)
					seen = { key = key, color = opts and opts.color, duration = opts and opts.duration }
					return real(key, vars, opts)
				end
				open(c, "account")
				m.google_error = case[1]
				wtap(c, "google")
				c.app.toast_key = real
				assert_true(seen ~= nil, case[1] .. ": a toast")
				assert_eq(seen.key, "auth.err." .. case[1])
				assert_eq(seen.color, case[2], case[1])
				assert_eq(seen.duration, 4)
			end)
		end
	end)

	it("tells an ID account that taps 'Link Google' in the Home Screen app that Google does not answer there", function()
		with_account({ welcomed = true }, function(c, m)
			open(c, "account")
			m.form_next = { id = "Anna_7", password = "secret123" }
			wtap(c, "create")
			c.run(0.6)
			assert_eq(auth.user().id, "anna_7")
			m.google_error = "home_app"
			wtap(c, "link_google")
			local seen = {}
			for _ = 1, 40 do -- the toast queue shows "Signed in" first
				c.run(0.25)
				local t = c.app.overlay.toast
				if type(t) == "string" then seen[#seen + 1] = t end
			end
			local all = table.concat(seen, " | ")
			assert_true(all:find("does not answer in the Home Screen app", 1, true) ~= nil, all)
			assert_true(all:find("Use ID and password", 1, true) == nil, "he is signed in with ID already: " .. all)
		end)
	end)

	it("shows every Google failure toast at a readable size in en, ru and ko", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			G.with_town({ town = false, language = lang }, function(c)
				for _, k in ipairs({ "popup_blocked", "popup_closed", "popup_timeout", "home_app", "home_app_link", "inapp_browser", "browser_unsupported" }) do
					c.app.toast_key("auth.err." .. k, nil, { duration = 1 })
					c.overlay:run(0.8)
					local list = c.overlay:smallest_texts(1)
					assert_true(list[1] ~= nil, lang .. " " .. k .. ": the toast is on screen")
					-- the toast is ONE line scaled to the canvas width: a long text becomes tiny (15 px is the project's floor)
					assert_true(list[1].px >= 18, lang .. " " .. k .. ": only " .. string.format("%.1f", list[1].px) .. " px")
					c.overlay:run(3)
				end
			end)
		end
	end)

	it("answers a second tap while a window is out with 'busy', not with a second window", function()
		with_account({ welcomed = true }, function(c, m)
			m.manual = true -- the answer is held: the window is "out"
			open(c, "account")
			wtap(c, "google")
			assert_eq(c.app.overlay.toast, nil)
			wtap(c, "google")
			c.run(0.7)
			assert_true(toast_now(c):find("still working", 1, true) ~= nil, toast_now(c))
			assert_eq(#m.calls, 1, "one window")
			m.manual = false
		end)
	end)
end)

-- "Forgot password?", "Forgot your ID?" and the privacy policy link (WP-18)
local platform = require("client.platform")

-- Pretends to be the web build for `fn`; `tabs` collects the pages opened, `blocked` makes the browser refuse.
local function as_web(fn, blocked)
	local tabs = {}
	local restore = platform.stub({
		is_html5 = function() return true end,
		open_url = function(url) tabs[#tabs + 1] = url; return not blocked end,
	})
	local ok, err = pcall(fn, tabs)
	restore()
	if not ok then error(err, 0) end
end

describe("forgot password and the privacy link", function()
	it("has no 'Forgot password?' in any window: Google is the only recovery", function()
		with_account({ setup = built_first }, function(c)
			c.run(3)
			assert_eq(c.app.ui.popup, "account")
			assert_true(c.app.ui.popup_targets.forgot == nil)
			assert_false(has(c, "Forgot your ID?"))
		end)
		with_account({ welcomed = true }, function(c)
			open(c, "account")
			assert_true(c.app.ui.popup_targets.forgot == nil)
			assert_true(c.app.ui.popup_targets.google ~= nil)
		end)
	end)

	it("opens the privacy page from the first-launch window and from the settings, on the web only", function()
		as_web(function(tabs)
			with_account({ setup = built_first }, function(c)
				c.run(3)
				assert_true(c.app.ui.popup_targets.privacy ~= nil)
				wtap(c, "privacy")
				assert_same(tabs, { "privacy.html" })
				wtap(c, "guest")
				c.run(0.6)
				open(c, "settings")
				wtap(c, "privacy")
				assert_same(tabs, { "privacy.html", "privacy.html" })
			end)
		end)
		local called = 0
		local restore = platform.stub({ is_html5 = function() return false end, open_url = function() called = called + 1; return true end })
		with_account({ welcomed = true }, function(c)
			open(c, "settings")
			wtap(c, "privacy")
			c.run(0.7)
			assert_eq(called, 0, "outside the browser nothing is opened")
			assert_eq(c.app.overlay.toast, nil, "and nothing is said")
		end)
		restore()
	end)

	it("says so when the browser blocks the new tab", function()
		as_web(function(tabs)
			with_account({ welcomed = true }, function(c)
				open(c, "settings")
				wtap(c, "privacy")
				assert_eq(#tabs, 1)
				assert_true(toast_has(c, "did not open a new tab"), tostring(c.app.overlay.toast))
			end)
		end, true)
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

	-- the device (a separate game) is ahead of the account: settled without a question too (the device save is uploaded)
	local function device_ahead(app, _, m)
		G.win(app, 1)
		local tbl1 = app.meta:serialize()
		m.accounts.u001 = { uid = "u001", kind = "google", google_sub = "g1", verified = true, email = "a@gmail.com" }
		m.docs.u001 = { code = savecode.encode(tbl1) }
		app.reset_save(7, app.now())
		G.win(app, 3)
	end

	-- what still asks: the account's save is unreadable (here its older copy can be read, so both saves are shown)
	local function damaged_account(app, c, m)
		device_ahead(app, c, m)
		m.docs.u001 = { code = "GLOW1-garbage", previous = m.docs.u001.code }
	end

	local function splashes(c)
		local n = 0
		for _, p in ipairs(c.E.posted("show_screen", "main:/app")) do
			if p.message.name == "splash" then n = n + 1 end
		end
		return n
	end

	it("takes the account's save into the town by itself when it is further along (no question)", function()
		with_account({ welcomed = true, setup = other_branch, language = "ru" }, function(c, m)
			m.google_next = { sub = "g1", email = "a@gmail.com" }
			auth.sign_in_google(function() end)
			cloud.on_signed_in()
			c.run(3)
			assert_true(c.app.ui.popup ~= "cloud_choice", "no window")
			c.run(0.5)
			assert_eq(c.app.meta:level_to_play(), 4)
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(posts[#posts].message.name, "splash")
		end)
	end)

	it("uploads this device's save by itself when it is ahead of the account: no window, the town goes on", function()
		with_account({ welcomed = true, setup = device_ahead, language = "ru" }, function(c, m)
			local old = m.docs.u001.code
			local before = splashes(c)
			m.google_next = { sub = "g1", email = "a@gmail.com" }
			auth.sign_in_google(function() end)
			cloud.on_signed_in()
			c.run(3)
			assert_true(c.app.ui.popup ~= "cloud_choice", "no window")
			assert_eq(cloud.decision(), nil)
			assert_eq(cloud.status().status, "synced")
			assert_eq(m.puts, 1)
			assert_eq(m.docs.u001.code, savecode.encode(c.app.store.last), "the account holds the device save")
			assert_eq(m.docs.u001.previous, old, "and keeps its old one")
			assert_eq(c.app.meta:level_to_play(), 4)
			assert_eq(splashes(c), before, "the town was not restarted")
		end)
	end)

	it("still asks when the account's save is damaged: both saves, the one further along recommended", function()
		with_account({ welcomed = true, setup = damaged_account, language = "ru" }, function(c, m)
			m.google_next = { sub = "g1", email = "a@gmail.com" }
			auth.sign_in_google(function() end)
			cloud.on_signed_in()
			c.run(3)
			assert_eq(c.app.ui.popup, "cloud_choice")
			assert_true(has(c, "Уровней 3"), G.dump(c.town))
			assert_true(has(c, "Уровней 1"))
			assert_true(c.app.ui.popup_targets.upload ~= nil and c.app.ui.popup_targets.download ~= nil
				and c.app.ui.popup_targets.cancel ~= nil, "keep this one, take the account's, not now")
			assert_eq(m.puts, 0, "nothing is written before the answer")
			assert_eq(c.app.meta:level_to_play(), 4)
		end)
	end)

	it("the player's answer in the window is carried out: the device save goes to the account", function()
		with_account({ welcomed = true, setup = damaged_account }, function(c, m)
			m.google_next = { sub = "g1", email = "a@gmail.com" }
			auth.sign_in_google(function() end)
			cloud.on_signed_in()
			c.run(3)
			assert_eq(c.app.ui.popup, "cloud_choice")
			wtap(c, "upload")
			c.run(0.6)
			assert_eq(c.app.ui.popup, nil)
			assert_eq(cloud.decision(), nil)
			assert_eq(m.puts, 1)
			assert_eq(m.docs.u001.code, savecode.encode(c.app.store.last))
			assert_eq(c.app.meta:level_to_play(), 4)
			c.run(3)
			assert_eq(c.app.ui.popup, nil, "and it is not asked again")
		end)
	end)

	it("'not now' keeps playing and pauses the upload", function()
		with_account({ welcomed = true, setup = damaged_account }, function(c, m)
			m.google_next = { sub = "g1", email = "a@gmail.com" }
			auth.sign_in_google(function() end)
			cloud.on_signed_in()
			c.run(3)
			assert_eq(c.app.ui.popup, "cloud_choice")
			wtap(c, "cancel")
			c.run(0.6)
			assert_eq(c.app.ui.popup, nil)
			assert_eq(cloud.status().status, "paused")
			assert_eq(c.app.meta:level_to_play(), 4)
			assert_eq(m.puts, 0)
		end)
	end)

	it("closing with the corner button is the same as 'not now'", function()
		with_account({ welcomed = true, setup = damaged_account }, function(c, m)
			m.google_next = { sub = "g1", email = "a@gmail.com" }
			auth.sign_in_google(function() end)
			cloud.on_signed_in()
			c.run(3)
			wtap(c, "close")
			c.run(0.6)
			assert_eq(cloud.status().status, "paused")
			assert_eq(m.puts, 0)
			assert_eq(c.app.meta:level_to_play(), 4)
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

describe("settings: the way in", function()
	it("shows a guest one clear sign-in button (it opens the account window) and no save code rows", function()
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			with_account({ language = lang, welcomed = true }, function(c)
				open(c, "settings")
				local expect = ({ en = "Sign in or create account", ru = "Войти или создать аккаунт", ko = "로그인 / 회원가입" })[lang]
				assert_true(has(c, expect), lang .. ": " .. G.dump(c.town))
				assert_true(c.app.ui.popup_targets.account ~= nil, "the button is there")
				assert_true(c.app.ui.popup_targets.code_copy == nil and c.app.ui.popup_targets.code_enter == nil,
					"the save code rows are hidden")
				wtap(c, "account")
				c.run(0.6)
				assert_eq(c.app.ui.popup, "account")
				assert_true(c.app.ui.popup_targets.google ~= nil and c.app.ui.popup_targets.create ~= nil)
			end)
		end
	end)

	it("five taps on the version show the save code rows, five more hide them", function()
		with_account({ welcomed = true }, function(c)
			open(c, "settings")
			for _ = 1, 4 do wtap(c, "version") end
			assert_true(c.app.ui.popup_targets.code_copy == nil, "four taps are not enough")
			wtap(c, "version")
			c.run(0.5)
			assert_true(c.app.ui.popup_targets.code_copy ~= nil and c.app.ui.popup_targets.code_enter ~= nil)
			assert_true(c.app.ui.popup_targets.reset ~= nil and c.app.ui.popup_targets.account ~= nil)
			for _ = 1, 5 do wtap(c, "version") end
			c.run(0.5)
			assert_true(c.app.ui.popup_targets.code_copy == nil)
		end)
	end)

	it("shows a signed-in player a row with the account, not the sign-in button", function()
		with_account({ welcomed = true, language = "en" }, function(c, m)
			m.google_next = { sub = "g9", email = "me@gmail.com" }
			auth.sign_in_google(function() end)
			c.run(1)
			open(c, "settings")
			assert_true(has(c, "Account:"), G.dump(c.town))
			assert_false(has(c, "Sign in or create account"))
			assert_true(c.app.ui.popup_targets.account ~= nil)
		end)
	end)
end)

describe("account_gui cleanup", function()
	it("leaves no provider and no cloud state behind for the next test file", function()
		require("client.cloud").reset()
		require("client.services.auth").set_provider(nil)
	end)
end)
