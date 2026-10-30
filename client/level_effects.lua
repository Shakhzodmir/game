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
-- Commands (x, y: logical px; at: display tick when it starts; dur in seconds
-- unless the kind says ticks):
--   {kind = "burst", fx = "pop"|"sparkle"|"debris"|"dust"|"confetti"|"spark", x, y, color, count, at}
--   {kind = "flash", x, y, size, color, at, dur}                a soft light
--   {kind = "charge", x, y, size, color, at, dur}               a glow that swells for dur TICKS (a Sabwoofer
--                                                               swelling, the Grand finale charging)
--   {kind = "beam", x, y, dx, dy, len, speed, at, color, width, core, mode = "comet"|"band"}
--                                                               a bolt from (x, y) along (dx, dy); speed px per tick,
--                                                               len px; a comet has a bright head and a dim tail
--   {kind = "ring", x, y, size, at, dur, color, image}          an expanding ring / shock wave
--   {kind = "fly", image, x0, y0, x1, y1, at, dur, trail, carry, axis, fan}  the Bird's arc (dur in ticks;
--                                                               fan -1, 0, 1 spreads the three birds of a Trio)
--   {kind = "reticle", x, y, size, color, at, dur}              the Bird's target closing in (dur in ticks)
--   {kind = "ray", x0, y0, x1, y1, at, color, width}            a Disco ray (width in cells)
--   {kind = "ghost", image, x, y, s0, s1, rot0, rot1, a0, a1, dy, dur, at}  a lingering copy of a destroyed thing
--   {kind = "creep", x0, y0, x1, y1, at}                        noise creeping to a piece
--   {kind = "shake", amp, dur, at}                              board shake (px, seconds)
--   {kind = "screen_flash", color, alpha, dur, at}              the whole screen (fx GUI)
--   {kind = "slowmo", dur, scale, at}                           visual slow motion
--   {kind = "banner", key, at}                                  a banner (fx GUI), i18n key
--   {kind = "praise", word, index, wave, at}                    a praise word (fx GUI)
--   {kind = "floor", x, y, at}                                  a dance-floor tile lit (bg GUI pop)
--   {kind = "stinger", x, y, at}                                a microphone delivered
-- (the Crossfader's exchange is flashes and a burst in each of its two cells: H.exchange)
--
-- Each of the ten combos has its own picture (M.COMBO_LOOK; tests/client/level_effects_test.lua
-- checks that no two look alike): a Cross is four fat cyan bolts, a Triple cross a pink and cyan
-- grid of twelve, a Bass drop four violet shock rings under a pulse of the screen, a Bird with a
-- Riff or a Sabwoofer carries the special's icon and fires it where it lands, a Trio fans three
-- birds, "Colour X" sends a ray of X to every piece it turns into a special, and the Grand
-- finale charges gold for 0.4 s, flashes white, slows down, shakes and rains confetti.
-- Reduced motion: no shakes, no slow motion, no screen flash, no charge; fewer particles.

local M = {}

-- main colour of each piece (art-direction.md, palette)
M.COLORS = {
	red = "#FF4468", orange = "#FF9A1F", yellow = "#FFDB1A",
	green = "#2BE38F", blue = "#3AA4FF", purple = "#9B52FF",
}
M.RAINBOW = { "#FF4468", "#FF9A1F", "#FFDB1A", "#2BE38F", "#3AA4FF", "#9B52FF" }
M.SPECIAL_COLORS = { riff = "#1FD1FF", sub = "#FF6FD8", bird = "#7EF0FF", disco = "#FFFFFF" }
-- The board is bright, so lights are saturated colours (a white or pastel glow would vanish on
-- the white cells): the colour each special glows in.
M.GLOW = { riff = "#1FB8FF", sub = "#FF4FC8", bird = "#1FA8E6", disco = "#B38CFF" }
M.GOLD = "#FFB020"
M.LIGHT_BEAM = "#FFC21A"  -- row / column spotlight
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
M.SHAKE = { sub = 6, bass_drop = 8, triple_cross = 6, finale = 10, stick = 4, trio = 3, cross = 5, concrete = 3,
	column = 5, bird_riff = 3, bird_sub = 4 }
M.FINALE_PAUSE = 24             -- T.finale_pause
M.SUB_SWELL = 6                 -- T.sub_swell
M.RING_TICKS = 2                -- T.ring (one ring step)
M.BEAM_WIDTH = { riff = 0.62, cross = 0.95, triple_cross = 0.8, light = 0.9 }
M.COMBOS = { "cross", "triple_cross", "bass_drop", "bird_riff", "bird_sub", "trio", "finale", "color_riff",
	"color_sub", "color_bird" }

-- What each combo looks like (the colours of its flash, bolts, rings and rays).
M.COMBO_LOOK = {
	cross = { flash = "#1FB8FF", beam = "#1FD1FF" },
	triple_cross = { flash = "#FF4FC8", beam_h = "#1FD1FF", beam_v = "#FF4FC8" },
	bass_drop = { flash = "#8B45FF", ring = { "#FF4FC8", "#8B45FF" }, screen = "#B38CFF" },
	bird_riff = { flash = "#1FB8FF", trail = "#1FB8FF" },
	bird_sub = { flash = "#FF4FC8", trail = "#FF4FC8" },
	trio = { flash = "#1FA8E6", trail = "#1FA8E6", ring = "#1FA8E6" },
	finale = { flash = "#FFB020" },
	color_riff = { flash = "#1FB8FF", special = "riff" },
	color_sub = { flash = "#FF4FC8", special = "sub" },
	color_bird = { flash = "#22C55E", special = "bird" },
}

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
		cur = nil,       -- {combo, special, color, t, x, y}: the activation whose bolts / rings / rays follow
		fly = { t = -1, n = 0 }, -- birds that took off in this tick (a Trio has three)
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

function Fx:flash(x, y, size, color, at, dur)
	return self:push({ kind = "flash", x = x, y = y, size = size, color = color, at = at, dur = dur })
end

local DIRV = { l = { -1, 0 }, r = { 1, 0 }, u = { 0, 1 }, d = { 0, -1 } } -- logical (y up)

-- Handlers by event type ---------------------------------------------------------------

local H = {}

function H.clear(self, e)
	local t = e.t or 0
	if e.cause == "fired" then
		local lx, ly = self:center(e.x, e.y)
		self:flash(lx, ly, self.geom.cell * 2.2, M.GLOW[e.special] or M.GOLD, t, 0.3)
	elseif e.kind == "regular" then
		self:burst("pop", e.x, e.y, M.color_of(e.color), M.POP_COUNT, t + 3)
	end
end

function H.special_new(self, e)
	local t = e.t or 0
	local cell = self.geom.cell
	local lx, ly = self:center(e.x, e.y)
	-- the pieces of the group fly in for T.clear; the special blooms as they arrive
	local at = t + 5
	self:flash(lx, ly, cell * 2.4, M.GOLD, at, 0.35)
	self:burst("sparkle", e.x, e.y, "#FFD84D", 8, at + 2)
	if e.special == "disco" then
		self:push({ kind = "ring", x = lx, y = ly, size = cell * 3.4, at = at, dur = 0.45, color = M.GLOW.disco, image = "fx_shock" })
	elseif e.special == "sub" then
		self:push({ kind = "ring", x = lx, y = ly, size = cell * 2.6, at = at, dur = 0.35, color = M.GLOW.sub, image = "fx_ring" })
	end
end

function H.activate(self, e)
	local g = self.geom
	local t = e.t or 0
	local cell = g.cell
	local lx, ly = self:center(e.x, e.y)
	local combo = e.combo
	self.cur = { combo = combo, special = e.special, color = e.color, t = t, x = lx, y = ly, cx = e.x, cy = e.y }
	if combo == "finale" then
		local at = t + M.FINALE_PAUSE
		if not self.reduced then
			-- 0.4 s of charging, then the white flash, the slow motion and the shake
			self:push({ kind = "charge", x = lx, y = ly, size = cell * 8, color = M.GOLD, at = t, dur = M.FINALE_PAUSE })
			self:push({ kind = "screen_flash", color = "#FFFFFF", alpha = 0.95, dur = 0.5, at = at })
			self:push({ kind = "slowmo", dur = 0.4, scale = 0.5, at = at })
		end
		self:flash(lx, ly, cell * 9, M.GOLD, at, 0.5)
		self:shake(M.SHAKE.finale, 0.55, at)
		-- confetti over the whole board: the middle and four corners of it
		local r = g.rect
		local mx, my = (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2
		local w, h = (r.x1 - r.x0) / 4, (r.y1 - r.y0) / 4
		local spots = { { mx, my }, { mx - w, my + h }, { mx + w, my + h }, { mx - w, my - h }, { mx + w, my - h } }
		for i = 1, #spots do
			self:push({ kind = "burst", fx = "confetti", x = spots[i][1], y = spots[i][2],
				color = M.RAINBOW[i], count = self.reduced and 5 or 12, at = at + i })
		end
	elseif combo then
		local look = M.COMBO_LOOK[combo] or {}
		self:flash(lx, ly, cell * 3.6, look.flash or M.GOLD, t, 0.4)
		if combo == "cross" then
			self:push({ kind = "ring", x = lx, y = ly, size = cell * 2.6, at = t, dur = 0.3, color = look.beam, image = "fx_ring" })
			self:shake(M.SHAKE.cross, 0.4, t)
		elseif combo == "triple_cross" then
			-- both specials swell, then twelve bolts
			if not self.reduced then
				self:push({ kind = "charge", x = lx, y = ly, size = cell * 3.4, color = M.GLOW.sub, at = t, dur = M.SUB_SWELL })
			end
			self:shake(M.SHAKE.triple_cross, 0.4, t + M.SUB_SWELL)
		elseif combo == "bass_drop" then
			if not self.reduced then
				self:push({ kind = "charge", x = lx, y = ly, size = cell * 4.4, color = "#8B45FF", at = t, dur = M.SUB_SWELL })
				self:push({ kind = "screen_flash", color = look.screen, alpha = 0.3, dur = 0.4, at = t + M.SUB_SWELL })
			end
			self:shake(M.SHAKE.bass_drop, 0.45, t + M.SUB_SWELL)
		elseif combo == "trio" then
			self:push({ kind = "ring", x = lx, y = ly, size = cell * 3, at = t, dur = 0.35, color = look.ring, image = "fx_ring" })
			self:shake(M.SHAKE.trio, 0.25, t)
		elseif combo == "bird_riff" or combo == "bird_sub" then
			self:burst("sparkle", e.x, e.y, look.trail, 8, t)
			self:shake(M.SHAKE[combo], 0.25, t)
		else
			-- "Colour X": the ball sends X rays to its pieces (see transform); a ring in X
			local x_color = e.color and M.color_of(e.color) or M.GOLD
			self:push({ kind = "ring", x = lx, y = ly, size = cell * 3.4, at = t, dur = 0.45, color = x_color, image = "fx_shock" })
			self:shake(4, 0.3, t)
		end
	elseif e.special == "sub" then
		self:flash(lx, ly, cell * 1.8, M.GLOW.sub, t, 0.2)
		if not self.reduced then
			self:push({ kind = "charge", x = lx, y = ly, size = cell * 2.8, color = M.GLOW.sub, at = t, dur = M.SUB_SWELL })
		end
		self:shake(M.SHAKE.sub, 0.3, t + M.SUB_SWELL)
	elseif e.special == "disco" then
		local c = M.color_of(e.color)
		self:flash(lx, ly, cell * 2.6, c, t, 0.45)
		self:push({ kind = "ring", x = lx, y = ly, size = cell * 2.8, at = t, dur = 0.4, color = c, image = "fx_ring" })
	elseif e.special == "bird" then
		self:flash(lx, ly, cell * 2, M.GLOW.bird, t, 0.3)
		self:burst("sparkle", e.x, e.y, "#7EF0FF", 6, t)
	else
		self:flash(lx, ly, cell * 2, M.GLOW.riff, t, 0.3)
	end
end

function H.booster(self, e)
	local t = e.t or 0
	local cell = self.geom.cell
	self.cur = nil
	if e.booster == "remix" and e.ok ~= false then
		self.remix_t = t -- the shuffle that follows in this tick is the player's own (H.shuffle)
	end
	if e.booster == "row_light" or e.booster == "col_light" then
		self.light = { booster = e.booster, t = t }
	elseif e.booster == "stick" and e.at then
		local lx, ly = self:center(e.at[1], e.at[2])
		self:flash(lx, ly, cell * 1.8, M.GOLD, t, 0.3)
		self:burst("spark", e.at[1], e.at[2], "#FFB020", 5, t)
		self:shake(M.SHAKE.stick, 0.2, t)
	end
end

-- The Crossfader: the two pieces leave in the two colours of the slider (cyan from the first cell, magenta from
-- the second) and land in the other's colour, with a sparkle in each cell. The flight itself is level_anim's.
function H.exchange(self, e)
	local t = e.t or 0
	local cell = self.geom.cell
	local at = t + math.max(e.duration or 18, 1)
	for k = 1, 2 do
		local c = (k == 1) and e.a or e.b
		local from, to = (k == 1) and M.GLOW.riff or M.GLOW.sub, (k == 1) and M.GLOW.sub or M.GLOW.riff
		local lx, ly = self:center(c[1], c[2])
		self:flash(lx, ly, cell * 1.9, from, t, 0.3)
		self:flash(lx, ly, cell * 2.1, to, at, 0.4)
		self:burst("sparkle", c[1], c[2], to, 8, at)
	end
end

function H.bolt(self, e)
	local g = self.geom
	local t = e.t or 0
	local d = DIRV[e.dir]
	if not d then return end
	local cell = g.cell
	local lx, ly = self:center(e.x, e.y)
	local run = g:run_length(e.x, e.y, e.dir) + 0.6
	local light = self.light and self.light.t == t
	local combo = (not light and self.cur and self.cur.t == t) and self.cur.combo or nil
	local tpc = light and M.LIGHT_TICKS_PER_CELL or M.BOLT_TICKS_PER_CELL
	local color, width, core, mode = M.SPECIAL_COLORS.riff, M.BEAM_WIDTH.riff, true, "comet"
	if light then
		color, width, core, mode = M.LIGHT_BEAM, M.BEAM_WIDTH.light, false, "band"
	elseif combo == "cross" then
		color, width = M.COMBO_LOOK.cross.beam, M.BEAM_WIDTH.cross
	elseif combo == "triple_cross" then
		local look = M.COMBO_LOOK.triple_cross
		color = (e.dir == "l" or e.dir == "r") and look.beam_h or look.beam_v
		width, core = M.BEAM_WIDTH.triple_cross, false
	end
	self:push({
		kind = "beam", x = lx, y = ly, dx = d[1], dy = d[2], len = run * cell, speed = cell / tpc, at = e.at or t,
		color = color, width = cell * width, core = core, mode = mode,
	})
end

function H.ring(self, e)
	local g = self.geom
	local t = e.t or 0
	local cell = g.cell
	local lx, ly = self:center(e.x, e.y)
	local r = e.r or 0
	local at = e.at or t
	local cur = self.cur
	local combo = (cur and cur.t == t) and cur.combo or nil
	if combo == "finale" then
		-- the finale's rings run through the colours of the pieces
		local color = M.RAINBOW[r % #M.RAINBOW + 1]
		if r == 0 then
			self:flash(lx, ly, cell * 2.6, M.GOLD, at, 0.3)
		else
			self:push({ kind = "ring", x = lx, y = ly, size = (2 * r + 1) * cell * 1.15, at = at, dur = 0.34,
				color = color, image = "fx_shock" })
		end
	elseif combo == "bass_drop" then
		local look = M.COMBO_LOOK.bass_drop.ring
		local color = look[r % 2 + 1]
		if r == 0 then
			self:flash(lx, ly, cell * 2.8, "#8B45FF", at, 0.3)
		end
		self:push({ kind = "ring", x = lx, y = ly, size = (2 * r + 1) * cell * 1.3, at = at, dur = 0.4, color = color,
			image = "fx_shock" })
	elseif r == 0 then
		self:flash(lx, ly, cell * 2.2, M.GLOW.sub, at, 0.25)
	else
		self:push({ kind = "ring", x = lx, y = ly, size = (2 * r + 1) * cell * 1.15, at = at, dur = 0.32,
			color = M.GLOW.sub, image = "fx_shock" })
	end
end

function H.bird_fly(self, e)
	local g = self.geom
	local t = e.t or 0
	local cell = g.cell
	local x0, y0 = self:center(e.x, e.y)
	local x1, y1 = self:center(e.tx, e.ty)
	local fl = self.fly
	if fl.t == t then fl.n = fl.n + 1 else fl.t, fl.n = t, 1 end
	local cur = self.cur
	local combo = (cur and cur.t == t) and cur.combo or nil
	local fan = 0
	if combo == "trio" then fan = fl.n - 2 end
	local trail = (combo and M.COMBO_LOOK[combo] and M.COMBO_LOOK[combo].trail) or M.GLOW.bird
	local dur = math.max(e.duration or 33, 1)
	self:push({ kind = "fly", image = "specials_bird", x0 = x0, y0 = y0, x1 = x1, y1 = y1, at = t, dur = dur,
		trail = trail, carry = e.carry and ("specials_" .. e.carry) or nil, axis = e.axis, fan = fan })
	-- the target closes in while the bird is on its way
	local rc = e.carry and M.GLOW[e.carry] or M.GLOW.bird
	self:push({ kind = "reticle", x = x1, y = y1, size = cell * (e.carry and 1.5 or 1.2), color = rc, at = t, dur = dur })
end

function H.disco_ray(self, e)
	local t = e.t or 0
	local x0, y0 = self:center(e.x, e.y)
	local x1, y1 = self:center(e.tx, e.ty)
	local cur = self.cur
	local target = self.lookup_cell and self.lookup_cell(e.tx, e.ty)
	local color = (cur and cur.color) or (target and target.color)
	self:push({ kind = "ray", x0 = x0, y0 = y0, x1 = x1, y1 = y1, at = t,
		color = color and M.color_of(color) or M.GLOW.disco })
end

function H.transform(self, e)
	local t = e.t or 0
	local cell = self.geom.cell
	local cur = self.cur
	local lx, ly = self:center(e.x, e.y)
	local sc = M.GLOW[e.special] or M.GOLD
	-- the ball sends a ray of X to the piece that turns into a special
	if cur and cur.combo and M.COMBO_LOOK[cur.combo] and M.COMBO_LOOK[cur.combo].special then
		self:push({ kind = "ray", x0 = cur.x, y0 = cur.y, x1 = lx, y1 = ly, at = t,
			color = cur.color and M.color_of(cur.color) or M.GLOW.disco, width = 0.34 })
	end
	self:flash(lx, ly, cell * 1.7, sc, t, 0.3)
	self:burst("sparkle", e.x, e.y, sc, 8, t)
end

function H.concert_riff(self, e)
	local t = e.t or 0
	local cell = self.geom.cell
	local lx, ly = self:center(e.x, e.y)
	self:flash(lx, ly, cell * 1.6, M.GLOW.riff, t, 0.3)
	self:burst("sparkle", e.x, e.y, "#FFD84D", 8, t)
end
H.continue_riff = H.concert_riff

function H.hit(self, e)
	local t = e.t or 0
	local cell = self.geom.cell
	if e.layer == "blocker" then
		local d = M.DEBRIS[e.item]
		if d then self:burst(d.fx == "sparkle" and "spark" or d.fx, e.x, e.y, d.color or "#FFFFFF", 4, t) end
	elseif e.layer == "wires" then
		self:burst("spark", e.x, e.y, "#FFB463", 5, t)
	elseif e.layer == "floor" and (e.hp or 0) > 0 then
		-- the tile cracks: a quick white blink
		local lx, ly = self:center(e.x, e.y)
		self:flash(lx, ly, cell * 1.5, "#FFD84D", t, 0.22)
	end
end

function H.destroy(self, e)
	local t = e.t or 0
	local cell = self.geom.cell
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
		self:flash(lx, ly, cell * 3.2, "#FFC933", t, 0.45)
		self:push({ kind = "ring", x = lx, y = ly, size = cell * 3, at = t, dur = 0.4, color = "#FFD84D", image = "fx_shock" })
		-- the speaker powers on and keeps glowing while the dust settles (the object itself leaves
		-- with T.clear, 9 ticks)
		self:push({ kind = "ghost", image = "blockers_column_on", x = lx, y = ly, s0 = 1, s1 = 1.3, a0 = 1, a1 = 0,
			dur = 0.5, at = t + 9 })
		self:shake(M.SHAKE.column, 0.3, t)
	else
		self:burst(d.fx, x, y, color, 12, t)
		if e.item == "concrete" then self:shake(M.SHAKE.concrete, 0.2, t) end
	end
end

function H.floor_lit(self, e)
	local t = e.t or 0
	local cell = self.geom.cell
	self:burst("sparkle", e.x, e.y, "#FFD84D", 8, t)
	local lx, ly = self:center(e.x, e.y)
	self:flash(lx, ly, cell * 1.9, "#FFC933", t, 0.45)
	self:push({ kind = "floor", x = e.x, y = e.y, lx = lx, ly = ly, at = t })
end

function H.freed(self, e)
	local t = e.t or 0
	local lx, ly = self:center(e.x, e.y)
	self:burst("spark", e.x, e.y, "#FFB463", 6, t)
	-- the cable snaps off and drops away
	self:push({ kind = "ghost", image = "blockers_wires_1", x = lx, y = ly, s0 = 1, s1 = 1.35, rot0 = 0, rot1 = 28, a0 = 1,
		a1 = 0, dy = -self.geom.cell * 0.35, dur = 0.38, at = t })
end

function H.mic_delivered(self, e)
	local t = e.t or 0
	local cell = self.geom.cell
	local lx, ly = self:center(e.x, e.y)
	self:push({ kind = "stinger", x = lx, y = ly - cell * 0.5, at = t })
	self:push({ kind = "burst", fx = "sparkle", x = lx, y = ly - cell * 0.5, color = "#FFD84D",
		count = self.reduced and 5 or 10, at = t })
end

function H.noise_spread(self, e)
	local t = e.t or 0
	local x0, y0 = self:center(e.fx, e.fy)
	local x1, y1 = self:center(e.x, e.y)
	self:push({ kind = "creep", x0 = x0, y0 = y0, x1 = x1, y1 = y1, at = t })
	self:burst("dust", e.x, e.y, "#8A8FA3", 6, t + 6)
end

function H.shuffle(self, e)
	-- the banner explains the automatic shuffle ("No moves"); the player's own Remix (a `booster` event of
	-- this very tick) needs no explanation
	if self.remix_t ~= nil and self.remix_t == (e.t or 0) then
		self.remix_t = nil
		return
	end
	self:push({ kind = "banner", key = "hud.shuffle", at = e.t or 0 })
end

function H.praise(self, e)
	self:push({ kind = "praise", word = e.word, index = M.PRAISE_INDEX[e.word] or 1, wave = e.wave, at = e.t or 0 })
end

function H.state(self, e)
	local t = e.t or 0
	if self.reduced then return end
	if e.state == "won_wait" then
		self:push({ kind = "screen_flash", color = "#FFF6B8", alpha = 0.45, dur = 0.5, at = t })
	elseif e.state == "concert" then
		self:push({ kind = "screen_flash", color = "#FFE66D", alpha = 0.4, dur = 0.6, at = t })
	end
end

-- Every event of every tick, in order.
function Fx:event(e)
	if not self.geom then return end
	local h = H[e.type]
	if h then h(self, e) end
end

-- Pieces by cell for the rays (the view sets it every frame): fn(x, y) -> piece | nil.
function Fx:set_cell_lookup(fn)
	self.lookup_cell = fn
end

return M
