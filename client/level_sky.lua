-- The sky of the level screen (pure Lua; screens/level/level_bg.gui_script draws it).
--
-- Every district can have its own level background (assets/images/districts/<id>/level_bg.png, 720x1280,
-- drawn WITHOUT clouds): assets.level_bg_key(district) falls back to the common backdrop. On top of it the
-- sky lives a little: by day small clouds drift slowly across it (fx/cloud, white, behind the board), in the
-- bright evening districts the stars twinkle (fx/spark). Nothing here is gameplay: with reduced motion
-- (app.reduced_motion) the sky stands still.
--
--   local sky = require("client.level_sky")
--   sky.district_of(list, level)    --> id of the district whose levels hold `level` | nil (list = the districts)
--   sky.kind(district, own_picture) --> "clouds" | "stars" (stars: an evening district with a picture of its own)
--   sky.items(kind, district)       --> the things of the sky, in drawing order: {key, w, h, ...}; same input,
--                                       same items (a plain table, never changes after that)
--   sky.pose(item, t, reduced)      --> x, y, alpha, scale of the item at time t (seconds); reduced: t is ignored

local M = {}

M.W, M.H = 720, 1280
M.MARGIN = 160 -- a cloud leaves and enters this far beyond the design area (a wider screen shows more of the sky)

-- the evening / night districts: a bright dusk with stars instead of clouds
M.NIGHT = { cinema = true, skyclub = true, bluesclub = true, arcade = true }

-- the clouds: y from the bottom of the design area, w = width on screen (the sprite is 2:1), speed in px/s (to the
-- right), x0 = where it is at t = 0. Different speeds and sizes: the near ones are bigger and quicker.
M.CLOUDS = {
	{ y = 1110, w = 250, speed = 9.0, x0 = 140, alpha = 0.95 },
	{ y = 985, w = 180, speed = 5.5, x0 = 560, alpha = 0.80 },
	{ y = 850, w = 140, speed = 4.0, x0 = 330, alpha = 0.70 },
	{ y = 690, w = 210, speed = 7.0, x0 = 40, alpha = 0.60 },
	{ y = 540, w = 160, speed = 3.5, x0 = 600, alpha = 0.55 },
	{ y = 390, w = 220, speed = 6.0, x0 = 250, alpha = 0.50 },
}

M.STARS = 22

function M.district_of(list, level)
	if type(list) ~= "table" or type(level) ~= "number" then return nil end
	for _, d in ipairs(list) do
		if type(d.first) == "number" and type(d.last) == "number" and level >= d.first and level <= d.last then
			return d.id
		end
	end
	return nil
end

-- Stars only over a district's own picture (it is drawn as a bright evening); the common backdrop is a day sky.
function M.kind(district, own_picture)
	return (own_picture and M.NIGHT[district]) and "stars" or "clouds"
end

-- a small deterministic generator (the stars of a district stand in the same places every time)
local function lcg(seed)
	local s = seed % 2147483647
	if s <= 0 then s = s + 2147483646 end
	return function()
		s = (s * 48271) % 2147483647
		return s / 2147483647
	end
end

local function seed_of(str)
	local h = 7
	for i = 1, #str do h = (h * 31 + str:byte(i)) % 2147483629 end
	return h + 1
end

function M.items(kind, district)
	local out = {}
	if kind == "stars" then
		local r = lcg(seed_of(district or "sky"))
		for i = 1, M.STARS do
			local size = 20 + math.floor(r() * 22)
			out[i] = {
				kind = "star", key = "fx/spark", w = size, h = size,
				x = 30 + r() * (M.W - 60), y = 880 + r() * 380, -- the top of the screen: the board hides the middle
				speed = 0.8 + r() * 1.6, phase = r() * 6.2832, alpha = 0.7 + r() * 0.3,
			}
		end
		return out
	end
	for i, c in ipairs(M.CLOUDS) do
		out[i] = { kind = "cloud", key = "fx/cloud", w = c.w, h = c.w / 2, x = c.x0, y = c.y, speed = c.speed, alpha = c.alpha }
	end
	return out
end

-- x, y, alpha, scale of an item at time t. A cloud drifts to the right and comes back from the left: the lane is
-- wider than the design area by its own width plus M.MARGIN on each side, so it enters and leaves out of sight.
function M.pose(item, t, reduced)
	if reduced then t = 0 end
	if item.kind == "cloud" then
		local pad = item.w + M.MARGIN
		local x = ((item.x + pad + item.speed * t) % (M.W + 2 * pad)) - pad
		return x, item.y, item.alpha, 1
	end
	local pulse = 0.5 + 0.5 * math.sin(item.phase + t * item.speed)
	if reduced then pulse = 0.5 end
	return item.x, item.y, item.alpha * (0.25 + 0.75 * pulse), 0.8 + 0.4 * pulse
end

return M
