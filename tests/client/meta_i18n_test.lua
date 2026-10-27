-- The strings of the meta screens: one commented block of their own in client/i18n.lua, every key the
-- screens use exists in both languages, no visible text is typed into the code in one language, and
-- what the screens show differs between English and Russian.

local G = require("tests.client.meta_gui_helper")
local i18n = require("client.i18n")

local function read(path)
	local f = assert(io.open(path, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

local function list(cmd)
	local out = {}
	local p = io.popen(cmd)
	for line in p:lines() do out[#out + 1] = line end
	p:close()
	return out
end

-- namespaces whose strings belong to the meta screens
local META = { splash = true, town = true, nav = true, lives = true, start = true, shop = true, settings = true,
	jukebox = true, chest = true, gift = true, concert = true, district = true, reward = true, toast = true }

-- the files of the meta screens (gui/ also holds the level windows, which have their own owner)
local FILES = "gui/start.lua gui/shop.lua gui/settings.lua gui/lives.lua gui/jukebox.lua gui/concert.lua gui/chest.lua " ..
	"gui/gift.lua gui/confirm.lua gui/kit.lua screens/town/hud.lua screens/town/scene.lua screens/town/show.lua " ..
	"screens/town/steps.lua screens/town/town.gui_script screens/splash/splash.gui_script main/overlay.gui_script " ..
	"main/app.script client/views.lua client/popups.lua client/meta_qa.lua client/flow.lua client/app.lua"

describe("client/i18n.lua: the meta screens block", function()
	it("has every key once, and the meta strings together in their own commented block", function()
		local src = read("client/i18n.lua")
		local first, last = string.find(src, "META SCREENS:", 1, true), string.find(src, "end of META SCREENS", 1, true)
		assert_true(first ~= nil and last ~= nil and first < last, "the block is marked")
		local seen, dup = {}, {}
		for key in string.gmatch(src, '\n\t%["([^"]+)"%] =') do
			if seen[key] then dup[#dup + 1] = key end
			seen[key] = true
		end
		assert_same(dup, {}, "duplicate keys")
		-- a meta key outside the block would be edited in two places
		local outside = {}
		local pos = 1
		while true do
			local s, e, key = string.find(src, '\n\t%["([^"]+)"%] =', pos)
			if not s then break end
			local ns = string.match(key, "^([%w_]+)%.")
			if (META[ns] or key == "tutorial.town") and (s < first or s > last) then outside[#outside + 1] = key end
			pos = e + 1
		end
		assert_same(outside, {}, "meta keys outside the block")
	end)

	it("has every key the meta screens use, in both languages", function()
		local missing = {}
		for _, f in ipairs(list("ls " .. FILES)) do
			local src = read(f)
			-- {key = "x.y"}, i18n.t("x.y"), toast_key("x.y"), and keys kept in tables ("x.y")
			for key in string.gmatch(src, '"([%a_]+%.[%w_%.]+)"') do
				local ns = string.match(key, "^([%a_]+)%.")
				local known = META[ns] or ns == "common" or ns == "booster" or ns == "stem" or ns == "tutorial" or ns == "time" or ns == "win"
				if known and string.sub(key, -1) ~= "." and string.find(src, key, 1, true) and not string.find(key, "%.json$") then
					if not i18n.has(key) and not string.find(key, "^meta%.") and not string.find(key, "^app%.") then
						missing[#missing + 1] = f .. ": " .. key
					end
				end
			end
		end
		assert_same(missing, {})
	end)

	it("types no visible text into the code: every text literal of the meta screens is a symbol", function()
		local bad = {}
		for _, f in ipairs(list("ls " .. FILES)) do
			local n = 0
			for line in string.gmatch(read(f), "[^\n]+") do
				n = n + 1
				local code = string.gsub(line, "%-%-.*$", "") -- comments may say anything
				-- a string given as the text of a node / button / toast / label
				for _, pat in ipairs({ 'text%s*=%s*"([^"]*)"', ':text%([^,]+,%s*"([^"]*)"', 'badge%([^,]+,[^,]+,[^,]+,[^,]+,%s*"([^"]*)"',
					'toast%("([^"]*)"', 'caption%([^,]+,[^,]+,%s*"([^"]*)"' }) do
					for lit in string.gmatch(code, pat) do
						-- two or more letters in a row (Latin or Cyrillic) make it a word
						if string.find(lit, "%a%a") or string.find(lit, "[\208\209][\128-\191][\208\209]?[\128-\191]?") then
							bad[#bad + 1] = f .. ":" .. n .. ": '" .. lit .. "'"
						end
					end
				end
			end
		end
		assert_same(bad, {})
	end)

	it("shows different words in English and Russian on every screen and window", function()
		local function collect(lang, open)
			local set = {}
			G.with_town({ language = lang, setup = function(app) G.win(app, 13) end }, function(c)
				open(c)
				for _, t in ipairs(c.town:texts(true)) do set[t] = true end
				for _, t in ipairs(c.overlay:texts(true)) do set[t] = true end
			end)
			return set
		end
		local scenes = {
			function(c) end,
			function(c) c.app.open_popup("start"); c.run(0.6) end,
			function(c) c.app.open_popup("lives"); c.run(0.6) end,
			function(c) c.app.open_popup("shop", { tab = "boosters" }); c.run(0.6) end,
			function(c) c.app.open_popup("shop", { tab = "coins" }); c.run(0.6) end,
			function(c) c.app.open_popup("settings"); c.run(0.6) end,
			function(c) c.app.open_popup("jukebox"); c.run(0.6) end,
			function(c) c.app.open_popup("gift", { id = "riff" }); c.run(0.6) end,
			function(c) c.app.open_popup("chest", { kind = "level", level_id = 10, chest = { coins = 60, boosters = { "stick" } } }); c.run(0.6) end,
			function(c) c.app.toast_key("toast.coming_soon"); c.run(0.6) end,
		}
		-- words that read the same in both languages
		local SAME = { ["English"] = true, ["Русский"] = true, ["GLOW"] = true, ["Lo-fi"] = true }
		local same = {}
		for i, open in ipairs(scenes) do
			local en, ru = collect("en", open), collect("ru", open)
			for text in pairs(en) do -- order-free: a list of findings
				if ru[text] and string.find(text, "%a%a%a") and not SAME[text] then same[#same + 1] = i .. ": " .. text end
			end
		end
		table.sort(same)
		assert_same(same, {})
	end)
end)
