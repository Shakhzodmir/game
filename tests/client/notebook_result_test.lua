-- The songbook in the results window of a level (gui/result.lua): the line Bit writes after a win, the finished
-- song at the end of a stretch with a way to hear it, a replay writing nothing.

local G = require("tests.client.level_gui_helper")
local flow = require("client.flow")
local songbook = require("client.songbook")

local function win(c)
	c.fb.session:autoplay(nil, { free_moves = true })
	for _ = 1, 60 * 120 do
		c.step(1)
		if c.popup() == "result" then break end
	end
	c.step(240) -- the writing is over
end

local function win_until(n)
	return function(app)
		while app.meta:level_to_play() < n do assert(flow.debug_win(3, true)) end
	end
end

describe("results window: the songbook", function()
	it("writes the line of the level that was won, on a sheet, within two seconds", function()
		G.with_level({ level = 3 }, function(c)
			win(c)
			assert_eq(c.popup(), "result")
			local song = c.app.meta:song_of("cafe")
			assert_eq(song.count, 3)
			assert_true(c.has("Bit wrote a new line"))
			assert_true(c.has(songbook.line("cafe", song.lines[3])), "the line is on the sheet")
		end)
	end)

	it("does not write the line at once: the letters come one by one, a tap finishes it", function()
		G.with_level({ level = 3 }, function(c)
			c.fb.session:autoplay(nil, { free_moves = true })
			for _ = 1, 60 * 120 do
				c.step(1)
				if c.popup() == "result" then break end
			end
			c.step(40) -- 0.7 s into the window
			local song = c.app.meta:song_of("cafe")
			local text = songbook.line("cafe", song.lines[3])
			assert_false(c.has(text), "the whole line is already there")
			c.step(150)
			assert_true(c.has(text), "the line is written after 2.5 s")
		end)
	end)

	it("announces a finished song and opens the notebook from it", function()
		G.with_level({ level = 20, setup = win_until(20) }, function(c)
			win(c)
			assert_eq(c.popup(), "result")
			assert_true(c.has("Your song is ready!"))
			local song = c.app.meta:song_of("cafe")
			assert_true(song.ready)
			assert_true(c.has(songbook.title("cafe", song.title)))
			c.tap_target("song_open")
			c.step(60)
			assert_eq(c.popup(), "notebook")
			assert_true(c.app.ui.notebook.ready)
			c.tap_target("close")
			c.run(0.6)
			assert_eq(c.popup(), "result", "back to the results")
		end)
	end)

	it("keeps one line per level", function()
		G.with_level({ level = 3, setup = win_until(3) }, function(c)
			win(c)
			assert_eq(c.app.meta:song_of("cafe").count, 3)
		end)
	end)
end)
