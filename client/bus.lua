-- Event bus with one queue per subscriber (pure Lua, no Defold API).
--
-- publish() never calls subscriber code: it only appends the event to the
-- queue of every interested subscriber. Each subscriber drains its own queue
-- in its own update(), so a GUI script handles events in the GUI context and
-- a game object script in its context (Defold forbids gui.* calls from other
-- scripts). Delivery order = publish order.
--
--   local bus = require("client.bus")
--   self.sub = bus.subscribe({"meta_changed", "settings_changed"}, "town")
--   ...
--   function update(self, dt)
--       self.sub:drain(function(topic, payload) ... end)
--   end
--   function final(self) self.sub:close() end
--
--   bus.publish("meta_changed", {revision = 12})
--
-- Topics used by the client (see client/app.lua, main/app.script):
--   meta_changed      {revision, reason}    the meta state changed (coins, lives, ...)
--   settings_changed  {key, value}          a setting changed (key "*" after a save reset)
--   language_changed  {language}            UI strings must be refreshed
--   screen_leaving    {from, to}            a transition starts (modals of the old screen close)
--   screen_changed    {name, prev, params}  a screen finished its fade-in
--   modal_result      {id, button}          an overlay modal was closed; button "close",
--                                           "replaced", "screen_changed" or a button id
--   lives_tick        {now}                 once per second, for timers
--   save_failed       {error, streak}       a save write failed (retried every second)
--   save_recovered    {after}               the first successful save after failures
--   save_reset        {}                    debug: the save was wiped
--   app_focus         {focused, event}      focus / iconify changes (client/hooks.lua)
--
-- A subscriber that stops draining (a disabled screen) cannot grow without
-- bound: past max_queue the oldest events are dropped and counted.

local M = {}

local Bus = {}
Bus.__index = Bus

local Sub = {}
Sub.__index = Sub

local DEFAULT_MAX_QUEUE = 256

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		subs = {},       -- list, in subscription order
		next_id = 0,
		max_queue = opts.max_queue or DEFAULT_MAX_QUEUE,
		published = 0,
	}, Bus)
end

local function topic_set(topics)
	if topics == nil or topics == "*" then return nil end
	local set = {}
	if type(topics) == "string" then
		set[topics] = true
	elseif type(topics) == "table" then
		for _, t in ipairs(topics) do
			if type(t) ~= "string" then error("bus: topics must be strings", 3) end
			set[t] = true
		end
	else
		error("bus: topics must be nil, '*', a string or a list of strings", 3)
	end
	return set
end

-- topics: nil or "*" (everything), a topic string, or a list of topics.
-- name: optional label for debugging.
function Bus:subscribe(topics, name)
	self.next_id = self.next_id + 1
	local sub = setmetatable({
		id = self.next_id,
		name = name or ("sub" .. self.next_id),
		bus = self,
		topics = topic_set(topics),
		q_topic = {},
		q_payload = {},
		head = 1,
		tail = 0,
		dropped = 0,
		closed = false,
	}, Sub)
	self.subs[#self.subs + 1] = sub
	return sub
end

function Bus:unsubscribe(sub)
	for i = #self.subs, 1, -1 do
		if self.subs[i] == sub then table.remove(self.subs, i) end
	end
	sub.closed = true
	sub:clear()
end

local function push(sub, topic, payload, max)
	if sub.tail - sub.head + 1 >= max then
		sub.q_topic[sub.head], sub.q_payload[sub.head] = nil, nil
		sub.head = sub.head + 1
		sub.dropped = sub.dropped + 1
	end
	sub.tail = sub.tail + 1
	sub.q_topic[sub.tail] = topic
	sub.q_payload[sub.tail] = payload
end

-- Queues the event for every interested subscriber; returns how many got it.
-- payload is shared, not copied: treat it as read-only.
function Bus:publish(topic, payload)
	if type(topic) ~= "string" then error("bus: topic must be a string", 2) end
	self.published = self.published + 1
	local n = 0
	for i = 1, #self.subs do
		local s = self.subs[i]
		if s.topics == nil or s.topics[topic] then
			push(s, topic, payload, self.max_queue)
			n = n + 1
		end
	end
	return n
end

-- Number of subscribers (handy in tests and debug overlays).
function Bus:count()
	return #self.subs
end

-- Subscriber ------------------------------------------------------------------

function Sub:pending()
	return self.tail - self.head + 1
end

function Sub:clear()
	self.q_topic, self.q_payload = {}, {}
	self.head, self.tail = 1, 0
end

-- Calls handler(topic, payload) for each queued event, oldest first. Events
-- published while draining (also by the handler itself) wait for the next
-- drain, so a handler that republishes cannot loop forever. Returns the
-- number of events handled. A handler error leaves the rest of the batch
-- queued and propagates.
function Sub:drain(handler)
	local last = self.tail
	local n = 0
	while self.head <= last do
		local i = self.head
		local topic, payload = self.q_topic[i], self.q_payload[i]
		self.q_topic[i], self.q_payload[i] = nil, nil
		self.head = i + 1
		n = n + 1
		handler(topic, payload)
	end
	if self.head > self.tail then
		self.head, self.tail = 1, 0
	end
	return n
end

function Sub:close()
	if not self.closed then self.bus:unsubscribe(self) end
end

-- Default bus shared by every script (script.shared_state = 1) -----------------

M.default = M.new()

function M.subscribe(topics, name) return M.default:subscribe(topics, name) end
function M.publish(topic, payload) return M.default:publish(topic, payload) end
function M.unsubscribe(sub) return M.default:unsubscribe(sub) end

return M
