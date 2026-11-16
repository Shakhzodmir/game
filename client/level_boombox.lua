-- The boombox of the level board (core-rules 10.10; pure Lua).
--
-- A boombox is a blocker with the hit rules of a record box that answers back: every hp unit an ADJACENT MATCH
-- takes off it makes it "play" the colour of that match, and BLAST free pieces of that colour elsewhere on the
-- board are cleared (BLAST_LAST when the hit destroys it). The core tells a play with a `boombox` event
-- {x, y, id, color, cells = {{x, y}, ...}, last}; the clears follow as ordinary `clear` events (cause "effect").
-- This module holds the look:
--
--   pictures .. blockers/boombox_3 (new), _2 (cracked), _1 (broken): the number is the hp LEFT, as for the
--               record box (client/level_anim.lua picks the animation of a piece through M.anim)
--   a hit ..... the wobble of every blocker (client/level_anim.lua) and the hit sound of the record box
--   a play .... the boombox shakes (client/level_anim.lua), a ring in the colour of the match leaves it and a
--               "sound wave" (a ring and a flash of that colour, existing fx) pops on every blasted piece
--               (client/level_effects.lua); a low thump (client/level_audio.lua)
--
--   local level_boombox = require("client.level_boombox")
--   level_boombox.image(hp)   -- image key "blockers/boombox_N"
--   level_boombox.anim(hp)    -- animation id "blockers_boombox_N"

local M = {}

M.ITEM = "boombox"
M.MAX_HP = 3
M.GOAL_ICON = "blockers/boombox_3"   -- the new one: the icon of the `break` goal
M.COLOR = "#2FD6C3"                  -- its teal: the debris of a hit
M.WAVE_FX = "fx_ring"                -- the sound wave on a blasted piece
M.LAST_FX = "fx_shock"               -- the ring of the last play
M.WAVE_SIZE, M.WAVE_TIME = 1.7, 0.3  -- in cells; seconds
M.PLAY_SIZE, M.PLAY_TIME = 2.6, 0.35 -- the ring that leaves the boombox
M.LAST_SIZE = 3.4                    -- ... and the bigger one of its last play
M.HIT_SFX, M.BREAK_SFX = "box_hit", "box_break"
-- the play: the hit of the record box, low and slow (a thump of the speaker)
M.PLAY_SFX, M.PLAY_GAIN, M.PLAY_SPEED = "box_hit", 0.9, 0.6

local function stage(hp)
	hp = math.floor(tonumber(hp) or 1)
	if hp < 1 then return 1 end
	if hp > M.MAX_HP then return M.MAX_HP end
	return hp
end

function M.image(hp)
	return "blockers/boombox_" .. stage(hp)
end

function M.anim(hp)
	return "blockers_boombox_" .. stage(hp)
end

return M
