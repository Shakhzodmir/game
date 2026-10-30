-- The checks of the visual-leak oracle itself (tests/client/level_leak.lua) and the stub's idea of "visible"
-- (E.visible_sprites in tests/client/level_defold_stub.lua), one test each. The oracle is only worth what its checks are
-- worth: a check that has gone dead leaves the whole suite and the fuzzer green and blind, so each of them is made to
-- fire on purpose here.

local L = require("tests.client.level_leak")
local stub = require("tests.client.level_defold_stub")

local function frames(B, n)
	for _ = 1, n do B.step(1 / 60) end
end

local function has(list, kind, needle)
	for _, f in ipairs(list) do
		if f.kind == kind and (not needle or string.find(f.text or "", needle, 1, true)) then return true end
	end
	return false
end

describe("the oracle: what it names", function()
	it("names an effect that lives much longer than its length while the session runs (overlong_fx)", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 5)
			B.self.vfx:play({ { kind = "ring", x = 300, y = 600, size = 100, color = "#FFFFFF", image = "fx_shock", at = 0, dur = 0.5 } })
			B.step(1 / 60)
			local fx = B.self.vfx.active[1]
			assert_true(fx ~= nil, "the ring runs")
			fx.cap, fx.life = 1e9, 100 -- a ring that has been alive for 100 s and is not cut off
			B.step(1 / 60)
			assert_true(has(B.findings, "overlong_fx"), "overlong_fx was not reported")
		end)
	end)

	it("names a pooled piece sprite that is on the screen (pooled_visible)", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 5)
			local view = B.self.view
			local o = view:_take()
			require("client.level_view").apply(o, "pieces_red", 300, 600, 0.1, 0.5, 0.5, 0, 0, nil, 1)
			view.free[#view.free + 1] = o
			B.step(1 / 60)
			-- (the pooled sprite is drawn although it is in the pool: the frame check says so)
			local list = L.frame_check(B) or {}
			assert_true(has(list, "pooled_visible", "pooled piece sprite"), "the pooled piece sprite on the screen was not reported")
		end)
	end)

	it("names effects that still run at rest even when none of them is drawn (rest_vfx)", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 90)
			B.self.vfx.active[#B.self.vfx.active + 1] = { step = function() end, c = { kind = "ghost" }, clock = "time", t0 = 0,
				dur = 1e9, n = 0, life = 0, cap = 1e9 }
			local R = L.leak_report(B, { rest = true })
			assert_true(has(R.leaks, "rest_vfx", "effects still run at rest"), L.format(R))
			B.self.vfx.active[#B.self.vfx.active] = nil
		end)
	end)

	it("names commands that still wait for their tick at rest (rest_vfx)", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 90)
			B.self.vfx:play({ { kind = "ring", x = 300, y = 600, size = 100, color = "#FFFFFF", image = "fx_shock", at = 1e9, dur = 0.5 } })
			local R = L.leak_report(B, { rest = true })
			assert_true(has(R.leaks, "rest_vfx", "still wait for their tick"), L.format(R))
		end)
	end)

	it("names a board that is shaken at rest (rest_shake)", function()
		L.with_board({ level = 1 }, function(B)
			frames(B, 90)
			B.self.shake_x = 3
			local R = L.leak_report(B, { rest = true })
			assert_true(has(R.leaks, "rest_shake"), L.format(R))
			B.self.shake_x = 0
		end)
	end)
end)

describe("the stub: what it lists as visible", function()
	it("lists no sprite that lies past any edge of the screen, and lists one inside it", function()
		local E = stub.install({})
		local ok, err = pcall(function()
			local level_view = require("client.level_view")
			local o = level_view.create("#piece_factory")
			level_view.apply(o, "pieces_red", 300, 600, 0.1, 0.5, 0.5, 0, 0, nil, 1)
			assert_eq(#E.visible_sprites(), 1, "inside")
			for _, p in ipairs({ { -100, 600, "left" }, { 900, 600, "right" }, { 300, -100, "top" }, { 300, 1500, "bottom" } }) do
				level_view.apply(o, "pieces_red", p[1], p[2], 0.1, 0.5, 0.5, 0, 0, nil, 1)
				assert_eq(#E.visible_sprites(), 0, "past the " .. p[3] .. " edge")
			end
		end)
		stub.restore()
		if not ok then error(err, 0) end
	end)
end)
