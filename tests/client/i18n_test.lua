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

	it("has every key in both languages with the same placeholders", function()
		for key, entry in pairs(i18n.STRINGS) do
			assert_true(entry.en ~= nil, key .. " has no en")
			assert_true(entry.ru ~= nil, key .. " has no ru")
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
		end
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
end)
