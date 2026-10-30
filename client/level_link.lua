-- The level board as seen by the HUD and the level windows (pure Lua).
--
-- The board (screens/level/board.script) owns the core game; GUI scripts of
-- the level screen talk to it through this shared module (script.shared_state
-- = 1): plain Lua calls on the session and the input state, no go.* calls, so
-- they are safe from any script. Everything that happens on the board comes
-- back as bus events (below).
--
--   local link = require("client.level_link")
--   link.active()                  -- true while a board is on display
--   link.status()                  -- game:status() {state, moves_left, score, goals, ...}
--   link.info()                    -- {level_id, W, H, goals, moves, difficulty, colors (level JSON),
--                                  --  run, standalone}
--   link.booster("stick" | "row_light" | "col_light")  -- enter target mode (the next tap on the board)
--   link.booster("remix")          -- applied at once
--       -> true | false, reason ("no_board" | "busy" | core reason)
--   link.cancel_booster()          -- leave target mode
--   link.targeting()               -- booster id in target mode, or nil
--   link.pause(on)                 -- a window is open: no ticks, no input
--   link.skip()                    -- skip the final concert (turbo)
--   link.continue(moves, riff)     -- "+5 moves" bought: core continue
--   link.give_up()                 -- out of moves, the player gives up
--   link.cell_center(x, y)         -- logical coordinates of core cell (x, y)
--   link.board_rect()              -- {x0, y0, x1, y1, cell} of the cell grid (the same table until it changes)
--   link.view()                    -- what the board background GUI draws (level_bg.gui_script):
--                                  --  {rev, geom, cells, floor0, floor_rev, lit = {[i] = t}, deliver,
--                                  --   shake_x, shake_y}; rev grows when the layout changed,
--                                  --   floor_rev when a floor tile was hit or lit
--   link.stable()                  -- the board is at rest (game:is_stable())
--   link.piece(x, y)               -- {kind, special, state, pinned} of core cell (x, y), or nil
--   link.can_swap(from, to)        -- game:can_swap: "ok" | "fail" | "reject" (nil without a board)
--   link.specials()                -- {{x, y}, ...} the idle special pieces
--   link.core_hint()               -- game:hint(): {from, to} | {at} | nil
--
-- Bus topics published by the board (client/bus.lua; payloads are read-only):
--   level_ready    {level_id, W, H, moves, goals, rect, standalone}   the board is built
--   level_moves    {left}                                    moves left changed
--   level_goal     {index, left, x, y, lx, ly, kind, color, item}  a goal went down
--                  (lx, ly = where the collected thing was: fly it to the goal icon)
--   level_score    {delta, total, lx, ly}
--   level_state    {state, reason}                           game state changed (reason "stuck")
--   level_praise   {word, index (1..5, i18n "praise.<index>"), wave}
--   level_banner   {key}                                     e.g. "hud.shuffle"
--   level_booster  {booster, phase = "target" | "cancel" | "used" | "rejected" | "done", ok, reason}
--                  (target / cancel: target mode on / off; used: the core took the command;
--                  rejected: it refused, reason = core reason; done: the booster ran, ok = false
--                  when a remix had nothing to shuffle)
--   level_result   {result = game:result()}                  complete or lost
--   level_special  {special, combo, lx, ly}                  a special fired (Bit scratches)
--   level_flash    {color, alpha, dur}                       the whole screen flashes (fx GUI)
--   level_floor    {x, y, lx, ly}                            a dance-floor tile was lit
--   level_noise    {x, y, lx, ly}                            noise grew onto a piece (Bit covers his ears)
--
-- The tutorial's guard (client/tutorial.lua): while a guided step is on, the
-- board asks before it takes a press or sends a command, and the HUD asks
-- before it starts a booster. A guard is a table of optional functions; a
-- missing one lets everything through, and a guard that raises an error is
-- dropped at once (a tutorial bug must never trap the player).
--   link.set_guard(g) / link.clear_guard() / link.guard()
--   g.cell(x, y) -> bool         a press on core cell (x, y); called once per press
--   g.command(cmd) -> bool       a swap / tap / booster command the board is about to send
--   g.booster(id) -> bool        the HUD is about to start booster `id`
--   g.hint(cmd) -> cmd | nil     the hint the board shows after 5 s of idleness
--   g.sent(cmd, ok, res)         what the core answered to a command the board sent
--   link.allow_cell(x, y), link.allow_command(cmd), link.allow_booster(id), link.hint(cmd), link.sent(...)

local M = {}

M.board = nil -- set by the board script: {session, input, geom, on_booster}
M.on_guard_error = nil -- test / debug hook: fn(name, err)

local guard_ref = nil

function M.attach(board)
	M.board = board
end

function M.detach(board)
	if M.board == board then M.board = nil end
end

function M.active()
	return M.board ~= nil
end

function M.status()
	local b = M.board
	return b and b.session.game:status() or nil
end

function M.info()
	local b = M.board
	if not b then return nil end
	local s = b.session
	local d = s.data or {}
	return {
		level_id = s.info.level_id, W = s.W, H = s.H,
		goals = d.goals or {}, moves = d.moves, difficulty = d.difficulty, colors = d.colors or {},
		run = s.info.run, standalone = s.info.standalone,
	}
end

function M.targeting()
	local b = M.board
	return b and b.input.targeting or nil
end

-- Starts a booster: target mode for the three that need a target, at once
-- for remix. The HUD checks the inventory first; the meta is charged by the
-- board when the core accepts the booster (session hook booster_used).
function M.booster(id)
	local b = M.board
	if not b then return false, "no_board" end
	if id == "remix" then
		local cmd = { type = "booster", booster = "remix" }
		local ok, res = b.session:command(cmd)
		M.sent(cmd, ok, res)
		if not ok then return false, res end
		return true
	end
	if b.session.paused then return false, "busy" end
	if not b.input:target(id) then return false, "bad_booster" end
	if b.on_booster then b.on_booster(id, "target") end
	return true
end

function M.cancel_booster()
	local b = M.board
	if not b or not b.input.targeting then return false end
	local id = b.input.targeting
	b.input:cancel_target()
	if b.on_booster then b.on_booster(id, "cancel") end
	return true
end

function M.pause(on)
	local b = M.board
	if not b then return false end
	b.session:set_paused(on)
	if on then b.input:cancel() end
	return true
end

local function run(cmd)
	local b = M.board
	if not b then return false, "no_board" end
	return b.session:command(cmd)
end

function M.skip()
	return run({ type = "skip" })
end

function M.continue(moves, riff)
	return run({ type = "continue", moves = moves or 5, riff = riff and true or false })
end

function M.give_up()
	return run({ type = "give_up" })
end

function M.cell_center(x, y)
	local b = M.board
	if not b or not b.geom then return nil end
	return b.geom:center(x, y)
end

function M.view()
	local b = M.board
	return b and b.view or nil
end

-- The same table is handed out while the board stays where it is (a new one when it moved or
-- resized), so a caller can ask every frame without garbage and compare rectangles by identity.
-- Read-only.
local rect_cache = nil

function M.board_rect()
	local b = M.board
	if not b or not b.geom then return nil end
	local r = b.geom.rect
	local c = rect_cache
	if not (c and c.x0 == r.x0 and c.y0 == r.y0 and c.x1 == r.x1 and c.y1 == r.y1 and c.cell == r.cell) then
		c = { x0 = r.x0, y0 = r.y0, x1 = r.x1, y1 = r.y1, cell = r.cell }
		rect_cache = c
	end
	return c
end

-- queries for the tutorial ---------------------------------------------------------------------

function M.stable()
	local b = M.board
	return b ~= nil and b.session.game:is_stable()
end

-- The object in core cell (x, y): {kind, special, state, pinned}, or nil.
function M.piece(x, y)
	local b = M.board
	if not b then return nil end
	local list = b.session.game:pieces()
	for i = 1, #list do
		local p = list[i]
		if p.x == x and p.y == y then
			return { kind = p.kind, special = p.special, state = p.state, pinned = p.pinned and true or false, item = p.item }
		end
	end
	return nil
end

-- "ok" | "fail" | "reject": what a swap would do now (core game:can_swap).
function M.can_swap(from, to)
	local b = M.board
	if not b then return nil end
	return b.session.game:can_swap(from, to)
end

-- The idle, free special pieces: {{x, y}, ...}.
function M.specials()
	local b = M.board
	local out = {}
	if not b then return out end
	local list = b.session.game:pieces()
	for i = 1, #list do
		local p = list[i]
		if p.kind == "special" and p.state == "idle" and not p.pinned then out[#out + 1] = { p.x, p.y } end
	end
	return out
end

-- The core's own pick: {from, to} | {at} | nil.
function M.core_hint()
	local b = M.board
	return b and b.session.game:hint() or nil
end

-- the guard --------------------------------------------------------------------------------------

function M.set_guard(g)
	guard_ref = type(g) == "table" and g or nil
end

function M.clear_guard()
	guard_ref = nil
end

function M.guard()
	return guard_ref
end

-- Calls guard function `name`; a guard that raises an error is dropped.
local function ask(name, default, ...)
	local g = guard_ref
	local fn = g and g[name]
	if not fn then return default end
	local ok, res = pcall(fn, ...)
	if ok then return res end
	guard_ref = nil
	if M.on_guard_error then M.on_guard_error(name, res) end
	return default
end

function M.allow_cell(x, y)
	return ask("cell", true, x, y) ~= false
end

function M.allow_command(cmd)
	return ask("command", true, cmd) ~= false
end

function M.allow_booster(id)
	return ask("booster", true, id) ~= false
end

-- The hint the board shows: its own pick, or whatever the guard makes of it
-- (nil: no hint).
function M.hint(cmd)
	return ask("hint", cmd, cmd)
end

function M.sent(cmd, ok, res)
	ask("sent", nil, cmd, ok, res)
end

return M
