// Checks our own sign-in with Google (web/glow_oidc.js, web/auth_return.html, the inline script of web/auth_test.html) in
// a small fake browser (no real browser, no network): the request, the answer checks, the three hand-over channels, the
// return page in every state it can meet, and the whole loop with a fake Google and a fake Firebase SDK.
//   node tools/qa/auth_oidc_check.mjs
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";
import { createHash, webcrypto } from "node:crypto";

const read = (p) => fs.readFileSync(new URL("../../" + p, import.meta.url), "utf8");
const CORE = read("web/glow_oidc.js");
const RETURN_HTML = read("web/auth_return.html");
const TEST_HTML = read("web/auth_test.html");
const scriptOf = (html) => (html.match(/<script>([\s\S]*?)<\/script>/) || [])[1];
const RETURN_JS = scriptOf(RETURN_HTML);
assert.ok(RETURN_JS, "the return page has one inline script");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const json = (x) => JSON.parse(JSON.stringify(x)); // a plain main-realm copy (objects made inside a vm context have another prototype)
const CLIENT = "956973883845-ct7e77188vteg5edv7m3sgp8j8iptd5r.apps.googleusercontent.com";
const ORIGIN = "https://shakhzodmir.github.io";
const RETURN_URL = ORIGIN + "/game/auth_return.html";
const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2.1 Mobile/24B156 Safari/604.1";
const b64u = (buf) => Buffer.from(buf).toString("base64url");
const sha256hex = (s) => createHash("sha256").update(s).digest("hex");

// ------------------------------------------------------------------------------------------------------------------------
// the fake browser: windows with their own sessionStorage, ONE shared localStorage and BroadcastChannel bus per origin,
// window.open that copies sessionStorage at open time, postMessage with origin and source, a fake Google that redirects.
// ------------------------------------------------------------------------------------------------------------------------
function makeWorld() {
	const world = { ls: new Map(), bus: new Map(), windows: [], blocked: [], google: [], clock: () => Date.now() };
	const deliver = (win, type, ev) => setTimeout(() => (win._l[type] || []).slice().forEach((f) => { try { f(ev); } catch (e) { world.errors.push(e); } }), 0);
	world.errors = [];
	world.notifyStorage = (writer, key, newValue) => {
		for (const w of world.windows) if (w !== writer && !w.gone) deliver(w, "storage", { type: "storage", key, newValue, origin: ORIGIN });
	};
	world.bcDeliver = (from, name, data) => {
		for (const ch of world.bus.get(name) || []) if (ch !== from && !ch.closed && ch.win && !ch.win.gone) setTimeout(() => { try { if (!ch.closed && ch.onmessage) ch.onmessage({ data: json(data) }); } catch (e) { world.errors.push(e); } }, 0);
	};
	return world;
}

// a Storage over a Map (the local one is shared, and tells the other windows through "storage" events)
function makeStorage(map, onChange) {
	return {
		get length() { return map.size; },
		key: (i) => (i < map.size ? [...map.keys()][i] : null),
		getItem: (k) => (map.has(String(k)) ? map.get(String(k)) : null),
		setItem: (k, v) => { map.set(String(k), String(v)); if (onChange) onChange(String(k), String(v)); },
		removeItem: (k) => { const had = map.has(String(k)); map.delete(String(k)); if (had && onChange) onChange(String(k), null); },
	};
}

// opts: href, ss (Map to copy), opener (a window), sever, noBC, noLocalStorage, lang, standalone, ua, script (source to run), core (bool), visible
function makeWindow(world, opts) {
	const o = { lang: "en", ua: IPHONE, core: false, visible: true, ...opts };
	const url = new URL(o.href);
	const win = { _l: {}, _docl: {}, gone: false, closedFlag: false, navs: [], replaced: [], posted: [], errors: [], closeCalls: 0, severed: !!o.sever };
	const ssMap = new Map(o.ss ? [...o.ss] : []);
	win.ssMap = ssMap;
	const doc = {
		hidden: !o.visible, visibilityState: o.visible ? "visible" : "hidden", documentElement: { textContent: "lang-root" },
		_els: {},
		getElementById(id) {
			return this._els[id] || (this._els[id] = { id, textContent: "", hidden: id === "b", _l: {}, addEventListener(t, f) { (this._l[t] = this._l[t] || []).push(f); }, click() { (this._l.click || []).forEach((f) => f({})); } });
		},
		addEventListener(t, f) { (win._docl[t] = win._docl[t] || []).push(f); },
		removeEventListener(t, f) { win._docl[t] = (win._docl[t] || []).filter((x) => x !== f); },
	};
	win.document = doc;
	const loc = { href: o.href, origin: url.origin, pathname: url.pathname, search: url.search, hash: url.hash,
		replace(u) { win.navs.push(String(u)); win.replaced.push(String(u)); }, assign(u) { win.navs.push(String(u)); } };
	win.location = loc;
	win.history = { length: o.hl || 2, calls: [], replaceState(a, b, u) { this.calls.push({ url: u, hashBefore: loc.hash, searchBefore: loc.search, at: win.posted.length }); loc.hash = ""; loc.search = ""; } };
	win.navigator = { language: o.lang, userAgent: o.ua, maxTouchPoints: 5 };
	if (o.standalone !== undefined) win.navigator.standalone = o.standalone;
	win.matchMedia = (q) => ({ matches: q === "(display-mode: " + (o.dm || "browser") + ")" });
	win.localStorage = o.noLocalStorage ? { get length() { throw new Error("blocked"); }, getItem() { throw new Error("blocked"); }, setItem() { throw new Error("blocked"); }, removeItem() { throw new Error("blocked"); }, key() { throw new Error("blocked"); } }
		: makeStorage(world.ls, (k, v) => world.notifyStorage(win, k, v));
	win.sessionStorage = makeStorage(ssMap, null);
	win.addEventListener = (t, f) => { (win._l[t] = win._l[t] || []).push(f); };
	win.removeEventListener = (t, f) => { win._l[t] = (win._l[t] || []).filter((x) => x !== f); };
	win.dispatch = (t, ev) => (win._l[t] || []).slice().forEach((f) => f(ev));
	win.dispatchDoc = (t, ev) => (win._docl[t] || []).slice().forEach((f) => f(ev));
	win.window = win; win.self = win; win.top = o.framed ? { not: "us" } : win;
	win.opener = o.opener ? { postMessage: (data, target) => o.opener._receive(data, target, win.handle, ORIGIN) } : null;
	win.crypto = webcrypto;
	if (!o.noBC) {
		win.BroadcastChannel = class {
			constructor(name) { this.name = name; this.win = win; this.closed = false; this.onmessage = null; (world.bus.get(name) || world.bus.set(name, new Set()).get(name)).add(this); }
			postMessage(data) { if (this.closed) throw new Error("closed channel"); win.posted.push({ bc: this.name, data }); world.bcDeliver(this, this.name, data); }
			close() { this.closed = true; }
		};
	}
	// what other windows see of this one (window.open returns it)
	win.handle = {
		get closed() { return win.closedFlag || win.severed; },
		close() { win.closeCalls++; if (!o.refuseClose) { win.closedFlag = true; win.gone = true; } },
		focus() {},
		postMessage(data, target) { win._receive(data, target, o.opener ? o.opener.handle : null, o.opener ? ORIGIN : ORIGIN); },
	};
	win.close = win.handle.close;
	win._receive = (data, target, source, origin) => {
		if (target !== "*" && target !== url.origin) { world.blocked.push({ target, to: url.origin }); return; }
		deliver(win, "message", { type: "message", data: json(data), origin: origin || ORIGIN, source });
	};
	win.open = (u, name) => {
		if (win.openBlocked) return null;
		const child = world.openFrom(win, u, name);
		return child ? child.handle : null;
	};
	win.setTimeout = setTimeout; win.clearTimeout = clearTimeout; win.setInterval = setInterval; win.clearInterval = clearInterval;
	world.windows.push(win);
	// the script context
	const ctx = vm.createContext({ window: win, document: doc, location: loc, history: win.history, navigator: win.navigator,
		BroadcastChannel: win.BroadcastChannel, setTimeout, clearTimeout, setInterval, clearInterval, console });
	win.ctx = ctx;
	win.run = (src) => vm.runInContext(src, ctx);
	if (o.core) vm.runInContext(CORE, ctx);
	return win;
}

// the fake Google: world.openFrom(openerWindow, url) is what window.open does; the destination page loads after a short
// "account chooser" delay and is the return page with the answer in the fragment (or an error), like the real redirect.
function installGoogle(world, scenario) {
	world.scenario = { delay: 25, ...scenario };
	world.pages = [];
	const answerFragment = (q) => {
		const s = world.scenario, now = Math.floor(Date.now() / 1000);
		const state = q.get("state") + (s.badState ? "X" : "");
		if (s.error) return "error=" + s.error + "&state=" + state;
		const claims = { iss: "https://accounts.google.com", aud: CLIENT, sub: "1001", email: "anna@gmail.com", name: "Анна", iat: now, exp: now + 3600, nonce: s.badNonce ? "zzz" : q.get("nonce"), ...(s.claims || {}) };
		const at = "ya29.fake-access-token";
		if (!s.noAtHash && String(q.get("response_type")).indexOf("token") >= 0) claims.at_hash = b64u(createHash("sha256").update(s.badAccess ? "other" : at).digest().subarray(0, 16));
		const idToken = b64u(JSON.stringify({ alg: "RS256", kid: "k" })) + "." + b64u(JSON.stringify(claims)) + ".sig";
		let f = "state=" + state;
		if (String(q.get("response_type")).indexOf("id_token") >= 0 && !s.noIdToken) f = "id_token=" + idToken + "&" + f;
		if (String(q.get("response_type")).indexOf("token") >= 0 && !s.noAccess && !(q.get("response_type") === "id_token")) f = "access_token=" + at + "&token_type=Bearer&expires_in=3599&" + f;
		return f;
	};
	world.openFrom = (opener, rawUrl, name) => {
		const u = new URL(rawUrl);
		world.google.push({ url: rawUrl, name, params: Object.fromEntries(u.searchParams) });
		const redirect = u.searchParams.get("redirect_uri");
		const sc = world.scenario;
		const child = makeWindow(world, { href: "https://accounts.google.com/chooser", opener: opener, sever: sc.sever, ss: opener.ssMap, noBC: false, lang: sc.lang || "en", standalone: sc.standalone, refuseClose: sc.refuseClose });
		child.gone = false;
		child.stage = "google";
		if (sc.sever) child.window.opener = null; // severed link: the page we land on has no opener
		world.pages.push(child);
		if (sc.stay) return child; // the window just sits on Google's page
		setTimeout(() => {
			if (child.gone) return;
			const frag = sc.noFragment ? "" : "#" + answerFragment(u.searchParams);
			const page = loadReturn(world, { href: redirect + frag, from: child, opener, sc });
			child.page = page;
		}, sc.delay);
		return child;
	};
}

// loads auth_return.html into the window `from` (a popup window or a starter's own window)
function loadReturn(world, { href, from, opener, sc = {} }) {
	const win = makeWindow(world, { href, ss: from.ssMap, opener: sc.sever ? null : opener, sever: false, noBC: sc.noBCReturn, lang: sc.lang || "en", standalone: sc.standalone, ua: sc.ua || IPHONE,
		hl: 3, refuseClose: sc.refuseClose, dm: sc.dm, noLocalStorage: sc.noLocalStorageReturn });
	// the page lives in the same window object the opener holds a handle to
	win.handle = from.handle;
	from.gone = true; from.closedFlag = false;
	win.handle.close = () => { win.closeCalls++; if (!sc.refuseClose) { win.closedFlag = true; win.gone = true; from.closedFlag = true; } };
	Object.defineProperty(from.handle, "closed", { configurable: true, get: () => win.closedFlag || from.closedFlag || !!sc.sever });
	win.close = win.handle.close;
	win.gone = false;
	if (sc.noOpenerPost) win.opener = null;
	win.run(RETURN_JS);
	return win;
}

// ------------------------------------------------------------------------------------------------------------------------
// the core in a fake window
// ------------------------------------------------------------------------------------------------------------------------
function coreWorld(optsWindow = {}) {
	const world = makeWorld();
	const win = makeWindow(world, { href: ORIGIN + "/game/auth_test.html", core: true, ...optsWindow });
	return { world, win, G: win.window.glowOidc };
}
function jwt(claims, header = { alg: "RS256", kid: "k" }) { return b64u(JSON.stringify(header)) + "." + b64u(JSON.stringify(claims)) + ".sig"; }
const nowS = () => Math.floor(Date.now() / 1000);
function goodClaims(n, extra = {}) { return { iss: "https://accounts.google.com", aud: CLIENT, sub: "1", iat: nowS(), exp: nowS() + 3600, nonce: n, ...extra }; }

// 1. prepare / authUrl / parse ------------------------------------------------------------------------------------------
{
	const { G, win } = coreWorld();
	assert.match(G.version, /^\d{4}-\d\d-\d\d[a-z]$/, "the core says its version (the ?v= of the <script> tags must match it)");
	const a = json(await G.prepare({ dest: "t", mode: "p" })), b = json(await G.prepare({ dest: "t", mode: "p" }));
	assert.match(a.s, /^pt\.[A-Za-z0-9_-]{24}$/);
	assert.match(a.r, /^[A-Za-z0-9_-]{43}$/, "32 random bytes, base64url");
	assert.equal(a.n, sha256hex(a.r), "the nonce Google sees is the sha256 (hex) of the raw nonce that stays here");
	assert.notEqual(a.s, b.s); assert.notEqual(a.r, b.r);
	assert.deepEqual([a.v, a.m, a.d, a.rt, typeof a.t], [1, "p", "t", "id_token token", "number"]);
	const r = json(await G.prepare({ dest: "g", mode: "r", responseType: "id_token" }));
	assert.match(r.s, /^rg\./); assert.equal(r.rt, "id_token");
	await assert.rejects(() => G.prepare({ dest: "t", mode: "p", crypto: {} }), (e) => e.code === "glow/oidc-nocrypto", "no crypto.subtle: a clear code");
	assert.deepEqual(json(G.parseState(a.s)), { mode: "p", dest: "t" });
	assert.deepEqual(json(G.parseState("rg.abcdefgh")), { mode: "r", dest: "g" });
	for (const bad of ["", "xt.abcdefgh", "pt.short", "pt.abcdefgh!", "pt-abcdefgh", "pz.abcdefgh", null, undefined, "PT.abcdefgh"]) assert.equal(G.parseState(bad), null, String(bad));

	// the request: fixed order, nothing extra
	const url = G.authUrl({ clientId: CLIENT, redirectUri: RETURN_URL, nonce: "ab12", state: "pt.abcdefgh12" });
	assert.equal(url, "https://accounts.google.com/o/oauth2/v2/auth?client_id=" + CLIENT + "&redirect_uri=https%3A%2F%2Fshakhzodmir.github.io%2Fgame%2Fauth_return.html&response_type=id_token%20token&scope=openid%20email%20profile&nonce=ab12&state=pt.abcdefgh12&prompt=select_account");
	const u2 = new URL(G.authUrl({ clientId: CLIENT, redirectUri: RETURN_URL, responseType: "token", nonce: "n", state: "pt.abcdefgh12" }));
	assert.equal(u2.searchParams.has("nonce"), false, "Google refuses a nonce with response_type=token");
	assert.equal(u2.searchParams.get("response_type"), "token");
	for (const rt of ["id_token", "id_token token"]) assert.equal(new URL(G.authUrl({ clientId: CLIENT, redirectUri: RETURN_URL, responseType: rt, nonce: "n", state: "pt.abcdefgh12" })).searchParams.get("nonce"), "n");
	for (const forbidden of ["response_mode", "include_granted_scopes", "hd=", "login_hint"]) assert.equal(url.includes(forbidden), false, forbidden + " is never sent");
	assert.match(G.authUrl({ clientId: CLIENT, redirectUri: RETURN_URL, nonce: "n", state: "pt.abcdefgh12", loginHint: "a@b.c" }), /&login_hint=a%40b\.c$/);
	assert.ok(G.authUrl({ clientId: CLIENT, redirectUri: RETURN_URL, nonce: "n", state: "s", endpoint: "http://127.0.0.1:1/auth" }).startsWith("http://127.0.0.1:1/auth?client_id="));
	assert.deepEqual(json(G.keysFor("t")), { pend: "glow_oidc_t_pend", res: "glow_oidc_t_res:", chan: "glow_oidc_t", ret: "glow_oidc_t_ret", own: "glow_oidc_t_own" });
	assert.equal(G.keysFor("g").pend, "glow_oidc_pend");

	// parameters
	assert.deepEqual(json(G.parseParams("#a=1&b=%20x+y&c&d=%3D&a=2")), { a: "1", b: " x y", c: "", d: "=" }, "first wins, + is a space, a bare name is empty");
	assert.deepEqual(json(G.parseParams("?x=%E0%A4%A")), { x: "%E0%A4%A" }, "a broken escape does not throw");
	assert.deepEqual(json(G.parseParams("__proto__=1&constructor=2")), { constructor: "2" }, "__proto__ is never a key");
	assert.deepEqual(json(G.parseParams("")), {}); assert.deepEqual(json(G.parseParams(null)), {});
	assert.deepEqual(json(G.relayParams({ q: "a=1&s=q", h: "s=h&b=2" })), { a: "1", s: "h", b: "2" }, "the fragment wins over the query");
	assert.equal(G.relayState({ h: "id_token=x&state=pt.abcdefgh12" }), "pt.abcdefgh12");
	assert.equal(G.relayState(null), "");

	// tokens
	const t = jwt({ iss: "i", name: "Анна Ким 김" });
	assert.equal(G.jwtClaims(t).name, "Анна Ким 김", "UTF-8 claims survive");
	for (const bad of ["", "a.b", "a.b.c.d", "a..c", "a.!!!.c", "a." + b64u("not json") + ".c", "a." + b64u("[1]") + ".c", null, undefined]) assert.equal(G.jwtClaims(bad), null, String(bad));
	void win;
}

// 2. validate -------------------------------------------------------------------------------------------------------------
{
	const { G } = coreWorld();
	const rec = json(await G.prepare({ dest: "t", mode: "p" }));
	const at = "ya29.token-value_1";
	const atHash = b64u(createHash("sha256").update(at).digest().subarray(0, 16));
	const relayOf = (frag, q = "") => ({ k: "glow_oidc", v: 1, h: frag, q, t: Date.now() });
	const ok = G.validate(relayOf("id_token=" + jwt(goodClaims(rec.n, { at_hash: atHash })) + "&access_token=" + at + "&state=" + rec.s), rec, { clientId: CLIENT, now: nowS() * 1000 });
	assert.equal(ok.ok, true);
	assert.deepEqual([ok.accessToken, ok.rawNonce, ok.tokenOnly, ok.claims.sub, ok.skew], [at, rec.r, false, "1", 0]);
	assert.ok(ok.idToken.split(".").length === 3);
	const expectFail = (frag, check, reason, ignore = false, extra = {}) => {
		const v = G.validate(relayOf(frag, extra.q || ""), extra.rec || rec, { clientId: CLIENT, ...(extra.opts || {}) });
		assert.deepEqual([v.ok, v.check, v.code, v.reason, v.ignore], [false, check, "glow/oidc-" + check, reason, ignore], check + " <- " + frag.slice(0, 60));
	};
	const goodId = jwt(goodClaims(rec.n));
	expectFail("id_token=" + goodId + "&access_token=" + at + "&state=" + rec.s + "X", "state", "", true);            // a foreign state is not ours: ignored, never an error
	expectFail("id_token=" + goodId + "&access_token=" + at, "state", "", true);                                       // no state at all
	expectFail("error=access_denied&state=" + rec.s, "denied", "cancelled");                                           // Cancel on Google's page: silent
	expectFail("error=server_error&state=" + rec.s, "oauth_server_error", "error");
	expectFail("error=%3Cscript%3E&state=" + rec.s, "oauth_script", "error");                                          // names are cleaned for the log
	expectFail("access_token=" + at + "&state=" + rec.s, "no_id_token", "error");
	expectFail("id_token=abc&access_token=" + at + "&state=" + rec.s, "bad_jwt", "error");
	expectFail("id_token=" + jwt(goodClaims(rec.n, { iss: "https://evil.example" })) + "&access_token=" + at + "&state=" + rec.s, "iss", "error");
	expectFail("id_token=" + jwt(goodClaims(rec.n, { aud: "other.apps.googleusercontent.com" })) + "&access_token=" + at + "&state=" + rec.s, "aud", "error");
	expectFail("id_token=" + jwt(goodClaims("zzz")) + "&access_token=" + at + "&state=" + rec.s, "nonce", "error");
	expectFail("id_token=" + jwt(goodClaims(rec.n, { exp: nowS() - 3 * 86400 })) + "&access_token=" + at + "&state=" + rec.s, "expired", "error");
	expectFail("id_token=" + jwt(goodClaims(rec.n, { exp: "never" })) + "&access_token=" + at + "&state=" + rec.s, "expired", "error");
	expectFail("id_token=" + goodId + "&state=" + rec.s, "no_access_token", "error");                                 // 'id_token token' without the access token
	expectFail("id_token=" + goodId + "&access_token=" + at + "&state=" + rec.s, "nonce", "error", false, { rec: { ...rec, n: "other" } }); // another attempt's nonce
	assert.equal(G.validate(null, rec, { clientId: CLIENT }).ignore, true); assert.equal(G.validate(relayOf("state=" + rec.s), null, {}).ignore, true);
	// both iss spellings; a wrong phone clock does not fail a good answer: only a day of slack is checked, the skew is reported
	assert.equal(G.validate(relayOf("id_token=" + jwt(goodClaims(rec.n, { iss: "accounts.google.com" })) + "&access_token=" + at + "&state=" + rec.s), rec, { clientId: CLIENT }).ok, true);
	const late = G.validate(relayOf("id_token=" + jwt(goodClaims(rec.n, { iat: nowS() - 7200, exp: nowS() - 3600 })) + "&access_token=" + at + "&state=" + rec.s), rec, { clientId: CLIENT, now: nowS() * 1000 });
	assert.deepEqual([late.ok, late.skew], [true, -7200], "a clock two hours ahead still signs in; the skew goes to the log");
	const early = G.validate(relayOf("id_token=" + jwt(goodClaims(rec.n, { iat: nowS() + 3000, exp: nowS() + 6600 })) + "&access_token=" + at + "&state=" + rec.s), rec, { clientId: CLIENT, now: nowS() * 1000 });
	assert.deepEqual([early.ok, early.skew], [true, 3000], "no iat check at all");
	// a fragment AND a query: the query is read too (an error may come that way)
	assert.equal(G.validate(relayOf("", "error=access_denied&state=" + rec.s), rec, { clientId: CLIENT }).check, "denied");
	// narrowed requests
	const recId = { ...rec, rt: "id_token" };
	const onlyId = G.validate(relayOf("id_token=" + goodId + "&state=" + rec.s), recId, { clientId: CLIENT });
	assert.deepEqual([onlyId.ok, onlyId.accessToken], [true, ""], "response_type=id_token needs no access token");
	const recT = { ...rec, rt: "token", n: "" };
	const onlyT = G.validate(relayOf("access_token=" + at + "&state=" + rec.s), recT, { clientId: CLIENT });
	assert.deepEqual([onlyT.ok, onlyT.tokenOnly, onlyT.idToken, onlyT.accessToken], [true, true, "", at], "token only: state is the single protection, and it is checked");
	assert.equal(G.validate(relayOf("state=" + rec.s), recT, { clientId: CLIENT }).check, "no_access_token");
	// reason ids
	assert.deepEqual(["glow/oidc-denied", "glow/oidc-state", "glow/oidc-nonce", "glow/oidc-oauth_x", "auth/popup-closed-by-user", "", undefined].map((c) => G.reasonOf(c)), ["cancelled", "", "error", "error", "", "", ""]);

	// at_hash: the access token is the one the id_token vouches for
	assert.equal(await G.checkAtHash({ at_hash: atHash }, at, { crypto: webcrypto }), "ok");
	assert.equal(await G.checkAtHash({ at_hash: atHash }, at + "x", { crypto: webcrypto }), "bad");
	assert.equal(await G.checkAtHash({}, at, { crypto: webcrypto }), "none");
	assert.equal(await G.checkAtHash({ at_hash: atHash }, "", { crypto: webcrypto }), "none");
	assert.equal(await G.checkAtHash({ at_hash: atHash }, at, { crypto: {} }), "none");
}

// 3. the order of credentials and the exchange policy (a fake SDK) ---------------------------------------------------------
{
	const { G } = coreWorld();
	const eq = (a, b, m) => assert.deepEqual(json(a), b, m);
	eq(G.credOrder("auto", { kind: "popup" }), ["A", "T"]);
	eq(G.credOrder("auto", { kind: "redirect" }), ["A", "T"]);
	eq(G.credOrder("auto", { kind: "redirect", aFailed: true }), ["B", "T"], "A failed before: a fresh token goes to B first");
	eq(G.credOrder("auto", { kind: "popup", aFailed: true }), ["A", "T"], "the popup test keeps A first");
	eq(G.credOrder("B", { kind: "popup" }), ["B"]); eq(G.credOrder("A", {}), ["A"]); eq(G.credOrder("T", {}), ["T"]);
	eq(G.credOrder("auto", { ath: "bad" }), ["A"], "an access token the id_token does not vouch for is not used");
	eq(G.credOrder("T", { ath: "bad" }), [], "...even when T was asked for");
	eq(G.credOrder("auto", { access: false }), ["A"]);
	const err = (code) => Object.assign(new Error(code), { code });
	const run = async (order, plan) => {
		const tried = [];
		const r = await G.exchange({ order, attempt: (k) => { tried.push(k); return plan[k] === "ok" ? Promise.resolve({ user: k }) : Promise.reject(err(plan[k])); } });
		return { r: json({ ok: r.ok, cred: r.cred, results: r.results, fatal: !!r.fatal }), tried };
	};
	let x = await run(["A", "T"], { A: "ok" });
	eq(x.r, { ok: true, cred: "A", results: { A: "ok", B: "skip", T: "skip" }, fatal: false }); eq(x.tried, ["A"]);
	x = await run(["A", "T"], { A: "auth/missing-or-invalid-nonce", T: "ok" });
	eq(x.r, { ok: true, cred: "T", results: { A: "auth/missing-or-invalid-nonce", B: "skip", T: "ok" }, fatal: false }); eq(x.tried, ["A", "T"]);
	x = await run(["A", "T"], { A: "auth/network-request-failed", T: "ok" });
	eq(x.r, { ok: false, cred: "none", results: { A: "auth/network-request-failed", B: "skip", T: "skip" }, fatal: true }); eq(x.tried, ["A"], "a network error stops the chain: T would fail the same way");
	x = await run(["A", "T"], { A: "auth/invalid-credential", T: "auth/invalid-credential" });
	eq(x.r, { ok: false, cred: "none", results: { A: "auth/invalid-credential", B: "skip", T: "auth/invalid-credential" }, fatal: false });
	x = await run(["B", "T"], { B: "auth/user-disabled", T: "ok" }); eq(x.tried, ["B"]);
	x = await run([], {}); eq(x.r, { ok: false, cred: "none", results: { A: "skip", B: "skip", T: "skip" }, fatal: false });
	const thrown = await G.exchange({ order: ["A"], attempt: () => { throw err("auth/internal-error"); } });
	assert.equal(thrown.ok, false); assert.equal(thrown.results.A, "auth/internal-error", "a synchronous throw is an answer too");
}

// 4. storage of an attempt ---------------------------------------------------------------------------------------------------
{
	let t = 1_000_000;
	const { G, win, world } = coreWorld();
	const env = { clock: () => t };
	const rec = json(await G.prepare({ dest: "t", mode: "p", now: t }));
	const rec2 = json(await G.prepare({ dest: "t", mode: "r", now: t }));
	// popup mode: the full record only in this tab; the shared storage gets a beacon without the secrets
	assert.deepEqual(json(G.savePending(rec, env, { shared: false })), { ss: true, ls: true });
	const ls = win.window.localStorage, ss = win.window.sessionStorage;
	const inSS = JSON.parse(ss.getItem("glow_oidc_t_pend")), inLS = JSON.parse(ls.getItem("glow_oidc_t_pend:" + rec.s));
	assert.equal(inSS.r, rec.r); assert.equal(inLS.r, undefined, "no raw nonce in the shared storage in popup mode"); assert.equal(inLS.n, undefined);
	assert.deepEqual([inLS.s, inLS.m, inLS.d], [rec.s, "p", "t"], "but the return page can tell the state is ours");
	assert.deepEqual(json(G.readPending("t", rec.s, env)).src, "ss");
	assert.deepEqual(json(G.readPending("t", null, env)).rec.s, rec.s, "no state asked: this tab's own record");
	// redirect mode: the full record is also shared (another window may finish the sign-in)
	G.savePending(rec2, env, { shared: true });
	assert.equal(JSON.parse(ls.getItem("glow_oidc_t_pend:" + rec2.s)).r, rec2.r);
	const list = json(G.listPending("t", env));
	assert.deepEqual(list.map((x) => [x.rec.s, x.src, x.beacon]), [[rec2.s, "ss", false], [rec.s, "ls", true]], "the tab's record first, then the shared ones; the beacon is marked");
	ss.removeItem("glow_oidc_t_pend");
	assert.deepEqual(json(G.readPending("t", rec2.s, env)), { rec: json(rec2), src: "ls", beacon: false });
	assert.equal(G.readPending("t", rec.s, env).beacon, true);
	assert.equal(G.readPending("g", rec.s, env), null, "the game's records are another namespace");
	// the starter's own marker
	assert.equal(G.isOwn("t", rec.s, env), false);
	G.markOwn("t", rec.s, env);
	assert.deepEqual([G.isOwn("t", rec.s, env), G.isOwn("t", "other", env), G.isOwn("t", undefined, env), G.isOwn("g", rec.s, env)], [true, false, true, false]);
	// claim: a beacon cannot be claimed; one claim at a time; the same page may claim again; an old claim is void
	assert.equal(G.claim("t", rec.s, env, { by: "a" }), null, "a beacon holds no secret: nothing to finish with");
	assert.equal(json(G.claim("t", rec2.s, env, { by: "a" })).cl.by, "a");
	assert.equal(G.claim("t", rec2.s, env, { by: "b" }), null, "another page is on it");
	assert.ok(G.claim("t", rec2.s, env, { by: "a" }), "the same page again");
	t += 61_000;
	assert.ok(G.claim("t", rec2.s, env, { by: "b" }), "a claim older than a minute is void");
	// the mailbox
	ls.setItem("glow_oidc_t_res:" + rec2.s, JSON.stringify({ k: "glow_oidc", v: 1, h: "state=" + rec2.s, q: "", t }));
	ls.setItem("glow_oidc_t_res:junk", "{not json"); ls.setItem("glow_oidc_t_res:other", JSON.stringify({ k: "nope" }));
	assert.deepEqual(json(G.listMail("t", env)).map((m) => m.state), [rec2.s]);
	assert.equal(G.readRelay("t", rec2.s, env).k, "glow_oidc"); assert.equal(G.readRelay("t", "none", env), null);
	// sweep: old attempts (15 min) and old answers (2 min) and broken entries go; fresh ones stay; others' keys stay
	ls.setItem("unrelated", "1");
	ls.setItem("glow_oidc_t_pend:old", JSON.stringify({ s: "old", t: t - 16 * 60_000 }));
	ls.setItem("glow_oidc_t_res:oldmail", JSON.stringify({ k: "glow_oidc", v: 1, t: t - 121_000 }));
	const before = [...world.ls.keys()].length;
	const removed = G.sweep("t", env);
	assert.equal(removed, 4, "old attempt, old answer, two broken answers");
	assert.equal([...world.ls.keys()].length, before - 4);
	assert.ok(ls.getItem("unrelated") && ls.getItem("glow_oidc_t_pend:" + rec2.s) && ls.getItem("glow_oidc_t_res:" + rec2.s));
	// done: nothing of the attempt is left, and the marker goes only with its own state
	G.markOwn("t", rec2.s, env);
	G.clearFlow("t", rec2.s, env);
	assert.equal(ls.getItem("glow_oidc_t_pend:" + rec2.s), null); assert.equal(ls.getItem("glow_oidc_t_res:" + rec2.s), null); assert.equal(G.isOwn("t", undefined, env), false);
	assert.ok(ls.getItem("glow_oidc_t_pend:" + rec.s), "another attempt is untouched");
	// blocked storage never throws
	const blocked = coreWorld({ noLocalStorage: true });
	const fresh = json(await blocked.G.prepare({ dest: "t", mode: "p" }));
	assert.deepEqual(json(blocked.G.savePending(fresh, {}, { shared: true })), { ss: true, ls: false });
	assert.deepEqual(json(blocked.G.listMail("t", {})), []); assert.equal(blocked.G.sweep("t", {}), 0); assert.equal(blocked.G.readPending("t", fresh.s, {}).src, "ss");
	assert.deepEqual(json(blocked.G.listPending("t", {})).map((x) => x.src), ["ss"]); assert.equal(blocked.G.claim("t", fresh.s, {}, { by: "a" }).cl.by, "a");
}

console.log("auth_oidc_check: core ok");
