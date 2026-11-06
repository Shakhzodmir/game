-- The living details of a town room (data: content/rooms.json): blinking lights, steam, floating notes, drifting
-- specks (dust, sparkles, confetti, embers), beams of light and big soft lights in the foreground. Everything is a
-- looped gui.animate on a handful of nodes: nothing runs per frame, nothing is created while the room stands.
-- GUI context of screens/town/town.gui_script (the scene builds one Life per room).
--
--   local life = require("screens.town.life").new(ui, did, view, layers, done)
--     layers = {mid, over, fg}: containers (the scene's parallax layers); done = {[task id] = true}
--   life:wake(task_id)          -- the details of a task just restored come alive (a soft pop)
--   life:flare()                -- every light flares up and settles (a purchase)
--   life:celebrate(x, y)        -- a wave of light spreads over the room from (x, y), logical coordinates, y up
--   life:count()                -- GUI nodes in use (the budget of rooms.json is never exceeded)
--
-- A detail with `item` waits for that task to be restored; `view` limits it to the day or the concert look.
-- Under reduced motion the lights and beams stand still and the moving details are not made at all.

local fx = require("client.fx")

local M = {}

local data_cache

function M.data()
	if data_cache == nil then
		local ok, t = pcall(function()
			local raw = sys.load_resource("/content/rooms.json")
			return raw and json.decode(raw)
		end)
		data_cache = ok and type(t) == "table" and type(t.districts) == "table" and t or false
	end
	return data_cache or { districts = {}, budget = 0, parallax = {}, drift = {}, crossfade = 0.6 }
end

-- the most nodes one room may use (also the test's limit)
function M.budget()
	return M.data().budget or 44
end

local random_for -- deterministic placement: the same room always looks the same

local function lcg(seed)
	local s = seed % 2147483647
	if s <= 0 then s = s + 2147483646 end
	return function()
		s = (s * 48271) % 2147483647
		return s / 2147483647
	end
end

random_for = function(did, n)
	local seed = n
	for i = 1, #did do seed = seed * 31 + string.byte(did, i) end
	return lcg(seed)
end

local Life = {}
Life.__index = Life

local function rr(r, a, b) return a + (b - a) * r() end

local function pick(list, i) return list[(i - 1) % #list + 1] end

local function add_mode(n) gui.set_blend_mode(n, gui.BLEND_ADD) end

local function y_of(y) return 1280 - y end

-- builders: each returns the number of nodes it made ----------------------------------------------------------------------

local function blink(self, d, parent, r)
	local lo, hi = (d.alpha or { 0.35, 0.9 })[1], (d.alpha or { 0.35, 0.9 })[2]
	local n = 0
	for i, pt in ipairs(d.points) do
		if not self:room() then break end
		local node = self.ui:circle(parent, pt[1], y_of(pt[2]), (d.r or 30) * 2, pick(d.colors, i), { soft = true, alpha = hi })
		add_mode(node)
		self:take(1)
		n = n + 1
		local entry = { node = node, lo = lo, hi = hi, period = d.period or 1.6, delay = rr(r, 0, d.period or 1.6) }
		self.blinks[#self.blinks + 1] = entry
		if self.reduced then
			gui.set_color(node, self:_with_alpha(node, (lo + hi) / 2)) -- the tint stays, only the alpha moves
		else
			self:start_blink(entry, r)
		end
	end
	return n
end

function Life:start_blink(e)
	gui.set_color(e.node, self:_with_alpha(e.node, e.hi))
	gui.animate(e.node, "color.w", e.lo, gui.EASING_INOUTSINE, e.period, e.delay, nil, gui.PLAYBACK_LOOP_PINGPONG)
end

function Life:_with_alpha(node, a)
	local c = gui.get_color(node)
	return vmath.vector4(c.x, c.y, c.z, a)
end

local function shaft(self, d, parent, r)
	if not self:room() then return 0 end
	local lo, hi = (d.alpha or { 0.1, 0.2 })[1], (d.alpha or { 0.1, 0.2 })[2]
	local node = self.ui:circle(parent, d.x, y_of(d.y), 10, d.color or "#FFF1B8", { soft = true, alpha = hi })
	gui.set_size(node, vmath.vector3(d.w or 160, d.h or 700, 0))
	gui.set_pivot(node, gui.PIVOT_N)
	gui.set_euler(node, vmath.vector3(0, 0, d.angle or 0))
	add_mode(node)
	self:take(1)
	if not self.reduced then
		gui.animate(node, "color.w", lo, gui.EASING_INOUTSINE, d.period or 5, rr(r, 0, 2), nil, gui.PLAYBACK_LOOP_PINGPONG)
		gui.animate(node, "euler.z", (d.angle or 0) + 2.5, gui.EASING_INOUTSINE, (d.period or 5) * 1.7, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
	end
	return 1
end

local function steam(self, d, parent, r)
	if self.reduced then return 0 end
	local n = 0
	for i = 1, d.count or 3 do
		if not self:room() then break end
		local size = (d.size or 48) * rr(r, 0.8, 1.2)
		local x = d.x + (i - (d.count or 3) / 2 - 0.5) * size * 0.45
		local period = (d.period or 3) * rr(r, 0.85, 1.15)
		local node = self.ui:circle(parent, x, y_of(d.y), size, d.color or "#FFFFFF", { soft = true, alpha = 0.5 })
		gui.set_scale(node, vmath.vector3(0.2, 0.2, 1))
		local delay = (i - 1) * period / (d.count or 3)
		gui.animate(node, "position.y", y_of(d.y) + (d.rise or 110), gui.EASING_OUTSINE, period, delay, nil, gui.PLAYBACK_LOOP_FORWARD)
		gui.animate(node, "position.x", x + rr(r, -14, 14), gui.EASING_INOUTSINE, period / 2, delay, nil, gui.PLAYBACK_LOOP_PINGPONG)
		gui.animate(node, "scale", vmath.vector3(1.5, 1.5, 1), gui.EASING_OUTQUAD, period, delay, nil, gui.PLAYBACK_LOOP_FORWARD)
		gui.animate(node, "color.w", 0, gui.EASING_INQUAD, period, delay, nil, gui.PLAYBACK_LOOP_FORWARD)
		self:take(1)
		n = n + 1
	end
	return n
end

local function notes(self, d, parent, r)
	if self.reduced then return 0 end
	local n = 0
	for i = 1, d.count or 3 do
		if not self:room() then break end
		local size = rr(r, 34, 46)
		local x = d.x + rr(r, -34, 34)
		local period = (d.period or 3.4) * rr(r, 0.9, 1.1)
		local node = self.ui:image(parent, "fx/note", x, y_of(d.y), { w = size, h = size, color = pick(d.colors, i), alpha = 0.95 })
		if not node then break end
		gui.set_scale(node, vmath.vector3(0.3, 0.3, 1))
		local delay = (i - 1) * period / (d.count or 3)
		gui.animate(node, "position.y", y_of(d.y) + (d.rise or 180), gui.EASING_OUTSINE, period, delay, nil, gui.PLAYBACK_LOOP_FORWARD)
		gui.animate(node, "position.x", x + rr(r, 18, 30) * (i % 2 == 0 and -1 or 1), gui.EASING_INOUTSINE, period / 2, delay, nil, gui.PLAYBACK_LOOP_PINGPONG)
		gui.animate(node, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, period * 0.3, delay, nil, gui.PLAYBACK_LOOP_FORWARD)
		gui.animate(node, "color.w", 0, gui.EASING_INQUAD, period, delay, nil, gui.PLAYBACK_LOOP_FORWARD)
		gui.animate(node, "euler.z", rr(r, -14, 14), gui.EASING_INOUTSINE, period / 2, delay, nil, gui.PLAYBACK_LOOP_PINGPONG)
		self:take(1)
		n = n + 1
	end
	return n
end

-- specks: each style is {image | nil (soft disc), size {min, max}, alpha, motion}
local STYLES = {
	dust = { size = { 8, 18 }, alpha = 0.55, motion = "float", rise = 60 },
	sparkle = { image = "fx/star_particle", size = { 20, 36 }, alpha = 0.9, motion = "twinkle" },
	confetti = { image = "fx/confetti", size = { 20, 30 }, alpha = 0.95, motion = "fall" },
	ember = { size = { 10, 18 }, alpha = 0.9, motion = "rise", rise = 130 },
}

local function motes(self, d, parent, r)
	if self.reduced then return 0 end
	local st = STYLES[d.style or "dust"] or STYLES.dust
	local rect = d.rect
	local n = 0
	for i = 1, d.count or 6 do
		if not self:room() then break end
		local size = rr(r, st.size[1], st.size[2])
		local x, y = rect[1] + rr(r, 0, rect[3]), rect[2] + rr(r, 0, rect[4])
		local color = d.colors and pick(d.colors, i) or d.color or "#FFFFFF"
		local gy = y_of(y)
		local node
		if st.image then
			node = self.ui:image(parent, st.image, x, gy, { w = size, h = size, color = color, alpha = st.alpha })
		else
			node = self.ui:circle(parent, x, gy, size, color, { soft = true, alpha = st.alpha })
		end
		if not node then break end
		local period = rr(r, 4, 8)
		local delay = rr(r, 0, period)
		if st.motion == "twinkle" then
			add_mode(node)
			gui.set_scale(node, vmath.vector3(0.4, 0.4, 1))
			local p = rr(r, 0.9, 1.9)
			gui.animate(node, "scale", vmath.vector3(1.1, 1.1, 1), gui.EASING_INOUTSINE, p, delay, nil, gui.PLAYBACK_LOOP_PINGPONG)
			gui.set_color(node, self:_with_alpha(node, 0.05))
			gui.animate(node, "color.w", st.alpha, gui.EASING_INOUTSINE, p, delay, nil, gui.PLAYBACK_LOOP_PINGPONG)
		elseif st.motion == "fall" then
			local fall = rect[4] + 140
			gui.animate(node, "position.y", gy - fall, gui.EASING_LINEAR, period + 1.5, delay, nil, gui.PLAYBACK_LOOP_FORWARD)
			gui.animate(node, "position.x", x + rr(r, -40, 40), gui.EASING_INOUTSINE, period / 2, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
			gui.animate(node, "euler.z", 360 * (i % 2 == 0 and 1 or -1), gui.EASING_LINEAR, period / 2 + 1, 0, nil, gui.PLAYBACK_LOOP_FORWARD)
		elseif st.motion == "rise" then
			add_mode(node)
			gui.animate(node, "position.y", gy + st.rise, gui.EASING_OUTQUAD, period / 2 + 1, delay, nil, gui.PLAYBACK_LOOP_FORWARD)
			gui.animate(node, "color.w", 0, gui.EASING_INQUAD, period / 2 + 1, delay, nil, gui.PLAYBACK_LOOP_FORWARD)
			gui.animate(node, "position.x", x + rr(r, -16, 16), gui.EASING_INOUTSINE, period / 3, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
		else -- float
			gui.animate(node, "position.y", gy + st.rise, gui.EASING_INOUTSINE, period, delay, nil, gui.PLAYBACK_LOOP_PINGPONG)
			gui.animate(node, "position.x", x + rr(r, -24, 24), gui.EASING_INOUTSINE, period * 0.8, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
			gui.set_color(node, self:_with_alpha(node, 0.1))
			gui.animate(node, "color.w", st.alpha, gui.EASING_INOUTSINE, period / 2, delay, nil, gui.PLAYBACK_LOOP_PINGPONG)
		end
		self:take(1)
		n = n + 1
	end
	return n
end

local function bokeh(self, d, parent, r)
	local n = 0
	for i = 1, d.count or 2 do
		if not self:room() then break end
		local size = rr(r, d.size[1], d.size[2])
		local x, y = rr(r, 40, 680), rr(r, d.y[1], d.y[2])
		local node = self.ui:circle(parent, x, y_of(y), size, pick(d.colors, i), { soft = true, alpha = 0.16 })
		add_mode(node)
		if not self.reduced then
			gui.animate(node, "position.x", x + rr(r, 40, 80) * (i % 2 == 0 and -1 or 1), gui.EASING_INOUTSINE, rr(r, 8, 13), 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
			gui.animate(node, "color.w", 0.07, gui.EASING_INOUTSINE, rr(r, 4, 7), 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
		end
		self:take(1)
		n = n + 1
	end
	return n
end

local BUILD = { blink = blink, shaft = shaft, steam = steam, notes = notes, motes = motes, bokeh = bokeh }
M.KINDS = BUILD

-- the room ---------------------------------------------------------------------------------------------------------------------

function Life:room() return self.used < self.limit end
function Life:take(k) self.used = self.used + k end
function Life:count() return self.used end

local function build_one(self, d, index)
	local parent = self.layers[d.layer or "mid"] or self.layers.mid
	local r = random_for(self.did, index)
	local f = BUILD[d.kind]
	if f then return f(self, d, parent, r) end
	return 0
end

function M.new(ui, did, view, layers, done, opts)
	opts = opts or {}
	local spec = M.data().districts[did]
	local self = setmetatable({ ui = ui, did = did, view = view, layers = layers, used = 0, limit = M.budget(),
		blinks = {}, pending = {}, reduced = fx.reduced(), spec = spec }, Life)
	if not spec then return self end
	for i, d in ipairs(spec.details) do
		if not d.view or d.view == view then
			if d.item and not (done and done[d.item]) then
				local q = self.pending[d.item]
				if not q then q = {}; self.pending[d.item] = q end
				q[#q + 1] = { d = d, index = i }
			else
				build_one(self, d, i)
			end
		end
	end
	return self
end

-- The task is restored: its details start (the items' own pop and glow come from the scene).
function Life:wake(task_id)
	local q = self.pending[task_id]
	if not q then return 0 end
	self.pending[task_id] = nil
	local n = 0
	for _, e in ipairs(q) do n = n + build_one(self, e.d, e.index) end
	return n
end

-- Every light flares up and settles back (a task was restored).
function Life:flare()
	if self.reduced then return end
	for _, e in ipairs(self.blinks) do
		gui.cancel_animations(e.node, "color.w")
		gui.set_color(e.node, self:_with_alpha(e.node, 1))
		gui.animate(e.node, "color.w", e.hi, gui.EASING_OUTQUAD, 0.6, 0, function() self:start_blink(e) end)
	end
end

-- A wave of light spreads from (x, y) over the room (additive, gone after ~1 s).
function Life:celebrate(x, y)
	local parent = self.layers.over
	if not parent then return end
	local big = self.ui:circle(parent, x, y, 220, "#FFF3A6", { soft = true, alpha = 0.7 })
	add_mode(big)
	if self.reduced then
		gui.animate(big, "color.w", 0, gui.EASING_OUTQUAD, 0.5, 0, function() gui.delete_node(big) end)
		return
	end
	gui.set_scale(big, vmath.vector3(0.3, 0.3, 1))
	gui.animate(big, "scale", vmath.vector3(7, 7, 1), gui.EASING_OUTCUBIC, 1.0)
	gui.animate(big, "color.w", 0, gui.EASING_INQUAD, 1.0, 0, function() gui.delete_node(big) end)
	local ring = self.ui:circle(parent, x, y, 160, "#FFFFFF", { soft = true, alpha = 0.5 })
	add_mode(ring)
	gui.set_scale(ring, vmath.vector3(0.2, 0.2, 1))
	gui.animate(ring, "scale", vmath.vector3(5, 5, 1), gui.EASING_OUTQUAD, 0.7)
	gui.animate(ring, "color.w", 0, gui.EASING_INQUAD, 0.7, 0, function() gui.delete_node(ring) end)
	self:flare()
end

return M
