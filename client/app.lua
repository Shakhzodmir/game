-- Shared application state (script.shared_state = 1: every script sees this
-- same table). Owns the meta instance, the save store and the screen state.
-- Pure Lua except the helpers marked "Defold" (they post messages).
--
--   local app = require("client.app")
--   app.meta                     -- meta.meta instance (all game-economy rules)
--   app.commit(reason)           -- call after every meta change: saves when
--                                -- dirty, publishes "meta_changed", logs the ledger
--   app.set_setting(key, value)  -- meta setting + language/haptics + events
--   app.show_screen(name, params)   -- Defold: msg.post("main:/app", "show_screen", ...)
--   app.screen, app.params       -- current screen and its params
--   app.toast(text), app.modal(spec) -- Defold: overlay helpers
--   app.snapshot()               -- plain table for debug / QA bridge
--
-- Initialised once by main/app.script (app.init) before any screen loads.

local Meta = require("meta.meta")
local bus = require("client.bus")
local i18n = require("client.i18n")
local platform = require("client.platform")
local analytics = require("client.services.analytics")
local audio = require("client.audio")

local M = {}

M.VERSION = "0.1.0"
M.APP_URL = "main:/app"
M.OVERLAY_URL = "main:/overlay#overlay"
M.SCREENS = { "splash", "town", "level" }

M.meta = nil          -- Meta instance
M.districts = nil     -- decoded content/districts.json
M.store = nil         -- client.save_io store
M.load_info = nil     -- info from Meta.load (source, interrupted, gifts, ...)
M.screen = nil        -- name of the screen on display
M.prev_screen = nil
M.params = {}         -- params the current screen was opened with
M.pending = nil       -- {name, params} of a screen being loaded
M.transitioning = false
M.debug = false
M.sys_language = nil

local rev_published = -1
local clock = platform.now

local function index_districts(data)
	local by_id, list = {}, {}
	for i, d in ipairs(data.districts or {}) do
		by_id[d.id] = d
		list[i] = d
	end
	return by_id, list
end

-- opts = {districts = table (content/districts.json), store = save_io store,
--         seed = integer, now = seconds (default clock()), clock = fn,
--         sys_language = string, debug = bool}
-- Returns the Meta.load info.
function M.init(opts)
	if type(opts) ~= "table" or type(opts.districts) ~= "table" or not opts.store then
		error("app.init needs {districts, store, seed}", 2)
	end
	clock = opts.clock or platform.now
	M.districts = opts.districts
	M.district_by_id, M.district_list = index_districts(opts.districts)
	M.store = opts.store
	M.debug = opts.debug and true or false
	M.sys_language = opts.sys_language
	M.screen, M.prev_screen, M.params, M.pending, M.transitioning = nil, nil, {}, nil, false

	local now = opts.now or clock()
	local cur, prev = M.store:load()
	local meta, info = Meta.load(M.districts, cur, prev, opts.seed, now)
	M.meta, M.load_info = meta, info
	rev_published = -1
	M.apply_settings()
	analytics.log("session_start", {
		first = info.source == "fresh",
		source = info.source,
		language = i18n.language(),
		version = M.VERSION,
		platform = platform.system(),
	})
	M.commit("load")
	return info
end

function M.now()
	return clock()
end

-- Language and haptics follow the meta settings.
function M.apply_settings()
	local s = M.meta:settings()
	i18n.set_language(s.language, M.sys_language)
	platform.haptics = s.haptics and true or false
	return s
end

-- To call after anything that may have changed the meta. Saves when the meta
-- is dirty (or always with force, e.g. when the app goes to the background),
-- turns ledger entries into analytics events and publishes "meta_changed"
-- when the revision moved. Returns true when the meta changed.
function M.commit(reason, force)
	local meta = M.meta
	if not meta then return false end
	analytics.log_ledger(meta:drain_ledger())
	local rev = meta:revision()
	local changed = rev ~= rev_published
	rev_published = rev
	local res, err = M.store:save_meta(meta, force)
	if res == false then
		analytics.log("save_error", { error = tostring(err) })
		bus.publish("save_failed", { error = tostring(err) })
	end
	if changed then bus.publish("meta_changed", { revision = rev, reason = reason }) end
	return changed
end

-- Changes a setting through the meta and applies it. true, or false and why.
function M.set_setting(key, value)
	local ok, why = M.meta:set_setting(key, value)
	if not ok then return false, why end
	local v = M.meta:settings()[key]
	M.apply_settings()
	if key == "language" then
		bus.publish("language_changed", { language = i18n.language() })
	end
	analytics.log("settings_change", { key = key, value = v })
	bus.publish("settings_changed", { key = key, value = v })
	M.commit("settings")
	return true
end

-- Once per second from app.script: lives regenerate with time.
function M.tick(now)
	now = now or clock()
	M.meta:lives(now)
	M.commit("tick")
	bus.publish("lives_tick", { now = now })
end

-- Debug: forget the save and start a fresh meta.
function M.reset_save(seed, now)
	M.store:wipe()
	M.meta = Meta.new(M.districts, seed)
	M.load_info = { source = "fresh", errors = {}, unlock_gifts = {}, district_chests = {} }
	rev_published = -1
	M.apply_settings()
	M.commit("reset", true)
end

-- districts -------------------------------------------------------------------------

function M.district(id)
	return M.district_by_id and M.district_by_id[id] or nil
end

-- District to show in the town and to play music for: the one being built,
-- or the last one when the whole town is complete.
function M.focus_district()
	local id = M.meta:current_district()
	if id then return id end
	local list = M.district_list or {}
	return list[#list] and list[#list].id or nil
end

-- True on the very first launch flow: level 1 not beaten yet.
function M.first_launch()
	return M.meta:level_to_play() == 1 and M.meta:stats().wins == 0
end

-- screens ------------------------------------------------------------------------------

function M.is_screen(name)
	for _, s in ipairs(M.SCREENS) do
		if s == name then return true end
	end
	return false
end

-- Called by app.script when a screen is on display (after its fade-in).
function M.set_screen(name, params)
	M.prev_screen = M.screen
	M.screen = name
	M.params = params or {}
	M.pending = nil
	analytics.log("screen_view", { name = name, prev = M.prev_screen })
	bus.publish("screen_changed", { name = name, prev = M.prev_screen, params = M.params })
end

-- Defold: asks app.script to switch screens with a fade.
function M.show_screen(name, params)
	msg.post(M.APP_URL, "show_screen", { name = name, params = params or {} })
end

-- Defold: overlay helpers (main/overlay.gui_script).
function M.toast(text, opts)
	opts = opts or {}
	msg.post(M.OVERLAY_URL, "toast", { text = text, color = opts.color, duration = opts.duration })
end

-- spec = {id, title, text, buttons = {{id, text, style}}}; the answer comes
-- back as bus event "modal_result" {id, button} (and a message to the sender).
function M.modal(spec)
	msg.post(M.OVERLAY_URL, "modal", spec)
end

-- snapshot -------------------------------------------------------------------------------

-- Plain data about the app for debug overlays and the QA bridge.
function M.snapshot(now)
	now = now or clock()
	local meta = M.meta
	local out = {
		version = M.VERSION,
		screen = M.screen,
		params = M.params,
		pending = M.pending and M.pending.name or nil,
		transitioning = M.transitioning,
		language = i18n.language(),
		debug = M.debug,
		audio = audio.status,
	}
	if meta then
		local lives = meta:lives(now)
		local task = meta:next_task()
		out.level = meta:level_to_play()
		out.all_done = meta:all_done()
		out.coins = meta:coins()
		out.stars = meta:stars()
		out.lives = lives.count
		out.lives_next_in = lives.next_in_seconds
		out.infinite_seconds = lives.infinite_seconds
		out.district = M.focus_district()
		out.next_task = task and { district = task.district, id = task.id, cost = task.cost, stem = task.stem } or nil
		out.revision = meta:revision()
		out.dirty = meta:dirty()
		out.save_source = M.load_info and M.load_info.source or nil
		out.streak = meta:streak().count
	end
	return out
end

return M
