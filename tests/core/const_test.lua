-- Constants of the core against the tables of core-rules.md: timings (14),
-- enumeration codes (17.2), scores (7.4), praise (16), queue records (15.2).
-- The numbers below are typed from the specification, not from const.lua.

local C = require("core.const")

describe("core const: timings (section 14)", function()
	local NORMAL = {
		swap = 10, exchange = 18, swap_fail = 14, shuffle = 30, clear = 9, chain = 3, sub_swell = 6, ring = 2,
		bird_flight = 33, disco_step = 2, transform_step = 2, fire_step = 3, finale_pause = 24,
		light_step = 1, concert_step = 2, fall_v0 = 300, fall_acc = 60, fall_vmax = 1080, start_delay = 1,
	}
	local TURBO = {
		swap = 1, exchange = 1, swap_fail = 1, shuffle = 1, clear = 1, chain = 0, sub_swell = 0, ring = 0,
		bird_flight = 0, disco_step = 0, transform_step = 0, fire_step = 0, finale_pause = 0,
		light_step = 0, concert_step = 0, fall_v0 = 300, fall_acc = 60, fall_vmax = 1080, start_delay = 0,
	}

	it("the normal column", function()
		assert_same(C.T[C.TIMING_NORMAL], NORMAL)
	end)

	it("the turbo column: only times change, the fall kinematics do not", function()
		assert_same(C.T[C.TIMING_TURBO], TURBO)
	end)

	it("a cell is 3600 units; 5, 60 and 18 cells per second and second squared at 60 ticks", function()
		assert_eq(C.UNIT, 3600)
		assert_eq(C.T[1].fall_v0 * 60 / C.UNIT, 5)
		assert_eq(C.T[1].fall_acc * 60 * 60 / C.UNIT, 60)
		assert_eq(C.T[1].fall_vmax * 60 / C.UNIT, 18)
	end)

	it("R(d) = (15 d + 6) // 7 in normal mode (28 cells per second) and 0 in turbo", function()
		local function idiv(a, b) return (a - a % b) / b end
		for d = 0, 40 do
			assert_eq(C.R(d, C.TIMING_NORMAL), idiv(15 * d + 6, 7), "d = " .. d)
			assert_eq(C.R(d, C.TIMING_TURBO), 0)
		end
		assert_same({ C.R(0, 1), C.R(1, 1), C.R(2, 1), C.R(3, 1), C.R(4, 1), C.R(7, 1), C.R(8, 1) }, { 0, 3, 5, 7, 9, 15, 18 })
	end)

	it("the turbo duration of every timer kind is one tick (15.1.8)", function()
		for _, kind in ipairs({ C.TM_SWAP, C.TM_FAIL, C.TM_BACK, C.TM_LOCK, C.TM_CLEAR, C.TM_XCHG }) do
			assert_eq(C.TURBO_TIMER[kind], 1, "timer " .. kind)
		end
		assert_eq(C.TURBO_TIMER[C.TM_SWAP], C.T[C.TIMING_TURBO].swap)
		assert_eq(C.TURBO_TIMER[C.TM_FAIL], C.T[C.TIMING_TURBO].swap_fail)
		assert_eq(C.TURBO_TIMER[C.TM_LOCK], C.T[C.TIMING_TURBO].shuffle)
		assert_eq(C.TURBO_TIMER[C.TM_CLEAR], C.T[C.TIMING_TURBO].clear)
		assert_eq(C.TURBO_TIMER[C.TM_XCHG], C.T[C.TIMING_TURBO].exchange)
	end)

	it("limits: 100 000 records per tick, 20 concert rounds, 50 shuffle attempts, 100 start fills", function()
		assert_eq(C.MAX_RECORDS_PER_TICK, 100000)
		assert_eq(C.CONCERT_MAX_ROUNDS, 20)
		assert_eq(C.SHUFFLE_ATTEMPTS, 50)
		assert_eq(C.START_FILLS, 100)
	end)
end)

describe("core const: enumeration codes (17.2)", function()
	it("colours in the global order of section 0", function()
		assert_same(C.COLOR_NAME, { "red", "orange", "yellow", "green", "blue", "purple" })
		for code, name in ipairs(C.COLOR_NAME) do assert_eq(C.COLOR[name], code) end
		assert_eq(C.NCOLORS, 6)
	end)

	it("kind, special, axis, blocker", function()
		assert_same({ C.K_NONE, C.K_REGULAR, C.K_SPECIAL, C.K_MIC, C.K_BLOCKER }, { 0, 1, 2, 3, 4 })
		assert_same(C.KIND_NAME, { "regular", "special", "mic", "blocker" })
		assert_same({ C.SP_RIFF, C.SP_SUB, C.SP_BIRD, C.SP_DISCO }, { 1, 2, 3, 4 })
		assert_same(C.SPECIAL, { riff = 1, sub = 2, bird = 3, disco = 4 })
		assert_same({ C.AX_H, C.AX_V }, { 1, 2 })
		assert_same(C.AXIS, { h = 1, v = 2 })
		assert_same({ C.BK_BOX, C.BK_CONCRETE, C.BK_NOISE, C.BK_BALLOON, C.BK_COLUMN }, { 1, 2, 3, 4, 5 })
		assert_same(C.BLOCKER, { record_box = 1, concrete = 2, noise = 3, balloon = 4, column = 5 })
	end)

	it("states, timers, source kinds", function()
		assert_same({ C.S_IDLE, C.S_FALL, C.S_SWAP, C.S_CLEAR, C.S_ARMED }, { 1, 2, 3, 4, 5 })
		assert_same(C.STATE_NAME, { "idle", "fall", "swap", "clear", "armed" })
		assert_same({ C.TM_NONE, C.TM_SWAP, C.TM_FAIL, C.TM_BACK, C.TM_LOCK, C.TM_CLEAR, C.TM_XCHG }, { 0, 1, 2, 3, 4, 5, 6 })
		assert_same({ C.SRC_MATCH, C.SRC_ADJ, C.SRC_EFFECT }, { 1, 2, 3 })
	end)

	it("items: in-level boosters, pre-level boosters, the continue Riff and the Crossfader", function()
		assert_same({ C.IT_STICK, C.IT_ROW, C.IT_COL, C.IT_REMIX }, { 1, 2, 3, 4 })
		assert_same({ C.IT_PRE_RIFF, C.IT_PRE_SUB, C.IT_PRE_DISCO, C.IT_CONT_RIFF }, { 5, 6, 7, 8 })
		assert_eq(C.IT_SWAP, 9)
		assert_same(C.BOOSTER, { stick = 1, row_light = 2, col_light = 3, remix = 4, swap = 9 })
		assert_eq(C.BOOSTER_NAME[C.IT_SWAP], "swap")
		assert_same(C.PRE_BOOSTER, { riff = 5, sub = 6, disco = 7 })
		assert_same(C.PRE_BOOSTER_NAME, { [5] = "riff", [6] = "sub", [7] = "disco" })
	end)

	it("game states and timing modes", function()
		assert_same({ C.G_PLAYING, C.G_WON_WAIT, C.G_CONCERT, C.G_OUT, C.G_LOST, C.G_COMPLETE }, { 1, 2, 3, 4, 5, 6 })
		assert_same(C.GAME_NAME, { "playing", "won_wait", "concert", "out_of_moves", "lost", "complete" })
		assert_same({ C.TIMING_NORMAL, C.TIMING_TURBO }, { 1, 2 })
		assert_same(C.TIMING, { normal = 1, turbo = 2 })
	end)

	it("goals, difficulty and stars (13: easy and medium 1, hard 2, super_hard 3)", function()
		assert_same(C.GOAL, { collect = 1, ["break"] = 2, light = 3, deliver = 4 })
		assert_same(C.DIFFICULTY, { easy = 1, medium = 2, hard = 3, super_hard = 4 })
		assert_same({ C.STARS[C.DIFFICULTY.easy], C.STARS[C.DIFFICULTY.medium], C.STARS[C.DIFFICULTY.hard], C.STARS[C.DIFFICULTY.super_hard] }, { 1, 1, 2, 3 })
	end)

	it("queue records and the number of data fields of each (15.2)", function()
		assert_same({ C.R_ACTIVATE, C.R_HIT, C.R_DISCO, C.R_TRANSFORM, C.R_BIRD, C.R_CONCERT_A, C.R_CONCERT_B, C.R_BOOSTER },
			{ 1, 2, 3, 4, 5, 6, 7, 8 })
		-- activate: id, cell, partner cell, mv, wv, X | hit: source, cell | disco_step: source, k, id
		-- transform: source, k, id | bird_impact: source, cell, cargo, axis | concert_a: k | concert_b | booster: item, target, mv, wv
		assert_same(C.RECORD_FIELDS, { 6, 2, 3, 3, 4, 1, 0, 4 })
	end)
end)

describe("core const: scores and praise (7.4, 16)", function()
	it("score table", function()
		assert_eq(C.SCORE_WAVE, 20) -- times the wave W
		assert_eq(C.SCORE_EFFECT, 30)
		assert_eq(C.SCORE_TRANSFORM, 30)
		assert_eq(C.SCORE_HP, 50)
		assert_eq(C.SCORE_CONCERT, 300)
		assert_eq(C.SCORE_BONUS[C.SP_RIFF], 60)
		assert_eq(C.SCORE_BONUS[C.SP_BIRD], 60)
		assert_eq(C.SCORE_BONUS[C.SP_SUB], 90)
		assert_eq(C.SCORE_BONUS[C.SP_DISCO], 150)
	end)

	it("praise thresholds 3, 5, 7, 9, 12 and their words", function()
		assert_same(C.PRAISE, { { 3, "juicy" }, { 5, "hit" }, { 7, "drive" }, { 9, "vibe" }, { 12, "legend" } })
	end)

	it("the core version names the specification it implements", function()
		assert_eq(string.sub(C.CORE_VERSION, 1, 3), "3.1")
	end)
end)
