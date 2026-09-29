-- Popup host for a GUI scene: a stack of meta windows (gui/*.lua) drawn on
-- top of the screen, with a dim backdrop, open / close animations, input
-- that goes to the top window only, and a rebuild when the language changes.
-- GUI script context only. The town embeds it (screens/town); any other
-- screen can embed it the same way with its own registry.
--
--   local popups = require("client.popups")
--   self.popups = popups.new(self.ui, parent, {
--       registry = {shop = require("gui.shop"), ...},   -- literal requires (bob bundles them)
--       fx = self.fx,                                     -- client/fx.lua instance
--       release = function() ... end,                     -- a window closed: free loose images
--   })
--   self.popups:open("shop", {tab = "coins", on_close = function(result) ... end})
--   update:   self.popups:update(dt)
--   on_input: if self.popups:on_input(action_id, action) then return true end
--   bus:      self.popups:on_event(topic, payload)
--
-- A window module:
--   M.build(e)                 draws into e.content (centre of the screen = 0, 0)
--                              and e.back (full-screen, bottom-left = 0, 0);
--                              e.first is true on the first build only
--   M.update(e, dt)            optional
--   M.on_input(e, id, action)  optional, before the buttons (sliders, taps anywhere)
--   M.on_event(e, topic, p)    optional (meta_changed, lives_tick, ...)
--   M.closed(e, result)        optional clean-up
--   M.fullscreen, M.dim_alpha, M.rebuild_on_meta, M.no_back   optional flags
-- The entry e: {name, params, state (kept across rebuilds), ui, fx, host,
-- first, targets}; e:close(result), e:open(name, params), e:rebuild(),
-- e:target(name, x, y) (a tap target for QA, centre coordinates).
-- Bus out: "popup_opened" {name}, "popup_closed" {name, result}.
-- Status for QA: app.ui.popup (top name), app.ui.popups (stack),
-- app.ui.popup_targets (logical tap targets of the top window).

local bus = require("client.bus")
local app = require("client.app")

local M = {}

M.DIM = "#3A2470"
M.DIM_ALPHA = 0.55
M.CX, M.CY = 360, 640

local BACK = hash("back")

local Host = {}
Host.__index = Host

local Entry = {}
Entry.__index = Entry

function Entry:close(result)
	self.host:close(self, result)
end

function Entry:open(name, params)
	return self.host:open(name, params)
end

function Entry:rebuild()
	self.host:rebuild(self)
end

-- A tap target for QA (logical coordinates), from centre coordinates.
function Entry:target(name, x, y)
	self.targets[name] = { x = M.CX + x, y = M.CY + y }
end

function Entry:is_top()
	return self.host.stack[#self.host.stack] == self
end

function M.new(scene, parent, opts)
	opts = opts or {}
	local self = setmetatable({
		ui = scene, fx = opts.fx, registry = opts.registry or {}, stack = {},
		release = opts.release, on_change = opts.on_change,
	}, Host)
	self.layer = scene:layer(parent or scene.root, "popups")
	return self
end

local function publish(self)
	local names = {}
	for i, e in ipairs(self.stack) do names[i] = e.name end
	local top = self.stack[#self.stack]
	app.ui.popup = top and top.name or nil
	app.ui.popups = names
	app.ui.popup_targets = top and top.targets or nil
	if self.on_change then self.on_change(top) end
end

function Host:top()
	return self.stack[#self.stack]
end

function Host:count()
	return #self.stack
end

function Host:find(name)
	for _, e in ipairs(self.stack) do
		if e.name == name then return e end
	end
	return nil
end

function Host:_build(e)
	local s = self.ui
	if e.back then s:clear(e.back) end
	if e.content then s:clear(e.content) end
	e.targets = {}
	e.back = s:layer(e.base)
	e.content = s:layer(e.root)
	e.mod.build(e)
	if e == self.stack[#self.stack] then app.ui.popup_targets = e.targets end
end

function Host:rebuild(e)
	if e and not e.closing then
		e.first = false
		self:_build(e)
	end
end

-- Opens a window (a second open of one already in the stack returns it).
function Host:open(name, params)
	local mod = self.registry[name]
	if not mod then
		print("WARNING: popups: unknown window '" .. tostring(name) .. "'")
		return nil
	end
	local found = self:find(name)
	if found then return found end
	local s = self.ui
	local e = setmetatable({
		name = name, mod = mod, params = params or {}, state = {}, host = self, ui = s, fx = self.fx,
		first = true, targets = {},
	}, Entry)
	e.holder = s:layer(self.layer)
	e.dim = s:box(e.holder, M.CX, M.CY, 720, 1280, { color = mod.dim_color or M.DIM, alpha = 0 })
	s:cover(e.dim, "stretch")
	e.base = s:layer(e.holder)
	e.root = s:layer(e.holder)
	gui.set_position(e.root, vmath.vector3(M.CX, M.CY, 0))
	self.stack[#self.stack + 1] = e
	s:set_input_root(e.holder)
	self:_build(e)
	e.first = false
	local reduced = app.reduced_motion()
	gui.animate(e.dim, "color.w", mod.dim_alpha or M.DIM_ALPHA, gui.EASING_OUTQUAD, reduced and 0.1 or 0.2)
	if not mod.fullscreen and not reduced then
		gui.set_scale(e.root, vmath.vector3(0.72, 0.72, 1))
		gui.animate(e.root, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, 0.32)
	end
	publish(self)
	bus.publish("popup_opened", { name = name })
	return e
end

-- Closes a window (the top one by default). result goes to
-- params.on_close(result) and to the bus.
function Host:close(e, result, instant)
	e = e or self.stack[#self.stack]
	if not e or e.closing then return end
	e.closing = true
	for i = #self.stack, 1, -1 do
		if self.stack[i] == e then table.remove(self.stack, i) end
	end
	local s = self.ui
	local top = self.stack[#self.stack]
	s:set_input_root(top and top.holder or nil)
	if e.mod.closed then e.mod.closed(e, result) end
	local function gone()
		s:clear(e.holder)
		if self.release then self.release() end
	end
	if instant or app.reduced_motion() then
		gone()
	else
		gui.animate(e.dim, "color.w", 0, gui.EASING_INQUAD, 0.18)
		if e.mod.fullscreen then
			gui.animate(e.root, "scale", vmath.vector3(1, 1, 1), gui.EASING_LINEAR, 0.18, 0, gone)
			gui.set_enabled(e.base, false)
		else
			gui.animate(e.root, "scale", vmath.vector3(0.82, 0.82, 1), gui.EASING_INBACK, 0.18, 0, gone)
		end
	end
	publish(self)
	bus.publish("popup_closed", { name = e.name, result = result })
	if e.params.on_close then e.params.on_close(result) end
end

-- Closes everything at once (the screen goes away, a save reset).
function Host:close_all()
	while #self.stack > 0 do self:close(self.stack[#self.stack], "closed", true) end
end

function Host:rebuild_all()
	for _, e in ipairs(self.stack) do self:rebuild(e) end
end

function Host:update(dt)
	for i = 1, #self.stack do
		local e = self.stack[i]
		if e and e.mod.update and not e.closing then e.mod.update(e, dt) end
	end
end

-- true when a window is open (it takes every input, like a modal).
function Host:on_input(action_id, action)
	local e = self.stack[#self.stack]
	if not e then return false end
	if e.mod.on_input and e.mod.on_input(e, action_id, action) then return true end
	if self.ui:on_input(action_id, action) then return true end
	if action_id == BACK and action.released and not e.mod.no_back then self:close(e, "back") end
	return true
end

function Host:on_event(topic, p)
	if topic == "language_changed" then
		self:rebuild_all()
		return
	end
	for i = 1, #self.stack do
		local e = self.stack[i]
		if e and not e.closing then
			if e.mod.on_event then e.mod.on_event(e, topic, p) end
			if topic == "meta_changed" and e.mod.rebuild_on_meta and not e.busy then self:rebuild(e) end
		end
	end
end

return M
