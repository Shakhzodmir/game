-- client/tutorial.lua: the parser of tutorials.json, the step machine and the guard,
-- on a fake board (inline fixtures; the authored content/tutorials.json is played in
-- tutorial_content_test.lua) and once on a real core game through client/level_link.lua.

local tutorial = require("client.tutorial")
local link = require("client.level_link")
local level_session = require("client.level_session")
local level_input = require("client.level_input")
local level_geom = require("client.level_geom")
local json = require("tools.lib.json")

local function swap(fx, fy, tx, ty, text)
	return { kind = "swap", from = { fx, fy }, to = { tx, ty }, text = text or "tutorial.swap" }
end

local function fake_env()
	local w = {
		st = "playing", stable = true, can = "ok", pieces = {}, specials = {}, hint = nil, mode = "swipe",
		targ = nil, moves = 20, ready = true,
	}
	local env = {
		state = function() return w.st end,
		stable = function() return w.stable end,
		can_swap = function() return w.can end,
		piece = function(x, y) return w.pieces[x .. "," .. y] end,
		specials = function() return w.specials end,
		hint = function() return w.hint end,
		targeting = function() return w.targ end,
		moves_left = function() return w.moves end,
		booster_ready = function() return w.ready end,
		mode = function() return w.mode end,
	}
	return env, w
end

local function special_at(w, x, y)
	w.pieces[x .. "," .. y] = { kind = "special", special = "riff", state = "idle", pinned = false }
end

local function run(t, seconds)
	for _ = 1, math.ceil((seconds or 1) * 60) do t:update(1 / 60) end
end

-- a tutorial of the given raw steps on a fake board; returns t, w (the fake board), log
local function make(raw_steps, opts)
	opts = opts or {}
	local env, w = fake_env()
	local log = { marks = {}, steps = {}, shown = {} }
	local defs = { ["7"] = { steps = raw_steps } }
	local t = tutorial.start(7, {
		defs = defs, env = env, fallback = opts.fallback,
		seen = function() return false end,
		mark = function(id) log.marks[#log.marks + 1] = id end,
		on_step = function(i, st, n) log.steps[#log.steps + 1] = i .. "/" .. n .. ":" .. st.kind end,
		on_show = function(i) log.shown[#log.shown + 1] = i end,
	})
	assert_true(t ~= nil)
	return t, w, log
end

describe("client.tutorial parsing", function()
	it("turns the 0-based cells of the file into core cells", function()
		local s = assert(tutorial.parse_step({ kind = "swap", from = { 3, 0 }, to = { 3, 1 }, text = "tutorial.swap" }))
		assert_same(s.from, { 4, 1 })
		assert_same(s.to, { 4, 2 })
		assert_eq(s.text, "tutorial.swap")
		local t = assert(tutorial.parse_step({ kind = "tap", at = { 4, 7 }, text = "tutorial.tap_special" }))
		assert_same(t.at, { 5, 8 })
		local b = assert(tutorial.parse_step({ kind = "booster", booster = "stick", at = { 0, 7 }, text = "tutorial.booster" }))
		assert_eq(b.booster, "stick")
		assert_same(b.at, { 1, 8 })
		local tip = assert(tutorial.parse_step({ kind = "tip", text = "tutorial.pre_boosters" }))
		assert_eq(tip.at, nil)
		local tip2 = assert(tutorial.parse_step({ kind = "tip", at = { 3, 6 }, text = "tutorial.record_box" }))
		assert_same(tip2.at, { 4, 7 })
		assert_true(tutorial.parse_step({ kind = "booster", booster = "remix" }) ~= nil) -- no target needed
		-- a tip that lights a button of the bar (the Crossfader's hint of level 21)
		local lit = assert(tutorial.parse_step({ kind = "tip", booster = "swap", text = "tutorial.swap_booster" }))
		assert_eq(lit.booster, "swap")
		assert_eq(lit.at, nil)
	end)

	it("refuses broken steps with a reason", function()
		local function bad(raw, part)
			local s, why = tutorial.parse_step(raw)
			assert_eq(s, nil)
			assert_true(string.find(why, part, 1, true) ~= nil, tostring(why))
		end
		bad(nil, "table")
		bad({ kind = "dance" }, "unknown kind")
		bad({ kind = "swap", from = { 1, 1 } }, "from and to")
		bad({ kind = "swap", from = { 1, 1 }, to = { 3, 1 } }, "neighbours")
		bad({ kind = "swap", from = { 1, 1 }, to = { 2, 2 } }, "neighbours")
		bad({ kind = "swap", from = { -1, 1 }, to = { 0, 1 } }, "from and to")
		bad({ kind = "swap", from = { 1.5, 1 }, to = { 2, 1 } }, "from and to")
		bad({ kind = "tap" }, "needs at")
		bad({ kind = "booster", booster = "riff" }, "unknown in-level booster")
		bad({ kind = "booster", booster = "stick" }, "needs at")
		bad({ kind = "tip", booster = "riff", text = "x" }, "booster button of the bar")
		bad({ kind = "tip", booster = 5, text = "x" }, "booster button of the bar")
	end)

	it("takes the steps of a level by its id and stops at the first broken one", function()
		local defs = {
			["1"] = { steps = { swap(3, 0, 3, 1), { kind = "tap", at = { 1, 1 } }, { kind = "tap" }, { kind = "tip" } } },
			["2"] = { steps = {} },
			["3"] = { steps = { { kind = "nope" } } },
		}
		local steps, errors = tutorial.steps(defs, 1)
		assert_eq(#steps, 2) -- the third is broken: it and the one after it are dropped
		assert_eq(#errors, 1)
		assert_eq(tutorial.steps(defs, 2), nil)
		assert_eq(tutorial.steps(defs, 4), nil)
		assert_eq(tutorial.steps(defs, 3), nil)
		assert_eq(tutorial.steps(nil, 1), nil)
		assert_eq(tutorial.steps({ [1] = defs["1"] }, 1) ~= nil, true) -- a numeric key works too
	end)

	it("reads /content/tutorials.json once and survives a missing or broken file, saying so", function()
		tutorial._reset()
		local warnings = {}
		tutorial.warn = function(text) warnings[#warnings + 1] = text end
		local reads = 0
		tutorial.read = function(path)
			reads = reads + 1
			assert_eq(path, "/content/tutorials.json")
			return json.encode({ ["1"] = { steps = { swap(3, 0, 3, 1) } } })
		end
		tutorial.decode = json.decode
		assert_true(tutorial.steps(tutorial.load(), 1) ~= nil)
		tutorial.load()
		assert_eq(reads, 1)
		assert_same(warnings, {}) -- a good file is quiet
		-- a missing file means a game without tutorials: it is logged (once, however often it is asked for)
		tutorial._reset()
		tutorial.warn = function(text) warnings[#warnings + 1] = text end
		tutorial.read = function() return nil end
		assert_same(tutorial.load(), {})
		assert_same(tutorial.load(), {})
		assert_eq(#warnings, 1)
		assert_true(string.find(warnings[1], "WARNING: tutorials: /content/tutorials.json cannot be read", 1, true) ~= nil, warnings[1])
		tutorial._reset()
		tutorial.warn = function(text) warnings[#warnings + 1] = text end
		tutorial.read = function() return "{ not json" end
		tutorial.decode = json.decode
		assert_same(tutorial.load(), {})
		assert_eq(#warnings, 2)
		assert_true(string.find(warnings[2], "is not valid JSON", 1, true) ~= nil, warnings[2])
		tutorial._reset()
	end)

	it("starts nothing for a level without steps and nothing for a tutorial already seen", function()
		local env = fake_env()
		local defs = { ["7"] = { steps = { swap(3, 0, 3, 1) } } }
		assert_eq(tutorial.start(8, { defs = defs, env = env }), nil)
		assert_eq(tutorial.start(7, { defs = defs, env = env, seen = function(id) return id == "level_7" end }), nil)
		assert_true(tutorial.start(7, { defs = defs, env = env, seen = function() return false end }) ~= nil)
		assert_eq(tutorial.id(41), "level_41")
	end)
end)

describe("client.tutorial steps", function()
	it("waits for the board to bloom, then shows the first step", function()
		local t, w, log = make({ swap(3, 0, 3, 1), swap(1, 4, 0, 4) })
		assert_eq(t:view(), nil)
		run(t, tutorial.START_DELAY - 0.1)
		assert_eq(t:view(), nil)
		-- the board is busy: the step waits for rest
		w.stable = false
		run(t, 0.5)
		assert_eq(t:view(), nil)
		w.stable = true
		run(t, 0.1)
		local v = t:view()
		assert_eq(v.index, 1)
		assert_eq(v.count, 2)
		assert_eq(v.kind, "swap")
		assert_eq(v.text, "tutorial.swap")
		assert_same(v.cells, { { 4, 1 }, { 4, 2 } })
		assert_eq(v.hand.mode, "swipe")
		assert_same(v.hand.points, { { 4, 1 }, { 4, 2 } })
		assert_same(log.shown, { 1 })
	end)

	it("lets only the guided swap through, in either direction, and nothing before the step", function()
		local t = make({ swap(3, 0, 3, 1) })
		-- before the step: everything is turned away
		assert_false(t:allow_command({ type = "swap", from = { 4, 1 }, to = { 4, 2 } }))
		assert_false(t:allow_cell(4, 1))
		run(t, 1)
		assert_true(t:allow_cell(4, 1))
		assert_true(t:allow_cell(4, 2))
		assert_false(t:allow_cell(5, 1))
		assert_true(t:allow_command({ type = "swap", from = { 4, 1 }, to = { 4, 2 } }))
		assert_true(t:allow_command({ type = "swap", from = { 4, 2 }, to = { 4, 1 } }))
		assert_false(t:allow_command({ type = "swap", from = { 4, 1 }, to = { 5, 1 } }))
		assert_false(t:allow_command({ type = "tap", at = { 4, 1 } }))
		assert_false(t:allow_command({ type = "booster", booster = "stick", at = { 4, 1 } }))
		assert_false(t:allow_booster("stick"))
		assert_true(t.blocked >= 5)
	end)

	it("replaces the hint by the guided move and hides it between steps", function()
		local t = make({ swap(3, 0, 3, 1), { kind = "tap", at = { 3, 1 } } })
		assert_eq(t:hint({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }), nil) -- not yet
		run(t, 1)
		local h = t:hint({ type = "swap", from = { 1, 1 }, to = { 2, 1 } })
		assert_same(h, { type = "swap", from = { 4, 1 }, to = { 4, 2 } })
		assert_true(t:allow_command(h))
		t:sent(h, true, "ok")
		assert_eq(t:hint({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }), nil) -- settling
	end)

	it("takes a step as done when the core accepts the guided move, then goes on when the board rests", function()
		local t, w, log = make({ swap(3, 0, 3, 1), { kind = "tap", at = { 4, 7 }, text = "tutorial.tap_special" } })
		run(t, 1)
		local cmd = { type = "swap", from = { 4, 1 }, to = { 4, 2 } }
		-- a swap the core calls a failed one, a refusal and another move do not count
		t:sent(cmd, true, "fail")
		t:sent(cmd, false, "bad_cell")
		t:sent({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }, true, "ok")
		assert_eq(t:view().index, 1)
		t:sent(cmd, true, "ok")
		assert_eq(t:view(), nil)
		assert_same(log.steps, { "1/2:swap" })
		-- the cascade is running: the next step waits
		w.stable = false
		run(t, 1)
		assert_eq(t:view(), nil)
		w.stable = true
		special_at(w, 5, 8)
		run(t, 1)
		local v = t:view()
		assert_eq(v.index, 2)
		assert_eq(v.kind, "tap")
		assert_same(v.cells, { { 5, 8 } })
		assert_true(t:allow_cell(5, 8))
		assert_false(t:allow_cell(4, 8))
		assert_true(t:allow_command({ type = "tap", at = { 5, 8 } }))
		assert_false(t:allow_command({ type = "swap", from = { 5, 8 }, to = { 5, 7 } })) -- not a tap
		t:sent({ type = "tap", at = { 5, 8 } }, true, "ok")
		assert_false(t:finished())
		run(t, 0.2)
		assert_true(t:finished())
		assert_eq(t.reason, "completed")
		assert_same(log.marks, { "level_7" })
		assert_same(log.steps, { "1/2:swap", "2/2:tap" })
		-- free play: everything passes, the hint is the board's own
		assert_true(t:allow_cell(1, 1))
		assert_true(t:allow_command({ type = "swap", from = { 1, 1 }, to = { 2, 1 } }))
		assert_true(t:allow_booster("stick"))
		local own = { type = "swap", from = { 1, 1 }, to = { 2, 1 } }
		assert_eq(t:hint(own), own)
	end)

	it("shows the hand for tap-tap input: tap the piece, tap its neighbour", function()
		local t, w = make({ swap(3, 0, 3, 1), { kind = "tap", at = { 4, 7 } } })
		w.mode = "taptap"
		special_at(w, 5, 8)
		run(t, 1)
		assert_eq(t:view().hand.mode, "taps")
		assert_same(t:view().hand.points, { { 4, 1 }, { 4, 2 } })
		t:sent({ type = "swap", from = { 4, 1 }, to = { 4, 2 } }, true, "ok")
		run(t, 1)
		local v = t:view()
		assert_eq(v.hand.mode, "taps")
		assert_same(v.hand.points, { { 5, 8 }, { 5, 8 } }) -- select, then tap again to launch
		w.mode = "swipe"
		assert_same(t:view().hand.points, { { 5, 8 } }) -- follows the setting
	end)

	it("runs a booster step in two parts: the button, then the target", function()
		local t, w = make({ { kind = "booster", booster = "stick", at = { 0, 7 }, text = "tutorial.booster" } })
		w.pieces["1,8"] = { kind = "regular", state = "idle" }
		run(t, 1)
		local v = t:view()
		assert_eq(v.kind, "booster")
		assert_eq(v.sub, "pick")
		assert_eq(v.button, "stick")
		assert_same(v.cells, {})
		assert_eq(v.hand, nil)
		assert_false(t:allow_cell(1, 8)) -- no target before the booster is picked
		assert_false(t:allow_booster("row_light"))
		assert_true(t:allow_booster("stick"))
		w.targ = "stick"
		run(t, 0.1)
		v = t:view()
		assert_eq(v.sub, "target")
		assert_eq(v.button, nil)
		assert_same(v.cells, { { 1, 8 } })
		assert_same(v.hand.points, { { 1, 8 } })
		assert_true(t:allow_cell(1, 8))
		assert_false(t:allow_cell(2, 8))
		assert_false(t:allow_command({ type = "booster", booster = "stick", at = { 2, 8 } }))
		assert_false(t:allow_command({ type = "booster", booster = "row_light", row = 8 }))
		local cmd = { type = "booster", booster = "stick", at = { 1, 8 } }
		assert_true(t:allow_command(cmd))
		t:sent(cmd, true, "ok")
		w.targ = nil
		run(t, 1)
		assert_true(t:finished())
		assert_eq(t.reason, "completed")
	end)

	it("aims a row or column spotlight at any cell of the line, and remix needs no target", function()
		local t, w = make({ { kind = "booster", booster = "row_light", at = { 2, 3 } } })
		w.pieces["3,4"] = { kind = "regular", state = "idle" }
		run(t, 1)
		w.targ = "row_light"
		run(t, 0.1)
		assert_true(t:allow_cell(7, 4))
		assert_false(t:allow_cell(3, 5))
		assert_true(t:allow_command({ type = "booster", booster = "row_light", row = 4 }))
		assert_false(t:allow_command({ type = "booster", booster = "row_light", row = 5 }))
		local t2 = make({ { kind = "booster", booster = "remix" } })
		run(t2, 1)
		assert_eq(t2:view().button, "remix")
		assert_true(t2:allow_command({ type = "booster", booster = "remix" }))
		t2:sent({ type = "booster", booster = "remix" }, true, nil)
		run(t2, 0.2)
		assert_true(t2:finished())
	end)

	it("dismisses a tip with a tap, not at once, and a press on the board counts as that tap", function()
		local t, w, log = make({ { kind = "tip", at = { 3, 6 }, text = "tutorial.record_box" }, swap(5, 7, 4, 7) })
		run(t, 1)
		local v = t:view()
		assert_eq(v.kind, "tip")
		assert_eq(v.dismiss, "tap")
		assert_same(v.cells, { { 4, 7 } })
		assert_eq(v.hand.mode, "point")
		-- the first moments: a stray tap does nothing
		assert_false(t:tap())
		run(t, tutorial.TIP_GUARD)
		assert_false(t:allow_command({ type = "swap", from = { 1, 1 }, to = { 2, 1 } })) -- a tip lets no move through
		assert_false(t:allow_cell(1, 1)) -- the press is the tap that dismisses it
		assert_same(log.steps, { "1/2:tip" })
		assert_eq(t:view(), nil)
		run(t, 1)
		assert_eq(t:view().kind, "swap")
		-- a tip without a place: no spotlight, no hand
		local t2 = make({ { kind = "tip", text = "tutorial.pre_boosters" } })
		run(t2, 1)
		assert_same(t2:view().cells, {})
		assert_eq(t2:view().hand, nil)
		run(t2, 0.5)
		assert_true(t2:tap())
		assert_true(t2:finished())
		assert_eq(t2.reason, "completed")
	end)

	it("lights a booster button with a tip: no cells, the button, a tapping hand; a tap on the button reads it", function()
		local t, w, log = make({ { kind = "tip", booster = "swap", text = "tutorial.swap_booster" } })
		run(t, 1)
		local v = t:view()
		assert_eq(v.kind, "tip")
		assert_eq(v.button, "swap", "the HUD lights this button")
		assert_same(v.cells, {})
		assert_eq(v.dismiss, "tap")
		-- another button is not what the tip asks for
		assert_false(t:allow_booster("stick"))
		assert_eq(t:view().button, "swap")
		-- the button it lights: let through, the tip is done at once, the lesson is remembered
		assert_true(t:allow_booster("swap"))
		assert_true(t:finished())
		assert_eq(t.reason, "completed")
		assert_same(log.marks, { "level_7" })
		assert_same(log.steps, { "1/1:tip" })
		assert_true(t:allow_booster("stick"), "after the lesson everything is allowed")
		-- a tap anywhere else dismisses it as any tip, and the button is then free too
		local t2 = make({ { kind = "tip", booster = "swap", text = "tutorial.swap_booster" } })
		run(t2, 1.5)
		assert_true(t2:tap())
		assert_true(t2:finished())
		assert_true(t2:allow_booster("swap"))
	end)

	it("can be skipped, and is then remembered like a finished one", function()
		local t, _, log = make({ swap(3, 0, 3, 1), swap(1, 4, 0, 4) })
		run(t, 1)
		t:skip()
		assert_true(t:finished())
		assert_eq(t.reason, "skipped")
		assert_same(log.marks, { "level_7" })
		t:skip()
		assert_eq(#log.marks, 1) -- once
		assert_true(t:allow_cell(1, 1))
	end)

	it("counts what the guard turns away and the view changes", function()
		local t = make({ swap(3, 0, 3, 1) })
		run(t, 1)
		local rev = t:view().rev
		local b = t.blocked
		t:allow_cell(7, 7)
		t:allow_command({ type = "tap", at = { 1, 1 } })
		assert_eq(t.blocked, b + 2)
		t:sent({ type = "swap", from = { 4, 1 }, to = { 4, 2 } }, true, "ok")
		assert_true(t.rev > rev)
	end)
end)

describe("client.tutorial fail-safes", function()
	it("uses the core's hint when the drawn swap is not possible on this board", function()
		local t, w = make({ swap(3, 0, 3, 1) })
		w.can = "reject"
		w.hint = { from = { 2, 2 }, to = { 3, 2 } }
		run(t, 1)
		local v = t:view()
		assert_same(v.cells, { { 2, 2 }, { 3, 2 } })
		assert_eq(t.fallbacks, 1)
		assert_true(t:allow_command({ type = "swap", from = { 3, 2 }, to = { 2, 2 } }))
		assert_false(t:allow_command({ type = "swap", from = { 4, 1 }, to = { 4, 2 } }))
	end)

	it("ends and remembers a tutorial whose swap is impossible and has no fallback", function()
		local t, w, log = make({ swap(3, 0, 3, 1) })
		w.can = "fail"
		w.hint = nil
		run(t, 1)
		assert_true(t:finished())
		assert_eq(t.reason, "abandoned")
		assert_same(log.marks, { "level_7" }) -- not shown again and again
		assert_true(t:allow_cell(1, 1)) -- the player is free
		local t2, w2 = make({ swap(3, 0, 3, 1) }, { fallback = false })
		w2.can = "fail"
		w2.hint = { from = { 2, 2 }, to = { 3, 2 } }
		run(t2, 1)
		assert_eq(t2.reason, "abandoned")
	end)

	it("retargets a tap step to the one special on the board, else gives up", function()
		local t, w = make({ { kind = "tap", at = { 4, 7 } } })
		w.specials = { { 6, 3 } }
		run(t, 1)
		assert_same(t:view().cells, { { 6, 3 } })
		local t2, w2 = make({ { kind = "tap", at = { 4, 7 } } })
		w2.specials = { { 6, 3 }, { 2, 2 } }
		run(t2, 1)
		assert_eq(t2.reason, "abandoned")
		local t3, w3 = make({ { kind = "tap", at = { 4, 7 } } })
		w3.pieces["5,8"] = { kind = "special", state = "armed", pinned = false } -- already fired
		run(t3, 1)
		assert_eq(t3.reason, "abandoned")
	end)

	it("gives up a booster step the player cannot take", function()
		local t, w = make({ { kind = "booster", booster = "stick", at = { 0, 7 } } })
		w.ready = false
		w.pieces["1,8"] = { kind = "regular", state = "idle" }
		run(t, 1)
		assert_eq(t.reason, "abandoned")
		local t2 = make({ { kind = "booster", booster = "stick", at = { 0, 7 } } })
		run(t2, 1) -- nothing on the target cell
		assert_eq(t2.reason, "abandoned")
	end)

	it("notices a move made behind the guard's back", function()
		local t, w = make({ swap(3, 0, 3, 1), swap(1, 4, 0, 4) })
		run(t, 1)
		w.moves = 19 -- autoplay or a debug command moved
		w.can = "fail"
		w.hint = nil
		run(t, 0.1)
		assert_eq(t.reason, "abandoned")
		-- a move that leaves the step possible keeps it
		local t2, w2 = make({ swap(3, 0, 3, 1) })
		run(t2, 1)
		w2.moves = 19
		run(t2, 0.1)
		assert_false(t2:finished())
		assert_eq(t2:view().index, 1)
	end)

	it("ends with the level: a win counts as seen, running out of moves does not", function()
		local t, w, log = make({ swap(3, 0, 3, 1), swap(1, 4, 0, 4) })
		run(t, 1)
		w.st = "won_wait"
		run(t, 0.1)
		assert_eq(t.reason, "ended")
		assert_same(log.marks, { "level_7" })
		local t2, w2, log2 = make({ swap(3, 0, 3, 1) })
		run(t2, 1)
		w2.st = "out_of_moves"
		run(t2, 0.1)
		assert_eq(t2.reason, "ended")
		assert_same(log2.marks, {})
		assert_true(t2:allow_cell(1, 1))
	end)

	it("does nothing before there is a board", function()
		local t, w = make({ swap(3, 0, 3, 1) })
		w.st = nil
		run(t, 2)
		assert_false(t:finished())
		assert_eq(t:view(), nil)
		w.st = "playing"
		run(t, 1)
		assert_eq(t:view().kind, "swap")
	end)
end)

-- the tutorial on a real core game, through the link the board and the HUD use ----------------------

local LEVEL = [[{
  "id": 3, "version": 1, "size": [6, 6], "moves": 12, "difficulty": "easy",
  "colors": ["red", "yellow", "green", "blue"],
  "goals": [{"type": "collect", "color": "red", "count": 99}],
  "cells": ["######", "######", "######", "######", "######", "######"],
  "slots": [
    {"at": [0,0], "type": "piece", "color": "yellow"}, {"at": [1,0], "type": "piece", "color": "blue"},
    {"at": [2,0], "type": "piece", "color": "yellow"}, {"at": [3,0], "type": "piece", "color": "green"},
    {"at": [4,0], "type": "piece", "color": "blue"}, {"at": [5,0], "type": "piece", "color": "yellow"},
    {"at": [0,1], "type": "piece", "color": "blue"}, {"at": [1,1], "type": "piece", "color": "green"},
    {"at": [2,1], "type": "piece", "color": "red"}, {"at": [3,1], "type": "piece", "color": "yellow"},
    {"at": [4,1], "type": "piece", "color": "green"}, {"at": [5,1], "type": "piece", "color": "blue"},
    {"at": [0,2], "type": "piece", "color": "green"}, {"at": [1,2], "type": "piece", "color": "red"},
    {"at": [2,2], "type": "piece", "color": "green"}, {"at": [3,2], "type": "piece", "color": "red"},
    {"at": [4,2], "type": "piece", "color": "red"}, {"at": [5,2], "type": "piece", "color": "green"},
    {"at": [0,3], "type": "piece", "color": "yellow"}, {"at": [1,3], "type": "piece", "color": "blue"},
    {"at": [2,3], "type": "piece", "color": "blue"}, {"at": [3,3], "type": "piece", "color": "green"},
    {"at": [4,3], "type": "piece", "color": "yellow"}, {"at": [5,3], "type": "piece", "color": "blue"},
    {"at": [0,4], "type": "piece", "color": "red"}, {"at": [1,4], "type": "piece", "color": "yellow"},
    {"at": [2,4], "type": "piece", "color": "red"}, {"at": [3,4], "type": "piece", "color": "blue"},
    {"at": [4,4], "type": "piece", "color": "red"}, {"at": [5,4], "type": "piece", "color": "green"},
    {"at": [0,5], "type": "piece", "color": "blue"}, {"at": [1,5], "type": "piece", "color": "green"},
    {"at": [2,5], "type": "piece", "color": "yellow"}, {"at": [3,5], "type": "piece", "color": "red"},
    {"at": [4,5], "type": "piece", "color": "green"}, {"at": [5,5], "type": "piece", "color": "yellow"}
  ]
}]]

describe("client.tutorial on a real board", function()
	it("guides the first move through client/level_link.lua and lets the cascade settle", function()
		local s = assert(level_session.new({ params = { level = 3, level_text = LEVEL } }))
		local board = {
			session = s, input = level_input.new(),
			geom = level_geom.new(6, 6, s.game:cells(), { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 }),
		}
		link.attach(board)
		-- the first guided move: whatever the core says is a good swap (so the fixture does not
		-- depend on the colours above), written the way the file writes it (0-based)
		local h = s.game:hint()
		assert_true(h ~= nil and h.from ~= nil)
		local steps = {
			{ kind = "swap", from = { h.from[1] - 1, h.from[2] - 1 }, to = { h.to[1] - 1, h.to[2] - 1 }, text = "tutorial.swap" },
		}
		local marked = {}
		local t = tutorial.start(3, {
			defs = { ["3"] = { steps = steps } },
			seen = function() return false end,
			mark = function(id) marked[#marked + 1] = id end,
			env = {
				state = function() return (link.status() or {}).state end,
				stable = link.stable, can_swap = link.can_swap, piece = link.piece, specials = link.specials,
				hint = link.core_hint, targeting = link.targeting,
				moves_left = function() return (link.status() or {}).moves_left end,
			},
		})
		link.set_guard(t:guard())
		local function frames(n)
			for _ = 1, n do
				s:advance(1 / 60)
				t:update(1 / 60)
			end
		end
		-- the board's side of it: ask, send, tell
		local function board_send(cmd)
			if not link.allow_command(cmd) then return false end
			local ok, res = s:command(cmd)
			link.sent(cmd, ok, res)
			return ok, res
		end
		assert_false(link.allow_cell(h.from[1], h.from[2])) -- the first step is not up yet
		frames(60)
		assert_eq(t:view().kind, "swap")
		assert_true(link.allow_cell(h.from[1], h.from[2]))
		assert_same(link.hint(s:hint_command()), { type = "swap", from = h.from, to = h.to })
		-- some other swap does not get through
		local other = { type = "swap", from = { 1, 1 }, to = { 2, 1 } }
		if not (h.from[1] == 1 and h.from[2] == 1) then assert_false(board_send(other)) end
		assert_true(board_send({ type = "swap", from = h.to, to = h.from }))
		assert_eq(s.game:status().moves_left, 11)
		frames(600)
		assert_true(t:finished())
		assert_eq(t.reason, "completed")
		assert_same(marked, { "level_3" })
		assert_true(link.allow_cell(1, 1))
		link.clear_guard()
		link.detach(board)
	end)
end)
