-- The town line of the results window and the first win that points at the town (client/level_windows.lua town_line and
-- swap_buttons, gui/result.lua). After a win the window says how many stars the next task of the town still needs ("2 more
-- stars to "Cafe sign""), or, in green, that it can be bought now; nothing in a practice run or when the town is complete.
-- And while the player has never done a task of the town and can do one now, "To town" is the big green button and "Next
-- level" the small white one (lw.FIRST_WIN_TO_TOWN switches that off; the producer has not decided it yet).

local G = require("tests.client.level_gui_helper")
local T = require("tests.client.meta_gui_helper")
local A = require("tests.client.layout_audit")
local MH = require("tests.meta.helper")
local lw = require("client.level_windows")
local level_end = require("client.level_end")
local views = require("client.views")
local i18n = require("client.i18n")

-- sets a field of a module for the length of fn and puts it back, whatever fn does
local function with(tbl, key, value, fn)
	local old = tbl[key]
	tbl[key] = value
	local ok, err = pcall(fn)
	tbl[key] = old
	if not ok then error(err, 0) end
end

-- is the node a pulsing one? (client/ui.lua needs the engine's globals: it is loaded once a test has booted the stub)
local function pulsing(node) return require("client.ui").is_pulsing(node) end

-- the pure rule, on a real meta ---------------------------------------------------------------------------------

-- the first `count` tasks of the cafe done (the stars are given to pay them: test setup)
local function done(m, count)
	for i, t in ipairs(m:district("cafe").tasks) do
		if i > count then return end
		MH.give(m, "stars", t.cost)
		assert(m:complete_task("cafe", t.id))
	end
end

describe("client.level_windows town line", function()
	before_each(function() i18n.set_language("en") end)

	it("says the first task can be bought as soon as one star is in the purse, and that it is the player's first", function()
		local m = MH.new()
		MH.give(m, "stars", 1)
		local t = lw.town_line(m, false)
		assert_eq(t.kind, "ready")
		assert_eq(t.need, 0)
		assert_eq(t.cost, 1)
		assert_true(t.first)
		assert_eq(t.district, "cafe")
		assert_eq(t.task, "turntable")
		-- the name is the table the task card of the town draws (views.task), not a text: it follows the language
		assert_same(t.name, views.task(m).name)
		assert_eq(i18n.name(t.name), "Turntable")
		i18n.set_language("ru")
		assert_eq(i18n.name(t.name), "Проигрыватель")
	end)

	it("counts the stars still missing when the purse does not reach the price", function()
		local m = MH.new()
		local t = lw.town_line(m, false)
		assert_eq(t.kind, "need")
		assert_eq(t.need, 1)
		assert_true(t.first)
		done(m, 2) -- the turntable and the lamps: the piano costs 2
		t = lw.town_line(m, false)
		assert_eq(t.kind, "need")
		assert_eq(t.need, 2)
		assert_eq(t.task, "piano")
		assert_false(t.first, "a task of the town is done")
		MH.give(m, "stars", 1)
		t = lw.town_line(m, false)
		assert_eq(t.kind, "need")
		assert_eq(t.need, 1)
		MH.give(m, "stars", 1)
		t = lw.town_line(m, false)
		assert_eq(t.kind, "ready")
		assert_eq(t.need, 0)
		assert_false(t.first)
	end)

	it("follows the task being built into the next district, with the stars of the wallet", function()
		local m = MH.new()
		for _, t in ipairs(m:district("cafe").tasks) do
			MH.give(m, "stars", t.cost)
			assert(m:complete_task("cafe", t.id))
		end
		local t = lw.town_line(m, false)
		assert_eq(t.district, "jazz")
		assert_eq(t.task, "stage_light")
		assert_eq(t.kind, "need")
		assert_false(t.first)
	end)

	it("has no line for a practice run or a replay (nothing is paid) and none when the town is complete", function()
		local m = MH.new()
		MH.give(m, "stars", 1)
		assert_true(lw.town_line(m, false) ~= nil)
		assert_eq(lw.town_line(m, true), nil)
		assert_eq(lw.town_line(nil, false), nil)
		for _, d in ipairs(m:districts()) do
			for _, t in ipairs(m:district(d.id).tasks) do
				if not t.done then
					MH.give(m, "stars", t.cost)
					assert(m:complete_task(d.id, t.id))
				end
			end
		end
		assert_eq(m:next_task(), nil, "the whole town is built")
		assert_eq(lw.town_line(m, false), nil)
	end)

	it("is part of the results view, from the meta as it stands after the win", function()
		local m = MH.new()
		MH.give(m, "stars", 2)
		local v = lw.result(m, { level_id = 1, stars = 1, next_level = 2 }, { score = 100, moves_at_win = 3 }, MH.T0)
		assert_eq(v.town.kind, "ready")
		assert_same(v.town, lw.town_line(m, false))
		local practice = lw.result(m, { level_id = 1, stars = 1, next_level = 2, standalone = true }, { score = 100 }, MH.T0)
		assert_eq(practice.town, nil)
	end)

	it("swaps the emphasis of the buttons only for a first purchase that can be made, on a win with a next level, not from the map", function()
		local ready_first = { kind = "ready", first = true }
		assert_true(lw.swap_buttons(ready_first, true, nil))
		assert_false(lw.swap_buttons({ kind = "ready", first = false }, true, nil), "a task was done: the usual buttons")
		assert_false(lw.swap_buttons({ kind = "need", first = true }, true, nil), "nothing to buy yet: the usual buttons")
		assert_false(lw.swap_buttons(nil, true, nil), "no line, no swap")
		assert_false(lw.swap_buttons(ready_first, false, nil), "the last level has the one button, To town, already")
		assert_false(lw.swap_buttons(ready_first, true, "map"), "from the map the second button leads to the map, not to the town")
		-- the one constant that switches it off
		with(lw, "FIRST_WIN_TO_TOWN", false, function()
			assert_false(lw.swap_buttons(ready_first, true, nil))
		end)
		assert_true(lw.FIRST_WIN_TO_TOWN, "the producer's variant is on for the preview")
	end)
end)

-- the window --------------------------------------------------------------------------------------------------

-- wins the level on the board by the QA autoplay; waits for the results window and the time it needs to settle
local function win(c, quick)
	c.fb.session:autoplay(nil, { free_moves = true })
	for _ = 1, 60 * 120 do
		c.step(1)
		if c.popup() == "result" then break end
	end
	c.step(quick and 2 or 120)
end

-- every win rated with one star: the wallet after it is the wallet before + 1
local function one_star(fn) with(level_end, "qa_stars", 1, fn) end

-- the first `count` tasks of the cafe done before the level (the purse is empty then)
local function bought(count) return function(app) T.build_tasks(app, "cafe", count) end end

local function complete_town(app)
	for _, d in ipairs(app.meta:districts()) do T.build_tasks(app, d.id) end
end

-- logical rect (y up) of a node under the stub's current window
local function lrect(c, n)
	local x0, y0, x1, y1 = c.E.rect(n)
	local ax, ay = c.E.to_logical(x0, y0)
	local bx, by = c.E.to_logical(x1, y1)
	return math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by)
end

local function height_of(c, n)
	local _, y0, _, y1 = lrect(c, n)
	return y1 - y0
end

local function clean(c)
	assert_eq(c.app.ui.level.errors, 0, "errors in the HUD code")
	local problems = c.E.audit()
	assert_eq(#problems, 0, table.concat(problems, "\n"))
end

-- the two buttons as drawn: {face node, height} of "To town" (or the map) and of "Next level"
local function buttons(c, town_label)
	local town = c.hud:find(town_label or "To town")
	local nxt = c.hud:find("Next level")
	assert_true(town ~= nil and nxt ~= nil, "both buttons are drawn")
	return { town = town.parent, town_h = height_of(c, town.parent), next = nxt.parent, next_h = height_of(c, nxt.parent) }
end

describe("results window: the first win points at the town", function()
	it("shows the first task in green and makes To town the big pulsing button, Next level the small one", function()
		one_star(function()
			G.with_level({ level = 1 }, function(c)
				win(c)
				assert_eq(c.popup(), "result")
				local r = c.app.ui.result
				assert_false(r.standalone, "a real attempt")
				assert_eq(r.town.kind, "ready")
				assert_true(r.town.first)
				assert_true(r.swap)
				local line = c.hud:find("You can buy “Turntable”")
				assert_true(line ~= nil, "the green line names the item of the task card")
				-- green: a dark green ink on a mint plate, readable (4.5:1), the plate is green and not lilac
				local pr, pg, pb = A.plate(c.E, line)
				assert_true(pg > pr and pg > pb, "a green plate")
				local col = line.color
				assert_true(col.y > col.x and col.y > col.z, "a green ink")
				assert_true(A.contrast(col.x, col.y, col.z, pr, pg, pb) >= 4.5, "the line reads on its plate")
				-- the big button is To town (green face, 124 px), Next level the small white one (92 px)
				local b = buttons(c)
				assert_eq(b.town.anim, "ui_button_green")
				assert_eq(b.next.anim, "ui_button_white")
				assert_true(b.town_h > b.next_h + 20, "To town is the bigger button: " .. b.town_h .. " vs " .. b.next_h)
				local t = c.app.ui.popup_targets
				assert_true(t.town.y > t.next.y, "To town stands where Next level used to")
				assert_true(pulsing(b.town), "the big button asks for the tap")
				assert_false(pulsing(b.next))
				-- the line is the last block, right over the buttons, under the chest progress
				local _, ly = c.E.centre(line)
				local _, cy = c.E.centre(c.hud:find("Chest in 9 levels"))
				assert_true(ly < cy and ly > t.town.y + 70, "the line sits between the strips and the big button (" .. ly .. ")")
				clean(c)
			end)
		end)
	end)

	it("keeps the label of the small Next level button readable in every language", function()
		one_star(function()
			for _, lang in ipairs({ "en", "ru", "ko" }) do
				G.with_level({ level = 1, language = lang }, function(c)
					win(c)
					assert_true(c.app.ui.result.swap)
					i18n.set_language(lang)
					local small, big = c.hud:find(i18n.t("win.next")), c.hud:find(i18n.t("win.town"))
					assert_true(small ~= nil and big ~= nil, lang)
					assert_true(c.E.text_px(small) >= 24, lang .. ": Next level is " .. c.E.text_px(small) .. " px")
					assert_true(c.E.text_px(big) > c.E.text_px(small) + 6, lang .. ": the big label is the bigger one")
					clean(c)
				end)
			end
		end)
	end)

	it("keeps both buttons where QA and the tests tap them: To town goes to the town, Next level opens the start window", function()
		one_star(function()
			G.with_level({ level = 1 }, function(c)
				win(c)
				assert_true(c.app.ui.result.swap)
				c.tap_target("next")
				c.step(30)
				assert_eq(c.popup(), "start", "the small Next level answers")
				assert_true(c.has("Level 2"))
				c.app.close_popup()
				c.step(40)
				assert_eq(c.popup(), "result")
				c.tap_target("town")
				c.run(1.0)
				local posts = c.E.posted("show_screen", "main:/app")
				assert_eq(#posts, 1)
				assert_eq(posts[1].message.name, "town", "the big To town goes to the town")
				clean(c)
			end)
		end)
	end)

	it("does not let the second tap of a double tap on Collect fall through to To town", function()
		-- the chest window's Collect lies over the big button of this tall results window; here that is To town
		G.with_level({ level = 20, setup = function(app)
			while app.meta:level_to_play() < 20 do assert(require("client.flow").debug_win(3, true)) end
		end }, function(c)
			win(c)
			local meta = c.app.meta
			assert_true(c.app.ui.result.swap, "nothing was bought: the first win points at the town")
			local town_at = c.app.ui.popup_targets.town
			c.tap_target("chest")
			c.step(30)
			c.tap_target("chest")
			c.step(120)
			local collect = c.app.ui.popup_targets.collect
			assert_true(math.abs(collect.x - town_at.x) < 230 and math.abs(collect.y - town_at.y) < 88,
				"Collect lies over To town in this window (" .. collect.x .. "," .. collect.y .. " vs " .. town_at.x .. "," .. town_at.y .. ")")
			local coins = meta:coins()
			c.tap(collect.x, collect.y) -- Collect
			c.tap(collect.x, collect.y) -- the second tap of the double tap, a few frames later
			c.step(30)
			assert_eq(c.popup(), "result", "the second tap did not press To town")
			assert_eq(meta:coins(), coins + 60, "the chest was paid once")
			c.step(20)
			assert_true(c.E.posted("show_screen", "main:/app")[1] == nil, "nothing left the screen")
			c.tap_target("next")
			c.step(30)
			assert_eq(c.popup(), "start", "the window listens again after the moment")
			clean(c)
		end)
	end)

	it("is calm under reduced motion: nothing pulses, and the line is there the moment the window opens", function()
		one_star(function()
			G.with_level({ level = 1, setup = function(app) assert(app.set_setting("reduced_motion", true)) end }, function(c)
				-- the moment the window is open (not the settled one): the line is there at once, in every mode
				win(c, true)
				local line = c.hud:find("You can buy “Turntable”")
				assert_true(line ~= nil)
				assert_true(c.E.text_px(line) >= 18, "the line is there at once: " .. c.E.text_px(line) .. " px")
				local b = buttons(c)
				assert_false(pulsing(b.town), "no pulse of the big button")
				assert_false(pulsing(b.next))
				assert_true(c.app.ui.result.swap, "the emphasis still moves: that is a state, not a motion")
			end)
		end)
	end)

	it("has the usual buttons when the switch is off, and the line all the same", function()
		one_star(function()
			with(lw, "FIRST_WIN_TO_TOWN", false, function()
				G.with_level({ level = 1 }, function(c)
					win(c)
					assert_false(c.app.ui.result.swap)
					assert_true(c.has("You can buy “Turntable”"))
					local b = buttons(c)
					assert_eq(b.next.anim, "ui_button_green")
					assert_eq(b.town.anim, "ui_button_white")
					assert_true(b.next_h > b.town_h + 20)
					local t = c.app.ui.popup_targets
					assert_true(t.next.y > t.town.y)
					assert_true(pulsing(b.next))
				end)
			end)
		end)
	end)
end)

describe("results window: the town line after a purchase", function()
	it("says in green that the next task can be bought, with the usual buttons (Next level big)", function()
		one_star(function()
			G.with_level({ level = 1, setup = bought(1) }, function(c)
				win(c)
				local r = c.app.ui.result
				assert_eq(r.town.kind, "ready")
				assert_false(r.town.first)
				assert_false(r.swap)
				assert_true(c.has("You can buy “Warm lamps”"), "the second task of the cafe")
				local b = buttons(c)
				assert_eq(b.next.anim, "ui_button_green")
				assert_eq(b.town.anim, "ui_button_white")
				assert_true(b.next_h > b.town_h + 20)
				local t = c.app.ui.popup_targets
				assert_true(t.next.y > t.town.y, "Next level is above To town, as it always was")
				assert_true(pulsing(b.next))
				clean(c)
			end)
		end)
	end)

	it("counts the missing stars in the plural form of the language when the purse is not enough", function()
		one_star(function()
			-- two tasks done (turntable, lamps), the win brings the one star the piano (2) misses one of
			G.with_level({ level = 1, setup = bought(2) }, function(c)
				win(c)
				local r = c.app.ui.result
				assert_eq(r.town.kind, "need")
				assert_eq(r.town.need, 1)
				assert_false(r.swap)
				assert_true(c.has("1 more star to “Upright piano”"), table.concat(c.texts(), " | "))
				assert_false(c.has("You can buy “Upright piano”"))
				local b = buttons(c)
				assert_eq(b.next.anim, "ui_button_green", "the usual buttons")
				clean(c)
			end)
			-- five tasks done, the sign (3) misses two stars; the Russian says "звезды", the Korean "별 2개"
			for _, case in ipairs({
				{ "en", "2 more stars to “Café sign”" },
				{ "ru", "Ещё 2 звезды до «Вывеска кафе»" },
				{ "ko", "“카페 간판”까지 별 2개 남았어요" },
			}) do
				G.with_level({ level = 1, language = case[1], setup = bought(5) }, function(c)
					win(c)
					assert_eq(c.app.ui.result.town.need, 2)
					assert_true(c.has(case[2]), case[1] .. ": " .. table.concat(c.texts(), " | "))
					clean(c)
				end)
			end
		end)
	end)

	it("shows the lilac line with a star for what is missing, readable in every language", function()
		one_star(function()
			for _, lang in ipairs({ "en", "ru", "ko" }) do
				G.with_level({ level = 1, language = lang, setup = bought(2) }, function(c)
					win(c)
					i18n.set_language(lang)
					local text = i18n.t("win.town_need", { n = 1, item = i18n.name(c.app.meta:next_task().name) })
					local line = c.hud:find(text)
					assert_true(line ~= nil, lang .. ": " .. text)
					assert_true(c.E.text_px(line) >= 18, lang .. ": " .. c.E.text_px(line) .. " px")
					local pr, pg, pb = A.plate(c.E, line)
					assert_true(pr > 0.9 and pb > pr, lang .. ": the lilac plate of the other strips")
				end)
			end
		end)
	end)

	it("follows a change of language while the window is open, and speaks the card's own word", function()
		one_star(function()
			G.with_level({ level = 1 }, function(c)
				win(c)
				assert_true(c.has("You can buy “Turntable”"))
				assert_true(c.app.set_setting("language", "ru"))
				c.step(10)
				assert_true(c.has("Можно купить «Проигрыватель»"), table.concat(c.texts(), " | "))
				assert_true(c.app.set_setting("language", "ko"))
				c.step(10)
				assert_true(c.has("“턴테이블” 살 수 있어요"), table.concat(c.texts(), " | "))
				assert_true(c.app.set_setting("language", "en"))
				c.step(10)
				assert_true(c.has("You can buy “Turntable”"))
			end)
		end)
	end)
end)

describe("results window: where the line stays away", function()
	it("has no line and the usual buttons when the whole town is built", function()
		G.with_level({ level = 1, setup = complete_town }, function(c)
			win(c)
			assert_eq(c.popup(), "result")
			local r = c.app.ui.result
			assert_eq(r.town, nil)
			assert_false(r.swap)
			for _, t in ipairs(c.texts()) do
				assert_true(not string.find(t, "^%d+ more stars? to ") and not string.find(t, "^You can buy "), "no line: " .. t)
			end
			local b = buttons(c)
			assert_eq(b.next.anim, "ui_button_green")
			clean(c)
		end)
	end)

	it("has no line in a practice run: nothing is paid there", function()
		G.with_level({ level = 5, attempt = false }, function(c)
			win(c)
			assert_eq(c.popup(), "result")
			assert_true(c.has("Practice: nothing is paid"))
			local r = c.app.ui.result
			assert_true(r.standalone)
			assert_eq(r.town, nil)
			assert_false(r.swap)
			for _, t in ipairs(c.texts()) do
				assert_true(not string.find(t, "^%d+ more stars? to ") and not string.find(t, "^You can buy "), "no line: " .. t)
			end
			local b = buttons(c)
			assert_eq(b.next.anim, "ui_button_green")
			clean(c)
		end)
	end)

	it("keeps the line but not the swap for a win of a level started from the map: that button goes to the map", function()
		one_star(function()
			G.with_level({ level = 1, from = "map", back = "map" }, function(c)
				win(c)
				assert_eq(c.popup(), "result")
				local r = c.app.ui.result
				assert_eq(r.town.kind, "ready")
				assert_true(r.town.first)
				assert_false(r.swap, "To the map is not the way to the first purchase")
				assert_true(c.has("You can buy “Turntable”"))
				local b = buttons(c, "To the map")
				assert_eq(b.next.anim, "ui_button_green")
				assert_eq(b.town.anim, "ui_button_white")
				assert_true(b.next_h > b.town_h + 20)
				c.tap_target("town")
				c.run(1.0)
				assert_eq(c.E.posted("show_screen", "main:/app")[1].message.name, "map")
				clean(c)
			end)
		end)
	end)

	-- the last level of the game: the one button, To town, is green and big already; the line is over it
	it("has the single green To town button on the last level, with the line over it", function()
		G.with_level({ level = 1 }, function(c)
			T.give_stars(c.app, 1)
			local view = lw.result(c.app.meta, { level_id = 300, stars = 1, next_level = nil }, { score = 100, moves_at_win = 3, stars = 1 }, c.app.now())
			assert_eq(view.town.kind, "ready")
			c.hud:ctx(function() c.hud.self.l:open("result", { view = view, level_id = 300 }) end)
			c.run(0.6)
			assert_eq(c.popup(), "result")
			assert_false(c.app.ui.result.swap, "there is no next level to demote")
			assert_true(c.has("You can buy “Turntable”"))
			assert_true(c.has("To town"))
			assert_false(c.has("Next level"))
			assert_true(c.has("More levels coming soon!"))
			local t = c.app.ui.popup_targets
			assert_true(t.town ~= nil and t.next == nil)
			local label = c.hud:find("To town")
			assert_eq(label.parent.anim, "ui_button_green")
			local line = c.hud:find("You can buy “Turntable”")
			local _, ly = c.E.centre(line)
			assert_true(ly > t.town.y + 80, "the line is over the button and its caption")
			clean(c)
		end)
	end)
end)
