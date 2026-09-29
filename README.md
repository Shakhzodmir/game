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

Нужны python3, JDK 25 и `bob.jar` от Defold 1.13.1.

```sh
JAVA=/path/to/java BOB=/path/to/bob.jar VARIANT=debug ./tools/build_web.sh
python3 -m http.server 8791 -d dist/GLOW     # открыть http://localhost:8791/
```

`VARIANT=release` — сборка для публикации (по умолчанию). Скрипт сначала запускает `tools/gen_defold.py` (без python3 он останавливается; `SKIP_GEN=1` — собрать без генератора, если сгенерированное точно свежее), затем bob; результат — `dist/GLOW/index.html`. В debug-сборке лежит файл `DEBUG_BUILD_DO_NOT_PUBLISH`: её нельзя выкладывать на порталы.

**Отладочная сборка** (`VARIANT=debug`):
- клавиши: F1 — город, F2 — уровень, F3 — заставка, F5 — +1000 монет, F6 — сменить язык, F9 — сбросить сохранение;
- мост для автотестов (только на `localhost`/`127.0.0.1` или с `?glowqa` в адресе): `window.__glowCmd = "goto town"` в консоли браузера, ответ и состояние приложения — в `window.__glowState` (команды — в `client/qa_bridge.lua`);
- проверки и скриншоты экранов в headless Chromium: `PLAYWRIGHT=/path/to/playwright/index.mjs node tools/qa/web_screens.mjs http://localhost:8791/index.html docs/media` — нажатия при 1× и 3×, тосты, окна, затемнения, контракт нот, тональность эффектов, ресинхронизация музыки после паузы кадра, повтор неудачного сохранения, сохранение и язык после перезагрузки, отсутствие ошибок Lua. С `--release` (на release-сборке) проверяет, что моста нет.

## Ресурсы Defold

Картинки, звук и музыка генерируются кодом (`tools/art`, `tools/audio`) в `assets/images`, `assets/sounds`, `assets/music`. После их обновления:

```sh
python3 tools/gen_defold.py          # атласы, шрифты, звуковые компоненты, реестр
python3 tools/gen_defold.py --check  # код 1, если сгенерированное устарело
```

Генератор пишет `assets/gen/` (атласы, шрифты, `audio.go`), минимальные `.gui` экранов и `client/assets_index.lua`. Эти файлы руками не правят. Манифесты необязательны: без них генератор берёт встроенные nine-slice и контракт микшера по умолчанию, пропускает битые PNG/Ogg, заменяет недостающий шрифт другим и разводит совпавшие id анимаций. Стемы района разной длины — ошибка (`GLOW_ALLOW_STEM_MISMATCH=1` — собрать всё равно). Картинки районов, фоны, Бит и логотип не попадают в атласы: они грузятся по требованию (`docs/design/client-architecture.md`, раздел 9). CI запускает `--check`.

## Устройство репозитория

```
game.project            настройки Defold (720×1280, shared_state, custom_resources=/content)
render/                 fit-рендер: логический экран целиком, без искажений, фон до краёв;
                        материал GUI «grey» для ещё не восстановленных предметов
input/                  привязки ввода (touch, multi_touch, отладочные клавиши)
main/                   main.collection: app.script (экраны, переходы), overlay (затемнение,
                        тосты, окна), audio.script (музыка по стемам, ноты, эффекты)
screens/                экраны-коллекции: splash, town, level (пока заглушки)
client/                 модули клиента: app, bus, hooks, i18n, save_io, layout, audio, platform,
                        ui, gfx, assets, qa_bridge, services/ (analytics, iap, ads)
core/                   правила игры (чистый Lua)
meta/                   мета и экономика (чистый Lua)
content/                districts.json, district_layouts.json, уровни (custom resources)
assets/                 сгенерированные картинки, звук, шрифты; assets/gen — ресурсы Defold
tools/                  тесты, сборка, генераторы арта, звука и ресурсов Defold, QA-скрипты
tests/                  тесты на чистом Lua
docs/                   дизайн-документы и скриншоты (docs/media)
web/glow.css            стиль HTML-страницы: холст на всё окно, без полос прокрутки
web/engine_template.html  шаблон страницы Defold 1.13.1 с ограничением DPR (не больше 2×)
```
