-- Level start flow shared by the start window, the splash (first launch) and
-- the QA bridge. Pure Lua except app.show_screen (Defold message).
--
--   local flow = require("client.flow")
--   local ok, why = flow.start(n, {"riff"}, "town")
--   -- ok: the meta attempt is open and the level screen is on its way with
--   --     app.params = {level_id, run, level_text, from}
--   -- why: "no_lives" | "run_active" | "not_next_level" | "all_done" |
--   --      "locked" | "not_enough_<booster>" (meta:start_level reasons)
--
-- The level screen contract (screens/level/level.gui_script, top comment;
-- client-architecture.md, section 4): params.run is the meta:start_level
-- result, params.level_text the raw level JSON (nil when the file is
-- missing: the meta still runs the attempt as "easy").

local app = require("client.app")
local levels = require("client.levels")
local config = require("meta.config")
local analytics = require("client.services.analytics")

local M = {}

local function valid_difficulty(d)
	for _, x in ipairs(config.difficulties) do
		if x == d then return true end
	end
	return false
end

-- {id, difficulty} for meta:start_level from the level file.
function M.level_ref(n)
	local info = levels.load(n)
	local diff = info and info.difficulty
	if not valid_difficulty(diff) then diff = "easy" end
	return { id = n, difficulty = diff }, info
end

-- Opens the attempt through the meta and asks for the level screen.
-- Returns true, nil, params or false, why.
function M.start(n, boosters, from)
	local ref, info = M.level_ref(n)
	local run, why = app.meta:start_level(ref, boosters or {}, app.now())
	app.commit("level_start")
	if not run then return false, why end
	analytics.log("level_start", {
		level = n, attempt = run.attempt, assist = run.assist, difficulty = run.difficulty,
		boosters = #run.boosters, streak = app.meta:streak().count, life_at_stake = run.life_at_stake,
	})
	for _, id in ipairs(run.paid_boosters or {}) do
		analytics.log("booster_use", { level = n, id = id, kind = "pre" })
	end
	local params = { level_id = n, run = run, level_text = info and info.text or nil, from = from }
	app.show_screen("level", params)
	return true, nil, params
end

-- Debug / QA: wins the next level through the meta's own start and finish
-- (no board). Returns the finish_level result or false, why.
function M.debug_win(moves_left)
	local n = app.meta:level_to_play()
	if not n then return false, "all_done" end
	local ref = M.level_ref(n)
	local run, why = app.meta:start_level(ref, {}, app.now())
	if not run then return false, why end
	app.meta:note_move()
	local res = app.meta:finish_level({ won = true, level_id = n, moves_at_win = moves_left or 3 }, app.now())
	app.commit("qa_win")
	return res
end

-- Debug / QA: loses the next level after a move (a life on level 21+).
function M.debug_lose()
	local n = app.meta:level_to_play()
	if not n then return false, "all_done" end
	local run, why = app.meta:start_level(M.level_ref(n), {}, app.now())
	if not run then return false, why end
	app.meta:note_move()
	local res = app.meta:finish_level({ won = false, level_id = n }, app.now())
	app.commit("qa_lose")
	return res
end

return M
