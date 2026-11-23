-- The static pages of the site (WP-18): web/privacy.html and web/404.html, and that the build and the publishing
-- step carry them next to index.html; the preview of a link to the game (the og: and twitter: tags of
-- web/engine_template.html and the picture web/og.png). Run from the repository root.

local i18n = require("client.i18n")

local function slurp(path)
	local f = assert(io.open(path, "rb"), path .. " is missing")
	local s = f:read("*a")
	f:close()
	return s
end

local function has(s, needle) return s:find(needle, 1, true) ~= nil end

-- the content="" of every <meta property="key" ...> or <meta name="key" ...> of a page, in the order of the page
local function metas(page, key)
	local out = {}
	for tag in page:gmatch("<meta%s[^>]*>") do
		local k = tag:match('property="([^"]*)"') or tag:match('name="([^"]*)"')
		if k == key then out[#out + 1] = tag:match('content="([^"]*)"') end
	end
	return out
end

-- width and height of a PNG file from its header (the signature, then the IHDR chunk: 4 bytes of length, "IHDR", width, height)
local function png_size(bytes)
	assert_eq(bytes:sub(1, 8), "\137PNG\r\n\26\n", "a PNG file")
	assert_eq(bytes:sub(13, 16), "IHDR")
	local function u32(i)
		local a, b, c, d = bytes:byte(i, i + 3)
		return ((a * 256 + b) * 256 + c) * 256 + d
	end
	return u32(17), u32(21)
end

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

describe("web/engine_template.html: the preview of a link to the game", function()
	local page = slurp("web/engine_template.html")
	local function one(key)
		local v = metas(page, key)
		assert_eq(#v, 1, key .. ": exactly one tag")
		return v[1]
	end

	it("describes the game in one text, the same for the search result, the chat card and the feed card", function()
		local text = one("description")
		assert_true(#text >= 60 and #text <= 200, "a sentence or two (X cuts a description at 200 characters): " .. #text)
		assert_eq(one("og:description"), text)
		assert_eq(one("twitter:description"), text)
		assert_true(has(text, "Match three") and has(text, "concert"))
	end)

	it("is a website with the name of the game, at the address of the site, shown as a large card", function()
		assert_eq(one("og:type"), "website")
		assert_eq(one("og:title"), "GLOW: Encore Town")
		assert_eq(one("twitter:title"), one("og:title"))
		assert_eq(one("og:title"), slurp("web/manifest.webmanifest"):match('"name": "([^"]*)"'), "the name in the web app manifest")
		assert_eq(one("og:url"), "https://shakhzodmir.github.io/game/")
		assert_eq(one("twitter:card"), "summary_large_image")
	end)

	it("is in English and names Russian and Korean as the other languages", function()
		assert_eq(one("og:locale"), "en_US")
		local other = metas(page, "og:locale:alternate")
		table.sort(other)
		assert_eq(#other, 2)
		assert_eq(other[1], "ko_KR")
		assert_eq(other[2], "ru_RU")
	end)

	it("shows a picture at an absolute https address: a file in web/ that is 1200 x 630 and under 300 KB", function()
		local url = one("og:image")
		local name = url:match("^https://shakhzodmir%.github%.io/game/([%w_%-]+%.png)$")
		assert_true(name ~= nil, "og:image is an absolute https address of a .png next to index.html: " .. url)
		assert_eq(one("twitter:image"), url, "the same picture for X")
		local bytes = slurp("web/" .. name)
		local w, h = png_size(bytes)
		assert_eq(w, 1200, "width")
		assert_eq(h, 630, "height")
		assert_eq(one("og:image:width"), tostring(w), "the tag tells the real width")
		assert_eq(one("og:image:height"), tostring(h), "and the real height")
		-- WhatsApp shows no picture for a file over about 300 KB (a plain full-colour PNG of the logo card is 360 KB, tools/art/make_og_image.py brings it to 260)
		assert_true(#bytes <= 300 * 1000, "web/" .. name .. " is " .. #bytes .. " bytes")
	end)

	it("says in words what the picture shows, the same for X", function()
		local alt = one("og:image:alt")
		assert_true(#alt >= 20 and #alt <= 420, "a short description (X takes up to 420 characters)")
		assert_true(has(alt, "GLOW"))
		assert_eq(one("twitter:image:alt"), alt)
	end)

	it("holds no {{ }}: this page is a template of the build, which would take them for its own", function()
		for _, key in ipairs({ "description", "og:title", "og:description", "og:url", "og:image", "og:image:alt", "twitter:title", "twitter:description", "twitter:image", "twitter:image:alt" }) do
			assert_false(has(one(key), "{{"), key)
		end
	end)

	it("keeps the order of the head: the first four meta tags stay first, the preview comes after the rule that says so", function()
		local function at(needle)
			local i = page:find(needle, 1, true)
			assert_true(i ~= nil, needle .. " is missing")
			return i
		end
		local charset, compat, viewport, capable = at('<meta charset="utf-8">'), at('http-equiv="X-UA-Compatible"'), at('name="viewport"'), at('name="apple-mobile-web-app-capable"')
		assert_true(charset < compat and compat < viewport and viewport < capable, "the first four meta tags, in their order")
		local rule = at("*must* come first in the head")
		assert_true(capable < rule, "the rule comes after them")
		assert_true(rule < at('name="description"') and rule < at('property="og:type"') and rule < at('name="twitter:card"'), "the preview tags come after the rule")
		assert_true(at('name="twitter:image:alt"') < at("<title>"), "and before the title")
	end)

	it("keeps the app tags of the page: the colour of the bar, the icons, the manifest", function()
		for _, needle in ipairs({ 'name="theme-color"', 'name="apple-mobile-web-app-title"', 'name="apple-mobile-web-app-status-bar-style"',
				'rel="apple-touch-icon"', 'rel="icon"', 'rel="manifest"' }) do
			assert_true(has(page, needle), needle)
		end
	end)
end)

describe("the build and the publishing step carry the pages", function()
	it("tools/build_web.sh copies both pages next to index.html", function()
		local s = slurp("tools/build_web.sh")
		assert_true(has(s, "web/privacy.html") and has(s, "web/404.html"))
		assert_true(s:find('cp [^\n]*web/privacy%.html[^\n]*"%$out/"') ~= nil)
		assert_true(s:find('cp [^\n]*web/404%.html[^\n]*"%$out/"') ~= nil)
	end)

	it("tools/build_web.sh copies the picture of the link preview next to index.html, on the line of the app icons", function()
		local name = metas(slurp("web/engine_template.html"), "og:image")[1]:match("/([%w_%-]+%.png)$")
		assert_true(name ~= nil, "og:image names a .png")
		local line = slurp("tools/build_web.sh"):match('\n(cp [^\n]*web/' .. (name:gsub("%p", "%%%0")) .. '[^\n]*"%$out/")')
		assert_true(line ~= nil, 'a cp line that copies web/' .. name .. ' into "$out/"')
		assert_true(has(line, "web/icon-512.png") and has(line, "web/manifest.webmanifest"), "the same line as the app icons")
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
end)
