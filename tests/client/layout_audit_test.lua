-- The text layout audit (tests/client/layout_audit.lua) over every window and screen of the game, in every
-- language, in the window shapes the game meets and with the worst numbers and names: no text sticks out of
-- its button, card, pill or window, none is smaller than 15 px, none lies over another one, and a small caption in the
-- soft colour keeps 4.5:1 against the plate it is printed on.
-- New texts and windows get caught here: add a case to CASES / LEVEL_CASES for a new window.

local H = require("tests.client.meta_gui_helper")
local G = require("tests.client.level_gui_helper")
local A = require("tests.client.layout_audit")
local config = require("meta.config")
local i18n = require("client.i18n")

local LANGS = {}
for _, l in ipairs({ "en", "ru", "ko" }) do
	if i18n.normalize(l) == l then LANGS[#LANGS + 1] = l end
end
local SIZES = { { 720, 1280 }, { 1920, 970 }, { 1280, 720 }, { 390, 844 }, { 360, 640 } }

local function rich(app)
	H.win(app, 13)
	app.meta:_change("test_rich", { { "coins", 9999999 - app.meta:coins() } })
	app.commit("test")
end

-- the states of the meta a window is shown in (case[3] of CASES): numbers of different length, no lives, unlimited lives, late game
local SETUPS = {
	rich = rich,
	nolives = function(app, c)
		H.win(app, 20)
		c.E.clock = c.E.clock + 3 * 3600
		for _ = 1, 5 do assert(require("client.flow").debug_lose()) end
		app.commit("test")
	end,
	somelives = function(app, c) -- two lives lost: the "3/5" pill, the refill button and its hint
		H.win(app, 20)
		c.E.clock = c.E.clock + 3 * 3600
		for _ = 1, 2 do assert(require("client.flow").debug_lose()) end
		app.commit("test")
	end,
	infinite = function(app) H.win(app, 30); app.meta:grant({ infinite_minutes = 90 }, "test", app.now()); app.commit("test") end,
	late = function(app) H.win(app, 99); app.meta:_change("test_rich", { { "coins", 1234567 - app.meta:coins() } }); app.commit("test") end,
	fresh = function() end,
}

-- accounts (WP-10): the mock provider and a signed-in player, with the longest names the forms allow
local function acct_env(app, bound_uid)
	local auth = require("client.services.auth")
	local cloud = require("client.cloud")
	local m = require("client.services.auth_mock").new()
	auth.set_provider(m)
	local file = { data = bound_uid and { v = 1, uid = bound_uid, signed_out = true } or nil }
	cloud.init({ app = app, auth = auth, now = function() return app.now() end, seed = function() return 5 end,
		binding = { read = function() return file.data end, write = function(t) file.data = t; return true end } })
	return m, auth, cloud
end

SETUPS.acct_guest = function(app) rich(app); acct_env(app) end
SETUPS.acct_id = function(app)
	rich(app)
	local m, auth, cloud = acct_env(app)
	m.form_next = { id = "a_login_of_twenty_ch", password = "secret123" }
	auth.password_form("register", {}, function() end)
	m.form_next = { email = "a_really_long_address_name@example-domain.com" }
	auth.link_email_form({}, function() end)
	cloud.on_signed_in()
end
SETUPS.acct_id_nomail = function(app) -- an ID account with no e-mail yet: the warning and the hint how to fix it
	rich(app)
	local m, auth, cloud = acct_env(app)
	m.form_next = { id = "a_login_of_twenty_ch", password = "secret123" }
	auth.password_form("register", {}, function() end)
	cloud.on_signed_in()
end
SETUPS.acct_google = function(app)
	rich(app)
	local m, auth, cloud = acct_env(app)
	m.google_next = { sub = "g1", email = "a_really_long_address_name@example-domain.com" }
	auth.sign_in_google(function() end)
	cloud.on_signed_in()
end
local function with_decision(bound_uid)
	return function(app)
		rich(app)
		local m, auth, cloud = acct_env(app, bound_uid)
		local savecode = require("meta.savecode")
		local other = app.meta:serialize()
		m.accounts.u001 = { uid = "u001", kind = "google", google_sub = "g1", verified = true, email = "a@gmail.com" }
		-- Only what client/cloud.lua does not settle by itself opens the window: a damaged account save (its older
		-- copy is readable: both cards, three buttons), and another account's save here when this account has none.
		if not bound_uid then m.docs.u001 = { code = "GLOW1-garbage", previous = savecode.encode(other) } end
		app.reset_save(7, app.now())
		rich(app)
		m.google_next = { sub = "g1", email = "a@gmail.com" }
		auth.sign_in_google(function() end)
		cloud.on_signed_in()
		assert(cloud.decision(), "the audit needs a decision")
	end
end
SETUPS.cloud_choose = with_decision(nil)
SETUPS.cloud_foreign = with_decision("u999")

-- chart and bands (WP-11): the mock server, the longest word names, a full band
local function soc_env(app, opts)
	opts = opts or {}
	local auth = require("client.services.auth")
	local social = require("client.services.social")
	local rules = require("meta.social")
	local now = 4 * 86400 + 3 * 604800 + 3600
	local m = require("client.services.social_mock").new({ now = function() return now end })
	m:seed(opts.bots or 0)
	local a = require("client.services.auth_mock").new()
	auth.set_provider(a)
	require("client.social").reset()
	if opts.server ~= false then social.set_provider(m) end
	if opts.signed ~= false then
		a.google_next = { sub = "me", email = "me@gmail.com" }
		auth.sign_in_google(function() end)
	end
	if opts.profile then
		m:profile_set(auth.user().uid, { a = 15, n = 12, d = 99 }, 12, function() end) -- the longest words
	end
	return m, auth.user() and auth.user().uid, rules
end
SETUPS.soc_unavailable = function(app) rich(app); soc_env(app, { server = false }) end
SETUPS.soc_signin = function(app) rich(app); soc_env(app, { signed = false }) end
SETUPS.soc_setup = function(app) rich(app); soc_env(app, {}) end
SETUPS.soc_chart = function(app) rich(app); soc_env(app, { bots = 120, profile = true }) end
SETUPS.soc_none = function(app) rich(app); soc_env(app, { bots = 3, profile = true }) end
SETUPS.soc_band = function(app)
	rich(app)
	local m, uid, rules = soc_env(app, { bots = 0, profile = true })
	m:band_create(uid, { a = 16, n = 13 }, function() end)
	local code = m.players[uid].band
	for i = 1, rules.BAND_MAX - 1 do
		local id = "m" .. i
		m.players[id] = { uid = id, seen = {}, day_sent = 0, day_got = 0, day = -1, inbox = 0, helped_by = {}, help_req = i % 3 == 0,
			profile = { name = { a = 9, n = 12, d = 99 }, avatar = i % 12 + 1 }, band = code,
			rec = { total = 99, level = 40, day = 0, day_gain = 0, week = rules.week_id(4 * 86400 + 3 * 604800 + 3600), week_base = 0, flags = 0 } }
		m.bands[code].members[id] = { seq = 10 + i }
	end
end

-- town windows: {name, params, setup name}
local CASES = {
	{ "start" }, { "start", nil, "rich" }, { "start", nil, "nolives" }, { "start", nil, "late" }, { "start", nil, "fresh" },
	{ "lives" }, { "lives", nil, "rich" }, { "lives", nil, "fresh" }, { "lives", nil, "somelives" }, { "lives", nil, "nolives" }, { "lives", nil, "infinite" },
	{ "shop", { tab = "boosters" } }, { "shop", { tab = "boosters" }, "rich" }, { "shop", { tab = "boosters" }, "late" },
	{ "shop", { tab = "boosters" }, "fresh" }, -- a new player: one closed pack beside the lives card, the line "N more" under both
	{ "shop", { tab = "coins" } }, { "shop", { tab = "coins" }, "rich" }, { "shop", { tab = "coins" }, "nolives" },
	{ "settings" }, { "settings", nil, "fresh" },
	{ "account", nil, "acct_guest" }, { "account", { mode = "choice" }, "acct_guest" }, { "account", nil, "acct_id" }, { "account", nil, "acct_id_nomail" },
	{ "account", nil, "acct_google" }, { "cloud_choice", nil, "cloud_choose" }, { "cloud_choice", nil, "cloud_foreign" }, { "jukebox" }, { "jukebox", nil, "late" },
	{ "chart", nil, "soc_unavailable" }, { "chart", nil, "soc_signin" }, { "chart", nil, "soc_setup" }, { "chart", nil, "soc_chart" },
	{ "band", nil, "soc_unavailable" }, { "band", nil, "soc_signin" }, { "band", nil, "soc_setup" }, { "band", nil, "soc_none" },
	{ "band", nil, "soc_band" },
	{ "concert", { district = "cafe" } }, { "concert", { district = "cafe" }, "late" },
	{ "chest", { kind = "level", level_id = 10, chest = { coins = 9999, boosters = { "stick", "riff", "crossfader" }, infinite_minutes = 15 } } },
	{ "gift", { id = "riff" } }, { "gift", { id = "crossfader" } },
	{ "confirm", { title = { key = "settings.reset_title" }, text = { key = "settings.reset_text" } } },
}

local function run_cases(label, sizes, langs, fn, cases)
	local bad = {}
	for _, lang in ipairs(langs) do
		for _, w in ipairs(sizes) do
			for _, case in ipairs(cases) do
				fn(lang, w, case, function(name, list)
					for _, m in ipairs(list) do bad[#bad + 1] = string.format("%s %s %s %dx%d: %s", label, name, lang, w[1], w[2], m) end
				end)
			end
		end
	end
	return bad
end

local function fail_on(bad, what)
	-- the same message repeated in several window shapes is listed once with the shapes it appears in
	assert_eq(#bad == 0 and "" or ("\n" .. table.concat(bad, "\n")), "", what)
end

describe("text layout audit: town windows", function()
	it("keeps every text inside its box and window, in every language and window shape", function()
		local bad = run_cases("town", SIZES, LANGS, function(lang, w, case, report)
			H.with_town({ language = lang, window = w, setup = function(app, c) (SETUPS[case[3] or "default"] or function(a) H.win(a, 13) end)(app, c) end }, function(c)
				c.app.open_popup(case[1], case[2])
				c.run(0.6)
				local name = case[1] .. (case[2] and case[2].tab and ("/" .. case[2].tab) or "") .. (case[3] and (" " .. case[3]) or "")
				assert_true(#A.texts(c, { window = true }) >= 1, name .. ": no texts measured")
				report(name, A.check(c, { window = true }))
			end)
			require("client.cloud").reset()
			require("client.services.auth").set_provider(nil)
			require("client.services.social").set_provider(nil)
			require("client.social").reset()
		end, CASES)
		fail_on(bad, "texts out of their boxes")
	end)
end)

-- level windows: opened on the level screen
local function open_level(c, name, extra)
	local l = c.hud.self.l
	local meta = c.app.meta
	local lw = require("client.level_windows")
	if name == "pause" then
		return l:open("pause", { level_id = 99, view = { at_stake = true, leave = "loss", lines = {
			{ key = "pause.warn_loss" }, { key = "continue.life_warning" }, { key = "continue.streak_warning", vars = { n = 12 } } } } })
	elseif name == "moves" then
		local boosters = {}
		for i = 1, 4 do boosters[i] = { id = config.boosters[i].id, count = 99 } end
		return l:open("moves", { ctx = l.ctx, view = { stuck = false, run = {}, coins = 9999999, at_stake = true, ad = true, ad_moves = 5,
			lines = { { key = "continue.life_warning" }, { key = "continue.streak_warning", vars = { n = 12 } } },
			offer = { k = 3, price = 9999, moves = 5, riff = true, affordable = true }, boosters = boosters } })
	elseif name == "defeat" then
		local goals, totals = {}, {}
		for i = 1, 3 do goals[i] = l.hud.goal_defs[1]; totals[i] = 30 end
		local view = lw.defeat(meta, { life_lost = true, streak_lost = 7, fails = 3 }, { goals = { 20, 20, 20 } }, goals, totals, c.app.now())
		view.no_lives = extra == "nolives"
		return l:open("defeat", { view = view, level_id = 99 })
	elseif name == "result" then
		local res = { level_id = 100, stars = 3, coins = 9999999, streak = 12, unlocked = { "crossfader", "remix" }, next_level = 101 }
		if extra == "concert" then -- the longest lines: a concert paying super stars on a new record, with a better one kept
			res.stars, res.best, res.gained, res.concert, res.super_gained, res.new_best_score = 2, 3, 1, true, 99, true
		end
		local view = lw.result(meta, res, { score = extra == "concert" and 21000 or 99999999, moves_at_win = 99, stars = 3 }, c.app.now())
		if extra == "concert" then assert_true(view.scale ~= nil and view.concert, "the audit must draw the score scale and the super stars") end
		local refund
		if extra ~= "norefund" then
			refund = {}
			for i = 1, (extra == "four" and 4 or 3) do refund[config.boosters[i].id] = 1 end
		end
		return l:open("result", { view = view, refund = refund, level_id = 100 })
	elseif name == "booster_buy" then
		return l:open("booster_buy", { id = config.boosters[extra == "last" and #config.boosters or 1].id })
	end
	return l:open(name, { tab = "boosters" })
end

local LEVEL_CASES = {
	{ "pause" }, { "moves" }, { "defeat" }, { "defeat", "nolives" },
	{ "result", "four" }, { "result", "norefund" }, { "result", "concert" },
	{ "booster_buy", "first" }, { "booster_buy", "last" }, { "shop" },
}

describe("text layout audit: level windows", function()
	it("keeps every text inside its box and window, in every language and window shape", function()
		local bad = run_cases("level", SIZES, LANGS, function(lang, w, case, report)
			G.with_level({ level = 13, language = lang, window = w }, function(c)
				assert_true(c.hud:ctx(open_level, c, case[1], case[2]) ~= nil, case[1])
				c.run(0.6)
				assert_true(#A.texts(c, { window = true }) >= 1, case[1] .. ": no texts measured")
				report(case[1] .. (case[2] and ("/" .. case[2]) or ""), A.check(c, { window = true }))
			end)
		end, LEVEL_CASES)
		fail_on(bad, "texts out of their boxes")
	end)
end)

describe("text layout audit: screens", function()
	it("keeps the texts of the town screen apart and inside their plates", function()
		local bad = run_cases("town screen", SIZES, LANGS, function(lang, w, case, report)
			H.with_town({ language = lang, window = w, setup = function(app) if case then rich(app) else H.win(app, 13) end end }, function(c)
				c.run(1)
				report(case and "rich" or "plain", A.check(c))
			end)
		end, { false, true })
		fail_on(bad, "town screen texts")
	end)

	it("keeps the texts of the level HUD apart and inside their plates", function()
		local bad = run_cases("level hud", SIZES, LANGS, function(lang, w, level, report)
			G.with_level({ level = level, language = lang, window = w }, function(c)
				c.run(1)
				report("level " .. level, A.check(c))
			end)
		end, { 1, 3, 13, 24, 40, 60, 90 })
		fail_on(bad, "level HUD texts")
	end)
end)

describe("text layout audit: the tool itself", function()
	it("counts wrapped lines with the real font advances", function()
		assert_eq(A.wrap("body", "a b", 1000), 1)
		assert_eq(A.wrap("body", "hello world", 20), 2)
		assert_eq(A.wrap("body", "one\ntwo", 1000), 2)
	end)

	it("sees a text that is too wide for its button and for the window", function()
		H.with_town({ language = "en", setup = function(app) H.win(app, 13) end }, function(c)
			c.app.open_popup("settings")
			c.run(0.6)
			assert_same(A.check(c, { window = true }), {})
			local victim
			for _, r in ipairs(A.texts(c, { window = true })) do
				if r.box and not victim then victim = r.node end
			end
			victim.text = victim.text .. " WWWWWWWWWWWWWWWWWWWWWWWWWWWW"
			local list = A.check(c, { window = true })
			assert_true(#list >= 1, "the audit did not see the long text")
		end)
	end)

	it("measures the WCAG contrast of two colours", function()
		assert_near(A.contrast(1, 1, 1, 0, 0, 0), 21, 1e-9)
		assert_near(A.contrast(0, 0, 0, 1, 1, 1), 21, 1e-9)
		assert_near(A.contrast(0.3, 0.2, 0.4, 0.3, 0.2, 0.4), 1, 1e-9)
		-- the producer's two inks on white: the main text 12.6:1, the soft caption at least 4.5:1 on every plate of the game
		assert_near(A.contrast(0x3D / 255, 0x28 / 255, 0x5D / 255, 1, 1, 1), 12.65, 0.01)
	end)

	it("sees a soft caption on a plate that is too dark for it", function()
		H.with_town({ language = "en", setup = function(app) H.win(app, 13) end }, function(c)
			c.app.open_popup("settings")
			c.run(0.6)
			assert_same(A.check(c, { window = true }), {})
			local soft = require("client.ui").color("text_soft")
			local victim
			for _, r in ipairs(A.texts(c, { window = true })) do
				local col = r.node.color
				if not victim and math.abs(col.x - soft.x) < 0.004 and math.abs(col.y - soft.y) < 0.004 and math.abs(col.z - soft.z) < 0.004 then
					victim = r.node
				end
			end
			assert_true(victim ~= nil, "the settings window has a soft caption")
			-- the plate under it as dark as a purple button: no contrast left
			victim.parent.color = vmath.vector4(0.42, 0.2, 0.8, 1)
			local list = A.check(c, { window = true, skip_overlap = true })
			assert_true(#list >= 1, "the audit did not see the dark plate")
			assert_true(list[1]:find("soft caption", 1, true) ~= nil, list[1])
		end)
	end)

	it("the QA bounds the engine would report agree with the audit", function()
		local ui = require("client.gui_qa")
		ui.track = true
		local ok, err = pcall(function()
			H.with_town({ language = "ru", setup = function(app) H.win(app, 13) end }, function(c)
				c.app.open_popup("shop", { tab = "boosters" })
				c.run(0.6)
				ui.out, ui.want = {}, ui.want + 1
				c.step(2)
				local n = 0
				for _, rows in pairs(ui.out) do n = n + #rows end
				assert_true(n > 20, "gui_bounds answered " .. n .. " texts")
			end)
		end)
		ui.track, ui.want, ui.out = false, 0, {}
		if not ok then error(err, 0) end
	end)
end)

describe("text layout audit: overlay", function()
	it("keeps every toast and the modal inside the screen, in every language and window shape", function()
		local keys = {}
		for k in pairs(i18n.STRINGS) do -- sorted below
			if k:sub(1, 6) == "toast." then keys[#keys + 1] = k end
		end
		table.sort(keys)
		assert_true(#keys >= 5, "toast keys")
		local vars = { n = 9999999, name = "WWWWWWWWWW" }
		local bad = run_cases("toast", SIZES, LANGS, function(lang, w, key, report)
			H.with_town({ language = lang, window = w, setup = function(app) H.win(app, 13) end }, function(c)
				c.app.toast_key(key, vars)
				c.run(0.5)
				assert_true(#A.texts(c, { scene = c.overlay.scene }) > 0, "the toast " .. key .. " is not on the screen")
				report(key, A.check(c, { scene = c.overlay.scene }))
			end)
		end, keys)
		fail_on(bad, "toast texts")
	end)
end)

-- The hint of a goal tile (screens/level/hud.lua): one line in a pill under the goals panel. Every kind of goal the levels have,
-- in every language, must read at 18 px or more, inside its pill, and the pill must stay inside the window, off the cells of the
-- board (level 185 is the tallest board: 44 px under the panel) and off the counters of the panel.
describe("text layout audit: goal hints", function()
	local level_hud = require("client.level_hud")
	local link = require("client.level_link")
	local MIN_PX = 18

	local function hud(c) return c.hud.self.l.hud end

	-- shows the hint of tile k and measures the texts of the pill: the problems, the rows
	local function show(c, k)
		local t = c.app.ui.level.targets["goal" .. k]
		assert_true(t ~= nil, "no tap target for goal " .. k)
		c.tap(t.x, t.y)
		c.step(3)
		local root = hud(c).hint_node
		assert_true(root ~= nil, "the tap showed no hint")
		return A.check(c, { root = root }), A.texts(c, { root = root })
	end

	it("keeps the line of every kind of goal inside its pill and readable, in every language", function()
		local first, order = G.first_goal_levels()
		local bad = {}
		for _, lang in ipairs(LANGS) do
			for _, what in ipairs(order) do
				local n, k = first[what][1], first[what][2]
				G.with_level({ level = n, attempt = false, language = lang }, function(c)
					c.run(0.8)
					local problems, rows = show(c, k)
					for _, m in ipairs(problems) do bad[#bad + 1] = string.format("level %d %s %s: %s", n, what, lang, m) end
					if #rows ~= 1 then bad[#bad + 1] = string.format("level %d %s %s: %d texts in the pill", n, what, lang, #rows) end
					for _, r in ipairs(rows) do
						if r.font_px < MIN_PX - 0.01 then
							bad[#bad + 1] = string.format("level %d %s %s: '%s' is only %.1f px tall", n, what, lang, r.text, r.font_px)
						end
						if r.lines ~= 1 then bad[#bad + 1] = string.format("level %d %s %s: the line wraps", n, what, lang) end
					end
				end)
			end
		end
		fail_on(bad, "goal hint texts")
	end)

	it("says a goal that is done, and a colour goal with the biggest number, at a readable size too", function()
		local bus = require("client.bus")
		local bad = {}
		for _, lang in ipairs(LANGS) do
			G.with_level({ level = 178, attempt = false, language = lang }, function(c)
				c.run(0.8)
				bus.publish("level_goal", { index = 1, left = 99999 })
				bus.publish("level_goal", { index = 1, left = 0 })
				c.step(3)
				local problems, rows = show(c, 1)
				for _, m in ipairs(problems) do bad[#bad + 1] = lang .. " done: " .. m end
				for _, r in ipairs(rows) do
					if r.font_px < MIN_PX - 0.01 then bad[#bad + 1] = string.format("%s done: '%s' is only %.1f px", lang, r.text, r.font_px) end
				end
			end)
			-- the longest name of a piece with a number of four digits (a level may ask for a lot)
			G.with_level({ level = 190, attempt = false, language = lang }, function(c) -- three colour goals of 45
				c.run(0.8)
				for k = 1, 3 do
					local problems, rows = show(c, k)
					for _, m in ipairs(problems) do bad[#bad + 1] = string.format("%s 190/%d: %s", lang, k, m) end
					for _, r in ipairs(rows) do
						if r.font_px < MIN_PX - 0.01 then bad[#bad + 1] = string.format("%s 190/%d: '%s' is only %.1f px", lang, k, r.text, r.font_px) end
					end
				end
			end)
		end
		fail_on(bad, "goal hint texts")
	end)

	it("keeps the pill inside every window shape, off the cells and the counters, under the tile it explains", function()
		local bad = {}
		-- 185: the tallest board (7x11, 44 px under the panel); 60: three goals; 178: two goals on a shaped 9x9 board
		for _, lang in ipairs(LANGS) do
			for _, w in ipairs(SIZES) do
				for _, level in ipairs({ 185, 60, 178 }) do
					G.with_level({ level = level, attempt = false, language = lang, window = w }, function(c)
						c.run(0.8)
						local goals = #c.app.ui.level.goals
						for k = 1, goals do
							local what = string.format("level %d %s %dx%d tile %d", level, lang, w[1], w[2], k)
							local problems, rows = show(c, k)
							for _, m in ipairs(problems) do bad[#bad + 1] = what .. ": " .. m end
							for _, r in ipairs(rows) do
								if r.font_px < MIN_PX - 0.01 then bad[#bad + 1] = string.format("%s: '%s' is only %.1f px", what, r.text, r.font_px) end
							end
							local h = hud(c)
							local r, b = h.hint_rect, link.board_rect()
							if r.y0 < b.y1 + 0.5 then bad[#bad + 1] = string.format("%s: the pill (bottom %.1f) covers the cells (top %.1f)", what, r.y0, b.y1) end
							if r.x0 < h.l.safe.x0 - 0.5 or r.x1 > h.l.safe.x1 + 0.5 then bad[#bad + 1] = what .. ": the pill is outside the window" end
							if r.y1 + level_hud.GOAL_HINT_NOTCH > h.l.goals.y0 + level_hud.GOAL_PANEL_EDGE + 0.5 then
								bad[#bad + 1] = what .. ": the pointer is over the counters"
							end
							local x = h:goal_pos(k)
							if math.abs(r.tail_x - x) > 0.5 then bad[#bad + 1] = string.format("%s: the pointer (%.1f) is not under the tile (%.1f)", what, r.tail_x, x) end
						end
					end)
				end
			end
		end
		fail_on(bad, "goal hint places")
	end)
end)
