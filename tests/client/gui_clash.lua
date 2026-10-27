-- A watcher for the commonest animation bug of the GUI scripts (not a test file itself): two gui.animate calls
-- on one node and one property in the same frame. The engine keeps ONE animation per node and property, so
-- the second call replaces the first before it ran a single frame: the fade-in that never shows, the pop-in
-- that is skipped. A gui.cancel_animations of the property in between is a deliberate restart and is fine.
-- For the town_defold_stub environment (its GUI keeps the running animations and steps them per frame).
--
--   local clash = require("tests.client.gui_clash")
--   local w = clash.watch(E)       -- E = town_defold_stub.boot(...), before the scripts run
--   ... run frames ...
--   assert_same(w.list(), {})      -- {"scale x2 at screens/level/level_fx.gui_script:140", ...}
--   w.stop()

local M = {}

function M.watch(E)
	local g = rawget(_G, "gui")
	local animate, cancel, advance = g.animate, g.cancel_animations, E.advance_scene
	local frame = 0
	local seen = setmetatable({}, { __mode = "k" }) -- node -> property -> frame of its last gui.animate
	local sites = {}                                -- "prop at file:line" -> hits
	local order = {}

	E.advance_scene = function(...)
		frame = frame + 1
		return advance(...)
	end
	g.animate = function(node, property, ...)
		local key = tostring(property)
		local per = seen[node]
		if not per then
			per = {}
			seen[node] = per
		end
		if per[key] == frame then
			local info = debug.getinfo(2, "Sl")
			local site = key .. " at " .. (info and (info.short_src .. ":" .. info.currentline) or "?")
			if not sites[site] then
				sites[site] = 0
				order[#order + 1] = site
			end
			sites[site] = sites[site] + 1
		end
		per[key] = frame
		return animate(node, property, ...)
	end
	g.cancel_animations = function(node, property, ...)
		local per = seen[node]
		if per then
			if property == nil then
				seen[node] = nil
			else
				local base = tostring(property)
				for k in pairs(per) do -- order-independent
					if k == base or string.sub(k, 1, #base + 1) == base .. "." or string.sub(base, 1, #k + 1) == k .. "." then
						per[k] = nil
					end
				end
			end
		end
		return cancel(node, property, ...)
	end

	local w = {}
	-- the call sites that animated a property twice in one frame, with the number of times
	function w.list()
		local out = {}
		for i, site in ipairs(order) do out[i] = site .. " (x" .. sites[site] .. ")" end
		return out
	end
	function w.stop()
		g.animate, g.cancel_animations, E.advance_scene = animate, cancel, advance
	end
	return w
end

return M
