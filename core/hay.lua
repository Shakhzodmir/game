-- The hay bale (10.12): a blocker that hides a special piece.
--
-- A hay bale is an ordinary one-cell blocker (code 7, hp 1-2) that takes hits
-- exactly like a record box (7.3). What is new is its end: a bale with a gift
-- does not leave an empty cell. The hit that destroys it puts it into `clear`
-- like any blocker (hits.lua draws a random gift there and stores the label of
-- the hit on the bale); the cell is an open slot from then on. In step 4 of
-- the first tick in which its clear timer has expired AND the queue of the
-- scheduler is empty (so no effect is in flight: neither the one that broke
-- the bale nor a chain it started), the bale vanishes and the special takes
-- its cell: a new object with a new id, idle, with the label of the
-- destroying hit. No hit of the wave that opened the bale can launch the gift.

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")

local HY = {}

-- Replaces the destroyed bale `o` (state clear, gift 1..5) by its gift.
function HY.reveal(s, o)
	local cell, gift, mv, wv, from = o.cell, o.gift, o.mv, o.wv, o.id
	B.remove(s, o)
	local special, axis = C.GIFT_SPECIAL[gift], C.GIFT_AXIS[gift]
	local n = B.new_obj(s, C.K_SPECIAL, { special = special, axis = axis, mv = mv, wv = wv, settle = s.now })
	B.place(s, n, cell)
	s.dirty = true -- a piece became idle (section 6)
	local x, y = U.xy(s.W, cell)
	local ev = { id = n.id, x = x, y = y, special = C.SPECIAL_NAME[special], from = from }
	if axis ~= 0 then ev.axis = C.AXIS_NAME[axis] end
	E.emit(s, "gift", ev)
end

return HY
