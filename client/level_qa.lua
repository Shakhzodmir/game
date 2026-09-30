-- QA bridge commands of the level board (client/qa_bridge.lua), registered
-- while a board is on display (screens/level/board.script):
--
--   hint_move                   plays the hint move (swap or tap)
--   swap x1 y1 x2 y2            a swap command (core cells, 1-based)
--   tap x y                     a tap on a special
--   skip                        skips the final concert (turbo)
--   booster <id> [x y | row | col], continue [n] [riff], give_up
--   state                       the app state + {level = board snapshot}
--   level_stats                 sprites, particles, effects, frame counters of the board
--
-- Commands go through the same session as touches, so the meta hooks
-- (first move, boosters), sounds and effects all run.
--
--   local off = level_qa.register(board)   -- board = {session, stats = fn() -> table}
--   off()                                  -- in final()

local qa_bridge = require("client.qa_bridge")

local M = {}

M.COMMANDS = { "hint_move", "swap", "tap", "skip", "booster", "continue", "give_up" }

function M.handlers(board)
	local h = {}
	for _, name in ipairs(M.COMMANDS) do
		h[name] = function(args)
			local s = board.session
			if not s then return { ok = false, error = "no_board" } end
			local res = s:qa(name, args)
			if board.on_qa then board.on_qa(name, res) end
			return res
		end
	end
	h.state = function(args, cmd, prev)
		local res = prev and prev(args, cmd) or { ok = true }
		if type(res) ~= "table" then res = { ok = res ~= false } end
		local s = board.session
		res.level = s and s:snapshot() or nil
		if board.stats then res.board = board.stats() end
		return res
	end
	h.level_stats = function()
		local s = board.session
		return { ok = s ~= nil, level = s and s:snapshot() or nil, board = board.stats and board.stats() or nil }
	end
	return h
end

function M.register(board)
	return qa_bridge.register(M.handlers(board))
end

return M
