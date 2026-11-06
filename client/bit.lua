-- Bit, the mascot, in a GUI scene (client/ui.lua): one image node whose texture is the current frame of a
-- flipbook (client/anim.lua plays content/animations.json: idle variants, dance on the beat, cheer, surprise,
-- sleep, writing, listening, waving), with a soft shadow, a skeletal sway on top of the frames (breathing, rocking,
-- bouncing on the beat) and jumps. The frames are loose images (assets/images/bit/*.png) loaded on first use; the
-- producer's drawings replace them under the same names (tools/art/install_ready.py). A frame without a file keeps
-- the picture that was showing.
--
--   local bit = require("client.bit")
--   self.bit = bit.new(self.ui, parent, x, y, 150)
--   self.bit:cheer()            -- happy jump, back to idle after a while
--   self.bit:worry()            -- a refusal (not enough stars)
--   self.bit:dance(bpm)         -- dance_a / dance_b, locked to the clock of the playing track
--   self.bit:event("note_collected") -- a game event picks an animation (data: events)
--   self.bit:touch()            -- the player did something: Bit stays awake (a sleeper wakes up)
--   self.bit:update(dt)         -- in the script's update
--   bit.images()                -- image keys, for the scene's keep list

local app = require("client.app")
local audio = require("client.audio")
local anim = require("client.anim")

local M = {}

-- the moods the level and the windows ask for by name (every one is a state of content/animations.json)
M.MOODS = { "idle", "happy", "dance_a", "dance_b", "sad", "worried", "scratch" }

-- A character with still pictures only: used when content/animations.json cannot be read.
local FALLBACK = {
	bit = {
		anims = {
			still_idle = { images = { "bit/idle" }, mode = "loop" }, still_happy = { images = { "bit/happy" }, mode = "loop" },
			still_sad = { images = { "bit/sad" }, mode = "loop" }, still_worried = { images = { "bit/worried" }, mode = "loop" },
			still_scratch = { images = { "bit/scratch" }, mode = "loop" },
			still_a = { images = { "bit/dance_a" }, mode = "loop", beats = 2 }, still_b = { images = { "bit/dance_b" }, mode = "loop", beats = 2 },
		},
		states = {
			idle = { anim = "still_idle" }, happy = { anim = "still_happy", next = "idle", priority = 2 },
			sad = { anim = "still_sad", priority = 2 }, worried = { anim = "still_worried", priority = 2 },
			scratch = { anim = "still_scratch", priority = 2 }, dance_a = { anim = "still_a", priority = 2 },
			dance_b = { anim = "still_b", priority = 2 }, surprised = { anim = "still_happy", next = "idle" },
			look = { anim = "still_idle", next = "idle" }, wave = { anim = "still_happy", next = "idle" },
		},
		idle = { gap = { 5, 9 }, variants = { { state = "look", weight = 1 }, { state = "wave", weight = 1 } } },
		wake = "surprised", dance = { states = { "dance_a", "dance_b" }, beats_per_state = 1 },
		events = {},
	},
}

local data_cache

-- The animation data (decoded once); nil sections fall back to the still pictures.
function M.data()
	if data_cache == nil then
		local ok, t = pcall(function()
			local raw = sys.load_resource("/content/animations.json")
			return raw and json.decode(raw)
		end)
		data_cache = ok and type(t) == "table" and t.bit and #anim.validate(t) == 0 and t or false
	end
	return data_cache or FALLBACK
end

local Bit = {}
Bit.__index = Bit

function M.images()
	local out = anim.images(M.data().bit)
	for _, m in ipairs(M.MOODS) do out["bit/" .. m] = true end
	return out
end

local function reduced()
	return app.reduced_motion()
end

local function new_player()
	return anim.new(M.data().bit, {
		rng = math.random, reduced = reduced(),
		on_sound = function(name, gain) audio.sfx(name, { gain = gain, transpose = false }) end,
	})
end

-- x, y: centre of Bit in the parent's coordinates; size: the frame (square).
function M.new(scene, parent, x, y, size, opts)
	opts = opts or {}
	local self = setmetatable({ ui = scene, size = size, mood = nil, beat = nil, beat_t = 0, shown = nil,
		reduced = reduced(), v_pos = vmath.vector3(0, 0, 0), v_scale = vmath.vector3(1, 1, 1),
		v_euler = vmath.vector3(0, 0, 0) }, Bit)
	self.player = new_player()
	self.holder = scene:layer(parent)
	gui.set_position(self.holder, vmath.vector3(x, y, 0))
	self.home = vmath.vector3(x, y, 0)
	self.shadow = scene:circle(self.holder, 0, -size * 0.43, size * 0.62, "#5A3FA0", { soft = true, alpha = 0.22 })
	gui.set_scale(self.shadow, vmath.vector3(1, 0.28, 1))
	self.body = scene:layer(self.holder) -- jumps, squashes and the worried wobble (gui tweens)
	self.sway = scene:layer(self.body)   -- the skeletal sway of the animation (set every frame)
	local first = self.player:image()
	self.node = scene:image(self.sway, first, 0, 0, { w = size, h = size })
	if not self.node then
		self.node = scene:image(self.sway, "bit/idle", 0, 0, { w = size, h = size })
	end
	if not self.node then
		self.node = scene:circle(self.sway, 0, 0, size * 0.8, "#FFC98B")
	end
	self.shown = self.node and first or nil
	if opts.mood and opts.mood ~= "idle" then self.player:play(opts.mood) end
	self:_apply()
	return self
end

-- Puts the current frame on the node (nothing when it already shows it or its file is missing).
function Bit:_apply()
	local p = self.player
	self.mood = p.state
	local key = p:image()
	if key ~= self.shown then
		local id = self.ui:loose_texture(key)
		if id then
			gui.set_texture(self.node, id)
			self.shown = key
		end
	end
end

-- A mood by name (a state of the animation data); `idle` is the breathing Bit with its idle variants.
function Bit:set(mood)
	if self.mood == mood then return end
	self.beat = nil
	self.player:set_dance(false)
	if not self.player:play(mood) then self.player:play("idle") end
	self:_apply()
end

-- Kept for the callers that stop whatever runs (gui tweens of the jump and the wobble go on by themselves).
function Bit:idle()
	gui.cancel_animations(self.body, "scale")
	gui.set_scale(self.body, vmath.vector3(1, 1, 1))
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

-- A happy jump with the cheer animation; `times` jumps, the cheer lasts at least `hold` seconds.
function Bit:cheer(hold, times)
	self.beat = nil
	self.player:set_dance(false)
	self.player:play("cheer", { loops = times or 2, hold = nil })
	jump(self, self.size * 0.28, times or 2)
	self:_apply()
end

function Bit:worry(hold)
	self.beat = nil
	self.player:set_dance(false)
	self.player:play("worried", { hold = hold or 1.4 })
	if not reduced() then
		gui.cancel_animations(self.body, "euler.z")
		gui.set_euler(self.body, vmath.vector3(0, 0, -6))
		gui.animate(self.body, "euler.z", 6, gui.EASING_INOUTSINE, 0.12, 0, function()
			gui.animate(self.body, "euler.z", 0, gui.EASING_OUTQUAD, 0.12)
		end)
	end
	self:_apply()
end

-- A mood for `seconds` (1e9: until the next call), then back to idle.
function Bit:mood_for(seconds, mood)
	self.beat = nil
	self.player:set_dance(false)
	if not self.player:play(mood, { hold = seconds }) then self.player:play("idle") end
	self:_apply()
end

-- A game event picks an animation by the data (task_done, level_won, note_collected, tap, notebook, ...).
-- Returns the state it started or nil (a busier state keeps going).
function Bit:event(name)
	local st = self.player:trigger(name)
	if st then self:_apply() end
	return st
end

-- Ends a state that lasts until released (the notebook).
function Bit:release()
	self.player:release()
end

-- The player did something: Bit stays awake; a sleeper wakes up.
function Bit:touch()
	self.player:touch()
	self:_apply()
end

-- Dances on the beat: the frames follow the clock of the playing track (audio.status.clock), the tempo is the
-- track's (audio.status.bpm) or `bpm`.
function Bit:dance(bpm)
	self.beat = 60 / math.max(40, bpm or 100)
	self.beat_t = 0
	self.player:set_dance(false)
	self.player:set_dance(true, bpm or 100)
	self:_apply()
end

function Bit:stop()
	self.beat = nil
	self.player:set_dance(false)
	self.player:play("idle")
	self:_apply()
end

-- A tap on Bit: a reaction (surprise, a wave or a cheer) and a note in the key of the district.
function Bit:poke()
	self.player:touch()
	if self.player.dancing then
		jump(self, self.size * 0.2, 1)
	else
		local st = self.player:trigger("tap")
		if st == "cheer" then jump(self, self.size * 0.28, 1) end
		if st == "surprised" then jump(self, self.size * 0.12, 1) end
	end
	local colors = audio.COLORS
	audio.play_note(colors[math.random(#colors)], math.random(1, 6), { quantize = false })
	self:_apply()
end

function Bit:update(dt)
	local p = self.player
	local r = reduced()
	if r ~= self.reduced then
		self.reduced = r
		p:set_reduced(r)
	end
	local st = audio.status
	local clock
	if p.dancing then
		self.beat_t = self.beat_t + dt
		if self.beat and self.beat_t >= self.beat then self.beat_t = self.beat_t - self.beat end
		if st and st.bpm then p.bpm = st.bpm end
		-- the clock of the track locks the frames to its beats; without music they run on their own time
		if st and st.playing and (st.clock or 0) > 0 then clock = st.clock end
	end
	if p:update(dt, clock) then self:_apply() end
	if not r then
		local pose = p.pose
		local size = self.size
		self.v_pos.x, self.v_pos.y = pose.dx * size, pose.dy * size
		self.v_scale.x, self.v_scale.y = pose.sx, pose.sy
		self.v_euler.z = pose.rot
		gui.set_position(self.sway, self.v_pos)
		gui.set_scale(self.sway, self.v_scale)
		gui.set_euler(self.sway, self.v_euler)
	end
end

-- Screen-independent hit test for taps on Bit.
function Bit:pick(action)
	return gui.pick_node(self.node, action.x, action.y)
end

return M
