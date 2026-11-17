# Фоны уровней по районам: что нарисовать в ChatGPT

На экране уровня за полем теперь можно показать картинку района: у базара фон базара, у пляжа пляж и так далее (2026-11-17, по просьбе продюсера). Пока картинки района нет, показывается общий фон (небо, домики), ничего не ломается. Каждая новая картинка включается сама, как только её установят.

## Что рисует ChatGPT, а что игра

- **ChatGPT:** одна неподвижная картинка района, портрет 1024×1536, без облаков.
- **Игра сама** (`client/level_sky.lua`): плывущие облака на дневных районах и мерцающие звёзды на вечерних (кино, небесный клуб, блюзовый клуб, аркада). При включённом «Меньше движения» небо стоит на месте.

## К каждой картинке прикрепить

1. `assets/images/backgrounds/level_bg.png`: общий фон, чтобы взять композицию;
2. `assets/images/districts/<район>/bg.png`: комната района;
3. `assets/images/mapbg/bg_<район>.png`: карта района.

Так цвета и стиль совпадут с остальным артом района.

## Промпт

```
Create a NEW opaque portrait background (1024x1536) for the LEVEL screen of the mobile match-3 music game GLOW. Use the attached pictures as references: the first one (the current level background) shows the COMPOSITION to keep; the other two are the room and the map of this district, so match their colours, shapes and glossy cute pastel style exactly.

THEME: <one line from the list below>

COMPOSITION (very important, the game board covers the middle of the screen):
- Top 20%: calm, almost empty soft sky or wall gradient (a garland and counters are placed there).
- Middle 65%: covered by the game board, so keep it soft and low-contrast: only a gentle gradient with very faint far scenery. No strong shapes, no bright details, no busy patterns here.
- Bottom 15%: the main scenery of the district as a low skyline / ground strip with the theme's buildings and props, in the same style as the district art.
- The left and right 8% may be cropped: keep nothing important there.
- Bright, light, cheerful pastel colours, never dark or gloomy (an evening or night theme is a bright evening, not black).
- Do NOT draw clouds (the game adds moving clouds itself). No birds, no characters, no people, no mascot, no text, letters or numbers, no logos, no UI, no game board, no magenta #FF00FF.
Fill the entire canvas with the scene.
```

## Строки THEME

| № | район | строка THEME |
|---|---|---|
| 1 | cafe | a warm pastel lo-fi café street, peach-pink morning sky, tiny cozy café fronts with awnings, string lamps, potted plants |
| 2 | jazz | an elegant but bright jazz-bar street at sunset, lavender-to-peach sky, bar fronts with a wordless neon sign shape, a street piano, warm lamps |
| 3 | square | a sunny street-band square, sky blue, colourful bunting, a fountain, a band wagon, pastel houses |
| 4 | stadium | a K-pop stadium by day, bright pink-lilac sky, a stadium arch with big light towers, letterless banners, star-shaped lights |
| 5 | garage | a rock-garage street at bright dusk, orange-blue sky, garage doors, amps, guitar-shaped signs, string lights |
| 6 | beach | a bossa-nova beach, turquoise sea and sky, sand, palm trees, striped umbrellas, a little beach bar |
| 7 | carnival | a salsa carnival street, warm magenta-orange sky, flag garlands, lantern strings, striped tents, drums |
| 8 | cinema (вечер, звёзды) | a cosy cinema street at a bright evening, soft violet-blue sky with the first stars, a cinema front with an empty marquee, spotlight beams, film-strip bunting |
| 9 | bazaar | an eastern bazaar, pale gold and turquoise sky, domes and minarets far away, market stalls with carpets and lanterns, arches |
| 10 | skyclub (вечер, звёзды) | a rooftop sky club above the city, bright cyan-violet evening sky with stars, city lights below, disco lights and speaker towers |
| 11 | block | a hip-hop block party, sunny yellow-blue sky, apartment buildings with pastel graffiti shapes (no letters), a boombox, a basketball hoop |
| 12 | island | a reggae island, bright turquoise sky, a thatched hut, palm trees, a hammock, colourful wooden signs without letters |
| 13 | ranch | a country ranch, soft blue sky, a red barn, a wooden fence, hay bales, a windmill, golden fields |
| 14 | bluesclub (вечер, звёзды) | a blues club in the evening, bright blue-violet dusk sky, a small club front with a lamp, a lamp post, soft mist near the ground |
| 15 | arcade (вечер, звёзды) | a pixel arcade street, bright purple-blue sky with pixel stars, glossy retro arcade cabinets and an arcade front, neon pink and cyan lights |

Если ChatGPT всё равно нарисует облака, попросить: «redraw without clouds».

## Как установить (мне или рабочему)

1. Файлы назвать `level_bg_<район>.png` (например `level_bg_bazaar.png`) и положить в `assets/art_incoming/` (папка не уходит на GitHub).
2. `python tools/art/install_level_bg.py assets/art_incoming bazaar`: вырежет середину 9:16, приведёт к 720×1280, положит в `assets/images/districts/<район>/level_bg.png` и запишет в `assets/art_ready/installed.json`.
3. `python tools/gen_defold.py` (обновит реестр `client/assets_index.lua`), затем тесты и просмотр на скриншоте.

Общий фон без облаков делает `python tools/art/install_level_sky.py`.
