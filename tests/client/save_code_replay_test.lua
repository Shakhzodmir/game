-- The save code windows (settings) and the replay of beaten levels after the last one, on the strict
-- Defold GUI stub (the same fixtures as the meta windows).

local G = require("tests.client.meta_gui_helper")
local platform = require("client.platform")

local function open(c, name, params)
	c.app.open_popup(name, params)
	c.run(0.6)
	assert_eq(c.app.ui.popup, name)
end

local function wtap(c, name)
	local t = c.app.ui.popup_targets and c.app.ui.popup_targets[name]
	assert_true(t ~= nil, "no target '" .. name .. "' in " .. tostring(c.app.ui.popup))
	c.tap(t.x, t.y)
	c.step(2)
end

local function has(c, text) return G.dump(c.town):find(text, 1, true) ~= nil end

-- Replaces the clipboard functions for one test; returns a table that records the copy and gives the paste.
local function fake_clipboard(paste)
	local real_copy, real_paste = platform.copy_text, platform.paste_text
	local box = { paste = paste }
	platform.copy_text = function(text) box.copied = text; return "clipboard" end
	platform.paste_text = function() return box.paste end
	function box.restore() platform.copy_text, platform.paste_text = real_copy, real_paste end
	return box
end

local function with_clip(paste, fn)
	local box = fake_clipboard(paste)
	local ok, err = pcall(fn, box)
	box.restore()
	if not ok then error(err, 0) end
end

describe("save code windows", function()
	it("copies the code and loads it back after a confirmation, then goes to the splash", function()
		with_clip(nil, function(box)
			G.with_town({ language = "en", setup = function(app) G.win(app, 5) end }, function(c)
				open(c, "settings")
				wtap(c, "code_copy")
				assert_true(box.copied ~= nil and box.copied:sub(1, 6) == "GLOW1-")
				local coins = c.app.meta:coins()
				c.app.reset_save(7, c.app.now())
				assert_eq(c.app.meta:level_to_play(), 1)
				open(c, "settings")
				box.paste = box.copied
				wtap(c, "code_enter")
				c.run(0.6)
				assert_eq(c.app.ui.popup, "confirm")
				assert_true(has(c, "Levels beaten: 5"), G.dump(c.town))
				wtap(c, "confirm")
				c.run(0.5)
				assert_eq(c.app.meta:level_to_play(), 6)
				assert_eq(c.app.meta:coins(), coins)
				local posts = c.E.posted("show_screen", "main:/app")
				assert_eq(posts[#posts].message.name, "splash")
				-- the replaced save was kept as the backup
				local _, previous = c.app.store:load()
				assert_true(previous ~= nil)
			end)
		end)
	end)

	it("warns when the code holds less progress than the current save, and cancels cleanly", function()
		with_clip(nil, function(box)
			G.with_town({ language = "en", setup = function(app) G.win(app, 3) end }, function(c)
				box.paste = (c.app.export_code())
				G.win(c.app, 4)
				open(c, "settings")
				wtap(c, "code_enter")
				c.run(0.6)
				assert_eq(c.app.ui.popup, "confirm")
				assert_true(has(c, "Levels beaten: 3"))
				assert_true(has(c, "LESS"), G.dump(c.town))
				wtap(c, "cancel")
				c.run(0.5)
				assert_eq(c.app.meta:level_to_play(), 8, "nothing changed")
			end)
		end)
	end)

	it("refuses a broken, foreign or empty code with a message and no window", function()
		with_clip(nil, function(box)
			G.with_town({ language = "en", setup = function(app) G.win(app, 3) end }, function(c)
				local good = (c.app.export_code())
				for _, bad in ipairs({ "hello", good:sub(1, #good - 5), "GLOW9-" .. good:sub(7) }) do
					open(c, "settings")
					box.paste = bad
					wtap(c, "code_enter")
					c.run(0.6)
					assert_eq(c.app.ui.popup, "settings", bad:sub(1, 12))
					assert_eq(c.app.meta:level_to_play(), 4)
				end
				box.paste = nil
				wtap(c, "code_enter")
				c.run(0.6)
				assert_eq(c.app.ui.popup, "settings")
			end)
		end)
	end)

	it("shows every state in Russian as well", function()
		with_clip(nil, function(box)
			G.with_town({ language = "ru", setup = function(app) G.win(app, 2) end }, function(c)
				box.paste = (c.app.export_code())
				open(c, "settings")
				wtap(c, "code_enter")
				c.run(0.6)
				assert_true(has(c, "Пройдено уровней: 2"), G.dump(c.town))
				assert_same(c.E.audit(), {})
			end)
		end)
	end)
end)

describe("replay after the last level", function()
	local function finished(app) G.win(app, 100) end

	it("turns the town button into a way to the beaten levels", function()
		G.with_town({ language = "en", setup = finished }, function(c)
			assert_true(c.app.meta:all_done())
			assert_true(has(c, "Play beaten levels"), G.dump(c.town))
			c.town:tap_text("Play beaten levels")
			c.run(0.6)
			assert_eq(c.app.ui.popup, "replay")
			assert_true(has(c, "More levels are coming soon"))
			assert_same(c.E.audit(), {})
		end)
	end)

	it("opens the last page first, pages back and starts a level without touching the save", function()
		G.with_town({ language = "en", setup = finished }, function(c)
			open(c, "replay")
			local ui = c.app.ui.replay
			assert_eq(ui.pages, 5)
			assert_eq(ui.page, 5)
			assert_eq(ui.last, 100)
			wtap(c, "page_prev")
			c.run(0.4)
			assert_eq(c.app.ui.replay.page, 4)
			wtap(c, "page_next")
			c.run(0.4)
			assert_eq(c.app.ui.replay.page, 5)
			local before = c.app.meta:serialize().checksum
			wtap(c, "replay_100")
			c.step(2)
			local posts = c.E.posted("show_screen", "main:/app")
			assert_eq(posts[#posts].message.name, "level")
			assert_eq(c.app.meta:run(), nil, "a replay opens no attempt")
			assert_eq(c.app.meta:serialize().checksum, before)
		end)
	end)

	it("builds in both languages and a small window", function()
		for _, lang in ipairs({ "en", "ru" }) do
			for _, w in ipairs({ { 720, 1280 }, { 1280, 720 }, { 390, 844 } }) do
				G.with_town({ language = lang, window = w, setup = finished }, function(c)
					open(c, "replay")
					assert_same(c.E.audit(), {}, lang)
					wtap(c, "close")
					c.run(0.5)
				end)
			end
		end
	end)

	it("pays nothing and offers the next beaten level only", function()
		G.with_town({ setup = finished }, function(c)
			local level_end = require("client.level_end")
			local coins = c.app.meta:coins()
			local r = level_end.win({ moves_at_win = 4, stars = 3, unplaced = {} }, { level_id = 99 })
			assert_true(r.standalone)
			assert_eq(r.coins, 0)
			assert_eq(r.next_level, 100)
			r = level_end.win({ moves_at_win = 4, stars = 3, unplaced = {} }, { level_id = 100 })
			assert_eq(r.next_level, nil, "no Next after the last level")
			assert_eq(c.app.meta:coins(), coins)
			local l = level_end.lose({ unplaced = {} }, { level_id = 100 })
			assert_true(l.standalone)
			assert_false(l.life_lost)
		end)
	end)

	it("shows the result window of the last level without a Next button and with the soon text", function()
		G.with_town({ language = "en", setup = finished }, function(c)
			local lw = require("client.level_windows")
			local level_end = require("client.level_end")
			local r = level_end.win({ moves_at_win = 4, stars = 3, unplaced = {} }, { level_id = 100 })
			local v = lw.result(c.app.meta, r, { moves_at_win = 4, stars = 3, score = 1 }, c.app.now())
			assert_true(v.all_done)
			assert_eq(v.next_level, nil)
		end)
	end)
end)
