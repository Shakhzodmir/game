-- Pause window of the level screen: resume, settings, leave the level. It says honestly
-- what leaving costs (client/level_windows.lua pause): nothing before the first move (and
-- the boosters come back), after it a loss with the life and the hit streak named. Leaving
-- with something at stake asks once more.
-- params = {view = level_windows.pause(...), level_id}
-- Result: "resume" (also the close button and the back key) | "leave".

local i18n = require("client.i18n")
local kit = require("gui.kit")
local lkit = require("gui.level_kit")

local M = {}

M.dim_alpha = 0.6

local W = 600

local function leave(e, v)
	if v.at_stake then
		e:open("confirm", {
			title = { key = "pause.leave_title" },
			text = { lines = v.lines },
			icon = "ui/icons/home",
			confirm = { text = { key = "pause.quit_confirm" }, style = "pink" },
			cancel = { text = { key = "pause.stay" } },
			on_confirm = function() e:close("leave") end,
		})
	else
		kit.sfx("button")
		e:close("leave")
	end
end

function M.build(e)
	local s = e.ui
	local v = e.params.view or { lines = {}, at_stake = false }
	local lines = {}
	for i, l in ipairs(v.lines or {}) do lines[i] = l end
	local note_h = 56
	local box_h = 28 + #lines * (note_h + 8)
	local H = 560 + box_h
	local body, hh = kit.panel(e, W, H, { title = { key = "pause.title" } })
	kit.bit(e, body, -W / 2 + 62, hh + 38, 124, "idle")

	if e.params.level_id then
		s:text(body, i18n.t("pause.level", { n = e.params.level_id }), 0, hh - 92, {
			font = "button", size = 32, color = "text_soft", max_width = W - 120,
		})
	end

	local y = hh - 190
	local resume = s:button({ parent = body, x = 0, y = y, w = 440, h = 116, style = "green", icon = "ui/icons/play",
		icon_size = 64, text = i18n.t("pause.resume"), text_size = 44, on_click = function() e:close("resume") end })
	e:target("resume", 0, y)
	lkit.pulse(resume.node, 0.025, 1.0)

	y = y - 136
	s:button({ parent = body, x = 0, y = y, w = 440, h = 100, style = "blue", icon = "ui/icons/settings", icon_size = 56,
		text = i18n.t("pause.settings"), text_size = 36, on_click = function() e:open("settings") end })
	e:target("settings", 0, y)

	-- what leaving costs, then the button
	y = y - 62 - box_h / 2
	local specs = {}
	for i, l in ipairs(lines) do
		local loss = v.at_stake or (v.leave == "loss")
		local key = l.key or ""
		local icon = (key == "continue.life_warning") and "ui/icons/heart"
			or (key == "continue.streak_warning" and "ui/icons/streak")
			or (loss and "ui/icons/retry" or "ui/icons/check")
		specs[i] = {
			text = l, icon = icon, size = 24, h = note_h, color = v.at_stake and "pink" or "text_soft",
			fill = v.at_stake and "#FFE9F1" or "#EAF9EF",
		}
	end
	lkit.notes(e, body, 0, y, W - 80, specs)

	y = y - box_h / 2 - 66
	s:button({ parent = body, x = 0, y = y, w = 440, h = 96, style = "pink", icon = "ui/icons/home", icon_size = 52,
		text = i18n.t("pause.quit"), text_size = 34, on_click = function() leave(e, v) end })
	e:target("leave", 0, y)
end

function M.update(e, dt)
	kit.update_bit(e, dt)
end

return M
