-- Bit, the mascot, in a GUI scene (client/ui.lua): one image node whose
-- texture follows the mood, with a soft shadow, a breathing idle, jumps,
-- a worried wobble and dancing on the beat. The frames are loose images
-- (assets/images/bit/*.png) loaded on first use by the scene.
--
--   local bit = require("client.bit")
--   self.bit = bit.new(self.ui, parent, x, y, 150)
--   self.bit:cheer()            -- happy jump, back to idle after a while
--   self.bit:worry()            -- a refusal (not enough stars)
--   self.bit:dance(bpm)         -- dance_a / dance_b on every beat
--   self.bit:update(dt)         -- in the script's update
--   bit.images()                -- image keys, for the scene's keep list

local app = require("client.app")
local audio = require("client.audio")

local M = {}

M.MOODS = { "idle", "happy", "dance_a", "dance_b", "sad", "worried", "scratch" }

local Bit = {}
Bit.__index = Bit

function M.images()
	local out = {}
	for _, m in ipairs(M.MOODS) do out["bit/" .. m] = true end
	return out
end

local function reduced()
	return app.reduced_motion()
end

-- x, y: centre of Bit in the parent's coordinates; size: the frame (square).
function M.new(scene, parent, x, y, size, opts)
	opts = opts or {}
	local self = setmetatable({ ui = scene, size = size, mood = nil, back_t = nil, beat = nil, beat_t = 0, frame = 0 }, Bit)
	self.holder = scene:layer(parent)
	gui.set_position(self.holder, vmath.vector3(x, y, 0))
	self.home = vmath.vector3(x, y, 0)
	self.shadow = scene:circle(self.holder, 0, -size * 0.43, size * 0.62, "#5A3FA0", { soft = true, alpha = 0.22 })
	gui.set_scale(self.shadow, vmath.vector3(1, 0.28, 1))
	self.body = scene:layer(self.holder)
	self.node = scene:image(self.body, "bit/idle", 0, 0, { w = size, h = size })
	if not self.node then
		self.node = scene:circle(self.body, 0, 0, size * 0.8, "#FFC98B")
	end
	self:set(opts.mood or "idle")
	self:idle()
	return self
end

function Bit:set(mood)
	if self.mood == mood then return end
	self.mood = mood
	local id = self.ui:loose_texture("bit/" .. mood)
	if id then gui.set_texture(self.node, id) end
end

-- Breathing: a slow squash of the body. Nothing under reduced motion.
function Bit:idle()
	gui.cancel_animations(self.body, "scale")
	gui.set_scale(self.body, vmath.vector3(1, 1, 1))
	if reduced() then return end
	gui.animate(self.body, "scale", vmath.vector3(1.03, 0.97, 1), gui.EASING_INOUTSINE, 0.9, 0, nil,
		gui.PLAYBACK_LOOP_PINGPONG)
end

local function jump(self, height, times)
	if reduced() then return end
	local p = self.home
	gui.cancel_animations(self.holder, "position")
	gui.set_position(self.holder, p)
	local n = 0
	local function hop()
		n = n + 1
		if n > times then return end
		gui.animate(self.holder, "position.y", p.y + height, gui.EASING_OUTQUAD, 0.17, 0, function()
			gui.animate(self.holder, "position.y", p.y, gui.EASING_INQUAD, 0.15, 0, hop)
		end)
	end
	hop()
end

-- A happy jump; back to idle after `hold` seconds.
function Bit:cheer(hold, times)
	self.beat = nil
	self:set("happy")
	jump(self, self.size * 0.28, times or 2)
	self.back_t = hold or 1.8
end

function Bit:worry(hold)
	self.beat = nil
	self:set("worried")
	if not reduced() then
		gui.cancel_animations(self.body, "euler.z")
		gui.set_euler(self.body, vmath.vector3(0, 0, -6))
		gui.animate(self.body, "euler.z", 6, gui.EASING_INOUTSINE, 0.12, 0, function()
			gui.animate(self.body, "euler.z", 0, gui.EASING_OUTQUAD, 0.12)
		end)
	end
	self.back_t = hold or 1.4
end

function Bit:mood_for(seconds, mood)
	self.beat = nil
	self:set(mood)
	self.back_t = seconds
end

-- Dances on the beat: the frame flips and the body bounces every beat.
function Bit:dance(bpm)
	self.beat = 60 / math.max(40, bpm or 100)
	self.beat_t = 0
	self.back_t = nil
	self:set("dance_a")
end

function Bit:stop()
	self.beat = nil
	self.back_t = nil
	self:set("idle")
	self:idle()
end

-- A tap on Bit: a jump and a note in the key of the district.
function Bit:poke()
	self:cheer(1.2, 1)
	local colors = audio.COLORS
	audio.play_note(colors[math.random(#colors)], math.random(1, 6), { quantize = false })
end

function Bit:update(dt)
	if self.beat then
		self.beat_t = self.beat_t + dt
		if self.beat_t >= self.beat then
			self.beat_t = self.beat_t - self.beat
			self.frame = 1 - self.frame
			self:set(self.frame == 0 and "dance_a" or "dance_b")
			if not reduced() then
				gui.set_scale(self.body, vmath.vector3(1.08, 0.92, 1))
				gui.animate(self.body, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, self.beat * 0.8)
			end
		end
	elseif self.back_t then
		self.back_t = self.back_t - dt
		if self.back_t <= 0 then
			self.back_t = nil
			self:set("idle")
			self:idle()
		end
	end
end

-- Screen-independent hit test for taps on Bit.
function Bit:pick(action)
	return gui.pick_node(self.node, action.x, action.y)
end

return M
