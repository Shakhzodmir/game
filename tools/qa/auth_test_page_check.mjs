// Runs the phone test page (web/auth_test.html, revision 2) in the fake browser of tools/qa/fake_world.mjs: no real browser, no
// network. The page script runs with the real web/glow_oidc.js, the real web/auth_return.html and a fake Google; Firebase is a
// fake SDK handed over through the page's own check hook (window.GLOW_DIAG_TEST) that applies the backend's nonce rule to the
// real tokens. It covers what the producer's phone run depends on and what text pins cannot see: tests 8 and 9 end to end, an
// attempt that ages from the TAP (a page open for a quarter of an hour), which page may finish an attempt (only the window that
// started it; a window opened from it holds a COPY of the record and must leave it alone), one exchange of one answer, what the
// RESULT line says the game's own code would have done (prod=), and that no token ever reaches the log.
//   node tools/qa/auth_test_page_check.mjs
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { read, scriptOf, sleep, RETURN_JS, CLIENT, ORIGIN, RETURN_URL, IPHONE, b64u, sha256hex, makeWorld, makeWindow, installGoogle, loadReturn } from "./fake_world.mjs";

const PAGE = read("web/auth_test.html");
const PAGE_JS = scriptOf(PAGE);
assert.ok(PAGE_JS && PAGE_JS.indexOf('var REV = "auth_test v2"') >= 0, "the page has its one inline script");

const err = (code) => Object.assign(new Error(code), { code });
const claimsOf = (token) => JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
const waitFor = async (fn, ms = 4000) => { const end = Date.now() + ms; while (Date.now() < end) { if (fn()) return true; await sleep(10); } return !!fn(); };
const nowS = () => Math.floor(Date.now() / 1000);
const jwt = (claims) => b64u(JSON.stringify({ alg: "RS256", kid: "k" })) + "." + b64u(JSON.stringify(claims)) + ".sig";
const TAB_MS = 60 * 1000;

// an answer of Google for the request p (its parameters), made by hand
function answerFrag(p, o = {}) {
	const claims = { iss: "https://accounts.google.com", aud: CLIENT, sub: "3003", email: "anna@gmail.com", iat: nowS(), exp: nowS() + 3600, nonce: p.nonce, ...(o.claims || {}) };
	const at = "ya29.fake-access-token";
	if (String(p.response_type).indexOf("token") >= 0) claims.at_hash = b64u(createHash("sha256").update(at).digest().subarray(0, 16));
	return "id_token=" + jwt(claims) + "&access_token=" + at + "&token_type=Bearer&expires_in=3599&state=" + p.state;
}

// the SDK of the page's check hook: the credentials of the three strategies, the backend's nonce rule for A. fail: {A|B|T: code}
function pageSdk(o = {}) {
	const calls = [];
	const rule = { A: "nonce", B: "ok", T: "ok", ...(o.rule || {}) };
	const OAuthProvider = function (id) { this.id = id; };
	OAuthProvider.prototype.credential = function (x) { return { kind: "A", idToken: x.idToken, rawNonce: x.rawNonce }; };
	const GoogleAuthProvider = function () { this.id = "google.com"; };
	GoogleAuthProvider.credential = (idToken, accessToken) => (idToken ? { kind: "B", idToken } : { kind: "T", accessToken });
	const auth = { currentUser: null };
	const m = {
		OAuthProvider, GoogleAuthProvider,
		getRedirectResult: async () => null,
		onAuthStateChanged: () => () => {},
		getAdditionalUserInfo: () => ({ isNewUser: false }),
		signOut: async () => { auth.currentUser = null; },
		signInWithCredential: async (a, cred) => {
			calls.push(cred.kind);
			if (o.fail && o.fail[cred.kind]) throw err(o.fail[cred.kind]);
			if (cred.kind === "A" && rule.A === "nonce" && sha256hex(cred.rawNonce) !== claimsOf(cred.idToken).nonce) throw err("auth/missing-or-invalid-nonce");
			await sleep(o.exchangeMs || 1);
			const user = { uid: "uid-0001abcdef", email: "anna@gmail.com", metadata: { creationTime: "2026-01-01T00:00:00Z" } };
			auth.currentUser = user;
			return { user };
		},
	};
	return { calls, m, auth };
}

// a page of the fake browser: the DOM pieces the script touches, a clock that can run ahead, timers that can be stopped
function mkEl(id) {
	return { id, hidden: false, disabled: false, textContent: "", innerHTML: "", className: "", value: "", style: {}, children: [], _l: {}, attrs: {},
		addEventListener(t, f) { (this._l[t] = this._l[t] || []).push(f); }, removeEventListener() {},
		click() { if (this.disabled) return; for (const f of (this._l.click || []).slice()) f({ target: this }); },
		appendChild(c) { this.children.push(c); return c; }, getAttribute(n) { return this.attrs[n] === undefined ? null : this.attrs[n]; }, setAttribute(n, v) { this.attrs[n] = v; },
		scrollIntoView() {}, focus() {}, select() {} };
}
const BUTTONS = ["b0a", "b0b", "b0c", "b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8", "b9", "b10s", "b10p", "b10r"];
const fakeDate = (clock) => { // a Date whose "now" runs clock.offset ms ahead (the page is open for a quarter of an hour)
	const RD = Date;
	function FD(...a) { return a.length ? new RD(...a) : new RD(RD.now() + clock.offset); }
	FD.now = () => RD.now() + clock.offset; FD.parse = RD.parse; FD.UTC = RD.UTC; FD.prototype = RD.prototype;
	return FD;
};
function testPage({ world, ss, offset = 0, sdk, hook = {}, search = "" }) {
	const win = makeWindow(world, { href: ORIGIN + "/game/auth_test.html" + search, core: true, ss, ua: IPHONE });
	win.clock = { offset };
	win.timers = []; win.timeouts = [];
	win.sdk = sdk || pageSdk();
	win.GLOW_AUTH_CONFIG = { apiKey: "k", authDomain: "d", projectId: "p", appId: "a", googleClientId: CLIENT, googleReturn: RETURN_URL, googleIos: "firebase", googleIosHome: "firebase" };
	win.GLOW_DIAG_TEST = { sdk: () => win.sdk, ...hook };
	const els = {}, el = (id) => els[id] || (els[id] = mkEl(id));
	win.el = el;
	const doc = win.document;
	doc.getElementById = el;
	doc.createElement = (tag) => mkEl(tag);
	doc.createTextNode = (text) => ({ text });
	doc.querySelectorAll = (sel) => (sel === ".tbtn" ? BUTTONS.map(el) : sel === "#appchips button" ? ["safari", "private", "chrome", "tg", "home"].map((a) => { const c = mkEl("chip-" + a); c.attrs["data-app"] = a; return c; }) : []);
	doc.querySelector = () => null;
	doc.referrer = "";
	const ctx = win.ctx;
	ctx.Date = fakeDate(win.clock); ctx.URL = URL;
	ctx.screen = { width: 390, height: 844 }; ctx.innerWidth = 390; ctx.innerHeight = 700; ctx.matchMedia = win.matchMedia;
	ctx.setInterval = (fn, ms) => { const h = setInterval(fn, ms); win.timers.push(h); return h; };
	ctx.setTimeout = (fn, ms, ...a) => { const h = setTimeout(fn, ms, ...a); win.timeouts.push(h); return h; };
	win.run(PAGE_JS);
	return win;
}
function kill(win) { // the page is gone for good: no timer, no listener, no delivery (a tab that iOS discarded, a page the browser left)
	win.timers.forEach((h) => clearInterval(h)); win.timeouts.forEach((h) => clearTimeout(h));
	win._l = {}; win._docl = {}; win.gone = true;
}
// the return page of a whole-page sign-in: it loads in the same tab (the starter's storage), on the same clock as the pages around it
function returnPage(world, { href, from, opener = null, offset = 0 }) {
	const win = makeWindow(world, { href, ss: from.ssMap, opener, ua: IPHONE, hl: 3 });
	win.ctx.Date = fakeDate({ offset });
	win.ctx.setTimeout = (f, ms) => setTimeout(f, ms * 0.2); win.ctx.setInterval = (f, ms) => setInterval(f, Math.max(5, ms * 0.2));
	win.run(RETURN_JS);
	return win;
}
const logOf = (world) => [...world.ls.keys()].filter((k) => k.indexOf("glow_diag_log_") === 0).sort((a, b) => Number(a.slice(14)) - Number(b.slice(14))).flatMap((k) => JSON.parse(world.ls.get(k)));
const resultsOf = (world, n, load) => logOf(world).filter((l) => new RegExp("^\\[" + (load || "\\d+") + "\\] [\\d.]+ s  (\\[(OK|ОШИБКА)\\] )?RESULT T" + n + " ").test(l));
const field = (line, key) => { const m = new RegExp(" " + key.replace(/\./g, "\\.") + "=(\\S+)").exec(line); return m ? m[1] : null; };
const ready = (win, id) => waitFor(() => win.el(id).disabled === false, 6000);
const nTokens = (text) => /eyJ[A-Za-z0-9_-]{6,}\.|ya29\.|id_token=|access_token=/.test(text);
const paramsOfUrl = (u) => Object.fromEntries(new URL(u).searchParams);
const mailKeys = (world) => [...world.ls.keys()].filter((k) => k.indexOf("glow_oidc_t_res:") === 0);
const OPEN = { delay: 25 };

// ---- 1. test 8, the whole loop: the window, the fake Google, the return page, the exchange; prod= says what the game would have done
{
	const world = makeWorld(); installGoogle(world, OPEN);
	const page = testPage({ world });
	assert.ok(await ready(page, "b8"), "test 8 is ready once the SDK and the secrets are");
	page.el("b8").click();
	assert.equal(world.google.length, 1, "one window.open in the tap");
	assert.ok(await waitFor(() => resultsOf(world, 8).length === 1, 8000), "test 8 ends with a RESULT line");
	const line = resultsOf(world, 8)[0];
	assert.equal(field(line, "ok"), "1", line);
	assert.deepEqual([field(line, "cred"), field(line, "A"), field(line, "prod"), field(line, "open")], ["A", "ok", "A", "win"], "A signed in, and A is what the game's own code would have used");
	assert.deepEqual(page.sdk.calls, ["A"]);
	assert.ok(logOf(world).every((l) => !nTokens(l)), "no token reaches the log");
	assert.deepEqual(mailKeys(world), [], "single use");
	kill(page);
}

// ---- 2. prod=: a green test is no proof for the game unless the game's own policy (A; T only after a refusal for the nonce AND with
// an access token the id_token vouches for) would have signed in too
for (const [name, sdkOpts, sc, wantCred, wantProd] of [
	["A signs in", {}, OPEN, "A", "A"],
	["the nonce refused, the access token vouched for: the game would use T after A", { fail: { A: "auth/missing-or-invalid-nonce" } }, OPEN, "T", "AT"],
	["A refused for another reason: the test goes on to T, the game would not", { fail: { A: "auth/invalid-credential" } }, OPEN, "T", "none"],
	["the nonce refused and no at_hash: the test tries T, the game would not", { fail: { A: "auth/missing-or-invalid-nonce" } }, { ...OPEN, noAtHash: true }, "T", "none"],
]) {
	const world = makeWorld(); installGoogle(world, sc);
	const page = testPage({ world, sdk: pageSdk(sdkOpts) });
	assert.ok(await ready(page, "b8"));
	page.el("b8").click();
	assert.ok(await waitFor(() => resultsOf(world, 8).length === 1, 8000), name);
	const line = resultsOf(world, 8)[0];
	assert.deepEqual([name, field(line, "ok"), field(line, "cred"), field(line, "prod")], [name, "1", wantCred, wantProd], line);
	kill(page);
}

// ---- 3. test 9 after a page that was open for a quarter of an hour: the attempt ages from the tap, so the way back does not sweep it
for (const stale of [false, true]) {
	const world = makeWorld();
	const w1 = testPage({ world });
	assert.ok(await ready(w1, "b9"));
	if (stale) w1.clock.offset = 16 * 60 * 1000; // the player taps 16 minutes after the page loaded (its secrets were made at load)
	w1.el("b9").click();
	assert.equal(w1.navs.length, 1, "the page leaves for Google");
	const p = paramsOfUrl(w1.navs[0]);
	assert.match(p.state, /^rt\./, "r = the whole page, t = the test page");
	kill(w1); // the page is gone: Google comes back to the same window
	const back = returnPage(world, { href: RETURN_URL + "#" + answerFrag(p), from: w1, offset: w1.clock.offset });
	assert.ok(await waitFor(() => back.replaced.length === 1, 4000), "the return page goes back to the test page");
	assert.deepEqual(back.replaced, ["auth_test.html"]);
	const w2 = testPage({ world, ss: back.ssMap, offset: stale ? 16 * 60 * 1000 + 1000 : 1000 }); // the same tab, a new load
	assert.ok(await waitFor(() => resultsOf(world, 9).length === 1, 8000), "test 9 ends with a RESULT line (stale=" + stale + "): " + logOf(world).filter((l) => /RESULT|nopend/.test(l)).join(" // "));
	const line = resultsOf(world, 9)[0];
	assert.deepEqual([field(line, "ok"), field(line, "starter"), field(line, "src"), field(line, "prod")], ["1", "1", "ss", "A"], "stale=" + stale + ": " + line);
	assert.deepEqual(w2.sdk.calls, ["A"]);
	kill(w2);
}

// ---- 3b. test 8 the same way: the starter tab is discarded while Google's window is open, the player taps 16 minutes after the load
{
	const world = makeWorld(); installGoogle(world, { stay: true });
	const w1 = testPage({ world });
	assert.ok(await ready(w1, "b8"));
	w1.clock.offset = 16 * 60 * 1000;
	w1.el("b8").click();
	const p = world.google[0].params, child = world.pages[0];
	kill(w1);
	returnPage(world, { href: RETURN_URL + "#" + answerFrag(p), from: child, opener: w1, offset: w1.clock.offset }); // Google's window answers
	assert.ok(await waitFor(() => mailKeys(world).length === 1, 4000));
	const w2 = testPage({ world, ss: w1.ssMap, offset: w1.clock.offset + 1000 }); // the starter's tab, reloaded
	assert.ok(await waitFor(() => resultsOf(world, 8).length === 1, 8000), logOf(world).filter((l) => /RESULT|nopend|expired/.test(l)).join(" // "));
	const line = resultsOf(world, 8)[0];
	assert.deepEqual([field(line, "ok"), field(line, "resumed"), field(line, "cred"), field(line, "prod")], ["1", "load", "A", "A"], line);
	assert.deepEqual(w2.sdk.calls, ["A"]);
	kill(w2);
}

// ---- 4. a window opened from the starter holds a COPY of its record but not its marker: it must leave the attempt alone
{
	const world = makeWorld(); installGoogle(world, { stay: true });
	const w1 = testPage({ world });
	assert.ok(await ready(w1, "b8"));
	w1.el("b8").click();
	const p = world.google[0].params, child = world.pages[0];
	assert.ok(child.ssMap.has("glow_oidc_t_pend") && !child.ssMap.has("glow_oidc_t_own"), "the pop-up has the record, not the marker");
	kill(w1); // the starter sleeps (a tab in the background): it cannot take the answer now
	const back = loadReturn(world, { href: RETURN_URL + "#" + answerFrag(p), from: child, opener: w1, sc: { refuseClose: true } }); // Google answers; the window will not close
	assert.ok(await waitFor(() => !back.document.getElementById("b").hidden, 6000), "the window that cannot close offers the way back to the test page");
	assert.equal(mailKeys(world).length, 1, "the answer waits in the mailbox");
	back.document.getElementById("b").click(); // the player taps it
	assert.deepEqual(back.replaced, ["auth_test.html"]);
	const w2 = testPage({ world, ss: back.ssMap }); // the pop-up's tab now runs the test page
	await sleep(1800);
	assert.deepEqual(w2.sdk.calls, [], "the copy does not exchange the answer");
	assert.equal(resultsOf(world, 8).length, 0, "and prints no result of its own");
	assert.equal(mailKeys(world).length, 1, "the answer is still there for the starter");
	assert.ok(logOf(world).some((l) => /копия попытки другого окна/.test(l)), "the page says why it did not touch it");
	assert.equal(JSON.parse(w1.ssMap.get("glow_oidc_t_pend")).cl, undefined, "nobody claimed it");
	kill(w2);
	// the starter's own tab, reloaded (a page iOS discarded): it has the marker, so it finishes the sign-in
	const w3 = testPage({ world, ss: w1.ssMap });
	assert.ok(await waitFor(() => resultsOf(world, 8).length === 1, 8000));
	const line = resultsOf(world, 8)[0];
	assert.deepEqual([field(line, "ok"), field(line, "resumed"), field(line, "cred")], ["1", "load", "A"], line);
	assert.deepEqual(w3.sdk.calls, ["A"]);
	assert.deepEqual(mailKeys(world), [], "single use");
	kill(w3);
}

// ---- 4b. the same copy, loaded BEFORE the answer: it does not start a bogus "waiting after a reload" run that would lock the page
{
	const world = makeWorld(); installGoogle(world, { stay: true });
	const w1 = testPage({ world });
	assert.ok(await ready(w1, "b8"));
	w1.el("b8").click();
	const child = world.pages[0];
	kill(w1);
	const w2 = testPage({ world, ss: child.ssMap }); // the pop-up's tab, now the test page
	assert.ok(await ready(w2, "b8"), "the page is not locked by a run of an attempt that is not its own");
	assert.equal(logOf(world).filter((l) => /ожидание ответа после перезагрузки/.test(l)).length, 0, "no resumed run");
	assert.ok(logOf(world).some((l) => /копия попытки другого окна/.test(l)));
	assert.ok(w2.ssMap.has("glow_oidc_t_pend"), "the copy is left as it is");
	kill(w2);
}

// ---- 5. one answer, one exchange: a page whose attempt another page has already claimed does not exchange it, and says so
{
	const world = makeWorld(); installGoogle(world, { stay: true });
	const w1 = testPage({ world });
	assert.ok(await ready(w1, "b8"));
	w1.el("b8").click();
	const p = world.google[0].params, child = world.pages[0];
	const rec = JSON.parse(w1.ssMap.get("glow_oidc_t_pend"));
	rec.cl = { t: Date.now(), by: "another-page" }; // another page of the same attempt is on it
	w1.ssMap.set("glow_oidc_t_pend", JSON.stringify(rec));
	loadReturn(world, { href: RETURN_URL + "#" + answerFrag(p), from: child, opener: w1, sc: {} });
	assert.ok(await waitFor(() => resultsOf(world, 8).length === 1, 8000));
	const line = resultsOf(world, 8)[0];
	assert.deepEqual([field(line, "ok"), field(line, "why")], ["0", "claimed_elsewhere"], line);
	assert.deepEqual(w1.sdk.calls, [], "no second exchange of the same answer");
	assert.ok(mailKeys(world).length === 1 && w1.ssMap.has("glow_oidc_t_pend"), "and nothing of the other page's attempt is deleted by this one");
	kill(w1);
}

console.log("auth_test_page_check: ok");
process.exit(0);
