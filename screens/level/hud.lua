-- The HUD of the level screen, drawn into a GUI scene (client/ui.lua): the top row (pause, the goals
-- with what is left of each, the moves badge), the booster bar (the five in-level boosters with their
-- counts, a "+" when the stock is empty, a lock before they open; in target mode the bar shows what to
-- pick and a cancel button), Bit beside the board, the flights of collected things to their goal icon,
-- and the score pops. The numbers come from the board (client/level_link.lua) and the meta; where
-- things stand comes from client/level_hud.lua (pure, tested); what Bit does from client/level_bit.lua.
-- Used by screens/level/level.gui_script, which owns the input and the windows.
--
--   local hud = hud_mod.new(scene, {fx = fx, layer = layer, actions = {pause, booster, cancel_booster}})
--   hud:build(info, status, board_rect)    -- (re)draws everything (a window resize, a new language)
--   hud:set_moves(left)   hud:on_goal(p)   hud:on_score(p)   hud:set_state(state)
--   hud:refresh_boosters()                 -- counts changed (the meta), the state changed
--   hud:set_target(booster id | nil)       -- target mode on / off
--   hud:set_pick(step)                     -- the Crossfader's prompt: 0 pick two pieces, 1 now the second
--   hud:on_bonus(p)                        -- level_bonus {adds = {{n, total, fill, special, ...}, ...}}: the bonus bar grows
--   hud:on_gift(p)                         -- level_bonus_gift {special, lx, ly}: the gift flies from the bar to its piece
--   hud:meter_rect()                       -- the bonus bar's logical rectangle (the tutorial, the flights)
--   hud:bit_event(topic, payload)          -- the board's topics for Bit
--   hud:update(dt)
--   hud:booster_rect(id), hud:goal_pos(k)  -- logical rectangles / positions (the tutorial, the flights)
--   hud:pick_bit(action)                   -- a tap on Bit? (he jumps and plays a note)
--   hud:set_bit_hidden(on), hud:bit_rect() -- the tutorial's bubble covers him: he steps aside

local app = require("client.app")
local ui = require("client.ui")
local i18n = require("client.i18n")
local audio = require("client.audio")
local bit = require("client.bit")
local levels = require("client.levels")
local link = require("client.level_link")
local level_hud = require("client.level_hud")
local level_bit = require("client.level_bit")
local fx = require("client.fx")

local M = {}

local BOOSTER_STYLE = { stick = "pink", row_light = "gold", col_light = "blue", remix = "purple", swap = "green" }
local BIT_SYNC_EVERY = 2.0 -- seconds between corrections of Bit's step to the music clock

local Hud = {}
Hud.__index = Hud

-- opts = {fx = client/fx.lua instance (flights, pops), layer = parent node of the HUD,
--         actions = {pause = fn(), booster = fn(id), cancel_booster = fn()}}
function M.new(scene, opts)
	local self = setmetatable({
		ui = scene, fx = opts.fx, parent = opts.layer, actions = opts.actions or {},
		moves = nil, goals = nil, state = "playing", target = nil,
		feed = level_hud.score_feed(), pops = 0, sync_t = 0, bit_slot = nil, built = false,
	}, Hud)
	return self
end

-- An image, or a soft disc when it is missing.
local function icon(s, parent, key, x, y, size, fallback)
	local n = key and s:image(parent, key, x, y, { w = size, h = size }) or nil
	if not n then n = s:circle(parent, x, y, size * 0.8, fallback or "lavender") end
	return n
end

local function booster_info(id)
	if not app.meta or not app.meta:run() then
		-- a debug level without an attempt: free boosters, all open
		return { count = nil, unlocked = true }
	end
	for _, b in ipairs(app.meta:inventory()) do
		if b.id == id then return { count = b.count, unlocked = b.unlocked, unlock_level = b.unlock_level } end
	end
	return { count = 0, unlocked = false }
end
M.booster_info = booster_info

-- building ---------------------------------------------------------------------------------------------------

function Hud:_goals(info, status)
	local s = self.ui
	local g = self.l.goals
	local panel = s:image(self.layer, "ui/panel", g.cx, g.cy, { w = g.w, h = g.h, slice9 = true })
		or s:round(self.layer, g.cx, g.cy, g.w, g.h, "white", { alpha = 0.95 })
	self.goals_panel = panel
	local tag = info.difficulty == "hard" and "hud.hard" or (info.difficulty == "super_hard" and "hud.super_hard" or nil)
	-- the level, and how hard it is (an honest signal) at the other end of the same line
	s:text(panel, i18n.t("hud.level", { n = info.level_id }), tag and (-g.w / 2 + 40) or 0, g.h / 2 - 34, {
		font = "button", size = 26, color = "text_soft", pivot = tag and gui.PIVOT_W or nil, max_width = tag and 190 or (g.w - 60),
	})
	if tag then
		local pill = s:round(panel, g.w / 2 - 108, g.h / 2 - 34, 160, 34, info.difficulty == "hard" and "pink" or "purple", { radius = 17 })
		s:text(pill, i18n.t(tag), 0, 1, { font = "button", size = 19, color = "white", max_width = 148 })
	end
	local goals = levels.goals({ goals = info.goals })
	local n = math.max(1, #goals)
	local slots = level_hud.goal_slots(n)
	self.goal_nodes, self.goal_defs, self.goal_slots = {}, goals, slots
	local counts = {}
	for k, gdef in ipairs(goals) do
		local left = status and status.goals and status.goals[k] or gdef.count or 0
		counts[k] = left
		local x = slots.xs[k]
		-- the title, the icon and the counter keep clear of the frame of the panel picture (14 px of border)
		local ic = icon(s, panel, gdef.image, x, 4, slots.icon * 0.88, "lavender")
		local txt, tinfo = s:text(panel, tostring(left), x, -g.h / 2 + 42, {
			font = "number", size = slots.text, color = "text", max_width = 120,
		})
		local check = s:image(panel, "ui/icons/check", x, -g.h / 2 + 42, { w = 48, h = 48 }) or s:circle(panel, x, -g.h / 2 + 42, 36, "green")
		gui.set_enabled(check, false)
		self.goal_nodes[k] = { icon = ic, text = txt, info = tinfo, check = check, x = x }
	end
	-- what the counters show: kept across rebuilds
	if not self.goals or #self.goals.shown ~= #counts then
		self.goals = level_hud.goals_new(counts)
	end
	for k = 1, #goals do self:_show_goal(k, false) end
end

-- shows the counter of goal k as the tracker has it (a tick when done)
function Hud:_show_goal(k, pop)
	local gn = self.goal_nodes and self.goal_nodes[k]
	if not gn then return end
	local left = self.goals.shown[k] or 0
	local done = left <= 0
	self.ui:set_text(gn.text, tostring(math.max(0, left)), gn.info)
	gui.set_enabled(gn.text, not done)
	local was = gn.done
	gn.done = done
	gui.set_enabled(gn.check, done)
	if pop and not app.reduced_motion() then
		gui.cancel_animations(gn.icon, "scale")
		gui.set_scale(gn.icon, vmath.vector3(1.25, 1.25, 1))
		gui.animate(gn.icon, "scale", vmath.vector3(1, 1, 1), gui.EASING_OUTBACK, 0.3)
		if done and not was then ui.pop_in(gn.check, 0, 0.3) end
	end
end

function Hud:_moves(status)
	local s = self.ui
	local m = self.l.moves
	local badge = s:image(self.layer, "ui/moves_badge", m.cx, m.cy, { w = m.w, h = m.h, slice9 = true })
		or s:circle(self.layer, m.cx, m.cy, m.w * 0.9, "pink")
	self.moves_badge = badge
	self.moves_low = nil
	self.moves_text, self.moves_info = s:text(badge, "–", 0, 12, {
		font = "title", size = 64, color = "white", outline = "#A8204F", max_width = 130,
	})
	s:text(badge, i18n.t("hud.moves"), 0, -46, { font = "button", size = 24, color = "white", outline = "#A8204F", max_width = 130 })
	self:set_moves(self.moves or (status and status.moves_left) or 0, true)
end

function Hud:_bar()
	local s = self.ui
	local b = self.l.bar
	local bar = s:image(self.layer, "ui/panel", b.cx, b.cy, { w = b.w, h = b.h, slice9 = true })
		or s:round(self.layer, b.cx, b.cy, b.w, b.h, "white", { alpha = 0.92 })
	self.bar = bar
	self.c_btn = s:layer(bar)
	self.btns = {}
	local xs = level_hud.bar_slots()
	local bb = level_hud.BAR_BUTTONS
	for i, id in ipairs(level_hud.BOOSTERS) do
		local btn = s:button({ parent = self.c_btn, x = xs[i], y = 2, w = bb.w, h = bb.h, style = BOOSTER_STYLE[id],
			icon = "ui/icons/" .. id, icon_size = 72, sfx = "booster", on_click = function() self:_tap_booster(id) end })
		local badge = s:image(btn.node, "ui/badge_count", 46, 40, { w = 46, h = 46 }) or s:circle(btn.node, 46, 40, 46, "green")
		local bt, binfo = s:text(badge, "", 0, 1, { font = "number", size = 26, color = "white", outline = "#0F7A3B", max_width = 40 })
		-- the count dims with the face of a button that cannot be used now; the plus (a call to buy) and the
		-- padlock stay as they are on purpose
		gui.set_inherit_alpha(badge, true)
		gui.set_inherit_alpha(bt, true)
		local plus = s:image(btn.node, "ui/icons/plus", 40, 36, { w = 56, h = 56 }) or s:circle(btn.node, 40, 36, 44, "green")
		local lock = s:image(btn.node, "ui/icons/lock", 30, -30, { w = 44, h = 44 })
		self.btns[id] = { btn = btn, badge = badge, text = bt, info = binfo, plus = plus, lock = lock, x = xs[i] }
	end
	self:refresh_boosters()
end

function Hud:_bit()
	local sl = self.l.slot
	self.bit_slot = sl
	if self.c_bit then self.ui:clear(self.c_bit) end
	self.c_bit = self.ui:layer(self.layer)
	if self.bit_hidden then gui.set_enabled(self.c_bit, false) end
	self.bit = bit.new(self.ui, self.c_bit, sl.x, sl.y, sl.size)
	self.beat = nil
	if self.bit_machine then
		-- the machine keeps its state across a rebuild: say what he is doing now
		self.bit_machine:set_reduced(app.reduced_motion())
		self.bit_machine:replay()
		self:_apply_bit(self.bit_machine:take())
	end
end

-- Draws everything. info = link.info(), status = link.status(), rect = link.board_rect().
function Hud:build(info, status, rect)
	local s = self.ui
	if self.layer then s:clear(self.layer) end
	self.c_bit, self.c_target, self.cancel_btn, self.bit = nil, nil, nil, nil -- they went with the layer
	self.layer = s:layer(self.parent, "hud")
	self.info = info
	self.l = level_hud.layout(s.fit, s.insets, rect)
	self.rect_ref = rect
	if status then
		if not self.moves then self.moves = status.moves_left end
		self.state = status.state or self.state
	end
	local l = self.l
	local pause = s:button({ parent = self.layer, x = l.pause.cx, y = l.pause.cy, w = l.pause.w, h = l.pause.h, style = "purple",
		icon = "ui/icons/pause", icon_size = 60, text = (not require("client.assets").has_image("ui/icons/pause")) and "II" or nil,
		on_click = function() if self.actions.pause then self.actions.pause() end end })
	self.pause_btn = pause
	self:_goals(info, status)
	self:_moves(status)
	self:_bar()
	self:_meter()
	self:_bit()
	if self.target then
		local id, step = self.target, self.pick_step
		self.target = nil
		self:set_target(id)
		if step == 1 then self:set_pick(1) end -- a first piece of the Crossfader stays picked across a rebuild
	end
	self.built = true
end

-- Moves the things that depend on the board's rectangle when it changed without a window resize
-- (the board is laid out after the HUD in the same frame). Returns true when it had to.
function Hud:follow_board(rect)
	-- link.board_rect() hands out the same table while the board stays (no allocation per frame)
	if rect == self.rect_ref or not self.built then return false end
	self.rect_ref = rect
	self.l = level_hud.layout(self.ui.fit, self.ui.insets, rect)
	self:_bit()
	return true
end

-- goals --------------------------------------------------------------------------------------------------------

function Hud:goal_pos(k)
	local g = self.l.goals
	local x = self.goal_slots and self.goal_slots.xs[k] or 0
	return g.cx + x, g.cy + 6
end

-- A goal went down (bus level_goal {index, left, kind, color, item, lx, ly}).
function Hud:on_goal(p)
	if not self.goals then return end
	local k = p.index
	local from = p.lx and p.ly
	local gdef = self.goal_defs and self.goal_defs[k]
	local what, changed = self.goals:event(k, p.left, from and gdef ~= nil)
	if what == "set" then
		if changed then self:_show_goal(k, true) end
		return
	end
	-- a flyer takes the collected thing to its goal icon; the counter follows when it lands
	local left = p.left
	self.fx:fly({
		image = gdef.image, size = 54, from = { p.lx, p.ly }, dur = 0.45, arc = (k % 2 == 0 and -1 or 1) * 90, scale_to = 0.6,
		to = function() return self:goal_pos(k) end,
		on_land = function()
			if not self.goals then return end
			local changed = self.goals:land(k, left)
			self:_show_goal(k, true)
			if changed and left <= 0 then
				local x, y = self:goal_pos(k)
				self.fx:ring(x, y, { size = 90, scale = 2.2, dur = 0.5, color = "#7CF0A8" })
				self.fx:burst(x, y, { count = 10, radius = 90, size = 28 })
			end
		end,
	})
end

-- moves --------------------------------------------------------------------------------------------------------

function Hud:set_moves(left, force)
	if not self.moves_text then return end
	local changed = left ~= self.moves
	self.moves = left
	self.ui:set_text(self.moves_text, tostring(left), self.moves_info)
	local st = level_hud.moves_state(left)
	local reduced = app.reduced_motion()
	if st.low ~= self.moves_low or force then
		self.moves_low = st.low
		local c = st.low and vmath.vector4(1, 0.52, 0.52, 1) or vmath.vector4(1, 1, 1, 1)
		gui.set_color(self.moves_badge, c)
		if st.low and not reduced then ui.pulse(self.moves_badge, 0.07, 0.35) else ui.stop_pulse(self.moves_badge) end
	end
	if changed and not force and not reduced and not st.low then
		gui.cancel_animations(self.moves_text, "scale")
		local base = gui.get_scale(self.moves_text)
		gui.set_scale(self.moves_text, base * 1.25)
		gui.animate(self.moves_text, "scale", base, gui.EASING_OUTBACK, 0.25)
	end
end

-- boosters -----------------------------------------------------------------------------------------------------

function Hud:_tap_booster(id)
	if self.actions.booster then self.actions.booster(id) end
end

function Hud:booster_rect(id)
	local b = self.btns and self.btns[id]
	if not b then return nil end
	local bar, bb = self.l.bar, level_hud.BAR_BUTTONS
	return level_hud.rect(bar.cx + b.x, bar.cy + 2, bb.w, bb.h)
end

-- The state of the booster buttons from the meta and the game state.
function Hud:refresh_boosters()
	if not self.btns then return end
	local dim = not level_hud.USABLE[self.state or "playing"]
	for _, id in ipairs(level_hud.BOOSTERS) do
		local b = self.btns[id]
		local info = booster_info(id)
		local st = level_hud.booster_state(info)
		b.st = st
		gui.set_enabled(b.badge, st.badge == true)
		if st.badge then self.ui:set_text(b.text, tostring(st.count or ""), b.info) end
		gui.set_enabled(b.plus, st.plus == true)
		if b.lock then gui.set_enabled(b.lock, st.lock == true) end
		local a = (st.dim or dim) and 0.5 or 1
		gui.set_color(b.btn.node, vmath.vector4(1, 1, 1, a))
		-- the icon takes the face's alpha (client/ui.lua lets a button's icon inherit it): its own colour is a tint only
		if b.btn.icon then
			gui.set_color(b.btn.icon, st.mode == "locked" and vmath.vector4(0.75, 0.72, 0.85, 1) or vmath.vector4(1, 1, 1, 1))
		end
		b.unlock_level = info.unlock_level
	end
end

function Hud:set_state(state)
	if state == self.state then return end
	self.state = state
	self:refresh_boosters()
end

-- Target mode: the bar shows the booster being aimed, what to pick and a cancel button.
function Hud:set_target(id)
	if id == self.target or not self.bar then return end
	local s = self.ui
	if self.c_target then
		s:clear(self.c_target)
		self.c_target = nil
	end
	self.target = id
	if not id then
		gui.set_enabled(self.c_btn, true)
		return
	end
	gui.set_enabled(self.c_btn, false)
	local c = s:layer(self.bar)
	self.c_target = c
	local tile = s:round(c, level_hud.BAR_BUTTONS.x0, 2, 104, 96, "#F4EEFF", { radius = 30 })
	icon(s, tile, "ui/icons/" .. id, 0, 2, 72, "purple")
	if not app.reduced_motion() then ui.pulse(tile, 0.08, 0.3) end
	self.pick_text, self.pick_info = s:text(c, i18n.t(level_hud.PROMPT[id] or "hud.pick_cell"), -20, 2, {
		font = "button", size = 34, color = "purple", max_width = 280,
	})
	self.pick_step = 0
	local cancel = s:button({ parent = c, x = 236, y = 2, w = 200, h = 84, style = "pink", icon = "ui/icons/close", icon_size = 40,
		text = i18n.t("common.cancel"), text_size = 28, on_click = function()
			if self.actions.cancel_booster then self.actions.cancel_booster() end
		end })
	self.cancel_btn = cancel
end

-- The Crossfader takes two pieces: once the first is picked the prompt asks for the second (step 1), and
-- goes back to asking for two when it is let go (step 0).
function Hud:set_pick(step)
	step = step == 1 and 1 or 0
	if self.target == nil or not level_hud.PROMPT2[self.target] or not self.pick_text or step == self.pick_step then return end
	self.pick_step = step
	local key = step == 1 and level_hud.PROMPT2[self.target] or level_hud.PROMPT[self.target]
	self.ui:set_text(self.pick_text, i18n.t(key), self.pick_info)
end

-- Bit ---------------------------------------------------------------------------------------------------------

function Hud:_beat_sync(force)
	local b = self.bit
	if not b or not b.beat then return end
	local clock = audio.status and audio.status.clock or 0
	if clock <= 0 then return end
	if not force and self.sync_t < BIT_SYNC_EVERY then return end
	self.sync_t = 0
	b.beat_t = clock % b.beat
end

function Hud:_apply_bit(actions)
	local b = self.bit
	if not b then return end
	for _, a in ipairs(actions) do
		if a.op == "dance" then
			b:dance(a.bpm)
			self:_beat_sync(true)
		elseif a.op == "idle" then
			b:stop()
		elseif a.op == "stay" then
			b:mood_for(1e9, a.mood)
		elseif a.op == "mood" then
			b:mood_for(a.seconds, a.mood)
		elseif a.op == "worry" then
			b:worry(a.seconds)
		elseif a.op == "cheer" then
			b:cheer(a.seconds, a.times)
		end
	end
end

-- The mood machine of Bit (created once the board has said how the level starts).
function Hud:start_bit(state, left)
	local d = app.district(app.focus_district())
	self.bit_machine = level_bit.new({ bpm = d and d.bpm or 100, reduced = app.reduced_motion(), state = state, left = left })
	self:_apply_bit(self.bit_machine:take())
end

function Hud:bit_event(topic, p)
	if not self.bit_machine then return end
	self.bit_machine:event(topic, p)
	self:_apply_bit(self.bit_machine:take())
end

function Hud:set_reduced(on)
	if self.bit_machine then
		self.bit_machine:set_reduced(on)
		self:_apply_bit(self.bit_machine:take())
	end
end

-- The mascot steps aside while the tutorial's bubble (which has his face too) would cover him.
function Hud:set_bit_hidden(on)
	on = on and true or false
	if on == (self.bit_hidden or false) then return end
	self.bit_hidden = on
	if self.c_bit then gui.set_enabled(self.c_bit, not on) end
end

-- The rectangle Bit stands in (logical), or nil before the HUD is built.
function Hud:bit_rect()
	local sl = self.bit_slot
	return sl and level_hud.rect(sl.x, sl.y, sl.size, sl.size) or nil
end

-- A tap on Bit: he jumps and plays a note. Returns true when the tap was his.
function Hud:pick_bit(action)
	if not self.bit or not self.bit_slot or not self.bit_slot.tappable or self.bit_hidden then return false end
	if self.bit:pick(action) then
		self.bit:poke()
		return true
	end
	return false
end

-- the bonus bar ------------------------------------------------------------------------------------------------
-- Above the booster bar (client/level_hud.lua METER): a capsule that fills while specials fire (client/bonus_meter.lua
-- counts), a note at its start, the gift at its end. Each addition: the fill grows with a pulse, sparks at its tip, a
-- "+n" and a note that climbs the scale; at 8 and 9 of 10 the gift trembles and the capsule glows ("will it fill?");
-- at 10 a flash and a ring at the gift, a fanfare, and the gift flies to the piece the core chose (on_gift).

local METER_EDGE, METER_BACK = "#7B5CD6", "#EADFFF"
local meter_hinted = false -- the first addition of a session says what the bar is for (a toast)
local METER_GIFT_ICON = "ui/icons/gift"

function Hud:_meter()
	local s = self.ui
	self.mtr, self.m_tense = nil, false
	local mi = self.info and self.info.meter
	if not (mi and mi.enabled) then return end
	local m = self.l.meter
	self.m_thr = mi.threshold or 10
	if self.m_pts == nil then self.m_pts = mi.points or 0 end
	local root = s:layer(self.layer, "bonus")
	local inner_w, inner_h = m.w - 24, m.h - 12
	local x0 = m.cx - inner_w / 2
	s:round(root, m.cx, m.cy, m.w + 6, m.h + 6, METER_EDGE, { alpha = 0.95 })
	local back = s:round(root, m.cx, m.cy, m.w, m.h, METER_BACK, { alpha = 0.97 })
	local fill = s:round(root, x0, m.cy, inner_h, inner_h, "#FF5FA2", { pivot = gui.PIVOT_W })
	for i = 1, self.m_thr - 1 do
		s:box(root, x0 + inner_w * i / self.m_thr, m.cy, 2, inner_h - 8, { color = "#FFFFFF", alpha = 0.6 })
	end
	local nx = m.cx - m.w / 2 + 4
	local gx, gy = m.cx + m.w / 2 + 2, m.cy + 4
	local note = s:image(root, "ui/icons/note_on", nx, m.cy, { w = 34, h = 34 })
	if not note then s:circle(root, nx, m.cy, 28, "#FFD84D") end
	local gift = s:image(root, METER_GIFT_ICON, gx, gy, { w = 54, h = 54 }) or s:circle(root, gx, gy, 44, "#FFB020")
	local label, linfo = s:text(root, "", m.cx, m.cy, { font = "number", size = 22, color = "white", outline = METER_EDGE, max_width = 110 })
	self.mtr = { root = root, back = back, fill = fill, gift = gift, label = label, linfo = linfo,
		x0 = x0, w = inner_w, h = inner_h, cy = m.cy, gx = gx, gy = gy }
	self:_meter_set(self.m_pts, false)
end

function Hud:meter_rect()
	return self.l and self.l.meter or nil
end

-- The fill and the label for `points`; animated when the bar grows in front of the player.
function Hud:_meter_set(points, animate)
	local mt = self.mtr
	if not mt then return end
	local st = level_hud.meter_state(points, self.m_thr)
	local w = math.max(mt.h, st.frac * mt.w)
	local col = ui.color(level_hud.meter_color(st.frac))
	gui.set_enabled(mt.fill, points > 0)
	gui.cancel_animations(mt.fill, "size.x")
	if animate and not app.reduced_motion() then
		gui.animate(mt.fill, "size.x", w, gui.EASING_OUTQUAD, 0.35)
		gui.animate(mt.fill, "color", col, gui.EASING_LINEAR, 0.35)
	else
		gui.set_size(mt.fill, vmath.vector3(w, mt.h, 0))
		gui.set_color(mt.fill, col)
	end
	self.ui:set_text(mt.label, st.label, mt.linfo)
	self:_meter_tense(st.tense)
end

-- The tremble of the gift and the glow of the capsule while 8 or 9 of 10 are in.
function Hud:_meter_tense(on)
	local mt = self.mtr
	if not mt or on == self.m_tense then return end
	self.m_tense = on
	gui.cancel_animations(mt.gift, "euler.z")
	gui.cancel_animations(mt.back, "color.w")
	if on and not app.reduced_motion() then
		gui.set_euler(mt.gift, vmath.vector3(0, 0, -9))
		gui.animate(mt.gift, "euler.z", 9, gui.EASING_INOUTSINE, 0.16, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
		gui.animate(mt.back, "color.w", 0.65, gui.EASING_INOUTSINE, 0.35, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
	else
		gui.set_euler(mt.gift, vmath.vector3(0, 0, 0))
		gui.set_color(mt.back, ui.color(METER_BACK, 0.97))
	end
end

local METER_TIP_COLORS = { "#FFFFFF", "#FFF3A6", "#FF9A3D", "#FF5FA2" }

-- level_bonus: the additions of one tick, in order. A chain can fire dozens of specials in a moment (a Disco ball, a
-- final concert): the bar runs through all of them but the effects are made once per call and at most METER_FX_LIVE
-- at a time, so the GUI scene never runs out of animations (the engine drops the ones past gui.max_animation_count).
local METER_FX_LIVE = 3

function Hud:on_bonus(p)
	local mt = self.mtr
	if not mt or not p or not p.adds or #p.adds == 0 then return end
	local thr = self.m_thr
	local sum, passed_full, last = 0, false, p.adds[#p.adds]
	for _, a in ipairs(p.adds) do
		sum = sum + (a.n or 1)
		if a.fill then passed_full = true end
		self.m_pts = a.fill and (a.total - thr) or a.total
	end
	local shown = last.fill and thr or (last.total or 0)
	if passed_full and not last.fill then shown = thr end -- it was full on the way: show that, then drain
	shown = math.min(shown, thr)
	local tipx = mt.x0 + mt.w * shown / thr
	self:_meter_set(shown, true)
	self.fx:pop(mt.back, 0.06, 0.25)
	pcall(audio.play_note, "yellow", math.max(1, math.min(shown, 9))) -- a note of the scale that climbs with the bar
	if not meter_hinted then -- once per session: what the bar is for
		meter_hinted = true
		pcall(app.toast_key, "hud.bonus_hint", nil, { color = "purple", duration = 3 })
	end
	self.m_live = self.m_live or 0
	if self.m_live < METER_FX_LIVE then
		self.m_live = self.m_live + 1
		local k = math.min(sum, 3)
		self.fx:burst(tipx, mt.cy, { count = 5 + 3 * k, radius = 34 + 14 * k, size = 22, dur = 0.5, colors = METER_TIP_COLORS })
		self.fx:float_text("+" .. tostring(sum), tipx, mt.cy + 26, { size = 34, color = "#FFF3A6", outline = METER_EDGE,
			dur = 0.7, rise = 50, max_width = 120 })
		self.fx:after(0.8, function() self.m_live = math.max(0, (self.m_live or 1) - 1) end)
	end
	if passed_full and not self.m_fill_fx then
		-- full: flash and ring at the gift, the fanfare, then the bar drains to what was carried over
		self.m_fill_fx = true
		self.fx:flash(mt.gx, mt.gy, { size = 220, color = "#FFF3A6", dur = 0.5 })
		self.fx:ring(mt.gx, mt.gy, { size = 110, scale = 3, dur = 0.6, color = "#FFD84D" })
		self.fx:burst(mt.gx, mt.gy, { count = 16, radius = 110, size = 30, dur = 0.7 })
		self.fx:shake(mt.gift, 8, 0.4)
		pcall(audio.sfx, "star")
		self.fx:after(0.55, function()
			self.m_fill_fx = false
			if self.mtr == mt then self:_meter_set(self.m_pts, true) end
		end)
	end
end

-- level_bonus_gift: the core put the gift on the board; it flies from the bar to the new special and blooms there.
function Hud:on_gift(p)
	local mt = self.mtr
	if not mt or not p then return end
	self.fx:fly({ image = METER_GIFT_ICON, size = 64, from = { mt.gx, mt.gy }, to = { p.lx, p.ly }, dur = 0.55, arc = 160,
		spin = 360, trail = "#FFD84D", on_land = function(x, y)
			self.fx:flash(x, y, { size = 200, color = "#FFF3A6", dur = 0.4 })
			self.fx:burst(x, y, { count = 12, radius = 90, size = 30, dur = 0.6 })
			pcall(audio.sfx, "special_create")
		end })
end

-- score pops ------------------------------------------------------------------------------------------------

function Hud:on_score(p)
	self.feed:add(p.delta, p.lx, p.ly)
end

local POP_STYLE = {
	{ size = 40, color = "white", outline = "#FF4D8D" },
	{ size = 52, color = "#FFF3A6", outline = "#E07F00" },
	{ size = 66, color = "#FFE066", outline = "#8B45FF" },
}

function Hud:update(dt)
	if self.bit then self.bit:update(dt) end
	if self.bit_machine then
		self.bit_machine:update(dt)
		if self.bit_machine:pending() then self:_apply_bit(self.bit_machine:take()) end
	end
	self.sync_t = self.sync_t + dt
	if self.bit and self.bit.beat then self:_beat_sync(false) end
	local pop = self.feed:update(dt)
	if pop and self.pops < 6 and not app.reduced_motion() then
		local st = POP_STYLE[pop.size] or POP_STYLE[1]
		self.pops = self.pops + 1
		self.fx:float_text("+" .. i18n.number(pop.delta), pop.x, pop.y, {
			size = st.size, color = st.color, outline = st.outline, shadow = st.outline, dur = 0.8, rise = 70, max_width = 240,
		})
		self.fx:after(0.8, function() self.pops = math.max(0, self.pops - 1) end)
	end
end

return M
