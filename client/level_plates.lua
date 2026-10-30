-- What on the board cannot be moved, and how the board says so (pure Lua).
--
-- The core decides what may move (core-rules.md 1.1, 5.1.1, 5.2): a blocker (record box, concrete, noise,
-- balloon, the 2x2 column) never swaps, never taps and never falls, and a regular piece under wires stays
-- where it is (it still matches in place). Pieces, specials and microphones move. The client only has to look
-- different and to answer an attempt:
--
--   fixed-ness .... M.kind(p, wired) -> "blocker" | "wired" | nil: the one answer the input, the refusal
--                   feedback and the plates share (p = an entry of game:pieces(), wired = the cell has wires)
--   plates ........ a cool, sunken, bolted plate (board/plate.png) under every such object, drawn as a "mark"
--                   of client/level_view.lua below the object: one per cell, one at twice the size for the
--                   column. It goes with the object: it blooms in with it, shrinks away with a destroyed
--                   blocker and fades out when the wires are cut or the noise is gone
--   first refusal . M.first(kind): true once per session for each kind, the board then also shows a toast
--
--   local level_plates = require("client.level_plates")
--   local P = level_plates.new()
--   n = P:fill(list, n, pieces, cells, geom, anim, t, shake_x, shake_y)
--       -- appends the plates of this frame to list[n + 1 ..] (mark tables, reused: nothing is allocated
--       -- while the set of fixed objects stays the same) and returns the new n. pieces = game:pieces(),
--       -- cells = game:cells() (wires), geom = client/level_geom.lua, anim = client/level_anim.lua
--       -- (for how each object looks: the plate follows its bloom), t = real seconds
--   P:count()  -- plates in the last list
--   level_plates.reset()  -- forgets which first refusals were shown (tests)

local M = {}

M.IMAGE = "board_plate"   -- animation id in the game atlas; 160 art px per cell (board/plate.png)
M.ART = 160
M.Z = 0.03                -- under the blockers (0.08) and the glow marks (0.05)
M.ALPHA = 1.0
M.FADE_IN = 0.14          -- seconds a plate takes to appear (on top of the bloom of its object)
M.FADE_OUT = 0.2          -- seconds a plate takes to go once its object is gone (wires cut)
M.COLUMN_CELLS = 2

-- Toast of the first refusal, by kind (literal keys: tools/check_refs.lua follows them).
M.TOAST = { blocker = "level.fixed_blocker", wired = "level.fixed_wired" }

-- what makes an object fixed for good (not a passing state: falling, swapping, clearing, pinned pieces
-- refuse too, but they do not sit on a plate)
function M.kind(p, wired)
	if not p then return nil end
	if p.kind == "blocker" then return "blocker" end
	if wired and p.kind == "regular" then return "wired" end
	return nil
end

local shown = {}

-- true the first time it is asked for a kind in this session (the app runs as one Lua state)
function M.first(kind)
	if not kind or shown[kind] then return false end
	shown[kind] = true
	return true
end

function M.reset()
	for k in pairs(shown) do shown[k] = nil end -- order-independent
end

local Plates = {}
Plates.__index = Plates

function M.new()
	return setmetatable({ recs = {}, frame = 0, n = 0 }, Plates)
end

local function clamp01(v)
	if v < 0 then return 0 end
	if v > 1 then return 1 end
	return v
end

local function new_rec(key)
	return {
		key = key, image = M.IMAGE, iw = M.ART, ih = M.ART, glow = false, color = "#FFFFFF", z = M.Z, rot = 0,
		x = 0, y = 0, w = 1, h = 1, alpha = 0, base = 0, seen = 0, born = 0, gone = nil,
	}
end

function Plates:fill(list, n, pieces, cells, geom, anim, t, sx, sy)
	local start = n
	self.frame = self.frame + 1
	local fr = self.frame
	sx, sy = sx or 0, sy or 0
	if geom and pieces then
		local W, cell = geom.W, geom.cell
		local recs = self.recs
		for i = 1, #pieces do
			local p = pieces[i]
			local idx = (p.y - 1) * W + p.x
			local c = cells and cells[idx]
			local kind = M.kind(p, c ~= nil and (c.wires or 0) > 0)
			if kind and not p.hidden then
				-- how the object looks now: the plate blooms with it and shrinks with it, and waits while
				-- the noise creeps over a piece that is still drawn as it was
				local v = anim and anim:record(p.id)
				local e = v and v.out
				local k = 1
				if e then k = clamp01(e.sx or 1) end
				if v and v.hold_image and t < (v.hold_until or 0) then k = 0 end
				local rec = recs[idx]
				if k > 0 or rec then
					if not rec then
						rec = new_rec(idx)
						rec.born = t
						recs[idx] = rec
					end
					rec.seen, rec.gone = fr, nil
					local size = (p.item == "column") and M.COLUMN_CELLS or 1
					local lx, ly = geom:center(p.x, p.y)
					if size > 1 then lx, ly = lx + cell / 2, ly - cell / 2 end
					rec.x, rec.y = lx + sx, ly + sy
					rec.w, rec.h = cell * size * (0.9 + 0.1 * k), cell * size * (0.9 + 0.1 * k)
					rec.alpha = M.ALPHA * k * clamp01((t - rec.born) / M.FADE_IN)
					rec.base = rec.alpha
					if rec.alpha > 0 then
						n = n + 1
						list[n] = rec
					end
				end
			end
		end
		-- plates whose object is gone: they fade out where they stood
		for key, rec in pairs(recs) do -- order-independent
			if rec.seen ~= fr then
				if not rec.gone then rec.gone = t end
				local u = (t - rec.gone) / M.FADE_OUT
				if u >= 1 then
					recs[key] = nil
				else
					rec.alpha = rec.base * (1 - u) -- from where it was (a shrunk plate has nothing left to fade)
					if rec.alpha > 0 then
						n = n + 1
						list[n] = rec
					end
				end
			end
		end
	end
	self.n = n - start
	return n
end

function Plates:count()
	return self.n
end

return M
