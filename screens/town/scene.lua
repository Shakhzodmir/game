-- District scene of the town: sky, the district background (day or
-- concert, continued past the design area), and the task items from
-- content/district_layouts.json. Restored items: full colour, a soft gold
-- glow and a gentle idle bob. Not restored: <task>_ghost.png (grey, light),
-- else the "grey" GUI material. GUI context of screens/town/town.gui_script.
--
--   local scene = require("screens.town.scene").new(town)  -- town.ui, town.c_scene
--   scene:build(district)            -- at once (screen entry)
--   scene:crossfade(district, done)  -- the day / concert look of the district fades into the other (0.6 s)
--   scene:slide_to(district, done, dir) -- another district slides in (from the right, dir = -1: left)
--   scene:light_up(task_id, fx)      -- a task was just done: the item lights up
--   scene:item_pos(task_id)          --> x, y (logical)
--   scene:item_at(x, y)              --> task id and its entry under a point | nil
--   scene:twinkle(fx)                --> a sparkle on a random restored item
--   scene:keep()                     --> loose images to keep in memory
-- A room is built in layers (bottom to top): bg (sky, the picture), mid, items, over, fg. While paging districts each
-- layer slides by its own factor (content/rooms.json parallax: the foreground travels farthest) and mid / fg drift a
-- few pixels; the living details of a room (blinking lights, steam, notes, specks: screens/town/life.lua) sit in
-- mid / over / fg. Only the pictures of the district on display stay in GPU memory: the town
-- releases the others (client/ui.lua release_images) after a switch.

local app = require("client.app")
local ui = require("client.ui")
local fx = require("client.fx")
local assets = require("client.assets")
local life_mod = require("screens.town.life")
local anim = require("client.anim")
local bit_mod = require("client.bit")

local M = {}

local GUI = "/screens/town/town.gui"
local layouts_cache

function M.layouts()
	if layouts_cache == nil then
		local ok, t = pcall(function()
			local data = sys.load_resource("/content/district_layouts.json")
			return data and json.decode(data)
		end)
		layouts_cache = ok and type(t) == "table" and t or false
	end
	return layouts_cache or {}
end

local function item_key(did, tid) return "districts/" .. did .. "/" .. tid end
M.item_key = item_key

local Scene = {}
Scene.__index = Scene

function M.new(town)
	return setmetatable({ town = town, ui = town.ui, container = town.c_scene, items = {}, district = nil }, Scene)
end

-- Loose images of a district in a view (bg + items, both looks).
function M.images(did, view, keep)
	keep = keep or {}
	local k = assets.district_bg_key(did, view)
	if k then keep[k] = true end
	local lay = M.layouts()[did]
	for tid in pairs(lay and lay.items or {}) do -- order-free: a set
		keep[item_key(did, tid)] = true
		keep[item_key(did, tid) .. "_ghost"] = true
	end
	return keep
end

function Scene:keep(keep)
	keep = keep or {}
	if self.district then M.images(self.district, self.view, keep) end
	if self.old_district then M.images(self.old_district, self.old_view, keep) end
	return keep
end

-- The idle motion of a restored item, from content/animations.json (items): looped tweens, none under reduced motion.
local function item_motion(node, id)
	if fx.reduced() or not node then return end
	local items = bit_mod.data().items or {}
	local spec = items.tasks and items.tasks[id] or items.default or { kind = "bob", amp = 5, period = 2.4 }
	local delay = (#id % 7) * 0.17
	for _, tw in ipairs(anim.item_motion(spec)) do
		local easing = tw.easing == "outquad" and gui.EASING_OUTQUAD or gui.EASING_INOUTSINE
		if tw.prop == "position.y" then
			gui.animate(node, tw.prop, gui.get_position(node).y + tw.to, easing, tw.dur, delay, nil, gui.PLAYBACK_LOOP_PINGPONG)
		elseif tw.prop == "euler.z" then
			gui.set_euler(node, vmath.vector3(0, 0, tw.from))
			gui.animate(node, tw.prop, tw.to, easing, tw.dur, delay, nil, gui.PLAYBACK_LOOP_PINGPONG)
		else -- scale.x / scale.y: factors of the rest scale
			local sc = gui.get_scale(node)
			gui.animate(node, tw.prop, (tw.prop == "scale.x" and sc.x or sc.y) * tw.to, easing, tw.dur, delay, nil, gui.PLAYBACK_LOOP_PINGPONG)
		end
	end
end
M.item_motion = item_motion

-- Draws one item in its restored / not restored look into holder.
local function draw_item(self, layer, did, t, it, items)
	local s = self.ui
	local old = items[t.id]
	if old then s:clear(old.holder) end
	local holder = s:layer(layer)
	local x, y = it.x, 1280 - it.y
	local w, h = it.w * it.scale, it.h * it.scale
	local e = { holder = holder, done = t.done, x = x, y = y, w = w, h = h }
	if t.done then
		local size = math.max(w, h)
		local glow = s:circle(holder, x, y, size * 1.5, "glow", { alpha = 0.85, soft = true })
		s:circle(glow, 0, 0, size * 0.66, "#FFF6C8", { alpha = 0.75, soft = true })
		if not fx.reduced() then ui.pulse(glow, 0.07, 1.6) end
		e.glow = glow
		e.node = s:image(holder, item_key(did, t.id), x, y, { w = w, h = h })
		item_motion(e.node, t.id)
	else
		if assets.image(item_key(did, t.id) .. "_ghost") then
			e.node = s:image(holder, item_key(did, t.id) .. "_ghost", x, y, { w = w, h = h })
		end
		if not e.node then
			e.node = s:image(holder, item_key(did, t.id), x, y, { w = w, h = h })
			if e.node then
				local grey = assets.gui_has_material(GUI, "grey") and pcall(gui.set_material, e.node, "grey")
				gui.set_color(e.node, grey and vmath.vector4(1, 1, 1, 0.75) or vmath.vector4(0.92, 0.92, 1, 0.45))
			end
		end
	end
	items[t.id] = e
	return e
end

local PARTS = { "mid", "items", "over", "fg" } -- the layers that slide with their own factor

-- Builds a room. opts.fade: the picture starts transparent (a crossfade; the living details wait for done_fade()).
-- Returns a table {layer, parts, items_layer, items, view, life, drift}.
local function build_layer(self, did, opts)
	opts = opts or {}
	local s = self.ui
	local layer = s:layer(self.container)
	local view = app.meta:view(did)
	local R = { layer = layer, view = view, did = did, parts = {} }
	local bg = s:layer(layer, "bg")
	R.parts.mid = s:layer(layer, "mid")
	R.items_layer = s:layer(layer, "items")
	R.parts.items = R.items_layer
	R.parts.over = s:layer(layer, "over")
	R.parts.fg = s:layer(layer, "fg")
	-- the layers that drift a little (a child, so it never fights the slide)
	R.drift = { mid = s:layer(R.parts.mid), fg = s:layer(R.parts.fg) }
	s:sky({ parent = bg })
	local key = assets.district_bg_key(did, view)
	R.bg = key and s:backdrop(bg, key) or nil
	if R.bg and opts.fade then gui.set_color(R.bg, vmath.vector4(1, 1, 1, 0)) end
	if view == "concert" then M.spotlights(s, R.drift.mid, opts.fade) end
	local items = {}
	local lay = M.layouts()[did]
	local done = {}
	if lay and lay.items then
		for _, t in ipairs(app.meta:district(did).tasks) do
			local it = lay.items[t.id]
			if it then draw_item(self, R.items_layer, did, t, it, items) end
			if t.done then done[t.id] = true end
		end
	end
	R.items = items
	R.done = done
	if not opts.fade then M.start_life(self, R) end
	return R
end

function M.start_life(self, R)
	if R.life then return end
	R.life = life_mod.new(self.ui, R.did, R.view, { mid = R.drift.mid, over = R.parts.over, fg = R.drift.fg }, R.done)
	local data = life_mod.data()
	if not fx.reduced() then
		for name, amp in pairs(data.drift or {}) do -- order-free: independent nodes
			local node = R.drift[name]
			if node and amp > 0 then
				gui.animate(node, "position.x", amp, gui.EASING_INOUTSINE, name == "fg" and 7.3 or 9.1, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
			end
		end
	end
end

local function adopt(self, R)
	self.layer, self.items_layer, self.items, self.view, self.room = R.layer, R.items_layer, R.items, R.view, R
end

-- Slow neon spotlights over the concert look of a district (still under
-- reduced motion).
M.SPOTS = {
	{ x = 90, color = "#FF4FD8", a0 = -20, a1 = 10, period = 5.2 },
	{ x = 630, color = "#3CF2FF", a0 = 20, a1 = -10, period = 6.1 },
}

function M.spotlights(s, parent, fade)
	for _, b in ipairs(M.SPOTS) do
		local n = s:circle(parent, b.x, 1320, 10, b.color, { soft = true, alpha = fade and 0 or 0.22 })
		if fade then gui.animate(n, "color.w", 0.22, gui.EASING_OUTQUAD, life_mod.data().crossfade or 0.6) end
		gui.set_size(n, vmath.vector3(200, 1300, 0))
		gui.set_pivot(n, gui.PIVOT_N)
		gui.set_blend_mode(n, gui.BLEND_ADD)
		gui.set_euler(n, vmath.vector3(0, 0, b.a0))
		if not fx.reduced() then
			gui.animate(n, "euler.z", b.a1, gui.EASING_INOUTSINE, b.period, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
		end
	end
end

-- Builds the scene of `did` at once; the pictures of anything else leave memory.
function Scene:build(did)
	local s = self.ui
	if self.layer then s:clear(self.layer) end
	self.district = did
	self.view = app.meta:view(did)
	self.old_district = nil
	self:_drop_fading()
	s:release_images(self.town:keep_images())
	adopt(self, build_layer(self, did))
end

-- A crossfade in progress leaves at once (a rebuild, a slide).
function Scene:_drop_fading()
	if self.fading then
		self.ui:clear(self.fading)
		self.fading = nil
	end
end

-- The other look (day / concert) of the district fades in over the one on display; the old room goes when the
-- picture is solid and the living details of the new one start. Under reduced motion: at once.
function Scene:crossfade(did, done)
	local s = self.ui
	if fx.reduced() or not self.layer then
		self:build(did)
		if done then done() end
		return
	end
	self:_drop_fading()
	local old = self.layer
	local old_room = self.room
	self.fading = old
	self.district = did
	local R = build_layer(self, did, { fade = true })
	adopt(self, R)
	s:release_images(self.town:keep_images())
	local finish = function()
		if self.room ~= R or self.fading ~= old then return end
		s:clear(old)
		self.fading = nil
		M.start_life(self, R)
		s:release_images(self.town:keep_images())
		if done then done() end
	end
	if R.bg then
		gui.animate(R.bg, "color.w", 1, gui.EASING_INOUTSINE, life_mod.data().crossfade or 0.6, 0, finish)
	else
		finish()
	end
end

-- Redraws items whose done state changed (no animation).
function Scene:refresh()
	local lay = M.layouts()[self.district]
	if not lay or not lay.items then return end
	for _, t in ipairs(app.meta:district(self.district).tasks) do
		local it = lay.items[t.id]
		local have = self.items[t.id]
		if it and (not have or have.done ~= t.done) then
			draw_item(self, self.items_layer, self.district, t, it, self.items)
			if t.done and self.room and self.room.life then self.room.life:wake(t.id) end
		end
	end
end

-- The item under a logical point (topmost first): task id, entry.
function Scene:item_at(x, y)
	local best, best_e, best_d
	for id, e in pairs(self.items or {}) do -- order-free: the closest centre wins
		if math.abs(x - e.x) <= e.w / 2 and math.abs(y - e.y) <= e.h / 2 then
			local d = (x - e.x) ^ 2 + (y - e.y) ^ 2
			if not best_d or d < best_d then best, best_e, best_d = id, e, d end
		end
	end
	return best, best_e
end

-- A little sparkle on one restored item (ambient life of the scene).
function Scene:twinkle(fxi)
	local done = {}
	for id, e in pairs(self.items or {}) do
		if e.done then done[#done + 1] = e end
	end
	if #done == 0 then return end
	table.sort(done, function(a, b) return a.x < b.x end)
	local e = done[math.random(#done)]
	fxi:burst(e.x + fx.rand(-e.w * 0.35, e.w * 0.35), e.y + fx.rand(-e.h * 0.3, e.h * 0.4),
		{ count = 4, radius = 36, size = 22, dur = 0.7 })
end

function Scene:item_pos(task_id)
	local e = self.items[task_id]
	if e then return e.x, e.y end
	return 360, 760
end

-- The item of a task that was just done lights up: full colour with a
-- scale pop, then its glow and idle bob.
function Scene:light_up(task_id)
	local lay = M.layouts()[self.district]
	local it = lay and lay.items and lay.items[task_id]
	if not it then return end
	local task
	for _, t in ipairs(app.meta:district(self.district).tasks) do
		if t.id == task_id then task = t end
	end
	if not task then return end
	local e = draw_item(self, self.items_layer, self.district, task, it, self.items)
	local room = self.room
	if room and room.life then
		room.life:wake(task_id)          -- the details that belong to this item start
		room.life:celebrate(e.x, e.y)    -- a wave of light over the room, every lamp flares
	end
	if fx.reduced() then return e end
	if e.node then
		local sc = gui.get_scale(e.node)
		-- the idle motion waits for the pop (both would write the same properties)
		gui.cancel_animations(e.node, "scale")
		gui.cancel_animations(e.node, "euler")
		gui.set_scale(e.node, sc * 0.55)
		gui.animate(e.node, "scale", sc * 1.18, gui.EASING_OUTBACK, 0.28, 0, function()
			gui.animate(e.node, "scale", sc, gui.EASING_OUTELASTIC, 0.7, 0, function()
				gui.set_euler(e.node, vmath.vector3(0, 0, 0))
				item_motion(e.node, task_id)
			end)
		end)
	end
	if e.glow then
		ui.stop_pulse(e.glow)
		local g = gui.get_scale(e.glow)
		gui.set_scale(e.glow, vmath.vector3(0.1, 0.1, 1))
		gui.animate(e.glow, "scale", g, gui.EASING_OUTQUAD, 0.6, 0.1, function() ui.pulse(e.glow, 0.07, 1.6) end)
	end
	return e
end

-- The next district slides in from the right (dir = 1, the default) while this one leaves to the
-- left; dir = -1 the other way round (back to an earlier district). done() when it is in place.
-- Under reduced motion: at once.
function Scene:slide_to(did, done, dir)
	local s = self.ui
	dir = dir == -1 and -1 or 1
	if fx.reduced() or not self.layer then
		self:build(did)
		if done then done() end
		return
	end
	self:_drop_fading()
	local old, old_room = self.layer, self.room
	self.old_district, self.old_view = self.district, self.view
	self.district = did
	local R = build_layer(self, did)
	adopt(self, R)
	gui.set_position(R.layer, vmath.vector3(760 * dir, 0, 0))
	gui.animate(R.layer, "position.x", 0, gui.EASING_OUTCUBIC, 0.7)
	gui.animate(old, "position.x", -760 * dir, gui.EASING_INOUTCUBIC, 0.7, 0, function()
		s:clear(old)
		self.old_district = nil
		s:release_images(self.town:keep_images())
		if done then done() end
	end)
	-- parallax: the nearer a layer, the farther it travels (it arrives with the room and leaves with it)
	local factors = life_mod.data().parallax or {}
	for _, name in ipairs(PARTS) do
		local f = factors[name]
		if f and f ~= 1 then
			local extra = 760 * dir * (f - 1)
			gui.set_position(R.parts[name], vmath.vector3(extra, 0, 0))
			gui.animate(R.parts[name], "position.x", 0, gui.EASING_OUTCUBIC, 0.7)
			if old_room and old_room.parts[name] then
				gui.animate(old_room.parts[name], "position.x", -extra, gui.EASING_INOUTCUBIC, 0.7)
			end
		end
	end
end

return M
