-- The static pages of the site (WP-18): web/privacy.html and web/404.html, and that the build and the publishing
-- step carry them next to index.html. Run from the repository root.

local i18n = require("client.i18n")

local function slurp(path)
	local f = assert(io.open(path, "rb"), path .. " is missing")
	local s = f:read("*a")
	f:close()
	return s
end

local function has(s, needle) return s:find(needle, 1, true) ~= nil end

local ISSUES = "https://github.com/Shakhzodmir/game/issues"
local PAGES = { "web/privacy.html", "web/404.html" }

-- everything starting with http: only the contact page of the repository may be linked
local function external_urls(s)
	local out = {}
	for url in s:gmatch("https?://[^%s\"'<>)]+") do out[#out + 1] = url end
	return out
end

describe("static pages: what every page must and must not contain", function()
	it("are single self-contained files in three languages", function()
		for _, path in ipairs(PAGES) do
			local s = slurp(path)
			assert_true(has(s, 'lang="ru"') and has(s, 'lang="en"') and has(s, 'lang="ko"'), path .. ": three languages")
			assert_true(s:find("[\234-\237][\128-\191][\128-\191]") ~= nil, path .. ": Hangul")
			assert_true(s:find("\208[\144-\175]") ~= nil, path .. ": Cyrillic")
			for _, code in ipairs({ "RU", "EN", "KO" }) do
				assert_true(s:find('data%-set="' .. code:lower() .. '"[^>]*>' .. code .. "</button>") ~= nil, path .. ": button " .. code)
			end
			assert_false(s:find("<link", 1, true) ~= nil, path .. ": no external stylesheet or font")
			assert_false(s:find("<img", 1, true) ~= nil, path .. ": no pictures")
			assert_false(s:find("<script[^>]-src=") ~= nil, path .. ": no external script")
			assert_false(s:find("@import", 1, true) ~= nil, path .. ": no @import")
			assert_false(s:find("url(", 1, true) ~= nil, path .. ": no url() resources")
			assert_true(has(s, "<style>"), path .. ": inline CSS")
		end
	end)

	it("hold no names, addresses, account paths or keys", function()
		for _, path in ipairs(PAGES) do
			local s = slurp(path)
			local low = s:lower()
			for _, bad in ipairs({ "@gmail", "aigpa", "c:\\", "c:/users", "apikey", "aiza", "api_key", "secret", "token", "password=" }) do
				assert_false(has(low, bad), path .. " contains '" .. bad .. "'")
			end
			assert_true(s:find("[%w._%-]+@[%w.%-]+%.%a%a") == nil, path .. ": an e-mail address")
		end
	end)
end)

describe("web/privacy.html", function()
	local s = slurp("web/privacy.html")

	it("is dated and links the public contact page, and nothing else outside the site", function()
		assert_true(has(s, "Обновлено: 17 ноября 2026"))
		assert_true(has(s, "Updated: November 17, 2026"))
		assert_true(has(s, "업데이트: 2026년 11월 17일"))
		assert_true(has(s, 'href="' .. ISSUES .. '"'))
		for _, url in ipairs(external_urls(s)) do assert_eq(url, ISSUES, "unexpected link " .. url) end
	end)

	it("leads back to the game next to it, in every language", function()
		local _, n = s:gsub('class="back" href="%./"', "")
		assert_eq(n, 6, "two back links per language")
		assert_true(has(s, "Назад в игру") and has(s, "Back to the game") and has(s, "게임으로 돌아가기"))
	end)

	it("states the facts of the code: what is kept, what is not, where, how to delete, children", function()
		local ru, en, ko = s:match('<section data%-l="ru".-</section>'), s:match('<section data%-l="en".-</section>'), s:match('<section data%-l="ko".-</section>')
		assert_true(ru and en and ko, "three sections")
		for _, t in ipairs({ ru, en, ko }) do assert_true(has(t, "eur3"), "the region") assert_true(has(t, "Firebase")) end
		assert_true(has(ru, "Нет рекламы") and has(ru, "Нет аналитики и отслеживания") and has(ru, "не продаём"))
		assert_true(has(en, "No ads") and has(en, "No analytics and no tracking") and has(en, "do not sell"))
		assert_true(has(ko, "광고가 없습니다") and has(ko, "분석과 추적이 없습니다") and has(ko, "판매하지 않으며"))
		assert_true(has(ru, "Пароль знает только сервис входа") and has(en, "known only to the sign-in service"))
		assert_true(has(ru, "младше 13 лет без разрешения родителей") and has(en, "under 13 without a parent's permission") and has(ko, "만 13세 미만"))
		assert_true(has(ru, "код сохранения игры") and has(en, "save code") and has(ko, "저장 코드"))
	end)

	it("names the deletion button exactly as the game does", function()
		local expect = { ru = "Удалить аккаунт и данные", en = "Delete account and data", ko = "계정과 데이터 삭제" }
		for lang, text in pairs(expect) do
			assert_eq(i18n.STRINGS["account.delete"][lang], text, "the game's own label changed: update the page")
			assert_true(has(s, text), lang .. ": the page must name the button '" .. text .. "'")
		end
	end)
end)

describe("web/404.html", function()
	local s = slurp("web/404.html")

	it("sends the visitor back to the game in every language and picks the language by the browser", function()
		local _, n = s:gsub('<a class="go" href="/game/">', "")
		assert_eq(n, 3)
		assert_true(has(s, "Вернуться в игру") and has(s, "Back to the game") and has(s, "게임으로 돌아가기"))
		assert_true(has(s, "navigator.language"))
		assert_eq(#external_urls(s), 0, "no outside links at all")
	end)

	it("draws Bit with CSS only", function()
		assert_true(has(s, 'class="bit"') and has(s, 'class="band"') and has(s, 'class="cup l"'))
		assert_true(has(s, "#7B4FFF"), "the purple of the headphones")
	end)
end)

describe("the build and the publishing step carry the pages", function()
	it("tools/build_web.sh copies both pages next to index.html", function()
		local s = slurp("tools/build_web.sh")
		assert_true(has(s, "web/privacy.html") and has(s, "web/404.html"))
		assert_true(s:find('cp [^\n]*web/privacy%.html[^\n]*"%$out/"') ~= nil)
		assert_true(s:find('cp [^\n]*web/404%.html[^\n]*"%$out/"') ~= nil)
	end)

	it("the gh-pages step publishes the whole bundle folder, so the pages go with it", function()
		local s = slurp(".github/workflows/ci.yml")
		local pages = s:match("\n  pages:.*$")
		assert_true(pages ~= nil)
		assert_true(has(pages, "git add -A"), "the step must add every file of the bundle folder")
		assert_true(has(pages, '$(dirname "$(find dist -name index.html | head -1)")'), "and publish the folder with index.html")
		assert_false(has(pages, "privacy.html"), "no per-file list: a new page needs no workflow change")
	end)
end)

describe("the sign-in scripts of the game page", function()
	it("carry the version of glow_auth.js in their address, so a phone that holds an older copy asks again", function()
		local js = slurp("web/glow_auth.js")
		local version = js:match('var VERSION = "([%d%-]+%a?)"')
		assert_true(version ~= nil, "VERSION in web/glow_auth.js")
		local page = slurp("web/engine_template.html")
		assert_true(has(page, 'src="glow_auth.js?v=' .. version .. '"'), "engine_template.html must ask for glow_auth.js?v=" .. version)
		assert_true(has(page, 'src="auth_config.js?v=' .. version .. '"'), "and for auth_config.js with the same version")
	end)

	it("gives glow_oidc.js the very same version, so a change of either file is one release and the dark line names the code that ran", function()
		local js = slurp("web/glow_auth.js")
		local core = slurp("web/glow_oidc.js")
		local version = js:match('var VERSION = "([%d%-]+%a?)"')
		assert_eq(core:match('var VERSION = "([%d%-]+%a?)"'), version, "web/glow_oidc.js VERSION must equal web/glow_auth.js VERSION")
		assert_true(has(slurp("web/auth_test.html"), '<script src="glow_oidc.js?v=' .. version .. '"></script>'), "the test page asks for the core with it too")
	end)
end)

describe("the ways of Google's sign-in in the game page (web/glow_auth.js, web/auth_config.js, web/engine_template.html)", function()
	local page = slurp("web/engine_template.html")
	local js = slurp("web/glow_auth.js")
	local cfg = slurp("web/auth_config.js")
	local version = js:match('var VERSION = "([%d%-]+%a?)"')
	local function key(name) return cfg:match(name .. ':%s*"([^"]*)"') end
	local WAYS = { firebase = true, shim = true, oidc_popup = true, oidc_redirect = true, no_window = true }

	it("loads the config, then the core, then the bridge, all three asking for the bridge's version", function()
		local a = page:find('src="auth_config.js?v=' .. version .. '"', 1, true)
		local o = page:find('src="glow_oidc.js?v=' .. version .. '"', 1, true)
		local g = page:find('src="glow_auth.js?v=' .. version .. '"', 1, true)
		assert_true(a and o and g, "all three tags carry ?v=" .. tostring(version))
		assert_true(a < o and o < g, "the core is loaded before the bridge that reads window.glowOidc")
	end)

	it("keeps the keys of the ways in the config: public identifiers, known ways, the Home Screen way only for the Home Screen app", function()
		assert_eq(key("googleClientId"), "956973883845-ct7e77188vteg5edv7m3sgp8j8iptd5r.apps.googleusercontent.com")
		assert_eq(key("googleReturn"), "https://shakhzodmir.github.io/game/auth_return.html")
		assert_true(WAYS[key("googleIos")] == true, "googleIos is one of the five ways: " .. tostring(key("googleIos")))
		assert_true(WAYS[key("googleIosHome")] == true, "googleIosHome is one of the five ways: " .. tostring(key("googleIosHome")))
		assert_true(key("googleIos") ~= "no_window", "a tab always has a window to use")
		local ret = slurp("web/auth_return.html")
		assert_true(ret ~= nil and key("googleReturn"):match("/auth_return%.html$") ~= nil, "the address names the return page that is shipped")
		for _, bad in ipairs({ "GOCSPX-", "client_secret", "private_key", "BEGIN PRIVATE KEY" }) do assert_false(has(cfg, bad), "the config holds only public identifiers (" .. bad .. ")") end
	end)

	it("names the same two addresses in the producer's console steps and in the handoff note", function()
		for _, path in ipairs({ "docs/handoff/google-signin-console-steps.md", "docs/handoff/google-signin-ios.md" }) do
			local doc = slurp(path)
			assert_true(has(doc, key("googleReturn")), path .. " names the return address")
			assert_true(has(doc, "https://shakhzodmir.github.io"), path .. " names the origin")
			assert_true(has(doc, "https://glow-dcd7e.firebaseapp.com/__/auth/handler"), path .. " says the old handler address stays")
		end
		assert_true(has(slurp("docs/handoff/google-signin-console-steps.md"), key("googleClientId"):sub(1, 17)), "and the client the steps open")
	end)

	it("has exactly the five ways, and the Firebase way is the same SDK call as before", function()
		assert_true(has(js, 'var FLOWS = ["firebase", "shim", "oidc_popup", "oidc_redirect", "no_window"];'))
		assert_true(has(js, "s.m.signInWithPopup(s.auth, new s.m.GoogleAuthProvider())"))
		assert_true(has(js, "s.m.linkWithPopup(u, new s.m.GoogleAuthProvider())"))
		assert_false(has(js, "signInWithRedirect") or has(js, "getRedirectResult"), "the SDK's redirect is not used (storage partitioning)")
	end)

	it("lets only an iPhone or iPad page read the keys and the saved choice: a desktop and an Android phone stay on the Firebase way", function()
		assert_true(has(js, 'if (!isIOS()) return "firebase";\n\t\treturn goodFlow(isStandalone() ? cfg.googleIosHome : cfg.googleIos) || "firebase";')
			or has(js, 'if (!isIOS()) return "firebase";\r\n\t\treturn goodFlow(isStandalone() ? cfg.googleIosHome : cfg.googleIos) || "firebase";'))
		assert_eq(select(2, js:gsub("cfg%.googleIos", "")), 2, "the two keys are read in that one place")
		assert_true(has(js, 'if (!isIOS()) return ""; // a saved choice never pins a desktop or an Android phone'))
		assert_true(has(js, "if (f && isIOS()) store(FLOW_KEY,"), "the address choice is kept only on an iPhone or iPad")
	end)

	it("opens the one window and navigates once, in the tap, with nothing asynchronous before it, in this order: save, arm, open, mark", function()
		local fn = js:match("function oidcStart%(.-\n\t// the whole operation")
		assert_true(fn ~= nil, "oidcStart")
		local open = fn:find("window.open(url", 1, true)
		local listen, ending = fn:find("var h = G.listen(", 1, true), fn:find("tr.onEnd(function (ok) {", 1, true)
		assert_true(open ~= nil and listen ~= nil and ending ~= nil and listen < ending and ending < open)
		-- (what runs inside the listener's callback runs later, when an answer comes)
		for _, part in ipairs({ fn:sub(1, listen), fn:sub(ending, open) }) do
			for _, bad in ipairs({ "await", ".then(", "setTimeout(", "Promise.resolve", "fetch(", "import(" }) do
				assert_false(has(part, bad), "nothing asynchronous before window.open (" .. bad .. ")")
			end
		end
		local save, arm, mark = fn:find("G.savePending(", 1, true), fn:find("G.listen(", 1, true), fn:find("G.markOwn(", 1, true)
		assert_true(save and arm and mark and save < arm and arm < open and open < mark, "save, arm, open, mark")
		assert_eq(select(2, js:gsub("window%.open%(url", "")), 1, "one window.open of ours")
		assert_eq(select(2, js:gsub("window%.location%.assign%(", "")), 1, "one navigation of ours")
		assert_false(has(js, "location.hash") or has(js, "atob(") or has(js, "console.log("), "the bridge parses no address and logs nothing")
	end)

	it("names no address but the SDK's own files, and no token ever reaches a note, a log or the wire format", function()
		local seen = {}
		for url in js:gmatch("https?://[^%s\"'<>)]+") do seen[#seen + 1] = url end
		assert_eq(#seen, 1, table.concat(seen, " "))
		assert_eq(seen[1], "https://www.gstatic.com/firebasejs/")
		assert_false(has(js, "idToken:") and has(js, "note(") and js:find("note%([^\n]*idToken") ~= nil, "no token in a note")
		assert_true(js:find("note%([^\n]*accessToken") == nil and js:find("note%([^\n]*rec%.r") == nil, "no token or raw nonce in a note")
	end)

	it("ends the SDK window with the try, never starts a credential after it, looks once more at the limit, and keeps restore inside the game's wait", function()
		assert_true(has(js, "get closed() { return gone; }") and not has(js, "get closed() { return false; }"), "the stand-in says closed once the try is over")
		assert_true(has(js, "if (gone) return null;"), "a try that ended before the SDK asked for its window gets none")
		assert_true(has(js, "return shimmed(open, tr);"), "the shim is given its try")
		assert_true(has(js, 'if (tr && tr.over) throw codeError("glow/oidc-late"'), "no credential is started after the try is over")
		assert_true(has(js, 'timed(open(cur), flow === "firebase" ? popupBound() : POPUP_MS, "glow/popup-timeout", function () { return !!(mine.last && mine.last()); })'), "the limit asks once more")
		assert_true(has(js, 'tr.last = function () { var was = tr.exchanging; h.poke("limit"); return !was && tr.exchanging; };'), "...by reading the mailbox now")
		assert_true(has(js, "GAME_WAIT_MS - (t0 - (callAt || t0))") and has(js, "OPS[op](s, args || [], t0)"), "restore's finish gets what is left of the game's 40 s")
	end)

	it("is covered by a node check that CI runs", function()
		local ci = slurp(".github/workflows/ci.yml")
		assert_true(has(ci, "node tools/qa/auth_flows_check.mjs"))
		assert_true(has(ci, "node tools/qa/auth_oidc_check.mjs"))
		assert_true(has(ci, "node tools/qa/auth_test_page_check.mjs"))
		local check = slurp("tools/qa/auth_flows_check.mjs")
		assert_true(has(check, 'from "./fake_world.mjs"'), "the check shares the fake browser")
		slurp("tools/qa/fake_world.mjs")
	end)
end)

describe("web/auth_test.html: the phone-side check of the sign-in with Google", function()
	local s = slurp("web/auth_test.html")

	it("uses its own Firebase app, so the player's real session is never touched, and signs out at once", function()
		assert_true(has(s, 'initializeApp(cfg, "diag")'))
		assert_true(has(s, "signOut(auth)"))
		assert_true(has(s, '<script src="auth_config.js"></script>'), "the public configuration comes from the same file as the game's")
	end)

	it("tests the pop-up inside the tap, the redirect and the plain window.open", function()
		assert_true(has(s, "signInWithPopup(auth, new m.GoogleAuthProvider())"))
		assert_true(has(s, "signInWithRedirect(auth, new m.GoogleAuthProvider())"))
		assert_true(has(s, "getRedirectResult(auth)"))
		assert_true(has(s, 'window.open("about:blank"'))
	end)

	it("has the experiments for the Home Screen app: a window that answers, the SDK told it is not standalone, a trip to another site", function()
		assert_true(has(s, 'window.open("auth_echo.html"'))
		assert_true(has(s, 'Object.defineProperty(navigator, "standalone"'), "test 5 masks navigator.standalone")
		assert_true(has(s, "delete navigator.standalone"), "and puts it back")
		assert_true(has(s, "?ret=1") and has(s, "https://tinyurl.com/2dk8w6jp"), "test 6 goes out and comes back")
		assert_false(has(s, "httpbin.org/redirect-to"), "httpbin answers 403 to redirects now")
		local e = slurp("web/auth_echo.html")
		assert_true(has(e, "window.opener.postMessage") and has(e, "BroadcastChannel") and has(e, "localStorage"))
		assert_false(has(e:lower(), "firebase"), "the echo window knows nothing about the sign-in")
	end)

	it("holds no keys, names or addresses, and masks the e-mail it shows", function()
		local low = s:lower()
		for _, bad in ipairs({ "@gmail", "aigpa", "c:\\", "c:/users", "aiza", "api_key", "secret" }) do
			assert_false(has(low, bad), "contains '" .. bad .. "'")
		end
		assert_true(has(s, "function mask("))
		assert_true(s:find("<script[^>]-src=\"https?:") == nil, "no external script tag: the SDK comes by import() from Google's CDN")
	end)

	it("is copied next to index.html by tools/build_web.sh", function()
		local b = slurp("tools/build_web.sh")
		assert_true(b:find('cp [^\n]*web/auth_test%.html[^\n]*"%$out/"') ~= nil)
	end)

	it("loads the shared core with the core's own version, so a phone never holds a stale copy of one half", function()
		local core = slurp("web/glow_oidc.js")
		local version = core:match('var VERSION = "([%d%-]+%a?)"')
		assert_true(version ~= nil, "VERSION in web/glow_oidc.js")
		assert_true(has(s, '<script src="glow_oidc.js?v=' .. version .. '"></script>'), "auth_test.html must ask for glow_oidc.js?v=" .. version)
		assert_true(has(s, '<script src="auth_config.js"></script>'))
	end)

	it("has the tests of rev 2: the probes, the Firebase pop-up with and without its 'closed' signal, our own sign-in in a window and by the whole page", function()
		for _, id in ipairs({ "b0a", "b0b", "b0c", "b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8", "b9" }) do
			assert_true(has(s, 'id="' .. id .. '"'), "button " .. id)
		end
		assert_true(has(s, 'new m.OAuthProvider("google.com").credential(') or has(s, 'OAuthProvider("google.com").credential'), "credential A")
		assert_true(has(s, "m.GoogleAuthProvider.credential(v.idToken)") and has(s, "m.GoogleAuthProvider.credential(null, v.accessToken)"), "credentials B and T")
		assert_true(has(s, "signInWithCredential(auth,"))
		assert_true(has(s, "glow_oidc_t_") and has(s, "auth_return.html"), "the test page names the return page and its own keys")
		assert_true(has(s, "RESULT T"), "every test ends with a RESULT line")
		assert_true(has(s, "function mask("), "the e-mail is masked")
		assert_true(has(s, "glow_diag_log_") and has(s, "glow_diag_boot"), "the log is kept per page load")
		assert_true(has(s, "function scrub("), "no token reaches the log")
		assert_true(has(s, "glow_google_flow") and has(s, "t10=1"), "test 10 only with ?t10=1")
		assert_true(has(s, '"back_cache"') and has(s, '"interrupted"') and has(s, '"aborted"') and has(s, '"no_answer"') and has(s, '"no_relay"'), "a test cannot end silently")
	end)

	it("opens Google's window as the first and only window.open of the tap, with every receiver armed before it and the marker written after it", function()
		local a = s:find('$("b8").addEventListener("click"', 1, true)
		local open = s:find("try { w = window.open(url, name); }", 1, true)
		local marker = s:find('G.markOwn("t", rec.s, {}); // right AFTER window.open', 1, true)
		assert_true(a and open and marker and a < open and open < marker)
		local before = s:sub(a, open)
		for _, bad in ipairs({ "await", ".then(", "setTimeout(", "Promise", "fetch(", "import(" }) do
			assert_false(has(before, bad), "nothing asynchronous before window.open in the tap (" .. bad .. ")")
		end
		assert_true(has(before, "G.savePending(") and has(before, "listenFor(f)"), "the attempt is saved and the receivers are armed before the window opens")
		assert_eq(select(2, s:sub(a, marker):gsub("window%.open%(", "")), 1, "one window.open in the tap")
	end)

	it("ages an attempt from the tap, leaves a copy of another window's attempt alone, exchanges one answer once, and says what the game would have done", function()
		assert_eq(select(2, s:gsub("rec%.t = Date%.now%(%);", "")), 2, "tests 8 and 9 restamp the attempt at the tap, as the game does")
		assert_true(has(s, "function notMine(pend)") and has(s, 'pend.src !== "ss" || G.isOwn("t", pend.rec.s, {})'), "only the window that started an attempt (its marker) finishes it")
		assert_eq(select(2, s:gsub("if %(notMine%(", "")), 2, "both ways in (an answer waiting, an attempt waiting) ask")
		assert_true(has(s, "function mayExchange(rec)") and has(s, "claimed_elsewhere"), "a page whose attempt another page claimed does not exchange it")
		assert_true(has(s, "function prodWould(res, ath)") and has(s, '["prod", prodWould(x.results, ath)]'), "the RESULT line says what the game's own credential policy would have done")
	end)

	it("never lets a token, a raw nonce or a code reach the log: the log text is scrubbed", function()
		local fn = s:match("function log%(text, cls%).-\n\t%}")
		assert_true(fn ~= nil and has(fn, "scrub(text)"), "log() scrubs")
		for _, v in ipairs({ "eyJ", "ya29", "id_token", "access_token" }) do assert_true(has(s:match("function scrub%(s%).-\n\t%}") or "", v), "scrub knows " .. v) end
	end)
end)

describe("web/glow_oidc.js: the shared core of our own sign-in with Google", function()
	local s = slurp("web/glow_oidc.js")

	it("is plain ES5-style script that loads by a script tag and by node, and touches nothing of the browser until called", function()
		assert_true(has(s, '(function () {\n\t"use strict";') or has(s, '(function () {\r\n\t"use strict";'))
		assert_true(has(s, 'if (typeof module === "object" && module && module.exports) module.exports = api;'))
		assert_true(has(s, 'window.glowOidc = api'))
		assert_false(s:find("\n[%a_$][%w_$.]*%.addEventListener", 1) ~= nil, "no listener is added at load time")
		assert_false(s:find("\nwindow%.", 1) ~= nil or s:find("\ndocument%.", 1) ~= nil or s:find("\nlocalStorage", 1) ~= nil, "no top-level browser access")
		assert_false(has(s, "=>") or has(s, "`") or has(s, "let ") or has(s, "const "), "ES5 style like web/glow_auth.js")
	end)

	it("knows nothing of Firebase: no SDK call, no address of its servers", function()
		for _, bad in ipairs({ "signInWith", "initializeApp", "getAuth", "gstatic", "firebaseapp", "identitytoolkit", "new m.", "m.signIn" }) do
			assert_false(has(s, bad), "web/glow_oidc.js must not contain " .. bad)
		end
	end)

	it("names only Google's own addresses", function()
		local seen = {}
		for url in s:gmatch("https?://[^%s\"'<>)]+") do seen[#seen + 1] = url end
		table.sort(seen)
		for _, url in ipairs(seen) do
			assert_true(url == "https://accounts.google.com" or url:find("^https://accounts%.google%.com/o/oauth2/v2/auth") ~= nil, "unexpected address " .. url)
		end
	end)

	it("never sends response_mode, include_granted_scopes or hd in its request, and no nonce with response_type=token", function()
		local fn = s:match("function authUrl%(p%).-\n\t%}")
		assert_true(fn ~= nil)
		for _, bad in ipairs({ "response_mode", "include_granted_scopes", "hd=" }) do assert_false(has(fn, bad), bad) end
		assert_true(has(fn, 'if (rt !== "token") parts.push("nonce="'))
	end)

	it("has the same storage keys as the return page", function()
		local page = slurp("web/auth_return.html")
		for _, key in ipairs({ "glow_oidc_t_pend", "glow_oidc_t_res:", "glow_oidc_t_ret", "glow_oidc_t_own", "glow_oidc_pend", "glow_oidc_res:", "glow_oidc_own", '"glow_oidc_t"', '"glow_oidc"' }) do
			assert_true(has(s, key), "core: " .. key)
			assert_true(has(page, key), "return page: " .. key)
		end
	end)

	it("is copied next to index.html by tools/build_web.sh, and the CI runs its node check", function()
		local b = slurp("tools/build_web.sh")
		assert_true(b:find('cp [^\n]*web/glow_oidc%.js[^\n]*"%$out/"') ~= nil)
		assert_true(has(slurp(".github/workflows/ci.yml"), "node tools/qa/auth_oidc_check.mjs"))
	end)
end)

describe("web/auth_return.html: the page Google sends the player back to", function()
	local s = slurp("web/auth_return.html")
	local script = s:match("<script>(.-)</script>")

	it("is frozen and logic-free: one inline script, a meta CSP that allows nothing from outside, no referrer, nothing external", function()
		assert_true(script ~= nil)
		assert_true(has(s, "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\">"))
		assert_true(has(s, '<meta name="referrer" content="no-referrer">'))
		assert_false(s:find("<script[^>]-src=") ~= nil, "no external script")
		for _, tag in ipairs({ "<link", "<img", "<iframe", "<form", "<object", "<embed", "<base" }) do assert_false(has(s:lower(), tag), "no " .. tag) end
		assert_false(has(script, "http://") or has(script, "https://"), "the script names no address")
		assert_false(has(s, "?v="), "the address is registered at Google exactly: no query, no version")
	end)

	it("knows nothing of Firebase and parses no token", function()
		assert_false(has(s:lower(), "firebase"), "no Firebase")
		for _, bad in ipairs({ "id_token", "access_token", "atob", "eval(", "Function(", "innerHTML", "document.write", "JSON.parse(hash" }) do
			assert_false(has(script, bad), "the return page must not contain " .. bad)
		end
	end)

	it("wipes the answer from the address before it sends anything, and sends only to its own origin", function()
		local wipe = script:find("history.replaceState(null", 1, true)
		local chan = script:find("new BroadcastChannel", 1, true)
		local post = script:find("postMessage(relay, location.origin)", 1, true)
		assert_true(wipe and chan and post and wipe < chan and wipe < post)
		assert_false(has(script, '"*"') or has(script, "'*'"), "never targetOrigin *")
	end)

	it("blanks itself when framed and does nothing without a state of ours", function()
		assert_true(has(script, "window.top !== window.self") and has(script, 'document.documentElement.textContent = ""'))
		assert_true(has(script, "/^([pr])([gt])\\.[A-Za-z0-9_-]{8,}$/"), "the state format")
		assert_true(has(script, "nostate"), "a breadcrumb of names and lengths when there is no state")
	end)

	it("goes back only to fixed pages, and only from the starter's own window, never next to a live starter", function()
		local replaces = select(2, script:gsub("location%.replace%(target%)", ""))
		assert_eq(replaces, 2, "two navigations, both to the fixed target")
		assert_false(has(script, "location.assign(") or has(script, "location.href"), "no other way to navigate")
		assert_true(has(script, 'var target = dest === "g" ? "./" : "auth_test.html";'), "the target is written out")
		assert_true(has(script, "var own = sget(ss, K.own) === state;"), "the marker of the starter's own window, written after window.open")
		assert_true(has(script, "if (!(own && homeOk)) return popupEnd();") and has(script, "if (!(own && homeOk)) return stay(false);"), "the guard before every navigation, in both modes")
		assert_true(has(script, "glow_oidc_ping") and has(script, "glow_oidc_pong") and has(script, "tmPong"), "a live starter answers a ping, and then nothing navigates")
		assert_true(has(script, "return pingThenLeave(function () {") and has(script, "pingThenLeave(function () { stay(true); });"), "both modes ask for a live starter's pong before they navigate")
		assert_false(has(script, "return leave();"), "leave() is called only after the wait for a pong")
		assert_eq(select(2, script:gsub("ret%.pong = 0; leave%(%);", "")), 1, "the one call of leave(): the pong wait ran out")
		local own = script:find("var own = ", 1, true)
		local leave = script:find("function leave()", 1, true)
		assert_true(own and leave and own < leave)
	end)

	it("keeps the answer in the shared storage only for an attempt that is still open: a pop-up's own copy of the record does not say so", function()
		assert_true(has(script, "if (live && ls) { ls.setItem(K.res + state"), "the mailbox is written only for a live attempt")
		assert_true(has(script, 'var live = mode === "p" ? pLS : known, stored = false;'), "a pop-up needs the beacon of the SHARED storage; a whole page its own record")
		assert_true(has(script, "known = pSS || pLS;"))
	end)

	it("does not say 'Done' where nothing was handed over, and says how to leave a window that will not close", function()
		assert_true(has(script, "say(stored ? okText : W.gone);"), "no 'Done' for a sign-in that is over")
		assert_true(has(script, 'say((stored || via ? closeText : W.gone) + " " + W.tab);'), "a window that stays says how to leave it")
		for _, lang in ipairs({ "ru", "ko", "en" }) do
			assert_true(s:match(lang .. ": {[^}]-gone:[^}]-tab:") ~= nil, lang .. " has the two texts")
		end
	end)

	it("speaks Russian, Korean or English by the device, and is copied next to index.html by tools/build_web.sh", function()
		assert_true(has(s, "Готово. Закройте это окно") and has(s, "완료되었습니다") and has(s, "Done. Close this window"))
		assert_true(s:find("[\234-\237][\128-\191][\128-\191]") ~= nil and s:find("\208[\144-\175]") ~= nil, "Hangul and Cyrillic")
		local b = slurp("tools/build_web.sh")
		assert_true(b:find('cp [^\n]*web/auth_return%.html[^\n]*"%$out/"') ~= nil)
	end)
end)
