-- Sprites of the level board (Defold, board.script context): one pooled
-- game object per object of game:pieces() (at most MAX_PIECES), the wires
-- overlay above them and "marks" (selection glow, hint glows, booster target
-- highlight). What each sprite shows comes from client/level_anim.lua; this
-- module only applies it with as few engine calls as possible.
--
--   local level_view = require("client.level_view")
--   local V = level_view.new({piece = "#piece_factory", glow = "#glow_factory"})
--   V:sync(anim_list, shake_x, shake_y)   -- every frame
--   V:set_wires(game:cells(), geom)       -- when the wires changed
--   V:marks({{image, x, y, w, h, color, alpha, glow = bool, z}, ...})
--   V:stats()                             -- {pieces, pooled, wires, marks}
--   V:final()
--
-- Sprites use screens/level/board.material: per-sprite vertex attributes
-- vcolor (tint, alpha) and vfx (x = clip line, y = white flash) keep the
-- whole board in a few batched draw calls.

local M = {}

M.MAX_PIECES = 150
M.OFF = vmath.vector3(-10000, -10000, 0)
M.NO_CLIP = 100000
M.Z_WIRES = 0.2
M.Z_MARK = 0.05

local H_VFX = hash("vfx")
local H_VCOLOR = hash("vcolor")

local anim_hash = {}
local function ah(name)
	local h = anim_hash[name]
	if not h then
		h = hash(name)
		anim_hash[name] = h
	end
	return h
end
M.anim_hash = ah

-- "#RRGGBB" -> r, g, b (0..1)
local hex_cache = {}
function M.rgb(hex)
	local c = hex_cache[hex]
	if not c then
		local s = string.gsub(hex or "#FFFFFF", "#", "")
		c = {
			(tonumber(string.sub(s, 1, 2), 16) or 255) / 255,
			(tonumber(string.sub(s, 3, 4), 16) or 255) / 255,
			(tonumber(string.sub(s, 5, 6), 16) or 255) / 255,
		}
		hex_cache[hex] = c
	end
	return c[1], c[2], c[3]
end

local View = {}
View.__index = View

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		factory = { piece = opts.piece or "#piece_factory", glow = opts.glow or "#glow_factory" },
		by_id = {},      -- piece id -> sprite object
		free = {},       -- pooled piece sprites
		count = 0,       -- piece sprites created
		wires = {},      -- sprite objects of the wires overlay
		mark_objs = {},  -- sprite objects of marks, by kind
		frame = 0,
		overflow = 0,
	}, View)
end

-- A sprite object: {go, url, pos, scl, image, rot, flash, clip, alpha, r, g, b}
function M.create(factory_url)
	local id = factory.create(factory_url, M.OFF, nil, nil, 1)
	return {
		go = id, url = msg.url(nil, id, "sprite"),
		pos = vmath.vector3(M.OFF), scl = vmath.vector3(1, 1, 1),
		image = nil, rot = 0, flash = 0, clip = M.NO_CLIP, alpha = 1, r = 1, g = 1, b = 1,
		vfx = vmath.vector4(M.NO_CLIP, 0, 0, 0), col = vmath.vector4(1, 1, 1, 1),
		hidden = true,
	}
end

function M.hide(o)
	if o.hidden then return end
	o.hidden = true
	o.pos.x, o.pos.y = M.OFF.x, M.OFF.y
	go.set_position(o.pos, o.go)
end

-- Applies a look: image (anim id string), x, y, z, sx, sy (final scale), rot
-- (degrees), flash, clip (logical y or nil), alpha, r, g, b.
function M.apply(o, image, x, y, z, sx, sy, rot, flash, clip, alpha, r, g, b)
	o.hidden = false
	local p = o.pos
	if p.x ~= x or p.y ~= y or p.z ~= z then
		p.x, p.y, p.z = x, y, z
		go.set_position(p, o.go)
	end
	if o.image ~= image then
		o.image = image
		sprite.play_flipbook(o.url, ah(image))
	end
	local s = o.scl
	if s.x ~= sx or s.y ~= sy then
		s.x, s.y = sx, sy
		go.set_scale(s, o.go)
	end
	rot = rot or 0
	if o.rot ~= rot then
		o.rot = rot
		go.set_rotation(vmath.quat_rotation_z(math.rad(rot)), o.go)
	end
	flash = flash or 0
	clip = clip or M.NO_CLIP
	if o.flash ~= flash or o.clip ~= clip then
		o.flash, o.clip = flash, clip
		o.vfx.x, o.vfx.y = clip, flash
		go.set(o.url, H_VFX, o.vfx)
	end
	alpha = alpha or 1
	r, g, b = r or 1, g or 1, b or 1
	if o.alpha ~= alpha or o.r ~= r or o.g ~= g or o.b ~= b then
		o.alpha, o.r, o.g, o.b = alpha, r, g, b
		local c = o.col
		c.x, c.y, c.z, c.w = r, g, b, alpha
		go.set(o.url, H_VCOLOR, c)
	end
end

function View:_take()
	local o = table.remove(self.free)
	if o then return o end
	if self.count >= M.MAX_PIECES then return nil end
	self.count = self.count + 1
	return M.create(self.factory.piece)
end

-- Every frame: list = level_anim:frame(...) entries.
function View:sync(list, shake_x, shake_y)
	self.frame = self.frame + 1
	local fr = self.frame
	shake_x, shake_y = shake_x or 0, shake_y or 0
	local by_id = self.by_id
	for i = 1, #list do
		local e = list[i]
		local o = by_id[e.id]
		if not o then
			o = self:_take()
			if o then by_id[e.id] = o else self.overflow = self.overflow + 1 end
		end
		if o then
			o.used = fr
			if e.alpha <= 0 then
				M.hide(o)
			else
				local k = e.scale
				M.apply(o, e.image, e.x + shake_x, e.y + shake_y, e.z, k * e.sx, k * e.sy, e.rot, e.flash,
					e.clip and (e.clip + shake_y) or nil, e.alpha)
			end
		end
	end
	for id, o in pairs(by_id) do -- order-independent
		if o.used ~= fr then
			by_id[id] = nil
			M.hide(o)
			self.free[#self.free + 1] = o
		end
	end
	-- the wires follow the shake too
	if self.wire_shake_x ~= shake_x or self.wire_shake_y ~= shake_y then
		self.wire_shake_x, self.wire_shake_y = shake_x, shake_y
		for _, w in ipairs(self.wires) do
			M.apply(w.o, w.image, w.x + shake_x, w.y + shake_y, M.Z_WIRES, w.k, w.k, 0, w.flash or 0, nil, 1)
		end
	end
end

-- The wires overlay from game:cells() (wires = hp).
function View:set_wires(cells, g)
	local list = {}
	for y = 1, g.H do
		for x = 1, g.W do
			local c = cells[(y - 1) * g.W + x]
			if c and c.exists and (c.wires or 0) > 0 then
				local lx, ly = g:center(x, y)
				list[#list + 1] = { x = lx, y = ly, image = "blockers_wires_" .. math.min(2, c.wires), k = g.cell / 160 }
			end
		end
	end
	for i = 1, math.max(#list, #self.wires) do
		local w = self.wires[i]
		local d = list[i]
		if d then
			if not w then
				w = { o = M.create(self.factory.piece) }
				self.wires[i] = w
			end
			w.x, w.y, w.image, w.k = d.x, d.y, d.image, d.k
			M.apply(w.o, w.image, w.x + (self.wire_shake_x or 0), w.y + (self.wire_shake_y or 0), M.Z_WIRES, w.k, w.k, 0, 0, nil, 1)
		elseif w then
			M.hide(w.o)
			w.x, w.y = M.OFF.x, M.OFF.y
		end
	end
	-- keep only as many entries as there are wires (hidden ones stay pooled at the end)
	self.wires_n = #list
	for i = #self.wires, #list + 1, -1 do
		local w = self.wires[i]
		if w then
			go.delete(w.o.go)
			self.wires[i] = nil
		end
	end
end

-- Marks under / over the pieces: list of {image, x, y, w, h (logical px),
-- color = "#hex", alpha, glow = true (additive), z, rot}. Drawn until the next call.
function View:marks(list)
	local objs = self.mark_objs
	local used = { glow = 0, piece = 0 }
	for i = 1, #list do
		local m = list[i]
		local kind = m.glow and "glow" or "piece"
		used[kind] = used[kind] + 1
		objs[kind] = objs[kind] or {}
		local o = objs[kind][used[kind]]
		if not o then
			o = M.create(self.factory[kind])
			objs[kind][used[kind]] = o
		end
		local iw, ih = m.iw or 64, m.ih or 64
		local r, g, b = M.rgb(m.color or "#FFFFFF")
		M.apply(o, m.image or "fx_glow_dot", m.x, m.y, m.z or M.Z_MARK, m.w / iw, m.h / ih, m.rot or 0, 0, nil,
			m.alpha or 1, r, g, b)
	end
	for kind, arr in pairs(objs) do -- order-independent
		for i = used[kind] + 1, #arr do M.hide(arr[i]) end
	end
end

function View:stats()
	local n = 0
	for _ in pairs(self.by_id) do n = n + 1 end -- order-independent
	return { pieces = n, created = self.count, pooled = #self.free, wires = self.wires_n or 0, overflow = self.overflow }
end

function View:final()
	-- the collection is being unloaded: its objects go with it
	self.by_id, self.free, self.wires, self.mark_objs = {}, {}, {}, {}
end

return M
