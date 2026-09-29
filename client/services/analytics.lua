-- Analytics service (test implementation): validates events against the
-- catalogue below, keeps them in a bounded queue and prints them in debug.
-- A real SDK plugs in with analytics.set_sink(fn(event)); callers do not change.
--
--   local analytics = require("client.services.analytics")
--   analytics.log("level_start", {level = 12, attempt = 1})
--   analytics.drain()      -- events since the last drain (QA bridge, tests)
--
-- Event = {name, params, t (seconds), seq}. Unknown event names or params
-- raise an error in debug (a typo would silently lose data) and are dropped
-- with a warning in release.

local M = {}

-- Catalogue: event -> allowed params. Mirrors the analytics plan: funnel,
-- level outcomes, economy sources/sinks, monetization, town progress, tech.
M.EVENTS = {
	session_start = { "first", "source", "language", "version", "platform" },
	session_end = { "seconds" },
	screen_view = { "name", "prev" },
	tutorial_step = { "id", "level" },

	level_start = { "level", "attempt", "assist", "difficulty", "boosters", "streak", "life_at_stake" },
	level_win = { "level", "attempt", "moves_left", "stars", "coins", "streak", "seconds" },
	level_fail = { "level", "attempt", "reason", "life_lost", "streak_lost", "fails", "seconds" },
	level_cancel = { "level" },
	first_move = { "level", "seconds" },

	continue_offer = { "level", "k", "price", "affordable" },
	continue_buy = { "level", "k", "price" },
	ad_offer = { "placement", "available" },
	ad_watch = { "placement", "ok", "reason" },
	booster_use = { "level", "id", "kind" },
	booster_buy = { "id", "count", "price" },
	lives_refill = { "price" },
	lives_out = { "level" },

	economy = { "item", "delta", "balance", "reason", "flow" },
	chest_open = { "kind", "level", "district", "coins" },
	iap_attempt = { "product" },
	iap_result = { "product", "ok", "reason" },

	task_complete = { "district", "task", "cost", "stem" },
	district_complete = { "district" },
	jukebox_play = { "district" },
	settings_change = { "key", "value" },

	save_error = { "error" },
	lua_error = { "message" },
}

M.MAX_QUEUE = 500

local queue = {}
local seq = 0
local sink = nil
local clock = function() return os.time() end
local strict = false
local echo = false
local quiet = false

-- opts: {strict = bool (error on bad events; use in debug), echo = bool
-- (print events), quiet = bool (no warnings), clock = fn() -> seconds,
-- sink = fn(event)}
function M.init(opts)
	opts = opts or {}
	strict = opts.strict and true or false
	echo = opts.echo and true or false
	quiet = opts.quiet and true or false
	if opts.clock then clock = opts.clock end
	sink = opts.sink
	queue, seq = {}, 0
end

function M.set_sink(fn)
	sink = fn
end

local function validate(name, params)
	local allowed = M.EVENTS[name]
	if not allowed then return false, "unknown analytics event '" .. tostring(name) .. "'" end
	if params ~= nil and type(params) ~= "table" then return false, "params of '" .. name .. "' must be a table" end
	if params then
		local ok = {}
		for _, p in ipairs(allowed) do ok[p] = true end
		for k in pairs(params) do
			if not ok[k] then return false, "event '" .. name .. "' has no param '" .. tostring(k) .. "'" end
		end
	end
	return true
end

-- Logs an event. Returns the event, or nil and the reason when it is invalid.
function M.log(name, params)
	local ok, why = validate(name, params)
	if not ok then
		if strict then error("analytics: " .. why, 2) end
		if not quiet then print("WARNING: analytics: " .. why) end
		return nil, why
	end
	seq = seq + 1
	local ev = { name = name, params = params or {}, t = clock(), seq = seq }
	queue[#queue + 1] = ev
	if #queue > M.MAX_QUEUE then table.remove(queue, 1) end
	if echo then print("analytics: " .. name) end
	if sink then
		local sok, err = pcall(sink, ev)
		if not sok then print("WARNING: analytics sink: " .. tostring(err)) end
	end
	return ev
end

-- Converts meta:drain_ledger() entries into "economy" events.
function M.log_ledger(entries)
	for _, e in ipairs(entries or {}) do
		M.log("economy", { item = e.item, delta = e.delta, balance = e.balance, reason = e.reason, flow = e.flow })
	end
end

-- Queued events since the last drain (oldest first); clears the queue.
function M.drain()
	local out = queue
	queue = {}
	return out
end

-- The last n events without removing them.
function M.recent(n)
	n = n or 10
	local out = {}
	for i = math.max(1, #queue - n + 1), #queue do out[#out + 1] = queue[i] end
	return out
end

function M.count()
	return seq
end

return M
