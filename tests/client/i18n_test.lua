local i18n = require("client.i18n")
local json = require("tools.lib.json")

local function placeholders(s)
	local set = {}
	for k in string.gmatch(s, "{([%w_]+)}") do set[k] = true end
	return set
end

local function values(v)
	if type(v) == "string" then return { v } end
	local out = {}
	for _, s in pairs(v) do out[#out + 1] = s end
	return out
end

describe("client.i18n", function()
	before_each(function() i18n.set_language("en") end)

	it("has every key in en, ru and ko with the same placeholders", function()
		assert_same(i18n.LANGUAGES, { "en", "ru", "ko" })
		for key, entry in pairs(i18n.STRINGS) do
			assert_true(entry.en ~= nil, key .. " has no en")
			assert_true(entry.ru ~= nil, key .. " has no ru")
			assert_true(entry.ko ~= nil, key .. " has no ko")
			local ref = placeholders(values(entry.en)[1])
			for _, lang in ipairs(i18n.LANGUAGES) do
				for _, s in ipairs(values(entry[lang])) do
					assert_same(placeholders(s), ref, key .. "/" .. lang .. " placeholders")
				end
			end
		end
	end)

	it("has complete plural tables", function()
		for key, entry in pairs(i18n.STRINGS) do
			if type(entry.en) == "table" then
				assert_true(entry.en.one and entry.en.other, key .. " en plural forms")
				assert_true(entry.ru.one and entry.ru.few and entry.ru.many, key .. " ru plural forms")
			else
				assert_eq(type(entry.ru), "string", key .. " ru must be a string like en")
			end
			assert_eq(type(entry.ko), "string", key .. " ko has one plural form: a plain string")
		end
	end)

	it("has no Korean key without an entry, and no empty or Latin-only Korean sentence by accident", function()
		local ko = require("client.i18n_ko")
		local n = 0
		for key, text in pairs(ko) do
			n = n + 1
			assert_true(i18n.STRINGS[key] ~= nil, key .. " is in i18n_ko.lua only")
			assert_true(#text > 0, key .. " is empty")
		end
		local total = 0
		for _ in pairs(i18n.STRINGS) do total = total + 1 end
		assert_eq(n, total)
	end)

	-- Korean cannot choose a particle for a variable: "트랙에 비트이(가) …" is what the player read on every task card
	it("writes no literal particle pair after a Korean placeholder", function()
		local ko = require("client.i18n_ko")
		local PAIRS = { "이(가)", "을(를)", "은(는)", "과(와)", "(으)로", "(이)라", "(이)나", "(이)랑", "아(야)" }
		local bad = {}
		for key, text in pairs(ko) do -- order-free: sorted below
			if string.find(text, "{", 1, true) then
				for _, pair in ipairs(PAIRS) do
					if string.find(text, pair, 1, true) then bad[#bad + 1] = key .. ": " .. pair end
				end
			end
		end
		table.sort(bad)
		assert_same(bad, {})
		-- the strings that had one now read cleanly with a real value in them
		i18n.set_language("ko")
		assert_eq(i18n.t("town.task_adds", { stem = i18n.t("stem.beat") }), "트랙에 추가: 리듬")
		assert_eq(i18n.t("town.back_to", { name = "재즈 바" }), "돌아가기: 재즈 바")
		assert_eq(i18n.t("start.selected", { name = "스틱" }), "가져가요: 스틱!")
		assert_eq(i18n.t("jukebox.locked", { name = "로파이 카페" }), "“로파이 카페” 구역을 복구하면 열려요")
		assert_eq(i18n.t("account.mail_sent", { email = "a@b.c" }), "메일을 보냈어요: a@b.c")
	end)

	-- Bit is the mascot (ru Бит, ko 비트); the first layer of five districts must not carry its name
	it("calls the first layer of a district by a name of its own, not the mascot's", function()
		local layer = { en = "Beat", ru = "Ударные", ko = "리듬" }
		local mascot = { ru = "Бит", ko = "비트" }
		local text = { ru = "Добавит в трек: Ударные", ko = "트랙에 추가: 리듬", en = "Adds Beat to the track" }
		for _, lang in ipairs(i18n.LANGUAGES) do
			i18n.set_language(lang)
			assert_eq(i18n.t("stem.beat"), layer[lang], lang)
			assert_eq(i18n.t("town.task_adds", { stem = i18n.t("stem.beat") }), text[lang], lang)
			assert_eq(i18n.t("town.layer_added", { stem = i18n.t("stem.beat") }), "+ " .. layer[lang] .. "!", lang)
			if mascot[lang] then
				assert_true(string.find(i18n.t("win.song_line"), mascot[lang], 1, true) ~= nil, lang .. ": the mascot keeps its name")
				assert_true(string.find(i18n.t("stem.beat"), mascot[lang], 1, true) == nil, lang .. ": the layer is not named like the mascot")
			end
		end
		-- the content id is not the name: the stem stays "beat" (saves, audio files and the tests know it by that id)
		local f = assert(io.open("content/districts.json", "r"))
		local data = json.decode(f:read("*a"))
		f:close()
		assert_eq(data.districts[1].id, "cafe")
		assert_eq(data.districts[1].tasks[1].stem, "beat")
	end)

	it("names districts, genres, songs and tasks in ko", function()
		local f = assert(io.open("content/districts.json", "r"))
		local data = json.decode(f:read("*a"))
		f:close()
		for _, d in ipairs(data.districts) do
			assert_true(d.name.ko and d.genre.ko, d.id)
			for _, song in ipairs(d.songs) do assert_true(song.name.ko, song.id) end
			for _, t in ipairs(d.tasks) do assert_true(t.name.ko, t.id) end
		end
	end)

	it("picks Korean from the system language and keeps the explicit choice", function()
		assert_eq(i18n.detect("ko"), "ko")
		assert_eq(i18n.detect("ko-KR"), "ko")
		assert_eq(i18n.detect("de"), "en")
		assert_eq(i18n.set_language("auto", "ko-KR"), "ko")
		assert_eq(i18n.set_language("ru", "ko-KR"), "ru")
		assert_eq(i18n.set_language("ko", "en"), "ko")
		assert_eq(i18n.t("common.coins", { n = 5 }), "코인 5개")
		assert_eq(i18n.number(1050, "ko"), "1,050")
	end)

	it("names every stem and booster of the content", function()
		local f = assert(io.open("content/districts.json", "r"))
		local data = json.decode(f:read("*a"))
		f:close()
		for _, d in ipairs(data.districts) do
			for _, t in ipairs(d.tasks) do
				assert_true(i18n.has("stem." .. t.stem), "missing stem." .. t.stem)
			end
		end
		for _, id in ipairs({ "stick", "row_light", "col_light", "remix", "riff", "sub", "disco" }) do
			assert_true(i18n.has("booster." .. id), id)
			assert_true(i18n.has("booster." .. id .. "_desc"), id .. "_desc")
		end
	end)

	it("detects the language with an English fallback", function()
		assert_eq(i18n.detect("ru"), "ru")
		assert_eq(i18n.detect("ru-RU"), "ru")
		assert_eq(i18n.detect("RU_ru"), "ru")
		assert_eq(i18n.detect("en-GB"), "en")
		assert_eq(i18n.detect("de"), "en")
		assert_eq(i18n.detect(nil), "en")
		assert_eq(i18n.set_language("auto", "ru"), "ru")
		assert_eq(i18n.set_language("en", "ru"), "en")
		assert_eq(i18n.set_language("ru", "en"), "ru")
		assert_eq(i18n.set_language("xx", "ru"), "ru")
		assert_eq(i18n.language(), "ru")
	end)

	it("translates and formats", function()
		assert_eq(i18n.t("town.level", { n = 12 }), "Level 12")
		i18n.set_language("ru")
		assert_eq(i18n.t("town.level", { n = 12 }), "Уровень 12")
		assert_eq(i18n.t("no.such.key"), "no.such.key")
		assert_eq(i18n.format("{a}+{b}={c}", { a = 1, b = 2 }), "1+2={c}")
	end)

	it("names the songbook tab of the navigation in the words of the window it opens", function()
		i18n.set_language("en")
		assert_eq(i18n.t("nav.notebook"), "Songbook")
		assert_eq(i18n.t("nav.notebook"), i18n.t("notebook.title"))
		i18n.set_language("ru")
		assert_eq(i18n.t("nav.notebook"), "Блокнот")
		i18n.set_language("ko")
		assert_eq(i18n.t("nav.notebook"), i18n.t("notebook.title"))
	end)

	it("picks plural forms", function()
		i18n.set_language("ru")
		assert_eq(i18n.t("common.stars", { n = 1 }), "1 звезда")
		assert_eq(i18n.t("common.stars", { n = 3 }), "3 звезды")
		assert_eq(i18n.t("common.stars", { n = 5 }), "5 звёзд")
		assert_eq(i18n.t("common.stars", { n = 11 }), "11 звёзд")
		assert_eq(i18n.t("common.stars", { n = 21 }), "21 звезда")
		assert_eq(i18n.t("common.stars", { n = 104 }), "104 звезды")
		assert_eq(i18n.t("continue.offer", { n = 5 }), "+5 ходов")
		assert_eq(i18n.t("continue.offer", { n = 3 }), "+3 хода")
		i18n.set_language("en")
		assert_eq(i18n.t("common.stars", { n = 1 }), "1 star")
		assert_eq(i18n.t("common.stars", { n = 0 }), "0 stars")
	end)

	it("counts the packs the shop shelf leaves out with the plural forms of each language", function()
		i18n.set_language("ru")
		assert_eq(i18n.t("shop.more_later", { n = 1 }), "Ещё 1 откроется позже")
		assert_eq(i18n.t("shop.more_later", { n = 2 }), "Ещё 2 откроются позже")
		assert_eq(i18n.t("shop.more_later", { n = 4 }), "Ещё 4 откроются позже")
		assert_eq(i18n.t("shop.more_later", { n = 7 }), "Ещё 7 откроются позже")
		assert_eq(i18n.t("shop.more_later", { n = 21 }), "Ещё 21 откроется позже")
		i18n.set_language("en")
		assert_eq(i18n.t("shop.more_later", { n = 1 }), "1 more will unlock later")
		assert_eq(i18n.t("shop.more_later", { n = 7 }), "7 more will unlock later")
		i18n.set_language("ko")
		assert_eq(i18n.t("shop.more_later", { n = 1 }), "나중에 1개 더 열려요")
		assert_eq(i18n.t("shop.more_later", { n = 7 }), "나중에 7개 더 열려요")
	end)

	-- the line of the results window about the next town task (gui/result.lua, lw.town_line): the stars it still needs, in the
	-- plural form of each language, or that it can be bought; {item} is the name the task card of the town shows
	it("tells how many stars the next town task needs with the plural forms of each language, and the name in quotes", function()
		i18n.set_language("ru")
		assert_eq(i18n.t("win.town_need", { n = 1, item = "Пианино" }), "Ещё 1 звезда до «Пианино»")
		assert_eq(i18n.t("win.town_need", { n = 2, item = "Пианино" }), "Ещё 2 звезды до «Пианино»")
		assert_eq(i18n.t("win.town_need", { n = 4, item = "Пианино" }), "Ещё 4 звезды до «Пианино»")
		assert_eq(i18n.t("win.town_need", { n = 5, item = "Пианино" }), "Ещё 5 звёзд до «Пианино»")
		assert_eq(i18n.t("win.town_need", { n = 7, item = "Пианино" }), "Ещё 7 звёзд до «Пианино»")
		assert_eq(i18n.t("win.town_ready", { item = "Пианино" }), "Можно купить «Пианино»")
		i18n.set_language("en")
		assert_eq(i18n.t("win.town_need", { n = 1, item = "Piano" }), "1 more star to “Piano”")
		assert_eq(i18n.t("win.town_need", { n = 2, item = "Piano" }), "2 more stars to “Piano”")
		assert_eq(i18n.t("win.town_need", { n = 7, item = "Piano" }), "7 more stars to “Piano”")
		assert_eq(i18n.t("win.town_ready", { item = "Piano" }), "You can buy “Piano”")
		i18n.set_language("ko")
		assert_eq(i18n.t("win.town_need", { n = 1, item = "피아노" }), "“피아노”까지 별 1개 남았어요")
		assert_eq(i18n.t("win.town_need", { n = 7, item = "피아노" }), "“피아노”까지 별 7개 남았어요")
		assert_eq(i18n.t("win.town_ready", { item = "피아노" }), "“피아노” 살 수 있어요")
	end)

	-- one line of 26 px shrunk to the room of its row (the Lua side draws one line per label): the longest name of the game
	-- with the biggest number must stay readable, and still above 18 px in a window that shrank by a tenth
	it("keeps the town line readable for every task name of the game, in every language, with every number the town can ask", function()
		local A = require("tests.client.layout_audit")
		local advances = require("tests.client.font_advances")
		local f = assert(io.open("content/districts.json", "r"))
		local data = json.decode(f:read("*a"))
		f:close()
		local SIZE, ROOM = 26, 468 -- the size of the text and the room it has in its row (gui/level_kit.lua note: 560 - 56 - 36)
		local function fitted(font, text)
			local _, w = A.wrap(font, text, 1e9) -- one line: its width at the size the font is baked at
			local px = w * SIZE / advances[font].size
			return px > ROOM and SIZE * ROOM / px or SIZE
		end
		local worst, worst_what, names = 1e9, nil, 0
		for _, lang in ipairs(i18n.LANGUAGES) do
			i18n.set_language(lang)
			local font = lang == "ko" and "button_ko" or "button"
			for _, d in ipairs(data.districts) do
				for _, t in ipairs(d.tasks) do
					names = names + 1
					local name = i18n.name(t.name)
					local texts = { i18n.t("win.town_ready", { item = name }) }
					for n = 1, 7 do texts[#texts + 1] = i18n.t("win.town_need", { n = n, item = name }) end
					for _, text in ipairs(texts) do
						local px = fitted(font, text)
						if px < worst then worst, worst_what = px, lang .. ": " .. text end
					end
				end
			end
		end
		assert_true(names >= 3 * 98, "every task name of the game was measured (" .. names .. ")")
		assert_true(worst * 0.9 >= 18, "the line shrinks to " .. string.format("%.1f", worst) .. " px (" .. tostring(worst_what) .. ")")
	end)

	it("formats numbers and durations", function()
		assert_eq(i18n.number(0), "0")
		assert_eq(i18n.number(999), "999")
		assert_eq(i18n.number(1050), "1,050")
		assert_eq(i18n.number(1234567), "1,234,567")
		assert_eq(i18n.number(-4200), "-4,200")
		assert_eq(i18n.number(1050, "ru"), "1\194\160050")
		assert_eq(i18n.duration(0), "0:00")
		assert_eq(i18n.duration(65), "1:05")
		assert_eq(i18n.duration(1199.2), "20:00")
		assert_eq(i18n.duration(3725), "1:02:05")
		assert_eq(i18n.duration_words(45 * 60), "45 min")
		assert_eq(i18n.duration_words(80 * 60), "1 h 20 min")
		i18n.set_language("ru")
		assert_eq(i18n.duration_words(80 * 60), "1 ч 20 мин")
	end)

	it("names content tables by language", function()
		local n = { en = "Jazz Bar", ru = "Джаз-бар" }
		assert_eq(i18n.name(n), "Jazz Bar")
		i18n.set_language("ru")
		assert_eq(i18n.name(n), "Джаз-бар")
		assert_eq(i18n.name({ en = "Only" }), "Only")
	end)

	it("lists the characters the fonts must contain", function()
		local chars = i18n.charset()
		local set = {}
		for _, c in ipairs(chars) do set[c] = true end
		assert_true(set["Ё"] or set["ё"], "has yo")
		assert_true(set["«"] and set["—"] and set["…"], "has typographic punctuation")
		assert_true(#chars > 100)
	end)

	it("resolves text specs when they are shown", function()
		i18n.set_language("en")
		assert_eq(i18n.tr("plain"), "plain")
		assert_eq(i18n.tr({ text = "plain" }), "plain")
		assert_eq(i18n.tr({ key = "town.level", vars = { n = 4 } }), "Level 4")
		assert_eq(i18n.tr({ key = "town.new_district", vars = { name = { en = "Jazz Bar", ru = "Джаз-бар" } } }),
			"New district: Jazz Bar")
		assert_eq(i18n.tr({ key = "splash.gift", vars = { name = { key = "booster.stick" } } }), "Gift: Drumstick boosters!")
		i18n.set_language("ru")
		assert_eq(i18n.tr({ key = "town.new_district", vars = { name = { en = "Jazz Bar", ru = "Джаз-бар" } } }),
			"Открыт новый район: Джаз-бар")
		assert_eq(i18n.tr(nil), "")
		local lives = { lines = { { key = "lives.infinite", vars = { time = i18n.duration_words_spec(4800) } },
			{ key = "lives.free_levels", vars = { n = 20 } } } }
		assert_eq(i18n.tr(lives), "Бесконечные жизни: 1 ч 20 мин\nУровни 1–20 не тратят жизни")
		i18n.set_language("en")
		assert_eq(i18n.tr(lives), "Unlimited lives: 1 h 20 min\nLevels 1–20 don't cost lives")
	end)

	it("has a description and a tutorial line for every blocker", function()
		for _, id in ipairs({ "record_box", "dancefloor", "wires", "mic", "concrete", "noise", "balloon", "column", "coconut", "chain", "curtain", "carpet", "conveyor", "boombox", "ice", "hay", "fog", "portal" }) do
			assert_true(i18n.has("blocker." .. id), id)
			assert_true(i18n.has("blocker." .. id .. "_desc"), id .. "_desc")
			assert_true(i18n.has("tutorial." .. id), "tutorial." .. id)
		end
	end)

	it("has every literal key the client code uses", function()
		local p = io.popen("find client main screens -name '*.lua' -o -name '*.script' -o -name '*.gui_script' | sort")
		local files = {}
		for line in p:lines() do files[#files + 1] = line end
		p:close()
		assert_true(#files > 5, "found the client sources")
		local missing, seen = {}, 0
		local patterns = {
			'i18n%.t%(%s*"([%w_%.]+)"', 'i18n%.t%(%s*\'([%w_%.]+)\'', 'toast_key%(%s*"([%w_%.]+)"',
			'[%s{,]key%s*=%s*"([%w_]+%.[%w_%.]+)"',
		}
		for _, f in ipairs(files) do
			local fh = assert(io.open(f, "r"))
			local src = fh:read("*a")
			fh:close()
			for _, pat in ipairs(patterns) do
				for key in string.gmatch(src, pat) do
					seen = seen + 1
					-- "stem." .. id is built at run time: only whole keys are checked
					if string.sub(key, -1) ~= "." and not i18n.has(key) then missing[#missing + 1] = f .. ": " .. key end
				end
			end
		end
		assert_true(seen > 20, "found the keys")
		assert_same(missing, {})
	end)

	-- the stars come from the score (WP-4), not from the difficulty of the level: the note of the results window says so
	it("the stars note of the results window speaks of the score in every language", function()
		local words = { en = "score", ru = "очк", ko = "점수" }
		local old_rule = { en = "difficulty", ru = "сложност", ko = "난이도" }
		for _, lang in ipairs(i18n.LANGUAGES) do
			i18n.set_language(lang)
			local text = i18n.t("win.stars_note")
			assert_true(string.find(string.lower(text), words[lang], 1, true) ~= nil, lang .. ": " .. text)
			assert_true(string.find(string.lower(text), old_rule[lang], 1, true) == nil, lang .. " still states the old rule: " .. text)
		end
	end)

end)
