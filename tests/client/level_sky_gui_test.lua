-- The living sky behind the level board on the strict Defold stub (screens/level/level_bg.gui_script, client/level_sky.lua):
-- the clouds that drift, the picture of the level's district, and the stillness with reduced motion.

local stub = require("tests.client.level_defold_stub")
local app = require("client.app")
local assets = require("client.assets")
local sky = require("client.level_sky")
local i18n = require("client.i18n")
local save_io = require("client.save_io")
local analytics = require("client.services.analytics")
local H = require("tests.meta.helper")

local DT = 1 / 60

local function boot_app()
	analytics.init({ strict = true })
	app.init({
		districts = H.districts(), store = save_io.new(save_io.memory_backend()), seed = 42,
		now = H.T0, clock = function() return H.T0 end, sys_language = "en",
	})
	i18n.set_language("en")
end

describe("screens/level/level_bg.gui_script: the sky", function()
	-- fn(c): c.clouds() = the live cloud nodes, c.step(n), c.start(level) = the screen is opened for that level
	local function with_sky(level, fn)
		local stubE = stub.install({})
		local ok, err = pcall(function()
			boot_app()
			app.params = { level = level }
			stubE.use_gui("/screens/level/level_bg.gui")
			local script = stub.load_script("screens/level/level_bg.gui_script")
			local self = {}
			script.init(self)
			local c = { E = stubE, self = self }
			function c.clouds()
				local out = {}
				for _, n in ipairs(stubE.gui.nodes) do
					if not n.dead and n.anim == "fx_cloud" then out[#out + 1] = n end
				end
				return out
			end
			function c.step(n)
				for _ = 1, n or 1 do
					stubE.advance(DT)
					script.update(self, DT)
				end
			end
			local ok2, err2 = pcall(fn, c)
			pcall(script.final, self)
			if not ok2 then error(err2, 0) end
		end)
		app.params = {}
		stub.restore()
		if not ok then error(err, 0) end
	end

	local function xs(nodes)
		local out = {}
		for i, n in ipairs(nodes) do out[i] = n.pos.x end
		return out
	end

	it("draws the clouds under the board and moves them to the right", function()
		with_sky(7, function(c)
			c.step(1)
			local clouds = c.clouds()
			assert_eq(#clouds, #sky.CLOUDS)
			local before = xs(clouds)
			c.step(120) -- two seconds
			local after = xs(clouds)
			for i = 1, #clouds do
				assert_true(after[i] > before[i], "cloud " .. i .. " drifts right")
				assert_true(math.abs((after[i] - before[i]) - sky.CLOUDS[i].speed * 2) < 0.5, "at its own speed")
			end
		end)
	end)

	it("the clouds are the first thing over the backdrop: the garland and the board are drawn after them", function()
		with_sky(7, function(c)
			c.step(1)
			local order, cloud_at, bunting_at = {}, nil, nil
			for i, n in ipairs(c.E.gui.nodes) do
				order[i] = n
				if not n.dead and n.anim == "fx_cloud" and not cloud_at then cloud_at = i end
				if not n.dead and n.anim == "ui_bunting" then bunting_at = i end
			end
			assert_true(cloud_at ~= nil and bunting_at ~= nil)
			assert_true(cloud_at < bunting_at, "the garland hangs over the clouds")
		end)
	end)

	it("stand still with reduced motion, and move again when it is off", function()
		with_sky(7, function(c)
			app.set_setting("reduced_motion", true)
			c.step(2)
			local still = xs(c.clouds())
			c.step(180)
			assert_same(xs(c.clouds()), still)
			app.set_setting("reduced_motion", false)
			c.step(120)
			assert_true(xs(c.clouds())[1] > still[1])
		end)
	end)

	it("a level of any district has a sky; a level number outside every district gets the common one", function()
		for _, level in ipairs({ 1, 21, 161 }) do
			with_sky(level, function(c)
				c.step(1)
				assert_eq(#c.clouds(), #sky.CLOUDS, "level " .. level)
			end)
		end
		-- an evening district with its own picture: stars instead of clouds
		with_sky(300, function(c)
			c.step(1)
			assert_eq(#c.clouds(), 0)
			local stars = 0
			for _, n in ipairs(c.E.gui.nodes) do
				if not n.dead and n.anim == "fx_spark" then stars = stars + 1 end
			end
			assert_eq(stars, sky.STARS)
		end)
		with_sky(9999, function(c)
			c.step(1)
			assert_eq(#c.clouds(), #sky.CLOUDS)
		end)
	end)

	it("changes the theme when the level becomes known (the board's level wins over the screen's params)", function()
		with_sky(nil, function(c)
			c.step(1)
			assert_eq(c.self.theme_id, "backgrounds/level_bg|clouds|")
			app.params = { level = 161 }
			c.step(1)
			assert_eq(c.self.theme_id, "districts/bazaar/level_bg|clouds|bazaar")
			assert_eq(#c.clouds(), #sky.CLOUDS, "the old clouds are gone, the new ones stand in their place")
		end)
	end)

	it("keeps the registry honest: the sprites of the sky exist and the common picture is a loose file", function()
		assert_true(assets.has_image("fx/cloud"))
		local e = assets.image("backgrounds/level_bg")
		assert_true(e ~= nil and e.file ~= nil)
	end)
end)
