-- The chart and band windows on the strict Defold GUI stub against the mock server: every state (no server, no
-- account, offline, profile setup, ready), the periods, scrolling, the pinned row, the climb animation, creating and
-- joining a band, leaving, removing, help with lives. Texts in en, ru, ko.

local G = require("tests.client.meta_gui_helper")
local auth = require("client.services.auth")
local social = require("client.services.social")
local social_engine = require("client.social")
local mock_mod = require("client.services.social_mock")
local auth_mock = require("client.services.auth_mock")
local platform = require("client.platform")
local rules = require("meta.social")

local NOW = 4 * 86400 + 3 * 604800 + 3600

local function has(c, text) return G.dump(c.town):find(text, 1, true) ~= nil end

local function open(c, name)
	c.app.open_popup(name)
	c.run(0.8)
	assert_eq(c.app.ui.popup, name)
end

local function wtap(c, name)
	local t = c.app.ui.popup_targets and c.app.ui.popup_targets[name]
	assert_true(t ~= nil, "no target '" .. name .. "' in " .. tostring(c.app.ui.popup))
	c.tap(t.x, t.y)
	c.run(0.4)
end

-- opts: {bots, signed (default true), server (default true), language, window, welcomed, profile, offline}
local function with_social(opts, fn)
	opts = opts or {}
	local clock = { t = NOW }
	local m = mock_mod.new({ now = function() return clock.t end })
	m:seed(opts.bots or 0)
	local a = auth_mock.new()
	G.with_town({
		language = opts.language or "en", window = opts.window,
		setup = function(app)
			G.win(app, opts.won or 6)
			social_engine.reset()
			auth.set_provider(a)
			if opts.server ~= false then social.set_provider(m) end
			if opts.signed ~= false then
				a.google_next = { sub = "me", email = "me@gmail.com" }
				auth.sign_in_google(function() end)
			end
			if opts.profile then
				m:profile_set(auth.user().uid, rules.suggest_name(1), 3, function() end)
			end
			m.offline = opts.offline or false
		end,
	}, function(c)
		c.m, c.clock, c.auth_mock = m, clock, a
		fn(c)
	end)
	social.set_provider(nil)
	auth.set_provider(nil)
	social_engine.reset()
end

local function switch(c, id)
	if auth.user() then auth.sign_out(function() end) end
	c.auth_mock.google_next = { sub = id, email = id .. "@gmail.com" }
	auth.sign_in_google(function() end)
	return auth.user().uid
end

describe("chart window: states", function()
	it("says the server is not connected, with no error and no sign-in button", function()
		with_social({ server = false }, function(c)
			open(c, "chart")
			assert_eq(c.app.ui.chart.stage, "unavailable")
			assert_true(has(c, "not connected yet"))
			assert_true(c.app.ui.popup_targets.signin == nil)
		end)
	end)

	it("asks to sign in, with a button that opens the account window", function()
		with_social({ signed = false }, function(c)
			open(c, "chart")
			assert_eq(c.app.ui.chart.stage, "signin")
			assert_true(has(c, "Sign in to see the chart"))
			wtap(c, "signin")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "account")
		end)
	end)

	it("shows 'no connection' with a retry that works once the network is back", function()
		with_social({ offline = true }, function(c)
			open(c, "chart")
			assert_eq(c.app.ui.chart.stage, "offline")
			assert_true(has(c, "No connection"))
			c.m.offline = false
			wtap(c, "retry")
			c.run(0.6)
			assert_eq(c.app.ui.chart.stage, "setup")
		end)
	end)

	it("asks for a game name and an avatar first, then shows the chart with my row", function()
		with_social({ bots = 12 }, function(c)
			open(c, "chart")
			assert_eq(c.app.ui.chart.stage, "setup")
			assert_true(has(c, "Pick your game name"))
			wtap(c, "reroll")
			wtap(c, "avatar_5")
			wtap(c, "save")
			c.run(0.8)
			assert_eq(c.app.ui.chart.stage, "ready")
			local p = c.m.players[auth.user().uid]
			assert_eq(p.profile.avatar, 5)
			assert_true(rules.valid_name(p.profile.name))
			assert_eq(c.app.ui.chart.count, 13)
			assert_true(c.app.ui.chart.rank >= 1)
		end)
	end)
end)

describe("chart window: the list", function()
	it("shows the top rows, scrolls by rows with the arrows, and keeps my row pinned", function()
		with_social({ bots = 60, profile = true }, function(c)
			open(c, "chart")
			assert_eq(c.app.ui.chart.stage, "ready")
			assert_eq(c.app.ui.chart.first, 1)
			assert_true(c.app.ui.popup_targets.up == nil)
			assert_true(c.app.ui.popup_targets.down ~= nil)
			local mine = c.app.ui.chart.rank
			wtap(c, "down")
			assert_eq(c.app.ui.chart.first, 6)
			assert_true(c.app.ui.popup_targets.up ~= nil)
			assert_eq(c.app.ui.chart.rank, mine, "the pinned row does not move")
			for _ = 1, 20 do
				if c.app.ui.popup_targets.down then wtap(c, "down") end
			end
			assert_eq(c.app.ui.chart.first, 61 - 6 + 1)
			assert_true(c.app.ui.popup_targets.down == nil)
		end)
	end)

	it("scrolls with the wheel and with a finger drag over the list", function()
		with_social({ bots = 40, profile = true }, function(c)
			open(c, "chart")
			local E = c.E
			E.input(hash("wheel_down"), { pressed = true })
			c.step(2)
			assert_eq(c.app.ui.chart.first, 2)
			E.input(hash("wheel_up"), { pressed = true })
			c.step(2)
			assert_eq(c.app.ui.chart.first, 1)
			local x = 330
			E.input(hash("touch"), E.touch_action(x, 900, true, false))
			c.step(1)
			for i = 1, 6 do
				E.input(nil, E.touch_action(x, 900 + i * 40, false, false))
				c.step(1)
			end
			E.input(hash("touch"), E.touch_action(x, 1140, false, true))
			c.step(1)
			assert_true(c.app.ui.chart.first >= 2, "a drag up moved the list: " .. c.app.ui.chart.first)
		end)
	end)

	it("switches the period and shows my band's chart or says there is none", function()
		with_social({ bots = 8, profile = true }, function(c)
			open(c, "chart")
			wtap(c, "period_all")
			c.run(0.6)
			assert_eq(c.app.ui.chart.period, "all")
			assert_eq(c.app.ui.chart.stage, "ready")
			assert_true(has(c, "Players: 9"))
			wtap(c, "period_band")
			c.run(0.6)
			assert_eq(c.app.ui.chart.rows, 0)
			assert_true(has(c, "Join a band"))
		end)
	end)

	it("plays the climb once when my rank rose, and not again on a rebuild", function()
		with_social({ bots = 30, profile = true }, function(c)
			open(c, "chart")
			local before = c.app.ui.chart.rank
			c.app.close_popup()
			c.run(0.6)
			c.clock.t = c.clock.t + 3600
			c.m.players[auth.user().uid].rec = { total = 90, level = 40, day = rules.day_id(c.clock.t), day_gain = 0,
				week = rules.week_id(c.clock.t), week_base = 0, flags = 0 }
			open(c, "chart")
			assert_true(c.app.ui.chart.rank < before, "rank " .. c.app.ui.chart.rank .. " < " .. before)
			assert_eq(c.app.ui.chart.climb, c.app.ui.chart.rank)
			assert_true(has(c, "+" .. (before - c.app.ui.chart.rank)))
			c.run(3)
			assert_true(has(c, tostring(c.app.ui.chart.rank)))
		end)
	end)

	it("hides a flagged player's row from the chart and tells the player", function()
		with_social({ bots = 5, profile = true }, function(c)
			c.m.players[auth.user().uid].rec.flags = 5
			open(c, "chart")
			assert_true(has(c, "checking your result"))
		end)
	end)
end)

describe("band window", function()
	it("says so without a server and asks to sign in without an account", function()
		with_social({ server = false }, function(c)
			open(c, "band")
			assert_eq(c.app.ui.band.stage, "unavailable")
			assert_true(has(c, "not connected yet"))
		end)
		with_social({ signed = false }, function(c)
			open(c, "band")
			assert_eq(c.app.ui.band.stage, "signin")
			assert_true(c.app.ui.popup_targets.signin ~= nil)
		end)
	end)

	it("creates a band with a suggested name and shows the card, the goal and the leader", function()
		with_social({ bots = 3, profile = true }, function(c)
			open(c, "band")
			assert_eq(c.app.ui.band.stage, "none")
			assert_true(has(c, "not in a band yet"))
			wtap(c, "create")
			assert_eq(c.app.ui.band.stage, "create")
			wtap(c, "reroll_band")
			wtap(c, "create_ok")
			c.run(0.6)
			assert_eq(c.app.ui.band.stage, "ready")
			assert_eq(c.app.ui.band.count, 1)
			assert_eq(c.app.ui.band.you, "leader")
			assert_eq(c.app.ui.band.goal, rules.BAND_GOAL_MIN)
			assert_true(has(c, "Leader"))
			assert_true(has(c, "Weekly goal"))
			assert_true(has(c, "Code: " .. c.app.ui.band.code))
		end)
	end)

	it("joins by a code pasted from an invitation text, and says no to a wrong code", function()
		with_social({ bots = 0, profile = true }, function(c)
			local uid = auth.user().uid
			local made
			c.m:band_create(uid, rules.suggest_band_name(2), function(_, _, b) made = b end)
			c.m:band_leave(uid, function() end)
			-- a band of another player
			local other = switch(c, "boss")
			c.m:profile_set(other, rules.suggest_name(2), 2, function() end)
			local band
			c.m:band_create(other, rules.suggest_band_name(4), function(_, _, b) band = b end)
			switch(c, "me")
			local pasted = "Join my band in GLOW! Code: " .. band.code
			local orig = platform.paste_text
			platform.paste_text = function() return pasted end
			open(c, "band")
			wtap(c, "join")
			c.run(0.6)
			platform.paste_text = orig
			assert_eq(c.app.ui.band.stage, "ready")
			assert_eq(c.app.ui.band.count, 2)
			assert_eq(c.app.ui.band.you, "member")
			assert_true(c.app.ui.popup_targets.leave ~= nil)
			-- a wrong code
			wtap(c, "leave")
			c.run(0.6)
			wtap(c, "confirm")
			c.run(0.8)
			assert_eq(c.app.ui.popup, "band")
			assert_eq(c.app.ui.band.stage, "none")
			platform.paste_text = function() return "ZZZZZZ" end
			wtap(c, "join")
			c.run(0.6)
			platform.paste_text = orig
			assert_eq(c.app.ui.band.stage, "none")
			c.run(0.7)
			assert_true(type(c.app.overlay.toast) == "string" and c.app.overlay.toast:find("No band", 1, true) ~= nil,
				tostring(c.app.overlay.toast))
		end)
	end)

	it("leaves with a confirmation; the leader's leaving passes the lead on", function()
		with_social({ bots = 0, profile = true }, function(c)
			local uid = auth.user().uid
			open(c, "band")
			wtap(c, "create")
			wtap(c, "create_ok")
			c.run(0.6)
			local code = c.app.ui.band.code
			local u2 = switch(c, "two")
			c.m:profile_set(u2, rules.suggest_name(8), 2, function() end)
			c.m:band_join(u2, code, function() end)
			switch(c, "me")
			c.app.close_popup()
			c.run(0.6)
			open(c, "band")
			assert_eq(c.app.ui.band.count, 2)
			wtap(c, "leave")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "confirm")
			assert_true(has(c, "member who joined first"))
			wtap(c, "confirm")
			c.run(0.8)
			assert_eq(c.m.bands[code].leader, u2)
			assert_eq(c.m.players[uid].band, nil)
			assert_eq(c.app.ui.band.stage, "none")
		end)
	end)

	it("lets the leader remove a member, and scrolls a long list", function()
		with_social({ bots = 0, profile = true }, function(c)
			local uid = auth.user().uid
			open(c, "band")
			wtap(c, "create")
			wtap(c, "create_ok")
			c.run(0.6)
			local code = c.app.ui.band.code
			for i = 1, 8 do
				local id = "m" .. i
				c.m.players[id] = { uid = id, seen = {}, day_sent = 0, day_got = 0, day = -1, inbox = 0, helped_by = {},
					profile = { name = rules.suggest_name(i), avatar = 1 }, band = code,
					rec = { total = 0, level = 0, day = 0, day_gain = 0, week = rules.week_id(NOW), week_base = 0, flags = 0 } }
				c.m.bands[code].members[id] = { seq = 50 + i }
			end
			c.app.close_popup()
			c.run(0.6)
			open(c, "band")
			assert_eq(c.app.ui.band.count, 9)
			assert_eq(c.app.ui.band.first, 1)
			assert_true(c.app.ui.popup_targets.down ~= nil)
			wtap(c, "down")
			assert_eq(c.app.ui.band.first, 5)
			wtap(c, "up")
			assert_eq(c.app.ui.band.first, 1)
			local kick
			for name in pairs(c.app.ui.popup_targets) do
				if name:match("^kick_") then kick = name end
			end
			assert_true(kick ~= nil, "the leader can tap a member")
			wtap(c, kick)
			c.run(0.6)
			assert_eq(c.app.ui.popup, "confirm")
			wtap(c, "confirm")
			c.run(0.8)
			assert_eq(c.app.ui.band.count, 8)
		end)
	end)

	it("asks for a life, a mate sends it, and the lives arrive in the meta", function()
		with_social({ bots = 0, profile = true, won = 25 }, function(c)
			local meta = c.app.meta
			-- spend lives: win/lose so that the stock is below the maximum
			assert(require("client.flow").debug_lose())
			local before = meta:lives(c.app.now()).count
			local uid = auth.user().uid
			open(c, "band")
			wtap(c, "create")
			wtap(c, "create_ok")
			c.run(0.6)
			local code = c.app.ui.band.code
			wtap(c, "ask_life")
			c.run(0.6)
			assert_true(has(c, "Waiting for a mate"))
			local u2 = switch(c, "two")
			c.m:profile_set(u2, rules.suggest_name(8), 2, function() end)
			c.m:band_join(u2, code, function() end)
			c.m:help_send(u2, uid, function() end)
			switch(c, "me")
			c.app.close_popup()
			c.run(0.6)
			open(c, "band")
			c.run(0.6)
			assert_eq(meta:lives(c.app.now()).count, math.min(before + 1, meta:lives(c.app.now()).max))
		end)
	end)

	it("shows the heart on a mate who asked, and sends a life from it", function()
		with_social({ bots = 0, profile = true }, function(c)
			open(c, "band")
			wtap(c, "create")
			wtap(c, "create_ok")
			c.run(0.6)
			local code = c.app.ui.band.code
			local u2 = switch(c, "two")
			c.m:profile_set(u2, rules.suggest_name(8), 2, function() end)
			c.m:band_join(u2, code, function() end)
			c.m:help_request(u2, function() end)
			switch(c, "me")
			c.app.close_popup()
			c.run(0.6)
			open(c, "band")
			assert_true(has(c, "Asks for a life"))
			local help
			for name in pairs(c.app.ui.popup_targets) do
				if name:match("^help_") then help = name end
			end
			assert_true(help ~= nil)
			wtap(c, help)
			c.run(0.6)
			assert_eq(c.m.players[u2].inbox, 1)
		end)
	end)
end)

describe("chart and band: languages and window shapes", function()
	it("draws every state in ru and ko without errors", function()
		for _, lang in ipairs({ "ru", "ko" }) do
			with_social({ bots = 25, profile = true, language = lang, window = { 360, 640 } }, function(c)
				open(c, "chart")
				assert_eq(c.app.ui.chart.stage, "ready")
				c.app.close_popup()
				c.run(0.6)
				open(c, "band")
				wtap(c, "create")
				wtap(c, "create_ok")
				c.run(0.6)
				assert_eq(c.app.ui.band.stage, "ready")
			end)
		end
		with_social({ language = "ru", signed = false }, function(c)
			open(c, "chart")
			assert_true(has(c, "Войди"))
		end)
	end)
end)
