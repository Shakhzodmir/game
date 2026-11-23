// Checks the ways Google's sign-in can go in web/glow_auth.js (the "flow": firebase, shim, oidc_popup, oidc_redirect, no_window)
// in the fake browser of tools/qa/fake_world.mjs: no real browser, no network. The page script runs together with the real
// web/glow_oidc.js and, for our own sign-in, the real web/auth_return.html script and a fake Google; Firebase is a fake SDK
// that applies the backend's nonce rule to the real tokens. Part 1 is how a way is chosen (every level of the precedence, what
// a desktop or an Android phone can never be moved to, the capability gate); part 2 the SDK's own window with and without its
// "closed" signal and the Home Screen app without a window; part 3 our own sign-in in a window; part 4 by the whole page.
//   node tools/qa/auth_flows_check.mjs
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { read, CORE, sleep, json, CLIENT, ORIGIN, RETURN_URL, IPHONE, b64u, sha256hex,
	makeWorld, makeWindow, installGoogle, loadReturn } from "./fake_world.mjs";
import vm from "node:vm";

const AUTH = read("web/glow_auth.js");
const VERSION = AUTH.match(/var VERSION = "([^"]+)"/)[1];
const err = (code) => Object.assign(new Error(code), { code });
const DESKTOP = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
const MAC_SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15";
const ANDROID = "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36";
const IPHONE_CHROME = IPHONE.replace("Version/27.2.1", "CriOS/130.0.6723.37");
const IPHONE_HOME = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/24B156"; // a Home Screen app has no Safari/ token
const TELEGRAM = IPHONE_HOME + " Telegram";
const WEEK = 7 * 24 * 3600 * 1000;

// ------------------------------------------------------------------------------------------------------------------------
// a game page: glow_oidc.js (unless noOidc) and glow_auth.js in a fake window, with a fake Firebase SDK
// ------------------------------------------------------------------------------------------------------------------------
function claimsOf(token) { return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8")); }

// rule.A: "nonce" = the backend's check sha256(rawNonce) == the nonce claim; rule.B: "ok" | "nonce" (B sends no nonce);
// rule.T: "ok" | code. calls: everything the page asked of the SDK, in order.
function fakeSdk(o = {}) {
	const calls = [];
	const rule = { A: "nonce", B: "ok", T: "ok", ...(o.rule || {}) };
	const mkUser = (uid, google = true, extra = {}) => ({ uid, email: uid + "@gmail.com", emailVerified: true, displayName: uid, providerData: google ? [{ providerId: "google.com", email: uid + "@gmail.com" }] : [{ providerId: "password" }], metadata: {}, ...extra });
	const auth = { currentUser: o.current === undefined ? null : o.current, languageCode: null };
	const sdk = { calls, auth, db: {}, rule, mkUser, m: {} };
	function check(cred, who) {
		calls.push([who, cred.kind]);
		if (o.fail && o.fail[cred.kind]) throw err(o.fail[cred.kind]);
		if (cred.kind === "A") { if (rule.A === "nonce" && sha256hex(cred.rawNonce) !== claimsOf(cred.idToken).nonce) throw err("auth/missing-or-invalid-nonce"); }
		else if (cred.kind === "B") { if (rule.B !== "ok") throw err(rule.B); }
		else if (rule.T !== "ok") throw err(rule.T);
		return claimsOf(cred.idToken || "x.e30.y");
	}
	const GoogleAuthProvider = function () { this.id = "google.com"; };
	GoogleAuthProvider.credential = (idToken, accessToken) => (idToken ? { kind: "B", idToken } : { kind: "T", accessToken });
	const OAuthProvider = function (id) { this.id = id; };
	OAuthProvider.prototype.credential = function (x) { return { kind: "A", providerId: this.id, idToken: x.idToken, rawNonce: x.rawNonce }; };
	Object.assign(sdk.m, {
		onAuthStateChanged: (a, cb) => { setTimeout(() => cb(auth.currentUser), 0); return () => {}; },
		GoogleAuthProvider, OAuthProvider,
		signInWithPopup: (...args) => { calls.push(["signInWithPopup", args[0] === auth, args[1] instanceof GoogleAuthProvider, args.length]); return o.popup ? o.popup("in", mkUser, auth) : Promise.reject(err("auth/internal-error")); },
		linkWithPopup: (...args) => { calls.push(["linkWithPopup", args[0] === auth.currentUser, args[1] instanceof GoogleAuthProvider, args.length]); return o.popup ? o.popup("link", mkUser, auth, args[0]) : Promise.reject(err("auth/internal-error")); },
		signInWithCredential: async (a, cred) => {
			const c = check(cred, "signInWithCredential");
			if (o.hang) await new Promise(() => {});
			await sleep(o.exchangeMs || 1);
			const made = mkUser(o.uid || ("u" + c.sub));
			auth.currentUser = made;
			if (o.swap) o.swap(auth, mkUser); // somebody else signs in at the same moment
			return { user: made };
		},
		linkWithCredential: async (u, cred) => {
			const c = check(cred, "linkWithCredential");
			if (o.hang) await new Promise(() => {});
			await sleep(o.exchangeMs || 1);
			if (o.linkTaken) throw err("auth/credential-already-in-use");
			u.providerData.push({ providerId: "google.com", email: "x@gmail.com" });
			return { user: u };
		},
		signOut: async () => { auth.currentUser = null; },
		doc: (db, c, id) => ({ path: c + "/" + id }),
		getDoc: async () => ({ exists: () => false, data: () => ({}) }),
	});
	return sdk;
}

const BASE_CFG = { apiKey: "k", authDomain: "d", projectId: "p", appId: "a", googleClientId: CLIENT, googleReturn: RETURN_URL };

// o: ua, standalone, dm, search, cfg (merged over BASE_CFG; a key set to undefined is removed), sdk, test (the page's _test hooks),
// world (shared with other windows), noOidc, noCrypto, noLocalStorage, saved (a glow_google_flow value to put in storage first)
function game(o = {}) {
	const world = o.world || makeWorld();
	const win = makeWindow(world, { href: ORIGIN + "/game/" + (o.search || ""), core: !o.noOidc, ua: o.ua || IPHONE, standalone: o.standalone, dm: o.dm, touch: o.touch, noLocalStorage: o.noLocalStorage, ss: o.ss });
	const cfg = { ...BASE_CFG, ...(o.cfg || {}) };
	for (const k of Object.keys(cfg)) if (cfg[k] === undefined) delete cfg[k];
	win.GLOW_AUTH_CONFIG = cfg;
	if (o.noCrypto) win.crypto = undefined;
	win.world = world;
	win.timers = [];
	win.ctx.setInterval = (fn, ms) => { const h = setInterval(fn, ms); win.timers.push(h); return h; }; // so that a page can be "closed" for good
	win.sdk = o.sdk || fakeSdk();
	win.glowAuth = { _test: { sdk: () => win.sdk, ...(o.test || {}) } };
	if (o.saved !== undefined) win.localStorage.setItem("glow_google_flow", typeof o.saved === "string" ? o.saved : JSON.stringify(o.saved));
	if (o.noCrypto) win.ctx.crypto = undefined;
	win.run(AUTH);
	win.lines = [];
	win.nextId = 1;
	return win;
}
const flowOf = (o) => game(o).glowAuth.flow();

// the page's answers: call() and wait for the line of that call
async function ask(win, op, args = [], ms = 4000) {
	const id = win.nextId++;
	const r = win.glowAuth.call(id, op, args);
	if (r !== "ok") return { r };
	return waitLine(win, id, ms);
}
async function waitLine(win, id, ms = 4000) {
	const end = Date.now() + ms;
	while (Date.now() < end) {
		const text = win.glowAuth.poll();
		if (text) for (const l of text.split("\n")) win.lines.push(l);
		const line = win.lines.find((l) => l.startsWith(id + "|"));
		if (line) { const [, ok, reason, rest] = line.split("|"); const f = {}; for (const kv of (rest || "").split("&")) if (kv) { const [k, v] = kv.split("="); f[k] = decodeURIComponent(v); } return { id, ok: ok === "1", reason, f, line }; }
		await sleep(5);
	}
	return null;
}
function startCall(win, op, args = []) { const id = win.nextId++; win.glowAuth.call(id, op, args); return id; }
async function waitFor(fn, ms = 4000) { const end = Date.now() + ms; while (Date.now() < end) { if (fn()) return true; await sleep(5); } return !!fn(); }
const cards = (win) => win.document.body.children.filter((c) => c.style.cssText && /position:fixed/.test(c.style.cssText) && c.children.length);
const tapCard = (win) => cards(win)[0].children[0].children[0];    // the green button
const cancelCard = (win) => cards(win)[0].children[0].children[1];
const notes = (win) => win.document.body.children.filter((c) => /^google /.test(c.textContent));
const worldKeys = (world) => [...world.ls.keys()];

// ------------------------------------------------------------------------------------------------------------------------
// 1. how the way is chosen
// ------------------------------------------------------------------------------------------------------------------------
{
	const T = (name, want, o) => assert.equal(flowOf(o), want, name);
	const ALL = { googleIos: "oidc_popup", googleIosHome: "shim" };

	// no key can move a desktop or an Android phone; nor the Mac
	T("desktop Chrome, every key set", "firebase", { ua: DESKTOP, cfg: ALL });
	T("Android Chrome, every key set", "firebase", { ua: ANDROID, cfg: ALL });
	T("a Mac (Safari, no touch screen), every key set", "firebase", { ua: MAC_SAFARI, touch: 0, cfg: ALL });
	T("desktop with the keys 'no_window'", "firebase", { ua: DESKTOP, cfg: { googleIos: "no_window", googleIosHome: "no_window" } });

	// iPhone: the key of the kind of page
	T("iPhone tab: no keys at all", "firebase", { cfg: { googleIos: undefined, googleIosHome: undefined } });
	T("iPhone tab: empty keys", "firebase", { cfg: { googleIos: "", googleIosHome: "" } });
	T("iPhone tab: an unknown key", "firebase", { cfg: { googleIos: "bogus" } });
	T("iPhone tab: a key of the wrong type", "firebase", { cfg: { googleIos: 5 } });
	for (const f of ["firebase", "shim", "oidc_popup", "oidc_redirect"]) T("iPhone tab: googleIos " + f, f, { cfg: { googleIos: f } });
	T("iPhone tab: no_window is for the Home Screen app only", "firebase", { cfg: { googleIos: "no_window" } });
	T("iPhone tab ignores googleIosHome", "firebase", { cfg: { googleIosHome: "shim" } });
	T("iPad (a Mac that has a touch screen) is an iOS page", "oidc_popup", { ua: MAC_SAFARI, touch: 5, cfg: { googleIos: "oidc_popup" } });
	T("iPhone Chrome (CriOS) takes the tab key too", "oidc_popup", { ua: IPHONE_CHROME, cfg: { googleIos: "oidc_popup" } });
	for (const f of ["firebase", "shim", "oidc_popup", "oidc_redirect", "no_window"]) T("Home Screen app: googleIosHome " + f, f, { ua: IPHONE_HOME, standalone: true, cfg: { googleIosHome: f } });
	T("Home Screen app ignores googleIos", "firebase", { ua: IPHONE_HOME, standalone: true, cfg: { googleIos: "oidc_popup" } });
	T("Home Screen app that only says so by the display-mode query", "shim", { ua: IPHONE_HOME, dm: "fullscreen", cfg: { googleIosHome: "shim" } });

	// the override in the address: this page; kept for an iPhone only
	T("?google=shim beats the key", "shim", { search: "?google=shim", cfg: { googleIos: "oidc_popup" } });
	T("?google=firebase beats the key too (a way back)", "firebase", { search: "?google=firebase", cfg: { googleIos: "oidc_popup" } });
	T("an unknown ?google= is ignored", "oidc_popup", { search: "?google=bogus", cfg: { googleIos: "oidc_popup" } });
	T("an empty ?google= is ignored", "oidc_popup", { search: "?google=&x=1", cfg: { googleIos: "oidc_popup" } });
	T("?google= among other parameters", "shim", { search: "?a=1&google=shim&b=2" });
	T("?google=no_window in a tab is gated", "firebase", { search: "?google=no_window" });
	T("?google=no_window in the Home Screen app", "no_window", { ua: IPHONE_HOME, standalone: true, search: "?google=no_window" });
	T("a desktop page can be moved for this page by the address (for testing)", "shim", { ua: DESKTOP, search: "?google=shim" });
	T("an Android page too", "oidc_popup", { ua: ANDROID, search: "?google=oidc_popup" });

	// the saved choice (the test page's "game with this way" buttons, an earlier ?google= on this phone)
	const fresh = (f, age = 1000) => ({ f, t: Date.now() - age });
	T("a saved choice beats the key", "shim", { saved: fresh("shim"), cfg: { googleIos: "oidc_popup" } });
	T("a saved choice is kept for a week", "shim", { saved: fresh("shim", WEEK - 60000) });
	T("an older one is forgotten", "firebase", { saved: fresh("shim", WEEK + 60000) });
	T("an older one is forgotten and the key applies", "oidc_popup", { saved: fresh("shim", WEEK + 60000), cfg: { googleIos: "oidc_popup" } });
	T("a saved choice from the future is forgotten", "firebase", { saved: fresh("shim", -3600 * 1000) });
	T("an unknown saved way is forgotten", "oidc_popup", { saved: fresh("bogus"), cfg: { googleIos: "oidc_popup" } });
	T("a saved value that is not JSON is forgotten", "oidc_popup", { saved: "shim", cfg: { googleIos: "oidc_popup" } });
	T("a saved value without a time is forgotten", "oidc_popup", { saved: { f: "shim" }, cfg: { googleIos: "oidc_popup" } });
	T("the address beats the saved choice", "firebase", { saved: fresh("shim"), search: "?google=firebase" });
	T("a saved choice never pins a desktop page", "firebase", { ua: DESKTOP, saved: fresh("shim") });
	T("a saved choice never pins an Android page", "firebase", { ua: ANDROID, saved: fresh("oidc_popup") });
	T("a saved oidc choice is gated like any other", "firebase", { saved: fresh("oidc_popup"), noOidc: true });
	{
		const w = game({ saved: fresh("shim", WEEK + 60000) });
		w.glowAuth.flow();
		assert.equal(w.localStorage.getItem("glow_google_flow"), null, "an old choice is deleted when it is read");
		const v = game({ saved: fresh("shim") }), before = v.localStorage.getItem("glow_google_flow");
		v.glowAuth.flow();
		assert.equal(v.localStorage.getItem("glow_google_flow"), before, "a good one is left alone");
	}
	{
		const w = game({ search: "?google=oidc_popup" });
		const kept = JSON.parse(w.localStorage.getItem("glow_google_flow"));
		assert.equal(kept.f, "oidc_popup", "on an iPhone the address choice is kept for the next loads");
		assert.ok(Math.abs(kept.t - Date.now()) < 5000);
		const next = game({ saved: kept });
		assert.equal(next.glowAuth.flow(), "oidc_popup", "...and read back");
		const d = game({ ua: DESKTOP, search: "?google=oidc_popup" });
		assert.equal(d.localStorage.getItem("glow_google_flow"), null, "on a desktop it is NOT kept: a shared link cannot pin a player");
		const a = game({ ua: ANDROID, search: "?google=shim" });
		assert.equal(a.localStorage.getItem("glow_google_flow"), null, "nor on Android");
		const bad = game({ search: "?google=bogus" });
		assert.equal(bad.localStorage.getItem("glow_google_flow"), null, "an unknown way is not kept");
	}
	{
		// ?google=auto: forget the saved choice, use the key
		const w = game({ search: "?google=auto", saved: fresh("shim"), cfg: { googleIos: "oidc_popup" } });
		assert.equal(w.localStorage.getItem("glow_google_flow"), null, "auto forgets");
		assert.equal(w.glowAuth.flow(), "oidc_popup", "and the key applies");
	}

	// the capability gate: our own sign-in needs the core, the public identifiers, a return page of this origin, crypto.subtle, storage
	const OIDC = { cfg: { googleIos: "oidc_popup" } };
	T("oidc: all there", "oidc_popup", OIDC);
	T("oidc: the core script is missing", "firebase", { ...OIDC, noOidc: true });
	T("oidc: no client id", "firebase", { cfg: { googleIos: "oidc_popup", googleClientId: undefined } });
	T("oidc: no return address", "firebase", { cfg: { googleIos: "oidc_popup", googleReturn: undefined } });
	T("oidc: a return address of another origin", "firebase", { cfg: { googleIos: "oidc_popup", googleReturn: "https://evil.example/game/auth_return.html" } });
	T("oidc: a return address that only looks like ours", "firebase", { cfg: { googleIos: "oidc_popup", googleReturn: ORIGIN + ".evil.example/game/auth_return.html" } });
	T("oidc: a return address of plain http", "firebase", { cfg: { googleIos: "oidc_popup", googleReturn: "http://shakhzodmir.github.io/game/auth_return.html" } });
	T("oidc: no crypto", "firebase", { ...OIDC, noCrypto: true });
	T("oidc: storage that throws", "firebase", { ...OIDC, noLocalStorage: true });
	T("oidc_redirect is gated the same way", "firebase", { cfg: { googleIos: "oidc_redirect" }, noOidc: true });
	T("shim needs none of that", "shim", { cfg: { googleIos: "shim" }, noOidc: true, noCrypto: true });
}

// ------------------------------------------------------------------------------------------------------------------------
// 2. the SDK's own window: today's way unchanged, the shim, and the Home Screen app without a window
// ------------------------------------------------------------------------------------------------------------------------
const lineOf = (r) => (r ? { ok: r.ok, reason: r.reason } : null);

// the SDK's pop-up as the real one behaves: it opens its window a moment after the call (from a microtask), asks every 5 ms
// (2 s in real life) whether the window is closed and ends "closed" 10 ms after the first yes; if nothing is wrong it answers
// after answerMs. holder.g is the page; onOpen(window) sees what the SDK was given.
function sdkPopup(holder, { answerMs = 120, onOpen, beforeOpen } = {}) {
	return (kind, mkUser, auth, linkUser) => new Promise((resolve, reject) => {
		Promise.resolve().then(() => {
			if (beforeOpen) beforeOpen(); // the SDK reads navigator.standalone BEFORE it chooses window.open
			const w = holder.g.open("https://auth.example/handler", "name", "features");
			if (onOpen) onOpen(w);
			if (!w) return reject(err("auth/popup-blocked"));
			let gaveUp = false;
			const iv = setInterval(() => {
				if (w.closed && !gaveUp) { gaveUp = true; clearInterval(iv); setTimeout(() => reject(err("auth/popup-closed-by-user")), 10); }
			}, 5);
			setTimeout(() => {
				if (gaveUp) return;
				clearInterval(iv);
				if (kind === "link") { linkUser.providerData.push({ providerId: "google.com", email: "l@gmail.com" }); return resolve({ user: linkUser }); }
				auth.currentUser = mkUser("g-sdk");
				resolve({ user: auth.currentUser });
			}, answerMs);
		});
	});
}
// the window the browser really opened: it reads closed after flipMs although it is alive
function realWindow(flipMs) {
	const w = { closed: false, closes: 0, close() { this.closes++; this.closed = true; }, focus() {} };
	if (flipMs) setTimeout(() => { w.closed = true; }, flipMs);
	return w;
}

{
	// (a) the Firebase way: the SDK's own call, once, with the arguments it always had; nothing of ours touches the page
	const holder = {};
	const sdk = fakeSdk({ popup: (...a) => sdkPopup(holder, { answerMs: 10 })(...a) });
	const g = game({ sdk });
	holder.g = g;
	const open0 = (g.open = (u, n, f) => realWindow(0));
	const id = startCall(g, "sign_in_google", ["en"]);
	assert.ok(await waitFor(() => cards(g).length === 1));
	assert.equal(sdk.calls.length, 0, "nothing opens outside a tap");
	tapCard(g).click();
	const r = await waitLine(g, id);
	assert.deepEqual([r.ok, r.f.uid], [true, "g-sdk"]);
	assert.deepEqual(sdk.calls, [["signInWithPopup", true, true, 2]], "signInWithPopup(auth, new GoogleAuthProvider()), nothing more");
	assert.equal(g.open, open0, "window.open is the page's own");
	assert.deepEqual(worldKeys(g.world), [], "no key of ours in the storage: no attempt, no choice");
	assert.deepEqual([...g.ssMap.keys()], [], "...nor in the tab's");
	assert.equal(notes(g).length, 0);
	// the same for a link
	const holder2 = {};
	const cur = { uid: "P1", email: "p@id.glow.invalid", emailVerified: false, displayName: "", providerData: [{ providerId: "password" }] };
	const sdk2 = fakeSdk({ current: cur, popup: (...a) => sdkPopup(holder2, { answerMs: 10 })(...a) });
	const g2 = game({ sdk: sdk2 });
	holder2.g = g2; g2.open = () => realWindow(0);
	assert.ok((await ask(g2, "restore")).ok);
	const id2 = startCall(g2, "link_google", ["en"]);
	assert.ok(await waitFor(() => cards(g2).length === 1));
	tapCard(g2).click();
	const r2 = await waitLine(g2, id2);
	assert.deepEqual([r2.ok, r2.f.google, r2.f.uid], [true, "1", "P1"]);
	assert.deepEqual(sdk2.calls, [["linkWithPopup", true, true, 2]], "linkWithPopup(user, new GoogleAuthProvider())");
}

// where a window really is the SDK's: a desktop page with a live tap opens it at once (no card), as before
{
	const holder = {};
	const sdk = fakeSdk({ popup: (...a) => sdkPopup(holder, { answerMs: 10 })(...a) });
	const g = game({ ua: DESKTOP, sdk });
	holder.g = g; g.open = () => realWindow(0);
	const r = await ask(g, "sign_in_google", ["en"]);
	assert.deepEqual([r.ok, sdk.calls.length, cards(g).length], [true, 1, 0], "no card where a window may open at once");
}

// (b) the shim: the SDK's "closed" read is the thing that ends it, and the shim takes it away
for (const [flow, expectOk] of [["firebase", false], ["shim", true]]) {
	const holder = {}, opens = [];
	const sdk = fakeSdk({ popup: (...a) => sdkPopup(holder, { answerMs: 120 })(...a) });
	const g = game({ cfg: { googleIos: flow }, sdk, test: { lookMs: 10 } });
	holder.g = g;
	const real = realWindow(25); // the window the browser opened reads "closed" after 25 ms although the player is still choosing
	const mine = (g.open = (u, n, f) => { opens.push([u, n, f]); return real; });
	const id = startCall(g, "sign_in_google", ["en"]);
	assert.ok(await waitFor(() => cards(g).length === 1));
	tapCard(g).click();
	const r = await waitLine(g, id);
	assert.equal(r.ok, expectOk, flow + ": a window that reads closed after 25 ms while the answer comes after 120 ms");
	if (!expectOk) assert.equal(r.reason, "popup_closed"); else assert.equal(r.f.uid, "g-sdk");
	assert.deepEqual(opens, [["https://auth.example/handler", "name", "features"]], "the SDK's arguments reach the real window.open");
	assert.equal(g.open, mine, flow + ": window.open is the page's own again");
	assert.equal(g.open("x").closed, true, flow + ": ...and a later call gets the real window, not a stand-in");
	if (flow === "shim") {
		assert.equal(sdk.calls.length, 1);
		assert.equal(notes(g).length, 0, "no failure line for a success");
	} else {
		assert.match(notes(g)[0].textContent, / firebase$/);
	}
}
{
	// the stand-in passes close() and focus() on, and says "not closed" only while the real one is alive and ours
	const holder = {}; let given = null;
	const sdk = fakeSdk({ popup: (...a) => sdkPopup(holder, { answerMs: 60, onOpen: (w) => { given = w; } })(...a) });
	const g = game({ cfg: { googleIos: "shim" }, sdk });
	holder.g = g;
	const real = realWindow(5);
	g.open = () => real;
	const id = startCall(g, "sign_in_google", ["en"]);
	assert.ok(await waitFor(() => cards(g).length === 1));
	tapCard(g).click();
	await waitFor(() => given !== null);
	assert.notEqual(given, real, "the SDK got a stand-in");
	assert.equal(given.closed, false); await sleep(30); assert.equal(given.closed, false, "it never says closed");
	given.close(); assert.equal(real.closes, 1, "close() goes to the real window");
	await waitLine(g, id);
}
{
	// the browser refuses the window: the SDK is told so (null), the card keeps one more tap, a second refusal says so
	const holder = {}, opens = [];
	const sdk = fakeSdk({ popup: (...a) => sdkPopup(holder, { answerMs: 30 })(...a) });
	const g = game({ cfg: { googleIos: "shim" }, sdk });
	holder.g = g;
	g.open = () => { opens.push(1); return null; };
	const id = startCall(g, "sign_in_google", ["en"]);
	assert.ok(await waitFor(() => cards(g).length === 1));
	tapCard(g).click();
	assert.ok(await waitFor(() => opens.length === 1 && cards(g).length === 1 && !tapCard(g).disabled), "the card stays for one more tap");
	tapCard(g).click();
	const r = await waitLine(g, id);
	assert.deepEqual(lineOf(r), { ok: false, reason: "popup_blocked" });
	assert.equal(opens.length, 2);
}
{
	// the SDK never calls window.open (an error before it): everything is put back when the call ends; in the Home Screen app too
	for (const home of [false, true]) {
		const sdk = fakeSdk({ popup: () => Promise.reject(err("auth/internal-error")) });
		const g = game({ cfg: home ? { googleIosHome: "shim" } : { googleIos: "shim" }, ua: home ? IPHONE_HOME : IPHONE, standalone: home ? true : undefined, sdk, test: { lookMs: 10, homeLookMs: 10 } });
		const mine = (g.open = () => realWindow(0));
		const id = startCall(g, "sign_in_google", ["en"]);
		assert.ok(await waitFor(() => cards(g).length === 1));
		tapCard(g).click();
		const r = await waitLine(g, id);
		assert.deepEqual(lineOf(r), { ok: false, reason: "error" });
		assert.equal(g.open, mine, "window.open is back");
		assert.equal(g.navigator.standalone, home ? true : undefined, "navigator.standalone is back");
	}
}
{
	// the safety: the SDK never calls and never ends (its helper frame does not load): the page is put back anyway
	const sdk = fakeSdk({ popup: () => new Promise(() => {}) });
	const g = game({ ua: IPHONE_HOME, standalone: true, cfg: { googleIosHome: "shim" }, sdk, test: { shimSafetyMs: 40, cancelLookMs: 10 } });
	const mine = (g.open = () => realWindow(0));
	const id = startCall(g, "sign_in_google", ["en"]);
	assert.ok(await waitFor(() => cards(g).length === 1));
	tapCard(g).click();
	assert.equal(g.navigator.standalone, false, "while the SDK is asked, the page says it is not a Home Screen app");
	assert.ok(await waitFor(() => g.navigator.standalone === true, 1000), "and says so again after the safety time");
	assert.equal(g.open, mine);
	cancelCard(g).click();
	assert.equal((await waitLine(g, id)).reason, "popup_closed");
}
{
	// the Home Screen app: the SDK sees navigator.standalone === false when it opens its window, and true again right after
	const holder = {}; let seen = null;
	const sdk = fakeSdk({ popup: (...a) => sdkPopup(holder, { answerMs: 40, beforeOpen: () => { seen = holder.g.navigator.standalone; } })(...a) });
	const g = game({ ua: IPHONE_HOME, standalone: true, cfg: { googleIosHome: "shim" }, sdk });
	holder.g = g; g.open = () => realWindow(10);
	const id = startCall(g, "sign_in_google", ["en"]);
	assert.ok(await waitFor(() => cards(g).length === 1));
	tapCard(g).click();
	const r = await waitLine(g, id);
	assert.equal(r.ok, true);
	assert.equal(seen, false, "the SDK took the window.open path");
	assert.equal(g.navigator.standalone, true, "restored");
	assert.equal(g.glowAuth.flow(), "shim");
}
{
	// the bounds: the SDK's own window in the Home Screen app ends at HOME_POPUP_MS with home_app; the shim keeps the long bound
	for (const [flow, wantReason, maxMs] of [["firebase", "home_app", 5000], ["shim", "popup_timeout", 700]]) {
		const sdk = fakeSdk({ popup: () => new Promise(() => {}) });
		const g = game({ ua: IPHONE_HOME, standalone: true, cfg: { googleIosHome: flow }, sdk, test: { popupMs: 300, homePopupMs: 30, homeLookMs: 900, lookMs: 5 } });
		g.open = () => realWindow(0);
		const id = startCall(g, "sign_in_google", ["en"]);
		assert.ok(await waitFor(() => cards(g).length === 1));
		const t0 = Date.now();
		tapCard(g).click();
		await sleep(150);
		if (flow === "shim") assert.equal(g.glowAuth.poll(), "", "the shim is still waiting after the Home Screen bound has passed");
		const r = await waitLine(g, id);
		assert.ok(Date.now() - t0 < maxMs, flow + ": the look at the account after the bound is the short one for the shim, the Home Screen one for the SDK window");
		assert.deepEqual(lineOf(r), { ok: false, reason: wantReason }, flow);
		assert.match(notes(g)[0].textContent, new RegExp(" " + flow + "$"), "the dark line names the way");
	}
}
{
	// our own Cancel during the shim's wait: the shim ends as "the window closed" (not silent), and says which way
	const sdk = fakeSdk({ popup: () => new Promise(() => {}) });
	const g = game({ cfg: { googleIos: "shim" }, sdk, test: { cancelLookMs: 10 } });
	g.open = () => realWindow(0);
	const id = startCall(g, "sign_in_google", ["en"]);
	assert.ok(await waitFor(() => cards(g).length === 1));
	tapCard(g).click();
	cancelCard(g).click();
	const r = await waitLine(g, id);
	assert.deepEqual(lineOf(r), { ok: false, reason: "popup_closed" });
	assert.match(notes(g)[0].textContent, /^google glow\/cancel-waiting ios-tab \d+s v\S+ shim$/);
}
{
	// a link through the shim
	const holder = {};
	const cur = { uid: "P2", email: "p@id.glow.invalid", emailVerified: false, displayName: "", providerData: [{ providerId: "password" }] };
	const sdk = fakeSdk({ current: cur, popup: (...a) => sdkPopup(holder, { answerMs: 60 })(...a) });
	const g = game({ cfg: { googleIos: "shim" }, sdk });
	holder.g = g; g.open = () => realWindow(15);
	assert.ok((await ask(g, "restore")).ok);
	const id = startCall(g, "link_google", ["en"]);
	assert.ok(await waitFor(() => cards(g).length === 1));
	tapCard(g).click();
	const r = await waitLine(g, id);
	assert.deepEqual([r.ok, r.f.google, r.f.uid], [true, "1", "P2"]);
}

// (c) no_window: the Home Screen app asks for no window at all
for (const op of ["sign_in_google", "link_google"]) {
	const holder = {}, opens = [];
	const cur = { uid: "P3", email: "p@id.glow.invalid", emailVerified: false, displayName: "", providerData: [{ providerId: "password" }] };
	const sdk = fakeSdk({ current: cur, popup: (...a) => sdkPopup(holder)(...a) });
	const g = game({ ua: IPHONE_HOME, standalone: true, cfg: { googleIosHome: "no_window" }, sdk });
	holder.g = g; g.open = () => { opens.push(1); return realWindow(0); };
	assert.ok((await ask(g, "restore")).ok);
	const t0 = Date.now();
	const r = await ask(g, op, ["en"]);
	assert.deepEqual(lineOf(r), { ok: false, reason: "home_app" }, op);
	assert.ok(Date.now() - t0 < 500, "at once");
	assert.deepEqual([cards(g).length, opens.length, sdk.calls.length], [0, 0, 0], "no card, no window, no SDK call");
	assert.match(notes(g)[0].textContent, /^google glow\/no-window ios-home \d+s v\S+ no_window$/);
}

// (d) an in-app browser gets no Google whatever the settings say
for (const flow of ["firebase", "shim", "oidc_popup", "oidc_redirect", "no_window"]) {
	const sdk = fakeSdk({ popup: () => Promise.resolve({}) });
	const g = game({ ua: TELEGRAM, cfg: { googleIos: flow, googleIosHome: flow }, sdk });
	g.open = () => realWindow(0);
	const r = await ask(g, "sign_in_google", ["en"]);
	assert.deepEqual(lineOf(r), { ok: false, reason: "inapp_browser" }, flow);
	assert.deepEqual([cards(g).length, sdk.calls.length], [0, 0]);
}

console.log("auth_flows_check: part 2 (the SDK window, the shim, no_window) ok");

// ------------------------------------------------------------------------------------------------------------------------
// 3. oidc_popup: our own request to Google in a window, the real return page, a fake Google, a fake Firebase
// ------------------------------------------------------------------------------------------------------------------------
const nowS = () => Math.floor(Date.now() / 1000);
const jwt = (claims) => b64u(JSON.stringify({ alg: "RS256", kid: "k" })) + "." + b64u(JSON.stringify(claims)) + ".sig";
// an answer of Google for the request p (its parameters), made by hand (a window that answers late, a replay)
function answerFrag(p, o = {}) {
	const claims = { iss: "https://accounts.google.com", aud: CLIENT, sub: o.sub || "2002", email: "late@gmail.com", iat: nowS(), exp: nowS() + 3600, nonce: p.nonce, ...(o.claims || {}) };
	const at = "ya29.late-access";
	const rt = String(p.response_type);
	if (rt.indexOf("token") >= 0) claims.at_hash = b64u(createHash("sha256").update(at).digest().subarray(0, 16));
	let f = "state=" + (o.state || p.state);
	if (rt.indexOf("id_token") >= 0) f = "id_token=" + jwt(claims) + "&" + f;
	if (rt !== "id_token") f = "access_token=" + at + "&token_type=Bearer&expires_in=3599&" + f;
	return f;
}
const oidcKeys = (g) => [...worldKeys(g.world), ...g.ssMap.keys()].filter((k) => k.indexOf("glow_oidc") === 0);
const stopped = (g) => ["message", "storage", "pageshow", "focus"].every((t) => (g._l[t] || []).length === 0) && (g._docl.visibilitychange || []).length === 0;
const popupWorld = (sc = {}) => { const world = makeWorld(); installGoogle(world, sc); return world; };
const OIDC_POPUP = { googleIos: "oidc_popup" };
async function tapped(g, op = "sign_in_google", args = ["en"]) {
	const id = startCall(g, op, args);
	assert.ok(await waitFor(() => cards(g).length === 1), "the tap card is up");
	tapCard(g).click();
	return id;
}
function kill(g) { // the page is gone for good (a tab iOS discarded): no timer, no listener, no delivery
	g.timers.forEach((h) => clearInterval(h));
	g._l = {}; g._docl = {}; g.gone = true;
}
const pwUser = (uid) => ({ uid, email: uid + "@id.glow.invalid", emailVerified: false, displayName: "", providerData: [{ providerId: "password" }], metadata: {} });

{
	// (a) the sign-in, from the tap to the account
	const world = popupWorld();
	const sdk = fakeSdk();
	const g = game({ world, cfg: OIDC_POPUP, sdk });
	assert.equal(g.glowAuth.flow(), "oidc_popup");
	const real = g.open, seen = [];
	g.open = (u, n) => {
		seen.push({ u, n, pend: g.ssMap.has("glow_oidc_pend"), beacon: [...world.ls.keys()].some((k) => k.indexOf("glow_oidc_pend:") === 0), chan: world.bus.has("glow_oidc"), own: g.ssMap.has("glow_oidc_own") });
		return real(u, n);
	};
	const id = startCall(g, "sign_in_google", ["en"]);
	assert.ok(await waitFor(() => cards(g).length === 1), "the tap card first");
	assert.equal(seen.length, 0, "nothing opens outside the tap");
	await sleep(80); // the secrets were made before the card; the player taps later
	const tapAt = Date.now();
	tapCard(g).click();
	assert.equal(seen.length, 1, "window.open ran inside the tap itself, with nothing asynchronous before it");
	assert.deepEqual([seen[0].pend, seen[0].beacon, seen[0].chan, seen[0].own], [true, true, true, false],
		"the attempt is saved and the receivers armed BEFORE the window opens; the marker is written only after");
	assert.equal(g.ssMap.has("glow_oidc_own"), true);
	assert.equal(tapCard(g).disabled, true, "the card says it waits");
	const q = new URL(seen[0].u).searchParams;
	assert.equal(new URL(seen[0].u).origin + new URL(seen[0].u).pathname, "https://accounts.google.com/o/oauth2/v2/auth");
	assert.deepEqual([q.get("client_id"), q.get("redirect_uri"), q.get("response_type"), q.get("scope"), q.get("prompt")], [CLIENT, RETURN_URL, "id_token token", "openid email profile", "select_account"]);
	assert.match(q.get("nonce"), /^[0-9a-f]{64}$/);
	assert.match(q.get("state"), /^pg\.[A-Za-z0-9_-]{24}$/, "p = a window, g = the game");
	for (const bad of ["response_mode", "include_granted_scopes", "hd", "login_hint"]) assert.equal(q.has(bad), false, bad + " is never sent");
	assert.equal(seen[0].n, "glow_oidc_" + q.get("state").slice(-6), "a window name of its own for every attempt");
	const rec = JSON.parse(g.ssMap.get("glow_oidc_pend"));
	assert.deepEqual([rec.op, rec.c, rec.m, rec.d, sha256hex(rec.r) === q.get("nonce")], ["in", "tab", "p", "g", true], "the secret stays here; Google got only its hash");
	assert.ok(rec.t >= tapAt && rec.t - tapAt < 1000, "the attempt ages from the tap, not from when its secrets were made");
	const beacon = JSON.parse(g.world.ls.get("glow_oidc_pend:" + rec.s));
	assert.equal(beacon.r, undefined, "the shared storage never holds the raw nonce in this mode");
	const r = await waitLine(g, id);
	assert.deepEqual([r.ok, r.f.uid, r.f.kind, r.f.google], [true, "u1001", "google", "1"]);
	assert.deepEqual(sdk.calls, [["signInWithCredential", "A"]]);
	assert.deepEqual([cards(g).length, notes(g).length, oidcKeys(g), stopped(g)], [0, 0, [], true], "the card is gone, nothing is left behind, nothing listens any more");
	assert.ok(await waitFor(() => world.pages[0].page && world.pages[0].page.closeCalls >= 1), "the return page closed Google's window once the answer was taken");
	// the account is the game's now (told): the next account call is not refused
	assert.ok((await ask(g, "cloud_get")).ok);
}

// (b) closed===true never ends the wait; and each way of handing the answer over, alone, works
for (const [name, sc] of [
	["the window reads closed all the time and has no link to us", { sever: true }],
	["only the mailbox", { sever: true, noBCReturn: true }],
	["only the broadcast channel", { sever: true, noLocalStorageReturn: true }],
	["only window.opener.postMessage", { noLocalStorageReturn: true, noBCReturn: true }],
	["a slow Google", { delay: 300 }],
	["the return page cannot close its window", { refuseClose: true }],
]) {
	const world = popupWorld(sc), sdk = fakeSdk();
	const g = game({ world, cfg: OIDC_POPUP, sdk });
	const id = await tapped(g);
	const r = await waitLine(g, id);
	assert.deepEqual([name, r && r.ok, sdk.calls.length], [name, true, 1]);
	assert.deepEqual([oidcKeys(g), stopped(g)], [[], true], name);
}

// (c) what an answer can be, and what it must never do
for (const [name, sc, wantReason, wantCode] of [
	["Cancel on Google's page", { error: "access_denied" }, "cancelled", null],
	["another error of Google's", { error: "invalid_request" }, "error", "glow/oidc-oauth_invalid_request"],
	["a wrong nonce", { badNonce: true }, "error", "glow/oidc-nonce"],
	["another audience", { claims: { aud: "other.apps.googleusercontent.com" } }, "error", "glow/oidc-aud"],
	["another issuer", { claims: { iss: "https://evil.example" } }, "error", "glow/oidc-iss"],
	["an expired id_token", { claims: { exp: nowS() - 3 * 24 * 3600 } }, "error", "glow/oidc-expired"],
	["no id_token", { noIdToken: true }, "error", "glow/oidc-no_id_token"],
	["no access token though one was asked for", { noAccess: true }, "error", "glow/oidc-no_access_token"],
]) {
	const world = popupWorld(sc), sdk = fakeSdk();
	const g = game({ world, cfg: OIDC_POPUP, sdk });
	const id = await tapped(g);
	const r = await waitLine(g, id);
	assert.deepEqual([name, lineOf(r)], [name, { ok: false, reason: wantReason }]);
	assert.equal(sdk.calls.length, 0, name + ": nothing reached Firebase");
	if (wantCode) assert.match(notes(g)[0].textContent, new RegExp("^google " + wantCode.replace("/", "\\/") + " ios-tab \\d+s v\\S+ oidc_popup$"), name);
	else assert.equal(notes(g).length, 0, name + ": the player's own Cancel says nothing");
	assert.deepEqual([cards(g).length, oidcKeys(g), stopped(g)], [0, [], true], name + ": the card is gone and nothing is left behind");
}

{
	// (d) an answer for another state is not ours: ignored, not an error; the wait goes on until Cancel
	const world = popupWorld({ badState: true }), sdk = fakeSdk();
	const g = game({ world, cfg: OIDC_POPUP, sdk });
	const id = await tapped(g);
	await sleep(500);
	assert.ok(world.pages[0].page, "the return page did run");
	assert.deepEqual([g.glowAuth.poll(), sdk.calls.length, cards(g).length, tapCard(g).disabled], ["", 0, 1, true], "still waiting");
	cancelCard(g).click();
	assert.deepEqual(lineOf(await waitLine(g, id)), { ok: false, reason: "popup_closed" });
	assert.deepEqual([oidcKeys(g), stopped(g)], [[], true]);
}

{
	// (e) a stale answer: attempt 1 is cancelled, its window answers late, attempt 2 is waiting; nobody is signed in by it
	const world = popupWorld({ stay: true }), sdk = fakeSdk();
	const g = game({ world, cfg: OIDC_POPUP, sdk });
	const id1 = await tapped(g);
	const p1 = { ...world.google[0].params }, child1 = world.pages[0];
	cancelCard(g).click();
	assert.deepEqual(lineOf(await waitLine(g, id1)), { ok: false, reason: "popup_closed" });
	assert.equal(child1.closeCalls, 1, "our own Cancel closes Google's window");
	assert.deepEqual([oidcKeys(g), stopped(g)], [[], true]);
	world.scenario.stay = false;
	const id2 = await tapped(g);
	loadReturn(world, { href: RETURN_URL + "#" + answerFrag(p1, { sub: "9999" }), from: child1, opener: g, sc: {} }); // the old window finishes now
	const r2 = await waitLine(g, id2);
	assert.deepEqual([r2.ok, r2.f.uid], [true, "u1001"], "attempt 2 signs in with ITS answer, not the stale one");
	assert.deepEqual(sdk.calls, [["signInWithCredential", "A"]]);
	// ... and a replay of the answer that was just used, by every channel, finds nobody
	const used = world.pages[1].page.posted.find((x) => x.data && x.data.k === "glow_oidc");
	if (used) { g.localStorage.setItem("glow_oidc_res:" + used.data.s, JSON.stringify(used.data)); g.dispatch("message", { origin: ORIGIN, data: used.data, source: null }); }
	loadReturn(world, { href: RETURN_URL + "#" + answerFrag(p1, { sub: "9999" }), from: child1, opener: g, sc: {} });
	await sleep(350);
	assert.equal(sdk.calls.length, 1, "nothing signs in a second time");
}

{
	// (e2) the pop-up is alive: an answer posted by another window of the same origin is not the pop-up's
	const world = popupWorld({ stay: true }), sdk = fakeSdk();
	const g = game({ world, cfg: OIDC_POPUP, sdk });
	const id = await tapped(g);
	const p = world.google[0].params;
	const other = makeWindow(world, { href: ORIGIN + "/game/other.html" });
	g.dispatch("message", { type: "message", origin: ORIGIN, source: other.handle, data: { k: "glow_oidc", v: 1, h: answerFrag(p), q: "", t: Date.now(), d: {} } });
	await sleep(350);
	assert.deepEqual([g.glowAuth.poll(), sdk.calls.length], ["", 0], "ignored: not from the window we opened");
	g.dispatch("message", { type: "message", origin: ORIGIN, source: world.pages[0].handle, data: { k: "glow_oidc", v: 1, h: answerFrag(p), q: "", t: Date.now(), d: {} } });
	assert.equal((await waitLine(g, id)).ok, true, "the same answer from the window we opened is taken");
}

{
	// (f) a second tap while the window is out is "busy", not a second window
	const world = popupWorld({ stay: true }), sdk = fakeSdk();
	const g = game({ world, cfg: OIDC_POPUP, sdk });
	const id = await tapped(g);
	const r2 = await ask(g, "sign_in_google", ["en"]);
	assert.deepEqual(lineOf(r2), { ok: false, reason: "busy" });
	assert.equal(world.google.length, 1, "one window");
	cancelCard(g).click();
	await waitLine(g, id);
}

{
	// (g) our Cancel: the window is closed, nothing is left, the account is looked at only if an exchange was under way
	const world = popupWorld({ stay: true }), sdk = fakeSdk();
	const g = game({ world, cfg: OIDC_POPUP, sdk, test: { cancelLookMs: 1500 } });
	const id = await tapped(g);
	const t0 = Date.now();
	cancelCard(g).click();
	const r = await waitLine(g, id);
	assert.deepEqual(lineOf(r), { ok: false, reason: "popup_closed" });
	assert.ok(Date.now() - t0 < 800, "no look at the account where nothing can finish late");
	assert.match(notes(g)[0].textContent, /^google glow\/cancel-waiting ios-tab \d+s v\S+ oidc_popup$/);
	assert.equal(world.pages[0].closeCalls, 1);
	assert.deepEqual([oidcKeys(g), stopped(g), cards(g).length], [[], true, 0]);
	// a Cancel while the answer is being exchanged is the case that look is for: the sign-in goes through, and counts
	const w2 = popupWorld(), sdk2 = fakeSdk({ exchangeMs: 300 });
	const g2 = game({ world: w2, cfg: OIDC_POPUP, sdk: sdk2, test: { cancelLookMs: 2000 } });
	const id2 = await tapped(g2);
	assert.ok(await waitFor(() => sdk2.calls.length === 1), "the answer is being exchanged");
	cancelCard(g2).click();
	const r2 = await waitLine(g2, id2);
	assert.deepEqual([r2.ok, r2.f.uid], [true, "u1001"], "a sign-in that finished while the card was cancelled still counts");
}

{
	// (h) the bound: 240 s in real life; the Home Screen app's shorter bound is the SDK window's, not ours
	for (const home of [false, true]) {
		const world = popupWorld({ stay: true }), sdk = fakeSdk();
		const g = game({ world, ua: home ? IPHONE_HOME : IPHONE, standalone: home ? true : undefined, cfg: home ? { googleIosHome: "oidc_popup" } : OIDC_POPUP, sdk, test: { popupMs: 400, homePopupMs: 30, lookMs: 5, homeLookMs: 5 } });
		const id = await tapped(g);
		await sleep(200);
		assert.equal(g.glowAuth.poll(), "", "still waiting past the Home Screen bound");
		const r = await waitLine(g, id);
		assert.deepEqual(lineOf(r), { ok: false, reason: "popup_timeout" }, "ends at the long bound, said as a timeout");
		assert.deepEqual([oidcKeys(g), stopped(g), cards(g).length, world.pages[0].closeCalls], [[], true, 0, 1]);
	}
}

{
	// (i) the browser refuses the window: the secrets go back unused, one more tap is allowed, a second refusal is said
	const world = popupWorld(), sdk = fakeSdk();
	const g = game({ world, cfg: OIDC_POPUP, sdk });
	g.openBlocked = true;
	const id = await tapped(g);
	assert.ok(await waitFor(() => cards(g).length === 1 && !tapCard(g).disabled), "the card keeps one more tap");
	assert.deepEqual([oidcKeys(g), stopped(g)], [[], true], "a refused window leaves nothing behind");
	g.openBlocked = false;
	tapCard(g).click();
	const r = await waitLine(g, id);
	assert.deepEqual([r.ok, sdk.calls.length], [true, 1], "the second tap works");
	// two refusals
	const w2 = popupWorld(), g2 = game({ world: w2, cfg: OIDC_POPUP, sdk: fakeSdk() });
	g2.openBlocked = true;
	const id2 = await tapped(g2);
	assert.ok(await waitFor(() => !tapCard(g2).disabled));
	tapCard(g2).click();
	assert.deepEqual(lineOf(await waitLine(g2, id2)), { ok: false, reason: "popup_blocked" });
	assert.deepEqual([oidcKeys(g2), stopped(g2), cards(g2).length], [[], true, 0]);
	// window.open that throws is a refusal too
	const g3 = game({ world: popupWorld(), cfg: OIDC_POPUP, sdk: fakeSdk() });
	g3.open = () => { throw new Error("SecurityError"); };
	const id3 = await tapped(g3);
	assert.ok(await waitFor(() => !tapCard(g3).disabled));
	tapCard(g3).click();
	assert.equal((await waitLine(g3, id3)).reason, "popup_blocked");
}

{
	// (j) where a window may open at once (desktop, Android with a live tap) there is no card first, and the same flow runs
	for (const ua of [DESKTOP, ANDROID]) {
		const world = popupWorld(), sdk = fakeSdk();
		const g = game({ world, ua, search: "?google=oidc_popup", sdk });
		assert.equal(g.glowAuth.flow(), "oidc_popup");
		const r = await ask(g, "sign_in_google", ["en"]);
		assert.deepEqual([r.ok, world.google.length, cards(g).length, sdk.calls.length], [true, 1, 0, 1]);
		assert.equal(world.google[0].params.state.slice(0, 3), "pg.");
	}
}

{
	// (k) a sign-in while another account is current, and the "told" rule
	const world = popupWorld(), sdk = fakeSdk({ current: pwUser("P1") });
	const g = game({ world, cfg: OIDC_POPUP, sdk });
	assert.equal((await ask(g, "restore")).f.uid, "P1");
	const id = await tapped(g);
	const r = await waitLine(g, id);
	assert.deepEqual([r.ok, r.f.uid, sdk.auth.currentUser.uid], [true, "u1001", "u1001"], "the other account is replaced by the one the player chose");
	assert.ok((await ask(g, "cloud_get")).ok, "and the game knows it");
	// somebody else signs in at the same moment: the answer is not taken for ours
	const w2 = popupWorld(), sdk2 = fakeSdk({ swap: (auth, mk) => { auth.currentUser = mk("other"); } });
	const g2 = game({ world: w2, cfg: OIDC_POPUP, sdk: sdk2 });
	const id2 = await tapped(g2);
	assert.deepEqual(lineOf(await waitLine(g2, id2)), { ok: false, reason: "no_user" });
}

{
	// (l) link: Google joins the account the game knows
	const world = popupWorld(), P = pwUser("P1"), sdk = fakeSdk({ current: P });
	const g = game({ world, cfg: OIDC_POPUP, sdk });
	await ask(g, "restore");
	const id = await tapped(g, "link_google");
	const rec = JSON.parse(g.ssMap.get("glow_oidc_pend"));
	assert.deepEqual([rec.op, rec.u], ["link", "P1"], "the attempt says whose link it is");
	const r = await waitLine(g, id);
	assert.deepEqual([r.ok, r.f.uid, r.f.google], [true, "P1", "1"]);
	assert.deepEqual(sdk.calls, [["linkWithCredential", "A"]]);
	assert.deepEqual([oidcKeys(g), stopped(g)], [[], true]);
	// the Google account already belongs to another player
	const g2 = game({ world: popupWorld(), cfg: OIDC_POPUP, sdk: fakeSdk({ current: pwUser("P2"), linkTaken: true }) });
	await ask(g2, "restore");
	assert.deepEqual(lineOf(await waitLine(g2, await tapped(g2, "link_google"))), { ok: false, reason: "already_linked" });
	// the account that asked is not the one signed in when the answer comes: nothing is linked to the wrong one
	const s3 = fakeSdk({ current: pwUser("P3") });
	const g3 = game({ world: popupWorld({ delay: 150 }), cfg: OIDC_POPUP, sdk: s3 });
	await ask(g3, "restore");
	const id3 = await tapped(g3, "link_google");
	s3.auth.currentUser = pwUser("P9");
	assert.deepEqual(lineOf(await waitLine(g3, id3)), { ok: false, reason: "no_user" });
	assert.equal(s3.calls.length, 0, "the SDK was never asked to link");
	// the game's own told rule at the start: a current user it does not know is refused before any window
	const s4 = fakeSdk({ current: pwUser("P4") });
	const g4 = game({ world: popupWorld(), cfg: OIDC_POPUP, sdk: s4 });
	await ask(g4, "restore");
	s4.auth.currentUser = pwUser("P8");
	assert.deepEqual(lineOf(await ask(g4, "link_google", ["en"])), { ok: false, reason: "no_user" });
	assert.equal(g4.world.google.length, 0, "no window");
}

// (m) which credential, and when to go on to the next
for (const [name, o, want] of [
	["A signs in", {}, { ok: true, calls: ["A"] }],
	["the nonce refused: the access token that the id_token vouches for is next", { sdk: { fail: { A: "auth/missing-or-invalid-nonce" } } }, { ok: true, calls: ["A", "T"] }],
	["the nonce refused and no at_hash: the access token is never submitted", { sc: { noAtHash: true }, sdk: { fail: { A: "auth/missing-or-invalid-nonce" } } }, { ok: false, reason: "error", calls: ["A"], detail: /A=auth\/missing-or-invalid-nonce$/ }],
	["the access token does not belong to the id_token", { sc: { badAccess: true }, sdk: { fail: { A: "auth/missing-or-invalid-nonce" } } }, { ok: false, reason: "error", calls: ["A"] }],
	["another refusal of A ends it: no second credential", { sdk: { fail: { A: "auth/invalid-credential" } } }, { ok: false, reason: "error", calls: ["A"], detail: /A=auth\/invalid-credential$/ }],
	["a network error ends it", { sdk: { fail: { A: "auth/network-request-failed" } } }, { ok: false, reason: "offline", calls: ["A"] }],
	["a disabled account", { sdk: { fail: { A: "auth/user-disabled" } } }, { ok: false, reason: "no_user", calls: ["A"] }],
	["both refused", { sdk: { fail: { A: "auth/missing-or-invalid-nonce", T: "auth/invalid-credential" } } }, { ok: false, reason: "error", calls: ["A", "T"], detail: /A=auth\/missing-or-invalid-nonce T=auth\/invalid-credential$/ }],
	["only B asked for", { test: { oidcCred: "B" } }, { ok: true, calls: ["B"] }],
	["only T asked for", { test: { oidcCred: "T" } }, { ok: true, calls: ["T"] }],
	["response_type=id_token: A, and there is no access token to fall back on", { test: { oidcResponse: "id_token" }, sdk: { fail: { A: "auth/missing-or-invalid-nonce" } }, rt: "id_token" }, { ok: false, reason: "error", calls: ["A"] }],
	["response_type=token: no nonce is sent, the access token alone signs in", { test: { oidcResponse: "token", oidcCred: "T" }, rt: "token" }, { ok: true, calls: ["T"] }],
]) {
	const world = popupWorld(o.sc || {}), sdk = fakeSdk(o.sdk || {});
	const g = game({ world, cfg: OIDC_POPUP, sdk, test: o.test });
	const id = await tapped(g);
	const r = await waitLine(g, id);
	assert.deepEqual([name, r.ok, sdk.calls.map((c) => c[1])], [name, want.ok, want.calls]);
	if (!want.ok) assert.equal(r.reason, want.reason, name);
	if (want.detail) assert.match(notes(g)[0].textContent, want.detail, name);
	const q = world.google[0].params;
	assert.equal(q.response_type, o.rt || "id_token token", name);
	assert.equal(q.nonce === undefined, (o.rt || "") === "token", name + ": no nonce with response_type=token");
	assert.deepEqual([oidcKeys(g), stopped(g)], [[], true], name);
}

// (n) the sign-in is finished by the page that loads next: a tab discarded while Google's window was open (its own storage lives on)
{
	const world = popupWorld({ delay: 120 }), sdk = fakeSdk();
	const g1 = game({ world, cfg: OIDC_POPUP, sdk });
	await tapped(g1);
	kill(g1); // the tab is gone before Google's window answers
	assert.ok(await waitFor(() => [...world.ls.keys()].some((k) => k.indexOf("glow_oidc_res:") === 0)), "the answer waits in the mailbox");
	// another tab of the game, with its own storage: not its attempt, so it must not take it
	const other = game({ world, cfg: OIDC_POPUP, sdk: fakeSdk() });
	const ro = await ask(other, "restore");
	assert.deepEqual([ro.ok, ro.f.uid, ro.f.ret], [true, undefined, undefined], "another tab finishes nothing of this one's");
	assert.ok([...world.ls.keys()].some((k) => k.indexOf("glow_oidc_res:") === 0), "...and leaves the answer where it is");
	// a window opened from the tab has a COPY of its storage but not the marker: it does not take it either
	const copy = new Map(g1.ssMap); copy.delete("glow_oidc_own");
	const child = game({ world, ss: copy, cfg: OIDC_POPUP, sdk: fakeSdk() });
	assert.equal((await ask(child, "restore")).f.ret, undefined);
	// the same tab, a new page: it finishes the sign-in
	const sdk2 = fakeSdk();
	const g2 = game({ world, ss: g1.ssMap, cfg: OIDC_POPUP, sdk: sdk2 });
	const r = await ask(g2, "restore");
	assert.deepEqual([r.ok, r.f.uid, r.f.ret], [true, "u1001", "ok"]);
	assert.deepEqual(sdk2.calls, [["signInWithCredential", "A"]]);
	assert.deepEqual([oidcKeys(g2)], [[]], "single use: everything of the attempt is gone");
	assert.ok((await ask(g2, "cloud_get")).ok, "the game knows the account");
	assert.equal(notes(g2).length, 0);
	// the same answer a second time finds no attempt
	const g3 = game({ world, ss: g1.ssMap, cfg: OIDC_POPUP, sdk: fakeSdk() });
	assert.equal((await ask(g3, "restore")).f.ret, undefined);
}
{
	// ... a link too, only for the account that asked
	for (const same of [true, false]) {
		const world = popupWorld({ delay: 120 }), s1 = fakeSdk({ current: pwUser("P1") });
		const g1 = game({ world, cfg: OIDC_POPUP, sdk: s1 });
		await ask(g1, "restore");
		await tapped(g1, "link_google");
		kill(g1);
		assert.ok(await waitFor(() => [...world.ls.keys()].some((k) => k.indexOf("glow_oidc_res:") === 0)));
		const s2 = fakeSdk({ current: pwUser(same ? "P1" : "P7") });
		const g2 = game({ world, ss: g1.ssMap, cfg: OIDC_POPUP, sdk: s2 });
		const r = await ask(g2, "restore");
		if (same) { assert.deepEqual([r.f.ret, r.f.google, s2.calls], ["linked", "1", [["linkWithCredential", "A"]]]); assert.equal(notes(g2).length, 0); }
		else { assert.deepEqual([r.f.ret, s2.calls.length, r.f.uid], ["error", 0, "P7"], "not linked to somebody else"); assert.match(notes(g2)[0].textContent, /^google glow\/oidc-link-user /); }
		assert.deepEqual(oidcKeys(g2), []);
	}
}
for (const [name, sc, ret, noted] of [
	["Cancel on Google's page", { error: "access_denied", delay: 100 }, "cancelled", false],
	["a bad answer", { badNonce: true, delay: 100 }, "error", true],
]) {
	const world = popupWorld(sc), g1 = game({ world, cfg: OIDC_POPUP, sdk: fakeSdk() });
	await tapped(g1); kill(g1);
	assert.ok(await waitFor(() => [...world.ls.keys()].some((k) => k.indexOf("glow_oidc_res:") === 0)), name);
	const sdk2 = fakeSdk(), g2 = game({ world, ss: g1.ssMap, cfg: OIDC_POPUP, sdk: sdk2 });
	const r = await ask(g2, "restore");
	assert.deepEqual([name, r.ok, r.f.ret, sdk2.calls.length, notes(g2).length > 0], [name, true, ret, 0, noted]);
	assert.deepEqual(oidcKeys(g2), [], name);
}
{
	// no answer yet: a young attempt is left alone (its window may still answer), an old one goes; nothing is signed in
	const world = popupWorld({ stay: true }), g1 = game({ world, cfg: OIDC_POPUP, sdk: fakeSdk() });
	await tapped(g1); kill(g1);
	const g2 = game({ world, ss: g1.ssMap, cfg: OIDC_POPUP, sdk: fakeSdk() });
	assert.equal((await ask(g2, "restore")).f.ret, undefined);
	assert.ok(g1.ssMap.has("glow_oidc_pend"), "a young attempt stays");
	const old = JSON.parse(g1.ssMap.get("glow_oidc_pend")); old.t = Date.now() - 241 * 1000; g1.ssMap.set("glow_oidc_pend", JSON.stringify(old));
	const g3 = game({ world, ss: g1.ssMap, cfg: OIDC_POPUP, sdk: fakeSdk() });
	const r3 = await ask(g3, "restore");
	assert.deepEqual([r3.f.ret, g3.ssMap.has("glow_oidc_pend"), notes(g3).length], ["cancelled", false, 0], "an old attempt is dropped without a word");
}
{
	// a Firebase that never answers: the start of the game is not held longer than the bound
	const world = popupWorld({ delay: 100 }), g1 = game({ world, cfg: OIDC_POPUP, sdk: fakeSdk() });
	await tapped(g1); kill(g1);
	assert.ok(await waitFor(() => [...world.ls.keys()].some((k) => k.indexOf("glow_oidc_res:") === 0)));
	const t0 = Date.now(), g2 = game({ world, ss: g1.ssMap, cfg: OIDC_POPUP, sdk: fakeSdk({ hang: true }), test: { restoreMs: 150 } });
	const r = await ask(g2, "restore");
	assert.deepEqual([r.ok, r.f.ret], [true, "timeout"]);
	assert.ok(Date.now() - t0 < 2000);
	assert.match(notes(g2)[0].textContent, /^google glow\/restore-timeout /);
}
{
	// old answers are swept at the start; a flow that is off never reads any of it
	const world = popupWorld(), g0 = game({ world, cfg: OIDC_POPUP, sdk: fakeSdk() });
	g0.localStorage.setItem("glow_oidc_res:pg.stale0000000000000000000", JSON.stringify({ k: "glow_oidc", v: 1, h: "id_token=x&state=pg.stale0000000000000000000", q: "", t: Date.now() - 200 * 1000, d: {} }));
	await ask(g0, "restore");
	assert.deepEqual(worldKeys(world), [], "an answer older than two minutes is swept at the start");
}

console.log("auth_flows_check: part 3 (oidc_popup, restore) ok");

// ------------------------------------------------------------------------------------------------------------------------
// 4. oidc_redirect: the whole page goes to Google and comes back
// ------------------------------------------------------------------------------------------------------------------------
const REDIRECT = { googleIos: "oidc_redirect" };
const paramsOf = (u) => Object.fromEntries(new URL(u).searchParams);
const mailboxKeys = (world) => [...world.ls.keys()].filter((k) => k.indexOf("glow_oidc_res:") === 0);
// a page of the game that taps the card and waits until the page is about to leave
async function leaving(o = {}) {
	const world = o.world || popupWorld(o.sc || {});
	const sdk = o.sdk || fakeSdk(o.sdkOpts || {});
	const g = game({ world, cfg: o.cfg || REDIRECT, sdk, ua: o.ua, standalone: o.standalone, test: { flushMs: 30, ...(o.test || {}) } });
	if (o.restore) await ask(g, "restore");
	const id = startCall(g, o.op || "sign_in_google", ["en"]);
	assert.ok(await waitFor(() => cards(g).length === 1), "the card");
	tapCard(g).click();
	return { world, sdk, g, id };
}

{
	// (a) the start: the card says where we go, the save gets its moment, then ONE navigation to Google with a state of our own
	const { world, g } = await leaving({ test: { flushMs: 150 } });
	assert.equal(tapCard(g).textContent, "Going to Google…");
	assert.equal(tapCard(g).disabled, true);
	assert.equal(g.navs.length, 0, "not at once: the game's last save reaches the browser's storage first");
	await sleep(60);
	assert.equal(g.navs.length, 0, "...but a moment later");
	assert.ok(await waitFor(() => g.navs.length === 1), "then the page leaves");
	await sleep(120);
	assert.equal(g.navs.length, 1, "once");
	const u = new URL(g.navs[0]);
	assert.equal(u.origin + u.pathname, "https://accounts.google.com/o/oauth2/v2/auth");
	const q = paramsOf(g.navs[0]);
	assert.deepEqual([q.client_id, q.redirect_uri, q.response_type, q.prompt], [CLIENT, RETURN_URL, "id_token token", "select_account"]);
	assert.match(q.state, /^rg\.[A-Za-z0-9_-]{24}$/, "r = the whole page, g = the game");
	assert.equal(world.google.length, 0, "no second window");
	const rec = JSON.parse(g.ssMap.get("glow_oidc_pend"));
	assert.deepEqual([rec.m, rec.op, rec.s === q.state, g.ssMap.get("glow_oidc_own") === q.state, sha256hex(rec.r) === q.nonce], ["r", "in", true, true, true], "the attempt and the marker are in this tab's storage before it leaves");
	assert.equal(JSON.parse(world.ls.get("glow_oidc_pend:" + q.state)).r, undefined, "the shared storage holds only the beacon: no raw nonce");
	// a page that is still here answers a ping: a window that did not start this never loads a second copy of the game
	const probe = makeWindow(world, { href: ORIGIN + "/game/auth_return.html" });
	const heard = [];
	const ch = new probe.BroadcastChannel("glow_oidc");
	ch.onmessage = (ev) => heard.push(ev.data);
	ch.postMessage({ k: "glow_oidc_ping", s: q.state });
	assert.ok(await waitFor(() => heard.length === 1));
	assert.deepEqual(heard[0], { k: "glow_oidc_pong", s: q.state });
}

{
	// (b) the whole page went; Google answers to the return page IN THAT WINDOW; the game loads again and finishes the sign-in
	const { world, g, id } = await leaving();
	assert.ok(await waitFor(() => g.navs.length === 1));
	const p = paramsOf(g.navs[0]);
	kill(g); // the page is gone: it left for Google
	const page = loadReturn(world, { href: RETURN_URL + "#" + answerFrag(p), from: g, opener: null, sc: { ua: IPHONE } });
	assert.ok(await waitFor(() => page.replaced.length === 1, 4000), "the return page sends the window back");
	assert.deepEqual(page.replaced, ["./"], "to the game, a fixed place");
	assert.equal(mailboxKeys(world).length, 1, "with the answer in the mailbox");
	const sdk2 = fakeSdk();
	const g2 = game({ world, ss: g.ssMap, cfg: REDIRECT, sdk: sdk2 });
	const r = await ask(g2, "restore");
	assert.deepEqual([r.ok, r.f.uid, r.f.ret, sdk2.calls], [true, "u2002", "ok", [["signInWithCredential", "A"]]], "the game signs the player in at its start");
	assert.deepEqual([oidcKeys(g2), notes(g2).length], [[], 0]);
	assert.ok((await ask(g2, "cloud_get")).ok, "and knows the account");
}

{
	// (c) the page is still alive when the answer arrives (a sheet over the app): it finishes the sign-in itself, and the
	// window that carried the answer is told to stay where it is, so there is never a second copy of the game
	const { world, sdk, g, id } = await leaving();
	assert.ok(await waitFor(() => g.navs.length === 1));
	const p = paramsOf(g.navs[0]);
	const sheet = makeWindow(world, { href: "https://accounts.google.com/chooser", ss: g.ssMap }); // a copy of this tab's storage, marker and all
	const page = loadReturn(world, { href: RETURN_URL + "#" + answerFrag(p), from: sheet, opener: null, sc: {} });
	const r = await waitLine(g, id);
	assert.deepEqual([r.ok, r.f.uid, sdk.calls], [true, "u2002", [["signInWithCredential", "A"]]]);
	await sleep(350);
	assert.deepEqual(page.replaced, [], "the sheet did not load the game over the live page");
	assert.deepEqual([cards(g).length, oidcKeys(g), stopped(g)], [0, [], true]);
}

{
	// (d) Back from Google (the page comes from the browser's cache, nothing runs again): nothing is coming; the card must not hang
	const { world, sdk, g, id } = await leaving();
	assert.ok(await waitFor(() => g.navs.length === 1));
	g.dispatch("pageshow", { persisted: true });
	const r = await waitLine(g, id);
	assert.deepEqual(lineOf(r), { ok: false, reason: "cancelled" }, "the player's own Back: silent");
	assert.deepEqual([cards(g).length, oidcKeys(g), stopped(g), sdk.calls.length, notes(g).length], [0, [], true, 0, 0]);
	const id3 = startCall(g, "sign_in_google", ["en"]);
	assert.ok(await waitFor(() => cards(g).length === 1), "and the page is free for the next try (not 'busy')");
	cancelCard(g).click();
	await waitLine(g, id3);
	// ... but when the answer IS there at that moment (Back after the return page ran), it is taken
	const b = await leaving();
	assert.ok(await waitFor(() => b.g.navs.length === 1));
	const sheet = makeWindow(b.world, { href: "https://accounts.google.com/chooser", ss: b.g.ssMap });
	loadReturn(b.world, { href: RETURN_URL + "#" + answerFrag(paramsOf(b.g.navs[0])), from: sheet, opener: null, sc: {} });
	b.g.dispatch("pageshow", { persisted: true });
	assert.equal((await waitLine(b.g, b.id)).ok, true);
}

{
	// (e) a fresh load with an attempt but no answer (the Back button after the cache was dropped): dropped, silently
	const { world, g } = await leaving();
	assert.ok(await waitFor(() => g.navs.length === 1));
	kill(g);
	const g2 = game({ world, ss: g.ssMap, cfg: REDIRECT, sdk: fakeSdk() });
	const r = await ask(g2, "restore");
	assert.deepEqual([r.ok, r.f.ret, notes(g2).length, oidcKeys(g2)], [true, "cancelled", 0, []]);
}

for (const [name, sc, ret, noted] of [
	["Cancel on Google's page", { error: "access_denied" }, "cancelled", false],
	["another error of Google's", { error: "invalid_request" }, "error", true],
	["a wrong nonce", { badNonce: true }, "error", true],
]) {
	const { world, g } = await leaving({ sc });
	assert.ok(await waitFor(() => g.navs.length === 1));
	kill(g);
	// the fake Google's own answer for this request: ask it like a window would
	const child = world.openFrom(g, g.navs[0], "x");
	await waitFor(() => child.page && child.page.replaced);
	const sdk2 = fakeSdk(), g2 = game({ world, ss: g.ssMap, cfg: REDIRECT, sdk: sdk2 });
	const r = await ask(g2, "restore");
	assert.deepEqual([name, r.ok, r.f.ret, sdk2.calls.length, notes(g2).length > 0], [name, true, ret, 0, noted]);
	assert.deepEqual(oidcKeys(g2), [], name);
}

{
	// (f) a link by the whole page: only for the account that asked
	for (const same of [true, false]) {
		const world = popupWorld(), s1 = fakeSdk({ current: pwUser("P1") });
		const g1 = game({ world, cfg: REDIRECT, sdk: s1, test: { flushMs: 30 } });
		await ask(g1, "restore");
		const id = startCall(g1, "link_google", ["en"]);
		assert.ok(await waitFor(() => cards(g1).length === 1));
		tapCard(g1).click();
		assert.ok(await waitFor(() => g1.navs.length === 1));
		assert.deepEqual([JSON.parse(g1.ssMap.get("glow_oidc_pend")).op, JSON.parse(g1.ssMap.get("glow_oidc_pend")).u], ["link", "P1"]);
		kill(g1);
		const sheet = makeWindow(world, { href: "https://accounts.google.com/chooser", ss: g1.ssMap });
		loadReturn(world, { href: RETURN_URL + "#" + answerFrag(paramsOf(g1.navs[0])), from: sheet, opener: null, sc: {} });
		assert.ok(await waitFor(() => mailboxKeys(world).length === 1));
		const s2 = fakeSdk({ current: pwUser(same ? "P1" : "P7") }), g2 = game({ world, ss: g1.ssMap, cfg: REDIRECT, sdk: s2 });
		const r = await ask(g2, "restore");
		if (same) assert.deepEqual([r.f.ret, r.f.google, s2.calls], ["linked", "1", [["linkWithCredential", "A"]]]);
		else assert.deepEqual([r.f.ret, s2.calls.length], ["error", 0]);
	}
}

{
	// (g) Cancel during the moment before the page leaves: it does not leave; the Home Screen app's record says so
	const { world, g, id } = await leaving({ test: { flushMs: 400 } });
	cancelCard(g).click();
	assert.deepEqual(lineOf(await waitLine(g, id)), { ok: false, reason: "popup_closed" });
	await sleep(500);
	assert.deepEqual([g.navs.length, oidcKeys(g), stopped(g)], [0, [], true], "the page stays; nothing is left behind");
	const h = await leaving({ ua: IPHONE_HOME, standalone: true, cfg: { googleIosHome: "oidc_redirect" } });
	assert.equal(JSON.parse(h.g.ssMap.get("glow_oidc_pend")).c, "home", "a Home Screen app's attempt is finished only in a Home Screen window");
	assert.ok(await waitFor(() => h.g.navs.length === 1));
	// a page that cannot leave says so
	const f = game({ world: popupWorld(), cfg: REDIRECT, sdk: fakeSdk(), test: { flushMs: 20 } });
	f.location.assign = () => { throw new Error("blocked"); };
	const id2 = startCall(f, "sign_in_google", ["en"]);
	assert.ok(await waitFor(() => cards(f).length === 1));
	tapCard(f).click();
	assert.deepEqual(lineOf(await waitLine(f, id2)), { ok: false, reason: "error" });
	assert.match(notes(f)[0].textContent, /^google glow\/oidc-assign /);
}

console.log("auth_flows_check: part 4 (oidc_redirect) ok");
process.exit(0);
