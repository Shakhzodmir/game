-- The authored tutorials (content/tutorials.json, or the part files until they are merged) played on the real
-- boards with the real runtime (client/tutorial.lua) behind the guard of client/level_link.lua, in both input
-- modes: every step must be possible on the board the player has when it comes (no repair from the core's hint,
-- no step given up), the guided move must complete it, and the lesson must end as "completed". A failure names
-- the level: the step of the author is wrong for the board (or the board changed under it).

local tutorial = require("client.tutorial")
local link = require("client.level_link")
local i18n = require("client.i18n")
local json = require("tools.lib.json")
local fake_board = require("tests.client.level_fake_board")

local function read(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function authored()
	local defs, sources = {}, {}
	local files = read("content/tutorials.json") and { "content/tutorials.json" }
		or { "content/tutorials_part1.json", "content/tutorials_part2.json" }
	for _, path in ipairs(files) do
		local text = read(path)
		if text then
			sources[#sources + 1] = path
			for k, v in pairs(json.decode(text)) do defs[k] = v end
		end
	end
	return defs, sources
end

local function levels_of(defs)
	local ids = {}
	for k in pairs(defs) do ids[#ids + 1] = tonumber(k) end
	table.sort(ids)
	return ids
end

-- Plays the lesson of `level` the way a player who does what the hand shows would. Returns the runtime
-- and what it did (steps done, in order).
local function play(level, defs, mode)
	local text = assert(read(string.format("content/levels/level_%04d.json", level)), "level file " .. level)
	local fb = fake_board.new({ level = level, text = text, input_mode = mode })
	local sess = fb.session
	local done = {}
	local t = tutorial.start(level, {
		defs = defs, seen = function() return false end, mark = function() end,
		on_step = function(_, st) done[#done + 1] = st.kind end,
		env = {
			state = function() return sess.game:status().state end,
			stable = link.stable, can_swap = link.can_swap, piece = link.piece, specials = link.specials,
			hint = link.core_hint, targeting = link.targeting,
			moves_left = function() return sess.game:status().moves_left end,
			booster_ready = function() return true end, mode = function() return mode end,
		},
	})
	assert_true(t ~= nil, "level " .. level .. " has a tutorial")
	link.set_guard(t:guard())
	local acted = {}
	for _ = 1, 60 * 90 do
		fb:advance(1 / 60)
		t:update(1 / 60)
		if t:finished() then break end
		local v = t:view()
		if v and t.age and t.age > 0.5 and not acted[t.rev] then
			if v.kind == "swap" then
				acted[t.rev] = true
				local a, b = v.cells[1], v.cells[2]
				if mode == "taptap" then
					fb:tap(a[1], a[2])
					fb:tap(b[1], b[2])
				else
					fb:swipe(a, b)
				end
			elseif v.kind == "tap" then
				acted[t.rev] = true
				fb:tap(v.cells[1][1], v.cells[1][2])
				if mode == "taptap" then fb:tap(v.cells[1][1], v.cells[1][2]) end -- the first tap selects
			elseif v.kind == "tip" then
				acted[t.rev] = true
				t:tap()
			elseif v.kind == "booster" then
				if v.sub == "pick" then
					acted[t.rev] = true
					link.booster(v.button)
				elseif v.sub == "target" then
					acted[t.rev] = true
					fb:tap(v.cells[1][1], v.cells[1][2])
				end
			end
		end
	end
	link.clear_guard()
	fb:detach()
	return t, done
end

describe("the authored tutorials on the real boards", function()
	it("are well formed: known kinds, cells on the board, texts in both languages", function()
		local defs = authored()
		local ids = levels_of(defs)
		if #ids == 0 then return end -- no content yet
		local missing = {}
		for _, n in ipairs(ids) do
			local steps, errors = tutorial.steps(defs, n)
			assert_true(steps ~= nil, "level " .. n .. ": " .. table.concat(errors or {}, "; "))
			assert_eq(#(errors or {}), 0, "level " .. n)
			for i, st in ipairs(steps) do
				if st.text and not i18n.has(st.text) then missing[#missing + 1] = "level " .. n .. " step " .. i .. ": " .. st.text end
			end
		end
		assert_same(missing, {})
	end)

	it("complete in swipe mode with no repair and no step given up", function()
		local defs = authored()
		for _, n in ipairs(levels_of(defs)) do
			local t = play(n, defs, "swipe")
			assert_eq(t.reason, "completed", "level " .. n)
			assert_eq(t.fallbacks, 0, "level " .. n .. " needed the core's hint instead of the author's cells")
		end
	end)

	it("complete in tap-and-tap mode with no repair and no step given up", function()
		local defs = authored()
		for _, n in ipairs(levels_of(defs)) do
			local t = play(n, defs, "taptap")
			assert_eq(t.reason, "completed", "level " .. n)
			assert_eq(t.fallbacks, 0, "level " .. n .. " needed the core's hint instead of the author's cells")
		end
	end)

	it("do every step they have, in order", function()
		local defs = authored()
		for _, n in ipairs(levels_of(defs)) do
			local steps = tutorial.steps(defs, n)
			local _, done = play(n, defs, "swipe")
			local kinds = {}
			for i, st in ipairs(steps) do kinds[i] = st.kind end
			assert_same(done, kinds, "level " .. n)
		end
	end)
end)
