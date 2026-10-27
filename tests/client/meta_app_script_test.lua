-- main/app.script (the application root: boot, the screen manager, engine hooks, debug keys) on the
-- strict Defold stub, with the engine's replies (collection proxy loaded / unloaded, the overlay's
-- fades) played by the test.

local town_stub = require("tests.client.town_defold_stub")
local bus = require("client.bus")
local hooks = require("client.hooks")

local function proxy(name) return msg.url("main", "/screens", name) end
local function overlay_url() return msg.url("main:/overlay#overlay") end

-- Boots the stub WITHOUT the app (the script boots it), creates the app object and runs fn(E, a, app).
local function with_app_script(fn)
	local E = town_stub.install({})
	hooks._reset()
	local ok, err = pcall(function()
		-- the script's own boot: app.init with the real content and an in-memory save
		local app = require("client.app")
		bus.default.subs = {}
		local a = E.object("main/app.script", { url = "main:/app" })
		a:init()
		fn(E, a, app)
	end)
	hooks._reset()
	town_stub.shutdown()
	if not ok then error(err, 0) end
end

-- the messages posted to `to` with this id since the last call
local function take(E, id, to)
	local out = E.posted(id, to)
	local keep = {}
	for _, m in ipairs(E.unrouted) do
		if not (m.id == id and (to == nil or m.to == to)) then keep[#keep + 1] = m end
	end
	E.unrouted = keep
	return out
end

-- Plays the engine's side of one screen change: the proxy loads, the overlay fades in.
local function engine_loads(E, a, name)
	assert_eq(#take(E, "async_load", "main:/screens#" .. name), 1, "async_load " .. name)
	a:message("proxy_loaded", {}, proxy(name))
	assert_eq(#take(E, "init", "main:/screens#" .. name), 1)
	assert_eq(#take(E, "enable", "main:/screens#" .. name), 1)
	assert_eq(#take(E, "fade_in", "main:/overlay#overlay"), 1)
	a:message("fade_in_done", {}, overlay_url())
end

describe("main/app.script", function()
	it("boots the app and loads the splash first", function()
		with_app_script(function(E, a, app)
			assert_true(app.meta ~= nil)
			assert_eq(app.meta:level_to_play(), 1)
			assert_eq(app.pending.name, "splash")
			assert_true(app.transitioning)
			assert_eq(#take(E, "take_focus", "main:/overlay#overlay"), 1)
			engine_loads(E, a, "splash")
			assert_eq(app.screen, "splash")
			assert_false(app.transitioning)
		end)
	end)

	it("changes screens through a fade: leaving, fade out, unload, load, fade in", function()
		with_app_script(function(E, a, app)
			engine_loads(E, a, "splash")
			local sub = bus.subscribe({ "screen_leaving", "screen_changed" })
			a:message("show_screen", { name = "town", ticket = app.stash({ from = "splash" }) })
			assert_true(app.transitioning)
			assert_eq(#take(E, "fade_out", "main:/overlay#overlay"), 1)
			a:message("fade_out_done", {}, overlay_url())
			assert_eq(#take(E, "unload", "main:/screens#splash"), 1)
			a:message("proxy_unloaded", {}, proxy("splash"))
			engine_loads(E, a, "town")
			assert_eq(app.screen, "town")
			assert_eq(app.params.from, "splash")
			local topics = {}
			sub:drain(function(topic) topics[#topics + 1] = topic end)
			sub:close()
			assert_same(topics, { "screen_leaving", "screen_changed" })
		end)
	end)

	it("queues a request made during a transition (the last wins) and drops a repeat of the one loading", function()
		with_app_script(function(E, a, app)
			engine_loads(E, a, "splash")
			a:message("show_screen", { name = "town", params = {} })
			take(E, "fade_out", "main:/overlay#overlay")
			-- the same request again: dropped
			a:message("show_screen", { name = "town", params = {} })
			-- two others: the last wins
			a:message("show_screen", { name = "level", params = { level = 1 } })
			a:message("show_screen", { name = "level", params = { level = 2 } })
			a:message("fade_out_done", {}, overlay_url())
			a:message("proxy_unloaded", {}, proxy("splash"))
			engine_loads(E, a, "town")
			-- the queued one starts now
			assert_eq(#take(E, "fade_out", "main:/overlay#overlay"), 1)
			a:message("fade_out_done", {}, overlay_url())
			a:message("proxy_unloaded", {}, proxy("town"))
			assert_eq(#take(E, "async_load", "main:/screens#level"), 1)
			a:message("proxy_loaded", {}, proxy("level"))
			a:message("fade_in_done", {}, overlay_url())
			assert_eq(app.screen, "level")
			assert_eq(app.params.level, 2)
		end)
	end)

	it("moves on when the overlay never answers a fade (the watchdog), and ignores an unknown screen", function()
		with_app_script(function(E, a, app)
			engine_loads(E, a, "splash")
			a:message("show_screen", { name = "nowhere", params = {} })
			assert_false(app.transitioning)
			a:message("show_screen", { name = "town", params = {} })
			assert_eq(#take(E, "fade_out", "main:/overlay#overlay"), 1)
			a:run(2.2) -- no fade_out_done: the manager goes on by itself
			assert_eq(#take(E, "unload", "main:/screens#splash"), 1)
			a:message("proxy_unloaded", {}, proxy("splash"))
			assert_eq(#take(E, "async_load", "main:/screens#town"), 1)
			a:message("proxy_loaded", {}, proxy("town"))
			a:run(2.2) -- no fade_in_done either
			assert_eq(app.screen, "town")
			assert_false(app.transitioning)
		end)
	end)

	it("ticks the lives every second and saves when the app goes to the background", function()
		with_app_script(function(E, a, app)
			engine_loads(E, a, "splash")
			local sub = bus.subscribe({ "lives_tick", "app_focus" })
			a:run(2.1)
			local ticks = 0
			sub:drain(function(topic) if topic == "lives_tick" then ticks = ticks + 1 end end)
			assert_true(ticks >= 1 and ticks <= 3, "ticks " .. ticks)
			-- a focus loss is saved at once and announced
			app.meta:grant({ coins = 10 }, "test", app.now())
			local saves, real = 0, sys.save
			sys.save = function(path, tbl)
				saves = saves + 1
				return real(path, tbl)
			end
			E.window_listener(nil, window.WINDOW_EVENT_FOCUS_LOST, {})
			sys.save = real
			local got
			sub:drain(function(topic, p) if topic == "app_focus" then got = p end end)
			sub:close()
			assert_true(got ~= nil and got.focused == false)
			assert_true(saves >= 1, "the meta was written")
			assert_eq(app.store.failing or 0, 0)
			assert_false(app.meta:dirty())
		end)
	end)

	it("turns the debug keys into actions (coins, language, reset) and ignores them in release", function()
		with_app_script(function(E, a, app)
			engine_loads(E, a, "splash")
			local coins = app.meta:coins()
			local used = a:input(hash("debug_coins"), { released = true })
			assert_true(used)
			assert_eq(app.meta:coins(), coins + 1000)
			a:input(hash("debug_language"), { released = true })
			assert_eq(require("client.i18n").language(), "ru")
			assert_false(a:input(hash("debug_coins"), { released = false, pressed = true }))
			assert_false(a:input(hash("unknown_key"), { released = true }))
			-- a debug reset wipes the progress and goes back to the splash
			a:input(hash("debug_reset_save"), { released = true })
			assert_eq(app.meta:coins(), 500)
			app.debug = false
			assert_false(a:input(hash("debug_coins"), { released = true }))
			app.debug = true
		end)
	end)
end)
