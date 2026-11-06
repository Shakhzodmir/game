-- UI strings in English, Russian and Korean + formatting helpers (pure Lua).
--
--   local i18n = require("client.i18n")
--   i18n.set_language("auto", sys.get_sys_info().language)  -- setting from the meta
--   i18n.t("town.level", {n = 12})              --> "Level 12" / "Уровень 12"
--   i18n.t("common.stars", {n = 3})             --> plural form picked by n
--   i18n.number(1050)                           --> "1,050" / "1 050"
--   i18n.duration(125)                          --> "2:05"
--   i18n.name({en = "Jazz Bar", ru = "Джаз-бар"}) --> by current language
--
-- Every entry holds en and ru side by side; the Korean text of the same key lives in client/i18n_ko.lua and is merged
-- in below as `ko` (one plural form: a plain string). A missing translation is caught by tests/client/i18n_test.lua. A value is a
-- string with {placeholders} or, for counted phrases, a plural table:
-- en {one, other}; ru {one, few, many} (1 звезда, 2 звезды, 5 звёзд).
-- Glyphs used here must exist in the generated fonts (tools/gen_defold.py
-- builds Latin + Cyrillic + the punctuation below).

local M = {}

M.LANGUAGES = { "en", "ru", "ko" }
M.FALLBACK = "en"

local S = {
	-- common ---------------------------------------------------------------------
	["app.title"] = { en = "GLOW", ru = "GLOW" },
	["common.ok"] = { en = "OK", ru = "ОК" },
	["common.cancel"] = { en = "Cancel", ru = "Отмена" },
	["common.close"] = { en = "Close", ru = "Закрыть" },
	["common.back"] = { en = "Back", ru = "Назад" },
	["common.yes"] = { en = "Yes", ru = "Да" },
	["common.no"] = { en = "No", ru = "Нет" },
	["common.play"] = { en = "Play", ru = "Играть" },
	["common.continue"] = { en = "Continue", ru = "Продолжить" },
	["common.retry"] = { en = "Try again", ru = "Ещё раз" },
	["common.buy"] = { en = "Buy", ru = "Купить" },
	["common.free"] = { en = "Free", ru = "Бесплатно" },
	["common.soon"] = { en = "Coming soon", ru = "Скоро" },
	["common.new"] = { en = "NEW", ru = "НОВОЕ" },
	["common.loading"] = { en = "Loading…", ru = "Загрузка…" },
	["common.skip"] = { en = "Skip", ru = "Пропустить" },
	["common.collect"] = { en = "Collect", ru = "Забрать" },
	["common.locked"] = { en = "Locked", ru = "Закрыто" },
	["common.level_n"] = { en = "Level {n}", ru = "Ур. {n}" },
	["common.unavailable"] = { en = "Not available in this version", ru = "Недоступно в этой версии" },
	["common.error"] = { en = "Something went wrong", ru = "Что-то пошло не так" },
	["common.not_enough_coins"] = { en = "Not enough coins", ru = "Не хватает монет" },
	["common.not_enough_stars"] = { en = "Not enough stars", ru = "Не хватает звёзд" },
	["common.coins"] = {
		en = { one = "{n} coin", other = "{n} coins" },
		ru = { one = "{n} монета", few = "{n} монеты", many = "{n} монет" },
	},
	["common.stars"] = {
		en = { one = "{n} star", other = "{n} stars" },
		ru = { one = "{n} звезда", few = "{n} звезды", many = "{n} звёзд" },
	},
	["common.lives"] = {
		en = { one = "{n} life", other = "{n} lives" },
		ru = { one = "{n} жизнь", few = "{n} жизни", many = "{n} жизней" },
	},
	["common.moves"] = {
		en = { one = "{n} move", other = "{n} moves" },
		ru = { one = "{n} ход", few = "{n} хода", many = "{n} ходов" },
	},
	["time.ms"] = { en = "{m}:{s}", ru = "{m}:{s}" },
	["time.hms"] = { en = "{h}:{m}:{s}", ru = "{h}:{m}:{s}" },
	["time.hm"] = { en = "{h} h {m} min", ru = "{h} ч {m} мин" },
	["time.min"] = { en = "{m} min", ru = "{m} мин" },

	-- level HUD ---------------------------------------------------------------------------
	["hud.level"] = { en = "Level {n}", ru = "Уровень {n}" },
	["hud.moves"] = { en = "Moves", ru = "Ходы" },
	["hud.goals"] = { en = "Goals", ru = "Цели" },
	["hud.shuffle"] = { en = "No moves — shuffling!", ru = "Ходов нет — перемешиваем!" },
	["hud.tap_skip"] = { en = "Tap to skip", ru = "Нажми, чтобы пропустить" },
	["hud.booster_locked"] = { en = "Opens at level {n}", ru = "Откроется на уровне {n}" },
	["hud.bonus_hint"] = { en = "Specials fill the bar. Fill it and get a free special!", ru = "Спецфишки заполняют шкалу. Наполни её и получи бонус!" },
	["hud.wait_board"] = { en = "Wait until the board settles", ru = "Подожди, пока поле успокоится" },
	["hud.booster_no"] = { en = "Nothing to do there: pick another spot", ru = "Тут нечего делать — выбери другое место" },
	["hud.remix_no"] = { en = "Nothing to shuffle", ru = "Нечего перемешивать" },
	["hud.pick_cell"] = { en = "Pick a piece", ru = "Выбери фишку" },
	["hud.pick_row"] = { en = "Pick a row", ru = "Выбери ряд" },
	["hud.pick_col"] = { en = "Pick a column", ru = "Выбери колонку" },
	["hud.hard"] = { en = "Hard", ru = "Сложный" },
	["hud.super_hard"] = { en = "Super Hard", ru = "Суперсложный" },
	["praise.1"] = { en = "Juicy!", ru = "Сочно!" },
	["praise.2"] = { en = "Hit!", ru = "Хит!" },
	["praise.3"] = { en = "Drive!", ru = "Драйв!" },
	["praise.4"] = { en = "Groovy!", ru = "Кайф!" },
	["praise.5"] = { en = "Legend!", ru = "Легенда!" },

	-- things that cannot be moved (client/level_plates.lua, screens/level/board.script): the toast of the first
	-- refused move of each kind in a session, after the thing has shaken its head -------------------------
	["level.fixed_blocker"] = {
		en = "Can't be moved — break it with matches next to it",
		ru = "Не двигается — разбей совпадениями рядом",
	},
	["level.fixed_wired"] = {
		en = "Wired pieces can't move — match them where they stand",
		ru = "Фишка в проводах не двигается — собери её на месте",
	},

	-- level effects: combo titles over the board, the final concert (screens/level/level_fx.gui_script) --
	["combo.cross"] = { en = "Cross!", ru = "Крест!" },
	["combo.triple_cross"] = { en = "Triple cross!", ru = "Тройной крест!" },
	["combo.bass_drop"] = { en = "Bass drop!", ru = "Бас-дроп!" },
	["combo.bird_riff"] = { en = "Riff flight!", ru = "Рифф на крыльях!" },
	["combo.bird_sub"] = { en = "Bass flight!", ru = "Бас на крыльях!" },
	["combo.trio"] = { en = "Trio!", ru = "Трио!" },
	["combo.finale"] = { en = "Grand finale!", ru = "Гранд-финал!" },
	["combo.color_riff"] = { en = "Riff storm!", ru = "Шторм риффов!" },
	["combo.color_sub"] = { en = "Bass storm!", ru = "Шторм басов!" },
	["combo.color_bird"] = { en = "Flock!", ru = "Стая!" },
	["fx.concert"] = { en = "Final concert!", ru = "Финальный концерт!" },

	-- boosters -----------------------------------------------------------------------------
	["booster.stick"] = { en = "Drumstick", ru = "Барабанная палочка" },
	["booster.row_light"] = { en = "Row spotlight", ru = "Прожектор по ряду" },
	["booster.col_light"] = { en = "Column spotlight", ru = "Прожектор по колонке" },
	["booster.remix"] = { en = "Remix", ru = "Ремикс" },
	["booster.riff"] = { en = "Riff", ru = "Рифф" },
	["booster.sub"] = { en = "Subwoofer", ru = "Сабвуфер" },
	["booster.disco"] = { en = "Disco ball", ru = "Диско-шар" },
	["booster.stick_desc"] = { en = "Breaks one piece", ru = "Разбивает одну фишку" },
	["booster.row_light_desc"] = { en = "Clears a whole row", ru = "Очищает весь ряд" },
	["booster.col_light_desc"] = { en = "Clears a whole column", ru = "Очищает всю колонку" },
	["booster.remix_desc"] = { en = "Shuffles the board", ru = "Перемешивает поле" },
	["booster.riff_desc"] = { en = "A Riff on the board at start", ru = "Рифф на поле со старта" },
	["booster.sub_desc"] = { en = "A Subwoofer on the board at start", ru = "Сабвуфер на поле со старта" },
	["booster.disco_desc"] = { en = "A Disco ball on the board at start", ru = "Диско-шар на поле со старта" },

	-- the Crossfader (booster "swap"): its name and line in the shop, the prompts of its two picks, its refusals,
	-- the first-use hint of level 21
	["booster.swap"] = { en = "Crossfader", ru = "Кроссфейдер" },
	["booster.swap_desc"] = { en = "Swaps any two pieces", ru = "Меняет местами любые две фишки" },
	["hud.pick_two"] = { en = "Pick two pieces", ru = "Выбери две фишки" },
	["hud.pick_second"] = { en = "Now the second piece", ru = "Теперь вторую фишку" },
	["hud.swap_fixed"] = { en = "This one can't be moved", ru = "Эту фишку не сдвинуть" },
	["hud.swap_same"] = { en = "Pick two different pieces", ru = "Выбери две разные фишки" },
	["tutorial.swap_booster"] = {
		en = "Swap any two pieces with the Crossfader!",
		ru = "Меняй любые две фишки Кроссфейдером!",
	},

	-- pieces, specials, blockers (goals, tutorials) ----------------------------------------------
	["piece.red"] = { en = "Red picks", ru = "Красные медиаторы" },
	["piece.orange"] = { en = "Orange tambourines", ru = "Оранжевые бубны" },
	["piece.yellow"] = { en = "Yellow stars", ru = "Жёлтые звёзды" },
	["piece.green"] = { en = "Green notes", ru = "Зелёные ноты" },
	["piece.blue"] = { en = "Blue cassettes", ru = "Синие кассеты" },
	["piece.purple"] = { en = "Purple headphones", ru = "Фиолетовые наушники" },
	["special.riff"] = { en = "Riff", ru = "Рифф" },
	["special.sub"] = { en = "Subwoofer", ru = "Сабвуфер" },
	["special.bird"] = { en = "Songbird", ru = "Пташка" },
	["special.disco"] = { en = "Disco ball", ru = "Диско-шар" },
	["special.finale"] = { en = "Grand finale!", ru = "Гранд-финал!" },
	["special.trio"] = { en = "Trio!", ru = "Трио!" },
	["blocker.record_box"] = { en = "Record box", ru = "Коробка с пластинками" },
	["blocker.dancefloor"] = { en = "Dance floor", ru = "Танцпол" },
	["blocker.wires"] = { en = "Wires", ru = "Провода" },
	["blocker.mic"] = { en = "Microphone", ru = "Микрофон" },
	["blocker.concrete"] = { en = "Concrete block", ru = "Бетонная тумба" },
	["blocker.noise"] = { en = "Noise", ru = "Помехи" },
	["blocker.balloon"] = { en = "Balloon", ru = "Воздушный шарик" },
	["blocker.column"] = { en = "Dusty speaker", ru = "Пыльная колонка" },
	["blocker.record_box_desc"] = {
		en = "Match next to the box or hit it with a special to break it. Some boxes take up to 3 hits.",
		ru = "Собирай рядом с коробкой или бей спецфишкой. Некоторым коробкам нужно до 3 ударов.",
	},
	["blocker.dancefloor_desc"] = {
		en = "Make matches on the purple tiles to light them gold. A double frame needs two matches.",
		ru = "Собирай фишки на фиолетовых плитках, чтобы зажечь их золотом. Двойной рамке нужно два матча.",
	},
	["blocker.wires_desc"] = {
		en = "A piece in wires cannot move. Match it or hit it with a special to cut the wires.",
		ru = "Фишка в проводах не двигается. Собери её в ряд или ударь спецфишкой, чтобы порвать провода.",
	},
	["blocker.mic_desc"] = {
		en = "Bring the microphone down to its stand at the bottom of the board.",
		ru = "Опусти микрофон на стойку внизу поля.",
	},
	["blocker.concrete_desc"] = {
		en = "Plain matches can't crack concrete: use special pieces and boosters.",
		ru = "Обычный матч бетон не берёт: нужны спецфишки и бустеры.",
	},
	["blocker.noise_desc"] = {
		en = "Noise spreads after every move that doesn't hit it. Match next to it to clear it.",
		ru = "Помехи растут после каждого хода, который их не задел. Собирай рядом, чтобы убрать их.",
	},
	["blocker.balloon_desc"] = {
		en = "A balloon pops when you match its colour next to it, or with any special.",
		ru = "Шарик лопается от матча его цвета рядом или от любой спецфишки.",
	},
	["blocker.column_desc"] = {
		en = "A big dusty speaker: every match next to it and every special knocks off one point.",
		ru = "Большая пыльная колонка: каждый матч рядом и каждая спецфишка снимают одно очко.",
	},

	-- pause -----------------------------------------------------------------------------------
	["pause.title"] = { en = "Paused", ru = "Пауза" },
	["pause.resume"] = { en = "Resume", ru = "Продолжить" },
	["pause.settings"] = { en = "Settings", ru = "Настройки" },
	["pause.quit"] = { en = "Quit level", ru = "Выйти из уровня" },
	["pause.quit_confirm"] = { en = "Quit", ru = "Выйти" },
	["pause.quit_free"] = { en = "Nothing is lost before your first move.", ru = "До первого хода ничего не теряется." },
	["pause.boosters_back"] = {
		en = "The boosters you took along come back.",
		ru = "Бустеры, которые ты взял с собой, вернутся.",
	},
	["pause.warn_loss"] = { en = "Leaving counts as a loss.", ru = "Выход засчитается как поражение." },
	["pause.leave_title"] = { en = "Leave the level?", ru = "Выйти из уровня?" },
	["pause.stay"] = { en = "Keep playing", ru = "Остаться" },
	["pause.level"] = { en = "Level {n}", ru = "Уровень {n}" },

	-- out of moves -------------------------------------------------------------------------------
	["continue.title"] = { en = "Out of moves!", ru = "Ходы кончились!" },
	["continue.offer"] = {
		en = { one = "+{n} move", other = "+{n} moves" },
		ru = { one = "+{n} ход", few = "+{n} хода", many = "+{n} ходов" },
	},
	["continue.riff"] = { en = "+ a Riff on the board", ru = "+ Рифф на поле" },
	["continue.ad"] = { en = "Watch a video", ru = "Смотреть видео" },
	["continue.give_up"] = { en = "Give up", ru = "Сдаться" },
	["continue.streak_warning"] = {
		en = "Your hit streak of {n} will burn!",
		ru = "Серия хитов ({n}) сгорит!",
	},
	["continue.life_warning"] = { en = "You will lose a life.", ru = "Ты потеряешь жизнь." },
	["continue.warn_loss"] = { en = "Giving up counts as a loss.", ru = "Сдача засчитается как поражение." },
	["continue.no_coins"] = { en = "Not enough coins: you have {n}", ru = "Не хватает монет: у тебя {n}" },
	["continue.use_booster"] = { en = "Or use a booster:", ru = "Или возьми бустер:" },
	["continue.sub"] = { en = "A few more moves can do it!", ru = "Ещё пара ходов — и победа!" },
	["continue.stuck"] = {
		en = "No move is left on the board. Use a booster or give up.",
		ru = "На поле не осталось ходов. Возьми бустер или сдайся.",
	},
	["continue.free_debug"] = { en = "Test level: free", ru = "Тестовый уровень: бесплатно" },
	["continue.limit"] = { en = "No more extra moves for this attempt.", ru = "Дополнительных ходов в этой попытке больше нет." },

	-- lose ------------------------------------------------------------------------------------------
	["lose.title"] = { en = "Level failed", ru = "Уровень не пройден" },
	["lose.retry"] = { en = "Try again", ru = "Ещё раз" },
	["lose.town"] = { en = "To town", ru = "В город" },
	["lose.life_lost"] = { en = "−1 life", ru = "−1 жизнь" },
	["lose.streak_lost"] = { en = "Hit streak lost", ru = "Серия хитов сгорела" },
	["lose.close"] = { en = "So close!", ru = "Совсем чуть-чуть!" },
	["lose.left"] = { en = "Still to do", ru = "Осталось сделать" },
	["lose.lives"] = { en = "Lives: {n} of {max}", ru = "Жизни: {n} из {max}" },
	["lose.no_lives"] = { en = "No lives left. A new one in {time}", ru = "Жизней нет. Новая через {time}" },
	["lose.cheer"] = { en = "Next time!", ru = "В следующий раз получится!" },

	-- buying a booster in the level (gui/booster_buy.lua) -------------------------------------------------
	["buy.text"] = { en = "None left! Get a pack of {n}?", ru = "Закончились! Взять набор из {n}?" },
	["buy.pack"] = { en = "Pack of {n}", ru = "Набор из {n}" },
	["buy.done"] = { en = "+{n} {name}!", ru = "+{n} {name}!" },
	["buy.locked"] = { en = "Opens at level {n}", ru = "Откроется на уровне {n}" },

	-- win / results ------------------------------------------------------------------------------------
	["win.title"] = { en = "Level complete!", ru = "Уровень пройден!" },
	["win.next"] = { en = "Next level", ru = "Следующий уровень" },
	["win.town"] = { en = "To town", ru = "В город" },
	["win.unlocked"] = { en = "New booster: {name}", ru = "Новый бустер: {name}" },
	["win.streak"] = { en = "Hit streak: {n}", ru = "Серия хитов: {n}" },
	["win.chest"] = { en = "Chest!", ru = "Сундук!" },
	["win.score"] = { en = "Score: {n}", ru = "Очки: {n}" },
	["win.moves_left"] = {
		en = { one = "{n} move left", other = "{n} moves left" },
		ru = { one = "Остался {n} ход", few = "Осталось {n} хода", many = "Осталось {n} ходов" },
	},
	["win.chest_in"] = {
		en = { one = "Chest in {n} level", other = "Chest in {n} levels" },
		ru = { one = "Сундук через {n} уровень", few = "Сундук через {n} уровня", many = "Сундук через {n} уровней" },
	},
	-- the level chest of the results window: the player opens it here, the unlimited lives run from that moment
	["win.chest_open"] = { en = "Open", ru = "Открыть" },
	["win.chest_got"] = { en = "Chest collected!", ru = "Сундук получен!" },
	["win.chest_lives_on"] = { en = "Unlimited lives are on!", ru = "Бесконечные жизни включены!" },
	-- the stars note of the results window: what decides the stars (score thresholds of the level)
	["win.stars_note"] = {
		en = "Stars come from your score: the more points, the more stars. Moves left give coins.",
		ru = "Звёзды зависят от очков: чем больше очков, тем больше звёзд. Ходы в запасе дают монеты.",
	},
	["win.next_star"] = { en = "{n} more points for the next star", ru = "До следующей звезды: {n}" },
	["win.max_stars"] = { en = "All 3 stars!", ru = "Все 3 звезды!" },
	["win.stars_new"] = { en = "+{n} to your stars", ru = "+{n} к твоим звёздам" },
	["win.stars_kept"] = { en = "Best on this level: {n} of 3 (stars never go down)", ru = "Лучший результат уровня: {n} из 3 (звёзды не отнимаются)" },
	["win.new_record"] = { en = "New score record!", ru = "Новый рекорд очков!" },
	["win.super_new"] = { en = "+{n} super stars", ru = "+{n} суперзвёзд" },
	["win.super_have"] = { en = "Super stars: {n}", ru = "Суперзвёзды: {n}" },
	["win.free_next"] = { en = "Free next start:", ru = "Бесплатно на старте:" },
	["win.all_done"] = { en = "More levels coming soon!", ru = "Скоро новые уровни!" },
	["win.refund"] = { en = "Returned to you: {names}", ru = "Возвращено тебе: {names}" },

	-- tutorial -----------------------------------------------------------------------------------------------------
	-- Two lines at most in the bubble (screens/level/tutorial_view.lua): a third one runs under its Skip tab.
	-- tests/client/tutorial_content_test.lua measures every text of content/tutorials.json in both languages.
	["tutorial.swap"] = {
		en = "Swap two pieces to make a line of 3",
		ru = "Меняй фишки местами и собирай 3 в ряд",
	},
	["tutorial.riff"] = { en = "Match 4 in a line to make a Riff!", ru = "Собери 4 в ряд — получишь Рифф!" },
	["tutorial.sub"] = { en = "Match in a T or L shape for a Subwoofer!", ru = "Собери уголком — получишь Сабвуфер!" },
	["tutorial.bird"] = { en = "Match a 2×2 square for a Songbird!", ru = "Собери квадрат 2×2 — получишь Пташку!" },
	["tutorial.disco"] = { en = "Match 5 in a line for a Disco ball!", ru = "Собери 5 в ряд — получишь Диско-шар!" },
	["tutorial.tap_special"] = { en = "Tap a special piece to launch it", ru = "Нажми на спецфишку, чтобы запустить её" },
	["tutorial.goals"] = { en = "Complete the goals before moves run out", ru = "Выполни цели, пока не кончились ходы" },
	["tutorial.booster"] = { en = "Tap a booster, then pick a target", ru = "Нажми на бустер, затем выбери цель" },
	["tutorial.record_box"] = {
		en = "Record boxes don't move. Break them!",
		ru = "Коробки не двигаются. Разбей их!",
	},
	["tutorial.dancefloor"] = { en = "Light up the whole dance floor!", ru = "Зажги весь танцпол!" },
	["tutorial.wires"] = { en = "Cut the wires to free the pieces!", ru = "Порви провода, чтобы освободить фишки!" },
	["tutorial.mic"] = { en = "Bring the microphones to the stage!", ru = "Доставь микрофоны на сцену!" },
	["tutorial.concrete"] = { en = "Only specials break concrete!", ru = "Бетон ломают только спецфишки!" },
	["tutorial.noise"] = { en = "Stop the noise before it spreads!", ru = "Убери помехи, пока они не разрослись!" },
	["tutorial.balloon"] = { en = "Pop the balloons with their own colour!", ru = "Лопай шарики фишками их цвета!" },
	["tutorial.column"] = { en = "Knock the dust off the big speaker!", ru = "Выбей пыль из большой колонки!" },
	-- steps of content/tutorials*.json (client/tutorial.lua): one line per step
	["tutorial.disco_swap"] = {
		en = "Swap the Disco ball with any piece",
		ru = "Поменяй Диско-шар местами с любой фишкой",
	},
	["tutorial.record_box_match"] = {
		en = "Match next to a box to crack it",
		ru = "Собери фишки рядом с коробкой — она треснет",
	},
	["tutorial.record_box_layers"] = { en = "Some boxes take several hits", ru = "Некоторым коробкам нужно несколько ударов" },
	["tutorial.combo"] = {
		en = "Swap two special pieces for a combo!",
		ru = "Поменяй две спецфишки местами — выйдет комбо!",
	},
	["tutorial.pre_boosters"] = {
		en = "Take boosters along: they start on the board",
		ru = "Бери бустеры с собой — они сразу на поле",
	},
	-- the dance floor: violet = still to light, gold = lit (client/level_floor.lua)
	-- (two lines at most: a longer step runs into the Skip button of the bubble)
	["tutorial.dancefloor_match"] = {
		en = "Match on purple tiles: they turn gold",
		ru = "Фиолетовая плитка загорится от матча",
	},
	["tutorial.dancefloor_double"] = { en = "A double frame takes two matches", ru = "Двойной рамке нужно два матча" },
	["tutorial.wires_match"] = {
		en = "Wired pieces can't move, but they still match",
		ru = "Фишка в проводах не двигается, но собирается",
	},
	["tutorial.wires_free"] = { en = "Wires cut: the piece is free again!", ru = "Провода порваны — фишка снова свободна!" },
	["tutorial.mic_drop"] = { en = "Clear the way under the microphone", ru = "Расчисти путь под микрофоном" },
	["tutorial.mic_stand"] = {
		en = "Bring the microphone to its stand to deliver it",
		ru = "Опусти микрофон на стойку — и он доставлен",
	},
	["tutorial.concrete_riff"] = {
		en = "Tap the Riff: its lightning cracks the concrete",
		ru = "Нажми на Рифф — его разряд треснет бетон",
	},
	["tutorial.noise_match"] = {
		en = "Match next to the noise to clear it",
		ru = "Собери фишки рядом с помехой — она исчезнет",
	},
	["tutorial.balloon_match"] = {
		en = "Match their colour next to a balloon to pop it",
		ru = "Собери рядом фишки его цвета — шарик лопнет",
	},
	["tutorial.column_match"] = {
		en = "Every match next to the speaker knocks off dust",
		ru = "Каждый матч рядом с колонкой сбивает пыль",
	},
	["tutorial.tap_continue"] = { en = "Tap to continue", ru = "Нажми, чтобы продолжить" },

	-- music stems (layer names shown by tasks and the jukebox) -------------------------------------------------------
	["stem.beat"] = { en = "Beat", ru = "Бит" },
	["stem.vinyl"] = { en = "Vinyl crackle", ru = "Треск винила" },
	["stem.keys"] = { en = "Keys", ru = "Клавиши" },
	["stem.bass"] = { en = "Bass", ru = "Бас" },
	["stem.lead"] = { en = "Lead", ru = "Мелодия" },
	["stem.pad"] = { en = "Pad", ru = "Пэд" },
	["stem.brushes"] = { en = "Brushes", ru = "Щётки" },
	["stem.piano"] = { en = "Piano", ru = "Пианино" },
	["stem.organ"] = { en = "Organ", ru = "Орган" },
	["stem.sax"] = { en = "Saxophone", ru = "Саксофон" },
	["stem.vibes"] = { en = "Vibraphone", ru = "Вибрафон" },
	["stem.trumpet"] = { en = "Trumpet", ru = "Труба" },
	["stem.drums"] = { en = "Drums", ru = "Барабаны" },
	["stem.shaker"] = { en = "Shaker", ru = "Шейкер" },
	["stem.guitar"] = { en = "Guitar", ru = "Гитара" },
	["stem.tuba"] = { en = "Tuba", ru = "Туба" },
	["stem.brass"] = { en = "Brass", ru = "Духовые" },
	["stem.clarinet"] = { en = "Clarinet", ru = "Кларнет" },
	["stem.claps"] = { en = "Claps", ru = "Хлопки" },
	["stem.whistle"] = { en = "Whistle", ru = "Свисток" },
	["stem.chords"] = { en = "Chords", ru = "Аккорды" },
	["stem.arp"] = { en = "Arpeggio", ru = "Арпеджио" },
	["stem.choir"] = { en = "Choir", ru = "Хор" },
	["stem.fx"] = { en = "Effects", ru = "Эффекты" },
	["stem.hook"] = { en = "Hook", ru = "Хук" },
	["stem.snaps"] = { en = "Snaps", ru = "Щелчки" },
	["stem.rhythm"] = { en = "Rhythm guitar", ru = "Ритм-гитара" },
	["stem.tamb"] = { en = "Tambourine", ru = "Бубен" },
	["stem.toms"] = { en = "Toms", ru = "Томы" },
	["stem.strings"] = { en = "Strings", ru = "Струнные" },
	["stem.gang"] = { en = "Gang vocals", ru = "Хор группы" },

	-- ============================================================================================================
	-- accounts and the cloud save (WP-10) ---------------------------------------------------------------------------
	["account.title"] = { en = "Account", ru = "Аккаунт" },
	["account.choice_title"] = { en = "Save your progress?", ru = "Сохранить прогресс?" },
	["account.choice_text"] = { en = "Sign in to keep your progress and continue on any device.", ru = "Войдите, чтобы прогресс сохранился и переносился между устройствами." },
	["account.privacy"] = { en = "We store only your sign-in and your save. You can delete both in Settings at any time.", ru = "Мы храним только ваш вход и сохранение игры. Удалить их можно в любой момент в Настройках." },
	["account.guest"] = { en = "Play as guest", ru = "Играть как гость" },
	["account.guest_note"] = { en = "A guest's progress stays on this device only.", ru = "Гостю прогресс сохраняется только на этом устройстве." },
	["account.google"] = { en = "Sign in with Google", ru = "Войти через Google" },
	["account.id_login"] = { en = "Sign in with ID and password", ru = "Войти по ID и паролю" },
	["account.create"] = { en = "Create account", ru = "Создать аккаунт" },
	["account.unavailable"] = { en = "Sign-in is not available yet.", ru = "Вход пока недоступен." },
	["account.as_guest"] = { en = "You are playing as a guest. Progress is saved on this device only.", ru = "Вы играете как гость. Прогресс хранится только на этом устройстве." },
	["account.signed_as"] = { en = "Signed in: {name}", ru = "Вы вошли: {name}" },
	["account.kind_google"] = { en = "Google account", ru = "Аккаунт Google" },
	["account.kind_id"] = { en = "ID and password account", ru = "Аккаунт с ID и паролем" },
	["account.no_mail_warn"] = { en = "No e-mail is linked: a forgotten password cannot be restored. Link an e-mail.", ru = "Почта не привязана: забытый пароль восстановить нельзя. Привяжите почту." },
	["account.pending_mail"] = { en = "Waiting for confirmation: {email}. Open the letter and tap the link.", ru = "Ждём подтверждения: {email}. Откройте письмо и нажмите на ссылку." },
	["account.link_google"] = { en = "Link Google", ru = "Привязать Google" },
	["account.link_email"] = { en = "Link e-mail", ru = "Привязать почту" },
	["account.check_mail"] = { en = "I confirmed the e-mail", ru = "Я подтвердил(а) почту" },
	["account.sync_now"] = { en = "Save to cloud now", ru = "Сохранить в облако сейчас" },
	["account.sign_out"] = { en = "Sign out", ru = "Выйти" },
	["account.delete"] = { en = "Delete account and data", ru = "Удалить аккаунт и данные" },
	["account.signout_title"] = { en = "Sign out?", ru = "Выйти из аккаунта?" },
	["account.signout_text"] = { en = "Your progress stays on this device. Another account will not get it.", ru = "Прогресс останется на этом устройстве. Другой аккаунт его не получит." },
	["account.signout_unsynced"] = { en = "Latest progress is not in the cloud yet. It stays on this device. Sign out anyway?", ru = "Последний прогресс ещё не в облаке. Он останется на этом устройстве. Всё равно выйти?" },
	["account.delete_title"] = { en = "Delete account?", ru = "Удалить аккаунт?" },
	["account.delete_text"] = { en = "The account and its cloud save will be deleted for good. Progress on this device stays.", ru = "Аккаунт и его облачное сохранение будут удалены навсегда. Прогресс на этом устройстве останется." },
	["account.delete_do"] = { en = "Delete", ru = "Удалить" },
	["account.signed_in"] = { en = "Signed in", ru = "Вход выполнен" },
	["account.signed_out"] = { en = "Signed out", ru = "Вы вышли из аккаунта" },
	["account.deleted"] = { en = "Account deleted", ru = "Аккаунт удалён" },
	["account.linked"] = { en = "Google linked", ru = "Google привязан" },
	["account.mail_sent"] = { en = "Letter sent to {email}", ru = "Письмо отправлено на {email}" },
	["account.mail_confirmed"] = { en = "E-mail confirmed", ru = "Почта подтверждена" },
	["account.mail_not_yet"] = { en = "Not confirmed yet: open the letter and tap the link", ru = "Пока не подтверждено: откройте письмо и нажмите на ссылку" },
	["account.reminder"] = { en = "Playing as a guest: progress will not move to another device. Sign in under Settings, Account.", ru = "Вы играете как гость: прогресс не сохранится на другом устройстве. Войти можно в Настройках, раздел «Аккаунт»." },
	["account.form_id"] = { en = "ID (3-20: letters, digits, _)", ru = "ID (3-20: буквы, цифры, _)" },
	["account.form_password"] = { en = "Password (8 or more characters)", ru = "Пароль (от 8 символов)" },
	["account.form_password2"] = { en = "Repeat the password", ru = "Повторите пароль" },
	["account.form_email"] = { en = "E-mail", ru = "Почта" },
	["account.form_err_id"] = { en = "ID: 3-20 characters, a letter first, then letters, digits or _", ru = "ID: 3-20 знаков, первая буква, дальше буквы, цифры или _" },
	["account.form_err_pw"] = { en = "The password needs 8 or more characters", ru = "Пароль должен быть не короче 8 символов" },
	["account.form_err_pw2"] = { en = "The passwords do not match", ru = "Пароли не совпадают" },
	["account.form_err_email"] = { en = "This does not look like an e-mail address", ru = "Это не похоже на адрес почты" },
	["account.form_register_note"] = { en = "No e-mail needed. If you forget the password it cannot be restored. Link an e-mail later in Settings, Account.", ru = "Почта не нужна. Если забудете пароль, восстановить его будет нельзя. Почту можно привязать позже: Настройки, «Аккаунт»." },
	["account.form_mail_note"] = { en = "We will send a letter to confirm this address.", ru = "Мы отправим письмо, чтобы подтвердить этот адрес." },
	["auth.err.unavailable"] = { en = "Sign-in is not available yet", ru = "Вход пока недоступен" },
	["auth.err.busy"] = { en = "One moment, still working", ru = "Минутку, ещё выполняется" },
	["auth.err.offline"] = { en = "No connection. Try again later", ru = "Нет соединения. Попробуйте позже" },
	["auth.err.timeout"] = { en = "The server did not answer. Try again later", ru = "Сервер не ответил. Попробуйте позже" },
	["auth.err.popup_blocked"] = { en = "The browser blocked the sign-in window. Allow pop-ups", ru = "Браузер заблокировал окно входа. Разрешите всплывающие окна" },
	["auth.err.bad_credentials"] = { en = "Wrong ID or password", ru = "Неверный ID или пароль" },
	["auth.err.id_taken"] = { en = "This ID is taken. Choose another", ru = "Этот ID занят. Выберите другой" },
	["auth.err.email_in_use"] = { en = "This e-mail belongs to another account", ru = "Эта почта принадлежит другому аккаунту" },
	["auth.err.weak_password"] = { en = "The password is too weak", ru = "Слишком простой пароль" },
	["auth.err.bad_id"] = { en = "This ID is not allowed", ru = "Такой ID нельзя" },
	["auth.err.bad_email"] = { en = "This e-mail address is not valid", ru = "Неверный адрес почты" },
	["auth.err.need_recent_login"] = { en = "For safety, sign in again first, then repeat", ru = "Для безопасности войдите заново и повторите" },
	["auth.err.already_linked"] = { en = "This account is already linked to another player", ru = "Этот аккаунт уже привязан к другому игроку" },
	["auth.err.too_many"] = { en = "Too many attempts. Wait a little", ru = "Слишком много попыток. Подождите" },
	["auth.err.not_enabled"] = { en = "This way of signing in is not turned on yet", ru = "Этот способ входа ещё не включён" },
	["auth.err.bad_domain"] = { en = "Sign-in is not set up for this site yet", ru = "Вход для этого сайта ещё не настроен" },
	["auth.err.denied"] = { en = "The server refused the request", ru = "Сервер отклонил запрос" },
	["auth.err.no_user"] = { en = "You are not signed in", ru = "Вы не вошли в аккаунт" },
	["auth.err.error"] = { en = "Something went wrong. Try again later", ru = "Что-то пошло не так. Попробуйте позже" },
	["cloud.status.off"] = { en = "Not signed in", ru = "Вход не выполнен" },
	["cloud.status.synced"] = { en = "Saved in the cloud", ru = "Сохранено в облаке" },
	["cloud.status.syncing"] = { en = "Saving to the cloud...", ru = "Сохраняем в облако..." },
	["cloud.status.offline"] = { en = "No connection: will try again", ru = "Нет соединения: повторим позже" },
	["cloud.status.error"] = { en = "Cloud error: will try again", ru = "Ошибка облака: повторим позже" },
	["cloud.status.paused"] = { en = "Cloud saving is paused", ru = "Сохранение в облако приостановлено" },
	["cloud.status.decision"] = { en = "Choose which save to keep", ru = "Выберите, какое сохранение оставить" },
	["cloud.sum"] = { en = "Levels {n}, coins {coins}, stars {stars}", ru = "Уровней {n}, монет {coins}, звёзд {stars}" },
	["cloud.this_device"] = { en = "This device", ru = "Это устройство" },
	["cloud.account"] = { en = "Your account", ru = "Ваш аккаунт" },
	["cloud.more_progress"] = { en = "More progress", ru = "Прогресс больше" },
	["cloud.title.offer_upload"] = { en = "Save this progress?", ru = "Сохранить этот прогресс?" },
	["cloud.text.offer_upload"] = { en = "This device is further along than your account. Upload it to the cloud?", ru = "На этом устройстве прогресс больше, чем в аккаунте. Загрузить его в облако?" },
	["cloud.title.offer_download"] = { en = "Use the cloud save?", ru = "Взять облачное сохранение?" },
	["cloud.text.offer_download"] = { en = "Your account has more progress than this device. Take it? Progress here is kept as a backup.", ru = "В аккаунте прогресс больше, чем на этом устройстве. Взять его? Прогресс здесь останется в запасе." },
	["cloud.title.choose"] = { en = "Which game to keep?", ru = "Какую игру оставить?" },
	["cloud.text.choose"] = { en = "This device and your account hold different games. The one you do not choose is kept as a backup.", ru = "На устройстве и в аккаунте разные игры. Та, что не выбрана, останется в запасе." },
	["cloud.title.foreign"] = { en = "Another account's save", ru = "Сохранение другого аккаунта" },
	["cloud.text.foreign"] = { en = "The save on this device belongs to another account and is not mixed with this one.", ru = "Сохранение на этом устройстве принадлежит другому аккаунту и не смешивается с этим." },
	["cloud.text.damaged"] = { en = "The save in the cloud is damaged and was not used. Upload the progress from this device?", ru = "Сохранение в облаке повреждено, его не использовали. Загрузить прогресс с этого устройства?" },
	["cloud.do_upload"] = { en = "Save to the cloud", ru = "Сохранить в облако" },
	["cloud.do_download"] = { en = "Use cloud save", ru = "Взять из облака" },
	["cloud.keep_device"] = { en = "Keep this device", ru = "Оставить это устройство" },
	["cloud.keep_cloud"] = { en = "Use the cloud save", ru = "Взять облачное" },
	["cloud.start_new"] = { en = "Start a new game", ru = "Начать новую игру" },
	["cloud.bring_device"] = { en = "Bring this device's progress", ru = "Перенести прогресс с устройства" },
	["cloud.later"] = { en = "Not now", ru = "Не сейчас" },
	["cloud.loaded"] = { en = "Progress loaded", ru = "Прогресс загружен" },
	["cloud.uploading"] = { en = "Saving to the cloud...", ru = "Сохраняем в облако..." },
	["cloud.err_write"] = { en = "Could not write the save on this device. Nothing was changed", ru = "Не удалось записать сохранение на устройстве. Ничего не изменено" },

	-- META SCREENS: splash, town, start window, lives, shop, settings, jukebox, chests and gifts, the
	-- district concert, toasts. Owner: screens/town, screens/splash, gui/*.lua, main/overlay.gui_script.
	-- Strings of those screens are added here and nowhere else (the level screen has its own block).
	-- ============================================================================================================

	-- splash and load notices ------------------------------------------------------------------------------------------
	["splash.tagline"] = { en = "Match. Play. Light up the town!", ru = "Собирай. Играй. Зажигай город!" },
	["splash.loading"] = { en = "Tuning up…", ru = "Настраиваем инструменты…" },
	["splash.restored"] = {
		en = "Your progress was restored from a backup",
		ru = "Прогресс восстановлен из резервной копии",
	},
	["splash.interrupted"] = {
		en = "The last level was interrupted and counted as a loss",
		ru = "Прошлый уровень прерван и засчитан как поражение",
	},
	["splash.cancelled"] = {
		en = "The last level was closed before your first move: nothing was lost",
		ru = "Прошлый уровень закрыт до первого хода: ничего не потеряно",
	},
	["splash.save_lost"] = {
		en = "Your saved progress could not be read, so the game starts over",
		ru = "Не удалось прочитать сохранение, игра начинается заново",
	},
	["splash.newer"] = {
		en = "Your progress comes from a newer version of the game",
		ru = "Прогресс сохранён более новой версией игры",
	},
	["splash.gift"] = { en = "Gift: {name} boosters!", ru = "Подарок: бустеры «{name}»!" },
	["splash.chest"] = { en = "{name}: the district chest is yours!", ru = "{name}: сундук района твой!" },

	-- map (screens/map) ------------------------------------------------------------------------------------------------
	["map.title"] = { en = "Map", ru = "Карта" },
	["map.button"] = { en = "Map", ru = "Карта" },
	["map.back"] = { en = "Town", ru = "Город" },
	["map.to_current"] = { en = "My level", ru = "К моему уровню" },
	["map.locked"] = { en = "Opens after level {n}", ru = "Откроется после уровня {n}" },
	["map.soon"] = { en = "New levels soon!", ru = "Скоро новые уровни!" },
	["map.soon_text"] = {
		en = "Play the beaten levels again to win more stars.",
		ru = "Пройденные уровни можно сыграть снова ради звёзд.",
	},
	["win.map"] = { en = "To the map", ru = "На карту" },
	["start.replay"] = { en = "Play again", ru = "Играть снова" },
	["start.replay_text"] = {
		en = "Beat your best for more stars. No coins or lives are spent.",
		ru = "Побей свой рекорд ради звёзд. Монеты и жизни не тратятся.",
	},
	["start.best_score"] = { en = "Best score: {n}", ru = "Рекорд: {n}" },

	-- town: top bar, task card, level button, navigation, hints --------------------------------------------------------
	["town.level"] = { en = "Level {n}", ru = "Уровень {n}" },
	["town.hard"] = { en = "Hard", ru = "Сложный" },
	["town.super_hard"] = { en = "Super Hard", ru = "Суперсложный" },
	["town.all_done"] = { en = "More levels coming soon!", ru = "Скоро новые уровни!" },
	["town.task_ready"] = { en = "Tap to build!", ru = "Нажми, чтобы построить!" },
	["town.task_need"] = {
		en = { one = "Need {n} more star", other = "Need {n} more stars" },
		ru = { one = "Нужна ещё {n} звезда", few = "Нужно ещё {n} звезды", many = "Нужно ещё {n} звёзд" },
	},
	["town.town_done"] = { en = "The whole town is shining!", ru = "Весь город сияет!" },
	["town.new_district"] = { en = "New district: {name}", ru = "Открыт новый район: {name}" },
	["town.day"] = { en = "Day", ru = "День" },
	["town.concert"] = { en = "Concert", ru = "Концерт" },
	["town.lives_full"] = { en = "Full", ru = "Макс." },
	["town.layers"] = { en = "Track layers: {done}/{total}", ru = "Слоёв трека: {done} из {total}" },
	["town.task_adds"] = { en = "Adds {stem} to the track", ru = "Добавит в трек: {stem}" },
	["town.layer_added"] = { en = "+ {stem}!", ru = "+ {stem}!" },
	["town.stars_hint"] = { en = "Win levels to earn stars", ru = "Звёзды дают за победы в уровнях" },
	["town.super_stars_hint"] = {
		en = "Super stars: {n}. Concert levels give them. What they buy comes soon.",
		ru = "Суперзвёзды: {n}. Их дают уровни-концерты. На что их тратить, скоро узнаем.",
	},
	["town.item_wait"] = { en = "{item}: coming soon to the track", ru = "{item}: скоро зазвучит в треке" },
	["town.back_to"] = { en = "Back to {name}", ru = "Назад: {name}" },
	["nav.shop"] = { en = "Shop", ru = "Магазин" },
	["nav.band"] = { en = "Band", ru = "Группа" },
	["nav.town"] = { en = "Town", ru = "Город" },
	["nav.chart"] = { en = "Chart", ru = "Чарт" },
	["nav.jukebox"] = { en = "Jukebox", ru = "Автомат" },
	["nav.soon"] = { en = "Soon", ru = "Скоро" },
	["tutorial.town"] = {
		en = "Spend stars to bring the town back to life",
		ru = "Трать звёзды, чтобы вернуть городу жизнь",
	},

	-- lives window -----------------------------------------------------------------------------------------------------
	["lives.title"] = { en = "Lives", ru = "Жизни" },
	["lives.next_in"] = { en = "Next life in {time}", ru = "Следующая жизнь через {time}" },
	["lives.full"] = { en = "All lives are here!", ru = "Все жизни на месте!" },
	["lives.refill"] = { en = "Refill for {price}", ru = "Пополнить за {price}" },
	["lives.infinite"] = { en = "Unlimited lives: {time}", ru = "Бесконечные жизни: {time}" },
	["lives.free_levels"] = { en = "Levels 1–{n} don't cost lives", ru = "Уровни 1–{n} не тратят жизни" },
	["lives.refilled"] = { en = "Lives refilled!", ru = "Жизни пополнены!" },
	["lives.get_coins"] = { en = "Get coins", ru = "Взять монеты" },
	["lives.wait"] = { en = "…or wait for a new life", ru = "…или подожди новую жизнь" },
	["lives.play_free"] = { en = "Unlimited lives are on: play as much as you like!", ru = "Жизни бесконечны: играй сколько хочешь!" },
	["lives.rule"] = {
		en = { one = "A new life every {n} minute", other = "A new life every {n} minutes" },
		ru = { one = "Новая жизнь каждую {n} минуту", few = "Новая жизнь каждые {n} минуты", many = "Новая жизнь каждые {n} минут" },
	},

	-- start window -----------------------------------------------------------------------------------------------------
	["start.title"] = { en = "Level {n}", ru = "Уровень {n}" },
	["start.goals"] = { en = "Goals", ru = "Цели" },
	["start.boosters"] = { en = "Boosters", ru = "Бустеры" },
	["start.streak"] = { en = "Hit streak", ru = "Серия хитов" },
	["start.locked"] = { en = "Unlocks at level {n}", ru = "Откроется на уровне {n}" },
	["start.no_lives"] = { en = "You need a life to play", ru = "Для игры нужна жизнь" },
	["start.play"] = { en = "Play", ru = "Играть" },
	["start.run_active"] = { en = "Finish the level in progress first", ru = "Сначала доиграй начатый уровень" },
	["start.not_next"] = { en = "Play the levels in order", ru = "Уровни проходятся по порядку" },
	["start.free"] = { en = "FREE", ru = "ДАРОМ" },
	["start.free_hint"] = { en = "Free from your hit streak!", ru = "Бесплатно за серию хитов!" },
	["start.all"] = { en = "all", ru = "все" },
	["start.life_cost"] = { en = "A loss costs a life", ru = "Поражение отнимет жизнь" },
	["start.pick_hint"] = { en = "Tap a booster to take it along", ru = "Нажми на бустер, чтобы взять его" },
	["start.no_goals"] = { en = "Goals will be shown in the level", ru = "Цели покажем в уровне" },
	["start.safe"] = { en = "A loss costs nothing here", ru = "Поражение здесь ничего не стоит" },
	["start.streak_from"] = { en = "The hit streak starts at level {n}", ru = "Серия хитов начнётся с уровня {n}" },
	["start.selected"] = { en = "Taking {name} along!", ru = "Берём с собой: {name}!" },

	-- district concert and rewards brought back to the town ------------------------------------------------------------
	["concert.skip"] = { en = "Tap to skip", ru = "Нажми, чтобы пропустить" },
	["concert.subtitle"] = { en = "The whole street sings along!", ru = "Вся улица подпевает!" },
	["reward.stars"] = {
		en = { one = "+{n} star", other = "+{n} stars" },
		ru = { one = "+{n} звезда", few = "+{n} звезды", many = "+{n} звёзд" },
	},
	["reward.coins"] = {
		en = { one = "+{n} coin", other = "+{n} coins" },
		ru = { one = "+{n} монета", few = "+{n} монеты", many = "+{n} монет" },
	},
	["reward.streak"] = { en = "Hit streak ×{n}!", ru = "Серия хитов ×{n}!" },
	["reward.streak_lost"] = { en = "Hit streak lost", ru = "Серия хитов сгорела" },
	["reward.life_lost"] = { en = "−1 life", ru = "−1 жизнь" },
	["reward.chest_level"] = { en = "Level {n} chest!", ru = "Сундук уровня {n}!" },
	["reward.chest_district"] = { en = "{name}: district chest!", ru = "{name}: сундук района!" },
	["district.concert"] = { en = "{name}: concert!", ru = "{name}: концерт!" },

	-- chest and unlock gift --------------------------------------------------------------------------------------------
	["chest.infinite"] = { en = "+{time} of unlimited lives", ru = "+{time} бесконечных жизней" },
	["chest.tap"] = { en = "Tap the chest!", ru = "Нажми на сундук!" },
	["chest.level"] = { en = "Level chest", ru = "Сундук уровня" },
	["gift.title"] = { en = "New booster!", ru = "Новый бустер!" },
	["gift.tap"] = { en = "Tap the gift!", ru = "Нажми на подарок!" },

	-- shop -------------------------------------------------------------------------------------------------------------
	["shop.title"] = { en = "Shop", ru = "Магазин" },
	["shop.pack"] = { en = "{n} × {name}", ru = "{n} × {name}" },
	["shop.lives"] = { en = "Lives", ru = "Жизни" },
	["shop.coins"] = { en = "Coins", ru = "Монеты" },
	["shop.bought"] = { en = "Purchased!", ru = "Куплено!" },
	["shop.iap_unavailable"] = {
		en = "Purchases are not available in the web demo",
		ru = "Покупки недоступны в веб-демо",
	},
	["shop.starter_pack"] = { en = "Starter pack", ru = "Стартовый набор" },
	["shop.coins_small"] = { en = "Handful of coins", ru = "Горсть монет" },
	["shop.coins_medium"] = { en = "Bag of coins", ru = "Мешок монет" },
	["shop.coins_large"] = { en = "Chest of coins", ru = "Сундук монет" },
	["shop.piggy_bank"] = { en = "Piggy bank", ru = "Копилка" },
	["shop.tab_boosters"] = { en = "Boosters", ru = "Бустеры" },
	["shop.tab_coins"] = { en = "Coins", ru = "Монеты" },
	["shop.refill"] = { en = "Refill lives", ru = "Пополнить жизни" },
	["shop.gift"] = { en = "Free gift", ru = "Подарок" },
	["shop.gift_desc"] = { en = "Watch a video", ru = "Посмотри видео" },
	["shop.gift_got"] = { en = "Gift: +{n} coins!", ru = "Подарок: +{n} монет!" },
	["shop.pack_got"] = { en = "+{n} {name}!", ru = "+{n} {name}!" },
	["shop.debug_grant"] = { en = "Test purchase (debug build)", ru = "Тестовая покупка (отладка)" },
	["shop.minutes"] = { en = "+{n} min", ru = "+{n} мин" },
	["shop.owned"] = { en = "You have: {n}", ru = "У тебя: {n}" },
	["shop.demo"] = { en = "Web demo: store purchases are turned off", ru = "Веб-демо: покупки в магазине отключены" },
	["shop.best"] = { en = "BEST", ru = "ХИТ" },
	["shop.gift_wait"] = { en = "Next gift in {time}", ru = "Следующий подарок через {time}" },
	["shop.gift_unavailable"] = { en = "No videos in the web demo", ru = "В веб-демо нет видео" },
	["shop.lives_full"] = { en = "Lives are full", ru = "Жизни полные" },
	["shop.infinite_on"] = { en = "Unlimited lives are on", ru = "Жизни бесконечны" },

	-- settings ---------------------------------------------------------------------------------------------------------
	["settings.account_guest"] = { en = "Guest", ru = "Гость" },
	["settings.account_user"] = { en = "Account: {name}", ru = "Аккаунт: {name}" },
	["settings.title"] = { en = "Settings", ru = "Настройки" },
	["settings.music"] = { en = "Music", ru = "Музыка" },
	["settings.sfx"] = { en = "Sounds", ru = "Звуки" },
	["settings.haptics"] = { en = "Vibration", ru = "Вибрация" },
	["settings.reduced_motion"] = { en = "Reduced motion", ru = "Меньше движения" },
	["settings.input_mode"] = { en = "Controls", ru = "Управление" },
	["settings.input_swipe"] = { en = "Swipe", ru = "Свайп" },
	["settings.input_taptap"] = { en = "Tap-tap", ru = "Тап-тап" },
	["settings.language"] = { en = "Language", ru = "Язык" },
	["settings.lang_auto"] = { en = "Auto", ru = "Авто" },
	["settings.lang_en"] = { en = "English", ru = "English" },
	["settings.lang_ru"] = { en = "Русский", ru = "Русский" },
	["settings.lang_ko"] = { en = "한국어", ru = "한국어" },
	["settings.version"] = { en = "Version {v}", ru = "Версия {v}" },
	["settings.reset"] = { en = "Reset progress", ru = "Сбросить прогресс" },
	["settings.reset_title"] = { en = "Reset progress?", ru = "Сбросить прогресс?" },
	["settings.reset_text"] = {
		en = "Levels, stars, coins and the whole town start over. This cannot be undone.",
		ru = "Уровни, звёзды, монеты и весь город начнутся заново. Отменить это нельзя.",
	},
	["settings.reset_do"] = { en = "Reset", ru = "Сбросить" },
	["settings.reset_done"] = { en = "Progress reset. Let's start again!", ru = "Прогресс сброшен. Начнём заново!" },
	["settings.code_section"] = { en = "Move your progress", ru = "Перенос прогресса" },
	["settings.code_copy"] = { en = "Copy save code", ru = "Скопировать код сохранения" },
	["settings.code_enter"] = { en = "Enter save code", ru = "Ввести код сохранения" },
	-- save code (meta/savecode.lua, client/app.lua) ------------------------------------
	["code.prompt_copy"] = {
		en = "Your save code. Copy it (Ctrl+C) and keep it safe:",
		ru = "Ваш код сохранения. Скопируйте его (Ctrl+C) и сохраните:",
	},
	["code.prompt_paste"] = { en = "Paste your save code here:", ru = "Вставьте сюда код сохранения:" },
	["code.copied"] = { en = "Save code copied", ru = "Код сохранения скопирован" },
	["code.shown"] = { en = "Copy the code from the box", ru = "Скопируйте код из окошка" },
	["code.copy_failed"] = { en = "Could not copy the code", ru = "Не удалось скопировать код" },
	["code.empty"] = { en = "No code received", ru = "Код не получен" },
	["code.err_prefix"] = { en = "This is not a GLOW save code", ru = "Это не код сохранения GLOW" },
	["code.err_version"] = { en = "The code is from another version of the game", ru = "Код от другой версии игры" },
	["code.err_damaged"] = {
		en = "The code is damaged or cut. Copy it again in full",
		ru = "Код испорчен или обрезан. Скопируйте его заново целиком",
	},
	["code.err_bad_save"] = { en = "The save inside the code is not valid", ru = "Сохранение внутри кода не подходит" },
	["code.confirm_title"] = { en = "Load this save?", ru = "Загрузить сохранение?" },
	["code.confirm_levels"] = { en = "Levels beaten: {n}", ru = "Пройдено уровней: {n}" },
	["code.confirm_coins"] = { en = "Coins: {n}", ru = "Монеты: {n}" },
	["code.confirm_stars"] = { en = "Stars: {n}", ru = "Звёзды: {n}" },
	["code.confirm_behind"] = {
		en = "Careful: this code holds LESS progress than you have now (levels {n}).",
		ru = "Осторожно: в коде МЕНЬШЕ прогресса, чем сейчас (уровней: {n}).",
	},
	["code.confirm_keep"] = {
		en = "Your current save is kept as a backup.",
		ru = "Текущее сохранение останется запасным.",
	},
	["code.confirm_do"] = { en = "Load", ru = "Загрузить" },
	["code.done"] = { en = "Progress loaded", ru = "Прогресс загружен" },
	["code.write_failed"] = { en = "Could not write the save. Nothing changed", ru = "Не удалось записать. Ничего не изменилось" },
	-- replay of beaten levels after the last one ---------------------------------------
	["replay.button"] = { en = "Play beaten levels", ru = "Пройденные уровни" },
	["replay.title"] = { en = "Play again", ru = "Играть снова" },
	["replay.text"] = {
		en = "More levels are coming soon! Replay any level: no coins and no lives are spent.",
		ru = "Скоро новые уровни! Пройдите любой уровень ещё раз: монеты и жизни не тратятся.",
	},
	["replay.page"] = { en = "{a}-{b}", ru = "{a}-{b}" },
	["win.practice"] = { en = "Practice: nothing is paid", ru = "Тренировка: награды нет" },
	["settings.sound"] = { en = "Sound", ru = "Звук" },
	["settings.game"] = { en = "Game", ru = "Игра" },

	-- jukebox ----------------------------------------------------------------------------------------------------------
	["jukebox.title"] = { en = "Jukebox", ru = "Музыкальный автомат" },
	["jukebox.layers"] = { en = "Layers: {done}/{total}", ru = "Слоёв: {done}/{total}" },
	["jukebox.locked"] = { en = "Build {name} to unlock", ru = "Восстанови район «{name}», чтобы открыть" },
	["jukebox.full_song"] = { en = "Full song", ru = "Полная песня" },
	["jukebox.now_playing"] = { en = "Now playing: {name}", ru = "Сейчас играет: {name}" },
	["jukebox.pick"] = { en = "Pick a song", ru = "Выбери песню" },
	["jukebox.no_layers"] = { en = "Build a task to hear it", ru = "Выполни задачу, чтобы услышать" },
	["jukebox.back_home"] = { en = "Return the town music", ru = "Вернуть музыку города" },

	-- jukebox songs: genre tabs, several songs each, the pick that stays --------------------------------------------------
	-- (the genre names and the song names come from content/districts.json: genre / songs[].name)
	["jukebox.bpm"] = { en = "{bpm} BPM", ru = "{bpm} уд/мин" },
	["jukebox.page"] = { en = "{page} / {pages}", ru = "{page} / {pages}" },
	["jukebox.already_home"] = { en = "The town music is playing", ru = "Сейчас играет музыка города" },

	-- toasts (overlay, debug keys) -------------------------------------------------------------------------------------
	["toast.coming_soon"] = { en = "Coming soon!", ru = "Скоро!" },
	["toast.saved_failed"] = {
		en = "Could not save progress. Trying again…",
		ru = "Не удалось сохранить прогресс. Пробуем ещё раз…",
	},
	["toast.saved_again"] = { en = "Progress saved", ru = "Прогресс сохранён" },
	["toast.language"] = { en = "Language: English", ru = "Язык: русский" },
	["toast.debug_coins"] = { en = "+{n} coins (debug)", ru = "+{n} монет (отладка)" },
	["toast.debug_reset"] = { en = "Save reset (debug)", ru = "Сохранение сброшено (отладка)" },
	-- ============================================================================================================
	-- songbook (WP-9): the notebook window, its button in the town and the line in the results ----------------------------
	["notebook.title"] = { en = "Songbook", ru = "Блокнот песен" },
	["notebook.levels"] = { en = "Levels {first}-{last}", ru = "Уровни {first}–{last}" },
	["notebook.verse"] = { en = "Verse {n}", ru = "Куплет {n}" },
	["notebook.chorus"] = { en = "Chorus", ru = "Припев" },
	["notebook.play"] = { en = "Listen", ru = "Прослушать" },
	["notebook.stop"] = { en = "Stop", ru = "Остановить" },
	["notebook.progress"] = { en = "Lines written: {n} of {total}", ru = "Записано строк: {n} из {total}" },
	["notebook.hint"] = { en = "Beat a level and Bit writes the next line", ru = "Пройди уровень, и Бит запишет следующую строку" },
	["win.song_line"] = { en = "Bit wrote a new line", ru = "Бит записал новую строку" },
	["win.song_ready"] = { en = "Your song is ready!", ru = "Твоя песня готова!" },
	["win.song_open"] = { en = "Listen", ru = "Слушать" },
	-- end of META SCREENS
	-- ============================================================================================================

	-- ============================================================================================================
	-- chart and band (WP-11): the nouns and adjectives of the game names are in social.adj.* / social.noun.*
	-- ============================================================================================================
	["social.adj.1"] = { en = "Bright", ru = "Светлый" },
	["social.adj.2"] = { en = "Loud", ru = "Громкий" },
	["social.adj.3"] = { en = "Night", ru = "Ночной" },
	["social.adj.4"] = { en = "Happy", ru = "Весёлый" },
	["social.adj.5"] = { en = "Quick", ru = "Быстрый" },
	["social.adj.6"] = { en = "Golden", ru = "Золотой" },
	["social.adj.7"] = { en = "Quiet", ru = "Тихий" },
	["social.adj.8"] = { en = "Vivid", ru = "Яркий" },
	["social.adj.9"] = { en = "Dancing", ru = "Танцующий" },
	["social.adj.10"] = { en = "Starry", ru = "Звёздный" },
	["social.adj.11"] = { en = "Neon", ru = "Неоновый" },
	["social.adj.12"] = { en = "Soft", ru = "Мягкий" },
	["social.adj.13"] = { en = "Brave", ru = "Смелый" },
	["social.adj.14"] = { en = "Friendly", ru = "Дружный" },
	["social.adj.15"] = { en = "Sunny", ru = "Солнечный" },
	["social.adj.16"] = { en = "Cosmic", ru = "Космический" },
	["social.noun.1"] = { en = "Beat", ru = "Бит" },
	["social.noun.2"] = { en = "Rhythm", ru = "Ритм" },
	["social.noun.3"] = { en = "Bass", ru = "Бас" },
	["social.noun.4"] = { en = "Hit", ru = "Хит" },
	["social.noun.5"] = { en = "Sound", ru = "Звук" },
	["social.noun.6"] = { en = "Dance", ru = "Танец" },
	["social.noun.7"] = { en = "Tone", ru = "Тон" },
	["social.noun.8"] = { en = "Melody", ru = "Мотив" },
	["social.noun.9"] = { en = "Clip", ru = "Клип" },
	["social.noun.10"] = { en = "Vibe", ru = "Вайб" },
	["social.noun.11"] = { en = "DJ", ru = "Диджей" },
	["social.noun.12"] = { en = "Spotlight", ru = "Прожектор" },
	["social.noun.13"] = { en = "Boombox", ru = "Бумбокс" },
	["social.noun.14"] = { en = "Synth", ru = "Синтезатор" },
	["social.noun.15"] = { en = "Groove", ru = "Грув" },
	["social.noun.16"] = { en = "Band", ru = "Ансамбль" },
	["chart.title"] = { en = "Chart", ru = "Чарт" },
	["chart.week"] = { en = "Week", ru = "Неделя" },
	["chart.all"] = { en = "All time", ru = "Всё время" },
	["chart.band"] = { en = "My band", ru = "Группа" },
	["chart.loading"] = { en = "Loading the chart…", ru = "Загружаем чарт…" },
	["chart.unavailable"] = { en = "The chart is not connected yet. Your stars are safe and will count when it opens.", ru = "Чарт ещё не подключён. Твои звёзды сохранены и пойдут в зачёт, когда он откроется." },
	["chart.signin"] = { en = "Sign in to see the chart and play with other players.", ru = "Войди, чтобы увидеть чарт и играть вместе с другими." },
	["chart.signin_button"] = { en = "Sign in", ru = "Войти" },
	["chart.offline"] = { en = "No connection. Try again when you are online.", ru = "Нет связи. Попробуй ещё раз, когда появится сеть." },
	["chart.error"] = { en = "Something went wrong. Try again in a minute.", ru = "Что-то пошло не так. Попробуй ещё раз через минуту." },
	["chart.empty"] = { en = "Nobody here yet.", ru = "Здесь пока никого нет." },
	["chart.no_band"] = { en = "Join a band to see your friends here.", ru = "Вступи в группу, чтобы видеть здесь друзей." },
	["chart.checking"] = { en = "We are checking your result. It is hidden from others for now.", ru = "Проверяем твой результат. Пока другие его не видят." },
	["chart.players"] = { en = "Players: {n}", ru = "Игроков: {n}" },
	["chart.week_left"] = { en = "The week ends in {time}", ru = "До конца недели: {time}" },
	["chart.rename"] = { en = "Change name", ru = "Сменить имя" },
	["social.profile_text"] = { en = "Pick your game name and avatar. Other players see only these.", ru = "Выбери игровое имя и аватар. Другие игроки видят только их." },
	["social.other_name"] = { en = "Another name", ru = "Другое имя" },
	["social.pick_avatar"] = { en = "Avatar", ru = "Аватар" },
	["social.profile_privacy"] = { en = "No real name, no e-mail: they are never shown.", ru = "Настоящее имя и почта никому не показываются." },
	["social.left_dh"] = { en = "{d}d {h}h", ru = "{d} дн {h} ч" },
	["social.left_hm"] = { en = "{h}h {m}m", ru = "{h} ч {m} мин" },
	["social.err.bad_name"] = { en = "Pick a name from the list.", ru = "Выбери имя из списка." },
	["social.err.bad_avatar"] = { en = "Pick an avatar from the set.", ru = "Выбери аватар из набора." },
	["social.err.bad_code"] = { en = "That code does not look right. It has 6 letters and digits.", ru = "Код не похож на настоящий: в нём 6 букв и цифр." },
	["social.err.no_such_band"] = { en = "No band with this code.", ru = "Нет группы с таким кодом." },
	["social.err.full"] = { en = "This band is full.", ru = "В группе нет мест." },
	["social.err.already_in_band"] = { en = "You are already in a band.", ru = "Ты уже в группе." },
	["social.err.no_band"] = { en = "You are not in a band.", ru = "Ты не в группе." },
	["social.err.not_leader"] = { en = "Only the leader can do this.", ru = "Это может только лидер." },
	["social.err.bad_target"] = { en = "That does not work for this player.", ru = "С этим игроком так нельзя." },
	["social.err.not_member"] = { en = "This player has left the band.", ru = "Этот игрок уже вышел из группы." },
	["social.err.no_profile"] = { en = "Pick a game name first.", ru = "Сначала выбери игровое имя." },
	["social.err.limit"] = { en = "That is enough for today. Try tomorrow.", ru = "На сегодня хватит. Попробуй завтра." },
	["social.err.not_requested"] = { en = "This player did not ask for help.", ru = "Этот игрок не просил помощи." },
	["social.err.already_sent"] = { en = "You already helped this player.", ru = "Ты уже помог этому игроку." },
	["social.err.denied"] = { en = "The server said no.", ru = "Сервер отказал." },
	["social.err.offline"] = { en = "No connection.", ru = "Нет связи." },
	["social.err.timeout"] = { en = "The server is slow. Try again.", ru = "Сервер отвечает долго. Попробуй ещё раз." },
	["social.err.signin"] = { en = "Sign in first.", ru = "Сначала войди в аккаунт." },
	["social.err.unavailable"] = { en = "Not available yet.", ru = "Пока недоступно." },
	["social.err.busy"] = { en = "One moment…", ru = "Секунду…" },
	["social.err.error"] = { en = "Something went wrong.", ru = "Что-то пошло не так." },
	["band.title"] = { en = "Band", ru = "Группа" },
	["band.loading"] = { en = "Loading your band…", ru = "Загружаем группу…" },
	["band.unavailable"] = { en = "Bands are not connected yet. They will open together with the chart.", ru = "Группы ещё не подключены. Они откроются вместе с чартом." },
	["band.signin"] = { en = "Sign in to make a band or join one.", ru = "Войди, чтобы создать группу или вступить в неё." },
	["band.none"] = { en = "You are not in a band yet. Make one or join with a code from a friend.", ru = "Ты пока не в группе. Создай свою или вступи по коду друга." },
	["band.create"] = { en = "Make a band", ru = "Создать группу" },
	["band.join"] = { en = "Join with a code", ru = "Вступить по коду" },
	["band.join_hint"] = { en = "Up to 20 players. Together you collect stars for a weekly goal.", ru = "До 20 игроков. Вместе вы копите звёзды на недельную цель." },
	["band.create_text"] = { en = "Pick a name for your band. You can change it with the button.", ru = "Выбери название группы. Его можно сменить кнопкой." },
	["band.other_name"] = { en = "Another name", ru = "Другое название" },
	["band.create_do"] = { en = "Make it!", ru = "Создать!" },
	["band.code"] = { en = "Code: {code}", ru = "Код: {code}" },
	["band.members"] = { en = "{n} of {max}", ru = "{n} из {max}" },
	["band.goal"] = { en = "Weekly goal: {n} of {goal} stars", ru = "Цель недели: {n} из {goal} звёзд" },
	["band.goal_done"] = { en = "Goal reached: {n} stars!", ru = "Цель выполнена: {n} звёзд!" },
	["band.leader"] = { en = "Leader", ru = "Лидер" },
	["band.member"] = { en = "Member", ru = "Участник" },
	["band.needs_life"] = { en = "Asks for a life", ru = "Просит жизнь" },
	["band.waiting_help"] = { en = "You asked for a life. Waiting for a mate.", ru = "Ты попросил жизнь. Ждём, пока кто-то поможет." },
	["band.ask_life"] = { en = "Ask for a life", ru = "Попросить жизнь" },
	["band.invite"] = { en = "Invite", ru = "Пригласить" },
	["band.leave"] = { en = "Leave", ru = "Выйти" },
	["band.leave_title"] = { en = "Leave the band?", ru = "Выйти из группы?" },
	["band.leave_text"] = { en = "Your stars stay yours. You can join again with the code.", ru = "Твои звёзды останутся с тобой. Вернуться можно по коду." },
	["band.leave_leader"] = { en = "You are the leader. The member who joined first becomes the leader.", ru = "Ты лидер. Лидером станет тот, кто вступил раньше всех." },
	["band.kick_title"] = { en = "Remove the member?", ru = "Исключить участника?" },
	["band.kick_text"] = { en = "They can join again with the code.", ru = "Он сможет вернуться по коду." },
	["band.kick_do"] = { en = "Remove", ru = "Исключить" },
	["band.invite_text"] = { en = "Join my band in GLOW! Code: {code}", ru = "Вступай в мою группу в GLOW! Код: {code}" },
	["band.prompt_copy"] = { en = "Copy the invitation:", ru = "Скопируй приглашение:" },
	["band.prompt_code"] = { en = "Paste the band code:", ru = "Вставь код группы:" },
	["band.copied"] = { en = "Invitation copied", ru = "Приглашение скопировано" },
	["band.shown"] = { en = "Copy the invitation from the box", ru = "Скопируй приглашение из окошка" },
	["band.copy_failed"] = { en = "Could not copy the invitation", ru = "Не удалось скопировать приглашение" },
	["band.lives_got"] = { en = "Band mates sent you {n} lives", ru = "Друзья из группы прислали жизней: {n}" },

}

-- The songbook lines and titles (meta/songbook.lua): entries with en, ru and ko already in them.
for key, entry in pairs(require("client.i18n_songbook")) do
	S[key] = entry
end

-- Korean texts: same keys, merged as the `ko` field (key order does not matter).
for key, text in pairs(require("client.i18n_ko")) do
	if S[key] then S[key].ko = text end
end

M.STRINGS = S

local current = M.FALLBACK

-- Plural category of n for a language (CLDR rules for integers).
function M.plural_form(lang, n)
	n = math.abs(math.floor(tonumber(n) or 0))
	if lang == "ru" then
		local m10, m100 = n % 10, n % 100
		if m10 == 1 and m100 ~= 11 then return "one" end
		if m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14) then return "few" end
		return "many"
	end
	return n == 1 and "one" or "other"
end

-- "ru", "ru-RU", "ru_RU", "RU" -> "ru"; anything unsupported -> nil.
function M.normalize(lang)
	if type(lang) ~= "string" then return nil end
	local code = string.lower(string.match(lang, "^%a%a") or "")
	for _, l in ipairs(M.LANGUAGES) do
		if l == code then return l end
	end
	return nil
end

-- Language from the system language string (sys.get_sys_info().language).
function M.detect(sys_language)
	return M.normalize(sys_language) or M.FALLBACK
end

-- setting: "auto" | "en" | "ru" (meta setting `language`); sys_language is
-- used for "auto". Returns the language now in use.
function M.set_language(setting, sys_language)
	if setting == nil or setting == "auto" then
		current = M.detect(sys_language)
	else
		current = M.normalize(setting) or M.detect(sys_language)
	end
	return current
end

function M.language()
	return current
end

function M.has(key)
	return S[key] ~= nil
end

-- Replaces {name} with tostring(vars.name). Unknown placeholders stay as they are.
function M.format(str, vars)
	if not vars then return str end
	return (string.gsub(str, "{([%w_]+)}", function(k)
		local v = vars[k]
		if v == nil then return nil end
		return tostring(v)
	end))
end

local function pick(entry, lang)
	return entry[lang] or entry[M.FALLBACK]
end

-- Translated string for key. Plural entries use vars.n. A missing key returns
-- the key itself so the gap is visible on screen, never a crash.
function M.t(key, vars, lang)
	local entry = S[key]
	if not entry then return key end
	lang = lang or current
	local v = pick(entry, lang)
	if type(v) == "table" then
		local n = vars and (vars.n or vars.count) or 0
		local form = M.plural_form(lang, n)
		v = v[form] or v.other or v.many or v.one
	end
	return M.format(v, vars)
end

-- Resolves a UI text spec at display time, so it follows the language:
--   "plain text"                         -> as is
--   {text = "plain"}                     -> as is
--   {key = "town.level", vars = {n = 3}} -> i18n.t with the vars, where a var
--       may itself be a localized table {en, ru} (a content name) or
--       {key = ..., vars = ...} (a nested translation)
function M.tr(spec)
	if type(spec) ~= "table" then return spec ~= nil and tostring(spec) or "" end
	if spec.lines then -- {lines = {spec, spec, ...}}: one per line
		local out = {}
		for i, l in ipairs(spec.lines) do out[i] = M.tr(l) end
		return table.concat(out, "\n")
	end
	if spec.key == nil then
		if spec.text ~= nil then return tostring(spec.text) end
		return M.name(spec)
	end
	local vars = spec.vars
	if type(vars) == "table" then
		local out = {}
		for k, v in pairs(vars) do
			if type(v) == "table" then out[k] = v.key and M.tr(v) or M.name(v) else out[k] = v end
		end
		vars = out
	end
	return M.t(spec.key, vars)
end

-- Localized name from a table like {en = "...", ru = "..."} (districts.json).
function M.name(tbl, lang)
	if type(tbl) ~= "table" then return tostring(tbl) end
	lang = lang or current
	return tbl[lang] or tbl[M.FALLBACK] or ""
end

-- Integer with thousands separators: 1,050 (en) / 1 050 (ru, no-break space).
function M.number(n, lang)
	lang = lang or current
	n = math.floor((tonumber(n) or 0) + 0.5)
	local sign = n < 0 and "-" or ""
	local s = tostring(math.abs(n))
	local sep = lang == "ru" and "\194\160" or ","
	local out = s
	if #s > 3 then
		local parts = {}
		local head = #s % 3
		if head > 0 then parts[#parts + 1] = string.sub(s, 1, head) end
		for i = head + 1, #s, 3 do
			parts[#parts + 1] = string.sub(s, i, i + 2)
		end
		out = table.concat(parts, sep)
	end
	return sign .. out
end

local function two(n)
	return string.format("%02d", n)
end

-- Timer text: "4:05" under an hour, "1:04:05" above.
function M.duration(seconds)
	seconds = math.max(0, math.ceil(tonumber(seconds) or 0))
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	local s = seconds % 60
	if h > 0 then return M.t("time.hms", { h = h, m = two(m), s = two(s) }) end
	return M.t("time.ms", { m = m, s = two(s) })
end

-- Longer spans in words: "45 min", "1 h 20 min".
function M.duration_words(seconds)
	return M.tr(M.duration_words_spec(seconds))
end

-- The same as a text spec for M.tr (follows later language changes).
function M.duration_words_spec(seconds)
	seconds = math.max(0, math.ceil(tonumber(seconds) or 0))
	local total_min = math.ceil(seconds / 60)
	local h, m = math.floor(total_min / 60), total_min % 60
	if h > 0 then return { key = "time.hm", vars = { h = h, m = m } } end
	return { key = "time.min", vars = { m = m } }
end

-- Every distinct character used by the strings (for font glyph checks).
function M.charset()
	local seen, list = {}, {}
	local function add(s)
		for ch in string.gmatch(s, "[%z\1-\127\194-\244][\128-\191]*") do
			if not seen[ch] then
				seen[ch] = true
				list[#list + 1] = ch
			end
		end
	end
	local keys = {}
	for k in pairs(S) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do
		for _, lang in ipairs(M.LANGUAGES) do
			local v = S[k][lang]
			if type(v) == "table" then
				local forms = {}
				for f in pairs(v) do forms[#forms + 1] = f end
				table.sort(forms)
				for _, f in ipairs(forms) do add(v[f]) end
			elseif v then
				add(v)
			end
		end
	end
	table.sort(list)
	return list
end

return M
