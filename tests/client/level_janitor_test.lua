-- The janitor of the level board (screens/level/board.script janitor, client/level_view.lua audit_sprite / View:audit,
-- client/level_vfx.lua Vfx:audit), on the strict Defold stub with the real board script.
--
-- Everything else on the board trusts what it has sent to the engine (the flags hidden / pooled, the cached look of a
-- sprite). When the board has been calm for a while the janitor asks the ENGINE where its objects are and puts right and
-- counts what differs. No hunt has met a leftover on a healthy board yet (decisions.md 8.3 item 8): this is the net under
-- the causes nobody has reproduced, so the tests make the faults on purpose, behind the back of the board, in the stub
-- (go.set_position of a sprite the board believes hidden, a lost effect sprite, a wire that is missing ...) and watch the
-- janitor find them, count them and say so once in the log.

local L = require("tests.client.level_leak")
local stub = require("tests.client.level_defold_stub")
local core_helper = require("tests.core.helper")

-- (the vectors of the engine keep float32; the janitor looks when the board is calm, and a board is only calm if it does
-- not mistake its own float32 numbers for a change: the tests run the way the engine does)
local function with_board(params, fn)
	return L.with_board(params, fn, { float32 = true })
end

local function frames(B, n, dt)
	for _ = 1, n do B.step(dt or 1 / 60) end
end

-- the lines of the log that are the janitor's
local function janitor_lines(B)
	local out = {}
	for _, line in ipairs(B.log) do
		if string.find(line, "WARNING: level janitor", 1, true) then out[#out + 1] = line end
	end
	return out
end

-- a new calm begins: the janitor looks once more, 20 frames after the board is still
local function wait_for_pass(B, max)
	local before = B.self.janitor_passes or 0
	for _ = 1, max or 120 do
		B.step(1 / 60)
		if (B.self.janitor_passes or 0) > before then return true end
	end
	return false
end

-- The janitor is due at the next calm, as if it had not looked for a long time. (A fault made behind the back of the
-- board needs this: nothing else tells the board that something has happened. A real one is found by the look that follows
-- the next move, or by the look every 600 frames.)
local function something_happened(B)
	B.self.janitor_frame = B.self.frames - 100000
end

local function engine_object(B, o)
	return B.E.objects[o.go.s]
end

local function visible(B, o)
	return B.E.visible(engine_object(B, o))
end

describe("the janitor: a board that is calm is looked at in the engine", function()
	it("looks once the board has been calm for a while, finds nothing on a clean board and writes to the engine not at all", function()
		with_board({ level = 1 }, function(B)
			frames(B, 70) -- the pieces bloom in, then twenty calm frames
			assert_eq(B.self.janitor_passes, 1)
			B.E.reset_counts()
			frames(B, 150) -- (the hint wobble comes after 5 s)
			for name, n in pairs(B.E.counts) do -- order-independent
				assert_true(false, "the janitor wrote to the engine on a clean board: " .. name .. " x" .. n)
			end
			assert_eq(B.self.janitor_passes, 1, "once per calm, nothing happened since")
			assert_eq(B.self.view:stats().repaired, 0)
			assert_eq(B.self.vfx:stats().repaired, 0)
			assert_eq(B.self.janitor_repairs or 0, 0)
			assert_eq(#janitor_lines(B), 0)
			assert_eq(#B.findings, 0)
		end)
	end)

	it("looks again after a move, and anyway every 600 frames of a quiet board", function()
		with_board({ level = 1 }, function(B)
			frames(B, 70)
			assert_eq(B.self.janitor_passes, 1)
			assert_true(B.self.session:qa("hint_move", {}).ok)
			for _ = 1, 600 do
				B.step(1 / 60)
				if B.self.janitor_passes >= 2 then break end
			end
			assert_eq(B.self.janitor_passes, 2, "a move was made and the board is calm again")
			-- nothing happens for ten seconds and more: it looks now and then all the same (the hint wobbles in between)
			frames(B, 1300)
			assert_true(B.self.janitor_passes >= 4, "passes: " .. B.self.janitor_passes)
			assert_eq(B.self.janitor_repairs or 0, 0)
			assert_eq(#B.findings, 0)
		end)
	end)

	it("hides an effect sprite the engine draws although the Lua side hid it, and counts it", function()
		with_board({ level = 1 }, function(B)
			frames(B, 70)
			local vfx = B.self.vfx
			-- one effect runs and ends: its sprite is in the pool
			vfx:play({ { kind = "flash", x = 300, y = 600, size = 100, color = "#FFFFFF", at = 0, dur = 0.2 } })
			frames(B, 60)
			local o = vfx.all[1]
			assert_true(o and o.pooled and o.hidden, "the effect sprite is pooled and hidden")
			assert_false(visible(B, o))
			-- something moves it onto the screen behind the back of the view
			go.set_position(vmath.vector3(300, 600, 0.4), o.go)
			assert_true(visible(B, o))
			something_happened(B)
			assert_true(wait_for_pass(B), "the janitor looks at the next calm")
			assert_false(visible(B, o), "the janitor hid it")
			assert_eq(vfx:stats().repaired, 1)
			assert_eq(B.self.janitor_repairs, 1)
			local lines = janitor_lines(B)
			assert_eq(#lines, 1, "and said so")
			assert_true(string.find(lines[1], "put right 1 thing(s)", 1, true) ~= nil, lines[1])
			-- the next calm finds nothing
			something_happened(B)
			assert_true(wait_for_pass(B))
			assert_eq(vfx:stats().repaired, 1)
			assert_eq(#janitor_lines(B), 1)
		end)
	end)

	it("takes back an effect sprite nobody holds", function()
		with_board({ level = 1 }, function(B)
			frames(B, 70)
			local vfx = B.self.vfx
			local o = vfx:_sprite("glow") -- taken, and the record that held it is lost
			require("client.level_view").apply(o, "fx_flash", 300, 600, 0.4, 1, 1, 0, 0, nil, 0.8)
			assert_true(visible(B, o))
			something_happened(B)
			assert_true(wait_for_pass(B))
			assert_false(visible(B, o))
			assert_true(o.pooled)
			assert_true(vfx:stats().repaired >= 1)
			assert_eq(#vfx.pool.glow, 1, "it is in its pool once")
		end)
	end)

	it("puts a piece sprite right that the engine has somewhere else, and sends every piece again", function()
		with_board({ level = 1 }, function(B)
			frames(B, 70)
			local view = B.self.view
			local id, o = next(view.by_id)
			local x, y = o.pos.x, o.pos.y
			go.set_position(vmath.vector3(x + 90, y + 40, o.pos.z), o.go)
			something_happened(B)
			B.E.reset_counts()
			assert_true(wait_for_pass(B))
			assert_true(view:stats().repaired >= 1)
			frames(B, 2) -- (the next sync sends the pieces again)
			local p = go.get_position(o.go)
			assert_true(math.abs(p.x - x) < 0.6 and math.abs(p.y - y) < 0.6, "the piece is back in its cell")
			-- the other pieces were sent again too (one wrong sprite does not make the others right)
			assert_true((B.E.counts.go_set_position or 0) >= #B.game():pieces(), "all pieces were sent again")
			local before = view:stats().repaired
			something_happened(B)
			assert_true(wait_for_pass(B))
			assert_eq(view:stats().repaired, before, "nothing more to repair")
			local R = L.leak_report(B, { rest = true })
			assert_eq(#R.leaks, 0, L.format(R))
		end)
	end)

	it("hides a mark that nobody asked for", function()
		with_board({ level = 1 }, function(B)
			frames(B, 70)
			local view = B.self.view
			-- a mark was shown once and hidden again; the engine draws it nevertheless
			view:marks({ { image = "fx_glow_dot", x = 100, y = 700, w = 80, h = 80, color = "#FFD84D", alpha = 0.8, glow = true } })
			view:marks({})
			local m = view.mark_objs.glow[1]
			assert_true(m.hidden)
			go.set_position(vmath.vector3(100, 700, 0.05), m.go)
			assert_true(visible(B, m))
			something_happened(B)
			assert_true(wait_for_pass(B))
			assert_false(visible(B, m), "the mark is gone")
			assert_true(view:stats().repaired >= 1)
		end)
	end)

	it("lays the wires out again when the overlay is not the core's", function()
		with_board({ level = 22 }, function(B)
			frames(B, 70)
			local view = B.self.view
			local n = view:stats().wires
			assert_true(n > 1, "level 22 has wires")
			assert_eq(#view.wires, n)
			-- a wire is lost: its sprite deleted, its place in the list gone
			local last = view.wires[n]
			go.delete(last.o.go)
			view.wires[n] = nil
			something_happened(B)
			assert_true(wait_for_pass(B))
			assert_eq(#view.wires, n, "the overlay is whole again")
			assert_true(view:stats().repaired >= 1)
			something_happened(B)
			local R
			frames(B, 30)
			R = L.leak_report(B, { rest = true })
			assert_eq(#R.leaks, 0, L.format(R))
		end)
	end)

	it("drops the cached list of pieces when it is not the core's", function()
		with_board({ level = 1 }, function(B)
			frames(B, 70)
			assert_true(B.self.pieces ~= nil)
			B.self.pieces[3] = setmetatable({ x = 9 }, { __index = B.self.pieces[3] }) -- a piece the board thinks is elsewhere
			something_happened(B)
			assert_true(wait_for_pass(B))
			assert_eq(B.self.janitor_repairs, 1)
			frames(B, 3)
			local R = L.leak_report(B, { rest = true })
			assert_eq(#R.leaks, 0, "the list was built again: " .. L.format(R))
		end)
	end)

	it("says so in the log for the first five passes with repairs only, and counts them all", function()
		with_board({ level = 1 }, function(B)
			frames(B, 70)
			local vfx = B.self.vfx
			vfx:play({ { kind = "flash", x = 300, y = 600, size = 100, color = "#FFFFFF", at = 0, dur = 0.2 } })
			frames(B, 60)
			local o = vfx.all[1]
			for _ = 1, 8 do
				go.set_position(vmath.vector3(300, 600, 0.4), o.go)
				something_happened(B)
				assert_true(wait_for_pass(B))
			end
			assert_eq(B.self.janitor_repairs, 8)
			assert_eq(#janitor_lines(B), 5)
		end)
	end)

	it("does not look while a window holds the session, a skip waits or an effect runs", function()
		with_board({ level = 1 }, function(B)
			frames(B, 70)
			local passes = B.self.janitor_passes
			something_happened(B)
			B.hud.pause = true
			B.apply_pause()
			frames(B, 100)
			assert_eq(B.self.janitor_passes, passes, "it looked while a window held the session")
			B.hud.pause = false
			B.apply_pause()
			B.self.vfx:play({ { kind = "ring", x = 300, y = 600, size = 100, color = "#FFFFFF", at = 0, dur = 1.0 } })
			frames(B, 30)
			assert_eq(B.self.janitor_passes, passes, "it looked while an effect ran")
			assert_true(wait_for_pass(B, 200))
		end)
	end)
end)

describe("the janitor: the sprite audit on its own", function()
	local function with_view(fn)
		local E = stub.install({})
		local ok, err = pcall(function()
			local level_view = require("client.level_view")
			fn(E, level_view, level_view.new({}))
		end)
		stub.restore()
		if not ok then error(err, 0) end
	end

	it("asks the engine, repairs a sprite that is drawn although it is hidden, and leaves a good one alone", function()
		with_view(function(E, level_view)
			local o = level_view.create("#piece_factory")
			level_view.apply(o, "pieces_red", 200, 500, 0.1, 0.5, 0.5, 0, 0, nil, 1)
			assert_eq(level_view.audit_sprite(o, false), 0, "a sprite where it was put")
			level_view.hide(o)
			assert_eq(level_view.audit_sprite(o, true), 0, "a hidden sprite that is hidden in the engine")
			-- the engine draws it although it was hidden
			go.set_position(vmath.vector3(200, 500, 0.1), o.go)
			assert_eq(level_view.audit_sprite(o, true), 1)
			assert_true(o.hidden)
			assert_false(E.visible(E.by_factory("piece_factory")[1]))
			-- a sprite that should not be drawn, and that Lua thinks is drawn, but is not: the flag is put right
			local q = level_view.create("#piece_factory")
			q.hidden = false
			assert_eq(level_view.audit_sprite(q, true), 1)
			assert_true(q.hidden)
		end)
	end)

	it("forgets a displaced sprite so that the next apply sends all of it again", function()
		with_view(function(E, level_view)
			local o = level_view.create("#piece_factory")
			level_view.apply(o, "pieces_red", 200, 500, 0.1, 0.5, 0.5, 30, 0.2, nil, 0.7)
			go.set_position(vmath.vector3(260, 500, 0.1), o.go)
			assert_eq(level_view.audit_sprite(o, false), 1)
			E.reset_counts()
			level_view.apply(o, "pieces_red", 200, 500, 0.1, 0.5, 0.5, 30, 0.2, nil, 0.7)
			local c = E.counts
			assert_true(c.go_set_position and c.go_set_scale and c.go_set_rotation and c.go_set, "every property was sent again")
			assert_eq(level_view.audit_sprite(o, false), 0)
			-- a position that differs by less than a pixel is the engine's float, not a fault
			go.set_position(vmath.vector3(200.3, 500.2, 0.1), o.go)
			assert_eq(level_view.audit_sprite(o, false), 0)
		end)
	end)

	it("takes back the sprite of a piece the core no longer has, and repairs the rest of what the view holds", function()
		with_view(function(E, level_view, V)
			local function entry(id, x)
				return { id = id, image = "pieces_red", x = x, y = 500, z = 0.1, sx = 1, sy = 1, scale = 0.5, rot = 0, flash = 0, alpha = 1 }
			end
			V:sync({ entry(1, 100), entry(2, 200), entry(3, 300) }, 0, 0)
			assert_eq(V:stats().pieces, 3)
			-- the draw list still holds piece 3 (an animation that outlived it), the core no longer has it
			assert_eq(V:audit({ [1] = true, [2] = true }), 1)
			assert_eq(V.by_id[3], nil)
			assert_eq(V:stats().pieces, 2)
			assert_eq(V:stats().pooled, 1)
			assert_eq(V:stats().repaired, 1)
			local on = 0
			for _, o in ipairs(E.by_factory("piece_factory")) do
				if E.visible(o) then on = on + 1 end
			end
			assert_eq(on, 2, "its sprite is away")
			-- all the pieces are sent again by the next sync (one wrong sprite does not make the others right)
			E.reset_counts()
			V:sync({ entry(1, 100), entry(2, 200) }, 0, 0)
			assert_true((E.counts.go_set_position or 0) >= 2)
			-- a clean view needs nothing
			assert_eq(V:audit({ [1] = true, [2] = true }), 0)
			assert_eq(V:stats().repaired, 1)
			-- a pooled sprite that the engine draws
			local pooled = V.free[1]
			go.set_position(vmath.vector3(300, 500, 0.1), pooled.go)
			assert_eq(V:audit({ [1] = true, [2] = true }), 1)
			assert_true(pooled.hidden)
			assert_eq(V:stats().repaired, 2)
		end)
	end)

	it("counts a mark past the last call as one that should be hidden, and one of the last call as one to be drawn", function()
		with_view(function(E, level_view, V)
			local list = { { image = "fx_glow_dot", x = 100, y = 200, w = 100, h = 100, color = "#FFD84D", alpha = 0.8, glow = true },
				{ image = "white", iw = 8, ih = 8, x = 300, y = 200, w = 90, h = 90, color = "#FFD84D", alpha = 0.4, glow = false } }
			V:marks(list)
			assert_eq(V.mark_n.glow, 1)
			assert_eq(V.mark_n.piece, 1)
			assert_eq(V:audit({}), 0, "marks where they were put")
			go.set_position(vmath.vector3(140, 200, 0.05), V.mark_objs.glow[1].go)
			assert_eq(V:audit({}), 1, "a mark that is somewhere else")
			V:marks({})
			assert_eq(V.mark_n.glow, 0)
			go.set_position(vmath.vector3(140, 200, 0.05), V.mark_objs.glow[1].go)
			assert_eq(V:audit({}), 1, "a mark nobody asks for that is drawn")
			assert_eq(V:audit({}), 0)
		end)
	end)

	it("lays the wires out again when one is missing, in the wrong place or of the wrong strength", function()
		with_view(function(E, level_view, V)
			local geom = require("client.level_geom")
			local cells = {}
			for i = 1, 25 do cells[i] = { exists = true, wires = 0 } end
			cells[7].wires, cells[8].wires, cells[19].wires = 1, 2, 1
			local g = geom.new(5, 5, cells, { x0 = 0, y0 = 200, x1 = 500, y1 = 700 })
			V:set_wires(cells, g)
			assert_eq(#V.wires, 3)
			assert_false(V:wires_differ(cells, g))
			assert_eq(V:audit({}, cells, g), 0)
			-- the core's wires change without the overlay hearing of it
			cells[8].wires = 1
			assert_true(V:wires_differ(cells, g))
			assert_eq(V:audit({}, cells, g), 1)
			assert_false(V:wires_differ(cells, g))
			cells[12].wires = 1
			assert_eq(V:audit({}, cells, g), 1)
			assert_eq(#V.wires, 4)
			cells[7].wires, cells[8].wires, cells[12].wires = 0, 0, 0
			assert_eq(V:audit({}, cells, g), 1)
			assert_eq(#V.wires, 1)
			assert_false(V:wires_differ(cells, g))
		end)
	end)

	it("does not mind an object the engine has already deleted", function()
		with_view(function(E, level_view)
			local o = level_view.create("#piece_factory")
			go.delete(o.go)
			assert_eq(level_view.audit_sprite(o, true), 0)
			assert_eq(level_view.audit_sprite(o, false), 0)
		end)
	end)

	it("counts the writes it makes to the engine, so that the board can tell that the screen is still", function()
		with_view(function(E, level_view)
			local o = level_view.create("#piece_factory")
			local w0 = level_view.writes
			level_view.apply(o, "pieces_red", 200, 500, 0.1, 0.5, 0.5, 0, 0, nil, 1)
			local w1 = level_view.writes
			assert_true(w1 > w0)
			level_view.apply(o, "pieces_red", 200, 500, 0.1, 0.5, 0.5, 0, 0, nil, 1)
			assert_eq(level_view.writes, w1, "the same look again is not a write")
			level_view.hide(o)
			assert_eq(level_view.writes, w1 + 1)
			level_view.hide(o)
			assert_eq(level_view.writes, w1 + 1, "a hidden sprite is not hidden twice")
		end)
	end)
end)
