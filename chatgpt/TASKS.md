# Задачи для ChatGPT

Обновлено: 2026-11-19. Пути файлов указаны от корня репозитория. Готовую картинку скачивает продюсер (см. `README.md`). Главный промпт со стилем: `docs/art-brief-chatgpt.md`, раздел 5; правила картинок: раздел 3.

## Задача 1 (срочная): район 16 «Ночное кафе» (часть 2), шесть картинок
Ночная версия Lo-fi-кафе: дождливая ночь, кафе открыто для тех, кто не спит. Для сравнения стиля используй комнату и карту первого кафе: `assets/images/districts/cafe/bg.jpg` и `assets/images/mapbg/bg_cafe.png`. Папка для файлов: `midnight`. **Ночь светлая и уютная, не тёмная:** лавандово-синее небо (#5B4FB0 … #8C7FE0), тёплые огни окон (#FFD36E), неон розовый #FF4FD8 и голубой #3CF2FF.

| № | Файл | Что это | Фон |
|---|---|---|---|
| 1.1 | `room_midnight_day.png` | комната, портрет 1024×1536 | без розового, вся картинка нарисована |
| 1.2 | `room_midnight_concert.png` | та же комната в режиме концерта | то же |
| 1.3 | `map_bg_midnight.png` | участок карты, портрет 2:3 | то же |
| 1.4 | `gate_midnight.png` | ворота района, 3:2 | сплошной розовый #FF00FF |
| 1.5 | `deco_midnight.png` | лист 3×2 украшений | розовый #FF00FF |
| 1.6 | `items_midnight.png` | лист 3×2 предметов | розовый #FF00FF |

Промпты (вставлять целиком после главного промпта):

**1.1** Room midnight_cafe "day": the same cosy lo-fi cafe room as the cafe reference, but late at night in the rain: a big window with a rainy city at night (lavender-blue sky, warm lit windows, a few stars between clouds, raindrops on the glass), a soft-lit wall with a small shelf, a wooden floor with warm lamp reflections. LIGHT and cosy, never dark. Do NOT draw furniture or items; leave free floor space for 6 items; keep the window and important details near the centre (8% of the width is cut on each side).

**1.2** Room midnight_cafe "concert": the same room as 1.1 in concert mode: neon night, deep blue-violet #3B2A8F to #6B4CE0, pink, cyan and warm-yellow spotlights reflecting in rain streaks on the window and in the polished floor, small floating light dots. Bright and festive, not dark. No items, no people, no text.

**1.3** map_bg_midnight: single, portrait 2:3, opaque: a vertical stretch of a rainy night street of cafes seen from above at a slight angle; a free band in the middle for a winding path (do NOT draw the path); on the left and right: cafe facades with warm lit windows, awnings, umbrellas, puddles reflecting neon, a sleeping cat on a sill, string lights; a soft lavender night sky at the top edge; no people, no text. The top and bottom edges must continue each other (the game stacks the tiles).

**1.4** gate_midnight: single, landscape 3:2, magenta background: an entrance arch of a night cafe street: a lavender-and-cream awning arch, two glowing lanterns, a crescent moon and a steaming cup on top, raindrops; a big EMPTY pale cream signboard in the upper middle (the game writes the name on it; keep it plain and light).

**1.5** deco_midnight, grid 3x2: six small props of a rainy night cafe street: a street lamp, an umbrella stand with wet umbrellas, a cafe chalkboard (no letters), a cat on a cushion, a potted plant with raindrops, a little neon cup sign (no letters).

**1.6** items_midnight, grid 3x2, in this order: (1) a vintage night radio-record player with a glowing dial, (2) a string of warm round lights hanging in a gentle curve, (3) a wobbly electric piano on legs, (4) a stand with two wet open umbrellas, (5) a sleepy cat wrapped in a knitted blanket on a cushion, (6) a neon sign shaped like a cup and a moon with an open-sign glow (no letters). Each item seen from the front at a slight angle, like the cafe items reference.

## Задача 2: фон уровня района (экран за игровым полем)
Одна неподвижная картинка района, портрет 1024×1536, **без облаков** (облака рисует игра), спокойный верх, мягкая середина (её закрывает поле), пейзаж района в нижней части. Полное описание композиции и строки THEME для районов: `docs/art-brief-level-backgrounds.md`. Для районов 1–15 фоны уже нарисованы и стоят в игре. Нужен фон для района 16: файл `level_bg_midnight.png`. THEME: a rainy night street of tiny cosy cafes in lavender-blue evening light, warm lit windows, puddles reflecting neon, string lamps, a sleeping cat on a sill.

## Задача 3 (после 1 и 2): районы 17–19 части 2
Те же шесть картинок и фон уровня для: 17 «Поздний клуб» (папка `lateclub`, джаз-клуб после полуночи), 18 «Фестиваль наций» (`nations`, праздничная площадь со флагами днём), 19 «Фан-встреча» (`fanmeet`, зал на закате). Подробные промпты будут добавлены сюда, когда продюсер скажет начинать.

## Что готово
См. `FROM_CLAUDE.md`.
