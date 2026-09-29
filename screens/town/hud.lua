-- Town HUD: top bar (lives with the timer, coins with "+", stars, settings),
-- the district ribbon with the track progress and the day / concert toggle,
-- the next-task card, the green "Level N" button with its difficulty tag
-- and hit-streak notes, and the bottom navigation. Every number comes from
-- the meta (client/views.lua); the counters show town.disp (what already
-- landed, see screens/town/town.gui_script).
--
-- Layout (logical, y up): top bar 1214 and ribbon 1110 are anchored to the
-- safe top; the task card 382, the level button 226 and the navigation 40
-- to the safe bottom. The scene items sit between 496 and 1043.

local app = require("client.app")
local ui = require("client.ui")
local i18n = require("client.i18n")
local fx = require("client.fx")
local views = require("client.views")
local levels = require("client.levels")
local assets = require("client.assets")

local M = {}

M.TOP_Y = 1214
M.RIBBON_Y = 1110
M.TASK_Y = 382
M.TASK_X = 318
M.LEVEL_Y = 226
M.NAV_Y = 40
M.LIVES_X, M.COINS_X, M.STARS_X, M.GEAR_X = 118, 336, 520, 660

M.NAV = {
	{ id = "shop", icon = "ui/icons/shop", label = "nav.shop" },
	{ id = "band", icon = "ui/icons/team", label = "nav.band", soon = true },
	{ id = "town", icon = "ui/icons/city", label = "nav.town", active = true },
	{ id = "chart", icon = "ui/icons/chart", label = "nav.chart", soon = true },
	{ id = "jukebox", icon = "ui/icons/jukebox", label = "nav.jukebox" },
}

local Hud = {}
Hud.__index = Hud

function M.new(town)
	return setmetatable({ town = town, ui = town.ui }, Hud)
end

local function icon(s, parent, key, x, y, size, fallback)
	return s:image(parent, key, x, y, { w = size, h = size }) or s:circle(parent, x, y, size * 0.8, fallback or "lavender")
end

-- an invisible button over an area
local function hit(s, parent, x, y, w, h, on_click, sfx)
	local b = s:button({ parent = parent, x = x, y = y, w = w, h = h, style = "white", sfx = sfx or "tap", on_click = on_click })
	gui.set_color(b.node, vmath.vector4(1, 1, 1, 0))
	return b
end

-- Logical position of a point anchored to an edge.
function Hud:top(x, y) return x, self.ui:anchored_y(y, "top") end
function Hud:bottom(x, y) return x, self.ui:anchored_y(y, "bottom") end

function Hud:target(name, x, y)
	self.targets[name] = { x = x, y = y }
end

-- top bar ------------------------------------------------------------------------------------

local function lives_label(v)
	if v.state == "infinite" then return i18n.duration(v.seconds) end
	if v.state == "full" then return i18n.t("town.lives_full") end
	return i18n.duration(v.seconds)
end

local function pill(s, parent, x, w)
	local sh = s:round(parent, x, M.TOP_Y - 6, w, 78, "#D66E8C", { alpha = 0.22 })
	s:anchor(sh, "top")
	local p = s:round(parent, x, M.TOP_Y, w, 78, "white")
	s:anchor(p, "top")
	return p
end

function Hud:build_top(parent)
	local s, town = self.ui, self.town
	-- lives
	local lp = pill(s, parent, M.LIVES_X, 204)
	local lv = views.lives(app.meta:lives(app.now()))
	self.heart = icon(s, lp, lv.icon, -64, 2, 74, "pink")
	self.lives_count = s:text(self.heart, lv.state == "infinite" and "" or tostring(lv.count), 0, 1, {
		font = "number", size = 32, color = "white", outline = "#B3122F",
	})
	self.lives_label, self.lives_info = s:text(lp, lives_label(lv), -20, 1, {
		font = "number", size = 28, color = lv.state == "infinite" and "purple" or "text", pivot = gui.PIVOT_W, max_width = 108,
	})
	self.lives_state = lv.state
	self.lives_pill = lp
	hit(s, lp, 0, 0, 204, 100, function() town:open_popup("lives") end)
	self:target("lives", self:top(M.LIVES_X, M.TOP_Y))

	-- coins with "+"
	local cp = pill(s, parent, M.COINS_X, 214)
	self.coin_icon = icon(s, cp, "ui/icons/coin", -72, 2, 66, "coin")
	self.coins_label, self.coins_info = s:text(cp, i18n.number(town.disp.coins), -36, 1, {
		font = "number", size = 34, color = "text", pivot = gui.PIVOT_W, max_width = 100,
	})
	hit(s, cp, 0, 0, 214, 100, function() town:open_popup("shop", { tab = "coins" }) end)
	local plus = s:image(cp, "ui/icons/plus", 78, 2, { w = 56, h = 56 })
	if not plus then
		plus = s:circle(cp, 78, 2, 50, "green")
		s:text(plus, "+", 0, 2, { font = "button", size = 38, color = "white" })
	end
	self.plus = plus
	local pb = hit(s, cp, 78, 0, 96, 100, function() town:open_popup("shop", { tab = "coins" }) end, "button")
	self:target("coins_plus", self:top(M.COINS_X + 78, M.TOP_Y))

	-- stars
	local sp = pill(s, parent, M.STARS_X, 146)
	self.star_icon = icon(s, sp, "ui/icons/star", -40, 2, 64, "yellow")
	self.stars_label, self.stars_info = s:text(sp, i18n.number(town.disp.stars), -4, 1, {
		font = "number", size = 34, color = "text", pivot = gui.PIVOT_W, max_width = 70,
	})
	hit(s, sp, 0, 0, 146, 100, function()
		app.toast_key("town.stars_hint", nil, { color = "gold" })
		town.fx:pop(self.star_icon, 0.3)
	end)

	-- settings
	local gear = s:button({ parent = parent, x = M.GEAR_X, y = M.TOP_Y, w = 92, h = 92, style = "white",
		icon = "ui/icons/settings", icon_size = 62,
		text = not assets.has_image("ui/icons/settings") and "..." or nil,
		on_click = function() town:open_popup("settings") end })
	s:anchor(gear.node, "top")
	self:target("settings", self:top(M.GEAR_X, M.TOP_Y))
end

function Hud:set_coins(v)
	if self.coins_label then self.ui:set_text(self.coins_label, i18n.number(v), self.coins_info) end
end

function Hud:set_stars(v)
	if self.stars_label then self.ui:set_text(self.stars_label, i18n.number(v), self.stars_info) end
end

-- Once a second: the lives timer (a rebuild when the state changed).
function Hud:tick()
	if not self.lives_label then return end
	local lv = views.lives(app.meta:lives(app.now()))
	if lv.state ~= self.lives_state and (lv.state == "infinite" or self.lives_state == "infinite") then
		self.town.dirty_ui = true
		return
	end
	self.lives_state = lv.state
	gui.set_text(self.lives_count, lv.state == "infinite" and "" or tostring(lv.count))
	self.ui:set_text(self.lives_label, lives_label(lv), self.lives_info)
end

function Hud:coins_pos() return self:top(M.COINS_X - 72, M.TOP_Y) end
function Hud:stars_pos() return self:top(M.STARS_X - 40, M.TOP_Y) end
function Hud:lives_pos() return self:top(M.LIVES_X - 64, M.TOP_Y) end

-- ribbon ----------------------------------------------------------------------------------------

function Hud:build_ribbon(parent)
	local s, town = self.ui, self.town
	local p = views.progress(app.meta, town.district)
	local rib = s:image(parent, "ui/button_purple", 330, M.RIBBON_Y, { w = 480, h = 96, slice9 = true })
		or s:round(parent, 330, M.RIBBON_Y, 480, 96, "purple")
	s:anchor(rib, "top")
	self.ribbon = rib
	s:text(rib, i18n.name(p.name), 0, 16, { font = "button", size = 34, color = "white", outline = "#5220A6",
		shadow = "#5220A6", max_width = 440 })
	s:text(rib, i18n.t("town.layers", { done = p.done, total = p.total }), 0, -20, {
		font = "small", size = 22, color = "#F1E6FF", max_width = 420,
	})
	local view = app.meta:view(town.district)
	local toggle = s:button({ parent = parent, x = 652, y = M.RIBBON_Y, w = 108, h = 92, style = view == "day" and "blue" or "gold",
		text = i18n.t(view == "day" and "town.concert" or "town.day"), text_size = 24,
		on_click = function() town:toggle_view() end })
	s:anchor(toggle.node, "top")
	self:target("view", self:top(652, M.RIBBON_Y))
end

-- task card ---------------------------------------------------------------------------------------

function Hud:build_task(parent)
	local s, town = self.ui, self.town
	local task = views.task(app.meta)
	self.task = task
	local x, y = M.TASK_X, M.TASK_Y
	if not task then
		local card = s:round(parent, x, y, 588, 112, "white", { alpha = 0.96 })
		s:anchor(card, "bottom")
		icon(s, card, "ui/icons/star", -236, 0, 76, "yellow")
		s:text(card, i18n.t("town.town_done"), 30, 2, { font = "button", size = 32, color = "pink", max_width = 470 })
		self.card = card
		return
	end
	local glow
	if task.affordable and fx.reduced() then
		glow = s:round(parent, x, y, 600, 138, "gold")
		s:anchor(glow, "bottom")
	end
	local card = s:button({ parent = parent, x = x, y = y, w = 588, h = 126, style = "white",
		on_click = function() town:on_task(task) end })
	s:anchor(card.node, "bottom")
	self.card = card.node
	self:target("task", self:bottom(x, y))
	local thumb = s:round(card.node, -234, 4, 100, 100, "#FFE3EF", { radius = 24 })
	if not s:image(thumb, task.image, 0, 0, { w = 88, h = 88 }) then s:circle(thumb, 0, 0, 70, "lavender") end
	s:text(card.node, i18n.name(task.name), -172, 24, {
		font = "button", size = 30, color = "text", pivot = gui.PIVOT_W, max_width = 300,
	})
	s:text(card.node, i18n.t("town.task_adds", { stem = i18n.t("stem." .. task.stem) }), -172, -18, {
		font = "small", size = 22, color = "purple", pivot = gui.PIVOT_W, max_width = 300,
	})
	local chip
	if task.affordable then
		chip = s:image(card.node, "ui/button_gold", 214, 4, { w = 118, h = 86, slice9 = true })
			or s:round(card.node, 214, 4, 118, 86, "gold")
	else
		chip = s:round(card.node, 214, 4, 118, 86, "#EFE8FF")
	end
	self.chip = chip
	local st = icon(s, chip, "ui/icons/star", -26, 4, 50, "yellow")
	if not task.affordable then gui.set_color(st, vmath.vector4(1, 1, 1, 0.55)) end
	s:text(chip, tostring(task.cost), 24, 6, {
		font = "number", size = 40, color = task.affordable and "white" or "text_soft",
		outline = task.affordable and "#C96A00" or false,
	})
	if not task.affordable and task.need > 0 then
		s:text(card.node, i18n.t("town.task_need", { n = task.need }), 214, -52, {
			font = "small", size = 18, color = "text_soft", max_width = 150,
		})
	end
	if task.affordable and not fx.reduced() then ui.pulse(card.node, 0.035, 0.7) end
end

function Hud:chip_pos()
	return self:bottom(M.TASK_X + 214, M.TASK_Y + 4)
end

-- The card after its task was done: it drops away (the new one pops in on rebuild).
function Hud:card_out()
	if not self.card or fx.reduced() then return end
	ui.stop_pulse(self.card)
	gui.animate(self.card, "scale", vmath.vector3(0.01, 0.01, 1), gui.EASING_INBACK, 0.3)
end

function Hud:card_in()
	if not self.card or fx.reduced() then return end
	local p = gui.get_position(self.card)
	gui.set_position(self.card, vmath.vector3(p.x + 720, p.y, 0))
	gui.animate(self.card, "position.x", p.x, gui.EASING_OUTBACK, 0.45)
end

-- level button --------------------------------------------------------------------------------------

function Hud:build_level(parent)
	local s, town = self.ui, self.town
	local level = app.meta:level_to_play()
	local x, y = 360, M.LEVEL_Y
	if not level then
		local b = s:button({ parent = parent, x = x, y = y, w = 560, h = 128, style = "blue", text = i18n.t("town.all_done"),
			text_size = 36, on_click = function()
				app.toast_key("town.all_done", nil, { color = "blue" })
				town.bit:cheer(1.2, 1)
			end })
		s:anchor(b.node, "bottom")
		self:target("level", self:bottom(x, y))
		self.level_btn = b.node
		return
	end
	local b = s:button({ parent = parent, x = x, y = y, w = 560, h = 128, style = "green", text = i18n.t("town.level", { n = level }),
		text_size = 54, on_click = function() town:open_popup("start", { level = level }) end })
	s:anchor(b.node, "bottom")
	self.level_btn = b.node
	self:target("level", self:bottom(x, y))
	if b.label then
		gui.set_position(b.label, vmath.vector3(-60, 6, 0))
		b.label_info.max_width = 300
		s:_fit_text(b.label, b.label_info)
	end
	-- hit streak: three notes inside the button
	local streak = app.meta:streak()
	self.notes = {}
	for i = 1, 3 do
		local slot = streak.slots and streak.slots[i]
		local lit = slot and slot.lit
		local nx = 132 + (i - 1) * 46
		local n = s:image(b.node, lit and "ui/icons/note_on" or "ui/icons/note_off", nx, 6, { w = 50, h = 50 })
			or s:circle(b.node, nx, 6, 34, lit and "yellow" or "white")
		if not lit then gui.set_color(n, vmath.vector4(1, 1, 1, 0.6)) end
		self.notes[i] = n
	end
	local tag_key = levels.tag(levels.difficulty(level))
	if tag_key then
		local hard = tag_key == "town.hard"
		local tag = s:round(b.node, 196, 66, 190, 50, hard and "pink" or "purple", { radius = 24 })
		s:text(tag, i18n.t(tag_key), 0, 2, { font = "button", size = 24, color = "white", max_width = 170 })
		if not fx.reduced() then
			gui.set_euler(tag, vmath.vector3(0, 0, -4))
		end
	end
	if not fx.reduced() then ui.pulse(b.node, 0.03, 0.9) end
end

-- Lights the streak note of `count` with a pop and sparkles.
function Hud:streak_pop(count)
	local i = math.max(1, math.min(3, count))
	local n = self.notes and self.notes[i]
	if not n then return end
	local x, y = self:bottom(360 + 132 + (i - 1) * 46, M.LEVEL_Y + 6)
	self.town.fx:burst(x, y, { count = 8, radius = 70, size = 26 })
	self.town.fx:pop(n, 0.6, 0.4)
end

-- navigation -----------------------------------------------------------------------------------------

function Hud:build_nav(parent)
	local s, town = self.ui, self.town
	local bar = s:round(parent, 360, M.NAV_Y, 744, 190, "white", { alpha = 0.97 })
	s:anchor(bar, "bottom")
	for i, item in ipairs(M.NAV) do
		local x = -288 + (i - 1) * 144
		local b = s:button({ parent = bar, x = x, y = 30, w = 132, h = 112, style = item.active and "purple" or "white",
			icon = item.icon, icon_size = 58, on_click = function() town:on_nav(item) end })
		if b.icon then
			gui.set_position(b.icon, vmath.vector3(0, 14, 0))
			if item.soon then gui.set_color(b.icon, vmath.vector4(1, 1, 1, 0.55)) end
		end
		s:text(b.node, i18n.t(item.label), 0, -34, {
			font = "small", size = 21, color = item.active and "white" or (item.soon and "text_soft" or "text"), max_width = 124,
		})
		if item.soon then
			local badge = s:round(b.node, 34, 46, 80, 30, "pink", { radius = 14 })
			s:text(badge, i18n.t("nav.soon"), 0, 1, { font = "small", size = 17, color = "white", max_width = 72 })
		end
		self:target("nav_" .. item.id, self:bottom(360 + x, M.NAV_Y + 30))
	end
end

-- everything --------------------------------------------------------------------------------------------

function Hud:build()
	local s = self.ui
	if self.layer then s:clear(self.layer) end
	self.layer = s:layer(self.town.c_ui)
	self.targets = {}
	self:build_top(self.layer)
	self:build_ribbon(self.layer)
	self:build_task(self.layer)
	self:build_level(self.layer)
	self:build_nav(self.layer)
	app.ui.targets = self.targets
end

return M
