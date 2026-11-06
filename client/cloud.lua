-- Cloud save: signs the device save to an account and keeps the two in step (WP-10).
--
--   cloud.init({app = require("client.app"), auth = require("client.services.auth"), binding = backend})
--   cloud.start()                    -- boot: restores the session, reconciles when somebody is signed in
--   cloud.on_signed_in()             -- after a sign-in from the UI: reconcile the account with this device
--   cloud.tick(now)                  -- once a second: background upload, retries
--   cloud.decision()                 -- a question for the player (or nil): see "decisions" below
--   cloud.resolve("download" | "upload" | "fresh" | "cancel")
--   cloud.status()                   -- {status, last_sync, failures, ...} for the indicator
--
-- Safety rules (docs/design/decisions.md, section 11):
--   * The device save is never deleted or overwritten by a network result. A cloud save replaces it only
--     through app.replace_save, which moves the device save to the "previous" slot first; a failed call changes
--     nothing and is retried later (15 s, 30 s, 1 min ... 5 min). The game does not wait for any of it.
--   * Progress decides, never time (meta/cloudsync.lua). A save with less progress never replaces one with more
--     without the player's choice; the loser is kept ("previous" slot on the device, "previous" field in the cloud).
--   * The cloud save is the same save code as the settings window's (meta/savecode.lua), checked completely
--     (code checksum, save checksum, restore) before it is used; a damaged one is never applied.
--   * The device save remembers which account it was synced with (the binding file, outside the save). A save
--     that belongs to another account is never uploaded to this one and never merged with its cloud save.
--
-- Decisions (cloud.decision().kind): "offer_upload" (this device is ahead), "offer_download" (the account is
-- ahead), "choose" (different branches: both summaries are shown, `recommend` is the one further along),
-- "foreign" (the save here belongs to another account). Until the player answers, nothing is uploaded; a
-- decision never opens during a level (the town asks for it).
--
-- Status: "off" (guest, or no provider), "syncing", "synced", "offline", "error", "decision", "paused".
-- Bus: "cloud_status" {status}, "cloud_decision" {kind}.

local bus = require("client.bus")
local savecode = require("meta.savecode")
local cloudsync = require("meta.cloudsync")
local analytics = require("client.services.analytics")

local M = {}

M.RETRY_FIRST, M.RETRY_MAX = 15, 300
M.UPLOAD_EVERY = 60      -- seconds between background uploads of ordinary progress
M.UPLOAD_AFTER_WIN = 3   -- ... and after a won level

local S

local function now() return S.now() end

local function fresh_binding()
	return { v = 1, uid = nil, signed_out = false, welcomed = false, reminded = 0, synced = nil }
end

local function load_binding(backend)
	local t = backend and backend.read() or nil
	local b = fresh_binding()
	if type(t) == "table" then
		if type(t.uid) == "string" then b.uid = t.uid end
		b.signed_out = t.signed_out == true
		b.welcomed = t.welcomed == true
		if type(t.reminded) == "number" then b.reminded = t.reminded end
		if type(t.synced) == "string" then b.synced = t.synced end
	end
	return b
end

local function save_binding()
	if S.backend then S.backend.write(S.binding) end
end

local function set_status(st)
	if S.status == st then return end
	S.status = st
	bus.publish("cloud_status", { status = st })
end

-- Forgets everything (tests: a later test file must not meet this state).
function M.reset() S = nil end

-- opts: {app, auth, binding = {read() -> table|nil, write(table)}, now, seed}
function M.init(opts)
	S = {
		app = opts.app, auth = opts.auth, backend = opts.binding,
		now = opts.now or function() return opts.app.now() end,
		seed = opts.seed or function() return require("client.platform").random_seed() end,
		binding = load_binding(opts.binding),
		status = "off", decision = nil, failures = 0, next_try = 0, busy = false,
		need_begin = false, paused = false, last_sync = nil, last_try = -1e9, wins_synced = nil, reason = nil,
	}
	bus.publish("cloud_status", { status = "off" })
	return S.binding
end

local function user() return S and S.auth.user() end

-- The save table on disk (the last good write): what a sync compares and uploads.
local function device_table()
	local app = S.app
	local t = app.store.last
	if not t then
		t = app.meta:serialize()
		app.store:save(t)
	end
	return t
end

local function device_summary()
	return cloudsync.summarize(device_table(), S.app.districts)
end

-- failures ---------------------------------------------------------------------------------------------

local function backoff()
	local n = math.min(S.failures, 6)
	return math.min(M.RETRY_MAX, M.RETRY_FIRST * 2 ^ (n - 1))
end

local function fail(why, at_begin)
	S.busy = false
	S.failures = S.failures + 1
	S.reason = why
	S.next_try = now() + backoff()
	if at_begin then S.need_begin = true end
	if why == "unavailable" then
		set_status("off")
	elseif why == "offline" or why == "timeout" then
		set_status("offline")
	else
		set_status("error")
	end
	if S.failures == 1 then analytics.log("save_error", { error = "cloud_" .. tostring(why) }) end
	return false, why
end

local function success()
	S.busy = false
	S.failures, S.reason, S.next_try = 0, nil, 0
	S.last_sync = now()
	set_status("synced")
end

local function bound_to(u)
	if S.binding.uid == nil then return "none" end
	return S.binding.uid == u.uid and "same" or "other"
end

local function mark_synced(u, checksum)
	S.binding.uid, S.binding.signed_out, S.binding.synced = u.uid, false, checksum
	S.wins_synced = S.app.meta:stats().wins
	save_binding()
end

-- reconciling -------------------------------------------------------------------------------------------

-- Reads the cloud document. Returns tbl, summary, damaged:
--   a good save -> tbl, summary;   no document -> nil, nil;   only damaged ones -> nil, nil, true.
-- A damaged current save falls back to the document's previous save.
local function read_doc(doc)
	if not doc then return nil, nil, false end
	local damaged = false
	for _, code in ipairs({ doc.code or "", doc.previous or "" }) do
		if code ~= "" then
			local tbl = savecode.decode(code)
			local sum = tbl and cloudsync.summarize(tbl, S.app.districts)
			if sum then return tbl, sum, damaged end
			damaged = true
		end
	end
	return nil, nil, damaged
end

local function upload(u, previous_code, loc_tbl)
	local ok, code = pcall(savecode.encode, loc_tbl)
	if not ok then return fail("error") end
	S.auth.cloud_put(code, previous_code, function(good, why)
		if not good then return fail(why or "error") end
		mark_synced(u, loc_tbl.checksum)
		success()
	end)
	return true
end

local function ask(d)
	S.busy = false
	S.decision = d
	set_status("decision")
	bus.publish("cloud_decision", { kind = d.kind })
end

-- The core of a sync: the account's document arrived. `background`: this device was in sync with the account
-- before, and only changes that cannot lose the cloud's progress go through without a question.
local function reconcile(u, doc, background)
	local loc_tbl = device_table()
	local loc = cloudsync.summarize(loc_tbl, S.app.districts)
	if not loc then return fail("error") end
	local tbl, sum, damaged = read_doc(doc)
	local bound = bound_to(u)
	if damaged and not tbl then
		-- the account's save is unreadable: never overwrite it silently, never apply it
		return ask({ kind = "offer_upload", local_sum = loc, damaged = true, doc = doc, bound = bound })
	end
	if background and bound == "same" then
		local what = cloudsync.background(loc, sum)
		if what == "none" then
			mark_synced(u, loc.checksum)
			return success()
		elseif what == "upload" then
			return upload(u, doc and doc.code or nil, loc_tbl)
		end
	end
	local plan = cloudsync.plan(loc, sum, bound)
	local a = plan.action
	if a == "none" then
		mark_synced(u, loc.checksum)
		return success()
	elseif a == "upload" then
		return upload(u, doc and doc.code or nil, loc_tbl)
	end
	return ask({ kind = a, local_sum = loc, cloud_sum = sum, cloud_tbl = tbl, recommend = plan.recommend, doc = doc,
		bound = bound, has_cloud = tbl ~= nil, damaged = damaged })
end

local function fetch(background)
	local u = user()
	if not u then S.busy = false; return end
	if S.busy then return end
	S.busy = true
	S.last_try = now()
	if not background then set_status("syncing") end
	S.auth.cloud_get(function(ok, why, doc)
		local cur = user()
		if not cur or cur.uid ~= u.uid then S.busy = false; return end -- signed out or switched meanwhile
		if not ok then return fail(why or "error", not background) end
		S.need_begin = false
		local fine, err = pcall(reconcile, cur, doc, background)
		if not fine then
			print("WARNING: cloud: reconcile failed: " .. tostring(err))
			fail("error")
		end
	end)
end

-- public ---------------------------------------------------------------------------------------------------

-- Before init() (tests of other screens) the cloud is simply off.
function M.binding() return S and S.binding end
function M.decision() return S and S.decision end

-- A sign-in finished (UI) or the stored session was restored: compare this device with the account.
function M.on_signed_in()
	if not S or not user() then return end
	S.decision, S.paused, S.failures, S.next_try = nil, false, 0, 0
	S.need_begin = true
	S.busy = false
	fetch(false)
end

function M.start()
	if not S then return end
	if not S.auth.available() then
		set_status("off")
		return
	end
	S.auth.restore(function(ok, _, u)
		if ok and u then M.on_signed_in() else set_status("off") end
	end)
end

-- The player's answer to cloud.decision(). Returns true, or false and why (the decision then stays).
function M.resolve(choice)
	if not S then return false, "no_decision" end
	local d = S.decision
	local u = user()
	if not d then return false, "no_decision" end
	if not u then S.decision = nil; set_status("off"); return false, "no_user" end
	local app = S.app
	if choice == "cancel" then
		S.decision, S.paused = nil, true
		set_status("paused")
		return true
	elseif choice == "download" then
		if not d.cloud_tbl then return false, "no_cloud" end
		local loser = device_table()
		local ok, why = app.replace_save(d.cloud_tbl, S.seed(), now())
		if not ok then return false, why or "write" end
		S.decision, S.paused = nil, false
		mark_synced(u, d.cloud_tbl.checksum)
		success()
		-- The device save lost: the "previous" slot keeps it only until the next save, so the account keeps a copy
		-- too (best effort). Never for a save that belongs to another account: it must not enter this one.
		if d.kind ~= "foreign" and d.local_sum and (d.local_sum.beaten > 0 or d.local_sum.wins > 0) then
			local enc, loser_code = pcall(savecode.encode, loser)
			local cur, cur_code = pcall(savecode.encode, d.cloud_tbl)
			if enc and cur then S.auth.cloud_put(cur_code, loser_code, function() end) end
		end
		return true
	elseif choice == "upload" then
		if d.kind == "foreign" and d.has_cloud then return false, "refused" end -- never merges into the account's own save
		local loc_tbl = device_table()
		if d.cloud_tbl and d.kind == "choose" then
			-- the loser stays on the device: the account's save becomes the "previous" slot
			app.store.last = d.cloud_tbl
			local ok, err = app.store:save(loc_tbl)
			if not ok then
				app.store.last = loc_tbl
				return false, "write", err
			end
		end
		S.decision, S.paused = nil, false
		set_status("syncing")
		S.busy = true
		upload(u, d.doc and d.doc.code or nil, loc_tbl)
		return true
	elseif choice == "fresh" then
		if d.kind ~= "foreign" or d.has_cloud then return false, "refused" end
		local tbl = app.new_save(S.seed())
		local ok, why = app.replace_save(tbl, S.seed(), now())
		if not ok then return false, why or "write" end
		S.decision, S.paused = nil, false
		mark_synced(u, device_table().checksum)
		success()
		return true
	end
	return false, "bad_choice"
end

-- Once a second. Reconciles after a failed start, uploads progress in the background, retries.
function M.tick(t)
	if not S or not S.app.meta then return end
	local u = user()
	if not u or S.busy or S.decision or S.paused then return end
	t = t or now()
	if t < S.next_try then return end
	if S.need_begin then
		return fetch(false)
	end
	if S.binding.uid ~= u.uid then return end
	local cur = S.app.store.last
	if not cur then return end
	if cur.checksum == S.binding.synced then return end
	-- a won level since the last sync is uploaded within seconds, other progress once a minute
	local urgent = S.wins_synced ~= nil and S.app.meta:stats().wins ~= S.wins_synced
	local gap = urgent and M.UPLOAD_AFTER_WIN or M.UPLOAD_EVERY
	if t - S.last_try >= gap or S.failures > 0 then fetch(true) end
end

-- The app goes to the background: whatever is waiting is sent now (best effort), without the usual pause.
function M.flush()
	if not S then return end
	S.last_try = -1e9
	M.tick(now())
end

-- "Sync now" (the account window).
function M.sync_now()
	if not S or not user() then return false end
	if S.decision then return false end
	S.paused, S.next_try = false, 0
	if S.busy then return true end
	if S.binding.uid ~= user().uid then S.need_begin = true end
	fetch(not S.need_begin)
	return true
end

-- Signs out. The device save stays (it keeps being tied to the account it was synced with: another account
-- signing in here is asked first, see cloudsync "foreign").
function M.sign_out(cb)
	if not S then return cb and cb(false, "unavailable") end
	S.auth.sign_out(function(ok, why)
		if ok then
			S.binding.signed_out = true
			save_binding()
			S.decision, S.paused, S.need_begin, S.failures, S.busy = nil, false, false, 0, false
			set_status("off")
		end
		if cb then cb(ok, why) end
	end)
end

-- Deletes the account and its cloud data (the provider does both). The progress on the device stays.
function M.delete_account(cb)
	if not S then return cb and cb(false, "unavailable") end
	S.auth.delete_account(function(ok, why)
		if ok then
			S.binding.uid, S.binding.synced, S.binding.signed_out = nil, nil, false
			save_binding()
			S.decision, S.paused, S.need_begin, S.failures, S.busy = nil, false, false, 0, false
			set_status("off")
		end
		if cb then cb(ok, why) end
	end)
end

-- First-launch window and the guest reminder --------------------------------------------------------------

function M.welcomed() return S == nil or S.binding.welcomed end
function M.set_welcomed()
	if not S or S.binding.welcomed then return end
	S.binding.welcomed = true
	save_binding()
end

M.REMIND_FROM, M.REMIND_EVERY = 10, 10

-- True when a guest (nobody signed in) has beaten REMIND_EVERY levels since the last reminder.
function M.guest_reminder_due(beaten)
	if not S then return false end
	if user() or not S.auth.available() then return false end
	if S.binding.uid ~= nil and not S.binding.signed_out then return false end
	return beaten >= M.REMIND_FROM and beaten - S.binding.reminded >= M.REMIND_EVERY
end

function M.mark_reminded(beaten)
	if not S then return end
	S.binding.reminded = beaten
	save_binding()
end

-- For the UI: what to show.
function M.status()
	if not S then return { status = "off", failures = 0, signed_in = false, paused = false, dirty = false } end
	return {
		status = S.status, last_sync = S.last_sync, failures = S.failures, reason = S.reason,
		signed_in = user() ~= nil, paused = S.paused,
		dirty = user() ~= nil and S.app.store.last ~= nil and S.app.store.last.checksum ~= S.binding.synced,
	}
end

return M
