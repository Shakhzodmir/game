-- Lives: up to C.lives.max, one comes back every C.lives.regen_seconds, plus
-- "infinite lives" measured in time.
--
-- Everything is computed from stored timestamps, so regeneration continues
-- while the app is closed. The clock never runs backwards for the meta: a
-- `now` earlier than the latest time seen is treated as that time, so turning
-- the device clock back neither grants lives nor extends infinite lives.
--
-- State (all integers, seconds):
--   count           lives in stock, 0..max
--   next_at         when the next life arrives (0 while count == max)
--   last_seen       the latest `now` seen
--   infinite_until  infinite lives are active while now < infinite_until

local C = require("meta.config")
local util = require("meta.util")

local M = {}

local MAX, REGEN = C.lives.max, C.lives.regen_seconds

function M.restore(t)
	t = type(t) == "table" and t or {}
	local ls = {
		count = util.int(t.count, MAX, 0, MAX),
		next_at = util.int(t.next_at, 0, 0),
		last_seen = util.int(t.last_seen, 0, 0),
		infinite_until = util.int(t.infinite_until, 0, 0),
	}
	if ls.count == MAX then
		ls.next_at = 0
	elseif ls.next_at == 0 then
		ls.next_at = ls.last_seen + REGEN
	end
	return ls
end

-- Moves the meta clock to `now` and grants the lives that came back since.
-- Returns the effective now.
function M.update(ls, now)
	now = util.check_now(now)
	if now < ls.last_seen then now = ls.last_seen end
	ls.last_seen = now
	if ls.count < MAX and now >= ls.next_at then
		local gained = math.floor((now - ls.next_at) / REGEN) + 1
		ls.count = math.min(MAX, ls.count + gained)
		ls.next_at = ls.count < MAX and ls.next_at + gained * REGEN or 0
	end
	return now
end

function M.infinite_seconds(ls, now)
	now = M.update(ls, now)
	return math.max(0, ls.infinite_until - now)
end

function M.infinite_active(ls, now)
	return M.infinite_seconds(ls, now) > 0
end

-- Can a level that costs lives be started?
function M.can_play(ls, now)
	return M.infinite_active(ls, now) or ls.count > 0
end

function M.status(ls, now)
	now = M.update(ls, now)
	return {
		count = ls.count,
		max = MAX,
		next_in_seconds = ls.count < MAX and ls.next_at - now or 0,
		infinite_seconds = math.max(0, ls.infinite_until - now),
	}
end

-- Takes one life. Returns false if there was none to take.
function M.consume(ls, now)
	now = M.update(ls, now)
	if ls.count == 0 then return false end
	if ls.count == MAX then ls.next_at = now + REGEN end
	ls.count = ls.count - 1
	return true
end

function M.refill(ls, now)
	M.update(ls, now)
	ls.count, ls.next_at = MAX, 0
end

-- Infinite lives stack: new minutes are added after the ones still left.
function M.add_infinite(ls, minutes, now)
	if not util.is_int(minutes) or minutes < 0 then
		error("meta: infinite lives minutes must be a non-negative integer", 2)
	end
	now = M.update(ls, now)
	ls.infinite_until = math.max(ls.infinite_until, now) + minutes * 60
	return ls.infinite_until - now
end

return M
