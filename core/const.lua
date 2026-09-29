-- Numeric ids, enumerations, timings and scores of the GLOW core.
--
-- Every code here is the one the hash uses (core-rules.md 17.2). The logic
-- compares numbers only; strings appear only at the API boundary (level
-- files, commands, events, queries), converted through the *_NAME tables.

local C = {}

C.CORE_VERSION = "3.1.0"

C.UNIT = 3600 -- units per cell (section 0)

-- Colours in global order (section 0): ties are broken towards the smaller code.
C.COLOR_NAME = { "red", "orange", "yellow", "green", "blue", "purple" }
C.COLOR = {}
for code, name in ipairs(C.COLOR_NAME) do C.COLOR[name] = code end
C.NCOLORS = 6

-- Content of a slot.
C.K_NONE, C.K_REGULAR, C.K_SPECIAL, C.K_MIC, C.K_BLOCKER = 0, 1, 2, 3, 4
C.KIND_NAME = { "regular", "special", "mic", "blocker" }

-- Specials.
C.SP_RIFF, C.SP_SUB, C.SP_BIRD, C.SP_DISCO = 1, 2, 3, 4
C.SPECIAL_NAME = { "riff", "sub", "bird", "disco" }
C.SPECIAL = { riff = 1, sub = 2, bird = 3, disco = 4 }

-- Riff axis.
C.AX_H, C.AX_V = 1, 2
C.AXIS_NAME = { "h", "v" }
C.AXIS = { h = 1, v = 2 }

-- Blockers.
C.BK_BOX, C.BK_CONCRETE, C.BK_NOISE, C.BK_BALLOON, C.BK_COLUMN = 1, 2, 3, 4, 5
C.BLOCKER_NAME = { "record_box", "concrete", "noise", "balloon", "column" }
C.BLOCKER = { record_box = 1, concrete = 2, noise = 3, balloon = 4, column = 5 }

-- Object states.
C.S_IDLE, C.S_FALL, C.S_SWAP, C.S_CLEAR, C.S_ARMED = 1, 2, 3, 4, 5
C.STATE_NAME = { "idle", "fall", "swap", "clear", "armed" }

-- Timers.
C.TM_NONE, C.TM_SWAP, C.TM_FAIL, C.TM_BACK, C.TM_LOCK, C.TM_CLEAR = 0, 1, 2, 3, 4, 5

-- Source kinds.
C.SRC_MATCH, C.SRC_ADJ, C.SRC_EFFECT = 1, 2, 3

-- Items: in-level boosters and entries of `unplaced`.
C.IT_STICK, C.IT_ROW, C.IT_COL, C.IT_REMIX = 1, 2, 3, 4
C.IT_PRE_RIFF, C.IT_PRE_SUB, C.IT_PRE_DISCO, C.IT_CONT_RIFF = 5, 6, 7, 8
C.BOOSTER = { stick = 1, row_light = 2, col_light = 3, remix = 4 }
C.BOOSTER_NAME = { "stick", "row_light", "col_light", "remix" }
-- Pre-level boosters: name -> item code.
C.PRE_BOOSTER = { riff = 5, sub = 6, disco = 7 }
C.PRE_BOOSTER_NAME = { [5] = "riff", [6] = "sub", [7] = "disco" }

-- Game states.
C.G_PLAYING, C.G_WON_WAIT, C.G_CONCERT, C.G_OUT, C.G_LOST, C.G_COMPLETE = 1, 2, 3, 4, 5, 6
C.GAME_NAME = { "playing", "won_wait", "concert", "out_of_moves", "lost", "complete" }

-- Timing modes.
C.TIMING_NORMAL, C.TIMING_TURBO = 1, 2
C.TIMING = { normal = 1, turbo = 2 }
C.TIMING_NAME = { "normal", "turbo" }

-- Queue record kinds (15.2) and the number of data fields each one carries.
C.R_ACTIVATE, C.R_HIT, C.R_DISCO, C.R_TRANSFORM = 1, 2, 3, 4
C.R_BIRD, C.R_CONCERT_A, C.R_CONCERT_B, C.R_BOOSTER = 5, 6, 7, 8
C.RECORD_FIELDS = { 6, 2, 3, 3, 4, 1, 0, 4 }

-- Goals.
C.GOAL_COLLECT, C.GOAL_BREAK, C.GOAL_LIGHT, C.GOAL_DELIVER = 1, 2, 3, 4
C.GOAL = { collect = 1, ["break"] = 2, light = 3, deliver = 4 }
C.GOAL_NAME = { "collect", "break", "light", "deliver" }

C.DIFFICULTY = { easy = 1, medium = 2, hard = 3, super_hard = 4 }
C.DIFFICULTY_NAME = { "easy", "medium", "hard", "super_hard" }
C.STARS = { 1, 1, 2, 3 }

-- Timings (section 14), indexed by timing mode.
C.T = {
	{ -- normal
		swap = 10, swap_fail = 14, shuffle = 30, clear = 9, chain = 3,
		sub_swell = 6, ring = 2, bird_flight = 33, disco_step = 2,
		transform_step = 2, fire_step = 3, finale_pause = 24, light_step = 1,
		concert_step = 2, fall_v0 = 300, fall_acc = 60, fall_vmax = 1080,
		start_delay = 1,
	},
	{ -- turbo
		swap = 1, swap_fail = 1, shuffle = 1, clear = 1, chain = 0,
		sub_swell = 0, ring = 0, bird_flight = 0, disco_step = 0,
		transform_step = 0, fire_step = 0, finale_pause = 0, light_step = 0,
		concert_step = 0, fall_v0 = 300, fall_acc = 60, fall_vmax = 1080,
		start_delay = 0,
	},
}

-- Turbo duration of each timer kind (15.1.8).
C.TURBO_TIMER = { 1, 1, 1, 1, 1 }

-- Bolt tick at distance d (section 8): (15*d + 6) // 7 in normal mode, 0 in turbo.
function C.R(d, timing)
	if timing == C.TIMING_TURBO then return 0 end
	return math.floor((15 * d + 6) / 7)
end

-- Scores (7.4).
C.SCORE_WAVE = 20        -- per group cell whose piece is destroyed, times W
C.SCORE_EFFECT = 30      -- regular piece destroyed by an `effect` hit
C.SCORE_TRANSFORM = 30   -- piece transformed by "Colour X"
C.SCORE_HP = 50          -- every hp unit of a blocker, wires or floor tile
C.SCORE_CONCERT = 300    -- Riff of the final concert
C.SCORE_BONUS = { 60, 90, 60, 150 } -- by special code: riff, sub, bird, disco

-- Praise thresholds (section 16).
C.PRAISE = { { 3, "juicy" }, { 5, "hit" }, { 7, "drive" }, { 9, "vibe" }, { 12, "legend" } }

C.MAX_RECORDS_PER_TICK = 100000
C.CONCERT_MAX_ROUNDS = 20
C.SHUFFLE_ATTEMPTS = 50
C.START_FILLS = 100

return C
