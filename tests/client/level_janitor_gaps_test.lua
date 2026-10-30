-- What level_janitor_test.lua leaves open: every branch of the janitor's net (screens/level/board.script janitor, the
-- audit of client/level_view.lua and client/level_vfx.lua) and every condition that makes it look, one test each, so that
-- a branch that goes dead is noticed (an independent mutation run found 13 branches of the net and 7 of the conditions
-- that no test touched). Also the engine writes the board counts (the janitor looks only when none was made), the faults
-- an engine can make that the net has to find (a wire sprite the engine has elsewhere, a depth or a size that is not
-- the one put there, a number that is no number) and the order in which a sprite goes back to the pool.

local L = require("tests.client.level_leak")
local stub = require("tests.client.level_defold_stub")

local function with_board(params, fn)
	return L.with_board(params, fn, { float32 = true })
end

local function frames(B, n, dt)
	for _ = 1, n do B.step(dt or 1 / 60) end
end

local function janitor_lines(B)
	local out = {}
	for _, line in ipairs(B.log) do
		if string.find(line, "WARNING: level janitor", 1, true) then out[#out + 1] = line end
	end
	return out
end

local function wait_for_pass(B, max)
	local before = B.self.janitor_passes or 0
	for _ = 1, max or 200 do
		B.step(1 / 60)
		if (B.self.janitor_passes or 0) > before then return true end
	end
	return false
end

-- as in level_janitor_test.lua: the janitor is due at the next calm
local function something_happened(B)
	B.self.janitor_frame = B.self.frames - 100000
	B.self.janitor_t = B.self.t - 100000
end

local function with_view(fn)
	local E = stub.install({})
	local ok, err = pcall(function()
		local level_view = require("client.level_view")
		fn(E, level_view, level_view.new({}))
	end)
	stub.restore()
	if not ok then error(err, 0) end
end

local function cells_of(n, fn)
	local cells = {}
	for i = 1, n * n do cells[i] = { exists = true, wires = 0 } end
	if fn then fn(cells) end
	return cells
end

describe("the janitor: a board with plates, wires and columns is looked at and found clean", function()
	for _, level in ipairs({ 22, 10, 50, 65, 90 }) do
		it("finds nothing to put right on a clean board of level " .. level, function()
			with_board({ level = level }, function(B)
				frames(B, 90)
				assert_true((B.self.janitor_passes or 0) >= 1, "the janitor looked")
				assert_eq(B.self.janitor_repairs or 0, 0, "and found nothing")
				assert_eq(#janitor_lines(B), 0)
				assert_eq(B.self.view:stats().repaired, 0)
				-- and what it looked at is still there afterwards (a janitor that hides a wanted mark is no janitor)
				local R = L.leak_report(B, { rest = true })
				assert_eq(#R.leaks, 0, L.format(R))
			end)
		end)
	end
end)

describe("the janitor: the lists the board keeps between two frames", function()
	it("puts right the cached cells of the board when they are not the core's (wires)", function()
		with_board({ level = 22 }, function(B)
			frames(B, 90)
			local self = B.self
			local idx
			for i, c in ipairs(self.cells) do
				if c.exists and (c.wires or 0) > 0 then idx = i break end
			end
			assert_true(idx ~= nil, "level 22 has wires")
			local fake = {}
			for i, c in ipairs(self.cells) do fake[i] = { exists = c.exists, wires = c.wires, floor = c.floor } end
			fake[idx].wires = 0 -- the board believes there are no wires there
			self.cells = fake
			something_happened(B)
			local before = self.janitor_repairs or 0
			assert_true(wait_for_pass(B))
			assert_true((self.janitor_repairs or 0) > before, "the stale cells were found")
			frames(B, 3)
			assert_eq(self.cells[idx].wires, B.game():cells()[idx].wires, "and the board has the core's cells again")
		end)
	end)

	it("puts right a stale floor in the cached cells", function()
		with_board({ level = 16 }, function(B)
			frames(B, 90)
			local self = B.self
			local fake = {}
			for i, c in ipairs(self.cells) do fake[i] = { exists = c.exists, wires = c.wires, floor = c.floor } end
			local idx
			for i, c in ipairs(fake) do if c.exists then idx = i break end end
			fake[idx].floor = (fake[idx].floor or 0) + 1
			self.cells = fake
			something_happened(B)
			local before = self.janitor_repairs or 0
			assert_true(wait_for_pass(B))
			assert_true((self.janitor_repairs or 0) > before, "the stale floor was found")
		end)
	end)

	it("drops the cached list of pieces when only the hp of a piece differs", function()
		local tried = {}
		for _, level in ipairs({ 10, 22, 40, 50, 65, 90 }) do
			local found = false
			with_board({ level = level }, function(B)
				frames(B, 90)
				local self = B.self
				local idx
				for i, p in ipairs(self.pieces) do
					if p.hp ~= nil then idx = i break end
				end
				if not idx then return end
				found = true
				self.pieces[idx] = setmetatable({ hp = (self.pieces[idx].hp or 1) + 1 }, { __index = self.pieces[idx] })
				something_happened(B)
				local before = self.janitor_repairs or 0
				assert_true(wait_for_pass(B))
				assert_true((self.janitor_repairs or 0) > before, "level " .. level .. ": the stale hp was found")
			end)
			tried[#tried + 1] = level
			if found then return end
		end
		assert_true(false, "no level with a piece that has hp among " .. table.concat(tried, ","))
	end)

	it("takes back the stale sprite of a piece that was alive at an earlier look", function()
		with_board({ level = 1 }, function(B)
			frames(B, 90)
			local self = B.self
			local view = self.view
			local game = B.game()
			local before = {}
			for _, p in ipairs(game:pieces()) do before[p.id] = true end
			assert_true(self.janitor_passes >= 1)
			-- a move: pieces die, others fall, new ones arrive
			assert_true(self.session:qa("hint_move", {}).ok)
			local dead
			for _ = 1, 600 do
				B.step(1 / 60)
				if game:is_stable() then
					local now = {}
					for _, p in ipairs(game:pieces()) do now[p.id] = true end
					for id in pairs(before) do
						if not now[id] then dead = id break end
					end
					break
				end
			end
			assert_true(dead ~= nil, "a piece died")
			frames(B, 60) -- (the janitor looks once more after the move: the dead id was among its ids)
			-- the draw list still holds an entry for the dead piece (an animation that outlived it): View:sync keeps a
			-- sprite for it, and only the janitor, which asks the core, knows that the piece is gone
			local anim = self.anim
			local real_frame = anim.frame
			anim.frame = function(a, pieces, tick_f, t)
				local list = real_frame(a, pieces, tick_f, t)
				local e = {}
				for k, v in pairs(list[1]) do e[k] = v end
				e.id, e.x, e.y = dead, 300, 600
				list[#list + 1] = e
				return list
			end
			frames(B, 2)
			assert_true(view.by_id[dead] ~= nil, "the ghost has a sprite")
			local ghost = view.by_id[dead]
			assert_true(B.E.visible(B.E.objects[ghost.go.s]), "and it is drawn")
			something_happened(B)
			local repairs = self.janitor_repairs or 0
			assert_true(wait_for_pass(B))
			assert_true((self.janitor_repairs or 0) > repairs, "the janitor found it")
			assert_eq(view.by_id[dead], nil, "and took the stale sprite back")
			assert_false(B.E.visible(B.E.objects[ghost.go.s]), "and hid it")
			anim.frame = real_frame
		end)
	end)
end)

describe("the janitor: the sprites of the view", function()
	it("puts right a plate mark that is somewhere else and hides one nobody asks for", function()
		with_view(function(E, level_view, V)
			V:marks({ { image = "white", iw = 8, ih = 8, x = 300, y = 200, w = 90, h = 90, color = "#FFD84D", alpha = 0.4, glow = false } })
			assert_eq(V:audit({}), 0, "a plate where it was put")
			go.set_position(vmath.vector3(340, 200, 0.05), V.mark_objs.piece[1].go)
			assert_eq(V:audit({}), 1, "a plate that is somewhere else")
			-- the last call drew no plate, but the sprite was not hidden (a marks() that forgot): drawn, nobody asks for it
			V.mark_n.piece = 0
			V.mark_objs.piece[1].hidden = false
			go.set_position(vmath.vector3(300, 200, 0.05), V.mark_objs.piece[1].go)
			assert_eq(V:audit({}), 1, "a plate nobody asks for that is drawn")
			assert_true(V.mark_objs.piece[1].hidden)
		end)
	end)

	it("hides a glow mark past the last call even when the view believes it is drawn", function()
		with_view(function(E, level_view, V)
			V:marks({ { image = "fx_glow_dot", x = 100, y = 200, w = 100, h = 100, color = "#FFD84D", alpha = 0.8, glow = true } })
			V.mark_n.glow = 0 -- the number the last marks() call drew decides what is wanted
			assert_eq(V:audit({}), 1)
			assert_true(V.mark_objs.glow[1].hidden)
			assert_false(E.visible(E.objects[V.mark_objs.glow[1].go.s]))
		end)
	end)

	it("puts right a sprite that is displaced in y only", function()
		with_view(function(E, level_view)
			local o = level_view.create("#piece_factory")
			level_view.apply(o, "pieces_red", 200, 500, 0.1, 0.5, 0.5, 0, 0, nil, 1)
			go.set_position(vmath.vector3(200, 560, 0.1), o.go)
			assert_eq(level_view.audit_sprite(o, false), 1)
		end)
	end)

	it("puts right a sprite whose depth, size or numbers are not the ones put there", function()
		with_view(function(E, level_view)
			local o = level_view.create("#piece_factory")
			local function put() level_view.apply(o, "pieces_red", 200, 500, 0.1, 0.5, 0.4, 0, 0, nil, 1) end
			put()
			assert_eq(level_view.audit_sprite(o, false), 0, "a sprite as it was put")
			-- depth: a sprite that went behind the board (or in front of the HUD) is drawn somewhere else
			go.set_position(vmath.vector3(200, 500, 0.9), o.go)
			assert_eq(level_view.audit_sprite(o, false), 1, "z")
			put()
			assert_eq(level_view.audit_sprite(o, false), 0, "sent again, found right")
			-- size: either axis
			go.set_scale(vmath.vector3(0.5, 0.9, 1), o.go)
			assert_eq(level_view.audit_sprite(o, false), 1, "scale y")
			put()
			go.set_scale(vmath.vector3(0.9, 0.4, 1), o.go)
			assert_eq(level_view.audit_sprite(o, false), 1, "scale x")
			put()
			assert_eq(level_view.audit_sprite(o, false), 0)
			-- a number that is no number: it is not "far away" by any comparison, and the sprite is not drawn
			go.set_position(vmath.vector3(0 / 0, 500, 0.1), o.go)
			assert_eq(level_view.audit_sprite(o, false), 1, "NaN x")
			put()
			go.set_position(vmath.vector3(200, 500, 0 / 0), o.go)
			assert_eq(level_view.audit_sprite(o, false), 1, "NaN z")
		end)
	end)

	it("sends a sprite again after it has put it right (the next apply is not skipped)", function()
		with_view(function(E, level_view)
			local o = level_view.create("#piece_factory")
			level_view.apply(o, "pieces_red", 200, 500, 0.1, 0.5, 0.4, 0, 0, nil, 1)
			go.set_scale(vmath.vector3(2, 2, 1), o.go)
			assert_eq(level_view.audit_sprite(o, false), 1)
			level_view.apply(o, "pieces_red", 200, 500, 0.1, 0.5, 0.4, 0, 0, nil, 1)
			local s = go.get_scale(o.go)
			assert_near(s.x, 0.5, 1e-6)
			assert_near(s.y, 0.4, 1e-6)
		end)
	end)

	it("puts right a wire sprite the engine has somewhere else, and sends it again", function()
		with_view(function(E, level_view, V)
			local geom = require("client.level_geom")
			local cells = cells_of(5, function(c) c[7].wires = 1 end)
			local g = geom.new(5, 5, cells, { x0 = 0, y0 = 200, x1 = 500, y1 = 700 })
			V:set_wires(cells, g)
			assert_eq(V:audit({}, cells, g), 0)
			local w = V.wires[1].o
			local p = go.get_position(w.go)
			go.set_position(vmath.vector3(p.x + 60, p.y, p.z), w.go)
			assert_eq(V:audit({}, cells, g), 1, "the displaced wire sprite")
			assert_eq(V:stats().repaired, 1)
			local back = go.get_position(w.go)
			assert_near(back.x, p.x, 0.01)
			assert_near(back.y, p.y, 0.01)
			assert_eq(V:audit({}, cells, g), 0, "and it stays right: nothing to count at the next look")
			assert_eq(V:stats().repaired, 1)
		end)
	end)

	it("sends a displaced wire again even when the janitor is not given the cells", function()
		with_view(function(E, level_view, V)
			local geom = require("client.level_geom")
			local cells = cells_of(5, function(c) c[7].wires = 1 end)
			V:set_wires(cells, geom.new(5, 5, cells, { x0 = 0, y0 = 200, x1 = 500, y1 = 700 }))
			local w = V.wires[1].o
			local p = go.get_position(w.go)
			go.set_position(vmath.vector3(p.x, p.y + 50, p.z), w.go)
			assert_eq(V:audit({}), 1)
			local back = go.get_position(w.go)
			assert_near(back.y, p.y, 0.01)
		end)
	end)

	it("lays the wires out again when the core's wires are on other cells than the sprites", function()
		with_view(function(E, level_view, V)
			local geom = require("client.level_geom")
			local cells = cells_of(5, function(c) c[7].wires = 1 end)
			local g = geom.new(5, 5, cells, { x0 = 0, y0 = 200, x1 = 500, y1 = 700 })
			V:set_wires(cells, g)
			assert_false(V:wires_differ(cells, g))
			cells[7].wires, cells[9].wires = 0, 1
			assert_true(V:wires_differ(cells, g), "one wire of strength 1, but on another cell")
			assert_eq(V:audit({}, cells, g), 1)
			assert_false(V:wires_differ(cells, g))
		end)
	end)

	it("lays the wires out again when there are more wire sprites than wires", function()
		with_view(function(E, level_view, V)
			local geom = require("client.level_geom")
			local cells = cells_of(5, function(c) c[7].wires, c[8].wires = 1, 1 end)
			local g = geom.new(5, 5, cells, { x0 = 0, y0 = 200, x1 = 500, y1 = 700 })
			V:set_wires(cells, g)
			assert_eq(#V.wires, 2)
			cells[8].wires = 0 -- the first sprite still matches its cell; the second has no wire any more
			assert_true(V:wires_differ(cells, g), "a sprite too many")
			assert_eq(V:audit({}, cells, g), 1)
			assert_eq(#V.wires, 1)
		end)
	end)

	it("finds a displaced wire sprite on a board, repairs it once and stays quiet after that", function()
		with_board({ level = 22 }, function(B)
			frames(B, 70)
			local view = B.self.view
			assert_true(view:stats().wires > 1, "level 22 has wires")
			local w = view.wires[1].o
			local p0 = go.get_position(w.go)
			go.set_position(vmath.vector3(p0.x + 90, p0.y + 40, p0.z), w.go)
			something_happened(B)
			assert_true(wait_for_pass(B))
			frames(B, 3)
			local p1 = go.get_position(w.go)
			assert_near(p1.x, p0.x, 0.01)
			assert_near(p1.y, p0.y, 0.01)
			assert_eq(B.self.janitor_repairs, 1)
			something_happened(B)
			assert_true(wait_for_pass(B))
			assert_eq(B.self.janitor_repairs, 1, "the second look finds nothing")
			assert_eq(view:stats().repaired, 1)
			local R = L.leak_report(B, { rest = true })
			assert_eq(#R.leaks, 0, L.format(R))
		end)
	end)

	it("keeps a piece sprite whose hide the engine refused in the pool, and hides it at the next look", function()
		with_view(function(E, level_view, V)
			local function entry(id) return { id = id, image = "pieces_red", x = 100 * id, y = 500, z = 0.1, sx = 0.5, sy = 0.5,
				scale = 1, rot = 0, flash = 0, alpha = 1 } end
			V:sync({ entry(1), entry(2), entry(3) })
			assert_eq(V:stats().pieces, 3)
			local o2 = V.by_id[2]
			-- the engine refuses go.set_position once (the hide of the piece that leaves)
			local real = go.set_position
			local armed = true
			go.set_position = function(pos, id)
				if armed and id == o2.go then
					armed = false
					error("go.set_position: refused", 2)
				end
				return real(pos, id)
			end
			local ok = pcall(V.sync, V, { entry(1), entry(3) })
			go.set_position = real
			assert_false(ok, "the refusal is an error of the frame")
			assert_eq(V.by_id[2], nil, "the piece is gone from the view")
			assert_eq(#V.free, 1, "and its sprite is in the pool, not lost")
			assert_true(E.visible(E.objects[o2.go.s]), "still drawn: the engine did not move it")
			assert_eq(V:audit({ [1] = true, [3] = true }), 1, "the audit finds a pooled sprite that is drawn")
			assert_false(E.visible(E.objects[o2.go.s]), "and hides it")
		end)
	end)
end)

describe("the janitor: what counts as a write to the engine (the board is calm while the number stands still)", function()
	-- the janitor looks only when no call went to the engine for REST_FRAMES frames: every kind of change a sprite sends
	-- has to count, or a screen that changes would look still
	local function check(name, change)
		it("counts a change of " .. name .. " as exactly one write", function()
			with_view(function(E, level_view)
				local o = level_view.create("#piece_factory")
				local base = { "pieces_red", 200, 500, 0.1, 0.5, 0.5, 0, 0, nil, 1 }
				level_view.apply(o, unpack(base))
				local w0 = level_view.writes
				level_view.apply(o, unpack(base))
				assert_eq(level_view.writes, w0, "the same look is not a write")
				local look = {}
				for i = 1, 10 do look[i] = base[i] end
				change(look)
				level_view.apply(o, look[1], look[2], look[3], look[4], look[5], look[6], look[7], look[8], look[9], look[10],
					look[11], look[12], look[13])
				assert_eq(level_view.writes, w0 + 1, name .. " was sent to the engine and not counted")
			end)
		end)
	end
	check("the image", function(l) l[1] = "pieces_blue" end)
	check("the position", function(l) l[2] = 230 end)
	check("the depth", function(l) l[3] = 0.3 end)
	check("the scale", function(l) l[5], l[6] = 0.7, 0.7 end)
	check("the rotation", function(l) l[7] = 30 end)
	check("the flash", function(l) l[8] = 0.5 end)
	check("the clip line", function(l) l[9] = 640 end)
	check("the alpha", function(l) l[10] = 0.5 end)
	check("the tint", function(l) l[11], l[12], l[13] = 1, 0.5, 0.5 end)
end)

describe("the janitor: when it looks", function()
	it("waits twenty calm frames before it looks", function()
		with_board({ level = 1 }, function(B)
			local calm_from, looked_at
			for i = 1, 400 do
				B.step(1 / 60)
				if not calm_from and (B.self.rest_frames or 0) > 0 then calm_from = i end
				if (B.self.janitor_passes or 0) >= 1 then looked_at = i break end
			end
			assert_true(calm_from ~= nil and looked_at ~= nil, "it got calm and it looked")
			assert_true(looked_at - calm_from >= 19, "it looked after only " .. (looked_at - calm_from) .. " calm frames")
		end)
	end)

	it("counts the calm frames again from the last write", function()
		with_board({ level = 1 }, function(B)
			frames(B, 90)
			local passes = B.self.janitor_passes
			local level_view = require("client.level_view")
			local function write() -- one write to the engine: a piece is moved a pixel, and the next frame puts it back
				local _, o = next(B.self.view.by_id)
				level_view.apply(o, o.image, o.x + 1, o.y, o.z, o.sx, o.sy, o.rot, o.flash, nil, o.alpha)
			end
			write()
			B.step(1 / 60)
			B.step(1 / 60)
			something_happened(B)
			for _ = 1, 400 do
				B.step(1 / 60)
				if (B.self.rest_frames or 0) >= 6 then break end
			end
			assert_true((B.self.rest_frames or 0) >= 6, "a few calm frames")
			assert_eq(B.self.janitor_passes, passes, "the write started the count again")
			write()
			for i = 1, 15 do
				B.step(1 / 60)
				assert_eq(B.self.janitor_passes, passes, "it looked after only " .. i .. " calm frames since the last write")
			end
		end)
	end)

	it("does not look while only particles play", function()
		with_board({ level = 1 }, function(B)
			frames(B, 90)
			local passes = B.self.janitor_passes
			something_happened(B)
			B.self.vfx:play({ { kind = "burst", fx = "confetti", x = 300, y = 600, color = "#FFFFFF", count = 12, at = 0 } })
			for i = 1, 30 do
				B.step(1 / 60)
				assert_eq(B.self.janitor_passes, passes, "it looked while particles played (frame " .. i .. ")")
				if B.self.vfx.live == 0 then break end
			end
			assert_true(B.self.vfx.live > 0, "the particles were still playing (the test would be empty otherwise)")
		end)
	end)

	it("looks once more after a swap that fails (no effect played, the core's rev moved)", function()
		with_board({ level = 1 }, function(B)
			frames(B, 90)
			local passes = B.self.janitor_passes
			local game, W, H = B.game(), B.self.W, B.self.H
			local done = false
			for y = 1, H do
				for x = 1, W - 1 do
					if not done and game:can_swap({ x, y }, { x + 1, y }) == "fail" then
						done = true
						assert_true(B.self.session:qa("swap", { x, y, x + 1, y }).ok)
					end
				end
			end
			assert_true(done, "a swap that fails")
			local played = B.self.vfx.played
			assert_true(wait_for_pass(B, 300), "the janitor looked again")
			assert_eq(B.self.vfx.played, played, "and no effect had played")
			assert_true(B.self.janitor_passes > passes)
		end)
	end)

	it("looks once more when a pick ends, however it ends (a selection that is let go changes nothing in the core)", function()
		with_board({ level = 1 }, function(B)
			frames(B, 90)
			local self = B.self
			local passes = self.janitor_passes
			local p
			for _, q in ipairs(B.game():pieces()) do
				if q.kind == "regular" and q.state == "idle" and not q.pinned and not q.wired then
					p = q
					break
				end
			end
			assert_true(p ~= nil, "a piece to pick")
			local lx, ly = self.geom:center(p.x, p.y)
			local function tap()
				B.touch("down", lx, ly)
				B.step(1 / 60)
				B.touch("up", lx, ly)
			end
			tap() -- picked: the selection pulses, so the board is not calm
			assert_true(self.input.selected ~= nil, "the piece is selected")
			frames(B, 60)
			assert_eq(self.janitor_passes, passes, "no look while the selection pulses")
			local rev = self.session.rev
			tap() -- let go: nothing happens in the core, but the board is calm again and the pick changed
			assert_eq(self.input.selected, nil)
			assert_true(wait_for_pass(B, 200), "the janitor looks after the pick")
			assert_eq(self.session.rev, rev, "(the core had nothing to say about it)")
			assert_eq(self.janitor_repairs or 0, 0)
		end)
	end)

	it("looks every ten seconds of board time even when the frames are few (a slow phone)", function()
		with_board({ level = 1 }, function(B)
			frames(B, 90)
			-- 10 frames a second: 600 frames would be a minute; the hint wobbles in between, with gaps of 24 frames
			local looked = B.self.janitor_passes
			for _ = 1, 250 do B.step(0.1) end
			assert_true(B.self.janitor_passes > looked, "passes: " .. looked .. " -> " .. B.self.janitor_passes)
			assert_true(B.self.frames - B.self.janitor_frame < 600, "and it was not the count of frames that made it look")
			assert_eq(B.self.janitor_repairs or 0, 0)
		end)
	end)

	it("reports the janitor in the board stats of the QA command level_stats", function()
		with_board({ level = 1 }, function(B)
			frames(B, 90)
			local res = require("client.qa_bridge").execute("level_stats")
			assert_true(res.ok)
			assert_true(res.board ~= nil and res.board.janitor ~= nil, "board.janitor")
			assert_eq(res.board.janitor.passes, B.self.janitor_passes)
			assert_eq(res.board.janitor.repairs, 0)
		end)
	end)
end)

describe("the janitor: the effects' side", function()
	local geom = require("client.level_geom")

	it("takes back an effect sprite nobody holds, and counts it once", function()
		local E = stub.install({})
		local ok, err = pcall(function()
			local level_vfx = require("client.level_vfx")
			local level_view = require("client.level_view")
			local cells = {}
			for i = 1, 81 do cells[i] = { exists = true } end
			local vfx = level_vfx.new({ geom = geom.new(9, 9, cells, { x0 = 0, y0 = 200, x1 = 720, y1 = 1050 }) })
			assert_eq(vfx:audit(), 0, "nothing to put right")
			local o = vfx:_sprite("glow") -- taken, and the record that held it is lost
			level_view.apply(o, "fx_flash", 300, 600, 0.4, 1, 1, 0, 0, nil, 0.8)
			assert_true(E.visible(E.objects[o.go.s]))
			assert_eq(vfx:audit(), 1, "one repair for one lost sprite")
			assert_true(o.pooled, "it is in its pool")
			assert_false(E.visible(E.objects[o.go.s]), "and out of sight")
			assert_eq(vfx:stats().repaired, 1)
			assert_eq(#vfx.pool.glow, 1)
		end)
		stub.restore()
		if not ok then error(err, 0) end
	end)
end)
