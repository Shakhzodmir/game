-- Public API of the core (17.3).
--
--   local core = require("core.game")
--   local level, errs = core.load_level(json_text_or_table)
--   local game = core.new(level, { seed = 1 })
--   game:input({ type = "swap", from = { 3, 4 }, to = { 4, 4 } })
--   game:step()
--
-- The game object is a thin wrapper {s = state}; the state is plain data
-- (no closures, no metatables) so clone() is a deep copy.

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local R = require("core.rng")
local L = require("core.level")
local ST = require("core.start")
local TK = require("core.tick")
local I = require("core.input")
local F = require("core.flow")
local G = require("core.gravity")
local MV = require("core.moves")
local HI = require("core.hint")
local HS = require("core.hash")

local core = {}

local Game = {}
Game.__index = Game

core.VERSION = C.CORE_VERSION

function core.load_level(input)
	return L.load(input)
end

local function check_opts(opts)
	local errs = {}
	if type(opts) ~= "table" then return { "opts: table required" } end
	if not (U.is_int(opts.seed) and opts.seed >= 1 and opts.seed <= 2147483646) then
		errs[#errs + 1] = "opts.seed: integer 1..2147483646 required"
	end
	for _, k in ipairs({ "attempt", "salt" }) do
		if opts[k] ~= nil and not (U.is_int(opts[k]) and opts[k] >= 0) then
			errs[#errs + 1] = "opts." .. k .. ": non-negative integer required"
		end
	end
	if opts.help ~= nil and not (U.is_int(opts.help) and opts.help >= 0 and opts.help <= 2) then
		errs[#errs + 1] = "opts.help: 0..2 required"
	end
	if opts.boosters ~= nil then
		if type(opts.boosters) ~= "table" then
			errs[#errs + 1] = "opts.boosters: list required"
		else
			for k = 1, #opts.boosters do
				if not C.PRE_BOOSTER[opts.boosters[k]] then
					errs[#errs + 1] = "opts.boosters[" .. k .. "]: riff|sub|disco required"
				end
			end
		end
	end
	if opts.timing ~= nil and not C.TIMING[opts.timing] then
		errs[#errs + 1] = "opts.timing: 'normal' or 'turbo' required"
	end
	if opts.input_lock ~= nil and type(opts.input_lock) ~= "boolean" then
		errs[#errs + 1] = "opts.input_lock: boolean required"
	end
	return errs
end

local function wrap(s)
	return setmetatable({ s = s }, Game)
end

-- core.new(level, opts): a game at tick 0 after section 4.
function core.new(level, opts)
	opts = opts or {}
	local errs = check_opts(opts)
	if type(level) ~= "table" or not level.presets then errs[#errs + 1] = "level: a loaded level required" end
	if #errs > 0 then return nil, errs end
	local items, names = {}, {}
	for k = 1, #(opts.boosters or {}) do
		items[k] = C.PRE_BOOSTER[opts.boosters[k]]
		names[k] = opts.boosters[k]
	end
	local s = ST.build(level, opts.seed, items)
	s.help = opts.help or 0
	s.timing = C.TIMING[opts.timing or "normal"]
	s.input_lock = opts.input_lock or false
	s.header = {
		seed = opts.seed, attempt = opts.attempt or 0, salt = opts.salt or 0,
		boosters = names, help = s.help, timing = opts.timing or "normal",
		input_lock = s.input_lock,
	}
	return wrap(s)
end

core.attempt_seed = R.attempt_seed

-- Stepping and input ------------------------------------------------------------

function Game:step()
	TK.step(self.s)
end

function Game:input(cmd)
	return I.input(self.s, cmd)
end

function Game:run_to_rest(max_ticks)
	max_ticks = max_ticks or 20000
	local n = 0
	while not F.is_stable(self.s) do
		if n >= max_ticks then error("core: run_to_rest exceeded " .. max_ticks .. " ticks") end
		TK.step(self.s)
		n = n + 1
	end
	return n
end

-- Queries (pure) ---------------------------------------------------------------

function Game:can_swap(from, to)
	return I.can_swap(self.s, from, to)
end

function Game:has_move()
	return MV.has_move(self.s)
end

function Game:moves()
	local s = self.s
	local list = MV.pair_list(s)
	local out = {}
	for k = 1, #list do
		local ax, ay = U.xy(s.W, list[k][1])
		local bx, by = U.xy(s.W, list[k][2])
		out[k] = { from = { ax, ay }, to = { bx, by } }
	end
	return out
end

function Game:hint()
	return HI.hint(self.s)
end

function Game:is_stable()
	return F.is_stable(self.s)
end

function Game:pieces()
	local s = self.s
	local out = {}
	local list = B.objects(s)
	for k = 1, #list do
		local o = list[k]
		local x, y = U.xy(s.W, o.cell)
		local p = {
			id = o.id, x = x, y = y, kind = C.KIND_NAME[o.kind],
			state = C.STATE_NAME[o.state], offx = o.offx, offy = o.offy,
			hidden = G.hidden(s, o), pinned = o.pins[1] ~= nil,
		}
		if o.color ~= 0 then p.color = C.COLOR_NAME[o.color] end
		if o.special ~= 0 then p.special = C.SPECIAL_NAME[o.special] end
		if o.axis ~= 0 then p.axis = C.AXIS_NAME[o.axis] end
		if o.blocker ~= 0 then
			p.item = C.BLOCKER_NAME[o.blocker]
			p.hp = o.hp
		end
		out[#out + 1] = p
	end
	return out
end

function Game:cells()
	local s = self.s
	local out = {}
	for i = 1, s.N do
		out[i] = { exists = s.exists[i], spawner = s.spawner[i], exit = s.exit[i], floor = s.floor[i], wires = s.wires[i] }
	end
	return out
end

function Game:status()
	local s = self.s
	return {
		state = C.GAME_NAME[s.state], stuck = s.stuck, tick = s.tick,
		moves_left = s.moves_left, score = s.score, goals = U.copy_array(s.goal_left),
	}
end

function Game:result()
	local s = self.s
	if s.state ~= C.G_COMPLETE and s.state ~= C.G_LOST then return nil end
	local won = s.state == C.G_COMPLETE
	return {
		won = won, score = s.score, moves_at_win = won and s.moves_at_win or 0,
		stars = won and C.STARS[s.level.difficulty] or 0, unplaced = U.copy_array(s.unplaced),
	}
end

function Game:drain_events()
	local ev = self.s.ev
	self.s.ev = {}
	return ev
end

function Game:hash()
	return HS.state(self.s)
end

-- Replay (17.1).
function Game:replay()
	local s, h = self.s, self.s.header
	local cmds = {}
	for k = 1, #s.cmds do
		cmds[k] = { tick = s.cmds[k].tick, cmd = U.deepcopy(s.cmds[k].cmd) }
	end
	return {
		core_version = C.CORE_VERSION,
		level = { id = s.level.id, version = s.level.version, hash = s.level.hash },
		seed = h.seed, attempt = h.attempt, salt = h.salt,
		boosters = U.copy_array(h.boosters), help = h.help, timing = h.timing,
		input_lock = h.input_lock,
		final_tick = s.tick, final_hash = HS.state(s),
		commands = cmds,
	}
end

-- Clones (17.3) -----------------------------------------------------------------

function Game:clone(opts)
	local s = U.deepcopy(self.s, self.s.level)
	s.level = self.s.level
	s.ev = {}
	if opts and opts.reseed ~= nil then
		local seed = R.fold_seed(s.header.seed, s.act, opts.reseed)
		s.rng[R.SPAWN] = R.stream(seed, R.SPAWN)
		s.rng[R.EFFECTS] = R.stream(seed, R.EFFECTS)
		s.rng[R.SHUFFLE] = R.stream(seed, R.SHUFFLE)
	end
	return wrap(s)
end

function Game:set_timing(mode)
	local code = C.TIMING[mode]
	if not code then error("core: set_timing expects 'normal' or 'turbo'", 2) end
	if code == C.TIMING_TURBO then
		I.switch_turbo(self.s)
	else
		self.s.timing = code
	end
end

-- Plays a replay on a level: returns the game and true, or the game (or nil)
-- and false, reason. Events are left in the game's buffer.
function core.playback(level, rep)
	if rep.level.hash ~= level.hash then return nil, false, "level hash differs" end
	local game, errs = core.new(level, {
		seed = rep.seed, attempt = rep.attempt, salt = rep.salt, help = rep.help,
		boosters = rep.boosters, timing = rep.timing, input_lock = rep.input_lock,
	})
	if not game then return nil, false, table.concat(errs, "; ") end
	local s = game.s
	for k = 1, #rep.commands do
		local c = rep.commands[k]
		while s.tick < c.tick - 1 do TK.step(s) end
		if s.tick ~= c.tick - 1 then return game, false, "command " .. k .. " is out of order" end
		local ok, res = I.input(s, c.cmd)
		if not ok then return game, false, "command " .. k .. " rejected: " .. tostring(res) end
	end
	while s.tick < rep.final_tick do TK.step(s) end
	if HS.state(s) ~= rep.final_hash then return game, false, "final hash differs" end
	return game, true
end

return core
