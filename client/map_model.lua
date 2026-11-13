-- Model of the game map (pure Lua, no GUI): where the levels sit on the long vertical map, which of
-- them the screen has to draw for a given scroll position, what state each one is in, where the
-- trail dots and the district gates are. The data is content/map.json (format: docs/handoff/WP-7.md).
--
--   local map_model = require("client.map_model")
--   local m = map_model.new(map_model.read())      -- or map_model.new(decoded_table)
--   m.world_h                                      -- height of the map (world px, y up from the bottom)
--   m:node(n)                                      -- {level, x, y}
--   m:state(n, next_level)                         -- "done" | "current" | "locked"
--   m:kind(n)                                      -- "day" | "concert" (the concert levels of stars.json)
--   m:visible(off, view_h, margin)                 -- first, last level to draw (numbers, no table)
--   m:dots(first, last)                            -- first, last trail dot between those levels
--   m:dot(g)                                       -- x, y, level the dot leads on from (a dot of a done stretch: g <= m:dot_end(next))
--   m:path_pos(u)                                  -- x, y of a point on the path; u = 3.5 is halfway from level 3 to 4
--   m:pick(wx, wy)                                 -- the level whose node is under a world point, or nil
--   m:segment_at(y)                                -- index of the segment (district stretch) holding a world y
--   m:tiles(seg, off, view_h, margin)              -- first, last background tile of a segment in view
--
-- World coordinates: x 0..720 to the right, y UP from the bottom of the map. `off` is the world y at the
-- bottom edge of the window; the screen y of a world point is y - off.
-- Hot path functions (visible, dots, dot, path_pos, pick, tiles) return numbers only: no allocation.

local M = {}

M.PATH = "/content/map.json"
M.PICK_PAD = 14        -- px a tap may miss a node's circle by

local Map = {}
Map.__index = Map

local function smooth(t)
	return t * t * (3 - 2 * t)
end

-- test hooks: fn(path) -> text | nil ; fn(text) -> table
M.read_file = nil
M.decode = nil

-- The decoded content/map.json (loaded through Defold's sys.load_resource and json.decode).
function M.read()
	local text
	if M.read_file then
		text = M.read_file(M.PATH)
	elseif sys and sys.load_resource then
		local ok, data = pcall(sys.load_resource, M.PATH)
		if ok then text = data end
	end
	if not text then return nil, "map.json missing" end
	local fn = M.decode or (json and json.decode)
	if not fn then return nil, "no json decoder" end
	local ok, t = pcall(fn, text)
	if not ok or type(t) ~= "table" then return nil, "map.json broken" end
	return t
end

-- Checks the rules of the data; returns true or false, "what is wrong".
function M.validate(data)
	if type(data) ~= "table" then return false, "not a table" end
	local count = data.level_count
	if type(count) ~= "number" or count < 1 then return false, "level_count" end
	local nodes = data.nodes
	if type(nodes) ~= "table" or #nodes ~= count then return false, "nodes: one per level" end
	local last_y = -1
	for i = 1, count do
		local n = nodes[i]
		if type(n) ~= "table" or n.level ~= i then return false, "node " .. i .. " out of order" end
		if type(n.x) ~= "number" or type(n.y) ~= "number" then return false, "node " .. i .. " has no x, y" end
		if n.x < 0 or n.x > (data.width or 720) then return false, "node " .. i .. " outside the map" end
		if n.y <= last_y then return false, "node " .. i .. " is not above the one before" end
		if n.y > data.world_height then return false, "node " .. i .. " above the map" end
		last_y = n.y
	end
	local segs = data.segments
	if type(segs) ~= "table" or #segs < 1 then return false, "segments" end
	local expect = 1
	for i, s in ipairs(segs) do
		if s.first ~= expect or s.last < s.first then return false, "segment " .. i .. " does not follow the one before" end
		if type(s.y0) ~= "number" or type(s.y1) ~= "number" or s.y1 <= s.y0 then return false, "segment " .. i .. " y range" end
		if i > 1 and s.y0 ~= segs[i - 1].y1 then return false, "segment " .. i .. " leaves a hole" end
		if nodes[s.first].y < s.y0 or nodes[s.last].y > s.y1 then return false, "segment " .. i .. " does not hold its levels" end
		expect = s.last + 1
	end
	if expect ~= count + 1 then return false, "segments do not cover every level" end
	if segs[1].y0 ~= 0 or segs[#segs].y1 ~= data.world_height then return false, "segments do not cover the map" end
	for _, k in ipairs({ "day", "concert" }) do
		local nd = data.node and data.node[k]
		if not (nd and nd.size and nd.states and nd.states.locked and nd.states.current and nd.states.done and nd.states.open) then
			return false, "the picture set of the " .. k .. " node"
		end
	end
	if not (data.path and data.path.dot and data.path.dot_done and data.path.spacing and data.path.spacing > 0) then return false, "path" end
	if not (data.tile_h and data.tile_h > 0) then return false, "tile_h" end
	return true
end

-- opts = {kind_of = function(level) -> "concert" | other}  (default: nobody is a concert)
function M.new(data, opts)
	local ok, why = M.validate(data)
	if not ok then error("map_model: " .. tostring(why), 2) end
	opts = opts or {}
	local self = setmetatable({}, Map)
	self.data = data
	self.count = data.level_count
	self.world_h = data.world_height
	self.width = data.width or 720
	self.tile_h = data.tile_h
	-- The tiles of a district overlap: a tile starts tile_step above the one below it and its faded bottom edge
	-- (tile_feather px, transparent in the picture) lies over the top of that one, so the sky at the top of the
	-- picture is never seen in the middle of the map. Without these fields the tiles stand edge to edge.
	self.tile_step = data.tile_step or data.tile_h
	self.tile_feather = data.tile_feather or 0
	self.nodes = data.nodes
	self.segments = data.segments
	self.kind_of = opts.kind_of
	self.spacing = data.path.spacing
	self.data = data
	-- trail dots: gap i (between level i and i + 1) holds k[i] dots; dot_first[i] = dots before that gap
	self.k, self.dot_first = {}, {}
	local total = 0
	for i = 1, self.count - 1 do
		local a, b = self.nodes[i], self.nodes[i + 1]
		local dx, dy = b.x - a.x, b.y - a.y
		local len = math.sqrt(dx * dx + dy * dy)
		-- the trail starts and ends a node radius away from the circles
		local free = len - 2 * (self:hit_radius_of("day") + 6)
		local k = math.max(1, math.floor(free / self.spacing + 0.5))
		self.k[i] = k
		self.dot_first[i] = total
		total = total + k
	end
	self.dot_total = total
	self.concert = {}
	for n = 1, self.count do
		self.concert[n] = opts.kind_of ~= nil and opts.kind_of(n) == "concert" or false
	end
	return self
end

-- The radius of a node's circle in the picture (the sprite has an empty margin around it): `hit` of the data.
function Map:hit_radius_of(kind)
	local d = self.data.node[kind]
	return d.hit or d.size * 0.35
end

function Map:node(n)
	return self.nodes[n]
end

function Map:kind(n)
	return self.concert[n] and "concert" or "day"
end

-- "done" (beaten: replay it), "current" (the one to play), "locked". next_level = nil: every level is beaten.
function Map:state(n, next_level)
	if next_level == nil or n < next_level then return "done" end
	if n == next_level then return "current" end
	return "locked"
end

function Map:size(n)
	return self.data.node[self.concert[n] and "concert" or "day"].size
end

-- Levels (first, last) whose node centre is within [off - margin, off + view_h + margin]; nodes rise with the level.
function Map:visible(off, view_h, margin)
	local lo_y, hi_y = off - margin, off + view_h + margin
	local nodes, n = self.nodes, self.count
	-- first node with y >= lo_y
	local a, b = 1, n + 1
	while a < b do
		local mid = math.floor((a + b) / 2)
		if nodes[mid].y >= lo_y then b = mid else a = mid + 1 end
	end
	local first = a
	-- last node with y <= hi_y
	a, b = 0, n
	while a < b do
		local mid = math.floor((a + b + 1) / 2)
		if nodes[mid].y <= hi_y then a = mid else b = mid - 1 end
	end
	return first, a
end

-- Most levels that can be in a window of h px at once (sizes the pools of the screen).
function Map:max_in_window(h)
	local best, j = 0, 1
	for i = 1, self.count do
		while j < self.count and self.nodes[j + 1].y - self.nodes[i].y <= h do j = j + 1 end
		if j - i + 1 > best then best = j - i + 1 end
	end
	return best
end

-- Trail dots (first, last) that belong to the gaps touched by levels first..last (a gap before and after).
function Map:dots(first, last)
	local g0 = first > 1 and self.dot_first[first - 1] + 1 or 1
	local gap = last < self.count and last or self.count - 1
	local g1 = gap >= 1 and (self.dot_first[gap] + self.k[gap]) or 0
	if first > self.count then return 1, 0 end
	return g0, g1
end

-- Most trail dots touched by any `levels` levels in a row (the pool size).
function Map:max_dots(levels)
	local best = 0
	for first = 1, self.count do
		local a, b = self:dots(first, math.min(self.count, first + levels - 1))
		if b - a + 1 > best then best = b - a + 1 end
	end
	return best
end

-- The gap (level it leads on from) that holds dot g, binary search over the gaps.
function Map:dot_gap(g)
	local a, b = 1, self.count - 1
	while a < b do
		local mid = math.floor((a + b + 1) / 2)
		if self.dot_first[mid] < g then a = mid else b = mid - 1 end
	end
	return a
end

-- The last dot of the trail that leads up to level n (all dots up to it are walked once n is reached).
function Map:dot_end(n)
	if n <= 1 then return 0 end
	if n > self.count then return self.dot_total end
	return self.dot_first[n - 1] + self.k[n - 1]
end

-- Position of a point on the path: u = 1 is level 1, u = 1.5 halfway to level 2. The sideways swing is eased
-- (the trail leaves and enters every node straight up).
function Map:path_pos(u)
	if u <= 1 then return self.nodes[1].x, self.nodes[1].y end
	if u >= self.count then return self.nodes[self.count].x, self.nodes[self.count].y end
	local i = math.floor(u)
	local t = u - i
	local a, b = self.nodes[i], self.nodes[i + 1]
	return a.x + (b.x - a.x) * smooth(t), a.y + (b.y - a.y) * t
end

-- Position of dot g and the gap it sits in.
function Map:dot(g)
	local i = self:dot_gap(g)
	local j = g - self.dot_first[i]       -- 1..k
	local a, b = self.nodes[i], self.nodes[i + 1]
	local k = self.k[i]
	-- the dots are spread over the middle of the gap, away from the two circles
	local len = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
	local pad = (self:hit_radius_of("day") + 6) / len
	local t = pad + (1 - 2 * pad) * j / (k + 1)
	return a.x + (b.x - a.x) * smooth(t), a.y + (b.y - a.y) * t, i
end

-- The level whose node is under the world point (wx, wy), or nil. The nearest one wins.
function Map:pick(wx, wy)
	local first, last = self:visible(wy, 0, 120)
	local best, best_d = nil, nil
	for n = first, last do
		local nd = self.nodes[n]
		local r = self:hit_radius_of(self.concert[n] and "concert" or "day") + M.PICK_PAD
		local dx, dy = nd.x - wx, nd.y - wy
		local d = dx * dx + dy * dy
		if d <= r * r and (best_d == nil or d < best_d) then best, best_d = n, d end
	end
	return best
end

-- Index of the segment that holds world y.
function Map:segment_at(y)
	for i, s in ipairs(self.segments) do
		if y < s.y1 then return i end
	end
	return #self.segments
end

-- World y of the bottom edge of tile `idx` of segment `seg` (tile 0 starts tile_feather below the segment).
function Map:tile_y(seg, idx)
	return self.segments[seg].y0 - self.tile_feather + idx * self.tile_step
end

-- Background tiles of segment `seg` (first, last; tile 0 is the lowest) that touch the window.
function Map:tiles(seg, off, view_h, margin)
	local s = self.segments[seg]
	local lo, hi = off - margin, off + view_h + margin
	local base = s.y0 - self.tile_feather
	if hi <= base or lo >= s.y1 then return 1, 0 end
	lo, hi = math.max(lo, base), math.min(hi, s.y1 - 1)
	-- tile i covers base + i * step .. base + i * step + tile_h
	local first = math.max(0, math.floor((lo - base - self.tile_h) / self.tile_step) + 1)
	return first, math.floor((hi - base) / self.tile_step)
end

-- Highest scroll offset for a window of view_h px.
function Map:max_off(view_h)
	return math.max(0, self.world_h - view_h)
end

-- The offset that puts world point y at `frac` of the window height (0 = bottom, 1 = top), clamped.
function Map:off_for(y, view_h, frac)
	local off = y - view_h * (frac or 0.4)
	if off < 0 then return 0 end
	local mx = self:max_off(view_h)
	if off > mx then return mx end
	return off
end

return M
