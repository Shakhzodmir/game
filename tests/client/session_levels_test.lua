-- Every level of the game on the real level screen scripts (tests/client/session_harness.lua): the board script, the
-- HUD, the effects and the background build the level, play its first moves and, for a few of them, take it to the
-- results window. The unit tests of the board run on a handful of levels; a level file written later that uses a
-- blocker, a goal or a start board the client cannot draw shows up here, with its number. (The harness fails a
-- session on any WARNING / ERROR line the game prints, so a swallowed error counts.)

local S = require("tests.client.session_harness")
local link = require("client.level_link")

local function level_count()
	local n = 0
	while true do
		local f = io.open(string.format("content/levels/level_%04d.json", n + 1), "rb")
		if not f then return n end
		f:close()
		n = n + 1
	end
end

-- The standalone debug level n (the QA bridge's `goto level n`): no attempt in the meta, the same scripts.
local function on_level(s, n)
	s:step_until(function() return s.app.screen == "splash" or s.app.screen == "level" end, 4, "the boot")
	s:qa("goto level " .. n)
	s:step_until(function()
		return s.app.screen == "level" and not s.app.transitioning and s.app.params and s.app.params.level == n
	end, 12, "level " .. n)
end

describe("a session: every level", function()
	it("is built by the level screen and plays its first moves", function()
		local count = level_count()
		assert_true(count >= 100, "content/levels has " .. count .. " levels")
		for n = 1, count do
			local ok, err = pcall(S.run, {}, function(s)
				on_level(s, n)
				s:run(0.7)
				local st = assert(link.status(), "no board")
				assert_eq(st.state, "playing")
				local moves = st.moves_left
				link.board.session:qa("autoplay", { "2" })
				s:step_until(function()
					local x = link.status()
					return x.state ~= "playing" or x.moves_left <= moves - 2
				end, 20, "two moves")
				s:run(0.5)
			end)
			if not ok then error("level " .. n .. ": " .. tostring(err), 0) end
		end
	end)

	it("fits its board into a small phone, a landscape window and a big tablet (every seventh)", function()
		local count = level_count()
		for _, size in ipairs({ { 320, 568 }, { 1280, 720 }, { 1024, 1366 } }) do
			for n = 1, count, 7 do
				local ok, err = pcall(S.run, { window = size }, function(s)
					on_level(s, n)
					s:run(0.5)
					local r = assert(link.board_rect(), "no board")
					assert_true(r.x1 > r.x0 and r.y1 > r.y0, "an empty board rectangle")
					assert_true(r.x0 >= 0 and r.x1 <= 720 and r.y0 >= 0 and r.y1 <= 1280, "the board is outside the 720 x 1280 area")
					s.E.set_window(size[2], size[1]) -- turned around and back, with the level running
					s:run(0.4)
					s.E.set_window(size[1], size[2])
					s:run(0.3)
					assert_eq(link.status().state, "playing")
				end)
				if not ok then error(size[1] .. "x" .. size[2] .. ", level " .. n .. ": " .. tostring(err), 0) end
			end
		end
	end)

	it("can be won to the results window (every twentieth)", function()
		local count = level_count()
		for n = 20, count, 20 do
			local ok, err = pcall(S.run, { audio = true }, function(s)
				on_level(s, n)
				s:run(0.7)
				assert_true(link.board.session:qa("win").ok)
				s:step_until(function() return s.app.ui.popup == "result" end, 700, "the results of level " .. n)
				s:run(0.5)
			end)
			if not ok then error("level " .. n .. ": " .. tostring(err), 0) end
		end
	end)
end)
