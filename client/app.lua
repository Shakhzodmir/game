-- Shared application state (script.shared_state = 1: every script sees this
-- same table). Owns the meta instance, the save store and the screen state.
-- Pure Lua except the helpers marked "Defold" (they post messages).
--
--   local app = require("client.app")
--   app.meta                     -- meta.meta instance (all game-economy rules)
--   app.commit(reason)           -- call after every meta change: saves when
--                                -- dirty (retries a failed save), publishes
--                                -- "meta_changed", logs the ledger
--   app.set_setting(key, value)  -- meta setting + language/haptics + events
--   app.settings_rev             -- grows whenever the settings may have changed
--                                -- (init, set_setting, reset_save): poll it
--   app.show_screen(name, params)   -- Defold: asks main/app.script for a screen
--   app.screen, app.params       -- current screen and its params
--   app.toast(text | {key, vars}, opts), app.toast_key(key, vars, opts)
--   app.modal(spec), app.close_modal(button) -- Defold: overlay helpers
--   app.load_notices()           -- what the splash tells the player after a load
--   app.free_levels()            -- levels 1..n cost no life (meta config)
--   app.snapshot()               -- plain table for debug / QA bridge
--
-- Messages between scripts carry at most 2 KB (msg.post), so specs and
-- params travel as tickets: app.stash(value) keeps the value in this shared
-- module (script.shared_state = 1) and returns a number; the receiver takes
-- it back with app.claim(ticket).
--
-- Initialised once by main/app.script (app.init) before any screen loads.

local Meta = require("meta.meta")
local bus = require("client.bus")
local i18n = require("client.i18n")
local platform = require("client.platform")
local analytics = require("client.services.analytics")
local audio = require("client.audio")
local config = require("meta.config")

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
M.settings_rev = 0     -- bumped when the settings may have changed
M.overlay = {}         -- status written by main/overlay.gui_script (toast, modal, fade)

local rev_published = -1
local clock = platform.now

-- tickets: values handed between scripts without msg.post size limits -------------

local stash, stash_n = {}, 0
M.STASH_KEEP = 64 -- tickets never claimed are dropped after this many newer ones

function M.stash(value)
	stash_n = stash_n + 1
	stash[stash_n] = value
	stash[stash_n - M.STASH_KEEP] = nil
	return stash_n
end

-- The value of a ticket (once), or nil.
function M.claim(ticket)
	if type(ticket) ~= "number" then return nil end
	local v = stash[ticket]
	stash[ticket] = nil
	return v
end

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
	-- the slot the meta accepted is the backup of the next save
	if M.store.adopt then M.store:adopt(info.source) end
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
	M.settings_rev = M.settings_rev + 1
	return s
end

-- To call after anything that may have changed the meta. Saves when the meta
-- is dirty, when the last save failed (retry), or always with force (e.g.
-- when the app goes to the background), turns ledger entries into analytics
-- events and publishes "meta_changed" when the revision moved. Returns true
-- when the meta changed.
-- Bus: "save_failed" {error, streak = failures in a row} on every failed
-- write, "save_recovered" {after = failures} on the first success after them.
function M.commit(reason, force)
	local meta = M.meta
	if not meta then return false end
	analytics.log_ledger(meta:drain_ledger())
	local rev = meta:revision()
	local changed = rev ~= rev_published
	rev_published = rev
	local failing_before = M.store.failing or 0
	local res, err = M.store:save_meta(meta, force)
	if res == false then
		local streak = M.store.failing or 1
		-- log the first failure of a streak and then every 60th (one per minute of app.tick)
		if streak == 1 or streak % 60 == 0 then analytics.log("save_error", { error = tostring(err) }) end
		bus.publish("save_failed", { error = tostring(err), streak = streak })
	elseif res == "saved" and failing_before > 0 then
		bus.publish("save_recovered", { after = failing_before })
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
-- Debug: forget the save and start a fresh meta. Publishes "save_reset";
-- settings_rev moves, so the audio re-applies the (default) volumes.
function M.reset_save(seed, now)
	M.store:wipe()
	M.meta = Meta.new(M.districts, seed)
	M.load_info = { source = "fresh", errors = {}, unlock_gifts = {}, district_chests = {} }
	rev_published = -1
	M.apply_settings()
	bus.publish("save_reset", {})
	bus.publish("settings_changed", { key = "*" })
	bus.publish("language_changed", { language = i18n.language() })
	M.commit("reset", true)
end

-- Levels 1..n never cost a life (a number of the meta config, shown in the
-- lives window; the rule itself is applied by the meta).
function M.free_levels()
	return config.levels.free_up_to
end

-- True when a save slot existed but could not be read (not merely missing).
local function slot_broken(reason)
	return reason ~= nil and reason ~= "missing"
end

-- Notices for the player about the last load, in display order:
-- {{key, vars?, color}, ...} for app.toast (i18n keys, resolved on display).
function M.load_notices(info)
	info = info or M.load_info or {}
	local out = {}
	local errors = info.errors or {}
	if info.source == "previous" then
		out[#out + 1] = { key = "splash.restored", color = "gold" }
	elseif info.source == "fresh" and (slot_broken(errors.current) or slot_broken(errors.previous)) then
		out[#out + 1] = { key = "splash.save_lost", color = "pink" }
	end
	if info.newer then out[#out + 1] = { key = "splash.newer", color = "blue" } end
	if info.interrupted == "loss" then
		out[#out + 1] = { key = "splash.interrupted", color = "pink" }
	elseif info.interrupted == "cancelled" then
		out[#out + 1] = { key = "splash.cancelled", color = "blue" }
	end
	for _, id in ipairs(info.unlock_gifts or {}) do
		out[#out + 1] = { key = "splash.gift", vars = { name = { key = "booster." .. id } }, color = "gold" }
	end
	for _, did in ipairs(info.district_chests or {}) do
		local d = M.district(did)
		out[#out + 1] = { key = "splash.chest", vars = { name = d and d.name or did }, color = "gold" }
	end
	return out
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

-- Two screen requests {name, params} ask for the same thing (same name,
-- same flat params): a repeated request for the screen being loaded is
-- dropped instead of loading it twice.
function M.same_request(a, b)
	if not a or not b or a.name ~= b.name then return false end
	local pa, pb = a.params or {}, b.params or {}
	for k, v in pairs(pa) do
		if pb[k] ~= v then return false end
	end
	for k in pairs(pb) do
		if pa[k] == nil then return false end
	end
	return true
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

-- Defold: asks app.script to switch screens with a fade. The params travel
-- as a ticket (no 2 KB message limit).
function M.show_screen(name, params)
	msg.post(M.APP_URL, "show_screen", { name = name, ticket = M.stash(params or {}) })
end

-- Defold: overlay helpers (main/overlay.gui_script).
-- text: a string, or {key, vars} resolved when shown (and re-resolved when
-- the language changes). opts = {color, duration}.
function M.toast(text, opts)
	opts = opts or {}
	local t = type(text) == "table" and text or { text = text }
	msg.post(M.OVERLAY_URL, "toast", { ticket = M.stash({
		text = t.text, key = t.key, vars = t.vars, color = opts.color or t.color, duration = opts.duration or t.duration,
	}) })
end

function M.toast_key(key, vars, opts)
	M.toast({ key = key, vars = vars }, opts)
end

-- spec = {id, title, text, buttons = {{id, text, style}}}; every text is a
-- string or {key, vars} (resolved by the overlay, refreshed on a language
-- change). The answer is the bus event "modal_result" {id, button}; button
-- is "close" (dismissed), "replaced" (another modal opened) or
-- "screen_changed" (the screen it belonged to went away).
function M.modal(spec)
	msg.post(M.OVERLAY_URL, "modal", { ticket = M.stash(spec) })
end

function M.close_modal(button)
	msg.post(M.OVERLAY_URL, "close_modal", { button = button or "close" })
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
		overlay = M.overlay,
		settings_rev = M.settings_rev,
		save_failing = M.store and M.store.failing or 0,
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
