-- Effects of the board (pure Lua): turns core events (core-rules.md 16) into
-- timed effect commands that client/level_vfx.lua plays with sprites,
-- particles, shakes and GUI overlays. Nothing here changes the game; the
-- timings of bolts, rings, flights and rays follow the core (section 14),
-- everything else is a visual extra (client-architecture.md, 4.1).
--
--   local level_effects = require("client.level_effects")
--   local E = level_effects.new({geom = g, reduced = false, lookup = fn(id) -> piece | nil})
--   E:event(e)                 -- every event of every tick, in order
--   for _, c in ipairs(E:drain()) do ... end
--
-- Commands (x, y: logical px; at: display tick when it starts):
--   {kind = "burst", fx = "pop"|"sparkle"|"debris"|"dust"|"confetti"|"spark", x, y, color, count, at}
--   {kind = "flash", x, y, size, color, at, dur}                a soft light
--   {kind = "beam", x, y, dx, dy, len, speed, at, color, width} a bolt from (x, y) along (dx, dy);
--                                                               speed px per tick, len px
--   {kind = "ring", x, y, size, at, dur, color, image}          an expanding ring / shock wave
--   {kind = "fly", image, x0, y0, x1, y1, at, dur, trail, carry, axis} the Bird's arc
--   {kind = "ray", x0, y0, x1, y1, at, color}                   a Disco ray
--   {kind = "creep", x0, y0, x1, y1, at}                        noise creeping to a piece
--   {kind = "shake", amp, dur, at}                              board shake (px, seconds)
--   {kind = "screen_flash", color, alpha, dur, at}              the whole screen (fx GUI)
--   {kind = "slowmo", dur, scale, at}                           visual slow motion
--   {kind = "banner", key, at}                                  a banner (fx GUI), i18n key
--   {kind = "praise", word, index, wave, at}                    a praise word (fx GUI)
--   {kind = "floor", x, y, at}                                  a dance-floor tile lit (bg GUI pop)
--   {kind = "stinger", x, y, at}                                a microphone delivered
-- Reduced motion: no shakes, no slow motion, no screen flash; fewer particles.

local M = {}

-- main colour of each piece (art-direction.md, palette)
M.COLORS = {
	red = "#FF4468", orange = "#FF9A1F", yellow = "#FFDB1A",
	green = "#2BE38F", blue = "#3AA4FF", purple = "#9B52FF",
}
M.SPECIAL_COLORS = { riff = "#1FD1FF", sub = "#FF6FD8", bird = "#7EF0FF", disco = "#FFFFFF" }
M.DEBRIS = {
	record_box = { fx = "debris", color = "#FFB463" },
	concrete = { fx = "dust", color = "#C9C2B4" },
	noise = { fx = "dust", color = "#8A8FA3" },
	balloon = { fx = "confetti" },
	column = { fx = "sparkle", color = "#FFD84D" },
}
M.PRAISE_INDEX = { juicy = 1, hit = 2, drive = 3, vibe = 4, legend = 5 }
M.POP_COUNT = 10          -- particles of one cleared piece (8-12)
M.BOLT_TICKS_PER_CELL = 15 / 7  -- R(d) = (15 d + 6) // 7: 28 cells per second
M.LIGHT_TICKS_PER_CELL = 1      -- T.light_step (row / column light)
M.SHAKE = { sub = 6, bass_drop = 8, triple_cross = 6, finale = 10, stick = 4, trio = 5 }
M.FINALE_PAUSE = 24             -- T.finale_pause
M.SUB_SWELL = 6                 -- T.sub_swell
M.RING_TICKS = 2                -- T.ring (one ring step)

local Fx = {}
Fx.__index = Fx

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		geom = opts.geom,
		reduced = opts.reduced and true or false,
		lookup = opts.lookup or function() return nil end,
		queue = {},
		light = nil,     -- {booster, t}: the next bolts of this tick are a row/column light
		finale = nil,    -- tick of the running Grand finale activation
		combo = {},      -- tick -> combo name of activations this tick (their rings / bolts)
	}, Fx)
end

function Fx:set_geom(g)
	self.geom = g
end

function Fx:set_reduced(on)
	self.reduced = on and true or false
end

function Fx:push(c)
	local q = self.queue
	q[#q + 1] = c
	return c
end

function Fx:drain()
	local q = self.queue
	self.queue = {}
	return q
end

function M.color_of(name)
	return M.COLORS[name] or "#FFFFFF"
end

function Fx:center(x, y)
	return self.geom:center(x, y)
end

function Fx:burst(kind, x, y, color, count, at)
	if self.reduced then count = math.max(3, math.floor(count / 2)) end
	local lx, ly = self:center(x, y)
	return self:push({ kind = "burst", fx = kind, x = lx, y = ly, color = color, count = count, at = at })
end

function Fx:shake(amp, dur, at)
	if self.reduced or not amp or amp <= 0 then return end
	self:push({ kind = "shake", amp = amp, dur = dur or 0.3, at = at })
end

local DIRV = { l = { -1, 0 }, r = { 1, 0 }, u = { 0, 1 }, d = { 0, -1 } } -- logical (y up)

function Fx:event(e)
	local g = self.geom
	if not g then return end
	local ty, t = e.type, e.t or 0
	local cell = g.cell
	if ty == "clear" then
		if e.cause == "fired" then
			local lx, ly = self:center(e.x, e.y)
			self:push({ kind = "flash", x = lx, y = ly, size = cell * 2.2, color = M.SPECIAL_COLORS[e.special] or "#FFFFFF",
				at = t, dur = 0.3 })
		elseif e.kind == "regular" then
			self:burst("pop", e.x, e.y, M.color_of(e.color), M.POP_COUNT, t + 3)
		end
	elseif ty == "special_new" then
		local lx, ly = self:center(e.x, e.y)
		self:push({ kind = "flash", x = lx, y = ly, size = cell * 2.4, color = "#FFFFFF", at = t + 2, dur = 0.35 })
		self:burst("sparkle", e.x, e.y, M.SPECIAL_COLORS[e.special] or "#FFFFFF", 8, t + 4)
	elseif ty == "activate" then
		local lx, ly = self:center(e.x, e.y)
		local combo = e.combo
		self.combo[t] = combo
		if combo == "finale" then
			self.finale = t
			local at = t + M.FINALE_PAUSE
			self:push({ kind = "flash", x = lx, y = ly, size = cell * 5, color = "#FFFFFF", at = t, dur = 0.4 })
			if not self.reduced then
				self:push({ kind = "screen_flash", color = "#FFFFFF", alpha = 0.95, dur = 0.5, at = at })
				self:push({ kind = "slowmo", dur = 0.4, scale = 0.5, at = at })
			end
			self:shake(M.SHAKE.finale, 0.55, at)
		elseif combo then
			self:push({ kind = "flash", x = lx, y = ly, size = cell * 3.6, color = "#FFF3A6", at = t, dur = 0.4 })
			local amp = M.SHAKE[combo] or 5
			local at = t
			if combo == "bass_drop" or combo == "triple_cross" then at = t + M.SUB_SWELL end
			self:shake(amp, 0.4, at)
		elseif e.special == "sub" then
			self:push({ kind = "flash", x = lx, y = ly, size = cell * 1.8, color = M.SPECIAL_COLORS.sub, at = t, dur = 0.2 })
			self:shake(M.SHAKE.sub, 0.3, t + M.SUB_SWELL)
		elseif e.special == "disco" then
			self.disco_color = e.color
			self:push({ kind = "flash", x = lx, y = ly, size = cell * 2.6, color = M.color_of(e.color), at = t, dur = 0.45 })
		else
			self:push({ kind = "flash", x = lx, y = ly, size = cell * 2, color = M.SPECIAL_COLORS[e.special] or "#FFFFFF",
				at = t, dur = 0.3 })
		end
	elseif ty == "booster" then
		if e.booster == "row_light" or e.booster == "col_light" then
			self.light = { booster = e.booster, t = t }
		elseif e.booster == "stick" and e.at then
			local lx, ly = self:center(e.at[1], e.at[2])
			self:push({ kind = "flash", x = lx, y = ly, size = cell * 1.8, color = "#FFF3A6", at = t, dur = 0.3 })
			self:shake(M.SHAKE.stick, 0.2, t)
		end
	elseif ty == "bolt" then
		local d = DIRV[e.dir]
		if not d then return end
		local lx, ly = self:center(e.x, e.y)
		local run = g:run_length(e.x, e.y, e.dir) + 0.6
		local light = self.light and self.light.t == t
		local tpc = light and M.LIGHT_TICKS_PER_CELL or M.BOLT_TICKS_PER_CELL
		self:push({
			kind = "beam", x = lx, y = ly, dx = d[1], dy = d[2], len = run * cell,
			speed = cell / tpc, at = e.at or t,
			color = light and "#FFE66D" or M.SPECIAL_COLORS.riff, width = cell * (light and 0.9 or 0.62),
		})
	elseif ty == "ring" then
		local lx, ly = self:center(e.x, e.y)
		local r = e.r or 0
		local at = e.at or t
		local finale = self.finale and self.combo[self.finale] == "finale" and at >= self.finale
		if r == 0 then
			self:push({ kind = "flash", x = lx, y = ly, size = cell * 2.2, color = finale and "#FFFFFF" or M.SPECIAL_COLORS.sub,
				at = at, dur = 0.25 })
		else
			self:push({ kind = "ring", x = lx, y = ly, size = (2 * r + 1) * cell * 1.15, at = at, dur = 0.32,
				color = finale and "#FFF3A6" or "#FF6FD8", image = "fx_shock" })
		end
	elseif ty == "bird_fly" then
		local x0, y0 = self:center(e.x, e.y)
		local x1, y1 = self:center(e.tx, e.ty)
		self:push({ kind = "fly", image = "specials_bird", x0 = x0, y0 = y0, x1 = x1, y1 = y1, at = t,
			dur = math.max(e.duration or 33, 1), trail = M.SPECIAL_COLORS.bird,
			carry = e.carry and ("specials_" .. e.carry) or nil, axis = e.axis })
	elseif ty == "disco_ray" then
		local x0, y0 = self:center(e.x, e.y)
		local x1, y1 = self:center(e.tx, e.ty)
		local target = self.lookup_cell and self.lookup_cell(e.tx, e.ty)
		local color = self.disco_color or (target and target.color)
		self:push({ kind = "ray", x0 = x0, y0 = y0, x1 = x1, y1 = y1, at = t,
			color = color and M.color_of(color) or "#FFFFFF" })
	elseif ty == "transform" or ty == "concert_riff" or ty == "continue_riff" then
		self:burst("sparkle", e.x, e.y, "#FFD84D", 8, t)
	elseif ty == "hit" then
		if e.layer == "blocker" then
			local d = M.DEBRIS[e.item]
			if d then self:burst(d.fx == "sparkle" and "spark" or d.fx, e.x, e.y, d.color or "#FFFFFF", 4, t) end
		elseif e.layer == "wires" then
			self:burst("spark", e.x, e.y, "#FFB463", 5, t)
		end
	elseif ty == "destroy" then
		local d = M.DEBRIS[e.item] or { fx = "debris", color = "#FFFFFF" }
		local color = d.color
		if e.item == "balloon" then
			local p = self.lookup(e.id)
			color = M.color_of(p and p.color)
		end
		local x, y = e.x, e.y
		if e.item == "column" then
			local lx, ly = self:center(x, y)
			lx, ly = lx + cell / 2, ly - cell / 2
			self:push({ kind = "burst", fx = "sparkle", x = lx, y = ly, color = color, count = self.reduced and 6 or 14, at = t })
			self:push({ kind = "flash", x = lx, y = ly, size = cell * 3.2, color = "#FFE66D", at = t, dur = 0.45 })
		else
			self:burst(d.fx, x, y, color, 12, t)
		end
	elseif ty == "floor_lit" then
		self:burst("sparkle", e.x, e.y, "#FFD84D", 8, t)
		local lx, ly = self:center(e.x, e.y)
		self:push({ kind = "floor", x = e.x, y = e.y, lx = lx, ly = ly, at = t })
	elseif ty == "freed" then
		self:burst("spark", e.x, e.y, "#FFB463", 6, t)
	elseif ty == "mic_delivered" then
		local lx, ly = self:center(e.x, e.y)
		self:push({ kind = "stinger", x = lx, y = ly - cell * 0.5, at = t })
		self:push({ kind = "burst", fx = "sparkle", x = lx, y = ly - cell * 0.5, color = "#FFD84D",
			count = self.reduced and 5 or 10, at = t })
	elseif ty == "noise_spread" then
		local x0, y0 = self:center(e.fx, e.fy)
		local x1, y1 = self:center(e.x, e.y)
		self:push({ kind = "creep", x0 = x0, y0 = y0, x1 = x1, y1 = y1, at = t })
		self:burst("dust", e.x, e.y, "#8A8FA3", 6, t + 6)
	elseif ty == "shuffle" then
		self:push({ kind = "banner", key = "hud.shuffle", at = t })
	elseif ty == "praise" then
		self:push({ kind = "praise", word = e.word, index = M.PRAISE_INDEX[e.word] or 1, wave = e.wave, at = t })
	elseif ty == "state" then
		if e.state == "won_wait" and not self.reduced then
			self:push({ kind = "screen_flash", color = "#FFF6B8", alpha = 0.45, dur = 0.5, at = t })
		end
	end
end

-- Pieces by cell for the rays (the view sets it every frame): fn(x, y) -> piece | nil.
function Fx:set_cell_lookup(fn)
	self.lookup_cell = fn
end

return M
