-- client/packs.lua: the downloader of the pictures the web archive does not carry (HTTP and clock injected).
local packs = require("client.packs")

-- a fake web: requests wait in a list until the test answers them
local function web()
	local w = { calls = {}, t = 0 }
	w.request = function(url, done, seconds) w.calls[#w.calls + 1] = { url = url, done = done, seconds = seconds } end
	w.clock = function() return w.t end
	w.answer = function(i, status, body) w.calls[i].done(status, body) end
	return w
end

local function images()
	return {
		["districts/cafe/bg"] = { file = "/assets/images/districts/cafe/bg.jpg", w = 720, h = 1280 },
		["districts/jazz/bg"] = { file = "/x/jazz/bg.jpg", w = 720, h = 1280, remote = "packs/districts/jazz/bg.jpg?v=aa", bytes = 4, district = "jazz" },
		["districts/jazz/sax"] = { file = "/x/jazz/sax.png", w = 9, h = 9, remote = "packs/districts/jazz/sax.png?v=bb", bytes = 3, district = "jazz" },
		["mapbg/bg_jazz"] = { file = "/x/mapbg/bg_jazz.png", w = 9, h = 9, remote = "packs/mapbg/bg_jazz.png?v=cc", bytes = 2, district = "jazz" },
		["districts/square/bg"] = { file = "/x/square/bg.jpg", w = 9, h = 9, remote = "packs/districts/square/bg.jpg?v=dd", bytes = 5, district = "square" },
		["districts/stadium/bg"] = { file = "/x/stadium/bg.jpg", w = 9, h = 9, remote = "packs/districts/stadium/bg.jpg?v=ee", bytes = 6, district = "stadium" },
	}
end

local GROUPS = {
	jazz = { "districts/jazz/bg", "districts/jazz/sax", "mapbg/bg_jazz" },
	square = { "districts/square/bg" },
	stadium = { "districts/stadium/bg" },
}
local ORDER = { "cafe", "jazz", "square", "stadium" }

describe("client.packs", function()
	local w
	local saved = {}
	for _, k in ipairs({ "PARALLEL", "TRIES", "PAUSE", "RETRY_AFTER", "TIMEOUT", "MIN_RATE", "BUDGET", "RECENT", "STREAK", "HOLD", "HOLD_MAX" }) do saved[k] = packs[k] end
	before_each(function()
		for k, v in pairs(saved) do packs[k] = v end -- a test may change the knobs
		w = web()
		packs.init({ request = w.request, clock = w.clock, base = "https://host/game/", images = images(), groups = GROUPS })
		packs.focus("cafe", ORDER)
	end)

	it("is off without a request function or a base address (other platforms, the tests): nothing is fetched", function()
		packs.init({ images = images(), groups = GROUPS })
		assert_false(packs.enabled())
		assert_false(packs.remote("districts/jazz/bg"))
		assert_eq(packs.want("districts/jazz/bg"), nil)
		packs.update()
		assert_eq(#w.calls, 0)
		-- every district counts as complete: the archive holds its pictures
		assert_true(packs.complete("jazz"))
	end)

	it("fetches a remote picture from the page's folder, keeps its bytes and counts the arrival", function()
		assert_true(packs.remote("districts/jazz/bg"))
		assert_false(packs.remote("districts/cafe/bg"))
		assert_eq(packs.want("districts/cafe/bg"), nil, "a picture of the archive is never fetched")
		assert_eq(packs.want("districts/jazz/bg"), "queued")
		assert_eq(#w.calls, 0, "requests start in update(), from the one script that lives as long as the app")
		packs.update()
		assert_eq(#w.calls, 1)
		assert_eq(w.calls[1].url, "https://host/game/packs/districts/jazz/bg.jpg?v=aa")
		assert_eq(packs.bytes("districts/jazz/bg"), nil)
		local v = packs.version
		w.answer(1, 200, "JPEG")
		assert_eq(packs.bytes("districts/jazz/bg"), "JPEG")
		assert_eq(packs.version, v + 1)
		-- asked again: nothing more is requested
		assert_eq(packs.want("districts/jazz/bg"), "ready")
		packs.update()
		assert_eq(#w.calls, 1)
	end)

	it("runs at most PARALLEL requests and serves the lowest priority number first, then the oldest request", function()
		packs.PARALLEL = 1
		packs.want_district("stadium", packs.NEXT)
		packs.want_district("square", packs.FOCUS)
		packs.want("districts/jazz/sax", packs.LATER)
		packs.want("districts/jazz/bg", packs.LATER)
		packs.update()
		assert_eq(#w.calls, 1)
		assert_true(w.calls[1].url:find("square", 1, true) ~= nil, w.calls[1].url)
		packs.want("districts/jazz/bg", packs.NOW) -- on screen now: it jumps the queue
		w.answer(1, 200, "SQUAR")
		packs.update()
		assert_true(w.calls[2].url:find("jazz/bg", 1, true) ~= nil, w.calls[2].url)
		w.answer(2, 200, "JPEG")
		packs.update()
		assert_true(w.calls[3].url:find("stadium", 1, true) ~= nil, w.calls[3].url)
		w.answer(3, 200, "STADIU")
		packs.update()
		assert_true(w.calls[4].url:find("jazz/sax", 1, true) ~= nil, w.calls[4].url)
		local log = packs.status(true).log
		assert_same(log, { "districts/square/bg", "districts/jazz/bg", "districts/stadium/bg", "districts/jazz/sax" })
	end)

	it("takes only a whole file: a 404 page, a wrong size or no status is a failed attempt", function()
		packs.PARALLEL = 3
		packs.want_district("jazz", packs.FOCUS)
		packs.update()
		assert_eq(#w.calls, 3)
		w.answer(1, 404, "<html>not found</html>")
		w.answer(2, 200, "toolong")
		w.answer(3, 0, nil)
		assert_eq(packs.bytes("districts/jazz/bg"), nil)
		assert_eq(packs.bytes("districts/jazz/sax"), nil)
		local got, total, pending, failed = packs.progress("jazz")
		assert_eq(got, 0)
		assert_eq(total, 9)
		assert_eq(pending, 3, "each will be tried again")
		assert_eq(failed, 0)
	end)

	it("tries again after a pause that doubles, then reports the file failed, and lets it be asked for later", function()
		packs.TRIES, packs.PAUSE, packs.RETRY_AFTER = 3, 2, 20
		packs.want("districts/jazz/bg", packs.NOW)
		packs.update()
		w.answer(1, 0, nil)
		packs.update()
		assert_eq(#w.calls, 1, "the pause comes first")
		w.t = 2.1
		packs.update()
		assert_eq(#w.calls, 2)
		w.answer(2, 500, "")
		w.t = 5
		packs.update()
		assert_eq(#w.calls, 2, "the second pause is twice as long")
		w.t = 6.2
		packs.update()
		assert_eq(#w.calls, 3)
		w.answer(3, 0, nil)
		local _, _, pending, failed = packs.progress("jazz")
		assert_eq(pending, 0)
		assert_eq(failed, 1)
		-- asked for again too soon: it stays failed; after RETRY_AFTER a new round starts
		assert_eq(packs.want("districts/jazz/bg"), "failed")
		w.t = 6.2 + 20.1
		assert_eq(packs.want("districts/jazz/bg"), "queued")
		packs.update()
		assert_eq(#w.calls, 4)
		w.answer(4, 200, "JPEG")
		assert_eq(packs.bytes("districts/jazz/bg"), "JPEG")
		-- the next round after a failure waits twice as long
		assert_true(packs.complete("jazz") == false)
	end)

	it("gives up a request past its deadline and ignores its late answer", function()
		packs.TIMEOUT, packs.PAUSE = 10, 1
		packs.want("districts/jazz/bg", packs.NOW)
		packs.update()
		w.t = 10.5
		packs.update()
		local _, _, pending = packs.progress("jazz")
		assert_eq(pending, 1)
		w.t = 12
		packs.update()
		assert_eq(#w.calls, 2, "a new attempt after the pause")
		w.answer(1, 200, "JPEG") -- the first request answers at last: ignored
		assert_eq(packs.bytes("districts/jazz/bg"), nil)
		w.answer(2, 200, "JPEG")
		assert_eq(packs.bytes("districts/jazz/bg"), "JPEG")
	end)

	it("gives a big file more time: the limit grows with its size (a slow link must not time out a map tile)", function()
		packs.TIMEOUT, packs.MIN_RATE, packs.PAUSE = 10, 1, 1
		packs.want("districts/stadium/bg", packs.NOW) -- 6 bytes at 1 byte a second: 16 s
		packs.update()
		assert_eq(w.calls[1].seconds, 16, "the HTTP request gets the same limit")
		w.t = 15.9
		packs.update()
		local _, _, pending = packs.progress("stadium")
		assert_eq(pending, 1)
		w.answer(1, 200, "STADIU")
		assert_eq(packs.bytes("districts/stadium/bg"), "STADIU", "in time")
	end)

	it("never raises: a request function that throws, an answer callback with garbage", function()
		packs.init({ request = function() error("boom") end, clock = w.clock, base = "b/", images = images(), groups = GROUPS })
		packs.want("districts/jazz/bg")
		packs.update()
		local _, _, pending = packs.progress("jazz")
		assert_eq(pending, 1, "the attempt failed and waits for the next one")
		packs.init({ request = w.request, clock = function() error("no clock") end, base = "b/", images = images(), groups = GROUPS })
		packs.want("districts/jazz/bg")
		packs.update()
		w.answer(1, {}, function() end)
		assert_eq(packs.bytes("districts/jazz/bg"), nil)
	end)

	it("reports the progress of a district in bytes", function()
		packs.want_district("jazz", packs.FOCUS)
		packs.update()
		w.answer(1, 200, "JPEG")
		local got, total, pending, failed = packs.progress("jazz")
		assert_eq(got, 4)
		assert_eq(total, 9)
		assert_eq(pending, 2)
		assert_eq(failed, 0)
		assert_false(packs.complete("jazz"))
		w.answer(2, 200, "SAX")
		packs.update() -- (at most PARALLEL requests at once: the third starts now)
		w.answer(3, 200, "MB")
		assert_true(packs.complete("jazz"))
		assert_true(packs.complete("cafe"), "no remote pictures: complete")
	end)

	it("holds at most BUDGET bytes: the files of the districts far from the player go first, never the player's or the next", function()
		packs.BUDGET, packs.RECENT, packs.PARALLEL = 10, 5, 10
		packs.focus("jazz", ORDER)
		packs.want_district("jazz", packs.FOCUS)    -- 9 bytes, the player's district
		packs.want_district("square", packs.NEXT)   -- 5 bytes, the next one
		packs.update()
		for i = 1, 4 do w.answer(i, 200, ({ "JPEG", "SAX", "MB", "SQUAR" })[i]) end
		assert_true(packs.complete("jazz"))
		assert_true(packs.complete("square"), "over the budget, but both are protected")
		w.t = 100
		packs.want_district("stadium", packs.LATER) -- 6 bytes, two districts ahead
		packs.update()
		w.answer(5, 200, "STADIU")
		assert_eq(packs.status().held, 20, "nothing may go: the player's, the next one and the file that just came")
		-- the player moves on to stadium: jazz and square are behind now and leave, the farthest first
		w.t = 200
		packs.bytes("districts/jazz/sax") -- read a moment ago: it stays for RECENT seconds
		w.t = 202
		packs.focus("stadium", ORDER)
		assert_eq(packs.status().held, 9)
		assert_eq(packs.bytes("districts/jazz/bg"), nil)
		assert_eq(packs.bytes("mapbg/bg_jazz"), nil)
		assert_eq(packs.bytes("districts/square/bg"), nil)
		assert_eq(packs.bytes("districts/jazz/sax"), "SAX")
		assert_eq(packs.bytes("districts/stadium/bg"), "STADIU")
		assert_eq(packs.status().released, 3)
		-- a released picture is fetched again when it is wanted
		assert_eq(packs.want("districts/jazz/bg", packs.NOW), "queued")
		packs.update()
		assert_eq(w.calls[#w.calls].url, "https://host/game/packs/districts/jazz/bg.jpg?v=aa")
	end)

	it("pauses every request after many failures in a row (the link is down), and goes on after a success", function()
		packs.STREAK, packs.HOLD, packs.HOLD_MAX, packs.PARALLEL, packs.PAUSE = 2, 5, 60, 1, 0
		packs.want_district("jazz", packs.FOCUS)
		packs.update()
		w.answer(1, 0, nil)
		packs.update()
		assert_eq(#w.calls, 2, "one failure: the next file goes at once")
		w.answer(2, 0, nil)
		packs.update()
		assert_eq(#w.calls, 2, "two in a row: everything waits HOLD seconds")
		assert_true(packs.offline())
		w.t = 4.9
		packs.update()
		assert_eq(#w.calls, 2)
		w.t = 5
		packs.update()
		assert_eq(#w.calls, 3)
		w.answer(3, 0, nil)
		w.t = 14.9
		packs.update()
		assert_eq(#w.calls, 3, "a third failure: twice as long")
		w.t = 15
		packs.update()
		assert_eq(#w.calls, 4)
		local body = { ["districts/jazz/bg"] = "JPEG", ["districts/jazz/sax"] = "SAX", ["mapbg/bg_jazz"] = "MB" }
		w.answer(4, 200, body[w.calls[4].url:match("packs/(.-)%.%a+%?")])
		packs.update()
		assert_eq(#w.calls, 5, "a success ends the pause")
		assert_false(packs.offline())
	end)

	-- (last: the tests of other files share this Lua state and expect the module off, as in a native build)
	it("is off again after _reset()", function()
		packs._reset()
		assert_false(packs.enabled())
		assert_eq(packs.version, 0)
	end)
end)
