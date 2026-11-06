// GLOW accounts and cloud save for the HTML5 build: Firebase Auth (Google, e-mail + password) and Firestore.
// The game (client/services/auth_web.lua) calls glowAuth.call(id, op, args) through html5.run and collects the
// finished operations with glowAuth.poll(): "<id>|<1|0>|<reason>|key=value&key=value" (values percent-encoded).
// Passwords are typed into the form below and go straight to the Firebase SDK; they never reach the game.
// The SDK is loaded from Google's CDN on first use, and only when web/auth_config.js is filled in.
(function () {
	"use strict";
	var cfg = window.GLOW_AUTH_CONFIG || {};
	var SDK_VERSION = "10.14.1";
	var SDK_BASE = "https://www.gstatic.com/firebasejs/" + SDK_VERSION + "/";
	var ID_DOMAIN = "id.glow.invalid";
	var RECENT_MS = 5 * 60 * 1000; // deleting an account needs a sign-in from the last five minutes
	var MAX_CODE = 200000;

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
		if (c === "auth/popup-closed-by-user" || c === "auth/cancelled-popup-request" || c === "auth/user-cancelled") return "cancelled";
		if (c === "auth/popup-blocked") return "popup_blocked";
		if (c === "auth/network-request-failed" || c === "unavailable" || c === "firestore/unavailable") return "offline";
		if (c === "auth/user-not-found" || c === "auth/wrong-password" || c === "auth/invalid-credential" ||
			c === "auth/invalid-login-credentials") return "bad_credentials";
		if (c === "auth/email-already-in-use") return ctx === "link_email" ? "email_in_use" : "id_taken";
		if (c === "auth/weak-password") return "weak_password";
		if (c === "auth/invalid-email") return ctx === "link_email" ? "bad_email" : "bad_id";
		if (c === "auth/requires-recent-login") return "need_recent_login";
		if (c === "auth/credential-already-in-use" || c === "auth/provider-already-linked") return "already_linked";
		if (c === "auth/too-many-requests") return "too_many";
		if (c === "auth/operation-not-allowed") return "not_enabled";
		if (c === "auth/unauthorized-domain") return "bad_domain";
		if (c === "permission-denied" || c === "firestore/permission-denied") return "denied";
		if (c === "auth/user-token-expired" || c === "auth/user-disabled" || c === "auth/null-user") return "no_user";
		return "error";
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
					var m = {};
					[mods[0], mods[1], mods[2]].forEach(function (mod) { Object.keys(mod).forEach(function (k) { m[k] = mod[k]; }); });
					var app = m.initializeApp(cfg);
					return { m: m, auth: m.getAuth(app), db: m.getFirestore(app) };
				});
			};
		sdkPromise = Promise.resolve().then(loader).then(function (s) { sdk = s; return s; });
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

	// kind: "login" | "register" | "email". Resolves {id, password} | {email} | null (cancelled).
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
			if (kind === "email") {
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
				if (kind === "email") {
					var email = inputs.email.value.trim();
					if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { err.textContent = L.err_email || ""; return; }
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

	// operations ------------------------------------------------------------------------------------------------

	function needUser(s) {
		var u = s.auth.currentUser;
		if (!u) { var e = new Error("no user"); e.code = "auth/null-user"; throw e; }
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
		sign_in_google: function (s) {
			return s.m.signInWithPopup(s.auth, new s.m.GoogleAuthProvider()).then(function (r) { return userFields(r.user); });
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
		link_google: function (s) {
			var u = needUser(s);
			return s.m.linkWithPopup(u, new s.m.GoogleAuthProvider()).then(function () { return userFields(s.auth.currentUser); });
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

	function call(id, op, args) {
		if (!configured || !OPS[op]) return "unavailable";
		if (NETWORK[op] && op !== "password_form" && op !== "link_email_form" && offline()) {
			done(id, false, "offline", {});
			return "ok";
		}
		loadSdk().then(function (s) { return OPS[op](s, args || []); }).then(function (fields) {
			done(id, true, "", fields);
		}, function (e) {
			if (window.console && console.warn) console.warn("glowAuth " + op + ":", e && (e.code || e.message));
			done(id, false, reasonOf(e, op === "link_email_form" ? "link_email" : op), {});
		});
		return "ok";
	}

	function poll() {
		if (!results.length) return "";
		var out = results.join("\n");
		results = [];
		return out;
	}

	window.glowAuth = window.glowAuth || {};
	window.glowAuth.configured = configured;
	window.glowAuth.call = call;
	window.glowAuth.poll = poll;
})();
