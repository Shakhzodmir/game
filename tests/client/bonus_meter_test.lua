-- The bonus meter (client/bonus_meter.lua), its hook in the level session and its place in the HUD layout.

local bonus_meter = require("client.bonus_meter")
local level_session = require("client.level_session")
local level_hud = require("client.level_hud")
local layout = require("client.layout")

local function act(id, special, extra)
	local e = { type = "activate", id = id, special = special, x = 3, y = 4 }
	for k, v in pairs(extra or {}) do e[k] = v end
	return e
end

describe("client.bonus_meter points", function()
	it("gives 1 for a Bird and a Riff, 2 for a Sabwoofer, 3 for a Disco ball", function()
		assert_eq(bonus_meter.points_of(act(1, "bird")), 1)
		assert_eq(bonus_meter.points_of(act(1, "riff")), 1)
		assert_eq(bonus_meter.points_of(act(1, "sub")), 2)
		assert_eq(bonus_meter.points_of(act(1, "disco")), 3)
	end)

	it("counts a combo as both of its specials, and nothing for a cargo special without an id", function()
		assert_eq(bonus_meter.points_of(act(1, "riff", { combo = "cross" })), 2)
		assert_eq(bonus_meter.points_of(act(1, "sub", { combo = "bass_drop" })), 4)
		assert_eq(bonus_meter.points_of(act(1, "disco", { combo = "finale" })), 6)
		assert_eq(bonus_meter.points_of(act(nil, "riff")), 0)
		assert_eq(bonus_meter.points_of({ type = "activate", special = "laser", id = 5 }), 0)
		for name in pairs(bonus_meter.COMBO) do
			assert_true(bonus_meter.points_of(act(1, "riff", { combo = name })) >= 2, name)
		end
	end)
end)

describe("client.bonus_meter bar", function()
	it("adds up, counts each special once, and ignores everything but `activate`", function()
		local m = bonus_meter.new({ seed = 5, level_id = 10 })
		local adds = m:feed({ act(1, "sub"), act(1, "sub"), { type = "match" }, act(2, "bird") })
		assert_eq(#adds, 2)
		assert_eq(adds[1].total, 2)
		assert_eq(adds[2].total, 3)
		assert_eq(m.points, 3)
		assert_eq(m.earned, 3)
		assert_eq(m:feed({ { type = "swap" } }), nil)
	end)

	it("makes a gift at 10, carries the rest over and queues a second one for a long chain", function()
		local m = bonus_meter.new({ seed = 5, level_id = 10 })
		local adds = m:feed({ act(1, "disco"), act(2, "disco"), act(3, "disco"), act(4, "bird") }) -- 3+3+3 = 9, +1 = 10
		assert_true(adds[4].fill)
		assert_eq(m.points, 0)
		assert_eq(m.made, 1)
		assert_eq(#m.queue, 1)
		assert_true(bonus_meter.POINTS[m:gift()] ~= nil)
		local more = m:feed({ act(5, "disco"), act(6, "disco"), act(7, "disco"), act(8, "disco") }) -- 12: gift, 2 left
		assert_true(more[4].fill)
		assert_eq(m.points, 2)
		assert_eq(#m.queue, 2)
		m:given()
		assert_eq(#m.queue, 1)
	end)

	it("is off on the first levels and counts nothing there", function()
		assert_false(bonus_meter.enabled_for(1))
		assert_false(bonus_meter.enabled_for(2))
		assert_true(bonus_meter.enabled_for(bonus_meter.MIN_LEVEL))
		local m = bonus_meter.new({ seed = 1, level_id = 2 })
		assert_eq(m:feed({ act(1, "disco") }), nil)
		assert_eq(m.points, 0)
	end)

	it("picks the same gift for the same seed and number, only among specials the player has met", function()
		for n = 1, 8 do
			assert_eq(bonus_meter.pick(77, n, 12), bonus_meter.pick(77, n, 12))
		end
		for seed = 1, 40 do
			assert_eq(bonus_meter.pick(seed, 1, 3), "riff") -- level 3: only the Riff is known
			local g = bonus_meter.pick(seed, 2, 5)
			assert_true(g == "riff" or g == "sub", g)
		end
		local seen = {}
		for seed = 1, 200 do seen[bonus_meter.pick(seed, 1, 20)] = true end
		for _, g in ipairs(bonus_meter.GIFTS) do assert_true(seen[g], "never picked: " .. g) end
	end)
end)

describe("client.level_session with the bonus meter", function()
	local LEVEL = [[{
	  "id": 12, "version": 1, "size": [6, 6], "moves": 12, "difficulty": "easy",
	  "colors": ["red", "yellow", "green", "blue"],
	  "goals": [{"type": "collect", "color": "red", "count": 10}],
	  "cells": ["######", "######", "######", "######", "######", "######"]
	}]]

	local function session()
		local s = assert(level_session.new({ params = { level_id = 12, level_text = LEVEL } }))
		return s
	end

	local function specials(s)
		local n = 0
		for _, p in ipairs(s.game:pieces()) do
			if p.kind == "special" then n = n + 1 end
		end
		return n
	end

	it("hands the additions to the tick callback and puts the gift on the board at the first rest", function()
		local s = session()
		for _ = 1, 600 do
			s:advance(1 / 60)
			if s.game:is_stable() then break end
		end
		local before = specials(s)
		assert_true(s:qa("meter", { "12", "bird" }).ok) -- 12 points: a gift, 2 left
		assert_eq(s.meter:snapshot().waiting, 1)
		local seen, added = false, 0
		for _ = 1, 120 do
			s:advance(1 / 60, function(evs, _, adds)
				for _, a in ipairs(adds or {}) do added = added + a.n end
				for _, e in ipairs(evs) do if e.type == "bonus" then seen = true end end
			end)
		end
		assert_eq(added, 12)
		assert_true(seen, "the core put the gift on the board (event bonus)")
		assert_eq(s.meter:snapshot().waiting, 0)
		assert_eq(s.meter.points, 2)
		assert_eq(specials(s), before + 1)
		assert_true(s:snapshot().meter.enabled)
	end)

	it("waits while a window is open and for a board that has not settled, and asks again", function()
		local s = session()
		s:qa("meter", { "10", "bird" })
		s:set_paused(true)
		for _ = 1, 30 do s:advance(1 / 60) end
		assert_eq(s.meter:snapshot().waiting, 1)
		s:set_paused(false)
		for _ = 1, 900 do
			s:advance(1 / 60)
			if s.meter:snapshot().waiting == 0 then break end
		end
		assert_eq(s.meter:snapshot().waiting, 0)
	end)

	it("keeps the QA command honest about its arguments", function()
		local s = session()
		assert_false(s:qa("meter", { "3", "laser" }).ok)
		local r = s:qa("meter", { "0" })
		assert_true(r.ok)
		assert_eq(s.meter.earned, 1) -- at least one point
	end)
end)

describe("client.level_hud: the bonus bar in the layout", function()
	local windows = { { 720, 1280 }, { 540, 960 }, { 1170, 2532 }, { 828, 1792 }, { 1920, 1080 }, { 1536, 2048 }, { 600, 1024 } }

	it("stands between the booster bar and the board and never touches either, on every window and board", function()
		for _, win in ipairs(windows) do
			local fit = layout.fit(win[1], win[2])
			local area = layout.play_area(fit, {})
			for W = 6, 9 do
				for H = 6, 11 do
					local b = layout.board(W, H, area)
					local board = { x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1, cell = b.cell }
					local l = level_hud.layout(fit, nil, board)
					local tag = W .. "x" .. H .. " in " .. win[1] .. "x" .. win[2]
					assert_true(l.meter.y0 >= l.bar.y1, tag)
					assert_true(l.meter.y1 <= board.y0, tag)
					assert_false(level_hud.overlaps(l.meter, l.bar), tag)
					assert_false(level_hud.overlaps(l.meter, board), tag)
					local s = l.slot
					local r = { x0 = s.x - s.size / 2, y0 = s.y - s.size / 2, x1 = s.x + s.size / 2, y1 = s.y + s.size / 2 }
					assert_false(level_hud.overlaps(r, l.meter), "Bit on the bar: " .. tag)
					assert_true(l.meter.x0 >= l.safe.x0 and l.meter.x1 <= l.safe.x1, tag)
				end
			end
		end
	end)

	it("describes the bar's look: the fill, the tremble at 8 and 9 of 10, the label", function()
		local a, b, c = level_hud.meter_state(0, 10), level_hud.meter_state(8, 10), level_hud.meter_state(10, 10)
		assert_eq(a.frac, 0)
		assert_false(a.tense)
		assert_true(b.tense)
		assert_eq(b.label, "8/10")
		assert_true(c.full)
		assert_false(c.tense)
		assert_eq(level_hud.meter_state(99, 10).frac, 1)
		assert_true(level_hud.meter_color(0.1) ~= level_hud.meter_color(0.95))
	end)
end)
