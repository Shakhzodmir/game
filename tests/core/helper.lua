-- Shared fixtures for the core tests (not a test file itself).
--
-- H.level(rows, extra) builds a level table in the JSON format from a
-- picture, one character per cell:
--   .   void                 #   cell filled at random at the start
--   r o y g b p   a preset regular piece ("piece") of that colour
--   R   riff h   V riff v   S sub   B bird   D disco   M mic
--   X   record_box hp 1     K concrete hp 1   N noise
--   A..F  balloon red/orange/yellow/green/blue/purple
-- `extra` overrides or adds top-level keys (goals, moves, floor, ...).
-- H.load(...) validates it through core.load_level and fails the test on
-- errors; H.game(...) also starts a game.

local core = require("core.game")

local H = {}

local PIECE = { r = "red", o = "orange", y = "yellow", g = "green", b = "blue", p = "purple" }
local SPECIAL = { R = { type = "riff", axis = "h" }, V = { type = "riff", axis = "v" },
	S = { type = "sub" }, B = { type = "bird" }, D = { type = "disco" }, M = { type = "mic" },
	X = { type = "record_box", hp = 1 }, K = { type = "concrete", hp = 1 }, N = { type = "noise" },
	A = { type = "balloon", color = "red" }, E = { type = "balloon", color = "blue" } }

function H.level(rows, extra)
	local W, Hh = #rows[1], #rows
	local cells, slots = {}, {}
	for y = 1, Hh do
		local row = rows[y]
		assert(#row == W, "ragged picture")
		local line = {}
		for x = 1, W do
			local ch = string.sub(row, x, x)
			line[x] = ch == "." and "." or "#"
			local at = { x - 1, y - 1 }
			if PIECE[ch] then
				slots[#slots + 1] = { at = at, type = "piece", color = PIECE[ch] }
			elseif SPECIAL[ch] then
				local sl = { at = at }
				for k, v in pairs(SPECIAL[ch]) do sl[k] = v end
				slots[#slots + 1] = sl
			end
		end
		cells[y] = table.concat(line)
	end
	local lvl = {
		id = 1, version = 1, size = { W, Hh }, moves = 20, difficulty = "easy",
		colors = { "red", "orange", "yellow", "green", "blue", "purple" },
		goals = { { type = "collect", color = "red", count = 999 } },
		cells = cells, slots = slots,
	}
	for k, v in pairs(extra or {}) do lvl[k] = v end
	if extra and extra.slots then
		-- extra slots are added to the picture's slots
		local all = {}
		for _, sl in ipairs(slots) do all[#all + 1] = sl end
		for _, sl in ipairs(extra.slots) do all[#all + 1] = sl end
		lvl.slots = all
	end
	return lvl
end

function H.load(rows, extra)
	local lvl, errs = core.load_level(H.level(rows, extra))
	if not lvl then error("level rejected: " .. table.concat(errs, "; "), 2) end
	return lvl
end

function H.game(rows, extra, opts)
	local lvl = H.load(rows, extra)
	opts = opts or {}
	if opts.seed == nil then opts.seed = 1 end
	local g, errs = core.new(lvl, opts)
	if not g then error("game rejected: " .. table.concat(errs, "; "), 2) end
	return g, lvl
end

-- Picture of the board: colour letter for regular pieces, the special
-- letter for specials, '.' for empty/void, 'M' mic, '*' blocker.
function H.picture(g)
	local s = g.s
	local LET = { "r", "o", "y", "g", "b", "p" }
	local SP = { "R", "S", "B", "D" }
	local rows = {}
	for y = 1, s.H do
		local line = {}
		for x = 1, s.W do
			local i = (y - 1) * s.W + x
			local id = s.slot[i]
			local ch = "."
			if id ~= 0 then
				local o = s.objs[id]
				if o.kind == 1 then ch = LET[o.color] or "?"
				elseif o.kind == 2 then ch = SP[o.special]
				elseif o.kind == 3 then ch = "M"
				else ch = "*" end
			end
			line[x] = ch
		end
		rows[y] = table.concat(line)
	end
	return rows
end

function H.obj_at(g, x, y)
	local s = g.s
	local id = s.slot[(y - 1) * s.W + x]
	if id == 0 then return nil end
	return s.objs[id]
end

-- Rebuilds every object of a live game from a picture (test setup only):
-- same letters as H.level, '_' = empty slot of an existing cell, '.' =
-- void (must match the level), 'L' = column (hp 6) with 'l' in its other
-- three cells. Ids are given by ascending cell, labels and
-- settle ticks are 0.
local COLOR = { r = 1, o = 2, y = 3, g = 4, b = 5, p = 6 }
local SPEC = { R = { 1, 1 }, V = { 1, 2 }, S = { 2, 0 }, B = { 3, 0 }, D = { 4, 0 } }
local BLOCK = { X = { 1, 1, 0 }, K = { 2, 1, 0 }, N = { 3, 1, 0 }, A = { 4, 1, 1 }, E = { 4, 1, 5 } }
function H.board(g, rows)
	local s = g.s
	s.objs = {}
	for i = 1, s.N do s.slot[i] = 0 end
	local id = 0
	for y = 1, s.H do
		for x = 1, s.W do
			local i = (y - 1) * s.W + x
			local ch = string.sub(rows[y], x, x)
			if ch == "." then
				assert(not s.exists[i], "void expected at " .. x .. "," .. y)
			else
				assert(s.exists[i], "cell expected at " .. x .. "," .. y)
			end
			local o = nil
			if ch == "L" then o = { kind = 4, blocker = 5, hp = 6 }
			elseif COLOR[ch] then o = { kind = 1, color = COLOR[ch] }
			elseif SPEC[ch] then o = { kind = 2, special = SPEC[ch][1], axis = SPEC[ch][2] }
			elseif ch == "M" then o = { kind = 3 }
			elseif BLOCK[ch] then o = { kind = 4, blocker = BLOCK[ch][1], hp = BLOCK[ch][2], color = BLOCK[ch][3] }
			end
			if o then
				id = id + 1
				local full = {
					id = id, kind = o.kind, color = o.color or 0, special = o.special or 0, axis = o.axis or 0,
					blocker = o.blocker or 0, hp = o.hp or 0, state = 1, cell = i, mv = 0, wv = 0,
					offx = 0, offy = 0, vy = 0, delay = 0, settle = 0, tk = 0, td = 0, pins = {},
				}
				s.objs[id] = full
				s.slot[i] = id
				if ch == "L" then
					s.slot[i + 1], s.slot[i + s.W], s.slot[i + s.W + 1] = id, id, id
				end
			end
		end
	end
	s.next_piece_id = id + 1
	s.dirty = false
	s.rest_flag = true
end

-- Events of one type from a list.
function H.of_type(events, ty)
	local out = {}
	for _, e in ipairs(events) do
		if e.type == ty then out[#out + 1] = e end
	end
	return out
end

-- Steps n ticks and returns all events.
function H.steps(g, n)
	local all = {}
	for _ = 1, n do
		g:step()
		for _, e in ipairs(g:drain_events()) do all[#all + 1] = e end
	end
	return all
end

return H
