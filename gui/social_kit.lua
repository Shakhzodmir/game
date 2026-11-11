-- Pieces shared by the chart and band windows (WP-11): avatars, district badges, the game name, a plain list
-- with scrolling by whole rows (drag, wheel, arrows), a pinned row.
-- Coordinates are window-centre coordinates, like gui/kit.lua.

local i18n = require("client.i18n")
local rules = require("meta.social")
local social = require("client.social")
local kit = require("gui.kit")

local M = {}

M.DISTRICT_COLORS = { "#FF8FB8", "#4CC9F0", "#FFB020", "#7BDB6B", "#B07CFF" }
M.MEDALS = { "#FFC83D", "#C9D2E3", "#E39A5B" }

-- A round avatar of the fixed set: a colour disc with an icon.
function M.avatar(e, parent, x, y, size, index)
	local s = e.ui
	local a = rules.AVATARS[index] or rules.AVATARS[1]
	local disc = s:circle(parent, x, y, size, a.color)
	kit.icon(e, disc, a.icon, 0, 0, size * 0.62, "white")
	return disc
end

-- The district badge: a small coloured disc with the number of the district (the colours repeat past the fifth).
function M.district(e, parent, x, y, n)
	local s = e.ui
	local d = s:circle(parent, x, y, 40, M.DISTRICT_COLORS[((n or 1) - 1) % #M.DISTRICT_COLORS + 1])
	s:text(d, tostring(n), 0, 2, { font = "number", size = 26, color = "white", outline = "#5220A6", max_width = 30 })
	return d
end

-- The rank mark: 1-3 on a medal, the rest as a plain number.
function M.rank(e, parent, x, y, rank)
	local s = e.ui
	if rank and rank <= 3 then
		local m = s:circle(parent, x, y, 58, M.MEDALS[rank])
		local t, info = s:text(m, tostring(rank), 0, 2, { font = "number", size = 38, color = "white", outline = "#7A5A00", max_width = 44 })
		return t, info
	end
	return s:text(parent, rank and tostring(rank) or "-", x, y + 2, { font = "number", size = 34, color = "text_soft", max_width = 70 })
end

-- One person's row: [rank] [avatar] name [district] stars. `row` = {rank, name, avatar, district, stars, me};
-- opts = {w, h, rank = false (no rank, e.g. a band list), extra = text under the name}.
-- Returns the row node and the rank text node/info (for the count-up animation).
function M.row(e, parent, x, y, row, opts)
	opts = opts or {}
	local s = e.ui
	local w, h = opts.w or 520, opts.h or 84
	local bg = s:round(parent, x, y, w, h - 8, row.me and "#E9DBFF" or "#F6F2FF", { radius = 26 })
	local left = -w / 2 + 44
	local rank_node, rank_info
	if opts.rank ~= false then
		rank_node, rank_info = M.rank(e, bg, left, 0, row.rank)
		left = left + 74
	end
	M.avatar(e, bg, left, 0, 58, row.avatar)
	left = left + 46
	local name_w = w - (left + w / 2) - 190
	local name_y = opts.extra and 14 or 0
	-- a long name wraps onto two lines (chart rows) or shrinks (rows with a line of text under the name)
	kit.label(e, bg, social.name_text(row.name), left, name_y, {
		font = "button", size = opts.extra and 26 or 21, color = row.me and "purple" or "text", pivot = gui.PIVOT_W,
		max_width = name_w, lines = opts.extra and 1 or 2,
	})
	if opts.extra then
		s:text(bg, opts.extra, left, -18, { font = "body", size = 20, color = "text_soft", pivot = gui.PIVOT_W, max_width = name_w })
	end
	if opts.help_fn then
		local hb = s:button({ parent = bg, x = w / 2 - 150, y = 0, w = 84, h = 62, style = "pink", icon = "ui/icons/heart", icon_size = 40,
			text = not require("client.assets").has_image("ui/icons/heart") and "+" or nil, sfx = "tap", on_click = opts.help_fn })
		if opts.help_target then e:target(opts.help_target, x + w / 2 - 150, y) end
	elseif not opts.no_district then
		M.district(e, bg, w / 2 - 150, 0, row.district or 1)
	end
	if not s:image(bg, "ui/icons/star", w / 2 - 98, 2, { w = 38, h = 38 }) then s:circle(bg, w / 2 - 98, 2, 34, "yellow") end
	s:text(bg, tostring(row.stars or 0), w / 2 - 70, 2, { font = "number", size = 30, color = "text", pivot = gui.PIVOT_W, max_width = 60 })
	return bg, rank_node, rank_info
end

-- A list state for scrolling by whole rows: {first (1-based), visible, count}.
function M.scroll_new(visible)
	return { first = 1, visible = visible, count = 0, acc = 0 }
end

function M.scroll_set(sc, count)
	sc.count = count
	sc.first = math.max(1, math.min(sc.first, math.max(1, count - sc.visible + 1)))
end

-- Moves by `d` rows; returns true when the first row changed.
function M.scroll_by(sc, d)
	local before = sc.first
	sc.first = math.max(1, math.min(sc.first + d, math.max(1, sc.count - sc.visible + 1)))
	return sc.first ~= before
end

-- A finger drag over the list: every `row_h` px of vertical movement is a row. Returns true when the list moved.
function M.scroll_drag(sc, dy, row_h)
	sc.acc = sc.acc + dy
	local rows = 0
	while sc.acc >= row_h do rows = rows - 1; sc.acc = sc.acc - row_h end   -- finger up: later rows
	while sc.acc <= -row_h do rows = rows + 1; sc.acc = sc.acc + row_h end
	if rows == 0 then return false end
	return M.scroll_by(sc, -rows)
end

-- A small round arrow button: dir = 1 (up) / -1 (down).
function M.arrow(e, parent, x, y, dir, on_click, target)
	local s = e.ui
	local has = require("client.assets").has_image("ui/icons/arrow")
	local b = s:button({ parent = parent, x = x, y = y, w = 80, h = 80, style = "blue", icon = "ui/icons/arrow", icon_size = 46,
		text = not has and (dir > 0 and "^" or "v") or nil, sfx = "tap", on_click = on_click })
	if b.icon then gui.set_euler(b.icon, vmath.vector3(0, 0, dir > 0 and 90 or -90)) end
	if target then e:target(target, x, y) end
	return b
end

-- The profile editor: a suggested game name (no typing: lists of words), a row of avatars, "Done".
-- st = {k (suggestion number), avatar}; on_save(name, avatar). Draws from the top of a body of half height hh.
function M.profile_editor(e, body, hh, st, on_save)
	local s = e.ui
	st.k = st.k or 0
	st.avatar = st.avatar or 1
	local name = rules.suggest_name(st.k)
	M.note(e, body, i18n.t("social.profile_text"), 0, hh - 190, 540, 28, "text", 150)
	local pill = s:round(body, 0, hh - 330, 540, 110, "#F6F2FF", { radius = 40 })
	s:text(pill, social.name_text(name), 0, 2, { font = "button", size = 42, color = "purple", max_width = 480 })
	s:button({ parent = body, x = 0, y = hh - 440, w = 400, h = 88, style = "blue", text = i18n.t("social.other_name"),
		text_size = 30, sfx = "tap", on_click = function() st.k = st.k + 1; e:rebuild() end })
	e:target("reroll", 0, hh - 440)
	kit.caption(e, body, i18n.t("social.pick_avatar"), 0, hh - 520, { size = 28 })
	for i = 1, #rules.AVATARS do
		local col, row = (i - 1) % 6, math.floor((i - 1) / 6)
		local x, y = -255 + col * 102, hh - 600 - row * 104
		if i == st.avatar then s:circle(body, x, y, 94, "#FFD84D") end
		M.avatar(e, body, x, y, 76, i)
		local hit = s:button({ parent = body, x = x, y = y, w = 96, h = 96, style = "white", sfx = "tap",
			on_click = function() st.avatar = i; e:rebuild() end })
		gui.set_color(hit.node, vmath.vector4(1, 1, 1, 0))
		e:target("avatar_" .. i, x, y)
	end
	kit.caption(e, body, i18n.t("social.profile_privacy"), 0, -hh + 250, { size = 22, max_width = 540 })
	s:button({ parent = body, x = 0, y = -hh + 140, w = 420, h = 100, style = "green", text = i18n.t("common.ok"),
		text_size = 36, on_click = function() on_save(name, st.avatar) end })
	e:target("save", 0, -hh + 140)
end

-- Text block (wrapped) in the window's usual body style.
function M.note(e, parent, text, x, y, w, size, color, h)
	return e.ui:text(parent, text, x, y, { font = "body", size = size or 28, color = color or "text", width = w, height = h or 160 })
end

return M
