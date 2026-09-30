-- District scene of the town: sky, the district background (day or
-- concert, continued past the design area), and the task items from
-- content/district_layouts.json. Restored items: full colour, a soft gold
-- glow and a gentle idle bob. Not restored: <task>_ghost.png (grey, light),
-- else the "grey" GUI material. GUI context of screens/town/town.gui_script.
--
--   local scene = require("screens.town.scene").new(town)  -- town.ui, town.c_scene
--   scene:build(district)            -- at once (screen entry, view toggle)
--   scene:slide_to(district, done)   -- the next district slides in from the right
--   scene:light_up(task_id, fx)      -- a task was just done: the item lights up
--   scene:item_pos(task_id)          --> x, y (logical)
--   scene:item_at(x, y)              --> task id and its entry under a point | nil
--   scene:twinkle(fx)                --> a sparkle on a random restored item
--   scene:keep()                     --> loose images to keep in memory
-- Only the pictures of the district on display stay in GPU memory: the town
-- releases the others (client/ui.lua release_images) after a switch.

local app = require("client.app")
local ui = require("client.ui")
local fx = require("client.fx")
local assets = require("client.assets")

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
		if e.node then fx.bob(e.node, 5, 2.2 + (#t.id % 5) * 0.23, (#t.id % 7) * 0.17) end
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

local function build_layer(self, did)
	local s = self.ui
	local layer = s:layer(self.container)
	local view = app.meta:view(did)
	s:sky({ parent = layer })
	local key = assets.district_bg_key(did, view)
	if key then s:backdrop(layer, key) end
	if view == "concert" then M.spotlights(s, layer) end
	local items_layer = s:layer(layer, "items")
	local items = {}
	local lay = M.layouts()[did]
	if lay and lay.items then
		for _, t in ipairs(app.meta:district(did).tasks) do
			local it = lay.items[t.id]
			if it then draw_item(self, items_layer, did, t, it, items) end
		end
	end
	return layer, items_layer, items, view
end

-- Slow neon spotlights over the concert look of a district (still under
-- reduced motion).
M.SPOTS = {
	{ x = 90, color = "#FF4FD8", a0 = -20, a1 = 10, period = 5.2 },
	{ x = 630, color = "#3CF2FF", a0 = 20, a1 = -10, period = 6.1 },
}

function M.spotlights(s, parent)
	for _, b in ipairs(M.SPOTS) do
		local n = s:circle(parent, b.x, 1320, 10, b.color, { soft = true, alpha = 0.22 })
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
	s:release_images(self.town:keep_images())
	self.layer, self.items_layer, self.items, self.view = build_layer(self, did)
end

-- Redraws items whose done state changed (no animation).
function Scene:refresh()
	local lay = M.layouts()[self.district]
	if not lay or not lay.items then return end
	for _, t in ipairs(app.meta:district(self.district).tasks) do
		local it = lay.items[t.id]
		local have = self.items[t.id]
		if it and (not have or have.done ~= t.done) then draw_item(self, self.items_layer, self.district, t, it, self.items) end
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
	if fx.reduced() then return e end
	if e.node then
		local sc = gui.get_scale(e.node)
		gui.set_scale(e.node, sc * 0.55)
		gui.animate(e.node, "scale", sc * 1.18, gui.EASING_OUTBACK, 0.28, 0, function()
			gui.animate(e.node, "scale", sc, gui.EASING_OUTELASTIC, 0.7)
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

-- The next district slides in from the right while this one leaves to the
-- left; done() when it is in place. Under reduced motion: at once.
function Scene:slide_to(did, done)
	local s = self.ui
	if fx.reduced() or not self.layer then
		self:build(did)
		if done then done() end
		return
	end
	local old = self.layer
	self.old_district, self.old_view = self.district, self.view
	self.district = did
	local layer, items_layer, items, view = build_layer(self, did)
	self.layer, self.items_layer, self.items, self.view = layer, items_layer, items, view
	gui.set_position(layer, vmath.vector3(760, 0, 0))
	gui.animate(layer, "position.x", 0, gui.EASING_OUTCUBIC, 0.7)
	gui.animate(old, "position.x", -760, gui.EASING_INOUTCUBIC, 0.7, 0, function()
		s:clear(old)
		self.old_district = nil
		s:release_images(self.town:keep_images())
		if done then done() end
	end)
end

return M
