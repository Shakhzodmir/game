-- Replay: after the last level the player can play any beaten level again. A page of 20 level buttons
-- (levels 1..n, the last page first), two arrows between pages. A replay is a practice run: no meta
-- attempt, so no coins, stars, chests or lives are paid or lost (client/level_end.lua, standalone result).
-- QA targets: replay_<n> (a level), page_prev, page_next. QA status (app.ui.replay): {page, pages, first, last}.

local app = require("client.app")
local i18n = require("client.i18n")
local kit = require("gui.kit")

local M = {}

local W, H = 640, 1060
local COLS, ROWS = 4, 5
local PAGE = COLS * ROWS
local CELL_W, CELL_H, GAP_X, GAP_Y = 124, 92, 14, 14

-- Levels shown on page p of n beaten levels: first, last.
function M.page_range(p, n)
	local first = (p - 1) * PAGE + 1
	return first, math.min(n, first + PAGE - 1)
end

function M.page_count(n)
	return math.max(1, math.ceil(n / PAGE))
end

-- Opens the level as a practice run.
function M.play(n)
	app.close_popup()
	app.show_screen("level", { level = n, from = "replay" })
end

function M.build(e)
	local s = e.ui
	local st = e.state
	local n = app.beaten_count()
	local pages = M.page_count(n)
	st.page = math.max(1, math.min(st.page or pages, pages))
	local body, hh = kit.panel(e, W, H, { title = { key = "replay.title" }, fit = true })

	s:text(body, i18n.t("replay.text"), 0, hh - 210, {
		font = "body", size = 28, color = "text", width = W - 90, height = 150,
	})

	local first, last = M.page_range(st.page, n)
	local gx0 = -((COLS - 1) * (CELL_W + GAP_X)) / 2
	local gy0 = hh - 330
	for i = first, last do
		local k = i - first
		local x = gx0 + (k % COLS) * (CELL_W + GAP_X)
		local y = gy0 - math.floor(k / COLS) * (CELL_H + GAP_Y)
		s:button({ parent = body, x = x, y = y, w = CELL_W, h = CELL_H, style = i == n and "gold" or "blue",
			text = tostring(i), text_size = 38, on_click = function() M.play(i) end })
		e:target("replay_" .. i, x, y)
	end

	local py = -hh + 130
	local function arrow(x, label, target, delta)
		local b = s:button({ parent = body, x = x, y = py, w = 110, h = 90, style = "white", text = label, text_size = 40,
			sfx = "tap", enabled = pages > 1, on_click = function()
				st.page = (st.page - 1 + delta) % pages + 1
				e:rebuild()
			end })
		e:target(target, x, py)
		return b
	end
	arrow(-190, "<", "page_prev", -1)
	s:text(body, i18n.t("replay.page", { a = first, b = last }), 0, py, { font = "button", size = 32, color = "text_soft", max_width = 200 })
	arrow(190, ">", "page_next", 1)

	app.ui.replay = { page = st.page, pages = pages, first = first, last = last }
end

function M.closed(e)
	app.ui.replay = nil
end

return M
