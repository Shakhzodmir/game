// GLOW accounts and cloud save for the HTML5 build: Firebase Auth (Google, e-mail + password) and Firestore.
// The game (client/services/auth_web.lua) calls glowAuth.call(id, op, args) through html5.run and collects the
// finished operations with glowAuth.poll(): "<id>|<1|0>|<reason>|key=value&key=value" (values percent-encoded).
// Passwords are typed into the form below and go straight to the Firebase SDK; they never reach the game.
// The SDK is loaded from Google's CDN on first use, and only when web/auth_config.js is filled in.
// Google's window can go five ways (googleFlow() below; "firebase" is today's and the default everywhere): the SDK's own
// pop-up, the same with its "closed" signal ignored, our own request to Google in a window (web/glow_oidc.js, answered to
// web/auth_return.html), the same with the whole page going to Google, or no window at all. See docs/handoff/google-signin-ios.md.
(function () {
	"use strict";
	var cfg = window.GLOW_AUTH_CONFIG || {};
	var SDK_VERSION = "10.14.1";
	var SDK_BASE = "https://www.gstatic.com/firebasejs/" + SDK_VERSION + "/";
	var ID_DOMAIN = "id.glow.invalid";
	var RECENT_MS = 5 * 60 * 1000; // deleting an account needs a sign-in from the last five minutes
	var MAX_CODE = 200000;
	var VERSION = "2026-11-24a"; // printed in the small diagnostic line, so a screenshot says which script the phone runs
	var T_ = (window.glowAuth && window.glowAuth._test) || {};
	var POPUP_MS = T_.popupMs || 4 * 60 * 1000; // Google's window may stay open this long (a slow link, a code by SMS)
	var HOME_POPUP_MS = T_.homePopupMs || T_.popupMs || 90 * 1000; // an iPhone Home Screen app: the SDK cannot see that window, so less
	var LOOK_MS = T_.lookMs || 5 * 1000;           // after a window that went away: how long the account is watched
	var HOME_LOOK_MS = T_.homeLookMs || 12 * 1000; // ... in an iPhone Home Screen app, where nothing says what the window did
	var CANCEL_LOOK_MS = T_.cancelLookMs || 2 * 1000; // ... after our own Cancel of the waiting card
	var WAIT_CARD_MS = T_.waitCardMs || 10 * 1000; // a window that stays unanswered this long gets the waiting card (with Cancel)
	var SDK_MS = T_.sdkMs || 30 * 1000;         // the three SDK files must arrive within this

	var configured = !!(cfg.apiKey && cfg.authDomain && cfg.projectId);
	var results = [];
	var sdk = null;     // {auth, db, m: {module functions}}
	var sdkPromise = null;
	var formEl = null;

	function enc(fields) {
		return Object.keys(fields || {}).sort().map(function (k) {
			var v = fields[k];
			return k + "=" + encodeURIComponent(v == null ? "" : String(v));
		}).join("&");
	}
	function done(id, ok, reason, fields) {
		results.push(id + "|" + (ok ? 1 : 0) + "|" + (reason || "") + "|" + enc(fields));
	}

	// error -> the stable reason ids of client/services/auth.lua
	function reasonOf(e, ctx) {
		var c = (e && e.code) || "";
		// "cancelled" is silent in the game, so it is only for what the player did on purpose (our Cancel buttons, a second
		// window replacing the first). A Google window that simply went away (auth/popup-closed-by-user) is not the
		// same: on a phone it is also what a window that opened somewhere else and never came back looks like.
		if (c === "auth/cancelled-popup-request" || c === "auth/user-cancelled") return "cancelled";
		if (c === "auth/popup-closed-by-user" || c === "glow/cancel-waiting") return "popup_closed";
		if (c === "glow/oidc-denied") return "cancelled"; // "Cancel" on Google's own page (access_denied): the player's choice, silent
		if (c === "glow/popup-timeout") return "popup_timeout";
		if (c === "glow/no-window") return "home_app"; // the "no_window" way: this app has no usable Google window, so say what to do instead
		if (c === "glow/sdk-timeout") return "timeout";
		if (c === "auth/popup-blocked") return "popup_blocked";
		if (c === "glow/inapp-browser") return "inapp_browser";
		if (c === "auth/web-storage-unsupported" || c === "auth/operation-not-supported-in-this-environment") return "browser_unsupported";
		if (c === "auth/network-request-failed" || c === "unavailable" || c === "firestore/unavailable") return "offline";
		if (c === "auth/user-not-found" || c === "auth/wrong-password" || c === "auth/invalid-credential" ||
			c === "auth/invalid-login-credentials") {
			// a Google answer that Firebase refused is no "wrong ID or password" (that text is for the ID form)
			return e && e.glowOidc ? "error" : "bad_credentials";
		}
		if (c === "auth/email-already-in-use") return ctx === "link_email" ? "email_in_use" : "id_taken";
		if (c === "auth/weak-password") return "weak_password";
		if (c === "auth/invalid-email" || c === "auth/missing-email") return (ctx === "link_email" || ctx === "reset_password") ? "bad_email" : "bad_id";
		if (c === "auth/requires-recent-login") return "need_recent_login";
		if (c === "auth/credential-already-in-use" || c === "auth/provider-already-linked") return "already_linked";
		if (c === "auth/too-many-requests") return "too_many";
		if (c === "auth/operation-not-allowed") return "not_enabled";
		if (c === "auth/unauthorized-domain") return "bad_domain";
		if (c === "permission-denied" || c === "firestore/permission-denied") return "denied";
		if (c === "auth/user-token-expired" || c === "auth/user-disabled" || c === "auth/null-user") return "no_user";
		return "error";
	}

	// p, or a rejection with `code` when it takes longer than ms (the answer is still used if it comes later: see loadSdk)
	function timed(p, ms, code) {
		return new Promise(function (resolve, reject) {
			var t = setTimeout(function () { var e = new Error(code); e.code = code; reject(e); }, ms);
			if (t && t.unref) t.unref(); // node (tests): a waiting timer must not keep the process alive
			function stop() { if (typeof clearTimeout === "function") clearTimeout(t); }
			p.then(function (v) { stop(); resolve(v); }, function (e) { stop(); reject(e); });
		});
	}

	function loadSdk() {
		if (sdk) return Promise.resolve(sdk);
		if (sdkPromise) return sdkPromise;
		var loader = (window.glowAuth && window.glowAuth._test && window.glowAuth._test.sdk) ||
			function () {
				return Promise.all([
					import(SDK_BASE + "firebase-app.js"),
					import(SDK_BASE + "firebase-auth.js"),
					import(SDK_BASE + "firebase-firestore.js")
				]).then(function (mods) {
					// every export of the three modules lands in m, so m.sendPasswordResetEmail (firebase-auth) is there
					var m = {};
					[mods[0], mods[1], mods[2]].forEach(function (mod) { Object.keys(mod).forEach(function (k) { m[k] = mod[k]; }); });
					var app = m.initializeApp(cfg);
					return { m: m, auth: m.getAuth(app), db: m.getFirestore(app) };
				});
			};
		// A slow link (Uzbekistan, a train) must not leave the player with a silent tap: the wait is bounded, and a
		// late arrival still fills `sdk`, so the next tap does not start over.
		var loading = Promise.resolve().then(loader).then(function (s) { sdk = s; return s; });
		sdkPromise = timed(loading, SDK_MS, "glow/sdk-timeout");
		sdkPromise.catch(function () { sdkPromise = null; });
		return sdkPromise;
	}

	function pendingKey(uid) { return "glow_pending_email_" + uid; }
	function store(key, value) {
		try { if (value == null) localStorage.removeItem(key); else localStorage.setItem(key, value); } catch (e) { /* private mode */ }
	}
	function stored(key) {
		try { return localStorage.getItem(key) || ""; } catch (e) { return ""; }
	}

	function isSynthetic(email) {
		return typeof email === "string" && email.slice(-(ID_DOMAIN.length + 1)) === "@" + ID_DOMAIN;
	}
	function userFields(u) {
		if (!u) return {};
		var providers = (u.providerData || []).map(function (p) { return p.providerId; });
		var email = u.email || "";
		var pending = stored(pendingKey(u.uid));
		if (pending && pending === email) { store(pendingKey(u.uid), null); pending = ""; }
		return {
			uid: u.uid,
			kind: providers.indexOf("password") >= 0 ? "password" : "google",
			id: isSynthetic(email) ? email.slice(0, email.length - ID_DOMAIN.length - 1) : "",
			email: email,
			verified: u.emailVerified ? 1 : 0,
			google: providers.indexOf("google.com") >= 0 ? 1 : 0,
			gmail: ((u.providerData || []).filter(function (p) { return p.providerId === "google.com"; })[0] || {}).email || "",
			pending: pending,
			name: u.displayName || ""
		};
	}

	// the sign-in form ------------------------------------------------------------------------------------------

	// Keys and pointer events typed into the form must not reach the game engine's window listeners.
	function shield(e) {
		if (formEl && e.target && formEl.contains(e.target)) e.stopImmediatePropagation();
	}
	["keydown", "keyup", "keypress", "mousedown", "mouseup", "mousemove", "touchstart", "touchend", "touchmove", "wheel"]
		.forEach(function (t) { window.addEventListener(t, shield, true); });

	function labelsOf(args, from) {
		var l = {};
		for (var i = from; i + 1 < args.length; i += 2) l[args[i]] = args[i + 1];
		return l;
	}

	// kind: "login" | "register" | "email" | "reset" (the last two ask for an e-mail only).
	// Resolves {id, password} | {email} | null (cancelled).
	function showForm(kind, L) {
		var test = window.glowAuth && window.glowAuth._test;
		if (test && test.form) return Promise.resolve(test.form(kind, L));
		return new Promise(function (resolve) {
			var wrap = document.createElement("div");
			wrap.style.cssText = "position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483000;background:rgba(40,20,90,.6);" +
				"display:flex;align-items:center;justify-content:center;font-family:sans-serif;";
			var form = document.createElement("form");
			form.noValidate = true;
			form.style.cssText = "background:#fff;border-radius:18px;padding:20px;width:min(86vw,360px);box-sizing:border-box;" +
				"box-shadow:0 8px 30px rgba(0,0,0,.35);color:#3A2470;max-height:92vh;overflow:auto;";
			var inputs = {};
			function text(tag, content, css) {
				var el = document.createElement(tag);
				el.textContent = content || "";
				if (css) el.style.cssText = css;
				return el;
			}
			function field(name, type, label, autocomplete) {
				var box = text("label", label, "display:block;font-size:14px;margin:12px 0 4px;");
				var inp = document.createElement("input");
				inp.type = type; inp.name = name; inp.autocomplete = autocomplete;
				inp.autocapitalize = "none"; inp.spellcheck = false;
				inp.style.cssText = "display:block;width:100%;box-sizing:border-box;font-size:18px;padding:10px;" +
					"border:2px solid #E3D9FF;border-radius:10px;margin-top:4px;";
				box.appendChild(inp);
				form.appendChild(box);
				inputs[name] = inp;
			}
			form.appendChild(text("div", L.title || "", "font-size:20px;font-weight:bold;text-align:center;"));
			if (kind === "email" || kind === "reset") {
				field("email", "email", L.email || "E-mail", "email");
			} else {
				field("id", "text", L.id || "ID", "username");
				field("password", "password", L.password || "Password", kind === "register" ? "new-password" : "current-password");
				if (kind === "register") field("password2", "password", L.password2 || "Password", "new-password");
			}
			if (L.note) form.appendChild(text("div", L.note, "font-size:13px;margin-top:12px;color:#6b5a99;"));
			var err = text("div", "", "font-size:14px;color:#c0306a;margin-top:10px;min-height:18px;");
			form.appendChild(err);
			var row = text("div", "", "display:flex;gap:10px;margin-top:8px;");
			var cancel = text("button", L.cancel || "Cancel", "flex:1;padding:12px;font-size:16px;border:0;border-radius:12px;background:#E3D9FF;color:#3A2470;");
			cancel.type = "button";
			var ok = text("button", L.submit || "OK", "flex:1;padding:12px;font-size:16px;border:0;border-radius:12px;background:#6C4BD1;color:#fff;font-weight:bold;");
			ok.type = "submit";
			row.appendChild(cancel); row.appendChild(ok);
			form.appendChild(row);
			wrap.appendChild(form);
			formEl = wrap;
			document.body.appendChild(wrap);
			var first = inputs.id || inputs.email;
			if (first) setTimeout(function () { first.focus(); }, 50);

			function close(value) {
				if (!formEl) return;
				formEl = null;
				if (wrap.parentNode) wrap.parentNode.removeChild(wrap);
				var canvas = document.getElementById("canvas");
				if (canvas && canvas.focus) canvas.focus();
				resolve(value);
			}
			cancel.addEventListener("click", function () { close(null); });
			form.addEventListener("submit", function (ev) {
				ev.preventDefault();
				if (kind === "email" || kind === "reset") {
					var email = inputs.email.value.trim();
					if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { err.textContent = L.err_email || ""; return; }
					// an ID account's inner address can never receive mail: do not ask the provider to write to it
					if (kind === "reset" && isSynthetic(email.toLowerCase())) { err.textContent = L.err_email || ""; return; }
					return close({ email: email });
				}
				var id = inputs.id.value.trim().toLowerCase();
				var isMail = id.indexOf("@") >= 0;
				if (!(isMail || /^[a-z][a-z0-9_]{2,19}$/.test(id))) { err.textContent = L.err_id || ""; return; }
				if (kind === "register" && isMail) { err.textContent = L.err_id || ""; return; }
				var pw = inputs.password.value;
				if (pw.length < 8 || pw.length > 128) { err.textContent = L.err_pw || ""; return; }
				if (kind === "register" && pw !== inputs.password2.value) { err.textContent = L.err_pw2 || ""; return; }
				close({ id: id, password: pw });
			});
		});
	}

	// The environment the Google window has to live in ------------------------------------------------------------
	function isIOS() {
		var ua = navigator.userAgent || "";
		// iPadOS 13+ calls itself a Mac ("Macintosh") but has a touch screen; a real Mac has none
		return /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && (navigator.maxTouchPoints || 0) > 1);
	}
	// a Home Screen app: iOS says it with navigator.standalone, Android and the rest with the display-mode query (WebKit
	// bug 264218: an installed iOS web app can answer "fullscreen" there instead of "standalone")
	var standaloneMasked = false; // the "shim" way hides navigator.standalone from the SDK for a moment: this page still knows what it is
	function isStandalone() {
		try { if (standaloneMasked || navigator.standalone === true) return true; } catch (e) { /* no navigator */ }
		try {
			if (!window.matchMedia) return false;
			return ["standalone", "fullscreen", "minimal-ui"].some(function (k) { return !!window.matchMedia("(display-mode: " + k + ")").matches; });
		} catch (e2) { return false; }
	}
	function popupBound() { return isIOS() && isStandalone() ? HOME_POPUP_MS : POPUP_MS; }

	// Which way Google's sign-in goes -------------------------------------------------------------------------------------
	//   firebase       today's way: the SDK's own pop-up (signInWithPopup / linkWithPopup). Desktop and Android always use it.
	//   shim           the same SDK call, but the window it opens never reads "closed" (the SDK gives up on that after 2 s)
	//   oidc_popup     our own request to Google in a window; Google answers to web/auth_return.html, which hands the answer over
	//                  without needing the link to the opener (web/glow_oidc.js), and Firebase gets a credential from it
	//   oidc_redirect  the same, with the whole page going to Google and coming back (finished by "restore" after the reload)
	//   no_window      an iPhone Home Screen app only: no window at all, the call fails at once with "home_app"
	// The default is chosen per kind of page by web/auth_config.js (googleIos for a Safari tab, googleIosHome for the Home
	// Screen app; absent or unknown = "firebase"), so nothing changes for anybody until a key is flipped there. For trying a
	// way on one device without a release: ?google=<way> in the address (for this page; on an iPhone or iPad it is also kept
	// for 7 days), ?google=auto forgets it. Only the NAME of a way ever comes from the address or from storage.
	var FLOWS = ["firebase", "shim", "oidc_popup", "oidc_redirect", "no_window"];
	var FLOW_KEY = "glow_google_flow"; // {f: way, t: ms}
	var FLOW_KEEP_MS = 7 * 24 * 3600 * 1000;
	function goodFlow(v) { return typeof v === "string" && FLOWS.indexOf(v) >= 0 ? v : ""; }
	function queryParam(name) {
		try {
			var parts = String(window.location.search || "").replace(/^\?/, "").split("&"), i, kv;
			for (i = 0; i < parts.length; i++) {
				kv = parts[i].split("=");
				if (kv[0] === name) return decodeURIComponent((kv[1] || "").replace(/\+/g, " "));
			}
		} catch (e) { /* no address (tests), or a broken escape */ }
		return "";
	}
	var urlFlow = (function () {
		var raw = queryParam("google");
		if (!raw) return "";
		if (raw === "auto") { store(FLOW_KEY, null); return ""; }
		var f = goodFlow(raw);
		if (f && isIOS()) store(FLOW_KEY, JSON.stringify({ f: f, t: Date.now() })); // kept for the next loads of this phone only
		return f;
	})();
	function savedFlow() {
		if (!isIOS()) return ""; // a saved choice never pins a desktop or an Android phone
		var raw = stored(FLOW_KEY), o = null, f, t;
		if (!raw) return "";
		try { o = JSON.parse(raw); } catch (e) { o = null; }
		f = o && goodFlow(o.f); t = o && Number(o.t);
		if (!f || !(t > 0) || Date.now() - t > FLOW_KEEP_MS || t - Date.now() > 60000) { store(FLOW_KEY, null); return ""; }
		return f;
	}
	function envFlow() {
		if (!isIOS()) return "firebase";
		return goodFlow(isStandalone() ? cfg.googleIosHome : cfg.googleIos) || "firebase";
	}
	// our own sign-in needs: the shared core, the public identifiers, a return page of THIS origin, crypto.subtle (https only),
	// and storage that works (the answer travels through it)
	function oidcUsable() {
		try {
			var loc = window.location, ret = String(cfg.googleReturn || "");
			if (!(window.glowOidc && cfg.googleClientId && ret && loc && loc.origin && ret.indexOf(loc.origin + "/") === 0)) return false;
			if (!(window.crypto && window.crypto.subtle)) return false;
			localStorage.setItem("glow_probe", "1"); localStorage.removeItem("glow_probe");
			sessionStorage.setItem("glow_probe", "1"); sessionStorage.removeItem("glow_probe");
			return true;
		} catch (e) { return false; }
	}
	function googleFlow() {
		var f = urlFlow || savedFlow() || envFlow();
		if ((f === "oidc_popup" || f === "oidc_redirect") && !oidcUsable()) return "firebase";
		if (f === "no_window" && !(isIOS() && isStandalone())) return "firebase";
		return f;
	}

	// the texts of the page's own pieces (the tap card, the "checking" line); the game's texts are in client/i18n.lua.
	// The game says its language with every Google call (gameLang); the page's <html lang> is always "en" here, so it
	// comes last, after the device's language.
	var gameLang = "";
	function words() {
		var lang = (gameLang || navigator.language || document.documentElement.lang || "en").slice(0, 2);
		return { ru: ["Продолжить с Google", "Отмена", "Ждём ответ от Google…", "Проверяю, вошли ли вы…", "Переходим на страницу Google…"],
			ko: ["Google로 계속하기", "취소", "Google 응답을 기다리는 중…", "로그인 확인 중…", "Google 페이지로 이동하는 중…"] }[lang] ||
			["Continue with Google", "Cancel", "Waiting for Google…", "Checking whether you signed in…", "Going to Google…"];
	}
	function displayKind() {
		try { if (standaloneMasked || navigator.standalone === true) return "home"; } catch (e) { /* no navigator */ }
		try { if (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) return "home"; } catch (e2) { /* none */ }
		if (isStandalone()) return isIOS() ? "home" : "full"; // iOS reports an installed app as "fullscreen" in some versions
		return "tab";
	}
	function envLabel() {
		var ua = navigator.userAgent || "";
		return (isIOS() ? "ios" : /Android/.test(ua) ? "android" : "desktop") + "-" + displayKind();
	}

	// Google refuses its sign-in page inside the built-in browsers of messengers and social apps (Telegram, Instagram,
	// KakaoTalk, ...: "403 disallowed_useragent"), and the pop-up cannot report back from them. Such a browser is
	// recognised before the window opens, and the game says to open the link in Safari or Chrome instead.
	function inAppBrowser() {
		var test = window.glowAuth && window.glowAuth._test;
		if (test && test.inapp != null) return !!test.inapp;
		var ua = navigator.userAgent || "";
		if (/FBAN|FBAV|FB_IAB|Instagram|KAKAOTALK|NAVER\(|Line\/|MicroMessenger|Telegram|TikTok|musical_ly|Snapchat|Twitter|; wv\)/i.test(ua)) return true;
		if (window.TelegramWebviewProxy || window.TelegramWebview) return true;
		// an iPhone / iPad page that is not Safari, Chrome, Firefox, Edge... (all of them say "Safari/") and not a Home
		// Screen app: a web view of an app (also on an iPad that calls itself a Mac)
		if (isIOS() && !isStandalone() && !/Safari\//.test(ua)) return true;
		return false;
	}

	// Safari (every iPhone and iPad browser) opens a window only inside the tap itself, and the game calls from its own
	// frame loop, never inside the tap. So on iOS the sign-in asks for a real page tap FIRST ("Continue with Google").
	// Elsewhere the call is tried at once (Chrome keeps a tap alive for about five seconds) and the same card appears
	// when the browser refuses (auth/popup-blocked). The card stays up while Google's window is open (with "Cancel"),
	// and the wait is bounded: a window that never reports back (a Home Screen app on iOS can lose it) ends as
	// "popup_timeout" in POPUP_MS, not as a game that waits ten minutes with nothing on the screen.
	function needsTap() {
		if (isIOS()) return true;
		var ua = navigator.userActivation; // Chrome, Firefox, Safari 16.4+: is the player's tap still alive?
		return !!(ua && ua.isActive === false);
	}

	// The card is a real page button over the game: "Continue with Google" + "Cancel"; once a window is out the green
	// button is disabled and says "Waiting for Google…" (Cancel stays).
	function buildCard() {
		var T = words();
		var wrap = document.createElement("div");
		wrap.style.cssText = "position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483000;background:rgba(40,20,90,.6);" +
			"display:flex;align-items:center;justify-content:center;font-family:sans-serif;";
		var box = document.createElement("div");
		box.style.cssText = "background:#fff;border-radius:18px;padding:20px;width:min(86vw,340px);box-sizing:border-box;text-align:center;";
		var go = document.createElement("button");
		go.type = "button"; go.textContent = T[0];
		go.style.cssText = "display:block;width:100%;padding:14px;font-size:18px;font-weight:bold;border:0;border-radius:12px;background:#2BC98A;color:#fff;";
		var no = document.createElement("button");
		no.type = "button"; no.textContent = T[1];
		no.style.cssText = "display:block;width:100%;padding:12px;font-size:16px;border:0;border-radius:12px;background:#E3D9FF;color:#3A2470;margin-top:10px;";
		box.appendChild(go); box.appendChild(no); wrap.appendChild(box);
		formEl = wrap;
		document.body.appendChild(wrap);
		var ft = setTimeout(function () { if (wrap.parentNode) { try { go.focus(); } catch (e) { /* none */ } } }, 50); // keyboard users
		if (ft && ft.unref) ft.unref(); // node (tests)
		return {
			go: go, no: no,
			wait: function (text) { go.disabled = true; go.textContent = text || T[2]; go.style.background = "#9C87E0"; },
			again: function () { go.disabled = false; go.textContent = T[0]; go.style.background = "#2BC98A"; },
			remove: function () {
				if (formEl === wrap) formEl = null;
				if (wrap.parentNode) wrap.parentNode.removeChild(wrap);
				var cv = document.getElementById("canvas"); // the game takes the keys back
				if (cv && cv.focus) { try { cv.focus(); } catch (e) { /* none */ } }
			}
		};
	}

	function cancelError(waiting) {
		var c = new Error(waiting ? "closed" : "cancelled");
		c.code = waiting ? "glow/cancel-waiting" : "auth/user-cancelled"; // not the SDK's own "closed" code: a screenshot tells them apart
		c.glowCancel = true; // our own button: the account is looked at only briefly
		return c;
	}

	function tapThenOpen(run, waitText) {
		var test = window.glowAuth && window.glowAuth._test;
		if (test && test.gesture) return test.gesture(run);
		return new Promise(function (resolve, reject) {
			var card = buildCard();
			var over = false, waiting = false, retried = false;
			// a card nobody taps is not kept for ever (the game has stopped waiting by then): it goes as a plain "no"
			var idle = setTimeout(function () {
				if (waiting) return;
				var c = new Error("cancelled"); c.code = "auth/user-cancelled";
				end(reject, c);
			}, POPUP_MS);
			if (idle && idle.unref) idle.unref();
			function end(settle, value) {
				if (over) return;
				over = true;
				if (typeof clearTimeout === "function") clearTimeout(idle);
				card.remove();
				settle(value);
			}
			card.go.addEventListener("click", function () {
				if (over || waiting) return;
				waiting = true;
				card.wait(waitText);
				var p;
				try { p = run(); } catch (e) { return end(reject, e); } // inside the tap: this is the call that may open a window
				p.then(function (v) { end(resolve, v); }, function (e) {
					// refused inside the tap (a cold auth iframe on an iPad's Chrome, a slow link): the card stays for one more tap
					if (e && e.code === "auth/popup-blocked" && !retried && !over) { retried = true; waiting = false; card.again(); return; }
					end(reject, e);
				});
			});
			card.no.addEventListener("click", function () { end(reject, cancelError(waiting)); });
		});
	}

	// Where the window may be opened at once (desktop, Android with a live tap) there is no card at first. A window that
	// stays unanswered for WAIT_CARD_MS (left behind the game, a tab in the switcher) gets the waiting card with Cancel, so
	// the game never looks dead and refuses a second tap as "busy" until the bound.
	function runWithWaitCard(run) {
		var p;
		try { p = run(); } catch (e) { return Promise.reject(e); }
		return new Promise(function (resolve, reject) {
			var card = null, over = false;
			var timer = setTimeout(function () {
				if (over) return;
				card = buildCard();
				card.wait();
				card.no.addEventListener("click", function () { finish(reject, cancelError(true)); });
			}, WAIT_CARD_MS);
			if (timer && timer.unref) timer.unref();
			function finish(settle, value) {
				if (over) return;
				over = true;
				if (typeof clearTimeout === "function") clearTimeout(timer);
				if (card) card.remove();
				settle(value);
			}
			p.then(function (v) { finish(resolve, v); }, function (e) { finish(reject, e); });
		});
	}

	function codeError(code, message) { var e = new Error(message || code); e.code = code; return e; }

	// One try of Google's window, with the things that must be undone when it ends (a listener, a record of the attempt, the
	// window itself): every way but "firebase" registers them here, and withGesture ends the try whatever way it ends.
	function newTry(flow) {
		var t = { flow: flow, over: false, stops: [], exchanging: false, win: null };
		t.onEnd = function (fn) { t.stops.push(fn); };
		t.end = function (ok) {
			if (t.over) return;
			t.over = true;
			var fns = t.stops, i;
			t.stops = [];
			for (i = 0; i < fns.length; i++) { try { fns[i](ok); } catch (e) { /* the rest still run */ } }
		};
		return t;
	}

	// open(try) starts Google's sign-in and returns a promise; it is called inside the player's tap where the browser needs
	// that, so nothing asynchronous may come before the window opens. flow: which way (googleFlow()). The bounds of the SDK's
	// own window (HOME_POPUP_MS in an iPhone Home Screen app) are for "firebase" only: the other ways keep what Google answers.
	function withGesture(open, flow) {
		if (inAppBrowser()) { var ia = new Error("in-app browser"); ia.code = "glow/inapp-browser"; return Promise.reject(ia); }
		var cur = null;
		function run() {
			if (cur) cur.end(false); // a first try the browser refused is undone before the second one
			cur = newTry(flow);
			return timed(open(cur), flow === "firebase" ? popupBound() : POPUP_MS, "glow/popup-timeout");
		}
		var p, going = flow === "oidc_redirect" ? words()[4] : undefined; // the whole page leaves: the card says so
		if (needsTap()) p = tapThenOpen(run, going);
		else p = runWithWaitCard(run).catch(function (e) {
			if (!e || e.code !== "auth/popup-blocked") throw e;
			return tapThenOpen(run, going);
		});
		return p.then(function (v) { if (cur) cur.end(true); return v; }, function (e) {
			if (e && typeof e === "object" && cur) e.glowTry = cur; // afterGoogleFailure: was an exchange under way?
			if (cur) cur.end(false);
			throw e;
		});
	}

	// The SDK's own pop-up with its window's "closed" signal ignored (the "shim" way). The SDK calls window.open once, a
	// moment after signInWithPopup / linkWithPopup is called (it first waits for its helper frame), then asks every 2 s
	// whether the window is closed and gives up 8 s after the first "yes"; on some iPhones it reads "yes" 2 s after the
	// window opened while the window is alive. That one call gets the real window inside a stand-in that never says closed;
	// everything is put back right after, or after 10 s if the SDK never called. In an iPhone Home Screen app the SDK clicks
	// a hidden link instead of calling window.open (navigator.standalone), so that flag reads false until the call is made.
	var SHIM_SAFETY_MS = T_.shimSafetyMs || 10 * 1000;
	function shimmed(call) {
		var realOpen = window.open, wrapped = null, masked = false, had = null, done = false, safety = null;
		function undo() {
			if (done) return;
			done = true;
			if (window.open === wrapped) window.open = realOpen;
			if (masked) {
				masked = false;
				standaloneMasked = false;
				try { if (had) Object.defineProperty(navigator, "standalone", had); else delete navigator.standalone; } catch (e) { /* none */ }
			}
			if (safety && typeof clearTimeout === "function") clearTimeout(safety);
		}
		wrapped = function () {
			undo(); // one shot: only the SDK's own call is wrapped
			var w = realOpen.apply(window, arguments);
			if (!w) return w; // refused: the SDK then says auth/popup-blocked as usual
			return {
				get closed() { return false; },
				close: function () { try { w.close(); } catch (e) { /* none */ } },
				focus: function () { try { w.focus(); } catch (e) { /* none */ } }
			};
		};
		try {
			if (isIOS() && navigator.standalone === true) {
				had = Object.getOwnPropertyDescriptor(navigator, "standalone") || null;
				Object.defineProperty(navigator, "standalone", { configurable: true, get: function () { return false; } });
				masked = true;
				standaloneMasked = true;
			}
		} catch (e1) { masked = false; }
		window.open = wrapped;
		safety = setTimeout(undo, SHIM_SAFETY_MS);
		if (safety && safety.unref) safety.unref(); // node (tests)
		var p;
		try { p = call(); } catch (e2) { undo(); throw e2; }
		p.then(undo, undo); // answered or refused: nothing of ours stays on the page
		return p;
	}

	// After a Google window that went away -------------------------------------------------------------------------
	// The SDK reports "window closed" 8 s after the fact even when the sign-in is still being finished (firebase-js-sdk
	// issue 10407), and on a slow link it finishes later still. So before "failed" is said, the account is watched for a
	// few seconds: a user with Google that was not there before (sign-in), or Google newly linked to the current user.
	function hasGoogle(u) { return !!u && (u.providerData || []).some(function (p) { return p.providerId === "google.com"; }); }
	function snapshot(s) { var u = s.auth.currentUser; return { uid: u ? u.uid : "", google: hasGoogle(u) }; }
	function finished(s, before, linking) {
		var u = s.auth.currentUser;
		if (!hasGoogle(u)) return null;
		// linking: Google appeared on the SAME user (a different user is somebody else's sign-in, not our link)
		if (linking) return (u.uid === before.uid && !before.google) ? u : null;
		return u.uid !== before.uid ? u : null;
	}
	function lookAgain(s, before, linking, ms) {
		return new Promise(function (resolve) {
			var end = Date.now() + ms;
			(function look() {
				var u = finished(s, before, linking);
				if (u) return resolve(u);
				if (Date.now() >= end) return resolve(null);
				var t = setTimeout(look, Math.min(400, Math.max(10, end - Date.now())));
				if (t && t.unref) t.unref(); // node (tests)
			})();
		});
	}
	function afterGoogleFailure(s, before, linking, e, flow) {
		var c = (e && e.code) || "";
		if (c !== "auth/popup-closed-by-user" && c !== "glow/cancel-waiting" && c !== "glow/popup-timeout") throw e;
		// our own ways (oidc_*) have nothing that can finish late, unless the answer was already being exchanged for a sign-in
		if ((flow === "oidc_popup" || flow === "oidc_redirect") && !(e.glowTry && e.glowTry.exchanging)) throw e;
		// how long the account is watched: our own Cancel briefly; where the SDK itself sees the window (it already waited
		// about 8 s after the close) a few seconds; in an iPhone Home Screen app, where nothing says what happened, longer
		// (only the SDK's own window: the other ways keep the same bound everywhere)
		var ms = e.glowCancel ? CANCEL_LOOK_MS : (flow === "firebase" && isIOS() && isStandalone() ? HOME_LOOK_MS : LOOK_MS);
		var gone = note(words()[3], ms + 500);
		return lookAgain(s, before, linking, ms).then(function (u) {
			gone();
			if (u) return userFields(u);
			throw e;
		});
	}

	// operations ------------------------------------------------------------------------------------------------

	// The uid the game was last TOLD about ("" = nobody; null until it has heard anything). A Google window we gave up on
	// (our Cancel, the bound) can still finish later and silently change the SDK's current user; the game would go on
	// as the old account while cloud reads, writes and deletes hit the new one's document. So account operations refuse
	// a current user the game does not know (the answer is "no_user"; the next start restores the real account).
	var told = null;
	function needUser(s) {
		var u = s.auth.currentUser;
		if (!u || (told !== null && u.uid !== told)) { var e = new Error("no user"); e.code = "auth/null-user"; throw e; }
		return u;
	}
	function docRef(s, u) { return s.m.doc(s.db, "saves", u.uid); }

	function offline() { return typeof navigator !== "undefined" && navigator.onLine === false; }

	// Our own sign-in with Google -----------------------------------------------------------------------------------------------
	// Google is asked directly (web/glow_oidc.js builds the request and checks the answer) and answers to web/auth_return.html,
	// a page of OUR origin that hands the answer over through storage, a broadcast channel and, when the link is alive,
	// window.opener. Nothing needs the link, a server of ours or third-party storage. The checked tokens become a Firebase
	// credential (signInWithCredential / linkWithCredential). A try is: prepare the secrets BEFORE the tap, and inside the tap
	// save the attempt, arm the receivers, open the one window, mark it ours; then wait; then exchange.
	var OIDC_RESPONSE = T_.oidcResponse || "id_token token"; // what Google is asked for: "id_token" once credential A is proven on the phone, "token" as a last resort
	var OIDC_CRED = T_.oidcCred || "auto";                   // "auto" = A, and T when the nonce was the problem; or "A" | "B" | "T"
	var FLUSH_MS = T_.flushMs || 800;                        // before the page leaves for Google: the game's last save reaches IndexedDB
	var RESTORE_MS = T_.restoreMs || 20 * 1000;              // finishing an answer that came back with a reload
	var INSTANCE = Math.random().toString(36).slice(2, 10) + Date.now().toString(36); // this page load: who has claimed an attempt
	var prep = { p: null, r: null }, prepGoing = { p: null, r: null };
	function ensurePrep(mode) {
		if (prep[mode]) return Promise.resolve(prep[mode]);
		if (!prepGoing[mode]) {
			prepGoing[mode] = window.glowOidc.prepare({ dest: "g", mode: mode, responseType: OIDC_RESPONSE }).then(function (rec) {
				prep[mode] = rec; prepGoing[mode] = null; return rec;
			}, function (e) { prepGoing[mode] = null; throw e; });
		}
		return prepGoing[mode];
	}
	function takePrep(mode) { // synchronous: the tap must not wait for anything
		var rec = prep[mode];
		prep[mode] = null;
		if (rec) ensurePrep(mode).then(null, function () { /* the next try asks again and says why */ });
		return rec;
	}

	// continue past credential A only when the nonce was what Firebase refused
	function oidcFatal(e) { return ((e && e.code) || "") !== "auth/missing-or-invalid-nonce"; }
	function oidcOrder(v, ath) {
		return window.glowOidc.credOrder(OIDC_CRED, { kind: "popup", aFailed: false, access: !!v.accessToken, ath: ath })
			.filter(function (k) { return k !== "T" || ath === "ok" || v.tokenOnly; }); // T only when the id_token vouches for the access token
	}
	function oidcCredential(s, kind, v, rec) {
		if (kind === "A") return new s.m.OAuthProvider("google.com").credential({ idToken: v.idToken, rawNonce: rec.r });
		if (kind === "B") return s.m.GoogleAuthProvider.credential(v.idToken);
		return s.m.GoogleAuthProvider.credential(null, v.accessToken);
	}
	// the answer of Google (a relay) -> checked -> a Firebase credential -> the signed-in account's fields. linkUser = the
	// account the game told us about when it asked to link, or null for a sign-in.
	function oidcExchange(s, relay, rec, linkUser) {
		var G = window.glowOidc, v = G.validate(relay, rec, { clientId: cfg.googleClientId });
		if (!v.ok) return Promise.reject(codeError(v.code, v.check));
		return G.checkAtHash(v.claims, v.accessToken).then(function (ath) {
			var order = oidcOrder(v, ath);
			if (!order.length) throw codeError("glow/oidc-nocred");
			return G.exchange({ order: order, fatal: oidcFatal, attempt: function (kind) {
				var cred = oidcCredential(s, kind, v, rec);
				if (!linkUser) return s.m.signInWithCredential(s.auth, cred);
				var cu = needUser(s); // the game must still know this account: nobody else is linked to
				if (cu.uid !== linkUser.uid) throw codeError("auth/null-user");
				return s.m.linkWithCredential(cu, cred);
			} }).then(function (x) {
				if (!x.ok) {
					var e = x.error && typeof x.error === "object" ? x.error : codeError(String(x.error || "glow/oidc-credential"));
					e.glowOidc = true;
					e.glowDetail = "A=" + x.results.A + (x.results.B !== "skip" ? " B=" + x.results.B : "") + (x.results.T !== "skip" ? " T=" + x.results.T : "");
					throw e;
				}
				var cur = s.auth.currentUser; // the account now signed in is the one this answer made
				if (linkUser) { if (!cur || cur.uid !== linkUser.uid) throw codeError("auth/null-user"); return userFields(cur); }
				if (!cur || !x.value || !x.value.user || cur.uid !== x.value.user.uid) throw codeError("auth/null-user");
				return userFields(cur);
			});
		});
	}

	// Called inside the tap (or at once where the browser lets a window open). Nothing asynchronous comes before window.open /
	// location.assign: the attempt is saved, the receivers are armed, the one window is opened, the page marks it is the starter.
	function oidcStart(s, mode, linkUser, tr) {
		var G = window.glowOidc, rec = takePrep(mode);
		if (!rec) return Promise.reject(codeError("auth/popup-blocked", "no attempt is ready")); // the one more tap of the card
		G.sweep("g", {}); // old answers and attempts of earlier tries
		rec.t = Date.now(); // an attempt ages from the tap, not from when its secrets were made
		rec.w = INSTANCE;
		rec.c = (function () { try { return navigator.standalone === true ? "home" : "tab"; } catch (e) { return "tab"; } })(); // the return page's rule for a Home Screen app
		rec.op = linkUser ? "link" : "in";
		if (linkUser) rec.u = linkUser.uid;
		G.savePending(rec, {}, { shared: false });
		var url = G.authUrl({ clientId: cfg.googleClientId, redirectUri: cfg.googleReturn, responseType: rec.rt, nonce: rec.n, state: rec.s });
		return new Promise(function (resolve, reject) {
			var h = G.listen({ dest: "g", state: rec.s, win: null, onRelay: function (relay, via) {
				if (tr.over || tr.exchanging) return;
				tr.exchanging = true;
				try { h.ack(via); } catch (e) { /* none */ }
				oidcExchange(s, relay, rec, linkUser).then(resolve, reject);
			} });
			tr.onEnd(function (ok) {
				h.stop();
				G.clearFlow("g", rec.s, {}); // the attempt, its answer and its marker: nothing late can sign anybody in
				if (!ok) { try { if (tr.win) tr.win.close(); } catch (e) { /* none */ } }
			});
			if (mode === "p") {
				var w = null;
				try { w = window.open(url, "glow_oidc_" + rec.s.slice(-6)); } catch (e) { w = null; }
				G.markOwn("g", rec.s, {}); // right AFTER window.open: a window opened from here has a copy of this storage made before this line
				if (!w) { // refused: nothing was shown to Google, the attempt is dropped, and the card keeps one more tap
					h.stop(); G.clearFlow("g", rec.s, {});
					return reject(codeError("auth/popup-blocked", "window.open gave nothing"));
				}
				tr.win = w;
				h.setWin(w);
				return;
			}
			// the whole page goes to Google. The receivers stay armed: a live page answers the return page's ping, and that is
			// what keeps a window that did not start this from loading a second copy of the game over the same save.
			G.markOwn("g", rec.s, {}); // right BEFORE the page leaves
			function onShow(ev) { // back from Google by the Back button (the page came from the cache): nothing is coming
				if (!ev || !ev.persisted) return;
				var t1 = setTimeout(function () {
					if (tr.over || tr.exchanging || G.readRelay("g", rec.s, {})) return;
					reject(codeError("auth/user-cancelled", "back from Google without an answer"));
				}, 800);
				if (t1 && t1.unref) t1.unref();
			}
			try { window.addEventListener("pageshow", onShow); } catch (e) { /* none */ }
			tr.onEnd(function () { try { window.removeEventListener("pageshow", onShow); } catch (e) { /* none */ } });
			var go = setTimeout(function () {
				if (tr.over) return;
				try { window.location.assign(url); } catch (e) { reject(codeError("glow/oidc-assign", "could not leave for Google")); }
			}, FLUSH_MS);
			if (go && go.unref) go.unref();
		});
	}
	// the whole operation: the secrets are ready before the card, then the usual tap -> window -> wait, then the same aftercare
	function oidcRun(s, flow, before, linkUser) {
		var mode = flow === "oidc_redirect" ? "r" : "p";
		return ensurePrep(mode).then(function () {
			return withGesture(function (tr) { return oidcStart(s, mode, linkUser, tr); }, flow);
		}).then(function (fields) { return fields; }, function (e) {
			// Google was linked after all (a try that finished late): that is what the player asked for
			if (linkUser && e && e.code === "auth/provider-already-linked" && hasGoogle(s.auth.currentUser)) return userFields(s.auth.currentUser);
			return afterGoogleFailure(s, before, !!linkUser, e, flow);
		});
	}

	// An answer that came back while this page was away: the whole-page way (the page left for Google and the return page loaded
	// it again), a window that went back to the starter's own window (iOS put the return where the starter was), or a tab that
	// was discarded and reloaded while Google's window was open. Only an attempt of THIS window (its own sessionStorage, its own
	// marker) with its answer already in the mailbox is finished; another tab's attempt is never touched. Never throws, never
	// waits longer than RESTORE_MS. Resolves "ok", "linked", a reason id (the answer failed; "cancelled" is silent), or null
	// when there was nothing to finish. first = the account the SDK restored (null for nobody), for an attempt to link.
	function finishReturn(s, first) {
		return new Promise(function (resolve) {
			var G = window.glowOidc, rec = null, relay = null, t0 = Date.now(), done = false, timer = null;
			function finish(ret, code) {
				if (done) return;
				done = true;
				if (timer && typeof clearTimeout === "function") clearTimeout(timer);
				try { if (rec) G.clearFlow("g", rec.s, {}); } catch (e) { /* none */ }
				if (code && ret !== "cancelled") {
					note("google " + String(code).slice(0, 60) + " " + envLabel() + " " + Math.round((Date.now() - t0) / 1000) + "s v" + VERSION + " " + googleFlow(), 15000);
				}
				resolve(ret);
			}
			try {
				if (!G) return resolve(null);
				G.sweep("g", {}); // answers older than two minutes and attempts older than fifteen go
				var mine = G.readPending("g", "", {});
				if (!mine || mine.src !== "ss" || !mine.rec || !mine.rec.r || !G.isOwn("g", mine.rec.s, {})) return resolve(null);
				rec = mine.rec;
				relay = G.readRelay("g", rec.s, {});
			} catch (e) { return resolve(null); }
			if (!relay) {
				// no answer: the whole page went to Google and came back without one (the Back button, an error page of Google's), or an
				// attempt that is too old to be answered. A young window attempt may still be answered by its window: left alone.
				if (rec.m === "r" || Date.now() - (rec.t || 0) > POPUP_MS) return finish("cancelled");
				rec = null;
				return resolve(null);
			}
			if (!G.claim("g", rec.s, {}, { by: INSTANCE })) { rec = null; return resolve(null); } // another page of this window is on it
			var linkUser = null;
			if (rec.op === "link") {
				if (!first || first.uid !== rec.u) return finish("error", "glow/oidc-link-user"); // the account that asked is not the one signed in now
				linkUser = first;
			}
			timer = setTimeout(function () { finish("timeout", "glow/restore-timeout"); }, RESTORE_MS);
			if (timer && timer.unref) timer.unref(); // node (tests)
			oidcExchange(s, relay, rec, linkUser).then(function () { finish(linkUser ? "linked" : "ok"); }, function (e) {
				if (linkUser && e && e.code === "auth/provider-already-linked" && hasGoogle(s.auth.currentUser)) return finish("linked");
				var why = reasonOf(e, linkUser ? "link_google" : "sign_in_google");
				finish(why, why === "cancelled" ? "" : String((e && (e.code || e.message)) || "?") + (e && e.glowDetail ? " " + e.glowDetail : ""));
			});
		});
	}

	function isOidc(flow) { return flow === "oidc_popup" || flow === "oidc_redirect"; }
	// the way for THIS call; an in-app browser gets no Google whatever the settings say, and "no_window" fails at once
	function chooseFlow() {
		if (inAppBrowser()) throw codeError("glow/inapp-browser", "in-app browser");
		var flow = googleFlow();
		if (flow === "no_window") throw codeError("glow/no-window", "no window");
		return flow;
	}

	var OPS = {
		// the account of an earlier run; first, an answer of Google that came back with a reload is finished (finishReturn). The
		// answer carries "ret" when there was one: ok | linked | a reason id (the game does not read it yet; the dark line says it)
		restore: function (s) {
			return new Promise(function (resolve) {
				var off = s.m.onAuthStateChanged(s.auth, function (u) {
					off();
					finishReturn(s, u).then(null, function () { return null; }).then(function (ret) { // whatever happens there, the start goes on
						var f = userFields(ret ? s.auth.currentUser : u);
						if (ret) f.ret = ret;
						resolve(f);
					});
				});
			});
		},
		sign_in_google: function (s, args) {
			gameLang = (args && args[0]) || gameLang;
			var flow = chooseFlow();
			var before = snapshot(s);
			if (isOidc(flow)) return oidcRun(s, flow, before, null);
			var open = function () { return s.m.signInWithPopup(s.auth, new s.m.GoogleAuthProvider()); };
			return withGesture(flow === "shim" ? function () { return shimmed(open); } : open, flow)
				.then(function (r) { return userFields(r.user); }, function (e) { return afterGoogleFailure(s, before, false, e, flow); });
		},
		password_form: function (s, args) {
			var mode = args[0] === "register" ? "register" : "login";
			return showForm(mode, labelsOf(args, 1)).then(function (v) {
				if (!v) { var e = new Error("cancelled"); e.code = "auth/user-cancelled"; throw e; }
				var email = v.id.indexOf("@") >= 0 ? v.id : v.id + "@" + ID_DOMAIN;
				var p = mode === "register" ? s.m.createUserWithEmailAndPassword(s.auth, email, v.password)
					: s.m.signInWithEmailAndPassword(s.auth, email, v.password);
				return p.then(function (r) { return userFields(r.user); });
			});
		},
		link_google: function (s, args) {
			gameLang = (args && args[0]) || gameLang;
			var u = needUser(s);
			var flow = chooseFlow();
			var before = snapshot(s);
			if (isOidc(flow)) return oidcRun(s, flow, before, u);
			var open = function () { return s.m.linkWithPopup(u, new s.m.GoogleAuthProvider()); };
			return withGesture(flow === "shim" ? function () { return shimmed(open); } : open, flow)
				.then(function () { return userFields(s.auth.currentUser); }, function (e) {
					// Google was linked after all (a window finished late): that is what the player asked for
					if (e && e.code === "auth/provider-already-linked" && hasGoogle(s.auth.currentUser)) return userFields(s.auth.currentUser);
					return afterGoogleFailure(s, before, true, e, flow);
				});
		},
		link_email_form: function (s, args) {
			var u = needUser(s);
			return showForm("email", labelsOf(args, 0)).then(function (v) {
				if (!v) { var e = new Error("cancelled"); e.code = "auth/user-cancelled"; throw e; }
				return s.m.verifyBeforeUpdateEmail(u, v.email).then(function () {
					store(pendingKey(u.uid), v.email);
					return userFields(u);
				});
			});
		},
		// "Forgot the password": no sign-in needed. args[0] = the letter's language (ru | en | ko), then the form labels.
		// The answer never says whether the address has an account: Firebase answers "sent" either way while its
		// e-mail enumeration protection is on, and "user-not-found" from a project without it is turned into success.
		reset_password: function (s, args) {
			var lang = /^(ru|en|ko)$/.test(args[0]) ? args[0] : "en";
			if (typeof s.m.sendPasswordResetEmail !== "function") { var m = new Error("no sendPasswordResetEmail"); m.code = "sdk-missing"; throw m; }
			return showForm("reset", labelsOf(args, 1)).then(function (v) {
				if (!v) { var e = new Error("cancelled"); e.code = "auth/user-cancelled"; throw e; }
				s.auth.languageCode = lang;
				return s.m.sendPasswordResetEmail(s.auth, v.email).then(function () { return {}; }, function (err) {
					if (err && err.code === "auth/user-not-found") return {};
					throw err;
				});
			});
		},
		refresh: function (s) {
			var u = needUser(s);
			return s.m.reload(u).then(function () { return userFields(s.auth.currentUser); });
		},
		sign_out: function (s) { return s.m.signOut(s.auth).then(function () { return {}; }); },
		delete_account: function (s) {
			var u = needUser(s);
			var last = Date.parse(u.metadata && u.metadata.lastSignInTime);
			if (!(last > 0) || Date.now() - last > RECENT_MS) { var e = new Error("recent"); e.code = "auth/requires-recent-login"; throw e; }
			return s.m.deleteDoc(docRef(s, u)).then(function () { return s.m.deleteUser(u); }).then(function () {
				store(pendingKey(u.uid), null);
				return {};
			});
		},
		cloud_get: function (s) {
			var u = needUser(s);
			return s.m.getDoc(docRef(s, u)).then(function (snap) {
				if (!snap.exists()) return { found: 0 };
				var d = snap.data() || {};
				return { found: 1, code: d.code || "", previous: d.previous || "" };
			});
		},
		cloud_put: function (s, args) {
			var u = needUser(s);
			var code = args[0] || "", prev = args[1] || "";
			if (!/^[A-Za-z0-9_-]+$/.test(code) || code.length > MAX_CODE || (prev && (!/^[A-Za-z0-9_-]+$/.test(prev) || prev.length > MAX_CODE))) {
				var e = new Error("bad code"); e.code = "bad-code"; throw e;
			}
			var data = { code: code, v: 1, updated: s.m.serverTimestamp() };
			if (prev) data.previous = prev;
			return s.m.setDoc(docRef(s, u), data).then(function () { return {}; });
		},
		cloud_delete: function (s) {
			var u = needUser(s);
			return s.m.deleteDoc(docRef(s, u)).then(function () { return {}; });
		}
	};

	var NETWORK = { sign_in_google: 1, password_form: 1, link_google: 1, link_email_form: 1, refresh: 1,
		delete_account: 1, cloud_get: 1, cloud_put: 1, cloud_delete: 1 };

	// what waits for the player (Google's window, a form): one at a time on the page, whatever the game's own guard did
	var WAITS = { sign_in_google: 1, link_google: 1, password_form: 1, link_email_form: 1, reset_password: 1 };
	var GOOGLE = { sign_in_google: 1, link_google: 1 };
	var SAYS_USER = { restore: 1, sign_in_google: 1, password_form: 1, link_google: 1, link_email_form: 1, refresh: 1 };
	var interactive = false;

	function call(id, op, args) {
		if (!configured || !OPS[op]) return "unavailable";
		if (NETWORK[op] && op !== "password_form" && op !== "link_email_form" && offline()) {
			done(id, false, "offline", {});
			return "ok";
		}
		if (WAITS[op] && interactive) { done(id, false, "busy", {}); return "ok"; }
		if (WAITS[op]) interactive = true;
		var t0 = Date.now();
		function free() { if (WAITS[op]) interactive = false; }
		loadSdk().then(function (s) { return OPS[op](s, args || []); }).then(function (fields) {
			free();
			if (SAYS_USER[op]) told = (fields && fields.uid) || "";
			else if (op === "sign_out" || op === "delete_account") told = "";
			done(id, true, "", fields);
		}, function (e) {
			free();
			var code = String((e && (e.code || e.message)) || "?");
			if (window.console && console.warn) console.warn("glowAuth " + op + ":", code);
			var why = reasonOf(e, op === "link_email_form" ? "link_email" : op);
			// Google's window went away or never answered inside an iPhone Home Screen app: that window cannot always
			// report back to such an app, and "try again" would not help; the game's text says what to do instead
			if ((why === "popup_closed" || why === "popup_timeout") && isIOS() && isStandalone() && googleFlow() === "firebase") why = "home_app";
			if (GOOGLE[op] && why !== "cancelled" && why !== "busy") {
				note("google " + code.slice(0, 60) + " " + envLabel() + " " + Math.round((Date.now() - t0) / 1000) + "s v" + VERSION + " " + googleFlow() + (e && e.glowDetail ? " " + String(e.glowDetail).slice(0, 80) : ""), 15000);
			} else if (why === "error") {
				note(op + ": " + code.slice(0, 80));
			}
			done(id, false, why, {});
		});
		return "ok";
	}

	// A failure the game cannot explain well: its code, the kind of page (ios-home = an iPhone Home Screen app), the
	// seconds it took and the script version, small at the bottom, so that a player can tell the developer what exactly
	// failed (a phone has no console; a screenshot is enough).
	function note(text, ms) {
		var n = null, tm = null;
		function remove() {
			if (tm && typeof clearTimeout === "function") clearTimeout(tm);
			if (n && n.parentNode) n.parentNode.removeChild(n);
			n = null;
		}
		try {
			n = document.createElement("div");
			n.textContent = text;
			n.style.cssText = "position:fixed;left:8px;right:8px;bottom:8px;z-index:2147483001;padding:8px 10px;border-radius:10px;" +
				"background:rgba(43,35,69,.9);color:#fff;font:12px sans-serif;text-align:center;pointer-events:none;";
			document.body.appendChild(n);
			tm = setTimeout(remove, ms || 8000);
			if (tm && tm.unref) tm.unref(); // node (tests) must not wait for it
		} catch (x) { /* no page: tests */ }
		return remove;
	}

	function poll() {
		if (!results.length) return "";
		var out = results.join("\n");
		results = [];
		return out;
	}

	window.glowAuth = window.glowAuth || {};
	window.glowAuth.configured = configured;
	window.glowAuth.version = VERSION;
	window.glowAuth.bounds = { popup: POPUP_MS, homePopup: HOME_POPUP_MS, look: LOOK_MS, homeLook: HOME_LOOK_MS, cancelLook: CANCEL_LOOK_MS, waitCard: WAIT_CARD_MS, sdk: SDK_MS };
	window.glowAuth.flow = googleFlow; // which way Google's sign-in goes on this page right now (the tests and the dark line read it)
	window.glowAuth.call = call;
	window.glowAuth.poll = poll;
})();
