-- District Concert: the last task of a district is done and the whole
-- street plays. Full screen: the concert background with every item lit,
-- sweeping spotlights, confetti, notes floating up on the beat, Bit
-- dancing, the full song (every stem + the party layer). 12 s, or a tap to
-- skip. The town then opens the district chest and slides the next district in.
-- params = {district = id, duration = seconds}
-- Result: "done" (played to the end) or "skip".

local app = require("client.app")
local i18n = require("client.i18n")
local audio = require("client.audio")
local assets = require("client.assets")
local ui = require("client.ui")
local fx = require("client.fx")
local kit = require("gui.kit")
local scene = require("screens.town.scene")

local M = {}

M.fullscreen = true
M.dim_color = "#3B2A8F"
M.dim_alpha = 1
M.no_back = true
M.DURATION = 12

local BEAMS = {
	{ x = 110, color = "#FF4FD8", a0 = -24, a1 = 14, period = 3.1 },
	{ x = 360, color = "#3CF2FF", a0 = 18, a1 = -18, period = 2.6 },
	{ x = 610, color = "#FFE66D", a0 = 24, a1 = -14, period = 3.4 },
}

local NOTE_COLORS = { "#FF4D8D", "#FFDB1A", "#3AA4FF", "#2BE38F", "#9B52FF", "#FF9A1F" }

-- Loose images the window shows (kept in memory while it is open).
function M.images(district, keep)
	keep = keep or {}
	local k = assets.district_bg_key(district, "concert")
	if k then keep[k] = true end
	return scene.images(district, "concert", keep)
end

local function beams(e, parent)
	local s = e.ui
	for _, b in ipairs(BEAMS) do
		local n = s:circle(parent, b.x, 1330, 10, b.color, { soft = true, alpha = 0.34 })
		gui.set_size(n, vmath.vector3(230, 1500, 0))
		gui.set_pivot(n, gui.PIVOT_N)
		gui.set_blend_mode(n, gui.BLEND_ADD)
		gui.set_euler(n, vmath.vector3(0, 0, b.a0))
		if not kit.reduced() then
			gui.animate(n, "euler.z", b.a1, gui.EASING_INOUTSINE, b.period, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
		end
		-- the lamp
		local lamp = s:circle(parent, b.x, 1300, 90, b.color, { soft = true, alpha = 0.9 })
		gui.set_blend_mode(lamp, gui.BLEND_ADD)
	end
end

local function items(e, parent, district, beat)
	local s = e.ui
	local lay = scene.layouts()[district]
	if not lay or not lay.items then return end
	local d = app.meta:district(district)
	for i, t in ipairs(d.tasks) do
		local it = lay.items[t.id]
		if it then
			local x, y = it.x, 1280 - it.y
			local w, h = it.w * it.scale, it.h * it.scale
			local g = s:circle(parent, x, y, math.max(w, h) * 1.4, "#FFE66D", { soft = true, alpha = 0.55 })
			gui.set_blend_mode(g, gui.BLEND_ADD)
			local n = s:image(parent, scene.item_key(district, t.id), x, y, { w = w, h = h })
			if n and not kit.reduced() then
				fx.bob(n, 7, beat, (i % 2) * beat / 2)
				ui.pulse(g, 0.1, beat / 2)
			end
		end
	end
end

local function float_note(e)
	local s = e.ui
	local x = fx.rand(40, 680)
	local c = NOTE_COLORS[math.random(#NOTE_COLORS)]
	local size = fx.rand(44, 70)
	local n = s:image(e.notes_layer, "fx/note", x, fx.rand(120, 300), { w = size, h = size, color = c })
		or s:circle(e.notes_layer, x, fx.rand(120, 300), size * 0.6, c, { soft = true })
	local d = fx.rand(2.2, 3.2)
	gui.animate(n, "position.y", gui.get_position(n).y + fx.rand(520, 800), gui.EASING_OUTSINE, d)
	gui.animate(n, "position.x", x + fx.rand(-60, 60), gui.EASING_INOUTSINE, d / 2, 0, nil, gui.PLAYBACK_LOOP_PINGPONG)
	gui.animate(n, "color.w", 0, gui.EASING_INQUAD, d, 0, function() gui.delete_node(n) end)
end

function M.build(e)
	local s = e.ui
	local st = e.state
	local district = e.params.district or app.focus_district()
	local data = app.district(district) or {}
	local bpm = data.bpm or 100
	e.beat = 60 / bpm
	st.t = st.t or 0

	-- the concert scene over the whole window
	s:sky({ parent = e.back, clouds = false })
	local key = assets.district_bg_key(district, "concert")
	if key then s:backdrop(e.back, key) end
	items(e, e.back, district, e.beat)
	beams(e, e.back)
	e.notes_layer = s:layer(e.back)

	-- title
	local title = s:text(e.content, i18n.t("district.concert", { name = i18n.name(data.name or {}) }), 0, 500, {
		font = "title", size = 66, color = "white", outline = "#FF4D8D", shadow = "#3A2470", max_width = 660,
	})
	e.title = title
	local sub = s:text(e.content, i18n.t("concert.subtitle"), 0, 426, {
		font = "button", size = 32, color = "#FFF3A6", outline = "#3A2470", max_width = 640,
	})
	if e.first and not kit.reduced() then
		kit.pop_in(title, 0.2, 0.5)
		kit.fade_in(sub, 0.6, 0.4)
	end

	-- Bit on the stage
	kit.bit(e, e.content, 0, -330, 240, "dance_a")
	e.bit:dance(bpm)

	-- skip hint
	local hint = s:text(e.content, i18n.t("concert.skip"), 0, -560, {
		font = "button", size = 28, color = "white", outline = "#3A2470", max_width = 600,
	})
	e:target("skip", 0, -560)
	if e.first then
		kit.fade_in(hint, 1.5, 0.5)
		audio.music(district, { all = true })
		kit.sfx("win")
		local x, y = kit.abs(0, 0)
		e.fx:flash(x, y, { size = 1600, dur = 0.6 })
		st.confetti = e.fx:confetti({ rate = 30, burst = 24 })
	end
	st.beat_t = 0
end

function M.update(e, dt)
	local st = e.state
	kit.update_bit(e, dt)
	st.t = (st.t or 0) + dt
	st.beat_t = (st.beat_t or 0) + dt
	if st.beat_t >= e.beat then
		st.beat_t = st.beat_t - e.beat
		if not kit.reduced() then
			float_note(e)
			if e.title and st.t > 1.2 then e.fx:pop(e.title, 0.05, e.beat * 0.8) end
		end
	end
	if st.t >= (e.params.duration or M.DURATION) and not e.closing then
		e:close("done")
	end
end

-- Any tap skips (after a moment, so the tap that ended the task does not).
function M.on_input(e, action_id, action)
	if action_id == kit.TOUCH and action.released and (e.state.t or 0) > 0.6 and not e.closing then
		e:close("skip")
	end
	return true
end

function M.closed(e)
	if e.state.confetti then e.state.confetti.stop() end
end

return M
