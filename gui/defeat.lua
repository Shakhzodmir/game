-- Defeat window of the level screen: the level was not beaten. Bit is sad. It says what was lost
-- (the life, the hit streak: the meta's numbers), how close it was and what was still to do, how
-- many lives are left (or when the next one comes), and offers a retry in two taps (the start
-- window of the same level, then Play) or the town.
-- params = {view = level_windows.defeat(...), level_id, standalone}
-- Result: "town" (the glue takes the loss to the town and leaves).

local app = require("client.app")
local i18n = require("client.i18n")
local kit = require("gui.kit")
local lkit = require("gui.level_kit")

local M = {}

M.dim_alpha = 0.7
M.no_back = true

local W = 620

local function retry(e, v)
	if e.params.standalone then
		-- a debug level: no meta, no start window
		e:close({ action = "retry" })
		return
	end
	e:open("start", { level = e.params.level_id })
end

function M.build(e)
	local s = e.ui
	local v = e.params.view
	local tiles = math.min(3, #v.goals)
	local lines = {}
	if v.life_lost then lines[#lines + 1] = { text = { key = "lose.life_lost" }, icon = "ui/icons/heart", color = "pink", fill = "#FFE9F1" } end
	if v.streak_lost > 0 then
		lines[#lines + 1] = { text = { key = "lose.streak_lost" }, icon = "ui/icons/streak", color = "pink", fill = "#FFE9F1" }
	end
	-- lives: how many are left, or when the next one comes
	local lives_text
	if v.life_lost or v.no_lives then
		if v.lives.infinite then
			lives_text = nil
		elseif v.no_lives then
			lives_text = { key = "lose.no_lives", vars = { time = i18n.duration(v.lives.next_in) } }
		else
			lives_text = { key = "lose.lives", vars = { n = v.lives.count, max = v.lives.max } }
		end
	end
	if lives_text then
		lines[#lines + 1] = { text = lives_text, icon = "ui/icons/heart", color = v.no_lives and "pink" or "text_soft", fill = "#F4EEFF" }
	end

	local h_goals = tiles > 0 and 214 or 0
	local h_lines = #lines > 0 and (#lines * 64 + 16) or 0
	local H = 600 + h_goals + h_lines
	local body, hh = kit.panel(e, W, H, { title = { key = "lose.title" }, close = false })

	-- Bit, sad, with a word for the player
	kit.bit(e, body, 0, hh - 150, 190, "sad")
	if e.bit then e.bit:mood_for(1e9, "sad") end
	s:text(body, i18n.t(v.close and "lose.close" or "lose.cheer"), 0, hh - 292, {
		font = "title", size = 46, color = v.close and "gold" or "purple", outline = "white", shadow = "shadow", max_width = W - 80,
	})

	local y = hh - 340
	if tiles > 0 then
		kit.section(e, body, i18n.t("lose.left"), 0, y - 16, W - 80)
		local gy = y - 120
		for i = 1, tiles do
			local g = v.goals[i]
			local gx = (i - (tiles + 1) / 2) * 150
			kit.goal(e, body, { image = g.image, count = g.left, color = g.color }, gx, gy, 124)
		end
		y = y - h_goals
	end
	if #lines > 0 then
		lkit.notes(e, body, 0, y - (#lines * 64 - 8) / 2 - 8, W - 100, lines)
		y = y - h_lines
	end

	-- retry and the town
	local ry = -hh + 214
	local rb = s:button({ parent = body, x = 0, y = ry, w = 440, h = 124, style = "green", icon = "ui/icons/retry", icon_size = 64,
		text = i18n.t("lose.retry"), text_size = 46, on_click = function() retry(e, v) end })
	e:target("retry", 0, ry)
	lkit.pulse(rb.node, 0.03, 0.9)
	local ty = -hh + 78
	s:button({ parent = body, x = 0, y = ty, w = 360, h = 96, style = "blue", icon = "ui/icons/home", icon_size = 52,
		text = i18n.t("lose.town"), text_size = 36, on_click = function() e:close("town") end })
	e:target("town", 0, ty)
end

function M.update(e, dt)
	kit.update_bit(e, dt)
end

return M
