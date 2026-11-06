-- Fixtures for the tests that run the meta GUI scripts on the strict stub (not a test file itself).
--
--   local G = require("tests.client.meta_gui_helper")
--   G.with_town({language = "en", window = {720, 1280}, setup = function(app) G.win(app, 3) end},
--     function(c)               -- c = {E, app, overlay, town, step(n), run(seconds), tap(lx, ly)}
--       c.town:tap_text("Level 4")
--     end)

local town_stub = require("tests.client.town_defold_stub")

local G = {}

-- Wins `n` levels through the meta (no board): stars, coins; the level chests are taken at once (flow.debug_win;
-- a chest left waiting, as after a win on the board, needs flow.debug_win(3, true)).
function G.win(app, n)
	local flow = require("client.flow")
	local res
	for _ = 1, n or 1 do res = assert(flow.debug_win(3)) end
	return res
end

-- A star balance for tasks (the meta only pays stars for wins: this is test setup).
function G.give_stars(app, n)
	app.meta:_change("test_stars", { { "stars", n } })
	app.commit("test")
end

-- Builds the first `count` tasks of a district straight through the meta (all of them without count).
function G.build_tasks(app, district, count)
	local d = app.meta:district(district)
	local need = 0
	for i, t in ipairs(d.tasks) do
		if not t.done and (count == nil or i <= count) then need = need + t.cost end
	end
	G.give_stars(app, need)
	for i, t in ipairs(d.tasks) do
		if not t.done and (count == nil or i <= count) then assert(app.meta:complete_task(district, t.id)) end
	end
	app.commit("test")
end

-- Boots the stub and the app on the real content, creates the overlay (faded in) and the town, and
-- runs fn(c). opts: {window, safe, language, setup = fn(app) before the town exists, town = false
-- (no town script)}. Always shuts the stub down.
function G.with_town(opts, fn)
	opts = opts or {}
	local E = town_stub.boot(opts)
	local ok, err = pcall(function()
		local app = require("client.app")
		local c = { E = E, app = app }
		c.overlay = E.script("main/overlay.gui_script", "/main/overlay.gui", { url = "main:/overlay#overlay" })
		c.overlay:init()
		c.overlay:message("fade_in", { duration = 0.25 }, msg.url("main:/app"))
		if opts.setup then opts.setup(app, c) end
		if opts.town ~= false then
			c.town = E.script("screens/town/town.gui_script", "/screens/town/town.gui")
			c.town:init()
			app.set_screen("town", {})
		end
		E.step(30)
		function c.step(n) E.step(n) end
		function c.run(seconds) E.run(seconds) end
		function c.tap(lx, ly) return E.tap(lx, ly) end
		fn(c)
	end)
	town_stub.shutdown()
	if not ok then error(err, 0) end
end

-- The window panel on the screen (the biggest white box that is not a full-screen backdrop) and every visible node
-- of it that sticks out of it, or out of the 720x1280 design area (that is inside every window shape). The title
-- ribbon (up to `up` px above the panel, but inside the area) is allowed outside the panel. Logical px, tol of slack.
-- Returns the list of complaints ("text/node: how far") and the panel rectangle.
function G.overflows(c, tol, up)
	tol, up = tol or 1.5, up or 60
	local E = c.E
	local nodes = E.alive_nodes((c.town or c.hud).scene)
	local function lrect(n)
		local x0, y0, x1, y1 = E.rect(n)
		local ax, ay = E.to_logical(x0, y0)
		local bx, by = E.to_logical(x1, y1)
		return math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by)
	end
	local panel, best = nil, 0
	for _, n in ipairs(nodes) do
		if n.kind == "box" and E.visible(n) and n.color.x > 0.99 and n.color.y > 0.99 and n.color.z > 0.99 and n.size.x > 300 then
			local x0, y0, x1, y1 = lrect(n)
			local area = (x1 - x0) * (y1 - y0)
			if x1 - x0 < 715 and area > best then panel, best = n, area end
		end
	end
	assert(panel, "no window panel on the screen")
	local px0, py0, px1, py1 = lrect(panel)
	local function under(n, anc)
		local p = n
		while p do
			if p == anc then return true end
			p = p.parent
		end
		return false
	end
	local out = {}
	for _, n in ipairs(nodes) do
		if n ~= panel and E.visible(n) and E.opacity(n) > 0.02 and under(n, panel) and (n.kind ~= "text" or (n.text or "") ~= "")
			and not (n.size.x == 0 and n.size.y == 0 and n.kind ~= "text") then
			local x0, y0, x1, y1 = lrect(n)
			local name = (n.kind == "text" and ("'" .. tostring(n.text) .. "'") or (n.kind .. " " .. math.floor(x1 - x0) .. "x" .. math.floor(y1 - y0)))
			local is_ribbon = false
			local p = n
			while p and p ~= panel do
				if p.parent == panel and y1 > py1 + tol and y0 > py1 - 110 then is_ribbon = true end
				p = p.parent
			end
			if not is_ribbon then
				local d = math.max(px0 - x0, x1 - px1, py0 - y0, y1 - py1)
				if d > tol then out[#out + 1] = string.format("%s is %.1f px out of the panel", name, d) end
			end
			local dd = math.max(-x0, x1 - 720, -y0, y1 - 1280)
			if dd > tol then out[#out + 1] = string.format("%s is %.1f px out of the screen", name, dd) end
		end
	end
	return out, { px0, py0, px1, py1 }
end

-- The texts of a script's scene as one string (for readable failures).
function G.dump(script)
	return table.concat(script:texts(true), " | ")
end

return G
