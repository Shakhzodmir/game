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
end)
