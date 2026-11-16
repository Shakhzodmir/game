-- The hay bale of the level board (core-rules 10.12; pure Lua).
--
-- A hay bale is a blocker with the hit rules of a record box (hp 2 -> 1 -> gone) that may hide a special
-- piece: "the needle in the haystack". When the bale is destroyed the core says `destroy` {id, x, y, item =
-- "hay"} like for any blocker; if something was inside, a `gift` event {id, x, y, special, axis, from} follows
-- once every effect on the board has ended: the special stands in the cell of the bale, idle and free. The
-- player cannot tell a full bale from an empty one (game:pieces() does not say what is inside), and neither
-- can this module. It holds the look:
--
--   pictures .. blockers/hay_2 (a full bale tied with two ropes) and blockers/hay_1 (a thinned, loose one):
--               the number is the hp LEFT, as for the record box (client/level_anim.lua picks the animation)
--   a hit ..... the wobble of every blocker (client/level_anim.lua), straw bits (client/level_effects.lua)
--               and the hit of the record box played soft and dull (client/level_audio.lua)
--   the end ... a bigger puff of straw and the break of the record box
--   the gift .. the special blooms in the cell exactly like one made by a match: it grows from nothing with a
--               white flash (client/level_anim.lua), a gold flash and sparkles (client/level_effects.lua) and
--               the sound of a new special (client/level_audio.lua)
--
--   local level_hay = require("client.level_hay")
--   level_hay.image(hp)   -- image key "blockers/hay_N"
--   level_hay.anim(hp)    -- animation id "blockers_hay_N"

local M = {}

M.ITEM = "hay"
M.MAX_HP = 2
M.GOAL_ICON = "blockers/hay_2"       -- the full bale: the icon of the `break` goal
M.COLOR = "#F2C04A"                  -- its straw: the bits of a hit
M.STRAW_FX = "debris"                -- the existing debris particles, in straw yellow
M.GIFT_COUNT = 5                     -- straw bits that fly when the gift pops out
-- a hit: the hit of the record box, soft and a little lower (a thud in the straw)
M.HIT_SFX, M.HIT_GAIN, M.HIT_SPEED = "box_hit", 0.55, 0.8
M.BREAK_SFX = "box_break"
-- the gift pops out: the sound of a special made by a match
M.GIFT_SFX = "special_create"

local function stage(hp)
	hp = math.floor(tonumber(hp) or 1)
	if hp < 1 then return 1 end
	if hp > M.MAX_HP then return M.MAX_HP end
	return hp
end

function M.image(hp)
	return "blockers/hay_" .. stage(hp)
end

function M.anim(hp)
	return "blockers_hay_" .. stage(hp)
end

return M
