local level_plates = require("client.level_plates")
local level_anim = require("client.level_anim")
local geom = require("client.level_geom")
local core = require("core.game")

-- 6x6 board with 100 px cells: cell (x, y) centre = (x*100 - 50 + 18, 624 - 12 - (y*100 - 50))
local function G()
	local cells = {}
	for i = 1, 36 do cells[i] = { exists = true } end
	return geom.new(6, 6, cells, { x0 = 0, y0 = 0, x1 = 636, y1 = 624 })
end

local function piece(id, x, y, extra)
	local p = { id = id, x = x, y = y, kind = "regular", color = "red", state = "idle", offx = 0, offy = 0,
		hidden = false, pinned = false }
	for k, v in pairs(extra or {}) do p[k] = v end
	return p
end

local function blocker(id, x, y, item, state)
	return piece(id, x, y, { kind = "blocker", item = item, hp = 1, color = false, state = state or "idle" })
end

local function plain_cells()
	local cells = {}
	for i = 1, 36 do cells[i] = { exists = true, wires = 0 } end
	return cells
end

-- One frame of the animation and the plates at time t: the plate list and how many there are.
local function step(P, A, pieces, cells, g, t, tick, list)
	list = list or {}
	A:frame(pieces, tick or t * 60, t)
	local n = P:fill(list, 0, pieces, cells, g, A, t)
	return list, n
end

-- The plates once their fade-in is over (they start at 0 so a board that blooms in does not show them early).
local function settled(P, A, pieces, cells, g, t)
	step(P, A, pieces, cells, g, t)
	return step(P, A, pieces, cells, g, t + 1)
end

describe("client.level_plates: what cannot be moved", function()
	it("calls blockers and wired pieces fixed, and nothing else", function()
		for _, item in ipairs({ "record_box", "concrete", "noise", "balloon", "column" }) do
			assert_eq(level_plates.kind(blocker(1, 2, 2, item), false), "blocker", item)
			assert_eq(level_plates.kind(blocker(1, 2, 2, item), true), "blocker", item)
		end
		assert_eq(level_plates.kind(piece(1, 2, 2), true), "wired")
		assert_eq(level_plates.kind(piece(1, 2, 2), false), nil)
		assert_eq(level_plates.kind(piece(1, 2, 2), nil), nil)
		assert_eq(level_plates.kind(piece(1, 2, 2, { kind = "special", special = "riff" }), false), nil)
		assert_eq(level_plates.kind(piece(1, 2, 2, { kind = "mic" }), false), nil)
		assert_eq(level_plates.kind(nil, false), nil)
		-- a piece that is falling or pinned is not fixed: it refuses for a moment, it does not sit on a plate
		assert_eq(level_plates.kind(piece(1, 2, 2, { state = "fall" }), false), nil)
		assert_eq(level_plates.kind(piece(1, 2, 2, { pinned = true }), false), nil)
	end)

	it("agrees with the core on every object of the levels that have fixed things", function()
		-- the plate language is only honest if the core really refuses what the client marks: every object of the
		-- levels with record boxes (10), wires (22), concrete (40), noise (50), balloons (65) and the column (90) is
		-- tapped and swapped for real; microphones (30) and the rest are never refused as fixed
		local function check(level_n)
			local f = assert(io.open(string.format("content/levels/level_%04d.json", level_n), "rb"))
			local text = f:read("*a")
			f:close()
			local level = assert(core.load_level(text))
			local game = assert(core.new(level, { seed = 7 }))
			game:run_to_rest()
			local cells = game:cells()
			local W, H = level.W, level.H
			local list = game:pieces()
			local at = {}
			for _, p in ipairs(list) do at[(p.y - 1) * W + p.x] = p end
			local fixed, moving = 0, 0
			for _, p in ipairs(list) do
				local c = cells[(p.y - 1) * W + p.x]
				local kind = level_plates.kind(p, (c.wires or 0) > 0)
				if kind then
					fixed = fixed + 1
					-- the core refuses a tap on it and a swap with any neighbour that has a cell
					local ok, why = game:input({ type = "tap", at = { p.x, p.y } })
					assert_false(ok, "level " .. level_n .. ": a tap on a fixed " .. kind .. " was taken")
					assert_eq(why, "not_movable")
					for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
						local nx, ny = p.x + d[1], p.y + d[2]
						if nx >= 1 and nx <= W and ny >= 1 and ny <= H and cells[(ny - 1) * W + nx].exists then
							local ok2, why2 = game:input({ type = "swap", from = { p.x, p.y }, to = { nx, ny } })
							assert_false(ok2, "level " .. level_n .. ": a swap with a fixed " .. kind .. " was taken")
							assert_eq(why2, "not_movable")
						end
					end
				elseif p.kind == "regular" or p.kind == "mic" then
					moving = moving + 1
					-- a free piece is never refused by a swap with a free neighbour
					for _, d in ipairs({ { 1, 0 }, { 0, 1 } }) do
						local other = p.x + d[1] <= W and at[(p.y + d[2] - 1) * W + p.x + d[1]] or nil
						if other and (other.kind == "regular" or other.kind == "mic")
							and (cells[(other.y - 1) * W + other.x].wires or 0) == 0 then
							assert_true(game:can_swap({ p.x, p.y }, { other.x, other.y }) ~= "reject",
								"level " .. level_n .. ": a free pair is refused")
						end
					end
				end
			end
			return fixed, moving
		end
		for _, n in ipairs({ 10, 22, 40, 50, 65, 90 }) do
			local fixed, moving = check(n)
			assert_true(fixed > 0, "level " .. n .. " has fixed things")
			assert_true(moving > 0, "level " .. n .. " has pieces that move")
		end
		local fixed, moving = check(30)
		assert_true(moving > 0)
		assert_eq(fixed, 0, "level 30 (microphones) has nothing fixed")
	end)

	it("tells the first refusal of each kind once per session", function()
		level_plates.reset()
		assert_true(level_plates.first("blocker"))
		assert_false(level_plates.first("blocker"))
		assert_true(level_plates.first("wired"))
		assert_false(level_plates.first("wired"))
		assert_false(level_plates.first(nil))
		level_plates.reset()
		assert_true(level_plates.first("blocker"))
		level_plates.reset()
	end)

	it("has a toast text in both languages for each kind", function()
		local i18n = require("client.i18n")
		for _, kind in ipairs({ "blocker", "wired" }) do
			local key = level_plates.TOAST[kind]
			assert_true(key ~= nil, kind)
			for _, lang in ipairs({ "en", "ru" }) do
				i18n.set_language(lang)
				local text = i18n.t(key)
				assert_true(type(text) == "string" and #text > 10 and text ~= key, key .. " " .. lang)
			end
		end
		i18n.set_language("en")
		assert_eq(i18n.t(level_plates.TOAST.blocker), "Can't be moved — break it with matches next to it")
		i18n.set_language("ru")
		assert_eq(i18n.t(level_plates.TOAST.blocker), "Не двигается — разбей совпадениями рядом")
		i18n.set_language("en")
	end)
end)

describe("client.level_plates: the plates", function()
	it("puts one plate under every blocker and wired piece and none under the rest", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local P = level_plates.new()
		local cells = plain_cells()
		cells[(2 - 1) * 6 + 5].wires = 2 -- a piece under wires at (5, 2)
		local pieces = {
			piece(1, 1, 1), piece(2, 2, 1, { kind = "special", special = "sub" }), piece(3, 3, 1, { kind = "mic" }),
			blocker(4, 1, 2, "record_box"), blocker(5, 2, 2, "concrete"), blocker(6, 3, 2, "noise"),
			blocker(7, 4, 2, "balloon"), piece(8, 5, 2), piece(9, 6, 2, { state = "fall", offy = 900 }),
		}
		local list, n = settled(P, A, pieces, cells, g, 5)
		assert_eq(n, 5) -- four blockers and the wired piece
		assert_eq(P:count(), 5)
		for _, c in ipairs({ { 1, 2 }, { 2, 2 }, { 3, 2 }, { 4, 2 }, { 5, 2 } }) do
			local lx, ly = g:center(c[1], c[2])
			local found = false
			for i = 1, n do
				if math.abs(list[i].x - lx) < 1e-6 and math.abs(list[i].y - ly) < 1e-6 then found = true end
			end
			assert_true(found, "a plate at " .. c[1] .. "," .. c[2])
		end
		for i = 1, n do
			local m = list[i]
			assert_eq(m.image, "board_plate")
			assert_eq(m.glow, false)
			assert_eq(m.w, 100)
			assert_eq(m.h, 100)
			assert_eq(m.iw, 160)
			assert_true(m.z < level_anim.Z.blocker, "a plate lies under the blockers")
			assert_true(m.z < 0.05, "and under the glow marks")
			assert_eq(m.alpha, 1)
		end
	end)

	it("gives the 2x2 column one plate of twice the size, centred under it", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local P = level_plates.new()
		local pieces = { blocker(1, 3, 3, "column"), piece(2, 1, 1) }
		local list, n = settled(P, A, pieces, plain_cells(), g, 5)
		assert_eq(n, 1)
		local cx, cy = g:center(3, 3)
		assert_near(list[1].x, cx + 50, 1e-9)
		assert_near(list[1].y, cy - 50, 1e-9)
		assert_eq(list[1].w, 200)
		assert_eq(list[1].h, 200)
	end)

	it("follows the shake of the screen", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local P = level_plates.new()
		local pieces = { blocker(1, 2, 2, "record_box") }
		settled(P, A, pieces, plain_cells(), g, 5)
		local list = {}
		A:frame(pieces, 400, 6.5)
		P:fill(list, 0, pieces, plain_cells(), g, A, 6.5, 6, -4)
		local cx, cy = g:center(2, 2)
		assert_near(list[1].x, cx + 6, 1e-9)
		assert_near(list[1].y, cy - 4, 1e-9)
	end)

	it("makes no garbage while the same things stay on the board: the same mark tables every frame", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local P = level_plates.new()
		local pieces = { blocker(1, 2, 2, "record_box"), blocker(2, 4, 4, "column"), piece(3, 1, 1) }
		local list1 = settled(P, A, pieces, plain_cells(), g, 5)
		local a, b = list1[1], list1[2]
		assert_true(a ~= nil and b ~= nil)
		for k = 1, 30 do
			local list2, n = step(P, A, pieces, plain_cells(), g, 7 + k / 60)
			assert_eq(n, 2)
			assert_true(list2[1] == a and list2[2] == b, "the plate tables are reused")
		end
	end)

	it("blooms in with its object, and not before it", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local P = level_plates.new()
		local pieces = { blocker(1, 2, 2, "record_box"), piece(2, 1, 1) }
		A:intro(pieces, 0) -- the whole board pops in as a wave from the bottom left
		local _, n0 = step(P, A, pieces, plain_cells(), g, 0)
		assert_eq(n0, 0) -- the box has not appeared yet, neither has its plate
		local seen_partial = false
		local last = 0
		for k = 1, 90 do
			local list, n = step(P, A, pieces, plain_cells(), g, k / 60)
			if n == 1 then
				assert_true(list[1].alpha >= last - 1e-9, "the plate only grows while it blooms")
				if list[1].alpha < 1 then seen_partial = true end
				last = list[1].alpha
			end
		end
		assert_true(seen_partial, "it grew in over some frames")
		assert_eq(last, 1)
	end)

	it("shrinks away with a destroyed blocker and does not come back", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local P = level_plates.new()
		local box = blocker(1, 2, 2, "record_box")
		local pieces = { box }
		settled(P, A, pieces, plain_cells(), g, 2)
		local t0 = 4
		step(P, A, pieces, plain_cells(), g, t0, 100)
		A:event({ type = "clear", id = 1, x = 2, y = 2, t = 100, cause = "effect", kind = "blocker" }, t0)
		box.state = "clear"
		local min_alpha = 1
		for u = 0, 12 do
			local list, n = step(P, A, pieces, plain_cells(), g, t0 + u / 60, 100 + u)
			if n == 1 then min_alpha = math.min(min_alpha, list[1].alpha) end
		end
		assert_true(min_alpha < 0.2, "the plate shrank with the box: " .. min_alpha)
		-- the box leaves the board: the plate has nothing left to fade, and nothing pops back
		pieces = {}
		for u = 13, 40 do
			local _, n = step(P, A, pieces, plain_cells(), g, t0 + u / 60, 100 + u)
			assert_eq(n, 0, "frame " .. u)
		end
	end)

	it("fades out where it stood when the wires are cut", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local P = level_plates.new()
		local cells = plain_cells()
		cells[(2 - 1) * 6 + 3].wires = 1
		local pieces = { piece(1, 3, 2) }
		local list, n = settled(P, A, pieces, cells, g, 5)
		assert_eq(n, 1)
		assert_eq(list[1].alpha, 1)
		local cx, cy = g:center(3, 2)
		cells[(2 - 1) * 6 + 3].wires = 0 -- freed
		local prev, steps = 1, 0
		for k = 1, 30 do
			local l2, n2 = step(P, A, pieces, cells, g, 6 + k / 60)
			if n2 == 0 then break end
			assert_eq(n2, 1)
			assert_near(l2[1].x, cx, 1e-9)
			assert_near(l2[1].y, cy, 1e-9)
			assert_true(l2[1].alpha < prev + 1e-9, "only fades")
			prev = l2[1].alpha
			steps = steps + 1
		end
		assert_true(steps >= 5 and steps <= 15, "it takes " .. steps .. " frames to go")
		local _, n_end = step(P, A, pieces, cells, g, 8)
		assert_eq(n_end, 0)
	end)

	it("waits for a piece that the noise is creeping over to turn grey", function()
		local g = G()
		local A = level_anim.new({ geom = g })
		local P = level_plates.new()
		-- the object is noise already (the core turned it), but it is still drawn as the piece it was
		local noise = blocker(1, 2, 2, "noise")
		A:frame({ piece(1, 2, 2) }, 10, 1)
		A:event({ type = "noise_spread", id = 1, x = 2, y = 2, t = 10 }, 1)
		local _, n = step(P, A, { noise }, plain_cells(), g, 1.0, 10)
		assert_eq(n, 0)
		local _, n2 = step(P, A, { noise }, plain_cells(), g, 1.1, 16)
		assert_eq(n2, 0, "still waiting at 0.1 s")
		step(P, A, { noise }, plain_cells(), g, 1.5, 40)
		local list, n3 = step(P, A, { noise }, plain_cells(), g, 1.7, 52)
		assert_eq(n3, 1, "the plate is there once the noise has turned the piece grey")
		assert_true(list[1].alpha > 0)
	end)

	it("skips what is hidden and tolerates a missing animation, cells or board", function()
		local g = G()
		local P = level_plates.new()
		local box = blocker(1, 2, 2, "record_box")
		box.hidden = true
		assert_eq(P:fill({}, 0, { box }, plain_cells(), g, nil, 5), 0)
		box.hidden = false
		local list = {}
		assert_eq(P:fill(list, 0, { box }, nil, g, nil, 5), 0) -- it starts at 0 and grows in
		assert_eq(P:fill(list, 0, { box }, nil, g, nil, 5 + level_plates.FADE_IN + 0.01), 1)
		assert_eq(list[1].alpha, 1)
		assert_eq(P:fill({}, 0, nil, nil, nil, nil, 0), 0)
		assert_eq(P:fill({}, 3, { box }, nil, nil, nil, 0), 3)
	end)
end)
