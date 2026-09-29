-- UI strings in English and Russian + formatting helpers (pure Lua).
--
--   local i18n = require("client.i18n")
--   i18n.set_language("auto", sys.get_sys_info().language)  -- setting from the meta
--   i18n.t("town.level", {n = 12})              --> "Level 12" / "Уровень 12"
--   i18n.t("win.coins", {n = 3})                --> plural form picked by n
--   i18n.number(1050)                           --> "1,050" / "1 050"
--   i18n.duration(125)                          --> "2:05"
--   i18n.name({en = "Jazz Bar", ru = "Джаз-бар"}) --> by current language
--
-- Every entry holds both languages side by side, so a missing translation is
-- visible in review and caught by tests/client/i18n_test.lua. A value is a
-- string with {placeholders} or, for counted phrases, a plural table:
-- en {one, other}; ru {one, few, many} (1 звезда, 2 звезды, 5 звёзд).
-- Glyphs used here must exist in the generated fonts (tools/gen_defold.py
-- builds Latin + Cyrillic + the punctuation below).

local M = {}

M.LANGUAGES = { "en", "ru" }
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

	-- loader / splash -------------------------------------------------------------
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

	-- town --------------------------------------------------------------------------
	["town.level"] = { en = "Level {n}", ru = "Уровень {n}" },
	["town.hard"] = { en = "Hard", ru = "Сложный" },
	["town.super_hard"] = { en = "Super Hard", ru = "Суперсложный" },
	["town.all_done"] = { en = "More levels coming soon!", ru = "Скоро новые уровни!" },
	["town.task_unlocks"] = { en = "New layer: {stem}", ru = "Новый слой: {stem}" },
	["town.task_ready"] = { en = "Tap to build!", ru = "Нажми, чтобы построить!" },
	["town.task_need"] = {
		en = { one = "Need {n} more star", other = "Need {n} more stars" },
		ru = { one = "Нужна ещё {n} звезда", few = "Нужно ещё {n} звезды", many = "Нужно ещё {n} звёзд" },
	},
	["town.task_done"] = { en = "{item} is back!", ru = "{item} на месте!" },
	["town.district_done"] = { en = "District complete!", ru = "Район восстановлен!" },
	["town.town_done"] = { en = "The whole town is shining!", ru = "Весь город сияет!" },
	["town.new_district"] = { en = "New district: {name}", ru = "Открыт новый район: {name}" },
	["town.day"] = { en = "Day", ru = "День" },
	["town.concert"] = { en = "Concert", ru = "Концерт" },
	["town.lives_full"] = { en = "Full", ru = "Макс." },
	["town.layers"] = { en = "Track layers: {done}/{total}", ru = "Слоёв трека: {done} из {total}" },
	["town.task_adds"] = { en = "Adds {stem} to the track", ru = "Добавит в трек: {stem}" },
	["town.layer_added"] = { en = "+ {stem}!", ru = "+ {stem}!" },
	["town.stars_hint"] = { en = "Win levels to earn stars", ru = "Звёзды дают за победы в уровнях" },
	["town.bit_hi"] = { en = "Let's make some noise!", ru = "Зажжём!" },
	["nav.shop"] = { en = "Shop", ru = "Магазин" },
	["nav.band"] = { en = "Band", ru = "Группа" },
	["nav.town"] = { en = "Town", ru = "Город" },
	["nav.chart"] = { en = "Chart", ru = "Чарт" },
	["nav.jukebox"] = { en = "Jukebox", ru = "Автомат" },
	["nav.soon"] = { en = "Soon", ru = "Скоро" },

	-- lives window --------------------------------------------------------------------
	["lives.title"] = { en = "Lives", ru = "Жизни" },
	["lives.next_in"] = { en = "Next life in {time}", ru = "Следующая жизнь через {time}" },
	["lives.full"] = { en = "All lives are here!", ru = "Все жизни на месте!" },
	["lives.none"] = { en = "No lives left", ru = "Жизни кончились" },
	["lives.refill"] = { en = "Refill for {price}", ru = "Пополнить за {price}" },
	["lives.infinite"] = { en = "Unlimited lives: {time}", ru = "Бесконечные жизни: {time}" },
	["lives.free_levels"] = { en = "Levels 1–{n} don't cost lives", ru = "Уровни 1–{n} не тратят жизни" },
	["lives.refill_short"] = { en = "Refill", ru = "Пополнить" },
	["lives.refilled"] = { en = "Lives refilled!", ru = "Жизни пополнены!" },
	["lives.infinite_short"] = { en = "Unlimited", ru = "Безлимит" },
	["lives.get_coins"] = { en = "Get coins", ru = "Взять монеты" },

	-- level start window ----------------------------------------------------------------
	["start.title"] = { en = "Level {n}", ru = "Уровень {n}" },
	["start.goals"] = { en = "Goals", ru = "Цели" },
	["start.boosters"] = { en = "Boosters", ru = "Бустеры" },
	["start.streak"] = { en = "Hit streak", ru = "Серия хитов" },
	["start.streak_desc"] = {
		en = "Win in a row to get free boosters!",
		ru = "Побеждай подряд — получай бустеры бесплатно!",
	},
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
	["start.get_more"] = { en = "Get more in the shop", ru = "Ещё — в магазине" },
	["start.no_goals"] = { en = "Goals will be shown in the level", ru = "Цели покажем в уровне" },

	-- level HUD ---------------------------------------------------------------------------
	["hud.level"] = { en = "Level {n}", ru = "Уровень {n}" },
	["hud.moves"] = { en = "Moves", ru = "Ходы" },
	["hud.goals"] = { en = "Goals", ru = "Цели" },
	["hud.last_moves"] = { en = "Last moves!", ru = "Последние ходы!" },
	["hud.shuffle"] = { en = "No moves — shuffling!", ru = "Ходов нет — перемешиваем!" },
	["hud.pick_target"] = { en = "Pick a piece", ru = "Выбери фишку" },
	["hud.placeholder"] = { en = "The board is on its way", ru = "Поле скоро будет здесь" },
	["praise.1"] = { en = "Juicy!", ru = "Сочно!" },
	["praise.2"] = { en = "Hit!", ru = "Хит!" },
	["praise.3"] = { en = "Drive!", ru = "Драйв!" },
	["praise.4"] = { en = "Groovy!", ru = "Кайф!" },
	["praise.5"] = { en = "Legend!", ru = "Легенда!" },

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
		en = "Make matches on the dance floor to light it up. A double outline needs two.",
		ru = "Собирай фишки на танцполе, чтобы зажечь его. Двойной обводке нужно два раза.",
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
	["pause.quit_life"] = {
		en = "You will lose a life and your hit streak.",
		ru = "Ты потеряешь жизнь и серию хитов.",
	},
	["pause.quit_streak"] = { en = "Your hit streak will be lost.", ru = "Серия хитов сгорит." },
	["pause.quit_free"] = { en = "Nothing is lost before your first move.", ru = "До первого хода ничего не теряется." },

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

	-- lose ------------------------------------------------------------------------------------------
	["lose.title"] = { en = "Level failed", ru = "Уровень не пройден" },
	["lose.retry"] = { en = "Try again", ru = "Ещё раз" },
	["lose.town"] = { en = "To town", ru = "В город" },
	["lose.life_lost"] = { en = "−1 life", ru = "−1 жизнь" },
	["lose.streak_lost"] = { en = "Hit streak lost", ru = "Серия хитов сгорела" },

	-- win / results / concert --------------------------------------------------------------------------
	["win.title"] = { en = "Level complete!", ru = "Уровень пройден!" },
	["win.stars"] = {
		en = { one = "+{n} star", other = "+{n} stars" },
		ru = { one = "+{n} звезда", few = "+{n} звезды", many = "+{n} звёзд" },
	},
	["win.coins"] = {
		en = { one = "+{n} coin", other = "+{n} coins" },
		ru = { one = "+{n} монета", few = "+{n} монеты", many = "+{n} монет" },
	},
	["win.next"] = { en = "Next level", ru = "Следующий уровень" },
	["win.town"] = { en = "To town", ru = "В город" },
	["win.unlocked"] = { en = "New booster: {name}", ru = "Новый бустер: {name}" },
	["win.streak"] = { en = "Hit streak: {n}", ru = "Серия хитов: {n}" },
	["win.chest"] = { en = "Chest!", ru = "Сундук!" },
	["concert.title"] = { en = "Concert!", ru = "Концерт!" },
	["concert.skip"] = { en = "Tap to skip", ru = "Нажми, чтобы пропустить" },

	-- chest ----------------------------------------------------------------------------------------------
	["chest.title"] = { en = "Chest", ru = "Сундук" },
	["chest.open"] = { en = "Open", ru = "Открыть" },
	["chest.infinite"] = { en = "+{time} of unlimited lives", ru = "+{time} бесконечных жизней" },
	["chest.tap"] = { en = "Tap the chest!", ru = "Нажми на сундук!" },
	["chest.level"] = { en = "Level chest", ru = "Сундук уровня" },
	["gift.title"] = { en = "New booster!", ru = "Новый бустер!" },
	["gift.tap"] = { en = "Tap the gift!", ru = "Нажми на подарок!" },

	-- shop -------------------------------------------------------------------------------------------------
	["shop.title"] = { en = "Shop", ru = "Магазин" },
	["shop.boosters"] = { en = "Booster packs", ru = "Наборы бустеров" },
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

	-- settings -----------------------------------------------------------------------------------------------
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
	["settings.on"] = { en = "On", ru = "Вкл" },
	["settings.off"] = { en = "Off", ru = "Выкл" },
	["settings.version"] = { en = "Version {v}", ru = "Версия {v}" },
	["settings.reset"] = { en = "Reset progress", ru = "Сбросить прогресс" },
	["settings.reset_title"] = { en = "Reset progress?", ru = "Сбросить прогресс?" },
	["settings.reset_text"] = {
		en = "Levels, stars, coins and the whole town start over. This cannot be undone.",
		ru = "Уровни, звёзды, монеты и весь город начнутся заново. Отменить это нельзя.",
	},
	["settings.reset_do"] = { en = "Reset", ru = "Сбросить" },

	-- jukebox -------------------------------------------------------------------------------------------------
	["jukebox.title"] = { en = "Jukebox", ru = "Музыкальный автомат" },
	["jukebox.play"] = { en = "Play", ru = "Слушать" },
	["jukebox.stop"] = { en = "Stop", ru = "Стоп" },
	["jukebox.layers"] = { en = "Layers: {done}/{total}", ru = "Слоёв: {done}/{total}" },
	["jukebox.locked"] = { en = "Build {name} to unlock", ru = "Восстанови район «{name}», чтобы открыть" },
	["jukebox.full_song"] = { en = "Full song", ru = "Полная песня" },
	["jukebox.now_playing"] = { en = "Now playing: {name}", ru = "Сейчас играет: {name}" },
	["jukebox.pick"] = { en = "Pick a song", ru = "Выбери песню" },
	["jukebox.no_layers"] = { en = "Build a task to hear it", ru = "Выполни задачу, чтобы услышать" },

	-- district concert -------------------------------------------------------------------------------------------
	["district.concert"] = { en = "{name}: concert!", ru = "{name}: концерт!" },
	["district.chest"] = { en = "District chest", ru = "Сундук района" },

	-- tutorial -----------------------------------------------------------------------------------------------------
	["tutorial.swap"] = {
		en = "Swap two pieces to make a line of 3",
		ru = "Поменяй две фишки местами, чтобы собрать 3 в ряд",
	},
	["tutorial.riff"] = { en = "Match 4 in a line to make a Riff!", ru = "Собери 4 в ряд — получишь Рифф!" },
	["tutorial.sub"] = { en = "Match in a T or L shape for a Subwoofer!", ru = "Собери уголком — получишь Сабвуфер!" },
	["tutorial.bird"] = { en = "Match a 2×2 square for a Songbird!", ru = "Собери квадрат 2×2 — получишь Пташку!" },
	["tutorial.disco"] = { en = "Match 5 in a line for a Disco ball!", ru = "Собери 5 в ряд — получишь Диско-шар!" },
	["tutorial.tap_special"] = { en = "Tap a special piece to launch it", ru = "Нажми на спецфишку, чтобы запустить её" },
	["tutorial.goals"] = { en = "Complete the goals before moves run out", ru = "Выполни цели, пока не кончились ходы" },
	["tutorial.town"] = {
		en = "Spend stars to bring the town back to life",
		ru = "Трать звёзды, чтобы вернуть городу жизнь",
	},
	["tutorial.booster"] = { en = "Tap a booster, then pick a target", ru = "Нажми на бустер, затем выбери цель" },
	["tutorial.record_box"] = { en = "Break the record boxes!", ru = "Разбей коробки с пластинками!" },
	["tutorial.dancefloor"] = { en = "Light up the whole dance floor!", ru = "Зажги весь танцпол!" },
	["tutorial.wires"] = { en = "Cut the wires to free the pieces!", ru = "Порви провода, чтобы освободить фишки!" },
	["tutorial.mic"] = { en = "Bring the microphones to the stage!", ru = "Доставь микрофоны на сцену!" },
	["tutorial.concrete"] = { en = "Only specials break concrete!", ru = "Бетон ломают только спецфишки!" },
	["tutorial.noise"] = { en = "Stop the noise before it spreads!", ru = "Убери помехи, пока они не разрослись!" },
	["tutorial.balloon"] = { en = "Pop the balloons with their own colour!", ru = "Лопай шарики фишками их цвета!" },
	["tutorial.column"] = { en = "Knock the dust off the big speaker!", ru = "Выбей пыль из большой колонки!" },

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

	-- toasts and errors --------------------------------------------------------------------------------------------------
	["toast.coming_soon"] = { en = "Coming soon!", ru = "Скоро!" },
	["toast.saved_failed"] = {
		en = "Could not save progress. Trying again…",
		ru = "Не удалось сохранить прогресс. Пробуем ещё раз…",
	},
	["toast.saved_again"] = { en = "Progress saved", ru = "Прогресс сохранён" },
	["toast.language"] = { en = "Language: English", ru = "Язык: русский" },
	["toast.debug_coins"] = { en = "+{n} coins (debug)", ru = "+{n} монет (отладка)" },
	["toast.debug_reset"] = { en = "Save reset (debug)", ru = "Сохранение сброшено (отладка)" },
}

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
