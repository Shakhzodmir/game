// Drives a debug HTML5 build through the QA bridge (client/qa_bridge.lua) in
// headless Chromium, checks the client foundation and saves screenshots.
//
//   python3 -m http.server 8765 -d dist/GLOW &
//   node tools/qa/web_screens.mjs http://localhost:8765/index.html docs/media
//   node tools/qa/web_screens.mjs http://localhost:8765/index.html /tmp --release   # a release build
//
// Env: PLAYWRIGHT = path to the playwright module (default: "playwright").
// Exits with 1 when a check fails or the page logs a Lua error or a page error.
//
// Checks (debug): screens and real taps at 1x / 3x (DPR capped at 2), the first
// launch straight into level 1, the "Level N" button -> start window -> Play ->
// the attempt (client/flow.lua), toasts slide into view, a modal closes when
// its screen goes away, a stray fade cannot hang a transition, the notes
// contract (dedupe, 3 voices), tonal effects follow the district key, jukebox =
// task stems + party, the music resyncs after a stall, a failed save is
// retried and reported, saves and language survive a reload, window resizes
// re-layout without errors, the board plays on the real engine (autoplay,
// hold, the win with its final concert and results window, "Next level" ->
// start window -> Play, a lost level with the moves and defeat windows), and no
// engine or game warning about something lost ("could not be found", "WARNING:
// tutorials|level") appears in the console.
// Every command the script sends exists in the bridge and every field it reads
// is published by the game: tests/client/qa_script_test.lua keeps them in step.
// Release: the QA bridge is absent.

const pwPath = process.env.PLAYWRIGHT || 'playwright';
const { chromium } = await import(pwPath);

const url = process.argv[2] || 'http://localhost:8765/index.html';
const outDir = process.argv[3] || 'docs/media';
const releaseMode = process.argv.includes('--release');

const errors = [];
const consoleLines = [];
const report = [];

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
function check(cond, what, detail) {
	report.push((cond ? 'ok   ' : 'FAIL ') + what + (detail !== undefined ? ' ' + JSON.stringify(detail) : ''));
	if (!cond) errors.push('check failed: ' + what + (detail !== undefined ? ' ' + JSON.stringify(detail) : ''));
}

async function state(page) {
	return page.evaluate(() => window.__glowState || null);
}

async function waitFor(page, pred, what, timeout = 20000) {
	const t0 = Date.now();
	let s = null;
	while (Date.now() - t0 < timeout) {
		s = await state(page);
		if (s && pred(s)) return s;
		await sleep(50);
	}
	throw new Error('timeout waiting for ' + what + '; last state: ' + JSON.stringify(s && s.app));
}

async function command(page, cmd) {
	const before = (await state(page))?.seq ?? 0;
	await page.evaluate(c => { window.__glowCmd = c; }, cmd);
	const s = await waitFor(page, st => st.seq > before, 'command ' + cmd);
	if (!s.result || !s.result.ok) throw new Error('command failed: ' + cmd + ' -> ' + JSON.stringify(s.result));
	return s;
}

async function onScreen(page, name, timeout) {
	return waitFor(page, s => s.app && s.app.screen === name && !s.app.transitioning, 'screen ' + name, timeout);
}

// logical (720x1280, y up) -> page CSS pixels, same fit as client/layout.lua
async function logicalToPage(page, lx, ly) {
	const vp = page.viewportSize();
	const s = Math.min(vp.width / 720, vp.height / 1280);
	const ox = (vp.width - 720 * s) / 2, oy = (vp.height - 1280 * s) / 2;
	return { x: ox + lx * s, y: vp.height - (oy + ly * s) };
}

// a real tap: press, hold for several frames (software GL can be slow), release
async function tap(page, lx, ly) {
	const p = await logicalToPage(page, lx, ly);
	await page.mouse.move(p.x, p.y);
	await sleep(100);
	await page.mouse.down();
	await sleep(250);
	await page.mouse.up();
}

// Where the game says a button is (logical coordinates): the town's (app.ui.targets), the top window's
// (app.ui.popup_targets, where = 'popup') and the level screen's (app.ui.level.targets, where = 'level').
async function targetOf(page, name, where) {
	const s = await state(page);
	const ui = (s && s.app && s.app.ui) || {};
	const table = where === 'popup' ? ui.popup_targets : where === 'level' ? ui.level && ui.level.targets : ui.targets;
	const t = table && table[name];
	if (!t) throw new Error(`no ${where || 'screen'} tap target "${name}" (screen ${ui.screen}, window ${ui.popup})`);
	return t;
}

async function tapTarget(page, name, where) {
	const t = await targetOf(page, name, where);
	await tap(page, t.x, t.y);
}

// The town's "Level N" button opens the start window, Play there opens the attempt in the meta and the level
// screen (client/flow.lua): two real taps. Returns the state with the level on display.
async function startLevelFromTown(page) {
	await tapTarget(page, 'level');
	await waitFor(page, s => s.app.ui && s.app.ui.popup === 'start', 'the start window', 8000);
	await sleep(700); // the window pops in
	await tapTarget(page, 'play', 'popup');
	return onScreen(page, 'level', 20000);
}

async function openPage(browser, viewport, scale) {
	const ctx = await browser.newContext({ viewport, deviceScaleFactor: scale || 1 });
	const page = await ctx.newPage();
	page.on('console', m => {
		const line = `[${viewport.width}x${viewport.height}] ${m.type()}: ${m.text()}`;
		consoleLines.push(line);
		// "could not be found": the engine dropped something the scripts asked for (a particlefx constant set before
		// the play, ...); "WARNING: tutorials|level": the game's own warnings (client/tutorial.lua, the level scripts)
		if (/ERROR:SCRIPT|ERROR:GUI|ERROR:GAMEOBJECT|ERROR:RESOURCE|ERROR:ENGINE|lua error|stack traceback|could not be found|WARNING: (tutorials|level)/i.test(m.text())) errors.push(line);
	});
	page.on('pageerror', e => errors.push(`[${viewport.width}x${viewport.height}] pageerror: ${e.message}`));
	await page.goto(url);
	return page;
}

// CPU time the page spends per second (Chrome DevTools metrics)
async function cpuPerSecond(page, cdp, seconds) {
	const get = async () => {
		const m = (await cdp.send('Performance.getMetrics')).metrics;
		const v = n => (m.find(x => x.name === n) || {}).value || 0;
		return { task: v('TaskDuration'), script: v('ScriptDuration'), t: v('Timestamp') };
	};
	const a = await get();
	await sleep(seconds * 1000);
	const b = await get();
	const dt = b.t - a.t;
	return { task_ms_per_s: Math.round((b.task - a.task) / dt * 1000), script_ms_per_s: Math.round((b.script - a.script) / dt * 1000) };
}

const browser = await chromium.launch({
	args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'],
});

async function releaseChecks() {
	const page = await openPage(browser, { width: 540, height: 960 });
	await sleep(9000);
	const st = await page.evaluate(() => window.__glowState);
	check(st === undefined, 'release: no QA bridge state on the page');
	await page.evaluate(() => { window.__glowCmd = 'set_coins 99999'; });
	await sleep(1000);
	const still = await page.evaluate(() => window.__glowCmd);
	check(still === 'set_coins 99999', 'release: commands are not read');
	await page.screenshot({ path: `${outDir}/release_check.png` });
	await page.context().close();
}

async function debugChecks() {
	// 1. phone portrait 9:16 --------------------------------------------------------------
	const page = await openPage(browser, { width: 540, height: 960 });
	await waitFor(page, s => s.app && s.app.screen === 'splash', 'splash', 30000);
	await sleep(600);
	await page.screenshot({ path: `${outDir}/client_splash.png` });
	// fresh save: the splash goes straight to level 1 (first launch), with its attempt open in the meta
	const first = await onScreen(page, 'level');
	check(first.app.params && first.app.params.level_id === 1 && first.app.params.from === 'splash' && first.app.run === true,
		'first launch: level 1 straight from the splash, the attempt is open', first.app.params && { level: first.app.params.level_id, from: first.app.params.from, run: first.app.run });
	await command(page, 'goto town');
	await onScreen(page, 'town');
	await sleep(900);
	await page.screenshot({ path: `${outDir}/client_town.png` });

	// audio engine: the district track runs, notes and sfx get played
	const au = (await state(page)).app.audio;
	check(au && au.playing && au.district === 'cafe', 'audio: town music plays', au && au.district);
	check(au.stems_on === 0 && au.stems >= 3, 'audio: a new player hears no stem yet (all locked, design question)', { on: au.stems_on, stems: au.stems });
	await command(page, 'note red 3');
	await command(page, 'sfx tap');
	await sleep(400);
	let a2 = (await state(page)).app.audio;
	check(a2.notes >= 1 && a2.sfx >= 1, 'audio: a note and an effect were played', { notes: a2.notes, sfx: a2.sfx });
	check(Math.abs(a2.last_sfx_speed - Math.pow(2, 5 / 12)) < 1e-6, 'audio: tonal effect "tap" transposed to F (cafe)', a2.last_sfx_speed);
	await command(page, 'sfx swap');
	await sleep(300);
	a2 = (await state(page)).app.audio;
	check(a2.last_sfx_speed === 1, 'audio: atonal effect "swap" untransposed', a2.last_sfx_speed);
	// notes contract: five notes of one wave, one of them twice -> one group, 3 voices
	const before = (await state(page)).app.audio;
	await command(page, 'chord 1 red orange red yellow green');
	await sleep(600);
	const a3 = (await state(page)).app.audio;
	check(a3.note_groups === before.note_groups + 1, 'audio: the notes of one tick form one group', a3.note_groups - before.note_groups);
	check(a3.last_group_voices === 3, 'audio: at most 3 voices', a3.last_group_voices);
	check(a3.deduped - before.deduped === 1 && a3.capped - before.capped === 1, 'audio: same file once, lowest steps kept',
		{ deduped: a3.deduped - before.deduped, capped: a3.capped - before.capped });
	// jukebox mode: every task stem + party, never tension
	await command(page, 'music cafe all');
	await sleep(1500);
	const a4 = (await state(page)).app.audio;
	console.log('audio (jukebox): ' + JSON.stringify(a4));
	check(a4.layers.party === true && a4.layers.tension === false && a4.stems_on === a4.stems - 1, 'audio: jukebox = task stems + party', a4.layers);
	if (!(a4.music_rms > 0)) console.log('note: music RMS is 0 (no audio output in this browser?)');
	// the music clock: a 600 ms hitch -> the stems restart at the clock position
	const r0 = a4.resyncs;
	await command(page, 'stall 600');
	await sleep(800);
	const a5 = (await state(page)).app.audio;
	check(a5.resyncs === r0 + 1 && a5.stalls >= 1 && a5.playing && a5.stems_on === a4.stems_on,
		'audio: the stems resync after a stall', { resyncs: a5.resyncs - r0, stalls: a5.stalls, pos: a5.last_resync_pos });
	await command(page, 'music cafe');

	// the saved volumes reach the mixer (whatever the script init order), and a
	// save reset applies the defaults again
	await command(page, 'volume 0.3');
	await sleep(300);
	check(Math.abs((await state(page)).app.audio.music_gain - 0.3) < 1e-6, 'audio: music volume setting applied', (await state(page)).app.audio.music_gain);

	// a repeated request for the screen being loaded does not load it twice
	const l0 = (await command(page, 'state')).result.loads;
	await command(page, 'goto level');
	await command(page, 'goto level');
	await onScreen(page, 'level');
	await sleep(700);
	const l1 = (await command(page, 'state')).result.loads;
	check(l1 === l0 + 1, 'screens: a duplicate request loads the screen once', l1 - l0);
	await command(page, 'goto town');
	await onScreen(page, 'town');
	await command(page, 'reset_save');
	await sleep(300);
	check(Math.abs((await state(page)).app.audio.music_gain - 0.8) < 1e-6, 'audio: a save reset applies the default volume again',
		(await state(page)).app.audio.music_gain);

	// a task: a (meta) win gives a star, the task card restores the item in
	// full colour with a gold glow and unlocks its stem
	await command(page, 'meta_win 5');
	await sleep(400);
	await tapTarget(page, 'task');
	await waitFor(page, s => s.app.next_task && s.app.next_task.id !== 'turntable', 'task done', 3000);
	// the stem joins the track when the stars have landed and the item lights up (stars fly first: a slow
	// software-GL page needs seconds), then crossfades in over 0.5 s
	const lit = await waitFor(page, s => s.app.audio && s.app.audio.stems_on >= 1, 'the stem of the task', 15000).catch(() => null);
	const at = (lit || await state(page)).app.audio;
	check(at.stems_on === 1, 'town: the task unlocked its stem', at.stems_on);
	await page.screenshot({ path: `${outDir}/client_town_task.png` });
	await waitFor(page, s => !s.app.overlay.toast && s.app.overlay.toasts_queued === 0, 'toasts done', 8000);
	// the day / concert toggle on the ribbon: the scene swaps its background
	await tapTarget(page, 'view');
	await sleep(900);
	await page.screenshot({ path: `${outDir}/client_town_concert.png` });
	await tapTarget(page, 'view');
	await sleep(600);

	// toasts slide fully into view below the top bar, then leave
	await command(page, 'toast_key toast.coming_soon');
	const tIn = await waitFor(page, s => s.app.overlay && s.app.overlay.toast_phase === 'hold', 'toast in view', 3000);
	check(Math.abs(tIn.app.overlay.toast_offset) < 1, 'toast: slides fully into view', tIn.app.overlay.toast_offset);
	await sleep(300);
	await page.screenshot({ path: `${outDir}/client_toast.png` });
	await waitFor(page, s => !s.app.overlay.toast, 'toast gone', 5000);

	// a modal goes away with its screen; the answer comes through the bus
	await command(page, 'modal qa');
	await waitFor(page, s => s.app.overlay.modal === 'qa', 'modal open', 3000);
	await command(page, 'goto level');
	const lv = await onScreen(page, 'level');
	check(!lv.app.overlay.modal, 'modal: closed when its screen went away');
	check(lv.app.overlay.last_modal_result && lv.app.overlay.last_modal_result.button === 'screen_changed',
		'modal: answer "screen_changed" on the bus', lv.app.overlay.last_modal_result);

	// a fade asked by another script during a transition cannot hang it
	await command(page, 'goto town');
	await command(page, 'stray_fade in');
	await command(page, 'stray_fade out');
	await onScreen(page, 'town', 8000);
	await waitFor(page, s => s.app.overlay.fade_alpha >= 0.99, 'stray fade-out ran after the transition', 3000);
	await command(page, 'stray_fade in');
	await waitFor(page, s => s.app.overlay.fade_alpha === 0 && !s.app.overlay.fading, 'overlay clear again', 3000);
	check(true, 'fade: a stray fade during a transition waits and cannot hang it');

	// the "Level N" button keeps pulsing after a press released outside it
	const levelBtn = await targetOf(page, 'level');
	const edge = await logicalToPage(page, levelBtn.x, levelBtn.y + 82); // the top edge of the button
	const clip = { x: edge.x - 210, y: edge.y - 30, width: 420, height: 80 };
	const changed = async () => {
		const a = await page.screenshot({ clip });
		await sleep(430);
		const b = await page.screenshot({ clip });
		let d = 0;
		for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) d++;
		return d;
	};
	const btn = await logicalToPage(page, levelBtn.x, levelBtn.y);
	await page.mouse.move(btn.x, btn.y);
	await page.mouse.down();
	await sleep(250);
	await page.mouse.move(btn.x, btn.y - 400);
	await sleep(100);
	await page.mouse.up();
	await sleep(600);
	const moved = await changed();
	check(moved > 1000 && (await state(page)).app.screen === 'town', 'ui: a pressed button pulses again', moved);

	// real input: the "Level N" button opens the start window, Play there opens the attempt and the level screen
	const att = await startLevelFromTown(page);
	check(att.app.params && att.app.params.from === 'town' && att.app.params.run && att.app.run === true,
		'start window: Play opens the attempt in the meta and the level screen', att.app.params && { from: att.app.params.from, level: att.app.params.level_id });
	await sleep(900);
	await page.screenshot({ path: `${outDir}/client_level.png` });
	// the window changes size: the board and the HUD are laid out again
	await page.setViewportSize({ width: 700, height: 900 });
	await sleep(700);
	await page.setViewportSize({ width: 540, height: 960 });
	await sleep(700);
	// language change on the level screen
	await command(page, 'lang ru');
	await sleep(500);
	await page.screenshot({ path: `${outDir}/client_level_ru.png` });
	await command(page, 'lang en');

	// the pause button opens the pause window; "Quit level" returns to the town (before the first move nothing is
	// lost, so there is no question to answer, and the attempt is dropped)
	await tapTarget(page, 'pause', 'level');
	const paused = await waitFor(page, s => s.app.ui.popup === 'pause', 'the pause window', 5000);
	await sleep(700);
	const leave = paused.app.ui.popup_targets.leave;
	await tap(page, leave.x, leave.y);
	const home = await onScreen(page, 'town');
	check(home.app.run !== true, 'pause: leaving before the first move drops the attempt', home.app.run);

	// a real attempt through to the end on the engine: win with the final concert, the results, "Next level" ->
	// start window -> Play (three taps from the win), then out through the pause window
	await startLevelFromTown(page);
	const attemptLevel = (await state(page)).app.params.level_id;
	await sleep(1300);
	await command(page, 'win');
	await waitFor(page, s => s.app.ui.level && ['concert', 'complete'].includes(s.app.ui.level.state), 'the final concert of the attempt', 150000);
	await command(page, 'skip');
	const won = await waitFor(page, s => s.app.ui.popup === 'result', 'the results of the attempt', 60000);
	check(won.app.level === attemptLevel + 1, 'results: the meta moved on to the next level', { played: attemptLevel, next: won.app.level });
	await sleep(1500);
	await page.screenshot({ path: `${outDir}/client_attempt_result.png` });
	await tapTarget(page, 'next', 'popup');
	await waitFor(page, s => s.app.ui.popup === 'start', 'the start window of the next level', 10000);
	await sleep(700);
	await tapTarget(page, 'play', 'popup');
	const next = await waitFor(page, s => s.app.screen === 'level' && !s.app.transitioning && s.app.params && s.app.params.level_id === attemptLevel + 1,
		'the next level', 30000);
	check(next.app.params.from === 'level' && next.app.run === true, 'results: Next level -> Play opens the next attempt', { from: next.app.params.from });
	await sleep(900);
	await tapTarget(page, 'pause', 'level');
	const paused2 = await waitFor(page, s => s.app.ui.popup === 'pause', 'the pause window (next level)', 5000);
	await sleep(700);
	await tap(page, paused2.app.ui.popup_targets.leave.x, paused2.app.ui.popup_targets.leave.y);
	await onScreen(page, 'town');

	// the board on the real engine (client/level_qa.lua commands): moves by themselves, the finale, the results.
	// A standalone debug level (no attempt in the meta): nothing is booked, no life is lost. The Lua stub of the
	// test suite cannot say what the engine does with particles, z-order or input, so this is where it shows.
	const lvl = s => (s.app && s.app.ui && s.app.ui.level) || null;
	await command(page, 'goto level 14');
	await onScreen(page, 'level');
	await waitFor(page, s => lvl(s) && lvl(s).state === 'playing' && lvl(s).moves > 0, 'level 14 on display', 20000);
	await sleep(1300); // the pieces bloom in
	const moves0 = lvl(await state(page)).moves;
	await command(page, 'autoplay 3');
	const played = await waitFor(page, s => lvl(s) && lvl(s).moves <= moves0 - 3, 'three moves by autoplay', 40000);
	check(lvl(played).moves <= moves0 - 3, 'board: autoplay plays moves by itself', { before: moves0, after: lvl(played).moves });
	await sleep(500);
	await page.screenshot({ path: `${outDir}/client_board_cascade.png` });
	// the app loses the focus: the game stands still, and goes on when it is back
	await command(page, 'hold 1');
	const held0 = (await command(page, 'state')).result.level.tick;
	await sleep(900);
	const held1 = (await command(page, 'state')).result.level.tick;
	check(held1 === held0, 'board: no ticks while the app is away', { before: held0, after: held1 });
	await command(page, 'hold 0');
	await sleep(500);
	check((await command(page, 'state')).result.level.tick > held1, 'board: the game goes on when the app is back');
	// the win, the final concert (title, confetti), the skip, the results
	await command(page, 'win');
	await waitFor(page, s => lvl(s) && ['won_wait', 'concert', 'complete'].includes(lvl(s).state), 'the win of level 14', 150000);
	await waitFor(page, s => lvl(s) && ['concert', 'complete'].includes(lvl(s).state), 'the final concert', 30000);
	await sleep(1500);
	await page.screenshot({ path: `${outDir}/client_board_concert.png` });
	check(lvl(await state(page)).state === 'concert', 'board: the final concert plays', lvl(await state(page)).state);
	await command(page, 'skip');
	await waitFor(page, s => s.app.ui.popup === 'result', 'the results window', 60000);
	await sleep(1200);
	await page.screenshot({ path: `${outDir}/client_board_result.png` });
	check(true, 'board: win, final concert, skip and the results window run on the engine');
	// the other end: a super hard level that the hint moves do not finish in time ends in the moves window and the defeat
	await command(page, 'goto level 60');
	await onScreen(page, 'level');
	await waitFor(page, s => lvl(s) && lvl(s).state === 'playing' && lvl(s).moves > 0, 'level 60 on display', 20000);
	await sleep(1300);
	await command(page, 'autoplay 100');
	const end60 = await waitFor(page, s => lvl(s) && ['out_of_moves', 'won_wait', 'concert', 'complete'].includes(lvl(s).state),
		'the end of level 60', 240000);
	if (lvl(end60).state === 'out_of_moves') {
		await waitFor(page, s => s.app.ui.popup === 'moves', 'the moves window', 10000);
		await sleep(900);
		await page.screenshot({ path: `${outDir}/client_board_moves.png` });
		await command(page, 'give_up');
		await waitFor(page, s => s.app.ui.popup === 'defeat', 'the defeat window', 20000);
		await sleep(900);
		await page.screenshot({ path: `${outDir}/client_board_defeat.png` });
		check(true, 'board: out of moves opens the moves window, giving up the defeat window');
	} else {
		console.log('note: the hint moves won level 60, the moves/defeat windows were not drawn this time');
	}
	await command(page, 'goto town');
	await onScreen(page, 'town');

	// language switch + a modal
	await command(page, 'lang ru');
	await sleep(600);
	await tapTarget(page, 'settings');
	await sleep(700);
	await page.screenshot({ path: `${outDir}/client_town_ru_settings.png` });
	check((await state(page)).app.ui.popup === 'settings', 'settings: the gear opens the settings window', (await state(page)).app.ui.popup);
	await command(page, 'close');
	await waitFor(page, s => !s.app.ui.popup, 'settings closed', 5000);

	// every window of the town through the bridge (client/meta_qa.lua "open"): it opens, is drawn and closes
	await command(page, 'lang en');
	for (const [popup, params, shot] of [
		['start', '', 'client_start'], ['lives', '', 'client_lives'], ['shop', '{"tab":"boosters"}', 'client_shop'],
		['shop', '{"tab":"coins"}', 'client_shop_coins'], ['jukebox', '', 'client_jukebox'], ['gift', '{"id":"riff"}', 'client_gift'],
		['chest', '', 'client_chest'], ['concert', '', 'client_concert'],
		['confirm', '{"title":{"key":"settings.reset_title"},"text":{"key":"settings.reset_text"},"confirm":{"text":{"key":"settings.reset_do"},"style":"pink"}}', 'client_confirm'],
	]) {
		await command(page, 'open ' + popup + (params ? ' ' + params : ''));
		await waitFor(page, st => st.app.ui && st.app.ui.popup === popup, 'window ' + popup, 8000);
		await sleep(popup === 'concert' ? 1500 : 800);
		await page.screenshot({ path: `${outDir}/${shot}.png` });
		await command(page, 'close');
		await waitFor(page, st => !st.app.ui.popup, 'window ' + popup + ' closed', 8000);
		check(true, 'window ' + popup + ' opens, draws and closes');
	}
	await command(page, 'lang ru'); // the reload check below expects the saved language

	// a failed save is retried and reported
	await command(page, 'save_fail 1');
	await command(page, 'set_coins 1234');
	const f1 = await waitFor(page, s => s.app.save_failing >= 1, 'save failure seen', 3000);
	const f1t = await waitFor(page, s => s.app.overlay.toast && /сохран|save/i.test(s.app.overlay.toast), 'save failure toast', 3000);
	check(true, 'save: failure reported to the player', f1t.app.overlay.toast);
	await sleep(1300);
	const f2 = await state(page);
	check(f2.app.save_failing > f1.app.save_failing, 'save: retried every second while failing', f2.app.save_failing);
	await command(page, 'save_fail 0');
	await waitFor(page, s => s.app.save_failing === 0, 'save retried after the disk recovered', 3000);
	check(true, 'save: the retry succeeds once writes work again');

	// performance: CPU of the page with 11 garage stems decoding vs no music
	const cdp = await page.context().newCDPSession(page);
	await cdp.send('Performance.enable');
	await command(page, 'music garage all');
	await sleep(1000);
	const withMusic = await cpuPerSecond(page, cdp, 4);
	await command(page, 'music_stop');
	await sleep(1000);
	const noMusic = await cpuPerSecond(page, cdp, 4);
	console.log('perf (headless Chromium, SwiftShader GL): 11 stems ' + JSON.stringify(withMusic) + ', no music ' + JSON.stringify(noMusic));
	await command(page, 'music cafe');

	// saves survive a reload (sys.save -> IndexedDB): both slots, current wins
	await sleep(1500);
	await page.reload();
	const reloaded = await waitFor(page, s => s.app && s.app.coins !== undefined, 'boot after reload', 30000);
	console.log('after reload: save_source=' + reloaded.app.save_source + ' coins=' + reloaded.app.coins + ' language=' + reloaded.app.language);
	check(reloaded.app.coins === 1234 && reloaded.app.save_source === 'current', 'save: coins from the current slot after reload',
		{ coins: reloaded.app.coins, source: reloaded.app.save_source });
	check(reloaded.app.language === 'ru', 'save: language survives a reload', reloaded.app.language);
	await page.context().close();

	// 2. landscape and tablet windows: the scene continues past the design area ------------
	for (const [vp, name] of [[{ width: 1280, height: 720 }, 'client_town_wide'], [{ width: 768, height: 1024 }, 'client_town_tablet']]) {
		const p = await openPage(browser, vp);
		await waitFor(p, s => s.app && s.app.screen && !s.app.transitioning, 'boot ' + name, 30000);
		await command(p, 'goto town');
		await onScreen(p, 'town');
		await sleep(900);
		await p.screenshot({ path: `${outDir}/${name}.png` });
		await p.context().close();
	}

	// 3. tall phone with a 3x pixel ratio: backbuffer capped at 2x, taps still land ----------
	const tall = await openPage(browser, { width: 390, height: 844 }, 3);
	await waitFor(tall, s => s.app && s.app.screen && !s.app.transitioning, 'boot (tall)', 30000);
	const canvas = await tall.evaluate(() => ({ w: document.getElementById('canvas').width, dpr: window.__glowDpr }));
	check(canvas.dpr === 2 && canvas.w === 780, 'web: device pixel ratio capped at 2 (780 px wide canvas at 3x)', canvas);
	await command(tall, 'goto town');
	await onScreen(tall, 'town');
	await sleep(900);
	await tall.screenshot({ path: `${outDir}/client_town_tall.png` });
	await startLevelFromTown(tall);
	await sleep(900);
	await tall.screenshot({ path: `${outDir}/client_level_tall.png` });
	const final = await state(tall);
	if (final.errors && final.errors.length) errors.push(...final.errors.map(e => 'bridge: ' + e));
	await tall.context().close();
}

try {
	if (releaseMode) await releaseChecks(); else await debugChecks();
} catch (e) {
	errors.push('qa: ' + e.message);
} finally {
	await browser.close();
}

for (const l of consoleLines) if (!/INFO:|^\[[^\]]*\] log: $/.test(l)) console.log(l);
console.log('\n' + report.join('\n'));
if (errors.length) {
	console.log('\nERRORS:');
	for (const e of errors) console.log('  ' + e);
	process.exit(1);
}
console.log('\nOK: screenshots in ' + outDir);
