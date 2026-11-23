// GLOW: our own sign-in with Google, the OpenID Connect leg (implicit flow, no server of ours).
//
// Why: Firebase's pop-up needs the window that Google's page opens to keep a live link (window.opener) to the game page.
// On some iPhones that link is gone a moment after the window opens, and the answer never reaches the page. Here Google
// answers to a page of OUR OWN origin (web/auth_return.html), which hands the answer over through shared storage, a
// broadcast channel and, when the link is alive, window.opener.postMessage. Nothing here needs the link, a server, or
// third-party storage. This file builds the request, keeps the secrets of one attempt, listens for the answer and checks
// it. It knows nothing about Firebase: the caller turns the checked tokens into a Firebase credential
// (see exchange() for the order in which to try them).
//
// It loads by a plain <script> tag (window.glowOidc) and by node (module.exports), and touches nothing of the browser
// until a function is called. Needs Promise and crypto.subtle (https pages only).
//
// A flow has a MODE and a DESTINATION, both in the first two letters of its state: "p" = Google's window is a pop-up and
// the page that started it waits; "r" = the whole page goes to Google and comes back; "g" = the game page, "t" = the
// phone test page (web/auth_test.html). A state looks like "pt.<24 random characters>".
//
// API (window.glowOidc), every function is safe to call and never throws unless it says so:
//   version                      the version of this file (the ?v= of its <script> tag must match it)
//   prepare({dest, mode, responseType, crypto})  -> Promise<pending>: a fresh attempt {v:1, s:state, r:raw nonce, n:nonce
//                                (sha256 hex of r, sent to Google), m, d, t:ms, rt:responseType}. Rejects with
//                                code "glow/oidc-nocrypto" when the browser has no crypto.subtle. Compute it BEFORE the tap:
//                                the tap must open the window without waiting for anything.
//   authUrl({clientId, redirectUri, responseType, scope, nonce, state, prompt, loginHint, endpoint}) -> string. Fixed order
//                                of parameters; no nonce for responseType "token" (Google refuses one there); never sends
//                                response_mode, include_granted_scopes or hd.
//   keysFor(dest)                storage keys and channel name of a destination: {pend, res, chan, ret, own}
//   parseState(s)                -> {mode, dest} | null
//   parseParams(str)             "a=1&b=2" (a leading # or ? is dropped) -> {a:"1", b:"2"}; first value wins
//   relayParams(relay)           the parameters of a relay: its query merged with its fragment (the fragment wins)
//   relayState(relay)            the state inside a relay, "" if none
//   jwtClaims(token)             the payload of a JWT, or null. NO signature check here: Firebase's backend does it
//   validate(relay, pending, {clientId, now, expSlackMs})
//                                -> {ok:true, idToken, accessToken, rawNonce, claims, skew, tokenOnly}
//                                 | {ok:false, check, code, reason, ignore}
//                                checks, in order: state (a foreign state is {ignore:true}: not ours, keep waiting), the
//                                "error" parameter, id_token present, iss, aud, nonce, exp (coarse: a wrong phone clock must
//                                not fail a good sign-in; there is NO iat check, the skew in seconds is returned for the log),
//                                access_token present when the request asked for one. code is "glow/oidc-<check>"; reason is
//                                one of our reason ids ("cancelled" for access_denied, "error" for the rest, "" for ignore).
//   checkAtHash(claims, accessToken) -> Promise<"ok"|"bad"|"none">: is the access token the one the id_token vouches for
//   reasonOf(code)               our reason id of a "glow/oidc-*" code
//   savePending(rec, env, {shared})  keeps the attempt: full record in this tab's sessionStorage; in localStorage (per state)
//                                a full copy only when shared (redirect mode: another window may finish the sign-in),
//                                otherwise a beacon without the secrets (it only tells the return page "this state is ours")
//   readPending(dest, state, env), listPending(dest, env), clearFlow(dest, state, env), sweep(dest, env)
//   markOwn(dest, state, env), isOwn(dest, state, env): the marker of the starter's own window. Write it right AFTER
//                                window.open (a window opened from here gets a COPY of sessionStorage made at open time, so a
//                                key written afterwards is the one thing a child never has), or right before location.assign
//   claim(dest, state, env, {by}) -> pending|null: marks the attempt as being consumed; another page that claims it within
//                                60 s gets null. Delete the attempt (clearFlow) when the exchange has settled
//   listMail(dest, env), readRelay(dest, state, env)  the answers waiting in the shared-storage mailbox
//   listen({dest, state, win, onRelay, onSeen, ...}) -> {stop, ack, setWin, poke, count, state}
//                                waits for the answer of ONE state on every channel: BroadcastChannel, message events (same
//                                origin only; from the pop-up only while it is alive), the storage event, a 300 ms re-read of
//                                the mailbox, and a re-read when the page becomes visible / is shown again / gets focus.
//                                onRelay(relay, via, info) fires once, for the first answer; onSeen(via, info, relay) for
//                                every arrival (via: "bc" | "pm" | "st" | "poll" | "vis" | "show" | "focus" | "load";
//                                info.hidden: the page was hidden at that moment). Answers to {k:"glow_oidc_ping"} while
//                                armed (a live starter says so to the return page). ack(via) tells the return page it can close.
//   credOrder(mode, {kind, aFailed, access, ath}) -> ["A","B","T"] subset: the order in which to try credentials
//   exchange({order, attempt, fatal}) -> Promise<{ok, cred, results:{A,B,T}, error}>: tries attempt(kind) in that order
//   (A = google.com OAuthProvider credential with the raw nonce, B = the same id_token without a nonce, T = the access token)
(function () {
	"use strict";
	var VERSION = "2026-11-23d";
	var GOOGLE_AUTH = "https://accounts.google.com/o/oauth2/v2/auth";
	var ISSUERS = ["https://accounts.google.com", "accounts.google.com"];
	var K_RELAY = "glow_oidc", K_ACK = "glow_oidc_ack", K_PING = "glow_oidc_ping", K_PONG = "glow_oidc_pong";
	var STATE_RE = /^([pr])([gt])\.[A-Za-z0-9_-]{8,}$/;
	var MAIL_MS = 120 * 1000;        // an answer left in the mailbox this long is swept
	var PEND_MS = 15 * 60 * 1000;    // an attempt older than this is swept
	var CLAIM_MS = 60 * 1000;        // an attempt claimed this recently is not claimed again by another page
	var EXP_SLACK_MS = 24 * 3600 * 1000;
	var POLL_MS = 300;
	var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
	var D = {};
	(function () { for (var i = 0; i < 64; i++) D[B64.charAt(i)] = i; D["+"] = 62; D["/"] = 63; })();

	// bytes, base64url, hex, utf-8 --------------------------------------------------------------------------------------
	function b64u(bytes) {
		var out = "", i = 0, n = bytes.length, a, b, c;
		for (; i + 2 < n; i += 3) {
			a = bytes[i]; b = bytes[i + 1]; c = bytes[i + 2];
			out += B64.charAt(a >> 2) + B64.charAt(((a & 3) << 4) | (b >> 4)) + B64.charAt(((b & 15) << 2) | (c >> 6)) + B64.charAt(c & 63);
		}
		if (i < n) {
			a = bytes[i]; b = i + 1 < n ? bytes[i + 1] : 0;
			out += B64.charAt(a >> 2) + B64.charAt(((a & 3) << 4) | (b >> 4));
			if (i + 1 < n) out += B64.charAt((b & 15) << 2);
		}
		return out;
	}
	function unb64u(s) {
		var out = [], buf = 0, bits = 0, i, v;
		s = String(s).replace(/=+$/, "");
		for (i = 0; i < s.length; i++) {
			v = D[s.charAt(i)];
			if (v === undefined) throw new Error("base64");
			buf = (buf << 6) | v; bits += 6;
			if (bits >= 8) { bits -= 8; out.push((buf >> bits) & 255); buf &= (1 << bits) - 1; }
		}
		return out;
	}
	function hex(bytes) {
		var s = "", i, b;
		for (i = 0; i < bytes.length; i++) { b = bytes[i]; s += (b < 16 ? "0" : "") + b.toString(16); }
		return s;
	}
	function utf8(bytes) {
		var s = "", i;
		for (i = 0; i < bytes.length; i++) s += "%" + (bytes[i] < 16 ? "0" : "") + bytes[i].toString(16);
		return decodeURIComponent(s);
	}
	function utf8Bytes(str) {
		var e = encodeURIComponent(String(str)), out = [], i = 0;
		while (i < e.length) {
			if (e.charAt(i) === "%") { out.push(parseInt(e.substr(i + 1, 2), 16)); i += 3; } else { out.push(e.charCodeAt(i)); i++; }
		}
		return out;
	}
	function getCrypto(o) {
		if (o && o.crypto) return o.crypto;
		try { if (typeof window !== "undefined" && window && window.crypto) return window.crypto; } catch (e) { /* none */ }
		try { if (typeof crypto !== "undefined" && crypto) return crypto; } catch (e2) { /* none */ }
		return null;
	}
	function sha256(bytes, c) {
		return c.subtle.digest("SHA-256", new Uint8Array(bytes)).then(function (buf) { return new Uint8Array(buf); });
	}
	function fail(check) { var e = new Error("glow/oidc-" + check); e.code = "glow/oidc-" + check; return e; }

	// the request ---------------------------------------------------------------------------------------------------------
	function prepare(opts) {
		opts = opts || {};
		return new Promise(function (resolve, reject) {
			var c = getCrypto(opts), mode = opts.mode === "r" ? "r" : "p", dest = opts.dest === "g" ? "g" : "t", raw, tail;
			if (!c || !c.subtle || typeof c.getRandomValues !== "function") return reject(fail("nocrypto"));
			try {
				var a = new Uint8Array(32), b = new Uint8Array(18);
				c.getRandomValues(a); c.getRandomValues(b);
				raw = b64u(a); tail = b64u(b);
			} catch (e) { return reject(fail("nocrypto")); }
			sha256(utf8Bytes(raw), c).then(function (d) {
				resolve({ v: 1, s: mode + dest + "." + tail, r: raw, n: hex(d), m: mode, d: dest,
					t: typeof opts.now === "number" ? opts.now : Date.now(), rt: opts.responseType || "id_token token" });
			}, function () { reject(fail("nocrypto")); });
		});
	}
	function authUrl(p) {
		var enc = encodeURIComponent, rt = p.responseType || "id_token token";
		var parts = ["client_id=" + enc(p.clientId), "redirect_uri=" + enc(p.redirectUri), "response_type=" + enc(rt),
			"scope=" + enc(p.scope || "openid email profile")];
		if (rt !== "token") parts.push("nonce=" + enc(p.nonce)); // Google: "Parameter not allowed for this message type: nonce"
		parts.push("state=" + enc(p.state));
		parts.push("prompt=" + enc(p.prompt || "select_account"));
		if (p.loginHint) parts.push("login_hint=" + enc(p.loginHint));
		return (p.endpoint || GOOGLE_AUTH) + "?" + parts.join("&");
	}
	function keysFor(dest) {
		return dest === "g"
			? { pend: "glow_oidc_pend", res: "glow_oidc_res:", chan: "glow_oidc", ret: "glow_oidc_ret", own: "glow_oidc_own" }
			: { pend: "glow_oidc_t_pend", res: "glow_oidc_t_res:", chan: "glow_oidc_t", ret: "glow_oidc_t_ret", own: "glow_oidc_t_own" };
	}
	function parseState(s) {
		var m = STATE_RE.exec(String(s == null ? "" : s));
		return m ? { mode: m[1], dest: m[2] } : null;
	}

	// the answer ----------------------------------------------------------------------------------------------------------
	function dec(x) { try { return decodeURIComponent(String(x).replace(/\+/g, " ")); } catch (e) { return String(x); } }
	function parseParams(str) {
		var o = {}, parts, i, kv, j, k;
		str = String(str == null ? "" : str).replace(/^[#?]/, "");
		if (!str) return o;
		parts = str.split("&");
		for (i = 0; i < parts.length; i++) {
			kv = parts[i];
			if (!kv) continue;
			j = kv.indexOf("=");
			k = dec(j < 0 ? kv : kv.slice(0, j));
			if (k && k !== "__proto__" && !Object.prototype.hasOwnProperty.call(o, k)) o[k] = j < 0 ? "" : dec(kv.slice(j + 1));
		}
		return o;
	}
	function relayParams(relay) {
		var a = parseParams(relay && relay.q), b = parseParams(relay && relay.h), o = {}, k;
		for (k in a) if (Object.prototype.hasOwnProperty.call(a, k)) o[k] = a[k];
		for (k in b) if (Object.prototype.hasOwnProperty.call(b, k)) o[k] = b[k];
		return o;
	}
	function relayState(relay) { return String(relayParams(relay).state || ""); }
	function jwtClaims(token) {
		try {
			var p = String(token).split("."), o;
			if (p.length !== 3 || !p[1]) return null;
			o = JSON.parse(utf8(unb64u(p[1])));
			return o && typeof o === "object" && Object.prototype.toString.call(o) !== "[object Array]" ? o : null;
		} catch (e) { return null; }
	}
	function reasonOf(code) {
		code = String(code || "");
		if (code === "glow/oidc-denied") return "cancelled"; // the player pressed Cancel on Google's page: silent, like a closed form
		if (code === "glow/oidc-state") return "";           // not ours: never an error
		return code.indexOf("glow/oidc-") === 0 ? "error" : "";
	}
	function bad(check, ignore) { var code = "glow/oidc-" + check; return { ok: false, check: check, code: code, reason: reasonOf(code), ignore: !!ignore }; }
	function safeName(s) { return String(s).replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 40) || "unknown"; }

	function validate(relay, pending, opts) {
		opts = opts || {};
		var now = typeof opts.now === "number" ? opts.now : Date.now();
		var p = relayParams(relay);
		if (!pending || !pending.s || !p.state || p.state !== pending.s) return bad("state", true);
		if (p.error) {
			// Google's own words: access_denied is the Cancel button; anything else is a failure we cannot explain better
			return p.error === "access_denied" ? bad("denied") : bad("oauth_" + safeName(p.error));
		}
		var rt = String(pending.rt || "id_token token"), types = rt.split(" ");
		var wantId = types.indexOf("id_token") >= 0, wantAccess = types.indexOf("token") >= 0;
		var res = { ok: true, idToken: "", accessToken: "", rawNonce: pending.r || "", claims: null, skew: null, tokenOnly: !wantId };
		if (wantId) {
			if (!p.id_token) return bad("no_id_token");
			var c = jwtClaims(p.id_token);
			if (!c) return bad("bad_jwt");
			if (ISSUERS.indexOf(c.iss) < 0) return bad("iss");
			if (c.aud !== opts.clientId) return bad("aud");
			if (c.nonce !== pending.n) return bad("nonce");
			var slack = typeof opts.expSlackMs === "number" ? opts.expSlackMs : EXP_SLACK_MS;
			if (typeof c.exp !== "number" || c.exp * 1000 < now - slack) return bad("expired");
			res.idToken = p.id_token;
			res.claims = c;
			res.skew = typeof c.iat === "number" ? Math.round(c.iat - now / 1000) : null;
		}
		if (wantAccess) {
			if (!p.access_token) return bad("no_access_token");
			res.accessToken = p.access_token;
		}
		return res;
	}
	// at_hash of an "id_token token" answer: base64url of the left half of sha256(access token)
	function checkAtHash(claims, accessToken, opts) {
		return new Promise(function (resolve) {
			if (!claims || !claims.at_hash || !accessToken) return resolve("none");
			var c = getCrypto(opts);
			if (!c || !c.subtle) return resolve("none");
			try {
				sha256(utf8Bytes(accessToken), c).then(function (d) {
					var half = [], i;
					for (i = 0; i < 16; i++) half.push(d[i]);
					resolve(b64u(half) === claims.at_hash ? "ok" : "bad");
				}, function () { resolve("none"); });
			} catch (e) { resolve("none"); }
		});
	}

	// storage -------------------------------------------------------------------------------------------------------------
	function pick(o, name) {
		if (o && o[name] !== undefined) return o[name];
		try { return typeof window !== "undefined" && window ? window[name] : null; } catch (e) { return null; } // blocked storage throws
	}
	function envOf(o) {
		return { ls: pick(o, "localStorage"), ss: pick(o, "sessionStorage"), BC: pick(o, "BroadcastChannel"),
			clock: (o && typeof o.clock === "function") ? o.clock : function () { return Date.now(); } };
	}
	function sget(st, k) { try { return st ? st.getItem(k) : null; } catch (e) { return null; } }
	function sset(st, k, v) { try { if (!st) return false; st.setItem(k, v); return true; } catch (e) { return false; } }
	function sdel(st, k) { try { if (st) st.removeItem(k); } catch (e) { /* none */ } }
	function skeys(st) {
		var out = [], i, n;
		try { if (!st) return out; n = st.length; for (i = 0; i < n; i++) out.push(st.key(i)); } catch (e) { /* none */ }
		return out;
	}
	function pj(v) {
		if (!v) return null;
		try { var o = JSON.parse(v); return o && typeof o === "object" ? o : null; } catch (e) { return null; }
	}
	function strip(rec) {
		var o = {}, k;
		for (k in rec) if (Object.prototype.hasOwnProperty.call(rec, k) && k !== "r" && k !== "n") o[k] = rec[k];
		return o;
	}
	function savePending(rec, o, opts) {
		var e = envOf(o), k = keysFor(rec.d), json = JSON.stringify(rec);
		var ssOk = sset(e.ss, k.pend, json);
		var lsOk = sset(e.ls, k.pend + ":" + rec.s, opts && opts.shared ? json : JSON.stringify(strip(rec)));
		return { ss: ssOk, ls: lsOk };
	}
	function readPending(dest, state, o) {
		var e = envOf(o), k = keysFor(dest), r = pj(sget(e.ss, k.pend));
		if (r && r.s && (!state || r.s === state)) return { rec: r, src: "ss", beacon: false };
		if (state) {
			r = pj(sget(e.ls, k.pend + ":" + state));
			if (r && r.s === state) return { rec: r, src: "ls", beacon: !r.r };
		}
		return null;
	}
	function listPending(dest, o) {
		var e = envOf(o), k = keysFor(dest), out = [], seen = {}, r = pj(sget(e.ss, k.pend)), keys, i, p;
		if (r && r.s) { out.push({ rec: r, src: "ss", beacon: false }); seen[r.s] = 1; }
		keys = skeys(e.ls);
		for (i = 0; i < keys.length; i++) {
			if (keys[i].indexOf(k.pend + ":") !== 0) continue;
			p = pj(sget(e.ls, keys[i]));
			if (p && p.s && !seen[p.s]) { out.push({ rec: p, src: "ls", beacon: !p.r }); seen[p.s] = 1; }
		}
		return out;
	}
	function listMail(dest, o) {
		var e = envOf(o), k = keysFor(dest), keys = skeys(e.ls), out = [], i, r;
		for (i = 0; i < keys.length; i++) {
			if (keys[i].indexOf(k.res) !== 0) continue;
			r = pj(sget(e.ls, keys[i]));
			if (r && r.k === K_RELAY) out.push({ state: keys[i].slice(k.res.length), relay: r });
		}
		return out;
	}
	function readRelay(dest, state, o) {
		var e = envOf(o), r = pj(sget(e.ls, keysFor(dest).res + state));
		return r && r.k === K_RELAY ? r : null;
	}
	function markOwn(dest, state, o) { return sset(envOf(o).ss, keysFor(dest).own, state); }
	function isOwn(dest, state, o) { var v = sget(envOf(o).ss, keysFor(dest).own); return !!v && (state === undefined || v === state); }
	function clearFlow(dest, state, o) {
		var e = envOf(o), k = keysFor(dest), r = pj(sget(e.ss, k.pend));
		if (r && r.s === state) sdel(e.ss, k.pend);
		if (sget(e.ss, k.own) === state) sdel(e.ss, k.own);
		sdel(e.ls, k.pend + ":" + state);
		sdel(e.ls, k.res + state);
	}
	function sweep(dest, o) {
		var e = envOf(o), k = keysFor(dest), n = e.clock(), keys = skeys(e.ls), removed = 0, i, r;
		for (i = 0; i < keys.length; i++) {
			if (keys[i].indexOf(k.pend + ":") === 0) {
				r = pj(sget(e.ls, keys[i]));
				if (!r || !(n - r.t < PEND_MS)) { sdel(e.ls, keys[i]); removed++; }
			} else if (keys[i].indexOf(k.res) === 0) {
				r = pj(sget(e.ls, keys[i]));
				if (!r || !(n - r.t < MAIL_MS)) { sdel(e.ls, keys[i]); removed++; }
			}
		}
		r = pj(sget(e.ss, k.pend));
		if (r && !(n - r.t < PEND_MS)) { sdel(e.ss, k.pend); removed++; }
		return removed;
	}
	function claim(dest, state, o, opts) {
		var e = envOf(o), k = keysFor(dest), n = e.clock(), by = (opts && opts.by) || "", got = readPending(dest, state, o), json, copy;
		if (!got || !got.rec.r) return null; // nothing to finish with: a beacon holds no secret
		var rec = got.rec, c = rec.cl;
		if (c && c.by !== by && n - c.t < CLAIM_MS) return null; // another page is on it
		rec.cl = { t: n, by: by };
		json = JSON.stringify(rec);
		if (got.src === "ss") sset(e.ss, k.pend, json);
		copy = pj(sget(e.ls, k.pend + ":" + state));
		if (got.src === "ls" || (copy && copy.r)) sset(e.ls, k.pend + ":" + state, json);
		return rec;
	}

	// the wait ------------------------------------------------------------------------------------------------------------
	function listen(opts) {
		opts = opts || {};
		var e = envOf(opts), k = keysFor(opts.dest), state = String(opts.state || ""), resKey = k.res + state;
		var target = opts.target || (typeof window !== "undefined" ? window : null);
		var doc = opts.document || (target && target.document) || null;
		var origin = opts.origin || (target && target.location && target.location.origin) || "";
		var win = opts.win || null, bc = null, timer = null, stopped = false, first = false, count = 0, h = {};
		var setI = opts.setInterval || (typeof setInterval === "function" ? setInterval : null);
		var clrI = opts.clearInterval || (typeof clearInterval === "function" ? clearInterval : null);
		function hidden() { try { return !!(doc && (doc.hidden === true || doc.visibilityState === "hidden")); } catch (x) { return false; } }
		function winGone() { try { return !win || win.closed === true; } catch (x) { return true; } }
		function arrive(relay, via) {
			var info;
			if (stopped || !relay || relay.k !== K_RELAY || relay.v !== 1 || relayState(relay) !== state) return; // not ours: ignored, not an error
			count++;
			info = { via: via, hidden: hidden(), t: e.clock(), n: count };
			if (opts.onSeen) { try { opts.onSeen(via, info, relay); } catch (x1) { /* the caller's problem */ } }
			if (!first) {
				first = true;
				if (opts.onRelay) { try { opts.onRelay(relay, via, info); } catch (x2) { /* the caller's problem */ } }
			}
		}
		function readMail(via) {
			if (stopped) return;
			var r = pj(sget(e.ls, resKey));
			if (r) arrive(r, via);
		}
		function onMessage(ev) {
			if (!ev || ev.origin !== origin || !ev.data || typeof ev.data !== "object") return;
			if (win && ev.source && ev.source !== win && !winGone()) return; // from another window than the pop-up we opened
			arrive(ev.data, "pm");
		}
		function onStorage(ev) {
			if (ev && ev.key === resKey && ev.newValue) { var r = pj(ev.newValue); if (r) arrive(r, "st"); }
		}
		function onVis() { if (!hidden()) readMail("vis"); }
		function onShow() { readMail("show"); }
		function onFocus() { readMail("focus"); }
		function stop() {
			if (stopped) return;
			stopped = true;
			try { if (timer !== null && clrI) clrI(timer); } catch (x3) { /* none */ }
			try { if (target) { target.removeEventListener("message", onMessage); target.removeEventListener("storage", onStorage); target.removeEventListener("pageshow", onShow); target.removeEventListener("focus", onFocus); } } catch (x4) { /* none */ }
			try { if (doc) doc.removeEventListener("visibilitychange", onVis); } catch (x5) { /* none */ }
			try { if (bc) bc.close(); } catch (x6) { /* none */ }
		}
		h.stop = stop;
		h.state = state;
		h.count = function () { return count; };
		h.setWin = function (w) { win = w; };
		h.poke = function (via) { readMail(via || "poke"); };
		h.ack = function (via) {
			var m = { k: K_ACK, s: state, via: via || "" };
			try { if (bc) bc.postMessage(m); } catch (x7) { /* none */ }
			try { if (win && origin) win.postMessage(m, origin); } catch (x8) { /* none */ }
		};
		try {
			if (typeof e.BC === "function") {
				bc = new e.BC(k.chan);
				bc.onmessage = function (ev) {
					var d = ev && ev.data;
					if (!d || stopped) return;
					if (d.k === K_PING && d.s === state) { try { bc.postMessage({ k: K_PONG, s: state }); } catch (x9) { /* none */ } return; }
					arrive(d, "bc");
				};
			}
		} catch (x10) { bc = null; }
		try {
			if (target) { target.addEventListener("message", onMessage); target.addEventListener("storage", onStorage); target.addEventListener("pageshow", onShow); target.addEventListener("focus", onFocus); }
			if (doc) doc.addEventListener("visibilitychange", onVis);
			if (setI) timer = setI(function () { readMail("poll"); }, typeof opts.pollMs === "number" ? opts.pollMs : POLL_MS);
		} catch (x11) { /* a page without these: the other channels still work */ }
		if (typeof setTimeout === "function") setTimeout(function () { readMail("load"); }, 0); // an answer that is already in the mailbox
		return h;
	}

	// credentials ---------------------------------------------------------------------------------------------------------
	// A: OAuthProvider("google.com").credential({idToken, rawNonce}); B: GoogleAuthProvider.credential(idToken) (no nonce
	// sent along); T: GoogleAuthProvider.credential(null, accessToken). Each answer carries ONE id_token, and the Firebase
	// backend refuses to see the same credential twice, so a token goes into one strategy only; A and T are different
	// credentials, so trying T after A has failed is safe.
	function credOrder(mode, o) {
		o = o || {};
		var order = (mode === "A" || mode === "B" || mode === "T") ? [mode] : ((o.kind === "redirect" && o.aFailed) ? ["B", "T"] : ["A", "T"]);
		return order.filter(function (c) { return c !== "T" || (o.access !== false && o.ath !== "bad"); }); // an access token the id_token does not vouch for is not used
	}
	var FATAL = ["auth/network-request-failed", "auth/too-many-requests", "auth/user-disabled", "auth/operation-not-allowed",
		"auth/account-exists-with-different-credential", "auth/credential-already-in-use", "auth/email-already-in-use", "auth/unauthorized-domain"];
	function isFatal(e) { return FATAL.indexOf(codeOf(e)) >= 0; }
	function codeOf(e) { return String((e && (e.code || e.name || e.message)) || "?").slice(0, 60); }
	function exchange(opts) {
		opts = opts || {};
		var order = opts.order || ["A", "T"], results = { A: "skip", B: "skip", T: "skip" }, fatal = opts.fatal || isFatal, i = 0, last = null;
		return new Promise(function (resolve) {
			(function next() {
				if (i >= order.length) return resolve({ ok: false, cred: "none", results: results, error: last });
				var kind = order[i++], p;
				try { p = Promise.resolve(opts.attempt(kind)); } catch (e) { p = Promise.reject(e); }
				p.then(function (value) {
					results[kind] = "ok";
					resolve({ ok: true, cred: kind, results: results, value: value });
				}, function (err) {
					results[kind] = codeOf(err);
					last = err;
					if (fatal(err)) return resolve({ ok: false, cred: "none", results: results, error: err, fatal: true });
					next();
				});
			})();
		});
	}

	var api = {
		version: VERSION, prepare: prepare, authUrl: authUrl, keysFor: keysFor, parseState: parseState, parseParams: parseParams,
		relayParams: relayParams, relayState: relayState, jwtClaims: jwtClaims, validate: validate, checkAtHash: checkAtHash,
		reasonOf: reasonOf, savePending: savePending, readPending: readPending, listPending: listPending, listMail: listMail,
		readRelay: readRelay, markOwn: markOwn, isOwn: isOwn, clearFlow: clearFlow, sweep: sweep, claim: claim, listen: listen,
		credOrder: credOrder, exchange: exchange, codeOf: codeOf,
		kinds: { relay: K_RELAY, ack: K_ACK, ping: K_PING, pong: K_PONG }, endpoint: GOOGLE_AUTH
	};
	if (typeof module === "object" && module && module.exports) module.exports = api;
	try { if (typeof window !== "undefined" && window) window.glowOidc = api; } catch (e) { /* none */ }
})();
