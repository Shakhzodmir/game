-- What the town plays, one step after another: a task being built, the
-- rewards brought back from a level, the district concert, a chest, the
-- next district sliding in. A step waits until no popup is open, runs, and
-- calls done() when it is over; a tap skips a skippable step to its end
-- state at once (its effects vanish with fx:clear()).
--
--   local show = require("screens.town.show").new(town)  -- town.popups, town.fx
--   show:push({name = "task", skippable = true,
--              run = function(done) ... done() end,   -- start the animation
--              finish = function() ... end,           -- the end state at once (skip)
--              after = function() ... end})           -- after either of them
--   show:update()       every frame
--   show:skip()         a tap: true when a step was skipped
-- Pure Lua (tests drive it with a fake town).

local M = {}

local Show = {}
Show.__index = Show

function M.new(town)
	return setmetatable({ town = town, queue = {}, cur = nil, token = 0, started = 0 }, Show)
end

function Show:push(step)
	self.queue[#self.queue + 1] = step
end

-- A step to play before everything queued (inside another step's flow).
function Show:front(step)
	table.insert(self.queue, 1, step)
end

function Show:busy()
	return self.cur ~= nil or #self.queue > 0
end

function Show:skippable()
	return self.cur ~= nil and self.cur.skippable == true
end

function Show:name()
	return self.cur and self.cur.name or nil
end

function Show:count()
	return #self.queue + (self.cur and 1 or 0)
end

local function finish(self, step)
	if self.cur ~= step then return end
	self.cur = nil
	if step.after then step.after() end
end

function Show:update()
	if self.cur or #self.queue == 0 or self.town.leaving then return end
	if self.town.popups and self.town.popups:count() > 0 then return end
	local step = table.remove(self.queue, 1)
	self.cur = step
	self.token = self.token + 1
	self.started = self.started + 1
	local token = self.token
	step.run(function()
		if self.token == token then finish(self, step) end
	end)
end

-- Skips the running step to its end state. true when one was skipped.
function Show:skip()
	local step = self.cur
	if not step or not step.skippable then return false end
	self.token = self.token + 1 -- a late done() of the step is ignored
	if self.town.fx then self.town.fx:clear() end
	if step.finish then step.finish() end
	finish(self, step)
	return true
end

-- Forgets everything (the screen goes away, a save reset).
function Show:clear()
	self.queue = {}
	self.cur = nil
	self.token = self.token + 1
end

return M
