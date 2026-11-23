// The fake browser the sign-in checks run in (no real browser, no network). Shared by tools/qa/auth_oidc_check.mjs (the core
// and the return page) and tools/qa/auth_flows_check.mjs (web/glow_auth.js on top of them).
import fs from "node:fs";
import vm from "node:vm";
import { createHash, webcrypto } from "node:crypto";

export const read = (p) => fs.readFileSync(new URL("../../" + p, import.meta.url), "utf8");
export const scriptOf = (html) => (html.match(/<script>([\s\S]*?)<\/script>/) || [])[1];
export const CORE = read("web/glow_oidc.js");
export const RETURN_JS = scriptOf(read("web/auth_return.html"));
if (!RETURN_JS) throw new Error("the return page has one inline script");

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const json = (x) => JSON.parse(JSON.stringify(x)); // a plain main-realm copy (objects made inside a vm context have another prototype)
export const CLIENT = "956973883845-ct7e77188vteg5edv7m3sgp8j8iptd5r.apps.googleusercontent.com";
export const ORIGIN = "https://shakhzodmir.github.io";
export const RETURN_URL = ORIGIN + "/game/auth_return.html";
export const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2.1 Mobile/24B156 Safari/604.1";
export const b64u = (buf) => Buffer.from(buf).toString("base64url");
export const sha256hex = (s) => createHash("sha256").update(s).digest("hex");

// ------------------------------------------------------------------------------------------------------------------------
// the fake browser: windows with their own sessionStorage, ONE shared localStorage and BroadcastChannel bus per origin,
// window.open that copies sessionStorage at open time, postMessage with origin and source, a fake Google that redirects.
// ------------------------------------------------------------------------------------------------------------------------
export function makeWorld() {
	const world = { ls: new Map(), bus: new Map(), windows: [], blocked: [], google: [], clock: () => Date.now() };
	const deliver = (win, type, ev) => setTimeout(() => (win._l[type] || []).slice().forEach((f) => { try { f(ev); } catch (e) { world.errors.push(e); } }), 0);
	world.errors = [];
	world.deliver = deliver;
	world.notifyStorage = (writer, key, newValue) => {
		for (const w of world.windows) if (w !== writer && !w.gone) deliver(w, "storage", { type: "storage", key, newValue, origin: ORIGIN });
	};
	world.bcDeliver = (from, name, data) => {
		for (const ch of world.bus.get(name) || []) if (ch !== from && !ch.closed && ch.win && !ch.win.gone) setTimeout(() => { try { if (!ch.closed && ch.onmessage) ch.onmessage({ data: json(data) }); } catch (e) { world.errors.push(e); } }, 0);
	};
	return world;
}

// a Storage over a Map (the local one is shared, and tells the other windows through "storage" events)
export function makeStorage(map, onChange) {
	return {
		get length() { return map.size; },
		key: (i) => (i < map.size ? [...map.keys()][i] : null),
		getItem: (k) => (map.has(String(k)) ? map.get(String(k)) : null),
		setItem: (k, v) => { map.set(String(k), String(v)); if (onChange) onChange(String(k), String(v)); },
		removeItem: (k) => { const had = map.has(String(k)); map.delete(String(k)); if (had && onChange) onChange(String(k), null); },
	};
}

// a page element for the pieces web/glow_auth.js builds (the card, the form, the small lines)
export function makeEl(tag) {
	return {
		tag, style: {}, children: [], _l: {}, textContent: "", parentNode: null,
		appendChild(c) { this.children.push(c); c.parentNode = this; return c; },
		removeChild(c) { const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); c.parentNode = null; return c; },
		addEventListener(t, f) { (this._l[t] = this._l[t] || []).push(f); },
		contains(x) { return x === this || this.children.some((c) => c.contains(x)); },
		focus() {}, click() { (this._l.click || []).forEach((f) => f({ target: this })); },
	};
}

// opts: href, touch (maxTouchPoints, default 5), ss (Map to copy), opener (a window), sever, noBC, noLocalStorage, lang, standalone, ua, script (source to run), core (bool), visible
export function makeWindow(world, opts) {
	const o = { lang: "en", ua: IPHONE, core: false, visible: true, ...opts };
	const url = new URL(o.href);
	const win = { _l: {}, _docl: {}, gone: false, closedFlag: false, navs: [], replaced: [], posted: [], errors: [], closeCalls: 0, severed: !!o.sever };
	const ssMap = new Map(o.ss ? [...o.ss] : []);
	win.ssMap = ssMap;
	const doc = {
		hidden: !o.visible, visibilityState: o.visible ? "visible" : "hidden", documentElement: { textContent: "lang-root", lang: "en" },
		createElement: makeEl, body: makeEl("body"),
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
	win.navigator = { language: o.lang, userAgent: o.ua, maxTouchPoints: o.touch === undefined ? 5 : o.touch };
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
		world.deliver(win, "message", { type: "message", data: json(data), origin: origin || ORIGIN, source });
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
		localStorage: win.localStorage, sessionStorage: win.sessionStorage, crypto: win.crypto,
		BroadcastChannel: win.BroadcastChannel, setTimeout, clearTimeout, setInterval, clearInterval, console });
	win.ctx = ctx;
	win.run = (src) => vm.runInContext(src, ctx);
	if (o.core) vm.runInContext(CORE, ctx);
	return win;
}

// the fake Google: world.openFrom(openerWindow, url) is what window.open does; the destination page loads after a short
// "account chooser" delay and is the return page with the answer in the fragment (or an error), like the real redirect.
export function installGoogle(world, scenario) {
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
export function loadReturn(world, { href, from, opener, sc = {} }) {
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
	const scale = sc.scale || 0.2;
	win.ctx.setTimeout = (f, ms) => setTimeout(f, ms * scale); win.ctx.setInterval = (f, ms) => setInterval(f, Math.max(5, ms * scale));
	win.run(RETURN_JS);
	return win;
}
