STAGE A of the GLOW core is done, plus several stage-B/C pieces. `./tools/test.sh` passes on Lua 5.1 and LuaJIT: 414 tests, 163 of them new in `tests/core/`. Files changed are only under `/home/user/game/core/` and `/home/user/game/tests/core/`; nothing committed by me, though the orchestrator's WIP snapshot commits have already picked up some of these files. The 20 levels another agent has put in `content/levels/` all pass validation and play to an end without errors or invariant breaks.

## Implemented
- **§3 randomness:** MRG32k3a, the four streams, attempt seed and clone reseed folds, weighted colour choice. Known-answer tests cover L'Ecuyer's reference output for seeds 12345×6 (first value 0.12701112204657714) and the golden first 5 outputs of each stream at seed 1. Reference values were computed separately in Python with exact integers.
- **§2 level loading:** `load_level` takes JSON text, read by my own strict parser in core (rejects null in arrays, fractions/exponents, repeated keys), or an already decoded table. All of 2.1.1–2.1.10 are checked, including the B0/B1 turbo fill runs and start boards for seeds 1..10. It also builds the canonical form and the level hash.
- **Board and start:** ids (§1.4), labels/vac with `merged` (§1.3), the start board (§4) with fills, checks, start shuffle, dirty start and pre-level boosters (unplaced when no candidate).
- **Tick and input:** the full 8-step tick (§15) with a plain-data `(due, seq)` queue, the 100 000-record guard and the turbo switch. All commands (§5): reason order, swap, swap_fail, refund, rule 6.2.1, expected-board acceptance, swipe-as-tap, tap, boosters (stick, row/col light, remix), continue, give_up, skip, `input_lock`.
- **Rules:** matching with union-find, classification and special cell (§6); hits with wires, blockers, column, dedup and `all_layers` (§7); gravity, spawn, diagonals, clamp and `hidden` (§10.1–10.3); mic release and delivery (§10.4); rest, noise growth and the credited/merged chain (§11); `has_move`, shuffle items 1–6, hint (§12); win, concert phases A–C and result (§13); scores, goals and praise.
- **Specials:** activation framework (action lists, path pins, t0 actions, retiring sources) with single Riff, Sabwoofer and Disco effects, and chains.
- **Outputs:** events (§16), hash (§17.2), replay and `core.playback` (§17.1), clone/reseed, `set_timing`, `run_to_rest`, and the full §17.3 API.
- **Speed:** one bot-style evaluation (clone, set turbo, swap, run to rest) on a 9×9 board takes about 1 ms.

## Stubbed for stage B
- **Bird (§8.3, §9):** it only does its cross. There is no target choice, no `bird_fly` event and no `bird_impact` records; `specials.bird_impact` is empty.
- **Combos (§8.5):** a two-special swap arms both and queues the activation correctly (to/from, label (a,1)), but the effect only hits the centre and `from`. There are no geometries, no "Colour X" transforms (`specials.transform` is empty), no Grand finale wiring (`hits.hit` already supports `all_layers`) and no `combo` event field.

## Module map (`core/`)
| Module | Role |
|---|---|
| `game.lua` | public facade |
| `const.lua` | codes, timings, scores |
| `util.lua` | helpers |
| `rng.lua` | generator and streams |
| `json_strict.lua` | strict level JSON reader |
| `level_schema.lua` | schema and canonical form |
| `level.lua` | normalization and rules 2.1.2–2.1.10 |
| `board.lua` | state, objects, pins, labels |
| `start.lua` | start board |
| `sched.lua` | record queue |
| `input.lua` | commands |
| `tick.lua` | the 8 steps, swap timers, record dispatch |
| `match.lua` | groups and resolution |
| `hits.lua` | hits, blockers, scores, goals |
| `specials.lua` | activation framework and effects |
| `gravity.lua` | assignment, movement, spawn |
| `moves.lua` | expected board, move list |
| `shuffle.lua` | shuffle and fallbacks |
| `flow.lua` | rest, noise, concert |
| `boosters.lua` | in-level boosters |
| `hint.lua` | hint tiers |
| `hash.lua` | state and level hash |
| `events.lua` | event buffer, state changes |

`README.md` covers the architecture, state layout and how the tick works.

Tests are in `tests/core/`: `helper.lua` (levels from pictures, `H.board` to rebuild a live board) plus tests for rng, level, start, input, swap, gravity, match, hits, flow, specials, hint, hash, golden, soak and lint. They include exact tick-by-tick kinematics (a one-cell fall gives offy 3240, 2820, 2340, 1800, 1200, 540, then lands on tick 7) and the timings "swap ends in step 2 of tick N+11" and "cleared in t, gone in step 4 of t+9". The soak test checks invariants after every tick with random play on both timings.

## Spec ambiguities and my readings
1. **§2.2 vs task.** §2.2 says `load_level(text)` checks the token stream; the task says core accepts decoded tables and must not require `tools/lib/json.lua`. I accept both. Text goes through my strict parser in core; duplicate keys can't be detected in a decoded table. The parser also rejects integers over 15 digits so values stay exact.
2. **§5.1.2 "Сюда же попадают свап двух обычных фишек одного цвета и свап двух микрофонов".** I apply this as an explicit rule: two same-colour regulars or two mics always give `fail`, even if the expected board already has a pending match through the cell. `moves()` uses the same evaluation.
3. **§2 "exits … используются только с целью deliver".** Exit flags are set, hashed and returned by `cells()` only when the level has a deliver goal. The "start mic on an exit" check also runs only with deliver.
4. **§2.0 `light {}` ("зажечь все плитки уровня").** The goal's count is the number of floor tiles; each tile that lights up is −1.
5. **§1.4.5 / §5.3 "в начале записи создаётся источник … (у Ремикса — после повторной проверки)".** I read the parenthesis as applying to the event only. Every booster record, including a failed Remix, creates a source and uses a `next_source_id`.
6. **§16 `bolt` "…прожектора".** The spec gives no exit point for the light boosters. I emit one bolt from (1,row) with dir `r` for row_light, and from (col,1) with dir `d` for col_light, `at = now`.
7. **§7.4 goal events.** One `goal` event per changed goal per hit, carrying the final `left`. A column breaking with four lit tiles gives one light event.
8. **§14 turbo "задержка старта 0".** Pieces assigned in turbo get delay 0 and vy = fall_v0. This can't be observed, because turbo lands everything in the same tick.
9. **§12.2 at start with n = 0.** I report this as having gone past item 3, so rule 2.1.10 rejects it.
10. **§17.3 error format "[at x,y]".** I use the zero-based JSON coordinates, since designers edit the file.
11. **§5.4 `continue {moves, riff}`.** `riff` is optional (nil means false); a non-boolean value is `bad_cmd`.
12. **§17.3 other API details.**
    - `result()` adds `won`; a lost game has stars 0 and moves_at_win 0.
    - Commands accept `{x,y}` or `{x=,y=}`.
    - `core.new` needs seed in 1..2^31−2.
13. **§17.2 hash details.**
    - An empty slot writes 17 zeros plus pins length 0.
    - A `swap_back` entry keeps the original swap's remembered labels.
    - Record data fields are written without a length prefix; the count per kind is fixed.
14. **§2.1.6.** "mic" counts as an element if there is a deliver goal, a mic block or mic pieces.
15. **§17.1 golden replays in `tests/golden/`.** That folder is outside my allowed paths. `tests/core/golden_test.lua` pins the level hash, final tick and state hash of a scripted game in both timings and replays it. The script never touches a special, so stage B work should not change it.
