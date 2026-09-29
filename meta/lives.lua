-- Lives: up to C.lives.max, one comes back every C.lives.regen_seconds, plus
-- "infinite lives" measured in time.
--
-- The state holds timestamps, so lives come back while the app is closed.
-- A device clock that was turned back must never help the player, and the
-- two resources need different rules for that:
--
--   * Regeneration runs on `last_seen`, the latest time ever seen. A `now`
--     before it counts as `last_seen`: the timer stands still until real
--     time catches up, so turning the clock back never brings a life sooner.
--   * Infinite lives are remaining time. They run on `clock`, the raw device
--     time of the last update. When the clock jumps back, `infinite_until`
--     moves back by the same amount: the remaining time is kept and keeps
--     running down, so a clock that was turned back neither extends nor
--     freezes it.
--
-- State (integers, seconds):
--   count           lives in stock, 0..max
--   next_at         when the next life arrives (0 while count == max)
--   last_seen       the latest time seen (regeneration clock)
--   clock           the device time of the last update, <= last_seen
--   infinite_until  infinite lives run while clock < infinite_until
--
-- update(ls, now) moves the state to `now`; every other function works at the
-- time of the last update. The facade checks `now` and calls update first.

local C = require("meta.config")
local util = require("meta.util")

local M = {}

local MAX, REGEN = C.lives.max, C.lives.regen_seconds

function M.restore(t)
	t = type(t) == "table" and t or {}
	local last_seen = util.int(t.last_seen, 0, 0)
	local ls = {
		count = util.int(t.count, MAX, 0, MAX),
		next_at = util.int(t.next_at, 0, 0),
		last_seen = last_seen,
		clock = util.int(t.clock, last_seen, 0, last_seen),
		infinite_until = util.int(t.infinite_until, 0, 0),
	}
	if ls.count == MAX then
		ls.next_at = 0
	elseif ls.next_at == 0 or ls.next_at > last_seen + REGEN then
		-- a missing or impossible timer restarts from the last seen time
		ls.next_at = last_seen + REGEN
	end
	return ls
end

-- Moves the state to `now` (whole seconds >= 0) and grants the lives that
-- came back. Returns true when the clock went back while infinite lives were
-- running, i.e. when infinite_until was moved.
function M.update(ls, now)
	local moved = false
	if now < ls.clock then
		local left = ls.infinite_until - ls.clock
		moved = left > 0
		ls.infinite_until = moved and now + left or 0
	end
	ls.clock = now
	if now > ls.last_seen then ls.last_seen = now end
	local t = ls.last_seen
	if ls.count < MAX and t >= ls.next_at then
		local gained = math.floor((t - ls.next_at) / REGEN) + 1
		ls.count = math.min(MAX, ls.count + gained)
		ls.next_at = ls.count < MAX and ls.next_at + gained * REGEN or 0
	end
	return moved
end

function M.infinite_seconds(ls)
	return math.max(0, ls.infinite_until - ls.clock)
end

function M.infinite_active(ls)
	return M.infinite_seconds(ls) > 0
end

-- Can a level that costs lives be started?
function M.can_play(ls)
	return ls.count > 0 or M.infinite_active(ls)
end

function M.status(ls)
	return {
		count = ls.count,
		max = MAX,
		next_in_seconds = ls.count < MAX and ls.next_at - ls.last_seen or 0,
		infinite_seconds = M.infinite_seconds(ls),
	}
end

-- Takes one life. Returns false if there was none to take.
function M.consume(ls)
	if ls.count == 0 then return false end
	if ls.count == MAX then ls.next_at = ls.last_seen + REGEN end
	ls.count = ls.count - 1
	return true
end

function M.refill(ls)
	ls.count, ls.next_at = MAX, 0
end

-- Infinite lives stack: new minutes are added after the ones still left.
-- Returns the seconds left after the addition.
function M.add_infinite(ls, minutes)
	if not util.is_int(minutes) or minutes < 0 then
		error("meta: infinite lives minutes must be a non-negative integer", 2)
	end
	ls.infinite_until = math.max(ls.infinite_until, ls.clock) + minutes * 60
	return ls.infinite_until - ls.clock
end

return M
