-- client/services/social.lua against the mock server (client/services/social_mock.lua): states, the chart,
-- the pinned row, limits and flags, bands (create, join, leave, kick, conflicts), help with lives.
local auth = require("client.services.auth")
local social = require("client.services.social")
local mock_mod = require("client.services.social_mock")
local auth_mock = require("client.services.auth_mock")
local rules = require("meta.social")

local NOW = 4 * 86400 + 3 * 604800 + 3600

local A -- the auth mock of the running test: one provider, several accounts (switch)

local function sign_in(a, id)
	if auth.user() then auth.sign_out(function() end) end
	a.google_next = { sub = id, email = id .. "@gmail.com" }
	local ok
	auth.sign_in_google(function(good) ok = good end)
	assert_true(ok)
	return auth.user().uid
end
local function switch(id) return sign_in(A, id) end

-- A server with `bots` other players and one signed-in test player; fn(m, uid, clock).
local function with_server(bots, fn)
	local clock = { t = NOW }
	local m = mock_mod.new({ now = function() return clock.t end })
	m:seed(bots or 0)
	local a = auth_mock.new()
	A = a
	auth.set_provider(a)
	social.set_provider(m)
	local ok, err = pcall(function()
		local uid = sign_in(a, "me")
		fn(m, uid, clock, a)
	end)
	social.set_provider(nil)
	auth.set_provider(nil)
	if not ok then error(err, 0) end
end

local function call(f, ...)
	local r
	local args, n = { ... }, select("#", ...)
	args[n + 1] = function(ok, reason, data) r = { ok = ok, reason = reason, data = data } end
	f(unpack(args, 1, n + 1))
	return r
end

local function profile(uid_n, name_k)
	assert_true(call(social.profile_set, rules.suggest_name(name_k or 1), 2).ok)
end

describe("social service: states", function()
	it("is unavailable without a server and asks to sign in without an account", function()
		assert_eq(social.state(), "unavailable")
		assert_eq(call(social.chart, "week").reason, "unavailable")
		local a = auth_mock.new()
		auth.set_provider(a)
		social.set_provider(mock_mod.new())
		assert_eq(social.state(), "signin")
		assert_eq(call(social.chart, "week").reason, "signin")
		assert_eq(call(social.band_get).reason, "signin")
		sign_in(a, "x")
		assert_eq(social.state(), "ready")
		social.set_provider(nil)
		auth.set_provider(nil)
	end)

	it("answers offline from the server without raising", function()
		with_server(5, function(m)
			profile()
			m.offline = true
			assert_eq(call(social.chart, "week").reason, "offline")
			assert_eq(call(social.band_get).reason, "offline")
			m.offline = false
			assert_true(call(social.chart, "week").ok)
		end)
	end)

	it("refuses names outside the word lists before they reach the server", function()
		with_server(0, function(m)
			assert_eq(call(social.profile_set, "Anna anna@mail.com", 1).reason, "bad_name")
			assert_eq(call(social.profile_set, rules.suggest_name(1), 99).reason, "bad_avatar")
			assert_eq(m.calls.profile_set, nil)
			assert_eq(call(social.chart, "year").reason, "error")
		end)
	end)
end)

describe("social service: the chart", function()
	it("ranks the week and all time, with a stable order, and pins my row below the top", function()
		with_server(150, function(m, uid)
			profile()
			assert_true(call(social.report, { total = 12, level = 6, district = 1 }).ok)
			local week = call(social.chart, "week")
			assert_true(week.ok)
			assert_eq(#week.data.rows, 100)
			assert_eq(week.data.count, 151)
			for i = 2, #week.data.rows do
				local a, b = week.data.rows[i - 1], week.data.rows[i]
				assert_true(a.stars > b.stars or (a.stars == b.stars and (a.total > b.total or (a.total == b.total and a.uid < b.uid))))
				assert_eq(b.rank, i)
			end
			local me = week.data.me
			assert_eq(me.uid, uid)
			assert_true(me.me)
			assert_true(me.rank > 100 == week.data.pinned)
			local all = call(social.chart, "all")
			assert_true(all.data.me.stars == 12)
			assert_eq(week.data.week_end - NOW > 0, true)
		end)
	end)

	it("never shows a uid-less or personal row: only name numbers, avatar, district, stars", function()
		with_server(5, function()
			profile()
			call(social.report, { total = 3, level = 2, district = 2 })
			for _, r in ipairs(call(social.chart, "all").data.rows) do
				assert_true(rules.valid_name(r.name))
				assert_true(rules.valid_avatar(r.avatar))
				for k in pairs(r) do
					assert_true(({ uid = 1, name = 1, avatar = 1, district = 1, stars = 1, total = 1, me = 1, rank = 1, prev_rank = 1, hidden = 1 })[k], "field " .. k)
				end
			end
		end)
	end)

	it("reports the rank change once the player climbed", function()
		with_server(40, function(m, uid, clock)
			profile()
			call(social.report, { total = 3, level = 2, district = 1 })
			local first = call(social.chart, "week").data.me
			assert_eq(first.prev_rank, nil)
			clock.t = clock.t + 3600
			call(social.report, { total = 30, level = 12, district = 1 })
			local second = call(social.chart, "week").data.me
			assert_eq(second.prev_rank, first.rank)
			assert_true(second.rank < first.rank)
		end)
	end)

	it("clamps cheating: more stars than the level allows, or than a day allows, and hides repeat offenders", function()
		with_server(10, function(m, uid, clock)
			profile()
			local r = call(social.report, { total = 300, level = 4, district = 1 })
			assert_true(r.ok)
			assert_eq(r.data.total, 12)
			assert_eq(r.data.refused, "level")
			local seen = call(social.chart, "all").data.me
			assert_eq(seen.stars, 12)
			for _ = 1, 3 do
				clock.t = clock.t + 86400
				call(social.report, { total = 999, level = 100, district = 1 })
			end
			assert_true(call(social.report, { total = 999, level = 100, district = 1 }).data.flagged)
			local mine = call(social.chart, "all").data
			assert_true(mine.me.hidden, "the player sees the mark")
			-- another player's view: the flagged one is not in it
			switch("other")
			call(social.profile_set, rules.suggest_name(9), 3)
			call(social.report, { total = 3, level = 3, district = 1 })
			for _, row in ipairs(call(social.chart, "all").data.rows) do assert_false(row.uid == uid) end
		end)
	end)

	it("starts the week over for everybody on Monday", function()
		with_server(5, function(m, uid, clock)
			profile()
			call(social.report, { total = 6, level = 3, district = 1 })
			assert_eq(call(social.chart, "week").data.me.stars, 6)
			clock.t = clock.t + 604800
			assert_eq(call(social.chart, "week").data.me.stars, 0)
			assert_eq(call(social.chart, "all").data.me.stars, 6)
		end)
	end)

	it("needs a profile first", function()
		with_server(3, function()
			assert_eq(call(social.chart, "week").reason, "no_profile")
			assert_eq(call(social.report, { total = 1, level = 1 }).reason, "no_profile")
		end)
	end)
end)

local function second_player(id, k)
	local uid = switch(id)
	assert_true(call(social.profile_set, rules.suggest_name(k), 4).ok)
	return uid
end

describe("social service: bands", function()
	it("creates a band, shows it with the leader, and joins by code", function()
		with_server(0, function(m, uid, clock, a)
			profile()
			assert_eq(call(social.band_get).data, nil)
			local made = call(social.band_create, rules.suggest_band_name(2))
			assert_true(made.ok)
			local b = made.data
			assert_true(rules.valid_code(b.code))
			assert_eq(b.you, "leader")
			assert_eq(b.count, 1)
			assert_eq(b.goal, rules.BAND_GOAL_MIN)
			assert_eq(switch("me"), uid)
			-- a second player joins with the code typed in lower case with spaces
			local u2 = second_player("two", 5)
			local j = call(social.band_join, " " .. b.code:lower():sub(1, 3) .. "-" .. b.code:lower():sub(4) .. " ")
			assert_true(j.ok, tostring(j.reason))
			assert_eq(j.data.count, 2)
			assert_eq(j.data.you, "member")
			assert_eq(j.data.leader, uid)
			assert_eq(call(social.band_join, b.code).reason, "already_in_band")
			assert_eq(call(social.band_create, rules.suggest_band_name(3)).reason, "already_in_band")
		end)
	end)

	it("refuses a wrong code, a malformed code and a full band", function()
		with_server(0, function(m)
			profile()
			assert_eq(call(social.band_join, "ZZZZZZ").reason, "no_such_band")
			assert_eq(call(social.band_join, "12").reason, "bad_code")
			local b = call(social.band_create, rules.suggest_band_name(1)).data
			for i = 1, rules.BAND_MAX - 1 do
				local uid = "fill" .. i
				m.players[uid] = { uid = uid, seen = {}, day_sent = 0, day_got = 0, day = -1, inbox = 0, helped_by = {},
					profile = { name = rules.suggest_name(i), avatar = 1 }, band = b.code }
				m.bands[b.code].members[uid] = { seq = 100 + i }
			end
			second_player("late", 77)
			local r = call(social.band_join, b.code)
			assert_eq(r.reason, "full")
			assert_eq(m.bands[b.code].members.late, nil)
		end)
	end)

	it("sums the week's stars of the members and sorts the list", function()
		with_server(0, function(m, uid, clock, a)
			profile()
			call(social.report, { total = 9, level = 5, district = 1 })
			local b = call(social.band_create, rules.suggest_band_name(1)).data
			second_player("two", 5)
			call(social.band_join, b.code)
			call(social.report, { total = 12, level = 6, district = 2 })
			local view = call(social.band_get).data
			assert_eq(view.stars, 21)
			assert_eq(view.members[1].stars, 12)
			assert_eq(view.members[2].stars, 9)
			assert_eq(view.goal, 60)
			local chart = call(social.chart, "band").data
			assert_eq(#chart.rows, 2)
			assert_eq(chart.rows[1].rank, 1)
		end)
	end)

	it("hands the lead to the member who joined first, and removes an empty band", function()
		with_server(0, function(m, uid, clock, a)
			profile()
			local b = call(social.band_create, rules.suggest_band_name(1)).data
			local u2 = second_player("two", 5)
			call(social.band_join, b.code)
			local u3 = second_player("three", 6)
			call(social.band_join, b.code)
			-- the creator leaves
			switch("me")
			assert_true(call(social.band_leave).ok)
			assert_eq(m.bands[b.code].leader, u2)
			assert_eq(call(social.band_leave).reason, "no_band")
			assert_eq(call(social.band_get).data, nil)
			-- everybody leaves: the band is gone and the code is free
			m.bands[b.code].members[u3] = nil
			m.players[u3].band = nil
			switch("two")
			assert_true(call(social.band_leave).ok)
			assert_eq(m.bands[b.code], nil)
			assert_eq(call(social.band_join, b.code).reason, "no_such_band")
		end)
	end)

	it("lets only the leader remove a member", function()
		with_server(0, function(m, uid, clock, a)
			profile()
			local b = call(social.band_create, rules.suggest_band_name(1)).data
			local u2 = second_player("two", 5)
			call(social.band_join, b.code)
			assert_eq(call(social.band_kick, uid).reason, "not_leader")
			switch("me")
			assert_eq(call(social.band_kick, uid).reason, "bad_target")
			assert_eq(call(social.band_kick, "ghost").reason, "not_member")
			local r = call(social.band_kick, u2)
			assert_true(r.ok)
			assert_eq(r.data.count, 1)
			assert_eq(m.players[u2].band, nil)
		end)
	end)
end)

describe("social service: help with lives", function()
	local function band_of_two(m, a)
		profile()
		local b = call(social.band_create, rules.suggest_band_name(1)).data
		local u2 = second_player("two", 5)
		call(social.band_join, b.code)
		return b, u2
	end

	it("sends a life only to a mate who asked, once per mate, and delivers it to the asker", function()
		with_server(0, function(m, uid, clock, a)
			local b, u2 = band_of_two(m, a)
			assert_eq(call(social.help_send, uid).reason, "not_requested")
			assert_eq(call(social.help_send, u2).reason, "bad_target")
			assert_true(call(social.help_request).ok)
			switch("me")
			assert_eq(call(social.help_claim).data.lives, 0)
			local view = call(social.band_get).data
			local asker
			for _, mem in ipairs(view.members) do if mem.uid == u2 then asker = mem end end
			assert_true(asker.help)
			assert_true(call(social.help_send, u2).ok)
			assert_eq(call(social.help_send, u2).reason, "already_sent")
			switch("two")
			local got = call(social.help_claim)
			assert_eq(got.data.lives, 1)
			assert_eq(call(social.help_claim).data.lives, 0)
		end)
	end)

	it("limits what a player may send and receive per day", function()
		with_server(0, function(m, uid, clock, a)
			profile()
			local b = call(social.band_create, rules.suggest_band_name(1)).data
			local askers = {}
			for i = 1, rules.HELP_SEND_DAY + 1 do
				local id = "ask" .. i
				m.players[id] = { uid = id, seen = {}, day_sent = 0, day_got = 0, day = -1, inbox = 0, helped_by = {}, help_req = true,
					profile = { name = rules.suggest_name(i), avatar = 1 }, band = b.code }
				m.bands[b.code].members[id] = { seq = 10 + i }
				askers[i] = id
			end
			for i = 1, rules.HELP_SEND_DAY do assert_true(call(social.help_send, askers[i]).ok) end
			assert_eq(call(social.help_send, askers[#askers]).reason, "limit")
			clock.t = clock.t + 86400
			assert_true(call(social.help_send, askers[#askers]).ok, "a new day")
			-- receiving: five mates sent, three arrive today
			m.players[uid].help_req, m.players[uid].inbox = true, 5
			assert_eq(call(social.help_claim).data.lives, rules.HELP_GET_DAY)
			assert_eq(call(social.help_claim).data.lives, 0)
			clock.t = clock.t + 86400
			assert_eq(call(social.help_claim).data.lives, 2)
		end)
	end)
end)
