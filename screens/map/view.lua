-- The map screen's picture: the long road of 100 levels seen from above (GUI script context only).
--
-- Layers, bottom to top:
--   back   - a colour that covers the window (the tint of the district under the view)
--   world  - everything that scrolls (moved as ONE node: its y is -offset)
--              c_bg    background tiles of the districts, gates with the district name, decorations
--              c_path  the trail dots
--              c_nodes the level nodes
--              c_bit   Bit and the "new levels soon" sign
--   ui     - top bar (back to the town, title, stars), the "to my level" button (anchored to the safe area)
--   popups - the start window and the windows it opens (client/popups.lua)
--   fx     - sparkles
--
-- Only what is near the window exists. The level nodes, the trail dots are POOLS: a fixed number of
-- prebuilt slots that are re-bound (position, picture, text) when a level comes into view or leaves it; the
-- background tiles, gates and decorations are made when they come within reach and deleted after they left,
-- so the node count of the GUI stays far under its limit (tools/gen_defold.py max_nodes) however long the map is.
-- Nothing is allocated per frame while the map scrolls: the pools and tables are made once.
--
-- Bit stands on the level to play. After a win the screen opens with Bit on the level that was the next one
-- when the map was last shown, and he walks along the trail to the new one (M.remembered).

local app = require("client.app")
local ui = require("client.ui")
local i18n = require("client.i18n")
local fx_mod = require("client.fx")
local bit = require("client.bit")
local audio = require("client.audio")
local assets = require("client.assets")
local layout = require("client.layout")
local rewards = require("client.rewards")
local levels = require("client.levels")
local map_model = require("client.map_model")
local map_scroll = require("client.map_scroll")

local M = {}

M.MARGIN = 260        -- px around the window in which nodes and dots exist
M.TILE_MARGIN = 900   -- background tiles are made this far ahead
M.MAX_VIEW_H = 2600   -- tallest window (logical px) the pools are sized for; a taller one rebuilds them
M.WALK_SPEED = 2.6    -- levels per second while Bit walks
M.TOP_Y = 1214
M.STAR_SIZE = 44

-- What the next opening of the map starts from (the level Bit stood on, the scroll position). Shared by the
-- scripts of the app (one Lua state); the screen sets it when it closes.
M.remembered = { level = nil, off = nil }

function M._reset()
	M.remembered.level, M.remembered.off = nil, nil
end

local View = {}
View.__index = View
M.View = View

local v3 = vmath.vector3

local function reduced()
	return app.reduced_motion()
end

local function anim_of(key)
	local e = assets.image(key)
	return e and e.anim or nil
end

-- construction -----------------------------------------------------------------------------------

-- scene = client/ui.lua scene; mdl = client/map_model.lua model
function M.new(scene, mdl)
	local self = setmetatable({}, View)
	self.ui = scene
	self.model = mdl
	self.pos3 = v3(0, 0, 0)       -- reused for every position set in the frame loop
	self.sz3 = v3(0, 0, 0)
	self.sc3 = v3(1, 1, 1)
	self.tiles, self.gates, self.decos = {}, {}, {}
	self.want = {}
	self.targets = {}
	self.keys = {}                -- "node_<level>": the QA target names, made once
	self.entries = {}             -- the tap target table of each level, shown in `targets` while its node is in the pools
	for n = 1, mdl.count do
		self.keys[n] = "node_" .. n
		self.entries[n] = self:target("node_" .. n, 0, 0)
		self.targets[self.keys[n]] = nil
	end
	self.status = { off = 0, first = 1, last = 0, next = nil, shown = nil, bit_u = 1, walking = false }
	self.slot_of_level = {}
	self.diff = {}                -- difficulty by level (the level file is read once)
	self.first, self.last = 1, 0  -- levels in the pools
	self.g0, self.g1 = 1, 0       -- dots in the pool
	self.tile_key = nil
	self.time = 0
	self.back_seg = nil
	self.next = nil               -- level to play now (nil: everything is beaten)
	self.disp_next = nil          -- what the nodes show (Bit has not walked to the new level yet)
	self.dirty = true

	local s = scene
	self.c_back = s:layer(s.root, "map_back")
	self.c_world = s:layer(s.root, "map_world")
	self.c_ui = s:layer(s.root, "map_ui")
	self.c_popups = s:layer(s.root, "popups_root")
	self.fx = fx_mod.new(s, s.root)
	self.back = s:box(self.c_back, 360, 640, 720, 1280, { color = "#F4EEFF" })
	s:cover(self.back, "stretch")
	return self
end

-- A tap target for QA (app.ui.targets): logical coordinates, y up. Returns the entry.
function View:target(name, x, y)
	local e = self.targets[name]
	if not e then
		e = {}
		self.targets[name] = e
	end
	e.x, e.y = x, y
	return e
end

function View:view_h()
	local f = self.ui.fit
	return math.max(layout.H, f.y1 - f.y0)
end

-- The pools (slots of nodes, dots) are made for the tallest window; the world is made from scratch when the language
-- or the window changes.
function View:build_world()
	local s, m = self.ui, self.model
	if self.world then s:clear(self.world) end
	self.world = s:layer(self.c_world, "world")
	self.c_bg = s:layer(self.world, "bg")
	self.c_path = s:layer(self.world, "path")
	self.c_nodes = s:layer(self.world, "nodes")
	self.c_bit = s:layer(self.world, "bit")
	self.tiles, self.gates, self.decos = {}, {}, {}
	self.first, self.last, self.g0, self.g1 = 1, 0, 1, 0
	self.slot_of_level = {}
	for k in pairs(self.targets) do self.targets[k] = nil end -- order-free: clears
	self.view_h_built = math.min(M.MAX_VIEW_H, math.max(self:view_h(), layout.H))

	local window = self.view_h_built + 2 * M.MARGIN
	self.npool = m:max_in_window(window) + 2
	self.slots = {}
	for i = 1, self.npool do self.slots[i] = self:make_slot() end
	-- dots: the most any run of levels that fits the window touches
	self.dpool = m:max_dots(self.npool) + 2
	self.dots = {}
	local size = m.data.path.size
	for i = 1, self.dpool do
		local node = s:image(self.c_path, m.data.path.dot, 0, 0, { w = size, h = size })
			or s:circle(self.c_path, 0, 0, size * 0.8, "#FFFFFF")
		gui.set_enabled(node, false)
		self.dots[i] = { node = node, done = nil }
	end
	-- Bit
	local st = m.data.bit
	self.bit = bit.new(s, self.c_bit, 0, 0, st.size)
	self.bit_u = self.bit_u or 1
	-- the sign after the last level
	local soon_y = m.data.soon and m.data.soon.y or m.world_h - 330
	local rib = s:image(self.c_nodes, "ui/ribbon", 360, soon_y, { w = 600, h = 150 })
		or s:round(self.c_nodes, 360, soon_y, 600, 120, "#9B5CFF", { radius = 40 })
	s:text(self.c_nodes, i18n.t("map.soon"), 360, soon_y + 6, {
		font = "button", size = 46, color = "white", outline = "#5220A6", shadow = "#5220A6", max_width = 470,
	})
	s:text(self.c_nodes, i18n.t("map.soon_text"), 360, soon_y - 96, {
		font = "body", size = 28, color = "text", width = 560, height = 80, max_width = 560,
	})
	self.sign = rib
	self.dirty = true
end

function View:make_slot()
	local s = self.ui
	local root = s:layer(self.c_nodes)
	gui.set_enabled(root, false)
	local slot = { root = root, level = nil }
	slot.glow = s:circle(root, 0, 0, 240, "glow", { soft = true, alpha = 0.7 })
	local day = self.model.data.node.day
	slot.face = s:image(root, day.states.locked, 0, 0, { w = day.size, h = day.size })
		or s:circle(root, 0, 0, day.size * 0.9, "#B9B2D0")
	slot.bubble = s:circle(root, 0, 0, 52, "white")
	slot.disc = s:circle(slot.bubble, 0, 0, 44, "purple")
	slot.num, slot.num_info = s:text(slot.disc, "1", 0, 2, { font = "number", size = 30, color = "white", max_width = 38 })
	slot.stars = {}
	local ss = M.STAR_SIZE
	for i = 1, 3 do
		slot.stars[i] = s:image(root, "ui/icons/star_empty", (i - 2) * (ss + 4), 0, { w = ss, h = ss })
			or s:circle(root, (i - 2) * (ss + 4), 0, ss * 0.8, "yellow")
		gui.set_enabled(slot.stars[i], false)
	end
	slot.super = s:image(root, "ui/icons/super_star", 0, 0, { w = 56, h = 56 })
		or s:circle(root, 0, 0, 44, "purple")
	gui.set_enabled(slot.super, false)
	return slot
end

-- binding -----------------------------------------------------------------------------------------

local function difficulty(self, n)
	local d = self.diff[n]
	if d == nil then
		d = levels.difficulty(n) or false
		self.diff[n] = d
	end
	return d or nil
end

function View:best_stars(n)
	local ok, v = pcall(app.meta.level_stars, app.meta, n, difficulty(self, n))
	return ok and v or 0
end

local STAR_ON = "ui/icons/star"
local STAR_OFF = "ui/icons/star_empty"

function View:bind_slot(slot, n, pop)
	local m = self.model
	local nd = m:node(n)
	local kind = m:kind(n)
	local state = m:state(n, self.disp_next)
	local def = m.data.node[kind]
	local size = def.size
	slot.level, slot.state = n, state
	self.pos3.x, self.pos3.y, self.pos3.z = nd.x, nd.y, 0
	gui.set_position(slot.root, self.pos3)
	gui.set_enabled(slot.root, true)
	local a = anim_of(def.states[state])
	if a then
		gui.play_flipbook(slot.face, a)
	end
	self.sc3.x, self.sc3.y, self.sc3.z = 1, 1, 1
	self.sz3.x, self.sz3.y = size, size
	gui.set_size(slot.face, self.sz3)
	ui.stop_pulse(slot.face, self.sc3)
	local current = state == "current"
	local glowing = current or (kind == "concert" and state ~= "locked")
	gui.set_enabled(slot.glow, glowing)
	if glowing then
		self.sz3.x, self.sz3.y = size * 1.55, size * 1.55
		gui.set_size(slot.glow, self.sz3)
		gui.set_color(slot.glow, ui.color(kind == "concert" and "#FFB0E0" or "glow", current and 0.75 or 0.5))
	end
	if current and not reduced() then
		ui.pulse(slot.face, 0.06, 0.9)
		ui.pulse(slot.glow, 0.1, 1.2)
	elseif not reduced() then
		ui.stop_pulse(slot.glow, self.sc3)
	end
	-- the number sits on a bubble at the top left of the node
	local bx = -size * 0.36
	local by = size * 0.36
	self.pos3.x, self.pos3.y = bx, by
	gui.set_position(slot.bubble, self.pos3)
	gui.set_color(slot.disc, ui.color(state == "locked" and "#B9B2D0" or (state == "done" and "green" or (kind == "concert" and "pink" or "purple"))))
	self.ui:set_text(slot.num, tostring(n), slot.num_info)
	-- stars under a beaten node
	local got = state == "done" and self:best_stars(n) or 0
	local sy = -size / 2 - M.STAR_SIZE * 0.35
	for i = 1, 3 do
		local node = slot.stars[i]
		gui.set_enabled(node, state == "done")
		if state == "done" then
			local ia = anim_of(i <= got and STAR_ON or STAR_OFF)
			if ia then gui.play_flipbook(node, ia) end
			self.pos3.x, self.pos3.y = (i - 2) * (M.STAR_SIZE + 2), sy - (i == 2 and 0 or 6)
			gui.set_position(node, self.pos3)
		end
	end
	-- a concert that gave a super star
	local sup = 0
	if kind == "concert" and state == "done" then
		local lv = app.meta:super_stars().levels
		sup = lv[n] or 0
	end
	gui.set_enabled(slot.super, sup > 0)
	if sup > 0 then
		self.pos3.x, self.pos3.y = size * 0.42, size * 0.42
		gui.set_position(slot.super, self.pos3)
	end
	if pop and not reduced() then
		self.fx:pop(slot.face, 0.25, 0.4)
	end
end

function View:hide_slot(slot)
	gui.set_enabled(slot.root, false)
	if ui.is_pulsing(slot.face) then ui.stop_pulse(slot.face, self.sc3) end
	slot.level = nil
end

function View:slot_for(n)
	return self.slots[(n - 1) % self.npool + 1]
end

function View:dot_slot(g)
	return self.dots[g % self.dpool + 1]
end

function View:bind_dot(g)
	local m = self.model
	local d = self:dot_slot(g)
	local x, y = m:dot(g)
	self.pos3.x, self.pos3.y, self.pos3.z = x, y, 0
	gui.set_position(d.node, self.pos3)
	local done = self.disp_next == nil or g <= m:dot_end(self.disp_next)
	if d.done ~= done then
		d.done = done
		local a = anim_of(done and m.data.path.dot_done or m.data.path.dot)
		if a then gui.play_flipbook(d.node, a) end
	end
	gui.set_enabled(d.node, true)
	d.g = g
end

-- Brings the pools in line with the window: levels and dots that entered are bound, those that left are hidden.
function View:sync_pools(off)
	local m = self.model
	local first, last = m:visible(off, self:view_h(), M.MARGIN)
	if first ~= self.first or last ~= self.last then
		local of, ol = self.first, self.last
		for n = of, ol do
			if n < first or n > last then
				local slot = self:slot_for(n)
				if slot.level == n then self:hide_slot(slot) end
				self.targets[self.keys[n]] = nil
			end
		end
		for n = first, last do
			if n < of or n > ol then self:bind_slot(self:slot_for(n), n) end
		end
		self.first, self.last = first, last
		local g0, g1 = m:dots(first, last)
		local og0, og1 = self.g0, self.g1
		for g = og0, og1 do
			if g < g0 or g > g1 then
				local d = self:dot_slot(g)
				if d.g == g then gui.set_enabled(d.node, false) end
			end
		end
		for g = g0, g1 do
			if g < og0 or g > og1 then self:bind_dot(g) end
		end
		self.g0, self.g1 = g0, g1
	end
end

-- Rebinds everything in the pools (the states changed).
function View:refresh()
	for n = self.first, self.last do
		self:bind_slot(self:slot_for(n), n)
	end
	for g = self.g0, self.g1 do self:bind_dot(g) end
	self:place_bit()
end

-- backgrounds, gates, decorations -------------------------------------------------------------------

local function key_of(seg, idx)
	return seg * 1000 + idx
end

function View:make_tile(seg, idx)
	local s, m = self.ui, self.model
	local sg = m.segments[seg]
	local th = m.tile_h
	local y = sg.y0 + idx * th + th / 2
	local node = s:image(self.c_bg, sg.bg, 360, y, { w = 720, h = th })
	if not node then
		node = s:box(self.c_bg, 360, y, 720, th, { color = sg.tint or "#F4EEFF" })
	end
	if idx % 2 == 1 then
		-- every other tile is mirrored top to bottom, so the seams of a repeated picture meet
		gui.set_scale(node, v3(1, -1, 1))
	end
	return node
end

function View:make_gate(seg)
	local s, m = self.ui, self.model
	local sg = m.segments[seg]
	local holder = s:layer(self.c_bg)
	local node = s:image(holder, sg.gate, 360, sg.gate_y, { w = 720, h = 480 })
	if not node then
		node = s:round(holder, 360, sg.gate_y, 520, 160, "#9B5CFF", { radius = 40 })
	end
	local sign = sg.sign or { dx = 0, dy = 116, w = 280 }
	local d = app.district_by_id and app.district_by_id[sg.district]
	local name = d and i18n.name(d.name) or sg.district
	s:text(holder, name, 360 + sign.dx, sg.gate_y + sign.dy, {
		font = "button", size = 38, color = "text", outline = false, shadow = false, max_width = sign.w,
	})
	return holder
end

function View:make_deco(seg, j)
	local s = self.ui
	local it = self.model.segments[seg].deco[j]
	local node = s:image(self.c_bg, it.image, it.x, it.y, { scale = it.scale or 1 })
	return node or false
end

-- Makes the tiles, gates and decorations that are within reach of the window and deletes those that left.
function View:sync_backdrop(off)
	local s, m = self.ui, self.model
	local vh = self:view_h()
	local want = self.want
	for k in pairs(want) do want[k] = nil end -- order-free: clears
	local changed = false
	local lo, hi = off - M.TILE_MARGIN, off + vh + M.TILE_MARGIN
	for seg = 1, #m.segments do
		local sg = m.segments[seg]
		local a, b = m:tiles(seg, off, vh, M.TILE_MARGIN)
		for idx = a, b do
			local k = key_of(seg, idx)
			want[k] = true
			if not self.tiles[k] then
				self.tiles[k] = self:make_tile(seg, idx)
				changed = true
			end
		end
		-- gate
		if sg.gate_y + 240 >= lo and sg.gate_y - 240 <= hi then
			want[-seg] = true
			if not self.gates[seg] then
				self.gates[seg] = self:make_gate(seg)
				changed = true
			end
		end
		for j, it in ipairs(sg.deco) do
			local k = key_of(seg, 100 + j)
			if it.y >= lo and it.y <= hi then
				want[k] = true
				if self.decos[k] == nil then
					self.decos[k] = self:make_deco(seg, j)
					changed = true
				end
			end
		end
	end
	for k, node in pairs(self.tiles) do -- order-free: deletes what is out of reach
		if not want[k] then
			s:clear(node)
			self.tiles[k] = nil
			changed = true
		end
	end
	for seg, node in pairs(self.gates) do
		if not want[-seg] then
			s:clear(node)
			self.gates[seg] = nil
			changed = true
		end
	end
	for k, node in pairs(self.decos) do
		if not want[k] then
			if node then s:clear(node) end
			self.decos[k] = nil
			changed = true
		end
	end
	if changed then self.ui:release_images(self:keep_images()) end
	-- the colour behind the window follows the district in the middle of it
	local seg = m:segment_at(off + vh / 2)
	if seg ~= self.back_seg then
		self.back_seg = seg
		gui.set_color(self.back, ui.color(m.segments[seg].tint or "#F4EEFF"))
	end
end

-- The loose pictures that are in use (Bit's, the tiles and gates on display): the others leave the GPU.
function View:keep_images()
	local m = self.model
	local keep = bit.images()
	for seg = 1, #m.segments do
		local sg = m.segments[seg]
		for idx = 0, 40 do
			if self.tiles[key_of(seg, idx)] then keep[sg.bg] = true break end
		end
		if self.gates[seg] then keep[sg.gate] = true end
		for j, it in ipairs(sg.deco) do
			if self.decos[key_of(seg, 100 + j)] then keep[it.image] = true end
		end
	end
	return keep
end

-- Bit -----------------------------------------------------------------------------------------------

-- Bit stands at (or walks to) the point u of the path.
function View:place_bit(hop)
	local m = self.model
	local x, y = m:path_pos(self.bit_u)
	local dy = m.data.bit.dy + (hop or 0)
	self.bit.home.x, self.bit.home.y = x, y + m.data.bit.dy
	self.pos3.x, self.pos3.y, self.pos3.z = x + 4, y + dy, 0
	gui.set_position(self.bit.holder, self.pos3)
end

-- frame ---------------------------------------------------------------------------------------------

-- Applies the scroll position: the world moves, the pools follow. No allocation.
function View:apply(off)
	self.pos3.x, self.pos3.y, self.pos3.z = 0, -off, 0
	gui.set_position(self.world, self.pos3)
	self.off = off
	if self.sync_pools then
		self:sync_pools(off)
		local key = math.floor(off / 64)
		if key ~= self.tile_key then
			self.tile_key = key
			self:sync_backdrop(off)
		end
	end
	self:publish_targets(off)
end

-- Logical tap positions of the visible nodes for QA (app.ui.targets): the tables are reused.
function View:publish_targets(off)
	local m = self.model
	local t = self.targets
	for n = self.first, self.last do
		local nd = m:node(n)
		local e = self.entries[n]
		t[self.keys[n]] = e
		e.x, e.y = nd.x, nd.y - off
	end
end

-- The status for QA / debug (app.ui.map): one table, updated in place.
function View:publish(u, walking)
	local st = self.status
	st.off, st.first, st.last, st.next, st.shown = self.off or 0, self.first, self.last, self.next, self.disp_next
	st.bit_u, st.walking = self.bit_u, walking or false
	u.targets = self.targets
	u.map = st
end

function View:screen_y(wy)
	return wy - (self.off or 0)
end

return M
