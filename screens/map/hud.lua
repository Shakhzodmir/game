-- The fixed part of the map screen: the top bar (back to the town, the title, the stars) and the
-- "to my level" button at the bottom, shown only while the level to play is out of the window.
-- Built into the view's c_ui layer; QA tap targets: view:target("back" | "to_current", x, y).

local app = require("client.app")
local ui = require("client.ui")
local i18n = require("client.i18n")
local rewards = require("client.rewards")

local M = {}

M.TOP_Y = 1214
M.BOTTOM_Y = 110

local Hud = {}
Hud.__index = Hud

-- actions = {back = fn, to_current = fn}
function M.new(view, actions)
	return setmetatable({ view = view, ui = view.ui, actions = actions }, Hud)
end

-- Stars the wallet shows: what the meta holds, less the rewards the town has not played yet.
local function shown_stars()
	return app.meta:stars() - rewards.held().stars
end

function Hud:build()
	local s, view = self.ui, self.view
	if self.layer then s:clear(self.layer) end
	self.layer = s:layer(view.c_ui, "map_hud")
	local layer = self.layer

	local back = s:button({ parent = layer, x = 128, y = M.TOP_Y, w = 216, h = 92, style = "white", icon = "ui/icons/city",
		icon_size = 54, text = i18n.t("map.back"), text_size = 30, on_click = self.actions.back })
	s:anchor(back.node, "top")
	self.back = back
	view:target("back", 128, s:anchored_y(M.TOP_Y, "top"))

	local rib = s:image(layer, "ui/ribbon", 380, M.TOP_Y, { w = 250, h = 78 })
	if rib then s:anchor(rib, "top") end
	local title = s:text(layer, i18n.t("map.title"), 380, M.TOP_Y + 2, {
		font = "button", size = 38, color = "white", outline = "#5220A6", shadow = "#5220A6", max_width = 150,
	})
	s:anchor(title, "top")

	local pill = s:round(layer, 604, M.TOP_Y, 176, 72, "white", { alpha = 0.95, radius = 34 })
	s:anchor(pill, "top")
	if not s:image(pill, "ui/icons/star", -52, 0, { w = 54, h = 54 }) then s:circle(pill, -52, 0, 44, "yellow") end
	self.stars, self.stars_info = s:text(pill, tostring(shown_stars()), 18, 2, {
		font = "number", size = 36, color = "text", max_width = 90,
	})

	local cur = s:button({ parent = layer, x = 360, y = M.BOTTOM_Y, w = 470, h = 104, style = "green", icon = "ui/icons/play",
		icon_size = 58, text = i18n.t("map.to_current"), text_size = 34, on_click = self.actions.to_current })
	s:anchor(cur.node, "bottom")
	self.cur = cur
	view:target("to_current", 360, s:anchored_y(M.BOTTOM_Y, "bottom"))
	self.cur_on = nil
	self:show_current(false)
end

function Hud:set_stars()
	if self.stars then self.ui:set_text(self.stars, tostring(shown_stars()), self.stars_info) end
end

-- The "to my level" button shows while the level to play is out of the window.
function Hud:show_current(on)
	if self.cur_on == on then return end
	self.cur_on = on
	gui.set_enabled(self.cur.node, on)
end

return M
