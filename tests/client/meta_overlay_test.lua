-- main/overlay.gui_script on the strict Defold GUI stub: the fades of the screen manager, toasts,
-- modal windows, the save-failure notices and the language switch.

local G = require("tests.client.meta_gui_helper")
local bus = require("client.bus")

local function app_url() return msg.url("main:/app") end

-- A booted app with only the overlay (no town): c.overlay, c.E, c.app.
local function with_overlay(fn, opts)
	opts = opts or {}
	opts.town = false
	G.with_town(opts, fn)
end

local function post_to_overlay(c, id, message, sender)
	c.overlay:message(id, message, sender)
end

describe("main/overlay.gui_script: fades", function()
	it("starts opaque, swallows input and clears on the first fade-in, answering the sender", function()
		G.with_town({ town = false }, function(c)
			-- with_town already faded in; start a fresh overlay to see the opaque start
		end)
		local town_stub = require("tests.client.town_defold_stub")
		local E = town_stub.boot({})
		local ok, err = pcall(function()
			local app = require("client.app")
			local overlay = E.script("main/overlay.gui_script", "/main/overlay.gui", { url = "main:/overlay#overlay" })
			overlay:init()
			overlay:step(3)
			assert_eq(app.overlay.fade_alpha, 1)
			-- every tap is swallowed while the cover is up
			local used = E.input(hash("touch"), E.touch_action(360, 640, true, false))
			assert_true(used == overlay)
			overlay:message("fade_in", { duration = 0.25 }, app_url())
			overlay:step(5)
			assert_true(app.overlay.fading)
			overlay:step(20)
			assert_false(app.overlay.fading)
			assert_eq(app.overlay.fade_alpha, 0)
			local replies = E.posted("fade_in_done", "main:/app")
			assert_eq(#replies, 1)
			-- the input goes through again
			assert_eq(E.input(hash("touch"), E.touch_action(360, 640, true, false)), nil)
			overlay:message("fade_out", { duration = 0.25 }, app_url())
			overlay:step(25)
			assert_eq(app.overlay.fade_alpha, 1)
			assert_eq(#E.posted("fade_out_done", "main:/app"), 1)
		end)
		town_stub.shutdown()
		if not ok then error(err, 0) end
	end)

	it("answers a superseded fade at once, so the screen manager never waits for it", function()
		with_overlay(function(c)
			local first_in = #c.E.posted("fade_in_done", "main:/app") -- the first fade-in of the setup
			post_to_overlay(c, "fade_out", { duration = 1 }, app_url())
			c.overlay:step(5)
			post_to_overlay(c, "fade_in", { duration = 0.25 }, app_url())
			c.overlay:step(3)
			assert_eq(#c.E.posted("fade_out_done", "main:/app"), 1) -- answered although it never finished
			c.overlay:step(25)
			assert_eq(#c.E.posted("fade_in_done", "main:/app"), first_in + 1)
			assert_eq(#c.E.posted("fade_out_done", "main:/app"), 1) -- and only once
		end)
	end)

	it("holds a fade another script asks for during a screen transition until the transition is over", function()
		with_overlay(function(c)
			c.app.transitioning = true
			local stray = msg.url("main:/audio#audio")
			post_to_overlay(c, "fade_out", { duration = 0.25 }, stray)
			c.overlay:step(30)
			assert_eq(c.app.overlay.fade_alpha, 0) -- not started
			assert_eq(#c.E.posted("fade_out_done", "main:/audio#audio"), 0)
			-- the manager's own fade-in ends the transition: the held fade runs now
			post_to_overlay(c, "fade_in", { duration = 0.25 }, app_url())
			c.app.transitioning = false
			c.overlay:step(40)
			assert_eq(#c.E.posted("fade_out_done", "main:/audio#audio"), 1)
			assert_eq(c.app.overlay.fade_alpha, 1)
		end)
	end)

	it("covers the whole window in every window size", function()
		for _, w in ipairs({ { 720, 1280 }, { 1280, 720 }, { 390, 844 } }) do
			with_overlay(function(c)
				post_to_overlay(c, "fade_out", { duration = 0.01 }, app_url())
				c.overlay:step(5)
				local scene = c.E.scene("/main/overlay.gui")
				local fade
				for _, n in ipairs(c.E.alive_nodes(scene)) do
					if not n.parent and n.kind == "box" then fade = n end
				end
				local x0, y0, x1, y1 = c.E.rect(fade)
				assert_true(x0 <= 0.5 and y0 <= 0.5 and x1 >= w[1] - 0.5 and y1 >= w[2] - 0.5, w[1] .. "x" .. w[2])
			end, { window = w })
		end
	end)
end)

describe("main/overlay.gui_script: toasts", function()
	it("slides a toast in under the top bar, holds it and slides it out", function()
		with_overlay(function(c)
			c.app.toast_key("toast.coming_soon", nil, { color = "blue" })
			c.overlay:step(3)
			assert_eq(c.app.overlay.toast, "Coming soon!")
			c.overlay:step(40)
			assert_eq(c.app.overlay.toast_phase, "hold")
			assert_near(c.app.overlay.toast_offset, 0, 0.5)
			c.overlay:run(3.5)
			assert_eq(c.app.overlay.toast, nil)
			assert_same(c.E.audit(), {})
		end)
	end)

	it("queues toasts, shows the same text twice in a row once, and lays out under the safe top", function()
		with_overlay(function(c)
			c.app.toast("one")
			c.app.toast("one")
			c.app.toast("two", { duration = 1 })
			c.overlay:step(3)
			assert_eq(c.app.overlay.toast, "one")
			assert_eq(c.app.overlay.toasts_queued, 1)
			c.overlay:run(3.5)
			assert_eq(c.app.overlay.toast, "two")
			c.overlay:run(3)
			assert_eq(c.app.overlay.toast, nil)
		end, { safe = { left = 0, top = 60, right = 0, bottom = 0 }, window = { 390, 844 } })
	end)

	it("translates a toast when it is shown and again when the language changes", function()
		with_overlay(function(c)
			c.app.toast_key("town.task_need", { n = 2 }, { duration = 4 })
			c.overlay:step(20)
			assert_eq(c.app.overlay.toast, "Need 2 more stars")
			c.app.set_setting("language", "ru")
			c.overlay:step(5)
			assert_eq(c.app.overlay.toast, "Нужно ещё 2 звезды")
		end)
	end)

	it("tells the player once that saving failed, and when it works again", function()
		with_overlay(function(c)
			bus.publish("save_failed", { error = "disk", streak = 1 })
			bus.publish("save_failed", { error = "disk", streak = 2 })
			bus.publish("save_failed", { error = "disk", streak = 3 })
			c.overlay:step(3)
			assert_eq(c.app.overlay.toast, "Could not save progress. Trying again…")
			assert_eq(c.app.overlay.toasts_queued, 0)
			c.overlay:run(4)
			bus.publish("save_recovered", { after = 3 })
			c.overlay:step(3)
			assert_eq(c.app.overlay.toast, "Progress saved")
			assert_same(c.E.audit(), {})
		end)
	end)

	it("announces a failure series that began before the overlay existed (the first write is app.init's)", function()
		local save_io = require("client.save_io")
		local backend = save_io.memory_backend()
		backend.fail = true -- storage that never works: the load commit of app.init fails first (streak 1, nobody listens yet)
		with_overlay(function(c)
			assert_true(c.app.store.failing >= 1, "the first write failed")
			assert_eq(c.app.overlay.toast, nil)
			c.app.tick(c.app.now()) -- the retry a second later fails again: streak 2, the first the overlay sees
			c.overlay:step(3)
			assert_eq(c.app.overlay.toast, "Could not save progress. Trying again…")
			for _ = 1, 3 do c.app.tick(c.app.now()) end
			c.overlay:step(3)
			assert_eq(c.app.overlay.toasts_queued, 0, "once for the whole series")
			-- the storage works again: the notice that follows
			backend.fail = false
			c.app.tick(c.app.now())
			c.overlay:run(3.6) -- the first toast leaves, the next one comes
			assert_eq(c.app.overlay.toast, "Progress saved")
			c.overlay:run(3) -- ... and leaves
			assert_eq(c.app.overlay.toast, nil)
			-- a new series is announced again
			backend.fail = true
			c.app.meta:grant({ coins = 1 }, "test", c.app.now())
			c.app.commit("test")
			c.overlay:step(3)
			assert_eq(c.app.overlay.toast, "Could not save progress. Trying again…")
		end, { backend = backend })
	end)
end)

describe("main/overlay.gui_script: modal", function()
	local function open_modal(c, spec)
		c.app.modal(spec or { id = "qa", title = { key = "settings.title" }, text = { key = "lives.full" },
			buttons = { { id = "ok", text = { key = "common.ok" } }, { id = "no", text = { key = "common.cancel" }, style = "pink" } } })
		c.overlay:step(40)
	end

	it("shows a modal, takes its taps and answers on the bus", function()
		with_overlay(function(c)
			local sub = bus.subscribe("modal_result")
			open_modal(c)
			assert_eq(c.app.overlay.modal, "qa")
			assert_true(c.overlay:has_text("Settings", true))
			assert_true(c.overlay:has_text("All lives are here!", true))
			-- a tap elsewhere is swallowed by the modal
			assert_true(c.E.input(hash("touch"), c.E.touch_action(20, 20, true, false)) == c.overlay)
			c.E.input(hash("touch"), c.E.touch_action(20, 20, false, true))
			assert_eq(c.app.overlay.modal, "qa")
			c.overlay:tap_text("Cancel")
			c.overlay:step(3)
			assert_eq(c.app.overlay.modal, nil)
			local got
			sub:drain(function(_, p) got = p end)
			sub:close()
			assert_eq(got.id, "qa")
			assert_eq(got.button, "no")
			assert_eq(c.app.overlay.last_modal_result.button, "no")
		end)
	end)

	it("answers 'replaced' when another modal comes, and 'screen_changed' when the screen goes away", function()
		with_overlay(function(c)
			local sub = bus.subscribe("modal_result")
			open_modal(c)
			open_modal(c, { id = "second", title = "Second", buttons = { { id = "ok", text = "Fine" } } })
			bus.publish("screen_leaving", { from = "town", to = "level" })
			c.overlay:step(3)
			local results = {}
			sub:drain(function(_, p) results[#results + 1] = p.id .. ":" .. p.button end)
			sub:close()
			assert_same(results, { "qa:replaced", "second:screen_changed" })
			assert_eq(c.app.overlay.modal, nil)
		end)
	end)

	it("closes on the back key and on close_modal, and rebuilds in the other language", function()
		with_overlay(function(c)
			open_modal(c)
			c.app.set_setting("language", "ru")
			c.overlay:step(5)
			assert_true(c.overlay:has_text("Настройки", true))
			assert_true(c.overlay:has_text("Все жизни на месте!", true))
			c.E.input(hash("back"), { released = true, pressed = false, x = 0, y = 0 })
			c.overlay:step(3)
			assert_eq(c.app.overlay.modal, nil)
			open_modal(c)
			c.app.close_modal("closed_by_code")
			c.overlay:step(3)
			assert_eq(c.app.overlay.last_modal_result.button, "closed_by_code")
			assert_same(c.E.audit(), {})
		end)
	end)
end)
