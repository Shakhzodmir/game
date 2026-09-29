-- Every number of the meta layer lives here. The other meta modules read this
-- table and never hard-code an economy value.
--
-- Units: coins and stars are integers, time is in seconds unless a field name
-- says minutes. docs/design/meta-economy.md documents these values for the
-- producer; change both together.

local C = {}

C.levels = {
	-- Levels shipped; after the last one the meta is "all_done". A save from a
	-- build with more levels keeps its progress past `count` untouched.
	count = 100,
	free_up_to = 20,  -- levels 1..20 never cost a life and ignore the lives counter
}

-- Level difficulties the meta accepts, from the level files. Every table
-- below that is keyed by difficulty must cover exactly these.
C.difficulties = { "easy", "medium", "hard", "super_hard" }

-- Stars for a win, by difficulty.
C.stars = { easy = 1, medium = 1, hard = 2, super_hard = 3 }

C.coins = {
	start = 500,
	win_base = 25,
	win_mult = { easy = 1, medium = 1, hard = 2, super_hard = 3 },
	per_move_left = 5,  -- for every move left when the level was won
}

-- Chest after every 10th level: k = level / 10.
C.level_chest = {
	every = 10,
	coins_base = 50,
	coins_per_k = 10,
	boosters_odd = 1,             -- boosters in the chest when k is odd
	boosters_even = 2,            -- ... when k is even
	infinite_minutes_odd = 15,
	infinite_minutes_even = 30,
	-- Chest boosters are dealt by walking this cycle; every chest continues
	-- where the previous one stopped. A booster still locked when its chest
	-- opens is skipped: the walk moves on to the next unlocked one, which it
	-- then passes. If none is unlocked the chest gives the fallback and the
	-- walk stays where it is.
	rotation = { "stick", "row_light", "riff", "col_light", "sub", "remix", "disco" },
	fallback = "stick",
}

C.lives = {
	max = 5,
	regen_seconds = 20 * 60,
	refill_price = 600,
}

-- "+5 moves" after running out of moves. The price list is per attempt; its
-- length is the purchase limit. From the riff_from-th purchase on the
-- continue also puts a Riff on the board.
C.continues = {
	moves = 5,
	prices = { 700, 1400, 2100 },
	riff_from = 2,
}

C.ad_moves = 3  -- rewarded ad, at most once per attempt

-- Boosters, in inventory display order. kind "in" = used during a level,
-- kind "pre" = chosen before a level and placed on the board by the core.
-- A booster unlocks when its level becomes the next level to play; the player
-- then gets `gift` of it for free. Packs hold pack_size pieces.
C.pack_size = 3
C.boosters = {
	{ id = "stick",     kind = "in",  unlock = 8,  gift = 3, pack_price = 450 },
	{ id = "row_light", kind = "in",  unlock = 14, gift = 2, pack_price = 600 },
	{ id = "col_light", kind = "in",  unlock = 18, gift = 2, pack_price = 600 },
	{ id = "remix",     kind = "in",  unlock = 25, gift = 2, pack_price = 450 },
	{ id = "riff",      kind = "pre", unlock = 12, gift = 3, pack_price = 600 },
	{ id = "sub",       kind = "pre", unlock = 16, gift = 3, pack_price = 750 },
	{ id = "disco",     kind = "pre", unlock = 22, gift = 3, pack_price = 900 },
}

-- Win streak ("Серия хитов"): wins in a row, counted from level 12 on.
-- At the start of a level each reward whose threshold is reached gives one
-- free pre-level booster, but only if that booster is already unlocked.
C.streak = {
	from_level = 12,
	rewards = {
		{ wins = 1, booster = "riff" },
		{ wins = 2, booster = "sub" },
		{ wins = 3, booster = "disco" },
	},
}

-- Player salt for attempt seeds (core-rules.md, section 3). The client's
-- random seed must be an integer with |seed| < 2^53 (exact in a double).
C.salt = { min = 1, max = 2147483646 }

C.settings = {
	music = 0.8,
	sfx = 1.0,
	haptics = true,
	reduced_motion = false,
	input_mode = "swipe",
	language = "auto",
}
C.input_modes = { "swipe", "taptap" }
C.languages = { "auto", "en", "ru" }

-- District scene look, a cosmetic toggle.
C.views = { "day", "concert" }

C.save_version = 1

return C
