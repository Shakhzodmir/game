local link = require("client.level_link")
local level_session = require("client.level_session")
local level_input = require("client.level_input")
local level_geom = require("client.level_geom")
local qa = require("client.qa_bridge")

local LEVEL = [[{
  "id": 4, "version": 1, "size": [6, 6], "moves": 9, "difficulty": "hard",
  "colors": ["red", "yellow", "green", "blue"],
  "goals": [{"type": "collect", "color": "green", "count": 5}],
  "cells": ["######", "######", "######", "######", "######", "######"]
}]]

describe("client.level_link", function()
	it("gives the HUD the board without the Defold side", function()
		assert_false(link.active())
		assert_false((link.booster("stick")))
		local s = assert(level_session.new({ params = { level = 4, level_text = LEVEL } }))
		local events = {}
		local board = {
			session = s, input = level_input.new(),
			geom = level_geom.new(6, 6, s.game:cells(), { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 }),
			on_booster = function(id, phase) events[#events + 1] = id .. ":" .. phase end,
		}
		link.attach(board)
		assert_true(link.active())
		assert_eq(link.info().moves, 9)
		assert_eq(link.info().difficulty, "hard")
		assert_eq(link.status().moves_left, 9)
		assert_true(link.booster("row_light"))
		assert_eq(link.targeting(), "row_light")
		assert_true(link.cancel_booster())
		assert_eq(link.targeting(), nil)
		assert_same(events, { "row_light:target", "row_light:cancel" })
		local ok, why = link.booster("fly")
		assert_false(ok)
		assert_eq(why, "bad_booster")
		assert_true(link.booster("remix")) -- at once through the core
		assert_true(link.pause(true))
		assert_true(s.paused)
		link.pause(false)
		local lx, ly = link.cell_center(1, 1)
		assert_true(lx > 0 and ly > 200)
		assert_eq(link.board_rect().cell, board.geom.cell)
		local ok2, res = link.skip()
		assert_false(ok2)
		assert_eq(res, "bad_state")
		link.detach({})
		assert_true(link.active()) -- only its own board detaches
		link.detach(board)
		assert_false(link.active())
	end)
end)

describe("client.qa_bridge (screen commands)", function()
	it("lets a screen add commands and chain to the app's handler", function()
		local window = {}
		local function run_js(code)
			if code == qa.READ_JS then
				local c = window.cmd
				window.cmd = nil
				return c or ""
			end
			window.last = code
			return ""
		end
		qa.init({ enabled = true, run_js = run_js, encode = function(t) return t end,
			handlers = { state = function() return { ok = true, loads = 3 } end } })
		local off = qa.register({
			state = function(args, cmd, prev)
				local r = prev and prev(args, cmd) or {}
				r.level = { moves = 7 }
				return r
			end,
			hint_move = function() return { ok = true, moved = true } end,
		})
		local r = qa.execute("state")
		assert_eq(r.loads, 3)
		assert_eq(r.level.moves, 7)
		assert_true(qa.execute("hint_move").moved)
		off()
		r = qa.execute("state")
		assert_eq(r.level, nil)
		r = qa.execute("hint_move")
		assert_false(r.ok)
		assert_true(string.find(r.error, "not_implemented", 1, true) ~= nil)
		qa.init({})
	end)
end)
