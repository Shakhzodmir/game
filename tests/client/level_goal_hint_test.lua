-- A tap on a goal tile of the level HUD explains the goal (screens/level/hud.lua draws a pill under the panel,
-- screens/level/level.gui_script routes the press), run on the strict GUI stub next to a stand-in for the board
-- (tests/client/level_fake_board.lua, a real core game behind client/level_link.lua). The pure side (the tile under a
-- press, the line of each kind, the place of the pill, the clock) is in tests/client/level_hud_test.lua.

local G = require("tests.client.level_gui_helper")
local bus = require("client.bus")
local i18n = require("client.i18n")
local level_hud = require("client.level_hud")
local link = require("client.level_link")

local SCENE = "/screens/level/level.gui"

-- level 178 has two colour goals: 45 red picks and 36 purple headphones (a 9x9 board with room under the panel);
-- level 185 is a 7x11 board with the dance floor (23 tiles): the board that leaves the least room under the panel
local RED = "Red picks: collect 45 more"
local PURPLE = "Purple headphones: collect 36 more"

local function ui(c) return c.app.ui.level end
local function hud(c) return c.hud.self.l.hud end
local function top(c) return c.popup() end

-- the tile's own tap target, as the QA bridge publishes it
local function goal_at(c, k)
	local t = ui(c).targets["goal" .. k]
	assert_true(t ~= nil and t.x ~= nil and t.y ~= nil, "no tap target goal" .. k)
	return t.x, t.y
end

-- a real tap: a press, two frames, a release
local function tap_goal(c, k)
	local x, y = goal_at(c, k)
	return c.tap(x, y)
end

local function tap_target(c, name)
	local t = ui(c).targets[name]
	assert_true(t ~= nil, "no tap target " .. name)
	return c.tap(t.x, t.y)
end

-- every test ends with these: the script did not trip over itself, and the scene is legal
local function clean(c)
	assert_eq(ui(c).errors, 0, "errors in the HUD code")
	local problems = c.E.audit()
	assert_eq(#problems, 0, table.concat(problems, "\n"))
end

local function nodes(c) return c.hud:stats().nodes end

-- is `n` the root or inside it
local function under(n, root)
	while n do
		if n == root then return true end
		n = n.parent
	end
	return false
end

-- the running animations of the nodes of the hint
local function hint_anims(c)
	local root = hud(c).hint_node
	local out = {}
	if not root then return out end
	for _, a in ipairs(c.E.scene(SCENE).anims) do
		if a.node and not a.node.dead and under(a.node, root) then out[#out + 1] = a end
	end
	return out
end

-- ticks the board and the GUI until the board is at rest
local function settle(c, seconds)
	for _ = 1, math.ceil((seconds or 40) * 60) do
		c.step(1)
		if c.fb:stable() and c.fb.session.game:status().state ~= "won_wait" then return true end
	end
	return false
end

local function game(c)
	local st = c.fb.session.game:status()
	local goals = {}
	for i, v in ipairs(st.goals) do goals[i] = v end
	return { moves = st.moves_left, state = st.state, goals = goals, score = st.score }
end

local function swap_step(level)
	local cmd
	G.with_level({ level = level }, function(c) cmd = c.fb.session:hint_command() end)
	local function zero(p) return { p[1] - 1, p[2] - 1 } end
	return { kind = "swap", from = zero(cmd.from), to = zero(cmd.to), text = "tutorial.swap" }, cmd
end

describe("level goal hints: a tap on a goal tile", function()
	it("explains a colour goal with what is to collect and how many are left, and the game does not notice", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			local before = game(c)
			local n0 = nodes(c)
			assert_eq(ui(c).goal_hint, nil)
			assert_false(c.has(RED))
			local pressed, released = tap_goal(c, 1)
			assert_true(pressed ~= nil, "the HUD took the press")
			assert_true(released ~= nil, "... and the release")
			c.step(2)
			assert_eq(ui(c).goal_hint, 1)
			assert_eq(ui(c).goal_hint_text, RED)
			assert_true(c.has(RED), "the line is on the screen")
			assert_true(nodes(c) > n0, "the pill has nodes")
			-- the game stood still: no move, no counter, no state, no tutorial, nothing paused
			assert_same(game(c), before)
			assert_eq(ui(c).tutorial, nil)
			assert_false(c.app.meta:tutorial_seen("level_178"), "no lesson was marked")
			assert_false(c.fb.session.paused, "the board runs on")
			clean(c)
		end)
	end)

	it("publishes a tap target for every goal tile, and a tap on it is the same as a tap on the tile", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			local t = ui(c).targets
			assert_true(t.goal1 ~= nil and t.goal2 ~= nil, "two tiles")
			assert_eq(t.goal3, nil, "no third tile")
			assert_true(t.goal1.x < t.goal2.x, "left to right")
			local x, y = hud(c):goal_pos(2)
			assert_eq(t.goal2.x, x)
			assert_eq(t.goal2.y, y)
			tap_target(c, "goal2")
			c.step(2)
			assert_eq(ui(c).goal_hint, 2)
			assert_true(c.has(PURPLE))
			-- the pause button and the boosters are still there
			assert_true(t.pause ~= nil and t.stick ~= nil)
		end)
		G.with_level({ level = 60, attempt = false }, function(c)
			c.run(0.8)
			assert_true(ui(c).targets.goal3 ~= nil, "three goals, three tiles")
		end)
	end)

	it("goes away by itself after a few seconds and leaves no node behind", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			local n0 = nodes(c)
			tap_goal(c, 1)
			c.step(2)
			assert_true(c.has(RED))
			c.run(level_hud.GOAL_HINT_SECONDS - 1)
			assert_true(c.has(RED), "still there before the time is up")
			assert_eq(ui(c).goal_hint, 1)
			c.run(1.3)
			assert_false(c.has(RED), "gone after the time")
			assert_eq(ui(c).goal_hint, nil)
			assert_eq(ui(c).goal_hint_text, nil)
			assert_eq(hud(c).hint_node, nil)
			assert_eq(nodes(c), n0, "every node of the pill was deleted")
			clean(c)
		end)
	end)

	it("shows one hint at a time: another tile replaces it, the same tile renews the time", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			local n0 = nodes(c)
			tap_goal(c, 1)
			c.step(2)
			local one = nodes(c)
			c.run(2)
			tap_goal(c, 2)
			c.step(2)
			assert_eq(ui(c).goal_hint, 2)
			assert_true(c.has(PURPLE))
			assert_false(c.has(RED), "the first hint is gone")
			assert_eq(nodes(c), one, "one pill, not two")
			-- the second one has its own full time: after 2 s of the first one's life it is still there
			c.run(level_hud.GOAL_HINT_SECONDS - 0.8)
			assert_true(c.has(PURPLE))
			-- the same tile again renews the time
			tap_goal(c, 2)
			c.step(2)
			c.run(level_hud.GOAL_HINT_SECONDS - 0.8)
			assert_true(c.has(PURPLE), "renewed")
			assert_eq(nodes(c), one, "still one pill")
			c.run(1.2)
			assert_false(c.has(PURPLE))
			assert_eq(nodes(c), n0)
			clean(c)
		end)
	end)

	it("ends with the next press on the board, and that press is not taken: it goes to the board", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			tap_goal(c, 1)
			c.step(2)
			assert_true(c.has(RED))
			local x, y = c.cell(5, 5)
			local pressed = c.tap(x, y)
			assert_eq(pressed, nil, "the HUD leaves a press on the board to the board")
			c.step(2)
			assert_false(c.has(RED))
			assert_eq(ui(c).goal_hint, nil)
			-- and the board still works: a move by the core's own hint goes through
			local cmd = c.fb.session:hint_command()
			local moves = game(c).moves
			assert_true(c.fb:send(cmd))
			settle(c)
			assert_eq(game(c).moves, moves - 1)
			clean(c)
		end)
	end)

	it("ends with a tap on a booster or on the pause button, which then do their work", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			tap_goal(c, 1)
			c.step(2)
			assert_true(c.has(RED))
			tap_target(c, "stick")
			c.step(5)
			assert_false(c.has(RED), "the booster tap ended the hint")
			assert_eq(ui(c).targeting, "stick", "... and armed the booster")
			tap_target(c, "stick") -- disarm
			c.step(5)
			tap_goal(c, 2)
			c.step(2)
			assert_true(c.has(PURPLE))
			tap_target(c, "pause")
			c.step(20)
			assert_eq(top(c), "pause", "the pause window opened")
			assert_false(c.has(PURPLE), "the hint went with the window")
			c.tap_target("resume")
			c.step(20)
			assert_false(c.has(PURPLE), "and does not come back")
			assert_eq(ui(c).goal_hint, nil)
			clean(c)
		end)
	end)

	it("does not disarm a booster that waits for its target: the target is still picked with the next tap", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			tap_target(c, "stick")
			c.step(5)
			assert_eq(ui(c).targeting, "stick")
			local moves = game(c).moves
			local pressed = tap_goal(c, 1)
			assert_true(pressed ~= nil)
			c.step(2)
			assert_true(c.has(RED), "the tile explains itself while a booster is armed")
			assert_eq(ui(c).targeting, "stick", "the booster is still armed")
			assert_eq(link.targeting(), "stick", "... on the board too")
			-- the target is picked with the next tap on the board: that tap also ends the hint
			local x, y = c.cell(4, 4)
			c.tap(x, y)
			c.fb:tap(4, 4)
			settle(c)
			assert_false(c.has(RED))
			assert_eq(ui(c).targeting, nil, "the booster was used")
			assert_eq(game(c).moves, moves, "a booster costs no move")
			clean(c)
		end)
	end)

	it("keeps the first piece of a two-tap Crossfader pick picked", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			tap_target(c, "swap")
			c.step(5)
			assert_eq(ui(c).targeting, "swap")
			assert_true(c.fb:tap(5, 5))
			c.step(5)
			assert_true(c.fb.input.pair ~= nil, "the first piece is picked")
			assert_true(c.has("Now the second piece"))
			tap_goal(c, 1)
			c.step(3)
			assert_true(c.has(RED))
			assert_true(c.fb.input.pair ~= nil, "still picked")
			assert_eq(ui(c).targeting, "swap")
			assert_true(c.has("Now the second piece"), "the bar still asks for the second one")
			clean(c)
		end)
	end)

	it("is harmless while the pieces are still moving", function()
		G.with_level({ level = 1 }, function(c)
			c.run(0.8)
			local cmd = assert(c.fb.session:hint_command())
			assert_true(c.fb:send(cmd))
			c.step(8)
			assert_false(c.fb:stable(), "the pieces are falling")
			local moves = game(c).moves
			assert_eq(moves, 19, "the move was made")
			tap_goal(c, 1)
			c.step(2)
			assert_true(ui(c).goal_hint == 1)
			assert_eq(game(c).moves, moves, "a tap costs no move")
			assert_true(settle(c))
			c.run(0.5)
			assert_eq(game(c).moves, moves, "... nor later")
			assert_eq(ui(c).errors, 0)
			-- the board is at rest and the next move goes through as it would have without the tap
			assert_true(c.fb:send(assert(c.fb.session:hint_command())))
			settle(c)
			assert_eq(game(c).moves, moves - 1)
			clean(c)
		end)
	end)

	it("follows the counter while it is shown, and says the goal is done when nothing is left", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			tap_goal(c, 1)
			c.step(2)
			assert_true(c.has(RED))
			bus.publish("level_goal", { index = 1, left = 20 })
			c.step(3)
			assert_eq(ui(c).goal_hint, 1)
			assert_eq(ui(c).goal_hint_text, "Red picks: collect 20 more")
			assert_false(c.has(RED))
			bus.publish("level_goal", { index = 1, left = 0 })
			c.step(3)
			assert_eq(ui(c).goal_hint_text, "This goal is done!")
			local n = nodes(c)
			-- a goal that is done is explained too (a tick is no answer), once
			c.run(level_hud.GOAL_HINT_SECONDS + 0.5)
			assert_eq(ui(c).goal_hint, nil)
			tap_goal(c, 1)
			c.step(2)
			assert_eq(ui(c).goal_hint_text, "This goal is done!")
			assert_eq(nodes(c), n)
			clean(c)
		end)
	end)

	it("ignores a press over the panel while the level is not played: in the finale it reaches the board (it skips the concert)", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			bus.publish("level_state", { state = "won_wait" })
			c.step(3)
			local pressed = tap_goal(c, 1)
			assert_eq(pressed, nil, "the panel does not take the press the board would take as the skip")
			assert_eq(ui(c).goal_hint, nil)
			bus.publish("level_state", { state = "concert" })
			c.step(3)
			assert_eq(tap_goal(c, 2), nil)
			assert_eq(ui(c).goal_hint, nil)
		end)
	end)

	it("ends when the finale begins", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			tap_goal(c, 1)
			c.step(2)
			assert_true(c.has(RED))
			bus.publish("level_state", { state = "won_wait" })
			c.step(3)
			assert_false(c.has(RED), "the finale ends it")
			assert_eq(ui(c).goal_hint, nil)
			assert_eq(hud(c).hint_node, nil)
			clean(c)
		end)
	end)

	it("is gone when the language changes, and speaks the new language at the next tap", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			tap_goal(c, 1)
			c.step(2)
			assert_true(c.has(RED))
			assert_true(c.app.set_setting("language", "ru"))
			c.step(10)
			assert_eq(ui(c).goal_hint, nil)
			assert_false(c.has(RED))
			assert_eq(ui(c).errors, 0)
			tap_goal(c, 2)
			c.step(2)
			assert_true(c.has("Фиолетовые наушники: собери ещё 36"))
			assert_true(c.app.set_setting("language", "ko"))
			c.step(10)
			tap_goal(c, 1)
			c.step(2)
			assert_true(c.has("빨간 피크: 45개 더 모아요"))
			clean(c)
		end)
	end)

	it("leaves a lesson on the screen alone: no hint over it, nothing marked or started", function()
		local step = swap_step(1)
		G.with_level({ level = 1, tutorials = { ["1"] = { steps = { step } } } }, function(c)
			c.run(1.0)
			assert_eq(ui(c).tutorial.phase, "active")
			local blocked = ui(c).tutorial.blocked
			tap_goal(c, 1)
			c.step(3)
			assert_eq(ui(c).goal_hint, nil, "the lesson speaks")
			assert_false(c.has("Red picks: collect 30 more"))
			assert_eq(ui(c).tutorial.phase, "active", "the lesson is where it was")
			assert_eq(ui(c).tutorial.blocked, blocked)
			assert_false(c.app.meta:tutorial_seen("level_1"))
			clean(c)
		end)
		-- a hint that was shown just before the lesson began goes when the lesson's bubble comes
		G.with_level({ level = 1, tutorials = { ["1"] = { steps = { step } } } }, function(c)
			assert_eq(ui(c).tutorial.phase, "wait", "the board blooms in first")
			c.run(0.4)
			tap_goal(c, 1)
			c.step(2)
			assert_eq(ui(c).goal_hint, 1, "a hint before the lesson")
			c.run(1.0)
			assert_eq(ui(c).tutorial.phase, "active")
			assert_eq(ui(c).goal_hint, nil, "gone when the lesson's bubble came")
			assert_true(c.has("Swap two pieces to make a line of 3"))
			clean(c)
		end)
	end)

	it("does not fire the tutorial: a lesson that was seen stays seen, and a goal tap starts or marks nothing", function()
		local step = swap_step(1)
		G.with_level({ level = 1, tutorials = { ["1"] = { steps = { step } } },
			setup = function(app) app.meta:mark_tutorial_seen("level_1") end }, function(c)
			c.run(1.0)
			assert_eq(ui(c).tutorial, nil, "the lesson was seen: none starts")
			tap_goal(c, 1)
			c.step(3)
			assert_eq(ui(c).goal_hint, 1)
			assert_eq(ui(c).tutorial, nil, "no lesson started by the tap")
			assert_false(link.guard() ~= nil, "no guard on the board")
			assert_true(c.app.meta:tutorial_seen("level_1"))
			clean(c)
		end)
		-- a lesson that has not run yet is not marked as seen by a tap on a tile (a lesson 'wait' is not 'active' either)
		G.with_level({ level = 1, tutorials = { ["1"] = { steps = { step } } } }, function(c)
			assert_false(c.app.meta:tutorial_seen("level_1"))
			c.run(0.3)
			tap_goal(c, 1)
			c.step(3)
			assert_false(c.app.meta:tutorial_seen("level_1"), "a tap on a tile is not a lesson")
			clean(c)
		end)
	end)

	it("honours reduced motion: the pill appears and disappears, nothing moves", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.app.set_setting("reduced_motion", true)
			c.run(0.8)
			tap_goal(c, 1)
			c.step(2)
			assert_true(c.has(RED))
			assert_eq(#hint_anims(c), 0, "no animation on any node of the pill")
			local gn = hud(c).goal_nodes[1]
			assert_eq(gn.icon.scale.x, 1, "the tile did not bump")
			-- every box of the pill is at rest scale at once (a text is scaled to its size, a box never is)
			local boxes = 0
			for _, n in ipairs(c.E.alive_nodes(c.E.scene(SCENE))) do
				if under(n, hud(c).hint_node) and n.kind == "box" then
					boxes = boxes + 1
					assert_true(math.abs(n.scale.x - 1) < 1e-9, "a box of the pill is scaled: " .. n.scale.x)
				end
			end
			assert_true(boxes >= 4, "the pill has its boxes: " .. boxes)
			c.run(level_hud.GOAL_HINT_SECONDS + 0.5)
			assert_false(c.has(RED))
			clean(c)
		end)
	end)

	it("pops in and bumps the tile when motion is on", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			tap_goal(c, 1)
			assert_true(#hint_anims(c) >= 1 or hud(c).goal_nodes[1].icon.scale.x ~= 1, "something moves")
			c.run(1)
			assert_eq(#hint_anims(c), 0, "and comes to rest")
			clean(c)
		end)
	end)

	it("does not leak nodes or animations when the tiles are hammered", function()
		G.with_level({ level = 178, attempt = false }, function(c)
			c.run(0.8)
			local n0 = nodes(c)
			for i = 1, 60 do
				tap_goal(c, (i % 2) + 1)
				c.step(1)
			end
			c.step(2)
			assert_true(nodes(c) <= n0 + 12, "one pill at a time: " .. (nodes(c) - n0) .. " more nodes")
			c.run(level_hud.GOAL_HINT_SECONDS + 1)
			assert_eq(nodes(c), n0)
			clean(c)
		end)
	end)

	it("keeps the pill off the cells of the tallest board and inside the window, and under the tile it explains", function()
		for _, win in ipairs({ { 720, 1280 }, { 360, 640 }, { 390, 844 }, { 1920, 970 } }) do
			G.with_level({ level = 185, attempt = false, window = win }, function(c)
				c.run(0.8)
				local k = 1
				tap_goal(c, k)
				c.step(2)
				local h = hud(c)
				local r = h.hint_rect
				assert_true(r ~= nil, "a pill")
				local b = link.board_rect()
				assert_true(r.y0 >= b.y1 + 0.5, win[1] .. "x" .. win[2] .. ": the pill covers a cell")
				assert_true(r.x0 >= h.l.safe.x0 and r.x1 <= h.l.safe.x1, "inside the window")
				local x = h:goal_pos(k)
				assert_true(r.tail_x >= r.x0 and r.tail_x <= r.x1)
				assert_near(r.tail_x, x, 0.5, "the pointer is under the tile")
				assert_true(r.y1 < h.l.goals.y0 + level_hud.GOAL_PANEL_EDGE, "below the panel's edge: no counter covered")
			end)
		end
	end)

	-- what the pill says for each kind, in English (the first level that has the kind decides the colour of a colour goal)
	local SAYS = {
		["break:record_box"] = "Record boxes don't move. Break them!",
		light = "Match on purple tiles: they turn gold",
		deliver = "Bring the microphones to the stage!",
		["break:concrete"] = "Only specials break concrete!",
		["break:noise"] = "Stop the noise before it spreads!",
		["break:balloon"] = "Pop the balloons with their own colour!",
		["break:column"] = "Knock the dust off the big speaker!",
		drop = "Coconuts don't pop: bring them down!",
		chains = "A chain holds the piece. Make a match with it!",
		carpet = "Match on the carpet: it rolls out further!",
		["break:boombox"] = "A match by the boombox pops three more!",
		ice = "Ice melts from matches right next to it!",
		["break:hay"] = "A bonus hides in the hay bale. Take it apart!",
		fog = "Fog hides the pieces. Match next to it!",
	}

	it("says a line for every kind of goal the levels have, on the real tile of the first level that has it", function()
		local first, order = G.first_goal_levels()
		assert_eq(#order, 15, "the kinds the levels have: " .. table.concat(order, ", "))
		for _, what in ipairs(order) do
			local n, k, def = first[what][1], first[what][2], first[what][3]
			G.with_level({ level = n, attempt = false }, function(c)
				c.run(0.8)
				tap_goal(c, k)
				c.step(2)
				local want = SAYS[what]
				if what == "collect" then
					want = i18n.t("piece." .. def.color) .. ": collect " .. ui(c).goals[k] .. " more"
				end
				assert_true(want ~= nil, "no expectation for " .. what)
				assert_eq(ui(c).goal_hint, k, "level " .. n .. " " .. what)
				assert_eq(ui(c).goal_hint_text, want, "level " .. n .. " " .. what)
				assert_true(c.has(want), "level " .. n .. " " .. what .. ": the line is on the screen")
				clean(c)
			end)
		end
	end)

	it("says the lines in Russian and in Korean as well, for the kinds a player meets first", function()
		local RU = { [1] = "Красные медиаторы: собери ещё 30", [15] = "Фиолетовая плитка загорится от матча" }
		local KO = { [1] = "빨간 피크: 30개 더 모아요", [15] = "보라색 타일 위에서 매치하면 금빛으로 켜져요" }
		for lang, texts in pairs({ ru = RU, ko = KO }) do
			for n, want in pairs(texts) do
				G.with_level({ level = n, attempt = false, language = lang }, function(c)
					c.run(0.8)
					tap_goal(c, 1)
					c.step(2)
					assert_eq(ui(c).goal_hint_text, want, lang .. " level " .. n)
					assert_true(c.has(want))
					clean(c)
				end)
			end
		end
	end)
end)
