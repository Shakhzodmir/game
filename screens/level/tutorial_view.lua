-- What the tutorial (client/tutorial.lua) looks like on the level screen, in a GUI scene
-- (client/ui.lua): a dim over everything but the cells (or the booster button) of the step, a soft
-- glow in the hole, a pointing hand (ui/icons/hand) that swipes or taps the way the player's input
-- mode asks, and a bubble with the text of the step, Bit's face, a skip button and, for a tip, "tap to
-- continue". Where things stand comes from client/level_hud.lua (pure, tested). The board still takes
-- the touches: the dim does not block them, the guard (client/level_link.lua) does.
--
--   local tv = tutorial_view.new(scene, {parent = layer, fx = fx, hud = hud, on_skip = fn()})
--   tv:set(v, rect)        -- v = tutorial:view() or nil; rect = link.board_rect(); redraws when it changed
--   tv:update(dt)          -- moves the hand
--   tv:shake()             -- a press was turned away: the bubble shakes
--   tv:set_visible(on)     -- hidden while a window is open
--   tv:clear()

local app = require("client.app")
local ui = require("client.ui")
local i18n = require("client.i18n")
local link = require("client.level_link")
local level_hud = require("client.level_hud")

local M = {}

M.DIM = "#3A2470"
M.DIM_ALPHA = 0.5
M.HAND = 112
M.BUBBLE_W = 620

local View = {}
View.__index = View

function M.new(scene, opts)
	return setmetatable({
		ui = scene, parent = opts.parent, fx = opts.fx, hud = opts.hud, on_skip = opts.on_skip,
		layer = nil, key = nil, t = 0, visible = true,
	}, View)
end

function View:clear()
	if self.layer then self.ui:clear(self.layer) end
	self.layer, self.hand, self.bubble, self.pts, self.mode, self.key = nil, nil, nil, nil, nil, nil
	self.was_down = false
	if self.hud then self.hud:set_bit_hidden(false) end
end

-- logical centres of the cells of a step, and the cell size
local function centres(cells)
	local out = {}
	for _, c in ipairs(cells) do
		local x, y = link.cell_center(c[1], c[2])
		if x then out[#out + 1] = { x, y } end
	end
	return out
end

-- Did anything that decides how the step looks change since it was drawn? (no allocation per frame)
local function changed(self, v, rect, fit)
	local k = self.key
	if not k then return true end
	return k.rev ~= v.rev or k.lang ~= i18n.language() or k.settings ~= app.settings_rev
		or k.ww ~= (fit and fit.ww) or k.wh ~= (fit and fit.wh)
		or k.x0 ~= (rect and rect.x0) or k.y0 ~= (rect and rect.y0) or k.x1 ~= (rect and rect.x1) or k.y1 ~= (rect and rect.y1)
end

local function remember(self, v, rect, fit)
	local k = self.key or {}
	k.rev, k.lang, k.settings = v.rev, i18n.language(), app.settings_rev
	k.ww, k.wh = fit and fit.ww, fit and fit.wh
	k.x0, k.y0, k.x1, k.y1 = rect and rect.x0, rect and rect.y0, rect and rect.x1, rect and rect.y1
	self.key = k
end

function View:set(v, rect)
	if not v then
		if self.layer then self:clear() end
		return
	end
	local s = self.ui
	if self.layer and not changed(self, v, rect, s.fit) then return end
	local fresh = (self.layer == nil) or (self.v_rev ~= v.rev)
	self:clear()
	remember(self, v, rect, s.fit)
	self.v_rev = v.rev
	local c = s:layer(self.parent, "tutorial")
	self.layer = c
	gui.set_enabled(c, self.visible)
	local safe = s.safe
	local vis = { x0 = safe.x0 - 2, y0 = safe.y0 - 2, x1 = safe.x1 + 2, y1 = safe.y1 + 2 }

	-- the hole: the lit cells, or the booster button
	local hole, pts
	if v.button then
		local r = self.hud and self.hud:booster_rect(v.button)
		if r then
			hole = { x0 = r.x0 - 10, y0 = r.y0 - 10, x1 = r.x1 + 10, y1 = r.y1 + 10 }
			pts = { { r.cx, r.cy } }
		end
	elseif #v.cells > 0 and rect then
		local cs = centres(v.cells)
		hole = level_hud.hole(cs, rect.cell, rect.cell * 0.08)
	end
	if v.hand and rect then pts = centres(v.hand.points) end
	if v.hand == nil and v.button then
		self.mode = "taps"
	else
		self.mode = v.hand and v.hand.mode or nil
	end
	self.pts = pts

	-- the dim
	if hole then
		for _, r in ipairs(level_hud.spotlight(vis, hole)) do
			s:box(c, r.cx, r.cy, r.w, r.h, { color = M.DIM, alpha = M.DIM_ALPHA })
		end
		local glow = s:round(c, (hole.x0 + hole.x1) / 2, (hole.y0 + hole.y1) / 2, hole.x1 - hole.x0, hole.y1 - hole.y0, "#FFE066",
			{ alpha = 0.26, radius = 22 })
		if not app.reduced_motion() then
			gui.animate(glow, "color.w", 0.08, gui.EASING_INOUTSINE, 0.55, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
		end
	else
		s:box(c, (vis.x0 + vis.x1) / 2, (vis.y0 + vis.y1) / 2, vis.x1 - vis.x0, vis.y1 - vis.y0, { color = M.DIM, alpha = 0.3 })
	end

	-- the hand
	if pts and #pts > 0 and self.mode then
		self.hand = s:image(c, "ui/icons/hand", pts[1][1], pts[1][2], { w = M.HAND, h = M.HAND })
		if self.hand then gui.set_color(self.hand, vmath.vector4(1, 1, 1, 0)) end
	end

	-- the bubble
	local text = v.text and i18n.has(v.text) and i18n.t(v.text) or ""
	local w = M.BUBBLE_W
	local h = (v.dismiss == "tap") and 168 or 140
	local br = level_hud.bubble_rect(safe, rect, hole, w, h)
	-- the bubble carries Bit's face: the mascot beside the board steps aside when it would be covered
	local bit_rect = self.hud and self.hud:bit_rect()
	if bit_rect then self.hud:set_bit_hidden(level_hud.overlaps(bit_rect, br)) end
	local panel = s:round(c, br.cx, br.cy, br.w, br.h, "white", { alpha = 0.98, radius = 34 })
	s:round(panel, 0, 0, br.w - 10, br.h - 10, "#F4EEFF", { radius = 30 })
	self.bubble = panel
	local face = s:image(panel, "bit/happy", -br.w / 2 + 70, 4, { w = 104, h = 104 })
	local tx = face and 38 or 0
	if text ~= "" then
		s:text(panel, text, tx, v.dismiss == "tap" and 18 or 4, {
			font = "body", size = 30, color = "text", width = br.w - 230, height = br.h - 60,
		})
	end
	if v.dismiss == "tap" then
		local hint = s:text(panel, i18n.t("tutorial.tap_continue"), tx, -br.h / 2 + 30, {
			font = "button", size = 24, color = "purple", max_width = br.w - 230,
		})
		if not app.reduced_motion() then ui.pulse(hint, 0.06, 0.6) end
	end
	-- skip
	s:button({ parent = panel, x = br.w / 2 - 98, y = br.h / 2 - 6, w = 172, h = 52, style = "white", text = i18n.t("common.skip"),
		text_size = 22, sfx = "tap", on_click = function() if self.on_skip then self.on_skip() end end })
	if fresh and not app.reduced_motion() then
		local base = gui.get_scale(panel)
		gui.set_scale(panel, base * 0.85)
		gui.animate(panel, "scale", base, gui.EASING_OUTBACK, 0.3)
	end
	self.t = 0
end

-- the hand follows the path of the step
function View:update(dt)
	if not self.layer or not self.hand or not self.pts or not self.mode or not self.visible then return end
	self.t = self.t + dt
	local pose = level_hud.hand_pose(self.mode, self.pts, self.t)
	local S = M.HAND
	gui.set_position(self.hand, vmath.vector3(pose.x + 0.20 * S, pose.y - 0.34 * S, 0))
	gui.set_scale(self.hand, vmath.vector3(pose.scale, pose.scale, 1))
	gui.set_color(self.hand, vmath.vector4(1, 1, 1, pose.alpha))
	if pose.down and not self.was_down and self.fx and not app.reduced_motion() then
		self.fx:ring(pose.x, pose.y, { size = 70, scale = 2.0, dur = 0.4, color = "#FFFFFF" })
	end
	self.was_down = pose.down
end

function View:shake()
	if self.bubble and self.fx then self.fx:shake(self.bubble, 12, 0.4) end
end

function View:set_visible(on)
	self.visible = on and true or false
	if self.layer then gui.set_enabled(self.layer, self.visible) end
end

return M
