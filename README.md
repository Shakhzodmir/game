# GLOW

Яркая музыкальная игра «три в ряд» на Defold 1.13.1 (портрет, логический экран 720×1280). Каждое совпадение звучит нотой в тональности района, а звёзды за уровни восстанавливают город и включают новые слои трека. Кодовое имя — GLOW, рабочее название релиза — Encore Town / «Город на бис».

Документы: `docs/design/` — журнал решений, правила ядра, мета и экономика, архитектура клиента, арт-дирекшн.

## Тесты

```sh
./tools/test.sh            # Lua 5.1 (как в веб-сборке) и LuaJIT (как на мобильных)
./tools/test.sh --filter bus
```

Тесты на чистом Lua лежат в `tests/` (`tests/meta` — мета и экономика, `tests/client` — модули клиента). Нужны `lua5.1` и `luajit`.

## Веб-сборка

Нужны JDK 25 и `bob.jar` от Defold 1.13.1.

```sh
JAVA=/path/to/java BOB=/path/to/bob.jar VARIANT=debug ./tools/build_web.sh
python3 -m http.server 8791 -d dist/GLOW     # открыть http://localhost:8791/
```

`VARIANT=release` — сборка для публикации (по умолчанию). Скрипт сначала запускает `tools/gen_defold.py`, затем bob; результат — `dist/GLOW/index.html`.

**Отладочная сборка** (`VARIANT=debug`):
- клавиши: F1 — город, F2 — уровень, F3 — заставка, F5 — +1000 монет, F6 — сменить язык, F9 — сбросить сохранение;
- мост для автотестов: `window.__glowCmd = "goto town"` в консоли браузера, ответ и состояние приложения — в `window.__glowState` (команды — в `client/qa_bridge.lua`);
- скриншоты экранов в headless Chromium: `PLAYWRIGHT=/path/to/playwright/index.mjs node tools/qa/web_screens.mjs http://localhost:8791/index.html docs/media` (заодно проверяет нажатия, звук, сохранение и отсутствие ошибок Lua в консоли).

## Ресурсы Defold

Картинки, звук и музыка генерируются кодом (`tools/art`, `tools/audio`) в `assets/images`, `assets/sounds`, `assets/music`. После их обновления:

```sh
python3 tools/gen_defold.py          # атласы, шрифты, звуковые компоненты, реестр
python3 tools/gen_defold.py --check  # код 1, если сгенерированное устарело
```

Генератор пишет `assets/gen/` (атласы, шрифты, `audio.go`), минимальные `.gui` экранов и `client/assets_index.lua`. Эти файлы руками не правят.

## Устройство репозитория

```
game.project            настройки Defold (720×1280, shared_state, custom_resources=/content)
render/                 fit-рендер: логический экран целиком, без искажений, фон до краёв
input/                  привязки ввода (touch, multi_touch, отладочные клавиши)
main/                   main.collection: app.script (экраны, переходы), overlay (затемнение,
                        тосты, окна), audio.script (музыка по стемам, ноты, эффекты)
screens/                экраны-коллекции: splash, town, level (пока заглушки)
client/                 модули клиента: app, bus, i18n, save_io, layout, audio, platform,
                        ui, gfx, assets, qa_bridge, services/ (analytics, iap, ads)
core/                   правила игры (чистый Lua)
meta/                   мета и экономика (чистый Lua)
content/                districts.json, district_layouts.json, уровни (custom resources)
assets/                 сгенерированные картинки, звук, шрифты; assets/gen — ресурсы Defold
tools/                  тесты, сборка, генераторы арта, звука и ресурсов Defold, QA-скрипты
tests/                  тесты на чистом Lua
docs/                   дизайн-документы и скриншоты (docs/media)
web/glow.css            стиль HTML-страницы: холст на всё окно, без полос прокрутки
```
