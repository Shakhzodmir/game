-- The game of the level screen (pure Lua): builds the core game from the
-- screen params, runs the fixed-step loop and hands every tick's events to
-- the board. No rules here: the core decides everything, the session only
-- feeds it time and commands (client-architecture.md, 4.1).
--
--   local level_session = require("client.level_session")
--   local s, err = level_session.new({
--       params = app.params,                -- {level_id, run, level_text} or {level = n} (debug)
--       read_level = function(n) return text end,  -- standalone: reads level_%04d.json
--       hooks = {first_move = fn(), booster_used = fn(id)},
--   })
--   s:advance(dt, function(events, tick) ... end)  -- in update(): 1/60 s ticks, at most 6
--   s:display_tick()          -- tick + fraction of the next one (for animations)
--   s:command(cmd)            -- game:input with the move / booster hooks
--   s:slowmo(0.4, 0.5)        -- visual slow motion: logic runs at half speed for 0.4 s
--   s.game                    -- the core game (queries: pieces, cells, status, hint, ...)
--   s.data                    -- the level JSON as plain data (goals, colours, difficulty)
--
-- Params contract (the start window, client/flow.lua): params.level_id, params.run
-- = meta:start_level result {level_id, attempt, assist, salt, boosters, ...},
-- params.level_text = the raw level JSON. Without them (debug keys, the QA
-- "level n" command) the session reads the level itself and plays attempt 1
-- with salt 0 and no boosters.

local core = require("core.game")
local json_strict = require("core.json_strict")

local M = {}

M.DT = 1 / 60
M.MAX_TICKS = 6       -- ticks per frame at most; a longer frame drops the rest
M.MAX_FRAME = 0.25    -- seconds of one frame that count at most
M.PRE_BOOSTERS = { riff = true, sub = true, disco = true }

-- Level of help for the core (0..2) from the losses in a row on the level
-- (meta-economy.md: 3-4 losses -> 5 %, 5 and more -> 10 %; core-rules.md 10.3).
function M.help_level(fails)
	fails = tonumber(fails) or 0
	if fails >= 5 then return 2 end
	if fails >= 3 then return 1 end
	return 0
end

local function int(v, default)
	v = tonumber(v)
	if not v or v ~= math.floor(v) then return default end
	return v
end

-- What the core needs from the screen params. read(n) -> level text | nil.
-- Returns {level_id, text, run, attempt, salt, help, boosters, standalone}.
function M.resolve(params, read)
	params = type(params) == "table" and params or {}
	local run = type(params.run) == "table" and params.run or nil
	local id = int(params.level_id) or int(params.level) or (run and int(run.level_id)) or 1
	local text = params.level_text
	if type(text) ~= "string" and type(text) ~= "table" then
		text = read and read(id) or nil
	end
	local boosters = {}
	if run and type(run.boosters) == "table" then
		for _, b in ipairs(run.boosters) do
			if M.PRE_BOOSTERS[b] then boosters[#boosters + 1] = b end
		end
	end
	local attempt = run and int(run.attempt) or 1
	local salt = run and int(run.salt) or 0
	if attempt < 0 then attempt = 1 end
	if salt < 0 then salt = 0 end
	return {
		level_id = id, text = text, run = run,
		attempt = attempt, salt = salt,
		help = M.help_level(run and run.assist),
		boosters = boosters,
		standalone = run == nil,
	}
end

local Session = {}
Session.__index = Session

-- opts: {params, read_level = fn(n) -> text, hooks = {first_move, booster_used},
--        timing = "normal"|"turbo", input_lock = bool, core = core module (tests)}
-- Returns the session, or nil and an error string.
function M.new(opts)
	opts = opts or {}
	local C = opts.core or core
	local info = M.resolve(opts.params, opts.read_level)
	if info.text == nil then return nil, "level " .. info.level_id .. ": no level file" end
	local level, errs = C.load_level(info.text)
	if not level then
		return nil, "level " .. info.level_id .. ": " .. table.concat(errs or { "cannot load" }, "; ")
	end
	local seed = C.attempt_seed(info.level_id, info.attempt, info.salt)
	local game, gerr = C.new(level, {
		seed = seed, attempt = info.attempt, salt = info.salt, help = info.help,
		boosters = info.boosters, timing = opts.timing or "normal", input_lock = opts.input_lock or false,
	})
	if not game then return nil, "level " .. info.level_id .. ": " .. table.concat(gerr or {}, "; ") end
	-- the level JSON as plain data (goals, colours, difficulty names) for the HUD
	local okd, data = pcall(json_strict.decode, level.canonical or "")
	local self = setmetatable({
		info = info,
		level = level,
		data = okd and type(data) == "table" and data or {},
		game = game,
		seed = seed,
		hooks = opts.hooks or {},
		acc = 0,
		tick = 0,
		paused = false,
		slow_left = 0,
		slow_scale = 1,
		moved = false,
		frames = 0,
		ticks_run = 0,
		dropped = 0,
	}, Session)
	self.W, self.H = self:size()
	self.status = game:status()
	return self
end

-- Board size W, H of the loaded level.
function Session:size()
	local lv = self.level
	if lv.W and lv.H then return lv.W, lv.H end
	local s = self.game.s
	return s.W, s.H
end

-- Fixed-step loop: accumulates dt (scaled during slow motion) and runs whole
-- 1/60 s ticks, at most MAX_TICKS per call; the backlog past that is
-- dropped (a slow device plays slower instead of spiralling). After every
-- tick the events are drained and handed to on_tick(events, tick).
-- Returns the number of ticks run.
function Session:advance(dt, on_tick)
	self.frames = self.frames + 1
	if self.paused then return 0 end
	dt = tonumber(dt) or 0
	if dt ~= dt or dt < 0 then dt = 0 end
	if dt > M.MAX_FRAME then dt = M.MAX_FRAME end
	if self.slow_left > 0 then
		local real = math.min(dt, self.slow_left)
		self.slow_left = self.slow_left - real
		dt = real * self.slow_scale + (dt - real)
	end
	self.acc = self.acc + dt
	local n = 0
	while self.acc >= M.DT - 1e-9 and n < M.MAX_TICKS do
		self.acc = self.acc - M.DT
		if self.acc < 0 then self.acc = 0 end
		self.game:step()
		self.tick = self.tick + 1
		n = n + 1
		local events = self.game:drain_events()
		if #events > 0 then self.status = self.game:status() end
		if on_tick then on_tick(events, self.tick) end
	end
	if self.acc >= M.DT then
		self.dropped = self.dropped + math.floor(self.acc / M.DT)
		self.acc = self.acc % M.DT
	end
	self.ticks_run = self.ticks_run + n
	return n
end

-- Tick + the fraction of the next one: the clock of the animations that
-- follow core timings (swaps, bolts, flights). Slows down with slowmo().
function Session:display_tick()
	return self.tick + self.acc / M.DT
end

-- Visual slow motion (Grand finale): for `seconds` of real time the logic
-- runs at `scale` speed. The core does not know (core-rules.md 14).
function Session:slowmo(seconds, scale)
	self.slow_left = math.max(self.slow_left, tonumber(seconds) or 0)
	self.slow_scale = tonumber(scale) or 0.5
end

function Session:set_paused(on)
	self.paused = on and true or false
end

-- game:input(cmd) plus the hooks: first_move() at the first accepted swap or
-- tap (meta:note_move), booster_used(id) when the core accepts a booster.
function Session:command(cmd)
	local ok, res = self.game:input(cmd)
	if ok then
		local t = cmd.type
		if (t == "swap" or t == "tap") and res == "ok" and not self.moved then
			self.moved = true
			if self.hooks.first_move then self.hooks.first_move() end
		elseif t == "booster" then
			if not self.moved then
				self.moved = true -- meta: a booster counts as the first move
			end
			if self.hooks.booster_used then self.hooks.booster_used(cmd.booster) end
		end
		self.status = self.game:status()
	end
	return ok, res
end

-- The hint move as a command ({type = "swap", from, to} | {type = "tap", at}) or nil.
function Session:hint_command()
	local h = self.game:hint()
	if not h then return nil end
	if h.at then return { type = "tap", at = { h.at[1], h.at[2] } } end
	return { type = "swap", from = { h.from[1], h.from[2] }, to = { h.to[1], h.to[2] } }
end

-- Plain state for the QA bridge and debug overlays.
function Session:snapshot()
	local st = self.game:status()
	return {
		level = self.info.level_id, state = st.state, stuck = st.stuck, tick = st.tick,
		moves = st.moves_left, score = st.score, goals = st.goals,
		stable = self.game:is_stable(), paused = self.paused, seed = self.seed,
		attempt = self.info.attempt, standalone = self.info.standalone,
		result = self.game:result(),
	}
end

-- QA bridge commands on this session (client/qa_bridge.lua):
--   hint_move | swap x1 y1 x2 y2 | tap x y | skip | state |
--   booster <stick|row_light|col_light|remix> [x y | row | col] | continue [n] [riff] | give_up
-- Returns a result table {ok, ...}.
function Session:qa(name, args)
	args = args or {}
	local function num(i) return tonumber(args[i]) end
	local function run(cmd)
		local ok, res = self:command(cmd)
		return { ok = ok, result = res, cmd = cmd, state = self:snapshot() }
	end
	if name == "state" then
		return { ok = true, state = self:snapshot() }
	elseif name == "hint_move" then
		local cmd = self:hint_command()
		if not cmd then return { ok = false, error = "no_hint", state = self:snapshot() } end
		return run(cmd)
	elseif name == "swap" then
		if not (num(1) and num(2) and num(3) and num(4)) then return { ok = false, error = "swap x1 y1 x2 y2" } end
		return run({ type = "swap", from = { num(1), num(2) }, to = { num(3), num(4) } })
	elseif name == "tap" then
		if not (num(1) and num(2)) then return { ok = false, error = "tap x y" } end
		return run({ type = "tap", at = { num(1), num(2) } })
	elseif name == "skip" then
		return run({ type = "skip" })
	elseif name == "booster" then
		local b = args[1]
		if b == "stick" then return run({ type = "booster", booster = b, at = { num(2) or 1, num(3) or 1 } }) end
		if b == "row_light" then return run({ type = "booster", booster = b, row = num(2) or 1 }) end
		if b == "col_light" then return run({ type = "booster", booster = b, col = num(2) or 1 }) end
		return run({ type = "booster", booster = b or "remix" })
	elseif name == "continue" then
		return run({ type = "continue", moves = num(1) or 5, riff = args[2] == "riff" })
	elseif name == "give_up" then
		return run({ type = "give_up" })
	end
	return { ok = false, error = "unknown level command '" .. tostring(name) .. "'" }
end

M.QA_COMMANDS = { "hint_move", "swap", "tap", "skip", "state", "booster", "continue", "give_up" }

return M
