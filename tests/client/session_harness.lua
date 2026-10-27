-- A whole session of the game on the strict Defold stubs (not a test file itself): the real
-- main/app.script, the overlay, the audio object and every screen script, loaded and unloaded
-- the way the engine does it for the collection proxies of main/main.collection, one after the
-- other in ONE Lua state. Each screen has its own tests; what only a session shows is the traffic
-- between them: the params a screen is opened with, the bus subscriptions a screen leaves behind,
-- the queue of rewards, the input focus, the fades, the state the next screen finds.
--
--   local S = require("tests.client.session_harness")
--   S.run({language = "en", setup = function(app) ... end}, function(s)
--       s:wait_screen("splash")
--       s:step_until(function() return s.app.screen == "level" end, 10, "the first level")
--       s:tap_target("play")             -- a named target of the top window / the town (app.ui)
--   end)
--
-- The engine's side of a proxy (client/app.lua SCREENS, screens/<name>/<name>.collection): async_load
-- creates the scripts of the collection (screen_scripts below, the order of the collection file),
-- proxy_loaded goes to the app script a frame later, init initialises them in that order, unload
-- finalises them in the reverse order, frees their GUI scenes and answers proxy_unloaded.

local town_stub = require("tests.client.town_defold_stub")

local M = {}

-- the scripts of each screen collection, in the order of the .collection file
M.SCREEN_SCRIPTS = {
	splash = {
		{ gui = "/screens/splash/splash.gui", path = "screens/splash/splash.gui_script" },
	},
	town = {
		{ gui = "/screens/town/town.gui", path = "screens/town/town.gui_script" },
	},
	level = {
		{ gui = "/screens/level/level_bg.gui", path = "screens/level/level_bg.gui_script" },
		{ path = "screens/level/board.script" },
		{ gui = "/screens/level/level.gui", path = "screens/level/level.gui_script" },
		{ gui = "/screens/level/level_fx.gui", path = "screens/level/level_fx.gui_script" },
	},
}

local Session = {}
Session.__index = Session

local function proxy_url(name) return msg.url("main", "/screens", name) end

-- Starts the stub and the application objects of main/main.collection and runs fn(s). Always shuts the stub down.
-- opts: {window = {w, h}, safe = {...}, language = "en", seed = n, setup = fn(app) (after the app script booted),
--        audio = true (the audio object too), qa = false, quiet = true (hide the analytics echo)}
function M.run(opts, fn)
	opts = opts or {}
	local hooks = require("client.hooks")
	local bus = require("client.bus")
	local rewards = require("client.rewards")
	local real_print = print
	local E = town_stub.install({
		window = opts.window, safe = opts.safe, collections = { "/screens/level/level.collection" },
	})
	local s
	local ok, err = pcall(function()
		hooks._reset()
		bus.default.subs = {}
		rewards.clear()
		require("client.levels")._reset()
		require("client.tutorial")._reset()
		if opts.quiet ~= false then
			rawset(_G, "print", function(first, ...)
				if type(first) == "string" and string.find(first, "^analytics: ") then return end
				real_print(first, ...)
			end)
		end
		s = setmetatable({ E = E, screens = {}, log = {}, frames = 0 }, Session)
		-- every posted message knows who posted it, so a reply finds its way back (the engine's `sender`)
		local inner_post = msg.post
		rawset(msg, "post", function(receiver, id, message)
			local before = #E.msgs
			inner_post(receiver, id, message)
			local who = E.current_script
			for i = before + 1, #E.msgs do E.msgs[i].from = who and who.url or nil end
		end)
		s.inner_post = inner_post
		if opts.language then
			-- the system language the app script reads
			sys.get_sys_info = function() return { system_name = "Linux", language = opts.language, device_language = opts.language } end
		end
		s.app = require("client.app")
		if opts.levels then
			-- the level files the game reads, changed: {[n] = fn(data) -> nil | data} (a level with few moves ends in the
			-- moves window quickly); every other file is read from content/levels as usual
			local json = require("tools.lib.json")
			local levels = require("client.levels")
			levels.read = function(path)
				local text = sys.load_resource(path)
				local n = tonumber(string.match(path, "level_(%d+)%.json$"))
				local patch = n and opts.levels[n]
				if not (text and patch) then return text end
				local data = json.decode(text)
				data = patch(data) or data
				return json.encode(data)
			end
		end
		s.main = E.object("main/app.script", { url = "main:/app" })
		s.overlay = E.script("main/overlay.gui_script", "/main/overlay.gui", { url = "main:/overlay#overlay" })
		if opts.audio then
			s.audio = E.object("main/audio.script", { url = "main:/audio#audio" })
		end
		-- init order of main/main.collection: audio, app, screens, overlay (the overlay starts opaque)
		if s.audio then s.audio:init() end
		s.overlay:init()
		s.main:init()
		if opts.setup then opts.setup(s.app, s) end
		fn(s)
	end)
	if s then
		for name in pairs(s.screens) do pcall(s.unload_screen, s, name, true) end
		if s.inner_post then rawset(msg, "post", s.inner_post) end
	end
	hooks._reset()
	bus.default.subs = {}
	town_stub.shutdown()
	rawset(_G, "print", real_print)
	if not ok then error(err, 0) end
end

-- The engine's side of the collection proxies -------------------------------------------------------

function Session:create_screen(name)
	local E = self.E
	local list = M.SCREEN_SCRIPTS[name]
	assert(list, "no screen " .. tostring(name))
	local scripts = {}
	for i, def in ipairs(list) do
		if def.gui then
			scripts[i] = E.script(def.path, def.gui)
			scripts[i].screen_gui = def.gui
		else
			scripts[i] = E.object(def.path)
		end
		scripts[i].screen = name
		-- a loaded collection does not run until it is initialised and enabled
		for k = #E.scripts, 1, -1 do
			if E.scripts[k] == scripts[i] then table.remove(E.scripts, k) end
		end
	end
	self.screens[name] = { scripts = scripts, state = "loaded" }
end

function Session:unload_screen(name, quiet)
	local E = self.E
	local sc = self.screens[name]
	if not sc then return end
	for i = #sc.scripts, 1, -1 do
		local sc_script = sc.scripts[i]
		if not quiet then sc_script:final() else pcall(sc_script.final, sc_script) end
		if sc_script.screen_gui then E.scenes[sc_script.screen_gui] = nil end
		for k = #E.scripts, 1, -1 do
			if E.scripts[k] == sc_script then table.remove(E.scripts, k) end
		end
	end
	self.screens[name] = nil
end

-- Plays the engine's answers to what the app script posted to the proxies (async_load, init, enable, unload).
function Session:engine()
	local E = self.E
	E.pump()
	local rest, mine = {}, {}
	for _, m in ipairs(E.unrouted) do
		local name = string.match(m.to, "^main:/screens#(%w+)$")
		if name then mine[#mine + 1] = { name = name, m = m } else rest[#rest + 1] = m end
	end
	E.unrouted = rest
	for _, x in ipairs(mine) do
		local name, id = x.name, x.m.id
		self.log[#self.log + 1] = id .. " " .. name
		if id == "async_load" then
			self:create_screen(name)
			self.pending_loaded = self.pending_loaded or {}
			self.pending_loaded[#self.pending_loaded + 1] = name
		elseif id == "init" then
			local sc = assert(self.screens[name], "init of an unloaded screen " .. name)
			for _, sc_script in ipairs(sc.scripts) do
				E.scripts[#E.scripts + 1] = sc_script
				sc_script:init()
			end
			sc.state = "running"
		elseif id == "unload" then
			self:unload_screen(name)
			self.pending_unloaded = self.pending_unloaded or {}
			self.pending_unloaded[#self.pending_unloaded + 1] = name
		elseif id == "enable" or id == "disable" or id == "final" then
			-- nothing to do
		else
			error("unexpected message " .. id .. " to the proxy " .. name)
		end
	end
	-- the replies arrive a frame later
	local loaded, unloaded = self.pending_loaded, self.pending_unloaded
	self.pending_loaded, self.pending_unloaded = nil, nil
	for _, name in ipairs(loaded or {}) do self.main:message("proxy_loaded", {}, proxy_url(name)) end
	for _, name in ipairs(unloaded or {}) do self.main:message("proxy_unloaded", {}, proxy_url(name)) end
end

-- Time and input ------------------------------------------------------------------------------------

function Session:frame()
	local E = self.E
	E.advance(1 / 60)
	E.step(1)
	self:engine()
	self.frames = self.frames + 1
end

function Session:step(n)
	for _ = 1, n or 1 do self:frame() end
end

function Session:run(seconds)
	self:step(math.ceil(seconds * 60))
end

-- Frames until pred() is true, at most `seconds`; fails with `what` otherwise.
function Session:step_until(pred, seconds, what)
	local limit = math.ceil((seconds or 10) * 60)
	for _ = 1, limit do
		if pred() then return true end
		self:frame()
	end
	if pred() then return true end
	error("timeout waiting for " .. tostring(what) .. "; screen " .. tostring(self.app.screen) .. ", pending " ..
		tostring(self.app.pending and self.app.pending.name) .. ", popup " .. tostring(self.app.ui and self.app.ui.popup), 2)
end

-- Waits for the screen to be on display (the fade-in over).
function Session:wait_screen(name, seconds)
	self:step_until(function() return self.app.screen == name and not self.app.transitioning end, seconds or 8, "screen " .. name)
	return self
end

function Session:tap(lx, ly)
	local a, b = self.E.tap(lx, ly)
	self:engine()
	return a, b
end

-- a touch action at logical coordinates
local function touch(self, lx, ly, pressed, released)
	return self.E.input(hash("touch"), self.E.touch_action(lx, ly, pressed, released))
end

-- A swipe from core cell a = {x, y} to b (1-based cells of the board on display), frame by frame like a finger.
function Session:swipe_cells(a, b)
	local link = require("client.level_link")
	local ax, ay = link.cell_center(a[1], a[2])
	local bx, by = link.cell_center(b[1], b[2])
	assert(ax and bx, "no board on display")
	touch(self, ax, ay, true, false)
	self:step(2)
	touch(self, (ax + bx) / 2, (ay + by) / 2, false, false)
	self:step(1)
	touch(self, ax + (bx - ax) * 0.85, ay + (by - ay) * 0.85, false, false)
	self:step(1)
	touch(self, ax + (bx - ax) * 0.9, ay + (by - ay) * 0.9, false, true)
	self:step(2)
end

-- A tap on core cell c of the board on display.
function Session:tap_cell(c)
	local link = require("client.level_link")
	local lx, ly = link.cell_center(c[1], c[2])
	assert(lx, "no board on display")
	touch(self, lx, ly, true, false)
	self:step(2)
	touch(self, lx, ly, false, true)
	self:step(2)
end

-- A tap on a named target of the top window (app.ui.popup_targets) or of the screen (app.ui.targets).
function Session:tap_target(name)
	local ui = self.app.ui or {}
	local t = (ui.popup_targets and ui.popup_targets[name]) or (not ui.popup and ui.targets and ui.targets[name])
	assert(t, "no target '" .. name .. "' (popup " .. tostring(ui.popup) .. ")")
	return self:tap(t.x, t.y)
end

-- A tap at a published target {x, y} (logical coordinates).
function Session:tap_target_at(t)
	return self:tap(t.x, t.y)
end

function Session:popup()
	return self.app.ui and self.app.ui.popup or nil
end

-- the script of a screen by its file name
function Session:script(path)
	for _, sc in pairs(self.screens) do
		for _, s in ipairs(sc.scripts) do
			if s.path == path then return s end
		end
	end
	return nil
end

function Session:texts(path)
	local sc = self:script(path)
	return sc and sc.texts and sc:texts(true) or {}
end

function Session:has_text(path, text)
	local sc = self:script(path)
	return sc ~= nil and sc.has_text ~= nil and sc:has_text(text, true)
end

return M
