-- A stand-in for screens/level/board.script in the tests of the level HUD (not a test file itself):
-- a real core game behind client/level_link.lua, which publishes the bus topics the board publishes
-- (client/level_link.lua header) for the events of the core, and takes touches through the same guard
-- hooks as the board. No engine calls: it runs next to the HUD script on the GUI stub.
--
--   local fb = require("tests.client.level_fake_board").new({level = 3, window = {720, 1280}})
--   fb:ready()                 -- level_ready on the bus (link is attached already)
--   fb:advance(dt)             -- the fixed-step loop; the events of the ticks go to the bus
--   fb:run(seconds)
--   fb:tap(x, y), fb:swipe({x, y}, {x2, y2}), fb:send(cmd)   -- core cells; return ok, res
--   fb:settle()                -- ticks until the board is at rest
--   fb:detach()
-- opts: {level = n | text = level JSON, window = {w, h}, insets, params = level_session params,
--        assist, boosters}

local app = require("client.app")
local bus = require("client.bus")
local layout = require("client.layout")
local levels = require("client.levels")
local link = require("client.level_link")
local level_geom = require("client.level_geom")
local level_input = require("client.level_input")
local level_session = require("client.level_session")

local M = {}

local SOURCE_EVENTS = { clear = true, destroy = true, floor_lit = true, mic_delivered = true, transform = true }
local PRAISE_INDEX = { juicy = 1, hit = 2, drive = 3, vibe = 4, legend = 5 }

local FB = {}
FB.__index = FB

function M.new(opts)
	opts = opts or {}
	local params = opts.params
	if not params then
		local info = opts.text and { text = opts.text } or levels.load(opts.level or 1)
		params = { level = opts.level or 1, level_id = opts.level or 1, level_text = opts.text or (info and info.text) }
		if app.meta and app.meta:run() then params.run = app.meta:run() end
		params.run = opts.run or params.run
	end
	local self = setmetatable({ events = {}, t = 0 }, FB)
	local hooks = {
		first_move = function()
			if app.meta and app.meta:run() then
				app.meta:note_move()
				app.commit("first_move")
			end
		end,
		booster_used = function(id)
			if app.meta and app.meta:run() then
				app.meta:use_booster(id)
				app.commit("booster")
			end
		end,
	}
	local s = assert(level_session.new({ params = params, hooks = hooks }))
	self.session = s
	-- what the board tells its input about the cell under a finger (screens/level/board.script)
	local function query(x, y)
		local list = s.game:pieces()
		for i = 1, #list do
			local p = list[i]
			if p.x == x and p.y == y then
				local c = s.game:cells()[(y - 1) * s.W + x]
				return { id = p.id, kind = p.kind, state = p.state, pinned = p.pinned and true or false,
					wired = c ~= nil and (c.wires or 0) > 0 }
			end
		end
		return nil
	end
	self.input = level_input.new({ mode = opts.input_mode or (app.meta and app.meta:settings().input_mode) or "swipe",
		query = query })
	local w, h = (opts.window and opts.window[1]) or 720, (opts.window and opts.window[2]) or 1280
	local fit = layout.fit(w, h)
	local area = layout.play_area(fit, { insets = opts.insets })
	self.geom = level_geom.new(s.W, s.H, s.game:cells(), area)
	self.W, self.H = s.W, s.H
	self.board = {
		session = s, input = self.input, geom = self.geom,
		view = { rev = 1, floor_rev = 0, cells = s.game:cells(), floor0 = {}, lit = {}, deliver = false, shake_x = 0, shake_y = 0,
			W = s.W, H = s.H, geom = self.geom },
		on_booster = function(id, phase) bus.publish("level_booster", { booster = id, phase = phase }) end,
	}
	link.attach(self.board)
	self.on_tick = function(events) self:_events(events) end
	return self
end

function FB:detach()
	link.detach(self.board)
end

function FB:ready()
	local s = self.session
	bus.publish("level_ready", {
		level_id = s.info.level_id, W = s.W, H = s.H, moves = s.data.moves, goals = s.data.goals,
		rect = link.board_rect(), standalone = s.info.standalone,
	})
end

function FB:_events(events)
	local s = self.session
	for i = 1, #events do
		local e = events[i]
		local ty = e.type
		if SOURCE_EVENTS[ty] then self.last_src = e end
		if ty == "moves" then
			bus.publish("level_moves", { left = e.left })
		elseif ty == "goal" then
			local src = self.last_src
			local goal = (s.data.goals or {})[e.index] or {}
			local p = { index = e.index, left = e.left, kind = goal.type, color = goal.color, item = goal.item }
			if src and src.x then
				p.x, p.y = src.x, src.y
				p.lx, p.ly = self.geom:center(src.x, src.y)
			end
			bus.publish("level_goal", p)
		elseif ty == "score" then
			local lx, ly
			if e.x then lx, ly = self.geom:center(e.x, e.y) end
			bus.publish("level_score", { delta = e.delta, total = e.total, lx = lx, ly = ly })
		elseif ty == "state" then
			bus.publish("level_state", { state = e.state, reason = e.reason })
			if e.state ~= "playing" then
				self.input:deselect()
				if e.state ~= "out_of_moves" and self.input.targeting then
					local id = self.input.targeting
					self.input:cancel_target()
					bus.publish("level_booster", { booster = id, phase = "cancel" })
				end
			end
			if e.state == "complete" or e.state == "lost" then
				bus.publish("level_result", { result = s.game:result() })
			end
		elseif ty == "noise_spread" then
			local lx, ly = self.geom:center(e.x, e.y)
			bus.publish("level_noise", { x = e.x, y = e.y, lx = lx, ly = ly })
		elseif ty == "activate" then
			local lx, ly = self.geom:center(e.x, e.y)
			bus.publish("level_special", { special = e.special, combo = e.combo, lx = lx, ly = ly })
		elseif ty == "praise" then
			bus.publish("level_praise", { word = e.word, index = PRAISE_INDEX[e.word], wave = e.wave })
		elseif ty == "booster" then
			bus.publish("level_booster", { booster = e.booster, phase = "done", ok = e.ok })
		end
	end
end

function FB:advance(dt)
	self.t = self.t + dt
	local s = self.session
	if s.auto then s:autoplay_step() end -- the QA "win" command
	s:advance(dt, self.on_tick)
	-- a selection that belongs to a piece that is gone or moving ends (the board does this every frame)
	if self.input.selected then
		self.input:validate(function(id)
			local list = s.game:pieces()
			for i = 1, #list do
				if list[i].id == id then return list[i] end
			end
			return nil
		end, s.game:status().state == "playing")
	end
end

function FB:run(seconds)
	for _ = 1, math.ceil(seconds * 60) do self:advance(1 / 60) end
end

function FB:stable()
	return self.session.game:is_stable()
end

-- ticks until the board is at rest (at most `seconds`)
function FB:settle(seconds)
	for _ = 1, math.ceil((seconds or 20) * 60) do
		self:advance(1 / 60)
		if self:stable() and self.session.game:status().state ~= "won_wait" then return true end
	end
	return false
end

-- what the board does with a command: the guard, the core, the answer to the guard, the bus
function FB:send(cmd)
	if not link.allow_command(cmd) then return false, "guard" end
	local ok, res
	if cmd.type == "swap" then
		local r = self.session.game:can_swap(cmd.from, cmd.to)
		if r == "reject" then return false, "reject" end
	end
	ok, res = self.session:command(cmd)
	link.sent(cmd, ok, res)
	if cmd.type == "booster" then
		if ok then
			self.input:cancel_target()
			bus.publish("level_booster", { booster = cmd.booster, phase = "used" })
		else
			bus.publish("level_booster", { booster = cmd.booster, phase = "rejected", reason = res })
		end
	end
	return ok, res
end

-- a tap on core cell (x, y)
function FB:tap(x, y)
	if not link.allow_cell(x, y) then return false, "guard" end
	self.input:press(x, y)
	local cmd = self.input:release(x, y)
	if cmd then return self:send(cmd) end
	return true, "select"
end

-- a swipe from cell a to the neighbour b
function FB:swipe(a, b)
	if not link.allow_cell(a[1], a[2]) then return false, "guard" end
	self.input:press(a[1], a[2])
	local cmd = self.input:move(a[1] + (b[1] - a[1]) * 0.6, a[2] + (b[2] - a[2]) * 0.6)
	self.input:release(a[1] + (b[1] - a[1]) * 0.6, a[2] + (b[2] - a[2]) * 0.6)
	if cmd then return self:send(cmd) end
	return false, "no swipe"
end

return M
