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
		-- the same table while the board stays, a new one when it moved
		local r1 = link.board_rect()
		assert_true(link.board_rect() == r1, "no garbage per frame")
		local was = board.geom.rect.x0
		board.geom.rect.x0 = was + 1
		local r2 = link.board_rect()
		assert_true(r2 ~= r1 and r2.x0 == was + 1)
		board.geom.rect.x0 = was
		assert_eq(link.board_rect().x0, was)
		local ok2, res = link.skip()
		assert_false(ok2)
		assert_eq(res, "bad_state")
		link.detach({})
		assert_true(link.active()) -- only its own board detaches
		link.detach(board)
		assert_false(link.active())
	end)
end)

describe("client.level_link guard and queries", function()
	local function with_board(fn)
		local s = assert(level_session.new({ params = { level = 4, level_text = LEVEL } }))
		local board = {
			session = s, input = level_input.new(),
			geom = level_geom.new(6, 6, s.game:cells(), { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 }),
		}
		link.attach(board)
		local ok, err = pcall(fn, s, board)
		link.clear_guard()
		link.on_guard_error = nil
		link.detach(board)
		if not ok then error(err, 0) end
	end

	it("lets everything through while no guard is set", function()
		assert_true(link.allow_cell(1, 1))
		assert_true(link.allow_command({ type = "swap" }))
		assert_true(link.allow_booster("stick"))
		local cmd = { type = "swap", from = { 1, 1 }, to = { 2, 1 } }
		assert_eq(link.hint(cmd), cmd)
		link.sent(cmd, true, "ok") -- nobody listens: no error
		assert_eq(link.guard(), nil)
	end)

	it("asks the guard and lets a missing function pass", function()
		local seen = {}
		link.set_guard({
			cell = function(x, y) seen[#seen + 1] = "cell " .. x .. "," .. y; return x == 2 end,
			command = function(cmd) seen[#seen + 1] = "cmd " .. cmd.type; return cmd.type == "tap" end,
			hint = function(cmd) return nil end,
			sent = function(cmd, ok, res) seen[#seen + 1] = "sent " .. tostring(ok) .. " " .. tostring(res) end,
		})
		assert_true(link.allow_cell(2, 5))
		assert_false(link.allow_cell(3, 5))
		assert_true(link.allow_command({ type = "tap" }))
		assert_false(link.allow_command({ type = "swap" }))
		assert_true(link.allow_booster("stick")) -- no booster function: allowed
		assert_eq(link.hint({ type = "swap" }), nil) -- the guard hides the hint
		link.sent({ type = "tap" }, true, "ok")
		assert_same(seen, { "cell 2,5", "cell 3,5", "cmd tap", "cmd swap", "sent true ok" })
		link.clear_guard()
		assert_true(link.allow_cell(3, 5))
	end)

	it("drops a guard that raises an error instead of trapping the player", function()
		local why
		link.on_guard_error = function(name, err) why = name .. ": " .. tostring(err) end
		link.set_guard({ cell = function() error("boom") end })
		assert_true(link.allow_cell(1, 1)) -- fails open
		assert_true(string.find(why, "cell", 1, true) ~= nil and string.find(why, "boom", 1, true) ~= nil)
		assert_eq(link.guard(), nil)
		link.on_guard_error = nil
	end)

	it("tells the tutorial what the board holds", function()
		with_board(function(s)
			assert_true(link.stable())
			local p = link.piece(1, 1)
			assert_eq(p.kind, "regular")
			assert_eq(p.state, "idle")
			assert_false(p.pinned)
			assert_eq(link.piece(9, 9), nil)
			assert_same(link.specials(), {})
			local h = link.core_hint()
			assert_true(h ~= nil)
			if h.from then
				assert_eq(link.can_swap(h.from, h.to), "ok")
			end
			assert_eq(link.can_swap({ 1, 1 }, { 1, 1 }) ~= "ok", true)
		end)
		assert_eq(link.can_swap({ 1, 1 }, { 2, 1 }), nil) -- no board
		assert_false(link.stable())
		assert_eq(link.piece(1, 1), nil)
		assert_same(link.specials(), {})
		assert_eq(link.core_hint(), nil)
	end)

	it("tells the guard about the remix it applied", function()
		with_board(function(s)
			local sent = {}
			link.set_guard({ sent = function(cmd, ok, res) sent[#sent + 1] = cmd.booster .. ":" .. tostring(ok) end })
			assert_true(link.booster("remix"))
			assert_same(sent, { "remix:true" })
		end)
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
