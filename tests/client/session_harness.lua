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

local function deep_copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = deep_copy(x) end -- (a copy: the order does not matter)
	return out
end

local function proxy_url(name) return msg.url("main", "/screens", name) end

-- Starts the stub and the application objects of main/main.collection and runs fn(s). Always shuts the stub down.
-- opts: {window = {w, h}, safe = {...}, language = "en", seed = n (the player's salt: boards are the same in every run),
--        setup = fn(app, s) (after the app script booted), levels = {[n] = fn(data)} (patch a level file),
--        files = {...}, clock = seconds (the disk and the clock of an earlier session: s:files(), a cold start),
--        audio = true (the audio object too), quiet = false (echo the analytics lines)}
-- The game reports what it swallowed with print("WARNING: ...") / print("ERROR: ..."): the harness keeps those lines
-- (s.warnings) and fails the session if any is left when it ends, so a test either expects them (s:take_warnings)
-- or the session is clean.
function M.run(opts, fn)
	opts = opts or {}
	local hooks = require("client.hooks")
	local bus = require("client.bus")
	local rewards = require("client.rewards")
	local real_print = print
	local warnings = {}
	local restore_platform
	local language = require("client.i18n").language()
	local E = town_stub.install({
		window = opts.window, safe = opts.safe, clock = opts.clock, collections = { "/screens/level/level.collection" },
	})
	local s
	local ok, err = pcall(function()
		hooks._reset()
		bus.default.subs = {}
		rewards.clear()
		require("client.levels")._reset()
		require("client.tutorial")._reset()
		-- the player's salt (and so every board) is the same in every session and on both VMs: math.random differs
		restore_platform = require("client.platform").stub({ random_seed = function() return opts.seed or 20240607 end })
		rawset(_G, "print", function(first, ...)
			if type(first) == "string" then
				if string.find(first, "^analytics: ") then
					if opts.quiet == false then real_print(first, ...) end
					return
				end
				if string.find(first, "^WARNING") or string.find(first, "^ERROR") then
					warnings[#warnings + 1] = first
					return
				end
			end
			real_print(first, ...)
		end)
		s = setmetatable({ E = E, screens = {}, log = {}, frames = 0, warnings = warnings, audited = {} }, Session)
		-- the save files of an earlier session (Session:files): a cold start from them
		for path, tbl in pairs(opts.files or {}) do E.files[path] = deep_copy(tbl) end
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
		-- Input order of the engine: the main collection's stack has the app object, /screens (the host of the proxies) and the
		-- overlay on top; a screen's own scripts have a stack of their own that /screens forwards to. So the overlay sees a touch
		-- first (it swallows it during a fade and under a modal), then the screens (the last script that took focus first), then
		-- the app object. The stub keeps one stack for all of them, so the dispatch is redone here.
		E.input = function(action_id, action)
			local snapshot = {}
			for i = #E.input_stack, 1, -1 do snapshot[#snapshot + 1] = E.input_stack[i] end -- top first
			local function offer(wanted)
				for _, sc in ipairs(snapshot) do
					if wanted(sc) and not sc.finalized and sc:call("on_input", action_id, action) then return sc end
				end
				return nil
			end
			return offer(function(sc) return not sc.screen and sc ~= s.main end)
				or offer(function(sc) return sc.screen ~= nil end)
				or offer(function(sc) return sc == s.main end)
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
	rewards.clear()
	require("client.levels")._reset() -- (the read hook of opts.levels and the cache of patched files)
	require("client.i18n").set_language(language)
	if restore_platform then restore_platform() end
	town_stub.shutdown()
	rawset(_G, "print", real_print)
	if not ok then
		for _, line in ipairs(warnings) do real_print("  (during the session) " .. line) end
		error(err, 0)
	end
	if #warnings > 0 then
		error("the game reported " .. #warnings .. " warning(s) nobody expected:\n  " .. table.concat(warnings, "\n  "), 0)
	end
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
	-- the engine deletes every game object of an unloaded collection, the ones a factory spawned too
	local ids = {}
	for _, o in pairs(E.objects) do ids[#ids + 1] = o.id end -- (the order does not matter)
	if #ids > 0 then go.delete(ids) end
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
	if self.frames % 30 == 0 then self:audit() end
end

-- What the strict GUI stub finds wrong with the text on display (a glyph the font lacks, an outline on a font that
-- bakes none, too many characters), reported once each as a warning of the session.
function Session:audit()
	for _, line in ipairs(self.E.audit()) do
		local text = "AUDIT: " .. line
		if not self.audited[text] then
			self.audited[text] = true
			self.warnings[#self.warnings + 1] = text
		end
	end
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

-- A copy of what the game has written to disk so far, and the clock: S.run({files = ..., clock = ...}) starts the
-- game again from it, as after the process was killed.
function Session:files()
	return deep_copy(self.E.files), self.E.clock
end

-- Runs a QA bridge command (client/qa_bridge.lua) the way the engine does: from the app script's update, so the
-- messages it posts (a fade, a screen load) come from main:/app and their replies find their way back.
function Session:qa(cmd)
	local E = self.E
	local before = E.current_script
	E.current_script = self.main
	local ok, res = pcall(require("client.qa_bridge").execute, cmd)
	E.current_script = before
	if not ok then error(res, 0) end
	return res
end

-- Takes the warnings the game printed that contain `text` (plain match) off the list the session is judged by;
-- returns them.
function Session:take_warnings(text)
	local taken, kept = {}, {}
	for _, line in ipairs(self.warnings) do
		if string.find(line, text, 1, true) then taken[#taken + 1] = line else kept[#kept + 1] = line end
	end
	for i = #self.warnings, 1, -1 do self.warnings[i] = nil end
	for _, line in ipairs(kept) do self.warnings[#self.warnings + 1] = line end
	return taken
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
