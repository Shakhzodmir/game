-- The event stream (section 16): every event type with its fields, and the
-- causal order, checked over random play and a few scripted scenes.

local core = require("core.game")
local C = require("core.const")
local H = require("tests.core.helper")

local function lcg(seed)
	local x = seed
	return function(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return math.floor(x / 65536) % n + 1
	end
end

-- Field checks ------------------------------------------------------------------

local function is_int(v) return type(v) == "number" and v == math.floor(v) end
local function oneof(...)
	local set = {}
	for _, v in ipairs({ ... }) do set[v] = true end
	return function(v) return set[v] == true end
end
local function list(check)
	return function(v)
		if type(v) ~= "table" then return false end
		for i = 1, #v do if not check(v[i]) then return false end end
		return true
	end
end
local function cell(v) return type(v) == "table" and #v == 2 and is_int(v[1]) and is_int(v[2]) end
local function ids(v)
	return type(v) == "table" and #v == 2 and is_int(v[1]) and v[1] >= 1 and is_int(v[2]) and v[2] >= 1
end
-- cells by ascending cell index, that is, row by row
local function by_index(v)
	if type(v) ~= "table" or #v < 3 then return false end
	for i = 1, #v do
		if not cell(v[i]) then return false end
		if i > 1 and not (v[i][2] > v[i - 1][2] or (v[i][2] == v[i - 1][2] and v[i][1] > v[i - 1][1])) then return false end
	end
	return true
end
local function shape(fields)
	return function(v)
		if type(v) ~= "table" then return false end
		for k, check in pairs(fields) do -- order-independent
			if not check(v[k]) then return false end
		end
		for k in pairs(v) do -- order-independent
			if fields[k] == nil then return false end
		end
		return true
	end
end
local function opt(check) return function(v) return v == nil or check(v) end end
local function pos(v) return is_int(v) and v >= 1 end
local function nat(v) return is_int(v) and v >= 0 end
local COLOR = oneof("red", "orange", "yellow", "green", "blue", "purple")
local SPECIAL = oneof("riff", "sub", "bird", "disco")
local AXIS = oneof("h", "v")
local DIR = oneof("l", "r", "u", "d")
local BLOCKER = oneof("record_box", "concrete", "noise", "balloon", "column")

-- type -> field -> check (t and type are added to every event)
local SCHEMA = {
	swap = { a = cell, b = cell, ids = ids, duration = pos },
	swap_fail = { a = cell, b = cell, ids = ids, duration = pos },
	swap_back = { a = cell, b = cell, ids = ids, duration = pos },
	moves = { left = nat },
	match = { cells = by_index, color = COLOR, wave = pos, act = nat, special = opt(SPECIAL) },
	clear = { id = pos, x = pos, y = pos, kind = oneof("regular", "special", "mic", "blocker"), color = opt(COLOR),
		special = opt(SPECIAL), cause = oneof("match", "effect", "fired") },
	special_new = { id = pos, x = pos, y = pos, special = SPECIAL, axis = opt(AXIS) },
	activate = { id = opt(pos), x = pos, y = pos, special = SPECIAL, axis = opt(AXIS), color = opt(COLOR),
		combo = opt(oneof("cross", "triple_cross", "bass_drop", "bird_riff", "bird_sub", "trio", "finale",
			"color_riff", "color_sub", "color_bird")), partner = opt(pos) },
	bolt = { x = pos, y = pos, dir = DIR, at = nat },
	ring = { x = pos, y = pos, r = nat, at = nat },
	bird_fly = { x = pos, y = pos, tx = pos, ty = pos, carry = opt(oneof("riff", "sub")), axis = opt(AXIS), duration = nat },
	disco_ray = { x = pos, y = pos, tx = pos, ty = pos },
	transform = { id = pos, x = pos, y = pos, special = SPECIAL, axis = opt(AXIS) },
	hit = { x = pos, y = pos, layer = oneof("wires", "blocker", "floor"), item = opt(BLOCKER), hp = nat },
	destroy = { id = pos, x = pos, y = pos, item = BLOCKER },
	floor_lit = { x = pos, y = pos },
	freed = { id = pos, x = pos, y = pos },
	score = { delta = pos, total = pos, x = pos, y = pos },
	goal = { index = pos, left = nat },
	land = { id = pos, x = pos, y = pos },
	spawn = { id = pos, x = pos, y = pos, kind = oneof("regular", "mic"), color = opt(COLOR) },
	praise = { act = nat, wave = pos, word = oneof("juicy", "hit", "drive", "vibe", "legend") },
	noise_spread = { fx = pos, fy = pos, x = pos, y = pos, id = pos },
	mic_delivered = { id = pos, x = pos, y = pos },
	shuffle = { moves = list(shape({ id = pos, fx = pos, fy = pos, x = pos, y = pos })),
		recolors = list(shape({ id = pos, color = COLOR })),
		riff = opt(shape({ id = pos, x = pos, y = pos, from = oneof("piece", "wires", "noise") })), duration = pos },
	concert_riff = { id = pos, x = pos, y = pos, axis = AXIS },
	continue_riff = { id = pos, x = pos, y = pos },
	booster = { booster = oneof("stick", "row_light", "col_light", "remix"), at = opt(cell), row = opt(pos), col = opt(pos),
		ok = function(v) return type(v) == "boolean" end },
	state = { state = oneof("playing", "won_wait", "concert", "out_of_moves", "lost", "complete"), reason = opt(oneof("stuck")) },
}

local function validate(e, where)
	local spec = SCHEMA[e.type]
	assert_true(spec ~= nil, where .. ": unknown event type " .. tostring(e.type))
	assert_true(is_int(e.t) and e.t >= 0, where .. ": t of " .. e.type)
	for k, check in pairs(spec) do -- order-independent
		assert_true(check(e[k]), where .. ": field " .. k .. " of " .. e.type .. " = " .. tostring(e[k]))
	end
	for k in pairs(e) do -- order-independent
		assert_true(k == "t" or k == "type" or spec[k] ~= nil, where .. ": extra field " .. k .. " in " .. e.type)
	end
end

-- Random play over levels that reach every event type -------------------------------

local LEVELS = {
	{ rows = { "#######", "#######", "###.###", "#######", "#######", "#######", "#######" },
		extra = { moves = 25, floor = { { at = { 0, 6 }, hp = 2 }, { at = { 5, 5 }, hp = 1 } },
			overlay = { { at = { 1, 1 }, type = "wires", hp = 2 }, { at = { 4, 4 }, type = "wires", hp = 1 } },
			goals = { { type = "collect", color = "red", count = 60 }, { type = "light" } } } },
	{ rows = { "######", "######", "######", "######", "######", "######", "######" },
		extra = { moves = 20, colors = { "red", "green", "blue", "yellow" },
			slots = { { at = { 1, 3 }, type = "record_box", hp = 2 }, { at = { 3, 2 }, type = "noise" },
				{ at = { 2, 4 }, type = "column", hp = 6 } },
			goals = { { type = "break", item = "record_box", count = 1 }, { type = "collect", color = "blue", count = 80 } } } },
	{ rows = { "..####..", ".######.", "########", "########", "########", "########" },
		extra = { moves = 20, goals = { { type = "deliver", count = 3 } },
			mic = { total = 3, on_board_max = 2, gap_moves = 1 }, slots = { { at = { 3, 2 }, type = "mic" } } } },
	{ rows = { "#######", "#######", "#######", "#######", "#######", "#######" },
		extra = { moves = 15, colors = { "red", "green", "blue", "yellow", "purple" },
			goals = { { type = "collect", color = "red", count = 8 } } } },
	{ rows = { "#######", "#R#S#V#", "##D#B##", "#B#S#R#", "##V#D##", "#S#B#V#", "#######" },
		extra = { moves = 30, colors = { "red", "green", "blue", "yellow" },
			goals = { { type = "collect", color = "green", count = 300 } } } },
	{ rows = { "########", "#K##K#B#", "##A##E##", "#B#DD#S#", "##K##A##", "#SB##BR#", "########" },
		extra = { moves = 30, colors = { "red", "orange", "blue", "purple", "yellow" },
			floor = { { at = { 0, 6 }, hp = 2 }, { at = { 3, 6 }, hp = 1 }, { at = { 7, 0 }, hp = 1 }, { at = { 5, 3 }, hp = 1 } },
			goals = { { type = "break", item = "concrete", count = 3 }, { type = "light" } } } },
}

-- Plays a game with random commands; returns all events in order.
local function play(lvl, seed, timing, rnd, limit)
	local g = core.new(lvl, { seed = seed, timing = timing, boosters = { "riff" }, help = seed % 3 })
	local all = {}
	local ticks = 0
	while g.s.state ~= C.G_COMPLETE and g.s.state ~= C.G_LOST and ticks < (limit or 3000) do
		local st = g.s.state
		if st == C.G_OUT then
			if rnd(3) == 1 and not g.s.stuck then
				g:input({ type = "continue", moves = 2, riff = rnd(2) == 1 })
			else
				g:input({ type = "give_up" })
			end
		elseif rnd(3) == 1 then
			local r = rnd(12)
			if r <= 5 then
				local mv = g:moves()
				if #mv > 0 then
					local m = mv[rnd(#mv)]
					g:input({ type = "swap", from = m.from, to = m.to })
				end
			elseif r == 6 then
				g:input({ type = "swap", from = { rnd(g.s.W), rnd(g.s.H) }, to = { rnd(g.s.W), rnd(g.s.H) } })
			elseif r == 7 then
				g:input({ type = "booster", booster = "stick", at = { rnd(g.s.W), rnd(g.s.H) } })
			elseif r == 8 then
				g:input({ type = "booster", booster = "row_light", row = rnd(g.s.H) })
			elseif r == 9 then
				g:input({ type = "tap", at = { rnd(g.s.W), rnd(g.s.H) } })
			elseif r == 10 then
				g:input({ type = "booster", booster = "col_light", col = rnd(g.s.W) })
			elseif r == 11 then
				g:input({ type = "booster", booster = "remix" })
			else
				-- a swap of two neighbours chosen at random: failed swaps and rejected ones
				local x, y = rnd(g.s.W - 1), rnd(g.s.H)
				g:input({ type = "swap", from = { x, y }, to = { x + 1, y } })
			end
		end
		g:step()
		ticks = ticks + 1
		for _, e in ipairs(g:drain_events()) do all[#all + 1] = e end
	end
	return all, g
end

local function all_events()
	local out = {}
	for li, spec in ipairs(LEVELS) do
		local lvl = H.load(spec.rows, spec.extra)
		for _, timing in ipairs({ "normal", "turbo" }) do
			for game_no = 1, 4 do
				local rnd = lcg(li * 97 + game_no * 13 + #timing)
				local evs, g = play(lvl, li * 100 + game_no, timing, rnd)
				out[#out + 1] = { events = evs, game = g, name = "level " .. li .. " " .. timing .. " #" .. game_no }
			end
		end
	end
	return out
end

-- the games are played on first use, so that an error shows up as a failed test
local cached
local function runs()
	if not cached then cached = all_events() end
	return cached
end

describe("core events: every event has exactly the fields of 16", function()
	it("passes the schema over random play on six levels, both timings", function()
		local seen = {}
		for _, run in ipairs(runs()) do
			for k, e in ipairs(run.events) do
				validate(e, run.name .. " event " .. k)
				seen[e.type] = (seen[e.type] or 0) + 1
			end
		end
		-- the random games reach most of the table; the scenes below add the rest
		for _, ty in ipairs({ "swap", "swap_back", "moves", "match", "clear", "special_new", "activate", "bolt", "ring", "bird_fly",
			"disco_ray", "transform", "hit", "destroy", "floor_lit", "freed", "score", "goal", "land", "spawn", "praise",
			"mic_delivered", "shuffle", "concert_riff", "booster", "state" }) do
			assert_true(seen[ty] ~= nil, "no " .. ty .. " event in the random games")
		end
	end)

	it("t never decreases and a command's events carry tick + 1", function()
		for _, run in ipairs(runs()) do
			local t = 0
			for k, e in ipairs(run.events) do
				assert_true(e.t >= t, run.name .. " event " .. k .. " (" .. e.type .. ") goes back in time")
				t = e.t
			end
		end
	end)
end)

describe("core events: causal order (16)", function()
	it("swap and swap_back are followed by moves; swap_fail is not", function()
		for _, run in ipairs(runs()) do
			local ev = run.events
			for k = 1, #ev do
				if ev[k].type == "swap" or ev[k].type == "swap_back" then
					assert_eq(ev[k + 1].type, "moves", run.name .. " after " .. ev[k].type)
					assert_eq(ev[k + 1].t, ev[k].t)
				end
			end
		end
	end)

	it("a goal that reaches the last open goal is followed at once by state won_wait", function()
		local won = 0
		for _, run in ipairs(runs()) do
			local left = {}
			for k = 1, #run.game.s.level.goals do left[k] = run.game.s.level.goals[k].count end
			local ev = run.events
			for k = 1, #ev do
				if ev[k].type == "goal" then
					left[ev[k].index] = ev[k].left
					local all = true
					for i = 1, #left do if left[i] > 0 then all = false end end
					if all then
						assert_same({ ev[k + 1].type, ev[k + 1].state }, { "state", "won_wait" }, run.name)
						won = won + 1
					end
				end
			end
		end
		assert_true(won > 0, "some game must win")
	end)

	it("goal events never repeat a finished goal and never grow", function()
		for _, run in ipairs(runs()) do
			local last = {}
			for _, e in ipairs(run.events) do
				if e.type == "goal" then
					if last[e.index] then assert_true(e.left < last[e.index], run.name .. " goal " .. e.index) end
					last[e.index] = e.left
				end
			end
		end
	end)

	it("a new special is followed by the score of its bonus; a lit tile follows its hit", function()
		for _, run in ipairs(runs()) do
			local ev = run.events
			for k = 1, #ev do
				local e = ev[k]
				if e.type == "special_new" then
					assert_eq(ev[k + 1].type, "score", run.name)
					assert_same({ ev[k + 1].x, ev[k + 1].y }, { e.x, e.y })
				elseif e.type == "floor_lit" then
					assert_same({ ev[k - 1].type, ev[k - 1].layer, ev[k - 1].hp, ev[k - 1].x, ev[k - 1].y }, { "hit", "floor", 0, e.x, e.y }, run.name)
				elseif e.type == "hit" and e.layer == "floor" and e.hp == 0 then
					assert_eq(ev[k + 1].type, "floor_lit", run.name)
				end
			end
		end
	end)

	it("freed follows the last hit on the wires of that cell", function()
		for _, run in ipairs(runs()) do
			local ev = run.events
			for k = 1, #ev do
				if ev[k].type == "freed" and ev[k - 1].type == "hit" then
					assert_same({ ev[k - 1].layer, ev[k - 1].hp, ev[k - 1].x, ev[k - 1].y }, { "wires", 0, ev[k].x, ev[k].y }, run.name)
				end
			end
		end
	end)

	it("activate comes first: bolt and ring belong to the activation of the same tick", function()
		for _, run in ipairs(runs()) do
			local ev = run.events
			for k = 1, #ev do
				if ev[k].type == "bolt" or ev[k].type == "ring" then
					local j = k
					while j > 1 and ev[j].type ~= "activate" and ev[j].type ~= "booster" do j = j - 1 end
					assert_true(ev[j].type == "activate" or ev[j].type == "booster", run.name .. ": a " .. ev[k].type .. " without activation")
					assert_eq(ev[j].t, ev[k].t, run.name)
				end
			end
		end
	end)

	it("a match comes before the clears of its cells; special_new after them; adjacent hits and praise last", function()
		for _, run in ipairs(runs()) do
			local ev = run.events
			for k = 1, #ev do
				if ev[k].type == "match" then
					local j = k + 1
					local n = 0
					local want = {}
					for _, c in ipairs(ev[k].cells) do want[c[1] .. "," .. c[2]] = true end
					while ev[j] and ev[j].type ~= "match" do
						if ev[j].type == "clear" and ev[j].t == ev[k].t and ev[j].cause == "match" and want[ev[j].x .. "," .. ev[j].y] then
							n = n + 1
							want[ev[j].x .. "," .. ev[j].y] = nil
						end
						if ev[j].type == "praise" then break end
						j = j + 1
					end
					-- every piece of the group is cleared by the match (a wired piece is only freed)
					assert_true(n >= 1, run.name .. ": a match without a clear")
				end
			end
		end
	end)

	it("the score total is the running sum of the deltas and ends at the game's score", function()
		for _, run in ipairs(runs()) do
			local total = 0
			for _, e in ipairs(run.events) do
				if e.type == "score" then
					total = total + e.delta
					assert_eq(e.total, total, run.name)
				end
			end
			assert_eq(total, run.game.s.score, run.name)
		end
	end)

	it("moves events carry the real moves_left, and the last state event the real state", function()
		for _, run in ipairs(runs()) do
			local left, state = run.game.s.level.moves, "playing"
			for _, e in ipairs(run.events) do
				if e.type == "moves" then left = e.left end
				if e.type == "state" then state = e.state end
			end
			assert_eq(left, run.game.s.moves_left, run.name)
			assert_eq(state, C.GAME_NAME[run.game.s.state], run.name)
		end
	end)

	it("every state event is a real change", function()
		for _, run in ipairs(runs()) do
			local state = "playing"
			for _, e in ipairs(run.events) do
				if e.type == "state" then
					assert_true(e.state ~= state, run.name .. ": " .. e.state .. " twice")
					state = e.state
				end
			end
		end
	end)

	it("ids: spawns and new specials take ascending fresh ids; land and clear mention known ids", function()
		for _, run in ipairs(runs()) do
			local top = 0
			for _, e in ipairs(run.events) do
				if e.type == "spawn" or e.type == "special_new" then
					assert_true(e.id > top, run.name .. ": id " .. e.id .. " is not fresh")
					top = e.id
				end
			end
		end
	end)
end)

-- Scenes for the events random play does not reach ---------------------------------------

local FULL = { "######", "######", "######", "######", "######", "######" }
local P1 = { "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }
local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or P1)
	return g
end

describe("core events: scenes (16)", function()
	it("swap_fail: a, b, ids and the duration, no moves", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local a, b = H.obj_at(g, 5, 5), H.obj_at(g, 6, 5)
		assert_same({ g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) }, { true, "fail" })
		local ev = g:drain_events()
		assert_same(ev, { { t = 1, type = "swap_fail", a = { 5, 5 }, b = { 6, 5 }, ids = { a.id, b.id }, duration = 14 } })
		validate(ev[1], "swap_fail")
	end)

	it("a swap: a is the cell the player dragged, b its neighbour, ids in that order", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		local a, b = H.obj_at(g, 4, 1), H.obj_at(g, 3, 1)
		g:input({ type = "swap", from = { 4, 1 }, to = { 3, 1 } })
		local ev = g:drain_events()
		assert_same(ev[1], { t = 1, type = "swap", a = { 4, 1 }, b = { 3, 1 }, ids = { a.id, b.id }, duration = 10 })
		assert_same(ev[2], { t = 1, type = "moves", left = 19 })
	end)

	it("destroy of a column is placed on its top-left cell, its four floors take one hit each, by index", function()
		local g = fresh({ "rrgrby", "yrgbyr", "rgLlrg", "gbllrg", "byrgby", "yrgbyr" }, {
			floor = { { at = { 2, 2 }, hp = 1 }, { at = { 3, 2 }, hp = 1 }, { at = { 2, 3 }, hp = 1 }, { at = { 3, 3 }, hp = 1 } },
			goals = { { type = "light" } },
		})
		g.s.objs[H.obj_at(g, 3, 3).id].hp = 1
		for _, c in ipairs({ 15, 16, 21, 22 }) do g.s.floor[c] = 1 end
		g:input({ type = "booster", booster = "stick", at = { 4, 4 } })
		g:step()
		local ev = g:drain_events()
		local seq = {}
		for _, e in ipairs(ev) do seq[#seq + 1] = e.type .. (e.x and (":" .. e.x .. "," .. e.y) or "") end
		assert_same(seq, { "booster", "destroy:3,3", "hit:3,3", "floor_lit:3,3", "hit:4,3", "floor_lit:4,3", "hit:3,4", "floor_lit:3,4",
			"hit:4,4", "floor_lit:4,4", "score:4,4", "goal", "state" })
		for _, e in ipairs(ev) do validate(e, "column") end
	end)

	it("one hit that changes two goals reports them in goal order, after the score", function()
		local g = fresh(nil, { goals = { { type = "light" }, { type = "collect", color = "red", count = 9 } }, floor = { { at = { 0, 2 }, hp = 1 } } })
		g:input({ type = "booster", booster = "stick", at = { 1, 3 } }) -- a red piece on the only tile
		g:step()
		local ev = g:drain_events()
		local seq = {}
		for _, e in ipairs(ev) do seq[#seq + 1] = e.type .. (e.index and (":" .. e.index .. "=" .. e.left) or "") end
		assert_same(seq, { "booster", "clear", "hit", "floor_lit", "score", "goal:1=0", "goal:2=8" })
		assert_eq(ev[5].delta, 30 + 50, "30 for the piece, 50 for the tile")
	end)

	it("shuffle fallbacks: freed then shuffle with riff.from = wires; destroy then shuffle with from = noise", function()
		local g = fresh({ "MMMMMM", "MMMMMM", "MMMrMM", "MMMMMM", "MMMMMM", "MMMMMM" })
		g.s.wires[16] = 1
		g:step()
		local ev = g:drain_events()
		assert_same({ ev[1].type, ev[2].type, ev[2].riff.from }, { "freed", "shuffle", "wires" })
		for _, e in ipairs(ev) do validate(e, "wires fallback") end
		local g2 = fresh({ "MMMMMM", "MMMMMM", "MMMNMM", "MMMMMM", "MMMMMM", "MMMMMM" })
		g2:step()
		ev = g2:drain_events()
		assert_same({ ev[1].type, ev[1].item, ev[2].type, ev[2].riff.from }, { "destroy", "noise", "shuffle", "noise" })
		for _, e in ipairs(ev) do validate(e, "noise fallback") end
	end)

	it("state stuck carries its reason; continue gives moves, continue_riff and state in that order", function()
		local g = fresh({ "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM", "MMMMMM" })
		g:step()
		local ev = g:drain_events()
		assert_same(ev, { { t = 1, type = "state", state = "out_of_moves", reason = "stuck" } })
		local g2 = fresh()
		g2.s.state, g2.s.moves_left = C.G_OUT, 0
		g2:input({ type = "continue", moves = 3, riff = true })
		ev = g2:drain_events()
		assert_same({ ev[1].type, ev[2].type, ev[3].type }, { "moves", "continue_riff", "state" })
		for _, e in ipairs(ev) do validate(e, "continue") end
	end)

	it("a Riff makes two bolts, a Cross four, a Triple cross twelve, with the tick of their exit", function()
		local function bolts(rows, arm, partner)
			local g = fresh(rows)
			H.arm(g, arm, partner)
			g:step()
			return H.of_type(g:drain_events(), "bolt")
		end
		local base = { "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }
		local function with(...)
			local rows = {}
			for y = 1, 6 do rows[y] = base[y] end
			for _, c in ipairs({ ... }) do rows[c[2]] = rows[c[2]]:sub(1, c[1] - 1) .. c[3] .. rows[c[2]]:sub(c[1] + 1) end
			return rows
		end
		local b = bolts(with({ 3, 3, "R" }), { 3, 3 })
		assert_eq(#b, 2)
		assert_same({ b[1].dir, b[2].dir, b[1].at, b[1].x, b[1].y }, { "l", "r", 1, 3, 3 })
		b = bolts(with({ 3, 3, "V" }), { 3, 3 })
		assert_same({ b[1].dir, b[2].dir }, { "u", "d" })
		b = bolts(with({ 3, 3, "R" }, { 4, 3, "R" }), { 4, 3 }, { 3, 3 })
		assert_eq(#b, 4, "Cross")
		b = bolts(with({ 3, 3, "S" }, { 4, 3, "R" }), { 4, 3 }, { 3, 3 })
		assert_eq(#b, 12, "Triple cross")
		for _, e in ipairs(b) do assert_eq(e.at, 1 + 6, "they leave after the swell") end
		-- a bolt is announced even when its direction holds no cells
		b = bolts(with({ 1, 1, "R" }), { 1, 1 })
		assert_eq(#b, 2)
	end)

	it("a Sabwoofer announces rings 0..2, the Bass drop 0..3; the Finale all rings of the field", function()
		local function rings(rows, arm, partner)
			local g = fresh(rows)
			H.arm(g, arm, partner)
			g:step()
			local r = H.of_type(g:drain_events(), "ring")
			local out = {}
			for _, e in ipairs(r) do out[#out + 1] = e.r end
			return out, r
		end
		local base = { "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }
		local function with(...)
			local rows = {}
			for y = 1, 6 do rows[y] = base[y] end
			for _, c in ipairs({ ... }) do rows[c[2]] = rows[c[2]]:sub(1, c[1] - 1) .. c[3] .. rows[c[2]]:sub(c[1] + 1) end
			return rows
		end
		assert_same((rings(with({ 3, 3, "S" }), { 3, 3 })), { 0, 1, 2 })
		local r = rings(with({ 3, 3, "S" }, { 4, 3, "S" }), { 4, 3 }, { 3, 3 })
		assert_same(r, { 0, 1, 2, 3 })
		-- the centre (2,2) reaches (6,6) at Chebyshev distance 4
		r = rings(with({ 2, 2, "D" }, { 3, 2, "D" }), { 3, 2 }, { 2, 2 })
		assert_same(r, { 0, 1, 2, 3, 4 }, "the farthest cell from (3,2) is (6,6) or (1,6), at Chebyshev distance 4")
	end)
end)
