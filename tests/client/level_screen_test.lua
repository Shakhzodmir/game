-- The level screen (screens/level/level.gui_script with screens/level/hud.lua, tutorial_view.lua and the level
-- windows gui/pause.lua, moves.lua, defeat.lua, result.lua, booster_buy.lua) run on the strict GUI stub
-- (tests/client/town_defold_stub.lua) next to a stand-in for the board (tests/client/level_fake_board.lua, a
-- real core game behind client/level_link.lua): bus events in, nodes and meta changes out. Nothing here
-- decides a rule: the rules are in the meta and the core, which these tests only watch being called.

local G = require("tests.client.level_gui_helper")
local flow = require("client.flow")
local i18n = require("client.i18n")
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

-- the levels before `n` are won on the meta; `keep` leaves their chests waiting, as wins on the board do
local function win_until(n, keep)
	return function(app)
		while app.meta:level_to_play() < n do assert(flow.debug_win(3, keep)) end
	end
end

-- the window host of the level screen
local function popups(c) return c.hud.self.l.popups end

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
	it("draws the level, its goals, the moves, the pause button and the five boosters", function()
		G.with_level({ level = 1 }, function(c)
			local n = 0
			for _, id in ipairs(level_hud.BOOSTERS) do
				assert_true(c.hud.self.l.hud.btns[id] ~= nil, id .. " has its button")
				n = n + 1
			end
			assert_eq(n, 5)
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

	it("keeps the Crossfader locked until level 21, then gives two and shows its count", function()
		G.with_level({ level = 20 }, function(c)
			local b = c.hud.self.l.hud.btns.swap
			assert_true(b.st.mode == "locked")
			tap_booster(c, "swap")
			c.run(0.5)
			assert_eq(c.app.overlay.toast, "Opens at level 21")
			assert_eq(ui(c).targeting, nil)
			clean(c)
		end)
		G.with_level({ level = 21 }, function(c)
			local b = c.hud.self.l.hud.btns.swap
			assert_eq(b.st.mode, "ready")
			assert_eq(b.st.count, 2, "the unlock gift")
			assert_eq(c.app.meta:booster_count("swap"), 2)
			assert_true(c.has("2"))
			clean(c)
		end)
	end)

	it("lays the five buttons out inside the bar, none on top of another", function()
		G.with_level({ level = 21 }, function(c)
			local rects = {}
			for _, id in ipairs(level_hud.BOOSTERS) do rects[#rects + 1] = c.hud.self.l.hud:booster_rect(id) end
			local bar = L.bar
			for i, r in ipairs(rects) do
				assert_true(r.x0 >= bar.x0 and r.x1 <= bar.x1, "button " .. i .. " is in the bar")
				if i > 1 then assert_false(level_hud.overlaps(rects[i - 1], r), "buttons " .. (i - 1) .. " and " .. i) end
			end
			local targets = ui(c).targets
			for _, id in ipairs(level_hud.BOOSTERS) do assert_true(targets[id] ~= nil, "a tap target for " .. id) end
			clean(c)
		end)
	end)

	it("aims the Crossfader with two taps: the bar asks for two pieces, then for the second, and the meta is charged once", function()
		G.with_level({ level = 21 }, function(c)
			local before = c.app.meta:booster_count("swap")
			assert_eq(before, 2)
			tap_booster(c, "swap")
			c.step(3)
			assert_eq(ui(c).targeting, "swap")
			assert_true(c.has("Pick two pieces"))
			assert_true(c.has("Cancel"))
			-- cancelling costs nothing
			c.hud:tap_text("Cancel")
			c.step(3)
			assert_eq(ui(c).targeting, nil)
			assert_eq(c.app.meta:booster_count("swap"), before)
			-- two far pieces of different colours
			local list = c.fb.session.game:pieces()
			local a, b
			for _, p in ipairs(list) do
				if p.kind == "regular" then
					if not a then a = p elseif p.color ~= a.color and not b and math.abs(p.x - a.x) + math.abs(p.y - a.y) >= 3 then b = p end
				end
			end
			assert_true(a and b)
			tap_booster(c, "swap")
			c.step(3)
			assert_true(c.fb:tap(a.x, a.y))
			c.step(3)
			assert_true(c.has("Now the second piece"), "the prompt asks for the second piece")
			assert_false(c.has("Pick two pieces"))
			-- the first piece again lets it go: back to two
			c.fb:tap(a.x, a.y)
			c.step(3)
			assert_true(c.has("Pick two pieces"))
			assert_eq(c.app.meta:booster_count("swap"), before, "nothing was charged")
			c.fb:tap(a.x, a.y)
			c.step(3)
			local ok = c.fb:tap(b.x, b.y)
			assert_true(ok, "the core took the exchange")
			settle(c)
			c.step(20)
			assert_eq(c.app.meta:booster_count("swap"), before - 1, "charged once, when the core took it")
			assert_eq(ui(c).targeting, nil)
			assert_false(c.has("Now the second piece"))
			assert_eq(c.fb.session.game:status().moves_left, c.fb.session.data.moves, "no move is spent")
			clean(c)
		end)
	end)

	it("drops a half-made pick when the pause opens: the mode ends, nothing is charged, the bar is back after it", function()
		G.with_level({ level = 21 }, function(c)
			local before = c.app.meta:booster_count("swap")
			local a
			for _, p in ipairs(c.fb.session.game:pieces()) do
				if p.kind == "regular" then a = p break end
			end
			assert_true(a)
			tap_booster(c, "swap")
			c.step(3)
			assert_true(c.fb:tap(a.x, a.y))
			c.step(3)
			assert_true(c.has("Now the second piece"))
			c.tap(PAUSE[1], PAUSE[2])
			c.step(20)
			assert_eq(top(c), "pause")
			assert_eq(ui(c).targeting, nil, "the target mode ended with the pause")
			assert_eq(c.fb.input.pair, nil, "and the first piece is let go")
			c.tap_target("resume")
			c.step(20)
			assert_eq(top(c), nil)
			assert_false(c.has("Now the second piece"))
			assert_false(c.has("Pick two pieces"))
			assert_eq(c.app.meta:booster_count("swap"), before, "no charge")
			-- the booster is there again, for a fresh start
			tap_booster(c, "swap")
			c.step(3)
			assert_eq(ui(c).targeting, "swap")
			assert_true(c.has("Pick two pieces"))
			-- the other boosters keep their target mode over a pause as before
			c.hud:tap_text("Cancel")
			c.step(3)
			tap_booster(c, "stick")
			c.step(3)
			assert_eq(ui(c).targeting, "stick")
			c.tap(PAUSE[1], PAUSE[2])
			c.step(20)
			assert_eq(ui(c).targeting, "stick", "a one-tap booster is not dropped by the pause")
			c.tap_target("resume")
			c.step(20)
			clean(c)
		end)
	end)

	it("refuses a piece that cannot move and two that are alike, says so, and charges nothing", function()
		local LEVEL = [[{"id": 21, "version": 1, "size": [7, 7], "moves": 20, "difficulty": "easy",
  "colors": ["red", "yellow", "green", "blue"],
  "goals": [{"type": "break", "item": "record_box", "count": 1}, {"type": "collect", "color": "red", "count": 60}],
  "cells": ["#######", "#######", "#######", "#######", "#######", "#######", "#######"],
  "slots": [{"at": [3, 3], "type": "record_box", "hp": 2}]}]]
		G.with_level({ level = 21, level_text = LEVEL }, function(c)
			local before = c.app.meta:booster_count("swap")
			local game = c.fb.session.game
			local box, a, twin
			for _, p in ipairs(game:pieces()) do
				if p.kind == "blocker" then box = p end
			end
			for _, p in ipairs(game:pieces()) do
				if p.kind == "regular" then
					if not a then a = p elseif p.color == a.color and not twin then twin = p end
				end
			end
			assert_true(box and a and twin)
			tap_booster(c, "swap")
			c.step(3)
			c.fb:tap(box.x, box.y)
			c.run(0.5)
			assert_eq(c.app.overlay.toast, "This one can't be moved")
			assert_eq(ui(c).targeting, "swap", "the target mode stays")
			assert_true(c.has("Pick two pieces"), "and nothing is picked")
			c.run(4) -- the toast goes
			c.fb:tap(a.x, a.y)
			c.step(3)
			c.fb:tap(twin.x, twin.y)
			c.run(0.5)
			assert_eq(c.app.overlay.toast, "Pick two different pieces")
			assert_true(c.has("Now the second piece"), "the first piece stays picked")
			assert_eq(c.app.meta:booster_count("swap"), before, "no charge for a refusal")
			assert_eq(game.s.act, 0)
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
			assert_false(c.has("Chest collected!"), "and it is not taken yet")
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

	it("keeps a chest that was not opened when the player leaves the results", function()
		G.with_level({ level = 10 }, function(c)
			win(c)
			local meta = c.app.meta
			c.tap_target("town")
			c.step(10)
			assert_eq(#meta:pending_chests(), 1, "leaving the results does not pay or drop the chest")
			assert_eq(meta:lives(c.app.now()).infinite_seconds, 0)
		end)
	end)

	-- Open, the closed chest, Collect: back on the results window
	local function take_chest(c)
		c.tap_target("chest") -- "Open" of the results window
		c.step(30)
		assert_eq(top(c), "chest", "the chest window shows the chest")
		c.tap_target("chest") -- the closed chest
		c.step(120)
		c.tap_target("collect")
		c.step(20)
	end

	it("offers an older chest in the next results, names its level and pays that very chest", function()
		-- the chest of level 10 was left unopened: the results of level 11 offer it (a claim for the level of the
		-- results themselves would find no chest and pay nothing, for ever)
		G.with_level({ level = 11, setup = win_until(11, true) }, function(c)
			local meta = c.app.meta
			assert_eq(#meta:pending_chests(), 1, "the chest of level 10 waits")
			win(c)
			assert_eq(top(c), "result")
			assert_true(c.has(i18n.t("reward.chest_level", { n = 10 })), "the older chest says which level it is from")
			assert_false(c.has("Chest!"))
			local coins = meta:coins()
			take_chest(c)
			assert_eq(top(c), "result")
			assert_eq(#meta:pending_chests(), 0, "the chest of level 10 was taken")
			assert_eq(meta:coins(), coins + 60)
			assert_true(c.has("Chest collected!"))
			clean(c)
		end)
	end)

	it("pays nothing when the chest window is closed without Collect, and offers the chest again", function()
		G.with_level({ level = 10 }, function(c)
			win(c)
			local meta = c.app.meta
			c.tap_target("chest") -- "Open"
			c.step(30)
			assert_eq(top(c), "chest")
			local coins = meta:coins()
			c.app.close_popup() -- dismissed without Collect
			c.step(40)
			assert_eq(top(c), "result", "back to the results")
			assert_eq(#meta:pending_chests(), 1, "the chest is still waiting")
			assert_eq(meta:coins(), coins)
			assert_eq(meta:lives(c.app.now()).infinite_seconds, 0)
			assert_true(c.has("Open"), "and the strip still offers it")
			assert_false(c.has("Chest collected!"))
			clean(c)
		end)
	end)

	it("pays nothing when the screen goes away while the chest window is open", function()
		G.with_level({ level = 10 }, function(c)
			win(c)
			local meta = c.app.meta
			c.tap_target("chest")
			c.step(30)
			assert_eq(top(c), "chest")
			require("client.bus").publish("screen_leaving", {})
			c.step(10)
			assert_eq(#meta:pending_chests(), 1)
			assert_eq(meta:lives(c.app.now()).infinite_seconds, 0)
		end)
	end)

	it("offers two waiting chests one after the other, oldest first, and stacks their minutes", function()
		G.with_level({ level = 20, setup = win_until(20, true) }, function(c)
			local meta = c.app.meta
			win(c)
			assert_eq(#meta:pending_chests(), 2)
			assert_true(c.has(i18n.t("reward.chest_level", { n = 10 })), "the oldest first")
			take_chest(c)
			assert_eq(#meta:pending_chests(), 1)
			c.run(1.5) -- the chest just taken stays on show for a moment (the next test), then the next is offered
			assert_true(c.has("Open"), "the next chest takes its place")
			assert_true(c.has("Chest!"), "the chest of this level")
			take_chest(c)
			assert_eq(#meta:pending_chests(), 0)
			local left = meta:lives(c.app.now()).infinite_seconds
			assert_true(left > 45 * 60 - 10 and left <= 45 * 60, "15 + 30 minutes: " .. left)
			clean(c)
		end)
	end)

	it("shows the chest just taken for a moment before it offers the next one", function()
		G.with_level({ level = 20, setup = win_until(20, true) }, function(c)
			win(c)
			take_chest(c)
			assert_eq(#c.app.meta:pending_chests(), 1)
			assert_true(c.has("Chest collected!"), "the player sees that Collect worked")
			assert_true(c.has("Unlimited lives are on!"))
			assert_false(c.has("Open"), "the next chest is not offered yet")
			c.run(0.6)
			assert_true(c.has("Chest collected!"), "still on show")
			c.run(0.6)
			assert_false(c.has("Chest collected!"))
			assert_true(c.has("Open"), "the next chest follows")
			clean(c)
		end)
	end)

	it("brings the next chest at a tap while the chest just taken is on show", function()
		G.with_level({ level = 20, setup = win_until(20, true) }, function(c)
			win(c)
			take_chest(c)
			assert_true(c.has("Chest collected!"))
			c.tap_target("taken") -- the tail of the tap on Collect: the window is still deaf
			c.step(5)
			assert_true(c.has("Chest collected!"), "no tap skips it in the first moment")
			c.run(0.3)
			c.tap_target("taken")
			c.step(10)
			assert_false(c.has("Chest collected!"), "a tap brings the next chest")
			assert_true(c.has("Open"))
			assert_eq(top(c), "result")
			clean(c)
		end)
	end)

	it("does not let the second tap of a double tap on Collect fall through to Next level", function()
		-- Collect of the chest window lies at the same place as "Next level" of this tall results window
		G.with_level({ level = 20, setup = win_until(20, true) }, function(c)
			win(c)
			local meta = c.app.meta
			local next_at = c.app.ui.popup_targets.next
			c.tap_target("chest")
			c.step(30)
			c.tap_target("chest")
			c.step(120)
			local collect = c.app.ui.popup_targets.collect
			assert_true(math.abs(collect.x - next_at.x) < 230 and math.abs(collect.y - next_at.y) < 62,
				"Collect lies over Next level in this window (" .. collect.x .. "," .. collect.y .. " vs " .. next_at.x .. "," .. next_at.y .. ")")
			local coins = meta:coins()
			c.tap(collect.x, collect.y) -- Collect
			c.tap(collect.x, collect.y) -- the second tap of the double tap, a few frames later
			c.step(30)
			assert_eq(top(c), "result", "the second tap did not press Next level")
			assert_eq(meta:coins(), coins + 60, "the chest was paid once")
			assert_eq(#meta:pending_chests(), 1)
			-- the window listens again after the moment
			c.step(20)
			c.tap_target("next")
			c.step(30)
			assert_eq(top(c), "start", "Next level answers a tap that comes later")
			clean(c)
		end)
	end)

	it("opens the chest from its whole strip: the picture, the title and the row, and Open is an 88 px target", function()
		G.with_level({ level = 10 }, function(c)
			win(c)
			-- Open: a touch target of at least 88 px (gui/kit.lua), hit off centre too
			local label = c.hud:find("Open")
			assert_true(label ~= nil)
			local x0, y0, x1, y1 = c.E.rect(label.parent)
			local lx0, ly0 = c.E.to_logical(x0, y0)
			local lx1, ly1 = c.E.to_logical(x1, y1)
			assert_true(math.abs(ly1 - ly0) >= 88 - 0.5, "the Open button is " .. math.abs(ly1 - ly0) .. " px high")
			local open = c.app.ui.popup_targets.chest
			local function opens(what, x, y)
				c.tap(x, y)
				c.step(30)
				assert_eq(top(c), "chest", what .. " opens the chest")
				c.app.close_popup()
				c.step(40)
				assert_eq(top(c), "result")
			end
			opens("the Open button", open.x, open.y)
			opens("the top of the Open button", open.x, open.y + 40)
			opens("the bottom of the Open button", open.x, open.y - 40)
			opens("the side of the Open button", open.x + 120, open.y)
			for _, find in ipairs({
				function() return c.hud:find("Chest!") end, -- the title
				function() return c.hud:find("×60") end,    -- the row
			}) do
				local n = find()
				assert_true(n ~= nil)
				local x, y = c.E.centre(n)
				opens("a tap on '" .. n.text .. "'", x, y)
			end
			for _, node in ipairs(c.E.alive_nodes(c.E.scene("/screens/level/level.gui"))) do
				if node.anim == "ui_icons_chest_closed" and c.E.visible(node) then
					local x, y = c.E.centre(node)
					opens("the picture of the chest", x, y)
					break
				end
			end
			-- a tap beside the strip opens nothing
			c.tap(open.x, open.y + 150)
			c.step(30)
			assert_eq(top(c), "result")
			assert_eq(#c.app.meta:pending_chests(), 1, "nothing was paid by any of it")
			clean(c)
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

	it("offers no chest in the stand-in results of a debug level, even when one waits in the meta", function()
		G.with_level({ level = 5, attempt = false, setup = win_until(11, true) }, function(c)
			assert_eq(#c.app.meta:pending_chests(), 1)
			win(c)
			assert_eq(top(c), "result")
			assert_true(c.has("Test level: no reward"))
			assert_false(c.has("Open"), "the chest of the real game is not for a debug level")
			assert_eq(#c.app.meta:pending_chests(), 1)
		end)
	end)

	it("wraps the stars note into its row at a readable size, in English and in Russian", function()
		for _, lang in ipairs({ "en", "ru" }) do
			G.with_level({ level = 3, language = lang }, function(c)
				win(c)
				assert_eq(top(c), "result")
				local note = c.hud:find(i18n.t("win.stars_note"))
				assert_true(note ~= nil, lang .. ": the note is on the results of a one-star win")
				local px = c.E.text_px(note)
				assert_true(px >= 15, lang .. ": the note shrank to " .. string.format("%.1f", px) .. " px instead of wrapping")
				clean(c)
			end)
		end
	end)

	it("draws only the stars the win earned: no empty slot", function()
		G.with_level({ level = 3 }, function(c)
			win(c)
			assert_eq(top(c), "result")
			assert_eq(showing(c, "ui_icons_star_empty"), 0, "an empty star slot is drawn")
			assert_true(showing(c, "ui_icons_star") >= 1)
		end)
	end)
end)

-- The results window is the tallest window of the game: the stars, the coins, the streak, a chest, new boosters,
-- the refund and the buttons add up to more than the screen when they come together, and the title ribbon and Bit
-- (which sit on the top edge of the panel) ran off the top of every window that is not taller than 9:16.
describe("level screen: the results window fits the screen", function()
	-- the shapes the game runs in: the design shape, a short phone, a tall phone (390x844 at 2x), a tablet, the
	-- desktop in landscape, a small phone
	local SIZES = { { 720, 1280 }, { 540, 960 }, { 780, 1688 }, { 768, 1024 }, { 1280, 720 }, { 360, 640 } }
	local MARGIN = 12 -- px of the design area the window keeps free at the top and the bottom

	-- logical rect (y up) of a node under the stub's current window
	local function lrect(c, n)
		local x0, y0, x1, y1 = c.E.rect(n)
		local ax, ay = c.E.to_logical(x0, y0)
		local bx, by = c.E.to_logical(x1, y1)
		return math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by)
	end

	-- the top of the title ribbon and of Bit, and the box of the panel (with its shadow), in logical px
	local function edges(c)
		local ed = {}
		for _, n in ipairs(c.E.alive_nodes(c.E.scene("/screens/level/level.gui"))) do
			local x0, y0, x1, y1 = lrect(c, n)
			if n.anim == "ui_ribbon" then ed.ribbon = math.max(ed.ribbon or -1e9, y1) end
			if n.texture and n.texture:sub(1, 8) == "img:bit/" then ed.bit = math.max(ed.bit or -1e9, y1) end
			if n.texture == "px_round" and math.abs(n.size.x - (640 + 8)) < 1 and (not ed.height or y1 - y0 > ed.height) then
				ed.bottom, ed.left, ed.right, ed.height = y0, x0, x1, y1 - y0
			end
		end
		return ed
	end

	-- the whole window inside the design area, so inside the visible area of every window shape, and its taps with it
	local function check_fits(c, what)
		for _, size in ipairs(SIZES) do
			c.E.set_window(size[1], size[2])
			c.step(3)
			local f = layout.fit(size[1], size[2])
			local at = what .. " in a " .. size[1] .. "x" .. size[2] .. " window"
			local ed = edges(c)
			assert_true(ed.ribbon and ed.bit and ed.bottom, at .. ": the window is drawn")
			assert_true(ed.ribbon <= layout.H - MARGIN and ed.ribbon <= f.y1, at .. ": the title ribbon runs off the top (" .. ed.ribbon .. ")")
			assert_true(ed.bit <= layout.H - MARGIN and ed.bit <= f.y1, at .. ": Bit runs off the top (" .. ed.bit .. ")")
			assert_true(ed.bottom >= MARGIN and ed.bottom >= f.y0, at .. ": the panel runs off the bottom (" .. ed.bottom .. ")")
			assert_true(ed.left >= f.x0 and ed.right <= f.x1 and ed.left >= 0 and ed.right <= layout.W, at .. ": the panel is wider than the screen")
			for name, t in pairs(c.app.ui.popup_targets) do
				assert_true(t.y >= ed.bottom and t.y <= ed.ribbon and t.x >= ed.left and t.x <= ed.right,
					at .. ": the target '" .. name .. "' is outside the window")
			end
		end
	end

	-- level, keep (the earlier chests stay unopened), the strips that make the window as tall as it gets
	local CASES = {
		{ level = 13, keep = true, older = 10, unlock = "row_light" },
		{ level = 20, keep = true, older = 10, unlock = "swap", ru = true },
		{ level = 20, keep = false, unlock = "swap" },
		{ level = 21, keep = true, older = 10, unlock = "disco" },
		{ level = 24, keep = true, older = 10, unlock = "remix" },
		{ level = 30, keep = false, ru = true },
		{ level = 30, keep = true, older = 10 },
	}
	for _, lang in ipairs({ "en", "ru" }) do
		for _, case in ipairs(CASES) do
			if lang == "en" or case.ru then
				local name = "keeps the title and Bit on the screen at level " .. case.level
					.. (case.keep and " with the chest of level 10 unopened" or "") .. " (" .. lang .. ")"
				it(name, function()
					G.with_level({ level = case.level, language = lang, setup = win_until(case.level, case.keep) }, function(c)
						win(c)
						assert_eq(top(c), "result")
						-- the case is the crowded window it claims to be
						assert_true(c.hud:find(i18n.t("win.streak", { n = "" }), true) ~= nil, "the hit streak strip")
						assert_true(c.has("Open") or c.has(i18n.t("win.chest_open")), "the chest strip")
						if case.older then assert_true(c.has(i18n.t("reward.chest_level", { n = case.older })), "the older chest") end
						if case.unlock then
							assert_true(c.has(i18n.t("win.unlocked", { name = i18n.t("booster." .. case.unlock) })), "the new booster strip")
						end
						check_fits(c, "level " .. case.level)
						clean(c)
					end)
				end)
			end
		end
	end

	it("shows the stars note while there is room for it, and leaves it out of a crowded window", function()
		G.with_level({ level = 3 }, function(c)
			win(c)
			assert_true(c.has(i18n.t("win.stars_note")), "an early win explains the stars")
			local e = popups(c):find("result")
			assert_eq(e.fit_k, 1)
			assert_eq(e.fit_dy, 0)
		end)
		G.with_level({ level = 20, setup = win_until(20, true) }, function(c)
			win(c)
			assert_false(c.has(i18n.t("win.stars_note")), "the streak, an older chest and a new booster crowd the window")
			assert_eq(popups(c):find("result").fit_k, 1, "and without the note it needs no shrinking")
		end)
	end)

	it("shrinks a window that is still too tall without the note, and its buttons still answer", function()
		G.with_level({ level = 20, setup = win_until(20, true) }, function(c)
			win(c)
			local e = popups(c):find("result")
			e.params.refund = { riff = 1, sub = 1 } -- boosters the core could not place come back: one more strip
			c.hud:ctx(function() e:rebuild() end)
			c.step(5)
			assert_true(c.hud:find("^Returned to you:", true) ~= nil, "the refund strip")
			assert_true(e.fit_k < 1 and e.fit_k > 0.9, "shrunk by a little: " .. tostring(e.fit_k))
			check_fits(c, "level 20 with the refund strip")
			-- the taps QA and the tests make are where the buttons are drawn
			for target, label in pairs({ next = "Next level", town = "To town", chest = "Open" }) do
				local node = c.hud:find(label)
				assert_true(node ~= nil, label)
				local x, y = c.E.centre(node.parent)
				local t = c.app.ui.popup_targets[target]
				assert_true(math.abs(x - t.x) < 2 and math.abs(y - t.y) < 2,
					"the target '" .. target .. "' (" .. t.x .. "," .. t.y .. ") is not on its button (" .. x .. "," .. y .. ")")
			end
			c.tap_target("chest")
			c.step(30)
			assert_eq(top(c), "chest", "Open answers at its place in the shrunk window")
			c.app.close_popup()
			c.step(40)
			c.tap_target("next")
			c.step(30)
			assert_eq(top(c), "start", "Next level answers too")
			clean(c)
		end)
	end)
end)

-- The window host (client/popups.lua) itself, on windows made up for the test.
describe("level screen: the window host fits tall windows and deafens a window that wakes up", function()
	-- opens a window module of the test in the host of the level screen
	local function open_probe(c, name, mod, params)
		local host = popups(c)
		host.registry[name] = mod
		c.hud:ctx(function() host:open(name, params or {}) end)
		c.run(0.5) -- the window pops in (0.32 s)
		return host:find(name)
	end

	it("puts a tall panel on the screen and keeps its targets and absolute points in step with it", function()
		G.with_level({ level = 3 }, function(c)
			local e = open_probe(c, "tall", { build = function(w)
				w:fit(1500, 100) -- 1500 px of panel and 124 around it do not fit 1280
				w:target("mid", 0, 300)
			end })
			local k, dy = layout.fit_window(1500, 100, 20, 16)
			assert_true(k < 1, "the case needs a window that shrinks")
			assert_near(e.fit_k, k, 1e-9)
			assert_near(e.fit_dy, dy, 1e-9)
			local t = c.app.ui.popup_targets.mid
			assert_near(t.x, 360, 1e-9)
			assert_near(t.y, 640 + dy + k * 300, 1e-9)
			local ax, ay = e:abs(0, 300)
			assert_near(ax, t.x, 1e-9)
			assert_near(ay, t.y, 1e-9)
			-- the content layer is drawn the same way (the stub's window is the design area: no further scale)
			local wx, wy, sx = c.E.world(e.content)
			assert_near(sx, k, 1e-9)
			assert_near(wy, 640 + dy, 1e-9)
			assert_near(e:room(100), layout.window_room(100, 20, 16), 1e-9)
			-- a rebuild fits again from nothing
			c.hud:ctx(function() popups(c):rebuild(e) end)
			assert_near(e.fit_k, k, 1e-9)
			-- a window that never asks to be fitted stays as it is
			local plain = open_probe(c, "plain", { build = function(w) w:target("mid", 0, 300) end })
			assert_eq(plain.fit_k, nil)
			assert_near(c.app.ui.popup_targets.mid.y, 940, 1e-9)
			assert_near(select(2, plain:abs(0, 300)), 940, 1e-9)
		end)
	end)

	it("takes no input for a moment after e:deafen, and listens again afterwards", function()
		G.with_level({ level = 3 }, function(c)
			local hits = 0
			local e = open_probe(c, "deaf", { build = function(w)
				w.ui:button({ parent = w.content, x = 0, y = 0, w = 300, h = 120, on_click = function() hits = hits + 1 end })
				w:target("b", 0, 0)
			end })
			c.tap_target("b")
			assert_eq(hits, 1, "a window that is not deaf answers")
			e:deafen(0.3)
			c.tap_target("b")
			c.step(5)
			assert_eq(hits, 1, "a deaf window ignores the tap")
			c.run(0.4)
			assert_eq(e.deaf, nil)
			c.tap_target("b")
			assert_eq(hits, 2, "and answers again when the moment is over")
			e:deafen()
			assert_near(e.deaf, 0.45, 1e-9, "the default is the host's DEAF")
		end)
	end)

	it("stays deaf while a finger keeps hammering: every swallowed press extends the moment", function()
		G.with_level({ level = 3 }, function(c)
			local hits = 0
			local e = open_probe(c, "hammer", { build = function(w)
				w.ui:button({ parent = w.content, x = 0, y = 0, w = 300, h = 120, on_click = function() hits = hits + 1 end })
				w:target("b", 0, 0)
			end })
			e:deafen(0.3)
			-- a press every 0.2 s for 1.4 s: each one lands before the moment of the previous one is over
			for _ = 1, 7 do
				c.run(0.2)
				c.tap_target("b")
			end
			assert_eq(hits, 0, "the hammering never gets through")
			assert_true(e.deaf ~= nil, "and the window is still deaf")
			c.run(0.3)
			assert_eq(e.deaf, nil, "a quiet moment ends it")
			c.tap_target("b")
			assert_eq(hits, 1, "and the window answers again")
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
