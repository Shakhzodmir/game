-- Touch input of the board (pure Lua): swipes, taps, the selection of
-- core-rules.md 5.5 (decisions.md, 6) and the booster targeting mode.
--
-- The module never changes the game: it turns touches into core commands
-- that the board checks (game:can_swap for swaps) and sends. It knows
-- nothing about rules beyond "what is in that cell", given by a query.
--
--   local level_input = require("client.level_input")
--   local inp = level_input.new({mode = "swipe" | "taptap", query = fn(x, y)})
--   -- query(x, y) -> nil (no object) or {id, kind = "regular"|"special"|"mic"|"blocker",
--   --                  state = "idle"|..., pinned = bool, wired = bool}
--   inp:press(fx, fy)          -- continuous cell coords (level_geom:frac), nil = off the board
--   local cmd = inp:move(fx, fy)    -- a swipe of 30% of a cell -> {type = "swap", from, to}
--   cmd = inp:release(fx, fy)       -- a tap -> {type = "swap" | "tap" | "booster", ...} or nil
--   inp:validate(find, playing)     -- drops a stale selection (every frame)
--   inp.selected                    -- {id, x, y} or nil
--   inp:target("stick" | "row_light" | "col_light")  -- the next tap picks a booster target
--   inp.hover                       -- {x, y} under the finger in target mode
--
-- Selection rules (5.5):
--   1. the selection belongs to a piece id and ends when that piece stops
--      being idle, leaves its cell, or the game leaves "playing";
--   2. with a piece S selected, a tap on a side neighbour N sends
--      swap{from = S, to = N}, whatever N is;
--   3. "swipe" mode: a tap on a special (nothing selected, or a selection
--      that is not adjacent) clears the selection and sends tap; a tap on a
--      regular piece or a microphone selects it; a tap on the selected piece
--      clears the selection;
--   4. "taptap" mode: the first tap on any piece selects it; a tap on the
--      selected special sends tap; a tap on a non-adjacent piece moves the
--      selection.
-- A swipe from a cell swaps it with its neighbour along the major axis
-- (swiping a special into a gap or a blocker is a tap: the core decides).
-- A tap off the board, on a gap or on a blocker clears the selection.

local M = {}

M.SWIPE = 0.3 -- share of a cell along the major axis that makes a swipe
M.MODES = { swipe = true, taptap = true }
M.TARGETS = { stick = "at", row_light = "row", col_light = "col" }

local Input = {}
Input.__index = Input

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		mode = M.MODES[opts.mode] and opts.mode or "swipe",
		query = opts.query or function() return nil end,
		selected = nil,  -- {id, x, y}
		pressed = nil,   -- {x, y, fx, fy, swiped}
		targeting = nil, -- booster id while picking a target
		hover = nil,     -- {x, y} in target mode
		enabled = true,
	}, Input)
end

function Input:set_mode(mode)
	if M.MODES[mode] then self.mode = mode end
end

local function cell_of(fx, fy)
	return math.floor(fx + 0.5), math.floor(fy + 0.5)
end

local function adjacent(ax, ay, bx, by)
	return math.abs(ax - bx) + math.abs(ay - by) == 1
end

function Input:deselect()
	self.selected = nil
end

-- A piece that may be selected: idle, not pinned, movable (no wires).
local function selectable(p, mode)
	if not p or p.state ~= "idle" or p.pinned or p.wired then return false end
	if p.kind == "regular" or p.kind == "mic" then return true end
	return mode == "taptap" and p.kind == "special"
end

local function launchable(p)
	return p and p.kind == "special" and p.state == "idle" and not p.pinned
end

-- Drops the selection when its piece is gone (rule 1). find(id) -> the
-- piece {x, y, state} or nil; playing = the game is in "playing".
function Input:validate(find, playing)
	local s = self.selected
	if not s then return end
	if not playing then
		self.selected = nil
		return
	end
	local p = find and find(s.id)
	if not p or p.state ~= "idle" or p.x ~= s.x or p.y ~= s.y then self.selected = nil end
end

-- Booster targeting --------------------------------------------------------------

-- Enters target mode: the next tap on the board picks the target. false for
-- a booster that needs no target (remix) or an unknown one.
function Input:target(booster)
	if not M.TARGETS[booster] then return false end
	self.targeting = booster
	self.hover = nil
	self.selected = nil
	self.pressed = nil
	return true
end

function Input:cancel_target()
	self.targeting = nil
	self.hover = nil
end

local function booster_cmd(booster, x, y)
	local field = M.TARGETS[booster]
	if field == "at" then return { type = "booster", booster = booster, at = { x, y } } end
	if field == "row" then return { type = "booster", booster = booster, row = y } end
	return { type = "booster", booster = booster, col = x }
end

-- Touches ------------------------------------------------------------------------

-- A finger went down at continuous cell coords (nil: off the board).
function Input:press(fx, fy)
	if not self.enabled then return end
	if fx == nil or fy == nil then
		self.pressed = nil
		self.hover = nil
		if not self.targeting then self.selected = nil end
		return
	end
	local x, y = cell_of(fx, fy)
	self.pressed = { x = x, y = y, fx = fx, fy = fy, swiped = false }
	if self.targeting then self.hover = { x = x, y = y } end
end

-- The finger moved. Returns a swap command once a swipe passes the
-- threshold, else nil.
function Input:move(fx, fy)
	local pr = self.pressed
	if not pr or pr.swiped or fx == nil or fy == nil then return nil end
	if self.targeting then
		local x, y = cell_of(fx, fy)
		self.hover = { x = x, y = y }
		return nil
	end
	local dx, dy = fx - pr.fx, fy - pr.fy
	local ax, ay = math.abs(dx), math.abs(dy)
	if math.max(ax, ay) < M.SWIPE then return nil end
	pr.swiped = true
	self.selected = nil
	local tx, ty = pr.x, pr.y
	if ax >= ay then tx = tx + (dx > 0 and 1 or -1) else ty = ty + (dy > 0 and 1 or -1) end
	return { type = "swap", from = { pr.x, pr.y }, to = { tx, ty } }
end

-- The tap rules at cell (x, y).
function Input:tap_cell(x, y)
	local p = self.query(x, y)
	local s = self.selected
	if s and adjacent(s.x, s.y, x, y) then
		self.selected = nil
		return { type = "swap", from = { s.x, s.y }, to = { x, y } }
	end
	if self.mode == "swipe" then
		if launchable(p) then
			self.selected = nil
			return { type = "tap", at = { x, y } }
		end
		if selectable(p, "swipe") then
			if s and s.id == p.id then
				self.selected = nil
			else
				self.selected = { id = p.id, x = x, y = y }
			end
			return nil
		end
		self.selected = nil
		return nil
	end
	-- taptap
	if s and p and s.id == p.id then
		self.selected = nil
		if launchable(p) then return { type = "tap", at = { x, y } } end
		return nil
	end
	if selectable(p, "taptap") then
		self.selected = { id = p.id, x = x, y = y }
		return nil
	end
	self.selected = nil
	return nil
end

-- The finger went up. Returns a command for a tap (or a booster target),
-- else nil. fx, fy may be nil (released off the board).
function Input:release(fx, fy)
	local pr = self.pressed
	self.pressed = nil
	if not pr or pr.swiped or not self.enabled then return nil end
	if self.targeting then
		local h = self.hover
		if fx ~= nil and fy ~= nil then
			local x, y = cell_of(fx, fy)
			h = { x = x, y = y }
		end
		self.hover = h
		if not h then return nil end
		return booster_cmd(self.targeting, h.x, h.y)
	end
	return self:tap_cell(pr.x, pr.y)
end

-- Forgets a touch in progress (the game paused, input blocked).
function Input:cancel()
	self.pressed = nil
end

return M
