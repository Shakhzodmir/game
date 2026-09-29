-- Shared engine hooks. Defold keeps ONE window listener (window.set_listener)
-- and ONE error handler (sys.set_error_handler) per app, so a second module
-- that sets its own silently removes the first. Every module registers here
-- instead; main/app.script installs the dispatchers once.
--
--   local hooks = require("client.hooks")
--   local off = hooks.on_window(function(event, data) ... end)  -- event: string below
--   local off2 = hooks.on_error(function(source, message, traceback) ... end)
--   off()                                  -- unregister
--
-- Window events are passed as strings: "focus_lost", "focus_gained",
-- "resized", "iconified", "deiconified" (Defold names the iconify constant
-- WINDOW_EVENT_ICONFIED in some versions; both spellings are handled).
-- Never call window.set_listener or sys.set_error_handler anywhere else.
-- Pure Lua: install() takes the window / sys tables, so tests pass fakes.

local M = {}

M.warn = function(text) print(text) end -- tests silence it

local window_fns, error_fns = {}, {}
local installed = false
local names = {} -- engine constant -> event name

local function add(list, fn)
	if type(fn) ~= "function" then error("hooks: handler must be a function", 3) end
	list[#list + 1] = fn
	return function()
		for i = #list, 1, -1 do
			if list[i] == fn then table.remove(list, i) end
		end
	end
end

function M.on_window(fn) return add(window_fns, fn) end
function M.on_error(fn) return add(error_fns, fn) end

local function call_all(list, ...)
	-- copy: a handler may unregister itself while we iterate
	local copy = {}
	for i = 1, #list do copy[i] = list[i] end
	for i = 1, #copy do
		local ok, err = pcall(copy[i], ...)
		if not ok then M.warn("WARNING: hooks: handler failed: " .. tostring(err)) end
	end
end

-- Event name of an engine constant (or of a name already translated).
function M.event_name(event)
	return names[event] or (type(event) == "string" and event) or nil
end

function M.dispatch_window(event, data)
	local name = M.event_name(event)
	if name then call_all(window_fns, name, data or {}) end
end

function M.dispatch_error(source, message, traceback)
	call_all(error_fns, source, message, traceback)
end

-- Installs the dispatchers (once; later calls are ignored).
-- win = the Defold `window` module, sysm = the Defold `sys` module.
function M.install(win, sysm)
	if installed then return false end
	installed = true
	names = {}
	if win then
		local map = {
			focus_lost = win.WINDOW_EVENT_FOCUS_LOST,
			focus_gained = win.WINDOW_EVENT_FOCUS_GAINED,
			resized = win.WINDOW_EVENT_RESIZED,
			iconified = win.WINDOW_EVENT_ICONIFIED or win.WINDOW_EVENT_ICONFIED,
			deiconified = win.WINDOW_EVENT_DEICONIFIED,
		}
		for name, const in pairs(map) do
			if const ~= nil then names[const] = name end
		end
		if win.set_listener then
			win.set_listener(function(_, event, data) M.dispatch_window(event, data) end)
		end
	end
	if sysm and sysm.set_error_handler then
		sysm.set_error_handler(function(source, message, traceback) M.dispatch_error(source, message, traceback) end)
	end
	return true
end

function M.count()
	return #window_fns, #error_fns
end

-- Test hook: forget every handler and the installation.
function M._reset()
	window_fns, error_fns, names, installed = {}, {}, {}, false
end

return M
