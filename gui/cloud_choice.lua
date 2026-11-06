-- The sync question (client/cloud.lua decisions): this device and the account hold different saves. Shows both
-- with their levels, coins and stars; the one not kept stays as a backup (the "previous" slot, the cloud copy).
-- "Not now" keeps playing with the save on the device and pauses the upload until the player syncs again.

local app = require("client.app")
local i18n = require("client.i18n")
local cloud = require("client.cloud")
local account = require("client.account")
local kit = require("gui.kit")

local M = {}

local W = 620
local BTN_H = 92

local function card(e, body, y, label, sum, more)
	local s = e.ui
	s:round(body, 0, y, W - 70, 150, "#F4EEFF", { radius = 24 })
	s:text(body, i18n.t(label), 0, y + 46, { font = "button", size = 26, color = "purple", max_width = W - 120 })
	s:text(body, i18n.tr(account.summary_spec(sum)), 0, y + 4, { font = "body", size = 26, color = "text", max_width = W - 120 })
	if more then
		s:text(body, i18n.t("cloud.more_progress"), 0, y - 42, { font = "small", size = 22, color = "green", max_width = W - 120 })
	end
end

local function pick(e, d, id)
	local ok, why = cloud.resolve(id)
	if not ok then
		app.toast_key(why == "write" and "cloud.err_write" or "auth.err.error", nil, { color = "pink" })
		return
	end
	if id == "download" or id == "fresh" then
		app.toast_key("cloud.loaded", nil, { color = "gold" })
		e:close(id)
		app.show_screen("splash", { from = "import" })
	elseif id == "upload" then
		app.toast_key("cloud.uploading", nil, { color = "gold" })
		e:close(id)
	else
		e:close(id)
	end
end

function M.build(e)
	local s = e.ui
	local d = cloud.decision()
	if not d then
		e:later(0, function() e:close("gone") end)
		return
	end
	local v = account.decision_view(d)
	local cards = (d.local_sum and 1 or 0) + (d.cloud_sum and 1 or 0)
	if d.kind == "foreign" then cards = d.cloud_sum and 1 or 0 end
	local text_h = 250
	local H = 230 + text_h + cards * 170 + #v.buttons * (BTN_H + 16)
	local body, hh = kit.panel(e, W, H, { title = v.title, fit = true })
	local y = hh - 130
	s:text(body, i18n.tr(v.text), 0, y - text_h / 2 + 20, { font = "body", size = 26, color = "text", width = W - 90, height = text_h })
	y = y - text_h
	if d.kind ~= "foreign" and d.local_sum then
		card(e, body, y - 70, "cloud.this_device", d.local_sum, d.kind == "choose" and d.recommend == "local")
		y = y - 170
	end
	if d.cloud_sum then
		card(e, body, y - 70, "cloud.account", d.cloud_sum, d.kind == "choose" and d.recommend == "cloud")
		y = y - 170
	end
	for _, b in ipairs(v.buttons) do
		local cy = y - BTN_H / 2 - 4
		s:button({ parent = body, x = 0, y = cy, w = 520, h = BTN_H, style = b.style, text = i18n.tr(b.text), text_size = 28,
			on_click = function() pick(e, d, b.id) end })
		e:target(b.id, 0, cy)
		y = y - BTN_H - 16
	end
end

-- Closing the window with the corner button is "not now".
function M.closed(e, result)
	if result == nil or result == "close" or result == "back" then
		if cloud.decision() then cloud.resolve("cancel") end
	end
end

return M
