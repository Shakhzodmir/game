-- screens/level/level_fx.gui_script on the engine-like GUI stub (tests/client/town_defold_stub.lua): a node has
-- ONE running animation per property (a second gui.animate replaces the first at once) and a node made by
-- script takes no alpha from its parent. The praise words, the combo titles and the banners must really be
-- seen, in both motion modes: what the player sees is sampled frame by frame.

local town = require("tests.client.town_defold_stub")
local clash = require("tests.client.gui_clash")
local bus = require("client.bus")

local PATH, GUI = "screens/level/level_fx.gui_script", "/screens/level/level_fx.gui"

-- Runs fn(E, t, find, watch) with the script initialised; find(text) is the live node showing the text.
local function with_fx(opts, fn)
	local E = town.boot({ language = "en" })
	local ok, err = pcall(function()
		local app = require("client.app")
		app.set_setting("reduced_motion", opts.reduced and true or false)
		local watch = clash.watch(E)
		local t = E.script(PATH, GUI)
		t:init()
		local function find(text)
			for _, n in ipairs(E.alive_nodes(E.scene(GUI))) do
				if n.text == text then return n end
			end
			return nil
		end
		local ok2, err2 = pcall(fn, E, t, find, watch)
		pcall(function() t:final() end)
		watch.stop()
		if not ok2 then error(err2, 0) end
	end)
	town.shutdown()
	if not ok then error(err, 0) end
end

-- the largest alpha the engine draws the node with over `frames` frames, and the alpha at frame `at`
local function watch_alpha(E, t, node, frames, at)
	local top, mid = 0, nil
	for i = 1, frames do
		t:step(1)
		if not node.dead then
			local a = E.opacity(node)
			if a > top then top = a end
			if i == at then mid = a end
		end
	end
	return top, mid
end

describe("level_fx.gui_script under full motion", function()
	it("shows a praise word while it holds and clears it afterwards", function()
		with_fx({}, function(E, t, find)
			bus.publish("level_praise", { word = "hit", index = 2, wave = 5 })
			t:step(2)
			local n = assert(find("Hit!"))
			local top, mid = watch_alpha(E, t, n, 40, 30)
			assert_true(top > 0.99 and mid > 0.99, "the word is solid while it holds: " .. tostring(mid))
			t:step(120)
			assert_true(n.dead, "the word is cleared")
		end)
	end)

	it("pops the shuffle banner in to its full size, holds it and takes it away", function()
		with_fx({}, function(E, t, find)
			bus.publish("level_banner", { key = "hud.shuffle" })
			t:step(2)
			local plate = assert(find("No moves — shuffling!")).parent
			t:step(30) -- 0.5 s: the pop-in (0.3 s) is over
			assert_near(plate.scale.x, 1, 0.001, "the banner reaches its full size")
			t:step(30) -- 1.0 s: it holds until 1.3 s
			assert_near(plate.scale.x, 1, 0.001, "and keeps it while it holds")
			t:step(60) -- 2.0 s: shrunk and cleared
			assert_true(plate.dead, "the banner is cleared")
		end)
	end)
end)

describe("level_fx.gui_script under reduced motion", function()
	it("fades a praise word in, holds it solid and fades it out", function()
		with_fx({ reduced = true }, function(E, t, find)
			bus.publish("level_praise", { word = "hit", index = 2, wave = 5 })
			t:step(2)
			local n = assert(find("Hit!"))
			local top, mid = watch_alpha(E, t, n, 40, 30) -- up to 0.7 s, sampled at 0.5 s
			assert_true(top > 0.99, "the word is seen: top alpha " .. top)
			assert_true(mid > 0.99, "and solid while it holds: " .. tostring(mid))
			t:step(120)
			assert_true(n.dead, "the word is cleared")
		end)
	end)

	it("shows the combo title and the Final concert title the same way", function()
		with_fx({ reduced = true }, function(E, t, find)
			bus.publish("level_special", { special = "sub", combo = "bass_drop", lx = 360, ly = 640 })
			t:step(2)
			local n = assert(find("Bass drop!"))
			local top = watch_alpha(E, t, n, 30)
			assert_true(top > 0.99, "the combo title is seen: " .. top)
			t:step(120)
			assert_true(n.dead)
			bus.publish("level_state", { state = "concert" })
			t:step(2)
			local c = assert(find("Final concert!"))
			local top2, mid2 = watch_alpha(E, t, c, 60, 50)
			assert_true(top2 > 0.99 and mid2 > 0.99, "the concert title is seen: " .. top2)
		end)
	end)

	it("fades the text of the banner with its plate", function()
		with_fx({ reduced = true }, function(E, t, find)
			bus.publish("level_banner", { key = "hud.shuffle" })
			t:step(2)
			local label = assert(find("No moves — shuffling!"))
			local plate = label.parent
			local gone_at
			for i = 1, 150 do
				t:step(1)
				if plate.dead then
					gone_at = i
					break
				end
				-- what the engine draws for the text never exceeds what it draws for the plate
				assert_true(E.opacity(label) <= E.opacity(plate) + 1e-6,
					"frame " .. i .. ": the text (" .. E.opacity(label) .. ") is more solid than its plate (" .. E.opacity(plate) .. ")")
			end
			assert_true(gone_at ~= nil, "the banner is cleared")
		end)
	end)
end)

describe("level_fx.gui_script animations", function()
	it("never start two animations of one node property in one frame, in either motion mode", function()
		for _, reduced in ipairs({ false, true }) do
			with_fx({ reduced = reduced }, function(E, t, find, watch)
				for i = 1, 5 do
					bus.publish("level_praise", { word = "x", index = i, wave = i + 3 })
					t:step(30)
				end
				for _, name in ipairs(require("client.level_effects").COMBOS) do
					bus.publish("level_special", { special = "sub", combo = name, lx = 360, ly = 640 })
					t:step(20)
				end
				bus.publish("level_banner", { key = "hud.shuffle" })
				bus.publish("level_flash", { color = "#FFFFFF", alpha = 0.9, dur = 0.5 })
				t:step(30)
				bus.publish("level_state", { state = "won_wait" })
				t:step(20)
				bus.publish("level_state", { state = "concert" })
				t:step(240)
				bus.publish("level_state", { state = "complete" })
				t:step(240)
				assert_same(watch.list(), {}, reduced and "reduced motion" or "full motion")
			end)
		end
	end)
end)
