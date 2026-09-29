-- Event buffer (section 16) and game-state changes.
--
-- Events are plain tables appended to s.ev; every event gets `t` (the tick
-- being executed, or tick + 1 for commands) and `type`. Enumerations are
-- given as strings: the client reads them, the logic never does.

local C = require("core.const")

local E = {}

function E.emit(s, ty, ev)
	ev = ev or {}
	ev.t = s.now
	ev.type = ty
	local buf = s.ev
	buf[#buf + 1] = ev
	return ev
end

-- Changes the game state and emits `state` (the event goes right after the
-- event that caused it). Leaving out_of_moves clears the `stuck` flag.
function E.set_state(s, st, reason)
	if s.state == st then return end
	if s.state == C.G_OUT then s.stuck = false end
	s.state = st
	local ev = { state = C.GAME_NAME[st] }
	if reason then ev.reason = reason end
	E.emit(s, "state", ev)
end

return E
