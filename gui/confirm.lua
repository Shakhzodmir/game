-- A yes / no question on top of another window (reset progress, ...).
-- params = {title, text (strings or {key, vars}), confirm = {text, style},
--           cancel = {text}, on_confirm = fn()}
-- Result: "confirm" or "cancel" / "close".

local i18n = require("client.i18n")
local kit = require("gui.kit")

local M = {}

local W, H = 580, 560

function M.build(e)
	local s = e.ui
	local p = e.params
	local body, hh = kit.panel(e, W, H, { title = p.title or { key = "common.ok" } })
	kit.icon(e, body, p.icon or "ui/icons/retry", 0, hh - 120, 96, "pink")
	s:text(body, i18n.tr(p.text or ""), 0, 20, {
		font = "body", size = 30, color = "text", width = W - 90, height = 220,
	})
	local cancel = p.cancel or {}
	s:button({ parent = body, x = -130, y = -hh + 90, w = 230, h = 100, style = "blue",
		text = i18n.tr(cancel.text or { key = "common.cancel" }), text_size = 32,
		on_click = function() e:close("cancel") end })
	e:target("cancel", -130, -hh + 90)
	local c = p.confirm or {}
	s:button({ parent = body, x = 130, y = -hh + 90, w = 230, h = 100, style = c.style or "green",
		text = i18n.tr(c.text or { key = "common.ok" }), text_size = 32,
		on_click = function()
			e:close("confirm")
			if p.on_confirm then p.on_confirm() end
		end })
	e:target("confirm", 130, -hh + 90)
end

return M
