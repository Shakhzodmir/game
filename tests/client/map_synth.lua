-- Synthetic content/map.json of any size for the scale tests (WP-13; not a test file itself). The geometry
-- follows tools/gen_map.py: districts of `per` levels, the path rises STEP per level and GAP at every gate.
-- Districts and pictures are the real ones (the five of the game, repeated), so every picture is in the registry.

local json = require("tools.lib.json")

local M = {}

local DISTRICTS = { "cafe", "jazz", "square", "stadium", "garage" }
local STEP, GAP, FIRST_Y, TOP_ROOM = 190, 480, 430, 800

local function read_real()
	local f = assert(io.open("content/map.json", "rb"))
	local text = f:read("*a")
	f:close()
	return json.decode(text)
end

-- opts = {per = levels per district (20)}
function M.make(n, opts)
	opts = opts or {}
	local per = opts.per or 20
	local d = read_real()
	local segs_n = math.ceil(n / per)
	local function seg_of(level) return math.floor((level - 1) / per) end
	local function y_of(level) return FIRST_Y + (level - 1) * STEP + seg_of(level) * GAP end
	local nodes = {}
	for level = 1, n do
		local at_gate = (level - 1) % per == 0 or level % per == 0
		nodes[level] = { level = level, x = at_gate and 360 or 360 + math.floor(170 * math.sin(level * 0.8) + 0.5), y = y_of(level) }
	end
	local world_h = y_of(n) + TOP_ROOM
	local segments = {}
	for i = 1, segs_n do
		local first, last = (i - 1) * per + 1, math.min(n, i * per)
		local did = DISTRICTS[(i - 1) % #DISTRICTS + 1]
		local y0 = i == 1 and 0 or math.floor((y_of(first - 1) + y_of(first)) / 2)
		local y1 = i == segs_n and world_h or math.floor((y_of(last) + y_of(last + 1)) / 2)
		local deco = {}
		for j = 0, 11 do
			deco[#deco + 1] = { image = "map/deco_" .. did .. "_" .. (j % 6 + 1), x = 360 + (j % 2 == 0 and -1 or 1) * 280,
				y = y0 + 420 + math.floor(((y1 - y0) - 900) * (j + 0.5) / 12) - 200, scale = 1 }
		end
		segments[i] = { id = "s" .. i, district = did, first = first, last = last, y0 = y0, y1 = y1,
			bg = "mapbg/bg_" .. did, gate = "mapbg/gate_" .. did, gate_y = i == 1 and 230 or y0, tint = "#E6E1F2", deco = deco }
	end
	d.level_count, d.nodes, d.segments, d.world_height = n, nodes, segments, world_h
	d.soon = { y = y_of(n) + 470 }
	return d
end

return M
