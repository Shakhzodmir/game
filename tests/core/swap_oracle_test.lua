-- The swap of section 5.1 against an oracle written from the text of the specification
-- (tests/core/oracle_a.lua): the cells (5.1.1) and the expected board (5.1.2) in the
-- middle of random games, with swaps in flight, falling pieces, locks and armed specials.
-- core.can_swap and game:input must give the answer of the oracle. Audit A.

local core = require("core.game")
local C = require("core.const")
local O = require("tests.core.oracle_a")
local H = require("tests.core.helper")

local LEVELS = {
	{ rows = { "########", "###..###", "########", "########", "########", "########", "########" }, extra = {
		colors = { "red", "green", "blue", "yellow" }, goals = { { type = "collect", color = "green", count = 300 } },
		slots = { { at = { 0, 2 }, type = "record_box", hp = 2 }, { at = { 4, 4 }, type = "riff", axis = "h" },
			{ at = { 6, 1 }, type = "sub" }, { at = { 1, 5 }, type = "bird" }, { at = { 5, 5 }, type = "disco" } },
		overlay = { { at = { 2, 3 }, type = "wires", hp = 1 }, { at = { 3, 3 }, type = "wires", hp = 1 } },
		floor = { { at = { 0, 0 }, hp = 1 } } } },
	{ rows = { "######", "######", "######", "######", "######", "######", "######", "######" }, extra = {
		colors = { "red", "orange", "yellow", "green", "blue" }, goals = { { type = "deliver", count = 3 } },
		mic = { total = 3, on_board_max = 2, gap_moves = 1 },
		slots = { { at = { 2, 1 }, type = "mic" }, { at = { 3, 2 }, type = "riff", axis = "v" },
			{ at = { 0, 3 }, type = "concrete", hp = 2 } } } },
}

describe("core swap oracle: 5.0, 5.1.1 and 5.1.2 in the middle of random games (audit A)", function()
	it("can_swap and input answer like the oracle (swaps in flight, falls, locks, armed specials)", function()
		local rnd = O.lcg(5)
		local seen = { ok = 0, fail = 0, reject = 0 }
		local moving = 0
		for gno = 1, 10 do
			local L = LEVELS[gno % #LEVELS + 1]
			local lvl = H.load(L.rows, L.extra)
			local g = core.new(lvl, { seed = gno * 13 + 1, timing = (gno % 5 == 0) and "turbo" or "normal", help = gno % 3, input_lock = gno % 7 == 0 })
			for t = 1, 110 do
				local r = rnd(10)
				if r <= 5 then
					local mv = g:moves()
					if #mv > 0 then
						local m = mv[rnd(#mv)]
						g:input({ type = "swap", from = m.from, to = m.to })
					end
				elseif r == 6 then
					g:input({ type = "tap", at = { rnd(8), rnd(8) } })
				elseif r == 7 then
					local fx, fy = rnd(8), rnd(8)
					g:input({ type = "swap", from = { fx, fy }, to = { fx + ({ 1, -1, 0, 0 })[rnd(4)], fy + ({ 0, 0, 1, -1 })[rnd(4)] } })
				end
				g:step()
				g:drain_events()
				if rnd(3) == 1 then
					local s = g.s
					if #s.swaps > 0 or not g:is_stable() then moving = moving + 1 end
					for _ = 1, 14 do
						local fx, fy = rnd(s.W), rnd(s.H)
						local d = rnd(4)
						local tx, ty = fx + ({ 1, -1, 0, 0 })[d], fy + ({ 0, 0, 1, -1 })[d]
						local want = O.swap(g, fx, fy, tx, ty)
						local label = "game " .. gno .. " tick " .. s.tick .. " (" .. fx .. "," .. fy .. ")->(" .. tx .. "," .. ty .. ")"
						assert_eq(g:can_swap({ fx, fy }, { tx, ty }), want, label .. " can_swap")
						local c = g:clone()
						local ok, res = c:input({ type = "swap", from = { fx, fy }, to = { tx, ty } })
						local got = (ok and res == "ok") and "ok" or (ok and res == "fail") and "fail" or "reject"
						assert_eq(got, want, label .. " input")
						seen[want] = seen[want] + 1
					end
				end
				if g.s.state == C.G_OUT then g:input({ type = "continue", moves = 5 }) end
				if g.s.state ~= C.G_PLAYING then break end
			end
		end
		assert_true(seen.ok > 100 and seen.fail > 100 and seen.reject > 100, "answers seen: " .. seen.ok .. "/" .. seen.fail .. "/" .. seen.reject)
		assert_true(moving > 100, "snapshots taken while the board moved: " .. moving)
	end)
end)
