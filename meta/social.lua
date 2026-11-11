-- Social rules (WP-11): the chart and the bands (groups). Pure Lua, no clock and no randomness of its own: every
-- function takes what it needs. The same rules run in the mock server (client/services/social_mock.lua) and are
-- written down for the real backend in docs/handoff/WP-11.md (the server must apply them too).
--
-- What a player shows to others (nothing else is ever sent or stored):
--   name    = {a, n, d}: an adjective and a noun of the fixed word lists (client/i18n.lua "social.adj.*" and
--             "social.noun.*", every language shows its own words) and a number 10..99. Nobody types a name,
--             so no real name, e-mail, link or rude word can get in.
--   avatar  = 1..#AVATARS (a colour and an icon the game already has)
--   district = 1..number of districts of the town (the position of the district the player works on, the "badge")
--   stars, total_stars, level, super (counters)
-- Anti-cheat (the server cannot replay a level without the core, so it limits and flags instead):
--   * total stars can never exceed 3 per level reached + the stars of concerts: MAX_PER_LEVEL * level;
--   * growth per day is capped (DAY_CAP), the weekly score counts at most WEEK_CAP stars;
--   * a report that asks for more than the caps is clamped and the player gets a mark ("flagged"); after
--     FLAG_LIMIT marks the player drops out of the public chart (stays visible to themself), see report().

local M = {}

M.AVATARS = {
	{ color = "purple", icon = "ui/icons/star" }, { color = "pink", icon = "ui/icons/heart" },
	{ color = "blue", icon = "ui/icons/jukebox" }, { color = "green", icon = "ui/icons/note_on" },
	{ color = "coin", icon = "ui/icons/coin" }, { color = "yellow", icon = "ui/icons/gift" },
	{ color = "pink", icon = "ui/icons/star" }, { color = "blue", icon = "ui/icons/heart" },
	{ color = "green", icon = "ui/icons/jukebox" }, { color = "coin", icon = "ui/icons/note_on" },
	{ color = "purple", icon = "ui/icons/coin" }, { color = "blue", icon = "ui/icons/gift" },
}
M.WORDS = 16              -- adjectives and nouns in the lists
M.CHART_LIMIT = 100       -- rows of the public chart
M.BAND_MAX = 20           -- members of a band
M.BAND_CODE_LEN = 6
M.CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789" -- no 0/O, 1/I/L
M.MAX_PER_LEVEL = 3       -- stars a level can give (the stars by score, WP-4)
M.DAY_CAP = 30            -- stars a player may gain per day (10 levels at 3 stars)
M.WEEK_CAP = 120          -- stars that count in the weekly score
M.FLAG_LIMIT = 3          -- marks before a player leaves the public chart
M.BAND_GOAL_PER_MEMBER = 30
M.BAND_GOAL_MIN = 60
M.HELP_SEND_DAY = 5       -- lives a player may send per day
M.HELP_GET_DAY = 3        -- lives a player may receive per day
M.PERIODS = { "week", "all", "band" }
M.DAY = 86400
M.WEEK = 7 * 86400

-- time --------------------------------------------------------------------------------------------------

function M.day_id(t) return math.floor(t / M.DAY) end

-- The week starts on Monday 00:00 UTC (1970-01-05 was a Monday).
function M.week_id(t) return math.floor((t - 4 * M.DAY) / M.WEEK) end

function M.week_end(week) return (week + 1) * M.WEEK + 4 * M.DAY end

-- profile -----------------------------------------------------------------------------------------------

local function int_in(v, lo, hi)
	return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

function M.valid_name(n)
	return type(n) == "table" and int_in(n.a, 1, M.WORDS) and int_in(n.n, 1, M.WORDS) and int_in(n.d, 10, 99)
end

function M.valid_band_name(n)
	return type(n) == "table" and int_in(n.a, 1, M.WORDS) and int_in(n.n, 1, M.WORDS)
end

function M.valid_avatar(a) return int_in(a, 1, #M.AVATARS) end

-- The k-th suggested name (k = 0, 1, 2, ...): spreads over the lists without a random generator.
function M.suggest_name(k)
	k = k or 0
	return { a = (k * 7) % M.WORDS + 1, n = (k * 5 + math.floor(k / M.WORDS)) % M.WORDS + 1, d = 10 + (k * 37) % 90 }
end

function M.suggest_band_name(k)
	k = k or 0
	return { a = (k * 5 + 3) % M.WORDS + 1, n = (k * 3 + 1 + math.floor(k / M.WORDS)) % M.WORDS + 1 }
end

function M.name_key(n) return string.format("%d.%d.%d", n.a, n.n, n.d or 0) end

-- codes ---------------------------------------------------------------------------------------------------

function M.normalize_code(s)
	if type(s) ~= "string" then return "" end
	return (s:gsub("[%s%-]", ""):upper())
end

function M.valid_code(s)
	if #s ~= M.BAND_CODE_LEN then return false end
	for i = 1, #s do
		if not M.CODE_ALPHABET:find(s:sub(i, i), 1, true) then return false end
	end
	return true
end

-- A band code from a number (the server counter): six letters of the alphabet, the same number always gives the
-- same code, and neighbouring numbers give unrelated codes. Two counters may rarely give one code: the server
-- checks that the code is free and takes the next counter when it is not.
function M.code_from(counter)
	local base = #M.CODE_ALPHABET
	local space = base ^ M.BAND_CODE_LEN
	local x = (counter * 2654435761 + 40503) % 2147483647 % space
	local out = {}
	for i = M.BAND_CODE_LEN, 1, -1 do
		local d = x % base
		x = math.floor(x / base)
		out[i] = M.CODE_ALPHABET:sub(d + 1, d + 1)
	end
	return table.concat(out)
end

function M.band_goal(members)
	return math.max(M.BAND_GOAL_MIN, M.BAND_GOAL_PER_MEMBER * members)
end

-- reports -------------------------------------------------------------------------------------------------

-- rec: the server record of a player {total, level, day, day_gain, week, week_base, flags}; claim: {total, level}
-- from the player; now: seconds. Returns the new record, the weekly score and what was refused:
--   refused = nil | "level" (more stars than the level allows: clamped to it and marked) |
--             "day" (more than DAY_CAP in a day: clamped and marked) | "down" (a smaller number: ignored)
function M.report(rec, claim, now)
	rec = rec or { total = 0, level = 0, day = M.day_id(now), day_gain = 0, week = M.week_id(now), week_base = 0, flags = 0 }
	local out = {}
	for k, v in pairs(rec) do out[k] = v end -- order-free copy
	local day, week = M.day_id(now), M.week_id(now)
	local refused
	if out.week ~= week then
		out.week, out.week_base = week, out.total
	end
	if out.day ~= day then out.day, out.day_gain = day, 0 end
	local level = math.max(out.level, math.floor(tonumber(claim.level) or 0))
	local total = math.floor(tonumber(claim.total) or 0)
	if total < out.total then
		refused = "down"
		total = out.total
	end
	local top = M.MAX_PER_LEVEL * level + (tonumber(claim.super) or 0)
	if total > top then
		total, refused = math.max(out.total, top), "level"
	end
	local gain = total - out.total
	local room = math.max(0, M.DAY_CAP - out.day_gain)
	if gain > room then
		total, refused = out.total + room, refused or "day"
		gain = room
	end
	out.total, out.level = total, level
	out.day_gain = out.day_gain + gain
	if refused == "level" or refused == "day" then out.flags = out.flags + 1 end
	return out, M.week_score(out), refused
end

function M.week_score(rec)
	return math.min(M.WEEK_CAP, math.max(0, rec.total - rec.week_base))
end

function M.visible(rec) return rec.flags < M.FLAG_LIMIT end

-- ranking -------------------------------------------------------------------------------------------------

-- rows = {{uid, stars, total, ...}}; sorts by `stars`, then total stars, then uid (a stable, total order) and
-- sets rank 1..n (ties keep distinct ranks: the same order for everyone).
function M.rank(rows)
	table.sort(rows, function(x, y)
		if x.stars ~= y.stars then return x.stars > y.stars end
		if (x.total or 0) ~= (y.total or 0) then return (x.total or 0) > (y.total or 0) end
		return x.uid < y.uid
	end)
	for i, r in ipairs(rows) do r.rank = i end
	return rows
end

-- The first `limit` rows of a ranked list and the player's own row, which is added (pinned) when it is below
-- the limit. Returns {rows, me, count}; me.pinned = true when it is outside the rows.
function M.top_with_me(ranked, me_uid, limit)
	limit = limit or M.CHART_LIMIT
	local rows, me = {}, nil
	for i, r in ipairs(ranked) do
		if r.uid == me_uid then me = r end
		if i <= limit then rows[#rows + 1] = r end
	end
	return { rows = rows, me = me, count = #ranked, pinned = me ~= nil and me.rank > limit }
end

-- How far the rank rose between two snapshots (positive: up).
function M.rank_change(old, new)
	if not old or not new then return 0 end
	return old - new
end

return M
