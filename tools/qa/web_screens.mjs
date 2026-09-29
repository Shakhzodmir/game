// Drives a debug HTML5 build through the QA bridge (client/qa_bridge.lua) in
// headless Chromium and saves screenshots of the placeholder screens.
//
//   python3 -m http.server 8765 -d dist/GLOW &
//   node tools/qa/web_screens.mjs http://localhost:8765/index.html docs/media
//
// Env: PLAYWRIGHT = path to the playwright module (default: "playwright").
// Exits with 1 when the page logs a Lua error or a page error.

const pwPath = process.env.PLAYWRIGHT || 'playwright';
const { chromium } = await import(pwPath);

const url = process.argv[2] || 'http://localhost:8765/index.html';
const outDir = process.argv[3] || 'docs/media';

const errors = [];
const consoleLines = [];

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function state(page) {
	return page.evaluate(() => window.__glowState || null);
}

async function waitFor(page, pred, what, timeout = 20000) {
	const t0 = Date.now();
	let s = null;
	while (Date.now() - t0 < timeout) {
		s = await state(page);
		if (s && pred(s)) return s;
		await sleep(100);
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

async function onScreen(page, name) {
	await waitFor(page, s => s.app && s.app.screen === name && !s.app.transitioning, 'screen ' + name);
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

async function openPage(browser, viewport, scale) {
	const ctx = await browser.newContext({ viewport, deviceScaleFactor: scale || 1 });
	const page = await ctx.newPage();
	page.on('console', m => {
		const line = `[${viewport.width}x${viewport.height}] ${m.type()}: ${m.text()}`;
		consoleLines.push(line);
		if (/ERROR:SCRIPT|ERROR:GUI|ERROR:GAMEOBJECT|ERROR:RESOURCE|ERROR:ENGINE|lua error|stack traceback/i.test(m.text())) errors.push(line);
	});
	page.on('pageerror', e => errors.push(`[${viewport.width}x${viewport.height}] pageerror: ${e.message}`));
	await page.goto(url);
	return page;
}

const browser = await chromium.launch({
	args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'],
});

try {
	// 1. phone portrait 9:16 --------------------------------------------------------------
	const page = await openPage(browser, { width: 540, height: 960 });
	await waitFor(page, s => s.app && s.app.screen === 'splash', 'splash', 30000);
	await sleep(600);
	await page.screenshot({ path: `${outDir}/client_splash.png` });
	// fresh save: the splash goes straight to level 1 (first launch)
	await onScreen(page, 'level');
	await command(page, 'goto town');
	await onScreen(page, 'town');
	await sleep(900);
	await page.screenshot({ path: `${outDir}/client_town.png` });

	// audio engine: the district track runs, notes and sfx get played
	const au = (await state(page)).app.audio;
	if (!au || !au.playing || au.district !== 'cafe') errors.push('audio: town music is not playing: ' + JSON.stringify(au));
	await command(page, 'note red 3');
	await command(page, 'sfx tap');
	await sleep(400);
	const au2 = (await state(page)).app.audio;
	console.log('audio status: ' + JSON.stringify(au2));
	if (!(au2.notes >= 1 && au2.sfx >= 1)) errors.push('audio: note/sfx not played: ' + JSON.stringify(au2));
	// jukebox mode: every stem unmuted -> the music group must carry signal
	await command(page, 'music cafe all');
	await sleep(1500);
	const au3 = (await state(page)).app.audio;
	console.log('audio (all stems): ' + JSON.stringify(au3));
	if (!(au3.stems_on >= 3)) errors.push('audio: jukebox stems not unmuted: ' + JSON.stringify(au3));
	if (!(au3.music_rms > 0)) console.log('note: music RMS is 0 (no audio output in this browser?)');
	await command(page, 'music cafe');

	// real input: tap the "Level N" button (logical 360, 245)
	await tap(page, 360, 245);
	await onScreen(page, 'level');
	await sleep(900);
	await page.screenshot({ path: `${outDir}/client_level.png` });

	// the back button (logical 80, 1160) returns to the town
	await tap(page, 80, 1160);
	await onScreen(page, 'town');

	// language switch + a modal
	await command(page, 'lang ru');
	await sleep(600);
	await tap(page, 660, 1210);
	await sleep(700);
	await page.screenshot({ path: `${outDir}/client_town_ru_settings.png` });

	// saves survive a reload (sys.save -> IndexedDB): both slots, current wins
	await command(page, 'set_coins 1234');
	await sleep(1500);
	await page.reload();
	const reloaded = await waitFor(page, s => s.app && s.app.coins !== undefined, 'boot after reload', 30000);
	console.log('after reload: save_source=' + reloaded.app.save_source + ' coins=' + reloaded.app.coins + ' language=' + reloaded.app.language);
	if (reloaded.app.coins !== 1234 || reloaded.app.save_source !== 'current') {
		errors.push('save: expected 1234 coins from the current slot after reload, got ' + JSON.stringify(reloaded.app));
	}
	if (reloaded.app.language !== 'ru') errors.push('save: language setting lost after reload');
	await page.context().close();

	// 2. landscape window: the design area is fitted, the sky fills the sides ---------------
	const wide = await openPage(browser, { width: 1280, height: 720 });
	await waitFor(wide, s => s.app && s.app.screen && !s.app.transitioning, 'boot (wide)', 30000);
	await command(wide, 'goto town');
	await onScreen(wide, 'town');
	await sleep(900);
	await wide.screenshot({ path: `${outDir}/client_town_wide.png` });
	await wide.context().close();

	// 3. tall phone with a 3x pixel ratio (high_dpi) --------------------------------------------
	const tall = await openPage(browser, { width: 390, height: 844 }, 3);
	await waitFor(tall, s => s.app && s.app.screen && !s.app.transitioning, 'boot (tall)', 30000);
	await command(tall, 'goto town');
	await onScreen(tall, 'town');
	await sleep(900);
	await tall.screenshot({ path: `${outDir}/client_town_tall.png` });
	await tap(tall, 360, 245);
	await onScreen(tall, 'level');
	await sleep(900);
	await tall.screenshot({ path: `${outDir}/client_level_tall.png` });
	const final = await state(tall);
	if (final.errors && final.errors.length) errors.push(...final.errors.map(e => 'bridge: ' + e));
	await tall.context().close();
} catch (e) {
	errors.push('qa: ' + e.message);
} finally {
	await browser.close();
}

for (const l of consoleLines) console.log(l);
if (errors.length) {
	console.log('\nERRORS:');
	for (const e of errors) console.log('  ' + e);
	process.exit(1);
}
console.log('\nOK: screenshots in ' + outDir);
