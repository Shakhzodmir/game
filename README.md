# GLOW

Яркая музыкальная игра «три в ряд» на Defold 1.13.1 (портрет, логический экран 720×1280). Каждое совпадение звучит нотой в тональности района, а звёзды за уровни восстанавливают город и включают новые слои трека. Кодовое имя — GLOW, рабочее название релиза — Encore Town / «Город на бис».

Документы:
- `docs/design/README.md` — индекс; `docs/design/decisions.md` — журнал решений (главный), правила ядра, мета и экономика, архитектура клиента, арт-дирекшн;
- `docs/plan-v2.md` — план: производство, сервисы, платформы, софт-лонч, дорожная карта, риски (в разделе 1 — честный срез, что проверено и чем);
- `docs/levels/README.md` — таблица 100 уровней; `docs/STATUS.md` — где стоит сборка; `docs/handoff/` — записки исполнителей по частям.

## Тесты

```sh
./tools/test.sh            # Lua 5.1 (как в веб-сборке) и LuaJIT (как на мобильных)
./tools/test.sh --filter bus
```

Тесты на чистом Lua лежат в `tests/`: `tests/core` (правила, оракулы по тексту спецификации, золотые реплеи в `tests/golden`), `tests/meta` (мета и экономика), `tests/client` (модули клиента и строгие заглушки Defold, на которых исполняются настоящие `.script` и `.gui_script`; сессионные тесты прогоняют весь путь игрока), `tests/tools` (уровни, обучение, боты). Нужны `lua5.1` и `luajit`.

Быстрые проверки без движка:

```sh
./tools/check_syntax.sh                   # синтаксис всех Lua-файлов, скрипты Defold тоже, на двух ВМ
luajit tools/check_refs.lua               # ссылки: require, картинки, звуки, ключи i18n, темы шины, сообщения, пути Defold
luajit tools/levels.lua validate --strict # все 100 уровней по правилам ядра и плану
python3 tools/gen_defold.py --check       # сгенерированные ресурсы свежие
```

CI на каждый пуш запускает тесты и собирает HTML5 настоящим `bob` 1.13.1 (около 2 минут).

## Уровни и боты

```sh
luajit tools/levels.lua stats                          # сложности, 126 звёзд, первое появление элементов
luajit tools/levels.lua preview 50                     # поле уровня в ASCII
luajit tools/bot/run.lua 50 --games 8                  # партии бота
luajit tools/bot/tune.lua --n 300 --jobs 3 --work /tmp/glow_tune   # подбор ходов, отчёт docs/levels/tuning.md
```

Подробно — `tools/README.md`; таблица уровней и обучение — `docs/levels/README.md`.

## Веб-сборка

Нужны python3, JDK 25 и `bob.jar` от Defold 1.13.1.

```sh
JAVA=/path/to/java BOB=/path/to/bob.jar VARIANT=debug ./tools/build_web.sh
python3 -m http.server 8791 -d dist/GLOW     # открыть http://localhost:8791/
```

`VARIANT=release` — сборка для публикации (по умолчанию). Скрипт сначала запускает `tools/gen_defold.py` (без python3 он останавливается; `SKIP_GEN=1` — собрать без генератора, если сгенерированное точно свежее), затем bob; результат — `dist/GLOW/index.html`. В debug-сборке лежит файл `DEBUG_BUILD_DO_NOT_PUBLISH`: её нельзя выкладывать на порталы.

Локально `bob` не обязателен: сборку проверяет CI, а артефакт (`glow-web`) можно скачать со страницы запуска. 30.10.2026 игра собрана локально (JDK 25 и `bob.jar`) и прогнана `tools/qa/web_screens.mjs` в headless Chromium: 45 проверок зелёные, снимки лежат в `docs/media`. На устройстве и на живых игроках она ещё не проверялась (`docs/plan-v2.md`, веха M1).

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
screens/                экраны-коллекции: splash, town (город), level (поле, HUD, окна, обучение)
gui/                    общий набор кнопок и окна: старт, магазин, жизни, настройки, автомат, сундук,
                        подарок, концерт района; пауза, «+5 ходов», поражение, итоги, покупка бустера
client/                 модули клиента: app, bus, hooks, i18n, save_io, layout, audio, platform,
                        ui, gfx, assets, views, popups, flow, rewards, tutorial, level_* (сессия, ввод,
                        анимации, эффекты, звук, HUD, окна), qa_bridge, services/ (analytics, iap, ads)
core/                   правила игры (чистый Lua)
meta/                   мета и экономика (чистый Lua)
content/                districts.json, district_layouts.json, tutorials.json, 100 уровней (custom resources:
                        вся папка входит в сборку, поэтому документов в ней нет)
assets/                 сгенерированные картинки, звук, шрифты, частицы; assets/gen — ресурсы Defold
tools/                  тесты, сборка, генераторы арта, звука и ресурсов Defold, уровни и боты, QA-скрипты
tests/                  тесты на чистом Lua (около 1500 на каждой ВМ)
docs/                   дизайн-документы, план v2, таблица уровней, записки (handoff), скриншоты (media)
web/glow.css            стиль HTML-страницы: холст на всё окно, без полос прокрутки
web/engine_template.html  шаблон страницы Defold 1.13.1 с ограничением DPR (не больше 2×)
```
