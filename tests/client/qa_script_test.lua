-- tools/qa/web_screens.mjs drives a real debug build through the QA bridge (client/qa_bridge.lua). Nobody can
-- run it in the dev container, so this keeps it honest against the code it talks to: every command it sends
-- exists, with arguments the bridge understands; every field of the game state it reads is published by the
-- game; every button it taps is one the game reports (app.ui.targets, popup_targets, level.targets); every window of
-- its `open` loop opens with the JSON it sends (the whole session runs on tests/client/session_harness.lua).

local S = require("tests.client.session_harness")
local qa = require("client.qa_bridge")
local assets = require("client.assets")
local i18n = require("client.i18n")
local meta_qa = require("client.meta_qa")
local app_mod = require("client.app")
local refs = require("tools.check_refs")
local json = require("tools.lib.json")

local function read(path)
	local f = assert(io.open(path, "rb"))
	local s = f:read("*a")
	f:close()
	return s
end

local SCRIPT = read("tools/qa/web_screens.mjs")

-- every command text the script passes to command(page, '...')
local function commands()
	local out = {}
	for text in string.gmatch(SCRIPT, "command%(%s*[%w_]+%s*,%s*'([^']*)'") do out[#out + 1] = text end
	for text in string.gmatch(SCRIPT, 'command%(%s*[%w_]+%s*,%s*"([^"]*)"') do out[#out + 1] = text end
	return out
end

-- [popup, params, screenshot] rows of the loop that opens every window
local function window_rows()
	local out = {}
	for popup, params in string.gmatch(SCRIPT, "%[%s*'([%a_]+)'%s*,%s*'([^']*)'%s*,%s*'client_[%w_]+'%s*%]") do
		out[#out + 1] = { popup = popup, params = params }
	end
	return out
end

local function words(text)
	local out = {}
	for w in string.gmatch(text, "%S+") do out[#out + 1] = w end
	return out
end

-- the identifiers and strings of the runtime Lua (what the game can publish under that name)
local function published_names()
	local set = {}
	local p = io.popen("find client main screens gui -name '*.lua' -o -name '*.script' -o -name '*.gui_script' | sort")
	for path in p:lines() do
		for _, t in ipairs(refs._lex(read(path))) do
			if t.k == "name" or t.k == "str" then set[t.v] = true end
		end
	end
	p:close()
	return set
end

describe("tools/qa/web_screens.mjs", function()
	it("sends only commands the QA bridge has", function()
		S.run({}, function(s)
			local list = commands()
			assert_true(#list > 40, "the script sends " .. #list .. " commands")
			local seen = {}
			for _, text in ipairs(list) do
				local w = words(text)[1]
				assert_true(w ~= nil, "an empty command")
				seen[w] = true
				assert_true(qa.has(w), "the bridge has no command '" .. w .. "' (" .. text .. ")")
			end
			-- the script exercises the screens, the audio, the save, the board and the windows
			for _, must in ipairs({ "goto", "meta_win", "open", "close", "win", "skip", "give_up", "autoplay", "hold", "save_fail", "stall",
				"lang", "music", "reset_save", "set_coins", "toast_key", "modal" }) do
				assert_true(seen[must], "the script no longer uses '" .. must .. "'")
			end
			assert_false(qa.has("no_such_command"))
		end)
	end)

	it("sends arguments the commands understand", function()
		local colors = { red = true, orange = true, yellow = true, green = true, blue = true, purple = true }
		local screens = {}
		for _, name in ipairs(app_mod.SCREENS) do screens[name] = true end
		S.run({}, function(s)
			for _, text in ipairs(commands()) do
				local w = words(text)
				local name = table.remove(w, 1)
				local where = "'" .. text .. "'"
				if name == "goto" then
					assert_true(screens[w[1]], "goto " .. tostring(w[1]) .. " is not a screen: " .. where)
					if w[2] then assert_true(tonumber(w[2]) ~= nil, where) end
				elseif name == "level" or name == "set_coins" or name == "stall" or name == "meta_win" or name == "autoplay"
					or name == "advance" or name == "volume" then
					if w[1] and w[1] ~= "free" then assert_true(tonumber(w[1]) ~= nil, where) end
				elseif name == "lang" then
					assert_true(w[1] == "auto" or w[1] == "en" or w[1] == "ru", where)
				elseif name == "music" then
					assert_true(assets.index.sounds.music[w[1]] ~= nil, "no music for " .. tostring(w[1]) .. ": " .. where)
					assert_true(w[2] == nil or w[2] == "all", where)
				elseif name == "layer" then
					assert_true(w[1] == "tension" or w[1] == "party", where)
				elseif name == "sfx" then
					assert_true(assets.sfx_id(w[1]) ~= nil, "no sound effect " .. tostring(w[1]) .. ": " .. where)
				elseif name == "note" then
					assert_true(colors[w[1]], where)
				elseif name == "chord" then
					assert_true(tonumber(w[1]) ~= nil, where)
					for i = 2, #w do assert_true(colors[w[i]], where) end
				elseif name == "toast_key" then
					assert_true(i18n.has(w[1]), "no string " .. tostring(w[1]) .. ": " .. where)
				elseif name == "stray_fade" then
					assert_true(w[1] == "in" or w[1] == "out", where)
				elseif name == "save_fail" or name == "hold" then
					assert_true(w[1] == "0" or w[1] == "1", where)
				elseif name == "open" and w[1] then
					assert_true(meta_qa.POPUPS[w[1]], "open " .. tostring(w[1]) .. " is not a window: " .. where)
				end
			end
			-- the windows of the "open" loop, with their JSON
			local rows = window_rows()
			assert_true(#rows >= 9, "the loop opens " .. #rows .. " windows")
			local function strings_exist(v, where)
				if type(v) ~= "table" then return end
				if type(v.key) == "string" then assert_true(i18n.has(v.key), "no string " .. v.key .. ": " .. where) end
				for _, x in pairs(v) do strings_exist(x, where) end
			end
			for _, r in ipairs(rows) do
				assert_true(meta_qa.POPUPS[r.popup], "window " .. r.popup .. " is not in the registry of the town")
				if r.params ~= "" then
					local ok, v = pcall(json.decode, r.params)
					assert_true(ok and type(v) == "table", "bad JSON for " .. r.popup .. ": " .. r.params)
					strings_exist(v, r.popup .. " " .. r.params)
				end
			end
		end)
	end)

	it("reads only fields the game publishes", function()
		local known = published_names()
		local read_fields = {}
		-- .app.<field>, .app.audio.<field>, .app.overlay.<field>, .app.ui.<field>, lvl(s).<field>, .result.<field>
		for field in string.gmatch(SCRIPT, "%.app%.([%a_][%w_]*)") do read_fields[field] = "app" end
		for field in string.gmatch(SCRIPT, "%.app%.audio%.([%a_][%w_]*)") do read_fields[field] = "app.audio" end
		for field in string.gmatch(SCRIPT, "%.app%.overlay%.([%a_][%w_]*)") do read_fields[field] = "app.overlay" end
		for field in string.gmatch(SCRIPT, "%.app%.ui%.([%a_][%w_]*)") do read_fields[field] = "app.ui" end
		for field in string.gmatch(SCRIPT, "lvl%([%w_]+%)%.([%a_][%w_]*)") do read_fields[field] = "level" end
		for field in string.gmatch(SCRIPT, "%.result%.([%a_][%w_]*)") do read_fields[field] = "result" end
		local n = 0
		for field, where in pairs(read_fields) do
			n = n + 1
			assert_true(known[field], "the script reads " .. where .. "." .. field .. ", which no Lua source publishes")
		end
		assert_true(n >= 20, "the script reads " .. n .. " fields")
	end)

	it("taps only buttons the game reports", function()
		-- the names of tap targets in the sources: e:target("play", ...) / self:target("level", ...)
		local screen_targets, popup_targets = {}, {}
		local p = io.popen("find screens gui -name '*.lua' -o -name '*.gui_script' | sort")
		for path in p:lines() do
			local toks = refs._lex(read(path))
			for i = 1, #toks - 3 do
				if toks[i].k == "name" and toks[i].v == "target" and toks[i + 1].v == "(" and toks[i + 2].k == "str" then
					local into = string.find(path, "^gui/") and popup_targets or screen_targets
					into[toks[i + 2].v] = true
				elseif toks[i].k == "name" and toks[i].v == "target" and toks[i + 1].v == "(" and toks[i + 2].k == "name"
					and toks[i + 3].v == "," and toks[i + 4].k == "str" then
					-- town:target(...) / hud:target("name") with a receiver argument
					local into = string.find(path, "^gui/") and popup_targets or screen_targets
					into[toks[i + 4].v] = true
				end
			end
		end
		p:close()
		local level_targets = { pause = true, stick = true, row_light = true, col_light = true, remix = true }
		local n = 0
		for name, where in string.gmatch(SCRIPT, "tapTarget%([%w_]+,%s*'([%w_]+)'%s*,?%s*'?(%a*)'?%)") do
			n = n + 1
			if where == "popup" then
				assert_true(popup_targets[name], "no window reports a tap target '" .. name .. "'")
			elseif where == "level" then
				assert_true(level_targets[name], "the level screen reports no tap target '" .. name .. "'")
			else
				assert_true(screen_targets[name], "the town reports no tap target '" .. name .. "'")
			end
		end
		assert_true(n >= 8, "the script taps " .. n .. " targets")
	end)

	it("finds the level targets it taps in the state of a running level", function()
		S.run({}, function(s)
			s:wait_screen("splash")
			s:step_until(function() return s.app.screen == "level" and not s.app.transitioning end, 8, "level 1")
			s:step(30)
			local targets = s.app.ui.level and s.app.ui.level.targets
			assert_true(targets ~= nil, "the level screen publishes no tap targets")
			for _, name in ipairs({ "pause", "stick", "row_light", "col_light", "remix" }) do
				assert_true(targets[name] and targets[name].x and targets[name].y, "no level target " .. name)
			end
			-- and a tap there opens the pause window
			s:tap_target_at(targets.pause)
			s:step_until(function() return s.app.ui.popup == "pause" end, 3, "the pause window")
			assert_true(s.app.ui.popup_targets.leave ~= nil)
		end)
	end)

	it("opens every window of its loop through the bridge, as sent, and closes it again", function()
		local flow = require("client.flow")
		S.run({ setup = function(app) assert(flow.debug_win(3)) end }, function(s)
			s:step_until(function() return s.app.screen == "town" and not s.app.transitioning end, 8, "the town")
			s:run(3)
			for _, r in ipairs(window_rows()) do
				local res = s:qa("open " .. r.popup .. (r.params ~= "" and (" " .. r.params) or ""))
				assert_true(res.ok, "open " .. r.popup .. ": " .. tostring(res.error))
				s:step_until(function() return s.app.ui.popup == r.popup end, 3, "window " .. r.popup)
				s:run(1.2)
				assert_true(s.app.ui.popup_targets ~= nil, r.popup .. " has no tap targets")
				assert_true(s:qa("close").ok)
				s:step_until(function() return s.app.ui.popup == nil end, 3, "window " .. r.popup .. " to close")
			end
		end)
	end)
end)
