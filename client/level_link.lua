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
--   link.board_rect()              -- {x0, y0, x1, y1, cell} of the cell grid
--   link.view()                    -- what the board background GUI draws (level_bg.gui_script):
--                                  --  {rev, geom, cells, floor0, floor_rev, lit = {[i] = t}, deliver,
--                                  --   shake_x, shake_y}; rev grows when the layout changed,
--                                  --   floor_rev when a floor tile was hit or lit
--
-- Bus topics published by the board (client/bus.lua; payloads are read-only):
--   level_ready    {level_id, W, H, moves, goals, rect}     the board is built
--   level_moves    {left}                                    moves left changed
--   level_goal     {index, left, x, y, lx, ly, kind, color, item}  a goal went down
--                  (lx, ly = where the collected thing was: fly it to the goal icon)
--   level_score    {delta, total, lx, ly}
--   level_state    {state, reason}                           game state changed
--   level_praise   {word, index (1..5, i18n "praise.<index>"), wave}
--   level_banner   {key}                                     e.g. "hud.shuffle"
--   level_booster  {booster, phase = "target" | "cancel" | "used" | "done", ok}
--   level_result   {result = game:result()}                  complete or lost
--   level_special  {special, combo, lx, ly}                  a special fired (Bit scratches)
--   level_flash    {color, alpha, dur}                       the whole screen flashes (fx GUI)
--   level_floor    {x, y, lx, ly}                            a dance-floor tile was lit

local M = {}

M.board = nil -- set by the board script: {session, input, geom, on_booster}

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
		local ok, res = b.session:command({ type = "booster", booster = "remix" })
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

function M.board_rect()
	local b = M.board
	if not b or not b.geom then return nil end
	local r = b.geom.rect
	return { x0 = r.x0, y0 = r.y0, x1 = r.x1, y1 = r.y1, cell = r.cell }
end

return M
