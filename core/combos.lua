-- Combos (8.5): a swap of two specials, centre = cell `to`.
--
-- One combo effect is one source whose `own` holds both armed specials
-- (the one in `to` first) and whose `centre` is `to`; its first hit on the
-- centre removes both (7.2.4). The Bird's cargo and the specials made by
-- "Colour X" get sources of their own with the combo's label.
--
--   riff+riff   Cross          sub+sub     Bass drop     bird+bird   Trio
--   riff+sub    Triple cross   bird+riff   Bird carries a Riff
--   disco+disco Grand finale   bird+sub    Bird carries a Sabwoofer
--   disco+X     Colour X -> X (X = riff, sub or bird)

local C = require("core.const")
local U = require("core.util")
local B = require("core.board")
local E = require("core.events")
local H = require("core.hits")
local EF = require("core.effects")
local BD = require("core.bird")

local CB = {}

local SP_RIFF, SP_SUB, SP_BIRD, SP_DISCO = C.SP_RIFF, C.SP_SUB, C.SP_BIRD, C.SP_DISCO
local K_REGULAR, K_SPECIAL, S_IDLE, S_ARMED = C.K_REGULAR, C.K_SPECIAL, C.S_IDLE, C.S_ARMED
local R_HIT = C.R_HIT

-- Combo name (the `combo` field of `activate`) by the two special codes,
-- smaller code first.
local NAME = {
	[SP_RIFF] = { [SP_RIFF] = "cross", [SP_SUB] = "triple_cross", [SP_BIRD] = "bird_riff", [SP_DISCO] = "color_riff" },
	[SP_SUB] = { [SP_SUB] = "bass_drop", [SP_BIRD] = "bird_sub", [SP_DISCO] = "color_sub" },
	[SP_BIRD] = { [SP_BIRD] = "trio", [SP_DISCO] = "color_bird" },
	[SP_DISCO] = { [SP_DISCO] = "finale" },
}

function CB.name(a, b)
	if a > b then a, b = b, a end
	return NAME[a][b]
end

-- Cross (riff+riff): the Riff of both axes from the centre.
local function cross(s, src, cell)
	local t0 = s.now
	local x, y = U.xy(s.W, cell)
	for dir = 1, 4 do EF.bolt(s, x, y, dir, t0) end
	local g = {}
	EF.geo_add(g, cell, 0)
	for dir = 1, 4 do EF.ray(s, g, x, y, dir, 0) end
	EF.run(s, src, EF.geo_hits(s, src, g), true)
end

-- Triple cross (riff+sub): bolts along rows y-1..y+1, each leaving
-- (x, y+k), and columns x-1..x+1, each leaving (x+k, y); a cell at distance
-- d from the exit point along its bolt at t0 + sub_swell + R(d). Rows and
-- columns outside the field have no bolt.
local function triple_cross(s, src, cell)
	local t0 = s.now
	local W, Hh = s.W, s.H
	local base = EF.NT.sub_swell
	local at = EF.at(s, t0, base)
	local x, y = U.xy(W, cell)
	local g = {}
	for k = -1, 1 do
		local yy = y + k
		if yy >= 1 and yy <= Hh then
			EF.bolt(s, x, yy, EF.D_L, at)
			EF.bolt(s, x, yy, EF.D_R, at)
			if s.exists[(yy - 1) * W + x] then EF.geo_add(g, (yy - 1) * W + x, base) end
			EF.ray(s, g, x, yy, EF.D_L, base)
			EF.ray(s, g, x, yy, EF.D_R, base)
		end
	end
	for k = -1, 1 do
		local xx = x + k
		if xx >= 1 and xx <= W then
			EF.bolt(s, xx, y, EF.D_U, at)
			EF.bolt(s, xx, y, EF.D_D, at)
			if s.exists[(y - 1) * W + xx] then EF.geo_add(g, (y - 1) * W + xx, base) end
			EF.ray(s, g, xx, y, EF.D_U, base)
			EF.ray(s, g, xx, y, EF.D_D, base)
		end
	end
	EF.run(s, src, EF.geo_hits(s, src, g), true)
end

-- Grand finale (disco+disco): every existing cell, ring r at
-- t0 + finale_pause + ring*r; the source hits all layers.
local function finale(s, src, cell)
	local t0 = s.now
	local NT = EF.NT
	local W = s.W
	local x, y = U.xy(W, cell)
	src.all_layers = true
	local g, rmax = {}, 0
	for i = 1, s.N do
		if s.exists[i] then
			local xx, yy = U.xy(W, i)
			local r = math.max(math.abs(xx - x), math.abs(yy - y))
			if r > rmax then rmax = r end
			g[i] = NT.finale_pause + NT.ring * r
		end
	end
	for r = 0, rmax do
		E.emit(s, "ring", { x = x, y = y, r = r, at = EF.at(s, t0, NT.finale_pause + NT.ring * r) })
	end
	EF.run(s, src, EF.geo_hits(s, src, g), true)
end

-- Colour X -> specials (disco + riff/sub/bird).
local function colour_x(s, src, o, po, X)
	local t0 = s.now
	local NT = EF.NT
	local W = s.W
	local to, from = o.cell, po.cell
	local cx, cy = U.xy(W, to)
	local L = {}
	if X ~= 0 then
		for i = 1, s.N do
			local p = B.get(s, i)
			if p and p.kind == K_REGULAR and p.color == X and p.state == S_IDLE
				and p.pins[1] == nil and s.wires[i] == 0 then
				local px, py = U.xy(W, i)
				L[#L + 1] = { math.max(math.abs(px - cx), math.abs(py - cy)), p }
			end
		end
		U.stable_sort(L, function(e) return e[1] end)
	end
	local n = #L
	for k = 1, n do B.pin(L[k][2], src.id) end
	local acts = {}
	-- natural order: transforms by k, hits on `to` and `from`, fires by k
	for k = 0, n - 1 do
		acts[#acts + 1] = { EF.at(s, t0, NT.transform_step * k), C.R_TRANSFORM, { src.id, k, L[k + 1][2].id } }
	end
	local t_end = EF.at(s, t0, NT.transform_step * n)
	acts[#acts + 1] = { t_end, R_HIT, { src.id, to } }
	acts[#acts + 1] = { t_end, R_HIT, { src.id, from } }
	for k = 0, n - 1 do
		local p = L[k + 1][2]
		local due = EF.at(s, t0, NT.transform_step * (n - 1) + NT.fire_step * (k + 1))
		acts[#acts + 1] = { due, C.R_ACTIVATE, { p.id, p.cell, 0, src.mv, src.wv, 0 } }
	end
	EF.run(s, src, acts, false)
end

-- The combo of the armed specials o (in `to`) and po (in `from`); src is
-- the combo source (own = {o, po}, centre = to).
function CB.run(s, src, o, po)
	local a, b = o.special, po.special
	local lo, hi = a, b
	if lo > hi then lo, hi = hi, lo end
	local cell = o.cell
	local extra = { combo = NAME[lo][hi], partner = po.id }
	local X = 0
	if hi == SP_DISCO and lo ~= SP_DISCO then
		X = B.most_frequent(s, true)
		if X ~= 0 then extra.color = C.COLOR_NAME[X] end
	end
	EF.activate_event(s, o.id, cell, a, o.axis, extra)
	if lo == hi then
		if lo == SP_RIFF then cross(s, src, cell)
		elseif lo == SP_SUB then EF.sub(s, src, cell, 3)
		elseif lo == SP_BIRD then BD.trio(s, src, cell)
		else finale(s, src, cell) end
	elseif hi == SP_DISCO then
		colour_x(s, src, o, po, X)
	elseif hi == SP_SUB then -- riff + sub
		triple_cross(s, src, cell)
	else -- bird + riff or bird + sub
		local cargo = lo == SP_RIFF and BD.CARGO_RIFF or BD.CARGO_SUB
		local riff = a == SP_RIFF and o or po
		BD.carry(s, src, cell, cargo, cargo == BD.CARGO_RIFF and riff.axis or 0)
	end
end

-- Record kind 4: transform k of "Colour X", {source, k, piece id}. The kind
-- of the new specials is the combo's non-disco special, still armed in
-- `own` (the transforms all come before the first hit on the centre).
function CB.transform(s, d)
	local src = s.sources[d[1]]
	local k = d[2]
	local p = s.objs[d[3]]
	if not p or not B.is_pinned_by(p, src.id) then return end
	local kind = 0
	for j = 1, #src.own do
		local q = s.objs[src.own[j]]
		if q and q.special ~= SP_DISCO then kind = q.special end
	end
	if kind == 0 then return end
	local X = p.color
	p.kind = K_SPECIAL
	p.special = kind
	p.axis = 0
	if kind == SP_RIFF then p.axis = (k % 2 == 0) and C.AX_H or C.AX_V end
	p.color = 0
	B.set_state(p, S_ARMED)
	p.tk, p.td = 0, 0
	local x, y = U.xy(s.W, p.cell)
	local ev = { id = p.id, x = x, y = y, special = C.SPECIAL_NAME[kind] }
	if p.axis ~= 0 then ev.axis = C.AXIS_NAME[p.axis] end
	E.emit(s, "transform", ev)
	local acc = H.acc()
	acc.score = C.SCORE_TRANSFORM
	H.goal(s, acc, C.GOAL_COLLECT, X, 1)
	H.flush(s, acc, p.cell)
end

return CB
