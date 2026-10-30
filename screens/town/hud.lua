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
local kit = require("gui.kit")

local M = {}

M.TOP_Y = 1214
M.RIBBON_Y = 1108
M.TASK_Y = 382
M.TASK_X = 316
M.LEVEL_Y = 226
M.NAV_Y = 40
M.LIVES_X, M.COINS_X, M.STARS_X, M.GEAR_X = 118, 336, 520, 660
M.BIT_X, M.BIT_Y = 660, 398

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
	local sh = s:round(parent, x, M.TOP_Y - 7, w, 80, "#D66E8C", { alpha = 0.22, radius = 38 })
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
		font = "number", size = 34, color = "text", pivot = gui.PIVOT_W, max_width = 96,
	})
	hit(s, cp, -30, 0, 150, 100, function() town:open_popup("shop", { tab = "coins" }) end)
	local plus = s:image(cp, "ui/icons/plus", 78, 2, { w = 58, h = 58 })
	if not plus then
		plus = s:circle(cp, 78, 2, 50, "green")
		s:text(plus, "+", 0, 2, { font = "button", size = 38, color = "white" })
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
		app.toast_key("town.stars_hint", nil, { color = "gold" })
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
function Hud:level_pos() return self:bottom(360, M.LEVEL_Y) end

-- ribbon ----------------------------------------------------------------------------------------

M.RIBBON_X, M.RIBBON_W = 328, 484
M.NAV_RIBBON_X, M.NAV_RIBBON_W = 312, 388 -- the narrower ribbon between the two district arrows
M.ARROW_PREV_X, M.ARROW_NEXT_X = 68, 550

local function arrow_button(self, parent, x, dir, enabled)
	local s, town = self.ui, self.town
	local has_icon = assets.has_image("ui/icons/arrow")
	local b = s:button({ parent = parent, x = x, y = M.RIBBON_Y, w = 80, h = 80, style = "blue", icon = "ui/icons/arrow", icon_size = 48,
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
	s:text(rib, i18n.name(p.name), 0, 22, { font = "button", size = paged and 30 or 34, color = "white", outline = "#5220A6",
		shadow = "#5220A6", max_width = rw - 44 })
	s:text(rib, i18n.t("town.layers", { done = p.done, total = p.total }), 0, -10, {
		font = "small", size = 21, color = "#F1E6FF", max_width = rw - 64,
	})
	-- the track progress: one segment per layer
	local n = math.max(1, p.total)
	local bw = rw - 84
	local seg = (bw - (n - 1) * 5) / n
	for i = 1, n do
		local x = -bw / 2 + (i - 0.5) * seg + (i - 1) * 5
		s:round(rib, x, -36, seg, 12, i <= p.done and "#FFDB1A" or "#6A2BD1", { radius = 5 })
	end
	if paged then
		arrow_button(self, parent, M.ARROW_PREV_X, -1, nav.prev ~= nil)
		arrow_button(self, parent, M.ARROW_NEXT_X, 1, nav.next ~= nil)
	end
	local view = app.meta:view(town.district)
	local toggle = s:button({ parent = parent, x = 652, y = M.RIBBON_Y, w = 112, h = 96, style = view == "day" and "blue" or "gold",
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
		local card = s:button({ parent = parent, x = x, y = y, w = 588, h = 128, style = "blue",
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
			font = "button", size = 32, color = "white", outline = "#174E9E", shadow = "#174E9E", max_width = 440, lines = 2,
		})
		return
	end
	local card = s:button({ parent = parent, x = x, y = y, w = 588, h = 128, style = "white",
		on_click = function() town:on_task(task) end })
	s:anchor(card.node, "bottom")
	self.card = card.node
	self:target("task", self:bottom(x, y))
	local thumb = s:round(card.node, -232, 4, 104, 104, "#FFE3EF", { radius = 28 })
	self.thumb = thumb
	if not s:image(thumb, task.image, 0, 0, { w = 92, h = 92 }) then s:circle(thumb, 0, 0, 70, "lavender") end
	s:text(card.node, i18n.name(task.name), -168, 26, {
		font = "button", size = 30, color = "text", pivot = gui.PIVOT_W, max_width = 300,
	})
	s:text(card.node, i18n.t("town.task_adds", { stem = i18n.t("stem." .. task.stem) }), -168, -14, {
		font = "small", size = 22, color = "purple", pivot = gui.PIVOT_W, max_width = 300,
	})
	if task.affordable then
		s:text(card.node, i18n.t("town.task_ready"), -168, -44, {
			font = "small", size = 19, color = "green", pivot = gui.PIVOT_W, max_width = 300,
		})
	else
		s:text(card.node, i18n.t("town.task_need", { n = task.need }), -168, -44, {
			font = "small", size = 19, color = "text_soft", pivot = gui.PIVOT_W, max_width = 300,
		})
	end
	local chip
	if task.affordable then
		chip = s:image(card.node, "ui/button_gold", 212, 4, { w = 124, h = 92, slice9 = true })
			or s:round(card.node, 212, 4, 124, 92, "gold")
	else
		chip = s:round(card.node, 212, 4, 124, 92, "#EFE8FF", { radius = 30 })
	end
	self.chip = chip
	local st = icon(s, chip, "ui/icons/star", 28, 4, 50, "yellow")
	self.chip_star = st
	if not task.affordable then gui.set_color(st, vmath.vector4(1, 1, 1, 0.55)) end
	s:text(chip, tostring(task.cost), -18, 6, {
		font = "number", size = 42, color = task.affordable and "white" or "text_soft",
		outline = task.affordable and "#C96A00" or false,
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

function Hud:build_level(parent)
	local s, town = self.ui, self.town
	local v = views.level_button(app.meta, levels)
	self.level_view = v
	local x, y = 360, M.LEVEL_Y
	self.notes, self.closed = {}, {}
	if v.all_done then
		local b = s:button({ parent = parent, x = x, y = y, w = 560, h = 128, style = "blue", text = i18n.t("town.all_done"),
			text_size = 34, on_click = function()
				app.toast_key("town.all_done", nil, { color = "blue" })
				if town.bit then town.bit:cheer(1.2, 1) end
			end })
		s:anchor(b.node, "bottom")
		self:target("level", self:bottom(x, y))
		self.level_btn = b.node
		return
	end
	local b = s:button({ parent = parent, x = x, y = y, w = 560, h = 130, style = "green",
		text = i18n.t("town.level", { n = v.level }), text_size = 54,
		on_click = function() town:open_popup("start", { level = v.level }) end })
	s:anchor(b.node, "bottom")
	self.level_btn = b.node
	self:target("level", self:bottom(x, y))
	if b.label then
		gui.set_position(b.label, vmath.vector3(-62, 6, 0))
		b.label_info.max_width = 320
		s:_fit_text(b.label, b.label_info)
	end
	-- hit streak: three notes inside the button. Once the streak runs (level 12 on) the note of a booster that
	-- is still locked is drawn closed; before that nothing runs and the notes are plain empty ones.
	for i, note in ipairs(v.notes) do
		local closed = v.streak_active and note.unlocked == false
		self.notes[i] = kit.note({ ui = s }, b.node, 136 + (i - 1) * 46, 6, { lit = note.lit, unlocked = not closed }, 52, 0.55)
		self.closed[i] = closed
	end
	if v.tag then
		local hard = v.tag == "town.hard"
		local tag = s:round(b.node, 188, 70, 196, 50, hard and "pink" or "purple", { radius = 24 })
		s:round(tag, 0, 0, 186, 40, hard and "#FF7EB6" or "#C18CFF", { radius = 20, alpha = 0.6 })
		s:text(tag, i18n.t(v.tag), 0, 2, { font = "button", size = 24, color = "white", outline = hard and "#A8204F" or "#5220A6", max_width = 176 })
		gui.set_euler(tag, vmath.vector3(0, 0, -5))
		self.tag = tag
	end
	if not fx.reduced() then ui.pulse(b.node, 0.03, 0.9) end
end

function Hud:note_pos(i)
	return self:bottom(360 + 136 + (i - 1) * 46, M.LEVEL_Y + 6)
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
	local bar = s:round(parent, 360, M.NAV_Y, 744, 196, "white", { alpha = 0.97, radius = 40 })
	s:anchor(bar, "bottom")
	s:round(bar, 0, 98, 744, 6, "#FFE3EF", { radius = 3 })
	self.nav = {}
	for i, item in ipairs(M.NAV) do
		local x = -288 + (i - 1) * 144
		local b = s:button({ parent = bar, x = x, y = 32, w = 134, h = 116, style = item.active and "purple" or "white",
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
		self:target("nav_" .. item.id, self:bottom(360 + x, M.NAV_Y + 32))
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
	self:build_hint(self.layer)
	self:build_nav(self.layer)
	app.ui.targets = self.targets
end

return M
