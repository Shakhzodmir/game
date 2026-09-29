-- Tick-by-tick tests of the swap lifecycle (5.1.3, 5.1.4, 6.2.1, 15.1).

local C = require("core.const")
local H = require("tests.core.helper")

local FULL = { "######", "######", "######", "######", "######", "######" }
local P1 = { "rrgrby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" }

local function fresh(rows, extra, opts)
	local g = H.game(FULL, extra, opts)
	H.board(g, rows or P1)
	return g
end

describe("core swap: timing and resolution in step 2", function()
	it("a swap accepted before tick N+1 ends in step 2 of tick N+11 and resolves at once", function()
		local g = fresh()
		for _ = 1, 3 do g:step() end -- N = 3
		g:drain_events()
		assert_same({ g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } }) }, { true, "ok" })
		local ev = H.steps(g, 10) -- ticks 4..13
		assert_eq(#H.of_type(ev, "match"), 0)
		assert_eq(H.obj_at(g, 3, 1).state, C.S_SWAP)
		g:step() -- tick 14 = N + 11
		ev = g:drain_events()
		assert_eq(ev[1].type, "match")
		assert_same(ev[1], { t = 14, type = "match", cells = { { 1, 1 }, { 2, 1 }, { 3, 1 } }, color = "red", wave = 1, act = 1 })
		local green = H.obj_at(g, 4, 1)
		assert_eq(green.color, 4)
		assert_eq(green.state, C.S_IDLE)
		assert_eq(green.settle, 14)
		assert_same({ green.mv, green.wv }, { 1, 0 }, "swapped pieces take (a, 0)")
		for x = 1, 3 do
			local o = H.obj_at(g, x, 1)
			assert_eq(o.state, C.S_CLEAR)
			assert_eq(o.td, 23)
			assert_same({ g.s.vac_mv[x], g.s.vac_wv[x] }, { 1, 1 }, "vac = label of the match source")
		end
		-- the events of one hit: clear -> score -> goal
		assert_same(ev[2], { t = 14, type = "clear", id = 1, x = 1, y = 1, kind = "regular", color = "red", cause = "match" })
		assert_same(ev[3], { t = 14, type = "score", delta = 20, total = 20, x = 1, y = 1 })
		assert_same(ev[4], { t = 14, type = "goal", index = 1, left = 998 })
		assert_eq(g.s.score, 60)
		assert_false(g.s.dirty, "the search clears the dirty flag")
	end)

	it("a piece cleared in tick t leaves the board in step 4 of tick t + 9, then the column refills", function()
		local g = fresh()
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		for _ = 1, 11 do g:step() end
		g:drain_events()
		for _ = 1, 8 do g:step() end -- tick 19
		assert_eq(H.obj_at(g, 1, 1).state, C.S_CLEAR)
		g:step() -- tick 20
		local ev = g:drain_events()
		local spawns = H.of_type(ev, "spawn")
		assert_eq(#spawns, 3)
		assert_same({ spawns[1].x, spawns[1].y, spawns[2].x, spawns[3].x }, { 1, 1, 2, 3 })
		local o = H.obj_at(g, 1, 1)
		assert_eq(o.state, C.S_FALL)
		assert_same({ o.mv, o.wv }, { 1, 1 }, "a spawn takes the vac of its cell")
	end)

	it("refunds a swap whose cells joined no group and restores labels", function()
		local g = fresh()
		local red = H.obj_at(g, 4, 1)
		red.mv, red.wv = 0, 7
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		-- a cascade takes the match away before the swap ends
		H.obj_at(g, 1, 1).color = C.COLOR.blue
		g:drain_events()
		for _ = 1, 11 do g:step() end
		local ev = g:drain_events()
		assert_same(H.of_type(ev, "swap_back"), {
			{ t = 11, type = "swap_back", a = { 3, 1 }, b = { 4, 1 }, ids = { red.id, 3 }, duration = 10 },
		})
		assert_same(H.of_type(ev, "moves"), { { t = 11, type = "moves", left = 20 } })
		local s = g.s
		assert_eq(s.moves_left, 20)
		assert_eq(s.moves_made, 0)
		assert_same(s.eom, {})
		assert_same({ red.mv, red.wv }, { 0, 7 }, "remembered label restored")
		assert_eq(red.tk, C.TM_BACK)
		assert_eq(red.td, 21)
		assert_same({ s.swaps[1].kind, s.swaps[1].a, s.swaps[1].w1, s.swaps[1].w2 }, { C.TM_BACK, 1, 0, 7 })
		assert_eq(s.act, 1, "the action number is not reused")
		for _ = 1, 10 do g:step() end -- tick 21
		assert_eq(H.obj_at(g, 4, 1), red, "exchanged back")
		assert_eq(red.state, C.S_IDLE)
		assert_eq(red.settle, 21)
		assert_same(s.swaps, {})
		assert_eq(#H.of_type(g:drain_events(), "swap_back"), 0, "no refund after swap_back")
	end)

	it("labels come from the swap's own number, not the current act", function()
		local g = fresh()
		g:input({ type = "swap", from = { 3, 1 }, to = { 4, 1 } })
		g:step()
		g:input({ type = "swap", from = { 5, 5 }, to = { 6, 5 } }) -- a failed swap: no act
		g:input({ type = "swap", from = { 1, 2 }, to = { 2, 2 } }) -- act 2
		assert_eq(g.s.act, 2)
		for _ = 1, 10 do g:step() end -- tick 11: the first swap ends
		local green = H.obj_at(g, 4, 1)
		assert_same({ green.mv, green.wv }, { 1, 0 })
	end)

	it("rule 6.2.1: the new special goes to the swap cell even against settle_tick", function()
		-- (3,1)-(3,2) makes red (1..4, 1): a Riff h
		local g = fresh({ "rrgrby", "yrrbyg", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		H.obj_at(g, 1, 1).settle = 100
		g:input({ type = "swap", from = { 3, 1 }, to = { 3, 2 } })
		local ev = H.steps(g, 11)
		local sn = H.of_type(ev, "special_new")
		assert_eq(#sn, 1)
		assert_same({ sn[1].x, sn[1].y, sn[1].special, sn[1].axis }, { 3, 1, "riff", "h" })
		local riff = H.obj_at(g, 3, 1)
		assert_same({ riff.mv, riff.wv, riff.settle, riff.state }, { 1, 1, 11, C.S_IDLE })
		assert_eq(riff.id, 37, "a new id")
		-- bonus score right after special_new
		for k, e in ipairs(ev) do
			if e.type == "special_new" then
				assert_same(ev[k + 1], { t = 11, type = "score", delta = 60, total = 140, x = 3, y = 1 })
			end
		end
	end)

	it("rule 6.2.1: with two swaps in one group the smaller act wins", function()
		local g = fresh({ "brrgyb", "rygrbg", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		assert_same({ g:input({ type = "swap", from = { 4, 1 }, to = { 4, 2 } }) }, { true, "ok" }) -- a = 1
		assert_same({ g:input({ type = "swap", from = { 1, 1 }, to = { 1, 2 } }) }, { true, "ok" }) -- a = 2
		local ev = H.steps(g, 11)
		local sn = H.of_type(ev, "special_new")
		assert_eq(#sn, 1)
		assert_same({ sn[1].x, sn[1].y, sn[1].special }, { 4, 1, "riff" })
		assert_eq(#H.of_type(ev, "swap_back"), 0)
	end)
end)

describe("core swap: specials (5.1.4)", function()
	it("a special swapped with a piece is armed and fires in step 3 of the same tick with (a, 1)", function()
		local g = fresh({ "Rbygby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } })
		local ev = H.steps(g, 11)
		local act = H.of_type(ev, "activate")
		assert_eq(#act, 1)
		assert_same({ act[1].t, act[1].x, act[1].y, act[1].special, act[1].axis }, { 11, 2, 1, "riff", "h" })
		assert_eq(#H.of_type(ev, "swap_back"), 0, "never refunded")
		-- the Riff's own cell was hit at t0: removed with cause "fired"
		local fired = H.of_type(ev, "clear")
		assert_same({ fired[1].x, fired[1].y, fired[1].cause, fired[1].special }, { 2, 1, "fired", "riff" })
		assert_same({ g.s.vac_mv[2], g.s.vac_wv[2] }, { 1, 1 })
	end)

	it("two specials arm together; the record names the special in `to` and the partner `from`", function()
		local g = fresh({ "RSygby", "yrgbyr", "rgbyrg", "gbyrgb", "byrgby", "yrgbyr" })
		g:input({ type = "swap", from = { 1, 1 }, to = { 2, 1 } })
		for _ = 1, 10 do g:step() end
		-- run step 2 of tick 11 only by peeking at the queue after the tick
		local riff = H.obj_at(g, 1, 1)
		g:step()
		assert_eq(riff.cell, 2, "the Riff moved into `to`")
		local ev = H.of_type(g:drain_events(), "activate")
		assert_eq(#ev, 1)
		assert_eq(ev[1].id, riff.id)
		assert_eq(ev[1].partner, 2)
	end)
end)
