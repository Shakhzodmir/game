local app = require("client.app")
local flow = require("client.flow")
local levels = require("client.levels")
local rewards = require("client.rewards")
local meta_qa = require("client.meta_qa")
local bus = require("client.bus")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local json = require("tools.lib.json")
local H = require("tests.meta.helper")

-- msg.post stands in for Defold: the posts are recorded
local posts
local function with_msg(fn)
	local old = rawget(_G, "msg")
	posts = {}
	rawset(_G, "msg", { post = function(url, id, m) posts[#posts + 1] = { url = url, id = id, m = m } end })
	local ok, err = pcall(fn)
	rawset(_G, "msg", old)
	if not ok then error(err, 0) end
end

local function boot()
	analytics.init({ strict = true })
	rewards.clear()
	app.init({
		districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
		now = H.T0, clock = function() return H.T0 end, sys_language = "en",
	})
	levels._reset()
	levels.read = function(path)
		if string.find(path, "level_0001", 1, true) then
			return json.encode({ difficulty = "medium", moves = 20, goals = { { type = "collect", color = "red", count = 10 } } })
		end
		return nil
	end
	levels.decode = json.decode
	meta_qa.decode = json.decode
end

describe("client.flow", function()
	it("starts a level through the meta and hands the level screen its contract", function()
		boot()
		with_msg(function()
			local ok, why, params = flow.start(1, {}, "town")
			assert_true(ok, why)
			assert_eq(params.level_id, 1)
			assert_eq(params.level, 1)
			assert_eq(params.run.level_id, 1)
			assert_eq(params.run.difficulty, "medium")
			assert_eq(type(params.level_text), "string")
			assert_eq(params.from, "town")
			assert_eq(posts[1].id, "show_screen")
			assert_eq(posts[1].m.name, "level")
			assert_same(app.claim(posts[1].m.ticket), params)
		end)
		assert_true(app.meta:run() ~= nil)
	end)

	it("runs a level without a file as easy and refuses a second start", function()
		boot()
		H.win(app.meta, H.T0)
		with_msg(function()
			local ok, _, params = flow.start(2, {}, "town")
			assert_true(ok)
			assert_eq(params.run.difficulty, "easy")
			assert_eq(params.level_text, nil)
			local ok2, why = flow.start(2, {}, "town")
			assert_false(ok2)
			assert_eq(why, "run_active")
		end)
	end)

	it("settles an attempt left open: cancelled before a move, a loss after it", function()
		boot()
		with_msg(function() assert_true(flow.start(1, {}, "town")) end)
		assert_eq(flow.settle_stale_run(), nil)
		assert_eq(app.meta:run(), nil)
		assert_eq(app.meta:stats().losses, 0)
		with_msg(function() assert_true(flow.start(1, {}, "town")) end)
		app.meta:note_move()
		local res = flow.settle_stale_run()
		assert_false(res.won)
		assert_eq(res.reason, "quit")
		assert_eq(app.meta:run(), nil)
		assert_eq(flow.settle_stale_run(), nil)
	end)
end)

describe("client.meta_qa", function()
	it("queues a reward from JSON and reports bad JSON", function()
		boot()
		local h = meta_qa.handlers()
		local sub = bus.subscribe("reward_pushed")
		local r = h.reward({}, 'reward {"won": true, "stars": 2, "coins": 40}')
		assert_true(r.ok)
		assert_eq(r.queued, 1)
		assert_eq(sub:pending(), 1)
		sub:close()
		assert_same(rewards.held(), { coins = 40, stars = 2 })
		assert_false(h.reward({}, "reward {oops").ok)
	end)

	it("adds debug stars and completes a task outside the town", function()
		boot()
		local h = meta_qa.handlers()
		assert_false(h.complete_task().ok)
		assert_true(h.add_stars({ "5" }).ok)
		assert_eq(app.meta:stars(), 5)
		local r = h.complete_task()
		assert_true(r.ok)
		assert_eq(r.via, "meta")
		assert_eq(app.meta:district("cafe").done, 1)
		assert_false(h.add_stars({ "x" }).ok)
	end)

	it("sends the task to the town when it is on display", function()
		boot()
		local h = meta_qa.handlers()
		h.add_stars({ "3" })
		app.screen, app.transitioning = "town", false
		local sub = bus.subscribe("meta_qa")
		local r = h.complete_task()
		assert_eq(r.via, "town")
		local got
		sub:drain(function(_, p) got = p end)
		sub:close()
		assert_eq(got.action, "task")
		assert_eq(app.meta:district("cafe").done, 0) -- the town does it, with its animation
		app.screen = nil
	end)

	it("opens popups only on the town, with JSON params", function()
		boot()
		local h = meta_qa.handlers()
		app.screen = "level"
		assert_false(h.open({ "shop" }, "open shop").ok)
		app.screen = "town"
		local sub = bus.subscribe("popup_request")
		assert_true(h.open({ "shop", '{"tab":' }, 'open shop {"tab": "coins"}').ok)
		local got
		sub:drain(function(_, p) got = p end)
		sub:close()
		assert_eq(got.name, "shop")
		assert_eq(got.params.tab, "coins")
		app.screen = nil
	end)

	it("advances through wins and loses a level", function()
		boot()
		local h = meta_qa.handlers()
		local r = h.advance({ "22" })
		assert_true(r.ok)
		assert_eq(app.meta:level_to_play(), 22)
		local l = h.meta_lose()
		assert_true(l.ok)
	end)
end)
