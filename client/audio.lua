-- Audio: API for any script + the pure maths and mixer state that
-- main/audio.script runs (client-architecture.md, section 5).
--
-- Front end (any script, GUI or game object; posts to main:/audio#audio):
--   audio.music(district_id)            start the district track: every stem in
--                                       the same frame, looping; locked stems at
--                                       gain 0, unlocked at 1 (from the meta)
--   audio.music(district_id, {all = true})  jukebox / finale: every task stem
--                                       + the party layer (never tension)
--   audio.stop_music(fade_seconds)
--   audio.unlock_stem(district_id, stem)  0 -> 1 crossfade over 0.5 s
--   audio.layer("tension" | "party", on) the extra stems of every track; the
--                                       two are never on together (party wins)
--   audio.level_duck(on)                music -6 dB while a level is on screen
--   audio.combo(waves)                  a big combo ducks music another -3 dB
--   audio.play_note(color, wave, opts)  musical note of a match, quantized to
--                                       the next 1/32 of the track clock and
--                                       mixed by the notes contract (below)
--   audio.sfx(name, opts)               immediate sound effect ("tap", "swap", ...);
--                                       tonal effects are transposed to the key
--                                       of the district like the notes
--   audio.set_volumes(music, sfx)       0..1 (normally from the settings)
--   audio.resync()                      restart the stems at the clock position
--
-- Mixer contract of the audio agent (assets/sounds/manifest.json -> mixer,
-- carried into client/assets_index.lua by tools/gen_defold.py):
--   notes on the same 1/32 tick: each file once, at most 3 voices (lowest
--   steps kept), voice i starts stagger[i] after the tick (10/22/34 ms), all
--   voices at gain_db_by_count[count] (0 / -4.5 / -6.5 dB);
--   music: tasks (+ tension at <= 5 moves) in a level; tasks + party in the
--   finale and the jukebox; never tension together with party.
--
-- Pure helpers (tested in tests/client/audio_test.lua):
--   note_step, note_id, transpose_speed, grid_step, quantize_delay, tick_of,
--   db_to_gain, gain_to_db, key_semitones, sfx_semitones, contract,
--   voices, new_note_scheduler, new_mixer

local M = {}

M.URL = "main:/audio#audio"
M.COLORS = { "red", "orange", "yellow", "green", "blue", "purple" }
M.MAX_STEP = 10          -- pentatonic steps 0..10 -> files <color>_1 .. <color>_11
M.MAX_TRANSPOSE = 7      -- semitones either way (keeps resampling artefacts low)
M.QUANTIZE_DIVISION = 32 -- 1/32 notes
M.CROSSFADE = 0.5        -- seconds, stem unlock
M.LEVEL_DUCK_DB = -6
M.COMBO_DUCK_DB = -3     -- on top of the level duck: -9 dB in a big combo
M.COMBO_HOLD = 1.5       -- seconds the combo duck lasts after the last big combo
M.BIG_COMBO = 4          -- waves (cascade depth) that count as a big combo
M.DUCK_SPEED_DB = 30     -- dB per second when ducking / restoring
M.LAYERS = { tension = true, party = true }
M.NOTE_HORIZON = 0.03    -- seconds: a tick group is played once its tick is this close

-- Defaults of the notes contract (used when the manifest is missing).
M.NOTE_CONTRACT = {
	dedupe = true,
	max_voices = 3,
	stagger = { 0.010, 0.022, 0.034 },
	gain_db_by_count = { 0.0, -4.5, -6.5 },
}

-- Live status written by main/audio.script (debug overlays, QA bridge).
M.status = {
	district = nil, playing = false, clock = 0, stems_on = 0,
	music_gain = 0, sfx_gain = 0, notes = 0, sfx = 0, last_delay = 0, music_rms = 0,
	note_groups = 0, voices = 0, max_group_voices = 0, deduped = 0, capped = 0,
	last_sfx_speed = 1, resyncs = 0, stalls = 0, layers = {},
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

-- Index and time of the grid line a note at `clock` is quantized to.
function M.tick_of(clock, bpm, division)
	local step = M.grid_step(bpm, division)
	local at = clock + M.quantize_delay(clock, bpm, division)
	local k = math.floor(at / step + 0.5)
	return k, k * step
end

function M.db_to_gain(db)
	return 10 ^ (db / 20)
end

function M.gain_to_db(g)
	if g <= 0 then return -math.huge end
	return 20 * math.log10(g)
end

local KEYS = {
	C = 0, ["C#"] = 1, Db = 1, D = 2, ["D#"] = 3, Eb = 3, E = 4, F = 5, ["F#"] = 6, Gb = 6,
	G = 7, ["G#"] = 8, Ab = 8, A = 9, ["A#"] = 10, Bb = 10, B = 11,
}

-- Semitones of a key name above C ("F" -> 5, "Bb" -> 10), nil if unknown.
function M.key_semitones(key)
	return KEYS[key]
end

-- Transposition of a sound effect written in `key` for a district
-- `district_semitones` from C (districts.json semitones_from_c). nil for an
-- atonal effect (key nil) or an unknown key: play it untransposed.
function M.sfx_semitones(key, district_semitones)
	local k = key and KEYS[key]
	if not k then return nil end
	local s = (tonumber(district_semitones) or 0) - k
	while s > 6 do s = s - 12 end
	while s < -6 do s = s + 12 end
	return s
end

-- The notes contract from the index (sounds.mixer.notes_same_tick), with
-- the defaults for anything missing or malformed.
function M.contract(src)
	local c = {}
	for k, v in pairs(M.NOTE_CONTRACT) do c[k] = v end
	if type(src) ~= "table" then return c end
	if type(src.max_voices) == "number" and src.max_voices >= 1 then c.max_voices = math.floor(src.max_voices) end
	if src.dedupe_same_file ~= nil then c.dedupe = src.dedupe_same_file and true or false end
	if src.dedupe ~= nil then c.dedupe = src.dedupe and true or false end
	local st = src.stagger_s or src.stagger
	if type(st) == "table" and #st >= c.max_voices then c.stagger = st end
	if type(src.gain_db_by_count) == "table" and #src.gain_db_by_count >= c.max_voices then
		c.gain_db_by_count = src.gain_db_by_count
	end
	return c
end

-- Voices for the notes that fall on one tick, by the contract. notes =
-- {{id, step, gain?, pan?, speed?}, ...} in arrival order. Returns
-- {{id, step, gain, pan, speed, offset}, ...} (offset = seconds after the
-- tick) plus stats {deduped, capped}.
function M.voices(notes, contract)
	contract = contract or M.NOTE_CONTRACT
	local list, seen, deduped = {}, {}, 0
	for i, n in ipairs(notes) do
		if contract.dedupe and seen[n.id] then
			deduped = deduped + 1
		else
			seen[n.id] = true
			list[#list + 1] = { n = n, seq = i }
		end
	end
	table.sort(list, function(a, b)
		local sa, sb = a.n.step or 0, b.n.step or 0
		if sa ~= sb then return sa < sb end
		return a.seq < b.seq
	end)
	local count = math.min(#list, contract.max_voices)
	local capped = #list - count
	local db = contract.gain_db_by_count[count] or contract.gain_db_by_count[#contract.gain_db_by_count] or 0
	local g = M.db_to_gain(db)
	local out = {}
	for i = 1, count do
		local n = list[i].n
		out[i] = {
			id = n.id, step = n.step, pan = n.pan or 0, speed = n.speed or 1,
			gain = math.max(0, math.min(1, (n.gain or 1) * g)),
			offset = contract.stagger[i] or contract.stagger[#contract.stagger] or 0,
		}
	end
	return out, { deduped = deduped, capped = capped }
end

-- note scheduler: groups the notes of one tick before they are played ----------------------

local Sched = {}
Sched.__index = Sched

function M.new_note_scheduler(contract)
	return setmetatable({
		contract = M.contract(contract),
		groups = {},      -- key -> {key, at, notes}
		keys = {},        -- pending keys
		max_played = nil, -- highest key already played (later notes go to the next tick)
	}, Sched)
end

-- Adds a note to the group of tick `key` (an integer that grows with time)
-- sounding at clock time `at`. false when that tick was already played: the
-- caller moves the note to the next tick.
function Sched:add(key, at, note)
	if self.max_played and key <= self.max_played then return false end
	local g = self.groups[key]
	if not g then
		g = { key = key, at = at, notes = {} }
		self.groups[key] = g
		self.keys[#self.keys + 1] = key
	end
	g.notes[#g.notes + 1] = note
	return true
end

function Sched:pending()
	return #self.keys
end

-- Groups whose tick is at most `horizon` seconds after `clock` (every group
-- when clock is nil), oldest first: {{key, at, voices, stats}, ...}.
function Sched:take_due(clock, horizon)
	local due, keep = {}, {}
	table.sort(self.keys)
	for _, key in ipairs(self.keys) do
		local g = self.groups[key]
		if clock == nil or g.at <= clock + (horizon or 0) then
			local v, st = M.voices(g.notes, self.contract)
			due[#due + 1] = { key = key, at = g.at, voices = v, stats = st }
			self.groups[key] = nil
			if not self.max_played or key > self.max_played then self.max_played = key end
		else
			keep[#keep + 1] = key
		end
	end
	self.keys = keep
	return due
end

-- Forgets the tick history (the clock restarted: new track or no music).
function Sched:reset()
	self.groups, self.keys, self.max_played = {}, {}, nil
end

-- mixer: what should sound how loud, independent of the engine ---------------------------

local Mixer = {}
Mixer.__index = Mixer

function M.new_mixer()
	return setmetatable({
		district = nil,
		bpm = nil,
		loop = nil,       -- loop length in seconds (all stems of a district share it)
		started_at = nil,
		stems = {},       -- name -> {gain, target, rate (gain per second), dirty}
		order = {},       -- stem names in start order
		layers = { tension = false, party = false },
		level_duck = false,
		combo_left = 0,   -- seconds of combo duck left
		duck_db = 0,      -- current (smoothed) duck
		music_volume = 0.8,
		sfx_volume = 1.0,
		group_db = { music = 0, sfx = 0, notes = 0 },
		_changed = {},    -- reused by update(): no garbage per frame
	}, Mixer)
end

-- Starts a track. stems: names of the stem files of the district (task stems
-- and the tension/party layers); unmuted: set {[stem] = true} of task stems
-- at full gain. opts = {all = true (jukebox / finale: every task stem and
-- party), loop = seconds}. The layers restart off (party on with all).
-- Returns the list {stem, gain} to start, in order, all in one frame.
function Mixer:start(district, bpm, stems, unmuted, now, opts)
	opts = opts or {}
	self.district, self.bpm, self.started_at = district, bpm, now
	self.loop = (type(opts.loop) == "number" and opts.loop > 0) and opts.loop or nil
	self.stems, self.order = {}, {}
	self.layers = { tension = false, party = opts.all and true or false }
	local out = {}
	for _, name in ipairs(stems) do
		local on
		if M.LAYERS[name] then
			on = self.layers[name]
		else
			on = (opts.all or (unmuted and unmuted[name])) and true or false
		end
		local g = on and 1 or 0
		self.stems[name] = { gain = g, target = g, rate = 0, dirty = false }
		self.order[#self.order + 1] = name
		out[#out + 1] = { stem = name, gain = g }
	end
	return out
end

-- Forgets the track; returns the stem names that must be stopped.
function Mixer:stop()
	local out = self.order
	self.district, self.started_at, self.bpm, self.loop = nil, nil, nil, nil
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

-- Where in the loop the stems should be now (seconds), or nil.
function Mixer:position(now)
	local c = self:clock(now)
	if not c then return nil end
	if self.loop then return c % self.loop end
	return c
end

-- Every stem restarted at the clock position, all in one frame: the fix for
-- stems that fell behind the clock while the engine loop stalled.
-- Returns {{stem, gain, start_time}, ...} or an empty list.
function Mixer:resync(now)
	local out = {}
	local pos = self:position(now)
	if not pos then return out end
	for _, name in ipairs(self.order) do
		out[#out + 1] = { stem = name, gain = self.stems[name].gain, start_time = pos }
	end
	return out
end

-- Moves a stem towards target over `seconds` (0 = at once). false if the
-- stem is not part of the track.
function Mixer:fade(stem, target, seconds)
	local s = self.stems[stem]
	if not s then return false end
	target = math.max(0, math.min(1, tonumber(target) or 0))
	s.target = target
	if not seconds or seconds <= 0 then
		-- instant: applied here (a rate of 1/0 times a dt of 0 would be NaN)
		if s.gain ~= target then s.dirty = true end
		s.gain, s.rate = target, 0
	else
		s.rate = math.abs(target - s.gain) / seconds
	end
	return true
end

function Mixer:unlock(stem)
	return self:fade(stem, 1, M.CROSSFADE)
end

-- Switches the tension / party layer. Party and tension never play together:
-- party on turns tension off, tension on while party plays is refused.
-- Returns true, or false and "unknown_layer" | "party_on".
function Mixer:set_layer(name, on, seconds)
	if not M.LAYERS[name] then return false, "unknown_layer" end
	on = on and true or false
	local fade = seconds or M.CROSSFADE
	if name == "tension" and on and self.layers.party then return false, "party_on" end
	if name == "party" and on and self.layers.tension then
		self.layers.tension = false
		self:fade("tension", 0, fade)
	end
	self.layers[name] = on
	self:fade(name, on and 1 or 0, fade)
	return true
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

-- Static gain of the engine groups in dB (manifest mixer.group_gain_db).
function Mixer:set_group_db(t)
	if type(t) ~= "table" then return end
	for _, k in ipairs({ "music", "sfx", "notes" }) do
		if type(t[k]) == "number" then self.group_db[k] = t[k] end
	end
end

-- Applies the mixer section of the audio manifest (assets.mixer()):
-- group_gain_db, music_in_level_db (-6), music_big_combo_db (-9 in total).
function Mixer:configure(contract)
	if type(contract) ~= "table" then return end
	self:set_group_db(contract.group_gain_db)
	local level = tonumber(contract.music_in_level_db)
	local combo = tonumber(contract.music_big_combo_db)
	if level and level <= 0 then self.level_db = level end
	if combo and combo <= (self.level_db or M.LEVEL_DUCK_DB) then
		self.combo_db = combo - (self.level_db or M.LEVEL_DUCK_DB)
	end
end

function Mixer:duck_target_db()
	local db = 0
	if self.level_duck then db = db + (self.level_db or M.LEVEL_DUCK_DB) end
	if self.combo_left > 0 then db = db + (self.combo_db or M.COMBO_DUCK_DB) end
	return db
end

-- Gain of the "music" mixer group: settings volume x ducking.
function Mixer:music_group_gain()
	return self.music_volume * M.db_to_gain(self.duck_db + self.group_db.music)
end

function Mixer:sfx_group_gain()
	return math.min(1, self.sfx_volume * M.db_to_gain(self.group_db.sfx))
end

-- The notes follow the sound effects volume.
function Mixer:notes_group_gain()
	return math.min(1, self.sfx_volume * M.db_to_gain(self.group_db.notes))
end

-- Advances fades and ducking by dt. Returns the list {stem, gain} of stems
-- whose gain changed this step. The list and its entries are reused on the
-- next call: read them at once.
function Mixer:update(dt)
	dt = tonumber(dt) or 0
	if dt ~= dt or dt < 0 then dt = 0 end
	local changed = self._changed
	local n = 0
	for _, name in ipairs(self.order) do
		local s = self.stems[name]
		local moved = s.dirty
		s.dirty = false
		if s.gain ~= s.target then
			local step = s.rate * dt
			if s.gain < s.target then
				s.gain = math.min(s.target, s.gain + step)
			else
				s.gain = math.max(s.target, s.gain - step)
			end
			moved = moved or step > 0
		end
		if moved then
			n = n + 1
			local e = changed[n]
			if not e then
				e = {}
				changed[n] = e
			end
			e.stem, e.gain = name, s.gain
		end
	end
	for i = #changed, n + 1, -1 do changed[i] = nil end
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

-- opts: {gain = 0..1 (default 1; the contract scales it by the voice count),
-- pan = -1..1, quantize = true}
function M.play_note(color, wave, opts)
	opts = opts or {}
	post("note", { color = color, wave = wave, gain = opts.gain, pan = opts.pan, quantize = opts.quantize ~= false })
end

-- opts: {gain, pan, speed, delay, transpose = true (tonal effects follow the key)}
function M.sfx(name, opts)
	opts = opts or {}
	post("sfx", {
		name = name, gain = opts.gain, pan = opts.pan, speed = opts.speed, delay = opts.delay,
		transpose = opts.transpose ~= false,
	})
end

function M.set_volumes(music, sfx)
	post("volumes", { music = music, sfx = sfx })
end

function M.resync()
	post("resync", {})
end

return M
