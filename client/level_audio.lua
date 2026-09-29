-- Sound of the board (pure Lua): turns core events into client/audio.lua
-- calls and haptic ticks (client-architecture.md, 5). The match notes are
-- the synesthesia: instrument = piece colour, pitch = cascade wave; the
-- audio script quantizes them to the music and mixes them by the notes
-- contract. Everything else is a sound effect, rate-limited where a big
-- cascade would otherwise machine-gun it.
--
--   local level_audio = require("client.level_audio")
--   local la = level_audio.new({audio = require("client.audio"), vibrate = platform.vibrate,
--                               now = socket.gettime, width = W})
--   la:events(events)      -- every tick's events, in order
--   la:touch()             -- a finger touched a piece: the click sounds at once
--   la:finish()            -- the screen is leaving: layers off
--
-- Layers: "tension" while playing with 1..5 moves left, "party" in the final
-- concert (the mixer never plays them together).

local M = {}

M.LOW_MOVES = 5
M.LAND_GAP = 0.09       -- seconds between two landing ticks at most
M.LAND_GAIN = 0.28
M.SFX_GAP = 0.05        -- same effect again only after this long
M.BIG_WAVE = 4          -- a wave this deep ducks the music (audio.combo)

M.SPECIAL_SFX = { riff = "riff", sub = "sub", bird = "bird", disco = "disco" }
M.BLOCKER_HIT = { record_box = "box_hit", concrete = "concrete_hit", column = "column_hit", noise = "noise_fizz" }
M.BLOCKER_BREAK = {
	record_box = "box_break", concrete = "concrete_break", noise = "noise_break",
	balloon = "balloon_pop", column = "column_on",
}
M.PRAISE_INDEX = { juicy = 1, hit = 2, drive = 3, vibe = 4, legend = 5 }
M.HAPTIC = { tap = 8, special = 22, combo = 40, finale = 70, praise = 14, goal = 18, destroy = 10 }

local LA = {}
LA.__index = LA

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		audio = opts.audio,
		vibrate = opts.vibrate or function() end,
		now = opts.now or os.clock,
		width = opts.width or 9,
		last = {},          -- sfx name -> time played
		tension = false,
		party = false,
		moves_low_played = false,
		state = "playing",
		disco = nil,        -- {color, step} of the last Disco activation (its rays play notes)
		goals_done = {},
		log = opts.log,     -- optional list: every call is appended (tests, debug)
	}, LA)
end

function LA:_log(...)
	if self.log then self.log[#self.log + 1] = { ... } end
end

-- An effect, at most once per `gap` seconds (0 = always).
function LA:sfx(name, opts, gap)
	local now = self.now()
	local g = gap or M.SFX_GAP
	local t = self.last[name]
	if g > 0 and t and now - t < g then return false end
	self.last[name] = now
	self:_log("sfx", name)
	if self.audio then self.audio.sfx(name, opts) end
	return true
end

function LA:note(color, wave, x)
	local pan = 0
	if x and self.width > 1 then pan = ((x - 1) / (self.width - 1) - 0.5) * 0.6 end
	self:_log("note", color, wave)
	if self.audio then self.audio.play_note(color, wave, { pan = pan }) end
end

function LA:layer(name, on)
	if self[name] == on then return end
	self[name] = on
	self:_log("layer", name, on)
	if self.audio then self.audio.layer(name, on) end
end

function LA:buzz(kind)
	local ms = M.HAPTIC[kind]
	if ms then
		self:_log("vibrate", ms)
		self.vibrate(ms)
	end
end

function LA:touch()
	self:sfx("tap", { gain = 0.7 }, 0.03)
	self:buzz("tap")
end

-- The tension layer follows the moves left while playing.
function LA:_moves(left)
	local low = self.state == "playing" and left > 0 and left <= M.LOW_MOVES
	if low and not self.moves_low_played then
		self.moves_low_played = true
		self:sfx("moves_low", nil, 0)
	elseif not low and left > M.LOW_MOVES then
		self.moves_low_played = false -- bought moves: the warning may come again
	end
	if not self.party then self:layer("tension", low) end
end

function LA:_state(st)
	self.state = st
	if st == "concert" then
		self:layer("tension", false)
		self:layer("party", true)
	elseif st ~= "playing" then
		self:layer("tension", false)
	end
end

function LA:event(e)
	local ty = e.type
	if ty == "match" then
		self:note(e.color, e.wave, e.cells and e.cells[1] and e.cells[1][1])
		if (e.wave or 0) >= M.BIG_WAVE and self.audio then
			self:_log("combo", e.wave)
			self.audio.combo(e.wave)
		end
		self:sfx("clear", { gain = 0.45 }, 0.07)
	elseif ty == "special_new" then
		self:sfx("special_create", nil, 0.06)
	elseif ty == "activate" then
		if e.special == "disco" or e.combo then
			self.disco = { color = e.color, step = 0 }
		end
		if e.combo == "finale" then
			self:sfx("finale", nil, 0)
			self:buzz("finale")
		elseif e.combo then
			self:sfx("combo_drop", nil, 0.2)
			self:buzz("combo")
		else
			self:sfx(M.SPECIAL_SFX[e.special] or "riff", nil, 0.04)
			self:buzz("special")
		end
	elseif ty == "disco_ray" then
		-- the Disco ball plays an arpeggio in the colour it clears
		local d = self.disco
		if d and d.color then
			d.step = d.step + 1
			self:note(d.color, 1 + (d.step - 1) % 8, e.tx)
		end
	elseif ty == "bird_fly" then
		self:sfx("bird", { gain = 0.6 }, 0.1)
	elseif ty == "transform" or ty == "concert_riff" or ty == "continue_riff" then
		self:sfx("special_create", { gain = 0.7 }, 0.08)
	elseif ty == "hit" then
		if e.layer == "blocker" then
			self:sfx(M.BLOCKER_HIT[e.item] or "box_hit", nil, 0.06)
		elseif e.layer == "wires" then
			self:sfx("wires_snap", { gain = 0.5 }, 0.08)
		end
	elseif ty == "destroy" then
		self:sfx(M.BLOCKER_BREAK[e.item] or "box_break", nil, 0.05)
		self:buzz("destroy")
	elseif ty == "freed" then
		self:sfx("wires_snap", nil, 0.06)
	elseif ty == "floor_lit" then
		self:sfx("floor_light", nil, 0.06)
	elseif ty == "land" then
		self:sfx("land", { gain = M.LAND_GAIN }, M.LAND_GAP)
	elseif ty == "goal" then
		if e.left == 0 and not self.goals_done[e.index] then
			self.goals_done[e.index] = true
			self:sfx("goal_done", nil, 0)
			self:buzz("goal")
		end
	elseif ty == "moves" then
		self:_moves(e.left or 0)
	elseif ty == "state" then
		self:_state(e.state)
	elseif ty == "mic_delivered" then
		self:sfx("mic_collect", nil, 0.1)
	elseif ty == "noise_spread" then
		self:sfx("noise_fizz", nil, 0.1)
	elseif ty == "shuffle" then
		self:sfx("shuffle", nil, 0)
	elseif ty == "praise" then
		local n = M.PRAISE_INDEX[e.word]
		if n then
			self:sfx("praise_" .. n, nil, 0)
			self:buzz("praise")
		end
	elseif ty == "swap" or ty == "swap_back" then
		self:sfx("swap", { gain = 0.8 }, 0.04)
	elseif ty == "swap_fail" then
		self:sfx("swap_fail", nil, 0.04)
	elseif ty == "booster" then
		self:sfx("booster", nil, 0)
	end
end

function LA:events(list)
	for i = 1, #list do self:event(list[i]) end
end

-- The screen is leaving: the extra layers go off.
function LA:finish()
	self:layer("tension", false)
	self:layer("party", false)
end

return M
