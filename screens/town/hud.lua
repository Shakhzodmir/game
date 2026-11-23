-- Town HUD: top bar (lives with the timer, coins with "+", stars, settings),
-- the district ribbon with the track progress and the day / concert toggle,
-- the next-task card, the green "Level N" button with its difficulty tag
-- and hit-streak notes, and the bottom navigation. Every number comes from
-- the meta (client/views.lua); the coin and star counters show town.disp
-- (what has already landed, see screens/town/town.gui_script).
--
-- Layout (logical, y up): top bar 1214 and ribbon 1110 are anchored to the
-- safe top; the task card 382, the level button 226 and the navigation 40
-- to the safe bottom. The scene items sit between 496 and 1043.

local app = require("client.app")
local ui = require("client.ui")
local i18n = require("client.i18n")
local fx = require("client.fx")
local views = require("client.views")
local rewards = require("client.rewards")
local levels = require("client.levels")
local assets = require("client.assets")
local analytics = require("client.services.analytics")
local social = require("client.services.social")
local kit = require("gui.kit")

local M = {}

M.TOP_Y = 1214
M.RIBBON_Y = 1108
M.TASK_Y = 382
M.TASK_X = 316
M.LEVEL_Y = 226
M.NAV_Y = 40
M.LIVES_X, M.COINS_X, M.STARS_X, M.GEAR_X = 118, 334, 528, 662
M.BIT_X, M.BIT_Y = 660, 398

-- The tabs of the bottom navigation, left to right. Band and Chart need the server behind client/services/social.lua:
-- while none is connected (`online` false: the web build today) they are not shown at all, because their windows
-- could only say "not connected", and the songbook has a tab of its own in their place. With a server the five tabs
-- are as they always were (the songbook then keeps its small button under the day / concert toggle,
-- Hud:build_notebook_button). A tab with soon = true is dimmed, wears the "Soon" badge and answers with a toast
-- (Town:on_nav); none uses it now. Town:on_nav opens the window of any other tab by its id.
function M.nav_items(online)
	if online then
		return {
			{ id = "shop", icon = "ui/icons/shop", label = "nav.shop" },
			{ id = "band", icon = "ui/icons/team", label = "nav.band" },
			{ id = "town", icon = "ui/icons/city", label = "nav.town", active = true },
			{ id = "chart", icon = "ui/icons/chart", label = "nav.chart" },
			{ id = "jukebox", icon = "ui/icons/jukebox", label = "nav.jukebox" },
		}
	end
	return {
		{ id = "shop", icon = "ui/icons/shop", label = "nav.shop" },
		{ id = "town", icon = "ui/icons/city", label = "nav.town", active = true },
		{ id = "notebook", icon = "ui/icons/notebook", label = "nav.notebook" },
		{ id = "jukebox", icon = "ui/icons/jukebox", label = "nav.jukebox" },
	}
end

-- The plate of the navigation (Hud:build_nav) is 700 px wide; its tabs share 690 of them: 138 px each for five (the
-- step the bar always had), 172 for four. A tab is 132 px wide whatever their number.
M.NAV_SPAN, M.NAV_TAB_W = 690, 132

-- x of tab i of n, from the centre of the plate
function M.nav_x(i, n)
	return (i - (n + 1) / 2) * math.floor(M.NAV_SPAN / n)
end

local Hud = {}
Hud.__index = Hud

function M.new(town)
	return setmetatable({ town = town, ui = town.ui, targets = {} }, Hud)
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

-- The lives as the top bar shows them: like the coin and star counters, without what is paid but has not
-- landed yet. The unlimited lives of a level chest belong to the meta from the moment the player takes it
-- ("Collect"), but the pill must not change before its heart has flown in (town.hold.infinite holds them; a
-- queued paid chest of the QA `reward` command is held by the queue first).
function Hud:lives_view()
	local l = app.meta:lives(app.now())
	local held = (self.town.hold.infinite or 0) + rewards.held().infinite
	if held > 0 and (l.infinite_seconds or 0) > 0 then
		l = { count = l.count, max = l.max, next_in_seconds = l.next_in_seconds, infinite_seconds = math.max(0, l.infinite_seconds - held) }
	end
	return views.lives(l)
end

local function pill(s, parent, x, w)
	local sh = s:round(parent, x, M.TOP_Y - 6, w, 80, "#CAB7DE", { alpha = 0.9, radius = 38 })
	s:anchor(sh, "top")
	local p = s:round(parent, x, M.TOP_Y, w, 78, "white", { radius = 38 })
	s:anchor(p, "top")
	return p
end

function Hud:build_top(parent)
	local s, town = self.ui, self.town
	-- lives
	local lp = pill(s, parent, M.LIVES_X, 204)
	local lv = self:lives_view()
	self.heart = icon(s, lp, lv.icon, -64, 2, 76, "pink")
	self.lives_count = s:text(self.heart, lv.state == "infinite" and "" or tostring(lv.count), 0, 3, {
		font = "number", size = 32, color = "white", outline = "#B3122F",
	})
	self.lives_label, self.lives_info = s:text(lp, lives_label(lv), -18, 1, {
		font = "number", size = 28, color = lv.state == "infinite" and "purple" or (lv.state == "empty" and "pink" or "text"),
		pivot = gui.PIVOT_W, max_width = 104,
	})
	self.lives_state = lv.state
	self.lives_pill = lp
	if lv.state == "empty" and not fx.reduced() then ui.pulse(self.heart, 0.08, 0.5) end
	hit(s, lp, 0, 0, 204, 100, function() town:open_popup("lives") end)
	self:target("lives", self:top(M.LIVES_X, M.TOP_Y))

	-- coins with "+"
	local cp = pill(s, parent, M.COINS_X, 214)
	self.coin_icon = icon(s, cp, "ui/icons/coin", -72, 2, 66, "coin")
	self.coins_label, self.coins_info = s:text(cp, i18n.number(town.disp.coins), -34, 1, {
		font = "number", size = 34, color = "text", pivot = gui.PIVOT_W, max_width = 92,
	})
	hit(s, cp, -30, 0, 150, 100, function() town:open_popup("shop", { tab = "coins" }) end)
	-- a small "+" at the very end of the pill: it never covers the number (the number ends at x = 58)
	local plus = s:image(cp, "ui/icons/plus", 83, 2, { w = 40, h = 40 })
	if not plus then
		plus = s:circle(cp, 83, 2, 36, "green")
		s:text(plus, "+", 0, 2, { font = "button", size = 28, color = "white" })
	end
	self.plus = plus
	hit(s, cp, 70, 0, 96, 100, function() town:open_popup("shop", { tab = "coins" }) end, "button")
	self:target("coins_plus", self:top(M.COINS_X + 78, M.TOP_Y))

	-- stars
	local sp = pill(s, parent, M.STARS_X, 146)
	self.star_icon = icon(s, sp, "ui/icons/star", -40, 3, 66, "yellow")
	self.stars_label, self.stars_info = s:text(sp, i18n.number(town.disp.stars), -4, 1, {
		font = "number", size = 34, color = "text", pivot = gui.PIVOT_W, max_width = 68,
	})
	hit(s, sp, 0, 0, 146, 100, function()
		local sup = app.meta:super_stars()
		if sup.earned > 0 then
			app.toast_key("town.super_stars_hint", { n = sup.balance }, { color = "gold" })
		else
			app.toast_key("town.stars_hint", nil, { color = "gold" })
		end
		town.fx:pop(self.star_icon, 0.3)
	end)
	self:target("stars", self:top(M.STARS_X, M.TOP_Y))

	-- settings
	local gear = s:button({ parent = parent, x = M.GEAR_X, y = M.TOP_Y, w = 96, h = 96, style = "white",
		icon = "ui/icons/settings", icon_size = 64,
		text = not assets.has_image("ui/icons/settings") and "..." or nil,
		on_click = function() town:open_popup("settings") end })
	s:anchor(gear.node, "top")
	self.gear = gear.node
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
	local lv = self:lives_view()
	if lv.state ~= self.lives_state then
		self.town.dirty_ui = true
		return
	end
	gui.set_text(self.lives_count, lv.state == "infinite" and "" or tostring(lv.count))
	self.ui:set_text(self.lives_label, lives_label(lv), self.lives_info)
end

function Hud:coins_pos() return self:top(M.COINS_X - 72, M.TOP_Y) end
function Hud:stars_pos() return self:top(M.STARS_X - 40, M.TOP_Y) end
function Hud:lives_pos() return self:top(M.LIVES_X - 64, M.TOP_Y) end
function Hud:level_pos() return self:bottom(M.LEVEL_X, M.LEVEL_Y) end

-- ribbon ----------------------------------------------------------------------------------------

M.RIBBON_X, M.RIBBON_W = 328, 484
M.NAV_RIBBON_X, M.NAV_RIBBON_W = 312, 388 -- the narrower ribbon between the two district arrows
M.ARROW_PREV_X, M.ARROW_NEXT_X = 68, 550

local function arrow_button(self, parent, x, dir, enabled)
	local s, town = self.ui, self.town
	local has_icon = assets.has_image("ui/icons/arrow")
	local b = s:button({ parent = parent, x = x, y = M.RIBBON_Y, w = 80, h = 80, style = "white", icon = "ui/icons/arrow", icon_size = 48,
		text = not has_icon and (dir < 0 and "<" or ">") or nil, enabled = enabled, sfx = "button",
		on_click = function() town:browse(dir) end })
	if b.icon and dir < 0 then gui.set_euler(b.icon, vmath.vector3(0, 0, 180)) end
	s:anchor(b.node, "top")
	self:target(dir < 0 and "nav_prev" or "nav_next", self:top(x, M.RIBBON_Y))
	return b
end

function Hud:build_ribbon(parent)
	local s, town = self.ui, self.town
	local p = views.progress(app.meta, town.district)
	local nav = views.browse(app.meta, town.district)
	self.paging = nav
	local paged = nav.count > 1 -- more than one district is open: arrows on both sides of the ribbon
	local rx, rw = M.RIBBON_X, M.RIBBON_W
	if paged then rx, rw = M.NAV_RIBBON_X, M.NAV_RIBBON_W end
	local rib = s:image(parent, "ui/button_purple", rx, M.RIBBON_Y, { w = rw, h = 104, slice9 = true })
		or s:round(parent, rx, M.RIBBON_Y, rw, 104, "purple")
	s:anchor(rib, "top")
	self.ribbon = rib
	s:text(rib, i18n.name(p.name), 0, 26, { font = "button", size = paged and 30 or 34, color = "white",
		shadow = "#6C32CF", max_width = rw - 44 })
	-- the caption: white on a dark translucent capsule. Under its glyphs the bare ribbon face is #9A5BF2 to #A66DF6, where the
	-- thin 21 px text was 2.9:1 in #F1E6FF and is 3.4:1 in plain white; the font "small" has no shadow to help it, and a
	-- heavier font is not for this change. The capsule (the shelf colour of the ribbon, the colour of the segments below)
	-- takes white to 5.0:1 at its lightest row (5.6 at the bottom), measured in the web build.
	local layers = i18n.t("town.layers", { done = p.done, total = p.total })
	local layers_w = math.min(kit.text_width(ui.font_for("small", layers), layers, 21), rw - 64)
	s:round(rib, 0, -6, layers_w + 36, 22, "#6C32CF", { alpha = 0.55, radius = 11 })
	s:text(rib, layers, 0, -4, { font = "small", size = 21, color = "white", max_width = rw - 64 })
	-- the track progress: one segment per layer
	local n = math.max(1, p.total)
	local bw = rw - 150
	local seg = (bw - (n - 1) * 8) / n
	for i = 1, n do
		local x = -bw / 2 + (i - 0.5) * seg + (i - 1) * 8
		s:round(rib, x, -24, seg, 10, i <= p.done and "#FFDB1A" or "#6C32CF", { radius = 5 })
	end
	if paged then
		arrow_button(self, parent, M.ARROW_PREV_X, -1, nav.prev ~= nil)
		arrow_button(self, parent, M.ARROW_NEXT_X, 1, nav.next ~= nil)
	end
	local view = app.meta:view(town.district)
	local toggle = s:button({ parent = parent, x = 652, y = M.RIBBON_Y, w = 112, h = 96, style = view == "day" and "white" or "gold",
		icon = view == "day" and "ui/icons/music_on" or "ui/icons/star", icon_size = 38,
		text = i18n.t(view == "day" and "town.concert" or "town.day"), text_size = 20,
		on_click = function() town:toggle_view() end })
	if toggle.icon then
		gui.set_position(toggle.icon, vmath.vector3(0, 18, 0))
		if toggle.label then
			gui.set_position(toggle.label, vmath.vector3(0, -20, 0))
			toggle.label_info.max_width = 100
			s:_fit_text(toggle.label, toggle.label_info)
		end
	end
	s:anchor(toggle.node, "top")
	self:target("view", self:top(652, M.RIBBON_Y))
	-- the songbook has its own tab in the navigation unless Band and Chart take the room (a server is connected)
	if self.online then self:build_notebook_button(parent) end
end

-- The songbook (WP-9) in a town that shows the five tabs (Band and Chart: a server is connected): a small button
-- under the day / concert toggle (the art keeps its zone free: UI_ZONES in tools/art/gen_art.py). A dot says a
-- finished song is waiting to be looked at. Without a server the songbook is a tab of the navigation instead
-- (Hud:build_nav) and this button is not drawn.
M.NOTEBOOK_X, M.NOTEBOOK_Y = 652, 1028
function Hud:build_notebook_button(parent)
	local s, town = self.ui, self.town
	-- the icon is in the UI atlas (a small copy of notebook/closed): a loose picture is a white square until it loads;
	-- a gold button, because the lavender notebook does not show on a purple one
	local has_icon = assets.has_image("ui/icons/notebook")
	local b = s:button({ parent = parent, x = M.NOTEBOOK_X, y = M.NOTEBOOK_Y, w = 80, h = 80, style = "white",
		icon = has_icon and "ui/icons/notebook" or "ui/icons/note_on", icon_size = 58, sfx = "button",
		on_click = function() town:open_popup("notebook") end })
	s:anchor(b.node, "top")
	self.notebook_btn = b.node
	if app.meta:songbook_pending() then
		local dot = s:circle(b.node, 30, 26, 26, "pink")
		if dot and not fx.reduced() then ui.pulse(dot, 0.15, 0.6) end
		self.notebook_dot = dot
	end
	self:target("notebook", self:top(M.NOTEBOOK_X, M.NOTEBOOK_Y))
end

-- task card ---------------------------------------------------------------------------------------

function Hud:build_task(parent)
	local s, town = self.ui, self.town
	local cv = views.card(app.meta, town.district)
	local task = cv.task
	self.task, self.card_kind = task, cv.kind
	local x, y = M.TASK_X, M.TASK_Y
	self.chip, self.chip_star, self.thumb = nil, nil, nil
	if cv.kind == "done" then
		local card = s:round(parent, x, y, 588, 112, "white", { alpha = 0.97, radius = 34 })
		s:anchor(card, "bottom")
		icon(s, card, "ui/icons/star", -236, 0, 76, "yellow")
		s:text(card, i18n.t("town.town_done"), 30, 2, { font = "button", size = 30, color = "pink", max_width = 470 })
		self.card = card
		return
	end
	if cv.kind == "back" then
		-- another district is on display: one tap takes the player back to the one being built
		local card = s:button({ parent = parent, x = x, y = y, w = 588, h = 128, style = "white",
			on_click = function() town:browse_to(cv.district, 1) end })
		s:anchor(card.node, "bottom")
		self.card = card.node
		self:target("back", self:bottom(x, y))
		local arrow = s:image(card.node, "ui/icons/arrow", 232, 4, { w = 72, h = 72 })
			or s:circle(card.node, 232, 4, 56, "white")
		if arrow and not fx.reduced() then
			local p = gui.get_position(arrow)
			gui.animate(arrow, "position.x", p.x + 10, gui.EASING_INOUTSINE, 0.5, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
		end
		kit.label({ ui = s }, card.node, i18n.t("town.back_to", { name = i18n.name(cv.name) }), -34, 4, {
			font = "button", size = 32, color = "text", max_width = 440, lines = 2,
		})
		return
	end
	local card = s:button({ parent = parent, x = x, y = y, w = 588, h = 128, style = "white",
		on_click = function() town:on_task(task) end })
	s:anchor(card.node, "bottom")
	self.card = card.node
	self:target("task", self:bottom(x, y))
	local thumb = s:round(card.node, -232, 4, 104, 104, "#F1E8FF", { radius = 28 })
	self.thumb = thumb
	-- the picture of the item keeps its proportions inside the 92 px square (a double bass is tall, a banner is wide)
	local info = assets.image(task.image)
	local tw, th = 92, 92
	if info and info.w and info.h and info.w > 0 and info.h > 0 then
		local k = math.min(92 / info.w, 92 / info.h)
		tw, th = info.w * k, info.h * k
	end
	if not s:image(thumb, task.image, 0, 0, { w = tw, h = th }) then s:circle(thumb, 0, 0, 70, "lavender") end
	s:text(card.node, i18n.name(task.name), -168, 22, {
		font = "button", size = 30, color = "text", pivot = gui.PIVOT_W, max_width = 300,
	})
	s:text(card.node, i18n.t("town.task_adds", { stem = i18n.t("stem." .. task.stem) }), -168, -18, {
		font = "small", size = 22, color = "purple", pivot = gui.PIVOT_W, max_width = 300,
	})
	local chip
	if task.affordable then
		chip = s:image(card.node, "ui/button_gold", 212, 4, { w = 124, h = 92, slice9 = true })
			or s:round(card.node, 212, 4, 124, 92, "gold")
	else
		chip = s:image(card.node, "ui/button_white", 212, 4, { w = 124, h = 92, slice9 = true })
			or s:round(card.node, 212, 4, 124, 92, "#EFE8FF", { radius = 30 })
	end
	self.chip = chip
	local st = icon(s, chip, "ui/icons/star", 28, 4, 50, "yellow")
	self.chip_star = st
	s:text(chip, tostring(task.cost), -18, 6, {
		font = "number", size = 42, color = task.affordable and "#6B4300" or "text",
	})
	if task.affordable and not fx.reduced() then ui.pulse(card.node, 0.035, 0.7) end
end

-- hint -------------------------------------------------------------------------------------------

M.HINT_Y = M.TASK_Y + 150

-- The pointing hand and the speech bubble over the task card (views.town_hint): the first star of
-- the game should go into the first task.
function Hud:build_hint(parent)
	local s = self.ui
	local hint = views.town_hint(app.meta, self.task)
	self.hint = hint
	if not hint then return end
	-- logged once per visit, not at every rebuild of the bars
	local town = self.town
	town.hints_logged = town.hints_logged or {}
	if not town.hints_logged[hint.id] then
		town.hints_logged[hint.id] = true
		analytics.log("tutorial_step", { id = hint.id, level = app.meta:level_to_play() })
	end
	local x = M.TASK_X
	local holder = s:layer(parent)
	gui.set_position(holder, vmath.vector3(0, M.HINT_Y, 0))
	s:anchor(holder, "bottom")
	local border = s:round(holder, x, 0, 548, 104, "#C9A7FF", { radius = 36 })
	local bubble = s:round(border, 0, 0, 536, 92, "white", { radius = 32 })
	-- the tail points down at the card
	local tail = s:box(border, 150, -50, 34, 34, { color = "#C9A7FF" })
	gui.set_euler(tail, vmath.vector3(0, 0, 45))
	s:box(border, 150, -45, 30, 30, { color = "white" })
	kit.label({ ui = s }, bubble, i18n.tr(hint.text), 0, 0, { font = "body", size = 28, color = "#5220A6", max_width = 490, lines = 2 })
	-- the hand taps the star price
	local hand = s:image(holder, "ui/icons/hand", M.TASK_X + 236, -92, { w = 96, h = 96 })
	if hand and not fx.reduced() then
		local p = gui.get_position(hand)
		gui.animate(hand, "position", vmath.vector3(p.x - 14, p.y + 16, 0), gui.EASING_INOUTSINE, 0.45, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
	end
	if not fx.reduced() then ui.pulse(border, 0.025, 0.9) end
	self:target("hint", self:bottom(x, M.HINT_Y))
end

function Hud:chip_pos()
	return self:bottom(M.TASK_X + 212, M.TASK_Y + 4)
end

function Hud:thumb_pos()
	return self:bottom(M.TASK_X - 232, M.TASK_Y + 4)
end

-- The card after its task was done: it drops away (the new one comes in on rebuild).
function Hud:card_out()
	if not self.card then return end
	ui.stop_pulse(self.card)
	if fx.reduced() then return end
	gui.animate(self.card, "scale", vmath.vector3(0.01, 0.01, 1), gui.EASING_INBACK, 0.3)
end

function Hud:card_in()
	if not self.card or fx.reduced() then return end
	local p = gui.get_position(self.card)
	gui.set_position(self.card, vmath.vector3(p.x + 720, p.y, 0))
	gui.animate(self.card, "position.x", p.x, gui.EASING_OUTBACK, 0.45)
end

-- level button --------------------------------------------------------------------------------------

-- The round "Map" button at the right end of the level row (the level button is narrower to make room).
M.LEVEL_X, M.LEVEL_W, M.NOTE_X = 288, 470, 100
M.MAP_X, M.MAP_W = 620, 150

function Hud:build_map_button(parent)
	local s = self.ui
	local b = s:button({ parent = parent, x = M.MAP_X, y = M.LEVEL_Y, w = M.MAP_W, h = 130, style = "white", icon = "ui/icons/map",
		icon_size = 72, text = i18n.t("map.button"), text_size = 28, on_click = function()
			if self.town.bit then self.town.bit:cheer(1.0, 1) end
			app.show_screen("map", { from = "town" })
		end })
	s:anchor(b.node, "bottom")
	if b.icon then gui.set_position(b.icon, vmath.vector3(0, 22, 0)) end
	if b.label then
		gui.set_position(b.label, vmath.vector3(0, -34, 0))
		b.label_info.max_width = M.MAP_W - 24
		s:_fit_text(b.label, b.label_info)
	end
	self:target("map", self:bottom(M.MAP_X, M.LEVEL_Y))
	self.map_btn = b.node
end

function Hud:build_level(parent)
	local s, town = self.ui, self.town
	local v = views.level_button(app.meta, levels)
	self.level_view = v
	local x, y = M.LEVEL_X, M.LEVEL_Y
	self:build_map_button(parent)
	self.notes, self.closed = {}, {}
	if v.all_done then
		local b = s:button({ parent = parent, x = x, y = y, w = M.LEVEL_W, h = 128, style = "white", text = i18n.t("replay.button"),
			text_size = 34, on_click = function()
				if town.bit then town.bit:cheer(1.2, 1) end
				town:open_popup("replay") -- the beaten levels can be played again
			end })
		s:anchor(b.node, "bottom")
		self:target("level", self:bottom(x, y))
		self.level_btn = b.node
		return
	end
	local b = s:button({ parent = parent, x = x, y = y, w = M.LEVEL_W, h = 130, style = "green",
		icon = "ui/icons/play_dark", icon_size = 56,
		text = i18n.t("town.level", { n = v.level }), text_size = 48,
		on_click = function() town:open_popup("start", { level = v.level }) end })
	s:anchor(b.node, "bottom")
	self.level_btn = b.node
	self:target("level", self:bottom(x, y))
	if b.label then
		gui.set_position(b.label, vmath.vector3(-34, 6, 0))
		b.label_info.max_width = 216
		s:_fit_text(b.label, b.label_info)
	end
	-- hit streak: three notes inside the button. Once the streak runs (level 12 on) the note of a booster that
	-- is still locked is drawn closed; before that nothing runs and the notes are plain empty ones.
	for i, note in ipairs(v.notes) do
		local closed = v.streak_active and note.unlocked == false
		self.notes[i] = kit.note({ ui = s }, b.node, M.NOTE_X + (i - 1) * 42, 6, { lit = note.lit, unlocked = not closed }, 52, 0.55)
		self.closed[i] = closed
	end
	if v.tag then
		local hard = v.tag == "town.hard"
		local tag = s:round(b.node, 160, 70, 196, 50, hard and "pink" or "purple", { radius = 24 })
		s:round(tag, 0, 0, 186, 40, hard and "#FF7EB6" or "#C18CFF", { radius = 20, alpha = 0.6 })
		s:text(tag, i18n.t(v.tag), 0, 2, { font = "button", size = 24, color = "white", outline = hard and "#A8204F" or "#5220A6", max_width = 176 })
		gui.set_euler(tag, vmath.vector3(0, 0, -5))
		self.tag = tag
	end
	if not fx.reduced() then ui.pulse(b.node, 0.03, 0.9) end
end

function Hud:note_pos(i)
	return self:bottom(M.LEVEL_X + M.NOTE_X + (i - 1) * 42, M.LEVEL_Y + 6)
end

-- Is there a streak note `i` that can light up (its booster is unlocked)?
function Hud:note_open(i)
	return self.notes ~= nil and self.notes[i] ~= nil and not self.closed[i]
end

-- Lights the streak note `i` with a pop and sparkles. A closed note (its booster is still locked) stays
-- closed: false.
function Hud:streak_pop(i)
	if not self:note_open(i) then return false end
	local n = self.notes[i]
	local x, y = self:note_pos(i)
	gui.set_color(n, vmath.vector4(1, 1, 1, 1))
	self.town.fx:burst(x, y, { count = 8, radius = 70, size = 26 })
	self.town.fx:pop(n, 0.6, 0.4)
	return true
end

-- navigation -----------------------------------------------------------------------------------------

function Hud:build_nav(parent)
	local s, town = self.ui, self.town
	local NAV_CY = 82 -- the plate floats 14 px above the bottom edge: 136 px high, 700 wide
	local sh = s:round(parent, 360, NAV_CY - 6, 704, 140, "#CAB7DE", { alpha = 0.9, radius = 48 })
	s:anchor(sh, "bottom")
	local bar = s:round(parent, 360, NAV_CY, 700, 136, "#FAF6FF", { radius = 46 }) -- (not pure white: the window layout tests take a pure white box for a panel)
	s:anchor(bar, "bottom")
	self.nav = {}
	local items = M.nav_items(self.online and true or false)
	for i, item in ipairs(items) do
		local x = M.nav_x(i, #items)
		local b = s:button({ parent = bar, x = x, y = 0, w = M.NAV_TAB_W, h = 112, style = item.active and "purple" or "flat",
			icon = item.icon, icon_size = 60, sfx = item.soon and "tap" or "button",
			on_click = function() town:on_nav(item, self.nav[item.id]) end })
		if b.icon then
			gui.set_position(b.icon, vmath.vector3(0, 16, 0))
			if item.soon then gui.set_color(b.icon, vmath.vector4(1, 1, 1, 0.5)) end
		end
		s:text(b.node, i18n.t(item.label), 0, -34, {
			font = "small", size = 21, color = item.active and "white" or (item.soon and "text_soft" or "text"), max_width = 126,
		})
		if item.soon then
			local badge = s:round(b.node, 36, 50, 84, 30, "pink", { radius = 14 })
			s:text(badge, i18n.t("nav.soon"), 0, 1, { font = "small", size = 17, color = "white", max_width = 76 })
		end
		self.nav[item.id] = b.node
		self:target("nav_" .. item.id, self:bottom(360 + x, NAV_CY))
		if item.id == "notebook" then
			-- a dot at the corner of the icon says a finished song is waiting to be looked at
			if app.meta:songbook_pending() then
				self.notebook_dot = s:circle(b.node, 34, 42, 26, "pink")
				if self.notebook_dot and not fx.reduced() then ui.pulse(self.notebook_dot, 0.15, 0.6) end
			end
			self:target("notebook", self:bottom(360 + x, NAV_CY)) -- the name the QA tools know the songbook by
		end
	end
end

-- everything --------------------------------------------------------------------------------------------

function Hud:build()
	local s = self.ui
	if self.layer then s:clear(self.layer) end
	self.layer = s:layer(self.town.c_ui)
	self.targets = {}
	self.notebook_dot = nil
	-- a server is connected: the five tabs with Band and Chart (see M.nav_items); decided once per drawing, so the
	-- ribbon and the navigation always agree about where the songbook is
	self.online = social.available()
	self:build_top(self.layer)
	self:build_ribbon(self.layer)
	self:build_task(self.layer)
	self:build_level(self.layer)
	self:build_hint(self.layer)
	self:build_nav(self.layer)
	app.ui.targets = self.targets
end

return M
