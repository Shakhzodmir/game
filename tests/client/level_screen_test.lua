-- The level screen (screens/level/level.gui_script with screens/level/hud.lua, tutorial_view.lua and the level
-- windows gui/pause.lua, moves.lua, defeat.lua, result.lua, booster_buy.lua) run on the strict GUI stub
-- (tests/client/town_defold_stub.lua) next to a stand-in for the board (tests/client/level_fake_board.lua, a
-- real core game behind client/level_link.lua): bus events in, nodes and meta changes out. Nothing here
-- decides a rule: the rules are in the meta and the core, which these tests only watch being called.

local G = require("tests.client.level_gui_helper")
local layout = require("client.layout")
local level_hud = require("client.level_hud")
local link = require("client.level_link")

local FIT = layout.fit(720, 1280)
local L = level_hud.layout(FIT, nil, nil)
local PAUSE = { L.pause.cx, L.pause.cy }
local BOOSTER_AT = {}
for i, id in ipairs(level_hud.BOOSTERS) do
	BOOSTER_AT[id] = { L.bar.cx + level_hud.bar_slots()[i], L.bar.cy + 2 }
end

-- a level that cannot be won: 7 moves for 60 red pieces
local LOSER = [[{"id": 21, "version": 1, "size": [7, 7], "moves": 7, "difficulty": "easy",
  "colors": ["red", "yellow", "green", "blue", "purple"],
  "goals": [{"type": "collect", "color": "red", "count": 60}, {"type": "collect", "color": "blue", "count": 40}],
  "cells": ["#######", "#######", "#######", "#######", "#######", "#######", "#######"]}]]

-- ticks the board and the GUI until the board is at rest
local function settle(c, seconds)
	for _ = 1, math.ceil((seconds or 40) * 60) do
		c.step(1)
		if c.fb:stable() and c.fb.session.game:status().state ~= "won_wait" then return true end
	end
	return false
end

-- one move of the core's hint; true when the board accepted it
local function hint_move(c)
	local cmd = c.fb.session:hint_command()
	if not cmd then return false end
	local ok = c.fb:send(cmd)
	settle(c)
	return ok
end

-- plays hint moves until `left` moves are left (or the game is over)
local function play_until(c, left)
	for _ = 1, 400 do
		local st = c.fb.session.game:status()
		if st.moves_left <= left or st.state ~= "playing" then return end
		if not hint_move(c) then return end
	end
end

local function out_of_moves(c)
	play_until(c, 0)
	c.step(40)
end

-- wins the level on the board by the QA autoplay; waits for the results window
local function win(c)
	c.fb.session:autoplay(nil, { free_moves = true })
	for _ = 1, 60 * 120 do
		c.step(1)
		if c.popup() == "result" then break end
	end
	c.step(120)
end

local function top(c) return c.popup() end
local function ui(c) return c.app.ui.level end

-- every test ends with these: the script did not trip over itself, and the scene is legal
local function clean(c)
	assert_eq(ui(c).errors, 0, "errors in the HUD code")
	local problems = c.E.audit()
	assert_eq(#problems, 0, table.concat(problems, "\n"))
end

local function tap_booster(c, id) return c.tap(BOOSTER_AT[id][1], BOOSTER_AT[id][2]) end

-- the live text node of the level scene that shows `text`
local function node_with(c, text)
	for _, n in ipairs(c.E.alive_nodes(c.E.scene("/screens/level/level.gui"))) do
		if n.text == text then return n end
	end
	return nil
end

-- how many live nodes of the level scene show this flipbook picture
local function showing(c, anim)
	local n = 0
	for _, node in ipairs(c.E.alive_nodes(c.E.scene("/screens/level/level.gui"))) do
		if node.anim == anim then n = n + 1 end
	end
	return n
end

local function empty_stock(app)
	for _, id in ipairs(level_hud.BOOSTERS) do
		local n = app.meta:booster_count(id)
		if n > 0 then app.meta:_change("test", { { id, -n } }) end
	end
end

describe("level screen: the HUD", function()
	it("draws the level, its goals, the moves, the pause button and the four boosters", function()
		G.with_level({ level = 1 }, function(c)
			assert_true(c.has("Level 1"))
			assert_true(c.has("Moves"))
			assert_true(c.has("20"), "the moves")
			assert_true(c.has("30"), "the goal counter")
			assert_eq(top(c), nil)
			local u = ui(c)
			assert_eq(u.screen, nil)
			assert_eq(u.state, "playing")
			assert_eq(u.moves, 20)
			assert_eq(u.goals[1], 30)
			assert_eq(u.targeting, nil)
			assert_eq(u.ended, false)
			local st = c.hud:stats()
			assert_true(st.peak < 1000, "nodes: " .. st.peak)
			clean(c)
		end)
	end)

	it("shows two and three goals and the difficulty of a hard level", function()
		G.with_level({ level = 24 }, function(c)
			assert_true(c.has("Level 24"))
			assert_true(c.has("Hard"))
			assert_eq(#ui(c).goals, 2)
			clean(c)
		end)
		G.with_level({ level = 60 }, function(c)
			assert_true(c.has("Super Hard"))
			assert_eq(#ui(c).goals, 3)
			clean(c)
		end)
	end)

	it("shows the dance-floor goal as the tile the board starts with (violet, on the gold it turns into), not as a lit one", function()
		G.with_level({ level = 16 }, function(c)
			assert_true(c.has("35"), "the 35 tiles to light")
			assert_eq(showing(c, "ui_icons_goal_floor"), 1, "the goal icon of the unlit tile")
			assert_eq(showing(c, "blockers_floor_lit"), 0, "the lit tile is what the goal turns into, not what it shows")
			clean(c)
		end)
	end)

	it("keeps a goal counter until the collected pieces have flown to its icon, then it matches the core", function()
		G.with_level({ level = 1 }, function(c)
			local seen_gap = false
			for _ = 1, 12 do
				local cmd = c.fb.session:hint_command()
				assert_true(cmd ~= nil)
				c.fb:send(cmd)
				for _ = 1, 40 * 60 do
					c.step(1)
					local left = c.fb.session.game:status().goals[1]
					if ui(c).goals[1] > left then seen_gap = true end
					if c.fb:stable() then break end
				end
				if seen_gap then break end
			end
			assert_true(seen_gap, "the counter waited for the flyer")
			c.run(1.5)
			assert_eq(ui(c).goals[1], c.fb.session.game:status().goals[1])
			assert_true(c.has(tostring(ui(c).goals[1])))
			clean(c)
		end)
	end)

	it("closes a goal with a tick and gives the moves badge its alarm at five moves", function()
		G.with_level({ level = 1 }, function(c)
			local bus = require("client.bus")
			bus.publish("level_moves", { left = 6 })
			c.step(3)
			assert_eq(ui(c).moves, 6)
			assert_eq(ui(c).low, false)
			bus.publish("level_moves", { left = 5 })
			c.step(3)
			assert_eq(ui(c).moves, 5)
			assert_eq(ui(c).low, true)
			bus.publish("level_moves", { left = 7 }) -- a continue: the alarm is over
			c.step(3)
			assert_eq(ui(c).low, false)
			clean(c)
		end)
	end)
end)

describe("level screen: boosters", function()
	it("aims a booster: the bar names the pick and offers Cancel; a tap on the board uses it and the meta is charged", function()
		G.with_level({ level = 9 }, function(c)
			local before = c.app.meta:booster_count("stick")
			assert_true(before > 0)
			tap_booster(c, "stick")
			c.step(3)
			assert_eq(ui(c).targeting, "stick")
			assert_true(c.has("Pick a piece"))
			assert_true(c.has("Cancel"))
			c.hud:tap_text("Cancel")
			c.step(3)
			assert_eq(ui(c).targeting, nil)
			assert_false(c.has("Cancel"))
			assert_eq(c.app.meta:booster_count("stick"), before, "cancelling costs nothing")
			-- aim again and use it
			tap_booster(c, "stick")
			c.step(3)
			local ok = c.fb:tap(3, 3)
			assert_true(ok, "the board took the booster")
			settle(c)
			c.step(20)
			assert_eq(c.app.meta:booster_count("stick"), before - 1)
			assert_eq(ui(c).targeting, nil)
			clean(c)
		end)
	end)

	it("dims what is drawn on a booster button together with its face: the icon and the count follow its alpha", function()
		G.with_level({ level = 9 }, function(c)
			local E = c.E
			local hud = c.hud.self.l.hud
			local b = hud.btns.stick
			assert_eq(E.opacity(b.btn.node), 1)
			assert_eq(E.opacity(b.btn.icon), 1)
			c.hud:ctx(function() hud:set_state("lost") end) -- no booster can be used now
			assert_eq(E.opacity(b.btn.node), 0.5)
			assert_eq(E.opacity(b.btn.icon), 0.5, "the icon is dimmed with the face")
			assert_eq(E.opacity(b.badge), 0.5, "and so is the count")
			assert_eq(E.opacity(b.text), 0.5)
			c.hud:ctx(function() hud:set_state("playing") end)
			assert_eq(E.opacity(b.btn.icon), 1)
			assert_eq(E.opacity(b.badge), 1)
		end)
		-- a locked one: dimmed with its icon, the padlock stays solid
		G.with_level({ level = 3 }, function(c)
			local E = c.E
			local b = c.hud.self.l.hud.btns.stick
			assert_eq(E.opacity(b.btn.node), 0.5)
			assert_eq(E.opacity(b.btn.icon), 0.5)
			assert_eq(E.opacity(b.lock), 1, "the padlock is not dimmed")
		end)
	end)

	it("answers a locked booster with the level it opens at", function()
		G.with_level({ level = 3 }, function(c)
			local info
			for _, b in ipairs(c.app.meta:inventory()) do
				if b.id == "stick" then info = b end
			end
			assert_false(info.unlocked)
			tap_booster(c, "stick")
			c.run(0.5)
			assert_eq(c.app.overlay.toast, "Opens at level " .. info.unlock_level)
			assert_eq(ui(c).targeting, nil)
			assert_eq(top(c), nil)
			clean(c)
		end)
	end)

	it("opens the purchase window for an empty booster and starts the booster after the purchase", function()
		G.with_level({ level = 26, ready = empty_stock }, function(c)
			local coins = c.app.meta:coins()
			tap_booster(c, "stick")
			c.step(30)
			assert_eq(top(c), "booster_buy")
			assert_true(c.has("Pack of 3"))
			assert_true(c.fb.session.paused, "the board stands still behind the window")
			c.tap_target("buy")
			c.step(40)
			assert_eq(top(c), nil)
			assert_true(c.app.meta:coins() < coins, "the pack is paid in coins")
			assert_eq(c.app.meta:booster_count("stick"), 3)
			assert_eq(ui(c).targeting, "stick", "the bought booster starts at once")
			assert_false(c.fb.session.paused)
			clean(c)
		end)
	end)

	it("does not sell a pack for coins the player does not have: the price shakes, the way to the shop is open", function()
		G.with_level({ level = 26, ready = function(app)
			empty_stock(app)
			app.meta:_change("test", { { "coins", -(app.meta:coins() - 10) } })
		end }, function(c)
			tap_booster(c, "stick")
			c.step(30)
			assert_eq(top(c), "booster_buy")
			assert_eq(c.E.opacity(node_with(c, "Pack of 3")), 0.78, "the unaffordable pack is dimmed as a whole")
			c.tap_target("buy")
			c.step(10)
			assert_eq(top(c), "booster_buy")
			assert_eq(c.app.meta:booster_count("stick"), 0)
			assert_eq(c.app.meta:coins(), 10)
			c.tap_target("get_coins")
			c.step(30)
			assert_eq(top(c), "shop")
			clean(c)
		end)
	end)

	it("lets a debug level without an attempt use free boosters", function()
		G.with_level({ level = 5, attempt = false }, function(c)
			assert_eq(c.app.meta:run(), nil)
			tap_booster(c, "stick")
			c.step(3)
			assert_eq(ui(c).targeting, "stick")
			assert_true(c.fb:tap(3, 3))
			settle(c)
			tap_booster(c, "stick")
			c.step(3)
			assert_eq(ui(c).targeting, "stick", "free: there is no stock to run out")
			clean(c)
		end)
	end)
end)

describe("level screen: the pause window", function()
	it("stops the board while it is open and resumes it; the back key opens it too", function()
		G.with_level({ level = 3 }, function(c)
			assert_false(c.fb.session.paused)
			c.tap(PAUSE[1], PAUSE[2])
			c.step(20)
			assert_eq(top(c), "pause")
			assert_true(c.fb.session.paused)
			assert_true(c.has("Paused"))
			c.tap_target("resume")
			c.step(20)
			assert_eq(top(c), nil)
			assert_false(c.fb.session.paused)
			c.E.input(hash("back"), { released = true })
			c.step(20)
			assert_eq(top(c), "pause", "the back key")
			c.E.input(hash("back"), { released = true })
			c.step(20)
			assert_eq(top(c), nil, "the back key closes it again")
			assert_false(c.fb.session.paused)
			clean(c)
		end)
	end)

	it("does not open once the win is certain: leaving the finale would book a loss for a win", function()
		G.with_level({ level = 3 }, function(c)
			local bus = require("client.bus")
			for _, state in ipairs({ "won_wait", "concert", "complete" }) do
				bus.publish("level_state", { state = state })
				c.step(3)
				c.tap(PAUSE[1], PAUSE[2])
				c.step(20)
				assert_eq(top(c), nil, state)
			end
			bus.publish("level_state", { state = "playing" })
			c.step(3)
			c.tap(PAUSE[1], PAUSE[2])
			c.step(20)
			assert_eq(top(c), "pause")
			clean(c)
		end)
	end)

	it("opens the settings of the town on top of itself", function()
		G.with_level({ level = 3 }, function(c)
			c.tap(PAUSE[1], PAUSE[2])
			c.step(20)
			c.tap_target("settings")
			c.step(30)
			assert_eq(top(c), "settings")
			clean(c)
		end)
	end)

	it("leaves before the first move without a loss: the attempt is dropped and the town is next", function()
		G.with_level({ level = 21, hours = 4 }, function(c)
			local lives = c.app.meta:lives(c.app.now()).count
			assert_true(c.app.meta:run() ~= nil)
			c.tap(PAUSE[1], PAUSE[2])
			c.step(20)
			assert_false(c.has("Leave the level?"))
			c.tap_target("leave")
			c.step(20)
			assert_eq(c.app.meta:run(), nil)
			assert_eq(c.app.meta:lives(c.app.now()).count, lives, "no life is lost before the first move")
			assert_true(ui(c).ended)
			c.run(0.5)
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "town")
			clean(c)
		end)
	end)

	it("asks once more before leaving a level that costs a life and a streak, and then books the loss", function()
		G.with_level({ level = 21, hours = 4 }, function(c)
			local meta = c.app.meta
			local lives, streak = meta:lives(c.app.now()).count, meta:streak().count
			assert_true(streak > 0)
			hint_move(c)
			assert_true(meta:run().moved, "the first move is told to the meta")
			c.tap(PAUSE[1], PAUSE[2])
			c.step(20)
			assert_true(c.has("Your hit streak of " .. streak .. " will burn!"), "pause names the streak")
			c.tap_target("leave")
			c.step(20)
			assert_eq(top(c), "confirm")
			c.tap_target("cancel")
			c.step(20)
			assert_eq(top(c), "pause")
			assert_true(meta:run() ~= nil, "staying keeps the attempt")
			c.tap_target("leave")
			c.step(20)
			c.tap_target("confirm")
			c.step(30)
			assert_eq(meta:run(), nil)
			assert_eq(meta:lives(c.app.now()).count, lives - 1)
			assert_eq(meta:streak().count, 0)
			c.run(0.5)
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "town")
			clean(c)
		end)
	end)
end)

describe("level screen: out of moves and defeat", function()
	it("offers +5 moves for coins when the moves run out; paying continues the level", function()
		G.with_level({ level = 21, hours = 4, level_text = LOSER }, function(c)
			out_of_moves(c)
			assert_eq(c.fb.session.game:status().state, "out_of_moves")
			assert_eq(top(c), "moves")
			assert_true(c.has("Out of moves!"))
			assert_true(c.has("+5 moves"))
			assert_true(c.fb.session.paused)
			local meta = c.app.meta
			local coins = meta:coins()
			c.tap_target("continue")
			c.step(40)
			assert_eq(top(c), nil)
			assert_true(meta:coins() < coins, "the offer is paid in coins")
			local st = c.fb.session.game:status()
			assert_eq(st.state, "playing")
			assert_eq(st.moves_left, 5)
			assert_eq(ui(c).moves, 5)
			assert_eq(ui(c).low, true)
			assert_eq(ui(c).state, "playing")
			clean(c)
		end)
	end)

	it("says honestly what giving up costs, and a booster from the stock is another way out", function()
		G.with_level({ level = 21, hours = 4, level_text = LOSER }, function(c)
			out_of_moves(c)
			assert_eq(top(c), "moves")
			assert_true(c.has("You will lose a life."))
			assert_true(c.has("Your hit streak of 9 will burn!"))
			c.tap_target("booster_stick")
			c.step(30)
			assert_eq(top(c), nil)
			assert_eq(ui(c).targeting, "stick")
			assert_eq(ui(c).state, "out_of_moves")
			-- aimed at nothing: the offer is back
			c.hud:tap_text("Cancel")
			c.step(30)
			assert_eq(ui(c).targeting, nil)
			assert_eq(top(c), "moves")
			clean(c)
		end)
	end)

	it("brings the offer back when the booster chosen in it cannot start, with the right words", function()
		G.with_level({ level = 21, hours = 4, level_text = LOSER }, function(c)
			out_of_moves(c)
			assert_eq(top(c), "moves")
			local real = link.booster
			link.booster = function() return false, "not_rest" end -- the board is not at rest after all
			c.tap_target("booster_stick")
			link.booster = real
			c.step(40)
			assert_eq(top(c), "moves", "the offer is back: the player can still buy moves or give up")
			assert_eq(c.app.overlay.toast, "Wait until the board settles")
			assert_eq(ui(c).state, "out_of_moves")
			c.run(4) -- the first toast is gone
			-- a Remix with nothing to shuffle has its own words (it is no spot to pick)
			link.booster = function() return false, "no_candidates" end
			c.tap_target("booster_row_light")
			link.booster = real
			c.step(40)
			assert_eq(top(c), "moves")
			assert_eq(c.app.overlay.toast, "Nothing to shuffle")
			-- and the way on is open: the booster starts the second time
			c.tap_target("booster_stick")
			c.step(30)
			assert_eq(top(c), nil)
			assert_eq(ui(c).targeting, "stick")
			clean(c)
		end)
	end)

	it("does not offer a Remix in the window: it gives no move", function()
		local loser26 = string.gsub(LOSER, '"id": 21', '"id": 26')
		G.with_level({ level = 26, hours = 4, level_text = loser26 }, function(c)
			assert_true(c.app.meta:booster_count("remix") > 0, "a Remix is in stock")
			out_of_moves(c)
			assert_eq(top(c), "moves")
			local targets = c.app.ui.popup_targets
			assert_true(targets.booster_stick ~= nil and targets.booster_row_light ~= nil and targets.booster_col_light ~= nil)
			assert_eq(targets.booster_remix, nil, "a Remix would be spent for nothing")
			clean(c)
		end)
	end)

	it("takes the number of the video's moves from the meta and logs the ad offer once per opening", function()
		local analytics = require("client.services.analytics")
		local config = require("meta.config")
		local was = config.ad_moves
		config.ad_moves = 4
		local ok, err = pcall(function()
			G.with_level({ level = 21, hours = 4, level_text = LOSER, stores = true }, function(c)
				local function offers()
					local n = 0
					for _, e in ipairs(analytics.drain()) do
						if e.name == "ad_offer" then n = n + 1 end
					end
					return n
				end
				analytics.drain()
				out_of_moves(c)
				assert_eq(top(c), "moves")
				assert_true(c.has("+4"), "the label is the meta's number")
				assert_false(c.has("+3"))
				assert_eq(offers(), 1)
				-- the window redraws itself in another language: it is the same offer
				assert_true(c.app.set_setting("language", "ru"))
				c.step(20)
				assert_true(c.has("Ходы кончились!"))
				assert_true(c.has("+4"))
				assert_true(c.app.set_setting("language", "en"))
				c.step(20)
				assert_eq(offers(), 0, "a rebuild of the window is not a new offer")
				clean(c)
			end)
		end)
		config.ad_moves = was
		if not ok then error(err, 0) end
	end)

	it("sells no moves to someone who cannot pay: the price shakes and the shop is one tap away", function()
		G.with_level({ level = 21, hours = 4, level_text = LOSER, ready = function(app)
			app.meta:_change("test", { { "coins", -(app.meta:coins() - 100) } })
		end }, function(c)
			out_of_moves(c)
			assert_eq(top(c), "moves")
			assert_true(c.has("Not enough coins: you have 100"))
			-- the button looks unavailable as a whole: its label and its price are dimmed with the face
			assert_eq(c.E.opacity(node_with(c, "+5 moves")), 0.78)
			assert_eq(c.E.opacity(node_with(c, "700")), 0.78)
			c.tap_target("continue")
			c.step(10)
			assert_eq(top(c), "moves")
			assert_eq(c.app.meta:coins(), 100)
			c.tap_target("get_coins")
			c.step(30)
			assert_eq(top(c), "shop")
			clean(c)
		end)
	end)

	it("draws the window of a stuck board and of an attempt with no offer left, without a price to pay", function()
		G.with_level({ level = 21, hours = 4 }, function(c)
			local lw = require("client.level_windows")
			local ctx = { level_id = 21, t0 = c.app.now() }
			local view = lw.out_of_moves(c.app.meta, { state = "out_of_moves", stuck = true }, c.app.now(),
				{ ads = false, boosters = level_hud.BOOSTERS })
			assert_eq(view.offer, nil, "a stuck board sells no moves")
			c.app.open_popup("moves", { view = view, ctx = ctx })
			c.step(30)
			assert_eq(top(c), "moves")
			assert_true(c.has("No move is left on the board. Use a booster or give up."))
			assert_false(c.has("+5 moves"))
			assert_true(c.has("Give up"))
			clean(c)
			c.app.close_popup()
			c.step(20)
			-- an attempt that has used its offers
			view.stuck = false
			c.app.open_popup("moves", { view = view, ctx = ctx })
			c.step(30)
			assert_true(c.has("No more extra moves for this attempt."))
			assert_false(c.has("+5 moves"))
			clean(c)
		end)
	end)

	it("gives up into the defeat window: the loss is booked by the meta and Bit is sad", function()
		G.with_level({ level = 21, hours = 4, level_text = LOSER }, function(c)
			local meta = c.app.meta
			local lives = meta:lives(c.app.now()).count
			out_of_moves(c)
			c.tap_target("give_up")
			c.step(60)
			assert_eq(top(c), "defeat")
			assert_true(c.has("Level failed"))
			assert_true(c.has("Try again"))
			assert_true(c.has("To town"))
			assert_true(c.has("−1 life"))
			assert_true(c.has("Hit streak lost"))
			assert_eq(meta:run(), nil, "the attempt is closed")
			assert_eq(meta:lives(c.app.now()).count, lives - 1)
			assert_eq(meta:streak().count, 0)
			assert_true(ui(c).ended)
			clean(c)
		end)
	end)

	it("retries in two taps: Try again opens the start window of the same level, Play starts the attempt", function()
		G.with_level({ level = 21, hours = 4, level_text = LOSER }, function(c)
			out_of_moves(c)
			c.tap_target("give_up")
			c.step(60)
			assert_eq(top(c), "defeat")
			c.tap_target("retry")
			c.step(30)
			assert_eq(top(c), "start")
			assert_true(c.has("Level 21"))
			assert_eq(c.app.meta:run(), nil)
			c.hud:tap_text("Play")
			c.step(10)
			assert_true(c.app.meta:run() ~= nil, "the second tap opens the attempt")
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "level")
			local params = c.app.claim(posts[1].message.ticket)
			assert_eq(params.level_id, 21)
			clean(c)
		end)
	end)

	it("goes back to the town from the defeat window, and the town is told about the loss", function()
		G.with_level({ level = 21, hours = 4, level_text = LOSER }, function(c)
			out_of_moves(c)
			c.tap_target("give_up")
			c.step(60)
			c.tap_target("town")
			c.run(1.0)
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "town")
			local rewards = require("client.rewards")
			assert_eq(rewards.count(), 1, "the loss waits in the queue of the town")
			local r = rewards.peek()
			assert_false(r.won)
			assert_true(r.life_lost)
			assert_eq(r.level_id, 21)
			clean(c)
		end)
	end)

	it("plays a debug level through to a stand-in defeat that touches nothing", function()
		G.with_level({ level = 21, attempt = false, level_text = LOSER }, function(c)
			out_of_moves(c)
			assert_eq(top(c), "moves")
			assert_true(c.has("Test level: free"))
			c.tap_target("continue") -- free +5
			c.step(40)
			assert_eq(c.fb.session.game:status().moves_left, 5)
			out_of_moves(c)
			c.tap_target("give_up")
			c.step(60)
			assert_eq(top(c), "defeat")
			assert_false(c.has("−1 life"))
			assert_eq(c.app.meta:run(), nil)
			clean(c)
		end)
	end)
end)

describe("level screen: the results", function()
	it("shows the results of a win and the meta's numbers; Next level and Play are three taps from the win", function()
		G.with_level({ level = 3 }, function(c)
			local meta = c.app.meta
			local coins = meta:coins()
			win(c)
			assert_eq(top(c), "result")
			assert_true(c.has("Level complete!"))
			assert_true(c.has("Next level"))
			assert_true(c.has("To town"))
			assert_eq(meta:run(), nil, "the attempt is closed through the meta")
			assert_eq(meta:level_to_play(), 4)
			local rewards = require("client.rewards")
			assert_eq(rewards.count(), 1, "the win waits in the queue of the town")
			assert_true(rewards.peek().won)
			assert_eq(rewards.peek().level_id, 3)
			assert_true(meta:coins() > coins)
			c.run(2.5) -- the count-up of the coins
			assert_true(c.has("+" .. (meta:coins() - coins)), "the coins of the window are the meta's")
			assert_true(ui(c).ended)
			c.tap_target("next")
			c.step(30)
			assert_eq(top(c), "start")
			assert_true(c.has("Level 4"))
			c.hud:tap_text("Play")
			c.step(10)
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "level")
			assert_eq(c.app.claim(posts[1].message.ticket).level_id, 4)
			assert_true(meta:run() ~= nil)
			clean(c)
		end)
	end)

	it("goes to the town from the results", function()
		G.with_level({ level = 3 }, function(c)
			win(c)
			c.tap_target("town")
			c.run(1.0)
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "town")
			clean(c)
		end)
	end)

	it("shows the chest that comes with level 10 and the progress to it before", function()
		G.with_level({ level = 3 }, function(c)
			win(c)
			assert_true(c.has("Chest in 7 levels"))
			clean(c)
		end)
		G.with_level({ level = 10 }, function(c)
			win(c)
			assert_true(c.has("Chest!"))
			assert_true(c.has("Open"), "the chest is opened right here")
			assert_false(c.has("It opens in the town"))
			clean(c)
		end)
	end)

	it("pays the level chest when the player takes it, and only then starts its unlimited lives", function()
		G.with_level({ level = 10 }, function(c)
			win(c)
			local meta = c.app.meta
			assert_eq(#meta:pending_chests(), 1, "the chest waits in the meta")
			assert_eq(meta:lives(c.app.now()).infinite_seconds, 0, "the win started no unlimited lives")
			assert_false(c.has("Unlimited lives are on!"))
			-- time passes in the window: the time of the chest must not run
			c.E.clock = c.E.clock + 10 * 60
			local coins = meta:coins()
			c.tap_target("chest") -- "Open" of the results window
			c.step(30)
			assert_eq(top(c), "chest", "the chest window shows the chest")
			assert_eq(meta:coins(), coins, "nothing is paid while the chest is closed")
			c.tap_target("chest")  -- the closed chest
			c.step(120)
			assert_eq(meta:coins(), coins, "nothing is paid while the player has not taken it")
			c.tap_target("collect")
			c.step(60)
			assert_eq(top(c), "result", "back to the results window")
			assert_eq(#meta:pending_chests(), 0)
			assert_eq(meta:coins(), coins + 60)
			local left = meta:lives(c.app.now()).infinite_seconds
			assert_true(left > 15 * 60 - 5 and left <= 15 * 60, "the full 15 minutes start at the claim, got " .. left)
			assert_true(c.has("Chest collected!"))
			assert_true(c.has("Unlimited lives are on!"))
			assert_false(c.has("Open"))
			clean(c)
		end)
	end)

	it("keeps a chest that was not opened: the next results offer it again", function()
		G.with_level({ level = 10 }, function(c)
			win(c)
			local meta = c.app.meta
			c.tap_target("town")
			c.step(10)
			assert_eq(#meta:pending_chests(), 1, "leaving the results does not pay or drop the chest")
			assert_eq(meta:lives(c.app.now()).infinite_seconds, 0)
		end)
	end)

	it("gives a debug level stand-in results: no reward and the next level in one tap", function()
		G.with_level({ level = 5, attempt = false }, function(c)
			win(c)
			assert_eq(top(c), "result")
			assert_true(c.has("Test level: no reward"))
			c.tap_target("next")
			c.step(10)
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(#posts, 1)
			assert_eq(posts[1].message.name, "level")
			assert_eq(c.app.claim(posts[1].message.ticket).level, 6)
			clean(c)
		end)
	end)
end)

-- the core's hint of a level at its start, as the 0-based cells of a tutorial step
local function swap_step(level)
	local cmd
	G.with_level({ level = level }, function(c) cmd = c.fb.session:hint_command() end)
	local function zero(p) return { p[1] - 1, p[2] - 1 } end
	return { kind = "swap", from = zero(cmd.from), to = zero(cmd.to), text = "tutorial.swap" }, cmd
end

-- the nodes of the level scene that show this flipbook animation, as {en, color alpha}
local function nodes_with(c, anim)
	local out = {}
	for _, n in ipairs(c.E.dump_scene("/screens/level/level.gui").nodes) do
		if n.anim == anim then out[#out + 1] = n end
	end
	return out
end

describe("level screen: the tutorial", function()
	it("guides the first swap: only that move goes through, the others are turned away and the step is remembered", function()
		local step, cmd = swap_step(1)
		G.with_level({ level = 1, tutorials = { ["1"] = { steps = { step } } } }, function(c)
			assert_eq(ui(c).tutorial.phase, "wait", "the board blooms in first")
			assert_false(c.has("Swap two pieces to make a line of 3"))
			c.run(1.0)
			assert_eq(ui(c).tutorial.phase, "active")
			assert_true(c.has("Swap two pieces to make a line of 3"))
			assert_true(c.has("Skip"))
			assert_eq(#nodes_with(c, "ui_icons_hand"), 1, "the pointing hand")
			local ok, why = c.fb:swipe({ 1, 1 }, { 2, 1 })
			assert_false(ok)
			assert_eq(why, "guard")
			c.step(5)
			assert_eq(ui(c).tutorial.blocked, 1, "the bubble heard the press that was turned away")
			assert_eq(c.fb.session.game:status().moves_left, 20)
			assert_true(c.fb:swipe(cmd.from, cmd.to))
			c.step(5)
			assert_eq(ui(c).tutorial.phase, "sent")
			assert_false(c.app.meta:tutorial_seen("level_1"), "not before it is done")
			settle(c)
			c.run(1.0)
			assert_eq(ui(c).tutorial, nil, "the tutorial is over")
			assert_false(c.has("Swap two pieces to make a line of 3"))
			assert_true(c.app.meta:tutorial_seen("level_1"))
			assert_eq(#nodes_with(c, "ui_icons_hand"), 0)
			-- the board is free now
			local ok2, why2 = c.fb:swipe({ 1, 1 }, { 2, 1 })
			assert_true(why2 ~= "guard")
			clean(c)
		end)
	end)

	it("works with tap and tap again: the first tap picks the piece, the second the neighbour", function()
		local step, cmd = swap_step(1)
		G.with_level({ level = 1, input_mode = "taptap", tutorials = { ["1"] = { steps = { step } } } }, function(c)
			c.run(1.0)
			assert_eq(ui(c).tutorial.phase, "active")
			local other = (cmd.from[1] == 1) and { 5, 5 } or { 1, 1 }
			local ok, why = c.fb:tap(other[1], other[2])
			assert_eq(why, "guard")
			assert_true(c.fb:tap(cmd.from[1], cmd.from[2]))
			assert_true(c.fb:tap(cmd.to[1], cmd.to[2]))
			c.step(5)
			assert_eq(ui(c).tutorial.phase, "sent")
			settle(c)
			c.run(1.0)
			assert_eq(ui(c).tutorial, nil)
			assert_true(c.app.meta:tutorial_seen("level_1"))
			clean(c)
		end)
	end)

	it("hides behind a window and comes back when it closes", function()
		local step = swap_step(1)
		G.with_level({ level = 1, tutorials = { ["1"] = { steps = { step } } } }, function(c)
			c.run(1.0)
			assert_true(c.has("Swap two pieces to make a line of 3"))
			c.tap(PAUSE[1], PAUSE[2])
			c.step(20)
			assert_eq(top(c), "pause")
			assert_false(c.has("Swap two pieces to make a line of 3"))
			c.tap_target("resume")
			c.step(20)
			assert_true(c.has("Swap two pieces to make a line of 3"))
			clean(c)
		end)
	end)

	it("can be skipped: the board is free at once and the tutorial is remembered", function()
		local step = swap_step(1)
		G.with_level({ level = 1, tutorials = { ["1"] = { steps = { step } } } }, function(c)
			c.run(1.0)
			assert_eq(select(2, c.fb:swipe({ 1, 1 }, { 2, 1 })), "guard")
			c.hud:tap_text("Skip")
			c.step(10)
			assert_eq(ui(c).tutorial, nil)
			assert_true(c.app.meta:tutorial_seen("level_1"))
			assert_false(c.has("Swap two pieces to make a line of 3"))
			assert_true(select(2, c.fb:swipe({ 1, 1 }, { 2, 1 })) ~= "guard")
			clean(c)
		end)
	end)

	it("dismisses a tip with a tap that does not reach the board", function()
		G.with_level({ level = 1, tutorials = { ["1"] = { steps = {
			{ kind = "tip", at = { 3, 3 }, text = "tutorial.record_box" },
		} } } }, function(c)
			c.run(1.0)
			assert_eq(ui(c).tutorial.phase, "active")
			assert_true(c.has("Record boxes don't move. Break them!"))
			assert_true(c.has("Tap to continue"))
			assert_eq(#nodes_with(c, "ui_icons_hand"), 1)
			c.run(0.6) -- the guard time of a tip
			local x, y = c.cell(1, 1)
			c.tap(x, y)
			c.step(10)
			assert_eq(ui(c).tutorial, nil)
			assert_true(c.app.meta:tutorial_seen("level_1"))
			assert_eq(c.fb.session.game:status().moves_left, 20, "the tap went to the tutorial, not to the board")
			clean(c)
		end)
	end)

	it("walks through a booster step: the button first, then the target; other boosters are turned away", function()
		G.with_level({ level = 9, tutorials = { ["9"] = { steps = {
			{ kind = "booster", booster = "stick", at = { 2, 2 }, text = "tutorial.booster" },
		} } } }, function(c)
			c.run(1.0)
			assert_eq(ui(c).tutorial.phase, "active")
			assert_true(c.has("Tap a booster, then pick a target"))
			local blocked = ui(c).tutorial.blocked
			tap_booster(c, "row_light")
			c.step(5)
			assert_eq(ui(c).targeting, nil, "another booster is not the lesson")
			assert_true(ui(c).tutorial.blocked > blocked)
			assert_eq(select(2, c.fb:tap(5, 5)), "guard", "no cell before the booster")
			tap_booster(c, "stick")
			c.step(5)
			assert_eq(ui(c).targeting, "stick")
			assert_eq(select(2, c.fb:tap(5, 5)), "guard", "only the cell the lesson points at")
			assert_true(c.fb:tap(3, 3))
			settle(c)
			c.run(1.0)
			assert_eq(ui(c).tutorial, nil)
			assert_true(c.app.meta:tutorial_seen("level_9"))
			clean(c)
		end)
	end)

	it("does not start a tutorial that was seen, and does not break a level that has none", function()
		local step = swap_step(1)
		G.with_level({ level = 1, tutorials = { ["1"] = { steps = { step } } }, setup = function(app)
			app.meta:mark_tutorial_seen("level_1")
		end }, function(c)
			c.run(1.5)
			assert_eq(ui(c).tutorial, nil)
			assert_false(c.has("Swap two pieces to make a line of 3"))
			assert_false(link.guard() ~= nil, "no guard on the board")
			clean(c)
		end)
		G.with_level({ level = 2 }, function(c)
			c.run(1.5)
			assert_eq(ui(c).tutorial, nil)
			clean(c)
		end)
	end)

	it("is remembered as seen when the level is won meanwhile", function()
		local step = swap_step(3)
		G.with_level({ level = 3, tutorials = { ["3"] = { steps = { step } } } }, function(c)
			c.run(1.0)
			assert_eq(ui(c).tutorial.phase, "active")
			win(c)
			assert_eq(top(c), "result")
			assert_true(c.app.meta:tutorial_seen("level_3"))
			assert_eq(ui(c).tutorial, nil)
			clean(c)
		end)
	end)
end)

describe("level screen: languages, window sizes and the QA bridge", function()
	it("redraws in Russian and back when the language changes, also under an open window", function()
		G.with_level({ level = 24 }, function(c)
			assert_true(c.has("Level 24"))
			assert_true(c.app.set_setting("language", "ru"))
			c.step(10)
			assert_true(c.has("Уровень 24"))
			assert_true(c.has("Ходы"))
			assert_true(c.has("Сложный"))
			assert_false(c.has("Moves"))
			c.tap(PAUSE[1], PAUSE[2])
			c.step(20)
			assert_true(c.has("Пауза"))
			assert_true(c.has("Продолжить"))
			assert_true(c.app.set_setting("language", "en"))
			c.step(10)
			assert_eq(top(c), "pause")
			assert_true(c.has("Paused"))
			assert_true(c.has("Resume"))
			clean(c)
		end)
	end)

	it("shows every window in Russian without a glyph the font lacks", function()
		G.with_level({ level = 21, hours = 4, level_text = LOSER, language = "ru" }, function(c)
			c.tap(PAUSE[1], PAUSE[2])
			c.step(20)
			assert_true(c.has("Пауза"))
			clean(c)
			c.tap_target("resume")
			c.step(20)
			out_of_moves(c)
			assert_eq(top(c), "moves")
			assert_true(c.has("Ходы кончились!"))
			clean(c)
			c.tap_target("give_up")
			c.step(60)
			assert_eq(top(c), "defeat")
			assert_true(c.has("Уровень не пройден"))
			clean(c)
		end)
		G.with_level({ level = 10, language = "ru" }, function(c)
			win(c)
			assert_true(c.has("Уровень пройден!"))
			assert_true(c.has("Сундук!"))
			clean(c)
		end)
	end)

	it("keeps the HUD inside the safe area of a tall window with a notch, and follows a resize", function()
		local w, h = 1170, 2532
		local insets = { inset_left = 0, inset_top = 132, inset_right = 0, inset_bottom = 102 }
		G.with_level({ level = 3, window = { w, h }, safe = { left = 0, top = 132, right = 0, bottom = 102 } }, function(c)
			local lay = level_hud.layout(layout.fit(w, h), insets, nil)
			assert_true(lay.goals.y1 <= lay.safe.y1 + 0.5)
			assert_true(lay.bar.y0 >= lay.safe.y0 - 0.5)
			assert_true(lay.safe.y1 < layout.fit(w, h).y1, "the notch takes room at the top")
			c.tap(lay.pause.cx, lay.pause.cy)
			c.step(20)
			assert_eq(top(c), "pause", "the pause button hangs from the safe top")
			c.tap_target("resume")
			c.step(20)
			clean(c)
			-- the window turns into a wide one (the safe area follows)
			c.E.set_window(1920, 1080)
			c.step(10)
			local lay2 = level_hud.layout(layout.fit(1920, 1080), insets, nil)
			c.tap(lay2.pause.cx, lay2.pause.cy)
			c.step(20)
			assert_eq(top(c), "pause", "the HUD followed the new window")
			clean(c)
		end)
	end)

	it("opens and closes a window of the registry on the QA request, and ignores a name it does not know", function()
		G.with_level({ level = 3 }, function(c)
			c.app.open_popup("settings")
			c.step(20)
			assert_eq(top(c), "settings")
			c.app.close_popup()
			c.step(20)
			assert_eq(top(c), nil)
			c.app.open_popup("no_such_window")
			c.step(5)
			assert_eq(top(c), nil)
			c.app.open_popup("start")
			c.step(20)
			assert_eq(top(c), "start", "the start window of the level to play")
			clean(c)
		end)
	end)

	it("closes its windows when the screen is left and lets the board run again", function()
		G.with_level({ level = 3 }, function(c)
			c.tap(PAUSE[1], PAUSE[2])
			c.step(20)
			assert_eq(top(c), "pause")
			require("client.bus").publish("screen_leaving", { name = "town" })
			c.step(30)
			assert_eq(top(c), nil)
			assert_false(c.fb.session.paused)
			clean(c)
		end)
	end)

	it("floats the score of a move up from the cleared pieces", function()
		G.with_level({ level = 1 }, function(c)
			local seen = false
			for _ = 1, 8 do
				local cmd = c.fb.session:hint_command()
				c.fb:send(cmd)
				for _ = 1, 40 * 60 do
					c.step(1)
					if c.hud:find("^%+[%d,]+$", true) then seen = true end
					if c.fb:stable() then break end
				end
				if seen then break end
			end
			assert_true(seen, "a +score text")
			clean(c)
		end)
	end)
end)

describe("level screen: a monkey", function()
	-- random touches on everything: the HUD, the open window and the board, with moves in between
	local function monkey(seed, taps, opts)
		opts = opts or {}
		opts.level = opts.level or 24
		opts.hours = opts.hours or 4
		G.with_level(opts, function(c)
			local state = seed
			local function rnd(n)
				state = (state * 1103515245 + 12345) % 2147483648
				return math.floor(state / 65536) % n + 1
			end
			for i = 1, taps do
				local r = rnd(10)
				local targets = c.app.ui.popup_targets
				if r <= 3 and top(c) and targets then
					local names = {}
					for name in pairs(targets) do names[#names + 1] = name end
					table.sort(names)
					if #names > 0 then c.tap_target(names[rnd(#names)]) end
				elseif r <= 6 then
					c.tap(rnd(720), rnd(1280))
				elseif r <= 8 then
					local cmd = c.fb.session:hint_command()
					if cmd and not top(c) then c.fb:send(cmd) end
				elseif r == 9 then
					c.tap(BOOSTER_AT[level_hud.BOOSTERS[rnd(4)]][1], BOOSTER_AT.stick[2])
				else
					c.tap(PAUSE[1], PAUSE[2])
				end
				c.step(rnd(40))
				assert_eq(ui(c).errors, 0, "tap " .. i)
			end
			c.run(2)
			clean(c)
			local st = c.hud:stats()
			assert_true(st.peak < 1800, "nodes at their peak: " .. st.peak)
		end)
	end

	it("survives random touches on a level with a tutorial", function()
		for seed = 1, 3 do monkey(seed, 120, { level = 9 }) end
	end)

	it("survives random touches on a level that cannot be won", function()
		for seed = 4, 6 do monkey(seed, 120, { level = 21, level_text = LOSER }) end
	end)

	it("survives random touches on a debug level without an attempt", function()
		monkey(7, 120, { level = 5, attempt = false })
	end)
end)

describe("level screen: pictures", function()
	it("has every picture its code names, so no soft disc stands in for an icon", function()
		local assets = require("client.assets")
		local files = {
			"gui/pause.lua", "gui/moves.lua", "gui/defeat.lua", "gui/result.lua", "gui/booster_buy.lua", "gui/level_kit.lua",
			"screens/level/hud.lua", "screens/level/tutorial_view.lua", "screens/level/level.gui_script",
			"client/level_windows.lua", "client/level_hud.lua", "client/level_bit.lua",
		}
		local missing, seen = {}, 0
		for _, f in ipairs(files) do
			local fh = assert(io.open(f, "r"))
			local src = fh:read("*a")
			fh:close()
			for key in string.gmatch(src, '"((%a+)/[%w_/]*[%w_])"') do
				local ns = string.match(key, "^(%a+)/")
				if ns == "ui" or ns == "bit" or ns == "specials" or ns == "pieces" then
					seen = seen + 1
					if not assets.has_image(key) then missing[#missing + 1] = f .. ": " .. key end
				end
			end
		end
		assert_true(seen > 30, "found the pictures: " .. seen)
		assert_same(missing, {})
	end)
end)

describe("level screen: QA requests for windows that need the game", function()
	it("makes up what a request leaves out, and refuses what cannot be made up", function()
		G.with_level({ level = 26 }, function(c)
			c.app.open_popup("booster_buy")
			c.step(30)
			assert_eq(top(c), "booster_buy")
			c.app.close_popup()
			c.step(20)
			c.app.open_popup("result")
			c.app.open_popup("defeat")
			c.step(20)
			assert_eq(top(c), nil, "no results without a result")
			c.app.open_popup("pause")
			c.step(20)
			assert_eq(top(c), "pause")
			c.app.close_popup()
			c.step(20)
			clean(c)
		end)
		G.with_level({ level = 21, hours = 4, level_text = LOSER }, function(c)
			out_of_moves(c)
			assert_eq(top(c), "moves")
			c.app.close_popup()
			c.step(20)
			c.app.open_popup("moves") -- no view given: the game's own
			c.step(30)
			assert_eq(top(c), "moves")
			assert_true(c.has("+5 moves"))
			clean(c)
		end)
	end)
end)
