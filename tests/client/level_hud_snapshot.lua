-- A picture of the level HUD and its windows without Defold: runs screens/level/level.gui_script on the strict
-- GUI stub (tests/client/town_defold_stub.lua) with a stand-in board (tests/client/level_fake_board.lua) and
-- writes the nodes of a scenario to a JSON file; tests/client/gui_snapshot.py draws it (the board itself is
-- not drawn: only what the HUD scripts hand to the engine).
--
--   lua5.1 tests/client/level_hud_snapshot.lua <scenario> <out.json> [language = en] [WxH = 720x1280] [seconds = 1.5]
--   python3 tests/client/gui_snapshot.py <out.json> <out.png> [scale = 0.75]
--
-- Run from the repository root. Scenarios:
--   hud (level 1), hud_two (level 3), hud_three (level 60, super hard), hud_hard (level 24), hud_low (3 moves left),
--   hud_target (a drumstick being aimed), hud_locked, hud_empty (stock 0: the "+"), hud_free (a debug level)
--   pause, pause_loss (after a move on level 21 with a streak), pause_free (after a move on level 3)
--   moves, moves_poor (not enough coins), moves_stuck, defeat, result (level 3), result_chest (level 10),
--   result_streak (level 14), result_last (level 100), buy (the "+" of an empty booster)
--   tutorial_swap, tutorial_tip, tutorial_booster, tutorial_taptap

package.path = "./?.lua;./?/init.lua;" .. package.path
local G = require("tests.client.level_gui_helper")
local json = require("tools.lib.json")
local link = require("client.level_link")
local bus = require("client.bus")

local scenario, outpath = arg[1], arg[2]
if not (scenario and outpath) then
	print("usage: lua5.1 tests/client/level_hud_snapshot.lua <scenario> <out.json> [language] [WxH] [seconds]")
	os.exit(1)
end
local language = arg[3] or "en"
local w, h = string.match(arg[4] or "720x1280", "^(%d+)x(%d+)$")
w, h = tonumber(w) or 720, tonumber(h) or 1280
local seconds = tonumber(arg[5]) or 1.5

-- plays hint moves until `left` moves are left
local function play_until(c, left)
	for _ = 1, 400 do
		local st = c.fb.session.game:status()
		if st.moves_left <= left or st.state ~= "playing" then return end
		local cmd = c.fb.session:hint_command()
		if not cmd then return end
		c.fb:send(cmd)
		c.fb:settle(30)
		c.step(2)
	end
end

local function one_move(c) play_until(c, c.fb.session.game:status().moves_left - 1) end

local function win(c)
	c.fb.session:autoplay(nil, { free_moves = true })
	for _ = 1, 60 * 90 do
		c.step(1)
		if c.app.ui.popup == "result" then break end
	end
	c.step(240)
end

local function empty_stock(app)
	for _, id in ipairs({ "stick", "row_light", "col_light", "remix" }) do
		local n = app.meta:booster_count(id)
		if n > 0 then app.meta:_change("snapshot", { { id, -n } }) end
	end
end

local CASES = {}
local function case(name, c) CASES[name] = c end

-- a level that cannot be won: 7 moves for 60 red pieces
local LOSER = [[{"id": 21, "version": 1, "size": [7, 7], "moves": 7, "difficulty": "easy",
  "colors": ["red", "yellow", "green", "blue", "purple"],
  "goals": [{"type": "collect", "color": "red", "count": 60}, {"type": "collect", "color": "blue", "count": 40}],
  "cells": ["#######", "#######", "#######", "#######", "#######", "#######", "#######"]}]]

local function run_out(c)
	play_until(c, 0)
	c.fb:settle(30)
	c.step(60)
end

case("hud", { level = 1 })
case("hud_two", { level = 3 })
case("hud_three", { level = 60 })
case("hud_hard", { level = 24 })
case("hud_low", { level = 24, run = function(c) play_until(c, 3) end })
case("hud_target", { level = 9, run = function(c) assert(link.booster("stick")) end })
case("hud_locked", { level = 3 })
case("hud_empty", { level = 26, ready = empty_stock })
case("hud_free", { level = 5, attempt = false })
case("pause", { level = 21, hours = 4, run = function(c) c.tap(62, 1170) end })
case("pause_loss", { level = 21, hours = 4, run = function(c) one_move(c); c.tap(62, 1170) end })
case("pause_free", { level = 3, run = function(c) one_move(c); c.tap(62, 1170) end })
case("moves", { level = 21, hours = 4, level_text = LOSER, run = run_out })
case("moves_poor", { level = 21, hours = 4, level_text = LOSER, ready = function(app)
	app.meta:_change("snapshot", { { "coins", -(app.meta:coins() - 120) } })
end, run = run_out })
case("defeat", { level = 21, hours = 4, level_text = LOSER, run = function(c)
	run_out(c)
	c.tap_target("give_up")
	c.step(90)
end })
case("result", { level = 3, run = win })
case("result_chest", { level = 10, run = win })
case("result_streak", { level = 14, run = win })
-- the last level: the file of level 1 under another number (the shipped files may not reach 100 yet)
local function level_one_as(n)
	local f = assert(io.open("content/levels/level_0001.json", "r"))
	local text = f:read("*a")
	f:close()
	return (string.gsub(text, '"id": 1,', '"id": ' .. n .. ','))
end
case("result_last", { level = 100, level_text = level_one_as(100), run = win })
case("buy", { level = 26, ready = empty_stock, run = function(c) c.tap(110, 72) end })
local SWAP = { ["1"] = { steps = { { kind = "swap", from = { 3, 0 }, to = { 3, 1 }, text = "tutorial.swap" } } } }
case("tutorial_swap", { level = 1, tutorials = SWAP, run = function(c) c.run(1.2) end })
case("tutorial_taptap", { level = 1, tutorials = SWAP, input_mode = "taptap", run = function(c) c.run(1.6) end })
case("tutorial_tip", { level = 1, run = function(c) c.run(1.2) end,
	tutorials = { ["1"] = { steps = { { kind = "tip", at = { 3, 3 }, text = "tutorial.record_box" } } } } })
case("tutorial_booster", { level = 9, run = function(c) c.run(1.2) end,
	tutorials = { ["9"] = { steps = { { kind = "booster", booster = "stick", at = { 2, 2 }, text = "tutorial.booster" } } } } })

local cfg = CASES[scenario]
if not cfg then
	print("unknown scenario " .. scenario)
	os.exit(1)
end
cfg.window, cfg.language = { w, h }, language

local out
G.with_level(cfg, function(c)
	if cfg.run then cfg.run(c) end
	c.run(seconds)
	out = { scenario = scenario, language = language, window = { w = w, h = h }, scenes = {}, problems = c.E.audit() }
	for _, path in ipairs({ "/screens/level/level.gui", "/main/overlay.gui" }) do out.scenes[#out.scenes + 1] = c.E.dump_scene(path) end
end)
local f = assert(io.open(outpath, "w"))
f:write(json.encode(out))
f:close()
for _, p in ipairs(out.problems) do print("AUDIT " .. p) end
