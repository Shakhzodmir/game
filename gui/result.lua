-- Results window of the level screen, after the final concert: the stars earned (the meta's number
-- for the difficulty), the coins (the meta's: the base and 5 for every move left), the score, the hit
-- streak with the free boosters of the next start, the progress to the next level chest (or the
-- chest that just came: "Open" shows the chest window and, once the player takes it, the meta pays it and
-- its unlimited lives start; left unopened it is offered again by the next results window and the town),
-- new boosters, boosters the core could not place and returned. "Next level" opens the start window of the next level (Play there starts it), "To town"
-- goes back. Stars, coins and Bit are animated once; a rebuild (language) shows the final state.
-- params = {view = level_windows.result(...), refund = {[id] = count} | nil, standalone}
-- Result: "town" | {action = "next", level} (a debug level: no start window).

local app = require("client.app")
local i18n = require("client.i18n")
local views = require("client.views")
local lw = require("client.level_windows")
local config = require("meta.config")
local fx = require("client.fx")
local kit = require("gui.kit")
local lkit = require("gui.level_kit")

local M = {}

M.dim_alpha = 0.72
M.no_back = true

local W = 640
local GAP = 14

-- names of boosters as "Riff, Subwoofer"
local function names(ids)
	local out = {}
	for i, id in ipairs(ids) do out[i] = i18n.t("booster." .. id) end
	return table.concat(out, ", ")
end

local function refund_ids(refund)
	local out = {}
	for _, def in ipairs(config.boosters) do -- the catalogue's order
		if refund and refund[def.id] then out[#out + 1] = def.id end
	end
	return out
end

-- The chest to offer now: live from the meta (a chest taken in this window is gone from it and the next one
-- waiting takes its place); the view's own chest when the window was handed one without a meta behind it.
local function offered_chest(v)
	if v.standalone then return nil end
	local meta = app.meta
	if meta and meta.pending_chests then return lw.chest(meta) end
	return v.chest
end

-- The contents of a chest in a row to the right of the chest icon, at height y of `inner`: the gaps shrink
-- when there are four.
local function chest_row(e, inner, chest, sw, y)
	local s = e.ui
	local items = views.chest_items(chest)
	local rooms, used = {}, 0
	for i, it in ipairs(items) do
		rooms[i] = it.kind == "infinite" and 74 or (it.kind == "coins" and 66 or 36)
		used = used + 38 + rooms[i]
	end
	local left, right = -sw / 2 + 150, sw / 2 - 18
	local gap = math.min(14, math.max(4, (right - left - used) / math.max(1, #items - 1)))
	local row = used + gap * (#items - 1)
	local ix = math.max(left, math.min(40 - row / 2, right - row))
	for i, it in ipairs(items) do
		kit.icon(e, inner, it.image, ix + 17, y, 38, "gold")
		local label = it.kind == "infinite" and i18n.t("time.min", { m = it.amount }) or ("×" .. i18n.number(it.amount))
		s:text(inner, label, ix + 38, y, { font = "number", size = 24, color = "text", pivot = gui.PIVOT_W, max_width = rooms[i] })
		ix = ix + 38 + rooms[i] + gap
	end
end

-- "Open": the chest window shows the chest; the player taking it ("Collect") is the moment the meta pays it,
-- so its unlimited lives run from there. A chest window closed any other way (the screen goes away) pays
-- nothing: the chest stays in the meta.
local function open_chest(e, chest)
	e:open("chest", { kind = "level", level_id = chest.level_id, chest = chest, on_close = function(result)
		if type(result) ~= "table" or result.action ~= "collect" then return end
		if app.claim_level_chest(chest.level_id) then
			e.state.claimed = chest
			e.state.pop_claimed = true
		end
		e:rebuild()
	end })
end

-- the blocks, top to bottom: {h, draw = function(y)}
local function blocks(e, body, v, animate, alive)
	local s = e.ui
	local list = {}
	local function add(h, draw) list[#list + 1] = { h = h, draw = draw } end

	-- stars: only the ones earned (the meta's number for the difficulty, not a rating of the play: empty
	-- slots made players think more stars could be won by playing better)
	local n_stars = math.max(1, math.min(3, v.stars))
	add(150, function(y)
		local stars = lkit.stars(e, body, 0, y - 4, n_stars, n_stars, 100)
		if animate and not kit.reduced() then
			for i = 1, n_stars do
				local node = stars[i]
				local base = gui.get_scale(node)
				gui.set_scale(node, base * 0.01)
				local sx = (i - (n_stars + 1) / 2) * 100 * 1.08
				e.fx:after(0.35 + i * 0.4, function()
					if not alive() then return end
					gui.animate(node, "scale", base, gui.EASING_OUTBACK, 0.45)
					kit.sfx("star", { speed = 1 + 0.12 * i })
					local ax, ay = kit.abs(sx, y - 4)
					e.fx:burst(ax, ay, { count = 10, radius = 110, size = 32 })
					e.fx:ring(ax, ay, { size = 90, scale = 2.4, dur = 0.45 })
				end)
			end
		end
	end)
	if not v.standalone and n_stars < 3 then
		add(104 + GAP, function(y)
			lkit.note(e, body, 0, y - GAP / 2, W - 80, {
				text = { key = "win.stars_note" }, icon = "ui/icons/star", size = 22, h = 104, color = "text_soft", wrap = true,
			})
		end)
	end

	-- coins, moves left, score
	add(172, function(y)
		if v.standalone then
			s:text(body, i18n.t("win.debug"), 0, y, { font = "button", size = 30, color = "text_soft", max_width = W - 80 })
			return
		end
		kit.icon(e, body, "ui/icons/coin", -150, y + 26, 76, "coin")
		local txt, info = s:text(body, "+" .. i18n.number(animate and 0 or v.coins), -100, y + 28, {
			font = "number", size = 70, color = "gold", outline = "#B35F00", shadow = "#B35F00", pivot = gui.PIVOT_W, max_width = 320,
		})
		if animate then
			e.fx:count(0, v.coins, 0.9, function(val)
				if not alive() then return end
				s:set_text(txt, "+" .. i18n.number(val), info)
				e.fx:sfx("coin", nil, 0.09)
			end, 1.0 + 0.4 * n_stars)
		end
		s:text(body, i18n.t("win.moves_left", { n = v.moves_left }), 0, y - 40, {
			font = "button", size = 28, color = "text", max_width = W - 100,
		})
		s:text(body, i18n.t("win.score", { n = i18n.number(v.score) }), 0, y - 76, {
			font = "small", size = 24, color = "text_soft", max_width = W - 100,
		})
	end)

	-- the hit streak
	if v.streak.active and v.streak.count > 0 then
		add(104 + GAP, function(y)
			local sw = W - 80
			local strip = s:round(body, 0, y - GAP / 2, sw, 104, "#F4EEFF", { radius = 32 })
			kit.icon(e, strip, "ui/icons/streak", -sw / 2 + 56, 2, 72, "pink")
			s:text(strip, i18n.t("win.streak", { n = v.streak.count }), -sw / 2 + 108, 20, {
				font = "button", size = 28, color = "text", pivot = gui.PIVOT_W, max_width = 260,
			})
			-- the free boosters of the next start: a label and the pictures right after it
			local free = v.streak.free or {}
			if #free > 0 then
				local lx = -sw / 2 + 108
				local label = s:text(strip, i18n.t("win.free_next"), lx, -20, {
					font = "small", size = 21, color = "text_soft", pivot = gui.PIVOT_W, max_width = math.min(200, 280 - 38 * #free),
				})
				local x = lx + lkit.width(label, 150) + 10
				for i, id in ipairs(free) do kit.booster_icon(e, strip, id, x + 17 + (i - 1) * 38, -20, 34) end
			end
			local notes = kit.notes(e, strip, 200, 2, v.streak.notes, 46, 52)
			if animate and not kit.reduced() then
				local lit = math.min(#notes, v.streak.count)
				if notes[lit] then
					local base = gui.get_scale(notes[lit])
					gui.set_scale(notes[lit], base * 0.01)
					e.fx:after(1.3, function()
						if alive() then gui.animate(notes[lit], "scale", base, gui.EASING_OUTBACK, 0.4) end
					end)
				end
			end
		end)
	end

	-- the level chest: waiting to be opened here, or just taken
	local chest = offered_chest(v)
	local taken = (not chest) and e.state.claimed or nil
	if chest then
		add(196 + GAP, function(y)
			local sw = W - 80
			local strip = s:round(body, 0, y - GAP / 2, sw, 196, "#FFD84D", { radius = 34 })
			local inner = s:round(strip, 0, 0, sw - 8, 188, "#FFF6D6", { radius = 30 })
			local icon = kit.icon(e, inner, "ui/icons/chest_closed", -sw / 2 + 80, 22, 120, "gold")
			if not kit.reduced() then kit.wiggle(icon, 0.05, 0.9) end
			-- an older chest left unopened says which level it is from
			local title = (chest.level_id == v.level_id) and i18n.t("win.chest") or i18n.t("reward.chest_level", { n = chest.level_id })
			s:text(inner, title, 40, 62, { font = "title", size = 44, color = "gold", outline = "white", max_width = 360 })
			chest_row(e, inner, chest, sw, 8)
			s:button({ parent = inner, x = 40, y = -56, w = 260, h = 64, style = "green", text = i18n.t("win.chest_open"), text_size = 30,
				on_click = function() open_chest(e, chest) end })
			e:target("chest", 40, y - GAP / 2 - 56)
		end)
	elseif taken then
		add(150 + GAP, function(y)
			local sw = W - 80
			local strip = s:round(body, 0, y - GAP / 2, sw, 150, "green", { radius = 34 })
			local inner = s:round(strip, 0, 0, sw - 8, 142, "#E8FBEF", { radius = 30 })
			kit.icon(e, inner, "ui/icons/chest_open", -sw / 2 + 80, 4, 110, "gold")
			s:text(inner, i18n.t("win.chest_got"), 40, 42, { font = "title", size = 40, color = "green", outline = "white", max_width = 360 })
			chest_row(e, inner, taken, sw, -6)
			if (taken.infinite_minutes or 0) > 0 then
				s:text(inner, i18n.t("win.chest_lives_on"), 40, -50, { font = "small", size = 22, color = "text_soft", max_width = 360 })
			end
			if e.state.pop_claimed then
				e.state.pop_claimed = nil
				kit.pop_in(strip, 0, 0.4)
				kit.sfx("unlock")
			end
		end)
	elseif not v.standalone and v.progress and not v.progress.opened then
		add(96 + GAP, function(y)
			local sw = W - 80
			local strip = s:round(body, 0, y - GAP / 2, sw, 96, "#F4EEFF", { radius = 30 })
			kit.icon(e, strip, "ui/icons/chest_closed", -sw / 2 + 52, 2, 72, "gold")
			s:text(strip, i18n.t("win.chest_in", { n = v.progress.left }), 40, 22, {
				font = "button", size = 24, color = "text_soft", max_width = sw - 160,
			})
			local total = v.progress.total
			local seg, step = 30, 36
			local x0 = 40 - (total - 1) * step / 2
			for i = 1, total do
				local on = i <= v.progress.done
				local n = s:round(strip, x0 + (i - 1) * step, -16, seg, 20, on and "#FFB020" or "#DDD2F3", { radius = 10 })
				if on and i == v.progress.done and animate and not kit.reduced() then
					local base = gui.get_scale(n)
					gui.set_scale(n, base * 0.01)
					e.fx:after(1.5, function()
						if alive() then gui.animate(n, "scale", base, gui.EASING_OUTBACK, 0.35) end
					end)
				end
			end
		end)
	end

	-- new boosters
	for _, id in ipairs(v.unlocked or {}) do
		add(76 + GAP, function(y)
			local sw = W - 80
			local strip = s:round(body, 0, y - GAP / 2, sw, 76, "#FFF6D6", { radius = 30 })
			kit.booster_icon(e, strip, id, -sw / 2 + 48, 0, 56)
			s:text(strip, i18n.t("win.unlocked", { name = i18n.t("booster." .. id) }), -sw / 2 + 92, 1, {
				font = "button", size = 26, color = "text", pivot = gui.PIVOT_W, max_width = sw - 220,
			})
			local g = views.gift(id, config)
			if g.count > 0 then
				local pill = s:round(strip, sw / 2 - 66, 0, 96, 44, "purple", { radius = 22 })
				s:text(pill, "×" .. g.count, 0, 1, { font = "number", size = 28, color = "white", max_width = 80 })
			end
		end)
	end

	-- boosters the core could not place come back
	local back = refund_ids(e.params.refund)
	if #back > 0 then
		add(60 + GAP, function(y)
			lkit.note(e, body, 0, y - GAP / 2, W - 80, {
				text = { key = "win.refund", vars = { names = names(back) } }, icon = views.booster_icon(back[1]),
				size = 22, h = 60, color = "text",
			})
		end)
	end
	return list
end

local function next_level(e, v)
	if e.params.standalone then
		e:close({ action = "next", level = v.next_level })
		return
	end
	e:open("start", { level = v.next_level })
end

function M.build(e)
	local s = e.ui
	local v = e.params.view
	local st = e.state
	local animate = e.first and not st.played
	st.played = true
	local alive = lkit.token(e)

	local list = blocks(e, nil, v, false, alive) -- heights only: nothing is drawn yet
	local h_blocks = 0
	for _, b in ipairs(list) do h_blocks = h_blocks + b.h end
	local has_next = v.next_level ~= nil
	local h_buttons = has_next and 290 or 250
	local H = 70 + h_blocks + h_buttons
	local body, hh = kit.panel(e, W, H, { title = { key = "win.title" }, close = false })

	local list2 = blocks(e, body, v, animate, alive)
	local y = hh - 70
	for _, b in ipairs(list2) do
		b.draw(y - b.h / 2)
		y = y - b.h
	end

	kit.bit(e, body, -W / 2 + 70, hh + 34, 132, "happy")
	if animate and e.bit then e.bit:cheer(4, 4) end

	-- the buttons
	if has_next then
		local ny = -hh + 214
		local nb = s:button({ parent = body, x = 0, y = ny, w = 460, h = 124, style = "green", icon = "ui/icons/play", icon_size = 64,
			text = i18n.t("win.next"), text_size = 44, on_click = function() next_level(e, v) end })
		e:target("next", 0, ny)
		lkit.pulse(nb.node, 0.03, 0.9)
		local ty = -hh + 80
		s:button({ parent = body, x = 0, y = ty, w = 340, h = 92, style = "blue", icon = "ui/icons/home", icon_size = 50,
			text = i18n.t("win.town"), text_size = 34, on_click = function() e:close("town") end })
		e:target("town", 0, ty)
	else
		local ty = -hh + 100
		s:button({ parent = body, x = 0, y = ty, w = 440, h = 112, style = "green", icon = "ui/icons/home", icon_size = 58,
			text = i18n.t("win.town"), text_size = 42, on_click = function() e:close("town") end })
		e:target("town", 0, ty)
		s:text(body, i18n.t("win.all_done"), 0, ty + 86, { font = "button", size = 26, color = "text_soft", max_width = W - 80 })
	end

	if animate then
		kit.sfx("win")
		if not kit.reduced() then e.fx:confetti({ rate = 26, burst = 18, duration = 3.2 }) end
		fx.buzz(40)
	end
end

function M.update(e, dt)
	kit.update_bit(e, dt)
end

return M
