-- Audio: API for any script + the pure maths and mixer state that
-- main/audio.script runs (client-architecture.md, section 5).
--
-- Front end (any script, GUI or game object; posts to main:/audio#audio):
--   audio.music(district_id)            start the district track: every stem in
--                                       the same frame, looping; locked stems at
--                                       gain 0, unlocked at 1 (from the meta)
--   audio.music(district_id, {all = true})  jukebox: every stem unmuted
--   audio.stop_music(fade_seconds)
--   audio.unlock_stem(district_id, stem)  0 -> 1 crossfade over 0.5 s
--   audio.layer("tension" | "party", on) the extra stems of every track
--   audio.level_duck(on)                music -6 dB while a level is on screen
--   audio.combo(waves)                  a big combo ducks music another -3 dB
--   audio.play_note(color, wave, opts)  musical note of a match, quantized to
--                                       the next 1/32 of the track clock
--   audio.sfx(name, opts)               immediate sound effect ("tap", "swap", ...)
--   audio.set_volumes(music, sfx)       0..1 from the settings
--
-- Pure helpers (tested in tests/client/audio_test.lua):
--   note_step, note_id, transpose_speed, grid_step, quantize_delay,
--   db_to_gain, gain_to_db, new_mixer

local M = {}

M.URL = "main:/audio#audio"
M.COLORS = { "red", "orange", "yellow", "green", "blue", "purple" }
M.MAX_STEP = 10          -- pentatonic steps 0..10 -> files <color>_1 .. <color>_11
M.MAX_TRANSPOSE = 7      -- semitones either way (keeps resampling artefacts low)
M.QUANTIZE_DIVISION = 32 -- 1/32 notes
M.CROSSFADE = 0.5        -- seconds, stem unlock
M.LEVEL_DUCK_DB = -6
M.COMBO_DUCK_DB = -3
M.COMBO_HOLD = 1.5       -- seconds the combo duck lasts after the last big combo
M.BIG_COMBO = 4          -- waves (cascade depth) that count as a big combo
M.DUCK_SPEED_DB = 30     -- dB per second when ducking / restoring
M.LAYERS = { tension = true, party = true }

-- Live status written by main/audio.script (debug overlays, QA bridge).
M.status = {
	district = nil, playing = false, clock = 0, stems_on = 0,
	music_gain = 0, sfx_gain = 0, notes = 0, sfx = 0, last_delay = 0, music_rms = 0,
}

-- pure maths ---------------------------------------------------------------------------

-- Pentatonic step of a cascade wave: min(wave - 1, 10), never below 0.
function M.note_step(wave)
	wave = math.floor(tonumber(wave) or 1)
	return math.max(0, math.min(wave - 1, M.MAX_STEP))
end

-- Sound component id of a note (tools/gen_defold.py names them note_<color>_<n>).
function M.note_id(color, wave)
	local step = M.note_step(wave)
	return "note_" .. tostring(color) .. "_" .. (step + 1), step
end

-- Playback speed that transposes a C-based sample by `semitones` (clamped).
function M.transpose_speed(semitones)
	local s = tonumber(semitones) or 0
	s = math.max(-M.MAX_TRANSPOSE, math.min(M.MAX_TRANSPOSE, s))
	return 2 ^ (s / 12)
end

-- Length of one grid step in seconds: a 1/division note at bpm (4/4).
function M.grid_step(bpm, division)
	division = division or M.QUANTIZE_DIVISION
	return 240 / (bpm * division)
end

-- Delay from `clock` (seconds since the stems started) to the next grid
-- line. 0 when there is no clock (no music) or the clock is on a line.
function M.quantize_delay(clock, bpm, division)
	if not clock or not bpm or bpm <= 0 or clock < 0 then return 0 end
	local step = M.grid_step(bpm, division)
	local next_line = math.ceil(clock / step - 1e-9) * step
	local d = next_line - clock
	if d < 0.0005 then return 0 end
	return d
end

function M.db_to_gain(db)
	return 10 ^ (db / 20)
end

function M.gain_to_db(g)
	if g <= 0 then return -math.huge end
	return 20 * math.log10(g)
end

-- mixer: what should sound how loud, independent of the engine ---------------------------

local Mixer = {}
Mixer.__index = Mixer

function M.new_mixer()
	return setmetatable({
		district = nil,
		bpm = nil,
		started_at = nil,
		stems = {},       -- name -> {gain, target, rate (gain per second)}
		order = {},       -- stem names in start order
		layers = { tension = false, party = false },
		level_duck = false,
		combo_left = 0,   -- seconds of combo duck left
		duck_db = 0,      -- current (smoothed) duck
		music_volume = 0.8,
		sfx_volume = 1.0,
	}, Mixer)
end

-- Starts a track. stems: names of the stem files of the district (task stems
-- and the tension/party layers); unmuted: set {[stem] = true} of stems at
-- full gain. Returns the list {stem, gain} to start, in order, all in one frame.
function Mixer:start(district, bpm, stems, unmuted, now)
	self.district, self.bpm, self.started_at = district, bpm, now
	self.stems, self.order = {}, {}
	local out = {}
	for _, name in ipairs(stems) do
		local on
		if M.LAYERS[name] then on = self.layers[name] else on = unmuted[name] and true or false end
		local g = on and 1 or 0
		self.stems[name] = { gain = g, target = g, rate = 0 }
		self.order[#self.order + 1] = name
		out[#out + 1] = { stem = name, gain = g }
	end
	return out
end

-- Forgets the track; returns the stem names that must be stopped.
function Mixer:stop()
	local out = self.order
	self.district, self.started_at, self.bpm = nil, nil, nil
	self.stems, self.order = {}, {}
	return out
end

function Mixer:playing()
	return self.district ~= nil
end

-- Seconds since the stems started (the music clock), or nil.
function Mixer:clock(now)
	if not self.started_at then return nil end
	return math.max(0, now - self.started_at)
end

-- Moves a stem towards target over `seconds` (0 = at once). false if the
-- stem is not part of the track.
function Mixer:fade(stem, target, seconds)
	local s = self.stems[stem]
	if not s then return false end
	s.target = target
	if not seconds or seconds <= 0 then
		s.rate = math.huge
	else
		s.rate = math.abs(target - s.gain) / seconds
	end
	return true
end

function Mixer:unlock(stem)
	return self:fade(stem, 1, M.CROSSFADE)
end

function Mixer:set_layer(name, on)
	if not M.LAYERS[name] then return false end
	self.layers[name] = on and true or false
	return self:fade(name, on and 1 or 0, M.CROSSFADE)
end

function Mixer:set_level_duck(on)
	self.level_duck = on and true or false
end

-- waves: cascade depth of the combo; only big ones duck the music.
function Mixer:combo(waves)
	if (tonumber(waves) or 0) >= M.BIG_COMBO then
		self.combo_left = M.COMBO_HOLD
		return true
	end
	return false
end

function Mixer:set_volumes(music, sfx)
	if music then self.music_volume = math.max(0, math.min(1, music)) end
	if sfx then self.sfx_volume = math.max(0, math.min(1, sfx)) end
end

function Mixer:duck_target_db()
	local db = 0
	if self.level_duck then db = db + M.LEVEL_DUCK_DB end
	if self.combo_left > 0 then db = db + M.COMBO_DUCK_DB end
	return db
end

-- Gain of the "music" mixer group: settings volume x ducking.
function Mixer:music_group_gain()
	return self.music_volume * M.db_to_gain(self.duck_db)
end

function Mixer:sfx_group_gain()
	return self.sfx_volume
end

-- Advances fades and ducking by dt. Returns the list {stem, gain} of stems
-- whose gain changed this step.
function Mixer:update(dt)
	local changed = {}
	for _, name in ipairs(self.order) do
		local s = self.stems[name]
		if s.gain ~= s.target then
			local step = s.rate * dt
			if s.gain < s.target then
				s.gain = math.min(s.target, s.gain + step)
			else
				s.gain = math.max(s.target, s.gain - step)
			end
			changed[#changed + 1] = { stem = name, gain = s.gain }
		end
	end
	if self.combo_left > 0 then self.combo_left = math.max(0, self.combo_left - dt) end
	local target = self:duck_target_db()
	if self.duck_db ~= target then
		local step = M.DUCK_SPEED_DB * dt
		if self.duck_db < target then
			self.duck_db = math.min(target, self.duck_db + step)
		else
			self.duck_db = math.max(target, self.duck_db - step)
		end
	end
	return changed
end

function Mixer:gain(stem)
	local s = self.stems[stem]
	return s and s.gain or nil
end

-- front end: messages to main/audio.script -------------------------------------------------

local function post(id, message)
	if msg and msg.post then msg.post(M.URL, id, message or {}) end
end

function M.music(district, opts)
	post("music", { district = district, all = opts and opts.all or nil })
end

function M.stop_music(fade)
	post("stop_music", { fade = fade })
end

function M.unlock_stem(district, stem)
	post("unlock_stem", { district = district, stem = stem })
end

function M.layer(name, on)
	post("layer", { name = name, on = on and true or false })
end

function M.level_duck(on)
	post("duck", { on = on and true or false })
end

function M.combo(waves)
	post("combo", { waves = waves })
end

-- opts: {gain = 0..1 (default 0.8), pan = -1..1, quantize = true}
function M.play_note(color, wave, opts)
	opts = opts or {}
	post("note", { color = color, wave = wave, gain = opts.gain, pan = opts.pan, quantize = opts.quantize ~= false })
end

-- opts: {gain, pan, speed, delay}
function M.sfx(name, opts)
	opts = opts or {}
	post("sfx", { name = name, gain = opts.gain, pan = opts.pan, speed = opts.speed, delay = opts.delay })
end

function M.set_volumes(music, sfx)
	post("volumes", { music = music, sfx = sfx })
end

return M
