-- The living rooms of the town (content/rooms.json, screens/town/life.lua, the layers and the crossfade of
-- screens/town/scene.lua) on the strict Defold GUI stub: every district has at least three kinds of living details
-- inside the node budget, details wait for their task, the day / concert look fades, paging slides the layers by
-- their own factors, a restored item celebrates, nothing is left behind, reduced motion stands still.

local G = require("tests.client.meta_gui_helper")
local json = require("tools.lib.json")

local DISTRICTS = { "cafe", "jazz", "square", "stadium", "garage" }

local function rooms()
	local f = assert(io.open("content/rooms.json", "rb"))
	local t = f:read("*a")
	f:close()
	return json.decode(t)
end

local function everything(app)
	G.give_stars(app, 3000)
	for _, d in ipairs(DISTRICTS) do G.build_tasks(app, d) end
end

local function to_district(c, did)
	for _ = 1, 6 do
		if c.app.ui.district == did and not c.app.ui.sliding then return end
		local t = c.app.ui.targets.nav_prev
		local idx = c.app.ui.nav.index
		local want
		for i, d in ipairs(DISTRICTS) do if d == did then want = i end end
		local tn = (want < idx) and c.app.ui.targets.nav_prev or c.app.ui.targets.nav_next
		c.tap(tn.x, tn.y)
		c.run(1.2)
	end
end

local function life_of(c)
	local scene = c.town.self.t.scene
	return scene.room and scene.room.life, scene
end

describe("content/rooms.json", function()
	it("gives each of the five districts at least three kinds of living details, inside the budget", function()
		local d = rooms()
		local KINDS = { blink = true, steam = true, notes = true, motes = true, shaft = true, bokeh = true }
		local items = {}
		local lay = json.decode((function() local f = assert(io.open("content/district_layouts.json", "rb")); local t = f:read("*a"); f:close(); return t end)())
		for _, did in ipairs(DISTRICTS) do
			local spec = assert(d.districts[did], did)
			local kinds, n = {}, 0
			for _, det in ipairs(spec.details) do
				assert_true(KINDS[det.kind], did .. ": kind " .. tostring(det.kind))
				assert_true(({ mid = true, over = true, fg = true })[det.layer or "mid"], did .. ": layer")
				kinds[det.kind] = true
				if det.item then assert_true(lay[did].items[det.item] ~= nil, did .. ": item " .. det.item) end
				if det.view then assert_true(det.view == "day" or det.view == "concert") end
				n = n + 1
			end
			local distinct = 0
			for _ in pairs(kinds) do distinct = distinct + 1 end
			assert_true(distinct >= 3, did .. " kinds " .. distinct)
			assert_true(n >= 5, did .. " details " .. n)
		end
		assert_true(d.budget <= 60)
		for _, name in ipairs({ "bg", "mid", "items", "fg" }) do assert_true(d.parallax[name] ~= nil, name) end
		assert_true(d.parallax.fg > d.parallax.items and d.parallax.items > d.parallax.mid and d.parallax.mid >= d.parallax.bg)
	end)
end)

describe("town rooms on the stub", function()
	it("every district in both looks stays inside the node budget and has living details", function()
		G.with_town({ setup = everything }, function(c)
			local budget = rooms().budget
			local base
			for _, did in ipairs(DISTRICTS) do
				to_district(c, did)
				assert_eq(c.app.ui.district, did)
				for _, view in ipairs({ "day", "concert" }) do
					if c.app.meta:view(did) ~= view then
						local t = c.app.ui.targets.view
						c.tap(t.x, t.y)
						c.run(1)
					end
					local life = life_of(c)
					assert_true(life:count() >= 3, did .. "/" .. view .. " life nodes " .. life:count())
					assert_true(life:count() <= budget, did .. "/" .. view .. " life nodes " .. life:count())
					local st = c.town:stats()
					assert_true(st.nodes < 330, did .. "/" .. view .. " nodes " .. st.nodes)
					assert_true(st.peak < 380, did .. "/" .. view .. " peak nodes " .. st.peak)
					assert_true(st.anims < 200, did .. "/" .. view .. " animations " .. st.anims)
					assert_eq(#c.E.audit(), 0)
				end
			end
		end)
	end)

	it("a detail waits for its task: only the ambient lights at first, the rest when the task is restored", function()
		G.with_town({}, function(c)
			local life, scene = life_of(c)
			local before = life:count()
			assert_true(before >= 2 and before < 20, "ambient only: " .. before)
			assert_true(life.pending.turntable ~= nil)
			G.give_stars(c.app, 50)
			local task = require("client.views").task(c.app.meta)
			c.app.ui.targets.card = c.app.ui.targets.card
			local ok = c.app.meta:district("cafe").tasks[1].id
			assert_eq(ok, "turntable")
			-- the player builds the first task through the card
			local t = c.app.ui.targets.build or c.app.ui.targets.task
			assert_true(t ~= nil, "no build target")
			c.tap(t.x, t.y)
			c.run(8)
			local life2 = life_of(c)
			assert_true(life2:count() > before, "after the task: " .. life2:count() .. " vs " .. before)
			assert_true(life2.pending.turntable == nil)
		end)
	end)

	it("the day and concert looks cross-fade: the new picture rises while the old one waits, then one picture is left", function()
		G.with_town({}, function(c)
			local function bgs()
				local n = 0
				for _, key in ipairs(c.town:loose_images()) do
					if key:find("^districts/cafe/bg") then n = n + 1 end
				end
				return n
			end
			local t = c.app.ui.targets.view
			c.tap(t.x, t.y)
			c.step(8)
			local _, scene = life_of(c)
			assert_true(scene.fading ~= nil, "the old room is still there during the fade")
			assert_eq(c.app.ui.view, "concert")
			local r = scene.room
			assert_true(r.life == nil, "the details of the new room wait for the fade")
			c.run(1)
			assert_true(scene.fading == nil)
			assert_true(scene.room.life ~= nil)
			assert_eq(bgs(), 1)
			-- a second toggle in the middle of a fade is safe
			c.tap(t.x, t.y)
			c.step(5)
			c.tap(t.x, t.y)
			c.run(1.5)
			assert_true(scene.fading == nil)
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("paging slides the layers by their own factors and they all come to rest", function()
		G.with_town({ setup = function(app) G.build_tasks(app, "cafe") end }, function(c)
			local scene = c.town.self.t.scene
			local t = c.app.ui.targets.nav_prev
			c.tap(t.x, t.y)
			c.step(6)
			local R = scene.room
			local gx = function(node) return c.town:ctx(function() return gui.get_position(node).x end) end
			local xs = { mid = gx(R.parts.mid), items = gx(R.parts.items), fg = gx(R.parts.fg) }
			assert_true(xs.mid < 0 or xs.mid > 0, "layers are offset while sliding")
			local sign = xs.items > 0 and 1 or -1
			assert_true(xs.fg * sign > xs.items * sign and xs.items * sign > xs.mid * sign, "the nearer the layer the farther it is")
			for _ = 1, 120 do if not c.app.ui.sliding then break end c.step(1) end
			c.run(0.5)
			assert_near(gx(R.parts.mid), 0, 0.01)
			assert_near(gx(R.parts.items), 0, 0.01)
			assert_near(gx(R.parts.fg), 0, 0.01)
			assert_eq(#c.E.audit(), 0)
		end)
	end)

	it("restoring an item makes a wave of light, flares the lights and leaves nothing behind", function()
		G.with_town({}, function(c)
			local life, scene = life_of(c)
			local nodes0 = c.town:stats().nodes
			c.town:ctx(function() life:celebrate(360, 700) end)
			c.step(2)
			assert_true(c.town:stats().nodes > nodes0, "the wave exists")
			c.run(2)
			assert_eq(c.town:stats().nodes, nodes0)
		end)
	end)

	it("reduced motion: no moving details, the lights stand still, the slide is immediate", function()
		G.with_town({ setup = function(app) app.set_setting("reduced_motion", true) end }, function(c)
			local life = life_of(c)
			assert_true(life.reduced)
			for _, e in ipairs(life.blinks) do
				local a = c.town:ctx(function() return gui.get_color(e.node).w end)
				assert_true(a >= e.lo - 1e-6 and a <= e.hi + 1e-6)
			end
			local n = life:count()
			c.run(2)
			assert_eq(life:count(), n)
			assert_eq(#c.E.audit(), 0)
		end)
	end)
end)
