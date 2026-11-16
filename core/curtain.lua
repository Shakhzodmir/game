-- The timed curtain (10.7): the phase all curtains of a level share.
--
-- s.cur_closed -- are the curtains closed now; s.cur_left -- moves left until
-- the next change. Both stay false / 0 on a level without curtains, where
-- nothing here is ever called. The cells are static (level.curtain.at); what
-- "closed" means for a cell is spread over the modules through B.veiled.
--
-- The phase changes only in step 8, on a board at rest (flow.lua): nothing
-- is in flight, pinned or queued when a curtain closes over a cell.

local U = require("core.util")
local E = require("core.events")

local CU = {}

-- Sets the phase, restarts its count and emits `curtain`. A curtain that
-- opens makes the board dirty: step 7 of the next tick finds the matches
-- that stood ready under it, and gravity takes the cells back.
-- reason: "move" | "deadlock" | "concert".
function CU.set(s, closed, reason)
	local cu = s.level.curtain
	s.cur_closed = closed
	s.cur_left = closed and cu.closed_moves or cu.open_moves
	if not closed then s.dirty = true end
	local cells = {}
	for k = 1, #cu.cells do
		local x, y = U.xy(s.W, cu.cells[k])
		cells[k] = { x, y }
	end
	E.emit(s, "curtain", { phase = closed and "closed" or "open", cells = cells, left = s.cur_left, reason = reason })
end

-- n moves were spent (the end-of-move queue of step 8). Every move takes one
-- off the count; at 0 the phase changes. Returns true if the curtains are
-- open now and were opened here.
function CU.advance(s, n)
	local opened = false
	for _ = 1, n do
		s.cur_left = s.cur_left - 1
		if s.cur_left <= 0 then
			CU.set(s, not s.cur_closed, "move")
			opened = not s.cur_closed
		else
			E.emit(s, "curtain_left", { phase = s.cur_closed and "closed" or "open", left = s.cur_left })
		end
	end
	return opened
end

return CU
