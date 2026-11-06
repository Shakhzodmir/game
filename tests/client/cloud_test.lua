-- Cloud sync scenarios on the mock provider (client/cloud.lua, meta/cloudsync.lua): sign-in with every
-- combination of device and account save, background upload and retries, offline, damaged data, another
-- account on the same device, deletion. Several "devices" share one fake server (the mock).

local app = require("client.app")
local bus = require("client.bus")
local save_io = require("client.save_io")
local auth = require("client.services.auth")
local cloud = require("client.cloud")
local savecode = require("meta.savecode")
local cloudsync = require("meta.cloudsync")
local analytics = require("client.services.analytics")
local mock_mod = require("client.services.auth_mock")
local H = require("tests.meta.helper")

local T
local function boot_device(files, seed, binding_file)
	analytics.init({ strict = true })
	local backend = save_io.memory_backend(files)
	T = T or H.T0
	app.init({
		districts = H.districts(), store = save_io.new(backend), seed = seed or 42, now = T,
		clock = function() return T end, sys_language = "en",
	})
	local bfile = binding_file or {}
	local binding = { read = function() return bfile.data end, write = function(t) bfile.data = require("meta.util").copy(t); return true end }
	cloud.init({ app = app, auth = auth, binding = binding, now = function() return T end, seed = function() return 5 end })
	return { backend = backend, bfile = bfile }
end

local function wins(n)
	for _ = 1, n do H.win(app.meta, T) end
	app.commit("test")
end

local function new_server()
	local m = mock_mod.new()
	auth.set_provider(m)
	return m
end

local function sign_in_google(m, sub, email)
	m.google_next = { sub = sub or "g1", email = email or "a@gmail.com", name = "Anna" }
	local res
	auth.sign_in_google(function(ok, why) res = { ok, why } end)
	assert_true(res[1], tostring(res[2]))
	cloud.on_signed_in()
end

local function cloud_summary(m, uid)
	local d = m.docs[uid or m.session]
	if not d then return nil end
	return cloudsync.summarize(assert(savecode.decode(d.code)), H.districts())
end

local function previous_summary(dev)
	local _, prev = app.store:load()
	return prev and cloudsync.summarize(prev, H.districts())
end

describe("cloudsync rules", function()
	local function sum(beaten, stars, wins_, salt)
		return { beaten = beaten, stars = stars, wins = wins_ or beaten, coins = 0, salt = salt or 1, checksum = "c" .. beaten .. stars }
	end

	it("orders saves of one player by progress and never by time", function()
		assert_eq(cloudsync.compare(sum(5, 10), sum(5, 10)), "equal")
		assert_eq(cloudsync.compare(sum(6, 10), sum(5, 10)), "a")
		assert_eq(cloudsync.compare(sum(5, 10), sum(5, 12)), "b")
		assert_eq(cloudsync.compare(sum(6, 8), sum(5, 12)), "branch")
	end)

	it("treats different salts as branches unless one side is a fresh game", function()
		assert_eq(cloudsync.compare(sum(5, 10, 5, 1), sum(3, 5, 3, 2)), "branch")
		assert_eq(cloudsync.compare(sum(0, 0, 0, 1), sum(3, 5, 3, 2)), "b")
		assert_eq(cloudsync.compare(sum(3, 5, 3, 2), sum(0, 0, 0, 1)), "a")
		assert_eq(cloudsync.compare(sum(0, 0, 0, 1), sum(0, 0, 0, 2)), "equal")
	end)

	it("plans every meeting of a device save and an account save", function()
		local a = cloudsync.plan
		assert_eq(a(sum(5, 10), nil, "none").action, "upload")
		assert_eq(a(sum(0, 0, 0), nil, "none").action, "none")
		assert_eq(a(sum(5, 10), sum(5, 10), "same").action, "none")
		assert_eq(a(sum(6, 10), sum(5, 10), "none").action, "offer_upload")
		assert_eq(a(sum(5, 10), sum(6, 10), "none").action, "offer_download")
		local p = a(sum(5, 10, 5, 1), sum(9, 20, 9, 2), "none")
		assert_eq(p.action, "choose")
		assert_eq(p.recommend, "cloud")
		assert_eq(a(sum(5, 10), nil, "other").action, "foreign")
		assert_eq(a(sum(5, 10), sum(1, 1), "other").has_cloud, true)
	end)

	it("lets a background upload through only when the cloud keeps its progress", function()
		local b = cloudsync.background
		assert_eq(b(sum(5, 10), nil), "upload")
		assert_eq(b(sum(6, 10), sum(5, 10)), "upload")
		assert_eq(b(sum(5, 10), sum(5, 10)), "none")
		assert_eq(b(sum(5, 10), sum(6, 10)), "conflict")
		assert_eq(b(sum(6, 8), sum(5, 12)), "conflict")
	end)
end)

describe("client.cloud: sign-in", function()
	before_each(function() T = H.T0 end)

	it("uploads the device save to an empty account at once, with the same code as the settings window", function()
		local m = new_server()
		boot_device()
		wins(3)
		sign_in_google(m)
		assert_eq(cloud.status().status, "synced")
		assert_eq(m.puts, 1)
		assert_eq(cloud_summary(m).beaten, 3)
		local code = app.export_code()
		assert_eq(m.docs[m.session].code, code)
		assert_eq(cloud.binding().uid, m.session)
	end)

	it("does not upload an untouched new game", function()
		local m = new_server()
		boot_device()
		sign_in_google(m)
		assert_eq(m.puts, 0)
		assert_eq(cloud.status().status, "synced")
	end)
end)

describe("client.cloud: scenarios", function()
	before_each(function() T = H.T0 end)

	-- A and B are two devices of one player: B starts as a copy of A's save at 3 wins.
	local function two_devices()
		local m = new_server()
		boot_device()
		wins(3)
		sign_in_google(m)
		local uid = m.session
		local code3 = m.docs[uid].code
		return m, uid, code3
	end

	local function device_from_code(code)
		local tbl = assert(savecode.decode(code))
		return boot_device({ current = { glow_save = 1, data = tbl } }, 42)
	end

	it("offers to take the cloud save when the account is ahead", function()
		local m, uid, code3 = two_devices()
		wins(2) -- A plays on
		T = T + 5
		cloud.tick(T)
		assert_eq(cloud_summary(m).beaten, 5)
		m.session = nil
		auth.sign_out()
		device_from_code(code3)
		sign_in_google(m)
		local d = cloud.decision()
		assert_eq(d.kind, "offer_download")
		assert_eq(d.local_sum.beaten, 3)
		assert_eq(d.cloud_sum.beaten, 5)
		assert_eq(cloud.status().status, "decision")
		assert_eq(m.puts, 2, "nothing was uploaded while the question is open")
		assert_true(cloud.resolve("download"))
		assert_eq(app.meta:level_to_play(), 6)
		assert_eq(previous_summary().beaten, 3, "the device save is the backup")
		assert_eq(cloud.status().status, "synced")
		assert_eq(cloudsync.summarize(savecode.decode(m.docs[uid].previous), H.districts()).beaten, 3,
			"and the account keeps a copy of it")
		assert_eq(cloud_summary(m).beaten, 5)
	end)

	it("offers to upload when the device is ahead and keeps the old cloud save as previous", function()
		local m, uid, code3 = two_devices()
		wins(2)
		local d_before = m.docs[uid].code
		auth.sign_out()
		m.session = nil
		cloud.sign_out()
		-- offline play on A: the binding stays, the device has 5 wins
		sign_in_google(m)
		local d = cloud.decision()
		assert_eq(d.kind, "offer_upload")
		assert_eq(m.docs[uid].code, d_before, "still the old save")
		assert_true(cloud.resolve("upload"))
		assert_eq(cloud_summary(m).beaten, 5)
		assert_eq(m.docs[uid].previous, d_before)
	end)

	it("lets the player choose between branches and keeps the loser on both sides", function()
		local m, uid, code3 = two_devices() -- cloud: salt of seed 42, 3 wins
		auth.sign_out(); m.session = nil
		boot_device(nil, 7) -- another game, started independently
		wins(6)
		sign_in_google(m)
		local d = cloud.decision()
		assert_eq(d.kind, "choose")
		assert_eq(d.recommend, "local")
		assert_eq(d.local_sum.beaten, 6)
		assert_eq(d.cloud_sum.beaten, 3)
		assert_true(cloud.resolve("upload"))
		assert_eq(cloud_summary(m).beaten, 6)
		assert_eq(m.docs[uid].previous, code3, "the account's old save is kept in the cloud")
		assert_eq(previous_summary().beaten, 3, "and on the device")
		assert_eq(app.meta:level_to_play(), 7, "the device save was not touched")
	end)

	it("takes the cloud branch when the player says so, device save goes to previous", function()
		local m, uid, code3 = two_devices()
		auth.sign_out(); m.session = nil
		boot_device(nil, 7)
		wins(6)
		sign_in_google(m)
		assert_eq(cloud.decision().kind, "choose")
		assert_true(cloud.resolve("download"))
		assert_eq(app.meta:level_to_play(), 4)
		assert_eq(previous_summary().beaten, 6)
		assert_eq(m.docs[uid].code, code3, "the cloud keeps its save")
		assert_eq(cloudsync.summarize(savecode.decode(m.docs[uid].previous), H.districts()).beaten, 6)
	end)

	it("a postponed question pauses uploads without losing anything, sync_now asks again", function()
		local m, uid, code3 = two_devices()
		auth.sign_out(); m.session = nil
		boot_device(nil, 7)
		wins(6)
		sign_in_google(m)
		assert_true(cloud.resolve("cancel"))
		assert_eq(cloud.status().status, "paused")
		wins(1)
		T = T + 500
		cloud.tick(T)
		assert_eq(m.docs[uid].code, code3)
		assert_eq(m.puts, 1)
		assert_true(cloud.sync_now())
		assert_eq(cloud.decision().kind, "choose")
	end)
end)

describe("client.cloud: background sync", function()
	before_each(function() T = H.T0 end)

	it("uploads after a won level within seconds and ordinary progress once a minute", function()
		local m = new_server()
		boot_device()
		wins(1)
		sign_in_google(m)
		assert_eq(m.puts, 1)
		cloud.tick(T)
		wins(1)
		cloud.tick(T + 1)
		assert_eq(m.puts, 1, "not at once")
		T = T + 4
		cloud.tick(T)
		assert_eq(m.puts, 2, "after a win: within a few seconds")
		app.meta:grant({ coins = 50 }, "test", T)
		app.commit("test")
		T = T + 10
		cloud.tick(T)
		assert_eq(m.puts, 2, "coins alone wait for the minute")
		T = T + 61
		cloud.tick(T)
		assert_eq(m.puts, 3)
		cloud.tick(T + 100)
		assert_eq(m.puts, 3, "nothing changed: no upload")
	end)

	it("goes offline quietly, retries with a growing pause and catches up", function()
		local m = new_server()
		boot_device()
		wins(1)
		sign_in_google(m)
		m.online = false
		wins(1)
		T = T + 5
		cloud.tick(T)
		assert_eq(cloud.status().status, "offline")
		assert_eq(cloud.status().failures, 1)
		local gets = #m.calls
		cloud.tick(T + 3)
		assert_eq(#m.calls, gets, "waits before the next try")
		T = T + 16
		cloud.tick(T)
		assert_eq(cloud.status().failures, 2)
		assert_eq(app.meta:level_to_play(), 3, "the game is untouched")
		m.online = true
		T = T + 40
		cloud.tick(T)
		assert_eq(cloud.status().status, "synced")
		assert_eq(cloud_summary(m).beaten, 2)
	end)

	it("a sign-in made offline reconciles later", function()
		local m = new_server()
		boot_device()
		wins(2)
		m.online = false
		m.session = nil
		m.accounts.u001 = { uid = "u001", kind = "google", google_sub = "g1", verified = true, email = "a@gmail.com" }
		m.session = "u001"
		auth.restore(function() end)
		cloud.on_signed_in()
		assert_eq(cloud.status().status, "offline")
		assert_eq(m.puts, 0)
		m.online = true
		T = T + 20
		cloud.tick(T)
		assert_eq(cloud.status().status, "synced")
		assert_eq(m.puts, 1)
	end)

	it("a failed upload is not marked as synced", function()
		local m = new_server()
		boot_device()
		wins(1)
		sign_in_google(m)
		wins(1)
		local real = m.cloud_put
		m.cloud_put = function(code, prev, cb) cb(false, "offline") end
		T = T + 5
		cloud.tick(T)
		m.cloud_put = real
		assert_true(cloud.status().dirty)
		T = T + 20
		cloud.tick(T)
		assert_false(cloud.status().dirty)
		assert_eq(cloud_summary(m).beaten, 2)
	end)

	it("another device that got further stops the upload and asks, no overwrite", function()
		local m = new_server()
		boot_device()
		wins(3)
		sign_in_google(m)
		local uid = m.session
		-- the other device uploads 6 wins
		local other = app.export_code()
		wins(3)
		m.docs[uid] = { code = app.export_code(), puts = 99 }
		-- this device (3 wins) plays two more: it is 5, the cloud has 6
		local files = { current = { glow_save = 1, data = savecode.decode(other) } }
		local b = boot_device(files, 42, { data = { v = 1, uid = uid, synced = "x" } })
		wins(2)
		local cloud_code = m.docs[uid].code
		auth.restore(function() end)
		T = T + 70
		cloud.tick(T)
		local d = cloud.decision()
		assert_true(d ~= nil, "a question")
		assert_eq(d.kind, "offer_download")
		assert_eq(m.docs[uid].code, cloud_code, "the cloud keeps its progress")
	end)
end)

describe("client.cloud: damaged and forged data", function()
	before_each(function() T = H.T0 end)

	local function upload_three()
		local m = new_server()
		boot_device()
		wins(3)
		sign_in_google(m)
		return m, m.session
	end

	it("never applies or overwrites a damaged cloud save without asking", function()
		local m, uid = upload_three()
		auth.sign_out(); m.session = nil
		boot_device(nil, 42)
		wins(1)
		local code = m.docs[uid].code
		m.docs[uid] = { code = code:sub(1, #code - 7) .. "AAAAAAA" }
		local level = app.meta:level_to_play()
		sign_in_google(m)
		local d = cloud.decision()
		assert_eq(d.kind, "offer_upload")
		assert_true(d.damaged)
		assert_eq(app.meta:level_to_play(), level)
		assert_eq(m.puts, 1 , "nothing was written")
	end)

	it("falls back to the previous cloud save when the current one is damaged", function()
		local m, uid = upload_three()
		local good = m.docs[uid].code
		m.docs[uid] = { code = "GLOW1-garbage", previous = good }
		auth.sign_out(); m.session = nil
		boot_device(nil, 99) -- a different game on this device
		wins(1)
		sign_in_google(m)
		local d = cloud.decision()
		assert_eq(d.cloud_sum.beaten, 3)
		assert_true(d.damaged)
	end)

	it("refuses a code that parses but fails the save checks (a forged number)", function()
		local m, uid = upload_three()
		local tbl = savecode.decode(m.docs[uid].code)
		tbl.wallet.coins = 999999 -- the save checksum no longer fits
		m.docs[uid] = { code = savecode.encode(tbl) }
		auth.sign_out(); m.session = nil
		boot_device(nil, 42)
		wins(1)
		sign_in_google(m)
		assert_true(cloud.decision().damaged)
		assert_eq(cloud.decision().kind, "offer_upload")
		assert_eq(app.meta:coins() < 999999, true)
	end)

	it("the fake server keeps the access rule: only the owner reaches a document", function()
		local m, uid = upload_three()
		assert_true(m.raw_get(uid, uid) ~= nil)
		local doc, why = m.raw_get("someone_else", uid)
		assert_eq(doc, nil)
		assert_eq(why, "denied")
		assert_eq(select(2, m.raw_get(nil, uid)), "denied")
	end)
end)

describe("client.cloud: another account on the same device", function()
	before_each(function() T = H.T0 end)

	local function player_one()
		local m = new_server()
		boot_device()
		wins(4)
		sign_in_google(m, "g1", "one@gmail.com")
		local uid1 = m.session
		local doc1 = m.docs[uid1].code
		cloud.sign_out()
		return m, uid1, doc1
	end

	it("keeps the first player's save out of the second player's account", function()
		local m, uid1, doc1 = player_one()
		sign_in_google(m, "g2", "two@gmail.com")
		local d = cloud.decision()
		assert_eq(d.kind, "foreign")
		assert_false(d.has_cloud)
		assert_eq(m.docs[m.session], nil, "nothing uploaded to the new account")
		assert_eq(m.puts, 1)
		assert_false((cloud.resolve("download")))
		assert_true(cloud.resolve("fresh"))
		assert_eq(app.meta:level_to_play(), 1)
		assert_eq(previous_summary().beaten, 4, "the first player's save is still on the device")
		assert_eq(m.docs[uid1].code, doc1)
		assert_eq(cloud.binding().uid, m.session)
	end)

	it("an account that has a cloud save gets it, and never receives the device save", function()
		local m, uid1, doc1 = player_one()
		-- the second player played elsewhere
		boot_device(nil, 11)
		wins(2)
		sign_in_google(m, "g2", "two@gmail.com")
		local uid2 = m.session
		cloud.sign_out()
		-- back on the first player's device
		boot_device({ current = { glow_save = 1, data = savecode.decode(doc1) } }, 42, nil)
		wins(0)
		T = T + 1
		local binding = { data = { v = 1, uid = uid1, signed_out = true } }
		boot_device({ current = { glow_save = 1, data = savecode.decode(doc1) } }, 42, binding)
		sign_in_google(m, "g2", "two@gmail.com")
		local d = cloud.decision()
		assert_eq(d.kind, "foreign")
		assert_true(d.has_cloud)
		local doc2 = m.docs[uid2].code
		assert_false((cloud.resolve("upload")))
		assert_eq(m.docs[uid2].code, doc2)
		assert_true(cloud.resolve("download"))
		assert_eq(app.meta:level_to_play(), 3)
		assert_eq(previous_summary().beaten, 4)
		assert_eq(m.docs[uid1].code, doc1)
		assert_eq(m.docs[uid2].previous, nil, "the first player's save never enters the second account")
	end)

	it("the same account signing in again is a plain sync", function()
		local m, uid1, doc1 = player_one()
		sign_in_google(m, "g1", "one@gmail.com")
		assert_eq(cloud.decision(), nil)
		assert_eq(cloud.status().status, "synced")
	end)

	it("can bring this device's progress into a new account when the player says so", function()
		local m = new_server()
		boot_device()
		wins(4)
		sign_in_google(m, "g1")
		cloud.sign_out()
		sign_in_google(m, "g2")
		assert_eq(cloud.decision().kind, "foreign")
		assert_true(cloud.resolve("upload"))
		assert_eq(cloud_summary(m).beaten, 4)
	end)
end)

describe("client.cloud: deleting the account", function()
	before_each(function() T = H.T0 end)

	it("removes the cloud data and the account, and keeps the progress on the device", function()
		local m = new_server()
		boot_device()
		wins(3)
		sign_in_google(m)
		local uid = m.session
		local res
		cloud.delete_account(function(ok, why) res = { ok, why } end)
		assert_true(res[1])
		assert_eq(m.docs[uid], nil)
		assert_eq(m.accounts[uid], nil)
		assert_eq(auth.user(), nil)
		assert_eq(cloud.binding().uid, nil)
		assert_eq(app.meta:level_to_play(), 4)
		assert_eq(cloud.status().status, "off")
	end)

	it("asks for a fresh sign-in first and changes nothing before that", function()
		local m = new_server()
		boot_device()
		wins(3)
		sign_in_google(m)
		local uid = m.session
		m.recent = false
		local res
		cloud.delete_account(function(ok, why) res = { ok, why } end)
		assert_false(res[1])
		assert_eq(res[2], "need_recent_login")
		assert_true(m.docs[uid] ~= nil)
		assert_true(auth.user() ~= nil)
		assert_eq(cloud.binding().uid, uid)
	end)

	it("a failed network call during sign-out or delete loses nothing", function()
		local m = new_server()
		boot_device()
		wins(3)
		sign_in_google(m)
		m.online = false
		local res
		cloud.delete_account(function(ok, why) res = { ok, why } end)
		assert_eq(res[2], "offline")
		assert_eq(app.meta:level_to_play(), 4)
	end)
end)

describe("client.cloud: guest, first launch and reminders", function()
	before_each(function() T = H.T0 end)

	it("says nothing when sign-in is not available", function()
		auth.set_provider(nil)
		boot_device()
		assert_false(auth.available())
		assert_false(cloud.guest_reminder_due(50))
		cloud.start()
		assert_eq(cloud.status().status, "off")
		local res
		auth.sign_in_google(function(ok, why) res = { ok, why } end)
		assert_eq(res[2], "unavailable")
	end)

	it("reminds a guest every ten levels and remembers it", function()
		local m = new_server()
		local dev = boot_device()
		assert_false(cloud.guest_reminder_due(9))
		assert_true(cloud.guest_reminder_due(10))
		cloud.mark_reminded(10)
		assert_false(cloud.guest_reminder_due(19))
		assert_true(cloud.guest_reminder_due(20))
		boot_device(nil, 42, dev.bfile) -- the next launch reads the file
		assert_false(cloud.guest_reminder_due(19))
		sign_in_google(m)
		assert_false(cloud.guest_reminder_due(40), "a signed-in player is not a guest")
	end)

	it("remembers that the first-launch window was shown", function()
		new_server()
		local dev = boot_device()
		assert_false(cloud.welcomed())
		cloud.set_welcomed()
		boot_device(nil, 42, dev.bfile)
		assert_true(cloud.welcomed())
	end)

	it("restores a stored session at start", function()
		local m = new_server()
		boot_device()
		wins(2)
		sign_in_google(m)
		boot_device({ current = { glow_save = 1, data = app.store.last } }, 42, nil)
		cloud.start()
		assert_eq(cloud.status().status, "synced")
	end)
end)

describe("services.auth", function()
	it("normalizes and checks login ids and passwords", function()
		assert_eq(auth.normalize_id("  Anna_7 "), "anna_7")
		assert_true(auth.valid_id("anna_7"))
		for _, bad in ipairs({ "ab", "7anna", "an na", "anna@x", "a_very_long_login_name_over" }) do assert_false(auth.valid_id(bad), bad) end
		assert_eq(auth.synthetic_email("anna_7"), "anna_7@id.glow.invalid")
		assert_true(auth.is_synthetic("anna_7@id.glow.invalid"))
		assert_false(auth.is_synthetic("anna@gmail.com"))
		assert_false(auth.valid_password("short"))
		assert_true(auth.valid_password("longenough"))
	end)

	it("signs up, signs in by ID and password, links an e-mail through a mail and a Google account", function()
		local m = new_server()
		local res
		m.form_next = { id = "Anna_7", password = "secret123" }
		auth.password_form("register", {}, function(ok, why, u) res = { ok, why, u } end)
		assert_true(res[1])
		assert_eq(res[3].id, "anna_7")
		assert_eq(res[3].email, "anna_7@id.glow.invalid")
		assert_false(auth.can_recover(res[3]), "no recovery without a real e-mail")
		m.form_next = { id = "anna_7", password = "secret123" }
		auth.password_form("register", {}, function(ok, why) res = { ok, why } end)
		assert_eq(res[2], "id_taken")
		-- link an e-mail: a mail is sent, the address counts after the click
		m.form_next = { email = "anna@gmail.com" }
		auth.link_email_form({}, function(ok, why, u) res = { ok, why, u } end)
		assert_true(res[1])
		assert_eq(res[3].pending_email, "anna@gmail.com")
		assert_false(auth.can_recover(res[3]))
		assert_true(m.confirm_mail(1))
		auth.refresh(function(ok, why, u) res = { ok, why, u } end)
		assert_true(auth.can_recover(res[3]))
		-- link Google
		m.google_next = { sub = "g9", email = "anna@gmail.com" }
		auth.link_google(function(ok, why, u) res = { ok, why, u } end)
		assert_true(res[3].google_linked)
		auth.sign_out()
		m.form_next = { id = "anna_7", password = "wrong-pass" }
		auth.password_form("login", {}, function(ok, why) res = { ok, why } end)
		assert_eq(res[2], "bad_credentials")
		m.google_next = { sub = "g9", email = "anna@gmail.com" }
		auth.sign_in_google(function(ok, why, u) res = { ok, why, u } end)
		assert_eq(res[3].uid, "u001", "Google leads into the same account")
	end)

	it("answers busy to a second interactive call and survives a throwing callback", function()
		local m = new_server()
		m.manual = true
		m.google_next = { sub = "g1" }
		local first, second
		auth.sign_in_google(function(ok) first = ok end)
		auth.sign_in_google(function(ok, why) second = why end)
		assert_eq(second, "busy")
		m.flush()
		assert_true(first)
		auth.sign_out(function() error("boom") end)
	end)
end)

describe("cloud cleanup", function()
	it("leaves no provider and no cloud state behind for the next test file", function()
		require("client.cloud").reset()
		require("client.services.auth").set_provider(nil)
	end)
end)
