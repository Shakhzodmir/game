-- What Bit, the mascot, does during a level (pure Lua; the picture is client/bit.lua).
--
-- Bit stands beside the board and dances on the beat of the music, scratches a
-- record when a combo goes off, covers his ears when the noise spreads, is
-- scared on the last moves and when they are gone, jumps for joy when a goal is
-- done and at the win, and is sad at the defeat (client-architecture.md, 4.2).
-- This module only decides; the screen turns its actions into calls on the Bit
-- object (screens/level/hud.lua).
--
--   local level_bit = require("client.level_bit")
--   local lb = level_bit.new({bpm = 100, reduced = false, state = "playing", left = 20})
--   lb:event(topic, payload)       -- the board's bus topics (level_moves, level_special, ...)
--   lb:update(dt)
--   lb:replay()                    -- say again what he is doing (the picture was rebuilt)
--   lb:pending()                   -- is an action waiting (cheap), then lb:take()
--   for _, a in ipairs(lb:take()) do ... end   -- the actions since the last call:
--     {op = "dance", bpm}                  dance on the beat
--     {op = "idle"}                        stand and breathe
--     {op = "stay", mood}                  a mood that stays: "worried" | "sad"
--     {op = "mood", mood, seconds}         a mood for a while, then back ("scratch")
--     {op = "worry", seconds}              cover the ears (and wobble) for a while, then back
--     {op = "cheer", seconds, times}       jump for joy; seconds = how long the happy face stays
--
-- Reduced motion: no dancing (he stands), the moods still show.

local M = {}

M.LOW_MOVES = 5
M.SCRATCH = 1.4   -- seconds of scratching after a combo
M.EARS = 1.8      -- seconds with the ears covered after noise grew
M.CHEER = 1.1     -- seconds of a small cheer (a goal done, a big cascade word)
M.PRAISE_MIN = 4  -- praise words from "Groovy!" up make him cheer

local B = {}
B.__index = B

-- opts = {bpm = 100, reduced = false, state = "playing", left = moves left}
function M.new(opts)
	opts = opts or {}
	local self = setmetatable({
		bpm = tonumber(opts.bpm) or 100,
		reduced = opts.reduced and true or false,
		state = opts.state or "playing",
		left = opts.left,
		trans = nil,   -- {kind = "scratch" | "ears" | "cheer", left = seconds}
		final = nil,   -- "happy" | "sad": the level is over
		actions = {},
		shown = nil,   -- what the last action put on the screen
	}, B)
	self:_refresh(true)
	return self
end

-- The mood that stays while nothing short-lived is going on.
function B:_base()
	local st = self.state
	if st == "out_of_moves" then return "worried" end
	if st == "playing" and self.left and self.left <= M.LOW_MOVES then return "worried" end
	if self.reduced then return "idle" end
	return "dance"
end

function B:_push(a)
	self.actions[#self.actions + 1] = a
end

-- Puts what Bit should be doing now on the screen when it changed (or with `force`).
function B:_refresh(force)
	local key
	if self.final then
		key = self.final
	elseif self.trans then
		key = self.trans.kind
	else
		key = self:_base()
	end
	if key == self.shown and not force then return end
	self.shown = key
	if key == "happy" then
		self:_push({ op = "cheer", seconds = 1e9, times = 3 })
	elseif key == "sad" then
		self:_push({ op = "stay", mood = "sad" })
	elseif key == "scratch" then
		self:_push({ op = "mood", mood = "scratch", seconds = self.trans.left })
	elseif key == "ears" then
		self:_push({ op = "worry", seconds = self.trans.left })
	elseif key == "cheer" then
		self:_push({ op = "cheer", seconds = self.trans.left, times = 1 })
	elseif key == "worried" then
		self:_push({ op = "stay", mood = "worried" })
	elseif key == "dance" then
		self:_push({ op = "dance", bpm = self.bpm })
	else
		self:_push({ op = "idle" })
	end
end

-- A short-lived mood; a new one replaces the one running.
function B:_trans(kind, seconds)
	if self.final then return end
	local same = self.trans and self.trans.kind == kind
	self.trans = { kind = kind, left = seconds }
	if same then
		self.shown = nil -- the same face again: start it over
	end
	self:_refresh()
end

-- A bus topic of the board.
function B:event(topic, p)
	if self.final then return end
	p = p or {}
	if topic == "level_moves" then
		self.left = p.left
		if not self.trans then self:_refresh() end
	elseif topic == "level_special" then
		if p.combo then self:_trans("scratch", M.SCRATCH) end
	elseif topic == "level_noise" then
		self:_trans("ears", M.EARS)
	elseif topic == "level_goal" then
		if p.left == 0 then self:_trans("cheer", M.CHEER) end
	elseif topic == "level_praise" then
		if (p.index or 0) >= M.PRAISE_MIN then self:_trans("cheer", M.CHEER) end
	elseif topic == "level_state" then
		self.state = p.state
		if p.state == "complete" then
			self.trans, self.final = nil, "happy"
			self:_refresh()
		elseif p.state == "lost" then
			self.trans, self.final = nil, "sad"
			self:_refresh()
		elseif p.state == "won_wait" then
			self:_trans("cheer", M.CHEER * 1.5)
		else
			if not self.trans then self:_refresh() end
		end
	end
end

function B:set_reduced(on)
	on = on and true or false
	if on == self.reduced then return end
	self.reduced = on
	if not self.trans and not self.final then self:_refresh() end
end

function B:set_bpm(bpm)
	bpm = tonumber(bpm)
	if bpm and bpm > 0 then
		self.bpm = bpm
		if self.shown == "dance" then self:_refresh(true) end
	end
end

function B:update(dt)
	local t = self.trans
	if not t then return end
	t.left = t.left - (tonumber(dt) or 0)
	if t.left <= 0 then
		self.trans = nil
		self:_refresh()
	end
end

-- Is there an action waiting? (cheap: ask this every frame, take() only when it is true)
function B:pending()
	return #self.actions > 0
end

-- The actions since the last call (a new table; the queue is emptied).
function B:take()
	local out = self.actions
	self.actions = {}
	return out
end

-- Puts what he is doing now on the screen again (the picture was rebuilt).
function B:replay()
	self:_refresh(true)
end

-- what he is doing now: "dance" | "idle" | "worried" | "sad" | "happy" | "scratch" | "ears" | "cheer"
function B:mood()
	return self.shown
end

return M
