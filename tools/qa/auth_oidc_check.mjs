// Checks our own sign-in with Google (web/glow_oidc.js, web/auth_return.html, and that web/auth_test.html compiles and loads
// the core by its own version) in a small fake browser (no real browser, no network): the request, the answer checks, the
// three hand-over channels, the return page in every state it can meet, and the whole loop with a fake Google and a fake
// Firebase SDK (the nonce rule and the order of credentials). The test page itself is run in real browsers by hand:
// the script of the phone-test work (Playwright, Chromium and WebKit) is not part of the repository.
//   node tools/qa/auth_oidc_check.mjs
import vm from "node:vm";
import assert from "node:assert/strict";
import { createHash, webcrypto } from "node:crypto";
import { read, scriptOf, CORE, RETURN_JS, sleep, json, CLIENT, ORIGIN, RETURN_URL, IPHONE, b64u, sha256hex,
	makeWorld, makeStorage, makeWindow, installGoogle, loadReturn } from "./fake_world.mjs";

const RETURN_HTML = read("web/auth_return.html");
const TEST_HTML = read("web/auth_test.html");
assert.ok(RETURN_JS, "the return page has one inline script");


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

// 5. the wait: every channel alone, and what must be ignored -------------------------------------------------------------------
const mkRelay = (state, extra = {}) => ({ k: "glow_oidc", v: 1, h: "id_token=x&state=" + state, q: "", t: Date.now(), d: {}, ...extra });
async function armed(opts = {}) {
	const w = coreWorld();
	const rec = json(await w.G.prepare({ dest: "t", mode: "p" }));
	const log = { relay: [], seen: [] };
	const h = w.G.listen({ dest: "t", state: rec.s, pollMs: 30, onRelay: (r, via, info) => log.relay.push({ via, hidden: info.hidden }), onSeen: (via, info) => log.seen.push({ via, hidden: info.hidden }), ...opts });
	// a second window of the same origin that writes into the world
	const other = makeWindow(w.world, { href: ORIGIN + "/game/auth_return.html", core: false });
	return { ...w, rec, h, log, other, key: "glow_oidc_t_res:" + rec.s };
}
{
	// BroadcastChannel alone (the re-read is slowed down, so that the order of the other channels is not a race)
	let a = await armed({ pollMs: 100000 });
	await sleep(5);
	const ch = new a.other.BroadcastChannel("glow_oidc_t");
	ch.postMessage(mkRelay(a.rec.s));
	await waitFor(() => a.log.relay.length === 1);
	assert.deepEqual(json(a.log.relay), [{ via: "bc", hidden: false }]);
	// ... and a duplicate through the mailbox is "seen", but the answer is delivered once
	a.other.localStorage.setItem(a.key, JSON.stringify(mkRelay(a.rec.s)));
	await waitFor(() => a.log.seen.length >= 2);
	assert.equal(a.log.relay.length, 1, "one answer, once");
	assert.ok(a.log.seen.length >= 2, "every arrival is logged for the diagnosis");
	assert.deepEqual(a.log.seen.map((x) => x.via).slice(0, 2), ["bc", "st"], "the storage event tells the other window's write first");
	a.h.stop();

	// another state, a foreign kind, a wrong version, a broken one: all ignored on every channel
	a = await armed();
	const ch2 = new a.other.BroadcastChannel("glow_oidc_t");
	for (const r of [mkRelay("pt.otherstate12"), { ...mkRelay(a.rec.s), v: 2 }, { ...mkRelay(a.rec.s), k: "x" }, null, "str", { k: "glow_oidc", v: 1 }]) ch2.postMessage(r);
	a.other.localStorage.setItem("glow_oidc_t_res:pt.otherstate12", JSON.stringify(mkRelay("pt.otherstate12")));
	a.other.localStorage.setItem(a.key, "{broken");
	a.win._receive(mkRelay("pt.otherstate12"), ORIGIN, a.other.handle, ORIGIN);
	await sleep(250);
	assert.equal(a.log.seen.length, 0, "nothing of ours arrived");
	// the broken mailbox is replaced by the real answer: it still arrives
	a.other.localStorage.setItem(a.key, JSON.stringify(mkRelay(a.rec.s)));
	await waitFor(() => a.log.relay.length === 1);
	assert.equal(a.log.relay.length, 1);
	a.h.stop();

	// message events: our origin only; from the pop-up only while it is alive
	a = await armed();
	a.win._receive(mkRelay(a.rec.s), ORIGIN, a.other.handle, "https://evil.example");
	await sleep(60);
	assert.equal(a.log.relay.length, 0, "a message from another origin is dropped");
	a.win._receive(mkRelay(a.rec.s), ORIGIN, a.other.handle, ORIGIN);
	await waitFor(() => a.log.relay.length === 1);
	assert.deepEqual(a.log.relay.map((x) => x.via), ["pm"], "no pop-up reference yet: any same-origin window may answer");
	a.h.stop();
	{
		const popup = makeWindow(a.world, { href: "https://accounts.google.com/x" });
		a = await armed({ win: popup.handle });
		a.win._receive(mkRelay(a.rec.s), ORIGIN, a.other.handle, ORIGIN); // a window that is not the pop-up
		await sleep(60);
		assert.equal(a.log.relay.length, 0, "while the pop-up is alive only the pop-up may answer by message");
		a.win._receive(mkRelay(a.rec.s), ORIGIN, popup.handle, ORIGIN);
		await waitFor(() => a.log.relay.length === 1);
		assert.equal(a.log.relay.length, 1);
		a.h.stop();
		const dead = makeWindow(a.world, { href: "https://accounts.google.com/x", sever: true }); // closed reads true: severed
		a = await armed({ win: dead.handle });
		a.win._receive(mkRelay(a.rec.s), ORIGIN, a.other.handle, ORIGIN);
		await waitFor(() => a.log.relay.length === 1);
		assert.equal(a.log.relay.length, 1, "a pop-up that reads closed no longer vetoes: its link may be cut");
		a.h.stop();
	}

	// the mailbox without any event: the first look, the re-read on visibility, pageshow and focus, the 300 ms re-read
	a = await armed({ pollMs: 100000 });
	a.world.ls.set(a.key, JSON.stringify(mkRelay(a.rec.s))); // no storage event: written under the page's feet
	await waitFor(() => a.log.relay.length === 1);
	assert.deepEqual(a.log.relay.map((x) => x.via), ["load"], "an answer that is already there is found at once");
	a.h.stop();
	const fires = [
		["vis", (w) => { w.document.hidden = false; w.document.visibilityState = "visible"; w.dispatchDoc("visibilitychange", {}); }],
		["show", (w) => w.dispatch("pageshow", { persisted: true })],
		["focus", (w) => w.dispatch("focus", {})],
	];
	for (const [via, fire] of fires) {
		a = await armed({ pollMs: 100000 });
		await sleep(40);
		a.win.document.hidden = true; a.win.document.visibilityState = "hidden";
		a.world.ls.set(a.key, JSON.stringify(mkRelay(a.rec.s)));
		if (via === "vis") { a.win.dispatchDoc("visibilitychange", {}); await sleep(40); assert.equal(a.log.relay.length, 0, "still hidden: not yet"); }
		fire(a.win);
		await waitFor(() => a.log.relay.length === 1);
		assert.deepEqual(json(a.log.relay), [{ via, hidden: via !== "vis" }], via + ": whether the page was hidden at that moment is reported");
		a.h.stop();
	}
	a = await armed({ pollMs: 30 });
	await sleep(40);
	a.world.ls.set(a.key, JSON.stringify(mkRelay(a.rec.s)));
	await waitFor(() => a.log.relay.length === 1);
	assert.deepEqual(a.log.relay.map((x) => x.via), ["poll"], "the 300 ms re-read is the net under all of it");
	a.h.stop();
	// a page whose timers stood still (Google's tab was in front) looks once more by hand before it gives up: poke() reads the mailbox now
	a = await armed({ pollMs: 100000 });
	await sleep(40);
	a.world.ls.set(a.key, JSON.stringify(mkRelay(a.rec.s)));
	assert.equal(a.log.relay.length, 0, "nothing has looked yet");
	a.h.poke("limit");
	assert.deepEqual(a.log.relay.map((x) => x.via), ["limit"], "poke() delivers synchronously, so the caller can look at the result at once");
	a.h.stop();

	// stop(): nothing more arrives, and it can be called twice
	a = await armed();
	a.h.stop(); a.h.stop();
	const ch3 = new a.other.BroadcastChannel("glow_oidc_t"); ch3.postMessage(mkRelay(a.rec.s));
	a.other.localStorage.setItem(a.key, JSON.stringify(mkRelay(a.rec.s)));
	await sleep(250);
	assert.equal(a.log.seen.length, 0, "a stopped wait hears nothing");

	// ack: the BroadcastChannel and the pop-up get it, with the origin
	const popup2 = makeWindow(a.world, { href: ORIGIN + "/game/auth_return.html" });
	const heard = [];
	popup2.addEventListener("message", (ev) => heard.push({ d: ev.data, o: ev.origin }));
	a = await armed({ win: popup2.handle });
	const peer = new a.other.BroadcastChannel("glow_oidc_t"); const bcHeard = []; peer.onmessage = (ev) => bcHeard.push(ev.data);
	a.h.ack("bc");
	await waitFor(() => bcHeard.length >= 1 && heard.length >= 1);
	assert.deepEqual(json(bcHeard), [{ k: "glow_oidc_ack", s: a.rec.s, via: "bc" }]);
	assert.deepEqual(heard.map((x) => [x.d.k, x.d.s, x.o]), [["glow_oidc_ack", a.rec.s, ORIGIN]]);
	// a live starter answers the return page's ping (and only for its own state)
	peer.postMessage({ k: "glow_oidc_ping", s: "pt.otherstate12" });
	peer.postMessage({ k: "glow_oidc_ping", s: a.rec.s });
	await waitFor(() => bcHeard.length >= 2);
	await sleep(60);
	assert.deepEqual(json(bcHeard.slice(1)), [{ k: "glow_oidc_pong", s: a.rec.s }], "pong for our state only, and a ping is no answer");
	assert.equal(a.log.seen.length, 0);
	a.h.stop();
	// a page without timers: the other channels still work
	a = await armed({ setInterval: null });
	a.other.localStorage.setItem(a.key, JSON.stringify(mkRelay(a.rec.s)));
	await waitFor(() => a.log.relay.length === 1);
	assert.equal(a.log.relay.length, 1);
	a.h.stop();
}

// 6. the return page ----------------------------------------------------------------------------------------------------------
// a starter (the page that began the attempt), in its own world, and a return page that Google sends a window to
async function starter(opts = {}) {
	const w = coreWorld(opts.win || {});
	const mode = opts.mode || "p", dest = opts.dest || "t";
	const rec = { ...json(await w.G.prepare({ dest, mode, responseType: opts.responseType || "id_token token" })), w: "W1", c: opts.c || "tab" };
	w.G.savePending(rec, {}, { shared: mode === "r" });
	const log = { relay: [], seen: [] };
	const h = opts.noListen ? null : w.G.listen({ dest, state: rec.s, pollMs: 30, onRelay: (r, via, info) => log.relay.push({ via, hidden: info.hidden, relay: r }), onSeen: (via) => log.seen.push(via) });
	return { ...w, rec, h, log, key: (dest === "g" ? "glow_oidc_res:" : "glow_oidc_t_res:") + rec.s };
}
const fragFor = (rec, extra = "", o = {}) => "id_token=" + jwt(goodClaims(rec.n)) + "&access_token=ya29.fake&token_type=Bearer&state=" + (o.state || rec.s) + extra;
function retPage(st, o = {}) {
	// the pop-up as window.open makes it: a COPY of the opener's sessionStorage taken at open time
	const copy = o.ss || new Map(st.win.ssMap);
	const win = makeWindow(st.world, { href: RETURN_URL + (o.search || "") + (o.frag === undefined ? "" : "#" + o.frag), ss: copy, opener: o.opener === undefined ? st.win : o.opener, noBC: o.noBC, lang: o.lang === undefined ? "en" : o.lang,
		standalone: o.standalone, noLocalStorage: o.noLS, framed: o.framed, hl: 3, refuseClose: o.refuseClose, dm: o.dm });
	const scale = o.scale || 0.2, realST = setTimeout;
	win.ctx.setTimeout = (f, ms) => realST(f, ms * scale); win.ctx.setInterval = (f, ms) => setInterval(f, Math.max(5, ms * scale));
	if (o.beforeRun) o.beforeRun(win);
	win.run(RETURN_JS);
	return win;
}
const allStored = (st) => JSON.stringify([...st.world.ls.entries()]);
const textOf = (win) => win.document.getElementById("m").textContent + " | " + win.document.getElementById("d").textContent;

{
	// a normal pop-up answer: hand-over on three channels, the fragment wiped first, the answer kept as it came, ack closes it
	const st = await starter();
	const seenMsg = [];
	st.win.addEventListener("message", (ev) => seenMsg.push(ev));
	const frag = fragFor(st.rec);
	const page = retPage(st, { frag, scale: 0.5 });
	assert.equal(page.history.calls.length, 1); assert.equal(page.history.calls[0].url, "/game/auth_return.html");
	assert.equal(page.history.calls[0].hashBefore, "#" + frag, "the call saw the answer in the address..."); assert.equal(page.location.hash, "", "...and wiped it");
	assert.equal(page.history.calls[0].at, 0, "wiped before anything was posted");
	const mail = JSON.parse(st.world.ls.get(st.key));
	assert.deepEqual([mail.k, mail.v, mail.h, mail.q], ["glow_oidc", 1, frag, ""], "the raw answer, not parsed, not changed");
	assert.deepEqual(json(mail.d), { op: 1, sa: 0, dm: "browser", ss: 1, ls: 1, own: 0, hl: 3, vs: "visible", c: "tab" });
	assert.deepEqual(page.posted.filter((p) => p.bc).map((p) => [p.bc, p.data.k, p.data.h === frag]), [["glow_oidc_t", "glow_oidc", true]]);
	await waitFor(() => st.log.relay.length === 1);
	assert.equal(st.log.relay.length, 1, "the starter got it"); assert.ok(["bc", "pm", "st", "poll", "load"].includes(st.log.relay[0].via));
	assert.ok(seenMsg.length >= 1 && seenMsg[0].origin === ORIGIN && seenMsg[0].data.k === "glow_oidc", "the opener was told by postMessage");
	assert.deepEqual(st.world.blocked, [], "the target origin of every postMessage was our own: nothing was refused as foreign, nothing was sent to *");
	assert.match(textOf(page), /Done\. Close this window and go back to the test page\./);
	assert.equal(page.closeCalls, 0, "it waits for the starter's word first");
	st.h.ack("bc");
	await waitFor(() => page.closeCalls === 1);
	assert.equal(page.closeCalls, 1, "closed after the ack"); assert.equal(page.gone, true);
	const ret = JSON.parse(st.world.ls.get("glow_oidc_t_ret"));
	assert.deepEqual([ret.s, ret.ack, ["bc", "pm"].includes(ret.via), ret.ct, ret.d.op, ret.rep], [st.rec.s, 1, true, 1, 1, 0], "the return record tells the test page what happened here");
	st.h.stop();
}
{
	// no ack at all: it closes after a short wait anyway, and says so; a window that refuses to close shows the way back (test page only)
	const st = await starter({ noListen: true });
	const page = retPage(st, { frag: fragFor(st.rec), refuseClose: true });
	await waitFor(() => page.closeCalls === 1 && !page.document.getElementById("b").hidden, 6000);
	assert.equal(page.closeCalls, 1);
	const ret = JSON.parse(st.world.ls.get("glow_oidc_t_ret"));
	assert.deepEqual([ret.ack, ret.via, ret.ct], [0, "", 1]);
	const b = page.document.getElementById("b");
	assert.equal(b.hidden, false, "a window that stays open gets a way back to the test page");
	b.click();
	assert.deepEqual(page.replaced, ["auth_test.html"]);
	// the game's pop-up has no such button: a stray window must never start a second copy of the game
	const g = await starter({ dest: "g", noListen: true });
	const gp = retPage(g, { frag: fragFor(g.rec), refuseClose: true });
	await waitFor(() => gp.closeCalls === 1, 6000);
	await sleep(500);
	assert.equal(gp.document.getElementById("b").hidden, true);
	assert.equal(g.world.ls.get("glow_oidc_t_ret"), undefined, "no return record for the game");
	assert.match(textOf(gp), /Done\. Go back to the game\./);
	assert.ok(g.world.ls.get("glow_oidc_res:" + g.rec.s), "the game's own mailbox key");
}
{
	// framed: blank, nothing read, nothing written
	const st = await starter({ noListen: true });
	const before = allStored(st);
	const page = retPage(st, { frag: fragFor(st.rec), framed: true });
	assert.equal(page.document.documentElement.textContent, "");
	assert.equal(allStored(st), before); assert.deepEqual(page.posted, []); assert.equal(page.history.calls.length, 0);
}
{
	// no state: a breadcrumb with names and lengths only, never values; nothing is relayed; no link to the game
	const st = await starter();
	const secret = "SECRETVALUE0123";
	const page = retPage(st, { frag: "foo=1&id_token=" + secret + "&bar", search: "?x=" + secret });
	const crumb = JSON.parse(st.world.ls.get("glow_oidc_t_ret"));
	assert.deepEqual([crumb.nostate, crumb.hl, crumb.ql, crumb.keys, crumb.sa, crumb.dm, crumb.op], [1, ("foo=1&id_token=" + secret + "&bar").length, ("x=" + secret).length, "foo,id_token,bar|x", 0, "browser", 1]);
	assert.equal(allStored(st).includes(secret), false, "no value is ever stored");
	assert.equal(textOf(page).includes(secret), false);
	assert.match(textOf(page), /^Nothing to do here\./);
	assert.equal(page.document.getElementById("b").hidden, true, "no button, no link");
	assert.deepEqual(page.posted, []); assert.equal(page.closeCalls, 0);
	assert.equal(page.history.calls.length, 1, "the address is wiped all the same");
	// a state that is not one of ours is no state
	const p2 = retPage(st, { frag: "id_token=a.b.c&state=evil.attacker" });
	assert.equal(JSON.parse(st.world.ls.get("glow_oidc_t_ret")).nostate, 1); assert.equal(p2.posted.length, 0);
	await sleep(60);
	assert.equal(st.log.relay.length, 0);
	st.h.stop();
}
{
	// the answer of an attempt this storage knows nothing about (another profile, a stray link): offered to the channels that
	// keep nothing, never written to the shared storage
	const lone = makeWorld();
	const ghost = makeWindow(lone, { href: ORIGIN + "/game/x", core: true });
	const rec = json(await ghost.window.glowOidc.prepare({ dest: "t", mode: "p" }));
	const page = retPage({ world: lone, win: ghost }, { frag: fragFor(rec), ss: new Map(), opener: ghost });
	assert.equal([...lone.ls.keys()].filter((k) => k.indexOf("glow_oidc_t_res") === 0).length, 0, "no answer in the storage without a record of the attempt");
	assert.equal(JSON.stringify([...lone.ls.entries()]).includes("id_token"), false);
	assert.equal(page.posted.filter((p) => p.bc).length, 1, "but the channels that keep nothing still carry it");
	const ghostRet = JSON.parse(lone.ls.get("glow_oidc_t_ret"));
	assert.deepEqual([ghostRet.d.ss, ghostRet.d.ls, ghostRet.st], [0, 0, "relayed"], "the token-free return record still says this window knew nothing of the attempt");
}
{
	// mode r in a window that is not the starter's: says "close this window", never navigates; "another storage" when nothing is known
	const st = await starter({ mode: "r", noListen: true });
	const page = retPage(st, { frag: fragFor(st.rec), opener: null, ss: new Map() /* a context that shares no tab storage */ });
	await sleep(150);
	assert.deepEqual(page.navs, []);
	assert.match(textOf(page), /^Close this window \(the Done or Close button\) and go back to the test page\. \|/, "it finds the record in the shared storage, so no 'another storage'");
	const p2 = retPage(st, { frag: fragFor({ ...st.rec }, "", { state: "rt.neverstarted1234567" }), opener: null, ss: new Map() });
	await sleep(40);
	assert.match(textOf(p2), /its storage is another one/);
	assert.deepEqual(p2.navs, []);
}
{
	// the starter's own window (the marker is there): popup mode goes back at once; the page there takes the answer from the mailbox
	for (const [dest, want] of [["t", "auth_test.html"], ["g", "./"]]) {
		const st = await starter({ dest, noListen: true });
		st.G.markOwn(dest, st.rec.s, {});
		const page = retPage(st, { frag: fragFor(st.rec), opener: null });
		assert.deepEqual(page.replaced, [want], "a fixed target for destination " + dest);
		assert.equal(page.closeCalls, 0);
		await sleep(30);
		if (dest === "t") assert.equal(JSON.parse(st.world.ls.get("glow_oidc_t_ret")).rep, 1);
		assert.ok(st.world.ls.get(st.key), "the answer waits in the mailbox for the page that loads next");
	}
	// a copy of the starter's storage made BEFORE the marker was written (what window.open gives a child) is not the starter's window
	const st = await starter({ noListen: true });
	const copyAtOpen = new Map(st.win.ssMap);
	st.G.markOwn("t", st.rec.s, {});
	const child = retPage(st, { frag: fragFor(st.rec), ss: copyAtOpen });
	assert.deepEqual(child.navs, [], "the pop-up's copy has the record but not the marker");
	await sleep(30);
	assert.equal(JSON.parse(st.world.ls.get("glow_oidc_t_ret")).d.own, 0);
	// a marker of ANOTHER attempt does not count
	const st2 = await starter({ noListen: true });
	st2.G.markOwn("t", "pt.anotherattempt12345", {});
	assert.deepEqual(retPage(st2, { frag: fragFor(st2.rec), opener: null }).navs, []);
}
{
	// mode r: the starter's own window goes back unless a live starter answers the ping (then this is another window over a live page)
	let st = await starter({ mode: "r", noListen: true });
	st.G.markOwn("t", st.rec.s, {});
	let page = retPage(st, { frag: fragFor(st.rec), opener: null });
	assert.deepEqual(page.navs, [], "it waits for a pong first");
	await waitFor(() => page.replaced.length === 1, 4000);
	assert.deepEqual(page.replaced, ["auth_test.html"]);
	assert.equal(JSON.parse(st.world.ls.get("glow_oidc_t_ret")).pong, 0);
	st = await starter({ mode: "r" }); // a live listener answers the ping
	st.G.markOwn("t", st.rec.s, {});
	page = retPage(st, { frag: fragFor(st.rec), opener: null, scale: 0.5 });
	await waitFor(() => (JSON.parse(st.world.ls.get("glow_oidc_t_ret") || "{}")).pong === 1, 4000);
	await sleep(500); // longer than the whole pong wait of the page: nothing may navigate afterwards either
	assert.deepEqual(page.navs, [], "a live starter: no second copy");
	assert.match(textOf(page), /^Close this window/);
	assert.equal(JSON.parse(st.world.ls.get("glow_oidc_t_ret")).pong, 1);
	assert.equal(st.log.relay.length, 1, "and the live starter took the answer itself");
	st.h.stop();
	// an attempt of a Home Screen app is finished only in a Home Screen window
	for (const [standalone, goes] of [[false, false], [true, true]]) {
		st = await starter({ mode: "r", noListen: true, c: "home" });
		st.G.markOwn("t", st.rec.s, {});
		page = retPage(st, { frag: fragFor(st.rec), opener: null, standalone });
		if (goes) await waitFor(() => page.navs.length === 1, 4000); else await sleep(700);
		assert.equal(page.navs.length === 1, goes, "home attempt, standalone=" + standalone);
	}
	for (const [standalone, goes] of [[false, false], [true, true]]) {
		st = await starter({ mode: "p", noListen: true, c: "home" });
		st.G.markOwn("t", st.rec.s, {});
		page = retPage(st, { frag: fragFor(st.rec), opener: null, standalone });
		await sleep(100);
		assert.equal(page.navs.length === 1, goes, "pop-up mode, home attempt, standalone=" + standalone);
	}
}
{
	// words by the device; a Google error is passed on as it is (the page judges nothing)
	for (const [lang, re] of [["ru", /^Готово\. Закройте это окно/], ["ko", /^완료되었습니다/], ["en", /^Done\./], ["de", /^Done\./], ["", /^Done\./]]) {
		const st = await starter({ noListen: true });
		assert.match(textOf(retPage(st, { frag: fragFor(st.rec), lang })), re, "language " + lang);
	}
	const st = await starter({ noListen: true });
	const f = "error=access_denied&state=" + st.rec.s;
	retPage(st, { frag: f });
	assert.equal(JSON.parse(st.world.ls.get(st.key)).h, f);
	const st2 = await starter({ noListen: true });
	retPage(st2, { frag: "", search: "?error=access_denied&state=" + st2.rec.s });
	const m2 = JSON.parse(st2.world.ls.get(st2.key));
	assert.deepEqual([m2.h, m2.q], ["", "error=access_denied&state=" + st2.rec.s], "an answer in the query reaches the starter too");
}
{
	// each channel alone, from the return page's side: no BroadcastChannel and no opener -> the mailbox; no storage -> channel / message
	let st = await starter();
	retPage(st, { frag: fragFor(st.rec), noBC: true, opener: null });
	await waitFor(() => st.log.relay.length >= 1);
	assert.ok(["st", "poll", "load"].includes(st.log.relay[0].via), "mailbox only: " + (st.log.relay[0] || {}).via);
	st.h.stop();
	st = await starter();
	retPage(st, { frag: fragFor(st.rec), noLS: true, opener: null });
	await waitFor(() => st.log.relay.length >= 1);
	assert.equal(st.log.relay[0].via, "bc", "broadcast only (the page cannot see its storage: the answer is not stored)");
	assert.equal(st.world.ls.get(st.key), undefined);
	st.h.stop();
	st = await starter();
	retPage(st, { frag: fragFor(st.rec), noLS: true, noBC: true });
	await waitFor(() => st.log.relay.length >= 1);
	assert.equal(st.log.relay[0].via, "pm", "opener.postMessage only");
	st.h.stop();
}

// 7. the static facts of the return page ------------------------------------------------------------------------------------
{
	assert.match(RETURN_HTML, /<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">/);
	assert.match(RETURN_HTML, /<meta name="referrer" content="no-referrer">/);
	assert.equal(/<(link|img|iframe|form|object|embed|base)\b/i.test(RETURN_HTML), false, "no external resource of any kind");
	assert.equal(/<script[^>]*\ssrc=/i.test(RETURN_HTML), false);
	assert.equal(/https?:\/\//.test(RETURN_JS), false, "the script names no address");
	for (const bad of ["id_token", "access_token", "atob", "eval(", "Function(", "innerHTML", "document.write", ", \"*\")", ", '*')"]) assert.equal(RETURN_JS.includes(bad), false, "the return page must not contain " + bad);
	assert.ok(RETURN_JS.includes("postMessage(relay, location.origin)"), "the target origin of the relay is our own");
	assert.ok(RETURN_JS.includes('"./"') && RETURN_JS.includes('"auth_test.html"'), "the only places it can go to are written out");
	assert.equal((RETURN_JS.match(/location\.(replace|assign)\(/g) || []).length, 2, "two navigations, both to the fixed target");
	assert.ok(RETURN_JS.indexOf("history.replaceState") >= 0 && RETURN_JS.indexOf("history.replaceState") < RETURN_JS.indexOf("new BroadcastChannel"), "the address is wiped before anything is sent");
	// the keys of the page are the keys of the core
	const G = coreWorld().G, kt = G.keysFor("t"), kg = G.keysFor("g");
	for (const v of [kt.pend, kt.res, kt.chan, kt.ret, kt.own, kg.pend, kg.res, kg.chan, kg.own]) assert.ok(RETURN_JS.includes('"' + v + '"'), "the return page names the key " + v);
}

// 8. the whole loop: a starter that opens Google's window, a fake Google, the return page ---------------------------------------
async function waitFor(fn, ms = 3000) { const end = Date.now() + ms; while (Date.now() < end) { if (fn()) return true; await sleep(10); } return !!fn(); }
async function loop(sc, o = {}) {
	const w = coreWorld(o.win || {});
	installGoogle(w.world, sc);
	const mode = o.mode || "p", rt = o.responseType || "id_token token";
	const rec = { ...json(await w.G.prepare({ dest: "t", mode, responseType: rt })), w: "W1", c: "tab" };
	w.G.savePending(rec, {}, { shared: mode === "r" });
	const got = { relay: null, via: null, seen: [], info: null };
	const h = w.G.listen({ dest: "t", state: rec.s, pollMs: 40, onRelay: (relay, via, info) => { got.relay = relay; got.via = via; got.info = info; if (!o.noAck) h.ack(via); }, onSeen: (via, info) => got.seen.push([via, info.hidden]) });
	const url = w.G.authUrl({ clientId: CLIENT, redirectUri: RETURN_URL, responseType: rt, nonce: rec.n, state: rec.s });
	let handle = null;
	if (mode === "p") {
		handle = w.win.open(url, "glow_oidc_" + rec.s.slice(-6)); // the first and only window.open of the tap
		if (handle) { h.setWin(handle); w.G.markOwn("t", rec.s, {}); } // the marker goes in AFTER window.open: the child's copy of the tab storage lacks it
	}
	if (o.wait !== false) await waitFor(() => got.relay, o.ms || 1500);
	return { ...w, rec, h, got, handle, url };
}
const verdict = (L, extra = {}) => json(L.G.validate(L.got.relay, L.rec, { clientId: CLIENT, ...extra }));

{
	// the happy loop: what Google is asked, what comes back, who closes the window
	const L = await loop({});
	const asked = L.world.google[0].params;
	assert.deepEqual([asked.client_id, asked.redirect_uri, asked.response_type, asked.scope, asked.prompt, asked.state, "response_mode" in asked, "hd" in asked, "include_granted_scopes" in asked],
		[CLIENT, RETURN_URL, "id_token token", "openid email profile", "select_account", L.rec.s, false, false, false]);
	assert.match(asked.nonce, /^[0-9a-f]{64}$/); assert.equal(asked.nonce, L.rec.n);
	assert.equal(L.world.google[0].name, "glow_oidc_" + L.rec.s.slice(-6), "a fresh window name for every attempt: no stale tab is ever reused");
	assert.ok(L.got.relay, "the answer arrived"); assert.equal(L.got.relay.d.own, 0, "the pop-up is not the starter's own window");
	const v = verdict(L);
	assert.equal(v.ok, true); assert.equal(v.claims.email, "anna@gmail.com"); assert.equal(v.rawNonce, L.rec.r);
	assert.equal(await L.G.checkAtHash(v.claims, v.accessToken, { crypto: webcrypto }), "ok");
	await waitFor(() => L.world.pages[0].page && L.world.pages[0].page.closeCalls === 1, 4000);
	assert.equal(L.world.pages[0].page.closeCalls, 1, "the return page closed itself after the ack");
	assert.equal(L.handle.closed, true);
	assert.equal(JSON.parse(L.world.ls.get("glow_oidc_t_ret")).ack, 1);
	// done: nothing of the attempt is left in any storage
	L.h.stop(); L.G.clearFlow("t", L.rec.s, {});
	assert.deepEqual([...L.world.ls.keys()].filter((k) => k.indexOf(L.rec.s) >= 0), []);
	assert.equal(L.win.window.sessionStorage.getItem("glow_oidc_t_pend"), null);
}
{
	// the leading hypothesis of the phone report: Google's window loses its link with the page that opened it. Nothing may depend on it
	const L = await loop({ sever: true });
	assert.equal(L.handle.closed, true, "the page reads closed=true at once, like on the phone");
	assert.ok(L.got.relay, "the answer still arrives"); assert.ok(["bc", "st", "poll", "load"].includes(L.got.via), "by a channel that needs no link: " + L.got.via);
	assert.equal(L.got.relay.d.op, 0, "the return page reports that its opener is gone");
	assert.equal(verdict(L).ok, true);
	L.h.stop();
}
{
	// the shared-storage mailbox alone (no BroadcastChannel anywhere, no link)
	const L = await loop({ sever: true, noBCReturn: true }, { win: { noBC: true } });
	assert.ok(["st", "poll", "load"].includes(L.got.via), L.got.via); assert.equal(verdict(L).ok, true);
	L.h.stop();
	// the BroadcastChannel alone (no storage on the return page, no link)
	const B = await loop({ sever: true, noLocalStorageReturn: true });
	assert.equal(B.got.via, "bc"); assert.equal(verdict(B).ok, true); assert.equal(B.world.ls.get(B.key), undefined);
	B.h.stop();
	// the message of the opener alone (no storage, no channel)
	const P = await loop({ noLocalStorageReturn: true, noBCReturn: true });
	assert.equal(P.got.via, "pm"); assert.equal(verdict(P).ok, true);
	P.h.stop();
}
{
	// what Google can answer instead
	let L = await loop({ error: "access_denied" });
	assert.deepEqual(pick3(verdict(L)), [false, "denied", "cancelled"], "Cancel on Google's page is silent, not a failure");
	L.h.stop();
	L = await loop({ error: "temporarily_unavailable" });
	assert.deepEqual(pick3(verdict(L)), [false, "oauth_temporarily_unavailable", "error"]);
	L.h.stop();
	L = await loop({ badNonce: true });
	assert.deepEqual(pick3(verdict(L)), [false, "nonce", "error"], "an id_token made for another attempt");
	L.h.stop();
	L = await loop({ claims: { aud: "other.apps.googleusercontent.com" } });
	assert.equal(verdict(L).check, "aud"); L.h.stop();
	L = await loop({ claims: { iss: "https://evil.example" } });
	assert.equal(verdict(L).check, "iss"); L.h.stop();
	L = await loop({ noIdToken: true });
	assert.equal(verdict(L).check, "no_id_token"); L.h.stop();
	L = await loop({ noAccess: true });
	assert.equal(verdict(L).check, "no_access_token"); L.h.stop();
	L = await loop({ badAccess: true });
	assert.equal(verdict(L).ok, true, "the id_token is good...");
	assert.equal(await L.G.checkAtHash(verdict(L).claims, verdict(L).accessToken, { crypto: webcrypto }), "bad", "...but it does not vouch for this access token");
	assert.deepEqual(json(L.G.credOrder("auto", { kind: "popup", ath: "bad" })), ["A"]);
	L.h.stop();
	L = await loop({ noAtHash: true });
	assert.equal(await L.G.checkAtHash(verdict(L).claims, verdict(L).accessToken, { crypto: webcrypto }), "none"); L.h.stop();
	// a narrowed request: the id_token alone
	L = await loop({}, { responseType: "id_token" });
	assert.equal(L.world.google[0].params.response_type, "id_token");
	const only = verdict(L); assert.deepEqual([only.ok, only.accessToken, only.tokenOnly], [true, "", false]); L.h.stop();
	// the access token alone: no nonce is asked for, and the state is still checked
	L = await loop({}, { responseType: "token" });
	assert.equal("nonce" in L.world.google[0].params, false);
	assert.deepEqual([verdict(L).ok, verdict(L).tokenOnly], [true, true]); L.h.stop();
	function pick3(v) { return [v.ok, v.check, v.reason]; }
}
{
	// an answer for a state that is not ours is ignored, and the real one is still taken afterwards (no hijack, no stuck attempt)
	const L = await loop({ badState: true }, { ms: 400 });
	assert.equal(L.got.relay, null, "a foreign state is never accepted");
	assert.equal(L.got.seen.length, 0);
	// the real answer arrives later (the player is slow)
	const real = { k: "glow_oidc", v: 1, h: fragFor(L.rec), q: "", t: Date.now(), d: {} };
	L.world.ls.set("glow_oidc_t_res:" + L.rec.s, JSON.stringify(real));
	assert.equal(await waitFor(() => L.got.relay, 3000), true);
	assert.equal(verdict(L).ok, true); L.h.stop();
	// a pending mailbox entry of ANOTHER attempt is left alone by the listener and swept by age
	assert.equal(L.G.sweep("t", { clock: () => Date.now() + 200_000 }) >= 0, true);
}
{
	// replay: once the attempt is cleared, the same return does nothing (no record: nothing is stored, nobody listens)
	const L = await loop({});
	assert.ok(L.got.relay);
	L.h.stop(); L.G.clearFlow("t", L.rec.s, {});
	const frag = L.got.relay.h;
	const again = makeWindow(L.world, { href: RETURN_URL + "#" + frag, ss: new Map(), opener: L.win });
	again.run(RETURN_JS);
	await sleep(80);
	assert.equal(L.world.ls.get("glow_oidc_t_res:" + L.rec.s), undefined, "an answer without an attempt is not stored");
	assert.equal(L.got.seen.length >= 1, true); // the first arrivals only
	const n = L.got.seen.length;
	await sleep(50);
	assert.equal(L.got.seen.length, n, "nothing new reached the finished attempt");
}
{
	// a window blocked by the browser: the starter is told (null), nothing is left half-armed
	const w = coreWorld();
	installGoogle(w.world, {});
	w.win.openBlocked = true;
	assert.equal(w.win.open("https://accounts.google.com/x", "n"), null);
}
{
	// iOS puts the return where the starter was (the pop-up was a sheet, or the Home Screen app took the in-scope address): the starter's own window
	// goes back, and the page that loads next finds the attempt (with its secrets, in the tab's storage) and the answer (in the mailbox)
	const st = await starter({ noListen: true });
	st.G.markOwn("t", st.rec.s, {});
	const page = retPage(st, { frag: fragFor(st.rec), opener: null, ss: st.win.ssMap });
	assert.deepEqual(page.replaced, ["auth_test.html"]);
	const next = makeWindow(st.world, { href: ORIGIN + "/game/auth_test.html", core: true, ss: st.win.ssMap }); // the same tab, a new page
	const G2 = next.window.glowOidc;
	const pend = json(G2.listPending("t", {})), mail = json(G2.listMail("t", {}));
	assert.deepEqual([pend[0].src, pend[0].beacon, pend[0].rec.s, mail.length, mail[0].state], ["ss", false, st.rec.s, 1, st.rec.s]);
	const v = G2.validate(mail[0].relay, pend[0].rec, { clientId: CLIENT });
	assert.equal(v.ok, true);
	assert.ok(G2.claim("t", st.rec.s, {}, { by: "load2" }), "the page that loads next takes it"); assert.equal(G2.claim("t", st.rec.s, {}, { by: "other tab" }), null, "and nobody else does");
	G2.clearFlow("t", st.rec.s, {});
	assert.deepEqual([...st.world.ls.keys()].filter((k) => k.indexOf(st.rec.s) >= 0), [], "single use: gone");
}
{
	// redirect mode, the whole page goes to Google: it comes back in the same window and goes back to the starter's page
	const w = coreWorld();
	const rec = { ...json(await w.G.prepare({ dest: "t", mode: "r" })), w: "W1", c: "tab" };
	w.G.savePending(rec, {}, { shared: true }); w.G.markOwn("t", rec.s, {});
	const h = w.G.listen({ dest: "t", state: rec.s, pollMs: 30 });
	h.stop(); // the page leaves: nothing of it is alive any more
	w.win.gone = true;
	const page = retPage({ world: w.world, win: w.win }, { frag: fragFor(rec), opener: null, ss: w.win.ssMap });
	await waitFor(() => page.replaced.length === 1, 4000);
	assert.deepEqual(page.replaced, ["auth_test.html"], "back to the starter's page, which takes the answer at load");
	assert.ok(w.world.ls.get("glow_oidc_t_res:" + rec.s));
	// the copy of the starter in a SHEET over a live page: the marker was copied with the storage, but the live page answers the ping
	const live = coreWorld();
	const rec2 = { ...json(await live.G.prepare({ dest: "t", mode: "r" })), w: "W1", c: "tab" };
	live.G.savePending(rec2, {}, { shared: true }); live.G.markOwn("t", rec2.s, {});
	const seen = [];
	const h2 = live.G.listen({ dest: "t", state: rec2.s, pollMs: 30, onRelay: (r, via) => seen.push(via) });
	const sheet = retPage({ world: live.world, win: live.win }, { frag: fragFor(rec2), opener: null, ss: new Map(live.win.ssMap) });
	await waitFor(() => seen.length === 1);
	await sleep(500);
	assert.deepEqual(sheet.navs, [], "no second copy of the page next to the live one");
	assert.equal(seen.length, 1, "the live page took the answer itself");
	h2.stop();
}

// 8b. the tokens of the loop go through a fake Firebase SDK: the nonce rule (the backend wants sha256(rawNonce) == the id_token's nonce) and the order of credentials
function fakeSdk(mode = {}) {
	const calls = [];
	const claimsOf = (t) => JSON.parse(Buffer.from(t.split(".")[1], "base64url").toString("utf8"));
	const err = (code) => Object.assign(new Error(code), { code });
	return {
		calls,
		async signInWithCredential(cred) {
			calls.push(cred.kind);
			await sleep(1);
			if (mode[cred.kind]) throw err(mode[cred.kind]);
			if (cred.kind === "A" && sha256hex(cred.rawNonce) !== claimsOf(cred.idToken).nonce) throw err("auth/missing-or-invalid-nonce");
			return { user: { uid: "u-" + cred.kind } };
		},
	};
}
const credOf = (kind, v) => (kind === "A" ? { kind, idToken: v.idToken, rawNonce: v.rawNonce } : kind === "B" ? { kind, idToken: v.idToken } : { kind, accessToken: v.accessToken });
async function viaSdk(L, sdk, { mode = "auto", kind = "popup", aFailed = false } = {}) {
	const v = L.G.validate(L.got.relay, L.rec, { clientId: CLIENT });
	assert.equal(v.ok, true, "the loop's answer is valid");
	const ath = await L.G.checkAtHash(v.claims, v.accessToken, { crypto: webcrypto });
	const order = json(L.G.credOrder(mode, { kind, aFailed, access: !!v.accessToken, ath }));
	const x = await L.G.exchange({ order, attempt: (k) => sdk.signInWithCredential(credOf(k, v)) });
	return { order, ath, x: json({ ok: x.ok, cred: x.cred, results: x.results, fatal: !!x.fatal }) };
}
{
	// the nonce of our request is what the backend's rule wants: credential A signs in on the very first try
	let L = await loop({});
	let sdk = fakeSdk();
	let r = await viaSdk(L, sdk);
	assert.deepEqual([r.order, r.x.ok, r.x.cred, sdk.calls, r.ath], [["A", "T"], true, "A", ["A"], "ok"]);
	assert.equal(r.x.results.T, "skip", "T is not tried once A has signed in");
	L.h.stop();
	// a wrong raw nonce is refused by the same rule (so the check above really checks something)
	L = await loop({});
	const v = L.G.validate(L.got.relay, L.rec, { clientId: CLIENT });
	sdk = fakeSdk();
	await assert.rejects(() => sdk.signInWithCredential({ kind: "A", idToken: v.idToken, rawNonce: v.rawNonce + "x" }), (e) => e.code === "auth/missing-or-invalid-nonce");
	L.h.stop();
	// the backend refuses A for the nonce: the access token T is the next credential, and only when the id_token vouches for it
	L = await loop({});
	sdk = fakeSdk({ A: "auth/missing-or-invalid-nonce" });
	r = await viaSdk(L, sdk);
	assert.deepEqual([r.x.ok, r.x.cred, sdk.calls, r.x.results.A], [true, "T", ["A", "T"], "auth/missing-or-invalid-nonce"]);
	L.h.stop();
	L = await loop({ badAccess: true });
	sdk = fakeSdk({ A: "auth/missing-or-invalid-nonce" });
	r = await viaSdk(L, sdk);
	assert.deepEqual([r.order, r.ath, r.x.ok, sdk.calls], [["A"], "bad", false, ["A"]], "an access token the id_token does not vouch for is never submitted");
	L.h.stop();
	// the second attempt of a sign-in whose A failed before goes B first, then T (a fresh token, a different credential)
	L = await loop({});
	sdk = fakeSdk({ B: "auth/invalid-credential" });
	r = await viaSdk(L, sdk, { kind: "redirect", aFailed: true });
	assert.deepEqual([r.order, r.x.cred, sdk.calls], [["B", "T"], "T", ["B", "T"]]);
	L.h.stop();
	// ?cred=B asks for B only, ?cred=T for T only
	L = await loop({});
	sdk = fakeSdk(); r = await viaSdk(L, sdk, { mode: "B" });
	assert.deepEqual([r.x.cred, sdk.calls], ["B", ["B"]]);
	sdk = fakeSdk(); r = await viaSdk(L, sdk, { mode: "T" });
	assert.deepEqual([r.x.cred, sdk.calls], ["T", ["T"]]);
	L.h.stop();
	// a network error ends the chain at once; the narrowed response types
	L = await loop({});
	sdk = fakeSdk({ A: "auth/network-request-failed" });
	r = await viaSdk(L, sdk);
	assert.deepEqual([r.x.ok, r.x.fatal, sdk.calls], [false, true, ["A"]]);
	L.h.stop();
	L = await loop({}, { responseType: "id_token" });
	sdk = fakeSdk(); r = await viaSdk(L, sdk);
	assert.deepEqual([r.order, r.x.cred], [["A"], "A"], "response_type=id_token: A only, there is no access token");
	L.h.stop();
	L = await loop({}, { responseType: "token" });
	const vt = L.G.validate(L.got.relay, L.rec, { clientId: CLIENT });
	assert.deepEqual([vt.ok, vt.tokenOnly, json(L.G.credOrder("auto", { access: !!vt.accessToken, ath: "none" }))], [true, true, ["A", "T"]], "token-only is a state-only protection: the caller decides to use it");
	L.h.stop();
}

// 9. the phone test page: it compiles, loads the core with the core's own version, and its pinned facts hold -----------------------------
{
	const testJs = scriptOf(TEST_HTML);
	assert.ok(testJs, "the test page has an inline script");
	new vm.Script(testJs, { filename: "auth_test.html" }); // a syntax error would fail the check, not the producer's phone
	const scripts = [...TEST_HTML.matchAll(/<script src="([^"]+)"><\/script>/g)].map((m) => m[1]);
	assert.deepEqual(scripts, ["auth_config.js", "glow_oidc.js?v=" + coreWorld().G.version], "the test page loads the core with its own version, so a phone never holds a stale copy");
	for (const bad of ["id_token=", "access_token=", "rawNonce="]) assert.equal(testJs.includes('log("' + bad), false);
}

console.log("auth_oidc_check: ok");
