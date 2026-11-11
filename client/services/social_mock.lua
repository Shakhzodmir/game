-- An in-memory social server for tests and QA (WP-11): the rules of meta/social.lua applied the way the real
-- backend must apply them. Deterministic: no clock of its own (m.now() is injected), no random numbers.
--
--   local m = require("client.services.social_mock").new({now = function() return 1730000000 end})
--   m:seed(30)                       -- 30 other players with names and stars
--   m.offline = true                 -- every call answers "offline"
--   m.delay = 1                      -- replies come on m:tick() calls instead of at once (tests of "busy" states)
-- Fields for asserts: m.players[uid], m.bands[code], m.calls (count by op).

local rules = require("meta.social")

local M = {}
M.__index = M

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		now = opts.now or function() return 1730000000 end,
		configured = opts.configured ~= false,
		players = {}, bands = {}, counter = 0, joined_seq = 0, calls = {}, offline = false, queue = {}, delay = 0,
	}, M)
end

function M:available() return self.configured end

function M:tick()
	local q = self.queue
	self.queue = {}
	for _, fn in ipairs(q) do fn() end
end

local function reply(self, op, cb, ok, reason, data)
	self.calls[op] = (self.calls[op] or 0) + 1
	if self.offline then ok, reason, data = false, "offline", nil end
	if self.delay > 0 then
		self.queue[#self.queue + 1] = function() cb(ok, reason, data) end
	else
		cb(ok, reason, data)
	end
end

local function player(self, uid)
	local p = self.players[uid]
	if not p then
		p = { uid = uid, rec = nil, seen = {}, day_sent = 0, day_got = 0, day = -1, inbox = 0, helped_by = {} }
		self.players[uid] = p
	end
	return p
end

local function roll_day(self, p)
	local d = rules.day_id(self.now())
	if p.day ~= d then p.day, p.day_sent, p.day_got = d, 0, 0 end
end

-- n other players: names, avatars and star totals that spread over the whole range, some in the same week.
function M:seed(n)
	local now = self:now()
	for i = 1, n do
		local uid = string.format("bot%03d", i)
		local p = player(self, uid)
		p.profile = { name = rules.suggest_name(i * 3), avatar = (i % #rules.AVATARS) + 1 }
		local level = 4 + (i * 7) % 96
		local total = math.min(rules.MAX_PER_LEVEL * level, (i * 13) % (rules.MAX_PER_LEVEL * level + 1))
		p.rec = { total = total, level = level, day = rules.day_id(now), day_gain = 0, week = rules.week_id(now),
			week_base = math.max(0, total - (i * 5) % 70), flags = 0 }
		p.district = math.min(#require("meta.config").songbook.districts, 1 + math.floor(level / 21))
	end
end

function M:profile_get(uid, cb)
	local p = player(self, uid)
	reply(self, "profile_get", cb, true, nil, p.profile and { name = p.profile.name, avatar = p.profile.avatar } or nil)
end

function M:profile_set(uid, name, avatar, cb)
	local p = player(self, uid)
	if not rules.valid_name(name) then return reply(self, "profile_set", cb, false, "bad_name") end
	if not rules.valid_avatar(avatar) then return reply(self, "profile_set", cb, false, "bad_avatar") end
	p.profile = { name = { a = name.a, n = name.n, d = name.d }, avatar = avatar }
	p.rec = p.rec or rules.report(nil, { total = 0, level = 0 }, self:now())
	reply(self, "profile_set", cb, true, nil, { name = p.profile.name, avatar = avatar })
end

function M:report(uid, claim, cb)
	local p = player(self, uid)
	if not p.profile then return reply(self, "report", cb, false, "no_profile") end
	local rec, score, refused = rules.report(p.rec, claim or {}, self:now())
	p.rec = rec
	local d = math.floor(tonumber(claim and claim.district) or 1)
	p.district = math.max(1, math.min(#require("meta.config").songbook.districts, d))
	reply(self, "report", cb, true, nil, { stars = score, total = rec.total, refused = refused, flagged = not rules.visible(rec) })
end

local function row_of(p, stars, me_uid)
	return {
		uid = p.uid, name = p.profile.name, avatar = p.profile.avatar, district = p.district or 1, stars = stars,
		total = p.rec.total, me = p.uid == me_uid,
	}
end

local function sorted_uids(t)
	local list = {}
	for uid in pairs(t) do list[#list + 1] = uid end
	table.sort(list)
	return list
end

function M:chart(uid, period, cb)
	local me = player(self, uid)
	if not me.profile or not me.rec then return reply(self, "chart", cb, false, "no_profile") end
	local rows = {}
	local function add(p)
		if p.profile and p.rec then
			local visible = rules.visible(p.rec) or p.uid == uid
			if visible then
				rows[#rows + 1] = row_of(p, period == "all" and p.rec.total or rules.week_score(p.rec), uid)
			end
		end
	end
	if period == "band" then
		local b = me.band and self.bands[me.band]
		if not b then return reply(self, "chart", cb, true, nil, { rows = {}, count = 0, no_band = true }) end
		for _, id in ipairs(sorted_uids(b.members)) do add(self.players[id]) end
	else
		for _, id in ipairs(sorted_uids(self.players)) do
			local p = self.players[id]
			if p.profile and p.rec and (rules.visible(p.rec) or id == uid) then add(p) end
		end
	end
	-- a week that rolled over since the last report counts from zero
	for _, r in ipairs(rows) do
		local p = self.players[r.uid]
		if period ~= "all" and p.rec.week ~= rules.week_id(self:now()) then r.stars = 0 end
	end
	rules.rank(rows)
	local out = rules.top_with_me(rows, uid, rules.CHART_LIMIT)
	if out.me then
		local flagged = not rules.visible(me.rec)
		local key = period
		out.me = { uid = out.me.uid, name = out.me.name, avatar = out.me.avatar, district = out.me.district,
			stars = out.me.stars, total = out.me.total, rank = out.me.rank, me = true, hidden = flagged or nil,
			prev_rank = me.seen[key] }
		for i, r in ipairs(out.rows) do
			if r.me then out.rows[i] = out.me end
		end
		me.seen[key] = out.me.rank
	end
	out.week = rules.week_id(self:now())
	out.week_end = rules.week_end(out.week)
	reply(self, "chart", cb, true, nil, out)
end

-- bands -------------------------------------------------------------------------------------------------

local function band_view(self, b, uid)
	local members = {}
	local total = 0
	for id, info in pairs(b.members) do -- order-free: sorted below
		local p = self.players[id]
		local stars = p.rec and rules.week_score(p.rec) or 0
		if p.rec and p.rec.week ~= rules.week_id(self:now()) then stars = 0 end
		total = total + stars
		members[#members + 1] = {
			uid = id, name = p.profile.name, avatar = p.profile.avatar, district = p.district or 1, stars = stars,
			role = id == b.leader and "leader" or "member", help = p.help_req == true, joined = info.seq, me = id == uid,
		}
	end
	table.sort(members, function(x, y)
		if x.stars ~= y.stars then return x.stars > y.stars end
		return x.joined < y.joined
	end)
	local n = #members
	local week = rules.week_id(self:now())
	return {
		code = b.code, name = b.name, leader = b.leader, members = members, count = n, goal = rules.band_goal(n),
		stars = total, week = week, week_end = rules.week_end(week), max = rules.BAND_MAX,
		you = uid == b.leader and "leader" or "member",
	}
end

function M:band_get(uid, cb)
	local p = player(self, uid)
	local b = p.band and self.bands[p.band]
	reply(self, "band_get", cb, true, nil, b and band_view(self, b, uid) or nil)
end

function M:band_create(uid, name, cb)
	local p = player(self, uid)
	if not p.profile then return reply(self, "band_create", cb, false, "no_profile") end
	if not rules.valid_band_name(name) then return reply(self, "band_create", cb, false, "bad_name") end
	if p.band then return reply(self, "band_create", cb, false, "already_in_band") end
	local code
	repeat
		self.counter = self.counter + 1
		code = rules.code_from(self.counter)
	until not self.bands[code]
	self.joined_seq = self.joined_seq + 1
	self.bands[code] = { code = code, name = { a = name.a, n = name.n }, leader = uid, members = { [uid] = { seq = self.joined_seq } } }
	p.band = code
	reply(self, "band_create", cb, true, nil, band_view(self, self.bands[code], uid))
end

function M:band_join(uid, code, cb)
	local p = player(self, uid)
	if not p.profile then return reply(self, "band_join", cb, false, "no_profile") end
	if p.band then return reply(self, "band_join", cb, false, "already_in_band") end
	local b = self.bands[code]
	if not b then return reply(self, "band_join", cb, false, "no_such_band") end
	local n = 0
	for _ in pairs(b.members) do n = n + 1 end -- count only
	if n >= rules.BAND_MAX then return reply(self, "band_join", cb, false, "full") end
	self.joined_seq = self.joined_seq + 1
	b.members[uid] = { seq = self.joined_seq }
	p.band = code
	reply(self, "band_join", cb, true, nil, band_view(self, b, uid))
end

local function remove_member(self, b, uid)
	b.members[uid] = nil
	local p = self.players[uid]
	p.band, p.help_req, p.inbox = nil, nil, 0
	if b.leader == uid then
		local best, best_seq
		for id, info in pairs(b.members) do -- the earliest joined member leads: a total order, no matter the walk
			if not best_seq or info.seq < best_seq then best, best_seq = id, info.seq end
		end
		if best then b.leader = best else self.bands[b.code] = nil end
	end
end

function M:band_leave(uid, cb)
	local p = player(self, uid)
	local b = p.band and self.bands[p.band]
	if not b then return reply(self, "band_leave", cb, false, "no_band") end
	remove_member(self, b, uid)
	reply(self, "band_leave", cb, true)
end

function M:band_kick(uid, target, cb)
	local p = player(self, uid)
	local b = p.band and self.bands[p.band]
	if not b then return reply(self, "band_kick", cb, false, "no_band") end
	if b.leader ~= uid then return reply(self, "band_kick", cb, false, "not_leader") end
	if target == uid then return reply(self, "band_kick", cb, false, "bad_target") end
	if not b.members[target] then return reply(self, "band_kick", cb, false, "not_member") end
	remove_member(self, b, target)
	reply(self, "band_kick", cb, true, nil, band_view(self, b, uid))
end

-- help with lives ----------------------------------------------------------------------------------------

function M:help_request(uid, cb)
	local p = player(self, uid)
	if not (p.band and self.bands[p.band]) then return reply(self, "help_request", cb, false, "no_band") end
	p.help_req, p.helped_by = true, {}
	reply(self, "help_request", cb, true)
end

function M:help_send(uid, target, cb)
	local p = player(self, uid)
	local b = p.band and self.bands[p.band]
	if not b then return reply(self, "help_send", cb, false, "no_band") end
	if target == uid then return reply(self, "help_send", cb, false, "bad_target") end
	if not b.members[target] then return reply(self, "help_send", cb, false, "not_member") end
	local t = self.players[target]
	if not t.help_req then return reply(self, "help_send", cb, false, "not_requested") end
	if t.helped_by[uid] then return reply(self, "help_send", cb, false, "already_sent") end
	roll_day(self, p)
	if p.day_sent >= rules.HELP_SEND_DAY then return reply(self, "help_send", cb, false, "limit") end
	p.day_sent = p.day_sent + 1
	t.helped_by[uid] = true
	t.inbox = t.inbox + 1
	reply(self, "help_send", cb, true, nil, { sent = p.day_sent })
end

function M:help_claim(uid, cb)
	local p = player(self, uid)
	roll_day(self, p)
	local n = math.min(p.inbox, rules.HELP_GET_DAY - p.day_got)
	if n <= 0 then return reply(self, "help_claim", cb, true, nil, { lives = 0, waiting = p.inbox }) end
	p.day_got = p.day_got + n
	p.inbox = p.inbox - n
	if p.inbox == 0 then p.help_req = nil end
	reply(self, "help_claim", cb, true, nil, { lives = n, waiting = p.inbox })
end

return M
