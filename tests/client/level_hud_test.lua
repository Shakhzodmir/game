-- client/level_hud.lua: the HUD geometry on every kind of window (phone, tall phone, notch,
-- wide desktop, tablet), where Bit stands, the booster buttons, the goal counters, the
-- moves badge and the score feed.

local layout = require("client.layout")
local hud = require("client.level_hud")

-- the board rectangle the board script would build for a W x H level in a window
local function board_in(W, H, ww, wh, insets)
	local fit = layout.fit(ww, wh)
	local b = layout.board(W, H, layout.play_area(fit, { insets = insets }))
	return fit, { x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1, cell = b.cell }
end

local function overlap(a, b)
	return a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1
end

local function slot_rect(s)
	return { x0 = s.x - s.size / 2, x1 = s.x + s.size / 2, y0 = s.y - s.size / 2, y1 = s.y + s.size / 2 }
end

local function inside(r, safe)
	return r.x0 >= safe.x0 - 0.5 and r.x1 <= safe.x1 + 0.5 and r.y0 >= safe.y0 - 0.5 and r.y1 <= safe.y1 + 0.5
end

describe("client.level_hud layout", function()
	it("hangs the top row from the top and stands the bar on the bottom of the design window", function()
		local fit, board = board_in(9, 9, 720, 1280)
		local l = hud.layout(fit, nil, board)
		assert_eq(l.top_shift, 0)
		assert_eq(l.bottom_shift, 0)
		assert_eq(l.pause.cy, 1170)
		assert_eq(l.goals.cy, 1170)
		assert_eq(l.moves.cy, 1170)
		assert_eq(l.bar.cy, 70)
		assert_eq(l.bar.y1, 136)
		-- the three top elements do not overlap
		assert_false(overlap(l.pause, l.goals))
		assert_false(overlap(l.goals, l.moves))
		-- all of it is inside the window
		for _, r in ipairs({ l.pause, l.goals, l.moves, l.bar }) do assert_true(inside(r, l.safe)) end
		-- the board sits between the top row and the bar
		assert_true(board.y1 <= l.goals.y0)
		assert_true(board.y0 >= l.bar.y1)
	end)

	it("puts Bit under the board, above the bar, in front of its frame at most, never over the cells or the bar", function()
		local fit, board = board_in(9, 9, 720, 1280)
		local l = hud.layout(fit, nil, board)
		local s = l.slot
		assert_eq(s.where, "bottom")
		assert_true(s.tappable)
		assert_true(s.size >= hud.BIT_MIN and s.size <= hud.BIT_MAX)
		local r = slot_rect(s)
		assert_false(overlap(r, board))
		assert_false(overlap(r, l.bar))
		assert_true(inside(r, l.safe))
	end)

	it("follows the top and bottom edges of a tall phone and keeps the board where it is", function()
		local fit, board = board_in(9, 9, 1170, 2532)
		local l = hud.layout(fit, nil, board)
		assert_true(l.top_shift > 100)
		assert_true(l.bottom_shift < -100)
		assert_near(l.goals.cy, 1170 + l.top_shift, 1e-9)
		assert_near(l.bar.cy, 70 + l.bottom_shift, 1e-9)
		for _, r in ipairs({ l.pause, l.goals, l.moves, l.bar }) do assert_true(inside(r, l.safe)) end
		assert_true(board.y1 < l.goals.y0 and board.y0 > l.bar.y1)
		local r = slot_rect(l.slot)
		assert_false(overlap(r, board))
		assert_false(overlap(r, l.bar))
		assert_true(l.slot.tappable)
		assert_true(inside(r, l.safe))
	end)

	it("keeps the top row below a notch and the bar above a home indicator", function()
		local fit = layout.fit(1170, 2532)
		local insets = { inset_top = 132, inset_bottom = 102, inset_left = 0, inset_right = 0 }
		local _, board = board_in(9, 9, 1170, 2532, insets)
		local with = hud.layout(fit, insets, board)
		local without = hud.layout(fit, nil, board)
		assert_true(with.goals.cy < without.goals.cy - 70) -- 132 px / 1.625
		assert_true(with.bar.cy > without.bar.cy + 50)
		assert_true(with.goals.y1 <= with.safe.y1 + 1e-9)
		assert_true(with.bar.y0 >= with.safe.y0 - 1e-9)
		assert_true(with.safe.y1 >= 1280 and with.safe.y0 <= 0) -- never smaller than the design window
	end)

	it("stands Bit beside the board on a wide window, outside the design column", function()
		local fit, board = board_in(9, 9, 1920, 1080)
		local l = hud.layout(fit, nil, board)
		local s = l.slot
		assert_eq(s.where, "left")
		assert_eq(s.size, hud.BIT_MAX)
		assert_true(s.x < 0) -- in the room the design window does not have
		local r = slot_rect(s)
		assert_false(overlap(r, board))
		assert_true(inside(r, l.safe))
		assert_true(s.y - s.size / 2 >= l.bar.y1)
	end)

	it("uses the side room of a tablet and of a narrow board", function()
		local fit, board = board_in(9, 9, 1536, 2048)
		local l = hud.layout(fit, nil, board)
		assert_eq(l.slot.where, "left")
		assert_true(inside(slot_rect(l.slot), l.safe))
		assert_false(overlap(slot_rect(l.slot), board))
		-- a 6x11 board on a phone leaves 135 px on each side
		local fit2, b2 = board_in(6, 11, 720, 1280)
		local l2 = hud.layout(fit2, nil, b2)
		assert_true(l2.slot.where == "left" or l2.slot.where == "right")
		assert_false(overlap(slot_rect(l2.slot), b2))
		assert_true(l2.slot.size >= hud.BIT_MIN)
	end)

	it("squeezes Bit into the corner when nothing is free, and then he is not tappable", function()
		local fit, board = board_in(7, 11, 720, 1280)
		local l = hud.layout(fit, nil, board)
		assert_eq(l.slot.where, "corner")
		assert_false(l.slot.tappable)
		assert_true(l.slot.size >= hud.BIT_TINY)
		assert_false(overlap(slot_rect(l.slot), l.bar))
		-- the cells themselves stay free
		assert_false(overlap(slot_rect(l.slot), board))
	end)

	it("never lets Bit cover the cells, whatever the board and the window", function()
		local windows = { { 720, 1280 }, { 540, 960 }, { 1170, 2532 }, { 828, 1792 }, { 1920, 1080 }, { 1536, 2048 },
			{ 2560, 1440 }, { 600, 1024 } }
		for _, win in ipairs(windows) do
			for W = 6, 9 do
				for H = 6, 11 do
					local fit, board = board_in(W, H, win[1], win[2])
					local l = hud.layout(fit, nil, board)
					assert_false(overlap(slot_rect(l.slot), board), W .. "x" .. H .. " in " .. win[1] .. "x" .. win[2])
					assert_false(overlap(slot_rect(l.slot), l.bar), W .. "x" .. H .. " in " .. win[1] .. "x" .. win[2])
					assert_true(l.slot.size >= hud.BIT_TINY)
				end
			end
		end
	end)

	it("has a place for Bit before the board exists", function()
		local l = hud.layout(layout.fit(720, 1280), nil, nil)
		assert_true(l.slot.size > 0)
		assert_eq(l.board, nil)
	end)

	it("spreads one, two or three goals over the panel", function()
		local one = hud.goal_slots(1)
		assert_same(one.xs, { 0 })
		assert_eq(one.icon, 84)
		local two = hud.goal_slots(2)
		assert_near(two.xs[1], -105, 1e-9)
		assert_near(two.xs[2], 105, 1e-9)
		local three = hud.goal_slots(3)
		assert_eq(#three.xs, 3)
		assert_near(three.xs[2], 0, 1e-9)
		assert_true(three.icon < one.icon) -- three goals are a little smaller
		assert_eq(#hud.goal_slots(5).xs, 3) -- at most three
		assert_eq(#hud.goal_slots(0).xs, 1)
		assert_eq(#hud.bar_slots(), 4)
		assert_eq(hud.bar_slots()[1], -250)
	end)
end)

describe("client.level_hud boosters", function()
	it("tells how a booster button looks", function()
		local locked = hud.booster_state({ unlocked = false, unlock_level = 14, count = 0 })
		assert_eq(locked.mode, "locked")
		assert_true(locked.lock and locked.dim)
		assert_eq(locked.unlock_level, 14)
		local empty = hud.booster_state({ unlocked = true, count = 0 })
		assert_eq(empty.mode, "empty")
		assert_true(empty.plus)
		assert_false(empty.badge)
		local ready = hud.booster_state({ unlocked = true, count = 3 })
		assert_eq(ready.mode, "ready")
		assert_true(ready.badge)
		assert_eq(ready.count, 3)
		local free = hud.booster_state({ unlocked = true, count = nil }) -- a debug level: free boosters
		assert_eq(free.mode, "ready")
		assert_false(free.badge)
	end)

	it("decides what a tap on a booster does", function()
		local ready = hud.booster_state({ unlocked = true, count = 2 })
		local empty = hud.booster_state({ unlocked = true, count = 0 })
		local locked = hud.booster_state({ unlocked = false })
		assert_eq(hud.booster_tap("stick", ready, { state = "playing" }), "start")
		assert_eq(hud.booster_tap("stick", ready, { state = "out_of_moves" }), "start")
		assert_eq(hud.booster_tap("stick", ready, { state = "concert" }), "wait")
		assert_eq(hud.booster_tap("stick", ready, { state = "won_wait" }), "wait")
		assert_eq(hud.booster_tap("stick", ready, { state = "playing", targeting = "stick" }), "cancel")
		assert_eq(hud.booster_tap("row_light", ready, { state = "playing", targeting = "stick" }), "start") -- switches
		assert_eq(hud.booster_tap("stick", empty, { state = "playing" }), "buy")
		assert_eq(hud.booster_tap("stick", locked, { state = "playing" }), "locked")
		assert_eq(hud.booster_tap("stick", ready, { state = "playing", allowed = false }), "blocked") -- the tutorial
		assert_eq(hud.booster_tap("stick", empty, { state = "playing", allowed = false }), "blocked")
		assert_eq(hud.booster_tap("stick", ready), "start")
		assert_eq(hud.PROMPT.stick, "hud.pick_cell")
		assert_eq(hud.PROMPT.row_light, "hud.pick_row")
		assert_eq(hud.PROMPT.col_light, "hud.pick_col")
	end)
end)

describe("client.level_hud goals and moves", function()
	it("counts a goal down as its flyers land, never up", function()
		local g = hud.goals_new({ 30, 5 })
		assert_eq(g.shown[1], 30)
		-- the board says 29: a flyer goes
		assert_eq(g:event(1, 29, true), "fly")
		assert_eq(g.shown[1], 30) -- not yet
		assert_eq(g:event(1, 28, true), "fly")
		assert_true(g:land(1, 29))
		assert_eq(g.shown[1], 29)
		-- a late flyer with an older number cannot put the counter back
		assert_false(g:land(1, 29))
		assert_true(g:land(1, 28))
		assert_eq(g.flying[1], 0)
		-- no position to fly from: shown at once
		local what, changed = g:event(2, 4, false)
		assert_eq(what, "set")
		assert_true(changed)
		assert_eq(g.shown[2], 4)
		assert_false(g:set(2, 9))
		assert_eq(g.shown[2], 4)
		assert_false(g:done(2))
		g:event(2, 0, false)
		assert_true(g:done(2))
		assert_false(g:all_done())
		g:set(1, 0)
		assert_true(g:all_done())
		local w2, c2 = g:event(7, 1, true) -- an unknown goal is ignored
		assert_eq(w2, "set")
		assert_false(c2)
	end)

	it("sets the counter at once when too many flyers are on their way", function()
		local g = hud.goals_new({ 100 })
		local flights = 0
		for i = 1, hud.MAX_FLYING + 4 do
			if g:event(1, 100 - i, true) == "fly" then flights = flights + 1 end
		end
		assert_eq(flights, hud.MAX_FLYING)
		assert_eq(g.shown[1], 100 - (hud.MAX_FLYING + 4)) -- the overflow was shown at once
	end)

	it("measures the progress of a goal", function()
		local g = hud.goals_new({ 40, 0 })
		assert_eq(g:progress(1), 0)
		g:set(1, 10)
		assert_near(g:progress(1), 0.75, 1e-9)
		assert_eq(g:progress(2), 1)
		assert_eq(g:progress(9), 1)
	end)

	it("pulses the moves badge at five moves and fewer", function()
		assert_false(hud.moves_state(20).low)
		assert_false(hud.moves_state(6).low)
		assert_true(hud.moves_state(5).low)
		assert_true(hud.moves_state(1).low)
		assert_false(hud.moves_state(0).low) -- out of moves: the window speaks
		assert_true(hud.moves_state(2).danger)
		assert_false(hud.moves_state(3).danger)
		assert_false(hud.moves_state(nil).low)
	end)

	it("merges the score events of one burst into one pop at their centre", function()
		local f = hud.score_feed()
		assert_eq(f:update(0.1), nil) -- nothing yet
		f:add(20, 100, 200)
		f:add(20, 200, 200)
		f:add(60, 300, 400)
		assert_eq(f:update(0.05), nil)
		local p = f:update(0.1)
		assert_eq(p.delta, 100)
		assert_near(p.x, (100 * 20 + 200 * 20 + 300 * 60) / 100, 1e-9)
		assert_near(p.y, (200 * 20 + 200 * 20 + 400 * 60) / 100, 1e-9)
		assert_eq(p.size, 2)
		assert_eq(f:update(1), nil) -- reset
		f:add(400, 10, 10)
		assert_eq(f:update(0.2).size, 3)
		f:add(20, 10, 10)
		assert_eq(f:update(0.2).size, 1)
		f:add(0, 1, 1)
		f:add(-5, 1, 1)
		assert_eq(f:update(1), nil)
		f:add(50, nil, nil) -- a score without a place: no pop, nothing left behind
		assert_eq(f:update(1), nil)
		f:add(20, 5, 5)
		assert_eq(f:update(0.2).delta, 20)
	end)
end)

describe("client.level_hud tutorial helpers", function()
	local vis = { x0 = 0, y0 = 0, x1 = 720, y1 = 1280 }

	local function area(r) return (r.x1 - r.x0) * (r.y1 - r.y0) end

	it("dims everything except the hole", function()
		local hole = { x0 = 200, y0 = 400, x1 = 300, y1 = 500 }
		local rects = hud.spotlight(vis, hole)
		assert_eq(#rects, 4)
		local total = 0
		for _, r in ipairs(rects) do
			total = total + r.w * r.h
			assert_false(overlap(r, hole)) -- not over the hole
		end
		assert_near(total, 720 * 1280 - 100 * 100, 1e-6) -- all of the rest
		-- a hole on the edge leaves fewer rectangles
		local edge = hud.spotlight(vis, { x0 = -50, y0 = 0, x1 = 100, y1 = 100 })
		assert_eq(#edge, 2)
		-- a hole outside the window dims it all
		local out = hud.spotlight(vis, { x0 = 900, y0 = 100, x1 = 950, y1 = 200 })
		local sum = 0
		for _, r in ipairs(out) do sum = sum + r.w * r.h end
		assert_near(sum, 720 * 1280 - 0, 1e5) -- (about the whole window)
	end)

	it("makes the hole from the lit cells", function()
		local h = hud.hole({ { 100, 200 }, { 176, 200 } }, 76, 8)
		assert_same(h, { x0 = 54, y0 = 154, x1 = 222, y1 = 246 })
		assert_eq(hud.hole({}, 76, 8), nil)
	end)

	it("moves the hand from the first cell to the second and back again", function()
		local a, b = { 100, 200 }, { 300, 200 }
		local p0 = hud.hand_pose("swipe", { a, b }, 0)
		assert_eq(p0.alpha, 0) -- it appears
		local pa = hud.hand_pose("swipe", { a, b }, 0.3)
		assert_eq(pa.x, 100)
		assert_true(pa.down)
		local pm = hud.hand_pose("swipe", { a, b }, 0.8)
		assert_true(pm.x > 100 and pm.x < 300)
		assert_true(pm.down)
		local pb = hud.hand_pose("swipe", { a, b }, 1.3)
		assert_eq(pb.x, 300)
		local pf = hud.hand_pose("swipe", { a, b }, 1.7)
		assert_true(pf.alpha < 0.6) -- fading before the next round
		-- one cycle later it is the same
		assert_near(hud.hand_pose("swipe", { a, b }, 0.8 + hud.HAND_SWIPE).x, pm.x, 1e-9)
	end)

	it("touches each point in turn when tapping, and holds still when pointing", function()
		local a, b = { 100, 200 }, { 300, 200 }
		local p1 = hud.hand_pose("taps", { a, b }, 0.55)
		assert_eq(p1.x, 100)
		assert_true(p1.scale < 1)
		local mid = hud.hand_pose("taps", { a, b }, hud.HAND_TAP + 0.2)
		assert_true(mid.x > 100 and mid.x < 300) -- on its way to the second
		local p2 = hud.hand_pose("taps", { a, b }, hud.HAND_TAP + 0.55)
		assert_eq(p2.x, 300)
		local rest = hud.hand_pose("taps", { a, b }, 2 * hud.HAND_TAP + 0.3)
		assert_true(rest.alpha < 1)
		-- the same cell twice (tap-tap on a special)
		local t2 = hud.hand_pose("taps", { a, a }, hud.HAND_TAP + 0.55)
		assert_eq(t2.x, 100)
		local pt = hud.hand_pose("point", { a }, 0.4)
		assert_eq(pt.x, 100)
		assert_eq(pt.alpha, 1)
		assert_true(math.abs(pt.y - 200) <= 9.0001)
		assert_eq(hud.hand_pose("taps", {}, 1).alpha, 0)
	end)

	it("puts the bubble in the half of the board away from the lit cells and never over them", function()
		local board = { x0 = 18, y0 = 283, x1 = 702, y1 = 967 }
		local low = { x0 = 100, y0 = 300, x1 = 250, y1 = 380 }
		local r = hud.bubble_rect(vis, board, low, 600, 130)
		assert_true(r.cy > 625) -- the cells are low: the bubble goes up
		assert_false(overlap(r, low))
		local high = { x0 = 100, y0 = 850, x1 = 250, y1 = 940 }
		local r2 = hud.bubble_rect(vis, board, high, 600, 130)
		assert_true(r2.cy < 625) -- high: it goes down
		-- no lit cells (a tip): the top
		local r3 = hud.bubble_rect(vis, board, nil, 600, 130)
		assert_true(r3.cy >= 625 or r3.cy < 625)
		-- inside the window, narrower than a narrow window
		local narrow = hud.bubble_rect({ x0 = 0, y0 = 0, x1 = 400, y1 = 800 }, nil, nil, 600, 130)
		assert_true(narrow.w <= 376 and narrow.x0 >= 0 and narrow.x1 <= 400)
		assert_true(narrow.y0 >= 0 and narrow.y1 <= 800)
		-- the lit cells fill the middle of the board: the bubble does not cover them
		local mid = { x0 = 100, y0 = 600, x1 = 600, y1 = 700 }
		local r4 = hud.bubble_rect(vis, board, mid, 600, 130)
		assert_false(overlap(r4, mid))
	end)
end)
