# Арт-бриф для ChatGPT: что нарисовать и как

Версия 2 (WP-12). Сверена с кодом после задач WP-4…WP-9 и с `tools/art/import_incoming.py` (таблица `SPEC`) и `tools/art/install_ready.py` (имена в игре). Имена и размеры ниже — те, что реально читает игра. Версия 1 от 03.11.2026 отличалась в этих местах:

- **добавлено:** 5 одиночных поз Бита (`bit_idle`, `bit_happy`, `bit_sad`, `bit_worried`, `bit_scratch`), 40 иконок игры (`icons_1…icons_5`), фон уровня (`level_bg`), панель, ленту, значок ходов, значок-счётчик и гирлянду (`ui`);
- **убрано:** вспышка блокнота (`sparkle_burst`, никто её не рисует), 7 из 9 канцелярских предметов (игра берёт только карандаш и звезду), состояния кнопок (нажатие и серый цвет игра делает сама), виджеты и вкладка (не читаются), суперзвезда как отдельный лист (игра берёт иконку `super_star`);
- **исправлено:** домики карты (`deco`) 160×160, а не 192; тропа — два камешка 48×48, а не сетка 2×2; узел «доступен» называется `open`.

## 0. Коротко

- Картинок **72**: очередь **A — 44** (нужны ближайшим задачам: Бит, блокнот, карта, бонус-шкала) и очередь **B — 28** (комнаты, фон уровня, кнопки и панели, значки жанров и иконки; не срочно).
- Рисуй **по группам**, в новом чате на каждую группу, и каждый раз прикладывай листы-образцы (раздел 2). Тогда стиль не уплывёт.
- Размер картинки ChatGPT точно не держит, это нормально: программа сама обрежет по краям и приведёт к нужному размеру. Важны **пропорции**, **единый стиль** и **фон** (раздел 3).
- Один главный промпт (раздел 5) вставляется один раз в начале чата. Дальше пишешь только номер пункта («A1.3»), потом «next».

## 1. Как пользоваться (6 шагов)

1. Открой ChatGPT с генерацией картинок. Начни **новый чат** под группу (A1 Бит, A2 блокнот, A3 карта, A4 бонус-шкала, потом B).
2. Прикрепи к первому сообщению листы-образцы для этой группы (таблица в разделе 2). Файлы лежат в репозитории: `docs/media/art-reference/` (я также присылаю их тебе в чат).
3. Вставь **главный промпт** (раздел 5) целиком. ChatGPT ответит «Ready».
4. Напиши номер пункта, например `A1.1`. Он нарисует одну картинку. Проверь по чек-листу (раздел 3). Не так? Напиши, что исправить («Bit is too thin», «the frames are not on one ground line», «background is not magenta»). Так? Сохрани файл **под именем из таблицы** и напиши `next`.
5. Складывай файлы в папки по группам: `bit`, `notebook`, `map`, `bonus`, `rooms`, `ui`, `genres`, `backgrounds` (как в таблице раздела 4). Программа ищет файлы по имени в любой папке, так что папка нужна только тебе.
6. Когда группа готова, пришли мне её (раздел 6). Не жди, пока нарисуется всё: хватит A1 и A2, чтобы я начал подключать.

## 2. Что прикреплять (листы-образцы)

Все листы сделаны из настоящих картинок игры, `docs/media/art-reference/`:

| Файл | Что на нём | К каким группам прикладывать |
|---|---|---|
| `05_bit.png` | Бит, все позы | всегда, где есть Бит: A1, A2, A3, A4 |
| `03_pieces_specials.png` | фишки и спецфишки (стиль глянца и контура) | всегда |
| `01_ui_buttons_panels.png` | кнопки, панели, лента, значки | A2, A4, B2 |
| `02_icons.png` | 40 иконок игры | A2, A4, B2, B4 |
| `06_district_items.png` | предметы и фоны пяти районов | A3, B1, B3 |
| `07_screens.png` | восемь экранов игры | A3, B1, B2 |
| `08_logo_backgrounds_districts.png` | логотип, фон уровня, экраны районов | A3, B1 |
| `04_blockers_board.png` | блокеры и плитки поля | по желанию |

Если лист слишком большой для чата, прикрепи по одному-двум самым важным: `05_bit.png` и `03_pieces_specials.png` для Бита, `07_screens.png` и `06_district_items.png` для карты и комнат.

## 3. Правила для любой картинки и приёмка

**Фон.** Спрайты и листы: сплошной **розовый (маджента) #FF00FF** на весь холст, без градиента, без тени на фоне, без #FF00FF внутри самого рисунка; рисунок не касается краёв (поле не меньше 8%). Программа вырежет розовый в прозрачность. Непрозрачные сцены (фоны карты, комнат, уровня): весь холст занят картинкой.
**Листы кадров.** Холст делится на равные квадратные клетки (сетку я называю в таблице: 2×2 или 3×2 или 3×3). В клетке один кадр или предмет по центру, одного размера, у кадров одного героя **одна линия земли**, линий между клетками нет.
**Одиночные формы** (кнопки, панели, лента, значок-счётчик): форма имеет пропорции из таблицы (кнопка 3:1, лента 4:1 и т. д.), симметричные края, без мелких деталей у края. Программа обрежет поля и растянет форму до точного размера, края не растягиваются (игра растягивает только середину).
**Размер холста.** Самый большой, какой даёт ChatGPT: 1024×1024 (сетка 2×2 и 3×3 и одиночные спрайты), 1536×1024 (3×2 и пейзажи 3:2), 1024×1536 (портрет 2:3).
**Чего нет на картинках.** Никакого текста, букв, цифр и логотипов (надписи рисует игра), чужих брендов и персонажей, реальных людей, тёмной мрачной гаммы.

Чек-лист приёмки (проверь глазами перед `next`):
- фон ровно розовый, края чистые, нет розовой каймы внутри рисунка;
- стиль как на образцах: глянец, мягкий светлый блик сверху слева, тонкий контур своего цвета, скруглённые формы;
- Бит выглядит точно как на `05_bit.png` (круглый рыже-кремовый зверёк, большие фиолетовые наушники с розовыми чашками);
- в листе кадров равные клетки, одинаковый размер героя, одна линия земли;
- нет текста, подписей, водяных знаков.

## 4. Список картинок

«Лист» = картинка, разрезаемая на клетки. «Одиночная» = одна картинка. «В игре» — размер в пикселях, до которого программа приведёт картинку.

### Очередь A (44)

**A1. Бит: анимации** (папка `bit`; задача WP-8; в игре кадр 256×256; прикладывать `05_bit.png`, `03_pieces_specials.png`)

| № | Файл | Сетка | Что нарисовать |
|---|---|---|---|
| A1.1 | `bit_idle_breathe.png` | 2×2 | 4 кадра: стоит, дышит (тело чуть сплющивается и вытягивается), огоньки наушников мигают |
| A1.2 | `bit_idle_look.png` | 2×2 | 4 кадра: смотрит влево, прямо, вправо, прямо; моргает |
| A1.3 | `bit_dance_a.png` | 3×2 | 6 кадров: пружинистый танец из стороны в сторону, руки вверх |
| A1.4 | `bit_dance_b.png` | 3×2 | 6 кадров: прыжок с поворотом, вокруг маленькие ноты |
| A1.5 | `bit_cheer.png` | 3×2 | 6 кадров: радуется, прыгает с поднятыми руками, вокруг звёздочки-конфетти |
| A1.6 | `bit_surprised.png` | 2×2 | 4 кадра: большие глаза, отпрыгивает, искорка-капелька |
| A1.7 | `bit_sleepy.png` | 2×2 | 4 кадра: зевает, веки опускаются, клюёт носом, маленькие «z» |
| A1.8 | `bit_write.png` | 3×2 | 6 кадров: держит большой карандаш и пишет на листе бумаги перед собой, язык от усердия; лист без читаемого текста, только каракули |
| A1.9 | `bit_listen.png` | 2×2 | 4 кадра: глаза закрыты, прижимает наушники руками, покачивается, маленькие ноты |
| A1.10 | `bit_wave.png` | 2×2 | 4 кадра: машет рукой, улыбается |

Одиночные позы (та же фигура, тот же размер, та же линия земли, что и в кадрах выше):

| № | Файл | Сетка | Что нарисовать |
|---|---|---|---|
| A1.11 | `bit_idle.png` | один, квадрат | стоит спокойно, лицо нейтральное |
| A1.12 | `bit_happy.png` | один, квадрат | радостное лицо, большая улыбка, руки чуть подняты |
| A1.13 | `bit_sad.png` | один, квадрат | грустный: опущенные уголки рта, уши-наушники опущены |
| A1.14 | `bit_worried.png` | один, квадрат | обеспокоен: глаза широко, рука у щеки |
| A1.15 | `bit_scratch.png` | один, квадрат | почёсывает затылок, глаза прищурены, в воздухе искорка |

Как игра читает Бита (WP-8, `content/animations.json`): кадры n-й анимации ложатся как `bit/<анимация>_<n>.png` (`bit_cheer_3` в брифе = `bit/cheer_3` в игре), 256×256, одна линия земли у всех кадров; `tools/art/install_ready.py` ставит анимацию, только когда готовы **все** её кадры. Что игра делает с кадрами: `idle_breathe` крутится туда-обратно всегда, `idle_look` и `wave`/`listen` играют по случайному поводу, `sleepy` после кадра 4 качается между кадрами 3 и 4, пока игрок не тронет экран, `dance_a`/`dance_b` меняются каждые 4 доли и идут в такт песни (один проход = 2 доли), `write` крутится, пока блокнот открыт. Дыхание, покачивание и подскок на доле игра добавляет сама (скелетная часть), рисовать их в кадрах не нужно.

Одиночные позы: `bit_happy` — лицо в обучении и радость; `bit_sad` — проигрыш уровня; `bit_worried` — ход отклонён; `bit_scratch` — Бит на поле при комбо (`client/level_bit.lua`); `bit_idle` — запасной кадр, если анимация не загрузилась.

**A2. Блокнот песни** (папка `notebook`; задача WP-9; прикладывать `05_bit.png`, `01_ui_buttons_panels.png`, `02_icons.png`)

| № | Файл | Сетка | Что нарисовать | В игре |
|---|---|---|---|---|
| A2.1 | `paper_sheet.png` | один, портрет 2:3 | листок кремовой бумаги с нотным станом (5 тонких линий, много строк), лёгкая тень, чуть загнутые уголки, пустой | 640×900 |
| A2.2 | `notebook_closed.png` | один, квадрат | закрытый блокнот-песенник: лавандовая обложка, золотая звезда и нота (без букв), ленточка-закладка, прошивка | 384×384 |
| A2.3 | `stationery_pencil.png` | один, квадрат | жёлтый карандаш, чуть под углом, с остро заточенным концом | 128×128 |
| A2.4 | `stationery_star.png` | один, квадрат | наклейка-звезда: розовая звезда с белой каймой и бликом | 128×128 |
| A2.5 | `doodles.png` | 3×3 | 9 рисунков-каракулей цветным карандашом, толстые скруглённые линии, по порядку слева направо, сверху вниз: нота, две ноты, скрипичный ключ, сердечко, звезда, цветок, солнце, облако, молния | 96×96 каждый |
| A2.6 | `stamp_ready.png` | один, квадрат | круглая золотая печать со звездой и двумя ленточками, без текста: «песня готова» | 192×192 |

Как игра читает блокнот (WP-9, `gui/notebook.lua`, `gui/result.lua`; процедурные заглушки — `tools/art/notebook_art.py`, лежат в `assets/images/notebook`; настоящий арт подменяет их без правки кода). Карандаш и звезда-наклейка лежат на странице блокнота (`notebook/stationery_1` и `notebook/stationery_6`), каракули — на полях (каждая четвёртая строка, `notebook/doodle_1…9`), печать — на готовой песне и в окне итогов.

**A3. Карта игры** (папка `map`; задача WP-7; прикладывать `07_screens.png`, `06_district_items.png`, `08_logo_backgrounds_districts.png`, `05_bit.png`)

| № | Файл | Сетка | Что нарисовать |
|---|---|---|---|
| A3.1–A3.5 | `map_bg_cafe.png`, `map_bg_jazz.png`, `map_bg_square.png`, `map_bg_stadium.png`, `map_bg_garage.png` | один, портрет 2:3, без розового | фон участка карты района. Вид сверху под небольшим углом; в центре свободная полоса под дорожку (дорожку не рисовать); слева и справа здания и предметы района; светлое небо у верхнего края; без людей, без дорожки, без текста. Темы: Lo-fi-кафе (тёплая пастельная улочка, лампы, растения, кот); Джаз-бар (изящный, но светлый, латунь, неон «без букв», рояль); Площадь уличного оркестра (парад, фонтан, гирлянды, труба); K-pop-стадион (розово-голубой свет, световые палочки, салют); Рок-гараж (гаражные ворота, усилители, плакаты без текста) |
| A3.6–A3.7 | `map_path_dot.png`, `map_path_dot_done.png` | два одиночных, квадрат | два круглых глянцевых камешка тропы с белой каймой и светящейся точкой: обычный (лавандово-белый) и пройденный (золотой). Игра сама кладёт их цепочкой от узла к узлу, поэтому поворотов и концов не нужно |
| A3.8 | `node_day.png` | 2×2 | круглый узел уровня («сцена-пластинка» с нотой): закрыт (серо-лавандовый, замок), доступен (`open`, яркий), текущий (`current`, крупнее, золотое кольцо, свечение), пройден (`done`, зелёная галочка); звёзд на узле нет |
| A3.9 | `node_concert.png` | 2×2 | те же 4 состояния для **концерта**: крупнее, сцена с прожекторами и звездой-короной сверху |
| A3.10–A3.14 | `gate_cafe.png`, `gate_jazz.png`, `gate_square.png`, `gate_stadium.png`, `gate_garage.png` | один, пейзаж 3:2 | вход в район: арка или вывеска в теме района, табличка пустая (название напишет игра), фон розовый |
| A3.15–A3.19 | `deco_cafe.png`, `deco_jazz.png`, `deco_square.png`, `deco_stadium.png`, `deco_garage.png` | 3×2 | 6 мелких предметов для украшения карты в теме района (деревья, лампы, скамейки, инструменты, флажки) |

Размеры и имена, которые ждёт карта (WP-7, `content/map.json`, процедурные заглушки лежат в `assets/images/map` и `assets/images/mapbg`; когда придёт арт, он подменяет их без правки кода). Программа режет листы на клетки и кладёт файлы под эти имена сама.

| Имя в игре | Размер, px | Откуда |
|---|---|---|
| `mapbg/bg_<район>` (`cafe`, `jazz`, `square`, `stadium`, `garage`) | 720×1080, непрозрачный; карта кладёт его по вертикали подряд, каждый второй кусок зеркалит, поэтому верх и низ должны совпадать по краям | A3.1–5 |
| `mapbg/gate_<район>` | 720×480, прозрачный; арка стоит поперёк тропы, табличка пустая (в игре на неё ложится название района, место таблички задаёт `sign` района в `map.json`) | A3.10–14 |
| `map/node_day_{locked,open,current,done}` | 160×160 каждый (лист 2×2 = 320×320), круг узла занимает центральные ~100 px, остальное свечение | A3.8 |
| `map/node_concert_{locked,open,current,done}` | 224×224 каждый (лист 2×2), круг ~125 px, звезда-корона над ним | A3.9 |
| `map/path_dot`, `map/path_dot_done` | 48×48 | A3.6–7 |
| `map/deco_<район>_<1..6>` | 160×160 каждый (лист 3×2 = 480×320), прозрачный | A3.15–19 |

Состояние `open` («доступен, но Бит не на нём») сегодня в игре не встречается: играть можно только следующий уровень (`current`), пройденные уровни — `done`. Картинку всё равно нужно нарисовать: она описана в `content/map.json`.

**A4. Бонус-шкала** (папка `bonus`; задача WP-5; прикладывать `01_ui_buttons_panels.png`, `02_icons.png`, `03_pieces_specials.png`)

| № | Файл | Сетка | Что нарисовать |
|---|---|---|---|
| A4.1 | `bonus_bar_frame.png` | один, пропорция 6:1 | пустая глянцевая шкала-капсула, ширина в 6 раз больше высоты: тонкая бело-лавандовая рамка, десять маленьких насечек, слева нотка на торце, справа гнездо-коробочка под подарок; внутри светлое лавандовое «стекло» |
| A4.2 | `bonus_bar_fill.png` | один, пропорция 6:1 | «сок» для заполнения той же формы и пропорций, что внутренность A4.1: леденцовый градиент розовый → оранжевый → жёлтый, глянцевая полоска сверху, мелкие пузырьки |
| A4.3 | `bonus_gift.png` | 2×2 | подарок-бонус: закрытая коробочка (`closed`), трясётся (`shake`), светится перед открытием (`glow`), открывается лучами (`open`) |
| A4.4 | `bonus_spark.png` | 3×2 | 6 кадров маленькой искры-звёздочки при каждом прибавлении очка |

Шкала в игре пока не нарисована: задача WP-5 (`tools/agents/tasks/WP-5-bonus-meter.md`) ещё не сделана, поэтому A4 нужна ей, а не нынешнему коду. Суперзвезда (раньше A4.5) берётся иконкой `ui/icons/super_star` из B4.

### Очередь B (28, позже)

| № | Файл | Что нарисовать |
|---|---|---|
| B1.1–B1.5 | `room_<район>_day.png` (cafe, jazz, square, stadium, garage), папка `rooms` | комната района днём, портрет 2:3, без розового, как `bg.png` на листе `06_district_items.png` и на экране города: окно с видом на город наверху, стена, пол; предметы не рисовать (они отдельные), оставить свободный пол для 3–6 предметов; в игре комната уже (9:16), поэтому по бокам срежется по 8% ширины: окно и важное держи ближе к центру |
| B1.6–B1.10 | `room_<район>_concert.png` | та же комната «в режиме концерт»: яркая неоновая ночь, сине-фиолетовый #3B2A8F → #6B4CE0 с розовыми, бирюзовыми и жёлтыми прожекторами; не тёмная |
| B1.11 | `level_bg.png`, папка `backgrounds` | фон экрана уровня, 9:16 (в игре 720×1280), весь холст занят картинкой, без розового, без предметов и текста; игра кладёт поверх поле, панели и Бита. Сверху держи спокойнее: там гирлянда `ui/bunting` |
| B2.1–B2.5 | `btn_green.png`, `btn_blue.png`, `btn_gold.png`, `btn_pink.png`, `btn_purple.png`, папка `ui` | одна широкая кнопка-«таблетка» без текста, пропорция 3:1, скругление около четверти высоты (не полный полукруг), глянец, тёмная «полка» снизу, как на `01_ui_buttons_panels.png`, но красивее. Нажатие и серый цвет игра делает сама, поэтому одна картинка на цвет |
| B2.6 | `panel.png`, папка `ui` | одиночная кремовая панель-окно, без ленты, квадрат, симметричные края |
| B2.7 | `ribbon.png`, папка `ui` | лента-заголовок, пропорция 4:1, концы симметричны (середина растягивается), без текста |
| B2.8 | `moves_badge.png`, папка `ui` | значок счётчика ходов, квадрат, мягкий круг или скруглённый квадрат, без цифр |
| B2.9 | `badge_count.png`, папка `ui` | маленький кружок-значок для числа бустеров, квадрат, без цифр |
| B2.10 | `bunting.png`, папка `ui` | гирлянда флажков: ленточка сверху, флажки без букв, на прозрачном фоне, пропорция 720:64 |
| B3.1 | `genres_a.png`, папка `genres` | 3×3 значка жанров: классика, народная, поп, хип-хоп, EDM, R&B, регги, кантри, блюз; круглые, на каждом нарисован характерный предмет (скрипка, балалайка и т. д.), без текста |
| B3.2 | `genres_b.png` | 3×2: босса-нова, эмбиент, кино-оркестр, чиптюн, латино, восточная |
| B4.1 | `icons_1.png`, папка `ui` | 3×3 значки игры: `arrow` (стрелка назад), `chart` (график), `check` (галочка), `chest_closed` и `chest_open` (сундук закрыт и открыт), `city` (город), `close` (крестик), `coin` (монета), `col_light` (бустер: световая колонка) |
| B4.2 | `icons_2.png`, папка `ui` | 3×3: `gift` (подарок), `goal_floor` (цель: плитка с пометкой), `hand` (рука-подсказка), `haptics` (вибрация), `heart` (жизнь), `heart_infinite` (бесконечная жизнь), `home` (домик), `jukebox` (автомат), `lock` (замок) |
| B4.3 | `icons_3.png`, папка `ui` | 3×3: `map` (карта), `music_off` и `music_on` (музыка выкл и вкл), `note_off` и `note_on` (нота выкл и вкл), `pause` (пауза), `play` (плей), `plus` (плюс), `remix` (бустер: перемешать) |
| B4.4 | `icons_4.png`, папка `ui` | 3×3: `retry` (повтор), `row_light` (бустер: световая строка), `settings` (шестерёнка), `shop` (магазин), `sound_off` и `sound_on` (звук выкл и вкл), `star` (звезда), `star_empty` (пустая звезда), `stick` (бустер: палочка) |
| B4.5 | `icons_5.png`, папка `ui` | 2×2: `streak` (огонёк серии), `super_star` (суперзвезда: золотая звезда с радужным бликом и короной), `swap` (бустер: обмен фишек), `team` (группа) |

Иконки режутся на клетки 96×96 и кладутся в `assets/images/ui/icons/<имя>.png`: имя — то, что написано в таблице. Жанры: клетки листа A — `classical, folk, pop, hiphop, edm, rnb, reggae, country, blues`, лист B — `bossa, ambient, cinematic, chiptune, latin, eastern` (15 жанров джукбокса, `content/genres.json`), `ui/genres/<id>.png` 96×96. Пока картинок нет, игра берёт процедурные заглушки из `tools/art/genres.py` и `tools/art/gen_art.py`; имена и размер те же, так что подмена файлов ничего не ломает.

## 5. ГЛАВНЫЙ ПРОМПТ (копируй целиком в начало чата)

```
You are the lead 2D game artist of a mobile match-3 music game called GLOW ("Encore Town"). I will ask you for images one at a time by item number. Follow ALL rules below for EVERY image.

STYLE
- Bright, sunny music-festival look: glossy, smooth, rounded shapes, soft gradients, soft shadows, clean anti-aliased edges, a soft white specular highlight at the top-left of every object, a thin darker outline in the object's own hue (about 2-3 px at 160 px size). Cheerful, cute, premium mobile-game quality. Match the attached reference sheets exactly in outline thickness, gloss, shading and palette.
- Palette: pastel city plus saturated accents. Pink #FF9EC7 / #FF4D8D, yellow #FFD36E / #FFDB1A, mint #8BE39A / #2BE38F, sky blue #7FC8FF / #3AA4FF, lavender #C9A7FF / #9B52FF, orange #FF9A1F, warm cream #FFF4C9, ink (dark violet) #2B2345. Scenes are LIGHT and cheerful, never dark or gloomy. The "concert" version of a scene is a bright neon night: deep blue-violet #3B2A8F to #6B4CE0 with pink #FF4FD8, cyan #3CF2FF and yellow #FFE66D spotlights.
- Mascot "Bit": a fluffy round orange-cream creature (body #FFC98B, outline #E0873A) wearing huge violet headphones (#7B4FFF) with pink ear cups (#FF4D8D) and small yellow lights, rosy cheeks, big friendly eyes, tiny arms and feet. Keep Bit IDENTICAL in every image (proportions, colors, headphones), exactly like the attached Bit sheet.
- No text, letters, numbers, logos or watermarks in any image. No real people, no real brands, no copyrighted characters.

OUTPUT FORMAT
- Sprites and sprite sheets: the whole canvas is flat solid pure magenta #FF00FF. No gradient, no shadow cast on the background, no magenta inside the artwork. The artwork never touches the canvas edge (keep at least 8% margin).
- Sprite sheets: I name the grid (2x2, 3x2 or 3x3). Divide the canvas into EQUAL SQUARE cells. Put exactly one frame or object per cell, centered, same scale in every cell, and for animation frames of one character keep the same ground line in every cell. No lines or borders between cells.
- Single shapes (buttons, panels, ribbon): I name the proportion (3:1, 4:1, square). Draw the shape symmetric, with the same corners on both sides, nothing fine at the edges.
- Opaque scenes (map, room and level backgrounds): fill the entire canvas with the scene, no magenta, no characters, no UI, no text.
- Use the largest canvas you can: 1024x1024 for 2x2 and 3x3 grids and single sprites, 1536x1024 for 3x2 grids, 1024x1536 for portrait 2:3 images.
- Draw ONE image per message. After the image write one line saying what you drew, then wait for my message "next" or for a change request. When I ask for a change, redraw the whole image keeping everything else the same.

When you have read this, answer only "Ready" and wait for the first item number.

ITEM LIST (I will refer to these by number)

A1 Bit animations (square cells, magenta background):
A1.1 bit_idle_breathe, grid 2x2: 4 frames, Bit stands and breathes (body squashes and stretches slightly), headphone lights blink alternately.
A1.2 bit_idle_look, grid 2x2: 4 frames, Bit looks left, center, right, center, blinks once.
A1.3 bit_dance_a, grid 3x2: 6 frames, bouncy side-to-side dance with arms up, headphones glowing.
A1.4 bit_dance_b, grid 3x2: 6 frames, jump with a spin, small musical notes floating around.
A1.5 bit_cheer, grid 3x2: 6 frames, jumping with both arms raised, small star confetti around, open happy mouth.
A1.6 bit_surprised, grid 2x2: 4 frames, wide eyes, hops back, a little sparkle drop.
A1.7 bit_sleepy, grid 2x2: 4 frames, yawns, eyelids droop, head nods, tiny "z" bubbles (the letter z as a bubble shape is allowed).
A1.8 bit_write, grid 3x2: 6 frames, Bit holds a big pencil and writes on a sheet of paper in front of it, tongue out in concentration; the paper shows only scribbles, no readable text.
A1.9 bit_listen, grid 2x2: 4 frames, eyes closed, both hands pressing the headphones, swaying to music, tiny notes.
A1.10 bit_wave, grid 2x2: 4 frames, waves hello with one arm, smiling.
A1.11 bit_idle, single square: Bit standing calmly, neutral face, same size and ground line as the frames above.
A1.12 bit_happy, single square: happy face, big smile, arms slightly raised.
A1.13 bit_sad, single square: sad, corners of the mouth down, headphones drooping.
A1.14 bit_worried, single square: worried, eyes wide, one hand near the cheek.
A1.15 bit_scratch, single square: scratches the back of its head, eyes narrowed, a tiny spark in the air.

A2 Songbook kit (magenta background):
A2.1 paper_sheet, single image, portrait 2:3: a sheet of cream paper with a music staff (5 thin lines repeated in many rows), soft shadow, slightly curled corners, empty, the paper fills about 85% of the canvas.
A2.2 notebook_closed, single, square: a cute closed songbook with a lavender cover, a gold star and a music note emblem (no letters), a ribbon bookmark, rounded corners, stitched binding.
A2.3 stationery_pencil, single square: a yellow pencil, slightly tilted, sharp tip.
A2.4 stationery_star, single square: a star sticker, pink star with a white border and a glint.
A2.5 doodles, grid 3x3: colored-pencil doodles with thick rounded strokes, in this order left to right, top to bottom: music note, double note, treble clef, heart, star, flower, sun, cloud, lightning bolt.
A2.6 stamp_ready, single square: a round golden seal with a star and two ribbon tails, no text, meaning "song complete".

A3 Game map (portrait scenes are opaque, everything else magenta background):
A3.1-A3.5 map_bg_cafe, map_bg_jazz, map_bg_square, map_bg_stadium, map_bg_garage: single, portrait 2:3, opaque: a vertical stretch of a district landscape seen from above at a slight angle; keep a free band in the middle for a winding path (do NOT draw the path); buildings and props of the district on the left and right; light sky at the top edge; no people, no text. Themes: cafe = warm pastel lo-fi cafe street with lamps, plants, a sleeping cat; jazz = elegant but bright jazz bar street with brass, a grand piano, a wordless neon sign; square = street brass-band parade square with a fountain, bunting, a tuba; stadium = pink and cyan k-pop stadium with light sticks and fireworks; garage = rock garage street with garage doors, amps, wordless posters.
A3.6 map_path_dot, single square: a round glossy path pebble, lavender-white, white edge, glowing dot in the middle.
A3.7 map_path_dot_done, single square: the same pebble, golden, glowing.
A3.8 node_day, grid 2x2: a round level node (a stage-disc with a music note): locked (grey-lavender with a lock), open (bright), current (bigger, golden ring, glow), done (green check mark). No stars on the node.
A3.9 node_concert, grid 2x2: the same four states for a CONCERT node: bigger, a small stage with spotlights and a star-crown on top.
A3.10-A3.14 gate_cafe, gate_jazz, gate_square, gate_stadium, gate_garage: single, landscape 3:2, magenta background: an entrance arch or signboard in the theme of the district, the signboard is empty (the game writes the name).
A3.15-A3.19 deco_cafe, deco_jazz, deco_square, deco_stadium, deco_garage: grid 3x2: six small decorative props in the theme of the district (trees, lamps, benches, instruments, flags).

A4 Bonus bar (magenta background):
A4.1 bonus_bar_frame, single, proportion 6:1: an empty glossy capsule-shaped progress bar: thin white-lavender frame, ten small tick notches, a small music note on the left end cap, a gift-box socket on the right end; the inside is light lavender glass.
A4.2 bonus_bar_fill, single, proportion 6:1: the "juice" that fills the same capsule shape: candy gradient pink to orange to yellow, a glossy highlight strip on top, tiny bubbles.
A4.3 bonus_gift, grid 2x2: a bonus gift: closed box, shaking, glowing before opening, opening with rays. Order: closed, shake, glow, open.
A4.4 bonus_spark, grid 3x2: 6 frames of a small spark-star pop.

B1 Rooms and level background (opaque, no magenta): room_cafe_day, room_jazz_day, room_square_day, room_stadium_day, room_garage_day, and room_<district>_concert for each; portrait 2:3. A room of the district as in the attached game screens: a window with a city view at the top, a wall, a floor; do NOT draw furniture or items, leave free floor space for 3 to 6 items. "day" = bright pastel daylight. "concert" = bright neon night with colored spotlights. In the game a room is narrower (9:16) than the canvas, so about 8% of the width is cut from each side: keep the window and every important shape in the central 80%.
B1.11 level_bg, portrait (draw it on 1024x1536; the program crops it to 9:16): the background of the level screen, the whole canvas filled with a calm scene (soft sky and a stage floor), no items, no text; keep the top calmer (a garland goes there).

B2 Interface (magenta background):
B2.1-B2.5 btn_green, btn_blue, btn_gold, btn_pink, btn_purple: single, proportion 3:1: one wide button without text, rounded corners of about a quarter of its height (not a full half-circle), glossy with a dark "shelf" at the bottom, like the attached buttons but more beautiful. One picture per colour: no pressed or disabled versions.
B2.6 panel, single square: a cream window panel without ribbon, symmetric edges.
B2.7 ribbon, single, proportion 4:1: a title ribbon with symmetric ends, no text.
B2.8 moves_badge, single square: a round or rounded-square counter badge, no numbers.
B2.9 badge_count, single square: a small round badge for a count, no numbers.
B2.10 bunting, single, proportion 720:64: a garland of little flags on a string at the top, flags without letters, transparent background.

B3 Genre icons (magenta background, round icons with a characteristic object, no text):
B3.1 genres_a, grid 3x3: classical, folk, pop, hip-hop, EDM, R&B, reggae, country, blues.
B3.2 genres_b, grid 3x2: bossa nova, ambient, cinematic orchestra, chiptune, latin, eastern traditional.

B4 Game icons (magenta background, one simple flat-glossy icon per cell, no text, same style as the reference icon sheet):
B4.1 icons_1, grid 3x3: arrow (back arrow), chart, check, chest_closed, chest_open, city, close (cross), coin, col_light (a booster: a vertical light column).
B4.2 icons_2, grid 3x3: gift, goal_floor (a goal tile), hand (a pointing hand), haptics (vibration), heart, heart_infinite (heart with an infinity sign, no letters), home, jukebox, lock.
B4.3 icons_3, grid 3x3: map, music_off, music_on, note_off, note_on, pause, play, plus, remix (a booster: shuffle).
B4.4 icons_4, grid 3x3: retry, row_light (a booster: a light row), settings (gear), shop, sound_off, sound_on, star, star_empty (outline star), stick (a booster: a stick).
B4.5 icons_5, grid 2x2: streak (a small flame), super_star (golden star with rainbow glint and a tiny crown), swap (a booster: exchange two pieces), team (a group of three figures).
```

## 6. Как передать мне готовые файлы

1. **Через чат:** прикрепи картинки (можно по несколько штук) и напиши группу и имена файлов, если они не совпадают с таблицей.
2. **Через GitHub (если файлов много):** на странице репозитория кнопка Add file → Upload files, загрузи в папку `assets/art_incoming/<группа>/` и отправь в новую ветку `art-incoming` (не в основную). Напиши мне «залил».

Я подключу картинки программой (`tools/art/import_incoming.py`, затем `tools/art/install_ready.py`): вырежет розовый фон, нарежет листы на кадры, обрежет поля, приведёт к нужным размерам, проверит стиль и положит в игру. Всё, что не подошло, пришлю списком с причиной.

## 7. Примечания

- Права на картинки, созданные в ChatGPT, определяются условиями OpenAI (на момент написания результат принадлежит пользователю); перед выходом в магазины проверь актуальные условия и сохрани переписку-историю генерации.
- Кнопки, панели, ленту и значок-счётчик игра растягивает по краям (девятисегментная сетка): рисуй края симметрично и без мелких деталей у края.
- Если ChatGPT упорно рисует не тот размер или шумит фон, пришли мне как есть: исправить розовый фон и пропорции я смогу сам, а испорченный стиль нет.

## 8. Что в игре ждёт картинку, но в брифе её нет (решить отдельно)

- `logo/logo` (640×320, экран заставки, `screens/splash/splash.gui_script`) — логотип с надписью, а текст на картинках запрещён. Нужно решение: буквы рисует игра или логотип делаем отдельно.
- Предметы комнат районов (`districts/<район>/<предмет>.png` и `_ghost`-версии, около 38 штук, `screens/town/scene.lua`) — в брифе нет списка размеров и листов, поэтому их нет в версии 2. Отдельная спецификация нужна до того, как их рисовать.
- `ui/button_small_<цвет>` (64×64) — игра берёт её только для кнопки обучения 172×52, если картинки нет, рисуется процедурная рамка. В бриф не добавлена, чтобы не рисовать пять картинок ради одной кнопки.
