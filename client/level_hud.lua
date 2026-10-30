-- The geometry and the small state machines of the level HUD (pure Lua; the
-- GUI side is screens/level/level.gui_script + screens/level/hud.lua).
--
-- Everything here is in logical coordinates (720x1280, y up, client/layout.lua)
-- and absolute: the top row (pause, goals, moves) hangs from the top edge of
-- the safe area and the booster bar stands on its bottom edge, exactly as
-- client/ui.lua anchors them; the board rectangle comes from the board.
--
--   local level_hud = require("client.level_hud")
--   local l = level_hud.layout(layout.fit(ww, wh), insets, link.board_rect())
--   l.pause, l.goals, l.moves, l.bar          -- {cx, cy, w, h, x0, y0, x1, y1}
--   l.board, l.safe, l.top_shift, l.bottom_shift
--   l.slot                                    -- where Bit stands: {x, y, size, where, tappable}
--   level_hud.goal_slots(n)                   -- x offsets of n goal icons inside the goals panel
--   level_hud.booster_state(info, ctx)        -- how a booster button looks
--   level_hud.booster_tap(id, state, ctx)     -- what a tap on it does
--   level_hud.goals_new(counts)               -- the goal counters (flights decide when they change)
--   level_hud.moves_state(left)               -- {low, danger}
--   level_hud.score_feed()                    -- merges the score events of one burst into one pop
--   level_hud.spotlight(vis, hole), level_hud.hole(centres, cell, pad)   -- the tutorial's dim and its hole
--   level_hud.hand_pose(mode, pts, t)         -- where the tutorial's pointing hand is at time t
--   level_hud.bubble_rect(vis, board, hole, w, h)   -- where the tutorial's text bubble goes
--   level_hud.overlaps(a, b)                  -- do two rectangles share some area

local layout = require("client.layout")

local M = {}

-- design positions (logical px, y up). The top row is anchored to the safe top, the bar to the safe bottom.
M.TOP_Y = 1170                                    -- centre of the top row (110 px below the design top)
M.PAUSE = { x = 62, w = 96, h = 96 }
M.GOALS = { x = 330, w = 420, h = 176 }
M.MOVES = { x = 632, w = 160, h = 160 }
M.BAR = { x = 360, y = 70, w = 704, h = 132 }     -- centre y of the booster bar (anchored to the bottom)
M.BAR_BUTTONS = { x0 = -268, gap = 134, w = 104, h = 96 } -- relative to the bar's centre: five in 704 px, their badges inside the bar
M.FRAME = 20                                      -- the board's frame outside its cells (level_bg.gui_script)
M.BIT_MAX, M.BIT_MIN, M.BIT_TINY = 150, 96, 64
M.LOW_MOVES = 5                                   -- the moves badge pulses and reddens at <= 5
M.BOOSTERS = { "stick", "row_light", "col_light", "remix", "swap" }

local function rect(cx, cy, w, h)
	return { cx = cx, cy = cy, w = w, h = h, x0 = cx - w / 2, x1 = cx + w / 2, y0 = cy - h / 2, y1 = cy + h / 2 }
end
M.rect = rect

local function max(a, b) return a > b and a or b end
local function min(a, b) return a < b and a or b end

-- Do two rectangles ({x0, y0, x1, y1}) cover a common area? (touching edges do not)
function M.overlaps(a, b)
	return a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1
end

-- Where Bit stands, from the free room around the board (layout `l` without
-- a slot yet): beside the board when the window or a narrow board leaves
-- room, else under it above the booster bar, else above it, else squeezed
-- into the corner (then he is not tappable). He may stand in front of the
-- board's frame (decoration), never over its cells.
function M.bit_slot(l)
	local b, safe, pad = l.board, l.safe, 8
	if not b then
		return { x = 80, y = l.bar.y1 + 76, size = 120, where = "bottom", tappable = true }
	end
	local lw = b.x0 - safe.x0 - 2 * pad
	local rw = safe.x1 - b.x1 - 2 * pad
	local w, side = lw, "left"
	if rw > lw then w, side = rw, "right" end
	if w >= M.BIT_MIN then
		local size = min(M.BIT_MAX, w)
		local x = side == "left" and (b.x0 - pad - size / 2) or (b.x1 + pad + size / 2)
		local y = max(b.y0 + size / 2, l.bar.y1 + pad + size / 2)
		return { x = x, y = y, size = size, where = side, tappable = true }
	end
	local below = b.y0 - l.bar.y1 - 2 * pad
	if below >= M.BIT_MIN then
		local size = min(M.BIT_MAX, below)
		return { x = max(b.x0, safe.x0 + pad) + size / 2, y = l.bar.y1 + pad + size / 2, size = size, where = "bottom",
			tappable = true }
	end
	local above = min(l.goals.y0, l.moves.y0) - b.y1 - 2 * pad
	if above >= M.BIT_MIN then
		local size = min(M.BIT_MAX, above)
		return { x = max(b.x0, safe.x0 + pad) + size / 2, y = b.y1 + pad + size / 2, size = size, where = "top",
			tappable = true }
	end
	-- squeezed: between the bar and the lowest cells
	local size = min(M.BIT_MIN, max(M.BIT_TINY, b.y0 - l.bar.y1 - 2))
	return { x = max(b.x0, safe.x0 + pad) + size / 2, y = l.bar.y1 + size / 2 + 1, size = size, where = "corner",
		tappable = false }
end

-- The HUD rectangles for a window (fit = layout.fit, insets = window.get_safe_area() or nil,
-- board = link.board_rect() or nil).
function M.layout(fit, insets, board)
	local safe = layout.safe_rect(fit, insets)
	local ts, bs = safe.y1 - layout.H, safe.y0
	local l = {
		safe = safe, top_shift = ts, bottom_shift = bs, fit = fit,
		pause = rect(M.PAUSE.x, M.TOP_Y + ts, M.PAUSE.w, M.PAUSE.h),
		goals = rect(M.GOALS.x, M.TOP_Y + ts, M.GOALS.w, M.GOALS.h),
		moves = rect(M.MOVES.x, M.TOP_Y + ts, M.MOVES.w, M.MOVES.h),
		bar = rect(M.BAR.x, M.BAR.y + bs, M.BAR.w, M.BAR.h),
	}
	if board then
		l.board = { x0 = board.x0, y0 = board.y0, x1 = board.x1, y1 = board.y1, cell = board.cell }
	end
	l.slot = M.bit_slot(l)
	return l
end

-- x offsets (from the panel's centre) and sizes of n goal icons in the goals panel.
function M.goal_slots(n)
	n = math.max(1, math.min(3, n))
	local w = M.GOALS.w
	local out = { icon = n == 3 and 76 or 84, text = n == 3 and 40 or 44, xs = {} }
	for k = 1, n do out.xs[k] = -w / 2 + w * (k - 0.5) / n end
	return out
end

-- the buttons of the booster bar: x offsets from the bar's centre
function M.bar_slots()
	local b = M.BAR_BUTTONS
	local xs = {}
	for i = 1, #M.BOOSTERS do xs[i] = b.x0 + (i - 1) * b.gap end
	return xs
end

-- boosters -----------------------------------------------------------------------------------------

-- Game states in which a booster may be used (core-rules.md 5.3: playing and out_of_moves).
M.USABLE = { playing = true, out_of_moves = true }

-- How a booster button looks. info = {count = n | nil (a debug level: free boosters), unlocked, unlock_level}.
-- Returns {mode = "locked" | "empty" | "ready", count, badge (show the count), plus, lock, dim}.
function M.booster_state(info)
	info = info or {}
	if not info.unlocked then
		return { mode = "locked", lock = true, dim = true, unlock_level = info.unlock_level }
	end
	if info.count ~= nil and info.count <= 0 then
		return { mode = "empty", plus = true, dim = false, count = 0 }
	end
	return { mode = "ready", badge = info.count ~= nil, count = info.count }
end

-- What a tap on a booster button does, given its state and
-- ctx = {state = core game state, targeting = booster id | nil, allowed = false when the tutorial forbids it}:
-- "blocked" (the tutorial) | "cancel" | "locked" | "buy" | "wait" (the game is not in a state for it) | "start".
function M.booster_tap(id, st, ctx)
	ctx = ctx or {}
	if ctx.allowed == false then return "blocked" end
	if ctx.targeting == id then return "cancel" end
	if st.mode == "locked" then return "locked" end
	-- (before the empty stock is looked at: once the win is certain nothing is sold or started. The purchase window stops
	-- the session like the pause window, which is blocked there on purpose, and froze the finale's effects on the board)
	if not M.USABLE[ctx.state or "playing"] then return "wait" end
	if st.mode == "empty" then return "buy" end
	return "start"
end

-- The text key of the target-mode prompt of a booster; PROMPT2 is the prompt of the second pick of the Crossfader,
-- which takes two pieces (its first one is chosen).
M.PROMPT = { stick = "hud.pick_cell", row_light = "hud.pick_row", col_light = "hud.pick_col", swap = "hud.pick_two" }
M.PROMPT2 = { swap = "hud.pick_second" }

-- The toast for a booster the core refused (its reason): the board is still moving -> wait for it; a Remix with
-- nothing to shuffle; a Crossfader on a piece that cannot move, or on two alike; anything else (a spot with
-- nothing to do) -> pick another spot.
M.REFUSAL = { not_rest = "hud.wait_board", no_candidates = "hud.remix_no", not_movable = "hud.swap_fixed",
	same_piece = "hud.swap_same" }
function M.refusal_key(reason)
	return M.REFUSAL[reason] or "hud.booster_no"
end

-- goals --------------------------------------------------------------------------------------------

local Goals = {}
Goals.__index = Goals

M.MAX_FLYING = 8 -- flights per goal at once; more events are shown at once

-- counts = what is left of each goal at the start (core status().goals).
function M.goals_new(counts)
	local g = setmetatable({ shown = {}, flying = {}, total = {} }, Goals)
	for i, c in ipairs(counts or {}) do
		g.shown[i], g.total[i], g.flying[i] = c, c, 0
	end
	return g
end

-- A goal went down to `left`. Returns "fly" (send a flyer; call land() when it arrives) or
-- "set", changed (the counter was changed at once: no place to fly from, or too much is on its way).
function Goals:event(index, left, can_fly)
	if self.shown[index] == nil then return "set", false end
	if can_fly and (self.flying[index] or 0) < M.MAX_FLYING then
		self.flying[index] = (self.flying[index] or 0) + 1
		return "fly"
	end
	return "set", self:set(index, left)
end

-- the counter only goes down
function Goals:set(index, left)
	if self.shown[index] == nil then return false end
	left = math.max(0, left)
	if left < self.shown[index] then
		self.shown[index] = left
		return true
	end
	return false
end

-- A flyer arrived: the counter shows `left` (never up again). Returns true when it changed.
function Goals:land(index, left)
	if self.flying[index] and self.flying[index] > 0 then self.flying[index] = self.flying[index] - 1 end
	return self:set(index, left)
end

function Goals:done(index)
	return self.shown[index] ~= nil and self.shown[index] <= 0
end

function Goals:all_done()
	for i = 1, #self.shown do
		if self.shown[i] > 0 then return false end
	end
	return #self.shown > 0
end

-- 0..1 of a goal that is done
function Goals:progress(index)
	local t = self.total[index]
	if not t or t <= 0 then return 1 end
	return 1 - self.shown[index] / t
end

-- moves --------------------------------------------------------------------------------------------

-- {low (pulse and redden), danger (the last two)}
function M.moves_state(left)
	left = tonumber(left) or 0
	return { low = left > 0 and left <= M.LOW_MOVES, danger = left > 0 and left <= 2 }
end

-- tutorial: spotlight, hand, bubble --------------------------------------------------------------------------

-- The dim around a hole: four rectangles that cover `vis` (the visible window) except `hole`
-- ({x0, y0, x1, y1}); empty ones are left out.
function M.spotlight(vis, hole)
	local h = {
		x0 = max(vis.x0, min(hole.x0, vis.x1)), x1 = min(vis.x1, max(hole.x1, vis.x0)),
		y0 = max(vis.y0, min(hole.y0, vis.y1)), y1 = min(vis.y1, max(hole.y1, vis.y0)),
	}
	local out = {}
	local function add(x0, y0, x1, y1)
		if x1 - x0 > 0.5 and y1 - y0 > 0.5 then out[#out + 1] = rect((x0 + x1) / 2, (y0 + y1) / 2, x1 - x0, y1 - y0) end
	end
	add(vis.x0, h.y1, vis.x1, vis.y1) -- above
	add(vis.x0, vis.y0, vis.x1, h.y0) -- below
	add(vis.x0, h.y0, h.x0, h.y1)     -- left
	add(h.x1, h.y0, vis.x1, h.y1)     -- right
	return out
end

-- The union of the cell rectangles of the given cell centres (logical), grown by `pad`.
function M.hole(centres, cell, pad)
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, c in ipairs(centres) do
		x0, x1 = min(x0, c[1] - cell / 2), max(x1, c[1] + cell / 2)
		y0, y1 = min(y0, c[2] - cell / 2), max(y1, c[2] + cell / 2)
	end
	if x0 == math.huge then return nil end
	pad = pad or 0
	return { x0 = x0 - pad, y0 = y0 - pad, x1 = x1 + pad, y1 = y1 + pad }
end

local function smooth(k)
	if k <= 0 then return 0 end
	if k >= 1 then return 1 end
	return k * k * (3 - 2 * k)
end

M.HAND_SWIPE = 1.8   -- seconds of one swipe of the hand
M.HAND_TAP = 0.95    -- seconds per tap, plus a rest at the end of the round
M.HAND_REST = 0.7

-- Where the pointing hand is at time t: its fingertip, how opaque it is, how pressed (a scale), and
-- whether a finger is down. mode: "swipe" (drag from the first point to the second), "taps" (touch
-- each point in turn), "point" (hold still on the first and bob). pts = {{x, y}, ...} logical.
-- Returns {x, y, alpha, scale, down}.
function M.hand_pose(mode, pts, t)
	local a = pts[1]
	if not a then return { x = 0, y = 0, alpha = 0, scale = 1, down = false } end
	if mode == "point" then
		return { x = a[1], y = a[2] + 9 * math.sin(t * 2.8), alpha = 1, scale = 1, down = false }
	end
	if mode == "swipe" then
		local b = pts[2] or a
		local u = t % M.HAND_SWIPE
		if u < 0.25 then
			return { x = a[1], y = a[2], alpha = u / 0.25, scale = 1, down = false }
		elseif u < 0.45 then
			return { x = a[1], y = a[2], alpha = 1, scale = 1 - 0.15 * smooth((u - 0.25) / 0.2), down = true }
		elseif u < 1.2 then
			local k = smooth((u - 0.45) / 0.75)
			return { x = a[1] + (b[1] - a[1]) * k, y = a[2] + (b[2] - a[2]) * k, alpha = 1, scale = 0.85, down = true }
		elseif u < 1.4 then
			return { x = b[1], y = b[2], alpha = 1, scale = 0.85 + 0.15 * smooth((u - 1.2) / 0.2), down = false }
		end
		return { x = b[1], y = b[2], alpha = 1 - (u - 1.4) / (M.HAND_SWIPE - 1.4), scale = 1, down = false }
	end
	-- taps
	local n = #pts
	local round = n * M.HAND_TAP + M.HAND_REST
	local u = t % round
	local i = math.min(n, math.floor(u / M.HAND_TAP) + 1)
	if u >= n * M.HAND_TAP then
		local last = pts[n]
		return { x = last[1], y = last[2], alpha = 1 - (u - n * M.HAND_TAP) / M.HAND_REST, scale = 1, down = false }
	end
	local p, prev = pts[i], pts[i - 1] or pts[i]
	local v = u - (i - 1) * M.HAND_TAP
	if v < 0.4 then
		local k = (i == 1) and 1 or smooth(v / 0.4)
		return { x = prev[1] + (p[1] - prev[1]) * k, y = prev[2] + (p[2] - prev[2]) * k,
			alpha = (i == 1) and min(1, v / 0.25) or 1, scale = 1, down = false }
	elseif v < 0.68 then
		return { x = p[1], y = p[2], alpha = 1, scale = 1 - 0.15 * smooth((v - 0.4) / 0.14), down = v >= 0.5 }
	end
	return { x = p[1], y = p[2], alpha = 1, scale = 0.85 + 0.15 * smooth((v - 0.68) / 0.15), down = false }
end

-- Where the text bubble of a step goes: in the half of the board away from the spotlight (above it when
-- the lit cells are low, below it when they are high), never over the hole, inside the safe area.
-- vis = the safe rectangle, board = {x0, y0, x1, y1} or nil, hole = {x0, y0, x1, y1} or nil.
-- Returns a rect of size w x h.
function M.bubble_rect(vis, board, hole, w, h)
	w = min(w, vis.x1 - vis.x0 - 24)
	local cx = (vis.x0 + vis.x1) / 2
	local mid = board and (board.y0 + board.y1) / 2 or (vis.y0 + vis.y1) / 2
	local hy = hole and (hole.y0 + hole.y1) / 2 or mid
	local top_y = board and (board.y1 + h / 2 - 30) or (vis.y1 - 300)
	local bottom_y = board and (board.y0 - h / 2 + 30) or (vis.y0 + 300)
	local function clamp(y)
		return max(vis.y0 + h / 2 + 8, min(vis.y1 - h / 2 - 8, y))
	end
	local first, second = top_y, bottom_y
	if hy > mid then first, second = bottom_y, top_y end
	local r = rect(cx, clamp(first), w, h)
	if hole and M.overlaps(r, hole) then
		local r2 = rect(cx, clamp(second), w, h)
		if not M.overlaps(r2, hole) then r = r2 end
	end
	return r
end

-- score pops ---------------------------------------------------------------------------------------

local Feed = {}
Feed.__index = Feed

M.FEED_WINDOW = 0.14 -- seconds: the events of one burst (a match clears its pieces in one tick) merge

-- Merges the score events that arrive within FEED_WINDOW into one pop at their weighted centre.
--   local feed = level_hud.score_feed()
--   feed:add(delta, lx, ly)   -- for every level_score event
--   local pop = feed:update(dt)    -- {delta, x, y, size = 1 | 2 | 3} when a burst is complete, else nil
function M.score_feed()
	return setmetatable({ sum = 0, wx = 0, wy = 0, w = 0, t = nil }, Feed)
end

function Feed:add(delta, lx, ly)
	delta = tonumber(delta) or 0
	if delta <= 0 then return end
	self.sum = self.sum + delta
	if lx and ly then
		self.wx, self.wy, self.w = self.wx + lx * delta, self.wy + ly * delta, self.w + delta
	end
	if not self.t then self.t = 0 end
end

function Feed:update(dt)
	if not self.t then return nil end
	self.t = self.t + dt
	if self.t < M.FEED_WINDOW then return nil end
	local pop = nil
	if self.w > 0 then
		local size = self.sum >= 300 and 3 or (self.sum >= 100 and 2 or 1)
		pop = { delta = self.sum, x = self.wx / self.w, y = self.wy / self.w, size = size }
	end
	self.sum, self.wx, self.wy, self.w, self.t = 0, 0, 0, 0, nil
	return pop
end

return M
