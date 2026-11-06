-- The text layout audit (tests/client/layout_audit.lua) over every window and screen of the game, in every
-- language, in the window shapes the game meets and with the worst numbers and names: no text sticks out of
-- its button, card, pill or window, none is smaller than 15 px, none lies over another one.
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
	infinite = function(app) H.win(app, 30); app.meta:grant({ infinite_minutes = 90 }, "test", app.now()); app.commit("test") end,
	late = function(app) H.win(app, 99); app.meta:_change("test_rich", { { "coins", 1234567 - app.meta:coins() } }); app.commit("test") end,
	fresh = function() end,
}

-- town windows: {name, params, setup name}
local CASES = {
	{ "start" }, { "start", nil, "rich" }, { "start", nil, "nolives" }, { "start", nil, "late" }, { "start", nil, "fresh" },
	{ "lives" }, { "lives", nil, "rich" }, { "lives", nil, "nolives" }, { "lives", nil, "infinite" },
	{ "shop", { tab = "boosters" } }, { "shop", { tab = "boosters" }, "rich" }, { "shop", { tab = "boosters" }, "late" },
	{ "shop", { tab = "coins" } }, { "shop", { tab = "coins" }, "rich" }, { "shop", { tab = "coins" }, "nolives" },
	{ "settings" }, { "settings", nil, "fresh" }, { "jukebox" }, { "jukebox", nil, "late" },
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
		local view = lw.result(meta, res, { score = 99999999, moves_at_win = 99, stars = 3 }, c.app.now())
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
	{ "result", "four" }, { "result", "norefund" },
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
