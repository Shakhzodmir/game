local app = require("client.app")
local bus = require("client.bus")
local save_io = require("client.save_io")
local i18n = require("client.i18n")
local analytics = require("client.services.analytics")
local H = require("tests.meta.helper")

local function boot(backend, lang)
	analytics.init({ strict = true })
	backend = backend or save_io.memory_backend()
	local info = app.init({
		districts = H.districts(),
		store = save_io.new(backend),
		seed = 42,
		now = H.T0,
		clock = function() return H.T0 end,
		sys_language = lang or "en",
	})
	return backend, info
end

describe("client.app", function()
	it("creates a fresh meta and saves it at once", function()
		local backend, info = boot()
		assert_eq(info.source, "fresh")
		assert_eq(backend.writes, 1)
		assert_false(app.meta:dirty())
		assert_true(app.first_launch())
		assert_eq(app.focus_district(), "cafe")
		assert_eq(app.district("jazz").bpm, 96)
	end)

	it("continues from the saved slot on the next launch", function()
		local backend = boot()
		H.win(app.meta, H.T0)
		app.commit("test")
		local _, info = boot(backend)
		assert_eq(info.source, "current")
		assert_eq(app.meta:level_to_play(), 2)
		assert_false(app.first_launch())
	end)

	it("publishes meta_changed only when the revision moved", function()
		boot()
		local sub = bus.subscribe("meta_changed")
		assert_false(app.commit("nothing"))
		assert_eq(sub:pending(), 0)
		app.meta:grant({ coins = 10 }, "test_gift", H.T0)
		assert_true(app.commit("gift"))
		assert_eq(sub:pending(), 1)
		sub:close()
		local econ = 0
		for _, ev in ipairs(analytics.drain()) do
			if ev.name == "economy" and ev.params.reason == "test_gift" then econ = econ + 1 end
		end
		assert_eq(econ, 1)
	end)

	it("applies the language setting from the meta and the system", function()
		boot(nil, "ru-RU")
		assert_eq(i18n.language(), "ru")
		local sub = bus.subscribe({ "language_changed", "settings_changed" })
		assert_true(app.set_setting("language", "en"))
		assert_eq(i18n.language(), "en")
		assert_eq(sub:pending(), 2)
		sub:close()
		local ok, why = app.set_setting("language", "klingon")
		assert_false(ok)
		assert_eq(why, "invalid_value")
		assert_true(app.set_setting("haptics", false))
		assert_false(require("client.platform").haptics)
		app.set_setting("haptics", true)
	end)

	it("tracks the screen and gives a snapshot", function()
		boot()
		app.set_screen("town", { from = "test" })
		assert_eq(app.screen, "town")
		app.set_screen("level", { level = 1 })
		assert_eq(app.prev_screen, "town")
		local snap = app.snapshot()
		assert_eq(snap.screen, "level")
		assert_eq(snap.level, 1)
		assert_eq(snap.coins, 500)
		assert_eq(snap.lives, 5)
		assert_eq(snap.district, "cafe")
		assert_eq(snap.next_task.id, "turntable")
		assert_true(app.is_screen("town"))
		assert_false(app.is_screen("shop"))
	end)

	it("resets the save in debug", function()
		local backend = boot()
		H.win(app.meta, H.T0)
		app.commit("test")
		app.reset_save(9, H.T0)
		assert_eq(app.meta:level_to_play(), 1)
		local cur = backend.read("current")
		assert_true(cur ~= nil)
		local _, info = boot(backend)
		assert_eq(info.source, "current")
		assert_eq(app.meta:level_to_play(), 1)
	end)

	it("hands values between scripts as tickets, once", function()
		local t = app.stash({ big = string.rep("x", 5000) })
		assert_eq(#app.claim(t).big, 5000)
		assert_eq(app.claim(t), nil)
		assert_eq(app.claim("nope"), nil)
		local first = app.stash(1)
		for _ = 1, app.STASH_KEEP + 1 do app.stash(2) end
		assert_eq(app.claim(first), nil) -- never claimed: dropped
	end)

	it("tells a repeated screen request from a new one", function()
		assert_true(app.same_request({ name = "town" }, { name = "town", params = {} }))
		assert_true(app.same_request({ name = "level", params = { level = 3 } }, { name = "level", params = { level = 3 } }))
		assert_false(app.same_request({ name = "level", params = { level = 3 } }, { name = "level", params = { level = 4 } }))
		assert_false(app.same_request({ name = "level", params = { level = 3 } }, { name = "level", params = { level = 3, from = "town" } }))
		assert_false(app.same_request({ name = "town" }, { name = "level" }))
		assert_false(app.same_request(nil, { name = "town" }))
	end)

	it("retries a failed save every tick and reports the failure once per streak", function()
		local backend = boot()
		local sub = bus.subscribe({ "save_failed", "save_recovered" })
		app.meta:grant({ coins = 100 }, "test_gift", H.T0)
		backend.fail = true
		app.commit("gift")
		app.tick(H.T0 + 1)
		app.tick(H.T0 + 2)
		local streaks = {}
		sub:drain(function(topic, p) if topic == "save_failed" then streaks[#streaks + 1] = p.streak end end)
		assert_same(streaks, { 1, 2, 3 })
		backend.fail = false
		app.tick(H.T0 + 3)
		local recovered
		sub:drain(function(topic, p) if topic == "save_recovered" then recovered = p.after end end)
		assert_eq(recovered, 3)
		sub:close()
		local _, info = boot(backend)
		assert_eq(info.source, "current")
		assert_eq(app.meta:coins(), 600)
	end)

	it("moves settings_rev whenever the settings may have changed", function()
		boot()
		local r0 = app.settings_rev
		app.set_setting("music", 0.3)
		assert_true(app.settings_rev > r0)
		local r1 = app.settings_rev
		app.reset_save(3, H.T0)
		assert_true(app.settings_rev > r1)
		assert_near(app.meta:settings().music, 0.8, 1e-9)
	end)

	it("reads the free levels from the meta config", function()
		assert_eq(app.free_levels(), require("meta.config").levels.free_up_to)
	end)

	it("turns the load info into notices for the player", function()
		boot()
		local function keys(list)
			local out = {}
			for i, n in ipairs(list) do out[i] = n.key end
			return out
		end
		assert_same(keys(app.load_notices({ source = "fresh", errors = { current = "missing", previous = "missing" } })), {})
		assert_same(keys(app.load_notices({ source = "fresh", errors = { current = "bad_checksum", previous = "missing" } })),
			{ "splash.save_lost" })
		assert_same(keys(app.load_notices({ source = "previous", errors = { current = "bad_checksum" }, interrupted = "loss" })),
			{ "splash.restored", "splash.interrupted" })
		local n = app.load_notices({ source = "current", interrupted = "cancelled", newer = true,
			unlock_gifts = { "stick" }, district_chests = { "cafe" } })
		assert_same(keys(n), { "splash.newer", "splash.cancelled", "splash.gift", "splash.chest" })
		assert_eq(i18n.tr(n[3]), i18n.t("splash.gift", { name = i18n.t("booster.stick") }))
		assert_true(string.find(i18n.tr(n[4]), i18n.name(app.district("cafe").name), 1, true) ~= nil)
	end)

	it("keeps the loaded slot as the backup (store.adopt)", function()
		local backend = boot()
		H.win(app.meta, H.T0)
		app.commit("win")
		backend.files.current.data.checksum = "broken"
		local _, info = boot(backend)
		assert_eq(info.source, "previous")
		app.commit("after", true)
		local prev = backend.read("previous")
		assert_true(prev.checksum ~= "broken")
	end)
end)
