local hooks = require("client.hooks")

local function fake_engine()
	local win = {
		WINDOW_EVENT_FOCUS_LOST = 1, WINDOW_EVENT_FOCUS_GAINED = 2, WINDOW_EVENT_RESIZED = 3,
		WINDOW_EVENT_ICONFIED = 4, -- the engine's spelling in some versions
		WINDOW_EVENT_DEICONIFIED = 5,
		sets = 0,
	}
	win.set_listener = function(fn) win.listener = fn; win.sets = win.sets + 1 end
	local sysm = { sets = 0 }
	sysm.set_error_handler = function(fn) sysm.handler = fn; sysm.sets = sysm.sets + 1 end
	return win, sysm
end

describe("client.hooks", function()
	before_each(function() hooks._reset() end)

	it("installs one listener and fans window events out to every module", function()
		local win, sysm = fake_engine()
		assert_true(hooks.install(win, sysm))
		assert_false(hooks.install(win, sysm)) -- once
		assert_eq(win.sets, 1)
		local a, b = {}, {}
		local off_a = hooks.on_window(function(ev) a[#a + 1] = ev end)
		hooks.on_window(function(ev) b[#b + 1] = ev end)
		win.listener(nil, 1)
		win.listener(nil, 4)
		win.listener(nil, 5)
		assert_same(a, { "focus_lost", "iconified", "deiconified" })
		assert_same(b, a)
		off_a()
		win.listener(nil, 2)
		assert_eq(#a, 3)
		assert_same(b[4], "focus_gained")
	end)

	it("keeps the other handlers alive when one fails", function()
		local win, sysm = fake_engine()
		hooks.install(win, sysm)
		local got, warned = {}, {}
		local warn = hooks.warn
		hooks.warn = function(t) warned[#warned + 1] = t end
		hooks.on_error(function() error("boom") end)
		hooks.on_error(function(source, message) got[#got + 1] = message end)
		sysm.handler("lua", "oops", "tb")
		hooks.warn = warn
		assert_same(got, { "oops" })
		assert_eq(#warned, 1)
		local n_win, n_err = hooks.count()
		assert_eq(n_win, 0)
		assert_eq(n_err, 2)
	end)

	it("lets a handler remove itself while events are dispatched", function()
		local win, sysm = fake_engine()
		hooks.install(win, sysm)
		local calls = 0
		local off
		off = hooks.on_window(function() calls = calls + 1; off() end)
		hooks.on_window(function() calls = calls + 10 end)
		win.listener(nil, 3)
		win.listener(nil, 3)
		assert_eq(calls, 21)
		assert_error(function() hooks.on_window("nope") end, "function")
	end)
end)
