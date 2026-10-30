-- Regenerates the golden replays of core-rules.md 17.1.
--
--   lua5.1 tests/golden/regen.lua          (from the repository root)
--
-- Each scenario below plays one level with a scripted, deterministic player
-- (the public API only: moves(), hint(), commands at any tick, boosters,
-- continue, skip) and stores the level, the replay (header, commands, final
-- tick and hash) and a summary in tests/golden/<name>.lua. tests/core/
-- golden_test.lua plays every stored replay back and demands the same
-- final hash and summary.
--
-- A deliberate change of the rules changes these files. Run this script, read
-- the diff of the summaries (score, state, tick) to see that the change is
-- the one intended, and commit the new files together with the rule change.

package.path = "./?.lua;./?/init.lua;" .. package.path

local core = require("core.game")
local C = require("core.const")
local digest = require("tests.golden.digest")

local COLORS6 = { "red", "orange", "yellow", "green", "blue", "purple" }


local function combos_level()
	local function sp(x, y, kind, axis) return { at = { x, y }, type = kind, axis = axis } end
	return {
		id = 9107, version = 1, size = { 8, 8 }, moves = 30, difficulty = "super_hard",
		colors = { "red", "orange", "yellow", "green" },
		goals = { { type = "collect", color = "red", count = 400 } },
		cells = { "########", "########", "########", "########", "########", "########", "########", "########" },
		slots = {
			sp(0, 1, "disco"), sp(1, 1, "riff", "h"), sp(3, 1, "disco"), sp(4, 1, "bird"), sp(6, 1, "sub"), sp(7, 1, "sub"),
			sp(0, 3, "bird"), sp(1, 3, "sub"), sp(3, 3, "bird"), sp(4, 3, "riff", "v"), sp(6, 3, "bird"), sp(7, 3, "bird"),
			sp(0, 5, "riff", "h"), sp(1, 5, "riff", "v"), sp(3, 5, "riff", "h"), sp(4, 5, "sub"), sp(6, 5, "disco"), sp(7, 5, "disco"),
			sp(0, 7, "disco"), sp(1, 7, "sub"),
		},
	}
end

local SCENARIOS = {
	{
		name = "classic",
		level = {
			id = 9101, version = 1, size = { 7, 8 }, moves = 22, difficulty = "hard",
			colors = { "red", "orange", "yellow", "green", "blue" },
			goals = { { type = "collect", color = "orange", count = 24 }, { type = "break", item = "record_box", count = 3 } },
			cells = { "#######", "#######", "###.###", "#######", "#######", "#######", "#######", "#######" },
			floor = { { at = { 0, 7 }, hp = 2 }, { at = { 6, 7 }, hp = 1 }, { at = { 3, 6 }, hp = 1 } },
			overlay = { { at = { 1, 1 }, type = "wires", hp = 2 }, { at = { 5, 3 }, type = "wires", hp = 1 } },
			slots = { { at = { 2, 4 }, type = "record_box", hp = 2 }, { at = { 5, 5 }, type = "record_box", hp = 1 },
				{ at = { 1, 3 }, type = "record_box", hp = 3 } },
			spawn_weights = { red = 3, orange = 2, yellow = 2, green = 2, blue = 1 },
		},
		opts = { seed = 4711, attempt = 2, salt = 31337, help = 1, boosters = { "riff" }, timing = "normal" },
		policy = { seed = 5, rate = 3, boosters = 3, continues = 1, give_up = false },
	},
	{
		name = "specials",
		level = {
			id = 9102, version = 1, size = { 7, 7 }, moves = 18, difficulty = "medium",
			colors = { "red", "green", "blue", "yellow" },
			goals = { { type = "collect", color = "green", count = 40 } },
			cells = { "#######", "#######", "#######", "#######", "#######", "#######", "#######" },
			slots = {
				{ at = { 1, 1 }, type = "riff", axis = "h" }, { at = { 3, 1 }, type = "sub" }, { at = { 5, 1 }, type = "riff", axis = "v" },
				{ at = { 2, 2 }, type = "disco" }, { at = { 4, 2 }, type = "bird" }, { at = { 1, 3 }, type = "bird" },
				{ at = { 3, 3 }, type = "sub" }, { at = { 5, 3 }, type = "riff", axis = "h" }, { at = { 2, 4 }, type = "riff", axis = "v" },
				{ at = { 4, 4 }, type = "disco" }, { at = { 1, 5 }, type = "sub" }, { at = { 3, 5 }, type = "bird" },
				{ at = { 5, 5 }, type = "riff", axis = "v" },
			},
		},
		opts = { seed = 20250101, help = 0, boosters = { "sub", "disco", "riff" }, timing = "normal" },
		policy = { seed = 9, rate = 2, boosters = 2, taps = true, continues = 0, give_up = true },
	},
	{
		name = "deliver",
		level = {
			id = 9103, version = 1, size = { 8, 6 }, moves = 16, difficulty = "super_hard",
			colors = COLORS6,
			goals = { { type = "deliver", count = 3 }, { type = "collect", color = "blue", count = 15 } },
			cells = { "..####..", ".######.", "########", "########", "########", "########" },
			mic = { total = 3, on_board_max = 2, gap_moves = 2 },
			slots = { { at = { 3, 2 }, type = "mic" } },
		},
		opts = { seed = 99, attempt = 1, salt = 7, help = 2, boosters = { "disco" }, timing = "turbo" },
		policy = { seed = 3, rate = 2, boosters = 2, continues = 2, give_up = false },
	},
	{
		-- narrow strips and noise: dead boards (shuffles) and the growth of noise
		name = "strips",
		level = {
			id = 9106, version = 1, size = { 8, 6 }, moves = 20, difficulty = "hard",
			colors = { "red", "orange", "yellow", "green", "blue" },
			goals = { { type = "collect", color = "red", count = 30 } },
			cells = { "##.##.##", "##.##.##", "##.##.##", "##.##.##", "##.##.##", "##.##.##" },
			slots = { { at = { 0, 2 }, type = "noise" }, { at = { 4, 3 }, type = "noise" }, { at = { 7, 4 }, type = "noise" },
				{ at = { 1, 1 }, type = "record_box", hp = 1 } },
		},
		opts = { seed = 4, attempt = 1, salt = 5, help = 0, timing = "normal" },
		policy = { seed = 4, rate = 2, boosters = 0, continues = 0, give_up = true },
	},
	{
		-- the blocking mode (input_lock): commands every tick, most of them refused with not_rest
		name = "locked",
		level = {
			id = 9105, version = 1, size = { 6, 7 }, moves = 12, difficulty = "medium",
			colors = { "red", "orange", "yellow", "green", "blue" },
			goals = { { type = "collect", color = "red", count = 15 } },
			cells = { "######", "######", "######", "######", "######", "######", "######" },
			floor = { { at = { 2, 5 }, hp = 1 } },
		},
		opts = { seed = 31, attempt = 1, salt = 1, help = 0, timing = "normal", input_lock = true },
		policy = { seed = 11, rate = 1, boosters = 2, continues = 0, give_up = true },
	},
	{
		-- every pair of specials next to each other: the ten combos, chains, Colour X (both timings)
		name = "combos_normal",
		level = combos_level(),
		opts = { seed = 5, timing = "normal" },
		policy = { hint_only = true, seed = 1, continues = 0, give_up = true },
	},
	{
		name = "combos_turbo",
		level = combos_level(),
		opts = { seed = 5, timing = "turbo", boosters = { "disco" } },
		policy = { hint_only = true, seed = 1, continues = 0, give_up = true },
	},
	{
		name = "concert",
		level = {
			id = 9104, version = 1, size = { 7, 6 }, moves = 14, difficulty = "easy",
			colors = { "red", "green", "blue", "yellow", "purple" },
			goals = { { type = "collect", color = "red", count = 6 } },
			cells = { "#######", "#######", "#######", "#######", "#######", "#######" },
		},
		opts = { seed = 777, help = 0, boosters = { "riff", "riff" }, timing = "normal" },
		policy = { seed = 21, rate = 2, boosters = 0, continues = 0, give_up = true, skip_after = 40 },
	},
}

-- Player ---------------------------------------------------------------------------

local function lcg(seed)
	local x = seed
	return function(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return math.floor(x / 65536) % n + 1
	end
end

local function play(game, p, events)
	local rnd = lcg(p.seed)
	local boosters, continues, concert_ticks = p.boosters, p.continues, 0
	local ticks = 0
	while ticks < 6000 do
		local st = game:status().state
		if st == "complete" or st == "lost" then break end
		local W, H = game.s.W, game.s.H
		if st == "out_of_moves" then
			if continues > 0 and not game:status().stuck then
				continues = continues - 1
				game:input({ type = "continue", moves = 3, riff = rnd(2) == 1 })
			elseif p.give_up or game:status().stuck then
				game:input({ type = "give_up" })
			else
				game:input({ type = "give_up" })
			end
		elseif st == "concert" or st == "won_wait" then
			concert_ticks = concert_ticks + 1
			if p.skip_after and concert_ticks == p.skip_after then game:input({ type = "skip" }) end
		elseif p.hint_only then
			-- the best move of the hint whenever the board is at rest
			if game:is_stable() then
				local h = game:hint()
				if h and h.from then
					game:input({ type = "swap", from = h.from, to = h.to })
				elseif h and h.at then
					game:input({ type = "tap", at = h.at })
				end
			end
		elseif rnd(p.rate) == 1 then
			local r = rnd(20)
			if r <= 9 then
				local h = game:hint()
				if h and h.from then
					game:input({ type = "swap", from = h.from, to = h.to })
				elseif h and h.at then
					game:input({ type = "tap", at = h.at })
				end
			elseif r <= 14 then
				local mv = game:moves()
				if #mv > 0 then
					local m = mv[rnd(#mv)]
					game:input({ type = "swap", from = m.from, to = m.to })
				end
			elseif r <= 16 then
				local x, y = rnd(W - 1), rnd(H)
				game:input({ type = "swap", from = { x, y }, to = { x + 1, y } })
			elseif r == 17 and p.taps then
				game:input({ type = "tap", at = { rnd(W), rnd(H) } })
			elseif r >= 18 and boosters > 0 then
				local kind = rnd(4)
				local ok
				if kind == 1 then
					ok = game:input({ type = "booster", booster = "stick", at = { rnd(W), rnd(H) } })
				elseif kind == 2 then
					ok = game:input({ type = "booster", booster = "row_light", row = rnd(H) })
				elseif kind == 3 then
					ok = game:input({ type = "booster", booster = "col_light", col = rnd(W) })
				else
					ok = game:input({ type = "booster", booster = "remix" })
				end
				if ok then boosters = boosters - 1 end
			end
		end
		game:step()
		for _, e in ipairs(game:drain_events()) do events[#events + 1] = e end
		ticks = ticks + 1
	end
end

-- Serializer -----------------------------------------------------------------------

local function key(k)
	if type(k) == "string" and string.find(k, "^[%a_][%w_]*$") and k ~= "end" and k ~= "and" and k ~= "or"
		and k ~= "not" and k ~= "nil" and k ~= "true" and k ~= "false" and k ~= "if" and k ~= "in" and k ~= "do"
		and k ~= "for" and k ~= "function" and k ~= "local" and k ~= "return" and k ~= "then" and k ~= "while"
		and k ~= "break" and k ~= "else" and k ~= "elseif" and k ~= "repeat" and k ~= "until" then
		return k
	end
	return "[" .. string.format("%q", k) .. "]"
end

local function ser(v, indent)
	local t = type(v)
	if t == "number" then return string.format("%.0f", v) end
	if t == "boolean" then return tostring(v) end
	if t == "string" then return string.format("%q", v) end
	local pad = string.rep("\t", indent + 1)
	local n = #v
	local parts = {}
	if n > 0 then
		local flat = true
		for i = 1, n do
			if type(v[i]) == "table" then flat = false end
		end
		for i = 1, n do parts[i] = ser(v[i], indent + 1) end
		if flat then return "{ " .. table.concat(parts, ", ") .. " }" end
		return "{\n" .. pad .. table.concat(parts, ",\n" .. pad) .. ",\n" .. string.rep("\t", indent) .. "}"
	end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end -- order-independent (sorted next)
	if #keys == 0 then return "{}" end
	table.sort(keys)
	local flat = true
	for _, k in ipairs(keys) do
		if type(v[k]) == "table" then flat = false end
		parts[#parts + 1] = key(k) .. " = " .. ser(v[k], indent + 1)
	end
	if flat then return "{ " .. table.concat(parts, ", ") .. " }" end
	return "{\n" .. pad .. table.concat(parts, ",\n" .. pad) .. ",\n" .. string.rep("\t", indent) .. "}"
end

local function write(path, text)
	local f = assert(io.open(path, "w"))
	f:write(text)
	f:close()
end

-- Main -------------------------------------------------------------------------------

local names = {}
for _, sc in ipairs(SCENARIOS) do
	local lvl, errs = core.load_level(sc.level)
	if not lvl then error(sc.name .. ": " .. table.concat(errs, "; ")) end
	local game, gerrs = core.new(lvl, sc.opts)
	if not game then error(sc.name .. ": " .. table.concat(gerrs, "; ")) end
	local events = {}
	play(game, sc.policy, events)
	game:run_to_rest()
	for _, e in ipairs(game:drain_events()) do events[#events + 1] = e end
	local st = game:status()
	local n_events, event_digest = digest.events(events)
	local summary = { state = st.state, tick = st.tick, score = st.score, moves_left = st.moves_left,
		commands = #game:replay().commands, events = n_events, event_digest = event_digest }
	local text = "-- Generated by tests/golden/regen.lua (core " .. C.CORE_VERSION .. "); do not edit.\n"
		.. "return " .. ser({ name = sc.name, level = sc.level, replay = game:replay(), summary = summary }, 0) .. "\n"
	write("tests/golden/" .. sc.name .. ".lua", text)
	names[#names + 1] = sc.name
	print(string.format("%-10s %-13s tick %5d  score %6d  moves_left %3d  commands %3d  events %6d", sc.name, st.state, st.tick, st.score, st.moves_left, summary.commands, n_events))
end

local lines = { "-- Generated by tests/golden/regen.lua; do not edit.", "return {" }
for _, n in ipairs(names) do lines[#lines + 1] = "\t" .. string.format("%q", n) .. "," end
lines[#lines + 1] = "}"
write("tests/golden/index.lua", table.concat(lines, "\n") .. "\n")
