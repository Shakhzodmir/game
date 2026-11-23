// Checks the Google window handling of web/glow_auth.js with a tiny fake page and a fake Firebase SDK (no browser, no
// network): the tap card on iOS, the Home Screen app, the bounded waits, one request at a time, the in-app browser table.
//   node tools/qa/auth_gesture_check.mjs
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const SRC = fs.readFileSync(new URL("../../web/glow_auth.js", import.meta.url), "utf8");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const err = (code) => Object.assign(new Error(code), { code });

const IOS_SAFARI = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";
const IOS_HOME = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
const ANDROID = "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36";

function makeEnv({ nav = {}, test = {}, sdk, media = [] }) {
	const listeners = {};
	function el(tag) {
		const e = {
			tag, style: {}, children: [], _l: {}, textContent: "", parentNode: null,
			appendChild(c) { this.children.push(c); c.parentNode = this; return c; },
			removeChild(c) { const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); c.parentNode = null; return c; },
			addEventListener(t, f) { (this._l[t] = this._l[t] || []).push(f); },
			contains(x) { return x === this || this.children.some((c) => c.contains(x)); },
			focus() {}, click() { (this._l.click || []).forEach((f) => f({ target: this })); },
		};
		return e;
	}
	const body = el("body"), canvas = el("canvas");
	const document = { body, documentElement: { lang: "en" }, createElement: el, getElementById: (id) => (id === "canvas" ? canvas : null) };
	const navigator = { onLine: true, userAgent: ANDROID, language: "en", ...nav };
	const win = { GLOW_AUTH_CONFIG: { apiKey: "k", authDomain: "d", projectId: "p" }, localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
		addEventListener: (t, f) => { (listeners[t] = listeners[t] || []).push(f); }, console: { warn() {} } };
	if (media.length) win.matchMedia = (q) => ({ matches: media.some((k) => q === "(display-mode: " + k + ")") });
	win.window = win; win.document = document; win.navigator = navigator;
	win.glowAuth = { _test: { sdk: () => sdk, ...test } };
	vm.runInContext(SRC, vm.createContext({ window: win, document, navigator, localStorage: win.localStorage, console: win.console, Date, Promise,
		encodeURIComponent, JSON, Object, Error, RegExp, setTimeout, clearTimeout, Math, String }));
	const shielded = (type, target) => { let stop = false; for (const f of listeners[type] || []) f({ target, stopImmediatePropagation() { stop = true; } }); return stop; };
	const cards = () => body.children.filter((c) => c.style.cssText && /position:fixed/.test(c.style.cssText) && c.children.length);
	const notes = () => body.children.filter((c) => /^google /.test(c.textContent));
	return { win, body, cards, notes, shielded, call: (id, op, args = []) => win.glowAuth.call(id, op, args), poll: () => win.glowAuth.poll() };
}

function fakeSdk(signIn) {
	const user = { uid: "u1", email: "a@gmail.com", emailVerified: true, displayName: "A", providerData: [{ providerId: "google.com", email: "a@gmail.com" }] };
	const calls = { popup: 0 };
	return { calls, sdk: { m: {
		onAuthStateChanged: (a, cb) => { setTimeout(() => cb(null), 0); return () => {}; },
		signInWithPopup: () => { calls.popup++; return signIn(user, calls.popup); },
		linkWithPopup: () => { calls.popup++; return signIn(user, calls.popup); },
		GoogleAuthProvider: function () {},
	}, auth: { currentUser: user }, db: {} } };
}
function driftSdk(signIn, { first = null, google = true } = {}) {
	const user = { uid: "u2", email: "b@gmail.com", emailVerified: true, displayName: "B", providerData: google ? [{ providerId: "google.com", email: "b@gmail.com" }] : [] };
	const auth = { currentUser: first };
	const calls = { popup: 0 };
	return { calls, auth, user, sdk: { m: {
		onAuthStateChanged: (a, cb) => { setTimeout(() => cb(null), 0); return () => {}; },
		signInWithPopup: () => { calls.popup++; return signIn(user, auth, calls.popup); },
		linkWithPopup: () => { calls.popup++; return signIn(user, auth, calls.popup); },
		GoogleAuthProvider: function () {},
	}, auth, db: {} } };
}
const lineOf = (text) => { const [id, ok, reason] = text.split("\n")[0].split("|"); return { id: Number(id), ok: ok === "1", reason }; };
const tapCard = (env) => env.cards()[0].children[0].children[0]; // the green button
const cancelCard = (env) => env.cards()[0].children[0].children[1];

// 1. iPhone Safari tab: the card comes first, no window is attempted outside a tap; the tap opens it and signs in
{
	const f = fakeSdk((u) => Promise.resolve({ user: u }));
	const env = makeEnv({ nav: { userAgent: IOS_SAFARI }, sdk: f.sdk });
	assert.equal(env.call(1, "sign_in_google"), "ok");
	await sleep(20);
	assert.equal(env.cards().length, 1, "the tap card is up");
	assert.equal(f.calls.popup, 0, "nothing was opened outside a tap");
	assert.equal(env.shielded("touchend", tapCard(env)), true, "the game engine does not see taps on the card");
	tapCard(env).click();
	await sleep(20);
	assert.equal(f.calls.popup, 1);
	assert.equal(env.cards().length, 0, "the card goes when Google answered");
	assert.deepEqual({ ...lineOf(env.poll()) }, { id: 1, ok: true, reason: "" });
}

// 2. Android Chrome with a live tap: the window is tried at once; refused -> the card -> the tap works
{
	const f = fakeSdk((u, n) => (n === 1 ? Promise.reject(err("auth/popup-blocked")) : Promise.resolve({ user: u })));
	const env = makeEnv({ nav: { userActivation: { isActive: true } }, sdk: f.sdk });
	env.call(2, "sign_in_google");
	await sleep(20);
	assert.equal(f.calls.popup, 1, "tried at once");
	assert.equal(env.cards().length, 1, "refused: the card");
	tapCard(env).click();
	await sleep(20);
	assert.equal(lineOf(env.poll()).ok, true);
}

// 3. an iPhone Home Screen app whose Google window never reports back: waiting card, Cancel says so, a timeout says so
{
	const f = fakeSdk(() => new Promise(() => {}));
	const env = makeEnv({ nav: { userAgent: IOS_HOME, standalone: true }, test: { cancelLookMs: 15 }, sdk: f.sdk });
	env.call(3, "sign_in_google");
	await sleep(20);
	assert.equal(f.calls.popup, 0, "inside a Home Screen app too: the tap comes first");
	tapCard(env).click();
	await sleep(20);
	assert.equal(f.calls.popup, 1);
	assert.equal(env.cards().length, 1, "the card stays while Google's window is out");
	assert.match(tapCard(env).textContent, /Waiting for Google/);
	cancelCard(env).click();
	await sleep(80);
	const r = lineOf(env.poll());
	assert.deepEqual([r.ok, r.reason], [false, "home_app"], "not silent: the player is told what to do");
	assert.equal(env.notes().length, 1, "and the small diagnostic line is up");
	assert.match(env.notes()[0].textContent, /glow\/cancel-waiting ios-home .*v2026/, "our own Cancel is told apart from the SDK's \"closed\" in the line");
}
{
	const f = fakeSdk(() => new Promise(() => {}));
	const env = makeEnv({ nav: { userAgent: IOS_HOME, standalone: true }, test: { popupMs: 40, homeLookMs: 30 }, sdk: f.sdk });
	env.call(4, "sign_in_google");
	await sleep(20);
	tapCard(env).click();
	await sleep(250);
	const r = lineOf(env.poll());
	assert.deepEqual([r.ok, r.reason], [false, "home_app"], "a window that never answers ends by itself");
	assert.equal(env.cards().length, 0);
	// ... and the page is free again
	env.call(5, "sign_in_google");
	await sleep(20);
	assert.equal(env.cards().length, 1);
}

// 3b. a card nobody taps goes by itself as a plain "no", and the page is free again
{
	const f = fakeSdk(() => Promise.resolve({}));
	const env = makeEnv({ nav: { userAgent: IOS_SAFARI }, test: { popupMs: 40 }, sdk: f.sdk });
	env.call(12, "sign_in_google");
	await sleep(20);
	assert.equal(env.cards().length, 1);
	await sleep(100);
	assert.equal(env.cards().length, 0);
	assert.equal(lineOf(env.poll()).reason, "cancelled");
	assert.equal(f.calls.popup, 0);
}

// 4. a window that closed: not silent any more (it was "cancelled"); our own Cancel before the tap still is
{
	const f = fakeSdk(() => Promise.reject(err("auth/popup-closed-by-user")));
	const env = makeEnv({ sdk: f.sdk, nav: { userActivation: { isActive: true } }, test: { lookMs: 30 } });
	env.call(6, "sign_in_google");
	await sleep(150);
	assert.equal(lineOf(env.poll()).reason, "popup_closed");
	const g = fakeSdk(() => Promise.resolve({}));
	const env2 = makeEnv({ nav: { userAgent: IOS_SAFARI }, sdk: g.sdk });
	env2.call(7, "sign_in_google");
	await sleep(20);
	cancelCard(env2).click();
	await sleep(20);
	assert.equal(lineOf(env2.poll()).reason, "cancelled");
	assert.equal(env2.notes().length, 0, "no diagnostic line for something the player chose");
}

// 5. one request at a time: a second one while the card is up is refused, no second card
{
	const f = fakeSdk(() => Promise.reject(err("auth/popup-blocked")));
	const env = makeEnv({ nav: { userAgent: IOS_SAFARI }, sdk: f.sdk });
	env.call(8, "sign_in_google");
	env.call(9, "sign_in_google");
	await sleep(30);
	assert.equal(env.cards().length, 1);
	const r = lineOf(env.poll());
	assert.deepEqual([r.id, r.reason], [9, "busy"]);
}

// 6. the SDK files do not arrive: bounded, and said
{
	const env = makeEnv({ test: { sdkMs: 30 }, sdk: new Promise(() => {}) });
	env.win.glowAuth._test.sdk = () => new Promise(() => {});
	env.call(10, "sign_in_google");
	await sleep(100);
	assert.equal(lineOf(env.poll()).reason, "timeout");
	assert.match(env.notes()[0].textContent, /glow\/sdk-timeout/);
}

// 7. the account the player chose already belongs to another player
{
	const f = fakeSdk(() => Promise.reject(err("auth/credential-already-in-use")));
	const env = makeEnv({ nav: { userActivation: { isActive: true } }, sdk: f.sdk });
	env.call(11, "link_google");
	await sleep(30);
	assert.equal(lineOf(env.poll()).reason, "already_linked");
}

// 4b. the window closed, but the sign-in was being finished: the account is looked at again before "failed" is said
{
	const d = driftSdk((u, auth) => { setTimeout(() => { auth.currentUser = u; }, 120); return Promise.reject(err("auth/popup-closed-by-user")); });
	const env = makeEnv({ sdk: d.sdk, nav: { userActivation: { isActive: true } }, test: { lookMs: 600 } });
	env.call(20, "sign_in_google");
	await sleep(60);
	assert.equal(env.poll(), "", "nothing is said while the account is looked at");
	assert.equal(env.body.children.filter((c) => /Checking whether you signed in/.test(c.textContent)).length, 1, "a small line says it is being checked");
	await sleep(900);
	const out = env.poll();
	assert.deepEqual([lineOf(out).ok, /uid=u2/.test(out), /google=1/.test(out)], [true, true, true], "a late sign-in counts as a sign-in");
	assert.equal(env.notes().length, 0, "and no failure line");
	assert.equal(env.body.children.filter((c) => /Checking/.test(c.textContent)).length, 0, "the checking line is gone");
}
{
	// the player cancelled the waiting card (a Home Screen app that lost the window) but the sign-in had gone through
	const d = driftSdk((u, auth) => { setTimeout(() => { auth.currentUser = u; }, 10); return new Promise(() => {}); });
	const env = makeEnv({ sdk: d.sdk, nav: { userAgent: IOS_HOME, standalone: true }, test: { cancelLookMs: 300 } });
	env.call(21, "sign_in_google");
	await sleep(20);
	tapCard(env).click();
	await sleep(20);
	cancelCard(env).click();
	await sleep(500);
	assert.equal(lineOf(env.poll()).ok, true);
}
{
	// linking: Google appears on the current user while the window reports "closed"
	const base = { uid: "u9", email: "x@id.glow.invalid", emailVerified: false, displayName: "", providerData: [{ providerId: "password" }] };
	const d = driftSdk((u, auth) => { setTimeout(() => { base.providerData.push({ providerId: "google.com", email: "x@gmail.com" }); }, 80); return Promise.reject(err("auth/popup-closed-by-user")); }, { first: base });
	const env = makeEnv({ sdk: d.sdk, nav: { userActivation: { isActive: true } }, test: { lookMs: 600 } });
	env.call(22, "link_google");
	await sleep(700);
	const out = env.poll();
	assert.deepEqual([lineOf(out).ok, /google=1/.test(out)], [true, true]);
	// ... and a link that never happened is still a failure, after the look
	const base2 = { uid: "u8", email: "y@id.glow.invalid", emailVerified: false, displayName: "", providerData: [{ providerId: "password" }] };
	const d2 = driftSdk(() => Promise.reject(err("auth/popup-closed-by-user")), { first: base2 });
	const env2 = makeEnv({ sdk: d2.sdk, nav: { userActivation: { isActive: true } }, test: { lookMs: 40 } });
	env2.call(23, "link_google");
	await sleep(300);
	assert.equal(lineOf(env2.poll()).reason, "popup_closed");
}
{
	// a signed-in Google user who "signs in" again with a window that closes is not mistaken for a new sign-in
	const f = fakeSdk(() => Promise.reject(err("auth/popup-closed-by-user")));
	const env = makeEnv({ sdk: f.sdk, nav: { userActivation: { isActive: true } }, test: { lookMs: 30 } });
	env.call(24, "sign_in_google");
	await sleep(200);
	assert.equal(lineOf(env.poll()).reason, "popup_closed");
}

// 4c. a Home Screen app that only says so by the display-mode query (WebKit bug 264218: "fullscreen")
{
	const f = fakeSdk(() => new Promise(() => {}));
	const env = makeEnv({ nav: { userAgent: IOS_HOME }, media: ["fullscreen"], test: { popupMs: 40, homeLookMs: 20 }, sdk: f.sdk });
	env.call(25, "sign_in_google");
	await sleep(20);
	assert.equal(env.cards().length, 1, "not taken for an app's web view: the tap card, not the 'open in Safari' refusal");
	tapCard(env).click();
	await sleep(250);
	const r = lineOf(env.poll());
	assert.deepEqual([r.ok, r.reason], [false, "home_app"]);
	assert.match(env.notes()[0].textContent, /ios-home/);
}
{
	// the same UA without any sign of a Home Screen app is an app's web view
	const f = fakeSdk(() => new Promise(() => {}));
	const env = makeEnv({ nav: { userAgent: IOS_HOME }, sdk: f.sdk });
	env.call(26, "sign_in_google");
	await sleep(20);
	assert.equal(env.cards().length, 0);
	assert.equal(lineOf(env.poll()).reason, "inapp_browser");
}
{
	// the version in the diagnostic line is the one the page was asked for (web/engine_template.html carries it too)
	const f = fakeSdk(() => Promise.reject(err("auth/internal-error")));
	const env = makeEnv({ sdk: f.sdk, nav: { userActivation: { isActive: true } } });
	env.call(27, "sign_in_google");
	await sleep(30);
	assert.equal(lineOf(env.poll()).reason, "error");
	assert.match(env.notes()[0].textContent, /^google auth\/internal-error android-tab 0s v\d{4}-\d\d-\d\d[a-z]$/);
	assert.match(env.win.glowAuth.version, /^\d{4}-\d\d-\d\d[a-z]$/);
}

// 5b. the bounds the page really runs with (no test overrides), and the Home Screen app's own shorter one
{
	const f = fakeSdk(() => Promise.resolve({}));
	const env = makeEnv({ sdk: f.sdk });
	assert.deepEqual({ ...env.win.glowAuth.bounds }, { popup: 240000, homePopup: 90000, look: 5000, homeLook: 12000, cancelLook: 2000, waitCard: 10000, sdk: 30000 });
}
{
	const home = makeEnv({ nav: { userAgent: IOS_HOME, standalone: true }, test: { popupMs: 3000, homePopupMs: 60, homeLookMs: 30 }, sdk: fakeSdk(() => new Promise(() => {})).sdk });
	const tab = makeEnv({ nav: { userAgent: IOS_SAFARI }, test: { popupMs: 3000, homePopupMs: 60, homeLookMs: 30, lookMs: 30 }, sdk: fakeSdk(() => new Promise(() => {})).sdk });
	home.call(30, "sign_in_google");
	tab.call(31, "sign_in_google");
	await sleep(20);
	tapCard(home).click();
	tapCard(tab).click();
	await sleep(500);
	assert.equal(lineOf(home.poll()).reason, "home_app", "the Home Screen app ended at its own bound");
	assert.equal(tab.poll(), "", "an iOS Safari tab is still waiting: its bound is the long one");
	assert.equal(tab.cards().length, 1);
}

// 5c. a window we gave up on finishes later and switches the SDK's account: the bridge acts only for the account the game knows
{
	const P = { uid: "P1", email: "p@id.glow.invalid", emailVerified: false, displayName: "", providerData: [{ providerId: "password" }] };
	const G = { uid: "G1", email: "g@gmail.com", emailVerified: true, displayName: "G", providerData: [{ providerId: "google.com", email: "g@gmail.com" }] };
	const touched = [];
	const auth = { currentUser: P };
	const sdk = { m: {
		onAuthStateChanged: (a, cb) => { setTimeout(() => cb(auth.currentUser), 0); return () => {}; },
		doc: (db, c, id) => ({ path: c + "/" + id }),
		getDoc: async (ref) => { touched.push("get " + ref.path); return { exists: () => false, data: () => ({}) }; },
		setDoc: async (ref) => { touched.push("set " + ref.path); },
		deleteDoc: async (ref) => { touched.push("delete " + ref.path); },
		deleteUser: async (u) => { touched.push("deleteUser " + u.uid); },
		GoogleAuthProvider: function () {},
	}, auth, db: {} };
	const env = makeEnv({ sdk, nav: { userActivation: { isActive: true } } });
	env.call(40, "restore");
	await sleep(30);
	assert.match(env.poll(), /uid=P1/);
	env.call(41, "cloud_get");
	await sleep(30);
	assert.match(env.poll(), /^41\|1\|/, "the game's own account is read");
	auth.currentUser = G; // the window finished late: the SDK switched, nobody told the game
	env.call(42, "cloud_get");
	env.call(43, "cloud_put", ["GLOW1-X", ""]);
	env.call(44, "delete_account");
	await sleep(40);
	const out = env.poll().split("\n").filter(Boolean).map((l) => l.split("|").slice(0, 3).join("|"));
	assert.deepEqual(out.sort(), ["42|0|no_user", "43|0|no_user", "44|0|no_user"]);
	assert.deepEqual(touched, ["get saves/P1"], "nothing of the other account was read, written or deleted");
}

// 5d. linking for account P: a DIFFERENT Google user appearing during the look is somebody else's sign-in, not our link
{
	const base = { uid: "P2", email: "q@id.glow.invalid", emailVerified: false, displayName: "", providerData: [{ providerId: "password" }] };
	const other = { uid: "G2", email: "h@gmail.com", emailVerified: true, displayName: "H", providerData: [{ providerId: "google.com", email: "h@gmail.com" }] };
	const d = driftSdk(() => { setTimeout(() => { d.auth.currentUser = other; }, 50); return Promise.reject(err("auth/popup-closed-by-user")); }, { first: base });
	const env = makeEnv({ sdk: d.sdk, nav: { userActivation: { isActive: true } }, test: { lookMs: 250 } });
	env.call(45, "link_google");
	await sleep(500);
	const r = lineOf(env.poll());
	assert.deepEqual([r.ok, r.reason], [false, "popup_closed"], "not taken for a link");
}

// 5e. a window refused INSIDE the card's tap (a cold auth iframe on an iPad's Chrome, a slow link) keeps the card for one more tap
{
	const f = fakeSdk((u, n) => (n === 1 ? Promise.reject(err("auth/popup-blocked")) : Promise.resolve({ user: u })));
	const env = makeEnv({ nav: { userAgent: IOS_SAFARI }, sdk: f.sdk });
	env.call(46, "sign_in_google");
	await sleep(20);
	tapCard(env).click();
	await sleep(30);
	assert.equal(env.cards().length, 1, "the card stays after a refused window");
	assert.equal(tapCard(env).textContent, "Continue with Google");
	assert.equal(env.poll(), "");
	tapCard(env).click();
	await sleep(30);
	assert.equal(lineOf(env.poll()).ok, true);
	// only once: a second refusal ends as popup_blocked
	const g = fakeSdk(() => Promise.reject(err("auth/popup-blocked")));
	const env2 = makeEnv({ nav: { userAgent: IOS_SAFARI }, sdk: g.sdk });
	env2.call(47, "sign_in_google");
	await sleep(20);
	tapCard(env2).click();
	await sleep(30);
	tapCard(env2).click();
	await sleep(30);
	assert.equal(lineOf(env2.poll()).reason, "popup_blocked");
	assert.equal(env2.cards().length, 0);
}

// 5f. desktop / Android with a live tap: no card at first; a window unanswered for a while gets the waiting card with Cancel
{
	const f = fakeSdk(() => new Promise(() => {}));
	const env = makeEnv({ nav: { userActivation: { isActive: true } }, test: { waitCardMs: 250, cancelLookMs: 20 }, sdk: f.sdk });
	env.call(48, "sign_in_google");
	await sleep(40);
	assert.equal(f.calls.popup, 1, "opened at once");
	assert.equal(env.cards().length, 0, "no card yet");
	await sleep(400);
	assert.equal(env.cards().length, 1);
	assert.match(tapCard(env).textContent, /Waiting for Google/);
	assert.equal(tapCard(env).disabled, true);
	cancelCard(env).click();
	await sleep(150);
	assert.equal(lineOf(env.poll()).reason, "popup_closed");
	assert.equal(env.cards().length, 0);
	assert.match(env.notes()[0].textContent, /glow\/cancel-waiting android-tab/);
	env.call(49, "sign_in_google"); // the page is free again: not "busy"
	await sleep(15);
	assert.equal(f.calls.popup, 2);
	// a window that answers in time never shows the card
	const g = fakeSdk((u) => new Promise((r) => setTimeout(() => r({ user: u }), 10)));
	const env2 = makeEnv({ nav: { userActivation: { isActive: true } }, test: { waitCardMs: 500 }, sdk: g.sdk });
	env2.call(50, "sign_in_google");
	await sleep(150);
	assert.equal(lineOf(env2.poll()).ok, true);
	assert.equal(env2.cards().length, 0);
}

// 5g. a tap that is no longer alive on a non-iOS page: the card first, nothing opened outside a tap
{
	const f = fakeSdk(() => Promise.resolve({}));
	const env = makeEnv({ nav: { userActivation: { isActive: false } }, sdk: f.sdk });
	env.call(51, "sign_in_google");
	await sleep(20);
	assert.equal(env.cards().length, 1);
	assert.equal(f.calls.popup, 0);
}

// 5h. the card speaks the game's language (the game passes it with the call), else the device's; <html lang> is always "en"
{
	const f = fakeSdk(() => Promise.resolve({}));
	const env = makeEnv({ nav: { userAgent: IOS_SAFARI, language: "ko-KR" }, sdk: f.sdk });
	env.call(52, "sign_in_google", ["ru"]);
	await sleep(20);
	assert.equal(tapCard(env).textContent, "Продолжить с Google");
	assert.equal(cancelCard(env).textContent, "Отмена");
	const g = fakeSdk(() => Promise.resolve({}));
	const env2 = makeEnv({ nav: { userAgent: IOS_SAFARI, language: "ko-KR" }, sdk: g.sdk });
	env2.call(53, "sign_in_google", [""]);
	await sleep(20);
	assert.equal(tapCard(env2).textContent, "Google로 계속하기");
}

// 5i. Google was linked after the window was reported gone (a slow link): the second tap is not an error
{
	const base = { uid: "P3", email: "r@id.glow.invalid", emailVerified: false, displayName: "", providerData: [{ providerId: "password" }, { providerId: "google.com", email: "r@gmail.com" }] };
	const d = driftSdk(() => Promise.reject(err("auth/provider-already-linked")), { first: base });
	const env = makeEnv({ sdk: d.sdk, nav: { userActivation: { isActive: true } } });
	env.call(54, "link_google");
	await sleep(40);
	const out = env.poll();
	assert.deepEqual([lineOf(out).ok, /google=1/.test(out)], [true, true]);
}

// 5j. the page kind in the diagnostic line: "fullscreen" outside iOS is not a Home Screen app
{
	const f = fakeSdk(() => Promise.reject(err("auth/internal-error")));
	const env = makeEnv({ sdk: f.sdk, media: ["fullscreen"], nav: { userActivation: { isActive: true } } });
	env.call(55, "sign_in_google");
	await sleep(30);
	env.poll();
	assert.match(env.notes()[0].textContent, / android-full /);
}

// 8. which pages count as "inside another app" (a verdict is a sign-in that is refused before any window opens)
const BLOCKED = (ua, extra = {}) => {
	const f = fakeSdk(() => Promise.resolve({}));
	const env = makeEnv({ nav: { userAgent: ua, ...extra }, sdk: f.sdk });
	env.call(1, "sign_in_google");
	return sleep(15).then(() => /\|inapp_browser\|/.test(env.poll()));
};
const table = [
	["iPhone Safari", IOS_SAFARI, {}, false],
	["iPhone Home Screen app", IOS_HOME, { standalone: true }, false],
	["iPhone Chrome", IOS_SAFARI.replace("Version/26.0", "CriOS/130.0.6723.37"), {}, false],
	["iPhone Firefox", IOS_SAFARI.replace("Version/26.0", "FxiOS/132.0"), {}, false],
	["iPhone Edge", IOS_SAFARI.replace("Version/26.0", "EdgiOS/130.0.2849.52"), {}, false],
	["iPhone DuckDuckGo", IOS_SAFARI.replace("Safari/604.1", "DuckDuckGo/7 Safari/605.1.15"), {}, false],
	["iPad desktop-class Safari", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", { maxTouchPoints: 5 }, false],
	["a Mac (no touch screen)", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", { maxTouchPoints: 0 }, false],
	["iPad app web view (called a Mac)", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", { maxTouchPoints: 5 }, true],
	["iPhone app web view (Telegram, Kakao ...)", IOS_HOME, {}, true],
	["Android Chrome", ANDROID, {}, false],
	["Android web view", ANDROID.replace("SM-S918B)", "SM-S918B; wv)"), {}, true],
];
for (const [name, ua, extra, want] of table) assert.equal(await BLOCKED(ua, extra), want, name);

console.log("auth_gesture_check: ok");
