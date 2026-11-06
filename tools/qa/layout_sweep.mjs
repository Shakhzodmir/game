// Layout sweep in the real engine: every town window and the level screen (with its pause window), in 4 window
// shapes x the languages, checked through the debug QA command `gui_bounds` (the rectangle of every text and of
// the box it sits on, in window pixels) and photographed into one contact sheet per language.
//
//   node tools/qa/layout_sweep.mjs http://localhost:8765/index.html [outDir=docs/media/layout] [--langs en,ru]
//
// Needs a DEBUG HTML5 build (the QA bridge is not in the release) and playwright (PLAYWRIGHT=<path> if it is not
// installed globally). Exit code 1 when any text sticks out of its box or the window, or is under 15 CSS px
// (the same rules as tests/client/layout_audit.lua, which runs without a browser inside ./tools/test.sh).
// Run one browser at a time: it is heavy on the CPU (software GL).

const pwPath = process.env.PLAYWRIGHT || 'playwright';
const { chromium } = await import(pwPath);

const url = process.argv[2] || 'http://localhost:8765/index.html';
const outDir = process.argv[3] && !process.argv[3].startsWith('--') ? process.argv[3] : 'docs/media/layout';
const langArg = process.argv.indexOf('--langs');
const LANGS = langArg > 0 ? process.argv[langArg + 1].split(',') : ['en', 'ru'];
const SIZES = [[720, 1280], [1280, 720], [390, 844], [360, 640]];
const TOL = 1.5;      // px of slack
const MIN_PX = 15;    // the floor of a readable text (CSS px at the design size; scaled with the window)

// [label, command lines before the shot]; the town windows go through `popup <name> [tab]`
const TOWN_WINDOWS = [
	['start', 'popup start'], ['lives', 'popup lives'], ['shop_boosters', 'popup shop boosters'], ['shop_coins', 'popup shop coins'],
	['settings', 'popup settings'], ['jukebox', 'popup jukebox'], ['concert', 'popup concert cafe'], ['gift', 'popup gift'],
	['confirm', 'popup confirm'],
];

const fs = await import('fs');
fs.mkdirSync(outDir, { recursive: true });

const problems = [];
const sleep = ms => new Promise(r => setTimeout(r, ms));
const state = page => page.evaluate(() => window.__glowState || null);

async function waitFor(page, pred, what, timeout = 20000) {
	const t0 = Date.now();
	let s = null;
	while (Date.now() - t0 < timeout) {
		s = await state(page);
		if (s && pred(s)) return s;
		await sleep(60);
	}
	throw new Error('timeout waiting for ' + what + '; last: ' + JSON.stringify(s && s.app && s.app.screen));
}

async function command(page, cmd) {
	const before = (await state(page))?.seq ?? 0;
	await page.evaluate(c => { window.__glowCmd = c; }, cmd);
	const s = await waitFor(page, st => st.seq > before, 'command ' + cmd);
	if (!s.result || !s.result.ok) throw new Error('command failed: ' + cmd + ' -> ' + JSON.stringify(s.result));
	return s;
}

// asks every scene for its text rectangles; the answer lands in app.ui.bounds a frame or two later
async function bounds(page) {
	await command(page, 'gui_bounds');
	await sleep(400);
	const s = await state(page);
	return (s.app.ui && s.app.ui.bounds) || {};
}

function judge(label, vw, vh, scenes, windowOnly) {
	let rows = 0;
	for (const rowsOfScene of Object.values(scenes)) {
		for (const r of rowsOfScene) {
			rows++;
			const x1 = r.x0 + r.w, y1 = r.y0 + r.h;
			const bad = [];
			if (r.bx0 !== undefined) {
				const d = Math.max(r.bx0 - r.x0, x1 - (r.bx0 + r.bw), r.by0 - r.y0, y1 - (r.by0 + r.bh));
				if (d > TOL) bad.push(`sticks out of its box by ${d.toFixed(1)} px`);
			}
			const d = Math.max(-r.x0, x1 - vw, -r.y0, y1 - vh);
			if (d > TOL) bad.push(`is ${d.toFixed(1)} px out of the window`);
			const scale = Math.min(vw / 720, vh / 1280);
			if (r.px / scale < MIN_PX - 0.01) bad.push(`is only ${(r.px / scale).toFixed(1)} px tall`);
			for (const b of bad) problems.push(`${label}: '${r.t.slice(0, 40)}' ${b}`);
		}
	}
	return rows;
}

const browser = await chromium.launch({
	args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'],
});

for (const lang of LANGS) {
	const shots = []; // {label, buf}
	for (const [vw, vh] of SIZES) {
		const ctx = await browser.newContext({ viewport: { width: vw, height: vh }, deviceScaleFactor: 1 });
		const page = await ctx.newPage();
		page.on('pageerror', e => problems.push(`${lang} ${vw}x${vh}: pageerror ${e.message}`));
		await page.goto(url);
		await waitFor(page, s => s.app && s.app.screen, 'the first screen', 60000);
		await command(page, 'reset_save');
		await command(page, 'lang ' + lang);
		await command(page, 'advance 14');
		await command(page, 'set_coins 1234567');
		await command(page, 'goto town');
		await waitFor(page, s => s.app.screen === 'town' && !s.app.transitioning, 'the town');
		await bounds(page); // switches the tracking on before any window is built
		for (const [name, cmd] of TOWN_WINDOWS) {
			await command(page, cmd);
			await sleep(900); // the window pops in
			const label = `${lang} ${vw}x${vh} ${name}`;
			const n = judge(label, vw, vh, await bounds(page));
			if (n === 0) problems.push(`${label}: gui_bounds answered no texts`);
			shots.push({ label, buf: await page.screenshot() });
			await command(page, 'popup close');
			await sleep(500);
		}
		// the level screen, then its pause window (the button at the bottom left, as in tools/qa/web_screens.mjs)
		await command(page, 'level 14');
		await waitFor(page, s => s.app.screen === 'level' && !s.app.transitioning, 'the level', 40000);
		await sleep(1500);
		const hud = `${lang} ${vw}x${vh} level_hud`;
		judge(hud, vw, vh, await bounds(page));
		shots.push({ label: hud, buf: await page.screenshot() });
		await ctx.close();
	}
	// one contact sheet per language, rendered by the browser itself (no image library needed)
	const cols = 6, cell = 260;
	const html = '<body style="margin:0;background:#222;color:#fff;font:12px sans-serif"><div style="display:flex;flex-wrap:wrap;width:'
		+ (cols * (cell + 8)) + 'px">' + shots.map(s => `<div style="margin:4px;width:${cell}px"><img style="width:${cell}px;height:${cell}px;object-fit:contain;background:#000" src="data:image/png;base64,${s.buf.toString('base64')}">${s.label}</div>`).join('') + '</div></body>';
	const sheet = await browser.newPage({ viewport: { width: cols * (cell + 8), height: 600 } });
	await sheet.setContent(html);
	await sheet.screenshot({ path: `${outDir}/layout_${lang}.png`, fullPage: true });
	await sheet.close();
}
await browser.close();

if (problems.length) {
	console.log('LAYOUT PROBLEMS (' + problems.length + '):\n' + problems.join('\n'));
	process.exit(1);
}
console.log('layout sweep: no problems; sheets in ' + outDir);
