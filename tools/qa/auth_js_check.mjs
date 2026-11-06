// Checks web/glow_auth.js against a fake Firebase SDK (no browser, no network): the wire format of the bridge,
// the reason mapping, the ID -> synthetic e-mail rule, the cloud document fields and the recent-login rule.
//   node tools/qa/auth_js_check.mjs
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const src = fs.readFileSync(new URL("../../web/glow_auth.js", import.meta.url), "utf8");

function makeWindow(config, sdk, form) {
	const store = {};
	const win = {
		GLOW_AUTH_CONFIG: config,
		localStorage: { getItem: (k) => store[k] ?? null, setItem: (k, v) => { store[k] = String(v); }, removeItem: (k) => { delete store[k]; } },
		addEventListener() {},
		console,
	};
	win.window = win;
	win.glowAuth = { _test: { sdk: () => Promise.resolve(sdk), form } };
	const ctx = vm.createContext({ window: win, localStorage: win.localStorage, navigator: { onLine: true }, console, Date, Promise, encodeURIComponent, JSON, Object, Error, RegExp, setTimeout });
	vm.runInContext(src, ctx);
	return win;
}

function fakeSdk() {
	const users = {}, docs = {};
	let current = null, n = 0;
	const err = (code) => Object.assign(new Error(code), { code });
	const mk = (email, providers, extra) => ({ uid: "uid" + (++n), email, emailVerified: false, displayName: "", providerData: providers.map((p) => ({ providerId: p })), metadata: { lastSignInTime: new Date().toISOString() }, ...extra });
	const m = {
		onAuthStateChanged: (auth, cb) => { setTimeout(() => cb(current), 0); return () => {}; },
		signInWithPopup: async () => { current = mk("a@gmail.com", ["google.com"], { emailVerified: true, displayName: "Anna" }); users[current.email] = { user: current }; return { user: current }; },
		createUserWithEmailAndPassword: async (a, email, pw) => { if (users[email]) throw err("auth/email-already-in-use"); current = mk(email, ["password"]); users[email] = { user: current, pw }; return { user: current }; },
		signInWithEmailAndPassword: async (a, email, pw) => { const u = users[email]; if (!u || u.pw !== pw) throw err("auth/invalid-credential"); current = u.user; return { user: current }; },
		verifyBeforeUpdateEmail: async () => {},
		linkWithPopup: async (u) => { u.providerData.push({ providerId: "google.com" }); return {}; },
		reload: async () => {},
		signOut: async () => { current = null; },
		deleteUser: async (u) => { delete users[u.email]; current = null; },
		GoogleAuthProvider: function () {},
		doc: (db, c, id) => ({ path: c + "/" + id }),
		getDoc: async (ref) => ({ exists: () => !!docs[ref.path], data: () => docs[ref.path] }),
		setDoc: async (ref, d) => { docs[ref.path] = d; },
		deleteDoc: async (ref) => { delete docs[ref.path]; },
		serverTimestamp: () => "TS",
	};
	return { sdk: { m, auth: { get currentUser() { return current; } }, db: {} }, docs, users, setOld: () => { current.metadata.lastSignInTime = "2020-01-01T00:00:00Z"; } };
}

async function run(win, op, args = []) {
	const id = Math.floor(Math.random() * 1e6);
	const r = win.glowAuth.call(id, op, args);
	if (r !== "ok") return { r };
	for (let i = 0; i < 50; i++) {
		await new Promise((res) => setTimeout(res, 2));
		const text = win.glowAuth.poll();
		if (text) {
			const [rid, ok, reason, rest] = text.split("\n")[0].split("|");
			assert.equal(Number(rid), id);
			const f = {};
			for (const kv of (rest || "").split("&")) if (kv) { const [k, v] = kv.split("="); f[k] = decodeURIComponent(v); }
			return { ok: ok === "1", reason, f };
		}
	}
	throw new Error("no answer for " + op);
}

// not configured: the game stays a guest game
let w = makeWindow({ apiKey: "", authDomain: "", projectId: "" }, null);
assert.equal(w.glowAuth.configured, false);
assert.equal(w.glowAuth.call(1, "restore", []), "unavailable");

const F = fakeSdk();
let nextForm = null;
w = makeWindow({ apiKey: "k", authDomain: "d", projectId: "p" }, F.sdk, (kind) => nextForm);
assert.equal(w.glowAuth.configured, true);

let r = await run(w, "restore");
assert.ok(r.ok); assert.ok(!r.f.uid);

nextForm = { id: "anna_7", password: "secret123" };
r = await run(w, "password_form", ["register"]);
assert.ok(r.ok, JSON.stringify(r));
assert.equal(r.f.id, "anna_7"); assert.equal(r.f.email, "anna_7@id.glow.invalid"); assert.equal(r.f.kind, "password");
r = await run(w, "password_form", ["register"]);
assert.equal(r.reason, "id_taken");
nextForm = null;
r = await run(w, "password_form", ["login"]);
assert.equal(r.reason, "cancelled");
nextForm = { id: "anna_7", password: "nope-nope" };
r = await run(w, "password_form", ["login"]);
assert.equal(r.reason, "bad_credentials");

// cloud document: only the code, the previous code, a version and a server time are written
r = await run(w, "cloud_get"); assert.ok(r.ok); assert.equal(r.f.found, "0");
r = await run(w, "cloud_put", ["GLOW1-abc_-", "GLOW1-old"]); assert.ok(r.ok);
assert.deepEqual(Object.keys(F.docs[Object.keys(F.docs)[0]]).sort(), ["code", "previous", "updated", "v"]);
r = await run(w, "cloud_get"); assert.equal(r.f.code, "GLOW1-abc_-"); assert.equal(r.f.previous, "GLOW1-old");
r = await run(w, "cloud_put", ["not a code!", ""]); assert.equal(r.reason, "error");

// e-mail link: pending until the address changes
nextForm = { email: "anna@gmail.com" };
r = await run(w, "link_email_form", []); assert.ok(r.ok); assert.equal(r.f.pending, "anna@gmail.com");
r = await run(w, "link_google"); assert.ok(r.ok); assert.equal(r.f.google, "1");

// deleting: refused when the sign-in is old, nothing removed; then done, data first
F.setOld();
r = await run(w, "delete_account"); assert.equal(r.reason, "need_recent_login");
assert.ok(Object.keys(F.docs).length === 1);
F.sdk.auth.currentUser.metadata.lastSignInTime = new Date().toISOString();
r = await run(w, "delete_account"); assert.ok(r.ok);
assert.equal(Object.keys(F.docs).length, 0);
r = await run(w, "cloud_get"); assert.equal(r.reason, "no_user");
console.log("auth_js_check: ok");
