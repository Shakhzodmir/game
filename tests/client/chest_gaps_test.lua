-- Regression tests for the mutants of the level-chest rework that the first test round did not kill (found by the
-- verifier of tests/client/level_screen_test.lua's chest tests): an older chest opened by the strip button, the burst of a
-- star under a results window that slid to fit the screen, the Russian stars note, the invisible and large strip buttons.
local G = require("tests.client.level_gui_helper")
local flow = require("client.flow")
local i18n = require("client.i18n")

local function win(c)
	c.fb.session:autoplay(nil, { free_moves = true })
	for _ = 1, 60 * 120 do
		c.step(1)
		if c.popup() == "result" then break end
	end
	c.step(120)
end
local function win_until(n, keep)
	return function(app)
		while app.meta:level_to_play() < n do assert(flow.debug_win(3, keep)) end
	end
end

describe("level chest: the cases the first test round left open", function()
	it("A2c/A3: the title of an OLDER chest opens it, the chest window names its level, and Collect pays that very chest", function()
		G.with_level({ level = 11, setup = win_until(11, true) }, function(c)
			local meta = c.app.meta
			win(c)
			assert_eq(#meta:pending_chests(), 1, "the chest of level 10 waits")
			local title = c.hud:find(i18n.t("reward.chest_level", { n = 10 }))
			assert_true(title ~= nil, "the strip names the older chest")
			local x, y = c.E.centre(title)
			c.tap(x, y) -- the title, not the Open button
			c.step(30)
			assert_eq(c.popup(), "chest", "the title opens the chest window")
			assert_false(c.has(i18n.t("reward.chest_level", { n = 11 })), "the chest window names the level of the results")
			c.tap_target("chest")
			c.step(120)
			local coins = meta:coins()
			c.tap_target("collect")
			c.step(60)
			assert_eq(#meta:pending_chests(), 0, "the chest of level 10 was taken")
			assert_eq(meta:coins(), coins + 60)
		end)
	end)

	it("K18: the burst of a star flies out of the star, also when the window slid down to fit the screen", function()
		G.with_level({ level = 13, setup = win_until(13, true) }, function(c) -- 1116 px: the window slides 38 px down
			local Fx = getmetatable(c.hud.self.l.popups.fx).__index
			local rings, real = {}, Fx.ring
			Fx.ring = function(self, x, y, o)
				if o and o.size == 90 and o.scale == 2.4 then rings[#rings + 1] = { x = x, y = y } end -- the ring of a star burst
				return real(self, x, y, o)
			end
			local ok, err = pcall(win, c)
			Fx.ring = real
			assert(ok, err)
			local e = c.hud.self.l.popups:find("result")
			assert_true(e.fit_dy < 0, "the case needs a window that slid: " .. tostring(e.fit_dy))
			assert_true(#rings >= 1, "the star burst happened")
			local star, w = nil, 0
			for _, node in ipairs(c.E.alive_nodes(c.E.scene("/screens/level/level.gui"))) do
				if node.anim == "ui_icons_star" and c.E.visible(node) and node.size.x * node.scale.x > w then
					star, w = node, node.size.x * node.scale.x
				end
			end
			assert_true(star ~= nil, "the star of the results")
			local sx, sy = c.E.centre(star)
			assert_near(rings[1].x, sx, 6, "the ring is on the star (x)")
			assert_near(rings[1].y, sy, 6, "the ring is on the star (y), the window slid " .. tostring(e.fit_dy))
		end)
	end)

	it("X12: the Russian stars note names the top difficulty like the tag of the level button", function()
		local tag = i18n.t("hud.super_hard", nil, "ru")  -- "Суперсложный" (a capital in the tag, lower case in a sentence)
		local note = i18n.t("win.stars_note", nil, "ru")
		assert_true(note:find(tag:sub(3), 1, true) ~= nil, "the note says something else than '" .. tag .. "': " .. note)
	end)

	it("N9: the whole-strip button is invisible", function()
		G.with_level({ level = 10 }, function(c)
			win(c)
			local found = 0
			for _, node in ipairs(c.E.alive_nodes(c.E.scene("/screens/level/level.gui"))) do
				if node.texture == "px_btn_white" and node.size.x == 560 and node.size.y == 212 then
					found = found + 1
					assert_true(node.color.w == 0, "the strip button draws itself: alpha " .. tostring(node.color.w))
				end
			end
			assert_eq(found, 1, "the strip button exists")
		end)
	end)

	it("N10: a tap anywhere on the chest just taken, not only in its middle, brings the next one", function()
		G.with_level({ level = 20, setup = win_until(20, true) }, function(c)
			win(c)
			c.tap_target("chest"); c.step(30)
			c.tap_target("chest"); c.step(120)
			c.tap_target("collect"); c.step(30) -- 0.5 s: past the deaf moment (0.45 s), well inside the 1.2 s hold
			assert_true(c.has("Chest collected!"))
			local t = c.app.ui.popup_targets.taken
			c.tap(t.x - 200, t.y + 40) -- the left side of the strip
			c.step(5)
			assert_false(c.has("Chest collected!"), "a tap on the side of the strip brings the next chest")
			assert_true(c.has("Open"))
		end)
	end)
end)
