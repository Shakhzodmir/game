# GLOW core

Deterministic, tick-based match-3 simulation in pure Lua (the Lua 5.1 subset
that runs on PUC Lua 5.1 in the web build and on LuaJIT elsewhere). The
contract is `docs/design/core-rules.md` (v3.1); section numbers below (§)
refer to it. No Defold APIs, no `os`/`io`, no `math.random`: the core gets a
level table (or JSON text), a seed and commands, and produces events and
queries.

## Usage

```lua
local core = require("core.game")

local level, errs = core.load_level(json_text)   -- or an already decoded table
local game = core.new(level, { seed = core.attempt_seed(level.id, attempt, salt),
                               attempt = attempt, salt = salt, help = 0,
                               boosters = { "riff" }, timing = "normal" })

game:input({ type = "swap", from = { 3, 4 }, to = { 4, 4 } })  -- between ticks
game:step()                                                   -- one tick (1/60 s)
for _, ev in ipairs(game:drain_events()) do ... end
local pieces = game:pieces()                                  -- positions every frame
```

Coordinates are 1-based `{x, y}` arrays (`{x = , y = }` is accepted too).
Enumerations in events and queries are strings (`"red"`, `"riff"`,
`"idle"`...); inside the core everything is a numeric code (`core/const.lua`,
the codes of §17.2).

Queries (pure, no randomness, no events): `can_swap`, `has_move`, `moves`,
`hint`, `is_stable`, `pieces`, `cells`, `status`, `result`, `hash`, `replay`.
Bots: `game:clone{reseed = k}`, `clone:set_timing("turbo")`,
`clone:run_to_rest()`. Replays: `game:replay()` and
`core.playback(level, replay)` (re-runs the commands and checks the hash).

## Module map

| Module | Role |
|---|---|
| `game.lua` | public facade (§17.3): `load_level`, `new`, game methods, clone, replay playback |
| `const.lua` | codes of every enumeration, timings normal/turbo (§14), scores (§7.4), `R(d)` |
| `util.lua` | integer checks, index helpers, labels, sorted-array sets, stable sort, deep copy |
| `rng.lua` | MRG32k3a, the four streams, seed folds, weighted colour choice (§3) |
| `json_strict.lua` | token-checking JSON reader for level text (§2.2) |
| `level_schema.lua` | level schema (§2.0, rule 2.1.1) and canonical form (§2.2) |
| `level.lua` | normalization and validation rules 2.1.2-2.1.10 (B0/B1 fill runs, start seeds) |
| `board.lua` | state construction, objects and ids (§1.4), pins, labels (§1.3), goal lookup, `mf()` |
| `start.lua` | start board (§4): fills, checks, start shuffle, ids, pre-level boosters |
| `sched.lua` | scheduler queue of plain records ordered by `(due, seq)` (§15.1, §15.2) |
| `input.lua` | commands (§5): validation order, swap/fail/swipe-as-tap, tap, boosters, continue, give_up, skip, turbo switch |
| `tick.lua` | `step()`: the 8 steps of §15, swap timers and refunds (§5.1.3), record dispatch |
| `match.lua` | colour map, union-find groups, classification (§6.1), special cell (§6.2), resolution (§6.3), praise |
| `hits.lua` | sources, the hit (§7.1), blockers (§7.3), scores and goals (§7.4), chain launch |
| `effects.lua` | effect framework (§7.2.6, §7.2.7): action lists, dedup, path pins, t0 actions, record handlers; geometry (rays, rings), `bolt`/`activate` events; Riff and Sabwoofer effects |
| `specials.lua` | the `activate` record (§7.2), single specials, Disco ball and its steps (§8.4); registers the record handlers |
| `bird.lua` | the Bird (§8.3): cross, level table, candidates, density, cargo tuples (§9), flights, reservations, `bird_impact`, Trio |
| `combos.lua` | the ten combos (§8.5): Cross, Triple cross, Bass drop, Bird with cargo, Trio, Grand finale, "Colour X" transforms |
| `gravity.lua` | assignment pass (§10.1), movement (§10.2), spawn colours and help (§10.3), mic release (§10.4), `hidden` |
| `moves.lua` | expected board and swap evaluation (§5.1.2), move list and `has_move` (§12.1) |
| `shuffle.lua` | shuffle and fallbacks (§12.2), used by the start, the rest step and Remix |
| `flow.lua` | rest detection, step 8: noise growth, out of moves, shuffle (§11); final concert (§13) |
| `boosters.lua` | in-level boosters (§5.3): stick, row/column light, Remix |
| `hint.lua` | hint tiers (§12.3) |
| `hash.lua` | state hash layout and integer fold (§17.2), byte fold for the level hash |
| `events.lua` | event buffer and game-state changes (§16) |

## State

A game is `{s = state}` with methods from a metatable; the state itself is
plain data (numbers, booleans, arrays and tables of them): no closures, no
metatables, no shared sub-tables except the read-only normalized level. So
`clone()` is a deep copy and `hash()` reads everything it needs.

- Cells: arrays of size `W*H` indexed by `i = (y-1)*W + x`: `exists`,
  `spawner`, `exit`, `floor` (hp), `wires` (hp), `vac_mv`/`vac_wv`, `slot`
  (object id or 0), `seg_top`/`seg_bot` (rows of the segment).
- Objects: `s.objs[id]` with `kind, color, special, axis, blocker, hp,
  state, cell, mv, wv, offx, offy, vy, delay, settle, tk, td, pins`. A falling
  piece is already written into its target cell; the offsets hold the lag.
  A 2x2 column is one object keyed by its top-left cell, its id in 4 slots.
- Counters of §17.2 item 2, `swaps` (swaps in flight in start order),
  `queue` (records), `sources` (active sources by id, each with `nrec`, the
  number of its queued records), `eom` (end-of-move queue), `praise`,
  `unplaced`, `rng` (4 streams x 6 words), `cmds` (accepted commands for the
  replay), `ev` (event buffer, not hashed).

## The tick

`step()` increments `tick`; `now = tick` (commands applied before the tick
already ran with `now = tick + 1`; they never hit, they only check, change
states and counters and queue records due `now`).

1. (commands of this window are already applied)
2. swap, swap_fail and swap_back timers expiring now, in start order, then
   shuffle locks by cell. If any expired: full match search with rule 6.2.1
   (the new special goes to the cell of the finished swap with the smallest
   act), then refunds of the swaps whose cells joined no group.
3. records due `<= now` in `(due, seq)` order, including records queued
   while this step runs. Activations build their full action list, pin the
   path, run the actions of `t0` at once and queue one record per later
   action. More than 100 000 records in a tick is a core error.
4. objects in `clear` whose timer expired leave the board.
5. gravity: one bottom-up pass assigning transfers, spawns and diagonals.
6. movement: per column bottom-up with the clamp; turbo lands everything.
7. match search if the board is dirty; microphone delivery every tick.
8. at rest: noise growth for each queued action, out of moves, shuffle when
   there is no move; `won_wait` -> concert, concert phase C; `rest_flag`.

A duration `D` started at `now` ends at tick `now + D` in the step that owns
it (swap timers step 2, `clear` step 4, records step 3). Records queued in
steps 4-8 with `due <= now` move to `now + 1`.

## Determinism rules (checked by `tests/core/lint_test.lua`)

- No `pairs`/`next` where order matters; every remaining use carries the
  comment `-- order-independent`. Board data are fixed-size arrays.
- Every `table.sort` has a strict total comparator, or sorts plain numbers
  (marked `-- numbers`).
- No `math.random`, `os.*`, `io.*`; no tools modules. Integers only.
- Randomness only through `rng.lua`, one `next_int` per choice (§3.2).

## Specials (§7.2, §8, §9)

A launch (swap end, tap, chain hit, "Colour X" fire, concert phase B) puts
the special into `armed` and queues an `activate` record (§15.2 kind 1)
with the launch label. When that record runs (its tick is `t0`), it creates
the effect source (`own` = the armed special(s), `centre` = its cell) and
builds the full action list of the effect: `{tick, kind, data}` entries
whose kinds are record kinds (hit, disco_step, transform, bird_impact,
activate). `effects.run` then

1. sorts the list stably by tick (the list is built in natural order: the
   normal-mode offset, then cell index or the explicit order of §8);
2. keeps the first hit per object (per cell for an `all_layers` source);
3. pins the path when the effect asks for it (§7.2.7): every idle movable
   piece in a cell hit later than `t0`;
4. runs the actions due at `t0` at once, in order, inside the record;
5. queues the rest, one record per action, in order.

The first hit of a source on its `centre` removes its own specials (`clear`,
cause `fired`), then hits the now open slot. A source lives while it owns
queued records (kinds 2-5 carry its id first); pins and Bird reservations
are always released by those records, so a dead source leaves none.

- Riff and Sabwoofer: `effects.riff`, `effects.sub` (also used by the Bird's
  cargo, the Bass drop and the fires of "Colour X").
- Disco: list `L` pinned at `t0` (balloons of X listed but not pinned);
  step `k` at `t0 + 2k` acts only if its piece is still pinned by the Disco
  (or the balloon is intact); own cell after the list.
- Bird: cross at `t0` (inline), then the target is chosen on the board as it
  is after the cross (§9 levels, density, one `effects` draw among equal
  best), reserved and its piece pinned; `bird_impact` at `t0 + 33` releases
  both and hits, or fires the cargo with a new source.
- Combos: one source for the combo effect (`own` = both specials, the one in
  `to` first). "Colour X" pins its list, transforms by `k`, hits `to` and
  `from` after the last transform slot, then queues one `activate` record per
  entry; the kind of the new specials is read from the armed non-disco
  special still in `own`.

Turbo keeps the same natural order; every effect delay is 0 there, so a
whole effect (Bird flight included) runs inside its activation record, and
chains (delay 0) run later in the same step 3.

## Status

Implemented: all of §0-§17, including every special and combo (§8), Bird
targeting (§9), taps and special swaps (§5.1.4, §5.1.5, §5.2).

Tests: `tests/core/*_test.lua`, run by `./tools/test.sh` on both VMs.
`tests/core/helper.lua` builds levels from pictures and can rebuild a live
board (`H.board`) for tick-by-tick scenarios.
