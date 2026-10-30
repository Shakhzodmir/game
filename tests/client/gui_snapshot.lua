-- A picture of the meta screens without Defold: runs the real GUI scripts (town, splash, overlay)
-- on the strict stub (tests/client/town_defold_stub.lua) and writes the nodes of a scenario to a
-- JSON file; tests/client/gui_snapshot.py draws it.
--
--   lua5.1 tests/client/gui_snapshot.lua <scenario> <out.json> [language = en] [WxH = 720x1280] [seconds = 1.5]
--   python3 tests/client/gui_snapshot.py <out.json> <out.png> [scale = 0.75]
--
-- Run from the repository root. Scenarios:
--   town            a fresh save: the first task, "Level 1", the navigation
--   town_ready      one star in the purse: the task card pulses
--   town_streak     level 14 with a hit streak (notes lit, Hard / Super Hard tag when the level has it)
--   town_concert    the same district in its concert look
--   town_jazz       the first district is complete: jazz bar with its tasks
--   start           the start window of the next level
--   start_streak    level 14, a streak of two (free boosters), stock in the purse
--   lives_full / lives_empty / lives_infinite
--   shop_boosters / shop_coins / shop_coins_debug (a debug build: test purchases and the video gift)
--   settings / confirm (the reset question)
--   jukebox         one finished district, one in progress
--   chest_level / chest_level_open / chest_district / gift / gift_open
--   concert         the district concert
--   splash
--   toast / modal   the overlay over the town
-- What is drawn is what the scripts hand to the engine: positions, scales, tints, texts. The
-- fonts, the nine-slice art and the procedural textures are approximated by the renderer.

package.path = "./?.lua;./?/init.lua;" .. package.path
local town = require("tests.client.town_defold_stub")
local json = require("tools.lib.json")

local scenario, outpath = arg[1], arg[2]
if not (scenario and outpath) then
	print("usage: lua5.1 tests/client/gui_snapshot.lua <scenario> <out.json> [language] [WxH] [seconds]")
	os.exit(1)
end
local language = arg[3] or "en"
local w, h = string.match(arg[4] or "720x1280", "^(%d+)x(%d+)$")
w, h = tonumber(w) or 720, tonumber(h) or 1280
local seconds = tonumber(arg[5]) or 1.5

local E = town.boot({ window = { w, h }, language = language, stores = scenario == "shop_coins_debug" })
local app = require("client.app")
local flow = require("client.flow")
local rewards = require("client.rewards")
local H = require("tests.meta.helper")

local overlay = E.script("main/overlay.gui_script", "/main/overlay.gui", { url = "main:/overlay#overlay" })
overlay:init()
-- the screen manager's first fade-in: the overlay starts opaque
overlay:message("fade_in", { duration = 0.25 }, msg.url("main:/app"))

local function win(n)
	for _ = 1, n do assert(flow.debug_win(3)) end
end

local function open_town()
	local t = E.script("screens/town/town.gui_script", "/screens/town/town.gui")
	t:init()
	E.step(30)
	return t
end

local function popup(t, name, params)
	app.open_popup(name, params)
	E.step(20)
end

local scene_paths = { "/screens/town/town.gui", "/main/overlay.gui" }
local main = open_town()

local function done_tasks_of_cafe()
	-- the first district complete: stars through the meta, tasks through the meta (no animations)
	local d = app.meta:district("cafe")
	app.meta:_change("debug_qa", { { "stars", 40 } })
	for _, t in ipairs(d.tasks) do assert(app.meta:complete_task("cafe", t.id)) end
	app.commit("snapshot")
end

local S = {}
function S.town() end
function S.town_ready()
	win(1)
	rewards.clear()
end
function S.town_streak()
	win(13)
	win(2)
	app.commit("snapshot")
end
function S.town_concert()
	require("client.bus").publish("meta_qa", { action = "view", view = "concert" }) -- as the QA command does
end
function S.town_jazz()
	done_tasks_of_cafe()
end
function S.town_browse()
	done_tasks_of_cafe()
	E.step(10)
	E.tap(68, 1108 + 0) -- the left arrow of the ribbon (design-area coordinates, no safe area)
	E.step(60)
end
function S.start() popup(main, "start") end
function S.start_streak()
	win(13)
	win(2)
	app.meta:grant({ boosters = { riff = 2, sub = 1 } }, "snapshot", app.now())
	app.commit("snapshot")
	popup(main, "start")
end
function S.lives_full() popup(main, "lives") end
function S.lives_empty()
	win(20)
	E.clock = E.clock + 3 * 3600 -- the unlimited lives of the chests are over
	for _ = 1, 5 do flow.debug_lose() end
	app.commit("snapshot")
	popup(main, "lives")
end
function S.lives_infinite()
	app.meta:grant({ infinite_minutes = 30 }, "snapshot", app.now())
	app.commit("snapshot")
	popup(main, "lives")
end
function S.shop_boosters()
	win(25)
	popup(main, "shop", { tab = "boosters" })
end
function S.shop_coins() popup(main, "shop", { tab = "coins" }) end
function S.shop_coins_debug() popup(main, "shop", { tab = "coins" }) end -- a debug build: test purchases, the video gift
function S.settings() popup(main, "settings") end
function S.confirm()
	popup(main, "confirm", {
		title = { key = "settings.reset_title" }, text = { key = "settings.reset_text" },
		confirm = { text = { key = "settings.reset_do" }, style = "pink" },
	})
end
function S.jukebox()
	done_tasks_of_cafe()
	popup(main, "jukebox")
end
function S.chest_level() popup(main, "chest", { kind = "level", level_id = 10, chest = { coins = 60, boosters = { "stick" }, infinite_minutes = 15 } }) end
function S.chest_level_open()
	popup(main, "chest", { kind = "level", level_id = 10, chest = { coins = 60, boosters = { "stick", "riff" }, infinite_minutes = 15 } })
	E.tap(360, 730)
	E.step(60)
end
function S.chest_district()
	popup(main, "chest", { kind = "district", district_name = app.district("cafe").name, chest = { coins = 300, boosters = { "riff", "stick" } } })
end
function S.gift() popup(main, "gift", { id = "riff" }) end
function S.gift_open()
	popup(main, "gift", { id = "riff" })
	E.tap(360, 730)
	E.step(60)
end
function S.concert()
	popup(main, "concert", { district = "cafe" })
	E.step(120)
end
function S.toast()
	app.toast_key("toast.coming_soon", nil, { color = "blue" })
end
function S.modal()
	app.modal({ id = "qa", title = { key = "settings.title" }, text = { key = "lives.full" },
		buttons = { { id = "ok", text = { key = "common.ok" } } } })
end
function S.splash()
	main:final()
	local sp = E.script("screens/splash/splash.gui_script", "/screens/splash/splash.gui")
	sp:init()
	scene_paths = { "/screens/splash/splash.gui", "/main/overlay.gui" }
end

local fn = S[scenario]
if not fn then
	print("unknown scenario " .. scenario)
	os.exit(1)
end
fn()
E.run(seconds)

local out = { scenario = scenario, language = language, window = { w = w, h = h }, scenes = {}, problems = E.audit() }
for _, path in ipairs(scene_paths) do out.scenes[#out.scenes + 1] = E.dump_scene(path) end
local f = assert(io.open(outpath, "w"))
f:write(json.encode(out))
f:close()
for _, p in ipairs(out.problems) do print("AUDIT " .. p) end
town.shutdown()
