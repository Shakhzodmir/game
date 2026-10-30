-- Tutorial runtime of the level screen (pure Lua, no engine calls).
--
-- A tutorial is a list of guided steps for one level, read from
-- /content/tutorials.json (levels-plan.md, section 4; tests/client/tutorial_content_test.lua fails the
-- build when the file is missing, and load() logs a warning if the game cannot read it):
--   {"<level id>": {"steps": [
--       {"kind": "swap", "from": [x, y], "to": [x, y], "text": "<i18n key>"},
--       {"kind": "tap", "at": [x, y], "text": "..."},                  -- tap a special piece
--       {"kind": "booster", "booster": "stick", "at": [x, y], "text": "..."},
--       {"kind": "tip", "at": [x, y] (optional), "text": "..."}]}}     -- a note, dismissed by a tap
-- Coordinates are as in the level file (0-based, y down); the runtime works
-- with core cells (1-based).
--
-- While a swap / tap / booster step is on, the board lets only the guided move
-- through (client/level_link.lua guard), draws the tutorial's move as the hint
-- instead of its own pick, and the screen shows a spotlight, a pointing hand
-- and a text bubble (screens/level/tutorial_view.lua). A step is done when the
-- core accepts the guided command; the next one starts when the board is at
-- rest again. A step whose move is no longer valid (the board is not what the
-- author drew) falls back to the core's own hint, or ends the tutorial: the
-- player is never stuck behind a guard.
--
--   local tutorial = require("client.tutorial")
--   local t = tutorial.start(level_id, {
--       seen = function(id) return meta:tutorial_seen(id) end,
--       mark = function(id) meta:mark_tutorial_seen(id) end,
--       env = {state = fn() -> "playing" | ..., stable = fn() -> bool,
--              can_swap = fn(from, to) -> "ok" | "fail" | "reject",
--              piece = fn(x, y) -> {kind, special, state, pinned} | nil,
--              specials = fn() -> {{x, y}, ...} (idle specials), hint = fn() -> {from, to} | {at} | nil,
--              targeting = fn() -> booster id | nil, moves_left = fn() -> n,
--              booster_ready = fn(id) -> bool, mode = fn() -> "swipe" | "taptap"},
--       on_step = function(index, step, count) end,    -- a step was done (analytics)
--       defs = decoded tutorials.json (default: tutorial.load())})
--   if t then link.set_guard(t:guard()) end            -- nil: nothing to show for this level
--   t:update(dt)                                       -- every frame
--   t:view()                                           -- what to draw now (below), nil between steps
--   t:tap()                                            -- the player tapped (dismisses a tip)
--   t:skip()                                           -- the player skips the tutorial
--   t:finished(), t.reason                             -- "completed" | "skipped" | "abandoned" | "ended"
--
-- view() = {index, count, kind, text, cells = {{x, y}...} (the spotlight), button = booster id |
--   nil (the booster button to point at), hand = {mode = "swipe" | "taps" | "point", points = {{x, y}...}} | nil,
--   dismiss = "tap" | nil, sub = "pick" | "target" | nil (a booster step), rev}
-- t.rev grows whenever the view changes; t.blocked grows with every press the guard turned away.
-- The tutorial is remembered in the save by the id "level_<n>" (meta:mark_tutorial_seen), once it
-- is complete, skipped, abandoned as broken, or the level is won.

local M = {}

M.PATH = "/content/tutorials.json"
M.KINDS = { swap = true, tap = true, booster = true, tip = true }
M.TARGET = { stick = "at", row_light = "row", col_light = "col" } -- boosters that need a target
M.START_DELAY = 0.8  -- seconds from the first frame to the first step (the board blooms in)
M.STEP_DELAY = 0.35  -- seconds between two steps
M.TIP_GUARD = 0.45   -- a tip takes a tap only after this long (the tap that made a move must not dismiss it)

local floor = math.floor

-- loading -----------------------------------------------------------------------------------------

-- test hooks: fn(path) -> text | nil ; fn(text) -> table ; fn(text) for the warnings (default: print)
M.read = nil
M.decode = nil
M.warn = nil

local cache = nil

local function read(path)
	if M.read then return M.read(path) end
	if sys and sys.load_resource then
		local ok, data = pcall(sys.load_resource, path)
		if ok then return data end
	end
	return nil
end

local function decode(text)
	local fn = M.decode or (json and json.decode)
	if not fn then return nil end
	local ok, t = pcall(fn, text)
	if ok and type(t) == "table" then return t end
	return nil
end

local function warn(text)
	local log = M.warn or print
	log("WARNING: tutorials: " .. text)
end

-- The decoded tutorials.json (cached); {} when the file is missing or broken. That is a defect of the
-- build (the game would have no tutorials at all, silently), so it is logged once: the QA run of the
-- browser build shows the line.
function M.load()
	if cache == nil then
		local text = read(M.PATH)
		local data = text and decode(text)
		if type(data) ~= "table" then
			warn(M.PATH .. (text and " is not valid JSON" or " cannot be read") .. ": the game has no tutorials")
		end
		cache = type(data) == "table" and data or false
	end
	return cache or {}
end

function M._reset()
	cache = nil
	M.read, M.decode, M.warn = nil, nil, nil
end

-- parsing -----------------------------------------------------------------------------------------

local function cell(v)
	if type(v) ~= "table" then return nil end
	local x, y = tonumber(v[1]), tonumber(v[2])
	if not x or not y or x ~= floor(x) or y ~= floor(y) or x < 0 or y < 0 then return nil end
	return { x + 1, y + 1 }
end

local function same(a, b)
	return a ~= nil and b ~= nil and a[1] == b[1] and a[2] == b[2]
end

local function adjacent(a, b)
	return math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) == 1
end

-- One raw step -> {kind, text, from, to, at, booster} with core cells, or nil and why.
function M.parse_step(raw)
	if type(raw) ~= "table" then return nil, "a step must be a table" end
	local kind = raw.kind
	if not M.KINDS[kind] then return nil, "unknown kind '" .. tostring(kind) .. "'" end
	local step = { kind = kind, text = type(raw.text) == "string" and raw.text or nil }
	if kind == "swap" then
		step.from, step.to = cell(raw.from), cell(raw.to)
		if not (step.from and step.to) then return nil, "a swap step needs from and to" end
		if not adjacent(step.from, step.to) then return nil, "the cells of a swap step must be neighbours" end
	elseif kind == "tap" then
		step.at = cell(raw.at)
		if not step.at then return nil, "a tap step needs at" end
	elseif kind == "booster" then
		local b = raw.booster
		if b ~= "remix" and not M.TARGET[b] then return nil, "unknown in-level booster '" .. tostring(b) .. "'" end
		step.booster = b
		step.at = cell(raw.at)
		if M.TARGET[b] and not step.at then return nil, "a " .. b .. " step needs at" end
	else -- tip
		step.at = cell(raw.at)
	end
	return step
end

-- The steps of a level from the decoded file: {steps} (the valid ones up to
-- the first broken step), {errors}. nil when the level has no tutorial.
function M.steps(defs, level_id)
	if type(defs) ~= "table" then return nil end
	local entry = defs[tostring(level_id)] or defs[tonumber(level_id)]
	if type(entry) ~= "table" or type(entry.steps) ~= "table" or #entry.steps == 0 then return nil end
	local out, errors = {}, {}
	for i, raw in ipairs(entry.steps) do
		local step, why = M.parse_step(raw)
		if not step then
			errors[#errors + 1] = "step " .. i .. ": " .. why
			break
		end
		out[#out + 1] = step
	end
	if #out == 0 then return nil, errors end
	return out, errors
end

-- The id the save remembers a level's tutorial by.
function M.id(level_id)
	return "level_" .. tostring(level_id)
end

-- runtime ---------------------------------------------------------------------------------------------

local T = {}
T.__index = T

-- opts = {level_id, steps, env, seen = fn(id) -> bool, mark = fn(id), on_step = fn(index, step, count),
--         on_show = fn(index, step), on_done = fn(reason), fallback = true}
function M.new(opts)
	local self = setmetatable({
		id = M.id(opts.level_id),
		level_id = opts.level_id,
		steps = opts.steps,
		env = opts.env or {},
		mark = opts.mark,
		on_step = opts.on_step,
		on_show = opts.on_show,
		on_done = opts.on_done,
		fallback = opts.fallback ~= false,
		index = 1,
		phase = "wait",   -- wait (before a step) | active | sent (the move is made, the board settles) | done
		wait = M.START_DELAY,
		age = 0,
		rev = 0,
		blocked = 0,      -- presses and commands the guard turned away
		fallbacks = 0,    -- steps that fell back to the core's hint
		marked = false,
		reason = nil,
	}, T)
	return self
end

-- A tutorial for the level, or nil: no steps for it, or it was seen already.
function M.start(level_id, opts)
	opts = opts or {}
	local defs = opts.defs or M.load()
	local steps = M.steps(defs, level_id)
	if not steps then return nil end
	if opts.seen and opts.seen(M.id(level_id)) then return nil end
	return M.new({
		level_id = level_id, steps = steps, env = opts.env, mark = opts.mark, on_step = opts.on_step,
		on_show = opts.on_show, on_done = opts.on_done, fallback = opts.fallback,
	})
end

function T:finished()
	return self.phase == "done"
end

function T:running()
	return self.phase ~= "done"
end

function T:count()
	return #self.steps
end

-- The step on now (swap / tap / booster / tip), or nil.
function T:step()
	if self.phase == "active" then return self.steps[self.index] end
	return nil
end

function T:_touch()
	self.rev = self.rev + 1
end

function T:_finish(reason, mark)
	if self.phase == "done" then return end
	self.phase = "done"
	self.reason = reason
	self:_touch()
	if mark and not self.marked then
		self.marked = true
		if self.mark then self.mark(self.id) end
	end
	if self.on_done then self.on_done(reason) end
end

-- The step's move is still possible on the board as it is now. A swap or tap
-- whose cells are off may be repaired from the core (the same lesson, another
-- spot): the step is changed in place and true is returned.
function T:_valid(st)
	local env = self.env
	if st.kind == "swap" then
		if not env.can_swap then return true end
		if env.can_swap(st.from, st.to) == "ok" then return true end
		if self.fallback and env.hint then
			local h = env.hint()
			if h and h.from and h.to then
				st.from, st.to = { h.from[1], h.from[2] }, { h.to[1], h.to[2] }
				self.fallbacks = self.fallbacks + 1
				return true
			end
		end
		return false
	elseif st.kind == "tap" then
		if not env.piece then return true end
		local function ok_at(c)
			local p = c and env.piece(c[1], c[2])
			return p ~= nil and p.kind == "special" and p.state == "idle" and not p.pinned
		end
		if ok_at(st.at) then return true end
		if self.fallback and env.specials then
			local list = env.specials()
			if list and #list == 1 then
				st.at = { list[1][1] or list[1].x, list[1][2] or list[1].y }
				self.fallbacks = self.fallbacks + 1
				return true
			end
		end
		return false
	elseif st.kind == "booster" then
		if env.booster_ready and not env.booster_ready(st.booster) then return false end
		if st.at and env.piece and env.piece(st.at[1], st.at[2]) == nil then return false end
		return true
	end
	return true
end

function T:_activate()
	local st = self.steps[self.index]
	if not self:_valid(st) then
		self:_finish("abandoned", true)
		return
	end
	self.phase, self.age, self.sub = "active", 0, nil
	local env = self.env
	self.moves0 = env.moves_left and env.moves_left() or nil
	if st.kind == "booster" then self.sub = "pick" end
	self:_touch()
	if self.on_show then self.on_show(self.index, st) end
end

function T:_done_step()
	local st = self.steps[self.index]
	if self.on_step then self.on_step(self.index, st, #self.steps) end
	self.phase = "sent"
	self:_touch()
end

function T:_advance()
	if self.index >= #self.steps then
		self:_finish("completed", true)
		return
	end
	self.index = self.index + 1
	self.phase, self.wait = "wait", M.STEP_DELAY
	self:_touch()
end

-- Every frame.
function T:update(dt)
	if self.phase == "done" then return end
	local env = self.env
	local state = env.state and env.state() or nil
	if state == nil then return end -- no board yet
	if state ~= "playing" then
		-- won: the lesson counts as seen; out of moves or lost: it is shown again next time
		local won = state == "won_wait" or state == "concert" or state == "complete"
		self:_finish("ended", won)
		return
	end
	dt = tonumber(dt) or 0
	if self.phase == "wait" then
		self.wait = self.wait - dt
		if self.wait <= 0 and (not env.stable or env.stable()) then self:_activate() end
	elseif self.phase == "active" then
		self.age = self.age + dt
		local st = self.steps[self.index]
		if st.kind == "booster" then
			local sub = (env.targeting and env.targeting() == st.booster) and "target" or "pick"
			if sub ~= self.sub then
				self.sub = sub
				self:_touch()
			end
		end
		if st.kind ~= "tip" and self.moves0 and env.moves_left and env.moves_left() ~= self.moves0 then
			-- a move was made behind the guard's back (autoplay, a debug command): the board is not
			-- what the step drew any more
			self.moves0 = env.moves_left()
			if not self:_valid(st) then
				self:_finish("abandoned", true)
			else
				self:_touch()
			end
		end
	elseif self.phase == "sent" then
		if not env.stable or env.stable() then self:_advance() end
	end
end

-- guided input ------------------------------------------------------------------------------------------------------

local function swap_matches(st, cmd)
	if cmd.type ~= "swap" or type(cmd.from) ~= "table" or type(cmd.to) ~= "table" then return false end
	return (same(cmd.from, st.from) and same(cmd.to, st.to)) or (same(cmd.from, st.to) and same(cmd.to, st.from))
end

local function booster_matches(st, cmd)
	if cmd.type ~= "booster" or cmd.booster ~= st.booster then return false end
	local field = M.TARGET[st.booster]
	if not field then return true end
	if field == "at" then return same(cmd.at, st.at) end
	if field == "row" then return cmd.row == st.at[2] end
	return cmd.col == st.at[1]
end

-- (x, y) may be aimed at by a booster step: the guided cell, or any cell of its row / column
local function target_ok(st, x, y)
	local field = M.TARGET[st.booster]
	if field == "row" then return y == st.at[2] end
	if field == "col" then return x == st.at[1] end
	return x == st.at[1] and y == st.at[2]
end

-- A press on core cell (x, y). Called once per press by the board. A tip takes it as a tap.
function T:allow_cell(x, y)
	if self.phase == "done" then return true end
	local at = { x, y }
	if self.phase == "active" then
		local st = self.steps[self.index]
		if st.kind == "swap" then
			if same(at, st.from) or same(at, st.to) then return true end
		elseif st.kind == "tap" then
			if same(at, st.at) then return true end
		elseif st.kind == "booster" then
			if self.sub == "target" and target_ok(st, x, y) then return true end
		elseif st.kind == "tip" then
			self:tap()
			return false
		end
	end
	self.blocked = self.blocked + 1
	return false
end

-- A swap / tap / booster command the board is about to send.
function T:allow_command(cmd)
	if self.phase == "done" then return true end
	if self.phase == "active" and type(cmd) == "table" then
		local st = self.steps[self.index]
		local ok = false
		if st.kind == "swap" then
			ok = swap_matches(st, cmd)
		elseif st.kind == "tap" then
			ok = cmd.type == "tap" and same(cmd.at, st.at)
		elseif st.kind == "booster" then
			ok = booster_matches(st, cmd)
		end
		if ok then return true end
	end
	self.blocked = self.blocked + 1
	return false
end

-- The HUD is about to start booster `id` (a tap on its button).
function T:allow_booster(id)
	if self.phase == "done" then return true end
	if self.phase == "active" then
		local st = self.steps[self.index]
		if st.kind == "booster" and st.booster == id then return true end
	end
	self.blocked = self.blocked + 1
	return false
end

-- What the board shows as the hint: the guided move of the step on now, else
-- nothing (the board's own pick would point at some other swap).
function T:hint(cmd)
	if self.phase == "done" then return cmd end
	if self.phase == "active" then
		local st = self.steps[self.index]
		if st.kind == "swap" then
			return { type = "swap", from = { st.from[1], st.from[2] }, to = { st.to[1], st.to[2] } }
		elseif st.kind == "tap" then
			return { type = "tap", at = { st.at[1], st.at[2] } }
		end
	end
	return nil
end

-- What the core answered to a command (client/level_link.lua sent): the guided
-- command accepted ends the step.
function T:sent(cmd, ok, res)
	if self.phase ~= "active" or type(cmd) ~= "table" or not ok then return end
	local st = self.steps[self.index]
	local hit = false
	if st.kind == "swap" then
		hit = swap_matches(st, cmd) and res == "ok"
	elseif st.kind == "tap" then
		hit = cmd.type == "tap" and same(cmd.at, st.at)
	elseif st.kind == "booster" then
		hit = booster_matches(st, cmd)
	end
	if hit then self:_done_step() end
end

-- The player tapped: a tip is dismissed (not in its first moments).
function T:tap()
	if self.phase ~= "active" then return false end
	local st = self.steps[self.index]
	if st.kind ~= "tip" or self.age < M.TIP_GUARD then return false end
	self:_done_step()
	self:_advance_now()
	return true
end

-- a tip has no move to wait for: on to the next step at once
function T:_advance_now()
	if self.phase == "sent" then self:_advance() end
end

-- The player skips the whole tutorial: it is not shown again.
function T:skip()
	self:_finish("skipped", true)
end

-- The table for client/level_link.lua set_guard.
function T:guard()
	local me = self
	return {
		cell = function(x, y) return me:allow_cell(x, y) end,
		command = function(cmd) return me:allow_command(cmd) end,
		booster = function(id) return me:allow_booster(id) end,
		hint = function(cmd) return me:hint(cmd) end,
		sent = function(cmd, ok, res) me:sent(cmd, ok, res) end,
	}
end

-- What to draw now, or nil while no step is on (see the header).
function T:view()
	if self.phase ~= "active" then return nil end
	local st = self.steps[self.index]
	local mode = self.env.mode and self.env.mode() or "swipe"
	-- the same table (read-only) until the step or the input mode changes: the screen asks every frame
	local c = self.view_cache
	if c and c.rev == self.rev and c.mode == mode and c.index == self.index and c.sub == self.sub then return c.view end
	local v = {
		index = self.index, count = #self.steps, kind = st.kind, text = st.text, cells = {},
		dismiss = st.kind == "tip" and "tap" or nil, sub = self.sub, rev = self.rev,
	}
	if st.kind == "swap" then
		v.cells = { st.from, st.to }
		v.hand = { mode = mode == "taptap" and "taps" or "swipe", points = { st.from, st.to } }
	elseif st.kind == "tap" then
		v.cells = { st.at }
		v.hand = { mode = "taps", points = mode == "taptap" and { st.at, st.at } or { st.at } }
	elseif st.kind == "booster" then
		if self.sub == "target" then
			if st.at then
				v.cells = { st.at }
				v.hand = { mode = "taps", points = { st.at } }
			end
		else
			v.button = st.booster
		end
	elseif st.at then
		v.cells = { st.at }
		v.hand = { mode = "point", points = { st.at } }
	end
	self.view_cache = { view = v, rev = self.rev, mode = mode, index = self.index, sub = self.sub }
	return v
end

return M
