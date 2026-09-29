-- Sources and hits (1.4.5-1.4.7, section 7), scores and goals (7.4).
--
-- A hit collects its score and goal changes in an accumulator and emits
-- them at its end in the causal order of section 16:
--   own special removed -> wires -> slot -> floor -> score -> goal -> state.

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local sched = require("core.sched")

local H = {}

local K_REGULAR, K_SPECIAL, K_MIC, K_BLOCKER = C.K_REGULAR, C.K_SPECIAL, C.K_MIC, C.K_BLOCKER
local S_IDLE, S_CLEAR, S_ARMED = C.S_IDLE, C.S_CLEAR, C.S_ARMED
local SRC_MATCH, SRC_ADJ, SRC_EFFECT = C.SRC_MATCH, C.SRC_ADJ, C.SRC_EFFECT

-- Sources ------------------------------------------------------------------

function H.new_source(s, kind, mv, wv, color)
	local id = s.next_source_id
	s.next_source_id = id + 1
	local src = {
		id = id, kind = kind, mv = mv, wv = wv, color = color or 0,
		all_layers = false, own = {}, centre = 0, keys = {}, reserves = {}, nrec = 0,
	}
	s.sources[id] = src
	return src
end

-- Accumulator ----------------------------------------------------------------

function H.acc()
	return { score = 0, goals = {} }
end

-- Decrements goal (gtype, param) by n; remembers it for the goal events.
function H.goal(s, acc, gtype, param, n)
	local k = B.goal_index(s, gtype, param)
	if not k then return end
	local left = s.goal_left[k]
	if left <= 0 then return end
	left = left - (n or 1)
	if left < 0 then left = 0 end
	s.goal_left[k] = left
	acc.goals[k] = true
end

local function all_goals_done(s)
	for k = 1, #s.goal_left do
		if s.goal_left[k] > 0 then return false end
	end
	return true
end

-- Emits score (one event, at cell), then goal events by index, then the
-- state change if the last goal was just met.
function H.flush(s, acc, cell)
	if acc.score > 0 then
		s.score = s.score + acc.score
		local x, y = U.xy(s.W, cell)
		E.emit(s, "score", { delta = acc.score, total = s.score, x = x, y = y })
		acc.score = 0
	end
	local any = false
	for k = 1, #s.goal_left do
		if acc.goals[k] then
			E.emit(s, "goal", { index = k, left = s.goal_left[k] })
			acc.goals[k] = nil
			any = true
		end
	end
	if any and s.state == C.G_PLAYING and all_goals_done(s) then
		E.set_state(s, C.G_WON_WAIT)
	end
end

-- Destruction ----------------------------------------------------------------

-- Puts an object into `clear` for T.clear (it vanishes in step 4).
function H.start_clear(s, o)
	B.set_state(o, S_CLEAR)
	o.tk = C.TM_CLEAR
	o.td = s.now + B.T(s).clear
	o.offx, o.offy, o.vy, o.delay = 0, 0, 0, 0
end

local function clear_event(s, o, cell, cause)
	local x, y = U.xy(s.W, cell)
	local ev = { id = o.id, x = x, y = y, kind = C.KIND_NAME[o.kind], cause = cause }
	if o.color ~= 0 then ev.color = C.COLOR_NAME[o.color] end
	if o.special ~= 0 then ev.special = C.SPECIAL_NAME[o.special] end
	E.emit(s, "clear", ev)
end

-- Destroys a regular piece (match or effect hit). `instant`: the piece in
-- the cell of a new special leaves the slot at once, without `clear` (6.3).
local function destroy_regular(s, o, cell, src, acc, instant)
	if instant then
		B.set_state(o, S_CLEAR)
		B.remove(s, o)
	else
		H.start_clear(s, o)
	end
	B.set_vac(s, cell, src.mv, src.wv)
	if src.kind == SRC_MATCH then
		acc.score = acc.score + C.SCORE_WAVE * src.wv
	else
		acc.score = acc.score + C.SCORE_EFFECT
	end
	H.goal(s, acc, C.GOAL_COLLECT, o.color, 1)
	clear_event(s, o, cell, src.kind == SRC_MATCH and "match" or "effect")
end

local function floor_hit(s, cell, acc)
	local hp = s.floor[cell] - 1
	s.floor[cell] = hp
	acc.score = acc.score + C.SCORE_HP
	local x, y = U.xy(s.W, cell)
	E.emit(s, "hit", { x = x, y = y, layer = "floor", hp = hp })
	if hp == 0 then
		E.emit(s, "floor_lit", { x = x, y = y })
		H.goal(s, acc, C.GOAL_LIGHT, 0, 1)
	end
end

-- Does source kind `src` break blocker o? (table 7.3)
local function breaks(o, src)
	local k = src.kind
	if k == SRC_EFFECT then return true end
	if k ~= SRC_ADJ then return false end
	local b = o.blocker
	if b == C.BK_CONCRETE then return false end
	if b == C.BK_BALLOON then return src.color == o.color end
	return true
end

-- Hit on an intact blocker. Returns destroyed, floors_done.
local function blocker_hit(s, o, cell, src, acc)
	if not breaks(o, src) then return false, false end
	local was_noise = o.blocker == C.BK_NOISE and o.hp > 0
	o.hp = o.hp - 1
	acc.score = acc.score + C.SCORE_HP
	if was_noise then
		local e = B.eom_entry(s, src.mv)
		if e then e.noise_hit = true end
	end
	local x, y = U.xy(s.W, o.cell)
	local item = C.BLOCKER_NAME[o.blocker]
	if o.hp > 0 then
		E.emit(s, "hit", { x = x, y = y, layer = "blocker", item = item, hp = o.hp })
		return false, false
	end
	E.emit(s, "destroy", { id = o.id, x = x, y = y, item = item })
	H.start_clear(s, o)
	local cells = B.cells_of(s, o)
	for k = 1, #cells do B.set_vac(s, cells[k], src.mv, src.wv) end
	H.goal(s, acc, C.GOAL_BREAK, o.blocker, 1)
	if o.blocker == C.BK_COLUMN and not src.all_layers then
		for k = 1, #cells do
			if s.floor[cells[k]] > 0 then floor_hit(s, cells[k], acc) end
		end
		return true, true
	end
	return true, false
end

-- Chain launch (7.2.1, 8.6): armed now, activation after T.chain with the
-- label of the hitting source.
function H.launch(s, o, delay, mv, wv, partner, X)
	B.set_state(o, S_ARMED)
	o.tk, o.td = 0, 0
	sched.push(s, s.now + delay, C.R_ACTIVATE, { o.id, o.cell, partner or 0, mv, wv, X or 0 })
end

-- Step 0 of 7.1: the first hit of a source on its centre removes its own
-- armed specials (7.2.4).
local function remove_own(s, src)
	local own = src.own
	for k = 1, #own do
		local o = s.objs[own[k]]
		if o and o.state == S_ARMED then
			H.start_clear(s, o)
			B.set_vac(s, o.cell, src.mv, src.wv)
			clear_event(s, o, o.cell, "fired")
		end
	end
	src.own = {}
end

-- The hit (7.1). opt_instant: the piece is removed without `clear` (the
-- cell of a new special in 6.3).
function H.hit(s, cell, src, opt_instant)
	local o = B.get(s, cell)
	if o and o.pins[1] then B.unpin(o, src.id) end
	-- 0. own specials
	if src.centre == cell and src.own[1] then
		remove_own(s, src)
	end
	-- deduplication by object key
	local key = B.key(s, cell)
	local slot_ok = true
	if not U.sorted_add(src.keys, key) then
		if not src.all_layers then return end
		slot_ok = false
	end
	local acc = H.acc()
	-- 1. openness, fixed before the slot is touched
	local open = B.is_open(o)
	local destroyed, floors_done = false, false
	-- 2. wires
	if s.wires[cell] > 0 then
		if src.kind == SRC_ADJ then return end
		local hp = s.wires[cell] - 1
		s.wires[cell] = hp
		acc.score = acc.score + C.SCORE_HP
		local x, y = U.xy(s.W, cell)
		E.emit(s, "hit", { x = x, y = y, layer = "wires", hp = hp })
		if hp == 0 then
			if o then
				E.emit(s, "freed", { id = o.id, x = x, y = y })
				B.raise_label(s, o, src.mv, src.wv)
			end
			if not s.in_group then s.dirty = true end
		end
		if not src.all_layers then
			H.flush(s, acc, cell)
			return
		end
		if hp > 0 then slot_ok = false end
	end
	-- 3. slot
	if slot_ok and not open then
		local k = o.kind
		if k == K_REGULAR then
			if src.kind ~= SRC_ADJ then
				destroy_regular(s, o, cell, src, acc, opt_instant)
				destroyed = true
			end
		elseif k == K_SPECIAL then
			if src.kind == SRC_EFFECT then
				H.launch(s, o, B.T(s).chain, src.mv, src.wv, 0, 0)
			end
		elseif k == K_BLOCKER then
			destroyed, floors_done = blocker_hit(s, o, cell, src, acc)
		end
		-- K_MIC: nothing
	end
	-- 4. floor
	if not floors_done and s.floor[cell] > 0
		and (destroyed or (src.kind == SRC_EFFECT and open) or src.all_layers) then
		floor_hit(s, cell, acc)
	end
	H.flush(s, acc, cell)
end

return H
