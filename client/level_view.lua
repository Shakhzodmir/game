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
--   V:stats()                             -- {pieces, created, pooled, wires, overflow, repaired}
--   V:audit(ids, cells, geom)             -- the janitor's look at what the ENGINE has (see below)
--   V:final()
--
-- Sprites use screens/level/board.material: per-sprite vertex attributes
-- vcolor (tint, alpha) and vfx (x = clip line, y = white flash) keep the
-- whole board in a few batched draw calls.
--
-- Everything here trusts what it has sent to the engine (o.x ..., o.hidden, the cached look): that is how a frame
-- at rest costs no engine call (M.writes counts the calls: a board is calm while it stands still). The janitor of
-- the board (screens/level/board.script, once the board has been calm for a while) is the one place that asks the
-- engine itself where its objects are (audit_sprite, V:audit) and puts right and counts (stats().repaired) what
-- differs: a sprite that was hidden here and is drawn there, a piece that is not where it was put, a mark or a
-- wire nobody asked for.

local M = {}

M.MAX_PIECES = 150
M.OFF = vmath.vector3(-10000, -10000, 0)
M.NO_CLIP = 100000
M.MIN_SCALE = 0.001  -- go.set_scale refuses a component <= 0
M.Z_WIRES = 0.2
M.Z_MARK = 0.05
M.OFF_LIMIT = -9000   -- an object whose x is below this is out of sight (hidden at M.OFF)
M.EPS_POS = 0.5       -- logical px the position the engine reports may differ from the one put there (it keeps floats)
M.writes = 0          -- engine writes made by apply / hide so far: a screen that is still has the same number as a frame ago

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
	hex = hex or "#FFFFFF"
	local c = hex_cache[hex]
	if not c then
		local s = string.gsub(hex, "#", "")
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
		mark_objs = { glow = {}, piece = {} }, -- sprite objects of marks, by kind
		mark_n = { glow = 0, piece = 0 },      -- how many of them the last V:marks() call drew
		frame = 0,
		overflow = 0,    -- pieces that found no sprite in the pool (they are not drawn)
		repaired = 0,    -- sprites the janitor had to put right (V:audit)
	}, View)
end

-- A sprite object: {go, url, pos, scl, x, y, z, sx, sy, image, rot, flash, clip, alpha, r, g, b}.
-- pos and scl are the vectors handed to the engine; x, y, z, sx, sy are the same numbers as plain Lua numbers, which
-- is what the next frame is compared with: a vector keeps float32 (z = 0.1 reads back as 0.10000000149), so comparing
-- its components with the doubles of the next frame never matched, and every sprite of a board at rest was sent to the
-- engine twice per frame (position and scale: 162 calls a frame for 81 pieces, found in the real engine).
function M.create(factory_url)
	local id = factory.create(factory_url, M.OFF, nil, nil, 1)
	return {
		go = id, url = msg.url(nil, id, "sprite"),
		pos = vmath.vector3(M.OFF), scl = vmath.vector3(1, 1, 1),
		x = M.OFF.x, y = M.OFF.y, z = 0, sx = 1, sy = 1,
		image = nil, rot = 0, flash = 0, clip = M.NO_CLIP, alpha = 1, r = 1, g = 1, b = 1,
		vfx = vmath.vector4(M.NO_CLIP, 0, 0, 0), col = vmath.vector4(1, 1, 1, 1),
		hidden = true,
	}
end

function M.hide(o)
	if o.hidden then return end
	o.x, o.y = M.OFF.x, M.OFF.y
	o.pos.x, o.pos.y = M.OFF.x, M.OFF.y
	go.set_position(o.pos, o.go)
	M.writes = M.writes + 1
	-- remembered only once the engine has moved it away: a hide it refused (an error) is tried again, and a sprite
	-- that is on the screen is never taken for a hidden one
	o.hidden = true
end

-- Applies a look: image (anim id string), x, y, z, sx, sy (final scale), rot
-- (degrees), flash, clip (logical y or nil), alpha, r, g, b.
function M.apply(o, image, x, y, z, sx, sy, rot, flash, clip, alpha, r, g, b)
	o.hidden = false
	if o.x ~= x or o.y ~= y or o.z ~= z then
		local p = o.pos
		p.x, p.y, p.z = x, y, z
		go.set_position(p, o.go)
		o.x, o.y, o.z = x, y, z -- (remembered once the engine has taken it: a call it refused is made again)
		M.writes = M.writes + 1
	end
	if o.image ~= image then
		o.image = image
		sprite.play_flipbook(o.url, ah(image))
		M.writes = M.writes + 1
	end
	-- go.set_scale refuses a component <= 0 (an error in the log, the old scale stays): a piece that has
	-- shrunk to nothing keeps a hair of size instead
	if sx < M.MIN_SCALE then sx = M.MIN_SCALE end
	if sy < M.MIN_SCALE then sy = M.MIN_SCALE end
	if o.sx ~= sx or o.sy ~= sy then
		local s = o.scl
		s.x, s.y = sx, sy
		go.set_scale(s, o.go)
		o.sx, o.sy = sx, sy
		M.writes = M.writes + 1
	end
	rot = rot or 0
	if o.rot ~= rot then
		o.rot = rot
		go.set_rotation(vmath.quat_rotation_z(math.rad(rot)), o.go)
		M.writes = M.writes + 1
	end
	flash = flash or 0
	clip = clip or M.NO_CLIP
	if o.flash ~= flash or o.clip ~= clip then
		o.flash, o.clip = flash, clip
		o.vfx.x, o.vfx.y = clip, flash
		go.set(o.url, H_VFX, o.vfx)
		M.writes = M.writes + 1
	end
	alpha = alpha or 1
	r, g, b = r or 1, g or 1, b or 1
	if o.alpha ~= alpha or o.r ~= r or o.g ~= g or o.b ~= b then
		o.alpha, o.r, o.g, o.b = alpha, r, g, b
		local c = o.col
		c.x, c.y, c.z, c.w = r, g, b, alpha
		go.set(o.url, H_VCOLOR, c)
		M.writes = M.writes + 1
	end
end

-- Forgets what is remembered of a sprite object, so that the next apply sends all of it to the engine again. The
-- sentinels are finite (a NaN would reach go.set_position if a hide came before the next apply).
function M.forget(o)
	o.image, o.rot, o.flash, o.clip, o.alpha, o.r, o.g, o.b = nil, nil, nil, nil, nil, nil, nil, nil
	o.x, o.y, o.sx, o.sy = M.OFF.x, M.OFF.y, 0, 0
	o.pos.x, o.pos.y = M.OFF.x, M.OFF.y
	o.scl.x, o.scl.y = 0, 0
end

-- The janitor's look at one sprite object: asks the ENGINE where it is and compares that with what this side
-- believes. A sprite that should be out of sight (want_hidden, or hidden here) but is drawn is hidden for real; one
-- that should be drawn but is not where it was put is forgotten, so that the next apply sends it again. Returns 1
-- when it had to repair something, else 0. Allocates nothing in Lua (the engine hands out one vector).
function M.audit_sprite(o, want_hidden)
	local ok, p = pcall(go.get_position, o.go)
	if not ok or not p then return 0 end -- (the object is gone: nothing to put right)
	local off = p.x < M.OFF_LIMIT
	if want_hidden or o.hidden then
		if not off then
			o.hidden = false -- what it remembers is wrong, so the hide is not skipped
			M.hide(o)
			return 1
		end
		if not o.hidden then
			o.x, o.y, o.hidden = M.OFF.x, M.OFF.y, true
			o.pos.x, o.pos.y = M.OFF.x, M.OFF.y
			return 1
		end
	elseif off or math.abs(p.x - o.x) > M.EPS_POS or math.abs(p.y - o.y) > M.EPS_POS then
		M.forget(o)
		return 1
	end
	return 0
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
	-- The sprites of the pieces that left go back to the pool FIRST: a frame that replaces many pieces (the concert
	-- clears a big board and the refill comes in the same frame) would otherwise need the sprites of the leavers and of
	-- the arrivals at once, and the pool (MAX_PIECES) is not that big. A piece without a sprite is not drawn.
	for i = 1, #list do
		local o = by_id[list[i].id]
		if o then o.used = fr end
	end
	for id, o in pairs(by_id) do -- order-independent
		if o.used ~= fr then
			by_id[id] = nil
			M.hide(o)
			self.free[#self.free + 1] = o
		end
	end
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
				local hp = math.min(2, c.wires)
				list[#list + 1] = { x = lx, y = ly, hp = hp, image = "blockers_wires_" .. hp, k = g.cell / 160 }
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
			w.x, w.y, w.hp, w.image, w.k = d.x, d.y, d.hp, d.image, d.k
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
-- Nothing is allocated here: the sprites are pooled by kind and the list is read only.
function View:marks(list)
	local objs = self.mark_objs
	local n_glow, n_piece = 0, 0
	for i = 1, #list do
		local m = list[i]
		local arr, idx
		if m.glow then
			n_glow = n_glow + 1
			arr, idx = objs.glow, n_glow
		else
			n_piece = n_piece + 1
			arr, idx = objs.piece, n_piece
		end
		local o = arr[idx]
		if not o then
			o = M.create(self.factory[m.glow and "glow" or "piece"])
			arr[idx] = o
		end
		local iw, ih = m.iw or 64, m.ih or 64
		local r, g, b = M.rgb(m.color or "#FFFFFF")
		M.apply(o, m.image or "fx_glow_dot", m.x, m.y, m.z or M.Z_MARK, m.w / iw, m.h / ih, m.rot or 0, 0, nil,
			m.alpha or 1, r, g, b)
	end
	local glow, piece = objs.glow, objs.piece
	for i = n_glow + 1, #glow do M.hide(glow[i]) end
	for i = n_piece + 1, #piece do M.hide(piece[i]) end
	self.mark_n.glow, self.mark_n.piece = n_glow, n_piece
end

function View:stats()
	local n = 0
	for _ in pairs(self.by_id) do n = n + 1 end -- order-independent
	return { pieces = n, created = self.count, pooled = #self.free, wires = self.wires_n or 0, overflow = self.overflow,
		repaired = self.repaired, writes = M.writes }
end

-- Is the wires overlay not the core's? (cells = game:cells(), g = the geometry: compares the place and the strength of
-- every wired cell with the sprite that is meant to show it, in the order set_wires lays them out. Allocates nothing.)
function View:wires_differ(cells, g)
	local wires = self.wires
	local n = 0
	for y = 1, g.H do
		for x = 1, g.W do
			local c = cells[(y - 1) * g.W + x]
			if c and c.exists and (c.wires or 0) > 0 then
				n = n + 1
				local w = wires[n]
				local lx, ly = g:center(x, y)
				if not w or w.x ~= lx or w.y ~= ly or w.hp ~= math.min(2, c.wires) then return true end
			end
		end
	end
	return n ~= #wires or n ~= (self.wires_n or 0)
end

-- The janitor's look at the whole view (screens/level/board.script, a board that has been calm for a while):
-- ids = {[piece id] = true} of the pieces the core has now; cells, g = game:cells() and the geometry (nil: the wires
-- are not looked at). Puts right and counts (also in stats().repaired) what differs, and returns the number of repairs:
--   * the sprite of a piece the core no longer has is hidden and taken back;
--   * a sprite the engine draws although it was hidden here (a pooled one, the marks past the last call, ...), or that
--     is not where it was put, is repaired (audit_sprite); when it is a piece's, every piece is sent again;
--   * a wires overlay that is not the core's is laid out again.
function View:audit(ids, cells, g)
	local fixed = 0
	local by_id = self.by_id
	for id, o in pairs(by_id) do -- order-independent
		if not ids[id] then
			by_id[id] = nil
			o.hidden = false
			M.hide(o)
			self.free[#self.free + 1] = o
			fixed = fixed + 1
		else
			fixed = fixed + M.audit_sprite(o, false)
		end
	end
	if fixed > 0 then
		-- if one was wrong, nothing says the others are right: the next sync sends all of them again
		for _, o in pairs(by_id) do M.forget(o) end -- order-independent
	end
	local free = self.free
	for i = 1, #free do fixed = fixed + M.audit_sprite(free[i], true) end
	local objs, mn = self.mark_objs, self.mark_n
	for i = 1, #objs.glow do fixed = fixed + M.audit_sprite(objs.glow[i], i > mn.glow) end
	for i = 1, #objs.piece do fixed = fixed + M.audit_sprite(objs.piece[i], i > mn.piece) end
	local wires = self.wires
	for i = 1, #wires do fixed = fixed + M.audit_sprite(wires[i].o, false) end
	if cells and g and self:wires_differ(cells, g) then
		self:set_wires(cells, g)
		fixed = fixed + 1
	end
	self.repaired = self.repaired + fixed
	return fixed
end

function View:final()
	-- the collection is being unloaded: its objects go with it
	self.by_id, self.free, self.wires, self.mark_objs = {}, {}, {}, { glow = {}, piece = {} }
	self.mark_n = { glow = 0, piece = 0 }
end

return M
