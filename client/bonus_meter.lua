-- The bonus meter of a level (WP-5; pure Lua, no Defold calls): a bar that fills while specials fire. A Bird or
-- a Riff gives 1 point, a Sabwoofer 2, a Disco ball 3; at THRESHOLD points the player gets one random special
-- of the four as a gift, put on the board by the core command `bonus` (core/input.lua) at the next rest.
--
-- The points come from what the player SEES: the core's `activate` events (a special that fires). A special
-- that is made does not count, a Bird's cargo (an `activate` without an id) does not count twice, and a special
-- counts once (its id). A combo counts the points of both specials. The meter lives in the session, not in
-- the core: it is not in the game's hash and the bots do not play with it (levels.lua stats stay the levels'),
-- and a replay holds the gift as an ordinary `bonus` command, so a replayed game is the same game.
--
--   local meter = require("client.bonus_meter").new({seed = session.seed, level_id = 12})
--   local adds = meter:feed(events)    -- the events of one tick -> {{n, special, combo, x, y, id, total, fill}, ...}
--   meter:gift()                       -- the special waiting to be put on the board, or nil
--   meter:given()                      -- the core took it: the next one may come
--   meter.points, meter.threshold      -- 0 .. threshold - 1 after a fill the rest is carried over
--   meter:snapshot()                   -- plain state for the QA bridge
--
-- Everything the producer may want to change is in M (constants), nothing else knows the numbers.

local R = require("core.rng")

local M = {}

M.POINTS = { bird = 1, riff = 1, sub = 2, disco = 3 }   -- per special that fires
M.THRESHOLD = 10                                         -- points for one gift
M.GIFTS = { "bird", "riff", "sub", "disco" }              -- what a gift can be
M.WEIGHTS = { bird = 1, riff = 1, sub = 1, disco = 1 }   -- equal chances
M.MIN_LEVEL = 3                                          -- the first two levels teach the match: no meter there
M.UNLOCK = { riff = 2, sub = 4, bird = 6, disco = 9 }    -- a gift is a special the player has met (content/tutorials.json)
M.MAX_QUEUE = 3                                          -- gifts waiting for a free moment (a long chain)

-- The two specials of a combo (core/combos.lua names), so that its points are the sum of both.
M.COMBO = {
	cross = { "riff", "riff" }, triple_cross = { "riff", "sub" }, bird_riff = { "bird", "riff" },
	color_riff = { "riff", "disco" }, bass_drop = { "sub", "sub" }, bird_sub = { "bird", "sub" },
	color_sub = { "sub", "disco" }, trio = { "bird", "bird" }, color_bird = { "bird", "disco" },
	finale = { "disco", "disco" },
}

-- Is there a meter on this level?
function M.enabled_for(level_id)
	return (tonumber(level_id) or 0) >= M.MIN_LEVEL
end

-- Points of one `activate` event: 0 for what does not count.
function M.points_of(e)
	if type(e) ~= "table" or e.id == nil then return 0 end -- a cargo special of a Bird: part of the Bird's own fire
	if e.combo and M.COMBO[e.combo] then
		local pair = M.COMBO[e.combo]
		return (M.POINTS[pair[1]] or 0) + (M.POINTS[pair[2]] or 0)
	end
	return M.POINTS[e.special] or 0
end

-- The n-th gift of a run: deterministic from the game's seed, with the weights above (the core's weighted choice)
-- among the specials unlocked at `level_id` (all four when it is nil).
function M.pick(seed, n, level_id)
	local st = R.stream(R.fold_seed(tonumber(seed) or 1, n, 91), 1)
	local codes, weights, names = {}, {}, {}
	for i = 1, #M.GIFTS do
		local g = M.GIFTS[i]
		local w = M.WEIGHTS[g] or 0
		if level_id and (tonumber(level_id) or 0) < (M.UNLOCK[g] or 0) then w = 0 end
		if w > 0 then
			codes[#codes + 1] = #codes + 1
			weights[#codes] = w
			names[#codes] = g
		end
	end
	if #codes == 0 then return M.GIFTS[1] end
	return names[R.weighted(st, codes, weights)]
end

local Meter = {}
Meter.__index = Meter

-- opts: {seed = the game's seed, level_id, enabled = bool (default: by level), threshold = n}
function M.new(opts)
	opts = opts or {}
	local enabled = opts.enabled
	if enabled == nil then enabled = M.enabled_for(opts.level_id) end
	return setmetatable({
		seed = tonumber(opts.seed) or 1,
		level_id = tonumber(opts.level_id),
		enabled = enabled and true or false,
		threshold = tonumber(opts.threshold) or M.THRESHOLD,
		points = 0,        -- the bar: 0 .. threshold - 1 (a fill carries the rest over)
		earned = 0,        -- all points ever added (the QA bridge, the tests)
		made = 0,          -- gifts made so far
		queue = {},        -- gifts that wait for a rest
		seen = {},         -- ids of the specials that were counted
	}, Meter)
end

-- Feeds the events of one tick; returns the additions {n, special, combo, x, y, id, total, fill} in order.
-- `fill` is true on the addition that made a gift (`total` is then the bar before the carry-over: threshold or more).
function Meter:feed(events)
	if not self.enabled or not events then return nil end
	local out
	for i = 1, #events do
		local e = events[i]
		if e.type == "activate" then
			local n = M.points_of(e)
			if n > 0 and not self.seen[e.id] then
				self.seen[e.id] = true
				self.earned = self.earned + n
				local total = self.points + n
				local add = { n = n, special = e.special, combo = e.combo, x = e.x, y = e.y, id = e.id, total = total, fill = false }
				self.points = total
				if total >= self.threshold then
					add.fill = true
					self.points = total - self.threshold
					if #self.queue < M.MAX_QUEUE then
						self.made = self.made + 1
						self.queue[#self.queue + 1] = M.pick(self.seed, self.made, self.level_id)
					end
				end
				out = out or {}
				out[#out + 1] = add
			end
		end
	end
	return out
end

-- The gift that waits to be put on the board, or nil.
function Meter:gift()
	return self.queue[1]
end

-- The core took the gift: drop it from the queue.
function Meter:given()
	table.remove(self.queue, 1)
end

function Meter:snapshot()
	return { enabled = self.enabled, points = self.points, threshold = self.threshold, earned = self.earned,
		made = self.made, waiting = #self.queue, next = self.queue[1] }
end

return M
