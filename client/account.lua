-- The account actions of the UI (windows gui/account.lua, gui/cloud_choice.lua, settings): each one calls the
-- auth service, tells the player the result with a toast and, after a sign-in, hands the account to the cloud
-- sync (client/cloud.lua). No GUI calls here: the windows only draw and call these functions.
-- Every action takes done(ok) to redraw the window.

local app = require("client.app")
local auth = require("client.services.auth")
local cloud = require("client.cloud")
local i18n = require("client.i18n")

local M = {}

-- A long address or ID shortened for a line of the UI ("a_really_long_addr...": one word cannot wrap).
function M.short(text, n)
	text = tostring(text or "")
	n = n or 20
	if #text <= n then return text end
	return text:sub(1, n - 3) .. "..."
end

-- reason -> i18n key; "cancelled" says nothing (the player closed the popup himself)
function M.error_key(reason)
	local key = "auth.err." .. tostring(reason)
	if reason ~= "error" and i18n.has(key) then return key end
	return "auth.err.error"
end

local function fail(reason)
	if reason == "cancelled" then return end
	app.toast_key(M.error_key(reason), nil, { color = "pink" })
end

-- The texts of the browser's sign-in form (it shows them; the game never sees what is typed).
function M.form_labels(kind)
	local L = {
		submit = i18n.t("common.ok"), cancel = i18n.t("common.cancel"),
		id = i18n.t("account.form_id"), password = i18n.t("account.form_password"),
		password2 = i18n.t("account.form_password2"), email = i18n.t("account.form_email"),
		err_id = i18n.t("account.form_err_id"), err_pw = i18n.t("account.form_err_pw"),
		err_pw2 = i18n.t("account.form_err_pw2"), err_email = i18n.t("account.form_err_email"),
	}
	if kind == "register" then
		L.title, L.note = i18n.t("account.create"), i18n.t("account.form_register_note")
	elseif kind == "email" then
		L.title, L.note = i18n.t("account.link_email"), i18n.t("account.form_mail_note")
	else
		L.title = i18n.t("account.id_login")
	end
	return L
end

local function signed_in(done)
	return function(ok, why)
		if ok then
			app.toast_key("account.signed_in", nil, { color = "gold" })
			cloud.on_signed_in()
		else
			fail(why)
		end
		if done then done(ok, why) end
	end
end

function M.sign_in_google(done) auth.sign_in_google(signed_in(done)) end
function M.sign_in_id(mode, done) auth.password_form(mode, M.form_labels(mode), signed_in(done)) end

function M.link_google(done)
	auth.link_google(function(ok, why)
		if ok then app.toast_key("account.linked", nil, { color = "gold" }) else fail(why) end
		if done then done(ok, why) end
	end)
end

function M.link_email(done)
	auth.link_email_form(M.form_labels("email"), function(ok, why, user)
		if ok then
			app.toast_key("account.mail_sent", { email = M.short(user and user.pending_email or "", 28) }, { color = "blue", duration = 4 })
		else
			fail(why)
		end
		if done then done(ok, why) end
	end)
end

-- "I confirmed the e-mail": asks the provider for the account again.
function M.check_mail(done)
	auth.refresh(function(ok, why, user)
		if not ok then
			fail(why)
		elseif auth.can_recover(user) then
			app.toast_key("account.mail_confirmed", nil, { color = "gold" })
		else
			app.toast_key("account.mail_not_yet", nil, { color = "blue" })
		end
		if done then done(ok, why) end
	end)
end

function M.sign_out(done)
	cloud.sign_out(function(ok, why)
		if ok then app.toast_key("account.signed_out", nil, { color = "blue" }) else fail(why) end
		if done then done(ok, why) end
	end)
end

function M.delete_account(done)
	cloud.delete_account(function(ok, why)
		if ok then app.toast_key("account.deleted", nil, { color = "blue" }) else fail(why) end
		if done then done(ok, why) end
	end)
end

-- Status line of the cloud: spec for i18n.tr.
function M.status_spec()
	local st = cloud.status()
	if not st.signed_in then return { key = "cloud.status.off" } end
	local name = st.status
	if name == "synced" and st.dirty then name = "syncing" end -- changes are waiting for the next upload
	if i18n.has("cloud.status." .. name) then return { key = "cloud.status." .. name } end
	return { key = "cloud.status.off" }
end

-- Short line "who": the account name, or "guest".
function M.who_spec()
	local u = auth.user()
	if not u then return { key = "settings.account_guest" } end
	return { key = "settings.account_user", vars = { name = M.short(auth.label(u) or "?") } }
end

-- {n = levels beaten, coins, stars} of a summary for the choice window.
function M.summary_spec(sum)
	return { key = "cloud.sum", vars = { n = sum.beaten, coins = i18n.number(sum.coins), stars = sum.stars } }
end

-- What the choice window shows for a decision of client/cloud.lua: {title, text, buttons = {{id, text, style}}}.
function M.decision_view(d)
	local k = d.kind
	local v = { title = { key = "cloud.title." .. k }, text = { key = "cloud.text." .. k }, buttons = {} }
	local function add(id, key, style) v.buttons[#v.buttons + 1] = { id = id, text = { key = key }, style = style } end
	if k == "offer_upload" then
		add("upload", "cloud.do_upload", "green")
	elseif k == "offer_download" then
		add("download", "cloud.do_download", "green")
	elseif k == "choose" then
		add("upload", "cloud.keep_device", d.recommend == "local" and "green" or "blue")
		add("download", "cloud.keep_cloud", d.recommend == "cloud" and "green" or "blue")
	elseif k == "foreign" then
		if d.has_cloud then
			add("download", "cloud.do_download", "green")
		else
			add("fresh", "cloud.start_new", "green")
			add("upload", "cloud.bring_device", "blue")
		end
	end
	add("cancel", "cloud.later", "blue")
	if d.damaged then v.text = { key = "cloud.text.damaged" } end
	return v
end

return M
