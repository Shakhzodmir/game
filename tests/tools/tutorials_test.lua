-- The authored tutorials (content/tutorials.json, the one file the game reads) against the level files,
-- with the core API only: no engine, no client screens. client/tutorial.lua plays the same file on the
-- fake board (tests/client/tutorial_content_test.lua); this file asks the questions of the content
-- author instead:
--   * the file is well formed (keys, kinds, cells, texts in en and ru) and the runtime parser takes it;
--   * the plan is met (levels-plan.md, sections 2 and 4): the tutorial levels and every level that brings
--     a new element have a lesson, the first guided move of each lesson sits on explicit pieces (so it
--     does not depend on the seed) and does what its text promises;
--   * every step is possible when its turn comes: a swap is a legal swap that makes a match or a special
--     (game:can_swap, and the move is not refunded), a tap targets a special that stands there then
--     (made by the step before, or already on the board), a booster is accepted, every cell is on the
--     board; the later steps are played on SEEDS different seeds because the refill is random;
--   * the effect named by the text of a step really happens (a Riff appears, a box cracks, a noise goes,
--     a microphone is delivered, ...), and a tip points at the thing it speaks about.
-- A failure names the level, the step and the seed. Fix the lesson, not the board.

local core = require("core.game")
local C = require("core.const")
local json = require("tools.lib.json")
local i18n = require("client.i18n")
local tutorial = require("client.tutorial")
local config = require("meta.config")

local PATH = "content/tutorials.json"
local SEEDS = 24        -- seeds 1..SEEDS for the steps played after a move
local MAX_TEXT = 64     -- characters of a step text: the bubble of the level screen holds three lines
local MAX_LEVELS = 100

-- levels-plan.md, section 2: the levels that always have a lesson, and the level that brings each element.
local PLAN_LESSONS = { 1, 2, 4, 6, 8, 9, 11, 12 }
local PLAN_ELEMENTS = {
	record_box = 10, dancefloor = 15, wires = 22, mic = 30, concrete = 40, noise = 50, balloon = 65, column = 90,
}
-- the special the first swap of these levels must make (2: 4 in a line, 4: L/T, 6: 2x2, 9: 5 in a line)
local PLAN_SPECIAL = { [2] = "riff", [4] = "sub", [6] = "bird", [9] = "disco" }

local ALLOWED = {
	swap = { kind = true, from = true, to = true, text = true },
	tap = { kind = true, at = true, text = true },
	booster = { kind = true, booster = true, at = true, text = true },
	tip = { kind = true, at = true, booster = true, text = true },
}
local MOVABLE = { piece = true, riff = true, sub = true, bird = true, disco = true, mic = true }
local SPECIAL_SLOT = { riff = true, sub = true, bird = true, disco = true }
-- the special a text promises to make
local MAKES = {
	["tutorial.riff"] = "riff", ["tutorial.sub"] = "sub", ["tutorial.bird"] = "bird", ["tutorial.disco"] = "disco",
}

-- files and levels ---------------------------------------------------------------------------------------

local function read(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function authored()
	local text = read(PATH)
	assert_true(text ~= nil, PATH .. " is missing: the game would ship without tutorials")
	local defs = json.decode(text)
	assert_eq(type(defs), "table", PATH .. " must be an object")
	return defs
end

-- the level numbers of the lessons, sorted (a key that is not a number is reported by the form test)
local function ids_of(defs)
	local ids = {}
	for k in pairs(defs) do
		local n = tonumber(k)
		if n and n == math.floor(n) and tostring(k):match("^[1-9]%d*$") then ids[#ids + 1] = n end
	end
	table.sort(ids)
	return ids
end

local function key(x, y)
	return x .. "," .. y
end

local function raw_of(n)
	local text = read(string.format("content/levels/level_%04d.json", n))
	if not text then return nil end
	return json.decode(text), text
end

-- Everything the tests need to know about a level without playing it: the decoded file, the level the core
-- loaded, and the explicit content by cell (slots, floor tiles, wires), 0-based like the file.
local levels = {}

local function level_of(n)
	if levels[n] then return levels[n] end
	local raw, text = raw_of(n)
	if not raw then return nil end
	local level, errs = core.load_level(text)
	assert_true(level ~= nil, "level " .. n .. " does not load: " .. table.concat(errs or {}, "; "))
	local info = { n = n, raw = raw, level = level, W = raw.size[1], H = raw.size[2], slot = {}, floor = {}, wires = {} }
	for _, s in ipairs(raw.slots or {}) do
		if s.type == "column" then -- 2x2 from the top-left cell
			for dx = 0, 1 do
				for dy = 0, 1 do info.slot[key(s.at[1] + dx, s.at[2] + dy)] = s end
			end
		else
			info.slot[key(s.at[1], s.at[2])] = s
		end
	end
	for _, t in ipairs(raw.floor or {}) do info.floor[key(t.at[1], t.at[2])] = t.hp end
	for _, t in ipairs(raw.overlay or {}) do info.wires[key(t.at[1], t.at[2])] = t.hp end
	for k, g in ipairs(raw.goals) do
		if g.type == "deliver" then info.deliver_goal = k end
	end
	levels[n] = info
	return info
end

local function on_board(info, x, y)
	if x < 0 or y < 0 or x >= info.W or y >= info.H then return false end
	return info.raw.cells[y + 1]:sub(x + 1, x + 1) == "#"
end

-- a stand: the bottom of a segment of the column ("exits": "bottom") or a cell of the list
local function is_stand(info, x, y)
	if not on_board(info, x, y) then return false end
	local exits = info.raw.exits
	if type(exits) == "table" then
		for _, e in ipairs(exits) do
			if e[1] == x and e[2] == y then return true end
		end
		return false
	end
	return not on_board(info, x, y + 1)
end

-- The elements of rule 2.1.6 that a level has (a goal brings its element too).
local function elements_of(raw)
	local kinds = {}
	for _, s in ipairs(raw.slots or {}) do
		if PLAN_ELEMENTS[s.type] then kinds[s.type] = true end
	end
	if raw.floor and #raw.floor > 0 then kinds.dancefloor = true end
	if raw.overlay and #raw.overlay > 0 then kinds.wires = true end
	if raw.mic then kinds.mic = true end
	for _, g in ipairs(raw.goals) do
		if g.type == "light" then kinds.dancefloor = true end
		if g.type == "deliver" then kinds.mic = true end
	end
	return kinds
end

-- element id -> the first level of 1..100 that has it
local function first_levels()
	local first = {}
	for n = 1, MAX_LEVELS do
		local raw = raw_of(n)
		if raw then
			for k in pairs(elements_of(raw)) do
				if not first[k] then first[k] = n end
			end
		end
	end
	return first
end

local function chars(s)
	local n = 0
	for _ in string.gmatch(s, "[^\128-\191]") do n = n + 1 end
	return n
end

-- steps in the form of the file ---------------------------------------------------------------------------

local function is_count(v)
	return type(v) == "number" and v >= 0 and v == math.floor(v)
end

local function is_cell(v)
	if type(v) ~= "table" or #v ~= 2 or not is_count(v[1]) or not is_count(v[2]) then return false end
	local n = 0
	for _ in pairs(v) do n = n + 1 end
	return n == 2
end

local function cell_text(c)
	return "[" .. c[1] .. ", " .. c[2] .. "]"
end

-- 1-based {x, y} of a 0-based file cell (the core's)
local function core_cell(c)
	return { c[1] + 1, c[2] + 1 }
end

-- the 0-based cells a step names, in a list
local function cells_of(step)
	local out = {}
	if step.from then out[#out + 1] = step.from end
	if step.to then out[#out + 1] = step.to end
	if step.at then out[#out + 1] = step.at end
	return out
end

-- A list of problems of the form of one step (empty: well formed).
local function form_problems(step)
	local out = {}
	if type(step) ~= "table" then return { "a step must be an object" } end
	local allowed = ALLOWED[step.kind]
	if not allowed then return { "unknown kind " .. tostring(step.kind) } end
	for k in pairs(step) do
		if not allowed[k] then out[#out + 1] = "'" .. tostring(k) .. "' does not belong to a " .. step.kind .. " step" end
	end
	if step.kind == "swap" then
		if not is_cell(step.from) or not is_cell(step.to) then out[#out + 1] = "a swap step needs from and to as [x, y]" end
	elseif step.kind == "tap" then
		if not is_cell(step.at) then out[#out + 1] = "a tap step needs at as [x, y]" end
	elseif step.kind == "booster" then
		if type(step.booster) ~= "string" then out[#out + 1] = "a booster step needs the booster id" end
		if step.at ~= nil and not is_cell(step.at) then out[#out + 1] = "at must be [x, y]" end
		if (step.booster == "stick" or step.booster == "row_light" or step.booster == "col_light") and not is_cell(step.at) then
			out[#out + 1] = step.booster .. " needs a target in at"
		end
	else -- a tip: a cell, or a button of the bar (the booster to light), or neither
		if step.at ~= nil and not is_cell(step.at) then out[#out + 1] = "at must be [x, y]" end
		if step.booster ~= nil and type(step.booster) ~= "string" then out[#out + 1] = "booster must be the booster id" end
		if step.booster ~= nil and step.at ~= nil then out[#out + 1] = "a tip lights a cell or a button, not both" end
	end
	if type(step.text) ~= "string" or step.text == "" then out[#out + 1] = "every step has a text (an i18n key)" end
	return out
end

-- the steps of the lesson of level n (a failure with its name when there is none)
local function steps_of(defs, n)
	local entry = defs[tostring(n)]
	assert_true(type(entry) == "table" and type(entry.steps) == "table", "level " .. n .. " has no lesson")
	return entry.steps
end

-- the first guided step (swap, tap or booster) of a lesson and its index; nil for a lesson of tips
local function first_move(steps)
	for i, st in ipairs(steps) do
		if st.kind ~= "tip" then return st, i end
	end
	return nil
end

-- the start board by its explicit pieces --------------------------------------------------------------------

-- colour of the explicit piece by cell (0-based); everything else (random cells, specials, blockers) has none
local function colours(info)
	local col = {}
	for k, s in pairs(info.slot) do
		if s.type == "piece" then col[k] = s.color end
	end
	return col
end

-- 3 in a line or a 2x2 square of one colour through (x, y) in the colour map
local function matches_at(col, x, y)
	local c = col[key(x, y)]
	if not c then return false end
	local function same(dx, dy)
		return col[key(x + dx, y + dy)] == c
	end
	-- run of the colour along a line through (x, y): both ways from the cell
	local function run(dx, dy)
		local n, d = 1, 1
		while same(-d * dx, -d * dy) do
			n, d = n + 1, d + 1
		end
		d = 1
		while same(d * dx, d * dy) do
			n, d = n + 1, d + 1
		end
		return n
	end
	if run(1, 0) >= 3 or run(0, 1) >= 3 then return true end
	for sx = -1, 0 do
		for sy = -1, 0 do
			if same(sx, sy) and same(sx + 1, sy) and same(sx, sy + 1) and same(sx + 1, sy + 1) then return true end
		end
	end
	return false
end

-- Why the first guided move of a lesson does not work on the explicit pieces alone (so it would depend on the
-- seed); nil if it is fine.
local function static_problem(info, step)
	if step.kind == "swap" then
		local a, b = info.slot[key(step.from[1], step.from[2])], info.slot[key(step.to[1], step.to[2])]
		if not a or not MOVABLE[a.type] then return "the cell " .. cell_text(step.from) .. " is not an explicit piece" end
		if not b or not MOVABLE[b.type] then return "the cell " .. cell_text(step.to) .. " is not an explicit piece" end
		if SPECIAL_SLOT[a.type] or SPECIAL_SLOT[b.type] then
			return nil -- a special always makes the swap legal
		end
		if info.wires[key(step.from[1], step.from[2])] or info.wires[key(step.to[1], step.to[2])] then
			return "a wired piece cannot be swapped"
		end
		if a.type == "piece" and b.type == "piece" then
			local col = colours(info)
			local ka, kb = key(step.from[1], step.from[2]), key(step.to[1], step.to[2])
			col[ka], col[kb] = col[kb], col[ka]
			if not (matches_at(col, step.from[1], step.from[2]) or matches_at(col, step.to[1], step.to[2])) then
				return "the swap makes no match from explicit pieces alone: it depends on the random cells"
			end
		end
	elseif step.kind == "tap" then
		local s = info.slot[key(step.at[1], step.at[2])]
		if not s or not SPECIAL_SLOT[s.type] then
			return "the cell " .. cell_text(step.at) .. " is not an explicit special at the start"
		end
	elseif step.kind == "booster" and step.booster == "stick" then
		if not info.slot[key(step.at[1], step.at[2])] then
			return "the stick targets " .. cell_text(step.at) .. ", which is a random cell"
		end
	end
	return nil
end

-- tips: the thing a tip speaks about must be where it points. Read from the file, that is the board at the
-- start: boxes, tiles, wires, concrete, noise, balloons, columns and stands stay where they are until a match
-- hits them, and the only thing that moves, the microphone, is pointed at by the first step of its lesson.
-- ------------------------------------------------------------------------------------------------------------

local function slot_of(info, step, ...)
	local s = info.slot[key(step.at[1], step.at[2])]
	if not s then return false end
	for _, t in ipairs({ ... }) do
		if s.type == t then return s end
	end
	return false
end

local TIPS = {
	["tutorial.record_box"] = function(info, st) return slot_of(info, st, "record_box") ~= false or "no record box there" end,
	["tutorial.record_box_layers"] = function(info, st)
		local s = slot_of(info, st, "record_box")
		return (s and s.hp >= 2) or "no record box with 2 or more layers there"
	end,
	["tutorial.dancefloor"] = function(info, st) return info.floor[key(st.at[1], st.at[2])] ~= nil or "no floor tile there" end,
	["tutorial.dancefloor_double"] = function(info, st) return info.floor[key(st.at[1], st.at[2])] == 2 or "no double floor tile there" end,
	["tutorial.wires"] = function(info, st) return info.wires[key(st.at[1], st.at[2])] ~= nil or "no wires there" end,
	["tutorial.mic"] = function(info, st) return slot_of(info, st, "mic") ~= false or "no microphone there" end,
	["tutorial.mic_stand"] = function(info, st) return is_stand(info, st.at[1], st.at[2]) or "not a stand" end,
	["tutorial.concrete"] = function(info, st) return slot_of(info, st, "concrete") ~= false or "no concrete there" end,
	["tutorial.noise"] = function(info, st) return slot_of(info, st, "noise") ~= false or "no noise there" end,
	["tutorial.balloon"] = function(info, st) return slot_of(info, st, "balloon") ~= false or "no balloon there" end,
	["tutorial.column"] = function(info, st) return slot_of(info, st, "column") ~= false or "no speaker column there" end,
}

-- playing the steps ---------------------------------------------------------------------------------------------

local function piece_at(game, x, y)
	local list = game:pieces()
	for i = 1, #list do
		local p = list[i]
		if p.x == x and p.y == y then return p end
	end
	return nil
end

-- What the effects of a step are measured on: layers of the blockers, tiles, wires, specials, goals, moves.
local function snap(game, info)
	local t = { box_hp = 0, concrete_hp = 0, noise = 0, balloon = 0, column_hp = 0, wires = 0, floor_hp = 0,
		specials = {}, goals = {} }
	local list = game:pieces()
	for i = 1, #list do
		local p = list[i]
		if p.kind == "blocker" then
			if p.item == "record_box" then t.box_hp = t.box_hp + p.hp
			elseif p.item == "concrete" then t.concrete_hp = t.concrete_hp + p.hp
			elseif p.item == "noise" then t.noise = t.noise + 1
			elseif p.item == "balloon" then t.balloon = t.balloon + 1
			elseif p.item == "column" then t.column_hp = t.column_hp + p.hp end
		elseif p.kind == "special" then
			t.specials[p.special] = (t.specials[p.special] or 0) + 1
		end
	end
	local cells = game:cells()
	for i = 1, #cells do
		t.wires = t.wires + (cells[i].wires or 0)
		t.floor_hp = t.floor_hp + (cells[i].floor or 0)
	end
	t.cells = cells
	local st = game:status()
	t.goals, t.moves, t.state = st.goals, st.moves_left, st.state
	return t
end

-- The effect a text promises, measured between two snapshots: true when kept, else why not.
local EFFECTS = {
	["tutorial.record_box_match"] = function(a, b) return b.box_hp < a.box_hp or "no record box was hit" end,
	["tutorial.dancefloor_match"] = function(a, b) return b.floor_hp < a.floor_hp or "no floor tile was lit" end,
	["tutorial.wires_match"] = function(a, b) return b.wires < a.wires or "no wires were cut" end,
	["tutorial.noise_match"] = function(a, b) return b.noise < a.noise or "no noise went" end,
	["tutorial.balloon_match"] = function(a, b) return b.balloon < a.balloon or "no balloon popped" end,
	["tutorial.column_match"] = function(a, b) return b.column_hp < a.column_hp or "the speaker column lost no dust" end,
	["tutorial.concrete_riff"] = function(a, b) return b.concrete_hp < a.concrete_hp or "the Riff did not hit the concrete" end,
	["tutorial.mic_drop"] = function(a, b, info)
		local k = info.deliver_goal
		return (k and b.goals[k] < a.goals[k]) or "no microphone was delivered"
	end,
}

-- Plays the lesson `steps` (the form of the file, 0-based) of level `info` from `seed` the way the guard allows
-- it, step after step; returns the list of problems (strings with the step in front).
local function play(info, steps, seed)
	local out = {}
	local game = assert(core.new(info.level, { seed = seed }))
	game:run_to_rest()
	local start = snap(game, info)
	local made -- the special the step before has made, for the tap that follows
	local function bad(i, why)
		out[#out + 1] = string.format("level %d step %d (%s) seed %d: %s", info.n, i, steps[i].text, seed, why)
	end
	for i, st in ipairs(steps) do
		local before = snap(game, info)
		local made_now = nil
		if st.kind == "swap" then
			local from, to = core_cell(st.from), core_cell(st.to)
			local pa, pb = piece_at(game, from[1], from[2]), piece_at(game, to[1], to[2])
			local answer = game:can_swap(from, to)
			if answer ~= "ok" then
				local why = answer == "fail" and "makes no match" or "is not allowed (a wired, blocked or empty cell, or a special armed)"
				bad(i, "game:can_swap says '" .. answer .. "': the swap " .. cell_text(st.from) .. " -> " .. cell_text(st.to) .. " " .. why)
				return out
			end
			local ok, res = game:input({ type = "swap", from = from, to = to })
			if not ok then
				bad(i, "the core refused the swap: " .. tostring(res))
				return out
			end
			game:run_to_rest()
			local after = snap(game, info)
			if after.moves ~= before.moves - 1 then
				bad(i, "the swap was given back (no match came of it)")
			end
			if st.text == "tutorial.combo" and not (pa and pb and pa.kind == "special" and pb.kind == "special") then
				bad(i, "a combo needs a special in both cells")
			end
			if st.text == "tutorial.disco_swap"
				and not ((pa and pa.special == "disco") or (pb and pb.special == "disco")) then
				bad(i, "no Disco ball in the swap")
			end
			if st.text == "tutorial.wires_free" then
				if (start.cells[(from[2] - 1) * info.W + from[1]].wires or 0) == 0 then
					bad(i, "the piece was never wired")
				end
			end
			local kind = MAKES[st.text]
			if kind then
				if (after.specials[kind] or 0) <= (before.specials[kind] or 0) then bad(i, "no " .. kind .. " came of the swap") end
				made_now = kind
			end
			local effect = EFFECTS[st.text]
			if effect then
				local r = effect(before, after, info)
				if r ~= true then bad(i, r) end
			end
		elseif st.kind == "tap" then
			local at = core_cell(st.at)
			local p = piece_at(game, at[1], at[2])
			if not (p and p.kind == "special" and p.state == "idle" and not p.pinned) then
				bad(i, "there is no special to tap at " .. cell_text(st.at) .. " (" .. (p and (p.kind .. "/" .. tostring(p.special) .. "/" .. p.state) or "empty") .. ")")
				return out
			end
			if made and p.special ~= made then bad(i, "the special there is a " .. tostring(p.special) .. ", the step before made a " .. made) end
			local ok, res = game:input({ type = "tap", at = at })
			if not ok then
				bad(i, "the core refused the tap: " .. tostring(res))
				return out
			end
			game:run_to_rest()
			local after = snap(game, info)
			if after.moves ~= before.moves - 1 then bad(i, "the tap did not cost a move") end
			local effect = EFFECTS[st.text]
			if effect then
				local r = effect(before, after, info)
				if r ~= true then bad(i, r) end
			end
		elseif st.kind == "booster" then
			local cmd = { type = "booster", booster = st.booster }
			if st.booster == "stick" then cmd.at = core_cell(st.at)
			elseif st.booster == "row_light" then cmd.row = st.at[2] + 1
			elseif st.booster == "col_light" then cmd.col = st.at[1] + 1 end
			local ok, res = game:input(cmd)
			if not ok then
				bad(i, "the core refused the " .. st.booster .. ": " .. tostring(res))
				return out
			end
			game:run_to_rest()
			local after = snap(game, info)
			if after.moves ~= before.moves then bad(i, "a booster must not cost a move") end
		end
		made = made_now
		local st_now = game:status()
		if st.kind ~= "tip" and st_now.state ~= "playing" then
			bad(i, "the level is over (" .. st_now.state .. ") before the lesson is")
			return out
		end
	end
	return out
end

local function first_n(list, n)
	local out = {}
	for i = 1, math.min(n, #list) do out[i] = list[i] end
	if #list > n then out[#out + 1] = "... and " .. (#list - n) .. " more" end
	return out
end

-- tests ------------------------------------------------------------------------------------------------------

describe("tutorials: the file", function()
	it("is an object of lessons by level number, each a list of well formed steps", function()
		local defs = authored()
		local ids = ids_of(defs)
		assert_true(#ids > 0, "no lessons")
		local problems = {}
		for k, entry in pairs(defs) do
			if not tostring(k):match("^[1-9]%d*$") then problems[#problems + 1] = "'" .. k .. "' is not a level number" end
			if type(entry) ~= "table" or type(entry.steps) ~= "table" or #entry.steps == 0 then
				problems[#problems + 1] = "level " .. k .. ": needs {\"steps\": [...]} with at least one step"
			else
				for key_, _ in pairs(entry) do
					if key_ ~= "steps" then problems[#problems + 1] = "level " .. k .. ": '" .. tostring(key_) .. "' does not belong to a lesson" end
				end
				for i, st in ipairs(entry.steps) do
					for _, why in ipairs(form_problems(st)) do
						problems[#problems + 1] = "level " .. k .. " step " .. i .. ": " .. why
					end
				end
			end
		end
		table.sort(problems)
		assert_true(#problems == 0, table.concat(first_n(problems, 12), "\n"))
	end)

	it("has a level file for every lesson, and every cell of a step is on that board", function()
		local defs = authored()
		local problems = {}
		for _, n in ipairs(ids_of(defs)) do
			local info = level_of(n)
			if not info or n < 1 or n > MAX_LEVELS then
				problems[#problems + 1] = "level " .. n .. " has a lesson but no level file"
			else
				for i, st in ipairs(defs[tostring(n)].steps) do
					for _, c in ipairs(cells_of(st)) do
						if is_cell(c) and not on_board(info, c[1], c[2]) then
							problems[#problems + 1] = "level " .. n .. " step " .. i .. ": " .. cell_text(c) .. " is not a cell of the board"
						end
					end
				end
			end
		end
		assert_true(#problems == 0, table.concat(first_n(problems, 12), "\n"))
	end)

	it("is taken by the runtime parser without a complaint", function()
		local defs = authored()
		for _, n in ipairs(ids_of(defs)) do
			local steps, errors = tutorial.steps(defs, n)
			assert_true(steps ~= nil, "level " .. n .. ": " .. table.concat(errors or {}, "; "))
			assert_eq(#(errors or {}), 0, "level " .. n .. ": " .. table.concat(errors or {}, "; "))
			assert_eq(#steps, #defs[tostring(n)].steps, "level " .. n .. ": steps lost by the parser")
		end
	end)

	it("keeps every text in both languages, short enough for the bubble", function()
		local defs = authored()
		local problems = {}
		for _, n in ipairs(ids_of(defs)) do
			for i, st in ipairs(defs[tostring(n)].steps) do
				local text = st.text
				local where = "level " .. n .. " step " .. i .. ": " .. tostring(text)
				if type(text) ~= "string" or not text:match("^tutorial%.") then
					problems[#problems + 1] = where .. " is not a tutorial.* key"
				else
					local entry = i18n.STRINGS[text]
					if not entry then
						problems[#problems + 1] = where .. " has no entry in client/i18n.lua"
					else
						for _, lang in ipairs({ "en", "ru" }) do
							local s = entry[lang]
							if type(s) ~= "string" or s == "" then
								problems[#problems + 1] = where .. " has no " .. lang .. " text"
							elseif chars(s) > MAX_TEXT then
								problems[#problems + 1] = where .. " (" .. lang .. ") is " .. chars(s) .. " characters, the bubble takes " .. MAX_TEXT
							end
						end
					end
				end
			end
		end
		assert_true(#problems == 0, table.concat(first_n(problems, 12), "\n"))
	end)

	it("names only boosters of the core that the player has on that level, and puts the pre-level tip where they start", function()
		local defs = authored()
		local unlock, first_pre = {}, nil
		for _, b in ipairs(config.boosters) do
			unlock[b.id] = b
			if b.kind == "pre" and (not first_pre or b.unlock < first_pre) then first_pre = b.unlock end
		end
		local problems = {}
		for _, n in ipairs(ids_of(defs)) do
			for i, st in ipairs(defs[tostring(n)].steps) do
				local where = "level " .. n .. " step " .. i
				if st.kind == "booster" or (st.kind == "tip" and st.booster ~= nil) then
					if not C.BOOSTER[st.booster] then
						problems[#problems + 1] = where .. ": '" .. tostring(st.booster) .. "' is not a booster of the core (stick, row_light, col_light, remix, swap)"
					elseif not unlock[st.booster] or unlock[st.booster].kind ~= "in" then
						problems[#problems + 1] = where .. ": the meta has no in-level booster '" .. st.booster .. "'"
					elseif unlock[st.booster].unlock > n then
						problems[#problems + 1] = where .. ": the " .. st.booster .. " opens only at level " .. unlock[st.booster].unlock
					elseif (unlock[st.booster].gift or 0) < 1 then
						problems[#problems + 1] = where .. ": the player gets no " .. st.booster .. " to try it with"
					end
				end
				if st.text == "tutorial.pre_boosters" and n ~= first_pre then
					problems[#problems + 1] = where .. ": the pre-level boosters open at level " .. tostring(first_pre) .. ", the tip belongs there"
				end
			end
		end
		assert_true(#problems == 0, table.concat(first_n(problems, 12), "\n"))
	end)
end)

describe("tutorials: the plan", function()
	it("has a lesson on the levels the plan names and on the level of every new element", function()
		local defs = authored()
		local first = first_levels()
		for _, n in ipairs(PLAN_LESSONS) do
			assert_true(defs[tostring(n)] ~= nil, "level " .. n .. " (levels-plan.md, section 2) has no lesson")
		end
		for element, n in pairs(PLAN_ELEMENTS) do
			assert_eq(first[element], n, element .. " must first appear on level " .. n .. " (levels-plan.md, section 2)")
			assert_true(defs[tostring(n)] ~= nil, "level " .. n .. " brings " .. element .. " and has no lesson")
		end
	end)

	it("teaches level 1 with three guided swaps, level 8 with the drumstick, level 12 with a tip, level 11 with a combo", function()
		local defs = authored()
		local function kinds(n)
			local out = {}
			for i, st in ipairs(steps_of(defs, n)) do out[i] = st.kind end
			return out
		end
		assert_same(kinds(1), { "swap", "swap", "swap" })
		assert_same(kinds(8), { "booster" })
		assert_eq(steps_of(defs, 8)[1].booster, "stick")
		assert_same(kinds(12), { "tip" })
		assert_eq(steps_of(defs, 12)[1].at, nil, "the pre-level tip points at no cell")
		assert_eq(steps_of(defs, 11)[1].text, "tutorial.combo")
	end)

	it("shows the Crossfader on the level where the meta opens it: one tip that lights its button", function()
		local defs = authored()
		local at
		for _, b in ipairs(config.boosters) do
			if b.id == "swap" then at = b.unlock end
		end
		assert_eq(at, 21, "the Crossfader opens at level 21")
		local steps = steps_of(defs, at)
		assert_eq(#steps, 1)
		assert_eq(steps[1].kind, "tip")
		assert_eq(steps[1].booster, "swap", "it lights the button of the bar")
		assert_eq(steps[1].at, nil, "and no cell of the board")
		assert_eq(steps[1].text, "tutorial.swap_booster")
		-- no other lesson is moved by it: the 18 lessons that were there are still there
		for _, n in ipairs({ 1, 2, 4, 6, 8, 9, 10, 11, 12, 13, 15, 16, 22, 30, 40, 50, 65, 90 }) do
			assert_true(defs[tostring(n)] ~= nil, "level " .. n .. " still has its lesson")
		end
		assert_eq(#ids_of(defs), 19)
	end)

	it("makes the special of the plan with the first swap of levels 2, 4, 6 and 9, and taps it on 2, 4 and 6", function()
		local defs = authored()
		for n, special in pairs(PLAN_SPECIAL) do
			local st = first_move(steps_of(defs, n))
			assert_true(st ~= nil and st.kind == "swap", "level " .. n .. ": the lesson starts with a swap")
			assert_eq(MAKES[st.text], special, "level " .. n .. ": the first swap must teach the " .. special)
		end
		for _, n in ipairs({ 2, 4, 6 }) do
			local steps = steps_of(defs, n)
			assert_true(steps[2] ~= nil and steps[2].kind == "tap", "level " .. n .. ": the special is launched by a tap")
			local at = steps[2].at
			assert_true((at[1] == steps[1].from[1] and at[2] == steps[1].from[2]) or (at[1] == steps[1].to[1] and at[2] == steps[1].to[2]),
				"level " .. n .. ": the tap is on a cell of the swap that made the special")
		end
	end)
end)

describe("tutorials: the boards", function()
	it("starts every lesson that moves on explicit pieces, so the first move does not depend on the seed", function()
		local defs = authored()
		local problems = {}
		for _, n in ipairs(ids_of(defs)) do
			local info = level_of(n)
			local st, i = first_move(defs[tostring(n)].steps)
			if info and st then
				local why = static_problem(info, st)
				if why then problems[#problems + 1] = "level " .. n .. " step " .. i .. " (" .. st.text .. "): " .. why end
			end
		end
		assert_true(#problems == 0, table.concat(first_n(problems, 12), "\n"))
	end)

	it("points each tip at the thing the text speaks about", function()
		local defs = authored()
		local problems = {}
		for _, n in ipairs(ids_of(defs)) do
			local info = level_of(n)
			for i, st in ipairs(defs[tostring(n)].steps) do
				if st.kind == "tip" and info then
					local check = TIPS[st.text]
					if check then
						if not st.at then
							problems[#problems + 1] = "level " .. n .. " step " .. i .. " (" .. st.text .. "): the tip must point at a cell"
						else
							local why = check(info, st)
							if why ~= true then
								problems[#problems + 1] = "level " .. n .. " step " .. i .. " (" .. st.text .. ") at " .. cell_text(st.at) .. ": " .. why
							end
						end
					end
				end
			end
		end
		assert_true(#problems == 0, table.concat(first_n(problems, 12), "\n"))
	end)

	it("can be played step by step on " .. SEEDS .. " seeds: legal swaps that match, specials to tap, the effect of the text", function()
		local defs = authored()
		local problems = {}
		for _, n in ipairs(ids_of(defs)) do
			local info = level_of(n)
			if info then
				local found = 0
				for seed = 1, SEEDS do
					for _, why in ipairs(play(info, defs[tostring(n)].steps, seed)) do
						if found < 2 then problems[#problems + 1] = why end -- two seeds per level are enough to see the cause
						found = found + 1
					end
				end
				if found > 2 then problems[#problems + 1] = "level " .. n .. ": " .. found .. " problems over " .. SEEDS .. " seeds in all" end
			end
		end
		assert_true(#problems == 0, table.concat(first_n(problems, 16), "\n"))
	end)
end)
