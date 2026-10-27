-- A monkey in a whole session (tests/client/session_harness.lua): random taps on the buttons the game reports,
-- random touches, swipes on the board, the back key, the app losing the focus, window resizes, language switches,
-- autoplay and save failures, over every screen and window, with the real scripts. What it looks for is what the
-- scripted sessions (session_test.lua) cannot guess: an error a screen swallows (the harness fails the session on
-- any WARNING / ERROR line the game prints), a stuck fade, a subscription or an open attempt a screen leaves
-- behind. The seeds are fixed (a small deterministic generator, the same on both VMs): a failure names its seed
-- and the step, and the same call repeats it.

local S = require("tests.client.session_harness")
local bus = require("client.bus")
local link = require("client.level_link")
local rewards = require("client.rewards")
local flow = require("client.flow")

local WINDOWS = { { 720, 1280 }, { 390, 844 }, { 1280, 720 }, { 768, 1024 } }
local DIRECTIONS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local HOPS = { "splash", "town", "level" }
local WINDOW_NAMES = { "start", "lives", "shop", "jukebox", "chest", "concert", "gift" }

-- Park-Miller: exact in doubles, no bit operators, the same sequence on Lua 5.1 and LuaJIT
local function generator(seed)
	local state = seed * 7919 % 2147483646 + 1
	return function(a, b)
		state = state * 16807 % 2147483647
		local unit = (state - 1) / 2147483646
		if not a then return unit end
		if not b then a, b = 1, a end
		return a + math.floor(unit * (b - a + 1))
	end
end

-- One run: `actions` random actions, then everything is put in order again. Returns what the run visited.
local function monkey(seed, actions, opts)
	opts = opts or {}
	local rng = generator(seed)
	local seen = {}
	local function visit(kind, name)
		local key = kind .. ":" .. tostring(name)
		seen[key] = (seen[key] or 0) + 1
	end
	S.run({ audio = true, language = "en", levels = opts.levels, setup = function(app)
		for _ = 1, opts.wins or 0 do assert(flow.debug_win(3)) end
		if opts.coins then app.meta:grant({ coins = opts.coins }, "test", app.now()) end
	end }, function(s)
		local app, E = s.app, s.E
		local function buttons()
			local ui = app.ui or {}
			local src = ui.popup and ui.popup_targets or ui.targets
			local list = {}
			for name, t in pairs(src or {}) do list[#list + 1] = { name = name, x = t.x, y = t.y } end
			table.sort(list, function(a, b) return a.name < b.name end)
			return list
		end
		for step = 1, actions do
			local r = rng(100)
			if r <= 38 then
				local list = buttons()
				if #list > 0 then
					local t = list[rng(#list)]
					s:tap(t.x, t.y)
				else
					s:step(rng(5))
				end
			elseif r <= 50 then
				s:tap(rng(0, 720), rng(0, 1280))
			elseif r <= 62 then
				if link.active() and link.status() then
					local info = link.info()
					local a = { rng(info.W), rng(info.H) }
					local d = DIRECTIONS[rng(#DIRECTIONS)]
					s:swipe_cells(a, { math.max(1, math.min(info.W, a[1] + d[1])), math.max(1, math.min(info.H, a[2] + d[2])) })
				else
					s:step(rng(10))
				end
			elseif r <= 80 then
				s:step(rng(1, 90))
			elseif r <= 84 then
				E.input(hash("back"), { released = true, pressed = false })
				s:step(2)
			elseif r <= 87 then
				E.window_listener(nil, window.WINDOW_EVENT_FOCUS_LOST, {})
				s:step(rng(1, 30))
				E.window_listener(nil, window.WINDOW_EVENT_FOCUS_GAINED, {})
			elseif r <= 90 then
				local w = WINDOWS[rng(#WINDOWS)]
				E.set_window(w[1], w[2])
				s:step(rng(1, 10))
			elseif r <= 93 then
				app.set_setting("language", rng(2) == 1 and "en" or "ru")
				s:step(2)
			elseif r <= 96 then
				if link.active() and link.board and link.status() and link.status().state == "playing" then
					link.board.session:qa("autoplay", { tostring(rng(1, 6)) })
				end
			elseif r <= 98 then
				if link.active() and link.board then link.board.session:qa("win") end
			elseif r == 99 then
				s:qa("save_fail " .. rng(0, 1))
			else
				-- rare ones: time passes (minutes, days), the QA bridge hops between screens, windows and wins, a screen
				-- is requested straight from code
				local k = rng(6)
				if k == 1 then
					E.clock = E.clock + rng(60, 3 * 3600)
				elseif k == 2 then
					E.clock = E.clock + rng(1, 40) * 86400
				elseif k == 3 then
					s:qa("goto " .. HOPS[rng(#HOPS)] .. (rng(2) == 1 and (" " .. rng(1, 30)) or ""))
				elseif k == 4 then
					s:qa("open " .. WINDOW_NAMES[rng(#WINDOW_NAMES)])
				elseif k == 5 then
					app.show_screen(HOPS[rng(#HOPS)], {})
				else
					s:qa("meta_win " .. rng(1, 10))
				end
			end
			visit("screen", app.screen)
			if app.ui and app.ui.popup then visit("popup", app.ui.popup) end
			if link.active() and link.status() then visit("state", link.status().state) end
			if #bus.default.subs > 12 then
				error("seed " .. seed .. ", action " .. step .. ": " .. #bus.default.subs .. " bus subscribers: a screen leaves some behind", 0)
			end
		end
		-- put everything in order: the disk works again, the town is shown, the rewards are paid
		s:qa("save_fail 0")
		s:run(5)
		assert_eq(app.store.failing, 0, "seed " .. seed .. ": the save works again and was written")
		E.set_window(720, 1280)
		app.show_screen("town", {})
		s:step_until(function() return app.screen == "town" and not app.transitioning end, 10, "the town (seed " .. seed .. ")")
		s:run(5) -- the town starts paying the rewards a moment after it appears
		s:step_until(function() return not app.ui.busy end, 120, "the town to be at rest (seed " .. seed .. ")")
		assert_eq(app.meta:run(), nil, "seed " .. seed .. ": no attempt is left open in the town")
		assert_eq(rewards.count(), 0, "seed " .. seed .. ": every reward was shown")
		assert_eq(#bus.default.subs, 3, "seed " .. seed .. ": overlay, audio and the town listen, nobody else")
		assert_eq(app.ui.disp.coins, app.meta:coins(), "seed " .. seed .. ": the top bar shows what the meta holds")
		assert_eq(app.ui.disp.stars, app.meta:stars())
	end)
	return seen
end

describe("a session: the monkey", function()
	it("survives random play over the first launch, the town, the level and every window, from several saves", function()
		local visited = {}
		-- {seed, levels already won, coins} ; a 5-move level 25 ends in the moves window quickly
		local runs = {
			{ 1, 0 }, { 2, 0 }, { 3, 24, 5000, true }, { 4, 3 }, { 6, 24, 5000, true }, { 8, 10, 1500 },
		}
		for _, run in ipairs(runs) do
			local opts = { wins = run[2], coins = run[3] }
			if run[4] then opts.levels = { [25] = function(d) d.moves = 5 end } end
			for key, n in pairs(monkey(run[1], 300, opts)) do visited[key] = (visited[key] or 0) + n end
		end
		-- the monkey must keep reaching the places worth testing (a change that walls it in fails here)
		for _, key in ipairs({ "screen:splash", "screen:town", "screen:level", "popup:start", "popup:settings", "popup:pause",
			"popup:shop", "popup:moves", "popup:result", "state:playing", "state:out_of_moves", "state:complete" }) do
			assert_true(visited[key], "the monkey never got to " .. key)
		end
	end)
end)
