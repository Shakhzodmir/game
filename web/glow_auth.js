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
		if (c === "glow/popup-timeout") return "popup_timeout";
		if (c === "glow/sdk-timeout") return "timeout";
		if (c === "auth/popup-blocked") return "popup_blocked";
		if (c === "glow/inapp-browser") return "inapp_browser";
		if (c === "auth/web-storage-unsupported" || c === "auth/operation-not-supported-in-this-environment") return "browser_unsupported";
		if (c === "auth/network-request-failed" || c === "unavailable" || c === "firestore/unavailable") return "offline";
		if (c === "auth/user-not-found" || c === "auth/wrong-password" || c === "auth/invalid-credential" ||
			c === "auth/invalid-login-credentials") return "bad_credentials";
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
	function isStandalone() {
		try { if (navigator.standalone === true) return true; } catch (e) { /* no navigator */ }
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
		return { ru: ["Продолжить с Google", "Отмена", "Ждём ответ от Google…", "Проверяю, вошли ли вы…"],
			ko: ["Google로 계속하기", "취소", "Google 응답을 기다리는 중…", "로그인 확인 중…"] }[lang] ||
			["Continue with Google", "Cancel", "Waiting for Google…", "Checking whether you signed in…"];
	}
	function displayKind() {
		try { if (navigator.standalone === true) return "home"; } catch (e) { /* no navigator */ }
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
			wait: function () { go.disabled = true; go.textContent = T[2]; go.style.background = "#9C87E0"; },
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

	function tapThenOpen(run) {
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
				card.wait();
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

	function withGesture(open) {
		if (inAppBrowser()) { var ia = new Error("in-app browser"); ia.code = "glow/inapp-browser"; return Promise.reject(ia); }
		function run() { return timed(open(), popupBound(), "glow/popup-timeout"); }
		if (needsTap()) return tapThenOpen(run);
		return runWithWaitCard(run).catch(function (e) {
			if (!e || e.code !== "auth/popup-blocked") throw e;
			return tapThenOpen(run);
		});
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
	function afterGoogleFailure(s, before, linking, e) {
		var c = (e && e.code) || "";
		if (c !== "auth/popup-closed-by-user" && c !== "glow/cancel-waiting" && c !== "glow/popup-timeout") throw e;
		// how long the account is watched: our own Cancel briefly; where the SDK itself sees the window (it already waited
		// about 8 s after the close) a few seconds; in an iPhone Home Screen app, where nothing says what happened, longer
		var ms = e.glowCancel ? CANCEL_LOOK_MS : (isIOS() && isStandalone() ? HOME_LOOK_MS : LOOK_MS);
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

	var OPS = {
		restore: function (s) {
			return new Promise(function (resolve) {
				var off = s.m.onAuthStateChanged(s.auth, function (u) { off(); resolve(userFields(u)); });
			});
		},
		sign_in_google: function (s, args) {
			gameLang = (args && args[0]) || gameLang;
			var before = snapshot(s);
			return withGesture(function () { return s.m.signInWithPopup(s.auth, new s.m.GoogleAuthProvider()); })
				.then(function (r) { return userFields(r.user); }, function (e) { return afterGoogleFailure(s, before, false, e); });
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
			var before = snapshot(s);
			return withGesture(function () { return s.m.linkWithPopup(u, new s.m.GoogleAuthProvider()); })
				.then(function () { return userFields(s.auth.currentUser); }, function (e) {
					// Google was linked after all (a window finished late): that is what the player asked for
					if (e && e.code === "auth/provider-already-linked" && hasGoogle(s.auth.currentUser)) return userFields(s.auth.currentUser);
					return afterGoogleFailure(s, before, true, e);
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
			if ((why === "popup_closed" || why === "popup_timeout") && isIOS() && isStandalone()) why = "home_app";
			if (GOOGLE[op] && why !== "cancelled" && why !== "busy") {
				note("google " + code.slice(0, 60) + " " + envLabel() + " " + Math.round((Date.now() - t0) / 1000) + "s v" + VERSION + " " + googleFlow(), 15000);
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
