# core-rules v3 — triage of 76 review findings

Legend: APPLY = applied as proposed; MOD = applied in modified form (why); REJECT = not applied (why).
A# = architect's binding decision number. SR = state-races, GS = gravity-spawn, MH = match-hit-specials, DI = determinism-impl.
Spec sections refer to core-rules.md v3.

## state-races
- SR1 [blocker] swap "has match" in step 2 but resolved in step 7 -> APPLY (A1): step 2 exchanges, runs full §6 search at once, refunds swaps outside groups; 6.2.1 only in step 2, smallest act wins (§5.1.3, §15).
- SR2 [blocker] disco/transform list L targets move or get swapped -> MOD (A3): flag `pinned` instead of wait-only reservation; step acts by piece id if still pinned by this source, else skipped with its slot kept; wired pieces allowed in single-disco L, excluded in "Цвет X" (§1.2, §8.4, §8.5).
- SR3 [major] firing lifecycle undefined (sub swell, combos, double trigger, Цвет X own cell) -> APPLY (A2) (§7.2); plus path pins (see DI2).
- SR4 [major] tap/stick between ticks, timer expiry tick, turbo zero delays -> APPLY (A4) §15.1.
- SR5 [major] bird target contents change during flight; levels ignore state -> APPLY: target piece pinned until impact, impact hits the cell; levels count idle unpinned pieces only; level 0 = not a candidate (§8.3, §9).
- SR6 [major] vac not set for fired specials, mic, column, initial -> APPLY (A5) rule 1.3.4.
- SR7 [major] refunded swap keeps (act,0) labels -> APPLY (A5): labels restored on refund.
- SR8 [major] destroyed blocker in clear matches two gravity rows -> APPLY (A6/A7): ordered first-match rules, clear -> wait.
- SR9 [major] shuffle/remix teleports pieces under the player's finger -> APPLY (A8): moved/recoloured pieces locked in `swap` for T.shuffle (30/1).
- SR10 [major] concert phase timing, snapshot, labels -> APPLY (A9): explicit timeline, B-snapshot armed at t_B, label (A+1,1).
- SR11 [minor] booster rest flag, booster label, row_light timing with voids -> APPLY (§5.3, rule 1.3.9).
- SR12 [minor] moves_at_win with in-flight swaps -> APPLY (A9): read at won_wait -> concert.
- SR13 [minor] skip mid-flight re-timing -> MOD (A4): timers clamped to now+T_turbo, all records due -> now (order kept), delays 0, falls land in the next step 6.
- SR14 [minor] transformed specials: unreachable chain clause, fire order -> MOD: stay armed; entry k fires at t_last + fire_step*(k+1) by L index; skipped entries keep their slot and do not fire (consistent with A3 "slot still used").
- SR15 [minor] noise growth candidate list rebuild -> APPLY: rebuilt per queued action from noise currently on board; additionally excludes spawner cells (GS13).
- SR16 [minor] mic gap counting, mic in clear, mic on exit at start -> APPLY (A10): moves_made/last_mic, delivered mic leaves the count at once, validation forbids preset mic on exit, exit check every tick.
- SR17 [minor] dirty triggers incl. swap_fail end; landing tick for never-fallen pieces -> APPLY: any piece becoming idle dirties the board; settle_tick replaces landing tick.
- SR18 [minor] shuffle with no candidates and no noise soft-locks -> APPLY (A8): candidate->Riff, noise->Riff (not a goal), wired->Riff, else out_of_moves.

## gravity-spawn
- GS1 [blocker] swapped piece falls away between step 2 and 7 -> APPLY via A1 (match resolved inside step 2, pieces enter clear before gravity). Proposed "swap cells are wait in step 5" and "refund decided in step 7" REJECTED: unnecessary once step 2 resolves immediately.
- GS2 [major] diagonal slider starts visually below a vertical faller -> APPLY (A6): donor only if no faller below is visually above c, else wait; clamp never raises offy.
- GS3 [minor] slider vs refill of its source cell; offx shrinks by vy while held -> APPLY (A6): refill inherits vy=min, delay+1; offx shrinks by applied vertical displacement.
- GS4 [major] kinematics of spawn/slide/idle->fall, "highest", turbo infinity -> MOD: start-delay counter is per TARGET column (the column where the clamp applies); the source column is covered by the refill rule; spawn offy formula as proposed; turbo lands in step 6, no infinite values.
- GS5 [major] scan table ambiguous, segment undefined, spawner-above rule -> APPLY (A6): explicit scan() with ordered rules; spawner must have void/outside directly above; spawner/exit lists validated. "top" keeps v2 meaning (topmost cell of each column).
- GS6 [major] destroyed blockers idle vs clear -> APPLY (A7): clear like pieces, column's 4 cells together.
- GS7 [major] vac for fired specials, mic, column, initial; freed-piece label -> APPLY (A5).
- GS8 [major] fillability validator nondeterministic, misses cells under blockers -> APPLY (A12): B0 and B1, colourless tokens, steps 4-6 turbo.
- GS9 [major] mic release counters ambiguous -> APPLY (A10).
- GS10 [major] exits only per column; mic reachability; mic presets -> MOD: exits "bottom" = every segment bottom; segment bottoms filled in B1 must be exits; exits/spawners disjoint; no preset mic on exit. "At least 1 starting mic" REJECTED (mics may all come from spawners): 0 <= presets <= min(on_board_max, total).
- GS11 [major] spawn colour draw order/weights -> APPLY (A11).
- GS12 [major] L lists vs gravity (piece or cell) -> APPLY via A3 (pinned pieces do not fall; act by id).
- GS13 [minor] holes legal at rest; noise growing onto spawners -> APPLY: holes legal and skipped; noise growth excludes spawner cells.
- GS14 [minor] spawned pieces drawn inside an upper segment -> APPLY: `hidden` flag above spawner top edge.
- GS15 [minor] sub cell refilled during swell -> APPLY (A2: sub armed until ring 0) + path pins keep rings 1-2 in place.

## match-hit-specials
- MH1 [blocker] stale swap check -> APPLY (A1). Proposed tie-break "highest act" REJECTED: A1 fixes smallest act.
- MH2 [blocker] disco L -> MOD (A3): flag `pinned` instead of a new state `marked`; pinned pieces still match and are hit normally; a wired pinned piece loses a layer and stays pinned.
- MH3 [major] when a fired special/combo leaves its cell; Цвет X never hits to/from -> MOD (A2): both combo specials removed at the combo's first centre hit; for Цвет X that hit (to, then from) is at t0 + transform_step*|L| (the slot after the last transform), not at the last fire tick as proposed.
- MH4 [major] Цвет X transforms wired pieces -> APPLY (A3): Цвет X lists and X exclude wired; single disco includes them.
- MH5 [major] tap activation timing -> MOD (A4): tap arms at input, activation record due now, ordinary (due,seq) order. "Run before all other records of the tick" REJECTED: plain queue order is already deterministic.
- MH6 [major] floor openness read before/after arming -> APPLY: openness taken at the start of the hit; arming never damages the floor.
- MH7 [major] column dedup, double floor damage, vac, goal count -> APPLY.
- MH8 [major] bird targets column cells already hit / Trio on one column -> APPLY: a column is a candidate only via its top-left cell; objects hit or reserved by the source are excluded; counted once in sums.
- MH9 [major] bird level table holes -> APPLY (pinned pieces added to level 0).
- MH10 [major] RNG draw on single option -> APPLY (§3.2).
- MH11 [major] score underspecified -> APPLY (§7.4 exhaustive table).
- MH12 [major] stale vac (dup SR6); "группы" in 1.3.6 -> APPLY.
- MH13 [major] transformed specials firing schedule -> MOD: fire slot per L index k (t_last + fire_step*(k+1)); skipped entries keep their slot (A3 consistency).
- MH14 [minor] 6.2.1 tie with two swaps -> MOD: smallest act (A1); swap_back/swap_fail never qualify.
- MH15 [minor] 6.2 rule 2/3 defaults -> APPLY: settle_tick; sub without unwired intersection -> rule 3.
- MH16 [minor] preset/wired pieces forming a match -> APPLY: validation rule 2.1.9; group without candidate -> no special.
- MH17 [minor] carrying bird with no candidate drops its cargo -> APPLY: cargo fires at the bird's own cell at t0 + bird_flight.
- MH18 [minor] balloon needs source colour -> APPLY.
- MH19 [minor] swap_back labels (dup SR7) -> APPLY.

## determinism-impl
- DI1 [blocker] scheduler/timer semantics -> MOD (A4): plain-data records ordered by (due, seq); hits due at t0 run inside the activation in the effect's natural order; records created in steps 4-8 with due <= now run in step 3 of now+1; loop guard raises an error. Proposal "sort same-due hits by cell index" kept only where natural order says so.
- DI2 [blocker] special leaves at t0 -> vertical riff/sub never clear the column above -> MOD: A2 lifecycle (removal at own-cell hit) applied; "stay armed until the last hit" REJECTED (A2). A2 alone still lets the column above a riff/sub fall into its cell and dodge later bolts/rings, so v3 adds PATH PINS: at activation an effect pins the idle movable pieces of every cell it will hit later (same pinned concept as A3). Flagged in decisions.md for architect review.
- DI3 [major] swap end vs step 7; swap_back end -> APPLY (A1). Proposal "keep pieces in swap until step 7" REJECTED (A1). swap_back end: exchange back, idle, dirty, no re-check.
- DI4 [major] delayed sequences piece vs cell -> APPLY (A3).
- DI5 [major] MRG32k3a constants, output range, seed hash, salt -> APPLY: reference code, seed fold, salt range, replay seed authoritative (§3). Exactness of Lua % re-checked (quotient < 2^21).
- DI6 [major] RNG consumption procedures -> APPLY (§3.2-3.3, §4, §10.3).
- DI7 [major] shuffle procedure underspecified -> APPLY (§12.2).
- DI8 [major] shuffle infinite loop -> MOD (A8): fallback via noise and wired pieces only; "replace any non-column blocker" REJECTED (would erase designed obstacles and goal items); final fallback out_of_moves.
- DI9 [major] turbo infinity, skip, clone switch -> APPLY (A4) (§14, §15.1).
- DI10 [major] replay/hash undefined -> MOD: header, final_tick/final_hash, full hashed field list and integer fold as proposed; level hash uses the same fold over canonical JSON bytes instead of sha1 (no sha1 needed in pure Lua).
- DI11 [major] clone for bots undefined; clairvoyant lookahead -> MOD: placed in §17.2 (structure 0-17 kept): clone{reseed}, set_timing, run_to_rest cap; lookahead must reseed.
- DI12 [major] level JSON schema -> APPLY (§2.0).
- DI13 [major] spawn_weights validation -> APPLY (A11): keys == colors, integers >= 1. Proposed upper bound 1000 not added (not needed for exactness).
- DI14 [major] validation rules 5/7 (holes after blocker break, stand reachability, presets) -> MOD: B1 covers blocker cells; reachability via segment-bottom exit rule; preset mic/match rules applied; column = 1 object. "At least 2*W free cells" REJECTED: arbitrary; soft-lock is removed by the out_of_moves fallback.
- DI15 [major] concert timing -> APPLY (A9).
- DI16 [major] bird targeting details -> APPLY: levels after the cross, density includes itself, payload over all area cells, carried riff fires along the chosen axis, Trio targets chosen in sequence.
- DI17 [major] mic counters (dup GS9) -> APPLY (A10).
- DI18 [minor] tie-breaks (6.2.1, landing tick, move count, noise, hint) -> MOD: (a) smallest act per A1; (b)-(e) applied (settle_tick updated on every return to idle).
- DI19 [minor] Lua VM determinism hazards -> APPLY (§0 rules).
- DI20 [minor] fall timing details -> MOD: same as GS4 (counter per target column, spawn vy=fall_v0, offx by applied displacement).
- DI21 [minor] 8.5 firing schedule (dup MH13) -> MOD as MH13.
- DI22 [minor] performance budget -> MOD: rule that an incremental match search is allowed only if result-identical (property test); microsecond budget and CI game counts REJECTED from the rules spec (belong to the tooling plan).
- DI23 [minor] API surface (can_swap, purity, input result) -> APPLY (§5.0, §17.2).
- DI24 [minor] event order -> APPLY (§16 causal order).

# Round 2 (v3 -> v3.1)

Three verifiers checked v3: RC = resolution-check, TW = tick-walkthrough (F1-F7), IM = implementer. DF = the design-fairness batch (arrived late in round 1; triaged here). Spec sections refer to core-rules.md v3.1.

## resolution-check
- RC1 [major] fired special leaves its cell instantly or via clear -> APPLY: removal puts the special(s) into `clear` for T.clear, event clear{cause=fired}, no score/goal/floor, vac = activation label (§7.2.4, §7.1 item 0, source fields own/centre in §1.4.6).
- RC2 [major] no id allocation; source lifetime; seq after renumber; praise not hashed -> APPLY: §1.4 (next_piece_id/next_source_id hashed, new ids only for spawns and group specials, in-place conversions keep id and label, sources active while they have records); seq := k; praise_best hashed (§17.2 item 7).
- RC3 [major] bird table: tile clause vs "non-idle = level 0" -> APPLY: the note covers piece clauses only; tile clause judged on its own (open slot qualifies); a pinned piece zeroes the whole cell (A3: pinned excluded from bird candidates).
- RC4 [major] cargo sums count a column only at its top-left cell -> APPLY: an object counts once if any of its cells is in the area (§9).
- RC5 [minor] 12.2.6 sends a live paid continue into a dead board -> MOD: A8 fixes the target state as out_of_moves, so it stays, with flag `stuck`: continue refused (no_candidates), boosters and give_up remain. Going to `lost` REJECTED (contradicts A8).
- RC6 [minor] carrying bird with no target: which cell -> APPLY: centre `to`.
- RC7 [minor] dirty-flag reset timing -> APPLY (RC variant): each search sets dirty=false after resolving its groups; resolution never sets it (freed group pieces were already in their lines; a new special does not match).
- RC8 [minor] start fallback can leave a match -> MOD: if a match remains the board starts dirty and step 7 of tick 1 resolves it with labels (0,0); 2.1.10 = seeds 1..10 never reach 12.2 item 3. RC's stricter "no start shuffle at all for seeds 1..10" REJECTED: a successful permutation is a normal start.
- RC9 [minor] special_new ordered two ways -> APPLY: special placed after all group cells, then special_new, then the bonus score event at the special cell (§6.3, §16).
- RC10 [minor] canonical level JSON -> APPLY (§2.2).
- RC11 [minor] pieces() lacks pinned -> APPLY (§17.3).
- RC12 [minor] §5.1.3 prose vs pseudocode -> APPLY: "no refunds after swap_back; the step-2 search still checks those pieces".
- RC13 [minor] spawn_weights upper bound -> APPLY: 1..1000 (round-1 DI13 rejection reversed: cheap guard against skewed modulo).
- RC14 [minor] decisions.md has two "## 6" -> APPLY: v3 section renumbered "## 7", core-rules header points to it. File title "(v2)" kept: it is the journal of plan v2, not the spec version.
- RC on DI2 path pins -> KEEP; decisions 7.4 now states the rule is normative until the architect replaces it.
- RC open design items -> see DF below.

## tick-walkthrough
- F1 [major] labels read only the target's vac; pieces falling through fresh cells keep stale labels -> APPLY: 1.3.5 takes max over T.vac and every cell strictly between S and T (vertical); 1.3.6 spawn takes max over c and the segment above.
- F2 [major] `act` in step 2 = global counter or the swap's own number -> APPLY: swap stores `a` at acceptance; (a,0)/(a,1) everywhere (1.3.1, 1.3.3, 1.3.9, 5.1.3, 5.1.4, 6.2.1).
- F3 [medium] ids/sources/seq/praise -> APPLY (dup RC2); column key = top-left index; shuffle locks hashed only per piece.
- F4a [medium] cargo activation inline or as a new record -> APPLY: inline inside the bird_impact record, t0 = now; cargo own-cell hit is ordinary.
- F4b [medium] cargo with no candidates: cell and Riff axis -> APPLY: centre `to`; Riff cargo takes the partner Riff's own axis.
- F4c [medium] Trio with < 3 candidates; turbo ordering -> APPLY: order = cross (by index), selections, impacts in selection order; a selection with no candidate drops it and all later ones, no draw.
- F5 [minor] draw only on real ties -> APPLY: one draw among equal best even if unique (3.2.1, §9).
- F6 [minor] dirty reset timing -> APPLY as RC7. F6's "clear at start, resolution may set again" REJECTED: it would delay rest by a tick after wire-freeing groups with no benefit.
- F7 [minor] level-0 note scope -> dup RC3.

## implementer
- IM1 [major] fired special removal -> dup RC1.
- IM2 [major] id allocation -> dup RC2. IM's "new id for noise growth / noise->Riff" REJECTED in favour of one rule: every in-place conversion keeps id and label.
- IM3 [major] hash not reproducible (codes, record kinds, layout) -> APPLY: enum code table, one record per action with a fixed field table (§15.2), layout rules (always emit, length-prefix lists, column emitted in all 4 cells), counters/praise/unplaced/stuck/input_lock added (§17.2).
- IM4 [major] events underspecified -> APPLY: §16 table with fields, domains and emission rule; per-hit event order; one score event per hit; goal index 1-based, left clamped at 0; bolt/ring emitted at activation with `at` even with no cells; continue_riff; booster {at|row|col, ok}; state reason.
- IM5 [minor] dirty reset vs resolution -> dup RC7 (placing a new special does not dirty).
- IM6 [minor] start fallback stream / 100 fills / match left / has_move vs 3 moves -> APPLY: stream init, exactly 100 fills, dirty start, 2.1.10; the shuffle's weaker pair check at start is intentional (fallback only).
- IM7 [minor] swap.act -> dup F2.
- IM8 [minor] "упёрлась" undefined at equality -> APPLY: stuck iff lim > offy - vy (strict); then new = min(lim, offy), vy = min(vy, B.vy).
- IM9 [minor] level table contradictions (tile, pinned special, idle mic) -> APPLY (dup RC3); level 3 requires an idle mic.
- IM10 [minor] cargo cell in combo, axis with no target, reservation end -> APPLY: `to`; partner Riff's axis (not IM's `h`: the player saw that Riff); reservation released when the bird_impact record runs.
- IM11 [minor] draws -> dup F5.
- IM12 [minor] seq renumbering -> APPLY: 1..k, counter := k.
- IM13 [minor] API contract gaps -> APPLY: §17.3 table (load_level, new/opts, input returns incl. 'fail', moves() element, hint nil, run_to_rest return, cells(), status(), result()); reason precedence and `bad_cmd` in §5.0; blockers listed by pieces() with item/hp.
- IM14 [minor] JSON required fields, decoder limits, canonical form -> APPLY: element fields required, token-stream checks in the loader, canonical form (§2.0, §2.2).
- IM15 [minor] remix n>=2 checked only at input -> APPLY: re-checked at execution; failure -> booster{ok=false} + unplaced.
- IM16 [minor] hit on noise already in clear -> APPLY: only a hit removing hp from an intact noise sets noise_hit.
- IM17 [major gameplay] noise credit moves to the later action -> MOD: merge links (1.3.10 `merged`, §11 credited chain). IM's rule "every act that is the mv of a group piece" REJECTED: max() has already relabelled those pieces to the later act, so it does not help in the stated scenario.
- IM18 [minor gameplay] fallback removing the last noise makes break-noise unwinnable -> MOD: chain order restored to the proposal A8 adopted (wired before noise); the removed noise counts toward break only if it was the last one (otherwise "not a goal" per A8 stays).
- IM19 [minor gameplay] fallback 6 sells useless continues -> dup RC5.
- IM20 [minor gameplay] paid items vanish silently -> APPLY: `unplaced` list in result() for unplaced pre-level boosters, continue Riffs and empty remixes; stick/row/col with no effect rejected with bad_cell (covers stick on a mic or a void).
- IM21 [minor doc] path-pin status, duplicate "## 6" -> APPLY (dup RC14).

## design-fairness (untriaged in round 1)
- DF1 [blocker] swap resolved after gravity -> already fixed in v3 (A1).
- DF2 [major] shuffle fallbacks: recolour check, empty chain, noise goal -> v3 + round 2: attempts need a swap pair; chain per A8; last noise counts. Validator rule "on_board_max + 4*columns < cells" REJECTED: the chain ends in out_of_moves (stuck), no soft-lock, and the rule would forbid legitimate dense layouts.
- DF3 [major] shuffle needs a duration -> v3 (A8: T.shuffle 30; the proposed 60 REJECTED by A8).
- DF4 [major] Disco list by cell; dynamic E -> REJECT (A3: pinned list acted on by id).
- DF5 [major] wired pieces in L -> v3 (A3).
- DF6 [major] bird target stale; retarget -> REJECT (A3: target pinned until impact; impact hits the cell).
- DF7 [major] bird cargo: cross first; axis -> v3 already (cross at centre; axis from §9).
- DF8 [major] cargo weighting contradicts the plan; 2x2 double count -> APPLY: lexicographic tuple (goal objects, cells under a mic, level 2, level 1), objects counted once.
- DF9 [major] Grand finale absorbed by wires/blockers -> APPLY: source flag all_layers (wires, slot and floor of every cell are hit; column floors per own cell).
- DF10 [major] client selection rules -> APPLY: §5.5 (binding for the client).
- DF11 [major] swipe of a special toward edge/void/blocker rejected -> APPLY: §5.1.5 executes it as a tap; a busy or pinned `to` is still rejected (not_movable).
- DF12 [major] noise credit -> MOD (IM17).
- DF13 [major] booster/concert labels -> v3.
- DF14 [major] praise emission -> APPLY: praise_best[m], highest threshold only, each word at most once per action.
- DF15 [major] hint tiers -> APPLY: combo rank in tier 4, special rank in tier 3 (disco+regular = disco), progress includes deliver, special moves ranked in tier 2; (c) concrete/foreign balloons already excluded in v3.
- DF16 [minor] transformed specials immune -> v3.
- DF17 [minor] bird levels (tile under mic/box, blocker under mic, unmatched cells) -> (a),(c) v3; (b) APPLY modified: level 3 also for a single-cell blocker with hp 1 under an idle mic (a hit that does not free the cell does not count).
- DF18 [minor] hits on falling pieces; Disco vs balloons -> falling pieces REJECT (hits address cells; changing it breaks the registered-cell model); balloons APPLY (L includes intact balloons of colour X, not in «Цвет X»).
- DF19 [minor] paid items wasted -> APPLY (stick predicate, remix requires a swap pair and re-checks, unplaced). "Place on any regular piece, stripping wires" REJECTED: refund is cleaner.
- DF20 [minor] boosters dead in out_of_moves -> APPLY: allowed at rest; state -> playing; step 8 returns to out_of_moves or won_wait.
- DF21 [minor] moves_at_win / phase B snapshot -> v3 (A9).
- DF22 [minor] skip result differs -> REJECT (A4: skip = turbo switch).
- DF23 [minor] exits and mic gap -> v3 (A10). "Explicit exit must have no cell below" REJECTED: every filled segment bottom must already be an exit; extra mid-segment exits are a designer choice.
- DF24 [minor] spawn_weights >= 1 -> v3 (+ cap 1000).
- DF25 [minor] assist colour ignores balloons -> APPLY: forced colour = collect remainder, else goal balloons, else mf(), else lowest.
- DF26 [minor] silent rejections -> APPLY: same-colour pairs and two mics become swap_fail (bounce); input already returns reasons.
- DF27 [minor] strict acceptance slows chained input -> APPLY: acceptance on the "expected board" (falling pieces at target cells, swapping pieces at destination); step 2 + refund still decide.
- DF28 [minor] no blocking-mode flag -> APPLY: option input_lock (constructor, replay header, hash).
- DF29 [minor] unlogged plan deviations -> APPLY: board size 6..9 x 6..11 (as plan); skip scope and client-side slow motion logged (decisions 7.32, §14).
