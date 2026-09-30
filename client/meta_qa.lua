-- QA bridge commands of the meta screens (debug builds only: the bridge
-- itself runs only there, client/qa_bridge.lua). Registered once by
-- main/app.script (require("client.meta_qa").register()).
--
--   reward <json>          queue a level result for the town (app.push_reward),
--                          e.g. reward {"won":true,"stars":2,"coins":60,"streak":1,
--                          "chest":{"coins":60,"boosters":["stick"],"infinite_minutes":15},
--                          "unlocked":["riff"]}
--   add_stars <n>          debug stars (the meta only pays stars for wins)
--   complete_task          the next district task: on the town through its card
--                          (the full animation), elsewhere straight in the meta
--   open <popup> [json]    a meta popup of the town: start, lives, shop, settings,
--                          jukebox, concert, chest, gift, confirm (json = params)
--   close                  closes the top popup
--   town_skip              skips the running town animation (task, rewards)
--   advance <n>            wins levels through the meta until level n is next
--   meta_lose              loses the next level (a life from level 21 on)
--   meta_ui                the town / popup status (app.ui) with tap targets
-- Pure Lua apart from what app.show_screen / the bus do; tests pass a JSON
-- decoder (M.decode) and drive M.handlers() directly.

local app = require("client.app")
local bus = require("client.bus")
local flow = require("client.flow")
local qa_bridge = require("client.qa_bridge")

local M = {}

M.decode = nil -- test hook: fn(text) -> table

local function decode(text)
	local fn = M.decode or (json and json.decode)
	if not fn then return nil, "no json decoder" end
	local ok, v = pcall(fn, text)
	if not ok then return nil, tostring(v) end
	return v
end

-- Everything after the first word of the command (a JSON argument keeps
-- its spaces).
local function rest(cmd, skip_words)
	local s = cmd or ""
	for _ = 1, skip_words or 1 do
		s = string.gsub(s, "^%s*%S+", "", 1)
	end
	return (string.gsub(s, "^%s+", ""))
end

local function town_on_display()
	return app.screen == "town" and not app.transitioning
end

function M.handlers()
	return {
		reward = function(_, cmd)
			local text = rest(cmd, 1)
			local r, err = decode(text ~= "" and text or "{}")
			if type(r) ~= "table" then return { ok = false, error = "reward needs a JSON object: " .. tostring(err) } end
			local n = app.push_reward(r)
			return { ok = n ~= nil, queued = n }
		end,
		add_stars = function(args)
			local n = math.floor(tonumber(args[1]) or 0)
			if n <= 0 then return { ok = false, error = "add_stars needs a positive number" } end
			-- a QA cheat outside the rules: the meta only pays stars for wins
			local ok, why = app.meta:_change("debug_qa", { { "stars", n } })
			app.meta:_touch()
			app.commit("qa_stars")
			return { ok = ok ~= false, error = why, stars = app.meta:stars() }
		end,
		complete_task = function()
			local t = app.meta:next_task()
			if not t then return { ok = false, error = "town_complete" } end
			if not t.affordable then return { ok = false, error = "not_enough_stars", need = t.cost - app.meta:stars() } end
			if town_on_display() then
				bus.publish("meta_qa", { action = "task" })
				return { ok = true, task = t.id, via = "town" }
			end
			local res, why = app.meta:complete_task(t.district, t.id)
			app.commit("qa_task")
			return { ok = res ~= false, error = why, task = t.id, via = "meta" }
		end,
		open = function(args, cmd)
			local name = args[1]
			if not name then return { ok = false, error = "open needs a popup name" } end
			if not town_on_display() then return { ok = false, error = "the town is not on display" } end
			local params
			local text = rest(cmd, 2)
			if text ~= "" then
				local p, err = decode(text)
				if type(p) ~= "table" then return { ok = false, error = "bad params: " .. tostring(err) } end
				params = p
			end
			app.open_popup(name, params)
			return { ok = true, popup = name }
		end,
		close = function()
			app.close_popup()
			return { ok = true }
		end,
		town_skip = function()
			bus.publish("meta_qa", { action = "skip" })
			return { ok = true }
		end,
		advance = function(args)
			local target = math.floor(tonumber(args[1]) or 0)
			local wins = 0
			while app.meta:level_to_play() and app.meta:level_to_play() < target and wins < 200 do
				local res, why = flow.debug_win(3)
				if not res then return { ok = false, error = why, wins = wins } end
				wins = wins + 1
			end
			return { ok = true, wins = wins, level = app.meta:level_to_play(), stars = app.meta:stars() }
		end,
		meta_lose = function()
			local res, why = flow.debug_lose()
			if not res then return { ok = false, error = why } end
			return { ok = true, life_lost = res.life_lost, lives = app.meta:lives(app.now()).count }
		end,
		meta_ui = function()
			return { ok = true, ui = app.ui }
		end,
	}
end

local off
-- Adds the commands to the QA bridge (once).
function M.register()
	if off then return off end
	off = qa_bridge.register(M.handlers())
	return off
end

return M
