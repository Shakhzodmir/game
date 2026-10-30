-- The tutorial's guard (client/level_link.lua) as screens/level/board.script uses it: the real board script on the
-- strict Defold stub (tests/client/level_defold_stub.lua), a real core game and real touches. The hooks of the
-- board are four calls (sent / allow_command / hint / allow_cell); these tests keep them honest.

local stub = require("tests.client.level_defold_stub")
local app = require("client.app")
local bus = require("client.bus")
local layout = require("client.layout")
local link = require("client.level_link")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local H = require("tests.meta.helper")

local DT = 1 / 60

-- Runs fn(script, self, d) with the board of level 1 on display; the guard is cleared afterwards.
local function with_board(fn)
	local E = stub.install({})
	local ok, err = pcall(function()
		analytics.init({ strict = true })
		app.init({
			districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
			now = H.T0, clock = function() return H.T0 end, sys_language = "en",
		})
		app.params = { level = 1 }
		local script = stub.load_script("screens/level/board.script")
		local self = {}
		script.init(self)
		assert_true(not self.failed, "the board failed to start")
		self.strict = true
		local d = {}
		function d.frame(n)
			for _ = 1, n or 1 do
				E.advance(DT)
				script.update(self, DT)
			end
		end
		function d.touch(kind, lx, ly)
			local f = layout.fit(E.window.w, E.window.h)
			local sx, sy = layout.logical_to_screen(f, lx, ly)
			return script.on_input(self, hash("touch"), { screen_x = sx, screen_y = sy, x = sx, y = sy,
				pressed = kind == "down", released = kind == "up" })
		end
		function d.swipe(ax, ay, bx, by)
			local lx, ly = self.geom:center(ax, ay)
			local c = self.geom.cell
			d.touch("down", lx, ly)
			d.frame(1)
			d.touch("move", lx + (bx - ax) * c * 0.45, ly - (by - ay) * c * 0.45)
			d.frame(1)
			d.touch("up", lx + (bx - ax) * c * 0.45, ly - (by - ay) * c * 0.45)
			d.frame(1)
		end
		function d.tap(x, y)
			local lx, ly = self.geom:center(x, y)
			d.touch("down", lx, ly)
			d.frame(1)
			d.touch("up", lx, ly)
			d.frame(1)
		end
		d.frame(3)
		local ok2, err2 = pcall(fn, script, self, d)
		pcall(script.final, self)
		link.clear_guard()
		link.on_guard_error = nil
		if not ok2 then error(err2, 0) end
	end)
	stub.restore()
	if not ok then error(err, 0) end
end

local function moves_left(self) return self.session.game:status().moves_left end

describe("screens/level/board.script with a guard on the link", function()
	it("takes no touch while the guard turns every press away", function()
		with_board(function(script, self, d)
			local presses = 0
			link.set_guard({ cell = function() presses = presses + 1 return false end })
			local cmd = self.session:hint_command()
			d.swipe(cmd.from[1], cmd.from[2], cmd.to[1], cmd.to[2])
			d.tap(cmd.from[1], cmd.from[2])
			d.frame(30)
			assert_true(presses >= 2, "the guard was asked once per press: " .. presses)
			assert_eq(moves_left(self), 20)
			assert_eq(self.input.selected, nil)
		end)
	end)

	it("lets the guided swap through, tells the guard what the core answered and turns the others away", function()
		with_board(function(script, self, d)
			local cmd = self.session:hint_command()
			local answers = {}
			local function same(a, b) return a[1] == b[1] and a[2] == b[2] end
			link.set_guard({
				cell = function(x, y) return same({ x, y }, cmd.from) or same({ x, y }, cmd.to) end,
				command = function(c) return c.type == "swap" and same(c.from, cmd.from) and same(c.to, cmd.to) end,
				sent = function(c, ok, res) answers[#answers + 1] = { cmd = c, ok = ok, res = res } end,
			})
			-- another swap: the press is turned away at once
			local other = (cmd.from[1] > 2) and { 1, 1 } or { 6, 6 }
			d.swipe(other[1], other[2], other[1] + 1, other[2])
			d.frame(30)
			assert_eq(moves_left(self), 20)
			assert_eq(#answers, 0)
			-- the guided one goes
			d.swipe(cmd.from[1], cmd.from[2], cmd.to[1], cmd.to[2])
			d.frame(30)
			assert_eq(moves_left(self), 19)
			assert_eq(#answers, 1)
			assert_true(answers[1].ok)
			assert_eq(answers[1].cmd.type, "swap")
		end)
	end)

	it("stops a command the guard refuses even when the press itself was let through", function()
		with_board(function(script, self, d)
			local cmd = self.session:hint_command()
			local asked = {}
			link.set_guard({ command = function(c) asked[#asked + 1] = c.type return false end })
			d.swipe(cmd.from[1], cmd.from[2], cmd.to[1], cmd.to[2])
			d.frame(30)
			assert_eq(#asked, 1)
			assert_eq(moves_left(self), 20, "the board did not send it")
		end)
	end)

	it("shows the hint the guard makes of the core's own pick", function()
		with_board(function(script, self, d)
			local mine = { from = { 1, 1 }, to = { 2, 1 } }
			local given
			link.set_guard({ hint = function(c) given = c return mine end })
			d.frame(60 * 7) -- the idle time of the hint
			assert_true(given ~= nil, "the guard saw the core's hint")
			assert_eq(given.type, "swap")
			assert_same(self.hint_cmd.from, mine.from)
			assert_same(self.hint_cmd.to, mine.to)
		end)
	end)

	it("drops a guard that raises an error and carries on as if there were none", function()
		with_board(function(script, self, d)
			local failed
			link.on_guard_error = function(name, err) failed = name end
			link.set_guard({ cell = function() error("boom") end })
			local cmd = self.session:hint_command()
			d.swipe(cmd.from[1], cmd.from[2], cmd.to[1], cmd.to[2])
			d.frame(30)
			assert_eq(failed, "cell")
			assert_eq(link.guard(), nil)
			assert_eq(moves_left(self), 19, "the swipe went through: nobody is trapped")
		end)
	end)

	it("runs with no guard at all as before", function()
		with_board(function(script, self, d)
			assert_eq(link.guard(), nil)
			local cmd = self.session:hint_command()
			d.swipe(cmd.from[1], cmd.from[2], cmd.to[1], cmd.to[2])
			d.frame(30)
			assert_eq(moves_left(self), 19)
		end)
	end)
end)
