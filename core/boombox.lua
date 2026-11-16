-- The boombox (10.10): a blocker that answers back.
--
-- It takes hits exactly like a record box (7.3). Every hp unit it loses to an `adjacent` hit makes it
-- "play" the colour of that group: C.BLAST free regular pieces of the colour elsewhere on the board are
-- cleared by `effect` hits (C.BLAST_LAST when the hit destroys the boombox). A hit of a special or a
-- booster has no colour and plays nothing.
--
-- hits.lua only notes the play on the adjacent source (src.boom: cells, src.boom_last: 0/1, in the order
-- of the hits, that is by cell index); match.lua calls BX.play at step 4a of 6.3, after the last adjacent
-- hit of the group. Nothing here runs, and no random number is drawn, on a level without boomboxes.

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local R = require("core.rng")
local H = require("core.hits")

local BX = {}

-- Candidates of a play, ascending cell index: regular idle pieces of `color` that are free (no wires, no
-- chain, no ice, not pinned, not under a closed curtain) and stand outside every group of the running search.
function BX.candidates(s, color, busy)
	local out = {}
	for i = 1, s.N do
		if not busy[i] and s.wires[i] == 0 and not B.veiled(s, i) then
			local o = B.get(s, i)
			if o and o.kind == C.K_REGULAR and o.state == C.S_IDLE and o.color == color
				and o.chain == 0 and o.ice == 0 and not o.pins[1] then
				out[#out + 1] = i
			end
		end
	end
	return out
end

-- The plays noted by adjacent source `src` (label mv, wv; group colour). `busy`: set of the cells of all
-- groups of this search.
function BX.play(s, src, busy)
	local boom, last = src.boom, src.boom_last
	if not boom then return end
	local W = s.W
	for k = 1, #boom do
		local cell = boom[k]
		local want = last[k] == 1 and C.BLAST_LAST or C.BLAST
		local cands = BX.candidates(s, src.color, busy)
		-- one draw of the `effects` stream per target, each among the candidates left (3.2.1)
		local targets = {}
		while #targets < want and #cands > 0 do
			local j = R.int(s.rng[R.EFFECTS], #cands)
			targets[#targets + 1] = cands[j]
			table.remove(cands, j)
		end
		table.sort(targets) -- numbers
		local cells = {}
		for j = 1, #targets do
			local tx, ty = U.xy(W, targets[j])
			cells[j] = { tx, ty }
		end
		local x, y = U.xy(W, cell)
		local ev = { x = x, y = y, color = C.COLOR_NAME[src.color], cells = cells }
		local box = B.get(s, cell) -- (a destroyed boombox is still in its slot, in `clear`)
		if box then ev.id = box.id end
		if last[k] == 1 then ev.last = true end
		E.emit(s, "boombox", ev)
		if #targets > 0 then
			-- a source of its own: the clears are `effect` hits with the label of the group; it never
			-- carries the carpet (its origin is a blocker cell, which the carpet cannot cover, 10.8)
			local es = H.new_source(s, C.SRC_EFFECT, src.mv, src.wv, src.color)
			for j = 1, #targets do H.hit(s, targets[j], es) end
			s.sources[es.id] = nil
		end
	end
	src.boom, src.boom_last = nil, nil
end

return BX
