-- Account window. params.mode = "choice" (the first-launch window: guest / Google / ID and password / create
-- an account) or nothing (the account manager opened from the settings: who is signed in, link Google or an
-- e-mail, sign out, delete the account and its data). Without a configured provider it says honestly that
-- sign-in is not available yet and the player stays a guest.
-- The actions are in client/account.lua; passwords are typed into the browser's own form, not here.

local app = require("client.app")
local i18n = require("client.i18n")
local auth = require("client.services.auth")
local cloud = require("client.cloud")
local account = require("client.account")
local kit = require("gui.kit")

local M = {}

local W = 620
local BTN_W, BTN_H, GAP = 520, 88, 18
local TEXT_W = W - 90

-- Lines a text takes in a block TEXT_W wide at `size` (an estimate by characters: Korean is wider).
local function lines_of(text, size)
	local n = 0
	for i = 1, #text do
		local b = text:byte(i)
		if b < 128 or b >= 192 then n = n + 1 end
	end
	local per = (i18n.language() == "ko" and 1.0 or (i18n.language() == "ru" and 0.62 or 0.55)) * size
	local chars_per_line = math.max(8, math.floor(TEXT_W / per))
	return math.max(1, math.ceil(n / chars_per_line))
end

local function text_block(items, spec, size, color)
	local text = i18n.tr(spec)
	local h = lines_of(text, size) * (size + 10) + 12
	items[#items + 1] = { kind = "text", text = text, size = size, color = color or "text", h = h }
end

local function button(items, id, text, style, fn)
	items[#items + 1] = { kind = "button", id = id, text = text, style = style or "blue", fn = fn, h = BTN_H }
end

local function confirm_sign_out(e)
	local st = cloud.status()
	e:open("confirm", {
		title = { key = "account.signout_title" },
		text = { key = st.dirty and "account.signout_unsynced" or "account.signout_text" },
		icon = "ui/icons/city",
		h = 700,
		confirm = { text = { key = "account.sign_out" }, style = "pink" },
		on_confirm = function()
			account.sign_out(function() app.close_popup() end)
		end,
	})
end

local function confirm_delete(e)
	e:open("confirm", {
		title = { key = "account.delete_title" },
		text = { key = "account.delete_text" },
		h = 760,
		confirm = { text = { key = "account.delete_do" }, style = "pink" },
		on_confirm = function()
			account.delete_account(function() app.close_popup() end)
		end,
	})
end

local function build_items(e, choice)
	local items = {}
	local available = auth.available()
	local user = auth.user()
	local function done(ok)
		if choice then
			if ok then
				cloud.set_welcomed()
				e:close("signed_in")
			end
		else
			e:rebuild()
		end
	end
	if choice then
		text_block(items, { key = available and "account.choice_text" or "account.unavailable" }, 28)
		if available then
			button(items, "google", i18n.t("account.google"), "green", function() account.sign_in_google(done) end)
			button(items, "id_login", i18n.t("account.id_login"), "blue", function() account.sign_in_id("login", done) end)
			button(items, "create", i18n.t("account.create"), "blue", function() account.sign_in_id("register", done) end)
		end
		text_block(items, { key = "account.guest_note" }, 24, "text_soft")
		if available then text_block(items, { key = "account.privacy" }, 22, "text_soft") end
		button(items, "guest", i18n.t("account.guest"), "pink", function()
			cloud.set_welcomed()
			e:close("guest")
		end)
		return items
	end
	if not user then
		text_block(items, { key = "account.as_guest" }, 28)
		if available then
			button(items, "google", i18n.t("account.google"), "green", function() account.sign_in_google(done) end)
			button(items, "id_login", i18n.t("account.id_login"), "blue", function() account.sign_in_id("login", done) end)
			button(items, "create", i18n.t("account.create"), "blue", function() account.sign_in_id("register", done) end)
		else
			text_block(items, { key = "account.unavailable" }, 26, "text_soft")
		end
		return items
	end
	text_block(items, { key = "account.signed_as", vars = { name = account.short(auth.label(user) or "?") } }, 30)
	text_block(items, { key = user.kind == "google" and "account.kind_google" or "account.kind_id" }, 24, "text_soft")
	text_block(items, account.status_spec(), 26, "purple")
	if user.kind == "password" and not auth.can_recover(user) then
		if user.pending_email then
			text_block(items, { key = "account.pending_mail", vars = { email = account.short(user.pending_email, 22) } }, 24, "text_soft")
		else
			text_block(items, { key = "account.no_mail_warn" }, 24, "pink")
		end
	end
	if not user.google_linked and user.kind == "password" then
		button(items, "link_google", i18n.t("account.link_google"), "blue", function() account.link_google(done) end)
	end
	if user.kind == "password" and not auth.can_recover(user) then
		if user.pending_email then
			button(items, "check_mail", i18n.t("account.check_mail"), "green", function() account.check_mail(done) end)
		end
		button(items, "link_email", i18n.t("account.link_email"), "blue", function() account.link_email(done) end)
	end
	button(items, "sync", i18n.t("account.sync_now"), "blue", function()
		cloud.sync_now()
		e:rebuild()
	end)
	button(items, "sign_out", i18n.t("account.sign_out"), "blue", function() confirm_sign_out(e) end)
	button(items, "delete", i18n.t("account.delete"), "pink", function() confirm_delete(e) end)
	return items
end

function M.build(e)
	local s = e.ui
	local choice = e.params and e.params.mode == "choice"
	local items = build_items(e, choice)
	local total = 0
	for _, it in ipairs(items) do total = total + it.h + GAP end
	local H = total + 200
	local body, hh = kit.panel(e, W, H, {
		title = { key = choice and "account.choice_title" or "account.title" }, fit = true,
	})
	local y = hh - 120
	for _, it in ipairs(items) do
		local cy = y - it.h / 2
		if it.kind == "text" then
			s:text(body, it.text, 0, cy, { font = "body", size = it.size, color = it.color, width = TEXT_W, height = it.h })
		else
			s:button({ parent = body, x = 0, y = cy, w = BTN_W, h = it.h, style = it.style, text = it.text, text_size = 28,
				on_click = it.fn })
			e:target(it.id, 0, cy)
		end
		y = y - it.h - GAP
	end
end

-- A first-launch window closed by the corner button counts as "guest".
function M.closed(e)
	if e.params and e.params.mode == "choice" then cloud.set_welcomed() end
end

function M.on_event(e, topic)
	if (topic == "cloud_status" or topic == "auth_changed") and not (e.params and e.params.mode == "choice") then
		e:rebuild()
	end
end

return M
