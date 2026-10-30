-- A picture of the level board without Defold: runs screens/level/board.script on the
-- strict stub of tests/client/level_defold_stub.lua and writes the sprites and particle
-- batches of chosen frames to a JSON file; tests/client/level_snapshot.py draws it.
--
--   lua5.1 tests/client/level_snapshot.lua <scenario> <out.json> [frames = 6,12,20]
--   python3 tests/client/level_snapshot.py <out.json> <out.png> [x0,y0,x1,y1 crop] [scale]
--
-- Run from the repository root. Frames count from the command of the scenario (1 frame =
-- 1/60 s; the swap of a combo ends after 10 ticks, so its effects start around frame 13).
-- Scenarios:
--   combo:<name>   two specials side by side on a random 7x7 board, swapped: cross, triple_cross,
--                  bass_drop, bird_riff, bird_sub, trio, finale, color_riff, color_sub, color_bird
--   single:<id>    one special tapped: riff, sub, bird, disco
--   light:<row|col>  the row / column spotlight booster
--   blockers_a     a Sabwoofer next to a column, a record box and wires
--   spawn          the first move of level 3 that makes a special (frames 29-40 show the gather)
--   play:<n>       level n played by the QA autoplay (frames count from the start)
--   idle           level 1 left alone: the intro bloom (frames 1-40) and the hint after 5 s (frames 300-340)
-- What is drawn is what the engine would get: the positions, scales, rotations, tints, flashes
-- and clip lines the scripts set. Backgrounds (sky, cells) are approximated by the renderer.

package.path = "./?.lua;./?/init.lua;" .. package.path
local stub = require("tests.client.level_defold_stub")
local app = require("client.app")
local bus = require("client.bus")
local save_io = require("client.save_io")
local H = require("tests.meta.helper")
local CH = require("tests.core.helper")
local json = require("tools.lib.json")
local analytics = require("client.services.analytics")

local scenario, outpath, framespec = arg[1], arg[2], arg[3] or "6,12,20"
if not (scenario and outpath) then
	print("usage: lua5.1 tests/client/level_snapshot.lua <scenario> <out.json> [frames]")
	os.exit(1)
end
local frames = {}
for f in framespec:gmatch("%d+") do frames[#frames + 1] = tonumber(f) end

local PAIRS = {
	cross = { "R", "R" }, triple_cross = { "R", "S" }, bass_drop = { "S", "S" }, bird_riff = { "B", "R" },
	bird_sub = { "B", "S" }, trio = { "B", "B" }, finale = { "D", "D" }, color_riff = { "D", "R" },
	color_sub = { "D", "S" }, color_bird = { "D", "B" },
}

local E = stub.install({})
analytics.init({ strict = true })
app.init({ districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
	now = H.T0, clock = function() return H.T0 end, sys_language = "en" })

local level_id = 1
local level, command, autoplay
local kind, name = scenario:match("^([%w_]+):?(.*)$")
local function plain7(mid)
	return { "#######", "#######", "#######", mid or "#######", "#######", "#######", "#######" }
end
if kind == "combo" then
	local p = assert(PAIRS[name], "unknown combo " .. name)
	level = CH.level(plain7("###" .. p[1] .. p[2] .. "##"), { moves = 10 })
	command = { type = "swap", from = { 4, 4 }, to = { 5, 4 } }
elseif kind == "single" then
	local letter = assert(({ riff = "R", sub = "S", bird = "B", disco = "D" })[name], "unknown special " .. name)
	level = CH.level(plain7("###" .. letter .. "###"), { moves = 10 })
	command = { type = "tap", at = { 4, 4 } }
elseif kind == "light" then
	level = CH.level(plain7(), { moves = 10 })
	command = { type = "booster", booster = name == "col" and "col_light" or "row_light", row = 4, col = 4 }
elseif kind == "blockers_a" then
	level = {
		id = 1, version = 1, size = { 7, 8 }, moves = 12, difficulty = "easy",
		colors = { "red", "orange", "yellow", "green", "blue" },
		goals = { { type = "break", item = "column", count = 1 } },
		cells = { "#######", "#######", "#######", "#######", "#######", "#######", "#######", "#######" },
		overlay = { { at = { 5, 5 }, type = "wires", hp = 2 } },
		slots = { { at = { 2, 1 }, type = "column", hp = 6 }, { at = { 5, 2 }, type = "record_box", hp = 3 },
			{ at = { 3, 3 }, type = "sub" } },
	}
	command = { type = "tap", at = { 4, 4 } }
elseif kind == "spawn" then
	local core = require("core.game")
	local f = assert(io.open("content/levels/level_0003.json", "rb"))
	level = f:read("*a")
	f:close()
	level_id = 3
	local lv = core.load_level(level)
	local g0 = core.new(lv, { seed = core.attempt_seed(3, 1, 0), attempt = 1, salt = 0 })
	for _, m in ipairs(g0:moves()) do
		local c = g0:clone()
		assert(c:input({ type = "swap", from = m.from, to = m.to }))
		local found = false
		for _ = 1, 400 do
			c:step()
			for _, e in ipairs(c:drain_events()) do
				if e.type == "special_new" then found = true end
			end
			if found then break end
		end
		if found then
			command = { type = "swap", from = m.from, to = m.to }
			break
		end
	end
elseif kind == "idle" then
	level_id = 1
elseif kind == "play" then
	level_id = tonumber(name) or 1
	autoplay = true
else
	error("unknown scenario " .. tostring(scenario))
end

app.params = { level = level_id, level_text = level }
local script = stub.load_script("screens/level/board.script")
local self = {}
script.init(self)
self.strict = true
local sub = bus.subscribe("*", "snapshot")
local function frame()
	E.advance(1 / 60)
	script.update(self, 1 / 60)
	sub:drain(function() end)
end
for _ = 1, 3 do frame() end
if command then
	local ok, res = self.session:command(command)
	assert(ok, tostring(res))
end
if autoplay then self.session:autoplay(nil, { free_moves = true }) end
local shots = {}
local n, fi = 0, 1
while fi <= #frames do
	frame()
	n = n + 1
	if n == frames[fi] then
		local snap = E.snapshot()
		snap.frame, snap.tick = n, self.session.tick
		shots[#shots + 1] = snap
		fi = fi + 1
	end
end
local g = self.geom
local cells = {}
for i, c in ipairs(self.cells) do cells[i] = { exists = c.exists, floor = c.floor, wires = c.wires } end
local f = assert(io.open(outpath, "w"))
f:write(json.encode({ scenario = scenario, geom = { W = g.W, H = g.H, cell = g.cell, x0 = g.x0, y1 = g.y1 }, cells = cells,
	shots = shots }))
f:close()
stub.restore()
print("ok", #shots .. " frames of " .. scenario)
